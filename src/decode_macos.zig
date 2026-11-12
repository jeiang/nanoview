//! ImageIO window-fit decoding into caller-owned premultiplied BGRA.
const std = @import("std");
const assert = std.debug.assert;
const Size = @import("decode.zig").Size;
const pixels_max = @import("decode.zig").pixels_max;

const CGRect = extern struct { x: f64, y: f64, w: f64, h: f64 };
extern "c" const kCFAllocatorNull: *const anyopaque;
extern "c" const kCFBooleanTrue: *const anyopaque;
extern "c" const kCFTypeDictionaryKeyCallBacks: opaque {};
extern "c" const kCFTypeDictionaryValueCallBacks: opaque {};
extern "c" const kCGImagePropertyOrientation: *const anyopaque;
extern "c" const kCGImagePropertyPixelWidth: *const anyopaque;
extern "c" const kCGImagePropertyPixelHeight: *const anyopaque;
extern "c" const kCGImageSourceCreateThumbnailFromImageAlways: *const anyopaque;
extern "c" const kCGImageSourceThumbnailMaxPixelSize: *const anyopaque;
extern "c" const kCGImageSourceCreateThumbnailWithTransform: *const anyopaque;
extern "c" const kCGColorSpaceSRGB: *const anyopaque;
extern "c" fn CFDataCreateWithBytesNoCopy(
    alloc: ?*const anyopaque,
    bytes: [*]const u8,
    len: isize,
    deallocator: *const anyopaque,
) ?*anyopaque;
extern "c" fn CFRelease(obj: *anyopaque) void;
extern "c" fn CFDictionaryGetValue(dict: *anyopaque, key: *const anyopaque) ?*anyopaque;
extern "c" fn CFNumberGetValue(n: *anyopaque, kind: c_int, out: *anyopaque) bool;
extern "c" fn CFNumberCreate(
    alloc: ?*anyopaque,
    kind: c_int,
    value: *const anyopaque,
) ?*anyopaque;
extern "c" fn CFDictionaryCreate(
    alloc: ?*anyopaque,
    keys: [*]const ?*const anyopaque,
    values: [*]const ?*const anyopaque,
    n: isize,
    key_cb: *const anyopaque,
    value_cb: *const anyopaque,
) ?*anyopaque;
extern "c" fn CGImageSourceCreateWithData(data: *anyopaque, options: ?*anyopaque) ?*anyopaque;
extern "c" fn CGImageSourceCopyPropertiesAtIndex(
    src: *anyopaque,
    index: usize,
    options: ?*anyopaque,
) ?*anyopaque;
extern "c" fn CGImageSourceCreateThumbnailAtIndex(
    src: *anyopaque,
    index: usize,
    options: ?*anyopaque,
) ?*anyopaque;
extern "c" fn CGImageGetWidth(img: *anyopaque) usize;
extern "c" fn CGImageGetHeight(img: *anyopaque) usize;
extern "c" fn CGImageRelease(img: *anyopaque) void;
extern "c" fn CGColorSpaceCreateWithName(name: *const anyopaque) ?*anyopaque;
extern "c" fn CGColorSpaceRelease(space: *anyopaque) void;
extern "c" fn CGBitmapContextCreate(
    data: ?*anyopaque,
    w: usize,
    h: usize,
    bpc: usize,
    bpr: usize,
    space: ?*anyopaque,
    info: u32,
) ?*anyopaque;
extern "c" fn CGContextRelease(ctx: *anyopaque) void;
extern "c" fn CGBitmapContextGetData(ctx: *anyopaque) ?[*]u8;
extern "c" fn CGContextClearRect(ctx: *anyopaque, rect: CGRect) void;
extern "c" fn CGContextSetInterpolationQuality(ctx: *anyopaque, quality: c_int) void;
extern "c" fn CGContextDrawImage(ctx: *anyopaque, rect: CGRect, image: *anyopaque) void;

/// Premultiplied BGRA, little endian, as nanoui draws pixels.
const bgra_premultiplied: u32 = 2 | (2 << 12);
const number_sint32: c_int = 3;

const Native = struct { w: u32, h: u32 };

/// The upright full size from the header and the EXIF orientation.
fn native_size(src: *anyopaque) !Native {
    const props = CGImageSourceCopyPropertiesAtIndex(src, 0, null) orelse return error.NotImage;
    defer CFRelease(props);
    var w: i32 = 0;
    var h: i32 = 0;
    var orientation: i32 = 1;
    if (CFDictionaryGetValue(props, kCGImagePropertyPixelWidth)) |n|
        _ = CFNumberGetValue(n, number_sint32, &w);
    if (CFDictionaryGetValue(props, kCGImagePropertyPixelHeight)) |n|
        _ = CFNumberGetValue(n, number_sint32, &h);
    if (CFDictionaryGetValue(props, kCGImagePropertyOrientation)) |n|
        _ = CFNumberGetValue(n, number_sint32, &orientation);
    if (w <= 0 or h <= 0) return error.NotImage;
    if (@as(u64, @intCast(w)) * @as(u64, @intCast(h)) > pixels_max) return error.TooLarge;
    const swap = orientation >= 5 and orientation <= 8;
    const result: Native = if (swap)
        .{ .w = @intCast(h), .h = @intCast(w) }
    else
        .{ .w = @intCast(w), .h = @intCast(h) };
    assert(result.w > 0 and result.h > 0);
    return result;
}

fn thumbnail(src: *anyopaque, side: i32) !*anyopaque {
    assert(side > 0);
    const max_n = CFNumberCreate(null, number_sint32, &side) orelse return error.Data;
    defer CFRelease(max_n);
    const keys = [_]?*const anyopaque{
        kCGImageSourceCreateThumbnailFromImageAlways,
        kCGImageSourceThumbnailMaxPixelSize,
        kCGImageSourceCreateThumbnailWithTransform,
    };
    const values = [_]?*const anyopaque{ kCFBooleanTrue, max_n, kCFBooleanTrue };
    const opts = CFDictionaryCreate(
        null,
        &keys,
        &values,
        keys.len,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks,
    ) orelse return error.Data;
    defer CFRelease(opts);
    return CGImageSourceCreateThumbnailAtIndex(src, 0, opts) orelse error.NotImage;
}

pub fn decode_fit(encoded: []const u8, out: []u8, bounds_w: u32, bounds_h: u32) !Size {
    assert(bounds_w > 0 and bounds_h > 0);
    if (encoded.len == 0) return error.NotImage;
    const len: isize = @intCast(encoded.len);
    const data = CFDataCreateWithBytesNoCopy(null, encoded.ptr, len, kCFAllocatorNull) orelse
        return error.Data;
    defer CFRelease(data);
    const src = CGImageSourceCreateWithData(data, null) orelse return error.NotImage;
    defer CFRelease(src);
    const native = try native_size(src);
    const nw: f64 = @floatFromInt(native.w);
    const nh: f64 = @floatFromInt(native.h);
    const bw: f64 = @floatFromInt(bounds_w);
    const bh: f64 = @floatFromInt(bounds_h);
    const s = @min(1, @min(bw / nw, bh / nh));
    const side: i32 = @intFromFloat(@max(1, @ceil(@max(nw, nh) * s)));
    const img = try thumbnail(src, side);
    defer CGImageRelease(img);
    const w = CGImageGetWidth(img);
    const h = CGImageGetHeight(img);
    if (w == 0 or h == 0) return error.NotImage;
    if (w * h * 4 > out.len) return error.TooLarge;
    const pixels = out[0 .. w * h * 4];
    @memset(pixels, 0);
    const space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB) orelse return error.ColorSpace;
    defer CGColorSpaceRelease(space);
    const info = bgra_premultiplied;
    const ctx = CGBitmapContextCreate(pixels.ptr, w, h, 8, w * 4, space, info) orelse
        return error.BitmapContext;
    defer CGContextRelease(ctx);
    CGContextSetInterpolationQuality(ctx, 3);
    const rect: CGRect = .{ .x = 0, .y = 0, .w = @floatFromInt(w), .h = @floatFromInt(h) };
    CGContextDrawImage(ctx, rect, img);
    return .{
        .width = @intCast(w),
        .height = @intCast(h),
        .native_w = native.w,
        .native_h = native.h,
    };
}

/// A full-size decode in memory the system allocates: for handing the
/// picture to another app (the clipboard) while the fixed buffers are in
/// use for showing it. `release` frees it.
pub const Full = struct {
    context: *anyopaque,
    bgra: []const u8,
    width: u32,
    height: u32,

    pub fn release(f: Full) void {
        CGContextRelease(f.context);
    }
};

pub fn decode_full(encoded: []const u8) !Full {
    if (encoded.len == 0) return error.NotImage;
    const len: isize = @intCast(encoded.len);
    const data = CFDataCreateWithBytesNoCopy(null, encoded.ptr, len, kCFAllocatorNull) orelse
        return error.Data;
    defer CFRelease(data);
    const src = CGImageSourceCreateWithData(data, null) orelse return error.NotImage;
    defer CFRelease(src);
    const native = try native_size(src);
    const img = try thumbnail(src, @intCast(@max(native.w, native.h)));
    defer CGImageRelease(img);
    const w = CGImageGetWidth(img);
    const h = CGImageGetHeight(img);
    if (w == 0 or h == 0) return error.NotImage;
    if (w * h > pixels_max) return error.TooLarge;
    const space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB) orelse return error.ColorSpace;
    defer CGColorSpaceRelease(space);
    const context = CGBitmapContextCreate(null, w, h, 8, w * 4, space, bgra_premultiplied) orelse
        return error.BitmapContext;
    errdefer CGContextRelease(context);
    const pixels = CGBitmapContextGetData(context) orelse return error.BitmapContext;
    const rect: CGRect = .{ .x = 0, .y = 0, .w = @floatFromInt(w), .h = @floatFromInt(h) };
    CGContextClearRect(context, rect);
    CGContextDrawImage(context, rect, img);
    assert(w <= std.math.maxInt(u32) and h <= std.math.maxInt(u32));
    return .{
        .context = context,
        .bgra = pixels[0 .. w * h * 4],
        .width = @intCast(w),
        .height = @intCast(h),
    };
}
