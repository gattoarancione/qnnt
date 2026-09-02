//! A fake RS-LiDAR-16, published as TLD at the rate a real one transmits. See SCHEMA.txt.
//!
//!   zig build lidar && ./zig-out/bin/lidar-sensor [seconds]
//!
//! 750 frames per second, one per MSOP packet, each carrying 12 blocks of 32 samples --
//! 288,000 points/s, the same figure the datasheet quotes. Ranges come from a synthetic
//! room so that a viewer shows a floor plan rather than noise.

const std = @import("std");
const qnnt = @import("qnnt").Qnnt;
const tld = @import("qnnt").Tld;

const allocator = std.heap.page_allocator;

const topic = "lidar/rs16";

// -- the sensor's numbers, from the datasheet ---------------------------------------

const model = "RS-LiDAR-16";
const rpm: u16 = 600; // 10 revolutions per second
const channels = 16; // vertical beams
const firings_per_block = 2; // MSOP packs two firings of 16 into one 100-byte block
const blocks_per_packet = 12;
const azimuth_step_cdeg = 20; // 0.2 degrees, in hundredths
const azimuths_per_rev = 1800;
const blocks_per_rev = azimuths_per_rev / firings_per_block; // 900
const packets_per_rev = blocks_per_rev / blocks_per_packet; // 75
const revs_per_s = rpm / 60; // 10
const packets_per_s: u32 = packets_per_rev * revs_per_s; // 750
const packet_period_us: u64 = 1_000_000 / packets_per_s; // 1333 us

/// Fixed vertical angles, -15..+15 in 2 degree steps.
const elevations_deg = [channels]f32{
    -15, -13, -11, -9, -7, -5, -3, -1, 1, 3, 5, 7, 9, 11, 13, 15,
};

// -- the synthetic room -------------------------------------------------------------

const sensor_height_m: f32 = 1.0;
const room_half_x: f32 = 10.0;
const room_half_y: f32 = 7.0;

const Pillar = struct { x: f32, y: f32, r: f32 };
const pillars = [_]Pillar{
    .{ .x = 3.0, .y = 2.0, .r = 0.4 },
    .{ .x = -4.0, .y = -3.0, .r = 0.6 },
};

/// Intensity by surface, so a viewer colouring by it separates wall from pillar from floor.
const intensity_wall: u8 = 120;
const intensity_pillar: u8 = 220;
const intensity_floor: u8 = 60;
const intensity_box: u8 = 255;

/// Distance along a horizontal ray to the room's walls. The room is convex, so the nearest
/// wall in the ray's direction is the answer -- no iteration needed.
fn wallDistance(sin_a: f32, cos_a: f32) f32 {
    var best: f32 = 1e9;
    // x = +-room_half_x, y = +-room_half_y; the ray is (sin_a, cos_a) from the origin.
    if (sin_a > 1e-6) best = @min(best, room_half_x / sin_a);
    if (sin_a < -1e-6) best = @min(best, -room_half_x / sin_a);
    if (cos_a > 1e-6) best = @min(best, room_half_y / cos_a);
    if (cos_a < -1e-6) best = @min(best, -room_half_y / cos_a);
    return best;
}

/// Distance to a circle along a ray from the origin, or null if it misses. The usual
/// quadratic; only the nearer root matters, and only if it is in front.
fn circleDistance(sin_a: f32, cos_a: f32, cx: f32, cy: f32, r: f32) ?f32 {
    const b = 2.0 * (sin_a * -cx + cos_a * -cy);
    const c = cx * cx + cy * cy - r * r;
    const disc = b * b - 4.0 * c;
    if (disc < 0) return null;
    const root = @sqrt(disc);
    const t0 = (-b - root) / 2.0;
    if (t0 > 0.05) return t0;
    const t1 = (-b + root) / 2.0;
    if (t1 > 0.05) return t1;
    return null;
}

/// The moving box, as an axis-aligned rectangle drifting along x. Returned as a circle-ish
/// distance via its four edges, which is enough for a fake.
fn boxDistance(sin_a: f32, cos_a: f32, phase: f32) ?f32 {
    const cx = 6.0 * @sin(phase);
    const cy: f32 = 4.5;
    const half: f32 = 0.7;

    var best: ?f32 = null;
    // Slab intersection against the rectangle.
    var t_min: f32 = 0.05;
    var t_max: f32 = 1e9;

    if (@abs(sin_a) < 1e-6) {
        if (@abs(-cx) > half) return null;
    } else {
        const t1 = (cx - half) / sin_a;
        const t2 = (cx + half) / sin_a;
        t_min = @max(t_min, @min(t1, t2));
        t_max = @min(t_max, @max(t1, t2));
    }
    if (@abs(cos_a) < 1e-6) {
        if (@abs(-cy) > half) return null;
    } else {
        const t1 = (cy - half) / cos_a;
        const t2 = (cy + half) / cos_a;
        t_min = @max(t_min, @min(t1, t2));
        t_max = @min(t_max, @max(t1, t2));
    }
    if (t_min <= t_max and t_min > 0.05) best = t_min;
    return best;
}

const Sample = struct { distance_mm: u16, intensity: u8 };

/// One beam: azimuth and elevation in, range and intensity out.
fn beam(at_cdeg: u32, elevation_deg: f32, phase: f32) Sample {
    const azim = @as(f32, @floatFromInt(at_cdeg)) * std.math.pi / 18000.0;
    const elev = elevation_deg * std.math.pi / 180.0;
    const sin_a = @sin(azim);
    const cos_a = @cos(azim);

    // Nearest horizontal obstruction, and what it was.
    var horizontal = wallDistance(sin_a, cos_a);
    var intensity = intensity_wall;

    for (pillars) |p| {
        if (circleDistance(sin_a, cos_a, p.x, p.y, p.r)) |d| {
            if (d < horizontal) {
                horizontal = d;
                intensity = intensity_pillar;
            }
        }
    }
    if (boxDistance(sin_a, cos_a, phase)) |d| {
        if (d < horizontal) {
            horizontal = d;
            intensity = intensity_box;
        }
    }

    // A downward beam may reach the floor before it reaches anything vertical.
    const cos_e = @cos(elev);
    var range = if (cos_e > 1e-6) horizontal / cos_e else 1e9;
    if (elev < -1e-6) {
        const floor = sensor_height_m / @sin(-elev);
        if (floor < range) {
            range = floor;
            intensity = intensity_floor;
        }
    } else if (elev > 1e-6) {
        // Upward past the walls is the ceiling-less sky: no return at all, which is a
        // distance of 0 on the wire and must be skipped by a consumer rather than plotted.
        const ceiling = 3.0 / @sin(elev);
        if (ceiling < range) return .{ .distance_mm = 0, .intensity = 0 };
    }

    if (range > 60.0) return .{ .distance_mm = 0, .intensity = 0 };
    return .{
        .distance_mm = @intFromFloat(@min(range * 1000.0, 65535.0)),
        .intensity = intensity,
    };
}

// -- the frame ----------------------------------------------------------------------

const Block = struct {
    azimuth_cdeg: u16,
    /// 32 x (u16 distance_mm little-endian, u8 intensity), MSOP's own layout. A buffer
    /// rather than 32 objects: naming every channel would cost ten times the samples.
    samples: tld.Bytes,
};

const Packet = struct {
    seq: u64,
    t_us: u64,
    model: []const u8,
    rpm: u16,
    blocks: []const Block,
};

var frame_buf: std.ArrayList(u8) = .empty;
var seq: u64 = 0;
var azimuth_cdeg: u32 = 0;

// One packet's worth of sample bytes, filled in place each tick.
var sample_bytes: [blocks_per_packet][channels * firings_per_block * 3]u8 = undefined;
var block_storage: [blocks_per_packet]Block = undefined;

var points_emitted = std.atomic.Value(u64).init(0);
var returns_emitted = std.atomic.Value(u64).init(0);

fn produce(_: []const u8, _: ?*anyopaque) ?[]const u8 {
    seq += 1;
    const now_us: u64 = @intCast(qnnt.nowMicros());
    // One phase for the whole packet: the box does not move measurably in 1.3 ms.
    const phase = @as(f32, @floatFromInt(now_us / 1000)) / 1500.0;

    for (0..blocks_per_packet) |b| {
        const base_azimuth = azimuth_cdeg;
        var out: usize = 0;

        for (0..firings_per_block) |f| {
            const fired_at = (base_azimuth + @as(u32, @intCast(f)) * azimuth_step_cdeg) % 36000;
            for (elevations_deg) |elev| {
                const sample = beam(fired_at, elev, phase);
                std.mem.writeInt(u16, sample_bytes[b][out..][0..2], sample.distance_mm, .little);
                sample_bytes[b][out + 2] = sample.intensity;
                out += 3;
                if (sample.distance_mm != 0) _ = returns_emitted.fetchAdd(1, .monotonic);
                _ = points_emitted.fetchAdd(1, .monotonic);
            }
        }

        block_storage[b] = .{
            .azimuth_cdeg = @intCast(base_azimuth),
            .samples = .{ .data = &sample_bytes[b] },
        };
        azimuth_cdeg = (base_azimuth + firings_per_block * azimuth_step_cdeg) % 36000;
    }

    const packet: Packet = .{
        .seq = seq,
        .t_us = now_us,
        .model = model,
        .rpm = rpm,
        .blocks = &block_storage,
    };

    tld.packTo(allocator, &frame_buf, packet) catch return null;
    return frame_buf.items;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    var run_s: u64 = 0; // 0 means until interrupted
    if (args.next()) |a| run_s = std.fmt.parseInt(u64, a, 10) catch 0;

    qnnt.configureFromEnvironment();
    if (!qnnt.run()) {
        std.debug.print("lidar-sensor: failed to start\n", .{});
        return;
    }
    defer qnnt.deinit();
    qnnt.installSignalHandlers();

    // One packet built here, only to report the frame size next to MSOP's -- and built
    // BEFORE the publisher starts. runPublisher's scheduler begins ticking the moment it is
    // called, so calling produce() afterwards would have two threads in the same global
    // frame buffer at once; the first run of this example panicked inside the encoder
    // because of exactly that.
    const sample_len = (produce(topic, null) orelse return).len;
    seq = 0;
    azimuth_cdeg = 0;
    points_emitted.store(0, .monotonic);
    returns_emitted.store(0, .monotonic);

    if (!qnnt.runPublisher(topic, produce, packet_period_us, null)) {
        std.debug.print("lidar-sensor: failed to publish {s}\n", .{topic});
        return;
    }

    std.debug.print(
        "lidar-sensor: {s} on {s}\n" ++
            "  {d} rpm, {d} packets/s, {d} points/s\n" ++
            "  {d} byte frames vs 1248 on the wire ({d} bytes of self-description)\n",
        .{
            model,                                            topic,
            rpm,                                              packets_per_s,
            packets_per_s * blocks_per_packet * channels * firings_per_block,
            sample_len,                                       @as(i64, @intCast(sample_len)) - 1248,
        },
    );

    // Wait for a viewer before pouring 750 frames a second at nobody. Announced first:
    // otherwise the sensor looks hung for the duration of the wait.
    std.debug.print("lidar-sensor: waiting up to 5s for a subscriber\n", .{});
    if (qnnt.waitForSubscriber(topic, 5_000)) {
        std.debug.print("lidar-sensor: subscriber attached, transmitting\n", .{});
    } else {
        std.debug.print("lidar-sensor: no subscriber yet, transmitting anyway\n", .{});
    }

    const deadline_us: u64 = if (run_s == 0)
        std.math.maxInt(u64)
    else
        @as(u64, @intCast(qnnt.nowMicros())) + run_s * 1_000_000;

    var last_points: u64 = 0;
    while (!qnnt.stopRequested() and @as(u64, @intCast(qnnt.nowMicros())) < deadline_us) {
        qnnt.sleepMs(1000);
        const now = points_emitted.load(.monotonic);
        const returns = returns_emitted.load(.monotonic);
        std.debug.print("lidar-sensor: {d} points/s, {d}% returns, seq {d}\n", .{
            now - last_points,
            if (now == 0) 0 else returns * 100 / now,
            seq,
        });
        last_points = now;
    }
}
