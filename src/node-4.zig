//! TLD benchmark subscriber. Subscribes to `test/bench`, decodes every frame and
//! reports throughput, end-to-end latency, integrity and raw decoder cost.
//!
//!   zig build run-4 -- [report_interval_ms]      default: 1000
//!
//! All statistics live on the subscriber thread and are only touched by the frame
//! handler, which qnnt calls from one thread per subscription — so no locking, and the
//! reporting happens inside the handler rather than from main.
//!
//! What the numbers mean:
//!
//!   * latency is measured from the timestamp node-3 wrote while encoding to the
//!     moment the frame finished decoding here, so it covers encode, publish, the
//!     kernel's loopback, the read and the decode. It is not decode cost alone.
//!   * the decoder microbenchmark re-decodes one captured frame in a tight loop, which
//!     isolates decode cost from everything else. Build with -Doptimize=ReleaseFast
//!     for that figure to mean anything.
//!   * gaps and payload mismatches should both be zero. TCP does not lose bytes, so a
//!     non-zero count means frames were mis-parsed rather than dropped.

const std = @import("std");
const qnnt = @import("qnnt").Qnnt;
const tld = @import("qnnt").Tld;

const allocator = std.heap.page_allocator;

const topic = "test/bench";

var report_interval_us: u64 = 1_000_000;

// Latency histogram: linear buckets, wide enough for loopback and with an explicit
// overflow count so a long tail cannot be quietly folded into the last bucket. Reset
// with every report, so the percentiles describe the same window as min/mean/max —
// mixing a lifetime histogram with a windowed max produces the nonsense of p99 > max.
const bucket_us = 4;
const bucket_count = 4096; // 4 us * 4096 = 16.4 ms
var hist: [bucket_count]u32 = @splat(0);
var hist_overflow: u64 = 0;

var window_frames: u64 = 0;
var window_wire_bytes: u64 = 0;
var window_payload_bytes: u64 = 0;
var window_lat_sum: u64 = 0;
var window_lat_min: u64 = std.math.maxInt(u64);
var window_lat_max: u64 = 0;

var total_frames: u64 = 0;
var gaps: u64 = 0;
var bad_payloads: u64 = 0;
var decode_errors: u64 = 0;
var expected_seq: u64 = 0;

var window_start_us: u64 = 0;

// A copy of the most recent frame, for the decoder microbenchmark. Copied because the
// frame handed to the handler borrows the subscriber's buffer and is reused. Frames
// larger than this are still measured for throughput and latency, just not re-decoded.
var sample: [128 * 1024]u8 = undefined;
var sample_len: usize = 0;

/// Consume every field the way a real application would, and check the payload
/// pattern. Returns the send timestamp and payload length.
fn readFrame(f: tld.Frame) !struct { sent_us: u64, payload_len: usize } {
    var sent_us: u64 = 0;
    var payload_len: usize = 0;
    var seq: u64 = 0;

    var it = try f.objectIterator();
    while (try it.next()) |pair| {
        if (std.mem.eql(u8, pair.key, "seq")) {
            seq = try pair.value.asUint();
        } else if (std.mem.eql(u8, pair.key, "t")) {
            sent_us = try pair.value.asUint();
        } else if (std.mem.eql(u8, pair.key, "data")) {
            const data = try pair.value.asBuffer();
            payload_len = data.len;
            // The generator fills the payload with a repeating 0..255 pattern; any
            // deviation means the framing lost sync, not that a byte was corrupted.
            for (data, 0..) |b, i| {
                if (b != @as(u8, @truncate(i))) {
                    bad_payloads += 1;
                    break;
                }
            }
        }
    }

    // Gaps only make sense once a first frame has established the baseline, and the
    // publisher may already have been running when this subscription attached.
    if (expected_seq != 0 and seq > expected_seq) gaps += seq - expected_seq;
    expected_seq = seq + 1;

    return .{ .sent_us = sent_us, .payload_len = payload_len };
}

/// Re-decode one captured frame `iterations` times, to separate decoder cost from the
/// transport. Returns nanoseconds per frame.
fn decodeBenchmark(bytes: []const u8, iterations: usize) u64 {
    var checksum: u64 = 0;
    const start_us: u64 = @intCast(qnnt.nowMicros());

    for (0..iterations) |_| {
        const f = tld.decode(bytes) catch continue;
        var it = f.objectIterator() catch continue;
        while (it.next() catch continue) |pair| {
            checksum +%= pair.key.len;
            switch (pair.value.type) {
                .tinyuint, .int8, .int16, .int32, .int64 => checksum +%= pair.value.asUint() catch 0,
                .buffer => checksum +%= (pair.value.asBuffer() catch @as([]const u8, &.{})).len,
                else => {},
            }
        }
    }

    const elapsed_us: u64 = @as(u64, @intCast(qnnt.nowMicros())) -| start_us;
    std.mem.doNotOptimizeAway(checksum); // keep the loop from being elided
    return elapsed_us * 1000 / iterations;
}

/// Latency at the given percentile, from the histogram. Returns the bucket's upper
/// bound, so it reads as "at or below".
fn percentile(p: f64) u64 {
    var total: u64 = hist_overflow;
    for (hist) |count| total += count;
    if (total == 0) return 0;

    const target = @as(u64, @intFromFloat(@as(f64, @floatFromInt(total)) * p));
    var seen: u64 = 0;
    for (hist, 0..) |count, i| {
        seen += count;
        if (seen >= target) return (i + 1) * bucket_us;
    }
    return bucket_count * bucket_us; // in the overflow tail
}

fn report(now_us: u64) void {
    const elapsed_s = @as(f64, @floatFromInt(now_us -| window_start_us)) / 1_000_000.0;
    if (elapsed_s <= 0) return;

    const frames_f = @as(f64, @floatFromInt(window_frames));

    std.debug.print(
        "node-4 {d:.0} frames/s | wire {d:.1} KB/s payload {d:.1} KB/s | lat us min {d} mean {d:.0} p50 {d} p99 {d} max {d} | gaps {d} badpay {d} err {d} | {d} total\n",
        .{
            frames_f / elapsed_s,
            @as(f64, @floatFromInt(window_wire_bytes)) / elapsed_s / 1024.0,
            @as(f64, @floatFromInt(window_payload_bytes)) / elapsed_s / 1024.0,
            if (window_lat_min == std.math.maxInt(u64)) 0 else window_lat_min,
            if (window_frames == 0) 0 else @as(f64, @floatFromInt(window_lat_sum)) / frames_f,
            percentile(0.50),
            percentile(0.99),
            window_lat_max,
            gaps,
            bad_payloads,
            decode_errors,
            total_frames,
        },
    );

    window_frames = 0;
    window_wire_bytes = 0;
    window_payload_bytes = 0;
    window_lat_sum = 0;
    window_lat_min = std.math.maxInt(u64);
    window_lat_max = 0;
    window_start_us = now_us;
    hist = @splat(0);
    hist_overflow = 0;
}

fn onFrame(_: []const u8, f: tld.Frame, _: ?*anyopaque) void {
    const info = readFrame(f) catch {
        decode_errors += 1;
        return;
    };

    const now_us: u64 = @intCast(qnnt.nowMicros());
    // Wall clock, so it can step backwards; a negative interval reads as 0 rather
    // than wrapping into an absurd figure.
    const latency = now_us -| info.sent_us;

    total_frames += 1;
    window_frames += 1;
    window_wire_bytes += f.size();
    window_payload_bytes += info.payload_len;
    window_lat_sum += latency;
    window_lat_min = @min(window_lat_min, latency);
    window_lat_max = @max(window_lat_max, latency);

    const bucket = latency / bucket_us;
    if (bucket < bucket_count) hist[bucket] += 1 else hist_overflow += 1;

    if (f.raw.len <= sample.len) {
        @memcpy(sample[0..f.raw.len], f.raw);
        sample_len = f.raw.len;
    }

    if (window_start_us == 0) window_start_us = now_us;
    if (now_us -| window_start_us >= report_interval_us) report(now_us);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next(); // executable path

    if (args.next()) |a| {
        const ms = std.fmt.parseInt(u64, a, 10) catch 1000;
        report_interval_us = ms * 1000;
    }

    if (! qnnt.run()) {
        std.debug.print("failed to run QNNT\n", .{});
    }
    defer qnnt.deinit();

    qnnt.installSignalHandlers();

    std.debug.print("node-4 benchmarking {s} (mode {s}), reporting every {d} ms\n", .{
        topic,
        @tagName(@import("builtin").mode),
        report_interval_us / 1000,
    });

    if (! qnnt.subscribeFrames(topic, onFrame, null)) {
        std.debug.print("failed to subscribe to {s}\n", .{topic});
        return;
    }

    // The subscriber thread owns the live statistics and reports them itself. Main only
    // runs the decoder microbenchmark, which needs a captured frame and must not sit
    // on the delivery path.
    while (!qnnt.stopRequested()) {
        qnnt.sleepMs(5000);

        if (sample_len == 0) continue;

        // Copy out first: the handler thread keeps overwriting `sample`.
        const frozen = try allocator.alloc(u8, sample_len);
        defer allocator.free(frozen);
        const len = sample_len;
        @memcpy(frozen[0..len], sample[0..len]);

        const ns = decodeBenchmark(frozen[0..len], 200_000);
        std.debug.print("node-4 decoder: {d} ns/frame on a {d}B frame ({d:.1} M frames/s single-threaded)\n", .{
            ns,
            len,
            if (ns == 0) 0 else 1000.0 / @as(f64, @floatFromInt(ns)),
        });
    }
}
