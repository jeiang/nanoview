const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const app_state = @import("app.zig");
const view = @import("view.zig");
const preload = @import("preload.zig");
const settings = @import("settings.zig");
const State = app_state.State;

// About 1.2 MiB: never on the stack.
var state: State = undefined;

pub fn main(init: std.process.Init) !void {
    const app = try nanoui.App.create(init, .{ .name = "nanoview" });
    defer app.destroy();
    const file_buffer = try app_state.alloc_pages(app_state.file_size_max);
    defer app_state.free_pages(file_buffer);
    const pool = try app_state.alloc_pages(preload.pool_bytes);
    defer app_state.free_pages(pool);
    const scratch_len = if (preload.decoded) app_state.file_size_max else 0;
    const scratch = try app_state.alloc_pages(scratch_len);
    defer app_state.free_pages(scratch);
    state.init(init.io, init.gpa, file_buffer, pool, scratch);
    load_settings(init);
    app.onOpenFiles(&state, State.on_open_files);
    state.window = try app.newWindow(.{
        .title = "nanoview",
        .icon = switch (builtin.os.tag) {
            .windows => @embedFile("nanoview.ico"),
            .linux => @embedFile("nanoview.png"),
            else => null,
        },
        .width = 800,
        .height = 600,
        .min_width = 320,
        .min_height = 240,
        .title_bar = if (builtin.os.tag == .macos) .hidden else .default,
        .content = .{ .view = .init(&state, view.view) },
    });
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    try state.preload.start();
    defer state.preload.stop();
    // The first argument that is not a flag (this skips `--nanoui-*`).
    for (args[@min(args.len, 1)..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--")) continue;
        state.open_path(arg);
        break;
    }
    try app.run();
}

fn load_settings(init: std.process.Init) void {
    const directory = settings.config_directory(init.gpa, init.environ_map) catch |err| {
        state.notify("settings.conf: {s}", .{@errorName(err)});
        return;
    };
    defer init.gpa.free(directory);
    state.load_settings(directory);
}
