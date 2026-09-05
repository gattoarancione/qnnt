//! What a CAN frame looks like on a qnnt topic, and how topics are laid out.
//!
//! Its own module, and free of any Linux header, for two reasons. It is the part that can
//! be tested anywhere -- SocketCAN needs a kernel with the CAN subsystem, and a mac has
//! none -- and it is the part that defines the wire, which outlives the gateway that
//! happens to be speaking it today.
//!
//! The wire deliberately does NOT carry `struct can_frame`. That struct is a Linux ABI:
//! the identifier and three flags share one 32-bit word at bit positions the kernel chose.
//! Putting it on the network would mean every other consumer -- a CAN-FD stack, a vehicle
//! simulator, a logger written in Python -- had to know those bit positions to read a
//! payload that has nothing to do with Linux. So the flags are named fields and the
//! identifier is already masked.

const std = @import("std");
const qnnt_mod = @import("qnnt");
const tld = qnnt_mod.Tld;

/// One CAN frame, as published.
pub const Frame = struct {
    /// The identifier, already masked -- 11 bits when `ext` is false, 29 when it is true.
    id: u32,
    /// A 29-bit identifier rather than an 11-bit one. This is not cosmetic: id 0x123
    /// standard and id 0x123 extended are DIFFERENT frames to every controller on the bus,
    /// so a gateway that dropped this would merge two conversations.
    ext: bool,
    /// Remote transmission request: a request for data that carries none. `data` is empty
    /// and `dlc` is the number of bytes being asked for.
    rtr: bool,
    /// An error frame the local controller synthesised -- bus-off, arbitration lost, and
    /// so on. Published so a monitor can see it, but never written to another segment: see
    /// `writable`.
    err: bool,
    /// Data length code. The same as `data.len` for an ordinary frame; for an RTR frame it
    /// is the length being requested, and `data` is empty.
    dlc: u8,
    data: tld.Bytes,
    /// When the originating gateway read it: microseconds since the epoch, on THAT host's
    /// clock. Nothing synchronises clocks across the mesh, so this orders frames from one
    /// origin and must not be used to compare two.
    us: i64,
};

// The Linux can_id word, for the two functions that have to speak it.
pub const eff_flag: u32 = 0x8000_0000;
pub const rtr_flag: u32 = 0x4000_0000;
pub const err_flag: u32 = 0x2000_0000;
pub const sff_mask: u32 = 0x0000_07FF;
pub const eff_mask: u32 = 0x1FFF_FFFF;

/// Classic CAN. CAN FD frames carry up to 64 bytes and need CAN_RAW_FD_FRAMES on the
/// socket; this gateway does not open one, and says so rather than truncating.
pub const max_data = 8;

/// A kernel `can_frame` as read from a socket, in the form this module wants it.
pub fn fromRaw(can_id: u32, dlc: u8, data: []const u8) Frame {
    const ext = (can_id & eff_flag) != 0;
    const rtr = (can_id & rtr_flag) != 0;
    return .{
        .id = can_id & (if (ext) eff_mask else sff_mask),
        .ext = ext,
        .rtr = rtr,
        .err = (can_id & err_flag) != 0,
        .dlc = dlc,
        // An RTR frame's payload is meaningless -- the kernel does not clear it, and
        // relaying whatever happened to be in those bytes would invent data.
        .data = .{ .data = if (rtr) &.{} else data[0..@min(data.len, @min(dlc, max_data))] },
        .us = 0,
    };
}

/// The identifier word to hand back to the kernel.
pub fn rawId(frame: Frame) u32 {
    var id = frame.id & (if (frame.ext) eff_mask else sff_mask);
    if (frame.ext) id |= eff_flag;
    if (frame.rtr) id |= rtr_flag;
    return id;
}

/// Whether this frame may be written to a local bus.
///
/// Error frames are not relayed. An error frame describes a condition on the segment that
/// produced it -- a controller that went bus-off, an acknowledgement nobody gave -- and
/// injecting it into a different segment reports a fault on a bus that is perfectly
/// healthy. A receiver that acted on it would be acting on a lie.
///
/// An over-long frame is refused rather than truncated, because a controller reading eight
/// bytes of a payload meant to be longer gets plausible values rather than an error.
pub fn writable(frame: Frame) bool {
    if (frame.err) return false;
    if (frame.dlc > max_data) return false;
    if (!frame.rtr and frame.data.data.len != frame.dlc) return false;
    return true;
}

// ---------------------------------------------------------------- topics
//
// One topic per (bus, gateway): `can/<bus>/<gateway>` carries the frames THAT gateway read
// from THAT bus. So a gateway publishes on its own topic and subscribes to `can/<bus>/*`,
// which is every gateway's view of the same logical bus, its own included.
//
// `<bus>` is a LOGICAL name, not an interface name. The bus one host reaches on vcan0 may
// be vcan1 on another, and naming the wire after one host's cabling is how a segment ends
// up joined to the wrong one.

pub const prefix = "can";

/// `can/<bus>/<node>` -- where this gateway publishes what it read from `bus`.
pub fn topicFor(buf: []u8, bus: []const u8, node: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, prefix ++ "/{s}/{s}", .{ bus, node });
}

/// `can/<bus>/*` -- every gateway's view of `bus`, this one's included.
pub fn patternFor(buf: []u8, bus: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, prefix ++ "/{s}/*", .{ bus });
}

/// The gateway name a topic came from, or null if it is not one of ours. Used to skip our
/// own traffic: the pattern matches the topic we publish on, exactly as documented, and the
/// handler is given the topic name precisely so it can decide.
pub fn nodeOf(topic: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, topic, prefix ++ "/")) return null;
    const rest = topic[prefix.len + 1 ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const node = rest[slash + 1 ..];
    if (node.len == 0 or std.mem.indexOfScalar(u8, node, '/') != null) return null;
    return node;
}

/// A bus name usable in a topic. Rejecting these here is what keeps `nodeOf` and the glob
/// unambiguous: a bus called "a/b" would make `can/a/b/x` parse as bus "a" node "b/x".
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.';
        if (!ok) return false;
    }
    return true;
}

// ---------------------------------------------------------------- the golden frame
//
// `frames.hpp` declares the same struct in C++, for the station in examples/can/station.cpp,
// and the two must agree FIELD BY FIELD. Neither side errors when they do not: TLD ignores
// a key the receiving struct does not declare, and the C++ macros leave a member the frame
// did not carry exactly as its constructor left it. A renamed field is therefore a frame
// that arrives with id 0 and no payload, drawn on screen as a real frame.
//
// So it is pinned to bytes rather than to review.

/// A frame with every field set and no two values alike, so a pair of fields swapped across
/// the language boundary cannot still compare equal.
///
/// `rtr` is false and `err` is false here on purpose, and `ext` is true: a bool that is
/// false is indistinguishable from a field the other side stopped declaring, so at least
/// one of them has to be true for the check to have teeth, and `ext` is the one whose
/// meaning a reader is most likely to get wrong.
pub const canonical_frame: Frame = .{
    .id = 0x1ABCDEF,
    .ext = true,
    .rtr = false,
    .err = false,
    .dlc = 8,
    // 0x0A and 0x0D early on: a CAN payload is arbitrary bytes, and these are the two that
    // a text transport would have mangled.
    .data = .{ .data = &.{ 0xA1, 0x0A, 0x0D, 0x00, 0xFF, 0xDE, 0xAD, 0x5A } },
    .us = 1_700_000_000_123_456,
};

const golden_frame = @embedFile("testdata/can_frame.tld");

test "the canonical frame still packs to the golden bytes" {
    // To regenerate deliberately: run with QNNT_WRITE_GOLDEN set, which prints the bytes as
    // hex for you to write out. Nothing overwrites the file on its own -- reviewing the
    // change is the point of having it.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try tld.packTo(testing.allocator, &buf, canonical_frame);

    if (std.c.getenv("QNNT_WRITE_GOLDEN") != null) {
        std.debug.print("can_frame.tld = {x}\n", .{buf.items});
    }
    try testing.expectEqualSlices(u8, golden_frame, buf.items);
}

test "the golden frame unpacks back to the canonical values" {
    const back = try tld.unpackFrom(Frame, golden_frame, null);
    try testing.expectEqual(canonical_frame.id, back.id);
    try testing.expectEqual(canonical_frame.ext, back.ext);
    try testing.expectEqual(canonical_frame.rtr, back.rtr);
    try testing.expectEqual(canonical_frame.err, back.err);
    try testing.expectEqual(canonical_frame.dlc, back.dlc);
    try testing.expectEqual(canonical_frame.us, back.us);
    try testing.expectEqualSlices(u8, canonical_frame.data.data, back.data.data);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "the Linux id word decodes into named fields" {
    // Standard frame, three bytes.
    const std_frame = fromRaw(0x123, 3, &.{ 0xAA, 0xBB, 0xCC, 0, 0, 0, 0, 0 });
    try testing.expectEqual(@as(u32, 0x123), std_frame.id);
    try testing.expect(!std_frame.ext);
    try testing.expect(!std_frame.rtr);
    try testing.expect(!std_frame.err);
    try testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB, 0xCC }, std_frame.data.data);

    // Extended: the id is 29 bits and the flag is not part of it.
    const ext = fromRaw(eff_flag | 0x1ABCDEF, 0, &([_]u8{0} ** 8));
    try testing.expectEqual(@as(u32, 0x1ABCDEF), ext.id);
    try testing.expect(ext.ext);

    // A standard id is masked to 11 bits, so a stray high bit cannot travel as part of it.
    const masked = fromRaw(0xF123, 0, &([_]u8{0} ** 8));
    try testing.expectEqual(@as(u32, 0x123), masked.id);
    try testing.expect(!masked.ext);
}

test "an RTR frame carries no data, whatever the kernel buffer held" {
    // The kernel does not clear the payload of a remote request. Relaying those bytes
    // would put data on another bus that nobody ever sent.
    const rtr = fromRaw(rtr_flag | 0x201, 8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    try testing.expect(rtr.rtr);
    try testing.expectEqual(@as(usize, 0), rtr.data.data.len);
    try testing.expectEqual(@as(u8, 8), rtr.dlc);  // still says how much is being asked for
}

test "the id word round-trips" {
    for ([_]u32{ 0x000, 0x123, sff_mask }) |id| {
        try testing.expectEqual(id, rawId(fromRaw(id, 0, &([_]u8{0} ** 8))));
    }
    for ([_]u32{ 0x1ABCDEF, eff_mask, 0 }) |id| {
        const raw = eff_flag | id;
        try testing.expectEqual(raw, rawId(fromRaw(raw, 0, &([_]u8{0} ** 8))));
    }
    const rtr = rtr_flag | 0x201;
    try testing.expectEqual(rtr, rawId(fromRaw(rtr, 4, &([_]u8{0} ** 8))));
}

test "error frames are published but never written to another bus" {
    const err = fromRaw(err_flag | 0x20, 8, &([_]u8{0} ** 8));
    try testing.expect(err.err);
    try testing.expect(!writable(err));

    // Everything else about it survives, because a monitor still wants to see it.
    const ok = fromRaw(0x123, 2, &.{ 1, 2, 0, 0, 0, 0, 0, 0 });
    try testing.expect(writable(ok));
}

test "a frame whose length disagrees with its payload is refused, not truncated" {
    // What a malformed or hostile publisher looks like. Writing eight bytes of a frame that
    // claims two, or two of one that claims eight, hands a controller plausible values.
    try testing.expect(!writable(.{
        .id = 0x100, .ext = false, .rtr = false, .err = false,
        .dlc = 2, .data = .{ .data = &.{ 1, 2, 3 } }, .us = 0,
    }));
    try testing.expect(!writable(.{
        .id = 0x100, .ext = false, .rtr = false, .err = false,
        .dlc = 9, .data = .{ .data = &([_]u8{0} ** 9) }, .us = 0,
    }));
    // An RTR frame is the one case where dlc and data legitimately disagree.
    try testing.expect(writable(.{
        .id = 0x100, .ext = false, .rtr = true, .err = false,
        .dlc = 8, .data = .{ .data = &.{} }, .us = 0,
    }));
}

test "topics say which bus and which gateway" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("can/powertrain/alpha",
        try topicFor(&buf, "powertrain", "alpha"));

    var pbuf: [128]u8 = undefined;
    try testing.expectEqualStrings("can/powertrain/*", try patternFor(&pbuf, "powertrain"));

    // The pattern matches this gateway's own topic. That is the library's documented
    // behaviour, and the reason the handler has to check.
    try testing.expect(qnnt_mod.topics.globMatch(
        try patternFor(&pbuf, "powertrain"),
        try topicFor(&buf, "powertrain", "alpha"),
    ));
    // And not another bus's.
    try testing.expect(!qnnt_mod.topics.globMatch(
        try patternFor(&pbuf, "powertrain"),
        try topicFor(&buf, "body", "alpha"),
    ));
}

test "nodeOf names the gateway a frame came from" {
    try testing.expectEqualStrings("alpha", nodeOf("can/powertrain/alpha").?);
    try testing.expectEqualStrings("b-2", nodeOf("can/body/b-2").?);

    // Not one of ours, or not well formed: anything with an extra segment is ambiguous,
    // which is why validName refuses a '/' in a bus or gateway name in the first place.
    try testing.expect(nodeOf("mesh/zig") == null);
    try testing.expect(nodeOf("can/powertrain") == null);
    try testing.expect(nodeOf("can/powertrain/") == null);
    try testing.expect(nodeOf("can/a/b/c") == null);
}

test "names that would make a topic ambiguous are refused" {
    try testing.expect(validName("powertrain"));
    try testing.expect(validName("vcan0"));
    try testing.expect(validName("b-2_x.1"));

    try testing.expect(!validName(""));
    try testing.expect(!validName("a/b"));   // would parse as two segments
    try testing.expect(!validName("a*"));    // would be a glob
    try testing.expect(!validName("a b"));
    try testing.expect(!validName("a" ** 65));
}

test "a frame survives the TLD round trip" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    const sent = Frame{
        .id = 0x1ABCDEF, .ext = true, .rtr = false, .err = false,
        .dlc = 8, .data = .{ .data = &.{ 0x00, 0xFF, 0x0A, 0x0D, 1, 2, 3, 4 } },
        .us = 1_700_000_000_000_000,
    };
    try tld.packTo(testing.allocator, &buf, sent);
    const packed_bytes = buf.items;

    // No allocator: the decoded payload borrows the buffer, which is what the subscriber
    // handler does -- it writes the bytes to the socket and returns.
    const got = try tld.unpackFrom(Frame, packed_bytes, null);
    try testing.expectEqual(sent.id, got.id);
    try testing.expectEqual(sent.ext, got.ext);
    try testing.expectEqual(sent.dlc, got.dlc);
    try testing.expectEqual(sent.us, got.us);
    // 0x0A and 0x0D inside the payload: the reason these topics are TLD and not text.
    try testing.expectEqualSlices(u8, sent.data.data, got.data.data);
}
