//! Writes rendered frames to PNG files with ImageIO.
const std = @import("std");
const cf = @import("cf.zig");
const metal = @import("metal.zig");

const CGImageRef = *opaque {};
const CFURLRef = *opaque {};
const CGImageDestinationRef = *opaque {};
extern "c" fn CGBitmapContextCreateImage(ctx: cf.CGContextRef) ?CGImageRef;
extern "c" fn CGImageRelease(img: CGImageRef) void;
extern "c" fn CFURLCreateFromFileSystemRepresentation(alloc: ?*anyopaque, path: [*]const u8, len: cf.CFIndex, is_dir: bool) ?CFURLRef;
extern "c" fn CGImageDestinationCreateWithURL(url: CFURLRef, kind: cf.CFStringRef, count: usize, options: ?*anyopaque) ?CGImageDestinationRef;
extern "c" fn CGImageDestinationAddImage(dest: CGImageDestinationRef, img: CGImageRef, props: ?*anyopaque) void;
extern "c" fn CGImageDestinationFinalize(dest: CGImageDestinationRef) bool;

/// Premultiplied BGRA, little endian: `kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little`.
const bgra_premultiplied: u32 = 2 | (2 << 12);

pub fn writePng(path: []const u8, pixels: metal.Pixels) !void {
    const space = cf.CGColorSpaceCreateWithName(cf.kCGColorSpaceSRGB) orelse return error.ColorSpace;
    defer cf.CGColorSpaceRelease(space);
    const ctx = cf.CGBitmapContextCreate(pixels.bytes.ptr, pixels.width, pixels.height, 8, pixels.width * 4, space, bgra_premultiplied) orelse
        return error.BitmapContext;
    defer cf.CGContextRelease(ctx);
    const img = CGBitmapContextCreateImage(ctx) orelse return error.Image;
    defer CGImageRelease(img);
    const url = CFURLCreateFromFileSystemRepresentation(null, path.ptr, @intCast(path.len), false) orelse return error.Url;
    defer cf.CFRelease(url);
    const kind = cf.string("public.png");
    defer cf.CFRelease(kind);
    const dest = CGImageDestinationCreateWithURL(url, kind, 1, null) orelse return error.Destination;
    defer cf.CFRelease(dest);
    CGImageDestinationAddImage(dest, img, null);
    if (!CGImageDestinationFinalize(dest)) return error.WriteFailed;
}

const CFDataRef = *opaque {};
const CGImageSourceRef = *opaque {};
extern "c" fn CFDataCreate(alloc: ?*anyopaque, bytes: [*]const u8, len: cf.CFIndex) ?CFDataRef;
extern "c" fn CGImageSourceCreateWithData(data: CFDataRef, options: ?*anyopaque) ?CGImageSourceRef;
extern "c" fn CGImageSourceCreateImageAtIndex(src: CGImageSourceRef, index: usize, options: ?*anyopaque) ?CGImageRef;
extern "c" fn CGImageGetWidth(img: CGImageRef) usize;
extern "c" fn CGImageGetHeight(img: CGImageRef) usize;
extern "c" fn CGContextDrawImage(ctx: cf.CGContextRef, rect: @import("../objc.zig").CGRect, image: CGImageRef) void;
extern "c" fn CGContextSetInterpolationQuality(ctx: cf.CGContextRef, quality: c_int) void;
extern "c" fn CGImageSourceGetType(src: CGImageSourceRef) ?cf.CFStringRef;
extern "c" fn CFEqual(a: *const anyopaque, b: *const anyopaque) bool;
extern "c" const kCGImageSourceTypeIdentifierHint: cf.CFStringRef;

/// Camera RAW types built on TIFF that ImageIO takes for a plain TIFF unless told.
const tiff_raw_types = [_][]const u8{
    "com.sony.arw-raw-image",  "com.sony.sr2-raw-image",       "com.sony.raw-image",
    "com.nikon.raw-image",     "com.nikon.nrw-raw-image",      "com.pentax.raw-image",
    "com.epson.raw-image",     "com.hasselblad.fff-raw-image",
};

/// An image source for `data`. ImageIO reads many camera RAW files (NEF, ARW, PEF, …)
/// as a plain TIFF and finds a small preview or nothing; told the camera's type it
/// reads the full picture. So a TIFF is also opened as each RAW type built on TIFF,
/// and the source with the largest picture is kept.
fn createSource(data: CFDataRef) ?CGImageSourceRef {
    const plain = CGImageSourceCreateWithData(data, null) orelse return null;
    const kind = CGImageSourceGetType(plain) orelse return plain;
    const tiff = cf.string("public.tiff");
    defer cf.CFRelease(tiff);
    if (!CFEqual(kind, tiff)) return plain;
    var best = plain;
    var best_area = area(plain);
    for (tiff_raw_types) |name| {
        const hinted = hintedSource(data, name) orelse continue;
        const a = area(hinted);
        if (a > best_area) {
            cf.CFRelease(best);
            best = hinted;
            best_area = a;
        } else cf.CFRelease(hinted);
    }
    return best;
}

fn hintedSource(data: CFDataRef, type_name: []const u8) ?CGImageSourceRef {
    const name = cf.string(type_name);
    defer cf.CFRelease(name);
    const keys = [_]?*const anyopaque{kCGImageSourceTypeIdentifierHint};
    const values = [_]?*const anyopaque{name};
    const opts = cf.CFDictionaryCreate(null, &keys, &values, 1, &cf.kCFTypeDictionaryKeyCallBacks, &cf.kCFTypeDictionaryValueCallBacks) orelse return null;
    defer cf.CFRelease(opts);
    return CGImageSourceCreateWithData(data, @ptrCast(opts));
}

/// The pixel count of the first picture's header size, 0 without one.
fn area(src: CGImageSourceRef) u64 {
    const props = CGImageSourceCopyPropertiesAtIndex(src, 0, null) orelse return 0;
    defer cf.CFRelease(props);
    var width: i32 = 0;
    var height: i32 = 0;
    if (CFDictionaryGetValue(props, kCGImagePropertyPixelWidth)) |n| _ = CFNumberGetValue(n, 3, &width);
    if (CFDictionaryGetValue(props, kCGImagePropertyPixelHeight)) |n| _ = CFNumberGetValue(n, 3, &height);
    if (width <= 0 or height <= 0) return 0;
    return @as(u64, @intCast(width)) * @as(u64, @intCast(height));
}

pub const Decoded = struct { width: u32, height: u32, bgra: []u8 };

/// Any image ImageIO reads (PNG, JPEG, GIF, HEIC, …) as premultiplied BGRA.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) !Decoded {
    const data = CFDataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse return error.Data;
    defer cf.CFRelease(data);
    const src = createSource(data) orelse return error.NotImage;
    defer cf.CFRelease(src);
    const img = CGImageSourceCreateImageAtIndex(src, 0, null) orelse return error.NotImage;
    defer CGImageRelease(img);
    const w = CGImageGetWidth(img);
    const h = CGImageGetHeight(img);
    if (w == 0 or h == 0 or w * h > 64 * 1024 * 1024) return error.TooLarge;
    const out = try gpa.alloc(u8, w * h * 4);
    errdefer gpa.free(out);
    @memset(out, 0);
    const space = cf.CGColorSpaceCreateWithName(cf.kCGColorSpaceSRGB) orelse return error.ColorSpace;
    defer cf.CGColorSpaceRelease(space);
    const ctx = cf.CGBitmapContextCreate(out.ptr, w, h, 8, w * 4, space, bgra_premultiplied) orelse return error.BitmapContext;
    defer cf.CGContextRelease(ctx);
    CGContextDrawImage(ctx, .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = @floatFromInt(w), .height = @floatFromInt(h) } }, img);
    return .{ .width = @intCast(w), .height = @intCast(h), .bgra = out };
}

extern "c" fn CGImageSourceCreateThumbnailAtIndex(src: CGImageSourceRef, index: usize, options: ?*anyopaque) ?CGImageRef;
extern "c" fn CGImageSourceCopyPropertiesAtIndex(src: CGImageSourceRef, index: usize, options: ?*anyopaque) ?*anyopaque;
extern "c" fn CFDictionaryGetValue(dict: *anyopaque, key: *const anyopaque) ?*anyopaque;
extern "c" fn CFNumberGetValue(n: *anyopaque, kind: c_int, out: *anyopaque) bool;
extern "c" fn CFNumberCreate(alloc: ?*anyopaque, kind: c_int, value: *const anyopaque) ?*anyopaque;
extern "c" const kCGImageSourceCreateThumbnailFromImageAlways: cf.CFStringRef;
extern "c" const kCGImageSourceThumbnailMaxPixelSize: cf.CFStringRef;
extern "c" const kCGImageSourceCreateThumbnailWithTransform: cf.CFStringRef;
extern "c" const kCGImagePropertyPixelWidth: cf.CFStringRef;
extern "c" const kCGImagePropertyPixelHeight: cf.CFStringRef;

pub const Fitted = struct { width: u32, height: u32, w: u32, h: u32, bgra: []u8 };
pub const Dimensions = struct { width: u32, height: u32 };

/// A picture's header dimensions without decoding its pixels.
pub fn dimensions(bytes: []const u8) ?Dimensions {
    const data = CFDataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse return null;
    defer cf.CFRelease(data);
    const src = createSource(data) orelse return null;
    defer cf.CFRelease(src);
    var width: i32 = 0;
    var height: i32 = 0;
    if (CGImageSourceCopyPropertiesAtIndex(src, 0, null)) |props| {
        defer cf.CFRelease(props);
        if (CFDictionaryGetValue(props, kCGImagePropertyPixelWidth)) |n| _ = CFNumberGetValue(n, 3, &width);
        if (CFDictionaryGetValue(props, kCGImagePropertyPixelHeight)) |n| _ = CFNumberGetValue(n, 3, &height);
    }
    if (width <= 0 or height <= 0) {
        const img = CGImageSourceCreateImageAtIndex(src, 0, null) orelse return null;
        defer CGImageRelease(img);
        width = @intCast(CGImageGetWidth(img));
        height = @intCast(CGImageGetHeight(img));
    }
    if (width <= 0 or height <= 0 or @as(u64, @intCast(width)) * @as(u64, @intCast(height)) > 64 * 1024 * 1024) return null;
    return .{ .width = @intCast(width), .height = @intCast(height) };
}

/// A picture decoded straight to at most `max_side` pixels (ImageIO scales
/// while it decodes: no full-size copy is made), with its own size.
pub fn decodeFit(gpa: std.mem.Allocator, bytes: []const u8, max_side: u32) !Fitted {
    const data = CFDataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse return error.Data;
    defer cf.CFRelease(data);
    const src = createSource(data) orelse return error.NotImage;
    defer cf.CFRelease(src);
    // Its own size, from its header.
    var width: i32 = 0;
    var height: i32 = 0;
    if (CGImageSourceCopyPropertiesAtIndex(src, 0, null)) |props| {
        defer cf.CFRelease(props);
        if (CFDictionaryGetValue(props, kCGImagePropertyPixelWidth)) |n| _ = CFNumberGetValue(n, 3, &width);
        if (CFDictionaryGetValue(props, kCGImagePropertyPixelHeight)) |n| _ = CFNumberGetValue(n, 3, &height);
    }
    const orig_w: u32 = if (width > 0) @intCast(width) else 0;
    const orig_h: u32 = if (height > 0) @intCast(height) else 0;
    const orig_longest: u32 = @max(orig_w, orig_h);
    if (orig_longest > 0 and orig_longest <= 256) {
        const img = CGImageSourceCreateImageAtIndex(src, 0, null) orelse return error.NotImage;
        defer CGImageRelease(img);
        const iw = CGImageGetWidth(img);
        const ih = CGImageGetHeight(img);
        if (iw == 0 or ih == 0) return error.NotImage;
        const longest: u32 = @intCast(@max(iw, ih));
        const side = @min(max_side, longest);
        const w: usize = @max(1, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(iw)) * @as(f64, @floatFromInt(side)) / @as(f64, @floatFromInt(longest))))));
        const h: usize = @max(1, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(ih)) * @as(f64, @floatFromInt(side)) / @as(f64, @floatFromInt(longest))))));
        const out = try gpa.alloc(u8, w * h * 4);
        errdefer gpa.free(out);
        @memset(out, 0);
        const space = cf.CGColorSpaceCreateWithName(cf.kCGColorSpaceSRGB) orelse return error.ColorSpace;
        defer cf.CGColorSpaceRelease(space);
        const ctx = cf.CGBitmapContextCreate(out.ptr, w, h, 8, w * 4, space, bgra_premultiplied) orelse return error.BitmapContext;
        defer cf.CGContextRelease(ctx);
        CGContextSetInterpolationQuality(ctx, 3);
        CGContextDrawImage(ctx, .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = @floatFromInt(w), .height = @floatFromInt(h) } }, img);
        return .{
            .width = @intCast(iw),
            .height = @intCast(ih),
            .w = @intCast(w),
            .h = @intCast(h),
            .bgra = out,
        };
    }
    const side: i32 = @intCast(@min(max_side, if (orig_w > 0 and orig_h > 0) @max(orig_w, orig_h) else max_side));
    const max_n = CFNumberCreate(null, 3, &side) orelse return error.Data;
    defer cf.CFRelease(max_n);
    const keys = [_]?*const anyopaque{ kCGImageSourceCreateThumbnailFromImageAlways, kCGImageSourceThumbnailMaxPixelSize, kCGImageSourceCreateThumbnailWithTransform };
    const values = [_]?*const anyopaque{ cf.kCFBooleanTrue, max_n, cf.kCFBooleanTrue };
    const opts = cf.CFDictionaryCreate(null, &keys, &values, 3, &cf.kCFTypeDictionaryKeyCallBacks, &cf.kCFTypeDictionaryValueCallBacks) orelse return error.Data;
    defer cf.CFRelease(opts);
    const img = CGImageSourceCreateThumbnailAtIndex(src, 0, @ptrCast(@constCast(opts))) orelse return error.NotImage;
    defer CGImageRelease(img);
    const w = CGImageGetWidth(img);
    const h = CGImageGetHeight(img);
    if (w == 0 or h == 0) return error.NotImage;
    const out = try gpa.alloc(u8, w * h * 4);
    errdefer gpa.free(out);
    @memset(out, 0);
    const space = cf.CGColorSpaceCreateWithName(cf.kCGColorSpaceSRGB) orelse return error.ColorSpace;
    defer cf.CGColorSpaceRelease(space);
    const ctx = cf.CGBitmapContextCreate(out.ptr, w, h, 8, w * 4, space, bgra_premultiplied) orelse return error.BitmapContext;
    defer cf.CGContextRelease(ctx);
    CGContextSetInterpolationQuality(ctx, 3);
    CGContextDrawImage(ctx, .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = @floatFromInt(w), .height = @floatFromInt(h) } }, img);
    return .{
        .width = if (width > 0) @intCast(width) else @intCast(w),
        .height = if (height > 0) @intCast(height) else @intCast(h),
        .w = @intCast(w),
        .h = @intCast(h),
        .bgra = out,
    };
}
