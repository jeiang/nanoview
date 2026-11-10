//! Finder's view settings for a folder, read from `.DS_Store`: a buddy
//! allocator file holding a B-tree of records. Big-endian throughout.
//! A folder's settings are records under its own name in its parent's store.
const std = @import("std");
const bplist = @import("bplist.zig");
const paths = @import("paths.zig");
const sort_order = @import("sort_order.zig");
const assert = std.debug.assert;

pub const size_max: u32 = 4 * 1024 * 1024;
const name_units_max: u32 = 255;
const depth_max: u32 = 8;
const records_max: u32 = 65536;
const directory_entries_max: u32 = 256;
const columns_max: u32 = 64;

/// Only the main thread reads stores, one at a time.
var buffer: [size_max]u8 = undefined;

pub fn detect(io: std.Io, dir_path: []const u8) sort_order.Order {
    assert(dir_path.len > 0);
    var path_buf: [paths.path_max]u8 = undefined;
    if (std.fs.path.dirname(dir_path)) |parent| {
        if (paths.join(parent, ".DS_Store", &path_buf)) |store| {
            if (paths.read_file(io, store, &buffer)) |bytes| {
                if (order_for(bytes, std.fs.path.basename(dir_path))) |order| return order;
            } else |_| {}
        }
    }
    const store = paths.join(dir_path, ".DS_Store", &path_buf) orelse return .{};
    const bytes = paths.read_file(io, store, &buffer) catch return .{};
    const result = order_for(bytes, ".") orelse return .{};
    assert(@backingInt(result.key) <= @backingInt(sort_order.Key.date_added));
    return result;
}

const Store = struct {
    bytes: []const u8,
    addresses: u32, // offset of the address array, from file offset 4
    address_count: u32,

    fn read_u32(st: *const Store, at: u64) ?u32 {
        assert(st.bytes.len >= 36);
        if (at > st.bytes.len or st.bytes.len - at < 4) return null;
        const i: usize = @intCast(at);
        assert(i + 4 <= st.bytes.len);
        return std.mem.readInt(u32, st.bytes[i..][0..4], .big);
    }

    /// Where block `number` starts in the file, and its size.
    fn block(st: *const Store, number: u32) ?struct { start: u64, size: u64 } {
        if (number >= st.address_count) return null;
        const a = st.read_u32(4 + @as(u64, st.addresses) + @as(u64, number) * 4) orelse return null;
        const start = @as(u64, a & ~@as(u32, 0x1f)) + 4;
        const size = @as(u64, 1) << @intCast(a & 0x1f);
        if (start > st.bytes.len or st.bytes.len - start < size) return null;
        assert(start >= 4 and start + size <= st.bytes.len);
        return .{ .start = start, .size = size };
    }
};

fn open_store(bytes: []const u8) ?Store {
    if (bytes.len < 36 or !std.mem.eql(u8, bytes[0..8], "\x00\x00\x00\x01Bud1")) return null;
    const root_offset = std.mem.readInt(u32, bytes[8..12], .big);
    var st: Store = .{ .bytes = bytes, .addresses = 0, .address_count = 0 };
    const count = st.read_u32(4 + @as(u64, root_offset)) orelse return null;
    if (count > records_max) return null;
    st.addresses = root_offset + 8;
    st.address_count = count;
    assert(st.address_count == count);
    return st;
}

/// The block number of the B-tree's master block, named `DSDB`.
fn master_block(st: *const Store) ?u32 {
    assert(st.address_count <= records_max);
    const padded = (@as(u64, st.address_count) + 255) / 256 * 256;
    assert(padded % 256 == 0 and padded >= st.address_count);
    var at: u64 = 4 + @as(u64, st.addresses) + padded * 4;
    const entries = st.read_u32(at) orelse return null;
    at += 4;
    var i: u32 = 0;
    while (i < @min(entries, directory_entries_max)) : (i += 1) {
        if (at >= st.bytes.len) return null;
        const len = st.bytes[@intCast(at)];
        const name_end = at + 1 + len;
        if (name_end > st.bytes.len) return null;
        const number = st.read_u32(name_end) orelse return null;
        if (std.mem.eql(u8, st.bytes[@intCast(at + 1)..@intCast(name_end)], "DSDB")) return number;
        at = name_end + 4;
    }
    return null;
}

const Record = struct {
    name: []const u8, // UTF-16BE
    code: [4]u8,
    kind: [4]u8,
    data: []const u8, // a blob's bytes without its length
    end: u64,
};

fn read_record(st: *const Store, at: u64) ?Record {
    assert(st.bytes.len >= 36);
    const units = st.read_u32(at) orelse return null;
    if (units > 1024) return null;
    const name_end = at + 4 + @as(u64, units) * 2;
    if (name_end + 8 > st.bytes.len) return null;
    const b = st.bytes;
    const n: usize = @intCast(name_end);
    const code = b[n..][0..4].*;
    const kind = b[n + 4 ..][0..4].*;
    const data_at = name_end + 8;
    var data_len: u64 = 0;
    var skip: u64 = 0;
    if (eq4(kind, "long") or eq4(kind, "shor") or eq4(kind, "type")) {
        data_len = 4;
    } else if (eq4(kind, "bool")) {
        data_len = 1;
    } else if (eq4(kind, "comp") or eq4(kind, "dutc")) {
        data_len = 8;
    } else if (eq4(kind, "blob")) {
        data_len = st.read_u32(data_at) orelse return null;
        skip = 4;
    } else if (eq4(kind, "ustr")) {
        data_len = @as(u64, st.read_u32(data_at) orelse return null) * 2;
        skip = 4;
    } else return null;
    const end = data_at + skip + data_len;
    if (end > b.len) return null;
    assert(end > at and end <= b.len);
    assert(n - @as(usize, @intCast(at + 4)) == @as(usize, units) * 2);
    return .{
        .name = b[@intCast(at + 4)..n],
        .code = code,
        .kind = kind,
        .data = b[@intCast(data_at + skip)..@intCast(end)],
        .end = end,
    };
}

fn eq4(a: [4]u8, comptime b: *const [4]u8) bool {
    comptime assert(b.len == 4);
    return std.mem.eql(u8, &a, b);
}

/// The view records of one folder; each is empty when absent.
const Views = struct {
    vstl: []const u8 = "",
    lsvc: []const u8 = "",
    lsvp: []const u8 = "",
    icvp: []const u8 = "",

    fn take(v: *Views, r: Record) void {
        assert(r.end > 0 and r.name.len % 2 == 0);
        if (eq4(r.code, "vstl") and eq4(r.kind, "type")) v.vstl = r.data;
        if (eq4(r.code, "lsvC") and eq4(r.kind, "blob")) v.lsvc = r.data;
        if (eq4(r.code, "lsvp") and eq4(r.kind, "blob")) v.lsvp = r.data;
        if (eq4(r.code, "icvp") and eq4(r.kind, "blob")) v.icvp = r.data;
    }
};

pub fn order_for(bytes: []const u8, name: []const u8) ?sort_order.Order {
    assert(name.len > 0);
    var name16: [name_units_max * 2]u8 = undefined;
    const want = utf16be(name, &name16) orelse return null;
    const st = open_store(bytes) orelse return null;
    const master = st.block(master_block(&st) orelse return null) orelse return null;
    const root = st.read_u32(master.start) orelse return null;
    var views: Views = .{};
    if (!walk(&st, root, want, &views)) return null;
    assert(want.len % 2 == 0);
    if (std.mem.eql(u8, views.vstl, "icnv") and views.icvp.len > 0) return from_arrange(views.icvp);
    if (views.lsvc.len > 0) return from_list(views.lsvc);
    if (views.lsvp.len > 0) return from_list(views.lsvp);
    if (views.icvp.len > 0) return from_arrange(views.icvp);
    return null;
}

fn utf16be(name: []const u8, out: *[name_units_max * 2]u8) ?[]const u8 {
    assert(name.len > 0);
    var units: [name_units_max]u16 = undefined;
    if (name.len > name_units_max * 3) return null;
    const n = std.unicode.utf8ToUtf16Le(&units, name) catch return null;
    if (n > name_units_max) return null;
    for (units[0..n], 0..) |u, i| std.mem.writeInt(u16, out[i * 2 ..][0..2], u, .big);
    assert(n * 2 <= out.len);
    return out[0 .. n * 2];
}

const Frame = struct { block: u32, position: u32, cursor: u64 };

/// Visits every record with an explicit stack, keeping those named `want`.
/// False when the tree is malformed.
fn walk(st: *const Store, root: u32, want: []const u8, views: *Views) bool {
    assert(want.len > 0 and want.len % 2 == 0);
    var stack: [depth_max]Frame = undefined;
    var depth: u32 = 1;
    stack[0] = .{ .block = root, .position = 0, .cursor = 0 };
    var records: u32 = 0;
    var steps: u32 = 0;
    while (depth > 0) : (steps += 1) {
        if (steps >= records_max * 2 or records >= records_max) return false;
        const top = &stack[depth - 1];
        const blk = st.block(top.block) orelse return false;
        const rightmost = st.read_u32(blk.start) orelse return false;
        const count = st.read_u32(blk.start + 4) orelse return false;
        if (top.position == 0) top.cursor = blk.start + 8;
        if (top.position == count) {
            // A leaf is done; an inner node goes on to its rightmost child.
            if (rightmost == 0) depth -= 1 else top.* = .{
                .block = rightmost,
                .position = 0,
                .cursor = 0,
            };
            continue;
        }
        var child: u32 = 0;
        if (rightmost != 0) {
            child = st.read_u32(top.cursor) orelse return false;
            top.cursor += 4;
        }
        const r = read_record(st, top.cursor) orelse return false;
        if (r.end > blk.start + blk.size) return false;
        assert(r.end > top.cursor);
        if (std.mem.eql(u8, r.name, want)) views.take(r);
        records += 1;
        top.cursor = r.end;
        top.position += 1;
        if (rightmost != 0) {
            if (depth == depth_max) return false;
            stack[depth] = .{ .block = child, .position = 0, .cursor = 0 };
            depth += 1;
        }
    }
    assert(depth == 0);
    return true;
}

fn key_of(id: []const u8) sort_order.Key {
    assert(id.len <= std.math.maxInt(u32));
    const table = .{
        .{ "name", .name },                .{ "kind", .kind },
        .{ "size", .size },                .{ "dateModified", .date_modified },
        .{ "dateCreated", .date_created }, .{ "dateAdded", .date_added },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, id, entry[0])) return entry[1];
    }
    return .name;
}

/// Finder's own directions when a setting gives none.
fn default_order(key: sort_order.Key) sort_order.Order {
    const result: sort_order.Order = .{ .key = key, .ascending = key == .name or key == .kind };
    assert(result.key == key);
    return result;
}

fn from_arrange(blob: []const u8) sort_order.Order {
    assert(blob.len > 0);
    const p = bplist.parse(blob) orelse return .{};
    const by = bplist.dict_get(&p, p.top, "arrangeBy") orelse return .{};
    const result = default_order(key_of(bplist.as_string(&p, by) orelse return .{}));
    assert(result.ascending == (result.key == .name or result.key == .kind));
    return result;
}

fn from_list(blob: []const u8) sort_order.Order {
    assert(blob.len > 0);
    const p = bplist.parse(blob) orelse return .{};
    const column_obj = bplist.dict_get(&p, p.top, "sortColumn") orelse return .{};
    const column = bplist.as_string(&p, column_obj) orelse return .{};
    const order = default_order(key_of(column));
    const columns = bplist.dict_get(&p, p.top, "columns") orelse return order;
    const settings = column_settings(&p, columns, column) orelse return order;
    const ascending_obj = bplist.dict_get(&p, settings, "ascending") orelse return order;
    const ascending = bplist.as_bool(&p, ascending_obj) orelse return order;
    assert(order.key == key_of(column));
    return .{ .key = order.key, .ascending = ascending };
}

/// `columns` is an array of dicts with `identifier` (lsvC) or a dict keyed
/// by identifier (lsvp).
fn column_settings(p: *const bplist.Plist, columns: u64, column: []const u8) ?u64 {
    assert(columns < p.count);
    if (bplist.is_dict(p, columns)) return bplist.dict_get(p, columns, column);
    const len = bplist.array_len(p, columns) orelse return null;
    var i: u32 = 0;
    while (i < @min(len, columns_max)) : (i += 1) {
        const item = bplist.array_at(p, columns, i) orelse return null;
        const id_obj = bplist.dict_get(p, item, "identifier") orelse continue;
        const id = bplist.as_string(p, id_obj) orelse continue;
        if (std.mem.eql(u8, id, column)) return item;
    }
    return null;
}

const testing = std.testing;
const fixture = @embedFile("testdata/list_date_modified.DS_Store");

test "order_for reads a list view sorted by date modified, newest first" {
    const order = order_for(fixture, "child").?;
    try testing.expectEqual(sort_order.Key.date_modified, order.key);
    try testing.expect(!order.ascending);
    try testing.expect(order_for(fixture, "other") == null);
}

test "order_for survives every truncation" {
    var cut: usize = 0;
    while (cut <= fixture.len) : (cut += 1) {
        if (order_for(fixture[0..cut], "child")) |order| {
            try testing.expect(@backingInt(order.key) <= @backingInt(sort_order.Key.date_added));
        }
    }
}

test "key_of maps Finder's identifiers" {
    try testing.expectEqual(sort_order.Key.date_added, key_of("dateAdded"));
    try testing.expectEqual(sort_order.Key.name, key_of("dateLastOpened"));
    try testing.expectEqual(sort_order.Key.name, key_of("none"));
}
