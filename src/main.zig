const std = @import("std");
const args = @import("args");
const Testing = @import("testing.zig");
const Ast = @import("ast.zig");
const Lower = @import("lower.zig");

test {
    _ = Testing;
    _ = @import("lower.zig");
}

pub fn println(comptime fmt: []const u8, args_: anytype) void {
    return std.debug.print(fmt ++ "\n", args_);
}

const Options = struct {
    help: bool = false,
    ast: bool = false,
    // stdin: bool = false,
    out: ?[]const u8 = null,
    testdir: ?[]const u8 = null,

    pub const shorthands = .{
        .h = "help",
        .o = "out",
    };

    pub const meta = .{
        .usage_summary = "...[options] [file]",
        .option_docs = .{
            .help = "print this help and exit",
            .ast = "print the tree instead of evaluating",
            .out = "write output to this file",
            .testdir = "run tests from directory",
            // .stdin = "parse from stdin",
        },
    };
};

pub fn main(init: std.process.Init) !u8 {
    const parsed = args.parseForCurrentProcess(Options, init, .print) catch return 1;
    defer parsed.deinit();

    if (parsed.options.help) {
        var buffer: [1024]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(init.io, &buffer);
        defer stdout.interface.flush() catch {};
        try args.printHelp(Options, parsed.executable_name orelse "ceeshel", &stdout.interface);
        return 0;
    }

    if (parsed.options.testdir) |directory| {
        return Testing.run(init.io, init.gpa, directory) catch |err| {
            println("cannot run tests in {s}: {s}", .{ directory, @errorName(err) });
            return 1;
        };
    }

    if (parsed.positionals.len != 1) {
        println("expected one input file; use --help for usage", .{});
        return 1;
    }

    var sema = try Lower.init(init.gpa);
    defer sema.deinit();

    const entry = sema.parseFile(init.io, parsed.positionals[0]) catch |err| {
        if (err != error.SyntaxError) return err;
        println("PARSE: syntax error at {f}", .{Ast.SrcFmt{ .state = &sema.astState, .src = sema.astState.syntax_error.? }});
        return 1;
    };
    if (parsed.options.ast) {
        println("{f}", .{Ast.AstCtx{ .state = &sema.astState, .ast = sema.astState.asts.items[entry] }});
        return 0;
    }

    if (true)
        return error.UnImplemented;
    return 0;
}
