//! The picture files of one folder, in a fixed buffer, in display order.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

pub const entries_max: u32 = 16384;
pub const names_bytes_max: u32 = 1024 * 1024;
pub const name_len_max: u32 = 255;
/// Directory entries read per scan, pictures or not.
const scan_entries_max: u32 = entries_max * 4;

/// Lower case, without dots: what nanoui decodes on this system.
pub const extensions: []const []const u8 = if (builtin.os.tag == .macos)
    &.{ "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "avif", "tif", "tiff", "bmp", "ico" }
else
    &.{ "png", "jpg", "jpeg", "gif" };

pub const Entry = struct { offset: u32, len: u16 };

pub const Folder = struct {
    names: [names_bytes_max]u8 = undefined,
    names_len: u32 = 0,
    entries: [entries_max]Entry = undefined,
    count: u32 = 0,

    pub fn reset(f: *Folder) void {
        f.names_len = 0;
        f.count = 0;
        assert(f.count == 0 and f.names_len == 0);
    }

    /// False when a limit stops it; a name that is not a picture is skipped.
    pub fn add(f: *Folder, file_name: []const u8) bool {
        assert(f.count <= entries_max and f.names_len <= names_bytes_max);
        if (!is_image_name(file_name) or file_name.len > name_len_max) return true;
        const len: u32 = @intCast(file_name.len);
        if (f.count == entries_max or names_bytes_max - f.names_len < len) return false;
        @memcpy(f.names[f.names_len..][0..len], file_name);
        f.entries[f.count] = .{ .offset = f.names_len, .len = @intCast(len) };
        f.names_len += len;
        f.count += 1;
        assert(std.mem.eql(u8, f.name(f.count - 1), file_name));
        return true;
    }

    pub fn sort(f: *Folder) void {
        assert(f.count <= entries_max);
        std.mem.sort(Entry, f.entries[0..f.count], f, entry_less);
        assert(f.count < 2 or !entry_less(f, f.entries[1], f.entries[0]));
    }

    fn entry_less(f: *const Folder, a: Entry, b: Entry) bool {
        return natural_less(f.slice(a), f.slice(b));
    }

    fn slice(f: *const Folder, e: Entry) []const u8 {
        assert(e.offset + e.len <= f.names_len);
        return f.names[e.offset..][0..e.len];
    }

    pub fn name(f: *const Folder, index: u32) []const u8 {
        assert(index < f.count);
        const result = f.slice(f.entries[index]);
        assert(result.len > 0);
        return result;
    }

    pub fn find(f: *const Folder, file_name: []const u8) ?u32 {
        assert(f.count <= entries_max);
        var i: u32 = 0;
        while (i < f.count) : (i += 1) {
            if (std.mem.eql(u8, f.name(i), file_name)) return i;
        }
        return null;
    }

    /// Keeps the order; the name bytes stay where they are until the next scan.
    pub fn remove(f: *Folder, index: u32) void {
        assert(index < f.count);
        const count_before = f.count;
        const tail = f.entries[index + 1 .. f.count];
        std.mem.copyForwards(Entry, f.entries[index .. f.count - 1], tail);
        f.count -= 1;
        assert(f.count == count_before - 1);
    }

    /// A folder over the limits lists what fits.
    pub fn scan(f: *Folder, io: std.Io, dir_path: []const u8) !void {
        assert(dir_path.len > 0);
        f.reset();
        var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        var seen: u32 = 0;
        while (seen < scan_entries_max) : (seen += 1) {
            const entry = try it.next(io) orelse break;
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            if (!f.add(entry.name)) break;
        }
        f.sort();
        assert(f.count <= entries_max);
    }
};

pub fn is_image_name(file_name: []const u8) bool {
    if (file_name.len == 0 or file_name[0] == '.') return false;
    const dot = std.mem.lastIndexOfScalar(u8, file_name, '.') orelse return false;
    const ext = file_name[dot + 1 ..];
    assert(ext.len < file_name.len);
    for (extensions) |known| {
        if (std.ascii.eqlIgnoreCase(ext, known)) return true;
    }
    return false;
}

/// Case-insensitive; a run of digits compares by value. Ties break by
/// byte order, so the order is total.
pub fn natural_less(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    // Each pass consumes at least one byte of each side.
    while (i < a.len and j < b.len) {
        if (std.ascii.isDigit(a[i]) and std.ascii.isDigit(b[j])) {
            const ra = digit_run(a, i);
            const rb = digit_run(b, j);
            const order = compare_numbers(a[ra.start..ra.end], b[rb.start..rb.end]);
            if (order != .eq) return order == .lt;
            assert(ra.end > i and rb.end > j);
            i = ra.end;
            j = rb.end;
            continue;
        }
        const ca = std.ascii.toLower(a[i]);
        const cb = std.ascii.toLower(b[j]);
        if (ca != cb) return ca < cb;
        i += 1;
        j += 1;
    }
    if (a.len - i != b.len - j) return a.len - i < b.len - j;
    return std.mem.order(u8, a, b) == .lt;
}

const Run = struct { start: usize, end: usize };

/// The digits from `from`, with leading zeros left out of `start`.
fn digit_run(s: []const u8, from: usize) Run {
    assert(from < s.len and std.ascii.isDigit(s[from]));
    var end = from;
    while (end < s.len and std.ascii.isDigit(s[end])) end += 1;
    var start = from;
    while (start + 1 < end and s[start] == '0') start += 1;
    assert(start < end);
    return .{ .start = start, .end = end };
}

fn compare_numbers(a: []const u8, b: []const u8) std.math.Order {
    assert(a.len > 0 and b.len > 0);
    if (a.len != b.len) return std.math.order(a.len, b.len);
    return std.mem.order(u8, a, b);
}

const testing = std.testing;

test "natural_less orders numbers by value" {
    try testing.expect(natural_less("a1", "a2"));
    try testing.expect(natural_less("a2", "a10"));
    try testing.expect(!natural_less("a10", "a2"));
    try testing.expect(natural_less("A2", "a10"));
    try testing.expect(natural_less("img9.png", "img10.png"));
    try testing.expect(natural_less("A", "a") != natural_less("a", "A"));
    try testing.expect(!natural_less("a", "a"));
}

test "is_image_name" {
    try testing.expect(is_image_name("x.PNG"));
    try testing.expect(!is_image_name(".hidden.png"));
    try testing.expect(!is_image_name("notes.txt"));
    try testing.expect(!is_image_name("png"));
}

test "sort, find and remove keep natural order" {
    const f = try testing.allocator.create(Folder);
    defer testing.allocator.destroy(f);
    f.* = .{};
    for ([_][]const u8{ "a10.png", "notes.txt", "a2.png", "a1.png" }) |n| {
        try testing.expect(f.add(n));
    }
    f.sort();
    try testing.expectEqual(@as(u32, 3), f.count);
    try testing.expectEqualStrings("a1.png", f.name(0));
    try testing.expectEqualStrings("a10.png", f.name(2));
    try testing.expectEqual(@as(?u32, 1), f.find("a2.png"));
    f.remove(0);
    try testing.expectEqualStrings("a2.png", f.name(0));
    try testing.expectEqualStrings("a10.png", f.name(1));
    try testing.expectEqual(@as(?u32, null), f.find("a1.png"));
}
