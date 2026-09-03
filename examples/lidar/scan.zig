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

// -- the receiver, generic over a driver --------------------------------------------
//
// Both drivers had a byte-identical Receiver, differing only in which parse function and
// packet lengths they used. That duplication was about to be edited in two places at once,
// which is how two copies stop being identical, so it lives here parameterised instead.
//
// `Driver` is a driver module: rs16.zig or helios32.zig, passed as @This().

/// What one call to `next` produced. Three outcomes, named, because a caller must be able
/// to tell "nothing is arriving" from "something arrived and was wrong" -- the first means
/// check the cable, the second means check the model.
pub fn Next(comptime _: type) type {
    return union(enum) {
        scan: Scan,
        /// Nothing arrived within the receive timeout. Not an error: a sensor that is off,
        /// unplugged, or on another port looks exactly like this, and the caller decides
        /// what to say about it.
        timeout,
        /// A datagram arrived and was not a packet this driver understands -- wrong model,
        /// truncated, or not a LiDAR at all.
        malformed,
    };
}

pub fn Receiver(comptime Driver: type) type {
    return struct {
        const Self = @This();

        io: std.Io,
        msop: std.Io.net.Socket,
        difop: ?std.Io.net.Socket,
        calibration: Calibration,

        /// How long one `next` call waits before reporting a timeout.
        ///
        /// It exists because the alternative is a blocking receive, and a blocking receive
        /// with no sensor on the other end parks the thread in recvfrom where a signal
        /// cannot reach it: the process ignored SIGINT entirely and had to be killed. Any
        /// bounded wait fixes that; half a second keeps the loop responsive without
        /// spinning.
        receive_timeout_ms: u32 = 500,

        /// How long to wait for the device's own calibration before settling for the
        /// driver's table. Announced once, either way, so "awaiting DIFOP" always resolves
        /// into a decision instead of being the last thing a log ever says.
        calibration_timeout_ms: u32 = 3000,

        seq: u64 = 0,
        malformed: u64 = 0,
        timeouts: u64 = 0,
        revolutions: u64 = 0,
        last_azimuth_cdeg: u16 = 0,

        started_us: u64 = 0,
        calibration_settled: bool = false,

        buffer: [Driver.msop_packet_len * 2]u8 = undefined,
        difop_buffer: [Driver.difop_packet_len * 2]u8 = undefined,

        pub fn init(io: std.Io, bind_addr: []const u8, msop: u16, difop: ?u16) !Self {
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
                .calibration = Driver.defaultCalibration(),
                .started_us = @intCast(std.Io.Timestamp.now(io, .real).toMicroseconds()),
            };
        }

        pub fn deinit(r: *Self) void {
            r.msop.close(r.io);
            if (r.difop) |*d| d.close(r.io);
        }

        /// Wait up to `receive_timeout_ms` for one packet.
        pub fn next(r: *Self) !Next(Driver) {
            const message = r.msop.receiveTimeout(r.io, &r.buffer, .{
                .duration = .{
                    .raw = std.Io.Duration.fromMilliseconds(r.receive_timeout_ms),
                    // The monotonic clock: a wall-clock adjustment must not extend or
                    // collapse the wait.
                    .clock = .awake,
                },
            }) catch |err| switch (err) {
                error.Timeout => {
                    r.timeouts += 1;
                    return .timeout;
                },
                else => return err,
            };

            r.seq += 1;
            const now_us: u64 = @intCast(std.Io.Timestamp.now(r.io, .real).toMicroseconds());
            const parsed = Driver.parseMsop(message.data, r.seq, now_us) catch {
                r.malformed += 1;
                return .malformed;
            };

            if (parsed.blocks[0].azimuth_cdeg < r.last_azimuth_cdeg) r.revolutions += 1;
            r.last_azimuth_cdeg = parsed.blocks[blocks_per_packet - 1].azimuth_cdeg;
            return .{ .scan = parsed };
        }

        /// Take any pending DIFOP packet, without blocking. Returns true when it changed
        /// the calibration.
        pub fn pollCalibration(r: *Self) bool {
            const socket = if (r.difop) |*d| d else {
                r.calibration_settled = true; // no DIFOP socket: nothing to wait for
                return false;
            };

            const message = socket.receiveTimeout(r.io, &r.difop_buffer, .{
                .duration = .{ .raw = std.Io.Duration.fromMilliseconds(0), .clock = .awake },
            }) catch {
                // Nothing waiting. Give up on the device's table once the window has
                // passed, so a caller can stop saying "awaiting" and say what it settled on.
                if (!r.calibration_settled) {
                    const now_us: u64 = @intCast(std.Io.Timestamp.now(r.io, .real).toMicroseconds());
                    if (now_us -| r.started_us >= @as(u64, r.calibration_timeout_ms) * 1000) {
                        r.calibration_settled = true;
                    }
                }
                return false;
            };

            const changed = Driver.parseDifop(message.data, &r.calibration);
            if (changed) r.calibration_settled = true;
            return changed;
        }

        /// True once the calibration question is answered: either the device supplied a
        /// table, or the wait for one expired.
        pub fn calibrationSettled(r: *const Self) bool {
            return r.calibration_settled;
        }
    };
}

test "a receiver with nobody sending times out rather than blocking forever" {
    // The bug this pins: a blocking receive parked the thread in recvfrom, where the
    // process could not even be interrupted -- SIGINT was ignored and it had to be killed.
    const Fake = struct {
        pub const msop_packet_len = 64;
        pub const difop_packet_len = 64;
        pub fn defaultCalibration() Calibration {
            return .{
                .model = "fake",
                .rpm = 600,
                .channels = 16,
                .firings_per_block = 2,
                .azimuth_step_cdeg = 20,
                .elevations_deg = @splat(0),
            };
        }
        pub fn parseMsop(_: []const u8, _: u64, _: u64) !Scan {
            return error.BadMagic;
        }
        pub fn parseDifop(_: []const u8, _: *Calibration) bool {
            return false;
        }
    };

    var io_impl: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    // Port 0 lets the OS pick, so this test cannot collide with a real driver or another
    // test run.
    var receiver = try Receiver(Fake).init(io, "127.0.0.1", 0, null);
    defer receiver.deinit();
    receiver.receive_timeout_ms = 50;
    receiver.calibration_timeout_ms = 10;

    const before = std.Io.Timestamp.now(io, .awake).toNanoseconds();
    const result = try receiver.next();
    const elapsed_ms = @divTrunc(std.Io.Timestamp.now(io, .awake).toNanoseconds() - before, 1_000_000);

    try std.testing.expect(result == .timeout);
    try std.testing.expectEqual(@as(u64, 1), receiver.timeouts);
    // Bounded, and actually waited: neither a hang nor a busy spin.
    try std.testing.expect(elapsed_ms >= 40);
    try std.testing.expect(elapsed_ms < 2000);

    // With no DIFOP socket at all there is nothing to await, so the question is settled
    // immediately rather than left open.
    _ = receiver.pollCalibration();
    try std.testing.expect(receiver.calibrationSettled());
}

test "the calibration wait expires instead of staying open forever" {
    const Fake = struct {
        pub const msop_packet_len = 64;
        pub const difop_packet_len = 64;
        pub fn defaultCalibration() Calibration {
            return .{
                .model = "fake",
                .rpm = 600,
                .channels = 32,
                .firings_per_block = 1,
                .azimuth_step_cdeg = 20,
                .elevations_deg = @splat(0),
            };
        }
        pub fn parseMsop(_: []const u8, _: u64, _: u64) !Scan {
            return error.BadMagic;
        }
        pub fn parseDifop(_: []const u8, _: *Calibration) bool {
            return false;
        }
    };

    var io_impl: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    // A DIFOP socket that exists and never receives anything: the case a real driver hits
    // when the sensor is off.
    var receiver = try Receiver(Fake).init(io, "127.0.0.1", 0, 0);
    defer receiver.deinit();
    receiver.calibration_timeout_ms = 60;

    try std.testing.expect(!receiver.calibrationSettled());
    _ = receiver.pollCalibration();
    try std.testing.expect(!receiver.calibrationSettled()); // too early to give up

    try io.sleep(.fromMilliseconds(100), .awake);
    _ = receiver.pollCalibration();
    try std.testing.expect(receiver.calibrationSettled()); // and now it has
    // Settling does not fabricate a device table.
    try std.testing.expect(!receiver.calibration.from_device);
}
