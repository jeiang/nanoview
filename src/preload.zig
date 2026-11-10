//! Neighbors of the shown picture, loaded ahead by one worker thread into a
//! fixed pool: decoded to window-fit pixels on macOS, file bytes elsewhere.
//! Shared state is touched only under `mutex`; a slot's bytes belong to the
//! worker while the slot is `loading` and are read-only otherwise.
const std = @import("std");
const builtin = @import("builtin");
const folder_mod = @import("folder.zig");
const paths = @import("paths.zig");
const assert = std.debug.assert;

pub const back_count: u32 = 5;
pub const ahead_count: u32 = 15;
pub const slot_count: u32 = back_count + ahead_count + 1;
pub const pool_bytes: u32 = 512 * 1024 * 1024;
pub const slot_bytes: u32 = (pool_bytes / slot_count) & ~@as(u32, 4095); // 24.4 MiB
pub const decoded = builtin.os.tag == .macos; // else slots hold file bytes
/// Pictures nanoui refuses, and so does the worker.
const pixels_max: u64 = 64 * 1000 * 1000;

pub const SlotState = enum { empty, loading, ready, failed };

pub const Slot = struct {
    state: SlotState = .empty,
    index: u32 = 0, // folder index it holds
    epoch: u32 = 0,
    len: u32 = 0, // bytes used
    width: u32 = 0, // decoded pixels (macOS)
    height: u32 = 0,
    native_w: u32 = 0, // upright full size in pixels (macOS)
    native_h: u32 = 0,
};

const Job = struct {
    slot: u32,
    path_buf: [paths.path_max]u8,
    path_len: u32,
    bounds_w: u32,
    bounds_h: u32,
};

pub const Preload = struct {
    io: std.Io,
    folder: *const folder_mod.Folder,
    pool: []u8, // pool_bytes; slot i owns pool[i * slot_bytes ..][0..slot_bytes]
    scratch: []u8, // macOS: the worker's file reads; else empty
    mutex: std.Io.Mutex = .init,
    slots: [slot_count]Slot = @splat(.{}),
    dir_buf: [paths.path_max]u8 = undefined,
    dir_len: u32 = 0,
    current: ?u32 = null, // folder index shown; never preloaded
    pinned: ?u32 = null, // slot the shown picture reads from
    epoch: u32 = 0, // bumped when folder contents or bounds change
    bounds_w: u32 = 0, // pixels a fitted picture may fill (macOS)
    bounds_h: u32 = 0,
    wake: std.atomic.Value(u32) = .init(0),
    quit: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    pub fn init(
        p: *Preload,
        io: std.Io,
        folder: *const folder_mod.Folder,
        pool: []u8,
        scratch: []u8,
    ) void {
        assert(pool.len == pool_bytes);
        assert(!decoded or scratch.len > 0);
        p.* = .{ .io = io, .folder = folder, .pool = pool, .scratch = scratch };
    }

    pub fn start(p: *Preload) !void {
        assert(p.thread == null);
        p.thread = try std.Thread.spawn(.{}, worker, .{p});
        assert(p.thread != null);
    }

    pub fn stop(p: *Preload) void {
        const thread = p.thread orelse return;
        p.quit.store(true, .release);
        p.notify();
        thread.join();
        p.thread = null;
    }

    pub fn lock(p: *Preload) void {
        p.mutex.lockUncancelable(p.io);
    }

    pub fn unlock(p: *Preload) void {
        p.mutex.unlock(p.io);
        p.notify();
    }

    fn notify(p: *Preload) void {
        _ = p.wake.fetchAdd(1, .release);
        p.io.futexWake(u32, &p.wake.raw, 1);
    }

    /// With the mutex held, after the folder changed.
    pub fn invalidate(p: *Preload, dir: []const u8) void {
        assert(dir.len > 0 and dir.len <= paths.path_max);
        p.epoch +%= 1;
        @memcpy(p.dir_buf[0..dir.len], dir);
        p.dir_len = @intCast(dir.len);
        for (&p.slots) |*slot| {
            if (slot.state != .loading) slot.state = .empty;
        }
        p.pinned = null;
        p.current = null;
    }

    /// The ready slot holding `index`, pinned for the shown picture.
    pub fn take(p: *Preload, index: u32) ?u32 {
        p.lock();
        defer p.unlock();
        assert(index < p.folder.count);
        p.current = index;
        p.pinned = null;
        for (p.slots, 0..) |slot, i| {
            if (slot.state == .ready and slot.index == index and slot.epoch == p.epoch) {
                p.pinned = @intCast(i);
                break;
            }
        }
        assert(p.pinned == null or p.slots[p.pinned.?].index == index);
        return p.pinned;
    }

    pub fn set_bounds(p: *Preload, w: u32, h: u32) void {
        if (!decoded) return;
        p.lock();
        defer p.unlock();
        if (w == p.bounds_w and h == p.bounds_h) return;
        p.bounds_w = w;
        p.bounds_h = h;
        p.epoch +%= 1;
        for (&p.slots, 0..) |*slot, i| {
            if (slot.state != .loading and !p.is_pinned(i)) slot.state = .empty;
        }
        assert(p.bounds_w == w and p.bounds_h == h);
    }

    /// Read-only while the slot is not `loading`.
    pub fn slot_bytes_of(p: *const Preload, slot: u32) []const u8 {
        assert(slot < slot_count);
        assert(p.slots[slot].state != .loading);
        return p.pool[slot * slot_bytes ..][0..p.slots[slot].len];
    }

    fn worker(p: *Preload) void {
        while (true) {
            const seen = p.wake.load(.acquire);
            if (p.quit.load(.acquire)) return;
            if (!p.run_one()) p.io.futexWaitUncancelable(u32, &p.wake.raw, seen);
        }
    }

    /// One unit of work; false when there was none. Tests call it directly.
    pub fn run_one(p: *Preload) bool {
        var job: Job = undefined;
        if (!p.pick(&job)) return false;
        const memory = p.pool[job.slot * slot_bytes ..][0..slot_bytes];
        var result: Slot = .{};
        const ok = p.fill(&job, memory, &result);
        p.lock();
        defer p.unlock();
        const slot = &p.slots[job.slot];
        assert(slot.state == .loading);
        if (slot.epoch != p.epoch or !p.wanted(slot.index)) {
            slot.state = .empty;
        } else if (ok) {
            result.state = .ready;
            result.index = slot.index;
            result.epoch = slot.epoch;
            slot.* = result;
        } else {
            // Stops retries until the slot is reused.
            slot.state = .failed;
        }
        return true;
    }

    fn fill(p: *Preload, job: *const Job, memory: []u8, result: *Slot) bool {
        const file_path = job.path_buf[0..job.path_len];
        if (!decoded) {
            const bytes = paths.read_file(p.io, file_path, memory) catch return false;
            result.len = @intCast(bytes.len);
            return true;
        }
        const encoded = paths.read_file(p.io, file_path, p.scratch) catch return false;
        image_io.decode_fit(encoded, memory, job.bounds_w, job.bounds_h, result) catch return false;
        assert(result.len <= memory.len);
        return true;
    }

    /// Forward distance in 1..ahead_count, or backward in 1..back_count.
    fn wanted(p: *const Preload, index: u32) bool {
        const current = p.current orelse return false;
        const count = p.folder.count;
        if (index >= count or index == current) return false;
        const forward = (index + count - current) % count;
        const backward = (current + count - index) % count;
        assert(forward > 0 and backward > 0);
        return forward <= ahead_count or backward <= back_count;
    }

    fn held(p: *const Preload, index: u32) bool {
        for (p.slots) |slot| {
            if (slot.state != .empty and slot.epoch == p.epoch and slot.index == index) return true;
        }
        return false;
    }

    /// Under the mutex: the nearest neighbor no slot holds, and a slot for it.
    fn pick(p: *Preload, job: *Job) bool {
        p.lock();
        defer p.mutex.unlock(p.io);
        const current = p.current orelse return false;
        const count = p.folder.count;
        if (count < 2 or p.dir_len == 0) return false;
        if (decoded and (p.bounds_w == 0 or p.bounds_h == 0)) return false;
        assert(current < count);
        const index = p.next_index(current, count) orelse return false;
        const slot = p.free_slot() orelse return false;
        const name = p.folder.name(index);
        const joined = paths.join(p.dir_buf[0..p.dir_len], name, &job.path_buf) orelse return false;
        job.path_len = @intCast(joined.len);
        job.slot = slot;
        job.bounds_w = p.bounds_w;
        job.bounds_h = p.bounds_h;
        p.slots[slot] = .{ .state = .loading, .index = index, .epoch = p.epoch };
        return true;
    }

    /// +1, -1, +2, -2, ..., +5, -5, +6, ..., +15.
    fn next_index(p: *const Preload, current: u32, count: u32) ?u32 {
        var d: u32 = 1;
        while (d <= ahead_count) : (d += 1) {
            const ahead = (current + d) % count;
            if (ahead != current and !p.held(ahead)) return ahead;
            if (d > back_count) continue;
            const behind = (current + count - d % count) % count;
            if (behind != current and !p.held(behind)) return behind;
        }
        return null;
    }

    fn free_slot(p: *const Preload) ?u32 {
        for (p.slots, 0..) |slot, i| {
            if (slot.state == .empty) return @intCast(i);
        }
        for (p.slots, 0..) |slot, i| {
            const done = slot.state == .ready or slot.state == .failed;
            const stale = slot.epoch != p.epoch or !p.wanted(slot.index);
            if (done and !p.is_pinned(i) and stale) return @intCast(i);
        }
        return null;
    }

    fn is_pinned(p: *const Preload, slot: usize) bool {
        assert(slot < slot_count);
        const pinned = p.pinned orelse return false;
        return pinned == slot;
    }
};

/// macOS: a window-fit decode into caller memory, as nanoui's own
/// `ui/image.zig` decodeFit does it. ImageIO and CoreGraphics only: no
/// AppKit state, so it runs off the main thread.
const image_io = struct {
    const CGRect = extern struct { x: f64, y: f64, w: f64, h: f64 };
    extern "c" const kCFAllocatorNull: *const anyopaque;
    extern "c" const kCFBooleanTrue: *const anyopaque;
    extern "c" const kCFTypeDictionaryKeyCallBacks: opaque {};
    extern "c" const kCFTypeDictionaryValueCallBacks: opaque {};
    extern "c" const kCGImagePropertyOrientation: *const anyopaque;
    extern "c" const kCGImagePropertyPixelWidth: *const anyopaque;
    extern "c" const kCGImagePropertyPixelHeight: *const anyopaque;
    extern "c" const kCGImageSourceCreateThumbnailFromImageAlways: *const anyopaque;
    extern "c" const kCGImageSourceThumbnailMaxPixelSize: *const anyopaque;
    extern "c" const kCGImageSourceCreateThumbnailWithTransform: *const anyopaque;
    extern "c" const kCGColorSpaceSRGB: *const anyopaque;
    extern "c" fn CFDataCreateWithBytesNoCopy(
        alloc: ?*const anyopaque,
        bytes: [*]const u8,
        len: isize,
        deallocator: *const anyopaque,
    ) ?*anyopaque;
    extern "c" fn CFRelease(obj: *anyopaque) void;
    extern "c" fn CFDictionaryGetValue(dict: *anyopaque, key: *const anyopaque) ?*anyopaque;
    extern "c" fn CFNumberGetValue(n: *anyopaque, kind: c_int, out: *anyopaque) bool;
    extern "c" fn CFNumberCreate(
        alloc: ?*anyopaque,
        kind: c_int,
        value: *const anyopaque,
    ) ?*anyopaque;
    extern "c" fn CFDictionaryCreate(
        alloc: ?*anyopaque,
        keys: [*]const ?*const anyopaque,
        values: [*]const ?*const anyopaque,
        n: isize,
        key_cb: *const anyopaque,
        value_cb: *const anyopaque,
    ) ?*anyopaque;
    extern "c" fn CGImageSourceCreateWithData(data: *anyopaque, options: ?*anyopaque) ?*anyopaque;
    extern "c" fn CGImageSourceCopyPropertiesAtIndex(
        src: *anyopaque,
        index: usize,
        options: ?*anyopaque,
    ) ?*anyopaque;
    extern "c" fn CGImageSourceCreateThumbnailAtIndex(
        src: *anyopaque,
        index: usize,
        options: ?*anyopaque,
    ) ?*anyopaque;
    extern "c" fn CGImageGetWidth(img: *anyopaque) usize;
    extern "c" fn CGImageGetHeight(img: *anyopaque) usize;
    extern "c" fn CGImageRelease(img: *anyopaque) void;
    extern "c" fn CGColorSpaceCreateWithName(name: *const anyopaque) ?*anyopaque;
    extern "c" fn CGColorSpaceRelease(space: *anyopaque) void;
    extern "c" fn CGBitmapContextCreate(
        data: ?*anyopaque,
        w: usize,
        h: usize,
        bpc: usize,
        bpr: usize,
        space: ?*anyopaque,
        info: u32,
    ) ?*anyopaque;
    extern "c" fn CGContextRelease(ctx: *anyopaque) void;
    extern "c" fn CGContextSetInterpolationQuality(ctx: *anyopaque, quality: c_int) void;
    extern "c" fn CGContextDrawImage(ctx: *anyopaque, rect: CGRect, image: *anyopaque) void;

    /// Premultiplied BGRA, little endian, as nanoui draws pixels.
    const bgra_premultiplied: u32 = 2 | (2 << 12);
    const number_sint32: c_int = 3;

    const Native = struct { w: u32, h: u32 };

    /// The upright full size from the header and the EXIF orientation.
    fn native_size(src: *anyopaque) !Native {
        const props = CGImageSourceCopyPropertiesAtIndex(src, 0, null) orelse return error.NotImage;
        defer CFRelease(props);
        var w: i32 = 0;
        var h: i32 = 0;
        var orientation: i32 = 1;
        if (CFDictionaryGetValue(props, kCGImagePropertyPixelWidth)) |n|
            _ = CFNumberGetValue(n, number_sint32, &w);
        if (CFDictionaryGetValue(props, kCGImagePropertyPixelHeight)) |n|
            _ = CFNumberGetValue(n, number_sint32, &h);
        if (CFDictionaryGetValue(props, kCGImagePropertyOrientation)) |n|
            _ = CFNumberGetValue(n, number_sint32, &orientation);
        if (w <= 0 or h <= 0) return error.NotImage;
        if (@as(u64, @intCast(w)) * @as(u64, @intCast(h)) > pixels_max) return error.TooLarge;
        const swap = orientation >= 5 and orientation <= 8;
        const result: Native = if (swap)
            .{ .w = @intCast(h), .h = @intCast(w) }
        else
            .{ .w = @intCast(w), .h = @intCast(h) };
        assert(result.w > 0 and result.h > 0);
        return result;
    }

    fn thumbnail(src: *anyopaque, side: i32) !*anyopaque {
        assert(side > 0);
        const max_n = CFNumberCreate(null, number_sint32, &side) orelse return error.Data;
        defer CFRelease(max_n);
        const keys = [_]?*const anyopaque{
            kCGImageSourceCreateThumbnailFromImageAlways,
            kCGImageSourceThumbnailMaxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform,
        };
        const values = [_]?*const anyopaque{ kCFBooleanTrue, max_n, kCFBooleanTrue };
        const opts = CFDictionaryCreate(
            null,
            &keys,
            &values,
            keys.len,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks,
        ) orelse return error.Data;
        defer CFRelease(opts);
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts) orelse error.NotImage;
    }

    fn decode_fit(encoded: []const u8, out: []u8, bounds_w: u32, bounds_h: u32, slot: *Slot) !void {
        assert(bounds_w > 0 and bounds_h > 0);
        if (encoded.len == 0) return error.NotImage;
        const len: isize = @intCast(encoded.len);
        const data = CFDataCreateWithBytesNoCopy(null, encoded.ptr, len, kCFAllocatorNull) orelse
            return error.Data;
        defer CFRelease(data);
        const src = CGImageSourceCreateWithData(data, null) orelse return error.NotImage;
        defer CFRelease(src);
        const native = try native_size(src);
        const nw: f64 = @floatFromInt(native.w);
        const nh: f64 = @floatFromInt(native.h);
        const bw: f64 = @floatFromInt(bounds_w);
        const bh: f64 = @floatFromInt(bounds_h);
        const s = @min(1, @min(bw / nw, bh / nh));
        const side: i32 = @intFromFloat(@max(1, @ceil(@max(nw, nh) * s)));
        const img = try thumbnail(src, side);
        defer CGImageRelease(img);
        const w = CGImageGetWidth(img);
        const h = CGImageGetHeight(img);
        if (w == 0 or h == 0) return error.NotImage;
        if (w * h * 4 > out.len) return error.TooLarge;
        const pixels = out[0 .. w * h * 4];
        @memset(pixels, 0);
        const space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB) orelse return error.ColorSpace;
        defer CGColorSpaceRelease(space);
        const info = bgra_premultiplied;
        const ctx = CGBitmapContextCreate(pixels.ptr, w, h, 8, w * 4, space, info) orelse
            return error.BitmapContext;
        defer CGContextRelease(ctx);
        CGContextSetInterpolationQuality(ctx, 3);
        const rect: CGRect = .{ .x = 0, .y = 0, .w = @floatFromInt(w), .h = @floatFromInt(h) };
        CGContextDrawImage(ctx, rect, img);
        slot.* = .{
            .width = @intCast(w),
            .height = @intCast(h),
            .native_w = native.w,
            .native_h = native.h,
            .len = @intCast(pixels.len),
        };
        assert(slot.len == slot.width * slot.height * 4);
    }
};
