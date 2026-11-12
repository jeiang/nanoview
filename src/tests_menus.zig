//! Menus through the Tester: which actions apply, their check marks.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("nanoui").ui;
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
