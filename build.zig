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

    const wasm_module = b.createModule(.{
        .root_source_file = b.path("wasm.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
        .optimize = .ReleaseFast,
        .single_threaded = true,
        .strip = true,
    });
    const wasm = b.addExecutable(.{ .name = "solver", .root_module = wasm_module });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.export_memory = true;
    wasm.import_memory = true;
    wasm.stack_size = 2 * 1024 * 1024;
    wasm.initial_memory = 4 * 1024 * 1024;
    wasm.max_memory = 4095 * 1024 * 1024;
    const wasm_step = b.step("wasm", "Build the WebAssembly solver");
    wasm_step.dependOn(&b.addInstallFile(wasm.getEmittedBin(), "web/solver.wasm").step);
    const web = b.step("web", "Build the static browser visualizer and WebAssembly solver");
    web.dependOn(wasm_step);
    for ([_][]const u8{ "index.html", "script.js", "sokoban-maps-60.txt" }) |asset| {
        web.dependOn(&b.addInstallFile(b.path(asset), b.fmt("web/{s}", .{asset})).step);
    }

    const clean = b.step("clean", "delete .zig-cache and zig-out");
    clean.dependOn(&b.addSystemCommand(&.{ "rm", "-rf", ".zig-cache", "zig-out" }).step);
}
