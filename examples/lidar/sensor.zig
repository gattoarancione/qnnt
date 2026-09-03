//! The bridge: an RS-LiDAR-16 on the wire in, a qnnt topic out. See SCHEMA.txt.
//!
//!   ./zig-out/bin/fake-rs16                  # or a real sensor on the network
//!   ./zig-out/bin/lidar-sensor [bind_addr]
//!
//! This is the whole point of the three-way split. The MSOP format lives in rs16.zig, the
//! transmission lives in fake_rs16.zig or in hardware, and this file does one job: receive
//! scans from the driver, pack them as TLD, publish them. It contains no knowledge of
//! RoboSense's wire format and no scene generation -- both moved out.
//!
//! To use real hardware instead of the fake, change nothing here. Point the sensor at this
//! host and run it; the driver binds the same port either way.

const std = @import("std");
const qnnt_mod = @import("qnnt");
const qnnt = qnnt_mod.Qnnt;
const tld = @import("qnnt").Tld;
const rs16 = @import("rs16");

const allocator = std.heap.page_allocator;

const topic = "lidar/rs16";

// -- the published frame ------------------------------------------------------------
//
// Unchanged by the restructure, which is the useful part: the viewer was written against
// this schema and did not have to be touched when the sensor grew a real wire format
// underneath it.

const Block = struct {
    azimuth_cdeg: u16,
    /// 32 x (u16 distance_mm little-endian, u8 intensity). A buffer rather than 32 named
    /// objects: naming every channel would cost ten times the samples in key bytes.
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
var sample_bytes: [rs16.blocks_per_packet][rs16.samples_per_block * 3]u8 = undefined;
var block_storage: [rs16.blocks_per_packet]Block = undefined;

/// Driver output to TLD. The only transformation is endianness -- the driver hands over
/// host-order millimetres, and the frame carries little-endian, which is what every
/// consumer of this topic already expects.
fn pack(scan: rs16.Scan, cal: rs16.Calibration) ![]const u8 {
    for (scan.blocks, 0..) |block, b| {
        var out: usize = 0;
        for (block.samples) |sample| {
            std.mem.writeInt(u16, sample_bytes[b][out..][0..2], sample.distance_mm, .little);
            sample_bytes[b][out + 2] = sample.intensity;
            out += 3;
        }
        block_storage[b] = .{
            .azimuth_cdeg = block.azimuth_cdeg,
            .samples = .{ .data = &sample_bytes[b] },
        };
    }

    const packet: Packet = .{
        .seq = scan.seq,
        .t_us = scan.t_us,
        .model = cal.model,
        .rpm = cal.rpm,
        .blocks = &block_storage,
    };
    try tld.packTo(allocator, &frame_buf, packet);
    return frame_buf.items;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    const bind_addr = args.next() orelse "0.0.0.0";

    qnnt.configureFromEnvironment();
    if (!qnnt.run()) {
        std.debug.print("lidar-sensor: failed to start qnnt\n", .{});
        return;
    }
    defer qnnt.deinit();
    qnnt.installSignalHandlers();

    // A manual publisher: the sensor's own rate paces this, not a scheduler. A LiDAR
    // arrives when it arrives, and inventing a period here would either drop packets or
    // publish stale ones.
    if (!qnnt.runPublisher(topic, null, null, null)) {
        std.debug.print("lidar-sensor: failed to publish {s}\n", .{topic});
        return;
    }

    var receiver = rs16.Receiver.init(qnnt_mod.io, bind_addr, rs16.msop_port, rs16.difop_port) catch |err| {
        std.debug.print(
            "lidar-sensor: cannot bind {s}:{d} ({}) -- is another driver already running?\n",
            .{ bind_addr, rs16.msop_port, err },
        );
        return;
    };
    defer receiver.deinit();

    std.debug.print(
        "lidar-sensor: listening for MSOP on {s}:{d}, publishing {s}\n",
        .{ bind_addr, rs16.msop_port, topic },
    );

    var published: u64 = 0;
    var last_published: u64 = 0;
    var last_report_us: u64 = @intCast(qnnt.nowMicros());
    var reported_calibration = false;

    while (!qnnt.stopRequested()) {
        // A real device sends its calibration once a second; picking it up means the
        // angles come from the hardware rather than from a table compiled in years ago.
        if (receiver.pollCalibration() and !reported_calibration) {
            reported_calibration = true;
            std.debug.print(
                "lidar-sensor: calibration from the device: {d} rpm, channel 0 at {d:.1} deg\n",
                .{ receiver.calibration.rpm, receiver.calibration.elevations_deg[0] },
            );
        }

        const scan = receiver.next() catch |err| {
            if (qnnt.stopRequested()) break;
            std.debug.print("lidar-sensor: receive failed: {}\n", .{err});
            continue;
        } orelse continue; // malformed datagram, already counted

        const frame = pack(scan, receiver.calibration) catch continue;
        qnnt.publish(topic, frame) catch continue;
        published += 1;

        const now_us: u64 = @intCast(qnnt.nowMicros());
        if (now_us -| last_report_us >= 1_000_000) {
            std.debug.print(
                "lidar-sensor: {d} packets/s in, {d} published, {d} malformed, {d} revs, {d} byte frames\n",
                .{
                    published - last_published,
                    published,
                    receiver.malformed,
                    receiver.revolutions,
                    frame.len,
                },
            );
            last_published = published;
            last_report_us = now_us;
        }
    }
}
