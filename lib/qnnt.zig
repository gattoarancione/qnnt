const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const Stream = net.Stream;

/// The TLD binary framing, re-exported so users get the encoder and decoder without a
/// second import. See `subscribeFrames` for how it meets the pub/sub data path.
pub const Tld = @import("tld.zig");

const allocator = @import("alloc.zig").allocator;

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

// ---------------------------------------------------------------- shutdown
//
// Every worker here is a loop around a blocking socket call or a sleep, so stopping
// them needs three things: a flag they check, a way to break whatever they are blocked
// in, and their handles so they can be joined. Without the last two, `nodeDeinit` tears
// down `io` and the maps while threads are still using them.
//
// The bookkeeping below is guarded by `Io.Mutex` like everything else. That is safe
// because every use of it happens while `io` is still live: nodeDeinit does all of its
// signalling, breaking and joining *before* it tears `io` down, and touches none of
// these afterwards.

var shutting_down: std.atomic.Value(bool) = .init(false);

var workers: std.ArrayList(std.Thread) = .empty;
var workers_mutex: Io.Mutex = .init;

// Sockets a worker may be blocked on, and how to wake it. The two kinds need different
// treatment, which is the trap here: `shutdown` wakes a blocking read, but a listening
// socket is not connected, so on BSD/macOS shutdown fails with ENOTCONN and leaves
// `accept` blocked forever. Waking an accept portably takes a real connection.
const TrackedSocket = struct {
    socket: net.Socket,
    kind: enum { listener, stream },
};

var live_sockets: std.ArrayList(TrackedSocket) = .empty;
var live_sockets_mutex: Io.Mutex = .init;

// Longest a worker sleeps before re-checking the shutdown flag. Sleeps shorter than
// this are taken in one go, so ordinary publish pacing is untouched.
const shutdown_poll_ms = 50;

fn isShuttingDown() bool {
    // A plain flag with no data published through it, so monotonic is enough — and it
    // is read once per published frame on the unpaced path.
    return shutting_down.load(.monotonic);
}

// Spawn a worker and record it so shutdown can join it, returning false if it must not
// be started. Capacity is reserved before the thread starts, because a thread that
// starts but fails to be recorded is a thread that can never be joined — the exact leak
// this machinery exists to prevent.
//
// Like `trackSocket`, the shutdown check belongs inside this critical section. Without
// it, a worker spawned between `joinWorkers` moving the list out and the caller noticing
// the flag lands in the fresh list, is never joined, and outlives `io` — which shows up
// as the process failing at exit long after every visible operation succeeded.
fn spawnWorker(comptime function: anytype, args: anytype) bool {
    workers_mutex.lockUncancelable(io);
    defer workers_mutex.unlock(io);

    if (isShuttingDown()) return false;

    workers.ensureUnusedCapacity(allocator, 1) catch return false;
    const thread = std.Thread.spawn(.{}, function, args) catch return false;
    workers.appendAssumeCapacity(thread);
    return true;
}

// Register a socket a worker is about to block on, returning false if the caller must
// not block after all. Callers must untrack *before* closing, so a listed handle is
// always still open: shutdown holds the lock while it breaks them, so an entry it sees
// cannot have been closed and its fd reused.
//
// The shutdown check has to happen *inside* this critical section, and that is the whole
// reason this returns a value. `breakLiveSockets` runs once, so a worker that starts
// blocking after it has passed would never be interrupted. Testing the flag under the
// same lock leaves no gap: register before the break and the break sees you, register
// after it and you are told to stop instead.
fn trackSocket(socket: net.Socket, kind: @FieldType(TrackedSocket, "kind")) bool {
    live_sockets_mutex.lockUncancelable(io);
    defer live_sockets_mutex.unlock(io);

    if (isShuttingDown()) return false;

    // A failed append would leave shutdown unable to interrupt this socket, so treat it
    // as a refusal rather than blocking un-interruptibly.
    live_sockets.append(allocator, .{ .socket = socket, .kind = kind }) catch return false;
    return true;
}

fn untrackSocket(socket: net.Socket) void {
    live_sockets_mutex.lockUncancelable(io);
    defer live_sockets_mutex.unlock(io);
    for (live_sockets.items, 0..) |tracked, i| {
        if (tracked.socket.handle == socket.handle) {
            _ = live_sockets.swapRemove(i);
            return;
        }
    }
}

// Break every blocking call in progress. Shutdown only, and it closes nothing: each
// socket's owner still closes it on the way out.
//
// The connects below happen with the lock held. That is deliberate and safe: they are
// loopback connects taking microseconds, and a worker woken by one only needs this lock
// to untrack itself, which it can do once we are done — nothing here waits on a worker.
fn breakLiveSockets() void {
    live_sockets_mutex.lockUncancelable(io);
    defer live_sockets_mutex.unlock(io);

    for (live_sockets.items) |tracked| switch (tracked.kind) {
        // Connected, so shutting it down makes the pending read return.
        .stream => {
            const stream: Stream = .{ .socket = tracked.socket };
            stream.shutdown(io, .both) catch {};
        },
        // Not connected, so shutdown is a no-op on BSD. Hand it the one thing `accept`
        // does return for — a connection — and the worker wakes, sees the flag and
        // closes what it just accepted.
        .listener => {
            var waker = tracked.socket.address.connect(io, .{ .mode = .stream }) catch continue;
            waker.close(io);
        },
    };
}

// Shut down the connections this node delivers on. They are owned by the `subscribers`
// table rather than tracked as blocking reads, but `publishAll` can be parked in a write
// to one of them if a subscriber has stopped draining — and that would stall the join.
fn breakSubscriberStreams() void {
    subscribers_mutex.lockUncancelable(io);
    defer subscribers_mutex.unlock(io);

    var it = subscribers.iterator();
    while (it.next()) |entry| {
        for (entry.value_ptr.items) |node| node.client.shutdown(io, .both) catch {};
    }
}

fn joinWorkers() void {
    // Move the list out under the lock and join outside it: an exiting worker may still
    // call untrackSocket or (for the registry) try to spawn, and joining while holding
    // its lock would deadlock.
    workers_mutex.lockUncancelable(io);
    var pending = workers;
    workers = .empty;
    workers_mutex.unlock(io);

    for (pending.items) |thread| thread.join();
    pending.deinit(allocator);
}

// Sleep, but wake early when a shutdown starts. Returns false if the caller should stop.
// Sleeps up to `shutdown_poll_ms` are one call, so the publish scheduler's pacing is
// unaffected at any period a caller is likely to use.
fn sleepUsInterruptible(us: u64) bool {
    var remaining = us;
    while (remaining > 0) {
        if (isShuttingDown()) return false;
        const slice = @min(remaining, shutdown_poll_ms * 1000);
        sleepUsFn(slice);
        remaining -= slice;
    }
    return !isShuttingDown();
}

fn sleepMsInterruptible(ms: u64) bool {
    return sleepUsInterruptible(ms * 1000);
}

var subscribers: std.StringHashMap(std.ArrayList(QnntNode)) = .init(allocator);
var subscribers_mutex: Io.Mutex = .init;

pub const Qnnt = struct {
    // Every callback takes the `context` pointer given at registration and hands it
    // back untouched. Without it a callback can only reach module-level state, which
    // means one handler cannot serve two subscriptions, and no closure, C++ lambda or
    // Python callable can be bound to one — it is `void *user_data` under a Zig name.
    // The library never dereferences it.

    // Callback invoked once per message received on a subscribed topic. It runs on
    // the subscriber's own background thread (asynchronously w.r.t. the caller), so
    // it must be thread-safe. `msg` points into the read buffer and is only valid
    // for the duration of the call — copy it if you need to keep it.
    pub const MessageHandler = *const fn (topic: []const u8, msg: []const u8, context: ?*anyopaque) void;

    // Callback invoked once per scheduler tick on a topic this node publishes, to
    // produce the payload for that tick. Returning null skips the tick (nothing is
    // sent). It runs on the publisher's own scheduler thread, so it must be
    // thread-safe. The payload is written to the subscriber sockets AFTER the
    // callback returns, so it must outlive the call: return a literal, a global, or
    // heap memory the callback keeps alive — never a buffer on the callback's frame.
    pub const SourceHandler = *const fn (topic: []const u8, context: ?*anyopaque) ?[]const u8;

    /// Callback for a TLD-framed subscription. `frame` borrows a buffer owned by the
    /// subscriber thread and is only valid for the duration of the call — copy
    /// anything you keep, including the slices its accessors return.
    pub const FrameHandler = *const fn (topic: []const u8, frame: Tld.Frame, context: ?*anyopaque) void;

    pub const run = &nodeRun;
    pub const runPublisher = &publisherRun;
    pub const publish = &publishAll;
    pub const subscribe = &subscribeRun;
    pub const subscribeFrames = &subscribeFramesRun;

    /// Buffered subscription: messages land in a queue the caller drains with `poll`,
    /// rather than arriving on a library thread. See the notes above `QueuedMessage`.
    pub const subscribeQueue = &subscribeQueueRun;
    pub const poll = &queuePoll;
    pub const reserveQueue = &queueReserve;
    pub const queueDropped = &queueDroppedCount;
    pub const deinit = &nodeDeinit;
    pub const sleepMs = &sleepMsFn;
    pub const nowMicros = &nowMicrosFn;

    /// Registry port control. Set before `run()`; see `setRegistryPort`.
    pub const setRegistryPort = &setRegistryPortFn;
    pub const registryPort = &currentRegistryPort;

    /// Opt in to handling Ctrl-C and SIGTERM. Off by default: a library must not
    /// install process-wide handlers behind its host's back, nor replace one the host
    /// already set. Call it after `run()` — see `installSignalHandlers`.
    pub const installSignalHandlers = &installShutdownHandlers;

    /// True once a stop has been requested, by a handled signal or by `deinit`. An
    /// application whose main thread has nothing to do can loop on this and fall
    /// through to its own `deinit` when it flips.
    pub const stopRequested = &isShuttingDown;
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

    // Untracked before the close above, so this handle is only listed while open.
    if (!trackSocket(client.socket, .stream)) return;
    defer untrackSocket(client.socket);

    var rbuf: [1024]u8 = undefined;
    var reader = client.reader(io, &rbuf);

    // empty writer buffer => writes go straight through
    var writer = client.writer(io, &.{});

    // Informational, so machine clients skip it; a human gets a hint instead of
    // connecting to silence and wondering whether anything is listening.
    try writer.interface.writeAll("# qnnt registry, type 'help' for commands\n");

    while (!isShuttingDown()) {
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

// The registry lives on a well-known port. Every node contends for it; whoever binds
// first plays the registry role, the rest stand by. The bind must therefore be mutually
// exclusive, which rules out `IpAddress.listen`'s `reuse_address`: its docstring says it
// sets SO_REUSEADDR *and* SO_REUSEPORT, and SO_REUSEPORT is precisely the option that
// lets two live listeners share a port — it would silently dissolve the election.
//
// But leaving both off has its own cost: a lingering TIME_WAIT socket on the port blocks
// the next bind, and this node's own shutdown creates one whenever it closes an accepted
// registry connection (the server closing first is what puts *its* end in TIME_WAIT).
// One such socket is enough to lock every node out for an MSL — around 15 s here — which
// stalls failover and makes a restarted node unable to take the role it just released.
//
// SO_REUSEADDR alone is exactly the fix: it permits binding over TIME_WAIT while two
// listeners on one address still collide. Since std bundles the two options together,
// the listener is opened by hand in `listenRegistry`.
pub const default_registry_port = 2222;

// Latched once per `nodeRun` and fixed for that node's lifetime: the registry thread, the
// publishers' registration loops and every subscriber's resolver all hold it, so moving it
// under them would be incoherent.
//
// No environment lookup here. Zig 0.16 gives a library no ambient access to the
// environment — `Environ` has to be handed down from `main` — and that is the right shape
// anyway: the library takes a port, and the caller decides whether it came from a flag, an
// env var or a constant.
var registry_port: u16 = default_registry_port;
var node_running = false;

/// Set the port the next `run()` will use. Returns false while a node is running, since
/// the value is already in use by its workers; stop the node first.
///
/// Distinct ports give fully independent registries in one machine, which is what makes it
/// possible to run tests and examples side by side instead of having them fight over one
/// well-known port.
pub fn setRegistryPortFn(port: u16) bool {
    if (node_running) return false;
    registry_port = port;
    return true;
}

/// The port in effect — the one a running node is using, or the one the next `run()` will.
pub fn currentRegistryPort() u16 {
    return registry_port;
}

// How often standby nodes re-check the port, publishers refresh their registration,
// and subscribers re-poll for a topic URI.
const registry_probe_interval_ms = 2000;

// Open the registry listener with SO_REUSEADDR but NOT SO_REUSEPORT; see the note on
// `registry_port` for why std's one-flag-for-both is unusable here. Everything after
// this is ordinary `net.Server`: accept, shutdown and deinit only use the handle.
fn listenRegistry(addr: net.IpAddress) !net.Server {
    const posix = std.posix;

    const family = Io.Threaded.posixAddressFamily(&addr);
    // Only Linux accepts SOCK_CLOEXEC inside socket(); the constant exists on macOS but
    // the call rejects it with EPROTONOSUPPORT, so `@hasDecl` is the wrong test. Where it
    // is unavailable the listener is inheritable across exec — worth knowing before this
    // library is used from a process that forks and execs.
    const cloexec: u32 = if (@import("builtin").os.tag == .linux) posix.SOCK.CLOEXEC else 0;
    const flags: u32 = posix.SOCK.STREAM | cloexec;

    const fd_rc = posix.system.socket(family, flags, 0);
    if (posix.errno(fd_rc) != .SUCCESS) return error.SocketOpenFailed;
    const fd: posix.socket_t = @intCast(fd_rc);
    errdefer _ = posix.system.close(fd);

    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

    var storage: Io.Threaded.PosixAddress = undefined;
    const addr_len = Io.Threaded.addressToPosix(&addr, &storage);

    switch (posix.errno(posix.system.bind(fd, &storage.any, addr_len))) {
        .SUCCESS => {},
        .ADDRINUSE => return error.AddressInUse, // another node holds the role
        else => return error.BindFailed,
    }
    switch (posix.errno(posix.system.listen(fd, registry_backlog))) {
        .SUCCESS => {},
        .ADDRINUSE => return error.AddressInUse,
        else => return error.ListenFailed,
    }

    return .{
        .socket = .{ .handle = fd, .address = addr },
        .options = if (net.Server.AcceptOptions != void) .{ .mode = .stream, .protocol = .tcp },
    };
}

const registry_backlog = 128;

fn registryRun() void {
    // Whether the "standing by" notice has been printed for the current contention.
    // Printing every probe would be noise; printing nothing at all is worse — a node
    // silently failing to bind is indistinguishable from one that simply is not the
    // registry, which hid an AddressInUse loop for a long time.
    var announced_standby = false;

    while (!isShuttingDown()) {
        const addr: net.IpAddress = net.IpAddress.parse("127.0.0.1", registry_port) catch |err| {
            std.debug.print("registry address parse failed: {}\n", .{err});
            return;
        };

        var server = listenRegistry(addr) catch |err| {
            // Another node already holds the registry role; stand by and re-probe.
            if (!announced_standby) {
                std.debug.print("registry standing by (port {d}: {})\n", .{ registry_port, err });
                announced_standby = true;
            }
            if (!sleepMsInterruptible(registry_probe_interval_ms)) return;
            continue;
        };
        defer server.deinit(io); // released before we re-contend for the role

        // Tracked so a shutdown can break the accept below. Untracked before the
        // deinit above, so the handle is never stale while it is listed.
        if (!trackSocket(server.socket, .listener)) return;
        defer untrackSocket(server.socket);

        announced_standby = false;
        registry_since_us.store(@intCast(nowMicrosFn()), .monotonic);
        std.debug.print("registry role acquired, listening on port {}\n", .{addr.getPort()});

        // Serve until the listener fails, then fall through to release the port
        // and re-enter contention.
        while (true) {
            const client = server.accept(io) catch |err| {
                // A shutdown breaking our own listener is not a failure worth
                // reporting; anything else means the role is being lost.
                if (isShuttingDown()) return;
                std.debug.print("registry accept failed ({}); releasing role\n", .{err});
                break;
            };

            if (isShuttingDown()) {
                client.close(io);
                return;
            }

            if (!spawnWorker(handleRegistryClient, .{client})) {
                client.close(io);
                // spawnWorker also refuses once a shutdown is under way, and by then the
                // listener has already been woken, so going back to accept would block
                // for good.
                if (isShuttingDown()) return;
                std.debug.print("error spawning registry client handler\n", .{});
            }
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
                // Close before dropping it: swapRemove alone leaked the descriptor.
                list_ptr.items[idx].client.close(io);
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
// cost and wake-up jitter don't accumulate into drift. A period of 0 is unpaced.
fn publisherSchedule(topic: []const u8, source: Qnnt.SourceHandler, period_us: u64, context: ?*anyopaque) void {
    var next_us: u64 = @intCast(nowMicrosFn());

    while (!isShuttingDown()) {
        // Unpaced has no deadline to wait for, so it skips the clock read as well as
        // the sleep — the read is the only remaining per-tick overhead at that point.
        if (period_us != 0) {
            next_us += period_us;
            const now_us: u64 = @intCast(nowMicrosFn());

            if (next_us > now_us) {
                if (!sleepUsInterruptible(next_us - now_us)) return;
            } else if (now_us - next_us >= period_us) {
                // More than a full period behind (slow callback, scheduling hiccup):
                // give up on the missed ticks and resynchronize, rather than firing a
                // burst to catch up on a backlog that only grows.
                next_us = now_us;
            }
        }

        if (source(topic, context)) |payload| {
            publishAll(topic, payload) catch |err| {
                std.debug.print("error publishing on {s}: {}\n", .{ topic, err });
            };
        }
    }
}

fn nodePublish(topic: []const u8, source: ?Qnnt.SourceHandler, period_us: u64, context: ?*anyopaque) !void {
    // Bind to loopback with an ephemeral port (0); the OS fills in the real port,
    // which we read back from the socket and register with the discovery directory.
    const addr: net.IpAddress = try .parse("127.0.0.1", 0);

    var server = try addr.listen(io, .{ .reuse_address = false });
    defer server.deinit(io);

    // Tracked so shutdown can break the accept loop below.
    if (!trackSocket(server.socket, .listener)) return;
    defer untrackSocket(server.socket);

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
    if (!spawnWorker(registerLoop, .{ topic, endpoint })) {
        std.debug.print("failed to spawn register loop for {s}\n", .{topic});
    }

    // Self-paced publishing, if the caller supplied a source. Started only once the
    // listener is up and registered, so no tick can fire before subscribers have
    // somewhere to connect.
    if (source) |src| {
        if (!spawnWorker(publisherSchedule, .{ topic, src, period_us, context })) {
            std.debug.print("failed to spawn scheduler for {s}\n", .{topic});
        }
    }

    while (!isShuttingDown()) {
        const client = server.accept(io) catch |err| {
            if (isShuttingDown()) return; // our own shutdown broke the accept
            return err;
        };

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

    // Short-lived, but it blocks on a read: tracked so a shutdown mid-exchange does
    // not hold the worker until the peer answers.
    if (!trackSocket(conn.socket, .stream)) return error.ShuttingDown;
    defer untrackSocket(conn.socket);

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
    while (!isShuttingDown()) {
        registerOnce(topic, endpoint) catch {}; // registry not up yet / mid-failover
        if (!sleepMsInterruptible(registry_probe_interval_ms)) return;
    }
}

// Ask the registry (well-known port) where `topic` is published and return the
// publisher's endpoint. Fails if the registry is unreachable or doesn't know the
// topic yet, so callers are expected to retry.
fn resolveTopic(topic: []const u8) !net.IpAddress {
    const reg: net.IpAddress = try net.IpAddress.parse("127.0.0.1", registry_port);
    var conn = try reg.connect(io, .{ .mode = .stream });
    defer conn.close(io);

    // Short-lived, but it blocks on a read: tracked so a shutdown mid-exchange does
    // not hold the worker until the peer answers.
    if (!trackSocket(conn.socket, .stream)) return error.ShuttingDown;
    defer untrackSocket(conn.socket);

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
fn subscribeLoop(topic: []const u8, handler: Qnnt.MessageHandler, context: ?*anyopaque) void {
    while (!isShuttingDown()) {
        const endpoint = resolveTopic(topic) catch {
            if (!sleepMsInterruptible(registry_probe_interval_ms)) return;
            continue;
        };

        var stream = endpoint.connect(io, .{ .mode = .stream }) catch {
            if (!sleepMsInterruptible(registry_probe_interval_ms)) return;
            continue;
        };
        defer stream.close(io);

        // Tracked so shutdown breaks the blocking read below.
        if (!trackSocket(stream.socket, .stream)) return;
        defer untrackSocket(stream.socket);

        std.debug.print("subscribed to {s} @ tcp://{f}\n", .{ topic, endpoint });

        var rbuf: [1024]u8 = undefined;
        var reader = stream.reader(io, &rbuf);
        while (true) {
            const msg = reader.interface.takeDelimiterInclusive('\n') catch break;
            handler(topic, msg, context); // delivered on this thread; msg valid only for the call
        }

        // Publisher closed (or we are shutting down); re-resolve and reconnect.
        if (!sleepMsInterruptible(registry_probe_interval_ms)) return;
    }
}

pub fn subscribeRun(topic: []const u8, handler: Qnnt.MessageHandler, context: ?*anyopaque) bool {
    if (!spawnWorker(subscribeLoop, .{ topic, handler, context })) {
        std.debug.print("error spawning subscriber thread for {s}\n", .{topic});
        return false;
    }
    return true;
}

// A declared TLD length is 8 attacker-controlled bytes, so cap what one frame may ask
// this process to buffer.
const max_frame_bytes = 1 << 20;

// As `subscribeLoop`, but the stream carries TLD frames instead of newline-delimited
// text. TLD frames are self-delimiting, so this needs no delimiter and imposes no
// restriction on payload bytes.
//
// A topic is one or the other, not both: the framing is a property of the stream, so a
// producer publishing TLD must be read with `subscribeFrames`, and a producer
// publishing text lines with `subscribe`.
fn subscribeFramesLoop(topic: []const u8, handler: Qnnt.FrameHandler, context: ?*anyopaque) void {
    // One buffer per subscription, reused for every frame, holding at most a frame.
    var frame_buf: std.ArrayList(u8) = .empty;
    defer frame_buf.deinit(allocator);

    while (!isShuttingDown()) {
        const endpoint = resolveTopic(topic) catch {
            if (!sleepMsInterruptible(registry_probe_interval_ms)) return;
            continue;
        };

        var stream = endpoint.connect(io, .{ .mode = .stream }) catch {
            if (!sleepMsInterruptible(registry_probe_interval_ms)) return;
            continue;
        };
        defer stream.close(io);

        // Tracked so shutdown breaks the blocking frame read below.
        if (!trackSocket(stream.socket, .stream)) return;
        defer untrackSocket(stream.socket);

        std.debug.print("subscribed to {s} @ tcp://{f} (tld)\n", .{ topic, endpoint });

        var rbuf: [4096]u8 = undefined;
        var reader = stream.reader(io, &rbuf);
        while (true) {
            const frame = Tld.readFrame(&reader.interface, allocator, &frame_buf, max_frame_bytes) catch |err| {
                // EndOfStream is the publisher going away, which is routine. Anything
                // else means the stream is not what we think it is, and silence there
                // would leave a mismatched producer looking like a dead one.
                if (err != error.EndOfStream) {
                    std.debug.print("tld read error on {s}: {}\n", .{ topic, err });
                }
                break;
            };
            handler(topic, frame, context);
        }

        if (!sleepMsInterruptible(registry_probe_interval_ms)) return;
    }
}

// ---------------------------------------------------------------- buffered subscription
//
// A second delivery mode: instead of invoking a callback on the subscriber's thread,
// copy each message into a queue the application drains on its own thread.
//
// This exists for callers on the other side of a language boundary. Crossing one per
// message costs far more than the copy — a ctypes callback is microseconds against a
// ~30 ns decode — so draining a thousand at a time amortises it away. It also sidesteps
// calling into a host runtime from a thread that runtime has never heard of, which under
// CPython means acquiring the GIL from a foreign thread and having nowhere to put an
// exception. With a queue, no library thread ever calls out.
//
// One queue serves every buffered subscription, so an application has a single drain
// point; each message carries the topic it arrived on. Drain from one thread only.
//
// Message buffers are recycled rather than reallocated: `poll` swaps a ring slot's buffer
// with a staging slot's, so steady-state delivery allocates nothing.

pub const QueuedMessage = struct {
    /// The topic string handed to `subscribeQueue` — the caller's, not a copy.
    topic: []const u8,
    /// Owned by the queue and valid until the next `poll` call, which recycles it.
    data: []const u8,
    received_us: u64,
};

const QueueSlot = struct {
    topic: []const u8 = &.{},
    buf: std.ArrayList(u8) = .empty,
    received_us: u64 = 0,
};

const queue_default_capacity = 1024;

var queue_ring: []QueueSlot = &.{};
var queue_head: usize = 0;
var queue_count: usize = 0;
var queue_dropped: u64 = 0;
var queue_mutex: Io.Mutex = .init;
var queue_staging: std.ArrayList(QueueSlot) = .empty;

// Bumped on every push and used as the futex word, so a waiting drainer wakes on arrival
// rather than polling a flag.
var queue_seq: std.atomic.Value(u32) = .init(0);

fn queueEnsureCapacity(capacity: usize) !void {
    if (queue_ring.len >= capacity) return;

    const grown = try allocator.alloc(QueueSlot, capacity);
    // Carry the existing entries over in order, so reserving more room mid-run does not
    // reorder or drop what is already queued.
    for (grown, 0..) |*slot, i| {
        slot.* = if (i < queue_count) queue_ring[(queue_head + i) % queue_ring.len] else .{};
    }
    if (queue_ring.len > 0) allocator.free(queue_ring);
    queue_ring = grown;
    queue_head = 0;
}

/// Reserve queue room before subscribing. Optional: the first `subscribeQueue` reserves
/// `queue_default_capacity` if nothing else has.
pub fn queueReserve(capacity: usize) bool {
    queue_mutex.lockUncancelable(io);
    defer queue_mutex.unlock(io);

    queueEnsureCapacity(capacity) catch return false;
    return true;
}

/// How many messages have been dropped because the queue was full. A drainer that keeps
/// up never sees this move; one that does not needs to know rather than guess.
pub fn queueDroppedCount() u64 {
    queue_mutex.lockUncancelable(io);
    defer queue_mutex.unlock(io);
    return queue_dropped;
}

// The handler behind every buffered subscription. `context` is the topic slice, boxed by
// subscribeQueue, so one handler serves them all.
fn queuePush(topic: []const u8, msg: []const u8, _: ?*anyopaque) void {
    queue_mutex.lockUncancelable(io);
    defer queue_mutex.unlock(io);

    if (queue_ring.len == 0) return; // never reserved; nothing to push into

    if (queue_count == queue_ring.len) {
        // Full. Drop the newest rather than the oldest: that keeps what has already been
        // accepted contiguous, so a consumer tracking sequence numbers sees a clean gap
        // at the end instead of a hole in the middle.
        queue_dropped += 1;
        return;
    }

    const slot = &queue_ring[(queue_head + queue_count) % queue_ring.len];
    slot.buf.clearRetainingCapacity();
    slot.buf.appendSlice(allocator, msg) catch {
        queue_dropped += 1;
        return;
    };
    slot.topic = topic;
    slot.received_us = @intCast(nowMicrosFn());
    queue_count += 1;

    _ = queue_seq.fetchAdd(1, .monotonic);
    io.futexWake(u32, &queue_seq.raw, 1);
}

/// Which reader a queued subscription uses. Framing is a property of the stream, not of
/// the delivery mode, so the queue has to be told: a TLD producer read as text would be
/// chopped at every 0x0A byte inside a payload, which is not a hypothetical — it is what
/// happens the first time a buffer holds a newline.
pub const QueueMode = enum { text, frames };

/// Subscribe to `topic`, delivering into the shared queue instead of a callback. For
/// `.frames` the queued bytes are the complete TLD frame, ready to hand to `Tld.decode`.
pub fn subscribeQueueRun(topic: []const u8, mode: QueueMode) bool {
    if (!queueReserveDefault()) return false;
    return switch (mode) {
        .text => subscribeRun(topic, queuePush, null),
        .frames => subscribeFramesRun(topic, queuePushFrame, null),
    };
}

fn queuePushFrame(topic: []const u8, frame: Tld.Frame, context: ?*anyopaque) void {
    // Queue the whole frame, prefix included, so a consumer can decode it as it stands.
    queuePush(topic, frame.raw, context);
}

// Apply the default capacity only if nothing has been reserved. Reserving
// unconditionally would quietly override a deliberate `reserveQueue(2)` with 1024, since
// the ring only ever grows — the caller asked for a small queue precisely to feel
// backpressure early.
fn queueReserveDefault() bool {
    queue_mutex.lockUncancelable(io);
    defer queue_mutex.unlock(io);

    if (queue_ring.len > 0) return true;
    queueEnsureCapacity(queue_default_capacity) catch return false;
    return true;
}

/// Move up to `out.len` messages out of the queue. Returns the slice actually filled,
/// whose `data` stays valid until the next call. `timeout_ms` of 0 never blocks and -1
/// blocks until something arrives.
pub fn queuePoll(out: []QueuedMessage, timeout_ms: i32) []QueuedMessage {
    if (out.len == 0) return out[0..0];

    queue_mutex.lockUncancelable(io);
    defer queue_mutex.unlock(io);

    if (queue_count == 0 and timeout_ms != 0) {
        // Read the sequence before unlocking so a push landing in the gap is not missed:
        // futexWaitTimeout returns immediately when the word has already moved on.
        const observed = queue_seq.load(.monotonic);
        queue_mutex.unlock(io);
        const timeout: Io.Timeout = if (timeout_ms < 0)
            .none
        else
            .{ .duration = .{
                // .awake is the monotonic clock here, the same one sleepMs uses: a
                // timeout must not be dragged around by wall-clock adjustments.
                .raw = Io.Duration.fromMilliseconds(timeout_ms),
                .clock = .awake,
            } };
        io.futexWaitTimeout(u32, &queue_seq.raw, observed, timeout) catch {};
        queue_mutex.lockUncancelable(io);
    }

    const take = @min(out.len, queue_count);
    if (take == 0) return out[0..0];

    queue_staging.ensureTotalCapacity(allocator, take) catch return out[0..0];
    while (queue_staging.items.len < take) queue_staging.appendAssumeCapacity(.{});

    for (0..take) |i| {
        const src = &queue_ring[(queue_head + i) % queue_ring.len];
        const dst = &queue_staging.items[i];

        // Swap buffers rather than copying: the ring slot inherits the staging slot's
        // buffer and its capacity, so nothing is allocated once things are warm.
        std.mem.swap(std.ArrayList(u8), &src.buf, &dst.buf);
        dst.topic = src.topic;
        dst.received_us = src.received_us;

        out[i] = .{ .topic = dst.topic, .data = dst.buf.items, .received_us = dst.received_us };
    }

    queue_head = (queue_head + take) % queue_ring.len;
    queue_count -= take;
    return out[0..take];
}

fn queueDeinit() void {
    queue_mutex.lockUncancelable(io);
    defer queue_mutex.unlock(io);

    for (queue_ring) |*slot| slot.buf.deinit(allocator);
    if (queue_ring.len > 0) allocator.free(queue_ring);
    queue_ring = &.{};

    for (queue_staging.items) |*slot| slot.buf.deinit(allocator);
    queue_staging.clearAndFree(allocator);

    queue_head = 0;
    queue_count = 0;
    queue_dropped = 0;
}

pub fn subscribeFramesRun(topic: []const u8, handler: Qnnt.FrameHandler, context: ?*anyopaque) bool {
    if (!spawnWorker(subscribeFramesLoop, .{ topic, handler, context })) {
        std.debug.print("error spawning tld subscriber thread for {s}\n", .{topic});
        return false;
    }
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

// Ask the node to stop, from Ctrl-C or SIGTERM. An atomic store is async-signal-safe,
// which is all this does — no prints, since std.debug.print takes a lock and is not.
//
// This used to call `std.c._exit(0)`, because Io.Threaded's signal machinery swallows
// SIGINT and a node would otherwise keep holding the registry port with no standby able
// to take over. Now that stopping is a real operation, the flag is enough: workers wind
// themselves up, and the application's own `deinit` releases the port properly. It also
// stops the library from killing its host, which `_exit` inside a shared library would.
fn onShutdownSignal(_: std.posix.SIG) callconv(.c) void {
    shutting_down.store(true, .monotonic);
}

/// Install handlers for SIGINT and SIGTERM so they request a stop. Opt-in, and never
/// called by `run()`: taking over a process's signal disposition is the host
/// application's decision, not a library's, and doing it silently would clobber a
/// handler the host had already installed — under a Python binding it would break
/// KeyboardInterrupt outright.
///
/// Call it AFTER `run()`. Io.Threaded installs its own signal setup during init, so
/// handlers registered before that get overwritten by it.
pub fn installShutdownHandlers() void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onShutdownSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
}

pub fn nodeRun() bool {
    // Cleared here rather than only in nodeDeinit, so a node can be started again after
    // being stopped — which is the whole point of having a shutdown path.
    shutting_down.store(false, .monotonic);
    registry_since_us.store(0, .monotonic);
    node_running = true;

    io_impl = .init(allocator, .{});
    io = io_impl.io();

    // Signal handlers are deliberately NOT installed here; see installShutdownHandlers.

    if (!spawnWorker(registryRun, .{})) {
        std.debug.print("error spawning registry thread\n", .{});
        return false;
    }
    sleepMsFn(5);
    return true;
}

// Start publishing `topic`. `source` and `period_us` are optional and go together:
// pass both to have the library drive the topic from its own scheduler thread, or both
// null to publish manually via `publish()`. Supplying only one of the two is a caller
// mistake and is reported rather than silently ignored.
//
// The interval is given as a period in microseconds rather than a frequency, so it is
// the same unit the scheduler paces to: every rate the clock can express is reachable,
// and there is no rounding step between what the caller asks for and what it gets.
//
// A period of 0 means unpaced — publish as fast as the machine manages, with no sleep
// between ticks. That is a real mode rather than a degenerate one: the smallest
// non-zero period still sleeps every tick, and a 1 us sleep costs several microseconds
// of syscall, so 0 is measurably faster than 1. It also busies a core, hence the
// notice at startup.
pub fn publisherRun(topic: []const u8, source: ?Qnnt.SourceHandler, period_us: ?u64, context: ?*anyopaque) bool {
    if ((source == null) != (period_us == null)) {
        std.debug.print("publisher {s}: source and period must be given together\n", .{topic});
        return false;
    }

    const period = period_us orelse 0;
    if (source != null and period == 0) {
        std.debug.print("publisher {s}: unpaced (period 0), will busy one core\n", .{topic});
    }

    if (!spawnWorker(nodePublish, .{ topic, source, period, context })) {
        std.debug.print("error spawning publisher thread for {s}\n", .{topic});
        return false;
    }
    sleepMsFn(5);
    return true;
}

// Stop the node and release everything it holds. Safe to call once per `nodeRun`, and a
// node may be started again afterwards.
//
// The ordering is the whole point: the workers must be *gone* before anything they touch
// is freed. Signal them, break the calls they are blocked in, join them, and only then
// tear down the maps and `io`. Doing this in the other order — which is what this
// function used to do — frees `io` out from under threads still parked in `accept`.
pub fn nodeDeinit() void {
    shutting_down.store(true, .monotonic);
    breakLiveSockets();
    breakSubscriberStreams();
    joinWorkers();

    // Past this point no worker exists, so the locks below are uncontended and only
    // taken to keep the access pattern honest.

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
        while (it.next()) |entry| {
            // Close the delivery connections too. Leaving these open leaked a socket per
            // subscriber per node lifetime, which only stayed invisible because a node
            // never used to outlive its process.
            for (entry.value_ptr.items) |node| node.client.close(io);
            entry.value_ptr.deinit(allocator);
        }
        subscribers.clearAndFree();
    }

    {
        live_sockets_mutex.lockUncancelable(io);
        defer live_sockets_mutex.unlock(io);
        live_sockets.clearAndFree(allocator);
    }

    queueDeinit();

    io_impl.deinit();
    node_running = false;
}

test {
    _ = @import("./qnnt.test.zig");
}
