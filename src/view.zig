//! The window's content: the picture, the keys and the pointer.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("nanoui").ui;
const app = @import("app.zig");
const paths = @import("paths.zig");
const orientation = @import("orientation.zig");
const viewport = @import("viewport.zig");
const preload = @import("preload.zig");
const actions = @import("actions.zig");
const State = app.State;
const assert = std.debug.assert;

const mac = builtin.os.tag == .macos;
const hint = if (mac) "Drop an image, or press ⌘O" else "Drop an image, or press Ctrl+O";

pub fn view(s: *State, c: *ui.Context) void {
    ui.imageLimits(c, .{
        .picture_side = 8192,
        .atlas_side = 8192,
        .decoded_bytes = 128 * 1024 * 1024,
    });
    c.wants_wheel = true;
    c.wants_moves = c.input.down;
    keys(s, c);

    const root = ui.div(c).sizeFull().center().bg(c.theme.background);
    defer root.end();
    drops(s, c, root.index);
    body(s, c);
    message(s, c);
}

fn body(s: *State, c: *ui.Context) void {
    assert(s.path_len <= paths.path_max);
    if (s.status == .empty) {
        ui.text(c, hint, .{ .color = c.theme.muted });
        return;
    }
    var key_buf: [16]u8 = undefined;
    if (s.status == .shown and s.viewport_generation != s.generation) {
        new_picture(s, c, s.picture_key(&key_buf));
    }
    if (s.status != .shown) {
        ui.text(c, c.print("Cannot show {s}", .{s.basename()}), .{ .color = c.theme.muted });
        return;
    }
    s.viewport.set_view(c.size.w, c.size.h, c.scale);
    fit_options(s);
    preload_bounds(s, c);
    pointer(s, c);
    if (s.source == .pixels and !s.promote_failed and needs_promote(s, c)) s.promote();
    draw(s, c, s.picture_key(&key_buf));
    if (s.info_shown) info(s, c);
}

const message_seconds: f64 = 4;

/// What `State.notify` last said, for a few seconds, above the info line.
fn message(s: *State, c: *ui.Context) void {
    assert(s.message_len <= app.message_len_max);
    if (s.message_len == 0) return;
    // A command has no clock: the first frame that sees its message starts it.
    if (s.message_until == null) s.message_until = c.time + message_seconds;
    const left = s.message_until.? - c.time;
    if (left <= 0) {
        s.message_len = 0;
        return;
    }
    c.frameIn(@floatCast(left));
    const box = ui.div(c).absolute().offset(12, c.size.h - 72).px(8).py(4).rounded(6)
        .bg(ui.Color.black.alpha(0.6));
    defer box.end();
    ui.text(c, s.message(), .{ .size = info_text_size, .color = ui.Color.white });
}

/// The upright size and turns of a newly loaded picture, and a fitted view.
fn new_picture(s: *State, c: *ui.Context, key: []const u8) void {
    assert(s.status == .shown);
    switch (s.source) {
        // The worker's pixels are already upright.
        .pixels => |px| s.base = .{
            .raw_w = @floatFromInt(px.native_w),
            .raw_h = @floatFromInt(px.native_h),
            .turns = 0,
        },
        .encoded => |bytes| {
            const size = ui.imageSize(c, key, bytes) orelse {
                s.status = .failed;
                return;
            };
            s.base = orientation.upright(size.w, size.h, orientation.read(bytes));
        },
        .none => {
            s.status = .failed;
            return;
        },
    }
    const previous = s.viewport;
    const carry = s.settings.zoom_lock and s.viewport_generation != 0;
    reset_viewport(s, c, !carry);
    if (carry) s.viewport.carry(previous);
    s.viewport_generation = s.generation;
    assert(s.base.raw_w > 0 and s.base.raw_h > 0);
}

/// macOS decodes neighbors to the pixels a fitted picture may fill: the
/// window when full screen, else the bound `resize_window` uses.
fn preload_bounds(s: *State, c: *const ui.Context) void {
    if (!preload.decoded) return;
    assert(c.scale > 0);
    var w: f64 = c.size.w;
    var h: f64 = c.size.h;
    if (s.window) |win| {
        const m = win.monitorSize();
        if (!win.isFullScreen() and m[0] > 0 and m[1] > 0) {
            w = m[0] * window_screen_share;
            h = m[1] * window_screen_share;
        }
    }
    w = @max(1, @ceil(w * c.scale));
    h = @max(1, @ceil(h * c.scale));
    s.preload.set_bounds(@intFromFloat(w), @intFromFloat(h));
}

/// Zoomed past the preloaded pixels, or the window grew.
fn needs_promote(s: *const State, c: *const ui.Context) bool {
    const px = s.source.pixels;
    const vp = &s.viewport;
    const needed = @ceil(@max(vp.image_w, vp.image_h) * vp.scale * c.scale);
    const have: f32 = @floatFromInt(@max(px.width, px.height));
    assert(needed > 0 and have > 0);
    return needed > have + 2;
}

fn drops(s: *State, c: *ui.Context, index: u32) void {
    c.acceptDrop(index);
    const drop = c.dropAt(index) orelse return;
    if (drop.urls.len == 0) return;
    // The drop lasts one frame: copy before open_path reads it.
    var buf: [paths.path_max]u8 = undefined;
    const dropped = paths.from_file_url(drop.urls[0], &buf) orelse return;
    assert(dropped.len > 0);
    s.open_path(dropped);
}

fn draw(s: *State, c: *ui.Context, key: []const u8) void {
    assert(key.len > 0);
    const turns = s.base.turns +% s.turns_user;
    const v = s.viewport.visible(turns) orelse return;
    assert(v.box.w > 0 and v.box.h > 0);
    if (s.settings.checkerboard) checkerboard(s, c);
    const angle = @as(f32, @floatFromInt(turns)) * std.math.pi / 2;
    const turn = ui.div(c).absolute().offset(v.box.x, v.box.y).rotate(angle);
    defer turn.end();
    const source: ui.ImageSource = switch (s.source) {
        .encoded => |bytes| .{ .encoded = bytes },
        .pixels => |px| .{ .pixels = .{ .bgra = px.bgra, .width = px.width, .height = px.height } },
        .none => unreachable, // status is shown
    };
    _ = ui.image(c, .{
        .key = key,
        .source = source,
        .box = .{ .w = v.box.w, .h = v.box.h },
        .part = v.part,
        .sampling = if (!s.settings.smooth and s.viewport.percent() > 100) .nearest else .linear,
        .radius = 0,
    });
}

/// Back to fit, for a new picture or a new turn.
fn reset_viewport(s: *State, c: *ui.Context, resize: bool) void {
    assert(s.base.raw_w > 0 and s.base.raw_h > 0);
    const odd = s.turns_user % 2 == 1;
    const w = if (odd) s.base.raw_h else s.base.raw_w;
    const h = if (odd) s.base.raw_w else s.base.raw_h;
    s.viewport = .{
        .image_w = w,
        .image_h = h,
        .mirror = s.mirror,
        .flip = s.flip,
        .fit_mode = s.settings.fit_mode,
        .fit_upscale = s.settings.fit_upscale,
    };
    s.viewport.set_view(c.size.w, c.size.h, c.scale);
    if (resize) resize_window(s, c);
}

/// View only: nothing is written to disk.
fn rotate(s: *State, c: *ui.Context, quarter: u2) void {
    if (s.status != .shown or s.viewport_generation != s.generation) return;
    assert(quarter == 1 or quarter == 3);
    s.turns_user +%= quarter;
    reset_viewport(s, c, true);
}

const window_w_min: f64 = 320;
const window_h_min: f64 = 240;
const window_screen_share: f64 = 0.8;

/// The window takes the picture's size, within 80 % of the screen.
fn resize_window(s: *State, c: *const ui.Context) void {
    // Windows has no setSize in nanoui.
    if (comptime !@hasDecl(@import("nanoui").Window, "setSize")) return;
    const w = s.window orelse return;
    if (w.isFullScreen()) return;
    const m = w.monitorSize();
    // GTK 4 reports the window's own size as the screen's: fitting to it
    // would shrink the window with every picture.
    const content = w.contentSize();
    if (m[0] <= 0 or m[1] <= 0 or (m[0] == content[0] and m[1] == content[1])) return;
    assert(c.scale > 0);
    const pic_w: f64 = s.viewport.image_w / c.scale;
    const pic_h: f64 = s.viewport.image_h / c.scale;
    const room_w = m[0] * window_screen_share;
    const room_h = m[1] * window_screen_share;
    const fit = @min(1, @min(room_w / pic_w, room_h / pic_h));
    const target_w = @max(window_w_min, pic_w * fit);
    const target_h = @max(window_h_min, pic_h * fit);
    assert(target_w >= window_w_min and target_h >= window_h_min);
    w.setSize(target_w, target_h);
}

const info_text_size: f32 = 12;

/// Name, upright pixel size, zoom and position in the folder.
fn info(s: *State, c: *ui.Context) void {
    assert(s.status == .shown);
    const vp = &s.viewport;
    const pw: u32 = @intFromFloat(vp.image_w);
    const ph: u32 = @intFromFloat(vp.image_h);
    const name = s.basename();
    const line = if (s.index) |i|
        c.print("{s} · {d}×{d} · {d}% · {d}/{d}", .{
            name, pw, ph, vp.percent(), i + 1, s.folder.count,
        })
    else
        c.print("{s} · {d}×{d} · {d}%", .{ name, pw, ph, vp.percent() });
    const box = ui.div(c).absolute().offset(12, c.size.h - 40).px(8).py(4).rounded(6)
        .bg(ui.Color.black.alpha(0.6));
    defer box.end();
    ui.text(c, line, .{ .size = info_text_size, .color = ui.Color.white });
}

fn pointer(s: *State, c: *ui.Context) void {
    assert(s.status == .shown);
    const in = &c.input;
    const vp = &s.viewport;
    if (in.zoom != 1 and in.zoom > 0) {
        vp.zoom_about(in.mouse.x, in.mouse.y, in.zoom);
        vp.pan(in.pan.x, in.pan.y);
    }
    if (in.scroll.x != 0 or in.scroll.y != 0) {
        if (in.precise) {
            vp.pan(in.scroll.x, in.scroll.y);
        } else if (in.scroll.y != 0) {
            // One step per wheel event, whatever its unit.
            const step = zoom_step(s);
            const factor = if (in.scroll.y > 0) step else 1 / step;
            vp.zoom_about(in.mouse.x, in.mouse.y, factor);
        }
    }
    if (in.pressed and in.button == .left and !in_title_band(s, c)) {
        if (in.click_count == 2) vp.toggle_fit_actual() else s.drag_last = in.mouse;
    }
    if (in.down) {
        if (s.drag_last) |last| {
            vp.pan(in.mouse.x - last.x, in.mouse.y - last.y);
            s.drag_last = in.mouse;
        }
    }
    if (in.released) s.drag_last = null;
    assert(vp.scale >= vp.scale_min() and vp.scale <= vp.scale_max());
}

/// On macOS the top band of a window with a hidden title bar moves the window.
fn in_title_band(s: *const State, c: *const ui.Context) bool {
    assert(c.title_bar_height >= 0);
    if (!mac) return false;
    const full = if (s.window) |w| w.isFullScreen() else false;
    return !full and c.input.mouse.y < c.title_bar_height;
}

/// A key as a shortcut; off macOS bare keys arrive as keys or characters.
fn key_hit(c: *ui.Context, sc: ui.Shortcut) bool {
    assert(sc.key != 0);
    if (c.shortcut(sc)) return true;
    if (mac or sc.cmd or sc.ctrl or sc.alt) return false;
    // `?Key`: nanoui does not export its key enum from `ui`.
    const Key = @FieldType(@FieldType(ui.Context, "input"), "key");
    const want: Key = switch (sc.key) {
        ui.Shortcut.left => .left,
        ui.Shortcut.right => .right,
        ui.Shortcut.escape => .escape,
        ui.Shortcut.forward_delete => .delete,
        else => null,
    };
    if (want) |k| {
        if (c.input.key != k) return false;
        c.input.key = null;
        return true;
    }
    const chars = c.input.chars;
    if (chars.len != 1 or std.ascii.toLower(chars[0]) != sc.key) return false;
    c.input.chars = "";
    return true;
}

/// One key event runs at most one action.
fn keys(s: *State, c: *ui.Context) void {
    assert(s.path_len <= paths.path_max);
    for (actions.bindings) |b| {
        if (!key_hit(c, b.shortcut)) continue;
        perform(s, c, b.action);
        return;
    }
}

pub fn perform(s: *State, c: *ui.Context, action: actions.Action) void {
    assert(s.path_len <= paths.path_max);
    const vp = &s.viewport;
    const shown = s.status == .shown;
    const cx = c.size.w / 2;
    const cy = c.size.h / 2;
    assert(cx >= 0 and cy >= 0);
    switch (action) {
        .open => s.open_dialog(),
        .next => s.step(1),
        .previous => s.step(-1),
        .zoom_in => if (shown) vp.zoom_about(cx, cy, zoom_step(s)),
        .zoom_out => if (shown) vp.zoom_about(cx, cy, 1 / zoom_step(s)),
        .fit => if (shown) vp.set_fit(),
        .actual => if (shown) vp.set_actual(),
        .fit_upscale, .fit_mode, .smooth, .zoom_lock, .checkerboard, .mirror, .flip => option(s, action),
        .full_screen => if (s.window) |w| w.setFullScreen(!w.isFullScreen()),
        .leave_full_screen => if (s.window) |w| w.setFullScreen(false),
        .rotate_right => rotate(s, c, 1),
        .rotate_left => rotate(s, c, 3),
        .info => s.info_shown = !s.info_shown,
        .trash => s.trash(),
        .reveal => s.reveal(),
        .copy_path => s.copy_path(),
    }
}

fn zoom_step(s: *const State) f32 {
    assert(s.settings.zoom_step_percent > 0);
    const result = 1 + @as(f32, @floatFromInt(s.settings.zoom_step_percent)) / 100;
    assert(result > 1 and std.math.isFinite(result));
    return result;
}

fn fit_options(s: *State) void {
    s.viewport.fit_mode = s.settings.fit_mode;
    s.viewport.fit_upscale = s.settings.fit_upscale;
    s.viewport.mirror = s.mirror;
    s.viewport.flip = s.flip;
    s.viewport.settle();
    assert(s.viewport.scale >= s.viewport.scale_min());
    assert(s.viewport.scale <= s.viewport.scale_max());
}

fn option(s: *State, action: actions.Action) void {
    const opts = &s.settings;
    if (action == .fit_mode) {
        opts.fit_mode = switch (opts.fit_mode) {
            .whole => .width,
            .width => .height,
            .height => .fill,
            .fill => .whole,
        };
        fit_options(s);
        s.viewport.set_fit();
        s.notify("Fit: {s}", .{@tagName(opts.fit_mode)});
        return;
    }
    const value: *bool, const name: []const u8 = switch (action) {
        .fit_upscale => .{ &opts.fit_upscale, "Fit upscale" },
        .smooth => .{ &opts.smooth, "Smooth" },
        .zoom_lock => .{ &opts.zoom_lock, "Zoom lock" },
        .checkerboard => .{ &opts.checkerboard, "Checkerboard" },
        .mirror => .{ &s.mirror, "Mirror" },
        .flip => .{ &s.flip, "Flip" },
        else => unreachable,
    };
    value.* = !value.*;
    fit_options(s);
    assert(s.viewport.mirror == s.mirror and s.viewport.flip == s.flip);
    s.notify("{s}: {s}", .{ name, if (value.*) "on" else "off" });
}

const checker_side_min: f32 = 16;
const checker_cells_max: u32 = 64;

fn checkerboard(s: *const State, c: *ui.Context) void {
    const vp = &s.viewport;
    const x0 = @max(0, vp.x);
    const y0 = @max(0, vp.y);
    const w = @min(c.size.w, vp.x + vp.image_w * vp.scale) - x0;
    const h = @min(c.size.h, vp.y + vp.image_h * vp.scale) - y0;
    assert(w > 0 and h > 0);
    const side = @max(checker_side_min, @max(w, h) / checker_cells_max);
    for (0..checker_cells_max) |row| {
        const y = @as(f32, @floatFromInt(row)) * side;
        if (y >= h) break;
        for (0..checker_cells_max) |col| {
            const x = @as(f32, @floatFromInt(col)) * side;
            if (x >= w) break;
            const gray: f32 = if ((row + col) % 2 == 0) 0.7 else 0.9;
            const cell = ui.div(c).absolute().offset(x0 + x, y0 + y)
                .size(@min(side, w - x), @min(side, h - y))
                .bg(.{ .r = gray, .g = gray, .b = gray });
            cell.end();
        }
    }
}
