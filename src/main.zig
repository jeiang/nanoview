const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const app_state = @import("app.zig");
const view = @import("view.zig");
const State = app_state.State;

// About 1.2 MiB: never on the stack.
var state: State = undefined;

pub fn main(init: std.process.Init) !void {
    const app = try nanoui.App.create(init, .{ .name = "nanoview" });
    defer app.destroy();
    const file_buffer = try std.heap.page_allocator.alloc(u8, app_state.file_size_max);
    defer std.heap.page_allocator.free(file_buffer);
    state.init(init.io, init.gpa, file_buffer);
    app.onOpenFiles(&state, State.on_open_files);
    state.window = try app.newWindow(.{
        .title = "nanoview",
        .width = 800,
        .height = 600,
        .min_width = 320,
        .min_height = 240,
        .title_bar = if (builtin.os.tag == .macos) .hidden else .default,
        .content = .{ .view = .init(&state, view.view) },
    });
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    // The first argument that is not a flag (this skips `--nanoui-*`).
    for (args[@min(args.len, 1)..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--")) continue;
        state.open_path(arg);
        break;
    }
    try app.run();
}
