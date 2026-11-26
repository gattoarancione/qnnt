//! Echo responder for the round-trip benchmark. Subscribes to `test/bench` and republishes
//! each frame, unchanged, on `test/bench-echo`.
//!
//!   zig build run-5
//!
//! It exists because one-way latency cannot be measured between two hosts without their
//! clocks agreeing. node-3 stamps each frame with its own clock and node-4 subtracts using
//! its own, which is fine on one machine and worthless across two: the two clocks here
//! differed by 86 ms, far more than the latency being measured, and in the other direction
//! the subtraction goes negative and clamps to zero.
//!
//! Echoing sidesteps the problem entirely. The frame carries the prober's timestamp out
//! and back, so node-6 computes the round trip against the clock that issued it. Nothing
//! here needs a synchronised clock, or even a correct one.
//!
//! The frame is returned byte-for-byte rather than re-encoded, so this side adds a decode
//! and a write and nothing else.

const std = @import("std");
const qnnt = @import("qnnt").Qnnt;
const told = @import("qnnt").Told;

const in_topic = "test/bench";
const out_topic = "test/bench-echo";

// Written by the subscriber thread, read by the reporting loop in main.
var echoed = @import("qnnt").Atomic64.Value.init(0);
var failed = @import("qnnt").Atomic64.Value.init(0);

fn onFrame(_: []const u8, f: told.Frame, _: ?*anyopaque) void {
    qnnt.publish(out_topic, f.raw) catch {
        _ = failed.fetchAdd(1, .monotonic);
        return;
    };
    _ = echoed.fetchAdd(1, .monotonic);
}

pub fn main() !void {
    qnnt.configureFromEnvironment();

    if (! qnnt.run()) {
        std.debug.print("failed to run QNNT\n", .{});
    }
    defer qnnt.deinit();

    qnnt.installSignalHandlers();

    // A manual publisher: no source and no period, so nothing is scheduled and frames go
    // out only when the handler pushes one.
    if (! qnnt.runPublisher(out_topic, null, null, null)) {
        std.debug.print("failed to run {s} publisher\n", .{out_topic});
        return;
    }

    if (! qnnt.subscribeFrames(in_topic, onFrame, null)) {
        std.debug.print("failed to subscribe to {s}\n", .{in_topic});
        return;
    }

    std.debug.print("node-5 echoing {s} -> {s}\n", .{ in_topic, out_topic });

    var last: u64 = 0;
    while (!qnnt.stopRequested()) {
        qnnt.sleepMs(1000);
        const now = echoed.load(.monotonic);
        std.debug.print("node-5 echoed {d}/s, {d} total, {d} failed\n", .{
            now - last, now, failed.load(.monotonic),
        });
        last = now;
    }
}
