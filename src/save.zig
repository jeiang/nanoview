//! Save frame as PNG: the shown frame or page at its full size, without the view's
//! rotation, mirror or zoom.
const std = @import("std");
const nanoui = @import("nanoui");
const app = @import("app.zig");
const decode = @import("decode.zig");
const paths = @import("paths.zig");
const png_save = @import("png_save.zig");
const State = app.State;
const assert = std.debug.assert;

const name_len_max: u32 = 255;

/// Asks where to save, then saves.
pub fn save_frame(s: *State) void {
    if (s.status != .shown) return;
    // The frame stays while the panel is open, even if a nested event loop draws.
    const playing = s.player.playing;
    s.player.playing = false;
    defer s.player.playing = playing;
    var name_buf: [name_len_max]u8 = undefined;
    const answer = nanoui.dialog.save(s.gpa, .{
        .title = "Save Frame as PNG",
        // A pasted picture has no folder: the panel opens where it last was.
        .directory = if (s.is_file()) s.dir() else "",
        .name = suggested_name(s, &name_buf),
        .extensions = &.{"png"},
    }) catch |err| {
        s.notify("Cannot open the save panel: {s}", .{@errorName(err)});
        return;
    };
    const target = answer orelse return;
    defer s.gpa.free(target);
    save_to(s, target);
}

/// Saves the shown frame to `target`, saying how it went.
pub fn save_to(s: *State, target: []const u8) void {
    assert(target.len > 0);
    write_frame(s, target) catch |err| {
        s.notify("Cannot save the frame: {s}", .{@errorName(err)});
        return;
    };
    s.notify("Saved {s}", .{std.fs.path.basename(target)});
}

fn write_frame(s: *State, target: []const u8) !void {
    if (s.status != .shown) return error.NothingShown;
    const frame = try full_frame(s);
    // The destination is untouched until the complete PNG replaces it.
    var pending = try std.Io.Dir.cwd().createFileAtomic(s.io, target, .{ .replace = true });
    defer pending.deinit(s.io);
    try s.png.write(s.io, pending.file, frame);
    try pending.replace(s.io);
}

/// The animation's canvas, full-size pixels as shown, or the file decoded again.
fn full_frame(s: *State) !png_save.Frame {
    if (s.player.active()) {
        return .{ .bgra = s.player.canvas(), .width = s.player.width, .height = s.player.height };
    }
    if (s.source == .pixels) {
        const px = s.source.pixels;
        if (px.width == px.native_w and px.height == px.native_h) {
            return .{ .bgra = px.bgra, .width = px.width, .height = px.height };
        }
    }
    // nanoui decodes the shown picture or a preloaded one is smaller than its file:
    // neither keeps full-size pixels here. `current_pixels` is not shown in either case.
    // nanoui's bytes are the whole file already, and all a pasted picture has.
    const bytes = switch (s.source) {
        .encoded => |encoded| encoded,
        else => try paths.read_file(s.io, s.path(), s.file_buffer),
    };
    const full = std.math.maxInt(u32);
    const size = try decode.decode_fit(bytes, s.current_pixels, full, full, s.page);
    return .{
        .bgra = s.current_pixels[0 .. size.width * size.height * 4],
        .width = size.width,
        .height = size.height,
    };
}

/// "name.png", "name frame 3.png" or "name page 2.png".
fn suggested_name(s: *const State, buf: []u8) []const u8 {
    const base = s.basename();
    const stem = base[0 .. base.len - std.fs.path.extension(base).len];
    const result = if (s.player.active())
        std.fmt.bufPrint(buf, "{s} frame {d}.png", .{ stem, s.player.frame_index + 1 })
    else if (s.page_count > 1)
        std.fmt.bufPrint(buf, "{s} page {d}.png", .{ stem, s.page + 1 })
    else
        std.fmt.bufPrint(buf, "{s}.png", .{stem});
    return result catch "frame.png";
}
