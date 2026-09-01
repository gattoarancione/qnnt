//! Federating the registry across hosts.
//!
//! The registry on its own is host-local: nodes on one host elect one of themselves to
//! hold the directory. This file extends that to a set of hosts, each configured with the
//! addresses of its peers, exchanging directory contents and propagating changes.
//!
//! It sits beside `qnnt.zig` rather than inside it because it is a separable concern with
//! its own protocol, listener and workers. It is not independent, though: it reads and
//! writes the same directory and shares the node's worker and shutdown machinery, which
//! it reaches through the declarations `qnnt.zig` marks as its internal surface. The
//! traffic the other way is deliberately narrow -- `qnnt.zig` calls only `start`,
//! `notifyChange`, `entryIsServable` and `writePeerList` from here.
//!
//! Three properties shape the design:
//!
//!  * The registry listener stays on loopback. Federation gets its OWN listener with a
//!    small verb set that cannot inspect or mutate the local directory the way `list` and
//!    `unpub` can. Exposing `unpub` to a network is a denial primitive; exposing `pub` is
//!    a traffic-hijack primitive, since the directory is trusted.
//!
//!  * Identity is a NodeId, never an address. Entries carry a port and an OPTIONAL host;
//!    when the host is absent the receiver substitutes the address it reached the sender
//!    on. That is what lets a node bind 0.0.0.0, or sit behind a gateway that picks its
//!    public address, without ever knowing its own address.
//!
//!  * Deletion is by expiry, not tombstones. Publishers already refresh every probe
//!    interval, so an entry whose origin goes quiet ages out on its own. `unpub` needs no
//!    distributed delete: it simply stops being refreshed.

const std = @import("std");
const qnnt = @import("qnnt.zig");

const Io = std.Io;
const net = std.Io.net;
const Stream = net.Stream;

const allocator = @import("alloc.zig").allocator;
const NodeId = qnnt.NodeId;
const TopicEntry = qnnt.TopicEntry;
const Reply = qnnt.Reply;
const resolve = @import("resolve.zig");

const max_peers = 32;
const fed_sync_interval_ms = 5_000;

/// Federation's own port, separate from the registry's so the registry can stay loopback.
pub const default_port = 2223;

// A remote entry stops being handed out once this stale, because pointing a subscriber at
// an unreachable host just makes it retry, and is dropped entirely after `forget`.
const fed_serve_until_us: u64 = 30 * std.time.us_per_s;
const fed_forget_after_us: u64 = 300 * std.time.us_per_s;

const Peer = struct {
    // Wide enough for a hostname, not just an address literal: peers may be named, and the
    // name is kept verbatim so it is re-resolved on every dial attempt.
    host: [resolve.max_host_len]u8 = @splat(0),
    host_len: usize = 0,
    port: u16 = 0,

    // Status, for the `peers` command. Written by that peer's connector, read by a
    // registry client handler, so they are atomics rather than plain fields.
    connected: std.atomic.Value(bool) = .init(false),
    last_sync_us: std.atomic.Value(u64) = .init(0),
    learned: std.atomic.Value(u64) = .init(0),
    attempts: std.atomic.Value(u64) = .init(0),

    fn hostText(p: *const Peer) []const u8 {
        return p.host[0..p.host_len];
    }
};

var fed_peers: [max_peers]Peer = @splat(.{});
var peer_count: usize = 0;
var federation_port: u16 = default_port;

// The cluster key is the switch. Federation runs when one is set and not otherwise,
// because the alternative -- an unauthenticated directory reachable from a network -- lets
// anyone redirect a topic's subscribers. Requiring a port as well was the wrong shape: it
// meant the common case (one key, default port) started nothing and said nothing.
var cluster_key: [64]u8 = @splat(0);
var cluster_key_len: usize = 0;

const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;

// Bumped whenever the directory changes structurally, and used as a futex word so peer
// connectors wake at once instead of waiting out the anti-entropy interval.
//
// Only *structural* changes count: a new topic, a moved endpoint, an unpub, or an entry
// learned from one peer that the others have not seen. Ordinary refreshes and subscriber
// counts deliberately do not, because every publisher refreshes every probe interval and
// signalling those would turn a 5 s round into a continuous push storm. Anti-entropy
// carries them instead, and 5 s is comfortably inside the 30 s a remote entry is served
// for, so liveness never lapses.
var fed_change_seq: std.atomic.Value(u32) = .init(0);

// Entries applied from peers that dialed US. They belong to no configured peer -- we never
// chose to talk to them -- so they cannot be attributed in the per-peer counters, and
// leaving them out entirely made `peers` report "learned 0" on a node whose whole
// directory had arrived that way.
var inbound_applied: std.atomic.Value(u64) = .init(0);

pub fn notifyChange() void {
    if (federation_port == 0) return;
    _ = fed_change_seq.fetchAdd(1, .monotonic);
    qnnt.io.futexWake(u32, &fed_change_seq.raw, std.math.maxInt(u32));
}

// Wait for the next change, the anti-entropy deadline, or shutdown -- whichever comes
// first. `observed` must be read BEFORE the work that precedes the wait, so a change
// landing during that work is not slept through: the futex returns immediately when the
// word has already moved on.
fn waitForChangeOrDeadline(observed: u32, ms: u64) bool {
    if (qnnt.isShuttingDown()) return false;
    qnnt.io.futexWaitTimeout(u32, &fed_change_seq.raw, observed, .{ .duration = .{
        .raw = Io.Duration.fromMilliseconds(@intCast(ms)),
        .clock = .awake,
    } }) catch {};
    return !qnnt.isShuttingDown();
}

/// Port for the federation listener; defaults to `default_port`. Passing 0 disables
/// federation outright, whatever key is set.
pub fn setPort(port: u16) bool {
    if (qnnt.node_running) return false;
    federation_port = port;
    return true;
}

/// Pre-shared key shared by every node in the cluster. Required for federation.
pub fn setClusterKey(key: []const u8) bool {
    if (qnnt.node_running or key.len == 0 or key.len > cluster_key.len) return false;
    @memcpy(cluster_key[0..key.len], key);
    cluster_key_len = key.len;
    return true;
}

/// Add a peer to dial.
///
/// `host` is an IPv4 or IPv6 literal, or a hostname -- resolved through libc, so /etc/hosts,
/// resolv.conf, mDNS and search domains all apply. A name is stored as written and resolved
/// again on every dial attempt, so a peer that changes address, or a name that does not
/// resolve until the network comes up, needs no restart. Resolution failures are reported by
/// the connector, named: `UnknownHost` for a name that does not exist,
/// `TemporaryResolveFailure` for one worth retrying.
///
/// Peer lists need not be symmetric or complete: an entry learned from one peer is
/// re-advertised to the others with its origin preserved, so a chain converges too.
pub fn addPeer(host: []const u8, port: u16) bool {
    if (qnnt.node_running or peer_count == max_peers or host.len == 0) return false;
    if (host.len > fed_peers[0].host.len) return false;

    var peer: Peer = .{};
    @memcpy(peer.host[0..host.len], host);
    peer.host_len = host.len;
    peer.port = if (port == 0) federation_port else port;
    fed_peers[peer_count] = peer;
    peer_count += 1;
    return true;
}

/// Whether federation will actually run: a key to authenticate with, and a port to listen
/// on. Asked by `bindText`, so a node with no key keeps its sockets on loopback and
/// exposes nothing.
pub fn enabled() bool {
    return cluster_key_len != 0 and federation_port != 0;
}

// ---------------------------------------------------------------- applying entries

// One entry as it travels between hosts. `host` empty means "you decide": the receiver
// fills in the address it reached the sender on, which is the whole NAT story.
const RemoteEntry = struct {
    origin: NodeId,
    version: u64,
    topic: []const u8,
    host: []const u8,
    port: u16,
    subs: u32,
};

fn parseNodeId(text: []const u8, out: *NodeId) bool {
    if (text.len != 32) return false;
    _ = std.fmt.hexToBytes(out, text) catch return false;
    return true;
}

// Returns true if the directory changed, which is what phase 4's push-on-change will key
// off. `observed_host` is the address we reached the sender on, used when the entry
// declines to name one.
fn applyRemoteEntry(entry: RemoteEntry, observed_host: []const u8) !bool {
    // Never take our own entries back from a peer: we are authoritative for them, and
    // accepting them would let a stale copy overwrite the live one.
    if (std.mem.eql(u8, &entry.origin, &qnnt.node_id)) return false;

    const host = if (entry.host.len == 0) observed_host else entry.host;
    var endpoint = resolve.parseLiteral(host, entry.port) catch return false;
    endpoint.setPort(entry.port);

    const now_us: u64 = @intCast(qnnt.nowMicrosFn());

    qnnt.directory_mutex.lockUncancelable(qnnt.io);
    defer qnnt.directory_mutex.unlock(qnnt.io);

    const gop = try qnnt.directory.getOrPut(entry.topic);
    if (!gop.found_existing) {
        gop.key_ptr.* = allocator.dupe(u8, entry.topic) catch |err| {
            _ = qnnt.directory.remove(entry.topic);
            return err;
        };
        gop.value_ptr.* = .{
            .endpoint = endpoint,
            .first_us = now_us,
            .last_us = now_us,
            .peers = .empty,
            .peers_us = if (entry.subs > 0) now_us else 0,
            .pending = .empty,
            .origin = entry.origin,
            .version = entry.version,
            .learned_us = now_us,
            .conflict_us = 0,
        };
        // Subscriber detail is not federated -- only the count, recorded by padding the
        // peer list with placeholders. Detail stays with the host that owns it and is
        // fetched on demand, rather than multiplying every sync by the subscriber count.
        try setRemoteSubCount(gop.value_ptr, entry.subs, endpoint);
        return true;
    }

    const held = gop.value_ptr;

    // Same origin: accept only a newer version. Comparing versions from one origin is
    // safe whatever the clock skew between hosts, and it is also what stops an update
    // circulating around a mesh forever.
    if (std.mem.eql(u8, &held.origin, &entry.origin)) {
        if (entry.version <= held.version) return false;
        held.endpoint = endpoint;
        held.version = entry.version;
        held.last_us = now_us;
        held.learned_us = now_us;
        try setRemoteSubCount(held, entry.subs, endpoint);
        return true;
    }

    // A different origin already holds this topic. First registration wins -- but only
    // against a claimant that is still there. An entry past its serve window is one whose
    // origin has stopped refreshing it, so it is not a rival any more, and preferring it
    // black-holes the topic until the forget window expires: a publisher that restarts
    // gets a new NodeId, so its own topic is held against it by the corpse of its previous
    // process, and remote subscribers are told "expired" for minutes while a live
    // publisher announces itself unheard.
    if (!entryIsServable(held, now_us)) {
        held.origin = entry.origin;
        held.endpoint = endpoint;
        held.version = entry.version;
        held.last_us = now_us;
        held.learned_us = now_us;
        held.conflict_us = now_us;
        try setRemoteSubCount(held, entry.subs, endpoint);
        return true;
    }

    // Both are live: first wins, and the clash is recorded so `list` shows it rather than
    // silently hiding a publisher.
    held.conflict_us = now_us;
    return false;
}

// The count is all that federates, so the list is filled with placeholders carrying the
// publisher's endpoint. `subs <topic>` on a remote topic proxies to the owner for detail.
fn setRemoteSubCount(entry: *TopicEntry, count: u32, endpoint: net.IpAddress) !void {
    entry.peers.clearRetainingCapacity();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try entry.peers.append(allocator, .{
            .address = endpoint,
            .connected_us = 0,
            .messages = 0,
        });
    }
    entry.peers_us = @intCast(qnnt.nowMicrosFn());
}

// ---------------------------------------------------------------- serialising

fn writeFedEntries(buffer: *std.ArrayList(u8)) !void {
    qnnt.directory_mutex.lockUncancelable(qnnt.io);
    defer qnnt.directory_mutex.unlock(qnnt.io);

    var id_buf: [32]u8 = undefined;
    const now_us: u64 = @intCast(qnnt.nowMicrosFn());

    var it = qnnt.directory.iterator();
    while (it.next()) |kv| {
        const entry = kv.value_ptr;

        // Never pass on an entry we would refuse to serve. Without this a registry keeps
        // re-teaching peers an address it already considers expired, and because a peer
        // hearing it for the first time starts its own lease from now, a dead publisher's
        // address can be handed out indefinitely -- each hop renewing what the lease was
        // there to end. `sub` has always applied this test; gossip has to apply it too.
        if (!entryIsServable(entry, now_us)) continue;

        // Ours: name a host only if one was configured. Left empty, the peer substitutes
        // the address it reached us on -- which is the address that works for it, and is
        // knowable even when our own public address is not.
        const is_local = std.mem.eql(u8, &entry.origin, &qnnt.node_id);
        var host_buf: [resolve.max_host_text]u8 = undefined;
        const host: []const u8 = if (is_local)
            (if (qnnt.advertise_len == 0) "-" else qnnt.advertiseText())
        else
            // Learned from someone else: pass on the address we resolved for them, since
            // our own connection address says nothing about a third party.
            // Host only: the port travels as its own field. Formatting the whole address
            // and trimming at the last colon used to leave an IPv6 address as "[::1]",
            // which the receiving side's parser then rejected -- third-party IPv6 entries
            // never propagated.
            resolve.hostText(entry.endpoint, &host_buf);

        const host_only = host;

        try buffer.print(allocator, "fed-entry {s} {d} {s} {s} {d} {d}\n", .{
            qnnt.formatNodeId(&id_buf, entry.origin),
            entry.version,
            kv.key_ptr.*,
            host_only,
            entry.endpoint.getPort(),
            entry.peers.items.len,
        });
    }
}

// ---------------------------------------------------------------- listener side

const FedSession = struct {
    authenticated: bool = false,
    nonce: [16]u8 = @splat(0),
    observed_host: [46]u8 = @splat(0),
    observed_len: usize = 0,

    fn observed(s: *const FedSession) []const u8 {
        return s.observed_host[0..s.observed_len];
    }
};

fn fedCommand(session: *FedSession, command: []const u8) !Reply {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);

    var it = std.mem.tokenizeAny(u8, command, " \t\r\n");
    const verb = it.next() orelse return qnnt.ownedReply(&buffer);

    // Nothing but authentication is served until authentication succeeds. The verb set
    // here is deliberately tiny: no `list`, no `unpub`, no human commands.
    if (!session.authenticated) {
        if (!qnnt.eqlAny(verb, &.{"fed-auth"})) return qnnt.errorReply(&buffer, "unauthenticated");

        const mac_text = it.next() orelse return qnnt.errorReply(&buffer, "usage: fed-auth <hmac>");
        var expected: [Hmac.mac_length]u8 = undefined;
        Hmac.create(&expected, &session.nonce, cluster_key[0..cluster_key_len]);

        var got: [Hmac.mac_length]u8 = undefined;
        if (mac_text.len != got.len * 2) return qnnt.errorReply(&buffer, "bad mac");
        _ = std.fmt.hexToBytes(&got, mac_text) catch return qnnt.errorReply(&buffer, "bad mac");

        // Constant-time, so a wrong key cannot be recovered a byte at a time by timing.
        if (!std.crypto.timing_safe.eql([Hmac.mac_length]u8, expected, got)) {
            return qnnt.errorReply(&buffer, "bad mac");
        }
        session.authenticated = true;
        try buffer.print(allocator, "ok\n", .{});
        return qnnt.ownedReply(&buffer);
    }

    if (qnnt.eqlAny(verb, &.{"fed-hello"})) {
        var id_buf: [32]u8 = undefined;
        try buffer.print(allocator, "fed-hello {s}\n", .{qnnt.formatNodeId(&id_buf, qnnt.node_id)});
        // Reflexive hint: tells a node behind a gateway how it appears from here, which
        // is the only way it can learn its own public address.
        try buffer.print(allocator, "# observed {s}\n", .{session.observed()});
    } else if (qnnt.eqlAny(verb, &.{"fed-sync"})) {
        try writeFedEntries(&buffer);
    } else if (qnnt.eqlAny(verb, &.{"fed-entry"})) {
        const entry = parseFedEntry(&it) orelse return qnnt.errorReply(&buffer, "malformed fed-entry");
        // Counted, because this is the only evidence a node has that a peer which dialled
        // *in* is teaching it anything: such a peer is not in its own peer list and so has
        // no row of its own in `peers`. Without the increment the command claimed nothing
        // had been applied while the directory was visibly full of that peer's entries.
        if (applyRemoteEntry(entry, session.observed()) catch false) {
            _ = inbound_applied.fetchAdd(1, .monotonic);
        }
        try buffer.print(allocator, "ok\n", .{});
    } else if (qnnt.eqlAny(verb, &.{"ping"})) {
        try buffer.print(allocator, "pong\n", .{});
    } else {
        try buffer.print(allocator, "error: unknown federation command '{s}'\n", .{verb});
    }

    return qnnt.ownedReply(&buffer);
}

fn parseFedEntry(it: *std.mem.TokenIterator(u8, .any)) ?RemoteEntry {
    const origin_text = it.next() orelse return null;
    const version_text = it.next() orelse return null;
    const topic = it.next() orelse return null;
    const host = it.next() orelse return null;
    const port_text = it.next() orelse return null;
    const subs_text = it.next() orelse return null;

    var origin: NodeId = undefined;
    if (!parseNodeId(origin_text, &origin)) return null;

    return .{
        .origin = origin,
        .version = std.fmt.parseInt(u64, version_text, 10) catch return null,
        .topic = topic,
        .host = if (std.mem.eql(u8, host, "-")) "" else host,
        .port = std.fmt.parseInt(u16, port_text, 10) catch return null,
        .subs = std.fmt.parseInt(u32, subs_text, 10) catch return null,
    };
}

fn handleFederationClient(client: Stream) !void {
    defer client.close(qnnt.io);
    if (!qnnt.trackSocket(client.socket, .stream)) return;
    defer qnnt.untrackSocket(client.socket);

    var session: FedSession = .{};

    // Whoever connected is, by definition, reachable at this address from here. It is the
    // fallback host for any entry they send without naming one.
    var host_buf: [46]u8 = undefined;
    const peer_text = std.fmt.bufPrint(&host_buf, "{f}", .{client.socket.address}) catch "";
    const colon = std.mem.lastIndexOfScalar(u8, peer_text, ':') orelse peer_text.len;
    session.observed_len = @min(colon, session.observed_host.len);
    @memcpy(session.observed_host[0..session.observed_len], peer_text[0..session.observed_len]);

    var rbuf: [4096]u8 = undefined;
    var reader = client.reader(qnnt.io, &rbuf);
    var writer = client.writer(qnnt.io, &.{});

    // A fresh nonce per connection, so a captured mac cannot be replayed.
    qnnt.io.random(&session.nonce);
    // "fed-nonce " + 32 hex + newline: 43 bytes. Sized at 64 rather than the hex length,
    // which was the original bug -- bufPrint failed and the connection closed mute.
    var nonce_hex: [64]u8 = undefined;
    try writer.interface.writeAll(try std.fmt.bufPrint(&nonce_hex, "fed-nonce {x}\n", .{session.nonce}));
    try writer.interface.writeAll(qnnt.response_terminator);

    while (!qnnt.isShuttingDown()) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream, error.ReadFailed => return, // peer gone, cleanly or not
            error.StreamTooLong => {
                try writer.interface.writeAll("error: line too long\n");
                try writer.interface.writeAll(qnnt.response_terminator);
                _ = reader.interface.discardDelimiterInclusive('\n') catch return;
                continue;
            },
        };

        const reply = try fedCommand(&session, line);
        defer allocator.free(reply.text);
        try writer.interface.writeAll(reply.text);

        // ALWAYS terminated, unlike the registry port. There, an empty reply means "you
        // pressed Enter, I have nothing to say" and staying silent is a courtesy to a
        // human. Here an empty reply is a real answer -- "I hold no entries" -- and
        // withholding the terminator leaves the peer blocked forever waiting for it.
        // That courtesy leaking into a machine protocol is exactly what hung the first
        // federation between two nodes that both started with empty directories.
        try writer.interface.writeAll(qnnt.response_terminator);
    }
}

fn listenerRun() void {
    while (!qnnt.isShuttingDown()) {
        const addr: net.IpAddress = net.IpAddress.parse(qnnt.bindText(), federation_port) catch |err| {
            std.debug.print("federation address parse failed: {}\n", .{err});
            return;
        };

        // SO_REUSEADDR here too, for the same reason as the registry: a restart must not
        // be locked out by a TIME_WAIT socket left by the previous listener.
        var server = qnnt.listenExclusiveOn(addr) catch |err| {
            std.debug.print(
                "federation listen on {s}:{d} failed: {} -- another node here already " ++
                    "holds it; give each one its own QNNT_FEDERATION_PORT\n",
                .{ qnnt.bindText(), federation_port, err },
            );
            if (!qnnt.sleepMsInterruptible(qnnt.registry_probe_interval_ms)) return;
            continue;
        };
        defer server.deinit(qnnt.io);

        if (!qnnt.trackSocket(server.socket, .listener)) return;
        defer qnnt.untrackSocket(server.socket);

        std.debug.print("federation listening on {s}:{d}\n", .{ qnnt.bindText(), federation_port });

        while (true) {
            const client = server.accept(qnnt.io) catch {
                if (qnnt.isShuttingDown()) return;
                break;
            };
            if (qnnt.isShuttingDown()) {
                client.close(qnnt.io);
                return;
            }
            if (!qnnt.spawnWorker(handleFederationClient, .{client})) {
                client.close(qnnt.io);
                if (qnnt.isShuttingDown()) return;
            }
        }
    }
}

// ---------------------------------------------------------------- connector side

fn peerConnectorRun(index: usize) void {
    const peer = &fed_peers[index];

    var backoff_ms: u64 = 500;
    var announced_failure = false;

    while (!qnnt.isShuttingDown()) {
        _ = peer.attempts.fetchAdd(1, .monotonic);

        // One connection, many exchanges. Reconnecting per round would put a connect and
        // a TIME_WAIT socket on every change, which is exactly the churn that once left
        // the registry port unbindable.
        if (serveePeer(peer, &announced_failure)) |_| {
            backoff_ms = 500;
        } else |err| {
            peer.connected.store(false, .monotonic);
            if (!announced_failure) {
                std.debug.print("federation: {s}:{d} unreachable ({}); retrying\n", .{
                    peer.hostText(), peer.port, err,
                });
                announced_failure = true;
            }
            if (!qnnt.sleepMsInterruptible(backoff_ms)) return;
            backoff_ms = @min(backoff_ms * 2, 30_000);
        }
    }
}

const SyncError = resolve.Error || error{
    ConnectFailed,
    ShuttingDown,
    NoNonce,
    AuthRejected,
    HelloFailed,
    PushRejected,
    SyncFailed,
};

// Connect, authenticate, then exchange until the connection breaks or we are asked to
// stop. Returns an error naming the step that failed, which is what the caller logs.
fn serveePeer(peer: *Peer, announced_failure: *bool) SyncError!void {
    // Resolved per attempt, not once at configuration time, so a peer that moves is
    // followed. This blocks the connector thread for as long as the system resolver takes.
    const addr = try resolve.resolve(peer.hostText(), peer.port);
    var conn = addr.connect(qnnt.io, .{ .mode = .stream }) catch return error.ConnectFailed;
    defer conn.close(qnnt.io);

    if (!qnnt.trackSocket(conn.socket, .stream)) return error.ShuttingDown;
    defer qnnt.untrackSocket(conn.socket);

    var rbuf: [8192]u8 = undefined;
    var reader = conn.reader(qnnt.io, &rbuf);
    var writer = conn.writer(qnnt.io, &.{});

    // The address we dialed is the address that works for us, so it is what we attribute
    // this peer's own entries to when they decline to name a host.
    //
    // It has to be the RESOLVED address in numeric form, never the configured text: this
    // string is written into the directory as an entry's host and every node that reads it
    // back -- including nodes that never heard the name -- parses it as a literal. A
    // hostname here would make the peer's entries undialable everywhere.
    var observed_buf: [resolve.max_host_text]u8 = undefined;
    const observed = resolve.hostText(addr, &observed_buf);

    try authenticate(&reader.interface, &writer.interface);

    writer.interface.writeAll("fed-hello\n") catch return error.HelloFailed;
    _ = readFedLine(&reader.interface) orelse return error.HelloFailed;
    drainToTerminator(&reader.interface);

    // Announce a first connection and a recovery, but not every reconnect in a flapping
    // loop -- the failure side is already rate-limited the same way.
    if (announced_failure.* or peer.last_sync_us.load(.monotonic) == 0) {
        // Naming the resolved address too, when the peer was configured as a name: which
        // address a name landed on is the first thing worth knowing when a peer that
        // "should" be reachable is not.
        if (std.mem.eql(u8, observed, peer.hostText())) {
            std.debug.print("federation: synced with {s}:{d}\n", .{ peer.hostText(), peer.port });
        } else {
            std.debug.print("federation: synced with {s}:{d} ({s})\n", .{
                peer.hostText(), peer.port, observed,
            });
        }
        announced_failure.* = false;
    }

    while (!qnnt.isShuttingDown()) {
        // Read the change counter BEFORE exchanging, so a change arriving during the
        // exchange makes the wait below return at once rather than being slept through.
        const observed_seq = fed_change_seq.load(.monotonic);

        try exchangeWithPeer(peer, &reader.interface, &writer.interface, observed);

        peer.connected.store(true, .monotonic);
        peer.last_sync_us.store(@intCast(qnnt.nowMicrosFn()), .monotonic);

        // Wakes on the next local change, on the anti-entropy deadline, or on shutdown.
        if (!waitForChangeOrDeadline(observed_seq, fed_sync_interval_ms)) return;
    }
}

fn authenticate(reader: *Io.Reader, writer: *Io.Writer) SyncError!void {
    const nonce_line = readFedLine(reader) orelse return error.NoNonce;
    var it = std.mem.tokenizeAny(u8, nonce_line, " \t\r\n");
    if (!qnnt.eqlAny(it.next() orelse return error.NoNonce, &.{"fed-nonce"})) return error.NoNonce;
    const nonce_hex = it.next() orelse return error.NoNonce;

    var nonce: [16]u8 = undefined;
    if (nonce_hex.len != nonce.len * 2) return error.NoNonce;
    _ = std.fmt.hexToBytes(&nonce, nonce_hex) catch return error.NoNonce;

    var mac: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&mac, &nonce, cluster_key[0..cluster_key_len]);

    var line: [160]u8 = undefined;
    const auth = std.fmt.bufPrint(&line, "fed-auth {x}\n", .{mac}) catch return error.AuthRejected;
    writer.writeAll(auth) catch return error.AuthRejected;
    if (!expectOk(reader)) return error.AuthRejected;
}

// Push what we hold, then pull what they hold. Both directions every round, so neither
// side needs the pushes to have been delivered reliably.
fn exchangeWithPeer(
    peer: *Peer,
    reader: *Io.Reader,
    writer: *Io.Writer,
    observed: []const u8,
) SyncError!void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    writeFedEntries(&out) catch return error.PushRejected;

    var lines = std.mem.tokenizeScalar(u8, out.items, '\n');
    while (lines.next()) |entry_line| {
        writer.writeAll(entry_line) catch return error.PushRejected;
        writer.writeAll("\n") catch return error.PushRejected;
        if (!expectOk(reader)) return error.PushRejected;
    }

    writer.writeAll("fed-sync\n") catch return error.SyncFailed;
    var learned: u64 = 0;
    while (true) {
        const line = readFedLineRaw(reader) orelse return error.SyncFailed;
        if (std.mem.startsWith(u8, line, qnnt.comment_prefix)) {
            if (std.mem.startsWith(u8, line, "# end")) break;
            continue;
        }
        var it = std.mem.tokenizeAny(u8, line, " \t\r\n");
        if (!qnnt.eqlAny(it.next() orelse continue, &.{"fed-entry"})) continue;
        const entry = parseFedEntry(&it) orelse continue;
        if (applyRemoteEntry(entry, observed) catch false) learned += 1;
    }

    if (learned > 0) {
        _ = peer.learned.fetchAdd(learned, .monotonic);
        // Something new arrived, so the OTHER peers have not seen it either. Relaying is
        // what lets a partial peer list converge; it cannot loop, because a peer that
        // already holds this version rejects it and relays nothing further.
        notifyChange();
    }
}

// Reads the next line that is not commentary, so the '#' convention works the same way
// on the federation port as it does for a human on the registry port.
fn readFedLine(reader: *Io.Reader) ?[]const u8 {
    while (true) {
        const line = reader.takeDelimiterInclusive('\n') catch return null;
        if (!std.mem.startsWith(u8, line, qnnt.comment_prefix)) return line;
    }
}

fn readFedLineRaw(reader: *Io.Reader) ?[]const u8 {
    return reader.takeDelimiterInclusive('\n') catch null;
}

// Consumes through the reply terminator, so the next read starts on a reply boundary.
fn drainToTerminator(reader: *Io.Reader) void {
    while (true) {
        const line = reader.takeDelimiterInclusive('\n') catch return;
        if (std.mem.startsWith(u8, line, "# end")) return;
    }
}

fn expectOk(reader: *Io.Reader) bool {
    const line = readFedLine(reader) orelse return false;
    const ok = std.mem.startsWith(u8, line, "ok");
    drainToTerminator(reader);
    return ok;
}

// ---------------------------------------------------------------- expiry

// Remote entries age out; local ones keep the existing behaviour of going stale but still
// being served, because a local publisher going quiet is the local operator's business.
fn sweepRun() void {
    while (!qnnt.isShuttingDown()) {
        if (!qnnt.sleepMsInterruptible(1000)) return;

        const now_us: u64 = @intCast(qnnt.nowMicrosFn());

        qnnt.directory_mutex.lockUncancelable(qnnt.io);
        defer qnnt.directory_mutex.unlock(qnnt.io);

        var doomed: [64][]const u8 = undefined;
        var doomed_count: usize = 0;

        var it = qnnt.directory.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, &kv.value_ptr.origin, &qnnt.node_id)) continue;
            if (now_us -| kv.value_ptr.learned_us > fed_forget_after_us) {
                if (doomed_count < doomed.len) {
                    doomed[doomed_count] = kv.key_ptr.*;
                    doomed_count += 1;
                }
            }
        }

        // Removed after iterating: mutating a hash map mid-iteration invalidates it.
        for (doomed[0..doomed_count]) |key| {
            if (qnnt.directory.fetchRemove(key)) |kv| {
                var entry = kv.value;
                entry.peers.deinit(allocator);
                entry.pending.deinit(allocator);
                allocator.free(kv.key);
            }
        }
    }
}

/// True when a remote entry is too stale to hand out. Local entries are always served.
// Federation state, on the loopback interface only. Whether a peer is reachable, and how
// much it has taught us, is the first thing to look at when a topic fails to appear.
pub fn writePeerList(buffer: *std.ArrayList(u8)) !void {
    if (federation_port == 0) {
        try buffer.print(allocator, "# federation disabled (no port set)\n", .{});
        return;
    }
    if (peer_count == 0) {
        try buffer.print(allocator, "# listening on {d}, no peers configured to dial\n", .{federation_port});
        try buffer.print(allocator, "# {d} entr(ies) applied from peers that dialed us\n", .{
            inbound_applied.load(.monotonic),
        });
        return;
    }

    const now_us: u64 = @intCast(qnnt.nowMicrosFn());
    try buffer.print(allocator, "# peer                  state      last sync  learned  attempts\n", .{});

    for (fed_peers[0..peer_count]) |*peer| {
        var addr_buf: [64]u8 = undefined;
        const addr = std.fmt.bufPrint(&addr_buf, "{s}:{d}", .{ peer.hostText(), peer.port }) catch "?";

        const last = peer.last_sync_us.load(.monotonic);
        var age_buf: [16]u8 = undefined;
        const since = if (last == 0) "never" else qnnt.formatAge(&age_buf, now_us -| last);

        try buffer.appendSlice(allocator, "  ");
        try qnnt.writePadded(buffer, addr, 22);
        try buffer.appendSlice(allocator, "  ");
        try qnnt.writePadded(buffer, if (peer.connected.load(.monotonic)) "connected" else "down", 9);
        try buffer.appendSlice(allocator, "  ");
        try qnnt.writePadded(buffer, since, 9);
        try buffer.print(allocator, "  {d:>7}  {d:>8}\n", .{
            peer.learned.load(.monotonic),
            peer.attempts.load(.monotonic),
        });
    }

    // Counted apart from the per-peer figures above: in a mutual mesh most entries arrive
    // pushed by the other side, on a connection we did not initiate.
    try buffer.print(allocator, "# plus {d} entr(ies) applied from peers that dialed us\n", .{
        inbound_applied.load(.monotonic),
    });
}

/// The federation port in effect, or 0 when federation is off. For `status`.
pub fn currentPort() u16 {
    return federation_port;
}

/// Wakes every connector parked on the change futex. Called by  so shutdown
/// does not have to wait out an anti-entropy interval.
pub fn wakeForShutdown() void {
    qnnt.io.futexWake(u32, &fed_change_seq.raw, std.math.maxInt(u32));
}

pub fn entryIsServable(entry: *const TopicEntry, now_us: u64) bool {
    if (std.mem.eql(u8, &entry.origin, &qnnt.node_id)) return true;
    return now_us -| entry.learned_us <= fed_serve_until_us;
}

pub fn start() void {
    // Always says which way it went. Silence was the actual failure mode: with a key but
    // no port the previous version returned without a word, so federation neither ran nor
    // explained itself, and the only symptom was a port that never appeared.
    if (federation_port == 0) {
        std.debug.print("federation disabled (port explicitly set to 0)\n", .{});
        return;
    }

    if (cluster_key_len == 0) {
        std.debug.print(
            "federation disabled: no cluster key. Set one to enable it -- an " ++
                "unauthenticated directory on a network lets anyone redirect a topic's " ++
                "subscribers.\n",
            .{},
        );
        return;
    }

    std.debug.print("federation enabled: port {d}, {d} peer(s) to dial, binding {s}\n", .{
        federation_port,
        peer_count,
        qnnt.bindText(),
    });

    if (!qnnt.spawnWorker(listenerRun, .{})) {
        std.debug.print("failed to start the federation listener\n", .{});
        return;
    }
    if (!qnnt.spawnWorker(sweepRun, .{})) {
        std.debug.print("failed to start the federation sweeper\n", .{});
    }
    for (0..peer_count) |i| {
        if (!qnnt.spawnWorker(peerConnectorRun, .{i})) {
            std.debug.print("failed to start connector for peer {d}\n", .{i});
        }
    }
}


// -- tests ------------------------------------------------------------------------------

const testing = std.testing;

test "first-wins holds against a live rival, yields to a stale one" {
    const Q = @import("qnnt.zig").Qnnt;

    try testing.expect(Q.setRegistryPort(22304));
    try testing.expect(Q.run());
    defer Q.deinit();

    const origin_a: NodeId = @splat(0xAA);
    const origin_b: NodeId = @splat(0xBB);
    const topic = "test/takeover";

    const from_a: RemoteEntry = .{
        .origin = origin_a, .version = 1, .topic = topic,
        .host = "10.0.0.8", .port = 9001, .subs = 0,
    };
    const from_b: RemoteEntry = .{
        .origin = origin_b, .version = 1, .topic = topic,
        .host = "10.0.0.9", .port = 9002, .subs = 0,
    };

    // A claims it first.
    try testing.expect(try applyRemoteEntry(from_a, "10.0.0.8"));

    // B loses while A's entry is still being refreshed: two live claimants, first wins.
    try testing.expect(!try applyRemoteEntry(from_b, "10.0.0.9"));
    try testing.expectEqual(@as(u16, 9001), heldPort(topic));

    // Rewind A's lease past the serve window, which is what a node that has gone away
    // looks like from here. No sleeping: the condition is a timestamp, so move it.
    {
        qnnt.directory_mutex.lockUncancelable(qnnt.io);
        defer qnnt.directory_mutex.unlock(qnnt.io);
        const held = qnnt.directory.getPtr(topic).?;
        held.learned_us -= fed_serve_until_us + 1;
    }

    // Same announcement from B, and now it takes over: A is no longer a rival.
    try testing.expect(try applyRemoteEntry(from_b, "10.0.0.9"));
    try testing.expectEqual(@as(u16, 9002), heldPort(topic));

    qnnt.directory_mutex.lockUncancelable(qnnt.io);
    defer qnnt.directory_mutex.unlock(qnnt.io);
    try testing.expectEqualSlices(u8, &origin_b, &qnnt.directory.getPtr(topic).?.origin);
}

fn heldPort(topic: []const u8) u16 {
    qnnt.directory_mutex.lockUncancelable(qnnt.io);
    defer qnnt.directory_mutex.unlock(qnnt.io);
    return qnnt.directory.getPtr(topic).?.endpoint.getPort();
}
