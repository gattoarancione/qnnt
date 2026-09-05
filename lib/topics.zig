//! Topic-name logic: glob matching, and the '/'-segment tree that `qnnt-ls --tree` draws.
//!
//! In the library rather than in a tool because three things now depend on matching the
//! same way, and a matcher that behaved differently in any of them would be worse than no
//! glob at all: what `qnnt-ls` shows you must be exactly what `qnnt-cat` subscribes to, and
//! both must be exactly what `Qnnt.subscribePattern` joins.
//!
//! It began in src/ when only the tools had globs. Moving it down is what stops every
//! consumer of the C, C++ and Python bindings writing a fourth one.
//!
//! Nothing in here touches the network, which is why its tests need no node.

const std = @import("std");

const allocator = std.heap.page_allocator;

/// Glob match: `*` spans any run of characters including none, `?` exactly one. Iterative
/// with a backtrack point rather than recursive, so a pattern of several stars against a
/// long topic cannot blow the stack or go exponential.
pub fn globMatch(pattern: []const u8, name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    var star: ?usize = null;
    var star_n: usize = 0;

    while (n < name.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == name[n])) {
            p += 1;
            n += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            star_n = n;
        } else if (star) |s| {
            // Give the last star one more character and try again from there.
            p = s + 1;
            star_n += 1;
            n = star_n;
        } else {
            return false;
        }
    }

    // Trailing stars match nothing, which is what lets "a/*" match "a/".
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

pub fn hasWildcard(pattern: []const u8) bool {
    return std.mem.indexOfAny(u8, pattern, "*?") != null;
}

/// How many '/'-separated segments a topic name has. "a" is 1, "a/b" is 2.
pub fn segmentCount(name: []const u8) usize {
    return std.mem.count(u8, name, "/") + 1;
}

/// The `index`-th segment, or empty past the end. Empty segments are preserved: "a/" has
/// two, the second of which is empty, and a registry is free to hold such a name.
pub fn segment(name: []const u8, index: usize) []const u8 {
    var it = std.mem.splitScalar(u8, name, '/');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i == index) return part;
    }
    return "";
}

/// A depth cap, because topic names come off the network and recursion depth should not.
pub const max_tree_depth = 24;

/// Render one level of the tree into `out`. `names` is sorted and every entry shares its
/// first `depth` segments, which is what makes each child's run of descendants contiguous
/// -- so the tree is drawn straight out of the sorted array with no nodes built at all.
///
/// Into a buffer rather than onto the terminal so it can be tested: the interesting part
/// of a tree is which connector goes where, and that is not worth eyeballing.
pub fn renderTree(
    out: *std.ArrayList(u8),
    names: [][]const u8,
    depth: usize,
    prefix: *std.ArrayList(u8),
) void {
    if (depth >= max_tree_depth) return;

    var i: usize = 0;
    while (i < names.len) {
        // A name with exactly `depth` segments IS this level's parent, already rendered by
        // the caller; its children follow it.
        if (segmentCount(names[i]) <= depth) {
            i += 1;
            continue;
        }

        const key = segment(names[i], depth);

        // The run of entries under this same child.
        var j = i + 1;
        while (j < names.len and
            segmentCount(names[j]) > depth and
            std.mem.eql(u8, segment(names[j], depth), key)) : (j += 1)
        {}

        const last = j == names.len;
        // Sorted, so the run's own exact name -- if it is a registered topic rather than
        // just a shared prefix -- is its first entry.
        const is_topic = segmentCount(names[i]) == depth + 1;

        // Roots carry no connector. Giving them one would draw them as siblings under a
        // parent that does not exist.
        const connector: []const u8 = if (depth == 0)
            ""
        else if (last)
            "\u{2514}\u{2500}\u{2500} "
        else
            "\u{251c}\u{2500}\u{2500} ";

        // A trailing '/' marks a name that only groups others, the way a directory reads:
        // "lidar/" is not a topic anyone published, "lidar/helios32" is.
        out.print(allocator, "{s}{s}{s}{s}\n", .{
            prefix.items,
            connector,
            key,
            if (is_topic) "" else "/",
        }) catch {};

        const mark = prefix.items.len;
        // A root's children start at column 0 with their own connectors, so nothing is
        // pushed for depth 0.
        if (depth > 0) {
            prefix.appendSlice(allocator, if (last) "    " else "\u{2502}   ") catch {};
        }
        renderTree(out, names[i..j], depth + 1, prefix);
        prefix.shrinkRetainingCapacity(mark);

        i = j;
    }
}

/// Sort comparator for topic names. The tree renderer requires sorted input -- it groups by
/// walking runs of the sorted array -- and sorting also keeps both tools' output stable
/// against the registry's hash order.
pub fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// -- tests ----------------------------------------------------------------------------

const testing = std.testing;

test "globs match the way a shell would" {
    try testing.expect(globMatch("lidar/*", "lidar/helios32"));
    try testing.expect(globMatch("lidar/*", "lidar/helios32/calibration"));
    try testing.expect(globMatch("lidar/*", "lidar/"));
    try testing.expect(!globMatch("lidar/*", "lidar"));
    try testing.expect(!globMatch("lidar/*", "mesh/zig"));

    try testing.expect(globMatch("*", "anything"));
    try testing.expect(globMatch("*/calibration", "lidar/rs16/calibration"));
    try testing.expect(globMatch("mesh/?ig", "mesh/zig"));
    try testing.expect(!globMatch("mesh/?ig", "mesh/zzig"));

    // A star in the middle, and several of them: the case a naive matcher gets wrong.
    try testing.expect(globMatch("a*b*c", "abc"));
    try testing.expect(globMatch("a*b*c", "axxbyyc"));
    try testing.expect(!globMatch("a*b*c", "axxbyy"));

    // Backtracking: the first star must give ground for the literal tail to land.
    try testing.expect(globMatch("*bench", "test/bench"));
    try testing.expect(globMatch("test/*h", "test/bench"));
    try testing.expect(!globMatch("test/*h", "test/bencher"));

    try testing.expect(globMatch("exact", "exact"));
    try testing.expect(!globMatch("exact", "exactly"));
    try testing.expect(!hasWildcard("plain/topic"));
    try testing.expect(hasWildcard("plain/*"));
}

test "the tree groups by segment, and marks a prefix apart from a topic" {
    var names = [_][]const u8{
        "lidar/helios32",
        "lidar/helios32/calibration",
        "test/bench",
        "test/topic-a",
        "test/topic-b",
    };
    std.mem.sort([]const u8, &names, {}, lessThan);

    var prefix: std.ArrayList(u8) = .empty;
    defer prefix.deinit(allocator);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    renderTree(&out, &names, 0, &prefix);

    // "lidar/" has a slash: nobody published it, it only groups. "helios32" has none even
    // though it has a child, because it is a topic in its own right -- that distinction is
    // the whole reason the tree is more use than the flat list.
    try testing.expectEqualStrings(
        \\lidar/
        \\└── helios32
        \\    └── calibration
        \\test/
        \\├── bench
        \\├── topic-a
        \\└── topic-b
        \\
    , out.items);
}

test "a single topic, and one with no separator at all" {
    var prefix: std.ArrayList(u8) = .empty;
    defer prefix.deinit(allocator);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var flat = [_][]const u8{"heartbeat"};
    renderTree(&out, &flat, 0, &prefix);
    try testing.expectEqualStrings("heartbeat\n", out.items);

    // Two roots, neither with a connector: they are not siblings of anything.
    out.clearRetainingCapacity();
    var two = [_][]const u8{ "alpha", "beta" };
    renderTree(&out, &two, 0, &prefix);
    try testing.expectEqualStrings("alpha\nbeta\n", out.items);

    // Depth: the last child of a last child gets spaces, not a continuing bar.
    out.clearRetainingCapacity();
    var deep = [_][]const u8{ "a/b/c/d", "a/e" };
    std.mem.sort([]const u8, &deep, {}, lessThan);
    renderTree(&out, &deep, 0, &prefix);
    try testing.expectEqualStrings(
        \\a/
        \\├── b/
        \\│   └── c/
        \\│       └── d
        \\└── e
        \\
    , out.items);
}

test "segments split the way the tree needs" {
    try testing.expectEqual(@as(usize, 1), segmentCount("a"));
    try testing.expectEqual(@as(usize, 2), segmentCount("a/b"));
    try testing.expectEqual(@as(usize, 3), segmentCount("a/b/c"));
    // A trailing slash is a second, empty segment rather than an error: the registry can
    // hold any name a publisher registered.
    try testing.expectEqual(@as(usize, 2), segmentCount("a/"));

    try testing.expectEqualStrings("a", segment("a/b/c", 0));
    try testing.expectEqualStrings("b", segment("a/b/c", 1));
    try testing.expectEqualStrings("c", segment("a/b/c", 2));
    try testing.expectEqualStrings("", segment("a/b/c", 3));
    try testing.expectEqualStrings("", segment("a/", 1));
}
