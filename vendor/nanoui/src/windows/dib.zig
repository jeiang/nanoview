//! Device-independent bitmaps, as the Windows clipboard carries pictures:
//! a CF_DIBV5 written from premultiplied BGRA, and a CF_DIB or CF_DIBV5
//! read back as a BMP file, which the system's decoders take. No Win32
//! here, so the layout is tested on any system.
const std = @import("std");

pub const v5_header_size = 124;
pub const file_header_size = 14;
const bi_rgb = 0;
const bi_bitfields = 3;
const bi_alphabitfields = 6;
const lcs_srgb = 0x73524742; // 'sRGB'
const lcs_gm_images = 4;

/// Bytes of a CF_DIBV5 for a `width` by `height` picture.
pub fn v5Size(width: u32, height: u32) usize {
    return v5_header_size + @as(usize, width) * height * 4;
}

/// Writes a BITMAPV5HEADER and the rows bottom-up with straight alpha, as
/// CF_DIBV5 has them (and as apps that ignore the height's sign read
/// them), to `out`, `v5Size` bytes. `bgra` is premultiplied, top-down.
pub fn writeV5(out: []u8, bgra: []const u8, width: u32, height: u32) void {
    const row = @as(usize, width) * 4;
    std.debug.assert(out.len == v5Size(width, height) and bgra.len == row * height);
    const h = out[0..v5_header_size];
    @memset(h, 0);
    put(u32, h, 0, v5_header_size);
    put(u32, h, 4, width);
    put(u32, h, 8, height);
    put(u16, h, 12, 1);
    put(u16, h, 14, 32);
    put(u32, h, 16, bi_bitfields);
    put(u32, h, 20, @intCast(row * height));
    put(u32, h, 40, 0x00FF0000);
    put(u32, h, 44, 0x0000FF00);
    put(u32, h, 48, 0x000000FF);
    put(u32, h, 52, 0xFF000000);
    put(u32, h, 56, lcs_srgb);
    put(u32, h, 108, lcs_gm_images);
    const pixels = out[v5_header_size..];
    for (0..height) |y| {
        const src = bgra[y * row ..][0..row];
        const dst = pixels[(height - 1 - y) * row ..][0..row];
        for (0..width) |x| dst[x * 4 ..][0..4].* = straight(src[x * 4 ..][0..4].*);
    }
}

fn straight(p: [4]u8) [4]u8 {
    const a: u32 = p[3];
    if (a == 0) return .{ 0, 0, 0, 0 };
    var out = p;
    for (0..3) |i| out[i] = @intCast(@min(255, (@as(u32, p[i]) * 255 + a / 2) / a));
    return out;
}

/// Where the pixels start in a DIB: after its header, its bit masks
/// (outside the header only for a BITMAPINFOHEADER) and its color table.
/// Null for a DIB too short for what its header says.
pub fn pixelOffset(dib: []const u8) ?usize {
    if (dib.len < 12) return null;
    const size = get(u32, dib, 0);
    var offset: usize = undefined;
    if (size == 12) {
        // BITMAPCOREHEADER: three-byte color entries.
        const bits = get(u16, dib, 10);
        offset = 12 + (if (bits <= 8) @as(usize, 3) << @intCast(bits) else 0);
    } else {
        if (size < 40 or dib.len < 40) return null;
        const bits = get(u16, dib, 14);
        const compression = get(u32, dib, 16);
        const used = get(u32, dib, 32);
        const masks: usize = if (size != 40) 0 else switch (compression) {
            bi_bitfields => 12,
            bi_alphabitfields => 16,
            else => 0,
        };
        const colors: usize = if (used != 0) used else if (bits <= 8) @as(usize, 1) << @intCast(bits) else 0;
        if (colors > 256) return null;
        offset = @as(usize, size) + masks + colors * 4;
    }
    return if (offset <= dib.len) offset else null;
}

/// The BITMAPFILEHEADER that makes `dib` a BMP file, or null for a DIB
/// that is not whole.
pub fn fileHeader(dib: []const u8) ?[file_header_size]u8 {
    const offset = pixelOffset(dib) orelse return null;
    if (dib.len > std.math.maxInt(u32) - file_header_size) return null;
    var h: [file_header_size]u8 = @splat(0);
    h[0] = 'B';
    h[1] = 'M';
    put(u32, &h, 2, @intCast(file_header_size + dib.len));
    put(u32, &h, 10, @intCast(file_header_size + offset));
    return h;
}

fn put(comptime T: type, out: []u8, at: usize, v: T) void {
    std.mem.writeInt(T, out[at..][0..@sizeOf(T)], v, .little);
}

fn get(comptime T: type, in: []const u8, at: usize) T {
    return std.mem.readInt(T, in[at..][0..@sizeOf(T)], .little);
}

const testing = std.testing;

test "a V5 DIB is bottom-up with straight alpha and sRGB bit fields" {
    // Top row: opaque red; bottom row: half-transparent gray, premultiplied.
    const bgra = [_]u8{ 0, 0, 255, 255, 64, 64, 64, 128 };
    var out: [v5_header_size + 8]u8 = undefined;
    writeV5(&out, &bgra, 1, 2);
    try testing.expectEqual(@as(u32, 124), get(u32, &out, 0));
    try testing.expectEqual(@as(u32, 1), get(u32, &out, 4));
    try testing.expectEqual(@as(u32, 2), get(u32, &out, 8));
    try testing.expectEqual(@as(u16, 32), get(u16, &out, 14));
    try testing.expectEqual(@as(u32, bi_bitfields), get(u32, &out, 16));
    try testing.expectEqual(@as(u32, 0xFF000000), get(u32, &out, 52));
    try testing.expectEqual(@as(u32, lcs_srgb), get(u32, &out, 56));
    try testing.expectEqualSlices(u8, &.{ 128, 128, 128, 128, 0, 0, 255, 255 }, out[124..]);
    try testing.expectEqual(@as(?usize, 124), pixelOffset(&out));
}

test "transparent pixels lose their color rather than divide by zero" {
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, straight(.{ 9, 9, 9, 0 }));
    try testing.expectEqual([4]u8{ 255, 0, 255, 1 }, straight(.{ 1, 0, 1, 1 }));
}

test "pixels start after masks and color tables, and a short DIB is refused" {
    var dib: [40 + 1024]u8 = @splat(0);
    put(u32, &dib, 0, 40);
    put(u16, &dib, 14, 32);
    put(u32, &dib, 16, bi_bitfields);
    try testing.expectEqual(@as(?usize, 52), pixelOffset(&dib));
    put(u32, &dib, 16, bi_rgb);
    try testing.expectEqual(@as(?usize, 40), pixelOffset(&dib));
    put(u16, &dib, 14, 8);
    try testing.expectEqual(@as(?usize, 40 + 1024), pixelOffset(&dib));
    put(u32, &dib, 32, 2);
    try testing.expectEqual(@as(?usize, 48), pixelOffset(&dib));
    put(u32, &dib, 32, 0);
    try testing.expectEqual(@as(?usize, null), pixelOffset(dib[0..100]));
    var core: [12 + 768]u8 = @splat(0);
    put(u32, &core, 0, 12);
    put(u16, &core, 10, 8);
    try testing.expectEqual(@as(?usize, 780), pixelOffset(&core));
    try testing.expectEqual(@as(?usize, null), pixelOffset(core[0..11]));
}

test "a DIB becomes a BMP file with the pixel offset counted from the file" {
    var dib: [40 + 4]u8 = @splat(0);
    put(u32, &dib, 0, 40);
    put(u16, &dib, 14, 32);
    const h = fileHeader(&dib).?;
    try testing.expectEqualStrings("BM", h[0..2]);
    try testing.expectEqual(@as(u32, 14 + 44), get(u32, &h, 2));
    try testing.expectEqual(@as(u32, 14 + 40), get(u32, &h, 10));
    try testing.expect(fileHeader(dib[0..20]) == null);
}
