//! Turning a peer's text into an address to dial.
//!
//! Zig's standard library parses address literals but ships no DNS client, so a name like
//! `nodeb.local` has to go through libc's `getaddrinfo`. That is a deliberate dependency
//! rather than an incidental one: the whole library already requires libc (see the note in
//! build.zig), and `getaddrinfo` is what respects the host's own configuration -- /etc/hosts,
//! resolv.conf, mDNS via nsswitch, search domains, and the RFC 6724 ordering that decides
//! whether a dual-stack name is reached over v6 or v4.
//!
//! Two properties matter to the caller:
//!
//!   * Literals never reach the resolver. That keeps the common case syscall-free and keeps
//!     a libc-less build working for anyone who only ever uses numeric peers.
//!   * `getaddrinfo` blocks the calling thread, outside the Io abstraction, for as long as
//!     the system resolver takes -- seconds, against a black-holed DNS server. Call it from
//!     a thread that can afford to wait, and expect shutdown to be delayed by up to that
//!     long if a resolve is in flight when the stop arrives.

const std = @import("std");
const builtin = @import("builtin");
const net = std.Io.net;

pub const Error = error{
    /// Not an address literal, and the resolver says no such name.
    UnknownHost,
    /// Resolution failed in a way that may work later: no DNS server reachable, a
    /// timeout, or a transient system failure. Worth retrying.
    TemporaryResolveFailure,
    /// A name was given, but this build has no libc and so no resolver at all.
    NoResolver,
    /// Longer than any legal hostname.
    HostTooLong,
};

/// Longest name `getaddrinfo` will accept.
pub const max_host_len = 255;

/// Text long enough for any address `hostText` can produce: 45 characters for an
/// IPv4-mapped IPv6 address, plus room to spare.
pub const max_host_text = 46;

/// Resolve `host` -- an IPv4 or IPv6 literal, or a hostname -- to an address on `port`.
///
/// Resolving per dial attempt rather than once at configuration time is intentional: a
/// peer that moves, or a name that starts out unresolvable because the network is not up
/// yet, then works on the next attempt without a restart.
pub fn resolve(host: []const u8, port: u16) Error!net.IpAddress {
    // "[::1]" is what anyone copying an address out of a URL will write, and std's parser
    // wants it bare. Strip the brackets rather than making every caller do it.
    const text = if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']')
        host[1 .. host.len - 1]
    else
        host;

    if (net.IpAddress.parse(text, port)) |addr| return addr else |_| {}

    if (!builtin.link_libc) return error.NoResolver;
    if (text.len == 0 or text.len > max_host_len) return error.HostTooLong;

    var name: [max_host_len + 1]u8 = undefined;
    @memcpy(name[0..text.len], text);
    name[text.len] = 0;

    // AF_UNSPEC plus ADDRCONFIG: ask for whichever families this host is actually
    // configured to use, and take the first result. The resolver has already sorted them
    // by the system's own preference, and second-guessing that here would mean
    // reimplementing destination address selection.
    const hints: std.c.addrinfo = .{
        .flags = .{ .ADDRCONFIG = true },
        .family = std.c.AF.UNSPEC,
        .socktype = std.c.SOCK.STREAM,
        .protocol = 0,
        .addrlen = 0,
        .canonname = null,
        .addr = null,
        .next = null,
    };

    // The port is applied afterwards instead of being passed as a service string, so no
    // number needs formatting and /etc/services is never consulted.
    var list: ?*std.c.addrinfo = null;
    const rc = std.c.getaddrinfo(name[0..text.len :0].ptr, null, &hints, &list);
    if (@intFromEnum(rc) != 0) return switch (rc) {
        // Transient: a retry may well succeed.
        .AGAIN, .MEMORY, .SYSTEM => error.TemporaryResolveFailure,
        // Everything else -- no such name, no address of a usable family, a
        // non-recoverable resolver failure -- reads the same to the caller.
        else => error.UnknownHost,
    };
    // Only free on success: on failure Linux leaves `list` untouched, and freeing an
    // undefined pointer there crashes.
    defer if (list) |l| std.c.freeaddrinfo(l);

    var it = list;
    while (it) |info| : (it = info.next) {
        const sa = info.addr orelse continue;
        var addr = switch (sa.family) {
            std.c.AF.INET => net.IpAddress{
                .ip4 = .{
                    // sockaddr.in holds the address as a u32 already in network order,
                    // so reinterpreting its bytes gives the big-endian [4]u8 wanted here
                    // -- on either host endianness, since @bitCast reinterprets memory.
                    .bytes = @bitCast(@as(*const std.c.sockaddr.in, @ptrCast(@alignCast(sa))).addr),
                    .port = port,
                },
            },
            std.c.AF.INET6 => net.IpAddress{
                .ip6 = .{
                    .bytes = @as(*const std.c.sockaddr.in6, @ptrCast(@alignCast(sa))).addr,
                    .port = port,
                },
            },
            else => continue,
        };
        addr.setPort(port);
        return addr;
    }

    // A successful lookup that yielded nothing we can dial is, to the caller, a name that
    // does not resolve to a usable address.
    return error.UnknownHost;
}

/// Format just the host part of `addr` -- no port, and no brackets around an IPv6 address
/// -- into `buf`, which must hold `max_host_text` bytes.
///
/// This is the inverse of what `resolve` accepts, and it is needed because a resolved peer
/// address has to be written back out as text: federation attributes a peer's entries to
/// the address it was reached on, and every node that later reads that text parses it as a
/// literal. A hostname there would make the entry undialable for everyone.
pub fn hostText(addr: net.IpAddress, buf: []u8) []const u8 {
    return switch (addr) {
        .ip4 => |ip4| std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{
            ip4.bytes[0], ip4.bytes[1], ip4.bytes[2], ip4.bytes[3],
        }) catch "?",
        .ip6 => |ip6| blk: {
            const bare: net.Ip6Address.Unresolved = .{ .bytes = ip6.bytes, .interface_name = null };
            break :blk std.fmt.bufPrint(buf, "{f}", .{&bare}) catch "?";
        },
    };
}

// -- tests ------------------------------------------------------------------------------
//
// "localhost" is the only name that can be assumed resolvable on a build machine with no
// network, since it comes from /etc/hosts. Anything else would make the suite depend on
// DNS.

const testing = std.testing;

test "literals bypass the resolver" {
    const v4 = try resolve("10.0.0.8", 2223);
    try testing.expect(v4 == .ip4);
    try testing.expectEqualSlices(u8, &.{ 10, 0, 0, 8 }, &v4.ip4.bytes);
    try testing.expectEqual(@as(u16, 2223), v4.ip4.port);

    const v6 = try resolve("::1", 2223);
    try testing.expect(v6 == .ip6);
    try testing.expectEqual(@as(u16, 2223), v6.ip6.port);
}

test "localhost resolves and carries the port" {
    const addr = try resolve("localhost", 2223);
    switch (addr) {
        .ip4 => |ip4| {
            try testing.expectEqual(@as(u16, 2223), ip4.port);
            try testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &ip4.bytes);
        },
        .ip6 => |ip6| {
            try testing.expectEqual(@as(u16, 2223), ip6.port);
            try testing.expect(ip6.isLoopBack());
        },
    }
}

test "a name that cannot resolve is reported, not hung on" {
    // .invalid is reserved by RFC 2606 precisely so it can never resolve.
    const err = resolve("qnnt-no-such-host.invalid", 2223);
    try testing.expect(err == error.UnknownHost or err == error.TemporaryResolveFailure);
}

test "hostText round-trips through resolve" {
    var buf: [max_host_text]u8 = undefined;

    for ([_][]const u8{ "10.0.0.8", "127.0.0.1", "::1", "fe80::1", "2001:db8::dead:beef" }) |text| {
        const addr = try resolve(text, 2223);
        const back = hostText(addr, &buf);
        const reparsed = try resolve(back, 2223);
        try testing.expect(addr.eql(&reparsed));
    }
}

test "hostText omits the port and the v6 brackets" {
    var buf: [max_host_text]u8 = undefined;
    try testing.expectEqualStrings("10.0.0.8", hostText(try resolve("10.0.0.8", 2223), &buf));
    try testing.expectEqualStrings("::1", hostText(try resolve("::1", 2223), &buf));
}

test "an over-long name is rejected before libc sees it" {
    const long = "a" ** (max_host_len + 1);
    try testing.expectError(error.HostTooLong, resolve(long, 2223));
    try testing.expectError(error.HostTooLong, resolve("", 2223));
}

test "the bracketed form is accepted" {
    const bracketed = try resolve("[::1]", 2223);
    const bare = try resolve("::1", 2223);
    try testing.expect(bracketed.eql(&bare));

    var buf: [max_host_text]u8 = undefined;
    // ...and comes back out bare, since that is what everything downstream parses.
    try testing.expectEqualStrings("::1", hostText(bracketed, &buf));
}
