//! The bridge: an IKEA DIRIGERA hub on one side, qnnt topics on the other.
//!
//!   ./zig-out/bin/dirigera-bridge --host 192.168.1.20:8443 --token ./dirigera_token
//!
//!   dirigera-bridge --host <ip:port> [--token path] [--topic prefix] [--list]
//!
//! Find the hub without guessing, because its address moves:
//!
//!   dns-sd -B _ihsp._tcp local            # the hub announces itself
//!   dns-sd -L <instance> _ihsp._tcp local # TXT record carries ipv4address and version
//!
//! Four topics:
//!
//!   home/dirigera/state       published   one frame per device, when it changes
//!   home/dirigera/inventory   published   every device, on a timer
//!   home/dirigera/status      published   the link, the hub, the counters
//!   home/dirigera/light       subscribed  {id, on?, level?, kelvin?}
//!
//! WHAT MAKES THIS DIFFERENT FROM THE UGV BRIDGE, and it is the interesting part: the hub
//! PUSHES. State arrives on a WebSocket the moment a light is switched, a sensor trips or an
//! illuminance reading moves, so this bridge is a translator rather than a poller. The UGV
//! had to be asked, and answered about every five seconds. Here `--list` exists only as a
//! diagnostic; the running bridge never polls for state.
//!
//! The inventory is still fetched on a timer, but for a different reason: the push stream
//! carries CHANGES, so a device that never changes would never appear, and a subscriber that
//! attaches late would see an empty world. The timer is what makes the topic complete rather
//! than merely current -- the same reason the camera bridge republishes its calibration.
//!
//! ON WRITING TO A HOUSE. This bridge controls real lights in someone's home, so:
//!
//!   * It sends nothing at startup, and nothing periodically. A command goes out only when
//!     one arrives on the command topic.
//!   * It commands only what the hub says is writable -- `capabilities.canReceive` -- which
//!     in practice means lights and outlets. Remotes and sensors are published read-only
//!     because the hub accepts nothing else for them.
//!   * There is no watchdog, and that is deliberate rather than an omission. The UGV needed
//!     one because a robot left driving is dangerous; a light left on is not, and a bridge
//!     that switched lights off when its controller went quiet would be a worse failure than
//!     the one it prevented.
//!   * `202 Accepted` from the hub is not applied, only queued, so a command is never
//!     reported as confirmed. The state topic says what the hub says, and that is the only
//!     confirmation there is.

const std = @import("std");
const qnnt_mod = @import("qnnt");
const qnnt = qnnt_mod.Qnnt;
const tld = qnnt_mod.Tld;
const https = @import("https");
const hub = @import("hub");
const ws = @import("ws");

const allocator = std.heap.page_allocator;

/// This bridge's own `Io`, distinct from `bridge_io`.
///
/// The library's `io` is only valid once `qnnt.run()` has been called, and two things here
/// happen before that or without it entirely: reading the token, and `--list`, which talks
/// to the hub and exits without ever starting a node. Using the library's `io` for those
/// dereferences an undefined pointer -- which is exactly what it did, with a segfault in
/// the token read.
var bridge_io: std.Io = undefined;

/// The hub's REST paths.
const path_devices = "/v1/devices";
const path_status = "/v1/hub/status";
/// The WebSocket lives on the same port as the API.
const path_events = "/v1";

// -- the wire types ---------------------------------------------------------------------

/// One device's state. Optionals are genuinely optional: a motion sensor has no
/// `light_level`, and TLD carries the absence rather than a zero that a consumer would have
/// to know to disbelieve.
const DeviceFrame = struct {
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

const StateFrame = struct {
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

const InventoryFrame = struct {
    t_us: u64,
    hub: []const u8,
    count: u32,
    devices: []const DeviceFrame,
};

const StatusFrame = struct {
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
};

/// A command from the command topic. Every field but the id is optional, so a controller can
/// dim without touching colour, or switch on without touching level.
const LightCommand = struct {
    /// The hub's device id. `--list` prints them.
    id: []const u8,
    on: ?bool = null,
    level: ?u8 = null,
    kelvin: ?u16 = null,
};

// -- shared state ------------------------------------------------------------------------

const max_pending = 32;

const Shared = struct {
    mutex: std.Io.Mutex = .init,

    api_link: bool = false,
    event_link: bool = false,
    events_received: u64 = 0,
    events_unparsed: u64 = 0,
    dropped_fragments: u64 = 0,
    commands_sent: u64 = 0,
    commands_failed: u64 = 0,
    commands_refused: u64 = 0,
    reconnects: u64 = 0,
    device_count: u32 = 0,

    /// Commands arrive on qnnt's subscriber thread and are sent from the supervisor, because
    /// an HTTPS round trip inside the callback would stall delivery of the next one. A ring
    /// rather than a single slot: two lights switched together must not lose one.
    pending: [max_pending]Pending = undefined,
    pending_head: usize = 0,
    pending_len: usize = 0,
    /// Commands dropped because the ring was full.
    pending_dropped: u64 = 0,
};

const Pending = struct {
    id_buf: [64]u8,
    id_len: usize,
    on: ?bool,
    level: ?u8,
    kelvin: ?u16,

    fn id(p: *const Pending) []const u8 {
        return p.id_buf[0..p.id_len];
    }
};

var shared: Shared = .{};

/// The last full inventory, and the lock over it.
///
/// The event thread needs this, which is why it is not just a local in the supervisor: a
/// pushed event carries ONLY the attributes that changed. A light being switched arrives as
/// an id plus `isOn` -- no name, no room, no capabilities -- so an event published on its
/// own tells a consumer that something it cannot identify changed, and (because
/// `canReceive` is absent) that it cannot be controlled. Merging the event over the last
/// known inventory is what makes the state topic usable.
var inventory: ?hub.Inventory = null;
var inventory_mutex: std.Io.Mutex = .init;

/// What an event needs from the inventory, copied out under the lock.
///
/// Copied rather than referenced because `hub.Inventory` owns the parsed JSON its strings
/// point into, and the supervisor replaces the whole thing every 30 seconds -- holding a
/// slice across that would be a use-after-free.
const Identity = struct {
    name_buf: [64]u8 = undefined,
    name_len: usize = 0,
    room_buf: [64]u8 = undefined,
    room_len: usize = 0,
    model_buf: [64]u8 = undefined,
    model_len: usize = 0,
    known: bool = false,
    can_set_on: bool = false,
    can_set_level: bool = false,
    can_set_temperature: bool = false,
    temperature_min: ?u16 = null,
    temperature_max: ?u16 = null,
    relation_buf: [64]u8 = undefined,
    relation_len: usize = 0,
    /// Last known values, for the attributes this event did not carry.
    is_on: ?bool = null,
    light_level: ?u8 = null,
    color_temperature: ?u16 = null,
    battery: ?u8 = null,
    is_detected: ?bool = null,
    illuminance: ?u32 = null,

    fn name(i: *const Identity) []const u8 {
        return i.name_buf[0..i.name_len];
    }
    fn room(i: *const Identity) []const u8 {
        return i.room_buf[0..i.room_len];
    }
    fn model(i: *const Identity) []const u8 {
        return i.model_buf[0..i.model_len];
    }
    fn relation(i: *const Identity) []const u8 {
        return i.relation_buf[0..i.relation_len];
    }
};

fn identityOf(id: []const u8) Identity {
    inventory_mutex.lockUncancelable(bridge_io);
    defer inventory_mutex.unlock(bridge_io);

    var out: Identity = .{};
    const inv = inventory orelse return out;
    const d = inv.find(id) orelse return out;

    out.known = true;
    out.name_len = @min(d.name.len, out.name_buf.len);
    @memcpy(out.name_buf[0..out.name_len], d.name[0..out.name_len]);
    out.room_len = @min(d.room.len, out.room_buf.len);
    @memcpy(out.room_buf[0..out.room_len], d.room[0..out.room_len]);
    out.model_len = @min(d.model.len, out.model_buf.len);
    @memcpy(out.model_buf[0..out.model_len], d.model[0..out.model_len]);
    out.relation_len = @min(d.relation.len, out.relation_buf.len);
    @memcpy(out.relation_buf[0..out.relation_len], d.relation[0..out.relation_len]);
    out.can_set_on = d.can_set_on;
    out.can_set_level = d.can_set_level;
    out.can_set_temperature = d.can_set_temperature;
    out.temperature_min = if (d.color_temperature_min) |a_bound|
        if (d.color_temperature_max) |b_bound| @min(a_bound, b_bound) else a_bound
    else
        null;
    out.temperature_max = if (d.color_temperature_min) |a_bound|
        if (d.color_temperature_max) |b_bound| @max(a_bound, b_bound) else a_bound
    else
        null;
    out.is_on = d.is_on;
    out.light_level = d.light_level;
    out.color_temperature = d.color_temperature;
    out.battery = d.battery;
    out.is_detected = d.is_detected;
    out.illuminance = d.illuminance;
    return out;
}

var hub_name_buf: [64]u8 = undefined;
var hub_name: []const u8 = "DIRIGERA";
var hub_firmware_buf: [32]u8 = undefined;
var hub_firmware: []const u8 = "";

var topic_state_buf: [128]u8 = undefined;
var topic_inventory_buf: [128]u8 = undefined;
var topic_status_buf: [128]u8 = undefined;
var topic_light_buf: [128]u8 = undefined;
var topic_state: []const u8 = "";
var topic_inventory: []const u8 = "";
var topic_status: []const u8 = "";
var topic_light: []const u8 = "";

var authority: []const u8 = "";
var token: []const u8 = "";

// -- subscriber --------------------------------------------------------------------------

/// Queue a command and return. No I/O here: this runs on qnnt's subscriber thread.
fn onLight(topic: []const u8, frame: tld.Frame, context: ?*anyopaque) void {
    _ = topic;
    _ = context;
    const cmd = tld.unpack(LightCommand, frame, null) catch {
        shared.mutex.lockUncancelable(bridge_io);
        shared.commands_refused += 1;
        shared.mutex.unlock(bridge_io);
        std.debug.print("dirigera-bridge: could not read a light command\n", .{});
        return;
    };
    if (cmd.id.len == 0 or cmd.id.len > 64) {
        shared.mutex.lockUncancelable(bridge_io);
        shared.commands_refused += 1;
        shared.mutex.unlock(bridge_io);
        return;
    }

    shared.mutex.lockUncancelable(bridge_io);
    defer shared.mutex.unlock(bridge_io);

    if (shared.pending_len == max_pending) {
        // Reported rather than silently overwritten: a lost command is a light that did not
        // come on, and the operator should be able to see that it happened.
        shared.pending_dropped += 1;
        return;
    }
    const slot = (shared.pending_head + shared.pending_len) % max_pending;
    shared.pending[slot] = .{
        .id_buf = undefined,
        .id_len = cmd.id.len,
        .on = cmd.on,
        .level = cmd.level,
        .kelvin = cmd.kelvin,
    };
    @memcpy(shared.pending[slot].id_buf[0..cmd.id.len], cmd.id);
    shared.pending_len += 1;
}

fn takePending() ?Pending {
    shared.mutex.lockUncancelable(bridge_io);
    defer shared.mutex.unlock(bridge_io);
    if (shared.pending_len == 0) return null;
    const p = shared.pending[shared.pending_head];
    shared.pending_head = (shared.pending_head + 1) % max_pending;
    shared.pending_len -= 1;
    return p;
}

// -- publishing --------------------------------------------------------------------------

var publish_buf: std.ArrayList(u8) = .empty;
var state_seq: u64 = 0;

fn deviceFrame(d: hub.Device) DeviceFrame {
    return .{
        .id = d.id,
        .type = d.type.slug(),
        .name = d.name,
        .room = d.room,
        .model = d.model,
        .reachable = d.reachable,
        .is_on = d.is_on,
        .light_level = d.light_level,
        .color_temperature = d.color_temperature,
        .battery = d.battery,
        .is_detected = d.is_detected,
        .illuminance = d.illuminance,
        .controllable = d.can_set_on or d.can_set_level or d.can_set_temperature,
        .can_set_on = d.can_set_on,
        .can_set_level = d.can_set_level,
        .can_set_temperature = d.can_set_temperature,
        .relation = d.relation,
        // Sorted here rather than in the consumer, so nobody else has to know that the
        // hub's own min/max arrive the wrong way round.
        .temperature_min = if (d.color_temperature_min) |a_bound|
            if (d.color_temperature_max) |b_bound| @min(a_bound, b_bound) else a_bound
        else
            null,
        .temperature_max = if (d.color_temperature_min) |a_bound|
            if (d.color_temperature_max) |b_bound| @max(a_bound, b_bound) else a_bound
        else
            null,
    };
}

/// Publish one change, merged over what the inventory already knows.
///
/// Fields the event carried win; fields it omitted fall back to the last known value, and
/// identity and capabilities always come from the inventory. `fresh` is false for a device
/// the inventory has never seen -- one paired since the last refresh -- so a consumer can
/// tell "this is everything the hub said" from "this is a change plus context".
fn publishState(event: []const u8, d: hub.Device) !void {
    const known = identityOf(d.id);

    var merged = deviceFrame(d);
    if (known.known) {
        merged.name = known.name();
        merged.room = known.room();
        merged.model = known.model();
        merged.controllable = known.can_set_on or known.can_set_level or
            known.can_set_temperature;
        merged.can_set_on = known.can_set_on;
        merged.can_set_level = known.can_set_level;
        merged.can_set_temperature = known.can_set_temperature;
        merged.temperature_min = known.temperature_min;
        merged.temperature_max = known.temperature_max;
        merged.relation = known.relation();
        // The event carries only what changed, so anything absent keeps its last value
        // rather than being published as null.
        if (merged.is_on == null) merged.is_on = known.is_on;
        if (merged.light_level == null) merged.light_level = known.light_level;
        if (merged.color_temperature == null) merged.color_temperature = known.color_temperature;
        if (merged.battery == null) merged.battery = known.battery;
        if (merged.is_detected == null) merged.is_detected = known.is_detected;
        if (merged.illuminance == null) merged.illuminance = known.illuminance;
    }

    state_seq += 1;
    const out: StateFrame = .{
        .seq = state_seq,
        .t_us = @intCast(qnnt.nowMicros()),
        .event = event,
        .identified = known.known,
        .device = merged,
    };
    try tld.packTo(allocator, &publish_buf, out);
    try qnnt.publish(topic_state, publish_buf.items);
}

fn publishInventory(inv: hub.Inventory) !void {
    var frames = try allocator.alloc(DeviceFrame, inv.devices.len);
    defer allocator.free(frames);
    for (inv.devices, 0..) |d, i| frames[i] = deviceFrame(d);

    const out: InventoryFrame = .{
        .t_us = @intCast(qnnt.nowMicros()),
        .hub = hub_name,
        .count = @intCast(frames.len),
        .devices = frames,
    };
    try tld.packTo(allocator, &publish_buf, out);
    try qnnt.publish(topic_inventory, publish_buf.items);
}

fn publishStatus() !void {
    shared.mutex.lockUncancelable(bridge_io);
    const out: StatusFrame = .{
        .t_us = @intCast(qnnt.nowMicros()),
        .hub = hub_name,
        .firmware = hub_firmware,
        .api_link = shared.api_link,
        .event_link = shared.event_link,
        .devices = shared.device_count,
        .events_received = shared.events_received,
        .events_unparsed = shared.events_unparsed,
        .dropped_fragments = shared.dropped_fragments,
        .commands_sent = shared.commands_sent,
        .commands_failed = shared.commands_failed,
        .commands_refused = shared.commands_refused + shared.pending_dropped,
        .reconnects = shared.reconnects,
    };
    shared.mutex.unlock(bridge_io);

    try tld.packTo(allocator, &publish_buf, out);
    try qnnt.publish(topic_status, publish_buf.items);
}

// -- the hub -----------------------------------------------------------------------------

/// `GET /v1/devices`, parsed. The caller owns the inventory.
fn fetchInventory(client: *https.Client, body: *std.ArrayList(u8)) !hub.Inventory {
    try client.request(authority, "GET", path_devices, token, null, body);
    return hub.parseDevices(allocator, body.items);
}

/// `GET /v1/hub/status` -- the one endpoint that needs no token, so also a cheap liveness
/// check. Fills in the hub's name and firmware for the status topic.
fn fetchHubIdentity(client: *https.Client, body: *std.ArrayList(u8)) void {
    client.request(authority, "GET", path_status, null, null, body) catch return;
    if (jsonStringField(body.items, "customName")) |name| {
        const n = @min(name.len, hub_name_buf.len);
        @memcpy(hub_name_buf[0..n], name[0..n]);
        hub_name = hub_name_buf[0..n];
    }
    if (jsonStringField(body.items, "firmwareVersion")) |version| {
        const n = @min(version.len, hub_firmware_buf.len);
        @memcpy(hub_firmware_buf[0..n], version[0..n]);
        hub_firmware = hub_firmware_buf[0..n];
    }
}

/// One string field out of a flat JSON object. `/v1/hub/status` is two nested objects and
/// nothing more, so this avoids allocating a parse tree for it.
fn jsonStringField(json: []const u8, key: []const u8) ?[]const u8 {
    var quoted: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&quoted, "\"{s}\":\"", .{key}) catch return null;
    const at = std.mem.indexOf(u8, json, needle) orelse return null;
    const start = at + needle.len;
    const end = std.mem.indexOfScalarPos(u8, json, start, '"') orelse return null;
    return json[start..end];
}

/// Send one queued command. The device is looked up in the inventory so the hub's own
/// `canReceive` decides what is sent -- see hub.lightCommand.
fn sendCommand(client: *https.Client, inv: hub.Inventory, p: Pending, body: *std.ArrayList(u8)) void {
    const device = inv.find(p.id()) orelse {
        shared.mutex.lockUncancelable(bridge_io);
        shared.commands_refused += 1;
        shared.mutex.unlock(bridge_io);
        std.debug.print(
            "dirigera-bridge: no device '{s}' -- run --list for the ids\n",
            .{p.id()},
        );
        return;
    };

    var cmd_buf: [256]u8 = undefined;
    const payload = hub.lightCommand(&cmd_buf, device, p.on, p.level, p.kelvin) catch {
        shared.mutex.lockUncancelable(bridge_io);
        shared.commands_refused += 1;
        shared.mutex.unlock(bridge_io);
        std.debug.print(
            "dirigera-bridge: '{s}' ({s}) accepts none of those attributes\n",
            .{ device.name, device.type.slug() },
        );
        return;
    };

    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ path_devices, device.id }) catch return;

    if (client.request(authority, "PATCH", path, token, payload, body)) |_| {
        shared.mutex.lockUncancelable(bridge_io);
        shared.commands_sent += 1;
        shared.api_link = true;
        shared.mutex.unlock(bridge_io);
    } else |err| {
        shared.mutex.lockUncancelable(bridge_io);
        shared.commands_failed += 1;
        shared.api_link = false;
        shared.mutex.unlock(bridge_io);
        std.debug.print("dirigera-bridge: command failed ({t})\n", .{err});
    }
}

// -- the event stream --------------------------------------------------------------------

/// Hold the WebSocket and publish what arrives. Its own thread, because the read blocks
/// until the hub has something to say -- which is the whole point.
fn eventLoop() void {
    var client = https.Client.init(bridge_io, allocator) catch |err| {
        std.debug.print("dirigera-bridge: no trust bundle ({t})\n", .{err});
        return;
    };
    defer client.deinit();

    const frame_buf = allocator.alloc(u8, 256 * 1024) catch return;
    defer allocator.free(frame_buf);

    while (!qnnt.stopRequested()) {
        // A long read timeout, not the REST one: an idle event stream is normal -- nothing
        // in the house is changing -- so a short deadline would reconnect constantly. If
        // this does fire, reconnecting is harmless.
        const connection = client.connect(authority, 300_000) catch |err| {
            markEventLink(false);
            std.debug.print("dirigera-bridge: event stream connect failed ({t})\n", .{err});
            _ = qnnt.sleepMs(3000);
            continue;
        };
        defer connection.close();

        var seed: [32]u8 = undefined;
        bridge_io.random(&seed);
        var masker: ws.Masker = .init(seed);

        var key_entropy: [16]u8 = undefined;
        bridge_io.random(&key_entropy);

        ws.handshake(
            connection.reader(),
            connection.writer(),
            authority,
            path_events,
            token,
            &key_entropy,
        ) catch |err| {
            markEventLink(false);
            std.debug.print("dirigera-bridge: event handshake failed ({t})\n", .{err});
            _ = qnnt.sleepMs(3000);
            continue;
        };

        markEventLink(true);
        std.debug.print("dirigera-bridge: event stream up\n", .{});

        var dropped: u64 = 0;
        while (!qnnt.stopRequested()) {
            const frame = ws.readFrame(
                connection.reader(),
                connection.writer(),
                &masker,
                frame_buf,
                &dropped,
            ) catch |err| {
                std.debug.print("dirigera-bridge: event stream ended ({t})\n", .{err});
                break;
            } orelse break; // the hub closed
            handleEvent(frame.payload, dropped);
        }

        markEventLink(false);
        shared.mutex.lockUncancelable(bridge_io);
        shared.reconnects += 1;
        shared.mutex.unlock(bridge_io);
        _ = qnnt.sleepMs(1000);
    }
}

fn markEventLink(up: bool) void {
    shared.mutex.lockUncancelable(bridge_io);
    shared.event_link = up;
    shared.mutex.unlock(bridge_io);
}

/// One pushed event.
///
/// The envelope is `{"type": ..., "data": {...}}` where `data` has the shape of one entry of
/// `/v1/devices`, so the same parser handles both -- which is the reason `hub.parseDevices`
/// takes a list and this wraps a single object into one. An event whose `data` cannot be
/// read is counted rather than discarded quietly: a firmware that changes this shape should
/// show up as a rising number on the status topic, not as a bridge that has gone mute.
fn handleEvent(payload: []const u8, dropped: u64) void {
    shared.mutex.lockUncancelable(bridge_io);
    shared.events_received += 1;
    shared.dropped_fragments = dropped;
    shared.mutex.unlock(bridge_io);

    const event_type = jsonStringField(payload, "type") orelse "unknown";

    // `data` is one device object; parseDevices wants an array, so bracket it.
    const data_at = std.mem.indexOf(u8, payload, "\"data\":") orelse return countUnparsed();
    const object = payload[data_at + 7 ..];
    const wrapped = std.fmt.allocPrint(allocator, "[{s}]", .{trimTrailingBrace(object)}) catch
        return countUnparsed();
    defer allocator.free(wrapped);

    var inv = hub.parseDevices(allocator, wrapped) catch return countUnparsed();
    defer inv.deinit();
    if (inv.devices.len == 0) return countUnparsed();

    publishState(event_type, inv.devices[0]) catch {};
}

fn countUnparsed() void {
    shared.mutex.lockUncancelable(bridge_io);
    shared.events_unparsed += 1;
    shared.mutex.unlock(bridge_io);
}

/// The envelope closes with a `}` after `data`'s own object. Balance braces to find where
/// `data` ends rather than assuming it is last in the envelope.
fn trimTrailingBrace(text: []const u8) []const u8 {
    var depth: i32 = 0;
    var in_string = false;
    var escaped = false;
    for (text, 0..) |ch, i| {
        if (escaped) {
            escaped = false;
            continue;
        }
        switch (ch) {
            '\\' => escaped = true,
            '"' => in_string = !in_string,
            '{' => if (!in_string) {
                depth += 1;
            },
            '}' => if (!in_string) {
                depth -= 1;
                if (depth == 0) return text[0 .. i + 1];
            },
            else => {},
        }
    }
    return text;
}

// -- setup -------------------------------------------------------------------------------

fn usage() void {
    std.debug.print(
        \\usage: dirigera-bridge --host <ip:port> [options]
        \\
        \\  --host <ip:port>  the hub's API, e.g. 192.168.1.20:8443 (required)
        \\  --token <path>    file holding the bearer token (default ./dirigera_token,
        \\                    or the DIRIGERA_TOKEN environment variable)
        \\  --topic <prefix>  topic prefix (default home/dirigera)
        \\  --list            print the devices and their ids, then exit
        \\
        \\--host is required rather than defaulted because a hub's address moves. Find it
        \\the way the hub advertises it:
        \\
        \\  dns-sd -B _ihsp._tcp local
        \\  dns-sd -L <instance> _ihsp._tcp local   # TXT carries ipv4address
        \\
        \\The token comes from pressing the hub's action button during an OAuth PKCE
        \\exchange; it is never printed by this program.
        \\
        \\State is PUSHED by the hub over a WebSocket, so this does not poll. The inventory
        \\is refetched on a timer only so that a late subscriber sees every device rather
        \\than just the ones that have changed since it attached.
        \\
    , .{});
}

/// Read the token, from `--token`, then `DIRIGERA_TOKEN`, then the default path.
fn loadToken(path: []const u8) ![]const u8 {
    // std.c.getenv rather than std.posix.getenv, which 0.16 does not have -- the same
    // call lib/env.zig makes for the QNNT_* variables.
    if (std.c.getenv("DIRIGERA_TOKEN")) |from_env| {
        const text = std.mem.span(from_env);
        if (text.len > 0) return try allocator.dupe(u8, text);
    }
    const contents = try std.Io.Dir.cwd().readFileAlloc(
        bridge_io,
        path,
        allocator,
        .limited(8192),
    );
    return std.mem.trim(u8, contents, " \t\r\n");
}

pub fn main(init: std.process.Init.Minimal) !void {
    // Before anything else: everything below needs an `Io`, and the library's is not
    // available until `qnnt.run()` -- which `--list` never calls.
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    bridge_io = threaded.io();

    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();

    var prefix: []const u8 = "home/dirigera";
    var token_path: []const u8 = "dirigera_token";
    var list_only = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--host")) {
            authority = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--token")) {
            token_path = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--topic")) {
            prefix = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--list")) {
            list_only = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return usage();
        } else {
            std.debug.print("dirigera-bridge: unknown option '{s}'\n", .{arg});
            return usage();
        }
    }

    if (authority.len == 0) {
        std.debug.print("dirigera-bridge: --host is required\n\n", .{});
        return usage();
    }

    token = loadToken(token_path) catch |err| {
        std.debug.print(
            "dirigera-bridge: could not read the token from '{s}' ({t}). Pair with the hub " ++
                "first, or set DIRIGERA_TOKEN.\n",
            .{ token_path, err },
        );
        return;
    };
    if (token.len == 0) {
        std.debug.print("dirigera-bridge: the token is empty\n", .{});
        return;
    }

    topic_state = try std.fmt.bufPrint(&topic_state_buf, "{s}/state", .{prefix});
    topic_inventory = try std.fmt.bufPrint(&topic_inventory_buf, "{s}/inventory", .{prefix});
    topic_status = try std.fmt.bufPrint(&topic_status_buf, "{s}/status", .{prefix});
    topic_light = try std.fmt.bufPrint(&topic_light_buf, "{s}/light", .{prefix});

    // -- the diagnostic path: talk to the hub, print, exit ------------------------
    if (list_only) {
        var client = try https.Client.init(bridge_io, allocator);
        defer client.deinit();
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(allocator);

        fetchHubIdentity(&client, &body);
        var inv = fetchInventory(&client, &body) catch |err| {
            std.debug.print("dirigera-bridge: {s} did not answer ({t})\n", .{ authority, err });
            return;
        };
        defer inv.deinit();

        std.debug.print("{s} (firmware {s}) -- {d} devices\n\n", .{
            hub_name, hub_firmware, inv.devices.len,
        });
        for (inv.devices) |d| {
            std.debug.print("  {s:<18} {s:<26} {s:<14} {s} {s}\n", .{
                d.type.slug(),
                if (d.name.len > 0) d.name else "(unnamed)",
                if (d.room.len > 0) d.room else "-",
                if (d.reachable) "  " else "!!",
                d.id,
            });
        }
        return;
    }

    // -- the bridge ---------------------------------------------------------------
    qnnt.configureFromEnvironment();
    if (!qnnt.run()) {
        std.debug.print("dirigera-bridge: could not start the qnnt node\n", .{});
        return;
    }
    defer qnnt.deinit();
    qnnt.installSignalHandlers();

    var client = try https.Client.init(bridge_io, allocator);
    defer client.deinit();
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);

    fetchHubIdentity(&client, &body);

    if (!qnnt.runPublisher(topic_state, null, null, null) or
        !qnnt.runPublisher(topic_inventory, null, null, null) or
        !qnnt.runPublisher(topic_status, null, null, null))
    {
        std.debug.print("dirigera-bridge: could not register the published topics\n", .{});
        return;
    }
    // Frame delivery, because commands are TLD objects. A text subscription would wait for
    // a newline that binary TLD never contains, and the handler would never run -- the bug
    // that cost an afternoon on the UGV bridge.
    if (!qnnt.subscribeFrames(topic_light, onLight, null)) {
        std.debug.print("dirigera-bridge: could not subscribe to {s}\n", .{topic_light});
        return;
    }

    std.debug.print(
        \\dirigera-bridge: {s} (firmware {s}) at {s}
        \\  pushed state  {s}
        \\  inventory     {s}
        \\  status        {s}
        \\  commands      {s}
        \\
    , .{ hub_name, hub_firmware, authority, topic_state, topic_inventory, topic_status, topic_light });

    const events = try std.Thread.spawn(.{}, eventLoop, .{});

    // The supervisor: inventory on a timer, status on a timer, and the command queue.
    // Never a poll for state -- that arrives on its own.
    defer if (inventory) |*inv| inv.deinit();

    var last_inventory_us: i64 = 0;
    var last_status_us: i64 = 0;

    while (!qnnt.stopRequested()) {
        const now = qnnt.nowMicros();

        if (now -| last_inventory_us >= 30_000_000) {
            last_inventory_us = now;
            if (fetchInventory(&client, &body)) |fresh| {
                // Swapped under the lock: the event thread reads this to identify a
                // device, and its strings point into the parse being freed.
                inventory_mutex.lockUncancelable(bridge_io);
                if (inventory) |*old| old.deinit();
                inventory = fresh;
                inventory_mutex.unlock(bridge_io);

                shared.mutex.lockUncancelable(bridge_io);
                shared.api_link = true;
                shared.device_count = @intCast(fresh.devices.len);
                shared.mutex.unlock(bridge_io);
                publishInventory(fresh) catch {};
            } else |err| {
                shared.mutex.lockUncancelable(bridge_io);
                shared.api_link = false;
                shared.mutex.unlock(bridge_io);
                std.debug.print("dirigera-bridge: inventory refresh failed ({t})\n", .{err});
            }
        }

        // Commands need the inventory to know what each device accepts, so they wait for
        // the first fetch rather than being sent blind.
        // Under the lock, because the subscriber thread writes it.
        shared.mutex.lockUncancelable(bridge_io);
        const waiting = shared.pending_len;
        shared.mutex.unlock(bridge_io);

        if (waiting > 0) {
            inventory_mutex.lockUncancelable(bridge_io);
            const snapshot = inventory;
            inventory_mutex.unlock(bridge_io);
            if (snapshot) |inv| {
                while (takePending()) |p| sendCommand(&client, inv, p, &body);
            }
        }

        if (now -| last_status_us >= 1_000_000) {
            last_status_us = now;
            publishStatus() catch {};
        }

        _ = qnnt.sleepMs(50);
    }

    events.join();
    publish_buf.deinit(allocator);
    std.debug.print("dirigera-bridge: stopped\n", .{});
}
