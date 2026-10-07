//! Round-trip benchmark. Publishes `test/bench` frames and measures how long each one
//! takes to come back on `test/bench-echo` from node-5.
//!
//!   zig build run-6 -- [period_us] [payload_bytes] [report_ms]   defaults: 50000 1024 5000
//!
//! Every number here comes from one clock -- the one in this process -- so it is valid
//! between hosts whose clocks disagree, which on a LAN is all of them. What it measures is
//! the whole path twice: encode, publish, the network, node-5's decode and republish, the
//! network again, and the decode here. One-way is not simply half of it, since the two
//! directions of a Wi-Fi link are rarely symmetric, but the round trip is exact.
//!
//! Pace it below the link's capacity. Saturating the path measures queueing delay, which
//! grows without bound and says nothing about the transport; the default 20 Hz at 1 KiB is
//! 20 KB/s, well under anything worth calling a LAN.

const std = @import("std");
const qnnt = @import("qnnt").Qnnt;
const tld = @import("qnnt").Tld;

const allocator = std.heap.page_allocator;

const out_topic = "test/bench";
const in_topic = "test/bench-echo";

var report_interval_us: u64 = 5_000_000;

// Round trips, in microseconds. Log-ish buckets: a LAN spans microseconds to tens of
// milliseconds, and linear buckets fine enough for the low end would need millions for
// the high one. 64 us per bucket up to 262 ms, with an explicit overflow count.
const bucket_us = 64;
const bucket_count = 4096;
var hist: [bucket_count]u32 = @splat(0);
var overflow: u64 = 0;

var window_n: u64 = 0;
var window_sum: u64 = 0;
var window_min: u64 = std.math.maxInt(u64);
var window_max: u64 = 0;
var window_start_us: u64 = 0;

var returned: u64 = 0;
var corrupt: u64 = 0;
var window_id: u64 = 0;

// Only the publishing loop in main touches these.
var frame: std.ArrayList(u8) = .empty;
var payload: []u8 = &.{};
var seq: u64 = 0;

// Written by the publishing loop in main, read by the subscriber thread when it reports.
var sent = @import("qnnt").Atomic64.Value.init(0);

// Frames published before the echo responder had subscribed. Captured at the first echo
// and subtracted from the loss count, because otherwise every window reports a constant
// backlog that looks like loss and is only a late subscriber.
var startup_gap: u64 = 0;
var first_echo_seen = false;

fn percentile(p: f64) u64 {
    var total: u64 = overflow;
    for (hist) |c| total += c;
    if (total == 0) return 0;

    const target = @as(u64, @intFromFloat(@as(f64, @floatFromInt(total)) * p));
    var seen: u64 = 0;
    for (hist, 0..) |c, i| {
        seen += c;
        if (seen >= target) return (i + 1) * bucket_us;
    }
    return bucket_count * bucket_us;
}

fn report(now_us: u64) void {
    const n = @as(f64, @floatFromInt(window_n));
    std.debug.print(
        "node-6 rtt us over {d} trips: min {d} mean {d:.0} p50 {d} p90 {d} p99 {d} max {d} | sent {d} back {d} lost {d} corrupt {d}\n",
        .{
            window_n,
            if (window_min == std.math.maxInt(u64)) 0 else window_min,
            if (window_n == 0) 0 else @as(f64, @floatFromInt(window_sum)) / n,
            percentile(0.50),
            percentile(0.90),
            percentile(0.99),
            window_max,
            sent.load(.monotonic),
            returned,
            sent.load(.monotonic) -| returned -| startup_gap,
            corrupt,
        },
    );

    window_n = 0;
    window_sum = 0;
    window_min = std.math.maxInt(u64);
    window_max = 0;
    window_start_us = now_us;
    hist = @splat(0);
    overflow = 0;
}

/// Runs on the subscriber thread; owns every statistic above except the publishing ones.
fn onEcho(_: []const u8, f: tld.Frame, _: ?*anyopaque) void {
    var sent_us: u64 = 0;
    var got_id: u64 = 0;
    var ok = false;

    var it = f.objectIterator() catch return;
    while (it.next() catch return) |pair| {
        if (std.mem.eql(u8, pair.key, "t")) {
            sent_us = pair.value.asUint() catch return;
            ok = true;
        } else if (std.mem.eql(u8, pair.key, "id")) {
            got_id = pair.value.asUint() catch return;
        }
    }
    if (!ok) {
        corrupt += 1;
        return;
    }

    const now_us: u64 = @intCast(qnnt.nowMicros());
    // Same clock at both ends of this subtraction -- the whole point of echoing.
    const rtt = now_us -| sent_us;

    if (!first_echo_seen) {
        first_echo_seen = true;
        startup_gap = sent.load(.monotonic) -| 1;
    }

    returned += 1;
    window_n += 1;
    window_sum += rtt;
    window_min = @min(window_min, rtt);
    window_max = @max(window_max, rtt);

    const bucket = rtt / bucket_us;
    // @intCast rather than a usize bucket: the guard to its left already proves the
    // value fits, and on a 32-bit target usize is narrower than the u64 it came from.
    if (bucket < bucket_count) hist[@intCast(bucket)] += 1 else overflow += 1;

    if (window_start_us == 0) window_start_us = now_us;
    if (now_us -| window_start_us >= report_interval_us) report(now_us);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next(); // executable path

    var period_us: u64 = 50_000; // 20 Hz
    var payload_bytes: usize = 1024;
    if (args.next()) |a| period_us = std.fmt.parseInt(u64, a, 10) catch period_us;
    if (args.next()) |a| payload_bytes = std.fmt.parseInt(usize, a, 10) catch payload_bytes;
    if (args.next()) |a| {
        const ms = std.fmt.parseInt(u64, a, 10) catch 5000;
        report_interval_us = ms * 1000;
    }

    payload = try allocator.alloc(u8, payload_bytes);
    defer allocator.free(payload);
    for (payload, 0..) |*b, i| b.* = @truncate(i);

    qnnt.configureFromEnvironment();

    if (! qnnt.run()) {
        std.debug.print("failed to run QNNT\n", .{});
    }
    defer qnnt.deinit();

    qnnt.installSignalHandlers();

    if (! qnnt.runPublisher(out_topic, null, null, null)) {
        std.debug.print("failed to run {s} publisher\n", .{out_topic});
        return;
    }

    if (! qnnt.subscribeFrames(in_topic, onEcho, null)) {
        std.debug.print("failed to subscribe to {s}\n", .{in_topic});
        return;
    }

    std.debug.print("node-6 probing {s} -> {s}: {d}B payload, {d}us period ({d:.1} Hz)\n", .{
        out_topic,
        in_topic,
        payload_bytes,
        period_us,
        if (period_us == 0) 0 else 1_000_000.0 / @as(f64, @floatFromInt(period_us)),
    });

    // Publish from here rather than through the scheduler, so the timestamp is written as
    // late as possible before the frame goes out.
    while (!qnnt.stopRequested()) {
        frame.clearRetainingCapacity();
        var enc = tld.Encoder.init(allocator, &frame);

        seq += 1;
        const obj = enc.beginObject();
        try enc.writeKey("id");
        try enc.writeUint(seq);
        try enc.writeKey("t");
        try enc.writeUint(@intCast(qnnt.nowMicros()));
        try enc.writeKey("data");
        try enc.writeBuffer(payload);
        try enc.end(obj);

        qnnt.publish(out_topic, frame.items) catch {};
        _ = sent.fetchAdd(1, .monotonic);

        if (period_us == 0) continue;
        qnnt.sleepMs(@intCast(period_us / 1000));
    }
}
