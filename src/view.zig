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
const keymap = @import("keymap.zig");
const settings_mod = @import("settings.zig");
const exif = @import("exif.zig");
const playback = @import("playback.zig");
const pages = @import("pages.zig");
const save = @import("save.zig");
const menus = @import("menus.zig");
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
    menus.run_menu_bar(s, c);
    menus.context_request(s, c);
    keys(s, c);
    slideshow(s, c);
    if (playback.tick(s, c.time)) |wait| c.frameIn(wait);

    const root = ui.div(c).sizeFull().center().bg(background(s, c));
    defer root.end();
    drops(s, c, root.index);
    body(s, c);
    message(s, c);
    rename_field(s, c);
    menus.context_menu(s, c);
    s.update_title();
}

fn background(s: *const State, c: *const ui.Context) ui.Color {
    const rgb = switch (s.settings.background) {
        .theme => return c.theme.background,
        .color => |rgb| rgb,
    };
    const result: ui.Color = .{
        .r = @as(f32, @floatFromInt(rgb.r)) / 255,
        .g = @as(f32, @floatFromInt(rgb.g)) / 255,
        .b = @as(f32, @floatFromInt(rgb.b)) / 255,
    };
    assert(result.r <= 1 and result.g <= 1 and result.b <= 1);
    return result;
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
    // A side button stepped: the next frame sets up the new picture.
    if (s.viewport_generation != s.generation) return;
    if (s.source == .pixels and !s.promote_failed and needs_promote(s, c)) s.promote();
    draw(s, c, s.picture_key(&key_buf));
    if (s.info_shown) info(s, c);
    if (s.details_shown) details(s, c);
}

const message_seconds: f64 = 4;
fn slideshow(s: *State, c: *ui.Context) void {
    if (s.trash_pending or s.rename_open) {
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
    const box = ui.div(c).absolute().offset(12, c.size.h - 92).px(8).py(4).rounded(6)
        .bg(ui.Color.black.alpha(0.6));
    defer box.end();
    ui.text(c, s.message(), .{ .size = info_text_size, .color = ui.Color.white });
}

const rename_width_max: f32 = 360;
const rename_width_min: f32 = 120;

/// The name field over the picture while Rename is open: Enter renames,
/// Escape (or a click elsewhere, which takes the keyboard away) cancels.
fn rename_field(s: *State, c: *ui.Context) void {
    if (!s.rename_open) return;
    assert(s.status != .empty);
    const width = @max(rename_width_min, @min(rename_width_max, c.size.w - 48));
    const box = ui.div(c).absolute().offset(12, c.title_bar_height + 12).px(6).py(6)
        .rounded(8).bg(ui.Color.black.alpha(0.6));
    defer box.end();
    const result = ui.textField(c, &s.rename_buffer, .{ .width = .{ .px = width } });
    if (result.submitted) {
        s.commit_rename();
        if (!s.rename_open) c.focus = 0;
        return;
    }
    if (s.rename_focused and !result.focused) {
        s.cancel_rename();
        return;
    }
    s.rename_focused = result.focused;
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
            w = m[0] * share(s.settings.window_max_percent);
            h = m[1] * share(s.settings.window_max_percent);
        }
    }
    w = @max(1, @ceil(w * c.scale));
    h = @max(1, @ceil(h * c.scale));
    s.preload.set_bounds(@intFromFloat(w), @intFromFloat(h));
}

/// Zoomed past the preloaded pixels, or the window grew.
fn needs_promote(s: *const State, c: *const ui.Context) bool {
    const px = s.source.pixels;
    if (px.width == px.native_w and px.height == px.native_h) return false;
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

fn share(percent: u32) f64 {
    assert(percent <= 100);
    return @as(f64, @floatFromInt(percent)) / 100;
}

/// The window size for a picture of `picture` points on a screen of
/// `monitor` points, within the percentage bounds; null when `window_fit`
/// leaves the window as it is.
pub fn fitted_size(
    settings: *const settings_mod.Settings,
    fitted_before: bool,
    monitor: [2]f64,
    picture: [2]f64,
) ?[2]f64 {
    assert(monitor[0] > 0 and monitor[1] > 0 and picture[0] > 0 and picture[1] > 0);
    switch (settings.window_fit) {
        .never => return null,
        .first => if (fitted_before) return null,
        .always => {},
    }
    const room = share(settings.window_max_percent);
    const least = share(settings.window_min_percent);
    const fit = @min(1, @min(monitor[0] * room / picture[0], monitor[1] * room / picture[1]));
    const w = @max(window_w_min, monitor[0] * least, picture[0] * fit);
    const h = @max(window_h_min, monitor[1] * least, picture[1] * fit);
    assert(w >= window_w_min and h >= window_h_min);
    return .{ w, h };
}

/// The window takes the picture's size, as `fitted_size` gives it.
fn resize_window(s: *State, c: *const ui.Context) void {
    const w = s.window orelse return;
    if (w.isFullScreen()) return;
    const m = w.monitorSize();
    // Before GTK realization (or if monitor lookup fails), nanoui falls
    // back to content size: fitting to it would shrink each picture.
    const content = w.contentSize();
    if (m[0] <= 0 or m[1] <= 0 or (m[0] == content[0] and m[1] == content[1])) return;
    assert(c.scale > 0);
    const picture: [2]f64 = .{ s.viewport.image_w / c.scale, s.viewport.image_h / c.scale };
    const size = fitted_size(&s.settings, s.window_fitted, m, picture) orelse return;
    w.setSize(size[0], size[1]);
    s.window_fitted = true;
}

const info_text_size: f32 = 12;

/// Name, upright pixel size, zoom and position in the folder.
fn info(s: *State, c: *ui.Context) void {
    assert(s.status == .shown);
    const vp = &s.viewport;
    const pw: u32 = @intFromFloat(vp.image_w);
    const ph: u32 = @intFromFloat(vp.image_h);
    const name = s.basename();
    var extra_buf: [2][64]u8 = undefined;
    const page = pages.info(s, &extra_buf[0]);
    const frame = playback.info(s, &extra_buf[1]);
    const line = if (s.index) |i|
        c.print("{s} · {d}×{d} · {d}% · {d}/{d}{s}{s}", .{
            name, pw, ph, vp.percent(), i + 1, s.folder.count, page, frame,
        })
    else
        c.print("{s} · {d}×{d} · {d}%{s}{s}", .{ name, pw, ph, vp.percent(), page, frame });
    const box = ui.div(c).absolute().offset(12, c.size.h - 60).px(8).py(4).rounded(6)
        .bg(ui.Color.black.alpha(0.6));
    defer box.end();
    ui.text(c, line, .{ .size = info_text_size, .color = ui.Color.white });
    ui.text(c, s.metadata.line(), .{ .size = info_text_size, .color = ui.Color.white });
}

const details_w: f32 = 300;
/// The panel ends above the message and info lines, which start 100 points up.
const details_bottom: f32 = 100;
/// A line of `info_text_size` text, rounded up, and the box's padding.
const details_line_h: f32 = 16;
const details_pad: f32 = 4;

/// The EXIF details, top right: the info box is bottom left, so both fit. A short
/// window shows the lines that fit whole.
fn details(s: *State, c: *ui.Context) void {
    assert(s.status == .shown);
    const top = c.title_bar_height + 12;
    const room = c.size.h - details_bottom - top - 2 * details_pad;
    if (room < details_line_h) return;
    const fit: u32 = @intFromFloat(@min(exif.lines_max, @floor(room / details_line_h)));
    assert(fit >= 1 and fit <= exif.lines_max);
    const x = @max(12, c.size.w - details_w - 12);
    const box = ui.div(c).absolute().offset(x, top).w(details_w).px(8).py(details_pad)
        .rounded(6).bg(ui.Color.black.alpha(0.6));
    defer box.end();
    const style: ui.TextStyle = .{
        .size = info_text_size,
        .color = ui.Color.white,
        .truncate = .ellipsis,
    };
    var i: u32 = 0;
    while (i < fit) : (i += 1) {
        ui.text(c, s.details.line(i) orelse break, style);
    }
}

fn toggle_details(s: *State) void {
    s.details_shown = !s.details_shown;
    if (!s.details_shown or s.status == .empty) return;
    // A pasted picture is not a file to read.
    if (s.is_file()) s.details.load(s.io, s.path()) else s.details.show(&.{});
}

fn pointer(s: *State, c: *ui.Context) void {
    assert(s.status == .shown);
    const in = &c.input;
    const vp = &s.viewport;
    // Keys and drags stay off the picture while the context menu is open.
    if (s.context_menu.open) {
        s.drag_last = null;
        return;
    }
    if (in.pressed and (in.button == .back or in.button == .forward)) {
        perform(s, c, if (in.button == .back) .previous else .next);
        return;
    }
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
    if (c.input.cmd or c.input.ctrl or c.input.alt) return false;
    const S = ui.Shortcut;
    const want: ?NamedKey = switch (sc.key) {
        S.left => .left,
        S.right => .right,
        S.up => .up,
        S.down => .down,
        S.home => .home,
        S.end => .end,
        S.page_up => .page_up,
        S.page_down => .page_down,
        S.enter => .enter,
        S.tab => .tab,
        S.escape => .escape,
        S.backspace => .backspace,
        S.forward_delete => .delete,
        else => function_key(sc.key),
    };
    if (want) |k| {
        if (c.input.key != k or c.input.shift != sc.shift) return false;
        c.input.key = null;
        return true;
    }
    const chars = c.input.chars;
    if (chars.len != 1 or std.ascii.toLower(chars[0]) != sc.key) return false;
    // A shifted punctuation key arrives as its own character ("+"), so
    // Shift only tells letters and Space apart.
    const shift_tells = std.ascii.isAlphabetic(chars[0]) or chars[0] == ' ';
    if (shift_tells and c.input.shift != sc.shift) return false;
    c.input.chars = "";
    return true;
}

// nanoui does not export its key enum from `ui`.
const NamedKey = @typeInfo(@FieldType(@FieldType(ui.Context, "input"), "key")).optional.child;

fn function_key(key: u21) ?NamedKey {
    const first = ui.Shortcut.f(1);
    if (key < first or key > ui.Shortcut.f(keymap.function_key_max)) return null;
    const result: NamedKey = @fromBackingInt(@intCast(@backingInt(NamedKey.f1) + (key - first)));
    assert(result != .f1 or key == first);
    return result;
}

/// One key event runs at most one action. The rename field takes every key
/// while it is open.
fn keys(s: *State, c: *ui.Context) void {
    assert(s.path_len <= paths.path_max);
    if (s.rename_open or s.context_menu.open) return;
    for (s.keymap.slice()) |b| {
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
        .zoom_in => if (shown) vp.zoom_about(cx, cy, zoom_step(s)),
        .zoom_out => if (shown) vp.zoom_about(cx, cy, 1 / zoom_step(s)),
        .fit => if (shown) vp.set_fit(),
        .actual => if (shown) vp.set_actual(),
        .fit_upscale, .fit_mode, .smooth, .zoom_lock, .checkerboard, .mirror, .flip => {
            option(s, action);
        },
        .full_screen => if (s.window) |w| w.setFullScreen(!w.isFullScreen()),
        .leave_full_screen => if (s.window) |w| w.setFullScreen(false),
        .always_on_top => option(s, action),
        .rotate_right => rotate(s, c, 1),
        .rotate_left => rotate(s, c, 3),
        .info => s.info_shown = !s.info_shown,
        .details => toggle_details(s),
        .trash => s.request_trash(),
        .confirm_trash => unreachable,
        .restore => s.restore(),
        .reveal => s.reveal(),
        .copy_path => s.copy_path(),
        .copy_image => s.copy_image(),
        .paste => s.paste(),
        .rename => s.start_rename(),
        .pause, .next_frame, .slower, .faster => playback.perform(s, action),
        .next_page => pages.turn(s, 1),
        .previous_page => pages.turn(s, -1),
        .save_frame => save.save_frame(s),
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
        .always_on_top => .{ &opts.always_on_top, "Always on top" },
        else => unreachable,
    };
    value.* = !value.*;
    if (action == .always_on_top) {
        if (s.window) |w| w.setAlwaysOnTop(value.*);
    }
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
