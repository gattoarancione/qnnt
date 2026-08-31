const std = @import("std");
const net = std.net;
const builtin = @import("builtin");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();

    // args: host port (defaults)
    var args = try std.process.argsWithAllocator(ally);
    defer args.deinit();
    _ = args.next();
    const host = args.next() orelse "127.0.0.1";
    const port = try std.fmt.parseUnsigned(u16, args.next() orelse "9000", 10);

    // connect
    const addr = net.Address{ .in = try net.Ip4Address.parse(host, port) };
    var stream = try net.tcpConnectToAddress(addr);
    defer stream.close();

    // --- stdin/stdout (buffered) ---
    var stdin_br = std.io.bufferedReader(std.fs.File.stdin().reader());
    const in = stdin_br.reader();

    var stdout_bw = std.io.bufferedWriter(std.fs.File.stdout().writer());
    const out = stdout_bw.writer();

    // --- socket I/O (buffered) ---
    var sock_br = std.io.bufferedReader(stream.reader());
    const sock_in = sock_br.reader();

    var sock_bw = std.io.bufferedWriter(stream.writer());
    const sock_out = sock_bw.writer();

    std.debug.print("connected to {s}:{d}\n", .{ host, port });

    while (true) {
        // read a line from stdin (allocates; returns null on EOF with no data)
        const maybe_line = try in.readUntilDelimiterOrEofAlloc(ally, '\n', 1 << 20);
        if (maybe_line == null) break; // EOF
        const line = maybe_line.?;

        // send to server
        try sock_out.writeAll(line);
        try sock_bw.flush();

        // read echoed line back
        const maybe_echo = try sock_in.readUntilDelimiterOrEofAlloc(ally, '\n', 1 << 20);
        if (maybe_echo == null) {
            ally.free(line);
            break;
        }
        const echo = maybe_echo.?;

        // print to stdout
        try out.writeAll(echo);
        try stdout_bw.flush();

        ally.free(line);
        ally.free(echo);
    }
}
