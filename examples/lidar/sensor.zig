//! The bridge: an RS-LiDAR-16 on the wire in, a qnnt topic out. See SCHEMA.txt.
//!
//!   ./zig-out/bin/fake-rs16                        # or a real sensor on the network
//!   ./zig-out/bin/lidar-sensor rs16 [bind_addr]
//!
//!   ./zig-out/bin/fake-helios32
//!   ./zig-out/bin/lidar-sensor helios32
//!
//! With real hardware, the direction of the connection is the thing to get straight: the
//! sensor PUSHES MSOP to a destination configured on the device, and nothing here dials
//! it. Set the sensor's destination IP to this host, then:
//!
//!   ./zig-out/bin/lidar-sensor helios32 --from 192.168.3.100
//!
//! where 192.168.3.100 is the SENSOR's address, used only to discard packets from anything
//! else on the port -- not to connect anywhere.
//!
//! Two models, one bridge. Everything that differs between an RS-LiDAR-16 and a Helios-32
//! -- endianness is the same, but the header, the distance unit, the channel count and how
//! a block divides into firings are not -- is resolved by the driver, so this file switches
//! on a name and then treats them identically.
//!
//! This is the whole point of the split. The MSOP format lives in rs16.zig and helios32.zig, the
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
const scan = @import("scan");
const rs16 = @import("rs16");
const helios32 = @import("helios32");

const allocator = std.heap.page_allocator;

/// Two receivers with the same shape but different types, so the choice is a tagged union
/// rather than an interface: Zig has no vtable here and does not need one for two cases.
const Driver = union(enum) {
    rs16: rs16.Receiver,
    helios32: helios32.Receiver,

    /// Three outcomes, not two: a packet, silence, or a datagram this driver does not
    /// understand. The caller must tell them apart -- silence means check the sensor,
    /// malformed means check the model.
    const Result = union(enum) { scan: scan.Scan, timeout, malformed, foreign };

    fn next(d: *Driver) !Result {
        return switch (d.*) {
            inline else => |*r| switch (try r.next()) {
                .scan => |s| Result{ .scan = s },
                .timeout => Result.timeout,
                .malformed => Result.malformed,
                .foreign => Result.foreign,
            },
        };
    }

    fn setSource(d: *Driver, address: ?std.Io.net.IpAddress) void {
        switch (d.*) {
            inline else => |*r| r.expected_source = address,
        }
    }

    fn foreign(d: *const Driver) u64 {
        return switch (d.*) {
            inline else => |r| r.foreign,
        };
    }

    fn calibrationSettled(d: *const Driver) bool {
        return switch (d.*) {
            inline else => |*r| r.calibrationSettled(),
        };
    }

    fn timeouts(d: *const Driver) u64 {
        return switch (d.*) {
            inline else => |r| r.timeouts,
        };
    }
    fn pollCalibration(d: *Driver) bool {
        return switch (d.*) {
            inline else => |*r| r.pollCalibration(),
        };
    }
    fn calibration(d: *const Driver) scan.Calibration {
        return switch (d.*) {
            inline else => |r| r.calibration,
        };
    }
    fn malformed(d: *const Driver) u64 {
        return switch (d.*) {
            inline else => |r| r.malformed,
        };
    }
    fn revolutions(d: *const Driver) u64 {
        return switch (d.*) {
            inline else => |r| r.revolutions,
        };
    }
    fn deinit(d: *Driver) void {
        switch (d.*) {
            inline else => |*r| r.deinit(),
        }
    }
};

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
    /// Carried per frame because a consumer cannot divide a block into firings without
    /// them, and they differ by model: 16 channels in two firings, or 32 in one.
    channels: u8,
    firings_per_block: u8,
    azimuth_step_cdeg: u16,
    blocks: []const Block,
};

/// The vertical angle table, published on its own topic rather than in every frame. It
/// changes approximately never and is 32 floats: at 1500 frames/s that would be 192 KB/s
/// of unchanging data. A consumer subscribes to both and needs one calibration to start.
const CalibrationFrame = struct {
    model: []const u8,
    rpm: u16,
    channels: u8,
    firings_per_block: u8,
    azimuth_step_cdeg: u16,
    /// Degrees, in channel order; only the first `channels` are meaningful.
    elevations_deg: []const f32,
    /// False means the sensor did not supply these and the driver's own table is in use --
    /// worth surfacing, because for a Helios that means the geometry is a guess.
    from_device: bool,
};

var frame_buf: std.ArrayList(u8) = .empty;
var sample_bytes: [scan.blocks_per_packet][scan.samples_per_block * 3]u8 = undefined;
var block_storage: [scan.blocks_per_packet]Block = undefined;
var cal_buf: std.ArrayList(u8) = .empty;

/// Publish the angle table. Called once the driver has one, and again whenever it changes.
fn publishCalibration(cal: scan.Calibration, cal_topic: []const u8) !void {
    const frame: CalibrationFrame = .{
        .model = cal.model,
        .rpm = cal.rpm,
        .channels = cal.channels,
        .firings_per_block = cal.firings_per_block,
        .azimuth_step_cdeg = cal.azimuth_step_cdeg,
        .elevations_deg = cal.elevations_deg[0..cal.channels],
        .from_device = cal.from_device,
    };
    try tld.packTo(allocator, &cal_buf, frame);
    try qnnt.publish(cal_topic, cal_buf.items);
}

/// Driver output to TLD. The only transformation is endianness -- the driver hands over
/// host-order millimetres, and the frame carries little-endian, which is what every
/// consumer of this topic already expects.
fn pack(s: scan.Scan, cal: scan.Calibration) ![]const u8 {
    for (s.blocks, 0..) |block, b| {
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
        .seq = s.seq,
        .t_us = s.t_us,
        .model = cal.model,
        .rpm = cal.rpm,
        .channels = cal.channels,
        .firings_per_block = cal.firings_per_block,
        .azimuth_step_cdeg = cal.azimuth_step_cdeg,
        .blocks = &block_storage,
    };
    try tld.packTo(allocator, &frame_buf, packet);
    return frame_buf.items;
}

/// The two bind failures mean opposite things and have opposite fixes, so they are worth
/// separating: one is "this host is not the destination", the other is "something here
/// already has the port".
fn reportBindFailure(bind_addr: []const u8, port: u16, err: anyerror) void {
    switch (err) {
        error.AddressUnavailable, error.AddressNotAvailable => std.debug.print(
            "lidar-sensor: this host has no address {s}, so nothing sent there can arrive." ++
                " Bind an address this host actually has -- or 0.0.0.0 for all of them --" ++
                " and make sure the sensor's configured destination is one of them ({})\n",
            .{ bind_addr, err },
        ),
        error.AddressInUse => std.debug.print(
            "lidar-sensor: {s}:{d} is already taken -- another driver, or a fake sensor," ++
                " is holding it ({})\n",
            .{ bind_addr, port, err },
        ),
        else => std.debug.print(
            "lidar-sensor: cannot bind {s}:{d} ({})\n",
            .{ bind_addr, port, err },
        ),
    }
}

fn usage(what: []const u8) void {
    std.debug.print(
        \\lidar-sensor: unexpected argument '{s}'
        \\
        \\usage: lidar-sensor [rs16|helios32] [options]
        \\  --bind  <addr>   local interface to receive on (default 0.0.0.0, every one)
        \\  --msop  <port>   MSOP port the sensor sends to (default 6699)
        \\  --difop <port>   DIFOP port (default 7788)
        \\  --from  <addr>   accept packets only from this sensor's address
        \\
        \\A sensor PUSHES to a destination configured on the device; nothing here dials it.
        \\Set the sensor's destination to this host's address, then run this.
        \\
    , .{what});
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();

    // Which sensor is on the other end. Both speak 1248-byte MSOP with 0xFFEE blocks, and
    // only the magic distinguishes them -- so guessing is possible but pointless: a
    // deployment knows what it bought.
    var model: []const u8 = "rs16";
    var bind_addr: []const u8 = "0.0.0.0";
    var msop_port: ?u16 = null;
    var difop_port: ?u16 = null;
    var from_addr: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--bind")) {
            bind_addr = args.next() orelse return usage("--bind needs an address");
        } else if (std.mem.eql(u8, arg, "--msop")) {
            const text = args.next() orelse return usage("--msop needs a port");
            msop_port = std.fmt.parseInt(u16, text, 10) catch return usage("--msop is not a port");
        } else if (std.mem.eql(u8, arg, "--difop")) {
            const text = args.next() orelse return usage("--difop needs a port");
            difop_port = std.fmt.parseInt(u16, text, 10) catch return usage("--difop is not a port");
        } else if (std.mem.eql(u8, arg, "--from")) {
            from_addr = args.next() orelse return usage("--from needs an address");
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return usage(arg);
        } else {
            // The one positional: the model, so the short form stays `lidar-sensor rs16`.
            model = arg;
        }
    }

    const is_helios = std.mem.eql(u8, model, "helios32");
    if (!is_helios and !std.mem.eql(u8, model, "rs16")) {
        std.debug.print("lidar-sensor: unknown model '{s}' (expected rs16 or helios32)\n", .{model});
        return;
    }

    const msop = msop_port orelse if (is_helios) helios32.msop_port else rs16.msop_port;
    const difop = difop_port orelse if (is_helios) helios32.difop_port else rs16.difop_port;

    // Parsed before binding anything, so a typo fails immediately rather than after the
    // node is up and the port is taken.
    var source: ?std.Io.net.IpAddress = null;
    if (from_addr) |text| {
        source = std.Io.net.IpAddress.parse(text, 0) catch {
            std.debug.print("lidar-sensor: --from '{s}' is not an IP address\n", .{text});
            return;
        };
    }

    const topic = if (is_helios) "lidar/helios32" else "lidar/rs16";
    const cal_topic = if (is_helios) "lidar/helios32/calibration" else "lidar/rs16/calibration";

    qnnt.configureFromEnvironment();
    if (!qnnt.run()) {
        std.debug.print("lidar-sensor: failed to start qnnt\n", .{});
        return;
    }
    defer qnnt.deinit();
    qnnt.installSignalHandlers();

    // Manual publishers: the sensor's own rate paces these, not a scheduler. A LiDAR
    // arrives when it arrives, and inventing a period would drop packets or publish stale.
    if (!qnnt.runPublisher(topic, null, null, null)) {
        std.debug.print("lidar-sensor: failed to publish {s}\n", .{topic});
        return;
    }
    if (!qnnt.runPublisher(cal_topic, null, null, null)) {
        std.debug.print("lidar-sensor: failed to publish {s}\n", .{cal_topic});
        return;
    }

    var driver: Driver = if (is_helios) .{
        .helios32 = helios32.Receiver.init(qnnt_mod.io, bind_addr, msop, difop) catch |err| {
            reportBindFailure(bind_addr, msop, err);
            return;
        },
    } else .{
        .rs16 = rs16.Receiver.init(qnnt_mod.io, bind_addr, msop, difop) catch |err| {
            reportBindFailure(bind_addr, msop, err);
            return;
        },
    };
    defer driver.deinit();
    driver.setSource(source);

    var cal = driver.calibration();
    std.debug.print(
        "lidar-sensor: {s} on {s}:{d} -> {s}\n  {d} channels, {d} firing(s) per block, angles {s}\n",
        .{
            cal.model,
            bind_addr,
            msop,
            topic,
            cal.channels,
            cal.firings_per_block,
            if (cal.from_device) "from the device" else "from the driver's table (awaiting DIFOP)",
        },
    );

    // Published up front so a consumer starting first has geometry to work with, and again
    // when the device supplies its own.
    publishCalibration(cal, cal_topic) catch {};

    var published: u64 = 0;
    var last_published: u64 = 0;
    var last_report_us: u64 = @intCast(qnnt.nowMicros());

    var announced_calibration = false;
    var last_frame_len: usize = 0;
    var silent_since_us: u64 = @intCast(qnnt.nowMicros());
    var announced_silence = false;

    while (!qnnt.stopRequested()) {
        if (driver.pollCalibration()) {
            const fresh = driver.calibration();
            if (fresh.from_device != cal.from_device or fresh.rpm != cal.rpm) {
                std.debug.print(
                    "lidar-sensor: calibration from the device: {d} rpm, channel 0 at {d:.2} deg, channel {d} at {d:.2} deg\n",
                    .{ fresh.rpm, fresh.elevations_deg[0], fresh.channels - 1, fresh.elevations_deg[fresh.channels - 1] },
                );
            }
            cal = fresh;
            announced_calibration = true;
            publishCalibration(cal, cal_topic) catch {};
        }

        // "awaiting DIFOP" has to resolve into a statement one way or the other. Without
        // this the startup line was the last thing the log ever said, which read as a hang
        // -- and was one, before the driver grew a receive timeout.
        if (!announced_calibration and driver.calibrationSettled() and !cal.from_device) {
            announced_calibration = true;
            std.debug.print(
                "lidar-sensor: no DIFOP within the wait; using the driver's table" ++
                    " ({d} channels, {d:.2}..{d:.2} deg){s}\n",
                .{
                    cal.channels,
                    cal.elevations_deg[0],
                    cal.elevations_deg[cal.channels - 1],
                    if (std.mem.eql(u8, model, "helios32"))
                        " -- these are a placeholder, not this unit's geometry"
                    else
                        "",
                },
            );
        }

        const now_us: u64 = @intCast(qnnt.nowMicros());

        switch (driver.next() catch |err| {
            if (qnnt.stopRequested()) break;
            std.debug.print("lidar-sensor: receive failed: {}\n", .{err});
            continue;
        }) {
            .timeout => {
                // Nothing arrived. Say so once, with the two things worth checking, and
                // keep looping so the process stays interruptible.
                if (!announced_silence and now_us -| silent_since_us >= 3_000_000) {
                    announced_silence = true;
                    std.debug.print(
                        "lidar-sensor: no packets on {s}:{d} for 3s -- is the sensor" ++
                            " transmitting, and to this host and port?\n",
                        .{ bind_addr, msop },
                    );
                }
                continue;
            },
            .foreign => {
                // Something else is sending to this port. Named once, because with a
                // filter set it is the difference between "no data" and "data from the
                // wrong device", and those have different fixes.
                if (driver.foreign() == 1) {
                    std.debug.print(
                        "lidar-sensor: discarding packets from another sender on {d}" ++
                            " (--from is set); is more than one sensor aimed here?\n",
                        .{msop},
                    );
                }
                continue;
            },
            .malformed => {
                // A datagram arrived and was not ours. Almost always the wrong model,
                // since both generations use the same port and packet size.
                if (driver.malformed() == 1) {
                    std.debug.print(
                        "lidar-sensor: a datagram on {d} was not {s} MSOP -- wrong model?" ++
                            " the other generation uses the same port and size\n",
                        .{ msop, model },
                    );
                }
                continue;
            },
            .scan => |s| {
                if (announced_silence) {
                    std.debug.print("lidar-sensor: packets are arriving again\n", .{});
                    announced_silence = false;
                }
                silent_since_us = now_us;

                const frame = pack(s, cal) catch continue;
                qnnt.publish(topic, frame) catch continue;
                published += 1;
                last_frame_len = frame.len;
            },
        }

        if (now_us -| last_report_us >= 1_000_000) {
            std.debug.print(
                "lidar-sensor: {d} packets/s in, {d} published, {d} malformed, {d} foreign, {d} idle waits, {d} revs, {d} byte frames, angles {s}\n",
                .{
                    published - last_published,
                    published,
                    driver.malformed(),
                    driver.foreign(),
                    driver.timeouts(),
                    driver.revolutions(),
                    last_frame_len,
                    if (cal.from_device) "device" else "driver",
                },
            );
            last_published = published;
            last_report_us = now_us;
        }
    }

    std.debug.print("lidar-sensor: stopping ({d} published, {d} malformed, {d} idle waits)\n", .{
        published,
        driver.malformed(),
        driver.timeouts(),
    });
}
