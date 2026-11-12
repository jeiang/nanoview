//! File information cached when a picture is loaded, never on a frame.
const std = @import("std");
const builtin = @import("builtin");
const paths = @import("paths.zig");
const sniff = @import("sniff.zig");
const assert = std.debug.assert;

const Time = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    day: c_int,
    month: c_int,
    year: c_int,
    weekday: c_int,
    yearday: c_int,
    dst: c_int,
};
extern "c" fn localtime(time: *const i64) ?*const Time;
extern "c" fn _localtime64(time: *const i64) ?*const Time;

pub const Metadata = struct {
    text: [128]u8 = undefined,
    len: u32 = 0,

    pub fn load(m: *Metadata, io: std.Io, path: []const u8) void {
        m.len = 0;
        const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return;
        const seconds: i64 = @intCast(@divFloor(st.mtime.nanoseconds, std.time.ns_per_s));
        const date = if (builtin.os.tag == .windows)
            _localtime64(&seconds)
        else
            localtime(&seconds);
        const tm = date orelse return;
        var format_buf: [format_len_max]u8 = undefined;
        const format = format_label(io, path, &format_buf);
        const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
        var bytes: f64 = @floatFromInt(st.size);
        var unit: u32 = 0;
        while (bytes >= 1024 and unit + 1 < units.len) : (unit += 1) bytes /= 1024;
        const text = std.fmt.bufPrint(
            &m.text,
            "{s} · {d:.1} {s} · {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}",
            .{
                format,                   bytes,                  units[unit],
                unsigned(tm.year + 1900), unsigned(tm.month + 1), unsigned(tm.day),
                unsigned(tm.hour),        unsigned(tm.min),
            },
        ) catch return;
        m.len = @intCast(text.len);
        std.debug.assert(m.len <= m.text.len);
    }

    pub fn line(m: *const Metadata) []const u8 {
        std.debug.assert(m.len <= m.text.len);
        return m.text[0..m.len];
    }
};

const format_len_max: u32 = 16;

/// The format the content shows, else the extension in capitals. A raw file or an
/// MPO keeps its extension: its content is only the TIFF or JPEG it is built on.
fn format_label(io: std.Io, path: []const u8, buf: *[format_len_max]u8) []const u8 {
    assert(path.len > 0);
    const ext = std.fs.path.extension(path);
    const bare = ext[@min(ext.len, 1)..];
    var head: [sniff.head_len_max]u8 = undefined;
    const bytes = paths.read_head(io, path, &head) catch head[0..0];
    if (sniff.detect(bytes)) |found| {
        if (!sniff.is_variant(found, bare)) return found.label();
    }
    const len = @min(bare.len, buf.len);
    for (buf[0..len], bare[0..len]) |*out, in| out.* = std.ascii.toUpper(in);
    assert(len <= format_len_max);
    return buf[0..len];
}

fn unsigned(value: c_int) u32 {
    return @intCast(@max(0, value));
}
