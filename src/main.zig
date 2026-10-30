const std = @import("std");
const args = @import("args");
const Ast = @import("ast.zig");
const Pool = @import("pool.zig");
const Lower = @import("lower.zig");
const Interp = @import("interp.zig");
const EmitC = @import("emit_c.zig");

pub fn println(comptime fmt: []const u8, args_: anytype) void {
    return std.debug.print(fmt ++ "\n", args_);
}

const Options = struct {
    help: bool = false,
    ast: bool = false,
    ir: bool = false,
    tests: ?[]const u8 = null,
    noc: bool = false,
    nolines: bool = false,
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
            .ir = "print the lowered IR",
            .tests = "run every .cshl file in the directory [file] as a test",
            .noc = "with --tests: don't compile the C (with tcc)",
            .nolines = "with -o: no #line directives pointing back at the source",
            .out = "write the program as C to this file",
            // .stdin = "parse from stdin",
        },
    };
};

// one file through every stage; owns everything it allocates
const Unit = struct {
    arena: std.heap.ArenaAllocator,
    state: Ast.AstState,
    pool: Pool,
    sema: Lower,
    entry: Ast.astpos = 0,

    fn init(unit: *Unit, gpa: std.mem.Allocator, io: std.Io) !void {
        unit.arena = .init(gpa);
        unit.state = try .init(gpa);
        unit.pool = try .init(gpa);
        unit.sema = try .init(unit.arena.allocator(), io, &unit.state, &unit.pool);
    }
    fn deinit(unit: *Unit) void {
        unit.pool.deinit();
        unit.state.deinit();
        unit.arena.deinit();
    }
    fn parse(unit: *Unit, io: std.Io, path: [:0]const u8) !void {
        unit.entry = try Ast.Ast.parse(io, .{ .filename = path }, &unit.state);
    }
    // the error the last stage failed with, as file:line:col: CODE: detail
    fn describe(unit: *Unit, w: *std.Io.Writer) !void {
        const err = unit.sema.err.?;
        try w.print("{f}", .{unit.sema.fmtAt(err.at)});
        try w.print("{s}: {s}", .{ err.code, err.detail });
    }
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

    if (parsed.options.tests) |testdir| return runTests(init.gpa, init.io, testdir, !parsed.options.noc);
    if (parsed.positionals.len != 1) {
        println("expected one input file; use --help for usage", .{});
        return 1;
    }

    var unit: Unit = undefined;
    try unit.init(init.gpa, init.io);
    defer unit.deinit();
    unit.parse(init.io, parsed.positionals[0]) catch |e| {
        if (e != error.SyntaxError) return e;
        println("PARSE: syntax error at {f}", .{Ast.SrcFmt{ .state = &unit.state, .src = unit.state.syntax_error.? }});
        return 1;
    };
    if (parsed.options.ast) {
        println("{f}", .{Ast.AstCtx{ .state = &unit.state, .ast = unit.state.asts.items[unit.entry] }});
        return 0;
    }

    var out: std.Io.Writer.Allocating = .init(unit.arena.allocator());
    const main_fn = unit.sema.lowerProgram(unit.entry) catch |e| return report(&unit, &out, e);
    if (parsed.options.ir) {
        try unit.sema.dump(&out.writer);
        println("{s}", .{out.written()});
        return 0;
    }
    if (parsed.options.out) |path| {
        try writeC(&unit, init.io, path, !parsed.options.nolines);
        return 0;
    }
    var it = Interp.init(&unit.sema) catch |e| return report(&unit, &out, e);
    const result = it.run(main_fn, &.{}) catch |e| return report(&unit, &out, e);
    try out.writer.print("{f}", .{unit.sema.fmtValue(result)});
    println("{s}", .{out.written()});
    return 0;
}

fn writeC(unit: *Unit, io: std.Io, path: []const u8, lines: bool) !void {
    var c: std.Io.Writer.Allocating = .init(unit.arena.allocator());
    try EmitC.emit(&unit.sema, &c.writer, lines);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = c.written() });
}

fn report(unit: *Unit, out: *std.Io.Writer.Allocating, e: anyerror) !u8 {
    if (e != error.Lower) return e;
    try unit.describe(&out.writer);
    println("{s}", .{out.written()});
    return 1;
}

// Every .cshl file directly in `dir` is a test. A first line
// `// error: CODE` expects lowering to fail with CODE; otherwise the last
// expression must be a true bool.
fn runTests(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8, compile: bool) !u8 {
    try std.Io.Dir.cwd().createDirPath(io, c_dir);
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".cshl")) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    var failed: usize = 0;
    var skipped: usize = 0;
    for (names.items) |name| {
        const path = try std.fs.path.joinZ(gpa, &.{ dir_path, name });
        defer gpa.free(path);
        var unit: Unit = undefined;
        try unit.init(gpa, io);
        defer unit.deinit();
        var out: std.Io.Writer.Allocating = .init(unit.arena.allocator());
        switch (try runTest(&unit, io, path, name, compile, &out.writer)) {
            .pass => {},
            .skip => skipped += 1,
            .fail => |p| {
                failed += 1;
                println("FAIL {s}: {s}", .{ name, p });
            },
        }
    }
    println("{d} passed, {d} failed, {d} skipped (compiled only, without C)", .{ names.items.len - failed - skipped, failed, skipped });
    return if (failed == 0) 0 else 1;
}

const Outcome = union(enum) { pass, skip, fail: []const u8 };
const c_dir = ".zig-cache/ceeshel-c";

// Interpreted, then compiled: both must give true. `// compiled only` on
// the first line skips interpreting, `// error: CODE` expects that error.
fn runTest(unit: *Unit, io: std.Io, path: [:0]const u8, name: []const u8, compile: bool, w: *std.Io.Writer) !Outcome {
    const a = unit.arena.allocator();
    const parsed = unit.parse(io, path);
    const content = unit.state.files.items[unit.state.files.items.len - 1].content.file;
    const first = content[0 .. std.mem.indexOfScalar(u8, content, '\n') orelse content.len];
    const prefix = "// error: ";
    const expected: ?[]const u8 = if (std.mem.startsWith(u8, first, prefix)) std.mem.trim(u8, first[prefix.len..], " \r") else null;
    parsed catch |e| {
        if (e != error.SyntaxError) return .{ .fail = try std.fmt.allocPrint(a, "{t}", .{e}) };
        if (expected) |code| if (std.mem.eql(u8, code, "PARSE")) return .pass;
        return .{ .fail = try std.fmt.allocPrint(a, "PARSE: syntax error at {f}", .{Ast.SrcFmt{ .state = &unit.state, .src = unit.state.syntax_error.? }}) };
    };
    const compiled_only = std.mem.startsWith(u8, first, "// compiled only");
    if (compiled_only and !compile) return .skip;

    const outcome: anyerror!Pool.Value = run: {
        const main_fn = unit.sema.lowerProgram(unit.entry) catch |e| break :run e;
        if (compiled_only) break :run unit.sema.vBool(true);
        var it = Interp.init(&unit.sema) catch |e| break :run e;
        break :run it.run(main_fn, &.{});
    };
    const result = outcome catch |e| {
        if (e != error.Lower) return e;
        if (expected) |code| if (std.mem.eql(u8, code, unit.sema.err.?.code)) return .pass;
        try unit.describe(w);
        return .{ .fail = w.buffered() };
    };
    if (expected) |code| return .{ .fail = try std.fmt.allocPrint(a, "expected {s}, got {f}", .{ code, unit.sema.fmtValue(result) }) };
    if (result.type != unit.sema.t.bool or result.bytes[0] == 0)
        return .{ .fail = try std.fmt.allocPrint(a, "the result is {f}", .{unit.sema.fmtValue(result)}) };
    if (!compile) return .pass;

    const c_path = try std.fmt.allocPrint(a, "{s}/{s}.c", .{ c_dir, name });
    // without #line, so a C error points at the C
    writeC(unit, io, c_path, false) catch |e| return .{ .fail = try std.fmt.allocPrint(a, "emitting C: {t}", .{e}) };
    const run = try std.process.run(a, io, .{ .argv = &.{ "tcc", "-run", c_path } });
    if (run.term.success()) return .pass;
    if (run.stderr.len > 0) return .{ .fail = try std.fmt.allocPrint(a, "compiled ({s}): {s}", .{ c_path, run.stderr }) };
    return .{ .fail = try std.fmt.allocPrint(a, "compiled ({s}): the result is false", .{c_path}) };
}
