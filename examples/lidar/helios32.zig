//! A RoboSense Helios-32 driver: MSOP/DIFOP over UDP in, model-independent scans out.
//!
//! The second driver, and the reason for scan.zig: a consumer written against the
//! RS-LiDAR-16 driver works with this one unchanged, because everything that differs is
//! resolved here or carried in the Calibration.
//!
//! HOW IT DIFFERS FROM THE FIRST-GENERATION RS-LiDAR-16, which is the interesting part:
//!
//!   channels          32 rather than 16
//!   block meaning     ONE firing of 32 channels, not two firings of 16. Same 100-byte
//!                     block, same 12 blocks per packet -- so the same container carries
//!                     twice the beams and half the azimuths.
//!   rate              1500 packets/s at 600 rpm, not 750, and 576,000 points/s, not
//!                     288,000. Twice the load through the same pipeline.
//!   distance unit     2.5 mm rather than 5 mm, so identical counts mean half the range
//!   header            a 32-byte header carrying a UTC second count and microseconds,
//!                     rather than the first generation's 42 bytes of broken-down date
//!   angles            NOT uniformly spaced. This is the one that bites: the RS-LiDAR-16
//!                     is -15..+15 in 2 degree steps and a driver can hardcode it, while
//!                     a Helios distribution is denser near the horizon. A table compiled
//!                     in here would be wrong for most units.
//!
//! WHAT IS VERIFIED AND WHAT IS NOT. Verified against the first-generation format and
//! consistent with the published figures: the 1248-byte packet, 12 blocks of 100 bytes,
//! the 0xFFEE block flag, big-endian azimuth and distance, 32 channels per block, the
//! packet and point rates above.
//!
//! NOT verified against a datasheet, and deliberately not invented:
//!
//!   * the per-channel vertical angle table. There is no default worth trusting here, so
//!     `Calibration.from_device` starts false and `angles_are_placeholder` says so loudly.
//!     Read them from the device over DIFOP, which is what the real driver does and what
//!     this one does.
//!   * the exact field offsets inside the 32-byte header beyond the magic and the
//!     timestamp, and the DIFOP layout, which is this directory's own rather than
//!     RoboSense's.
//!   * whether a given unit is 2.5 mm or 5 mm per count. `distance_unit_mm` is one
//!     constant and it scales the entire cloud.
//!
//! Point it at real hardware and the angle table arrives from the sensor within a second.
//! Point it at the fake next door and the fake supplies a plausible non-uniform table so
//! the difference from a uniform one is visible downstream.

const std = @import("std");
const scan = @import("scan");

pub const msop_port: u16 = 6699;
pub const difop_port: u16 = 7788;

pub const msop_packet_len = 1248;
/// 32 bytes here against the first generation's 42: the newer header drops the
/// broken-down date for a UTC second count.
pub const msop_header_len = 32;
pub const msop_tail_len = 16;
pub const blocks_per_packet = scan.blocks_per_packet; // 12
pub const block_len = 100;
pub const channels = 32;
/// One firing per block, unlike the 16-channel generation.
pub const firings_per_block = 1;
pub const samples_per_block = scan.samples_per_block; // 32, all one firing
pub const sample_len = 3;

/// 0.2 degrees at 600 rpm, as on the first generation -- what changes is that a block
/// now covers one azimuth rather than two.
pub const azimuth_step_cdeg = 20;

/// 2.5 mm per count. The figure to check per unit; see the header note.
pub const distance_unit_mm: f32 = 2.5;

pub const msop_magic = [8]u8{ 0x55, 0xAA, 0x05, 0x5A, 0xA5, 0x5A, 0x50, 0xA0 };
pub const difop_magic = [8]u8{ 0xA5, 0xFF, 0x00, 0x5A, 0x11, 0x11, 0x55, 0x55 };
pub const block_flag = [2]u8{ 0xFF, 0xEE };

/// Offset of the timestamp: 6 bytes of UTC seconds then 4 of microseconds.
pub const header_timestamp_offset = 8;

comptime {
    std.debug.assert(msop_header_len + blocks_per_packet * block_len + msop_tail_len == msop_packet_len);
    std.debug.assert(2 + 2 + samples_per_block * sample_len == block_len);
    // The whole point of one firing per block: every sample slot is a distinct channel.
    std.debug.assert(channels * firings_per_block == samples_per_block);
}

/// A placeholder, and named one. Denser near the horizon than at the extremes, which is
/// the shape of a Helios distribution, but the numbers are not a datasheet's. A driver
/// running on this table rather than the device's is misreporting geometry, so
/// `angles_are_placeholder` stays true until DIFOP overwrites it.
pub const placeholder_elevations_deg = [channels]f32{
    -55.0, -42.0, -31.0, -25.0, -19.0, -16.0, -13.5, -11.5,
    -9.5,  -8.0,  -6.5,  -5.5,  -4.5,  -3.5,  -2.5,  -1.5,
    -0.5,  0.5,   1.5,   2.5,   3.5,   4.5,   5.5,   6.5,
    7.5,   8.5,   9.5,   11.0,  13.0,  15.0,  17.0,  19.0,
};

pub const ParseError = error{
    ShortPacket,
    BadMagic,
    BadBlockFlag,
};

pub fn defaultCalibration() scan.Calibration {
    var cal: scan.Calibration = .{
        .model = "RS-Helios-32",
        .rpm = 600,
        .channels = channels,
        .firings_per_block = firings_per_block,
        .azimuth_step_cdeg = azimuth_step_cdeg,
        .elevations_deg = @splat(0),
        .from_device = false,
    };
    @memcpy(cal.elevations_deg[0..channels], &placeholder_elevations_deg);
    return cal;
}

/// True while the calibration is this file's guess rather than the device's own.
pub fn anglesArePlaceholder(cal: *const scan.Calibration) bool {
    return !cal.from_device;
}

pub fn parseMsop(bytes: []const u8, seq: u64, received_us: u64) ParseError!scan.Scan {
    if (bytes.len < msop_packet_len) return error.ShortPacket;
    if (!std.mem.eql(u8, bytes[0..msop_magic.len], &msop_magic)) return error.BadMagic;

    var out: scan.Scan = .{
        .seq = seq,
        .t_us = timestampFromHeader(bytes[0..msop_header_len]) orelse received_us,
        .blocks = undefined,
    };

    for (0..blocks_per_packet) |b| {
        const at = msop_header_len + b * block_len;
        const raw = bytes[at..][0..block_len];
        if (!std.mem.eql(u8, raw[0..2], &block_flag)) return error.BadBlockFlag;

        out.blocks[b].azimuth_cdeg = std.mem.readInt(u16, raw[2..4], .big);

        for (0..samples_per_block) |i| {
            const s = raw[4 + i * sample_len ..][0..sample_len];
            const counts = std.mem.readInt(u16, s[0..2], .big);
            // The unit differs from the first generation, which is why this is not shared
            // code: the same count means a different range.
            const mm = @as(f32, @floatFromInt(counts)) * distance_unit_mm;
            out.blocks[b].samples[i] = .{
                .distance_mm = if (counts == 0) 0 else @intFromFloat(@min(mm, 65535.0)),
                .intensity = s[2],
            };
        }
    }
    return out;
}

/// Microseconds from the header's UTC seconds plus microseconds. Returns null when the
/// seconds field is zero, meaning the device did not set it.
fn timestampFromHeader(header: *const [msop_header_len]u8) ?u64 {
    const t = header[header_timestamp_offset..][0..10];
    var seconds: u64 = 0;
    for (t[0..6]) |byte| seconds = (seconds << 8) | byte; // 6 bytes, big endian
    if (seconds == 0) return null;
    const micros = std.mem.readInt(u32, t[6..10], .big);
    return seconds * 1_000_000 + micros;
}

pub fn writeMsop(
    out: *[msop_packet_len]u8,
    blocks: *const [blocks_per_packet]scan.Block,
    t_us: u64,
) void {
    @memset(out, 0);
    @memcpy(out[0..msop_magic.len], &msop_magic);

    const t = out[header_timestamp_offset..][0..10];
    const seconds = t_us / 1_000_000;
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        t[i] = @truncate(seconds >> @intCast((5 - i) * 8));
    }
    std.mem.writeInt(u32, t[6..10], @intCast(t_us % 1_000_000), .big);

    for (blocks, 0..) |block, b| {
        const at = msop_header_len + b * block_len;
        const raw = out[at..][0..block_len];
        @memcpy(raw[0..2], &block_flag);
        std.mem.writeInt(u16, raw[2..4], block.azimuth_cdeg, .big);

        for (block.samples, 0..) |sample, s_i| {
            const s = raw[4 + s_i * sample_len ..][0..sample_len];
            const counts: u16 = if (sample.distance_mm == 0)
                0
            else
                @intFromFloat(@as(f32, @floatFromInt(sample.distance_mm)) / distance_unit_mm);
            std.mem.writeInt(u16, s[0..2], counts, .big);
            s[2] = sample.intensity;
        }
    }
}

// -- DIFOP, which for this model is not optional ------------------------------------

pub const difop_packet_len = 1206;
pub const difop_rpm_offset = 8;
pub const difop_angles_offset = 32;

pub fn writeDifop(out: *[difop_packet_len]u8, cal: *const scan.Calibration) void {
    @memset(out, 0);
    @memcpy(out[0..difop_magic.len], &difop_magic);
    std.mem.writeInt(u16, out[difop_rpm_offset..][0..2], cal.rpm, .big);
    for (0..channels) |i| {
        const cdeg: i16 = @intFromFloat(cal.elevations_deg[i] * 100.0);
        std.mem.writeInt(i16, out[difop_angles_offset + i * 2 ..][0..2], cdeg, .big);
    }
}

pub fn parseDifop(bytes: []const u8, cal: *scan.Calibration) bool {
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

pub const Receiver = struct {
    io: std.Io,
    msop: std.Io.net.Socket,
    difop: ?std.Io.net.Socket,
    calibration: scan.Calibration = undefined,

    seq: u64 = 0,
    malformed: u64 = 0,
    revolutions: u64 = 0,
    last_azimuth_cdeg: u16 = 0,

    buffer: [msop_packet_len * 2]u8 = undefined,
    difop_buffer: [difop_packet_len * 2]u8 = undefined,

    pub fn init(io: std.Io, bind_addr: []const u8, msop: u16, difop: ?u16) !Receiver {
        var msop_address: std.Io.net.IpAddress = try .parse(bind_addr, msop);
        const msop_socket = try msop_address.bind(io, .{ .mode = .dgram });

        var difop_socket: ?std.Io.net.Socket = null;
        if (difop) |port| {
            var difop_address: std.Io.net.IpAddress = try .parse(bind_addr, port);
            difop_socket = difop_address.bind(io, .{ .mode = .dgram }) catch null;
        }

        return .{
            .io = io,
            .msop = msop_socket,
            .difop = difop_socket,
            .calibration = defaultCalibration(),
        };
    }

    pub fn deinit(r: *Receiver) void {
        r.msop.close(r.io);
        if (r.difop) |*d| d.close(r.io);
    }

    pub fn next(r: *Receiver) !?scan.Scan {
        const message = try r.msop.receive(r.io, &r.buffer);
        r.seq += 1;

        const now_us: u64 = @intCast(std.Io.Timestamp.now(r.io, .real).toMicroseconds());
        const parsed = parseMsop(message.data, r.seq, now_us) catch {
            r.malformed += 1;
            return null;
        };

        if (parsed.blocks[0].azimuth_cdeg < r.last_azimuth_cdeg) r.revolutions += 1;
        r.last_azimuth_cdeg = parsed.blocks[blocks_per_packet - 1].azimuth_cdeg;
        return parsed;
    }

    pub fn pollCalibration(r: *Receiver) bool {
        const socket = if (r.difop) |*d| d else return false;
        const message = socket.receiveTimeout(r.io, &r.difop_buffer, .{
            .duration = .{ .raw = std.Io.Duration.fromMilliseconds(0), .clock = .awake },
        }) catch return false;
        return parseDifop(message.data, &r.calibration);
    }
};

// -- tests --------------------------------------------------------------------------

const testing = std.testing;

test "a Helios MSOP packet survives a write and a parse" {
    var blocks: [blocks_per_packet]scan.Block = undefined;
    for (&blocks, 0..) |*block, b| {
        // One azimuth per block here, where the 16-channel generation advances twice.
        block.azimuth_cdeg = @intCast(b * azimuth_step_cdeg);
        for (&block.samples, 0..) |*sample, i| {
            // Multiples of 5 so the 2.5 mm unit divides exactly in both directions.
            sample.* = .{
                .distance_mm = @intCast((b * 32 + i) * 5),
                .intensity = @intCast((b * 32 + i) % 256),
            };
        }
    }

    var packet: [msop_packet_len]u8 = undefined;
    writeMsop(&packet, &blocks, 1_700_000_000_123_456);

    try testing.expectEqualSlices(u8, &msop_magic, packet[0..8]);
    try testing.expectEqualSlices(u8, &block_flag, packet[msop_header_len..][0..2]);

    const parsed = try parseMsop(&packet, 3, 0);
    // The device's own timestamp must come through, not the host's fallback.
    try testing.expectEqual(@as(u64, 1_700_000_000_123_456), parsed.t_us);
    for (parsed.blocks, blocks) |got, want| {
        try testing.expectEqual(want.azimuth_cdeg, got.azimuth_cdeg);
        for (got.samples, want.samples) |g, w| {
            try testing.expectEqual(w.distance_mm, g.distance_mm);
            try testing.expectEqual(w.intensity, g.intensity);
        }
    }
}

test "the two generations are not interchangeable on the wire" {
    const rs16 = @import("rs16");

    // A packet written by the first-generation driver must be refused here, and the other
    // way round. Both are 1248 bytes with 0xFFEE blocks, so only the magic distinguishes
    // them -- which is exactly why a driver checks it instead of assuming.
    var gen1_blocks: [rs16.blocks_per_packet]rs16.Block = std.mem.zeroes([rs16.blocks_per_packet]rs16.Block);
    var gen1: [rs16.msop_packet_len]u8 = undefined;
    rs16.writeMsop(&gen1, &gen1_blocks, 0);
    try testing.expectError(error.BadMagic, parseMsop(&gen1, 0, 0));

    var helios_blocks: [blocks_per_packet]scan.Block = std.mem.zeroes([blocks_per_packet]scan.Block);
    var helios: [msop_packet_len]u8 = undefined;
    writeMsop(&helios, &helios_blocks, 0);
    try testing.expectError(error.BadMagic, rs16.parseMsop(&helios, 0, 0));
}

test "the distance unit is what separates the same counts into different ranges" {
    var blocks: [blocks_per_packet]scan.Block = std.mem.zeroes([blocks_per_packet]scan.Block);
    blocks[0].samples[0] = .{ .distance_mm = 1000, .intensity = 1 };

    var packet: [msop_packet_len]u8 = undefined;
    writeMsop(&packet, &blocks, 0);

    // 1000 mm at 2.5 mm per count is 400 counts; the first generation would write 200.
    const counts = std.mem.readInt(u16, packet[msop_header_len + 4 ..][0..2], .big);
    try testing.expectEqual(@as(u16, 400), counts);

    const parsed = try parseMsop(&packet, 0, 0);
    try testing.expectEqual(@as(u16, 1000), parsed.blocks[0].samples[0].distance_mm);
}

test "the calibration says when it is a placeholder, and stops saying so after DIFOP" {
    var cal = defaultCalibration();
    // The point of the flag: nothing else tells a caller that the geometry is a guess.
    try testing.expect(anglesArePlaceholder(&cal));
    try testing.expectEqual(@as(u8, 32), cal.channels);
    try testing.expectEqual(@as(u8, 1), cal.firings_per_block);

    var from_device = defaultCalibration();
    from_device.rpm = 1200;
    for (0..channels) |i| {
        from_device.elevations_deg[i] = -30.0 + @as(f32, @floatFromInt(i)) * 1.6;
    }
    var packet: [difop_packet_len]u8 = undefined;
    writeDifop(&packet, &from_device);

    try testing.expect(parseDifop(&packet, &cal));
    try testing.expect(!anglesArePlaceholder(&cal));
    try testing.expectEqual(@as(u16, 1200), cal.rpm);
    try testing.expectApproxEqAbs(@as(f32, -30.0), cal.elevations_deg[0], 0.01);
}
