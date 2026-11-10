const std = @import("std");

pub const Status = enum { empty, shown, failed };

pub const State = struct {
    io: std.Io,
    status: Status = .empty,

    pub fn init(s: *State, io: std.Io) void {
        s.* = .{ .io = io };
        std.debug.assert(s.status == .empty);
    }
};
