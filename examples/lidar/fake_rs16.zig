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
const scan = @import("scan");
const scene = @import("scene");

// -- transmission -------------------------------------------------------------------

const calibration = rs16.defaultCalibration();
const revs_per_s = calibration.rpm / 60; // 10
const azimuths_per_rev = 1800;
const blocks_per_rev = azimuths_per_rev / rs16.firings_per_block; // 900
const packets_per_rev = blocks_per_rev / rs16.blocks_per_packet; // 75
const packets_per_s: u32 = packets_per_rev * revs_per_s; // 750
const packet_period_ns: i96 = 1_000_000_000 / packets_per_s; // 1333333 ns

fn usage(what: []const u8) void {
    std.debug.print(
        \\fake-rs16: {s}
        \\
        \\usage: fake-rs16 [host] [options]
        \\  host             where to send, as an RS-LiDAR-16 would (default 127.0.0.1)
        \\  --msop  <port>   MSOP destination port (default {d})
        \\  --difop <port>   DIFOP destination port (default {d})
        \\
        \\A sensor pushes to a destination; it does not listen. Point this at the host
        \\running the driver, and give the driver the matching --msop and --difop.
        \\
    , .{ what, rs16.msop_port, rs16.difop_port });
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    // Flags rather than positions, matching lidar-sensor's --msop and --difop, so the two
    // sides of a non-default port pair are configured with the same words.
    var host: []const u8 = "127.0.0.1";
    var msop_port: u16 = rs16.msop_port;
    var difop_port: u16 = rs16.difop_port;

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

    // A sensor does not bind the destination's port; it sends to it. Binding 0 lets the OS
    // pick this side's source port, which is what a device on a network does.
    var any: std.Io.net.IpAddress = try .parse("0.0.0.0", 0);
    var socket = try any.bind(io, .{ .mode = .dgram });
    defer socket.close(io);

    const msop_dest: std.Io.net.IpAddress = try .parse(host, msop_port);
    const difop_dest: std.Io.net.IpAddress = try .parse(host, difop_port);

    std.debug.print(
        "fake-rs16: {s} -> {s}:{d} (MSOP) and :{d} (DIFOP)\n" ++
            "  {d} rpm, {d} packets/s, {d} points/s, {d} byte packets\n",
        .{
            calibration.model,
            host,
            msop_port,
            difop_port,
            calibration.rpm,
            packets_per_s,
            packets_per_s * rs16.samples_per_block * rs16.blocks_per_packet,
            rs16.msop_packet_len,
        },
    );

    var packet: [rs16.msop_packet_len]u8 = undefined;
    var difop: [rs16.difop_packet_len]u8 = undefined;
    rs16.writeDifop(&difop, &calibration);

    var blocks: [rs16.blocks_per_packet]scan.Block = undefined;
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
                for (calibration.elevations_deg[0..rs16.channels]) |elev| {
                    const hit = scene.beam(fired_at, elev, phase);
                    block.samples[i] = .{ .distance_mm = hit.distance_mm, .intensity = hit.intensity };
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
