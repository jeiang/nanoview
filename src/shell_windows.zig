//! Windows: the Recycle Bin and Explorer selection. Restore talks to the
//! Recycle Bin's shell folder through COM by vtable slot, as Raymond Chen
//! shows in The Old New Thing: "How can I get information about the items
//! in the Recycle Bin?" (2011-08-30) and "Invoking commands on items in the
//! Recycle Bin" (2011-09-01). GUIDs, slots and constants are from the
//! Windows SDK headers (shobjidl.h, shlguid.h, shlobj.h, shtypes.h,
//! shellapi.h, wtypes.h), as shipped with Zig's mingw-w64.
const std = @import("std");
const builtin = @import("builtin");
const paths = @import("paths.zig");
const explorer_sort = @import("explorer_sort.zig");
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

const Guid = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };

/// IID_IShellFolder2 (shobjidl.h, shlguid.h).
const iid_shell_folder2: Guid = .{ .a = 0x93F2F68C, .b = 0x1D1B, .c = 0x11D3, .d = .{
    0xA3, 0x0E, 0x00, 0xC0, 0x4F, 0x79, 0xAB, 0xD1,
} };
/// IID_IContextMenu (shobjidl.h, shlguid.h).
const iid_context_menu: Guid = .{ .a = 0x000214E4, .b = 0x0000, .c = 0x0000, .d = .{
    0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46,
} };
/// PSGUID_DISPLACED (shlguid.h): the properties of an item moved to the
/// Recycle Bin, with PID_DISPLACED_FROM and PID_DISPLACED_DATE.
const fmtid_displaced: Guid = .{ .a = 0x9B174B33, .b = 0x40FF, .c = 0x11D2, .d = .{
    0xA2, 0x7E, 0x00, 0xC0, 0x4F, 0xC3, 0x08, 0x71,
} };
const pid_displaced_from: u32 = 2;
const pid_displaced_date: u32 = 3;

const s_ok: i32 = 0;
const csidl_bitbucket: i32 = 0x000A; // shlobj.h
const shcontf_folders: u32 = 0x20; // shobjidl.h, SHCONTF
const shcontf_nonfolders: u32 = 0x40;
const shcontf_includehidden: u32 = 0x80;
const shgdn_infolder: u32 = 0x1; // shobjidl.h, SHGDN
const shgdn_forparsing: u32 = 0x8000;
const cmf_normal: u32 = 0x0; // shobjidl.h
/// CMIC_MASK_FLAG_NO_UI is SEE_MASK_FLAG_NO_UI (shobjidl.h, shellapi.h).
const cmic_mask_flag_no_ui: u32 = 0x400;
const sw_shownormal: i32 = 1;
/// The menu command range handed to QueryContextMenu, as in Raymond Chen's
/// example; only the verb is invoked, never an id.
const command_first: u32 = 1;
const command_last: u32 = 0x7FFF;
const vt_empty: u16 = 0; // wtypes.h, VARENUM
const vt_date: u16 = 7;
const vt_bstr: u16 = 8;
const coinit_apartment_threaded: u32 = 0x2;
const invalid_file_attributes: u32 = 0xFFFF_FFFF;
/// Recycle Bin items looked at; a bin holding more is searched this far.
const bin_items_max: u32 = 100_000;
/// How long Restore waits for the file to be back where it was: the shell
/// does not promise that the verb has finished when it returns.
const restore_wait_ms_max: u32 = 2000;
const restore_step_ms: u32 = 50;

/// A COM object: its first field points at its vtable.
const Com = extern struct {
    vtable: [*]const *const anyopaque,

    fn slot(c: *Com, comptime T: type, i: usize) T {
        return @ptrCast(@alignCast(c.vtable[i]));
    }

    fn release(c: *Com) void {
        _ = c.slot(*const fn (*Com) callconv(.winapi) u32, 2)(c);
    }
};

/// VARIANT: the type word, three reserved words, and a value as large as
/// two pointers.
const Variant = extern struct {
    vt: u16,
    reserved: [3]u16 = .{ 0, 0, 0 },
    value: [2]usize = .{ 0, 0 },
};

/// SHCOLUMNID, which is PROPERTYKEY (shtypes.h).
const ColumnId = extern struct { fmtid: Guid, pid: u32 };

/// STRRET (shtypes.h): a string in one of three forms, read only through
/// StrRetToBufW.
const StrRet = extern struct {
    kind: u32,
    value: extern union { wide: ?[*:0]u16, offset: u32, bytes: [260]u8 },
};

/// CMINVOKECOMMANDINFO (shobjidl.h).
const InvokeInfo = extern struct {
    size: u32,
    mask: u32 = cmic_mask_flag_no_ui,
    window: ?*anyopaque = null,
    verb: ?[*:0]const u8 = "undelete",
    parameters: ?[*:0]const u8 = null,
    directory: ?[*:0]const u8 = null,
    show: i32 = sw_shownormal,
    hot_key: u32 = 0,
    icon: ?*anyopaque = null,
};

const win = struct {
    extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, flags: u32) callconv(.winapi) i32;
    extern "ole32" fn CoUninitialize() callconv(.winapi) void;
    extern "ole32" fn CoTaskMemFree(p: ?*anyopaque) callconv(.winapi) void;
    extern "shell32" fn SHGetSpecialFolderLocation(
        window: ?*anyopaque,
        csidl: i32,
        out: *?*anyopaque,
    ) callconv(.winapi) i32;
    extern "shell32" fn SHGetDesktopFolder(out: *?*Com) callconv(.winapi) i32;
    extern "shlwapi" fn StrRetToBufW(
        str: *StrRet,
        pidl: *anyopaque,
        out: [*]u16,
        count: u32,
    ) callconv(.winapi) i32;
    extern "oleaut32" fn VariantChangeType(
        to: *Variant,
        from: *Variant,
        flags: u16,
        vt: u16,
    ) callconv(.winapi) i32;
    extern "oleaut32" fn VariantClear(v: *Variant) callconv(.winapi) i32;
    extern "oleaut32" fn SysStringLen(s: [*]const u16) callconv(.winapi) u32;
    extern "user32" fn CreatePopupMenu() callconv(.winapi) ?*anyopaque;
    extern "user32" fn DestroyMenu(menu: *anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn GetFileAttributesW(path: [*:0]const u16) callconv(.winapi) u32;
    extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
};

/// Only the main thread restores, one file at a time.
var want_buf: [wide_max]u16 = undefined;
var shown_buf: [wide_max]u16 = undefined;
var stored_buf: [wide_max]u16 = undefined;

/// The file a Restore looks for: its folder and name, UTF-16.
const Target = struct { folder: []const u16, name: []const u16 };

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

pub const RestoreError = error{ Gone, Failed };

/// Puts back the newest Recycle Bin item that was `original`, with the
/// bin's own "undelete" verb. `Gone` when the bin holds no such item.
pub fn restore(original: []const u8) RestoreError!void {
    comptime assert(builtin.os.tag == .windows);
    assert(original.len > 0);
    const want = wide(original, &want_buf) orelse return error.Failed;
    const split = std.mem.lastIndexOfScalar(u16, want, '\\') orelse return error.Failed;
    const target: Target = .{ .folder = want[0..split], .name = want[split + 1 ..] };
    if (target.name.len == 0) return error.Failed;
    // The main thread already has its apartment; a second call only counts.
    const apartment = win.CoInitializeEx(null, coinit_apartment_threaded) >= 0;
    defer if (apartment) win.CoUninitialize();
    const bin = recycle_bin() orelse return error.Failed;
    defer bin.release();
    const item = newest(bin, target) orelse return error.Gone;
    defer win.CoTaskMemFree(item);
    if (!undelete(bin, item)) return error.Failed;
    if (!appears(want)) return error.Failed;
}

fn recycle_bin() ?*Com {
    var pidl_raw: ?*anyopaque = null;
    if (win.SHGetSpecialFolderLocation(null, csidl_bitbucket, &pidl_raw) < 0) return null;
    defer win.CoTaskMemFree(pidl_raw);
    const pidl = pidl_raw orelse return null;
    var desktop_raw: ?*Com = null;
    if (win.SHGetDesktopFolder(&desktop_raw) < 0) return null;
    const desktop = desktop_raw orelse return null;
    defer desktop.release();
    // The bin is a child of the desktop, never the desktop itself.
    const bind = desktop.slot(
        *const fn (*Com, *anyopaque, ?*anyopaque, *const Guid, *?*Com) callconv(.winapi) i32,
        5, // IShellFolder::BindToObject
    );
    var bin: ?*Com = null;
    if (bind(desktop, pidl, null, &iid_shell_folder2, &bin) < 0) return null;
    return bin;
}

/// The child id of the newest item that was the target, for the caller to
/// free with CoTaskMemFree. Two files of one path trashed in a row are
/// told apart by the date deleted.
fn newest(bin: *Com, target: Target) ?*anyopaque {
    const flags = shcontf_folders | shcontf_nonfolders | shcontf_includehidden;
    const enum_objects = bin.slot(
        *const fn (*Com, ?*anyopaque, u32, *?*Com) callconv(.winapi) i32,
        4, // IShellFolder::EnumObjects
    );
    var list_raw: ?*Com = null;
    // S_FALSE with no list: the bin is empty.
    if (enum_objects(bin, null, flags, &list_raw) != s_ok) return null;
    const list = list_raw orelse return null;
    defer list.release();
    const next = list.slot(
        *const fn (*Com, u32, *?*anyopaque, ?*u32) callconv(.winapi) i32,
        3, // IEnumIDList::Next
    );
    var best: ?*anyopaque = null;
    var best_date: f64 = 0;
    var i: u32 = 0;
    while (i < bin_items_max) : (i += 1) {
        var child_raw: ?*anyopaque = null;
        if (next(list, 1, &child_raw, null) != s_ok) break;
        const child = child_raw orelse break;
        // A match without a date counts as the oldest.
        const match = is_target(bin, child, target);
        const date: ?f64 = if (match) deleted(bin, child) orelse 0 else null;
        if (date != null and (best == null or date.? > best_date)) {
            if (best) |b| win.CoTaskMemFree(b);
            best = child;
            best_date = date.?;
        } else {
            win.CoTaskMemFree(child);
        }
    }
    return best;
}

fn is_target(bin: *Com, child: *anyopaque, target: Target) bool {
    var from_value: Variant = .{ .vt = vt_empty };
    defer _ = win.VariantClear(&from_value);
    if (!displaced(bin, child, pid_displaced_from, vt_bstr, &from_value)) return false;
    const bstr: ?[*]const u16 = @ptrFromInt(from_value.value[0]);
    const from = bstr orelse return false;
    if (!same_folder(from[0..win.SysStringLen(from)], target.folder)) return false;
    const shown = display_name(bin, child, shgdn_infolder, &shown_buf) orelse return false;
    const stored = display_name(bin, child, shgdn_forparsing, &stored_buf) orelse return false;
    return names_item(shown, stored, target.name);
}

/// When the item went to the bin, as an OLE date: larger is later.
fn deleted(bin: *Com, child: *anyopaque) ?f64 {
    comptime assert(@sizeOf(usize) == @sizeOf(f64));
    var value: Variant = .{ .vt = vt_empty };
    defer _ = win.VariantClear(&value);
    if (!displaced(bin, child, pid_displaced_date, vt_date, &value)) return null;
    return @bitCast(@as(u64, value.value[0]));
}

/// One of the item's displaced properties, changed to `vt`. `out` is left
/// for VariantClear on every path.
fn displaced(bin: *Com, child: *anyopaque, pid: u32, vt: u16, out: *Variant) bool {
    assert(out.vt == vt_empty);
    const key: ColumnId = .{ .fmtid = fmtid_displaced, .pid = pid };
    const get_details = bin.slot(
        *const fn (*Com, *anyopaque, *const ColumnId, *Variant) callconv(.winapi) i32,
        17, // IShellFolder2::GetDetailsEx
    );
    if (get_details(bin, child, &key, out) < 0) {
        out.* = .{ .vt = vt_empty };
        return false;
    }
    return win.VariantChangeType(out, out, 0, vt) >= 0 and out.vt == vt;
}

fn display_name(bin: *Com, child: *anyopaque, flags: u32, out: *[wide_max]u16) ?[]const u16 {
    const get_name = bin.slot(
        *const fn (*Com, *anyopaque, u32, *StrRet) callconv(.winapi) i32,
        11, // IShellFolder::GetDisplayNameOf
    );
    var name: StrRet = undefined;
    if (get_name(bin, child, flags, &name) < 0) return null;
    // StrRetToBufW frees a string the STRRET holds.
    if (win.StrRetToBufW(&name, child, out, wide_max) < 0) return null;
    const len = std.mem.indexOfScalar(u16, out, 0) orelse return null;
    return out[0..len];
}

fn undelete(bin: *Com, child: *anyopaque) bool {
    const get_ui_object = bin.slot(*const fn (
        *Com,
        ?*anyopaque,
        u32,
        [*]const *anyopaque,
        *const Guid,
        ?*u32,
        *?*Com,
    ) callconv(.winapi) i32, 10); // IShellFolder::GetUIObjectOf
    const children = [1]*anyopaque{child};
    var menu_raw: ?*Com = null;
    if (get_ui_object(bin, null, 1, &children, &iid_context_menu, null, &menu_raw) < 0)
        return false;
    const context_menu = menu_raw orelse return false;
    defer context_menu.release();
    const menu = win.CreatePopupMenu() orelse return false;
    defer _ = win.DestroyMenu(menu);
    const query = context_menu.slot(
        *const fn (*Com, *anyopaque, u32, u32, u32, u32) callconv(.winapi) i32,
        3, // IContextMenu::QueryContextMenu
    );
    if (query(context_menu, menu, 0, command_first, command_last, cmf_normal) < 0) return false;
    const info: InvokeInfo = .{ .size = @sizeOf(InvokeInfo) };
    const invoke = context_menu.slot(
        *const fn (*Com, *const InvokeInfo) callconv(.winapi) i32,
        4, // IContextMenu::InvokeCommand
    );
    return invoke(context_menu, &info) >= 0;
}

/// Success only once the file is back at its path.
fn appears(path: [*:0]const u16) bool {
    var waited: u32 = 0;
    while (waited <= restore_wait_ms_max) : (waited += restore_step_ms) {
        if (win.GetFileAttributesW(path) != invalid_file_attributes) return true;
        win.Sleep(restore_step_ms);
    }
    return false;
}

fn same_folder(a: []const u16, b: []const u16) bool {
    // `C:\` and `C:` name one folder.
    const separators = [_]u16{'\\'};
    return explorer_sort.eql_ignore_case(
        std.mem.trimEnd(u16, a, &separators),
        std.mem.trimEnd(u16, b, &separators),
    );
}

/// Whether a bin item that Explorer shows as `shown`, stored in the bin as
/// `stored`, was the file `name`. With extensions hidden Explorer shows
/// only the stem; the bin's stored `$R…` file keeps the extension, so a
/// stem matches only with it.
fn names_item(shown: []const u16, stored: []const u16, name: []const u16) bool {
    assert(name.len > 0);
    const eql = explorer_sort.eql_ignore_case;
    if (eql(shown, name)) return true;
    const dot = std.mem.lastIndexOfScalar(u16, name, '.') orelse return false;
    if (dot == 0 or !eql(shown, name[0..dot])) return false;
    const extension = name[dot..];
    if (stored.len <= extension.len) return false;
    return eql(stored[stored.len - extension.len ..], extension);
}

test "a Recycle Bin item is the file by its name, or its stem and stored extension" {
    const t = std.testing;
    const w = std.unicode.utf8ToUtf16LeStringLiteral;
    const stored = w("C:\\$Recycle.Bin\\S-1\\$RAB12CD.png");
    try t.expect(names_item(w("a.png"), stored, w("a.png")));
    try t.expect(names_item(w("A.PNG"), stored, w("a.png")));
    try t.expect(names_item(w("a"), stored, w("a.png")));
    try t.expect(!names_item(w("a"), w("C:\\$Recycle.Bin\\S-1\\$RAB12CD.jpg"), w("a.png")));
    try t.expect(!names_item(w("b.png"), stored, w("a.png")));
    try t.expect(!names_item(w(""), stored, w(".png")));
    try t.expect(same_folder(w("C:\\Photos\\"), w("c:\\photos")));
    try t.expect(same_folder(w("C:\\"), w("C:")));
    try t.expect(!same_folder(w("C:\\Photos\\Old"), w("C:\\Photos")));
}
