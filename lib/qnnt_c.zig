//! C ABI for the qnnt node: lifecycle, publishing, and both subscription modes.
//!
//! The TOLD codec's own C functions are not here: they are libtold's, built from the
//! deps/told submodule, and a C caller links both. This library takes only TOLD's frame
//! layout, so a frame callback can hand out the same told_frame libtold decodes into.
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
const told_abi = @import("told_abi");

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

// ---------------------------------------------------------------- per-topic teardown
//
// The trampoline box a direct subscription allocates, so `qnnt_remove_subscriber` can give
// it back. Boxes were always leaked on purpose -- one per subscription, for the life of the
// node, bounded by how many a program makes. Per-topic removal makes that unbounded, so
// what a topic owns is tracked here and freed with it.
//
// Pattern subscriptions are deliberately absent: one box serves every topic a glob joins,
// so freeing it when one of them is removed would leave the others calling through it.
// A pattern's box stays bounded by the number of patterns, as before.
//
// Unguarded, like `poll_scratch` and `event_box` below: these are control-plane calls made
// from the caller's own thread, never from a library worker.
const OwnedBox = struct {
    topic: []const u8, // owned
    publisher: bool,
    box: *anyopaque,
    release: *const fn (*anyopaque) void,
};

var owned_boxes: std.ArrayList(OwnedBox) = .empty;

fn releaseMessageBox(p: *anyopaque) void {
    allocator.destroy(@as(*MessageBox, @ptrCast(@alignCast(p))));
}

fn releaseFrameBox(p: *anyopaque) void {
    allocator.destroy(@as(*FrameBox, @ptrCast(@alignCast(p))));
}

fn releaseSourceBox(p: *anyopaque) void {
    allocator.destroy(@as(*SourceBox, @ptrCast(@alignCast(p))));
}

/// Record a box against a topic, or free it now if the subscription never started.
/// Returns the status to hand back to the caller.
fn keepBox(
    started: bool,
    topic: []const u8,
    publisher: bool,
    box: *anyopaque,
    release: *const fn (*anyopaque) void,
) Status {
    if (!started) {
        release(box);
        return .failed;
    }
    const name = allocator.dupe(u8, topic) catch return .ok; // started; just untracked
    owned_boxes.append(allocator, .{
        .topic = name,
        .publisher = publisher,
        .box = box,
        .release = release,
    }) catch {
        allocator.free(name);
    };
    return .ok;
}

/// Free whatever the topic's direct subscriptions or publisher allocated here.
fn releaseBoxes(topic: []const u8, publisher: bool) void {
    var i: usize = 0;
    while (i < owned_boxes.items.len) {
        const entry = owned_boxes.items[i];
        if (entry.publisher == publisher and std.mem.eql(u8, entry.topic, topic)) {
            entry.release(entry.box);
            allocator.free(entry.topic);
            _ = owned_boxes.swapRemove(i);
            continue; // swapRemove moved a new entry into i
        }
        i += 1;
    }
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

/// Stack size for the threads that serve one connection or one request and exit. 0 (the
/// default) leaves them on std.Thread's 16 MiB; below 128 KiB is refused, and anything
/// else is rounded up to a page. Before qnnt_init.
export fn qnnt_set_handler_stack_bytes(bytes: usize) callconv(.c) Status {
    return if (qnnt.setHandlerStackBytesFn(bytes)) .ok else .failed;
}

export fn qnnt_handler_stack_bytes() callconv(.c) usize {
    return qnnt.handlerStackBytesFn();
}

/// Same-host traffic over Unix sockets, remote over TCP. On by default. Before qnnt_init.
export fn qnnt_set_local_sockets(enabled: u8) callconv(.c) Status {
    return if (qnnt.setLocalSocketsFn(enabled != 0)) .ok else .failed;
}

export fn qnnt_local_sockets() callconv(.c) u8 {
    return if (qnnt.localSocketsFn()) 1 else 0;
}

/// Where the Unix sockets go; NULL or "" restores /tmp/qnnt-<uid>. Before qnnt_init.
export fn qnnt_set_socket_dir(path: ?[*:0]const u8) callconv(.c) Status {
    const text = if (path) |p| std.mem.span(p) else "";
    return if (qnnt.setSocketDirFn(text)) .ok else .failed;
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
    // Borrowed, not copied: the library duplicates the topic into the publisher's own
    // token and never refers to this slice again.
    const name = topicSlice(topic, topic_len) orelse return .invalid_argument;

    if (source) |callback| {
        // The box outlives this call -- it is what the scheduler calls back through -- so
        // it is tracked against the topic and freed by `qnnt_remove_publisher`.
        const box = allocator.create(SourceBox) catch return .failed;
        box.* = .{ .callback = callback, .user = user };
        const started = qnnt.publisherRun(name, sourceTrampoline, period_us, box);
        return keepBox(started, name, true, box, releaseSourceBox);
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
    const name = topicSlice(topic, topic_len) orelse return .invalid_argument;
    const cb = callback orelse return .invalid_argument;

    const box = allocator.create(MessageBox) catch return .failed;
    box.* = .{ .callback = cb, .user = user };
    const started = qnnt.subscribeRun(name, messageTrampoline, box);
    return keepBox(started, name, false, box, releaseMessageBox);
}

/// `qnnt_subscribe` over a glob: every topic matching `pattern` now, and every one that
/// appears later, each joined as its own subscription. `rescan_ms` is how often to look;
/// 0 looks once and stops. The callback's `topic` says which stream a message came from.
export fn qnnt_subscribe_pattern(
    pattern: ?[*]const u8,
    pattern_len: usize,
    callback: ?MessageFn,
    user: ?*anyopaque,
    rescan_ms: u64,
) callconv(.c) Status {
    const name = retainTopic(pattern, pattern_len) orelse return .invalid_argument;
    const cb = callback orelse return .invalid_argument;

    const box = allocator.create(MessageBox) catch return .failed;
    box.* = .{ .callback = cb, .user = user };
    return if (qnnt.subscribePatternRun(name, messageTrampoline, box, rescan_ms)) .ok else .failed;
}

/// Invoked with a decoded TOLD frame. The frame borrows the subscriber's buffer and is
/// valid only for the call.
const FrameFn = *const fn (
    topic: [*]const u8,
    topic_len: usize,
    frame: *const CFrame,
    user: ?*anyopaque,
) callconv(.c) void;

/// The same struct libtold hands out, from the one file that declares it -- rather than a
/// copy kept in step by a comment. See deps/told/src/told_abi.zig.
const CFrame = told_abi.Frame;

const FrameBox = struct {
    callback: FrameFn,
    user: ?*anyopaque,
};

fn frameTrampoline(topic: []const u8, frame: qnnt.Told.Frame, context: ?*anyopaque) void {
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
    const name = topicSlice(topic, topic_len) orelse return .invalid_argument;
    const cb = callback orelse return .invalid_argument;

    const box = allocator.create(FrameBox) catch return .failed;
    box.* = .{ .callback = cb, .user = user };
    const started = qnnt.subscribeFramesRun(name, frameTrampoline, box);
    return keepBox(started, name, false, box, releaseFrameBox);
}

/// `qnnt_subscribe_frames` over a glob. See `qnnt_subscribe_pattern`.
export fn qnnt_subscribe_pattern_frames(
    pattern: ?[*]const u8,
    pattern_len: usize,
    callback: ?FrameFn,
    user: ?*anyopaque,
    rescan_ms: u64,
) callconv(.c) Status {
    const name = retainTopic(pattern, pattern_len) orelse return .invalid_argument;
    const cb = callback orelse return .invalid_argument;

    const box = allocator.create(FrameBox) catch return .failed;
    box.* = .{ .callback = cb, .user = user };
    return if (qnnt.subscribePatternFramesRun(name, frameTrampoline, box, rescan_ms)) .ok else .failed;
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
    // No box on this path: the queue subscription's handler is the library's own.
    const name = topicSlice(topic, topic_len) orelse return .invalid_argument;
    const zig_mode: qnnt.QueueMode = switch (mode) {
        .text => .text,
        .frames => .frames,
    };
    return if (qnnt.Qnnt.subscribeQueue(name, zig_mode)) .ok else .failed;
}

// ---------------------------------------------------------------- per-topic removal

/// Stop publishing `topic` without stopping the node: joins that publisher's threads, drops
/// its registration and closes its delivery connections.
///
/// QNNT_FAILED when no publisher of that name is running here, and when called from that
/// publisher's own source callback -- which would otherwise wait for the calling thread.
export fn qnnt_remove_publisher(topic: ?[*]const u8, topic_len: usize) callconv(.c) Status {
    const name = topicSlice(topic, topic_len) orelse return .invalid_argument;
    if (!qnnt.removePublisher(name)) return .failed;
    // After the join, so nothing can be calling through the box as it is freed.
    releaseBoxes(name, true);
    return .ok;
}

/// Stop every subscription this node holds on `topic`, whichever flavour started it.
///
/// A topic reached through a glob stays gone: the pattern does not rejoin it. QNNT_FAILED
/// when nothing was subscribed, and when called from that topic's own callback.
export fn qnnt_remove_subscriber(topic: ?[*]const u8, topic_len: usize) callconv(.c) Status {
    const name = topicSlice(topic, topic_len) orelse return .invalid_argument;
    if (!qnnt.removeSubscriber(name)) return .failed;
    releaseBoxes(name, false);
    return .ok;
}

/// Does `topic` match `pattern`? Exposed because a caller that subscribes to a glob often
/// has to make the same decision the library made -- which stream is this, does it belong to
/// this pattern -- and the answer has to agree exactly. There is one matcher, and this is it.
export fn qnnt_topic_matches(
    pattern: ?[*]const u8,
    pattern_len: usize,
    topic: ?[*]const u8,
    topic_len: usize,
) callconv(.c) bool {
    const pat = topicSlice(pattern, pattern_len) orelse return false;
    const name = topicSlice(topic, topic_len) orelse return false;
    return qnnt.topics.globMatch(pat, name);
}

/// `qnnt_subscribe_queue` over a glob. Each queued message carries its own topic, so one
/// queue serves the whole pattern.
export fn qnnt_subscribe_pattern_queue(
    pattern: ?[*]const u8,
    pattern_len: usize,
    mode: QueueMode,
    rescan_ms: u64,
) callconv(.c) Status {
    const name = retainTopic(pattern, pattern_len) orelse return .invalid_argument;
    const zig_mode: qnnt.QueueMode = switch (mode) {
        .text => .text,
        .frames => .frames,
    };
    return if (qnnt.Qnnt.subscribePatternQueue(name, zig_mode, rescan_ms)) .ok else .failed;
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

// ---------------------------------------------------------------- request / reply

/// Mirrors qnnt_rpc_status. Values are on the wire: append, never renumber.
const RpcStatus = enum(c_int) {
    ok = 0,
    no_procedure = 1,
    unreachable_host = 2,
    timed_out = 3,
    refused = 4,
    too_large = 5,
    failed = 6,
};

fn rpcStatus(status: qnnt.RpcStatus) RpcStatus {
    return switch (status) {
        .ok => .ok,
        .no_procedure => .no_procedure,
        .unreachable_host => .unreachable_host,
        .timed_out => .timed_out,
        .refused => .refused,
        .too_large => .too_large,
        .failed => .failed,
    };
}

/// Serves one request. Return NULL to refuse, which the caller sees as QNNT_RPC_REFUSED
/// rather than as an empty reply. The bytes returned are read AFTER this returns, so they
/// must outlive the call -- same rule as qnnt_source_fn.
const ResponderFn = *const fn (
    procedure: [*]const u8,
    procedure_len: usize,
    request: [*]const u8,
    request_len: usize,
    reply_len: *usize,
    user: ?*anyopaque,
) callconv(.c) ?[*]const u8;

const ResponderBox = struct {
    callback: ResponderFn,
    user: ?*anyopaque,
};

fn releaseResponderBox(ptr: *anyopaque) void {
    allocator.destroy(@as(*ResponderBox, @ptrCast(@alignCast(ptr))));
}

fn responderTrampoline(procedure: []const u8, request: []const u8, context: ?*anyopaque) ?[]const u8 {
    const box: *const ResponderBox = @ptrCast(@alignCast(context orelse return null));

    var len: usize = 0;
    const bytes = box.callback(
        procedure.ptr,
        procedure.len,
        request.ptr,
        request.len,
        &len,
        box.user,
    ) orelse return null;
    // An empty reply is legitimate, so a non-null pointer with length 0 is answered as an
    // empty `ok` -- only NULL refuses.
    return bytes[0..len];
}

/// Serve `procedure` on this node. Requests are answered one at a time, so a handler that
/// touches shared state needs no lock of its own.
export fn qnnt_add_responder(
    procedure: ?[*]const u8,
    procedure_len: usize,
    callback: ?ResponderFn,
    user: ?*anyopaque,
) callconv(.c) Status {
    const name = topicSlice(procedure, procedure_len) orelse return .invalid_argument;
    const cb = callback orelse return .invalid_argument;

    const box = allocator.create(ResponderBox) catch return .failed;
    box.* = .{ .callback = cb, .user = user };
    const started = qnnt.addResponderRun(name, responderTrampoline, box);
    return keepBox(started, name, true, box, releaseResponderBox);
}

/// Stop serving it: joins the responder's threads and drops its registration. QNNT_FAILED
/// when nothing of that name was being served here, and when called from its own handler.
export fn qnnt_remove_responder(procedure: ?[*]const u8, procedure_len: usize) callconv(.c) Status {
    const name = topicSlice(procedure, procedure_len) orelse return .invalid_argument;
    if (!qnnt.removeResponder(name)) return .failed;
    releaseBoxes(name, true);
    return .ok;
}

/// One request, on the calling thread. Returns a qnnt_rpc_status, not a qnnt_status: the
/// interesting outcomes here are "no such procedure" and "timed out", which the general
/// status enum has no room for.
export fn qnnt_request(
    procedure: ?[*]const u8,
    procedure_len: usize,
    data: ?[*]const u8,
    data_len: usize,
    timeout_ms: u64,
    out: ?[*]u8,
    out_cap: usize,
    out_len: ?*usize,
) callconv(.c) RpcStatus {
    const name = topicSlice(procedure, procedure_len) orelse return .failed;
    const written = out_len orelse return .failed;
    written.* = 0;

    const payload: []const u8 = if (data) |d| d[0..data_len] else &.{};
    const dst: []u8 = if (out) |o| o[0..out_cap] else &.{};

    return rpcStatus(qnnt.requestRun(name, payload, timeout_ms, dst, written));
}

/// Start a request and return a ticket at once; 0 means it could not be started. Collect
/// the reply with qnnt_poll_replies -- there is deliberately no completion callback, for
/// the same reason qnnt_poll exists.
export fn qnnt_request_begin(
    procedure: ?[*]const u8,
    procedure_len: usize,
    data: ?[*]const u8,
    data_len: usize,
    timeout_ms: u64,
) callconv(.c) u64 {
    const name = topicSlice(procedure, procedure_len) orelse return 0;
    const payload: []const u8 = if (data) |d| d[0..data_len] else &.{};
    return qnnt.requestBeginRun(name, payload, timeout_ms);
}

/// Mirrors qnnt_reply. `procedure` and `data` point into library storage valid until the
/// next qnnt_poll_replies, which recycles it.
const CReply = extern struct {
    id: u64,
    status: RpcStatus,
    procedure: [*]const u8,
    procedure_len: usize,
    data: [*]const u8,
    data_len: usize,
};

var reply_scratch: std.ArrayList(qnnt.QueuedReply) = .empty;

export fn qnnt_poll_replies(
    out: ?[*]CReply,
    max: usize,
    timeout_ms: i32,
    count: ?*usize,
) callconv(.c) Status {
    const dst = out orelse return .invalid_argument;
    const written = count orelse return .invalid_argument;
    written.* = 0;
    if (max == 0) return .ok;

    reply_scratch.resize(allocator, max) catch return .failed;

    const batch = qnnt.pollReplies(reply_scratch.items, timeout_ms);
    for (batch, 0..) |reply, i| {
        dst[i] = .{
            .id = reply.id,
            .status = rpcStatus(reply.status),
            .procedure = reply.procedure.ptr,
            .procedure_len = reply.procedure.len,
            .data = reply.data.ptr,
            .data_len = reply.data.len,
        };
    }
    written.* = batch.len;
    return .ok;
}

export fn qnnt_requests_in_flight() callconv(.c) usize {
    return qnnt.requestsInFlight();
}

export fn qnnt_rpc_status_name(status: RpcStatus) callconv(.c) [*:0]const u8 {
    return switch (status) {
        .ok => "ok",
        .no_procedure => "no such procedure",
        .unreachable_host => "host unreachable",
        .timed_out => "timed out",
        .refused => "refused by the responder",
        .too_large => "payload too large",
        .failed => "failed",
    };
}

// ---------------------------------------------------------------- diagnostics

/// qnnt's release version, e.g. "0.2.0". The wire format's is told_version().
export fn qnnt_version() callconv(.c) [*:0]const u8 {
    return version_z;
}

const version_z: [:0]const u8 = @import("build_options").version ++ "";

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
