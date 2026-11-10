const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const State = @import("app.zig").State;
const view = @import("view.zig");

// About a megabyte once the folder list lives here: never on the stack.
var state: State = undefined;

pub fn main(init: std.process.Init) !void {
    const app = try nanoui.App.create(init, .{ .name = "nanoview" });
    defer app.destroy();
    state.init(init.io);
    _ = try app.newWindow(.{
        .title = "nanoview",
        .width = 800,
        .height = 600,
        .min_width = 320,
        .min_height = 240,
        .title_bar = if (builtin.os.tag == .macos) .hidden else .default,
        .content = .{ .view = .init(&state, view.view) },
    });
    try app.run();
}
