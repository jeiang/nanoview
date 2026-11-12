//! File changes the viewer makes on disk: new names, moves that never
//! replace a file, and the stack of what this run moved to the Trash.
const std = @import("std");
const builtin = @import("builtin");
const paths = @import("paths.zig");
const folder = @import("folder.zig");
const assert = std.debug.assert;

/// Moves to the Trash that Restore can undo, newest last; older ones drop out.
pub const trash_undo_max: u32 = 16;

pub const NameProblem = enum {
    empty,
    separator,
    dots,
    too_long,

    pub fn text(problem: NameProblem) []const u8 {
        return switch (problem) {
            .empty => "The name is empty",
            .separator => "A name cannot contain a slash",
            .dots => "A name cannot be . or ..",
            .too_long => "The name is too long",
        };
    }
};

/// Null when `name` can name a file in the picture's folder.
pub fn check_name(name: []const u8) ?NameProblem {
    if (name.len == 0) return .empty;
    if (name.len > folder.name_len_max) return .too_long;
    for (name) |c| {
        if (c == '/' or c == 0) return .separator;
        if (builtin.os.tag == .windows and (c == '\\' or c == ':')) return .separator;
    }
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return .dots;
    return null;
}

/// The name without its extension: what Rename selects. A leading dot
/// starts no extension.
pub fn stem_len(name: []const u8) usize {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name.len;
    const result = if (dot == 0) name.len else dot;
    assert(result <= name.len);
    return result;
}

pub const MoveError = error{ Exists, Missing, Failed };

/// Renames `from` to `to`, failing with `Exists` rather than replace a file.
pub fn move_no_replace(from: []const u8, to: []const u8) MoveError!void {
    assert(from.len > 0 and to.len > 0);
    return switch (builtin.os.tag) {
        .windows => move_windows(from, to),
        .linux => move_linux(from, to),
        else => move_macos(from, to),
    };
}

fn z(path: []const u8, out: *[paths.path_max + 1]u8) MoveError![:0]const u8 {
    if (path.len > paths.path_max or std.mem.indexOfScalar(u8, path, 0) != null)
        return error.Failed;
    @memcpy(out[0..path.len], path);
    out[path.len] = 0;
    return out[0..path.len :0];
}

const rename_excl: c_uint = 0x4; // RENAME_EXCL in <stdio.h>
extern "c" fn renamex_np(from: [*:0]const u8, to: [*:0]const u8, flags: c_uint) c_int;

fn move_macos(from: []const u8, to: []const u8) MoveError!void {
    var from_buf: [paths.path_max + 1]u8 = undefined;
    var to_buf: [paths.path_max + 1]u8 = undefined;
    const rc = renamex_np((try z(from, &from_buf)).ptr, (try z(to, &to_buf)).ptr, rename_excl);
    if (rc == 0) return;
    return switch (std.posix.errno(rc)) {
        .EXIST => error.Exists,
        .NOENT => error.Missing,
        else => error.Failed,
    };
}

fn move_linux(from: []const u8, to: []const u8) MoveError!void {
    const linux = std.os.linux;
    var from_buf: [paths.path_max + 1]u8 = undefined;
    var to_buf: [paths.path_max + 1]u8 = undefined;
    const a = try z(from, &from_buf);
    const b = try z(to, &to_buf);
    const cwd = linux.AT.FDCWD;
    const rc = linux.renameat2(cwd, a, cwd, b, .{ .NOREPLACE = true });
    switch (linux.errno(rc)) {
        .SUCCESS => return,
        .EXIST => return error.Exists,
        .NOENT => return error.Missing,
        // A file system without RENAME_NOREPLACE (some network and FUSE
        // ones): check, then rename. A file made in between is replaced;
        // that race needs another program writing the same new name in the
        // same instant, which the user cannot tell from a later write.
        .INVAL, .NOSYS => {
            var st: linux.Statx = undefined;
            const exists = linux.statx(cwd, b, linux.AT.SYMLINK_NOFOLLOW, .{}, &st);
            if (linux.errno(exists) != .NOENT) return error.Exists;
            const plain = linux.renameat(cwd, a, cwd, b);
            return switch (linux.errno(plain)) {
                .SUCCESS => {},
                .NOENT => error.Missing,
                else => error.Failed,
            };
        },
        else => return error.Failed,
    }
}

const wide_max = paths.path_max + 1;
extern "kernel32" fn MoveFileExW(
    from: [*:0]const u16,
    to: [*:0]const u16,
    flags: u32,
) callconv(.winapi) i32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

fn wide(path: []const u8, out: *[wide_max]u16) MoveError![:0]const u16 {
    if (path.len > paths.path_max or std.mem.indexOfScalar(u8, path, 0) != null)
        return error.Failed;
    const n = std.unicode.wtf8ToWtf16Le(out, path) catch return error.Failed;
    out[n] = 0;
    return out[0..n :0];
}

/// Without MOVEFILE_REPLACE_EXISTING, MoveFileExW never replaces a file.
fn move_windows(from: []const u8, to: []const u8) MoveError!void {
    var from_buf: [wide_max]u16 = undefined;
    var to_buf: [wide_max]u16 = undefined;
    const a = try wide(from, &from_buf);
    const b = try wide(to, &to_buf);
    if (MoveFileExW(a.ptr, b.ptr, 0) != 0) return;
    return switch (GetLastError()) {
        80, 183 => error.Exists, // ERROR_FILE_EXISTS, ERROR_ALREADY_EXISTS
        2, 3 => error.Missing, // ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND
        else => error.Failed,
    };
}

/// One move to the Trash: the file's path, and where the Trash put it.
pub const Trashed = struct {
    original_buf: [paths.path_max]u8 = undefined,
    original_len: u32 = 0,
    location_buf: [paths.path_max]u8 = undefined,
    location_len: u32 = 0,

    pub fn original(t: *const Trashed) []const u8 {
        assert(t.original_len > 0 and t.original_len <= paths.path_max);
        return t.original_buf[0..t.original_len];
    }

    pub fn location(t: *const Trashed) []const u8 {
        assert(t.location_len > 0 and t.location_len <= paths.path_max);
        return t.location_buf[0..t.location_len];
    }
};

pub const TrashStack = struct {
    items: [trash_undo_max]Trashed = undefined,
    count: u32 = 0,

    /// The oldest entry drops out when the stack is full.
    pub fn push(t: *TrashStack, original: []const u8, location: []const u8) void {
        assert(original.len > 0 and original.len <= paths.path_max);
        assert(location.len > 0 and location.len <= paths.path_max);
        if (t.count == trash_undo_max) {
            std.mem.copyForwards(Trashed, t.items[0 .. t.count - 1], t.items[1..t.count]);
            t.count -= 1;
        }
        const item = &t.items[t.count];
        @memcpy(item.original_buf[0..original.len], original);
        item.original_len = @intCast(original.len);
        @memcpy(item.location_buf[0..location.len], location);
        item.location_len = @intCast(location.len);
        t.count += 1;
        assert(t.count <= trash_undo_max);
    }

    pub fn top(t: *const TrashStack) ?*const Trashed {
        assert(t.count <= trash_undo_max);
        if (t.count == 0) return null;
        return &t.items[t.count - 1];
    }

    pub fn pop(t: *TrashStack) void {
        assert(t.count > 0);
        t.count -= 1;
    }
};

const testing = std.testing;

test "a new name is one non-empty file name within the limit" {
    try testing.expectEqual(@as(?NameProblem, null), check_name("b.png"));
    try testing.expectEqual(@as(?NameProblem, null), check_name(".hidden"));
    try testing.expectEqual(@as(?NameProblem, .empty), check_name(""));
    try testing.expectEqual(@as(?NameProblem, .separator), check_name("a/b.png"));
    try testing.expectEqual(@as(?NameProblem, .separator), check_name("a\x00b"));
    try testing.expectEqual(@as(?NameProblem, .dots), check_name("."));
    try testing.expectEqual(@as(?NameProblem, .dots), check_name(".."));
    const long: [folder.name_len_max + 1]u8 = @splat('a');
    try testing.expectEqual(@as(?NameProblem, .too_long), check_name(&long));
    try testing.expectEqual(@as(?NameProblem, null), check_name(long[1..]));
    const windows_separator: ?NameProblem = if (builtin.os.tag == .windows) .separator else null;
    try testing.expectEqual(windows_separator, check_name("a\\b.png"));
}

test "the stem stops at the last dot, not a leading one" {
    try testing.expectEqual(@as(usize, 5), stem_len("photo.jpeg"));
    try testing.expectEqual(@as(usize, 3), stem_len("a.b.png"));
    try testing.expectEqual(@as(usize, 7), stem_len(".hidden"));
    try testing.expectEqual(@as(usize, 4), stem_len("name"));
}

test "the trash stack undoes newest first and forgets the oldest past its limit" {
    var stack: TrashStack = .{};
    try testing.expect(stack.top() == null);
    var name_buf: [32]u8 = undefined;
    for (0..trash_undo_max + 2) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "/p/{d}.png", .{i});
        stack.push(name, "/trash/x");
    }
    try testing.expectEqual(trash_undo_max, stack.count);
    try testing.expectEqualStrings("/p/17.png", stack.top().?.original());
    try testing.expectEqualStrings("/trash/x", stack.top().?.location());
    stack.pop();
    try testing.expectEqualStrings("/p/16.png", stack.top().?.original());
    for (0..trash_undo_max - 2) |_| stack.pop();
    try testing.expectEqualStrings("/p/2.png", stack.top().?.original());
}

test "a move never replaces a file and reports a missing source" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a", .data = "first" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b", .data = "second" });
    var dir_buf: [paths.path_max]u8 = undefined;
    const dir_len = try tmp.dir.realPathFile(testing.io, ".", &dir_buf);
    var a_buf: [paths.path_max]u8 = undefined;
    var b_buf: [paths.path_max]u8 = undefined;
    var c_buf: [paths.path_max]u8 = undefined;
    const a = paths.join(dir_buf[0..dir_len], "a", &a_buf).?;
    const b = paths.join(dir_buf[0..dir_len], "b", &b_buf).?;
    const c = paths.join(dir_buf[0..dir_len], "c", &c_buf).?;
    try testing.expectError(error.Exists, move_no_replace(a, b));
    try move_no_replace(a, c);
    try testing.expectError(error.Missing, move_no_replace(a, b));
    var data: [16]u8 = undefined;
    try testing.expectEqualStrings("second", try tmp.dir.readFile(testing.io, "b", &data));
    try testing.expectEqualStrings("first", try tmp.dir.readFile(testing.io, "c", &data));
}
