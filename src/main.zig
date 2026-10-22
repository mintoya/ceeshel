const std = @import("std");
const args = @import("args");
const Tokenizer = @import("tokinize.zig");
const Ast = @import("ast.zig");

pub fn println(comptime fmt: []const u8, args_: anytype) void {
    return std.debug.print(fmt ++ "\n", args_);
}

const Options = struct {
    help: bool = false,
    out: ?[]const u8 = null,

    pub const shorthands = .{
        .h = "help",
        .o = "out",
    };

    pub const meta = .{
        .usage_summary = "...[options] [file]",
        .option_docs = .{
            .help = "print this help and exit",
            .out = "write output to this file",
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

    var state = try Ast.parse_state.init(init.gpa);
    const entry = try Ast.Ast.parse(init.io, .{ .filename = parsed.positionals[0] }, &state);
    _ = entry;
    return 0;
}

