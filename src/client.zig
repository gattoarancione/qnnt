const std = @import("std");
const net = std.net;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // ---- args: host port (defaults: 127.0.0.1 9000) ----
    var args = try std.process.argsWithAllocator(gpa.allocator());
    defer args.deinit();

    _ = args.next(); // skip program name
    const host = args.next() orelse "127.0.0.1";
    const port_str = args.next() orelse "9000";
    const port = try std.fmt.parseUnsigned(u16, port_str, 10);

    // Resolve IPv4 address (use Ip6Address.parse for IPv6)
    const ip4 = try net.Ip4Address.parse(host, port);
    const addr = net.Address{ .in = ip4 };

    // ---- connect ----
    var stream = try net.tcpConnectToAddress(addr);
    defer stream.close();

    // ---- I/O setup ----
    // stdin (buffered reader)
    var in_buf: [4096]u8 = undefined;
    //var stdin_reader = std.io.getStdIn().reader(&in_buf);
    var stdin_reader = std.fs.File.stdin().reader(&in_buf);

    // socket: unbuffered writer (empty buffer => direct writes)
    var sock_writer = stream.writer(&.{});
    // socket: buffered reader
    var sock_rbuf: [4096]u8 = undefined;
    var sock_reader = stream.reader(&sock_rbuf);

    // stdout: unbuffered writer
    //var stdout_writer = std.io.getStdOut().writer(&.{});
    var stdout_writer = std.fs.File.stdout().writer(&.{});

    std.debug.print("connected to {s}:{d}\n", .{ host, port });

    // ---- line loop ----
    while (true) {
        // read one line from stdin (including '\n')
        const line = stdin_reader.interface.takeDelimiterInclusive('\n') catch |err| {
            if (err == error.EndOfStream) break; // Ctrl-D / EOF
            return err;
        };
        if (line.len == 0) continue;

        // send line to server
        try sock_writer.interface.writeAll(line);

        // read one echoed line back
        const echo = sock_reader.interface().takeDelimiterInclusive('\n') catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        try stdout_writer.interface.writeAll(echo);
    }
}
