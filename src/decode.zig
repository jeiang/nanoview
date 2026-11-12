//! System decoders share fixed caller storage and upright premultiplied BGRA output.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
pub const pixels_max: u64 = 64 * 1000 * 1000;
pub const file_size_max: u32 = 256 * 1024 * 1024;
pub const supported = switch (builtin.os.tag) {
    .macos, .linux, .windows => true,
    else => false,
};
pub const Size = struct { width: u32, height: u32, native_w: u32, native_h: u32 };

pub fn fit(w: u32, h: u32, bw: u32, bh: u32) !Size {
    if (w == 0 or h == 0 or bw == 0 or bh == 0) return error.NotImage;
    if (@as(u64, w) * h > pixels_max) return error.TooLarge;
    const scale_w = @as(f64, @floatFromInt(bw)) / @as(f64, @floatFromInt(w));
    const scale_h = @as(f64, @floatFromInt(bh)) / @as(f64, @floatFromInt(h));
    const scale = @min(1, @min(scale_w, scale_h));
    const result: Size = .{
        .width = @intFromFloat(@max(1, @floor(@as(f64, @floatFromInt(w)) * scale))),
        .height = @intFromFloat(@max(1, @floor(@as(f64, @floatFromInt(h)) * scale))),
        .native_w = w,
        .native_h = h,
    };
    assert(result.width <= w and result.height <= h);
    assert(result.width <= bw and result.height <= bh);
    return result;
}

pub fn decode_fit(bytes: []const u8, out: []u8, bw: u32, bh: u32) !Size {
    if (bytes.len == 0) return error.NotImage;
    if (bytes.len > file_size_max) return error.TooLarge;
    if (bw == 0 or bh == 0) return error.NotImage;
    return switch (builtin.os.tag) {
        .macos => @import("decode_macos.zig").decode_fit(bytes, out, bw, bh),
        .linux => @import("decode_linux.zig").decode_fit(bytes, out, bw, bh),
        .windows => @import("decode_windows.zig").decode_fit(bytes, out, bw, bh),
        else => error.Unavailable,
    };
}

/// Fixed, known raster names only; used for inventory intersection on every OS.
pub const known_extensions = [_][]const u8{
    "avif", "heic", "heif", "webp", "tif", "tiff", "bmp", "dib", "ico", "cur",
    "ani",  "pnm",  "pbm",  "pgm",  "ppm", "pam",  "pcx", "ras", "tga", "targa",
    "xbm",  "xpm",  "icns", "jxl",  "jp2", "j2k",  "jpf", "jpx", "qoi",
};
pub fn intersect(names: []const []const u8, out: [][]const u8) usize {
    assert(names.len <= 256);
    var count: usize = 0;
    for (known_extensions) |known| {
        for (names) |name| {
            if (!std.ascii.eqlIgnoreCase(known, name)) continue;
            if (count == out.len) return count;
            out[count] = known;
            count += 1;
            break;
        }
    }
    assert(count <= out.len);
    return count;
}

test "fit bounds dimensions without enlarging and rejects excessive pixels" {
    const t = std.testing;
    const wide: Size = .{ .width = 400, .height = 200, .native_w = 2000, .native_h = 1000 };
    try t.expectEqual(wide, try fit(2000, 1000, 400, 400));
    try t.expectEqual(@as(u32, 20), (try fit(20, 10, 400, 400)).width);
    try t.expectEqual(@as(u32, 1), (try fit(1, 64000000, 20, 20)).width);
    try t.expectError(error.TooLarge, fit(8001, 8000, 1, 1));
    try t.expectError(error.NotImage, fit(0, 20, 20, 20));
    try t.expectError(error.NotImage, fit(20, 20, 0, 20));
    try t.expectError(error.NotImage, decode_fit(&.{}, &.{}, 20, 20));
}

test "installed extensions intersect a fixed inventory without duplicates" {
    var out: [known_extensions.len][]const u8 = undefined;
    const n = intersect(&.{ "svg", "pdf", "TIFF", "tiff", "bmp", "unknown" }, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("tiff", out[0]);
    try std.testing.expectEqualStrings("bmp", out[1]);
    try std.testing.expectEqual(@as(usize, 0), intersect(&.{}, &out));
    try std.testing.expectEqual(@as(usize, 1), intersect(&.{ "bmp", "webp" }, out[0..1]));
}
