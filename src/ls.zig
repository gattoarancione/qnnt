//! qnnt-ls -- what is on the bus.
//!
//!   qnnt-ls                          every topic, one per line
//!   qnnt-ls 'lidar/*'                only matching topics
//!   qnnt-ls --tree                   grouped by '/' segment
//!   qnnt-ls -n                       numbered, for --subs
//!   qnnt-ls --subs lidar/helios32    who is subscribed to one topic
//!   qnnt-ls --subs 3                 the same, by its number from -n
//!
//! Bare output is one name per line and nothing else, because the common use is a pipe:
//! `qnnt-ls | xargs qnnt-cat` should work without flags. `--tree` is for eyes. Both are
//! sorted, so neither shuffles with the registry's hash order between calls.
//!
//! QUOTE YOUR GLOBS. `lidar/*` unquoted is expanded by the shell first, and zsh fails the
//! command outright when nothing matches on disk.

const std = @import("std");
const qnnt = @import("qnnt").Qnnt;
const topics = @import("topics");
const stdout = @import("stdout");

const allocator = std.heap.page_allocator;

const max_topics = 512;

/// The listing is data -- `qnnt-ls | xargs qnnt-cat` is the point of it -- so it goes to
/// stdout. Only notices and errors go to stderr, through std.debug.print.
const print = stdout.print;

fn usage() void {
    std.debug.print(
        \\usage: qnnt-ls [options] [pattern]...
        \\
        \\  [pattern]...      topic names or globs; every topic if none given
        \\
        \\  --tree            group the names by '/' segment
        \\  -n, --number      prefix each name with its number, for --subs
        \\  --subs <topic|N>  the subscribers of one topic, as the registry reports them.
        \\                    N is a number from -n, resolved against the current listing.
        \\
        \\Bare output is one name per line, for a pipe. Quote globs.
        \\
    , .{});
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();

    var patterns: [32][]const u8 = undefined;
    var pattern_count: usize = 0;
    var want_tree = false;
    var want_numbers = false;
    var subs_of: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--tree")) {
            want_tree = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--number")) {
            want_numbers = true;
        } else if (std.mem.eql(u8, arg, "--subs")) {
            subs_of = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return usage();
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("qnnt-ls: unknown option '{s}'\n\n", .{arg});
            return usage();
        } else {
            if (pattern_count == patterns.len) {
                std.debug.print("qnnt-ls: at most {d} patterns\n", .{patterns.len});
                return;
            }
            patterns[pattern_count] = arg;
            pattern_count += 1;
        }
    }

    // Every QNNT_* variable, handled by the library so all four languages agree.
    qnnt.configureFromEnvironment();

    if (!qnnt.run()) {
        std.debug.print("qnnt-ls: failed to start\n", .{});
        return;
    }
    defer qnnt.deinit();

    defer stdout.flush();

    var names: [max_topics][]const u8 = undefined;
    var name_buf: [max_topics * 96]u8 = undefined;

    const total = qnnt.listTopics(&names, &name_buf) catch |err| {
        std.debug.print("qnnt-ls: cannot reach the registry: {t}\n", .{err});
        return;
    };

    // Sorted before anything else: --subs by number and the tree both depend on the order
    // being the same one the user saw.
    std.mem.sort([]const u8, names[0..total], {}, topics.lessThan);

    // Keep only what matches, in place.
    var kept: usize = 0;
    for (names[0..total]) |name| {
        if (pattern_count == 0 or matchesAny(patterns[0..pattern_count], name)) {
            names[kept] = name;
            kept += 1;
        }
    }
    const shown = names[0..kept];

    if (subs_of) |spec| {
        const topic = resolveTopic(spec, shown) orelse {
            std.debug.print("qnnt-ls: no topic '{s}' -- {d} listed\n", .{ spec, kept });
            return;
        };

        // Passed through rather than reformatted: the registry already lays out subscriber,
        // connected and msgs, and its '#' lines carry the part that matters most -- whether
        // the publisher has reported at all, which is a different fact from having none.
        var cmd_buf: [256]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "subs {s}", .{topic}) catch return;
        const reply = allocator.alloc(u8, 64 * 1024) catch return;
        defer allocator.free(reply);

        const text = qnnt.registryCommand(cmd, reply) catch |err| {
            std.debug.print("qnnt-ls: {t}\n", .{err});
            return;
        };
        print("{s}", .{text});
        return;
    }

    if (kept == 0) {
        print("# no topics{s}\n", .{if (pattern_count > 0) " matched" else " registered"});
        return;
    }

    if (want_tree) {
        var prefix: std.ArrayList(u8) = .empty;
        defer prefix.deinit(allocator);
        var tree: std.ArrayList(u8) = .empty;
        defer tree.deinit(allocator);

        topics.renderTree(&tree, shown, 0, &prefix);
        print("{s}# {d} topic(s)\n", .{ tree.items, kept });
        return;
    }

    for (shown, 1..) |name, i| {
        if (want_numbers) {
            print("{d:>4}  {s}\n", .{ i, name });
        } else {
            print("{s}\n", .{name});
        }
    }
}

fn matchesAny(patterns: [][]const u8, name: []const u8) bool {
    for (patterns) |p| {
        if (topics.hasWildcard(p)) {
            if (topics.globMatch(p, name)) return true;
        } else if (std.mem.eql(u8, p, name)) {
            return true;
        }
    }
    return false;
}

/// A --subs argument is either a topic name or a number from `-n`. Numbers are resolved
/// against the listing as it is right now, which is why -n prints them next to the names it
/// just fetched: a topic registered or expired in between shifts every number after it.
/// A name is tried first, so a topic that happens to be called "3" still works.
fn resolveTopic(spec: []const u8, listing: [][]const u8) ?[]const u8 {
    for (listing) |name| {
        if (std.mem.eql(u8, name, spec)) return name;
    }

    const n = std.fmt.parseInt(usize, spec, 10) catch return null;
    if (n == 0 or n > listing.len) return null;
    return listing[n - 1];
}

// -- tests ----------------------------------------------------------------------------

const testing = std.testing;

test "--subs takes a name or a number, and prefers the name" {
    var listing = [_][]const u8{ "alpha", "3", "beta" };

    try testing.expectEqualStrings("beta", resolveTopic("beta", &listing).?);

    // "3" is both a name here and a valid index. The name wins, because a topic that
    // exists is never what someone meant to miss.
    try testing.expectEqualStrings("3", resolveTopic("3", &listing).?);

    try testing.expectEqualStrings("alpha", resolveTopic("1", &listing).?);

    // With no name in the way, a number indexes the listing 1-based.
    var plain = [_][]const u8{ "alpha", "beta", "gamma" };
    try testing.expectEqualStrings("alpha", resolveTopic("1", &plain).?);
    try testing.expectEqualStrings("gamma", resolveTopic("3", &plain).?);

    // Out of range and nonsense both decline rather than picking something.
    try testing.expect(resolveTopic("0", &listing) == null);
    try testing.expect(resolveTopic("4", &listing) == null);
    try testing.expect(resolveTopic("nope", &listing) == null);
    try testing.expect(resolveTopic("", &listing) == null);
}

test "patterns select, and no pattern means everything" {
    var globs = [_][]const u8{"lidar/*"};
    try testing.expect(matchesAny(&globs, "lidar/helios32"));
    try testing.expect(!matchesAny(&globs, "test/bench"));

    // An exact pattern matches exactly: it is not treated as a prefix.
    var exact = [_][]const u8{"test/bench"};
    try testing.expect(matchesAny(&exact, "test/bench"));
    try testing.expect(!matchesAny(&exact, "test/bench2"));

    var both = [_][]const u8{ "test/bench", "lidar/*" };
    try testing.expect(matchesAny(&both, "test/bench"));
    try testing.expect(matchesAny(&both, "lidar/rs16"));
    try testing.expect(!matchesAny(&both, "mesh/zig"));
}
