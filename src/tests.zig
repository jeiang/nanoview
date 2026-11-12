const std = @import("std");
const ui = @import("nanoui").ui;
const app = @import("app.zig");
const view = @import("view.zig");
const paths = @import("paths.zig");
const preload = @import("preload.zig");
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
}

/// A State and a Tester over it, on the heap: State is too large for the
/// stack. The large buffers stay untouched until used.
const Fixture = struct {
    state: *State,
    file_buffer: []u8,
    pool: []u8,
    scratch: []u8,
    tester: ui.Tester = undefined,
    tmp: std.testing.TmpDir,
    dir_buf: [paths.path_max]u8 = undefined,
    dir_len: usize = 0,

    fn create() !*Fixture {
        const f = try testing.allocator.create(Fixture);
        errdefer testing.allocator.destroy(f);
        const state = try testing.allocator.create(State);
        errdefer testing.allocator.destroy(state);
        f.* = .{
            .state = state,
            .file_buffer = try app.alloc_pages(app.file_size_max),
            .pool = try app.alloc_pages(preload.pool_bytes),
            .scratch = try app.alloc_pages(if (preload.decoded) app.file_size_max else 0),
            .tmp = testing.tmpDir(.{}),
        };
        state.init(testing.io, testing.allocator, f.file_buffer, f.pool, f.scratch);
        f.dir_len = try f.tmp.dir.realPathFile(testing.io, ".", &f.dir_buf);
        try f.tester.init(testing.allocator, .init(state, view.view), .{
            .width = 480,
            .height = 360,
        });
        return f;
    }

    fn destroy(f: *Fixture) void {
        f.tester.deinit();
        f.tmp.cleanup();
        app.free_pages(f.file_buffer);
        app.free_pages(f.pool);
        app.free_pages(f.scratch);
        testing.allocator.destroy(f.state);
        testing.allocator.destroy(f);
    }

    fn write_png(f: *Fixture, name: []const u8, width: usize, height: usize) !void {
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

    fn open(f: *Fixture, name: []const u8) !void {
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
    f.tester.pinch(240, 180, 8, 0, 0);
    try testing.expect(f.state.source == .encoded);
    try testing.expect(!f.state.viewport.fit);
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
