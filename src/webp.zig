//! WebP decoding over the vendored libwebp v1.6.0 (`vendor/libwebp`), through the flat
//! entry points in `webp_bridge.c`. Output is premultiplied BGRA, four bytes per pixel,
//! rows packed. libwebp allocates its own decoder state on the C heap; every pixel buffer
//! here belongs to the caller. Animations are composited in Zig on a caller-owned work
//! buffer, so one call to `Animation.next` copies one whole canvas out.

const std = @import("std");
const assert = std.debug.assert;

/// The WebP format itself stops at 16384, so this only guards a broken header.
pub const dimension_max: u32 = 65535;
pub const pixels_max: u64 = 64 * 1024 * 1024;
pub const frames_max: u32 = 10000;
pub const bytes_per_pixel: u32 = 4;

pub const Error = error{
    Corrupt,
    Truncated,
    Unsupported,
    TooLarge,
    TooManyFrames,
    OutputTooSmall,
    WorkTooSmall,
    OutOfMemory,
    Busy,
};

pub const Info = struct {
    width: u32,
    height: u32,
    frame_count: u32,
    /// Times to play the animation; 0 plays it forever. 0 for a still picture.
    loop_count: u32,
    has_alpha: bool,
    animated: bool,
};

pub const Size = struct {
    width: u32,
    height: u32,
};

pub const Frame = struct {
    /// Counts from 0 in display order.
    index: u32,
    /// As stored in the file; a viewer may raise tiny values to a minimum.
    delay_ms: u32,
};

const Features = extern struct {
    width: u32,
    height: u32,
    has_alpha: u32,
    has_animation: u32,
};

const Canvas = extern struct {
    width: u32,
    height: u32,
    frame_count: u32,
    loop_count: u32,
};

const FrameC = extern struct {
    data: [*]const u8,
    size: usize,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    duration_ms: u32,
    dispose_background: u32,
    blend: u32,
    has_alpha: u32,
};

extern fn nv_webp_get_features(data: [*]const u8, size: usize, out: *Features) c_int;
extern fn nv_webp_decode_bgra(
    data: [*]const u8,
    size: usize,
    out: [*]u8,
    out_size: usize,
    stride: u32,
    width: u32,
    height: u32,
) c_int;
extern fn nv_webp_demux_new(data: [*]const u8, size: usize, out: *?*anyopaque) c_int;
extern fn nv_webp_demux_delete(demux: ?*anyopaque) void;
extern fn nv_webp_demux_canvas(demux: *const anyopaque, out: *Canvas) void;
extern fn nv_webp_demux_frame(demux: *const anyopaque, number: u32, out: *FrameC) c_int;

/// libwebp fills its function tables on a decoder's first use with no lock (its
/// thread support is off), and the window and the preload worker both decode. One
/// decode at a time closes that; the wait is at most one frame's decode.
var decode_lock: std.atomic.Mutex = .unlocked;
/// Far more spins than the longest decode lasts: reaching it means a lost unlock.
const lock_spins_max: u64 = 1 << 36;

fn decode_bgra(
    data: [*]const u8,
    size: usize,
    out: []u8,
    stride: u32,
    width: u32,
    height: u32,
) Error!void {
    assert(width > 0 and height > 0 and stride >= width * bytes_per_pixel);
    var spins: u64 = 0;
    while (!decode_lock.tryLock()) : (spins += 1) {
        if (spins == lock_spins_max) return error.Busy;
        std.atomic.spinLoopHint();
    }
    defer decode_lock.unlock();
    try check(nv_webp_decode_bgra(data, size, out.ptr, out.len, stride, width, height));
}

/// libwebp's VP8StatusCode values.
const Status = enum(c_int) {
    ok = 0,
    out_of_memory = 1,
    invalid_param = 2,
    bitstream_error = 3,
    unsupported_feature = 4,
    suspended = 5,
    user_abort = 6,
    not_enough_data = 7,
    _,
};

fn check(status: c_int) Error!void {
    return switch (@as(Status, @fromBackingInt(@intCast(status)))) {
        .ok => {},
        .out_of_memory => error.OutOfMemory,
        .unsupported_feature => error.Unsupported,
        .not_enough_data, .suspended => error.Truncated,
        else => error.Corrupt,
    };
}

/// Reads the headers only. Null when `bytes` is not a WebP file this decoder can read.
pub fn probe(bytes: []const u8) ?Info {
    const info = read_info(bytes) catch return null;
    assert(info.width > 0 and info.height > 0);
    assert(info.frame_count > 0);
    return info;
}

/// Bytes of premultiplied BGRA that `decode_first` and `Animation.next` write.
pub fn bgra_size(width: u32, height: u32) u64 {
    assert(width > 0 and height > 0);
    return @as(u64, width) * height * bytes_per_pixel;
}

/// Work buffer `Animation.init` needs: the composited canvas plus room to decode one
/// frame before blending it.
pub fn animation_work_size(width: u32, height: u32) u64 {
    return 2 * bgra_size(width, height);
}

fn read_info(bytes: []const u8) Error!Info {
    var features: Features = undefined;
    try check(nv_webp_get_features(bytes.ptr, bytes.len, &features));
    var info: Info = .{
        .width = features.width,
        .height = features.height,
        .frame_count = 1,
        .loop_count = 0,
        .has_alpha = features.has_alpha != 0,
        .animated = features.has_animation != 0,
    };
    if (info.animated) {
        const demux = try demux_open(bytes);
        defer nv_webp_demux_delete(demux);
        var canvas: Canvas = undefined;
        nv_webp_demux_canvas(demux, &canvas);
        info.frame_count = canvas.frame_count;
        info.loop_count = canvas.loop_count;
    }
    if (info.frame_count == 0) return error.Corrupt;
    return info;
}

fn demux_open(bytes: []const u8) Error!*anyopaque {
    var demux: ?*anyopaque = null;
    try check(nv_webp_demux_new(bytes.ptr, bytes.len, &demux));
    return demux orelse error.Corrupt;
}

/// Checks the header sizes only, so a hostile file is refused before libwebp
/// allocates anything for its pixels.
fn check_size(width: u32, height: u32) Error!void {
    assert(width > 0 and height > 0);
    if (width > dimension_max or height > dimension_max) return error.TooLarge;
    if (@as(u64, width) * height > pixels_max) return error.TooLarge;
}

/// Decodes the first frame, composited on a transparent canvas, into `out_bgra`.
pub fn decode_first(bytes: []const u8, out_bgra: []u8, work: []u8) Error!Size {
    // libwebp keeps its scratch on its own heap; the parameter matches the other decoders.
    _ = work;
    var features: Features = undefined;
    try check(nv_webp_get_features(bytes.ptr, bytes.len, &features));
    try check_size(features.width, features.height);
    const size: Size = .{ .width = features.width, .height = features.height };
    const canvas_bytes = bgra_size(size.width, size.height);
    if (out_bgra.len < canvas_bytes) return error.OutputTooSmall;
    const canvas = out_bgra[0..@intCast(canvas_bytes)];
    if (features.has_animation == 0) {
        try decode_bgra(
            bytes.ptr,
            bytes.len,
            canvas,
            size.width * bytes_per_pixel,
            size.width,
            size.height,
        );
        return size;
    }
    const demux = try demux_open(bytes);
    defer nv_webp_demux_delete(demux);
    var info: Canvas = undefined;
    nv_webp_demux_canvas(demux, &info);
    assert(info.width == size.width and info.height == size.height);
    if (info.frame_count == 0) return error.Corrupt;
    if (info.frame_count > frames_max) return error.TooManyFrames;
    var frame: FrameC = undefined;
    try check(nv_webp_demux_frame(demux, 1, &frame));
    // Over a transparent canvas, blending and replacing give the same pixels.
    @memset(canvas, 0);
    try paste(canvas, size.width, size.height, frame);
    return size;
}

const Rect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

fn frame_rect(frame: FrameC, width: u32, height: u32) Error!Rect {
    if (@as(u64, frame.x) + frame.width > width) return error.Corrupt;
    if (@as(u64, frame.y) + frame.height > height) return error.Corrupt;
    assert(frame.width > 0 and frame.height > 0);
    return .{ .x = frame.x, .y = frame.y, .width = frame.width, .height = frame.height };
}

/// Decodes `frame` straight into its place on `canvas`, replacing what was there.
fn paste(canvas: []u8, width: u32, height: u32, frame: FrameC) Error!void {
    const rect = try frame_rect(frame, width, height);
    const offset = (@as(usize, rect.y) * width + rect.x) * bytes_per_pixel;
    assert(offset < canvas.len);
    const target = canvas[offset..];
    try decode_bgra(
        frame.data,
        frame.size,
        target,
        width * bytes_per_pixel,
        rect.width,
        rect.height,
    );
}

/// Rounds `x / 255` for `x` up to 255 * 255.
fn div_255(x: u32) u32 {
    assert(x <= 255 * 255);
    return (x + 128 + ((x + 128) >> 8)) >> 8;
}

/// Premultiplied source-over of `source` (rows packed) onto `rect` of `canvas`.
fn blend_over(canvas: []u8, width: u32, rect: Rect, source: []const u8) void {
    assert(source.len == @as(usize, rect.width) * rect.height * bytes_per_pixel);
    assert(rect.x + rect.width <= width);
    var row: u32 = 0;
    while (row < rect.height) : (row += 1) {
        const canvas_row = (@as(usize, rect.y + row) * width + rect.x) * bytes_per_pixel;
        const source_row = @as(usize, row) * rect.width * bytes_per_pixel;
        var byte: usize = 0;
        while (byte < @as(usize, rect.width) * bytes_per_pixel) : (byte += bytes_per_pixel) {
            const src = source[source_row + byte ..][0..4];
            const dst = canvas[canvas_row + byte ..][0..4];
            const keep: u32 = 255 - @as(u32, src[3]);
            for (dst, src) |*d, s| {
                d.* = @intCast(@min(255, @as(u32, s) + div_255(@as(u32, d.*) * keep)));
            }
        }
    }
}

fn clear_rect(canvas: []u8, width: u32, rect: Rect) void {
    assert(rect.x + rect.width <= width);
    var row: u32 = 0;
    while (row < rect.height) : (row += 1) {
        const start = (@as(usize, rect.y + row) * width + rect.x) * bytes_per_pixel;
        @memset(canvas[start..][0 .. @as(usize, rect.width) * bytes_per_pixel], 0);
    }
}

/// Plays an animated (or still) WebP frame by frame. `bytes` and `work` must outlive it.
/// After an error from `next`, call `reset` before playing again.
pub const Animation = struct {
    demux: *anyopaque,
    width: u32,
    height: u32,
    frame_count: u32,
    /// Times to play the animation; 0 plays it forever.
    loop_count: u32,
    frame_next: u32,
    /// The frame shown last asked for its area to be cleared before the next one.
    dispose: ?Rect,
    canvas: []u8,
    scratch: []u8,

    pub fn init(bytes: []const u8, work: []u8) Error!Animation {
        var features: Features = undefined;
        try check(nv_webp_get_features(bytes.ptr, bytes.len, &features));
        try check_size(features.width, features.height);
        const canvas_bytes: usize = @intCast(bgra_size(features.width, features.height));
        if (work.len < animation_work_size(features.width, features.height)) {
            return error.WorkTooSmall;
        }
        const demux = try demux_open(bytes);
        errdefer nv_webp_demux_delete(demux);
        var info: Canvas = undefined;
        nv_webp_demux_canvas(demux, &info);
        if (info.width != features.width or info.height != features.height) {
            return error.Corrupt;
        }
        if (info.frame_count == 0) return error.Corrupt;
        if (info.frame_count > frames_max) return error.TooManyFrames;
        var animation: Animation = .{
            .demux = demux,
            .width = info.width,
            .height = info.height,
            .frame_count = info.frame_count,
            .loop_count = info.loop_count,
            .frame_next = 0,
            .dispose = null,
            .canvas = work[0..canvas_bytes],
            .scratch = work[canvas_bytes..][0..canvas_bytes],
        };
        animation.reset();
        return animation;
    }

    pub fn deinit(self: *Animation) void {
        nv_webp_demux_delete(self.demux);
        self.* = undefined;
    }

    /// Starts over at the first frame on a transparent canvas.
    pub fn reset(self: *Animation) void {
        assert(self.canvas.len == bgra_size(self.width, self.height));
        self.frame_next = 0;
        self.dispose = null;
        @memset(self.canvas, 0);
    }

    /// Composites the next frame and copies the whole canvas into `canvas`. Null after
    /// the last frame; `reset` starts the next loop.
    pub fn next(self: *Animation, canvas: []u8) Error!?Frame {
        assert(self.frame_next <= self.frame_count);
        if (canvas.len < self.canvas.len) return error.OutputTooSmall;
        if (self.frame_next == self.frame_count) return null;
        var frame: FrameC = undefined;
        try check(nv_webp_demux_frame(self.demux, self.frame_next + 1, &frame));
        const rect = try frame_rect(frame, self.width, self.height);
        if (self.dispose) |area| clear_rect(self.canvas, self.width, area);
        self.dispose = null;
        if (frame.blend != 0 and frame.has_alpha != 0) {
            const bytes = @as(usize, rect.width) * rect.height * bytes_per_pixel;
            const source = self.scratch[0..bytes];
            try decode_bgra(
                frame.data,
                frame.size,
                source,
                rect.width * bytes_per_pixel,
                rect.width,
                rect.height,
            );
            blend_over(self.canvas, self.width, rect, source);
        } else {
            try paste(self.canvas, self.width, self.height, frame);
        }
        if (frame.dispose_background != 0) self.dispose = rect;
        @memcpy(canvas[0..self.canvas.len], self.canvas);
        self.frame_next += 1;
        return .{ .index = self.frame_next - 1, .delay_ms = frame.duration_ms };
    }
};

// Fixtures, made with libwebp 1.6.0 from tiny PNM inputs (nix develop -c nix shell
// nixpkgs#libwebp -c sh; T=/tmp/nanoview-webp; P is the 2x2 PAM header
// "P7\nWIDTH 2\nHEIGHT 2\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n"):
//   lossy.ppm: "P6\n8 8\n255\n" then 64 times \310\050\050 (RGB 200,40,40)
//   alpha.pam: P, then RGBA 255,0,0,255  0,255,0,128  0,0,255,0  255,255,255,255
//   frame1.pam: P, then 4 times RGBA 255,0,0,255
//   frame2.pam: P, then RGBA 0,0,0,0, then 3 times 0,0,255,255
//   cwebp -quiet -q 90 -metadata none $T/lossy.ppm -o webp_lossy.webp
//   cwebp -quiet -lossless -exact -metadata none $T/alpha.pam -o webp_lossless_alpha.webp
//   cwebp -quiet -lossless -exact -metadata none $T/frame1.pam -o $T/frame1.webp
//   cwebp -quiet -lossless -exact -metadata none $T/frame2.pam -o $T/frame2.webp
//   webpmux -frame $T/frame1.webp +100+0+0+0-b -frame $T/frame2.webp +250+0+0+0+b \
//     -loop 3 -bgcolor 255,255,255,255 -o webp_anim.webp
// The second frame blends, so its transparent corner keeps the first frame's red.
const fixture_lossy = @embedFile("testdata/webp_lossy.webp");
const fixture_alpha = @embedFile("testdata/webp_lossless_alpha.webp");
const fixture_anim = @embedFile("testdata/webp_anim.webp");

const testing = std.testing;
const bgra_red = [4]u8{ 0, 0, 255, 255 };
const bgra_blue = [4]u8{ 255, 0, 0, 255 };

fn expect_pixel(pixels: []const u8, index: usize, expected: [4]u8, tolerance: u8) !void {
    const got = pixels[index * 4 ..][0..4];
    for (got, expected) |g, e| {
        const diff = if (g > e) g - e else e - g;
        if (diff > tolerance) {
            std.debug.print("pixel {d}: got {any}, expected {any}\n", .{ index, got.*, expected });
            return error.TestUnexpectedResult;
        }
    }
}

fn expect_broken(result: anytype) !void {
    if (result) |_| {
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expect(err == error.Corrupt or err == error.Truncated);
    }
}

test "webp lossy probe and decode" {
    const info = probe(fixture_lossy).?;
    try testing.expectEqual(Info{
        .width = 8,
        .height = 8,
        .frame_count = 1,
        .loop_count = 0,
        .has_alpha = false,
        .animated = false,
    }, info);
    var out: [8 * 8 * 4]u8 = undefined;
    const size = try decode_first(fixture_lossy, &out, &.{});
    try testing.expectEqual(Size{ .width = 8, .height = 8 }, size);
    // dwebp gives 199,40,39 for the 200,40,40 source; lossy allows a little drift.
    for (0..64) |index| try expect_pixel(&out, index, .{ 39, 40, 199, 255 }, 3);
}

test "webp lossless alpha is premultiplied" {
    const info = probe(fixture_alpha).?;
    try testing.expect(info.has_alpha and !info.animated);
    try testing.expectEqual(@as(u32, 2), info.width);
    var out: [2 * 2 * 4]u8 = @splat(0xAA);
    _ = try decode_first(fixture_alpha, &out, &.{});
    try expect_pixel(&out, 0, bgra_red, 0);
    // Green at alpha 128 premultiplies to about half intensity.
    try expect_pixel(&out, 1, .{ 0, 128, 0, 128 }, 1);
    // -exact kept blue under alpha 0; premultiplying clears it.
    try expect_pixel(&out, 2, .{ 0, 0, 0, 0 }, 0);
    try expect_pixel(&out, 3, .{ 255, 255, 255, 255 }, 0);
}

test "webp animation probe and first frame" {
    try testing.expectEqual(Info{
        .width = 2,
        .height = 2,
        .frame_count = 2,
        .loop_count = 3,
        .has_alpha = true,
        .animated = true,
    }, probe(fixture_anim).?);
    var out: [2 * 2 * 4]u8 = @splat(0xAA);
    _ = try decode_first(fixture_anim, &out, &.{});
    for (0..4) |index| try expect_pixel(&out, index, bgra_red, 0);
}

fn expect_anim_frames(animation: *Animation, canvas: []u8) !void {
    const first = (try animation.next(canvas)).?;
    try testing.expectEqual(Frame{ .index = 0, .delay_ms = 100 }, first);
    for (0..4) |index| try expect_pixel(canvas, index, bgra_red, 0);
    const second = (try animation.next(canvas)).?;
    try testing.expectEqual(Frame{ .index = 1, .delay_ms = 250 }, second);
    try expect_pixel(canvas, 0, bgra_red, 0);
    for (1..4) |index| try expect_pixel(canvas, index, bgra_blue, 0);
    try testing.expectEqual(@as(?Frame, null), try animation.next(canvas));
    try testing.expectEqual(@as(?Frame, null), try animation.next(canvas));
}

test "webp animation composites, loops and resets" {
    var work: [2 * 2 * 4 * 2]u8 = undefined;
    try testing.expectEqual(@as(u64, work.len), animation_work_size(2, 2));
    var animation = try Animation.init(fixture_anim, &work);
    defer animation.deinit();
    try testing.expectEqual(@as(u32, 3), animation.loop_count);
    try testing.expectEqual(@as(u32, 2), animation.frame_count);
    var canvas: [2 * 2 * 4]u8 = @splat(0xAA);
    try expect_anim_frames(&animation, &canvas);
    animation.reset();
    try expect_anim_frames(&animation, &canvas);
}

test "webp still picture plays as one frame" {
    var work: [2 * 2 * 4 * 2]u8 = undefined;
    var animation = try Animation.init(fixture_alpha, &work);
    defer animation.deinit();
    try testing.expectEqual(@as(u32, 1), animation.frame_count);
    var canvas: [2 * 2 * 4]u8 = undefined;
    const frame = (try animation.next(&canvas)).?;
    try testing.expectEqual(@as(u32, 0), frame.index);
    try expect_pixel(&canvas, 1, .{ 0, 128, 0, 128 }, 1);
    try testing.expectEqual(@as(?Frame, null), try animation.next(&canvas));
}

test "webp small buffers are refused" {
    var out: [2 * 2 * 4 - 1]u8 = undefined;
    try testing.expectError(error.OutputTooSmall, decode_first(fixture_alpha, &out, &.{}));
    try testing.expectError(error.OutputTooSmall, decode_first(fixture_anim, &out, &.{}));
    var work_short: [2 * 2 * 4 * 2 - 1]u8 = undefined;
    try testing.expectError(error.WorkTooSmall, Animation.init(fixture_anim, &work_short));
    var work: [2 * 2 * 4 * 2]u8 = undefined;
    var animation = try Animation.init(fixture_anim, &work);
    defer animation.deinit();
    try testing.expectError(error.OutputTooSmall, animation.next(&out));
}

test "webp malformed input" {
    const garbage = "this is not a webp picture at all";
    try testing.expectEqual(@as(?Info, null), probe(garbage));
    try testing.expectEqual(@as(?Info, null), probe(""));
    var out: [64 * 4]u8 = undefined;
    var work: [64 * 4 * 2]u8 = undefined;
    try expect_broken(decode_first(garbage, &out, &.{}));
    try expect_broken(Animation.init(garbage, &work));
    // A frame chunk that claims more bytes than the file holds.
    var lying: [fixture_anim.len]u8 = fixture_anim.*;
    lying[4] +%= 64;
    lying[48] +%= 64;
    try testing.expectEqual(@as(?Info, null), probe(&lying));
    try expect_broken(Animation.init(&lying, &work));
}

test "webp truncated input" {
    var out: [64 * 4]u8 = undefined;
    var work: [64 * 4 * 2]u8 = undefined;
    const fixtures = [_][]const u8{ fixture_lossy, fixture_alpha, fixture_anim };
    for (fixtures) |fixture| {
        const cuts = [_]usize{ 0, 11, 20, fixture.len / 2, fixture.len - 1 };
        for (cuts) |cut| {
            try expect_broken(decode_first(fixture[0..cut], &out, &.{}));
            try expect_broken(Animation.init(fixture[0..cut], &work));
        }
    }
    try testing.expectEqual(@as(?Info, null), probe(fixture_anim[0 .. fixture_anim.len - 1]));
    try testing.expectError(
        error.Truncated,
        Animation.init(fixture_anim[0 .. fixture_anim.len - 1], &work),
    );
}

/// RIFF + VP8X header for an animated canvas, with no frames after it.
fn vp8x_header(width: u32, height: u32) [30]u8 {
    var header: [30]u8 = undefined;
    @memcpy(header[0..4], "RIFF");
    std.mem.writeInt(u32, header[4..8], header.len - 8, .little);
    @memcpy(header[8..16], "WEBPVP8X");
    std.mem.writeInt(u32, header[16..20], 10, .little);
    // Flags: animation.
    std.mem.writeInt(u32, header[20..24], 0x02, .little);
    std.mem.writeInt(u24, header[24..27], @intCast(width - 1), .little);
    std.mem.writeInt(u24, header[27..30], @intCast(height - 1), .little);
    return header;
}

test "webp limits apply before decoding" {
    var out: [64 * 4]u8 = undefined;
    var work: [64 * 4 * 2]u8 = undefined;
    const sizes = [_][2]u32{
        .{ dimension_max + 1, 1 },
        .{ 1, dimension_max + 1 },
        .{ 9000, 9000 },
    };
    for (sizes) |size| {
        const header = vp8x_header(size[0], size[1]);
        try testing.expectError(error.TooLarge, decode_first(&header, &out, &.{}));
        try testing.expectError(error.TooLarge, Animation.init(&header, &work));
    }
    // Inside the limits the same empty header is only short of frames.
    const small = vp8x_header(8, 8);
    try expect_broken(decode_first(&small, &out, &.{}));
    try expect_broken(Animation.init(&small, &work));
}
