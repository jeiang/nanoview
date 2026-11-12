//! What menus show of each action: whether it applies now and whether it
//! is checked. Titles and groups are `actions.infos`.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const actions = @import("actions.zig");
const app = @import("app.zig");

const Action = actions.Action;
const State = app.State;

/// The state a checkable action turns on or off; null for the others.
pub fn checked(s: *const State, action: Action) ?bool {
    assert(s.settings.slideshow_seconds > 0);
    const on: ?bool = switch (action) {
        .fit_upscale => s.settings.fit_upscale,
        .smooth => s.settings.smooth,
        .zoom_lock => s.settings.zoom_lock,
        .checkerboard => s.settings.checkerboard,
        .always_on_top => s.settings.always_on_top,
        .mirror => s.mirror,
        .flip => s.flip,
        .slideshow => s.slideshow_running,
        .info => s.info_shown,
        .full_screen => full_screen(s),
        else => null,
    };
    assert(on == null or actions.infos.get(action).title.len > 0);
    return on;
}

/// Whether the action does anything now: menus leave out or disable the
/// others.
pub fn available(s: *const State, action: Action) bool {
    assert(s.status != .empty or s.folder.count == 0);
    switch (action) {
        .confirm_trash => return s.trash_pending,
        .leave_full_screen => return full_screen(s),
        .restore => return builtin.os.tag != .windows and s.trashed.top() != null,
        else => {},
    }
    return switch (actions.infos.get(action).needs) {
        .nothing => true,
        .picture => s.status == .shown,
        .file => s.status != .empty and s.is_file(),
        .folder => s.status != .empty and s.folder.count > 1,
    };
}

fn full_screen(s: *const State) bool {
    const w = s.window orelse return false;
    return w.isFullScreen();
}
