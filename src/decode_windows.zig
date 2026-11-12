//! WIC decodes frame zero into caller-owned premultiplied BGRA storage.
//! Standard JPEG/TIFF orientation metadata is applied, including reflections.
//! Codec-specific orientation metadata (for example HEIF item transforms) is
//! not queried; JPEG EXIF also has the existing bounded reader as a fallback.
const std = @import("std");
const builtin = @import("builtin");
const decode = @import("decode.zig");
const orientation = @import("orientation.zig");
const assert = std.debug.assert;

// WinAPI selects stdcall on x86 and the Windows ABI on x86_64. Windows ARM64
// uses its ordinary C ABI, rather than Zig's x86-only WinAPI convention.
const winapi: std.builtin.CallingConvention = if (builtin.cpu.arch == .aarch64)
    .c
else
    .winapi;

const Guid = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };
const clsid_factory: Guid = .{ .a = 0xCACAF262, .b = 0x9370, .c = 0x4615, .d = .{
    0xA1, 0x3B, 0x9F, 0x55, 0x39, 0xDA, 0x4C, 0x0A,
} };
const iid_factory: Guid = .{ .a = 0xEC5EC8A9, .b = 0xC395, .c = 0x4314, .d = .{
    0x9C, 0x77, 0x54, 0xD7, 0xA9, 0x35, 0xFF, 0x70,
} };
const format_pbgra: Guid = .{ .a = 0x6FDDC324, .b = 0x4E03, .c = 0x4BFE, .d = .{
    0xB1, 0x85, 0x3D, 0x77, 0x76, 0x8D, 0xC9, 0x10,
} };
const changed_mode: i32 = @bitCast(@as(u32, 0x80010106));
const bytes_per_pixel: u32 = 4;
const flip_horizontal: u32 = 8;
const interpolation_fant: u32 = 3;

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

pub fn decode_fit(
    encoded: []const u8,
    out: []u8,
    bounds_w: u32,
    bounds_h: u32,
) !decode.Size {
    comptime assert(builtin.os.tag == .windows);
    if (encoded.len == 0 or encoded.len > decode.file_size_max) return error.InvalidImage;
    // A UI thread may already be STA. Its existing apartment is usable, but
    // RPC_E_CHANGED_MODE must not be balanced with CoUninitialize.
    const initialized = win.CoInitializeEx(null, 0);
    if (initialized < 0 and initialized != changed_mode) return error.ComInitializationFailed;
    defer if (initialized >= 0) win.CoUninitialize();
    var raw: ?*Com = null;
    try check(win.CoCreateInstance(&clsid_factory, null, 1, &iid_factory, &raw));
    const factory = raw orelse return error.WicDecodeFailed;
    defer factory.release();
    const stream = try memory_stream(factory, encoded);
    defer stream.release();
    raw = null;
    const open = factory.slot(
        *const fn (*Com, *Com, ?*const Guid, u32, *?*Com) callconv(winapi) i32,
        4,
    );
    try check(open(factory, stream, null, 0, &raw));
    const decoder = raw orelse return error.WicDecodeFailed;
    defer decoder.release();
    raw = null;
    const get_frame = decoder.slot(*const fn (*Com, u32, *?*Com) callconv(winapi) i32, 13);
    try check(get_frame(decoder, 0, &raw));
    const frame = raw orelse return error.WicDecodeFailed;
    defer frame.release();
    return decode_frame(factory, frame, encoded, out, bounds_w, bounds_h);
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
    // Separate rotation and reflection stages make the composition explicit:
    // rotate clockwise first, then reflect horizontally in upright coordinates.
    const rotated = if (turns != 0) try transform(factory, frame, turns) else null;
    defer if (rotated) |source| source.release();
    const flipped = if (mirrored)
        try transform(factory, rotated orelse frame, flip_horizontal)
    else
        null;
    defer if (flipped) |source| source.release();
    const source = flipped orelse rotated orelse frame;
    const scaler = try create(factory, 11);
    defer scaler.release();
    const scale = scaler.slot(
        *const fn (*Com, *Com, u32, u32, u32) callconv(winapi) i32,
        8,
    );
    try check(scale(scaler, source, size.width, size.height, interpolation_fant));
    try copy_pixels(factory, scaler, out[0..@intCast(byte_count)], size.width);
    return size;
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
