const std = @import("std");
const linux = std.os.linux;
const shell = @import("shell.zig");
const paths = @import("paths.zig");
const assert = std.debug.assert;
const walk_max: u32 = paths.path_max;
const at_cwd: i32 = linux.AT.FDCWD;
const Tm = extern struct {
    sec: i32,
    min: i32,
    hour: i32,
    day: i32,
    month: i32,
    year: i32,
    weekday: i32,
    yearday: i32,
    dst: i32,
    offset: i64,
    zone: ?[*:0]const u8,
};
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn time(out: ?*i64) i64;
extern "c" fn localtime_r(value: *const i64, out: *Tm) ?*Tm;

fn env(name: [*:0]const u8) ?[]const u8 {
    const value = getenv(name) orelse return null;
    for (0..paths.path_max) |i| {
        if (value[i] == 0) return value[0..i];
    }
    return null;
}

fn z(path: []const u8, out: *[paths.path_max + 1]u8) ?[:0]const u8 {
    if (path.len > paths.path_max or std.mem.indexOfScalar(u8, path, 0) != null) return null;
    @memcpy(out[0..path.len], path);
    out[path.len] = 0;
    return out[0..path.len :0];
}

fn stat(fd: i32, path: [*:0]const u8, flags: u32) ?linux.Statx {
    var result: linux.Statx = undefined;
    var mask: linux.STATX = .BASIC_STATS;
    mask.MNT_ID = true;
    if (linux.statx(fd, path, flags, mask, &result) != 0) return null;
    if (!result.mask.TYPE or !result.mask.MODE or !result.mask.UID) return null;
    return result;
}

fn same_device(a: linux.Statx, b: linux.Statx) bool {
    return a.dev_major == b.dev_major and a.dev_minor == b.dev_minor;
}

fn private_dir(parent: i32, name: [*:0]const u8, uid: u32) ?i32 {
    _ = linux.mkdirat(parent, name, 0o700);
    const raw = linux.openat(parent, name, .{
        .DIRECTORY = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0);
    if (linux.errno(raw) != .SUCCESS) return null;
    const fd: i32 = @intCast(raw);
    const s = stat(fd, "", linux.AT.EMPTY_PATH) orelse {
        _ = linux.close(fd);
        return null;
    };
    // No mode test: the specification asks for none here, and FAT, exFAT
    // and NTFS mounts show every directory as 0755 whatever was asked.
    if (s.uid != uid) {
        _ = linux.close(fd);
        return null;
    }
    return fd;
}

fn mount_point(path: []const u8, source: linux.Statx, out: *[paths.path_max]u8) ?[]const u8 {
    var current = std.fs.path.dirname(path) orelse return null;
    for (0..walk_max) |_| {
        var buf: [paths.path_max + 1]u8 = undefined;
        const p = z(current, &buf) orelse return null;
        const here = stat(at_cwd, p, 0) orelse return null;
        if (!same_device(source, here)) return null;
        const parent = std.fs.path.dirname(current) orelse current;
        if (std.mem.eql(u8, parent, current)) break;
        const above = stat(at_cwd, (z(parent, &buf) orelse return null), 0) orelse return null;
        if (!same_device(here, above) or here.mnt_id != above.mnt_id) break;
        current = parent;
    } else return null;
    @memcpy(out[0..current.len], current);
    return out[0..current.len];
}

fn local_date() ?shell.Date {
    const now = time(null);
    var tm: Tm = undefined;
    if (now == -1 or localtime_r(&now, &tm) == null or tm.year < -1900) return null;
    return .{
        .year = @intCast(tm.year + 1900),
        .month = @intCast(tm.month + 1),
        .day = @intCast(tm.day),
        .hour = @intCast(tm.hour),
        .minute = @intCast(tm.min),
        .second = @intCast(tm.sec),
    };
}

fn home_root(io: std.Io, root: []const u8, uid: u32) ?i32 {
    const parent = std.fs.path.dirname(root) orelse return null;
    std.Io.Dir.cwd().createDirPath(io, parent) catch return null;
    var root_z: [paths.path_max + 1]u8 = undefined;
    return private_dir(at_cwd, z(root, &root_z) orelse return null, uid);
}

/// Returns where the file went, for Restore: `<trash>/files/<name>`.
pub fn trash(io: std.Io, path: []const u8, out: *[paths.path_max]u8) ?[]const u8 {
    if (path.len == 0 or path[0] != '/') return null;
    var path_z: [paths.path_max + 1]u8 = undefined;
    const source_z = z(path, &path_z) orelse return null;
    const source = stat(at_cwd, source_z, linux.AT.SYMLINK_NOFOLLOW) orelse return null;
    const uid = linux.getuid();
    var root_buf: [paths.path_max]u8 = undefined;
    if (shell.home_trash(env("XDG_DATA_HOME"), env("HOME"), &root_buf)) |root| {
        if (home_root(io, root, uid)) |fd| {
            defer _ = linux.close(fd);
            const dest = stat(fd, "", linux.AT.EMPTY_PATH) orelse return null;
            if (same_device(source, dest)) return move(fd, root, source_z, path, uid, out);
        }
    }
    var top_buf: [paths.path_max]u8 = undefined;
    const top = mount_point(path, source, &top_buf) orelse return null;
    const relative = path[top.len + @intFromBool(!std.mem.eql(u8, top, "/")) ..];
    return mount_move(top, source_z, relative, uid, out);
}

fn mount_move(
    top: []const u8,
    source: [:0]const u8,
    relative: []const u8,
    uid: u32,
    out: *[paths.path_max]u8,
) ?[]const u8 {
    var shared_buf: [paths.path_max + 1]u8 = undefined;
    const shared = std.mem.printSentinel(&shared_buf, "{s}/.Trash", .{top}, 0) catch return null;
    const raw = linux.openat(at_cwd, shared, .{
        .DIRECTORY = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0);
    if (linux.errno(raw) == .SUCCESS) {
        const shared_fd: i32 = @intCast(raw);
        defer _ = linux.close(shared_fd);
        const s = stat(shared_fd, "", linux.AT.EMPTY_PATH) orelse return null;
        if (s.mode & 0o1000 != 0) {
            var uid_buf: [16]u8 = undefined;
            const name = std.mem.printSentinel(&uid_buf, "{d}", .{uid}, 0) catch return null;
            var user_buf: [paths.path_max]u8 = undefined;
            const user_root = std.fmt.bufPrint(&user_buf, "{s}/{s}", .{ shared, name }) catch
                return null;
            if (private_dir(shared_fd, name, uid)) |fd| {
                defer _ = linux.close(fd);
                if (move(fd, user_root, source, relative, uid, out)) |where| return where;
            }
        }
    }
    var root_buf: [paths.path_max]u8 = undefined;
    const root = shell.mount_trash(top, uid, false, &root_buf) orelse return null;
    var root_z: [paths.path_max + 1]u8 = undefined;
    const fd = private_dir(at_cwd, (z(root, &root_z) orelse return null), uid) orelse return null;
    defer _ = linux.close(fd);
    return move(fd, root, source, relative, uid, out);
}

/// `root` is the trash directory open as `root_fd`.
fn move(
    root_fd: i32,
    root: []const u8,
    source: [:0]const u8,
    original: []const u8,
    uid: u32,
    out: *[paths.path_max]u8,
) ?[]const u8 {
    assert(original.len > 0);
    const files = private_dir(root_fd, "files", uid) orelse return null;
    defer _ = linux.close(files);
    const info = private_dir(root_fd, "info", uid) orelse return null;
    defer _ = linux.close(info);
    var text_buf: [shell.info_max]u8 = undefined;
    const text = shell.trash_info(original, local_date() orelse return null, &text_buf) orelse
        return null;
    for (0..shell.attempts_max) |attempt| {
        var name_buf: [paths.path_max]u8 = undefined;
        const name = shell.unique_name(
            std.fs.path.basename(source),
            @intCast(attempt),
            &name_buf,
        ) orelse return null;
        // Checked first so a move never happens that Restore could not find.
        const location = std.fmt.bufPrint(out, "{s}/files/{s}", .{ root, name }) catch
            return null;
        var name_z: [paths.path_max + 1]u8 = undefined;
        const dest = z(name, &name_z) orelse return null;
        // Reserve metadata first; neither existing files nor metadata are replaced.
        var info_buf: [paths.path_max + 16]u8 = undefined;
        const metadata = std.mem.printSentinel(
            &info_buf,
            "{s}.trashinfo",
            .{name},
            0,
        ) catch return null;
        const raw = linux.openat(info, metadata, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .EXCL = true,
            .CLOEXEC = true,
        }, 0o600);
        if (linux.errno(raw) == .EXIST) continue;
        if (linux.errno(raw) != .SUCCESS) return null;
        const fd: i32 = @intCast(raw);
        const written = linux.write(fd, text.ptr, text.len);
        const synced = if (written == text.len) linux.fsync(fd) else 1;
        const closed = linux.close(fd);
        const result = if (synced == 0 and closed == 0)
            rename_no_replace(source, files, dest)
        else
            1;
        if (result == 0) return location;
        _ = linux.unlinkat(info, metadata, 0);
        if (linux.errno(result) != .EXIST) return null;
    }
    return null;
}

/// Called once a trashed file is back: its `<trash>/info/<name>.trashinfo`
/// goes too, so the trash does not list a file that is not there.
pub fn forget(location: []const u8) void {
    assert(location.len > 0 and location[0] == '/');
    const files = std.fs.path.dirname(location) orelse return;
    const root = std.fs.path.dirname(files) orelse return;
    var info_buf: [paths.path_max + 1]u8 = undefined;
    const info = std.mem.printSentinel(&info_buf, "{s}/info/{s}.trashinfo", .{
        root, std.fs.path.basename(location),
    }, 0) catch return;
    // A leftover entry only shows as a broken item in the file manager's
    // trash; the picture itself is back, which is what the user asked for.
    _ = linux.unlinkat(at_cwd, info, 0);
}

/// NFS and FUSE without rename2 refuse the no-replace flag (EINVAL). The
/// plain rename is safe there once the name is seen free: `files` is the
/// user's own, and the name is reserved by its `.trashinfo`.
fn rename_no_replace(source: [:0]const u8, files: i32, dest: [:0]const u8) usize {
    const result = linux.renameat2(at_cwd, source, files, dest, .{ .NOREPLACE = true });
    if (linux.errno(result) != .INVAL) return result;
    const taken = linux.faccessat(files, dest, linux.F_OK, linux.AT.SYMLINK_NOFOLLOW);
    if (linux.errno(taken) != .NOENT) return result;
    return linux.renameat(at_cwd, source, files, dest);
}

pub fn reveal(path: []const u8) bool {
    return @import("shell_dbus.zig").reveal(path);
}

test "trash move preserves collisions and writes recoverable metadata" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [paths.path_max]u8 = undefined;
    const dir_len = try tmp.dir.realPathFile(io, ".", &dir_buf);
    var root_buf: [paths.path_max]u8 = undefined;
    const root = paths.join(dir_buf[0..dir_len], "Trash", &root_buf).?;
    const fd = home_root(io, root, linux.getuid()).?;
    defer _ = linux.close(fd);
    try tmp.dir.writeFile(io, .{ .sub_path = "a b.png", .data = "picture" });
    var source_buf: [paths.path_max]u8 = undefined;
    const source = paths.join(dir_buf[0..dir_len], "a b.png", &source_buf).?;
    var source_z: [paths.path_max + 1]u8 = undefined;
    const p = z(source, &source_z).?;
    var out: [paths.path_max]u8 = undefined;
    try t.expect(move(fd, root, p, source, linux.getuid(), &out) != null);
    try tmp.dir.writeFile(io, .{ .sub_path = "a b.png", .data = "second" });
    const location = move(fd, root, p, source, linux.getuid(), &out).?;
    var want_buf: [paths.path_max]u8 = undefined;
    const want = try std.fmt.bufPrint(&want_buf, "{s}/files/a b.png.1", .{root});
    try t.expectEqualStrings(want, location);
    var data: [shell.info_max]u8 = undefined;
    const first = try tmp.dir.openFile(io, "Trash/files/a b.png", .{});
    defer first.close(io);
    const n = try first.readPositionalAll(io, &data, 0);
    try t.expectEqualStrings("picture", data[0..n]);
    const second = try tmp.dir.openFile(io, "Trash/files/a b.png.1", .{});
    defer second.close(io);
    const n2 = try second.readPositionalAll(io, &data, 0);
    try t.expectEqualStrings("second", data[0..n2]);
    const metadata = try tmp.dir.openFile(io, "Trash/info/a b.png.1.trashinfo", .{});
    defer metadata.close(io);
    const n3 = try metadata.readPositionalAll(io, &data, 0);
    try t.expect(std.mem.indexOf(u8, data[0..n3], "/a%20b.png\nDeletionDate=") != null);
    try t.expect(move(fd, root, p, source, linux.getuid(), &out) == null);
}

test "restore moves a trashed file back, forgets it, and never replaces a file" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [paths.path_max]u8 = undefined;
    const dir_len = try tmp.dir.realPathFile(io, ".", &dir_buf);
    var root_buf: [paths.path_max]u8 = undefined;
    const root = paths.join(dir_buf[0..dir_len], "Trash", &root_buf).?;
    const fd = home_root(io, root, linux.getuid()).?;
    defer _ = linux.close(fd);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.png", .data = "picture" });
    var source_buf: [paths.path_max]u8 = undefined;
    const source = paths.join(dir_buf[0..dir_len], "a.png", &source_buf).?;
    var source_z: [paths.path_max + 1]u8 = undefined;
    var out: [paths.path_max]u8 = undefined;
    const location = move(fd, root, z(source, &source_z).?, source, linux.getuid(), &out).?;
    try tmp.dir.writeFile(io, .{ .sub_path = "a.png", .data = "new" });
    try t.expectError(error.Exists, shell.restore(io, location, source));
    try tmp.dir.deleteFile(io, "a.png");
    try shell.restore(io, location, source);
    var data: [16]u8 = undefined;
    try t.expectEqualStrings("picture", try tmp.dir.readFile(io, "a.png", &data));
    try t.expectError(error.FileNotFound, tmp.dir.access(io, "Trash/info/a.png.trashinfo", .{}));
    try t.expectError(error.Gone, shell.restore(io, location, source));
}
