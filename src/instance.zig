//! One nanoview at a time, when `single_instance` is set: a new process
//! hands its file arguments to the running one and exits. The message is
//! absolute paths, one per line, ended by an empty line; no paths means
//! "come to the front". Linux and macOS send it over a Unix socket,
//! Windows by WM_COPYDATA.
const std = @import("std");
const builtin = @import("builtin");
const paths = @import("paths.zig");
const assert = std.debug.assert;

pub const platform = if (builtin.os.tag == .windows)
    @import("instance_windows.zig")
else
    @import("instance_posix.zig");

/// Files handed over in one message; more are dropped, as a drop of more
/// than the folder holds would be.
pub const paths_max: u32 = 16;
pub const message_bytes_max: usize = paths_max * (paths.path_max + 1) + 1;

/// Runs on the UI thread with the paths of one message (possibly none).
pub const Deliver = *const fn (ctx: *anyopaque, files: []const []const u8) void;

/// The message for `files`, which must be absolute. A path holding a
/// newline cannot be framed and is skipped; so are paths past the limits.
pub fn encode(files: []const []const u8, out: *[message_bytes_max]u8) []const u8 {
    var len: usize = 0;
    var count: u32 = 0;
    for (files) |file| {
        if (count == paths_max) break;
        if (file.len == 0 or file.len > paths.path_max) continue;
        if (std.mem.indexOfScalar(u8, file, '\n') != null) continue;
        assert(len + file.len + 2 <= out.len);
        @memcpy(out[len..][0..file.len], file);
        out[len + file.len] = '\n';
        len += file.len + 1;
        count += 1;
    }
    out[len] = '\n';
    assert(len + 1 <= out.len);
    return out[0 .. len + 1];
}

/// A message as it arrives, in fixed storage.
pub const Message = struct {
    buf: [message_bytes_max]u8 = undefined,
    len: usize = 0,

    /// True once the ending empty line is in.
    pub fn complete(m: *const Message) bool {
        assert(m.len <= m.buf.len);
        const bytes = m.buf[0..m.len];
        return std.mem.eql(u8, bytes, "\n") or std.mem.endsWith(u8, bytes, "\n\n");
    }

    /// The paths of a complete message, slices into `buf`.
    pub fn files(m: *const Message, out: *[paths_max][]const u8) []const []const u8 {
        assert(m.complete());
        var count: u32 = 0;
        var it = std.mem.splitScalar(u8, m.buf[0..m.len], '\n');
        while (it.next()) |line| {
            if (line.len == 0 or count == paths_max) break;
            out[count] = line;
            count += 1;
        }
        return out[0..count];
    }
};

/// The arguments as absolute paths, in `storage`: the running instance
/// has another working directory. A path that cannot be resolved (one
/// that does not exist) is joined to the working directory as written.
pub fn absolute(
    io: std.Io,
    args: []const []const u8,
    storage: *[paths_max][paths.path_max]u8,
    out: *[paths_max][]const u8,
) []const []const u8 {
    var cwd_buf: [paths.path_max]u8 = undefined;
    const cwd_len = std.Io.Dir.cwd().realPathFile(io, ".", &cwd_buf) catch 0;
    var count: u32 = 0;
    for (args) |arg| {
        if (count == paths_max) break;
        if (arg.len == 0 or arg.len > paths.path_max) continue;
        const buf = &storage[count];
        if (std.Io.Dir.cwd().realPathFile(io, arg, buf)) |len| {
            out[count] = buf[0..len];
        } else |_| if (std.fs.path.isAbsolute(arg) or cwd_len == 0) {
            @memcpy(buf[0..arg.len], arg);
            out[count] = buf[0..arg.len];
        } else {
            out[count] = paths.join(cwd_buf[0..cwd_len], arg, buf) orelse continue;
        }
        count += 1;
    }
    return out[0..count];
}

/// When another nanoview runs and takes `args`, true: this process is
/// done. False when none runs or it cannot be reached; start normally.
pub fn hand_over(io: std.Io, args: []const []const u8) bool {
    var storage: [paths_max][paths.path_max]u8 = undefined;
    var resolved: [paths_max][]const u8 = undefined;
    const files = absolute(io, args, &storage, &resolved);
    var out: [message_bytes_max]u8 = undefined;
    return platform.hand(encode(files, &out));
}

const testing = std.testing;
test "a message frames absolute paths and an empty one asks only to come forward" {
    var out: [message_bytes_max]u8 = undefined;
    const sent = encode(&.{ "/a/b.png", "/bad\nname.png", "/c d.jpg" }, &out);
    try testing.expectEqualStrings("/a/b.png\n/c d.jpg\n\n", sent);
    var m: Message = .{};
    @memcpy(m.buf[0 .. sent.len - 1], sent[0 .. sent.len - 1]);
    m.len = sent.len - 1;
    try testing.expect(!m.complete());
    m.len = sent.len;
    m.buf[sent.len - 1] = '\n';
    try testing.expect(m.complete());
    var got: [paths_max][]const u8 = undefined;
    const files = m.files(&got);
    try testing.expectEqual(@as(usize, 2), files.len);
    try testing.expectEqualStrings("/c d.jpg", files[1]);

    const raise = encode(&.{}, &out);
    try testing.expectEqualStrings("\n", raise);
    @memcpy(m.buf[0..1], raise);
    m.len = 1;
    try testing.expect(m.complete());
    try testing.expectEqual(@as(usize, 0), m.files(&got).len);
}

test "a message holds at most paths_max paths" {
    var many: [paths_max + 4][]const u8 = undefined;
    for (&many) |*p| p.* = "/x.png";
    var out: [message_bytes_max]u8 = undefined;
    const sent = encode(&many, &out);
    try testing.expectEqual(@as(usize, paths_max * 7 + 1), sent.len);
}

test "relative arguments become absolute against the working directory" {
    var storage: [paths_max][paths.path_max]u8 = undefined;
    var out: [paths_max][]const u8 = undefined;
    const got = absolute(testing.io, &.{ "build.zig", "missing-file.png" }, &storage, &out);
    try testing.expectEqual(@as(usize, 2), got.len);
    for (got) |p| try testing.expect(std.fs.path.isAbsolute(p));
    try testing.expect(std.mem.endsWith(u8, got[1], "missing-file.png"));
}
