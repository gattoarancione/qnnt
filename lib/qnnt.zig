const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const Stream = net.Stream;

const allocator = std.heap.page_allocator;

// The 0.16 std.Io interface: a concrete implementation (`Threaded`) provides the
// `Io` fat pointer that every net/sleep call is threaded through. Both are process
// globals so the value stays stable while worker threads borrow `io`.
var io_impl: Io.Threaded = undefined;
var io: Io = undefined;

const QnntNode = struct {
    client: Stream,
    address: net.IpAddress, // peer, filled in by accept; for inspection only
    since_us: u64, // when it connected
    messages: u64, // messages successfully written to it
};

// One subscriber of one topic. Only the node publishing that topic holds the
// connections, so this is the shape it reports upward to the registry; see the
// `report` command in the wire conventions below.
const PeerRecord = struct {
    address: net.IpAddress,
    connected_us: u64, // how long it had been connected when the report was taken
    messages: u64,
};

// Two separate concerns, deliberately kept apart:
//
//  * `directory` — the shared discovery table (topic -> publisher URI). It lives on
//    whichever node currently holds the registry role, and is filled over the network
//    by `pub` registrations coming from publishers on ANY node. `sub` reads from it.
//    Keys are heap-owned because they arrive in transient network buffers.
//
//  * `subscribers` — this node's own delivery table (topic -> live subscriber
//    connections), for the topics THIS process publishes. Its accept loop fills it and
//    publishAll drains it. Keys are the static topic strings passed to runPublisher.
//
// Each has its own mutex; both are touched from multiple threads.
// What the directory knows about one topic. The timestamps exist for the human side
// of the interface: `pub` registrations are refreshed on a timer, so a registration
// that stopped being refreshed is how a dead publisher becomes visible.
const TopicEntry = struct {
    endpoint: net.IpAddress,
    first_us: u64, // first time this topic was registered
    last_us: u64, // most recent refresh

    // The publishing node's subscriber list as of its last report. `peers_us` is when
    // that snapshot arrived — zero means the publisher has never reported, which is
    // different from reporting zero subscribers and is displayed differently.
    peers: std.ArrayList(PeerRecord),
    peers_us: u64,

    // The snapshot being assembled between `report begin` and `report end`, so a
    // half-delivered report never replaces a good one.
    pending: std.ArrayList(PeerRecord),
};

var directory: std.StringHashMap(TopicEntry) = .init(allocator);
var directory_mutex: Io.Mutex = .init;

// When the current registry role was acquired, for `status`. Written by the registry
// thread and read by client handlers, hence atomic.
var registry_since_us: std.atomic.Value(u64) = .init(0);

var subscribers: std.StringHashMap(std.ArrayList(QnntNode)) = .init(allocator);
var subscribers_mutex: Io.Mutex = .init;

pub const Qnnt = struct {
    // Callback invoked once per message received on a subscribed topic. It runs on
    // the subscriber's own background thread (asynchronously w.r.t. the caller), so
    // it must be thread-safe. `msg` points into the read buffer and is only valid
    // for the duration of the call — copy it if you need to keep it.
    pub const MessageHandler = *const fn (topic: []const u8, msg: []const u8) void;

    // Callback invoked once per scheduler tick on a topic this node publishes, to
    // produce the payload for that tick. Returning null skips the tick (nothing is
    // sent). It runs on the publisher's own scheduler thread, so it must be
    // thread-safe. The payload is written to the subscriber sockets AFTER the
    // callback returns, so it must outlive the call: return a literal, a global, or
    // heap memory the callback keeps alive — never a buffer on the callback's frame.
    pub const SourceHandler = *const fn (topic: []const u8) ?[]const u8;

    pub const run = &nodeRun;
    pub const runPublisher = &publisherRun;
    pub const publish = &publishAll;
    pub const subscribe = &subscribeRun;
    pub const deinit = &nodeDeinit;
    pub const sleepMs = &sleepMsFn;
    pub const nowMicros = &nowMicrosFn;
};

// Parse "tcp://<host>:<port>" into an address. Rejects anything else (e.g. the
// registry's "error: ..." replies).
fn parseTcpUri(text: []const u8) !net.IpAddress {
    const trimmed = std.mem.trim(u8, text, " \r\n");
    if (!std.mem.startsWith(u8, trimmed, "tcp://")) return error.MalformedUri;
    const hostport = trimmed["tcp://".len..];
    const colon = std.mem.lastIndexOfScalar(u8, hostport, ':') orelse return error.MalformedUri;
    const host = hostport[0..colon];
    const port = std.fmt.parseInt(u16, hostport[colon + 1 ..], 10) catch return error.MalformedUri;
    return net.IpAddress.parse(host, port);
}

// The registry speaks one line-oriented protocol to two very different kinds of
// client — the nodes in this library, and whoever pointed `nc` at port 2222 — so it
// has to stay parseable while reading well in a terminal. The conventions:
//
//  * one command per line, one response per command; commands and their aliases are
//    case-insensitive, and surrounding whitespace (including telnet's CRLF) is ignored;
//  * lines beginning with '#' are informational — the session banner, table headers,
//    summaries — and are skipped by machine clients (see `takeReply`), so prose can be
//    added for humans without breaking any parser;
//  * failures answer with a single line starting "error: ";
//  * the commands nodes depend on (`pub`, `sub`) answer in exactly one data line, and
//    `sub`'s is the bare publisher URI. That shape is load-bearing — don't dress it up.
const comment_prefix = "#";

// A registration is considered stale once it has missed a few refresh cycles. Only
// ever reported, never acted on: a stale entry is still served, since a publisher that
// went quiet is not necessarily gone and the subscriber will retry anyway.
const stale_after_us: u64 = 3 * registry_probe_interval_ms * 1000;

const Reply = struct {
    text: []const u8, // heap-owned; caller frees
    close: bool = false, // hang up after sending, for `quit`
};

fn eqlAny(verb: []const u8, names: []const []const u8) bool {
    for (names) |name| if (std.ascii.eqlIgnoreCase(verb, name)) return true;
    return false;
}

fn ownedReply(buffer: *std.ArrayList(u8)) !Reply {
    return .{ .text = try buffer.toOwnedSlice(allocator) };
}

fn usageReply(buffer: *std.ArrayList(u8), usage: []const u8) !Reply {
    try buffer.print(allocator, "error: usage: {s}\n", .{usage});
    return ownedReply(buffer);
}

fn errorReply(buffer: *std.ArrayList(u8), reason: []const u8) !Reply {
    try buffer.print(allocator, "error: {s}\n", .{reason});
    return ownedReply(buffer);
}

const report_usage = "report <topic> begin | peer <uri> <connected_us> <msgs> | end";

fn clientCommand(command: []const u8) !Reply {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);

    var it = std.mem.tokenizeAny(u8, command, " \t\r\n");
    const verb = it.next() orelse return ownedReply(&buffer); // bare Enter: stay quiet

    if (eqlAny(verb, &.{ "list", "ls" })) {
        try writeTopicList(&buffer);
    } else if (eqlAny(verb, &.{"pub"})) {
        // "pub <topic> tcp://<host>:<port>" — a publisher registering its endpoint.
        const topic = it.next() orelse return usageReply(&buffer, "pub <topic> <uri>");
        const uri = it.next() orelse return usageReply(&buffer, "pub <topic> <uri>");
        const endpoint = parseTcpUri(uri) catch {
            try buffer.print(allocator, "error: malformed uri '{s}', expected tcp://<host>:<port>\n", .{uri});
            return ownedReply(&buffer);
        };
        try registerTopic(topic, endpoint);
        try buffer.print(allocator, "ok\n", .{});
    } else if (eqlAny(verb, &.{"sub"})) {
        // Hand the subscriber the complete URI of the topic's publisher so it
        // can connect there directly.
        const topic = it.next() orelse return usageReply(&buffer, "sub <topic>");
        directory_mutex.lockUncancelable(io);
        defer directory_mutex.unlock(io);
        if (directory.get(topic)) |entry| {
            try buffer.print(allocator, "tcp://{f}\n", .{entry.endpoint});
        } else {
            try buffer.print(allocator, "error: topic {s} not found\n", .{topic});
        }
    } else if (eqlAny(verb, &.{ "subs", "peers" })) {
        const topic = it.next() orelse return usageReply(&buffer, "subs <topic>");
        try writeSubscriberList(&buffer, topic);
    } else if (eqlAny(verb, &.{"report"})) {
        // Node protocol: a publishing node handing over its subscriber list, which is
        // knowledge the registry has no other way to obtain.
        const topic = it.next() orelse return usageReply(&buffer, report_usage);
        const phase = it.next() orelse return usageReply(&buffer, report_usage);

        if (eqlAny(phase, &.{"begin"})) {
            if (!beginPeerReport(topic)) return errorReply(&buffer, "topic not registered");
        } else if (eqlAny(phase, &.{"peer"})) {
            const uri = it.next() orelse return usageReply(&buffer, report_usage);
            const connected = it.next() orelse return usageReply(&buffer, report_usage);
            const messages = it.next() orelse return usageReply(&buffer, report_usage);

            const record: PeerRecord = .{
                .address = parseTcpUri(uri) catch return errorReply(&buffer, "malformed peer uri"),
                .connected_us = std.fmt.parseInt(u64, connected, 10) catch return errorReply(&buffer, "malformed connected_us"),
                .messages = std.fmt.parseInt(u64, messages, 10) catch return errorReply(&buffer, "malformed msgs"),
            };
            if (!try addPeerReport(topic, record)) return errorReply(&buffer, "topic not registered");
        } else if (eqlAny(phase, &.{"end"})) {
            if (!commitPeerReport(topic)) return errorReply(&buffer, "topic not registered");
        } else {
            return usageReply(&buffer, report_usage);
        }
        try buffer.print(allocator, "ok\n", .{});
    } else if (eqlAny(verb, &.{ "unpub", "rm" })) {
        // Drop a registration by hand. The publisher's own refresh will put it back
        // within a probe interval if it is still alive — which makes this a way to
        // ask "is this entry a leftover?" and get an answer.
        const topic = it.next() orelse return usageReply(&buffer, "unpub <topic>");
        if (unregisterTopic(topic)) {
            try buffer.print(allocator, "ok\n", .{});
        } else {
            try buffer.print(allocator, "error: topic {s} not found\n", .{topic});
        }
    } else if (eqlAny(verb, &.{ "status", "stat" })) {
        try writeStatus(&buffer);
    } else if (eqlAny(verb, &.{"ping"})) {
        try buffer.print(allocator, "pong\n", .{});
    } else if (eqlAny(verb, &.{ "help", "h", "?" })) {
        try writeHelp(&buffer);
    } else if (eqlAny(verb, &.{ "quit", "exit", "q" })) {
        try buffer.print(allocator, "# bye\n", .{});
        return .{ .text = try buffer.toOwnedSlice(allocator), .close = true };
    } else {
        try buffer.print(allocator, "error: unknown command '{s}', type 'help'\n", .{verb});
    }

    return ownedReply(&buffer);
}

fn writeHelp(buffer: *std.ArrayList(u8)) !void {
    try buffer.print(allocator,
        \\# commands (case-insensitive):
        \\#   list                 registered topics: publisher, subscribers, age, state
        \\#   subs <topic>         one line per subscriber: peer, connected, messages
        \\#   sub <topic>          resolve a topic to its publisher URI
        \\#   pub <topic> <uri>    register or refresh a topic's publisher endpoint
        \\#   unpub <topic>        drop a registration
        \\#   status               registry uptime, topic count, timings
        \\#   ping                 liveness check
        \\#   help                 this text
        \\#   quit                 close the connection
        \\# aliases: ls, peers, rm, stat, h, ?, q, exit
        \\# subscriber figures come from the publishing nodes, which report them with
        \\# each refresh, so they lag by up to one probe interval; 'subs' says how stale.
        \\# node protocol: report <topic> begin | peer <uri> <connected_us> <msgs> | end
        \\# '#' lines are informational; failures reply "error: <reason>".
        \\
    , .{});
}

// Human-readable age. The exact figure matters less than being able to tell at a
// glance which registrations have gone quiet.
fn formatAge(buf: []u8, age_us: u64) []const u8 {
    const secs = age_us / 1_000_000;
    if (secs < 10) return std.fmt.bufPrint(buf, "{d}.{d}s", .{ secs, (age_us % 1_000_000) / 100_000 }) catch "?";
    if (secs < 60) return std.fmt.bufPrint(buf, "{d}s", .{secs}) catch "?";
    return std.fmt.bufPrint(buf, "{d}m{d:0>2}s", .{ secs / 60, secs % 60 }) catch "?";
}

fn writePadded(buffer: *std.ArrayList(u8), text: []const u8, width: usize) !void {
    try buffer.appendSlice(allocator, text);
    if (width > text.len) try buffer.appendNTimes(allocator, ' ', width - text.len);
}

// Wide enough for the header word and any value formatAge produces ("12m34s").
const age_column_width = "refreshed".len;

const subs_column_width = "subs".len;

// One row of the topic table. Header and data rows are both rendered from this, with
// the same widths, so they cannot drift out of alignment.
const TopicRow = struct {
    lead: []const u8, // "# " for the header, "  " for data, so columns line up
    topic: []const u8,
    publisher: []const u8,
    subs: []const u8,
    refreshed: []const u8,
    age: []const u8,
    state: []const u8,
};

const TopicWidths = struct {
    topic: usize,
    publisher: usize,
};

fn writeTopicRow(buffer: *std.ArrayList(u8), widths: TopicWidths, row: TopicRow) !void {
    try buffer.appendSlice(allocator, row.lead);
    try writePadded(buffer, row.topic, widths.topic);
    try buffer.appendSlice(allocator, "  ");
    try writePadded(buffer, row.publisher, widths.publisher);
    try buffer.appendSlice(allocator, "  ");
    try writePadded(buffer, row.subs, subs_column_width);
    try buffer.appendSlice(allocator, "  ");
    try writePadded(buffer, row.refreshed, age_column_width);
    try buffer.appendSlice(allocator, "  ");
    try writePadded(buffer, row.age, age_column_width);
    try buffer.appendSlice(allocator, "  ");
    try buffer.appendSlice(allocator, row.state);
    try buffer.appendSlice(allocator, "\n");
}

// "tcp://" + a formatted address; ample for IPv6 with a port.
fn formatPublisher(buf: []u8, endpoint: net.IpAddress) []const u8 {
    return std.fmt.bufPrint(buf, "tcp://{f}", .{endpoint}) catch "tcp://?";
}

fn writeTopicList(buffer: *std.ArrayList(u8)) !void {
    directory_mutex.lockUncancelable(io);
    defer directory_mutex.unlock(io);

    if (directory.count() == 0) {
        try buffer.print(allocator, "# no topics registered\n", .{});
        return;
    }

    // Size the topic and publisher columns to their content so the table lines up
    // without leaving a gutter wide enough for addresses nobody has.
    var topic_width: usize = "topic".len;
    var publisher_width: usize = "publisher".len;
    var sizing = directory.iterator();
    while (sizing.next()) |entry| {
        var uri_buf: [64]u8 = undefined;
        topic_width = @max(topic_width, entry.key_ptr.len);
        publisher_width = @max(publisher_width, formatPublisher(&uri_buf, entry.value_ptr.endpoint).len);
    }

    const widths: TopicWidths = .{ .topic = topic_width, .publisher = publisher_width };

    // Header carries the '#' prefix; data rows are indented by two to match it.
    try writeTopicRow(buffer, widths, .{
        .lead = "# ",
        .topic = "topic",
        .publisher = "publisher",
        .subs = "subs",
        .refreshed = "refreshed",
        .age = "age",
        .state = "state",
    });

    // Wall clock, so it can step backwards across an NTP adjustment; saturating
    // subtraction keeps that from wrapping into a bogus 584,000-year age.
    const now_us: u64 = @intCast(nowMicrosFn());
    var stale_count: usize = 0;

    var entries = directory.iterator();
    while (entries.next()) |entry| {
        const refreshed_us = now_us -| entry.value_ptr.last_us;
        const is_stale = refreshed_us > stale_after_us;
        if (is_stale) stale_count += 1;

        var uri_buf: [64]u8 = undefined;
        var refreshed_buf: [16]u8 = undefined;
        var age_buf: [16]u8 = undefined;
        var subs_buf: [16]u8 = undefined;

        // "-" rather than "0" when the publisher has never reported: not knowing the
        // count is a different fact from knowing it is zero.
        const subs = if (entry.value_ptr.peers_us == 0)
            "-"
        else
            std.fmt.bufPrint(&subs_buf, "{d}", .{entry.value_ptr.peers.items.len}) catch "?";

        try writeTopicRow(buffer, widths, .{
            .lead = "  ",
            .topic = entry.key_ptr.*,
            .publisher = formatPublisher(&uri_buf, entry.value_ptr.endpoint),
            .subs = subs,
            .refreshed = formatAge(&refreshed_buf, refreshed_us),
            .age = formatAge(&age_buf, now_us -| entry.value_ptr.first_us),
            .state = if (is_stale) "stale" else "live",
        });
    }

    if (stale_count == 0) {
        try buffer.print(allocator, "# {d} topic(s)\n", .{directory.count()});
    } else {
        try buffer.print(allocator, "# {d} topic(s), {d} not refreshed in {d}ms\n", .{
            directory.count(),
            stale_count,
            stale_after_us / 1000,
        });
    }
}

// Detail for every subscriber of one topic, from the publishing node's last report.
// Every column is left as-of that report rather than advanced to now: the age and the
// message count then belong to the same instant, so msgs/connected is the topic's
// actual delivery rate. The header says how old the snapshot is.
fn writeSubscriberList(buffer: *std.ArrayList(u8), topic: []const u8) !void {
    directory_mutex.lockUncancelable(io);
    defer directory_mutex.unlock(io);

    const entry = directory.getPtr(topic) orelse {
        try buffer.print(allocator, "error: topic {s} not found\n", .{topic});
        return;
    };

    if (entry.peers_us == 0) {
        try buffer.print(allocator, "# {s}: publisher has not reported subscribers yet\n", .{topic});
        return;
    }

    const now_us: u64 = @intCast(nowMicrosFn());
    const snapshot_us = now_us -| entry.peers_us;

    var snapshot_buf: [16]u8 = undefined;
    try buffer.print(allocator, "# subscribers of {s}, reported {s} ago\n", .{
        topic,
        formatAge(&snapshot_buf, snapshot_us),
    });

    if (entry.peers.items.len == 0) {
        try buffer.print(allocator, "# no subscribers\n", .{});
        return;
    }

    var peer_width: usize = "peer".len;
    for (entry.peers.items) |peer| {
        var buf: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{f}", .{peer.address}) catch "?";
        peer_width = @max(peer_width, text.len);
    }

    try buffer.appendSlice(allocator, "# ");
    try writePadded(buffer, "peer", peer_width);
    try buffer.appendSlice(allocator, "  ");
    try writePadded(buffer, "connected", age_column_width);
    try buffer.appendSlice(allocator, "  msgs\n");

    for (entry.peers.items) |peer| {
        var peer_buf: [64]u8 = undefined;
        var connected_buf: [16]u8 = undefined;

        try buffer.appendSlice(allocator, "  ");
        try writePadded(buffer, std.fmt.bufPrint(&peer_buf, "{f}", .{peer.address}) catch "?", peer_width);
        try buffer.appendSlice(allocator, "  ");
        try writePadded(buffer, formatAge(&connected_buf, peer.connected_us), age_column_width);
        try buffer.print(allocator, "  {d}\n", .{peer.messages});
    }

    try buffer.print(allocator, "# {d} subscriber(s)\n", .{entry.peers.items.len});
}

fn writeStatus(buffer: *std.ArrayList(u8)) !void {
    const now_us: u64 = @intCast(nowMicrosFn());

    const topics = blk: {
        directory_mutex.lockUncancelable(io);
        defer directory_mutex.unlock(io);
        break :blk directory.count();
    };

    const since_us = registry_since_us.load(.monotonic);
    var uptime_buf: [16]u8 = undefined;
    const uptime = if (since_us == 0) "?" else formatAge(&uptime_buf, now_us -| since_us);

    try buffer.print(allocator, "uptime {s}\n", .{uptime});
    try buffer.print(allocator, "topics {d}\n", .{topics});
    try buffer.print(allocator, "port {d}\n", .{registry_port});
    try buffer.print(allocator, "probe-interval {d}ms\n", .{registry_probe_interval_ms});
    try buffer.print(allocator, "stale-after {d}ms\n", .{stale_after_us / 1000});
}

// Record (or refresh) a topic's publisher endpoint in the discovery directory.
// The topic key arrives in a transient network buffer, so it is heap-owned on
// first insert and left untouched on refresh.
fn registerTopic(topic: []const u8, endpoint: net.IpAddress) !void {
    const now_us: u64 = @intCast(nowMicrosFn());

    directory_mutex.lockUncancelable(io);
    defer directory_mutex.unlock(io);

    const gop = try directory.getOrPut(topic);
    if (!gop.found_existing) {
        gop.key_ptr.* = allocator.dupe(u8, topic) catch |err| {
            _ = directory.remove(topic);
            return err;
        };
        gop.value_ptr.* = .{
            .endpoint = endpoint,
            .first_us = now_us,
            .last_us = now_us,
            .peers = .empty,
            .peers_us = 0,
            .pending = .empty,
        };
    } else {
        // A refresh. The endpoint is re-read rather than assumed: a restarted
        // publisher comes back on a different ephemeral port.
        gop.value_ptr.endpoint = endpoint;
        gop.value_ptr.last_us = now_us;
    }
}

fn unregisterTopic(topic: []const u8) bool {
    directory_mutex.lockUncancelable(io);
    defer directory_mutex.unlock(io);

    if (directory.fetchRemove(topic)) |kv| {
        var entry = kv.value;
        entry.peers.deinit(allocator);
        entry.pending.deinit(allocator);
        allocator.free(kv.key); // owned on insert
        return true;
    }
    return false;
}

// The three phases of a subscriber report from a publishing node. Each returns false
// if the topic is unknown here — which happens legitimately, when a publisher reports
// to a registry elected after the publisher started and its `pub` hasn't landed yet.
fn beginPeerReport(topic: []const u8) bool {
    directory_mutex.lockUncancelable(io);
    defer directory_mutex.unlock(io);

    const entry = directory.getPtr(topic) orelse return false;
    entry.pending.clearRetainingCapacity();
    return true;
}

fn addPeerReport(topic: []const u8, record: PeerRecord) !bool {
    directory_mutex.lockUncancelable(io);
    defer directory_mutex.unlock(io);

    const entry = directory.getPtr(topic) orelse return false;
    try entry.pending.append(allocator, record);
    return true;
}

fn commitPeerReport(topic: []const u8) bool {
    directory_mutex.lockUncancelable(io);
    defer directory_mutex.unlock(io);

    const entry = directory.getPtr(topic) orelse return false;

    // Swap instead of copying, so the retired snapshot's capacity is reused for the
    // next one rather than being reallocated every probe interval.
    std.mem.swap(std.ArrayList(PeerRecord), &entry.peers, &entry.pending);
    entry.pending.clearRetainingCapacity();
    entry.peers_us = @intCast(nowMicrosFn());
    return true;
}

fn handleRegistryClient(client: Stream) !void {
    defer client.close(io);

    var rbuf: [1024]u8 = undefined;
    var reader = client.reader(io, &rbuf);

    // empty writer buffer => writes go straight through
    var writer = client.writer(io, &.{});

    // Informational, so machine clients skip it; a human gets a hint instead of
    // connecting to silence and wondering whether anything is listening.
    try writer.interface.writeAll("# qnnt registry, type 'help' for commands\n");

    while (true) {
        const chunk = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return, // client closed
            error.StreamTooLong => {
                // A line too long for the read buffer. Say so and resynchronize on the
                // next newline rather than dropping an interactive session over it.
                try writer.interface.writeAll("error: line too long\n");
                _ = reader.interface.discardDelimiterInclusive('\n') catch return;
                continue;
            },
            else => return err,
        };

        const reply = try clientCommand(chunk);
        defer allocator.free(reply.text);
        try writer.interface.writeAll(reply.text);
        if (reply.close) return;
    }
}

// Read the next line that isn't informational. Machine clients go through this so the
// registry stays free to print banners and headers at humans (see the conventions
// above) without those lines being mistaken for a response.
fn takeReply(reader: *Io.Reader) Io.Reader.DelimiterError![]u8 {
    while (true) {
        const line = try reader.takeDelimiterInclusive('\n');
        if (!std.mem.startsWith(u8, line, comment_prefix)) return line;
    }
}

// The registry lives on a well-known port. Every node contends for it; whoever
// binds first plays the registry role, the rest stand by. `reuse_address` stays
// false on purpose so the bind is mutually exclusive (SO_REUSEPORT would let
// several nodes bind at once and defeat the election).
const registry_port = 2222;

// How often standby nodes re-check the port, publishers refresh their registration,
// and subscribers re-poll for a topic URI.
const registry_probe_interval_ms = 2000;

fn registryRun() void {
    while (true) {
        const addr: net.IpAddress = net.IpAddress.parse("127.0.0.1", registry_port) catch |err| {
            std.debug.print("registry address parse failed: {}\n", .{err});
            return;
        };

        var server = addr.listen(io, .{ .reuse_address = false }) catch {
            // Another node already holds the registry role; stand by and re-probe.
            sleepMsFn(registry_probe_interval_ms);
            continue;
        };
        defer server.deinit(io); // released before we re-contend for the role

        registry_since_us.store(@intCast(nowMicrosFn()), .monotonic);
        std.debug.print("registry role acquired, listening on port {}\n", .{addr.getPort()});

        // Serve until the listener fails, then fall through to release the port
        // and re-enter contention.
        while (true) {
            const client = server.accept(io) catch |err| {
                std.debug.print("registry accept failed ({}); releasing role\n", .{err});
                break;
            };
            // handle in a thread; drop spawn if you want single-threaded
            _ = std.Thread.spawn(.{}, handleRegistryClient, .{client}) catch |err| {
                std.debug.print("error spawning registry client handler: {}\n", .{err});
                client.close(io);
            };
        }
    }
}

pub fn publishAll(topic: []const u8, data: []const u8) !void {
    // Held across the socket writes: on localhost this is cheap, and it keeps
    // the subscriber list stable while the accept loop may be appending to it.
    subscribers_mutex.lockUncancelable(io);
    defer subscribers_mutex.unlock(io);

    if (subscribers.getPtr(topic)) |list_ptr| {
        // Iterate backward so a failed-write swapRemove only ever touches
        // indices we've already visited.
        var idx = list_ptr.items.len;
        while (idx > 0) {
            idx -= 1;
            var writer = list_ptr.items[idx].client.writer(io, &.{});
            writer.interface.writeAll(data) catch |err| {
                std.debug.print("error writing: {}\n", .{err});
                _ = list_ptr.swapRemove(idx);
                continue;
            };
            list_ptr.items[idx].messages += 1;
        }
    } else {
        std.debug.print("topic {s} not found\n", .{topic});
    }
}

// Drive `source` at a fixed rate, publishing whatever it returns. Paced against an
// absolute deadline rather than "sleep(period) after the work", so the callback's own
// cost and wake-up jitter don't accumulate into drift.
fn publisherSchedule(topic: []const u8, source: Qnnt.SourceHandler, period_us: u64) void {
    var next_us: u64 = @intCast(nowMicrosFn());

    while (true) {
        next_us += period_us;
        const now_us: u64 = @intCast(nowMicrosFn());

        if (next_us > now_us) {
            sleepUsFn(next_us - now_us);
        } else if (now_us - next_us >= period_us) {
            // More than a full period behind (slow callback, scheduling hiccup): give
            // up on the missed ticks and resynchronize, rather than firing a burst to
            // catch up on a backlog that only grows.
            next_us = now_us;
        }

        if (source(topic)) |payload| {
            publishAll(topic, payload) catch |err| {
                std.debug.print("error publishing on {s}: {}\n", .{ topic, err });
            };
        }
    }
}

fn nodePublish(topic: []const u8, source: ?Qnnt.SourceHandler, period_us: u64) !void {
    // Bind to loopback with an ephemeral port (0); the OS fills in the real port,
    // which we read back from the socket and register with the discovery directory.
    const addr: net.IpAddress = try .parse("127.0.0.1", 0);

    var server = try addr.listen(io, .{ .reuse_address = false });
    defer server.deinit(io);

    const endpoint = server.socket.address; // resolved, including the ephemeral port

    {
        subscribers_mutex.lockUncancelable(io);
        defer subscribers_mutex.unlock(io);
        try subscribers.put(topic, .empty);
    }

    std.debug.print("publisher {s} listening on tcp://{f}\n", .{ topic, endpoint });

    // Keep the registry's directory pointed at us. This runs regardless of which
    // node holds the registry (we register over the network, even to ourselves),
    // retries until a registry exists, and refreshes so a newly-elected registry
    // after a failover re-learns this publisher.
    _ = std.Thread.spawn(.{}, registerLoop, .{ topic, endpoint }) catch |err| {
        std.debug.print("failed to spawn register loop for {s}: {}\n", .{ topic, err });
    };

    // Self-paced publishing, if the caller supplied a source. Started only once the
    // listener is up and registered, so no tick can fire before subscribers have
    // somewhere to connect.
    if (source) |src| {
        _ = std.Thread.spawn(.{}, publisherSchedule, .{ topic, src, period_us }) catch |err| {
            std.debug.print("failed to spawn scheduler for {s}: {}\n", .{ topic, err });
        };
    }

    while (true) {
        const client = try server.accept(io);

        subscribers_mutex.lockUncancelable(io);
        defer subscribers_mutex.unlock(io);
        if (subscribers.getPtr(topic)) |list_ptr| {
            try list_ptr.append(allocator, .{
                .client = client,
                .address = client.socket.address, // peer address, resolved by accept
                .since_us = @intCast(nowMicrosFn()),
                .messages = 0,
            });
        }
    }
}

// Copy out this topic's subscriber list for reporting. Taken under the lock and
// released before any network write, so a slow registry can't stall publishing.
// Caller frees.
fn snapshotPeers(topic: []const u8, now_us: u64) ![]PeerRecord {
    subscribers_mutex.lockUncancelable(io);
    defer subscribers_mutex.unlock(io);

    const list_ptr = subscribers.getPtr(topic);
    const count = if (list_ptr) |l| l.items.len else 0;

    const out = try allocator.alloc(PeerRecord, count);
    if (list_ptr) |l| {
        for (l.items, out) |node, *record| {
            record.* = .{
                .address = node.address,
                .connected_us = now_us -| node.since_us,
                .messages = node.messages,
            };
        }
    }
    return out;
}

// Register this publisher with whichever node holds the registry, then hand over the
// current subscriber list. The registry cannot see those connections — they terminate
// here — so piggybacking the snapshot on the refresh is how `list` and `subs` get
// their figures, at the cost of them lagging by up to one probe interval.
fn registerOnce(topic: []const u8, endpoint: net.IpAddress) !void {
    const reg: net.IpAddress = try net.IpAddress.parse("127.0.0.1", registry_port);
    var conn = try reg.connect(io, .{ .mode = .stream });
    defer conn.close(io);

    var writer = conn.writer(io, &.{});
    var rbuf: [256]u8 = undefined;
    var reader = conn.reader(io, &rbuf);

    var cmdbuf: [512]u8 = undefined;

    const cmd = try std.fmt.bufPrint(&cmdbuf, "pub {s} tcp://{f}\n", .{ topic, endpoint });
    try writer.interface.writeAll(cmd);
    _ = takeReply(&reader.interface) catch {}; // best-effort ack

    const now_us: u64 = @intCast(nowMicrosFn());
    const peers = try snapshotPeers(topic, now_us);
    defer allocator.free(peers);

    // Framed, so a report interrupted midway (registry failover, dropped connection)
    // leaves the previous snapshot in place instead of a truncated one.
    const begin = try std.fmt.bufPrint(&cmdbuf, "report {s} begin\n", .{topic});
    try writer.interface.writeAll(begin);
    _ = takeReply(&reader.interface) catch {};

    // Each line is acknowledged before the next is sent: it keeps this in lockstep
    // with the registry rather than pushing an unbounded batch at it.
    for (peers) |peer| {
        const line = try std.fmt.bufPrint(&cmdbuf, "report {s} peer tcp://{f} {d} {d}\n", .{
            topic,
            peer.address,
            peer.connected_us,
            peer.messages,
        });
        try writer.interface.writeAll(line);
        _ = takeReply(&reader.interface) catch {};
    }

    const end = try std.fmt.bufPrint(&cmdbuf, "report {s} end\n", .{topic});
    try writer.interface.writeAll(end);
    _ = takeReply(&reader.interface) catch {};
}

fn registerLoop(topic: []const u8, endpoint: net.IpAddress) void {
    while (true) {
        registerOnce(topic, endpoint) catch {}; // registry not up yet / mid-failover
        sleepMsFn(registry_probe_interval_ms);
    }
}

// Ask the registry (well-known port) where `topic` is published and return the
// publisher's endpoint. Fails if the registry is unreachable or doesn't know the
// topic yet, so callers are expected to retry.
fn resolveTopic(topic: []const u8) !net.IpAddress {
    const reg: net.IpAddress = try net.IpAddress.parse("127.0.0.1", registry_port);
    var conn = try reg.connect(io, .{ .mode = .stream });
    defer conn.close(io);

    var cmdbuf: [256]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmdbuf, "sub {s}\n", .{topic});
    var writer = conn.writer(io, &.{});
    try writer.interface.writeAll(cmd);

    var rbuf: [256]u8 = undefined;
    var reader = conn.reader(io, &rbuf);
    const line = try takeReply(&reader.interface);
    return parseTcpUri(line); // errors (incl. "error: not found") -> caller retries
}

// Resolve `topic` through the registry, connect to its publisher, and deliver every
// message received to `handler`. Retries resolution/connection so it tolerates the
// registry or publisher not being ready yet (e.g. the publishing node started
// later), and reconnects if the publisher goes away.
fn subscribeLoop(topic: []const u8, handler: Qnnt.MessageHandler) void {
    while (true) {
        const endpoint = resolveTopic(topic) catch {
            sleepMsFn(registry_probe_interval_ms);
            continue;
        };

        var stream = endpoint.connect(io, .{ .mode = .stream }) catch {
            sleepMsFn(registry_probe_interval_ms);
            continue;
        };
        defer stream.close(io);

        std.debug.print("subscribed to {s} @ tcp://{f}\n", .{ topic, endpoint });

        var rbuf: [1024]u8 = undefined;
        var reader = stream.reader(io, &rbuf);
        while (true) {
            const msg = reader.interface.takeDelimiterInclusive('\n') catch break;
            handler(topic, msg); // delivered on this thread; msg valid only for the call
        }

        // Publisher closed; re-resolve and reconnect after a short pause.
        sleepMsFn(registry_probe_interval_ms);
    }
}

pub fn subscribeRun(topic: []const u8, handler: Qnnt.MessageHandler) bool {
    _ = std.Thread.spawn(.{}, subscribeLoop, .{ topic, handler }) catch |err| {
        std.debug.print("error spawning subscriber thread for {s}: {}\n", .{topic, err});
        return false;
    };
    return true;
}

fn sleepMsFn(ms: u64) void {
    io.sleep(Io.Duration.fromMilliseconds(@intCast(ms)), .awake) catch {};
}

fn sleepUsFn(us: u64) void {
    io.sleep(Io.Duration.fromMicroseconds(@intCast(us)), .awake) catch {};
}

// Wall-clock time now, in microseconds since the Unix epoch.
fn nowMicrosFn() i64 {
    return Io.Timestamp.now(io, .real).toMicroseconds();
}

// Exit promptly on Ctrl-C / termination. Io.Threaded installs signal machinery
// that otherwise swallows SIGINT, so a node would keep holding the registry port
// after Ctrl-C and no standby could ever take over. _exit is async-signal-safe and
// lets the OS close the listening socket immediately, so a standby rebinds within
// one probe interval. (No prints here: std.debug.print takes a lock and is not
// async-signal-safe.)
fn onShutdownSignal(_: std.posix.SIG) callconv(.c) void {
    std.c._exit(0);
}

fn installShutdownHandlers() void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onShutdownSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
}

pub fn nodeRun() bool {
    io_impl = .init(allocator, .{});
    io = io_impl.io();

    // Must run after Io.Threaded's own signal setup so our INT/TERM handlers win.
    installShutdownHandlers();

    _ = std.Thread.spawn(.{}, registryRun, .{}) catch |err| {
        std.debug.print("error spawning registry thread: {}\n", .{err});
        return false;
    };
    sleepMsFn(5);
    return true;
}

// Start publishing `topic`. `source` and `frequency_hz` are optional and go together:
// pass both to have the library drive the topic from its own scheduler thread, or both
// null to publish manually via `publish()`. Supplying only one of the two is a caller
// mistake and is reported rather than silently ignored.
pub fn publisherRun(topic: []const u8, source: ?Qnnt.SourceHandler, frequency_hz: ?u32) bool {
    if ((source == null) != (frequency_hz == null)) {
        std.debug.print("publisher {s}: source and frequency must be given together\n", .{topic});
        return false;
    }

    var period_us: u64 = 0;
    if (frequency_hz) |hz| {
        if (hz == 0) {
            std.debug.print("publisher {s}: frequency must be > 0 Hz\n", .{topic});
            return false;
        }
        period_us = 1_000_000 / hz;
    }

    _ = std.Thread.spawn(.{}, nodePublish, .{ topic, source, period_us }) catch |err| {
        std.debug.print("error spawning publisher thread for {s}: {}\n", .{topic, err});
        return false;
    };
    sleepMsFn(5);
    return true;
}

pub fn nodeDeinit() void {
    {
        directory_mutex.lockUncancelable(io);
        defer directory_mutex.unlock(io);
        var it = directory.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*); // owned keys
            entry.value_ptr.peers.deinit(allocator);
            entry.value_ptr.pending.deinit(allocator);
        }
        directory.clearAndFree();
    }
    {
        subscribers_mutex.lockUncancelable(io);
        defer subscribers_mutex.unlock(io);
        var it = subscribers.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(allocator);
        subscribers.clearAndFree();
    }

    io_impl.deinit();
}

test {
    _ = @import("./qnnt.test.zig");
}
