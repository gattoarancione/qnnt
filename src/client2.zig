const std = @import("std");
const net = std.net;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // ---- args: host port (defaults: 127.0.0.1 9000) ----
    var args = try std.process.argsWithAllocator(gpa.allocator());
    defer args.deinit();

    _ = args.next();
    const host = args.next() orelse "127.0.0.1";
    const port = try std.fmt.parseUnsigned(u16, args.next() orelse "9000", 10);

    const addr = std.net.Address{ .in = try std.net.Ip4Address.parse(host, port) };
    var stream = try net.tcpConnectToAddress(addr);
    defer stream.close();

    // stdin/stdout via std.fs.File
    var in_buf: [4096]u8 = undefined;
    var sock_rbuf: [4096]u8 = undefined;

    var stdin_reader = std.fs.File.stdin().reader(&in_buf);
    var stdout_writer = std.fs.File.stdout().writer(&.{});
    var sock_reader = stream.reader(&sock_rbuf);
    var sock_writer = stream.writer(&.{});

    std.debug.print("connected to {s}:{d}\n", .{ host, port });

    while (true) {
        // read one line from stdin
        const line = stdin_reader.interface.takeDelimiterInclusive('\n') catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        if (line.len == 0) continue;

        // send to server
        try sock_writer.interface.writeAll(line);

        // read echoed line back
        const echo = sock_reader.interface().takeDelimiterInclusive('\n') catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        try stdout_writer.interface.writeAll(echo);
    }
}
