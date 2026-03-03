const std = @import("std");
const net = std.net;

const allocator = std.heap.page_allocator;

const QnntNode = struct {
    client: net.Server.Connection,
};

pub const Qnnt = struct {
    pub var registry: std.StringHashMap(std.ArrayList(QnntNode)) = .init(allocator);
    pub const run = &nodeRun;
    pub const runPublisher = &publisherRun;
    pub const publish = &publishAll;
    pub const deinit = &nodeDeinit;
};

fn clientCommand(command: []u8) ![]const u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);

    if (std.mem.startsWith(u8, command, "list")) {
        var it = Qnnt.registry.iterator();
        while (it.next()) |entry| {
            try buffer.writer(allocator).print("{s} - {}\n", .{ entry.key_ptr.*, entry.value_ptr.*.items.len });
        }
    } else if (std.mem.startsWith(u8, command, "pub")) {
        const params = std.mem.trim(u8, command[4..], " ");
        try buffer.writer(allocator).print("{s}\n", .{ params });
    } else if (std.mem.startsWith(u8, command, "sub")) {
        try buffer.writer(allocator).print("{s}\n", .{ "subscribing" });
    } else {
        try buffer.writer(allocator).print("{s}\n", .{ "command list" });
    }

    return buffer.toOwnedSlice(allocator); // caller must free
}

fn handleRegistryClient(client: net.Server.Connection) !void {
    defer client.stream.close();

    var rbuf: [1024]u8 = undefined;
    var reader = client.stream.reader(&rbuf);

    // empty writer buffer => writes go straight through
    var writer = client.stream.writer(&.{});

    while (true) {
        const chunk = reader.interface().takeDelimiterInclusive('\n') catch |err| {
            if (err == error.EndOfStream) return; // client closed
            return err;
        };
        std.debug.print("echoing {s}", .{chunk});
        const result = try clientCommand(chunk);
        try writer.interface.writeAll(result);
        allocator.free(result);
    }
}

fn registryRun() !void {
    // listen on 127.0.0.1, choose a free port (0)
    const ip4 = try net.Ip4Address.parse("127.0.0.1", 2222);
    const addr = net.Address{ .in = ip4 };

    //var server = try addr.listen(.{ .reuse_address = true });
    var server = try addr.listen(.{ .reuse_address = false });
    defer server.deinit();

    std.debug.print("listening on port {}\n", .{server.listen_address.getPort()});

    while (true) {
        const client = try server.accept();
        // handle in a thread; drop spawn if you want single-threaded
        _ = try std.Thread.spawn(.{}, handleRegistryClient, .{client});
    }
}

pub fn publishAll(topic: []const u8, data: []const u8) !void {
    if (Qnnt.registry.getPtr(topic)) |list_ptr| {
        for (list_ptr.items, 0..) |*node, idx| {
            var writer = node.client.stream.writer(&.{});
            writer.interface.writeAll(data) catch |err| {
                std.debug.print("error writing: {}\n", .{ err });
                _ = list_ptr.swapRemove(idx);
            };
        }
    } else {
        std.debug.print("topic {s} not found\n", .{ topic });
    }
}

fn nodePublish(topic: []const u8) !void {
    // listen on 127.0.0.1, choose a free port (0)
    const ip4 = try net.Ip4Address.parse("0.0.0.0", 0);
    const addr = net.Address{ .in = ip4 };

    //var server = try addr.listen(.{ .reuse_address = true });
    var server = try addr.listen(.{ .reuse_address = false });
    defer server.deinit();

    std.debug.print("listening on port {}\n", .{server.listen_address.getPort()});

    try Qnnt.registry.put(topic, .empty);

    while (true) {
        const client = try server.accept();

        if (Qnnt.registry.getPtr(topic)) |list_ptr| {
            try list_ptr.append(allocator, .{ .client = client, });
        }
    }
}

pub fn nodeRun() !void {
    _ = try std.Thread.spawn(.{}, registryRun, .{});
    std.Thread.sleep(5 * std.time.ns_per_ms);
}

pub fn publisherRun(topic: []const u8) !void {
    _ = try std.Thread.spawn(.{}, nodePublish, .{ topic });
    std.Thread.sleep(5 * std.time.ns_per_ms);
}

pub fn nodeDeinit() void {
    var iterator = Qnnt.registry.iterator();
    while (iterator.next()) |list| {
        list.value_ptr.deinit(allocator);
    }

    Qnnt.registry.clearAndFree();
}

test {
    _ = @import("./qnnt.test.zig");
}
