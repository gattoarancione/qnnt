//! The parts of speaking HTTP over a socket that are not specific to one device.
//!
//! Two examples in this repository talk to a small embedded web server: the UGV Beast over
//! plaintext Socket.IO (examples/ugv/) and an IKEA DIRIGERA hub over TLS
//! (examples/dirigera/). They need the same three things, and each of the three exists here
//! because getting it wrong on the robot cost a day:
//!
//!   * a connect with a real deadline, because the OS default is 76 seconds
//!   * a response decoder, because these servers answer chunked and close the connection
//!   * an address parser that refuses anything it cannot dial
//!
//! What is NOT here is the protocol on top -- Engine.IO framing, TLS, WebSocket frames.
//! Those live with the example that needs them.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Error = error{
    /// A 4xx/5xx, or a malformed response. Includes an expired session, which is the one
    /// worth reconnecting on.
    Rejected,
    /// The peer did not answer inside the deadline. Distinct from `Rejected` because it
    /// usually means the network path rather than the peer.
    Timeout,
};

/// Connect, giving up after `ms` rather than after the operating system does.
///
/// `Io`'s own connect cannot be deadlined on Zig 0.16 -- passing one makes
/// `Io.Threaded.netConnectIpPosix` panic with "TODO implement netConnectIpPosix with
/// timeout" -- and the default is the OS's SYN retransmission. Measured against a silent
/// host on this subnet: **76.6 seconds** for a single attempt. This robot is its own Wi-Fi
/// access point and reboots without notice, so that is not an edge case; it is what every
/// reconnect costs while the robot is down, and for all of it the bridge is frozen.
///
/// So the connect is done straight through libc: a non-blocking `connect` followed by
/// `poll` with a real deadline. The descriptor is put back into blocking mode before it is
/// handed to `Io`, because `Io.Threaded`'s read path treats `EAGAIN` as a programmer bug
/// and panics on it -- which is the same trap that made `SO_RCVTIMEO` unusable.
pub fn connectWithDeadline(address: Io.net.IpAddress, ms: u32) !Io.net.Stream {
    const posix = std.posix;

    var storage: posix.sockaddr.in = std.mem.zeroes(posix.sockaddr.in);
    var storage6: posix.sockaddr.in6 = std.mem.zeroes(posix.sockaddr.in6);
    var sockaddr_ptr: *const posix.sockaddr = undefined;
    var sockaddr_len: posix.socklen_t = undefined;
    var family: u32 = undefined;

    switch (address) {
        .ip4 => |ip4| {
            storage.family = posix.AF.INET;
            storage.port = std.mem.nativeToBig(u16, ip4.port);
            storage.addr = @bitCast(ip4.bytes);
            // Darwin's sockaddr carries its own length; Linux's does not.
            if (@hasField(posix.sockaddr.in, "len")) storage.len = @sizeOf(posix.sockaddr.in);
            sockaddr_ptr = @ptrCast(&storage);
            sockaddr_len = @sizeOf(posix.sockaddr.in);
            family = posix.AF.INET;
        },
        .ip6 => |ip6| {
            storage6.family = posix.AF.INET6;
            storage6.port = std.mem.nativeToBig(u16, ip6.port);
            storage6.addr = ip6.bytes;
            storage6.flowinfo = ip6.flow;
            if (@hasField(posix.sockaddr.in6, "len")) storage6.len = @sizeOf(posix.sockaddr.in6);
            sockaddr_ptr = @ptrCast(&storage6);
            sockaddr_len = @sizeOf(posix.sockaddr.in6);
            family = posix.AF.INET6;
        },
    }

    const fd = std.c.socket(family, posix.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = std.c.close(fd);

    const flags = std.c.fcntl(fd, posix.F.GETFL, @as(c_int, 0));
    if (flags < 0) return error.SocketFailed;
    if (std.c.fcntl(fd, posix.F.SETFL, flags | @as(c_int, @bitCast(posix.O{ .NONBLOCK = true }))) < 0)
        return error.SocketFailed;

    const rc = std.c.connect(fd, sockaddr_ptr, sockaddr_len);
    if (rc != 0) {
        // Anything but "in progress" is a real refusal, and immediate.
        switch (posix.errno(rc)) {
            .INPROGRESS, .AGAIN => {},
            else => return error.ConnectFailed,
        }

        var pollfds = [1]posix.pollfd{.{
            .fd = fd,
            .events = posix.POLL.OUT,
            .revents = 0,
        }};
        const ready = posix.poll(&pollfds, @intCast(ms)) catch return error.ConnectFailed;
        if (ready == 0) return error.Timeout;

        // Writable does not mean connected: a refused connection is also writable, and
        // SO_ERROR is what distinguishes them.
        var so_error: c_int = 0;
        var so_len: posix.socklen_t = @sizeOf(c_int);
        if (std.c.getsockopt(fd, posix.SOL.SOCKET, posix.SO.ERROR, &so_error, &so_len) != 0)
            return error.ConnectFailed;
        if (so_error != 0) return error.ConnectFailed;
    }

    // Back to blocking before `Io` ever touches it.
    if (std.c.fcntl(fd, posix.F.SETFL, flags) < 0) return error.SocketFailed;

    return .{ .socket = .{ .handle = fd, .address = address } };
}

/// A ceiling on one response, so a server that never closes cannot grow the buffer without
/// bound. Engine.IO's own maxPayload here is 1 MB.
pub const max_response_bytes = 4 << 20;

/// "192.168.50.5:5000" -> an address. An IP literal only, deliberately: the robot is
/// reached by address, and resolving a name is another operation that can hang when the
/// network path is gone.
pub fn parseAuthority(authority: []const u8) !Io.net.IpAddress {
    const colon = std.mem.lastIndexOfScalar(u8, authority, ':') orelse
        return error.BadAuthority;
    const port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch
        return error.BadAuthority;
    return Io.net.IpAddress.parse(authority[0..colon], port) catch error.BadAuthority;
}

/// Strip the status line and headers, then undo `Transfer-Encoding: chunked` if it was
/// used, leaving the body in `out`.
///
/// Only what this one server actually sends is handled: a non-2xx status is a rejection, and
/// a body is either chunked or plain. Anything else -- a redirect, a continuation, a
/// compressed body -- would mean this is not the robot's Socket.IO endpoint.
pub fn decodeResponse(
    response: []const u8,
    out: *std.ArrayList(u8),
    allocator: Allocator,
) !void {
    const status = try decodeResponseStatus(response, out, allocator);
    if (status < 200 or status > 299) return error.Rejected;
}

/// The same, but hands back the status instead of refusing a non-2xx, and decodes the body
/// either way.
///
/// For most callers a non-2xx is simply a failure and `decodeResponse` is the right door.
/// This one exists because some exchanges carry their meaning in a 4xx body: the DIRIGERA
/// pairing flow answers "Invalid authorization code" until the operator presses the hub's
/// button, and "Already one ongoing pairing request" if a previous attempt is still open.
/// Those two need telling apart -- one means keep waiting, the other means start over --
/// and a bare `error.Rejected` cannot say which.
pub fn decodeResponseStatus(
    response: []const u8,
    out: *std.ArrayList(u8),
    allocator: Allocator,
) !u16 {
    const split = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return error.Rejected;
    const head = response[0..split];
    const body = response[split + 4 ..];

    // "HTTP/1.1 200 OK"
    const first_line_end = std.mem.indexOf(u8, head, "\r\n") orelse head.len;
    const status_line = head[0..first_line_end];
    const first_space = std.mem.indexOfScalar(u8, status_line, ' ') orelse return error.Rejected;
    const status_text = std.mem.trim(u8, status_line[first_space + 1 ..], " ");
    const code_end = std.mem.indexOfScalar(u8, status_text, ' ') orelse status_text.len;
    const status = std.fmt.parseInt(u16, status_text[0..code_end], 10) catch
        return error.Rejected;

    out.clearRetainingCapacity();

    if (!headerHasValue(head, "transfer-encoding", "chunked")) {
        try out.appendSlice(allocator, body);
        return status;
    }

    // <hex length>\r\n<data>\r\n ... 0\r\n\r\n
    var rest = body;
    while (true) {
        const line_end = std.mem.indexOf(u8, rest, "\r\n") orelse break;
        // A chunk-size line may carry extensions after a ';'.
        const size_field = rest[0..line_end];
        const size_text = std.mem.trim(
            u8,
            size_field[0 .. std.mem.indexOfScalar(u8, size_field, ';') orelse size_field.len],
            " ",
        );
        const size = std.fmt.parseInt(usize, size_text, 16) catch return error.Rejected;
        if (size == 0) break;

        const data_start = line_end + 2;
        // A truncated final chunk means the connection died mid-response.
        if (data_start + size > rest.len) return error.Rejected;
        try out.appendSlice(allocator, rest[data_start .. data_start + size]);

        const next = data_start + size;
        rest = if (next + 2 <= rest.len) rest[next + 2 ..] else "";
    }
    return status;
}

/// Whether a header names a value, case-insensitively on both. Written out because the
/// robot spells `Transfer-Encoding: chunked` and a stricter or looser match would either
/// miss it or match the wrong header.
fn headerHasValue(head: []const u8, name: []const u8, value: []const u8) bool {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next(); // the status line
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) continue;
        var values = std.mem.splitScalar(u8, line[colon + 1 ..], ',');
        while (values.next()) |candidate| {
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, candidate, " "), value)) return true;
        }
    }
    return false;
}

// -- tests ----------------------------------------------------------------------------
//
// The fixtures are real bytes off the two devices these helpers were written against.

const testing = std.testing;

test "decodeResponse undoes the chunked framing the robot actually sends" {
    // Real shape: Werkzeug answers every request chunked, with Connection: close.
    const response = "HTTP/1.1 200 OK\r\n" ++
        "Server: Werkzeug/3.0.3 Python/3.10.12\r\n" ++
        "Content-Type: text/plain; charset=UTF-8\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "Connection: close\r\n\r\n" ++
        "61\r\n0{\"sid\":\"cPDW9T3dG4M4dvlXAAAe\",\"upgrades\":[\"websocket\"]," ++
        "\"pingTimeout\":20000,\"pingInterval\":25000}\r\n" ++
        "0\r\n\r\n";

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try decodeResponse(response, &out, testing.allocator);
    try testing.expectEqualStrings(
        "0{\"sid\":\"cPDW9T3dG4M4dvlXAAAe\",\"upgrades\":[\"websocket\"]," ++
            "\"pingTimeout\":20000,\"pingInterval\":25000}",
        out.items,
    );
}

test "decodeResponse joins several chunks" {
    const response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "2\r\n42\r\n5\r\n/ctrl\r\n0\r\n\r\n";
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try decodeResponse(response, &out, testing.allocator);
    try testing.expectEqualStrings("42/ctrl", out.items);
}

test "decodeResponse handles a plain body, since not every server chunks" {
    const response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK";
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try decodeResponse(response, &out, testing.allocator);
    try testing.expectEqualStrings("OK", out.items);
}

test "decodeResponse rejects a non-2xx" {
    // The status that matters: an expired session, which is what triggers a reconnect.
    const response = "HTTP/1.1 400 BAD REQUEST\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "1a\r\n{\"code\":1,\"message\":\"Sess\"}\r\n0\r\n\r\n";
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(error.Rejected, decodeResponse(response, &out, testing.allocator));
}

test "decodeResponse rejects a chunk cut short by a dropped connection" {
    // Claims 0x61 bytes and carries four. Accepting this would hand a caller a truncated
    // telemetry frame as though it were whole.
    const response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n61\r\nabcd";
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(error.Rejected, decodeResponse(response, &out, testing.allocator));
}

test "decodeResponse rejects a response with no header terminator" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(
        error.Rejected,
        decodeResponse("HTTP/1.1 200 OK\r\nTransfer-Enc", &out, testing.allocator),
    );
}

test "headerHasValue is case-insensitive and does not match a different header" {
    const head = "HTTP/1.1 200 OK\r\nTRANSFER-ENCODING: Chunked\r\nX-Other: chunked-ish";
    try testing.expect(headerHasValue(head, "transfer-encoding", "chunked"));
    try testing.expect(!headerHasValue(head, "content-encoding", "chunked"));
}

test "parseAuthority reads the robot's host and port" {
    const address = try parseAuthority("192.168.50.5:5000");
    var buf: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{f}", .{address});
    try testing.expect(std.mem.indexOf(u8, text, "192.168.50.5") != null);
    try testing.expect(std.mem.indexOf(u8, text, "5000") != null);
}

test "parseAuthority refuses what it cannot dial" {
    // A hostname is refused on purpose: resolving one is another operation that hangs when
    // the network path is gone, and the bridge is given an address.
    try testing.expectError(error.BadAuthority, parseAuthority("robot.local:5000"));
    try testing.expectError(error.BadAuthority, parseAuthority("192.168.50.5"));
    try testing.expectError(error.BadAuthority, parseAuthority("192.168.50.5:notaport"));
}
