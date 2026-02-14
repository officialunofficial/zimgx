const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    addVipsDeps(exe_mod);

    const exe = b.addExecutable(.{
        .name = "zimgx",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the zimgx server");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const test_step = b.step("test", "Run unit tests");

    // Modules tested as standalone test roots.  Modules with cross-directory
    // imports (http/response, transform/pipeline) are excluded here and
    // tested via main.zig's test block instead, avoiding Zig's
    // one-file-per-module constraint.
    const test_modules = [_][]const u8{
        "src/main.zig",
        "src/transform/params.zig",
        "src/transform/negotiate.zig",
        "src/router.zig",
        "src/config.zig",
        "src/http/errors.zig",
        "src/cache/cache.zig",
        "src/cache/memory.zig",
        "src/cache/noop.zig",
        "src/cache/tiered.zig",
        "src/s3/signing.zig",
        "src/s3/client.zig",
        "src/vips/bindings.zig",
        "src/origin/fetcher.zig",
        "src/origin/source.zig",
        "src/allocator.zig",
        "src/server.zig",
    };

    // Benchmark executable (shares src/ module root with main exe)
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench_main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    addVipsDeps(bench_mod);

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = bench_mod,
    });
    b.installArtifact(bench_exe);

    const bench_run = b.addRunArtifact(bench_exe);
    bench_run.step.dependOn(b.getInstallStep());
    const bench_step = b.step("bench", "Run pipeline benchmarks");
    bench_step.dependOn(&bench_run.step);

    for (test_modules) |mod| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path(mod),
            .target = target,
            .optimize = optimize,
        });
        addVipsDeps(test_mod);

        const t = b.addTest(.{
            .root_module = test_mod,
        });
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
    }
}

fn addVipsDeps(mod: *std.Build.Module) void {
    mod.link_libc = true;
    mod.linkSystemLibrary("vips", .{});

    // macOS Homebrew: headers and libraries are not in the default
    // search path, so we add the Cellar locations explicitly.
    if (@import("builtin").os.tag == .macos) {
        mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/Cellar/vips/8.18.0_2/include" });
        mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/Cellar/glib/2.86.3/include/glib-2.0" });
        mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/Cellar/glib/2.86.3/lib/glib-2.0/include" });
        mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/Cellar/vips/8.18.0_2/lib" });
        mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/Cellar/glib/2.86.3/lib" });
    }
}
