//! Recoverable trash and file-manager selection, with fixed caller-owned buffers.
const std = @import("std");
const builtin = @import("builtin");
const native = @import("nanoui").shell;
const paths = @import("paths.zig");
const assert = std.debug.assert;
pub const attempts_max: u32 = 1024;
pub const info_max: u32 = paths.path_max * 3 + 128;
pub const Date = struct { year: u32, month: u32, day: u32, hour: u32, minute: u32, second: u32 };

test {
    if (builtin.os.tag == .linux) _ = @import("shell_linux.zig");
}

pub fn trash(io: std.Io, path: []const u8) bool {
    assert(path.len > 0);
    return switch (builtin.os.tag) {
        .linux => @import("shell_linux.zig").trash(io, path),
        .windows => @import("shell_windows.zig").trash(path),
        else => native.trash(path),
    };
}

pub fn reveal(path: []const u8) void {
    assert(path.len > 0);
    const selected = switch (builtin.os.tag) {
        .linux => @import("shell_linux.zig").reveal(path),
        .windows => @import("shell_windows.zig").reveal(path),
        else => false,
    };
    if (!selected) native.showInFolder(path);
}

pub fn escaped(path: []const u8, out: []u8) ?[]const u8 {
    assert(path.len <= paths.path_max);
    var w: std.Io.Writer = .fixed(out);
    const hex = "0123456789ABCDEF";
    for (path) |c| {
        if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "/-._~", c) != null) {
            w.writeByte(c) catch return null;
        } else {
            w.writeAll(&.{ '%', hex[c >> 4], hex[c & 15] }) catch return null;
        }
    }
    return out[0..w.end];
}

pub fn trash_info(path: []const u8, date: Date, out: *[info_max]u8) ?[]const u8 {
    assert(date.month >= 1 and date.month <= 12);
    assert(date.day >= 1 and date.day <= 31);
    var encoded: [paths.path_max * 3]u8 = undefined;
    const p = escaped(path, &encoded) orelse return null;
    return std.fmt.bufPrint(out, "[Trash Info]\nPath={s}\n" ++
        "DeletionDate={d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}\n", .{
        p, date.year, date.month, date.day, date.hour, date.minute, date.second,
    }) catch null;
}

pub fn unique_name(base: []const u8, attempt: u32, out: []u8) ?[]const u8 {
    assert(base.len > 0 and attempt < attempts_max);
    if (attempt == 0) return std.fmt.bufPrint(out, "{s}", .{base}) catch null;
    return std.fmt.bufPrint(out, "{s}.{d}", .{ base, attempt }) catch null;
}

pub fn home_trash(xdg: ?[]const u8, home: ?[]const u8, out: []u8) ?[]const u8 {
    if (xdg) |value| {
        if (value.len > 0 and value[0] == '/')
            return std.fmt.bufPrint(out, "{s}/Trash", .{value}) catch null;
    }
    const value = home orelse return null;
    if (value.len == 0 or value[0] != '/') return null;
    return std.fmt.bufPrint(out, "{s}/.local/share/Trash", .{value}) catch null;
}

pub fn mount_trash(top: []const u8, uid: u32, shared: bool, out: []u8) ?[]const u8 {
    assert(top.len > 0 and top[0] == '/');
    const sep = if (std.mem.eql(u8, top, "/")) "" else "/";
    if (shared)
        return std.fmt.bufPrint(out, "{s}{s}.Trash/{d}", .{ top, sep, uid }) catch null;
    return std.fmt.bufPrint(out, "{s}{s}.Trash-{d}", .{ top, sep, uid }) catch null;
}

test "trashinfo escapes bytes and uses a local ISO date" {
    var out: [info_max]u8 = undefined;
    const date: Date = .{ .year = 2026, .month = 1, .day = 9, .hour = 3, .minute = 4, .second = 5 };
    try std.testing.expectEqualStrings("[Trash Info]\nPath=/a%20b/%25%0A%C3%A9.png\n" ++
        "DeletionDate=2026-01-09T03:04:05\n", trash_info("/a b/%\né.png", date, &out).?);
    try std.testing.expectEqualStrings("[Trash Info]\nPath=folder/a.png\n" ++
        "DeletionDate=2026-01-09T03:04:05\n", trash_info("folder/a.png", date, &out).?);
}

test "trash names and directory selection are bounded and deterministic" {
    var out: [paths.path_max]u8 = undefined;
    const t = std.testing;
    try t.expectEqualStrings("a.png", unique_name("a.png", 0, &out).?);
    try t.expectEqualStrings("a.png.1023", unique_name("a.png", 1023, &out).?);
    try t.expectEqualStrings("/data/Trash", home_trash("/data", "/home/me", &out).?);
    try t.expectEqualStrings("/home/me/.local/share/Trash", home_trash("", "/home/me", &out).?);
    try t.expectEqualStrings(
        "/home/me/.local/share/Trash",
        home_trash("relative", "/home/me", &out).?,
    );
    try t.expect(home_trash(null, null, &out) == null);
    try t.expectEqualStrings("/usb/.Trash/42", mount_trash("/usb", 42, true, &out).?);
    try t.expectEqualStrings("/.Trash-42", mount_trash("/", 42, false, &out).?);
}
