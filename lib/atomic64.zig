//! A 64-bit counter that also works on a 32-bit CPU.
//!
//! `std.atomic.Value(u64)` needs the target to have lock-free 64-bit atomic
//! instructions. A 32-bit CPU generally does not, and Zig does not paper over it: an
//! `@atomicLoad` of a u64 on x86-linux or arm-linux is a compile error, which is what
//! kept this library 64-bit only.
//!
//! Narrowing the values is not an option. They are epochs, microsecond timestamps and
//! lifetime counters: `registry_since_us` truncated to 32 bits wraps about 71 minutes
//! after the node starts, and `directory_epoch` is compared across hosts during
//! federation merges, where a wrap would silently reorder entries.
//!
//! So this picks the native atomic where the target has one, and a u64 behind a spin lock
//! where it does not. `std.atomic.Mutex` is the right primitive rather than `Io.Mutex`:
//! the latter wants an `io` handle threaded through every caller, and these critical
//! sections are two instructions -- read or write eight bytes -- so a spin is cheaper than
//! anything that could park a thread. The lock itself is a u8 compare-exchange, which every
//! 32-bit target has. The API mirrors `std.atomic.Value`, so call sites read the same on
//! both paths.
//!
//! Affordable because of where these are used: each is bumped once per event, per request
//! or per sync, never read in a tight loop.
//!
//! One constraint the guarded path imposes: a struct holding one of these must not be
//! copied once threads are running, because each copy would carry its own lock and the two
//! would no longer exclude each other. `federation.Peer` copies a default-initialised value
//! into its array in `addPeer`, which is safe only because `addPeer` refuses to run after
//! the node has started; every later access is through a pointer.

const std = @import("std");

/// Whether the target can do lock-free 64-bit atomics. 64-bit pointers are the practical
/// proxy: every target Zig builds here with a 64-bit usize has them, and the 32-bit ones
/// either lack the instruction or need a libatomic call that Zig will not emit implicitly.
pub const lock_free = @bitSizeOf(usize) >= 64;

pub const Value = if (lock_free) Native else Guarded;

/// Thin pass-through, so a 64-bit build is exactly what it was before.
const Native = struct {
    inner: std.atomic.Value(u64),

    pub fn init(value: u64) Native {
        return .{ .inner = std.atomic.Value(u64).init(value) };
    }

    pub fn load(self: *Native, comptime order: std.builtin.AtomicOrder) u64 {
        return self.inner.load(order);
    }

    pub fn store(self: *Native, value: u64, comptime order: std.builtin.AtomicOrder) void {
        self.inner.store(value, order);
    }

    pub fn fetchAdd(self: *Native, value: u64, comptime order: std.builtin.AtomicOrder) u64 {
        return self.inner.fetchAdd(value, order);
    }

    pub fn swap(self: *Native, value: u64, comptime order: std.builtin.AtomicOrder) u64 {
        return self.inner.swap(value, order);
    }

    pub fn cmpxchgStrong(
        self: *Native,
        expected: u64,
        desired: u64,
        comptime success: std.builtin.AtomicOrder,
        comptime failure: std.builtin.AtomicOrder,
    ) ?u64 {
        return self.inner.cmpxchgStrong(expected, desired, success, failure);
    }
};

/// The 32-bit path. The memory order is accepted and ignored: the lock already gives a
/// stronger guarantee than any order these call sites ask for.
const Guarded = struct {
    guard: std.atomic.Mutex = .unlocked,
    raw: u64 = 0,

    pub fn init(value: u64) Guarded {
        return .{ .raw = value };
    }

    /// std.atomic.Mutex offers no blocking lock, only tryLock, so spin on it. Contention
    /// is rare and the holder releases within a couple of instructions.
    fn acquire(self: *Guarded) void {
        while (!self.guard.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn load(self: *Guarded, comptime _: std.builtin.AtomicOrder) u64 {
        self.acquire();
        defer self.guard.unlock();
        return self.raw;
    }

    pub fn store(self: *Guarded, value: u64, comptime _: std.builtin.AtomicOrder) void {
        self.acquire();
        defer self.guard.unlock();
        self.raw = value;
    }

    /// Wrapping, like std.atomic.Value.fetchAdd, rather than trapping on overflow.
    pub fn fetchAdd(self: *Guarded, value: u64, comptime _: std.builtin.AtomicOrder) u64 {
        self.acquire();
        defer self.guard.unlock();
        const previous = self.raw;
        self.raw = previous +% value;
        return previous;
    }

    pub fn swap(self: *Guarded, value: u64, comptime _: std.builtin.AtomicOrder) u64 {
        self.acquire();
        defer self.guard.unlock();
        const previous = self.raw;
        self.raw = value;
        return previous;
    }

    /// null on success, like std.atomic.Value: the lock makes this unconditionally
    /// strong, so there is no weak variant to distinguish.
    pub fn cmpxchgStrong(
        self: *Guarded,
        expected: u64,
        desired: u64,
        comptime _: std.builtin.AtomicOrder,
        comptime _: std.builtin.AtomicOrder,
    ) ?u64 {
        self.acquire();
        defer self.guard.unlock();
        if (self.raw != expected) return self.raw;
        self.raw = desired;
        return null;
    }
};

test "counts the same on either path" {
    var v: Value = .init(7);
    try std.testing.expectEqual(@as(u64, 7), v.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 7), v.fetchAdd(5, .monotonic));
    try std.testing.expectEqual(@as(u64, 12), v.load(.monotonic));
    v.store(std.math.maxInt(u64), .monotonic);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), v.load(.monotonic));
    // wraps rather than traps, matching std.atomic.Value
    _ = v.fetchAdd(1, .monotonic);
    try std.testing.expectEqual(@as(u64, 0), v.load(.monotonic));

    try std.testing.expectEqual(@as(u64, 0), v.swap(99, .monotonic));
    try std.testing.expectEqual(@as(u64, 99), v.load(.monotonic));

    // null means it took; a mismatch returns what was actually there
    try std.testing.expectEqual(@as(?u64, null), v.cmpxchgStrong(99, 100, .monotonic, .monotonic));
    try std.testing.expectEqual(@as(u64, 100), v.load(.monotonic));
    try std.testing.expectEqual(@as(?u64, 100), v.cmpxchgStrong(7, 8, .monotonic, .monotonic));
    try std.testing.expectEqual(@as(u64, 100), v.load(.monotonic));
}

test "holds a value no 32-bit counter could" {
    // The reason these are not simply narrowed to u32: a microsecond timestamp passes
    // 2^32 about 71 minutes after the epoch it counts from.
    var v: Value = .init(0);
    const two_hours_us: u64 = 2 * 60 * 60 * std.time.us_per_s;
    v.store(two_hours_us, .monotonic);
    try std.testing.expectEqual(two_hours_us, v.load(.monotonic));
    try std.testing.expect(two_hours_us > std.math.maxInt(u32));
}
