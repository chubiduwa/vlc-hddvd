//! Builds libhddvd_plugin.{dylib,dll}, a VLC 3.0 plugin.
//!
//!   zig build                                   # native (macOS arm64 here)
//!   zig build -Dtarget=x86_64-windows-gnu       # Windows x64 DLL
//!   zig build -Dtarget=x86_64-macos             # Intel Mac
//!
//! Plugin headers come from the VLC Windows SDK (they are platform-neutral C).
//! libvlccore comes from the SDK's import library on Windows and from VLC.app on macOS.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const vlc_sdk = b.option([]const u8, "vlc-sdk", "VLC SDK dir (with include/vlc/plugins)") orelse
        "../vlc-sdk/vlc-3.0.24/sdk";
    const vlc_app = b.option([]const u8, "vlc-app", "VLC.app (macOS libvlccore)") orelse
        "/Applications/VLC.app";

    const vlc_include: std.Build.LazyPath = .{ .cwd_relative = b.fmt("{s}/include/vlc/plugins", .{vlc_sdk}) };
    // What `pkg-config --cflags vlc-plugin` gives, plus MODULE_STRING (out-of-tree builds must set it).
    const defines = [_][2][]const u8{
        .{ "__PLUGIN__", "1" },
        .{ "MODULE_STRING", "\"hddvd\"" },
        .{ "_FILE_OFFSET_BITS", "64" },
        .{ "_REENTRANT", "1" },
        .{ "_THREAD_SAFE", "1" },
    };
    var common_flags: [defines.len + 1][]const u8 = undefined;
    common_flags[0] = "-std=gnu11";
    for (defines, 1..) |d, i| common_flags[i] = b.fmt("-D{s}={s}", .{ d[0], d[1] });

    // VLC plugin API for Zig: src/vlc.h through translate-c, imported as @import("vlc").
    const vlc_c = b.addTranslateC(.{
        .root_source_file = b.path("src/vlc.h"),
        .target = target,
        .optimize = optimize,
    });
    vlc_c.addIncludePath(b.path("src"));
    vlc_c.addIncludePath(vlc_include);
    for (defines) |d| vlc_c.defineCMacro(d[0], d[1]);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/hddvd.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "vlc", .module = vlc_c.createModule() }},
    });

    mod.addIncludePath(b.path("src"));
    mod.addIncludePath(vlc_include);
    mod.addCSourceFiles(.{ .files = &.{ "src/module.c", "src/nav_glue.c", "src/spu_glue.c" }, .flags = &common_flags });

    switch (target.result.os.tag) {
        .windows => {
            mod.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libvlccore.lib", .{vlc_sdk}) });
            mod.linkSystemLibrary("ws2_32", .{});
        },
        .macos => {
            mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/Contents/MacOS/lib", .{vlc_app}) });
            mod.linkSystemLibrary("vlccore", .{});
        },
        else => mod.linkSystemLibrary("vlccore", .{}),
    }

    const lib = b.addLibrary(.{
        // VLC only loads lib*_plugin.{dll,dylib,so}; Zig adds the "lib" prefix itself except on Windows.
        .name = if (target.result.os.tag == .windows) "libhddvd_plugin" else "hddvd_plugin",
        .linkage = .dynamic,
        .root_module = mod,
    });
    b.installArtifact(lib);

    // `zig build test`: unit tests of the modules that do not depend on VLC, built for and run on the host
    // whatever -Dtarget is. Test code is only compiled here, never into the plugin.
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    }) });
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(tests).step);
}
