//! Enough of RFC 6455 to listen to a DIRIGERA hub.
//!
//! The hub pushes every state change over a WebSocket on the same port as its REST API:
//!
//!     wss://<hub>:8443/v1     with  Authorization: Bearer <token>
//!
//! That is the reason this example exists in the shape it does. The UGV Beast had to be
//! polled and gave up telemetry about every five seconds; here a light being switched, a
//! motion sensor tripping or an illuminance reading changing arrives immediately and
//! unprompted. A bridge over this is a translator, not a poller.
//!
//! Deliberately partial, and these are the omissions:
//!
//!   * **No fragmentation.** A continuation frame is skipped rather than reassembled. The
//!     hub sends each event as one frame; if a firmware ever fragments, events would be
//!     dropped rather than corrupted, and `dropped_fragments` counts them so it shows up as
//!     a number rather than as silence.
//!   * **No extensions or compression.** None are negotiated, so none can arrive.
//!   * **No close handshake beyond noticing one.** The bridge reconnects rather than
//!     conversing about why the connection ended.
//!
//! Client-to-server frames must be masked and server-to-client frames must not be; both
//! directions are enforced here, because an unmasked client frame is a protocol violation
//! that some servers answer by hanging up with no explanation.

const std = @import("std");
const Io = std.Io;

pub const Error = error{
    /// The server did not answer 101, or its Sec-WebSocket-Accept did not match. Either
    /// means we are not talking to the WebSocket endpoint we think we are.
    HandshakeFailed,
    /// The peer sent something this reader does not implement, or nonsense.
    ProtocolError,
    /// A frame larger than the caller's buffer.
    FrameTooLarge,
};

/// From RFC 6455 section 1.3. Concatenated with the client's key to prove the server
/// actually understood the upgrade rather than echoing a 101 at anything.
pub const accept_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Masks for client-to-server frames.
///
/// Zig 0.16 has no global CSPRNG -- randomness comes from the `Io` -- and threading an `Io`
/// through frame writing just to mask a two-byte pong is out of proportion. So the seed is
/// taken from the `Io` once, when the connection opens, and this stretches it.
///
/// That is sound because masking is not a secrecy mechanism: RFC 6455 requires it to stop
/// intermediaries being tricked into caching crafted responses, and this connection is
/// inside TLS regardless. Being able to seed it deterministically also lets the tests
/// assert exact bytes instead of XOR-ing them back.
pub const Masker = struct {
    rng: std.Random.DefaultCsprng,

    pub fn init(seed: [32]u8) Masker {
        return .{ .rng = .init(seed) };
    }

    pub fn next(m: *Masker) [4]u8 {
        var mask: [4]u8 = undefined;
        m.rng.random().bytes(&mask);
        return mask;
    }
};

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,
};

pub const Frame = struct {
    opcode: Opcode,
    payload: []const u8,
};

/// `base64(sha1(key ++ guid))` -- what the server must return for a given client key.
pub fn acceptFor(key: []const u8, out: *[28]u8) []const u8 {
    var hash: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    var sha1: std.crypto.hash.Sha1 = .init(.{});
    sha1.update(key);
    sha1.update(accept_guid);
    sha1.final(&hash);
    return std.base64.standard.Encoder.encode(out, &hash);
}

/// Perform the upgrade. `reader`/`writer` are the plaintext ends of the TLS connection.
///
/// The response headers are consumed here, so on return the reader is positioned exactly at
/// the first WebSocket frame.
pub fn handshake(
    reader: *Io.Reader,
    writer: *Io.Writer,
    authority: []const u8,
    path: []const u8,
    token: []const u8,
    entropy: *const [16]u8,
) !void {
    var key_buf: [24]u8 = undefined;
    const key = std.base64.standard.Encoder.encode(&key_buf, entropy);

    writer.print(
        "GET {s} HTTP/1.1\r\n" ++
            "Host: {s}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "Authorization: Bearer {s}\r\n" ++
            "\r\n",
        .{ path, authority, key, token },
    ) catch return error.HandshakeFailed;
    writer.flush() catch return error.HandshakeFailed;

    // Read the response a line at a time, stopping at the blank line, so the reader is
    // left positioned exactly at the first frame. Line-wise rather than searching for
    // "\r\n\r\n" because Io.Reader delimits on a single byte.
    var expected: [28]u8 = undefined;
    const want = acceptFor(key, &expected);

    var saw_101 = false;
    var saw_accept = false;
    var lines: usize = 0;
    while (lines < 64) : (lines += 1) {
        // INCLUSIVE, and the distinction is not cosmetic: the exclusive form leaves the
        // delimiter in the stream, so the next call returns an empty line immediately.
        // With the exclusive form every second line read as blank, this loop took the
        // first of them as the end of the headers, and the handshake failed for want of a
        // Sec-WebSocket-Accept it had never looked at.
        const line_raw = reader.takeDelimiterInclusive('\n') catch
            return error.HandshakeFailed;
        const line = std.mem.trimEnd(u8, line_raw, "\r\n");
        if (line.len == 0) break; // end of headers

        if (lines == 0) {
            saw_101 = std.mem.indexOf(u8, line, " 101 ") != null;
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(
            std.mem.trim(u8, line[0..colon], " "),
            "sec-websocket-accept",
        )) continue;
        // The server's proof it understood the upgrade rather than echoing a 101 at
        // anything: base64(sha1(our key ++ the RFC's GUID)).
        saw_accept = std.mem.eql(u8, std.mem.trim(u8, line[colon + 1 ..], " \t"), want);
    }

    if (!saw_101 or !saw_accept) return error.HandshakeFailed;
}

/// The next frame with an application payload, returned as a slice of `buf`.
///
/// Answers pings itself, because a hub that stops getting pongs closes the connection, and
/// skips what it does not implement. `dropped_fragments` is incremented rather than
/// silently ignored -- see the file header.
pub fn readFrame(
    reader: *Io.Reader,
    writer: *Io.Writer,
    masker: *Masker,
    buf: []u8,
    dropped_fragments: *u64,
) !?Frame {
    while (true) {
        const header = reader.take(2) catch return error.ProtocolError;
        const opcode: Opcode = @enumFromInt(header[0] & 0x0F);
        const masked = (header[1] & 0x80) != 0;
        var length: u64 = header[1] & 0x7F;

        if (length == 126) {
            const extended = reader.take(2) catch return error.ProtocolError;
            length = std.mem.readInt(u16, extended[0..2], .big);
        } else if (length == 127) {
            const extended = reader.take(8) catch return error.ProtocolError;
            length = std.mem.readInt(u64, extended[0..8], .big);
        }

        // A server must never mask. If one does, the stream is not what we think it is and
        // every subsequent length would be misread.
        if (masked) return error.ProtocolError;
        if (length > buf.len) return error.FrameTooLarge;

        const payload = reader.take(@intCast(length)) catch return error.ProtocolError;
        @memcpy(buf[0..payload.len], payload);
        const body = buf[0..payload.len];

        switch (opcode) {
            .text, .binary => return .{ .opcode = opcode, .payload = body },
            .ping => {
                // Echo the payload back, as the spec requires.
                try writeFrame(writer, masker, .pong, body);
                continue;
            },
            .pong => continue,
            .close => return null,
            .continuation => {
                dropped_fragments.* += 1;
                continue;
            },
            else => continue,
        }
    }
}

/// One client frame. Masked, because the spec requires it of a client and servers enforce
/// it. The mask is derived from the payload length and a counter rather than from a
/// cryptographic source: masking exists to defeat intermediary cache poisoning, not to
/// provide secrecy, and this connection is already inside TLS.
pub fn writeFrame(
    writer: *Io.Writer,
    masker: *Masker,
    opcode: Opcode,
    payload: []const u8,
) !void {
    var header: [14]u8 = undefined;
    header[0] = 0x80 | @as(u8, @intFromEnum(opcode)); // FIN set, never fragmented
    var len: usize = 2;

    if (payload.len < 126) {
        header[1] = 0x80 | @as(u8, @intCast(payload.len));
    } else if (payload.len <= 0xFFFF) {
        header[1] = 0x80 | 126;
        std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
        len = 4;
    } else {
        header[1] = 0x80 | 127;
        std.mem.writeInt(u64, header[2..10], payload.len, .big);
        len = 10;
    }

    const mask = masker.next();
    @memcpy(header[len .. len + 4], &mask);
    len += 4;

    writer.writeAll(header[0..len]) catch return error.ProtocolError;

    // Masked in blocks, so a large payload does not need a full copy.
    var offset: usize = 0;
    var block: [512]u8 = undefined;
    while (offset < payload.len) {
        const take = @min(block.len, payload.len - offset);
        for (0..take) |i| {
            block[i] = payload[offset + i] ^ mask[(offset + i) % 4];
        }
        writer.writeAll(block[0..take]) catch return error.ProtocolError;
        offset += take;
    }
    writer.flush() catch return error.ProtocolError;
}

fn containsHeaderValue(head: []const u8, name: []const u8, value: []const u8) bool {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next(); // status line
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) continue;
        return std.mem.eql(u8, std.mem.trim(u8, line[colon + 1 ..], " \t"), value);
    }
    return false;
}

// -- tests ----------------------------------------------------------------------------

const testing = std.testing;

test "acceptFor computes the RFC 6455 example" {
    // Section 1.3 of the RFC gives this exact pair, which makes it the one case that
    // proves the implementation rather than merely being self-consistent.
    var out: [28]u8 = undefined;
    try testing.expectEqualStrings(
        "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
        acceptFor("dGhlIHNhbXBsZSBub25jZQ==", &out),
    );
}

test "a frame header is parsed and the payload returned" {
    // 0x81 = FIN + text, 0x05 = unmasked, 5 bytes.
    const bytes = [_]u8{ 0x81, 0x05, 'h', 'e', 'l', 'l', 'o' };
    var reader: Io.Reader = .fixed(&bytes);
    var sink: [64]u8 = undefined;
    var writer: Io.Writer = .fixed(&sink);
    var buf: [64]u8 = undefined;
    var dropped: u64 = 0;
    var masker: Masker = .init(@splat(7));

    const frame = (try readFrame(&reader, &writer, &masker, &buf, &dropped)).?;
    try testing.expectEqual(Opcode.text, frame.opcode);
    try testing.expectEqualStrings("hello", frame.payload);
}

test "a 126-length frame reads its extended length" {
    var bytes: [4 + 200]u8 = undefined;
    bytes[0] = 0x81;
    bytes[1] = 126;
    std.mem.writeInt(u16, bytes[2..4], 200, .big);
    @memset(bytes[4..], 'x');
    var reader: Io.Reader = .fixed(&bytes);
    var sink: [64]u8 = undefined;
    var writer: Io.Writer = .fixed(&sink);
    var buf: [512]u8 = undefined;
    var dropped: u64 = 0;
    var masker: Masker = .init(@splat(7));

    const frame = (try readFrame(&reader, &writer, &masker, &buf, &dropped)).?;
    try testing.expectEqual(@as(usize, 200), frame.payload.len);
}

test "a close frame ends the stream rather than erroring" {
    const bytes = [_]u8{ 0x88, 0x00 };
    var reader: Io.Reader = .fixed(&bytes);
    var sink: [64]u8 = undefined;
    var writer: Io.Writer = .fixed(&sink);
    var buf: [64]u8 = undefined;
    var dropped: u64 = 0;
    var masker: Masker = .init(@splat(7));
    try testing.expect((try readFrame(&reader, &writer, &masker, &buf, &dropped)) == null);
}

test "a ping is answered with a masked pong carrying the same payload" {
    const bytes = [_]u8{ 0x89, 0x02, 'h', 'i', 0x81, 0x01, 'z' };
    var reader: Io.Reader = .fixed(&bytes);
    var sink: [64]u8 = undefined;
    var writer: Io.Writer = .fixed(&sink);
    var buf: [64]u8 = undefined;
    var dropped: u64 = 0;
    var masker: Masker = .init(@splat(7));

    // The text frame after the ping is what comes back...
    const frame = (try readFrame(&reader, &writer, &masker, &buf, &dropped)).?;
    try testing.expectEqualStrings("z", frame.payload);

    // ...and a pong went out in the meantime, masked, as a client frame must be.
    const written = writer.buffered();
    try testing.expectEqual(@as(u8, 0x8A), written[0]); // FIN + pong
    try testing.expectEqual(@as(u8, 0x82), written[1]); // MASK + length 2
    const mask = written[2..6];
    try testing.expectEqual(@as(u8, 'h'), written[6] ^ mask[0]);
    try testing.expectEqual(@as(u8, 'i'), written[7] ^ mask[1]);
}

test "a masked server frame is refused" {
    // A server must never mask. Accepting one would mean misreading every later length,
    // so this has to be an error rather than a best effort.
    const bytes = [_]u8{ 0x81, 0x85, 1, 2, 3, 4, 'a', 'b', 'c', 'd', 'e' };
    var reader: Io.Reader = .fixed(&bytes);
    var sink: [64]u8 = undefined;
    var writer: Io.Writer = .fixed(&sink);
    var buf: [64]u8 = undefined;
    var dropped: u64 = 0;
    var masker: Masker = .init(@splat(7));
    try testing.expectError(
        error.ProtocolError,
        readFrame(&reader, &writer, &masker, &buf, &dropped),
    );
}

test "a frame beyond the buffer is refused rather than truncated" {
    const bytes = [_]u8{ 0x81, 0x0A } ++ [_]u8{'x'} ** 10;
    var reader: Io.Reader = .fixed(&bytes);
    var sink: [64]u8 = undefined;
    var writer: Io.Writer = .fixed(&sink);
    var buf: [4]u8 = undefined;
    var dropped: u64 = 0;
    var masker: Masker = .init(@splat(7));
    try testing.expectError(
        error.FrameTooLarge,
        readFrame(&reader, &writer, &masker, &buf, &dropped),
    );
}

test "a continuation frame is counted, not silently skipped" {
    const bytes = [_]u8{ 0x00, 0x01, 'a', 0x81, 0x01, 'b' };
    var reader: Io.Reader = .fixed(&bytes);
    var sink: [64]u8 = undefined;
    var writer: Io.Writer = .fixed(&sink);
    var buf: [64]u8 = undefined;
    var dropped: u64 = 0;
    var masker: Masker = .init(@splat(7));

    const frame = (try readFrame(&reader, &writer, &masker, &buf, &dropped)).?;
    try testing.expectEqualStrings("b", frame.payload);
    try testing.expectEqual(@as(u64, 1), dropped);
}

test "writeFrame masks the payload and sets FIN" {
    var sink: [64]u8 = undefined;
    var writer: Io.Writer = .fixed(&sink);
    var masker: Masker = .init(@splat(7));
    try writeFrame(&writer, &masker, .text, "abc");
    const written = writer.buffered();
    try testing.expectEqual(@as(u8, 0x81), written[0]);
    try testing.expectEqual(@as(u8, 0x83), written[1]);
    const mask = written[2..6];
    try testing.expectEqual(@as(u8, 'a'), written[6] ^ mask[0]);
    try testing.expectEqual(@as(u8, 'b'), written[7] ^ mask[1]);
    try testing.expectEqual(@as(u8, 'c'), written[8] ^ mask[2]);
}

test "containsHeaderValue matches case-insensitively on the name only" {
    const head = "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" ++
        "Connection: Upgrade";
    try testing.expect(containsHeaderValue(head, "sec-websocket-accept", "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="));
    // The value itself is case-sensitive: base64 is.
    try testing.expect(!containsHeaderValue(head, "sec-websocket-accept", "S3PPLMBITXAQ9KYGZZHZRBK+XOO="));
}
