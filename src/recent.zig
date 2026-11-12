//! Recently opened files: one absolute path per line, newest first, in a
//! file under the per-user state directory. Fixed buffers only: writes
//! happen after startup.
const std = @import("std");
const builtin = @import("builtin");
const paths = @import("paths.zig");
const assert = std.debug.assert;

pub const recent_max: u32 = 10;
pub const file_name = "recent";
const temp_name = "recent.tmp";
/// Each path and its newline.
pub const file_size_max: u32 = recent_max * (paths.path_max + 1);

pub const List = struct {
    bytes: [recent_max][paths.path_max]u8 = undefined,
    lens: [recent_max]u16 = undefined,
    count: u32 = 0,

    /// Newest first.
    pub fn get(l: *const List, i: u32) ?[]const u8 {
        assert(l.count <= recent_max);
        if (i >= l.count) return null;
        const result = l.bytes[i][0..l.lens[i]];
        assert(result.len > 0);
        return result;
    }

    pub fn clear(l: *List) void {
        l.count = 0;
        assert(l.get(0) == null);
    }

    /// To the front; an existing copy moves, the oldest drops when full.
    pub fn insert(l: *List, path: []const u8) void {
        assert(path.len > 0 and path.len <= paths.path_max);
        const at = l.find(path) orelse @min(l.count, recent_max - 1);
        var i = at;
        while (i > 0) : (i -= 1) {
            @memcpy(l.bytes[i][0..l.lens[i - 1]], l.bytes[i - 1][0..l.lens[i - 1]]);
            l.lens[i] = l.lens[i - 1];
        }
        @memcpy(l.bytes[0][0..path.len], path);
        l.lens[0] = @intCast(path.len);
        l.count = @max(l.count, at + 1);
        assert(std.mem.eql(u8, l.get(0).?, path));
        assert(l.count <= recent_max);
    }

    fn find(l: *const List, path: []const u8) ?u32 {
        for (0..l.count) |i| {
            if (std.mem.eql(u8, l.get(@intCast(i)).?, path)) return @intCast(i);
        }
        return null;
    }

    /// File order; a line that is not an absolute path, or repeats one,
    /// is skipped.
    pub fn parse(l: *List, content: []const u8) void {
        l.clear();
        var lines = std.mem.splitScalar(u8, content, '\n');
        for (0..file_size_max + 1) |_| {
            const raw = lines.next() orelse break;
            if (l.count == recent_max) break;
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0 or line.len > paths.path_max) continue;
            if (!std.fs.path.isAbsolute(line) or l.find(line) != null) continue;
            @memcpy(l.bytes[l.count][0..line.len], line);
            l.lens[l.count] = @intCast(line.len);
            l.count += 1;
        }
        assert(l.count <= recent_max);
    }

    pub fn write(l: *const List, out: *[file_size_max]u8) []const u8 {
        var len: usize = 0;
        for (0..l.count) |i| {
            const path = l.get(@intCast(i)).?;
            @memcpy(out[len..][0..path.len], path);
            out[len + path.len] = '\n';
            len += path.len + 1;
        }
        assert(len <= file_size_max);
        return out[0..len];
    }
};

/// Called once at startup. The state convention per system, beside the
/// config directory's.
pub fn directory(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (builtin.os.tag == .windows) {
        const base = env.get("LOCALAPPDATA") orelse return error.NoStateDirectory;
        return std.fs.path.join(gpa, &.{ base, "nanoview" });
    }
    if (builtin.os.tag == .macos) {
        const home = env.get("HOME") orelse return error.NoStateDirectory;
        return std.fs.path.join(gpa, &.{ home, "Library", "Application Support", "nanoview" });
    }
    if (env.get("XDG_STATE_HOME")) |base| {
        if (base.len > 0 and std.fs.path.isAbsolute(base))
            return std.fs.path.join(gpa, &.{ base, "nanoview" });
    }
    const home = env.get("HOME") orelse return error.NoStateDirectory;
    return std.fs.path.join(gpa, &.{ home, ".local", "state", "nanoview" });
}

/// A missing file is an empty list.
pub fn load(io: std.Io, dir_path: []const u8, list: *List) !void {
    assert(dir_path.len > 0);
    var path_buf: [paths.path_max]u8 = undefined;
    const path = paths.join(dir_path, file_name, &path_buf) orelse return error.NameTooLong;
    var bytes: [file_size_max]u8 = undefined;
    list.clear();
    const content = paths.read_file(io, path, &bytes) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    list.parse(content);
}

/// Through a temporary file and a rename, so a failed write leaves the
/// last list whole. Creates the directory the first time.
pub fn save(io: std.Io, dir_path: []const u8, list: *const List) !void {
    assert(dir_path.len > 0);
    var bytes: [file_size_max]u8 = undefined;
    const content = list.write(&bytes);
    try std.Io.Dir.cwd().createDirPath(io, dir_path);
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = temp_name, .data = content });
    try dir.rename(temp_name, dir, file_name, io);
}

const testing = std.testing;

fn absolute(buf: []u8, i: usize) []const u8 {
    const prefix = if (builtin.os.tag == .windows) "C:\\p" else "/p";
    return std.fmt.bufPrint(buf, "{s}{d}", .{ prefix, i }) catch unreachable;
}

test "insert puts the newest first, moves a repeat and drops the oldest" {
    const list = try testing.allocator.create(List);
    defer testing.allocator.destroy(list);
    list.* = .{};
    var buf: [16]u8 = undefined;
    for (0..recent_max + 2) |i| list.insert(absolute(&buf, i));
    try testing.expectEqual(recent_max, list.count);
    try testing.expectEqualStrings(absolute(&buf, recent_max + 1), list.get(0).?);
    try testing.expectEqualStrings(absolute(&buf, 2), list.get(recent_max - 1).?);
    list.insert(absolute(&buf, 5));
    try testing.expectEqual(recent_max, list.count);
    try testing.expectEqualStrings(absolute(&buf, 5), list.get(0).?);
    try testing.expectEqualStrings(absolute(&buf, recent_max + 1), list.get(1).?);
    for (1..recent_max) |i| {
        try testing.expect(!std.mem.eql(u8, list.get(@intCast(i)).?, absolute(&buf, 5)));
    }
    try testing.expect(list.get(recent_max) == null);
    list.clear();
    try testing.expect(list.get(0) == null);
}

test "parse keeps order and skips relative, empty and repeated lines" {
    const list = try testing.allocator.create(List);
    defer testing.allocator.destroy(list);
    list.* = .{};
    var a: [16]u8 = undefined;
    var b: [16]u8 = undefined;
    var text: [64]u8 = undefined;
    const pa = absolute(&a, 1);
    const pb = absolute(&b, 2);
    const content = try std.fmt.bufPrint(&text, "{s}\r\n\nrelative.png\n{s}\n{s}\n", .{
        pa, pb, pa,
    });
    list.parse(content);
    try testing.expectEqual(@as(u32, 2), list.count);
    try testing.expectEqualStrings(pa, list.get(0).?);
    try testing.expectEqualStrings(pb, list.get(1).?);
}

test "the list survives a save and load through a new directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [paths.path_max]u8 = undefined;
    const len = try tmp.dir.realPathFile(testing.io, ".", &root);
    var dir_buf: [paths.path_max]u8 = undefined;
    const dir_path = paths.join(root[0..len], "state", &dir_buf).?;
    const lists = try testing.allocator.alloc(List, 2);
    defer testing.allocator.free(lists);
    lists[0] = .{};
    try load(testing.io, dir_path, &lists[0]);
    try testing.expectEqual(@as(u32, 0), lists[0].count);
    var buf: [16]u8 = undefined;
    for (0..3) |i| lists[0].insert(absolute(&buf, i));
    try save(testing.io, dir_path, &lists[0]);
    lists[1] = .{};
    try load(testing.io, dir_path, &lists[1]);
    try testing.expectEqual(@as(u32, 3), lists[1].count);
    for (0..3) |i| try testing.expectEqualStrings(lists[0].get(@intCast(i)).?, lists[1].get(
        @intCast(i),
    ).?);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "state/" ++
        temp_name, .{}));
}
