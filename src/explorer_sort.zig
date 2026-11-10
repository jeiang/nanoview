//! Windows: the sort order of an open Explorer window showing the folder,
//! asked through the shell's COM interfaces by vtable slot. Explorer's
//! stored per-folder setting (registry bags) is not read: with no Explorer
//! window on the folder the order is name. Every failure gives name order.
//! GUIDs and slots are from the Windows SDK headers (exdisp.h, servprov.h,
//! shobjidl.h, shlguid.h, propkey.h).
const std = @import("std");
const builtin = @import("builtin");
const sort_order = @import("sort_order.zig");
const assert = std.debug.assert;

pub const Guid = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };

const fmtid_storage: Guid = .{ .a = 0xB725F130, .b = 0x47EF, .c = 0x101A, .d = .{
    0xA5, 0xF1, 0x02, 0x60, 0x8C, 0x9E, 0xEB, 0xAC,
} };
const fmtid_item_date: Guid = .{ .a = 0xF7DB74B4, .b = 0x4287, .c = 0x4103, .d = .{
    0xAF, 0xBA, 0xF1, 0xB1, 0x3D, 0xCD, 0x75, 0xCF,
} };

/// A sort column's property to a key; anything else, including date
/// created (pid 15), gives name.
pub fn key_of_property(fmtid: Guid, pid: u32) sort_order.Key {
    if (std.meta.eql(fmtid, fmtid_storage)) {
        return switch (pid) {
            4 => .kind, // PKEY_ItemTypeText
            12 => .size, // PKEY_Size
            14 => .date_modified, // PKEY_DateModified
            else => .name, // 10 is PKEY_ItemNameDisplay
        };
    }
    // PKEY_ItemDate: Explorer's "Date" column.
    if (std.meta.eql(fmtid, fmtid_item_date) and pid == 100) return .date_modified;
    return .name;
}

const clsid_shell_windows: Guid = .{ .a = 0x9BA05972, .b = 0xF6A8, .c = 0x11CF, .d = .{
    0xA4, 0x42, 0x00, 0xA0, 0xC9, 0x0A, 0x8F, 0x39,
} };
const iid_shell_windows: Guid = .{ .a = 0x85CB6900, .b = 0x4D95, .c = 0x11CF, .d = .{
    0x96, 0x0C, 0x00, 0x80, 0xC7, 0xF4, 0xEE, 0x85,
} };
const iid_service_provider: Guid = .{ .a = 0x6D5140C1, .b = 0x7436, .c = 0x11CE, .d = .{
    0x80, 0x34, 0x00, 0xAA, 0x00, 0x60, 0x09, 0xFA,
} };
const sid_top_level_browser: Guid = .{ .a = 0x4C96BE40, .b = 0x915C, .c = 0x11CF, .d = .{
    0x99, 0xD3, 0x00, 0xAA, 0x00, 0x4A, 0xE8, 0x37,
} };
const iid_shell_browser: Guid = .{ .a = 0x000214E2, .b = 0x0000, .c = 0x0000, .d = .{
    0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46,
} };
const iid_folder_view2: Guid = .{ .a = 0x1AF3A467, .b = 0x214F, .c = 0x4298, .d = .{
    0x90, 0x8E, 0x06, 0xB0, 0x3E, 0x0B, 0x39, 0xF9,
} };
const iid_persist_folder2: Guid = .{ .a = 0x1AC3D9F0, .b = 0x175C, .c = 0x11D1, .d = .{
    0x95, 0xBE, 0x00, 0x60, 0x97, 0x97, 0xEA, 0x4F,
} };

const clsctx_local_server: u32 = 4;
const vt_i4: u16 = 3;
const windows_max: i32 = 64;
const wide_max: u32 = 32768;

/// A COM object: its first field points at its vtable (nanoui's
/// `windows/webview2.zig` shape, which nanoui does not export).
const Com = extern struct {
    vtable: [*]const *const anyopaque,

    fn slot(c: *Com, comptime T: type, i: usize) T {
        return @ptrCast(@alignCast(c.vtable[i]));
    }

    fn release(c: *Com) void {
        _ = c.slot(*const fn (*Com) callconv(.winapi) u32, 2)(c);
    }

    fn query(c: *Com, iid: *const Guid) ?*Com {
        var out: ?*Com = null;
        const qi = c.slot(*const fn (*Com, *const Guid, *?*Com) callconv(.winapi) i32, 0);
        if (qi(c, iid, &out) < 0) return null;
        return out;
    }
};

/// VARIANT: the type word, three reserved words, and a value as large as
/// two pointers.
const Variant = extern struct {
    vt: u16,
    reserved: [3]u16 = .{ 0, 0, 0 },
    value: [2]usize = .{ 0, 0 },
};

const SortColumn = extern struct { fmtid: Guid, pid: u32, direction: i32 };

const win = struct {
    extern "ole32" fn CoCreateInstance(
        clsid: *const Guid,
        outer: ?*anyopaque,
        ctx: u32,
        iid: *const Guid,
        out: *?*Com,
    ) callconv(.winapi) i32;
    extern "ole32" fn CoTaskMemFree(p: ?*anyopaque) callconv(.winapi) void;
    extern "shell32" fn SHGetPathFromIDListW(pidl: *anyopaque, out: [*]u16) callconv(.winapi) i32;
};

/// Only the main thread asks, one folder at a time.
var want_buf: [wide_max]u16 = undefined;
var path_buf: [wide_max]u16 = undefined;

pub fn detect(dir_path: []const u8) sort_order.Order {
    comptime assert(builtin.os.tag == .windows);
    const want = wide_dir(dir_path, &want_buf) orelse return .{};
    var raw: ?*Com = null;
    const ctx = clsctx_local_server;
    if (win.CoCreateInstance(&clsid_shell_windows, null, ctx, &iid_shell_windows, &raw) < 0)
        return .{};
    const shell_windows = raw orelse return .{};
    defer shell_windows.release();
    var count: i32 = 0;
    const get_count = shell_windows.slot(*const fn (*Com, *i32) callconv(.winapi) i32, 7);
    if (get_count(shell_windows, &count) < 0) return .{};
    const item = shell_windows.slot(*const fn (*Com, Variant, *?*Com) callconv(.winapi) i32, 8);
    var i: i32 = 0;
    while (i < @min(count, windows_max)) : (i += 1) {
        var dispatch: ?*Com = null;
        var index: Variant = .{ .vt = vt_i4 };
        index.value[0] = @as(u32, @bitCast(i));
        if (item(shell_windows, index, &dispatch) < 0) continue;
        const d = dispatch orelse continue;
        defer d.release();
        if (window_order(d, want)) |order| return order;
    }
    return .{};
}

/// The order of one Explorer window, when it shows `want`.
fn window_order(dispatch: *Com, want: []const u16) ?sort_order.Order {
    const provider = dispatch.query(&iid_service_provider) orelse return null;
    defer provider.release();
    var browser_raw: ?*Com = null;
    const query_service = provider.slot(
        *const fn (*Com, *const Guid, *const Guid, *?*Com) callconv(.winapi) i32,
        3,
    );
    if (query_service(provider, &sid_top_level_browser, &iid_shell_browser, &browser_raw) < 0)
        return null;
    const browser = browser_raw orelse return null;
    defer browser.release();
    var view_raw: ?*Com = null;
    const active_view = browser.slot(*const fn (*Com, *?*Com) callconv(.winapi) i32, 15);
    if (active_view(browser, &view_raw) < 0) return null;
    const shell_view = view_raw orelse return null;
    defer shell_view.release();
    const view2 = shell_view.query(&iid_folder_view2) orelse return null;
    defer view2.release();
    if (!shows(view2, want)) return null;
    return sort_of(view2);
}

fn shows(view2: *Com, want: []const u16) bool {
    assert(want.len > 0);
    var folder_raw: ?*Com = null;
    const get_folder = view2.slot(*const fn (*Com, *const Guid, *?*Com) callconv(.winapi) i32, 5);
    if (get_folder(view2, &iid_persist_folder2, &folder_raw) < 0) return false;
    const persist = folder_raw orelse return false;
    defer persist.release();
    var pidl: ?*anyopaque = null;
    const cur_folder = persist.slot(*const fn (*Com, *?*anyopaque) callconv(.winapi) i32, 5);
    if (cur_folder(persist, &pidl) < 0) return false;
    defer win.CoTaskMemFree(pidl);
    if (win.SHGetPathFromIDListW(pidl orelse return false, &path_buf) == 0) return false;
    const len = std.mem.indexOfScalar(u16, &path_buf, 0) orelse return false;
    return eql_ignore_case(trim_separator(path_buf[0..len]), want);
}

fn sort_of(view2: *Com) sort_order.Order {
    var count: i32 = 0;
    const get_count = view2.slot(*const fn (*Com, *i32) callconv(.winapi) i32, 26);
    if (get_count(view2, &count) < 0 or count < 1) return .{};
    var column: SortColumn = undefined;
    const get_columns = view2.slot(*const fn (*Com, *SortColumn, i32) callconv(.winapi) i32, 28);
    if (get_columns(view2, &column, 1) < 0) return .{};
    const key = key_of_property(column.fmtid, column.pid);
    assert(@backingInt(key) <= @backingInt(sort_order.Key.date_modified));
    return .{ .key = key, .ascending = column.direction >= 0 };
}

/// UTF-16, backslashes, no trailing separator.
fn wide_dir(dir_path: []const u8, out: *[wide_max]u16) ?[]const u16 {
    if (dir_path.len == 0 or dir_path.len >= wide_max) return null;
    const n = std.unicode.wtf8ToWtf16Le(out, dir_path) catch return null;
    for (out[0..n]) |*u| {
        if (u.* == '/') u.* = '\\';
    }
    const result = trim_separator(out[0..n]);
    assert(result.len <= n);
    return if (result.len == 0) null else result;
}

fn trim_separator(s: []const u16) []const u16 {
    // `C:\` keeps its separator: Explorer reports a drive root that way.
    if (s.len > 3 and s[s.len - 1] == '\\') return s[0 .. s.len - 1];
    return s;
}

fn eql_ignore_case(a: []const u16, b: []const u16) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (lower(x) != lower(y)) return false;
    }
    return true;
}

fn lower(u: u16) u16 {
    return if (u >= 'A' and u <= 'Z') u + 32 else u;
}

test "key_of_property maps Explorer's columns" {
    const t = std.testing;
    try t.expectEqual(sort_order.Key.name, key_of_property(fmtid_storage, 10));
    try t.expectEqual(sort_order.Key.size, key_of_property(fmtid_storage, 12));
    try t.expectEqual(sort_order.Key.date_modified, key_of_property(fmtid_storage, 14));
    try t.expectEqual(sort_order.Key.kind, key_of_property(fmtid_storage, 4));
    try t.expectEqual(sort_order.Key.name, key_of_property(fmtid_storage, 15));
    try t.expectEqual(sort_order.Key.date_modified, key_of_property(fmtid_item_date, 100));
    try t.expectEqual(sort_order.Key.name, key_of_property(fmtid_item_date, 4));
}
