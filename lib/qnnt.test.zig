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
