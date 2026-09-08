//! Socket.IO, spoken over its HTTP long-polling transport.
//!
//! The UGV Beast's web UI talks to the robot with `io('.../ctrl')` and `io('.../json')`, so
//! the robot speaks Socket.IO and nothing simpler. Socket.IO's default transport is a
//! WebSocket, but the protocol *begins* every session on long polling and only upgrades if
//! both ends want to -- and a client that never upgrades stays a first-class client. That
//! lower rung is plain HTTP request/response, which `std.http.Client` already gives us:
//!
//!   GET  /socket.io/?EIO=4&transport=polling            -> 0{"sid":"...","pingInterval":...}
//!   POST /socket.io/?EIO=4&transport=polling&sid=<sid>   body: 40/ctrl,
//!   POST ...                                             body: 42/ctrl,["request_data"]
//!   GET  ...                                            -> 42/ctrl,["update",{...}]
//!
//! So no WebSocket implementation and no dependency. What it costs is a TCP connection and
//! request per message rather than one framed stream; at the tens-of-hertz a teleoperated
//! robot needs, that is not a real cost. What it *does* cost is latency floor: a command
//! waits for a fresh connection, measured at 5-11 ms to this robot over en0.
//!
//! Engine.IO framing, the parts that matter here:
//!
//!   - A poll response may carry several packets, separated by 0x1e (RS).
//!   - Packet type is the first character: `0` open, `2` ping, `3` pong, `4` message.
//!   - Socket.IO rides inside `4`: `40<ns>,` connect, `42<ns>,[...]` event, `41<ns>,` close.
//!     So an event packet reads `42/ctrl,["update",{...}]` -- `4` message, `2` event.
//!   - The server pings on the poll channel and expects `3` back by POST, or it drops the
//!     session after pingTimeout. `poll()` answers that itself.
//!
//! One rule the transport imposes: at most one GET in flight per session. A second
//! concurrent poll makes the server close the session. POSTs have no such limit, which is
//! what lets the bridge poll telemetry on one thread and push commands from another.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
/// The transport-generic half: a connect with a deadline, and decoding a chunked response.
/// Shared with examples/dirigera/, which needs the same three things over TLS.
const wire = @import("wire");

pub const record_separator = 0x1e;

pub const Error = error{
    /// The server answered, but not with something Engine.IO allows here.
    BadHandshake,
    /// A 4xx/5xx, or a POST the server did not answer `ok`. Includes the case where the
    /// session has expired, which is the one worth reconnecting on.
    Rejected,
    /// The session id did not fit, or a URL did not. Both mean a robot we do not know.
    NameTooLong,
    /// The robot did not answer inside the round trip's deadline. Distinct from `Rejected`
    /// because it usually means the network path, not the robot.
    Timeout,
};

/// What survives a reconnect: where the robot is, and who we are to it. Copyable, because
/// each thread builds its own `Client` around the same session rather than sharing one.
pub const Session = struct {
    /// "192.168.50.5:5000" -- host and port as written on the command line.
    authority: []const u8,
    sid_buf: [64]u8 = undefined,
    sid_len: usize = 0,
    /// From the handshake. The server drops us if we go this long without a pong.
    ping_interval_ms: u32 = 25000,
    ping_timeout_ms: u32 = 20000,

    pub fn sid(s: *const Session) []const u8 {
        return s.sid_buf[0..s.sid_len];
    }
};

pub const Client = struct {
    io: Io,
    allocator: Allocator,
    /// Bounds connect and every read. Callers pick their own: a command must fail fast so
    /// the next one can be tried, while a long poll legitimately waits out the server's
    /// ping interval.
    timeout_ms: u32 = 2000,

    /// Asked between bounded reads whether to give up early. Optional, and null keeps the
    /// old behaviour exactly.
    ///
    /// It exists because a deadline and a shutdown are different things. The long poll
    /// legitimately waits 35 s -- the robot holds the request open until it has something to
    /// say -- but a process asked to stop must not wait that out. Without this the bridge
    /// ignored Ctrl-C for 38 seconds after the robot's Wi-Fi dropped, which is
    /// indistinguishable from a hang.
    cancel: ?*const fn () bool = null,
    /// The raw response, headers and chunk framing included. Reused so a round trip at
    /// 10 Hz does not allocate.
    raw: std.ArrayList(u8) = .empty,
    /// Room for the longest request line we build: path, query and sid.
    path_buf: [512]u8 = undefined,

    pub fn init(io: Io, allocator: Allocator) Client {
        return .{ .io = io, .allocator = allocator };
    }

    pub fn deinit(c: *Client) void {
        c.raw.deinit(c.allocator);
    }

    /// The request target, with the session id when there is one.
    fn path(c: *Client, sid_opt: ?[]const u8) Error![]const u8 {
        const written = if (sid_opt) |sid_text|
            std.fmt.bufPrint(
                &c.path_buf,
                "/socket.io/?EIO=4&transport=polling&sid={s}",
                .{sid_text},
            )
        else
            std.fmt.bufPrint(&c.path_buf, "/socket.io/?EIO=4&transport=polling", .{});
        return written catch return error.NameTooLong;
    }

    fn timeout(c: *const Client) Io.Timeout {
        return .{ .duration = .{
            .raw = .fromMilliseconds(c.timeout_ms),
            // Elapsed time, not wall-clock: a clock adjustment must not extend or cancel a
            // deadline that exists to stop a robot.
            .clock = .awake,
        } };
    }

    /// One HTTP round trip, bounded at every step, leaving the decoded body in `out`.
    ///
    /// This is a purpose-built HTTP/1.1 client rather than `std.http.Client`, and the reason
    /// is a deadline. `std.http.Client` has no read timeout, so a request on a network path
    /// that has gone away sits in `receiveHead` until TCP gives up -- about fifteen minutes
    /// on macOS. That happened here for real: a routing change on the host sent packets for
    /// the robot out a second interface, and both of the bridge's loops blocked
    /// indefinitely. The watchdog lives on one of those loops, so it stopped running too --
    /// precisely the failure the watchdog exists to prevent.
    ///
    /// Setting `SO_RCVTIMEO` on the client's socket does not fix it either: a timeout then
    /// surfaces as `EAGAIN`, and `Io.Threaded`'s read path treats `EAGAIN` as a programmer
    /// bug and panics. `Io`'s own `receiveTimeout` is the supported way to bound a read, and
    /// it needs the socket in hand.
    ///
    /// What makes this small enough to be worth writing: the robot answers every request
    /// with `Transfer-Encoding: chunked` and `Connection: close`, so there is no connection
    /// to pool, no length to negotiate, and the body is simply everything up to EOF once the
    /// chunk framing is removed. Being an IP literal, it also needs no DNS -- one less place
    /// for a dead network to hang.
    fn roundTrip(
        c: *Client,
        authority: []const u8,
        target: []const u8,
        payload: ?[]const u8,
        out: *std.ArrayList(u8),
    ) !void {
        const address = wire.parseAuthority(authority) catch return error.Rejected;

        // Capped separately: a connect that cannot be made fails quickly, and inheriting a
        // long poll's 35 s read budget would make an unreachable robot take 35 s to say so.
        var stream = wire.connectWithDeadline(address, @min(c.timeout_ms, 3000)) catch |err| return switch (err) {
            error.Timeout => error.Timeout,
            else => error.Rejected,
        };
        defer stream.close(c.io);

        // -- the request ------------------------------------------------------------
        var send_buf: [1024]u8 = undefined;
        var writer = stream.writer(c.io, &send_buf);
        const w = &writer.interface;

        if (payload) |body| {
            w.print(
                "POST {s} HTTP/1.1\r\nHost: {s}\r\n" ++
                    // The robot's Flask server answers a POST body only when told what the
                    // body is, and this is the type its own web UI sends.
                    "Content-Type: text/plain;charset=UTF-8\r\n" ++
                    "Content-Length: {d}\r\nConnection: close\r\n\r\n{s}",
                .{ target, authority, body.len, body },
            ) catch return error.Rejected;
        } else {
            w.print(
                "GET {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n",
                .{ target, authority },
            ) catch return error.Rejected;
        }
        w.flush() catch return error.Rejected;

        // -- the response, to EOF ---------------------------------------------------
        c.raw.clearRetainingCapacity();
        var chunk: [4096]u8 = undefined;

        // Sliced rather than one long wait. The budget is still `timeout_ms`; it is simply
        // spent in pieces, so `cancel` gets a look in between them. A read that returns
        // Timeout here is not a failure -- it means "nothing yet", which is the normal
        // state of a long poll.
        const slice_ms: u32 = @min(c.timeout_ms, 250);
        const slice: Io.Timeout = .{ .duration = .{
            .raw = .fromMilliseconds(slice_ms),
            .clock = .awake,
        } };
        var waited: u32 = 0;

        while (true) {
            const message = stream.socket.receiveTimeout(c.io, &chunk, slice) catch |err| {
                switch (err) {
                    error.Timeout => {
                        if (c.cancel) |stop| {
                            if (stop()) return error.Cancelled;
                        }
                        waited += slice_ms;
                        if (waited >= c.timeout_ms) return error.Timeout;
                        continue;
                    },
                    else => return error.Rejected,
                }
            };
            // The server closed, which is how every response here ends.
            if (message.data.len == 0) break;
            c.raw.appendSlice(c.allocator, message.data) catch return error.Rejected;
            if (c.raw.items.len > wire.max_response_bytes) return error.Rejected;
        }

        return wire.decodeResponse(c.raw.items, out, c.allocator);
    }

    /// A plain GET, for the robot's ordinary web endpoints rather than its Socket.IO one.
    /// `GET /config` is the only user: the robot's own configuration file.
    pub fn get(
        c: *Client,
        authority: []const u8,
        target: []const u8,
        out: *std.ArrayList(u8),
    ) !void {
        return c.roundTrip(authority, target, null, out);
    }

    /// Open a session: the Engine.IO handshake, which hands back the sid every later
    /// request must carry.
    pub fn handshake(c: *Client, authority: []const u8, out: *std.ArrayList(u8)) !Session {
        try c.roundTrip(authority, try c.path(null), null, out);

        // `0{"sid":"...","upgrades":["websocket"],"pingInterval":25000,"pingTimeout":20000}`
        const body = out.items;
        if (body.len < 2 or body[0] != '0') return error.BadHandshake;

        var session: Session = .{ .authority = authority };
        const sid = jsonString(body, "sid") orelse return error.BadHandshake;
        if (sid.len > session.sid_buf.len) return error.NameTooLong;
        @memcpy(session.sid_buf[0..sid.len], sid);
        session.sid_len = sid.len;
        if (jsonNumber(body, "pingInterval")) |v| session.ping_interval_ms = @intFromFloat(v);
        if (jsonNumber(body, "pingTimeout")) |v| session.ping_timeout_ms = @intFromFloat(v);
        return session;
    }

    /// Join a namespace. Until this succeeds the server discards events for it -- which is
    /// silent, so it is worth doing before the first command rather than lazily.
    pub fn openNamespace(
        c: *Client,
        session: *const Session,
        namespace: []const u8,
        out: *std.ArrayList(u8),
    ) !void {
        var packet: [128]u8 = undefined;
        const body = std.fmt.bufPrint(&packet, "40{s},", .{namespace}) catch
            return error.NameTooLong;
        try c.roundTrip(session.authority, try c.path(session.sid()), body, out);
    }

    /// `socket.emit(event, payload)`. `payload_json` is spliced in as the event's single
    /// argument, so it has to be valid JSON; callers build it from typed values rather than
    /// from user text.
    pub fn emit(
        c: *Client,
        session: *const Session,
        namespace: []const u8,
        event_name: []const u8,
        payload_json: ?[]const u8,
        out: *std.ArrayList(u8),
    ) !void {
        var packet: [512]u8 = undefined;
        const body = if (payload_json) |p|
            std.fmt.bufPrint(&packet, "42{s},[\"{s}\",{s}]", .{ namespace, event_name, p })
        else
            std.fmt.bufPrint(&packet, "42{s},[\"{s}\"]", .{ namespace, event_name });
        try c.roundTrip(
            session.authority,
            try c.path(session.sid()),
            body catch return error.NameTooLong,
            out,
        );
    }

    /// Wait for whatever the server has to say. Blocks until the server has a packet or its
    /// own poll timeout expires, so this is the telemetry path and belongs on its own
    /// thread -- and only one such call may be outstanding per session.
    ///
    /// Answers pings itself and reports whether it did, since a caller watching for
    /// telemetry wants to know the difference between "the link is quiet" and "the link is
    /// alive but carrying only keepalives".
    pub fn poll(
        c: *Client,
        session: *const Session,
        out: *std.ArrayList(u8),
    ) !bool {
        try c.roundTrip(session.authority, try c.path(session.sid()), null, out);

        var pinged = false;
        var it = packets(out.items);
        while (it.next()) |p| {
            if (p.len == 1 and p[0] == '2') pinged = true;
        }
        if (pinged) {
            // Answered on a separate POST, and deliberately not through `out`: the caller
            // still has to read the telemetry that arrived alongside the ping.
            var scratch: std.ArrayList(u8) = .empty;
            defer scratch.deinit(c.allocator);
            c.roundTrip(session.authority, try c.path(session.sid()), "3", &scratch) catch {};
        }
        return pinged;
    }
};

/// Splits a poll response into Engine.IO packets. A single response often holds several.
pub fn packets(body: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, body, record_separator);
}

/// The event name and its first argument, out of a `42<ns>,["name",{...}]` packet, or null
/// if this packet is not an event in `namespace`.
pub fn event(packet: []const u8, namespace: []const u8) ?struct { name: []const u8, arg: []const u8 } {
    if (packet.len < 2 or packet[0] != '4' or packet[1] != '2') return null;
    var rest = packet[2..];

    // The namespace is present unless it is the default "/", in which case it is omitted.
    if (!std.mem.eql(u8, namespace, "/")) {
        if (!std.mem.startsWith(u8, rest, namespace)) return null;
        rest = rest[namespace.len..];
        if (rest.len == 0 or rest[0] != ',') return null;
        rest = rest[1..];
    }

    // `["name",<arg>]`
    if (rest.len < 2 or rest[0] != '[') return null;
    const name_open = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    const name_close = std.mem.indexOfScalarPos(u8, rest, name_open + 1, '"') orelse return null;
    const name = rest[name_open + 1 .. name_close];

    const comma = std.mem.indexOfScalarPos(u8, rest, name_close, ',') orelse
        return .{ .name = name, .arg = "" };
    if (rest.len < 2 or rest[rest.len - 1] != ']') return null;
    return .{ .name = name, .arg = std.mem.trim(u8, rest[comma + 1 .. rest.len - 1], " ") };
}

// -- just enough JSON to read the robot's replies -------------------------------------
//
// The robot sends flat objects of numbers and booleans -- the telemetry map is fifteen
// numeric keys -- so these read one field out of one object rather than parsing a document.
// Anything nested would need a real parser; nothing here is nested.

/// The string value of `"key":"value"`.
pub fn jsonString(json: []const u8, key: []const u8) ?[]const u8 {
    const at = findKey(json, key) orelse return null;
    var i = at;
    while (i < json.len and json[i] != '"') i += 1;
    if (i >= json.len) return null;
    const start = i + 1;
    var j = start;
    while (j < json.len and json[j] != '"') j += 1;
    if (j >= json.len) return null;
    return json[start..j];
}

/// The numeric value of `"key":123.4`. Booleans read as 1 and 0, because the robot sends
/// one telemetry field (`cv_movtion_mode`) as a bool among fourteen numbers.
pub fn jsonNumber(json: []const u8, key: []const u8) ?f64 {
    const at = findKey(json, key) orelse return null;
    var i = at;
    while (i < json.len and (json[i] == ' ' or json[i] == ':')) i += 1;
    if (std.mem.startsWith(u8, json[i..], "true")) return 1;
    if (std.mem.startsWith(u8, json[i..], "false")) return 0;
    var j = i;
    while (j < json.len and (std.ascii.isDigit(json[j]) or json[j] == '-' or
        json[j] == '+' or json[j] == '.' or json[j] == 'e' or json[j] == 'E')) j += 1;
    if (j == i) return null;
    return std.fmt.parseFloat(f64, json[i..j]) catch null;
}

/// Position just past `"key":`, matching the whole quoted key so that looking up `"105"`
/// cannot match inside `"1105"`.
fn findKey(json: []const u8, key: []const u8) ?usize {
    var quoted: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&quoted, "\"{s}\"", .{key}) catch return null;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, json, from, needle)) |at| {
        var i = at + needle.len;
        while (i < json.len and json[i] == ' ') i += 1;
        if (i < json.len and json[i] == ':') return i + 1;
        from = at + 1;
    }
    return null;
}

// -- tests ----------------------------------------------------------------------------
//
// The fixtures are real bytes off 192.168.50.5, not invented ones.

const testing = std.testing;

test "event reads the real update packet the robot sent" {
    const packet = "42/ctrl,[\"update\",{\"104\":0.07,\"106\":35,\"107\":54.12,\"112\":1201," ++
        "\"114\":true,\"115\":0}]";
    const e = event(packet, "/ctrl") orelse return error.NotParsed;
    try testing.expectEqualStrings("update", e.name);
    try testing.expectEqualStrings(
        "{\"104\":0.07,\"106\":35,\"107\":54.12,\"112\":1201,\"114\":true,\"115\":0}",
        e.arg,
    );
}

test "event on the wrong namespace is not mistaken for ours" {
    try testing.expect(event("42/json,[\"x\",{}]", "/ctrl") == null);
}

test "a namespace-connect ack is not an event" {
    try testing.expect(event("40/ctrl,{\"sid\":\"DI5SivbQIWaUf-8xAAAI\"}", "/ctrl") == null);
}

test "an event with no argument parses, since request_data has none" {
    const e = event("42/ctrl,[\"request_data\"]", "/ctrl") orelse return error.NotParsed;
    try testing.expectEqualStrings("request_data", e.name);
    try testing.expectEqualStrings("", e.arg);
}

test "packets splits a response carrying a ping alongside an event" {
    const body = "2\x1e42/ctrl,[\"update\",{\"112\":1201}]";
    var it = packets(body);
    try testing.expectEqualStrings("2", it.next().?);
    try testing.expectEqualStrings("42/ctrl,[\"update\",{\"112\":1201}]", it.next().?);
    try testing.expect(it.next() == null);
}

test "jsonString pulls the sid out of the real handshake" {
    const body = "0{\"sid\":\"lv_VI97HAgtNUtIYAAAG\",\"upgrades\":[\"websocket\"]," ++
        "\"pingTimeout\":20000,\"pingInterval\":25000}";
    try testing.expectEqualStrings("lv_VI97HAgtNUtIYAAAG", jsonString(body, "sid").?);
    try testing.expectEqual(@as(f64, 25000), jsonNumber(body, "pingInterval").?);
}

test "a numeric key does not match inside a longer one" {
    // The telemetry map is numeric keys, so `"105"` must not be found inside `"1105"`.
    try testing.expectEqual(@as(f64, 7), jsonNumber("{\"1105\":3,\"105\":7}", "105").?);
    try testing.expect(jsonNumber("{\"1105\":3}", "105") == null);
}

test "jsonNumber reads a bool, which the robot sends among its numbers" {
    try testing.expectEqual(@as(f64, 1), jsonNumber("{\"114\":true}", "114").?);
    try testing.expectEqual(@as(f64, 0), jsonNumber("{\"114\":false}", "114").?);
}

test "jsonNumber reads a negative and a fractional reading" {
    try testing.expectEqual(@as(f64, -3.25), jsonNumber("{\"110\":-3.25}", "110").?);
    try testing.expectEqual(@as(f64, 0.07), jsonNumber("{\"104\":0.07}", "104").?);
}

