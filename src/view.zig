//! The window's content: the picture, the keys and the pointer.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("nanoui").ui;
const app = @import("app.zig");
const paths = @import("paths.zig");
const orientation = @import("orientation.zig");
const viewport = @import("viewport.zig");
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

    if (s.status == .empty) {
        ui.text(c, hint, .{ .color = c.theme.muted });
        return;
    }
    var key_buf: [16]u8 = undefined;
    const key = s.picture_key(&key_buf);
    const size: ui.Size = size: {
        if (s.status == .shown) {
            if (ui.imageSize(c, key, s.bytes)) |size| break :size size;
            s.status = .failed;
        }
        ui.text(c, c.print("Cannot show {s}", .{s.basename()}), .{ .color = c.theme.muted });
        return;
    };
    assert(s.status == .shown and size.w > 0 and size.h > 0);
    if (s.viewport_generation != s.generation) {
        s.base = orientation.upright(size.w, size.h, orientation.read(s.bytes));
        reset_viewport(s, c);
        s.viewport_generation = s.generation;
    }
    s.viewport.set_view(c.size.w, c.size.h, c.scale);
    pointer(s, c);
    draw(s, c, key);
    if (s.info_shown) info(s, c);
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
    const angle = @as(f32, @floatFromInt(turns)) * std.math.pi / 2;
    const turn = ui.div(c).absolute().offset(v.box.x, v.box.y).rotate(angle);
    defer turn.end();
    _ = ui.image(c, .{
        .key = key,
        .bytes = s.bytes,
        .box = .{ .w = v.box.w, .h = v.box.h },
        .part = v.part,
        .radius = 0,
    });
}

/// Back to fit, for a new picture or a new turn.
fn reset_viewport(s: *State, c: *ui.Context) void {
    assert(s.base.raw_w > 0 and s.base.raw_h > 0);
    const odd = s.turns_user % 2 == 1;
    const w = if (odd) s.base.raw_h else s.base.raw_w;
    const h = if (odd) s.base.raw_w else s.base.raw_h;
    s.viewport = .{ .image_w = w, .image_h = h };
    assert(s.viewport.fit);
    resize_window(s, c);
}

/// View only: nothing is written to disk.
fn rotate(s: *State, c: *ui.Context, quarter: u2) void {
    if (s.status != .shown or s.viewport_generation != s.generation) return;
    assert(quarter == 1 or quarter == 3);
    s.turns_user +%= quarter;
    reset_viewport(s, c);
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
            const factor = if (in.scroll.y > 0) viewport.zoom_step else 1 / viewport.zoom_step;
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
    assert(vp.scale >= vp.scale_fit() and vp.scale <= vp.scale_max());
}

/// On macOS the top band of a window with a hidden title bar moves the window.
fn in_title_band(s: *const State, c: *const ui.Context) bool {
    if (!mac) return false;
    const full = if (s.window) |w| w.isFullScreen() else false;
    return !full and c.input.mouse.y < c.title_bar_height;
}

/// A key as a shortcut; off macOS bare keys arrive as keys or characters.
fn key_hit(c: *ui.Context, comptime sc: ui.Shortcut) bool {
    if (c.shortcut(sc)) return true;
    if (mac or sc.cmd or sc.ctrl or sc.alt) return false;
    // `?Key`: nanoui does not export its key enum from `ui`.
    const Key = @FieldType(@FieldType(ui.Context, "input"), "key");
    const want: Key = comptime switch (sc.key) {
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

fn keys(s: *State, c: *ui.Context) void {
    const vp = &s.viewport;
    const shown = s.status == .shown;
    const cx = c.size.w / 2;
    const cy = c.size.h / 2;
    if (key_hit(c, .{ .key = 'o', .cmd = true })) s.open_dialog();
    if (key_hit(c, .{ .key = ui.Shortcut.right })) s.step(1);
    if (key_hit(c, .{ .key = ui.Shortcut.left })) s.step(-1);
    const zoom_in = key_hit(c, .{ .key = '=' }) or key_hit(c, .{ .key = '=', .shift = true }) or
        key_hit(c, .{ .key = '+' });
    if (zoom_in and shown) vp.zoom_about(cx, cy, viewport.zoom_step);
    if (key_hit(c, .{ .key = '-' }) and shown) vp.zoom_about(cx, cy, 1 / viewport.zoom_step);
    if (key_hit(c, .{ .key = '0' }) and shown) vp.set_fit();
    if (key_hit(c, .{ .key = '1' }) and shown) vp.set_actual();
    if (key_hit(c, .{ .key = 'f' })) {
        if (s.window) |w| w.setFullScreen(!w.isFullScreen());
    }
    if (key_hit(c, .{ .key = ui.Shortcut.escape })) {
        if (s.window) |w| w.setFullScreen(false);
    }
    if (key_hit(c, .{ .key = 'r' })) rotate(s, c, 1);
    if (key_hit(c, .{ .key = 'l' })) rotate(s, c, 3);
    if (key_hit(c, .{ .key = 'i' })) s.info_shown = !s.info_shown;
    if (key_hit(c, .{ .key = ui.Shortcut.forward_delete }) or
        key_hit(c, .{ .key = ui.Shortcut.backspace, .cmd = true })) s.trash();
    if (key_hit(c, .{ .key = 'r', .cmd = true })) s.reveal();
    if (key_hit(c, .{ .key = 'c', .cmd = true, .shift = true })) s.copy_path();
}
