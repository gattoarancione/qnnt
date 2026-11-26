//! The bridge: an IKEA DIRIGERA hub on one side, qnnt topics on the other.
//!
//!   ./zig-out/bin/dirigera-bridge --host 192.168.1.20:8443 --pair    # once, ever
//!   ./zig-out/bin/dirigera-bridge --host 192.168.1.20:8443 --token ./dirigera_token
//!
//!   dirigera-bridge --host <ip:port> [--token path] [--topic prefix] [--list] [--pair]
//!
//! Find the hub without guessing, because its address moves:
//!
//!   dns-sd -B _ihsp._tcp local            # the hub announces itself
//!   dns-sd -L <instance> _ihsp._tcp local # TXT record carries ipv4address and version
//!
//! Five topics:
//!
//!   home/dirigera/state       published   one frame per device, when it changes
//!   home/dirigera/inventory   published   every device, on a timer
//!   home/dirigera/status      published   the link, the hub, the counters, pairing
//!   home/dirigera/light       subscribed  {id, on?, level?, kelvin?}
//!   home/dirigera/pair        subscribed  {name, cancel} -- start or stop pairing
//!
//! PAIRING IS PART OF THE BRIDGE, not a step you do elsewhere first. Everything above needs
//! a bearer token, and the only way to get one is an OAuth PKCE exchange finished by
//! pressing the hub's physical button. This program used to read that token from a file and
//! exit if it was missing, which left the procedure living in a script outside the tree --
//! so the example could not actually be run from a clean checkout.
//!
//! Now a bridge with no token still starts. Its topics come up, its status says
//! `paired: false`, and it waits for a request on the pair topic; `--pair` does the same
//! thing on the terminal. The exchange itself is in pair.zig, driven through callbacks so
//! that its whole state machine is tested offline -- see the tests there. The bridge
//! supplies the four things it cannot: TLS, a clock, a sleep, and entropy.
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
const told = qnnt_mod.Told;
const https = @import("https");
const hub = @import("hub");
const ws = @import("ws");
const frames = @import("frames");
const pair = @import("pair");

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

// The topic payload types live in frames.zig, which is also where the golden frames that
// hold them in step with the C++ station's definitions are checked. They were here; moving
// them out is what let them be tested at all.
const DeviceFrame = frames.DeviceFrame;
const StateFrame = frames.StateFrame;
const InventoryFrame = frames.InventoryFrame;
const StatusFrame = frames.StatusFrame;
const LightCommand = frames.LightCommand;

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

    /// A bearer token is in hand. Everything the bridge does beyond `GET /v1/hub/status`
    /// waits on this.
    paired: bool = false,
    /// A pairing exchange is running on its own thread.
    pairing: bool = false,
    /// Set to abandon that exchange.
    pair_cancel: bool = false,
    /// The last thing the exchange said, for whoever is standing at the hub.
    pair_detail_buf: [192]u8 = undefined,
    pair_detail_len: usize = 0,
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
var topic_pair_buf: [128]u8 = undefined;
var topic_state: []const u8 = "";
var topic_inventory: []const u8 = "";
var topic_status: []const u8 = "";
var topic_light: []const u8 = "";
var topic_pair: []const u8 = "";

var authority: []const u8 = "";
var token: []const u8 = "";

// -- subscriber --------------------------------------------------------------------------

/// Queue a command and return. No I/O here: this runs on qnnt's subscriber thread.
fn onLight(topic: []const u8, frame: told.Frame, context: ?*anyopaque) void {
    _ = topic;
    _ = context;
    const cmd = told.unpack(LightCommand, frame, null) catch {
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
    try told.packTo(allocator, &publish_buf, out);
    try qnnt.publish(topic_state, publish_buf.items);
}

fn publishInventory(inv: hub.Inventory) !void {
    const rows = try allocator.alloc(DeviceFrame, inv.devices.len);
    defer allocator.free(rows);
    for (inv.devices, 0..) |d, i| rows[i] = deviceFrame(d);

    const out: InventoryFrame = .{
        .t_us = @intCast(qnnt.nowMicros()),
        .hub = hub_name,
        .count = @intCast(rows.len),
        .devices = rows,
    };
    try told.packTo(allocator, &publish_buf, out);
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
        .paired = shared.paired,
        .pairing = shared.pairing,
        .pair_detail = shared.pair_detail_buf[0..shared.pair_detail_len],
    };
    shared.mutex.unlock(bridge_io);

    try told.packTo(allocator, &publish_buf, out);
    try qnnt.publish(topic_status, publish_buf.items);
}

// -- pairing -----------------------------------------------------------------------------
//
// The exchange lives in pair.zig, which knows nothing about TLS, qnnt or this program. What
// is here is the wiring: the four callbacks it needs from a real runtime, the thread it runs
// on, and writing the token out at the end.
//
// It runs on its own thread because it blocks for as long as it takes someone to walk to the
// hub and press a button -- up to ten minutes. The supervisor keeps publishing status
// throughout, which is the whole point: the GUI shows the progress below while it waits.

/// Where the token is written once the hub grants it.
var pair_token_path: []const u8 = "dirigera_token";
/// The name the hub will list this client under, from the pairing request.
var pair_client_name_buf: [64]u8 = undefined;
var pair_client_name_len: usize = 0;

fn pairRequest(
    context: ?*anyopaque,
    method: []const u8,
    path: []const u8,
    content_type: []const u8,
    body: ?[]const u8,
    out: *std.ArrayList(u8),
) anyerror!u16 {
    const client: *https.Client = @ptrCast(@alignCast(context.?));
    // No token: this exchange is how one is obtained.
    return client.requestTyped(authority, method, path, null, content_type, body, out);
}

// `bridge_io`, NOT the library's `io` by way of `qnnt.sleepMs`/`qnnt.nowMicros`.
//
// `--pair` runs before `qnnt.run()` and never starts a node at all, so the library's `io` is
// still undefined there -- reaching for it segfaults on the first call. That is the hazard
// this file's own header warns about for `--list` and the token read; pairing is the third
// thing that happens outside a running node, and it walked straight into it against a real
// hub. `bridge_io` is valid from the first line of `main`, so it is correct in both paths:
// the terminal one and the one driven from the GUI after the node is up.
fn pairSleep(ms: u64, context: ?*anyopaque) void {
    _ = context;
    bridge_io.sleep(.fromMilliseconds(@intCast(ms)), .awake) catch {};
}

/// Elapsed rather than wall-clock time: these are deadlines for how long to keep offering
/// the operator a chance to press the button, and a clock adjustment must not extend or cut
/// short the window.
fn pairNow(context: ?*anyopaque) i64 {
    _ = context;
    return @divTrunc(std.Io.Timestamp.now(bridge_io, .awake).toMicroseconds(), 1000);
}

fn pairEntropy(buffer: []u8, context: ?*anyopaque) void {
    _ = context;
    bridge_io.random(buffer);
}

/// Progress goes two places: the terminal, for `--pair`, and the status topic, for the GUI.
fn pairProgress(message: []const u8, context: ?*anyopaque) void {
    _ = context;
    std.debug.print("dirigera-bridge: pairing -- {s}\n", .{message});

    shared.mutex.lockUncancelable(bridge_io);
    defer shared.mutex.unlock(bridge_io);
    shared.pair_detail_len = @min(message.len, shared.pair_detail_buf.len);
    @memcpy(shared.pair_detail_buf[0..shared.pair_detail_len], message[0..shared.pair_detail_len]);
}

fn pairShouldStop(context: ?*anyopaque) bool {
    _ = context;
    if (qnnt.stopRequested()) return true;
    shared.mutex.lockUncancelable(bridge_io);
    defer shared.mutex.unlock(bridge_io);
    return shared.pair_cancel;
}

fn isPaired() bool {
    shared.mutex.lockUncancelable(bridge_io);
    defer shared.mutex.unlock(bridge_io);
    return shared.paired;
}

/// Record what the exchange ended as, for the status topic.
fn pairFinished(detail: []const u8, paired: bool) void {
    shared.mutex.lockUncancelable(bridge_io);
    defer shared.mutex.unlock(bridge_io);
    shared.pairing = false;
    shared.pair_cancel = false;
    if (paired) shared.paired = true;
    shared.pair_detail_len = @min(detail.len, shared.pair_detail_buf.len);
    @memcpy(shared.pair_detail_buf[0..shared.pair_detail_len], detail[0..shared.pair_detail_len]);
}

/// The whole exchange, including writing the token out. Returns true when paired.
///
/// Its own HTTPS client rather than the supervisor's: this runs for minutes on another
/// thread, and the supervisor is meanwhile using its client for the inventory.
fn runPairing() bool {
    var client = https.Client.init(bridge_io, allocator) catch {
        pairFinished("could not start a TLS client", false);
        return false;
    };
    defer client.deinit();

    var fresh: std.ArrayList(u8) = .empty;
    defer fresh.deinit(allocator);

    const name = if (pair_client_name_len > 0)
        pair_client_name_buf[0..pair_client_name_len]
    else
        "qnnt-bridge";

    const host: pair.Host = .{
        .request = pairRequest,
        .sleep = pairSleep,
        .now_ms = pairNow,
        .entropy = pairEntropy,
        .context = &client,
    };

    pair.run(
        host,
        &fresh,
        allocator,
        .{ .client_name = name },
        pairProgress,
        pairShouldStop,
    ) catch |err| {
        const detail = switch (err) {
            error.TimedOut => "nobody pressed the hub's button -- pairing gave up",
            error.Cancelled => "pairing cancelled",
            error.OutOfMemory => "out of memory",
        };
        pairFinished(detail, false);
        return false;
    };

    // Owner-only: this is a bearer token for someone's house, and the default 0o666 would
    // leave it readable by every account on the machine.
    std.Io.Dir.cwd().writeFile(bridge_io, .{
        .sub_path = pair_token_path,
        .data = fresh.items,
        .flags = .{ .permissions = @enumFromInt(0o600) },
    }) catch |err| {
        std.debug.print(
            "dirigera-bridge: paired, but could not write the token to '{s}' ({t})\n",
            .{ pair_token_path, err },
        );
        pairFinished("paired, but the token could not be saved", false);
        return false;
    };

    // Adopted in memory too, so a bridge that paired at runtime starts working without
    // being restarted.
    token = allocator.dupe(u8, fresh.items) catch {
        pairFinished("paired, but the token could not be held", false);
        return false;
    };
    std.debug.print(
        "dirigera-bridge: paired -- token written to {s}\n",
        .{pair_token_path},
    );
    pairFinished("paired", true);
    return true;
}

/// The thread body for a pairing asked for over the topic.
fn pairingThread() void {
    _ = runPairing();
}

/// A pairing request from a controller. Starts the exchange, or cancels one.
fn onPair(topic: []const u8, frame: told.Frame, context: ?*anyopaque) void {
    _ = topic;
    _ = context;
    const request = told.unpack(frames.PairRequest, frame, null) catch return;

    if (request.cancel) {
        shared.mutex.lockUncancelable(bridge_io);
        shared.pair_cancel = true;
        shared.mutex.unlock(bridge_io);
        return;
    }

    shared.mutex.lockUncancelable(bridge_io);
    const busy = shared.pairing or shared.paired;
    if (!busy) {
        shared.pairing = true;
        shared.pair_cancel = false;
        pair_client_name_len = @min(request.name.len, pair_client_name_buf.len);
        @memcpy(pair_client_name_buf[0..pair_client_name_len], request.name[0..pair_client_name_len]);
    }
    shared.mutex.unlock(bridge_io);
    if (busy) return;

    // Detached: nothing waits for it, and it must not run on the subscriber thread -- it
    // blocks for minutes.
    const thread = std.Thread.spawn(.{}, pairingThread, .{}) catch {
        pairFinished("could not start the pairing thread", false);
        return;
    };
    thread.detach();
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
        // Nothing to subscribe to without a token, and the hub answers an unauthenticated
        // upgrade with 401. An unpaired bridge waits here rather than reconnecting in a
        // loop against a door it cannot open.
        if (!isPaired()) {
            _ = qnnt.sleepMs(500);
            continue;
        }

        // Connected with a long read timeout for the handshake, then dropped to a short one
        // for the stream itself -- see below. An idle event stream is normal (nothing in the
        // house is changing), so the LENGTH of the idle period this tolerates has not
        // changed; only the size of each individual wait has.
        const connection = client.connect(authority, event_connect_timeout_ms) catch |err| {
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

        // NOW the short timeout. A house can be quiet for hours, and this loop must
        // tolerate that -- but it must not spend one uninterruptible five-minute read doing
        // it, because that is five minutes of ignoring a shutdown. So the same total
        // patience is spent in short waits, and a wait that expires is not an error: it is
        // "nothing happened yet", and the only question it raises is whether we have been
        // asked to stop.
        //
        // This needs `timedOut()` to tell an expired wait from a broken connection; without
        // it the two are the same error and a short timeout would reconnect on every quiet
        // moment. See tls_openssl.Reader.timed_out.
        connection.setReadTimeout(event_read_slice_ms);

        var dropped: u64 = 0;
        var idle_ms: u64 = 0;
        while (!qnnt.stopRequested()) {
            // `readFrame` CONSUMES as it goes: it takes the two header bytes, then the
            // payload. So a timeout that lands between the two leaves the header gone, and
            // simply calling it again would read payload bytes as a header and desynchronise
            // the stream silently -- which is worse than the slow shutdown this is fixing.
            //
            // The reader's seek position says which happened. Unchanged means the frame was
            // never started and the next attempt begins at the same boundary; moved means a
            // frame was half-consumed, and the only safe answer is a new connection.
            const seek_before = connection.reader().seek;

            const frame = ws.readFrame(
                connection.reader(),
                connection.writer(),
                &masker,
                frame_buf,
                &dropped,
            ) catch |err| {
                const timed_out = connection.timedOut();
                const untouched = connection.reader().seek == seek_before;

                if (timed_out and untouched) {
                    idle_ms += event_read_slice_ms;
                    // Silence for this long is a stream that has gone away without saying
                    // so -- a hub that rebooted, or a route that changed. Reconnecting is
                    // harmless and is how it comes back.
                    if (idle_ms >= event_idle_limit_ms) {
                        std.debug.print(
                            "dirigera-bridge: no events for {d}s, reconnecting\n",
                            .{event_idle_limit_ms / 1000},
                        );
                        break;
                    }
                    continue;
                }
                if (timed_out) {
                    std.debug.print(
                        "dirigera-bridge: event stream timed out mid-frame, reconnecting\n",
                        .{},
                    );
                } else {
                    std.debug.print("dirigera-bridge: event stream ended ({t})\n", .{err});
                }
                break;
            } orelse break; // the hub closed
            idle_ms = 0;
            handleEvent(frame.payload, dropped);
        }

        markEventLink(false);
        shared.mutex.lockUncancelable(bridge_io);
        shared.reconnects += 1;
        shared.mutex.unlock(bridge_io);
        _ = qnnt.sleepMs(1000);
    }
}

/// The handshake's read timeout. Generous, because it is one exchange and a slow hub is
/// not a broken one.
const event_connect_timeout_ms: u32 = 15_000;

/// One wait on the event stream. Short, so a shutdown is noticed within one of them.
const event_read_slice_ms: u32 = 1000;

/// Total silence tolerated before reconnecting, unchanged from the five minutes this loop
/// always allowed -- now spent as 300 waits of a second rather than one wait of five
/// minutes.
const event_idle_limit_ms: u64 = 300_000;

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
        \\  --pair            pair with the hub, write the token, then exit
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
        \\  dirigera-bridge --host <ip:port> --pair
        \\
        \\...then press the action button on the underside of the hub. The token is written
        \\to --token, owner-readable only. Pairing can also be driven from the GUI: started
        \\without a token this bridge comes up unpaired, publishes that on its status topic,
        \\and waits for a request on <prefix>/pair.
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
    var pair_only = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--host")) {
            authority = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--token")) {
            token_path = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--topic")) {
            prefix = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--list")) {
            list_only = true;
        } else if (std.mem.eql(u8, arg, "--pair")) {
            pair_only = true;
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

    pair_token_path = token_path;

    // A missing token is no longer a reason to exit. It used to be, and that left the
    // pairing procedure outside the program entirely -- a scratchpad script you had to
    // have kept. Unpaired, the bridge still starts, still publishes status saying so, and
    // waits for a pairing request; the GUI's panel is built on exactly that.
    token = loadToken(token_path) catch "";
    shared.paired = token.len > 0;
    if (!shared.paired) {
        std.debug.print(
            "dirigera-bridge: no token in '{s}' -- starting UNPAIRED. Run with --pair, or " ++
                "send a request on the pair topic (the GUI has a panel for it).\n",
            .{token_path},
        );
    }

    topic_state = try std.fmt.bufPrint(&topic_state_buf, "{s}/state", .{prefix});
    topic_inventory = try std.fmt.bufPrint(&topic_inventory_buf, "{s}/inventory", .{prefix});
    topic_status = try std.fmt.bufPrint(&topic_status_buf, "{s}/status", .{prefix});
    topic_light = try std.fmt.bufPrint(&topic_light_buf, "{s}/light", .{prefix});
    topic_pair = try std.fmt.bufPrint(&topic_pair_buf, "{s}/pair", .{prefix});

    // -- pairing on the terminal: no qnnt node, no topics --------------------------
    //
    // Before `--list`, because `--list` cannot work without a token and the natural order
    // of a first run is pair, then look.
    if (pair_only) {
        if (shared.paired) {
            std.debug.print(
                "dirigera-bridge: already paired -- '{s}' holds a token. Delete it to pair " ++
                    "again.\n",
                .{token_path},
            );
            return;
        }
        std.debug.print(
            "dirigera-bridge: pairing with {s}\n" ++
                "  press the action button on the underside of the hub\n",
            .{authority},
        );
        if (!runPairing()) return;
        return;
    }

    // -- the diagnostic path: talk to the hub, print, exit ------------------------
    if (list_only) {
        if (!shared.paired) {
            std.debug.print(
                "dirigera-bridge: --list needs a token. Pair first: --pair\n",
                .{},
            );
            return;
        }
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
    // Frame delivery, because commands are TOLD objects. A text subscription would wait for
    // a newline that binary TOLD never contains, and the handler would never run -- the bug
    // that cost an afternoon on the UGV bridge.
    if (!qnnt.subscribeFrames(topic_light, onLight, null)) {
        std.debug.print("dirigera-bridge: could not subscribe to {s}\n", .{topic_light});
        return;
    }
    // Subscribed even when already paired, so the topic exists either way: a controller
    // that attaches to a missing topic waits for ever rather than being told no.
    if (!qnnt.subscribeFrames(topic_pair, onPair, null)) {
        std.debug.print("dirigera-bridge: could not subscribe to {s}\n", .{topic_pair});
        return;
    }

    std.debug.print(
        \\dirigera-bridge: {s} (firmware {s}) at {s}{s}
        \\  pushed state  {s}
        \\  inventory     {s}
        \\  status        {s}
        \\  commands      {s}
        \\  pairing       {s}
        \\
    , .{
        hub_name,
        hub_firmware,
        authority,
        if (shared.paired) "" else "  -- UNPAIRED",
        topic_state,
        topic_inventory,
        topic_status,
        topic_light,
        topic_pair,
    });

    const events = try std.Thread.spawn(.{}, eventLoop, .{});

    // The supervisor: inventory on a timer, status on a timer, and the command queue.
    // Never a poll for state -- that arrives on its own.
    defer if (inventory) |*inv| inv.deinit();

    var last_inventory_us: i64 = 0;
    var last_status_us: i64 = 0;

    while (!qnnt.stopRequested()) {
        const now = qnnt.nowMicros();

        // Every call below needs the token. Unpaired, the loop does nothing but keep
        // publishing status -- which is how the GUI's pairing panel learns what is
        // happening while someone walks to the hub.
        if (now -| last_inventory_us >= 30_000_000 and isPaired()) {
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
