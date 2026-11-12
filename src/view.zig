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
    slideshow(s, c);

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
    preload_bounds(s, c);
    pointer(s, c);
    if (s.source == .pixels and !s.promote_failed and needs_promote(s, c)) s.promote();
    draw(s, c, s.picture_key(&key_buf));
    if (s.info_shown) info(s, c);
}

const message_seconds: f64 = 4;
fn slideshow(s: *State, c: *ui.Context) void {
    if (s.trash_pending) {
        s.slideshow_at = null;
        return;
    }
    if (!s.slideshow_running) return;
    const seconds: f64 = @floatFromInt(@max(1, s.settings.slideshow_seconds));
    if (s.slideshow_at == null) s.slideshow_at = c.time + seconds;
    if (c.time >= s.slideshow_at.?) {
        s.step(if (s.settings.slideshow_reverse) -1 else 1);
        s.slideshow_at = c.time + seconds;
    }
    if (s.slideshow_running) c.frameIn(@floatCast(s.slideshow_at.? - c.time));
}

/// What `State.notify` last said, for a few seconds, above the info line.
fn message(s: *State, c: *ui.Context) void {
    assert(s.message_len <= app.message_len_max);
    if (s.message_len == 0) return;
    if (s.trash_pending) {
        const box = ui.div(c).absolute().offset(12, c.size.h - 100).px(8).py(4)
            .bg(ui.Color.black.alpha(0.8));
        defer box.end();
        ui.text(c, s.message(), .{ .size = info_text_size, .color = ui.Color.white });
        return;
    }
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
    reset_viewport(s, c);
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
    s.open_paths(drop.urls);
}

fn draw(s: *State, c: *ui.Context, key: []const u8) void {
    assert(key.len > 0);
    const turns = s.base.turns +% s.turns_user;
    const v = s.viewport.visible(turns) orelse return;
    assert(v.box.w > 0 and v.box.h > 0);
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
    const box = ui.div(c).absolute().offset(12, c.size.h - 60).px(8).py(4).rounded(6)
        .bg(ui.Color.black.alpha(0.6));
    defer box.end();
    ui.text(c, line, .{ .size = info_text_size, .color = ui.Color.white });
    ui.text(c, s.metadata.line(), .{ .size = info_text_size, .color = ui.Color.white });
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
    if (c.input.cmd or c.input.ctrl or c.input.alt or c.input.shift != sc.shift) return false;
    // `?Key`: nanoui does not export its key enum from `ui`.
    const Key = @FieldType(@FieldType(ui.Context, "input"), "key");
    const want: Key = switch (sc.key) {
        ui.Shortcut.left => .left,
        ui.Shortcut.right => .right,
        ui.Shortcut.home => .home,
        ui.Shortcut.end => .end,
        ui.Shortcut.enter => .enter,
        ui.Shortcut.f(5) => .f5,
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
    const pending = s.trash_pending;
    if (pending) {
        s.trash_pending = false;
        s.message_len = 0;
    }
    if (action == .confirm_trash) {
        if (pending) s.trash();
        return;
    }
    const shown = s.status == .shown;
    const cx = c.size.w / 2;
    const cy = c.size.h / 2;
    assert(cx >= 0 and cy >= 0);
    switch (action) {
        .open => s.open_dialog(),
        .next => s.step(1),
        .previous => s.step(-1),
        .first => s.endpoint(false),
        .last => s.endpoint(true),
        .random => s.random(),
        .reload => s.reload(),
        .slideshow => {
            s.slideshow_running = !s.slideshow_running;
            s.slideshow_at = null;
            const text = if (s.slideshow_running) "Slideshow started" else "Slideshow stopped";
            s.notify("{s}", .{text});
        },
        .zoom_in => if (shown) vp.zoom_about(cx, cy, viewport.zoom_step),
        .zoom_out => if (shown) vp.zoom_about(cx, cy, 1 / viewport.zoom_step),
        .fit => if (shown) vp.set_fit(),
        .actual => if (shown) vp.set_actual(),
        .full_screen => if (s.window) |w| w.setFullScreen(!w.isFullScreen()),
        .leave_full_screen => if (s.window) |w| w.setFullScreen(false),
        .rotate_right => rotate(s, c, 1),
        .rotate_left => rotate(s, c, 3),
        .info => s.info_shown = !s.info_shown,
        .trash => s.request_trash(),
        .confirm_trash => unreachable,
        .reveal => s.reveal(),
        .copy_path => s.copy_path(),
    }
}
