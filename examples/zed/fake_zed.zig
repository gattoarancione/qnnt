//! A fake Stereolabs camera, transmitting the framing zed.zig parses.
//!
//!   ./zig-out/bin/fake-zed [--model zedx|zed2i] [--shm path] [--fps n] [--slots n]
//!
//! It stands in for the ZED SDK, not for a wire: neither camera has a network protocol, so
//! unlike fake-helios32 -- which reproduces a format that exists and was checked against
//! hardware -- this one speaks a framing invented in this directory. See zed.zig.
//!
//! It transmits at the camera's NATIVE resolution: 1920x1200 for a ZED X, 1920x1080 for a
//! ZED 2i. That is the point of it. A sensor does not downscale to suit its consumer, and
//! deciding how much of a frame to put on qnnt is the bridge's job -- which is what makes
//! that decision visible and adjustable instead of baked in here.
//!
//! A ZED 2i also carries an IMU, a barometer and a magnetometer, which go into a ring in
//! the same mapping at 400 Hz.
//!
//! It hands frames over through SHARED MEMORY, which is what the SDK does: a pointer into a
//! buffer, not a transport. It never blocks and never waits for the driver -- a slow driver
//! misses frames, exactly as a slow application misses `grab()` calls. There is no host
//! argument, because a camera on GMSL2 or USB is not on the network.
//!
//! Build with -Doptimize=ReleaseFast if you want native frame rate. A 1080p frame is 2.07
//! million ray casts and a Debug build will not keep up; the rate it reports is the one it
//! achieved, not the one it was asked for.

const std = @import("std");
const frame = @import("frame");
const zed = @import("zed");
const world = @import("world");
const shm = @import("shm");

/// The mapping to remove on the way out, for the signal handler.
///
/// A hard kill leaves the file behind, which is the price of a handoff that lives in the
/// filesystem namespace -- and the same criticism that ruled out a named pipe. It is made
/// harmless rather than impossible: `shm.create` truncates and re-stamps the header, so a
/// leftover from a previous run is never mistaken for a live camera. This handler covers the
/// ordinary exits.
var cleanup_path: ?[:0]const u8 = null;

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    if (cleanup_path) |p| _ = std.c.unlink(p.ptr);
    std.c.exit(0);
}

fn installCleanup(path: [:0]const u8) void {
    cleanup_path = path;
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
}

/// The ZED 2i's IMU runs at up to 400 Hz. The magnetometer and barometer are slower on real
/// hardware -- roughly 50 and 25 Hz -- and this sends all of them together at the IMU rate,
/// which overstates the two slow ones. Worth knowing before treating the barometer field as
/// a fresh reading rather than the most recent one.
const sensors_hz: u64 = 400;

fn usage(what: []const u8) void {
    std.debug.print(
        \\fake-zed: {s}
        \\
        \\usage: fake-zed [options]
        \\  --model <name>     zedx (1920x1200) or zed2i (1920x1080, with sensors)
        \\  --shm <path>       the shared mapping (default /tmp/qnnt-<model>.shm)
        \\  --slots <n>        frame slots in the ring (default 4)
        \\  --fps <n>          override the native frame rate
        \\
        \\Frames are handed over through shared memory, as the ZED SDK hands them over: this
        \\never blocks and never waits for a reader. A slow driver misses frames rather than
        \\slowing the camera. Local only -- a camera on GMSL2 or USB is not on a network.
        \\
    , .{what});
}

/// A plausible inertial sample: gravity plus a slow sway, so a consumer has something that
/// moves without this pretending to be a real motion trace.
fn sensorsAt(t_us: u64) zed.Sensors {
    const t = @as(f32, @floatFromInt(t_us % 10_000_000)) / 1.0e6;
    const sway = @sin(t * 0.6);
    return .{
        .t_us = t_us,
        // The camera sits roughly level, so gravity is almost all on one axis.
        .accel = .{ 0.15 * sway, -0.08 * sway, 9.807 + 0.03 * sway },
        .gyro = .{ 0.4 * sway, -0.9 * sway, 0.2 * @cos(t * 0.6) },
        // Earth's field is tens of microtesla; the exact vector depends on where you are.
        .mag = .{ 21.0 + sway, -3.5, 43.0 - 0.5 * sway },
        .pressure_hpa = 1013.25 - 0.2 * sway,
        .temperature_c = 31.0 + 0.4 * sway,
    };
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();

    var model: zed.Model = .zed_x;
    var shm_path_arg: ?[]const u8 = null;
    var slots: u32 = shm.default_slots;
    var fps_override: ?u16 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--model")) {
            const text = args.next() orelse return usage("--model needs a name");
            model = zed.Model.parse(text) orelse return usage("--model must be zedx or zed2i");
        } else if (std.mem.eql(u8, arg, "--shm")) {
            shm_path_arg = args.next() orelse return usage("--shm needs a path");
        } else if (std.mem.eql(u8, arg, "--slots")) {
            const text = args.next() orelse return usage("--slots needs a number");
            slots = std.fmt.parseInt(u32, text, 10) catch return usage("--slots is not a number");
            if (slots < 2 or slots > 64) return usage("--slots must be between 2 and 64");
        } else if (std.mem.eql(u8, arg, "--fps")) {
            const text = args.next() orelse return usage("--fps needs a number");
            fps_override = std.fmt.parseInt(u16, text, 10) catch return usage("--fps is not a number");
            if (fps_override.? == 0) return usage("--fps must be at least 1");
        } else {
            return usage("unrecognised argument (see below)");
        }
    }

    const s = zed.spec(model);
    const fps = fps_override orelse s.fps;

    var io_impl: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    var path_buf: [256]u8 = undefined;
    const path: [:0]const u8 = if (shm_path_arg) |given|
        try std.fmt.bufPrintZ(&path_buf, "{s}", .{given})
    else
        try zed.shmPath(model, &path_buf);

    var region = shm.create(
        path,
        s.width,
        s.height,
        fps,
        @intFromEnum(model),
        s.has_sensors,
        slots,
    ) catch |err| {
        std.debug.print("fake-zed: cannot create {s}: {t}\n", .{ path, err });
        return;
    };
    defer region.deinit();
    installCleanup(path);

    const allocator = std.heap.page_allocator;
    const n = @as(usize, s.width) * s.height;
    const depth = try allocator.alloc(u16, n);
    defer allocator.free(depth);
    const mono = try allocator.alloc(u8, n);
    defer allocator.free(mono);

    // The intrinsics this unit reports, deliberately off the driver's nominal ones: a real
    // calibration never is the nominal one, so a consumer that silently used the fallback
    // should be visibly wrong rather than accidentally right.
    var intr = zed.defaultIntrinsics(model);
    intr.fx *= 1.014;
    intr.fy *= 1.011;
    intr.cx += 1.7;
    intr.cy -= 2.3;
    intr.baseline_mm = s.baseline_mm - 0.4;
    intr.from_device = true;

    var calib: [zed.calib_block_bytes]u8 = undefined;
    zed.writeCalib(&calib, s, intr);
    shm.writeCalibration(region, &calib);

    std.debug.print(
        "fake-zed: {s} -> {s}\n" ++
            "  {d}x{d} native at {d} Hz, {d} slots of {d:.1} MB, {d:.1} MB mapped\n" ++
            "  depth {d}..{d} mm, fx {d:.1} baseline {d:.1} mm{s}\n" ++
            "  shared memory: never blocks, so a slow driver misses frames rather than\n" ++
            "  slowing this down. Watch the driver's 'missed' count, not this one.\n",
        .{
            s.name,
            path,
            s.width,
            s.height,
            fps,
            slots,
            @as(f64, @floatFromInt(shm.payloadBytes(s.width, s.height))) / 1.0e6,
            @as(f64, @floatFromInt(shm.totalBytes(s.width, s.height, slots))) / 1.0e6,
            intr.depth_min_mm,
            intr.depth_max_mm,
            intr.fx,
            intr.baseline_mm,
            if (s.has_sensors) ", plus a 400 Hz sensor ring" else "",
        },
    );

    const period_us: u64 = 1_000_000 / @as(u64, fps);
    var seq: u64 = 0;
    var frames_sent: u64 = 0;
    var last_frames: u64 = 0;
    var sensors_sent: u64 = 0;
    var render_us_total: u64 = 0;

    var next_us: u64 = @intCast(std.Io.Timestamp.now(io, .awake).toMicroseconds());
    var last_report_us: u64 = @intCast(std.Io.Timestamp.now(io, .real).toMicroseconds());
    var sensor_due_us: u64 = last_report_us;

    while (true) {
        const before_us: u64 = @intCast(std.Io.Timestamp.now(io, .awake).toMicroseconds());
        if (before_us < next_us) {
            io.sleep(std.Io.Duration.fromMicroseconds(@intCast(next_us - before_us)), .awake) catch {};
        } else {
            // Already late. Re-anchor rather than accumulating a debt that would make the
            // loop sprint for the rest of the run trying to catch up.
            next_us = before_us;
        }
        next_us += period_us;

        const stamp: u64 = @intCast(std.Io.Timestamp.now(io, .real).toMicroseconds());
        const phase = @as(f32, @floatFromInt(seq % 90)) / 90.0;

        const render_start: u64 = @intCast(std.Io.Timestamp.now(io, .awake).toMicroseconds());
        world.render(&intr, @truncate(seq), phase, depth, mono);
        render_us_total += @as(u64, @intCast(std.Io.Timestamp.now(io, .awake).toMicroseconds())) -| render_start;

        seq += 1;
        // One memcpy into the slot, then one release store. No chunking, no framing, and
        // nothing that can be half-delivered.
        shm.writeFrame(region, seq, stamp, depth, mono);
        frames_sent += 1;

        if (s.has_sensors) {
            var sample: [zed.sensors_block_bytes]u8 = undefined;
            while (sensor_due_us <= stamp) : (sensor_due_us += 1_000_000 / sensors_hz) {
                zed.writeSensors(&sample, sensorsAt(sensor_due_us));
                shm.writeSensors(region, &sample);
                sensors_sent += 1;
            }
        }

        if (stamp -| last_report_us >= 1_000_000) {
            const elapsed = @as(f64, @floatFromInt(stamp -| last_report_us)) / 1.0e6;
            const window = @max(1, frames_sent - last_frames);
            const achieved = @as(f64, @floatFromInt(window)) / elapsed;

            var holes: usize = 0;
            for (depth) |d| {
                if (d == 0) holes += 1;
            }

            // The rate ACHIEVED, not the one requested. A fake quietly running at a third of
            // what it advertises would make every measurement downstream of it a lie -- and
            // with shared memory this figure is entirely the fake's own: no reader can hold
            // it back.
            std.debug.print(
                "fake-zed: {d:.1} frames/s of {d} target, {d:.1} ms/frame rendering, " ++
                    "{d:.1}% without depth{s}\n",
                .{
                    achieved,
                    fps,
                    @as(f64, @floatFromInt(render_us_total)) / @as(f64, @floatFromInt(window)) / 1000.0,
                    @as(f64, @floatFromInt(holes)) * 100.0 / @as(f64, @floatFromInt(n)),
                    if (achieved < @as(f64, @floatFromInt(fps)) * 0.9)
                        " -- BEHIND, build with -Doptimize=ReleaseFast"
                    else
                        "",
                },
            );
            if (s.has_sensors) {
                std.debug.print("  {d} sensor samples written\n", .{sensors_sent});
                sensors_sent = 0;
            }

            last_frames = frames_sent;
            last_report_us = stamp;
            render_us_total = 0;
        }
    }
}
