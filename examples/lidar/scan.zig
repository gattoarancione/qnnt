//! What a LiDAR driver hands out, independent of make and model.
//!
//! Both drivers in this directory produce these types and nothing else. A consumer that
//! works against them does not know whether it is fed an RS-LiDAR-16 or a Helios-32, which
//! is the point: the wire formats differ in endianness, header layout, distance units,
//! channel count and how a block is divided, and none of that survives the driver.
//!
//! The one thing a consumer does need is the vertical angle table, because it cannot
//! compute a point without it and it is not the same between models -- so `Calibration`
//! travels with the scans rather than being something the consumer compiles in.

const std = @import("std");

/// Both RoboSense generations put 12 blocks of 32 samples in a 1248-byte packet. What a
/// block *means* differs -- an RS-LiDAR-16 block is two firings of 16 channels, a Helios-32
/// block is one firing of 32 -- and that difference is expressed in the calibration's
/// `firings_per_block`, not in a different container.
pub const blocks_per_packet = 12;
pub const samples_per_block = 32;
pub const max_channels = 32;

pub const Sample = struct {
    /// Millimetres. 0 means no return -- absorbed, out of range, or sky. Never plot it.
    distance_mm: u16,
    intensity: u8,
};

pub const Block = struct {
    /// Hundredths of a degree, 0..35999. The azimuth of the block's first firing.
    azimuth_cdeg: u16,
    samples: [samples_per_block]Sample,
};

pub const Scan = struct {
    /// Packets received by this driver, not anything from the wire.
    seq: u64,
    /// The device's timestamp if its header carried a usable one, else the host's.
    t_us: u64,
    blocks: [blocks_per_packet]Block,
};

/// Everything a consumer needs to turn samples into points.
pub const Calibration = struct {
    model: []const u8,
    rpm: u16,
    /// How many channels the sensor has, and therefore how much of `elevations_deg` is
    /// meaningful.
    channels: u8,
    /// Firings packed into one block: 2 for a 16-channel sensor filling 32 sample slots,
    /// 1 for a 32-channel sensor. A consumer needs it to know whether the second half of a
    /// block belongs to the next azimuth.
    firings_per_block: u8,
    /// Azimuth advance between firings within a block, in hundredths of a degree.
    azimuth_step_cdeg: u16,
    /// Vertical angle per channel, in degrees, in channel order. Only the first `channels`
    /// entries are meaningful.
    elevations_deg: [max_channels]f32,
    /// Whether the angles above came from the device or from a table compiled in. False is
    /// a warning sign for any sensor whose spacing is not uniform.
    from_device: bool = false,
};

/// A point in the sensor's frame: x right, y forward, z up, metres.
pub const Point = struct { x: f32, y: f32, z: f32, intensity: u8 };

/// Resolve one sample of a block into a point, or null if there was no return.
///
/// Written once here rather than in each consumer, because the channel-to-azimuth mapping
/// is the part that differs between models and the part most likely to be got wrong: with
/// two firings per block, samples 16..31 belong to the *next* azimuth, not this one.
pub fn resolve(
    cal: *const Calibration,
    block: Block,
    index: usize,
) ?Point {
    const sample = block.samples[index];
    if (sample.distance_mm == 0) return null;

    const per_firing = cal.channels;
    const firing = if (per_firing == 0) 0 else index / per_firing;
    const channel = if (per_firing == 0) 0 else index % per_firing;

    const azimuth_cdeg = (@as(u32, block.azimuth_cdeg) +
        @as(u32, @intCast(firing)) * cal.azimuth_step_cdeg) % 36000;

    const azim = @as(f32, @floatFromInt(azimuth_cdeg)) * std.math.pi / 18000.0;
    const elev = cal.elevations_deg[channel] * std.math.pi / 180.0;
    const r = @as(f32, @floatFromInt(sample.distance_mm)) / 1000.0;
    const horizontal = r * @cos(elev);

    return .{
        .x = horizontal * @sin(azim),
        .y = horizontal * @cos(azim),
        .z = r * @sin(elev),
        .intensity = sample.intensity,
    };
}

test "a two-firing block puts its second half at the next azimuth" {
    var cal: Calibration = .{
        .model = "test-16",
        .rpm = 600,
        .channels = 16,
        .firings_per_block = 2,
        .azimuth_step_cdeg = 20,
        .elevations_deg = @splat(0),
    };
    cal.elevations_deg[0] = 0; // straight ahead, so the maths is checkable by hand

    var block: Block = .{ .azimuth_cdeg = 0, .samples = @splat(.{ .distance_mm = 0, .intensity = 0 }) };
    block.samples[0] = .{ .distance_mm = 1000, .intensity = 10 }; // firing 0, channel 0
    block.samples[16] = .{ .distance_mm = 1000, .intensity = 20 }; // firing 1, channel 0

    // Azimuth 0 is straight ahead: +y, x = 0.
    const first = resolve(&cal, block, 0).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0), first.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1), first.y, 1e-4);

    // The second firing is 0.2 degrees later, so it must have swung slightly to +x.
    const second = resolve(&cal, block, 16).?;
    try std.testing.expect(second.x > 0);
    try std.testing.expectApproxEqAbs(@as(f32, 1), second.y, 1e-3);
}

test "a one-firing block of 32 channels uses the block's own azimuth throughout" {
    var cal: Calibration = .{
        .model = "test-32",
        .rpm = 600,
        .channels = 32,
        .firings_per_block = 1,
        .azimuth_step_cdeg = 20,
        .elevations_deg = @splat(0),
    };

    var block: Block = .{ .azimuth_cdeg = 9000, .samples = @splat(.{ .distance_mm = 0, .intensity = 0 }) };
    block.samples[0] = .{ .distance_mm = 2000, .intensity = 1 };
    block.samples[31] = .{ .distance_mm = 2000, .intensity = 2 };

    // 90 degrees is +x. Both samples share the azimuth, unlike the 16-channel case above.
    const a = resolve(&cal, block, 0).?;
    const b = resolve(&cal, block, 31).?;
    try std.testing.expectApproxEqAbs(@as(f32, 2), a.x, 1e-3);
    try std.testing.expectApproxEqAbs(a.x, b.x, 1e-4);
}

test "no return resolves to nothing, not to the origin" {
    const cal: Calibration = .{
        .model = "test",
        .rpm = 600,
        .channels = 16,
        .firings_per_block = 2,
        .azimuth_step_cdeg = 20,
        .elevations_deg = @splat(0),
    };
    const block: Block = .{ .azimuth_cdeg = 0, .samples = @splat(.{ .distance_mm = 0, .intensity = 0 }) };
    try std.testing.expect(resolve(&cal, block, 0) == null);
}
