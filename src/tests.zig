const std = @import("std");
const ui = @import("nanoui").ui;
const State = @import("app.zig").State;
const view = @import("view.zig");

test "the empty window shows the hint" {
    var s: State = undefined;
    s.init(std.testing.io);
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&s, view.view), .{ .width = 480, .height = 360 });
    defer t.deinit();
    try std.testing.expect(t.containsText("Drop an image"));
}

test {
    _ = @import("viewport.zig");
    _ = @import("folder.zig");
    _ = @import("paths.zig");
    _ = @import("orientation.zig");
}
