//! `zig build icon`: nanoview's icon, a framed landscape: a river through a
//! valley under a sun, in flat colors, on Apple's macOS icon grid (an
//! 824-pixel tile in 1024) with a soft shadow under the tile. The tile is the
//! frame; the picture sits in a rounded window inside it.
//!
//! Every shape is a signed distance, so its edge is anti-aliased. This draws
//! macos/icon.png, then the Mac's own sips and iconutil make
//! macos/AppIcon.icns from it, and sips the frames of windows/nanoview.ico.
//! Run from the repository's root (build.zig does).
const std = @import("std");
const assert = std.debug.assert;
const flate = std.compress.flate;
const Io = std.Io;

const size = 1024;
const channels = 4;
const Rgb = [3]f64;
const frame_color: Rgb = .{ 0xF0, 0xEB, 0xE0 };
const sky_color: Rgb = .{ 0xBF, 0xE3, 0xF5 };
const sun_color: Rgb = .{ 0xF2, 0xB7, 0x05 };
const hill_left_color: Rgb = .{ 0x3F, 0x8F, 0x4F };
const hill_right_color: Rgb = .{ 0x7D, 0xB8, 0x5A };
const river_color: Rgb = .{ 0x2F, 0x7F, 0xD0 };
const shadow_color: Rgb = .{ 0, 0, 0 };

const tile: Box = .{ .half = 412.0, .radius = 185.0 };
/// The picture's window in the frame.
const window: Box = .{ .half = 328.0, .radius = 104.0 };
const center = 512.0;
const sun: Circle = .{ .x = 676.0, .y = 336.0, .radius = 66.0 };
const hill_left: Circle = .{ .x = 300.0, .y = 900.0, .radius = 430.0 };
const hill_right: Circle = .{ .x = 760.0, .y = 960.0, .radius = 440.0 };
// The river: from the notch where the hills meet down to the window's edge,
// an S that widens toward the viewer.
const river_x = 568.0;
const river_top = 564.0;
const river_bottom = center + window.half;
const river_drift = -70.0;
const river_swing = 56.0;
const river_half_width_top = 5.0;
const river_half_width_grow = 95.0;
const shadow_y = 10.0;
const shadow_sigma = 14.0;
const shadow_alpha = 0.30;

comptime {
    // The tile and the reach of its shadow fit the canvas.
    assert(center + tile.half + shadow_y + 4 * shadow_sigma < size);
    assert(center - tile.half > 0);
    assert(window.half < tile.half);
    assert(river_top < river_bottom);
}

extern "c" fn erfc(x: f64) f64;

const icon_path = "macos/icon.png";
const icns_path = "macos/AppIcon.icns";
const ico_path = "windows/nanoview.ico";
const scratch = "/tmp/nanoview-icon";
const iconset = scratch ++ "/AppIcon.iconset";
/// The iconset's sizes, each also at twice the size (`@2x`).
const iconset_sides = [_]u32{ 16, 32, 128, 256, 512 };
/// Windows has no margin around an icon: the tile and the near part of its
/// shadow, cut from the middle of the canvas.
const ico_crop_side = 880;
const ico_crop_path = scratch ++ "/windows.png";
const ico_sides = [_]u32{ 16, 32, 48, 256 };
const ico_header_bytes = 6;
const ico_entry_bytes = 16;
const ico_frame_bytes_max = 1 << 20;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const pixels = try arena.alloc(u8, size * size * channels);
    draw(pixels);
    var out: Io.Writer.Allocating = .init(arena);
    try writePng(arena, &out.writer, pixels);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = icon_path, .data = out.written() });

    try Io.Dir.cwd().createDirPath(io, iconset);
    for (iconset_sides) |side| {
        const one = try std.fmt.allocPrint(arena, "{s}/icon_{d}x{d}.png", .{
            iconset, side, side,
        });
        try resize(io, arena, .{ .from = icon_path, .side = side, .to = one });
        const two = try std.fmt.allocPrint(arena, "{s}/icon_{d}x{d}@2x.png", .{
            iconset, side, side,
        });
        try resize(io, arena, .{ .from = icon_path, .side = side * 2, .to = two });
    }
    try run(io, arena, &.{ "iconutil", "-c", "icns", "-o", icns_path, iconset });
    try writeIco(io, arena);
}

/// windows/nanoview.ico: one PNG frame for each of `ico_sides`.
fn writeIco(io: Io, arena: std.mem.Allocator) !void {
    const crop = std.fmt.comptimePrint("{d}", .{ico_crop_side});
    try run(io, arena, &.{ "sips", "-c", crop, crop, icon_path, "--out", ico_crop_path });
    var directory: Io.Writer.Allocating = .init(arena);
    var frames: Io.Writer.Allocating = .init(arena);
    try directory.writer.writeAll(&.{ 0, 0, 1, 0, ico_sides.len, 0 });
    for (ico_sides) |side| {
        const path = try std.fmt.allocPrint(arena, "{s}/ico_{d}.png", .{ scratch, side });
        try resize(io, arena, .{ .from = ico_crop_path, .side = side, .to = path });
        const limit: Io.Limit = .limited(ico_frame_bytes_max);
        const frame = try Io.Dir.cwd().readFileAlloc(io, path, arena, limit);
        const offset = ico_header_bytes + ico_entry_bytes * ico_sides.len + frames.written().len;
        // A side of 256 is written as 0; then no palette, one plane, 32 bits.
        const side_byte: u8 = @truncate(side);
        try directory.writer.writeAll(&.{ side_byte, side_byte, 0, 0, 1, 0, 32, 0 });
        try directory.writer.writeInt(u32, @intCast(frame.len), .little);
        try directory.writer.writeInt(u32, @intCast(offset), .little);
        try frames.writer.writeAll(frame);
    }
    assert(directory.written().len == ico_header_bytes + ico_entry_bytes * ico_sides.len);
    const bytes = try std.mem.concat(arena, u8, &.{ directory.written(), frames.written() });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = ico_path, .data = bytes });
}

const Resize = struct { from: []const u8, side: u32, to: []const u8 };

/// `from` made `side` pixels square by sips.
fn resize(io: Io, arena: std.mem.Allocator, options: Resize) !void {
    assert(options.side > 0 and options.side <= size);
    const side = try std.fmt.allocPrint(arena, "{d}", .{options.side});
    try run(io, arena, &.{ "sips", "-z", side, side, options.from, "--out", options.to });
}

/// Runs `argv`; unless it exits 0, prints what it said and fails.
fn run(io: Io, arena: std.mem.Allocator, argv: []const []const u8) !void {
    assert(argv.len > 0);
    const result = try std.process.run(arena, io, .{ .argv = argv });
    if (result.term.success()) return;
    std.debug.print("{s}: {s}{s}\n", .{ argv[0], result.stdout, result.stderr });
    return error.CommandFailed;
}

/// Writes `pixels` (rows of straight-alpha RGBA, top first) as one PNG, each
/// row unfiltered.
fn writePng(gpa: std.mem.Allocator, writer: *Io.Writer, pixels: []const u8) !void {
    const row_bytes = size * channels;
    assert(pixels.len == row_bytes * size);
    // The compressor asserts that its output already has room.
    var data: Io.Writer.Allocating = try .initCapacity(gpa, pixels.len / 2);
    defer data.deinit();
    const compressor = try gpa.create(flate.Compress);
    defer gpa.destroy(compressor);
    const history = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(history);
    compressor.* = try .init(&data.writer, history, .zlib, .best);
    for (0..size) |row| {
        try compressor.writer.writeByte(0); // filter: none
        try compressor.writer.writeAll(pixels[row * row_bytes ..][0..row_bytes]);
    }
    try compressor.finish();

    var header: [13]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], size, .big);
    std.mem.writeInt(u32, header[4..8], size, .big);
    header[8..].* = .{ 8, 6, 0, 0, 0 }; // 8 bits a channel, RGBA
    try writer.writeAll("\x89PNG\r\n\x1a\n");
    try writeChunk(writer, "IHDR", &header);
    try writeChunk(writer, "IDAT", data.written());
    try writeChunk(writer, "IEND", "");
}

fn writeChunk(writer: *Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    try writer.writeInt(u32, @intCast(data.len), .big);
    try writer.writeAll(kind);
    try writer.writeAll(data);
    try writer.writeInt(u32, crc.final(), .big);
}

/// The whole icon, row by row, each pixel sampled at its centre.
fn draw(pixels: []u8) void {
    assert(pixels.len == size * size * channels);
    for (0..size) |row| {
        for (0..size) |column| {
            const x = @as(f64, @floatFromInt(column)) + 0.5;
            const y = @as(f64, @floatFromInt(row)) + 0.5;
            const at = (row * size + column) * channels;
            pixels[at..][0..4].* = straight(pixel(x, y));
        }
    }
}

/// Premultiplied red, green, blue and alpha.
const Premultiplied = [4]f64;

/// Straight alpha, as PNG keeps it.
fn straight(px: Premultiplied) [4]u8 {
    const alpha = px[3];
    if (!(alpha > 0.0)) return .{ 0, 0, 0, 0 };
    return .{
        byteOf(px[0] / alpha),
        byteOf(px[1] / alpha),
        byteOf(px[2] / alpha),
        byteOf(alpha * 255),
    };
}

fn byteOf(value: f64) u8 {
    assert(value >= 0 and value < 255.5);
    return @intFromFloat(@round(value));
}

fn pixel(x: f64, y: f64) Premultiplied {
    var px: Premultiplied = .{ 0, 0, 0, 0 };
    const shadow_distance = tile.distance(x, y - shadow_y);
    if (shadow_distance < 4 * shadow_sigma) {
        const spread = shadow_distance / (shadow_sigma * @sqrt(2.0));
        px = over(px, shadow_color, shadow_alpha * 0.5 * erfc(spread));
    }
    px = over(px, frame_color, cover(tile.distance(x, y)));
    // Everything in the picture is clipped to the window.
    const clip = cover(window.distance(x, y));
    if (clip <= 0.0) return px;
    px = over(px, sky_color, clip);
    px = over(px, sun_color, clip * cover(sun.distance(x, y)));
    px = over(px, hill_right_color, clip * cover(hill_right.distance(x, y)));
    // The hills meet along the river: it hides the seam, so the seam is hard.
    const left_of_river = y < river_top or x < riverMiddle(y);
    if (left_of_river) px = over(px, hill_left_color, clip * cover(hill_left.distance(x, y)));
    px = over(px, river_color, clip * cover(riverDistance(x, y)));
    return px;
}

/// A rounded square about the canvas's centre.
const Box = struct {
    half: f64,
    radius: f64,

    fn distance(box: Box, x: f64, y: f64) f64 {
        const qx = @abs(x - center) - (box.half - box.radius);
        const qy = @abs(y - center) - (box.half - box.radius);
        const outside = std.math.hypot(@max(qx, 0.0), @max(qy, 0.0));
        return outside + @min(@max(qx, qy), 0.0) - box.radius;
    }
};

const Circle = struct {
    x: f64,
    y: f64,
    radius: f64,

    fn distance(circle: Circle, x: f64, y: f64) f64 {
        return std.math.hypot(x - circle.x, y - circle.y) - circle.radius;
    }
};

fn riverMiddle(y: f64) f64 {
    const t = (y - river_top) / (river_bottom - river_top);
    return river_x + river_drift * t + river_swing * @sin(2.0 * std.math.pi * t);
}

/// The river's nearer bank at height `y`: how far `x` is past it, sideways.
fn riverReach(x: f64, y: f64) f64 {
    const t = (y - river_top) / (river_bottom - river_top);
    return @abs(x - riverMiddle(y)) - (river_half_width_top + river_half_width_grow * t * t);
}

/// The distance to the river, near enough at its banks for their edge: the
/// sideways reach, scaled by the bank's slope there.
fn riverDistance(x: f64, y: f64) f64 {
    if (y < river_top) return river_top - y;
    const reach = riverReach(x, y);
    const slope = riverReach(x, y + 0.5) - riverReach(x, y - 0.5);
    return reach / @sqrt(1.0 + slope * slope);
}

/// A shape's share of a pixel, from the distance at its centre.
fn cover(distance: f64) f64 {
    return @min(1.0, @max(0.0, 0.5 - distance));
}

/// Paints `rgb` at alpha `alpha` over the premultiplied `px`.
fn over(px: Premultiplied, rgb: Rgb, alpha: f64) Premultiplied {
    if (alpha <= 0.0) return px;
    const keep = 1.0 - alpha;
    return .{
        rgb[0] * alpha + px[0] * keep,
        rgb[1] * alpha + px[1] * keep,
        rgb[2] * alpha + px[2] * keep,
        alpha + px[3] * keep,
    };
}
