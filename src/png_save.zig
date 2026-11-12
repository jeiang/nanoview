//! Writes premultiplied BGRA pixels as a straight RGBA PNG, streamed through fixed
//! buffers: the compressor's window, one IDAT chunk and the file writer's buffer.
const std = @import("std");
const flate = std.compress.flate;
const Writer = std.Io.Writer;
const assert = std.debug.assert;

pub const idat_bytes_max: u32 = 64 * 1024;
pub const file_bytes_max: u32 = 64 * 1024;
const chunk_pixels_max: u32 = 1024;
const signature = "\x89PNG\r\n\x1a\n";

pub const Frame = struct { bgra: []const u8, width: u32, height: u32 };

/// One IDAT chunk per full buffer: a PNG chunk's length comes before its data.
const Idat = struct {
    out: *Writer,
    writer: Writer,

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        _ = splat;
        const idat: *Idat = @fieldParentPtr("writer", w);
        if (w.end > 0) try write_chunk(idat.out, "IDAT", w.buffered());
        w.end = 0;
        const first = data[0];
        const n = @min(first.len, w.buffer.len);
        @memcpy(w.buffer[0..n], first[0..n]);
        w.end = n;
        return n;
    }

    fn flush(w: *Writer) Writer.Error!void {
        const idat: *Idat = @fieldParentPtr("writer", w);
        if (w.end > 0) try write_chunk(idat.out, "IDAT", w.buffered());
        w.end = 0;
    }
};

/// About 420 KiB: a field of the one `State`, never on the stack.
pub const Encoder = struct {
    compress: flate.Compress,
    idat: Idat,
    window: [flate.max_window_len]u8,
    idat_buffer: [idat_bytes_max]u8,
    file_buffer: [file_bytes_max]u8,

    /// Writes `frame` to the start of `file`.
    pub fn write(e: *Encoder, io: std.Io, file: std.Io.File, frame: Frame) !void {
        assert(frame.width > 0 and frame.height > 0);
        assert(frame.bgra.len == @as(u64, frame.width) * frame.height * 4);
        var file_writer = file.writer(io, &e.file_buffer);
        e.encode(&file_writer.interface, frame) catch |err| switch (err) {
            error.WriteFailed => return file_writer.err orelse err,
        };
    }

    fn encode(e: *Encoder, out: *Writer, frame: Frame) Writer.Error!void {
        try out.writeAll(signature);
        var header: [13]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], frame.width, .big);
        std.mem.writeInt(u32, header[4..8], frame.height, .big);
        header[8..13].* = .{ 8, 6, 0, 0, 0 }; // 8-bit RGBA, no interlace
        try write_chunk(out, "IHDR", &header);
        e.idat = .{ .out = out, .writer = .{
            .buffer = &e.idat_buffer,
            .vtable = &.{ .drain = Idat.drain, .flush = Idat.flush },
        } };
        e.compress = try .init(&e.idat.writer, &e.window, .zlib, .fastest);
        const row_len = @as(usize, frame.width) * 4;
        for (0..frame.height) |y| {
            try e.compress.writer.writeByte(0); // filter: none
            try write_row(&e.compress.writer, frame.bgra[y * row_len ..][0..row_len]);
        }
        try e.compress.finish();
        try e.idat.writer.flush();
        try write_chunk(out, "IEND", "");
        try out.flush();
    }
};

/// Un-premultiplies one row of BGRA into straight RGBA.
fn write_row(w: *Writer, row: []const u8) Writer.Error!void {
    assert(row.len % 4 == 0);
    var chunk: [chunk_pixels_max * 4]u8 = undefined;
    var at: usize = 0;
    while (at < row.len) {
        const n = @min(row.len - at, chunk.len);
        for (0..n / 4) |i| {
            const p = row[at + i * 4 ..][0..4];
            chunk[i * 4 ..][0..4].* = straight(p.*);
        }
        try w.writeAll(chunk[0..n]);
        at += n;
    }
    assert(at == row.len);
}

fn straight(bgra: [4]u8) [4]u8 {
    const a: u32 = bgra[3];
    if (a == 0) return .{ 0, 0, 0, 0 };
    var rgba: [4]u8 = undefined;
    for (0..3) |i| {
        const c: u32 = bgra[2 - i];
        rgba[i] = @intCast(@min(255, (c * 255 + a / 2) / a));
    }
    rgba[3] = bgra[3];
    return rgba;
}

fn write_chunk(out: *Writer, kind: *const [4]u8, data: []const u8) Writer.Error!void {
    assert(data.len <= std.math.maxInt(u31));
    try out.writeInt(u32, @intCast(data.len), .big);
    try out.writeAll(kind);
    try out.writeAll(data);
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    try out.writeInt(u32, crc.final(), .big);
}

test "straight alpha undoes premultiplication and clears transparent pixels" {
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, straight(.{ 0, 0, 255, 255 }));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 128 }, straight(.{ 128, 0, 0, 128 }));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, straight(.{ 9, 9, 9, 0 }));
}

test "a frame wider than one IDAT chunk inflates back to its rows" {
    const testing = std.testing;
    const e = try testing.allocator.create(Encoder);
    defer testing.allocator.destroy(e);
    const width: u32 = 20000; // 80 KB rows: several chunks and IDATs
    const pixels = try testing.allocator.alloc(u8, width * 2 * 4);
    defer testing.allocator.free(pixels);
    var random: std.Random.DefaultPrng = .init(1);
    random.random().bytes(pixels);
    for (0..pixels.len / 4) |i| pixels[i * 4 + 3] = 255; // opaque: noise stays exact
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(testing.io, "f.png", .{});
    try e.write(testing.io, file, .{ .bgra = pixels, .width = width, .height = 2 });
    file.close(testing.io);
    const png = try tmp.dir.readFileAlloc(testing.io, "f.png", testing.allocator, .unlimited);
    defer testing.allocator.free(png);
    try testing.expectEqualStrings(signature, png[0..8]);
    // The IDAT payloads, in order, are one zlib stream.
    var zlib: std.ArrayList(u8) = .empty;
    defer zlib.deinit(testing.allocator);
    var at: usize = 8;
    var idats: u32 = 0;
    while (at < png.len) {
        const len = std.mem.readInt(u32, png[at..][0..4], .big);
        const kind = png[at + 4 ..][0..4];
        if (std.mem.eql(u8, kind, "IDAT")) {
            try zlib.appendSlice(testing.allocator, png[at + 8 ..][0..len]);
            idats += 1;
        }
        at += 12 + len;
    }
    try testing.expect(idats > 1);
    var reader: std.Io.Reader = .fixed(zlib.items);
    var window: [flate.max_window_len]u8 = undefined;
    var inflate: flate.Decompress = .init(&reader, .zlib, &window);
    const raw = try inflate.reader.allocRemaining(testing.allocator, .unlimited);
    defer testing.allocator.free(raw);
    try testing.expectEqual(@as(usize, 2 * (1 + width * 4)), raw.len);
    try testing.expectEqual(@as(u8, 0), raw[0]);
    try testing.expectEqualSlices(u8, &straight(pixels[4..8].*), raw[5..9]);
    const second = raw[1 + width * 4 ..];
    try testing.expectEqualSlices(u8, &straight(pixels[width * 4 ..][0..4].*), second[1..5]);
}
