const std = @import("std");
const qnnt = @import("qnnt").Qnnt;

pub fn main() !void {
    try qnnt.run();
    defer qnnt.deinit();

    try qnnt.runPublisher("test/topic-a");
    try qnnt.runPublisher("test/topic-b");

    while (true) {
        try qnnt.publish("test/topic-a", "ciao!\n");
        std.Thread.sleep(5 * std.time.ns_per_ms);
        try qnnt.publish("test/topic-b", "!oaic\n");
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
}
