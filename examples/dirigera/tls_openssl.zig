//! TLS to the hub, through OpenSSL, exposed as an `Io.Reader` and an `Io.Writer`.
//!
//! WHY THIS EXISTS, because a dependency in a repository that has none needs a reason.
//!
//! Zig 0.16's `std.crypto.tls.Client` cannot complete a handshake with a DIRIGERA hub, and
//! the gap is narrow and specific:
//!
//!   * The hub speaks TLS 1.2 only. Forcing 1.3 returns alert 70, protocol_version.
//!   * Its certificate is ECDSA, and it accepts only `ECDHE-ECDSA-*` cipher suites.
//!   * For TLS 1.2, std offers only `ECDHE_RSA_*`. The `ECDHE_ECDSA_*` constants are
//!     defined in `std.crypto.tls.CipherSuite` and never offered, and the offer list is a
//!     private comptime constant with no way to override it.
//!
//! There is no overlap, so the hub replies with a handshake failure. Everything else in std
//! is present -- ECDSA signature verification is implemented and advertised -- which makes
//! this one list the whole obstacle. The alternative was vendoring 1700 lines of the
//! standard library to change three enum entries; this is smaller and stays correct as
//! OpenSSL is maintained.
//!
//! WHAT IS AND IS NOT VERIFIED. The chain is verified, against the IKEA root embedded in
//! https.zig, by `SSL_VERIFY_PEER` plus an explicit `SSL_get_verify_result` check. The
//! hostname is not, and cannot be: the hub's leaf carries no subjectAltName and its CN is a
//! device serial, so there is nothing to match an address against. `SSL_set1_host` is
//! therefore deliberately never called -- OpenSSL only checks the name if asked, so simply
//! not asking gives chain verification without name verification, which is precisely the
//! distinction wanted here.
//!
//! One bonus over the std path: because reads go through `SSL_read` rather than
//! `Io.Threaded`, `SO_RCVTIMEO` is usable. `Io.Threaded` treats `EAGAIN` as a programmer bug
//! and panics on it, which is what made socket timeouts unusable in examples/ugv/; here the
//! timeout surfaces as a return value this code handles itself.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const wire = @import("wire");

pub const Error = error{
    /// The library would not initialise, or a connection could not be created.
    TlsSetup,
    /// The handshake failed, or the chain did not verify against the embedded root.
    TlsFailed,
    /// The peer went away mid-connection.
    TlsClosed,
};

// -- the parts of OpenSSL used here ------------------------------------------------------
//
// Declared rather than translated: `@cImport` would pull the whole of `ssl.h` in, and this
// needs eleven functions. Anything spelled as a macro in the headers is avoided.

const SSL_CTX = opaque {};
const SSL = opaque {};
const X509 = opaque {};
const X509_STORE = opaque {};

const SSL_VERIFY_PEER: c_int = 0x01;
const SSL_ERROR_NONE: c_int = 0;
const SSL_ERROR_SSL: c_int = 1;
const SSL_ERROR_WANT_READ: c_int = 2;
const SSL_ERROR_WANT_WRITE: c_int = 3;
const SSL_ERROR_ZERO_RETURN: c_int = 6;
const SSL_ERROR_SYSCALL: c_int = 5;
const X509_V_OK: c_long = 0;

extern fn TLS_client_method() ?*const anyopaque;
extern fn SSL_CTX_new(method: ?*const anyopaque) ?*SSL_CTX;
extern fn SSL_CTX_free(ctx: *SSL_CTX) void;
extern fn SSL_CTX_set_verify(ctx: *SSL_CTX, mode: c_int, callback: ?*const anyopaque) void;
extern fn SSL_CTX_get_cert_store(ctx: *SSL_CTX) ?*X509_STORE;
extern fn X509_STORE_add_cert(store: *X509_STORE, cert: *X509) c_int;
extern fn d2i_X509(out: ?*?*X509, input: *[*c]const u8, len: c_long) ?*X509;
extern fn X509_free(cert: *X509) void;
extern fn SSL_new(ctx: *SSL_CTX) ?*SSL;
extern fn SSL_free(ssl: *SSL) void;
extern fn SSL_set_fd(ssl: *SSL, fd: c_int) c_int;
extern fn SSL_connect(ssl: *SSL) c_int;
extern fn SSL_read(ssl: *SSL, buf: [*]u8, num: c_int) c_int;
extern fn SSL_write(ssl: *SSL, buf: [*]const u8, num: c_int) c_int;
extern fn SSL_shutdown(ssl: *SSL) c_int;
extern fn SSL_get_error(ssl: *const SSL, ret: c_int) c_int;
extern fn SSL_get_verify_result(ssl: *const SSL) c_long;

/// A context holding the trust anchor, shared by every connection made from it.
pub const Context = struct {
    ctx: *SSL_CTX,

    /// `root_der` is the trust anchor -- IKEA's self-signed root. Nothing else is trusted,
    /// not even the system store, so this will refuse any certificate IKEA did not issue.
    pub fn init(root_der: []const u8) !Context {
        const ctx = SSL_CTX_new(TLS_client_method()) orelse return error.TlsSetup;
        errdefer SSL_CTX_free(ctx);

        var cursor: [*c]const u8 = root_der.ptr;
        const cert = d2i_X509(null, &cursor, @intCast(root_der.len)) orelse
            return error.TlsSetup;
        defer X509_free(cert);

        const store = SSL_CTX_get_cert_store(ctx) orelse return error.TlsSetup;
        if (X509_STORE_add_cert(store, cert) != 1) return error.TlsSetup;

        // A chain that does not reach the anchor above makes SSL_connect fail. The
        // hostname is a separate question -- see the file header -- and SSL_set1_host is
        // deliberately not called.
        SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, null);

        return .{ .ctx = ctx };
    }

    pub fn deinit(c: *Context) void {
        SSL_CTX_free(c.ctx);
    }
};

/// One TLS connection. Heap-allocated because the reader and writer below hand out pointers
/// into it, so it must not move.
pub const Connection = struct {
    io: Io,
    allocator: Allocator,
    stream: Io.net.Stream,
    ssl: *SSL,
    reader_state: Reader,
    writer_state: Writer,
    read_buf: []u8,
    write_buf: []u8,

    pub fn open(
        io: Io,
        allocator: Allocator,
        context: Context,
        address: Io.net.IpAddress,
        connect_timeout_ms: u32,
        read_timeout_ms: u32,
        buffer_len: usize,
    ) !*Connection {
        const c = try allocator.create(Connection);
        errdefer allocator.destroy(c);

        c.io = io;
        c.allocator = allocator;
        c.read_buf = try allocator.alloc(u8, buffer_len);
        errdefer allocator.free(c.read_buf);
        c.write_buf = try allocator.alloc(u8, buffer_len);
        errdefer allocator.free(c.write_buf);

        // A bounded connect: the OS default is about 76 seconds. See wire.zig.
        c.stream = wire.connectWithDeadline(address, connect_timeout_ms) catch
            return error.TlsFailed;
        errdefer c.stream.close(io);

        // Safe here, unlike on the std path: SSL_read surfaces a timeout as a return value
        // for this code to handle, rather than reaching Io.Threaded's EAGAIN assertion.
        setReceiveTimeout(c.stream.socket.handle, read_timeout_ms);

        c.ssl = SSL_new(context.ctx) orelse return error.TlsSetup;
        errdefer SSL_free(c.ssl);

        if (SSL_set_fd(c.ssl, c.stream.socket.handle) != 1) return error.TlsSetup;
        if (SSL_connect(c.ssl) != 1) return error.TlsFailed;
        // Belt and braces: SSL_VERIFY_PEER should already have failed the handshake, but a
        // silent verification pass is exactly the mistake worth double-checking.
        if (SSL_get_verify_result(c.ssl) != X509_V_OK) return error.TlsFailed;

        c.reader_state = .{
            .interface = .{
                .vtable = &.{ .stream = Reader.streamImpl, .readVec = Reader.readVec },
                .buffer = c.read_buf,
                .seek = 0,
                .end = 0,
            },
            .ssl = c.ssl,
        };
        c.writer_state = .{
            .interface = .{
                .vtable = &.{ .drain = Writer.drain },
                .buffer = c.write_buf,
                .end = 0,
            },
            .ssl = c.ssl,
        };
        return c;
    }

    pub fn close(c: *Connection) void {
        _ = SSL_shutdown(c.ssl);
        SSL_free(c.ssl);
        c.stream.close(c.io);
        c.allocator.free(c.read_buf);
        c.allocator.free(c.write_buf);
        c.allocator.destroy(c);
    }

    pub fn reader(c: *Connection) *Io.Reader {
        return &c.reader_state.interface;
    }

    pub fn writer(c: *Connection) *Io.Writer {
        return &c.writer_state.interface;
    }
};

/// Plaintext out of `SSL_read`, shaped as an `Io.Reader` so the HTTP and WebSocket code
/// above it does not know TLS is involved. Mirrors `Io.net.Stream.Reader`.
const Reader = struct {
    interface: Io.Reader,
    ssl: *SSL,

    fn readVec(io_r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const self: *Reader = @alignCast(@fieldParentPtr("interface", io_r));

        var iovecs: [8][]u8 = undefined;
        const dest_n, const data_size = try io_r.writableVector(&iovecs, data);
        if (dest_n == 0) return 0;
        const dest = iovecs[0];
        if (dest.len == 0) return 0;

        // One slice, because SSL_read cannot scatter. A short read is always allowed.
        const n = SSL_read(self.ssl, dest.ptr, @intCast(@min(dest.len, std.math.maxInt(c_int))));
        if (n <= 0) return switch (SSL_get_error(self.ssl, n)) {
            // A clean close, and how a response body ends here: the hub answers
            // `Connection: close`.
            SSL_ERROR_ZERO_RETURN => error.EndOfStream,
            // With a blocking socket these mean SO_RCVTIMEO fired.
            SSL_ERROR_WANT_READ, SSL_ERROR_WANT_WRITE => error.ReadFailed,
            SSL_ERROR_SYSCALL => if (n == 0) error.EndOfStream else error.ReadFailed,
            else => error.ReadFailed,
        };

        // The accounting that matters, and the one this got wrong at first.
        //
        // `writableVector` offers the caller's buffers FIRST and the reader's own buffer
        // after them, so `data_size` is how much of what was just read belongs to the
        // caller. Anything past that landed in the reader's internal buffer, and `end` has
        // to be advanced by it or the framework will not know those bytes exist.
        //
        // `peekGreedy` passes no buffers of its own, so `data_size` is zero and EVERY byte
        // is internal. Returning the count instead of advancing `end` made the reader look
        // empty after a successful read -- which read as end-of-stream, and turned a
        // perfectly good 308-byte response into nothing at all.
        const count: usize = @intCast(n);
        if (count > data_size) {
            io_r.end += count - data_size;
            return data_size;
        }
        return count;
    }

    fn streamImpl(io_r: *Io.Reader, io_w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const n = try readVec(io_r, &data);
        io_w.advance(n);
        return n;
    }
};

/// The other direction. Mirrors `Io.net.Stream.Writer`.
const Writer = struct {
    interface: Io.Writer,
    ssl: *SSL,

    fn drain(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *Writer = @alignCast(@fieldParentPtr("interface", io_w));

        // Both the already-buffered bytes AND the caller's vectors, in that order, in one
        // call -- which is what `Io.net.Stream.Writer` does by handing both to `netWrite`.
        //
        // Writing only the buffered part and returning was the first version, and it
        // silently truncated every request: the trailing "\r\n" of each HTTP header block
        // sat in `data`, never went out, and the hub waited for a request that never
        // finished and then closed. `consume` is told the total, buffered included.
        var total: usize = 0;

        const buffered = io_w.buffered();
        if (buffered.len > 0) total += try writeAll(self.ssl, buffered);

        for (data, 0..) |chunk, i| {
            if (chunk.len == 0) continue;
            // The last vector is repeated `splat` times; everything before it once.
            const repeats = if (i == data.len - 1) splat else 1;
            for (0..repeats) |_| total += try writeAll(self.ssl, chunk);
        }

        return io_w.consume(total);
    }

    fn writeAll(ssl: *SSL, bytes: []const u8) Io.Writer.Error!usize {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const take = @min(bytes.len - offset, std.math.maxInt(c_int));
            const n = SSL_write(ssl, bytes.ptr + offset, @intCast(take));
            if (n <= 0) return error.WriteFailed;
            offset += @intCast(n);
        }
        return offset;
    }
};

/// `SO_RCVTIMEO`, so a dead peer cannot hold a read open indefinitely.
fn setReceiveTimeout(handle: std.posix.fd_t, ms: u32) void {
    if (ms == 0) return;
    const tv: std.posix.timeval = .{
        .sec = @intCast(ms / 1000),
        .usec = @intCast((ms % 1000) * 1000),
    };
    std.posix.setsockopt(
        handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        &std.mem.toBytes(tv),
    ) catch {};
}
