//! EXIF orientation, and the upright size and quarter turns it implies.
const std = @import("std");
const builtin = @import("builtin");
const exif_mod = @import("exif.zig");
const sniff = @import("sniff.zig");
const assert = std.debug.assert;

const mac = builtin.os.tag == .macos;

/// Mirrored variants are shown unmirrored.
pub fn quarter_turns(exif: u8) u2 {
    const result: u2 = switch (exif) {
        3, 4 => 2,
        5, 6 => 1,
        7, 8 => 3,
        else => 0,
    };
    // Orientations 5 to 8 swap width and height: an odd number of turns.
    assert((exif >= 5 and exif <= 8) == (result % 2 == 1));
    return result;
}

/// The EXIF orientation of a JPEG, 1 unless found.
pub fn jpeg_exif(bytes: []const u8) u8 {
    if (sniff.detect(bytes) != .jpeg) return 1;
    const block = exif_mod.locate(.of_bytes(bytes)).exif orelse return 1;
    const value = exif_mod.walk(block).orientation orelse return 1;
    assert(value >= 1 and value <= 8);
    return @intCast(value);
}

/// macOS asks ImageIO, so HEIC and TIFF work too.
pub fn read(bytes: []const u8) u8 {
    const result = if (mac) image_io_orientation(bytes) else jpeg_exif(bytes);
    assert(result >= 1 and result <= 8);
    return result;
}

const image_io = struct {
    extern "c" const kCFAllocatorNull: *const anyopaque;
    extern "c" const kCGImagePropertyOrientation: *const anyopaque;
    extern "c" fn CFDataCreateWithBytesNoCopy(
        alloc: ?*const anyopaque,
        bytes: [*]const u8,
        len: isize,
        deallocator: *const anyopaque,
    ) ?*anyopaque;
    extern "c" fn CGImageSourceCreateWithData(data: *anyopaque, options: ?*anyopaque) ?*anyopaque;
    extern "c" fn CGImageSourceCopyPropertiesAtIndex(
        src: *anyopaque,
        index: usize,
        options: ?*anyopaque,
    ) ?*anyopaque;
    extern "c" fn CFDictionaryGetValue(dict: *anyopaque, key: *const anyopaque) ?*anyopaque;
    extern "c" fn CFNumberGetValue(n: *anyopaque, kind: c_int, out: *anyopaque) bool;
    extern "c" fn CFRelease(obj: *anyopaque) void;
};

fn image_io_orientation(bytes: []const u8) u8 {
    if (bytes.len == 0) return 1;
    const data = image_io.CFDataCreateWithBytesNoCopy(
        null,
        bytes.ptr,
        @intCast(bytes.len),
        image_io.kCFAllocatorNull,
    ) orelse return 1;
    defer image_io.CFRelease(data);
    const src = image_io.CGImageSourceCreateWithData(data, null) orelse return 1;
    defer image_io.CFRelease(src);
    const props = image_io.CGImageSourceCopyPropertiesAtIndex(src, 0, null) orelse return 1;
    defer image_io.CFRelease(props);
    const n = image_io.CFDictionaryGetValue(props, image_io.kCGImagePropertyOrientation) orelse
        return 1;
    var value: i32 = 1;
    // 3 is kCFNumberSInt32Type.
    if (!image_io.CFNumberGetValue(n, 3, &value)) return 1;
    if (value < 1 or value > 8) return 1;
    assert(value >= 1 and value <= 8);
    return @intCast(value);
}

pub const Upright = struct { raw_w: f32, raw_h: f32, turns: u2 };

/// On macOS nanoui's bitmap is already upright (ImageIO applies the EXIF
/// transform), so only the size swaps. Elsewhere the bitmap is raw and
/// the view turns it. macOS pictures of at most 256 px with EXIF rotation
/// are not transformed by nanoui and show with wrong proportions.
pub fn upright(header_w: f32, header_h: f32, exif: u8) Upright {
    assert(header_w > 0 and header_h > 0);
    assert(exif >= 1 and exif <= 8);
    if (mac) {
        if (exif >= 5) return .{ .raw_w = header_h, .raw_h = header_w, .turns = 0 };
        return .{ .raw_w = header_w, .raw_h = header_h, .turns = 0 };
    }
    return .{ .raw_w = header_w, .raw_h = header_h, .turns = quarter_turns(exif) };
}

const testing = std.testing;

fn jpeg_with_orientation(comptime big: bool, value: u8) [34]u8 {
    const tiff = if (big)
        [_]u8{ 'M', 'M', 0, 42, 0, 0, 0, 8, 0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, value, 0, 0 }
    else
        [_]u8{ 'I', 'I', 42, 0, 8, 0, 0, 0, 1, 0, 0x12, 0x01, 3, 0, 1, 0, 0, 0, value, 0, 0, 0 };
    const head = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE1, 0, 2 + 6 + tiff.len, 'E', 'x', 'i', 'f', 0, 0 };
    return head ++ tiff;
}

test "jpeg_exif finds the orientation" {
    try testing.expectEqual(@as(u8, 6), jpeg_exif(&jpeg_with_orientation(true, 6)));
    try testing.expectEqual(@as(u8, 8), jpeg_exif(&jpeg_with_orientation(false, 8)));
    const whole = jpeg_with_orientation(true, 6);
    var cut: usize = 0;
    while (cut < whole.len) : (cut += 1) {
        try testing.expectEqual(@as(u8, 1), jpeg_exif(whole[0..cut]));
    }
    try testing.expectEqual(@as(u8, 1), jpeg_exif("\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR"));
}

test "quarter_turns" {
    const want = [_]u2{ 0, 0, 0, 2, 2, 1, 1, 3, 3, 0 };
    for (want, 0..) |turns, exif| try testing.expectEqual(turns, quarter_turns(@intCast(exif)));
}
