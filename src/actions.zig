//! Every command a key can run, the keys that run them, and how menus show
//! them. `view.perform` carries each one out.
const std = @import("std");
const builtin = @import("builtin");
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
    details,
    trash,
    confirm_trash,
    restore,
    reveal,
    copy_path,
    copy_image,
    paste,
    rename,
    pause,
    next_frame,
    slower,
    faster,
    next_page,
    previous_page,
    save_frame,
};

/// The menus, in menu bar order.
pub const Group = enum {
    file,
    edit,
    view,
    go,

    pub fn title(g: Group) []const u8 {
        return switch (g) {
            .file => "File",
            .edit => "Edit",
            .view => "View",
            .go => "Go",
        };
    }
};

/// What an action needs to do something: menus leave out or disable the rest.
pub const Needs = enum {
    nothing,
    /// A picture on screen, a file or a pasted one.
    picture,
    /// A picture that is a file.
    file,
    /// Other pictures in its folder to step to.
    folder,
};

pub const Info = struct {
    title: []const u8,
    group: Group,
    needs: Needs = .picture,
    /// A separator comes before it when its menu shows anything before it.
    section: bool = false,
};

const trash_title = if (builtin.os.tag == .windows) "Move to Recycle Bin" else "Move to Trash";
const reveal_title = switch (builtin.os.tag) {
    .macos => "Show in Finder",
    .windows => "Show in Explorer",
    else => "Show in Folder",
};

/// Each action's menu title and place; menus list a group's actions in
/// enum order. `EnumArray.init` makes leaving one out a compile error.
pub const infos = std.enums.EnumArray(Action, Info).init(.{
    .open = .{ .title = "Open…", .group = .file, .needs = .nothing },
    .next = .{ .title = "Next Picture", .group = .go, .needs = .folder },
    .previous = .{ .title = "Previous Picture", .group = .go, .needs = .folder },
    .first = .{ .title = "First Picture", .group = .go, .needs = .folder, .section = true },
    .last = .{ .title = "Last Picture", .group = .go, .needs = .folder },
    .random = .{ .title = "Random Picture", .group = .go, .needs = .folder },
    .reload = .{ .title = "Reload", .group = .file, .needs = .file },
    .slideshow = .{ .title = "Slideshow", .group = .go, .needs = .folder, .section = true },
    .zoom_in = .{ .title = "Zoom In", .group = .view },
    .zoom_out = .{ .title = "Zoom Out", .group = .view },
    .fit = .{ .title = "Fit to Window", .group = .view },
    .actual = .{ .title = "Actual Size", .group = .view },
    .fit_upscale = .{ .title = "Fit Enlarges Small Pictures", .group = .view, .section = true },
    .fit_mode = .{ .title = "Next Fit Mode", .group = .view },
    .smooth = .{ .title = "Smooth Pixels", .group = .view },
    .zoom_lock = .{ .title = "Zoom Lock", .group = .view },
    .checkerboard = .{ .title = "Checkerboard", .group = .view },
    .full_screen = .{ .title = "Full Screen", .group = .view, .needs = .nothing, .section = true },
    .always_on_top = .{ .title = "Always on Top", .group = .view, .needs = .nothing },
    .leave_full_screen = .{ .title = "Leave Full Screen", .group = .view, .needs = .nothing },
    .rotate_right = .{ .title = "Rotate Right", .group = .view, .section = true },
    .rotate_left = .{ .title = "Rotate Left", .group = .view },
    .mirror = .{ .title = "Mirror", .group = .view },
    .flip = .{ .title = "Flip", .group = .view },
    .info = .{ .title = "Show Info", .group = .view, .section = true },
    .trash = .{ .title = trash_title, .group = .file, .needs = .file, .section = true },
    .confirm_trash = .{ .title = "Confirm " ++ trash_title, .group = .file, .needs = .file },
    .restore = .{ .title = "Put Back", .group = .edit, .needs = .nothing },
    .reveal = .{ .title = reveal_title, .group = .file, .needs = .file, .section = true },
    .copy_path = .{ .title = "Copy Path", .group = .edit, .needs = .file, .section = true },
    .copy_image = .{ .title = "Copy Picture", .group = .edit },
    .paste = .{ .title = "Paste", .group = .edit, .needs = .nothing },
    .rename = .{ .title = "Rename…", .group = .file, .needs = .file },
    .details = .{ .title = "Show EXIF Details", .group = .view },
    .pause = .{ .title = "Pause Animation", .group = .view, .section = true },
    .next_frame = .{ .title = "Next Frame", .group = .view },
    .slower = .{ .title = "Slower", .group = .view },
    .faster = .{ .title = "Faster", .group = .view },
    .next_page = .{ .title = "Next Page", .group = .go, .section = true },
    .previous_page = .{ .title = "Previous Page", .group = .go },
    .save_frame = .{ .title = "Save Frame As…", .group = .file },
});

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
    .{ .shortcut = .{ .key = 'e' }, .action = .details },
    .{ .shortcut = .{ .key = key.forward_delete }, .action = .trash },
    .{ .shortcut = .{ .key = key.backspace, .cmd = true }, .action = .trash },
    .{ .shortcut = .{ .key = key.enter }, .action = .confirm_trash },
    .{ .shortcut = .{ .key = 'z', .cmd = true }, .action = .restore },
    .{ .shortcut = .{ .key = 'r', .cmd = true }, .action = .reveal },
    .{ .shortcut = .{ .key = 'c', .cmd = true, .shift = true }, .action = .copy_path },
    .{ .shortcut = .{ .key = 'c', .cmd = true }, .action = .copy_image },
    .{ .shortcut = .{ .key = 'v', .cmd = true }, .action = .paste },
    .{ .shortcut = .{ .key = key.f(2) }, .action = .rename },
    .{ .shortcut = .{ .key = 'k' }, .action = .pause },
    .{ .shortcut = .{ .key = '.' }, .action = .next_frame },
    .{ .shortcut = .{ .key = '[' }, .action = .slower },
    .{ .shortcut = .{ .key = ']' }, .action = .faster },
    .{ .shortcut = .{ .key = key.down, .alt = true }, .action = .next_page },
    .{ .shortcut = .{ .key = key.up, .alt = true }, .action = .previous_page },
    .{ .shortcut = .{ .key = 's', .cmd = true, .shift = true }, .action = .save_frame },
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

test "every action has its own title" {
    const all = std.enums.values(Action);
    for (all, 0..) |a, i| {
        const title = infos.get(a).title;
        try std.testing.expect(title.len > 0);
        for (all[i + 1 ..]) |b| try std.testing.expect(!std.mem.eql(u8, title, infos.get(b).title));
    }
}
