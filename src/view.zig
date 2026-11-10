const builtin = @import("builtin");
const ui = @import("nanoui").ui;
const State = @import("app.zig").State;

const hint = if (builtin.os.tag == .macos)
    "Drop an image, or press ⌘O"
else
    "Drop an image, or press Ctrl+O";

pub fn view(s: *State, c: *ui.Context) void {
    const root = ui.div(c).sizeFull().center().bg(c.theme.background);
    defer root.end();
    if (s.status == .empty) ui.text(c, hint, .{ .color = c.theme.muted });
}
