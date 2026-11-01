const std = @import("std");
const Ast = @import("ast.zig");

const Expectation = struct {
    err: ?[]const u8 = null,
    compiled_only: bool = false,

    fn parse(source: []const u8) !Expectation {
        var result: Expectation = .{};
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            if (!std.mem.startsWith(u8, trimmed, "//")) break;
            const comment = std.mem.trim(u8, trimmed[2..], " \t");
            if (std.mem.startsWith(u8, comment, "error:")) {
                const name = std.mem.trim(u8, comment[6..], " \t");
                if (name.len == 0 or result.err != null) return error.InvalidTestDirective;
                result.err = name;
            } else if (std.mem.eql(u8, comment, "compiled only")) {
                result.compiled_only = true;
            }
        }
        return result;
    }
};

const Outcome = union(enum) { value: bool, diagnostic: []const u8, unsupported };
const Verdict = enum { pass, fail, skip };

fn verdict(expected: Expectation, actual: Outcome) Verdict {
    if (expected.compiled_only) return .skip;
    return switch (actual) {
        .unsupported => .fail,
        .value => |v| if (expected.err == null and v) .pass else .fail,
        .diagnostic => |name| if (expected.err != null and std.mem.eql(u8, expected.err.?, name)) .pass else .fail,
    };
}

fn evaluate(io: std.Io, allocator: std.mem.Allocator, path: [:0]const u8) !Outcome {
    var state = try Ast.AstState.init(allocator);
    defer state.deinit();
    _ = Ast.Ast.parse(io, .{ .filename = path }, &state) catch |err| switch (err) {
        error.SyntaxError => return .{ .diagnostic = "PARSE" },
        else => return err,
    };
    // Lower.lower is not implemented yet. Parsing alone cannot pass a fixture.
    return .unsupported;
}

pub fn run(io: std.Io, allocator: std.mem.Allocator, directory: []const u8) !u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".cshl")) continue;
        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        try names.append(allocator, name);
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    var passed: usize = 0;
    var failed: usize = 0;
    var skipped: usize = 0;
    for (names.items) |name| {
        const path = try std.fs.path.joinZ(allocator, &.{ directory, name });
        defer allocator.free(path);
        const source = dir.readFileAlloc(io, name, allocator, .unlimited) catch |err| {
            std.debug.print("FAIL {s}: {s}\n", .{ name, @errorName(err) });
            failed += 1;
            continue;
        };
        defer allocator.free(source);
        const expected = Expectation.parse(source) catch |err| {
            std.debug.print("FAIL {s}: {s}\n", .{ name, @errorName(err) });
            failed += 1;
            continue;
        };
        if (expected.compiled_only) {
            std.debug.print("SKIP {s}: compiled only\n", .{name});
            skipped += 1;
            continue;
        }
        const actual = evaluate(io, allocator, path) catch |err| {
            std.debug.print("FAIL {s}: {s}\n", .{ name, @errorName(err) });
            failed += 1;
            continue;
        };
        switch (verdict(expected, actual)) {
            .pass => {
                passed += 1;
                std.debug.print("PASS {s}\n", .{name});
            },
            .fail => {
                failed += 1;
                std.debug.print("FAIL {s}: expected {s}, got ", .{ name, expected.err orelse "true" });
                switch (actual) {
                    .unsupported => std.debug.print("unsupported evaluation\n", .{}),
                    .diagnostic => |diagnostic| std.debug.print("{s}\n", .{diagnostic}),
                    .value => |v| std.debug.print("{}\n", .{v}),
                }
            },
            .skip => unreachable,
        }
    }
    std.debug.print("{d} passed, {d} failed, {d} skipped\n", .{ passed, failed, skipped });
    if (names.items.len == 0) std.debug.print("no .cshl fixtures found in {s}\n", .{directory});
    return if (failed != 0 or names.items.len == 0) 1 else 0;
}

test "leading comments" {
    const t = std.testing;
    const expected = try Expectation.parse("\r\n // explanation\r\n // error: PARSE \r\ncode\n// compiled only");
    try t.expectEqualStrings("PARSE", expected.err.?);
    try t.expect(!expected.compiled_only);
    try t.expect((try Expectation.parse("// compiled only\ncode")).compiled_only);
    try t.expectEqual(@as(?[]const u8, null), (try Expectation.parse("code\n// error: PARSE")).err);
    try t.expectError(error.InvalidTestDirective, Expectation.parse("// error: \n"));
    try t.expectError(error.InvalidTestDirective, Expectation.parse("// error: A\n// error: B\n"));
}

test "fixtures require true or the exact expected diagnostic" {
    const t = std.testing;
    try t.expectEqual(Verdict.pass, verdict(.{}, .{ .value = true }));
    try t.expectEqual(Verdict.fail, verdict(.{}, .{ .value = false }));
    try t.expectEqual(Verdict.fail, verdict(.{}, .{ .diagnostic = "PARSE" }));
    try t.expectEqual(Verdict.pass, verdict(.{ .err = "PARSE" }, .{ .diagnostic = "PARSE" }));
    try t.expectEqual(Verdict.fail, verdict(.{ .err = "PARSE" }, .{ .diagnostic = "OTHER" }));
    try t.expectEqual(Verdict.fail, verdict(.{ .err = "PARSE" }, .{ .value = true }));
    try t.expectEqual(Verdict.fail, verdict(.{}, .unsupported));
    try t.expectEqual(Verdict.fail, verdict(.{ .err = "UNSUPPORTED" }, .unsupported));
    try t.expectEqual(Verdict.skip, verdict(.{ .compiled_only = true }, .unsupported));
}

test "runner checks parse errors, excludes helpers, and rejects empty or unsupported suites" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(path);
    try t.expectEqual(@as(u8, 1), try run(t.io, t.allocator, path));
    try tmp.dir.createDirPath(t.io, "lib");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "lib/helper.cshl", .data = "1" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "ignored.txt", .data = "1" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "parse.cshl", .data = "// error: PARSE\n[" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "compiled.cshl", .data = "// compiled only\n1" });
    try t.expectEqual(@as(u8, 0), try run(t.io, t.allocator, path));
    try tmp.dir.writeFile(t.io, .{ .sub_path = "unsupported.cshl", .data = "1" });
    try t.expectEqual(@as(u8, 1), try run(t.io, t.allocator, path));
    try tmp.dir.writeFile(t.io, .{ .sub_path = "parse.cshl", .data = "// error: OTHER\n[" });
    try t.expectEqual(@as(u8, 1), try run(t.io, t.allocator, path));
}
