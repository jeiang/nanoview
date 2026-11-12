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
extern "user32" fn PostMessageW(
    hwnd: HWND,
    msg: u32,
    wp: WPARAM,
    lp: LPARAM,
) callconv(.winapi) BOOL;
extern "user32" fn DestroyWindow(hwnd: HWND) callconv(.winapi) BOOL;
extern "kernel32" fn OpenMutexW(
    access: u32,
    inherit: BOOL,
    name: LPCWSTR,
) callconv(.winapi) ?HANDLE;
extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

const WM_COPYDATA = 0x004A;
const WM_APP = 0x8000;
/// Posted to itself: the message taken, open its files outside the send.
const deliver_message = WM_APP + 1;
const ERROR_ALREADY_EXISTS = 183;
const SYNCHRONIZE = 0x0010_0000;
const SMTO_ABORTIFHUNG = 0x0002;
/// How long a sender waits for the running instance to take the message.
const send_timeout_ms: u32 = 5000;
/// How long a sender looks for the running instance's window while its
/// mutex exists: the window comes just after the mutex, before startup.
const find_wait_ms_max: u32 = 3000;
const find_step_ms: u32 = 50;
/// Marks a WM_COPYDATA as nanoview's message.
const message_tag: usize = 0x6E76_6965; // "nvie"
/// Replies to it: taken, or busy with the last one (send again soon).
const reply_taken: usize = 1;
const reply_busy: usize = 2;
const HWND_MESSAGE: isize = -3;
const class_name = std.unicode.utf8ToUtf16LeStringLiteral("nanoview.instance");
const mutex_name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\nanoview.instance");

fn message_parent() HWND {
    return @ptrFromInt(@as(usize, @bitCast(HWND_MESSAGE)));
}

const Sent = enum { taken, busy, failed };

fn send_to(target: HWND, message: []const u8) Sent {
    assert(message.len > 0 and message.len <= instance.message_bytes_max);
    const data: COPYDATASTRUCT = .{
        .dwData = message_tag,
        .cbData = @intCast(message.len),
        .lpData = message.ptr,
    };
    var result: usize = 0;
    const lp: LPARAM = @bitCast(@intFromPtr(&data));
    const flags = SMTO_ABORTIFHUNG;
    const ok = SendMessageTimeoutW(target, WM_COPYDATA, 0, lp, flags, send_timeout_ms, &result);
    if (ok == 0) return .failed;
    return if (result == reply_taken) .taken else if (result == reply_busy) .busy else .failed;
}

/// Hands `message` to the running instance. False when it is gone, or
/// does not take the message in time.
pub fn hand(message: []const u8) bool {
    assert(message.len > 0 and message.len <= instance.message_bytes_max);
    for (0..find_wait_ms_max / find_step_ms) |_| {
        const running = OpenMutexW(SYNCHRONIZE, 0, mutex_name) orelse return false;
        _ = CloseHandle(running);
        if (FindWindowExW(message_parent(), null, class_name, null)) |target| {
            // The running instance may come to the front only if this
            // one, which the user just started, lets it.
            var pid: u32 = 0;
            _ = GetWindowThreadProcessId(target, &pid);
            if (pid != 0) _ = AllowSetForegroundWindow(pid);
            switch (send_to(target, message)) {
                .taken => return true,
                .failed => return false,
                .busy => {},
            }
        }
        Sleep(find_step_ms);
    }
    return false;
}

var mutex: ?HANDLE = null;
var window: ?HWND = null;
var receiver: ?struct { ctx: *anyopaque, deliver: instance.Deliver } = null;
var inbox: instance.Message = .{};
/// The inbox holds a message not yet delivered.
var pending = false;

fn proc_(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) callconv(.winapi) LRESULT {
    switch (msg) {
        WM_COPYDATA => return take(hwnd, lp),
        deliver_message => {
            deliver_inbox();
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wp, lp),
    }
}

/// Copies the message and returns at once: opening a file decodes it, and
/// a sender waiting past its timeout would open the files itself.
fn take(hwnd: HWND, lp: LPARAM) LRESULT {
    if (pending) return reply_busy;
    const data: *const COPYDATASTRUCT = @ptrFromInt(@as(usize, @bitCast(lp)));
    if (data.dwData != message_tag or data.cbData == 0) return 0;
    if (data.cbData > inbox.buf.len) return 0;
    const bytes: [*]const u8 = @ptrCast(data.lpData orelse return 0);
    @memcpy(inbox.buf[0..data.cbData], bytes[0..data.cbData]);
    inbox.len = data.cbData;
    if (!inbox.complete()) return 0;
    if (PostMessageW(hwnd, deliver_message, 0, 0) == 0) return 0;
    pending = true;
    return reply_taken;
}

fn deliver_inbox() void {
    const r = receiver orelse return; // `listen` posts again.
    if (!pending) return;
    assert(inbox.complete());
    var files: [instance.paths_max][]const u8 = undefined;
    r.deliver(r.ctx, inbox.files(&files));
    pending = false;
}

/// Before the slow startup: the mutex, then at once the window later
/// processes look for. `Running` when another process has the mutex.
pub fn claim() error{ Running, Listen }!void {
    assert(mutex == null and window == null);
    const m = CreateMutexW(null, 0, mutex_name) orelse return error.Listen;
    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        // Closed, so `hand` sees the mutex go when the running one exits.
        _ = CloseHandle(m);
        return error.Running;
    }
    const inst = GetModuleHandleW(null);
    const class: WNDCLASSEXW = .{
        .lpfnWndProc = proc_,
        .hInstance = inst,
        .lpszClassName = class_name,
    };
    _ = RegisterClassExW(&class);
    const parent = message_parent();
    window = CreateWindowExW(0, class_name, class_name, 0, 0, 0, 0, 0, parent, null, inst, null);
    if (window == null) {
        _ = CloseHandle(m);
        return error.Listen;
    }
    mutex = m;
}

/// Once the window exists: the UI thread's message loop then runs
/// `deliver` for each message, including one taken before now.
pub fn listen(ctx: *anyopaque, deliver: instance.Deliver) error{Watch}!void {
    assert(window != null and receiver == null);
    receiver = .{ .ctx = ctx, .deliver = deliver };
    if (pending and PostMessageW(window.?, deliver_message, 0, 0) == 0) {
        release();
        return error.Watch;
    }
}

/// On a normal exit; the system also lets go of both at process end.
pub fn release() void {
    if (window) |w| _ = DestroyWindow(w);
    if (mutex) |m| _ = CloseHandle(m);
    window = null;
    mutex = null;
    receiver = null;
}
