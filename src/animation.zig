//! Animated GIF, APNG and WebP, played frame by frame through the bundled decoders into
//! one fixed buffer that `main` allocates once. The file bytes must stay unchanged while
//! a picture plays: both decoders read them on every frame.
const std = @import("std");
const wuffs = @import("wuffs.zig");
const webp = @import("webp.zig");
const assert = std.debug.assert;

/// 16 MP covers a 4096 by 4096 canvas. APNG is the costly case: Wuffs unfilters a whole
/// frame at up to 8 bytes per pixel and keeps a 4-byte canvas backup, so with the shown
/// canvas a frame touches up to 16 bytes per pixel, 256 MiB here. GIF touches 8, WebP 12.
pub const pixels_max: u64 = 16 * 1024 * 1024;
pub const canvas_bytes_max: u64 = pixels_max * bytes_per_pixel;
const bytes_per_pixel: u64 = 4;
/// What `wuffs.Animation.init` needs for any picture within `pixels_max`.
const wuffs_work_max: u64 = wuffs.state_size_max + wuffs.state_align_max +
    pixels_max * (wuffs.png_bytes_per_pixel_max + bytes_per_pixel) + wuffs.dimension_max;
const webp_work_max: u64 = 2 * canvas_bytes_max;
pub const work_bytes_max: u64 = @max(wuffs_work_max, webp_work_max);
/// The shown canvas, then the decoder's work. Reserved once; pages are touched on use.
pub const memory_bytes: u64 = canvas_bytes_max + work_bytes_max;

/// Browsers show shorter frames for 100 ms: files rely on it.
pub const delay_ms_min: u32 = 20;
pub const delay_ms_short: u32 = 100;
pub const speed_percent_min: u32 = 25;
pub const speed_percent_max: u32 = 400;
pub const speed_percent_step: u32 = 25;

pub const Error = wuffs.Error || webp.Error;

pub const Kind = enum { wuffs, webp };

pub const Found = struct {
    kind: Kind,
    width: u32,
    height: u32,
    /// Known up front for WebP only; a GIF tells at the end of its first play.
    frame_count: ?u32,

    pub fn too_large(found: Found) bool {
        return @as(u64, found.width) * found.height > pixels_max;
    }
};

/// An animated picture by its content. A GIF counts even with one frame: only a full
/// pass tells, and the player then holds it as a still.
pub fn detect(bytes: []const u8) ?Found {
    if (webp.probe(bytes)) |info| {
        if (!info.animated or info.frame_count < 2) return null;
        return .{
            .kind = .webp,
            .width = info.width,
            .height = info.height,
            .frame_count = info.frame_count,
        };
    }
    const info = wuffs.probe(bytes) orelse return null;
    if (!info.animated) return null;
    return .{ .kind = .wuffs, .width = info.width, .height = info.height, .frame_count = null };
}

const Decoder = union(enum) {
    none,
    wuffs: wuffs.Animation,
    webp: webp.Animation,
};

pub const Player = struct {
    /// `memory_bytes`, from `main`.
    memory: []u8 = &.{},
    decoder: Decoder = .none,
    width: u32 = 0,
    height: u32 = 0,
    /// The frame on the canvas, from 0.
    frame_index: u32 = 0,
    frame_count: ?u32 = null,
    /// Plays of the whole animation; 0 forever.
    loop_count: u32 = 0,
    plays: u32 = 0,
    delay_ms: u32 = 0,
    playing: bool = false,
    /// The loop count ran out: the last frame stays.
    finished: bool = false,
    /// Bumped for every frame put on the canvas: the picture key's number.
    serial: u32 = 0,
    /// On the view's clock; null until a frame sees the shown frame.
    due: ?f64 = null,
    speed_percent: u32 = 100,

    pub fn active(p: *const Player) bool {
        return p.decoder != .none;
    }

    pub fn canvas(p: *const Player) []u8 {
        assert(p.active());
        return p.memory[0 .. @as(usize, p.width) * p.height * bytes_per_pixel];
    }

    /// Shows the first frame. `bytes` must stay unchanged until `stop`.
    pub fn start(p: *Player, bytes: []const u8, found: Found) Error!void {
        assert(p.memory.len == memory_bytes);
        assert(!p.active() and !found.too_large());
        const work = p.memory[canvas_bytes_max..];
        p.decoder = switch (found.kind) {
            .wuffs => .{ .wuffs = try wuffs.Animation.init(bytes, work) },
            .webp => .{ .webp = try webp.Animation.init(bytes, work) },
        };
        errdefer p.stop();
        p.width = found.width;
        p.height = found.height;
        p.frame_count = found.frame_count;
        p.loop_count = p.decoder_loop_count();
        p.plays = 0;
        p.finished = false;
        p.due = null;
        if (!try p.next_frame()) return error.Corrupt;
        p.playing = p.frame_count != 1;
        assert(p.frame_index == 0);
    }

    pub fn stop(p: *Player) void {
        switch (p.decoder) {
            .none => {},
            .wuffs => {},
            .webp => |*animation| animation.deinit(),
        }
        p.decoder = .none;
        p.playing = false;
        p.due = null;
        assert(!p.active());
    }

    /// Seconds until the next frame is due, or null when nothing plays. Puts at most one
    /// frame on the canvas per call. On an error playback stops on the last good frame.
    pub fn tick(p: *Player, now: f64) Error!?f64 {
        if (!p.playing) return null;
        assert(p.active());
        if (p.due == null) p.due = now + p.delay_seconds();
        if (now >= p.due.?) {
            p.advance(false) catch |err| {
                p.playing = false;
                return err;
            };
            if (!p.playing) return null;
            p.due = now + p.delay_seconds();
        }
        const result = p.due.? - now;
        assert(result > 0);
        return result;
    }

    /// Pauses, or resumes; a finished animation starts over.
    pub fn toggle_pause(p: *Player) void {
        assert(p.active());
        p.due = null;
        if (p.playing) {
            p.playing = false;
            return;
        }
        if (p.frame_count == 1) return;
        if (p.finished) {
            p.finished = false;
            p.plays = 0;
        }
        p.playing = true;
    }

    /// Pauses and shows the next frame, the first after the last.
    pub fn step(p: *Player) Error!void {
        assert(p.active());
        p.playing = false;
        p.due = null;
        try p.advance(true);
    }

    pub fn change_speed(p: *Player, faster: bool) void {
        const s = p.speed_percent;
        p.speed_percent = if (faster)
            @min(speed_percent_max, s + speed_percent_step)
        else
            @max(speed_percent_min, s -| speed_percent_step);
        assert(p.speed_percent >= speed_percent_min and p.speed_percent <= speed_percent_max);
    }

    /// How long the shown frame stays at the current speed.
    pub fn delay_seconds(p: *const Player) f64 {
        assert(p.speed_percent >= speed_percent_min);
        const ms = if (p.delay_ms < delay_ms_min) delay_ms_short else p.delay_ms;
        const result = @as(f64, @floatFromInt(ms)) / 10 / @as(f64, @floatFromInt(p.speed_percent));
        assert(result > 0);
        return result;
    }

    /// The next frame; at the end of the file, the first again unless the loop count
    /// ran out, which `wrap` ignores.
    fn advance(p: *Player, wrap: bool) Error!void {
        if (try p.next_frame()) return;
        p.frame_count = p.frame_index + 1;
        p.loop_count = p.decoder_loop_count();
        p.plays +|= 1;
        const out = p.loop_count != 0 and p.plays >= p.loop_count;
        if (p.frame_count == 1 or (out and !wrap)) {
            p.playing = false;
            p.finished = p.frame_count != 1;
            return;
        }
        switch (p.decoder) {
            .none => unreachable,
            .wuffs => |*animation| try animation.reset(),
            .webp => |*animation| animation.reset(),
        }
        if (!try p.next_frame()) return error.Corrupt;
        assert(p.frame_index == 0);
    }

    /// False at the end of the file, with the canvas untouched.
    fn next_frame(p: *Player) Error!bool {
        const pixels = p.canvas();
        const frame_index: u32, const delay: u32 = switch (p.decoder) {
            .none => unreachable,
            .wuffs => |*animation| blk: {
                const frame = try animation.next(pixels) orelse return false;
                break :blk .{ frame.index, frame.delay_ms };
            },
            .webp => |*animation| blk: {
                const frame = try animation.next(pixels) orelse return false;
                break :blk .{ frame.index, frame.delay_ms };
            },
        };
        p.frame_index = frame_index;
        p.delay_ms = delay;
        p.serial +%= 1;
        return true;
    }

    fn decoder_loop_count(p: *const Player) u32 {
        return switch (p.decoder) {
            .none => unreachable,
            .wuffs => |animation| animation.loop_count,
            .webp => |animation| animation.loop_count,
        };
    }
};

const testing = std.testing;

test "short delays count as 100 ms and speed scales every delay" {
    var p: Player = .{};
    p.delay_ms = 10;
    try testing.expectApproxEqAbs(@as(f64, 0.1), p.delay_seconds(), 1e-9);
    p.delay_ms = 20;
    try testing.expectApproxEqAbs(@as(f64, 0.02), p.delay_seconds(), 1e-9);
    p.delay_ms = 300;
    p.change_speed(true);
    p.change_speed(true);
    p.change_speed(true);
    p.change_speed(true);
    try testing.expectEqual(@as(u32, 200), p.speed_percent);
    try testing.expectApproxEqAbs(@as(f64, 0.15), p.delay_seconds(), 1e-9);
    for (0..20) |_| p.change_speed(true);
    try testing.expectEqual(speed_percent_max, p.speed_percent);
    for (0..20) |_| p.change_speed(false);
    try testing.expectEqual(speed_percent_min, p.speed_percent);
}

test "detect finds animations by content and the limit is a pixel count" {
    const fixtures = @import("wuffs_fixtures.zig");
    const red: fixtures.Rgba = .{ 255, 0, 0, 255 };
    try testing.expect(detect(comptime fixtures.png(1, 1, &.{red})) == null);
    try testing.expect(detect(@embedFile("testdata/webp_lossy.webp")) == null);
    const anim = detect(@embedFile("testdata/webp_anim.webp")).?;
    try testing.expectEqual(Kind.webp, anim.kind);
    try testing.expectEqual(@as(?u32, 2), anim.frame_count);
    const big: Found = .{ .kind = .wuffs, .width = 4097, .height = 4096, .frame_count = null };
    try testing.expect(big.too_large());
    const edge: Found = .{ .kind = .wuffs, .width = 4096, .height = 4096, .frame_count = null };
    try testing.expect(!edge.too_large());
}
