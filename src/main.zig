const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const app_state = @import("app.zig");
const view = @import("view.zig");
const preload = @import("preload.zig");
const settings = @import("settings.zig");
const recent = @import("recent.zig");
const instance = @import("instance.zig");
const animation = @import("animation.zig");
const State = app_state.State;

// About 1.2 MiB: never on the stack.
var state: State = undefined;

pub fn main(init: std.process.Init) !void {
    const app = try nanoui.App.create(init, .{ .name = "nanoview" });
    defer app.destroy();
    const file_buffer = try app_state.alloc_pages(app_state.file_size_max);
    defer app_state.free_pages(file_buffer);
    const pool = try app_state.alloc_pages(preload.pool_bytes);
    defer app_state.free_pages(pool);
    const scratch_len = if (preload.decoded) app_state.file_size_max else 0;
    const scratch = try app_state.alloc_pages(scratch_len);
    defer app_state.free_pages(scratch);
    const current_pixels = try app_state.alloc_pages(app_state.current_pixels_max);
    defer app_state.free_pages(current_pixels);
    const animation_memory = try app_state.alloc_pages(animation.memory_bytes);
    defer app_state.free_pages(animation_memory);
    state.init(init.io, init.gpa, file_buffer, pool, scratch, current_pixels, animation_memory);
    load_settings(init);
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var files: [@import("folder.zig").entries_max][]const u8 = undefined;
    var count: u32 = 0;
    const arguments = args[@min(args.len, 1)..];
    for (arguments[0..@min(arguments.len, files.len)]) |arg| {
        if (std.mem.startsWith(u8, arg, "--")) continue;
        if (count == files.len) break;
        files[count] = arg;
        count += 1;
    }
    // Before the slow startup: a process that hands its files over shows
    // none, and one started in the same instant finds this one.
    const owner = start_instance(init.io, files[0..count]) orelse return;
    defer if (owner) instance.platform.release();
    load_recent(init);
    // Elsewhere nanoui would add its roles' keys (Ctrl+Q): no menu bar.
    if (builtin.os.tag == .macos) app.setMenu(@import("menus.zig").menu_bar(&state)) catch |err| {
        state.notify("Menu bar: {s}", .{@errorName(err)});
    };
    app.onOpenFiles(&state, State.on_open_files);
    state.window = try app.newWindow(.{
        .title = "nanoview",
        .icon = switch (builtin.os.tag) {
            .windows => @embedFile("nanoview.ico"),
            .linux => @embedFile("nanoview.png"),
            else => null,
        },
        .width = 800,
        .height = 600,
        .min_width = 320,
        .min_height = 240,
        // macOS always draws under its title bar; nanoui's GTK window has
        // no hidden one, so Linux keeps the system's.
        .title_bar = if (builtin.os.tag == .macos or
            (builtin.os.tag == .windows and state.settings.title_bar == .hidden))
            .hidden
        else
            .default,
        .always_on_top = state.settings.always_on_top,
        .content = .{ .view = .init(&state, view.view) },
    });
    if (owner) instance.platform.listen(&state, State.on_instance) catch {
        state.notify("Single instance is off: cannot watch for other nanoviews", .{});
    };
    try state.preload.start();
    defer state.preload.stop();
    state.open_paths(files[0..count]);
    try app.run();
}

/// Null when the files went to the running nanoview: this process is done.
/// True when this process is the one later ones hand their files to.
fn start_instance(io: std.Io, files: []const []const u8) ?bool {
    if (!state.settings.single_instance) return false;
    const started = instance.start(io, files) catch |err| {
        state.notify("Single instance is off: {s}", .{instance.describe(err)});
        return false;
    };
    return if (started == .handed) null else true;
}

fn load_settings(init: std.process.Init) void {
    const directory = settings.config_directory(init.gpa, init.environ_map) catch |err| {
        state.notify("settings.conf: {s}", .{@errorName(err)});
        return;
    };
    defer init.gpa.free(directory);
    state.load_settings(directory);
}

fn load_recent(init: std.process.Init) void {
    if (!state.settings.recent) return;
    const directory = recent.directory(init.gpa, init.environ_map) catch |err| {
        state.notify("Recent files: {s}", .{@errorName(err)});
        return;
    };
    defer init.gpa.free(directory);
    state.load_recent(directory);
}
