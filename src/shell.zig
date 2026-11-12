//! Recoverable trash and file-manager selection, with fixed caller-owned buffers.
const std = @import("std");
const builtin = @import("builtin");
const native = @import("nanoui").shell;
const paths = @import("paths.zig");
const fileops = @import("fileops.zig");
const assert = std.debug.assert;
pub const attempts_max: u32 = 1024;
pub const info_max: u32 = paths.path_max * 3 + 128;
pub const Date = struct { year: u32, month: u32, day: u32, hour: u32, minute: u32, second: u32 };

test {
    if (builtin.os.tag == .linux) _ = @import("shell_linux.zig");
}

/// Returns where the file went in the Trash, for `restore`: empty when the
/// system does not say (Windows), null when the file did not move.
pub fn trash(io: std.Io, path: []const u8, out: *[paths.path_max]u8) ?[]const u8 {
    assert(path.len > 0);
    return switch (builtin.os.tag) {
        .linux => @import("shell_linux.zig").trash(io, path, out),
        .windows => if (@import("shell_windows.zig").trash(path)) out[0..0] else null,
        else => native.trashTo(path, out),
    };
}

pub const RestoreError = error{ Unavailable, Exists, Gone, NoFolder, Failed };

/// Moves the file `trash` put at `location` back to `original`, never over
/// a file that took its place since. `Gone` also when the file now at
/// `location` is not the one trashed: the Trash was emptied and another
/// file trashed later took the same place.
pub fn restore(
    io: std.Io,
    location: []const u8,
    original: []const u8,
    identity: fileops.Identity,
) RestoreError!void {
    assert(original.len > 0);
    // The Recycle Bin's own undelete is not a documented interface.
    if (builtin.os.tag == .windows) return error.Unavailable;
    assert(location.len > 0);
    const now = fileops.node(location) orelse return error.Gone;
    if (!std.meta.eql(now.identity, identity)) return error.Gone;
    if (builtin.os.tag == .linux and !@import("shell_linux.zig").recorded(location, original))
        return error.Gone;
    fileops.move_no_replace(location, original) catch |err| switch (err) {
        error.Exists => return error.Exists,
        error.Failed => return error.Failed,
        error.Missing => {
            std.Io.Dir.cwd().access(io, location, .{}) catch return error.Gone;
            return error.NoFolder;
        },
    };
    if (builtin.os.tag == .linux) @import("shell_linux.zig").forget(location);
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

/// Undoes `escaped`; null for a broken escape or a path over the limit.
pub fn unescaped(text: []const u8, out: *[paths.path_max]u8) ?[]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    // Each pass takes at least one byte of `text`.
    while (i < text.len) : (n += 1) {
        if (n == out.len) return null;
        if (text[i] == '%') {
            if (i + 3 > text.len) return null;
            out[n] = std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16) catch return null;
            i += 3;
        } else {
            out[n] = text[i];
            i += 1;
        }
    }
    assert(n <= text.len);
    return out[0..n];
}

/// Whether the `.trashinfo` text `info` says its file came from
/// `original`. A relative `Path=` starts at the top of the volume whose
/// trash, `<top>/.Trash/<uid>` or `<top>/.Trash-<uid>`, holds `location`.
pub fn info_names(info: []const u8, location: []const u8, original: []const u8) bool {
    assert(original.len > 0 and location.len > 0);
    var lines = std.mem.splitScalar(u8, info, '\n');
    // Bounded by the length of `info`.
    const recorded = while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "Path=")) break line["Path=".len..];
    } else return false;
    var buf: [paths.path_max]u8 = undefined;
    const path = unescaped(recorded, &buf) orelse return false;
    if (path.len == 0) return false;
    if (path[0] == '/') return std.mem.eql(u8, path, original);
    if (path.len >= original.len or !std.mem.endsWith(u8, original, path)) return false;
    const top = original[0 .. original.len - path.len - 1];
    if (original[top.len] != '/') return false;
    return std.mem.startsWith(u8, location, top) and
        std.mem.startsWith(u8, location[top.len..], "/.Trash");
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

/// A stand-in `.trashinfo` beside a stand-in `files/a.png`.
fn write_test_info(dir: std.Io.Dir, original: []const u8) !void {
    const date: Date = .{ .year = 2026, .month = 1, .day = 9, .hour = 3, .minute = 4, .second = 5 };
    var info: [info_max]u8 = undefined;
    const text = trash_info(original, date, &info).?;
    try dir.writeFile(std.testing.io, .{ .sub_path = "info/a.png.trashinfo", .data = text });
}

test "restore refuses a taken name, a missing folder, another file, and one gone" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "files", "info" }) |d| try tmp.dir.createDirPath(t.io, d);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "files/a.png", .data = "picture" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.png", .data = "new" });
    var dir_buf: [paths.path_max]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPathFile(t.io, ".", &dir_buf)];
    var bufs: [4][paths.path_max]u8 = undefined;
    const location = paths.join(dir, "files/a.png", &bufs[0]).?;
    const original = paths.join(dir, "a.png", &bufs[1]).?;
    const lost = paths.join(dir, "gone/a.png", &bufs[2]).?;
    const kept = paths.join(dir, "files/kept.png", &bufs[3]).?;
    const id = fileops.node(location).?.identity;
    try write_test_info(tmp.dir, lost);
    try t.expectError(error.NoFolder, restore(t.io, location, lost, id));
    try write_test_info(tmp.dir, original);
    try t.expectError(error.Exists, restore(t.io, location, original, id));
    try tmp.dir.deleteFile(t.io, "a.png");
    // The Trash emptied, and another file trashed to the same place.
    try fileops.move_no_replace(location, kept);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "files/a.png", .data = "other" });
    try t.expectError(error.Gone, restore(t.io, location, original, id));
    try tmp.dir.deleteFile(t.io, "files/a.png");
    try fileops.move_no_replace(kept, location);
    try restore(t.io, location, original, id);
    var data: [16]u8 = undefined;
    try t.expectEqualStrings("picture", try tmp.dir.readFile(t.io, "a.png", &data));
    try t.expectError(error.Gone, restore(t.io, location, original, id));
}

test "a trashinfo names the original by an absolute or a volume-relative path" {
    const t = std.testing;
    const info = "[Trash Info]\nPath=/a%20b/%C3%A9.png\nDeletionDate=2026-01-09T03:04:05\n";
    const home = "/home/me/.local/share/Trash/files/é.png";
    try t.expect(info_names(info, home, "/a b/é.png"));
    try t.expect(!info_names(info, home, "/docs/é.png"));
    const usb = "[Trash Info]\nPath=photos/a.png\n";
    try t.expect(info_names(usb, "/usb/.Trash-42/files/a.png", "/usb/photos/a.png"));
    try t.expect(info_names(usb, "/usb/.Trash/42/files/a.png", "/usb/photos/a.png"));
    try t.expect(!info_names(usb, "/usb/.Trash-42/files/a.png", "/usb/xphotos/a.png"));
    try t.expect(!info_names(usb, "/disk/.Trash-42/files/a.png", "/usb/photos/a.png"));
    try t.expect(!info_names("[Trash Info]\nPath=/a%2\n", home, "/a"));
    try t.expect(!info_names("[Trash Info]\n", home, "/a"));
}
