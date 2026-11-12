const std = @import("std");

/// libwebp's decoder and demux sources only; vendor/libwebp/src/webp/config.h leaves every
/// WEBP_HAVE_* SIMD switch off, so all targets use the same portable C path.
const webp_sources = [_][]const u8{
    "dec/alpha_dec.c",
    "dec/buffer_dec.c",
    "dec/frame_dec.c",
    "dec/idec_dec.c",
    "dec/io_dec.c",
    "dec/quant_dec.c",
    "dec/tree_dec.c",
    "dec/vp8_dec.c",
    "dec/vp8l_dec.c",
    "dec/webp_dec.c",
    "demux/demux.c",
    "dsp/alpha_processing.c",
    "dsp/cpu.c",
    "dsp/dec.c",
    "dsp/dec_clip_tables.c",
    "dsp/filters.c",
    "dsp/lossless.c",
    "dsp/rescaler.c",
    "dsp/upsampling.c",
    "dsp/yuv.c",
    "utils/bit_reader_utils.c",
    "utils/color_cache_utils.c",
    "utils/filters_utils.c",
    "utils/huffman_utils.c",
    "utils/palette.c",
    "utils/quant_levels_dec_utils.c",
    "utils/rescaler_utils.c",
    "utils/random_utils.c",
    "utils/thread_utils.c",
    "utils/utils.c",
};

/// Compiles the bundled C decoders into a module. Zig's default UBSan traps are off for
/// upstream C: upstream does not test with them, and a trap would abort the viewer.
fn add_decoders(b: *std.Build, module: *std.Build.Module) void {
    module.link_libc = true;
    // wuffs_bridge.c sets the Wuffs implementation and module macros itself.
    module.addIncludePath(b.path("vendor/wuffs"));
    module.addCSourceFile(.{
        .file = b.path("src/wuffs_bridge.c"),
        .flags = &.{"-fno-sanitize=undefined"},
    });
    module.addIncludePath(b.path("vendor/libwebp"));
    module.addCSourceFile(.{
        .file = b.path("src/webp_bridge.c"),
        .flags = &.{ "-DHAVE_CONFIG_H", "-fno-sanitize=undefined" },
    });
    module.addCSourceFiles(.{
        .root = b.path("vendor/libwebp/src"),
        .files = &webp_sources,
        .flags = &.{ "-DHAVE_CONFIG_H", "-fno-sanitize=undefined" },
    });
}

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
    // The app does not call the wrappers yet: the linker drops their code, though ELF
    // builds still carry the C objects' debug info.
    add_decoders(b, exe.root_module);
    if (target.result.os.tag == .windows) {
        exe.subsystem = .windows;
        // The resource is Explorer's icon; main.zig hands the same file to the window.
        exe.root_module.addWin32ResourceFile(.{ .file = b.path("windows/nanoview.rc") });
        exe.root_module.addAnonymousImport("nanoview.ico", .{
            .root_source_file = b.path("windows/nanoview.ico"),
        });
    }
    if (target.result.os.tag == .linux) {
        // The launcher's entry and its icon (a Wayland shell reads the window's icon from
        // them too); main.zig hands the same picture to the window for X11.
        exe.root_module.addAnonymousImport("nanoview.png", .{
            .root_source_file = b.path("linux/nanoview.png"),
        });
        b.installFile("linux/nanoview.desktop", "share/applications/nanoview.desktop");
        b.installFile("linux/nanoview.png", "share/icons/hicolor/256x256/apps/nanoview.png");
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

    const icon = b.step("icon", "Redraw the icon: macos/, windows/ and linux/ (macOS host)");
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
    add_decoders(b, tests.root_module);
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
