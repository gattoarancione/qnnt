//! A fake RS-Helios-32 transmitting the format helios32.zig parses.
//!
//!   ./zig-out/bin/fake-helios32 [host] [--msop port] [--difop port]
//!
//! Twice the RS-LiDAR-16's load through the same pipeline: 1500 packets/s and 576,000
//! points/s, because 32 channels fill a block that the older model fills with two firings
//! of 16. Same synthetic room, so the two sensors are directly comparable.
//!
//! The DIFOP it sends carries a non-uniform angle table. That is the whole reason a Helios
//! driver should read DIFOP: point this at the driver and the geometry comes off the wire.

const std = @import("std");
const scan = @import("scan");
const helios = @import("helios32");
const scene = @import("scene");

const revs_per_s = 10;
const azimuths_per_rev = 1800;
/// One firing per block here, so a block covers one azimuth and a revolution needs 1800 of
/// them -- against the 16-channel model's 900.
const blocks_per_rev = azimuths_per_rev;
const packets_per_rev = blocks_per_rev / helios.blocks_per_packet; // 150
const packets_per_s: u32 = packets_per_rev * revs_per_s; // 1500
const packet_period_ns: i96 = 1_000_000_000 / packets_per_s; // 666666 ns

fn usage(what: []const u8) void {
    std.debug.print(
        \\fake-helios32: {s}
        \\
        \\usage: fake-helios32 [host] [options]
        \\  host             where to send, as an RS-Helios-32 would (default 127.0.0.1)
        \\  --msop  <port>   MSOP destination port (default {d})
        \\  --difop <port>   DIFOP destination port (default {d})
        \\
        \\A sensor pushes to a destination; it does not listen. Point this at the host
        \\running the driver, and give the driver the matching --msop and --difop.
        \\
    , .{ what, helios.msop_port, helios.difop_port });
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    // Flags rather than positions, matching lidar-sensor's --msop and --difop, so the two
    // sides of a non-default port pair are configured with the same words.
    var host: []const u8 = "127.0.0.1";
    var msop_port: u16 = helios.msop_port;
    var difop_port: u16 = helios.difop_port;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--msop")) {
            const text = args.next() orelse return usage("--msop needs a port");
            // Refused, not silently defaulted: a typo'd port used to fall back to 6699 and
            // transmit somewhere the driver was not listening, which looks like a dead
            // sensor rather than a mistyped argument.
            msop_port = std.fmt.parseInt(u16, text, 10) catch return usage("--msop is not a port");
        } else if (std.mem.eql(u8, arg, "--difop")) {
            const text = args.next() orelse return usage("--difop needs a port");
            difop_port = std.fmt.parseInt(u16, text, 10) catch return usage("--difop is not a port");
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return usage("unrecognised option (see below)");
        } else {
            host = arg;
        }
    }

    var io_impl: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    var any: std.Io.net.IpAddress = try .parse("0.0.0.0", 0);
    var socket = try any.bind(io, .{ .mode = .dgram });
    defer socket.close(io);

    const msop_dest: std.Io.net.IpAddress = try .parse(host, msop_port);
    const difop_dest: std.Io.net.IpAddress = try .parse(host, difop_port);

    // The table this device reports. Deliberately not uniform, and deliberately not the
    // placeholder the driver ships with, so that a downstream consumer visibly gets its
    // geometry from the device rather than from a compiled guess.
    var calibration = helios.defaultCalibration();
    calibration.rpm = 600;
    for (0..helios.channels) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(helios.channels - 1));
        // Dense near the horizon and sparse at the extremes, which is the shape of a real
        // Helios distribution and the reason a driver cannot assume uniform spacing. The
        // numbers are still invented -- see the note in helios32.zig -- but the character
        // is right, so a consumer that mishandles a non-uniform table shows it.
        const u = 2.0 * t - 1.0; // -1 at the bottom beam, +1 at the top
        const shaped = std.math.pow(f32, @abs(u), 1.6);
        calibration.elevations_deg[i] = if (u < 0) -50.0 * shaped else 15.0 * shaped;
        // Two columns, alternating by channel, at roughly the spread the measured unit
        // reports. Without this the fake is a single-column sensor and the example never
        // exercises the horizontal correction -- which is how reading only the vertical
        // table went unnoticed until a real wall rendered twice.
        calibration.azimuth_offsets_deg[i] = if (i % 2 == 0) -4.07 else 3.63;
    }

    std.debug.print(
        "fake-helios32: {s} -> {s}:{d} (MSOP) and :{d} (DIFOP)\n" ++
            "  {d} rpm, {d} packets/s, {d} points/s, {d} channels, {d} byte packets\n" ++
            "  angles {d:.1} to {d:.1} deg, non-uniform (sent over DIFOP)\n",
        .{
            calibration.model,
            host,
            msop_port,
            difop_port,
            calibration.rpm,
            packets_per_s,
            packets_per_s * helios.samples_per_block * helios.blocks_per_packet,
            helios.channels,
            helios.msop_packet_len,
            calibration.elevations_deg[0],
            calibration.elevations_deg[helios.channels - 1],
        },
    );

    var packet: [helios.msop_packet_len]u8 = undefined;
    var difop: [helios.difop_packet_len]u8 = undefined;
    helios.writeDifop(&difop, &calibration);

    var blocks: [helios.blocks_per_packet]scan.Block = undefined;
    var azimuth_cdeg: u32 = 0;
    var sent: u64 = 0;
    var last_sent: u64 = 0;
    var last_report_us: u64 = @intCast(std.Io.Timestamp.now(io, .real).toMicroseconds());
    var next_ns: i96 = std.Io.Timestamp.now(io, .awake).toNanoseconds();

    while (true) {
        const now_us: u64 = @intCast(std.Io.Timestamp.now(io, .real).toMicroseconds());
        const phase = @as(f32, @floatFromInt(now_us / 1000)) / 1500.0;

        for (&blocks) |*block| {
            block.azimuth_cdeg = @intCast(azimuth_cdeg);
            // One firing: every sample slot is its own channel, no interleave.
            for (0..helios.channels) |ch| {
                // The real unit's lasers sit in two columns, so each channel's ray leaves
                // at its own azimuth. Cast through the same correction the DIFOP declares,
                // or the driver would apply an offset this scene never used and the fake
                // would disagree with itself.
                const offset_cdeg: i32 =
                    @intFromFloat(calibration.azimuth_offsets_deg[ch] * 100.0);
                const ray_cdeg: u32 =
                    @intCast(@mod(@as(i32, @intCast(azimuth_cdeg)) + offset_cdeg, 36000));
                const hit = scene.beam(ray_cdeg, calibration.elevations_deg[ch], phase);
                block.samples[ch] = .{ .distance_mm = hit.distance_mm, .intensity = hit.intensity };
            }
            azimuth_cdeg = (azimuth_cdeg + helios.azimuth_step_cdeg) % 36000;
        }

        helios.writeMsop(&packet, &blocks, now_us);
        socket.send(io, &msop_dest, &packet) catch {};
        sent += 1;

        if (now_us -| last_report_us >= 1_000_000) {
            socket.send(io, &difop_dest, &difop) catch {};
            std.debug.print("fake-helios32: {d} packets/s sent, azimuth {d:.1} deg\n", .{
                sent - last_sent,
                @as(f32, @floatFromInt(azimuth_cdeg)) / 100.0,
            });
            last_sent = sent;
            last_report_us = now_us;
        }

        next_ns += packet_period_ns;
        const now_ns = std.Io.Timestamp.now(io, .awake).toNanoseconds();
        if (next_ns > now_ns) {
            io.sleep(.fromNanoseconds(next_ns - now_ns), .awake) catch break;
        } else {
            next_ns = now_ns;
        }
    }
}
