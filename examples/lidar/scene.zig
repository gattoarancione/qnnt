//! The synthetic room both fakes transmit. Nothing model-specific in here: a beam goes in
//! as an azimuth and an elevation, a range and an intensity come out.
//!
//! Four walls of a 20 m x 14 m room, two pillars, and a box that drifts, so a viewer shows
//! a floor plan rather than noise. Intensity distinguishes the surfaces, which is what lets
//! a renderer colour them apart.

const std = @import("std");

pub const sensor_height_m: f32 = 1.0;
pub const room_half_x: f32 = 10.0;
pub const room_half_y: f32 = 7.0;

pub const intensity_wall: u8 = 120;
pub const intensity_pillar: u8 = 220;
pub const intensity_floor: u8 = 60;
pub const intensity_box: u8 = 255;

const Pillar = struct { x: f32, y: f32, r: f32 };
const pillars = [_]Pillar{
    .{ .x = 3.0, .y = 2.0, .r = 0.4 },
    .{ .x = -4.0, .y = -3.0, .r = 0.6 },
};

fn wallDistance(sin_a: f32, cos_a: f32) f32 {
    var best: f32 = 1e9;
    if (sin_a > 1e-6) best = @min(best, room_half_x / sin_a);
    if (sin_a < -1e-6) best = @min(best, -room_half_x / sin_a);
    if (cos_a > 1e-6) best = @min(best, room_half_y / cos_a);
    if (cos_a < -1e-6) best = @min(best, -room_half_y / cos_a);
    return best;
}

fn circleDistance(sin_a: f32, cos_a: f32, cx: f32, cy: f32, r: f32) ?f32 {
    const b = 2.0 * (sin_a * -cx + cos_a * -cy);
    const c = cx * cx + cy * cy - r * r;
    const disc = b * b - 4.0 * c;
    if (disc < 0) return null;
    const root = @sqrt(disc);
    const t0 = (-b - root) / 2.0;
    if (t0 > 0.05) return t0;
    const t1 = (-b + root) / 2.0;
    if (t1 > 0.05) return t1;
    return null;
}

fn boxDistance(sin_a: f32, cos_a: f32, phase: f32) ?f32 {
    const cx = 6.0 * @sin(phase);
    const cy: f32 = 4.5;
    const half: f32 = 0.7;

    var t_min: f32 = 0.05;
    var t_max: f32 = 1e9;

    if (@abs(sin_a) < 1e-6) {
        if (@abs(-cx) > half) return null;
    } else {
        const t1 = (cx - half) / sin_a;
        const t2 = (cx + half) / sin_a;
        t_min = @max(t_min, @min(t1, t2));
        t_max = @min(t_max, @max(t1, t2));
    }
    if (@abs(cos_a) < 1e-6) {
        if (@abs(-cy) > half) return null;
    } else {
        const t1 = (cy - half) / cos_a;
        const t2 = (cy + half) / cos_a;
        t_min = @max(t_min, @min(t1, t2));
        t_max = @min(t_max, @max(t1, t2));
    }
    if (t_min <= t_max and t_min > 0.05) return t_min;
    return null;
}

pub const Hit = struct { distance_mm: u16, intensity: u8 };

/// One beam against the room. `at_cdeg` is hundredths of a degree; the elevation is degrees.
pub fn beam(at_cdeg: u32, elevation_deg: f32, phase: f32) Hit {
    const azim = @as(f32, @floatFromInt(at_cdeg)) * std.math.pi / 18000.0;
    const elev = elevation_deg * std.math.pi / 180.0;
    const sin_a = @sin(azim);
    const cos_a = @cos(azim);

    var horizontal = wallDistance(sin_a, cos_a);
    var intensity = intensity_wall;

    for (pillars) |p| {
        if (circleDistance(sin_a, cos_a, p.x, p.y, p.r)) |d| {
            if (d < horizontal) {
                horizontal = d;
                intensity = intensity_pillar;
            }
        }
    }
    if (boxDistance(sin_a, cos_a, phase)) |d| {
        if (d < horizontal) {
            horizontal = d;
            intensity = intensity_box;
        }
    }

    const cos_e = @cos(elev);
    var range = if (cos_e > 1e-6) horizontal / cos_e else 1e9;

    if (elev < -1e-6) {
        const floor = sensor_height_m / @sin(-elev);
        if (floor < range) {
            range = floor;
            intensity = intensity_floor;
        }
    } else if (elev > 1e-6) {
        // Upward past the walls is sky: no return, which is 0 on the wire. A Helios sees a
        // lot more of this than an RS-16 does, its beams reaching much further down and up.
        const ceiling = 3.0 / @sin(elev);
        if (ceiling < range) return .{ .distance_mm = 0, .intensity = 0 };
    }

    if (range > 60.0) return .{ .distance_mm = 0, .intensity = 0 };
    return .{
        .distance_mm = @intFromFloat(@min(range * 1000.0, 65535.0)),
        .intensity = intensity,
    };
}
