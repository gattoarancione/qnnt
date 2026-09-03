//! A fake RS-LiDAR-16 that transmits the real thing's wire format over UDP.
//!
//!   zig build lidar && ./zig-out/bin/fake-rs16 [host] [msop_port]
//!
//! No qnnt in here at all: this process pretends to be hardware. It sends MSOP packets to
//! a destination at the rate the datasheet quotes -- 750 packets/s, 288,000 points/s -- and
//! a DIFOP packet once a second carrying the vertical angle table, which is how a driver
//! learns a device's calibration rather than assuming one.
//!
//! Ranges come from a synthetic room, so a viewer downstream shows a floor plan rather than
//! noise: four walls, two pillars, and a box that drifts.
//!
//! Send it somewhere else and it is still a sensor: `./fake-rs16 192.168.1.50` unicasts to
//! another host. The default is loopback, which is what the example uses.

const std = @import("std");
const rs16 = @import("rs16");

// -- the synthetic room -------------------------------------------------------------

const sensor_height_m: f32 = 1.0;
const room_half_x: f32 = 10.0;
const room_half_y: f32 = 7.0;

const Pillar = struct { x: f32, y: f32, r: f32 };
const pillars = [_]Pillar{
    .{ .x = 3.0, .y = 2.0, .r = 0.4 },
    .{ .x = -4.0, .y = -3.0, .r = 0.6 },
};

const intensity_wall: u8 = 120;
const intensity_pillar: u8 = 220;
const intensity_floor: u8 = 60;
const intensity_box: u8 = 255;

fn wallDistance(sin_a: f32, cos_a: f32) f32 {
    var best: f32 = 1e9;
    if (sin_a > 1e-6) best = @min(best, room_half_x / sin_a);
    if (sin_a < -1e-6) best = @min(best, -room_half_x / sin_a);
    if (cos_a > 1e-6) best = @min(best, room_half_y / cos_a);
    if (cos_a < -1e-6) best = @min(best, -room_half_y / cos_a);
    return best;
}

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

fn boxDistance(sin_a: f32, cos_a: f32, phase: f32) ?f32 {
    const cx = 6.0 * @sin(phase);
    const cy: f32 = 4.5;
    const half: f32 = 0.7;

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
    if (t_min <= t_max and t_min > 0.05) return t_min;
    return null;
}

/// One beam against the room. Distances come out in millimetres, which the writer converts
/// to the sensor's count units.
fn beam(at_cdeg: u32, elevation_deg: f32, phase: f32) rs16.Sample {
    const azim = @as(f32, @floatFromInt(at_cdeg)) * std.math.pi / 18000.0;
    const elev = elevation_deg * std.math.pi / 180.0;
    const sin_a = @sin(azim);
    const cos_a = @cos(azim);

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

    const cos_e = @cos(elev);
    var range = if (cos_e > 1e-6) horizontal / cos_e else 1e9;
    if (elev < -1e-6) {
        const floor = sensor_height_m / @sin(-elev);
        if (floor < range) {
            range = floor;
            intensity = intensity_floor;
        }
    } else if (elev > 1e-6) {
        // Upward past the walls is sky: no return at all, which is 0 on the wire.
        const ceiling = 3.0 / @sin(elev);
        if (ceiling < range) return .{ .distance_mm = 0, .intensity = 0 };
    }

    if (range > 60.0) return .{ .distance_mm = 0, .intensity = 0 };
    return .{
        .distance_mm = @intFromFloat(@min(range * 1000.0, 65535.0)),
        .intensity = intensity,
    };
}

// -- transmission -------------------------------------------------------------------

const calibration: rs16.Calibration = .{};
const revs_per_s = calibration.rpm / 60; // 10
const azimuths_per_rev = 1800;
const blocks_per_rev = azimuths_per_rev / rs16.firings_per_block; // 900
const packets_per_rev = blocks_per_rev / rs16.blocks_per_packet; // 75
const packets_per_s: u32 = packets_per_rev * revs_per_s; // 750
const packet_period_ns: i96 = 1_000_000_000 / packets_per_s; // 1333333 ns

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    const host = args.next() orelse "127.0.0.1";
    const msop_port: u16 = if (args.next()) |a|
        std.fmt.parseInt(u16, a, 10) catch rs16.msop_port
    else
        rs16.msop_port;

    var io_impl: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    // A sensor does not bind the destination's port; it sends to it. Binding 0 lets the OS
    // pick this side's source port, which is what a device on a network does.
    var any: std.Io.net.IpAddress = try .parse("0.0.0.0", 0);
    var socket = try any.bind(io, .{ .mode = .dgram });
    defer socket.close(io);

    const msop_dest: std.Io.net.IpAddress = try .parse(host, msop_port);
    const difop_dest: std.Io.net.IpAddress = try .parse(host, rs16.difop_port);

    std.debug.print(
        "fake-rs16: {s} -> {s}:{d} (MSOP) and :{d} (DIFOP)\n" ++
            "  {d} rpm, {d} packets/s, {d} points/s, {d} byte packets\n",
        .{
            calibration.model,
            host,
            msop_port,
            rs16.difop_port,
            calibration.rpm,
            packets_per_s,
            packets_per_s * rs16.samples_per_block * rs16.blocks_per_packet,
            rs16.msop_packet_len,
        },
    );

    var packet: [rs16.msop_packet_len]u8 = undefined;
    var difop: [rs16.difop_packet_len]u8 = undefined;
    rs16.writeDifop(&difop, &calibration);

    var blocks: [rs16.blocks_per_packet]rs16.Block = undefined;
    var azimuth_cdeg: u32 = 0;
    var sent: u64 = 0;
    var last_report_us: u64 = @intCast(std.Io.Timestamp.now(io, .real).toMicroseconds());
    var last_sent: u64 = 0;
    var next_ns: i96 = std.Io.Timestamp.now(io, .awake).toNanoseconds();

    while (true) {
        const now_us: u64 = @intCast(std.Io.Timestamp.now(io, .real).toMicroseconds());
        const phase = @as(f32, @floatFromInt(now_us / 1000)) / 1500.0;

        for (&blocks) |*block| {
            block.azimuth_cdeg = @intCast(azimuth_cdeg);
            var i: usize = 0;
            for (0..rs16.firings_per_block) |f| {
                const fired_at = (azimuth_cdeg + @as(u32, @intCast(f)) * rs16.azimuth_step_cdeg) % 36000;
                for (calibration.elevations_deg) |elev| {
                    block.samples[i] = beam(fired_at, elev, phase);
                    i += 1;
                }
            }
            azimuth_cdeg = (azimuth_cdeg + rs16.firings_per_block * rs16.azimuth_step_cdeg) % 36000;
        }

        rs16.writeMsop(&packet, &blocks, now_us);
        // A datagram to a port nobody has bound is silently discarded by the OS, which is
        // exactly what a real sensor experiences when its driver is not running. Not an
        // error, and not a reason to stop transmitting.
        socket.send(io, &msop_dest, &packet) catch {};
        sent += 1;

        // DIFOP once a second, as the device does.
        if (now_us -| last_report_us >= 1_000_000) {
            socket.send(io, &difop_dest, &difop) catch {};
            std.debug.print("fake-rs16: {d} packets/s sent, azimuth {d:.1} deg\n", .{
                sent - last_sent,
                @as(f32, @floatFromInt(azimuth_cdeg)) / 100.0,
            });
            last_sent = sent;
            last_report_us = now_us;
        }

        // Paced against an absolute deadline, so the cost of generating a packet does not
        // accumulate into drift -- at 750 Hz a millisecond of slippage per packet would
        // halve the rate within a second.
        next_ns += packet_period_ns;
        const now_ns = std.Io.Timestamp.now(io, .awake).toNanoseconds();
        if (next_ns > now_ns) {
            io.sleep(.fromNanoseconds(next_ns - now_ns), .awake) catch break;
        } else {
            next_ns = now_ns; // fell behind; do not try to catch up in a burst
        }
    }
}
