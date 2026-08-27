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
var directory: std.StringHashMap(net.IpAddress) = .init(allocator);
var directory_mutex: Io.Mutex = .init;

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

fn clientCommand(command: []u8) ![]const u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);

    if (std.mem.startsWith(u8, command, "list")) {
        directory_mutex.lockUncancelable(io);
        defer directory_mutex.unlock(io);
        var it = directory.iterator();
        while (it.next()) |entry| {
            try buffer.print(allocator, "{s} @ tcp://{f}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    } else if (std.mem.startsWith(u8, command, "pub")) {
        // "pub <topic> tcp://<host>:<port>" — a publisher registering its endpoint.
        const rest = std.mem.trim(u8, command[3..], " \r\n");
        const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse {
            try buffer.print(allocator, "error: usage: pub <topic> <uri>\n", .{});
            return buffer.toOwnedSlice(allocator);
        };
        const topic = rest[0..sp];
        const endpoint = parseTcpUri(rest[sp + 1 ..]) catch {
            try buffer.print(allocator, "error: malformed uri\n", .{});
            return buffer.toOwnedSlice(allocator);
        };
        try registerTopic(topic, endpoint);
        try buffer.print(allocator, "ok\n", .{});
    } else if (std.mem.startsWith(u8, command, "sub")) {
        // Hand the subscriber the complete URI of the topic's publisher so it
        // can connect there directly.
        const topic = std.mem.trim(u8, command[4..], " \r\n");
        directory_mutex.lockUncancelable(io);
        defer directory_mutex.unlock(io);
        if (directory.get(topic)) |endpoint| {
            try buffer.print(allocator, "tcp://{f}\n", .{endpoint});
        } else {
            try buffer.print(allocator, "error: topic {s} not found\n", .{topic});
        }
    } else {
        try buffer.print(allocator, "commands: list | pub <topic> <uri> | sub <topic>\n", .{});
    }

    return buffer.toOwnedSlice(allocator); // caller must free
}

// Record (or refresh) a topic's publisher endpoint in the discovery directory.
// The topic key arrives in a transient network buffer, so it is heap-owned on
// first insert and left untouched on refresh.
fn registerTopic(topic: []const u8, endpoint: net.IpAddress) !void {
    directory_mutex.lockUncancelable(io);
    defer directory_mutex.unlock(io);

    const gop = try directory.getOrPut(topic);
    if (!gop.found_existing) {
        gop.key_ptr.* = allocator.dupe(u8, topic) catch |err| {
            _ = directory.remove(topic);
            return err;
        };
    }
    gop.value_ptr.* = endpoint;
}

fn handleRegistryClient(client: Stream) !void {
    defer client.close(io);

    var rbuf: [1024]u8 = undefined;
    var reader = client.reader(io, &rbuf);

    // empty writer buffer => writes go straight through
    var writer = client.writer(io, &.{});

    while (true) {
        const chunk = reader.interface.takeDelimiterInclusive('\n') catch |err| {
            if (err == error.EndOfStream) return; // client closed
            return err;
        };
        const result = try clientCommand(chunk);
        try writer.interface.writeAll(result);
        allocator.free(result);
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
            };
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
            try list_ptr.append(allocator, .{ .client = client });
        }
    }
}

// Send one "pub <topic> <uri>" registration to whichever node holds the registry.
fn registerOnce(topic: []const u8, endpoint: net.IpAddress) !void {
    const reg: net.IpAddress = try net.IpAddress.parse("127.0.0.1", registry_port);
    var conn = try reg.connect(io, .{ .mode = .stream });
    defer conn.close(io);

    var cmdbuf: [512]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmdbuf, "pub {s} tcp://{f}\n", .{ topic, endpoint });
    var writer = conn.writer(io, &.{});
    try writer.interface.writeAll(cmd);

    var rbuf: [64]u8 = undefined;
    var reader = conn.reader(io, &rbuf);
    _ = reader.interface.takeDelimiterInclusive('\n') catch {}; // best-effort ack
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
    const line = try reader.interface.takeDelimiterInclusive('\n');
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
        while (it.next()) |entry| allocator.free(entry.key_ptr.*); // owned keys
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
