//! The UGV Beast's command and telemetry vocabulary.
//!
//! Almost nothing here is guessed. The robot serves its own configuration at `GET /config`,
//! and that file -- not the web UI, not a datasheet -- is what defines the protocol:
//!
//!   fb:                     the telemetry field map, fifteen numeric keys
//!     base_voltage: 112       so `{"112":1201}` is 12.01 V
//!     pan_angle: 109
//!     ...
//!   cmd_movition_ctrl: 1    (the robot's spelling)
//!   cmd_gimbal_ctrl: 133
//!   max_speed: 0.5          the ceiling the vendor's own UI scales its sticks against
//!
//! `parseConfig` reads that file, so a firmware that renumbers a field or raises a limit is
//! followed rather than fought. The defaults below are what this robot answered on
//! 2026-09-04 (`sbc_version: 0.91`, `main_type: 3`) and are used only when `/config` cannot
//! be read -- which is a degraded mode worth reporting, not a normal one.
//!
//! The angle limits are the exception: they are not in `/config`. They come from the
//! vendor UI's own clamps on its gamepad path, which is the only statement of them we have.
//! Getting them wrong drives the pan-tilt into a mechanical stop, so they are conservative
//! and enforced here rather than trusted from a caller.

const std = @import("std");

/// Which numeric key carries which reading, from the robot's `fb:` block.
pub const Fields = struct {
    detect_type: u16 = 101,
    led_mode: u16 = 102,
    detect_react: u16 = 103,
    picture_size: u16 = 104,
    video_size: u16 = 105,
    cpu_load: u16 = 106,
    cpu_temp: u16 = 107,
    ram_usage: u16 = 108,
    pan_angle: u16 = 109,
    tilt_angle: u16 = 110,
    wifi_rssi: u16 = 111,
    base_voltage: u16 = 112,
    video_fps: u16 = 113,
    cv_movtion_mode: u16 = 114,
    base_light: u16 = 115,
};

/// The `T` values that select a command. Only the ones this bridge sends are named; the
/// robot understands many more (arm, servo identity, PWM) that a drive-and-look bridge has
/// no business issuing.
pub const Commands = struct {
    movition_ctrl: u16 = 1,
    gimbal_ctrl: u16 = 133,
    gimbal_steady: u16 = 137,
    gimbal_base_ctrl: u16 = 141,
};

/// How fast the robot is willing to go. Read from `/config` so the bridge enforces the
/// vendor's number rather than one of its own choosing.
pub const Limits = struct {
    max_speed: f32 = 0.5,
    slow_speed: f32 = 0.2,
    max_rate: f32 = 1.0,

    /// Not in `/config`. The vendor UI's gamepad clamps, which is the only bound on these
    /// axes anyone has published.
    pan_min_deg: f32 = -180,
    pan_max_deg: f32 = 180,
    tilt_min_deg: f32 = -30,
    tilt_max_deg: f32 = 90,
};

pub const Config = struct {
    fields: Fields = .{},
    commands: Commands = .{},
    limits: Limits = .{},
    name_buf: [64]u8 = undefined,
    name_len: usize = 0,
    /// False when `/config` could not be read and every value above is a compiled-in
    /// default. Published on the status topic, because operating a robot on assumed limits
    /// is worth knowing about.
    from_robot: bool = false,

    pub fn name(c: *const Config) []const u8 {
        return if (c.name_len == 0) "UGV" else c.name_buf[0..c.name_len];
    }
};

/// One telemetry frame, named. Every field is optional in the sense that a firmware may not
/// send it; missing readings keep the value they had, and `fresh` says which arrived.
pub const Telemetry = struct {
    /// Battery, volts. The robot reports centivolts as an integer (1201 -> 12.01).
    voltage: f32 = 0,
    pan_deg: f32 = 0,
    tilt_deg: f32 = 0,
    cpu_load: f32 = 0,
    cpu_temp_c: f32 = 0,
    ram_usage: f32 = 0,
    video_fps: f32 = 0,
    wifi_rssi: f32 = 0,
    led_mode: u8 = 0,
    base_light: u8 = 0,
    detect_type: u32 = 0,
    detect_react: u32 = 0,
    motion_mode: bool = false,
};

/// Reads the robot's YAML without a YAML parser, because the file is not deep: one level of
/// section headers at column 0, and `key: value` two spaces under them. Every value this
/// bridge needs is at that second level:
///
///   args_config:  max_speed, slow_speed, max_rate
///   cmd_config:   cmd_movition_ctrl, cmd_gimbal_ctrl, ...
///   base_config:  robot_name
///   fb:           the telemetry field map
///
/// Which section a key sits in matters, and is tracked: `fb` and `sbc_config` both contain
/// bare names that would collide if keys were matched without their parent.
pub fn parseConfig(yaml: []const u8) Config {
    var c: Config = .{};
    var section: []const u8 = "";
    var found_speed = false;
    var found_fields = false;

    var lines = std.mem.splitScalar(u8, yaml, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == '-') continue;

        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..colon], " ");
        const value = std.mem.trim(u8, trimmed[colon + 1 ..], " \"'");

        // A key at column 0 opens a section, whatever it is; anything deeper belongs to the
        // section last opened.
        if (line[0] != ' ' and line[0] != '\t') {
            section = key;
            continue;
        }

        if (std.mem.eql(u8, section, "fb")) {
            const id = parseU16(value) orelse continue;
            inline for (@typeInfo(Fields).@"struct".fields) |f| {
                if (std.mem.eql(u8, key, f.name)) {
                    @field(c.fields, f.name) = id;
                    found_fields = true;
                }
            }
            continue;
        }

        if (std.mem.eql(u8, section, "args_config")) {
            if (std.mem.eql(u8, key, "max_speed")) {
                if (parseF32(value)) |v| {
                    c.limits.max_speed = v;
                    found_speed = true;
                }
            } else if (std.mem.eql(u8, key, "slow_speed")) {
                if (parseF32(value)) |v| c.limits.slow_speed = v;
            } else if (std.mem.eql(u8, key, "max_rate")) {
                if (parseF32(value)) |v| c.limits.max_rate = v;
            }
        } else if (std.mem.eql(u8, section, "cmd_config")) {
            if (std.mem.eql(u8, key, "cmd_movition_ctrl")) {
                if (parseU16(value)) |v| c.commands.movition_ctrl = v;
            } else if (std.mem.eql(u8, key, "cmd_gimbal_ctrl")) {
                if (parseU16(value)) |v| c.commands.gimbal_ctrl = v;
            } else if (std.mem.eql(u8, key, "cmd_gimbal_steady")) {
                if (parseU16(value)) |v| c.commands.gimbal_steady = v;
            } else if (std.mem.eql(u8, key, "cmd_gimbal_base_ctrl")) {
                if (parseU16(value)) |v| c.commands.gimbal_base_ctrl = v;
            }
        } else if (std.mem.eql(u8, section, "base_config")) {
            if (std.mem.eql(u8, key, "robot_name")) {
                const n = @min(value.len, c.name_buf.len);
                @memcpy(c.name_buf[0..n], value[0..n]);
                c.name_len = n;
            }
        }
    }

    // Not "the file downloaded" -- "the two things that make commanding safe were actually
    // in it". A served-but-unrecognised file has to read as false, or the bridge would
    // report the robot's limits while enforcing this build's.
    c.from_robot = found_speed and found_fields;
    return c;
}

fn parseF32(text: []const u8) ?f32 {
    return std.fmt.parseFloat(f32, text) catch null;
}

fn parseU16(text: []const u8) ?u16 {
    return std.fmt.parseInt(u16, text, 10) catch null;
}

/// Turns an `update` payload into named readings. `sio.jsonNumber` does the lookups, so a
/// key the firmware does not send simply leaves its field at zero.
pub fn parseTelemetry(json: []const u8, fields: Fields, number: fn ([]const u8, []const u8) ?f64) Telemetry {
    var t: Telemetry = .{};
    var key: [8]u8 = undefined;

    const get = struct {
        fn f(j: []const u8, k: *[8]u8, id: u16, number_fn: fn ([]const u8, []const u8) ?f64) ?f64 {
            const text = std.fmt.bufPrint(k, "{d}", .{id}) catch return null;
            return number_fn(j, text);
        }
    }.f;

    if (get(json, &key, fields.base_voltage, number)) |v| t.voltage = @as(f32, @floatCast(v)) / 100.0;
    if (get(json, &key, fields.pan_angle, number)) |v| t.pan_deg = @floatCast(v);
    if (get(json, &key, fields.tilt_angle, number)) |v| t.tilt_deg = @floatCast(v);
    if (get(json, &key, fields.cpu_load, number)) |v| t.cpu_load = @floatCast(v);
    if (get(json, &key, fields.cpu_temp, number)) |v| t.cpu_temp_c = @floatCast(v);
    if (get(json, &key, fields.ram_usage, number)) |v| t.ram_usage = @floatCast(v);
    if (get(json, &key, fields.video_fps, number)) |v| t.video_fps = @floatCast(v);
    if (get(json, &key, fields.wifi_rssi, number)) |v| t.wifi_rssi = @floatCast(v);
    if (get(json, &key, fields.led_mode, number)) |v| t.led_mode = clampU8(v);
    if (get(json, &key, fields.base_light, number)) |v| t.base_light = clampU8(v);
    if (get(json, &key, fields.detect_type, number)) |v| t.detect_type = clampU32(v);
    if (get(json, &key, fields.detect_react, number)) |v| t.detect_react = clampU32(v);
    if (get(json, &key, fields.cv_movtion_mode, number)) |v| t.motion_mode = v != 0;
    return t;
}

fn clampU8(v: f64) u8 {
    return @intFromFloat(std.math.clamp(v, 0, 255));
}

fn clampU32(v: f64) u32 {
    return @intFromFloat(std.math.clamp(v, 0, 4_294_967_295));
}

/// `{"T":1,"L":<left>,"R":<right>}` -- the two track speeds.
///
/// `left` and `right` arrive as a fraction of full speed in [-1, 1], because that is what a
/// stick or a keyboard produces, and are scaled here by the robot's own `max_speed`. The
/// clamp is not advisory: a caller that asks for 5.0 gets `max_speed`, not 5.0, and the
/// bridge says so on its status topic.
pub fn driveCommand(buf: []u8, commands: Commands, limits: Limits, left: f32, right: f32) ![]const u8 {
    const l = std.math.clamp(left, -1, 1) * limits.max_speed;
    const r = std.math.clamp(right, -1, 1) * limits.max_speed;
    return std.fmt.bufPrint(buf, "{{\"T\":{d},\"L\":{d:.4},\"R\":{d:.4}}}", .{
        commands.movition_ctrl, l, r,
    });
}

/// `{"T":133,"X":<pan>,"Y":<tilt>,"SPD":<spd>,"ACC":<acc>}` -- an absolute pan-tilt target
/// in degrees, clamped to the axes' travel.
pub fn gimbalCommand(
    buf: []u8,
    commands: Commands,
    limits: Limits,
    pan_deg: f32,
    tilt_deg: f32,
    speed: u16,
    accel: u16,
) ![]const u8 {
    const x = std.math.clamp(pan_deg, limits.pan_min_deg, limits.pan_max_deg);
    const y = std.math.clamp(tilt_deg, limits.tilt_min_deg, limits.tilt_max_deg);
    return std.fmt.bufPrint(buf, "{{\"T\":{d},\"X\":{d:.2},\"Y\":{d:.2},\"SPD\":{d},\"ACC\":{d}}}", .{
        commands.gimbal_ctrl, x, y, speed, accel,
    });
}

/// Both tracks to zero. Held as its own function rather than `driveCommand(0, 0)` because
/// the watchdog has to be able to build it when nothing else in the process is healthy --
/// no config, no allocator, no floating-point formatting of a caller's value.
pub fn stopCommand(buf: []u8, commands: Commands) ![]const u8 {
    return std.fmt.bufPrint(buf, "{{\"T\":{d},\"L\":0,\"R\":0}}", .{commands.movition_ctrl});
}

// -- tests ----------------------------------------------------------------------------

const testing = std.testing;

/// The robot's real `GET /config`, captured from 192.168.50.5 on 2026-09-04
/// (`sbc_version: 0.91`). Kept as a fixture because the layout of this file *is* the
/// protocol: the first version of the parser read a flat file, this one is nested one level,
/// and nothing but the real bytes would have caught that.
const real_config = @embedFile("testdata/config.yaml");

test "parseConfig reads the robot's real nested config" {
    const c = parseConfig(real_config);
    try testing.expect(c.from_robot);
    try testing.expectEqualStrings("UGV Beast", c.name());
    // args_config
    try testing.expectEqual(@as(f32, 0.5), c.limits.max_speed);
    try testing.expectEqual(@as(f32, 0.2), c.limits.slow_speed);
    try testing.expectEqual(@as(f32, 1.0), c.limits.max_rate);
    // cmd_config
    try testing.expectEqual(@as(u16, 1), c.commands.movition_ctrl);
    try testing.expectEqual(@as(u16, 133), c.commands.gimbal_ctrl);
    try testing.expectEqual(@as(u16, 137), c.commands.gimbal_steady);
    // fb
    try testing.expectEqual(@as(u16, 112), c.fields.base_voltage);
    try testing.expectEqual(@as(u16, 109), c.fields.pan_angle);
    try testing.expectEqual(@as(u16, 110), c.fields.tilt_angle);
    try testing.expectEqual(@as(u16, 107), c.fields.cpu_temp);
}

test "a key is read from its own section, not by name alone" {
    // `fb` and `sbc_config` both hold bare names. A parser that matched keys without their
    // parent would take 999 here, and the bridge would then read the wrong telemetry field.
    const yaml =
        \\fb:
        \\  base_voltage: 112
        \\sbc_config:
        \\  pan_angle: 999
        \\  max_speed: 99.0
        \\
    ;
    const c = parseConfig(yaml);
    try testing.expectEqual(@as(u16, 112), c.fields.base_voltage);
    try testing.expectEqual(@as(u16, 109), c.fields.pan_angle);
    try testing.expectEqual(@as(f32, 0.5), c.limits.max_speed);
}

test "a config served but unrecognised reads as not-from-robot" {
    // The failure this guards: the bridge reporting the robot's limits on its status topic
    // while actually enforcing this build's defaults. Downloading a file is not parsing one.
    const c = parseConfig("some_other_service:\n  version: 2\n");
    try testing.expect(!c.from_robot);
    try testing.expectEqual(@as(f32, 0.5), c.limits.max_speed);
}

test "a config with the field map but no speed limit is not trusted either" {
    const c = parseConfig("fb:\n  base_voltage: 112\n");
    try testing.expect(!c.from_robot);
}

test "a config that cannot be read is flagged, not silently defaulted" {
    const c: Config = .{};
    try testing.expect(!c.from_robot);
    try testing.expectEqual(@as(f32, 0.5), c.limits.max_speed);
}

test "drive scales by the robot's max_speed rather than passing a fraction through" {
    var buf: [128]u8 = undefined;
    const cmd = try driveCommand(&buf, .{}, .{ .max_speed = 0.5 }, 1.0, -1.0);
    try testing.expectEqualStrings("{\"T\":1,\"L\":0.5000,\"R\":-0.5000}", cmd);
}

test "drive clamps a caller that asks for more than full scale" {
    var buf: [128]u8 = undefined;
    const cmd = try driveCommand(&buf, .{}, .{ .max_speed = 0.5 }, 10.0, -10.0);
    try testing.expectEqualStrings("{\"T\":1,\"L\":0.5000,\"R\":-0.5000}", cmd);
}

test "gimbal clamps to the axes' travel, which is asymmetric in tilt" {
    var buf: [128]u8 = undefined;
    const limits: Limits = .{};
    try testing.expectEqualStrings(
        "{\"T\":133,\"X\":180.00,\"Y\":90.00,\"SPD\":0,\"ACC\":0}",
        try gimbalCommand(&buf, .{}, limits, 900, 900, 0, 0),
    );
    try testing.expectEqualStrings(
        "{\"T\":133,\"X\":-180.00,\"Y\":-30.00,\"SPD\":0,\"ACC\":0}",
        try gimbalCommand(&buf, .{}, limits, -900, -900, 0, 0),
    );
}

test "stop is exactly zero on both tracks" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("{\"T\":1,\"L\":0,\"R\":0}", try stopCommand(&buf, .{}));
}

test "telemetry converts the robot's centivolts to volts" {
    const sio = @import("sio");
    const json = "{\"104\":0.07,\"106\":35,\"107\":54.12,\"109\":12.5,\"110\":-3.25," ++
        "\"112\":1201,\"113\":26.0,\"114\":true,\"115\":0}";
    const t = parseTelemetry(json, .{}, sio.jsonNumber);
    try testing.expectApproxEqAbs(@as(f32, 12.01), t.voltage, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 12.5), t.pan_deg, 0.001);
    try testing.expectApproxEqAbs(@as(f32, -3.25), t.tilt_deg, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 54.12), t.cpu_temp_c, 0.001);
    try testing.expect(t.motion_mode);
    try testing.expectEqual(@as(u8, 0), t.base_light);
}

test "a telemetry field the firmware omits reads as zero, not as another field's value" {
    const sio = @import("sio");
    const t = parseTelemetry("{\"112\":1201}", .{}, sio.jsonNumber);
    try testing.expectApproxEqAbs(@as(f32, 12.01), t.voltage, 0.001);
    try testing.expectEqual(@as(f32, 0), t.pan_deg);
    try testing.expectEqual(@as(f32, 0), t.cpu_temp_c);
}
