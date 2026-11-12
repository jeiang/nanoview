//! The single-instance message on Windows: a named mutex tells a later
//! process that one is running, and WM_COPYDATA carries the message to
//! the first one's message-only window, of a class only nanoview uses.
const std = @import("std");
const instance = @import("instance.zig");
const assert = std.debug.assert;

const HWND = *opaque {};
const HANDLE = *anyopaque;
const BOOL = i32;
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;
const WndProc = *const fn (HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;

const WNDCLASSEXW = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXW),
    style: u32 = 0,
    lpfnWndProc: WndProc,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?HANDLE = null,
    hIcon: ?HANDLE = null,
    hCursor: ?HANDLE = null,
    hbrBackground: ?HANDLE = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: ?HANDLE = null,
};

const COPYDATASTRUCT = extern struct {
    dwData: usize,
    cbData: u32,
    lpData: ?*const anyopaque,
};

const LPCWSTR = [*:0]const u16;

extern "kernel32" fn CreateMutexW(
    attrs: ?*anyopaque,
    owner: BOOL,
    name: LPCWSTR,
) callconv(.winapi) ?HANDLE;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
extern "user32" fn RegisterClassExW(class: *const WNDCLASSEXW) callconv(.winapi) u16;
extern "user32" fn CreateWindowExW(
    ex: u32,
    class: LPCWSTR,
    title: LPCWSTR,
    style: u32,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    parent: ?HWND,
    menu: ?HANDLE,
    inst: ?HANDLE,
    param: ?*anyopaque,
) callconv(.winapi) ?HWND;
extern "user32" fn DefWindowProcW(
    hwnd: HWND,
    msg: u32,
    wp: WPARAM,
    lp: LPARAM,
) callconv(.winapi) LRESULT;
extern "user32" fn FindWindowExW(
    parent: ?HWND,
    after: ?HWND,
    class: ?LPCWSTR,
    title: ?LPCWSTR,
) callconv(.winapi) ?HWND;
extern "user32" fn SendMessageTimeoutW(
    hwnd: HWND,
    msg: u32,
    wp: WPARAM,
    lp: LPARAM,
    flags: u32,
    timeout: u32,
    result: ?*usize,
) callconv(.winapi) LRESULT;
extern "user32" fn GetWindowThreadProcessId(hwnd: HWND, pid: ?*u32) callconv(.winapi) u32;
extern "user32" fn AllowSetForegroundWindow(pid: u32) callconv(.winapi) BOOL;

const WM_COPYDATA = 0x004A;
const ERROR_ALREADY_EXISTS = 183;
const SMTO_ABORTIFHUNG = 0x0002;
/// How long a sender waits for the running instance to take the message.
const send_timeout_ms: u32 = 5000;
/// Marks a WM_COPYDATA as nanoview's message.
const message_tag: usize = 0x6E76_6965; // "nvie"
const HWND_MESSAGE: isize = -3;
const class_name = std.unicode.utf8ToUtf16LeStringLiteral("nanoview.instance");
const mutex_name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\nanoview.instance");

fn message_parent() HWND {
    return @ptrFromInt(@as(usize, @bitCast(HWND_MESSAGE)));
}

/// Hands `message` to the running instance. False when none runs or it
/// did not take the message; the mutex stays held for the process's life.
pub fn hand(message: []const u8) bool {
    assert(message.len > 0 and message.len <= instance.message_bytes_max);
    _ = CreateMutexW(null, 0, mutex_name) orelse return false;
    if (GetLastError() != ERROR_ALREADY_EXISTS) return false;
    const target = FindWindowExW(message_parent(), null, class_name, null) orelse return false;
    // The running instance may come to the front only if this one, which
    // the user just started, lets it.
    var pid: u32 = 0;
    _ = GetWindowThreadProcessId(target, &pid);
    if (pid != 0) _ = AllowSetForegroundWindow(pid);
    const data: COPYDATASTRUCT = .{
        .dwData = message_tag,
        .cbData = @intCast(message.len),
        .lpData = message.ptr,
    };
    var result: usize = 0;
    const lp: LPARAM = @bitCast(@intFromPtr(&data));
    const flags = SMTO_ABORTIFHUNG;
    const ok = SendMessageTimeoutW(target, WM_COPYDATA, 0, lp, flags, send_timeout_ms, &result);
    return ok != 0 and result == 1;
}

var receiver: ?struct { ctx: *anyopaque, deliver: instance.Deliver } = null;
var inbox: instance.Message = .{};

fn proc_(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) callconv(.winapi) LRESULT {
    if (msg != WM_COPYDATA) return DefWindowProcW(hwnd, msg, wp, lp);
    const r = receiver orelse return 0;
    const data: *const COPYDATASTRUCT = @ptrFromInt(@as(usize, @bitCast(lp)));
    if (data.dwData != message_tag or data.cbData == 0) return 0;
    if (data.cbData > inbox.buf.len) return 0;
    const bytes: [*]const u8 = @ptrCast(data.lpData orelse return 0);
    @memcpy(inbox.buf[0..data.cbData], bytes[0..data.cbData]);
    inbox.len = data.cbData;
    if (!inbox.complete()) return 0;
    var files: [instance.paths_max][]const u8 = undefined;
    r.deliver(r.ctx, inbox.files(&files));
    return 1;
}

/// Makes the window later instances find; on the UI thread, whose message
/// loop then runs `deliver` for each message.
pub fn listen(ctx: *anyopaque, deliver: instance.Deliver) error{Window}!void {
    assert(receiver == null);
    const inst = GetModuleHandleW(null);
    const class: WNDCLASSEXW = .{
        .lpfnWndProc = proc_,
        .hInstance = inst,
        .lpszClassName = class_name,
    };
    _ = RegisterClassExW(&class);
    const parent = message_parent();
    _ = CreateWindowExW(0, class_name, class_name, 0, 0, 0, 0, 0, parent, null, inst, null) orelse
        return error.Window;
    receiver = .{ .ctx = ctx, .deliver = deliver };
}
