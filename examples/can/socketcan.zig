//! SocketCAN, the Linux CAN stack, in the little of it a gateway needs.
//!
//! LINUX ONLY, and unapologetically so: CAN is a kernel subsystem, and there is no
//! equivalent to port to. Everything that is not the kernel lives in frame.zig, which is
//! why the wire format and the topic layout can be tested on a machine that has no CAN at
//! all -- see the note at the top of that file.
//!
//! Zig's standard library gives us AF_CAN and the ioctl, but no `sockaddr_can` and no
//! `can_frame`, so both are declared here against the kernel ABI. They are stable: these
//! layouts have not changed since SocketCAN was merged in 2.6.25.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const frame = @import("frame");

pub const Error = error{
    /// The kernel has no CAN subsystem. Almost always a kernel without CONFIG_CAN, which
    /// includes Docker Desktop's -- see examples/can/README or EXAMPLES.txt.
    NoCanSupport,
    /// No interface by that name. `ip link add dev vcan0 type vcan && ip link set up vcan0`.
    NoSuchInterface,
    /// The interface exists but is down.
    InterfaceDown,
    /// An FD frame arrived for a socket the kernel would not enable FD on. Relaying it
    /// would mean sending it as classic, which is a different frame.
    NoFdSupport,
    SocketFailed,
    BindFailed,
    ReadFailed,
    WriteFailed,
};

const can_raw = 1;
const sol_can_raw = 100 + can_raw;
const can_raw_err_filter = 2;
const can_raw_recv_own_msgs = 4;
const can_raw_fd_frames = 5;
/// The `flags` byte of a canfd_frame.
const canfd_brs: u8 = 0x01;
const canfd_esi: u8 = 0x02;
/// Every error class the controller can report. The default is 0 -- no error frames at all
/// -- so a gateway that wants to relay bus health has to ask.
const can_err_mask: u32 = 0x1FFF_FFFF;

/// struct sockaddr_can. Only the first two fields matter for CAN_RAW; the `can_addr` union
/// that follows belongs to the transport protocols we do not speak, and is carried at its
/// real width so `@sizeOf` is the length the kernel would compute. CAN_RAW's bind only
/// requires the bytes up to `ifindex`, so a short one happens to work -- but a struct whose
/// size is a lie is a trap for the next person to pass it to something that checks.
const sockaddr_can = extern struct {
    family: u16,
    ifindex: c_int,
    addr: [16]u8 = @splat(0),
};

/// struct can_frame. 16 bytes: the id word, the length, three reserved bytes, and eight
/// bytes of payload aligned to 8.
const can_frame = extern struct {
    can_id: u32,
    len: u8,
    _pad: u8 = 0,
    _res0: u8 = 0,
    _res1: u8 = 0,
    data: [8]u8 align(8) = @splat(0),
};

/// struct canfd_frame. 72 bytes, and the same first five: an FD frame differs from a
/// classic one in its length, its flags byte -- where the classic struct has padding -- and
/// sixty-four bytes of payload instead of eight.
const canfd_frame = extern struct {
    can_id: u32,
    len: u8,
    flags: u8 = 0,
    _res0: u8 = 0,
    _res1: u8 = 0,
    data: [64]u8 align(8) = @splat(0),
};

/// What the kernel puts on the wire for each, and the only thing that distinguishes them on
/// a socket carrying both: a read returns exactly one of these two sizes, and which one it
/// is IS the answer to "was that CAN FD".
const can_mtu = @sizeOf(can_frame);
const canfd_mtu = @sizeOf(canfd_frame);

/// struct ifreq, written out rather than taken from std: the standard one is a pair of
/// anonymous unions, and the two fields we need are far clearer named.
const ifreq_index = extern struct {
    name: [16]u8,
    index: c_int,
    _pad: [20]u8 = @splat(0),
};

// Checked against the kernel's own headers on aarch64 and x86_64 -- compile the equivalent
// offsetof() program against <linux/can.h> and these are the numbers it prints. They are
// asserted rather than commented because getting one wrong does not fail to compile and
// does not fail to run: it binds to the wrong interface, or reads a frame whose payload is
// offset by a byte, and every value looks plausible.
comptime {
    std.debug.assert(@sizeOf(can_frame) == 16);
    std.debug.assert(@sizeOf(canfd_frame) == 72);
    std.debug.assert(@offsetOf(canfd_frame, "can_id") == 0);
    std.debug.assert(@offsetOf(canfd_frame, "len") == 4);
    std.debug.assert(@offsetOf(canfd_frame, "flags") == 5);
    std.debug.assert(@offsetOf(canfd_frame, "data") == 8);
    std.debug.assert(can_raw_fd_frames == 5);
    std.debug.assert(frame.max_data == 64);
    std.debug.assert(@offsetOf(can_frame, "can_id") == 0);
    std.debug.assert(@offsetOf(can_frame, "len") == 4);
    std.debug.assert(@offsetOf(can_frame, "data") == 8);

    std.debug.assert(@sizeOf(sockaddr_can) == 24);
    std.debug.assert(@offsetOf(sockaddr_can, "family") == 0);
    std.debug.assert(@offsetOf(sockaddr_can, "ifindex") == 4);

    std.debug.assert(@sizeOf(ifreq_index) == 40);
    std.debug.assert(@offsetOf(ifreq_index, "name") == 0);
    std.debug.assert(@offsetOf(ifreq_index, "index") == 16);

    // AF_CAN, and the socket-option level and names, as <linux/can/raw.h> defines them.
    std.debug.assert(posix.AF.CAN == 29);
    std.debug.assert(sol_can_raw == 101);
    std.debug.assert(can_raw_recv_own_msgs == 4);
    std.debug.assert(can_raw_err_filter == 2);
    std.debug.assert(can_err_mask == 0x1FFF_FFFF);
}

pub const Bus = struct {
    fd: c_int,
    /// The interface name, for messages. Borrowed from the caller's arguments.
    iface: []const u8,
    /// Whether the kernel agreed to deliver CAN FD frames on this socket. False is not an
    /// error: a kernel or an interface without FD still carries classic traffic perfectly
    /// well, and refusing to run would take a working gateway off the air over a feature
    /// its bus may never use.
    fd_frames: bool,

    /// Open `iface` and bind to it, with a read timeout so the reader can notice a
    /// shutdown request instead of blocking in the kernel for ever.
    pub fn open(iface: []const u8, read_timeout_ms: u32) Error!Bus {
        if (iface.len == 0 or iface.len >= 16) return Error.NoSuchInterface;

        const fd = std.c.socket(posix.AF.CAN, posix.SOCK.RAW, can_raw);
        if (fd < 0) {
            // EAFNOSUPPORT/EPROTONOSUPPORT is the kernel saying it has no CAN at all,
            // which is a different problem from a missing interface and deserves to say so.
            return switch (posix.errno(fd)) {
                .AFNOSUPPORT, .PROTONOSUPPORT, .INVAL => Error.NoCanSupport,
                else => Error.SocketFailed,
            };
        }
        errdefer _ = std.c.close(fd);

        var ifr: ifreq_index = .{ .name = @splat(0), .index = 0 };
        @memcpy(ifr.name[0..iface.len], iface);
        if (std.c.ioctl(fd, linux.SIOCGIFINDEX, &ifr) != 0) return Error.NoSuchInterface;
        if (ifr.index == 0) return Error.NoSuchInterface;

        // We read and write on ONE socket per bus, and that is what stops a relayed frame
        // from looping. SocketCAN loops a transmitted frame back to the OTHER sockets on
        // the interface, and to the sending socket only when this option is on. Off, a
        // frame this gateway writes is never read back by this gateway, so it is never
        // republished. It is off by default; set explicitly because the whole design rests
        // on it and a default is not a statement of intent.
        var off: c_int = 0;
        _ = std.c.setsockopt(fd, sol_can_raw, can_raw_recv_own_msgs, &off, @sizeOf(c_int));

        // Ask for error frames. Without this the kernel delivers none, and a controller
        // going bus-off would be invisible to everyone watching the topic.
        var err_mask: u32 = can_err_mask;
        _ = std.c.setsockopt(fd, sol_can_raw, can_raw_err_filter, &err_mask, @sizeOf(u32));

        // Ask for CAN FD. On a socket with this set the kernel delivers BOTH formats and
        // the read size says which arrived; without it, FD frames on the wire are not
        // delivered at all -- not truncated, simply absent.
        //
        // It can legitimately fail on an older kernel, so the answer is recorded rather
        // than insisted on. Transmitting FD additionally needs the interface MTU at 72,
        // which is the link's business and not this socket's.
        var on: c_int = 1;
        const fd_ok = std.c.setsockopt(fd, sol_can_raw, can_raw_fd_frames, &on, @sizeOf(c_int)) == 0;

        var tv: posix.timeval = .{
            .sec = @intCast(read_timeout_ms / 1000),
            .usec = @intCast((read_timeout_ms % 1000) * 1000),
        };
        _ = std.c.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &tv, @sizeOf(posix.timeval));

        var addr: sockaddr_can = .{ .family = posix.AF.CAN, .ifindex = ifr.index };
        const bound = std.c.bind(fd, @ptrCast(&addr), @sizeOf(sockaddr_can));
        if (bound != 0) {
            return switch (posix.errno(bound)) {
                .NODEV => Error.NoSuchInterface,
                .NETDOWN => Error.InterfaceDown,
                else => Error.BindFailed,
            };
        }

        return .{ .fd = fd, .iface = iface, .fd_frames = fd_ok };
    }

    pub fn close(self: *Bus) void {
        _ = std.c.close(self.fd);
        self.fd = -1;
    }

    /// One frame, or null when the read timed out -- which is the reader's chance to check
    /// whether it has been asked to stop.
    ///
    /// The payload is copied into the CALLER'S buffer, and the returned frame borrows it.
    /// That is what the out-parameter is for, and it is not decoration: the first version
    /// read into a local `can_frame` and returned a frame pointing into it, which dangled
    /// the instant this returned. It did not crash. It published whatever the next call
    /// left on the stack -- every frame on the bus arrived at every other host carrying the
    /// same eight bytes of a leftover pointer, with a correct identifier and a correct
    /// length in front of it.
    pub fn read(self: *const Bus, payload: *[frame.max_data]u8) Error!?frame.Frame {
        // One buffer, big enough for either format. The kernel fills as much as the frame
        // needs and tells us how much by what it returns.
        var raw: canfd_frame = .{ .can_id = 0, .len = 0 };
        const n = std.c.read(self.fd, @ptrCast(&raw), canfd_mtu);
        if (n < 0) {
            return switch (posix.errno(n)) {
                .AGAIN, .INTR => null,
                else => Error.ReadFailed,
            };
        }

        // THE READ SIZE IS THE FORMAT. A CAN_RAW socket with FD enabled delivers both, and
        // this is the only thing that distinguishes them: an eight-byte FD frame and an
        // eight-byte classic frame are otherwise identical, and they are not the same frame
        // to a controller. Anything that is neither size is not a frame at all.
        const kind: frame.Kind = switch (n) {
            can_mtu => .classic,
            canfd_mtu => .{
                .fd = true,
                .brs = (raw.flags & canfd_brs) != 0,
                .esi = (raw.flags & canfd_esi) != 0,
            },
            else => return Error.ReadFailed,
        };

        // The classic struct has three reserved bytes where the FD one keeps its flags and
        // the first of its payload, so a classic frame's eight bytes start at the same
        // offset either way -- `data` is at offset 8 in both.
        payload.* = raw.data;
        return frame.fromRaw(raw.can_id, raw.len, payload, kind);
    }

    /// Write one frame. The caller must have checked `frame.writable` first: this is the
    /// kernel boundary, not the policy boundary.
    ///
    /// The size written is what tells the kernel which format to transmit, exactly as the
    /// size read told us which arrived.
    pub fn write(self: *const Bus, f: frame.Frame) Error!void {
        if (f.fd) {
            // An FD frame will not go onto an interface whose MTU is still 16: the write
            // fails with EMSGSIZE. `ip link set <if> mtu 72` is what the link needs, and
            // examples/can/start-gateway.sh does it.
            if (!self.fd_frames) return Error.NoFdSupport;

            var raw: canfd_frame = .{ .can_id = frame.rawId(f), .len = f.dlc };
            if (f.brs) raw.flags |= canfd_brs;
            if (f.esi) raw.flags |= canfd_esi;
            const n = @min(f.data.data.len, raw.data.len);
            @memcpy(raw.data[0..n], f.data.data[0..n]);

            if (std.c.write(self.fd, @ptrCast(&raw), canfd_mtu) != canfd_mtu) {
                return Error.WriteFailed;
            }
            return;
        }

        var raw: can_frame = .{ .can_id = frame.rawId(f), .len = f.dlc };
        const n = @min(f.data.data.len, raw.data.len);
        @memcpy(raw.data[0..n], f.data.data[0..n]);

        const written = std.c.write(self.fd, @ptrCast(&raw), can_mtu);
        if (written != can_mtu) {
            // ENOBUFS is the normal one: the interface's transmit queue is full, which on a
            // real bus means the gateway is offering more than the wire can carry.
            return Error.WriteFailed;
        }
    }
};

/// Why an open failed, in the terms of whoever has to fix it.
pub fn explain(err: Error, iface: []const u8) void {
    switch (err) {
        Error.NoCanSupport => std.debug.print(
            "{s}: this kernel has no CAN support (no AF_CAN socket).\n" ++
                "  A stock Linux distribution has it; Docker Desktop's LinuxKit kernel does not.\n" ++
                "  Check with: ls /proc/net/can\n",
            .{iface},
        ),
        Error.NoSuchInterface => std.debug.print(
            "{s}: no such interface. Create it with:\n" ++
                "  sudo modprobe vcan && sudo ip link add dev {s} type vcan && sudo ip link set up {s}\n",
            .{ iface, iface, iface },
        ),
        Error.InterfaceDown => std.debug.print(
            "{s}: the interface is down -- ip link set up {s}\n",
            .{ iface, iface },
        ),
        else => std.debug.print("{s}: {s}\n", .{ iface, @errorName(err) }),
    }
}

// ---------------------------------------------------------------- tests
//
// These need a real CAN interface, so they do not run in `zig build test` on a developer's
// machine -- they are built by `zig build can-test -Dtarget=*-linux-gnu` and run inside the
// container by docker/can.sh, which creates the interface first.
//
// They exist because this file had no coverage at all and immediately proved it: `read`
// returned a frame borrowing its own stack, so every relayed frame carried eight bytes of a
// leftover pointer. Nothing above the socket could have caught it -- the identifier and the
// length were right, and the payload was plausible bytes.

const testing = std.testing;

/// Created by docker/can.sh before running this.
const test_iface = "vcantest";

fn openOrSkip() !Bus {
    return Bus.open(test_iface, 500) catch |err| {
        std.debug.print("skipping: no {s} ({t}). docker/can.sh creates it.\n",
            .{ test_iface, err });
        return error.SkipZigTest;
    };
}

test "a frame written on one socket arrives intact on another" {
    var tx = try openOrSkip();
    defer tx.close();
    var rx = try openOrSkip();
    defer rx.close();

    const sent = frame.Frame{
        .id = 0x123,
        .ext = false,
        .rtr = false,
        .err = false,
        .dlc = 8,
        // Every byte different, and not a run of zeros: a payload that is mostly zeros
        // matches a dangling read into fresh stack often enough to pass by luck.
        .data = .{ .data = &.{ 0xA1, 0x01, 0x02, 0xDE, 0xAD, 0xBE, 0xEF, 0x5A } },
        .us = 0,
    };
    try tx.write(sent);

    var payload: [frame.max_data]u8 = undefined;
    const got = (try rx.read(&payload)) orelse return error.TestUnexpectedResult;

    try testing.expectEqual(sent.id, got.id);
    try testing.expectEqual(sent.ext, got.ext);
    try testing.expectEqual(sent.dlc, got.dlc);
    // The assertion the whole gateway rests on, and the one that was silently false.
    try testing.expectEqualSlices(u8, sent.data.data, got.data.data);
}

test "a 29-bit identifier survives the kernel round trip" {
    var tx = try openOrSkip();
    defer tx.close();
    var rx = try openOrSkip();
    defer rx.close();

    try tx.write(.{
        .id = 0x1ABCDEF, .ext = true, .rtr = false, .err = false,
        .dlc = 3, .data = .{ .data = &.{ 0x11, 0x22, 0x33 } }, .us = 0,
    });

    var payload: [frame.max_data]u8 = undefined;
    const got = (try rx.read(&payload)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 0x1ABCDEF), got.id);
    try testing.expect(got.ext);
    try testing.expectEqual(@as(u8, 3), got.dlc);
    try testing.expectEqualSlices(u8, &.{ 0x11, 0x22, 0x33 }, got.data.data);
}

test "a socket does not read back what it just sent" {
    // The property the gateway's loop prevention rests on: one socket per bus does both the
    // reading and the writing, and SocketCAN loops a transmitted frame to the OTHER sockets
    // on the interface, not to the sender. If this ever became false, a relayed frame would
    // be read back and republished, and the mesh would saturate.
    var bus = try openOrSkip();
    defer bus.close();

    try bus.write(.{
        .id = 0x300, .ext = false, .rtr = false, .err = false,
        .dlc = 1, .data = .{ .data = &.{0x99} }, .us = 0,
    });

    // One read timeout is enough: the loopback would already have been queued.
    var payload: [frame.max_data]u8 = undefined;
    try testing.expect((try bus.read(&payload)) == null);
}

test "the read timeout returns rather than blocking for ever" {
    var bus = try openOrSkip();
    defer bus.close();

    // Nothing is on the bus, so this must come back empty -- that return is the gateway's
    // only chance to notice it has been asked to shut down.
    var payload: [frame.max_data]u8 = undefined;
    try testing.expect((try bus.read(&payload)) == null);
}

test "a CAN FD frame round-trips with its length, its flags and all 64 bytes" {
    var tx = try openOrSkip();
    defer tx.close();
    var rx = try openOrSkip();
    defer rx.close();

    if (!tx.fd_frames) {
        std.debug.print("skipping: kernel would not enable CAN_RAW_FD_FRAMES\n", .{});
        return error.SkipZigTest;
    }

    var payload: [frame.max_data]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @intCast(i);  // every byte different

    try tx.write(.{
        .id = 0x321, .ext = false, .rtr = false, .err = false,
        .fd = true, .brs = true, .esi = false,
        .dlc = 64, .data = .{ .data = &payload }, .us = 0,
    });

    var got_buf: [frame.max_data]u8 = undefined;
    const got = (try rx.read(&got_buf)) orelse return error.TestUnexpectedResult;

    try testing.expect(got.fd);
    try testing.expect(got.brs);
    try testing.expect(!got.esi);
    try testing.expectEqual(@as(u32, 0x321), got.id);
    try testing.expectEqual(@as(u8, 64), got.dlc);
    // All 64, not the first 8: a classic-sized read would have truncated here silently.
    try testing.expectEqualSlices(u8, &payload, got.data.data);
}

test "classic and FD frames are told apart on the same socket" {
    var tx = try openOrSkip();
    defer tx.close();
    var rx = try openOrSkip();
    defer rx.close();

    if (!tx.fd_frames) return error.SkipZigTest;

    // The same identifier and the same eight-byte payload, sent both ways. Nothing in the
    // bytes distinguishes them; only the size the kernel delivers does, which is precisely
    // the thing this asserts.
    const eight = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    try tx.write(.{
        .id = 0x111, .ext = false, .rtr = false, .err = false, .fd = false,
        .dlc = 8, .data = .{ .data = &eight }, .us = 0,
    });
    try tx.write(.{
        .id = 0x111, .ext = false, .rtr = false, .err = false, .fd = true,
        .dlc = 8, .data = .{ .data = &eight }, .us = 0,
    });

    var buf: [frame.max_data]u8 = undefined;
    const first = (try rx.read(&buf)) orelse return error.TestUnexpectedResult;
    try testing.expect(!first.fd);
    try testing.expectEqualSlices(u8, &eight, first.data.data);

    var buf2: [frame.max_data]u8 = undefined;
    const second = (try rx.read(&buf2)) orelse return error.TestUnexpectedResult;
    try testing.expect(second.fd);
    try testing.expectEqualSlices(u8, &eight, second.data.data);
}

test "an FD length classic CAN cannot express survives" {
    var tx = try openOrSkip();
    defer tx.close();
    var rx = try openOrSkip();
    defer rx.close();

    if (!tx.fd_frames) return error.SkipZigTest;

    // 12 bytes: the first length above 8 that CAN FD allows, and one no classic frame can
    // carry. If anything on the path fell back to classic this would come back as 8.
    const twelve = [_]u8{ 0xA, 0xB, 0xC, 0xD, 0xE, 0xF, 1, 2, 3, 4, 5, 6 };
    try tx.write(.{
        .id = 0x222, .ext = true, .rtr = false, .err = false, .fd = true,
        .dlc = 12, .data = .{ .data = &twelve }, .us = 0,
    });

    var buf: [frame.max_data]u8 = undefined;
    const got = (try rx.read(&buf)) orelse return error.TestUnexpectedResult;
    try testing.expect(got.fd and got.ext);
    try testing.expectEqual(@as(u8, 12), got.dlc);
    try testing.expectEqualSlices(u8, &twelve, got.data.data);
}
