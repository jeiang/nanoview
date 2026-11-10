//! A read-only view of a binary property list: strings, booleans, arrays
//! and dictionaries, enough to read Finder's view settings. No allocation.
const std = @import("std");
const assert = std.debug.assert;

const trailer_size: u32 = 32;
const dict_keys_max: u64 = 4096;

pub const Plist = struct {
    bytes: []const u8,
    offset_size: u8,
    ref_size: u8,
    count: u64,
    top: u64,
    table: u64,
};

const kind_simple: u4 = 0x0;
const kind_int: u4 = 0x1;
const kind_ascii: u4 = 0x5;
const kind_array: u4 = 0xA;
const kind_dict: u4 = 0xD;

pub fn parse(bytes: []const u8) ?Plist {
    if (bytes.len < 40 or !std.mem.startsWith(u8, bytes, "bplist00")) return null;
    const t = bytes[bytes.len - trailer_size ..];
    const p: Plist = .{
        .bytes = bytes,
        .offset_size = t[6],
        .ref_size = t[7],
        .count = std.mem.readInt(u64, t[8..16], .big),
        .top = std.mem.readInt(u64, t[16..24], .big),
        .table = std.mem.readInt(u64, t[24..32], .big),
    };
    if (p.offset_size < 1 or p.offset_size > 8 or p.ref_size < 1 or p.ref_size > 8) return null;
    if (p.count == 0 or p.top >= p.count) return null;
    const objects_end = bytes.len - trailer_size;
    if (p.table < 8 or p.table > objects_end) return null;
    if (p.count > (objects_end - p.table) / p.offset_size) return null;
    assert(p.table + p.count * p.offset_size <= objects_end);
    return p;
}

/// What `parse` established; every reader asserts it.
fn check(p: *const Plist) void {
    assert(p.offset_size >= 1 and p.offset_size <= 8);
    assert(p.ref_size >= 1 and p.ref_size <= 8);
    assert(p.count > 0 and p.top < p.count);
    assert(p.table + p.count * p.offset_size <= p.bytes.len - trailer_size);
}

/// A big-endian unsigned integer of `size` bytes at `at`, inside the objects.
fn read_uint(p: *const Plist, at: u64, size: u8) ?u64 {
    assert(size >= 1 and size <= 8);
    assert(p.bytes.len >= 40);
    const end = std.math.add(u64, at, size) catch return null;
    if (end > p.bytes.len - trailer_size) return null;
    var value: u64 = 0;
    for (p.bytes[@intCast(at)..@intCast(end)]) |b| value = (value << 8) | b;
    assert(size == 8 or value < @as(u64, 1) << @intCast(size * 8));
    return value;
}

const Header = struct { kind: u4, low: u4, count: u64, data: u64 };

fn header(p: *const Plist, obj: u64) ?Header {
    check(p);
    if (obj >= p.count) return null;
    const at = read_uint(p, p.table + obj * p.offset_size, p.offset_size) orelse return null;
    const marker: u8 = @intCast(read_uint(p, at, 1) orelse return null);
    const kind: u4 = @intCast(marker >> 4);
    const low: u4 = @intCast(marker & 0xF);
    if (low != 0xF or kind == kind_simple or kind == kind_int) {
        assert(low < 0xF or kind == kind_simple or kind == kind_int);
        return .{ .kind = kind, .low = low, .count = low, .data = at + 1 };
    }
    // The count does not fit the low nibble: an integer object follows.
    const int_marker: u8 = @intCast(read_uint(p, at + 1, 1) orelse return null);
    if (int_marker >> 4 != kind_int or int_marker & 0xF > 3) return null;
    const size: u8 = @as(u8, 1) << @intCast(int_marker & 0xF);
    const count = read_uint(p, at + 2, size) orelse return null;
    assert(size <= 8);
    return .{ .kind = kind, .low = low, .count = count, .data = at + 2 + size };
}

/// ASCII strings only.
pub fn as_string(p: *const Plist, obj: u64) ?[]const u8 {
    check(p);
    const h = header(p, obj) orelse return null;
    if (h.kind != kind_ascii) return null;
    const end = std.math.add(u64, h.data, h.count) catch return null;
    if (end > p.bytes.len - trailer_size) return null;
    const result = p.bytes[@intCast(h.data)..@intCast(end)];
    assert(result.len == h.count);
    return result;
}

pub fn as_bool(p: *const Plist, obj: u64) ?bool {
    check(p);
    const h = header(p, obj) orelse return null;
    if (h.kind != kind_simple) return null;
    assert(h.count == h.low);
    return switch (h.low) {
        0x8 => false,
        0x9 => true,
        else => null,
    };
}

fn ref_at(p: *const Plist, h: Header, i: u64) ?u64 {
    check(p);
    assert(h.kind == kind_array or h.kind == kind_dict);
    const offset = std.math.mul(u64, i, p.ref_size) catch return null;
    const at = std.math.add(u64, h.data, offset) catch return null;
    return read_uint(p, at, p.ref_size);
}

/// The value for an ASCII `key` (linear over at most 4096 keys).
pub fn dict_get(p: *const Plist, obj: u64, key: []const u8) ?u64 {
    check(p);
    const h = header(p, obj) orelse return null;
    if (h.kind != kind_dict or h.count > dict_keys_max) return null;
    assert(h.count <= dict_keys_max);
    var i: u64 = 0;
    while (i < h.count) : (i += 1) {
        const key_obj = ref_at(p, h, i) orelse return null;
        const name = as_string(p, key_obj) orelse continue;
        if (std.mem.eql(u8, name, key)) return ref_at(p, h, h.count + i);
    }
    return null;
}

pub fn array_len(p: *const Plist, obj: u64) ?u32 {
    check(p);
    const h = header(p, obj) orelse return null;
    if (h.kind != kind_array or h.count > std.math.maxInt(u32)) return null;
    assert(h.kind == kind_array);
    return @intCast(h.count);
}

pub fn array_at(p: *const Plist, obj: u64, i: u32) ?u64 {
    check(p);
    const h = header(p, obj) orelse return null;
    if (h.kind != kind_array or i >= h.count) return null;
    assert(i < h.count);
    return ref_at(p, h, i);
}

pub fn is_dict(p: *const Plist, obj: u64) bool {
    check(p);
    const h = header(p, obj) orelse return false;
    return h.kind == kind_dict;
}

const testing = std.testing;

// plistlib.dumps({"a": True, "list": ["x", "y"]}, fmt=plistlib.FMT_BINARY)
const sample = "bplist00\xd2\x01\x02\x03\x04QaTlist\x09\xa2\x05\x06QxQy" ++
    "\x08\x0d\x0f\x14\x15\x18\x1a" ++
    "\x00\x00\x00\x00\x00\x00\x01\x01" ++
    "\x00\x00\x00\x00\x00\x00\x00\x07" ++
    "\x00\x00\x00\x00\x00\x00\x00\x00" ++
    "\x00\x00\x00\x00\x00\x00\x00\x1c";

test "reads a small plist; truncations never read out of bounds" {
    const p = parse(sample).?;
    try testing.expectEqual(@as(?bool, true), as_bool(&p, dict_get(&p, p.top, "a").?));
    const list = dict_get(&p, p.top, "list").?;
    try testing.expectEqual(@as(?u32, 2), array_len(&p, list));
    try testing.expectEqualStrings("y", as_string(&p, array_at(&p, list, 1).?).?);
    try testing.expect(dict_get(&p, p.top, "missing") == null);
    var cut: usize = 0;
    while (cut < sample.len) : (cut += 1) {
        const t = parse(sample[0..cut]) orelse continue;
        if (dict_get(&t, t.top, "list")) |l| _ = array_at(&t, l, 1);
    }
}
