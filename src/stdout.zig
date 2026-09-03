//! Buffered stdout for the console tools.
//!
//! The tools have to write to fd 1: their output is data meant for a pipe or a redirect,
//! and `std.debug.print` goes to stderr. This does that directly rather than through
//! `std.Io.File.Writer`, for two reasons -- it needs no `Io`, so it works before the node
//! is up and during shutdown, and its buffer is module-level rather than a stack local,
//! which is where the first attempt at this went wrong: a 64 KB buffer in main's frame
//! alongside the topic tables produced torn and half-written output.
//!
//! NOT thread-safe. `qnnt-cat` has one subscriber thread per topic and serialises its own
//! calls with a mutex; `qnnt-ls` is single-threaded.

const std = @import("std");

var buffer: [64 * 1024]u8 = undefined;
var used: usize = 0;

/// Write everything, looping over short writes. A pipe accepts what it accepts, and a
/// partial write is normal rather than an error.
fn writeAll(bytes: []const u8) void {
    var at: usize = 0;
    while (at < bytes.len) {
        const n = std.c.write(1, bytes[at..].ptr, bytes.len - at);
        if (n > 0) {
            at += @intCast(n);
            continue;
        }
        // EINTR is worth retrying -- a signal arriving mid-write is expected in a tool
        // that shuts down on Ctrl-C. Anything else means the far end is gone.
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        return;
    }
}

pub fn write(bytes: []const u8) void {
    // Anything that cannot fit goes straight out rather than being split around the
    // buffer, which keeps one message one write for a reader watching a pipe.
    if (bytes.len >= buffer.len) {
        flush();
        writeAll(bytes);
        return;
    }
    if (used + bytes.len > buffer.len) flush();
    @memcpy(buffer[used..][0..bytes.len], bytes);
    used += bytes.len;
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    var line: [8 * 1024]u8 = undefined;
    const text = std.fmt.bufPrint(&line, fmt, args) catch {
        // Too long for one formatted chunk: say so rather than emitting a truncated
        // record that a downstream parser would accept as complete.
        write("<line too long>\n");
        return;
    };
    write(text);
}

pub fn flush() void {
    if (used == 0) return;
    writeAll(buffer[0..used]);
    used = 0;
}
