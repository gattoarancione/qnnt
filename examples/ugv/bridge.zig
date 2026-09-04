//! The bridge: a UGV Beast on one side, qnnt topics on the other.
//!
//!   ./zig-out/bin/ugv-bridge --host 192.168.50.5:5000     # terminal 1
//!   ./zig-out/bin/ugv-pilot                               # terminal 2, the GUI
//!
//!   ugv-bridge [--host addr:port] [--topic prefix] [--rate hz] [--deadman ms]
//!
//! Four topics:
//!
//!   ugv/<name>/drive       subscribed   {left, right} in [-1, 1]
//!   ugv/<name>/gimbal      subscribed   {pan, tilt} degrees, absolute
//!   ugv/<name>/telemetry   published    battery, angles, CPU, at whatever rate it arrives
//!   ugv/<name>/status      published    the link, the robot's limits, the watchdog
//!
//! This bridge drives real actuators, so its shape is decided by that rather than by
//! convenience:
//!
//! **The output is a fixed-rate loop, not a per-message send.** A subscriber callback
//! stores the newest setpoint and returns; the loop sends whatever is current at `--rate`.
//! Velocity commands supersede rather than queue -- a stale command is worthless and
//! executing a backlog of them is dangerous -- so coalescing is the correct behaviour, not
//! a shortcut. It also keeps HTTP latency out of the qnnt subscriber thread.
//!
//! **The loop is also the heartbeat.** The vendor's own web UI re-sends its current drive
//! command every 2000 ms (`setInterval(heartbeat_send, 2000)`), which says the firmware
//! stops the tracks if commands stop arriving. So there are two independent stops:
//!
//!   1. This bridge's watchdog. If no drive command arrives for `--deadman` ms the setpoint
//!      is forced to zero and the loop keeps sending that zero. Default 500 ms.
//!   2. The robot's own timeout, if the bridge itself dies and nothing is sent at all.
//!
//! (1) exists because (2) is slower and outside our control. A controller that crashes
//! mid-turn, a Wi-Fi drop, a GUI that freezes -- all of them leave a robot driving until
//! something stops it, and 500 ms of unintended motion is a very different event from three
//! seconds of it. Neither is a substitute for the other.
//!
//! **The robot's own limits are the limits.** `max_speed` and the command numbers come from
//! `GET /config` -- the robot's live configuration -- not from constants here. Drive inputs
//! are a fraction of full scale in [-1, 1] and get scaled by that. If `/config` cannot be
//! read the bridge falls back to compiled-in defaults and says so on the status topic, both
//! because the operator should know and because the GUI scales its controls from it.

const std = @import("std");
const qnnt_mod = @import("qnnt");
const qnnt = qnnt_mod.Qnnt;
const tld = qnnt_mod.Tld;
const sio = @import("sio");
const beast = @import("beast");

const allocator = std.heap.page_allocator;

/// The robot's command namespace, and the one it pushes telemetry on. Both ride the same
/// Engine.IO session, which is what Socket.IO namespaces are for.
const ns_json = "/json";
const ns_ctrl = "/ctrl";

// -- the wire types ---------------------------------------------------------------------

/// What a controller sends. A fraction of full scale rather than a speed, because the
/// robot's ceiling is the robot's to state -- see `Status.max_speed`.
const Drive = struct {
    left: f32,
    right: f32,
};

/// An absolute pan-tilt target. Absolute rather than a rate, because that is the command
/// the robot actually implements (`T:133` takes an angle) and because a rate command with a
/// dropped stop keeps moving.
const Gimbal = struct {
    pan: f32,
    tilt: f32,
    speed: u16 = 0,
    accel: u16 = 0,
};

const TelemetryFrame = struct {
    seq: u64,
    t_us: u64,
    /// Battery volts.
    voltage: f32,
    pan_deg: f32,
    tilt_deg: f32,
    cpu_load: f32,
    cpu_temp_c: f32,
    ram_usage: f32,
    video_fps: f32,
    wifi_rssi: f32,
    led_mode: u8,
    base_light: u8,
    detect_type: u32,
    detect_react: u32,
    motion_mode: bool,
};

const StatusFrame = struct {
    t_us: u64,
    /// Commands are reaching the robot.
    link: bool,
    /// Telemetry is coming back.
    telemetry_link: bool,
    /// The limits below came from the robot rather than from this build's defaults.
    limits_from_robot: bool,
    robot: []const u8,
    max_speed: f32,
    pan_min_deg: f32,
    pan_max_deg: f32,
    tilt_min_deg: f32,
    tilt_max_deg: f32,
    /// What the loop is currently sending, after clamping and after the watchdog.
    commanded_left: f32,
    commanded_right: f32,
    /// The watchdog has zeroed the setpoint because commands stopped arriving.
    deadman: bool,
    /// Milliseconds since a drive command last arrived.
    since_command_ms: u64,
    commands_sent: u64,
    commands_failed: u64,
    telemetry_frames: u64,
    /// Failed polls. Non-zero with a healthy `link` means the robot takes commands but the
    /// telemetry session has dropped.
    telemetry_errors: u64,
    /// Requests that asked for more than the robot allows and were reduced.
    clamped: u64,
    /// Command messages that could not be decoded.
    rejected: u64,
};

// -- shared state ------------------------------------------------------------------------
//
// Three threads: qnnt's subscriber thread stores setpoints, the output loop sends them, the
// poll thread receives telemetry. The mutex covers the setpoints and the counters; nothing
// here is held across an HTTP call.

const Shared = struct {
    mutex: std.Io.Mutex = .init,

    left: f32 = 0,
    right: f32 = 0,
    /// When a drive command last arrived. The watchdog's input.
    last_drive_us: i64 = 0,
    /// No drive command has ever arrived. Distinct from a stale one: at startup the robot
    /// should be sent a stop, but the operator has not lost control of anything.
    ever_driven: bool = false,

    gimbal: Gimbal = .{ .pan = 0, .tilt = 0 },
    gimbal_pending: bool = false,

    /// Commands are reaching the robot.
    link: bool = false,
    /// Telemetry is coming back. Tracked apart from `link` because the two directions fail
    /// independently, and a bridge that reported one for both hid a dead poll loop behind a
    /// working command path.
    telemetry_link: bool = false,
    deadman: bool = false,
    commands_sent: u64 = 0,
    commands_failed: u64 = 0,
    telemetry_frames: u64 = 0,
    telemetry_errors: u64 = 0,
    clamped: u64 = 0,
    /// Command messages that arrived but could not be read. Counted and reported rather
    /// than dropped in silence: a controller publishing the wrong shape otherwise gets no
    /// indication at all, and the robot simply never moves.
    rejected: u64 = 0,

    telemetry: beast.Telemetry = .{},
    telemetry_seq: u64 = 0,
    telemetry_fresh: bool = false,
};

var shared: Shared = .{};
var deadman_ms: u64 = 500;

/// The robot's limits, and the lock over them.
///
/// This robot's Wi-Fi reboots without notice, so `GET /config` can fail at startup and
/// succeed minutes later. Read once, the bridge would then enforce built-in limits for the
/// rest of its life while the robot sat there able to state the real ones -- so it is
/// re-read whenever a session is established and we do not yet have the robot's own.
var config: beast.Config = .{};
var config_mutex: std.Io.Mutex = .init;

/// The parts building a command needs. Copied under the lock, and free of pointers so the
/// copy stays valid after the config is replaced.
fn currentRules() struct { commands: beast.Commands, limits: beast.Limits, from_robot: bool } {
    config_mutex.lockUncancelable(qnnt_mod.io);
    defer config_mutex.unlock(qnnt_mod.io);
    return .{
        .commands = config.commands,
        .limits = config.limits,
        .from_robot = config.from_robot,
    };
}

/// The robot's name into a caller-owned buffer, because `Config.name()` borrows from the
/// config itself and the config can be replaced underneath a reader.
fn currentName(buf: []u8) []const u8 {
    config_mutex.lockUncancelable(qnnt_mod.io);
    defer config_mutex.unlock(qnnt_mod.io);
    const name = config.name();
    const count = @min(name.len, buf.len);
    @memcpy(buf[0..count], name[0..count]);
    return buf[0..count];
}

/// Try `GET /config` and adopt it if it really is the robot's. Called on every session
/// (re-)establishment, and a no-op once the real limits are in hand.
fn refreshConfig(authority: []const u8) void {
    if (currentRules().from_robot) return;

    const fetched = fetchConfig(authority);
    if (!fetched.from_robot) return;

    config_mutex.lockUncancelable(qnnt_mod.io);
    config = fetched;
    config_mutex.unlock(qnnt_mod.io);
    std.debug.print(
        "ugv-bridge: limits now from the robot -- max_speed {d}, pan [{d}, {d}], " ++
            "tilt [{d}, {d}]\n",
        .{
            fetched.limits.max_speed,
            fetched.limits.pan_min_deg,
            fetched.limits.pan_max_deg,
            fetched.limits.tilt_min_deg,
            fetched.limits.tilt_max_deg,
        },
    );
}

/// The Engine.IO session, and the lock that lets the poll thread replace it while the
/// command thread is using it. A session is not permanent: it expires if the robot stops
/// hearing from us, and it dies outright if the robot's server restarts. Without recovery
/// the bridge would go quiet for good the first time either happened.
var session: sio.Session = .{ .authority = "" };
var session_mutex: std.Io.Mutex = .init;

/// A copy, so no HTTP call is made while holding the lock.
fn currentSession() sio.Session {
    session_mutex.lockUncancelable(qnnt_mod.io);
    defer session_mutex.unlock(qnnt_mod.io);
    return session;
}

/// Establish a session and join both namespaces. Used for the first connection and for
/// every recovery after it, because they are the same job.
fn openSession(client: *sio.Client, authority: []const u8, reply: *std.ArrayList(u8)) !void {
    const fresh = try client.handshake(authority, reply);

    session_mutex.lockUncancelable(qnnt_mod.io);
    session = fresh;
    session_mutex.unlock(qnnt_mod.io);

    // Until a namespace is connected the robot discards events for it, silently.
    try client.openNamespace(&fresh, ns_json, reply);
    try client.openNamespace(&fresh, ns_ctrl, reply);
    // The robot pushes telemetry once asked, the same as the web UI's single
    // `socket.emit('request_data')`.
    try client.emit(&fresh, ns_ctrl, "request_data", null, reply);

    // The robot is answering, so this is the moment to ask for its limits if an earlier
    // attempt failed.
    refreshConfig(authority);
}

var topic_drive_buf: [128]u8 = undefined;
var topic_gimbal_buf: [128]u8 = undefined;
var topic_telemetry_buf: [128]u8 = undefined;
var topic_status_buf: [128]u8 = undefined;
var topic_drive: []const u8 = "";
var topic_gimbal: []const u8 = "";
var topic_telemetry: []const u8 = "";
var topic_status: []const u8 = "";

// -- subscribers -------------------------------------------------------------------------

/// Stores the setpoint and returns. Deliberately does no I/O: this runs on qnnt's
/// subscriber thread, and an HTTP round trip here would stall delivery of the *next*
/// command behind the robot's response to this one.
fn onDrive(topic: []const u8, frame: tld.Frame, context: ?*anyopaque) void {
    _ = topic;
    _ = context;
    const cmd = tld.unpack(Drive, frame, null) catch |err| return reject("drive", err);
    if (!std.math.isFinite(cmd.left) or !std.math.isFinite(cmd.right))
        return reject("drive", error.NotFinite);

    const l = std.math.clamp(cmd.left, -1, 1);
    const r = std.math.clamp(cmd.right, -1, 1);

    shared.mutex.lockUncancelable(qnnt_mod.io);
    defer shared.mutex.unlock(qnnt_mod.io);
    if (l != cmd.left or r != cmd.right) shared.clamped += 1;
    shared.left = l;
    shared.right = r;
    shared.last_drive_us = qnnt.nowMicros();
    shared.ever_driven = true;
}

fn onGimbal(topic: []const u8, frame: tld.Frame, context: ?*anyopaque) void {
    _ = topic;
    _ = context;
    const cmd = tld.unpack(Gimbal, frame, null) catch |err| return reject("gimbal", err);
    if (!std.math.isFinite(cmd.pan) or !std.math.isFinite(cmd.tilt))
        return reject("gimbal", error.NotFinite);

    shared.mutex.lockUncancelable(qnnt_mod.io);
    defer shared.mutex.unlock(qnnt_mod.io);
    shared.gimbal = cmd;
    shared.gimbal_pending = true;
}

/// A command that could not be read. Loud for the first few, then counted only: a
/// controller with a mismatched message shape produces one of these per command, and the
/// useful information is that it is happening at all.
fn reject(which: []const u8, err: anyerror) void {
    shared.mutex.lockUncancelable(qnnt_mod.io);
    shared.rejected += 1;
    const count = shared.rejected;
    shared.mutex.unlock(qnnt_mod.io);
    if (count <= 3 or count % 100 == 0) {
        std.debug.print(
            "ugv-bridge: could not read a {s} command ({t}), {d} so far -- the robot is " ++
                "not moving because of it\n",
            .{ which, err, count },
        );
    }
}

// -- the output loop ---------------------------------------------------------------------

/// Sends the setpoint to the robot: immediately when it changes, and periodically when it
/// does not. This is the only place that puts the robot in motion.
///
/// The first version of this sent every cycle at `--rate`, which is the textbook shape for
/// a teleop output stage and was wrong here. Each command is an HTTP POST -- the polling
/// transport has no persistent stream -- and 10 POST/s saturates the robot's Flask server
/// on its SBC: telemetry polls that return instantly against an idle robot took 4 to 5
/// seconds under that load. The vendor's own UI sends on change plus a 2000 ms heartbeat,
/// and it has a WebSocket to do it over.
///
/// So three separate clocks, because they answer three different questions:
///
///   --rate       the *maximum* send rate. A controller streaming faster than the robot
///                can absorb is coalesced to this; the newest setpoint wins.
///   --heartbeat  how often an unchanged setpoint is re-sent, to stay inside the
///                firmware's own motion timeout.
///   --deadman    how long a setpoint may go un-refreshed before it is replaced by a stop.
///
/// Steady-state load is now 2 POST/s rather than 10, and a change is sent within one 5 ms
/// tick instead of waiting out a period -- so this is both lighter on the robot and more
/// responsive than the loop it replaces.
fn outputLoop(rate_hz: u32, heartbeat_ms: u64) void {
    var client = sio.Client.init(qnnt_mod.io, allocator);
    defer client.deinit();
    // A command must fail fast: the next cycle carries a fresher setpoint than a retry of
    // this one would, and a blocked send here would also stall the watchdog below.
    client.timeout_ms = 1500;

    var reply: std.ArrayList(u8) = .empty;
    defer reply.deinit(allocator);

    var cmd_buf: [256]u8 = undefined;
    var payload_buf: [256]u8 = undefined;

    // The floor between two sends, from --rate.
    const min_gap_us: i64 = @intCast(@max(1, 1_000_000 / @as(u64, rate_hz)));
    const heartbeat_us: i64 = @intCast(heartbeat_ms * 1000);
    // How often the loop looks at the setpoint. Costs nothing -- no I/O -- and bounds how
    // long a change waits to be noticed.
    const tick_us: u64 = 5_000;

    var sent_left: f32 = 0;
    var sent_right: f32 = 0;
    var last_send_us: i64 = 0;
    var primed = false;

    while (!qnnt.stopRequested()) {
        const now = qnnt.nowMicros();

        var want_left: f32 = 0;
        var want_right: f32 = 0;
        var gimbal: ?Gimbal = null;
        {
            shared.mutex.lockUncancelable(qnnt_mod.io);
            defer shared.mutex.unlock(qnnt_mod.io);

            // Just reads the setpoint. The watchdog that zeroes it runs on the supervisor
            // thread -- see `runWatchdog` -- because this thread can be inside a send, and
            // a 500 ms deadman evaluated on a thread that can block for seconds is not a
            // 500 ms deadman.
            want_left = shared.left;
            want_right = shared.right;

            if (shared.gimbal_pending) {
                gimbal = shared.gimbal;
                shared.gimbal_pending = false;
            }
        }

        const since_send = now -| last_send_us;
        const changed = want_left != sent_left or want_right != sent_right or !primed;
        // A change goes out as soon as --rate allows; an unchanged setpoint goes out on the
        // heartbeat, because the firmware stops the tracks if commands stop arriving.
        const send_now = (changed and since_send >= min_gap_us) or since_send >= heartbeat_us;

        if (send_now) {
            // `catch` falls through to the tick rather than `continue`-ing: skipping the
            // sleep on a formatting failure would spin this thread at full speed.
            const rules = currentRules();
            if (beast.driveCommand(
                &cmd_buf,
                rules.commands,
                rules.limits,
                want_left,
                want_right,
            )) |drive| {
                sendJson(&client, drive, &reply);
                sent_left = want_left;
                sent_right = want_right;
                last_send_us = now;
                primed = true;
            } else |_| {}
        }

        if (gimbal) |g| {
            const rules = currentRules();
            if (beast.gimbalCommand(
                &payload_buf,
                rules.commands,
                rules.limits,
                g.pan,
                g.tilt,
                g.speed,
                g.accel,
            )) |cmd| {
                sendJson(&client, cmd, &reply);
                last_send_us = qnnt.nowMicros();
            } else |_| {}
        }

        _ = qnnt.sleepUs(tick_us);
    }

    // Whatever brought the loop down, the robot must not be left driving.
    if (beast.stopCommand(&cmd_buf, currentRules().commands)) |stop| {
        sendJson(&client, stop, &reply);
    } else |_| {}
}

/// The watchdog: replace a setpoint nobody is refreshing with a stop.
///
/// Deliberately on the supervisor thread, which does nothing but publish and sleep 20 ms.
/// It used to live in the output loop, which was wrong for a reason that only showed up
/// against a robot that reboots: the output loop can be inside an HTTP round trip, and
/// until the connect was bounded that meant up to 76 seconds. A watchdog that cannot run
/// while the network is misbehaving is a watchdog that is absent exactly when it is needed.
///
/// It cannot make the robot stop on its own -- only the output loop can send -- but it
/// makes the setpoint correct the instant the deadman expires, so whatever goes out next is
/// a stop, and the status topic tells the truth in the meantime.
fn runWatchdog() void {
    shared.mutex.lockUncancelable(qnnt_mod.io);
    defer shared.mutex.unlock(qnnt_mod.io);

    const age_us = qnnt.nowMicros() -| shared.last_drive_us;
    const stale = !shared.ever_driven or age_us > @as(i64, @intCast(deadman_ms * 1000));
    if (stale) {
        shared.left = 0;
        shared.right = 0;
    }
    shared.deadman = stale and shared.ever_driven;
}

/// One command to the robot, with its bookkeeping. A failure is counted and the link marked
/// down; it is not retried here, because the next cycle is 100 ms away and carries a fresher
/// setpoint than a retry of this one would.
fn sendJson(client: *sio.Client, json: []const u8, reply: *std.ArrayList(u8)) void {
    const current = currentSession();
    client.emit(&current, ns_json, "json", json, reply) catch {
        shared.mutex.lockUncancelable(qnnt_mod.io);
        defer shared.mutex.unlock(qnnt_mod.io);
        shared.commands_failed += 1;
        shared.link = false;
        return;
    };
    shared.mutex.lockUncancelable(qnnt_mod.io);
    defer shared.mutex.unlock(qnnt_mod.io);
    shared.commands_sent += 1;
    shared.link = true;
}

// -- the telemetry loop ------------------------------------------------------------------

/// Holds the single long poll the transport allows, on its own thread. Blocks for as long as
/// the robot has nothing to say, which is why it cannot share a thread with the output loop.
fn pollLoop(authority: []const u8) void {
    var client = sio.Client.init(qnnt_mod.io, allocator);
    defer client.deinit();
    // A long poll legitimately waits: the robot holds it open until it has something to
    // say, bounded by its own 25 s ping interval. So this deadline is for a dead path, not
    // for a quiet robot.
    client.timeout_ms = 35_000;

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);

    var consecutive_failures: u32 = 0;

    while (!qnnt.stopRequested()) {
        _ = client.poll(&session, &body) catch |err| {
            shared.mutex.lockUncancelable(qnnt_mod.io);
            shared.telemetry_link = false;
            shared.telemetry_errors += 1;
            const count = shared.telemetry_errors;
            shared.mutex.unlock(qnnt_mod.io);
            // The first one, then sparsely: a dropped session fails every cycle and the
            // useful information is that it started, not that it continues.
            if (count == 1 or count % 100 == 0) {
                std.debug.print(
                    "ugv-bridge: telemetry poll failed ({t}), {d} so far\n",
                    .{ err, count },
                );
            }
            consecutive_failures += 1;
            // Three in a row is not a blip. Rebuild the session: the likely causes are an
            // expired session or a restarted server, and neither recovers on its own.
            if (consecutive_failures >= 3) {
                if (openSession(&client, authority, &body)) |_| {
                    std.debug.print("ugv-bridge: session re-established\n", .{});
                    consecutive_failures = 0;
                } else |reconnect_err| {
                    std.debug.print(
                        "ugv-bridge: could not re-establish the session ({t})\n",
                        .{reconnect_err},
                    );
                    _ = qnnt.sleepMs(2000);
                }
            } else {
                _ = qnnt.sleepMs(200);
            }
            continue;
        };
        consecutive_failures = 0;

        var it = sio.packets(body.items);
        while (it.next()) |packet| {
            const e = sio.event(packet, ns_ctrl) orelse continue;
            if (!std.mem.eql(u8, e.name, "update")) continue;

            const t = beast.parseTelemetry(e.arg, config.fields, sio.jsonNumber);
            shared.mutex.lockUncancelable(qnnt_mod.io);
            shared.telemetry = t;
            shared.telemetry_seq += 1;
            shared.telemetry_fresh = true;
            shared.telemetry_frames += 1;
            shared.telemetry_link = true;
            shared.mutex.unlock(qnnt_mod.io);
        }
    }
}

// -- publishing --------------------------------------------------------------------------

var publish_buf: std.ArrayList(u8) = .empty;

fn publishTelemetry() !void {
    var t: beast.Telemetry = undefined;
    var seq: u64 = 0;
    {
        shared.mutex.lockUncancelable(qnnt_mod.io);
        defer shared.mutex.unlock(qnnt_mod.io);
        if (!shared.telemetry_fresh) return;
        shared.telemetry_fresh = false;
        t = shared.telemetry;
        seq = shared.telemetry_seq;
    }

    const out: TelemetryFrame = .{
        .seq = seq,
        .t_us = @intCast(qnnt.nowMicros()),
        .voltage = t.voltage,
        .pan_deg = t.pan_deg,
        .tilt_deg = t.tilt_deg,
        .cpu_load = t.cpu_load,
        .cpu_temp_c = t.cpu_temp_c,
        .ram_usage = t.ram_usage,
        .video_fps = t.video_fps,
        .wifi_rssi = t.wifi_rssi,
        .led_mode = t.led_mode,
        .base_light = t.base_light,
        .detect_type = t.detect_type,
        .detect_react = t.detect_react,
        .motion_mode = t.motion_mode,
    };
    try tld.packTo(allocator, &publish_buf, out);
    try qnnt.publish(topic_telemetry, publish_buf.items);
}

fn publishStatus() !void {
    var name_buf: [64]u8 = undefined;
    const robot_name = currentName(&name_buf);
    const rules = currentRules();

    shared.mutex.lockUncancelable(qnnt_mod.io);
    const now = qnnt.nowMicros();
    const since_ms: u64 = if (shared.ever_driven)
        @intCast(@max(0, @divTrunc(now -| shared.last_drive_us, 1000)))
    else
        0;
    const out: StatusFrame = .{
        .t_us = @intCast(now),
        .link = shared.link,
        .telemetry_link = shared.telemetry_link,
        .limits_from_robot = rules.from_robot,
        .robot = robot_name,
        .max_speed = rules.limits.max_speed,
        .pan_min_deg = rules.limits.pan_min_deg,
        .pan_max_deg = rules.limits.pan_max_deg,
        .tilt_min_deg = rules.limits.tilt_min_deg,
        .tilt_max_deg = rules.limits.tilt_max_deg,
        .commanded_left = shared.left,
        .commanded_right = shared.right,
        .deadman = shared.deadman,
        .since_command_ms = since_ms,
        .commands_sent = shared.commands_sent,
        .commands_failed = shared.commands_failed,
        .telemetry_frames = shared.telemetry_frames,
        .telemetry_errors = shared.telemetry_errors,
        .clamped = shared.clamped,
        .rejected = shared.rejected,
    };
    shared.mutex.unlock(qnnt_mod.io);

    try tld.packTo(allocator, &publish_buf, out);
    try qnnt.publish(topic_status, publish_buf.items);
}

// -- setup -------------------------------------------------------------------------------

/// `GET /config` -- the robot describing itself. Everything the bridge enforces comes from
/// here when it can be read.
fn fetchConfig(authority: []const u8) beast.Config {
    var client = sio.Client.init(qnnt_mod.io, allocator);
    defer client.deinit();
    // Startup, so a slow answer is better than a wrong assumption -- but not unbounded.
    client.timeout_ms = 5000;

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);

    client.get(authority, "/config", &body) catch return .{};
    return beast.parseConfig(body.items);
}

fn usage() void {
    std.debug.print(
        \\usage: ugv-bridge [options]
        \\
        \\  --host <addr:port>  the robot's web interface (default 192.168.50.5:5000)
        \\  --topic <prefix>    topic prefix (default ugv/beast)
        \\  --rate <hz>         command rate, which is also the heartbeat (default 10)
        \\  --deadman <ms>      stop if no drive command arrives for this long (default 500)
        \\
        \\Publishes <prefix>/telemetry and <prefix>/status, subscribes <prefix>/drive and
        \\<prefix>/gimbal.
        \\
        \\Drive commands are {{left, right}} in [-1, 1], a fraction of full scale. The robot's
        \\own max_speed from GET /config is what that fraction is of; the bridge publishes it
        \\on the status topic so a controller need not assume it.
        \\
        \\--deadman is the point of this bridge. Commands are re-sent at --rate whether or
        \\not they change, and a setpoint older than the deadman window is replaced by a
        \\stop. Without that a crashed controller or a dropped link leaves the robot driving.
        \\
    , .{});
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();

    var authority: []const u8 = "192.168.50.5:5000";
    var prefix: []const u8 = "ugv/beast";
    var rate_hz: u32 = 10;
    var heartbeat_ms: u64 = 500;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--host")) {
            authority = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--topic")) {
            prefix = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--rate")) {
            const text = args.next() orelse return usage();
            rate_hz = std.fmt.parseInt(u32, text, 10) catch return usage();
            if (rate_hz == 0 or rate_hz > 200) {
                std.debug.print("ugv-bridge: --rate must be 1..200 Hz\n", .{});
                return;
            }
        } else if (std.mem.eql(u8, arg, "--heartbeat")) {
            const text = args.next() orelse return usage();
            heartbeat_ms = std.fmt.parseInt(u64, text, 10) catch return usage();
            if (heartbeat_ms < 20 or heartbeat_ms > 2000) {
                // Below 20 ms it is a send rate, not a heartbeat, and it saturates the
                // robot's server. Above 2000 ms it is outside the margin the vendor's own
                // UI keeps against the firmware's motion timeout.
                std.debug.print("ugv-bridge: --heartbeat must be 20..2000 ms\n", .{});
                return;
            }
        } else if (std.mem.eql(u8, arg, "--deadman")) {
            const text = args.next() orelse return usage();
            deadman_ms = std.fmt.parseInt(u64, text, 10) catch return usage();
            if (deadman_ms == 0) {
                std.debug.print("ugv-bridge: --deadman must be at least 1 ms\n", .{});
                return;
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return usage();
        } else {
            std.debug.print("ugv-bridge: unknown option '{s}'\n", .{arg});
            return usage();
        }
    }

    topic_drive = try std.fmt.bufPrint(&topic_drive_buf, "{s}/drive", .{prefix});
    topic_gimbal = try std.fmt.bufPrint(&topic_gimbal_buf, "{s}/gimbal", .{prefix});
    topic_telemetry = try std.fmt.bufPrint(&topic_telemetry_buf, "{s}/telemetry", .{prefix});
    topic_status = try std.fmt.bufPrint(&topic_status_buf, "{s}/status", .{prefix});

    qnnt.configureFromEnvironment();
    if (!qnnt.run()) {
        std.debug.print("ugv-bridge: could not start the qnnt node\n", .{});
        return;
    }
    defer qnnt.deinit();
    qnnt.installSignalHandlers();

    // Read the robot's limits before anything can be commanded. Retried later on every
    // session (re-)establishment, so a robot that was rebooting at this moment still gets
    // to state its own limits rather than leaving the bridge on assumed ones for good.
    config = fetchConfig(authority);
    if (!config.from_robot) {
        std.debug.print(
            "ugv-bridge: GET http://{s}/config failed -- using built-in limits " ++
                "(max_speed {d}) until the robot answers. Reported as " ++
                "limits_from_robot=false on {s}.\n",
            .{ authority, config.limits.max_speed, topic_status },
        );
    }

    // The session.
    var setup = sio.Client.init(qnnt_mod.io, allocator);
    defer setup.deinit();
    var reply: std.ArrayList(u8) = .empty;
    defer reply.deinit(allocator);

    // A failed first connection is NOT fatal. This robot's Wi-Fi reboots without notice,
    // so the bridge being started while the robot is down is an ordinary event, not an
    // error worth exiting on -- the poll loop's recovery will keep trying. What matters is
    // that the topics still come up, so a controller can attach and the status topic can
    // say the link is down.
    openSession(&setup, authority, &reply) catch |err| {
        std.debug.print(
            "ugv-bridge: no Socket.IO session at {s} yet ({t}) -- retrying in the " ++
                "background\n",
            .{ authority, err },
        );
    };

    // Publishers before subscribers, so nothing attaches to a topic that never appears.
    if (!qnnt.runPublisher(topic_telemetry, null, null, null) or
        !qnnt.runPublisher(topic_status, null, null, null))
    {
        std.debug.print("ugv-bridge: could not register the published topics\n", .{});
        return;
    }
    // Frame delivery, not text: the commands are TLD objects. A text subscription waits
    // for a newline delimiter that binary TLD never contains, so the handler is never
    // called and nothing anywhere reports why.
    if (!qnnt.subscribeFrames(topic_drive, onDrive, null) or
        !qnnt.subscribeFrames(topic_gimbal, onGimbal, null))
    {
        std.debug.print("ugv-bridge: could not subscribe to the command topics\n", .{});
        return;
    }

    var banner_name: [64]u8 = undefined;
    const banner_rules = currentRules();
    std.debug.print(
        \\ugv-bridge: {s} at {s} (limits {s})
        \\  commands  {s}  {s}
        \\  telemetry {s}  {s}
        \\  {d} Hz max, {d} ms heartbeat, {d} ms deadman, max_speed {d}, pan [{d}, {d}], tilt [{d}, {d}]
        \\
    , .{
        currentName(&banner_name),
        authority,
        if (banner_rules.from_robot) "from the robot" else "BUILT-IN DEFAULTS, retrying",
        topic_drive,
        topic_gimbal,
        topic_telemetry,
        topic_status,
        rate_hz,
        heartbeat_ms,
        deadman_ms,
        banner_rules.limits.max_speed,
        banner_rules.limits.pan_min_deg,
        banner_rules.limits.pan_max_deg,
        banner_rules.limits.tilt_min_deg,
        banner_rules.limits.tilt_max_deg,
    });

    const output = try std.Thread.spawn(.{}, outputLoop, .{ rate_hz, heartbeat_ms });
    const poll = try std.Thread.spawn(.{}, pollLoop, .{authority});

    // Telemetry as it arrives; status on a timer, so a subscriber that attaches late still
    // learns the robot's limits without waiting for one of them to change.
    var last_status_us: i64 = 0;
    while (!qnnt.stopRequested()) {
        // Before publishing, so the status frame carries the watchdog's current verdict
        // rather than one up to 20 ms stale.
        runWatchdog();
        publishTelemetry() catch {};
        const now = qnnt.nowMicros();
        if (now -| last_status_us >= 500_000) {
            last_status_us = now;
            publishStatus() catch {};
        }
        _ = qnnt.sleepMs(20);
    }

    output.join();
    poll.join();
    publish_buf.deinit(allocator);
    std.debug.print("ugv-bridge: stopped, robot sent a stop\n", .{});
}
