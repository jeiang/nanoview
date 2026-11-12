//! What the user can set, with the defaults. One `Settings` lives in `State`.
const std = @import("std");
const builtin = @import("builtin");
const paths = @import("paths.zig");
const assert = std.debug.assert;

pub const file_size_max: u32 = 16 * 1024;
pub const line_len_max: u32 = 512;
pub const zoom_step_percent_min: u32 = 1;
pub const zoom_step_percent_max: u32 = 400;
pub const slideshow_seconds_min: u32 = 1;
pub const slideshow_seconds_max: u32 = 3600;

pub const FitMode = enum { whole, width, height, fill };
pub const AfterTrash = enum { next, previous };

pub const Settings = struct {
    /// What "fit" shows: the whole picture, or one side filling the window.
    fit_mode: FitMode = .whole,
    /// Fit may enlarge a picture smaller than the window.
    fit_upscale: bool = false,
    /// Off: enlarged pictures show their pixels as squares.
    smooth: bool = true,
    /// The next picture keeps the zoom and position of the last.
    zoom_lock: bool = false,
    /// A checkerboard behind the picture, to tell transparency from white.
    checkerboard: bool = false,
    /// One zoom step, as a percentage added to the scale.
    zoom_step_percent: u32 = 25,
    /// Stepping past the last picture goes to the first, and back.
    loop: bool = true,
    slideshow_seconds: u32 = 5,
    slideshow_reverse: bool = false,
    /// Ask before a picture goes to the Trash.
    trash_confirm: bool = false,
    /// The picture shown after one is trashed.
    after_trash: AfterTrash = .next,
};

pub const Reason = enum {
    unknown_key,
    bad_value,
    missing_equals,
    line_too_long,
    file_too_long,

    pub fn text(reason: Reason) []const u8 {
        return switch (reason) {
            .unknown_key => "unknown key",
            .bad_value => "bad value",
            .missing_equals => "expected key = value",
            .line_too_long => "line too long",
            .file_too_long => "file too long",
        };
    }
};

pub const Problem = struct { line: u32, reason: Reason };

/// Invalid lines leave their field unchanged; later valid lines still apply.
pub fn parse(bytes: []const u8, settings: *Settings) ?Problem {
    if (bytes.len > file_size_max) return .{ .line = 1, .reason = .file_too_long };
    var first: ?Problem = null;
    var start: usize = 0;
    var line: u32 = 1;
    for (0..bytes.len + 1) |end| {
        if (end != bytes.len and bytes[end] != '\n') continue;
        const reason = parse_line(bytes[start..end], settings);
        if (first == null) {
            if (reason) |r| first = .{ .line = line, .reason = r };
        }
        start = end + 1;
        line += 1;
    }
    assert(line <= file_size_max + 2);
    return first;
}

fn parse_line(raw: []const u8, settings: *Settings) ?Reason {
    assert(raw.len <= file_size_max);
    if (raw.len > line_len_max) return .line_too_long;
    const comment = std.mem.indexOfScalar(u8, raw, '#') orelse raw.len;
    const line = std.mem.trim(u8, raw[0..comment], " \t\r");
    if (line.len == 0) return null;
    const equals = std.mem.indexOfScalar(u8, line, '=') orelse return .missing_equals;
    const key = std.mem.trim(u8, line[0..equals], " \t");
    const value = std.mem.trim(u8, line[equals + 1 ..], " \t");
    inline for (@typeInfo(Settings).@"struct".field_names) |name| {
        if (std.mem.eql(u8, key, name)) {
            @field(settings, name) = parse_value(name, value) orelse return .bad_value;
            return null;
        }
    }
    return .unknown_key;
}

fn parse_value(comptime name: []const u8, value: []const u8) ?@FieldType(Settings, name) {
    const T = @FieldType(Settings, name);
    assert(value.len <= line_len_max);
    switch (@typeInfo(T)) {
        .bool => {
            if (std.mem.eql(u8, value, "true")) return true;
            if (std.mem.eql(u8, value, "false")) return false;
            return null;
        },
        .@"enum" => return std.meta.stringToEnum(T, value),
        .int => {
            if (value.len == 0) return null;
            for (value) |ch| if (ch < '0' or ch > '9') return null;
            const number = std.fmt.parseInt(T, value, 10) catch return null;
            if (number < @field(@This(), name ++ "_min") or
                number > @field(@This(), name ++ "_max")) return null;
            return number;
        },
        else => @compileError("unsupported setting type"),
    }
}

/// nanoui.path(.data) creates directories and uses XDG_DATA_HOME on Linux.
/// Resolve without side effects, using the config convention instead.
pub fn config_directory(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (builtin.os.tag == .windows) {
        const base = env.get("APPDATA") orelse return error.NoConfigDirectory;
        return std.fs.path.join(gpa, &.{ base, "nanoview" });
    }
    if (builtin.os.tag == .macos) {
        const home = env.get("HOME") orelse return error.NoConfigDirectory;
        return std.fs.path.join(gpa, &.{ home, "Library", "Application Support", "nanoview" });
    }
    if (env.get("XDG_CONFIG_HOME")) |base| {
        if (base.len > 0 and std.fs.path.isAbsolute(base))
            return std.fs.path.join(gpa, &.{ base, "nanoview" });
    }
    const home = env.get("HOME") orelse return error.NoConfigDirectory;
    return std.fs.path.join(gpa, &.{ home, ".config", "nanoview" });
}

/// The directory argument permits a real file read without touching the user's home.
pub fn load(io: std.Io, directory: []const u8, settings: *Settings) !?Problem {
    assert(directory.len > 0);
    var path_buf: [paths.path_max]u8 = undefined;
    const path = paths.join(directory, "settings.conf", &path_buf) orelse
        return error.NameTooLong;
    var bytes: [file_size_max]u8 = undefined;
    const content = paths.read_file(io, path, &bytes) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.FileTooBig => return .{ .line = 1, .reason = .file_too_long },
        else => return err,
    };
    return parse(content, settings);
}

const testing = std.testing;

test "all settings parse with whitespace comments and blank lines" {
    var settings: Settings = .{};
    try testing.expect(parse(
        \\ # preferences
        \\
        \\ fit_mode = fill # cropped
        \\fit_upscale=true
        \\smooth = false
        \\zoom_lock = true
        \\checkerboard = true
        \\zoom_step_percent = 400
        \\loop = false
        \\slideshow_seconds = 3600
        \\slideshow_reverse = true
        \\trash_confirm = true
        \\after_trash = previous
        \\
    , &settings) == null);
    try testing.expectEqualDeep(Settings{
        .fit_mode = .fill,
        .fit_upscale = true,
        .smooth = false,
        .zoom_lock = true,
        .checkerboard = true,
        .zoom_step_percent = 400,
        .loop = false,
        .slideshow_seconds = 3600,
        .slideshow_reverse = true,
        .trash_confirm = true,
        .after_trash = .previous,
    }, settings);
    try testing.expect(parse("\tzoom_step_percent = 1\r\nslideshow_seconds=1", &settings) == null);
    try testing.expectEqual(@as(u32, 1), settings.zoom_step_percent);
    try testing.expectEqual(@as(u32, 1), settings.slideshow_seconds);
}

test "bad settings retain defaults and parsing continues with the first problem" {
    const cases = .{
        .{ "unknown = true", Reason.unknown_key },
        .{ "smooth = yes", Reason.bad_value },
        .{ "fit_mode = sideways", Reason.bad_value },
        .{ "zoom_step_percent = 0", Reason.bad_value },
        .{ "zoom_step_percent = 401", Reason.bad_value },
        .{ "slideshow_seconds = 3601", Reason.bad_value },
        .{ "slideshow_seconds = -1", Reason.bad_value },
        .{ "slideshow_seconds = 1_0", Reason.bad_value },
        .{ "slideshow_seconds = 99999999999999", Reason.bad_value },
        .{ "smooth true", Reason.missing_equals },
    };
    inline for (cases) |case| {
        var settings: Settings = .{};
        const problem = parse("# comment\n\n" ++ case[0] ++
            "\ncheckerboard=true\nalso_bad=1", &settings).?;
        try testing.expectEqual(@as(u32, 3), problem.line);
        try testing.expectEqual(case[1], problem.reason);
        var expected: Settings = .{};
        expected.checkerboard = true;
        try testing.expectEqualDeep(expected, settings);
    }
}

test "file and line limits are enforced" {
    var settings: Settings = .{};
    const huge: [file_size_max + 1]u8 = @splat(' ');
    try testing.expectEqual(Reason.file_too_long, parse(&huge, &settings).?.reason);
    const long: [line_len_max + 1]u8 = @splat('x');
    try testing.expectEqual(Reason.line_too_long, parse(&long, &settings).?.reason);
    const boundary: [line_len_max]u8 = @splat(' ');
    try testing.expect(parse(&boundary, &settings) == null);
    try testing.expectEqualDeep(Settings{}, settings);
}

test "loading a real settings file from an injected directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory: [paths.path_max]u8 = undefined;
    const len = try tmp.dir.realPathFile(testing.io, ".", &directory);
    var settings: Settings = .{};
    try testing.expect(try load(testing.io, directory[0..len], &settings) == null);
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "settings.conf",
        .data = "zoom_step_percent=80\nfit_mode=height\n",
    });
    try testing.expect(try load(testing.io, directory[0..len], &settings) == null);
    try testing.expectEqual(@as(u32, 80), settings.zoom_step_percent);
    try testing.expectEqual(FitMode.height, settings.fit_mode);
    const huge: [file_size_max + 1]u8 = @splat(' ');
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "settings.conf", .data = &huge });
    try testing.expectEqual(Reason.file_too_long, (try load(testing.io, directory[0..len], &settings)).?.reason);
}
