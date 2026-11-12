//! WIC decodes a chosen frame (a TIFF page, an ICO size) into caller-owned
//! premultiplied BGRA storage.
//! Standard JPEG/TIFF orientation metadata is applied, including reflections.
//! Codec-specific orientation metadata (for example HEIF item transforms) is
//! not queried; JPEG EXIF also has the existing bounded reader as a fallback.
//! A frame with a color profile is converted to sRGB by IWICColorTransform.
const std = @import("std");
const builtin = @import("builtin");
const decode = @import("decode.zig");
const orientation = @import("orientation.zig");
const assert = std.debug.assert;

// Zig resolves WinAPI per target: stdcall on x86, the Microsoft ABI on x86_64,
// and the Windows AAPCS64 variant on arm64.
const winapi = std.builtin.CallingConvention.winapi;

const Guid = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };
const clsid_factory: Guid = .{ .a = 0xCACAF262, .b = 0x9370, .c = 0x4615, .d = .{
    0xA1, 0x3B, 0x9F, 0x55, 0x39, 0xDA, 0x4C, 0x0A,
} };
const iid_factory: Guid = .{ .a = 0xEC5EC8A9, .b = 0xC395, .c = 0x4314, .d = .{
    0x9C, 0x77, 0x54, 0xD7, 0xA9, 0x35, 0xFF, 0x70,
} };
const iid_codec_info: Guid = .{ .a = 0xE87A44C4, .b = 0xB76E, .c = 0x4C47, .d = .{
    0x8B, 0x09, 0x29, 0x8E, 0xB1, 0x2A, 0x27, 0x14,
} };
const format_pbgra: Guid = .{ .a = 0x6FDDC324, .b = 0x4E03, .c = 0x4BFE, .d = .{
    0xB1, 0x85, 0x3D, 0x77, 0x76, 0x8D, 0xC9, 0x10,
} };
const format_bgra: Guid = .{ .a = 0x6FDDC324, .b = 0x4E03, .c = 0x4BFE, .d = .{
    0xB1, 0x85, 0x3D, 0x77, 0x76, 0x8D, 0xC9, 0x0F,
} };
const contexts_max: u32 = 4; // color contexts asked of a frame
const context_exif: u32 = 2; // WICColorContextExifColorSpace
const exif_srgb: u32 = 1;
const changed_mode: i32 = @bitCast(@as(u32, 0x80010106));
const bytes_per_pixel: u32 = 4;
const flip_horizontal: u32 = 8;
const interpolation_fant: u32 = 3;
const cache_on_load: u32 = 2; // WICBitmapCacheOnLoad
const component_decoder: u32 = 1;
const decoders_max: u32 = 64;
const extension_text_max: u32 = 512;
pub const extension_names_max: u32 = 32;
pub const extension_len_max: u32 = 16;

// Layout and vtable slots follow wincodec.h; all interfaces begin with IUnknown.
const Com = extern struct {
    vtable: [*]const *const anyopaque,

    fn slot(c: *Com, comptime T: type, index: usize) T {
        return @ptrCast(@alignCast(c.vtable[index]));
    }

    fn release(c: *Com) void {
        _ = c.slot(*const fn (*Com) callconv(winapi) u32, 2)(c);
    }
};

// PROPVARIANT's value union includes a counted pointer, hence two pointer
// words on both 32- and 64-bit Windows. Only scalar orientation values are read.
const PropVariant = extern struct {
    vt: u16 = 0,
    reserved: [3]u16 = .{ 0, 0, 0 },
    value: extern union {
        short: u16,
        unsigned: u32,
        storage: [2]usize,
    } = .{ .storage = .{ 0, 0 } },
};

const win = struct {
    extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, flags: u32) callconv(winapi) i32;
    extern "ole32" fn CoUninitialize() callconv(winapi) void;
    extern "ole32" fn CoCreateInstance(
        clsid: *const Guid,
        outer: ?*anyopaque,
        context: u32,
        iid: *const Guid,
        out: *?*Com,
    ) callconv(winapi) i32;
    extern "ole32" fn PropVariantClear(value: *PropVariant) callconv(winapi) i32;
};

/// The COM objects that one decode or page count holds.
const Opened = struct {
    uninitialize: bool,
    factory: *Com,
    stream: *Com,
    decoder: *Com,

    fn close(o: Opened) void {
        o.decoder.release();
        o.stream.release();
        o.factory.release();
        if (o.uninitialize) win.CoUninitialize();
    }

    /// IWICBitmapDecoder::GetFrameCount (slot 12).
    fn frame_count(o: Opened) !u32 {
        var count: u32 = 0;
        const get_count = o.decoder.slot(*const fn (*Com, *u32) callconv(winapi) i32, 12);
        try check(get_count(o.decoder, &count));
        return @max(count, 1);
    }
};

fn open_decoder(encoded: []const u8) !Opened {
    assert(encoded.len > 0 and encoded.len <= decode.file_size_max);
    const uninitialize = try com_initialize();
    errdefer if (uninitialize) win.CoUninitialize();
    var raw: ?*Com = null;
    try check(win.CoCreateInstance(&clsid_factory, null, 1, &iid_factory, &raw));
    const factory = raw orelse return error.WicDecodeFailed;
    errdefer factory.release();
    const stream = try memory_stream(factory, encoded);
    errdefer stream.release();
    raw = null;
    const open = factory.slot(
        *const fn (*Com, *Com, ?*const Guid, u32, *?*Com) callconv(winapi) i32,
        4,
    );
    try check(open(factory, stream, null, 0, &raw));
    const decoder = raw orelse return error.WicDecodeFailed;
    return .{
        .uninitialize = uninitialize,
        .factory = factory,
        .stream = stream,
        .decoder = decoder,
    };
}

/// WIC's frame count; 1 when the file does not open.
pub fn page_count(encoded: []const u8) u32 {
    comptime assert(builtin.os.tag == .windows);
    if (encoded.len == 0 or encoded.len > decode.file_size_max) return 1;
    const opened = open_decoder(encoded) catch return 1;
    defer opened.close();
    return opened.frame_count() catch 1;
}

pub fn decode_fit(
    encoded: []const u8,
    out: []u8,
    bounds_w: u32,
    bounds_h: u32,
    page: u32,
) !decode.Size {
    comptime assert(builtin.os.tag == .windows);
    if (encoded.len == 0 or encoded.len > decode.file_size_max) return error.InvalidImage;
    const opened = try open_decoder(encoded);
    defer opened.close();
    const pages = try opened.frame_count();
    if (page >= pages) return error.NoPage;
    var raw: ?*Com = null;
    const get_frame = opened.decoder.slot(
        *const fn (*Com, u32, *?*Com) callconv(winapi) i32,
        13,
    );
    try check(get_frame(opened.decoder, page, &raw));
    const frame = raw orelse return error.WicDecodeFailed;
    defer frame.release();
    var size = try decode_frame(opened.factory, frame, encoded, out, bounds_w, bounds_h);
    size.page_count = pages;
    return size;
}

fn memory_stream(factory: *Com, encoded: []const u8) !*Com {
    assert(encoded.len > 0 and encoded.len <= decode.file_size_max);
    const stream = try create(factory, 14);
    errdefer stream.release();
    const initialize = stream.slot(
        *const fn (*Com, [*]u8, u32) callconv(winapi) i32,
        16,
    );
    // WIC's API takes BYTE*, but the decoder only reads this memory. The
    // caller keeps it alive until every lazily evaluated WIC source is released.
    try check(initialize(stream, @constCast(encoded.ptr), @intCast(encoded.len)));
    return stream;
}

fn decode_frame(
    factory: *Com,
    frame: *Com,
    encoded: []const u8,
    out: []u8,
    bounds_w: u32,
    bounds_h: u32,
) !decode.Size {
    var width: u32 = 0;
    var height: u32 = 0;
    const get_size = frame.slot(*const fn (*Com, *u32, *u32) callconv(winapi) i32, 3);
    try check(get_size(frame, &width, &height));
    const exif = frame_orientation(frame) orelse orientation.jpeg_exif(encoded);
    const swapped = exif >= 5;
    const size = try decode.fit(
        if (swapped) height else width,
        if (swapped) width else height,
        bounds_w,
        bounds_h,
    );
    const byte_count = @as(u64, size.width) * size.height * bytes_per_pixel;
    if (byte_count > out.len) return error.OutputTooSmall;
    assert(byte_count <= decode.pixels_max * bytes_per_pixel);
    const turns: u32 = switch (exif) {
        3, 4 => 2,
        5, 6 => 1,
        7, 8 => 3,
        else => 0,
    };
    const mirrored = exif == 2 or exif == 4 or exif == 5 or exif == 7;
    const colored = to_srgb(factory, frame);
    defer if (colored) |source| source.release();
    // Scale at the frame's stored orientation first: the flip-rotator reads
    // pixel by pixel, which is quadratic over a scanline codec, so it only
    // runs on a buffered bitmap of the fitted size.
    const scaler = try create(factory, 11);
    defer scaler.release();
    const scale = scaler.slot(
        *const fn (*Com, *Com, u32, u32, u32) callconv(winapi) i32,
        8,
    );
    const stored_w = if (swapped) size.height else size.width;
    const stored_h = if (swapped) size.width else size.height;
    try check(scale(scaler, colored orelse frame, stored_w, stored_h, interpolation_fant));
    if (turns == 0 and !mirrored) {
        try copy_pixels(factory, scaler, out[0..@intCast(byte_count)], size.width);
        return size;
    }
    const buffered = try buffer(factory, scaler);
    defer buffered.release();
    // Rotate clockwise first, then reflect horizontally in upright coordinates.
    const rotated = if (turns != 0) try transform(factory, buffered, turns) else null;
    defer if (rotated) |source| source.release();
    const flipped = if (mirrored)
        try transform(factory, rotated orelse buffered, flip_horizontal)
    else
        null;
    defer if (flipped) |source| source.release();
    const source = flipped orelse rotated orelse buffered;
    try copy_pixels(factory, source, out[0..@intCast(byte_count)], size.width);
    return size;
}

/// IWICImagingFactory::CreateBitmapFromSource (slot 18) with
/// WICBitmapCacheOnLoad: the scaled pixels are decoded once, into WIC memory.
fn buffer(factory: *Com, source: *Com) !*Com {
    var raw: ?*Com = null;
    const create_bitmap = factory.slot(
        *const fn (*Com, *Com, u32, *?*Com) callconv(winapi) i32,
        18,
    );
    try check(create_bitmap(factory, source, cache_on_load, &raw));
    const bitmap = raw orelse return error.WicDecodeFailed;
    assert(@intFromPtr(bitmap) != 0);
    return bitmap;
}

fn copy_pixels(factory: *Com, source: *Com, out: []u8, width: u32) !void {
    assert(width > 0 and out.len > 0);
    assert(out.len <= decode.pixels_max * bytes_per_pixel);
    const converter = try create(factory, 10);
    defer converter.release();
    const initialize = converter.slot(
        *const fn (*Com, *Com, *const Guid, u32, ?*Com, f64, u32) callconv(winapi) i32,
        8,
    );
    // No dithering, no palette, and WICBitmapPaletteTypeCustom (unused for BGRA).
    try check(initialize(converter, source, &format_pbgra, 0, null, 0, 0));
    const copy = converter.slot(
        *const fn (*Com, ?*const anyopaque, u32, u32, [*]u8) callconv(winapi) i32,
        7,
    );
    try check(copy(converter, null, width * bytes_per_pixel, @intCast(out.len), out.ptr));
}

fn transform(factory: *Com, source: *Com, flags: u32) !*Com {
    assert(flags > 0 and flags <= flip_horizontal);
    const rotator = try create(factory, 13);
    errdefer rotator.release();
    const initialize = rotator.slot(
        *const fn (*Com, *Com, u32) callconv(winapi) i32,
        8,
    );
    try check(initialize(rotator, source, flags));
    return rotator;
}

/// The frame converted from its first color context to sRGB, as straight BGRA. Null
/// when it has none, when that context is sRGB, or when WIC cannot convert it: the
/// picture then shows with its numbers taken as sRGB, as before.
fn to_srgb(factory: *Com, frame: *Com) ?*Com {
    const get_contexts = frame.slot(
        *const fn (*Com, u32, ?[*]?*Com, *u32) callconv(winapi) i32,
        9,
    );
    var count: u32 = 0;
    if (get_contexts(frame, 0, null, &count) < 0 or count == 0) return null;
    var contexts: [contexts_max]?*Com = @splat(null);
    defer for (contexts) |context| if (context) |c| c.release();
    const asked = @min(count, contexts_max);
    for (contexts[0..asked]) |*context| context.* = create(factory, 15) catch return null;
    if (get_contexts(frame, asked, &contexts, &count) < 0 or count == 0) return null;
    const source = contexts[0].?;
    if (is_srgb(source)) return null;
    const target = create(factory, 15) catch return null;
    defer target.release();
    const from_exif = target.slot(*const fn (*Com, u32) callconv(winapi) i32, 5);
    if (from_exif(target, exif_srgb) < 0) return null;
    const converter = create(factory, 16) catch return null;
    const initialize = converter.slot(
        *const fn (*Com, *Com, *Com, *Com, *const Guid) callconv(winapi) i32,
        8,
    );
    if (initialize(converter, frame, source, target, &format_bgra) < 0) {
        converter.release();
        return null;
    }
    return converter;
}

/// IWICColorContext::GetType (slot 6) and GetExifColorSpace (slot 8).
fn is_srgb(context: *Com) bool {
    var kind: u32 = 0;
    const get_type = context.slot(*const fn (*Com, *u32) callconv(winapi) i32, 6);
    if (get_type(context, &kind) < 0) return true;
    if (kind != context_exif) return kind == 0; // 0: uninitialized, 1: a profile
    var space: u32 = 0;
    const get_space = context.slot(*const fn (*Com, *u32) callconv(winapi) i32, 8);
    // Only Adobe RGB (2) is converted; uncalibrated (0xFFFF) stays as it is.
    if (get_space(context, &space) < 0) return true;
    return space != 2;
}

fn frame_orientation(frame: *Com) ?u8 {
    var raw: ?*Com = null;
    const get_reader = frame.slot(*const fn (*Com, *?*Com) callconv(winapi) i32, 8);
    if (get_reader(frame, &raw) < 0) return null;
    const reader = raw orelse return null;
    defer reader.release();
    const names = [_][*:0]const u16{
        std.unicode.utf8ToUtf16LeStringLiteral("/app1/ifd/{ushort=274}"),
        std.unicode.utf8ToUtf16LeStringLiteral("/ifd/{ushort=274}"),
    };
    const query = reader.slot(
        *const fn (*Com, [*:0]const u16, *PropVariant) callconv(winapi) i32,
        5,
    );
    for (names) |name| {
        var value: PropVariant = .{};
        defer _ = win.PropVariantClear(&value);
        if (query(reader, name, &value) < 0) continue;
        const exif: u32 = switch (value.vt) {
            2, 18 => value.value.short, // VT_I2, VT_UI2.
            3, 19 => value.value.unsigned, // VT_I4, VT_UI4.
            else => continue,
        };
        if (exif >= 1 and exif <= 8) return @intCast(exif);
    }
    return null;
}

fn create(factory: *Com, comptime index: usize) !*Com {
    var raw: ?*Com = null;
    const make = factory.slot(*const fn (*Com, *?*Com) callconv(winapi) i32, index);
    try check(make(factory, &raw));
    return raw orelse error.WicDecodeFailed;
}

fn check(result: i32) !void {
    if (result < 0) return error.WicDecodeFailed;
}

/// A UI thread may already be STA. Its existing apartment is usable, but
/// RPC_E_CHANGED_MODE must not be balanced with CoUninitialize.
fn com_initialize() !bool {
    const initialized = win.CoInitializeEx(null, 0);
    if (initialized < 0 and initialized != changed_mode) return error.ComInitializationFailed;
    assert(initialized >= 0 or initialized == changed_mode);
    return initialized >= 0;
}

/// Known raster names that installed WIC decoders claim; zero when COM or
/// WIC enumeration fails, so the caller keeps only its baseline.
pub fn extensions(out: [][]const u8) usize {
    comptime assert(builtin.os.tag == .windows);
    const uninitialize = com_initialize() catch return 0;
    defer if (uninitialize) win.CoUninitialize();
    var raw: ?*Com = null;
    if (win.CoCreateInstance(&clsid_factory, null, 1, &iid_factory, &raw) < 0) return 0;
    const factory = raw orelse return 0;
    defer factory.release();
    raw = null;
    const enumerate = factory.slot(*const fn (*Com, u32, u32, *?*Com) callconv(winapi) i32, 23);
    if (enumerate(factory, component_decoder, 0, &raw) < 0) return 0;
    const components = raw orelse return 0;
    defer components.release();
    var supported: [decode.known_extensions.len]bool = @splat(false);
    const next = components.slot(*const fn (*Com, u32, *?*Com, *u32) callconv(winapi) i32, 3);
    for (0..decoders_max) |_| {
        var fetched: u32 = 0;
        raw = null;
        // S_FALSE (1) ends the enumeration.
        if (next(components, 1, &raw, &fetched) != 0 or fetched != 1) break;
        const component = raw orelse break;
        defer component.release();
        mark_decoder(component, &supported);
    }
    var count: usize = 0;
    for (decode.known_extensions, supported) |known, available| {
        if (!available) continue;
        if (count == out.len) break;
        out[count] = known;
        count += 1;
    }
    assert(count <= out.len);
    assert(count <= decode.known_extensions.len);
    return count;
}

fn mark_decoder(component: *Com, supported: *[decode.known_extensions.len]bool) void {
    var raw: ?*Com = null;
    const query = component.slot(*const fn (*Com, *const Guid, *?*Com) callconv(winapi) i32, 0);
    if (query(component, &iid_codec_info, &raw) < 0) return;
    const info = raw orelse return;
    defer info.release();
    var text: [extension_text_max]u16 = undefined;
    var actual: u32 = 0;
    const get = info.slot(*const fn (*Com, u32, [*]u16, *u32) callconv(winapi) i32, 17);
    // A list longer than the buffer fails; that decoder adds nothing.
    if (get(info, extension_text_max, &text, &actual) < 0) return;
    var storage: [extension_names_max][extension_len_max]u8 = undefined;
    var names: [extension_names_max][]const u8 = undefined;
    const n = parse_extensions(text[0..@min(actual, extension_text_max)], &storage, &names);
    var matched: [decode.known_extensions.len][]const u8 = undefined;
    const count = decode.intersect(names[0..n], &matched);
    assert(count <= n);
    for (decode.known_extensions, supported) |known, *available| {
        for (matched[0..count]) |match| {
            if (std.mem.eql(u8, known, match)) available.* = true;
        }
    }
}

/// Splits a WIC list such as ".jpg,.JPEG,.jfif" into lower-case names without
/// dots. Empty, non-alphanumeric, non-ASCII and over-long names are skipped.
pub fn parse_extensions(
    text: []const u16,
    storage: *[extension_names_max][extension_len_max]u8,
    names: *[extension_names_max][]const u8,
) usize {
    assert(text.len <= extension_text_max);
    var count: usize = 0;
    var len: usize = 0;
    var valid = true;
    for (0..text.len + 1) |i| {
        if (count == extension_names_max) break;
        const last = i == text.len or text[i] == 0;
        if (!last and text[i] != ',') {
            const unit = text[i];
            if (unit == '.' and len == 0) continue;
            if (unit >= 0x80 or !std.ascii.isAlphanumeric(@intCast(unit)) or
                len == extension_len_max)
            {
                valid = false;
                continue;
            }
            storage[count][len] = std.ascii.toLower(@intCast(unit));
            len += 1;
            continue;
        }
        if (valid and len > 0) {
            names[count] = storage[count][0..len];
            count += 1;
        }
        len = 0;
        valid = true;
        if (last) break;
    }
    assert(count <= extension_names_max);
    return count;
}

test "parse_extensions lowercases WIC lists and skips invalid names" {
    const t = std.testing;
    var storage: [extension_names_max][extension_len_max]u8 = undefined;
    var names: [extension_names_max][]const u8 = undefined;
    const list = ".jpg,.JPEG,,jfif,.t\u{e9}f,.waytoolongextension,.x-y,.png\x00.bmp";
    const text = std.unicode.utf8ToUtf16LeStringLiteral(list);
    const n = parse_extensions(text, &storage, &names);
    try t.expectEqual(@as(usize, 4), n);
    try t.expectEqualStrings("jpg", names[0]);
    try t.expectEqualStrings("jpeg", names[1]);
    try t.expectEqualStrings("jfif", names[2]);
    try t.expectEqualStrings("png", names[3]);
    try t.expectEqual(@as(usize, 0), parse_extensions(&.{}, &storage, &names));
    var many: [extension_names_max * 3 + 3]u16 = undefined;
    for (0..extension_names_max + 1) |i| {
        many[i * 3 ..][0..3].* = .{ '.', 'a', ',' };
    }
    try t.expectEqual(@as(usize, extension_names_max), parse_extensions(&many, &storage, &names));
}
