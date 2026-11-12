//! The viewer's side of animation: starting a picture's player, timing its frames on the
//! view's clock, the playback commands and the info line's frame number.
const std = @import("std");
const app = @import("app.zig");
const animation = @import("animation.zig");
const actions = @import("actions.zig");
const State = app.State;
const assert = std.debug.assert;

/// Plays `bytes` (in `State.file_buffer`) when it is an animation; false shows it as a
/// still. A picture over the limit says so.
pub fn play(s: *State, bytes: []const u8) bool {
    assert(!s.player.active());
    if (!s.settings.animation) return false;
    const found = animation.detect(bytes) orelse return false;
    if (found.too_large()) {
        s.notify("Too large to animate: showing the first frame", .{});
        return false;
    }
    s.player.start(bytes, found) catch |err| {
        s.notify("Cannot play the animation: {s}", .{@errorName(err)});
        return false;
    };
    s.source = .{ .pixels = .{
        .bgra = s.player.canvas(),
        .width = found.width,
        .height = found.height,
        .native_w = found.width,
        .native_h = found.height,
    } };
    assert(s.player.active());
    return true;
}

/// Once per view frame: the frame due by `now`, and when the view wakes for the next.
pub fn tick(s: *State, now: f64) ?f32 {
    if (!s.player.active() or s.status != .shown) return null;
    const wait = s.player.tick(now) catch |err| {
        s.notify("Animation stopped: {s}", .{@errorName(err)});
        return null;
    };
    const seconds = wait orelse return null;
    assert(seconds > 0);
    return @floatCast(seconds);
}

pub fn perform(s: *State, action: actions.Action) void {
    const still = s.player.active() and s.player.frame_count == 1;
    if (!s.player.active() or still or s.status != .shown) {
        if (s.status == .shown) s.notify("Not an animation", .{});
        return;
    }
    const p = &s.player;
    switch (action) {
        .pause => {
            p.toggle_pause() catch |err| {
                s.notify("Animation stopped: {s}", .{@errorName(err)});
                return;
            };
            s.notify("{s}", .{if (p.playing) "Playing" else "Paused"});
        },
        .next_frame => p.step() catch |err| {
            s.notify("Animation stopped: {s}", .{@errorName(err)});
        },
        .slower, .faster => {
            p.change_speed(action == .faster);
            s.notify("Speed {d}%", .{p.speed_percent});
        },
        else => unreachable,
    }
}

/// " · frame 3/10" or " · frame 3" while a GIF has not told its count; empty for stills.
pub fn info(s: *const State, buf: []u8) []const u8 {
    if (!s.player.active() or s.player.frame_count == 1) return "";
    const p = &s.player;
    var writer: std.Io.Writer = .fixed(buf);
    writer.print(" · frame {d}", .{p.frame_index + 1}) catch {};
    if (p.frame_count) |count| writer.print("/{d}", .{count}) catch {};
    if (!p.playing and !p.finished) writer.writeAll(", paused") catch {};
    return buf[0..writer.end];
}
