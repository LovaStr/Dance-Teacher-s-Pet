const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdl3_prefix = b.option(
        []const u8,
        "sdl3-prefix",
        "SDL3 development prefix containing include/ and lib/ (needed on Windows; e.g. SDL3-devel\\x86_64-w64-mingw32)",
    );
    const sdl3_dll = b.option(
        []const u8,
        "sdl3-dll",
        "Path to SDL3.dll to copy next to the executable (Windows)",
    );

    const console = b.option(bool, "console", "Keep a console window on Windows (shows logs/errors)") orelse false;

    const zigui_dep = b.dependency("zigui", .{ .target = target, .optimize = optimize });
    const zoto_dep = b.dependency("zoto", .{ .target = target, .optimize = optimize });
    // dr_libs is a plain header-only C repo (no build.zig): we only need its files.
    const drlibs_dep = b.dependency("dr_libs", .{});

    const zigui_mod = zigui_dep.module("zigui");

    // zigui's SDL3 window/event-loop runtime. The zigui package exports only the
    // pure-Zig `zigui` module, so compile `src/app.zig` from the dependency
    // directly (this is exactly what zigui's own examples do).
    const app_mod = b.createModule(.{
        .root_source_file = zigui_dep.path("src/app.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "zigui", .module = zigui_mod }},
    });
    linkSdl3(b, app_mod, target.result.os.tag, sdl3_prefix);

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
    if (target.result.os.tag == .windows) exe_mod.addWin32ResourceFile(.{ .file = b.path("assets/lmp3.rc") });

    const exe = b.addExecutable(.{ .name = "lmp3", .root_module = exe_mod });
    // Windows: a GUI-subsystem exe opens only the player window, no console.
    if (target.result.os.tag == .windows and !console) exe.subsystem = .windows;
    b.installArtifact(exe);

    if (sdl3_dll) |dll| {
        b.getInstallStep().dependOn(&b.addInstallBinFile(.{ .cwd_relative = dll }, "SDL3.dll").step);
    }

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
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
    for ([_][]const u8{ "util", "transport" }) |name| {
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

fn linkSdl3(b: *std.Build, m: *std.Build.Module, os: std.Target.Os.Tag, prefix: ?[]const u8) void {
    if (prefix) |p| {
        m.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ p, "include" }) });
        m.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ p, "lib" }) });
        if (os == .windows) {
            // The MinGW SDL3 package ships an import library named libSDL3.dll.a,
            // which -lSDL3 does not find; link it directly.
            m.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ p, "lib", "libSDL3.dll.a" }) });
            return;
        }
    } else if (builtin.os.tag == .macos) {
        // Same Homebrew layout zigui's own build.zig assumes.
        const brew = if (builtin.cpu.arch == .aarch64) "/opt/homebrew/opt/sdl3" else "/usr/local/opt/sdl3";
        m.addIncludePath(.{ .cwd_relative = brew ++ "/include" });
        m.addLibraryPath(.{ .cwd_relative = brew ++ "/lib" });
        m.addRPath(.{ .cwd_relative = brew ++ "/lib" });
    }
    m.linkSystemLibrary("SDL3", .{});
}
