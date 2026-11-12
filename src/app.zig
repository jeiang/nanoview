//! The viewer's state and the commands that change it.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const folder_mod = @import("folder.zig");
const paths = @import("paths.zig");
const viewport_mod = @import("viewport.zig");
const orientation = @import("orientation.zig");
const sort_order = @import("sort_order.zig");
const preload_mod = @import("preload.zig");
const decode = @import("decode.zig");
const builtin = @import("builtin");
const settings_mod = @import("settings.zig");
const metadata_mod = @import("metadata.zig");
const shell = @import("shell.zig");
const keymap_mod = @import("keymap.zig");
const recent_mod = @import("recent.zig");
const fileops = @import("fileops.zig");
const assert = std.debug.assert;

pub const file_size_max = decode.file_size_max;
/// Room for the largest picture at full size.
pub const current_pixels_max: u32 = decode.pixels_max * 4;
pub const message_len_max: u32 = 512;
pub const title_len_max: u32 = 512;
/// Room past the longest name, so a name too long gets a message rather
/// than keys that do nothing.
pub const rename_bytes_max: u32 = folder_mod.name_len_max * 2;
/// Clipboard text longer than this is not a list of paths.
pub const paste_text_max: usize = 64 * 1024;
pub const paste_lines_max: u32 = 256;
/// The title and name of a picture pasted from the clipboard.
pub const clipboard_name = "Clipboard";

/// Where paste reads: the system clipboard, or a test's stand-in. Each
/// result is allocated with the given allocator; the caller frees it.
pub const Clipboard = struct {
    read_files: *const fn (std.mem.Allocator) anyerror!?[][]u8 = system_files,
    read_text: *const fn (std.mem.Allocator) anyerror!?[]u8 = system_text,
    read_image: *const fn (std.mem.Allocator) anyerror!?[]u8 = system_image,

    fn system_files(gpa: std.mem.Allocator) anyerror!?[][]u8 {
        return nanoui.clipboard.readFiles(gpa);
    }

    fn system_text(gpa: std.mem.Allocator) anyerror!?[]u8 {
        return nanoui.clipboard.readText(gpa);
    }

    fn system_image(gpa: std.mem.Allocator) anyerror!?[]u8 {
        return nanoui.clipboard.readImage(gpa);
    }
};

/// Pages for the large buffers. Debug builds fill `alloc` results with
/// 0xAA, which would commit every page (about 1 GiB) at startup; the raw
/// call leaves them untouched until used.
pub fn alloc_pages(len: usize) ![]u8 {
    if (len == 0) return &.{};
    const ptr = std.heap.page_allocator.rawAlloc(len, .of(u8), @returnAddress()) orelse
        return error.OutOfMemory;
    return ptr[0..len];
}

pub fn free_pages(memory: []u8) void {
    if (memory.len == 0) return;
    std.heap.page_allocator.rawFree(memory, .of(u8), @returnAddress());
}

pub const Status = enum { empty, shown, failed };

pub const Source = union(enum) {
    none,
    encoded: []const u8, // in file_buffer, or in a preload slot (Linux, Windows)
    pixels: Pixels, // in a preload slot (macOS)

    pub const Pixels = struct {
        bgra: []const u8,
        width: u32,
        height: u32,
        native_w: u32,
        native_h: u32,
    };
};

pub const State = struct {
    settings: settings_mod.Settings = .{},
    io: std.Io,
    gpa: std.mem.Allocator, // only for nanoui's dialog and clipboard results, freed at once
    file_buffer: []u8, // file_size_max bytes, allocated once in main
    current_pixels: []u8, // current_pixels_max bytes, allocated once at startup
    source: Source = .none,
    promote_failed: bool = false,
    promoted: bool = false, // the source was read again at full size
    window: ?*nanoui.Window = null, // null under ui.Tester
    status: Status = .empty,
    path_buf: [paths.path_max]u8 = undefined,
    path_len: u32 = 0,
    dir_buf: [paths.path_max]u8 = undefined,
    dir_len: u32 = 0,
    folder: folder_mod.Folder = .{},
    preload: preload_mod.Preload = undefined,
    index: ?u32 = null, // position in folder, null when the file is not listed
    generation: u32 = 0, // bumped per load: the picture's nanoui key
    viewport: viewport_mod.Viewport = .{ .image_w = 1, .image_h = 1 },
    viewport_generation: u32 = 0, // generation the viewport was made for
    base: orientation.Upright = .{ .raw_w = 1, .raw_h = 1, .turns = 0 },
    turns_user: u2 = 0,
    mirror: bool = false,
    flip: bool = false,
    info_shown: bool = false,
    drag_last: ?ui.Point = null,
    message_buf: [message_len_max]u8 = undefined,
    message_len: u32 = 0,
    message_until: ?f64 = null, // on the view's clock; null until a frame shows it
    folder_mtime: i128 = 0,
    selection: folder_mod.Folder = .{},
    selection_only: bool = false,
    random_state: u64 = 1,
    slideshow_running: bool = false,
    slideshow_at: ?f64 = null,
    trash_pending: bool = false,
    metadata: metadata_mod.Metadata = .{},
    keymap: keymap_mod.Keymap = .{},
    title_buf: [title_len_max]u8 = undefined,
    title_len: u32 = 0,
    window_fitted: bool = false, // the window took a picture's size since launch
    sort_fallback_told: bool = false,
    recent_list: recent_mod.List = .{},
    recent_dir_buf: [paths.path_max]u8 = undefined,
    recent_dir_len: u32 = 0, // 0: the list stays in memory
    recent_failed: bool = false,
    rename_open: bool = false,
    rename_focused: bool = false, // the field had the keyboard last frame
    rename_storage: [rename_bytes_max]u8 = undefined,
    rename_buffer: ui.TextBuffer = .{},
    trashed: fileops.TrashStack = .{},
    clipboard: Clipboard = .{},

    /// The buffers are allocated once by the caller and never freed while
    /// the state lives.
    pub fn init(
        s: *State,
        io: std.Io,
        gpa: std.mem.Allocator,
        file_buffer: []u8,
        pool: []u8,
        scratch: []u8,
        current_pixels: []u8,
    ) void {
        assert(file_buffer.len == file_size_max);
        assert(current_pixels.len == current_pixels_max);
        folder_mod.init_extensions();
        s.* = .{
            .io = io,
            .gpa = gpa,
            .file_buffer = file_buffer,
            .current_pixels = current_pixels,
            .keymap = .defaults(),
        };
        s.rename_buffer = .initFixed(&s.rename_storage);
        s.preload.init(io, &s.folder, pool, scratch);
        s.random_state = @truncate(@as(u96, @bitCast(std.Io.Clock.real.now(io).nanoseconds)));
        if (s.random_state == 0) s.random_state = 1;
        assert(s.status == .empty and s.folder.count == 0);
    }

    /// Called once, before the window opens. notify starts its timer on the first frame.
    pub fn load_settings(s: *State, directory: []const u8) void {
        const problem = settings_mod.load(s.io, directory, &s.settings, &s.keymap) catch |err| {
            s.notify("settings.conf: {s}", .{@errorName(err)});
            return;
        };
        const p = problem orelse return;
        if (p.line == 0) {
            s.notify("settings.conf: {s}", .{p.reason.text()});
        } else {
            s.notify("settings.conf line {d}: {s}", .{ p.line, p.reason.text() });
        }
    }

    /// Called once at startup, after the settings: `recent = false` reads nothing.
    pub fn load_recent(s: *State, directory: []const u8) void {
        assert(directory.len > 0);
        if (!s.settings.recent) return;
        if (directory.len > paths.path_max) {
            s.notify("Recent files: directory name too long", .{});
            return;
        }
        @memcpy(s.recent_dir_buf[0..directory.len], directory);
        s.recent_dir_len = @intCast(directory.len);
        recent_mod.load(s.io, directory, &s.recent_list) catch |err| {
            s.notify("Could not read recent files: {s}", .{@errorName(err)});
        };
    }

    /// Newest first; null past the end.
    pub fn recent(s: *const State, i: u32) ?[]const u8 {
        return s.recent_list.get(i);
    }

    pub fn recent_count(s: *const State) u32 {
        assert(s.recent_list.count <= recent_mod.recent_max);
        return s.recent_list.count;
    }

    pub fn clear_recent(s: *State) void {
        s.recent_list.clear();
        if (s.settings.recent) s.save_recent();
        assert(s.recent_count() == 0);
    }

    /// A file or folder the user opened.
    fn remember(s: *State, opened: []const u8) void {
        assert(opened.len > 0);
        if (!s.settings.recent) return;
        s.recent_list.insert(opened);
        s.save_recent();
    }

    fn save_recent(s: *State) void {
        if (s.recent_dir_len == 0) return;
        const directory = s.recent_dir_buf[0..s.recent_dir_len];
        recent_mod.save(s.io, directory, &s.recent_list) catch |err| {
            if (s.recent_failed) return;
            s.recent_failed = true;
            s.notify("Could not save recent files: {s}", .{@errorName(err)});
        };
    }

    pub fn path(s: *const State) []const u8 {
        assert(s.path_len <= paths.path_max);
        return s.path_buf[0..s.path_len];
    }

    pub fn dir(s: *const State) []const u8 {
        assert(s.dir_len > 0 and s.dir_len <= paths.path_max);
        return s.dir_buf[0..s.dir_len];
    }

    /// The file's name, or `clipboard_name` for a pasted picture.
    pub fn basename(s: *const State) []const u8 {
        assert(s.status != .empty or s.path_len > 0);
        if (s.path_len == 0) return clipboard_name;
        return std.fs.path.basename(s.path());
    }

    /// The single entry for an argument, the dialog, a drop and macOS open-file.
    pub fn open_path(s: *State, file_path: []const u8) void {
        s.open_paths(&.{file_path});
    }

    fn resolve(s: *State, input: []const u8, buf: *[paths.path_max]u8) ?[]const u8 {
        var decoded: [paths.path_max]u8 = undefined;
        const file = if (std.mem.startsWith(u8, input, "file://"))
            paths.from_file_url(input, &decoded) orelse return null
        else
            input;
        if (file.len == 0 or file.len > paths.path_max) return null;
        const len = std.Io.Dir.cwd().realPathFile(s.io, file, buf) catch {
            @memcpy(buf[0..file.len], file);
            return buf[0..file.len];
        };
        return buf[0..len];
    }

    pub fn open_paths(s: *State, files: []const []const u8) void {
        if (files.len == 0) return;
        var buf: [paths.path_max]u8 = undefined;
        const first = s.resolve(files[0], &buf) orelse {
            s.notify("Could not open path", .{});
            return;
        };
        const st = std.Io.Dir.cwd().statFile(s.io, first, .{}) catch null;
        const directory = if (st) |v| v.kind == .directory else false;
        const parent = if (directory) first else std.fs.path.dirname(first) orelse ".";
        @memcpy(s.dir_buf[0..parent.len], parent);
        s.dir_len = @intCast(parent.len);
        @memcpy(s.path_buf[0..first.len], first);
        s.path_len = @intCast(first.len);
        if (s.trash_pending) s.message_len = 0;
        s.trash_pending = false;
        s.slideshow_at = null;
        s.selection.reset();
        s.selection_only = !directory and files.len > 1;
        for (files[0..@min(files.len, folder_mod.entries_max)]) |file| {
            const real = s.resolve(file, &buf) orelse {
                s.selection_only = false;
                break;
            };
            if (!std.mem.eql(u8, std.fs.path.dirname(real) orelse ".", s.dir())) {
                s.selection_only = false;
                break;
            }
            if (s.selection.find(std.fs.path.basename(real)) == null)
                _ = s.selection.add(std.fs.path.basename(real));
        }
        s.rescan();
        if (directory) {
            if (s.folder.count > 0) s.show_index(0) else {
                s.clear();
                s.notify("No pictures in this folder", .{});
            }
        } else {
            s.index = s.folder.find(s.basename());
            s.load();
        }
        if (s.status == .shown) s.remember(if (directory) s.dir() else s.path());
    }

    fn directory_mtime(s: *State) i128 {
        const st = std.Io.Dir.cwd().statFile(s.io, s.dir(), .{}) catch return 0;
        return st.mtime.nanoseconds;
    }

    fn rescan(s: *State) void {
        const choice = s.settings.sort;
        if (choice == .date_created and !sort_order.has_date_created and !s.sort_fallback_told) {
            s.sort_fallback_told = true;
            s.notify("Sort by date created is macOS only: sorting by date modified", .{});
        }
        const order = sort_order.resolve(s.io, s.dir(), choice, s.settings.sort_descending);
        s.preload.lock();
        defer s.preload.unlock();
        s.folder.scan(s.io, s.dir(), order) catch {
            s.folder.reset();
            s.notify("Could not read folder", .{});
        };
        if (choice == .random) {
            s.random_state = folder_mod.xorshift(s.random_state);
            s.folder.shuffle(s.random_state);
        }
        if (s.selection_only) {
            var i = s.folder.count;
            while (i > 0) {
                i -= 1;
                if (s.selection.find(s.folder.name(i)) == null) s.folder.remove(i);
            }
        }
        s.folder_mtime = s.directory_mtime();
        s.preload.invalidate(s.dir());
    }

    /// Returns the old position when the displayed file disappeared.
    fn refresh(s: *State, force: bool) ?u32 {
        if (s.dir_len == 0) return null;
        if (!force and s.directory_mtime() == s.folder_mtime) return null;
        const old = s.index;
        s.rescan();
        s.index = if (s.path_len > 0) s.folder.find(s.basename()) else null;
        return if (s.index == null) old else null;
    }

    pub fn reload(s: *State) void {
        if (s.path_len == 0) return;
        _ = s.refresh(true);
        s.load();
    }

    fn fail(s: *State) void {
        s.generation +%= 1;
        s.source = .none;
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

    /// What every newly shown picture starts from.
    fn begin_picture(s: *State) void {
        s.generation +%= 1;
        s.turns_user = 0;
        s.mirror = false;
        s.flip = false;
        s.drag_last = null;
        s.promote_failed = false;
        s.promoted = false;
        s.slideshow_at = null;
        s.rename_open = false;
    }

    pub fn load(s: *State) void {
        assert(s.path_len > 0);
        s.begin_picture();
        s.metadata.load(s.io, s.path());
        // Without an index nothing preloads: `current` stays null.
        const slot = if (s.index) |i| s.preload.take(i) else null;
        if (slot) |n| {
            s.source = s.slot_source(n);
            s.status = .shown;
        } else {
            s.read_current();
        }
        // The view sets the title on its next frame.
        if (s.window) |w| w.redraw();
        assert(s.status != .empty);
    }

    fn slot_source(s: *const State, n: u32) Source {
        const bytes = s.preload.slot_bytes_of(n);
        const slot = s.preload.slots[n];
        if (!preload_mod.decoded or slot.encoded) return .{ .encoded = bytes };
        assert(bytes.len == slot.width * slot.height * 4);
        return .{ .pixels = .{
            .bgra = bytes,
            .width = slot.width,
            .height = slot.height,
            .native_w = slot.native_w,
            .native_h = slot.native_h,
        } };
    }

    /// The synchronous read into `file_buffer`.
    fn read_current(s: *State) void {
        assert(s.path_len > 0);
        if (paths.read_file(s.io, s.path(), s.file_buffer)) |bytes| {
            s.source = s.decode_current(bytes) catch {
                s.source = .none;
                s.status = .failed;
                return;
            };
            s.status = .shown;
        } else |_| {
            s.source = .none;
            s.status = .failed;
        }
    }

    fn decode_current(s: *State, bytes: []const u8) !Source {
        const system = builtin.os.tag == .macos and !decode.bundled_only(bytes);
        if (system) return .{ .encoded = bytes };
        const full = std.math.maxInt(u32);
        const size = decode.decode_fit(bytes, s.current_pixels, full, full) catch |err| {
            const portable = folder_mod.is_baseline_name(s.basename());
            if (err == error.Unavailable or portable) return .{ .encoded = bytes };
            return err;
        };
        return .{ .pixels = .{
            .bgra = s.current_pixels[0 .. size.width * size.height * 4],
            .width = size.width,
            .height = size.height,
            .native_w = size.native_w,
            .native_h = size.native_h,
        } };
    }

    /// The preloaded pixels are too small for the zoom: read the file and
    /// keep the viewport, generation and turns.
    pub fn promote(s: *State) void {
        assert(s.source == .pixels and !s.promote_failed);
        if (paths.read_file(s.io, s.path(), s.file_buffer)) |bytes| {
            s.source = s.decode_current(bytes) catch {
                s.promote_failed = true;
                s.notify("Cannot show full resolution", .{});
                return;
            };
        } else |_| {
            s.promote_failed = true;
            s.notify("Cannot show full resolution", .{});
        }
        s.promoted = !s.promote_failed;
        assert(s.source != .none or s.promote_failed);
    }

    /// Rescanning preserves the filename, or the missing file's old position.
    pub fn step(s: *State, delta: i32) void {
        assert(delta == 1 or delta == -1);
        s.slideshow_at = null;
        const missing = s.refresh(false);
        const count = s.folder.count;
        if (count == 0) {
            if (s.slideshow_running) s.notify("No pictures in this folder", .{});
            s.slideshow_running = false;
            return;
        }
        if (missing) |old| {
            const before = if (old > 0) old - 1 else if (s.settings.loop) count - 1 else 0;
            const next = if (delta > 0) old else before;
            s.show_index(if (next >= count and s.settings.loop) 0 else @min(next, count - 1));
            return;
        }
        const from = s.index orelse {
            s.show_index(if (delta > 0) 0 else count - 1);
            return;
        };
        if (!s.settings.loop and
            ((delta > 0 and from == count - 1) or (delta < 0 and from == 0)))
        {
            s.notify("{s}", .{if (delta > 0) "Last picture" else "First picture"});
            s.slideshow_running = false;
            return;
        }
        s.show_index(if (delta > 0) (from + 1) % count else (from + count - 1) % count);
    }

    pub fn endpoint(s: *State, last: bool) void {
        _ = s.refresh(false);
        if (s.folder.count > 0) s.show_index(if (last) s.folder.count - 1 else 0);
    }

    pub fn random(s: *State) void {
        _ = s.refresh(false);
        const count = s.folder.count;
        if (count == 0) return;
        s.random_state ^= s.random_state << 13;
        s.random_state ^= s.random_state >> 7;
        s.random_state ^= s.random_state << 17;
        const choices = if (s.index != null and count > 1) count - 1 else count;
        var next: u32 = @intCast(s.random_state % choices);
        if (s.index) |i| {
            if (count > 1 and next >= i) next += 1;
        }
        s.show_index(next);
    }

    pub fn open_dialog(s: *State) void {
        assert(s.path_len <= paths.path_max);
        const result = nanoui.dialog.open(s.gpa, .{ .extensions = folder_mod.extensions });
        const picked = (result catch return) orelse return;
        s.open_paths(picked);
        for (picked) |p| s.gpa.free(p);
        s.gpa.free(picked);
    }

    pub fn request_trash(s: *State) void {
        if (s.status == .empty) return;
        if (!s.is_file()) return s.notify("This picture is not a file", .{});
        if (!s.settings.trash_confirm) return s.trash();
        s.trash_pending = true;
        s.notify("Move {s} to the Trash? Enter to confirm, Escape to cancel", .{s.basename()});
    }

    pub fn trash(s: *State) void {
        if (s.status == .empty) return;
        if (!s.is_file()) return s.notify("This picture is not a file", .{});
        s.slideshow_at = null;
        s.trash_pending = false;
        var location_buf: [paths.path_max]u8 = undefined;
        const location = shell.trash(s.io, s.path(), &location_buf) orelse {
            s.notify("Could not move {s} to the Trash", .{s.basename()});
            return;
        };
        if (location.len > 0) s.trashed.push(s.path(), location);
        if (s.index) |i| {
            s.preload.lock();
            s.folder.remove(i);
            s.preload.invalidate(s.dir());
            s.preload.unlock();
            if (s.folder.count == 0) {
                s.clear();
            } else {
                const count = s.folder.count;
                const previous = s.settings.after_trash == .previous;
                const next = if (previous and i > 0) i - 1 else if (previous)
                    (if (s.settings.loop) count - 1 else 0)
                else if (i < count) i else (if (s.settings.loop) 0 else count - 1);
                s.show_index(next);
            }
        } else if (s.folder.count > 0) {
            s.step(if (s.settings.after_trash == .previous) -1 else 1);
        } else {
            s.clear();
        }
        assert(s.status == .empty or s.path_len > 0);
    }

    /// Moves the newest file this run put in the Trash back, and shows it.
    pub fn restore(s: *State) void {
        if (builtin.os.tag == .windows) {
            return s.notify("Restore is not available on Windows", .{});
        }
        const item = s.trashed.top() orelse return s.notify("Nothing to restore", .{});
        const name = std.fs.path.basename(item.original());
        // A failure keeps the entry, so Restore works once the cause is
        // fixed, unless the file is gone for good.
        shell.restore(s.io, item.location(), item.original()) catch |err| return switch (err) {
            error.Exists => s.notify("{s} exists again: not restored", .{name}),
            error.NoFolder => s.notify("The folder of {s} is gone: not restored", .{name}),
            error.Gone => {
                s.notify("{s} is no longer in the Trash", .{name});
                s.trashed.pop();
            },
            error.Unavailable, error.Failed => s.notify("Could not restore {s}", .{name}),
        };
        // The popped entry's bytes stay until the next push.
        s.trashed.pop();
        s.open_path(item.original());
        s.notify("Restored {s}", .{name});
        assert(s.status != .empty);
    }

    /// Tells the user what a command did or could not do; the view shows it
    /// for a few seconds. A text too long for the buffer is cut.
    pub fn notify(s: *State, comptime fmt: []const u8, args: anytype) void {
        var writer: std.Io.Writer = .fixed(&s.message_buf);
        writer.print(fmt, args) catch {};
        var len = writer.end;
        // A cut may land inside a UTF-8 sequence: drop its bytes.
        if (len == message_len_max) {
            while (len > 0 and s.message_buf[len - 1] & 0xC0 == 0x80) len -= 1;
            if (len > 0 and s.message_buf[len - 1] >= 0xC0) len -= 1;
        }
        s.message_len = @intCast(len);
        s.message_until = null;
        if (s.window) |w| w.redraw();
        assert(s.message_len <= message_len_max);
    }

    pub fn message(s: *const State) []const u8 {
        assert(s.message_len <= message_len_max);
        return s.message_buf[0..s.message_len];
    }

    /// What `settings.title` asks the title bar to show.
    pub fn title_text(s: *const State, buf: *[title_len_max]u8) []const u8 {
        if (s.status == .empty or s.settings.title == .none) return "nanoview";
        var writer: std.Io.Writer = .fixed(buf);
        writer.writeAll(s.basename()) catch {};
        if (s.settings.title != .name) {
            if (s.index) |i| writer.print(" ({d}/{d})", .{ i + 1, s.folder.count }) catch {};
        }
        const sized = s.status == .shown and s.viewport_generation == s.generation;
        if (s.settings.title == .full and sized) {
            const vp = &s.viewport;
            const w: u32 = @intFromFloat(vp.image_w);
            const h: u32 = @intFromFloat(vp.image_h);
            writer.print(" · {d}×{d} · {d}%", .{ w, h, vp.percent() }) catch {};
        }
        assert(writer.end <= title_len_max);
        return buf[0..writer.end];
    }

    pub fn title(s: *const State) []const u8 {
        assert(s.title_len <= title_len_max);
        return s.title_buf[0..s.title_len];
    }

    /// Called each frame; the window hears only of a change.
    pub fn update_title(s: *State) void {
        var buf: [title_len_max]u8 = undefined;
        const text = s.title_text(&buf);
        if (std.mem.eql(u8, text, s.title())) return;
        @memcpy(s.title_buf[0..text.len], text);
        s.title_len = @intCast(text.len);
        if (s.window) |w| w.setTitle(text);
        assert(std.mem.eql(u8, s.title(), text));
    }

    /// Back to the empty window.
    fn clear(s: *State) void {
        s.status = .empty;
        s.source = .none;
        s.index = null;
        s.path_len = 0;
        s.generation +%= 1;
        s.rename_open = false;
        if (s.window) |w| w.redraw();
        assert(s.status == .empty);
    }

    /// False for a picture pasted from the clipboard: it has no path.
    pub fn is_file(s: *const State) bool {
        assert(s.status != .empty);
        return s.path_len > 0;
    }

    pub fn reveal(s: *State) void {
        if (s.status == .empty) return;
        if (!s.is_file()) return s.notify("This picture is not a file", .{});
        shell.reveal(s.path());
    }

    pub fn copy_path(s: *State) void {
        if (s.status == .empty) return;
        if (!s.is_file()) return s.notify("This picture is not a file", .{});
        nanoui.clipboard.writeText(s.path());
    }

    /// Puts the picture on the clipboard at full size, with its file where
    /// the system takes both.
    pub fn copy_image(s: *State) void {
        if (s.status == .empty) return;
        if (s.status == .failed) return s.notify("There is no picture to copy", .{});
        const file: ?[]const u8 = if (s.is_file()) s.path() else null;
        if (s.full_pixels()) |px| return s.copied(px.bgra, px.width, px.height, file);
        if (builtin.os.tag == .macos) return s.copy_decoded(file);
        // Preloaded pixels may be fitted to the window: decode the file whole.
        if (s.source == .pixels and !s.promote_failed) s.promote();
        if (s.full_pixels()) |px| return s.copied(px.bgra, px.width, px.height, file);
        s.notify("Cannot copy {s}", .{s.basename()});
    }

    fn full_pixels(s: *const State) ?Source.Pixels {
        assert(s.status == .shown);
        const px = switch (s.source) {
            .pixels => |px| px,
            else => return null,
        };
        if (px.width != px.native_w or px.height != px.native_h) return null;
        return px;
    }

    /// macOS keeps no full-size pixels: the system decodes the file whole
    /// into memory it allocates, freed once the clipboard has its copy.
    fn copy_decoded(s: *State, file: ?[]const u8) void {
        assert(builtin.os.tag == .macos and s.status == .shown);
        const encoded = switch (s.source) {
            .encoded => |bytes| bytes,
            // Preloaded pixels come from a slot, which leaves file_buffer free.
            .pixels => paths.read_file(s.io, s.path(), s.file_buffer) catch
                return s.notify("Cannot read {s}", .{s.basename()}),
            .none => unreachable,
        };
        const decode_macos = @import("decode_macos.zig");
        const full = decode_macos.decode_full(encoded) catch |err| return switch (err) {
            error.TooLarge => s.notify("{s} is too large to copy", .{s.basename()}),
            else => s.notify("Cannot copy {s}", .{s.basename()}),
        };
        defer full.release();
        s.copied(full.bgra, full.width, full.height, file);
    }

    fn copied(s: *State, bgra: []const u8, width: u32, height: u32, file: ?[]const u8) void {
        if (nanoui.clipboard.writeImage(bgra, width, height, file)) {
            s.notify("Copied {s}", .{s.basename()});
        } else {
            s.notify("Could not copy {s} to the clipboard", .{s.basename()});
        }
    }

    /// Files on the clipboard, or text naming them, open like a drop;
    /// otherwise a picture on it shows untitled.
    pub fn paste(s: *State) void {
        assert(s.path_len <= paths.path_max);
        if (s.paste_files()) return;
        if (s.paste_text()) return;
        s.paste_image();
    }

    fn paste_files(s: *State) bool {
        const files = (s.clipboard.read_files(s.gpa) catch null) orelse return false;
        defer nanoui.dialog.freePaths(s.gpa, files);
        if (files.len == 0) return false;
        s.open_paths(files);
        return true;
    }

    /// Text counts when every line is an absolute path or file URL of
    /// something that exists: anything else is ordinary text.
    fn paste_text(s: *State) bool {
        const text = (s.clipboard.read_text(s.gpa) catch null) orelse return false;
        defer s.gpa.free(text);
        if (text.len > paste_text_max) return false;
        var lines: [paste_lines_max][]const u8 = undefined;
        var count: u32 = 0;
        var it = std.mem.tokenizeAny(u8, text, "\r\n");
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t");
            if (line.len == 0) continue;
            if (count == paste_lines_max or !s.exists(line)) return false;
            lines[count] = line;
            count += 1;
        }
        if (count == 0) return false;
        s.open_paths(lines[0..count]);
        return true;
    }

    fn exists(s: *State, input: []const u8) bool {
        assert(input.len > 0);
        var buf: [paths.path_max]u8 = undefined;
        const file = if (std.mem.startsWith(u8, input, "file://"))
            paths.from_file_url(input, &buf) orelse return false
        else
            input;
        if (file.len > paths.path_max or !std.fs.path.isAbsolute(file)) return false;
        _ = std.Io.Dir.cwd().statFile(s.io, file, .{}) catch return false;
        return true;
    }

    fn paste_image(s: *State) void {
        const got = s.clipboard.read_image(s.gpa) catch
            return s.notify("Could not read the clipboard", .{});
        const bytes = got orelse return s.notify("The clipboard holds no picture", .{});
        // The one allocation after startup accepted here: the system hands
        // the clipboard over only in memory it allocates. The bytes move
        // into file_buffer within its limit and are freed at once.
        const len = bytes.len;
        const fits = len > 0 and len <= s.file_buffer.len;
        if (fits) @memcpy(s.file_buffer[0..len], bytes);
        s.gpa.free(bytes);
        if (len == 0) return s.notify("The clipboard holds no picture", .{});
        if (!fits) return s.notify("The clipboard picture is too large", .{});
        s.show_clipboard(s.file_buffer[0..len]);
    }

    /// Shows `bytes`, in file_buffer, as a picture with no file and no
    /// folder: stepping finds nothing, and file commands say so.
    fn show_clipboard(s: *State, bytes: []const u8) void {
        assert(bytes.len > 0 and bytes.ptr == s.file_buffer.ptr);
        s.preload.lock();
        if (s.dir_len > 0) s.preload.invalidate(s.dir());
        s.folder.reset();
        s.preload.unlock();
        s.selection.reset();
        s.selection_only = false;
        s.dir_len = 0;
        s.path_len = 0;
        s.index = null;
        s.trash_pending = false;
        s.metadata.len = 0;
        s.begin_picture();
        if (s.decode_current(bytes)) |source| {
            s.source = source;
            s.status = .shown;
        } else |_| {
            s.source = .none;
            s.status = .failed;
            s.notify("Cannot show the clipboard picture", .{});
        }
        if (s.window) |w| {
            w.setTitle(clipboard_name);
            w.redraw();
        }
        assert(!s.is_file());
    }

    /// Opens the name field with the name before the extension selected;
    /// the view draws it and calls `commit_rename` or `cancel_rename`.
    pub fn start_rename(s: *State) void {
        if (s.status == .empty) return;
        if (!s.is_file()) return s.notify("This picture is not a file", .{});
        const name = s.basename();
        s.rename_buffer.set(name);
        if (!std.mem.eql(u8, s.rename_buffer.text(), name)) {
            return s.notify("Cannot rename {s}: the name is too long", .{name});
        }
        s.rename_buffer.want_selection = .{ 0, fileops.stem_len(name) };
        s.rename_buffer.focus();
        s.rename_open = true;
        s.rename_focused = false;
        s.slideshow_at = null;
        assert(s.rename_buffer.text().len == name.len);
    }

    pub fn cancel_rename(s: *State) void {
        assert(s.rename_open);
        s.rename_open = false;
    }

    /// A failure leaves the file as it was and the field open to fix the name.
    pub fn commit_rename(s: *State) void {
        assert(s.rename_open and s.is_file());
        const name = s.rename_buffer.text();
        if (fileops.check_name(name)) |problem| return s.notify("{s}", .{problem.text()});
        var old_buf: [paths.path_max]u8 = undefined;
        const old = old_buf[0..s.basename().len];
        @memcpy(old, s.basename());
        if (std.mem.eql(u8, name, old)) return s.cancel_rename();
        var target_buf: [paths.path_max]u8 = undefined;
        const target = paths.join(s.dir(), name, &target_buf) orelse
            return s.notify("{s}", .{fileops.NameProblem.too_long.text()});
        fileops.move_no_replace(s.path(), target) catch |err| return switch (err) {
            error.Exists => s.notify("{s} already exists", .{name}),
            error.Missing => s.notify("{s} is no longer there", .{old}),
            error.Failed => s.notify("Could not rename {s}", .{old}),
        };
        if (s.selection_only) s.rename_selected(old, name);
        @memcpy(s.path_buf[0..target.len], target);
        s.path_len = @intCast(target.len);
        // The rescan sorts the new name into place; the load reads the
        // picture again, since the rescan let go of its preloaded slot.
        _ = s.refresh(true);
        s.load();
        s.notify("Renamed {s} to {s}", .{ old, s.basename() });
        assert(!s.rename_open);
    }

    /// Opened as a selection of files: the new name stays in it.
    fn rename_selected(s: *State, old: []const u8, name: []const u8) void {
        assert(s.selection_only);
        const i = s.selection.find(old) orelse return;
        s.selection.remove(i);
        if (!s.selection.add(name)) s.selection_only = false;
    }

    /// Another nanoview handed over its files: open them like a drop, and
    /// come to the front either way.
    pub fn on_instance(ctx: *anyopaque, files: []const []const u8) void {
        const s: *State = @ptrCast(@alignCast(ctx));
        assert(s.path_len <= paths.path_max);
        if (files.len > 0) s.open_paths(files);
        if (s.window) |w| w.focus();
    }

    pub fn on_open_files(ctx: *anyopaque, files: []const []const u8) void {
        const s: *State = @ptrCast(@alignCast(ctx));
        assert(s.path_len <= paths.path_max);
        s.open_paths(files);
    }

    /// Promoted pixels get their own prefix, as bytes do: nanoui caches a
    /// picture by key, so new content needs a new key.
    pub fn picture_key(s: *const State, buf: *[16]u8) []const u8 {
        const prefix = switch (s.source) {
            .pixels => if (s.promoted) "f" else "p",
            else => "e",
        };
        const key = std.fmt.bufPrint(buf, "{s}{d}", .{ prefix, s.generation }) catch unreachable;
        assert(key.len > 1);
        return key;
    }
};
