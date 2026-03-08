const std = @import("std");
const zon = @import("build.zig.zon");

const name = "sokoban-solver";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);

    const exe_module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    exe_module.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = exe_module,
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "run the application");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const test_module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = .Debug,
    });
    test_module.addOptions("build_options", options);

    const exe_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "run tests");
    test_step.dependOn(&run_exe_tests.step);

    const clean = b.step("clean", "delete .zig-cache and zig-out");
    clean.dependOn(&b.addSystemCommand(&.{ "rm", "-rf", ".zig-cache", "zig-out" }).step);
}
