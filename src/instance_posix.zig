//! The single-instance message over a Unix socket, for Linux and macOS:
//! `$XDG_RUNTIME_DIR/nanoview.sock`, or `/tmp/nanoview-<uid>.sock`. The
//! first instance listens; a later one connects, writes, and exits.
const nanoui = @import("nanoui");
const std = @import("std");
const instance = @import("instance.zig");
const paths = @import("paths.zig");
const c = std.c;
const assert = std.debug.assert;

/// How long a reader waits for a sender that connected but stalls.
const read_timeout_ms: u32 = 500;
/// Senders taken per wake; any more wake the UI thread again.
const receives_per_wake_max: u32 = 8;

const Address = c.sockaddr.un;

/// The socket's path in `out`, or null when it would not fit an address.
pub fn socket_path(out: *[paths.path_max]u8) ?[]const u8 {
    const runtime = if (c.getenv("XDG_RUNTIME_DIR")) |v| std.mem.span(v) else "";
    const path = if (runtime.len > 0)
        std.fmt.bufPrint(out, "{s}/nanoview.sock", .{runtime}) catch return null
    else
        std.fmt.bufPrint(out, "/tmp/nanoview-{d}.sock", .{c.getuid()}) catch return null;
    const sun_path_len = @typeInfo(@FieldType(Address, "path")).array.len;
    return if (path.len < sun_path_len) path else null;
}

fn address(path: []const u8) Address {
    var a: Address = .{ .family = c.AF.UNIX, .path = undefined };
    assert(path.len < a.path.len);
    @memset(&a.path, 0);
    @memcpy(a.path[0..path.len], path);
    return a;
}

fn connect_to(path: []const u8) ?c.fd_t {
    const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (fd < 0) return null;
    const a = address(path);
    if (c.connect(fd, @ptrCast(&a), @sizeOf(Address)) != 0) {
        _ = c.close(fd);
        return null;
    }
    return fd;
}

/// Hands `message` to the running instance. False when none answers.
pub fn send(path: []const u8, message: []const u8) bool {
    assert(message.len > 0 and message.len <= instance.message_bytes_max);
    const fd = connect_to(path) orelse return false;
    defer _ = c.close(fd);
    var sent: usize = 0;
    // Each write moves at least one byte or fails: bounded by the length.
    while (sent < message.len) {
        const n = c.write(fd, message[sent..].ptr, message.len - sent);
        if (n <= 0) return false;
        sent += @intCast(n);
    }
    return true;
}

/// Hands `message` to the running instance at the usual socket.
pub fn hand(message: []const u8) bool {
    var buf: [paths.path_max]u8 = undefined;
    const path = socket_path(&buf) orelse return false;
    return send(path, message);
}

var receiver: ?struct { listener: Listener, ctx: *anyopaque, deliver: instance.Deliver } = null;
var inbox: instance.Message = .{};

/// Listens at the usual socket; the UI thread runs `deliver` for each
/// message, woken by nanoui when a sender connects.
pub fn listen(ctx: *anyopaque, deliver: instance.Deliver) error{ Running, Socket, Watch }!void {
    assert(receiver == null);
    var buf: [paths.path_max]u8 = undefined;
    const path = socket_path(&buf) orelse return error.Socket;
    const listener = try Listener.open(path);
    receiver = .{ .listener = listener, .ctx = ctx, .deliver = deliver };
    _ = nanoui.fdwatch.readable(listener.fd, null, on_readable) catch {
        receiver = null;
        listener.close(path);
        return error.Watch;
    };
}

fn on_readable(_: ?*anyopaque) callconv(.c) void {
    const r = receiver orelse return;
    var files: [instance.paths_max][]const u8 = undefined;
    var taken: u32 = 0;
    while (taken < receives_per_wake_max and r.listener.receive(&inbox)) : (taken += 1) {
        r.deliver(r.ctx, inbox.files(&files));
    }
}

pub const Listener = struct {
    fd: c.fd_t,

    /// Listens at `path`. A socket file left by an instance that is gone
    /// (connecting is refused) is replaced; one that answers is running.
    pub fn open(path: []const u8) error{ Running, Socket }!Listener {
        const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
        if (fd < 0) return error.Socket;
        errdefer _ = c.close(fd);
        const a = address(path);
        if (c.bind(fd, @ptrCast(&a), @sizeOf(Address)) != 0) {
            if (c.errno(-1) != .ADDRINUSE) return error.Socket;
            if (connect_to(path)) |other| {
                _ = c.close(other);
                return error.Running;
            }
            var z: [paths.path_max + 1]u8 = undefined;
            @memcpy(z[0..path.len], path);
            z[path.len] = 0;
            _ = c.unlink(@ptrCast(&z));
            if (c.bind(fd, @ptrCast(&a), @sizeOf(Address)) != 0) return error.Socket;
        }
        if (c.listen(fd, 4) != 0) return error.Socket;
        // Readable means a sender is waiting: accept must never block.
        const flags = c.fcntl(fd, c.F.GETFL);
        if (flags < 0) return error.Socket;
        if (c.fcntl(fd, c.F.SETFL, flags | @as(c_int, @bitCast(c.O{ .NONBLOCK = true }))) < 0)
            return error.Socket;
        return .{ .fd = fd };
    }

    pub fn close(l: Listener, path: []const u8) void {
        assert(l.fd >= 0);
        _ = c.close(l.fd);
        var z: [paths.path_max + 1]u8 = undefined;
        @memcpy(z[0..path.len], path);
        z[path.len] = 0;
        _ = c.unlink(@ptrCast(&z));
    }

    /// One waiting sender's message into `m`. False when none waits or
    /// what came is not a whole message.
    pub fn receive(l: Listener, m: *instance.Message) bool {
        assert(l.fd >= 0);
        const fd = c.accept(l.fd, null, null);
        if (fd < 0) return false;
        defer _ = c.close(fd);
        // Accepted sockets inherit O_NONBLOCK on BSD, not on Linux: block,
        // but only briefly, so a stalled sender cannot hold the UI.
        const flags = c.fcntl(fd, c.F.GETFL);
        const nonblock: c_int = @bitCast(c.O{ .NONBLOCK = true });
        if (flags >= 0) _ = c.fcntl(fd, c.F.SETFL, flags & ~nonblock);
        const timeout: c.timeval = .{ .sec = 0, .usec = read_timeout_ms * 1000 };
        _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.RCVTIMEO, @ptrCast(&timeout), @sizeOf(c.timeval));
        m.len = 0;
        // Each read adds at least one byte or ends: bounded by the buffer.
        while (m.len < m.buf.len and !m.complete()) {
            const n = c.read(fd, m.buf[m.len..].ptr, m.buf.len - m.len);
            if (n <= 0) break;
            m.len += @intCast(n);
        }
        return m.complete();
    }
};

const testing = std.testing;

/// Under /tmp: a test directory's full path may not fit an address.
fn test_path(buf: *[paths.path_max]u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "/tmp/nanoview-test-{d}.sock", .{c.getpid()});
}

test "a sender's paths reach the listener, and a stale socket is replaced" {
    var buf: [paths.path_max]u8 = undefined;
    const path = try test_path(&buf);
    var out: [instance.message_bytes_max]u8 = undefined;
    try testing.expect(!send(path, instance.encode(&.{"/a.png"}, &out)));

    const listener = try Listener.open(path);
    try testing.expectError(error.Running, Listener.open(path));
    var m: instance.Message = .{};
    try testing.expect(!listener.receive(&m));
    try testing.expect(send(path, instance.encode(&.{ "/a.png", "/b c.png" }, &out)));
    try testing.expect(listener.receive(&m));
    var got: [instance.paths_max][]const u8 = undefined;
    const files = m.files(&got);
    try testing.expectEqual(@as(usize, 2), files.len);
    try testing.expectEqualStrings("/b c.png", files[1]);

    // Gone without removing its socket file: the next one takes over.
    _ = c.close(listener.fd);
    const next = try Listener.open(path);
    defer next.close(path);
    try testing.expect(send(path, instance.encode(&.{}, &out)));
    try testing.expect(next.receive(&m));
    try testing.expectEqual(@as(usize, 0), m.files(&got).len);
}
