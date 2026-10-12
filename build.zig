const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("ceeshel", .{
        .root_source_file = b.path("src/types.zig"),
        .target = target,
    });

    const args_dep = b.dependency("args", .{
        .target = target,
        .optimize = optimize,
    });
    const treesitter_dep = b.dependency("treesitter", .{
        .target = target,
        .optimize = optimize,
    });

    const language_mod = b.createModule(.{
        .root_source_file = b.path("tree-sitter/native/language.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "treesitter", .module = treesitter_dep.module("treesitter") }},
    });

    const generate_c = b.addSystemCommand(&.{ "tree-sitter", "generate", "--abi", "14", "--output", "tree-sitter/src" });
    generate_c.setCwd(b.path("."));
    const generator = b.addExecutable(.{
        .name = "generate-native-parser",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/generate_native_parser.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const generate_native = b.addRunArtifact(generator);
    generate_native.setCwd(b.path("."));
    generate_native.addArgs(&.{ "tree-sitter/src/parser.c", "tree-sitter/native/language.zig" });
    generate_native.has_side_effects = true;
    generate_native.step.dependOn(&generate_c.step);
    const format_native = b.addSystemCommand(&.{ b.graph.zig_exe, "fmt", "tree-sitter/native/language.zig" });
    format_native.setCwd(b.path("."));
    format_native.step.dependOn(&generate_native.step);
    const generate_step = b.step("generate", "Regenerate the editor parser and native Zig language tables");
    generate_step.dependOn(&format_native.step);
    const exe = b.addExecutable(.{
        .name = "ceeshel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ceeshel", .module = mod },
                .{ .name = "args", .module = args_dep.module("args") },
                .{ .name = "treesitter", .module = treesitter_dep.module("treesitter") },
                .{ .name = "cshl_language", .module = language_mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const ast_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ast.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_ast_tests = b.addRunArtifact(ast_tests);

    const parser_mod = b.createModule(.{
        .root_source_file = b.path("src/ts_adapt.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "treesitter", .module = treesitter_dep.module("treesitter") },
            .{ .name = "cshl_language", .module = language_mod },
        },
    });
    const parser_tests = b.addTest(.{ .root_module = parser_mod });
    const run_parser_tests = b.addRunArtifact(parser_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_ast_tests.step);
    test_step.dependOn(&run_parser_tests.step);
}
