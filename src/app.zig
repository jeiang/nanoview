//! The viewer's state and the commands that change it.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const folder_mod = @import("folder.zig");
const paths = @import("paths.zig");
const viewport_mod = @import("viewport.zig");
const orientation = @import("orientation.zig");
const sort_order = @import("sort_order.zig");
const assert = std.debug.assert;

pub const file_size_max: u32 = 256 * 1024 * 1024;

pub const Status = enum { empty, shown, failed };

pub const State = struct {
    io: std.Io,
    gpa: std.mem.Allocator, // only for nanoui.dialog.open's result
    file_buffer: []u8, // file_size_max bytes, allocated once in main
    bytes: []const u8 = "", // the current file, inside file_buffer
    window: ?*nanoui.Window = null, // null under ui.Tester
    status: Status = .empty,
    path_buf: [paths.path_max]u8 = undefined,
    path_len: u32 = 0,
    dir_buf: [paths.path_max]u8 = undefined,
    dir_len: u32 = 0,
    folder: folder_mod.Folder = .{},
    index: ?u32 = null, // position in folder, null when the file is not listed
    generation: u32 = 0, // bumped per load: the picture's nanoui key
    viewport: viewport_mod.Viewport = .{ .image_w = 1, .image_h = 1 },
    viewport_generation: u32 = 0, // generation the viewport was made for
    base: orientation.Upright = .{ .raw_w = 1, .raw_h = 1, .turns = 0 },
    turns_user: u2 = 0,
    info_shown: bool = false,
    drag_last: ?ui.Point = null,

    pub fn init(s: *State, io: std.Io, gpa: std.mem.Allocator, file_buffer: []u8) void {
        assert(file_buffer.len == file_size_max);
        s.* = .{ .io = io, .gpa = gpa, .file_buffer = file_buffer };
        assert(s.status == .empty and s.folder.count == 0);
    }

    pub fn path(s: *const State) []const u8 {
        assert(s.path_len <= paths.path_max);
        return s.path_buf[0..s.path_len];
    }

    pub fn dir(s: *const State) []const u8 {
        assert(s.dir_len > 0 and s.dir_len <= paths.path_max);
        return s.dir_buf[0..s.dir_len];
    }

    pub fn basename(s: *const State) []const u8 {
        assert(s.path_len > 0);
        return std.fs.path.basename(s.path());
    }

    /// The single entry for an argument, the dialog, a drop and macOS open-file.
    pub fn open_path(s: *State, file_path: []const u8) void {
        assert(s.path_len <= paths.path_max);
        // No picture to name in a failure: an unusable path changes nothing.
        if (file_path.len == 0 or file_path.len > paths.path_max) return;
        // Absolute, so the parent folder and its `.DS_Store` can be found.
        var real_buf: [paths.path_max]u8 = undefined;
        const real = if (std.Io.Dir.cwd().realPathFile(s.io, file_path, &real_buf)) |len|
            real_buf[0..len]
        else |_|
            file_path;
        @memcpy(s.path_buf[0..real.len], real);
        s.path_len = @intCast(real.len);
        const parent = std.fs.path.dirname(s.path()) orelse ".";
        @memcpy(s.dir_buf[0..parent.len], parent);
        s.dir_len = @intCast(parent.len);
        // A folder that cannot be listed still shows the file, alone.
        s.folder.scan(s.io, s.dir(), sort_order.detect(s.io, s.dir())) catch s.folder.reset();
        s.index = s.folder.find(s.basename());
        s.load();
        assert(s.status != .empty);
    }

    fn fail(s: *State) void {
        s.generation +%= 1;
        s.bytes = "";
        s.status = .failed;
        assert(s.status == .failed);
    }

    pub fn show_index(s: *State, i: u32) void {
        assert(i < s.folder.count);
        const joined = paths.join(s.dir(), s.folder.name(i), &s.path_buf) orelse {
            s.fail();
            return;
        };
        s.path_len = @intCast(joined.len);
        s.index = i;
        s.load();
        assert(s.status != .empty);
    }

    pub fn load(s: *State) void {
        assert(s.path_len > 0);
        s.generation +%= 1;
        s.turns_user = 0;
        s.drag_last = null;
        if (paths.read_file(s.io, s.path(), s.file_buffer)) |bytes| {
            s.bytes = bytes;
            s.status = .shown;
        } else |_| {
            s.bytes = "";
            s.status = .failed;
        }
        if (s.window) |w| {
            w.setTitle(s.basename());
            w.redraw();
        }
        assert(s.status != .empty);
    }

    /// `delta` is +1 or -1; wraps around the folder.
    pub fn step(s: *State, delta: i32) void {
        assert(delta == 1 or delta == -1);
        const count = s.folder.count;
        if (count == 0) return;
        const from: u32 = s.index orelse if (delta > 0) count - 1 else 0;
        assert(from < count);
        const next = if (delta > 0) (from + 1) % count else (from + count - 1) % count;
        s.show_index(next);
    }

    pub fn open_dialog(s: *State) void {
        assert(s.path_len <= paths.path_max);
        const result = nanoui.dialog.open(s.gpa, .{ .extensions = folder_mod.extensions });
        const picked = (result catch return) orelse return;
        var buf: [paths.path_max]u8 = undefined;
        var len: usize = 0;
        if (picked.len > 0 and picked[0].len <= paths.path_max) {
            len = picked[0].len;
            @memcpy(buf[0..len], picked[0]);
        }
        for (picked) |p| s.gpa.free(p);
        s.gpa.free(picked);
        if (len > 0) s.open_path(buf[0..len]);
    }

    /// No confirmation: the trash is recoverable.
    pub fn trash(s: *State) void {
        if (s.status == .empty) return;
        assert(s.path_len > 0);
        if (!nanoui.shell.trash(s.path())) return;
        if (s.index) |i| {
            s.folder.remove(i);
            if (s.folder.count == 0) {
                s.clear();
            } else {
                s.show_index(@min(i, s.folder.count - 1));
            }
        } else if (s.folder.count > 0) {
            s.step(1);
        } else {
            s.clear();
        }
        assert(s.status == .empty or s.path_len > 0);
    }

    /// Back to the empty window.
    fn clear(s: *State) void {
        s.status = .empty;
        s.bytes = "";
        s.index = null;
        s.path_len = 0;
        s.generation +%= 1;
        if (s.window) |w| {
            w.setTitle("nanoview");
            w.redraw();
        }
        assert(s.status == .empty);
    }

    pub fn reveal(s: *const State) void {
        if (s.status == .empty) return;
        assert(s.path_len > 0);
        nanoui.shell.showInFolder(s.path());
    }

    pub fn copy_path(s: *const State) void {
        if (s.status == .empty) return;
        assert(s.path_len > 0);
        nanoui.clipboard.writeText(s.path());
    }

    pub fn on_open_files(ctx: *anyopaque, files: []const []const u8) void {
        const s: *State = @ptrCast(@alignCast(ctx));
        assert(s.path_len <= paths.path_max);
        if (files.len > 0) s.open_path(files[0]);
    }

    pub fn picture_key(s: *const State, buf: *[16]u8) []const u8 {
        const key = std.fmt.bufPrint(buf, "{d}", .{s.generation}) catch unreachable;
        assert(key.len > 0);
        return key;
    }
};
