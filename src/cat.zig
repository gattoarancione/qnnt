//! qnnt-cat -- topic data to stdout, or stdin to a topic.
//!
//!   qnnt-cat 'lidar/*'                       decoded, to stdout
//!   qnnt-cat --hex test/bench                one hex line per message
//!   qnnt-cat --raw test/bench > cap.bin      the frames, verbatim
//!   qnnt-cat --publish --raw test/bench < cap.bin    replay that capture, unpaced
//!   qnnt-cat --dump 'lidar/*' > cap.tld      capture with arrival times and topics
//!   qnnt-cat --restore < cap.tld             replay it at the pace it was recorded
//!   qnnt-cat --publish test/notes            each stdin line becomes a message
//!
//! Data goes to STDOUT and everything else to stderr, so a redirect or a pipe carries only
//! the payload. That is the whole reason this is its own command rather than a flag on
//! qnnt-ls: one of them writes data, the other writes a report about data.
//!
//! Capture and replay round-trip without a side-channel because a TLD frame carries its own
//! length -- `tld.frameSize` finds the boundary -- so a file of concatenated frames needs no
//! index and no separators. Text topics are newline-delimited and self-describing the same
//! way, under --text.
//!
//! Globs work in the reading direction only. A glob is matched against the registry's list
//! of topics that EXIST, and publishing to a topic that already exists is not what --publish
//! is for, so a wildcard there is refused rather than quietly matching nothing.

const std = @import("std");
const root = @import("qnnt");
const qnnt = root.Qnnt;
const tld = root.Tld;
const stdout = @import("stdout");

const allocator = std.heap.page_allocator;

const max_topics = 256;
const max_pattern = 32;

/// How a message is rendered on the way out, and expected on the way in.
///
/// `raw` and `dump` are both round-trippable, and they trade different things. `raw` is the
/// payload and nothing else: perfect fidelity for one topic, but a capture over a glob merges
/// several topics into one stream with no way to tell them apart, and nothing records when
/// anything arrived, so a replay runs as fast as the pipe allows. `dump` wraps each message
/// in a small TLD envelope carrying the arrival time and the topic, which costs a few bytes
/// and buys back both -- and `--restore` is the only thing that reads it.
const Format = enum { decoded, hex, raw, dump };

var opt_format: Format = .decoded;
var opt_text = false;
var opt_time = false;
var opt_quiet = false;
var opt_max: u64 = 0;
var opt_rescan_ms: u64 = 1000;

/// Period divider. 1.0 leaves timing alone; 4.0 divides every interval by four, so the
/// stream runs four times faster; 0.25 divides by a quarter, so four times slower. It reads
/// the same on both sides: on --dump it scales the intervals recorded, on --restore the
/// intervals waited, and the two compose.
var opt_throttle: f64 = 1.0;

/// Base for --dump's timestamps: the first arrival. Intervals are scaled relative to it,
/// because multiplying an absolute epoch time by the throttle would move the capture to
/// some point in the next century. Set once by whichever subscriber thread gets there
/// first -- with a glob there are several, and they all need the same origin.
var dump_base_us = std.atomic.Value(u64).init(0);

var seen = std.atomic.Value(u64).init(0);
var limit_reached = std.atomic.Value(bool).init(false);

/// One subscriber thread per topic, all writing to the same fd: without this a glob over
/// five topics interleaves two messages inside one line.
var out_mutex: std.Io.Mutex = .init;

fn writeOut(bytes: []const u8) void {
    // Uncancelable, like the library's own locks: this runs on a subscriber thread during
    // shutdown too, and a cancelled lock there would drop the message being written.
    out_mutex.lockUncancelable(root.io);
    defer out_mutex.unlock(root.io);
    stdout.write(bytes);
    // Flushed per message rather than on a timer: this is the tail of a pipe, and a
    // consumer like `head` or a waiting shell should see a message when it happens, not
    // when a buffer fills.
    stdout.flush();
}

/// Count one message and say whether to emit it. The limit is enforced here rather than in
/// main, which spends its time asleep between rescans -- a 1 kHz topic delivers thousands
/// of messages inside one of those sleeps.
/// An interval under the throttle, which divides it. Separate and exact at 1.0: the common
/// case must not be nudged by a float round trip, or a dump taken without --throttle would
/// not carry the arrival times it claims to.
fn scaleInterval(delta_us: u64, throttle: f64) u64 {
    if (throttle == 1.0) return delta_us;
    const scaled = @as(f64, @floatFromInt(delta_us)) / throttle;
    if (!(scaled > 0.0)) return 0;
    // A throttle big enough to overflow is a typo, not an intention.
    if (scaled >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) return std.math.maxInt(u64);
    return @intFromFloat(scaled);
}

fn countMessage() bool {
    const n = seen.fetchAdd(1, .monotonic) + 1;
    if (opt_max == 0) return true;
    if (n > opt_max) return false;
    if (n == opt_max) limit_reached.store(true, .release);
    return true;
}

/// One captured message as a TLD object: {t, topic, data}.
///
/// A TLD frame rather than a format of its own, because then a capture is still a stream of
/// TLD frames -- `frameSize` splits it, `qnnt-cat --hex` reads it, and any language with a
/// TLD decoder can too. The timestamp is when this process received the message, which is
/// what reproduces the pace actually observed; a publish time inside someone's payload is
/// their schema's business, not the envelope's.
fn writeEnvelope(topic: []const u8, bytes: []const u8) void {
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(allocator);

    const now: u64 = @intCast(qnnt.nowMicros());
    _ = dump_base_us.cmpxchgStrong(0, now, .monotonic, .monotonic);
    const base = dump_base_us.load(.monotonic);
    const stamp = base + scaleInterval(now -| base, opt_throttle);

    var enc = tld.Encoder.init(allocator, &frame);
    const obj = enc.beginObject();
    enc.writeKey("t") catch return;
    enc.writeUint(stamp) catch return;
    enc.writeKey("topic") catch return;
    enc.writeString(topic) catch return;
    enc.writeKey("data") catch return;
    enc.writeBuffer(bytes) catch return;
    enc.end(obj) catch return;

    writeOut(frame.items);
}

fn emit(topic: []const u8, bytes: []const u8, frame: ?tld.Frame) void {
    if (opt_format == .dump) {
        writeEnvelope(topic, bytes);
        return;
    }
    if (opt_format == .raw) {
        // No topic, no timestamp, no separator: the point of --raw is that what comes out
        // is exactly what was on the wire, so it can go back in.
        writeOut(bytes);
        return;
    }

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);

    if (opt_time) {
        const us: u64 = @intCast(qnnt.nowMicros());
        line.print(allocator, "{d}.{d:0>6} ", .{ us / 1_000_000, us % 1_000_000 }) catch {};
    }
    line.print(allocator, "{s} ", .{topic}) catch {};

    switch (opt_format) {
        .hex => for (bytes) |b| line.print(allocator, "{x:0>2}", .{b}) catch {},
        .decoded => if (frame) |f| {
            if (stringifyFrame(f)) |text| {
                defer allocator.free(text);
                line.appendSlice(allocator, text) catch {};
            } else {
                line.print(allocator, "<{d} bytes, undecodable>", .{bytes.len}) catch {};
            }
        } else {
            appendText(&line, bytes);
        },
        .raw, .dump => unreachable, // handled above
    }

    line.append(allocator, '\n') catch {};
    writeOut(line.items);
}

fn onFrame(topic: []const u8, frame: tld.Frame, _: ?*anyopaque) void {
    if (!countMessage()) return;
    emit(topic, frame.raw, frame);
}

fn onText(topic: []const u8, msg: []const u8, _: ?*anyopaque) void {
    if (!countMessage()) return;
    emit(topic, msg, null);
}

/// A frame to text. The depth bound is what keeps a deeply nested payload from recursing
/// this process through its stack -- the frame arrives from the network and its shape is
/// not this tool's to trust.
fn stringifyFrame(frame: tld.Frame) ?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    tld.stringify(frame, allocator, &out, 32) catch {
        out.deinit(allocator);
        return null;
    };
    return out.toOwnedSlice(allocator) catch null;
}

/// Text with the trailing newline trimmed and interior control bytes escaped, so one
/// message stays one line however it was framed.
fn appendText(out: *std.ArrayList(u8), msg: []const u8) void {
    const body = std.mem.trimEnd(u8, msg, "\r\n");
    for (body) |c| {
        switch (c) {
            '\n' => out.appendSlice(allocator, "\\n") catch {},
            '\r' => out.appendSlice(allocator, "\\r") catch {},
            '\t' => out.appendSlice(allocator, "\\t") catch {},
            else => out.append(allocator, c) catch {},
        }
    }
}

// -- reading -----------------------------------------------------------------------------

// Only the literal names on the command line come through here now; globs are joined
// inside the library, which keeps its own list and its own cap.
var joined_count: usize = 0;

fn join(topic: []const u8) void {
    if (joined_count == max_topics) return;

    // Copied because the library retains the topic string for the life of the subscription,
    // and the caller's slice points into the argument buffer.
    const owned = allocator.dupe(u8, topic) catch return;
    const ok = if (opt_text)
        qnnt.subscribe(owned, onText, null)
    else
        qnnt.subscribeFrames(owned, onFrame, null);

    if (!ok) {
        std.debug.print("qnnt-cat: could not subscribe to {s}\n", .{owned});
        allocator.free(owned);
        return;
    }
    joined_count += 1;
}

/// "+ topic", printed when a subscription actually attaches to a publisher rather than when
/// one is merely started. Glob topics are joined inside the library now, so there is no
/// longer a place in this file where every join passes -- and attach is the better moment to
/// report anyway: it says the stream is live, not that we asked for it.
///
/// The handler fires on library threads, so the slot is claimed atomically. Two threads
/// attaching at the same instant can both miss the other's entry and print the line twice;
/// that is a cosmetic duplicate on a progress message, and not worth a lock in its way.
var announced: [max_topics][64]u8 = undefined;
var announced_len: [max_topics]std.atomic.Value(usize) = @splat(std.atomic.Value(usize).init(0));
var announced_count = std.atomic.Value(usize).init(0);

fn onEvent(event: qnnt.Event, topic: []const u8, _: []const u8, _: usize, _: ?*anyopaque) void {
    if (event != .publisher_connected or opt_quiet) return;

    const n = announced_count.load(.acquire);
    for (0..@min(n, announced.len)) |i| {
        const len = announced_len[i].load(.acquire);
        if (len != 0 and std.mem.eql(u8, announced[i][0..len], topic)) return;
    }

    // Checked before claiming, so a name too long to record does not burn a slot every
    // time its publisher reconnects.
    if (topic.len > announced[0].len) return;
    const slot = announced_count.fetchAdd(1, .acq_rel);
    if (slot >= announced.len) return;
    @memcpy(announced[slot][0..topic.len], topic);
    announced_len[slot].store(topic.len, .release);

    std.debug.print("qnnt-cat: + {s}\n", .{topic});
}

// -- writing -----------------------------------------------------------------------------

/// Hex text to bytes. Whitespace between pairs is allowed so a capture taken with --hex can
/// be edited by hand and fed back.
fn hexToBytes(text: []const u8, out: *std.ArrayList(u8)) !void {
    var high: ?u8 = null;
    for (text) |c| {
        if (std.ascii.isWhitespace(c)) continue;
        const nibble = std.fmt.charToDigit(c, 16) catch return error.NotHex;
        if (high) |h| {
            try out.append(allocator, h << 4 | nibble);
            high = null;
        } else {
            high = nibble;
        }
    }
    if (high != null) return error.OddLength;
}

/// Topics this process has registered as a publisher. A timed capture names its own topics,
/// so they are only known as the stream is read and each has to be registered on first
/// sight rather than up front.
var published: [max_topics][]const u8 = undefined;
var published_count: usize = 0;

fn ensurePublisher(topic: []const u8) ?[]const u8 {
    for (published[0..published_count]) |t| {
        if (std.mem.eql(u8, t, topic)) return t;
    }
    if (published_count == max_topics) return null;

    // Copied: the library retains the topic for the life of the publisher, and this slice
    // points into the frame buffer the next read reuses.
    const owned = allocator.dupe(u8, topic) catch return null;
    if (!qnnt.runPublisher(owned, null, null, null)) {
        std.debug.print("qnnt-cat: could not publish {s}\n", .{owned});
        allocator.free(owned);
        return null;
    }

    published[published_count] = owned;
    published_count += 1;
    if (!opt_quiet) std.debug.print("qnnt-cat: publishing {s}\n", .{owned});
    return owned;
}

/// Publish `bytes` to every named topic. One stdin message fans out to all of them, which
/// is what makes `qnnt-cat --publish a b` a tee rather than a choice.
fn publishAll(list: [][]const u8, bytes: []const u8) void {
    for (list) |topic| {
        qnnt.publish(topic, bytes) catch |err| {
            std.debug.print("qnnt-cat: publish to {s} failed: {t}\n", .{ topic, err });
        };
    }
    _ = seen.fetchAdd(1, .monotonic);
}

fn runPublish(list: [][]const u8, wait_ms: u64, throttle: f64) void {
    var rbuf: [64 * 1024]u8 = undefined;
    var reader = std.Io.File.stdin().reader(root.io, &rbuf);

    // A dump names its own topics, so restoring registers them as it reads and does its own
    // waiting -- before the pacing clock starts, so the wait is not charged against the
    // capture's first gap.
    if (opt_format == .dump) {
        replayDump(list, &reader.interface, throttle, wait_ms);
        return;
    }

    for (list) |topic| {
        if (ensurePublisher(topic) == null) return;
    }

    // Waiting by default, because the alternative is silent data loss: a publisher with no
    // subscriber yet has nowhere to put the first messages, and a replay that drops its
    // opening frames looks like a corrupt capture rather than a race.
    if (wait_ms > 0) waitForAny(list, wait_ms);

    if (opt_format == .raw and !opt_text) {
        replayFrames(list, &reader.interface);
        return;
    }

    // Line-oriented: one line of stdin is one message. Under --hex the line is hex digits;
    // otherwise it is the payload, with the newline put back because that is what makes a
    // text topic self-delimiting on the wire.
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);

    while (!qnnt.stopRequested()) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch break;
        if (opt_max != 0 and seen.load(.monotonic) >= opt_max) break;

        if (opt_format == .hex) {
            payload.clearRetainingCapacity();
            hexToBytes(line, &payload) catch |err| {
                std.debug.print("qnnt-cat: skipping a line that is not hex: {t}\n", .{err});
                continue;
            };
            publishAll(list, payload.items);
        } else {
            publishAll(list, line);
        }
    }
}

/// Replay a stream of concatenated TLD frames. `frameSize` returns null when the bytes so
/// far are a prefix of a frame rather than a whole one, which is exactly the "need more"
/// signal a stream needs -- so no length index, no separators, and a file produced by
/// `--raw` goes back in without transformation.
fn replayFrames(list: [][]const u8, reader: *std.Io.Reader) void {
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(allocator);

    var chunk: [32 * 1024]u8 = undefined;
    var eof = false;

    while (!qnnt.stopRequested()) {
        // Drain every complete frame the buffer already holds before reading more.
        while (true) {
            const size = tld.frameSize(pending.items) catch {
                std.debug.print("qnnt-cat: stdin is not a stream of TLD frames\n", .{});
                return;
            } orelse break;
            if (size > pending.items.len) break;

            publishAll(list, pending.items[0..size]);
            // The tail moves down rather than the frames being indexed: a replay is
            // sequential and this keeps one buffer for the whole run.
            std.mem.copyForwards(u8, pending.items, pending.items[size..]);
            pending.shrinkRetainingCapacity(pending.items.len - size);

            if (opt_max != 0 and seen.load(.monotonic) >= opt_max) return;
        }

        if (eof) break;

        const n = reader.readSliceShort(&chunk) catch 0;
        if (n == 0) {
            eof = true;
            continue;
        }
        pending.appendSlice(allocator, chunk[0..n]) catch return;
    }

    if (pending.items.len != 0) {
        std.debug.print(
            "qnnt-cat: {d} trailing byte(s) were not a whole frame -- truncated capture?\n",
            .{pending.items.len},
        );
    }
}

/// Replay a stream of {t, topic, data} envelopes at the pace they were recorded.
///
/// `override` non-empty sends everything to those topics instead of the recorded ones,
/// which is how a capture is replayed somewhere it will not collide with the original.
fn replayDump(override: [][]const u8, reader: *std.Io.Reader, throttle: f64, wait_ms: u64) void {
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(allocator);

    var chunk: [32 * 1024]u8 = undefined;
    var eof = false;

    // The two clocks the pacing compares: where the capture started, and where the replay
    // started. Everything after the first message is scheduled against that pair, so a slow
    // publish does not push the whole rest of the stream later.
    var base_capture_us: ?u64 = null;
    var base_wall_us: u64 = 0;
    var late_us: u64 = 0;

    while (!qnnt.stopRequested()) {
        while (true) {
            const size = tld.frameSize(pending.items) catch {
                std.debug.print("qnnt-cat: stdin is not a stream of TLD frames\n", .{});
                return;
            } orelse break;
            if (size > pending.items.len) break;

            const frame = tld.validate(pending.items[0..size], 32) catch {
                std.debug.print("qnnt-cat: a frame in the capture did not decode\n", .{});
                return;
            };

            if (readEnvelope(frame)) |env| {
                if (base_capture_us == null) {
                    // Register and wait before the clock starts, so the wait is not charged
                    // against the first gap in the capture. Registering matters either way:
                    // a redirect publishes to topics this process has never announced, and
                    // publishing to an unannounced topic reaches nobody at all.
                    if (override.len > 0) {
                        for (override) |topic| {
                            if (ensurePublisher(topic) == null) return;
                        }
                    } else if (ensurePublisher(env.topic) == null) {
                        return;
                    }
                    if (wait_ms > 0) waitForAny(published[0..published_count], wait_ms);
                    base_capture_us = env.t;
                    base_wall_us = @intCast(qnnt.nowMicros());
                } else {
                    // Saturating: a capture whose clock stepped backwards, or whose frames
                    // are out of order, should not be read as a gap of half a century.
                    const want = scaleInterval(env.t -| base_capture_us.?, throttle);
                    const elapsed = @as(u64, @intCast(qnnt.nowMicros())) -| base_wall_us;
                    if (want > elapsed) {
                        qnnt.sleepUs(want - elapsed);
                    } else {
                        late_us = @max(late_us, elapsed - want);
                    }
                }

                if (override.len > 0) {
                    publishAll(override, env.data);
                } else if (ensurePublisher(env.topic)) |owned| {
                    var one = [_][]const u8{owned};
                    publishAll(&one, env.data);
                }
            } else {
                std.debug.print(
                    "qnnt-cat: not a dump -- expected {{t, topic, data}} frames. " ++
                        "Was it written with --raw instead of --dump?\n",
                    .{},
                );
                return;
            }

            std.mem.copyForwards(u8, pending.items, pending.items[size..]);
            pending.shrinkRetainingCapacity(pending.items.len - size);

            if (opt_max != 0 and seen.load(.monotonic) >= opt_max) return;
        }

        if (eof) break;

        const n = reader.readSliceShort(&chunk) catch 0;
        if (n == 0) {
            eof = true;
            continue;
        }
        pending.appendSlice(allocator, chunk[0..n]) catch return;
    }

    // Said rather than hidden: a replay that could not keep up did not reproduce the pace
    // it claims to, and the amount matters.
    if (late_us > 1000 and !opt_quiet) {
        std.debug.print(
            "qnnt-cat: fell behind the recorded pace by up to {d}.{d:0>3}ms\n",
            .{ late_us / 1000, late_us % 1000 },
        );
    }
    if (pending.items.len != 0) {
        std.debug.print(
            "qnnt-cat: {d} trailing byte(s) were not a whole frame -- truncated capture?\n",
            .{pending.items.len},
        );
    }
}

const Envelope = struct { t: u64, topic: []const u8, data: []const u8 };

/// Read one {t, topic, data} envelope, or null if this frame is not one. Null is a
/// legitimate answer rather than an error: it is how a --raw capture fed to --restore is
/// recognised and reported instead of being replayed as nonsense.
fn readEnvelope(frame: tld.Frame) ?Envelope {
    if (frame.type != .object) return null;

    var t: ?u64 = null;
    var topic: ?[]const u8 = null;
    var data: ?[]const u8 = null;

    var it = frame.objectIterator() catch return null;
    while (it.next() catch return null) |pair| {
        if (std.mem.eql(u8, pair.key, "t")) {
            t = pair.value.asUint() catch return null;
        } else if (std.mem.eql(u8, pair.key, "topic")) {
            topic = pair.value.asString() catch return null;
        } else if (std.mem.eql(u8, pair.key, "data")) {
            data = pair.value.asBuffer() catch return null;
        }
    }

    return .{
        .t = t orelse return null,
        .topic = topic orelse return null,
        .data = data orelse return null,
    };
}

fn waitForAny(list: [][]const u8, wait_ms: u64) void {
    for (list) |topic| {
        if (!qnnt.waitForSubscriber(topic, @intCast(wait_ms)) and !opt_quiet) {
            std.debug.print(
                "qnnt-cat: nothing subscribed to {s} within {d}ms -- publishing anyway, " ++
                    "with nowhere for it to go\n",
                .{ topic, wait_ms },
            );
        }
    }
}

fn usage() void {
    std.debug.print(
        \\usage: qnnt-cat [options] <pattern>...            topic  -> stdout
        \\       qnnt-cat --publish [topic] [options]       stdin  -> topic(s)
        \\       qnnt-cat --restore [topic] [options]       a dump -> the topics it names
        \\
        \\  <pattern>...    topic names, or globs when reading. QUOTE globs.
        \\
        \\  -w, --publish [topic]
        \\                  reverse the direction: read stdin and publish it. With a topic,
        \\                  everything goes there. Use --restore instead for a --dump,
        \\                  which carries its own topics and times.
        \\  --hex           hex, in whichever direction is active
        \\  --raw           the bytes themselves: frames verbatim out, replayed in
        \\  --dump          each message wrapped with its arrival time and topic, so the
        \\                  capture can be restored at its original pace, to its own topics
        \\  --restore [topic]
        \\                  publish a --dump from stdin, honouring the recorded times and
        \\                  topics. Needs no topic; given one, everything goes there.
        \\  --throttle <x>  period divider, on either direction: 4 makes every gap a
        \\                  quarter as long (four times faster), 0.25 makes it four times
        \\                  longer. On --dump it scales the intervals recorded, on --restore
        \\                  the intervals waited, and the two compose. Default 1.0.
        \\  --text          newline-delimited instead of TLD-framed, for line topics
        \\  --time          prefix each line with the time (not with --raw)
        \\  --max <n>       stop after n messages
        \\  --rescan <ms>   how often to re-match globs while reading (default 1000;
        \\                  0 matches once at startup and never looks again)
        \\  --wait <ms>     with --publish, wait this long for a subscriber (default 2000)
        \\  --quiet         no notices on stderr
        \\
        \\Data goes to stdout, notices to stderr, so a redirect carries only the payload:
        \\
        \\  qnnt-cat --raw test/bench > cap.bin
        \\  qnnt-cat --publish --raw test/bench < cap.bin
        \\
        \\A --raw capture is the payloads alone: exact for one topic, but it records neither
        \\when anything arrived nor which topic it came from, so a replay runs unpaced and a
        \\capture over a glob merges topics. --dump and --restore keep both:
        \\
        \\  qnnt-cat --dump 'lidar/*' > cap.tld
        \\  qnnt-cat --restore < cap.tld                # same pace, same topics
        \\  qnnt-cat --restore --throttle 4 < cap.tld     # four times faster
        \\  qnnt-cat --dump --throttle 0.5 test/x > cap.tld # record it at half rate
        \\  qnnt-cat --restore replay/here < cap.tld    # redirected to one topic
        \\
    , .{});
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();

    var patterns: [max_pattern][]const u8 = undefined;
    var pattern_count: usize = 0;
    var publish = false;
    var wait_ms: u64 = 2000;

    // A one-slot pushback, because the iterator has no peek and `--publish` takes an
    // optional topic: an argument looked at and rejected as a topic has to be handed back
    // to the loop rather than dropped.
    var pending: ?[]const u8 = null;

    while (true) {
        const arg = if (pending) |held| blk: {
            pending = null;
            break :blk held;
        } else (args.next() orelse break);

        if (std.mem.eql(u8, arg, "--publish") or std.mem.eql(u8, arg, "-w")) {
            publish = true;
            // An optional topic may be attached, so `--publish test/replay` reads the way
            // it sounds. Only taken when it does not start with '-', or `--restore --throttle 4`
            // would swallow the flag as a topic name -- the standard wart of a flag with an
            // optional value, avoided rather than inherited.
            if (args.next()) |next| {
                if (std.mem.startsWith(u8, next, "-")) {
                    pending = next;
                } else {
                    if (pattern_count == max_pattern) return usage();
                    patterns[pattern_count] = next;
                    pattern_count += 1;
                }
            }
        } else if (std.mem.eql(u8, arg, "--hex")) {
            opt_format = .hex;
        } else if (std.mem.eql(u8, arg, "--raw")) {
            opt_format = .raw;
        } else if (std.mem.eql(u8, arg, "--dump")) {
            opt_format = .dump;
        } else if (std.mem.eql(u8, arg, "--restore")) {
            // Sugar, and the point of the pair: restoring IS publishing a dump, so it says
            // so in one word rather than asking anyone to remember which two flags combine.
            // An optional topic redirects it, exactly as with --publish.
            publish = true;
            opt_format = .dump;
            if (args.next()) |next| {
                if (std.mem.startsWith(u8, next, "-")) {
                    pending = next;
                } else {
                    if (pattern_count == max_pattern) return usage();
                    patterns[pattern_count] = next;
                    pattern_count += 1;
                }
            }
        } else if (std.mem.eql(u8, arg, "--text")) {
            opt_text = true;
        } else if (std.mem.eql(u8, arg, "--time")) {
            opt_time = true;
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            opt_quiet = true;
        } else if (std.mem.eql(u8, arg, "--max")) {
            opt_max = std.fmt.parseInt(u64, args.next() orelse return usage(), 10) catch return usage();
        } else if (std.mem.eql(u8, arg, "--rescan")) {
            opt_rescan_ms = std.fmt.parseInt(u64, args.next() orelse return usage(), 10) catch return usage();
        } else if (std.mem.eql(u8, arg, "--wait")) {
            wait_ms = std.fmt.parseInt(u64, args.next() orelse return usage(), 10) catch return usage();
        } else if (std.mem.eql(u8, arg, "--throttle")) {
            opt_throttle = std.fmt.parseFloat(f64, args.next() orelse return usage()) catch return usage();
            if (!(opt_throttle > 0.0) or !std.math.isFinite(opt_throttle)) {
                std.debug.print("qnnt-cat: --throttle must be a positive period multiplier\n", .{});
                return;
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return usage();
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("qnnt-cat: unknown option '{s}'\n\n", .{arg});
            return usage();
        } else {
            if (pattern_count == max_pattern) {
                std.debug.print("qnnt-cat: at most {d} topics\n", .{max_pattern});
                return;
            }
            patterns[pattern_count] = arg;
            pattern_count += 1;
        }
    }

    // A dump carries its own topic names, so restoring needs no topic at all; given one, it
    // redirects everything there instead.
    if (pattern_count == 0 and publish and opt_format != .dump) {
        std.debug.print(
            "qnnt-cat: --publish needs a topic here. A {s} stream records no topic names, so " ++
                "there is nothing to take them from -- name one, or capture with --dump, " ++
                "which records them, and restore it with --restore.\n",
            .{if (opt_format == .raw) "--raw" else "line"},
        );
        return;
    }
    // Everything else needs at least one: a read needs to know what to read, and a publish
    // without a dump has no other source of topic names.
    if (pattern_count == 0 and !publish) return usage();

    // A glob selects among topics that exist. Publishing creates the topic, so a wildcard
    // there could only ever match nothing -- refused rather than silently doing so.
    if (publish) {
        for (patterns[0..pattern_count]) |p| {
            if (root.topics.hasWildcard(p)) {
                std.debug.print(
                    "qnnt-cat: '{s}' is a glob, and --publish needs literal topic names " ++
                        "(a glob can only match topics that already exist)\n",
                    .{p},
                );
                return;
            }
        }
    }

    // Every QNNT_* variable, handled by the library so all four languages agree.
    qnnt.configureFromEnvironment();

    if (!qnnt.run()) {
        std.debug.print("qnnt-cat: failed to start\n", .{});
        return;
    }
    defer qnnt.deinit();

    qnnt.installSignalHandlers();
    qnnt.setEventHandler(onEvent, null);

    defer stdout.flush();

    if (publish) {
        runPublish(patterns[0..pattern_count], wait_ms, opt_throttle);
        if (!opt_quiet) {
            std.debug.print("qnnt-cat: published {d} message(s)\n", .{seen.load(.monotonic)});
        }
        return;
    }

    // A glob goes to the library, which does the matching, the rescanning and the joining;
    // a literal name is subscribed to directly. This used to be a rescan loop here, and the
    // point of moving it is that `qnnt-ls`, `qnnt-cat` and `Qnnt.subscribePattern` now match
    // through the same code -- what one shows you is what the others join.
    for (patterns[0..pattern_count]) |p| {
        if (!root.topics.hasWildcard(p)) {
            join(p);
            continue;
        }
        const ok = if (opt_text)
            qnnt.subscribePattern(p, onText, null, opt_rescan_ms)
        else
            qnnt.subscribePatternFrames(p, onFrame, null, opt_rescan_ms);
        if (!ok) std.debug.print("qnnt-cat: could not subscribe to {s}\n", .{p});
    }

    // Short slices rather than one long sleep, so --max ends the run promptly.
    while (!qnnt.stopRequested() and !limit_reached.load(.acquire)) {
        qnnt.sleepMs(50);
    }

    if (!opt_quiet) std.debug.print("qnnt-cat: {d} message(s)\n", .{seen.load(.monotonic)});
}

// -- tests ----------------------------------------------------------------------------

const testing = std.testing;

test "hex round-trips, and rejects what is not hex" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try hexToBytes("00ff10", &out);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0xff, 0x10 }, out.items);

    // Whitespace between pairs is allowed, so a --hex capture stays hand-editable.
    out.clearRetainingCapacity();
    try hexToBytes("de ad  be\tef", &out);
    try testing.expectEqualSlices(u8, &.{ 0xde, 0xad, 0xbe, 0xef }, out.items);

    out.clearRetainingCapacity();
    try testing.expectError(error.OddLength, hexToBytes("abc", &out));
    out.clearRetainingCapacity();
    try testing.expectError(error.NotHex, hexToBytes("zz", &out));
}

test "a frame stream splits on its own lengths, with no separators" {
    // What --raw writes and --publish --raw reads back: frames butted together. The test is
    // that the boundaries are recoverable from the bytes alone.
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(testing.allocator);

    var sizes: [3]usize = undefined;
    for (0..3) |i| {
        var one: std.ArrayList(u8) = .empty;
        defer one.deinit(testing.allocator);
        var enc = tld.Encoder.init(testing.allocator, &one);
        const obj = enc.beginObject();
        try enc.writeKey("seq");
        try enc.writeUint(i);
        try enc.end(obj);
        sizes[i] = one.items.len;
        try stream.appendSlice(testing.allocator, one.items);
    }

    var at: usize = 0;
    var found: usize = 0;
    while (at < stream.items.len) {
        const size = (try tld.frameSize(stream.items[at..])) orelse break;
        try testing.expectEqual(sizes[found], size);
        const frame = try tld.validate(stream.items[at..][0..size], 32);
        try testing.expectEqual(size, frame.size());
        at += size;
        found += 1;
    }
    try testing.expectEqual(@as(usize, 3), found);
    try testing.expectEqual(stream.items.len, at);

    // A prefix of a frame reports "not yet", which is what lets the replay loop wait for
    // more bytes instead of mistaking a short read for corruption.
    try testing.expect((try tld.frameSize(stream.items[0..1])) != null); // header known
    const partial = stream.items[0 .. sizes[0] - 1];
    const size = try tld.frameSize(partial);
    try testing.expect(size == null or size.? > partial.len);
}

test "an envelope carries the time and topic back out again" {
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(testing.allocator);

    var enc = tld.Encoder.init(testing.allocator, &frame);
    const obj = enc.beginObject();
    try enc.writeKey("t");
    try enc.writeUint(1788463155061346);
    try enc.writeKey("topic");
    try enc.writeString("lidar/helios32");
    try enc.writeKey("data");
    try enc.writeBuffer(&.{ 0xde, 0xad, 0xbe, 0xef });
    try enc.end(obj);

    const env = readEnvelope(try tld.validate(frame.items, 32)) orelse
        return error.ShouldHaveReadEnvelope;
    try testing.expectEqual(@as(u64, 1788463155061346), env.t);
    try testing.expectEqualStrings("lidar/helios32", env.topic);
    try testing.expectEqualSlices(u8, &.{ 0xde, 0xad, 0xbe, 0xef }, env.data);
}

test "a plain frame is not mistaken for an envelope" {
    // The case that matters: a --raw capture handed to --restore. Recognising it
    // is what lets the tool say so instead of replaying the payload's own fields as
    // timings, which is the kind of wrong that looks like it worked.
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(testing.allocator);

    var enc = tld.Encoder.init(testing.allocator, &frame);
    const obj = enc.beginObject();
    try enc.writeKey("seq");
    try enc.writeUint(7);
    try enc.writeKey("t"); // a payload may well have its own "t"
    try enc.writeUint(999);
    try enc.end(obj);

    try testing.expect(readEnvelope(try tld.validate(frame.items, 32)) == null);

    // A scalar frame is not one either.
    frame.clearRetainingCapacity();
    var enc2 = tld.Encoder.init(testing.allocator, &frame);
    try enc2.writeUint(42);
    try testing.expect(readEnvelope(try tld.validate(frame.items, 32)) == null);
}

test "envelopes concatenate into a stream that splits on its own lengths" {
    // The property the replay loop depends on: no index, no separators, and a partial
    // trailing frame is distinguishable from a whole one.
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(testing.allocator);

    for (0..3) |i| {
        var one: std.ArrayList(u8) = .empty;
        defer one.deinit(testing.allocator);
        var enc = tld.Encoder.init(testing.allocator, &one);
        const obj = enc.beginObject();
        try enc.writeKey("t");
        try enc.writeUint(1000 + i * 500);
        try enc.writeKey("topic");
        try enc.writeString("test/x");
        try enc.writeKey("data");
        try enc.writeBuffer("hi");
        try enc.end(obj);
        try stream.appendSlice(testing.allocator, one.items);
    }

    var at: usize = 0;
    var seen_t: [3]u64 = undefined;
    var n: usize = 0;
    while (at < stream.items.len) {
        const size = (try tld.frameSize(stream.items[at..])) orelse break;
        const env = readEnvelope(try tld.validate(stream.items[at..][0..size], 32)).?;
        seen_t[n] = env.t;
        n += 1;
        at += size;
    }
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(stream.items.len, at);

    // The deltas the replay would pace on: 500 ms apart, as recorded.
    try testing.expectEqual(@as(u64, 500), seen_t[1] - seen_t[0]);
    try testing.expectEqual(@as(u64, 500), seen_t[2] - seen_t[1]);
}

test "the throttle divides the period, and 1.0 is exact" {
    // Exactness at 1.0 is the property that matters most: a dump taken without --throttle
    // has to carry the arrival times it claims to, not those times through a float.
    try testing.expectEqual(@as(u64, 500_000), scaleInterval(500_000, 1.0));
    try testing.expectEqual(@as(u64, 1), scaleInterval(1, 1.0));
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), scaleInterval(std.math.maxInt(u64), 1.0));

    // A period DIVIDER: 4 is four times faster, 0.25 is four times slower.
    try testing.expectEqual(@as(u64, 125_000), scaleInterval(500_000, 4.0));
    try testing.expectEqual(@as(u64, 250_000), scaleInterval(500_000, 2.0));
    try testing.expectEqual(@as(u64, 2_000_000), scaleInterval(500_000, 0.25));
    try testing.expectEqual(@as(u64, 1_000_000), scaleInterval(500_000, 0.5));

    // Zero stays zero however it is scaled -- two messages that arrived together still do.
    try testing.expectEqual(@as(u64, 0), scaleInterval(0, 2.0));
    try testing.expectEqual(@as(u64, 0), scaleInterval(0, 0.001));

    // A throttle large enough to overflow saturates rather than wrapping into a tiny gap,
    // which would turn a typo into a flood.
    // A tiny divider is what overflows now; it saturates rather than wrapping into a
    // small gap, which would turn a typo into a flood.
    try testing.expectEqual(
        @as(u64, std.math.maxInt(u64)),
        scaleInterval(std.math.maxInt(u64) / 2, 1.0e-9),
    );
}
