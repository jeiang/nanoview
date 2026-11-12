//! BMP, GIF, PNG (with APNG), QOI and TGA through the bundled Wuffs library, which
//! src/wuffs_bridge.c compiles. Nothing here or in Wuffs allocates: the decoder state, the
//! Wuffs work buffer and the animation backup all live in the caller's `work` buffer.
//! Pictures come out as tightly packed premultiplied BGRA, `width * 4` bytes per row.

const std = @import("std");
const assert = std.debug.assert;

pub const dimension_max: u32 = 65535;
pub const pixels_max: u64 = 64 * 1024 * 1024;
pub const frames_max: u32 = 10_000;
pub const bytes_per_pixel: u32 = 4;
/// Upper bound on the bridge state; the GIF decoder dominates at about 64 KiB.
pub const state_size_max: u64 = 96 * 1024;
pub const state_align_max: u64 = 64;
/// PNG unfilters the whole image at up to 8 bytes per pixel plus one filter byte per row.
/// The other formats need no Wuffs work buffer.
pub const png_bytes_per_pixel_max: u64 = 8;
pub const decoder_work_max: u64 = pixels_max * png_bytes_per_pixel_max + dimension_max;
/// `work` that any picture within the limits fits for `decode_first`.
pub const work_size_still_max: u64 = state_size_max + state_align_max + decoder_work_max;
/// `work` that any picture within the limits fits for `Animation.init`.
pub const work_size_animation_max: u64 = work_size_still_max + pixels_max * bytes_per_pixel;

const flicks_per_millisecond: u64 = 705_600;

const fourcc_bmp: u32 = 0x424D5020;
const fourcc_gif: u32 = 0x47494620;
const fourcc_png: u32 = 0x504E4720;
const fourcc_qoi: u32 = 0x514F4920;
const fourcc_tga: u32 = 0x54474120;

const disposal_none: u8 = 0;
const disposal_background: u8 = 1;
const disposal_previous: u8 = 2;

pub const Format = enum { bmp, gif, png, qoi, tga };

pub const Info = struct {
    width: u32,
    height: u32,
    format: Format,
    /// Plays of the whole animation; 0 means forever and is also what still pictures report.
    loop_count: u32,
    /// True for APNG and for every GIF: a GIF's frame count needs a scan of the whole file,
    /// so `Animation.next` returning null after the first frame is the final answer.
    animated: bool,
    /// Bytes of `work` that `decode_first` needs for this picture.
    work_size_still: u64,
    /// Bytes of `work` that `Animation.init` needs for this picture.
    work_size_animation: u64,
};

pub const Size = struct {
    width: u32,
    height: u32,
};

pub const Frame = struct {
    index: u32,
    /// How long to show the frame; 0 for still pictures and zero-delay frames.
    delay_ms: u32,
};

pub const Error = error{
    Unsupported,
    Corrupt,
    Truncated,
    TooLarge,
    TooManyFrames,
    OutputTooSmall,
    WorkTooSmall,
};

const Status = enum(i32) {
    ok = 0,
    end = 1,
    unsupported = 2,
    corrupt = 3,
    truncated = 4,
    work_too_small = 5,
    output_too_small = 6,
    _,
};

const BridgeInfo = extern struct {
    width: u32,
    height: u32,
    fourcc: u32,
    loop_count: u32,
    work_len: u64,
};

const BridgeFrame = extern struct {
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,
    duration_flicks: u64,
    index: u64,
    background_bgra: u32,
    disposal: u8,
    overwrite: u8,
    padding: [2]u8,
};

extern fn nanoview_wuffs_state_size() usize;
extern fn nanoview_wuffs_state_align() usize;
extern fn nanoview_wuffs_open(
    state: *anyopaque,
    bytes: [*]const u8,
    len: usize,
    info: *BridgeInfo,
) i32;
extern fn nanoview_wuffs_probe(bytes: [*]const u8, len: usize, info: *BridgeInfo) i32;
extern fn nanoview_wuffs_frame_config(state: *anyopaque, frame: *BridgeFrame) i32;
extern fn nanoview_wuffs_decode_frame(
    state: *anyopaque,
    canvas: [*]u8,
    canvas_len: usize,
    work: [*]u8,
    work_len: usize,
    overwrite: u8,
) i32;
extern fn nanoview_wuffs_restart(state: *anyopaque) i32;
extern fn nanoview_wuffs_loop_count(state: *anyopaque) u32;

/// Reads only the header. Null for data this module cannot decode or that breaks a limit.
pub fn probe(bytes: []const u8) ?Info {
    if (bytes.len == 0) return null;
    var bridge: BridgeInfo = undefined;
    const status = status_of(nanoview_wuffs_probe(bytes.ptr, bytes.len, &bridge));
    if (status != .ok) return null;
    var info = info_from(bridge) catch return null;
    info.animated = switch (info.format) {
        .gif => true,
        .png => png_has_actl(bytes),
        .bmp, .qoi, .tga => false,
    };
    return info;
}

const png_chunks_max: u32 = 4096;

/// Walks the chunks before the first IDAT; an acTL chunk there makes a PNG an APNG.
fn png_has_actl(bytes: []const u8) bool {
    const signature_len = 8;
    assert(bytes.len >= signature_len);
    var offset: usize = signature_len;
    var chunk: u32 = 0;
    while (chunk < png_chunks_max and bytes.len - offset >= 8) : (chunk += 1) {
        const length = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        const kind = bytes[offset + 4 ..][0..4];
        if (std.mem.eql(u8, kind, "acTL")) return true;
        if (std.mem.eql(u8, kind, "IDAT")) return false;
        // Length, type, data and CRC.
        const step = @as(u64, length) + 12;
        if (step > bytes.len - offset) return false;
        offset += @intCast(step);
    }
    return false;
}

/// Decodes the first frame, composited on transparent black, into `out_bgra`.
pub fn decode_first(bytes: []const u8, out_bgra: []u8, work: []u8) Error!Size {
    var animation = try Animation.open(bytes, work, .still);
    const frame = try animation.next(out_bgra) orelse return error.Corrupt;
    assert(frame.index == 0);
    return .{ .width = animation.width, .height = animation.height };
}

/// Plays a picture frame by frame onto one caller canvas. `bytes` and `work` must stay
/// unchanged and in place while the animation is used.
pub const Animation = struct {
    state: *anyopaque,
    decoder_work: []u8,
    /// Canvas copy under a restore-previous frame; empty for `decode_first`.
    backup: []u8,
    width: u32,
    height: u32,
    /// Plays of the whole animation; 0 means forever. GIF can reveal it late.
    loop_count: u32,
    frames_decoded: u32,
    pending: Pending,

    const Mode = enum { still, animation };

    const Pending = struct {
        disposal: u8,
        rect: Rect,
        background_bgra: u32,

        const none: Pending = .{
            .disposal = disposal_none,
            .rect = .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 },
            .background_bgra = 0,
        };
    };

    pub fn init(bytes: []const u8, work: []u8) Error!Animation {
        return open(bytes, work, .animation);
    }

    fn open(bytes: []const u8, work: []u8, mode: Mode) Error!Animation {
        const prefix = state_prefix();
        if (work.len < prefix) return error.WorkTooSmall;
        const address = @intFromPtr(work.ptr);
        const offset = std.mem.alignForward(usize, address, nanoview_wuffs_state_align()) -
            address;
        assert(offset + nanoview_wuffs_state_size() <= prefix);
        const state: *anyopaque = @ptrCast(work[offset..].ptr);
        var bridge: BridgeInfo = undefined;
        try check(status_of(nanoview_wuffs_open(state, bytes.ptr, bytes.len, &bridge)));
        const info = try info_from(bridge);
        const needed = switch (mode) {
            .still => info.work_size_still,
            .animation => info.work_size_animation,
        };
        if (work.len < needed) return error.WorkTooSmall;
        const rest = work[prefix..];
        const decoder_work_len: usize = @intCast(bridge.work_len);
        const backup_len: usize = switch (mode) {
            .still => 0,
            .animation => canvas_size(info.width, info.height),
        };
        return .{
            .state = state,
            .decoder_work = rest[0..decoder_work_len],
            .backup = rest[decoder_work_len..][0..backup_len],
            .width = info.width,
            .height = info.height,
            .loop_count = info.loop_count,
            .frames_decoded = 0,
            .pending = .none,
        };
    }

    /// Composites the next frame onto `canvas`, which must hold what the previous call
    /// left there. Null after the last frame, leaving the canvas untouched; `reset` loops.
    pub fn next(self: *Animation, canvas: []u8) Error!?Frame {
        assert(self.backup.len > 0 or self.frames_decoded == 0);
        const size = canvas_size(self.width, self.height);
        if (canvas.len < size) return error.OutputTooSmall;
        const pixels = canvas[0..size];
        var bridge: BridgeFrame = undefined;
        const status = status_of(nanoview_wuffs_frame_config(self.state, &bridge));
        if (status == .end) return null;
        try check(status);
        if (self.frames_decoded >= frames_max) return error.TooManyFrames;
        if (bridge.index != self.frames_decoded) return error.Corrupt;
        const rect = try self.frame_rect(bridge);
        self.dispose(pixels);
        if (bridge.index == 0) {
            fill(pixels, self.width, self.full_rect(), bridge.background_bgra);
        }
        if (bridge.disposal == disposal_previous and self.backup.len > 0) {
            copy_rect(self.backup, pixels, self.width, rect);
        }
        try check(status_of(nanoview_wuffs_decode_frame(
            self.state,
            pixels.ptr,
            pixels.len,
            self.decoder_work.ptr,
            self.decoder_work.len,
            bridge.overwrite,
        )));
        self.pending = .{
            .disposal = bridge.disposal,
            .rect = rect,
            .background_bgra = bridge.background_bgra,
        };
        self.frames_decoded += 1;
        self.loop_count = nanoview_wuffs_loop_count(self.state);
        const delay = delay_ms(bridge.duration_flicks);
        return .{ .index = self.frames_decoded - 1, .delay_ms = delay };
    }

    /// Rewinds to the first frame, which repaints the whole canvas.
    pub fn reset(self: *Animation) Error!void {
        assert(self.width > 0 and self.height > 0);
        try check(status_of(nanoview_wuffs_restart(self.state)));
        self.frames_decoded = 0;
        self.pending = .none;
    }

    fn dispose(self: *Animation, pixels: []u8) void {
        assert(pixels.len == canvas_size(self.width, self.height));
        switch (self.pending.disposal) {
            disposal_background => {
                fill(pixels, self.width, self.pending.rect, self.pending.background_bgra);
            },
            disposal_previous => if (self.backup.len > 0) {
                copy_rect(pixels, self.backup, self.width, self.pending.rect);
            },
            else => {},
        }
        self.pending = .none;
    }

    fn frame_rect(self: *const Animation, bridge: BridgeFrame) Error!Rect {
        if (bridge.x0 > bridge.x1 or bridge.x1 > self.width) return error.Corrupt;
        if (bridge.y0 > bridge.y1 or bridge.y1 > self.height) return error.Corrupt;
        return .{ .x0 = bridge.x0, .y0 = bridge.y0, .x1 = bridge.x1, .y1 = bridge.y1 };
    }

    fn full_rect(self: *const Animation) Rect {
        return .{ .x0 = 0, .y0 = 0, .x1 = self.width, .y1 = self.height };
    }
};

const Rect = struct {
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,
};

fn fill(pixels: []u8, width: u32, rect: Rect, bgra: u32) void {
    assert(rect.x0 <= rect.x1 and rect.x1 <= width);
    assert(@as(u64, rect.y1) * width * bytes_per_pixel <= pixels.len);
    var color: [bytes_per_pixel]u8 = undefined;
    std.mem.writeInt(u32, &color, bgra, .little);
    for (rect.y0..rect.y1) |y| {
        const row = row_span(pixels, width, rect, y);
        for (0..row.len / bytes_per_pixel) |i| row[i * bytes_per_pixel ..][0..4].* = color;
    }
}

fn copy_rect(dst: []u8, src: []const u8, width: u32, rect: Rect) void {
    assert(dst.len == src.len);
    assert(@as(u64, rect.y1) * width * bytes_per_pixel <= dst.len);
    for (rect.y0..rect.y1) |y| {
        const start = (y * width + rect.x0) * bytes_per_pixel;
        const len = (rect.x1 - rect.x0) * bytes_per_pixel;
        @memcpy(dst[start..][0..len], src[start..][0..len]);
    }
}

fn row_span(pixels: []u8, width: u32, rect: Rect, y: usize) []u8 {
    const start = (y * width + rect.x0) * bytes_per_pixel;
    return pixels[start..][0 .. (rect.x1 - rect.x0) * bytes_per_pixel];
}

fn info_from(bridge: BridgeInfo) Error!Info {
    const format: Format = switch (bridge.fourcc) {
        fourcc_bmp => .bmp,
        fourcc_gif => .gif,
        fourcc_png => .png,
        fourcc_qoi => .qoi,
        fourcc_tga => .tga,
        else => return error.Unsupported,
    };
    if (bridge.width == 0 or bridge.height == 0) return error.Corrupt;
    if (bridge.width > dimension_max or bridge.height > dimension_max) return error.TooLarge;
    const pixels = @as(u64, bridge.width) * bridge.height;
    if (pixels > pixels_max) return error.TooLarge;
    if (bridge.work_len > decoder_work_max) return error.TooLarge;
    const still = @as(u64, state_prefix()) + bridge.work_len;
    return .{
        .width = bridge.width,
        .height = bridge.height,
        .format = format,
        .loop_count = bridge.loop_count,
        .animated = false,
        .work_size_still = still,
        .work_size_animation = still + pixels * bytes_per_pixel,
    };
}

/// Room for the bridge state at any alignment of `work`.
fn state_prefix() usize {
    const size = nanoview_wuffs_state_size();
    const alignment = nanoview_wuffs_state_align();
    assert(size <= state_size_max);
    assert(alignment <= state_align_max and std.math.isPowerOfTwo(alignment));
    return size + alignment;
}

fn canvas_size(width: u32, height: u32) usize {
    assert(@as(u64, width) * height <= pixels_max);
    return @as(usize, width) * height * bytes_per_pixel;
}

fn delay_ms(duration_flicks: u64) u32 {
    return @intCast(@min(duration_flicks / flicks_per_millisecond, std.math.maxInt(u32)));
}

fn status_of(code: i32) Status {
    return @fromBackingInt(code);
}

fn check(status: Status) Error!void {
    return switch (status) {
        .ok => {},
        .unsupported => error.Unsupported,
        .truncated => error.Truncated,
        .work_too_small => error.WorkTooSmall,
        .output_too_small => error.OutputTooSmall,
        else => error.Corrupt,
    };
}

const testing = std.testing;
const fixtures = @import("wuffs_fixtures.zig");

const testing_work_size = 128 * 1024;

const bgra_red = [4]u8{ 0, 0, 255, 255 };
const bgra_green = [4]u8{ 0, 255, 0, 255 };
const bgra_blue = [4]u8{ 255, 0, 0, 255 };
const bgra_clear = [4]u8{ 0, 0, 0, 0 };
const bgra_white_half = [4]u8{ 128, 128, 128, 128 };
const bgra_green_half = [4]u8{ 0, 128, 0, 128 };

const rgba_red = [4]u8{ 255, 0, 0, 255 };
const rgba_blue = [4]u8{ 0, 0, 255, 255 };
const rgba_white_half = [4]u8{ 255, 255, 255, 128 };
const rgba_green_half = [4]u8{ 0, 255, 0, 128 };

const bmp_2x2 = fixtures.bmp24(2, 2, &.{
    rgba_red,
    .{ 0, 255, 0, 255 },
    rgba_blue,
    .{ 255, 255, 255, 255 },
});
const bmp_2x2_bgra = [_][4]u8{ bgra_red, bgra_green, bgra_blue, .{ 255, 255, 255, 255 } };

const tga_2x2 = fixtures.tga32(2, 2, &.{
    rgba_red,
    rgba_white_half,
    .{ 0, 0, 255, 0 },
    .{ 10, 20, 30, 255 },
});
const tga_2x2_bgra = [_][4]u8{ bgra_red, bgra_white_half, bgra_clear, .{ 30, 20, 10, 255 } };

const qoi_2x2 = fixtures.qoi(2, 2, &.{
    .{ 0, 0, 0, 255 },
    rgba_red,
    rgba_green_half,
    .{ 200, 100, 50, 255 },
});
const qoi_2x2_bgra = [_][4]u8{
    .{ 0, 0, 0, 255 },
    bgra_red,
    bgra_green_half,
    .{ 50, 100, 200, 255 },
};

const png_2x1 = fixtures.png(2, 1, &.{ rgba_red, .{ 0, 0, 255, 51 } });
const png_2x1_bgra = [_][4]u8{ bgra_red, .{ 51, 0, 0, 51 } };

const gif_keep = 1;
const gif_restore_background = 2;
const gif_restore_previous = 3;
const gif_transparent = 3;

// Palette: 0 red, 1 green, 2 blue, 3 black (the transparent index).
const gif_animation = fixtures.gif(3, 1, .{
    .{ 255, 0, 0 },
    .{ 0, 255, 0 },
    .{ 0, 0, 255 },
    .{ 0, 0, 0 },
}, 2, &.{
    gif_row_frame(0, 10, gif_keep, null, &.{ 0, 1, 2 }),
    gif_row_frame(1, 20, gif_restore_previous, null, &.{0}),
    gif_row_frame(2, 30, gif_restore_background, null, &.{1}),
    gif_row_frame(0, 0, gif_keep, gif_transparent, &.{gif_transparent}),
});

const apng_none = 0;
const apng_background = 1;
const apng_previous = 2;
const apng_source = 0;
const apng_over = 1;

const apng_animation = fixtures.apng(2, 1, 4, &.{
    apng_row_frame(0, .{ 1, 10 }, apng_none, apng_source, &.{ rgba_red, rgba_white_half }),
    apng_row_frame(1, .{ 5, 100 }, apng_background, apng_over, &.{rgba_blue}),
    apng_row_frame(0, .{ 1, 1 }, apng_previous, apng_source, &.{rgba_green_half}),
    apng_row_frame(1, .{ 7, 1000 }, apng_none, apng_source, &.{rgba_blue}),
});

fn gif_row_frame(
    x: u16,
    delay_cs: u16,
    disposal: u8,
    transparent: ?u8,
    indices: []const u8,
) fixtures.GifFrame {
    return .{
        .x = x,
        .y = 0,
        .width = @intCast(indices.len),
        .height = 1,
        .delay_cs = delay_cs,
        .disposal = disposal,
        .transparent = transparent,
        .indices = indices,
    };
}

fn apng_row_frame(
    x: u32,
    delay: [2]u16,
    dispose: u8,
    blend: u8,
    pixels: []const fixtures.Rgba,
) fixtures.ApngFrame {
    return .{
        .x = x,
        .y = 0,
        .width = @intCast(pixels.len),
        .height = 1,
        .delay_num = delay[0],
        .delay_den = delay[1],
        .dispose = dispose,
        .blend = blend,
        .pixels = pixels,
    };
}

fn expect_pixels(canvas: []const u8, expected: []const [4]u8) !void {
    try testing.expect(canvas.len >= expected.len * bytes_per_pixel);
    for (expected, 0..) |pixel, i| {
        try testing.expectEqualSlices(u8, &pixel, canvas[i * bytes_per_pixel ..][0..4]);
    }
}

fn expect_still(bytes: []const u8, expected: []const [4]u8, width: u32, height: u32) !void {
    var work: [testing_work_size]u8 = undefined;
    var out: [64]u8 = @splat(0xaa);
    const size = try decode_first(bytes, &out, &work);
    try testing.expectEqual(Size{ .width = width, .height = height }, size);
    try expect_pixels(&out, expected);
}

fn expect_frame(
    animation: *Animation,
    canvas: []u8,
    index: u32,
    delay: u32,
    expected: []const [4]u8,
) !void {
    const frame = (try animation.next(canvas)).?;
    try testing.expectEqual(Frame{ .index = index, .delay_ms = delay }, frame);
    try expect_pixels(canvas, expected);
}

test "wuffs probe reads headers and rejects what it cannot decode" {
    const bmp = probe(bmp_2x2).?;
    try testing.expectEqual(Format.bmp, bmp.format);
    try testing.expectEqual(@as(u32, 2), bmp.width);
    try testing.expectEqual(@as(u32, 2), bmp.height);
    try testing.expectEqual(bmp.work_size_still + 2 * 2 * 4, bmp.work_size_animation);
    try testing.expectEqual(Format.tga, probe(tga_2x2).?.format);
    try testing.expectEqual(Format.qoi, probe(qoi_2x2).?.format);
    try testing.expectEqual(Format.png, probe(png_2x1).?.format);
    try testing.expectEqual(@as(u32, 0), probe(png_2x1).?.loop_count);
    const gif = probe(gif_animation).?;
    try testing.expectEqual(Format.gif, gif.format);
    try testing.expectEqual(@as(u32, 3), gif.width);
    try testing.expectEqual(@as(u32, 3), gif.loop_count);
    try testing.expectEqual(@as(u32, 4), probe(apng_animation).?.loop_count);
    try testing.expect(probe(apng_animation).?.animated);
    try testing.expect(gif.animated);
    try testing.expect(!probe(png_2x1).?.animated);
    try testing.expect(!bmp.animated);
    try testing.expect(probe(png_2x1).?.work_size_still <= testing_work_size);
    try testing.expectEqual(@as(?Info, null), probe(""));
    try testing.expectEqual(@as(?Info, null), probe("not a picture at all"));
    try testing.expectEqual(@as(?Info, null), probe(png_2x1[0..20]));
}

test "wuffs decodes BMP pixels" {
    try expect_still(bmp_2x2, &bmp_2x2_bgra, 2, 2);
}

test "wuffs premultiplies TGA alpha" {
    try expect_still(tga_2x2, &tga_2x2_bgra, 2, 2);
}

test "wuffs premultiplies QOI alpha" {
    try expect_still(qoi_2x2, &qoi_2x2_bgra, 2, 2);
}

test "wuffs premultiplies PNG alpha" {
    try expect_still(png_2x1, &png_2x1_bgra, 2, 1);
}

test "wuffs decode_first gives the first animation frame" {
    try expect_still(gif_animation, &.{ bgra_red, bgra_green, bgra_blue }, 3, 1);
    try expect_still(apng_animation, &.{ bgra_red, bgra_white_half }, 2, 1);
}

test "wuffs composites GIF disposal, delays, loops and reset" {
    var work: [testing_work_size]u8 = undefined;
    var canvas: [3 * 4]u8 = @splat(0xaa);
    var animation = try Animation.init(gif_animation, &work);
    try testing.expectEqual(@as(u32, 3), animation.loop_count);
    try expect_frame(&animation, &canvas, 0, 100, &.{ bgra_red, bgra_green, bgra_blue });
    try expect_frame(&animation, &canvas, 1, 200, &.{ bgra_red, bgra_red, bgra_blue });
    // Frame 1 restores the previous canvas before frame 2 draws.
    try expect_frame(&animation, &canvas, 2, 300, &.{ bgra_red, bgra_green, bgra_green });
    // Frame 2 restores the background; frame 3 is one transparent pixel.
    try expect_frame(&animation, &canvas, 3, 0, &.{ bgra_red, bgra_green, bgra_clear });
    try testing.expectEqual(@as(?Frame, null), try animation.next(&canvas));
    try expect_pixels(&canvas, &.{ bgra_red, bgra_green, bgra_clear });
    try animation.reset();
    try expect_frame(&animation, &canvas, 0, 100, &.{ bgra_red, bgra_green, bgra_blue });
    try expect_frame(&animation, &canvas, 1, 200, &.{ bgra_red, bgra_red, bgra_blue });
}

test "wuffs composites APNG disposal, blending, delays, loops and reset" {
    var work: [testing_work_size]u8 = undefined;
    var canvas: [2 * 4]u8 = @splat(0xaa);
    var animation = try Animation.init(apng_animation, &work);
    try testing.expectEqual(@as(u32, 4), animation.loop_count);
    try expect_frame(&animation, &canvas, 0, 100, &.{ bgra_red, bgra_white_half });
    try expect_frame(&animation, &canvas, 1, 50, &.{ bgra_red, bgra_blue });
    try expect_frame(&animation, &canvas, 2, 1000, &.{ bgra_green_half, bgra_clear });
    try expect_frame(&animation, &canvas, 3, 7, &.{ bgra_red, bgra_blue });
    try testing.expectEqual(@as(?Frame, null), try animation.next(&canvas));
    try animation.reset();
    try expect_frame(&animation, &canvas, 0, 100, &.{ bgra_red, bgra_white_half });
}

test "wuffs still pictures have one frame" {
    var work: [testing_work_size]u8 = undefined;
    var canvas: [2 * 2 * 4]u8 = undefined;
    var animation = try Animation.init(qoi_2x2, &work);
    try testing.expectEqual(@as(u32, 0), animation.loop_count);
    try expect_frame(&animation, &canvas, 0, 0, &qoi_2x2_bgra);
    try testing.expectEqual(@as(?Frame, null), try animation.next(&canvas));
}

test "wuffs rejects small output and work buffers" {
    var work: [testing_work_size]u8 = undefined;
    var out: [2 * 2 * 4]u8 = undefined;
    const short = out[0 .. out.len - 1];
    try testing.expectError(error.OutputTooSmall, decode_first(bmp_2x2, short, &work));
    try testing.expectError(error.WorkTooSmall, decode_first(bmp_2x2, &out, work[0..16]));
    const info = probe(gif_animation).?;
    const still: usize = @intCast(info.work_size_still);
    _ = try decode_first(gif_animation, &out, work[0..still]);
    try testing.expectError(error.WorkTooSmall, Animation.init(gif_animation, work[0..still]));
    const animation_work = work[0..@intCast(info.work_size_animation)];
    var animation = try Animation.init(gif_animation, animation_work);
    try testing.expectError(error.OutputTooSmall, animation.next(out[0 .. 3 * 4 - 1]));
}

test "wuffs reports truncated data" {
    var work: [testing_work_size]u8 = undefined;
    var out: [3 * 4]u8 = undefined;
    // Drops the IEND chunk and the end of the IDAT chunk.
    const png = png_2x1[0 .. png_2x1.len - 20];
    try testing.expectError(error.Truncated, decode_first(png, &out, &work));
    // Drops the trailer, the block terminator and the end of the last frame's pixels.
    var animation = try Animation.init(gif_animation[0 .. gif_animation.len - 4], &work);
    for (0..3) |_| _ = (try animation.next(&out)).?;
    try testing.expectError(error.Truncated, animation.next(&out));
}

test "wuffs reports corrupt and unsupported data" {
    var work: [testing_work_size]u8 = undefined;
    var out: [2 * 2 * 4]u8 = undefined;
    var png = png_2x1[0..png_2x1.len].*;
    // A pixel byte inside IDAT, so the chunk checksum fails.
    png[50] ^= 0xff;
    try testing.expectError(error.Corrupt, decode_first(&png, &out, &work));
    try testing.expectError(error.Unsupported, decode_first("plain text", &out, &work));
    try testing.expectError(error.Unsupported, decode_first("", &out, &work));
    const empty = qoi_header_only(0, 0);
    try testing.expectError(error.Corrupt, decode_first(&empty, &out, &work));
}

test "wuffs enforces the size limits" {
    var work: [testing_work_size]u8 = undefined;
    var out: [4]u8 = undefined;
    const wide = qoi_header_only(dimension_max + 1, 1);
    try testing.expectEqual(@as(?Info, null), probe(&wide));
    try testing.expectError(error.TooLarge, decode_first(&wide, &out, &work));
    // 8193 * 8193 is just over pixels_max with both sides within dimension_max.
    const many = qoi_header_only(8193, 8193);
    try testing.expect(@as(u64, 8193) * 8193 > pixels_max);
    try testing.expectError(error.TooLarge, decode_first(&many, &out, &work));
}

/// A QOI header and end marker with no pixels.
fn qoi_header_only(width: u32, height: u32) [22]u8 {
    var bytes: [22]u8 = @splat(0);
    bytes[0..4].* = "qoif".*;
    std.mem.writeInt(u32, bytes[4..8], width, .big);
    std.mem.writeInt(u32, bytes[8..12], height, .big);
    bytes[12] = 4;
    bytes[21] = 1;
    return bytes;
}
