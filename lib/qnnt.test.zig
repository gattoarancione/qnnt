//! Lifecycle tests. These exist because the interesting failure is not a wrong value,
//! it is a thread still running after `deinit` returned — so they drive the node through
//! start/stop cycles with workers parked in every blocking call the library has, and
//! rely on the join in `nodeDeinit` to prove nothing is left behind. A regression shows
//! up as a hang (the join never completes) or a crash (a worker touching a torn-down
//! `io`), not as a failed assertion.

const std = @import("std");
const testing = std.testing;
const qnnt = @import("./qnnt.zig").Qnnt;
const tld = @import("./qnnt.zig").Tld;
const QueuedMessage = @import("./qnnt.zig").QueuedMessage;

// A port of our own, so this binary neither disturbs a node the developer is running nor
// competes with the example programs — which used to have to be serialised against it.
const test_registry_port = 22300;

// Every test starts its node through here, so the port is set exactly once per run.
fn startNode() !void {
    try testing.expect(qnnt.setRegistryPort(test_registry_port));
    try testing.expect(qnnt.run());
}

fn source(_: []const u8, _: ?*anyopaque) ?[]const u8 {
    return "tick\n";
}

fn onMessage(_: []const u8, _: []const u8, _: ?*anyopaque) void {}

fn onFrame(_: []const u8, _: tld.Frame, _: ?*anyopaque) void {}

test "start and stop with no workers beyond the registry" {
    try startNode();
    qnnt.deinit();
}

test "repeated start/stop cycles" {
    // Ten cycles: a worker leaked from an earlier cycle would still be looping on a
    // torn-down `io` during the next one.
    for (0..10) |_| {
        try startNode();
        qnnt.deinit();
    }
}

test "stop with a publisher, subscriber and scheduler mid-flight" {
    for (0..5) |_| {
        try startNode();

        // A scheduled publisher (scheduler thread + register loop + accept loop), a
        // manual publisher, and both subscriber flavours. That covers every worker
        // kind: accept, blocking read, connect-and-retry, and paced sleep.
        try testing.expect(qnnt.runPublisher("test/lifecycle-a", source, 1_000, null));
        try testing.expect(qnnt.runPublisher("test/lifecycle-b", null, null, null));
        try testing.expect(qnnt.subscribe("test/lifecycle-a", onMessage, null));
        try testing.expect(qnnt.subscribeFrames("test/lifecycle-c", onFrame, null));

        // Long enough for the registry to be elected, registrations to land and the
        // subscriber to connect, so the workers are actually parked in their blocking
        // calls rather than still starting up.
        qnnt.sleepMs(120);

        qnnt.deinit();
    }
}

test "stop while a subscriber is retrying a topic that does not exist" {
    // The subscriber sits in resolveTopic/connect and sleeps between attempts. This is
    // the case a naive shutdown flag misses: without an interruptible sleep the join
    // waits out a full probe interval.
    try startNode();
    try testing.expect(qnnt.subscribe("test/never-published", onMessage, null));
    qnnt.sleepMs(50);

    const start = qnnt.nowMicros();
    qnnt.deinit();
    const elapsed_us = qnnt.nowMicros() - start;

    // Well under the 2000 ms probe interval it would take if the sleep were not sliced.
    try testing.expect(elapsed_us < 1_000_000);
}

test "stop immediately after start, before workers reach their blocking calls" {
    // Races the shutdown against worker startup: the flag may be set before a worker
    // has even entered its loop, so every loop has to check it on entry rather than
    // only after its first blocking call.
    for (0..10) |_| {
        try startNode();
        try testing.expect(qnnt.runPublisher("test/race", source, 100, null));
        try testing.expect(qnnt.subscribe("test/race", onMessage, null));
        qnnt.deinit();
    }
}

test "unpaced publisher stops promptly" {
    // The unpaced scheduler never sleeps, so the only thing that stops it is the flag
    // check at the top of its loop.
    try startNode();
    try testing.expect(qnnt.runPublisher("test/unpaced", source, 0, null));
    qnnt.sleepMs(50);

    const start = qnnt.nowMicros();
    qnnt.deinit();
    try testing.expect(qnnt.nowMicros() - start < 1_000_000);
}

// ---------------------------------------------------------------- context

const Captured = struct {
    seen: std.atomic.Value(u32) = .init(0),
    tag: u32,
};

fn countingHandler(_: []const u8, _: []const u8, context: ?*anyopaque) void {
    const captured: *Captured = @ptrCast(@alignCast(context orelse return));
    _ = captured.seen.fetchAdd(1, .monotonic);
}

fn taggedSource(_: []const u8, context: ?*anyopaque) ?[]const u8 {
    const captured: *Captured = @ptrCast(@alignCast(context orelse return null));
    _ = captured.seen.fetchAdd(1, .monotonic);
    return switch (captured.tag) {
        1 => "one\n",
        else => "other\n",
    };
}

test "context reaches a source, and distinguishes two subscriptions" {
    var pub_ctx: Captured = .{ .tag = 1 };
    var sub_a: Captured = .{ .tag = 10 };
    var sub_b: Captured = .{ .tag = 20 };

    try startNode();
    defer qnnt.deinit();

    try testing.expect(qnnt.runPublisher("test/ctx", taggedSource, 1_000, &pub_ctx));

    // One handler, two subscriptions to the same topic, told apart only by context.
    try testing.expect(qnnt.subscribe("test/ctx", countingHandler, &sub_a));
    try testing.expect(qnnt.subscribe("test/ctx", countingHandler, &sub_b));

    var waited_ms: u64 = 0;
    while (waited_ms < 3_000) {
        if (sub_a.seen.load(.monotonic) > 0 and sub_b.seen.load(.monotonic) > 0) break;
        qnnt.sleepMs(100);
        waited_ms += 100;
    }

    // The source runs on the scheduler thread with no network involved, so this half is
    // unconditional: the publish path must have carried our pointer through.
    try testing.expect(pub_ctx.seen.load(.monotonic) > 0);

    // The subscriber half needs discovery to work. This used to be skipped here: a
    // server-side TIME_WAIT on the registry port, left by a previous cycle's shutdown,
    // blocked every later bind, so most tests ran with no registry at all. The listener
    // now sets SO_REUSEADDR, so a missing registry is a real fault and fails loudly.
    if (sub_a.seen.load(.monotonic) == 0 or sub_b.seen.load(.monotonic) == 0) {
        std.debug.print(
            "[ctx] no delivery after {d}ms (source ran {d} times, sub_a={d} sub_b={d})\n",
            .{
                waited_ms,
                pub_ctx.seen.load(.monotonic),
                sub_a.seen.load(.monotonic),
                sub_b.seen.load(.monotonic),
            },
        );
    }

    // Both saw traffic, so context was neither dropped nor crossed between them.
    try testing.expect(sub_a.seen.load(.monotonic) > 0);
    try testing.expect(sub_b.seen.load(.monotonic) > 0);
}

test "a null context is delivered as null, not as garbage" {
    try startNode();
    defer qnnt.deinit();

    // taggedSource returns null when its context is null, so the topic exists but
    // publishes nothing. Reaching here without a crash is the assertion.
    try testing.expect(qnnt.runPublisher("test/ctx-null", taggedSource, 1_000, null));
    qnnt.sleepMs(80);
}

// ---------------------------------------------------------------- signals

test "signal handlers are not installed by run()" {
    // A library must not take over the process's signal disposition unasked. Verify by
    // reading back the disposition around run(): it must be untouched.
    var before: std.posix.Sigaction = undefined;
    std.posix.sigaction(.INT, null, &before);

    try startNode();
    var during: std.posix.Sigaction = undefined;
    std.posix.sigaction(.INT, null, &during);
    qnnt.deinit();

    try testing.expectEqual(before.handler.handler, during.handler.handler);
}

test "installSignalHandlers requests a stop instead of killing the process" {
    try startNode();
    qnnt.installSignalHandlers();

    try testing.expect(!qnnt.stopRequested());

    // Raising SIGINT here would have terminated the test binary outright with the old
    // _exit(0) handler; now it only sets the flag, so the test survives to assert it.
    try std.posix.raise(.INT);
    try testing.expect(qnnt.stopRequested());

    qnnt.deinit();
    // deinit clears the flag path for the next run(), so a node can be restarted.
    try startNode();
    try testing.expect(!qnnt.stopRequested());
    qnnt.deinit();
}

// ---------------------------------------------------------------- buffered queue

test "queue delivers, tags by topic, and blocks until something arrives" {
    try startNode();
    defer qnnt.deinit();

    try testing.expect(qnnt.reserveQueue(64));
    try testing.expect(qnnt.runPublisher("test/q", source, 1_000, null));
    try testing.expect(qnnt.subscribeQueue("test/q", .text));

    var batch: [32]QueuedMessage = undefined;

    // A blocking poll must return as soon as a message lands, not after the timeout.
    const start = qnnt.nowMicros();
    var got = qnnt.poll(&batch, 3_000);
    const waited_us = qnnt.nowMicros() - start;

    try testing.expect(got.len > 0);
    try testing.expect(waited_us < 3_000_000); // woken by arrival, not by the timeout
    for (got) |msg| {
        try testing.expectEqualStrings("test/q", msg.topic);
        try testing.expectEqualStrings("tick\n", msg.data);
        try testing.expect(msg.received_us > 0);
    }

    // A zero timeout never blocks.
    const immediate = qnnt.nowMicros();
    _ = qnnt.poll(&batch, 0);
    try testing.expect(qnnt.nowMicros() - immediate < 100_000);

    // Draining repeatedly keeps working, which is what exercises buffer recycling.
    var total: usize = got.len;
    for (0..5) |_| {
        got = qnnt.poll(&batch, 1_000);
        total += got.len;
    }
    try testing.expect(total > 1);
}

test "an empty queue with a zero timeout returns nothing rather than waiting" {
    try startNode();
    defer qnnt.deinit();

    try testing.expect(qnnt.reserveQueue(8));
    var batch: [4]QueuedMessage = undefined;
    try testing.expectEqual(@as(usize, 0), qnnt.poll(&batch, 0).len);
}

test "a full queue drops the newest and counts it" {
    try startNode();
    defer qnnt.deinit();

    // Two slots against a 1 kHz publisher: overflow is certain.
    try testing.expect(qnnt.reserveQueue(2));
    try testing.expect(qnnt.runPublisher("test/q-full", source, 1_000, null));
    try testing.expect(qnnt.subscribeQueue("test/q-full", .text));

    qnnt.sleepMs(400); // fill it and keep pushing, without draining

    try testing.expect(qnnt.queueDropped() > 0);

    // What survived is still intact -- dropping the newest must not corrupt the rest.
    var batch: [4]QueuedMessage = undefined;
    const got = qnnt.poll(&batch, 0);
    try testing.expect(got.len > 0);
    try testing.expect(got.len <= 2);
    for (got) |msg| try testing.expectEqualStrings("tick\n", msg.data);
}

test "realtime priority is accepted only where it can be honoured" {
    const builtin = @import("builtin");

    if (builtin.os.tag == .linux) {
        // Accepted here means "the request is valid", not "the kernel will grant it":
        // privilege is only discoverable when a thread tries, and is reported then.
        try testing.expect(qnnt.setRealtimePriority(10));
        try testing.expectEqual(@as(u8, 10), qnnt.realtimePriority());

        // Out of the SCHED_FIFO range, which the kernel is asked for rather than assumed.
        try testing.expect(!qnnt.setRealtimePriority(200));
        try testing.expectEqual(@as(u8, 10), qnnt.realtimePriority());
    } else {
        // Refused rather than silently doing nothing useful: on macOS a POSIX priority
        // would not deliver what a caller asking for SCHED_FIFO is asking for.
        try testing.expect(!qnnt.setRealtimePriority(10));
        try testing.expectEqual(@as(u8, 0), qnnt.realtimePriority());
    }

    // Leave it off: every later test spawns workers, and they would each try to promote
    // themselves and complain about it.
    try testing.expect(qnnt.setRealtimePriority(0));
    try testing.expectEqual(@as(u8, 0), qnnt.realtimePriority());
}

test "memory locking is accepted only where it is implemented" {
    const builtin = @import("builtin");

    if (builtin.os.tag == .linux) {
        try testing.expect(qnnt.setLockMemory(true));
        try testing.expect(qnnt.lockMemory());
    } else {
        try testing.expect(!qnnt.setLockMemory(true));
        try testing.expect(!qnnt.lockMemory());
    }

    // Leave it off. MCL_FUTURE would apply to every allocation the rest of the suite makes,
    // and on a machine with a low RLIMIT_MEMLOCK that turns into allocation failures in
    // tests that have nothing to do with this one.
    try testing.expect(qnnt.setLockMemory(false));
    try testing.expect(!qnnt.lockMemory());
}
