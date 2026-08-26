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

// Per-topic state: where the publisher accepts subscribers (handed out by the
// registry's `sub` command) plus the live subscriber connections.
const Topic = struct {
    endpoint: net.IpAddress,
    subscribers: std.ArrayList(QnntNode),
};

// `registry` is touched from the main thread (publishAll), each publisher thread
// (nodePublish) and each registry-client thread (clientCommand). Every access —
// structural (put/getPtr/iterate) and the subscriber lists it hands out pointers
// into — must hold `registry_mutex`.
var registry: std.StringHashMap(Topic) = .init(allocator);
var registry_mutex: Io.Mutex = .init;

pub const Qnnt = struct {
    pub const run = &nodeRun;
    pub const runPublisher = &publisherRun;
    pub const publish = &publishAll;
    pub const deinit = &nodeDeinit;
    pub const sleepMs = &sleepMsFn;
};

fn clientCommand(command: []u8) ![]const u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);

    if (std.mem.startsWith(u8, command, "list")) {
        registry_mutex.lockUncancelable(io);
        defer registry_mutex.unlock(io);
        var it = registry.iterator();
        while (it.next()) |entry| {
            try buffer.print(allocator, "{s} - {} subs @ tcp://{f}\n", .{
                entry.key_ptr.*,
                entry.value_ptr.subscribers.items.len,
                entry.value_ptr.endpoint,
            });
        }
    } else if (std.mem.startsWith(u8, command, "pub")) {
        const params = std.mem.trim(u8, command[4..], " \r\n");
        try buffer.print(allocator, "{s}\n", .{ params });
    } else if (std.mem.startsWith(u8, command, "sub")) {
        // Hand the subscriber the complete URI of the topic's publisher so it
        // can connect there directly.
        const topic = std.mem.trim(u8, command[4..], " \r\n");
        registry_mutex.lockUncancelable(io);
        defer registry_mutex.unlock(io);
        if (registry.get(topic)) |t| {
            try buffer.print(allocator, "tcp://{f}\n", .{ t.endpoint });
        } else {
            try buffer.print(allocator, "error: topic {s} not found\n", .{ topic });
        }
    } else {
        try buffer.print(allocator, "commands: list | pub <topic> <data> | sub <topic>\n", .{});
    }

    return buffer.toOwnedSlice(allocator); // caller must free
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
        std.debug.print("echoing {s}", .{chunk});
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

// How often a standby node re-checks whether the port has freed up, so it can
// take over if the node currently holding the registry role dies.
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
    // the subscriber list stable while a publisher thread may be appending to it.
    registry_mutex.lockUncancelable(io);
    defer registry_mutex.unlock(io);

    if (registry.getPtr(topic)) |t| {
        // Iterate backward so a failed-write swapRemove only ever touches
        // indices we've already visited.
        var idx = t.subscribers.items.len;
        while (idx > 0) {
            idx -= 1;
            var writer = t.subscribers.items[idx].client.writer(io, &.{});
            writer.interface.writeAll(data) catch |err| {
                std.debug.print("error writing: {}\n", .{ err });
                _ = t.subscribers.swapRemove(idx);
            };
        }
    } else {
        std.debug.print("topic {s} not found\n", .{ topic });
    }
}

fn nodePublish(topic: []const u8) !void {
    // Bind to loopback with an ephemeral port (0); the OS fills in the real port,
    // which we read back from the socket and hand out via the registry.
    const addr: net.IpAddress = try .parse("127.0.0.1", 0);

    var server = try addr.listen(io, .{ .reuse_address = false });
    defer server.deinit(io);

    const endpoint = server.socket.address; // resolved, including the ephemeral port

    {
        registry_mutex.lockUncancelable(io);
        defer registry_mutex.unlock(io);
        try registry.put(topic, .{ .endpoint = endpoint, .subscribers = .empty });
    }

    std.debug.print("publisher {s} listening on tcp://{f}\n", .{ topic, endpoint });

    while (true) {
        const client = try server.accept(io);

        registry_mutex.lockUncancelable(io);
        defer registry_mutex.unlock(io);
        if (registry.getPtr(topic)) |t| {
            try t.subscribers.append(allocator, .{ .client = client });
        }
    }
}

fn sleepMsFn(ms: u64) void {
    io.sleep(Io.Duration.fromMilliseconds(@intCast(ms)), .awake) catch {};
}

pub fn nodeRun() bool {
    io_impl = .init(allocator, .{});
    io = io_impl.io();

    _ = std.Thread.spawn(.{}, registryRun, .{}) catch |err| {
        std.debug.print("error spawning registry thread: {}\n", .{err});
        return false;
    };
    sleepMsFn(5);
    return true;
}

pub fn publisherRun(topic: []const u8) bool {
    _ = std.Thread.spawn(.{}, nodePublish, .{ topic }) catch |err| {
        std.debug.print("error spawning publisher thread for {s}: {}\n", .{topic, err});
        return false;
    };
    sleepMsFn(5);
    return true;
}

pub fn nodeDeinit() void {
    registry_mutex.lockUncancelable(io);
    var iterator = registry.iterator();
    while (iterator.next()) |entry| {
        entry.value_ptr.subscribers.deinit(allocator);
    }
    registry.clearAndFree();
    registry_mutex.unlock(io); // must release before io_impl is torn down

    io_impl.deinit();
}

test {
    _ = @import("./qnnt.test.zig");
}
