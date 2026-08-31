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
//!   QNNT_PEERS             host[:port],host[:port],... to dial

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
        std.debug.print(
            "qnnt: configureFromEnvironment needs libc for getenv; configure explicitly\n",
            .{},
        );
        return;
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

    if (get("QNNT_PEERS")) |list| {
        var specs = std.mem.tokenizeScalar(u8, list, ',');
        while (specs.next()) |spec| {
            const trimmed = std.mem.trim(u8, spec, " \t");
            if (trimmed.len == 0) continue;

            // Split on the LAST colon, so an IPv6 literal is not cut at its first one.
            if (std.mem.lastIndexOfScalar(u8, trimmed, ':')) |colon| {
                if (parsePort(trimmed[colon + 1 ..])) |value| {
                    if (!federation.addPeer(trimmed[0..colon], value)) reject("QNNT_PEERS", trimmed);
                    continue;
                }
            }
            // No port given: 0 means "use the federation port".
            if (!federation.addPeer(trimmed, 0)) reject("QNNT_PEERS", trimmed);
        }
    }
}
