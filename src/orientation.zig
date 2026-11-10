//! EXIF orientation, and the upright size and quarter turns it implies.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const mac = builtin.os.tag == .macos;
const segments_max: u32 = 64;
const ifd_entries_max: u32 = 256;
const tag_orientation: u16 = 0x0112;

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
    if (bytes.len < 4 or bytes[0] != 0xFF or bytes[1] != 0xD8) return 1;
    var at: usize = 2;
    var segment: u32 = 0;
    while (segment < segments_max) : (segment += 1) {
        if (at + 4 > bytes.len or bytes[at] != 0xFF) return 1;
        const marker = bytes[at + 1];
        if (marker == 0xDA or marker == 0xD9) return 1;
        const len = std.mem.readInt(u16, bytes[at + 2 ..][0..2], .big);
        if (len < 2 or at + 2 + len > bytes.len) return 1;
        const payload = bytes[at + 4 .. at + 2 + len];
        assert(payload.len == len - 2);
        if (marker == 0xE1 and std.mem.startsWith(u8, payload, "Exif\x00\x00")) {
            return tiff_orientation(payload[6..]);
        }
        at += 2 + len;
        assert(at <= bytes.len);
    }
    return 1;
}

fn tiff_orientation(tiff: []const u8) u8 {
    if (tiff.len < 8) return 1;
    const endian: std.builtin.Endian = if (std.mem.eql(u8, tiff[0..2], "II"))
        .little
    else if (std.mem.eql(u8, tiff[0..2], "MM"))
        .big
    else
        return 1;
    if (std.mem.readInt(u16, tiff[2..4], endian) != 42) return 1;
    const ifd = std.mem.readInt(u32, tiff[4..8], endian);
    if (ifd > tiff.len or tiff.len - ifd < 2) return 1;
    assert(ifd + 2 <= tiff.len);
    const count = @min(std.mem.readInt(u16, tiff[ifd..][0..2], endian), ifd_entries_max);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const entry = ifd + 2 + i * 12;
        if (entry + 12 > tiff.len) return 1;
        const tag = std.mem.readInt(u16, tiff[entry..][0..2], endian);
        const kind = std.mem.readInt(u16, tiff[entry + 2 ..][0..2], endian);
        if (tag != tag_orientation or kind != 3) continue;
        const value = std.mem.readInt(u16, tiff[entry + 8 ..][0..2], endian);
        assert(entry + 12 <= tiff.len);
        if (value >= 1 and value <= 8) return @intCast(value);
        return 1;
    }
    return 1;
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
