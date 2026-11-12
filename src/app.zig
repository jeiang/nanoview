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
const animation = @import("animation.zig");
const playback = @import("playback.zig");
const assert = std.debug.assert;

pub const file_size_max = decode.file_size_max;
/// Room for the largest picture at full size.
pub const current_pixels_max: u32 = decode.pixels_max * 4;
pub const message_len_max: u32 = 512;
pub const title_len_max: u32 = 512;

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
    gpa: std.mem.Allocator, // only for nanoui.dialog.open's result
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
    player: animation.Player = .{},

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
        animation_memory: []u8,
    ) void {
        assert(file_buffer.len == file_size_max);
        assert(current_pixels.len == current_pixels_max);
        assert(animation_memory.len == animation.memory_bytes);
        folder_mod.init_extensions();
        s.* = .{
            .io = io,
            .gpa = gpa,
            .file_buffer = file_buffer,
            .current_pixels = current_pixels,
            .keymap = .defaults(),
            .player = .{ .memory = animation_memory },
        };
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

    pub fn basename(s: *const State) []const u8 {
        assert(s.path_len > 0);
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
        s.player.stop();
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

    pub fn load(s: *State) void {
        assert(s.path_len > 0);
        s.player.stop();
        s.generation +%= 1;
        s.turns_user = 0;
        s.mirror = false;
        s.flip = false;
        s.drag_last = null;
        s.promote_failed = false;
        s.promoted = false;
        s.slideshow_at = null;
        s.metadata.load(s.io, s.path());
        // Without an index nothing preloads: `current` stays null.
        const slot = if (s.index) |i| s.preload.take(i) else null;
        // An animation plays from the file's bytes, which the slot does not keep.
        const animated = if (slot) |n| s.preload.slots[n].animated else false;
        if (slot != null and !(animated and s.settings.animation)) {
            s.source = s.slot_source(slot.?);
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
            if (playback.play(s, bytes)) {
                s.status = .shown;
                return;
            }
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
        // An animation's canvas is full size, and its file must stay in `file_buffer`.
        assert(!s.player.active());
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
        if (!s.settings.trash_confirm) return s.trash();
        s.trash_pending = true;
        s.notify("Move {s} to the Trash? Enter to confirm, Escape to cancel", .{s.basename()});
    }

    pub fn trash(s: *State) void {
        if (s.status == .empty) return;
        s.slideshow_at = null;
        s.trash_pending = false;
        assert(s.path_len > 0);
        if (!shell.trash(s.io, s.path())) {
            s.notify("Could not move {s} to the Trash", .{s.basename()});
            return;
        }
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
        s.player.stop();
        s.status = .empty;
        s.source = .none;
        s.index = null;
        s.path_len = 0;
        s.generation +%= 1;
        if (s.window) |w| w.redraw();
        assert(s.status == .empty);
    }

    pub fn reveal(s: *const State) void {
        if (s.status == .empty) return;
        assert(s.path_len > 0);
        shell.reveal(s.path());
    }

    pub fn copy_path(s: *const State) void {
        if (s.status == .empty) return;
        assert(s.path_len > 0);
        nanoui.clipboard.writeText(s.path());
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
            .pixels => if (s.player.active()) "a" else if (s.promoted) "f" else "p",
            else => "e",
        };
        // Each frame of an animation is new content.
        const number = if (s.player.active()) s.player.serial else s.generation;
        const key = std.fmt.bufPrint(buf, "{s}{d}", .{ prefix, number }) catch unreachable;
        assert(key.len > 1);
        return key;
    }
};
