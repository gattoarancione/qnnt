const std = @import("std");
const qnnt = @import("qnnt").Qnnt;

pub fn main() !void {
    if (! qnnt.run()) {
        std.debug.print("failed to run QNNT\n", .{});
    }
    defer qnnt.deinit();

    if (! qnnt.runPublisher("test/topic-a")) {
        std.debug.print("failed to run test/topic-a publisher\n", .{});
        return;
    } else if (! qnnt.runPublisher("test/topic-b")) {
        std.debug.print("failed to run test/topic-b publisher\n", .{});
        return;
    }

    while (true) {
        try qnnt.publish("test/topic-a", "ciao!\n");
        qnnt.sleepMs(1);
        try qnnt.publish("test/topic-b", "!oaic\n");
        qnnt.sleepMs(1);
    }
}
