//! The vocabulary a depth camera produces, and the geometry to turn it into points.
//!
//! Deliberately the same shape as examples/lidar/scan.zig: a model-independent frame type,
//! the intrinsics needed to interpret it, and a generic receiver a driver plugs into. What
//! a consumer sees does not name a manufacturer, so a second camera means a second driver
//! and nothing else.
//!
//! One structural difference from the LiDAR chain, and it is worth being blunt about. An
//! RS-Helios pushes UDP datagrams whose layout is real and discoverable, so that fake
//! reproduces a wire that exists -- and was checked against hardware. A ZED X has no network
//! protocol at all: it runs GMSL2 coax into a ZED Link card and is read through the ZED SDK
//! (`sl::Camera::retrieveMeasure`). There is no wire to imitate, so the framing in zed.zig
//! is THIS DIRECTORY'S OWN, standing in for the SDK boundary rather than reproducing
//! anything. Everything from the driver's output onwards is a faithful analogue; that one
//! seam is invented, and no amount of it passing tests makes it verified.

const std = @import("std");
const shm = @import("shm");

/// Enough for a ZED 2i's 2K mode, 2208x1242, which is the largest native geometry either
/// camera produces. The fake transmits at native resolution -- that is the point of it --
/// and the DECISION about how much to put on qnnt belongs at the bridge, not here.
///
/// The two buffers this sizes come to 16.5 MB, which is why an Assembler is always heap
/// allocated and never a local.
pub const max_width = 2208;
pub const max_height = 1242;
pub const max_pixels = @as(usize, max_width) * max_height;

/// What the camera needs to be interpreted: a pinhole model plus the stereo baseline.
///
/// `from_device` distinguishes intrinsics the sensor reported from the driver's built-in
/// defaults, for the same reason the LiDAR driver does: a plausible-looking cloud built on
/// guessed intrinsics is worse than no cloud, because nothing about it looks wrong.
pub const Intrinsics = struct {
    model: []const u8,
    width: u16,
    height: u16,
    /// Focal lengths in pixels, at THIS width and height. A downscaled frame has downscaled
    /// intrinsics, so these travel with the frame size rather than being quoted for the
    /// sensor's native resolution.
    fx: f32,
    fy: f32,
    /// Principal point, pixels.
    cx: f32,
    cy: f32,
    /// Stereo baseline. Not used to deproject a depth map -- depth is already metric by the
    /// time it arrives -- but it is what bounds the achievable depth precision, so it is
    /// published rather than dropped.
    baseline_mm: f32,
    /// The range the sensor is rated for. Outside it a depth value is noise, and the driver
    /// discards it for the same reason the LiDAR drivers apply their rated window.
    depth_min_mm: u16,
    depth_max_mm: u16,
    from_device: bool = false,
};

/// One assembled frame. The slices borrow the driver's buffers and are valid until the next
/// frame is received.
pub const StereoFrame = struct {
    seq: u32,
    /// The sensor's own clock, microseconds, or the host's if the sensor did not set it.
    t_us: u64,
    width: u16,
    height: u16,
    /// Depth in millimetres, row-major, `width * height` entries. 0 means no depth here --
    /// too near, too far, occluded, or untextured. A stereo camera produces a great deal of
    /// it, unlike a LiDAR's occasional dropout, so a consumer must skip rather than plot.
    depth_mm: []const u16,
    /// Luminance, row-major, same count. The left rectified image, which is the one depth
    /// is registered to.
    mono: []const u8,
    /// Frames the consumer skipped before this one, because the camera did not wait for it.
    ///
    /// This replaced a `rows_missing` count. Over UDP a frame could arrive with holes in it;
    /// across shared memory it cannot -- a frame is published whole or not at all -- so the
    /// only thing a slow consumer loses is whole frames, and that is what gets reported.
    missed: u64 = 0,

    pub fn pixels(f: StereoFrame) usize {
        return @as(usize, f.width) * f.height;
    }
};

/// One deprojected point, in the same frame the LiDAR examples use: x right, y forward,
/// z up, metres. NOT the camera convention (x right, y DOWN, z forward) -- converted here
/// so a consumer can hold one world frame for a camera and a LiDAR together.
pub const Point = struct { x: f32, y: f32, z: f32, intensity: u8 };

/// Deproject one pixel. Null when there is no depth there, or when the depth is outside the
/// rated window.
///
/// The pinhole model: a pixel `step` from the principal point subtends `step / f` radians,
/// so at depth z it is `(u - cx) * z / fx` across. Nothing here needs the baseline; the
/// baseline set the precision of z long before this.
pub fn deproject(intr: *const Intrinsics, f: StereoFrame, u: u16, v: u16) ?Point {
    if (u >= f.width or v >= f.height) return null;

    const at = @as(usize, v) * f.width + u;
    const mm = f.depth_mm[at];
    if (mm == 0) return null;
    if (mm < intr.depth_min_mm or mm > intr.depth_max_mm) return null;

    const z_m = @as(f32, @floatFromInt(mm)) / 1000.0;
    const cam_x = (@as(f32, @floatFromInt(u)) - intr.cx) * z_m / intr.fx;
    const cam_y = (@as(f32, @floatFromInt(v)) - intr.cy) * z_m / intr.fy;

    // Camera to world: the camera looks along its own +z, which is the world's +y, and its
    // +y points down, which is the world's -z.
    return .{
        .x = cam_x,
        .y = z_m,
        .z = -cam_y,
        .intensity = f.mono[at],
    };
}

/// Deproject the whole frame, taking every `step`-th pixel in each axis, into `out`.
/// Returns how many points were written.
///
/// Subsampled because a full frame is not a sensible thing to publish: 320x200 is 64,000
/// points, and at 13 bytes and 15 Hz that is 12 MB/s for one topic. `step` is the honest
/// knob for that, and the count it returns is what the caller should report -- not the
/// pixel count, which would overstate what was sent.
pub fn deprojectInto(
    intr: *const Intrinsics,
    f: StereoFrame,
    step: u16,
    out: []Point,
) usize {
    if (step == 0) return 0;

    var n: usize = 0;
    var v: u16 = 0;
    while (v < f.height) : (v += step) {
        var u: u16 = 0;
        while (u < f.width) : (u += step) {
            if (n == out.len) return n;
            if (deproject(intr, f, u, v)) |p| {
                out[n] = p;
                n += 1;
            }
        }
    }
    return n;
}

/// What a driver hands back per poll. Same shape as scan.Next, and for the same reason: a
/// receiver that can only block cannot be shut down, and a driver that returns `timeout`
/// lets the caller decide whether to keep waiting.
pub fn Next(comptime _: type) type {
    return union(enum) {
        /// A whole frame, copied out of the shared region.
        frame: StereoFrame,
        /// No new frame within the receive window.
        timeout,
    };
}

// -- tests ----------------------------------------------------------------------------

const testing = std.testing;

fn testIntrinsics() Intrinsics {
    return .{
        .model = "test",
        .width = 4,
        .height = 4,
        // A principal point in the middle of a 4x4 frame sits at 1.5, and fx = 4 makes the
        // arithmetic checkable by hand.
        .fx = 4.0,
        .fy = 4.0,
        .cx = 1.5,
        .cy = 1.5,
        .baseline_mm = 120.0,
        .depth_min_mm = 300,
        .depth_max_mm = 20_000,
    };
}

test "deprojection puts the principal ray straight ahead" {
    var depth: [16]u16 = @splat(0);
    var mono: [16]u8 = @splat(200);
    const intr = testIntrinsics();

    // A pixel at the principal point deprojects to straight ahead: no x, no z, all range.
    // cx is 1.5, so no pixel sits exactly on it -- (1,1) and (2,2) straddle it evenly.
    depth[1 * 4 + 1] = 2000;
    depth[2 * 4 + 2] = 2000;

    const f: StereoFrame = .{
        .seq = 1,
        .t_us = 0,
        .width = 4,
        .height = 4,
        .depth_mm = &depth,
        .mono = &mono,
        .missed = 0,
    };

    const a = deproject(&intr, f, 1, 1).?;
    const b = deproject(&intr, f, 2, 2).?;

    // Symmetric about the principal point, so mirrored in x and z, same range.
    try testing.expectApproxEqAbs(@as(f32, 2.0), a.y, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 2.0), b.y, 1e-5);
    try testing.expectApproxEqAbs(a.x, -b.x, 1e-5);
    try testing.expectApproxEqAbs(a.z, -b.z, 1e-5);

    // (u - cx) * z / fx = (1 - 1.5) * 2 / 4 = -0.25
    try testing.expectApproxEqAbs(@as(f32, -0.25), a.x, 1e-5);
    // v below the principal point is world +z, because the camera's y points down.
    try testing.expectApproxEqAbs(@as(f32, 0.25), a.z, 1e-5);
    try testing.expectEqual(@as(u8, 200), a.intensity);
}

test "no depth and out-of-range depth both decline" {
    var depth: [16]u16 = @splat(0);
    var mono: [16]u8 = @splat(0);
    const intr = testIntrinsics();

    depth[0] = 0; // no depth: the common case for a stereo camera
    depth[1] = 299; // under the rated minimum
    depth[2] = 20_001; // over the rated maximum
    depth[3] = 1000; // fine

    const f: StereoFrame = .{
        .seq = 1,
        .t_us = 0,
        .width = 4,
        .height = 4,
        .depth_mm = &depth,
        .mono = &mono,
        .missed = 0,
    };

    try testing.expect(deproject(&intr, f, 0, 0) == null);
    try testing.expect(deproject(&intr, f, 1, 0) == null);
    try testing.expect(deproject(&intr, f, 2, 0) == null);
    try testing.expect(deproject(&intr, f, 3, 0) != null);

    // Off the edge is null rather than a wrapped read.
    try testing.expect(deproject(&intr, f, 4, 0) == null);
    try testing.expect(deproject(&intr, f, 0, 4) == null);
}

test "subsampling takes every step-th pixel and counts only what it wrote" {
    var depth: [16]u16 = @splat(1000);
    var mono: [16]u8 = @splat(10);
    const intr = testIntrinsics();

    const f: StereoFrame = .{
        .seq = 1,
        .t_us = 0,
        .width = 4,
        .height = 4,
        .depth_mm = &depth,
        .mono = &mono,
        .missed = 0,
    };

    var out: [16]Point = undefined;
    try testing.expectEqual(@as(usize, 16), deprojectInto(&intr, f, 1, &out));
    try testing.expectEqual(@as(usize, 4), deprojectInto(&intr, f, 2, &out));
    try testing.expectEqual(@as(usize, 1), deprojectInto(&intr, f, 4, &out));

    // Holes are skipped, so the count is points and not pixels -- which is the number a
    // caller should report.
    @memset(&depth, 0);
    depth[0] = 1000;
    try testing.expectEqual(@as(usize, 1), deprojectInto(&intr, f, 1, &out));

    // A short output buffer stops rather than overruns.
    @memset(&depth, 1000);
    var small: [3]Point = undefined;
    try testing.expectEqual(@as(usize, 3), deprojectInto(&intr, f, 1, &small));

    // A zero step would not terminate; it returns nothing instead.
    try testing.expectEqual(@as(usize, 0), deprojectInto(&intr, f, 0, &out));
}

/// The consumer's side of the camera handoff: a bounded-wait reader over the shared region.
///
/// Bounded because the alternative is a loop that spins or one that blocks forever, and a
/// driver that cannot be stopped is not usable. It polls the published sequence number,
/// which is one atomic load, and sleeps between attempts.
///
/// Notice what it no longer contains, compared with the UDP version this replaced: no chunk
/// bitmap, no reassembly, no receive buffer to tune, no per-datagram parse, no malformed
/// count, no `rows_missing`. Shared memory hands over a whole frame or nothing, so all of
/// that was machinery for a problem the real SDK boundary does not have.
pub fn Receiver(comptime Driver: type) type {
    return struct {
        const Self = @This();

        io: std.Io,
        region: shm.Region,
        intrinsics: Intrinsics,
        /// Whether the camera says it carries inertial and environmental sensors. Reported by
        /// the calibration block rather than assumed from the model, so a consumer follows
        /// what the device claims.
        has_sensors: bool = false,

        /// Where the frame's planes are copied to. Owned here because the slot they came
        /// from is the producer's and may be reused at any moment.
        depth: []u16,
        mono: []u8,

        /// How long `next` waits before reporting a timeout.
        receive_timeout_ms: u32 = 500,
        /// How long between polls. 500 us against a 33 ms frame period is under 2% of a
        /// frame of latency, for one atomic load per poll.
        poll_interval_us: u32 = 500,

        /// How long to wait for the camera's own intrinsics before settling for the driver's
        /// nominal ones. Announced either way, so "awaiting calibration" always resolves into
        /// a decision rather than being the last thing a log says.
        calibration_timeout_ms: u32 = 3000,

        last_seq: u64 = 0,
        calib_seen: u32 = 0,
        sensors_cursor: u64 = 0,

        frames: u64 = 0,
        /// Frames the producer wrote that this consumer never saw, because it was busy. The
        /// honest form of "the camera did not wait", and the number that replaced a packet
        /// loss count that modelled nothing.
        missed: u64 = 0,
        /// Slots the producer lapped mid-copy. Should be zero; if it is not, the consumer is
        /// so far behind that the ring is too small for it.
        torn: u64 = 0,
        timeouts: u64 = 0,
        sensors_lost: u64 = 0,

        started_us: u64 = 0,
        calibration_settled: bool = false,

        /// Open the region the camera created, or fail if it is not there yet.
        pub fn init(
            io: std.Io,
            allocator: std.mem.Allocator,
            model: Driver.Model,
            path: [:0]const u8,
        ) !Self {
            const region = try shm.open(path);

            const n = @as(usize, region.width()) * region.height();
            if (n == 0 or n > max_pixels) return error.BadGeometry;

            return .{
                .io = io,
                .region = region,
                // Nominal intrinsics for the geometry the CAMERA is actually sending, not
                // for the spec table's headline mode.
                //
                // A real ZED 2i found this. Its spec row says 1920x1080, which is what the
                // SDK can do; over UVC on this machine it offers 672x376 and nothing else.
                // Taking the fallback from the table gave focal lengths 2.86x too long for
                // the frames arriving, and every deprojected point with them. The fake never
                // caught it because a fake built from the spec table always agrees with the
                // spec table.
                .intrinsics = Driver.intrinsicsFor(
                    Driver.spec(model),
                    region.width(),
                    region.height(),
                ),
                .depth = try allocator.alloc(u16, n),
                .mono = try allocator.alloc(u8, n),
                .started_us = @intCast(std.Io.Timestamp.now(io, .real).toMicroseconds()),
            };
        }

        pub fn deinit(r: *Self, allocator: std.mem.Allocator) void {
            allocator.free(r.depth);
            allocator.free(r.mono);
            r.region.deinit();
        }

        /// Wait up to `receive_timeout_ms` for a frame newer than the last one taken.
        pub fn next(r: *Self) !Next(Driver) {
            const deadline_us = @as(u64, @intCast(std.Io.Timestamp.now(r.io, .awake).toMicroseconds())) +
                @as(u64, r.receive_timeout_ms) * 1000;

            while (true) {
                switch (shm.takeFrame(r.region, r.last_seq, r.depth, r.mono)) {
                    .frame => |f| {
                        r.frames += 1;
                        r.missed += f.missed;
                        r.last_seq = f.seq;
                        return .{ .frame = .{
                            .seq = @truncate(f.seq),
                            .t_us = f.t_us,
                            .width = r.region.width(),
                            .height = r.region.height(),
                            .depth_mm = r.depth,
                            .mono = r.mono,
                            .missed = f.missed,
                        } };
                    },
                    .torn => {
                        // The producer lapped the ring while this was copying. Counted and
                        // retried rather than handed over: a half-overwritten frame is two
                        // frames spliced together, which looks like geometry and is not.
                        r.torn += 1;
                        r.last_seq = r.region.published();
                    },
                    .none => {},
                }

                const now: u64 = @intCast(std.Io.Timestamp.now(r.io, .awake).toMicroseconds());
                if (now >= deadline_us) {
                    r.timeouts += 1;
                    return .timeout;
                }
                r.io.sleep(std.Io.Duration.fromMicroseconds(r.poll_interval_us), .awake) catch {};
            }
        }

        /// Read the calibration block if it changed. True when it did.
        pub fn pollCalibration(r: *Self) bool {
            var block: [Driver.calib_block_bytes]u8 = undefined;
            if (shm.takeCalibration(r.region, r.calib_seen, &block)) |seen| {
                if (Driver.parseCalib(&block, &r.intrinsics, &r.has_sensors)) {
                    r.calib_seen = seen;
                    r.calibration_settled = true;
                    return true;
                }
            }

            if (!r.calibration_settled) {
                const now: u64 = @intCast(std.Io.Timestamp.now(r.io, .real).toMicroseconds());
                if (now -| r.started_us >= @as(u64, r.calibration_timeout_ms) * 1000) {
                    r.calibration_settled = true;
                }
            }
            return false;
        }

        /// Drain inertial samples into `out`, returning how many were written.
        pub fn pollSensors(r: *Self, out: []Driver.Sensors) usize {
            if (!r.has_sensors or out.len == 0) return 0;

            var raw: [64 * shm.sensors_bytes]u8 = undefined;
            const want = @min(out.len, raw.len / shm.sensors_bytes);
            const got = shm.takeSensors(
                r.region,
                &r.sensors_cursor,
                raw[0 .. want * shm.sensors_bytes],
                &r.sensors_lost,
            );

            var n: usize = 0;
            for (0..got) |i| {
                if (Driver.parseSensors(raw[i * shm.sensors_bytes ..])) |sample| {
                    out[n] = sample;
                    n += 1;
                }
            }
            return n;
        }

        pub fn calibrationSettled(r: *const Self) bool {
            return r.calibration_settled;
        }
    };
}

