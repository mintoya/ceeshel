const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const args_dep = b.dependency("args", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("ceeshl", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "args", .module = args_dep.module("args") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "ceeshl",
        .root_module = mod,
    });
    b.installArtifact(exe);

    const exe_check = b.addExecutable(.{
        .name = "ceeshl",
        .root_module = exe.root_module,
    });
    const check_step = b.step("check", "Check compilation for ZLS");
    check_step.dependOn(&exe_check.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
