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
    SocketFailed,
    BindFailed,
    ReadFailed,
    WriteFailed,
};

const can_raw = 1;
const sol_can_raw = 100 + can_raw;
const can_raw_err_filter = 2;
const can_raw_recv_own_msgs = 4;
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

        return .{ .fd = fd, .iface = iface };
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
        var raw: can_frame = .{ .can_id = 0, .len = 0 };
        const n = std.c.read(self.fd, @ptrCast(&raw), @sizeOf(can_frame));
        if (n < 0) {
            return switch (posix.errno(n)) {
                .AGAIN, .INTR => null,
                else => Error.ReadFailed,
            };
        }
        // A short read is not a frame. CAN_RAW delivers whole frames or nothing, so this
        // means the socket is not what we think it is.
        if (n != @sizeOf(can_frame)) return Error.ReadFailed;

        payload.* = raw.data;
        return frame.fromRaw(raw.can_id, raw.len, payload);
    }

    /// Write one frame. The caller must have checked `frame.writable` first: this is the
    /// kernel boundary, not the policy boundary.
    pub fn write(self: *const Bus, f: frame.Frame) Error!void {
        var raw: can_frame = .{ .can_id = frame.rawId(f), .len = f.dlc };
        const n = @min(f.data.data.len, raw.data.len);
        @memcpy(raw.data[0..n], f.data.data[0..n]);

        const written = std.c.write(self.fd, @ptrCast(&raw), @sizeOf(can_frame));
        if (written != @sizeOf(can_frame)) {
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
