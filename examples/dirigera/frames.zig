//! What travels on the bridge's topics.
//!
//! Its own module for one reason: these definitions have a counterpart in C++
//! (examples/dirigera/frames.hpp) and the two must agree FIELD BY FIELD. A mismatched name
//! is not a compile error on either side and not an error at runtime either -- TOLD ignores
//! a key the receiving struct does not declare, and `told.hpp` leaves a member the
//! frame did not carry exactly as its constructor left it. The result is plausible data:
//! a light that reports itself uncontrollable, a sensor with no room.
//!
//! So the agreement is pinned by a golden frame rather than by review. `testdata/*.tld`
//! holds bytes packed from the canonical values below; the Zig test checks that packing
//! them still produces those bytes, and examples/cpp_logic_test.cpp checks that the C++
//! structs unpack the same bytes to the same values. Either side drifting fails.
//!
//! Regenerating a golden is deliberate work, not something a test does on your behalf: see
//! the note on `canonical_device`.

const std = @import("std");
const qnnt_mod = @import("qnnt");
const told = qnnt_mod.Told;

/// One device's state. Optionals are genuinely optional: a motion sensor has no
/// `light_level`, and TOLD carries the absence rather than a zero that a consumer would have
/// to know to disbelieve.
pub const DeviceFrame = struct {
    id: []const u8,
    type: []const u8,
    name: []const u8,
    room: []const u8,
    model: []const u8,
    /// False means the hub cannot currently reach it, so the values below are its last
    /// known state rather than a live reading. Carried because a consumer that ignores it
    /// will happily display hours-old data as current.
    reachable: bool,
    is_on: ?bool,
    light_level: ?u8,
    color_temperature: ?u16,
    battery: ?u8,
    is_detected: ?bool,
    illuminance: ?u32,
    /// Whether this bridge would accept any command for it -- a summary of the three
    /// flags below, kept because most consumers only need the yes/no.
    controllable: bool,
    /// Which attributes the hub will actually accept, from its own `canReceive`. Published
    /// separately because a controller has to know WHICH control to offer: a dimmable white
    /// bulb and a tunable one differ only here, and guessing from the device type gets it
    /// wrong.
    can_set_on: bool,
    can_set_level: bool,
    can_set_temperature: bool,
    /// The bulb's colour-temperature range in Kelvin, already sorted low-to-high -- the hub
    /// reports its `min` above its `max`. Null when the device has no such range.
    temperature_min: ?u16,
    temperature_max: ?u16,
    /// Devices sharing one physical unit share this. A VALLHORN is a single sensor on the
    /// wall that the hub presents as two devices -- a motion sensor and a light sensor --
    /// and this is the only thing that says so. Published because a consumer that shows
    /// them separately is showing one sensor twice, and the light-sensor half carries
    /// neither a name nor a room of its own.
    relation: []const u8,
};

pub const StateFrame = struct {
    seq: u64,
    t_us: u64,
    /// What the hub called the event, e.g. `deviceStateChanged`. Carried verbatim because
    /// this bridge does not pretend to know every event type a firmware may introduce.
    event: []const u8,
    /// The device was in the last inventory, so `device` below carries its name, room and
    /// capabilities. False for a device paired since the last refresh, where only the
    /// changed attributes are known.
    identified: bool,
    device: DeviceFrame,
};

pub const InventoryFrame = struct {
    t_us: u64,
    hub: []const u8,
    count: u32,
    devices: []const DeviceFrame,
};

pub const StatusFrame = struct {
    t_us: u64,
    hub: []const u8,
    firmware: []const u8,
    /// The REST API answered the last time it was tried.
    api_link: bool,
    /// The push stream is connected. Tracked apart from `api_link` because the two fail
    /// independently, and the whole value of this bridge is the push stream.
    event_link: bool,
    devices: u32,
    events_received: u64,
    events_unparsed: u64,
    /// WebSocket continuation frames, which this reader does not reassemble. Non-zero means
    /// events are being lost and ws.zig needs the fragmentation it currently skips.
    dropped_fragments: u64,
    commands_sent: u64,
    commands_failed: u64,
    /// Commands for a device the hub does not accept commands for, or an unknown id.
    commands_refused: u64,
    reconnects: u64,

    /// A bearer token is in hand.
    ///
    /// False means the bridge is running and its topics are up, but the only hub endpoint
    /// it can reach is the unauthenticated one -- it is waiting to be paired. A controller
    /// reads this to know whether to show a house or a pairing panel.
    paired: bool,
    /// A pairing exchange is under way: the hub has a window open and is waiting for its
    /// action button to be pressed.
    pairing: bool,
    /// The last thing the pairing exchange said, in words meant for whoever is standing at
    /// the hub -- "press the action button", or the hub's own reason for refusing. Empty
    /// when no pairing has been attempted.
    pair_detail: []const u8,
};

/// A request to pair, from a controller. The bridge runs the exchange; the controller only
/// starts and stops it, because the operator has to be at the hub either way.
pub const PairRequest = struct {
    /// How the hub will list this client. Worth a name a person would recognise months
    /// later, since it appears in IKEA's own app.
    name: []const u8 = "qnnt-bridge",
    /// Abandon an exchange already running.
    cancel: bool = false,
};

/// A command from the command topic. Every field but the id is optional, so a controller can
/// dim without touching colour, or switch on without touching level.
pub const LightCommand = struct {
    /// The hub's device id. `--list` prints them.
    id: []const u8,
    on: ?bool = null,
    level: ?u8 = null,
    kelvin: ?u16 = null,
};

// -- the golden frames -----------------------------------------------------------------

/// A device with EVERY field populated and no two values alike.
///
/// Distinct values matter: if two fields shared a value, swapping them on one side of the
/// language boundary would still compare equal and the test would pass through the bug.
/// The optionals are all present here for the same reason -- a null proves nothing about
/// whether the name matched, since a missing key also reads as null.
pub const canonical_device: DeviceFrame = .{
    .id = "abc123_1",
    .type = "light",
    .name = "Hall light",
    .room = "Room A",
    .model = "TRADFRI bulb E27",
    .reachable = true,
    .is_on = true,
    .light_level = 57,
    .color_temperature = 2842,
    .battery = 91,
    .is_detected = false,
    .illuminance = 314,
    .controllable = true,
    .can_set_on = true,
    .can_set_level = true,
    // Every plain bool is true on purpose. A `bool` default-constructs to false in C++, so
    // a field the station stopped declaring would read as false -- and a canonical value of
    // false would then be indistinguishable from a dropped field, letting the check pass
    // straight through the bug it exists to catch. False-ness is tested on the OPTIONAL
    // bools instead, where absent and present-but-false are different things.
    .can_set_temperature = true,
    .temperature_min = 2202,
    .temperature_max = 4000,
    .relation = "rel-77",
};

/// A command with every field present. This is the struct the C++ station SENDS, so a
/// mismatch here is a click that silently does nothing.
pub const canonical_command: LightCommand = .{
    .id = "abc123_1",
    .on = true,
    .level = 42,
    .kelvin = 2700,
};

const golden_device = @embedFile("testdata/device_frame.tld");
const golden_command = @embedFile("testdata/light_command.tld");

const testing = std.testing;

test "the canonical device still packs to the golden bytes" {
    // Fails when a field is added, renamed, reordered or retyped on the Zig side. That is
    // the point: the C++ side is checked against the same bytes, so a change here that is
    // not mirrored there shows up as one of these two tests failing rather than as a
    // station quietly displaying defaults.
    //
    // To regenerate deliberately: run with the environment variable QNNT_WRITE_GOLDEN set,
    // which prints the new bytes as hex for you to write out -- reviewing them is the
    // point, so nothing overwrites the file on its own.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try told.packTo(testing.allocator, &buf, canonical_device);

    if (std.c.getenv("QNNT_WRITE_GOLDEN") != null) {
        std.debug.print("device_frame.tld = {x}\n", .{buf.items});
    }
    try testing.expectEqualSlices(u8, golden_device, buf.items);
}

test "the canonical light command still packs to the golden bytes" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try told.packTo(testing.allocator, &buf, canonical_command);

    if (std.c.getenv("QNNT_WRITE_GOLDEN") != null) {
        std.debug.print("light_command.tld = {x}\n", .{buf.items});
    }
    try testing.expectEqualSlices(u8, golden_command, buf.items);
}

test "a golden frame unpacks back to the canonical values" {
    // The other direction, so the goldens are known to be readable and not merely stable.
    // No allocator: every field here is a scalar or a string, so the strings can point
    // straight into the embedded bytes instead of being copied and then leaked.
    const back = try told.unpackFrom(DeviceFrame, golden_device, null);
    try testing.expectEqualStrings(canonical_device.id, back.id);
    try testing.expectEqualStrings(canonical_device.name, back.name);
    try testing.expectEqual(canonical_device.light_level, back.light_level);
    try testing.expectEqual(canonical_device.temperature_min, back.temperature_min);
    try testing.expectEqual(canonical_device.can_set_temperature, back.can_set_temperature);
    try testing.expectEqualStrings(canonical_device.relation, back.relation);
}
