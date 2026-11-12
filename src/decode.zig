//! One entry to the decoders: the system's first, then the bundled ones. Both share
//! fixed caller storage and give upright premultiplied BGRA.
const std = @import("std");
const builtin = @import("builtin");
const webp = @import("webp.zig");
const wuffs = @import("wuffs.zig");
const animation = @import("animation.zig");
const assert = std.debug.assert;
pub const pixels_max: u64 = 64 * 1000 * 1000;
pub const file_size_max: u32 = 256 * 1024 * 1024;
pub const supported = switch (builtin.os.tag) {
    .macos, .linux, .windows => true,
    else => false,
};
pub const pages_max: u32 = 65535;
/// `page_count`: the file's pages (TIFF pages, ICO sizes, any ImageIO or WIC images
/// that are not an animation's frames); 1 for single pictures.
pub const Size = struct {
    width: u32,
    height: u32,
    native_w: u32,
    native_h: u32,
    page_count: u32 = 1,
};

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

/// Decodes page `page` of the file. Only ImageIO and WIC choose a page: gdk-pixbuf
/// and the bundled decoders read the first, and their count is 1.
pub fn decode_fit(bytes: []const u8, out: []u8, bw: u32, bh: u32, page: u32) !Size {
    if (bytes.len == 0) return error.NotImage;
    if (bytes.len > file_size_max) return error.TooLarge;
    if (bw == 0 or bh == 0) return error.NotImage;
    if (page >= pages_max) return error.NoPage;
    const system: anyerror!Size = switch (builtin.os.tag) {
        .macos => @import("decode_macos.zig").decode_fit(bytes, out, bw, bh, page),
        .linux => if (page == 0)
            @import("decode_linux.zig").decode_fit(bytes, out, bw, bh)
        else
            error.NoPage,
        .windows => @import("decode_windows.zig").decode_fit(bytes, out, bw, bh, page),
        else => error.Unavailable,
    };
    // The system's error is the one to report: `Unavailable` selects nanoui's decoders.
    var size = system catch |err| {
        if (page > 0) return err;
        return decode_bundled(bytes, out, bw, bh) catch err;
    };
    size.page_count = pages(bytes, size.page_count);
    if (page >= size.page_count) return error.NoPage;
    return size;
}

/// The page count without decoding, for files that nanoui decodes itself.
pub fn page_count(bytes: []const u8) u32 {
    if (bytes.len == 0 or bytes.len > file_size_max) return 1;
    const count: u32 = switch (builtin.os.tag) {
        .macos => @import("decode_macos.zig").page_count(bytes),
        .windows => @import("decode_windows.zig").page_count(bytes),
        else => 1,
    };
    return pages(bytes, count);
}

/// An animation's frames are not pages.
fn pages(bytes: []const u8, count: u32) u32 {
    if (count <= 1 or animation.detect(bytes) != null) return 1;
    return @min(count, pages_max);
}

/// True for data that only the bundled decoders read on this system, so the
/// caller must not hand the encoded bytes to nanoui. ImageIO has no QOI.
pub fn bundled_only(bytes: []const u8) bool {
    return builtin.os.tag == .macos and std.mem.startsWith(u8, bytes, "qoif");
}

const Bundled = struct { width: u32, height: u32, webp: bool };

/// PNG stays with the system and nanoui: Wuffs needs a work buffer of up to 8 bytes
/// per pixel for it. Animated pictures give their first frame.
fn probe_bundled(bytes: []const u8) ?Bundled {
    if (webp.probe(bytes)) |info| {
        return .{ .width = info.width, .height = info.height, .webp = true };
    }
    const info = wuffs.probe(bytes) orelse return null;
    if (info.format == .png or info.work_size_still > wuffs_work_max) return null;
    return .{ .width = info.width, .height = info.height, .webp = false };
}

const wuffs_work_max: u32 = wuffs.state_size_max + wuffs.state_align_max;

/// Decodes at the native size into `out`, then shrinks in place to the bounds. A
/// picture whose native pixels do not fit `out` fails: the preload slots are small,
/// so a large one is decoded only when it is shown.
fn decode_bundled(bytes: []const u8, out: []u8, bw: u32, bh: u32) !Size {
    const found = probe_bundled(bytes) orelse return error.NotImage;
    const size = try fit(found.width, found.height, bw, bh);
    const native_len = @as(u64, found.width) * found.height * 4;
    if (native_len > out.len) return error.TooLarge;
    const native = out[0..@intCast(native_len)];
    if (found.webp) {
        _ = try webp.decode_first(bytes, native, &.{});
    } else {
        var work: [wuffs_work_max]u8 align(wuffs.state_align_max) = undefined;
        _ = try wuffs.decode_first(bytes, native, &work);
    }
    shrink(native, found.width, found.height, size.width, size.height);
    return size;
}

/// Averages blocks of the `w` by `h` picture at the start of `pixels` into a `dw` by
/// `dh` picture at the same place. Each destination pixel lies at or before the
/// first source pixel of its block, so no pixel is overwritten before it is read.
fn shrink(pixels: []u8, w: u32, h: u32, dw: u32, dh: u32) void {
    assert(dw > 0 and dh > 0 and dw <= w and dh <= h);
    assert(pixels.len >= @as(u64, w) * h * 4);
    if (dw == w and dh == h) return;
    for (0..dh) |dy| {
        const y0 = dy * h / dh;
        const y1 = @max(y0 + 1, (dy + 1) * h / dh);
        for (0..dw) |dx| {
            const x0 = dx * w / dw;
            const x1 = @max(x0 + 1, (dx + 1) * w / dw);
            var sum: [4]u64 = @splat(0);
            for (y0..y1) |y| {
                for (pixels[(y * w + x0) * 4 .. (y * w + x1) * 4], 0..) |value, i| {
                    sum[i % 4] += value;
                }
            }
            const count = (y1 - y0) * (x1 - x0);
            const to = pixels[(dy * dw + dx) * 4 ..][0..4];
            for (to, sum) |*channel, total| channel.* = @intCast(total / count);
        }
    }
}

/// Fixed, known raster names only; used for inventory intersection on Linux and
/// Windows. BMP, QOI, TGA and WebP are absent: the bundled decoders always read them.
pub const known_extensions = [_][]const u8{
    "avif", "heic", "heif", "tif", "tiff", "dib", "ico", "cur", "ani",  "pnm",
    "pbm",  "pgm",  "ppm",  "pam", "pcx",  "ras", "xbm", "xpm", "icns", "jxl",
    "jp2",  "j2k",  "jpf",  "jpx", "dds",  "jxr", "wdp",
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
    try t.expectError(error.NotImage, decode_fit(&.{}, &.{}, 20, 20, 0));
}

test "installed extensions intersect a fixed inventory without duplicates" {
    var out: [known_extensions.len][]const u8 = undefined;
    const n = intersect(&.{ "svg", "pdf", "TIFF", "tiff", "ico", "unknown" }, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("tiff", out[0]);
    try std.testing.expectEqualStrings("ico", out[1]);
    try std.testing.expectEqual(@as(usize, 0), intersect(&.{}, &out));
    try std.testing.expectEqual(@as(usize, 1), intersect(&.{ "ico", "tiff" }, out[0..1]));
}

test "a bundled picture decodes at its size and shrinks to the bounds" {
    const t = std.testing;
    const fixtures = @import("wuffs_fixtures.zig");
    const red: fixtures.Rgba = .{ 255, 0, 0, 255 };
    const blue: fixtures.Rgba = .{ 0, 0, 255, 255 };
    const file = comptime fixtures.qoi(4, 2, &.{ red, red, blue, blue, red, red, blue, blue });
    var out: [4 * 2 * 4]u8 = undefined;
    const full = try decode_bundled(file, &out, 100, 100);
    try t.expectEqual(Size{ .width = 4, .height = 2, .native_w = 4, .native_h = 2 }, full);
    try t.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, out[0..4]);
    const half = try decode_bundled(file, &out, 2, 2);
    try t.expectEqual(Size{ .width = 2, .height = 1, .native_w = 4, .native_h = 2 }, half);
    try t.expectEqualSlices(u8, &.{ 0, 0, 255, 255, 255, 0, 0, 255 }, out[0..8]);
    try t.expectError(error.TooLarge, decode_bundled(file, out[0..8], 2, 2));
    try t.expectError(error.NotImage, decode_bundled("not a picture", &out, 2, 2));
}
