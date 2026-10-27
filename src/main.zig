const std = @import("std");
const args = @import("args");
const Ast = @import("ast.zig");
const Pool = @import("pool.zig");
const Lower = @import("lower.zig");

pub fn println(comptime fmt: []const u8, args_: anytype) void {
    return std.debug.print(fmt ++ "\n", args_);
}

const Options = struct {
    help: bool = false,
    ast: bool = false,
    // stdin: bool = false,
    out: ?[]const u8 = null,

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

    if (parsed.positionals.len != 1) {
        println("expected one input file; use --help for usage", .{});
        return 1;
    }

    var state = try Ast.AstState.init(init.gpa);
    defer state.deinit();
    const entry = try Ast.Ast.parse(init.io, .{ .filename = parsed.positionals[0] }, &state);
    if (parsed.options.ast) {
        println("{f}", .{Ast.AstCtx{ .state = &state, .ast = state.asts.items[entry] }});
        return 0;
    }

    var pool = try Pool.init(init.gpa);
    defer pool.deinit();
    return 0;
}
