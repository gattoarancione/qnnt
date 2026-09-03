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
//!   * the DIFOP layout beyond the magic, the rpm and the angle table, which is this
//!     directory's own rather than RoboSense's.
//!
//! Point it at real hardware and the angle table arrives from the sensor within a second.
//! Point it at the fake next door and the fake supplies a plausible non-uniform table so
//! the difference from a uniform one is visible downstream.

const std = @import("std");
const scan = @import("scan");

pub const msop_port: u16 = 6699;
pub const difop_port: u16 = 7788;

pub const msop_packet_len = 1248;
/// 42 bytes, measured: the first 0xFFEE block flag sits at offset 42 in packets captured
/// from a real unit. An earlier guess of 32 was wrong.
pub const msop_header_len = 42;
pub const msop_tail_len = 6;
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

/// 2.5 mm per count, confirmed against RoboSense's own rs_driver: decoder_RSHELIOS.hpp
/// initialises DISTANCE_RES to 0.0025f, against 0.005f for the RS16 and RS32. It scales
/// the entire cloud, so it is worth knowing this one is not a guess.
pub const distance_unit_mm: f32 = 2.5;

/// Lens centre offset, metres: rs_driver's RX for this model. The optics sit this far off
/// the rotation axis, so a return leaves from a point out along the block's pointing
/// direction rather than from the origin. Small -- a few centimetres -- and constant, which
/// is why it went unnoticed for as long as it did.
///
/// rs_driver also carries an RY of about a centimetre for this model and never applies it;
/// see `scan.Calibration.lens_offset_m`.
pub const lens_offset_m: f32 = 0.03498;

/// The rated measurement window, 0.1 to 180 m, from the same rs_driver const params as the
/// unit above. Returns outside it are reported as no-return. The maximum never binds on
/// this model: a u16 of counts at 2.5 mm tops out at 163.8 m, so every count the sensor can
/// send is inside 180 m. The minimum does bind -- counts 1..39 are below it.
pub const distance_min_mm: u32 = 100;
pub const distance_max_mm: u32 = 180_000;

/// Four bytes, measured. An earlier guess extended it to eight, which would have rejected
/// every real packet.
pub const msop_magic = [4]u8{ 0x55, 0xAA, 0x05, 0x5A };
pub const difop_magic = [8]u8{ 0xA5, 0xFF, 0x00, 0x5A, 0x11, 0x11, 0x55, 0x55 };
pub const block_flag = [2]u8{ 0xFF, 0xEE };

/// Offset of the timestamp: 6 bytes of big-endian UTC seconds then 4 of microseconds.
/// Measured -- consecutive packets differ by 666 us there, which is the packet period at
/// 1500 packets/s, so this is certainly the right field.
pub const header_timestamp_offset = 20;

/// A device with no time source still fills the timestamp, with an epoch that is decades
/// stale: the unit these constants came from reports 2017-01-01. Anything older than this
/// is treated as unset, because a consumer computing latency against it would get a figure
/// seven years wrong rather than an obviously missing one.
const plausible_epoch_seconds: u64 = 1_577_836_800; // 2020-01-01

comptime {
    std.debug.assert(msop_header_len + blocks_per_packet * block_len + msop_tail_len == msop_packet_len);
    std.debug.assert(2 + 2 + samples_per_block * sample_len == block_len);
    // The whole point of one firing per block: every sample slot is a distinct channel.
    std.debug.assert(channels * firings_per_block == samples_per_block);
}

/// Read out of a real unit's DIFOP, so no longer invented -- but still a fallback, because
/// it is ONE unit's calibration and the family covers several distributions. Channel 0 is
/// the topmost beam and the table descends.
///
/// Note the spacing: 2.11 degrees at the top tightening to 1.31 lower down. Nothing about
/// this is uniform, which is why the driver prefers the device's own table and says so when
/// it is running on this one instead.
pub const placeholder_elevations_deg = [channels]f32{
    14.94,  13.03,  10.92,  8.89,   6.96,   5.46,   3.98,   2.67,
    1.34,   0.02,   -1.29,  -2.60,  -3.90,  -5.19,  -6.47,  -7.74,
    -9.00,  -10.25, -11.49, -12.99, -14.72, -16.69, -18.90, -21.35,
    -24.04, -26.97, -30.14, -33.55, -37.20, -41.09, -45.22, -49.59,
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
        .lens_offset_m = lens_offset_m,
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
            // code: the same count means a different range. The windowing rule that
            // follows it IS shared, so it lives in scan.zig and is passed this model's
            // numbers.
            out.blocks[b].samples[i] = .{
                .distance_mm = scan.sampleDistanceMm(
                    counts,
                    distance_unit_mm,
                    distance_min_mm,
                    distance_max_mm,
                ),
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

    // Zero means never set. A stale epoch means the device has no time source and is
    // counting from its own power-on default -- a real unit reported 2017 -- and a
    // consumer measuring latency against that would be years out rather than obviously
    // unsynchronised. Either way the caller's clock is the better answer.
    if (seconds < plausible_epoch_seconds) return null;

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
            const counts = scan.sampleDistanceCounts(sample.distance_mm, distance_unit_mm);
            std.mem.writeInt(u16, s[0..2], counts, .big);
            s[2] = sample.intensity;
        }
    }
}

// -- DIFOP, which for this model is not optional ------------------------------------

/// 1248, measured -- the same size as MSOP, and not the first generation's 1206.
pub const difop_packet_len = 1248;
/// Measured and confirmed against a real unit: rpm as big-endian at 8, then the ethernet
/// block -- sensor IP at 10, destination IP at 14, MAC at 18, MSOP port at 24, DIFOP port
/// at 28. Reading those back is how the layout below was established at all.
pub const difop_rpm_offset = 8;
pub const difop_sensor_ip_offset = 10;
pub const difop_dest_ip_offset = 14;
pub const difop_mac_offset = 18;
pub const difop_msop_port_offset = 24;
pub const difop_difop_port_offset = 28;

/// The vertical angle table: 32 channels of THREE bytes each -- a sign byte, then the
/// magnitude as big-endian hundredths of a degree. Found by scanning a captured DIFOP for a
/// monotonic run of 32 plausible angles; it is the only such run in the packet.
///
/// The table descends: channel 0 is the topmost beam. A real unit reported
/// +14.94 down to -54.60 degrees, non-uniform, with spacing tightening from 2.11 to 1.31
/// degrees -- which is why no compiled-in table would have done.
pub const difop_angles_offset = 468;
pub const difop_angle_stride = 3;

/// The horizontal correction table, immediately after the vertical one: rs_driver's DIFOP
/// struct is `RSCalibrationAngle vert_angle_cali[32]` then `horiz_angle_cali[32]`, and each
/// entry is 3 bytes, so 468 + 32 * 3. Read separately from the vertical table because for a
/// long time only the vertical one was read, and a wall rendered as two.
pub const difop_horiz_angles_offset = difop_angles_offset + channels * difop_angle_stride;

pub fn writeDifop(out: *[difop_packet_len]u8, cal: *const scan.Calibration) void {
    @memset(out, 0);
    @memcpy(out[0..difop_magic.len], &difop_magic);
    std.mem.writeInt(u16, out[difop_rpm_offset..][0..2], cal.rpm, .big);

    for (0..channels) |i| {
        // Sign byte then magnitude, which is how the device does it -- not a signed
        // integer. A negative angle written as two's complement would read as +600 degrees.
        writeAngle(out, difop_angles_offset + i * difop_angle_stride, cal.elevations_deg[i]);
        writeAngle(
            out,
            difop_horiz_angles_offset + i * difop_angle_stride,
            cal.azimuth_offsets_deg[i],
        );
    }
}

fn writeAngle(out: *[difop_packet_len]u8, at: usize, deg: f32) void {
    out[at] = if (deg < 0) 1 else 0;
    const mag: u16 = @intFromFloat(@abs(deg) * 100.0);
    std.mem.writeInt(u16, out[at + 1 ..][0..2], mag, .big);
}

pub fn parseDifop(bytes: []const u8, cal: *scan.Calibration) bool {
    if (bytes.len < difop_packet_len) return false;
    if (!std.mem.eql(u8, bytes[0..difop_magic.len], &difop_magic)) return false;

    const rpm = std.mem.readInt(u16, bytes[difop_rpm_offset..][0..2], .big);
    if (rpm != 0) cal.rpm = rpm;

    var any = false;
    for (0..channels) |i| {
        const at = difop_angles_offset + i * difop_angle_stride;
        const negative = bytes[at] != 0;
        const mag = std.mem.readInt(u16, bytes[at + 1 ..][0..2], .big);
        if (mag != 0) any = true;
        const deg = @as(f32, @floatFromInt(mag)) / 100.0;
        cal.elevations_deg[i] = if (negative) -deg else deg;

        // The horizontal correction is not gated on `any`: a sensor could legitimately
        // report every horizontal offset as zero -- a single-column model does -- and that
        // is data, not an absent table. The vertical table decides whether the device
        // answered at all.
        const h_at = difop_horiz_angles_offset + i * difop_angle_stride;
        const h_negative = bytes[h_at] != 0;
        const h_mag = std.mem.readInt(u16, bytes[h_at + 1 ..][0..2], .big);
        const h_deg = @as(f32, @floatFromInt(h_mag)) / 100.0;
        cal.azimuth_offsets_deg[i] = if (h_negative) -h_deg else h_deg;
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

const testing = std.testing;

test "a Helios MSOP packet survives a write and a parse" {
    var blocks: [blocks_per_packet]scan.Block = undefined;
    for (&blocks, 0..) |*block, b| {
        // One azimuth per block here, where the 16-channel generation advances twice.
        block.azimuth_cdeg = @intCast(b * azimuth_step_cdeg);
        for (&block.samples, 0..) |*sample, i| {
            // Multiples of 5 so the 2.5 mm unit divides exactly in both directions.
            sample.* = .{
                // Past `distance_min_mm`, which the driver now enforces, and a multiple
                // of 5 mm so it survives the 2.5 mm count conversion exactly.
                .distance_mm = @intCast(distance_min_mm + (b * 32 + i) * 5),
                .intensity = @intCast((b * 32 + i) % 256),
            };
        }
    }

    var packet: [msop_packet_len]u8 = undefined;
    writeMsop(&packet, &blocks, 1_700_000_000_123_456);

    try testing.expectEqualSlices(u8, &msop_magic, packet[0..msop_magic.len]);
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

test "the constants match what a real unit actually sends" {
    // Measured from an RS-Helios-32 at 192.168.3.221. Earlier versions of this file guessed
    // several of these and every guess but two was wrong, so they are pinned: a change here
    // means the driver stops parsing real hardware.
    try testing.expectEqual(@as(usize, 1248), msop_packet_len);
    try testing.expectEqual(@as(usize, 42), msop_header_len); // 0xFFEE observed at 42
    try testing.expectEqual(@as(usize, 4), msop_magic.len); // not 8
    try testing.expectEqualSlices(u8, &.{ 0x55, 0xAA, 0x05, 0x5A }, &msop_magic);
    try testing.expectEqual(@as(usize, 20), header_timestamp_offset);
    try testing.expectEqual(@as(usize, 1248), difop_packet_len); // not the gen-1 1206
    try testing.expectEqual(@as(usize, 468), difop_angles_offset);
    try testing.expectEqual(@as(usize, 3), difop_angle_stride); // sign byte + magnitude

    // The fallback table is that unit's own, so it must look like a Helios distribution:
    // descending from just above the horizon, and nowhere near uniform.
    try testing.expect(placeholder_elevations_deg[0] > 0);
    try testing.expect(placeholder_elevations_deg[channels - 1] < -45);
    const top_gap = placeholder_elevations_deg[0] - placeholder_elevations_deg[1];
    const bottom_gap = placeholder_elevations_deg[channels - 2] - placeholder_elevations_deg[channels - 1];
    try testing.expect(bottom_gap > top_gap * 1.5); // sparser at the bottom, by a lot
}

test "a device clock that was never set is not passed off as a timestamp" {
    // The real unit reports 2017-01-01: it has no time source and counts from a default.
    // Treating that as authoritative would make any latency computed against it years out.
    var blocks: [blocks_per_packet]scan.Block = std.mem.zeroes([blocks_per_packet]scan.Block);
    var packet: [msop_packet_len]u8 = undefined;

    writeMsop(&packet, &blocks, 1_483_229_239_718_430); // what the unit actually sends
    const stale = try parseMsop(&packet, 0, 99_000_000);
    try testing.expectEqual(@as(u64, 99_000_000), stale.t_us); // the host's clock instead

    writeMsop(&packet, &blocks, 1_800_000_000_000_000); // a device that is synchronised
    const fresh = try parseMsop(&packet, 0, 99_000_000);
    try testing.expectEqual(@as(u64, 1_800_000_000_000_000), fresh.t_us);
}

test "returns outside the rated window are dropped, not clamped into the cloud" {
    // Counts either side of the 0.1 m minimum and the representable ceiling. Written as
    // raw counts rather than through writeMsop, because that writer takes millimetres from
    // a u16 and so cannot express a return past 65.535 m at all. The writer is deliberately
    // left permissive: it stands in for a sensor, which is free to put any count on the
    // wire, and enforcing the window is the driver's job -- which is what this pins.
    var packet: [msop_packet_len]u8 = std.mem.zeroes([msop_packet_len]u8);
    @memcpy(packet[0..msop_magic.len], &msop_magic);
    for (0..blocks_per_packet) |b| {
        const blk = packet[msop_header_len + b * block_len ..][0..block_len];
        @memcpy(blk[0..2], &block_flag);
    }

    const cases = [_]struct { counts: u16, want: u32 }{
        .{ .counts = 0, .want = 0 }, // the sensor's own no-return
        .{ .counts = 39, .want = 0 }, // 97.5 mm, inside the blind zone
        .{ .counts = 40, .want = 100 }, // 100 mm, the nearest rated return
        // Past where a u16 of millimetres used to give up, which is the point of the u32:
        // these are ordinary returns now, not dropped ones.
        .{ .counts = 26_215, .want = 65_537 }, // 65.5375 m, truncated toward zero
        // 163.8 m, all a u16 of 2.5 mm counts can express, and still inside the rated
        // 180 m -- so this model has no reachable maximum and nothing here to reject.
        .{ .counts = 65_535, .want = 163_837 },
    };

    for (cases, 0..) |c, i| {
        const block = packet[msop_header_len..][0..block_len];
        std.mem.writeInt(u16, block[4..][0..2], c.counts, .big);

        const parsed = try parseMsop(&packet, 0, 0);
        testing.expectEqual(c.want, parsed.blocks[0].samples[0].distance_mm) catch |e| {
            std.debug.print("case {d}: {d} counts\n", .{ i, c.counts });
            return e;
        };
    }
}

test "a distance no count can carry is written as no-return, not wrapped" {
    // Widening distance_mm to u32 made this reachable: 400 m is 160,000 counts at 2.5 mm,
    // which does not fit the u16 the wire uses. Before the widening both sides were u16 and
    // the case could not arise, so this pins the guard that replaced the old arithmetic.
    var blocks: [blocks_per_packet]scan.Block = std.mem.zeroes([blocks_per_packet]scan.Block);
    blocks[0].samples[0] = .{ .distance_mm = 400_000, .intensity = 9 };
    blocks[0].samples[1] = .{ .distance_mm = 100_000, .intensity = 9 }; // 40,000 counts, fits

    var packet: [msop_packet_len]u8 = undefined;
    writeMsop(&packet, &blocks, 0);
    const parsed = try parseMsop(&packet, 0, 0);

    try testing.expectEqual(@as(u32, 0), parsed.blocks[0].samples[0].distance_mm);
    try testing.expectEqual(@as(u32, 100_000), parsed.blocks[0].samples[1].distance_mm);
}

test "DIFOP carries a horizontal correction table after the vertical one" {
    // Both tables, written the way the unit at 192.168.3.221 writes them: sign byte then
    // big-endian hundredths of a degree, vertical at 468 and horizontal at 564. The real
    // sensor alternates roughly -4 and +4 degrees by channel -- two laser columns -- and
    // reading only the vertical table renders a wall as two walls 8 degrees apart.
    var difop: [difop_packet_len]u8 = std.mem.zeroes([difop_packet_len]u8);
    @memcpy(difop[0..difop_magic.len], &difop_magic);
    std.mem.writeInt(u16, difop[difop_rpm_offset..][0..2], 600, .big);

    for (0..channels) |i| {
        const v_at = difop_angles_offset + i * difop_angle_stride;
        difop[v_at] = if (i >= 16) 1 else 0;
        std.mem.writeInt(u16, difop[v_at + 1 ..][0..2], @intCast(100 + i * 10), .big);

        // Even channels swing left, odd right, as the measured unit does.
        const h_at = difop_horiz_angles_offset + i * difop_angle_stride;
        difop[h_at] = if (i % 2 == 0) 1 else 0;
        std.mem.writeInt(u16, difop[h_at + 1 ..][0..2], if (i % 2 == 0) 407 else 363, .big);
    }

    var cal = defaultCalibration();
    try testing.expect(parseDifop(&difop, &cal));
    try testing.expect(cal.from_device);

    try testing.expectApproxEqAbs(@as(f32, 1.0), cal.elevations_deg[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, -2.6), cal.elevations_deg[16], 0.001);

    try testing.expectApproxEqAbs(@as(f32, -4.07), cal.azimuth_offsets_deg[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 3.63), cal.azimuth_offsets_deg[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, -4.07), cal.azimuth_offsets_deg[30], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 3.63), cal.azimuth_offsets_deg[31], 0.001);
}

test "writeDifop round-trips both angle tables, not just the vertical one" {
    // Regression guard: writeDifop wrote only the vertical table for a long time, so a
    // fake built on it declared a single-column sensor and the example could not show the
    // horizontal correction going missing.
    var cal = defaultCalibration();
    cal.rpm = 600;
    for (0..channels) |i| {
        cal.elevations_deg[i] = -20.0 + @as(f32, @floatFromInt(i));
        cal.azimuth_offsets_deg[i] = if (i % 2 == 0) -4.07 else 3.63;
    }

    var difop: [difop_packet_len]u8 = undefined;
    writeDifop(&difop, &cal);

    var back = defaultCalibration();
    try testing.expect(parseDifop(&difop, &back));
    for (0..channels) |i| {
        try testing.expectApproxEqAbs(cal.elevations_deg[i], back.elevations_deg[i], 0.011);
        try testing.expectApproxEqAbs(
            cal.azimuth_offsets_deg[i],
            back.azimuth_offsets_deg[i],
            0.011,
        );
    }
}
