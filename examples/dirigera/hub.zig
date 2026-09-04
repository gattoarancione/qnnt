//! The DIRIGERA hub's vocabulary: what a device is, what it reports, what it accepts.
//!
//! Read off a real hub (firmware 2.975.3, api 1.6.7) rather than from documentation, and
//! examples/dirigera/testdata/devices.json is that hub's actual `/v1/devices` response,
//! sanitised, kept as a fixture. Sanitised because it came out of somebody's home: the
//! serial numbers, the timezone and the room names are replaced. What a test needs is the
//! SHAPE, and every structural property survives -- the five device types, the
//! `capabilities.canReceive` lists, the paired sensors sharing a `relationId`, an
//! unreachable device, and the colour-temperature quirk below.
//!
//! Three things about this API are worth knowing before writing against it:
//!
//! **`202 Accepted` means queued, not applied.** A `PATCH` to an unreachable device
//! succeeds and nothing happens -- the hub keeps its own idea of the device's state and
//! reports that back. So a command is not a confirmation, and the state that matters is
//! whatever the hub subsequently reports.
//!
//! **Only `capabilities.canReceive` is writable.** For lights that is `isOn`, `lightLevel`
//! and `colorTemperature`; for the remotes and the sensors it is `customName` alone, which
//! makes them read-only in every way that matters.
//!
//! **`colorTemperatureMin` is numerically LARGER than `colorTemperatureMax`** -- 4000
//! against 2202 on the bulb here. The names run in mired order while the values are in
//! Kelvin, so a clamp written the obvious way produces an empty range and rejects every
//! input. `clampTemperature` sorts the bounds instead of trusting their names.

const std = @import("std");

pub const DeviceType = enum {
    light,
    light_controller,
    motion_sensor,
    light_sensor,
    outlet,
    air_purifier,
    environment_sensor,
    blinds,
    speaker,
    gateway,
    other,

    /// The hub's spelling, which is camelCase.
    pub fn parse(text: []const u8) DeviceType {
        const table = .{
            .{ "light", DeviceType.light },
            .{ "lightController", DeviceType.light_controller },
            .{ "motionSensor", DeviceType.motion_sensor },
            .{ "lightSensor", DeviceType.light_sensor },
            .{ "outlet", DeviceType.outlet },
            .{ "airPurifier", DeviceType.air_purifier },
            .{ "environmentSensor", DeviceType.environment_sensor },
            .{ "blinds", DeviceType.blinds },
            .{ "speaker", DeviceType.speaker },
            .{ "gateway", DeviceType.gateway },
        };
        inline for (table) |entry| {
            if (std.mem.eql(u8, text, entry[0])) return entry[1];
        }
        return .other;
    }

    pub fn slug(t: DeviceType) []const u8 {
        return switch (t) {
            .light => "light",
            .light_controller => "lightController",
            .motion_sensor => "motionSensor",
            .light_sensor => "lightSensor",
            .outlet => "outlet",
            .air_purifier => "airPurifier",
            .environment_sensor => "environmentSensor",
            .blinds => "blinds",
            .speaker => "speaker",
            .gateway => "gateway",
            .other => "other",
        };
    }

    /// Whether this bridge will send commands to it at all. Everything else is published
    /// read-only, which is not a policy choice -- the hub does not accept anything but a
    /// rename for them.
    pub fn isActuator(t: DeviceType) bool {
        return switch (t) {
            .light, .outlet, .blinds => true,
            else => false,
        };
    }
};

/// One device, flattened. The hub nests state under `attributes` and mixes in a lot of
/// firmware bookkeeping (OTA schedules, startup behaviour, circadian presets); this keeps
/// what a consumer of a home-automation topic would actually use.
pub const Device = struct {
    id: []const u8,
    type: DeviceType,
    name: []const u8,
    room: []const u8,
    model: []const u8,
    reachable: bool,
    /// Sensors and remotes that share one radio report the same `relationId`. The three
    /// VALLHORN units here each appear twice -- once as a motion sensor, once as a light
    /// sensor -- and this is what pairs them.
    relation: []const u8,

    // -- state, whichever of it applies -------------------------------------------
    /// Lights and outlets.
    is_on: ?bool = null,
    /// 0..100.
    light_level: ?u8 = null,
    /// Kelvin.
    color_temperature: ?u16 = null,
    color_temperature_min: ?u16 = null,
    color_temperature_max: ?u16 = null,
    /// Battery-powered sensors and remotes, 0..100.
    battery: ?u8 = null,
    /// Motion sensors.
    is_detected: ?bool = null,
    /// Light sensors.
    illuminance: ?u32 = null,
    /// Whether the hub will accept `isOn` for this device -- i.e. `isOn` appears in its
    /// `capabilities.canReceive`. Carried rather than inferred from the type, because the
    /// hub is the authority on it.
    can_set_on: bool = false,
    can_set_level: bool = false,
    can_set_temperature: bool = false,

    /// A stable, human-meaningful topic segment: the room and name, lowercased, with
    /// anything awkward replaced. Falls back to the id when a device has no name, which is
    /// the case for the light-sensor half of a VALLHORN.
    pub fn topicSegment(d: Device, buf: []u8) []const u8 {
        var len: usize = 0;
        const parts = [_][]const u8{ d.room, d.name };
        for (parts) |part| {
            if (part.len == 0) continue;
            if (len > 0 and len < buf.len) {
                buf[len] = '-';
                len += 1;
            }
            for (part) |ch| {
                if (len >= buf.len) break;
                buf[len] = switch (ch) {
                    'A'...'Z' => ch + 32,
                    'a'...'z', '0'...'9' => ch,
                    else => '-',
                };
                len += 1;
            }
        }
        if (len == 0) {
            const n = @min(d.id.len, buf.len);
            @memcpy(buf[0..n], d.id[0..n]);
            return buf[0..n];
        }
        return buf[0..len];
    }
};

/// Devices parsed out of a `/v1/devices` response, plus the arena holding their strings.
/// The strings point into the parsed JSON, so the whole thing is freed together.
pub const Inventory = struct {
    devices: []Device,
    parsed: std.json.Parsed(std.json.Value),
    allocator: std.mem.Allocator,

    pub fn deinit(inv: *Inventory) void {
        inv.allocator.free(inv.devices);
        inv.parsed.deinit();
    }

    pub fn find(inv: Inventory, id: []const u8) ?Device {
        for (inv.devices) |d| {
            if (std.mem.eql(u8, d.id, id)) return d;
        }
        return null;
    }
};

/// Parse `/v1/devices`. Unknown device types and unknown attributes are ignored rather than
/// refused: a firmware update that adds either must not stop the bridge from working with
/// what it already understands.
pub fn parseDevices(allocator: std.mem.Allocator, json: []const u8) !Inventory {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    errdefer parsed.deinit();

    const array = switch (parsed.value) {
        .array => |a| a,
        else => return error.NotADeviceList,
    };

    var devices = try allocator.alloc(Device, array.items.len);
    errdefer allocator.free(devices);

    var count: usize = 0;
    for (array.items) |item| {
        const object = switch (item) {
            .object => |o| o,
            else => continue,
        };
        devices[count] = parseDevice(object);
        count += 1;
    }

    return .{
        .devices = devices[0..count],
        .parsed = parsed,
        .allocator = allocator,
    };
}

fn parseDevice(object: std.json.ObjectMap) Device {
    var d: Device = .{
        .id = str(object.get("id")) orelse "",
        .type = DeviceType.parse(str(object.get("deviceType")) orelse ""),
        .name = "",
        .room = "",
        .model = "",
        .reachable = boolean(object.get("isReachable")) orelse false,
        .relation = str(object.get("relationId")) orelse "",
    };

    if (object.get("room")) |room| {
        if (room == .object) d.room = str(room.object.get("name")) orelse "";
    }

    if (object.get("attributes")) |attributes| {
        if (attributes == .object) {
            const a = attributes.object;
            d.name = str(a.get("customName")) orelse "";
            d.model = str(a.get("model")) orelse "";
            d.is_on = boolean(a.get("isOn"));
            if (integer(a.get("lightLevel"))) |v| d.light_level = clampU8(v);
            if (integer(a.get("colorTemperature"))) |v| d.color_temperature = clampU16(v);
            if (integer(a.get("colorTemperatureMin"))) |v| d.color_temperature_min = clampU16(v);
            if (integer(a.get("colorTemperatureMax"))) |v| d.color_temperature_max = clampU16(v);
            if (integer(a.get("batteryPercentage"))) |v| d.battery = clampU8(v);
            d.is_detected = boolean(a.get("isDetected"));
            if (integer(a.get("illuminance"))) |v| d.illuminance = @intCast(@max(0, v));
        }
    }

    // The hub is the authority on what it will accept, so this is read rather than guessed
    // from the device type.
    if (object.get("capabilities")) |capabilities| {
        if (capabilities == .object) {
            if (capabilities.object.get("canReceive")) |can| {
                if (can == .array) {
                    for (can.array.items) |entry| {
                        const name = str(entry) orelse continue;
                        if (std.mem.eql(u8, name, "isOn")) d.can_set_on = true;
                        if (std.mem.eql(u8, name, "lightLevel")) d.can_set_level = true;
                        if (std.mem.eql(u8, name, "colorTemperature")) d.can_set_temperature = true;
                    }
                }
            }
        }
    }

    return d;
}

fn str(value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn boolean(value: ?std.json.Value) ?bool {
    const v = value orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

fn integer(value: ?std.json.Value) ?i64 {
    const v = value orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn clampU8(v: i64) u8 {
    return @intCast(std.math.clamp(v, 0, 255));
}

fn clampU16(v: i64) u16 {
    return @intCast(std.math.clamp(v, 0, 65535));
}

/// Clamp a Kelvin value to what the bulb supports, without trusting which bound is called
/// which. See the file header: the hub reports min 4000 and max 2202 on the same bulb, so
/// sorting the pair is the only way to get a non-empty range.
pub fn clampTemperature(kelvin: u16, bound_a: ?u16, bound_b: ?u16) u16 {
    const a = bound_a orelse return kelvin;
    const b = bound_b orelse return kelvin;
    const low = @min(a, b);
    const high = @max(a, b);
    return std.math.clamp(kelvin, low, high);
}

/// The body of a `PATCH /v1/devices/<id>`: a one-element array of attribute sets.
///
/// Only the fields asked for are sent, and only if the device said it accepts them --
/// sending an attribute a device does not list makes the hub reject the whole call, so one
/// unsupported field would lose the others with it.
pub fn lightCommand(
    buf: []u8,
    device: Device,
    on: ?bool,
    level: ?u8,
    kelvin: ?u16,
) ![]const u8 {
    var stream = std.Io.Writer.fixed(buf);
    try stream.writeAll("[{\"attributes\":{");

    var wrote = false;
    if (on) |value| {
        if (device.can_set_on) {
            try stream.print("\"isOn\":{s}", .{if (value) "true" else "false"});
            wrote = true;
        }
    }
    if (level) |value| {
        if (device.can_set_level) {
            if (wrote) try stream.writeAll(",");
            try stream.print("\"lightLevel\":{d}", .{@min(value, 100)});
            wrote = true;
        }
    }
    if (kelvin) |value| {
        if (device.can_set_temperature) {
            if (wrote) try stream.writeAll(",");
            const clamped = clampTemperature(
                value,
                device.color_temperature_min,
                device.color_temperature_max,
            );
            try stream.print("\"colorTemperature\":{d}", .{clamped});
            wrote = true;
        }
    }
    if (!wrote) return error.NothingToSend;

    try stream.writeAll("}}]");
    return stream.buffered();
}

// -- tests ----------------------------------------------------------------------------

const testing = std.testing;

/// A real hub's `/v1/devices`, sanitised. See the file header.
const fixture = @embedFile("testdata/devices.json");

test "the real inventory parses into the five device types" {
    var inv = try parseDevices(testing.allocator, fixture);
    defer inv.deinit();

    try testing.expectEqual(@as(usize, 17), inv.devices.len);

    var lights: usize = 0;
    var controllers: usize = 0;
    var motion: usize = 0;
    var light_sensors: usize = 0;
    var gateways: usize = 0;
    for (inv.devices) |d| switch (d.type) {
        .light => lights += 1,
        .light_controller => controllers += 1,
        .motion_sensor => motion += 1,
        .light_sensor => light_sensors += 1,
        .gateway => gateways += 1,
        else => {},
    };
    try testing.expectEqual(@as(usize, 5), lights);
    try testing.expectEqual(@as(usize, 5), controllers);
    try testing.expectEqual(@as(usize, 3), motion);
    try testing.expectEqual(@as(usize, 3), light_sensors);
    try testing.expectEqual(@as(usize, 1), gateways);
}

test "writability comes from the hub's canReceive, not from the device type" {
    var inv = try parseDevices(testing.allocator, fixture);
    defer inv.deinit();

    for (inv.devices) |d| switch (d.type) {
        .light => {
            try testing.expect(d.can_set_on);
            try testing.expect(d.can_set_level);
        },
        // The remotes and sensors accept a rename and nothing else, so nothing here may
        // treat them as controllable.
        .light_controller, .motion_sensor, .light_sensor => {
            try testing.expect(!d.can_set_on);
            try testing.expect(!d.can_set_level);
            try testing.expect(!d.can_set_temperature);
        },
        else => {},
    };
}

test "an unreachable device is parsed as such" {
    // The case that matters: the hub reports state for a device it cannot currently talk
    // to, and a caller that ignores `reachable` will believe that state is live.
    var inv = try parseDevices(testing.allocator, fixture);
    defer inv.deinit();

    var unreachable_count: usize = 0;
    for (inv.devices) |d| {
        if (!d.reachable) unreachable_count += 1;
    }
    try testing.expect(unreachable_count >= 1);
}

test "paired sensors share a relationId" {
    // Each VALLHORN appears twice, as a motion sensor and a light sensor. A consumer that
    // wants "did motion happen where it is dark" needs the pairing.
    var inv = try parseDevices(testing.allocator, fixture);
    defer inv.deinit();

    var motion_relations: usize = 0;
    for (inv.devices) |d| {
        if (d.type != .motion_sensor or d.relation.len == 0) continue;
        motion_relations += 1;
        var matched = false;
        for (inv.devices) |other| {
            if (other.type == .light_sensor and std.mem.eql(u8, other.relation, d.relation))
                matched = true;
        }
        try testing.expect(matched);
    }
    try testing.expectEqual(@as(usize, 3), motion_relations);
}

test "clampTemperature survives the hub reporting min above max" {
    // The bulb here reports min 4000, max 2202. Clamping in the order the names imply
    // yields an empty range and every value collapses to one end.
    try testing.expectEqual(@as(u16, 3000), clampTemperature(3000, 4000, 2202));
    try testing.expectEqual(@as(u16, 4000), clampTemperature(9000, 4000, 2202));
    try testing.expectEqual(@as(u16, 2202), clampTemperature(1000, 4000, 2202));
    // And the sane ordering must behave identically.
    try testing.expectEqual(@as(u16, 3000), clampTemperature(3000, 2202, 4000));
}

test "clampTemperature passes the value through when the bulb states no bounds" {
    try testing.expectEqual(@as(u16, 2700), clampTemperature(2700, null, null));
    try testing.expectEqual(@as(u16, 2700), clampTemperature(2700, 4000, null));
}

test "lightCommand emits only attributes the device accepts" {
    var buf: [256]u8 = undefined;
    const dimmable: Device = .{
        .id = "x", .type = .light, .name = "n", .room = "r", .model = "m",
        .reachable = true, .relation = "",
        .can_set_on = true, .can_set_level = true, .can_set_temperature = false,
    };
    try testing.expectEqualStrings(
        "[{\"attributes\":{\"isOn\":true,\"lightLevel\":40}}]",
        try lightCommand(&buf, dimmable, true, 40, 2700),
    );
}

test "lightCommand refuses to send nothing rather than an empty attribute set" {
    // A device that accepts none of the requested fields must produce an error, not
    // `[{"attributes":{}}]` -- which the hub would accept as a successful no-op and leave
    // the caller believing the command took effect.
    var buf: [256]u8 = undefined;
    const sensor: Device = .{
        .id = "x", .type = .motion_sensor, .name = "n", .room = "r", .model = "m",
        .reachable = true, .relation = "",
    };
    try testing.expectError(error.NothingToSend, lightCommand(&buf, sensor, true, 50, 2700));
}

test "lightCommand clamps level and temperature" {
    var buf: [256]u8 = undefined;
    const bulb: Device = .{
        .id = "x", .type = .light, .name = "n", .room = "r", .model = "m",
        .reachable = true, .relation = "",
        .color_temperature_min = 4000, .color_temperature_max = 2202,
        .can_set_level = true, .can_set_temperature = true,
    };
    try testing.expectEqualStrings(
        "[{\"attributes\":{\"lightLevel\":100,\"colorTemperature\":4000}}]",
        try lightCommand(&buf, bulb, null, 250, 9000),
    );
}

test "topicSegment builds a stable readable segment" {
    var buf: [64]u8 = undefined;
    const d: Device = .{
        .id = "abc", .type = .light, .name = "Desk lamp", .room = "Room A",
        .model = "m", .reachable = true, .relation = "",
    };
    try testing.expectEqualStrings("room-a-desk-lamp", d.topicSegment(&buf));
}

test "topicSegment falls back to the id for a device with no name" {
    // The light-sensor half of a VALLHORN has an empty customName.
    var buf: [64]u8 = undefined;
    const d: Device = .{
        .id = "1234", .type = .light_sensor, .name = "", .room = "",
        .model = "m", .reachable = true, .relation = "",
    };
    try testing.expectEqualStrings("1234", d.topicSegment(&buf));
}

test "an unknown device type degrades instead of failing the whole parse" {
    const json =
        \\[{"id":"a","deviceType":"quantumToaster","isReachable":true,
        \\  "attributes":{"customName":"T"}},
        \\ {"id":"b","deviceType":"light","isReachable":true,
        \\  "attributes":{"customName":"L","isOn":true},
        \\  "capabilities":{"canReceive":["isOn"]}}]
    ;
    var inv = try parseDevices(testing.allocator, json);
    defer inv.deinit();
    try testing.expectEqual(@as(usize, 2), inv.devices.len);
    try testing.expectEqual(DeviceType.other, inv.devices[0].type);
    try testing.expectEqual(DeviceType.light, inv.devices[1].type);
    try testing.expect(inv.devices[1].can_set_on);
}
