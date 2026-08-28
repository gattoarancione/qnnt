const std = @import("std");
const qnnt = @import("qnnt").Qnnt;

// Timestamp (µs) of the previous message; only ever touched by the single
// topic-a subscriber thread, so no synchronization is needed.
var prev_us: u64 = 0;

// Called by the topic-c scheduler thread to produce that tick's payload.
fn topicCSource(_: []const u8, _: ?*anyopaque) ?[]const u8 {
    return "hola!\n";
}

// Invoked on the subscriber's background thread for each message on the topic.
fn onTopicA(topic: []const u8, msg: []const u8, _: ?*anyopaque) void {
    const us: u64 = @intCast(qnnt.nowMicros());
    const millis = us / 1000;
    const micros = us % 1000; // 0..999, zero-padded so it reads as a fraction of a ms
    const delta = if (prev_us == 0) 0 else us - prev_us; // µs since previous message
    prev_us = us;
    std.debug.print("[{d}.{d:0>3}] (+{d}us) node-1 received on {s}: {s}", .{ millis, micros, delta, topic, msg });
}

pub fn main() !void {
    if (! qnnt.run()) {
        std.debug.print("failed to run QNNT\n", .{});
    }
    defer qnnt.deinit();

    qnnt.installSignalHandlers();

    // This node publishes its own topic, paced by the library's scheduler at the 1 ms
    // period the old hand-rolled `sleepMs(1)` loop was reaching for...
    if (! qnnt.runPublisher("test/topic-c", topicCSource, 1_000, null)) { // 1 ms, 1 kHz
        std.debug.print("failed to run test/topic-c publisher\n", .{});
        return;
    }

    // ...and subscribes to one of node-0's topics via the registry, handing the
    // library a callback that receives each message asynchronously.
    if (! qnnt.subscribe("test/topic-a", onTopicA, null)) {
        std.debug.print("failed to subscribe to test/topic-a\n", .{});
        return;
    }

    // Both the publisher and the subscriber run on their own threads now, so the
    // main thread just stays alive.
    while (!qnnt.stopRequested()) {
        qnnt.sleepMs(1000);
    }
}
