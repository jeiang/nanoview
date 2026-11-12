//! Every command a key can run, and the keys that run them. `view.perform`
//! carries each one out.
const std = @import("std");
const ui = @import("nanoui").ui;

pub const Action = enum {
    open,
    next,
    previous,
    zoom_in,
    zoom_out,
    fit,
    actual,
    full_screen,
    leave_full_screen,
    rotate_right,
    rotate_left,
    info,
    trash,
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
    .{ .shortcut = .{ .key = '=' }, .action = .zoom_in },
    .{ .shortcut = .{ .key = '=', .shift = true }, .action = .zoom_in },
    .{ .shortcut = .{ .key = '+' }, .action = .zoom_in },
    .{ .shortcut = .{ .key = '-' }, .action = .zoom_out },
    .{ .shortcut = .{ .key = '0' }, .action = .fit },
    .{ .shortcut = .{ .key = '1' }, .action = .actual },
    .{ .shortcut = .{ .key = 'f' }, .action = .full_screen },
    .{ .shortcut = .{ .key = key.escape }, .action = .leave_full_screen },
    .{ .shortcut = .{ .key = 'r' }, .action = .rotate_right },
    .{ .shortcut = .{ .key = 'l' }, .action = .rotate_left },
    .{ .shortcut = .{ .key = 'i' }, .action = .info },
    .{ .shortcut = .{ .key = key.forward_delete }, .action = .trash },
    .{ .shortcut = .{ .key = key.backspace, .cmd = true }, .action = .trash },
    .{ .shortcut = .{ .key = 'r', .cmd = true }, .action = .reveal },
    .{ .shortcut = .{ .key = 'c', .cmd = true, .shift = true }, .action = .copy_path },
};

fn same(a: ui.Shortcut, b: ui.Shortcut) bool {
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
