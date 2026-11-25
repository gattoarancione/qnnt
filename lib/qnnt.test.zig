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
const fed = @import("./federation.zig");

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

// -- connection events ------------------------------------------------------------------

const EventLog = struct {
    // Handlers fire on several library threads at once, so the slot is claimed atomically
    // and each writer then owns its own entry.
    var kinds: [64]qnnt.Event = undefined;
    var topics: [64][48]u8 = undefined;
    var topic_lens: [64]usize = @splat(0);
    var count = std.atomic.Value(usize).init(0);

    fn record(event: qnnt.Event, topic: []const u8, _: []const u8, _: usize, _: ?*anyopaque) void {
        const slot = count.fetchAdd(1, .monotonic);
        if (slot >= kinds.len) return;
        kinds[slot] = event;
        const n = @min(topic.len, topics[slot].len);
        @memcpy(topics[slot][0..n], topic[0..n]);
        topic_lens[slot] = n;
    }

    fn reset() void {
        count.store(0, .monotonic);
    }

    fn seen(event: qnnt.Event, topic: []const u8) bool {
        const n = @min(count.load(.monotonic), kinds.len);
        for (kinds[0..n], topics[0..n], topic_lens[0..n]) |k, *t, len| {
            if (k == event and std.mem.eql(u8, t[0..len], topic)) return true;
        }
        return false;
    }
};

fn eventSource(_: []const u8, _: ?*anyopaque) ?[]const u8 {
    return "tick\n";
}

fn eventSink(_: []const u8, _: []const u8, _: ?*anyopaque) void {}

test "a publisher learns when a subscriber connects, and can wait for one" {
    EventLog.reset();
    try startNode();
    defer qnnt.deinit();

    qnnt.setEventHandler(EventLog.record, null);
    defer qnnt.setEventHandler(null, null);

    try testing.expect(qnnt.runPublisher("test/events", eventSource, 20_000, null));

    // Nobody is connected yet, so a zero-timeout wait must say so rather than block.
    try testing.expectEqual(@as(usize, 0), qnnt.subscriberCount("test/events"));
    try testing.expect(!qnnt.waitForSubscriber("test/events", 0));

    try testing.expect(qnnt.subscribe("test/events", eventSink, null));

    // This is the call the mesh examples wanted instead of a fixed sleep.
    try testing.expect(qnnt.waitForSubscriber("test/events", 5000));
    try testing.expect(qnnt.subscriberCount("test/events") >= 1);

    try testing.expect(EventLog.seen(.subscriber_connected, "test/events"));
    // The subscriber side of the same connection.
    try testing.expect(EventLog.seen(.publisher_connected, "test/events"));
}

test "a quiet subscription is reported stale only when a timeout is set" {
    EventLog.reset();
    try startNode();
    defer qnnt.deinit();

    qnnt.setEventHandler(EventLog.record, null);
    defer qnnt.setEventHandler(null, null);
    // Off by default: a topic may legitimately be quiet.
    try testing.expectEqual(@as(u64, 0), qnnt.staleTimeout());
    qnnt.setStaleTimeout(300);
    defer qnnt.setStaleTimeout(0);

    // A publisher that never publishes: the subscription connects and then hears nothing.
    try testing.expect(qnnt.runPublisher("test/quiet", null, null, null));
    try testing.expect(qnnt.subscribe("test/quiet", eventSink, null));
    try testing.expect(qnnt.waitForSubscriber("test/quiet", 5000));

    // The sweeper wakes every 200 ms, so allow it a few passes past the timeout.
    var waited: usize = 0;
    while (waited < 3000 and !EventLog.seen(.publisher_stale, "test/quiet")) : (waited += 100) {
        qnnt.sleepMs(100);
    }
    try testing.expect(EventLog.seen(.publisher_stale, "test/quiet"));
}

test "events are buffered for a poller, not only pushed to a handler" {
    try startNode();
    defer qnnt.deinit();

    // No handler registered at all: the queue is filled regardless, which is what stops a
    // consumer losing the connections that happen before its first poll.
    try testing.expect(qnnt.runPublisher("test/polled", eventSource, 20_000, null));
    try testing.expect(qnnt.subscribe("test/polled", eventSink, null));
    try testing.expect(qnnt.waitForSubscriber("test/polled", 5000));

    var buffer: [16]qnnt.PolledEvent = undefined;
    var saw_subscriber = false;
    var saw_publisher = false;
    var count: usize = 0;

    // Drain a few times: the two sides of the connection are established by different
    // threads, so they need not both be queued by the time the wait returns.
    var attempts: usize = 0;
    while (attempts < 50 and !(saw_subscriber and saw_publisher)) : (attempts += 1) {
        for (qnnt.pollEvents(&buffer)) |event| {
            count += 1;
            if (event.event == .subscriber_connected and
                std.mem.eql(u8, event.topic, "test/polled"))
            {
                saw_subscriber = true;
                // The count is the point: it is what lets a publisher wait for a known
                // number of peers rather than merely the first.
                try testing.expect(event.subscribers >= 1);
                try testing.expect(event.peer.len > 0);
            }
            if (event.event == .publisher_connected and
                std.mem.eql(u8, event.topic, "test/polled"))
            {
                saw_publisher = true;
            }
        }
        if (!(saw_subscriber and saw_publisher)) qnnt.sleepMs(20);
    }

    try testing.expect(saw_subscriber);
    try testing.expect(saw_publisher);

    // Draining is destructive: what has been handed over is gone.
    var again: [16]qnnt.PolledEvent = undefined;
    try testing.expectEqual(@as(usize, 0), qnnt.pollEvents(&again).len);
    try testing.expectEqual(@as(u64, 0), qnnt.eventsDropped());
}

test "listTopics reads back the topics the registry is publishing" {
    try startNode();
    defer qnnt.deinit();

    // Two topics, so the test would catch a parser that returns only the first row, and a
    // name with a slash, since that is what every real topic looks like.
    try testing.expect(qnnt.runPublisher("test/listed-one", eventSource, 20_000, null));
    try testing.expect(qnnt.runPublisher("test/listed/two", eventSource, 20_000, null));

    var names: [32][]const u8 = undefined;
    var buf: [1024]u8 = undefined;

    // Registration is another thread's work, so the listing may be empty for a moment.
    var found_one = false;
    var found_two = false;
    var attempts: usize = 0;
    while (attempts < 50 and !(found_one and found_two)) : (attempts += 1) {
        const n = try qnnt.listTopics(&names, &buf);
        for (names[0..n]) |name| {
            if (std.mem.eql(u8, name, "test/listed-one")) found_one = true;
            if (std.mem.eql(u8, name, "test/listed/two")) found_two = true;
        }
        if (found_one and found_two) break;
        qnnt.sleepMs(20);
    }

    try testing.expect(found_one);
    try testing.expect(found_two);

    // Only the first column, and nothing from the header or the summary: a row's remaining
    // columns are addresses and counts, and both bracketing lines start with '#'.
    const n = try qnnt.listTopics(&names, &buf);
    for (names[0..n]) |name| {
        try testing.expect(name.len > 0);
        try testing.expect(!std.mem.startsWith(u8, name, "#"));
        try testing.expect(std.mem.indexOfAny(u8, name, " \t") == null);
        try testing.expect(!std.mem.eql(u8, name, "topic"));
    }

    // The caller's buffer bounds the answer instead of overrunning it.
    var tiny: [1][]const u8 = undefined;
    try testing.expect(try qnnt.listTopics(&tiny, &buf) <= 1);
}

test "the frame cap applies to publishing as well as subscribing" {
    try startNode();
    defer qnnt.deinit();

    // The default is generous enough for a 1080p depth frame, which a megabyte was not.
    try testing.expect(qnnt.maxFrameBytes() >= 6 * 1024 * 1024);

    try testing.expect(qnnt.runPublisher("test/capped", null, null, null));

    // Small enough: fine.
    const ok = try testing.allocator.alloc(u8, 1024);
    defer testing.allocator.free(ok);
    @memset(ok, 0);
    try qnnt.publish("test/capped", ok);

    // Tighten the cap, then exceed it. The publish fails HERE rather than at every
    // subscriber, which is the whole point: an oversized frame makes a subscriber break its
    // read loop and reconnect into the same frame, while the producer sees nothing wrong.
    try testing.expect(qnnt.setMaxFrameBytes(4096));
    try testing.expectEqual(@as(usize, 4096), qnnt.maxFrameBytes());

    const too_big = try testing.allocator.alloc(u8, 8192);
    defer testing.allocator.free(too_big);
    @memset(too_big, 0);
    try testing.expectError(error.FrameTooLarge, qnnt.publish("test/capped", too_big));

    // Still fine at exactly the limit.
    try qnnt.publish("test/capped", too_big[0..4096]);

    // A nonsense cap is refused rather than accepted and then blocking everything.
    try testing.expect(!qnnt.setMaxFrameBytes(0));
    try testing.expect(!qnnt.setMaxFrameBytes(16));
    try testing.expectEqual(@as(usize, 4096), qnnt.maxFrameBytes());

    try testing.expect(qnnt.setMaxFrameBytes(qnnt.default_max_frame_bytes));
}

// A pattern subscriber's sink. Records which topics it heard from, which is the only thing
// the pattern tests care about — the payload path is `subscribe`'s and tested above.
const PatternSink = struct {
    // Same shape as EventLog: one pattern subscriber runs a worker per joined topic, so the
    // slot is claimed atomically and the length is published last, with release, so a
    // reader never sees a name that is only half written.
    var names: [32][64]u8 = undefined;
    var lens: [32]std.atomic.Value(usize) = @splat(std.atomic.Value(usize).init(0));
    var claimed = std.atomic.Value(usize).init(0);

    fn reset() void {
        for (&lens) |*l| l.store(0, .monotonic);
        claimed.store(0, .monotonic);
    }

    fn record(topic: []const u8, _: []const u8, _: ?*anyopaque) void {
        const slot = claimed.fetchAdd(1, .monotonic);
        if (slot >= names.len or topic.len > names[slot].len) return;
        @memcpy(names[slot][0..topic.len], topic);
        lens[slot].store(topic.len, .release);
    }

    fn seen(topic: []const u8) bool {
        for (0..names.len) |i| {
            const n = lens[i].load(.acquire);
            if (n != 0 and std.mem.eql(u8, names[i][0..n], topic)) return true;
        }
        return false;
    }

    fn waitFor(topic: []const u8, ms: usize) bool {
        var waited: usize = 0;
        while (waited < ms) : (waited += 25) {
            if (seen(topic)) return true;
            qnnt.sleepMs(25);
        }
        return seen(topic);
    }
};

test "subscribePattern joins matching topics and ignores the rest" {
    PatternSink.reset();
    try startNode();
    defer qnnt.deinit();

    // Two that match and one that does not. The near-miss matters: `bus/*` must not be
    // read as "anything containing bus", which is how a substring check would behave.
    try testing.expect(qnnt.runPublisher("test/bus/left", source, 50_000, null));
    try testing.expect(qnnt.runPublisher("test/bus/right", source, 50_000, null));
    try testing.expect(qnnt.runPublisher("test/busy-elsewhere", source, 50_000, null));

    try testing.expect(qnnt.subscribePattern("test/bus/*", PatternSink.record, null, 100));

    try testing.expect(PatternSink.waitFor("test/bus/left", 5000));
    try testing.expect(PatternSink.waitFor("test/bus/right", 5000));

    // Given both matches arrived, a rescan has certainly run, so the near-miss having
    // stayed away is a result and not just a race we won.
    try testing.expect(!PatternSink.seen("test/busy-elsewhere"));
}

test "subscribePattern joins a topic that appears after it started" {
    PatternSink.reset();
    try startNode();
    defer qnnt.deinit();

    // Subscribing to nothing at all: the pattern has no match when it starts, which is the
    // arrangement `subscribe` cannot express and the reason this call polls.
    try testing.expect(qnnt.subscribePattern("test/late/*", PatternSink.record, null, 100));
    qnnt.sleepMs(300);
    try testing.expect(!PatternSink.seen("test/late/arrival"));

    try testing.expect(qnnt.runPublisher("test/late/arrival", source, 50_000, null));
    try testing.expect(PatternSink.waitFor("test/late/arrival", 5000));
}

test "subscribePattern refuses an empty pattern" {
    try startNode();
    defer qnnt.deinit();

    // Empty matches nothing in the matcher, so this would be a worker polling for ever
    // over a pattern that can never join anything.
    try testing.expect(!qnnt.subscribePattern("", PatternSink.record, null, 100));
}

test "a zero rescan joins what exists now and then stops looking" {
    PatternSink.reset();
    try startNode();
    defer qnnt.deinit();

    try testing.expect(qnnt.runPublisher("test/once/early", source, 50_000, null));
    // Registered before the pattern starts, so the single pass is certain to see it.
    var waited: usize = 0;
    var names: [32][]const u8 = undefined;
    var buf: [1024]u8 = undefined;
    while (waited < 2000) : (waited += 25) {
        const n = qnnt.listTopics(&names, &buf) catch 0;
        var there = false;
        for (names[0..n]) |name| {
            if (std.mem.eql(u8, name, "test/once/early")) there = true;
        }
        if (there) break;
        qnnt.sleepMs(25);
    }

    try testing.expect(qnnt.subscribePattern("test/once/*", PatternSink.record, null, 0));
    try testing.expect(PatternSink.waitFor("test/once/early", 5000));

    // Anything appearing afterwards is not picked up: this is the one-shot capture shape,
    // where polling for ever would keep a process alive that meant to take a snapshot.
    try testing.expect(qnnt.runPublisher("test/once/later", source, 50_000, null));
    qnnt.sleepMs(1500);
    try testing.expect(!PatternSink.seen("test/once/later"));
}

/// The port the registry says `topic` should use. Asked the way a publisher asks.
fn askPort(topic: []const u8, skip: u16) !u16 {
    var cmd: [128]u8 = undefined;
    const command = if (skip == 0)
        try std.fmt.bufPrint(&cmd, "port {s}", .{topic})
    else
        try std.fmt.bufPrint(&cmd, "port {s} skip {d}", .{ topic, skip });

    var buf: [512]u8 = undefined;
    const reply = try qnnt.registryCommand(command, &buf);
    var lines = std.mem.splitScalar(u8, reply, '\n');
    while (lines.next()) |line| {
        const text = std.mem.trim(u8, line, " \t\r");
        if (text.len == 0 or text[0] == '#') continue;
        return std.fmt.parseInt(u16, text, 10) catch error.NotAPort;
    }
    return error.NoReply;
}

test "with no range the registry tells a publisher to take what it likes" {
    try startNode();
    defer qnnt.deinit();

    // The default, and the whole existing behaviour: port 0, chosen by the OS.
    try testing.expectEqual(@as(u16, 0), try askPort("test/ports/none", 0));
}

test "publishers take their ports from the configured range" {
    try testing.expect(qnnt.setPublisherPorts(23400, 23409));
    defer _ = qnnt.setPublisherPorts(0, 0);

    try startNode();
    defer qnnt.deinit();

    try testing.expect(qnnt.runPublisher("test/ports/one", null, null, null));
    try testing.expect(qnnt.runPublisher("test/ports/two", null, null, null));

    // Registered asynchronously, so wait for the directory rather than guessing.
    var names: [32][]const u8 = undefined;
    var buf: [2048]u8 = undefined;
    var waited: usize = 0;
    while (waited < 3000) : (waited += 25) {
        const n = try qnnt.listTopics(&names, &buf);
        var seen: usize = 0;
        for (names[0..n]) |name| {
            if (std.mem.startsWith(u8, name, "test/ports/")) seen += 1;
        }
        if (seen >= 2) break;
        qnnt.sleepMs(25);
    }

    const one = try askPort("test/ports/one", 0);
    const two = try askPort("test/ports/two", 0);
    try testing.expect(one >= 23400 and one <= 23409);
    try testing.expect(two >= 23400 and two <= 23409);
    // Two topics never share a port, or one publisher's bind would fail against the other.
    try testing.expect(one != two);

    // STICKY. Asking again gives the same answer, because the directory already holds it.
    // This is what makes a stale entry harmless: a restarting publisher reclaims its own
    // port, so an address a peer is still serving points at the topic it always meant.
    try testing.expectEqual(one, try askPort("test/ports/one", 0));
    try testing.expectEqual(two, try askPort("test/ports/two", 0));

    // Unless the asker says that port just failed to bind, which is the race the registry
    // cannot see: it names a port, it does not hold the socket.
    const moved = try askPort("test/ports/one", one);
    try testing.expect(moved != one);
    try testing.expect(moved >= 23400 and moved <= 23409);
}

test "a freed port is the last to be handed out again, not the first" {
    try testing.expect(qnnt.setPublisherPorts(23500, 23503));
    defer _ = qnnt.setPublisherPorts(0, 0);

    try startNode();
    defer qnnt.deinit();

    // Four topics that never register, so nothing is held and each ask allocates afresh.
    // Round-robin means consecutive asks walk the range rather than repeating its floor.
    const a = try askPort("test/rr/a", 0);
    const b = try askPort("test/rr/b", 0);
    const c = try askPort("test/rr/c", 0);
    try testing.expect(a != b and b != c and a != c);

    // Lowest-free allocation would have answered 23500 every time, since nothing is
    // registered -- and a port freed by a dead publisher would be reissued immediately,
    // while a peer may still be serving the address that used to mean it.
    try testing.expect(a == 23500);
    try testing.expect(b == 23501);
    try testing.expect(c == 23502);
}

test "a full range is refused rather than quietly falling back" {
    try testing.expect(qnnt.setPublisherPorts(23600, 23601));
    defer _ = qnnt.setPublisherPorts(0, 0);

    try startNode();
    defer qnnt.deinit();

    try testing.expect(qnnt.runPublisher("test/full/one", null, null, null));
    try testing.expect(qnnt.runPublisher("test/full/two", null, null, null));

    var names: [32][]const u8 = undefined;
    var buf: [2048]u8 = undefined;
    var waited: usize = 0;
    while (waited < 3000) : (waited += 25) {
        const n = try qnnt.listTopics(&names, &buf);
        var seen: usize = 0;
        for (names[0..n]) |name| {
            if (std.mem.startsWith(u8, name, "test/full/")) seen += 1;
        }
        if (seen >= 2) break;
        qnnt.sleepMs(25);
    }

    // Both slots are held by registered publishers, so a third topic cannot be placed. The
    // reply is an error, NOT 0: answering 0 would give the publisher an ephemeral port,
    // which works locally and is unreachable through the firewall the range exists for.
    try testing.expectError(error.NotAPort, askPort("test/full/three", 0));
}

test "the range is refused when it is not a range" {
    try testing.expect(qnnt.setPublisherPorts(2300, 2399));
    defer _ = qnnt.setPublisherPorts(0, 0);

    // High below low, and port 0 as a bound, are both configuration errors rather than
    // something to interpret.
    try testing.expect(!qnnt.setPublisherPorts(2400, 2300));
    try testing.expect(!qnnt.setPublisherPorts(0, 2300));

    var low: u16 = 0;
    var high: u16 = 0;
    try testing.expect(qnnt.parsePublisherPorts("2300-2399", &low, &high));
    try testing.expectEqual(@as(u16, 2300), low);
    try testing.expectEqual(@as(u16, 2399), high);

    // A single port is a range of one, which is what pinning one topic looks like.
    try testing.expect(qnnt.parsePublisherPorts("2300", &low, &high));
    try testing.expectEqual(low, high);

    try testing.expect(!qnnt.parsePublisherPorts("2399-2300", &low, &high));
    try testing.expect(!qnnt.parsePublisherPorts("", &low, &high));
    try testing.expect(!qnnt.parsePublisherPorts("2300-", &low, &high));
    try testing.expect(!qnnt.parsePublisherPorts("http", &low, &high));
}

test "a peer's port inside our range does not consume a slot here" {
    // The range is a HOST resource. A peer running the same range fills the directory with
    // ports bound on ITS machine; counting those would make this host report itself out of
    // ports while every one of them was free. Only entries registered here hold a port here.
    try testing.expect(qnnt.setPublisherPorts(23700, 23701));
    defer _ = qnnt.setPublisherPorts(0, 0);

    try startNode();
    defer qnnt.deinit();

    // Two slots, one taken locally.
    try testing.expect(qnnt.runPublisher("test/peerport/mine", null, null, null));
    var names: [32][]const u8 = undefined;
    var buf: [2048]u8 = undefined;
    var waited: usize = 0;
    while (waited < 3000) : (waited += 25) {
        const n = try qnnt.listTopics(&names, &buf);
        for (names[0..n]) |name| {
            if (std.mem.eql(u8, name, "test/peerport/mine")) break;
        } else {
            qnnt.sleepMs(25);
            continue;
        }
        break;
    }

    // A federated entry arrives carrying the other slot, on another host's address. Fed in
    // the way a standby learns one, which is the path that marks an entry as NOT local.
    const learned = fed.applyMirrorEntries(
        "fed-entry 5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a 1 test/peerport/theirs 10.9.9.9 23701 0\n",
        "10.9.9.9",
    );
    try testing.expectEqual(@as(u64, 1), learned);

    // The remaining slot is still ours to give, because 23701 is bound on 10.9.9.9.
    const port = try askPort("test/peerport/other", 0);
    try testing.expectEqual(@as(u16, 23701), port);
}

// ---------------------------------------------------------------- per-topic teardown
//
// The interesting failure here is the same one the rest of this file exists for: a worker
// still running after the call returned. `removePublisher` and `removeSubscriber` join,
// so a regression shows up as a hang or as a worker touching freed memory, not as a
// failed assertion. What the assertions add is that the topic is actually *gone* --
// unregistered, and not merely quiet.

fn waitForTopic(name: []const u8, want: bool, timeout_ms: usize) !void {
    var names: [64][]const u8 = undefined;
    var buf: [4096]u8 = undefined;
    var waited: usize = 0;
    while (waited < timeout_ms) : (waited += 25) {
        const n = qnnt.listTopics(&names, &buf) catch 0;
        var seen = false;
        for (names[0..n]) |listed| {
            if (std.mem.eql(u8, listed, name)) seen = true;
        }
        if (seen == want) return;
        qnnt.sleepMs(25);
    }
    return error.TopicDidNotSettle;
}

test "removePublisher stops the publisher and drops its registration" {
    try startNode();
    defer qnnt.deinit();

    try testing.expect(qnnt.runPublisher("test/remove/pub", &source, 1000, null));
    try waitForTopic("test/remove/pub", true, 3000);

    try testing.expect(qnnt.removePublisher("test/remove/pub"));

    // Gone from the directory, and it stays gone: the refresh loop was joined before the
    // `unpub` went out, so nothing re-registers it afterwards.
    try waitForTopic("test/remove/pub", false, 3000);
    qnnt.sleepMs(300);
    try waitForTopic("test/remove/pub", false, 500);
}

test "removePublisher reports whether there was anything to remove" {
    try startNode();
    defer qnnt.deinit();

    try testing.expect(!qnnt.removePublisher("test/remove/never-published"));

    try testing.expect(qnnt.runPublisher("test/remove/once", null, null, null));
    try waitForTopic("test/remove/once", true, 3000);

    try testing.expect(qnnt.removePublisher("test/remove/once"));
    // Second call has nothing left: the token was detached and freed by the first.
    try testing.expect(!qnnt.removePublisher("test/remove/once"));
}

test "removeSubscriber stops a subscription" {
    try startNode();
    defer qnnt.deinit();

    try testing.expect(qnnt.runPublisher("test/remove/feed", &source, 1000, null));
    try testing.expect(qnnt.subscribe("test/remove/feed", &onMessage, null));
    qnnt.sleepMs(300); // let it connect, so the join has a live read to break

    try testing.expect(qnnt.removeSubscriber("test/remove/feed"));
    try testing.expect(!qnnt.removeSubscriber("test/remove/feed"));

    // The publisher is untouched by its subscriber going away.
    try waitForTopic("test/remove/feed", true, 3000);
}

test "removeSubscriber stops a frames subscription too" {
    try startNode();
    defer qnnt.deinit();

    try testing.expect(qnnt.subscribeFrames("test/remove/frames", &onFrame, null));
    qnnt.sleepMs(100); // parked in resolve, which is the retry path rather than a read

    try testing.expect(qnnt.removeSubscriber("test/remove/frames"));
    try testing.expect(!qnnt.removeSubscriber("test/remove/frames"));
}

test "removeSubscriber takes every subscription on the topic" {
    try startNode();
    defer qnnt.deinit();

    try testing.expect(qnnt.subscribe("test/remove/twice", &onMessage, null));
    try testing.expect(qnnt.subscribe("test/remove/twice", &onMessage, null));
    qnnt.sleepMs(100);

    // One call, both gone -- otherwise the second would outlive the node's own bookkeeping
    // and the next call would find it.
    try testing.expect(qnnt.removeSubscriber("test/remove/twice"));
    try testing.expect(!qnnt.removeSubscriber("test/remove/twice"));
}

test "a publisher can be removed and the topic published again" {
    try startNode();
    defer qnnt.deinit();

    try testing.expect(qnnt.runPublisher("test/remove/cycle", &source, 1000, null));
    try waitForTopic("test/remove/cycle", true, 3000);
    try testing.expect(qnnt.removePublisher("test/remove/cycle"));
    try waitForTopic("test/remove/cycle", false, 3000);

    // The name was freed with the first token, so this is a fresh allocation under the
    // same string -- the case that catches a token holding a borrowed slice.
    try testing.expect(qnnt.runPublisher("test/remove/cycle", &source, 1000, null));
    try waitForTopic("test/remove/cycle", true, 3000);
    try testing.expect(qnnt.removePublisher("test/remove/cycle"));
}

test "removing one topic leaves the others running" {
    try startNode();
    defer qnnt.deinit();

    try testing.expect(qnnt.runPublisher("test/remove/keep-a", &source, 1000, null));
    try testing.expect(qnnt.runPublisher("test/remove/keep-b", &source, 1000, null));
    try waitForTopic("test/remove/keep-a", true, 3000);
    try waitForTopic("test/remove/keep-b", true, 3000);

    try testing.expect(qnnt.removePublisher("test/remove/keep-a"));

    try waitForTopic("test/remove/keep-a", false, 3000);
    // The whole point of a per-topic token: b's accept loop and refresh were never
    // signalled, so it is still registering long after a was joined.
    qnnt.sleepMs(300);
    try waitForTopic("test/remove/keep-b", true, 1000);
}

test "deinit after removing everything, and after removing nothing" {
    try startNode();
    try testing.expect(qnnt.runPublisher("test/remove/all", &source, 1000, null));
    try testing.expect(qnnt.subscribe("test/remove/all", &onMessage, null));
    qnnt.sleepMs(200);
    try testing.expect(qnnt.removePublisher("test/remove/all"));
    try testing.expect(qnnt.removeSubscriber("test/remove/all"));
    qnnt.deinit();

    // And the other order: tokens still live when deinit runs, so joinTopicTokens is what
    // reaps them. A leak here hangs the join or faults on a torn-down `io`.
    try startNode();
    try testing.expect(qnnt.runPublisher("test/remove/all", &source, 1000, null));
    try testing.expect(qnnt.subscribe("test/remove/all", &onMessage, null));
    qnnt.sleepMs(200);
    qnnt.deinit();
}

test "a topic removed from under a glob is not rejoined" {
    try startNode();
    defer qnnt.deinit();

    try testing.expect(qnnt.runPublisher("test/remove/glob-a", &source, 1000, null));
    try waitForTopic("test/remove/glob-a", true, 3000);

    // Rescan fast, so the "did it come back" window below covers several passes.
    try testing.expect(qnnt.subscribePattern("test/remove/glob-*", &onMessage, null, 100));

    // Wait for the pattern to have joined it -- observable as there being a subscription
    // to remove.
    var waited: usize = 0;
    while (waited < 3000) : (waited += 50) {
        if (qnnt.removeSubscriber("test/remove/glob-a")) break;
        qnnt.sleepMs(50);
    } else return error.PatternNeverJoined;

    // Ten rescans' worth. `joined` is append-only, so the name is still in it and the
    // pattern skips it -- if it rejoined, there would be a subscription to remove again.
    qnnt.sleepMs(1000);
    try testing.expect(!qnnt.removeSubscriber("test/remove/glob-a"));
}

test "removing after deinit is refused, not a crash" {
    try startNode();
    try testing.expect(qnnt.runPublisher("test/remove/after", &source, 1000, null));
    try testing.expect(qnnt.subscribe("test/remove/after", &onMessage, null));
    qnnt.sleepMs(200);
    qnnt.deinit();

    // The natural place to call one of these is on the way out, which is easily one line
    // too late. Both mutexes would otherwise reach for an `io` that deinit tore down.
    try testing.expect(!qnnt.removePublisher("test/remove/after"));
    try testing.expect(!qnnt.removeSubscriber("test/remove/after"));
}

// ---------------------------------------------------------------- request / reply

fn echoHandler(_: []const u8, request: []const u8, _: ?*anyopaque) ?[]const u8 {
    // Static, because the reply is written to the socket AFTER this returns.
    const store = struct {
        var buf: [4096]u8 = undefined;
    };
    if (request.len > store.buf.len) return null;
    @memcpy(store.buf[0..request.len], request);
    return store.buf[0..request.len];
}

fn refusingHandler(_: []const u8, _: []const u8, _: ?*anyopaque) ?[]const u8 {
    return null;
}

fn rpcCountingHandler(_: []const u8, _: []const u8, context: ?*anyopaque) ?[]const u8 {
    const seen: *usize = @ptrCast(@alignCast(context.?));
    seen.* += 1;
    return "ok";
}

/// Responders register asynchronously, like publishers, so wait rather than guess.
fn waitForProcedure(name: []const u8, timeout_ms: usize) !void {
    var out: [256]u8 = undefined;
    var len: usize = 0;
    var waited: usize = 0;
    while (waited < timeout_ms) : (waited += 25) {
        // Generous per-probe timeout: an absent procedure answers `no_procedure` at once,
        // so this only ever costs time against a responder that is slow on purpose.
        if (qnnt.request(name, "ping", 2000, &out, &len) == .ok) return;
        qnnt.sleepMs(25);
    }
    return error.ProcedureNeverAppeared;
}

test "a request reaches the responder and the reply comes back" {
    try startNode();
    defer qnnt.deinit();

    try testing.expect(qnnt.addResponder("test/rpc/echo", &echoHandler, null));
    try waitForProcedure("test/rpc/echo", 3000);

    var out: [256]u8 = undefined;
    var len: usize = 0;
    try testing.expectEqual(qnnt.RpcStatus.ok, qnnt.request("test/rpc/echo", "hello", 2000, &out, &len));
    try testing.expectEqualStrings("hello", out[0..len]);
}

test "an empty request and an empty reply are carried, not confused with failure" {
    try startNode();
    defer qnnt.deinit();

    try testing.expect(qnnt.addResponder("test/rpc/echo2", &echoHandler, null));
    try waitForProcedure("test/rpc/echo2", 3000);

    var out: [64]u8 = undefined;
    var len: usize = 1;
    // Zero bytes in, zero bytes out, and still `ok` -- the status byte is what carries the
    // difference between "nothing" and "no answer", which a bare length cannot.
    try testing.expectEqual(qnnt.RpcStatus.ok, qnnt.request("test/rpc/echo2", "", 2000, &out, &len));
    try testing.expectEqual(@as(usize, 0), len);
}

test "a handler that declines is reported as refused, not as an empty reply" {
    try startNode();
    defer qnnt.deinit();

    try testing.expect(qnnt.addResponder("test/rpc/no", &refusingHandler, null));

    var out: [64]u8 = undefined;
    var len: usize = 0;
    var waited: usize = 0;
    while (waited < 3000) : (waited += 25) {
        if (qnnt.request("test/rpc/no", "x", 500, &out, &len) == .refused) break;
        qnnt.sleepMs(25);
    } else return error.ProcedureNeverAppeared;

    try testing.expectEqual(qnnt.RpcStatus.refused, qnnt.request("test/rpc/no", "x", 2000, &out, &len));
    try testing.expectEqual(@as(usize, 0), len);
}

test "an unknown procedure fails fast instead of waiting out the timeout" {
    try startNode();
    defer qnnt.deinit();

    var out: [64]u8 = undefined;
    var len: usize = 0;
    const began = qnnt.nowMicros();
    // A 10s timeout that must NOT be waited out: an unresolvable name is known immediately.
    try testing.expectEqual(
        qnnt.RpcStatus.no_procedure,
        qnnt.request("test/rpc/nobody", "x", 10_000, &out, &len),
    );
    const elapsed_us = qnnt.nowMicros() - began;
    try testing.expect(elapsed_us < 2_000_000);
}

test "a topic is not a procedure, and a procedure is not a topic" {
    try startNode();
    defer qnnt.deinit();

    try testing.expect(qnnt.runPublisher("test/rpc/stream", &source, 1000, null));
    try testing.expect(qnnt.addResponder("test/rpc/proc", &echoHandler, null));
    try waitForProcedure("test/rpc/proc", 3000);

    // Calling a topic is refused rather than connecting to a publisher and waiting for a
    // reply that stream will never send.
    var out: [64]u8 = undefined;
    var len: usize = 0;
    try testing.expectEqual(
        qnnt.RpcStatus.no_procedure,
        qnnt.request("test/rpc/stream", "x", 1000, &out, &len),
    );

    // And the mirror: resolving a procedure as a topic is an error, not an endpoint.
    var buf: [256]u8 = undefined;
    const reply = try qnnt.registryCommand("sub test/rpc/proc", &buf);
    try testing.expect(std.mem.indexOf(u8, reply, "not a topic") != null);
}

test "requestBegin returns immediately and the reply is drained later" {
    try startNode();
    defer qnnt.deinit();

    try testing.expect(qnnt.addResponder("test/rpc/async", &echoHandler, null));
    try waitForProcedure("test/rpc/async", 3000);

    const began = qnnt.nowMicros();
    const id = qnnt.requestBegin("test/rpc/async", "deferred", 3000);
    const call_us = qnnt.nowMicros() - began;

    try testing.expect(id != 0);
    // The whole point: the call returns without waiting for the round trip.
    try testing.expect(call_us < 500_000);

    var out: [8]qnnt.QueuedReply = undefined;
    const replies = qnnt.pollReplies(&out, 5000);
    try testing.expectEqual(@as(usize, 1), replies.len);
    try testing.expectEqual(id, replies[0].id);
    try testing.expectEqual(qnnt.RpcStatus.ok, replies[0].status);
    try testing.expectEqualStrings("deferred", replies[0].data);
    try testing.expectEqualStrings("test/rpc/async", replies[0].procedure);
}

test "a non-blocking request to nowhere completes with a status rather than hanging" {
    try startNode();
    defer qnnt.deinit();

    const id = qnnt.requestBegin("test/rpc/missing", "x", 1000);
    try testing.expect(id != 0);

    var out: [4]qnnt.QueuedReply = undefined;
    const replies = qnnt.pollReplies(&out, 5000);
    try testing.expectEqual(@as(usize, 1), replies.len);
    try testing.expectEqual(id, replies[0].id);
    try testing.expectEqual(qnnt.RpcStatus.no_procedure, replies[0].status);
}

test "several requests in flight all come back, each matched by its own ticket" {
    try startNode();
    defer qnnt.deinit();

    try testing.expect(qnnt.addResponder("test/rpc/many", &echoHandler, null));
    try waitForProcedure("test/rpc/many", 3000);

    var ids: [8]u64 = undefined;
    var payloads: [8][2]u8 = undefined;
    for (0..8) |i| {
        payloads[i] = .{ 'a' + @as(u8, @intCast(i)), 0 };
        ids[i] = qnnt.requestBegin("test/rpc/many", payloads[i][0..1], 5000);
        try testing.expect(ids[i] != 0);
    }

    var seen: usize = 0;
    var matched: [8]bool = @splat(false);
    var waited: usize = 0;
    while (seen < 8 and waited < 10000) : (waited += 50) {
        var out: [8]qnnt.QueuedReply = undefined;
        for (qnnt.pollReplies(&out, 50)) |reply| {
            for (ids, 0..) |id, i| {
                if (id != reply.id) continue;
                try testing.expectEqual(qnnt.RpcStatus.ok, reply.status);
                // The ticket identifies WHICH call, so the payload must be that call's.
                try testing.expectEqualStrings(payloads[i][0..1], reply.data);
                matched[i] = true;
                seen += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 8), seen);
    for (matched) |m| try testing.expect(m);
}

test "removeResponder stops it answering and drops the registration" {
    var calls: usize = 0;
    try startNode();
    defer qnnt.deinit();

    try testing.expect(qnnt.addResponder("test/rpc/gone", &rpcCountingHandler, &calls));
    try waitForProcedure("test/rpc/gone", 3000);
    const answered = calls;
    try testing.expect(answered > 0);

    try testing.expect(qnnt.removeResponder("test/rpc/gone"));
    try testing.expect(!qnnt.removeResponder("test/rpc/gone"));

    var out: [64]u8 = undefined;
    var len: usize = 0;
    var waited: usize = 0;
    while (waited < 3000) : (waited += 25) {
        if (qnnt.request("test/rpc/gone", "x", 500, &out, &len) == .no_procedure) break;
        qnnt.sleepMs(25);
    } else return error.StillRegistered;

    // The handler is not merely unreachable, it is not running: nothing more arrives.
    const after = calls;
    qnnt.sleepMs(200);
    try testing.expectEqual(after, calls);
}

test "a responder can be removed and the name served again" {
    try startNode();
    defer qnnt.deinit();

    try testing.expect(qnnt.addResponder("test/rpc/cycle", &echoHandler, null));
    try waitForProcedure("test/rpc/cycle", 3000);
    try testing.expect(qnnt.removeResponder("test/rpc/cycle"));

    try testing.expect(qnnt.addResponder("test/rpc/cycle", &echoHandler, null));
    try waitForProcedure("test/rpc/cycle", 5000);
}

test "a reply larger than the caller's buffer is reported, not truncated" {
    try startNode();
    defer qnnt.deinit();

    try testing.expect(qnnt.addResponder("test/rpc/big", &echoHandler, null));
    try waitForProcedure("test/rpc/big", 3000);

    const payload = "0123456789" ** 4; // 40 bytes
    var small: [8]u8 = undefined;
    var len: usize = 99;
    try testing.expectEqual(
        qnnt.RpcStatus.too_large,
        qnnt.request("test/rpc/big", payload, 2000, &small, &len),
    );
    // Nothing was written, and the length says so rather than leaving a stale value.
    try testing.expectEqual(@as(usize, 0), len);
}

test "request and removeResponder after deinit are refused, not a crash" {
    try startNode();
    try testing.expect(qnnt.addResponder("test/rpc/after", &echoHandler, null));
    qnnt.sleepMs(200);
    qnnt.deinit();

    try testing.expect(!qnnt.removeResponder("test/rpc/after"));
    try testing.expectEqual(@as(u64, 0), qnnt.requestBegin("test/rpc/after", "x", 100));
}

fn slowHandler(_: []const u8, _: []const u8, _: ?*anyopaque) ?[]const u8 {
    qnnt.sleepMs(800);
    return "slow";
}

test "requestBegin does not wait for a slow responder" {
    try startNode();
    defer qnnt.deinit();

    try testing.expect(qnnt.addResponder("test/rpc/slow", &slowHandler, null));
    try waitForProcedure("test/rpc/slow", 5000);

    // The handler takes 800 ms. A blocking call cannot return in less than that, so the
    // margin below is what separates "started the work" from "did the work" -- an echo
    // responder could not tell them apart, which is why this one sleeps.
    const began = qnnt.nowMicros();
    const id = qnnt.requestBegin("test/rpc/slow", "x", 5000);
    const call_us = qnnt.nowMicros() - began;

    try testing.expect(id != 0);
    try testing.expect(call_us < 200_000);

    // And the reply still arrives, so returning early did not mean dropping the work.
    var out: [4]qnnt.QueuedReply = undefined;
    var waited: usize = 0;
    while (waited < 5000) : (waited += 50) {
        const replies = qnnt.pollReplies(&out, 50);
        if (replies.len == 0) continue;
        try testing.expectEqual(id, replies[0].id);
        try testing.expectEqual(qnnt.RpcStatus.ok, replies[0].status);
        try testing.expectEqualStrings("slow", replies[0].data);
        return;
    }
    return error.ReplyNeverArrived;
}

test "a completing request wakes a caller parked in poll" {
    // The Qt poller -- and any C program written the same way -- drains messages and
    // replies from one loop: it blocks in `poll` and only looks at replies when that
    // returns. If a completion did not wake `poll`, every reply would wait out that
    // timeout. This pins the wake, because the cost of losing it is invisible in any test
    // that polls with a short timeout.
    try startNode();
    defer qnnt.deinit();

    try testing.expect(qnnt.addResponder("test/rpc/wake", &echoHandler, null));
    try waitForProcedure("test/rpc/wake", 5000);

    // Nothing is published, so the message queue stays empty for the whole test: `poll`
    // below can only return early because the reply woke it.
    try testing.expect(qnnt.reserveQueue(64));

    const id = qnnt.requestBegin("test/rpc/wake", "wake-up", 3000);
    try testing.expect(id != 0);

    const began = qnnt.nowMicros();
    var msgs: [8]QueuedMessage = undefined;
    const batch = qnnt.poll(&msgs, 10_000); // ten seconds it must NOT wait out
    const waited_us = qnnt.nowMicros() - began;

    try testing.expectEqual(@as(usize, 0), batch.len); // no messages, as expected
    try testing.expect(waited_us < 3_000_000);

    // And the reply really is there to be drained, which is what the wake was for.
    var out: [4]qnnt.QueuedReply = undefined;
    const replies = qnnt.pollReplies(&out, 2000);
    try testing.expectEqual(@as(usize, 1), replies.len);
    try testing.expectEqual(id, replies[0].id);
}

// -- local sockets ------------------------------------------------------------------------

/// What each side of one topic named as its peer: "unix" over a Unix socket, an address over
/// TCP. The publisher and the subscriber are the same process here, so both events land in
/// one handler.
const PeerLog = struct {
    var topic_buf: [48]u8 = undefined;
    var topic_len: usize = 0;
    var seen_by_subscriber: [96]u8 = undefined;
    var subscriber_len = std.atomic.Value(usize).init(0);
    var seen_by_publisher: [96]u8 = undefined;
    var publisher_len = std.atomic.Value(usize).init(0);
    var messages = std.atomic.Value(usize).init(0);

    fn watch(topic: []const u8) void {
        @memcpy(topic_buf[0..topic.len], topic);
        topic_len = topic.len;
        subscriber_len.store(0, .monotonic);
        publisher_len.store(0, .monotonic);
        messages.store(0, .monotonic);
    }

    fn record(event: qnnt.Event, topic: []const u8, peer: []const u8, _: usize, _: ?*anyopaque) void {
        if (!std.mem.eql(u8, topic, topic_buf[0..topic_len])) return;
        switch (event) {
            .publisher_connected => store(&seen_by_subscriber, &subscriber_len, peer),
            .subscriber_connected => store(&seen_by_publisher, &publisher_len, peer),
            else => {},
        }
    }

    fn store(buf: *[96]u8, len: *std.atomic.Value(usize), peer: []const u8) void {
        const n = @min(peer.len, buf.len);
        @memcpy(buf[0..n], peer[0..n]);
        len.store(n, .release);
    }

    fn onMessage(_: []const u8, _: []const u8, _: ?*anyopaque) void {
        _ = messages.fetchAdd(1, .monotonic);
    }

    /// Both ends attached and at least one message through.
    fn waitConnected(timeout_ms: usize) bool {
        var waited: usize = 0;
        while (waited < timeout_ms) : (waited += 20) {
            if (subscriber_len.load(.acquire) > 0 and publisher_len.load(.acquire) > 0 and
                messages.load(.monotonic) > 0) return true;
            qnnt.sleepMs(20);
        }
        return false;
    }

    fn subscriberSaw() []const u8 {
        return seen_by_subscriber[0..subscriber_len.load(.acquire)];
    }

    fn publisherSaw() []const u8 {
        return seen_by_publisher[0..publisher_len.load(.acquire)];
    }
};

test "a subscriber on this host is served over the Unix socket" {
    try startNode();
    defer qnnt.deinit();
    try testing.expect(qnnt.socketDir().len > 0);

    PeerLog.watch("test/local/unix");
    qnnt.setEventHandler(PeerLog.record, null);
    defer qnnt.setEventHandler(null, null);

    try testing.expect(qnnt.runPublisher("test/local/unix", source, 10_000, null));
    try testing.expect(qnnt.subscribe("test/local/unix", PeerLog.onMessage, null));
    try testing.expect(PeerLog.waitConnected(5000));

    try testing.expectEqualStrings("unix", PeerLog.subscriberSaw());
    try testing.expectEqualStrings("unix", PeerLog.publisherSaw());
}

test "with local sockets off, a subscriber on this host uses TCP" {
    // The path every remote subscriber takes, so it has to keep working locally too: with
    // local sockets on by default, nothing else in this file goes over TCP any more.
    try testing.expect(qnnt.setLocalSockets(false));
    defer _ = qnnt.setLocalSockets(true);
    try startNode();
    defer qnnt.deinit();
    try testing.expectEqualStrings("", qnnt.socketDir());

    PeerLog.watch("test/local/tcp");
    qnnt.setEventHandler(PeerLog.record, null);
    defer qnnt.setEventHandler(null, null);

    try testing.expect(qnnt.runPublisher("test/local/tcp", source, 10_000, null));
    try testing.expect(qnnt.subscribe("test/local/tcp", PeerLog.onMessage, null));
    try testing.expect(PeerLog.waitConnected(5000));

    try testing.expect(std.mem.startsWith(u8, PeerLog.subscriberSaw(), "127.0.0.1:"));
    try testing.expect(std.mem.startsWith(u8, PeerLog.publisherSaw(), "127.0.0.1:"));

    // And refused while running, like every other pre-start knob.
    try testing.expect(!qnnt.setLocalSockets(true));
}

/// The `unix://` line the registry hands out for `topic`, once the publisher has registered.
fn waitForLocalPath(topic: []const u8, out: []u8, timeout_ms: usize) ![]const u8 {
    var cmd: [128]u8 = undefined;
    const command = try std.fmt.bufPrint(&cmd, "sub {s}", .{topic});
    var reply: [512]u8 = undefined;
    var waited: usize = 0;
    while (waited < timeout_ms) : (waited += 25) {
        const text = qnnt.registryCommand(command, &reply) catch "";
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "unix://")) {
                const path = std.mem.trimEnd(u8, line["unix://".len..], "\r");
                @memcpy(out[0..path.len], path);
                return out[0..path.len];
            }
        }
        qnnt.sleepMs(25);
    }
    return error.NoLocalPath;
}

test "a socket path that no longer answers falls back to TCP" {
    // What a subscriber meets when the publisher's socket file is gone -- a cleaned /tmp,
    // or a container that shares the network but not the filesystem. It must still connect.
    try startNode();
    defer qnnt.deinit();

    PeerLog.watch("test/local/gone");
    qnnt.setEventHandler(PeerLog.record, null);
    defer qnnt.setEventHandler(null, null);

    try testing.expect(qnnt.runPublisher("test/local/gone", source, 10_000, null));
    var path_buf: [128]u8 = undefined;
    const path = try waitForLocalPath("test/local/gone", &path_buf, 3000);
    var zbuf: [129]u8 = undefined;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    try testing.expectEqual(@as(c_int, 0), std.c.unlink(zbuf[0..path.len :0]));

    try testing.expect(qnnt.subscribe("test/local/gone", PeerLog.onMessage, null));
    try testing.expect(PeerLog.waitConnected(5000));
    try testing.expect(std.mem.startsWith(u8, PeerLog.subscriberSaw(), "127.0.0.1:"));
}

test "a request goes over TCP when local sockets are off" {
    try testing.expect(qnnt.setLocalSockets(false));
    defer _ = qnnt.setLocalSockets(true);
    try startNode();
    defer qnnt.deinit();

    try testing.expect(qnnt.addResponder("test/local/rpc", &echoHandler, null));
    try waitForProcedure("test/local/rpc", 3000);

    var out: [64]u8 = undefined;
    var len: usize = 0;
    try testing.expectEqual(qnnt.RpcStatus.ok, qnnt.request("test/local/rpc", "over tcp", 2000, &out, &len));
    try testing.expectEqualStrings("over tcp", out[0..len]);
}

test "the registry hands out a path only for a registration that carried one" {
    try startNode();
    defer qnnt.deinit();

    var reply: [512]u8 = undefined;
    _ = try qnnt.registryCommand("pub test/local/p1 tcp://127.0.0.1:5001 unix:///tmp/somewhere.sock", &reply);
    var text = try qnnt.registryCommand("sub test/local/p1", &reply);
    try testing.expect(std.mem.indexOf(u8, text, "tcp://127.0.0.1:5001\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "unix:///tmp/somewhere.sock\n") != null);

    // An older publisher, registering TCP alone: no path, exactly as before.
    _ = try qnnt.registryCommand("pub test/local/p2 tcp://127.0.0.1:5002", &reply);
    text = try qnnt.registryCommand("sub test/local/p2", &reply);
    try testing.expect(std.mem.indexOf(u8, text, "tcp://127.0.0.1:5002\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "unix://") == null);

    // A path that is not absolute is ignored rather than handed to subscribers.
    _ = try qnnt.registryCommand("pub test/local/p3 tcp://127.0.0.1:5003 unix://relative.sock", &reply);
    text = try qnnt.registryCommand("sub test/local/p3", &reply);
    try testing.expect(std.mem.indexOf(u8, text, "unix://") == null);
}

/// A socket file with nothing listening on it: what a node that died leaves behind.
fn leaveStaleSocket(path: [:0]const u8, keep_listening: bool) !std.c.fd_t {
    const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
    if (fd < 0) return error.NoSocket;
    var addr = std.mem.zeroes(std.c.sockaddr.un);
    if (@hasField(std.c.sockaddr.un, "len")) addr.len = @sizeOf(std.c.sockaddr.un);
    addr.family = std.c.AF.UNIX;
    @memcpy(addr.path[0..path.len], path);
    if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.un)) != 0) return error.BindFailed;
    if (keep_listening) {
        if (std.c.listen(fd, 4) != 0) return error.ListenFailed;
        return fd;
    }
    _ = std.c.close(fd);
    return -1;
}

fn exists(path: [:0]const u8) bool {
    var dir = std.Io.Dir.cwd();
    _ = &dir;
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY });
    if (fd >= 0) {
        _ = std.c.close(fd);
        return true;
    }
    // A socket cannot be opened, but the error says whether it is there.
    return std.posix.errno(fd) != .NOENT;
}

test "a dead node's socket file is swept at start, and a live one is left alone" {
    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&dir_buf, "/tmp/qnnt-sweep-{d}", .{std.c.getpid()});
    _ = std.c.mkdir(dir, 0o700);
    defer _ = std.c.rmdir(dir);

    var dead_buf: [96]u8 = undefined;
    const dead = try std.fmt.bufPrintZ(&dead_buf, "{s}/0000000000000000-0.sock", .{dir});
    var live_buf: [96]u8 = undefined;
    const live = try std.fmt.bufPrintZ(&live_buf, "{s}/0000000000000000-1.sock", .{dir});
    defer _ = std.c.unlink(dead);
    defer _ = std.c.unlink(live);

    _ = try leaveStaleSocket(dead, false);
    const live_fd = try leaveStaleSocket(live, true);
    defer _ = std.c.close(live_fd);
    try testing.expect(exists(dead) and exists(live));

    try testing.expect(qnnt.setSocketDir(dir));
    defer _ = qnnt.setSocketDir("");
    try startNode();
    defer qnnt.deinit();

    try testing.expectEqualStrings(dir, qnnt.socketDir());
    try testing.expect(!exists(dead));
    try testing.expect(exists(live));
}

test "a socket directory that could be someone else's turns local sockets off" {
    var real_buf: [64]u8 = undefined;
    const real = try std.fmt.bufPrintZ(&real_buf, "/tmp/qnnt-real-{d}", .{std.c.getpid()});
    var link_buf: [64]u8 = undefined;
    const link = try std.fmt.bufPrintZ(&link_buf, "/tmp/qnnt-link-{d}", .{std.c.getpid()});
    _ = std.c.mkdir(real, 0o700);
    defer _ = std.c.rmdir(real);
    _ = std.c.unlink(link);
    try testing.expectEqual(@as(c_int, 0), std.c.symlink(real, link));
    defer _ = std.c.unlink(link);

    // A symlink is refused even when it points somewhere fine: whoever made the link
    // decides where the sockets go, and that need not be this user.
    try testing.expect(qnnt.setSocketDir(link));
    defer _ = qnnt.setSocketDir("");
    try startNode();
    try testing.expectEqualStrings("", qnnt.socketDir());
    qnnt.deinit();

    // A real directory of ours that others could write to is tightened, then used.
    _ = std.c.chmod(real, 0o777);
    try testing.expect(qnnt.setSocketDir(real));
    try startNode();
    defer qnnt.deinit();
    try testing.expectEqualStrings(real, qnnt.socketDir());
}

test "the socket directory must be absolute and short enough for the names under it" {
    defer _ = qnnt.setSocketDir("");
    try testing.expect(!qnnt.setSocketDir("relative/dir"));
    try testing.expect(!qnnt.setSocketDir("/"));
    try testing.expect(!qnnt.setSocketDir("/" ++ "x" ** 64));
    try testing.expect(qnnt.setSocketDir("/tmp/somewhere/"));
    try testing.expect(qnnt.setSocketDir(""));
}
