//! Configuration from the process environment, in one place.
//!
//! This lives in the library rather than in each program because the alternative was four
//! separate implementations — Zig, C, C++ and Python — of the same parsing, which drifted
//! immediately: the Zig demo nodes read nothing at all, and nobody noticed until
//! federation began reporting its own state and every Zig node announced "no cluster key"
//! regardless of the environment.
//!
//! It is an explicit call, not something `run()` does. A library that silently reconfigures
//! itself from process-wide state surprises anything that embeds it — the same reason
//! signal handlers are opt-in here. A program that wants environment configuration says so
//! in one line; a program that does not is unaffected.
//!
//! Variables, all optional:
//!
//!   QNNT_REGISTRY_PORT     the host-local registry port (default 2222)
//!   QNNT_ADVERTISE_ADDR    the address remote subscribers should dial
//!   QNNT_BIND_ADDR         what publisher sockets bind
//!   QNNT_CLUSTER_KEY       enables federation; required for it
//!   QNNT_FEDERATION_PORT   federation's port (default 2223, 0 disables)
//!   QNNT_PEERS             host[:port],... to dial; host may be an address or a name
//!   QNNT_RT_PRIORITY       SCHED_FIFO priority for worker threads (Linux only)
//!   QNNT_LOCK_MEMORY       1 to pin pages with mlockall (Linux only)
//!   QNNT_MAX_FRAME_BYTES   largest TLD frame published or accepted (default 16 MiB)

const std = @import("std");
const builtin = @import("builtin");
const qnnt = @import("qnnt.zig");
const federation = @import("federation.zig");

/// Look up a variable, treating an empty value as absent.
///
/// `export QNNT_CLUSTER_KEY` with no value is a plausible thing to type, and it should mean
/// "unset" rather than "set to the empty string" — the latter would be rejected as a
/// zero-length key and read as a configuration error.
fn get(name: [*:0]const u8) ?[]const u8 {
    if (!builtin.link_libc) return null;
    const value = std.c.getenv(name) orelse return null;
    const text = std.mem.span(value);
    return if (text.len == 0) null else text;
}

fn parsePort(text: []const u8) ?u16 {
    return std.fmt.parseInt(u16, text, 10) catch null;
}

/// Split a peer spec into host and port, where a port of 0 means "none given".
///
/// Splitting on the last colon is not enough on its own: a bare IPv6 literal is all
/// colons, and `fe80::1` would come apart into the host `fe80:` on port 1. The bracketed
/// form is the standard way to say where the address stops, so:
///
///   [fe80::1]:2223   bracketed, with a port
///   [fe80::1]        bracketed, no port
///   fe80::1          two or more colons and no brackets, so all address, no port
///   10.0.0.9:2223    one colon, so host and port
///   nodeb.local      no colon
fn splitHostPort(spec: []const u8) struct { host: []const u8, port: u16 } {
    if (spec.len != 0 and spec[0] == '[') {
        if (std.mem.indexOfScalar(u8, spec, ']')) |close| {
            const host = spec[1..close];
            const rest = spec[close + 1 ..];
            if (rest.len > 1 and rest[0] == ':') {
                if (parsePort(rest[1..])) |value| return .{ .host = host, .port = value };
            }
            return .{ .host = host, .port = 0 };
        }
    }

    const colons = std.mem.count(u8, spec, ":");
    if (colons == 1) {
        const colon = std.mem.indexOfScalar(u8, spec, ':').?;
        if (parsePort(spec[colon + 1 ..])) |value| return .{ .host = spec[0..colon], .port = value };
    }

    return .{ .host = spec, .port = 0 };
}

// A rejected setting is reported, never dropped in silence. Quietly discarding
// configuration is what made this class of problem invisible.
fn reject(name: []const u8, value: []const u8) void {
    std.debug.print("ignoring {s}={s}: not accepted\n", .{ name, value });
}

/// Apply everything the environment specifies. Call before `run()` — the setters refuse
/// once a node is running — and apply any explicit overrides afterwards.
///
/// Requires libc for `getenv`; without it this does nothing and says so, rather than
/// pretending to have read a configuration it could not see.
pub fn configureFromEnvironment() void {
    if (!builtin.link_libc) {
        // Loud, because the consequence is that NOTHING was configured: a node would come
        // up on its defaults with no cluster key and no peers, and the only symptom is a
        // port that never appears. Zig links no libc by default on Linux, so this is a
        // platform difference, not a rare edge case.
        std.debug.print(
            "qnnt: configureFromEnvironment() did nothing -- this binary is not linked " ++
                "against libc, so getenv is unavailable and EVERY QNNT_* variable was " ++
                "ignored. Build with libc (link_libc = true) or configure explicitly.\n",
            .{},
        );
        return;
    }

    if (get("QNNT_MAX_FRAME_BYTES")) |text| {
        if (std.fmt.parseInt(usize, text, 10)) |value| {
            // Both ends of THIS node. Two nodes on a topic are two settings, so a producer
            // raising its own does not raise its consumers' -- which is worth knowing before
            // wondering why a bigger frame still gets refused.
            if (!qnnt.setMaxFrameBytesFn(value)) reject("QNNT_MAX_FRAME_BYTES", text);
        } else |_| reject("QNNT_MAX_FRAME_BYTES", text);
    }

    if (get("QNNT_REGISTRY_PORT")) |text| {
        if (parsePort(text)) |value| {
            if (!qnnt.setRegistryPortFn(value)) reject("QNNT_REGISTRY_PORT", text);
        } else reject("QNNT_REGISTRY_PORT", text);
    }

    if (get("QNNT_ADVERTISE_ADDR")) |text| {
        if (!qnnt.setAdvertiseAddressFn(text)) reject("QNNT_ADVERTISE_ADDR", text);
    }

    if (get("QNNT_BIND_ADDR")) |text| {
        if (!qnnt.setBindAddressFn(text)) reject("QNNT_BIND_ADDR", text);
    }

    if (get("QNNT_FEDERATION_PORT")) |text| {
        if (parsePort(text)) |value| {
            if (!federation.setPort(value)) reject("QNNT_FEDERATION_PORT", text);
        } else reject("QNNT_FEDERATION_PORT", text);
    }

    if (get("QNNT_CLUSTER_KEY")) |text| {
        // The value itself is never echoed, rejected or not: it is a secret.
        if (!federation.setClusterKey(text)) reject("QNNT_CLUSTER_KEY", "<value withheld>");
    }

    if (get("QNNT_RT_PRIORITY")) |text| {
        if (std.fmt.parseInt(u8, text, 10)) |value| {
            if (!qnnt.Qnnt.setRealtimePriority(value)) reject("QNNT_RT_PRIORITY", text);
        } else |_| reject("QNNT_RT_PRIORITY", text);
    }

    if (get("QNNT_LOCK_MEMORY")) |text| {
        // Anything that plainly means "on"; anything else is a mistake worth naming rather
        // than quietly reading as off.
        if (qnnt.eqlAny(text, &.{ "1", "yes", "true", "on" })) {
            if (!qnnt.Qnnt.setLockMemory(true)) reject("QNNT_LOCK_MEMORY", text);
        } else if (qnnt.eqlAny(text, &.{ "0", "no", "false", "off" })) {
            _ = qnnt.Qnnt.setLockMemory(false);
        } else reject("QNNT_LOCK_MEMORY", text);
    }

    if (get("QNNT_PEERS")) |list| {
        var specs = std.mem.tokenizeScalar(u8, list, ',');
        while (specs.next()) |spec| {
            const trimmed = std.mem.trim(u8, spec, " \t");
            if (trimmed.len == 0) continue;

            const split = splitHostPort(trimmed);
            // A port of 0 means "use the federation port".
            if (!federation.addPeer(split.host, split.port)) reject("QNNT_PEERS", trimmed);
        }
    }
}

// -- tests ------------------------------------------------------------------------------

const testing = std.testing;

test "splitHostPort understands v4, v6 and names" {
    const cases = [_]struct { spec: []const u8, host: []const u8, port: u16 }{
        .{ .spec = "10.0.0.9:2223", .host = "10.0.0.9", .port = 2223 },
        .{ .spec = "10.0.0.9", .host = "10.0.0.9", .port = 0 },
        .{ .spec = "nodeb.local:2223", .host = "nodeb.local", .port = 2223 },
        .{ .spec = "nodeb.local", .host = "nodeb.local", .port = 0 },
        // The case the old last-colon split got wrong: no brackets, so it is all address.
        .{ .spec = "fe80::1", .host = "fe80::1", .port = 0 },
        .{ .spec = "::1", .host = "::1", .port = 0 },
        .{ .spec = "[fe80::1]:2223", .host = "fe80::1", .port = 2223 },
        .{ .spec = "[fe80::1]", .host = "fe80::1", .port = 0 },
        // A port that is not a number is not a port; the whole spec stays the host, and
        // fails later as an unresolvable name rather than being silently truncated.
        .{ .spec = "nodeb.local:http", .host = "nodeb.local:http", .port = 0 },
    };

    for (cases) |c| {
        const got = splitHostPort(c.spec);
        try testing.expectEqualStrings(c.host, got.host);
        try testing.expectEqual(c.port, got.port);
    }
}
