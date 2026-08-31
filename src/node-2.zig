const std = @import("std");
const qnnt = @import("qnnt").Qnnt;

// Per-subscription state, handed to the library at registration and handed back on
// every callback. This is what `context` buys: one handler now serves both topics,
// where before there had to be two near-identical handlers over two globals purely
// because a callback had no way to be told which subscription it belonged to.
const Feed = struct {
    label: []const u8,
    // Timestamp (µs) of the previous message. Only ever touched by this feed's own
    // subscriber thread, so no synchronization is needed.
    prev_us: u64 = 0,
    count: u64 = 0,
};

var topic_b: Feed = .{ .label = "b" };
var topic_c: Feed = .{ .label = "c" };

// Invoked on each subscriber's background thread for every message on its topic.
fn onMessage(topic: []const u8, msg: []const u8, context: ?*anyopaque) void {
    // The pointer is ours: the library carries it through untouched and never looks
    // inside it, so the cast back is as safe as what we passed in.
    const feed: *Feed = @ptrCast(@alignCast(context orelse return));

    const us: u64 = @intCast(qnnt.nowMicros());
    const millis = us / 1000;
    const micros = us % 1000; // 0..999, zero-padded so it reads as a fraction of a ms
    const delta = if (feed.prev_us == 0) 0 else us - feed.prev_us; // µs since previous
    feed.prev_us = us;
    feed.count += 1;

    std.debug.print("[{d}.{d:0>3}] (+{d}us) node-2 feed {s} #{d} on {s}: {s}", .{
        millis, micros, delta, feed.label, feed.count, topic, msg,
    });
}

pub fn main() !void {
    // Every QNNT_* variable, handled by the library so all four languages agree.
    qnnt.configureFromEnvironment();

    if (! qnnt.run()) {
        std.debug.print("failed to run QNNT\n", .{});
    }
    defer qnnt.deinit();

    // Ctrl-C and SIGTERM now ask the node to stop rather than killing the process, so
    // the deinit above actually runs and releases the registry port cleanly.
    qnnt.installSignalHandlers();

    // This node publishes nothing; it only consumes one topic from node-0 and one
    // from node-1, both resolved through the registry. Same handler, different state.
    if (! qnnt.subscribe("test/topic-b", onMessage, &topic_b)) {
        std.debug.print("failed to subscribe to test/topic-b\n", .{});
        return;
    } else if (! qnnt.subscribe("test/topic-c", onMessage, &topic_c)) {
        std.debug.print("failed to subscribe to test/topic-c\n", .{});
        return;
    }

    // Nothing to do on the main thread — the subscribers deliver on their own threads,
    // so just stay alive (and keep this node available as a registry standby) until a
    // signal asks us to stop.
    while (!qnnt.stopRequested()) {
        qnnt.sleepMs(1000);
    }
}
