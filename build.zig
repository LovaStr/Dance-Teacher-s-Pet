const std = @import("std");
const builtin = @import("builtin");
const sdl3_sources = @import("third_party/sdl3_sources.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const console = b.option(bool, "console", "Keep a console window on Windows (shows logs/errors)") orelse false;

    const zigui_dep = b.dependency("zigui", .{ .target = target, .optimize = optimize });
    const zoto_dep = b.dependency("zoto", .{ .target = target, .optimize = optimize });
    // dr_libs is a plain header-only C repo (no build.zig): we only need its files.
    const drlibs_dep = b.dependency("dr_libs", .{});

    const zigui_mod = zigui_dep.module("zigui");

    // zigui's SDL3 window/event-loop runtime. The zigui package exports only the
    // pure-Zig `zigui` module, so compile `src/app.zig` from the dependency
    // directly (this is exactly what zigui's own examples do).
    // Zig 0.17 has no `@cImport`: app.zig imports SDL's headers as `sdl_c`,
    // translated from zigui's own src/sdl_c.h.
    const sdl_c = b.addTranslateC(.{
        .root_source_file = zigui_dep.path("src/sdl_c.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const app_mod = b.createModule(.{
        .root_source_file = zigui_dep.path("src/app.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "zigui", .module = zigui_mod }},
    });
    app_mod.addImport("sdl_c", sdl_c.createModule());
    linkSdl3(b, app_mod, sdl_c, target, optimize);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zigui", .module = zigui_mod },
            .{ .name = "zigui_app", .module = app_mod },
            .{ .name = "zoto", .module = zoto_dep.module("zoto") },
        },
    });

    addDecoderC(b, exe_mod, drlibs_dep);

    // Windows: embed the app icon (resource id 1, which SDL uses for the window too).
    if (target.result.os.tag == .windows) exe_mod.addWin32ResourceFile(.{ .file = b.path("assets/DanceTeachersPet.rc") });

    const exe = b.addExecutable(.{ .name = "DanceTeachersPet", .root_module = exe_mod });
    // Windows: a GUI-subsystem exe opens only the player window, no console.
    if (target.result.os.tag == .windows and !console) exe.subsystem = .windows;
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run the player (pass files/folders after --)").dependOn(&run.step);

    // Unit tests (tests/*.zig). They only need the decoder and its C shim, so
    // neither SDL3 nor zigui is required: plain `zig build test` works.
    const decoder_mod = b.createModule(.{
        .root_source_file = b.path("src/decoder.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addDecoderC(b, decoder_mod, drlibs_dep);

    const test_step = b.step("test", "Run unit tests");
    addUnitTest(b, test_step, target, optimize, "tests/decoder_test.zig", "decoder", decoder_mod);
    // Pure modules with no dependencies of their own.
    for ([_][]const u8{ "util", "transport", "waveform", "loudness" }) |name| {
        const mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
        });
        addUnitTest(b, test_step, target, optimize, b.fmt("tests/{s}_test.zig", .{name}), name, mod);
    }
}

/// Compile `test_file` with `mod` importable as `import_name`, and run it as part of `step`.
fn addUnitTest(
    b: *std.Build,
    step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_file: []const u8,
    import_name: []const u8,
    mod: *std.Build.Module,
) void {
    const t = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(test_file),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = import_name, .module = mod }},
        }),
    });
    step.dependOn(&b.addRunArtifact(t).step);
}

/// dr_mp3 / dr_flac / dr_wav implementations, compiled once in the C shim.
fn addDecoderC(b: *std.Build, m: *std.Build.Module, drlibs_dep: *std.Build.Dependency) void {
    m.addIncludePath(drlibs_dep.path("."));
    m.addCSourceFile(.{
        .file = b.path("src/lm_decode.c"),
        // Always optimize the decoders (they are very slow in Debug) and skip
        // UBSan, which the single-header decoders trip on by design.
        .flags = &.{ "-O2", "-fno-sanitize=undefined" },
    });
}

fn linkSdl3(b: *std.Build, m: *std.Build.Module, tc: *std.Build.Step.TranslateC, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    if (target.result.os.tag == .windows) {
        const sdl_dep = b.dependency("sdl3", .{});
        const lib = buildSdl3(b, sdl_dep, target, optimize);
        m.addIncludePath(sdl_dep.path("include"));
        tc.addIncludePath(sdl_dep.path("include"));
        m.addCMacro("SDL_STATIC_LIB", "1");
        m.linkLibrary(lib);
        return;
    }
    if (builtin.os.tag == .macos) {
        // Same Homebrew layout zigui's own build.zig assumes.
        const brew = if (builtin.cpu.arch == .aarch64) "/opt/homebrew/opt/sdl3" else "/usr/local/opt/sdl3";
        m.addIncludePath(.{ .cwd_relative = brew ++ "/include" });
        m.addLibraryPath(.{ .cwd_relative = brew ++ "/lib" });
        m.addRPath(.{ .cwd_relative = brew ++ "/lib" });
        tc.addIncludePath(.{ .cwd_relative = brew ++ "/include" });
    }
    m.linkSystemLibrary("SDL3", .{});
}

/// SDL3 compiled from the `sdl3` dependency as a static library (Windows only),
/// so the exe needs no SDL3.dll. The source list is in third_party/sdl3_sources.zig.
fn buildSdl3(
    b: *std.Build,
    sdl_dep: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // First, so our winsdkver.h shadows MinGW's (see the header for why).
    mod.addIncludePath(b.path("third_party/sdl3_shim"));
    mod.addIncludePath(sdl_dep.path("include"));
    mod.addIncludePath(sdl_dep.path("include/build_config"));
    mod.addIncludePath(sdl_dep.path("src"));
    mod.addIncludePath(sdl_dep.path("src/video/khronos"));
    mod.addCSourceFiles(.{
        .root = sdl_dep.path("."),
        .files = &sdl3_sources.files,
        .flags = &.{ "-DSDL_STATIC_LIB=1", "-fno-sanitize=undefined" },
    });
    mod.addCSourceFile(.{
        .file = b.path("third_party/sdl3_shim/stub_gameinput.c"),
        .flags = &.{ "-DSDL_STATIC_LIB=1", "-fno-sanitize=undefined" },
    });
    for ([_][]const u8{
        "user32",   "gdi32",    "winmm",    "imm32", "ole32",    "oleaut32",
        "version",  "uuid",     "advapi32", "setupapi", "shell32", "cfgmgr32",
    }) |name| mod.linkSystemLibrary(name, .{});
    return b.addLibrary(.{ .name = "SDL3", .linkage = .static, .root_module = mod });
}
