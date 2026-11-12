const std = @import("std");
const paths = @import("paths.zig");
const assert = std.debug.assert;
const wide_max = paths.path_max + 2;
const fo_delete: u32 = 3;
const fof_silent: u16 = 0x0004;
const fof_noconfirmation: u16 = 0x0010;
const fof_allowundo: u16 = 0x0040;
const fof_noerrorui: u16 = 0x0400;
/// Without this, a file the Recycle Bin cannot take (a network share, a
/// drive with no bin, a file over the bin's limit) is destroyed silently:
/// `fof_noconfirmation` hides the prompt. With it the shell asks, and a
/// refusal comes back as `aborted`.
const fof_wantnukewarning: u16 = 0x4000;
const Operation = extern struct {
    window: ?*anyopaque = null,
    function: u32 = fo_delete,
    from: [*:0]const u16,
    to: ?[*:0]const u16 = null,
    flags: u16 = fof_allowundo | fof_noconfirmation | fof_silent | fof_noerrorui |
        fof_wantnukewarning,
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
