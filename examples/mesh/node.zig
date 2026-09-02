//! The Zig node of the five-language mesh. See SCHEMA.txt.
//!
//!   zig build mesh && bash examples/mesh/run.sh
//!
//! Publishes mesh/zig and subscribes to the other four topics. Zig needs no schema
//! declaration beyond the struct itself: @typeInfo supplies the field names, so `pack` and
//! `unpack` work straight off the type.

const std = @import("std");
const qnnt = @import("qnnt").Qnnt;
const tld = @import("qnnt").Tld;

const allocator = std.heap.page_allocator;

const me = "zig";
const my_topic = "mesh/zig";
const peers = [_]struct { name: []const u8, topic: []const u8 }{
    .{ .name = "c", .topic = "mesh/c" },
    .{ .name = "cpp", .topic = "mesh/cpp" },
    .{ .name = "python", .topic = "mesh/python" },
    .{ .name = "qt", .topic = "mesh/qt" },
};

const Mode = enum(i32) { idle = 0, running = 1, faulted = 2 };
const Reading = struct { channel: u8, value: f64, valid: bool };
const Origin = struct { x: f64, y: f64 };

const Sample = struct {
    seq: u64,
    source: []const u8,
    mode: Mode,
    count: i32,
    temp: f32,
    blob: tld.Bytes,
    origin: Origin,
    readings: [3]Reading,
};

const blob_bytes = [_]u8{ 0x00, 0xFF, 0x0A };

/// Everything a sample must contain, derived from its sequence number alone, so a receiver
/// can check what it should have got rather than only that something arrived.
fn expected(seq: u64, from: []const u8) Sample {
    var readings: [3]Reading = undefined;
    for (&readings, 0..) |*r, i| {
        r.* = .{
            .channel = @intCast(i + 1),
            .value = @floatFromInt(seq * 10 + i),
            .valid = i != 1,
        };
    }
    return .{
        .seq = seq,
        .source = from,
        .mode = @enumFromInt(@as(i32, @intCast(seq % 3))),
        .count = -@as(i32, @intCast(seq)),
        .temp = 36.5,
        .blob = .{ .data = &blob_bytes },
        .origin = .{ .x = 1.5, .y = -2.5 },
        .readings = readings,
    };
}

const Peer = struct {
    name: []const u8,
    expected: bool = true,
    received: std.atomic.Value(u64) = .init(0),
    last_seq: std.atomic.Value(u64) = .init(0),
    first_seq: std.atomic.Value(u64) = .init(0),
    problems: std.atomic.Value(u64) = .init(0),
};

var peer_state: [peers.len]Peer = undefined;

/// Which peers to expect. run.sh sets MESH_PEERS to the languages it actually started, so
/// the mesh works with any subset -- build without -Dqt and the other four stop waiting for
/// a Qt node instead of all failing.
fn peerPresent(name: []const u8) bool {
    const raw = std.c.getenv("MESH_PEERS") orelse return true;
    const list = std.mem.span(raw);
    if (list.len == 0) return true;
    var it = std.mem.tokenizeScalar(u8, list, ',');
    while (it.next()) |entry| {
        if (std.mem.eql(u8, std.mem.trim(u8, entry, " "), name)) return true;
    }
    return false;
}

/// One subscriber thread per topic, so each slot is touched by exactly one thread; the
/// atomics are for main's benefit when it reads them at the end.
fn onFrame(_: []const u8, frame: tld.Frame, context: ?*anyopaque) void {
    const peer: *Peer = @ptrCast(@alignCast(context.?));

    // No allocator: strings borrow from the frame, which is alive for this call and is all
    // the comparisons below need.
    const got = tld.unpack(Sample, frame, null) catch {
        _ = peer.problems.fetchAdd(1, .monotonic);
        return;
    };

    const want = expected(got.seq, peer.name);
    var bad = false;
    if (!std.mem.eql(u8, got.source, want.source)) bad = true;
    if (got.mode != want.mode or got.count != want.count) bad = true;
    if (got.temp != want.temp) bad = true;
    if (!std.mem.eql(u8, got.blob.data, want.blob.data)) bad = true;
    if (got.origin.x != want.origin.x or got.origin.y != want.origin.y) bad = true;
    for (got.readings, want.readings) |a, b| {
        if (a.channel != b.channel or a.value != b.value or a.valid != b.valid) bad = true;
    }

    const previous = peer.last_seq.swap(got.seq, .monotonic);
    // A gap inside the run means the transport lost something. Attaching late does not, so
    // the first sample sets the baseline instead of being compared against 1.
    if (previous != 0 and got.seq != previous + 1) bad = true;
    if (previous == 0) peer.first_seq.store(got.seq, .monotonic);

    if (bad) _ = peer.problems.fetchAdd(1, .monotonic);
    _ = peer.received.fetchAdd(1, .monotonic);
}

var out_frame: std.ArrayList(u8) = .empty;
var next_seq: u64 = 0;

/// The scheduler starts ticking the moment runPublisher is called, which is before the
/// roster has connected -- so the gate lives here rather than in main. Returning null skips
/// a tick without consuming a sequence number, which is what keeps seq 1 the first sample
/// anybody sees.
var gate_open = std.atomic.Value(bool).init(false);

fn produce(_: []const u8, _: ?*anyopaque) ?[]const u8 {
    if (!gate_open.load(.monotonic)) return null;
    next_seq += 1;
    tld.packTo(allocator, &out_frame, expected(next_seq, me)) catch return null;
    return out_frame.items;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();

    var run_ms: u64 = 9000;
    var need: u64 = 5;
    if (args.next()) |a| run_ms = std.fmt.parseInt(u64, a, 10) catch run_ms;
    if (args.next()) |a| need = std.fmt.parseInt(u64, a, 10) catch need;

    qnnt.configureFromEnvironment();
    if (!qnnt.run()) {
        std.debug.print("{s}: failed to start\n", .{me});
        std.process.exit(1);
    }
    defer qnnt.deinit();
    qnnt.installSignalHandlers();

    // Announce the topic first, so peers can resolve it while this node attaches to theirs.
    // The scheduler starts further down, once someone is actually listening.
    if (!qnnt.runPublisher(my_topic, produce, 200_000, null)) {
        std.debug.print("{s}: failed to publish {s}\n", .{ me, my_topic });
        std.process.exit(1);
    }

    var expecting: usize = 0;
    for (&peer_state, peers) |*state, peer| {
        state.* = .{ .name = peer.name, .expected = peerPresent(peer.name) };
        if (!state.expected) continue;
        expecting += 1;
        if (!qnnt.subscribeFrames(peer.topic, onFrame, state)) {
            std.debug.print("{s}: failed to subscribe {s}\n", .{ me, peer.topic });
            std.process.exit(1);
        }
    }

    std.debug.print("{s}: publishing {s}, subscribed to {d} peers\n", .{ me, my_topic, expecting });

    // Wait for the first subscriber rather than sleeping a guess. Before this existed the
    // examples slept a fixed 600-1500 ms and still lost the opening samples when a peer
    // was slow to resolve the topic; now the first sample goes out when someone is there
    // to receive it.
    // Not just one subscriber but all of them: this node knows how many peers the roster
    // says are coming, and waiting for the last one means every peer sees seq 1.
    if (qnnt.waitForSubscribers(my_topic, expecting, 5000)) {
        std.debug.print("{s}: all {d} subscribers on {s}, publishing\n", .{
            me, expecting, my_topic,
        });
    } else {
        std.debug.print("{s}: only {d} of {d} subscribers after 5s, publishing anyway\n", .{
            me, qnnt.subscriberCount(my_topic), expecting,
        });
    }
    gate_open.store(true, .monotonic);

    const deadline = @as(u64, @intCast(qnnt.nowMicros())) + run_ms * 1000;
    while (!qnnt.stopRequested() and @as(u64, @intCast(qnnt.nowMicros())) < deadline) {
        qnnt.sleepMs(200);
    }

    var failed = false;
    for (&peer_state) |*state| {
        if (!state.expected) continue;
        const got = state.received.load(.monotonic);
        const bad = state.problems.load(.monotonic);
        const ok = got >= need and bad == 0;
        if (!ok) failed = true;
        std.debug.print("{s}: from {s:<7} {d:>3} samples, seq {d}..{d}, {d} problem(s) {s}\n", .{
            me,
            state.name,
            got,
            state.first_seq.load(.monotonic),
            state.last_seq.load(.monotonic),
            bad,
            if (ok) "ok" else "FAILED",
        });
    }

    std.debug.print("{s}: {s}\n", .{ me, if (failed) "FAILED" else "all peers verified" });
    if (failed) std.process.exit(1);
}
