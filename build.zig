const std = @import("std");

const system_libraries = [_][]const u8{
    "user32",
    "gdi32",
    "shell32",
    "dwmapi",
    "ole32",
    "pdh",
    "dxgi",
    "iphlpapi",
    "wtsapi32",
};

fn createAppModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    for (system_libraries) |library| {
        mod.linkSystemLibrary(library, .{});
    }
    return mod;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .os_tag = .windows, .abi = .gnu } });
    const optimize: std.builtin.OptimizeMode = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse switch (b.release_mode) {
        .off, .any, .safe => .ReleaseSafe,
        .fast => .ReleaseFast,
        .small => .ReleaseSmall,
    };

    const app = b.addExecutable(.{
        .name = "TaskbarPerfZig",
        .root_module = createAppModule(b, target, optimize),
    });
    app.subsystem = .Windows;
    app.win32_manifest = b.path("app.manifest");
    b.installArtifact(app);

    const run = b.addRunArtifact(app);
    b.step("run", "Open the monitor").dependOn(&run.step);

    const unit_tests = b.addTest(.{
        .root_module = createAppModule(b, target, optimize),
    });
    const run_tests = b.addRunArtifact(unit_tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);

    const smoke_mod = b.createModule(.{
        .root_source_file = b.path("smoke.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    smoke_mod.linkSystemLibrary("user32", .{});
    smoke_mod.linkSystemLibrary("kernel32", .{});
    const smoke_exe = b.addExecutable(.{
        .name = "smoke",
        .root_module = smoke_mod,
    });
    const run_smoke = b.addRunArtifact(smoke_exe);
    run_smoke.addFileArg(app.getEmittedBin());
    b.step("smoke", "Launch and cleanly close TaskbarPerfZig").dependOn(&run_smoke.step);
}
