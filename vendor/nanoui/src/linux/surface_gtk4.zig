//! The surface's GTK 4 side (issue #4): GTK 4 draws a drawing area through
//! a draw function and sends input through event controllers (a click
//! gesture, motion, scroll, keys, focus) instead of GTK 3's event
//! signals. The input method is the key controller's: it takes typed
//! text first and commits it (`onCommit`), so `key-pressed` only sees the
//! keys that aren't text. What each does is surface.zig's, shared with GTK 3.
const std = @import("std");
const gtk = @import("gtk.zig");
const surface = @import("surface.zig");
const Surface = surface.Surface;

/// Draws `s` in its window and feeds it GTK 4's input.
pub fn attach(s: *Surface) void {
    gtk.connect(s.im, "commit", @ptrCast(&onCommit), s);
    attachArea(s);
}

/// Puts `s.area` in the window (replacing what was there), drawn and fed
/// input: a GL area draws in "render" and starts OpenGL when realized; a
/// drawing area through its draw function.
pub fn attachArea(s: *Surface) void {
    const g4 = &gtk.v4api;
    const area = s.area;
    g4.gtk_widget_set_focusable(area, 1);
    if (s.gl) {
        gtk.connect(area, "render", @ptrCast(&onRender), s);
        gtk.connect(area, "realize", @ptrCast(&onRealize), s);
    } else g4.gtk_drawing_area_set_draw_func(area, onDraw, s, null);
    gtk.connect(area, "resize", @ptrCast(&onResize), s);
    const click = g4.gtk_gesture_click_new();
    g4.gtk_gesture_single_set_button(click, 0);
    gtk.connect(click, "pressed", @ptrCast(&onPressed), s);
    gtk.connect(click, "released", @ptrCast(&onReleased), s);
    g4.gtk_widget_add_controller(area, click);
    const motion = g4.gtk_event_controller_motion_new();
    gtk.connect(motion, "motion", @ptrCast(&onMotion), s);
    gtk.connect(motion, "leave", @ptrCast(&onLeave), s);
    g4.gtk_widget_add_controller(area, motion);
    // Both axes (vertical 1, horizontal 2).
    const scroll = g4.gtk_event_controller_scroll_new(3);
    gtk.connect(scroll, "scroll", @ptrCast(&onScroll), s);
    g4.gtk_widget_add_controller(area, scroll);
    const zoom = g4.gtk_gesture_zoom_new();
    surface.attachZoom(s, zoom);
    g4.gtk_widget_add_controller(area, zoom);
    const key = g4.gtk_event_controller_key_new();
    g4.gtk_event_controller_key_set_im_context(key, s.im);
    gtk.connect(key, "key-pressed", @ptrCast(&onKey), s);
    g4.gtk_widget_add_controller(area, key);
    const focus = g4.gtk_event_controller_focus_new();
    gtk.connect(focus, "enter", @ptrCast(&onFocusIn), s);
    gtk.connect(focus, "leave", @ptrCast(&onFocusOut), s);
    g4.gtk_widget_add_controller(area, focus);
    g4.gtk_im_context_set_client_widget(s.im, area);
    g4.gtk_window_set_child(s.window.gtkwindow.?, area);
}

fn onRealize(_: *gtk.Widget, data: ?*anyopaque) callconv(.c) void {
    surface.glStart(of(data));
}

fn onRender(_: *gtk.Widget, _: *anyopaque, data: ?*anyopaque) callconv(.c) c_int {
    return @intFromBool(surface.glRender(of(data)));
}

fn of(data: ?*anyopaque) *Surface {
    return @ptrCast(@alignCast(data));
}

fn onDraw(_: *gtk.Widget, cr: *anyopaque, _: c_int, _: c_int, data: ?*anyopaque) callconv(.c) void {
    _ = surface.paint(of(data), cr);
}

fn onResize(area: *gtk.Widget, _: c_int, _: c_int, data: ?*anyopaque) callconv(.c) void {
    surface.resized(of(data), area);
}

/// The pointer at (x, y), with the modifiers `controller`'s event had.
fn at(s: *Surface, controller: *anyopaque, x: f64, y: f64) void {
    s.pointerAt(x, y, gtk.v4api.gtk_event_controller_get_current_event_state(controller));
}

fn onPressed(gesture: *anyopaque, n_press: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const s = of(data);
    gtk.api.gtk_widget_grab_focus(s.area);
    at(s, gesture, x, y);
    const button = gtk.v4api.gtk_gesture_single_get_current_button(gesture);
    s.ctx.input.button = switch (button) {
        1 => .left,
        8 => .back,
        9 => .forward,
        else => return,
    };
    // GTK 4 counts the clicks itself: a double click's second press says 2.
    s.ctx.input.click_count = @intCast(@max(1, n_press));
    s.ctx.updateHot();
    if (surface.windowDrag(s) and beginMove(s, gesture)) return;
    s.ctx.pointerDown();
    s.frame();
}

fn beginMove(s: *Surface, controller: *anyopaque) bool {
    const g = &gtk.v4api;
    const event = g.gtk_event_controller_get_current_event(controller) orelse return false;
    const device = g.gdk_event_get_device(event) orelse return false;
    const native_surface = g.gtk_native_get_surface(s.window.gtkwindow.?) orelse return false;
    var x: f64 = 0;
    var y: f64 = 0;
    if (g.gdk_event_get_position(event, &x, &y) == 0) return false;
    // The event's surface coordinates (not widget coordinates) and its
    // original device/time let Wayland authorize the interactive move.
    g.gdk_toplevel_begin_move(native_surface, device, 1, x, y, g.gdk_event_get_time(event));
    return true;
}

fn onReleased(gesture: *anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const s = of(data);
    at(s, gesture, x, y);
    const button = gtk.v4api.gtk_gesture_single_get_current_button(gesture);
    if (button != 1 and button != 8 and button != 9) return;
    surface.released(s);
}

fn onMotion(controller: *anyopaque, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const s = of(data);
    at(s, controller, x, y);
    surface.moved(s);
}

fn onLeave(_: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    surface.left(of(data));
}

fn onScroll(controller: *anyopaque, dx: f64, dy: f64, data: ?*anyopaque) callconv(.c) c_int {
    const unit: ?c_int = if (gtk.scroll_get_unit) |f| f(controller) else null;
    const m = scrollMapping(unit, dx, dy);
    surface.scrollAxes(of(data), @floatCast(-dx * m.factor), @floatCast(-dy * m.factor), m.precise);
    return 1;
}

const ScrollMapping = struct { precise: bool, factor: f64 };

/// GDK_SCROLL_UNIT_SURFACE (1) is a touchpad's pixels on Wayland. Wheel
/// units (0, or unknown before GTK 4.8) with a fraction are smooth
/// (an X11 touchpad, whose device is the logical pointer); whole steps a wheel.
fn scrollMapping(unit: ?c_int, dx: f64, dy: f64) ScrollMapping {
    if (unit == 1) return .{ .precise = true, .factor = 1 };
    const smooth = dx != @trunc(dx) or dy != @trunc(dy);
    return if (smooth) .{ .precise = true, .factor = 40 } else .{ .precise = false, .factor = 48 };
}

test "GTK 4 scroll units pick precise pixel or wheel steps" {
    try std.testing.expectEqual(ScrollMapping{ .precise = true, .factor = 1 }, scrollMapping(1, 0, 3));
    try std.testing.expectEqual(ScrollMapping{ .precise = true, .factor = 40 }, scrollMapping(0, 0, 0.25));
    try std.testing.expectEqual(ScrollMapping{ .precise = true, .factor = 40 }, scrollMapping(null, -0.5, 0));
    try std.testing.expectEqual(ScrollMapping{ .precise = false, .factor = 48 }, scrollMapping(0, 0, -1));
    try std.testing.expectEqual(ScrollMapping{ .precise = false, .factor = 48 }, scrollMapping(null, 1, 0));
}

fn onKey(_: *anyopaque, keyval: c_uint, _: c_uint, state: c_uint, data: ?*anyopaque) callconv(.c) c_int {
    return @intFromBool(surface.keyPress(of(data), keyval, state, null));
}

fn onFocusIn(_: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const s = of(data);
    gtk.api.gtk_im_context_focus_in(s.im);
    s.ctx.input.window_active = s.window.isFocused();
    s.frame();
}

fn onFocusOut(_: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const s = of(data);
    gtk.api.gtk_im_context_focus_out(s.im);
    s.ctx.input.window_active = false;
    s.frame();
}

/// Text typed (or composed by an input method): straight to the view.
fn onCommit(_: *anyopaque, str: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
    const s = of(data);
    s.committed.clearRetainingCapacity();
    s.committed.appendSlice(s.gpa, std.mem.span(str)) catch return;
    if (s.committed.items.len == 0) return;
    s.ctx.input.chars = s.committed.items;
    s.frame();
}
