//! TLD load generator. Publishes `test/bench` as TLD frames at a chosen rate and
//! payload size, for node-4 to measure.
//!
//!   zig build run-3 -- [period_us] [payload_bytes]      defaults: 1000 64
//!
//! The period is in microseconds, matching the library's scheduler: 1000 is 1 kHz, and
//! 0 is unpaced — as fast as the machine manages. Note that 0 is meaningfully faster
//! than 1, since a 1 us period still sleeps every tick and the syscall costs more than
//! the microsecond being waited for.
//!
//! Each frame carries a sequence number and the send timestamp, which is what lets
//! node-4 report end-to-end latency and spot gaps. The payload is a repeating 0..255
//! pattern, so it contains 0x0A and 0xFF on purpose: a benchmark that only moved
//! plain text would not be exercising the thing TLD framing is for, and node-4
//! verifies the pattern byte-for-byte.

const std = @import("std");
const qnnt = @import("qnnt").Qnnt;
const tld = @import("qnnt").Tld;

const allocator = std.heap.page_allocator;

const topic = "test/bench";

// Written by the scheduler thread, read by the reporting loop in main.
var sent = std.atomic.Value(u64).init(0);
var sent_bytes = std.atomic.Value(u64).init(0);

// Touched only by the scheduler thread, which is the only caller of benchSource.
var frame: std.ArrayList(u8) = .empty;
var payload: []u8 = &.{};
var seq: u64 = 0;

fn benchSource(_: []const u8, _: ?*anyopaque) ?[]const u8 {
    frame.clearRetainingCapacity();
    var enc = tld.Encoder.init(allocator, &frame);

    seq += 1;

    const obj = enc.beginObject();
    enc.writeKey("seq") catch return null;
    enc.writeUint(seq) catch return null;
    enc.writeKey("t") catch return null;
    enc.writeUint(@intCast(qnnt.nowMicros())) catch return null;
    enc.writeKey("data") catch return null;
    enc.writeBuffer(payload) catch return null;
    enc.end(obj) catch return null;

    _ = sent.fetchAdd(1, .monotonic);
    _ = sent_bytes.fetchAdd(frame.items.len, .monotonic);
    return frame.items;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next(); // executable path

    var period_us: u64 = 1000;
    var payload_bytes: usize = 64;
    if (args.next()) |a| period_us = std.fmt.parseInt(u64, a, 10) catch period_us;
    if (args.next()) |a| payload_bytes = std.fmt.parseInt(usize, a, 10) catch payload_bytes;

    payload = try allocator.alloc(u8, payload_bytes);
    defer allocator.free(payload);
    for (payload, 0..) |*b, i| b.* = @truncate(i);

    if (! qnnt.run()) {
        std.debug.print("failed to run QNNT\n", .{});
    }
    defer qnnt.deinit();

    qnnt.installSignalHandlers();

    // Encode one frame up front purely to report the wire size, so the two nodes'
    // numbers can be compared without guessing at framing overhead.
    _ = benchSource(topic, null);
    const frame_bytes = frame.items.len;
    sent.store(0, .monotonic);
    sent_bytes.store(0, .monotonic);
    seq = 0;

    std.debug.print("node-3 publishing {s}: {d}B payload, {d}B frames ({d} overhead), ", .{
        topic,
        payload_bytes,
        frame_bytes,
        frame_bytes - payload_bytes,
    });

    if (period_us == 0) {
        std.debug.print("unpaced (no target rate)\n", .{});
    } else {
        const rate = 1_000_000.0 / @as(f64, @floatFromInt(period_us));
        std.debug.print("{d}us period ({d:.1} Hz), target {d:.1} KB/s\n", .{
            period_us,
            rate,
            rate * @as(f64, @floatFromInt(frame_bytes)) / 1024.0,
        });
    }

    if (! qnnt.runPublisher(topic, benchSource, period_us, null)) {
        std.debug.print("failed to run {s} publisher\n", .{topic});
        return;
    }

    // Report what was actually sent, so a shortfall at the subscriber can be pinned on
    // the publisher rather than on the transport or the decoder.
    var last_sent: u64 = 0;
    var last_bytes: u64 = 0;
    var last_us: u64 = @intCast(qnnt.nowMicros());

    while (!qnnt.stopRequested()) {
        qnnt.sleepMs(1000);

        const now_us: u64 = @intCast(qnnt.nowMicros());
        const now_sent = sent.load(.monotonic);
        const now_bytes = sent_bytes.load(.monotonic);

        const elapsed_s = @as(f64, @floatFromInt(now_us -| last_us)) / 1_000_000.0;
        const d_sent = now_sent - last_sent;
        const d_bytes = now_bytes - last_bytes;

        std.debug.print("node-3 sent {d:.0} frames/s ({d:.1} KB/s), {d} total\n", .{
            @as(f64, @floatFromInt(d_sent)) / elapsed_s,
            @as(f64, @floatFromInt(d_bytes)) / elapsed_s / 1024.0,
            now_sent,
        });

        last_sent = now_sent;
        last_bytes = now_bytes;
        last_us = now_us;
    }
}
