//! The camera-to-driver handoff, as shared memory.
//!
//! This models what the ZED SDK actually does. `retrieveMeasure()` hands you a pointer into
//! the SDK's own buffer; nothing is serialised, nothing is chunked, and if your application
//! is slow you do not receive a damaged frame -- you receive a LATER one, and the ones in
//! between are gone. A ring of frame slots in a shared mapping reproduces exactly that.
//!
//! It replaced a UDP chunking transport, and the reason is worth recording because the
//! wrong choice cost real work. Over UDP a 6.2 MB frame became 760 datagrams that could be
//! lost individually, so the driver grew a chunk bitmap, a byte-offset scatter that had to
//! handle a depth value split across two datagrams, a `rows_missing` count, a socket
//! receive-buffer tuned to 8 MB, and a fix for losing 83% of every frame. All of it modelled
//! a problem a real ZED driver does not have. A named pipe was considered next and rejected
//! for a subtler reason: a 64 KB pipe buffer against a 6.2 MB frame lock-steps the writer to
//! the reader, so a slow consumer would throttle the camera -- and throttling the sensor is
//! the one thing real hardware cannot do.
//!
//! What shared memory gets right:
//!
//!   * the producer never blocks. It writes the next slot and publishes it. A slow consumer
//!     misses frames, which is what happens with a real camera, and sees the miss as a gap
//!     in the sequence number.
//!   * no serialisation. Depth is a native u16 array because both ends are the same machine
//!     by construction -- which is a thing shared memory may assume and a wire format may
//!     not.
//!   * no size ceiling, no MTU, no fragmentation, no reassembly.
//!
//! What it necessarily gives up: it is local-only. There is no `--from`, and the fake cannot
//! run on another machine the way fake-helios32 can. That is not a limitation of the model,
//! it is the model -- a camera on a GMSL2 or USB link is not on the network either.

const std = @import("std");

pub const magic = [8]u8{ 'Z', 'E', 'D', 'S', 'H', 'M', '1', 0 };
pub const version: u32 = 1;

/// One page for the header, so the frame slots start page-aligned.
pub const header_bytes: usize = 4096;

/// Frame slots. Four at 30 Hz gives a consumer 133 ms to copy a frame out before the
/// producer laps it, which is two orders of magnitude more than a 6 MB copy takes. More
/// slots would only hide a consumer that is already too slow to be useful.
pub const default_slots: u32 = 4;

/// Inertial samples the ring holds. A ZED 2i's IMU runs at 400 Hz and a consumer polling at
/// frame rate wakes 30 times a second, so it must be able to drain 13 at a time; 512 gives
/// it 1.28 seconds of slack before anything is lost.
pub const sensors_slots: u32 = 512;
pub const sensors_bytes: usize = 64;
pub const sensors_region: usize = sensors_slots * sensors_bytes;

pub const slot_header_bytes: usize = 16;

/// Byte offsets in the header page. Named because a producer and a consumer that disagree
/// by one byte produce a picture that looks almost right.
pub const off_magic = 0;
pub const off_version = 8;
pub const off_slots = 12;
pub const off_width = 16;
pub const off_height = 18;
pub const off_fps = 20;
pub const off_model = 22;
pub const off_has_sensors = 23;
pub const off_payload_len = 24;
pub const off_slot_stride = 28;
/// The newest fully-written frame. Read with acquire, written with release: it is the fence
/// that makes the slot's bytes visible before the consumer is told to look at them.
pub const off_published = 32;
/// Seqlock for the calibration block: odd while being written, even when settled.
pub const off_calib_seq = 40;
pub const off_calib = 48;
/// Total inertial samples ever written, which doubles as the ring's write cursor.
pub const off_sensors_written = 128;

pub const Error = error{
    NotShared,
    BadMagic,
    BadVersion,
    BadGeometry,
    TooSmall,
    OpenFailed,
    SizeFailed,
    MapFailed,
};

pub fn payloadBytes(w: u16, h: u16) usize {
    // Native u16 depth plus u8 luminance. No endianness conversion, because shared memory
    // between two processes on one machine may assume one byte order and a wire may not.
    return @as(usize, w) * h * 3;
}

fn roundUp(n: usize, to: usize) usize {
    return (n + to - 1) / to * to;
}

pub fn slotStride(w: u16, h: u16) usize {
    return roundUp(slot_header_bytes + payloadBytes(w, h), 4096);
}

pub fn totalBytes(w: u16, h: u16, slots: u32) usize {
    return header_bytes + sensors_region + slots * slotStride(w, h);
}

/// A mapped region, with the accessors both ends share.
pub const Region = struct {
    bytes: []align(std.heap.page_size_min) u8,
    fd: c_int,
    path: [:0]const u8,
    /// Set on the process that created it, and the only one that unlinks.
    owner: bool,

    pub fn width(r: Region) u16 {
        return std.mem.readInt(u16, r.bytes[off_width..][0..2], .little);
    }
    pub fn height(r: Region) u16 {
        return std.mem.readInt(u16, r.bytes[off_height..][0..2], .little);
    }
    pub fn slots(r: Region) u32 {
        return std.mem.readInt(u32, r.bytes[off_slots..][0..4], .little);
    }
    pub fn fps(r: Region) u16 {
        return std.mem.readInt(u16, r.bytes[off_fps..][0..2], .little);
    }
    pub fn modelId(r: Region) u8 {
        return r.bytes[off_model];
    }
    pub fn hasSensors(r: Region) bool {
        return r.bytes[off_has_sensors] != 0;
    }
    pub fn payloadLen(r: Region) usize {
        return std.mem.readInt(u32, r.bytes[off_payload_len..][0..4], .little);
    }
    pub fn stride(r: Region) usize {
        return std.mem.readInt(u32, r.bytes[off_slot_stride..][0..4], .little);
    }

    fn atomicU64(r: Region, at: usize) *std.atomic.Value(u64) {
        return @ptrCast(@alignCast(r.bytes[at..].ptr));
    }
    fn atomicU32(r: Region, at: usize) *std.atomic.Value(u32) {
        return @ptrCast(@alignCast(r.bytes[at..].ptr));
    }

    pub fn published(r: Region) u64 {
        return r.atomicU64(off_published).load(.acquire);
    }
    pub fn sensorsWritten(r: Region) u64 {
        return r.atomicU64(off_sensors_written).load(.acquire);
    }

    /// The bytes of one slot: its header then its payload.
    fn slot(r: Region, index: u64) []u8 {
        const at = header_bytes + sensors_region + @as(usize, @intCast(index)) * r.stride();
        return r.bytes[at..][0..r.stride()];
    }

    pub fn deinit(r: *Region) void {
        std.posix.munmap(r.bytes);
        _ = std.c.close(r.fd);
        // Only the creator removes it. A consumer unlinking would leave the producer writing
        // to a file nothing else can find.
        if (r.owner) _ = std.c.unlink(r.path.ptr);
    }
};

/// Create the region, sized for this geometry, and stamp its header. The producer's side.
pub fn create(
    path: [:0]const u8,
    w: u16,
    h: u16,
    fps_value: u16,
    model_id: u8,
    has_sensors: bool,
    slot_count: u32,
) Error!Region {
    const size = totalBytes(w, h, slot_count);

    const fd = std.c.open(
        path,
        .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true },
        @as(std.c.mode_t, 0o600),
    );
    if (fd < 0) return error.OpenFailed;

    if (std.c.ftruncate(fd, @intCast(size)) != 0) {
        _ = std.c.close(fd);
        return error.SizeFailed;
    }

    const bytes = std.posix.mmap(
        null,
        size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    ) catch {
        _ = std.c.close(fd);
        return error.MapFailed;
    };

    @memset(bytes[0..header_bytes], 0);
    std.mem.writeInt(u32, bytes[off_slots..][0..4], slot_count, .little);
    std.mem.writeInt(u16, bytes[off_width..][0..2], w, .little);
    std.mem.writeInt(u16, bytes[off_height..][0..2], h, .little);
    std.mem.writeInt(u16, bytes[off_fps..][0..2], fps_value, .little);
    bytes[off_model] = model_id;
    bytes[off_has_sensors] = if (has_sensors) 1 else 0;
    std.mem.writeInt(u32, bytes[off_payload_len..][0..4], @intCast(payloadBytes(w, h)), .little);
    std.mem.writeInt(u32, bytes[off_slot_stride..][0..4], @intCast(slotStride(w, h)), .little);
    std.mem.writeInt(u32, bytes[off_version..][0..4], version, .little);

    // The magic goes LAST, and with a release fence, so a consumer that opens the file
    // mid-creation sees either no magic or a fully stamped header -- never a half-written
    // geometry it would size its buffers from.
    const magic_word: *u64 = @ptrCast(@alignCast(bytes[off_magic..].ptr));
    @atomicStore(u64, magic_word, @bitCast(magic), .release);

    return .{ .bytes = bytes, .fd = fd, .path = path, .owner = true };
}

/// Open an existing region and validate its header. The consumer's side.
pub fn open(path: [:0]const u8) Error!Region {
    const fd = std.c.open(path, .{ .ACCMODE = .RDWR }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;

    // The header first, to learn the geometry before mapping the whole thing.
    var probe: [header_bytes]u8 = undefined;
    const got = std.c.pread(fd, &probe, header_bytes, 0);
    if (got < @as(isize, header_bytes)) {
        _ = std.c.close(fd);
        return error.TooSmall;
    }
    if (!std.mem.eql(u8, probe[0..magic.len], &magic)) {
        _ = std.c.close(fd);
        return error.BadMagic;
    }
    if (std.mem.readInt(u32, probe[off_version..][0..4], .little) != version) {
        _ = std.c.close(fd);
        return error.BadVersion;
    }

    const w = std.mem.readInt(u16, probe[off_width..][0..2], .little);
    const h = std.mem.readInt(u16, probe[off_height..][0..2], .little);
    const slot_count = std.mem.readInt(u32, probe[off_slots..][0..4], .little);
    if (w == 0 or h == 0 or slot_count == 0 or slot_count > 64) {
        _ = std.c.close(fd);
        return error.BadGeometry;
    }

    const size = totalBytes(w, h, slot_count);
    const bytes = std.posix.mmap(
        null,
        size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    ) catch {
        _ = std.c.close(fd);
        return error.MapFailed;
    };

    return .{ .bytes = bytes, .fd = fd, .path = path, .owner = false };
}

// -- the producer's side ---------------------------------------------------------------

/// Hand over one frame. Never blocks, and never waits for a consumer: if nobody is reading,
/// the slot is simply overwritten next time round, which is what a camera does.
pub fn writeFrame(
    r: Region,
    seq: u64,
    t_us: u64,
    depth: []const u16,
    mono: []const u8,
) void {
    const w = r.width();
    const h = r.height();
    const n = @as(usize, w) * h;

    const s = r.slot(seq % r.slots());
    std.mem.writeInt(u64, s[0..8], seq, .little);
    std.mem.writeInt(u64, s[8..16], t_us, .little);

    const payload = s[slot_header_bytes..][0..r.payloadLen()];
    @memcpy(payload[0 .. n * 2], std.mem.sliceAsBytes(depth[0..n]));
    @memcpy(payload[n * 2 ..][0..n], mono[0..n]);

    // Release AFTER the payload, so a consumer that sees this sequence number is guaranteed
    // to see the bytes that go with it. Without the fence the store could be visible first
    // and the consumer would read the previous frame's tail.
    r.atomicU64(off_published).store(seq, .release);
}

pub fn writeCalibration(r: Region, block: []const u8) void {
    std.debug.assert(block.len <= off_sensors_written - off_calib);

    const lock = r.atomicU32(off_calib_seq);
    // Odd while writing: a consumer that reads an odd counter, or a different one either
    // side of the block, knows it caught a partial update and retries.
    _ = lock.fetchAdd(1, .release);
    @memcpy(r.bytes[off_calib..][0..block.len], block);
    _ = lock.fetchAdd(1, .release);
}

pub fn writeSensors(r: Region, sample: []const u8) void {
    std.debug.assert(sample.len <= sensors_bytes);

    const written = r.atomicU64(off_sensors_written);
    const index = written.load(.monotonic) % sensors_slots;
    const at = header_bytes + @as(usize, @intCast(index)) * sensors_bytes;
    @memcpy(r.bytes[at..][0..sample.len], sample);
    // Published after the bytes, as with a frame.
    _ = written.fetchAdd(1, .release);
}

// -- the consumer's side ---------------------------------------------------------------

pub const Taken = union(enum) {
    /// A frame was copied out. `missed` is how many the consumer was too slow to see, which
    /// is the honest form of "the camera kept going without us".
    frame: struct { seq: u64, t_us: u64, missed: u64 },
    /// Nothing new since last time.
    none,
    /// The producer lapped the ring while this was being copied. The bytes are discarded
    /// rather than handed over half-updated.
    torn,
};

/// Copy the newest frame out, if it is newer than `last_seq`.
///
/// Copied rather than handed over as a pointer into the mapping. A pointer would be the
/// genuinely zero-copy thing to do and is what a real integration might, but the slot can be
/// overwritten under a consumer that holds it; copying and THEN checking for a lap means
/// nothing half-overwritten ever escapes. A 6 MB copy is about 0.6 ms, against 33 ms of
/// frame period.
pub fn takeFrame(
    r: Region,
    last_seq: u64,
    depth_out: []u16,
    mono_out: []u8,
) Taken {
    const newest = r.published();
    if (newest == 0 or newest == last_seq) return .none;

    const w = r.width();
    const h = r.height();
    const n = @as(usize, w) * h;
    if (depth_out.len < n or mono_out.len < n) return .none;

    const s = r.slot(newest % r.slots());
    const slot_seq = std.mem.readInt(u64, s[0..8], .little);
    const t_us = std.mem.readInt(u64, s[8..16], .little);

    const payload = s[slot_header_bytes..][0..r.payloadLen()];
    @memcpy(std.mem.sliceAsBytes(depth_out[0..n]), payload[0 .. n * 2]);
    @memcpy(mono_out[0..n], payload[n * 2 ..][0..n]);

    // Lapped? The producer has written `after - newest` frames since the copy began, and
    // anything at or beyond the ring length means this slot was reused underneath it.
    const after = r.published();
    if (slot_seq != newest or after -| newest >= r.slots()) return .torn;

    // Frames between the last one seen and this one are simply gone -- the camera did not
    // wait. That is the behaviour a UDP transport modelled as damage and a pipe would have
    // modelled as the camera slowing down; here it is a number.
    const missed = if (last_seq == 0) 0 else newest -| last_seq -| 1;
    return .{ .frame = .{ .seq = newest, .t_us = t_us, .missed = missed } };
}

/// Read the calibration block if it has changed. Returns the new seqlock value, or null when
/// nothing changed or a partial write was caught.
pub fn takeCalibration(r: Region, last: u32, out: []u8) ?u32 {
    const lock = r.atomicU32(off_calib_seq);
    const before = lock.load(.acquire);
    if (before == last or before % 2 != 0 or before == 0) return null;

    @memcpy(out, r.bytes[off_calib..][0..out.len]);
    if (lock.load(.acquire) != before) return null; // caught mid-update
    return before;
}

/// Drain inertial samples from `cursor` forward. Returns how many were written into `out`
/// and advances the cursor past them. `lost` counts samples that were overwritten before
/// this consumer got to them.
pub fn takeSensors(r: Region, cursor: *u64, out: []u8, lost: *u64) usize {
    if (!r.hasSensors()) return 0;

    const written = r.sensorsWritten();
    if (written <= cursor.*) return 0;

    // Fell more than a ring behind: the oldest samples are gone. Skipped forward rather
    // than reading whatever happens to be in the slots now.
    if (written - cursor.* > sensors_slots) {
        lost.* += written - cursor.* - sensors_slots;
        cursor.* = written - sensors_slots;
    }

    var count: usize = 0;
    while (cursor.* < written and (count + 1) * sensors_bytes <= out.len) {
        const index = cursor.* % sensors_slots;
        const at = header_bytes + @as(usize, @intCast(index)) * sensors_bytes;
        @memcpy(out[count * sensors_bytes ..][0..sensors_bytes], r.bytes[at..][0..sensors_bytes]);
        cursor.* += 1;
        count += 1;
    }
    return count;
}

// -- tests ----------------------------------------------------------------------------

const testing = std.testing;

const test_path: [:0]const u8 = "/tmp/qnnt-zed-test.shm";

test "a frame written to a slot comes back byte-identical" {
    const w: u16 = 64;
    const h: u16 = 40;
    const n = @as(usize, w) * h;

    var producer = try create(test_path, w, h, 30, 0, true, default_slots);
    defer producer.deinit();

    // A second mapping of the same file, which is what the consumer process has.
    var consumer = try open(test_path);
    defer consumer.deinit();

    try testing.expectEqual(w, consumer.width());
    try testing.expectEqual(h, consumer.height());
    try testing.expectEqual(default_slots, consumer.slots());
    try testing.expect(consumer.hasSensors());

    const depth = try testing.allocator.alloc(u16, n);
    defer testing.allocator.free(depth);
    const mono = try testing.allocator.alloc(u8, n);
    defer testing.allocator.free(mono);
    for (0..n) |i| {
        depth[i] = @intCast(1000 + i);
        mono[i] = @truncate(i);
    }

    // Nothing published yet.
    const d_out = try testing.allocator.alloc(u16, n);
    defer testing.allocator.free(d_out);
    const m_out = try testing.allocator.alloc(u8, n);
    defer testing.allocator.free(m_out);
    try testing.expect(takeFrame(consumer, 0, d_out, m_out) == .none);

    writeFrame(producer, 1, 12345, depth, mono);

    switch (takeFrame(consumer, 0, d_out, m_out)) {
        .frame => |f| {
            try testing.expectEqual(@as(u64, 1), f.seq);
            try testing.expectEqual(@as(u64, 12345), f.t_us);
            try testing.expectEqual(@as(u64, 0), f.missed);
        },
        else => return error.ShouldHaveTakenAFrame,
    }
    try testing.expectEqualSlices(u16, depth, d_out);
    try testing.expectEqualSlices(u8, mono, m_out);

    // The same frame again is not new.
    try testing.expect(takeFrame(consumer, 1, d_out, m_out) == .none);
}

test "a consumer that falls behind misses frames rather than getting damaged ones" {
    const w: u16 = 32;
    const h: u16 = 16;
    const n = @as(usize, w) * h;

    var producer = try create(test_path, w, h, 30, 0, false, default_slots);
    defer producer.deinit();
    var consumer = try open(test_path);
    defer consumer.deinit();

    const depth = try testing.allocator.alloc(u16, n);
    defer testing.allocator.free(depth);
    const mono = try testing.allocator.alloc(u8, n);
    defer testing.allocator.free(mono);
    const d_out = try testing.allocator.alloc(u16, n);
    defer testing.allocator.free(d_out);
    const m_out = try testing.allocator.alloc(u8, n);
    defer testing.allocator.free(m_out);

    // Ten frames written while nobody reads. The camera did not wait, and the consumer's
    // next read gets the NEWEST -- not the oldest, and not a mixture.
    for (1..11) |seq| {
        @memset(depth, @intCast(seq));
        @memset(mono, @intCast(seq));
        writeFrame(producer, seq, seq * 100, depth, mono);
    }

    switch (takeFrame(consumer, 1, d_out, m_out)) {
        .frame => |f| {
            try testing.expectEqual(@as(u64, 10), f.seq);
            // Frames 2..9 are gone, and their number is reported rather than hidden.
            try testing.expectEqual(@as(u64, 8), f.missed);
        },
        else => return error.ShouldHaveTakenAFrame,
    }
    // The bytes are frame 10's throughout, not a seam between two frames.
    for (d_out) |v| try testing.expectEqual(@as(u16, 10), v);
    for (m_out) |v| try testing.expectEqual(@as(u8, 10), v);
}

test "calibration is read whole or not at all" {
    var producer = try create(test_path, 16, 16, 30, 1, true, default_slots);
    defer producer.deinit();
    var consumer = try open(test_path);
    defer consumer.deinit();

    var block: [32]u8 = undefined;
    for (&block, 0..) |*b, i| b.* = @truncate(i);

    var out: [32]u8 = undefined;
    // Nothing written yet: no update to report.
    try testing.expect(takeCalibration(consumer, 0, &out) == null);

    writeCalibration(producer, &block);
    const seen = takeCalibration(consumer, 0, &out) orelse return error.ShouldHaveRead;
    try testing.expectEqualSlices(u8, &block, &out);

    // Unchanged: not reported again, which is what keeps a 1 Hz republish from being 1 Hz
    // of log noise.
    try testing.expect(takeCalibration(consumer, seen, &out) == null);

    block[0] = 0xFF;
    writeCalibration(producer, &block);
    const seen2 = takeCalibration(consumer, seen, &out) orelse return error.ShouldHaveRead;
    try testing.expect(seen2 != seen);
    try testing.expectEqual(@as(u8, 0xFF), out[0]);
}

test "inertial samples drain in order, and a ring overrun is counted" {
    var producer = try create(test_path, 16, 16, 30, 1, true, default_slots);
    defer producer.deinit();
    var consumer = try open(test_path);
    defer consumer.deinit();

    var sample: [sensors_bytes]u8 = undefined;
    var out: [sensors_bytes * 32]u8 = undefined;
    var cursor: u64 = 0;
    var lost: u64 = 0;

    try testing.expectEqual(@as(usize, 0), takeSensors(consumer, &cursor, &out, &lost));

    for (0..5) |i| {
        @memset(&sample, @intCast(i + 1));
        writeSensors(producer, &sample);
    }

    const got = takeSensors(consumer, &cursor, &out, &lost);
    try testing.expectEqual(@as(usize, 5), got);
    try testing.expectEqual(@as(u64, 0), lost);
    // In order, oldest first.
    for (0..5) |i| {
        try testing.expectEqual(@as(u8, @intCast(i + 1)), out[i * sensors_bytes]);
    }
    try testing.expectEqual(@as(u64, 5), cursor);
    try testing.expectEqual(@as(usize, 0), takeSensors(consumer, &cursor, &out, &lost));

    // Overrun the ring: a consumer this far behind cannot have the oldest samples, and the
    // count says how many it lost rather than handing over whatever is in the slots.
    for (0..sensors_slots + 100) |i| {
        @memset(&sample, @truncate(i));
        writeSensors(producer, &sample);
    }
    _ = takeSensors(consumer, &cursor, &out, &lost);
    try testing.expect(lost > 0);
    try testing.expectEqual(@as(u64, 100), lost);
}

test "a stale or foreign file is refused rather than mapped" {
    // No file at all.
    try testing.expectError(error.OpenFailed, open("/tmp/qnnt-zed-does-not-exist.shm"));

    // A file too small to hold a header.
    const stale: [:0]const u8 = "/tmp/qnnt-zed-stale.shm";
    const fd = std.c.open(stale, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    try testing.expect(fd >= 0);
    _ = std.c.close(fd);
    defer _ = std.c.unlink(stale.ptr);
    try testing.expectError(error.TooSmall, open(stale));

    // Header-sized but not ours: the magic is what stops a leftover file from a different
    // program being interpreted as geometry.
    const fd2 = std.c.open(stale, .{ .ACCMODE = .RDWR, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    try testing.expect(fd2 >= 0);
    try testing.expect(std.c.ftruncate(fd2, header_bytes * 2) == 0);
    _ = std.c.close(fd2);
    try testing.expectError(error.BadMagic, open(stale));
}

test "the layout arithmetic covers every native mode" {
    // 1080p and 1200p, the two the chain actually transmits, plus 2K as the largest either
    // camera offers.
    for ([_][2]u16{ .{ 1920, 1080 }, .{ 1920, 1200 }, .{ 2208, 1242 } }) |wh| {
        const w = wh[0];
        const h = wh[1];
        try testing.expectEqual(@as(usize, w) * h * 3, payloadBytes(w, h));

        // A slot is page-aligned, so slots never share a page and a write to one cannot
        // dirty a neighbour's.
        try testing.expectEqual(@as(usize, 0), slotStride(w, h) % 4096);
        try testing.expect(slotStride(w, h) >= slot_header_bytes + payloadBytes(w, h));

        const total = totalBytes(w, h, default_slots);
        try testing.expect(total > default_slots * payloadBytes(w, h));
        // Sanity on the size a caller has to be willing to map: 25 MB at 1080p.
        try testing.expect(total < 64 * 1024 * 1024);
    }
}
