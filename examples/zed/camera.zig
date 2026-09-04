//! The bridge: a Stereolabs camera on one side, qnnt topics on the other.
//!
//!   ./zig-out/bin/fake-zed --model zed2i    # terminal 1: the camera, at native 1080p
//!   ./zig-out/bin/camera-sensor --model zed2i --scale 4
//!   ./zig-out/bin/camera-viewer '' camera/zed2i
//!
//!   camera-sensor [--model zedx|zed2i] [--shm path] [--scale n] [--step n]
//!
//! THIS is where the size decision lives, and that placement is the point.
//!
//! The camera transmits at its native resolution because that is what a camera does. A ZED
//! 2i's 1080p depth-plus-mono frame is 6.22 MB, so publishing it whole is 186 MB/s -- which
//! measurements in BENCHMARK.txt say is fine on loopback (13% of 1426 MB/s) and impossible
//! on a wire (1.6x past gigabit's 117.6 MB/s). `--scale` is that choice, made once, here,
//! by whoever knows where the subscribers are:
//!
//!   --scale 1    1920x1080   186 MB/s    loopback only
//!   --scale 2     960x540     46 MB/s    fine on gigabit
//!   --scale 4     480x270     11 MB/s    comfortable anywhere
//!   --scale 8     240x135      2.9 MB/s  about what the LiDAR example moves
//!
//! Downscaling in the bridge rather than in the driver keeps the driver honest about what
//! the sensor sent, and rather than in the fake because a sensor has no idea what its
//! consumer can carry.
//!
//! Four topics, four lifetimes and four sizes:
//!
//!   camera/<model>/depth        the depth map and mono image, every frame
//!   camera/<model>/cloud        the same frame deprojected to points, subsampled
//!   camera/<model>/calibration  the intrinsics, about 1 Hz
//!   camera/<model>/sensors      IMU, barometer, magnetometer -- ZED 2i only, 400 Hz

const std = @import("std");
const qnnt_mod = @import("qnnt");
const qnnt = qnnt_mod.Qnnt;
const tld = qnnt_mod.Tld;
const frame = @import("frame");
const zed = @import("zed");
const shm = @import("shm");

const allocator = std.heap.page_allocator;

const Receiver = frame.Receiver(zed);

// -- the published frames -------------------------------------------------------------

const DepthFrame = struct {
    seq: u32,
    t_us: u64,
    model: []const u8,
    width: u16,
    height: u16,
    /// How much the bridge decimated before publishing. Carried so a consumer knows it is
    /// looking at a reduced frame, and so the intrinsics on the calibration topic can be
    /// matched to it: they are scaled by the same factor.
    scale: u16,
    /// Frames the bridge skipped before this one, because the camera did not wait for it.
    /// Shared memory hands over a whole frame or nothing, so a slow consumer loses whole
    /// frames rather than receiving damaged ones -- this is that count.
    missed: u64,
    /// width*height little-endian u16 millimetres.
    depth: tld.Bytes,
    /// width*height luminance bytes.
    mono: tld.Bytes,
};

const CloudFrame = struct {
    seq: u32,
    t_us: u64,
    model: []const u8,
    points: u32,
    /// Every point taken from a pixel `step` apart in the ALREADY decimated frame, so the
    /// effective spacing in the original is scale * step.
    step: u16,
    scale: u16,
    /// `points` x (f32 x, f32 y, f32 z little-endian, u8 intensity) = 13 bytes each.
    xyzi: tld.Bytes,
};

const CalibrationFrame = struct {
    model: []const u8,
    /// The geometry these intrinsics describe, which is the PUBLISHED geometry rather than
    /// the sensor's native one. Quoting native focal lengths for a decimated frame would
    /// put every point out by exactly the scale factor.
    width: u16,
    height: u16,
    scale: u16,
    fx: f32,
    fy: f32,
    cx: f32,
    cy: f32,
    baseline_mm: f32,
    depth_min_mm: u16,
    depth_max_mm: u16,
    from_device: bool,
    has_sensors: bool,
};

const SensorsFrame = struct {
    t_us: u64,
    model: []const u8,
    /// m/s^2, camera frame.
    accel: [3]f32,
    /// degrees/s, camera frame.
    gyro: [3]f32,
    /// microtesla.
    mag: [3]f32,
    pressure_hpa: f32,
    temperature_c: f32,
};

var depth_buf: std.ArrayList(u8) = .empty;
var cloud_buf: std.ArrayList(u8) = .empty;
var calib_buf: std.ArrayList(u8) = .empty;
var sensors_buf: std.ArrayList(u8) = .empty;

/// The decimated planes, and their little-endian wire copies.
var small_depth: []u16 = &.{};
var small_mono: []u8 = &.{};
var depth_wire: []u8 = &.{};
var mono_wire: []u8 = &.{};
var point_wire: []u8 = &.{};
var points: []frame.Point = &.{};

const point_stride = 13;

var topic_depth: []const u8 = "";
var topic_cloud: []const u8 = "";
var topic_calib: []const u8 = "";
var topic_sensors: []const u8 = "";

/// Take every `scale`-th pixel in each axis. Returns the decimated geometry.
///
/// Sampled, not averaged, and that is deliberate: averaging depth across an edge invents a
/// surface at a distance nothing was measured at, halfway between the foreground and the
/// background. A stereo frame is full of those edges. Sampling can miss a thin object;
/// averaging reports objects that are not there, which is worse.
///
/// It also makes the intrinsics exact. Output pixel u maps to input pixel u*scale, so
/// fx' = fx/scale and cx' = cx/scale with no half-pixel correction -- the correction that
/// area-averaging would need, and that is easy to forget.
fn decimate(f: frame.StereoFrame, scale: u16) struct { w: u16, h: u16 } {
    if (scale <= 1) return .{ .w = f.width, .h = f.height };

    const ow: u16 = @intCast(@max(1, f.width / scale));
    const oh: u16 = @intCast(@max(1, f.height / scale));

    for (0..oh) |v| {
        const src_row = v * scale * @as(usize, f.width);
        const dst_row = v * @as(usize, ow);
        for (0..ow) |u| {
            small_depth[dst_row + u] = f.depth_mm[src_row + u * scale];
            small_mono[dst_row + u] = f.mono[src_row + u * scale];
        }
    }
    return .{ .w = ow, .h = oh };
}

fn scaledIntrinsics(intr: frame.Intrinsics, scale: u16, w: u16, h: u16) frame.Intrinsics {
    if (scale <= 1) return intr;
    const k = @as(f32, @floatFromInt(scale));
    var out = intr;
    out.width = w;
    out.height = h;
    out.fx = intr.fx / k;
    out.fy = intr.fy / k;
    out.cx = intr.cx / k;
    out.cy = intr.cy / k;
    return out;
}

fn publishDepth(
    seq: u32,
    t_us: u64,
    model: []const u8,
    w: u16,
    h: u16,
    scale: u16,
    missed: u64,
    depth: []const u16,
    mono: []const u8,
) !void {
    const n = @as(usize, w) * h;
    for (0..n) |i| {
        std.mem.writeInt(u16, depth_wire[i * 2 ..][0..2], depth[i], .little);
    }
    @memcpy(mono_wire[0..n], mono[0..n]);

    const out: DepthFrame = .{
        .seq = seq,
        .t_us = t_us,
        .model = model,
        .width = w,
        .height = h,
        .scale = scale,
        .missed = missed,
        .depth = .{ .data = depth_wire[0 .. n * 2] },
        .mono = .{ .data = mono_wire[0..n] },
    };

    try tld.packTo(allocator, &depth_buf, out);
    try qnnt.publish(topic_depth, depth_buf.items);
}

fn publishCloud(
    seq: u32,
    t_us: u64,
    intr: *const frame.Intrinsics,
    w: u16,
    h: u16,
    scale: u16,
    step: u16,
    depth: []const u16,
    mono: []const u8,
) !usize {
    const view: frame.StereoFrame = .{
        .seq = seq,
        .t_us = t_us,
        .width = w,
        .height = h,
        .depth_mm = depth[0 .. @as(usize, w) * h],
        .mono = mono[0 .. @as(usize, w) * h],
        .missed = 0,
    };

    const count = frame.deprojectInto(intr, view, step, points);

    var at: usize = 0;
    for (points[0..count]) |p| {
        std.mem.writeInt(u32, point_wire[at..][0..4], @bitCast(p.x), .little);
        std.mem.writeInt(u32, point_wire[at + 4 ..][0..4], @bitCast(p.y), .little);
        std.mem.writeInt(u32, point_wire[at + 8 ..][0..4], @bitCast(p.z), .little);
        point_wire[at + 12] = p.intensity;
        at += point_stride;
    }

    const out: CloudFrame = .{
        .seq = seq,
        .t_us = t_us,
        .model = intr.model,
        .points = @intCast(count),
        .step = step,
        .scale = scale,
        .xyzi = .{ .data = point_wire[0..at] },
    };

    try tld.packTo(allocator, &cloud_buf, out);
    try qnnt.publish(topic_cloud, cloud_buf.items);
    return count;
}

fn publishCalibration(intr: frame.Intrinsics, scale: u16, has_sensors: bool) !void {
    const out: CalibrationFrame = .{
        .model = intr.model,
        .width = intr.width,
        .height = intr.height,
        .scale = scale,
        .fx = intr.fx,
        .fy = intr.fy,
        .cx = intr.cx,
        .cy = intr.cy,
        .baseline_mm = intr.baseline_mm,
        .depth_min_mm = intr.depth_min_mm,
        .depth_max_mm = intr.depth_max_mm,
        .from_device = intr.from_device,
        .has_sensors = has_sensors,
    };
    try tld.packTo(allocator, &calib_buf, out);
    try qnnt.publish(topic_calib, calib_buf.items);
}

fn publishSensors(s: zed.Sensors, model: []const u8) !void {
    const out: SensorsFrame = .{
        .t_us = s.t_us,
        .model = model,
        .accel = s.accel,
        .gyro = s.gyro,
        .mag = s.mag,
        .pressure_hpa = s.pressure_hpa,
        .temperature_c = s.temperature_c,
    };
    try tld.packTo(allocator, &sensors_buf, out);
    try qnnt.publish(topic_sensors, sensors_buf.items);
}

fn usage() void {
    std.debug.print(
        \\usage: camera-sensor [options]
        \\
        \\  --model <name>   zedx or zed2i (default zedx)
        \\  --shm <path>     the camera's shared mapping (default /tmp/qnnt-<model>.shm)
        \\  --scale <n>      publish every n-th pixel in each axis (default 4)
        \\  --step <n>       publish every n-th pixel of THAT in the cloud (default 2)
        \\
        \\--scale is the bandwidth decision, and it belongs here: the camera hands over its
        \\native resolution and this decides how much of it goes on qnnt. 1080p whole is
        \\186 MB/s, which loopback carries and gigabit does not.
        \\
        \\The camera hands frames over through shared memory, as the ZED SDK does. It never
        \\waits for this process, so falling behind loses whole frames -- reported as
        \\'missed' -- rather than producing damaged ones.
        \\
    , .{});
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();

    var model: zed.Model = .zed_x;
    var shm_path_arg: ?[]const u8 = null;
    // A quarter in each axis, so a 1080p camera publishes 480x270 at 11 MB/s -- carryable
    // on any network. The default is a bandwidth decision and it is the caller's to change.
    var scale: u16 = 4;
    var step: u16 = 2;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--model")) {
            const text = args.next() orelse return usage();
            model = zed.Model.parse(text) orelse {
                std.debug.print("camera-sensor: --model must be zedx or zed2i\n", .{});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--shm")) {
            shm_path_arg = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--scale")) {
            scale = std.fmt.parseInt(u16, args.next() orelse return usage(), 10) catch return usage();
            if (scale == 0) {
                std.debug.print("camera-sensor: --scale must be at least 1\n", .{});
                return;
            }
        } else if (std.mem.eql(u8, arg, "--step")) {
            step = std.fmt.parseInt(u16, args.next() orelse return usage(), 10) catch return usage();
            if (step == 0) {
                std.debug.print("camera-sensor: --step must be at least 1\n", .{});
                return;
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return usage();
        } else {
            std.debug.print("camera-sensor: unexpected argument '{s}'\n\n", .{arg});
            return usage();
        }
    }

    const s = zed.spec(model);
    const slug = model.slug();
    topic_depth = try std.fmt.allocPrint(allocator, "camera/{s}/depth", .{slug});
    topic_cloud = try std.fmt.allocPrint(allocator, "camera/{s}/cloud", .{slug});
    topic_calib = try std.fmt.allocPrint(allocator, "camera/{s}/calibration", .{slug});
    topic_sensors = try std.fmt.allocPrint(allocator, "camera/{s}/sensors", .{slug});

    // Every QNNT_* variable, handled by the library so all four languages agree.
    qnnt.configureFromEnvironment();

    if (!qnnt.run()) {
        std.debug.print("camera-sensor: failed to start\n", .{});
        return;
    }
    defer qnnt.deinit();

    qnnt.installSignalHandlers();

    var path_buf: [256]u8 = undefined;
    const path: [:0]const u8 = if (shm_path_arg) |given|
        try std.fmt.bufPrintZ(&path_buf, "{s}", .{given})
    else
        try zed.shmPath(model, &path_buf);

    // Wait for the camera rather than failing outright: a bridge started first should come
    // up when the camera does, which is what the LiDAR bridge does for a sensor that
    // appears late.
    var receiver = while (!qnnt.stopRequested()) {
        if (Receiver.init(qnnt_mod.io, allocator, model, path)) |r| {
            break r;
        } else |err| switch (err) {
            error.OpenFailed, error.BadMagic, error.TooSmall => {
                std.debug.print("camera-sensor: waiting for {s} ({t})\n", .{ path, err });
                qnnt.sleepMs(1000);
            },
            else => {
                std.debug.print("camera-sensor: cannot open {s}: {t}\n", .{ path, err });
                return;
            },
        }
    } else return;
    defer receiver.deinit(allocator);

    // Everything below asks the REGION, not the spec table. The table describes what the
    // model can do; the region says what this camera is actually sending, and they differ --
    // a real ZED 2i over V4L2 offers 672x376 at 15 where the table says 1920x1080 at 30.
    // Three separate numbers here were taken from the table and all three were wrong
    // against real hardware: the frame-size estimate, the sensors decision, and the
    // bandwidth report.
    const cam_w = receiver.region.width();
    const cam_h = receiver.region.height();
    const cam_has_sensors = receiver.region.hasSensors();
    // A producer that could not determine its own rate writes 0. Falling back to the table
    // is better than reporting 0 MB/s, but it has to say which number it used.
    const region_fps = receiver.region.fps();
    const cam_fps: u16 = if (region_fps != 0) region_fps else s.fps;

    // The published frame has to fit this node's own limit, and at scale 1 a 1080p frame is
    // 6.2 MB. Checked before a single frame is published, because discovering it per frame
    // means one refusal per frame with nothing getting through in between.
    const published_pixels = @as(usize, cam_w / scale) * (cam_h / scale);
    const est_frame = published_pixels * 3 + 256; // planes plus TLD keys and headers
    if (est_frame > qnnt.maxFrameBytes()) {
        std.debug.print(
            "camera-sensor: at scale {d} a published frame is about {d} bytes, past this " ++
                "node's {d} byte limit. Raise QNNT_MAX_FRAME_BYTES on every node on the " ++
                "topic, or use a larger --scale.\n",
            .{ scale, est_frame, qnnt.maxFrameBytes() },
        );
        return;
    }

    // Registered after the camera is known, and the sensors topic only if the camera says it
    // has any. Registering it from the spec table put a topic on the bus that nothing would
    // ever publish to -- a subscriber would attach and wait for ever, which is worse than
    // the topic not existing.
    if (!qnnt.runPublisher(topic_depth, null, null, null) or
        !qnnt.runPublisher(topic_cloud, null, null, null) or
        !qnnt.runPublisher(topic_calib, null, null, null) or
        (cam_has_sensors and !qnnt.runPublisher(topic_sensors, null, null, null)))
    {
        std.debug.print("camera-sensor: could not register the topics\n", .{});
        return;
    }


    const native = @as(usize, cam_w) * cam_h;
    small_depth = try allocator.alloc(u16, native);
    defer allocator.free(small_depth);
    small_mono = try allocator.alloc(u8, native);
    defer allocator.free(small_mono);
    depth_wire = try allocator.alloc(u8, native * 2);
    defer allocator.free(depth_wire);
    mono_wire = try allocator.alloc(u8, native);
    defer allocator.free(mono_wire);
    points = try allocator.alloc(frame.Point, native);
    defer allocator.free(points);
    point_wire = try allocator.alloc(u8, native * point_stride);
    defer allocator.free(point_wire);

    const ow = cam_w / scale;
    const oh = cam_h / scale;
    // The camera's rate, not the table's. Against a real ZED 2i at 15 fps this reported
    // 5.7 MB/s where the truth was 2.84, because it multiplied by the table's 30 -- and the
    // bandwidth figure is the whole basis on which --scale gets chosen.
    const wire_rate = @as(f64, @floatFromInt(@as(usize, ow) * oh * 3)) *
        @as(f64, @floatFromInt(cam_fps)) / 1.0e6;

    std.debug.print(
        "camera-sensor: {s} from {s}{s}\n" ++
            "  native {d}x{d}, publishing {d}x{d} at scale {d}: about {d:.1} MB/s\n" ++
            "  {s}\n" ++
            "  topics {s}, {s}, {s}{s}\n",
        .{
            s.name,
            path,
            if (cam_has_sensors) ", with sensors" else "",
            cam_w,
            cam_h,
            ow,
            oh,
            scale,
            wire_rate,
            // Said out loud, because it is the decision --scale exists to make. The gigabit
            // figure is measured, not assumed: see BENCHMARK.txt.
            if (wire_rate > 117.6)
                "past gigabit's measured 117.6 MB/s -- loopback only"
            else if (wire_rate > 60.0)
                "over half of gigabit; fine on loopback, tight on a wire"
            else
                "carryable on gigabit",
            topic_depth,
            topic_cloud,
            topic_calib,
            if (cam_has_sensors) " and /sensors" else "",
        },
    );
    std.debug.print("  {d} frame slots of {d:.1} MB each in the mapping\n", .{
        receiver.region.slots(),
        @as(f64, @floatFromInt(receiver.region.payloadLen())) / 1.0e6,
    });

    var announced = false;
    var announced_intr: ?frame.Intrinsics = null;
    var frames_out: u64 = 0;
    var published_points: u64 = 0;
    var sensor_samples: u64 = 0;
    var idle: u64 = 0;
    var last_report_us: u64 = @intCast(qnnt.nowMicros());
    var last_frames: u64 = 0;
    // Republished on a timer, not only when it changes.
    //
    // With shared memory the calibration is a VALUE the camera writes once, not an event it
    // repeats -- which is what a real SDK offers too: you read the calibration whenever you
    // like. So keeping the topic alive for a consumer that attaches later is this bridge's
    // job, and only its job. The UDP version got this for free because the fake resent the
    // packet every second, and losing that accidental property silently broke the viewer:
    // it subscribed, waited for a depth range it needed to scale anything, and never got
    // one.
    var last_calib_us: u64 = 0;

    // The frame socket is the hot path and the other two are not: 760 datagrams arrive per
    // frame and at most one calibration packet per second. Polling the side channels on
    // every frame datagram cost three extra syscalls each -- with the sensor drain, up to
    // sixty-five -- and the receive buffer overflowed while they were being made. Measured
    // before this gate: every frame partial, 83% of every frame lost.
    //
    // So they are polled between frames instead, where there is slack by construction.
    var side_due = true;

    while (!qnnt.stopRequested()) {
        // The intrinsics are published at the geometry actually being published, not the
        // camera's native one: a consumer deprojecting a 480x270 frame with 1920x1080 focal
        // lengths would be out by exactly the scale factor.
        const now_for_calib: u64 = @intCast(qnnt.nowMicros());
        const calib_due = now_for_calib -| last_calib_us >= 1_000_000;

        if (side_due and (receiver.pollCalibration() or (calib_due and announced))) {
            last_calib_us = now_for_calib;
            const pub_intr = scaledIntrinsics(receiver.intrinsics, scale, ow, oh);
            try publishCalibration(pub_intr, scale, receiver.has_sensors);
            if (changedFrom(announced_intr, pub_intr)) {
                announced_intr = pub_intr;
                std.debug.print(
                    "camera-sensor: calibration from the camera: native {d}x{d} fx {d:.2}, " ++
                        "published {d}x{d} fx {d:.2}, baseline {d:.1} mm, sensors {s}\n",
                    .{
                        receiver.intrinsics.width,
                        receiver.intrinsics.height,
                        receiver.intrinsics.fx,
                        pub_intr.width,
                        pub_intr.height,
                        pub_intr.fx,
                        pub_intr.baseline_mm,
                        if (receiver.has_sensors) "yes" else "no",
                    },
                );
            }
            announced = true;
        } else if (side_due and !announced and receiver.calibrationSettled()) {
            last_calib_us = now_for_calib;
            const pub_intr = scaledIntrinsics(receiver.intrinsics, scale, ow, oh);
            announced_intr = pub_intr;
            std.debug.print(
                "camera-sensor: no calibration within the wait; using the driver's nominal " ++
                    "defaults (fx {d:.2} at {d}x{d}) -- these are not this unit's\n",
                .{ pub_intr.fx, pub_intr.width, pub_intr.height },
            );
            try publishCalibration(pub_intr, scale, receiver.has_sensors);
            announced = true;
        }

        if (side_due) {
            var samples: [32]zed.Sensors = undefined;
            const got = receiver.pollSensors(&samples);
            for (samples[0..got]) |sample| {
                try publishSensors(sample, receiver.intrinsics.model);
                sensor_samples += 1;
            }
        }
        side_due = false;

        switch (receiver.next() catch |err| {
            std.debug.print("camera-sensor: receive failed: {t}\n", .{err});
            break;
        }) {
            .frame => |f| {
                frames_out += 1;

                const geo = decimate(f, scale);
                const depth: []const u16 = if (scale <= 1) f.depth_mm else small_depth;
                const mono: []const u8 = if (scale <= 1) f.mono else small_mono;

                try publishDepth(
                    f.seq,
                    f.t_us,
                    receiver.intrinsics.model,
                    geo.w,
                    geo.h,
                    scale,
                    f.missed,
                    depth,
                    mono,
                );

                const pub_intr = scaledIntrinsics(receiver.intrinsics, scale, geo.w, geo.h);
                published_points += try publishCloud(
                    f.seq,
                    f.t_us,
                    &pub_intr,
                    geo.w,
                    geo.h,
                    scale,
                    step,
                    depth,
                    mono,
                );
                // A frame boundary is the natural place: the burst for the next frame has
                // not started, so a few extra syscalls cost nothing.
                side_due = true;
            },
            // No new frame within the window, which is exactly when there is room to
            // service the calibration and sensors in the mapping.
            .timeout => {
                idle += 1;
                side_due = true;
            },
        }

        const now_us: u64 = @intCast(qnnt.nowMicros());
        if (now_us -| last_report_us >= 1_000_000) {
            const elapsed = @as(f64, @floatFromInt(now_us -| last_report_us)) / 1.0e6;
            std.debug.print(
                // `missed` is the number that matters: the camera never waits, so falling
                // behind shows up there and nowhere else. `torn` should stay zero -- if it
                // does not, this process is so far behind that the ring is too small.
                "camera-sensor: {d:.1} frames/s, {d} published, {d} missed, {d} torn, " ++
                    "{d} idle, {d} B depth + {d} B cloud{s}\n",
                .{
                    @as(f64, @floatFromInt(frames_out - last_frames)) / elapsed,
                    frames_out,
                    receiver.missed,
                    receiver.torn,
                    idle,
                    depth_buf.items.len,
                    cloud_buf.items.len,
                    if (sensor_samples > 0) " (+sensors)" else "",
                },
            );
            if (sensor_samples > 0) {
                std.debug.print("  {d} sensor samples published\n", .{sensor_samples});
                sensor_samples = 0;
            }
            last_frames = frames_out;
            last_report_us = now_us;
        }
    }

    std.debug.print("camera-sensor: stopping ({d} frames, {d} missed, {d} points)\n", .{
        frames_out,
        receiver.missed,
        published_points,
    });
}

/// Has anything a consumer would act on changed? Compared field by field rather than with a
/// byte comparison, because the struct holds a slice for the model name and comparing its
/// pointer would call two identical names different.
fn changedFrom(old: ?frame.Intrinsics, new: frame.Intrinsics) bool {
    const prev = old orelse return true;
    return prev.width != new.width or
        prev.height != new.height or
        prev.fx != new.fx or
        prev.fy != new.fy or
        prev.cx != new.cx or
        prev.cy != new.cy or
        prev.baseline_mm != new.baseline_mm or
        prev.depth_min_mm != new.depth_min_mm or
        prev.depth_max_mm != new.depth_max_mm or
        prev.from_device != new.from_device or
        !std.mem.eql(u8, prev.model, new.model);
}
