//! Menus built and rebuilt without the app running (macOS): lazy
//! submenus, filled when they open.
const std = @import("std");
const objc = @import("../objc.zig");
const menu = @import("../menu.zig");
const testing = std.testing;

fn titleAt(m: objc.Object, i: usize) []const u8 {
    const it = objc.msg(objc.Object, m, "itemAtIndex:", .{@as(objc.NSInteger, @intCast(i))});
    return objc.fromNSString(objc.msg(?objc.Object, it, "title", .{}));
}

fn count(m: objc.Object) usize {
    return @intCast(objc.msg(objc.NSInteger, m, "numberOfItems", .{}));
}

test "setSubmenu replaces children" {
    const pool = objc.Pool.push();
    defer pool.pop();
    const m = try menu.Menu.create(testing.allocator, "Test", &.{
        .{ .label = "Bookmarks", .id = "marks", .submenu = &.{
            .{ .label = "A", .id = "a" },
            .{ .label = "Folder", .id = "folder", .submenu = &.{.{ .label = "Deep", .id = "deep" }} },
        } },
        .{ .label = "Other", .id = "other" },
    });
    defer m.destroy();
    const marks = m.item("marks").?;
    try testing.expect(m.item("deep") != null);
    try marks.setSubmenu(&.{ .{ .label = "C", .id = "c" }, .separator, .{ .label = "D", .id = "d", .image_symbol = "star" } });
    const sub = marks.submenu.?;
    try testing.expectEqual(@as(usize, 3), count(sub));
    try testing.expectEqualStrings("C", titleAt(sub, 0));
    try testing.expectEqualStrings("D", titleAt(sub, 2));
    // The old items are gone, however deep; the others stay.
    try testing.expect(m.item("a") == null and m.item("folder") == null and m.item("deep") == null);
    try testing.expect(m.item("c") != null and m.item("other") != null);
    try testing.expectEqual(@as(usize, 4), m.items.items.len); // marks, other, c, d
}

const Opened = struct {
    n: u32 = 0,
    fn fill(s: *Opened, it: *menu.Item) void {
        s.n += 1;
        it.setSubmenu(&.{.{ .label = "Recent", .id = "recent" }}) catch {};
    }
};

test "on_open fills the submenu before it shows" {
    const pool = objc.Pool.push();
    defer pool.pop();
    var opened: Opened = .{};
    const m = try menu.Menu.create(testing.allocator, "Test", &.{
        .{ .label = "History", .id = "history", .submenu = &.{}, .on_open = .of(&opened, Opened.fill) },
    });
    defer m.destroy();
    const sub = m.item("history").?.submenu.?;
    // AppKit asks the menu's delegate as it opens.
    const delegate = objc.msg(objc.Object, sub, "delegate", .{});
    objc.msg(void, delegate, "menuNeedsUpdate:", .{sub});
    try testing.expectEqual(@as(u32, 1), opened.n);
    try testing.expectEqualStrings("Recent", titleAt(sub, 0));
    m.item("recent").?.setAccelerator("Cmd+Shift+H");
    const ns = m.item("recent").?.ns;
    try testing.expectEqualStrings("h", objc.fromNSString(objc.msg(?objc.Object, ns, "keyEquivalent", .{})));
}

const Clicks = struct {
    n: u32 = 0,
    fn click(s: *Clicks, _: *menu.Item) void {
        s.n += 1;
    }
};

/// ⌘ and a key, as AppKit offers it to the menu bar first.
fn commandKey(chars: []const u8) objc.Object {
    const key_down: objc.NSUInteger = 10;
    const command: objc.NSUInteger = 1 << 20;
    return objc.msg(objc.Object, objc.class("NSEvent"), "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{
        key_down, objc.CGPoint{}, command, @as(f64, 0), @as(objc.NSInteger, 0), @as(?objc.Object, null), objc.nsString(chars), objc.nsString(chars), objc.NO, @as(u16, 0),
    });
}

test "a submenu whose accelerators are shown only shows them and takes no keys" {
    const pool = objc.Pool.push();
    defer pool.pop();
    _ = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    var opened: Clicks = .{};
    var rotated: Clicks = .{};
    const m = try menu.Menu.create(testing.allocator, "Test", &.{
        .{ .label = "File", .submenu = &.{.{ .label = "Open", .id = "open", .accelerator = "Cmd+O", .click = .of(&opened, Clicks.click) }} },
        .{ .label = "View", .accelerators_shown_only = true, .submenu = &.{
            .{ .label = "Rotate", .id = "rotate", .accelerator = "Cmd+K", .click = .of(&rotated, Clicks.click) },
            .{ .label = "More", .submenu = &.{.{ .label = "Deep", .id = "deep", .accelerator = "Cmd+J", .click = .of(&rotated, Clicks.click) }} },
        } },
    });
    defer m.destroy();
    try testing.expect(objc.msg(objc.BOOL, m.ns, "performKeyEquivalent:", .{commandKey("k")}) == objc.NO);
    try testing.expect(objc.msg(objc.BOOL, m.ns, "performKeyEquivalent:", .{commandKey("j")}) == objc.NO);
    try testing.expectEqual(@as(u32, 0), rotated.n);
    const ns = m.item("rotate").?.ns;
    try testing.expectEqualStrings("k", objc.fromNSString(objc.msg(?objc.Object, ns, "keyEquivalent", .{})));
    // Other menus take theirs.
    try testing.expect(objc.msg(objc.BOOL, m.ns, "performKeyEquivalent:", .{commandKey("o")}) == objc.YES);
    try testing.expectEqual(@as(u32, 1), opened.n);
}
