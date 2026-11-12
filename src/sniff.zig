//! A picture's format from its first bytes, whatever the file is called. TGA has no
//! signature: it is known by its extension alone.
const std = @import("std");
const assert = std.debug.assert;

/// Bytes `detect` looks at; a shorter head is fine.
pub const head_len_max: u32 = 64;

pub const Format = enum {
    png,
    jpeg,
    gif,
    webp,
    bmp,
    qoi,
    tiff,
    heic,
    heif,
    avif,
    jxl,
    ico,
    psd,
    jp2,
    exr,
    dds,
    icns,

    /// The name the info line shows.
    pub fn label(f: Format) []const u8 {
        return switch (f) {
            .png => "PNG",
            .jpeg => "JPEG",
            .gif => "GIF",
            .webp => "WebP",
            .bmp => "BMP",
            .qoi => "QOI",
            .tiff => "TIFF",
            .heic => "HEIC",
            .heif => "HEIF",
            .avif => "AVIF",
            .jxl => "JPEG XL",
            .ico => "ICO",
            .psd => "PSD",
            .jp2 => "JPEG 2000",
            .exr => "OpenEXR",
            .dds => "DDS",
            .icns => "ICNS",
        };
    }

    /// What nanoui's own decoders read: the fallback when a system decoder is
    /// missing or rejects the file.
    pub fn baseline(f: Format) bool {
        return f == .png or f == .jpeg or f == .gif;
    }
};

const Signature = struct { format: Format, at: u8 = 0, bytes: []const u8 };

/// Fixed signatures; the formats with a weak or variable one are checked in `detect`.
const signatures = [_]Signature{
    .{ .format = .png, .bytes = "\x89PNG\r\n\x1a\n" },
    .{ .format = .jpeg, .bytes = "\xff\xd8\xff" },
    .{ .format = .gif, .bytes = "GIF87a" },
    .{ .format = .gif, .bytes = "GIF89a" },
    .{ .format = .webp, .at = 8, .bytes = "WEBP" },
    .{ .format = .qoi, .bytes = "qoif" },
    .{ .format = .tiff, .bytes = "II*\x00" },
    .{ .format = .tiff, .bytes = "MM\x00*" },
    .{ .format = .tiff, .bytes = "II+\x00" }, // BigTIFF
    .{ .format = .tiff, .bytes = "MM\x00+" },
    .{ .format = .jxl, .bytes = "\xff\x0a" },
    .{ .format = .jxl, .bytes = "\x00\x00\x00\x0cJXL \x0d\x0a\x87\x0a" },
    .{ .format = .psd, .bytes = "8BPS\x00\x01" },
    .{ .format = .psd, .bytes = "8BPS\x00\x02" }, // PSB
    .{ .format = .jp2, .bytes = "\x00\x00\x00\x0cjP  \x0d\x0a\x87\x0a" },
    .{ .format = .jp2, .bytes = "\xff\x4f\xff\x51" }, // bare codestream
    .{ .format = .exr, .bytes = "\x76\x2f\x31\x01" },
    .{ .format = .dds, .bytes = "DDS \x7c\x00\x00\x00" },
    .{ .format = .icns, .bytes = "icns" },
};

/// Null when no signature matches: the caller falls back to the extension.
pub fn detect(head: []const u8) ?Format {
    const bytes = head[0..@min(head.len, head_len_max)];
    for (signatures) |sig| {
        if (bytes.len < sig.at + sig.bytes.len) continue;
        if (!std.mem.eql(u8, bytes[sig.at..][0..sig.bytes.len], sig.bytes)) continue;
        // "WEBP" alone is not enough: RIFF holds other kinds too.
        if (sig.format == .webp and !std.mem.startsWith(u8, bytes, "RIFF")) continue;
        return sig.format;
    }
    if (is_bmp(bytes)) return .bmp;
    if (is_ico(bytes)) return .ico;
    return ftyp(bytes);
}

/// "BM" is common in text, so the DIB header size must be one of the known ones.
fn is_bmp(bytes: []const u8) bool {
    if (bytes.len < 18 or !std.mem.startsWith(u8, bytes, "BM")) return false;
    const header = std.mem.readInt(u32, bytes[14..18], .little);
    for ([_]u32{ 12, 16, 40, 52, 56, 64, 108, 124 }) |known| {
        if (header == known) return true;
    }
    return false;
}

/// Reserved zero, type 1, a nonzero count and a zero reserved byte in the first entry.
fn is_ico(bytes: []const u8) bool {
    if (bytes.len < 22 or !std.mem.startsWith(u8, bytes, "\x00\x00\x01\x00")) return false;
    const count = std.mem.readInt(u16, bytes[4..6], .little);
    return count > 0 and bytes[9] == 0;
}

/// HEIF and AVIF: an ISO base media `ftyp` box whose brands name the format.
fn ftyp(bytes: []const u8) ?Format {
    if (bytes.len < 16 or !std.mem.eql(u8, bytes[4..8], "ftyp")) return null;
    const box_len = std.mem.readInt(u32, bytes[0..4], .big);
    if (box_len < 16) return null;
    const end = @min(box_len, bytes.len);
    var result: ?Format = null;
    // The major brand at 8, then the compatible brands from 16.
    var at: usize = 8;
    while (at + 4 <= end) : (at += if (at == 8) 8 else 4) {
        const brand = bytes[at..][0..4];
        if (brand_in(brand, &.{ "avif", "avis" })) return .avif;
        if (brand_in(brand, &.{ "heic", "heix", "heim", "heis", "hevc", "hevx" })) return .heic;
        if (brand_in(brand, &.{ "mif1", "msf1" })) result = .heif;
    }
    assert(at >= 8);
    return result;
}

fn brand_in(brand: *const [4]u8, names: []const *const [4]u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, brand, name)) return true;
    }
    return false;
}

/// Extensions of formats that are a variant of a container `detect` names: a DNG is a
/// TIFF, an MPO a JPEG. The info line shows the extension for them.
pub fn is_variant(format: Format, extension: []const u8) bool {
    const names: []const []const u8 = switch (format) {
        .jpeg => &.{"mpo"},
        .tiff => &.{
            "dng", "cr2", "nef", "nrw", "arw", "srf", "sr2", "pef", "erf",
            "3fr", "fff", "mos", "iiq", "dcr", "kdc", "mef", "srw",
        },
        else => &.{},
    };
    for (names) |name| {
        if (std.ascii.eqlIgnoreCase(name, extension)) return true;
    }
    return false;
}

const testing = std.testing;

/// An ICO head up to its count, and its first directory entry.
const ico_head = "\x00\x00\x01\x00";
const ico_entry = "\x10\x10\x00\x00\x01\x00\x20\x00\x68\x04\x00\x00\x16\x00\x00\x00";

test "detect names each format by its first bytes" {
    const Case = struct { []const u8, ?Format };
    const cases = [_]Case{
        .{ "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR", .png },
        .{ "\xff\xd8\xff\xe0\x00\x10JFIF", .jpeg },
        .{ "GIF89a\x01\x00", .gif },
        .{ "GIF87a", .gif },
        .{ "RIFF\x24\x00\x00\x00WEBPVP8 ", .webp },
        .{ "RIFF\x24\x00\x00\x00WAVEfmt ", null },
        .{ "BM\x36\x00\x00\x00\x00\x00\x00\x00\x36\x00\x00\x00\x28\x00\x00\x00", .bmp },
        .{ "BMW is not a picture, nor a header", null },
        .{ "qoif\x00\x00\x00\x01", .qoi },
        .{ "II*\x00\x08\x00\x00\x00", .tiff },
        .{ "MM\x00*\x00\x00\x00\x08", .tiff },
        .{ "\x00\x00\x00\x18ftypheic\x00\x00\x00\x00mif1heic", .heic },
        .{ "\x00\x00\x00\x1cftypmif1\x00\x00\x00\x00mif1miafavif", .avif },
        .{ "\x00\x00\x00\x18ftypmif1\x00\x00\x00\x00mif1miaf", .heif },
        .{ "\x00\x00\x00\x18ftypisom\x00\x00\x00\x00isomiso2", null },
        .{ "\x00\x00\x00\x14ftypcrx \x00\x00\x00\x01crx ", null },
        .{ "\xff\x0a\xfa\x7f", .jxl },
        .{ ico_head ++ "\x01\x00" ++ ico_entry, .ico },
        .{ ico_head ++ "\x00\x00" ++ ico_entry, null },
        .{ "8BPS\x00\x01\x00\x00", .psd },
        .{ "\x00\x00\x00\x0cjP  \x0d\x0a\x87\x0a", .jp2 },
        .{ "\xff\x4f\xff\x51\x00\x2f", .jp2 },
        .{ "\x76\x2f\x31\x01\x02\x00\x00\x00", .exr },
        .{ "DDS \x7c\x00\x00\x00", .dds },
        .{ "icns\x00\x00\x10\x00", .icns },
        .{ "", null },
        .{ "\x89PN", null },
        .{ "not a picture", null },
    };
    for (cases) |case| try testing.expectEqual(case[1], detect(case[0]));
}

test "detect names the real test pictures" {
    try testing.expectEqual(@as(?Format, .jpeg), detect(@embedFile("testdata/format.jpeg")));
    try testing.expectEqual(@as(?Format, .jp2), detect(@embedFile("testdata/format.jp2")));
    try testing.expectEqual(@as(?Format, .psd), detect(@embedFile("testdata/format.psd")));
    try testing.expectEqual(@as(?Format, .exr), detect(@embedFile("testdata/format.exr")));
    try testing.expectEqual(@as(?Format, .icns), detect(@embedFile("testdata/format.icns")));
    try testing.expectEqual(@as(?Format, .webp), detect(@embedFile("testdata/webp_lossy.webp")));
    try testing.expectEqual(@as(?Format, null), detect(@embedFile("testdata/format.tga")));
}

test "only nanoui's own formats fall back to its decoders" {
    try testing.expect(Format.png.baseline() and Format.jpeg.baseline() and Format.gif.baseline());
    try testing.expect(!Format.webp.baseline() and !Format.tiff.baseline());
}

test "raw and MPO extensions name variants of their container" {
    try testing.expect(is_variant(.tiff, "DNG"));
    try testing.expect(is_variant(.jpeg, "mpo"));
    try testing.expect(!is_variant(.tiff, "png"));
    try testing.expect(!is_variant(.png, "png"));
}
