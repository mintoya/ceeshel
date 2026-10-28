const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const args_dep = b.dependency("args", .{
        .target = target,
        .optimize = optimize,
    });

    const ts_dep = b.dependency("tree_sitter", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("ceeshl", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "args", .module = args_dep.module("args") },
            .{ .name = "tree-sitter", .module = ts_dep.module("tree_sitter") },
        },
    });

    const generate = b.addSystemCommand(&.{ "tree-sitter", "generate" });
    generate.setCwd(b.path("grammar"));
    generate.addFileInput(b.path("grammar/grammar.js"));
    mod.addCSourceFile(.{ .file = b.path("grammar/src/parser.c") });
    mod.addIncludePath(b.path("grammar/src"));

    const exe = b.addExecutable(.{
        .name = "ceeshl",
        .root_module = mod,
    });
    exe.step.dependOn(&generate.step);
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
    mod_tests.step.dependOn(&generate.step);
    const run_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
    // every test/*.cshl: its last expression must be true
    const run_cshl = b.addRunArtifact(exe);
    run_cshl.addArgs(&.{ "--tests", "test" });
    run_cshl.has_side_effects = true;
    test_step.dependOn(&run_cshl.step);
}
