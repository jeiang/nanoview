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
    if (target.result.os.tag == .windows) {
        exe.subsystem = .windows;
        // The resource is Explorer's icon; main.zig hands the same file to the window.
        exe.root_module.addWin32ResourceFile(.{ .file = b.path("windows/nanoview.rc") });
        exe.root_module.addAnonymousImport("nanoview.ico", .{
            .root_source_file = b.path("windows/nanoview.ico"),
        });
    }
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
        const icns_dest = "nanoview.app/Contents/Resources/AppIcon.icns";
        const icns = b.addInstallFile(b.path("macos/AppIcon.icns"), icns_dest);
        const app = b.step("app", "Build zig-out/nanoview.app");
        app.dependOn(&bundle_exe.step);
        app.dependOn(&plist.step);
        app.dependOn(&icns.step);
    }

    const icon = b.step("icon", "Redraw the icon: macos/ and windows/ (macOS host)");
    if (b.graph.host.result.os.tag == .macos) {
        const icon_exe = b.addExecutable(.{
            .name = "icon",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/icon.zig"),
                .target = b.graph.host,
                .optimize = .ReleaseSafe,
                .link_libc = true, // erfc, for the shadow
            }),
        });
        const icon_run = b.addRunArtifact(icon_exe);
        // It writes the icon's files in the source tree.
        icon_run.setCwd(b.path("."));
        icon.dependOn(&icon_run.step);
    } else {
        icon.dependOn(&b.addFail("zig build icon runs on a Mac: it needs sips and iconutil").step);
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
