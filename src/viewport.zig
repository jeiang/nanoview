//! Where the picture sits in the window: scale, position, and the part of
//! the bitmap to draw. Pure arithmetic, no nanoui.
const std = @import("std");
const FitMode = @import("settings.zig").FitMode;
const assert = std.debug.assert;

pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };
pub const Visible = struct { box: Rect, part: [4]f32 };

pub const scale_factor_max: f32 = 32; // 3200 %
pub const scale_factor_min: f32 = 0.1;
/// Keeps every scale above zero, so a division by it is always defined,
/// also before the window has reported its size.
const scale_floor: f32 = 1e-4;

pub const Viewport = struct {
    image_w: f32, // upright size in pixels, after quarter turns
    image_h: f32,
    view_w: f32 = 0, // points
    view_h: f32 = 0,
    dpr: f32 = 1, // device pixels per point
    scale: f32 = 1, // points per image pixel
    x: f32 = 0, // image top left, in view points
    y: f32 = 0,
    fit: bool = true,
    fit_mode: FitMode = .whole,
    fit_upscale: bool = false,
    mirror: bool = false,
    flip: bool = false,

    fn check(vp: *const Viewport) void {
        assert(vp.image_w > 0 and vp.image_h > 0);
        assert(std.math.isFinite(vp.image_w) and std.math.isFinite(vp.image_h));
        assert(vp.view_w >= 0 and vp.view_h >= 0);
        assert(vp.dpr > 0 and std.math.isFinite(vp.dpr));
        assert(vp.scale > 0 and std.math.isFinite(vp.scale));
        assert(std.math.isFinite(vp.x) and std.math.isFinite(vp.y));
    }

    pub fn scale_fit(vp: *const Viewport) f32 {
        vp.check();
        const w = vp.view_w / vp.image_w;
        const h = vp.view_h / vp.image_h;
        const s = switch (vp.fit_mode) {
            .whole => @min(w, h),
            .width => w,
            .height => h,
            .fill => @max(w, h),
        };
        const cap = if (vp.fit_upscale) vp.scale_max() else 1 / vp.dpr;
        return std.math.clamp(s, scale_floor, @max(cap, scale_floor));
    }

    pub fn scale_min(vp: *const Viewport) f32 {
        return @min(scale_factor_min / vp.dpr, vp.scale_fit());
    }

    pub fn scale_max(vp: *const Viewport) f32 {
        vp.check();
        const result = scale_factor_max / vp.dpr;
        assert(result >= 1 / vp.dpr);
        return result;
    }

    pub fn set_view(vp: *Viewport, w: f32, h: f32, dpr: f32) void {
        assert(w >= 0 and h >= 0 and std.math.isFinite(w) and std.math.isFinite(h));
        assert(dpr > 0 and std.math.isFinite(dpr));
        vp.view_w = w;
        vp.view_h = h;
        vp.dpr = dpr;
        vp.settle();
    }

    pub fn settle(vp: *Viewport) void {
        vp.check();
        const lo = vp.scale_min();
        const hi = vp.scale_max();
        assert(lo <= hi);
        if (vp.fit) vp.scale = vp.scale_fit();
        vp.scale = std.math.clamp(vp.scale, lo, hi);
        vp.x = place(vp.x, vp.image_w * vp.scale, vp.view_w);
        vp.y = place(vp.y, vp.image_h * vp.scale, vp.view_h);
        assert(lo <= vp.scale and vp.scale <= hi);
        vp.check();
    }

    /// Centers an extent smaller than the view; else keeps no blank gap at an edge.
    fn place(position: f32, extent: f32, view: f32) f32 {
        assert(extent > 0 and view >= 0);
        if (extent <= view) return (view - extent) / 2;
        const result = std.math.clamp(position, view - extent, 0);
        assert(result <= 0 and result >= view - extent);
        return result;
    }

    /// The image point under (px, py) stays there unless an edge clamp moves it.
    pub fn zoom_about(vp: *Viewport, px: f32, py: f32, factor: f32) void {
        assert(factor > 0 and std.math.isFinite(factor));
        assert(std.math.isFinite(px) and std.math.isFinite(py));
        vp.check();
        const s0 = vp.scale;
        const s1 = std.math.clamp(s0 * factor, vp.scale_min(), vp.scale_max());
        vp.x = px - (px - vp.x) * s1 / s0;
        vp.y = py - (py - vp.y) * s1 / s0;
        vp.scale = s1;
        vp.fit = false;
        vp.settle();
    }

    pub fn pan(vp: *Viewport, dx: f32, dy: f32) void {
        assert(std.math.isFinite(dx) and std.math.isFinite(dy));
        vp.x += dx;
        vp.y += dy;
        vp.settle();
    }

    pub fn set_fit(vp: *Viewport) void {
        vp.fit = true;
        vp.settle();
        assert(vp.scale == vp.scale_fit());
    }

    pub fn set_actual(vp: *Viewport) void {
        vp.check();
        vp.zoom_about(vp.view_w / 2, vp.view_h / 2, (1 / vp.dpr) / vp.scale);
        assert(vp.scale >= vp.scale_min());
    }

    pub fn toggle_fit_actual(vp: *Viewport) void {
        vp.check();
        if (vp.fit and vp.scale_fit() < 1 / vp.dpr) vp.set_actual() else vp.set_fit();
        assert(vp.scale <= vp.scale_max());
    }

    /// Preserve the normalized point at the window center, not pixel offsets.
    pub fn carry(vp: *Viewport, previous: Viewport) void {
        vp.check();
        previous.check();
        const u = (previous.view_w / 2 - previous.x) /
            (previous.image_w * previous.scale);
        const v = (previous.view_h / 2 - previous.y) /
            (previous.image_h * previous.scale);
        vp.scale = std.math.clamp(previous.scale, vp.scale_min(), vp.scale_max());
        vp.fit = false;
        vp.x = vp.view_w / 2 - u * vp.image_w * vp.scale;
        vp.y = vp.view_h / 2 - v * vp.image_h * vp.scale;
        vp.settle();
    }

    pub fn percent(vp: *const Viewport) u32 {
        vp.check();
        const p = @round(vp.scale * vp.dpr * 100);
        assert(p >= 0 and p <= scale_factor_max * 100);
        return @intFromFloat(p);
    }

    /// What to draw so the box overlaps the window before rotation: the
    /// shown rect, as a box rotated by `turns` about its center, and the
    /// part of the unrotated bitmap inside it.
    pub fn visible(vp: *const Viewport, turns: u2) ?Visible {
        vp.check();
        const dw = vp.image_w * vp.scale;
        const dh = vp.image_h * vp.scale;
        const x0 = @max(vp.x, 0);
        const y0 = @max(vp.y, 0);
        const x1 = @min(vp.x + dw, vp.view_w);
        const y1 = @min(vp.y + dh, vp.view_h);
        if (x1 <= x0 or y1 <= y0) return null;
        const u = [2]f32{ (x0 - vp.x) / dw, (x1 - vp.x) / dw };
        const v = [2]f32{ (y0 - vp.y) / dh, (y1 - vp.y) / dh };
        const a = vp.raw(turns, u[0], v[0]);
        const b = vp.raw(turns, u[1], v[1]);
        // Quarter turns reverse axes themselves; reflections must remain
        // in the UV endpoints so the renderer reflects, not just crops.
        var part = [4]f32{
            @min(a[0], b[0]), @min(a[1], b[1]),
            @max(a[0], b[0]), @max(a[1], b[1]),
        };
        const mx = if (turns % 2 == 0) vp.mirror else vp.flip;
        const my = if (turns % 2 == 0) vp.flip else vp.mirror;
        if (mx) std.mem.swap(f32, &part[0], &part[2]);
        if (my) std.mem.swap(f32, &part[1], &part[3]);
        const w = x1 - x0;
        const h = y1 - y0;
        const bw = if (turns % 2 == 0) w else h;
        const bh = if (turns % 2 == 0) h else w;
        const cx = x0 + w / 2;
        const cy = y0 + h / 2;
        return .{ .box = .{ .x = cx - bw / 2, .y = cy - bh / 2, .w = bw, .h = bh }, .part = part };
    }

    /// Upright normalized (u, v) to raw bitmap (p, q), for `turns`
    /// clockwise quarter turns from raw to upright.
    fn raw(vp: *const Viewport, turns: u2, upright_u: f32, upright_v: f32) [2]f32 {
        const u = if (vp.mirror) 1 - upright_u else upright_u;
        const v = if (vp.flip) 1 - upright_v else upright_v;
        assert(u >= -0.001 and u <= 1.001);
        assert(v >= -0.001 and v <= 1.001);
        return switch (turns) {
            0 => .{ u, v },
            1 => .{ v, 1 - u },
            2 => .{ 1 - u, 1 - v },
            3 => .{ 1 - v, u },
        };
    }
};

const expect = std.testing.expect;
const approx = std.testing.expectApproxEqAbs;

test "fit centers a small and a large image" {
    var small: Viewport = .{ .image_w = 100, .image_h = 50 };
    small.set_view(400, 300, 1);
    try approx(1, small.scale, 0.0001);
    try approx(150, small.x, 0.0001);
    try approx(125, small.y, 0.0001);
    var large: Viewport = .{ .image_w = 800, .image_h = 300 };
    large.set_view(400, 300, 2);
    try approx(0.5, large.scale, 0.0001);
    try approx(0, large.x, 0.0001);
    try approx(75, large.y, 0.0001);
}

test "zoom_about keeps the pointer's image point fixed" {
    var vp: Viewport = .{ .image_w = 1000, .image_h = 1000 };
    vp.set_view(400, 400, 1);
    vp.zoom_about(100, 100, 4); // 0.4 -> 1.6: the image overfills the view
    const before_x = (150 - vp.x) / vp.scale;
    const before_y = (220 - vp.y) / vp.scale;
    vp.zoom_about(150, 220, 1.25);
    try approx(before_x, (150 - vp.x) / vp.scale, 0.01);
    try approx(before_y, (220 - vp.y) / vp.scale, 0.01);
    try expect(!vp.fit);
}

test "zooming out below fit centers at the named minimum" {
    var vp: Viewport = .{ .image_w = 1000, .image_h = 500 };
    vp.set_view(400, 400, 1);
    vp.zoom_about(200, 200, 0.01);
    try expect(!vp.fit);
    try approx(0.1, vp.scale, 0.0001);
    try approx(150, vp.x, 0.0001);
    try approx(175, vp.y, 0.0001);
    vp.set_fit();
    try approx(0.4, vp.scale, 0.0001);
}

test "pan clamps at edges" {
    var vp: Viewport = .{ .image_w = 1000, .image_h = 1000 };
    vp.set_view(400, 400, 1);
    vp.set_actual();
    vp.pan(10000, 10000);
    try approx(0, vp.x, 0.0001);
    try approx(0, vp.y, 0.0001);
    vp.pan(-10000, -10000);
    try approx(-600, vp.x, 0.0001);
    try approx(-600, vp.y, 0.0001);
}

test "visible of a centered image shows it whole for every turn" {
    var vp: Viewport = .{ .image_w = 200, .image_h = 100 };
    vp.set_view(400, 300, 1);
    for ([_]u2{ 0, 1, 2, 3 }) |turns| {
        const v = vp.visible(turns).?;
        for (v.part, [4]f32{ 0, 0, 1, 1 }) |got, want| try approx(want, got, 0.0001);
        const odd = turns % 2 == 1;
        try approx(@as(f32, if (odd) 100 else 200), v.box.w, 0.0001);
        try approx(@as(f32, if (odd) 200 else 100), v.box.h, 0.0001);
        try approx(200, v.box.x + v.box.w / 2, 0.0001);
        try approx(150, v.box.y + v.box.h / 2, 0.0001);
    }
}

test "visible maps the upright bottom half for one turn" {
    var vp: Viewport = .{ .image_w = 100, .image_h = 100 };
    vp.set_view(100, 50, 1);
    vp.zoom_about(50, 25, 2); // scale 1: the image is 100 x 100 in a 100 x 50 view
    vp.pan(0, -1000); // bottom half
    const v = vp.visible(1).?;
    for (v.part, [4]f32{ 0.5, 0, 1, 1 }) |got, want| try approx(want, got, 0.0001);
}

test "fit modes and upscale select the requested side" {
    var vp: Viewport = .{ .image_w = 800, .image_h = 200, .fit_upscale = true };
    vp.set_view(400, 300, 1);
    for ([_]FitMode{ .whole, .width, .height, .fill }, [_]f32{ 0.5, 0.5, 1.5, 1.5 }) |m, s| {
        vp.fit_mode = m;
        vp.set_fit();
        try approx(s, vp.scale, 0.0001);
    }
    vp.fit_upscale = false;
    vp.set_fit();
    try approx(1, vp.scale, 0.0001);
    vp.image_w = 80;
    vp.image_h = 20;
    vp.fit_mode = .whole;
    vp.fit_upscale = true;
    vp.set_fit();
    try approx(5, vp.scale, 0.0001);
}

test "zoom lock carries scale and normalized center and clamps new limits" {
    var previous: Viewport = .{ .image_w = 1000, .image_h = 800 };
    previous.set_view(400, 300, 1);
    previous.set_actual();
    previous.pan(-100, -100);
    var next: Viewport = .{ .image_w = 2000, .image_h = 1600 };
    next.set_view(400, 300, 1);
    next.carry(previous);
    try approx(previous.scale, next.scale, 0.0001);
    try approx((200 - previous.x) / 1000, (200 - next.x) / 2000, 0.0001);
    try approx((150 - previous.y) / 800, (150 - next.y) / 1600, 0.0001);
    next.image_w = 10;
    next.image_h = 10;
    next.carry(previous);
    try approx(195, next.x, 0.0001);
    try approx(145, next.y, 0.0001);
    previous.scale = 0.01;
    next.carry(previous);
    try approx(0.1, next.scale, 0.0001);
}

test "reflected crops map to raw pixels for every quarter turn" {
    var vp: Viewport = .{ .image_w = 100, .image_h = 100 };
    vp.set_view(40, 30, 1);
    vp.set_actual();
    vp.pan(-1000, -1000);
    for ([_]u2{ 0, 1, 2, 3 }) |turns| {
        for ([_]bool{ false, true }) |mirror| {
            for ([_]bool{ false, true }) |flip| {
                vp.mirror = mirror;
                vp.flip = flip;
                const u: f32 = if (mirror) 0.4 else 0.6;
                const v: f32 = if (flip) 0.3 else 0.7;
                const expected: [2]f32 = switch (turns) {
                    0 => .{ u, v },
                    1 => .{ v, 1 - u },
                    2 => .{ 1 - u, 1 - v },
                    3 => .{ 1 - v, u },
                };
                const raw = vp.raw(turns, 0.6, 0.7);
                try approx(expected[0], raw[0], 0.0001);
                try approx(expected[1], raw[1], 0.0001);
                const shown = vp.visible(turns).?;
                const mx = if (turns % 2 == 0) mirror else flip;
                const my = if (turns % 2 == 0) flip else mirror;
                try expect((shown.part[0] > shown.part[2]) == mx);
                try expect((shown.part[1] > shown.part[3]) == my);
                const before = vp.raw(turns, (20 - vp.x) / 100, (15 - vp.y) / 100);
                vp.zoom_about(20, 15, 1.25);
                const side = 100 * vp.scale;
                const after = vp.raw(turns, (20 - vp.x) / side, (15 - vp.y) / side);
                try approx(before[0], after[0], 0.0001);
                try approx(before[1], after[1], 0.0001);
                vp.set_actual();
                vp.pan(-1000, -1000);
            }
        }
    }
}

test "minimum respects a fit scale below ten percent" {
    var vp: Viewport = .{ .image_w = 10000, .image_h = 10000 };
    vp.set_view(400, 300, 2);
    try approx(0.03, vp.scale_min(), 0.0001);
    vp.zoom_about(200, 150, 0.1);
    try approx(0.03, vp.scale, 0.0001);
    try expect(!vp.fit);
    vp.set_fit();
    try expect(vp.fit);
}
