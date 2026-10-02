const std = @import("std");
/// Topic-name matching, exported so every consumer reaches the SAME matcher: what
/// `qnnt-ls` shows, what `qnnt-cat` subscribes to, and what `subscribePattern` joins must
/// agree, and they cannot if each carries its own copy.
pub const topics = @import("topics.zig");
const Io = std.Io;
const net = std.Io.net;
const Stream = net.Stream;

/// The TLD binary framing, re-exported so users get the encoder and decoder without a
/// second import. See `subscribeFrames` for how it meets the pub/sub data path.
pub const Tld = @import("tld.zig");
/// 64-bit counters that also work on 32-bit CPUs; see atomic64.zig.
pub const Atomic64 = @import("atomic64.zig");

// Federating the registry across hosts. Kept in its own file: separate protocol, separate
// listener, separate workers. What it reaches back into here is marked below under
// "internal surface"; what this file uses from it is only the four calls named there.
const federation = @import("federation.zig");
const resolve = @import("resolve.zig");


const allocator = @import("alloc.zig").allocator;

// The 0.16 std.Io interface: a concrete implementation (`Threaded`) provides the
// `Io` fat pointer that every net/sleep call is threaded through. Both are process
// globals so the value stays stable while worker threads borrow `io`.
var io_impl: Io.Threaded = undefined;
pub var io: Io = undefined;

const QnntNode = struct {
    client: Stream,
    address: net.IpAddress, // peer, filled in by accept; for inspection only
    since_us: u64, // when it connected
    messages: u64, // messages successfully written to it
};

// One subscriber of one topic. Only the node publishing that topic holds the
// connections, so this is the shape it reports upward to the registry; see the
// `report` command in the wire conventions below.
pub const PeerRecord = struct {
    address: net.IpAddress,
    connected_us: u64, // how long it had been connected when the report was taken
    messages: u64,
};

// Two separate concerns, deliberately kept apart:
//
//  * `directory` — the shared discovery table (topic -> publisher URI). It lives on
//    whichever node currently holds the registry role, and is filled over the network
//    by `pub` registrations coming from publishers on ANY node. `sub` reads from it.
//    Keys are heap-owned because they arrive in transient network buffers.
//
//  * `subscribers` — this node's own delivery table (topic -> live subscriber
//    connections), for the topics THIS process publishes. Its accept loop fills it and
//    publishAll drains it. Keys are the static topic strings passed to runPublisher.
//
// Each has its own mutex; both are touched from multiple threads.
// What the directory knows about one topic. The timestamps exist for the human side
// of the interface: `pub` registrations are refreshed on a timer, so a registration
// that stopped being refreshed is how a dead publisher becomes visible.
/// How long after the last clashing announcement `list` keeps reporting CONFLICT. A
/// losing origin re-announces on every sync, so an unresolved clash keeps refreshing this
/// and stays visible; one that stops is over.
pub const conflict_window_us: u64 = 30 * std.time.us_per_s;

/// What a directory entry names. Topics and procedures share one namespace deliberately --
/// one directory means one federation path and one expiry rule for both -- so the entry has
/// to say which it is. Without that a subscriber could resolve a procedure and sit waiting
/// for a stream that will never come, while the responder waits for a request: two ends
/// blocked on each other, which is the worst way to report a name collision.
///
/// Values are on the wire (fed-entry's 7th field). Append, never renumber.
pub const EntryKind = enum(u8) {
    topic = 0,
    responder = 1,

    /// A kind off the wire. An unrecognised one comes from a peer newer than this build,
    /// and degrades to `.topic` rather than being dropped: the entry is still a real
    /// endpoint worth federating onward, and the worst that follows is that a local
    /// requester is told the name is a topic rather than a procedure.
    pub fn fromWire(value: u8) EntryKind {
        return switch (value) {
            0 => .topic,
            1 => .responder,
            else => .topic,
        };
    }
};

pub const TopicEntry = struct {
    endpoint: net.IpAddress,
    /// Stream or procedure. See `EntryKind`.
    kind: EntryKind = .topic,
    first_us: u64, // first time this topic was registered
    last_us: u64, // most recent refresh

    // The publishing node's subscriber list as of its last report. `peers_us` is when
    // that snapshot arrived — zero means the publisher has never reported, which is
    // different from reporting zero subscribers and is displayed differently.
    peers: std.ArrayList(PeerRecord),
    peers_us: u64,

    // The snapshot being assembled between `report begin` and `report end`, so a
    // half-delivered report never replaces a good one.
    pending: std.ArrayList(PeerRecord),

    // --- provenance, for federation ---

    /// Which node registered this topic. Compared as an opaque id, never parsed as an
    /// address: see the note on `NodeId`.
    origin: NodeId,

    /// Registered by a process on THIS host rather than learned from a peer. The registry
    /// listens on loopback only, so anything that arrives through `registerTopic` is local
    /// by construction -- which is what makes this a reliable answer to "is that port in
    /// use on this machine", the question the publisher port range has to ask.
    local: bool,

    /// The origin's own clock when it last published this state. Only ever compared
    /// against other versions from the SAME origin, which makes clock skew between hosts
    /// irrelevant -- no vector clocks and no NTP dependency -- and is also what stops an
    /// update from looping around a mesh forever.
    version: u64,

    /// When this node learned the entry. For a local registration that is the same as
    /// `last_us`; for one learned from a peer it is how remote entries age out.
    learned_us: u64,

    /// Set when another origin tried to claim a topic this one already holds. First
    /// registration wins, and the loser is reported rather than silently dropped: a
    /// duplicate topic name across hosts is a misconfiguration, and one that hides a
    /// publisher looks like "my data sometimes vanishes".
    /// When a second origin was last seen claiming this topic, or 0 if never. A timestamp
    /// rather than a flag because a clash is a condition, not a permanent property: the
    /// flag only ever went true, so one transient overlap -- a publisher restarting, a
    /// peer's stale copy arriving on connect -- marked the topic CONFLICT for as long as
    /// the entry lived, long after the rival was gone.
    conflict_us: u64,
};

pub var directory: std.StringHashMap(TopicEntry) = .init(allocator);

/// Bumped whenever the directory MATERIALLY changes -- a topic appears, its endpoint moves,
/// or it is removed. Deliberately not bumped by a refresh, which is why this can stand in
/// for a content digest: `version` is set to `now_us` on every refresh, so anything derived
/// from it changes every probe interval per publisher and a "has it changed?" check built
/// on it would always say yes.
///
/// The distinction already existed -- `registerTopic` computes `changed` precisely so
/// federation is not woken by heartbeats -- so this counter is that same signal, counted.
/// A standby quotes the epoch it last mirrored and the holder answers "unchanged" in a
/// dozen bytes instead of re-sending the directory.
///
/// Paired with the holder's NodeId on the wire, because the counter is per-process: a
/// standby that mirrored epoch 42 from one holder must not think it is current against a
/// different holder that happens to be at epoch 42.
pub var directory_epoch: Atomic64.Value = .init(0);
pub var directory_mutex: Io.Mutex = .init;

/// One place that says "the directory really changed": bump the epoch, then wake
/// federation. Both were previously the same call, and they still fire together -- the
/// epoch exists so a standby can ask cheaply whether it missed one.
fn markDirectoryChanged() void {
    bumpDirectoryEpoch();
    federation.notifyChange();
}

/// The directory changed, but not because anything here did it -- federation learned an
/// entry from a peer. Bumps the version WITHOUT waking the peer connectors.
///
/// Both halves matter. The bump matters because everything that watches for change watches
/// the epoch: a `subscribePattern` re-lists only when it moves, and a standby re-pulls the
/// mirror only when it moves, so a remote topic that arrived without one is a topic no
/// pattern subscription on this host will ever join. The absence of the notify matters
/// because whether a learned entry should be relayed onward is federation's decision, taken
/// at the call site that knows which peer it came from; waking every connector for every
/// entry received is how a mesh amplifies its own gossip.
pub fn bumpDirectoryEpoch() void {
    _ = directory_epoch.fetchAdd(1, .monotonic);
}

// When the current registry role was acquired, for `status`. Written by the registry
// thread and read by client handlers, hence atomic.
var registry_since_us: Atomic64.Value = .init(0);

// ---------------------------------------------------------------- shutdown
//
// Every worker here is a loop around a blocking socket call or a sleep, so stopping
// them needs three things: a flag they check, a way to break whatever they are blocked
// in, and their handles so they can be joined. Without the last two, `nodeDeinit` tears
// down `io` and the maps while threads are still using them.
//
// The bookkeeping below is guarded by `Io.Mutex` like everything else. That is safe
// because every use of it happens while `io` is still live: nodeDeinit does all of its
// signalling, breaking and joining *before* it tears `io` down, and touches none of
// these afterwards.

var shutting_down: std.atomic.Value(bool) = .init(false);

var workers: std.ArrayList(std.Thread) = .empty;
var workers_mutex: Io.Mutex = .init;

// Sockets a worker may be blocked on, and how to wake it. The two kinds need different
// treatment, which is the trap here: `shutdown` wakes a blocking read, but a listening
// socket is not connected, so on BSD/macOS shutdown fails with ENOTCONN and leaves
// `accept` blocked forever. Waking an accept portably takes a real connection.
const TrackedSocket = struct {
    socket: net.Socket,
    kind: enum { listener, stream },
};

var live_sockets: std.ArrayList(TrackedSocket) = .empty;
var live_sockets_mutex: Io.Mutex = .init;

// Longest a worker sleeps before re-checking the shutdown flag. Sleeps shorter than
// this are taken in one go, so ordinary publish pacing is untouched.
const shutdown_poll_ms = 50;

pub fn isShuttingDown() bool {
    // A plain flag with no data published through it, so monotonic is enough — and it
    // is read once per published frame on the unpaced path.
    return shutting_down.load(.monotonic);
}

// ---------------------------------------------------------------- per-topic teardown
//
// `nodeDeinit` stops everything at once: one flag, one sweep of the sockets, one join of
// every worker. That is the right shape for shutdown and the wrong shape for dropping a
// single topic, which is what `removePublisher` and `removeSubscriber` need.
//
// A token is the missing per-topic handle. It carries its own cancel flag, the threads
// spawned under it, and the sockets those threads block on -- the same three things the
// global path owns, scoped to one topic. Workers test `token.stopping()`, which is the
// global flag OR this token's, so a topic can be stopped on its own and a node shutdown
// still stops all of them.

const TopicKind = enum { publisher, subscriber, responder };

const TopicToken = struct {
    /// Owned, and the name the workers themselves use -- so a topic's name outlives the
    /// caller's slice for exactly as long as something is still running under it.
    topic: []const u8,
    kind: TopicKind,
    cancelled: std.atomic.Value(bool) = .init(false),
    threads: std.ArrayList(std.Thread) = .empty,
    sockets: std.ArrayList(TrackedSocket) = .empty,
    mutex: Io.Mutex = .init,

    fn stopping(t: *const TopicToken) bool {
        return isShuttingDown() or t.cancelled.load(.monotonic);
    }
};

var topic_tokens: std.ArrayList(*TopicToken) = .empty;
var topic_tokens_mutex: Io.Mutex = .init;

/// Which token the running thread belongs to, or null on a caller's own thread.
///
/// The guard against the one deadlock this feature invites: `removePublisher` joins the
/// topic's threads, so calling it from that topic's own source callback or message
/// handler would have the thread wait for itself. Set once as each worker starts.
threadlocal var current_topic_token: ?*TopicToken = null;

fn createTopicToken(topic: []const u8, kind: TopicKind) ?*TopicToken {
    topic_tokens_mutex.lockUncancelable(io);
    defer topic_tokens_mutex.unlock(io);

    if (isShuttingDown()) return null;
    topic_tokens.ensureUnusedCapacity(allocator, 1) catch return null;

    const token = allocator.create(TopicToken) catch return null;
    token.* = .{
        .topic = allocator.dupe(u8, topic) catch {
            allocator.destroy(token);
            return null;
        },
        .kind = kind,
    };
    topic_tokens.appendAssumeCapacity(token);
    return token;
}

/// Free a token and everything it owns. The caller must already have detached it and
/// joined its threads -- this frees the name those threads were using.
fn destroyTopicToken(token: *TopicToken) void {
    token.threads.deinit(allocator);
    token.sockets.deinit(allocator);
    allocator.free(token.topic);
    allocator.destroy(token);
}

/// Take a token out of the registry so nothing else can find it. Returns null when the
/// topic has no live worker of that kind.
fn detachTopicToken(topic: []const u8, kind: TopicKind) ?*TopicToken {
    topic_tokens_mutex.lockUncancelable(io);
    defer topic_tokens_mutex.unlock(io);

    for (topic_tokens.items, 0..) |token, i| {
        if (token.kind == kind and std.mem.eql(u8, token.topic, topic)) {
            return topic_tokens.swapRemove(i);
        }
    }
    return null;
}

/// Take one specific token out, for the path where a topic failed to start and the token
/// must not be left behind for a later `remove` to find.
fn detachTopicTokenPtr(token: *TopicToken) void {
    topic_tokens_mutex.lockUncancelable(io);
    defer topic_tokens_mutex.unlock(io);

    for (topic_tokens.items, 0..) |candidate, i| {
        if (candidate == token) {
            _ = topic_tokens.swapRemove(i);
            return;
        }
    }
}

/// As `spawnWorker`, but the thread is owned by `token` rather than the global list, so
/// stopping that topic joins it and a node shutdown still does through `joinWorkers`.
fn spawnWorkerFor(token: *TopicToken, comptime function: anytype, args: anytype) bool {
    token.mutex.lockUncancelable(io);
    defer token.mutex.unlock(io);

    // Under the same lock the remover takes, so there is no window: a spawn serialised
    // before the cancel lands in the list the remover takes, and one serialised after it
    // is refused here instead of starting a thread nothing would ever join.
    if (token.stopping()) return false;
    token.threads.ensureUnusedCapacity(allocator, 1) catch return false;

    const Shim = struct {
        fn run(t: *TopicToken, a: @TypeOf(args)) @typeInfo(@TypeOf(function)).@"fn".return_type.? {
            current_topic_token = t;
            applyRealtimePriority();
            return @call(.auto, function, a);
        }
    };

    const thread = std.Thread.spawn(.{}, Shim.run, .{ token, args }) catch return false;
    token.threads.appendAssumeCapacity(thread);
    return true;
}

/// `trackSocket` for a token's own workers: the token breaks these, not `breakLiveSockets`.
///
/// Deliberately NOT also registered globally. Registering in both wakes a listener twice at
/// shutdown -- once from `breakLiveSockets`, once from `breakTopicSockets` -- and each wake
/// is a real connection, since a listening socket cannot be shut down portably. The server
/// closes each one, leaving it in TIME_WAIT on the listener's port, and the next bind of
/// that port (publishers bind with reuse_address = false) fails. That surfaced as a
/// publisher in a configured range being handed a second port, which shifts every later
/// assignment in that range. `nodeDeinit` reaches these through `joinTopicTokens`.
fn trackSocketFor(
    token: *TopicToken,
    socket: net.Socket,
    kind: @FieldType(TrackedSocket, "kind"),
) bool {
    token.mutex.lockUncancelable(io);
    defer token.mutex.unlock(io);

    if (token.stopping()) return false;
    if (isShuttingDown()) return false; // the check `trackSocket` makes, for the same reason
    token.sockets.append(allocator, .{ .socket = socket, .kind = kind }) catch return false;
    return true;
}

fn untrackSocketFor(token: *TopicToken, socket: net.Socket) void {
    token.mutex.lockUncancelable(io);
    defer token.mutex.unlock(io);
    for (token.sockets.items, 0..) |tracked, i| {
        if (tracked.socket.handle == socket.handle) {
            _ = token.sockets.swapRemove(i);
            return;
        }
    }
}

/// Break the blocking calls this token's workers are in. Held under the token's lock for
/// the reason `breakLiveSockets` is: a worker untracks before it closes, so an entry seen
/// under the lock is still open and its handle cannot have been reused.
fn breakTopicSockets(token: *TopicToken) void {
    token.mutex.lockUncancelable(io);
    defer token.mutex.unlock(io);

    for (token.sockets.items) |tracked| switch (tracked.kind) {
        .stream => {
            const stream: Stream = .{ .socket = tracked.socket };
            stream.shutdown(io, .both) catch {};
        },
        .listener => {
            var waker = tracked.socket.address.connect(io, .{ .mode = .stream }) catch continue;
            waker.close(io);
        },
    };
}

/// Sleep, waking early when this topic is stopped or the node is. Returns false if the
/// caller should stop.
fn sleepUsInterruptibleFor(token: *TopicToken, us: u64) bool {
    var remaining = us;
    while (remaining > 0) {
        if (token.stopping()) return false;
        const slice = @min(remaining, shutdown_poll_ms * 1000);
        sleepUsFn(slice);
        remaining -= slice;
    }
    return !token.stopping();
}

fn sleepMsInterruptibleFor(token: *TopicToken, ms: u64) bool {
    return sleepUsInterruptibleFor(token, ms * 1000);
}

/// Cancel a token, break what its workers are blocked in, and join them. Returns with
/// every thread gone, so the caller may free what they were using.
fn stopTopicToken(token: *TopicToken) void {
    // Before the lock, so every later `spawnWorkerFor` and `trackSocketFor` refuses.
    token.cancelled.store(true, .monotonic);
    breakTopicSockets(token);

    // Move the threads out under the lock and join outside it: an exiting worker still
    // calls `untrackSocketFor`, which wants the same lock.
    token.mutex.lockUncancelable(io);
    var pending = token.threads;
    token.threads = .empty;
    token.mutex.unlock(io);

    for (pending.items) |thread| thread.join();
    pending.deinit(allocator);
}

/// Cancel a named worker of one kind, join it, and drop its registration.
///
/// The body of `removePublisher`, `removeSubscriber` and `removeResponder`: they differ in
/// which kind they look for and what they clean up afterwards, not in the teardown itself.
fn stopAndForget(name: []const u8, kind: TopicKind, label: []const u8) bool {
    // Guarded because these are documented as safe to call speculatively, and the obvious
    // place to call one is on the way out -- possibly after `deinit`, where the mutexes
    // below would be reaching for an `io` that is already gone.
    if (!node_running) return false;

    const token = detachTopicToken(name, kind) orelse return false;

    if (current_topic_token == token) {
        // Put it back: nothing was stopped, and leaving it detached would strand the
        // workers with no way to reach them again.
        topic_tokens_mutex.lockUncancelable(io);
        defer topic_tokens_mutex.unlock(io);
        topic_tokens.append(allocator, token) catch {};
        std.debug.print("{s} {s}: refused, called from its own thread\n", .{ label, name });
        return false;
    }

    stopTopicToken(token);

    // Only now that the accept loop is gone can the delivery connections be closed: a live
    // loop would be appending to the very list being torn down. Empty for a responder,
    // which finishes with each connection as it goes.
    {
        subscribers_mutex.lockUncancelable(io);
        defer subscribers_mutex.unlock(io);
        if (subscribers.fetchRemove(token.topic)) |entry| {
            var list = entry.value;
            for (list.items) |node| node.client.close(io);
            list.deinit(allocator);
        }
    }

    // Best effort, and deliberately after the workers are gone: the refresh loop would
    // otherwise re-register the name between this and its next tick. A registry that is
    // down or mid-failover just means the entry expires on its own instead.
    var buf: [256]u8 = undefined;
    var cmd_buf: [256]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "unpub {s}", .{token.topic}) catch "";
    if (cmd.len != 0) _ = registryCommand(cmd, &buf) catch {};

    destroyTopicToken(token);
    return true;
}

/// Stop publishing one topic on this node: its accept loop, its registry refresh and its
/// scheduler, then drop the registration and close the delivery connections.
///
/// Returns false when no publisher of that name is running here, and when called from one
/// of that publisher's own threads -- a source callback asking to remove its own topic
/// would otherwise wait for itself.
pub fn removePublisher(topic: []const u8) bool {
    return stopAndForget(topic, .publisher, "removePublisher");
}

/// Stop every subscription this node holds on `topic`, whichever flavour started it.
///
/// A topic joined by a glob stays gone: `patternLoop` never forgets what it has joined, so
/// its next rescan passes over this name rather than resubscribing.
pub fn removeSubscriber(topic: []const u8) bool {
    if (!node_running) return false; // see stopAndForget

    // Not `stopAndForget`: a topic may hold SEVERAL subscriptions and one call takes them
    // all, and a subscriber has no registration to drop -- only the publisher's entry names
    // the topic in the directory.
    var removed = false;
    while (detachTopicToken(topic, .subscriber)) |token| {
        if (current_topic_token == token) {
            topic_tokens_mutex.lockUncancelable(io);
            defer topic_tokens_mutex.unlock(io);
            topic_tokens.append(allocator, token) catch {};
            std.debug.print("removeSubscriber {s}: refused, called from its own thread\n", .{topic});
            return false;
        }

        stopTopicToken(token);

        // The stale sweeper reads this table; with the loop gone the entry would sit there
        // for ever, still claiming a connection.
        {
            sub_states_mutex.lockUncancelable(io);
            defer sub_states_mutex.unlock(io);
            if (sub_states.fetchRemove(token.topic)) |entry| allocator.free(entry.key);
        }

        destroyTopicToken(token);
        removed = true;
    }
    return removed;
}

/// Stop and free every remaining token. Shutdown only: `joinWorkers` has to reach these
/// threads too, and it runs after the global flag is already set, so the joins here are
/// against workers that are already winding down.
fn joinTopicTokens() void {
    while (true) {
        topic_tokens_mutex.lockUncancelable(io);
        const token = topic_tokens.pop();
        topic_tokens_mutex.unlock(io);

        const t = token orelse break;
        stopTopicToken(t);
        destroyTopicToken(t);
    }

    topic_tokens_mutex.lockUncancelable(io);
    defer topic_tokens_mutex.unlock(io);
    topic_tokens.clearAndFree(allocator);
}

// ---------------------------------------------------------------- memory locking

// Whether to pin the process's pages into RAM with mlockall, so a latency-critical path
// cannot be interrupted by a page fault. Off by default.
//
// Linux only, like the priority setting above, and this time std says so too: it declares
// MCL only for Linux and the BSDs, and mlockall is reachable as a raw syscall on Linux
// without needing libc.
//
// Its scope is the process, not a thread, which is why it is applied once in `nodeRun`
// rather than per worker. MCL_CURRENT pins everything already mapped -- worker stacks
// included, whenever they were created -- and MCL_FUTURE pins whatever gets mapped later.
var lock_memory_requested = false;

/// Ask for the process's memory to be locked into RAM before workers start. Must be called
/// before `run()`.
///
/// This is the second half of a real-time configuration, the first being
/// `setRealtimePriority`: a thread that cannot be preempted can still be stopped for
/// milliseconds by a major page fault, and no scheduling policy prevents that.
///
/// Pages are locked as they are first touched (MCL_ONFAULT), not pre-populated, so the
/// cost is only the memory actually used -- see the note in `applyMemoryLocking` for the
/// measurement that decided this. The consequence is that warm-up still faults; run the
/// path once before trusting its tail.
///
/// Be deliberate about it anyway. MCL_FUTURE means every later mapping is locked too, so a
/// process that grows can hit ENOMEM in an allocation far from here if RLIMIT_MEMLOCK is
/// not high enough, and locked pages cannot be reclaimed under pressure -- on a small
/// board that is memory the rest of the system no longer has.
pub fn setLockMemoryFn(enabled: bool) bool {
    if (node_running) return false;

    if (enabled and @import("builtin").os.tag != .linux) {
        std.debug.print(
            "memory locking ignored: mlockall is used here on Linux, and this is {s}\n",
            .{@tagName(@import("builtin").os.tag)},
        );
        return false;
    }

    lock_memory_requested = enabled;
    return true;
}

pub fn lockMemoryFn() bool {
    return lock_memory_requested;
}

// Applied once, at the top of nodeRun, before anything is spawned or allocated.
fn applyMemoryLocking() void {
    if (!lock_memory_requested) return;
    if (@import("builtin").os.tag != .linux) return;

    const linux = std.os.linux;

    // ONFAULT matters more than it looks. Without it, mlockall populates every mapping,
    // and this process reserves far more address space than it uses -- the allocator holds
    // ~440 MB of mostly untouched arenas. Measured on the i.MX board: 8.8 MB resident
    // normally, 184 MB with CURRENT|FUTURE, all of it unevictable, for a hot path that
    // needs about 9 MB. That is 10% of a 1.8 GB board pinned to no purpose.
    //
    // With ONFAULT a page is locked the first time it is touched and never faults again,
    // so the steady state is fault-free -- which is what a deadline needs -- without
    // pinning memory the process never uses. The cost is one minor fault per page during
    // warm-up, so let a real-time path run once before trusting its tail.
    var rc = linux.mlockall(.{ .CURRENT = true, .FUTURE = true, .ONFAULT = true });
    var err = linux.errno(rc);
    var on_fault = true;

    // ONFAULT arrived in Linux 4.4; older kernels reject the flag rather than ignore it.
    if (err == .INVAL) {
        rc = linux.mlockall(.{ .CURRENT = true, .FUTURE = true });
        err = linux.errno(rc);
        on_fault = false;
    }

    if (err == .SUCCESS) {
        if (on_fault) {
            std.debug.print("memory locked into RAM (mlockall CURRENT|FUTURE|ONFAULT: " ++
                "pages lock as they are first touched)\n", .{});
        } else {
            std.debug.print("memory locked into RAM (mlockall CURRENT|FUTURE; this kernel " ++
                "has no ONFAULT, so every mapping is resident and pinned)\n", .{});
        }
        return;
    }

    // Reported the same way a refused priority is, and for the same reason: a node that
    // silently runs unlocked after being asked to lock has lost a guarantee nobody will
    // notice is missing until a page fault lands in the middle of a deadline.
    std.debug.print(
        "memory locking REFUSED by the kernel ({s}); pages are NOT pinned and a page fault " ++
            "can still stall a worker. mlockall needs CAP_IPC_LOCK (setcap cap_ipc_lock+ep), " ++
            "root, or an RLIMIT_MEMLOCK ceiling above this process's size (ulimit -l).\n",
        .{@tagName(err)},
    );
}

// ---------------------------------------------------------------- realtime scheduling

// SCHED_FIFO priority for worker threads; 0 leaves them wherever the kernel put them.
//
// Linux only, and deliberately so. macOS grants real-time behaviour through
// thread_policy_set with a time-constraint policy, not through POSIX priorities, so
// accepting a priority there and calling pthread_setschedparam would report success while
// changing nothing that matters to a deadline. Refusing says more than pretending.
//
// Why this exists: benchmarking on an i.MX board with a low-latency (SMP PREEMPT) kernel
// gave a round trip bounded under 1.1 ms across 18,000 trips while the CPU was free, and
// a p99 seven times worse the moment four spinners contended for the cores. Low preemption
// latency is not a scheduling guarantee, and SCHED_OTHER threads wait their turn. See
// BENCHMARK.txt section B.5.
var rt_priority: std.atomic.Value(u8) = .init(0);

// Set once a worker has failed to obtain the policy, so the complaint is made exactly
// once. It is made loudly: a node that quietly keeps running at default priority after
// being asked for real-time is the worst possible outcome here, because the latency bound
// it was configured for simply will not be there and nothing will have said so.
var rt_failure_reported = std.atomic.Value(bool).init(false);

/// Ask for worker threads to run on SCHED_FIFO at `priority`. 0 disables, which is the
/// default. Must be called before `run()`, since it applies to threads as they start.
///
/// Returns false, having explained itself, if the platform cannot honour it or the
/// priority is out of the kernel's range. It does NOT return false for lack of privilege:
/// that is only discoverable when a thread actually tries, and is reported then.
///
/// The calling thread is left alone. A library that silently changed its caller's
/// scheduling policy would be overstepping; if the application's own thread needs
/// real-time it should say so itself.
pub fn setRealtimePriorityFn(priority: u8) bool {
    if (node_running) return false;

    if (priority == 0) {
        rt_priority.store(0, .monotonic);
        return true;
    }

    if (@import("builtin").os.tag != .linux) {
        std.debug.print(
            "realtime priority ignored: SCHED_FIFO is honoured on Linux, and this is {s}. " ++
                "Worker threads stay at default priority.\n",
            .{@tagName(@import("builtin").os.tag)},
        );
        return false;
    }

    const linux = std.os.linux;
    const fifo: linux.SCHED = .{ .mode = .FIFO };

    // Ask the kernel for its range rather than assuming 1..99: it is stable on Linux, but
    // an out-of-range priority fails per-thread later, which is a much worse place to
    // discover a typo than the configuration call.
    const min_rc = linux.sched_get_priority_min(fifo);
    const max_rc = linux.sched_get_priority_max(fifo);
    if (linux.errno(min_rc) != .SUCCESS or linux.errno(max_rc) != .SUCCESS) {
        std.debug.print("realtime priority ignored: kernel would not report the SCHED_FIFO range\n", .{});
        return false;
    }

    const min: u8 = @intCast(min_rc);
    const max: u8 = @intCast(max_rc);
    if (priority < min or priority > max) {
        std.debug.print(
            "realtime priority {d} out of range: this kernel accepts {d}..{d} for SCHED_FIFO\n",
            .{ priority, min, max },
        );
        return false;
    }

    rt_priority.store(priority, .monotonic);
    return true;
}

pub fn realtimePriorityFn() u8 {
    return rt_priority.load(.monotonic);
}

// Promote the calling thread. Runs first in every worker, before it touches a socket or a
// callback, so a worker is at its final priority for the whole of its life.
fn applyRealtimePriority() void {
    const priority = rt_priority.load(.monotonic);
    if (priority == 0) return;
    if (@import("builtin").os.tag != .linux) return;

    const linux = std.os.linux;
    const param: linux.sched_param = .{ .priority = priority };

    // pid 0 means the calling thread, which is the point: each worker promotes itself, so
    // the caller's thread and any thread the application owns are untouched.
    const rc = linux.sched_setscheduler(0, .{ .mode = .FIFO }, &param);
    const err = linux.errno(rc);
    if (err == .SUCCESS) return;

    if (!rt_failure_reported.swap(true, .monotonic)) {
        std.debug.print(
            "realtime priority {d} REFUSED by the kernel ({s}); worker threads are running " ++
                "at default priority and the latency bound you configured is not in effect. " ++
                "SCHED_FIFO needs CAP_SYS_NICE (setcap cap_sys_nice+ep on the binary), root, " ++
                "or an RLIMIT_RTPRIO ceiling at least this high (ulimit -r).\n",
            .{ priority, @tagName(err) },
        );
    }
}

// Spawn a worker and record it so shutdown can join it, returning false if it must not
// be started. Capacity is reserved before the thread starts, because a thread that
// starts but fails to be recorded is a thread that can never be joined — the exact leak
// this machinery exists to prevent.
//
// Like `trackSocket`, the shutdown check belongs inside this critical section. Without
// it, a worker spawned between `joinWorkers` moving the list out and the caller noticing
// the flag lands in the fresh list, is never joined, and outlives `io` — which shows up
// as the process failing at exit long after every visible operation succeeded.
pub fn spawnWorker(comptime function: anytype, args: anytype) bool {
    workers_mutex.lockUncancelable(io);
    defer workers_mutex.unlock(io);

    if (isShuttingDown()) return false;

    workers.ensureUnusedCapacity(allocator, 1) catch return false;

    // Every worker enters through this shim so it can promote itself before doing any
    // work. Setting the policy from inside the thread, rather than on it from outside,
    // means there is no window where a worker is already reading a socket at default
    // priority. The return type is preserved so error-returning workers behave exactly
    // as they did before.
    const Shim = struct {
        fn run(a: @TypeOf(args)) @typeInfo(@TypeOf(function)).@"fn".return_type.? {
            applyRealtimePriority();
            return @call(.auto, function, a);
        }
    };

    const thread = std.Thread.spawn(.{}, Shim.run, .{args}) catch return false;
    workers.appendAssumeCapacity(thread);
    return true;
}

// Register a socket a worker is about to block on, returning false if the caller must
// not block after all. Callers must untrack *before* closing, so a listed handle is
// always still open: shutdown holds the lock while it breaks them, so an entry it sees
// cannot have been closed and its fd reused.
//
// The shutdown check has to happen *inside* this critical section, and that is the whole
// reason this returns a value. `breakLiveSockets` runs once, so a worker that starts
// blocking after it has passed would never be interrupted. Testing the flag under the
// same lock leaves no gap: register before the break and the break sees you, register
// after it and you are told to stop instead.
pub fn trackSocket(socket: net.Socket, kind: @FieldType(TrackedSocket, "kind")) bool {
    live_sockets_mutex.lockUncancelable(io);
    defer live_sockets_mutex.unlock(io);

    if (isShuttingDown()) return false;

    // A failed append would leave shutdown unable to interrupt this socket, so treat it
    // as a refusal rather than blocking un-interruptibly.
    live_sockets.append(allocator, .{ .socket = socket, .kind = kind }) catch return false;
    return true;
}

pub fn untrackSocket(socket: net.Socket) void {
    live_sockets_mutex.lockUncancelable(io);
    defer live_sockets_mutex.unlock(io);
    for (live_sockets.items, 0..) |tracked, i| {
        if (tracked.socket.handle == socket.handle) {
            _ = live_sockets.swapRemove(i);
            return;
        }
    }
}

// Break every blocking call in progress. Shutdown only, and it closes nothing: each
// socket's owner still closes it on the way out.
//
// The connects below happen with the lock held. That is deliberate and safe: they are
// loopback connects taking microseconds, and a worker woken by one only needs this lock
// to untrack itself, which it can do once we are done — nothing here waits on a worker.
fn breakLiveSockets() void {
    live_sockets_mutex.lockUncancelable(io);
    defer live_sockets_mutex.unlock(io);

    for (live_sockets.items) |tracked| switch (tracked.kind) {
        // Connected, so shutting it down makes the pending read return.
        .stream => {
            const stream: Stream = .{ .socket = tracked.socket };
            stream.shutdown(io, .both) catch {};
        },
        // Not connected, so shutdown is a no-op on BSD. Hand it the one thing `accept`
        // does return for — a connection — and the worker wakes, sees the flag and
        // closes what it just accepted.
        .listener => {
            var waker = tracked.socket.address.connect(io, .{ .mode = .stream }) catch continue;
            waker.close(io);
        },
    };
}

// Shut down the connections this node delivers on. They are owned by the `subscribers`
// table rather than tracked as blocking reads, but `publishAll` can be parked in a write
// to one of them if a subscriber has stopped draining — and that would stall the join.
fn breakSubscriberStreams() void {
    subscribers_mutex.lockUncancelable(io);
    defer subscribers_mutex.unlock(io);

    var it = subscribers.iterator();
    while (it.next()) |entry| {
        for (entry.value_ptr.items) |node| node.client.shutdown(io, .both) catch {};
    }
}

fn joinWorkers() void {
    // Move the list out under the lock and join outside it: an exiting worker may still
    // call untrackSocket or (for the registry) try to spawn, and joining while holding
    // its lock would deadlock.
    workers_mutex.lockUncancelable(io);
    var pending = workers;
    workers = .empty;
    workers_mutex.unlock(io);

    for (pending.items) |thread| thread.join();
    pending.deinit(allocator);
}

// Sleep, but wake early when a shutdown starts. Returns false if the caller should stop.
// Sleeps up to `shutdown_poll_ms` are one call, so the publish scheduler's pacing is
// unaffected at any period a caller is likely to use.
fn sleepUsInterruptible(us: u64) bool {
    var remaining = us;
    while (remaining > 0) {
        if (isShuttingDown()) return false;
        const slice = @min(remaining, shutdown_poll_ms * 1000);
        sleepUsFn(slice);
        remaining -= slice;
    }
    return !isShuttingDown();
}

pub fn sleepMsInterruptible(ms: u64) bool {
    return sleepUsInterruptible(ms * 1000);
}

var subscribers: std.StringHashMap(std.ArrayList(QnntNode)) = .init(allocator);
var subscribers_mutex: Io.Mutex = .init;

// ---------------------------------------------------------------- connection events
//
// A publisher that starts producing before anyone has connected is publishing into
// nothing: qnnt has no replay, so those messages are gone. The mesh examples worked around
// it with a fixed startup delay, which is a guess. These events, and `waitForSubscriber`
// below, replace the guess with the fact.
//
// Threading: handlers run on the library's own threads -- the publisher's accept thread,
// the subscriber's read thread, or whichever thread called `publish` when a write to a
// dead subscriber revealed it. Not on the caller's thread, and not serialised with each
// other. Keep them short, and marshal to your own thread if you need more (the Qt wrapper
// does exactly that with a queued connection).
//
// A handler is called with NO library lock held. That is deliberate: an earlier draft
// emitted from inside the subscribers critical section, where a handler calling
// `subscriberCount` would have deadlocked against the lock it was already under.

pub const Event = enum(c_int) {
    /// A subscriber connected to one of this node's publishers.
    subscriber_connected = 0,
    /// A subscriber's connection was found broken while publishing to it.
    subscriber_disconnected = 1,
    /// This node's subscription attached to a publisher.
    publisher_connected = 2,
    /// A publisher this node was subscribed to closed the stream.
    publisher_disconnected = 3,
    /// Nothing has arrived on a connected subscription for `stale_timeout_ms`. Only
    /// emitted when that timeout is set; a quiet topic is not otherwise an error.
    publisher_stale = 4,
    /// Data arrived on a subscription that had gone stale.
    publisher_resumed = 5,
};

/// `peer` is the address the event concerns, as text, or empty when there is none to name.
/// `subscribers` is this node's current subscriber count for `topic` -- 0 for the
/// publisher_* events, which concern the other direction.
pub const EventHandler = *const fn (
    event: Event,
    topic: []const u8,
    peer: []const u8,
    subscribers: usize,
    context: ?*anyopaque,
) void;

var event_handler: ?EventHandler = null;
var event_context: ?*anyopaque = null;
var event_mutex: Io.Mutex = .init;

/// Register the handler for connection events, or clear it with null. May be called before
/// or after `run()`.
pub fn setEventHandlerFn(handler: ?EventHandler, context: ?*anyopaque) void {
    event_mutex.lockUncancelable(io);
    defer event_mutex.unlock(io);
    event_handler = handler;
    event_context = context;
}

fn emitEvent(event: Event, topic: []const u8, peer: []const u8, subscriber_count: usize) void {
    // Buffered first, so a slow handler cannot delay what a poller would have seen.
    eventQueuePush(event, topic, peer, subscriber_count);

    // Copy the handler out under the lock and call it outside, so a handler that
    // re-registers or clears itself cannot deadlock, and a long handler cannot block
    // another thread's emit.
    var handler: ?EventHandler = null;
    var context: ?*anyopaque = null;
    {
        event_mutex.lockUncancelable(io);
        defer event_mutex.unlock(io);
        handler = event_handler;
        context = event_context;
    }
    if (handler) |h| h(event, topic, peer, subscriber_count, context);
}

// -- event queue --------------------------------------------------------------------
//
// The same trade as the message queue, for the same reason. A callback is delivered on a
// library thread, which is wrong for a language that has to take a lock to run any code at
// all: a ctypes callback would acquire the GIL on this node's accept thread, and then a
// Python handler would be holding up the library while it ran. Buffering here and letting
// the consumer drain at its own pace removes both problems.
//
// Buffered unconditionally rather than on request, so no event is lost before a consumer
// gets around to its first poll -- which is exactly when the interesting ones happen. The
// cost is a mutex and a ~120 byte copy per *connection*, not per message.

const event_queue_capacity = 64;

const EventSlot = struct {
    event: Event = .subscriber_connected,
    topic: [64]u8 = undefined,
    topic_len: usize = 0,
    peer: [48]u8 = undefined,
    peer_len: usize = 0,
    subscribers: usize = 0,
    at_us: u64 = 0,
};

var event_ring: [event_queue_capacity]EventSlot = undefined;
var event_ring_head: usize = 0;
var event_ring_count: usize = 0;
var event_ring_mutex: Io.Mutex = .init;
var event_dropped = Atomic64.Value.init(0);

// Where a drain copies to, so the slices handed out stay valid until the next drain -- the
// same contract as `poll` for messages.
var event_staging: [event_queue_capacity]EventSlot = undefined;

/// One buffered event. `topic` and `peer` are valid until the next `pollEvents`.
pub const PolledEvent = struct {
    event: Event,
    topic: []const u8,
    peer: []const u8,
    subscribers: usize,
    at_us: u64,
};

fn eventQueuePush(event: Event, topic: []const u8, peer: []const u8, subscriber_count: usize) void {
    event_ring_mutex.lockUncancelable(io);
    defer event_ring_mutex.unlock(io);

    if (event_ring_count == event_queue_capacity) {
        // The newest is dropped, as in the message queue: a consumer that has stopped
        // draining should not be able to push out the history it has not read yet.
        _ = event_dropped.fetchAdd(1, .monotonic);
        return;
    }

    const slot = &event_ring[(event_ring_head + event_ring_count) % event_queue_capacity];
    slot.event = event;
    slot.topic_len = @min(topic.len, slot.topic.len);
    @memcpy(slot.topic[0..slot.topic_len], topic[0..slot.topic_len]);
    slot.peer_len = @min(peer.len, slot.peer.len);
    @memcpy(slot.peer[0..slot.peer_len], peer[0..slot.peer_len]);
    slot.subscribers = subscriber_count;
    slot.at_us = @intCast(nowMicrosFn());
    event_ring_count += 1;
}

/// Drain up to `out.len` buffered events. Returns the slice actually filled; the strings it
/// points at stay valid until the next call.
pub fn pollEventsFn(out: []PolledEvent) []PolledEvent {
    if (out.len == 0) return out[0..0];

    event_ring_mutex.lockUncancelable(io);
    defer event_ring_mutex.unlock(io);

    const take = @min(out.len, @min(event_ring_count, event_queue_capacity));
    for (0..take) |i| {
        event_staging[i] = event_ring[(event_ring_head + i) % event_queue_capacity];
        const slot = &event_staging[i];
        out[i] = .{
            .event = slot.event,
            .topic = slot.topic[0..slot.topic_len],
            .peer = slot.peer[0..slot.peer_len],
            .subscribers = slot.subscribers,
            .at_us = slot.at_us,
        };
    }
    event_ring_head = (event_ring_head + take) % event_queue_capacity;
    event_ring_count -= take;
    return out[0..take];
}

/// Events discarded because nothing drained the queue.
pub fn eventsDroppedFn() u64 {
    return event_dropped.load(.monotonic);
}

/// How many subscribers are connected to this node's publisher for `topic`. 0 if this node
/// does not publish it.
pub fn subscriberCountFn(topic: []const u8) usize {
    subscribers_mutex.lockUncancelable(io);
    defer subscribers_mutex.unlock(io);
    if (subscribers.getPtr(topic)) |list| return list.items.len;
    return 0;
}

/// Block until `topic` has at least one connected subscriber, or the timeout expires.
/// Returns whether there is one. A timeout of 0 polls once and returns immediately.
///
/// This is the answer to "when may I start publishing": a subscriber cannot attach until
/// this publisher has registered AND the subscriber's next registry probe comes round, so
/// the delay is neither zero nor predictable. Waiting for the event beats sleeping for a
/// guess.
pub fn waitForSubscriberFn(topic: []const u8, timeout_ms: u64) bool {
    return waitForSubscribersFn(topic, 1, timeout_ms);
}

/// Block until `topic` has at least `count` connected subscribers, or the timeout expires.
///
/// The plural form matters when a node knows how many peers to expect: waiting for one
/// subscriber stops a publisher shouting into an empty room, but the second and third peers
/// still miss the opening messages. Waiting for all of them means every peer sees the
/// stream from its first message.
pub fn waitForSubscribersFn(topic: []const u8, count: usize, timeout_ms: u64) bool {
    if (subscriberCountFn(topic) >= count) return true;
    if (timeout_ms == 0) return false;

    const deadline = @as(u64, @intCast(nowMicrosFn())) + timeout_ms * 1000;
    while (@as(u64, @intCast(nowMicrosFn())) < deadline) {
        // Polled rather than signalled: the wait happens once at startup, so 5 ms of
        // latency costs nothing and a condition variable would be state to get wrong.
        if (!sleepMsInterruptible(5)) return false;
        if (subscriberCountFn(topic) >= count) return true;
    }
    return subscriberCountFn(topic) >= count;
}

// -- subscription liveness ----------------------------------------------------------
//
// Tracked here rather than in the subscribe loops because the loops block in `read`, and a
// thread blocked in a read cannot notice that nothing has arrived. One sweeper watches the
// timestamps instead.

const SubState = struct {
    connected: bool = false,
    stale: bool = false,
    last_us: u64 = 0,
};

var sub_states: std.StringHashMap(SubState) = .init(allocator);
var sub_states_mutex: Io.Mutex = .init;

/// Silence after which a connected subscription is reported stale. 0 disables it, which is
/// the default: a topic may legitimately be quiet, and calling that an error by default
/// would make the feature a nuisance.
var stale_timeout_ms: u64 = 0;

pub fn setStaleTimeoutFn(ms: u64) void {
    stale_timeout_ms = ms;
}

pub fn staleTimeoutFn() u64 {
    return stale_timeout_ms;
}

fn subMark(topic: []const u8, connected: bool) void {
    sub_states_mutex.lockUncancelable(io);
    defer sub_states_mutex.unlock(io);

    const gop = sub_states.getOrPut(topic) catch return;
    if (!gop.found_existing) {
        // The key must outlive the caller's slice: subscribe topics are already copied at
        // the ABI boundary, but a Zig caller may pass a temporary.
        gop.key_ptr.* = allocator.dupe(u8, topic) catch {
            _ = sub_states.remove(topic);
            return;
        };
        gop.value_ptr.* = .{};
    }
    gop.value_ptr.connected = connected;
    gop.value_ptr.stale = false;
    gop.value_ptr.last_us = @intCast(nowMicrosFn());
}

/// Called from the delivery path on every message, so staleness is measured from real
/// traffic rather than from the connection's age.
fn subTouch(topic: []const u8) void {
    if (stale_timeout_ms == 0) return;

    var resumed = false;
    {
        sub_states_mutex.lockUncancelable(io);
        defer sub_states_mutex.unlock(io);
        if (sub_states.getPtr(topic)) |state| {
            state.last_us = @intCast(nowMicrosFn());
            if (state.stale) {
                state.stale = false;
                resumed = true;
            }
        }
    }
    if (resumed) emitEvent(.publisher_resumed, topic, "", 0);
}

// One sweeper for every subscription, started with the node.
fn staleSweepRun() void {
    while (!isShuttingDown()) {
        if (!sleepMsInterruptible(200)) return;
        const timeout = stale_timeout_ms;
        if (timeout == 0) continue;

        const now: u64 = @intCast(nowMicrosFn());

        // Collected under the lock and emitted after it, for the reason given above.
        var stale_topics: [16][]const u8 = undefined;
        var count: usize = 0;
        {
            sub_states_mutex.lockUncancelable(io);
            defer sub_states_mutex.unlock(io);

            var it = sub_states.iterator();
            while (it.next()) |entry| {
                const state = entry.value_ptr;
                if (!state.connected or state.stale) continue;
                if (now -| state.last_us < timeout * 1000) continue;
                state.stale = true;
                if (count < stale_topics.len) {
                    stale_topics[count] = entry.key_ptr.*;
                    count += 1;
                }
            }
        }

        for (stale_topics[0..count]) |topic| {
            emitEvent(.publisher_stale, topic, "", 0);
        }
    }
}


pub const Qnnt = struct {
    // Every callback takes the `context` pointer given at registration and hands it
    // back untouched. Without it a callback can only reach module-level state, which
    // means one handler cannot serve two subscriptions, and no closure, C++ lambda or
    // Python callable can be bound to one — it is `void *user_data` under a Zig name.
    // The library never dereferences it.

    // Callback invoked once per message received on a subscribed topic. It runs on
    // the subscriber's own background thread (asynchronously w.r.t. the caller), so
    // it must be thread-safe. `msg` points into the read buffer and is only valid
    // for the duration of the call — copy it if you need to keep it.
    pub const MessageHandler = *const fn (topic: []const u8, msg: []const u8, context: ?*anyopaque) void;

    // Callback invoked once per scheduler tick on a topic this node publishes, to
    // produce the payload for that tick. Returning null skips the tick (nothing is
    // sent). It runs on the publisher's own scheduler thread, so it must be
    // thread-safe. The payload is written to the subscriber sockets AFTER the
    // callback returns, so it must outlive the call: return a literal, a global, or
    // heap memory the callback keeps alive — never a buffer on the callback's frame.
    pub const SourceHandler = *const fn (topic: []const u8, context: ?*anyopaque) ?[]const u8;

    /// Callback for a TLD-framed subscription. `frame` borrows a buffer owned by the
    /// subscriber thread and is only valid for the duration of the call — copy
    /// anything you keep, including the slices its accessors return.
    pub const FrameHandler = *const fn (topic: []const u8, frame: Tld.Frame, context: ?*anyopaque) void;

    pub const run = &nodeRun;
    pub const runPublisher = &publisherRun;
    pub const publish = &publishAll;
    pub const subscribe = &subscribeRun;
    /// Opt-in: subscribe to every topic matching a glob, now and as they appear. See
    /// `subscribePatternRun` for what it costs -- a poll, and one connection per match.
    pub const subscribePattern = &subscribePatternRun;
    pub const subscribeFrames = &subscribeFramesRun;
    /// `subscribePattern` for TLD frames.
    pub const subscribePatternFrames = &subscribePatternFramesRun;

    /// Stop publishing one topic without stopping the node: joins that publisher's
    /// threads, drops its registration and closes its delivery connections. False when no
    /// such publisher is running here. See `removePublisher`.
    pub const removePublisher = &@import("qnnt.zig").removePublisher;
    /// Stop subscribing to one topic without stopping the node. A topic reached through a
    /// glob stays gone -- the pattern does not rejoin it. See `removeSubscriber`.
    pub const removeSubscriber = &@import("qnnt.zig").removeSubscriber;

    // --- request/reply -------------------------------------------------------------
    //
    // The other shape: one request, one reply, addressed to a name. See the notes above
    // `RpcStatus` for the wire and why discovery reuses the topic directory.

    /// Serves one request. See `ResponderHandlerFn` for the lifetime of what it returns.
    pub const ResponderHandler = ResponderHandlerFn;
    /// How a request ended. See `RpcStatus`.
    pub const RpcStatus = @import("qnnt.zig").RpcStatus;
    /// One completed request, as `pollReplies` hands it back. See `QueuedReply`.
    pub const QueuedReply = @import("qnnt.zig").QueuedReply;

    /// Serve `procedure` on this node. Requests are answered one at a time.
    pub const addResponder = &addResponderRun;
    /// Stop serving it, and drop its registration. Sibling of `removePublisher`.
    pub const removeResponder = &@import("qnnt.zig").removeResponder;

    /// One request, on the calling thread, returning when the reply arrives or the timeout
    /// expires. A control-plane call: it costs a connection. See `requestRun`.
    pub const request = &requestRun;

    /// Start a request and return a ticket immediately. The reply is collected with
    /// `pollReplies`, never through a callback on a library thread. See `requestBeginRun`.
    pub const requestBegin = &requestBeginRun;
    /// Drain completed requests, as `poll` drains messages.
    pub const pollReplies = &@import("qnnt.zig").pollReplies;
    /// How many requests started with `requestBegin` have not yet completed.
    pub const requestsInFlight = &@import("qnnt.zig").requestsInFlight;

    /// The topics the registry knows, for discovery: see `listTopics`.
    pub const listTopics = &@import("qnnt.zig").listTopics;

    /// One command to the registry, reply returned verbatim: see `registryCommand`.
    pub const registryCommand = &@import("qnnt.zig").registryCommand;

    /// Buffered subscription: messages land in a queue the caller drains with `poll`,
    /// rather than arriving on a library thread. See the notes above `QueuedMessage`.
    pub const subscribeQueue = &subscribeQueueRun;
    /// `subscribeQueue` over a glob.
    pub const subscribePatternQueue = &subscribePatternQueueRun;
    pub const poll = &queuePoll;
    pub const reserveQueue = &queueReserve;
    pub const queueDropped = &queueDroppedCount;
    pub const deinit = &nodeDeinit;
    pub const sleepMs = &sleepMsFn;

    /// The frame size cap, honoured when publishing and when subscribing. See
    /// `default_max_frame_bytes`.
    pub const maxFrameBytes = &@import("qnnt.zig").maxFrameBytes;
    pub const setMaxFrameBytes = &setMaxFrameBytesFn;
    pub const default_max_frame_bytes = @import("qnnt.zig").default_max_frame_bytes;
    /// Microsecond sleep, for anything pacing itself against the scheduler's own unit --
    /// a capture replayed at its recorded rate, for instance.
    pub const sleepUs = &sleepUsFn;
    pub const nowMicros = &nowMicrosFn;

    /// Take publisher ports from `low..high` instead of letting the OS choose, so a
    /// firewall can forward them. See the note on the publisher port range. `(0, 0)` puts
    /// it back to ephemeral. Set before starting publishers.
    pub const setPublisherPorts = &setPublisherPortsFn;

    /// "2300-2399" -> the pair, for a caller reading its own configuration.
    pub const parsePublisherPorts = &@import("qnnt.zig").parsePublisherPorts;

    /// Registry port control. Set before `run()`; see `setRegistryPort`.
    pub const setRegistryPort = &setRegistryPortFn;
    pub const registryPort = &currentRegistryPort;
    pub const Event = @import("qnnt.zig").Event;
    pub const EventHandler = @import("qnnt.zig").EventHandler;
    pub const setEventHandler = &setEventHandlerFn;
    pub const subscriberCount = &subscriberCountFn;
    pub const waitForSubscriber = &waitForSubscriberFn;
    pub const waitForSubscribers = &waitForSubscribersFn;
    pub const PolledEvent = @import("qnnt.zig").PolledEvent;
    pub const pollEvents = &pollEventsFn;
    pub const eventsDropped = &eventsDroppedFn;
    pub const setStaleTimeout = &setStaleTimeoutFn;
    pub const staleTimeout = &staleTimeoutFn;

    pub const setRealtimePriority = &setRealtimePriorityFn;
    pub const realtimePriority = &realtimePriorityFn;
    pub const setLockMemory = &setLockMemoryFn;
    pub const lockMemory = &lockMemoryFn;

    /// Addressing. Both must be set before `run()`. Defaults keep everything on
    /// loopback, so a local deployment is unchanged and nothing is exposed unasked.
    pub const setAdvertiseAddress = &setAdvertiseAddressFn;
    pub const setBindAddress = &setBindAddressFn;
    pub const advertiseAddress = &advertiseAddressFn;

    /// This node's identity: 32 hex characters, random per process, independent of any
    /// address. See the note on `NodeId` for why it is not derived from one.
    pub const nodeIdText = &nodeIdTextFn;

    /// Apply configuration from the process environment: one call, one implementation,
    /// shared by every language binding. Explicit rather than automatic — see lib/env.zig.
    pub const configureFromEnvironment = &@import("env.zig").configureFromEnvironment;

    /// Federation. All must be set before `run()`. Federation stays off unless a port
    /// AND a cluster key are given.
    pub const setFederationPort = &federation.setPort;
    pub const setClusterKey = &federation.setClusterKey;
    pub const addPeer = &federation.addPeer;
    pub const federationEnabled = &federation.enabled;

    /// Opt in to handling Ctrl-C and SIGTERM. Off by default: a library must not
    /// install process-wide handlers behind its host's back, nor replace one the host
    /// already set. Call it after `run()` — see `installSignalHandlers`.
    pub const installSignalHandlers = &installShutdownHandlers;

    /// True once a stop has been requested, by a handled signal or by `deinit`. An
    /// application whose main thread has nothing to do can loop on this and fall
    /// through to its own `deinit` when it flips.
    pub const stopRequested = &isShuttingDown;
};

// Parse "tcp://<host>:<port>" into an address. Rejects anything else (e.g. the
// registry's "error: ..." replies).
fn parseTcpUri(text: []const u8) !net.IpAddress {
    const trimmed = std.mem.trim(u8, text, " \r\n");
    if (!std.mem.startsWith(u8, trimmed, "tcp://")) return error.MalformedUri;
    const hostport = trimmed["tcp://".len..];
    const colon = std.mem.lastIndexOfScalar(u8, hostport, ':') orelse return error.MalformedUri;
    const host = hostport[0..colon];
    const port = std.fmt.parseInt(u16, hostport[colon + 1 ..], 10) catch return error.MalformedUri;
    return net.IpAddress.parse(host, port);
}

// The registry speaks one line-oriented protocol to two very different kinds of
// client — the nodes in this library, and whoever pointed `nc` at port 2222 — so it
// has to stay parseable while reading well in a terminal. The conventions:
//
//  * one command per line, one response per command; commands and their aliases are
//    case-insensitive, and surrounding whitespace (including telnet's CRLF) is ignored;
//  * lines beginning with '#' are informational — the session banner, table headers,
//    summaries — and are skipped by machine clients (see `takeReply`), so prose can be
//    added for humans without breaking any parser;
//  * failures answer with a single line starting "error: ";
//  * the commands nodes depend on (`pub`, `sub`) answer in exactly one data line, and
//    `sub`'s is the bare publisher URI. That shape is load-bearing — don't dress it up.
pub const comment_prefix = "#";

// Written after every non-empty reply. Informational, so it is invisible to machine
// clients, and it is what lets an interactive client know a reply is complete.
pub const response_terminator = "# end\n";

// A registration is considered stale once it has missed a few refresh cycles. Only
// ever reported, never acted on: a stale entry is still served, since a publisher that
// went quiet is not necessarily gone and the subscriber will retry anyway.
const stale_after_us: u64 = 3 * registry_probe_interval_ms * 1000;

pub const Reply = struct {
    text: []const u8, // heap-owned; caller frees
    close: bool = false, // hang up after sending, for `quit`
};

pub fn eqlAny(verb: []const u8, names: []const []const u8) bool {
    for (names) |name| if (std.ascii.eqlIgnoreCase(verb, name)) return true;
    return false;
}

pub fn ownedReply(buffer: *std.ArrayList(u8)) !Reply {
    return .{ .text = try buffer.toOwnedSlice(allocator) };
}

fn usageReply(buffer: *std.ArrayList(u8), usage: []const u8) !Reply {
    try buffer.print(allocator, "error: usage: {s}\n", .{usage});
    return ownedReply(buffer);
}

pub fn errorReply(buffer: *std.ArrayList(u8), reason: []const u8) !Reply {
    try buffer.print(allocator, "error: {s}\n", .{reason});
    return ownedReply(buffer);
}

const report_usage = "report <topic> begin | peer <uri> <connected_us> <msgs> | end";

fn clientCommand(command: []const u8) !Reply {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);

    var it = std.mem.tokenizeAny(u8, command, " \t\r\n");
    const verb = it.next() orelse return ownedReply(&buffer); // bare Enter: stay quiet

    if (eqlAny(verb, &.{ "list", "ls" })) {
        try writeTopicList(&buffer);
    } else if (eqlAny(verb, &.{"pub"})) {
        // "pub <topic> tcp://<host>:<port>" — a publisher registering its endpoint.
        const topic = it.next() orelse return usageReply(&buffer, "pub <topic> <uri>");
        const uri = it.next() orelse return usageReply(&buffer, "pub <topic> <uri>");
        const endpoint = parseTcpUri(uri) catch {
            try buffer.print(allocator, "error: malformed uri '{s}', expected tcp://<host>:<port>\n", .{uri});
            return ownedReply(&buffer);
        };
        try registerTopic(topic, endpoint, node_id, .topic);
        try buffer.print(allocator, "ok\n", .{});
    } else if (eqlAny(verb, &.{"rpc"})) {
        // "rpc <procedure> tcp://<host>:<port>" — a responder registering its endpoint.
        // Same directory as `pub`, so federation and expiry come for free; the entry is
        // marked so a subscriber cannot resolve it by mistake.
        const name = it.next() orelse return usageReply(&buffer, "rpc <procedure> <uri>");
        const uri = it.next() orelse return usageReply(&buffer, "rpc <procedure> <uri>");
        const endpoint = parseTcpUri(uri) catch {
            try buffer.print(allocator, "error: malformed uri '{s}', expected tcp://<host>:<port>\n", .{uri});
            return ownedReply(&buffer);
        };
        try registerTopic(name, endpoint, node_id, .responder);
        try buffer.print(allocator, "ok\n", .{});
    } else if (eqlAny(verb, &.{"rpc-find"})) {
        // `sub` for procedures, and deliberately a separate verb: it refuses to answer for
        // a streaming topic. A requester that got a publisher's address here would send a
        // request nobody reads and then wait out its timeout on every call.
        const name = it.next() orelse return usageReply(&buffer, "rpc-find <procedure>");
        directory_mutex.lockUncancelable(io);
        defer directory_mutex.unlock(io);
        if (directory.get(name)) |entry| {
            if (entry.kind != .responder) {
                try buffer.print(allocator, "error: {s} is a topic, not a procedure\n", .{name});
            } else if (!federation.entryIsServable(&entry, @intCast(nowMicrosFn()))) {
                try buffer.print(allocator, "error: procedure {s} expired\n", .{name});
            } else {
                try buffer.print(allocator, "tcp://{f}\n", .{entry.endpoint});
            }
        } else {
            try buffer.print(allocator, "error: procedure {s} not found\n", .{name});
        }
    } else if (eqlAny(verb, &.{"sub"})) {
        // Hand the subscriber the complete URI of the topic's publisher so it
        // can connect there directly.
        const topic = it.next() orelse return usageReply(&buffer, "sub <topic>");
        directory_mutex.lockUncancelable(io);
        defer directory_mutex.unlock(io);
        if (directory.get(topic)) |entry| {
            // The mirror of `rpc-find`'s check: a subscriber handed a responder's address
            // would connect and wait for a stream that only arrives in reply to a request.
            if (entry.kind != .topic) {
                try buffer.print(allocator, "error: {s} is a procedure, not a topic\n", .{topic});
            } else
            // A remote entry whose origin has gone quiet is withheld rather than handed
            // out: pointing a subscriber at an unreachable host only makes it retry.
            if (!federation.entryIsServable(&entry, @intCast(nowMicrosFn()))) {
                try buffer.print(allocator, "error: topic {s} expired\n", .{topic});
            } else {
                try buffer.print(allocator, "tcp://{f}\n", .{entry.endpoint});
            }
        } else {
            try buffer.print(allocator, "error: topic {s} not found\n", .{topic});
        }
    } else if (eqlAny(verb, &.{"subs"})) {
        const topic = it.next() orelse return usageReply(&buffer, "subs <topic>");
        try writeSubscriberList(&buffer, topic);
    } else if (eqlAny(verb, &.{"report"})) {
        // Node protocol: a publishing node handing over its subscriber list, which is
        // knowledge the registry has no other way to obtain.
        const topic = it.next() orelse return usageReply(&buffer, report_usage);
        const phase = it.next() orelse return usageReply(&buffer, report_usage);

        if (eqlAny(phase, &.{"begin"})) {
            if (!beginPeerReport(topic)) return errorReply(&buffer, "topic not registered");
        } else if (eqlAny(phase, &.{"peer"})) {
            const uri = it.next() orelse return usageReply(&buffer, report_usage);
            const connected = it.next() orelse return usageReply(&buffer, report_usage);
            const messages = it.next() orelse return usageReply(&buffer, report_usage);

            const record: PeerRecord = .{
                .address = parseTcpUri(uri) catch return errorReply(&buffer, "malformed peer uri"),
                .connected_us = std.fmt.parseInt(u64, connected, 10) catch return errorReply(&buffer, "malformed connected_us"),
                .messages = std.fmt.parseInt(u64, messages, 10) catch return errorReply(&buffer, "malformed msgs"),
            };
            if (!try addPeerReport(topic, record)) return errorReply(&buffer, "topic not registered");
        } else if (eqlAny(phase, &.{"end"})) {
            if (!commitPeerReport(topic)) return errorReply(&buffer, "topic not registered");
        } else {
            return usageReply(&buffer, report_usage);
        }
        try buffer.print(allocator, "ok\n", .{});
    } else if (eqlAny(verb, &.{ "unpub", "rm" })) {
        // Drop a registration by hand. The publisher's own refresh will put it back
        // within a probe interval if it is still alive — which makes this a way to
        // ask "is this entry a leftover?" and get an answer.
        const topic = it.next() orelse return usageReply(&buffer, "unpub <topic>");
        if (unregisterTopic(topic)) {
            try buffer.print(allocator, "ok\n", .{});
        } else {
            try buffer.print(allocator, "error: topic {s} not found\n", .{topic});
        }
    } else if (eqlAny(verb, &.{"peers"})) {
        try federation.writePeerList(&buffer);
    } else if (eqlAny(verb, &.{"mirror"})) {
        // `mirror` alone: the whole directory. `mirror <holder-id> <epoch>`: the whole
        // directory, or a one-line "you are current" if nothing material has changed
        // since that epoch.
        //
        // The holder's id is checked as well as the epoch because the counter is
        // per-process. A standby holding epoch 42 from a previous holder is not current
        // against a new one that happens to have reached 42 by a different route, and
        // answering "unchanged" there would leave it mirroring a directory it never saw.
        var id_buf: [32]u8 = undefined;
        const mine = formatNodeId(&id_buf, node_id);
        const epoch = directory_epoch.load(.monotonic);

        const their_id = it.next();
        const their_epoch = it.next();
        const current = their_id != null and their_epoch != null and
            std.mem.eql(u8, their_id.?, mine) and
            (std.fmt.parseInt(u64, their_epoch.?, 10) catch (epoch +% 1)) == epoch;

        if (current) {
            try buffer.print(allocator, "mirror-unchanged {s} {d}\n", .{ mine, epoch });
        } else {
            try buffer.print(allocator, "mirror-state {s} {d}\n", .{ mine, epoch });
            // The publisher port range travels with the directory, and only here -- it is a
            // property of THIS HOST's firewall, so federating it would push one host's
            // forwarding rules onto another where they are meaningless.
            //
            // A standby inherits it so that the registry role can move without the range
            // being lost. That is not hypothetical: `qnnt-ls` and `qnnt-cat` start real
            // nodes and can win the election, and neither has any reason to be configured
            // with a port range. Without this, a tool becoming the registry would answer
            // every publisher "take what you like" and quietly un-forward the whole host.
            if (publisherPortsConfigured()) {
                try buffer.print(allocator, "mirror-ports {d} {d}\n",
                    .{ publisher_port_low, publisher_port_high });
            }
            try federation.writeFedEntries(&buffer);
        }
    } else if (eqlAny(verb, &.{"port"})) {
        // `port <topic>` -> the port that topic should listen on, or 0 for "take what you
        // like". `port <topic> skip <n>` when the asker has just failed to bind <n>.
        //
        // Answered by the registry rather than decided by each publisher because the range
        // is a HOST resource shared by every process on it, and only the registry sees them
        // all.
        const want = it.next() orelse return errorReply(&buffer, "port needs a topic");
        var avoid: u16 = 0;
        if (it.next()) |kw| {
            if (eqlAny(kw, &.{ "skip", "not" })) {
                avoid = std.fmt.parseInt(u16, it.next() orelse "", 10) catch
                    return errorReply(&buffer, "skip needs a port");
            }
        }
        const assigned = assignPublisherPort(want, avoid) catch
            return errorReply(&buffer, "publisher port range is full");
        try buffer.print(allocator, "{d}\n", .{assigned});
    } else if (eqlAny(verb, &.{"epoch"})) {
        // Deliberately tiny, because it is polled. A pattern subscriber asks this a few
        // times a second and only pays for `list` when the answer has moved.
        //
        // The holder's id travels with it for the same reason the mirror carries it: the
        // counter is per-process, so a new holder after a failover starts its own count
        // and a client holding an old number must not read that as "nothing changed".
        var id_buf: [32]u8 = undefined;
        try buffer.print(allocator, "{s} {d}\n", .{
            formatNodeId(&id_buf, node_id),
            directory_epoch.load(.monotonic),
        });
    } else if (eqlAny(verb, &.{ "status", "stat" })) {
        try writeStatus(&buffer);
    } else if (eqlAny(verb, &.{"ping"})) {
        try buffer.print(allocator, "pong\n", .{});
    } else if (eqlAny(verb, &.{ "help", "h", "?" })) {
        try writeHelp(&buffer);
    } else if (eqlAny(verb, &.{ "quit", "exit", "q" })) {
        try buffer.print(allocator, "# bye\n", .{});
        return .{ .text = try buffer.toOwnedSlice(allocator), .close = true };
    } else {
        try buffer.print(allocator, "error: unknown command '{s}', type 'help'\n", .{verb});
    }

    return ownedReply(&buffer);
}

fn writeHelp(buffer: *std.ArrayList(u8)) !void {
    try buffer.print(allocator,
        \\# commands (case-insensitive):
        \\#   list                 registered topics: publisher, subscribers, age, state
        \\#   subs <topic>         who is subscribed to a topic: address, connected, messages
        \\#   sub <topic>          resolve a topic to its publisher URI
        \\#   pub <topic> <uri>    register or refresh a topic's publisher endpoint
        \\#   epoch                who holds the directory, and its version
        \\#   port <topic> [skip n] the port that topic should listen on, 0 for 'any'
        \\#   mirror [id epoch]    the directory, or 'unchanged' if you are current
        \\#   unpub <topic>        drop a registration
        \\#   peers                other REGISTRIES federated with this one, not subscribers
        \\#   status               registry uptime, topic count, timings
        \\#   ping                 liveness check
        \\#   help                 this text
        \\#   quit                 close the connection
        \\# aliases: ls, rm, stat, h, ?, q, exit
        \\# subscriber figures come from the publishing nodes, which report them with
        \\# each refresh, so they lag by up to one probe interval; 'subs' says how stale.
        \\# node protocol: report <topic> begin | peer <uri> <connected_us> <msgs> | end
        \\# '#' lines are informational; failures reply "error: <reason>".
        \\# every non-empty reply ends with '# end'.
        \\
    , .{});
}

// Human-readable age. The exact figure matters less than being able to tell at a
// glance which registrations have gone quiet.
pub fn formatAge(buf: []u8, age_us: u64) []const u8 {
    const secs = age_us / 1_000_000;
    if (secs < 10) return std.fmt.bufPrint(buf, "{d}.{d}s", .{ secs, (age_us % 1_000_000) / 100_000 }) catch "?";
    if (secs < 60) return std.fmt.bufPrint(buf, "{d}s", .{secs}) catch "?";
    return std.fmt.bufPrint(buf, "{d}m{d:0>2}s", .{ secs / 60, secs % 60 }) catch "?";
}

pub fn writePadded(buffer: *std.ArrayList(u8), text: []const u8, width: usize) !void {
    try buffer.appendSlice(allocator, text);
    if (width > text.len) try buffer.appendNTimes(allocator, ' ', width - text.len);
}

// Wide enough for the header word and any value formatAge produces ("12m34s").
const age_column_width = "refreshed".len;

const subs_column_width = "subs".len;

// "local", or the first 8 hex characters of a remote origin -- enough to tell origins
// apart in a log without turning the table into a wall of hex.
const origin_column_width = 8;

// One row of the topic table. Header and data rows are both rendered from this, with
// the same widths, so they cannot drift out of alignment.
const TopicRow = struct {
    lead: []const u8, // "# " for the header, "  " for data, so columns line up
    topic: []const u8,
    publisher: []const u8,
    subs: []const u8,
    refreshed: []const u8,
    age: []const u8,
    origin: []const u8,
    state: []const u8,
};

const TopicWidths = struct {
    topic: usize,
    publisher: usize,
};

fn writeTopicRow(buffer: *std.ArrayList(u8), widths: TopicWidths, row: TopicRow) !void {
    try buffer.appendSlice(allocator, row.lead);
    try writePadded(buffer, row.topic, widths.topic);
    try buffer.appendSlice(allocator, "  ");
    try writePadded(buffer, row.publisher, widths.publisher);
    try buffer.appendSlice(allocator, "  ");
    try writePadded(buffer, row.subs, subs_column_width);
    try buffer.appendSlice(allocator, "  ");
    try writePadded(buffer, row.refreshed, age_column_width);
    try buffer.appendSlice(allocator, "  ");
    try writePadded(buffer, row.age, age_column_width);
    try buffer.appendSlice(allocator, "  ");
    try writePadded(buffer, row.origin, origin_column_width);
    try buffer.appendSlice(allocator, "  ");
    try buffer.appendSlice(allocator, row.state);
    try buffer.appendSlice(allocator, "\n");
}

// "tcp://" + a formatted address; ample for IPv6 with a port.
fn formatPublisher(buf: []u8, endpoint: net.IpAddress) []const u8 {
    return std.fmt.bufPrint(buf, "tcp://{f}", .{endpoint}) catch "tcp://?";
}

fn writeTopicList(buffer: *std.ArrayList(u8)) !void {
    directory_mutex.lockUncancelable(io);
    defer directory_mutex.unlock(io);

    if (directory.count() == 0) {
        try buffer.print(allocator, "# no topics registered\n", .{});
        return;
    }

    // Size the topic and publisher columns to their content so the table lines up
    // without leaving a gutter wide enough for addresses nobody has.
    var topic_width: usize = "topic".len;
    var publisher_width: usize = "publisher".len;
    var sizing = directory.iterator();
    while (sizing.next()) |entry| {
        var uri_buf: [64]u8 = undefined;
        topic_width = @max(topic_width, entry.key_ptr.len);
        publisher_width = @max(publisher_width, formatPublisher(&uri_buf, entry.value_ptr.endpoint).len);
    }

    const widths: TopicWidths = .{ .topic = topic_width, .publisher = publisher_width };

    // Header carries the '#' prefix; data rows are indented by two to match it.
    try writeTopicRow(buffer, widths, .{
        .lead = "# ",
        .topic = "topic",
        .publisher = "publisher",
        .subs = "subs",
        .refreshed = "refreshed",
        .age = "age",
        .origin = "origin",
        .state = "state",
    });

    // Wall clock, so it can step backwards across an NTP adjustment; saturating
    // subtraction keeps that from wrapping into a bogus 584,000-year age.
    const now_us: u64 = @intCast(nowMicrosFn());
    var stale_count: usize = 0;

    var entries = directory.iterator();
    while (entries.next()) |entry| {
        const refreshed_us = now_us -| entry.value_ptr.last_us;
        const is_stale = refreshed_us > stale_after_us;
        if (is_stale) stale_count += 1;

        var uri_buf: [64]u8 = undefined;
        var refreshed_buf: [16]u8 = undefined;
        var age_buf: [16]u8 = undefined;
        var subs_buf: [16]u8 = undefined;
        var origin_buf: [32]u8 = undefined;

        // "-" rather than "0" when the publisher has never reported: not knowing the
        // count is a different fact from knowing it is zero.
        const subs = if (entry.value_ptr.peers_us == 0)
            "-"
        else
            std.fmt.bufPrint(&subs_buf, "{d}", .{entry.value_ptr.peers.items.len}) catch "?";

        try writeTopicRow(buffer, widths, .{
            .lead = "  ",
            .topic = entry.key_ptr.*,
            .publisher = formatPublisher(&uri_buf, entry.value_ptr.endpoint),
            .subs = subs,
            .refreshed = formatAge(&refreshed_buf, refreshed_us),
            .age = formatAge(&age_buf, now_us -| entry.value_ptr.first_us),
            .origin = if (std.mem.eql(u8, &entry.value_ptr.origin, &node_id))
                "local"
            else
                formatNodeId(&origin_buf, entry.value_ptr.origin)[0..origin_column_width],
            // A conflict outranks the liveness state: the entry is live, but a second
            // origin is claiming the same topic name and losing. Shown only while the
            // clash is current, so the column reports what is happening now rather than
            // what happened once.
            .state = if (entry.value_ptr.conflict_us != 0 and
                now_us -| entry.value_ptr.conflict_us <= conflict_window_us)
                "CONFLICT"
            else if (is_stale) "stale" else "live",
        });
    }

    if (stale_count == 0) {
        try buffer.print(allocator, "# {d} topic(s)\n", .{directory.count()});
    } else {
        try buffer.print(allocator, "# {d} topic(s), {d} not refreshed in {d}ms\n", .{
            directory.count(),
            stale_count,
            stale_after_us / 1000,
        });
    }
}

// Detail for every subscriber of one topic, from the publishing node's last report.
// Every column is left as-of that report rather than advanced to now: the age and the
// message count then belong to the same instant, so msgs/connected is the topic's
// actual delivery rate. The header says how old the snapshot is.
fn writeSubscriberList(buffer: *std.ArrayList(u8), topic: []const u8) !void {
    directory_mutex.lockUncancelable(io);
    defer directory_mutex.unlock(io);

    const entry = directory.getPtr(topic) orelse {
        try buffer.print(allocator, "error: topic {s} not found\n", .{topic});
        return;
    };

    if (entry.peers_us == 0) {
        try buffer.print(allocator, "# {s}: publisher has not reported subscribers yet\n", .{topic});
        return;
    }

    const now_us: u64 = @intCast(nowMicrosFn());
    const snapshot_us = now_us -| entry.peers_us;

    var snapshot_buf: [16]u8 = undefined;
    try buffer.print(allocator, "# subscribers of {s}, reported {s} ago\n", .{
        topic,
        formatAge(&snapshot_buf, snapshot_us),
    });

    if (entry.peers.items.len == 0) {
        try buffer.print(allocator, "# no subscribers\n", .{});
        return;
    }

    // Labelled "subscriber", not "peer". Within this one interface "peer" was being used
    // for both a topic's subscriber and a federated registry -- and `peers` means the
    // latter, which made `subs` output read as though it listed the wrong thing. The node
    // protocol's `report ... peer <uri>` token keeps its name: it is a wire format, and
    // both ends of it are in this repository, so the ambiguity there costs nobody.
    var peer_width: usize = "subscriber".len;
    for (entry.peers.items) |peer| {
        var buf: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{f}", .{peer.address}) catch "?";
        peer_width = @max(peer_width, text.len);
    }

    try buffer.appendSlice(allocator, "# ");
    try writePadded(buffer, "subscriber", peer_width);
    try buffer.appendSlice(allocator, "  ");
    try writePadded(buffer, "connected", age_column_width);
    try buffer.appendSlice(allocator, "  msgs\n");

    for (entry.peers.items) |peer| {
        var peer_buf: [64]u8 = undefined;
        var connected_buf: [16]u8 = undefined;

        try buffer.appendSlice(allocator, "  ");
        try writePadded(buffer, std.fmt.bufPrint(&peer_buf, "{f}", .{peer.address}) catch "?", peer_width);
        try buffer.appendSlice(allocator, "  ");
        try writePadded(buffer, formatAge(&connected_buf, peer.connected_us), age_column_width);
        try buffer.print(allocator, "  {d}\n", .{peer.messages});
    }

    try buffer.print(allocator, "# {d} subscriber(s)\n", .{entry.peers.items.len});
}

fn writeStatus(buffer: *std.ArrayList(u8)) !void {
    const now_us: u64 = @intCast(nowMicrosFn());

    const topic_count = blk: {
        directory_mutex.lockUncancelable(io);
        defer directory_mutex.unlock(io);
        break :blk directory.count();
    };

    const since_us = registry_since_us.load(.monotonic);
    var uptime_buf: [16]u8 = undefined;
    const uptime = if (since_us == 0) "?" else formatAge(&uptime_buf, now_us -| since_us);

    try buffer.print(allocator, "uptime {s}\n", .{uptime});
    try buffer.print(allocator, "topic_count {d}\n", .{topic_count});
    var id_buf: [32]u8 = undefined;
    try buffer.print(allocator, "node {s}\n", .{formatNodeId(&id_buf, node_id)});
    try buffer.print(allocator, "advertise {s}\n", .{advertiseText()});
    try buffer.print(allocator, "port {d}\n", .{registry_port});
    // Shown because the commonest way to get this wrong is invisible otherwise: a node
    // holding the registry WITHOUT a range answers every publisher "take what you like",
    // and the host quietly stops being forwardable while every process looks healthy.
    if (publisherPortsConfigured()) {
        try buffer.print(allocator, "publisher-ports {d}-{d}\n",
            .{ publisher_port_low, publisher_port_high });
    } else {
        try buffer.print(allocator, "publisher-ports ephemeral\n", .{});
    }
    try buffer.print(allocator, "probe-interval {d}ms\n", .{registry_probe_interval_ms});
    try buffer.print(allocator, "bind-retry {d}ms\n", .{registry_bind_retry_ms});
    try buffer.print(allocator, "registry-role {s}\n", .{@tagName(registry_role)});
    try buffer.print(allocator, "registry-mirror {s}\n", .{if (registry_mirror) "on" else "off"});
    try buffer.print(allocator, "directory-epoch {d}\n", .{directory_epoch.load(.monotonic)});
    try buffer.print(allocator, "stale-after {d}ms\n", .{stale_after_us / 1000});
    if (federation.enabled()) {
        try buffer.print(allocator, "federation port {d}\n", .{federation.currentPort()});
    } else {
        try buffer.print(allocator, "federation off\n", .{});
    }
}

// Record (or refresh) a topic's publisher endpoint in the discovery directory.
// The topic key arrives in a transient network buffer, so it is heap-owned on
// first insert and left untouched on refresh.
fn registerTopic(topic: []const u8, endpoint: net.IpAddress, origin: NodeId, kind: EntryKind) !void {
    const now_us: u64 = @intCast(nowMicrosFn());

    // Notified after the lock is released: waking a connector while holding the directory
    // mutex would have it block on the very lock it needs to serialise what it was woken
    // for.
    var changed = false;
    defer if (changed) markDirectoryChanged();

    directory_mutex.lockUncancelable(io);
    defer directory_mutex.unlock(io);

    const gop = try directory.getOrPut(topic);
    if (!gop.found_existing) {
        gop.key_ptr.* = allocator.dupe(u8, topic) catch |err| {
            _ = directory.remove(topic);
            return err;
        };
        gop.value_ptr.* = .{
            .endpoint = endpoint,
            .first_us = now_us,
            .last_us = now_us,
            .peers = .empty,
            .peers_us = 0,
            .pending = .empty,
            .origin = origin,
            .version = now_us,
            .learned_us = now_us,
            .conflict_us = 0,
            .local = true,
            .kind = kind,
        };
        changed = true;
        return;
    }

    // Same origin: an ordinary refresh. The endpoint is re-read rather than assumed,
    // since a restarted publisher comes back on a different ephemeral port. Two local
    // publishers of one topic still overwrite each other exactly as before, because they
    // share this node's origin.
    if (std.mem.eql(u8, &gop.value_ptr.origin, &origin)) {
        // A moved endpoint is structural (the publisher restarted on a new port); a
        // version bump on its own is just the refresh heartbeat.
        if (!std.meta.eql(gop.value_ptr.endpoint, endpoint)) changed = true;
        gop.value_ptr.endpoint = endpoint;
        gop.value_ptr.last_us = now_us;
        gop.value_ptr.version = now_us;
        gop.value_ptr.local = true;
        gop.value_ptr.kind = kind;
        return;
    }

    // A different origin holds this topic. A LOCAL publisher takes it over regardless of
    // who got there first: this node is authoritative for topics its own publishers
    // serve, and deferring to a remote claim would route local subscribers across the
    // network while a perfectly good local publisher sits idle. First-wins settles
    // clashes *between remote origins*; local always beats remote.
    //
    // Federation made this visible: a peer's entries arrive on connect, which is well
    // before the local publisher's first refresh, so "first" was almost always the remote
    // one and every host ended up preferring someone else's publisher.
    gop.value_ptr.conflict_us = now_us;
    gop.value_ptr.local = true;
    gop.value_ptr.kind = kind;
    gop.value_ptr.origin = origin;
    gop.value_ptr.endpoint = endpoint;
    gop.value_ptr.last_us = now_us;
    gop.value_ptr.version = now_us;
    gop.value_ptr.learned_us = now_us;
    changed = true;
}

fn unregisterTopic(topic: []const u8) bool {
    var removed = false;
    defer if (removed) markDirectoryChanged();

    directory_mutex.lockUncancelable(io);
    defer directory_mutex.unlock(io);

    if (directory.fetchRemove(topic)) |kv| {
        var entry = kv.value;
        entry.peers.deinit(allocator);
        entry.pending.deinit(allocator);
        allocator.free(kv.key); // owned on insert
        removed = true;
        return true;
    }
    return false;
}

// The three phases of a subscriber report from a publishing node. Each returns false
// if the topic is unknown here — which happens legitimately, when a publisher reports
// to a registry elected after the publisher started and its `pub` hasn't landed yet.
fn beginPeerReport(topic: []const u8) bool {
    directory_mutex.lockUncancelable(io);
    defer directory_mutex.unlock(io);

    const entry = directory.getPtr(topic) orelse return false;
    entry.pending.clearRetainingCapacity();
    return true;
}

fn addPeerReport(topic: []const u8, record: PeerRecord) !bool {
    directory_mutex.lockUncancelable(io);
    defer directory_mutex.unlock(io);

    const entry = directory.getPtr(topic) orelse return false;
    try entry.pending.append(allocator, record);
    return true;
}

fn commitPeerReport(topic: []const u8) bool {
    directory_mutex.lockUncancelable(io);
    defer directory_mutex.unlock(io);

    const entry = directory.getPtr(topic) orelse return false;

    // Swap instead of copying, so the retired snapshot's capacity is reused for the
    // next one rather than being reallocated every probe interval.
    std.mem.swap(std.ArrayList(PeerRecord), &entry.peers, &entry.pending);
    entry.pending.clearRetainingCapacity();
    entry.peers_us = @intCast(nowMicrosFn());
    return true;
}

fn handleRegistryClient(client: Stream) !void {
    defer client.close(io);

    // Untracked before the close above, so this handle is only listed while open.
    if (!trackSocket(client.socket, .stream)) return;
    defer untrackSocket(client.socket);

    var rbuf: [1024]u8 = undefined;
    var reader = client.reader(io, &rbuf);

    // empty writer buffer => writes go straight through
    var writer = client.writer(io, &.{});

    // Informational, so machine clients skip it; a human gets a hint instead of
    // connecting to silence and wondering whether anything is listening.
    // Terminated like any other reply, so a client can use one "read until '# end'" loop
    // from the moment it connects instead of special-casing the greeting.
    try writer.interface.writeAll("# qnnt registry, type 'help' for commands\n");
    try writer.interface.writeAll(response_terminator);

    while (!isShuttingDown()) {
        const chunk = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            // Gone, cleanly (FIN) or not (RST, e.g. a client killed mid-command). Both are
            // ordinary on an interactive port; propagating either printed a worker-thread
            // stack trace and made a normal disconnect look like a fault.
            error.EndOfStream, error.ReadFailed => return,
            error.StreamTooLong => {
                // A line too long for the read buffer. Say so and resynchronize on the
                // next newline rather than dropping an interactive session over it.
                try writer.interface.writeAll("error: line too long\n");
                _ = reader.interface.discardDelimiterInclusive('\n') catch return;
                continue;
            },
        };

        const reply = try clientCommand(chunk);
        defer allocator.free(reply.text);
        try writer.interface.writeAll(reply.text);

        // Terminate every non-empty reply. Without this a client cannot tell where a
        // multi-line reply ends and has to fall back on an idle timeout, which measured
        // 81.6 ms per command against 0.47 ms when the length is known. It is an
        // informational line, so machine clients skip it exactly as they skip the banner
        // (see `takeReply`) and nothing that already works has to change. A blank input
        // line still produces nothing at all, so no reply means no terminator either.
        if (reply.text.len > 0) try writer.interface.writeAll(response_terminator);

        if (reply.close) return;
    }
}

// Read the next line that isn't informational. Machine clients go through this so the
// registry stays free to print banners and headers at humans (see the conventions
// above) without those lines being mistaken for a response.
fn takeReply(reader: *Io.Reader) Io.Reader.DelimiterError![]u8 {
    while (true) {
        const line = try reader.takeDelimiterInclusive('\n');
        if (!std.mem.startsWith(u8, line, comment_prefix)) return line;
    }
}

// Consume the rest of a reply, terminator included.
//
// Not tidiness -- required. Closing a socket that still holds unread received data makes
// the kernel send RST rather than FIN, and the peer's next read then fails with
// ECONNRESET. Leaving the '# end' line unread was enough to make every registration close
// abortively, which showed up as a stack trace from the registry's client handler on a
// node that was doing nothing but running.
//
// The returned slice from `takeReply` points into the reader's buffer, so callers must
// finish with the line before draining.
fn drainReply(reader: *Io.Reader) void {
    while (true) {
        const line = reader.takeDelimiterInclusive('\n') catch return;
        if (std.mem.startsWith(u8, line, "# end")) return;
    }
}

// Read a reply and discard it, leaving the connection on a reply boundary.
fn discardReply(reader: *Io.Reader) void {
    _ = takeReply(reader) catch return;
    drainReply(reader);
}

// The registry lives on a well-known port. Every node contends for it; whoever binds
// first plays the registry role, the rest stand by. The bind must therefore be mutually
// exclusive, which rules out `IpAddress.listen`'s `reuse_address`: its docstring says it
// sets SO_REUSEADDR *and* SO_REUSEPORT, and SO_REUSEPORT is precisely the option that
// lets two live listeners share a port — it would silently dissolve the election.
//
// But leaving both off has its own cost: a lingering TIME_WAIT socket on the port blocks
// the next bind, and this node's own shutdown creates one whenever it closes an accepted
// registry connection (the server closing first is what puts *its* end in TIME_WAIT).
// One such socket is enough to lock every node out for an MSL — around 15 s here — which
// stalls failover and makes a restarted node unable to take the role it just released.
//
// SO_REUSEADDR alone is exactly the fix: it permits binding over TIME_WAIT while two
// listeners on one address still collide. Since std bundles the two options together,
// the listener is opened by hand in `listenRegistry`.
// ---------------------------------------------------------------- node identity
//
// A node's identity is a random 128-bit id, NOT its address.
//
// That is forced by how nodes are actually deployed: a host may bind 0.0.0.0 and have no
// idea which of its addresses a peer will reach it on, and behind a gateway its public
// address is chosen by the gateway and never visible locally at all. An address-derived
// identity would be unknowable to its owner, and would change whenever the gateway's
// choice changed.
//
// So identity and reachability are separated. The id names the origin of a directory
// entry and is what version comparisons and loop suppression key on. Addresses are
// routing hints, and the rule for them is that the OBSERVER decides: whoever wants to
// dial a publisher uses the address it reached that publisher's host on, paired with the
// port from the entry. A node never has to know its own address for others to reach it.
pub const NodeId = [16]u8;

pub var node_id: NodeId = @splat(0);
var node_id_set = false;

fn ensureNodeId() void {
    if (node_id_set) return;
    io.random(&node_id);
    node_id_set = true;
}

pub fn formatNodeId(buf: *[32]u8, id: NodeId) []const u8 {
    return std.fmt.bufPrint(buf, "{x}", .{id}) catch buf[0..0];
}

/// This node's id, as 32 hex characters. Stable for the process lifetime.
pub fn nodeIdTextFn(buf: *[32]u8) []const u8 {
    return formatNodeId(buf, node_id);
}

// ---------------------------------------------------------------- addressing
//
// Three addresses, previously all hardcoded to loopback:
//
//  * the registry listener stays on loopback, always. It carries the human interface and
//    the destructive commands, and neither belongs on a network.
//  * publishers bind `bind_addr` (what the socket listens on).
//  * publishers advertise `advertise_addr` (what a subscriber is told to dial).
//
// The default is loopback for both, so a purely local deployment behaves exactly as
// before and no port is exposed by accident. Setting an advertise address is the explicit
// opt-in to being reachable, and `bind_addr` then defaults to 0.0.0.0 to match, because
// advertising an address you are not listening on is never useful.
//
// The advertised address is NOT auto-detected. Multi-homed hosts, containers and NAT all
// defeat "pick the first non-loopback interface", and a wrong guess here is a silent
// data-path failure: a remote subscriber dials an address that either refuses or, worse,
// reaches a different publisher holding that port on its own machine.

const loopback_text = "127.0.0.1";
const any_text = "0.0.0.0";

var advertise_buf: [resolve.max_host_text]u8 = undefined; // fits IPv6 text
pub var advertise_len: usize = 0; // 0 => loopback default
var bind_buf: [resolve.max_host_text]u8 = undefined;
var bind_len: usize = 0; // 0 => follow the advertise address

pub fn advertiseText() []const u8 {
    return if (advertise_len == 0) loopback_text else advertise_buf[0..advertise_len];
}

pub fn bindText() []const u8 {
    if (bind_len != 0) return bind_buf[0..bind_len];

    // An explicit advertise address means "be reachable there", so listen widely.
    if (advertise_len != 0) return any_text;

    // Federation on with no advertise address is the NORMAL case, not an omission: the
    // whole point of letting each peer fill in the address it reached us on is that we
    // need not know our own. But that only works if we are actually listening on the
    // interface they arrive over, so this must be 0.0.0.0 rather than loopback.
    //
    // Getting this wrong made federation bind 127.0.0.1 and look fine on one machine
    // while being unreachable from any other.
    if (federation.enabled()) return any_text;

    // Nothing asked to be reachable: stay private and expose no port by accident.
    return loopback_text;
}

// ---------------------------------------------------------------- publisher port range
//
// By default a publisher binds port 0 and takes whatever the OS gives it. That is right for
// a routed network and wrong for one with a firewall in it: nobody can forward a port they
// cannot predict, which is why federation crosses a NAT happily -- one well-known port per
// host -- while the data plane does not.
//
// A range makes the data plane forwardable. `QNNT_PUBLISHER_PORTS=2300-2399` and one rule
// covers every topic on the host.
//
// THE REGISTRY ARBITRATES, not each publisher independently. Several processes on one host
// share the range, and only the registry sees all of them; two publishers picking "the
// first free port" would race, and a publisher picking by hash would collide. So a
// publisher asks and the registry answers -- with a port, with 0 for "no range here, take
// what you like", or with a refusal when the range is full.
//
// The answer is STICKY, and that matters more than it looks. A federated entry is served
// for up to `fed_serve_until_us` after a peer learned it, and each hop restarts that clock,
// so a remote subscriber can hold a dead publisher's address for tens of seconds. The data
// connection carries no topic name -- a subscriber cannot tell it reached the wrong
// publisher -- so handing a recycled port to a DIFFERENT topic would deliver one topic's
// frames under another's name, silently. Stickiness comes from the directory itself: a
// topic's entry holds its port, so a restarting publisher gets its own port back, and a
// stale entry still points where it always meant to.
//
// Allocation is round-robin over the range rather than lowest-free, for the same reason: a
// freed port becomes the LAST to be handed out again instead of the first, so reuse takes a
// full lap of the range instead of happening immediately.
//
// The assignment is advisory. The registry does not hold the socket, so a port it names can
// be taken between the answer and the bind; the publisher says which one failed and asks
// again.

/// 0,0 means unset: publishers bind port 0 and the registry answers "take what you like".
pub var publisher_port_low: u16 = 0;
pub var publisher_port_high: u16 = 0;

/// Where the next round-robin scan starts. Not reset when a port is freed -- that is the
/// point of it.
var publisher_port_cursor: u16 = 0;

pub fn publisherPortsConfigured() bool {
    return publisher_port_low != 0 and publisher_port_high >= publisher_port_low;
}

pub fn setPublisherPortsFn(low: u16, high: u16) bool {
    if (low == 0 and high == 0) {
        publisher_port_low = 0;
        publisher_port_high = 0;
        return true;
    }
    if (low == 0 or high < low) return false;
    publisher_port_low = low;
    publisher_port_high = high;
    if (publisher_port_cursor < low or publisher_port_cursor > high) publisher_port_cursor = low;
    return true;
}

/// "2300-2399" -> the pair. A single port is a range of one.
pub fn parsePublisherPorts(text: []const u8, low: *u16, high: *u16) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return false;
    const dash = std.mem.indexOfScalar(u8, trimmed, '-');
    const lo_text = if (dash) |d| trimmed[0..d] else trimmed;
    const hi_text = if (dash) |d| trimmed[d + 1 ..] else trimmed;
    const lo = std.fmt.parseInt(u16, std.mem.trim(u8, lo_text, " \t"), 10) catch return false;
    const hi = std.fmt.parseInt(u16, std.mem.trim(u8, hi_text, " \t"), 10) catch return false;
    if (lo == 0 or hi < lo) return false;
    low.* = lo;
    high.* = hi;
    return true;
}

pub const PortAssignError = error{RangeFull};

/// How many times a publisher will re-ask after losing a race for the port it was given.
/// Each attempt costs one loopback round trip and names the port that failed, so the
/// registry converges quickly; the bound is only here so a host whose range is being eaten
/// by something else fails loudly instead of spinning.
const publisher_port_attempts = 8;

/// Bind the listener a publisher will accept on, taking its port from the registry when a
/// range is configured.
fn listenForPublisher(topic: []const u8) !net.Server {
    if (!publisherPortsConfigured()) {
        const addr: net.IpAddress = try .parse(bindText(), 0);
        return addr.listen(io, .{ .reuse_address = false });
    }

    // Two different retries, deliberately not one counter. Waiting for a registry is
    // unbounded, exactly as `registerLoop` waits -- a node whose registry is mid-election
    // should come up when it finishes, not give up. Losing a race for a named port is
    // bounded, because something else on the host is eating the range and spinning on that
    // would hide it.
    var avoid: u16 = 0;
    var lost_races: usize = 0;
    var announced_wait = false;

    while (!isShuttingDown()) {
        const port = requestPublisherPort(topic, avoid) orelse {
            // No registry answered. Retrying rather than falling back to port 0: a range is
            // configured, so an ephemeral port would be a publisher that works perfectly on
            // this host and is unreachable from the network the range exists for.
            if (!announced_wait) {
                announced_wait = true;
                std.debug.print(
                    "publisher {s}: waiting for a registry to assign a port from {d}-{d}\n",
                    .{ topic, publisher_port_low, publisher_port_high },
                );
            }
            if (!sleepMsInterruptible(registry_probe_interval_ms)) return error.ShuttingDown;
            continue;
        };

        if (port == 0) {
            // The registry has no range, though we do. It is holding the role without the
            // configuration, which the mirror covers when the role MOVES to it -- but not
            // when such a node wins the election in the first place, having had nothing to
            // mirror from.
            std.debug.print(
                "publisher {s}: this node wants ports {d}-{d} but the registry assigns none. " ++
                    "Set QNNT_PUBLISHER_PORTS on every node on this host, including tools.\n",
                .{ topic, publisher_port_low, publisher_port_high },
            );
            return error.NoPortAssigned;
        }

        const addr: net.IpAddress = try .parse(bindText(), port);
        return addr.listen(io, .{ .reuse_address = false }) catch |err| {
            // The registry names a port; it does not hold the socket. Anything on the host
            // can take it in between, so say which one failed and ask for another.
            lost_races += 1;
            if (lost_races >= publisher_port_attempts) {
                std.debug.print(
                    "publisher {s}: could not bind any port in {d}-{d} after {d} attempts " ++
                        "({t}) -- something outside qnnt is using the range\n",
                    .{ topic, publisher_port_low, publisher_port_high, lost_races, err },
                );
                return err;
            }
            avoid = port;
            continue;
        };
    }
    return error.ShuttingDown;
}

/// Ask the registry for this topic's port. Null when no registry answered, which is
/// different from an answer of 0.
fn requestPublisherPort(topic: []const u8, avoid: u16) ?u16 {
    var cmd_buf: [256]u8 = undefined;
    const command = if (avoid == 0)
        std.fmt.bufPrint(&cmd_buf, "port {s}", .{topic}) catch return null
    else
        std.fmt.bufPrint(&cmd_buf, "port {s} skip {d}", .{ topic, avoid }) catch return null;

    var reply_buf: [512]u8 = undefined;
    const reply = registryCommand(command, &reply_buf) catch return null;

    var lines = std.mem.splitScalar(u8, reply, '\n');
    while (lines.next()) |line| {
        const text = std.mem.trim(u8, line, " \t\r");
        if (text.len == 0 or std.mem.startsWith(u8, text, comment_prefix)) continue;
        // An error reply is not a port. Reported by the caller, which knows the topic.
        return std.fmt.parseInt(u16, text, 10) catch null;
    }
    return null;
}

/// The port `topic` should listen on: its own if the directory already holds one, otherwise
/// the next free port in the range. 0 when no range is configured, which means "port 0".
///
/// `avoid` is a port the asker has just failed to bind, so it is never handed back.
fn assignPublisherPort(topic: []const u8, avoid: u16) PortAssignError!u16 {
    if (!publisherPortsConfigured()) return 0;

    directory_mutex.lockUncancelable(io);
    defer directory_mutex.unlock(io);

    const low = publisher_port_low;
    const high = publisher_port_high;

    // Sticky: this topic's own port, if it still holds one in range. Checked before the
    // scan so a restarting publisher always reclaims what a stale entry still advertises.
    if (directory.get(topic)) |entry| {
        const held = entry.endpoint.getPort();
        if (entry.local and held >= low and held <= high and held != avoid) return held;
    }

    // Only entries registered HERE hold a port on this machine. A peer's entry may well
    // carry a port inside our range -- if that host has the same range configured -- and
    // treating it as taken would exhaust the range with ports that are not ours.
    const span: usize = @as(usize, high - low) + 1;
    var i: usize = 0;
    while (i < span) : (i += 1) {
        const offset = (@as(usize, publisher_port_cursor - low) + i) % span;
        const port: u16 = low + @as(u16, @intCast(offset));
        if (port == avoid) continue;

        var taken = false;
        var it = directory.iterator();
        while (it.next()) |kv| {
            const entry = kv.value_ptr;
            if (!entry.local) continue;
            if (entry.endpoint.getPort() != port) continue;
            // Its own reservation is not a reason to refuse it.
            if (std.mem.eql(u8, kv.key_ptr.*, topic)) continue;
            taken = true;
            break;
        }
        if (taken) continue;

        publisher_port_cursor = if (port == high) low else port + 1;
        return port;
    }
    return PortAssignError.RangeFull;
}

/// The address remote subscribers are told to dial, with `port` filled in. Set it before
/// `run()` to make this node reachable off-host.
pub fn setAdvertiseAddressFn(text: []const u8) bool {
    if (node_running) return false;
    // Resolved now, and stored as the numeric result rather than as written. Two reasons:
    // a bad address fails at configuration time instead of at first publish, and what goes
    // out as a publisher endpoint must be something every subscriber can parse as a
    // literal -- a hostname only this host can resolve would be useless to them.
    const addr = resolve.resolve(text, 0) catch return false;
    var numeric_buf: [resolve.max_host_text]u8 = undefined;
    const numeric = resolve.hostText(addr, &numeric_buf);
    if (numeric.len == 0 or numeric.len > advertise_buf.len) return false;
    @memcpy(advertise_buf[0..numeric.len], numeric);
    advertise_len = numeric.len;
    return true;
}

/// The address publisher sockets bind. Defaults to following the advertise address.
pub fn setBindAddressFn(text: []const u8) bool {
    if (node_running) return false;
    // Resolved and stored numerically, as above. A bind address is also deliberately
    // resolved only once: it decides which local interface sockets attach to, and having
    // that drift underneath a running node because a name started answering differently
    // would be a surprise, not a feature.
    const addr = resolve.resolve(text, 0) catch return false;
    var numeric_buf: [resolve.max_host_text]u8 = undefined;
    const numeric = resolve.hostText(addr, &numeric_buf);
    if (numeric.len == 0 or numeric.len > bind_buf.len) return false;
    @memcpy(bind_buf[0..numeric.len], numeric);
    bind_len = numeric.len;
    return true;
}

pub fn advertiseAddressFn() []const u8 {
    return advertiseText();
}

pub const default_registry_port = 2222;

// Latched once per `nodeRun` and fixed for that node's lifetime: the registry thread, the
// publishers' registration loops and every subscriber's resolver all hold it, so moving it
// under them would be incoherent.
//
// No environment lookup here. Zig 0.16 gives a library no ambient access to the
// environment — `Environ` has to be handed down from `main` — and that is the right shape
// anyway: the library takes a port, and the caller decides whether it came from a flag, an
// env var or a constant.
var registry_port: u16 = default_registry_port;
pub var node_running = false;

/// Set the port the next `run()` will use. Returns false while a node is running, since
/// the value is already in use by its workers; stop the node first.
///
/// Distinct ports give fully independent registries in one machine, which is what makes it
/// possible to run tests and examples side by side instead of having them fight over one
/// well-known port.
/// Whether this node will ever hold the registry.
///
/// `client` is for a node that must not be elected -- a sensor board, a container with a
/// tight memory budget, anything where holding the directory for the whole host is not a
/// job it should be given. It still publishes and subscribes normally; it simply never
/// contends for the port, and never mirrors, because a warm copy exists only to make a
/// takeover fast and a client will never take over.
pub const RegistryRole = enum { candidate, client };

var registry_role: RegistryRole = .candidate;

/// Whether a candidate keeps a warm copy of the directory. Separable from the role because
/// the two costs are different: being a candidate is free until the holder dies, while
/// mirroring is a round trip every probe interval and a copy of the directory in memory.
/// Turning it off leaves a node able to take over, but cold -- which is what it was before
/// mirroring existed.
var registry_mirror: bool = true;

pub fn setRegistryRoleFn(role: RegistryRole) bool {
    if (node_running) return false;
    registry_role = role;
    return true;
}

pub fn setRegistryMirrorFn(on: bool) bool {
    if (node_running) return false;
    registry_mirror = on;
    return true;
}

pub fn registryRoleFn() RegistryRole {
    return registry_role;
}

pub fn setRegistryPortFn(port: u16) bool {
    if (node_running) return false;
    registry_port = port;
    return true;
}

/// The port in effect — the one a running node is using, or the one the next `run()` will.
pub fn currentRegistryPort() u16 {
    return registry_port;
}

// How often publishers refresh their registration and subscribers re-poll for a topic
// URI. Also the unit `stale_after_us` is expressed in, so changing it changes when an
// entry is considered stale.
pub const registry_probe_interval_ms = 2000;

// How often a standby re-contends for the registry port. Deliberately NOT
// `registry_probe_interval_ms`, though it was until measurement separated them.
//
// The two answer different questions and cost different amounts. A refresh is a round trip
// to the registry, so doing it eight times a second across every publisher on a host would
// be real traffic. Re-contending is a socket, a bind that fails with EADDRINUSE, and a
// close -- three syscalls against a port nobody is listening on, costing nothing on the
// wire.
//
// They were one constant, and that made the standby wait up to two seconds to notice a
// dead holder. Recovery from the holder's death has two phases: taking the role, then the
// directory refilling as publishers re-register. Measured over eight runs
// (examples/registry/failover.py), taking the role was 2.0-4.0s and the refill only
// 0-2.2s -- so the larger half of the outage was a standby sleeping, which is the half
// that costs nothing to fix.
pub const registry_bind_retry_ms = 250;

// Open the registry listener with SO_REUSEADDR but NOT SO_REUSEPORT; see the note on
// `registry_port` for why std's one-flag-for-both is unusable here. Everything after
// this is ordinary `net.Server`: accept, shutdown and deinit only use the handle.
fn listenRegistry(addr: net.IpAddress) !net.Server {
    return listenExclusiveOn(addr);
}

// SO_REUSEADDR but NOT SO_REUSEPORT: binding over a lingering TIME_WAIT must work, while
// two live listeners on one address must still collide, since that collision IS the
// election. std's `reuse_address` sets both, so the socket is opened by hand.
pub fn listenExclusiveOn(addr: net.IpAddress) !net.Server {
    const posix = std.posix;

    const family = Io.Threaded.posixAddressFamily(&addr);
    // Only Linux accepts SOCK_CLOEXEC inside socket(); the constant exists on macOS but
    // the call rejects it with EPROTONOSUPPORT, so `@hasDecl` is the wrong test. Where it
    // is unavailable the listener is inheritable across exec — worth knowing before this
    // library is used from a process that forks and execs.
    const cloexec: u32 = if (@import("builtin").os.tag == .linux) posix.SOCK.CLOEXEC else 0;
    const flags: u32 = posix.SOCK.STREAM | cloexec;

    const fd_rc = posix.system.socket(family, flags, 0);
    if (posix.errno(fd_rc) != .SUCCESS) return error.SocketOpenFailed;
    const fd: posix.socket_t = @intCast(fd_rc);
    errdefer _ = posix.system.close(fd);

    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

    var storage: Io.Threaded.PosixAddress = undefined;
    const addr_len = Io.Threaded.addressToPosix(&addr, &storage);

    switch (posix.errno(posix.system.bind(fd, &storage.any, addr_len))) {
        .SUCCESS => {},
        .ADDRINUSE => return error.AddressInUse, // another node holds the role
        else => return error.BindFailed,
    }
    switch (posix.errno(posix.system.listen(fd, registry_backlog))) {
        .SUCCESS => {},
        .ADDRINUSE => return error.AddressInUse,
        else => return error.ListenFailed,
    }

    return .{
        .socket = .{ .handle = fd, .address = addr },
        .options = if (net.Server.AcceptOptions != void) .{ .mode = .stream, .protocol = .tcp },
    };
}

const registry_backlog = 128;

// The standby's copy of the directory is pulled into this. File scope rather than a local
// because it is large and only the registry thread ever touches it -- a 64 KiB frame on a
// worker's stack is not worth the risk for a buffer with exactly one user.
//
// It bounds how big a directory a standby can mirror: `registryCommand` stops copying when
// the next line would not fit, so beyond roughly 600 entries a standby's copy is a prefix
// rather than the whole thing. That degrades the warm copy, it does not corrupt it -- the
// missing topics simply re-register within a probe interval, which is the behaviour a
// standby had for everything before it mirrored anything.
var mirror_buf: [64 * 1024]u8 = undefined;

/// What a standby remembers between pulls, so it can ask "anything new?" instead of
/// "send me everything".
const MirrorState = struct {
    holder: [32]u8 = @splat(0),
    holder_len: usize = 0,
    epoch: u64 = 0,
    /// When the whole directory was last taken. See `pullMirror` for why this matters even
    /// when nothing has changed.
    last_full_us: i64 = 0,

    fn holderText(m: *const MirrorState) []const u8 {
        return m.holder[0..m.holder_len];
    }
};

/// Pull the directory from whoever currently holds the registry and merge it.
///
/// This is what makes a takeover warm. Without it a new holder starts empty and every
/// topic is unresolvable until its publisher's next refresh -- measured at about two
/// seconds, and the dominant term in the outage once the bind retry was shortened.
///
/// Pulled rather than pushed, deliberately. A standby already wakes to re-contend for the
/// port, so it can fetch in the same cycle: no registration with the holder, no fan-out, no
/// tracking of which standbys are alive, and no failure mode where a slow standby stalls
/// the holder's publish path. A missed pull corrects itself on the next one. The cost is
/// that the copy is up to one pull interval stale, which is hidden by the fact that a
/// standby's copy only ever matters at the moment it takes the role.
fn pullMirror(state: *MirrorState) void {
    const now_us = nowMicrosFn();

    // A full pull every so often even when nothing has changed, because merging is what
    // refreshes a mirrored entry's lease. `entryIsServable` stops serving an entry this
    // node has not heard about for `fed_serve_until_us`, so a standby that only ever heard
    // "unchanged" would watch its warm copy quietly go cold and then, on takeover, refuse
    // to serve topics that were alive the whole time. Half the lease is the interval.
    const lease_refresh_us: i64 = @intCast(federation.serve_until_us / 2);
    const force_full = state.holder_len == 0 or
        (now_us -| state.last_full_us) >= lease_refresh_us;

    var cmd_buf: [96]u8 = undefined;
    const command = if (force_full)
        "mirror"
    else
        std.fmt.bufPrint(&cmd_buf, "mirror {s} {d}", .{ state.holderText(), state.epoch }) catch
            "mirror";

    const text = registryCommand(command, &mirror_buf) catch return;

    // "You are current": nothing to merge, and nothing to pay for it beyond the round trip.
    if (std.mem.indexOf(u8, text, "mirror-unchanged") != null) return;

    // Otherwise the reply opens with the holder's identity and epoch, and the rest is the
    // directory. Record them so the next poll can be the cheap one.
    if (std.mem.indexOf(u8, text, "mirror-state ")) |at| {
        var it = std.mem.tokenizeAny(u8, text[at..], " \t\r\n");
        _ = it.next(); // mirror-state
        if (it.next()) |id_text| {
            if (id_text.len <= state.holder.len) {
                @memcpy(state.holder[0..id_text.len], id_text);
                state.holder_len = id_text.len;
            }
        }
        if (it.next()) |epoch_text| {
            state.epoch = std.fmt.parseInt(u64, epoch_text, 10) catch state.epoch;
        }
    }
    state.last_full_us = now_us;

    // Loopback is the address a local publisher that named none is reachable at, which is
    // exactly what an empty host field in a `fed-entry` line asks the receiver to decide.
    _ = federation.applyMirrorEntries(text, "127.0.0.1");
}

fn registryRun() void {
    // Whether the "standing by" notice has been printed for the current contention.
    // Printing every probe would be noise; printing nothing at all is worse — a node
    // silently failing to bind is indistinguishable from one that simply is not the
    // registry, which hid an AddressInUse loop for a long time.
    // A node that will never be elected has nothing to do here. It still publishes and
    // subscribes; it simply never contends, and never mirrors, because a warm copy is only
    // ever read at a takeover this node has opted out of.
    if (registry_role == .client) {
        std.debug.print(
            "registry role declined: this node is a client, it will not be elected\n",
            .{},
        );
        return;
    }

    var announced_standby = false;
    // Last time this node pulled the holder's directory. Zero so the first standby cycle
    // mirrors immediately rather than waiting out an interval.
    var last_mirror_us: i64 = 0;
    var mirror_state: MirrorState = .{};

    while (!isShuttingDown()) {
        const addr: net.IpAddress = net.IpAddress.parse("127.0.0.1", registry_port) catch |err| {
            std.debug.print("registry address parse failed: {}\n", .{err});
            return;
        };

        var server = listenRegistry(addr) catch |err| {
            // Another node already holds the registry role; stand by and re-probe.
            if (!announced_standby) {
                std.debug.print("registry standing by (port {d}: {})\n", .{ registry_port, err });
                announced_standby = true;
            }

            // Keep a warm copy, but not on every bind retry: re-contending is three
            // syscalls against a port nobody answers, while this is a round trip to the
            // holder. Binding stays fast so a dead holder is noticed quickly; mirroring
            // runs at the slower refresh cadence, which is all the freshness a copy needs
            // when it is only read at the moment of takeover.
            const now_us = nowMicrosFn();
            if (registry_mirror and
                now_us -| last_mirror_us >= registry_probe_interval_ms * 1000)
            {
                last_mirror_us = now_us;
                pullMirror(&mirror_state);
            }

            if (!sleepMsInterruptible(registry_bind_retry_ms)) return;
            continue;
        };
        defer server.deinit(io); // released before we re-contend for the role

        // Tracked so a shutdown can break the accept below. Untracked before the
        // deinit above, so the handle is never stale while it is listed.
        if (!trackSocket(server.socket, .listener)) return;
        defer untrackSocket(server.socket);

        announced_standby = false;
        registry_since_us.store(@intCast(nowMicrosFn()), .monotonic);
        std.debug.print("registry role acquired, listening on port {}\n", .{addr.getPort()});

        // Serve until the listener fails, then fall through to release the port
        // and re-enter contention.
        while (true) {
            const client = server.accept(io) catch |err| {
                // A shutdown breaking our own listener is not a failure worth
                // reporting; anything else means the role is being lost.
                if (isShuttingDown()) return;
                std.debug.print("registry accept failed ({}); releasing role\n", .{err});
                break;
            };

            if (isShuttingDown()) {
                client.close(io);
                return;
            }

            if (!spawnWorker(handleRegistryClient, .{client})) {
                client.close(io);
                // spawnWorker also refuses once a shutdown is under way, and by then the
                // listener has already been woken, so going back to accept would block
                // for good.
                if (isShuttingDown()) return;
                std.debug.print("error spawning registry client handler\n", .{});
            }
        }
    }
}

pub fn publishAll(topic: []const u8, data: []const u8) !void {
    // Checked here, at the producer, because the alternative is discovering it at every
    // consumer: a subscriber that meets an oversized frame breaks its read loop and
    // reconnects into the same frame forever, while this end sees nothing wrong at all.
    // Failing the publish puts the error where the size was decided.
    if (data.len > maxFrameBytes()) {
        std.debug.print(
            "publish to {s}: {d} bytes exceeds the {d} byte frame limit -- subscribers " ++
                "would refuse it and reconnect in a loop. Publish less per message, or " ++
                "raise QNNT_MAX_FRAME_BYTES on every node on the topic.\n",
            .{ topic, data.len, maxFrameBytes() },
        );
        return error.FrameTooLarge;
    }

    // Peers whose write failed, reported after the lock is released.
    var lost: [8][64]u8 = undefined;
    var lost_len: [8]usize = @splat(0);
    var lost_count: usize = 0;
    var remaining: usize = 0;

    {
        // Held across the socket writes: on localhost this is cheap, and it keeps
        // the subscriber list stable while the accept loop may be appending to it.
        // Scoped to this block rather than the function, so the events below are emitted
        // with no lock held -- a handler may call back into the library.
        subscribers_mutex.lockUncancelable(io);
        defer subscribers_mutex.unlock(io);

        if (subscribers.getPtr(topic)) |list_ptr| {
            // Iterate backward so a failed-write swapRemove only ever touches
            // indices we've already visited.
            var idx = list_ptr.items.len;
            while (idx > 0) {
                idx -= 1;
                var writer = list_ptr.items[idx].client.writer(io, &.{});
                writer.interface.writeAll(data) catch |err| {
                    // Named, and named as what it is. "error writing: error.WriteFailed"
                    // told the reader nothing and looked like a fault; a subscriber going
                    // away is the ordinary case, and the useful facts are which topic and
                    // which peer. The event below carries the same news programmatically.
                    std.debug.print("subscriber {f} left {s} ({s})\n", .{
                        list_ptr.items[idx].address,
                        topic,
                        @errorName(err),
                    });
                    if (lost_count < lost.len) {
                        const text = std.fmt.bufPrint(&lost[lost_count], "{f}", .{
                            list_ptr.items[idx].address,
                        }) catch "?";
                        lost_len[lost_count] = text.len;
                        lost_count += 1;
                    }
                    // Close before dropping it: swapRemove alone leaked the descriptor.
                    list_ptr.items[idx].client.close(io);
                    _ = list_ptr.swapRemove(idx);
                    continue;
                };
                list_ptr.items[idx].messages += 1;
            }
            remaining = list_ptr.items.len;
        } else {
            std.debug.print("topic {s} not found\n", .{topic});
        }
    }

    for (lost[0..lost_count], lost_len[0..lost_count]) |*buf, len| {
        emitEvent(.subscriber_disconnected, topic, buf[0..len], remaining);
    }
}

// Drive `source` at a fixed rate, publishing whatever it returns. Paced against an
// absolute deadline rather than "sleep(period) after the work", so the callback's own
// cost and wake-up jitter don't accumulate into drift. A period of 0 is unpaced.
fn publisherSchedule(token: *TopicToken, source: Qnnt.SourceHandler, period_us: u64, context: ?*anyopaque) void {
    const topic = token.topic;
    var next_us: u64 = @intCast(nowMicrosFn());

    while (!token.stopping()) {
        // Unpaced has no deadline to wait for, so it skips the clock read as well as
        // the sleep — the read is the only remaining per-tick overhead at that point.
        if (period_us != 0) {
            next_us += period_us;
            const now_us: u64 = @intCast(nowMicrosFn());

            if (next_us > now_us) {
                if (!sleepUsInterruptibleFor(token, next_us - now_us)) return;
            } else if (now_us - next_us >= period_us) {
                // More than a full period behind (slow callback, scheduling hiccup):
                // give up on the missed ticks and resynchronize, rather than firing a
                // burst to catch up on a backlog that only grows.
                next_us = now_us;
            }
        }

        if (source(topic, context)) |payload| {
            publishAll(topic, payload) catch |err| {
                std.debug.print("error publishing on {s}: {}\n", .{ topic, err });
            };
        }
    }
}

fn nodePublish(token: *TopicToken, source: ?Qnnt.SourceHandler, period_us: u64, context: ?*anyopaque) !void {
    // The token's copy, not the caller's slice: it outlives every worker started below,
    // which is what lets `removePublisher` free it only once they have all gone.
    const topic = token.topic;
    // Bind with an ephemeral port (0); the OS fills in the real port, which we read back
    // from the socket.
    // Port 0 unless this node was given a range, in which case the registry says which.
    // Asked only when a range is configured HERE, so a node without one behaves exactly as
    // it always has: no extra round trip, and no dependency on a registry existing before a
    // publisher can bind.
    var server = listenForPublisher(topic) catch |err| {
        // Already explained by listenForPublisher, which knows which of the several
        // reasons it was. A stack trace here would read as a fault in qnnt rather than as
        // the configuration problem it is.
        if (err != error.ShuttingDown) {
            std.debug.print("publisher {s}: not started\n", .{topic});
        }
        return;
    };
    defer server.deinit(io);

    // Tracked so shutdown -- or `removePublisher` on this topic alone -- can break the
    // accept loop below.
    if (!trackSocketFor(token, server.socket, .listener)) return;
    defer untrackSocketFor(token, server.socket);

    // What we listen on and what we advertise are separate: binding 0.0.0.0 is useful,
    // telling a subscriber to dial 0.0.0.0 is not. Take the port the OS chose and pair it
    // with the address remote subscribers can actually reach.
    var endpoint: net.IpAddress = try .parse(advertiseText(), 0);
    endpoint.setPort(server.socket.address.getPort());

    {
        subscribers_mutex.lockUncancelable(io);
        defer subscribers_mutex.unlock(io);
        try subscribers.put(topic, .empty);
    }

    std.debug.print("publisher {s} listening on tcp://{f}\n", .{ topic, endpoint });

    // Keep the registry's directory pointed at us. This runs regardless of which
    // node holds the registry (we register over the network, even to ourselves),
    // retries until a registry exists, and refreshes so a newly-elected registry
    // after a failover re-learns this publisher.
    if (!spawnWorkerFor(token, registerLoop, .{ token, endpoint })) {
        std.debug.print("failed to spawn register loop for {s}\n", .{topic});
    }

    // Self-paced publishing, if the caller supplied a source. Started only once the
    // listener is up and registered, so no tick can fire before subscribers have
    // somewhere to connect.
    if (source) |src| {
        if (!spawnWorkerFor(token, publisherSchedule, .{ token, src, period_us, context })) {
            std.debug.print("failed to spawn scheduler for {s}\n", .{topic});
        }
    }

    while (!token.stopping()) {
        const client = server.accept(io) catch |err| {
            if (token.stopping()) return; // our own shutdown, or this topic's, broke the accept
            return err;
        };

        // NOTE: the waker connection that `breakTopicSockets` used to interrupt this accept
        // is deliberately NOT closed here, even though we are stopping and it is not a real
        // subscriber. Closing it on this thread races with the waker's own close, and on
        // loopback the two FINs cross: a simultaneous close leaves the SERVER end in
        // TIME_WAIT on the publisher's port, which then cannot be bound for ~30s. That is
        // invisible with ephemeral ports and fatal with QNNT_PUBLISHER_PORTS, where the next
        // publisher is handed that exact port and its bind fails.
        //
        // So it goes onto the subscriber list like any other connection and is closed with
        // the rest of them -- by `removePublisher` after the join, or by `nodeDeinit` --
        // late enough that the waker's FIN has certainly arrived and the close is an
        // ordinary passive one.

        var now_count: usize = 0;
        {
            subscribers_mutex.lockUncancelable(io);
            defer subscribers_mutex.unlock(io);
            if (subscribers.getPtr(topic)) |list_ptr| {
                try list_ptr.append(allocator, .{
                    .client = client,
                    .address = client.socket.address, // peer address, resolved by accept
                    .since_us = @intCast(nowMicrosFn()),
                    .messages = 0,
                });
                now_count = list_ptr.items.len;
            }
        }

        // Emitted after the lock is released: a handler is free to call back into the
        // library, and `subscriberCount` would deadlock against this very mutex.
        var peer_buf: [64]u8 = undefined;
        const peer = std.fmt.bufPrint(&peer_buf, "{f}", .{client.socket.address}) catch "?";
        emitEvent(.subscriber_connected, topic, peer, now_count);
    }
}

// Copy out this topic's subscriber list for reporting. Taken under the lock and
// released before any network write, so a slow registry can't stall publishing.
// Caller frees.
fn snapshotPeers(topic: []const u8, now_us: u64) ![]PeerRecord {
    subscribers_mutex.lockUncancelable(io);
    defer subscribers_mutex.unlock(io);

    const list_ptr = subscribers.getPtr(topic);
    const count = if (list_ptr) |l| l.items.len else 0;

    const out = try allocator.alloc(PeerRecord, count);
    if (list_ptr) |l| {
        for (l.items, out) |node, *record| {
            record.* = .{
                .address = node.address,
                .connected_us = now_us -| node.since_us,
                .messages = node.messages,
            };
        }
    }
    return out;
}

// Register this publisher with whichever node holds the registry, then hand over the
// current subscriber list. The registry cannot see those connections — they terminate
// here — so piggybacking the snapshot on the refresh is how `list` and `subs` get
// their figures, at the cost of them lagging by up to one probe interval.
fn registerOnce(topic: []const u8, endpoint: net.IpAddress) !void {
    const reg: net.IpAddress = try net.IpAddress.parse("127.0.0.1", registry_port);
    var conn = try reg.connect(io, .{ .mode = .stream });
    defer conn.close(io);

    // Short-lived, but it blocks on a read: tracked so a shutdown mid-exchange does
    // not hold the worker until the peer answers.
    if (!trackSocket(conn.socket, .stream)) return error.ShuttingDown;
    defer untrackSocket(conn.socket);

    var writer = conn.writer(io, &.{});
    var rbuf: [256]u8 = undefined;
    var reader = conn.reader(io, &rbuf);

    var cmdbuf: [512]u8 = undefined;

    const cmd = try std.fmt.bufPrint(&cmdbuf, "pub {s} tcp://{f}\n", .{ topic, endpoint });
    try writer.interface.writeAll(cmd);
    discardReply(&reader.interface); // ack; drained so the close stays orderly

    const now_us: u64 = @intCast(nowMicrosFn());
    const peers = try snapshotPeers(topic, now_us);
    defer allocator.free(peers);

    // Framed, so a report interrupted midway (registry failover, dropped connection)
    // leaves the previous snapshot in place instead of a truncated one.
    const begin = try std.fmt.bufPrint(&cmdbuf, "report {s} begin\n", .{topic});
    try writer.interface.writeAll(begin);
    discardReply(&reader.interface);

    // Each line is acknowledged before the next is sent: it keeps this in lockstep
    // with the registry rather than pushing an unbounded batch at it.
    for (peers) |peer| {
        const line = try std.fmt.bufPrint(&cmdbuf, "report {s} peer tcp://{f} {d} {d}\n", .{
            topic,
            peer.address,
            peer.connected_us,
            peer.messages,
        });
        try writer.interface.writeAll(line);
        discardReply(&reader.interface);
    }

    const end = try std.fmt.bufPrint(&cmdbuf, "report {s} end\n", .{topic});
    try writer.interface.writeAll(end);
    discardReply(&reader.interface);
}

fn registerLoop(token: *TopicToken, endpoint: net.IpAddress) void {
    while (!token.stopping()) {
        registerOnce(token.topic, endpoint) catch {}; // registry not up yet / mid-failover
        if (!sleepMsInterruptibleFor(token, registry_probe_interval_ms)) return;
    }
}

/// Send one command to the registry and return its reply, copied into `buf`.
///
/// The general primitive, so a tool that wants `subs` or `status` can pass the registry's
/// own answer straight through instead of parsing a table only to reformat it. Informational
/// '#' lines are kept for that reason -- they are most of what those replies say.
pub fn registryCommand(command: []const u8, buf: []u8) ![]const u8 {
    const reg: net.IpAddress = try net.IpAddress.parse("127.0.0.1", registry_port);
    var conn = try reg.connect(io, .{ .mode = .stream });
    defer conn.close(io);

    // Short-lived, but it blocks on a read: tracked so a shutdown mid-exchange does not
    // hold the worker until the peer answers.
    if (!trackSocket(conn.socket, .stream)) return error.ShuttingDown;
    defer untrackSocket(conn.socket);

    var writer = conn.writer(io, &.{});
    try writer.interface.writeAll(command);
    try writer.interface.writeAll("\n");

    var rbuf: [1024]u8 = undefined;
    var reader = conn.reader(io, &rbuf);

    // Two terminators to expect, not one. The registry greets every connection with a
    // banner of its own, itself terminated, so the first `# end` closes the greeting and
    // the second closes the reply. `takeReply` cannot be used here because it skips every
    // '#' line -- including the terminators -- which is right for a one-line reply and
    // wrong for anything longer.
    const end = response_terminator[0 .. response_terminator.len - 1];
    var greeted = false;
    var used: usize = 0;

    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch break;
        if (std.mem.startsWith(u8, line, end)) {
            if (greeted) break;
            greeted = true;
            continue;
        }
        if (!greeted) continue; // still inside the greeting
        if (used + line.len > buf.len) break;

        // Copied straight away: the slice points into the reader's buffer, which the next
        // read reuses.
        @memcpy(buf[used..][0..line.len], line);
        used += line.len;
    }

    return buf[0..used];
}

/// Ask the registry which topics it currently knows. Names are copied into `buf` and `out`
/// is filled with slices into it; returns how many were written.
///
/// Here rather than in a tool because the table being parsed is written by `writeTopicList`
/// a few hundred lines up: keeping both halves in one file means a column added or reordered
/// is a local change rather than a silent break in something downstream. Only the first
/// column is read, which is the topic.
pub fn listTopics(out: [][]const u8, buf: []u8) !usize {
    // Heap rather than a stack buffer: a busy registry's table is a few KB and this runs on
    // whatever thread the caller is on, including library workers.
    const reply = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(reply);
    const text = try registryCommand("list", reply);

    var count: usize = 0;
    var used: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, comment_prefix)) continue;

        var it = std.mem.tokenizeAny(u8, line, " \t\r");
        const name = it.next() orelse continue;
        if (count == out.len or used + name.len > buf.len) break;

        @memcpy(buf[used..][0..name.len], name);
        out[count] = buf[used..][0..name.len];
        used += name.len;
        count += 1;
    }

    return count;
}

// Ask the registry (well-known port) where `topic` is published and return the
// publisher's endpoint. Fails if the registry is unreachable or doesn't know the
// topic yet, so callers are expected to retry.
fn resolveTopic(topic: []const u8) !net.IpAddress {
    const reg: net.IpAddress = try net.IpAddress.parse("127.0.0.1", registry_port);
    var conn = try reg.connect(io, .{ .mode = .stream });
    defer conn.close(io);

    // Short-lived, but it blocks on a read: tracked so a shutdown mid-exchange does
    // not hold the worker until the peer answers.
    if (!trackSocket(conn.socket, .stream)) return error.ShuttingDown;
    defer untrackSocket(conn.socket);

    var cmdbuf: [256]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmdbuf, "sub {s}\n", .{topic});
    var writer = conn.writer(io, &.{});
    try writer.interface.writeAll(cmd);

    var rbuf: [256]u8 = undefined;
    var reader = conn.reader(io, &rbuf);
    const line = try takeReply(&reader.interface);
    const parsed = parseTcpUri(line); // errors (incl. "error: not found") -> caller retries
    drainReply(&reader.interface);
    return parsed;
}

// Resolve `topic` through the registry, connect to its publisher, and deliver every
// message received to `handler`. Retries resolution/connection so it tolerates the
// registry or publisher not being ready yet (e.g. the publishing node started
// later), and reconnects if the publisher goes away.
fn subscribeLoop(token: *TopicToken, handler: Qnnt.MessageHandler, context: ?*anyopaque) void {
    const topic = token.topic;
    while (!token.stopping()) {
        const endpoint = resolveTopic(topic) catch {
            if (!sleepMsInterruptibleFor(token, registry_probe_interval_ms)) return;
            continue;
        };

        var stream = endpoint.connect(io, .{ .mode = .stream }) catch {
            if (!sleepMsInterruptibleFor(token, registry_probe_interval_ms)) return;
            continue;
        };
        defer stream.close(io);

        // Tracked so shutdown -- or `removeSubscriber` on this topic -- breaks the
        // blocking read below.
        if (!trackSocketFor(token, stream.socket, .stream)) return;
        defer untrackSocketFor(token, stream.socket);

        std.debug.print("subscribed to {s} @ tcp://{f}\n", .{ topic, endpoint });

        var peer_buf: [64]u8 = undefined;
        const peer = std.fmt.bufPrint(&peer_buf, "{f}", .{endpoint}) catch "?";
        subMark(topic, true);
        emitEvent(.publisher_connected, topic, peer, 0);

        var rbuf: [1024]u8 = undefined;
        var reader = stream.reader(io, &rbuf);
        while (true) {
            const msg = reader.interface.takeDelimiterInclusive('\n') catch break;
            subTouch(topic);
            handler(topic, msg, context); // delivered on this thread; msg valid only for the call
        }

        subMark(topic, false);
        emitEvent(.publisher_disconnected, topic, peer, 0);

        // Publisher closed (or we are shutting down); re-resolve and reconnect.
        if (!sleepMsInterruptibleFor(token, registry_probe_interval_ms)) return;
    }
}

/// How many topics one pattern will join before it stops joining more. A bound rather than
/// unbounded growth: a pattern like `*` against a large federated directory would otherwise
/// open a connection per topic on the whole cluster, and discovering that as memory
/// pressure is worse than being told.
pub const max_pattern_topics = 256;

/// A reasonable gap between checks for topics that have appeared since, for a caller with
/// no opinion. Cheap to poll at, because the check is the `epoch` verb -- a couple of dozen
/// bytes -- and the directory is only listed when that has moved.
pub const default_pattern_rescan_ms = 500;

/// What a pattern subscription delivers. The two flavours differ only in the handler they
/// hand each joined topic to, so they share the discovery loop rather than duplicating it.
const PatternSink = union(enum) {
    messages: Qnnt.MessageHandler,
    frames: Qnnt.FrameHandler,
};

/// Ask the registry who holds the directory and what version it is at. False if it could
/// not be reached, which a caller should treat as "no news", not as "nothing there".
fn readDirectoryEpoch(holder: *[32]u8, holder_len: *usize, epoch: *u64) bool {
    var buf: [128]u8 = undefined;
    const text = registryCommand("epoch", &buf) catch return false;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const id = it.next() orelse return false;
    const version = it.next() orelse return false;
    if (id.len > holder.len) return false;
    @memcpy(holder[0..id.len], id);
    holder_len.* = id.len;
    epoch.* = std.fmt.parseInt(u64, version, 10) catch return false;
    return true;
}

/// Subscribe to every topic matching a glob, including ones that do not exist yet.
///
/// `subscribe` takes one name and waits for it. This takes a pattern -- `*` spans any run
/// of characters, `?` exactly one -- and joins each topic that matches, now and as they
/// appear. The handler is the ordinary one and already receives the topic name as its first
/// argument, so a pattern subscriber can tell the streams apart without any new API.
///
/// It is a SEPARATE call rather than `subscribe` noticing a `*`, and deliberately so. A
/// pattern costs a poll of the registry and one connection per matching publisher, and
/// neither should be something a caller gets by accident because a topic name happened to
/// contain a star. Everyone who does not ask for this pays nothing.
///
/// Three things worth knowing before reaching for it:
///
/// **Fan-out is per publisher, not per pattern.** Matching ten topics opens ten
/// connections. A symmetric arrangement where N nodes each subscribe to the others' topics
/// is N(N-1) connections -- 6 for three nodes, 2450 for fifty. This gives the ROUTING of a
/// bus, not its economics, and `max_pattern_topics` is the backstop.
///
/// **Discovery is polled, not pushed.** A topic that appears is joined within
/// `rescan_ms`; one that already exists is joined at once. Contrast `subscribe`, which
/// retries a named topic until it shows up. A `rescan_ms` of zero joins what exists now and
/// then stops looking, which is the right shape for a one-shot capture;
/// `default_pattern_rescan_ms` is a sensible value for a caller with no opinion.
///
/// **Matching means matching.** A node's own topics match its own pattern, and it will
/// subscribe to itself. That is left alone rather than special-cased: the handler is given
/// the topic name, so a caller that wants its own traffic excluded says so in one line,
/// while a caller that wants everything -- a logger, a recorder -- would have had to fight
/// a built-in exclusion.
///
/// `pattern` must outlive the subscription, exactly as `subscribe`'s topic must.
pub fn subscribePatternRun(
    pattern: []const u8,
    handler: Qnnt.MessageHandler,
    context: ?*anyopaque,
    rescan_ms: u64,
) bool {
    return startPattern(pattern, .{ .messages = handler }, context, rescan_ms);
}

/// `subscribePattern` for TLD frames: the same discovery, delivering to a `FrameHandler`
/// rather than to raw bytes. Everything said about the plain one applies here too.
pub fn subscribePatternFramesRun(
    pattern: []const u8,
    handler: Qnnt.FrameHandler,
    context: ?*anyopaque,
    rescan_ms: u64,
) bool {
    return startPattern(pattern, .{ .frames = handler }, context, rescan_ms);
}

fn startPattern(pattern: []const u8, sink: PatternSink, context: ?*anyopaque, rescan_ms: u64) bool {
    if (pattern.len == 0) return false;
    if (!spawnWorker(patternLoop, .{ pattern, sink, context, rescan_ms })) {
        std.debug.print("error spawning pattern subscriber for {s}\n", .{pattern});
        return false;
    }
    return true;
}

fn patternLoop(
    pattern: []const u8,
    sink: PatternSink,
    context: ?*anyopaque,
    rescan_ms: u64,
) void {
    // Joined names are duped because the listing buffer is reused on every rescan, so a
    // slice into it would be overwritten under whoever held it.
    var joined: std.ArrayList([]const u8) = .empty;
    // Both the list and the names, now that each subscription owns its own copy of the
    // topic in its token. They did not used to: a subscription borrowed this slice for its
    // whole life, and since this loop can return long before those do -- immediately, with
    // a zero rescan -- freeing here left every subscriber reading freed memory. With the
    // token owning the name that hazard is gone, and keeping these was simply a leak: one
    // name per joined topic, for the life of the node.
    defer {
        for (joined.items) |name| allocator.free(name);
        joined.deinit(allocator);
    }
    // Reserved up front, all of it, so appending can never fail mid-scan. It matters more
    // than the 4KiB costs: the list is the ONLY record of what we already joined, so a
    // failed append would re-subscribe the same topic on every rescan, for ever.
    joined.ensureTotalCapacity(allocator, max_pattern_topics) catch {
        std.debug.print("pattern {s}: out of memory, not subscribing\n", .{pattern});
        return;
    };

    var names: [max_pattern_topics][]const u8 = undefined;
    var name_buf: [64 * 1024]u8 = undefined;

    var known_holder: [32]u8 = undefined;
    var known_holder_len: usize = 0;
    var known_epoch: u64 = 0;
    var have_listed = false;
    var announced_full = false;

    while (!isShuttingDown()) {
        var holder: [32]u8 = undefined;
        var holder_len: usize = 0;
        var epoch: u64 = 0;

        // Only list when something actually changed. A new holder counts as changed: the
        // epoch is per-process, so after a failover an unchanged number means nothing.
        const readable = readDirectoryEpoch(&holder, &holder_len, &epoch);
        const moved = !have_listed or !readable or epoch != known_epoch or
            !std.mem.eql(u8, holder[0..holder_len], known_holder[0..known_holder_len]);

        if (moved) {
            const count = listTopics(&names, &name_buf) catch 0;
            for (names[0..count]) |name| {
                if (!topics.globMatch(pattern, name)) continue;
                if (alreadyJoined(joined.items, name)) continue;

                if (joined.items.len >= max_pattern_topics) {
                    if (!announced_full) {
                        std.debug.print(
                            "pattern {s}: at the {d}-topic limit, not joining more. " ++
                                "Narrow the pattern, or raise max_pattern_topics.\n",
                            .{ pattern, max_pattern_topics },
                        );
                        announced_full = true;
                    }
                    break;
                }

                const owned = allocator.dupe(u8, name) catch continue;
                const ok = switch (sink) {
                    .messages => |h| subscribeRun(owned, h, context),
                    .frames => |h| subscribeFramesRun(owned, h, context),
                };
                if (!ok) {
                    allocator.free(owned);
                    continue;
                }
                joined.appendAssumeCapacity(owned);
            }

            if (readable) {
                @memcpy(known_holder[0..holder_len], holder[0..holder_len]);
                known_holder_len = holder_len;
                known_epoch = epoch;
                have_listed = true;
            }
        }

        // Zero means look once and stop, for a caller that wants what exists now and no
        // background polling at all -- not "poll as fast as you can".
        if (rescan_ms == 0) return;
        if (!sleepMsInterruptible(rescan_ms)) return;
    }
}

fn alreadyJoined(items: []const []const u8, name: []const u8) bool {
    for (items) |held| {
        if (std.mem.eql(u8, held, name)) return true;
    }
    return false;
}

pub fn subscribeRun(topic: []const u8, handler: Qnnt.MessageHandler, context: ?*anyopaque) bool {
    const token = createTopicToken(topic, .subscriber) orelse {
        std.debug.print("error tracking subscriber {s}\n", .{topic});
        return false;
    };

    if (!spawnWorkerFor(token, subscribeLoop, .{ token, handler, context })) {
        std.debug.print("error spawning subscriber thread for {s}\n", .{topic});
        detachTopicTokenPtr(token);
        destroyTopicToken(token);
        return false;
    }
    return true;
}

/// The largest frame this node will accept, and the largest it will publish.
///
/// A declared TLD length is 8 attacker-controlled bytes, so a receiver has to cap what one
/// frame may ask it to buffer. The cap stays; what changed is that it applies to BOTH ends.
/// A 1 MiB limit on the subscriber with no limit at all on the publisher meant a producer
/// could emit frames that every subscriber refused -- and refusing is not graceful here: the
/// read loop breaks and reconnects, straight back into the same oversized frame. One
/// oversized publisher produced an endless reconnect storm and looked, from the producer's
/// side, like everything was fine.
///
/// 16 MiB rather than 1: a 1080p depth-plus-mono frame is 6.2 MB and a 2K one is 8.2 MB, so
/// a megabyte ruled out every sensor resolution above about 786x444 regardless of frame
/// rate. Deployments that want a tighter bound can set QNNT_MAX_FRAME_BYTES.
pub const default_max_frame_bytes = 16 << 20;

var max_frame_bytes_value = std.atomic.Value(usize).init(default_max_frame_bytes);

pub fn maxFrameBytes() usize {
    return max_frame_bytes_value.load(.monotonic);
}

/// Set the cap. Both ends of this node honour it; the two ends of a LINK are two nodes, so
/// a publisher raising its own does not raise its subscribers'.
pub fn setMaxFrameBytesFn(bytes: usize) bool {
    if (bytes < 1024) return false; // below any useful frame; almost certainly a typo
    max_frame_bytes_value.store(bytes, .monotonic);
    return true;
}

// As `subscribeLoop`, but the stream carries TLD frames instead of newline-delimited
// text. TLD frames are self-delimiting, so this needs no delimiter and imposes no
// restriction on payload bytes.
//
// A topic is one or the other, not both: the framing is a property of the stream, so a
// producer publishing TLD must be read with `subscribeFrames`, and a producer
// publishing text lines with `subscribe`.
fn subscribeFramesLoop(token: *TopicToken, handler: Qnnt.FrameHandler, context: ?*anyopaque) void {
    const topic = token.topic;

    // One buffer per subscription, reused for every frame, holding at most a frame.
    var frame_buf: std.ArrayList(u8) = .empty;
    defer frame_buf.deinit(allocator);

    while (!token.stopping()) {
        const endpoint = resolveTopic(topic) catch {
            if (!sleepMsInterruptibleFor(token, registry_probe_interval_ms)) return;
            continue;
        };

        var stream = endpoint.connect(io, .{ .mode = .stream }) catch {
            if (!sleepMsInterruptibleFor(token, registry_probe_interval_ms)) return;
            continue;
        };
        defer stream.close(io);

        // Tracked so shutdown -- or `removeSubscriber` on this topic -- breaks the
        // blocking frame read below.
        if (!trackSocketFor(token, stream.socket, .stream)) return;
        defer untrackSocketFor(token, stream.socket);

        std.debug.print("subscribed to {s} @ tcp://{f} (tld)\n", .{ topic, endpoint });

        var peer_buf: [64]u8 = undefined;
        const peer = std.fmt.bufPrint(&peer_buf, "{f}", .{endpoint}) catch "?";
        subMark(topic, true);
        emitEvent(.publisher_connected, topic, peer, 0);

        var rbuf: [4096]u8 = undefined;
        var reader = stream.reader(io, &rbuf);
        while (true) {
            const frame = Tld.readFrame(&reader.interface, allocator, &frame_buf, maxFrameBytes()) catch |err| {
                // EndOfStream is the publisher going away, which is routine. Anything
                // else means the stream is not what we think it is, and silence there
                // would leave a mismatched producer looking like a dead one.
                if (err != error.EndOfStream) {
                    std.debug.print("tld read error on {s}: {}\n", .{ topic, err });
                }
                break;
            };
            subTouch(topic);
            handler(topic, frame, context);
        }

        subMark(topic, false);
        emitEvent(.publisher_disconnected, topic, peer, 0);

        if (!sleepMsInterruptibleFor(token, registry_probe_interval_ms)) return;
    }
}

// ---------------------------------------------------------------- buffered subscription
//
// A second delivery mode: instead of invoking a callback on the subscriber's thread,
// copy each message into a queue the application drains on its own thread.
//
// This exists for callers on the other side of a language boundary. Crossing one per
// message costs far more than the copy — a ctypes callback is microseconds against a
// ~30 ns decode — so draining a thousand at a time amortises it away. It also sidesteps
// calling into a host runtime from a thread that runtime has never heard of, which under
// CPython means acquiring the GIL from a foreign thread and having nowhere to put an
// exception. With a queue, no library thread ever calls out.
//
// One queue serves every buffered subscription, so an application has a single drain
// point; each message carries the topic it arrived on. Drain from one thread only.
//
// Message buffers are recycled rather than reallocated: `poll` swaps a ring slot's buffer
// with a staging slot's, so steady-state delivery allocates nothing.

pub const QueuedMessage = struct {
    /// The topic string handed to `subscribeQueue` — the caller's, not a copy.
    topic: []const u8,
    /// Owned by the queue and valid until the next `poll` call, which recycles it.
    data: []const u8,
    received_us: u64,
};

const QueueSlot = struct {
    topic: []const u8 = &.{},
    buf: std.ArrayList(u8) = .empty,
    received_us: u64 = 0,
};

const queue_default_capacity = 1024;

var queue_ring: []QueueSlot = &.{};
var queue_head: usize = 0;
var queue_count: usize = 0;
var queue_dropped: u64 = 0;
var queue_mutex: Io.Mutex = .init;
var queue_staging: std.ArrayList(QueueSlot) = .empty;

// Bumped on every push and used as the futex word, so a waiting drainer wakes on arrival
// rather than polling a flag.
var queue_seq: std.atomic.Value(u32) = .init(0);

fn queueEnsureCapacity(capacity: usize) !void {
    if (queue_ring.len >= capacity) return;

    const grown = try allocator.alloc(QueueSlot, capacity);
    // Carry the existing entries over in order, so reserving more room mid-run does not
    // reorder or drop what is already queued.
    for (grown, 0..) |*slot, i| {
        slot.* = if (i < queue_count) queue_ring[(queue_head + i) % queue_ring.len] else .{};
    }
    if (queue_ring.len > 0) allocator.free(queue_ring);
    queue_ring = grown;
    queue_head = 0;
}

/// Reserve queue room before subscribing. Optional: the first `subscribeQueue` reserves
/// `queue_default_capacity` if nothing else has.
pub fn queueReserve(capacity: usize) bool {
    queue_mutex.lockUncancelable(io);
    defer queue_mutex.unlock(io);

    queueEnsureCapacity(capacity) catch return false;
    return true;
}

/// How many messages have been dropped because the queue was full. A drainer that keeps
/// up never sees this move; one that does not needs to know rather than guess.
pub fn queueDroppedCount() u64 {
    queue_mutex.lockUncancelable(io);
    defer queue_mutex.unlock(io);
    return queue_dropped;
}

// The handler behind every buffered subscription. `context` is the topic slice, boxed by
// subscribeQueue, so one handler serves them all.
fn queuePush(topic: []const u8, msg: []const u8, _: ?*anyopaque) void {
    queue_mutex.lockUncancelable(io);
    defer queue_mutex.unlock(io);

    if (queue_ring.len == 0) return; // never reserved; nothing to push into

    if (queue_count == queue_ring.len) {
        // Full. Drop the newest rather than the oldest: that keeps what has already been
        // accepted contiguous, so a consumer tracking sequence numbers sees a clean gap
        // at the end instead of a hole in the middle.
        queue_dropped += 1;
        return;
    }

    const slot = &queue_ring[(queue_head + queue_count) % queue_ring.len];
    slot.buf.clearRetainingCapacity();
    slot.buf.appendSlice(allocator, msg) catch {
        queue_dropped += 1;
        return;
    };
    slot.topic = topic;
    slot.received_us = @intCast(nowMicrosFn());
    queue_count += 1;

    _ = queue_seq.fetchAdd(1, .monotonic);
    io.futexWake(u32, &queue_seq.raw, 1);
}

/// Which reader a queued subscription uses. Framing is a property of the stream, not of
/// the delivery mode, so the queue has to be told: a TLD producer read as text would be
/// chopped at every 0x0A byte inside a payload, which is not a hypothetical — it is what
/// happens the first time a buffer holds a newline.
pub const QueueMode = enum { text, frames };

/// Subscribe to `topic`, delivering into the shared queue instead of a callback. For
/// `.frames` the queued bytes are the complete TLD frame, ready to hand to `Tld.decode`.
pub fn subscribeQueueRun(topic: []const u8, mode: QueueMode) bool {
    if (!queueReserveDefault()) return false;
    return switch (mode) {
        .text => subscribeRun(topic, queuePush, null),
        .frames => subscribeFramesRun(topic, queuePushFrame, null),
    };
}

/// `subscribeQueue` over a glob. The queued message already carries its topic, so a
/// consumer draining one queue can tell the streams apart with no extra bookkeeping --
/// which is what makes this the natural shape for the managed-runtime bindings.
pub fn subscribePatternQueueRun(pattern: []const u8, mode: QueueMode, rescan_ms: u64) bool {
    if (!queueReserveDefault()) return false;
    return switch (mode) {
        .text => subscribePatternRun(pattern, queuePush, null, rescan_ms),
        .frames => subscribePatternFramesRun(pattern, queuePushFrame, null, rescan_ms),
    };
}

fn queuePushFrame(topic: []const u8, frame: Tld.Frame, context: ?*anyopaque) void {
    // Queue the whole frame, prefix included, so a consumer can decode it as it stands.
    queuePush(topic, frame.raw, context);
}

// Apply the default capacity only if nothing has been reserved. Reserving
// unconditionally would quietly override a deliberate `reserveQueue(2)` with 1024, since
// the ring only ever grows — the caller asked for a small queue precisely to feel
// backpressure early.
fn queueReserveDefault() bool {
    queue_mutex.lockUncancelable(io);
    defer queue_mutex.unlock(io);

    if (queue_ring.len > 0) return true;
    queueEnsureCapacity(queue_default_capacity) catch return false;
    return true;
}

/// Move up to `out.len` messages out of the queue. Returns the slice actually filled,
/// whose `data` stays valid until the next call. `timeout_ms` of 0 never blocks and -1
/// blocks until something arrives.
pub fn queuePoll(out: []QueuedMessage, timeout_ms: i32) []QueuedMessage {
    if (out.len == 0) return out[0..0];

    queue_mutex.lockUncancelable(io);
    defer queue_mutex.unlock(io);

    if (queue_count == 0 and timeout_ms != 0) {
        // Read the sequence before unlocking so a push landing in the gap is not missed:
        // futexWaitTimeout returns immediately when the word has already moved on.
        const observed = queue_seq.load(.monotonic);
        queue_mutex.unlock(io);
        const timeout: Io.Timeout = if (timeout_ms < 0)
            .none
        else
            .{ .duration = .{
                // .awake is the monotonic clock here, the same one sleepMs uses: a
                // timeout must not be dragged around by wall-clock adjustments.
                .raw = Io.Duration.fromMilliseconds(timeout_ms),
                .clock = .awake,
            } };
        io.futexWaitTimeout(u32, &queue_seq.raw, observed, timeout) catch {};
        queue_mutex.lockUncancelable(io);
    }

    const take = @min(out.len, queue_count);
    if (take == 0) return out[0..0];

    queue_staging.ensureTotalCapacity(allocator, take) catch return out[0..0];
    while (queue_staging.items.len < take) queue_staging.appendAssumeCapacity(.{});

    for (0..take) |i| {
        const src = &queue_ring[(queue_head + i) % queue_ring.len];
        const dst = &queue_staging.items[i];

        // Swap buffers rather than copying: the ring slot inherits the staging slot's
        // buffer and its capacity, so nothing is allocated once things are warm.
        std.mem.swap(std.ArrayList(u8), &src.buf, &dst.buf);
        dst.topic = src.topic;
        dst.received_us = src.received_us;

        out[i] = .{ .topic = dst.topic, .data = dst.buf.items, .received_us = dst.received_us };
    }

    queue_head = (queue_head + take) % queue_ring.len;
    queue_count -= take;
    return out[0..take];
}

fn queueDeinit() void {
    queue_mutex.lockUncancelable(io);
    defer queue_mutex.unlock(io);

    for (queue_ring) |*slot| slot.buf.deinit(allocator);
    if (queue_ring.len > 0) allocator.free(queue_ring);
    queue_ring = &.{};

    for (queue_staging.items) |*slot| slot.buf.deinit(allocator);
    queue_staging.clearAndFree(allocator);

    queue_head = 0;
    queue_count = 0;
    queue_dropped = 0;
}

pub fn subscribeFramesRun(topic: []const u8, handler: Qnnt.FrameHandler, context: ?*anyopaque) bool {
    const token = createTopicToken(topic, .subscriber) orelse {
        std.debug.print("error tracking tld subscriber {s}\n", .{topic});
        return false;
    };

    if (!spawnWorkerFor(token, subscribeFramesLoop, .{ token, handler, context })) {
        std.debug.print("error spawning tld subscriber thread for {s}\n", .{topic});
        detachTopicTokenPtr(token);
        destroyTopicToken(token);
        return false;
    }
    return true;
}

fn sleepMsFn(ms: u64) void {
    io.sleep(Io.Duration.fromMilliseconds(@intCast(ms)), .awake) catch {};
}

fn sleepUsFn(us: u64) void {
    io.sleep(Io.Duration.fromMicroseconds(@intCast(us)), .awake) catch {};
}

// Wall-clock time now, in microseconds since the Unix epoch.
pub fn nowMicrosFn() i64 {
    return Io.Timestamp.now(io, .real).toMicroseconds();
}

// Ask the node to stop, from Ctrl-C or SIGTERM. An atomic store is async-signal-safe,
// which is all this does — no prints, since std.debug.print takes a lock and is not.
//
// This used to call `std.c._exit(0)`, because Io.Threaded's signal machinery swallows
// SIGINT and a node would otherwise keep holding the registry port with no standby able
// to take over. Now that stopping is a real operation, the flag is enough: workers wind
// themselves up, and the application's own `deinit` releases the port properly. It also
// stops the library from killing its host, which `_exit` inside a shared library would.
fn onShutdownSignal(_: std.posix.SIG) callconv(.c) void {
    shutting_down.store(true, .monotonic);
}

/// Install handlers for SIGINT and SIGTERM so they request a stop. Opt-in, and never
/// called by `run()`: taking over a process's signal disposition is the host
/// application's decision, not a library's, and doing it silently would clobber a
/// handler the host had already installed — under a Python binding it would break
/// KeyboardInterrupt outright.
///
/// Call it AFTER `run()`. Io.Threaded installs its own signal setup during init, so
/// handlers registered before that get overwritten by it.
pub fn installShutdownHandlers() void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onShutdownSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
}


// ---------------------------------------------------------------- internal surface
//
// The declarations below are `pub` for one reason: `federation.zig` needs them, and Zig
// has no narrower way to share state between two files of one module. They are internals,
// not API — a library user should reach for `Qnnt` and `Tld` and nothing else here.
//
// Keeping them listed in one comment rather than scattering `pub` silently through the
// file makes the coupling countable, which is the point: federation touches the directory
// and its mutex, the node id, the worker and shutdown machinery, the addressing helpers,
// the reply/formatting helpers used by its `peers` output, and the SO_REUSEADDR listener.
// If that list starts growing, the split is in the wrong place.

pub fn nodeRun() bool {
    // Cleared here rather than only in nodeDeinit, so a node can be started again after
    // being stopped — which is the whole point of having a shutdown path.
    shutting_down.store(false, .monotonic);
    registry_since_us.store(0, .monotonic);
    node_running = true;

    // Before the allocator and the workers, so there is as little already-faulted memory
    // as possible and MCL_FUTURE covers everything that follows.
    applyMemoryLocking();

    io_impl = .init(allocator, .{});
    io = io_impl.io();

    ensureNodeId(); // needs `io` for randomness, so it cannot happen any earlier

    // Signal handlers are deliberately NOT installed here; see installShutdownHandlers.

    // One sweeper for subscription liveness. Cheap when the timeout is 0 (the default):
    // it wakes every 200 ms, sees no timeout set, and goes back to sleep.
    if (!spawnWorker(staleSweepRun, .{})) {
        std.debug.print("error spawning stale sweeper\n", .{});
    }

    if (!spawnWorker(registryRun, .{})) {
        std.debug.print("error spawning registry thread\n", .{});
        return false;
    }

    if (rt_priority.load(.monotonic) != 0) {
        std.debug.print("worker threads requesting SCHED_FIFO priority {d}\n", .{
            rt_priority.load(.monotonic),
        });
    }

    federation.start();

    sleepMsFn(5);
    return true;
}

// Start publishing `topic`. `source` and `period_us` are optional and go together:
// pass both to have the library drive the topic from its own scheduler thread, or both
// null to publish manually via `publish()`. Supplying only one of the two is a caller
// mistake and is reported rather than silently ignored.
//
// The interval is given as a period in microseconds rather than a frequency, so it is
// the same unit the scheduler paces to: every rate the clock can express is reachable,
// and there is no rounding step between what the caller asks for and what it gets.
//
// A period of 0 means unpaced — publish as fast as the machine manages, with no sleep
// between ticks. That is a real mode rather than a degenerate one: the smallest
// non-zero period still sleeps every tick, and a 1 us sleep costs several microseconds
// of syscall, so 0 is measurably faster than 1. It also busies a core, hence the
// notice at startup.
pub fn publisherRun(topic: []const u8, source: ?Qnnt.SourceHandler, period_us: ?u64, context: ?*anyopaque) bool {
    if ((source == null) != (period_us == null)) {
        std.debug.print("publisher {s}: source and period must be given together\n", .{topic});
        return false;
    }

    const period = period_us orelse 0;
    if (source != null and period == 0) {
        std.debug.print("publisher {s}: unpaced (period 0), will busy one core\n", .{topic});
        // At real-time priority that stops being merely wasteful: a SCHED_FIFO thread in a
        // tight loop outranks every SCHED_OTHER thread on its core, including the ones the
        // system needs. Linux's RT throttle (sched_rt_runtime_us, 950 ms of each second by
        // default) is what keeps the machine reachable, and leaning on it is not a design.
        if (rt_priority.load(.monotonic) != 0) {
            std.debug.print(
                "publisher {s}: WARNING -- unpaced AND SCHED_FIFO priority {d}. This will " ++
                    "monopolise a core and is held back only by the kernel's RT throttle. " ++
                    "Give the publisher a period, or leave it at default priority.\n",
                .{ topic, rt_priority.load(.monotonic) },
            );
        }
    }

    const token = createTopicToken(topic, .publisher) orelse {
        std.debug.print("error tracking publisher {s}\n", .{topic});
        return false;
    };

    if (!spawnWorkerFor(token, nodePublish, .{ token, source, period, context })) {
        std.debug.print("error spawning publisher thread for {s}\n", .{topic});
        detachTopicTokenPtr(token);
        destroyTopicToken(token);
        return false;
    }
    sleepMsFn(5);
    return true;
}

// ---------------------------------------------------------------- request / reply
//
// Everything above this line is one-way: a publisher writes and whoever is listening
// reads. A procedure is the other shape -- one request, one reply, addressed to a name --
// and it needs three things pub/sub does not have.
//
// DISCOVERY is the directory, unchanged. A responder registers its endpoint exactly as a
// publisher does, which is what buys federation, expiry and the publisher port range for
// free rather than building a second naming scheme beside the first. The entry carries an
// `EntryKind` so the two cannot be confused; see the note there for why a collision that
// merely deadlocked would be the worst outcome.
//
// FRAMING is a 4-byte big-endian length and then the bytes. Deliberately not TLD: a
// payload here is opaque to qnnt, and very often IS a TLD frame, so imposing TLD would
// mean either double-encoding or forbidding raw bytes. A reply prefixes its payload with
// one status byte, so "the handler refused" is distinguishable from "the handler returned
// nothing", which a bare length cannot express.
//
// LIFETIME is one connection per call. No correlation ids, no multiplexing, no
// head-of-line blocking between concurrent callers, and a dead peer is a failed connect
// rather than a request that waits for a reply that is never coming. The cost is a TCP
// handshake per call, which is why `request` is documented as a control-plane operation:
// for anything at streaming rates, publish.

/// How a request ended. Values cross the C ABI: append, never renumber.
pub const RpcStatus = enum(u8) {
    ok = 0,
    /// No such procedure in the directory, or the name is a topic rather than a procedure.
    no_procedure = 1,
    /// The procedure resolved but its host could not be reached.
    unreachable_host = 2,
    /// No reply within the timeout.
    timed_out = 3,
    /// The responder ran and declined to answer -- the handler returned null.
    refused = 4,
    /// The request or the reply was larger than `maxFrameBytes`.
    too_large = 5,
    /// Anything else: a malformed reply, a connection broken mid-exchange.
    failed = 6,
};

/// Serves one request. Returns the reply, or null to refuse -- which reaches the caller as
/// `refused`, distinct from an empty reply.
///
/// Runs on the responder's own thread, so it must be thread-safe. `request` is valid only
/// for the call. The RETURN value is written to the socket after the handler returns, so it
/// must outlive the call: a literal, a global, or heap the handler keeps alive -- never a
/// buffer on the handler's frame. Same contract as `SourceHandler`.
pub const ResponderHandlerFn = *const fn (
    procedure: []const u8,
    request: []const u8,
    context: ?*anyopaque,
) ?[]const u8;

/// Default deadline for a request that does not name one.
pub const default_request_timeout_ms: u64 = 5000;

/// How long a responder waits for a client that has connected to finish sending. A client
/// that opens a connection and then stops -- crashed, or hostile -- must not hold the
/// responder's only thread for ever.
const responder_read_timeout_ms: u64 = 5000;

/// In-flight `requestBegin` calls. Each holds a thread, so this is a real bound rather
/// than a formality: the failure it prevents is a caller looping on requestBegin against a
/// dead procedure and spawning a thread per iteration.
pub const max_pending_requests: usize = 256;

fn deadlineFrom(timeout_ms: u64) u64 {
    const now: u64 = @intCast(nowMicrosFn());
    const ms = if (timeout_ms == 0) default_request_timeout_ms else timeout_ms;
    return now +| ms *| 1000;
}

/// Fill `dest` completely, or fail. The deadline covers the whole fill, not each read, so
/// a peer dribbling one byte at a time cannot extend it indefinitely.
fn receiveExact(sock: *const net.Socket, dest: []u8, deadline_us: u64) !void {
    var filled: usize = 0;
    while (filled < dest.len) {
        const now: u64 = @intCast(nowMicrosFn());
        if (now >= deadline_us) return error.TimedOut;

        const remain_ms = (deadline_us - now + 999) / 1000;
        const timeout: Io.Timeout = .{ .duration = .{
            .raw = Io.Duration.fromMilliseconds(@intCast(@min(remain_ms, 1 << 30))),
            .clock = .awake,
        } };

        const message = sock.receiveTimeout(io, dest[filled..], timeout) catch |err| switch (err) {
            error.Timeout => return error.TimedOut,
            else => return error.Broken,
        };
        // Zero bytes with no error is the peer closing: more will never arrive, so waiting
        // out the rest of the deadline would only delay the same answer.
        if (message.data.len == 0) return error.Broken;
        filled += message.data.len;
    }
}

fn sendAll(stream: *net.Stream, bytes: []const u8) !void {
    var writer = stream.writer(io, &.{});
    try writer.interface.writeAll(bytes);
}

/// `[u32 be length][body]`. The length counts the body only.
fn sendFrame(stream: *net.Stream, first: []const u8, rest: []const u8) !void {
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(first.len + rest.len), .big);
    try sendAll(stream, &header);
    if (first.len != 0) try sendAll(stream, first);
    if (rest.len != 0) try sendAll(stream, rest);
}

/// Read one length-prefixed frame into `buf`, returning what it holds.
fn receiveFrame(sock: *const net.Socket, buf: *std.ArrayList(u8), deadline_us: u64) ![]u8 {
    var header: [4]u8 = undefined;
    try receiveExact(sock, &header, deadline_us);

    const len = std.mem.readInt(u32, &header, .big);
    // The length is 4 attacker-controlled bytes, so it is checked before it is trusted as
    // an allocation size -- the same rule `readFrame` follows for TLD.
    if (len > maxFrameBytes()) return error.TooLarge;

    buf.clearRetainingCapacity();
    try buf.ensureTotalCapacity(allocator, len);
    buf.items.len = len;
    if (len != 0) try receiveExact(sock, buf.items, deadline_us);
    return buf.items;
}

// ---------------------------------------------------------------- responder side

/// Keep the registry's directory pointing at this responder. `registerLoop` for procedures:
/// the same refresh cadence and the same reason -- a registry elected after a failover has
/// to re-learn what is served here.
fn rpcRegisterLoop(token: *TopicToken, endpoint: net.IpAddress) void {
    while (!token.stopping()) {
        rpcRegisterOnce(token.topic, endpoint) catch {}; // registry not up yet / mid-failover
        if (!sleepMsInterruptibleFor(token, registry_probe_interval_ms)) return;
    }
}

fn rpcRegisterOnce(procedure: []const u8, endpoint: net.IpAddress) !void {
    var cmd_buf: [320]u8 = undefined;
    const command = try std.fmt.bufPrint(&cmd_buf, "rpc {s} tcp://{f}", .{ procedure, endpoint });
    var reply_buf: [256]u8 = undefined;
    _ = try registryCommand(command, &reply_buf);
}

fn responderLoop(token: *TopicToken, handler: ResponderHandlerFn, context: ?*anyopaque) !void {
    const procedure = token.topic;

    var server = listenForPublisher(procedure) catch |err| {
        if (err != error.ShuttingDown) {
            std.debug.print("responder {s}: not started\n", .{procedure});
        }
        return;
    };
    defer server.deinit(io);

    if (!trackSocketFor(token, server.socket, .listener)) return;
    defer untrackSocketFor(token, server.socket);

    var endpoint: net.IpAddress = try .parse(advertiseText(), 0);
    endpoint.setPort(server.socket.address.getPort());

    std.debug.print("responder {s} listening on tcp://{f}\n", .{ procedure, endpoint });

    if (!spawnWorkerFor(token, rpcRegisterLoop, .{ token, endpoint })) {
        std.debug.print("failed to spawn register loop for responder {s}\n", .{procedure});
    }

    // One buffer for the whole responder, reused per request rather than per connection.
    var request_buf: std.ArrayList(u8) = .empty;
    defer request_buf.deinit(allocator);

    while (!token.stopping()) {
        var client = server.accept(io) catch |err| {
            if (token.stopping()) return; // our own shutdown, or this procedure's
            return err;
        };
        // Unlike a publisher's subscriber list, a request connection is finished with at
        // the end of this iteration -- so it is closed here, and the waker connection that
        // `breakTopicSockets` uses to interrupt the accept is closed here too. That is safe
        // where it is not for a publisher: nothing has bound this port from a fixed range
        // and gone on to need it back within the TIME_WAIT window, because the responder
        // holding it is the thing being torn down.
        defer client.close(io);

        if (token.stopping()) return;

        serveRequest(procedure, &client, handler, context, &request_buf) catch |err| {
            // One bad client is not a reason to stop answering everyone else.
            if (err != error.Broken and err != error.TimedOut) {
                std.debug.print("responder {s}: {t}\n", .{ procedure, err });
            }
        };
    }
}

fn serveRequest(
    procedure: []const u8,
    client: *net.Stream,
    handler: ResponderHandlerFn,
    context: ?*anyopaque,
    buf: *std.ArrayList(u8),
) !void {
    const deadline = deadlineFrom(responder_read_timeout_ms);

    const request = receiveFrame(&client.socket, buf, deadline) catch |err| {
        // A request too large to read still gets an answer, so the caller learns why
        // rather than timing out. Nothing else can be said on a broken connection.
        if (err == error.TooLarge) {
            sendFrame(client, &.{@intFromEnum(RpcStatus.too_large)}, &.{}) catch {};
        }
        return err;
    };

    if (handler(procedure, request, context)) |reply| {
        if (reply.len > maxFrameBytes()) {
            std.debug.print(
                "responder {s}: reply of {d} bytes exceeds the {d} byte cap\n",
                .{ procedure, reply.len, maxFrameBytes() },
            );
            try sendFrame(client, &.{@intFromEnum(RpcStatus.too_large)}, &.{});
            return;
        }
        try sendFrame(client, &.{@intFromEnum(RpcStatus.ok)}, reply);
    } else {
        try sendFrame(client, &.{@intFromEnum(RpcStatus.refused)}, &.{});
    }
}

/// Serve `procedure` on this node. The handler answers one request at a time; a slow
/// handler delays the next caller rather than being run concurrently, which is what makes
/// a handler that touches shared state safe to write without a lock of its own.
pub fn addResponderRun(
    procedure: []const u8,
    handler: ResponderHandlerFn,
    context: ?*anyopaque,
) bool {
    const token = createTopicToken(procedure, .responder) orelse {
        std.debug.print("error tracking responder {s}\n", .{procedure});
        return false;
    };

    if (!spawnWorkerFor(token, responderLoop, .{ token, handler, context })) {
        std.debug.print("error spawning responder thread for {s}\n", .{procedure});
        detachTopicTokenPtr(token);
        destroyTopicToken(token);
        return false;
    }
    sleepMsFn(5);
    return true;
}

/// Stop serving `procedure`: joins its threads and drops its registration. The sibling of
/// `removePublisher`, with the same guarantee and the same refusal when called from the
/// procedure's own handler.
pub fn removeResponder(procedure: []const u8) bool {
    return stopAndForget(procedure, .responder, "removeResponder");
}

// ---------------------------------------------------------------- requester side

fn resolveProcedure(procedure: []const u8) ?net.IpAddress {
    var cmd_buf: [320]u8 = undefined;
    const command = std.fmt.bufPrint(&cmd_buf, "rpc-find {s}", .{procedure}) catch return null;
    var reply_buf: [256]u8 = undefined;
    const reply = registryCommand(command, &reply_buf) catch return null;

    var lines = std.mem.splitScalar(u8, reply, '\n');
    while (lines.next()) |line| {
        const text = std.mem.trim(u8, line, " \t\r");
        if (text.len == 0 or text[0] == '#') continue;
        return parseTcpUri(text) catch return null;
    }
    return null;
}

/// One request, start to finish, on the calling thread.
///
/// The reply is written into `out` and its length returned through `out_len`. A reply
/// larger than `out` is `too_large`: the size is the caller's to choose, because the
/// library has nowhere to put a reply the caller did not make room for.
pub fn requestRun(
    procedure: []const u8,
    payload: []const u8,
    timeout_ms: u64,
    out: []u8,
    out_len: *usize,
) RpcStatus {
    out_len.* = 0;
    if (payload.len > maxFrameBytes()) return .too_large;

    const deadline = deadlineFrom(timeout_ms);
    const endpoint = resolveProcedure(procedure) orelse return .no_procedure;

    var stream = endpoint.connect(io, .{ .mode = .stream }) catch return .unreachable_host;
    defer stream.close(io);

    // Tracked so a shutdown mid-request does not hold the caller until the peer answers.
    if (!trackSocket(stream.socket, .stream)) return .failed;
    defer untrackSocket(stream.socket);

    sendFrame(&stream, payload, &.{}) catch return .failed;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const frame = receiveFrame(&stream.socket, &buf, deadline) catch |err| return switch (err) {
        error.TimedOut => .timed_out,
        error.TooLarge => .too_large,
        else => .failed,
    };

    // Status byte, then the payload. A frame with neither is a responder speaking a
    // protocol this build does not know.
    if (frame.len < 1) return .failed;
    const status = statusFromWire(frame[0]);
    const body = frame[1..];
    if (status != .ok) return status;

    if (body.len > out.len) return .too_large;
    @memcpy(out[0..body.len], body);
    out_len.* = body.len;
    return .ok;
}

// ---------------------------------------------------------------- non-blocking requests
//
// `request` blocks, which is fine for a script and wrong for anything with a UI or a
// control loop: a 5 second timeout against an unreachable host freezes the caller for 5
// seconds. The non-blocking form hands the work to a thread and gives the caller a ticket.
//
// Completions are DRAINED, not delivered. A callback would have to fire on the worker's
// thread, and that is exactly the crossing `subscribeQueue` exists to avoid -- a managed
// runtime would be entered from a thread it has never seen, holding no GIL and with
// nowhere to put an exception. So `pollReplies` mirrors `poll`, down to the lifetime of
// the bytes it hands back, and the two can be drained from the same loop.

/// One completed request. `data` is owned by the library and valid until the next
/// `pollReplies` call, which recycles it -- the same contract as `QueuedMessage.data`.
pub const QueuedReply = struct {
    /// The ticket `requestBegin` returned.
    id: u64,
    status: RpcStatus,
    /// The procedure that was called, so one drain loop can serve many call sites.
    procedure: []const u8,
    data: []const u8,
};

const ReplySlot = struct {
    id: u64 = 0,
    status: RpcStatus = .failed,
    procedure: std.ArrayList(u8) = .empty,
    buf: std.ArrayList(u8) = .empty,
};

var replies_done: std.ArrayList(ReplySlot) = .empty;
var replies_staging: std.ArrayList(ReplySlot) = .empty;
var replies_mutex: Io.Mutex = .init;
var replies_seq: std.atomic.Value(u32) = .init(0);
var request_seq: Atomic64.Value = .init(0);
var requests_in_flight: std.atomic.Value(usize) = .init(0);

/// What a request worker owns for the duration of its call. Copied because the caller's
/// slices are theirs again the moment `requestBegin` returns.
const RequestJob = struct {
    id: u64,
    procedure: []u8,
    payload: []u8,
    timeout_ms: u64,
};

/// Start a request and return immediately with a ticket to match the reply against.
///
/// Returns 0 when the request could not be started at all -- out of memory, too many
/// already in flight, or the node is stopping. A 0 is never reported through
/// `pollReplies`, so a caller that checks for it has nothing else to time out.
pub fn requestBeginRun(procedure: []const u8, payload: []const u8, timeout_ms: u64) u64 {
    if (!node_running) return 0;
    if (payload.len > maxFrameBytes()) return 0;

    // Checked before the copies, so the failure path allocates nothing.
    if (requests_in_flight.load(.monotonic) >= max_pending_requests) {
        std.debug.print(
            "requestBegin {s}: {d} requests already in flight\n",
            .{ procedure, max_pending_requests },
        );
        return 0;
    }

    const job = allocator.create(RequestJob) catch return 0;
    const name = allocator.dupe(u8, procedure) catch {
        allocator.destroy(job);
        return 0;
    };
    const body = allocator.dupe(u8, payload) catch {
        allocator.free(name);
        allocator.destroy(job);
        return 0;
    };

    const id = request_seq.fetchAdd(1, .monotonic) + 1; // 0 is reserved for "not started"
    job.* = .{ .id = id, .procedure = name, .payload = body, .timeout_ms = timeout_ms };

    _ = requests_in_flight.fetchAdd(1, .monotonic);
    if (!spawnWorker(requestWorker, .{job})) {
        _ = requests_in_flight.fetchSub(1, .monotonic);
        allocator.free(body);
        allocator.free(name);
        allocator.destroy(job);
        return 0;
    }
    return id;
}

fn requestWorker(job: *RequestJob) void {
    defer {
        allocator.free(job.payload);
        allocator.free(job.procedure);
        allocator.destroy(job);
        _ = requests_in_flight.fetchSub(1, .monotonic);
    }

    // Sized to the cap rather than guessed: the worker has no caller buffer to grow into,
    // and a reply that does not fit would be reported as too_large when it is not.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var status: RpcStatus = .failed;
    var length: usize = 0;
    if (out.resize(allocator, @min(maxFrameBytes(), 1 << 20))) {
        status = requestRun(job.procedure, job.payload, job.timeout_ms, out.items, &length);
    } else |_| {
        status = .failed;
    }

    pushReply(job.id, job.procedure, status, out.items[0..length]);
}

fn pushReply(id: u64, procedure: []const u8, status: RpcStatus, data: []const u8) void {
    replies_mutex.lockUncancelable(io);
    defer replies_mutex.unlock(io);

    replies_done.ensureUnusedCapacity(allocator, 1) catch return;
    var slot: ReplySlot = .{ .id = id, .status = status };
    slot.procedure.appendSlice(allocator, procedure) catch {
        slot.procedure.deinit(allocator);
        return;
    };
    slot.buf.appendSlice(allocator, data) catch {
        slot.procedure.deinit(allocator);
        slot.buf.deinit(allocator);
        return;
    };
    replies_done.appendAssumeCapacity(slot);

    // Wake a caller parked in pollReplies, the way queuePush wakes one parked in poll.
    _ = replies_seq.fetchAdd(1, .monotonic);
    io.futexWake(u32, &replies_seq.raw, 1);

    // And wake anyone parked in `poll`, which is a deliberate widening of what that
    // sequence means: "something arrived worth looking at", not "a message arrived".
    //
    // A binding that drains both from one loop -- the Qt poller does, and any C program
    // written the same way -- blocks in `poll` waiting for messages, and only looks at
    // replies when that returns. On a node doing control-plane RPC and streaming nothing,
    // `poll` sleeps out its whole timeout every turn, so a reply that completed in a
    // millisecond waited up to 100 ms to be seen. That is two orders of magnitude added to
    // the call it was reporting.
    //
    // The waiter wakes, finds no messages, returns an empty batch and goes on to drain the
    // replies. The spurious wakeup costs a loop iteration and can only happen while
    // requests are actually completing -- a program that makes none is never woken by one.
    _ = queue_seq.fetchAdd(1, .monotonic);
    io.futexWake(u32, &queue_seq.raw, 1);
}

/// Drain completed requests. Returns the prefix of `out` that was filled.
///
/// `timeout_ms` of 0 polls and returns whatever is ready; a negative value waits until
/// something is. The slices in the results are recycled by the NEXT call, so copy anything
/// kept beyond the current batch.
pub fn pollReplies(out: []QueuedReply, timeout_ms: i32) []QueuedReply {
    if (out.len == 0) return out[0..0];

    replies_mutex.lockUncancelable(io);
    defer replies_mutex.unlock(io);

    if (replies_done.items.len == 0 and timeout_ms != 0) {
        // Read the sequence before unlocking so a completion landing in the gap is not
        // missed -- futexWaitTimeout returns at once when the word has already moved.
        const observed = replies_seq.load(.monotonic);
        replies_mutex.unlock(io);
        const timeout: Io.Timeout = if (timeout_ms < 0)
            .none
        else
            .{ .duration = .{
                .raw = Io.Duration.fromMilliseconds(timeout_ms),
                .clock = .awake,
            } };
        io.futexWaitTimeout(u32, &replies_seq.raw, observed, timeout) catch {};
        replies_mutex.lockUncancelable(io);
    }

    const take = @min(out.len, replies_done.items.len);
    if (take == 0) return out[0..0];

    // Last batch's buffers go back now rather than at the end of the previous call: that
    // is what lets the slices handed out then stay valid until this call.
    for (replies_staging.items) |*slot| {
        slot.procedure.deinit(allocator);
        slot.buf.deinit(allocator);
    }
    replies_staging.clearRetainingCapacity();
    replies_staging.ensureTotalCapacity(allocator, take) catch return out[0..0];

    for (0..take) |i| {
        replies_staging.appendAssumeCapacity(replies_done.orderedRemove(0));
        const slot = &replies_staging.items[i];
        out[i] = .{
            .id = slot.id,
            .status = slot.status,
            .procedure = slot.procedure.items,
            .data = slot.buf.items,
        };
    }
    return out[0..take];
}

/// How many `requestBegin` calls have not yet completed.
pub fn requestsInFlight() usize {
    return requests_in_flight.load(.monotonic);
}

fn repliesDeinit() void {
    replies_mutex.lockUncancelable(io);
    defer replies_mutex.unlock(io);
    for (replies_done.items) |*slot| {
        slot.procedure.deinit(allocator);
        slot.buf.deinit(allocator);
    }
    replies_done.clearAndFree(allocator);
    for (replies_staging.items) |*slot| {
        slot.procedure.deinit(allocator);
        slot.buf.deinit(allocator);
    }
    replies_staging.clearAndFree(allocator);
}

fn statusFromWire(value: u8) RpcStatus {
    return switch (value) {
        0 => .ok,
        1 => .no_procedure,
        2 => .unreachable_host,
        3 => .timed_out,
        4 => .refused,
        5 => .too_large,
        else => .failed,
    };
}

// Stop the node and release everything it holds. Safe to call once per `nodeRun`, and a
// node may be started again afterwards.
//
// The ordering is the whole point: the workers must be *gone* before anything they touch
// is freed. Signal them, break the calls they are blocked in, join them, and only then
// tear down the maps and `io`. Doing this in the other order — which is what this
// function used to do — frees `io` out from under threads still parked in `accept`.
pub fn nodeDeinit() void {
    shutting_down.store(true, .monotonic);
    // Wakes any federation connector parked on its change futex, so shutdown does not
    // wait out an anti-entropy interval.
    federation.wakeForShutdown();
    breakLiveSockets();
    breakSubscriberStreams();
    joinWorkers();
    // The per-topic workers are not in the global list, so they are joined separately.
    // After `joinWorkers`, because a publisher's accept loop can still be spawning its
    // register loop while the global workers are winding down.
    joinTopicTokens();

    // Past this point no worker exists, so the locks below are uncontended and only
    // taken to keep the access pattern honest.

    {
        directory_mutex.lockUncancelable(io);
        defer directory_mutex.unlock(io);
        var it = directory.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*); // owned keys
            entry.value_ptr.peers.deinit(allocator);
            entry.value_ptr.pending.deinit(allocator);
        }
        directory.clearAndFree();
    }
    {
        subscribers_mutex.lockUncancelable(io);
        defer subscribers_mutex.unlock(io);
        var it = subscribers.iterator();
        while (it.next()) |entry| {
            // Close the delivery connections too. Leaving these open leaked a socket per
            // subscriber per node lifetime, which only stayed invisible because a node
            // never used to outlive its process.
            for (entry.value_ptr.items) |node| node.client.close(io);
            entry.value_ptr.deinit(allocator);
        }
        subscribers.clearAndFree();
    }

    {
        live_sockets_mutex.lockUncancelable(io);
        defer live_sockets_mutex.unlock(io);
        live_sockets.clearAndFree(allocator);
    }
    {
        // Keys are duped on first mark and were freed nowhere, so a node that started and
        // stopped repeatedly leaked one per subscribed topic per lifetime.
        sub_states_mutex.lockUncancelable(io);
        defer sub_states_mutex.unlock(io);
        var it = sub_states.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        sub_states.clearAndFree();
    }

    queueDeinit();
    repliesDeinit();

    io_impl.deinit();
    node_running = false;
}


test {
    _ = @import("./qnnt.test.zig");
    _ = @import("./topics.zig");
    // Pulled in here rather than given its own build entry: federation.zig imports this
    // file, so testing it as a root would recompile and re-run the whole suite in a second
    // binary -- and both copies would race for the same test registry port.
    _ = @import("./federation.zig");
}

test "the directory epoch counts material changes and ignores refresh heartbeats" {
    // This is the premise the whole conditional mirror rests on. If a refresh bumped the
    // epoch, a standby's "am I current?" would be answered "no" every probe interval per
    // publisher, every full directory would be re-sent, and the cheap path would never
    // fire once. It is also why the epoch is not a digest over the entries: `version` is
    // set to `now_us` on every refresh, so anything derived from entry contents changes
    // constantly while nothing has actually happened.
    const testing = std.testing;

    try testing.expect(setRegistryPortFn(22308));
    try testing.expect(nodeRun());
    defer nodeDeinit();

    const first = try net.IpAddress.parse("127.0.0.1", 9401);
    const moved = try net.IpAddress.parse("127.0.0.1", 9402);

    const before = directory_epoch.load(.monotonic);

    // A topic appearing is a change.
    try registerTopic("epoch/one", first, node_id, .topic);
    const after_insert = directory_epoch.load(.monotonic);
    try testing.expect(after_insert > before);

    // Refreshing it is not. This is the heartbeat every publisher sends every couple of
    // seconds, and it must be free.
    try registerTopic("epoch/one", first, node_id, .topic);
    try registerTopic("epoch/one", first, node_id, .topic);
    try testing.expectEqual(after_insert, directory_epoch.load(.monotonic));

    // The endpoint moving is a change: a standby holding the old address would hand
    // subscribers somewhere nothing is listening.
    try registerTopic("epoch/one", moved, node_id, .topic);
    const after_move = directory_epoch.load(.monotonic);
    try testing.expect(after_move > after_insert);

    // And so is going away.
    try testing.expect(unregisterTopic("epoch/one"));
    try testing.expect(directory_epoch.load(.monotonic) > after_move);
}

test "a client node declines the registry role" {
    // The opt-out for a resource-constrained host: it publishes and subscribes normally
    // but is never elected, so it never holds the whole host's directory.
    const testing = std.testing;

    try testing.expect(setRegistryRoleFn(.client));
    defer _ = setRegistryRoleFn(.candidate);
    try testing.expectEqual(RegistryRole.client, registryRoleFn());

    // Refused once a node is running, like every other pre-start knob: changing it under a
    // live node would leave the registry thread's decision and the reported role disagreeing.
    try testing.expect(setRegistryPortFn(22309));
    try testing.expect(nodeRun());
    defer nodeDeinit();
    try testing.expect(!setRegistryRoleFn(.candidate));
    try testing.expect(!setRegistryMirrorFn(false));
}
