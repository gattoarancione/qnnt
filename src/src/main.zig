const std = @import("std");
const print_d = std.debug.print;
const Thread = std.Thread;
const src = @import("src");

pub fn main() !void {
    var node = src.Node.init();
    defer node.deinit();

    var tap0 = try node.newTap("qnnt/test0");
    print_d("Just inserted this: {s}\n", .{tap0.topic});

    //var tap1 = try node.newTap("qnnt/test1");
    //print_d("Just inserted this: {s}\n", .{tap1.topic});

    try node.run(false);

    while (true) {
        try tap0.pour("ciao");
        //try tap1.pour("caca");
        Thread.sleep(10 * std.time.ns_per_ms);
    }
}
