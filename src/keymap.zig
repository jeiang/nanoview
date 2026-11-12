//! The keys in effect: the defaults of `actions.zig`, then the
//! `key.<action> = <keys>` lines of settings.conf. Built once at startup.
const std = @import("std");
const ui = @import("nanoui").ui;
const actions = @import("actions.zig");
const Action = actions.Action;
const Binding = actions.Binding;
const assert = std.debug.assert;

pub const bindings_max: u32 = 128;
pub const keys_per_line_max: u32 = 16;
pub const key_name_len_max: u32 = 32;
/// nanoui reports F1 to F12 off macOS.
pub const function_key_max: u8 = 12;

comptime {
    assert(actions.bindings.len <= bindings_max);
}

pub const Error = enum { unknown_action, bad_key, too_many_keys };

pub const Keymap = struct {
    entries: [bindings_max]Binding = undefined,
    /// The settings.conf line of each binding; 0 for a default.
    lines: [bindings_max]u32 = undefined,
    count: u32 = 0,

    pub fn defaults() Keymap {
        var k: Keymap = .{};
        for (actions.bindings, 0..) |b, i| {
            k.entries[i] = b;
            k.lines[i] = 0;
        }
        k.count = actions.bindings.len;
        assert(k.count <= bindings_max);
        return k;
    }

    pub fn slice(k: *const Keymap) []const Binding {
        assert(k.count <= bindings_max);
        return k.entries[0..k.count];
    }

    /// Replaces every key of the action named `name`; an empty `value`
    /// unbinds it. On an error the map is unchanged.
    pub fn rebind(k: *Keymap, name: []const u8, value: []const u8, line: u32) ?Error {
        assert(line > 0);
        const action = std.meta.stringToEnum(Action, name) orelse return .unknown_action;
        var parsed: [keys_per_line_max]ui.Shortcut = undefined;
        var parsed_count: u32 = 0;
        if (value.len > 0) {
            var parts = std.mem.splitScalar(u8, value, ',');
            for (0..keys_per_line_max + 1) |_| {
                const part = parts.next() orelse break;
                if (parsed_count == keys_per_line_max) return .too_many_keys;
                parsed[parsed_count] = parse_shortcut(part) orelse return .bad_key;
                parsed_count += 1;
            }
        }
        var kept: u32 = 0;
        for (k.slice()) |b| kept += @intFromBool(b.action != action);
        if (kept + parsed_count > bindings_max) return .too_many_keys;
        k.remove_action(action);
        assert(k.count == kept);
        for (parsed[0..parsed_count]) |shortcut| {
            k.entries[k.count] = .{ .shortcut = shortcut, .action = action };
            k.lines[k.count] = line;
            k.count += 1;
        }
        return null;
    }

    fn remove_action(k: *Keymap, action: Action) void {
        var kept: u32 = 0;
        for (0..k.count) |i| {
            if (k.entries[i].action == action) continue;
            k.entries[kept] = k.entries[i];
            k.lines[kept] = k.lines[i];
            kept += 1;
        }
        k.count = kept;
        for (k.slice()) |b| assert(b.action != action);
    }

    /// One key bound twice keeps the later binding, the override. Returns
    /// the settings.conf line of the first binding that won a conflict.
    pub fn drop_conflicts(k: *Keymap) ?u32 {
        var first: ?u32 = null;
        var i: u32 = 0;
        // Each pass either keeps entry `i` or drops one entry.
        for (0..bindings_max) |_| {
            if (i >= k.count) break;
            const later = for (k.entries[i + 1 .. k.count], i + 1..) |b, j| {
                if (same(b.shortcut, k.entries[i].shortcut)) break j;
            } else null;
            if (later) |j| {
                if (first == null) first = k.lines[j];
                const end = k.count;
                std.mem.copyForwards(Binding, k.entries[i .. end - 1], k.entries[i + 1 .. end]);
                std.mem.copyForwards(u32, k.lines[i .. end - 1], k.lines[i + 1 .. end]);
                k.count -= 1;
            } else i += 1;
        }
        assert(i == k.count);
        return first;
    }

    /// The key menus show for an action: its first binding.
    pub fn first_key(k: *const Keymap, action: Action) ?ui.Shortcut {
        assert(k.count <= bindings_max);
        for (k.slice()) |b| if (b.action == action) return b.shortcut;
        return null;
    }
};

const mac = @import("builtin").os.tag == .macos;
pub const shortcut_text_len_max: u32 = 32;

/// How menus show a key: `⇧⌘C` on macOS, `Ctrl+Shift+C` elsewhere.
pub fn shortcut_text(sc: ui.Shortcut, buf: *[shortcut_text_len_max]u8) []const u8 {
    assert(sc.key != 0);
    var w: std.Io.Writer = .fixed(buf);
    const n = sc.native();
    const mods = if (mac)
        [_]struct { bool, []const u8 }{
            .{ n.ctrl, "⌃" },
            .{ n.alt, "⌥" },
            .{ n.shift, "⇧" },
            .{ n.cmd, "⌘" },
        }
    else
        [_]struct { bool, []const u8 }{
            .{ n.ctrl, "Ctrl+" }, .{ n.alt, "Alt+" }, .{ n.shift, "Shift+" }, .{ n.cmd, "" },
        };
    for (mods) |m| if (m[0]) w.writeAll(m[1]) catch unreachable;
    if (key_symbol(n.key)) |name| {
        w.writeAll(name) catch unreachable;
    } else if (n.key >= S.f(1) and n.key <= S.f(function_key_max)) {
        w.print("F{d}", .{n.key - S.f(1) + 1}) catch unreachable;
    } else if (n.key < 128) {
        w.writeByte(std.ascii.toUpper(@intCast(n.key))) catch unreachable;
    } else {
        w.print("{u}", .{n.key}) catch unreachable;
    }
    assert(w.end > 0);
    return w.buffered();
}

fn key_symbol(key: u21) ?[]const u8 {
    const symbols = [_]struct { u21, []const u8, []const u8 }{
        .{ S.left, "←", "Left" },
        .{ S.right, "→", "Right" },
        .{ S.up, "↑", "Up" },
        .{ S.down, "↓", "Down" },
        .{ S.escape, "⎋", "Esc" },
        .{ S.enter, "↩", "Enter" },
        .{ S.tab, "⇥", "Tab" },
        .{ S.backspace, "⌫", "Backspace" },
        .{ S.forward_delete, "⌦", "Del" },
        .{ S.home, "↖", "Home" },
        .{ S.end, "↘", "End" },
        .{ S.page_up, "⇞", "PgUp" },
        .{ S.page_down, "⇟", "PgDn" },
        .{ ' ', "Space", "Space" },
    };
    for (symbols) |sym| if (sym[0] == key) return if (mac) sym[1] else sym[2];
    return null;
}

const same = actions.same;

const S = ui.Shortcut;
const named_keys = [_]struct { []const u8, u21 }{
    .{ "space", ' ' },             .{ "enter", S.enter },           .{ "return", S.enter },
    .{ "escape", S.escape },       .{ "esc", S.escape },            .{ "tab", S.tab },
    .{ "backspace", S.backspace }, .{ "delete", S.forward_delete }, .{ "left", S.left },
    .{ "right", S.right },         .{ "up", S.up },                 .{ "down", S.down },
    .{ "home", S.home },           .{ "end", S.end },               .{ "pageup", S.page_up },
    .{ "pagedown", S.page_down },
};

/// `cmd+shift+r`, `F5`, `space`, `shift++`: modifiers in any order, any case.
pub fn parse_shortcut(raw: []const u8) ?ui.Shortcut {
    const text = std.mem.trim(u8, raw, " \t");
    if (text.len == 0 or text.len > key_name_len_max) return null;
    // A last `+` that follows a separator, or stands alone, is the plus key.
    const key_start = if (text[text.len - 1] == '+')
        text.len - 1
    else if (std.mem.lastIndexOfScalar(u8, text, '+')) |plus| plus + 1 else 0;
    var result: ui.Shortcut = .{ .key = parse_key(text[key_start..]) orelse return null };
    if (key_start == 0) return result;
    if (text[key_start - 1] != '+') return null;
    var parts = std.mem.splitScalar(u8, text[0 .. key_start - 1], '+');
    for (0..key_name_len_max) |_| {
        const part = parts.next() orelse break;
        const flag: *bool = if (eql(part, "cmd"))
            &result.cmd
        else if (eql(part, "ctrl"))
            &result.ctrl
        else if (eql(part, "alt") or eql(part, "opt") or eql(part, "option"))
            &result.alt
        else if (eql(part, "shift"))
            &result.shift
        else
            return null;
        if (flag.*) return null;
        flag.* = true;
    }
    assert(result.key != 0);
    return result;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn parse_key(name: []const u8) ?u21 {
    assert(name.len <= key_name_len_max);
    if (name.len == 0) return null;
    for (named_keys) |n| if (eql(name, n[0])) return n[1];
    if (name.len >= 2 and (name[0] == 'f' or name[0] == 'F')) {
        for (name[1..]) |ch| if (!std.ascii.isDigit(ch)) return null;
        const n = std.fmt.parseInt(u8, name[1..], 10) catch return null;
        if (n < 1 or n > function_key_max) return null;
        return S.f(n);
    }
    if (name.len != 1) return null;
    // `#` starts a comment and `,` separates keys in settings.conf.
    if (name[0] <= ' ' or name[0] > '~' or name[0] == '#' or name[0] == ',') return null;
    return std.ascii.toLower(name[0]);
}

const testing = std.testing;

test "every named key and character parses" {
    for (named_keys) |n| {
        try testing.expectEqual(n[1], parse_shortcut(n[0]).?.key);
        var upper: [key_name_len_max]u8 = undefined;
        const name = std.ascii.upperString(&upper, n[0]);
        try testing.expectEqual(n[1], parse_shortcut(name).?.key);
    }
    for (1..function_key_max + 1) |n| {
        var buf: [4]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "F{d}", .{n});
        try testing.expectEqual(S.f(@intCast(n)), parse_shortcut(name).?.key);
    }
    try testing.expectEqual(@as(u21, 'a'), parse_shortcut("A").?.key);
    try testing.expectEqual(@as(u21, '7'), parse_shortcut(" 7 ").?.key);
    for ("=-[];'./\\`!") |ch| try testing.expectEqual(@as(u21, ch), parse_shortcut(&.{ch}).?.key);
    try testing.expectEqual(@as(u21, '+'), parse_shortcut("+").?.key);
    const plus = parse_shortcut("shift++").?;
    try testing.expect(plus.key == '+' and plus.shift and !plus.cmd);
}

test "modifiers in any order and case" {
    const expected: ui.Shortcut = .{ .key = 'r', .cmd = true, .shift = true };
    for ([_][]const u8{ "cmd+shift+r", "shift+cmd+r", "SHIFT+Cmd+R", "shift+cmd+r " }) |t| {
        try testing.expect(same(expected, parse_shortcut(t).?));
    }
    const all = parse_shortcut("alt+ctrl+shift+cmd+pagedown").?;
    try testing.expect(all.alt and all.ctrl and all.shift and all.cmd);
    try testing.expectEqual(S.page_down, all.key);
    try testing.expect(parse_shortcut("opt+f12").?.alt);
}

test "bad key names are errors" {
    for ([_][]const u8{
        "",   "cmd+",   "shift+shift+a", "hyper+a",   "f0",      "f13", "f1x",
        "ab", "cmd++a",
        "é",
        ",",  "#",      "+a",            "cmd+shift", "pageupx", "\t",
    }) |t| try testing.expect(parse_shortcut(t) == null);
}

test "an override replaces the defaults and an empty value unbinds" {
    var k: Keymap = .defaults();
    try testing.expect(k.rebind("next", "n, Down", 3) == null);
    var next_keys: u32 = 0;
    for (k.slice()) |b| {
        if (b.action != .next) continue;
        next_keys += 1;
        try testing.expect(b.shortcut.key == 'n' or b.shortcut.key == S.down);
    }
    try testing.expectEqual(@as(u32, 2), next_keys);
    try testing.expect(k.rebind("open", "", 4) == null);
    for (k.slice()) |b| try testing.expect(b.action != .open);
    const before = k.count;
    try testing.expectEqual(Error.unknown_action, k.rebind("fly", "a", 5).?);
    try testing.expectEqual(Error.bad_key, k.rebind("next", "a, hyper+b", 5).?);
    try testing.expectEqual(Error.bad_key, k.rebind("next", "a,,b", 5).?);
    const seventeen = "a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q";
    try testing.expectEqual(Error.too_many_keys, k.rebind("next", seventeen, 5).?);
    try testing.expectEqual(before, k.count);
    try testing.expect(k.drop_conflicts() == null);
}

test "a key bound twice keeps the override and reports its line" {
    var k: Keymap = .defaults();
    try testing.expect(k.rebind("next", "x", 7) == null);
    try testing.expectEqual(@as(?u32, 7), k.drop_conflicts());
    for (k.slice()) |b| {
        const plain_x = b.shortcut.key == 'x' and !b.shortcut.cmd;
        if (plain_x) try testing.expectEqual(Action.next, b.action);
        try testing.expect(b.action != .random);
    }
    try testing.expect(k.drop_conflicts() == null);
}

test "the map holds at most bindings_max keys" {
    var k: Keymap = .defaults();
    const ten = "f1,f2,f3,f4,f5,f6,f7,f8,f9,f10";
    var refused = false;
    for (std.enums.values(Action)) |action| {
        const err = k.rebind(@tagName(action), ten, 9) orelse continue;
        try testing.expectEqual(Error.too_many_keys, err);
        refused = true;
    }
    try testing.expect(refused);
    try testing.expect(k.count <= bindings_max);
}

test "menus show keys the platform's way" {
    var buf: [shortcut_text_len_max]u8 = undefined;
    const copy_path = shortcut_text(.{ .key = 'c', .cmd = true, .shift = true }, &buf);
    try testing.expectEqualStrings(if (mac) "⇧⌘C" else "Ctrl+Shift+C", copy_path);
    try testing.expectEqualStrings("F2", shortcut_text(.{ .key = S.f(2) }, &buf));
    const right = shortcut_text(.{ .key = S.right }, &buf);
    try testing.expectEqualStrings(if (mac) "→" else "Right", right);
    try testing.expectEqualStrings("+", shortcut_text(.{ .key = '+' }, &buf));
    var k: Keymap = .defaults();
    try testing.expectEqual(@as(?u21, S.right), (k.first_key(.next) orelse unreachable).key);
    try testing.expectEqual(@as(?Error, null), k.rebind("next", "n", 1));
    try testing.expectEqual(@as(?u21, 'n'), (k.first_key(.next) orelse unreachable).key);
}
