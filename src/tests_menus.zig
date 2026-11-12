//! Menus through the Tester: which actions apply, their check marks.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const objc = nanoui.objc;
const keymap = @import("keymap.zig");
const paths = @import("paths.zig");
const menus = @import("menus.zig");
const tests = @import("tests.zig");
const testing = std.testing;
const Fixture = tests.Fixture;

test "an empty window offers only what needs no picture" {
    const f = try Fixture.create();
    defer f.destroy();
    try testing.expect(menus.available(f.state, .open));
    try testing.expect(menus.available(f.state, .paste));
    try testing.expect(menus.available(f.state, .full_screen));
    try testing.expect(!menus.available(f.state, .zoom_in));
    try testing.expect(!menus.available(f.state, .next));
    try testing.expect(!menus.available(f.state, .trash));
    try testing.expect(!menus.available(f.state, .restore));
    try testing.expect(!menus.available(f.state, .leave_full_screen));
}

test "a pasted picture offers no file actions and no steps" {
    const f = try Fixture.create();
    defer f.destroy();
    for ([_][]const u8{ "a.png", "b.png" }) |n| try f.write_png(n, 4, 4);
    try f.open("a.png");
    try testing.expect(menus.available(f.state, .next));
    try testing.expect(menus.available(f.state, .reveal));
    try testing.expect(!menus.available(f.state, .confirm_trash));
    const pixels = try testing.allocator.alloc(u8, 6 * 4 * 4);
    defer testing.allocator.free(pixels);
    @memset(pixels, 0x80);
    const png = try ui.png.encode(testing.allocator, .{ .bytes = pixels, .width = 6, .height = 4 });
    defer testing.allocator.free(png);
    tests.pasted = .{ .image = png };
    _ = f.tester.shortcut(.{ .key = 'v', .cmd = true });
    f.tester.frame();
    try testing.expectEqualStrings("Clipboard", f.state.basename());
    try testing.expect(menus.available(f.state, .copy_image));
    try testing.expect(menus.available(f.state, .rotate_right));
    try testing.expect(!menus.available(f.state, .next));
    try testing.expect(!menus.available(f.state, .reveal));
    try testing.expect(!menus.available(f.state, .rename));
    try testing.expect(!menus.available(f.state, .copy_path));
}

test "checkable actions report what their keys turned on" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.write_png("a.png", 4, 4);
    try f.open("a.png");
    try testing.expectEqual(@as(?bool, null), menus.checked(f.state, .next));
    try testing.expectEqual(@as(?bool, true), menus.checked(f.state, .smooth));
    try testing.expectEqual(@as(?bool, false), menus.checked(f.state, .info));
    try testing.expectEqual(@as(?bool, false), menus.checked(f.state, .mirror));
    _ = f.tester.shortcut(.{ .key = 'p' });
    _ = f.tester.shortcut(.{ .key = 'i' });
    _ = f.tester.shortcut(.{ .key = 'm' });
    try testing.expectEqual(@as(?bool, false), menus.checked(f.state, .smooth));
    try testing.expectEqual(@as(?bool, true), menus.checked(f.state, .info));
    try testing.expectEqual(@as(?bool, true), menus.checked(f.state, .mirror));
    try testing.expectEqual(@as(?bool, false), menus.checked(f.state, .full_screen));
}

/// Room for the whole menu, then a right click in the middle.
fn open_menu(f: *Fixture) void {
    f.tester.resize(480, 640);
    f.tester.rightClick(240, 180);
    f.tester.settle(1);
}

test "a right click opens the context menu; a click on an item runs it" {
    const f = try Fixture.create();
    defer f.destroy();
    for ([_][]const u8{ "a.png", "b.png" }) |n| try f.write_png(n, 4, 4);
    try f.open("a.png");
    try testing.expect(!f.tester.hasText("Copy Picture"));
    open_menu(f);
    try testing.expect(f.state.context_menu.open);
    try testing.expect(f.tester.hasText("Open…") and f.tester.hasText("Copy Picture"));
    try testing.expect(f.tester.hasText(if (builtin.os.tag == .macos) "⌘C" else "Ctrl+C"));
    // No trash pending: no confirmation in the menu.
    try testing.expect(!f.tester.containsText("Confirm"));
    try f.tester.clickText("View");
    f.tester.settle(1);
    try testing.expect(f.tester.hasText("Smooth Pixels"));
    try f.tester.clickText("Show Info");
    f.tester.settle(1);
    try testing.expect(f.state.info_shown);
    try testing.expect(!f.state.context_menu.open and !f.tester.hasText("Copy Picture"));
    open_menu(f);
    try f.tester.clickText("Go");
    f.tester.settle(1);
    try f.tester.clickText("Next Picture");
    try testing.expectEqualStrings("b.png", f.state.basename());
}

test "the context menu shows the keys in effect" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.write_png("a.png", 4, 4);
    try f.open("a.png");
    const problem = f.state.keymap.rebind("rotate_right", "k", 1);
    try testing.expectEqual(@as(?keymap.Error, null), problem);
    open_menu(f);
    try f.tester.clickText("View");
    f.tester.settle(1);
    const row = f.tester.findText("Rotate Right").?;
    const key = f.tester.findText("K").?;
    try testing.expect(@abs(key.y - row.y) < 4 and key.x > row.x);
    try testing.expect(f.tester.findText("R") == null);
}

test "the context menu opens a recent file and clears the list" {
    const f = try Fixture.create();
    defer f.destroy();
    for ([_][]const u8{ "a.png", "b.png" }) |n| try f.write_png(n, 4, 4);
    var buf: [paths.path_max]u8 = undefined;
    f.state.load_recent(paths.join(f.dir_buf[0..f.dir_len], "state", &buf).?);
    try f.open("a.png");
    try f.open("b.png");
    open_menu(f);
    try f.tester.clickText("Open Recent");
    f.tester.settle(1);
    try testing.expect(f.tester.hasText("b.png") and f.tester.hasText("Clear Recent"));
    try f.tester.clickText("a.png");
    try testing.expectEqualStrings("a.png", f.state.basename());
    open_menu(f);
    try f.tester.clickText("Open Recent");
    f.tester.settle(1);
    try f.tester.clickText("Clear Recent");
    try testing.expectEqual(@as(u32, 0), f.state.recent_count());
    open_menu(f);
    try testing.expect(!f.tester.hasText("Open Recent"));
}

test "an empty window's context menu offers what needs no picture" {
    const f = try Fixture.create();
    defer f.destroy();
    open_menu(f);
    try testing.expect(f.tester.hasText("Open…") and f.tester.hasText("Paste"));
    try testing.expect(!f.tester.hasText("Copy Picture") and !f.tester.hasText("Go"));
}

test "keys and drags stay off the picture while the context menu is open" {
    const f = try Fixture.create();
    defer f.destroy();
    for ([_][]const u8{ "a.png", "b.png" }) |n| try f.write_png(n, 1200, 900);
    try f.open("a.png");
    _ = f.tester.shortcut(.{ .key = '1' });
    open_menu(f);
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.right });
    try testing.expectEqualStrings("a.png", f.state.basename());
    try testing.expect(f.state.context_menu.open);
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.escape });
    f.tester.settle(1);
    try testing.expect(!f.state.context_menu.open and !f.tester.hasText("Copy Picture"));
    // The press that closes the menu does not drag the picture.
    open_menu(f);
    const x = f.state.viewport.x;
    f.tester.drag(20, 340, 120, 300);
    try testing.expect(!f.state.context_menu.open);
    try testing.expectEqual(x, f.state.viewport.x);
    // With the menu closed, the same drag does.
    f.tester.drag(20, 340, 120, 300);
    try testing.expect(f.state.viewport.x != x);
}

/// A key press as AppKit offers it to the menu bar first.
fn key_event(flags: usize, chars: []const u8) objc.Object {
    const key_down: usize = 10;
    const fmt = "keyEventWithType:location:modifierFlags:timestamp:windowNumber:" ++
        "context:characters:charactersIgnoringModifiers:isARepeat:keyCode:";
    const code: u16 = if (chars.len == 1) switch (std.ascii.toLower(chars[0])) {
        'z' => 6,
        'x' => 7,
        'c' => 8,
        'v' => 9,
        'b' => 11,
        'r' => 15,
        else => 0,
    } else 120;
    return objc.msg(objc.Object, objc.class("NSEvent"), fmt, .{
        key_down,             objc.CGPoint{},         flags,
        @as(f64, 0),          @as(objc.NSInteger, 0), @as(?objc.Object, null),
        objc.nsString(chars), objc.nsString(chars),   objc.NO,
        code,
    });
}

test "the menu bar shows the keys but leaves them to the view, so each runs once" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const f = try Fixture.create();
    defer f.destroy();
    for ([_][]const u8{ "a.png", "b.png" }) |n| try f.write_png(n, 4, 4);
    try f.open("a.png");
    const pool = objc.Pool.push();
    defer pool.pop();
    const app = try native_app();
    defer free_native_app(app);
    const window = try native_window(app, f);
    defer f.state.window = null;
    const bar = try nanoui.Menu.create(testing.allocator, "nanoview", menus.menu_bar(f.state));
    defer bar.destroy();
    objc.msg(void, app.nsapp, "setMainMenu:", .{bar.ns});
    defer objc.msg(void, app.nsapp, "setMainMenu:", .{@as(?objc.Object, null)});
    const copy = bar.item("copy_image").?;
    try testing.expectEqual(@as(u21, 'c'), copy.accel.key);
    // ⌘C and a bare r: the menu bar takes neither.
    const cmd: usize = 1 << 20;
    const perform = "performKeyEquivalent:";
    try testing.expect(objc.msg(objc.BOOL, bar.ns, perform, .{key_event(cmd, "c")}) == objc.NO);
    try testing.expect(objc.msg(objc.BOOL, bar.ns, perform, .{key_event(0, "r")}) == objc.NO);
    try testing.expectEqual(menus.Pending.none, std.meta.activeTag(f.state.menu_bar.pending));
    // The view runs r once: a quarter turn.
    native_press(bar, window, 0, "r");
    try testing.expectEqual(@as(u2, 1), f.state.turns_user);
    // A click runs its action once, on the next frame.
    const next = bar.item("next").?;
    next.click.?.func(next.click.?.ctx, next);
    f.tester.frame();
    f.tester.frame();
    try testing.expectEqualStrings("b.png", f.state.basename());
}

// A headless test process cannot become active: only the OS key-window
// lookup is substituted. Menus, selectors, responder and field stay native.
var key_window: ?*anyopaque = null;
var key_method: ?*anyopaque = null;
var key_implementation: ?*const anyopaque = null;
extern "c" fn class_getInstanceMethod(cls: *anyopaque, sel: *anyopaque) ?*anyopaque;
extern "c" fn method_setImplementation(method: *anyopaque, imp: *const anyopaque) *const anyopaque;

fn test_key_window(_: *anyopaque, _: *anyopaque) callconv(.c) ?*anyopaque {
    return key_window;
}
fn native_app() !*nanoui.App {
    const app = try testing.allocator.create(nanoui.App);
    app.* = .{
        .gpa = testing.allocator,
        .io = testing.io,
        .options = .{ .quit_on_last_window_closed = false },
        .nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{}),
        .delegate = objc.msg(objc.Object, objc.class("NSObject"), "new", .{}),
        .flags = .{ .hidden = true },
    };
    const cls = objc.class("NSApplication");
    key_method = class_getInstanceMethod(@ptrCast(cls), @ptrCast(objc.sel("keyWindow"))).?;
    key_implementation = method_setImplementation(key_method.?, @ptrCast(&test_key_window));
    return app;
}

fn free_native_app(app: *nanoui.App) void {
    _ = method_setImplementation(key_method.?, key_implementation.?);
    key_window = null;
    app.running = false;
    for (0..app.windows.items.len) |_| app.windows.items[app.windows.items.len - 1].close();
    app.windows.deinit(app.gpa);
    objc.release(app.delegate);
    testing.allocator.destroy(app);
}

fn native_window(app: *nanoui.App, f: *Fixture) !*nanoui.Window {
    const window = try app.newWindow(.{
        .title = "menu keyboard test",
        .width = 480,
        .height = 360,
        .visible = false,
        .content = .{ .view = .init(f.state, @import("view.zig").view) },
    });
    f.state.window = window;
    key_window = @ptrCast(window.nswindow);
    const key = objc.msg(?objc.Object, app.nsapp, "keyWindow", .{});
    try testing.expect(key == window.nswindow);
    return window;
}

/// AppKit first offers the chord to the menu; unclaimed keys go to keyDown:.
/// Use the real surface, not Tester.shortcut, for native text input and undo.
fn native_press(bar: *nanoui.Menu, window: *nanoui.Window, flags: usize, chars: []const u8) void {
    const event = key_event(flags, chars);
    if (objc.msg(objc.BOOL, bar.ns, "performKeyEquivalent:", .{event}) == objc.NO) {
        objc.msg(void, window.surface.?.nsview, "keyDown:", .{event});
    }
}

// AppKit's nil-target resolver uses OS activation as well. In the headless
// process, supply the same real first responder explicitly for Edit selectors.
fn native_edit_targets(bar: *nanoui.Menu, window: *nanoui.Window) void {
    const selectors = [_][:0]const u8{
        "undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:",
    };
    for (bar.items.items) |item| {
        const action = objc.msg(?objc.SEL, item.ns, "action", .{}) orelse continue;
        for (selectors) |selector| if (action == objc.sel(selector) and !item.shown_only) {
            objc.msg(void, item.ns, "setTarget:", .{window.surface.?.nsview});
        };
    }
}

test "native Edit keys edit and undo the rename field instead of picture actions" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const f = try Fixture.create();
    defer f.destroy();
    try f.write_png("a.png", 4, 4);
    try f.open("a.png");
    const pool = objc.Pool.push();
    defer pool.pop();
    const app = try native_app();
    defer free_native_app(app);
    const window = try native_window(app, f);
    defer f.state.window = null;
    const bar = try nanoui.Menu.create(testing.allocator, "nanoview", menus.menu_bar(f.state));
    defer bar.destroy();
    native_edit_targets(bar, window);
    objc.msg(void, app.nsapp, "setMainMenu:", .{bar.ns});
    defer objc.msg(void, app.nsapp, "setMainMenu:", .{@as(?objc.Object, null)});
    native_press(bar, window, 0, "\u{f705}");
    try testing.expect(f.state.rename_open);
    const cmd: usize = 1 << 20;
    const shift: usize = 1 << 17;
    native_press(bar, window, cmd, "a");
    native_press(bar, window, cmd, "c");
    native_press(bar, window, 0, "b");
    try testing.expectEqualStrings("b", f.state.rename_buffer.text());
    native_press(bar, window, cmd, "v");
    try testing.expectEqualStrings("ba.png", f.state.rename_buffer.text());
    native_press(bar, window, cmd, "z");
    try testing.expectEqualStrings("b", f.state.rename_buffer.text());
    native_press(bar, window, cmd | shift, "Z");
    try testing.expectEqualStrings("ba.png", f.state.rename_buffer.text());
    native_press(bar, window, cmd, "a");
    native_press(bar, window, cmd, "x");
    try testing.expectEqualStrings("", f.state.rename_buffer.text());
    native_press(bar, window, cmd, "v");
    try testing.expectEqualStrings("ba.png", f.state.rename_buffer.text());
    try testing.expectEqual(menus.Pending.none, std.meta.activeTag(f.state.menu_bar.pending));
    try testing.expectEqual(@as(u2, 0), f.state.turns_user);
}
