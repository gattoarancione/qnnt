const std = @import("std");
const net = std.net;

fn handleClient(client: net.Server.Connection) !void {
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
        std.debug.print("echoing {s}\n", .{chunk});
        try writer.interface.writeAll(chunk);
    }
}

pub fn main() !void {
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
        _ = try std.Thread.spawn(.{}, handleClient, .{client});
    }
}
