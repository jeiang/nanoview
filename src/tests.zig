const builtin = @import("builtin");
const std = @import("std");
const ui = @import("nanoui").ui;
const app = @import("app.zig");
const view = @import("view.zig");
const paths = @import("paths.zig");
const preload = @import("preload.zig");
const animation = @import("animation.zig");
const decode = @import("decode.zig");
const save_mod = @import("save.zig");
const State = app.State;
const testing = std.testing;

test {
    _ = @import("viewport.zig");
    _ = @import("folder.zig");
    _ = @import("paths.zig");
    _ = @import("orientation.zig");
    _ = @import("bplist.zig");
    _ = @import("ds_store.zig");
    _ = @import("sort_order.zig");
    _ = @import("explorer_sort.zig");
    _ = @import("shell.zig");
    _ = @import("actions.zig");
    _ = @import("settings.zig");
    _ = @import("keymap.zig");
    _ = @import("recent.zig");
    _ = @import("decode.zig");
    _ = @import("webp.zig");
    _ = @import("wuffs.zig");
    _ = @import("animation.zig");
    _ = @import("png_save.zig");
    _ = @import("decode_windows.zig");
    _ = @import("fileops.zig");
    _ = @import("instance.zig");
    if (builtin.os.tag != .windows) _ = @import("instance_posix.zig");
    _ = @import("sniff.zig");
    _ = @import("exif.zig");
    _ = @import("tests_menus.zig");
}

/// What the stand-in clipboard holds: tests never read the real one.
const Pasted = struct {
    files: ?[]const []const u8 = null,
    text: ?[]const u8 = null,
    image: ?[]const u8 = null,
};
pub var pasted: Pasted = .{};

const fake_clipboard: app.Clipboard = .{
    .read_files = fake_files,
    .read_text = fake_text,
    .read_image = fake_image,
};

fn fake_files(gpa: std.mem.Allocator) anyerror!?[][]u8 {
    const files = pasted.files orelse return null;
    const out = try gpa.alloc([]u8, files.len);
    for (files, out) |file, *o| o.* = try gpa.dupe(u8, file);
    return out;
}

fn fake_text(gpa: std.mem.Allocator) anyerror!?[]u8 {
    return try gpa.dupe(u8, pasted.text orelse return null);
}

fn fake_image(gpa: std.mem.Allocator) anyerror!?[]u8 {
    return try gpa.dupe(u8, pasted.image orelse return null);
}
/// A State and a Tester over it, on the heap: State is too large for the
/// stack. The large buffers stay untouched until used.
pub const Fixture = struct {
    state: *State,
    file_buffer: []u8,
    pool: []u8,
    scratch: []u8,
    current_pixels: []u8,
    animation_memory: []u8,
    tester: ui.Tester = undefined,
    tmp: std.testing.TmpDir,
    dir_buf: [paths.path_max]u8 = undefined,
    dir_len: usize = 0,

    pub fn create() !*Fixture {
        const f = try testing.allocator.create(Fixture);
        errdefer testing.allocator.destroy(f);
        const state = try testing.allocator.create(State);
        errdefer testing.allocator.destroy(state);
        f.* = .{
            .state = state,
            .file_buffer = try app.alloc_pages(app.file_size_max),
            .pool = try app.alloc_pages(preload.pool_bytes),
            .scratch = try app.alloc_pages(if (preload.decoded) app.file_size_max else 0),
            .current_pixels = try app.alloc_pages(app.current_pixels_max),
            .animation_memory = try app.alloc_pages(animation.memory_bytes),
            .tmp = testing.tmpDir(.{}),
        };
        const pixels = f.current_pixels;
        state.init(
            testing.io,
            testing.allocator,
            f.file_buffer,
            f.pool,
            f.scratch,
            pixels,
            f.animation_memory,
        );
        state.clipboard = fake_clipboard;
        pasted = .{};
        f.dir_len = try f.tmp.dir.realPathFile(testing.io, ".", &f.dir_buf);
        try f.tester.init(testing.allocator, .init(state, view.view), .{
            .width = 480,
            .height = 360,
        });
        return f;
    }

    pub fn destroy(f: *Fixture) void {
        f.tester.deinit();
        f.tmp.cleanup();
        app.free_pages(f.file_buffer);
        app.free_pages(f.pool);
        app.free_pages(f.scratch);
        app.free_pages(f.current_pixels);
        app.free_pages(f.animation_memory);
        testing.allocator.destroy(f.state);
        testing.allocator.destroy(f);
    }

    pub fn write_png(f: *Fixture, name: []const u8, width: usize, height: usize) !void {
        const pixels = try testing.allocator.alloc(u8, width * height * 4);
        defer testing.allocator.free(pixels);
        @memset(pixels, 0xff);
        const png = try ui.png.encode(testing.allocator, .{
            .bytes = pixels,
            .width = width,
            .height = height,
        });
        defer testing.allocator.free(png);
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = png });
    }

    pub fn open(f: *Fixture, name: []const u8) !void {
        var buf: [paths.path_max]u8 = undefined;
        const full = paths.join(f.dir_buf[0..f.dir_len], name, &buf) orelse return error.TooLong;
        f.state.open_path(full);
        f.tester.frame();
    }
};

test "the empty window shows the hint" {
    const f = try Fixture.create();
    defer f.destroy();
    try testing.expect(f.tester.containsText("Drop an image"));
}

test "right walks the folder in natural order and wraps" {
    const f = try Fixture.create();
    defer f.destroy();
    for ([_][]const u8{ "a1.png", "a2.png", "a10.png" }) |n| try f.write_png(n, 4, 4);
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "notes.txt", .data = "x" });
    try f.open("a1.png");
    try testing.expectEqual(app.Status.shown, f.state.status);
    try testing.expectEqual(@as(?u32, 0), f.state.index);
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.right });
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.right });
    try testing.expectEqualStrings("a10.png", f.state.basename());
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.right });
    try testing.expectEqualStrings("a1.png", f.state.basename());
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.left });
    try testing.expectEqualStrings("a10.png", f.state.basename());
}

test "mouse side buttons walk the folder" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.write_png("a1.png", 4, 4);
    try f.write_png("a2.png", 4, 4);
    try f.open("a1.png");
    f.tester.clickWith(.forward, 240, 180);
    try testing.expectEqualStrings("a2.png", f.state.basename());
    f.tester.clickWith(.back, 240, 180);
    try testing.expectEqualStrings("a1.png", f.state.basename());
}

test "a pinch zooms and 0 fits again" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.write_png("wide.png", 1000, 10);
    try f.open("wide.png");
    try testing.expect(f.state.viewport.fit);
    f.tester.pinch(240, 180, 2, 0, 0);
    try testing.expect(!f.state.viewport.fit);
    _ = f.tester.shortcut(.{ .key = '0' });
    try testing.expect(f.state.viewport.fit);
}

test "a file that is not a picture fails visibly" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "notes.txt", .data = "not a picture" });
    try f.open("notes.txt");
    try testing.expectEqual(app.Status.failed, f.state.status);
    try testing.expect(f.tester.containsText("Cannot show notes.txt"));
}

test "a PNG named a.dat opens directly, joins the list and says PNG" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.write_png("a.dat", 8, 8);
    try f.write_png("b.png", 8, 8);
    try f.open("a.dat");
    try testing.expectEqual(app.Status.shown, f.state.status);
    try testing.expectEqual(@as(?u32, 0), f.state.index);
    try testing.expectEqual(@as(u32, 2), f.state.folder.count);
    _ = f.tester.shortcut(.{ .key = 'i' });
    try testing.expect(f.tester.containsText("PNG ·"));
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.right });
    try testing.expectEqualStrings("b.png", f.state.basename());
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.right });
    try testing.expectEqualStrings("a.dat", f.state.basename());
    try testing.expectEqual(app.Status.shown, f.state.status);
}

test "a JPEG named b.png shows and the info line says JPEG" {
    const f = try Fixture.create();
    defer f.destroy();
    const jpeg = @embedFile("testdata/format.jpeg");
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "b.png", .data = jpeg });
    try f.open("b.png");
    try testing.expectEqual(app.Status.shown, f.state.status);
    _ = f.tester.shortcut(.{ .key = 'i' });
    try testing.expect(f.tester.containsText("JPEG ·"));
    try testing.expect(!f.tester.containsText("PNG ·"));
}

test "e lists the EXIF details of a camera JPEG and says when a file has none" {
    const f = try Fixture.create();
    defer f.destroy();
    const jpeg = @embedFile("testdata/exif.jpeg");
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "a.jpg", .data = jpeg });
    try f.write_png("b.png", 8, 8);
    try f.open("a.jpg");
    _ = f.tester.shortcut(.{ .key = 'e' });
    const want = [_][]const u8{
        "Camera: Canon EOS R5",       "Lens: RF24-70mm F2.8 L IS USM",
        "Taken: 2024-05-01 12:34:56", "Exposure: 1/250 s",
        "Aperture: f/2.8",            "ISO: 200",
        "Focal length: 50.0 mm",      "Flash: fired",
        "Pixels: 32 × 32",
        "GPS: 48.858370, 2.294481",   "Software: nanoview test",
        "Color space: sRGB",
    };
    for (want) |line| try testing.expect(f.tester.containsText(line));
    // The panel follows the next picture, and goes away on a second press.
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.right });
    try testing.expect(f.tester.containsText("No EXIF data"));
    try testing.expect(!f.tester.containsText("Camera:"));
    _ = f.tester.shortcut(.{ .key = 'e' });
    try testing.expect(!f.tester.containsText("No EXIF data"));
}

test "r turns the view a quarter and i shows the upright size" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.write_png("wide.png", 20, 10);
    try f.open("wide.png");
    _ = f.tester.shortcut(.{ .key = 'r' });
    try testing.expectEqual(@as(f32, 10), f.state.viewport.image_w);
    try testing.expectEqual(@as(f32, 20), f.state.viewport.image_h);
    _ = f.tester.shortcut(.{ .key = 'l' });
    _ = f.tester.shortcut(.{ .key = 'i' });
    try testing.expect(f.tester.containsText("20×10"));
}

fn drain(p: *preload.Preload) u32 {
    var jobs: u32 = 0;
    while (jobs < preload.slot_count * 2 and p.run_one()) jobs += 1;
    return jobs;
}

test "the worker preloads the neighbors and the next step uses them" {
    const f = try Fixture.create();
    defer f.destroy();
    for ([_][]const u8{ "a1.png", "a2.png", "a3.png", "a4.png", "a5.png" }) |n| {
        try f.write_png(n, 40, 30);
    }
    try f.open("a1.png");
    f.state.preload.set_bounds(960, 720);
    _ = drain(&f.state.preload);
    var ready: [5]bool = @splat(false);
    var ready_count: u32 = 0;
    for (f.state.preload.slots) |slot| {
        if (slot.state != .ready) continue;
        ready[slot.index] = true;
        ready_count += 1;
    }
    try testing.expectEqual(@as(u32, 4), ready_count);
    try testing.expect(!ready[0] and ready[1] and ready[2] and ready[3] and ready[4]);
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.right });
    try testing.expect(f.state.preload.pinned != null);
    if (preload.decoded) {
        try testing.expect(f.state.source == .pixels);
    } else {
        const bytes = f.state.source.encoded;
        const pool = f.state.preload.pool;
        try testing.expect(@intFromPtr(bytes.ptr) >= @intFromPtr(pool.ptr));
        try testing.expect(@intFromPtr(bytes.ptr) < @intFromPtr(pool.ptr) + pool.len);
    }
}

test "zooming past the preloaded pixels reads the file" {
    if (!preload.decoded) return error.SkipZigTest;
    const f = try Fixture.create();
    defer f.destroy();
    try f.write_png("a.png", 64, 64);
    try f.write_png("b.png", 2000, 10);
    try f.open("a.png");
    f.state.preload.set_bounds(960, 720);
    _ = drain(&f.state.preload);
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.right });
    try testing.expect(f.state.source == .pixels);
    var before_buf: [16]u8 = undefined;
    const before = f.state.picture_key(&before_buf);
    f.tester.pinch(240, 180, 8, 0, 0);
    switch (f.state.source) {
        .encoded => {},
        .pixels => |px| try testing.expectEqual(px.native_w, px.width),
        .none => return error.TestUnexpectedResult,
    }
    var after_buf: [16]u8 = undefined;
    try testing.expect(!std.mem.eql(u8, before, f.state.picture_key(&after_buf)));
    try testing.expect(!f.state.viewport.fit);
}

test "ImageIO formats display directly and from preloaded pixels" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const formats = .{ "psd", "icns", "exr", "tga", "jp2", "pbm", "sgi", "jpe", "jfif" };
    inline for (formats) |format| {
        const f = try Fixture.create();
        defer f.destroy();
        const alias = comptime (std.mem.eql(u8, format, "jpe") or std.mem.eql(u8, format, "jfif"));
        const fixture = if (alias)
            "jpeg"
        else
            format;
        try f.write_png("a.png", 32, 32);
        try f.tmp.dir.writeFile(testing.io, .{
            .sub_path = "b." ++ format,
            .data = @embedFile("testdata/format." ++ fixture),
        });
        try f.open("b." ++ format);
        try testing.expectEqual(app.Status.shown, f.state.status);
        try testing.expect(!f.tester.containsText("Cannot show"));
        try f.open("a.png");
        f.state.preload.set_bounds(960, 720);
        _ = drain(&f.state.preload);
        _ = f.tester.shortcut(.{ .key = ui.Shortcut.right });
        try testing.expectEqual(app.Status.shown, f.state.status);
        try testing.expect(f.state.source == .pixels);
        try testing.expect(f.state.preload.pinned != null);
        try testing.expect(!f.tester.containsText("Cannot show"));
    }
}

test "bundled formats display directly and from preloaded pixels on every system" {
    const fixtures = @import("wuffs_fixtures.zig");
    const dot: fixtures.Rgba = .{ 0, 128, 255, 255 };
    const dots: [4]fixtures.Rgba = @splat(dot);
    const files = .{
        .{ "b.qoi", comptime fixtures.qoi(2, 2, &dots) },
        .{ "b.tga", comptime fixtures.tga32(2, 2, &dots) },
        .{ "b.bmp", comptime fixtures.bmp24(2, 2, &dots) },
        .{ "b.webp", @embedFile("testdata/webp_lossy.webp") },
    };
    inline for (files) |file| {
        const f = try Fixture.create();
        defer f.destroy();
        try f.write_png("a.png", 32, 32);
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = file[0], .data = file[1] });
        try f.open(file[0]);
        try testing.expectEqual(app.Status.shown, f.state.status);
        try testing.expect(!f.tester.containsText("Cannot show"));
        try f.open("a.png");
        f.state.preload.set_bounds(960, 720);
        _ = drain(&f.state.preload);
        _ = f.tester.shortcut(.{ .key = ui.Shortcut.right });
        try testing.expectEqual(app.Status.shown, f.state.status);
        try testing.expect(f.state.source == .pixels);
        try testing.expect(!f.tester.containsText("Cannot show"));
    }
}

test "opening another folder empties the slots" {
    const f = try Fixture.create();
    defer f.destroy();
    for ([_][]const u8{ "a1.png", "a2.png", "a3.png" }) |n| try f.write_png(n, 8, 8);
    try f.tmp.dir.createDirPath(testing.io, "other");
    try f.write_png("other/b.png", 8, 8);
    try f.open("a1.png");
    f.state.preload.set_bounds(960, 720);
    _ = drain(&f.state.preload);
    try f.open("other/b.png");
    for (f.state.preload.slots) |slot| {
        try testing.expect(slot.state == .empty or slot.state == .loading);
    }
}

test "a failed trash says so, then the message goes away" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.write_png("a.png", 4, 4);
    try f.open("a.png");
    // Nothing left to move: every system's trash refuses.
    try f.tmp.dir.deleteFile(testing.io, "a.png");
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.forward_delete });
    try testing.expect(f.tester.containsText("Could not move a.png to the Trash"));
    try testing.expectEqualStrings("a.png", f.state.basename());
    f.tester.advance(5);
    try testing.expect(!f.tester.containsText("Could not move"));
}

test "startup settings errors survive until the window's first frame" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.tmp.dir.writeFile(testing.io, .{
        .sub_path = "settings.conf",
        .data = "smooth=invalid\nzoom_step_percent=80\n",
    });
    f.state.load_settings(f.dir_buf[0..f.dir_len]);
    try testing.expectEqual(@as(u32, 80), f.state.settings.zoom_step_percent);
    try testing.expect(f.state.settings.smooth);
    try testing.expect(f.state.message_until == null);
    f.tester.frame();
    try testing.expect(f.tester.containsText("settings.conf line 1: bad value"));
    f.tester.advance(1);
    try testing.expect(f.tester.containsText("settings.conf line 1: bad value"));
}

test "Home End Space and random navigate without repeating" {
    const f = try Fixture.create();
    defer f.destroy();
    for ([_][]const u8{ "a.png", "b.png", "c.png" }) |n| try f.write_png(n, 4, 4);
    try f.open("b.png");
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.home });
    try testing.expectEqualStrings("a.png", f.state.basename());
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.end });
    try testing.expectEqualStrings("c.png", f.state.basename());
    _ = f.tester.shortcut(.{ .key = ' ', .shift = true });
    try testing.expectEqualStrings("b.png", f.state.basename());
    _ = f.tester.shortcut(.{ .key = ' ' });
    try testing.expectEqualStrings("c.png", f.state.basename());
    for (0..32) |_| {
        const old = f.state.index;
        _ = f.tester.shortcut(.{ .key = 'x' });
        try testing.expect(old != f.state.index);
    }
}

test "loop off stays put at either end" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.write_png("a.png", 4, 4);
    try f.write_png("b.png", 4, 4);
    try f.open("a.png");
    f.state.settings.loop = false;
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.left });
    try testing.expectEqualStrings("a.png", f.state.basename());
    try testing.expect(f.tester.containsText("First picture"));
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.end });
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.right });
    try testing.expectEqualStrings("b.png", f.state.basename());
    try testing.expect(f.tester.containsText("Last picture"));
}

test "a changed folder rescans additions and a deleted current file" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.write_png("a.png", 4, 4);
    try f.open("a.png");
    try f.write_png("b.png", 4, 4);
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.right });
    try testing.expectEqualStrings("b.png", f.state.basename());
    try f.write_png("c.png", 4, 4);
    try f.tmp.dir.deleteFile(testing.io, "b.png");
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.right });
    try testing.expectEqualStrings("c.png", f.state.basename());
}

test "opening a directory selects its first picture and empty folders say so" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.write_png("b.png", 4, 4);
    try f.write_png("a.png", 4, 4);
    f.state.open_path(f.dir_buf[0..f.dir_len]);
    f.tester.frame();
    try testing.expectEqualStrings("a.png", f.state.basename());
    try f.tmp.dir.createDirPath(testing.io, "empty");
    try f.open("empty");
    try testing.expect(f.tester.containsText("No pictures in this folder"));
}

test "multiple open files limit navigation and reload retains that selection" {
    const f = try Fixture.create();
    defer f.destroy();
    for ([_][]const u8{ "a.png", "b.png", "c.png" }) |n| try f.write_png(n, 4, 4);
    var a: [paths.path_max]u8 = undefined;
    var c: [paths.path_max]u8 = undefined;
    const pa = paths.join(f.dir_buf[0..f.dir_len], "a.png", &a).?;
    const pc = paths.join(f.dir_buf[0..f.dir_len], "c.png", &c).?;
    State.on_open_files(f.state, &.{ pc, pa });
    f.tester.frame();
    try testing.expectEqualStrings("c.png", f.state.basename());
    try testing.expectEqual(@as(u32, 2), f.state.folder.count);
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.right });
    try testing.expectEqualStrings("a.png", f.state.basename());
    try f.write_png("a.png", 8, 6);
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.f(5) });
    try testing.expectEqual(@as(f32, 8), f.state.viewport.image_w);
    try testing.expectEqual(@as(u32, 2), f.state.folder.count);
    _ = f.tester.shortcut(.{ .key = 'i' });
    try testing.expect(f.tester.containsText("PNG"));
}

test "slideshow advances restarts its timer reverses and stops at an end" {
    const f = try Fixture.create();
    defer f.destroy();
    for ([_][]const u8{ "a.png", "b.png", "c.png" }) |n| try f.write_png(n, 4, 4);
    try f.open("a.png");
    f.state.settings.slideshow_seconds = 1;
    _ = f.tester.shortcut(.{ .key = 's' });
    f.tester.advance(1.1);
    try testing.expectEqualStrings("b.png", f.state.basename());
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.left });
    f.tester.advance(0.5);
    try testing.expectEqualStrings("a.png", f.state.basename());
    f.tester.advance(0.6);
    try testing.expectEqualStrings("b.png", f.state.basename());
    f.state.settings.slideshow_reverse = true;
    f.state.settings.loop = false;
    f.tester.advance(2.2);
    try testing.expectEqualStrings("a.png", f.state.basename());
    try testing.expect(!f.state.slideshow_running);
    try testing.expect(f.tester.containsText("First picture"));
}

test "trash confirmation cancels and Enter accepts without touching system trash" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.write_png("a.png", 4, 4);
    try f.open("a.png");
    f.state.settings.trash_confirm = true;
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.forward_delete });
    try testing.expect(f.tester.containsText("Move a.png to the Trash?"));
    f.tester.advance(5);
    try testing.expect(f.state.trash_pending);
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.escape });
    try testing.expect(!f.state.trash_pending);
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.forward_delete });
    _ = f.tester.shortcut(.{ .key = 'i' });
    try testing.expect(!f.state.trash_pending);
    try f.tmp.dir.deleteFile(testing.io, "a.png");
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.forward_delete });
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.enter });
    try testing.expect(f.tester.containsText("Could not move a.png to the Trash"));
}
test "mirror and flip are view only and reset with the next picture" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.write_png("a.png", 20, 10);
    try f.write_png("b.png", 20, 10);
    try f.open("a.png");
    _ = f.tester.shortcut(.{ .key = 'm' });
    try testing.expect(f.state.viewport.mirror);
    try testing.expect(f.tester.containsText("Mirror: on"));
    _ = f.tester.shortcut(.{ .key = 'v' });
    _ = f.tester.shortcut(.{ .key = 'r' });
    try testing.expect(f.state.viewport.mirror and f.state.viewport.flip);
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.right });
    try testing.expect(!f.state.viewport.mirror and !f.state.viewport.flip);
}

test "w cycles fit modes and zero restores the selected fit" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.write_png("a.png", 1000, 200);
    try f.open("a.png");
    const FitMode = @import("settings.zig").FitMode;
    for ([_]FitMode{ .width, .height, .fill, .whole }) |mode| {
        _ = f.tester.shortcut(.{ .key = 'w' });
        try testing.expectEqual(mode, f.state.settings.fit_mode);
        try testing.expectEqual(mode, f.state.viewport.fit_mode);
        try testing.expect(f.state.viewport.fit);
    }
    _ = f.tester.shortcut(.{ .key = '-' });
    try testing.expect(!f.state.viewport.fit);
    _ = f.tester.shortcut(.{ .key = '0' });
    try testing.expect(f.state.viewport.fit);
}

test "zoom lock keeps scale and relative position on the next picture" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.write_png("a.png", 1000, 800);
    try f.write_png("b.png", 1200, 1000);
    try f.open("a.png");
    _ = f.tester.shortcut(.{ .key = '1' });
    f.state.viewport.pan(-100, -80);
    const old = f.state.viewport;
    _ = f.tester.shortcut(.{ .key = 'z' });
    try testing.expect(f.tester.containsText("Zoom lock: on"));
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.right });
    const vp = f.state.viewport;
    try testing.expectApproxEqAbs(old.scale, vp.scale, 0.0001);
    const old_center = (240 - old.x) / (old.image_w * old.scale);
    const new_center = (240 - vp.x) / (vp.image_w * vp.scale);
    try testing.expectApproxEqAbs(old_center, new_center, 0.0001);
    try testing.expect(!vp.fit);
}

test "zoom keys use the configured percentage and options notify" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.write_png("a.png", 1000, 800);
    try f.open("a.png");
    f.state.settings.zoom_step_percent = 50;
    const old = f.state.viewport.scale;
    _ = f.tester.shortcut(.{ .key = '=' });
    try testing.expectApproxEqAbs(old * 1.5, f.state.viewport.scale, 0.0001);
    for ([_]u8{ 'p', 'b', 'u' }, [_][]const u8{
        "Smooth: off", "Checkerboard: on", "Fit upscale: on",
    }) |key, message| {
        _ = f.tester.shortcut(.{ .key = key });
        try testing.expect(f.tester.containsText(message));
    }
}

test "off macOS a typed plus zooms in with Shift held" {
    if (@import("builtin").os.tag == .macos) return error.SkipZigTest;
    const f = try Fixture.create();
    defer f.destroy();
    try f.write_png("a.png", 1000, 800);
    try f.open("a.png");
    const before = f.state.viewport.scale;
    f.tester.setMods(.{ .shift = true });
    f.tester.typeText("+");
    try testing.expect(f.state.viewport.scale > before);
    const zoomed = f.state.viewport.scale;
    f.tester.setMods(.{});
    f.tester.typeText("-");
    try testing.expect(f.state.viewport.scale < zoomed);
}

test "a rebound key runs its action and its old key no longer does" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.write_png("a.png", 4, 4);
    try f.write_png("b.png", 4, 4);
    try f.tmp.dir.writeFile(testing.io, .{
        .sub_path = "settings.conf",
        .data = "key.next = n, PageDown\nkey.previous = shift+N\n",
    });
    f.state.load_settings(f.dir_buf[0..f.dir_len]);
    try testing.expectEqual(@as(u32, 0), f.state.message_len);
    try f.open("a.png");
    _ = f.tester.shortcut(.{ .key = 'n' });
    try testing.expectEqualStrings("b.png", f.state.basename());
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.right });
    _ = f.tester.shortcut(.{ .key = ' ' });
    try testing.expectEqualStrings("b.png", f.state.basename());
    _ = f.tester.shortcut(.{ .key = 'n', .shift = true });
    try testing.expectEqualStrings("a.png", f.state.basename());
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.page_down });
    try testing.expectEqualStrings("b.png", f.state.basename());
}

test "a key bound twice in settings.conf is named in the window" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.tmp.dir.writeFile(testing.io, .{
        .sub_path = "settings.conf",
        .data = "# keys\nkey.info = x\n",
    });
    f.state.load_settings(f.dir_buf[0..f.dir_len]);
    f.tester.frame();
    try testing.expect(f.tester.containsText("settings.conf line 2: key bound to two actions"));
}

test "each title mode gives its text" {
    const f = try Fixture.create();
    defer f.destroy();
    f.tester.frame();
    try testing.expectEqualStrings("nanoview", f.state.title());
    try f.write_png("a.png", 20, 10);
    try f.write_png("b.png", 20, 10);
    try f.open("a.png");
    try testing.expectEqualStrings("a.png", f.state.title());
    const Title = @import("settings.zig").Title;
    const cases = [_]struct { Title, []const u8 }{
        .{ .name_position, "a.png (1/2)" },
        .{ .full, "a.png (1/2) · 20×10 · 100%" },
        .{ .none, "nanoview" },
    };
    for (cases) |case| {
        f.state.settings.title = case[0];
        f.tester.frame();
        try testing.expectEqualStrings(case[1], f.state.title());
    }
    f.state.settings.title = .full;
    _ = f.tester.shortcut(.{ .key = '1' });
    _ = f.tester.shortcut(.{ .key = '=' });
    try testing.expectEqualStrings("a.png (1/2) · 20×10 · 125%", f.state.title());
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.right });
    try testing.expectEqualStrings("b.png (2/2) · 20×10 · 100%", f.state.title());
}

test "window_fit and the percentage bounds size the window" {
    var settings: @import("settings.zig").Settings = .{};
    const screen: [2]f64 = .{ 1000, 800 };
    const big = view.fitted_size(&settings, true, screen, .{ 3000, 2000 }).?;
    try testing.expectApproxEqAbs(@as(f64, 800), big[0], 0.001);
    try testing.expectApproxEqAbs(@as(f64, 533.333), big[1], 0.001);
    const small = view.fitted_size(&settings, true, screen, .{ 100, 100 }).?;
    try testing.expectEqual([2]f64{ 320, 240 }, small);
    settings.window_min_percent = 70;
    try testing.expectEqual([2]f64{ 800, 560 }, view.fitted_size(&settings, true, screen, .{
        3000, 2000,
    }).?);
    settings.window_fit = .first;
    try testing.expect(view.fitted_size(&settings, false, screen, .{ 100, 100 }) != null);
    try testing.expect(view.fitted_size(&settings, true, screen, .{ 100, 100 }) == null);
    settings.window_fit = .never;
    try testing.expect(view.fitted_size(&settings, false, screen, .{ 100, 100 }) == null);
}

test "the background setting colors the window behind the picture" {
    const f = try Fixture.create();
    defer f.destroy();
    f.state.settings.background = .{ .color = .{ .r = 255, .g = 0, .b = 0 } };
    f.tester.frame();
    const pixels = try f.tester.render(testing.allocator);
    defer pixels.deinit(testing.allocator);
    // BGRA, at the top left corner, away from the hint text.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, pixels.bytes[0..4]);
}

test "t toggles always on top and says so" {
    const f = try Fixture.create();
    defer f.destroy();
    _ = f.tester.shortcut(.{ .key = 't' });
    try testing.expect(f.state.settings.always_on_top);
    try testing.expect(f.tester.containsText("Always on top: on"));
    _ = f.tester.shortcut(.{ .key = 't' });
    try testing.expect(f.tester.containsText("Always on top: off"));
}

test "the sort setting orders the folder" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.write_png("a.png", 4, 4);
    try f.write_png("b.png", 64, 64);
    try f.write_png("c.png", 16, 16);
    f.state.settings.sort = .size;
    f.state.settings.sort_descending = true;
    try f.open("a.png");
    try testing.expectEqualStrings("b.png", f.state.folder.name(0));
    try testing.expectEqualStrings("a.png", f.state.folder.name(2));
    try testing.expectEqual(@as(?u32, 2), f.state.index);
    f.state.settings.sort = .random;
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.f(5) });
    try testing.expectEqual(@as(u32, 3), f.state.folder.count);
    try testing.expectEqualStrings("a.png", f.state.folder.name(f.state.index.?));
}

test "opening a picture records it in the recent file" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.write_png("a.png", 4, 4);
    try f.write_png("b.png", 4, 4);
    var buf: [paths.path_max]u8 = undefined;
    const state_dir = paths.join(f.dir_buf[0..f.dir_len], "state", &buf).?;
    f.state.load_recent(state_dir);
    try testing.expectEqual(@as(u32, 0), f.state.recent_count());
    try f.open("a.png");
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.right });
    try f.open("b.png");
    try testing.expectEqual(@as(u32, 2), f.state.recent_count());
    try testing.expect(std.mem.endsWith(u8, f.state.recent(0).?, "b.png"));
    try testing.expect(std.mem.endsWith(u8, f.state.recent(1).?, "a.png"));
    try testing.expect(f.state.recent(2) == null);
    var bytes: [2 * paths.path_max]u8 = undefined;
    const saved = try f.tmp.dir.readFile(testing.io, "state/recent", &bytes);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, saved, "\n"));
    f.state.clear_recent();
    try testing.expectEqual(@as(u32, 0), f.state.recent_count());
    const cleared = try f.tmp.dir.readFile(testing.io, "state/recent", &bytes);
    try testing.expectEqual(@as(usize, 0), cleared.len);
    f.state.settings.recent = false;
    try f.open("a.png");
    try testing.expectEqual(@as(u32, 0), f.state.recent_count());
}

fn expect_file(f: *Fixture, name: []const u8, data: ?[]const u8) !void {
    var buf: [64]u8 = undefined;
    const read = f.tmp.dir.readFile(testing.io, name, &buf);
    if (data) |d| try testing.expectEqualStrings(d, try read) else {
        try testing.expectError(error.FileNotFound, read);
    }
}

/// F2, then the whole name replaced by `name`, then Enter.
fn rename_to(f: *Fixture, name: []const u8) void {
    if (!f.state.rename_open) _ = f.tester.shortcut(.{ .key = ui.Shortcut.f(2) });
    f.tester.textOps(&.{.{ .command = .select_all }});
    if (name.len == 0) f.tester.textOps(&.{.{ .command = .delete_backward }});
    f.tester.typeText(name);
    f.tester.key(.enter);
}

test "F2 renames the file on disk and sorts it into place" {
    const f = try Fixture.create();
    defer f.destroy();
    for ([_][]const u8{ "a.png", "c.png", "d.png" }) |n| try f.write_png(n, 4, 4);
    try f.open("a.png");
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.f(2) });
    try testing.expect(f.state.rename_open);
    // The stem is selected: typing replaces it and keeps the extension.
    f.tester.typeText("e");
    try testing.expectEqualStrings("e.png", f.state.rename_buffer.text());
    f.tester.key(.enter);
    try testing.expect(!f.state.rename_open);
    try expect_file(f, "a.png", null);
    try testing.expectEqualStrings("e.png", f.state.basename());
    try testing.expectEqual(@as(?u32, 2), f.state.index);
    try testing.expectEqualStrings("c.png", f.state.folder.name(0));
    try testing.expectEqualStrings("e.png", f.state.folder.name(2));
    try testing.expectEqual(app.Status.shown, f.state.status);
    try testing.expect(f.tester.containsText("Renamed a.png to e.png"));
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.right });
    try testing.expectEqualStrings("c.png", f.state.basename());
}

test "a bad new name says why and leaves the file and the field" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "a.png", .data = "picture" });
    try f.open("a.png");
    const long: [300]u8 = @splat('x');
    const cases = [_][2][]const u8{
        .{ "", "The name is empty" },
        .{ "b/c.png", "A name cannot contain a slash" },
        .{ "..", "A name cannot be . or .." },
        .{ &long, "The name is too long" },
    };
    for (cases) |case| {
        rename_to(f, case[0]);
        try testing.expect(f.tester.containsText(case[1]));
        try testing.expect(f.state.rename_open);
        try expect_file(f, "a.png", "picture");
    }
    try testing.expectEqualStrings("a.png", f.state.basename());
}

test "rename refuses to replace another file" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "a.png", .data = "first" });
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "b.png", .data = "second" });
    try f.open("a.png");
    rename_to(f, "b.png");
    try testing.expect(f.tester.containsText("b.png already exists"));
    try expect_file(f, "a.png", "first");
    try expect_file(f, "b.png", "second");
    try testing.expectEqualStrings("a.png", f.state.basename());
}

test "Escape closes the rename field and keeps the name" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.write_png("a.png", 4, 4);
    try f.open("a.png");
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.f(2) });
    f.tester.typeText("zzz");
    f.tester.key(.escape);
    try testing.expect(!f.state.rename_open);
    try expect_file(f, "zzz.png", null);
    try testing.expectEqualStrings("a.png", f.state.basename());
}

test "keys typed into the rename field run no actions" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.write_png("a.png", 20, 10);
    try f.write_png("b.png", 20, 10);
    try f.open("a.png");
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.f(2) });
    try testing.expect(!f.tester.shortcut(.{ .key = 'r' }));
    try testing.expect(!f.tester.shortcut(.{ .key = ui.Shortcut.right }));
    f.tester.typeText("r");
    f.tester.key(.right);
    try testing.expectEqualStrings("r.png", f.state.rename_buffer.text());
    try testing.expectEqual(@as(u2, 0), f.state.turns_user);
    try testing.expectEqual(@as(f32, 20), f.state.viewport.image_w);
    try testing.expectEqualStrings("a.png", f.state.basename());
    try testing.expect(f.state.rename_open);
}

test "cmd+z restores the newest trashed file and shows it, then has nothing left" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.write_png("a.png", 4, 4);
    try f.open("a.png");
    const restore: ui.Shortcut = .{ .key = 'z', .cmd = true };
    if (builtin.os.tag == .windows) {
        _ = f.tester.shortcut(restore);
        return testing.expect(f.tester.containsText("Restore is not available on Windows"));
    }
    // A stand-in for the Trash, so the test never touches the real one.
    try f.tmp.dir.createDirPath(testing.io, "files");
    try f.write_png("files/b.png", 6, 4);
    var location_buf: [paths.path_max]u8 = undefined;
    var original_buf: [paths.path_max]u8 = undefined;
    const dir = f.dir_buf[0..f.dir_len];
    f.state.trashed.push(
        paths.join(dir, "b.png", &original_buf).?,
        paths.join(dir, "files/b.png", &location_buf).?,
    );
    _ = f.tester.shortcut(restore);
    try testing.expect(f.tester.containsText("Restored b.png"));
    try testing.expectEqualStrings("b.png", f.state.basename());
    try testing.expectEqual(@as(f32, 6), f.state.viewport.image_w);
    try testing.expectEqual(@as(u32, 2), f.state.folder.count);
    _ = f.tester.shortcut(restore);
    try testing.expect(f.tester.containsText("Nothing to restore"));
}

test "cmd+v opens pasted file paths and file URLs like a drop" {
    const f = try Fixture.create();
    defer f.destroy();
    for ([_][]const u8{ "a.png", "b.png" }) |n| try f.write_png(n, 4, 4);
    var buf: [paths.path_max]u8 = undefined;
    const b = paths.join(f.dir_buf[0..f.dir_len], "b.png", &buf).?;
    var text_buf: [paths.path_max + 16]u8 = undefined;
    pasted.text = try std.fmt.bufPrint(&text_buf, "file://{s}\n", .{b});
    _ = f.tester.shortcut(.{ .key = 'v', .cmd = true });
    try testing.expectEqualStrings("b.png", f.state.basename());
    try testing.expectEqual(@as(u32, 2), f.state.folder.count);
    pasted = .{ .files = &.{paths.join(f.dir_buf[0..f.dir_len], "a.png", &buf).?} };
    _ = f.tester.shortcut(.{ .key = 'v', .cmd = true });
    try testing.expectEqualStrings("a.png", f.state.basename());
}

test "a pasted picture shows as Clipboard, steps nowhere, and is not a file" {
    const f = try Fixture.create();
    defer f.destroy();
    for ([_][]const u8{ "a.png", "b.png" }) |n| try f.write_png(n, 4, 4);
    try f.open("a.png");
    const pixels = try testing.allocator.alloc(u8, 6 * 4 * 4);
    defer testing.allocator.free(pixels);
    @memset(pixels, 0x80);
    const png = try ui.png.encode(testing.allocator, .{ .bytes = pixels, .width = 6, .height = 4 });
    defer testing.allocator.free(png);
    pasted = .{ .text = "just words", .image = png };
    _ = f.tester.shortcut(.{ .key = 'v', .cmd = true });
    f.tester.frame();
    try testing.expectEqual(app.Status.shown, f.state.status);
    try testing.expectEqualStrings("Clipboard", f.state.basename());
    try testing.expectEqual(@as(f32, 6), f.state.viewport.image_w);
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.right });
    try testing.expectEqualStrings("Clipboard", f.state.basename());
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.forward_delete });
    try testing.expect(f.tester.containsText("This picture is not a file"));
    f.tester.advance(5);
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.f(2) });
    try testing.expect(f.tester.containsText("This picture is not a file"));
    try testing.expect(!f.state.rename_open);
}

test "a pasted picture saves as PNG, has no EXIF or pages, and nothing crashes" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.tmp.dir.writeFile(testing.io, .{
        .sub_path = "a.jpeg",
        .data = @embedFile("testdata/exif.jpeg"),
    });
    try f.open("a.jpeg");
    _ = f.tester.shortcut(.{ .key = 'e' });
    try testing.expect(!f.tester.containsText("No EXIF data"));
    const pixels = try testing.allocator.alloc(u8, 6 * 4 * 4);
    defer testing.allocator.free(pixels);
    @memset(pixels, 0x80);
    const png = try ui.png.encode(testing.allocator, .{ .bytes = pixels, .width = 6, .height = 4 });
    defer testing.allocator.free(png);
    pasted = .{ .image = png };
    _ = f.tester.shortcut(.{ .key = 'v', .cmd = true });
    f.tester.frame();
    // The panel does not keep the file's details, and reopening it reads no file.
    try testing.expect(f.tester.containsText("No EXIF data"));
    _ = f.tester.shortcut(.{ .key = 'e' });
    _ = f.tester.shortcut(.{ .key = 'e' });
    try testing.expect(f.tester.containsText("No EXIF data"));
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.down, .alt = true });
    try testing.expectEqual(app.Status.shown, f.state.status);
    var buf: [paths.path_max]u8 = undefined;
    const target = paths.join(f.dir_buf[0..f.dir_len], "out.png", &buf).?;
    @import("save.zig").save_to(f.state, target);
    f.tester.frame();
    try testing.expect(f.tester.containsText("Saved out.png"));
    try f.open("out.png");
    try testing.expectEqual(@as(f32, 6), f.state.viewport.image_w);
}

test "pasting with no picture on the clipboard says so" {
    const f = try Fixture.create();
    defer f.destroy();
    _ = f.tester.shortcut(.{ .key = 'v', .cmd = true });
    try testing.expect(f.tester.containsText("The clipboard holds no picture"));
    try testing.expectEqual(app.Status.empty, f.state.status);
}

const anim_fixtures = @import("wuffs_fixtures.zig");
const bgra_red = [4]u8{ 0, 0, 255, 255 };
const bgra_green = [4]u8{ 0, 255, 0, 255 };
const bgra_blue = [4]u8{ 255, 0, 0, 255 };

fn gif_dot(indices: []const u8, delay_cs: u16) anim_fixtures.GifFrame {
    return .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
        .delay_cs = delay_cs,
        .disposal = 1,
        .transparent = null,
        .indices = indices,
    };
}

/// Red for 0.3 s, green for 0.6 s, blue for 0.9 s; the NETSCAPE count 1 is two plays.
const gif_three = anim_fixtures.gif(1, 1, .{
    .{ 255, 0, 0 },
    .{ 0, 255, 0 },
    .{ 0, 0, 255 },
    .{ 0, 0, 0 },
}, 1, &.{ gif_dot(&.{0}, 30), gif_dot(&.{1}, 60), gif_dot(&.{2}, 90) });

/// Red for 0.1 s, then blue for 0.2 s, played once.
const apng_two = anim_fixtures.apng(1, 1, 1, &.{
    .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
        .delay_num = 1,
        .delay_den = 10,
        .dispose = 0,
        .blend = 0,
        .pixels = &.{.{ 255, 0, 0, 255 }},
    },
    .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
        .delay_num = 2,
        .delay_den = 10,
        .dispose = 0,
        .blend = 0,
        .pixels = &.{.{ 0, 0, 255, 255 }},
    },
});

fn shown_pixel(f: *Fixture, index: usize) [4]u8 {
    return f.state.source.pixels.bgra[index * 4 ..][0..4].*;
}

/// Runs frames until `seconds` after `start` on the tester's clock.
fn wait_until(f: *Fixture, start: f64, seconds: f64) void {
    const left = start + seconds - f.tester.time;
    if (left > 0) f.tester.advance(@floatCast(left));
}

fn write_file(f: *Fixture, name: []const u8, data: []const u8) !void {
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = data });
}

test "a GIF shows each frame for its delay and stops after its plays" {
    const f = try Fixture.create();
    defer f.destroy();
    try write_file(f, "a.gif", gif_three);
    f.state.settings.fit_upscale = true;
    const start = f.tester.time;
    try f.open("a.gif");
    try testing.expect(f.state.player.active());
    const timeline = [_]struct { f64, [4]u8 }{
        .{ 0.15, bgra_red }, .{ 0.6, bgra_green }, .{ 1.35, bgra_blue },
        .{ 1.95, bgra_red }, .{ 2.4, bgra_green }, .{ 3.5, bgra_blue },
        .{ 6.0, bgra_blue },
    };
    var key_bufs: [timeline.len][16]u8 = undefined;
    var keys: [timeline.len][]const u8 = undefined;
    for (timeline, 0..) |point, i| {
        wait_until(f, start, point[0]);
        try testing.expectEqualSlices(u8, &point[1], &shown_pixel(f, 0));
        keys[i] = f.state.picture_key(&key_bufs[i]);
    }
    try testing.expect(f.state.player.finished and !f.state.player.playing);
    // Each new frame has its own key: nanoui would show the cached frame otherwise.
    for (keys[0..5], keys[1..6]) |a, b| try testing.expect(!std.mem.eql(u8, a, b));
    try testing.expectEqualStrings(keys[5], keys[6]);
    const pixels = try f.tester.render(testing.allocator);
    defer pixels.deinit(testing.allocator);
    const center = (pixels.height / 2 * pixels.width + pixels.width / 2) * 4;
    // The offscreen renderer converts colors slightly.
    const drawn = pixels.bytes[center..][0..4];
    try testing.expect(drawn[0] > 240 and drawn[1] < 16 and drawn[2] < 16);
    _ = f.tester.shortcut(.{ .key = 'i' });
    try testing.expect(f.tester.containsText("frame 3/3"));
}

test "pause holds the frame, next frame steps and wraps, speed says so" {
    const f = try Fixture.create();
    defer f.destroy();
    try write_file(f, "a.gif", gif_three);
    const start = f.tester.time;
    try f.open("a.gif");
    wait_until(f, start, 0.6);
    _ = f.tester.shortcut(.{ .key = 'k' });
    try testing.expect(f.tester.containsText("Paused"));
    wait_until(f, start, 3);
    try testing.expectEqualSlices(u8, &bgra_green, &shown_pixel(f, 0));
    _ = f.tester.shortcut(.{ .key = 'i' });
    try testing.expect(f.tester.containsText("frame 2, paused"));
    _ = f.tester.shortcut(.{ .key = '.' });
    try testing.expectEqualSlices(u8, &bgra_blue, &shown_pixel(f, 0));
    _ = f.tester.shortcut(.{ .key = '.' });
    try testing.expectEqualSlices(u8, &bgra_red, &shown_pixel(f, 0));
    try testing.expect(f.tester.containsText("frame 1/3, paused"));
    _ = f.tester.shortcut(.{ .key = 'k' });
    try testing.expect(f.tester.containsText("Playing"));
    const resumed = f.tester.time;
    wait_until(f, resumed, 0.2);
    try testing.expectEqualSlices(u8, &bgra_red, &shown_pixel(f, 0));
    wait_until(f, resumed, 0.4);
    try testing.expectEqualSlices(u8, &bgra_green, &shown_pixel(f, 0));
    _ = f.tester.shortcut(.{ .key = ']' });
    try testing.expect(f.tester.containsText("Speed 125%"));
    _ = f.tester.shortcut(.{ .key = '[' });
    _ = f.tester.shortcut(.{ .key = '[' });
    try testing.expect(f.tester.containsText("Speed 75%"));
}

test "stepping away stops an animation and coming back restarts it" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.write_png("a.png", 4, 4);
    try write_file(f, "b.gif", gif_three);
    try f.open("a.png");
    f.state.preload.set_bounds(960, 720);
    _ = drain(&f.state.preload);
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.right });
    // The preloaded first frame cannot play: the file is read again.
    try testing.expect(f.state.player.active());
    var start = f.tester.time;
    wait_until(f, start, 0.6);
    try testing.expectEqualSlices(u8, &bgra_green, &shown_pixel(f, 0));
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.right });
    try testing.expectEqualStrings("a.png", f.state.basename());
    try testing.expect(!f.state.player.active());
    _ = f.tester.shortcut(.{ .key = 'k' });
    try testing.expect(f.tester.containsText("Not an animation"));
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.left });
    try testing.expect(f.state.player.active());
    try testing.expectEqualSlices(u8, &bgra_red, &shown_pixel(f, 0));
    start = f.tester.time;
    wait_until(f, start, 0.15);
    try testing.expectEqualSlices(u8, &bgra_red, &shown_pixel(f, 0));
    wait_until(f, start, 0.6);
    try testing.expectEqualSlices(u8, &bgra_green, &shown_pixel(f, 0));
}

test "an animated WebP and an APNG play their frames and loop counts" {
    const f = try Fixture.create();
    defer f.destroy();
    try write_file(f, "a.webp", @embedFile("testdata/webp_anim.webp"));
    try write_file(f, "b.png", apng_two);
    // Two frames of 0.1 s and 0.25 s, three plays.
    var start = f.tester.time;
    try f.open("a.webp");
    try testing.expect(f.state.player.active());
    const webp_timeline = [_]struct { f64, [4]u8 }{
        .{ 0.05, bgra_red }, .{ 0.25, bgra_blue }, .{ 0.4, bgra_red },
        .{ 0.6, bgra_blue }, .{ 2.0, bgra_blue },
    };
    for (webp_timeline) |point| {
        wait_until(f, start, point[0]);
        try testing.expectEqualSlices(u8, &bgra_red, &shown_pixel(f, 0));
        try testing.expectEqualSlices(u8, &point[1], &shown_pixel(f, 1));
    }
    try testing.expect(f.state.player.finished);
    _ = f.tester.shortcut(.{ .key = 'i' });
    try testing.expect(f.tester.containsText("frame 2/2"));
    start = f.tester.time;
    try f.open("b.png");
    try testing.expect(f.state.player.active());
    try testing.expectEqualSlices(u8, &bgra_red, &shown_pixel(f, 0));
    wait_until(f, start, 0.2);
    try testing.expectEqualSlices(u8, &bgra_blue, &shown_pixel(f, 0));
    wait_until(f, start, 1.0);
    try testing.expectEqualSlices(u8, &bgra_blue, &shown_pixel(f, 0));
    try testing.expect(f.state.player.finished);
}

test "animation off and a picture over the limit show the first frame" {
    const f = try Fixture.create();
    defer f.destroy();
    try write_file(f, "a.gif", gif_three);
    f.state.settings.animation = false;
    try f.open("a.gif");
    try testing.expectEqual(app.Status.shown, f.state.status);
    try testing.expect(!f.state.player.active());
    f.state.settings.animation = true;
    const wide = comptime anim_fixtures.gif(4097, 4096, .{
        .{ 255, 0, 0 },
        .{ 0, 255, 0 },
        .{ 0, 0, 255 },
        .{ 0, 0, 0 },
    }, 0, &.{ gif_dot(&.{0}, 10), gif_dot(&.{1}, 10) });
    try write_file(f, "b.gif", wide);
    try f.open("b.gif");
    try testing.expect(!f.state.player.active());
    try testing.expect(f.tester.containsText("Too large to animate"));
}

const TiffPage = struct { width: u16, height: u16, rgb: [3]u8 };

fn put_le(out: *std.ArrayList(u8), comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try out.appendSlice(testing.allocator, &bytes);
}

fn tiff_entry(out: *std.ArrayList(u8), tag: u16, kind: u16, count: u32, value: u32) !void {
    try put_le(out, u16, tag);
    try put_le(out, u16, kind);
    try put_le(out, u32, count);
    if (kind == 3 and count == 1) {
        try put_le(out, u16, @intCast(value));
        try put_le(out, u16, 0);
    } else try put_le(out, u32, value);
}

/// An uncompressed RGB TIFF with one solid page per entry. Each page is its bits per
/// sample, one strip and its directory.
fn tiff_pages(pages_in: []const TiffPage) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    const ifd_len: u32 = 2 + 9 * 12 + 4;
    var starts: [4]u32 = undefined;
    var ifds: [4]u32 = undefined;
    var at: u32 = 8;
    for (pages_in, 0..) |p, i| {
        const n = @as(u32, p.width) * p.height * 3;
        starts[i] = at;
        ifds[i] = at + 6 + n + n % 2;
        at = ifds[i] + ifd_len;
    }
    try out.appendSlice(testing.allocator, "II*\x00");
    try put_le(&out, u32, ifds[0]);
    for (pages_in, 0..) |p, i| {
        const n = @as(u32, p.width) * p.height * 3;
        for (0..3) |_| try put_le(&out, u16, 8);
        for (0..n / 3) |_| try out.appendSlice(testing.allocator, &p.rgb);
        if (n % 2 == 1) try out.append(testing.allocator, 0);
        try testing.expectEqual(ifds[i], out.items.len);
        try put_le(&out, u16, 9);
        try tiff_entry(&out, 256, 3, 1, p.width);
        try tiff_entry(&out, 257, 3, 1, p.height);
        try tiff_entry(&out, 258, 3, 3, starts[i]);
        try tiff_entry(&out, 259, 3, 1, 1);
        try tiff_entry(&out, 262, 3, 1, 2);
        try tiff_entry(&out, 273, 4, 1, starts[i] + 6);
        try tiff_entry(&out, 277, 3, 1, 3);
        try tiff_entry(&out, 278, 3, 1, p.height);
        try tiff_entry(&out, 279, 4, 1, n);
        try put_le(&out, u32, if (i + 1 == pages_in.len) 0 else ifds[i + 1]);
    }
    return out.toOwnedSlice(testing.allocator);
}

fn solid_png(side: usize, bgra: [4]u8) ![]u8 {
    var pixels: [32 * 32][4]u8 = undefined;
    std.debug.assert(side <= 32);
    @memset(pixels[0 .. side * side], bgra);
    return ui.png.encode(testing.allocator, .{
        .bytes = @ptrCast(pixels[0 .. side * side]),
        .width = side,
        .height = side,
    });
}

/// An icon whose sizes are PNG pictures.
fn ico_sizes(sides: []const u8, pngs: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    try put_le(&out, u16, 0);
    try put_le(&out, u16, 1);
    try put_le(&out, u16, @intCast(pngs.len));
    var offset: u32 = @intCast(6 + 16 * pngs.len);
    for (sides, pngs) |side, png| {
        try out.appendSlice(testing.allocator, &.{ side, side, 0, 0 });
        try put_le(&out, u16, 1);
        try put_le(&out, u16, 32);
        try put_le(&out, u32, @intCast(png.len));
        try put_le(&out, u32, offset);
        offset += @intCast(png.len);
    }
    for (pngs) |png| try out.appendSlice(testing.allocator, png);
    return out.toOwnedSlice(testing.allocator);
}

test "pages of a TIFF and sizes of an icon turn with page down and page up" {
    if (builtin.os.tag == .linux) return error.SkipZigTest; // gdk-pixbuf reads page 1 only
    const f = try Fixture.create();
    defer f.destroy();
    const tiff = try tiff_pages(&.{
        .{ .width = 4, .height = 2, .rgb = .{ 255, 0, 0 } },
        .{ .width = 3, .height = 5, .rgb = .{ 0, 0, 255 } },
    });
    defer testing.allocator.free(tiff);
    try write_file(f, "a.tif", tiff);
    try f.open("a.tif");
    try testing.expect(f.tester.containsText("Page 1 of 2"));
    _ = f.tester.shortcut(.{ .key = 'i' });
    try testing.expect(f.tester.containsText("4×2"));
    try testing.expect(f.tester.containsText("page 1/2"));
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.down, .alt = true });
    try testing.expect(f.tester.containsText("Page 2 of 2"));
    try testing.expect(f.tester.containsText("3×5"));
    try testing.expectEqualSlices(u8, &bgra_blue, &shown_pixel(f, 14));
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.down, .alt = true });
    try testing.expect(f.tester.containsText("page 2/2"));
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.up, .alt = true });
    try testing.expect(f.tester.containsText("Page 1 of 2"));
    try testing.expect(f.tester.containsText("4×2"));
    const red = try solid_png(32, bgra_red);
    defer testing.allocator.free(red);
    const blue = try solid_png(16, bgra_blue);
    defer testing.allocator.free(blue);
    const ico = try ico_sizes(&.{ 32, 16 }, &.{ red, blue });
    defer testing.allocator.free(ico);
    try write_file(f, "b.ico", ico);
    try f.open("b.ico");
    try testing.expectEqual(@as(u32, 2), f.state.page_count);
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.down, .alt = true });
    // ImageIO reads no icon size under 16 pixels.
    try testing.expect(f.tester.containsText("16×16"));
    try testing.expectEqualSlices(u8, &bgra_blue, &shown_pixel(f, 255));
    // Another picture starts at its first page; a single picture has none to turn.
    try f.write_png("c.png", 2, 2);
    try f.open("c.png");
    try testing.expect(!f.tester.containsText("page "));
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.down, .alt = true });
    try testing.expect(f.tester.containsText("Single page"));
    try f.open("a.tif");
    try testing.expectEqual(@as(u32, 0), f.state.page);
}

/// Opaque red twice, then half-transparent blue beside opaque green.
const apng_alpha = anim_fixtures.apng(2, 1, 0, &.{
    .{
        .x = 0,
        .y = 0,
        .width = 2,
        .height = 1,
        .delay_num = 1,
        .delay_den = 10,
        .dispose = 0,
        .blend = 0,
        .pixels = &.{ .{ 255, 0, 0, 255 }, .{ 255, 0, 0, 255 } },
    },
    .{
        .x = 0,
        .y = 0,
        .width = 2,
        .height = 1,
        .delay_num = 1,
        .delay_den = 10,
        .dispose = 0,
        .blend = 0,
        .pixels = &.{ .{ 0, 0, 255, 128 }, .{ 0, 255, 0, 255 } },
    },
});

fn saved_path(f: *Fixture, name: []const u8, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ f.dir_buf[0..f.dir_len], name }) catch unreachable;
}

test "save frame writes the shown frame unrotated and it reads back the same" {
    const f = try Fixture.create();
    defer f.destroy();
    try write_file(f, "a.png", apng_alpha);
    try f.open("a.png");
    _ = f.tester.shortcut(.{ .key = '.' });
    try testing.expectEqual(@as(u32, 1), f.state.player.frame_index);
    var shown: [8]u8 = undefined;
    @memcpy(&shown, f.state.player.canvas()[0..8]);
    _ = f.tester.shortcut(.{ .key = 'r' });
    var path_buf: [paths.path_max]u8 = undefined;
    save_mod.save_to(f.state, saved_path(f, "frame.png", &path_buf));
    f.tester.frame();
    try testing.expect(f.tester.containsText("Saved frame.png"));
    const gpa = testing.allocator;
    const bytes = try f.tmp.dir.readFileAlloc(testing.io, "frame.png", gpa, .unlimited);
    defer testing.allocator.free(bytes);
    try testing.expect(animation.detect(bytes) == null);
    var back: [8]u8 = undefined;
    const size = try decode.decode_fit(bytes, &back, 100, 100, 0);
    try testing.expectEqual(@as(u32, 2), size.width);
    try testing.expectEqual(@as(u32, 1), size.height);
    for (shown, back) |a, b| try testing.expect(@abs(@as(i16, a) - b) <= 1);
    try testing.expect(back[3] == 128 and back[0] >= 127); // blue kept its alpha
    try f.open("frame.png");
    try testing.expectEqual(app.Status.shown, f.state.status);
    _ = f.tester.shortcut(.{ .key = 'i' });
    try testing.expect(f.tester.containsText("2×1"));
    // A still that nanoui decodes is read again at full size.
    try f.write_png("white.png", 4, 3);
    try f.open("white.png");
    save_mod.save_to(f.state, saved_path(f, "white copy.png", &path_buf));
    const copy = try f.tmp.dir.readFileAlloc(testing.io, "white copy.png", gpa, .unlimited);
    defer testing.allocator.free(copy);
    var white: [4 * 3 * 4]u8 = undefined;
    const copy_size = try decode.decode_fit(copy, &white, 100, 100, 0);
    try testing.expectEqual(@as(u32, 4), copy_size.width);
    try testing.expect(std.mem.allEqual(u8, &white, 0xff));
    save_mod.save_to(f.state, "/nonexistent directory/x.png");
    f.tester.frame();
    try testing.expect(f.tester.containsText("Cannot save the frame"));
}

test "a finished play-once GIF restarts and stepping shows paused" {
    const f = try Fixture.create();
    defer f.destroy();
    const once = comptime anim_fixtures.gif(1, 1, .{
        .{ 255, 0, 0 }, .{ 0, 255, 0 }, .{ 0, 0, 255 }, .{ 0, 0, 0 },
    }, null, &.{ gif_dot(&.{0}, 10), gif_dot(&.{1}, 10) });
    try write_file(f, "once.gif", once);
    try f.open("once.gif");
    f.tester.advance(0.4);
    try testing.expect(f.state.player.finished);
    _ = f.tester.shortcut(.{ .key = 'k' });
    try testing.expectEqualSlices(u8, &bgra_red, &shown_pixel(f, 0));
    f.tester.advance(0.15);
    try testing.expectEqualSlices(u8, &bgra_green, &shown_pixel(f, 0));
    f.tester.advance(0.2);
    try testing.expect(f.state.player.finished);
    _ = f.tester.shortcut(.{ .key = '.' });
    _ = f.tester.shortcut(.{ .key = 'i' });
    try testing.expectEqualSlices(u8, &bgra_red, &shown_pixel(f, 0));
    try testing.expect(f.tester.containsText("frame 1/2, paused"));
}

test "save failure cannot truncate an existing destination" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const f = try Fixture.create();
    defer f.destroy();
    try f.write_png("a.png", 4, 3);
    try f.open("a.png");
    try write_file(f, "existing.png", "original bytes");
    var buf: [paths.path_max]u8 = undefined;
    const target = saved_path(f, "existing.png", &buf);
    // Existing file is writable, but the directory cannot create the temporary PNG.
    try f.tmp.dir.setPermissions(testing.io, .fromMode(0o500));
    defer f.tmp.dir.setPermissions(testing.io, .fromMode(0o700)) catch unreachable;
    save_mod.save_to(f.state, target);
    f.tester.frame();
    try testing.expect(f.tester.containsText("Cannot save the frame"));
    var back: [64]u8 = undefined;
    const bytes = try f.tmp.dir.readFile(testing.io, "existing.png", &back);
    try testing.expectEqualStrings("original bytes", bytes);
}

test "an oversized single-frame GIF does not warn about animation" {
    const f = try Fixture.create();
    defer f.destroy();
    const palette = .{ .{ 255, 0, 0 }, .{ 0, 255, 0 }, .{ 0, 0, 255 }, .{ 0, 0, 0 } };
    const single = comptime anim_fixtures.gif(4097, 4096, palette, null, &.{gif_dot(&.{0}, 10)});
    const multi = comptime anim_fixtures.gif(4097, 4096, palette, null, &.{
        gif_dot(&.{0}, 10), gif_dot(&.{1}, 10),
    });
    const playback = @import("playback.zig");
    try testing.expect(!animation.multiple_frames(single));
    try testing.expect(animation.multiple_frames(multi));
    for (6..single.len) |n| try testing.expect(!animation.multiple_frames(single[0..n]));
    try testing.expect(!playback.play(f.state, single));
    try testing.expectEqual(@as(u32, 0), f.state.message_len);
    try testing.expect(!playback.play(f.state, multi));
    f.tester.frame();
    try testing.expect(f.tester.containsText("Too large to animate"));
}
