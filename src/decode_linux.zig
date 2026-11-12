//! Optional GdkPixbuf codecs, resolved at each call without shared mutable state.
const std = @import("std");
const decoder = @import("decode.zig");
const Size = decoder.Size;
const assert = std.debug.assert;

const SList = extern struct { data: ?*anyopaque, next: ?*SList };
const SizeFn = *const fn (*anyopaque, c_int, c_int, *anyopaque) callconv(.c) void;
const Api = struct {
    gdk_pixbuf_loader_new: *const fn () callconv(.c) ?*anyopaque,
    gdk_pixbuf_loader_write: *const fn (
        *anyopaque,
        [*]const u8,
        usize,
        ?*anyopaque,
    ) callconv(.c) c_int,
    gdk_pixbuf_loader_close: *const fn (*anyopaque, ?*anyopaque) callconv(.c) c_int,
    gdk_pixbuf_loader_set_size: *const fn (*anyopaque, c_int, c_int) callconv(.c) void,
    gdk_pixbuf_loader_get_pixbuf: *const fn (*anyopaque) callconv(.c) ?*anyopaque,
    gdk_pixbuf_apply_embedded_orientation: *const fn (*anyopaque) callconv(.c) ?*anyopaque,
    gdk_pixbuf_get_option: *const fn (*anyopaque, [*:0]const u8) callconv(.c) ?[*:0]const u8,
    gdk_pixbuf_get_width: *const fn (*anyopaque) callconv(.c) c_int,
    gdk_pixbuf_get_height: *const fn (*anyopaque) callconv(.c) c_int,
    gdk_pixbuf_get_n_channels: *const fn (*anyopaque) callconv(.c) c_int,
    gdk_pixbuf_get_has_alpha: *const fn (*anyopaque) callconv(.c) c_int,
    gdk_pixbuf_get_bits_per_sample: *const fn (*anyopaque) callconv(.c) c_int,
    gdk_pixbuf_get_rowstride: *const fn (*anyopaque) callconv(.c) c_int,
    gdk_pixbuf_get_pixels: *const fn (*anyopaque) callconv(.c) ?[*]const u8,
    gdk_pixbuf_get_byte_length: *const fn (*anyopaque) callconv(.c) usize,
    gdk_pixbuf_scale_simple: *const fn (*anyopaque, c_int, c_int, c_int) callconv(.c) ?*anyopaque,
    gdk_pixbuf_get_formats: *const fn () callconv(.c) ?*SList,
    gdk_pixbuf_format_is_disabled: *const fn (*anyopaque) callconv(.c) c_int,
    gdk_pixbuf_format_get_extensions: *const fn (*anyopaque) callconv(.c) ?[*:null]?[*:0]u8,
    g_signal_connect_data: *const fn (
        *anyopaque,
        [*:0]const u8,
        SizeFn,
        *anyopaque,
        ?*anyopaque,
        c_uint,
    ) callconv(.c) c_ulong,
    g_object_unref: *const fn (*anyopaque) callconv(.c) void,
    g_slist_free: *const fn (?*SList) callconv(.c) void,
    g_strfreev: *const fn (?[*:null]?[*:0]u8) callconv(.c) void,
};

const Library = struct {
    handle: *anyopaque,
    api: Api,

    fn open() !Library {
        // GTypes retain code pointers after objects die; NODELETE keeps those valid
        // across dlclose while balancing every per-call dlopen reference.
        const handle = std.c.dlopen("libgdk_pixbuf-2.0.so.0", .{
            .NOW = true,
            .NODELETE = true,
        }) orelse return error.Unavailable;
        errdefer _ = std.c.dlclose(handle);
        var api: Api = undefined;
        inline for (@typeInfo(Api).@"struct".field_names) |name| {
            const symbol = std.c.dlsym(handle, name) orelse return error.Unavailable;
            @field(api, name) = @ptrCast(@alignCast(symbol));
        }
        return .{ .handle = handle, .api = api };
    }

    fn close(self: Library) void {
        _ = std.c.dlclose(self.handle);
    }
};

const Prepared = struct {
    api: *const Api,
    side: u32,
    native_w: u32 = 0,
    native_h: u32 = 0,
    failure: ?anyerror = null,
};

fn size_prepared(loader: *anyopaque, w: c_int, h: c_int, data: *anyopaque) callconv(.c) void {
    const state: *Prepared = @ptrCast(@alignCast(data));
    if (state.failure != null) return;
    if (w <= 0 or h <= 0) {
        state.failure = error.NotImage;
        state.api.gdk_pixbuf_loader_set_size(loader, 1, 1);
        return;
    }
    const size = decoder.fit(@intCast(w), @intCast(h), state.side, state.side) catch |err| {
        state.failure = err;
        // The signal cannot abort loading: request minimal storage until write returns.
        state.api.gdk_pixbuf_loader_set_size(loader, 1, 1);
        return;
    };
    state.native_w = size.native_w;
    state.native_h = size.native_h;
    state.api.gdk_pixbuf_loader_set_size(loader, @intCast(size.width), @intCast(size.height));
}

pub fn decode_fit(encoded: []const u8, out: []u8, bounds_w: u32, bounds_h: u32) !Size {
    if (encoded.len > decoder.file_size_max) return error.TooLarge;
    if (encoded.len == 0) return error.NotImage;
    if (bounds_w == 0 or bounds_h == 0) return error.TooLarge;
    const library = try Library.open();
    defer library.close();
    const api = &library.api;
    const loader = api.gdk_pixbuf_loader_new() orelse return error.Data;
    defer api.g_object_unref(loader);
    // Orientation metadata is not necessarily available at size-prepared. A square
    // bound preserves enough pixels for either orientation without a second decode.
    var prepared = Prepared{ .api = api, .side = @max(bounds_w, bounds_h) };
    if (api.g_signal_connect_data(loader, "size-prepared", size_prepared, &prepared, null, 0) == 0)
        return error.Data;
    try load_bytes(api, loader, encoded, &prepared);
    const source = api.gdk_pixbuf_loader_get_pixbuf(loader) orelse return error.NotImage;
    const option = api.gdk_pixbuf_get_option(source, "orientation");
    const swap = if (option) |value| value[0] >= '5' and value[0] <= '8' else false;
    const size = try decoder.fit(
        if (swap) prepared.native_h else prepared.native_w,
        if (swap) prepared.native_w else prepared.native_h,
        bounds_w,
        bounds_h,
    );
    if (@as(u64, size.width) * size.height * 4 > out.len) return error.TooLarge;
    const upright = api.gdk_pixbuf_apply_embedded_orientation(source) orelse return error.Data;
    defer api.g_object_unref(upright);
    if (api.gdk_pixbuf_get_width(upright) == size.width and
        api.gdk_pixbuf_get_height(upright) == size.height)
    {
        try copy_pixels(api, upright, out, size);
    } else {
        const scaled = api.gdk_pixbuf_scale_simple(
            upright,
            @intCast(size.width),
            @intCast(size.height),
            2, // GDK_INTERP_BILINEAR.
        ) orelse return error.Data;
        defer api.g_object_unref(scaled);
        try copy_pixels(api, scaled, out, size);
    }
    return size;
}

fn load_bytes(api: *const Api, loader: *anyopaque, encoded: []const u8, state: *Prepared) !void {
    var closed = false;
    defer if (!closed) {
        _ = api.gdk_pixbuf_loader_close(loader, null);
    };
    const chunk_size_max = 64 * 1024;
    var offset: usize = 0;
    while (offset < encoded.len) {
        assert(offset < decoder.file_size_max);
        const end = @min(encoded.len, offset + chunk_size_max);
        const chunk = encoded[offset..end];
        const ok = api.gdk_pixbuf_loader_write(loader, chunk.ptr, chunk.len, null);
        if (state.failure) |err| return err;
        if (ok == 0) return error.NotImage;
        offset = end;
    }
    const ok = api.gdk_pixbuf_loader_close(loader, null);
    closed = true;
    if (state.failure) |err| return err;
    if (ok == 0 or state.native_w == 0 or state.native_h == 0) return error.NotImage;
}

fn copy_pixels(api: *const Api, pixbuf: *anyopaque, out: []u8, size: Size) !void {
    assert(size.width > 0 and size.height > 0);
    assert(@as(u64, size.width) * size.height <= decoder.pixels_max);
    const channels_i = api.gdk_pixbuf_get_n_channels(pixbuf);
    const stride_i = api.gdk_pixbuf_get_rowstride(pixbuf);
    const alpha = api.gdk_pixbuf_get_has_alpha(pixbuf) != 0;
    if (api.gdk_pixbuf_get_bits_per_sample(pixbuf) != 8 or
        channels_i != @as(c_int, if (alpha) 4 else 3) or stride_i <= 0)
        return error.NotImage;
    const channels: usize = @intCast(channels_i);
    const stride: usize = @intCast(stride_i);
    const row_bytes = @as(usize, size.width) * channels;
    if (stride < row_bytes) return error.NotImage;
    const bytes = @as(usize, size.height - 1) * stride + row_bytes;
    if (bytes > api.gdk_pixbuf_get_byte_length(pixbuf)) return error.NotImage;
    const pixels = api.gdk_pixbuf_get_pixels(pixbuf) orelse return error.NotImage;
    for (0..size.height) |y| {
        for (0..size.width) |x| {
            const src = y * stride + x * channels;
            const dst = (y * size.width + x) * 4;
            const a: u16 = if (alpha) pixels[src + 3] else 255;
            out[dst] = @intCast((@as(u16, pixels[src + 2]) * a + 127) / 255);
            out[dst + 1] = @intCast((@as(u16, pixels[src + 1]) * a + 127) / 255);
            out[dst + 2] = @intCast((@as(u16, pixels[src]) * a + 127) / 255);
            out[dst + 3] = @intCast(a);
        }
    }
}

// Only raster formats known to the viewer. Baseline PNG/JPEG/GIF belong to
// the caller, not to the optional system codec inventory. Never advertise SVG/PDF.
const known_extensions = decoder.known_extensions;
const formats_max = 256;
const format_extensions_max = 64;

pub fn extensions(out: [][]const u8) usize {
    const library = Library.open() catch return 0;
    defer library.close();
    const api = &library.api;
    const formats = api.gdk_pixbuf_get_formats();
    defer api.g_slist_free(formats);
    var supported: [known_extensions.len]bool = @splat(false);
    var node = formats;
    for (0..formats_max) |_| {
        const item = node orelse break;
        node = item.next;
        const format = item.data orelse continue;
        if (api.gdk_pixbuf_format_is_disabled(format) != 0) continue;
        const names = api.gdk_pixbuf_format_get_extensions(format) orelse continue;
        defer api.g_strfreev(names);
        for (0..format_extensions_max) |i| {
            const name = names[i] orelse break;
            var matched: [known_extensions.len][]const u8 = undefined;
            const count = decoder.intersect(&.{std.mem.span(name)}, &matched);
            for (known_extensions, 0..) |known, j| {
                for (matched[0..count]) |match| {
                    if (std.mem.eql(u8, known, match)) supported[j] = true;
                }
            }
        }
    }
    var count: usize = 0;
    for (known_extensions, supported) |known, available| {
        if (!available) continue;
        if (count == out.len) break;
        out[count] = known;
        count += 1;
    }
    assert(count <= out.len);
    assert(count <= known_extensions.len);
    return count;
}
