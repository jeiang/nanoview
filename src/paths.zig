//! File URLs from drops, and path joins, into fixed buffers.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

pub const path_max: u32 = 4096;
const windows = builtin.os.tag == .windows;

/// Null unless a local `file://` URL whose path fits.
pub fn from_file_url(url: []const u8, out: *[path_max]u8) ?[]const u8 {
    const scheme = "file://";
    if (!std.mem.startsWith(u8, url, scheme)) return null;
    const rest = url[scheme.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const authority = rest[0..slash];
    var len: u32 = 0;
    if (authority.len > 0 and !std.mem.eql(u8, authority, "localhost")) {
        // A UNC path `\\server\share\...`; other systems have no such path.
        if (!windows) return null;
        if (authority.len + 2 > path_max) return null;
        out[0] = '\\';
        out[1] = '\\';
        @memcpy(out[2..][0..authority.len], authority);
        len = @intCast(authority.len + 2);
    }
    len = decode(rest[slash..], out, len) orelse return null;
    var result: []u8 = out[0..len];
    if (windows) {
        if (authority.len == 0 or std.mem.eql(u8, authority, "localhost")) {
            if (result.len >= 3 and result[0] == '/' and result[2] == ':') result = result[1..];
        } else {
            for (result) |*ch| {
                if (ch.* == '/') ch.* = '\\';
            }
        }
    }
    assert(result.len <= path_max);
    return result;
}

/// Percent-decodes `in` after `out[0..start]`; null on a bad escape or overflow.
fn decode(in: []const u8, out: *[path_max]u8, start: u32) ?u32 {
    assert(start <= path_max);
    var len: u32 = start;
    var i: usize = 0;
    while (i < in.len) {
        if (len == path_max) return null;
        if (in[i] == '%') {
            if (i + 2 >= in.len) return null;
            const hi = std.fmt.charToDigit(in[i + 1], 16) catch return null;
            const lo = std.fmt.charToDigit(in[i + 2], 16) catch return null;
            out[len] = hi * 16 + lo;
            i += 3;
        } else {
            out[len] = in[i];
            i += 1;
        }
        len += 1;
    }
    assert(len >= start and len <= path_max);
    return len;
}

pub fn join(dir: []const u8, name: []const u8, out: *[path_max]u8) ?[]const u8 {
    assert(name.len > 0);
    const needs_sep = dir.len > 0 and !std.fs.path.isSep(dir[dir.len - 1]);
    const total = dir.len + @intFromBool(needs_sep) + name.len;
    if (total > path_max) return null;
    @memcpy(out[0..dir.len], dir);
    if (needs_sep) out[dir.len] = std.fs.path.sep;
    @memcpy(out[total - name.len ..][0..name.len], name);
    const result = out[0..total];
    assert(std.mem.endsWith(u8, result, name));
    return result;
}

const testing = std.testing;

test "from_file_url decodes local file URLs" {
    var buf: [path_max]u8 = undefined;
    if (!windows) {
        const spaced = from_file_url("file:///tmp/a%20b.png", &buf).?;
        try testing.expectEqualStrings("/tmp/a b.png", spaced);
        try testing.expectEqualStrings("/x.png", from_file_url("file://localhost/x.png", &buf).?);
        try testing.expectEqualStrings("/%E", from_file_url("file:///%25E", &buf).?);
    }
    try testing.expect(from_file_url("http://x", &buf) == null);
    try testing.expect(from_file_url("file:///a%zz", &buf) == null);
    try testing.expect(from_file_url("file:///a%2", &buf) == null);
}

test "join adds one separator" {
    var buf: [path_max]u8 = undefined;
    if (!windows) {
        try testing.expectEqualStrings("/a/b.png", join("/a", "b.png", &buf).?);
        try testing.expectEqualStrings("/a/b.png", join("/a/", "b.png", &buf).?);
    }
    const long: [path_max]u8 = @splat('x');
    try testing.expect(join(&long, "b.png", &buf) == null);
}
