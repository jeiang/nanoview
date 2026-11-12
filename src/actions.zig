//! Every command a key can run, and the keys that run them. `view.perform`
//! carries each one out.
const std = @import("std");
const ui = @import("nanoui").ui;

pub const Action = enum {
    open,
    next,
    previous,
    first,
    last,
    random,
    reload,
    slideshow,
    zoom_in,
    zoom_out,
    fit,
    actual,
    fit_upscale,
    fit_mode,
    smooth,
    zoom_lock,
    checkerboard,
    full_screen,
    always_on_top,
    leave_full_screen,
    rotate_right,
    rotate_left,
    mirror,
    flip,
    info,
    trash,
    confirm_trash,
    reveal,
    copy_path,
};

pub const Binding = struct { shortcut: ui.Shortcut, action: Action };

const key = ui.Shortcut;

/// `cmd` is Command on macOS and Control elsewhere.
pub const bindings = [_]Binding{
    .{ .shortcut = .{ .key = 'o', .cmd = true }, .action = .open },
    .{ .shortcut = .{ .key = key.right }, .action = .next },
    .{ .shortcut = .{ .key = key.left }, .action = .previous },
    .{ .shortcut = .{ .key = ' ' }, .action = .next },
    .{ .shortcut = .{ .key = ' ', .shift = true }, .action = .previous },
    .{ .shortcut = .{ .key = key.home }, .action = .first },
    .{ .shortcut = .{ .key = key.end }, .action = .last },
    .{ .shortcut = .{ .key = 'x' }, .action = .random },
    .{ .shortcut = .{ .key = key.f(5) }, .action = .reload },
    .{ .shortcut = .{ .key = 'r', .cmd = true, .shift = true }, .action = .reload },
    .{ .shortcut = .{ .key = 's' }, .action = .slideshow },
    .{ .shortcut = .{ .key = '=' }, .action = .zoom_in },
    .{ .shortcut = .{ .key = '=', .shift = true }, .action = .zoom_in },
    .{ .shortcut = .{ .key = '+' }, .action = .zoom_in },
    .{ .shortcut = .{ .key = '-' }, .action = .zoom_out },
    .{ .shortcut = .{ .key = '0' }, .action = .fit },
    .{ .shortcut = .{ .key = '1' }, .action = .actual },
    .{ .shortcut = .{ .key = 'u' }, .action = .fit_upscale },
    .{ .shortcut = .{ .key = 'w' }, .action = .fit_mode },
    .{ .shortcut = .{ .key = 'p' }, .action = .smooth },
    .{ .shortcut = .{ .key = 'z' }, .action = .zoom_lock },
    .{ .shortcut = .{ .key = 'b' }, .action = .checkerboard },
    .{ .shortcut = .{ .key = 'f' }, .action = .full_screen },
    .{ .shortcut = .{ .key = 't' }, .action = .always_on_top },
    .{ .shortcut = .{ .key = key.escape }, .action = .leave_full_screen },
    .{ .shortcut = .{ .key = 'r' }, .action = .rotate_right },
    .{ .shortcut = .{ .key = 'l' }, .action = .rotate_left },
    .{ .shortcut = .{ .key = 'm' }, .action = .mirror },
    .{ .shortcut = .{ .key = 'v' }, .action = .flip },
    .{ .shortcut = .{ .key = 'i' }, .action = .info },
    .{ .shortcut = .{ .key = key.forward_delete }, .action = .trash },
    .{ .shortcut = .{ .key = key.backspace, .cmd = true }, .action = .trash },
    .{ .shortcut = .{ .key = key.enter }, .action = .confirm_trash },
    .{ .shortcut = .{ .key = 'r', .cmd = true }, .action = .reveal },
    .{ .shortcut = .{ .key = 'c', .cmd = true, .shift = true }, .action = .copy_path },
};

pub fn same(a: ui.Shortcut, b: ui.Shortcut) bool {
    return a.key == b.key and a.cmd == b.cmd and a.ctrl == b.ctrl and a.alt == b.alt and
        a.shift == b.shift;
}

test "every action has a key and no key runs two actions" {
    var bound: [std.enums.values(Action).len]bool = @splat(false);
    for (bindings, 0..) |b, i| {
        bound[@backingInt(b.action)] = true;
        for (bindings[i + 1 ..]) |other| try std.testing.expect(!same(b.shortcut, other.shortcut));
    }
    for (bound) |has_key| try std.testing.expect(has_key);
}
