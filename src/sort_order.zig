//! The order the system file manager shows a folder in, or the one the
//! `sort` setting picks.
const std = @import("std");
const builtin = @import("builtin");

pub const Key = enum { name, kind, size, date_modified, date_created, date_added };
pub const Order = struct { key: Key = .name, ascending: bool = true };

/// The `sort` setting: `system` asks the file manager.
pub const Choice = enum { system, name, kind, size, date_modified, date_created, random };

/// Only macOS keeps a creation date nanoview reads.
pub const has_date_created = builtin.os.tag == .macos;

/// `random` lists by name; the scan then shuffles.
pub fn resolve(io: std.Io, dir_path: []const u8, choice: Choice, descending: bool) Order {
    std.debug.assert(dir_path.len > 0);
    const key: Key = switch (choice) {
        .system => return detect(io, dir_path),
        .name, .random => .name,
        .kind => .kind,
        .size => .size,
        .date_modified => .date_modified,
        .date_created => if (has_date_created) .date_created else .date_modified,
    };
    const result: Order = .{ .key = key, .ascending = !descending or choice == .random };
    std.debug.assert(has_date_created or result.key != .date_created);
    return result;
}

/// Any failure gives name, ascending.
pub fn detect(io: std.Io, dir_path: []const u8) Order {
    std.debug.assert(dir_path.len > 0);
    const result: Order = switch (builtin.os.tag) {
        .macos => @import("ds_store.zig").detect(io, dir_path),
        .windows => @import("explorer_sort.zig").detect(dir_path),
        else => .{},
    };
    // Other systems are never asked for the dates only macOS keeps.
    std.debug.assert(builtin.os.tag == .macos or
        (result.key != .date_created and result.key != .date_added));
    return result;
}

test "each sort choice resolves to its key and direction" {
    const io = std.testing.io;
    const cases = [_]struct { Choice, Key }{
        .{ .name, .name },
        .{ .kind, .kind },
        .{ .size, .size },
        .{ .date_modified, .date_modified },
        .{ .date_created, if (has_date_created) .date_created else .date_modified },
        .{ .random, .name },
    };
    for (cases) |case| {
        const up = resolve(io, "/", case[0], false);
        try std.testing.expectEqual(Order{ .key = case[1], .ascending = true }, up);
        const down = resolve(io, "/", case[0], true);
        try std.testing.expectEqual(case[0] != .random, !down.ascending);
    }
}
