//! A CAN gateway: a local SocketCAN interface, joined to the same logical bus on every
//! other host in a qnnt mesh.
//!
//!   qnnt-can-gw --name alpha --bus powertrain=vcan0
//!   qnnt-can-gw --name bravo --bus powertrain=vcan0 --bus body=vcan1
//!
//! Each gateway publishes what it reads from a local interface on `can/<bus>/<name>`, and
//! subscribes to `can/<bus>/*` -- every gateway's view of the same logical bus. A frame put
//! on vcan0 at alpha appears on vcan0 at bravo, charlie and delta, and nowhere else.
//!
//! Several buses at once are several independent networks. `--bus powertrain=vcan0 --bus
//! body=vcan1` bridges both over one qnnt mesh and one federation link, and nothing crosses
//! between them, because a topic names its bus. That is the whole reason `<bus>` is a
//! LOGICAL name and not the interface name: the segment this host reaches on vcan0 may be
//! vcan1 on the next, and naming the wire after one host's cabling is how two unrelated
//! segments get spliced together.
//!
//! What makes this small is `subscribePattern`. The gateway never learns the names of its
//! peers, is never configured with a list of them, and needs no restart when one appears:
//! it subscribes to a shape, and gateways that join the mesh later are picked up because
//! their topics show up in the federated directory. Adding the fifth host is editing one
//! host's QNNT_PEERS, not editing five gateways.

const std = @import("std");
const root = @import("qnnt");
const qnnt = root.Qnnt;
const tld = root.Tld;
const frame = @import("frame");
const socketcan = @import("socketcan");

const allocator = std.heap.page_allocator;

/// How long a CAN read blocks before coming back empty so the loop can check for shutdown.
const read_timeout_ms = 200;

/// A gateway bridges few buses -- one or two is the norm, a handful the outside case. The
/// cap exists so the fixed array below needs no allocator on a path that must not fail.
const max_buses = 8;

var opt_name: []const u8 = "";
var opt_rescan_ms: u64 = 500;
var opt_stats_ms: u64 = 5000;
var opt_quiet = false;

const Bus = struct {
    /// The logical bus, as it appears in the topic.
    name: []const u8,
    /// The local interface it is reached on.
    iface: []const u8,
    sock: socketcan.Bus = undefined,

    /// `can/<name>/<gateway>`, what we publish. Owned, because the library keeps a topic
    /// string for the life of the publisher.
    topic: []const u8 = "",
    /// `can/<name>/*`, what we subscribe to.
    pattern: []const u8 = "",

    read_frames: std.atomic.Value(u64) = .init(0),
    published: std.atomic.Value(u64) = .init(0),
    /// Frames from other gateways, written to the local interface.
    injected: std.atomic.Value(u64) = .init(0),
    /// Frames we declined to write: error frames, and anything malformed.
    refused: std.atomic.Value(u64) = .init(0),
    /// Local writes the kernel would not take -- almost always a full transmit queue.
    write_failed: std.atomic.Value(u64) = .init(0),
    /// Deliveries on our own topic, which the pattern matches by design.
    own: std.atomic.Value(u64) = .init(0),
};

var buses: [max_buses]Bus = undefined;
var bus_count: usize = 0;

// ---------------------------------------------------------------- local bus -> the mesh

/// One thread per bus, parked in a CAN read. There is no way to make this a poll across
/// several interfaces without giving up the per-bus counters and the per-bus error
/// reporting, and a gateway bridges a handful of buses, not a thousand.
fn readerLoop(bus: *Bus) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    // The payload the frame returned by `read` borrows. It lives as long as this loop, and
    // is finished with by the time the next read overwrites it: the frame is packed and
    // published before the loop comes round.
    var payload: [frame.max_data]u8 = undefined;

    while (!qnnt.stopRequested()) {
        const got = bus.sock.read(&payload) catch |err| {
            if (!opt_quiet) std.debug.print(
                "qnnt-can-gw: {s}: read failed ({t}), stopping this bus\n",
                .{ bus.iface, err },
            );
            return;
        };
        // Timed out: the loop's chance to notice a shutdown request.
        const f = got orelse continue;
        _ = bus.read_frames.fetchAdd(1, .monotonic);

        var stamped = f;
        stamped.us = qnnt.nowMicros();

        tld.packTo(allocator, &buf, stamped) catch continue;
        qnnt.publish(bus.topic, buf.items) catch continue;
        _ = bus.published.fetchAdd(1, .monotonic);
    }
}

// ---------------------------------------------------------------- the mesh -> local bus

/// Every gateway's frames for one bus, this gateway's included.
///
/// Skipping our own topic is the whole of the loop prevention at this level, and it is not
/// the only layer: SocketCAN does not loop a transmitted frame back to the socket that sent
/// it, so a frame this gateway injects is never read by its own reader and never
/// republished. Both are needed. Without the topic check a frame would be written straight
/// back to the bus it came from, duplicating every local message; without the socket
/// behaviour a frame from alpha would be injected at bravo, read back by bravo, republished
/// as bravo's, injected at alpha, and the mesh would saturate in under a second.
fn onFrame(topic: []const u8, f: tld.Frame, context: ?*anyopaque) void {
    const bus: *Bus = @ptrCast(@alignCast(context orelse return));

    const from = frame.nodeOf(topic) orelse return;
    if (std.mem.eql(u8, from, opt_name)) {
        _ = bus.own.fetchAdd(1, .monotonic);
        return;
    }

    // No allocator: the payload borrows the subscriber's buffer, which is valid for exactly
    // this call -- and this call writes it to the socket and returns.
    const decoded = tld.unpack(frame.Frame, f, null) catch {
        _ = bus.refused.fetchAdd(1, .monotonic);
        return;
    };

    if (!frame.writable(decoded)) {
        _ = bus.refused.fetchAdd(1, .monotonic);
        return;
    }

    bus.sock.write(decoded) catch {
        _ = bus.write_failed.fetchAdd(1, .monotonic);
        return;
    };
    _ = bus.injected.fetchAdd(1, .monotonic);
}

// ---------------------------------------------------------------- arguments

fn usage() void {
    std.debug.print(
        \\usage: qnnt-can-gw --name <gateway> --bus <bus>=<iface> [--bus <bus>=<iface>]...
        \\
        \\  --name <gateway>  this gateway's name, unique in the mesh. It is the last
        \\                    segment of every topic this gateway publishes, and what the
        \\                    other gateways use to tell its frames from their own.
        \\  --bus <bus>=<if>  bridge local interface <if> as logical bus <bus>. Repeatable:
        \\                    each bus is an independent network with its own topics, and
        \\                    nothing crosses between them.
        \\  --rescan <ms>     how often to look for gateways that have joined since
        \\                    (default 500). 0 looks once at startup and never again.
        \\  --stats <ms>      how often to print counters (default 5000, 0 to disable)
        \\  --quiet           no periodic counters
        \\
        \\Topics:
        \\  can/<bus>/<gateway>   frames <gateway> read from its local <bus>
        \\  can/<bus>/*           what each gateway subscribes to
        \\
        \\Watch the whole mesh, both buses, from anywhere on it:
        \\  qnnt-ls --tree
        \\  qnnt-cat 'can/powertrain/*'
        \\
        \\Federation is what carries this between hosts: set QNNT_CLUSTER_KEY on every
        \\gateway and QNNT_PEERS to the others. Without a key a gateway still works, but
        \\only joins gateways on its own machine.
        \\
    , .{});
}

/// `--bus powertrain=vcan0`.
fn addBus(spec: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, spec, '=') orelse {
        std.debug.print("qnnt-can-gw: --bus wants <bus>=<iface>, got '{s}'\n", .{spec});
        return false;
    };
    const name = spec[0..eq];
    const iface = spec[eq + 1 ..];

    if (!frame.validName(name)) {
        std.debug.print(
            "qnnt-can-gw: '{s}' is not a usable bus name (letters, digits, - _ . only) --\n" ++
                "  it becomes a topic segment, and a '/' or a '*' in it would make the\n" ++
                "  topic ambiguous or turn it into a glob\n",
            .{name},
        );
        return false;
    }
    if (iface.len == 0 or iface.len >= 16) {
        std.debug.print("qnnt-can-gw: '{s}' is not a usable interface name\n", .{iface});
        return false;
    }
    if (bus_count == max_buses) {
        std.debug.print("qnnt-can-gw: at most {d} buses\n", .{max_buses});
        return false;
    }
    for (buses[0..bus_count]) |b| {
        if (std.mem.eql(u8, b.name, name)) {
            std.debug.print("qnnt-can-gw: bus '{s}' given twice\n", .{name});
            return false;
        }
        // Two logical buses on one interface would each read the other's frames back and
        // republish them under a second name: the same loop the socket rule prevents
        // between hosts, reintroduced locally.
        if (std.mem.eql(u8, b.iface, iface)) {
            std.debug.print(
                "qnnt-can-gw: {s} is already bridged as bus '{s}'. One interface per bus:\n" ++
                    "  two buses on one interface would each republish the other's frames.\n",
                .{ iface, b.name },
            );
            return false;
        }
    }

    buses[bus_count] = .{ .name = name, .iface = iface };
    bus_count += 1;
    return true;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--name")) {
            opt_name = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--bus")) {
            if (!addBus(args.next() orelse return usage())) return;
        } else if (std.mem.eql(u8, arg, "--rescan")) {
            opt_rescan_ms = std.fmt.parseInt(u64, args.next() orelse return usage(), 10) catch
                return usage();
        } else if (std.mem.eql(u8, arg, "--stats")) {
            opt_stats_ms = std.fmt.parseInt(u64, args.next() orelse return usage(), 10) catch
                return usage();
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            opt_quiet = true;
        } else {
            return usage();
        }
    }

    if (bus_count == 0 or opt_name.len == 0) return usage();
    if (!frame.validName(opt_name)) {
        std.debug.print(
            "qnnt-can-gw: '{s}' is not a usable gateway name (letters, digits, - _ . only)\n",
            .{opt_name},
        );
        return;
    }

    // The interfaces first, before starting a node: a gateway that cannot reach its bus is
    // not a gateway, and half-registering its topics would let peers subscribe to a topic
    // that will never carry anything.
    for (buses[0..bus_count]) |*bus| {
        bus.sock = socketcan.Bus.open(bus.iface, read_timeout_ms) catch |err| {
            std.debug.print("qnnt-can-gw: cannot bridge bus '{s}'\n", .{bus.name});
            socketcan.explain(err, bus.iface);
            return;
        };
    }
    defer for (buses[0..bus_count]) |*bus| bus.sock.close();

    qnnt.configureFromEnvironment();
    if (!qnnt.run()) {
        std.debug.print("qnnt-can-gw: failed to start\n", .{});
        return;
    }
    defer qnnt.deinit();
    qnnt.installSignalHandlers();

    for (buses[0..bus_count]) |*bus| {
        var tbuf: [160]u8 = undefined;
        var pbuf: [160]u8 = undefined;
        bus.topic = try allocator.dupe(u8, try frame.topicFor(&tbuf, bus.name, opt_name));
        bus.pattern = try allocator.dupe(u8, try frame.patternFor(&pbuf, bus.name));

        // The publisher before the subscription, so a peer that resolves our topic finds a
        // publisher rather than an entry that is not yet listening.
        if (!qnnt.runPublisher(bus.topic, null, null, null)) {
            std.debug.print("qnnt-can-gw: could not publish {s}\n", .{bus.topic});
            return;
        }
        // Frames, not text: a CAN payload contains 0x0A as freely as any other byte, and a
        // newline-delimited subscription would split and rejoin frames into garbage.
        if (!qnnt.subscribePatternFrames(bus.pattern, onFrame, bus, opt_rescan_ms)) {
            std.debug.print("qnnt-can-gw: could not subscribe to {s}\n", .{bus.pattern});
            return;
        }
    }

    std.debug.print("qnnt-can-gw: gateway '{s}'\n", .{opt_name});
    for (buses[0..bus_count]) |*bus| {
        std.debug.print("  {s: <12} {s: <8} publishes {s}, joins {s}\n",
            .{ bus.name, bus.iface, bus.topic, bus.pattern });
    }

    var threads: [max_buses]std.Thread = undefined;
    for (buses[0..bus_count], 0..) |*bus, i| {
        threads[i] = try std.Thread.spawn(.{}, readerLoop, .{bus});
    }

    var last_stats_us = qnnt.nowMicros();
    while (!qnnt.stopRequested()) {
        _ = qnnt.sleepMs(100);
        if (opt_quiet or opt_stats_ms == 0) continue;

        const now = qnnt.nowMicros();
        if (now -| last_stats_us < @as(i64, @intCast(opt_stats_ms)) * 1000) continue;
        last_stats_us = now;

        for (buses[0..bus_count]) |*bus| {
            std.debug.print(
                "qnnt-can-gw: {s: <12} read {d} published {d} injected {d} " ++
                    "refused {d} write-failed {d} own {d}\n",
                .{
                    bus.name,
                    bus.read_frames.load(.monotonic),
                    bus.published.load(.monotonic),
                    bus.injected.load(.monotonic),
                    bus.refused.load(.monotonic),
                    bus.write_failed.load(.monotonic),
                    bus.own.load(.monotonic),
                },
            );
        }
    }

    for (threads[0..bus_count]) |t| t.join();
}
