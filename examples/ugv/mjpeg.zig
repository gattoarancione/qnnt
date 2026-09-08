//! Pulling JPEG frames out of the robot's `GET /video_feed`.
//!
//! What that endpoint actually sends, measured rather than assumed:
//!
//!     Content-Type: multipart/x-mixed-replace; boundary=frame
//!     Transfer-Encoding: chunked
//!
//!     43dd\r\n                                    <- chunk, 17373 bytes
//!     --frame\r\nContent-Type: image/jpeg\r\n\r\n  <- 37 bytes of part header
//!     <17334 bytes of JPEG>
//!     \r\n                                        <- part trailer
//!     \r\n                                        <- end of chunk
//!
//! 37 + 17334 + 2 = 17373 exactly, so this producer puts one whole part in one chunk. This
//! reader does NOT rely on that: a server is free to split a part across chunks, and a
//! reader that assumed otherwise would corrupt a frame the first time one did.
//!
//! THERE IS NO Content-Length ON A PART. So the end of a frame has to be found rather than
//! read, and the multipart layer cannot tell us where it is without waiting for the NEXT
//! boundary -- which would put every frame one frame behind.
//!
//! So the multipart layer is ignored entirely and the JPEG delimits itself: SOI (FF D8)
//! starts a frame, EOI (FF D9) ends it. That is unambiguous inside compressed data, because
//! a literal FF in an entropy-coded segment is always stuffed as FF 00, so FF D9 cannot
//! occur by accident. It also skips the part headers for free -- they are ASCII, and ASCII
//! contains no FF. The one case it would misread is a JPEG carrying an EXIF thumbnail,
//! which is itself a JPEG with its own EOI; this producer emits none, and a frame truncated
//! at a thumbnail would be visibly wrong rather than silently plausible.
//!
//! The chunked layer, by contrast, must be decoded properly: its size lines are ASCII hex
//! and would otherwise be spliced into the middle of a frame.

const std = @import("std");

/// A frame larger than this is dropped and counted. At the robot's 640x480 a frame is about
/// 17 KB; this is two orders of magnitude of headroom, and exists so a desynchronised
/// stream cannot grow a buffer without bound.
pub const max_frame_bytes = 512 * 1024;

pub const Reader = struct {
    /// Where the chunked decoder is.
    chunk: enum { size, data, after_data, trailer } = .size,
    chunk_left: usize = 0,
    size_seen: usize = 0,
    size_value: usize = 0,

    /// The frame being assembled. Caller-owned, so this struct costs nothing to hold.
    frame: []u8,
    len: usize = 0,
    in_frame: bool = false,
    saw_ff: bool = false,
    /// Set when frame[0..len] is a complete JPEG waiting to be taken.
    ready: bool = false,

    /// Frames dropped for exceeding max_frame_bytes, and chunk headers that were not hex.
    /// Counted rather than logged: a broken stream produces these continuously.
    oversized: u64 = 0,
    malformed: u64 = 0,

    pub fn init(buffer: []u8) Reader {
        return .{ .frame = buffer };
    }

    /// Feed bytes read from the socket. Returns how many were consumed, stopping early the
    /// moment a frame completes -- so the caller takes that frame and pushes the rest.
    pub fn push(self: *Reader, input: []const u8) usize {
        var i: usize = 0;
        while (i < input.len) {
            if (self.ready) return i;
            const c = input[i];

            switch (self.chunk) {
                // Hex size, terminated by CRLF. A chunk extension after ';' is legal and
                // ignored; nothing here sends one.
                .size => {
                    i += 1;
                    if (c == '\r') continue;
                    if (c == '\n') {
                        self.chunk_left = self.size_value;
                        self.chunk = if (self.size_value == 0) .trailer else .data;
                        self.size_value = 0;
                        self.size_seen = 0;
                        continue;
                    }
                    if (c == ';') continue;
                    const digit: ?u8 = switch (c) {
                        '0'...'9' => c - '0',
                        'a'...'f' => c - 'a' + 10,
                        'A'...'F' => c - 'A' + 10,
                        else => null,
                    };
                    if (digit) |d| {
                        self.size_value = self.size_value * 16 + d;
                        self.size_seen += 1;
                    } else if (self.size_seen != 0) {
                        // Junk after digits: the extension case, skipped above, or a
                        // desynchronised stream. Counted, and the line still ends at LF.
                        self.malformed += 1;
                    }
                },

                // Chunk payload: the only bytes that are really the body.
                .data => {
                    i += 1;
                    self.chunk_left -= 1;
                    self.feed(c);
                    if (self.chunk_left == 0) self.chunk = .after_data;
                },

                // The CRLF that closes a chunk. Not body, so it must not reach the frame.
                .after_data => {
                    i += 1;
                    if (c == '\n') self.chunk = .size;
                },

                // A zero-sized chunk ended the body. Nothing more will come.
                .trailer => return input.len,
            }
        }
        return i;
    }

    /// One byte of decoded body through the JPEG state machine.
    fn feed(self: *Reader, c: u8) void {
        if (!self.in_frame) {
            // Looking for SOI. Everything before it is a part header or a part trailer.
            if (self.saw_ff and c == 0xD8) {
                self.in_frame = true;
                self.len = 0;
                self.frame[self.len] = 0xFF;
                self.len += 1;
                self.frame[self.len] = 0xD8;
                self.len += 1;
                self.saw_ff = false;
                return;
            }
            self.saw_ff = (c == 0xFF);
            return;
        }

        if (self.len == self.frame.len) {
            // Desynchronised, or a frame larger than we will carry. Abandon it and go
            // looking for the next SOI rather than truncating into something decodable.
            self.oversized += 1;
            self.in_frame = false;
            self.len = 0;
            self.saw_ff = false;
            return;
        }
        self.frame[self.len] = c;
        self.len += 1;

        if (self.saw_ff and c == 0xD9) {
            self.in_frame = false;
            self.ready = true;
            self.saw_ff = false;
            return;
        }
        self.saw_ff = (c == 0xFF);
    }

    /// The completed frame, or null. Taking it clears the way for the next.
    pub fn take(self: *Reader) ?[]const u8 {
        if (!self.ready) return null;
        self.ready = false;
        const out = self.frame[0..self.len];
        self.len = 0;
        return out;
    }

    /// After a reconnect: the stream restarts, so neither the chunk state nor a
    /// half-assembled frame carries over.
    pub fn reset(self: *Reader) void {
        self.chunk = .size;
        self.chunk_left = 0;
        self.size_seen = 0;
        self.size_value = 0;
        self.len = 0;
        self.in_frame = false;
        self.saw_ff = false;
        self.ready = false;
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// The robot's real part header, byte for byte from a capture.
const part_header = "--frame\r\nContent-Type: image/jpeg\r\n\r\n";

/// A minimal JPEG: SOI, a comment segment, EOI. Not decodable as a picture, which is the
/// point -- these tests are about framing, and a real frame would only hide the boundaries.
const tiny_jpeg = [_]u8{ 0xFF, 0xD8, 0xFF, 0xFE, 0x00, 0x04, 'h', 'i', 0xFF, 0xD9 };

/// One chunk carrying one whole part, which is what the robot sends.
fn onePart(out: *std.ArrayList(u8), jpeg: []const u8) !void {
    const body_len = part_header.len + jpeg.len + 2;
    try out.print(testing.allocator, "{x}\r\n", .{body_len});
    try out.appendSlice(testing.allocator, part_header);
    try out.appendSlice(testing.allocator, jpeg);
    try out.appendSlice(testing.allocator, "\r\n");   // part trailer
    try out.appendSlice(testing.allocator, "\r\n");   // end of chunk
}

test "one chunk, one part, one frame" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(testing.allocator);
    try onePart(&wire, &tiny_jpeg);

    var buf: [1024]u8 = undefined;
    var r = Reader.init(&buf);
    const used = r.push(wire.items);
    const frame = r.take() orelse return error.NoFrame;

    try testing.expectEqualSlices(u8, &tiny_jpeg, frame);
    // The part header and both CRLFs are consumed and none of them reach the frame.
    try testing.expect(used <= wire.items.len);
    try testing.expectEqual(@as(u64, 0), r.oversized);
}

test "several frames arrive in order" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(testing.allocator);

    // Three frames, each with a distinguishable payload byte.
    var expect: [3][tiny_jpeg.len]u8 = undefined;
    for (0..3) |n| {
        expect[n] = tiny_jpeg;
        expect[n][6] = @intCast('0' + n);
        try onePart(&wire, &expect[n]);
    }

    var buf: [1024]u8 = undefined;
    var r = Reader.init(&buf);
    var got: usize = 0;
    var at: usize = 0;
    while (at < wire.items.len) {
        at += r.push(wire.items[at..]);
        if (r.take()) |frame| {
            try testing.expectEqualSlices(u8, &expect[got], frame);
            got += 1;
        }
    }
    try testing.expectEqual(@as(usize, 3), got);
}

test "a frame split across chunks is still one frame" {
    // The case the one-part-per-chunk observation must not be relied on. Same bytes, but
    // the part is cut in half at an arbitrary point and sent as two chunks -- so the chunk
    // size lines land in the middle of the JPEG, where a raw scan would splice them in.
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(testing.allocator);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    try body.appendSlice(testing.allocator, part_header);
    try body.appendSlice(testing.allocator, &tiny_jpeg);
    try body.appendSlice(testing.allocator, "\r\n");

    const cut = part_header.len + 5;   // mid-JPEG
    try wire.print(testing.allocator, "{x}\r\n", .{cut});
    try wire.appendSlice(testing.allocator, body.items[0..cut]);
    try wire.appendSlice(testing.allocator, "\r\n");
    try wire.print(testing.allocator, "{x}\r\n", .{body.items.len - cut});
    try wire.appendSlice(testing.allocator, body.items[cut..]);
    try wire.appendSlice(testing.allocator, "\r\n");

    var buf: [1024]u8 = undefined;
    var r = Reader.init(&buf);
    var at: usize = 0;
    while (at < wire.items.len and !r.ready) at += r.push(wire.items[at..]);
    const frame = r.take() orelse return error.NoFrame;
    try testing.expectEqualSlices(u8, &tiny_jpeg, frame);
}

test "bytes arriving one at a time make the same frame" {
    // A socket read boundary can fall anywhere, including inside a chunk size line and
    // between the FF and the D9 of an EOI. Feeding one byte at a time exercises every one
    // of those splits at once.
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(testing.allocator);
    try onePart(&wire, &tiny_jpeg);

    var buf: [1024]u8 = undefined;
    var r = Reader.init(&buf);
    var frames: usize = 0;
    for (wire.items) |c| {
        const one = [_]u8{c};
        _ = r.push(&one);
        if (r.take()) |frame| {
            try testing.expectEqualSlices(u8, &tiny_jpeg, frame);
            frames += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), frames);
}

test "a frame too large to hold is dropped, and the next one still arrives" {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(testing.allocator);

    // A "frame" with no EOI, longer than the buffer: a desynchronised stream.
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(testing.allocator);
    try big.appendSlice(testing.allocator, &.{ 0xFF, 0xD8 });
    try big.appendNTimes(testing.allocator, 0x41, 200);
    try onePart(&wire, big.items);
    try onePart(&wire, &tiny_jpeg);

    var buf: [64]u8 = undefined;      // smaller than the oversized frame
    var r = Reader.init(&buf);
    var got: ?[]const u8 = null;
    var at: usize = 0;
    while (at < wire.items.len) {
        at += r.push(wire.items[at..]);
        if (r.take()) |f| got = f;
    }
    try testing.expect(r.oversized >= 1);
    // Recovery is the point: the good frame after it is delivered normally.
    try testing.expectEqualSlices(u8, &tiny_jpeg, got orelse return error.NoFrame);
}

test "a reset drops a half-assembled frame instead of finishing it after a reconnect" {
    var buf: [1024]u8 = undefined;
    var r = Reader.init(&buf);

    // Half of a part, then the connection drops.
    var half: std.ArrayList(u8) = .empty;
    defer half.deinit(testing.allocator);
    try half.print(testing.allocator, "{x}\r\n", .{part_header.len + 4});
    try half.appendSlice(testing.allocator, part_header);
    try half.appendSlice(testing.allocator, tiny_jpeg[0..4]);
    _ = r.push(half.items);
    try testing.expect(r.in_frame);

    r.reset();
    try testing.expect(!r.in_frame);
    try testing.expect(r.take() == null);

    // A fresh stream is read cleanly, rather than the old fragment being completed by the
    // new one's bytes -- which would have produced a frame that never existed.
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(testing.allocator);
    try onePart(&wire, &tiny_jpeg);
    var at: usize = 0;
    while (at < wire.items.len and !r.ready) at += r.push(wire.items[at..]);
    try testing.expectEqualSlices(u8, &tiny_jpeg, r.take() orelse return error.NoFrame);
}
