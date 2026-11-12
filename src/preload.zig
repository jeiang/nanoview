//! Neighbors of the shown picture, loaded ahead by one worker thread into a
//! fixed pool: decoded to window-fit pixels by the system codec when available.
//! Shared state is touched only under `mutex`; a slot's bytes belong to the
//! worker while the slot is `loading` and are read-only otherwise.
const std = @import("std");
const decode = @import("decode.zig");
const folder_mod = @import("folder.zig");
const paths = @import("paths.zig");
const assert = std.debug.assert;

pub const back_count: u32 = 5;
pub const ahead_count: u32 = 15;
pub const slot_count: u32 = back_count + ahead_count + 1;
pub const pool_bytes: u32 = 512 * 1024 * 1024;
pub const slot_bytes: u32 = (pool_bytes / slot_count) & ~@as(u32, 4095); // 24.4 MiB
pub const decoded = decode.supported;

pub const SlotState = enum { empty, loading, ready, failed };

pub const Slot = struct {
    state: SlotState = .empty,
    index: u32 = 0, // folder index it holds
    epoch: u32 = 0,
    len: u32 = 0, // bytes used
    encoded: bool = false, // Linux without GdkPixbuf: portable nanoui file bytes
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
        assert(!p.quit.load(.acquire));
        p.quit.store(true, .release);
        p.notify();
        thread.join();
        p.thread = null;
    }

    pub fn lock(p: *Preload) void {
        assert(p.pool.len == pool_bytes);
        p.mutex.lockUncancelable(p.io);
    }

    pub fn unlock(p: *Preload) void {
        assert(p.pool.len == pool_bytes);
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
        const size = decode.decode_fit(encoded, memory, job.bounds_w, job.bounds_h) catch |err| {
            if (err != error.Unavailable or encoded.len > memory.len) return false;
            @memcpy(memory[0..encoded.len], encoded);
            result.* = .{ .encoded = true, .len = @intCast(encoded.len) };
            return true;
        };
        result.* = .{
            .width = size.width,
            .height = size.height,
            .native_w = size.native_w,
            .native_h = size.native_h,
            .len = size.width * size.height * 4,
        };
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
        assert(index < p.folder.count);
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
        assert(count >= 2 and current < count);
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
