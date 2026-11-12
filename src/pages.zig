//! Pages of one file: TIFF pages, ICO sizes and other ImageIO or WIC images that are
//! not an animation. gdk-pixbuf cannot choose a page, so Linux shows the first only.
const std = @import("std");
const app = @import("app.zig");
const paths = @import("paths.zig");
const State = app.State;
const assert = std.debug.assert;

/// After a load: a file with pages says how many.
pub fn opened(s: *State) void {
    assert(s.page == 0);
    if (s.status == .shown and s.page_count > 1) {
        s.notify("Page 1 of {d}", .{s.page_count});
    }
}

/// The next (`delta` 1) or previous (-1) page; the ends hold.
pub fn turn(s: *State, delta: i32) void {
    assert(delta == 1 or delta == -1);
    assert(s.page < s.page_count);
    if (s.status != .shown) return;
    if (s.page_count <= 1) {
        s.notify("Single page", .{});
        return;
    }
    const at_end = if (delta > 0) s.page + 1 == s.page_count else s.page == 0;
    if (at_end) {
        s.notify("Page {d} of {d}", .{ s.page + 1, s.page_count });
        return;
    }
    const page = if (delta > 0) s.page + 1 else s.page - 1;
    // The shown pixels may be a preloaded slot: the page decodes from the file.
    const bytes = paths.read_file(s.io, s.path(), s.file_buffer) catch |err| {
        s.notify("Cannot read the file: {s}", .{@errorName(err)});
        return;
    };
    s.page = page;
    // A failure may have overwritten the shown page: load shows the first again.
    s.source = s.decode_current(bytes) catch |err| {
        s.load();
        s.notify("Cannot show page {d}: {s}", .{ page + 1, @errorName(err) });
        return;
    };
    s.generation +%= 1;
    s.promoted = false;
    s.promote_failed = false;
    if (s.window) |w| w.redraw();
    s.notify("Page {d} of {d}", .{ s.page + 1, s.page_count });
    assert(s.page < s.page_count);
}

/// " · page 2/5" for a file with pages; empty otherwise.
pub fn info(s: *const State, buf: []u8) []const u8 {
    if (s.page_count <= 1) return "";
    return std.fmt.bufPrint(buf, " · page {d}/{d}", .{ s.page + 1, s.page_count }) catch "";
}
