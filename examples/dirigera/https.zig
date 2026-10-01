//! HTTPS to the hub, with certificate verification that actually verifies something.
//!
//! The DIRIGERA hub serves its API over TLS on port 8443, and the obvious thing -- what
//! nearly every published DIRIGERA client does, and what the probing scripts for this
//! example did -- is to turn verification off, because the certificate is not signed by
//! anyone a system trust store knows. That is not necessary here. The hub presents its
//! WHOLE chain, four certificates deep, ending in a self-signed root:
//!
//!   0  CN=DIRIGERA HUB FOR SMART PRODUCTS<serial>   issued by ...
//!   1  CN=IKEA HOME SMART DEVICE TRUST               (STMicroelectronics)
//!   2  CN=IKEA Home smart Device Trust CA
//!   3  CN=IKEA Home smart Root CA                    self-signed, valid to 2071
//!
//! So certificate 3 is embedded in this binary as `ikea_root_ca.der` and used as the trust
//! anchor. The connection is then cryptographically verified to terminate at a device whose
//! certificate IKEA issued -- which is a real guarantee, and strictly better than the
//! nothing that `curl -k` provides.
//!
//! What is NOT verified is the hostname, and that part is unavoidable: the leaf carries no
//! subjectAltName at all, and its CN is a device serial rather than a name or an address.
//! No TLS implementation can match `192.168.75.254` against that, so `host` is
//! `.no_verification` while `ca` remains a real bundle. The comment matters because
//! `.no_verification` looks alarming in isolation; it is the hostname check that is off,
//! not the chain.
//!
//! Everything transport-generic -- the connect deadline, the chunked response decoder --
//! comes from examples/net/wire.zig, shared with the UGV example.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Certificate = std.crypto.Certificate;
const wire = @import("wire");
/// TLS itself, through OpenSSL. See that file's header for why std's client cannot be used
/// against this hub.
const tls = @import("tls_openssl");

pub const Error = wire.Error || tls.Error || error{
    /// A path or authority did not fit its buffer.
    NameTooLong,
};

/// IKEA's self-signed root, the trust anchor for every hub they have shipped. Embedded
/// rather than read at runtime so the bridge has no file dependency, and as DER rather than
/// PEM so it needs no base64 step.
///
///   subject: C=SE, O=IKEA of Sweden AB, CN=IKEA Home smart Root CA
///   sha256:  2B:EE:E1:72:64:C7:97:23:CD:BA:13:6D:18:6E:91:5F:
///            11:5B:B1:FA:06:A1:41:50:C8:55:FD:16:70:D0:FA:AC
pub const root_ca_der = @embedFile("ikea_root_ca.der");

/// One connection's buffer size. Generous because a `/v1/devices` response is ~17 KB and
/// arrives in one read where possible.
const buffer_len = 32 * 1024;

/// Bounds a REST call. The event stream sets its own, much longer, because waiting is what
/// it is for.
pub const default_timeout_ms = 5000;

pub const Connection = tls.Connection;

pub const Client = struct {
    io: Io,
    allocator: Allocator,
    context: tls.Context,
    timeout_ms: u32 = default_timeout_ms,
    /// The raw response, headers and chunk framing included. Reused across calls.
    raw: std.ArrayList(u8),

    pub fn init(io: Io, allocator: Allocator) !Client {
        return .{
            .io = io,
            .allocator = allocator,
            // Only IKEA's root is trusted -- not the system store. See the file header.
            .context = try tls.Context.init(root_ca_der),
            .raw = .empty,
        };
    }

    pub fn deinit(c: *Client) void {
        c.context.deinit();
        c.raw.deinit(c.allocator);
    }

    /// A TLS connection the caller keeps -- for the WebSocket, which stays open. Its read
    /// timeout is separate because an idle event stream is normal, while an idle REST call
    /// is a fault.
    pub fn connect(c: *Client, authority: []const u8, read_timeout_ms: u32) !*Connection {
        const address = wire.parseAuthority(authority) catch return error.Rejected;
        return tls.Connection.open(
            c.io,
            c.allocator,
            c.context,
            address,
            c.timeout_ms,
            read_timeout_ms,
            buffer_len,
        );
    }

    /// One request, one connection. The hub answers `Connection: close`, so there is
    /// nothing to pool; and the REST calls here are occasional (an inventory refresh, a
    /// light command) rather than a stream.
    ///
    /// A non-2xx is `error.Rejected`. Pairing needs to read the body of a 4xx instead, so
    /// it calls `requestTyped` directly.
    pub fn request(
        c: *Client,
        authority: []const u8,
        method: []const u8,
        path: []const u8,
        token: ?[]const u8,
        body: ?[]const u8,
        out: *std.ArrayList(u8),
    ) !void {
        const status = try c.requestTyped(
            authority,
            method,
            path,
            token,
            "application/json",
            body,
            out,
        );
        if (status < 200 or status > 299) return error.Rejected;
    }

    /// As `request`, but the caller names the body's media type and receives the status
    /// rather than an error for a non-2xx.
    ///
    /// Both exist for the pairing exchange: its token endpoint is form-encoded rather than
    /// JSON, and it answers 4xx with a body that says whether to keep waiting for the
    /// operator's button press or to start a fresh pairing window.
    pub fn requestTyped(
        c: *Client,
        authority: []const u8,
        method: []const u8,
        path: []const u8,
        token: ?[]const u8,
        content_type: []const u8,
        body: ?[]const u8,
        out: *std.ArrayList(u8),
    ) !u16 {
        const connection = try c.connect(authority, c.timeout_ms);
        defer connection.close();

        const w = connection.writer();
        w.print("{s} {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n", .{
            method, path, authority,
        }) catch return error.Rejected;
        if (token) |bearer| {
            w.print("Authorization: Bearer {s}\r\n", .{bearer}) catch return error.Rejected;
        }
        if (body) |payload| {
            w.print("Content-Type: {s}\r\nContent-Length: {d}\r\n\r\n{s}", .{
                content_type, payload.len, payload,
            }) catch return error.Rejected;
        } else {
            w.writeAll("\r\n") catch return error.Rejected;
        }
        w.flush() catch return error.Rejected;

        c.raw.clearRetainingCapacity();
        const r = connection.reader();
        while (true) {
            // Only end-of-stream ends the body -- the hub answers `Connection: close`, so
            // that is the normal termination. A read FAILURE is different and must not be
            // mistaken for a complete response: treating the two alike turned a transport
            // fault into a silent empty body.
            const chunk = r.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => break,
                else => {
                    std.debug.print("dirigera https: read failed ({t})\n", .{err});
                    return error.Rejected;
                },
            };
            c.raw.appendSlice(c.allocator, chunk) catch return error.Rejected;
            r.toss(chunk.len);
            if (c.raw.items.len > wire.max_response_bytes) return error.Rejected;
        }

        return wire.decodeResponseStatus(c.raw.items, out, c.allocator);
    }
};

// -- tests ----------------------------------------------------------------------------

const testing = std.testing;

test "the embedded root is the self-signed IKEA anchor, not a leaf" {
    // A chain can only be verified against a root. If someone replaced this file with the
    // hub's leaf certificate -- the easy mistake, since that is what `openssl s_client`
    // prints first -- verification would fail for every hub but this one.
    const cert: Certificate = .{ .buffer = root_ca_der, .index = 0 };
    const parsed = try cert.parse();
    try testing.expect(std.mem.indexOf(u8, parsed.subject(), "IKEA Home smart Root CA") != null);
    // Self-signed: the anchor is its own issuer.
    try testing.expectEqualStrings(parsed.subject(), parsed.issuer());
}

test "root_ca_der is DER, not accidentally PEM" {
    // PEM would start with "-----BEGIN"; DER starts with an ASN.1 SEQUENCE tag.
    try testing.expectEqual(@as(u8, 0x30), root_ca_der[0]);
    try testing.expect(!std.mem.startsWith(u8, root_ca_der, "-----"));
}

test "the embedded root is loadable as an OpenSSL trust anchor" {
    // Offline proof that the DER is not truncated or the wrong encoding: OpenSSL parses it
    // and accepts it into a store. Without this, a corrupt anchor would only show up as a
    // handshake failure against a live hub, which the test suite cannot reach.
    var context = try tls.Context.init(root_ca_der);
    defer context.deinit();
}
