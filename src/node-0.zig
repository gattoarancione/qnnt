const std = @import("std");
const qnnt = @import("qnnt").Qnnt;

// Called by each topic's scheduler thread to produce that tick's payload. Returning
// null would skip the tick; these two always have something to say. Messages are
// newline-delimited on the wire, hence the trailing "\n".
fn topicASource(_: []const u8) ?[]const u8 {
    return "ciao!\n";
}

fn topicBSource(_: []const u8) ?[]const u8 {
    return "!oaic\n";
}

pub fn main() !void {
    if (! qnnt.run()) {
        std.debug.print("failed to run QNNT\n", .{});
    }
    defer qnnt.deinit();

    // Each publisher paces itself: the library calls the source callback once per
    // period on its own thread, so nothing here drives the publishing. The two rates
    // differ so subscribers can tell the topics apart by their timing alone.
    if (! qnnt.runPublisher("test/topic-a", topicASource, 10_000)) { // 10 ms, 100 Hz
        std.debug.print("failed to run test/topic-a publisher\n", .{});
        return;
    } else if (! qnnt.runPublisher("test/topic-b", topicBSource, 50_000)) { // 50 ms, 20 Hz
        std.debug.print("failed to run test/topic-b publisher\n", .{});
        return;
    }

    // Nothing left for the main thread to do but stay alive.
    while (true) {
        qnnt.sleepMs(1000);
    }
}
