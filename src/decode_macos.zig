//! ImageIO window-fit decoding into caller-owned premultiplied BGRA.
const std = @import("std");
const assert = std.debug.assert;
const decode = @import("decode.zig");
const Size = decode.Size;
const pixels_max = decode.pixels_max;

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
extern "c" fn CGImageSourceGetType(src: *anyopaque) ?*anyopaque;
extern "c" fn CFEqual(a: *const anyopaque, b: *const anyopaque) bool;
extern "c" fn CFStringCreateWithBytes(
    alloc: ?*anyopaque,
    bytes: [*]const u8,
    len: isize,
    encoding: u32,
    external: bool,
) ?*anyopaque;
extern "c" const kCGImageSourceTypeIdentifierHint: *const anyopaque;
const utf8_encoding: u32 = 0x08000100;

/// Camera RAW types built on TIFF that ImageIO takes for a plain TIFF unless told.
/// nanoui's decoder tries the same list.
const tiff_raw_types = [_][]const u8{
    "com.sony.arw-raw-image", "com.sony.sr2-raw-image",       "com.sony.raw-image",
    "com.nikon.raw-image",    "com.nikon.nrw-raw-image",      "com.pentax.raw-image",
    "com.epson.raw-image",    "com.hasselblad.fff-raw-image",
};

fn string(text: []const u8) ?*anyopaque {
    return CFStringCreateWithBytes(null, text.ptr, @intCast(text.len), utf8_encoding, false);
}

/// ImageIO reads many camera RAW files (NEF, ARW, PEF, …) as a plain TIFF and finds a
/// small preview or nothing; told the camera's type it reads the full picture. So a
/// TIFF is also opened as each RAW type built on TIFF, keeping the largest picture.
fn create_source(data: *anyopaque) ?*anyopaque {
    const plain = CGImageSourceCreateWithData(data, null) orelse return null;
    const kind = CGImageSourceGetType(plain) orelse return plain;
    const tiff = string("public.tiff") orelse return plain;
    defer CFRelease(tiff);
    if (!CFEqual(kind, tiff)) return plain;
    var best = plain;
    var best_area = area(plain);
    for (tiff_raw_types) |name| {
        const hinted = hinted_source(data, name) orelse continue;
        const hinted_area = area(hinted);
        if (hinted_area > best_area) {
            CFRelease(best);
            best = hinted;
            best_area = hinted_area;
        } else CFRelease(hinted);
    }
    return best;
}

fn hinted_source(data: *anyopaque, type_name: []const u8) ?*anyopaque {
    assert(type_name.len > 0);
    const name = string(type_name) orelse return null;
    defer CFRelease(name);
    const keys = [_]?*const anyopaque{kCGImageSourceTypeIdentifierHint};
    const values = [_]?*const anyopaque{name};
    const opts = CFDictionaryCreate(
        null,
        &keys,
        &values,
        keys.len,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks,
    ) orelse return null;
    defer CFRelease(opts);
    return CGImageSourceCreateWithData(data, opts);
}

/// The pixel count of the first picture's header size, 0 without one.
fn area(src: *anyopaque) u64 {
    const props = CGImageSourceCopyPropertiesAtIndex(src, 0, null) orelse return 0;
    defer CFRelease(props);
    var w: i32 = 0;
    var h: i32 = 0;
    if (CFDictionaryGetValue(props, kCGImagePropertyPixelWidth)) |n|
        _ = CFNumberGetValue(n, number_sint32, &w);
    if (CFDictionaryGetValue(props, kCGImagePropertyPixelHeight)) |n|
        _ = CFNumberGetValue(n, number_sint32, &h);
    if (w <= 0 or h <= 0) return 0;
    return @as(u64, @intCast(w)) * @as(u64, @intCast(h));
}

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
    const src = create_source(data) orelse return error.NotImage;
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
    if (CGImageGetWidth(img) == 0 or CGImageGetHeight(img) == 0) return error.NotImage;
    // RAW thumbnails can come out a pixel over the asked side: drawn into the bounds.
    const fitted = try decode.fit(
        @intCast(CGImageGetWidth(img)),
        @intCast(CGImageGetHeight(img)),
        bounds_w,
        bounds_h,
    );
    const w: usize = fitted.width;
    const h: usize = fitted.height;
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
