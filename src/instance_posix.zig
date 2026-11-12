//! The single-instance message over a Unix socket, for Linux and macOS, in
//! a directory only this user may enter: `$XDG_RUNTIME_DIR` on Linux, the
//! per-user temporary directory on macOS. The process holding the lock on
//! `nanoview.lock` there is the running instance and listens at
//! `nanoview.sock`; a later process connects, writes, and exits.
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const std = @import("std");
const instance = @import("instance.zig");
const paths = @import("paths.zig");
const fileops = @import("fileops.zig");
const c = std.c;
const assert = std.debug.assert;

/// How long a reader gives one sender for its whole message.
const receive_ms_max: i64 = 500;
/// How long a sender waits for the instance holding the lock to listen:
/// it takes the lock before its window opens, and listens just after.
const connect_wait_ms_max: u32 = 3000;
const connect_step_ms: u32 = 50;
/// Senders waiting to be taken: a file manager opening many files at
/// once starts as many processes.
const pending_senders_max: c_int = 16;
/// Senders taken per wake; any more wake the UI thread again.
const receives_per_wake_max: u32 = 8;
const darwin_user_temp_dir: c_int = 65537; // _CS_DARWIN_USER_TEMP_DIR, <unistd.h>
extern "c" fn confstr(name: c_int, buf: [*]u8, len: usize) usize;
extern "c" fn getpeereid(fd: c.fd_t, uid: *c.uid_t, gid: *c.gid_t) c_int;

const Address = c.sockaddr.un;
const sun_path_len = @typeInfo(@FieldType(Address, "path")).array.len;
const Path = [paths.path_max + 1]u8;

/// The private directory, without a trailing slash, in `out`. Linux
/// without `XDG_RUNTIME_DIR` has none: a shared /tmp would let another
/// user take the name and receive this user's file paths.
fn directory(out: *[paths.path_max]u8) error{NoRuntimeDir}![]const u8 {
    var value: []const u8 = "";
    if (builtin.os.tag.isDarwin()) {
        const n = confstr(darwin_user_temp_dir, out, out.len);
        if (n > 1 and n <= out.len) value = out[0 .. n - 1];
    }
    if (value.len == 0) {
        const name = if (builtin.os.tag.isDarwin()) "TMPDIR" else "XDG_RUNTIME_DIR";
        const env = std.mem.span(c.getenv(name) orelse return error.NoRuntimeDir);
        if (env.len > out.len) return error.NoRuntimeDir;
        @memcpy(out[0..env.len], env);
        value = out[0..env.len];
    }
    value = std.mem.trimEnd(u8, value, "/");
    if (value.len == 0 or value[0] != '/') return error.NoRuntimeDir;
    return value;
}

fn place(dir: []const u8, name: []const u8, out: *Path) ?[:0]const u8 {
    assert(dir.len > 0 and name.len > 0);
    const path = std.fmt.bufPrintSentinel(out, "{s}/{s}", .{ dir, name }, 0) catch return null;
    return if (path.len < sun_path_len) path else null;
}

fn address(path: []const u8) Address {
    var a: Address = .{ .family = c.AF.UNIX, .path = undefined };
    assert(path.len < a.path.len);
    @memset(&a.path, 0);
    @memcpy(a.path[0..path.len], path);
    return a;
}

/// True when the other end of `fd` runs as this user.
fn peer_is_user(fd: c.fd_t) bool {
    if (builtin.os.tag == .linux) {
        const Cred = extern struct { pid: i32, uid: u32, gid: u32 };
        var cred: Cred = undefined;
        var len: c.socklen_t = @sizeOf(Cred);
        const peercred = std.os.linux.SO.PEERCRED;
        if (c.getsockopt(fd, c.SOL.SOCKET, peercred, @ptrCast(&cred), &len) != 0) return false;
        return len == @sizeOf(Cred) and cred.uid == c.getuid();
    }
    var uid: c.uid_t = undefined;
    var gid: c.gid_t = undefined;
    return getpeereid(fd, &uid, &gid) == 0 and uid == c.getuid();
}

/// Only a socket this user made, served by this user: not a file another
/// user put there to receive the paths.
fn connect_to(path: [:0]const u8) ?c.fd_t {
    const n = fileops.node(path) orelse return null;
    if (!n.socket or n.uid != c.getuid()) return null;
    const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (fd < 0) return null;
    const a = address(path);
    if (c.connect(fd, @ptrCast(&a), @sizeOf(Address)) != 0 or !peer_is_user(fd)) {
        _ = c.close(fd);
        return null;
    }
    return fd;
}

fn write_all(fd: c.fd_t, message: []const u8) bool {
    assert(message.len > 0 and message.len <= instance.message_bytes_max);
    var sent: usize = 0;
    // Each write moves at least one byte or fails: bounded by the length.
    while (sent < message.len) {
        const n = c.write(fd, message[sent..].ptr, message.len - sent);
        if (n <= 0) return false;
        sent += @intCast(n);
    }
    return true;
}

/// True while some process holds the lock in `dir`.
fn held(dir: []const u8) bool {
    var buf: Path = undefined;
    const path = place(dir, "nanoview.lock", &buf) orelse return false;
    const fd = c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true });
    if (fd < 0) return false;
    defer _ = c.close(fd);
    return c.flock(fd, c.LOCK.SH | c.LOCK.NB) != 0;
}

/// Hands `message` to the instance holding the lock in `dir`. False when
/// it lets go of the lock, or does not listen in time.
fn send_at(dir: []const u8, message: []const u8) bool {
    var buf: Path = undefined;
    const path = place(dir, "nanoview.sock", &buf) orelse return false;
    for (0..connect_wait_ms_max / connect_step_ms) |_| {
        if (connect_to(path)) |fd| {
            defer _ = c.close(fd);
            return write_all(fd, message);
        }
        if (!held(dir)) return false;
        var none: [0]c.pollfd = .{};
        _ = c.poll(&none, 0, connect_step_ms);
    }
    return false;
}

/// Hands `message` to the running instance. False when none answers.
pub fn hand(message: []const u8) bool {
    var buf: [paths.path_max]u8 = undefined;
    const dir = directory(&buf) catch return false;
    return send_at(dir, message);
}

const Owner = struct {
    lock: c.fd_t,
    listener: c.fd_t = -1,
    socket_buf: Path = undefined,
    socket_len: usize = 0,

    fn socket(o: *const Owner) [:0]const u8 {
        assert(o.socket_len > 0);
        return o.socket_buf[0..o.socket_len :0];
    }

    /// The socket goes before the lock, so it is never a successor's.
    fn release(o: *const Owner) void {
        assert(o.lock >= 0 and o.listener >= 0);
        _ = c.unlink(o.socket());
        _ = c.close(o.listener);
        _ = c.close(o.lock);
    }
};

/// Takes the lock in `dir` and listens there. `Running` when another
/// process holds the lock, whether or not it listens yet.
fn claim_at(dir: []const u8) error{ Running, Listen }!Owner {
    var lock_buf: Path = undefined;
    const lock_path = place(dir, "nanoview.lock", &lock_buf) orelse return error.Listen;
    const flags: c.O = .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true, .NOFOLLOW = true };
    const lock = c.open(lock_path, flags, @as(c.mode_t, 0o600));
    if (lock < 0) return error.Listen;
    errdefer _ = c.close(lock);
    if (c.flock(lock, c.LOCK.EX | c.LOCK.NB) != 0) {
        return if (c.errno(-1) == .AGAIN) error.Running else error.Listen;
    }
    var o: Owner = .{ .lock = lock };
    const path = place(dir, "nanoview.sock", &o.socket_buf) orelse return error.Listen;
    o.socket_len = path.len;
    // The lock is this process's, so a socket here is left by an instance
    // that is gone. Anything else is not this program's to remove.
    if (fileops.node(path)) |n| {
        if (!n.socket or n.uid != c.getuid()) return error.Listen;
        _ = c.unlink(path);
    }
    o.listener = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (o.listener < 0) return error.Listen;
    errdefer _ = c.close(o.listener);
    const a = address(path);
    if (c.bind(o.listener, @ptrCast(&a), @sizeOf(Address)) != 0) return error.Listen;
    errdefer _ = c.unlink(path);
    if (c.listen(o.listener, pending_senders_max) != 0) return error.Listen;
    // Readable means a sender is waiting: accept must never block.
    if (!nonblocking(o.listener)) return error.Listen;
    return o;
}

fn nonblocking(fd: c.fd_t) bool {
    const flags = c.fcntl(fd, c.F.GETFL);
    if (flags < 0) return false;
    return c.fcntl(fd, c.F.SETFL, flags | @as(c_int, @bitCast(c.O{ .NONBLOCK = true }))) >= 0;
}

var owner: ?Owner = null;
var receiver: ?struct { ctx: *anyopaque, deliver: instance.Deliver } = null;
var inbox: instance.Message = .{};

/// Before the slow startup, so a process started at the same moment finds
/// this one running and waits for it to listen.
pub fn claim() error{ Running, NoRuntimeDir, Listen }!void {
    assert(owner == null);
    var buf: [paths.path_max]u8 = undefined;
    owner = try claim_at(try directory(&buf));
}

/// Once the window exists: the UI thread runs `deliver` for each message,
/// woken by nanoui when a sender connects. Senders before now wait queued.
pub fn listen(ctx: *anyopaque, deliver: instance.Deliver) error{Watch}!void {
    assert(owner != null and receiver == null);
    receiver = .{ .ctx = ctx, .deliver = deliver };
    _ = nanoui.fdwatch.readable(owner.?.listener, null, on_readable) catch {
        // Unwatched, it would take messages and never show them.
        release();
        return error.Watch;
    };
}

/// On a normal exit, so the next instance finds no socket to clear.
pub fn release() void {
    const o = owner orelse return;
    o.release();
    owner = null;
    receiver = null;
}

fn on_readable(_: ?*anyopaque) callconv(.c) void {
    const r = receiver orelse return;
    const o = owner orelse return;
    var files: [instance.paths_max][]const u8 = undefined;
    var taken: u32 = 0;
    while (taken < receives_per_wake_max and receive(o.listener, &inbox)) : (taken += 1) {
        r.deliver(r.ctx, inbox.files(&files));
    }
}

fn now_ms() i64 {
    var t: c.timespec = undefined;
    if (c.clock_gettime(.MONOTONIC, &t) != 0) return 0;
    return @as(i64, t.sec) * 1000 + @divTrunc(@as(i64, t.nsec), 1_000_000);
}

/// One waiting sender's message into `m`. False when none waits, or what
/// came in `receive_ms_max` is not a whole message: a sender that drips
/// bytes cannot hold the UI thread longer.
fn receive(listener: c.fd_t, m: *instance.Message) bool {
    assert(listener >= 0);
    const fd = c.accept(listener, null, null);
    if (fd < 0) return false;
    defer _ = c.close(fd);
    // Accepted sockets inherit O_NONBLOCK on BSD, not on Linux: poll waits.
    if (!nonblocking(fd)) return false;
    const deadline = now_ms() + receive_ms_max;
    m.len = 0;
    // Each pass reads at least one byte or ends: bounded by the buffer.
    while (m.len < m.buf.len and !m.complete()) {
        const left = deadline - now_ms();
        if (left <= 0) break;
        var ready = [1]c.pollfd{.{ .fd = fd, .events = c.POLL.IN, .revents = 0 }};
        if (c.poll(&ready, 1, @intCast(left)) <= 0) break;
        const n = c.read(fd, m.buf[m.len..].ptr, m.buf.len - m.len);
        if (n <= 0) break;
        m.len += @intCast(n);
    }
    return m.complete();
}

const testing = std.testing;

/// Under /tmp: a test directory's full path may not fit an address.
const TestDir = struct {
    buf: Path = undefined,
    len: usize = 0,

    fn create() !TestDir {
        var d: TestDir = .{};
        const pid = c.getpid();
        const made = try std.fmt.bufPrintSentinel(&d.buf, "/tmp/nanoview-test-{d}", .{pid}, 0);
        d.len = made.len;
        if (c.mkdir(made, 0o700) != 0) return error.TestDir;
        return d;
    }

    fn path(d: *const TestDir) []const u8 {
        return d.buf[0..d.len];
    }

    fn remove(d: *const TestDir, names: []const []const u8) void {
        for (names) |name| {
            var buf: Path = undefined;
            if (place(d.path(), name, &buf)) |p| _ = c.unlink(p);
        }
        _ = c.rmdir(d.buf[0..d.len :0]);
    }
};

test "a sender's paths reach the lock holder, which clears its socket on exit" {
    const dir = try TestDir.create();
    defer dir.remove(&.{ "nanoview.lock", "nanoview.sock" });
    var out: [instance.message_bytes_max]u8 = undefined;
    try testing.expect(!send_at(dir.path(), instance.encode(&.{"/a.png"}, &out)));
    const first = try claim_at(dir.path());
    try testing.expectError(error.Running, claim_at(dir.path()));
    var m: instance.Message = .{};
    try testing.expect(!receive(first.listener, &m));
    try testing.expect(send_at(dir.path(), instance.encode(&.{ "/a.png", "/b c.png" }, &out)));
    try testing.expect(receive(first.listener, &m));
    var got: [instance.paths_max][]const u8 = undefined;
    const files = m.files(&got);
    try testing.expectEqual(@as(usize, 2), files.len);
    try testing.expectEqualStrings("/b c.png", files[1]);
    first.release();
    try testing.expect(fileops.node(first.socket()) == null);
    // The lock is free again: a sender gives up at once, not after waiting.
    try testing.expect(!send_at(dir.path(), instance.encode(&.{}, &out)));
}

test "a socket left by a crash is replaced, and a file of another kind is kept" {
    const dir = try TestDir.create();
    defer dir.remove(&.{ "nanoview.lock", "nanoview.sock" });
    const crashed = try claim_at(dir.path());
    _ = c.close(crashed.listener);
    _ = c.close(crashed.lock);
    const next = try claim_at(dir.path());
    var out: [instance.message_bytes_max]u8 = undefined;
    try testing.expect(send_at(dir.path(), instance.encode(&.{}, &out)));
    var m: instance.Message = .{};
    try testing.expect(receive(next.listener, &m));
    next.release();
    const flags: c.O = .{ .ACCMODE = .WRONLY, .CREAT = true };
    const file = c.open(next.socket(), flags, @as(c.mode_t, 0o600));
    try testing.expect(file >= 0);
    _ = c.close(file);
    try testing.expectError(error.Listen, claim_at(dir.path()));
    try testing.expect(fileops.node(next.socket()).?.socket == false);
}

test "a sender that stops halfway is dropped after the time limit" {
    const dir = try TestDir.create();
    defer dir.remove(&.{ "nanoview.lock", "nanoview.sock" });
    const o = try claim_at(dir.path());
    defer o.release();
    const fd = connect_to(o.socket()).?;
    defer _ = c.close(fd);
    try testing.expect(write_all(fd, "/a.png\n"));
    const start = now_ms();
    var m: instance.Message = .{};
    try testing.expect(!receive(o.listener, &m));
    try testing.expect(now_ms() - start >= receive_ms_max);
}

test "on macOS the socket is in this user's own temporary directory" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    var buf: [paths.path_max]u8 = undefined;
    const dir = try directory(&buf);
    try testing.expect(!std.mem.startsWith(u8, dir, "/tmp"));
    try testing.expectEqual(c.getuid(), fileops.node(dir).?.uid);
    var socket: Path = undefined;
    try testing.expect(place(dir, "nanoview.sock", &socket) != null);
}
