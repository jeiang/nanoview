//! EXIF fields through a bounded IFD walker, and the text of the details panel. The
//! block comes from JPEG (APP1), TIFF-based files, PNG (`eXIf`) and WebP (`EXIF`); the
//! profile name from JPEG (APP2), TIFF and WebP (`ICCP`). HEIF and AVIF are not read:
//! their Exif item sits behind the `meta` box's item tables. Files are read in small
//! positional reads, so nothing is allocated and a block may lie anywhere in the file.
const std = @import("std");
const sniff = @import("sniff.zig");
const assert = std.debug.assert;

/// Entries read per IFD, and tags read from an ICC profile.
pub const tags_max: u32 = 256;
const segments_max: u32 = 64; // JPEG segments before the scan
const chunks_max: u32 = 1024; // PNG and WebP chunks
const entry_size: u32 = 12;
pub const field_len_max: u32 = 64;
pub const text_len_max: u32 = 1024;
pub const lines_max: u32 = 16;

/// Bytes in memory or a file, and a window on them; reads never go past the window.
pub const Source = struct {
    backing: union(enum) { bytes: []const u8, file: File },
    base: u64 = 0,
    len: u64,

    const File = struct { file: std.Io.File, io: std.Io };

    pub fn of_bytes(bytes: []const u8) Source {
        return .{ .backing = .{ .bytes = bytes }, .len = bytes.len };
    }

    pub fn of_file(file: std.Io.File, io: std.Io, len: u64) Source {
        return .{ .backing = .{ .file = .{ .file = file, .io = io } }, .len = len };
    }

    /// Up to `buf.len` bytes at `offset`: fewer past the end or after a failed read.
    pub fn read(s: Source, offset: u64, buf: []u8) []u8 {
        if (offset >= s.len) return buf[0..0];
        const n: usize = @intCast(@min(buf.len, s.len - offset));
        const got: usize = switch (s.backing) {
            .bytes => |b| copy: {
                @memcpy(buf[0..n], b[@intCast(s.base + offset)..][0..n]);
                break :copy n;
            },
            .file => |f| f.file.readPositionalAll(f.io, buf[0..n], s.base + offset) catch 0,
        };
        assert(got <= n);
        return buf[0..got];
    }

    /// The part at `offset`, `len` long, cut to the window.
    pub fn sub(s: Source, offset: u64, len: u64) Source {
        const start = @min(offset, s.len);
        const result: Source = .{
            .backing = s.backing,
            .base = s.base + start,
            .len = @min(len, s.len - start),
        };
        assert(result.base + result.len <= s.base + s.len);
        return result;
    }
};

pub const Blocks = struct { exif: ?Source = null, icc: ?Source = null };

/// Where the EXIF block and the ICC profile are, by the file's content.
pub fn locate(src: Source) Blocks {
    var head: [sniff.head_len_max]u8 = undefined;
    const format = sniff.detect(src.read(0, &head)) orelse return .{};
    return switch (format) {
        .jpeg => jpeg_blocks(src),
        .tiff => .{ .exif = src }, // its profile is a tag, found by `walk`
        .png => png_blocks(src),
        .webp => webp_blocks(src),
        else => .{},
    };
}

fn jpeg_blocks(src: Source) Blocks {
    var result: Blocks = .{};
    var at: u64 = 2;
    var segment: u32 = 0;
    while (segment < segments_max) : (segment += 1) {
        var buf: [4 + 14]u8 = undefined;
        const head = src.read(at, &buf);
        if (head.len < 4 or head[0] != 0xFF) break;
        const marker = head[1];
        if (marker == 0xDA or marker == 0xD9) break;
        const len = std.mem.readInt(u16, head[2..4], .big);
        if (len < 2 or at + 2 + len > src.len) break;
        const payload = src.sub(at + 4, len - 2);
        const id = head[4..];
        if (marker == 0xE1 and std.mem.startsWith(u8, id, "Exif\x00\x00")) {
            if (result.exif == null) result.exif = payload.sub(6, len);
        }
        // Only the first part of a profile split over several segments.
        if (marker == 0xE2 and std.mem.startsWith(u8, id, "ICC_PROFILE\x00\x01")) {
            if (result.icc == null) result.icc = payload.sub(14, len);
        }
        at += 2 + @as(u64, len);
    }
    assert(segment <= segments_max);
    return result;
}

fn png_blocks(src: Source) Blocks {
    var at: u64 = 8;
    var chunk: u32 = 0;
    while (chunk < chunks_max) : (chunk += 1) {
        var buf: [8]u8 = undefined;
        const head = src.read(at, &buf);
        if (head.len < 8) break;
        const len = std.mem.readInt(u32, head[0..4], .big);
        if (std.mem.eql(u8, head[4..8], "eXIf")) return .{ .exif = src.sub(at + 8, len) };
        if (std.mem.eql(u8, head[4..8], "IEND")) break;
        at += 12 + @as(u64, len);
    }
    // iCCP is compressed: its name is not read.
    return .{};
}

fn webp_blocks(src: Source) Blocks {
    var result: Blocks = .{};
    var at: u64 = 12;
    var chunk: u32 = 0;
    while (chunk < chunks_max) : (chunk += 1) {
        var buf: [8 + 6]u8 = undefined;
        const head = src.read(at, &buf);
        if (head.len < 8) break;
        const len = std.mem.readInt(u32, head[4..8], .little);
        const data = src.sub(at + 8, len);
        if (std.mem.eql(u8, head[0..4], "EXIF")) {
            // Some writers keep JPEG's "Exif\0\0" in front of the TIFF header.
            const jpeg_style = std.mem.startsWith(u8, head[8..], "Exif\x00\x00");
            result.exif = if (jpeg_style) data.sub(6, len) else data;
        }
        if (std.mem.eql(u8, head[0..4], "ICCP")) result.icc = data;
        at += 8 + @as(u64, len) + (len & 1);
    }
    return result;
}

/// A RATIONAL whose denominator is not zero.
pub const Rational = struct {
    num: u32,
    den: u32,

    pub fn value(r: Rational) f64 {
        assert(r.den != 0);
        return @as(f64, @floatFromInt(r.num)) / @as(f64, @floatFromInt(r.den));
    }
};

/// Printable ASCII; anything else shows as '?'.
pub const Text = struct {
    buf: [field_len_max]u8 = undefined,
    len: u8 = 0,

    pub fn get(t: *const Text) []const u8 {
        assert(t.len <= field_len_max);
        return t.buf[0..t.len];
    }

    fn set(t: *Text, raw: []const u8) void {
        const end = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
        const trimmed = std.mem.trim(u8, raw[0..end], " ");
        const len = @min(trimmed.len, field_len_max);
        for (t.buf[0..len], trimmed[0..len]) |*out, in| {
            out.* = if (in >= 0x20 and in < 0x7F) in else '?';
        }
        t.len = @intCast(len);
    }
};

pub const Fields = struct {
    found: bool = false, // a TIFF header and its first IFD were read
    make: Text = .{},
    model: Text = .{},
    lens: Text = .{},
    date: Text = .{},
    software: Text = .{},
    profile: Text = .{},
    exposure: ?Rational = null,
    f_number: ?Rational = null,
    focal: ?Rational = null,
    iso: ?u32 = null,
    flash: ?u32 = null,
    width: ?u32 = null,
    height: ?u32 = null,
    orientation: ?u32 = null,
    color_space: ?u32 = null,
    latitude: ?f64 = null,
    longitude: ?f64 = null,
};

const Entry = struct { tag: u16, kind: u16, count: u32, raw: [4]u8, offset: u32 };
const Ifd = enum { main, exif, gps };

/// What the main IFD points at, and the GPS parts read before they combine.
const Found = struct {
    exif: ?u32 = null,
    gps: ?u32 = null,
    icc: ?Entry = null,
    latitude_ref: u8 = 0,
    longitude_ref: u8 = 0,
    latitude: ?f64 = null,
    longitude: ?f64 = null,
};

const Tiff = struct {
    src: Source,
    endian: std.builtin.Endian,

    fn entry(t: Tiff, bytes: *const [entry_size]u8) Entry {
        return .{
            .tag = std.mem.readInt(u16, bytes[0..2], t.endian),
            .kind = std.mem.readInt(u16, bytes[2..4], t.endian),
            .count = std.mem.readInt(u32, bytes[4..8], t.endian),
            .raw = bytes[8..12].*,
            .offset = std.mem.readInt(u32, bytes[8..12], t.endian),
        };
    }

    /// The value's bytes, as many as fit `buf`: in the entry when they fit 4 bytes.
    fn data(t: Tiff, e: Entry, buf: []u8) []const u8 {
        const unit: u64 = switch (e.kind) {
            1, 2, 6, 7 => 1,
            3, 8 => 2,
            4, 9, 11 => 4,
            5, 10, 12 => 8,
            else => 0,
        };
        const size = unit * e.count;
        if (size <= 4) {
            const n: usize = @intCast(@min(size, buf.len));
            @memcpy(buf[0..n], e.raw[0..n]);
            return buf[0..n];
        }
        return t.src.read(e.offset, buf[0..@intCast(@min(size, buf.len))]);
    }

    fn uint(t: Tiff, e: Entry) ?u32 {
        if (e.count == 0) return null;
        var buf: [4]u8 = undefined;
        const bytes = t.data(e, &buf);
        return switch (e.kind) {
            1 => if (bytes.len >= 1) bytes[0] else null,
            3 => if (bytes.len >= 2) std.mem.readInt(u16, bytes[0..2], t.endian) else null,
            4 => if (bytes.len >= 4) std.mem.readInt(u32, bytes[0..4], t.endian) else null,
            else => null,
        };
    }

    /// Null for a zero denominator, a negative SRATIONAL or an offset outside the block.
    fn rational(t: Tiff, e: Entry, index: u32) ?Rational {
        if ((e.kind != 5 and e.kind != 10) or index >= e.count) return null;
        var buf: [8]u8 = undefined;
        const bytes = t.src.read(@as(u64, e.offset) + @as(u64, index) * 8, &buf);
        if (bytes.len < 8) return null;
        const num = std.mem.readInt(u32, bytes[0..4], t.endian);
        const den = std.mem.readInt(u32, bytes[4..8], t.endian);
        if (den == 0) return null;
        if (e.kind == 10 and (@as(i32, @bitCast(num)) < 0 or @as(i32, @bitCast(den)) < 0)) {
            return null;
        }
        return .{ .num = num, .den = den };
    }

    fn ascii(t: Tiff, e: Entry, out: *Text) void {
        if (e.kind != 2 and e.kind != 7) return;
        var buf: [field_len_max]u8 = undefined;
        out.set(t.data(e, &buf));
    }

    /// Degrees, minutes and seconds as decimal degrees.
    fn degrees(t: Tiff, e: Entry) ?f64 {
        const d = t.rational(e, 0) orelse return null;
        const m = t.rational(e, 1) orelse return null;
        const s = t.rational(e, 2) orelse return null;
        return d.value() + m.value() / 60 + s.value() / 3600;
    }

    /// False when the IFD's count cannot be read; a cut table keeps its whole entries.
    fn walk_ifd(t: Tiff, offset: u32, ifd: Ifd, fields: *Fields, found: *Found) bool {
        var count_buf: [2]u8 = undefined;
        const count_bytes = t.src.read(offset, &count_buf);
        if (count_bytes.len < 2) return false;
        const count = @min(std.mem.readInt(u16, count_bytes[0..2], t.endian), tags_max);
        var table_buf: [tags_max * entry_size]u8 = undefined;
        const table = t.src.read(@as(u64, offset) + 2, table_buf[0 .. count * entry_size]);
        const whole = table.len / entry_size;
        assert(whole <= tags_max);
        for (0..whole) |i| {
            const e = t.entry(table[i * entry_size ..][0..entry_size]);
            switch (ifd) {
                .main => t.main_tag(e, fields, found),
                .exif => t.exif_tag(e, fields),
                .gps => t.gps_tag(e, found),
            }
        }
        return true;
    }

    fn main_tag(t: Tiff, e: Entry, fields: *Fields, found: *Found) void {
        switch (e.tag) {
            0x0100 => fields.width = t.uint(e),
            0x0101 => fields.height = t.uint(e),
            0x010F => t.ascii(e, &fields.make),
            0x0110 => t.ascii(e, &fields.model),
            0x0112 => {
                const value = t.uint(e) orelse return;
                if (value >= 1 and value <= 8) fields.orientation = value;
            },
            0x0131 => t.ascii(e, &fields.software),
            // The file's modification date: the date taken replaces it when present.
            0x0132 => if (fields.date.len == 0) t.ascii(e, &fields.date),
            0x8769 => found.exif = t.uint(e),
            0x8825 => found.gps = t.uint(e),
            0x8773 => if (e.kind == 7 or e.kind == 1) {
                found.icc = e;
            },
            else => {},
        }
    }

    fn exif_tag(t: Tiff, e: Entry, fields: *Fields) void {
        switch (e.tag) {
            0x829A => fields.exposure = t.rational(e, 0),
            0x829D => fields.f_number = t.rational(e, 0),
            0x8827 => fields.iso = t.uint(e),
            0x9003 => t.ascii(e, &fields.date),
            0x920A => fields.focal = t.rational(e, 0),
            0x9209 => fields.flash = t.uint(e),
            0xA001 => fields.color_space = t.uint(e),
            0xA002 => fields.width = t.uint(e) orelse fields.width,
            0xA003 => fields.height = t.uint(e) orelse fields.height,
            0xA434 => t.ascii(e, &fields.lens),
            else => {},
        }
    }

    fn gps_tag(t: Tiff, e: Entry, found: *Found) void {
        switch (e.tag) {
            1 => if (e.kind == 2 and e.count >= 1) {
                found.latitude_ref = e.raw[0];
            },
            2 => found.latitude = t.degrees(e),
            3 => if (e.kind == 2 and e.count >= 1) {
                found.longitude_ref = e.raw[0];
            },
            4 => found.longitude = t.degrees(e),
            else => {},
        }
    }
};

/// The main IFD, then the Exif and GPS IFDs it points at, each at most once: a pointer
/// back to an IFD already read is ignored, so a looped offset cannot loop.
pub fn walk(src: Source) Fields {
    var fields: Fields = .{};
    var head_buf: [8]u8 = undefined;
    const head = src.read(0, &head_buf);
    if (head.len < 8) return fields;
    const endian: std.builtin.Endian = if (std.mem.eql(u8, head[0..2], "II"))
        .little
    else if (std.mem.eql(u8, head[0..2], "MM"))
        .big
    else
        return fields;
    const t: Tiff = .{ .src = src, .endian = endian };
    if (std.mem.readInt(u16, head[2..4], endian) != 42) return fields;
    const main = std.mem.readInt(u32, head[4..8], endian);
    var found: Found = .{};
    if (!t.walk_ifd(main, .main, &fields, &found)) return fields;
    fields.found = true;
    if (found.exif) |offset| {
        if (offset != main) _ = t.walk_ifd(offset, .exif, &fields, &found);
    }
    if (found.gps) |offset| {
        if (offset != main and offset != found.exif) _ = t.walk_ifd(offset, .gps, &fields, &found);
    }
    fields.latitude = signed(found.latitude, found.latitude_ref, 'S', 90);
    fields.longitude = signed(found.longitude, found.longitude_ref, 'W', 180);
    if (found.icc) |e| profile_name(src.sub(e.offset, e.count), &fields.profile);
    assert(fields.orientation == null or fields.orientation.? <= 8);
    return fields;
}

fn signed(value: ?f64, ref: u8, negative: u8, limit: f64) ?f64 {
    const v = value orelse return null;
    if (!std.math.isFinite(v) or v > limit) return null;
    return if (ref == negative) -v else v;
}

/// The description of an ICC profile: a v2 `desc` or a v4 `mluc` (its first record).
pub fn profile_name(src: Source, out: *Text) void {
    var head_buf: [132]u8 = undefined;
    const head = src.read(0, &head_buf);
    if (head.len < 132 or !std.mem.eql(u8, head[36..40], "acsp")) return;
    const count = @min(std.mem.readInt(u32, head[128..132], .big), tags_max);
    var table_buf: [tags_max * 12]u8 = undefined;
    const table = src.read(132, table_buf[0 .. count * 12]);
    for (0..table.len / 12) |i| {
        const e = table[i * 12 ..][0..12];
        if (!std.mem.eql(u8, e[0..4], "desc")) continue;
        const offset = std.mem.readInt(u32, e[4..8], .big);
        const size = std.mem.readInt(u32, e[8..12], .big);
        description(src.sub(offset, size), out);
        return;
    }
}

fn description(tag: Source, out: *Text) void {
    var buf: [28 + field_len_max * 2]u8 = undefined;
    const bytes = tag.read(0, &buf);
    if (bytes.len < 12) return;
    if (std.mem.eql(u8, bytes[0..4], "desc")) {
        const len = std.mem.readInt(u32, bytes[8..12], .big);
        out.set(bytes[12..][0..@min(len, bytes.len - 12)]);
        return;
    }
    if (!std.mem.eql(u8, bytes[0..4], "mluc") or bytes.len < 28) return;
    if (std.mem.readInt(u32, bytes[8..12], .big) == 0) return;
    const len = std.mem.readInt(u32, bytes[20..24], .big);
    const offset = std.mem.readInt(u32, bytes[24..28], .big);
    var utf16_buf: [field_len_max * 2]u8 = undefined;
    const utf16 = tag.read(offset, utf16_buf[0..@min(len, utf16_buf.len)]);
    // UTF-16BE: the high byte of an ASCII character is zero.
    var ascii: [field_len_max]u8 = undefined;
    const n = utf16.len / 2;
    for (ascii[0..n], 0..) |*ch, k| {
        ch.* = if (utf16[k * 2] == 0) utf16[k * 2 + 1] else '?';
    }
    out.set(ascii[0..n]);
}

/// The panel's lines, read once per picture while the panel is open.
pub const Details = struct {
    text: [text_len_max]u8 = undefined,
    len: u32 = 0,

    pub fn load(d: *Details, io: std.Io, path: []const u8) void {
        assert(path.len > 0);
        var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
            return d.set_error(err);
        };
        defer file.close(io);
        const len = file.length(io) catch |err| return d.set_error(err);
        const src = Source.of_file(file, io, len);
        const blocks = locate(src);
        var fields: Fields = if (blocks.exif) |block| walk(block) else .{};
        if (blocks.icc) |icc| profile_name(icc, &fields.profile);
        d.show(&fields);
    }

    fn set_error(d: *Details, err: anyerror) void {
        const text = std.fmt.bufPrint(&d.text, "Could not read EXIF: {s}", .{@errorName(err)});
        d.len = if (text) |t| @intCast(t.len) else |_| 0;
        assert(d.len <= text_len_max);
    }

    /// One "Label: value" line per field the file carries.
    pub fn show(d: *Details, f: *const Fields) void {
        var w: std.Io.Writer = .fixed(&d.text);
        if (!f.found) w.writeAll("No EXIF data\n") catch {};
        camera_line(&w, f);
        if (f.lens.len > 0) w.print("Lens: {s}\n", .{f.lens.get()}) catch {};
        if (f.date.len > 0) date_line(&w, f.date.get());
        if (f.exposure) |r| exposure_line(&w, r);
        if (f.f_number) |r| w.print("Aperture: f/{d:.1}\n", .{r.value()}) catch {};
        if (f.iso) |v| w.print("ISO: {d}\n", .{v}) catch {};
        if (f.focal) |r| w.print("Focal length: {d:.1} mm\n", .{r.value()}) catch {};
        if (f.flash) |v| {
            w.print("Flash: {s}\n", .{if (v & 1 == 1) "fired" else "did not fire"}) catch {};
        }
        if (f.width != null and f.height != null) {
            w.print("Pixels: {d} × {d}\n", .{ f.width.?, f.height.? }) catch {};
        }
        if (f.orientation) |v| w.print("Orientation: {s}\n", .{orientation_name(v)}) catch {};
        if (f.latitude != null and f.longitude != null) {
            w.print("GPS: {d:.6}, {d:.6}\n", .{ f.latitude.?, f.longitude.? }) catch {};
        }
        if (f.software.len > 0) w.print("Software: {s}\n", .{f.software.get()}) catch {};
        if (f.color_space) |v| w.print("Color space: {s}\n", .{space_name(v)}) catch {};
        if (f.profile.len > 0) w.print("Profile: {s}\n", .{f.profile.get()}) catch {};
        // A full buffer cuts the last line; the text is ASCII but for "×".
        var end = w.end;
        if (end > 0 and d.text[end - 1] != '\n') {
            end = if (std.mem.lastIndexOfScalar(u8, d.text[0..end], '\n')) |nl| nl + 1 else 0;
        }
        d.len = @intCast(end);
        assert(d.len <= text_len_max);
    }

    /// Line `i`, null past the last.
    pub fn line(d: *const Details, i: u32) ?[]const u8 {
        assert(d.len <= text_len_max);
        var it = std.mem.tokenizeScalar(u8, d.text[0..d.len], '\n');
        var k: u32 = 0;
        while (it.next()) |text| : (k += 1) {
            if (k == i) return text;
            if (k >= lines_max) break;
        }
        return null;
    }
};

fn camera_line(w: *std.Io.Writer, f: *const Fields) void {
    const make = f.make.get();
    const model = f.model.get();
    if (make.len == 0 and model.len == 0) return;
    // Most cameras repeat the make in the model.
    const repeats = make.len > 0 and std.ascii.startsWithIgnoreCase(model, make);
    if (repeats or make.len == 0) {
        w.print("Camera: {s}\n", .{model}) catch {};
    } else if (model.len == 0) {
        w.print("Camera: {s}\n", .{make}) catch {};
    } else {
        w.print("Camera: {s} {s}\n", .{ make, model }) catch {};
    }
}

/// EXIF writes "2024:05:01 12:34:56".
fn date_line(w: *std.Io.Writer, date: []const u8) void {
    var buf: [field_len_max]u8 = undefined;
    @memcpy(buf[0..date.len], date);
    if (date.len >= 10 and date[4] == ':' and date[7] == ':') {
        buf[4] = '-';
        buf[7] = '-';
    }
    w.print("Taken: {s}\n", .{buf[0..date.len]}) catch {};
}

fn exposure_line(w: *std.Io.Writer, r: Rational) void {
    assert(r.den != 0);
    if (r.num == 0) return;
    if (r.num >= r.den) {
        w.print("Exposure: {d:.1} s\n", .{r.value()}) catch {};
    } else {
        w.print("Exposure: 1/{d:.0} s\n", .{1 / r.value()}) catch {};
    }
}

fn orientation_name(value: u32) []const u8 {
    assert(value >= 1 and value <= 8);
    const names = [_][]const u8{
        "normal",          "mirrored",
        "rotated 180°",
        "flipped",         "mirrored, turned",
        "turned 90°",
        "flipped, turned",
        "turned 270°",
    };
    return names[value - 1];
}

fn space_name(value: u32) []const u8 {
    return switch (value) {
        1 => "sRGB",
        2 => "Adobe RGB",
        0xFFFF => "uncalibrated",
        else => "other",
    };
}

const testing = std.testing;

/// A TIFF block in either byte order. IFD0 at 8: make, orientation 6, and pointers to
/// the Exif IFD at 64 (exposure 1/250, f/2.8, ISO 200) and the GPS IFD at 108
/// (latitude 33° 30' S). Values: the make at 140, the rationals from 152.
fn tiff_fixture(comptime endian: std.builtin.Endian) [200]u8 {
    var b: [200]u8 = @splat(0);
    b[0..2].* = if (endian == .little) "II".* else "MM".*;
    std.mem.writeInt(u16, b[2..4], 42, endian);
    std.mem.writeInt(u32, b[4..8], 8, endian);
    std.mem.writeInt(u16, b[8..10], 4, endian);
    put_entry(&b, 10, endian, .{ 0x010F, 2, 6, 140 });
    put_entry(&b, 22, endian, .{ 0x0112, 3, 1, 0 });
    std.mem.writeInt(u16, b[30..32], 6, endian);
    put_entry(&b, 34, endian, .{ 0x8769, 4, 1, 64 });
    put_entry(&b, 46, endian, .{ 0x8825, 4, 1, 108 });
    std.mem.writeInt(u16, b[64..66], 3, endian);
    put_entry(&b, 66, endian, .{ 0x829A, 5, 1, 152 });
    put_entry(&b, 78, endian, .{ 0x829D, 5, 1, 160 });
    put_entry(&b, 90, endian, .{ 0x8827, 3, 1, 0 });
    std.mem.writeInt(u16, b[98..100], 200, endian);
    std.mem.writeInt(u16, b[108..110], 2, endian);
    put_entry(&b, 110, endian, .{ 1, 2, 2, 0 });
    b[118] = 'S';
    put_entry(&b, 122, endian, .{ 2, 5, 3, 168 });
    @memcpy(b[140..146], "Canon\x00");
    const rationals = [_][2]u32{ .{ 1, 250 }, .{ 28, 10 }, .{ 33, 1 }, .{ 30, 1 }, .{ 0, 1 } };
    for (rationals, 0..) |r, i| {
        std.mem.writeInt(u32, b[152 + i * 8 ..][0..4], r[0], endian);
        std.mem.writeInt(u32, b[156 + i * 8 ..][0..4], r[1], endian);
    }
    return b;
}

/// Tag, type, count and offset; inline values are written by the caller.
fn put_entry(b: *[200]u8, at: usize, endian: std.builtin.Endian, e: [4]u32) void {
    std.mem.writeInt(u16, b[at..][0..2], @intCast(e[0]), endian);
    std.mem.writeInt(u16, b[at + 2 ..][0..2], @intCast(e[1]), endian);
    std.mem.writeInt(u32, b[at + 4 ..][0..4], e[2], endian);
    if (e[3] != 0) std.mem.writeInt(u32, b[at + 8 ..][0..4], e[3], endian);
}

test "walk reads the IFDs in both byte orders" {
    inline for (.{ std.builtin.Endian.little, std.builtin.Endian.big }) |endian| {
        const b = tiff_fixture(endian);
        const f = walk(.of_bytes(&b));
        try testing.expect(f.found);
        try testing.expectEqualStrings("Canon", f.make.get());
        try testing.expectEqual(@as(?u32, 6), f.orientation);
        try testing.expectEqual(Rational{ .num = 1, .den = 250 }, f.exposure.?);
        try testing.expectEqual(@as(f64, 2.8), f.f_number.?.value());
        try testing.expectEqual(@as(?u32, 200), f.iso);
        try testing.expectApproxEqAbs(@as(f64, -33.5), f.latitude.?, 1e-9);
        try testing.expectEqual(@as(?f64, null), f.longitude);
    }
}

test "walk keeps what a cut block holds and rejects offsets outside it" {
    const b = tiff_fixture(.little);
    // IFD0 is whole; the make, the Exif IFD and the GPS IFD lie past the cut.
    const f = walk(.of_bytes(b[0..62]));
    try testing.expect(f.found);
    try testing.expectEqual(@as(?u32, 6), f.orientation);
    try testing.expectEqual(@as(u8, 0), f.make.len);
    try testing.expectEqual(@as(?Rational, null), f.exposure);
    try testing.expectEqual(@as(?f64, null), f.latitude);
    // Half of IFD0: its first entry only.
    const half = walk(.of_bytes(b[0..30]));
    try testing.expect(half.found and half.orientation == null);
    for (0..10) |cut| try testing.expect(!walk(.of_bytes(b[0..cut])).found);
}

test "a looped IFD offset is read once and a zero denominator is absent" {
    var b = tiff_fixture(.big);
    // Both pointers lead back to IFD0.
    std.mem.writeInt(u32, b[42..46], 8, .big);
    std.mem.writeInt(u32, b[54..58], 8, .big);
    const looped = walk(.of_bytes(&b));
    try testing.expect(looped.found);
    try testing.expectEqualStrings("Canon", looped.make.get());
    try testing.expectEqual(@as(?Rational, null), looped.exposure);
    try testing.expectEqual(@as(?f64, null), looped.latitude);
    b = tiff_fixture(.big);
    std.mem.writeInt(u32, b[156..160], 0, .big); // exposure 1/0
    const zero = walk(.of_bytes(&b));
    try testing.expectEqual(@as(?Rational, null), zero.exposure);
    try testing.expect(zero.f_number != null);
}

test "locate finds the block in JPEG, PNG and WebP" {
    const tiff = tiff_fixture(.little);
    const jpeg = "\xff\xd8\xff\xe1\x00\xd0Exif\x00\x00" ++ tiff ++ "\xff\xd9";
    try testing.expectEqual(@as(?u32, 6), walk(locate(.of_bytes(jpeg)).exif.?).orientation);
    const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\xc8eXIf" ++ tiff ++ "\x00\x00\x00\x00";
    try testing.expectEqual(@as(?u32, 6), walk(locate(.of_bytes(png)).exif.?).orientation);
    const webp = "RIFF\x00\x00\x00\x00WEBPEXIF\xce\x00\x00\x00Exif\x00\x00" ++ tiff;
    try testing.expectEqual(@as(?u32, 6), walk(locate(.of_bytes(webp)).exif.?).orientation);
    try testing.expect(locate(.of_bytes("GIF89a")).exif == null);
    // A segment longer than the file is not read.
    try testing.expect(locate(.of_bytes(jpeg[0..100])).exif == null);
}

test "the panel says when a file has no EXIF data" {
    var d: Details = .{};
    d.show(&.{});
    try testing.expectEqualStrings("No EXIF data", d.line(0).?);
    try testing.expectEqual(@as(?[]const u8, null), d.line(1));
}
