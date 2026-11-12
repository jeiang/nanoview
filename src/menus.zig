//! What menus show of each action: whether it applies now and whether it
//! is checked, and the context menu. Titles and groups are `actions.infos`.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const assert = std.debug.assert;
const actions = @import("actions.zig");
const app = @import("app.zig");
const keymap = @import("keymap.zig");
const paths = @import("paths.zig");
const recent_mod = @import("recent.zig");
const view = @import("view.zig");

const Action = actions.Action;
const State = app.State;
const mac = builtin.os.tag == .macos;

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
        .details => s.details_shown,
        .pause => if (s.player.active()) !s.player.playing else null,
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
        .restore => return s.trashed.top() != null,
        .pause, .next_frame, .slower, .faster => return s.player.active(),
        .next_page, .previous_page => return s.status == .shown and s.page_count > 1,
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

/// The context menu: where it opens, and whether it is open.
pub const ContextMenu = struct {
    open: bool = false,
    at: ui.Point = .{ .x = 0, .y = 0 },
};

const action_count: u32 = std.enums.values(Action).len;
/// Every action with a separator before it, recent files, and the rest.
const list_len_max: u32 = action_count * 2 + recent_mod.recent_max + 8;
const context_width: f32 = 250;
const context_row_height: f32 = 24;

/// The submenus of the context menu: the File and Edit groups stand in the
/// menu itself.
const Sub = enum(u8) { recent, view, go };
const sub_count = std.enums.values(Sub).len;

pub const Pending = @typeInfo(Entry).@"union".tag_type.?;
const Entry = union(enum) { none, action: Action, recent: u32, clear_recent, submenu: Sub };

/// Menu items and what each one does.
const List = struct {
    items: [list_len_max]kit.MenuItem = undefined,
    entries: [list_len_max]Entry = undefined,
    len: u32 = 0,

    fn add(l: *List, item: kit.MenuItem, entry: Entry) void {
        assert(l.len < list_len_max);
        assert(item.separator == (entry == .none));
        l.items[l.len] = item;
        l.entries[l.len] = entry;
        l.len += 1;
    }

    /// A separator, unless the list is empty or ends with one.
    fn separate(l: *List) void {
        assert(l.len <= list_len_max);
        if (l.len > 0 and !l.items[l.len - 1].separator) l.add(.{ .separator = true }, .none);
    }

    /// The items, without a separator at the end.
    fn slice(l: *List) []const kit.MenuItem {
        assert(l.len <= list_len_max);
        if (l.len > 0 and l.items[l.len - 1].separator) l.len -= 1;
        return l.items[0..l.len];
    }
};

/// Opens the context menu on a right click (or Control-click on macOS), or
/// Shift+F10 off macOS. nanoui reports no Menu key. Call before the keys.
pub fn context_request(s: *State, c: *ui.Context) void {
    assert(c.size.w >= 0 and c.size.h >= 0);
    if (s.rename_open) return;
    const in = &c.input;
    const click = in.secondary or (in.pressed and in.button == .right);
    var keyboard = false;
    if (!mac and !click) {
        keyboard = c.shortcut(.{ .key = ui.Shortcut.f(10), .shift = true }) or
            (in.key == .f10 and in.shift);
    }
    if (!click and !keyboard) return;
    // The press opened the menu: it does not also close it.
    in.pressed = false;
    if (keyboard) in.key = null;
    const inside = in.mouse.x >= 0 and in.mouse.y >= 0 and
        in.mouse.x < c.size.w and in.mouse.y < c.size.h;
    const center: ui.Point = .{ .x = c.size.w / 2, .y = c.size.h / 2 };
    s.context_menu.at = if (click or inside) in.mouse else center;
    s.context_menu.open = true;
    assert(s.context_menu.open);
}

/// The context menu, open or fading: the actions that apply now.
pub fn context_menu(s: *State, c: *ui.Context) void {
    var top: List = .{};
    var subs: [sub_count]List = @splat(.{});
    fill(s, c, &top, &subs);
    const m = &s.context_menu;
    const anchor: ui.Rect = .{ .x = m.at.x, .y = m.at.y, .w = 0, .h = 0 };
    const options: kit.MenuOptions = .{ .width = context_width, .row_height = context_row_height };
    const items = top.slice();
    assert(items.len > 0);
    const choice = kit.menuChoice(c, "context-menu", &m.open, anchor, items, options) orelse return;
    const entry = top.entries[choice.index];
    const chosen = if (choice.sub) |j| subs[@backingInt(entry.submenu)].entries[j] else entry;
    switch (chosen) {
        .action => |a| view.perform(s, c, a),
        .recent => |i| open_recent(s, i),
        .clear_recent => s.clear_recent(),
        .none, .submenu => unreachable,
    }
}

fn fill(s: *const State, c: *ui.Context, top: *List, subs: *[sub_count]List) void {
    assert(top.len == 0);
    const recent = &subs[@backingInt(Sub.recent)];
    const count = s.recent_count();
    for (0..count) |i| {
        const path = s.recent(@intCast(i)) orelse break;
        recent.add(.{ .label = std.fs.path.basename(path) }, .{ .recent = @intCast(i) });
    }
    recent.separate();
    if (count > 0) recent.add(.{ .label = "Clear Recent" }, .clear_recent);
    add_group(s, c, &subs[@backingInt(Sub.view)], .view, null);
    add_group(s, c, &subs[@backingInt(Sub.go)], .go, null);
    add_group(s, c, top, .file, subs);
    top.separate();
    add_group(s, c, top, .edit, null);
    top.separate();
    add_submenu(top, subs, .view, actions.Group.view.title());
    add_submenu(top, subs, .go, actions.Group.go.title());
    assert(top.len <= list_len_max);
}

/// The group's actions that apply now; Open Recent after Open when `subs`.
fn add_group(
    s: *const State,
    c: *ui.Context,
    l: *List,
    group: actions.Group,
    subs: ?*[sub_count]List,
) void {
    assert(l.len < list_len_max);
    for (std.enums.values(Action)) |a| {
        const info = actions.infos.get(a);
        if (info.group != group or !available(s, a)) continue;
        if (info.section) l.separate();
        const item: kit.MenuItem = .{
            .label = info.title,
            .shortcut = shortcut(s, c, a),
            .checked = checked(s, a),
        };
        l.add(item, .{ .action = a });
        if (a == .open) if (subs) |all| add_submenu(l, all, .recent, "Open Recent");
    }
}

fn add_submenu(top: *List, subs: *[sub_count]List, sub: Sub, label: []const u8) void {
    assert(label.len > 0);
    const items = subs[@backingInt(sub)].slice();
    if (items.len == 0) return;
    top.add(.{ .label = label, .items = items }, .{ .submenu = sub });
}

/// The text of the action's first key, for this frame.
fn shortcut(s: *const State, c: *ui.Context, action: Action) []const u8 {
    const sc = s.keymap.first_key(action) orelse return "";
    var buf: [keymap.shortcut_text_len_max]u8 = undefined;
    const text = keymap.shortcut_text(sc, &buf);
    assert(text.len > 0);
    return c.print("{s}", .{text});
}

fn open_recent(s: *State, i: u32) void {
    // Opening moves the entry to the front of the list: copy it first.
    var buf: [paths.path_max]u8 = undefined;
    const path = s.recent(i) orelse return s.notify("That recent file is gone", .{});
    assert(path.len <= paths.path_max);
    @memcpy(buf[0..path.len], path);
    s.open_path(buf[0..path.len]);
}

const group_count: u32 = std.enums.values(actions.Group).len;
/// A group's actions and separators, Open Recent, and standard Edit items.
const group_len_max: u32 = action_count * 2 + 9;
/// The window menu and the app menu, beside the groups.
const bar_len_max: u32 = group_count + 2;
/// "Ctrl+Alt+Shift+Cmd+" and a key of at most four bytes, or "Plus".
const accelerator_len_max: u32 = 32;
const recent_ids = ids: {
    var ids: [recent_mod.recent_max][]const u8 = undefined;
    for (&ids, 0..) |*id, i| id.* = std.fmt.comptimePrint("recent{d}", .{i});
    break :ids ids;
};

/// The macOS menu bar's template: AppKit copies it, but the items' ids
/// and the Open Recent items stay here. Its menus show the keys of
/// `s.keymap` but leave them to `view.keys`, so each runs its action
/// once; a click is queued in `pending` for the next frame, which has
/// the context `view.perform` needs.
pub const MenuBar = struct {
    bar: [bar_len_max]nanoui.MenuItem = undefined,
    groups: [group_count][group_len_max]nanoui.MenuItem = undefined,
    recent: [recent_mod.recent_max + 1]nanoui.MenuItem = undefined,
    accelerators: [action_count][accelerator_len_max]u8 = undefined,
    pending: Entry = .none,
};

/// The menu bar's template, built in `s.menu_bar` from `actions.infos`
/// and the key table. For `nanoui.App.setMenu`, once, on macOS.
pub fn menu_bar(s: *State) []const nanoui.MenuItem {
    const b = &s.menu_bar;
    var len: u32 = 0;
    b.bar[len] = .{ .role = .app_menu };
    len += 1;
    for (std.enums.values(actions.Group), 0..) |group, g| {
        const items = bar_group(s, group, &b.groups[g]);
        b.bar[len] = .{
            .label = group.title(),
            .id = @tagName(group),
            .submenu = items,
            .on_open = .of(s, refresh_group),
            .accelerators_shown_only = true,
        };
        len += 1;
    }
    b.bar[len] = .{ .role = .window_menu };
    len += 1;
    assert(len == bar_len_max);
    return b.bar[0..len];
}

/// Every action of the group, with its first key; Open Recent after Open.
fn bar_group(
    s: *State,
    group: actions.Group,
    items: *[group_len_max]nanoui.MenuItem,
) []const nanoui.MenuItem {
    var len: u32 = 0;
    if (group == .edit) {
        const editing = [_]nanoui.MenuItem{
            .{ .role = .undo },
            .{ .role = .redo },
            .separator,
            .{ .role = .cut },
            .{ .role = .copy },
            .{ .role = .paste, .label = "Paste Text" },
            .{ .role = .select_all },
            .separator,
        };
        for (editing) |item| {
            items[len] = item;
            len += 1;
        }
    }
    for (std.enums.values(Action)) |a| {
        const info = actions.infos.get(a);
        if (info.group != group) continue;
        if (info.section and len > 0) {
            items[len] = .separator;
            len += 1;
        }
        const buf = &s.menu_bar.accelerators[@backingInt(a)];
        items[len] = .{
            .label = info.title,
            .id = @tagName(a),
            .accelerator = if (s.keymap.first_key(a)) |sc| accelerator(sc, buf) else "",
            .kind = if (checked(s, a) == null) .normal else .checkbox,
            .click = .of(s, clicked),
        };
        len += 1;
        if (a == .open) {
            const none = s.menu_bar.recent[0..0];
            const on_open: nanoui.MenuClick = .of(s, refresh_recent);
            items[len] = .{ .label = "Open Recent", .submenu = none, .on_open = on_open };
            len += 1;
        }
    }
    assert(len <= group_len_max);
    return items[0..len];
}

/// A key as nanoui's accelerators name it: "Shift+Cmd+c", "Plus".
fn accelerator(sc: ui.Shortcut, buf: *[accelerator_len_max]u8) []const u8 {
    assert(sc.key != 0);
    var w: std.Io.Writer = .fixed(buf);
    const n = sc.native();
    const mods = [_]struct { bool, []const u8 }{
        .{ n.ctrl, "Ctrl+" }, .{ n.alt, "Alt+" }, .{ n.shift, "Shift+" }, .{ n.cmd, "Cmd+" },
    };
    for (mods) |m| if (m[0]) w.writeAll(m[1]) catch unreachable;
    if (n.key == '+') {
        w.writeAll("Plus") catch unreachable;
    } else {
        w.print("{u}", .{n.key}) catch unreachable;
    }
    assert(w.end > 0);
    return w.buffered();
}

/// A group's menu is about to show: its checks and what applies now.
fn refresh_group(s: *State, holder: *nanoui.menu.Item) void {
    const group = std.meta.stringToEnum(actions.Group, holder.id) orelse unreachable;
    for (std.enums.values(Action)) |a| {
        if (actions.infos.get(a).group != group) continue;
        const item = holder.menu.item(@tagName(a)) orelse continue;
        item.setEnabled(available(s, a));
        if (checked(s, a)) |on| item.setChecked(on);
    }
}

/// Open Recent is about to show: the recent files, then Clear Recent.
fn refresh_recent(s: *State, holder: *nanoui.menu.Item) void {
    const items = &s.menu_bar.recent;
    const count = @min(s.recent_count(), recent_mod.recent_max);
    var len: u32 = 0;
    for (0..count) |i| {
        const path = s.recent(@intCast(i)) orelse break;
        const label = std.fs.path.basename(path);
        items[len] = .{ .label = label, .id = recent_ids[i], .click = .of(s, clicked) };
        len += 1;
    }
    items[len] = .{
        .label = "Clear Recent",
        .id = "clear_recent",
        .disabled = len == 0,
        .click = .of(s, clicked),
    };
    len += 1;
    assert(len <= items.len);
    holder.setSubmenu(items[0..len]) catch |err| {
        s.notify("Open Recent: {s}", .{@errorName(err)});
    };
}

/// A menu bar click: run on the next frame, which has a context.
fn clicked(s: *State, item: *nanoui.menu.Item) void {
    assert(item.id.len > 0);
    s.menu_bar.pending = if (std.meta.stringToEnum(Action, item.id)) |a|
        .{ .action = a }
    else if (std.mem.eql(u8, item.id, "clear_recent"))
        .clear_recent
    else for (recent_ids, 0..) |id, i| {
        if (std.mem.eql(u8, id, item.id)) break .{ .recent = @intCast(i) };
    } else unreachable;
    if (s.window) |w| w.redraw();
}

/// Runs the menu bar's queued click. Call before the keys.
pub fn run_menu_bar(s: *State, c: *ui.Context) void {
    const entry = s.menu_bar.pending;
    s.menu_bar.pending = .none;
    switch (entry) {
        .none => {},
        .action => |a| if (available(s, a)) view.perform(s, c, a),
        .recent => |i| open_recent(s, i),
        .clear_recent => s.clear_recent(),
        .submenu => unreachable,
    }
    assert(s.menu_bar.pending == .none);
}
