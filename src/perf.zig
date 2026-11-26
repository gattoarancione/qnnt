//! qnnt-perf -- how topics are actually flowing.
//!
//!   qnnt-perf                         every topic, a live table on stderr
//!   qnnt-perf 'lidar/*' test/bench    only these
//!   qnnt-perf --duration 10 test/x    ten seconds, then the summary
//!   qnnt-perf test/x | awk ...        piped: tab-separated records on stdout instead
//!
//! Per topic and per interval: frames, frame rate (min / median / avg / max), frame size
//! (min / avg / max), bandwidth, missed frames, sequence resets, reconnects, and what the
//! registry says about the topic -- its subscriber count and whether it is live.
//!
//! Where the output goes follows qnnt-cat's rule, data to stdout and the rest to stderr,
//! read from the other side: a person at a terminal gets a table redrawn in place on
//! stderr, and a pipe gets records on stdout with no table in the way. --pretty and --tsv
//! override the guess.
//!
//! Rates come from the time between arrivals, on a monotonic clock, as this process sees
//! them. avg is frames over the interval; median, min and max come from the individual
//! gaps, so max is the tightest burst actually delivered -- frames that crossed the
//! network in one TCP segment arrive microseconds apart, and max says so.
//!
//! MISSES ARE ONLY MEASURABLE WHEN THE PAYLOAD COUNTS. qnnt delivers every frame on a
//! connection or drops the connection, so frames go missing only across a reconnect, and
//! nothing on the wire says how many. A TOLD object with an unsigned sequence field --
//! `seq`, or whatever --seq names -- says exactly: a jump from 41 to 45 is three misses.
//! A topic without one shows `-` for misses, which means unknown, not zero. A sequence
//! going backwards is counted as a reset, not as misses: that is a publisher restarting.
//!
//! FRAMING IS NOT RECORDED ANYWHERE, so it has to be chosen: TOLD frames by default, --text
//! for newline-delimited topics. A text topic read as TOLD does not fail cleanly -- "ciao!\n"
//! happens to parse as several tiny frames -- so the figures would be nonsense presented as
//! numbers. A topic whose bytes are all printable and carry newlines is flagged `text?`
//! instead, with a notice saying to measure it with --text.

const std = @import("std");
const root = @import("qnnt");
const qnnt = root.Qnnt;
const told = root.Told;
const stdout = @import("stdout");

const allocator = std.heap.page_allocator;

const max_topics = 256;
const max_pattern = 32;

var opt_text = false;
var opt_seq_key: ?[]const u8 = "seq";
var opt_interval_ms: u64 = 1000;
var opt_duration_s: u64 = 0;
var opt_rescan_ms: u64 = 1000;
var opt_quiet = false;

// -- intervals ---------------------------------------------------------------------------

/// Gaps between arrivals, in microseconds, binned log-linearly: 16 bins per power of two,
/// so any quantile it reports is within about 3% of the true one, in fixed memory however
/// many frames arrive. Exact below 16 us, where a bin is one microsecond wide.
const Histogram = struct {
    const sub_bits = 4;
    const sub = 1 << sub_bits;
    const bins = (64 - sub_bits + 1) * sub;

    counts: [bins]u32 = @splat(0),
    total: u64 = 0,

    fn index(us: u64) usize {
        if (us < sub) return @intCast(us);
        const exp: u6 = @intCast(63 - @clz(us));
        const mantissa = (us >> (exp - sub_bits)) & (sub - 1);
        return (@as(usize, exp) - sub_bits + 1) * sub + @as(usize, @intCast(mantissa));
    }

    /// The middle of bin `i`, which is what a quantile falling in it is reported as.
    fn value(i: usize) u64 {
        if (i < sub) return i;
        const row = i / sub;
        const exp: u6 = @intCast(row + sub_bits - 1);
        const width = @as(u64, 1) << (exp - sub_bits);
        const low = (@as(u64, sub) + i % sub) * width;
        return low + width / 2;
    }

    fn add(h: *Histogram, us: u64) void {
        h.counts[index(us)] += 1;
        h.total += 1;
    }

    fn merge(h: *Histogram, other: *const Histogram) void {
        for (&h.counts, other.counts) |*a, b| a.* += b;
        h.total += other.total;
    }

    fn quantile(h: *const Histogram, q: f64) ?u64 {
        if (h.total == 0) return null;
        const want: u64 = @max(1, @as(u64, @intFromFloat(@ceil(q * @as(f64, @floatFromInt(h.total))))));
        var seen: u64 = 0;
        for (h.counts, 0..) |n, i| {
            seen += n;
            if (seen >= want) return value(i);
        }
        return null;
    }
};

// -- what is collected -------------------------------------------------------------------

/// Figures for one topic over some span: an interval, or the whole run.
const Figures = struct {
    frames: u64 = 0,
    bytes: u64 = 0,
    size_min: u64 = std.math.maxInt(u64),
    size_max: u64 = 0,
    gap_min: u64 = std.math.maxInt(u64),
    gap_max: u64 = 0,
    gaps: Histogram = .{},
    /// Frames that carried the sequence field. Zero means misses cannot be known.
    sequenced: u64 = 0,
    misses: u64 = 0,
    resets: u64 = 0,
    reconnects: u64 = 0,

    fn addFrame(f: *Figures, size: u64, gap_us: ?u64) void {
        f.frames += 1;
        f.bytes += size;
        f.size_min = @min(f.size_min, size);
        f.size_max = @max(f.size_max, size);
        if (gap_us) |gap| {
            f.gap_min = @min(f.gap_min, gap);
            f.gap_max = @max(f.gap_max, gap);
            f.gaps.add(gap);
        }
    }

    fn merge(f: *Figures, o: *const Figures) void {
        f.frames += o.frames;
        f.bytes += o.bytes;
        f.size_min = @min(f.size_min, o.size_min);
        f.size_max = @max(f.size_max, o.size_max);
        f.gap_min = @min(f.gap_min, o.gap_min);
        f.gap_max = @max(f.gap_max, o.gap_max);
        f.gaps.merge(&o.gaps);
        f.sequenced += o.sequenced;
        f.misses += o.misses;
        f.resets += o.resets;
        f.reconnects += o.reconnects;
    }
};

/// What a sequence number says about the frames before it.
const SeqVerdict = union(enum) { first, next, missed: u64, reset };

/// Compare `seq` with the last one seen. Anything not ahead of the last is a reset rather
/// than a negative miss: within one connection TCP cannot reorder, so a sequence that goes
/// back is a publisher that started counting again -- and a repeated number is the same.
fn judgeSeq(last: ?u64, seq: u64) SeqVerdict {
    const prev = last orelse return .first;
    if (seq == prev +% 1) return .next;
    if (seq > prev) return .{ .missed = seq - prev - 1 };
    return .reset;
}

/// The unsigned `key` field of a top-level TOLD object, or null if the frame has none.
fn seqField(frame: told.Frame, key: []const u8) ?u64 {
    if (frame.type != .object) return null;
    var it = frame.objectIterator() catch return null;
    while (it.next() catch return null) |pair| {
        if (std.mem.eql(u8, pair.key, key)) return pair.value.asUint() catch null;
    }
    return null;
}

/// One topic. The subscriber thread writes `window` under the lock; the reporter swaps it
/// out once per interval and owns `total`, so the hot path never touches the whole-run
/// figures and the reporter never holds the lock for longer than a copy.
const Slot = struct {
    name: []const u8,
    mutex: std.Io.Mutex = .init,
    window: Figures = .{},
    last_arrival_us: ?u64 = null,
    last_seq: ?u64 = null,
    total: Figures = .{},
    first_arrival_us: ?u64 = null,
    /// See `Framing`. Written under the lock by the subscriber thread.
    printable_frames: u32 = 0,
    saw_binary: bool = false,
    saw_newline: bool = false,
    text_noticed: bool = false,
    /// Connections that broke over the whole run.
    breaks: u32 = 0,

    /// Whether a topic read as TOLD looks like newline-delimited text instead. Two ways to
    /// tell: enough printable frames with newlines in them, or -- when the text happens to
    /// trip the TOLD reader, which drops the connection -- a stream that keeps breaking
    /// while nothing it delivered was binary.
    fn looksLikeText(s: *const Slot) bool {
        if (s.saw_binary or s.printable_frames == 0) return false;
        if (s.saw_newline and s.printable_frames >= text_sniff_frames) return true;
        return s.breaks >= text_sniff_breaks;
    }
};

/// Frames seen before a topic read as TOLD is judged to be text in disguise.
const text_sniff_frames = 20;
/// Or broken connections, for text that the TOLD reader rejects after a frame or two.
const text_sniff_breaks = 2;

/// A frame's bytes are what text would be: printable ASCII and the whitespace a line
/// carries. Real TOLD rarely is -- a header byte, a length or a number is usually not.
fn isPrintable(bytes: []const u8) bool {
    for (bytes) |c| {
        if (!(c == '\t' or c == '\n' or c == '\r' or (c >= 0x20 and c < 0x7f))) return false;
    }
    return true;
}

var slots: [max_topics]*Slot = undefined;
var slot_count = std.atomic.Value(usize).init(0);
var slots_mutex: std.Io.Mutex = .init;
var slots_full_reported = std.atomic.Value(bool).init(false);

/// The slot for `topic`, created on first sight. Read without a lock: a slot is fully built
/// before the count that publishes it is stored, and nothing in it that the scan reads
/// changes afterwards.
fn slotFor(topic: []const u8) ?*Slot {
    if (find(topic, slot_count.load(.acquire))) |s| return s;

    slots_mutex.lockUncancelable(root.io);
    defer slots_mutex.unlock(root.io);

    const n = slot_count.load(.acquire);
    if (find(topic, n)) |s| return s; // another thread got here first
    if (n == max_topics) {
        if (!slots_full_reported.swap(true, .monotonic)) {
            std.debug.print("qnnt-perf: tracking {d} topics already; ignoring more\n", .{max_topics});
        }
        return null;
    }

    const slot = allocator.create(Slot) catch return null;
    const name = allocator.dupe(u8, topic) catch {
        allocator.destroy(slot);
        return null;
    };
    slot.* = .{ .name = name };
    slots[n] = slot;
    slot_count.store(n + 1, .release);
    return slot;
}

fn find(topic: []const u8, n: usize) ?*Slot {
    for (slots[0..n]) |s| {
        if (std.mem.eql(u8, s.name, topic)) return s;
    }
    return null;
}

fn monotonicUs() u64 {
    return @intCast(std.Io.Timestamp.now(root.io, .awake).toMicroseconds());
}

fn record(topic: []const u8, size: usize, seq: ?u64, bytes: ?[]const u8) void {
    const now = monotonicUs();
    const slot = slotFor(topic) orelse return;

    slot.mutex.lockUncancelable(root.io);
    defer slot.mutex.unlock(root.io);

    if (slot.first_arrival_us == null) slot.first_arrival_us = now;
    const gap = if (slot.last_arrival_us) |last| now -| last else null;
    slot.last_arrival_us = now;
    slot.window.addFrame(size, gap);

    if (bytes) |b| if (!slot.saw_binary) {
        if (isPrintable(b)) {
            slot.printable_frames +|= 1;
            if (std.mem.indexOfScalar(u8, b, '\n') != null) slot.saw_newline = true;
        } else {
            slot.saw_binary = true;
        }
        noticeText(slot);
    };

    if (seq) |s| {
        slot.window.sequenced += 1;
        switch (judgeSeq(slot.last_seq, s)) {
            .first, .next => {},
            .missed => |n| slot.window.misses += n,
            .reset => slot.window.resets += 1,
        }
        slot.last_seq = s;
    }
}

/// Once per topic, under the slot's lock.
fn noticeText(slot: *Slot) void {
    if (opt_text or slot.text_noticed or !slot.looksLikeText()) return;
    slot.text_noticed = true;
    if (!opt_quiet) std.debug.print(
        "qnnt-perf: {s} looks like newline-delimited text, so its TOLD figures are " ++
            "meaningless -- measure it with --text\n",
        .{slot.name},
    );
}

fn onFrame(topic: []const u8, frame: told.Frame, _: ?*anyopaque) void {
    const seq = if (opt_seq_key) |key| seqField(frame, key) else null;
    record(topic, frame.raw.len, seq, frame.raw);
}

fn onText(topic: []const u8, msg: []const u8, _: ?*anyopaque) void {
    record(topic, msg.len, null, null);
}

fn onEvent(event: qnnt.Event, topic: []const u8, _: []const u8, _: usize, _: ?*anyopaque) void {
    switch (event) {
        // A slot from the moment the stream attaches, so a topic that is connected but
        // silent still gets a row saying so.
        .publisher_connected => _ = slotFor(topic),
        .publisher_disconnected => if (slotFor(topic)) |slot| {
            slot.mutex.lockUncancelable(root.io);
            defer slot.mutex.unlock(root.io);
            slot.window.reconnects += 1;
            slot.breaks +|= 1;
            noticeText(slot);
            // The gap across a reconnect is the outage, not a frame interval.
            slot.last_arrival_us = null;
        },
        else => {},
    }
}

// -- the registry's view -----------------------------------------------------------------

const TopicState = struct {
    /// Subscribers as the publisher last reported them; null before its first report.
    subs: ?u64 = null,
    live: bool = false,
};

/// One data row of the registry's `list`: `  topic publisher subs refreshed age origin
/// state`. Header and notice lines start with '#'.
fn parseListRow(line: []const u8) ?struct { topic: []const u8, state: TopicState } {
    if (line.len == 0 or line[0] == '#') return null;
    var it = std.mem.tokenizeAny(u8, line, " \t\r\n");
    const topic = it.next() orelse return null;
    _ = it.next() orelse return null; // publisher
    const subs = it.next() orelse return null;
    _ = it.next() orelse return null; // refreshed
    _ = it.next() orelse return null; // age
    _ = it.next() orelse return null; // origin
    const state = it.next() orelse return null;
    return .{ .topic = topic, .state = .{
        .subs = std.fmt.parseInt(u64, subs, 10) catch null,
        .live = std.mem.eql(u8, state, "live"),
    } };
}

var list_reply: []u8 = &.{};

/// The registry's state for every topic it lists, keyed into `out` by slot index.
fn fetchStates(out: []TopicState, n: usize) bool {
    @memset(out[0..n], .{});
    const text = qnnt.registryCommand("list", list_reply) catch return false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const row = parseListRow(line) orelse continue;
        for (slots[0..n], 0..) |s, i| {
            if (std.mem.eql(u8, s.name, row.topic)) out[i] = row.state;
        }
    }
    return true;
}

// -- figures to numbers ------------------------------------------------------------------

/// Everything one output row needs, already worked out.
const Row = struct {
    topic: []const u8,
    frames: u64,
    hz_min: ?f64,
    hz_med: ?f64,
    hz_avg: f64,
    hz_max: ?f64,
    size_min: ?u64,
    size_avg: ?f64,
    size_max: ?u64,
    bandwidth: f64,
    misses: ?u64,
    resets: ?u64,
    reconnects: u64,
    state: TopicState,
    framing: []const u8,
};

fn hzOf(gap_us: u64) f64 {
    // A gap of zero is two frames in the same microsecond; reported as 1 MHz rather than
    // infinity, which is what that clock can resolve.
    return 1e6 / @as(f64, @floatFromInt(@max(gap_us, 1)));
}

fn rowOf(topic: []const u8, f: *const Figures, span_us: u64, state: TopicState, framing: []const u8) Row {
    const span_s = @as(f64, @floatFromInt(@max(span_us, 1))) / 1e6;
    const have_gaps = f.gaps.total > 0;
    return .{
        .topic = topic,
        .frames = f.frames,
        .hz_min = if (have_gaps) hzOf(f.gap_max) else null,
        .hz_med = if (f.gaps.quantile(0.5)) |m| hzOf(m) else null,
        .hz_avg = @as(f64, @floatFromInt(f.frames)) / span_s,
        .hz_max = if (have_gaps) hzOf(f.gap_min) else null,
        .size_min = if (f.frames > 0) f.size_min else null,
        .size_avg = if (f.frames > 0) @as(f64, @floatFromInt(f.bytes)) / @as(f64, @floatFromInt(f.frames)) else null,
        .size_max = if (f.frames > 0) f.size_max else null,
        .bandwidth = @as(f64, @floatFromInt(f.bytes)) / span_s,
        .misses = if (f.sequenced > 0) f.misses else null,
        .resets = if (f.sequenced > 0) f.resets else null,
        .reconnects = f.reconnects,
        .state = state,
        .framing = framing,
    };
}

/// A number scaled to k/M/G with one decimal, or "-" when there is none.
fn scaled(buf: []u8, v: ?f64, unit: []const u8) []const u8 {
    const x = v orelse return "-";
    const steps = [_]struct { at: f64, suffix: []const u8 }{
        .{ .at = 1e9, .suffix = "G" },
        .{ .at = 1e6, .suffix = "M" },
        .{ .at = 1e3, .suffix = "k" },
    };
    for (steps) |s| {
        if (x >= s.at) return std.fmt.bufPrint(buf, "{d:.1}{s}{s}", .{ x / s.at, s.suffix, unit }) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d:.1}{s}", .{ x, unit }) catch "?";
}

fn count(buf: []u8, v: ?u64) []const u8 {
    const x = v orelse return "-";
    return std.fmt.bufPrint(buf, "{d}", .{x}) catch "?";
}

fn asF64(v: ?u64) ?f64 {
    return if (v) |x| @floatFromInt(x) else null;
}

// -- pretty, on stderr -------------------------------------------------------------------

const columns = [_]struct { name: []const u8, width: usize }{
    .{ .name = "frames", .width = 8 },
    .{ .name = "Hz min", .width = 8 },
    .{ .name = "med", .width = 8 },
    .{ .name = "avg", .width = 8 },
    .{ .name = "max", .width = 8 },
    .{ .name = "size min", .width = 9 },
    .{ .name = "avg", .width = 8 },
    .{ .name = "max", .width = 8 },
    .{ .name = "bandwidth", .width = 11 },
    .{ .name = "miss", .width = 6 },
    .{ .name = "reset", .width = 6 },
    .{ .name = "reconn", .width = 7 },
    .{ .name = "subs", .width = 5 },
    .{ .name = "state", .width = 6 },
    .{ .name = "fmt", .width = 5 },
};

fn pad(out: *std.ArrayList(u8), text: []const u8, width: usize, right: bool) void {
    const fill = width -| text.len;
    if (right) out.appendNTimes(allocator, ' ', fill) catch {};
    out.appendSlice(allocator, text) catch {};
    if (!right) out.appendNTimes(allocator, ' ', fill) catch {};
}

fn prettyRow(out: *std.ArrayList(u8), r: Row, topic_width: usize) void {
    var b: [15][24]u8 = undefined;
    const cells = [_][]const u8{
        count(&b[0], r.frames),
        scaled(&b[1], r.hz_min, ""),
        scaled(&b[2], r.hz_med, ""),
        scaled(&b[3], r.hz_avg, ""),
        scaled(&b[4], r.hz_max, ""),
        scaled(&b[5], asF64(r.size_min), "B"),
        scaled(&b[6], r.size_avg, "B"),
        scaled(&b[7], asF64(r.size_max), "B"),
        scaled(&b[8], r.bandwidth, "B/s"),
        count(&b[9], r.misses),
        count(&b[10], r.resets),
        count(&b[11], r.reconnects),
        count(&b[12], r.state.subs),
        stateText(r.state),
        r.framing,
    };
    pad(out, r.topic, topic_width, false);
    for (cells, columns) |cell, col| {
        out.append(allocator, ' ') catch {};
        pad(out, cell, col.width, !leftAligned(col.name));
    }
    out.append(allocator, '\n') catch {};
}

fn prettyHeader(out: *std.ArrayList(u8), topic_width: usize) void {
    pad(out, "topic", topic_width, false);
    for (columns) |col| {
        out.append(allocator, ' ') catch {};
        pad(out, col.name, col.width, !leftAligned(col.name));
    }
    out.append(allocator, '\n') catch {};
}

fn leftAligned(name: []const u8) bool {
    return std.mem.eql(u8, name, "state") or std.mem.eql(u8, name, "fmt");
}

fn stateText(state: TopicState) []const u8 {
    if (state.subs == null and !state.live) return "-";
    return if (state.live) "live" else "stale";
}

/// Lines the last live table took, so the next one can be drawn over it.
var drawn_lines: usize = 0;

fn writeStderr(bytes: []const u8) void {
    var at: usize = 0;
    while (at < bytes.len) {
        const n = std.c.write(2, bytes[at..].ptr, bytes.len - at);
        if (n > 0) {
            at += @intCast(n);
        } else if (n < 0 and std.posix.errno(n) == .INTR) {
            continue;
        } else return;
    }
}

fn drawTable(rows: []const Row, title: []const u8, redraw: bool) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    // Back over the previous table and clear it, so the live view stays in place instead
    // of scrolling one table per interval. Only when stderr is a terminal: in a log file
    // those escapes would be garbage, and every table is kept instead.
    if (redraw and drawn_lines > 0) {
        out.print(allocator, "\x1b[{d}F\x1b[J", .{drawn_lines}) catch {};
    }

    var width: usize = "topic".len;
    for (rows) |r| width = @max(width, r.topic.len);

    out.appendSlice(allocator, title) catch {};
    out.append(allocator, '\n') catch {};
    prettyHeader(&out, width);
    for (rows) |r| prettyRow(&out, r, width);
    if (rows.len == 0) out.appendSlice(allocator, "  (nothing has arrived yet)\n") catch {};

    drawn_lines = 2 + @max(rows.len, 1);
    writeStderr(out.items);
}

// -- records, on stdout ------------------------------------------------------------------

const tsv_header = "# scope\telapsed_s\ttopic\tframes\thz_min\thz_med\thz_avg\thz_max\t" ++
    "size_min\tsize_avg\tsize_max\tbytes_per_s\tmisses\tresets\treconnects\tsubs\tstate\tframing\n";

fn optF(buf: []u8, v: ?f64) []const u8 {
    const x = v orelse return "-";
    return std.fmt.bufPrint(buf, "{d:.3}", .{x}) catch "?";
}

/// One record: plain numbers in base units -- Hz, bytes, bytes per second -- and `-` for a
/// figure that is not known, which is a different fact from zero.
fn tsvRow(out: *std.ArrayList(u8), scope: []const u8, elapsed_s: f64, r: Row) void {
    var b: [12][32]u8 = undefined;
    out.print(allocator, "{s}\t{d:.3}\t{s}\t{d}\t{s}\t{s}\t{d:.3}\t{s}\t{s}\t{s}\t{s}\t{d:.3}\t{s}\t{s}\t{d}\t{s}\t{s}\t{s}\n", .{
        scope,
        elapsed_s,
        r.topic,
        r.frames,
        optF(&b[0], r.hz_min),
        optF(&b[1], r.hz_med),
        r.hz_avg,
        optF(&b[2], r.hz_max),
        count(&b[3], r.size_min),
        optF(&b[4], r.size_avg),
        count(&b[5], r.size_max),
        r.bandwidth,
        count(&b[6], r.misses),
        count(&b[7], r.resets),
        r.reconnects,
        count(&b[8], r.state.subs),
        stateText(r.state),
        r.framing,
    }) catch {};
}

// -- the run -----------------------------------------------------------------------------

/// What the figures were read as. `text?` is a TOLD read that looks like text in disguise.
fn framingOf(s: *Slot) []const u8 {
    if (opt_text) return "text";
    s.mutex.lockUncancelable(root.io);
    defer s.mutex.unlock(root.io);
    return if (s.looksLikeText()) "text?" else "told";
}

fn subscribeAll(patterns: []const []const u8) void {
    for (patterns) |p| {
        const ok = if (root.topics.hasWildcard(p)) blk: {
            break :blk if (opt_text)
                qnnt.subscribePattern(p, onText, null, opt_rescan_ms)
            else
                qnnt.subscribePatternFrames(p, onFrame, null, opt_rescan_ms);
        } else blk: {
            // Copied: the library keeps the topic for the life of the subscription.
            const owned = allocator.dupe(u8, p) catch break :blk false;
            break :blk if (opt_text)
                qnnt.subscribe(owned, onText, null)
            else
                qnnt.subscribeFrames(owned, onFrame, null);
        };
        if (!ok) std.debug.print("qnnt-perf: could not subscribe to {s}\n", .{p});
    }
}

fn usage() void {
    std.debug.print(
        \\usage: qnnt-perf [options] [pattern]...
        \\
        \\  [pattern]...      topic names or globs; every topic if none given. QUOTE globs.
        \\
        \\  --interval <ms>   how often to report (default 1000)
        \\  --duration <s>    stop after this long and print the summary (default: until ^C)
        \\  --seq <field>     the TOLD object field that counts frames, for misses (default seq)
        \\  --no-seq          do not look for one; misses are reported as unknown
        \\  --text            newline-delimited topics instead of TOLD frames
        \\  --rescan <ms>     how often to re-match globs (default 1000; 0 matches once)
        \\  --pretty          the live table on stderr, even when stdout is piped
        \\  --tsv             tab-separated records on stdout, even at a terminal
        \\  --quiet           no notices on stderr
        \\
        \\At a terminal: a live table on stderr, and a summary when it ends. Piped: one
        \\record per topic per interval on stdout, then one 'total' record per topic:
        \\
        \\  scope elapsed_s topic frames hz_min hz_med hz_avg hz_max size_min size_avg
        \\  size_max bytes_per_s misses resets reconnects subs state framing
        \\
        \\Base units throughout, and '-' for a figure that is not known. Misses need a
        \\sequence field in the payload: without one they cannot be counted, and show '-'.
        \\
        \\Framing is not recorded anywhere, so pick it: TOLD by default, --text for line
        \\topics. A text topic read as TOLD is flagged 'text?' rather than measured as frames.
        \\
    , .{});
}

const Mode = enum { auto, pretty, tsv };

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();

    var patterns: [max_pattern][]const u8 = undefined;
    var pattern_count: usize = 0;
    var mode: Mode = .auto;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--interval")) {
            opt_interval_ms = std.fmt.parseInt(u64, args.next() orelse return usage(), 10) catch return usage();
            if (opt_interval_ms == 0) return usage();
        } else if (std.mem.eql(u8, arg, "--duration")) {
            opt_duration_s = std.fmt.parseInt(u64, args.next() orelse return usage(), 10) catch return usage();
        } else if (std.mem.eql(u8, arg, "--seq")) {
            opt_seq_key = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--no-seq")) {
            opt_seq_key = null;
        } else if (std.mem.eql(u8, arg, "--text")) {
            opt_text = true;
        } else if (std.mem.eql(u8, arg, "--rescan")) {
            opt_rescan_ms = std.fmt.parseInt(u64, args.next() orelse return usage(), 10) catch return usage();
        } else if (std.mem.eql(u8, arg, "--pretty")) {
            mode = .pretty;
        } else if (std.mem.eql(u8, arg, "--tsv")) {
            mode = .tsv;
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            opt_quiet = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return usage();
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("qnnt-perf: unknown option '{s}'\n\n", .{arg});
            return usage();
        } else {
            if (pattern_count == max_pattern) {
                std.debug.print("qnnt-perf: at most {d} patterns\n", .{max_pattern});
                return;
            }
            patterns[pattern_count] = arg;
            pattern_count += 1;
        }
    }
    if (pattern_count == 0) {
        patterns[0] = "*";
        pattern_count = 1;
    }

    // The guess the flags override: a terminal on stdout means a person is watching.
    const tsv = switch (mode) {
        .tsv => true,
        .pretty => false,
        .auto => std.c.isatty(1) == 0,
    };
    const redraw = !tsv and std.c.isatty(2) != 0;

    list_reply = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(list_reply);

    // Every QNNT_* variable, handled by the library so all four languages agree.
    qnnt.configureFromEnvironment();

    if (!qnnt.run()) {
        std.debug.print("qnnt-perf: failed to start\n", .{});
        return;
    }
    defer qnnt.deinit();

    qnnt.installSignalHandlers();
    qnnt.setEventHandler(onEvent, null);
    defer stdout.flush();

    subscribeAll(patterns[0..pattern_count]);

    if (tsv) {
        stdout.write(tsv_header);
        stdout.flush();
    }

    const start_us = monotonicUs();
    var window_start_us = start_us;
    var states: [max_topics]TopicState = undefined;
    var rows: [max_topics]Row = undefined;
    var window: Figures = undefined;

    while (true) {
        // Sleep to the end of the interval in short slices, so ^C and --duration end it
        // promptly rather than after a whole interval.
        const deadline = window_start_us + opt_interval_ms * 1000;
        var stopping = false;
        while (monotonicUs() < deadline) {
            if (qnnt.stopRequested()) {
                stopping = true;
                break;
            }
            if (opt_duration_s != 0 and monotonicUs() - start_us >= opt_duration_s * 1_000_000) {
                stopping = true;
                break;
            }
            qnnt.sleepMs(@min(50, (deadline -| monotonicUs()) / 1000 + 1));
        }

        const now = monotonicUs();
        const span = now - window_start_us;
        window_start_us = now;
        const elapsed_s = @as(f64, @floatFromInt(now - start_us)) / 1e6;

        const n = slot_count.load(.acquire);
        _ = fetchStates(&states, n);

        for (slots[0..n], 0..) |s, i| {
            s.mutex.lockUncancelable(root.io);
            window = s.window;
            s.window = .{};
            s.mutex.unlock(root.io);

            s.total.merge(&window);
            rows[i] = rowOf(s.name, &window, span, states[i], framingOf(s));
        }

        // A stop that lands just after an interval ended leaves a sliver of one: a frame
        // over two milliseconds, reported as a rate. Its figures still go into the totals
        // above; it is only not shown as an interval of its own.
        const sliver = stopping and span * 10 < opt_interval_ms * 1000;
        if (sliver) {
            // nothing to draw
        } else if (tsv) {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(allocator);
            for (rows[0..n]) |r| tsvRow(&out, "interval", elapsed_s, r);
            stdout.write(out.items);
            stdout.flush();
        } else {
            var title: [128]u8 = undefined;
            const text = std.fmt.bufPrint(&title, "qnnt-perf  {d} topic(s)  last {d:.1}s  running {d:.0}s", .{
                n, @as(f64, @floatFromInt(span)) / 1e6, elapsed_s,
            }) catch "qnnt-perf";
            drawTable(rows[0..n], text, redraw);
        }

        if (stopping) break;
    }

    // The whole run, per topic, over the time since its first frame: a topic that joined
    // late is not averaged over a stretch it was not there for.
    const end_us = monotonicUs();
    const elapsed_s = @as(f64, @floatFromInt(end_us - start_us)) / 1e6;
    const n = slot_count.load(.acquire);
    for (slots[0..n], 0..) |s, i| {
        const since = s.first_arrival_us orelse start_us;
        rows[i] = rowOf(s.name, &s.total, end_us -| since, states[i], framingOf(s));
    }

    if (tsv) {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        for (rows[0..n]) |r| tsvRow(&out, "total", elapsed_s, r);
        stdout.write(out.items);
    } else {
        var title: [128]u8 = undefined;
        const text = std.fmt.bufPrint(&title, "qnnt-perf  summary over {d:.1}s, from each topic's first frame", .{
            elapsed_s,
        }) catch "qnnt-perf summary";
        // Drawn below the live table rather than over it: the last interval stays visible
        // above the whole-run figures.
        drawn_lines = 0;
        drawTable(rows[0..n], text, false);
    }
}

// -- tests ----------------------------------------------------------------------------

const testing = std.testing;

test "the histogram is exact below 16 us and within its bin width above" {
    for (0..16) |v| {
        try testing.expectEqual(@as(u64, v), Histogram.value(Histogram.index(v)));
    }
    // Every value lands in a bin whose reported middle is within ~3% of it.
    const samples = [_]u64{ 16, 17, 31, 32, 100, 1000, 9_999, 10_000, 1_000_000, 123_456_789 };
    for (samples) |v| {
        const reported = Histogram.value(Histogram.index(v));
        const err = @abs(@as(f64, @floatFromInt(reported)) - @as(f64, @floatFromInt(v)));
        try testing.expect(err <= @as(f64, @floatFromInt(v)) * 0.035);
    }
    // The largest gap still has a bin.
    try testing.expect(Histogram.index(std.math.maxInt(u64)) < Histogram.bins);
}

test "the median comes from the middle of the gaps, not their mean" {
    var h: Histogram = .{};
    // Nine steady 10 ms gaps and one 2 s stall: the mean is ~209 ms, the median is 10 ms.
    for (0..9) |_| h.add(10_000);
    h.add(2_000_000);
    const med = h.quantile(0.5).?;
    try testing.expect(med >= 9_700 and med <= 10_300);

    var empty: Histogram = .{};
    try testing.expect(empty.quantile(0.5) == null);
}

test "a sequence counts what is missing, and a step back is a reset" {
    try testing.expectEqual(SeqVerdict.first, judgeSeq(null, 7));
    try testing.expectEqual(SeqVerdict.next, judgeSeq(7, 8));
    try testing.expectEqual(SeqVerdict{ .missed = 3 }, judgeSeq(41, 45));
    // A publisher restarting from 1, and a repeat: neither is a negative miss.
    try testing.expectEqual(SeqVerdict.reset, judgeSeq(900, 1));
    try testing.expectEqual(SeqVerdict.reset, judgeSeq(5, 5));
    // Counting through the top of u64 is the next frame, not a reset.
    try testing.expectEqual(SeqVerdict.next, judgeSeq(std.math.maxInt(u64), 0));
}

test "the seq field is read from a TOLD object, and only from one" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var enc = told.Encoder.init(testing.allocator, &buf);
    const obj = enc.beginObject();
    try enc.writeKey("t");
    try enc.writeUint(99);
    try enc.writeKey("seq");
    try enc.writeUint(42);
    try enc.end(obj);
    const frame = try told.validate(buf.items, 32);
    try testing.expectEqual(@as(?u64, 42), seqField(frame, "seq"));
    try testing.expectEqual(@as(?u64, 99), seqField(frame, "t"));
    try testing.expect(seqField(frame, "nope") == null);

    buf.clearRetainingCapacity();
    var enc2 = told.Encoder.init(testing.allocator, &buf);
    try enc2.writeUint(42); // a bare number is not a sequenced frame
    try testing.expect(seqField(try told.validate(buf.items, 32), "seq") == null);
}

test "figures turn into rates, sizes and bandwidth" {
    var f: Figures = .{};
    f.addFrame(100, null); // the first frame has no gap before it
    f.addFrame(300, 10_000);
    f.addFrame(200, 20_000);
    const r = rowOf("t", &f, 1_000_000, .{}, "told");

    try testing.expectEqual(@as(u64, 3), r.frames);
    try testing.expectApproxEqAbs(@as(f64, 3.0), r.hz_avg, 1e-9);
    try testing.expectApproxEqRel(@as(f64, 50.0), r.hz_min.?, 1e-9); // the 20 ms gap
    try testing.expectApproxEqRel(@as(f64, 100.0), r.hz_max.?, 1e-9); // the 10 ms gap
    try testing.expectEqual(@as(?u64, 100), r.size_min);
    try testing.expectEqual(@as(?u64, 300), r.size_max);
    try testing.expectApproxEqAbs(@as(f64, 200.0), r.size_avg.?, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 600.0), r.bandwidth, 1e-9);
    // Nothing carried a sequence field, so misses are unknown rather than zero.
    try testing.expect(r.misses == null);

    // An interval with nothing in it has no rates to speak of, and says so.
    const quiet = rowOf("t", &Figures{}, 1_000_000, .{}, "told");
    try testing.expect(quiet.hz_min == null and quiet.hz_med == null and quiet.size_avg == null);
    try testing.expectEqual(@as(f64, 0), quiet.hz_avg);
}

test "merging intervals gives the whole run" {
    var a: Figures = .{};
    a.addFrame(10, 1000);
    a.sequenced = 1;
    a.misses = 2;
    var b: Figures = .{};
    b.addFrame(50, 5000);
    b.reconnects = 1;
    var total: Figures = .{};
    total.merge(&a);
    total.merge(&b);
    try testing.expectEqual(@as(u64, 2), total.frames);
    try testing.expectEqual(@as(u64, 10), total.size_min);
    try testing.expectEqual(@as(u64, 50), total.size_max);
    try testing.expectEqual(@as(u64, 1000), total.gap_min);
    try testing.expectEqual(@as(u64, 5000), total.gap_max);
    try testing.expectEqual(@as(u64, 2), total.gaps.total);
    try testing.expectEqual(@as(u64, 2), total.misses);
    try testing.expectEqual(@as(u64, 1), total.reconnects);
}

test "a registry list row gives the subscriber count and the state" {
    const row = parseListRow("  test/topic-a  tcp://127.0.0.1:65312  3     1.3s       68m17s     local     live").?;
    try testing.expectEqualStrings("test/topic-a", row.topic);
    try testing.expectEqual(@as(?u64, 3), row.state.subs);
    try testing.expect(row.state.live);

    // "-" is the registry saying the publisher has not reported yet: unknown, kept unknown.
    const unknown = parseListRow("  x  tcp://1.2.3.4:5  -  0.1s  1s  local  stale").?;
    try testing.expect(unknown.state.subs == null);
    try testing.expect(!unknown.state.live);

    try testing.expect(parseListRow("# topic publisher subs refreshed age origin state") == null);
    try testing.expect(parseListRow("") == null);
    try testing.expect(parseListRow("  too few columns") == null);
}

test "numbers scale to k and M, and an unknown is a dash" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("999.0", scaled(&buf, 999.0, ""));
    try testing.expectEqualStrings("1.5kB/s", scaled(&buf, 1500.0, "B/s"));
    try testing.expectEqualStrings("117.7MB/s", scaled(&buf, 117.67e6, "B/s"));
    try testing.expectEqualStrings("-", scaled(&buf, null, "B"));
}

test "a record has every column, in base units, with dashes for unknowns" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var f: Figures = .{};
    f.addFrame(100, null);
    tsvRow(&out, "interval", 1.0, rowOf("test/x", &f, 1_000_000, .{}, "told"));

    const header_fields = std.mem.count(u8, tsv_header, "\t") + 1;
    try testing.expectEqual(header_fields, std.mem.count(u8, out.items, "\t") + 1);
    try testing.expect(std.mem.startsWith(u8, out.items, "interval\t1.000\ttest/x\t1\t-\t-\t1.000\t-\t100\t"));
    try testing.expect(std.mem.endsWith(u8, out.items, "\t-\t-\t0\t-\t-\ttold\n"));
}

test "text read as TOLD is recognised, and real TOLD is not" {
    try testing.expect(isPrintable("ciao!\n"));
    try testing.expect(!isPrintable(&.{ 0x41, 0x00, 0x0a }));

    var text: Slot = .{ .name = "t" };
    text.printable_frames = text_sniff_frames;
    text.saw_newline = true;
    try testing.expect(text.looksLikeText());

    // Printable but never a newline: a TOLD topic of short strings could be that, and is
    // not called text on so little.
    var strings: Slot = .{ .name = "s" };
    strings.printable_frames = 1000;
    try testing.expect(!strings.looksLikeText());

    // One binary frame settles it for good.
    var binary: Slot = .{ .name = "b" };
    binary.printable_frames = 1000;
    binary.saw_newline = true;
    binary.saw_binary = true;
    try testing.expect(!binary.looksLikeText());

    // Text the reader rejects outright: a frame or two, then the stream breaks, repeatedly.
    var rejected: Slot = .{ .name = "r" };
    rejected.printable_frames = 1;
    rejected.breaks = text_sniff_breaks;
    try testing.expect(rejected.looksLikeText());
    // A binary stream that breaks is just a flaky publisher.
    rejected.saw_binary = true;
    try testing.expect(!rejected.looksLikeText());

    // And too few frames to judge is not a verdict either.
    var early: Slot = .{ .name = "e" };
    early.printable_frames = text_sniff_frames - 1;
    early.saw_newline = true;
    try testing.expect(!early.looksLikeText());
}
