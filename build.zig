const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const nanoui = b.dependency("nanoui", .{ .target = target, .optimize = optimize })
        .module("nanoui");

    const exe = b.addExecutable(.{
        .name = "nanoview",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "nanoui", .module = nanoui }},
        }),
    });
    if (target.result.os.tag == .windows) exe.subsystem = .windows;
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run nanoview").dependOn(&run.step);

    if (target.result.os.tag == .macos) {
        const bundle_exe = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{
            .custom = "nanoview.app/Contents/MacOS",
        } } });
        const plist_dest = "nanoview.app/Contents/Info.plist";
        const plist = b.addInstallFile(b.path("macos/Info.plist"), plist_dest);
        const app = b.step("app", "Build zig-out/nanoview.app");
        app.dependOn(&bundle_exe.step);
        app.dependOn(&plist.step);
    }

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "nanoui", .module = nanoui }},
        }),
    });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
