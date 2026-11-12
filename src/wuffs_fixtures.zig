//! Tiny pictures for the src/wuffs.zig tests. They are built at compile time from their
//! pixels, so every expectation in a test sits next to the input it checks.

const std = @import("std");

pub const Rgba = [4]u8;

const fixture_size_max = 4096;
const eval_branch_quota = 200_000;
const gif_palette_entries = 4;
const gif_sub_block_max = 255;
const png_signature = "\x89PNG\r\n\x1a\n";

const Builder = struct {
    bytes: [fixture_size_max]u8 = undefined,
    len: usize = 0,

    fn put(b: *Builder, data: []const u8) void {
        @memcpy(b.bytes[b.len..][0..data.len], data);
        b.len += data.len;
    }

    fn byte(b: *Builder, value: u8) void {
        b.put(&.{value});
    }

    fn u16le(b: *Builder, value: u16) void {
        b.put(&.{ @truncate(value), @truncate(value >> 8) });
    }

    fn u32le(b: *Builder, value: u32) void {
        b.u16le(@truncate(value));
        b.u16le(@truncate(value >> 16));
    }

    fn u32be(b: *Builder, value: u32) void {
        b.put(&.{ @truncate(value >> 24), @truncate(value >> 16) });
        b.put(&.{ @truncate(value >> 8), @truncate(value) });
    }

    fn done(comptime b: Builder) []const u8 {
        const out = b.bytes[0..b.len].*;
        return &out;
    }
};

/// A bottom-up 24-bit BMP with a BITMAPINFOHEADER.
pub fn bmp24(comptime width: u32, comptime height: u32, comptime pixels: []const Rgba) []const u8 {
    comptime {
        std.debug.assert(pixels.len == width * height);
        const row_len = (width * 3 + 3) / 4 * 4;
        const header_len = 14 + 40;
        var b: Builder = .{};
        b.put("BM");
        b.u32le(header_len + row_len * height);
        b.u32le(0);
        b.u32le(header_len);
        b.u32le(40);
        b.u32le(width);
        b.u32le(height);
        b.u16le(1);
        b.u16le(24);
        b.u32le(0);
        b.u32le(row_len * height);
        b.put(&@as([16]u8, @splat(0)));
        for (0..height) |row| {
            const y = height - 1 - row;
            for (pixels[y * width ..][0..width]) |p| b.put(&.{ p[2], p[1], p[0] });
            for (width * 3..row_len) |_| b.byte(0);
        }
        return b.done();
    }
}

/// An uncompressed, top-down 32-bit TGA with 8 alpha bits.
pub fn tga32(comptime width: u16, comptime height: u16, comptime pixels: []const Rgba) []const u8 {
    comptime {
        std.debug.assert(pixels.len == @as(u32, width) * height);
        var b: Builder = .{};
        b.put(&.{ 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
        b.u16le(width);
        b.u16le(height);
        b.put(&.{ 32, 0x28 });
        for (pixels) |p| b.put(&.{ p[2], p[1], p[0], p[3] });
        return b.done();
    }
}

/// A four-channel QOI that spells every pixel with QOI_OP_RGBA.
pub fn qoi(comptime width: u32, comptime height: u32, comptime pixels: []const Rgba) []const u8 {
    comptime {
        std.debug.assert(pixels.len == width * height);
        var b: Builder = .{};
        b.put("qoif");
        b.u32be(width);
        b.u32be(height);
        b.put(&.{ 4, 0 });
        for (pixels) |p| b.put(&.{ 0xff, p[0], p[1], p[2], p[3] });
        b.put(&.{ 0, 0, 0, 0, 0, 0, 0, 1 });
        return b.done();
    }
}

pub const GifFrame = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    delay_cs: u16,
    /// The wire value: 1 keep, 2 restore background, 3 restore previous.
    disposal: u8,
    transparent: ?u8,
    indices: []const u8,
};

/// A GIF89a with a four-color global palette and an optional NETSCAPE2.0 loop count.
pub fn gif(
    comptime width: u16,
    comptime height: u16,
    comptime palette: [gif_palette_entries][3]u8,
    comptime loops: ?u16,
    comptime frames: []const GifFrame,
) []const u8 {
    comptime {
        @setEvalBranchQuota(eval_branch_quota);
        var b: Builder = .{};
        b.put("GIF89a");
        b.u16le(width);
        b.u16le(height);
        // Global palette of 2^(1+1) entries, 2-bit color resolution.
        b.put(&.{ 0x91, 0, 0 });
        for (palette) |rgb| b.put(&rgb);
        if (loops) |count| {
            b.put("\x21\xff\x0bNETSCAPE2.0\x03\x01");
            b.u16le(count);
            b.byte(0);
        }
        for (frames) |frame| gif_frame(&b, frame);
        b.byte(0x3b);
        return b.done();
    }
}

fn gif_frame(b: *Builder, comptime frame: GifFrame) void {
    std.debug.assert(frame.indices.len == @as(u32, frame.width) * frame.height);
    const transparent_flag: u8 = if (frame.transparent != null) 1 else 0;
    b.put(&.{ 0x21, 0xf9, 4, (frame.disposal << 2) | transparent_flag });
    b.u16le(frame.delay_cs);
    b.put(&.{ frame.transparent orelse 0, 0, 0x2c });
    b.u16le(frame.x);
    b.u16le(frame.y);
    b.u16le(frame.width);
    b.u16le(frame.height);
    b.put(&.{ 0, 2 });
    const data = gif_lzw(frame.indices);
    var start: usize = 0;
    while (start < data.len) {
        const n = @min(gif_sub_block_max, data.len - start);
        b.byte(n);
        b.put(data[start..][0..n]);
        start += n;
    }
    b.byte(0);
}

/// LZW with a 2-bit minimum code size that sends a clear code before every pixel, so
/// the table never grows and every code stays 3 bits wide.
fn gif_lzw(comptime indices: []const u8) []const u8 {
    const clear: u32 = 4;
    const end: u32 = 5;
    const code_bits = 3;
    var b: Builder = .{};
    var bits: u32 = 0;
    var bit_count: u32 = 0;
    for (0..indices.len * 2 + 1) |i| {
        const pixel = i % 2 == 1;
        const code: u32 = if (i == indices.len * 2) end else if (pixel) indices[i / 2] else clear;
        bits |= code << @as(u5, @intCast(bit_count));
        bit_count += code_bits;
        while (bit_count >= 8) {
            b.byte(@truncate(bits));
            bits >>= 8;
            bit_count -= 8;
        }
    }
    if (bit_count > 0) b.byte(@truncate(bits));
    return b.done();
}

pub const ApngFrame = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    delay_num: u16,
    delay_den: u16,
    /// 0 none, 1 background, 2 previous.
    dispose: u8,
    /// 0 source, 1 over.
    blend: u8,
    pixels: []const Rgba,
};

/// An 8-bit RGBA PNG without animation chunks.
pub fn png(comptime width: u32, comptime height: u32, comptime pixels: []const Rgba) []const u8 {
    comptime {
        @setEvalBranchQuota(eval_branch_quota);
        var b: Builder = .{};
        b.put(png_signature);
        png_header(&b, width, height);
        png_chunk(&b, "IDAT", png_zlib(width, height, pixels));
        png_chunk(&b, "IEND", "");
        return b.done();
    }
}

/// An 8-bit RGBA APNG whose first frame is also the default image.
pub fn apng(
    comptime width: u32,
    comptime height: u32,
    comptime plays: u32,
    comptime frames: []const ApngFrame,
) []const u8 {
    comptime {
        @setEvalBranchQuota(eval_branch_quota);
        var b: Builder = .{};
        b.put(png_signature);
        png_header(&b, width, height);
        var actl: Builder = .{};
        actl.u32be(frames.len);
        actl.u32be(plays);
        png_chunk(&b, "acTL", actl.done());
        var sequence: u32 = 0;
        for (frames, 0..) |frame, i| {
            var fctl: Builder = .{};
            fctl.u32be(sequence);
            fctl.u32be(frame.width);
            fctl.u32be(frame.height);
            fctl.u32be(frame.x);
            fctl.u32be(frame.y);
            fctl.put(&.{ frame.delay_num >> 8, frame.delay_num & 0xff });
            fctl.put(&.{ frame.delay_den >> 8, frame.delay_den & 0xff });
            fctl.put(&.{ frame.dispose, frame.blend });
            png_chunk(&b, "fcTL", fctl.done());
            sequence += 1;
            const data = png_zlib(frame.width, frame.height, frame.pixels);
            if (i == 0) {
                png_chunk(&b, "IDAT", data);
            } else {
                var fdat: Builder = .{};
                fdat.u32be(sequence);
                fdat.put(data);
                png_chunk(&b, "fdAT", fdat.done());
                sequence += 1;
            }
        }
        png_chunk(&b, "IEND", "");
        return b.done();
    }
}

fn png_header(b: *Builder, comptime width: u32, comptime height: u32) void {
    var ihdr: Builder = .{};
    ihdr.u32be(width);
    ihdr.u32be(height);
    ihdr.put(&.{ 8, 6, 0, 0, 0 });
    png_chunk(b, "IHDR", ihdr.done());
}

fn png_chunk(b: *Builder, comptime kind: *const [4]u8, comptime data: []const u8) void {
    b.u32be(data.len);
    b.put(kind);
    b.put(data);
    b.u32be(crc32(kind ++ data));
}

/// Filter-0 scanlines in one stored deflate block.
fn png_zlib(comptime width: u32, comptime height: u32, comptime pixels: []const Rgba) []const u8 {
    std.debug.assert(pixels.len == width * height);
    var raw: Builder = .{};
    for (0..height) |y| {
        raw.byte(0);
        for (pixels[y * width ..][0..width]) |p| raw.put(&p);
    }
    const data = raw.done();
    var b: Builder = .{};
    b.put(&.{ 0x78, 0x01, 0x01 });
    b.u16le(data.len);
    b.u16le(~@as(u16, data.len));
    b.put(data);
    b.u32be(adler32(data));
    return b.done();
}

fn crc32(data: []const u8) u32 {
    var crc: u32 = 0xffff_ffff;
    for (data) |value| {
        crc ^= value;
        for (0..8) |_| {
            const mask = 0 -% (crc & 1);
            crc = (crc >> 1) ^ (0xedb8_8320 & mask);
        }
    }
    return ~crc;
}

fn adler32(data: []const u8) u32 {
    const modulus = 65521;
    var a: u32 = 1;
    var s: u32 = 0;
    for (data) |value| {
        a = (a + value) % modulus;
        s = (s + a) % modulus;
    }
    return (s << 16) | a;
}
