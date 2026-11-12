//! The picture files of one folder, in a fixed buffer, in display order.
const std = @import("std");
const builtin = @import("builtin");
const paths = @import("paths.zig");
const sort_order = @import("sort_order.zig");
const assert = std.debug.assert;

pub const entries_max: u32 = 16384;
pub const names_bytes_max: u32 = 1024 * 1024;
pub const name_len_max: u32 = 255;
/// Directory entries read per scan, pictures or not.
const scan_entries_max: u32 = entries_max * 4;

/// Lower case, without dots. Initialized before folder scans or the worker start.
pub var extensions: []const []const u8 = if (builtin.os.tag == .macos)
    &.{
        "png", "jpg",  "jpeg", "jpe", "jfif", "gif", "heic", "heif", "webp", "avif",
        "tif", "tiff", "bmp",  "ico", "jp2",  "psd", "icns", "tga",  "exr",  "sgi",
        "pbm",
    }
else if (builtin.os.tag == .windows)
    &.{
        "png",  "jpg",  "jpeg", "gif", "bmp", "ico", "tif", "tiff", "webp",
        "heic", "heif", "avif", "jxl", "dds", "jxr", "wdp",
    }
else
    baseline_extensions;

const baseline_extensions: []const []const u8 = &.{ "png", "jpg", "jpeg", "gif" };
const extensions_max: u32 = 64;
var extension_table: [extensions_max][]const u8 = undefined;
var extensions_initialized = false;

pub fn init_extensions() void {
    if (builtin.os.tag != .linux or extensions_initialized) return;
    @memcpy(extension_table[0..baseline_extensions.len], baseline_extensions);
    const count = @import("decode_linux.zig").extensions(
        extension_table[baseline_extensions.len..],
    );
    extensions = extension_table[0 .. baseline_extensions.len + count];
    extensions_initialized = true;
    assert(extensions.len >= baseline_extensions.len);
    assert(extensions.len <= extensions_max);
}

pub const Entry = struct { offset: u32, len: u16, value: i64 = 0 };

pub const Folder = struct {
    names: [names_bytes_max]u8 = undefined,
    names_len: u32 = 0,
    entries: [entries_max]Entry = undefined,
    count: u32 = 0,
    order: sort_order.Order = .{},

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
        const na = f.slice(a);
        const nb = f.slice(b);
        const primary: std.math.Order = switch (f.order.key) {
            .name => if (natural_less(na, nb)) .lt else if (natural_less(nb, na)) .gt else .eq,
            .kind => std.ascii.orderIgnoreCase(extension(na), extension(nb)),
            else => std.math.order(a.value, b.value),
        };
        // Only the primary key reverses: ties stay in ascending name order.
        if (primary != .eq) return if (f.order.ascending) primary == .lt else primary == .gt;
        return natural_less(na, nb);
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
    pub fn scan(f: *Folder, io: std.Io, dir_path: []const u8, order: sort_order.Order) !void {
        assert(dir_path.len > 0);
        f.reset();
        f.order = order;
        var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        var seen: u32 = 0;
        while (seen < scan_entries_max) : (seen += 1) {
            const entry = try it.next(io) orelse break;
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            if (!f.add(entry.name)) break;
        }
        if (order.key != .name and order.key != .kind) f.fill_values(io, dir_path);
        f.sort();
        assert(f.count <= entries_max);
    }

    /// A failed stat leaves 0.
    fn fill_values(f: *Folder, io: std.Io, dir_path: []const u8) void {
        assert(f.order.key != .name and f.order.key != .kind);
        var buf: [paths.path_max]u8 = undefined;
        var i: u32 = 0;
        while (i < f.count) : (i += 1) {
            const e = &f.entries[i];
            e.value = 0;
            const file_path = paths.join(dir_path, f.slice(e.*), &buf) orelse continue;
            e.value = switch (f.order.key) {
                .size => if (std.Io.Dir.cwd().statFile(io, file_path, .{})) |st|
                    @intCast(@min(st.size, std.math.maxInt(i64)))
                else |_|
                    0,
                .date_modified => if (std.Io.Dir.cwd().statFile(io, file_path, .{})) |st|
                    @intCast(st.mtime.nanoseconds)
                else |_|
                    0,
                .date_created => file_times(file_path).created,
                .date_added => file_times(file_path).added,
                .name, .kind => unreachable,
            };
        }
        assert(i == f.count);
    }
};

fn extension(file_name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, file_name, '.') orelse return "";
    assert(dot < file_name.len);
    return file_name[dot + 1 ..];
}

const FileTimes = struct { created: i64 = 0, added: i64 = 0 };

const attr = struct {
    const List = extern struct {
        bitmapcount: u16 = 5, // ATTR_BIT_MAP_COUNT
        reserved: u16 = 0,
        commonattr: u32,
        volattr: u32 = 0,
        dirattr: u32 = 0,
        fileattr: u32 = 0,
        forkattr: u32 = 0,
    };
    const cmn_crtime: u32 = 0x00000200;
    const cmn_addedtime: u32 = 0x10000000;
    /// The reply's length word and two packed timespecs.
    const reply_size: u32 = 4 + 16 + 16;
    extern "c" fn getattrlist(
        path: [*:0]const u8,
        list: *List,
        buf: *anyopaque,
        size: usize,
        options: c_uint,
    ) c_int;
};

/// Creation and added dates in nanoseconds (macOS; other systems are never
/// asked for these keys). A failure gives zeros.
fn file_times(file_path: []const u8) FileTimes {
    if (builtin.os.tag != .macos) return .{};
    var z: [paths.path_max + 1]u8 = undefined;
    if (file_path.len > paths.path_max) return .{};
    @memcpy(z[0..file_path.len], file_path);
    z[file_path.len] = 0;
    var list: attr.List = .{ .commonattr = attr.cmn_crtime | attr.cmn_addedtime };
    var reply: [64]u8 align(8) = @splat(0);
    const path_z: [*:0]const u8 = @ptrCast(&z);
    if (attr.getattrlist(path_z, &list, &reply, reply.len, 0) != 0) return .{};
    const len = std.mem.readInt(u32, reply[0..4], .little);
    if (len != attr.reply_size) return .{};
    return .{ .created = timespec_ns(reply[4..20]), .added = timespec_ns(reply[20..36]) };
}

fn timespec_ns(bytes: *const [16]u8) i64 {
    const sec = std.mem.readInt(i64, bytes[0..8], .little);
    const nsec = std.mem.readInt(i64, bytes[8..16], .little);
    assert(nsec >= 0 and nsec < std.time.ns_per_s);
    return sec *| std.time.ns_per_s +| nsec;
}

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

test "sort follows the order's key and direction" {
    const f = try testing.allocator.create(Folder);
    defer testing.allocator.destroy(f);
    f.* = .{};
    try testing.expect(f.add("b.png"));
    try testing.expect(f.add("a.png"));
    f.entries[0].value = 1;
    f.entries[1].value = 2;
    f.order = .{ .key = .date_modified, .ascending = true };
    f.sort();
    try testing.expectEqualStrings("b.png", f.name(0));
    f.order.ascending = false;
    f.sort();
    try testing.expectEqualStrings("a.png", f.name(0));
    f.reset();
    try testing.expect(f.add("a.png"));
    try testing.expect(f.add("z.jpg"));
    f.order = .{ .key = .kind, .ascending = true };
    f.sort();
    try testing.expectEqualStrings("z.jpg", f.name(0));
}
