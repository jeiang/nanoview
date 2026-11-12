//! Menus through the Tester: which actions apply, their check marks.
const std = @import("std");
const ui = @import("nanoui").ui;
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
