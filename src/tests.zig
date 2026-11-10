const std = @import("std");
const ui = @import("nanoui").ui;
const app = @import("app.zig");
const view = @import("view.zig");
const paths = @import("paths.zig");
const State = app.State;
const testing = std.testing;

test {
    _ = @import("viewport.zig");
    _ = @import("folder.zig");
    _ = @import("paths.zig");
    _ = @import("orientation.zig");
}

/// A State and a Tester over it, on the heap: State is too large for the stack.
const Fixture = struct {
    state: *State,
    file_buffer: []u8,
    tester: ui.Tester = undefined,
    tmp: std.testing.TmpDir,
    dir_buf: [paths.path_max]u8 = undefined,
    dir_len: usize = 0,

    fn create() !*Fixture {
        const f = try testing.allocator.create(Fixture);
        errdefer testing.allocator.destroy(f);
        const state = try testing.allocator.create(State);
        errdefer testing.allocator.destroy(state);
        const file_buffer = try testing.allocator.alloc(u8, app.file_size_max);
        f.* = .{ .state = state, .file_buffer = file_buffer, .tmp = testing.tmpDir(.{}) };
        state.init(testing.io, testing.allocator, file_buffer);
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
        testing.allocator.free(f.file_buffer);
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
