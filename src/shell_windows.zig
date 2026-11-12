const std = @import("std");
const paths = @import("paths.zig");
const assert = std.debug.assert;
const wide_max = paths.path_max + 2;
const Operation = extern struct {
    window: ?*anyopaque = null,
    function: u32 = 3,
    from: [*:0]const u16,
    to: ?[*:0]const u16 = null,
    flags: u16 = 0x0040 | 0x0010 | 0x0004 | 0x0400,
    aborted: i32 = 0,
    mappings: ?*anyopaque = null,
    title: ?[*:0]const u16 = null,
};
extern "shell32" fn SHFileOperationW(op: *Operation) callconv(.winapi) i32;
extern "shell32" fn ILCreateFromPathW(path: [*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "shell32" fn ILFree(pidl: *anyopaque) callconv(.winapi) void;
extern "shell32" fn SHOpenFolderAndSelectItems(
    pidl: *anyopaque,
    count: u32,
    children: ?*anyopaque,
    flags: u32,
) callconv(.winapi) i32;

fn wide(path: []const u8, out: *[wide_max]u16) ?[:0]const u16 {
    assert(path.len > 0);
    if (path.len > paths.path_max or std.mem.indexOfScalar(u8, path, 0) != null) return null;
    const n = std.unicode.wtf8ToWtf16Le(out, path) catch return null;
    for (out[0..n]) |*c| {
        if (c.* == '/') c.* = '\\';
    }
    out[n] = 0;
    out[n + 1] = 0;
    return out[0..n :0];
}

pub fn trash(path: []const u8) bool {
    var out: [wide_max]u16 = undefined;
    const p = wide(path, &out) orelse return false;
    var op: Operation = .{ .from = p.ptr };
    return SHFileOperationW(&op) == 0 and op.aborted == 0;
}

pub fn reveal(path: []const u8) bool {
    var out: [wide_max]u16 = undefined;
    const p = wide(path, &out) orelse return false;
    const pidl = ILCreateFromPathW(p.ptr) orelse return false;
    defer ILFree(pidl);
    return SHOpenFolderAndSelectItems(pidl, 0, null, 0) >= 0;
}
