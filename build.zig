//! Builds libhddvd_plugin.{dylib,dll,so}, a VLC 3.0 plugin.
//!
//!   zig build                                   # native (macOS arm64 here)
//!   zig build -Dtarget=x86_64-windows-gnu       # Windows x64 DLL
//!   zig build -Dtarget=x86_64-macos             # Intel Mac
//!   zig build -Dvlc-sdk=/usr                    # Linux, with the distribution's libvlccore-dev
//!                                               # (and libasound2-dev; -Dalsa-include for a cross build)
//!
//! Plugin headers come from the VLC Windows SDK (they are platform-neutral C), or from libvlccore-dev on Linux.
//! libvlccore comes from the SDK's import library on Windows, from VLC.app on macOS and from the system on Linux
//! (-Dvlc-lib overrides all three).

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // ReleaseSafe by default: a Debug plugin is too slow to composite and mix Advanced Content in real time.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode: debug, safe, fast or small (default: safe)") orelse .safe;

    const vlc_sdk = b.option([]const u8, "vlc-sdk", "VLC SDK dir (with include/vlc/plugins)") orelse
        "../vlc-sdk/vlc-3.0.24/sdk";
    const vlc_app = b.option([]const u8, "vlc-app", "VLC.app (macOS libvlccore)") orelse
        "/Applications/VLC.app";
    const vlc_lib = b.option([]const u8, "vlc-lib", "Folder with libvlccore (default: from vlc-sdk, vlc-app or the system)");
    const alsa_include = b.option([]const u8, "alsa-include", "Linux: folder holding alsa/asoundlib.h (default: the system's)");

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

    // stb_image and stb_truetype (build.zig.zon), for images and fonts: @import("stb"), plus src/stb.c.
    const stb_dir = b.dependency("stb", .{}).path("");
    const stb_c = b.addTranslateC(.{
        .root_source_file = b.path("src/stb.h"),
        .target = target,
        .optimize = optimize,
    });
    stb_c.addIncludePath(stb_dir);

    // QuickJS-ng (build.zig.zon) for HDi scripts, patched for the HD DVD script profile: @import("quickjs").
    const qjs = QuickJs.init(b);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/hddvd.zig"),
        .target = target,
        .optimize = optimize,
        // Release builds carry no debug info (it holds the build machine's paths); Debug keeps it.
        .strip = optimize != .debug,
        .link_libc = true,
        .link_libcpp = true, // RtAudio
        .imports = &.{
            .{ .name = "vlc", .module = vlc_c.createModule() },
            .{ .name = "stb", .module = stb_c.createModule() },
            .{ .name = "quickjs", .module = qjs.translate(target, optimize) },
        },
    });
    addStb(b, mod, stb_dir);
    qjs.addTo(mod, target, false);
    addRtAudio(b, mod, target, alsa_include);

    mod.addIncludePath(b.path("src"));
    mod.addIncludePath(vlc_include);
    mod.addCSourceFiles(.{ .files = &.{ "src/module.c", "src/nav_glue.c", "src/spu_glue.c", "src/codec_glue.c" }, .flags = &common_flags });

    switch (target.result.os.tag) {
        .windows => {
            mod.addObjectFile(.{ .cwd_relative = b.fmt("{s}/libvlccore.lib", .{vlc_lib orelse b.fmt("{s}/lib", .{vlc_sdk})}) });
            mod.linkSystemLibrary("ws2_32", .{});
        },
        else => {
            const dir = vlc_lib orelse if (target.result.os.tag == .macos) b.fmt("{s}/Contents/MacOS/lib", .{vlc_app}) else null;
            if (dir) |d| mod.addLibraryPath(.{ .cwd_relative = d });
            mod.linkSystemLibrary("vlccore", .{});
        },
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
    const stb_host = b.addTranslateC(.{
        .root_source_file = b.path("src/stb.h"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    stb_host.addIncludePath(stb_dir);
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true, // spu.zig allocates with std.heap.c_allocator, like the plugin
        .imports = &.{
            .{ .name = "stb", .module = stb_host.createModule() },
            .{ .name = "quickjs", .module = qjs.translate(b.graph.host, optimize) },
        },
    });
    addStb(b, test_mod, stb_dir);
    qjs.addTo(test_mod, b.graph.host, true);
    const filter = b.option([]const u8, "test-filter", "Run only the tests whose name contains this");
    const tests = b.addTest(.{ .root_module = test_mod, .filters = if (filter) |f| b.dupeStrings(&.{f}) else &.{} });
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(tests).step);
}

fn addStb(b: *std.Build, m: *std.Build.Module, stb_dir: std.Build.LazyPath) void {
    m.addIncludePath(stb_dir);
    m.addCSourceFiles(.{ .files = &.{"src/stb.c"}, .flags = &.{ "-std=gnu11", "-fno-sanitize=undefined" } });
    _ = b;
}

/// RtAudio (build.zig.zon) and src/fx_glue.cpp: an audio output for effect sounds while VLC is paused
/// (adv/fxout.zig), on CoreAudio, WASAPI or ALSA.
fn addRtAudio(b: *std.Build, m: *std.Build.Module, target: std.Build.ResolvedTarget, alsa_include: ?[]const u8) void {
    const dir = b.dependency("rtaudio", .{}).path("");
    const api: []const u8 = switch (target.result.os.tag) {
        .macos => "-D__MACOSX_CORE__",
        .windows => "-D__WINDOWS_WASAPI__",
        else => "-D__LINUX_ALSA__",
    };
    const flags: []const []const u8 = &.{ "-std=c++17", "-fno-sanitize=undefined", "-fvisibility=hidden", "-w", api };
    m.addIncludePath(dir);
    m.addCSourceFiles(.{ .root = dir, .files = &.{"RtAudio.cpp"}, .flags = flags });
    m.addCSourceFiles(.{ .files = &.{"src/fx_glue.cpp"}, .flags = flags });
    switch (target.result.os.tag) {
        .macos => {
            addMacosFrameworkPath(b, m, target);
            m.linkFramework("CoreAudio", .{});
            m.linkFramework("CoreFoundation", .{});
        },
        .windows => for ([_][]const u8{ "ole32", "ksuser", "mfplat", "mfuuid", "wmcodecdspuuid", "winmm" }) |l| m.linkSystemLibrary(l, .{}),
        else => {
            if (alsa_include) |d| m.addSystemIncludePath(.{ .cwd_relative = d });
            m.linkSystemLibrary("asound", .{});
        },
    }
}

/// macOS framework search path from the system SDK, needed for RtAudio's CoreAudio/CoreFoundation
/// `-framework` link inputs (and `<CoreAudio/AudioHardware.h>` includes, which are not in Zig's
/// bundled macOS headers). Zig only resolves this itself through its native-target detection
/// (`NativePaths`, via `xcrun`); with an explicit -Dtarget it has no framework search paths at
/// all, so even a native-arch build like -Dtarget=aarch64-macos on a Mac fails to find frameworks.
fn addMacosFrameworkPath(b: *std.Build, m: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (b.graph.host.result.os.tag != .macos) return;
    const sdk: ?[]const u8 = sdk: {
        if (b.graph.environ_map.get("SDKROOT")) |p| if (p.len > 0) break :sdk p;
        if (!std.zig.system.darwin.isSdkInstalled(b.graph.arena, b.graph.io)) break :sdk null;
        break :sdk std.zig.system.darwin.getSdk(b.graph.arena, b.graph.io, &target.result);
    };
    if (sdk) |s| {
        // The SDK path becomes include/link flags, resolved from state the configuration cache
        // cannot track (xcrun, env), so the resolved configuration must not be reused.
        b.graph.poisonCache();
        m.addSystemFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{s}) });
        // Framework stubs re-export libraries like libobjc.A.dylib, resolved in the SDK's usr/lib
        // (what NativePaths does for native builds; SIP no longer pastes dylibs into /usr/lib).
        m.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{s}) });
    }
}

const QuickJs = struct {
    b: *std.Build,
    dir: std.Build.LazyPath,
    /// quickjs.c with the HD DVD profile (src/qjs_patch.zig).
    patched: std.Build.LazyPath,

    fn init(b: *std.Build) QuickJs {
        const dep = b.dependency("quickjs", .{});
        const tool = b.addExecutable(.{
            .name = "qjs_patch",
            .root_module = b.createModule(.{ .root_source_file = b.path("src/qjs_patch.zig"), .target = b.graph.host }),
        });
        const run = b.addRunArtifact(tool);
        run.addFileArg(dep.path("quickjs.c"));
        return .{ .b = b, .dir = dep.path(""), .patched = run.addOutputFileArg("quickjs.c") };
    }

    fn translate(q: QuickJs, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
        const t = q.b.addTranslateC(.{
            .root_source_file = q.dir.path(q.b, "quickjs.h"),
            .target = target,
            .optimize = optimize,
        });
        return t.createModule();
    }

    /// Compiles QuickJS-ng into `m`. Its asserts stay on in the tests (they catch leaked values when a runtime
    /// is freed) and are off in the plugin.
    fn addTo(q: QuickJs, m: *std.Build.Module, target: std.Build.ResolvedTarget, asserts: bool) void {
        const b = q.b;
        var flags: std.ArrayList([]const u8) = .empty;
        flags.appendSlice(b.allocator, &.{ "-std=gnu11", "-funsigned-char", "-fno-sanitize=undefined", "-w", "-D_GNU_SOURCE" }) catch @panic("OOM");
        if (!asserts) flags.append(b.allocator, "-DNDEBUG") catch @panic("OOM");
        if (target.result.os.tag == .windows) flags.appendSlice(b.allocator, &.{ "-DWIN32_LEAN_AND_MEAN", "-D_WIN32_WINNT=0x0601" }) catch @panic("OOM");
        m.addIncludePath(q.dir);
        m.addCSourceFile(.{ .file = q.patched, .flags = flags.items });
        m.addCSourceFiles(.{ .root = q.dir, .files = &.{ "dtoa.c", "libregexp.c", "libunicode.c" }, .flags = flags.items });
    }
};
