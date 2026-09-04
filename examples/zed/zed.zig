//! A driver for Stereolabs depth cameras, at the seam where the ZED SDK sits.
//!
//! Named for the family, not a model: one driver serves a ZED X and a ZED 2i, and `--model`
//! picks between them. It was called zedx.zig while it only knew one camera, which stopped
//! being true the moment it grew a spec table.
//!
//! THE FRAMING BELOW IS THIS DIRECTORY'S OWN. Neither camera has a network protocol: a
//! ZED X runs GMSL2 into a ZED Link card, a ZED 2i is USB 3.0, and both are read through
//! `sl::Camera`. There is no wire to reproduce, so this defines one that stands in for the
//! SDK boundary. Compare examples/lidar/helios32.zig, where the format IS the sensor's and
//! was corrected against real hardware; nothing here has that standing.
//!
//! ONE driver for two cameras, where the LiDAR needed two. That is not laziness, it is what
//! the seam says: an RS-16 and a Helios speak genuinely different wire formats, so they get
//! genuinely different parsers. A ZED X and a ZED 2i are the same two SDK calls returning
//! the same two planes; they differ in resolution, baseline, field of view and which extra
//! sensors exist. Those are parameters, so they live in a table rather than in a second
//! copy of the same code.
//!
//! What the driver genuinely does, and would still do against a real camera:
//!
//!   * reassemble a frame from its chunks and report the bytes that never came. A 1080p
//!     frame is 760 datagrams at the default chunk size; UDP loses them.
//!   * close a frame on a NEW sequence number, never by counting chunks, so a lost last
//!     chunk does not swallow the following frame.
//!   * take intrinsics and sensor availability from the camera when it says so, and report
//!     when it did not.
//!   * bound every wait, so a missing camera parks nothing.

const std = @import("std");
const frame = @import("frame");

/// Which camera. Adding a third is a row in `specs`, not a file.
pub const Model = enum {
    zed_x,
    zed_2i,

    pub fn parse(text: []const u8) ?Model {
        if (std.mem.eql(u8, text, "zedx") or std.mem.eql(u8, text, "zed-x")) return .zed_x;
        if (std.mem.eql(u8, text, "zed2i") or std.mem.eql(u8, text, "zed-2i")) return .zed_2i;
        return null;
    }

    pub fn slug(m: Model) []const u8 {
        return switch (m) {
            .zed_x => "zedx",
            .zed_2i => "zed2i",
        };
    }
};

/// One camera's native capability. Resolutions are per eye, as Stereolabs quotes them.
///
/// These come from published specifications, not from hardware in this room -- the same
/// standing as the LiDAR drivers' compiled-in angle tables, and the reason `from_device`
/// exists on the intrinsics.
pub const Spec = struct {
    model: Model,
    name: []const u8,
    /// The native mode this chain transmits by default. A camera has several; the fake sends
    /// at whatever it is told and the bridge decides what to publish.
    width: u16,
    height: u16,
    fps: u16,
    /// Horizontal field of view, degrees.
    fov_deg: f32,
    baseline_mm: f32,
    depth_min_mm: u16,
    depth_max_mm: u16,
    /// A ZED 2i carries an IMU, a barometer and a magnetometer. Published as its own topic
    /// when present, because 400 Hz of small samples has nothing in common with 30 Hz of
    /// megabytes -- different rate, different size, different consumers.
    has_sensors: bool,
};

pub const specs = [_]Spec{
    .{
        .model = .zed_x,
        .name = "ZED X",
        // 1200p, the ZED X's native mode, 16:10.
        .width = 1920,
        .height = 1200,
        .fps = 30,
        .fov_deg = 110.0,
        .baseline_mm = 120.0,
        .depth_min_mm = 300,
        .depth_max_mm = 20_000,
        .has_sensors = false,
    },
    .{
        .model = .zed_2i,
        .name = "ZED 2i",
        // 1080p at 30 fps. The 2i also does 2K at 15, 720p at 60 and WVGA at 100; this is
        // the mode the chain is sized around.
        .width = 1920,
        .height = 1080,
        .fps = 30,
        .fov_deg = 110.0,
        .baseline_mm = 120.0,
        // The 2i focuses closer than the X: 0.2 m against 0.3.
        .depth_min_mm = 200,
        .depth_max_mm = 20_000,
        .has_sensors = true,
    },
};

pub fn spec(m: Model) Spec {
    for (specs) |s| {
        if (s.model == m) return s;
    }
    unreachable;
}

/// The shared mapping's path. One per model, so a ZED X and a ZED 2i fake can run at once.
pub fn shmPath(m: Model, buf: []u8) ![:0]const u8 {
    return std.fmt.bufPrintZ(buf, "/tmp/qnnt-{s}.shm", .{m.slug()});
}

/// The calibration block as it sits in the shared header, behind a seqlock. No magic and no
/// length: it is at a known offset in a region whose header was already validated, which is
/// what shared memory buys over a wire format.
pub const calib_block_bytes = 40;
pub const off_c_model = 0; // u8
pub const off_c_width = 2;
pub const off_c_height = 4;
pub const off_c_fx = 8; // f32 from here
pub const off_c_fy = 12;
pub const off_c_cx = 16;
pub const off_c_cy = 20;
pub const off_c_baseline = 24;
pub const off_c_depth_min = 28; // u16 mm
pub const off_c_depth_max = 30;
pub const off_c_has_sensors = 32; // u8

/// One inertial sample as it sits in the shared ring.
pub const sensors_block_bytes = 52;
pub const off_s_t_us = 0; // u64
pub const off_s_accel = 8; // 3 x f32, m/s^2
pub const off_s_gyro = 20; // 3 x f32, deg/s
pub const off_s_mag = 32; // 3 x f32, microtesla
pub const off_s_pressure = 44; // f32, hPa
pub const off_s_temp = 48; // f32, degrees C

pub fn defaultIntrinsics(m: Model) frame.Intrinsics {
    const s = spec(m);
    return intrinsicsFor(s, s.width, s.height);
}

/// Nominal intrinsics for a given frame size.
///
/// Derived from the field of view rather than measured, so `from_device` stays false: a
/// plausible-looking cloud built on nominal intrinsics is worse than no cloud, because
/// nothing about it looks wrong.
pub fn intrinsicsFor(s: Spec, w: u16, h: u16) frame.Intrinsics {
    const half = s.fov_deg / 2.0 * std.math.pi / 180.0;
    const fx = @as(f32, @floatFromInt(w)) / 2.0 / @tan(half);
    return .{
        .model = s.name,
        .width = w,
        .height = h,
        .fx = fx,
        // Square pixels, so one focal length serves both axes whatever the aspect.
        .fy = fx,
        .cx = @as(f32, @floatFromInt(w)) / 2.0 - 0.5,
        .cy = @as(f32, @floatFromInt(h)) / 2.0 - 0.5,
        .baseline_mm = s.baseline_mm,
        .depth_min_mm = s.depth_min_mm,
        .depth_max_mm = s.depth_max_mm,
        .from_device = false,
    };
}

pub fn writeCalib(out: *[calib_block_bytes]u8, s: Spec, intr: frame.Intrinsics) void {
    @memset(out, 0);
    out[off_c_model] = @intFromEnum(s.model);
    std.mem.writeInt(u16, out[off_c_width..][0..2], intr.width, .little);
    std.mem.writeInt(u16, out[off_c_height..][0..2], intr.height, .little);
    writeF32(out, off_c_fx, intr.fx);
    writeF32(out, off_c_fy, intr.fy);
    writeF32(out, off_c_cx, intr.cx);
    writeF32(out, off_c_cy, intr.cy);
    writeF32(out, off_c_baseline, intr.baseline_mm);
    std.mem.writeInt(u16, out[off_c_depth_min..][0..2], intr.depth_min_mm, .little);
    std.mem.writeInt(u16, out[off_c_depth_max..][0..2], intr.depth_max_mm, .little);
    out[off_c_has_sensors] = if (s.has_sensors) 1 else 0;
}

/// Read a calibration block into `intr`. False leaves `intr` untouched: a half-applied
/// calibration is worse than none.
///
/// The validation stays even though the bytes now come from a sibling process rather than a
/// network. A zero focal length would send every point to infinity and a negative one would
/// mirror the scene, and neither becomes acceptable because the source is closer.
pub fn parseCalib(bytes: []const u8, intr: *frame.Intrinsics, has_sensors: ?*bool) bool {
    if (bytes.len < calib_block_bytes) return false;

    const w = std.mem.readInt(u16, bytes[off_c_width..][0..2], .little);
    const h = std.mem.readInt(u16, bytes[off_c_height..][0..2], .little);
    if (w == 0 or h == 0 or w > frame.max_width or h > frame.max_height) return false;

    const fx = readF32(bytes, off_c_fx);
    const fy = readF32(bytes, off_c_fy);
    if (!(fx > 0.0) or !(fy > 0.0)) return false;

    const dmin = std.mem.readInt(u16, bytes[off_c_depth_min..][0..2], .little);
    const dmax = std.mem.readInt(u16, bytes[off_c_depth_max..][0..2], .little);
    if (dmax <= dmin) return false;

    const id = bytes[off_c_model];
    if (id < specs.len) intr.model = specs[id].name;

    intr.width = w;
    intr.height = h;
    intr.fx = fx;
    intr.fy = fy;
    intr.cx = readF32(bytes, off_c_cx);
    intr.cy = readF32(bytes, off_c_cy);
    intr.baseline_mm = readF32(bytes, off_c_baseline);
    intr.depth_min_mm = dmin;
    intr.depth_max_mm = dmax;
    intr.from_device = true;
    if (has_sensors) |p| p.* = bytes[off_c_has_sensors] != 0;
    return true;
}

/// One sample from a ZED 2i's inertial and environmental sensors.
pub const Sensors = struct {
    t_us: u64,
    /// m/s^2, camera frame.
    accel: [3]f32,
    /// degrees/s, camera frame.
    gyro: [3]f32,
    /// microtesla.
    mag: [3]f32,
    pressure_hpa: f32,
    temperature_c: f32,
};

pub fn writeSensors(out: []u8, s: Sensors) void {
    @memset(out[0..sensors_block_bytes], 0);
    std.mem.writeInt(u64, out[off_s_t_us..][0..8], s.t_us, .little);
    for (0..3) |i| writeF32(out, off_s_accel + i * 4, s.accel[i]);
    for (0..3) |i| writeF32(out, off_s_gyro + i * 4, s.gyro[i]);
    for (0..3) |i| writeF32(out, off_s_mag + i * 4, s.mag[i]);
    writeF32(out, off_s_pressure, s.pressure_hpa);
    writeF32(out, off_s_temp, s.temperature_c);
}

pub fn parseSensors(bytes: []const u8) ?Sensors {
    if (bytes.len < sensors_block_bytes) return null;

    var s: Sensors = .{
        .t_us = std.mem.readInt(u64, bytes[off_s_t_us..][0..8], .little),
        .accel = undefined,
        .gyro = undefined,
        .mag = undefined,
        .pressure_hpa = readF32(bytes, off_s_pressure),
        .temperature_c = readF32(bytes, off_s_temp),
    };
    for (0..3) |i| s.accel[i] = readF32(bytes, off_s_accel + i * 4);
    for (0..3) |i| s.gyro[i] = readF32(bytes, off_s_gyro + i * 4);
    for (0..3) |i| s.mag[i] = readF32(bytes, off_s_mag + i * 4);
    return s;
}

fn writeF32(out: []u8, at: usize, v: f32) void {
    std.mem.writeInt(u32, out[at..][0..4], @bitCast(v), .little);
}

fn readF32(bytes: []const u8, at: usize) f32 {
    return @bitCast(std.mem.readInt(u32, bytes[at..][0..4], .little));
}

pub const Next = frame.Next(@This());

// -- tests ----------------------------------------------------------------------------
//
// The writer and the parser share their offsets, so a round trip cannot prove the format is
// a ZED's -- it is not, and no test here can make it one. What these catch is drift between
// the two halves, and the reassembly rules, which are real work either way.

const testing = std.testing;

test "calibration round-trips per model, and nonsense is refused whole" {
    for (specs) |s| {
        var intr = defaultIntrinsics(s.model);
        try testing.expect(!intr.from_device);

        var packet: [calib_block_bytes]u8 = undefined;
        var sent = defaultIntrinsics(s.model);
        sent.fx = 1113.5;
        sent.fy = 1112.25;
        writeCalib(&packet, s, sent);

        var has_sensors = false;
        try testing.expect(parseCalib(&packet, &intr, &has_sensors));
        try testing.expect(intr.from_device);
        try testing.expectEqual(s.has_sensors, has_sensors);
        try testing.expectEqualStrings(s.name, intr.model);
        try testing.expectApproxEqAbs(@as(f32, 1113.5), intr.fx, 1e-4);

        const before = intr;
        var bad = packet;
        writeF32(&bad, off_c_fx, 0.0);
        try testing.expect(!parseCalib(&bad, &intr, null));
        try testing.expectApproxEqAbs(before.fx, intr.fx, 1e-4);

        bad = packet;
        writeF32(&bad, off_c_fy, -1.0);
        try testing.expect(!parseCalib(&bad, &intr, null));

        bad = packet;
        std.mem.writeInt(u16, bad[off_c_depth_max..][0..2], 1, .little);
        try testing.expect(!parseCalib(&bad, &intr, null));
        try testing.expectEqual(before.depth_max_mm, intr.depth_max_mm);

        // Too short to be a block at all.
        try testing.expect(!parseCalib(packet[0..8], &intr, null));
    }
}

test "the sensors packet round-trips, and only a ZED 2i has one" {
    const sent: Sensors = .{
        .t_us = 1_788_000_000_000,
        .accel = .{ 0.01, -0.02, 9.81 },
        .gyro = .{ 0.5, -0.25, 0.125 },
        .mag = .{ 21.5, -3.25, 43.0 },
        .pressure_hpa = 1013.25,
        .temperature_c = 31.5,
    };

    var packet: [sensors_block_bytes]u8 = undefined;
    writeSensors(&packet, sent);

    const got = parseSensors(&packet) orelse return error.ShouldHaveParsed;
    try testing.expectEqual(sent.t_us, got.t_us);
    for (0..3) |i| {
        try testing.expectApproxEqAbs(sent.accel[i], got.accel[i], 1e-6);
        try testing.expectApproxEqAbs(sent.gyro[i], got.gyro[i], 1e-6);
        try testing.expectApproxEqAbs(sent.mag[i], got.mag[i], 1e-6);
    }
    try testing.expectApproxEqAbs(@as(f32, 1013.25), got.pressure_hpa, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 31.5), got.temperature_c, 1e-4);

    try testing.expect(parseSensors(packet[0..8]) == null);

    try testing.expect(spec(.zed_2i).has_sensors);
    try testing.expect(!spec(.zed_x).has_sensors);
}

test "native modes and their arithmetic" {
    // The numbers the chain is sized around, pinned so a resolution change has to be
    // deliberate rather than incidental.
    const x = spec(.zed_x);
    const i = spec(.zed_2i);

    try testing.expectEqual(@as(usize, 1920 * 1200), @as(usize, x.width) * x.height);
    try testing.expectEqual(@as(usize, 1920 * 1080), @as(usize, i.width) * i.height);

    // Every native mode has to fit the vocabulary's buffers.
    for (specs) |s| {
        try testing.expect(@as(usize, s.width) * s.height <= frame.max_pixels);
    }

    try testing.expectEqual(Model.zed_x, Model.parse("zedx").?);
    try testing.expectEqual(Model.zed_2i, Model.parse("zed2i").?);
    try testing.expect(Model.parse("nope") == null);
    try testing.expectEqualStrings("zed2i", Model.zed_2i.slug());
}

test "nominal intrinsics describe the field of view they claim, at any size" {
    const s = spec(.zed_2i);
    for ([_][2]u16{ .{ 1920, 1080 }, .{ 960, 540 }, .{ 480, 270 } }) |wh| {
        const intr = intrinsicsFor(s, wh[0], wh[1]);
        const half = std.math.atan(@as(f32, @floatFromInt(wh[0])) / 2.0 / intr.fx);
        try testing.expectApproxEqAbs(s.fov_deg, half * 2.0 * 180.0 / std.math.pi, 0.01);
        // The principal point stays at the centre of the grid whatever the size.
        try testing.expectApproxEqAbs(@as(f32, @floatFromInt(wh[0])) / 2.0 - 0.5, intr.cx, 1e-4);
    }
}

test "nominal intrinsics follow the geometry in use, not the spec's headline mode" {
    // What a real ZED 2i exposed: its spec row says 1920x1080, which is the SDK's
    // capability, while over UVC it offers 672x376 and nothing else. A fallback taken from
    // the table would be 2.86x too long for the frames actually arriving.
    const s = spec(.zed_2i);
    const headline = intrinsicsFor(s, s.width, s.height);
    const uvc = intrinsicsFor(s, 672, 376);

    try testing.expect(uvc.fx < headline.fx);
    // The ratio is the width ratio, because fx scales with the pixel grid at a fixed field
    // of view -- which is exactly why quoting one for the other is wrong by that factor.
    try testing.expectApproxEqAbs(
        @as(f32, 1920.0 / 672.0),
        headline.fx / uvc.fx,
        0.001,
    );

    // Both describe the same field of view, which is the invariant that makes the scaling
    // correct rather than merely proportional.
    for ([_]frame.Intrinsics{ headline, uvc }) |i| {
        const half = std.math.atan(@as(f32, @floatFromInt(i.width)) / 2.0 / i.fx);
        try testing.expectApproxEqAbs(s.fov_deg, half * 2.0 * 180.0 / std.math.pi, 0.01);
    }
}
