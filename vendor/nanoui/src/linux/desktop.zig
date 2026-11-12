//! The desktop around the app on Linux: the clipboard (GTK's), opening
//! URLs and files with `xdg-open`, the XDG directories, and the theme.
const std = @import("std");
const appearance = @import("appearance.zig");
const gtk = @import("gtk.zig");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn posix_spawnp(pid: *c_int, file: [*:0]const u8, actions: ?*const anyopaque, attr: ?*const anyopaque, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" var environ: [*:null]const ?[*:0]const u8;

fn env(name: [*:0]const u8) ?[]const u8 {
    return if (getenv(name)) |v| std.mem.span(v) else null;
}

/// The CLIPBOARD selection: GTK 3's, or GTK 4's display's.
fn board() ?*anyopaque {
    if (!gtk.ready()) return null;
    if (gtk.v4) return gtk.v4api.gdk_display_get_clipboard(gtk.api.gdk_display_get_default() orelse return null);
    return gtk.v3.gtk_clipboard_get(gtk.v3.gdk_atom_intern("CLIPBOARD", 0));
}

/// GTK 4 reads the clipboard only asynchronously: the answer, waited for
/// on GLib's loop (as GTK 3's wait_for_text waits), a second at most.
const Read = struct {
    done: bool = false,
    text: ?[*:0]u8 = null,
    fn finish(source: *anyopaque, result: *anyopaque, data: ?*anyopaque) callconv(.c) void {
        const r: *Read = @ptrCast(@alignCast(data));
        r.text = gtk.v4api.gdk_clipboard_read_text_finish(source, result, null);
        r.done = true;
    }
};

fn readText4(b: *anyopaque) ?[*:0]u8 {
    var r: Read = .{};
    gtk.v4api.gdk_clipboard_read_text_async(b, null, Read.finish, &r);
    var spins: usize = 0;
    while (!r.done and spins < 1000) : (spins += 1) {
        if (gtk.api.g_main_context_iteration(null, 0) == 0) std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .fromMilliseconds(1), .awake) catch {};
    }
    return r.text;
}

/// GTK functions only the clipboard's pictures use, looked up when first
/// needed: a GTK without one (GTK 4 before 4.6 has no PNG saver) still
/// runs everything else. GTK was opened RTLD_GLOBAL, so the default
/// namespace (a null handle) has its symbols.
fn optional(comptime F: type, name: [*:0]const u8) ?F {
    const sym = std.c.dlsym(null, name) orelse return null;
    return @ptrCast(@alignCast(sym));
}

const memory_b8g8r8a8_premultiplied = 0; // GdkMemoryFormat

fn writeImage4(b: *anyopaque, bgra: []const u8, width: u32, height: u32) bool {
    const bytes_new = optional(*const fn (data: [*]const u8, size: usize) callconv(.c) ?*anyopaque, "g_bytes_new") orelse return false;
    const bytes_unref = optional(*const fn (bytes: *anyopaque) callconv(.c) void, "g_bytes_unref") orelse return false;
    const texture_new = optional(*const fn (w: c_int, h: c_int, format: c_int, bytes: *anyopaque, stride: usize) callconv(.c) ?*anyopaque, "gdk_memory_texture_new") orelse return false;
    const set_texture = optional(*const fn (cb: *anyopaque, texture: *anyopaque) callconv(.c) void, "gdk_clipboard_set_texture") orelse return false;
    // GBytes copies the pixels; the texture keeps the copy.
    const bytes = bytes_new(bgra.ptr, bgra.len) orelse return false;
    defer bytes_unref(bytes);
    const texture = texture_new(@intCast(width), @intCast(height), memory_b8g8r8a8_premultiplied, bytes, @as(usize, width) * 4) orelse return false;
    defer gtk.api.g_object_unref(texture);
    set_texture(b, texture);
    return true;
}

fn writeImage3(b: *anyopaque, bgra: []const u8, width: u32, height: u32) bool {
    const pixbuf_new = optional(*const fn (space: c_int, alpha: c_int, bits: c_int, w: c_int, h: c_int) callconv(.c) ?*anyopaque, "gdk_pixbuf_new") orelse return false;
    const get_pixels = optional(*const fn (pixbuf: *anyopaque) callconv(.c) [*]u8, "gdk_pixbuf_get_pixels") orelse return false;
    const get_stride = optional(*const fn (pixbuf: *anyopaque) callconv(.c) c_int, "gdk_pixbuf_get_rowstride") orelse return false;
    const set_image = optional(*const fn (cb: *anyopaque, pixbuf: *anyopaque) callconv(.c) void, "gtk_clipboard_set_image") orelse return false;
    // GdkPixbuf has straight RGBA only, in rows it allocates and pads.
    const pixbuf = pixbuf_new(0, 1, 8, @intCast(width), @intCast(height)) orelse return false;
    defer gtk.api.g_object_unref(pixbuf);
    const pixels = get_pixels(pixbuf);
    const stride: usize = @intCast(get_stride(pixbuf));
    for (0..height) |y| {
        for (0..width) |x| {
            const p = bgra[(y * width + x) * 4 ..][0..4];
            const a: u32 = p[3];
            const out = pixels[y * stride + x * 4 ..][0..4];
            if (a == 0) {
                out.* = .{ 0, 0, 0, 0 };
                continue;
            }
            for (0..3) |i| out[i] = @intCast(@min(255, (@as(u32, p[2 - i]) * 255 + a / 2) / a));
            out[3] = p[3];
        }
    }
    set_image(b, pixbuf);
    return true;
}

pub const clipboard = struct {
    pub fn readText(gpa: std.mem.Allocator) !?[]u8 {
        const b = board() orelse return null;
        const s = (if (gtk.v4) readText4(b) else gtk.v3.gtk_clipboard_wait_for_text(b)) orelse return null;
        defer gtk.api.g_free(s);
        return try gpa.dupe(u8, std.mem.span(s));
    }

    pub fn writeText(text: []const u8) void {
        const b = board() orelse return;
        if (gtk.v4) {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(std.heap.c_allocator);
            buf.appendSlice(std.heap.c_allocator, text) catch return;
            buf.append(std.heap.c_allocator, 0) catch return;
            gtk.v4api.gdk_clipboard_set_text(b, @ptrCast(buf.items.ptr));
        } else gtk.v3.gtk_clipboard_set_text(b, text.ptr, @intCast(text.len));
    }

    /// Puts a picture on the clipboard: `bgra` is `width` by `height`
    /// premultiplied BGRA pixels. GTK offers it in the formats it can
    /// convert to (PNG among them). The file it came from does not go
    /// along: GTK has no image-and-file pair. False when it could not.
    pub fn writeImage(bgra: []const u8, width: u32, height: u32, file: ?[]const u8) bool {
        _ = file;
        const n = @as(usize, width) * height;
        if (n == 0 or bgra.len != n * 4) return false;
        if (width > std.math.maxInt(c_int) or height > std.math.maxInt(c_int)) return false;
        const b = board() orelse return false;
        return if (gtk.v4) writeImage4(b, bgra, width, height) else writeImage3(b, bgra, width, height);
    }

    pub fn changeCount() isize {
        return 0;
    }

    /// Images on the clipboard: not read here yet.
    pub fn readImage(_: std.mem.Allocator) !?[]u8 {
        return null;
    }

    /// Files on the clipboard: not read here yet.
    pub fn readFiles(_: std.mem.Allocator) !?[][]u8 {
        return null;
    }
};

/// Runs `xdg-open` on `target`, not waiting for it.
fn xdgOpen(target: []const u8) bool {
    var buf: [4096]u8 = undefined;
    if (target.len >= buf.len) return false;
    @memcpy(buf[0..target.len], target);
    buf[target.len] = 0;
    const argv = [_:null]?[*:0]const u8{ "xdg-open", @ptrCast(&buf) };
    var pid: c_int = 0;
    return posix_spawnp(&pid, "xdg-open", null, null, &argv, environ) == 0;
}

pub const shell = struct {
    pub fn openUrl(url: []const u8) bool {
        return xdgOpen(url);
    }

    pub fn openPath(file: []const u8) bool {
        return xdgOpen(file);
    }

    pub fn showInFolder(file: []const u8) void {
        _ = xdgOpen(std.fs.path.dirname(file) orelse file);
    }

    pub fn trash(file: []const u8) bool {
        _ = file;
        return false;
    }

    pub fn trashTo(_: []const u8, _: []u8) ?[]u8 {
        return null;
    }

    pub fn beep() void {}
};

pub const Directory = enum { data, cache, home, documents, downloads, desktop, temp };

/// The path of a standard directory, by the XDG conventions; for `data`
/// and `cache`, the app's own, created if missing. Caller frees it.
pub fn path(gpa: std.mem.Allocator, dir: Directory, app_name: []const u8) ![]u8 {
    const home = env("HOME") orelse "/tmp";
    const io = std.Io.Threaded.global_single_threaded.io();
    const full = switch (dir) {
        .temp => return gpa.dupe(u8, env("TMPDIR") orelse "/tmp"),
        .home => return gpa.dupe(u8, home),
        .documents => return std.fs.path.join(gpa, &.{ home, "Documents" }),
        .downloads => return std.fs.path.join(gpa, &.{ home, "Downloads" }),
        .desktop => return std.fs.path.join(gpa, &.{ home, "Desktop" }),
        .data => if (env("XDG_DATA_HOME")) |d| try std.fs.path.join(gpa, &.{ d, app_name }) else try std.fs.path.join(gpa, &.{ home, ".local", "share", app_name }),
        .cache => if (env("XDG_CACHE_HOME")) |d| try std.fs.path.join(gpa, &.{ d, app_name }) else try std.fs.path.join(gpa, &.{ home, ".cache", app_name }),
    };
    std.Io.Dir.cwd().createDirPath(io, full) catch {};
    return full;
}

/// Whether the desktop asks for dark colors: `GTK_THEME`, where it is set (as
/// GTK itself reads it), else the portal's scheme, else GtkSettings — see
/// `appearance.zig`.
pub fn isDark() bool {
    return appearance.dark(env("GTK_THEME"));
}

pub fn accentColor() [3]f32 {
    return .{ 0.21, 0.52, 0.89 };
}
