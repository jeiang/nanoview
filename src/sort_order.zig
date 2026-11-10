//! The order the system file manager shows a folder in.
const std = @import("std");
const builtin = @import("builtin");

pub const Key = enum { name, kind, size, date_modified, date_created, date_added };
pub const Order = struct { key: Key = .name, ascending: bool = true };

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
