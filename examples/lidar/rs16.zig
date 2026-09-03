//! An RS-LiDAR-16 driver: MSOP/DIFOP over UDP in, model-independent scan packets out.
//!
//! This is the piece you would actually write for real hardware, and the reason the example
//! is split three ways. It knows about RoboSense's wire format -- big-endian azimuths,
//! 5 mm distance units, 0xFFEE block flags, the 42/1200/6 packet layout -- and nothing at
//! all about qnnt. Point it at a real sensor's IP instead of the fake and nothing else in
//! the chain changes.
//!
//!   examples/lidar/fake_rs16.zig   emits this format over UDP
//!   this module                    receives and parses it
//!   examples/lidar/sensor.zig      publishes the result as TLD
//!
//! Fidelity, stated plainly. The packet structure is faithful: 1248 bytes as 42-byte
//! header, 12 blocks of 100 bytes, 6-byte tail; each block a 0xFFEE flag, a big-endian
//! azimuth in hundredths of a degree, then 32 channels of big-endian distance and one
//! intensity byte. The 8-byte MSOP magic is faithful. What is NOT verified against a
//! datasheet: the exact offsets of the fields inside the 42-byte header beyond the magic
//! and the timestamp, and whether this model's distance unit is 5 mm or 2.5 mm -- the
//! constant is named `distance_unit_mm` and is the one number to check before pointing
//! this at real hardware.

const std = @import("std");
const scan = @import("scan");

// -- wire format --------------------------------------------------------------------
//
// Defined once, and used by both the parser here and the writer the fake uses, so the two
// cannot drift apart. The cost of sharing is that a misparse of our own format would not be
// caught by the fake; only real hardware settles that.

pub const msop_port: u16 = 6699;
pub const difop_port: u16 = 7788;

pub const msop_packet_len = 1248;
pub const msop_header_len = 42;
pub const msop_tail_len = 6;
pub const blocks_per_packet = 12;
pub const block_len = 100;
pub const channels = 16;
pub const firings_per_block = 2;
pub const samples_per_block = channels * firings_per_block; // 32
pub const sample_len = 3; // u16 distance (big endian) + u8 intensity

/// 0.2 degrees, in hundredths, between the two firings of a block.
pub const azimuth_step_cdeg = 20;

/// One distance count. The datasheet figure to verify per model: RS-LiDAR-16 is documented
/// at 5 mm, and some RoboSense models use 2.5 mm. Getting it wrong scales the whole cloud.
pub const distance_unit_mm: f32 = 5.0;

pub const msop_magic = [8]u8{ 0x55, 0xAA, 0x05, 0x0A, 0x5A, 0xA5, 0x50, 0xA0 };
pub const difop_magic = [8]u8{ 0xA5, 0xFF, 0x00, 0x5A, 0x11, 0x11, 0x55, 0x55 };
pub const block_flag = [2]u8{ 0xFF, 0xEE };

/// Offset of the 10-byte timestamp inside the header. See the fidelity note above.
pub const header_timestamp_offset = 20;

comptime {
    // The layout has to add up, or the parser and the sensor disagree about where blocks
    // start. Cheaper to assert than to debug.
    std.debug.assert(msop_header_len + blocks_per_packet * block_len + msop_tail_len == msop_packet_len);
    std.debug.assert(2 + 2 + samples_per_block * sample_len == block_len);
}

// -- what the driver hands out ------------------------------------------------------
//
// Model-independent: endianness resolved, distances in millimetres, azimuths in hundredths
// of a degree, and the vertical angles supplied alongside so a consumer needs no table of
// its own. A consumer of this has no reason to know the sensor's make.

// The vocabulary is scan.zig's, shared with the Helios driver next door, so a consumer
// written against one works with the other. Aliased rather than re-declared: two structs
// with the same fields are still two types, and the whole point is that they are not.
pub const Sample = scan.Sample;
pub const Block = scan.Block;
pub const Scan = scan.Scan;
pub const Calibration = scan.Calibration;

pub fn defaultCalibration() Calibration {
    var cal: Calibration = .{
        .model = "RS-LiDAR-16",
        .rpm = 600,
        .channels = channels,
        .firings_per_block = firings_per_block,
        .azimuth_step_cdeg = azimuth_step_cdeg,
        .elevations_deg = @splat(0),
        // Uniform 2 degree spacing IS this model's published table, so unlike the Helios
        // driver this default is trustworthy -- but DIFOP still overrides it, because a
        // unit may have been calibrated.
        .from_device = false,
    };
    @memcpy(cal.elevations_deg[0..channels], &default_elevations_deg);
    return cal;
}

/// The published RS-LiDAR-16 distribution: -15 to +15 in uniform 2 degree steps. Other
/// RoboSense models -- the Helios family in particular -- do NOT use uniform spacing, which
/// is why a driver should prefer the table the device sends over any table it ships with.
pub const default_elevations_deg = [channels]f32{
    -15, -13, -11, -9, -7, -5, -3, -1, 1, 3, 5, 7, 9, 11, 13, 15,
};

pub const ParseError = error{
    ShortPacket,
    BadMagic,
    BadBlockFlag,
};

/// Parse one MSOP packet. `bytes` must be a whole datagram.
pub fn parseMsop(bytes: []const u8, seq: u64, received_us: u64) ParseError!Scan {
    if (bytes.len < msop_packet_len) return error.ShortPacket;
    if (!std.mem.eql(u8, bytes[0..msop_magic.len], &msop_magic)) return error.BadMagic;

    var out: Scan = .{
        .seq = seq,
        .t_us = timestampFromHeader(bytes[0..msop_header_len]) orelse received_us,
        .blocks = undefined,
    };

    for (0..blocks_per_packet) |b| {
        const at = msop_header_len + b * block_len;
        const raw = bytes[at..][0..block_len];
        if (!std.mem.eql(u8, raw[0..2], &block_flag)) return error.BadBlockFlag;

        // Big-endian, both here and for distances: RoboSense puts these on the wire
        // network order, which is the single easiest thing to get wrong in this format.
        out.blocks[b].azimuth_cdeg = std.mem.readInt(u16, raw[2..4], .big);

        for (0..samples_per_block) |i| {
            const s = raw[4 + i * sample_len ..][0..sample_len];
            const counts = std.mem.readInt(u16, s[0..2], .big);
            const mm = @as(f32, @floatFromInt(counts)) * distance_unit_mm;
            out.blocks[b].samples[i] = .{
                .distance_mm = if (counts == 0) 0 else @intFromFloat(@min(mm, 65535.0)),
                .intensity = s[2],
            };
        }
    }
    return out;
}

/// The header's 10-byte timestamp, in microseconds since the epoch, if it looks populated.
/// Returns null when the sensor did not fill it -- a fake, or a unit with no GPS -- so the
/// caller can fall back to its own clock rather than reporting 1900.
fn timestampFromHeader(header: *const [msop_header_len]u8) ?u64 {
    const t = header[header_timestamp_offset..][0..10];
    const year: u16 = @as(u16, t[0]) + 1900;
    if (t[0] == 0) return null; // year 1900: not set

    const days = std.time.epoch.YearAndDay{ .year = year, .day = 0 };
    _ = days;
    // Deliberately not a full calendar conversion: the fake fills the sub-second fields,
    // which is what matters for jitter measurement, and a driver for real hardware should
    // use the DIFOP-configured time source rather than trusting this.
    const ms = std.mem.readInt(u16, t[6..8], .big);
    const us = std.mem.readInt(u16, t[8..10], .big);
    return @as(u64, ms) * 1000 + us;
}

/// Write one MSOP packet. Used by the fake sensor; kept beside the parser so the layout has
/// exactly one definition.
pub fn writeMsop(
    out: *[msop_packet_len]u8,
    blocks: *const [blocks_per_packet]Block,
    t_us: u64,
) void {
    @memset(out, 0);
    @memcpy(out[0..msop_magic.len], &msop_magic);

    // Sub-second fields of the timestamp, big-endian, and a non-zero year so a reader can
    // tell it was filled in.
    const t = out[header_timestamp_offset..][0..10];
    t[0] = 126; // 2026 - 1900, so the "is it set" test above passes
    std.mem.writeInt(u16, t[6..8], @intCast((t_us / 1000) % 1000), .big);
    std.mem.writeInt(u16, t[8..10], @intCast(t_us % 1000), .big);

    for (blocks, 0..) |block, b| {
        const at = msop_header_len + b * block_len;
        const raw = out[at..][0..block_len];
        @memcpy(raw[0..2], &block_flag);
        std.mem.writeInt(u16, raw[2..4], block.azimuth_cdeg, .big);

        for (block.samples, 0..) |sample, i| {
            const s = raw[4 + i * sample_len ..][0..sample_len];
            const counts: u16 = if (sample.distance_mm == 0)
                0
            else
                @intFromFloat(@as(f32, @floatFromInt(sample.distance_mm)) / distance_unit_mm);
            std.mem.writeInt(u16, s[0..2], counts, .big);
            s[2] = sample.intensity;
        }
    }
}

// -- DIFOP: how a driver learns the device's own calibration ------------------------
//
// A real sensor emits this once a second on its own port, carrying the serial number, the
// configured rotation rate and -- the part that matters -- the vertical angle table. A
// driver that reads it works with any channel distribution, including the non-uniform ones
// the Helios family uses, instead of trusting a table compiled in years earlier.

pub const difop_packet_len = 1206;
/// Where this implementation puts the angle table. A real DIFOP has a documented layout;
/// this is the fake's own and is not claimed to match it byte for byte.
pub const difop_rpm_offset = 8;
pub const difop_angles_offset = 32;

pub fn writeDifop(out: *[difop_packet_len]u8, cal: *const Calibration) void {
    @memset(out, 0);
    @memcpy(out[0..difop_magic.len], &difop_magic);
    std.mem.writeInt(u16, out[difop_rpm_offset..][0..2], cal.rpm, .big);

    // Angles as signed hundredths of a degree, which is how RoboSense expresses them.
    for (0..channels) |i| {
        const cdeg: i16 = @intFromFloat(cal.elevations_deg[i] * 100.0);
        std.mem.writeInt(i16, out[difop_angles_offset + i * 2 ..][0..2], cdeg, .big);
    }
}

/// Apply a DIFOP packet to a calibration. Returns whether it was understood.
pub fn parseDifop(bytes: []const u8, cal: *Calibration) bool {
    if (bytes.len < difop_packet_len) return false;
    if (!std.mem.eql(u8, bytes[0..difop_magic.len], &difop_magic)) return false;

    const rpm = std.mem.readInt(u16, bytes[difop_rpm_offset..][0..2], .big);
    if (rpm != 0) cal.rpm = rpm;

    var any = false;
    for (0..channels) |i| {
        const cdeg = std.mem.readInt(i16, bytes[difop_angles_offset + i * 2 ..][0..2], .big);
        if (cdeg != 0) any = true;
        cal.elevations_deg[i] = @as(f32, @floatFromInt(cdeg)) / 100.0;
    }
    if (any) cal.from_device = true;
    return any;
}

// -- the receiver -------------------------------------------------------------------
//
// scan.zig's, parameterised by this module. Both drivers had an identical copy of it; the
// timeouts that stop a missing sensor from parking the thread in recvfrom now exist once.
//
// One datagram per scan, which is how the sensor transmits: no reassembly, no framing, and
// a dropped packet costs exactly one packet's worth of points. That is why a LiDAR speaks
// UDP, and why a driver counts losses rather than trying to recover them.

pub const Next = scan.Next(@This());
pub const Receiver = scan.Receiver(@This());

// -- tests --------------------------------------------------------------------------
//
// The writer and the parser share their offsets, so a round trip cannot catch a
// misunderstanding of the real format -- only hardware settles that. What it does catch is
// drift: a changed offset, a flipped endianness, a distance unit edited on one side only.
// Those are the mistakes that actually happen.

const testing = std.testing;

test "an MSOP packet survives a write and a parse" {
    var blocks: [blocks_per_packet]Block = undefined;
    for (&blocks, 0..) |*block, b| {
        block.azimuth_cdeg = @intCast(b * azimuth_step_cdeg * firings_per_block);
        for (&block.samples, 0..) |*sample, i| {
            // Multiples of the distance unit, so the count conversion is exact both ways.
            sample.* = .{
                .distance_mm = @intCast((b * 32 + i) * @as(usize, @intFromFloat(distance_unit_mm))),
                .intensity = @intCast((b * 32 + i) % 256),
            };
        }
    }

    var packet: [msop_packet_len]u8 = undefined;
    writeMsop(&packet, &blocks, 1_234_567);

    // The bytes a real driver keys on, checked directly rather than only through the parser.
    try testing.expectEqualSlices(u8, &msop_magic, packet[0..8]);
    try testing.expectEqualSlices(u8, &block_flag, packet[msop_header_len..][0..2]);
    // Azimuth is big-endian on the wire: the single easiest thing to get wrong here.
    try testing.expectEqual(@as(u16, 20 * 2), std.mem.readInt(u16, packet[msop_header_len + 100 + 2 ..][0..2], .big));

    const parsed = try parseMsop(&packet, 7, 999);
    try testing.expectEqual(@as(u64, 7), parsed.seq);
    for (parsed.blocks, blocks) |got, want| {
        try testing.expectEqual(want.azimuth_cdeg, got.azimuth_cdeg);
        for (got.samples, want.samples) |g, w| {
            try testing.expectEqual(w.distance_mm, g.distance_mm);
            try testing.expectEqual(w.intensity, g.intensity);
        }
    }
}

test "a malformed packet is refused rather than misread" {
    var packet: [msop_packet_len]u8 = undefined;
    var blocks: [blocks_per_packet]Block = std.mem.zeroes([blocks_per_packet]Block);
    writeMsop(&packet, &blocks, 0);

    try testing.expectError(error.ShortPacket, parseMsop(packet[0 .. msop_packet_len - 1], 0, 0));

    var bad_magic = packet;
    bad_magic[0] = 0;
    try testing.expectError(error.BadMagic, parseMsop(&bad_magic, 0, 0));

    // A packet whose header is right but whose blocks are not: worth distinguishing,
    // because it means the layout is understood and the payload is not.
    var bad_block = packet;
    bad_block[msop_header_len] = 0;
    try testing.expectError(error.BadBlockFlag, parseMsop(&bad_block, 0, 0));
}

test "no return stays no return, rather than becoming a point at the sensor" {
    var blocks: [blocks_per_packet]Block = std.mem.zeroes([blocks_per_packet]Block);
    blocks[0].samples[0] = .{ .distance_mm = 0, .intensity = 0 };
    blocks[0].samples[1] = .{ .distance_mm = 5, .intensity = 42 };

    var packet: [msop_packet_len]u8 = undefined;
    writeMsop(&packet, &blocks, 0);
    const parsed = try parseMsop(&packet, 0, 0);

    try testing.expectEqual(@as(u16, 0), parsed.blocks[0].samples[0].distance_mm);
    try testing.expectEqual(@as(u16, 5), parsed.blocks[0].samples[1].distance_mm);
}

test "DIFOP carries the calibration a driver should prefer over its own table" {
    var cal = defaultCalibration();
    // A non-uniform table, as the Helios family has and RS-LiDAR-16 does not: the point of
    // reading DIFOP is that the driver does not have to know which it is talking to.
    const angles = [channels]f32{ -20, -16, -12, -9, -7, -5.5, -4, -2.5, -1, 0.5, 2, 4, 6.5, 9, 13, 18 };
    @memcpy(cal.elevations_deg[0..channels], &angles);
    cal.rpm = 1200;

    var packet: [difop_packet_len]u8 = undefined;
    writeDifop(&packet, &cal);

    var received = defaultCalibration();
    try testing.expect(parseDifop(&packet, &received));
    try testing.expect(received.from_device);
    try testing.expectEqual(@as(u16, 1200), received.rpm);
    for (0..channels) |i| {
        try testing.expectApproxEqAbs(cal.elevations_deg[i], received.elevations_deg[i], 0.01);
    }

    // Something that is not a DIFOP packet leaves the calibration alone.
    var untouched = defaultCalibration();
    try testing.expect(!parseDifop("not a difop packet", &untouched));
    try testing.expect(!untouched.from_device);
}
