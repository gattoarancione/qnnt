//! The synthetic scene the fake camera looks at: a room, rendered to a depth map and a
//! mono image through the same pinhole model the driver deprojects with.
//!
//! The counterpart of examples/lidar/scene.zig, and it carries the same warning: rendering
//! a scene with the model the driver inverts means the two agree by construction, so a
//! round trip through here proves the arithmetic is consistent and nothing about whether it
//! matches a real ZED X. What it is good for is exercising the chain -- and for one thing
//! the LiDAR scene taught, which is that a fake that is too tidy hides bugs. So this one
//! drops depth the way a stereo camera actually does.
//!
//! A depth map holds Z, not range. That distinction is the whole reason the ray direction
//! below is left unnormalised with its z component at 1: the intersection parameter `t` is
//! then the depth directly, and there is no place to accidentally store a radial distance
//! that would bow the whole scene outward.

const std = @import("std");
const frame = @import("frame");

/// Camera height above the floor, metres. The camera frame has +y pointing down, so the
/// floor is at +1.2 and the ceiling above it is negative.
pub const camera_height_m: f32 = 1.2;
pub const ceiling_m: f32 = 1.5;
pub const back_wall_m: f32 = 6.0;
pub const side_wall_m: f32 = 3.0;

/// Luminance bands, chosen so a viewer colouring by intensity can tell surfaces apart --
/// the same trick the LiDAR scene uses, and the same caveat: on a real camera this byte is
/// image luminance and carries no notion of "which surface".
pub const mono_floor: u8 = 70;
pub const mono_wall: u8 = 150;
pub const mono_sphere: u8 = 210;
pub const mono_box: u8 = 250;

const Hit = struct { z_m: f32, mono: u8 };

/// Cheap deterministic hash, for the dropout pattern. Deterministic on purpose: a fake that
/// varies run to run cannot be diffed against itself, and nothing here needs real entropy.
fn hash(a: u32, b: u32, c: u32) u32 {
    var h: u32 = 2166136261;
    inline for (.{ a, b, c }) |v| {
        h ^= v;
        h = h *% 16777619;
    }
    return h;
}

/// Where a ray through pixel (u, v) lands. `phase` walks 0..1 to move the box.
fn trace(intr: *const frame.Intrinsics, u: u16, v: u16, phase: f32) ?Hit {
    // Unnormalised, z = 1, so any intersection parameter IS the depth in metres.
    const dx = (@as(f32, @floatFromInt(u)) - intr.cx) / intr.fx;
    const dy = (@as(f32, @floatFromInt(v)) - intr.cy) / intr.fy;

    var best: f32 = back_wall_m;
    var mono: u8 = mono_wall;

    // Floor and ceiling: horizontal planes, hit when the ray has vertical travel.
    if (dy > 1e-4) {
        const t = camera_height_m / dy;
        if (t < best) {
            best = t;
            mono = mono_floor;
        }
    } else if (dy < -1e-4) {
        const t = ceiling_m / -dy;
        if (t < best) {
            best = t;
            mono = mono_wall;
        }
    }

    // Side walls.
    if (@abs(dx) > 1e-4) {
        const t = side_wall_m / @abs(dx);
        if (t < best) {
            best = t;
            mono = mono_wall;
        }
    }

    // A sphere, and a box that slides across the scene. Both as spheres, because what this
    // needs is curved depth for the viewer to show, not a modelling exercise.
    const spheres = [_]struct { x: f32, y: f32, z: f32, r: f32, mono: u8 }{
        .{ .x = -0.8, .y = 0.5, .z = 3.0, .r = 0.45, .mono = mono_sphere },
        .{ .x = -1.6 + 3.2 * phase, .y = 0.2, .z = 4.2, .r = 0.35, .mono = mono_box },
    };

    for (spheres) |s| {
        // |t*d - c|^2 = r^2, with d = (dx, dy, 1).
        const a = dx * dx + dy * dy + 1.0;
        const b = -2.0 * (dx * s.x + dy * s.y + s.z);
        const c = s.x * s.x + s.y * s.y + s.z * s.z - s.r * s.r;
        const disc = b * b - 4.0 * a * c;
        if (disc < 0) continue;

        const t = (-b - @sqrt(disc)) / (2.0 * a);
        if (t > 0.0 and t < best) {
            best = t;
            mono = s.mono;
        }
    }

    if (best <= 0.0) return null;
    return .{ .z_m = best, .mono = mono };
}

/// Render one frame. `depth` and `mono` must hold `intr.width * intr.height` entries.
pub fn render(
    intr: *const frame.Intrinsics,
    seq: u32,
    phase: f32,
    depth: []u16,
    mono: []u8,
) void {
    var v: u16 = 0;
    while (v < intr.height) : (v += 1) {
        var u: u16 = 0;
        while (u < intr.width) : (u += 1) {
            const at = @as(usize, v) * intr.width + u;

            const hit = trace(intr, u, v, phase) orelse {
                depth[at] = 0;
                mono[at] = 0;
                continue;
            };

            // Texture, so the image is not flat bands. A real stereo matcher needs texture
            // to find depth at all, which is the physical reason for the dropouts below.
            const grain = @as(u8, @truncate((hash(u, v, 0) >> 9) & 0x1f));
            mono[at] = hit.mono -| grain;

            const mm_f = hit.z_m * 1000.0;
            if (mm_f < @as(f32, @floatFromInt(intr.depth_min_mm)) or
                mm_f > @as(f32, @floatFromInt(intr.depth_max_mm)))
            {
                // Outside the rated window the camera reports nothing, which the driver
                // would enforce anyway -- doing it here too keeps the fake honest rather
                // than relying on someone downstream to clean up.
                depth[at] = 0;
                continue;
            }

            // Stereo dropout. This is the lesson from the LiDAR fakes, applied on purpose:
            // a scene with depth everywhere is not what a stereo camera produces, and a
            // consumer written against a gapless depth map falls over on the first real
            // frame. Roughly 6% of pixels, varying per frame so it reads as noise rather
            // than as a dirty lens, and heavier on the dim floor where a real matcher
            // struggles most.
            const roll = hash(u, v, seq) % 1000;
            const limit: u32 = if (hit.mono == mono_floor) 110 else 45;
            if (roll < limit) {
                depth[at] = 0;
                continue;
            }

            depth[at] = @intFromFloat(mm_f);
        }
    }
}

// -- tests ----------------------------------------------------------------------------

const testing = std.testing;

test "the scene renders geometry the driver can invert" {
    const intr_test: frame.Intrinsics = .{
        .model = "test",
        .width = 64,
        .height = 40,
        .fx = 32.0,
        .fy = 32.0,
        .cx = 31.5,
        .cy = 19.5,
        .baseline_mm = 120,
        .depth_min_mm = 300,
        .depth_max_mm = 20_000,
    };

    const n = @as(usize, intr_test.width) * intr_test.height;
    const depth = try testing.allocator.alloc(u16, n);
    defer testing.allocator.free(depth);
    const mono = try testing.allocator.alloc(u8, n);
    defer testing.allocator.free(mono);

    render(&intr_test, 0, 0.5, depth, mono);

    var with_depth: usize = 0;
    var max_mm: u16 = 0;
    for (depth) |d| {
        if (d != 0) {
            with_depth += 1;
            max_mm = @max(max_mm, d);
        }
    }

    // Most of the frame has depth, but not all of it: the dropouts are the point.
    try testing.expect(with_depth > n / 2);
    try testing.expect(with_depth < n);

    // Nothing beyond the back wall, and nothing inside the rated minimum.
    try testing.expect(max_mm <= @as(u16, @intFromFloat(back_wall_m * 1000.0)) + 1);
    for (depth) |d| {
        if (d != 0) try testing.expect(d >= intr_test.depth_min_mm);
    }

    // Deprojecting a pixel with depth gives a point in front of the camera, and the centre
    // row should look straight down the room at the back wall.
    const f: frame.StereoFrame = .{
        .seq = 0,
        .t_us = 0,
        .width = intr_test.width,
        .height = intr_test.height,
        .depth_mm = depth,
        .mono = mono,
        .missed = 0,
    };

    var found = false;
    var u: u16 = 0;
    while (u < intr_test.width) : (u += 1) {
        if (frame.deproject(&intr_test, f, u, 19)) |p| {
            try testing.expect(p.y > 0.0); // forward, never behind
            found = true;
        }
    }
    try testing.expect(found);
}

test "dropouts move between frames rather than staying put" {
    // A static pattern would read as a dirty lens and, worse, would let a consumer that
    // caches "where there is no depth" appear to work.
    const intr: frame.Intrinsics = .{
        .model = "test",
        .width = 64,
        .height = 40,
        .fx = 32.0,
        .fy = 32.0,
        .cx = 31.5,
        .cy = 19.5,
        .baseline_mm = 120,
        .depth_min_mm = 300,
        .depth_max_mm = 20_000,
    };
    const n = @as(usize, intr.width) * intr.height;

    const d0 = try testing.allocator.alloc(u16, n);
    defer testing.allocator.free(d0);
    const d1 = try testing.allocator.alloc(u16, n);
    defer testing.allocator.free(d1);
    const mono = try testing.allocator.alloc(u8, n);
    defer testing.allocator.free(mono);

    render(&intr, 0, 0.5, d0, mono);
    render(&intr, 1, 0.5, d1, mono);

    var differ: usize = 0;
    for (d0, d1) |a, b| {
        if ((a == 0) != (b == 0)) differ += 1;
    }
    try testing.expect(differ > 0);

    // Same seq and phase must render identically, though: the fake is deterministic so a
    // capture can be compared against itself.
    render(&intr, 0, 0.5, d1, mono);
    try testing.expectEqualSlices(u16, d0, d1);
}
