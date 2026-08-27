const std = @import("std");
const qnnt = @import("qnnt").Qnnt;

// Timestamp (µs) of the previous message, one per topic. Each is only ever touched
// by that topic's own subscriber thread, so no synchronization is needed.
var prev_b_us: u64 = 0;
var prev_c_us: u64 = 0;

// Shared formatting for both handlers; `prev_us` is the caller's per-topic slot.
fn report(prev_us: *u64, topic: []const u8, msg: []const u8) void {
    const us: u64 = @intCast(qnnt.nowMicros());
    const millis = us / 1000;
    const micros = us % 1000; // 0..999, zero-padded so it reads as a fraction of a ms
    const delta = if (prev_us.* == 0) 0 else us - prev_us.*; // µs since previous message
    prev_us.* = us;
    std.debug.print("[{d}.{d:0>3}] (+{d}us) node-2 received on {s}: {s}", .{ millis, micros, delta, topic, msg });
}

// Invoked on each subscriber's background thread for every message on the topic.
fn onTopicB(topic: []const u8, msg: []const u8) void {
    report(&prev_b_us, topic, msg);
}

fn onTopicC(topic: []const u8, msg: []const u8) void {
    report(&prev_c_us, topic, msg);
}

pub fn main() !void {
    if (! qnnt.run()) {
        std.debug.print("failed to run QNNT\n", .{});
    }
    defer qnnt.deinit();

    // This node publishes nothing; it only consumes one topic from node-0 and one
    // from node-1, both resolved through the registry.
    if (! qnnt.subscribe("test/topic-b", onTopicB)) {
        std.debug.print("failed to subscribe to test/topic-b\n", .{});
        return;
    } else if (! qnnt.subscribe("test/topic-c", onTopicC)) {
        std.debug.print("failed to subscribe to test/topic-c\n", .{});
        return;
    }

    // Nothing to do on the main thread — the subscribers deliver on their own
    // threads, so just stay alive (and keep this node available as a registry
    // standby).
    while (true) {
        qnnt.sleepMs(1000);
    }
}
