//! C ABI for the qnnt node: lifecycle, publishing, and both subscription modes.
//!
//! Includes the TLD codec's exports too, so one library carries the whole surface;
//! `libqnnt_tld` remains available for callers who only want the codec and none of the
//! threads or sockets.
//!
//! Two subscription modes are offered because they suit different callers:
//!
//!   * `qnnt_subscribe` / `qnnt_subscribe_frames` invoke your callback on a library
//!     thread. Lowest latency, and correct for C and C++.
//!   * `qnnt_subscribe_queue` + `qnnt_poll` copy messages into a queue you drain on your
//!     own thread. Slightly more latency, but the crossing is amortised over a batch and
//!     no library thread ever calls into your runtime — which is what a garbage-collected
//!     or GIL-bearing host needs.
//!
//! Kept in step with include/qnnt.h by hand.

const std = @import("std");
const qnnt = @import("qnnt.zig");
const allocator = @import("alloc.zig").allocator;

comptime {
    // Pull the codec's exports into this library as well.
    _ = @import("tld_c.zig");
}

const Status = enum(c_int) {
    ok = 0,
    /// A node operation failed; the library has printed the specifics to stderr.
    failed = 1,
    invalid_argument = 2,
    /// A source callback was given without a period, or vice versa.
    invalid_period = 3,
};

// A topic crosses as (pointer, length) and the library keeps the pointer: topics are not
// copied, so the caller's string must outlive the subscription or publisher. Documented
// in the header rather than papered over with a hidden allocation.
fn topicSlice(ptr: ?[*]const u8, len: usize) ?[]const u8 {
    const p = ptr orelse return null;
    return p[0..len];
}

/// Copy a topic the library is going to keep.
///
/// `topicSlice` only views the caller's bytes, and the library retains a topic for the life
/// of the publisher or subscription that uses it -- the register loop, the subscriber
/// thread and the subscribers map all hold the slice. A C caller who passed a stack buffer,
/// a C++ caller who passed `topic.toUtf8().constData()`, or a Python caller whose
/// `topic.encode()` temporary was collected, therefore left the library reading freed
/// memory, and the symptom was a subscription for a garbled topic name that resolved to
/// nothing.
///
/// Never freed, deliberately: publishers and subscriptions live until deinit, so this is
/// bounded by the number of topics rather than by traffic -- the same reasoning as the
/// source box below.
fn retainTopic(topic: ?[*]const u8, topic_len: usize) ?[]const u8 {
    const borrowed = topicSlice(topic, topic_len) orelse return null;
    return allocator.dupe(u8, borrowed) catch null;
}

// ---------------------------------------------------------------- lifecycle

/// Choose the registry port for the next `qnnt_init`. Returns QNNT_FAILED while a node is
/// running. Distinct ports give independent registries on one machine, which is how two
/// programs (or a test and a demo) stay out of each other's way.
export fn qnnt_set_registry_port(port: u16) callconv(.c) Status {
    return if (qnnt.setRegistryPortFn(port)) .ok else .failed;
}

/// Run worker threads on SCHED_FIFO at `priority`; 0 (the default) leaves them alone.
/// Linux only -- elsewhere this returns failed and says why.
///
/// `ok` means the request was accepted, not that it will succeed: whether the process may
/// actually take a real-time priority is only discoverable when a thread tries, and a
/// refusal is reported on stderr then. Check for that line if a latency bound matters.
export fn qnnt_set_realtime_priority(priority: u8) callconv(.c) Status {
    return if (qnnt.setRealtimePriorityFn(priority)) .ok else .failed;
}

export fn qnnt_realtime_priority() callconv(.c) u8 {
    return qnnt.realtimePriorityFn();
}

/// Pin the process's pages into RAM with mlockall before workers start (Linux only).
/// The companion to qnnt_set_realtime_priority: a thread that cannot be preempted can
/// still be stalled by a page fault.
///
/// As with the priority, `ok` means accepted, not granted -- a kernel refusal is printed
/// once, to stderr, naming the errno. Note that this locks future mappings too, so an
/// RLIMIT_MEMLOCK that is too low shows up as an allocation failure elsewhere.
export fn qnnt_set_lock_memory(enabled: u8) callconv(.c) Status {
    return if (qnnt.setLockMemoryFn(enabled != 0)) .ok else .failed;
}

export fn qnnt_lock_memory() callconv(.c) u8 {
    return if (qnnt.lockMemoryFn()) 1 else 0;
}

/// The address remote subscribers should dial. Optional: leave it unset and observers
/// fill it in from the connection they reached this host on, which is what lets a node
/// behind a gateway work without knowing its own public address.
export fn qnnt_set_advertise_address(addr: ?[*:0]const u8) callconv(.c) Status {
    const text = addr orelse return .invalid_argument;
    return if (qnnt.setAdvertiseAddressFn(std.mem.span(text))) .ok else .failed;
}

/// The address publisher sockets bind. Defaults to following the advertise address.
export fn qnnt_set_bind_address(addr: ?[*:0]const u8) callconv(.c) Status {
    const text = addr orelse return .invalid_argument;
    return if (qnnt.setBindAddressFn(std.mem.span(text))) .ok else .failed;
}

/// Federation. All optional and all before qnnt_init; federation stays off unless both a
/// port and a cluster key are given.
export fn qnnt_set_federation_port(port: u16) callconv(.c) Status {
    return if (qnnt.Qnnt.setFederationPort(port)) .ok else .failed;
}

export fn qnnt_set_cluster_key(key: ?[*:0]const u8) callconv(.c) Status {
    const text = key orelse return .invalid_argument;
    return if (qnnt.Qnnt.setClusterKey(std.mem.span(text))) .ok else .failed;
}

/// Add a peer to dial. Port 0 means "the federation port".
export fn qnnt_add_peer(host: ?[*:0]const u8, port: u16) callconv(.c) Status {
    const text = host orelse return .invalid_argument;
    return if (qnnt.Qnnt.addPeer(std.mem.span(text), port)) .ok else .failed;
}

/// This node's identity: 32 hex characters plus a NUL, so `cap` must be at least 33.
/// Copied out rather than returned as a pointer, because the caller owns the lifetime it
/// wants and the library's buffer is not it.
export fn qnnt_node_id(out: ?[*]u8, cap: usize) callconv(.c) Status {
    const dst = out orelse return .invalid_argument;
    if (cap < 33) return .invalid_argument;
    var buf: [32]u8 = undefined;
    const text = qnnt.nodeIdTextFn(&buf);
    @memcpy(dst[0..text.len], text);
    dst[text.len] = 0;
    return .ok;
}

/// The address remote subscribers are told to dial, as text. Copied out; `cap` must hold
/// it plus a NUL (46 bytes is enough for any address).
export fn qnnt_advertise_address(out: ?[*]u8, cap: usize) callconv(.c) Status {
    const dst = out orelse return .invalid_argument;
    const text = qnnt.advertiseAddressFn();
    if (cap < text.len + 1) return .invalid_argument;
    @memcpy(dst[0..text.len], text);
    dst[text.len] = 0;
    return .ok;
}

/// Whether federation will actually run: a cluster key is set and a port is available.
export fn qnnt_federation_enabled() callconv(.c) u8 {
    return if (qnnt.Qnnt.federationEnabled()) 1 else 0;
}

export fn qnnt_registry_port() callconv(.c) u16 {
    return qnnt.currentRegistryPort();
}

/// Apply configuration from the process environment. One call, and the same six QNNT_*
/// variables work identically from C, C++, Python and Zig. Explicit rather than automatic:
/// a library that silently reconfigures itself from process-wide state surprises whatever
/// embeds it. Call before qnnt_init, then override explicitly if you want to.
export fn qnnt_configure_from_environment() callconv(.c) void {
    qnnt.Qnnt.configureFromEnvironment();
}

export fn qnnt_init() callconv(.c) Status {
    return if (qnnt.nodeRun()) .ok else .failed;
}

export fn qnnt_deinit() callconv(.c) void {
    qnnt.nodeDeinit();
}

/// Opt in to SIGINT/SIGTERM handling, which requests a stop rather than exiting. Never
/// done by `qnnt_init`: taking over a process's signal disposition is the host's call,
/// and under a Python binding doing it silently would break KeyboardInterrupt. Call
/// after `qnnt_init`.
export fn qnnt_install_signal_handlers() callconv(.c) void {
    qnnt.installShutdownHandlers();
}

export fn qnnt_stop_requested() callconv(.c) bool {
    return qnnt.Qnnt.stopRequested();
}

export fn qnnt_now_micros() callconv(.c) i64 {
    return qnnt.Qnnt.nowMicros();
}

export fn qnnt_sleep_ms(ms: u64) callconv(.c) void {
    qnnt.Qnnt.sleepMs(ms);
}

// ---------------------------------------------------------------- publishing

/// Produces one payload per scheduler tick. Return NULL (or set *len to 0) to skip a
/// tick. The bytes are read after you return, so they must outlive the call.
const SourceFn = *const fn (
    topic: [*]const u8,
    topic_len: usize,
    out_len: *usize,
    user: ?*anyopaque,
) callconv(.c) ?[*]const u8;

// The C callback and its user pointer, boxed so both fit the single `context` slot the
// Zig handler signature carries.
const SourceBox = struct {
    callback: SourceFn,
    user: ?*anyopaque,
};

fn sourceTrampoline(topic: []const u8, context: ?*anyopaque) ?[]const u8 {
    const box: *const SourceBox = @ptrCast(@alignCast(context orelse return null));

    var len: usize = 0;
    const bytes = box.callback(topic.ptr, topic.len, &len, box.user) orelse return null;
    if (len == 0) return null;
    return bytes[0..len];
}

/// Start publishing `topic`. Pass source=NULL and period_us=0 to publish by hand with
/// `qnnt_publish`; pass both to have the library drive it. A period of 0 with a source
/// means unpaced — as fast as the machine manages, which busies a core.
export fn qnnt_publisher_start(
    topic: ?[*]const u8,
    topic_len: usize,
    source: ?SourceFn,
    period_us: u64,
    user: ?*anyopaque,
) callconv(.c) Status {
    const name = retainTopic(topic, topic_len) orelse return .invalid_argument;

    if (source) |callback| {
        // The box must outlive the publisher, and publishers live until deinit, so it is
        // never freed. Bounded by the number of publishers, not by messages.
        const box = allocator.create(SourceBox) catch return .failed;
        box.* = .{ .callback = callback, .user = user };
        return if (qnnt.publisherRun(name, sourceTrampoline, period_us, box)) .ok else .failed;
    }

    if (period_us != 0) return .invalid_period;
    return if (qnnt.publisherRun(name, null, null, null)) .ok else .failed;
}

export fn qnnt_publish(
    topic: ?[*]const u8,
    topic_len: usize,
    data: ?[*]const u8,
    data_len: usize,
) callconv(.c) Status {
    const name = topicSlice(topic, topic_len) orelse return .invalid_argument;
    const bytes = data orelse return .invalid_argument;

    qnnt.publishAll(name, bytes[0..data_len]) catch return .failed;
    return .ok;
}

// ---------------------------------------------------------------- callback subscriptions

/// Invoked on the subscriber's thread. `data` is valid only for the call.
const MessageFn = *const fn (
    topic: [*]const u8,
    topic_len: usize,
    data: [*]const u8,
    data_len: usize,
    user: ?*anyopaque,
) callconv(.c) void;

const MessageBox = struct {
    callback: MessageFn,
    user: ?*anyopaque,
};

fn messageTrampoline(topic: []const u8, msg: []const u8, context: ?*anyopaque) void {
    const box: *const MessageBox = @ptrCast(@alignCast(context orelse return));
    box.callback(topic.ptr, topic.len, msg.ptr, msg.len, box.user);
}

export fn qnnt_subscribe(
    topic: ?[*]const u8,
    topic_len: usize,
    callback: ?MessageFn,
    user: ?*anyopaque,
) callconv(.c) Status {
    const name = retainTopic(topic, topic_len) orelse return .invalid_argument;
    const cb = callback orelse return .invalid_argument;

    const box = allocator.create(MessageBox) catch return .failed;
    box.* = .{ .callback = cb, .user = user };
    return if (qnnt.subscribeRun(name, messageTrampoline, box)) .ok else .failed;
}

/// Invoked with a decoded TLD frame. The frame borrows the subscriber's buffer and is
/// valid only for the call.
const FrameFn = *const fn (
    topic: [*]const u8,
    topic_len: usize,
    frame: *const CFrame,
    user: ?*anyopaque,
) callconv(.c) void;

/// Must match qnnt_tld_frame in qnnt_tld.h, and the struct of the same shape in tld_c.zig.
const CFrame = extern struct {
    type: u8,
    mod: u8,
    ext_code: i16,
    data: [*]const u8,
    data_len: usize,
    raw: [*]const u8,
    raw_len: usize,
};

const FrameBox = struct {
    callback: FrameFn,
    user: ?*anyopaque,
};

fn frameTrampoline(topic: []const u8, frame: qnnt.Tld.Frame, context: ?*anyopaque) void {
    const box: *const FrameBox = @ptrCast(@alignCast(context orelse return));
    const c_frame: CFrame = .{
        .type = @intFromEnum(frame.type),
        .mod = frame.mod,
        .ext_code = if (frame.ext_code) |code| @intCast(code) else -1,
        .data = frame.data.ptr,
        .data_len = frame.data.len,
        .raw = frame.raw.ptr,
        .raw_len = frame.raw.len,
    };
    box.callback(topic.ptr, topic.len, &c_frame, box.user);
}

export fn qnnt_subscribe_frames(
    topic: ?[*]const u8,
    topic_len: usize,
    callback: ?FrameFn,
    user: ?*anyopaque,
) callconv(.c) Status {
    const name = retainTopic(topic, topic_len) orelse return .invalid_argument;
    const cb = callback orelse return .invalid_argument;

    const box = allocator.create(FrameBox) catch return .failed;
    box.* = .{ .callback = cb, .user = user };
    return if (qnnt.subscribeFramesRun(name, frameTrampoline, box)) .ok else .failed;
}

// ---------------------------------------------------------------- queued subscriptions

/// Mirrors qnnt_message. `topic` and `data` point into library storage that stays valid
/// until the next `qnnt_poll`, which recycles it.
const CMessage = extern struct {
    topic: [*]const u8,
    topic_len: usize,
    data: [*]const u8,
    data_len: usize,
    received_us: u64,
};

/// Size the shared queue before subscribing. Optional; the first queued subscription
/// reserves a default if you have not.
export fn qnnt_queue_reserve(capacity: usize) callconv(.c) Status {
    return if (qnnt.Qnnt.reserveQueue(capacity)) .ok else .failed;
}

export fn qnnt_queue_dropped() callconv(.c) u64 {
    return qnnt.Qnnt.queueDropped();
}

/// Mirrors qnnt_queue_mode.
const QueueMode = enum(c_int) { text = 0, frames = 1 };

export fn qnnt_subscribe_queue(
    topic: ?[*]const u8,
    topic_len: usize,
    mode: QueueMode,
) callconv(.c) Status {
    const name = retainTopic(topic, topic_len) orelse return .invalid_argument;
    const zig_mode: qnnt.QueueMode = switch (mode) {
        .text => .text,
        .frames => .frames,
    };
    return if (qnnt.Qnnt.subscribeQueue(name, zig_mode)) .ok else .failed;
}

// Scratch for translating a batch into C form. Poll is single-consumer by contract, so
// one buffer suffices; it grows to the largest batch ever requested.
var poll_scratch: std.ArrayList(qnnt.QueuedMessage) = .empty;

/// Drain up to `max` messages into `out`, writing the count to `*count`. `timeout_ms` of
/// 0 never blocks; -1 blocks until something arrives. Call from one thread only.
export fn qnnt_poll(
    out: ?[*]CMessage,
    max: usize,
    timeout_ms: i32,
    count: ?*usize,
) callconv(.c) Status {
    const dst = out orelse return .invalid_argument;
    const written = count orelse return .invalid_argument;
    written.* = 0;
    if (max == 0) return .ok;

    poll_scratch.resize(allocator, max) catch return .failed;

    const batch = qnnt.Qnnt.poll(poll_scratch.items, timeout_ms);
    for (batch, 0..) |msg, i| {
        dst[i] = .{
            .topic = msg.topic.ptr,
            .topic_len = msg.topic.len,
            .data = msg.data.ptr,
            .data_len = msg.data.len,
            .received_us = msg.received_us,
        };
    }
    written.* = batch.len;
    return .ok;
}

// ---------------------------------------------------------------- diagnostics

export fn qnnt_status_name(status: Status) callconv(.c) [*:0]const u8 {
    return switch (status) {
        .ok => "ok",
        .failed => "failed",
        .invalid_argument => "invalid argument",
        .invalid_period => "source and period must be given together",
    };
}

// ---------------------------------------------------------------- connection events

const EventFn = *const fn (
    event: c_int,
    topic: [*]const u8,
    topic_len: usize,
    peer: [*]const u8,
    peer_len: usize,
    subscribers: usize,
    user: ?*anyopaque,
) callconv(.c) void;

const EventBox = struct {
    callback: EventFn,
    user: ?*anyopaque,
};

// One box, replaced rather than accumulated: the library holds a single handler, and this
// mirrors it. Leaked on replacement, which is bounded by how many times a program changes
// its handler -- in practice once.
var event_box: ?*EventBox = null;

fn eventTrampoline(
    event: qnnt.Event,
    topic: []const u8,
    peer: []const u8,
    subscribers: usize,
    context: ?*anyopaque,
) void {
    const box: *EventBox = @ptrCast(@alignCast(context.?));
    // Empty slices still need a valid pointer for C: an empty `peer` is normal.
    const topic_ptr: [*]const u8 = if (topic.len == 0) "" else topic.ptr;
    const peer_ptr: [*]const u8 = if (peer.len == 0) "" else peer.ptr;
    box.callback(@intFromEnum(event), topic_ptr, topic.len, peer_ptr, peer.len, subscribers, box.user);
}

/// Register a handler for connection events, or pass NULL to clear it.
///
/// The handler runs on one of the library's threads, not the caller's, and two events may
/// be delivered at once from different threads. It is called with no library lock held, so
/// it may call back in -- qnnt_subscriber_count from inside a handler is fine.
export fn qnnt_set_event_handler(handler: ?EventFn, user: ?*anyopaque) callconv(.c) void {
    const callback = handler orelse {
        qnnt.setEventHandlerFn(null, null);
        return;
    };

    const box = allocator.create(EventBox) catch return;
    box.* = .{ .callback = callback, .user = user };
    event_box = box;
    qnnt.setEventHandlerFn(eventTrampoline, box);
}

/// Subscribers currently connected to this node's publisher for `topic`.
export fn qnnt_subscriber_count(topic: ?[*]const u8, topic_len: usize) callconv(.c) usize {
    const name = topicSlice(topic, topic_len) orelse return 0;
    return qnnt.subscriberCountFn(name);
}

/// Block until `topic` has a subscriber, or the timeout expires. Returns whether it has
/// one. This is what a publisher should call instead of sleeping before its first message.
export fn qnnt_wait_for_subscriber(
    topic: ?[*]const u8,
    topic_len: usize,
    timeout_ms: u64,
) callconv(.c) bool {
    const name = topicSlice(topic, topic_len) orelse return false;
    return qnnt.waitForSubscriberFn(name, timeout_ms);
}

/// As above, but for a known number of peers: waiting for one subscriber stops a publisher
/// shouting into an empty room, while waiting for all of them means every peer sees the
/// stream from its first message.
export fn qnnt_wait_for_subscribers(
    topic: ?[*]const u8,
    topic_len: usize,
    count: usize,
    timeout_ms: u64,
) callconv(.c) bool {
    const name = topicSlice(topic, topic_len) orelse return false;
    return qnnt.waitForSubscribersFn(name, count, timeout_ms);
}

/// Silence after which a connected subscription is reported stale. 0 disables it.
export fn qnnt_set_stale_timeout(ms: u64) callconv(.c) void {
    qnnt.setStaleTimeoutFn(ms);
}

export fn qnnt_stale_timeout() callconv(.c) u64 {
    return qnnt.staleTimeoutFn();
}

const EventRecord = extern struct {
    event: c_int,
    topic: [*]const u8,
    topic_len: usize,
    peer: [*]const u8,
    peer_len: usize,
    subscribers: usize,
    at_us: u64,
};

// Room for one drain's worth of records, so the Zig-side slices can be converted without
// allocating per call.
var event_scratch: [64]qnnt.PolledEvent = undefined;

/// Drain buffered connection events into `out`, writing how many to *count.
///
/// The alternative to qnnt_set_event_handler, and the right one for a language that cannot
/// be called on a foreign thread: events are buffered as they happen and handed over when
/// asked for. Both may be used at once.
///
/// The `topic` and `peer` pointers are valid until the next call, as with qnnt_poll.
export fn qnnt_poll_events(
    out: ?[*]EventRecord,
    max: usize,
    count: ?*usize,
) callconv(.c) Status {
    const dst = out orelse return .invalid_argument;
    const written = count orelse return .invalid_argument;
    written.* = 0;
    if (max == 0) return .ok;

    const take = @min(max, event_scratch.len);
    const events = qnnt.pollEventsFn(event_scratch[0..take]);

    for (events, 0..) |event, i| {
        dst[i] = .{
            .event = @intFromEnum(event.event),
            .topic = if (event.topic.len == 0) "" else event.topic.ptr,
            .topic_len = event.topic.len,
            .peer = if (event.peer.len == 0) "" else event.peer.ptr,
            .peer_len = event.peer.len,
            .subscribers = event.subscribers,
            .at_us = event.at_us,
        };
    }
    written.* = events.len;
    return .ok;
}

/// Events discarded because nothing drained the queue.
export fn qnnt_events_dropped() callconv(.c) u64 {
    return qnnt.eventsDroppedFn();
}
