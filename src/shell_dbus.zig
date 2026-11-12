//! GIO owns its D-Bus objects; nanoview supplies only bounded stack buffers.
const std = @import("std");
const shell = @import("shell.zig");
const paths = @import("paths.zig");
const timeout_ms: i32 = 2000;
const Api = struct {
    g_bus_get_sync: *const fn (i32, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque,
    g_variant_new_strv: *const fn ([*]const [*:0]const u8, isize) callconv(.c) *anyopaque,
    g_variant_new_string: *const fn ([*:0]const u8) callconv(.c) *anyopaque,
    g_variant_new_tuple: *const fn ([*]const *anyopaque, usize) callconv(.c) *anyopaque,
    g_variant_unref: *const fn (*anyopaque) callconv(.c) void,
    g_object_unref: *const fn (*anyopaque) callconv(.c) void,
    g_dbus_connection_call_sync: *const fn (
        *anyopaque,
        [*:0]const u8,
        [*:0]const u8,
        [*:0]const u8,
        [*:0]const u8,
        *anyopaque,
        ?*anyopaque,
        u32,
        i32,
        ?*anyopaque,
        ?*anyopaque,
    ) callconv(.c) ?*anyopaque,
};
var api: Api = undefined;
var attempted = false;
var loaded = false;

fn load() bool {
    if (attempted) return loaded;
    attempted = true;
    const lib = std.c.dlopen("libgio-2.0.so.0", .{ .NOW = true }) orelse return false;
    inline for (@typeInfo(Api).@"struct".field_names) |name| {
        const symbol = std.c.dlsym(lib, name) orelse {
            _ = std.c.dlclose(lib);
            return false;
        };
        @field(api, name) = @ptrCast(symbol);
    }
    loaded = true;
    return true;
}

pub fn reveal(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/' or !load()) return false;
    var escaped_buf: [paths.path_max * 3]u8 = undefined;
    const encoded = shell.escaped(path, &escaped_buf) orelse return false;
    var uri_buf: [paths.path_max * 3 + 8]u8 = undefined;
    const uri = std.mem.printSentinel(&uri_buf, "file://{s}", .{encoded}, 0) catch return false;
    const connection = api.g_bus_get_sync(2, null, null) orelse return false;
    defer api.g_object_unref(connection);
    const uris = [_][*:0]const u8{uri.ptr};
    const children = [_]*anyopaque{
        api.g_variant_new_strv(&uris, 1), api.g_variant_new_string(""),
    };
    const parameters = api.g_variant_new_tuple(&children, children.len);
    // The call sinks the floating parameter tuple, including its children.
    const reply = api.g_dbus_connection_call_sync(
        connection,
        "org.freedesktop.FileManager1",
        "/org/freedesktop/FileManager1",
        "org.freedesktop.FileManager1",
        "ShowItems",
        parameters,
        null,
        0,
        timeout_ms,
        null,
        null,
    ) orelse return false;
    api.g_variant_unref(reply);
    return true;
}
