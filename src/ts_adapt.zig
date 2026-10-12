const std = @import("std");
pub const ast = @import("ast.zig");
pub const ts = @import("treesitter");
const grammar = @import("cshl_language");
const lexer = grammar.lexer;

pub const Error = ts.ParserError || ts.Language.Error || error{
    InputTooLarge,
    LanguageVersionMismatch,
    ParseFailed,
    SyntaxError,
    UnsupportedNode,
    InvalidTree,
};

pub const Diagnostic = struct {
    offset: u32 = 0,
    length: u32 = 0,
    /// One-based byte coordinates.
    line: u32 = 1,
    column: u32 = 1,
};

/// Owns the AST and source text; no Tree-sitter nodes survive conversion.
pub const Parsed = struct {
    allocator: std.mem.Allocator,
    nodes: ast.AstList = .empty,
    positions: std.ArrayList(ast.Position) = .empty,
    files: [1]ast.File,
    root: ast.AstH = 0,

    pub fn deinit(self: *Parsed) void {
        self.nodes.deinit(self.allocator);
        self.positions.deinit(self.allocator);
        self.allocator.free(self.files[0].filename);
        self.allocator.free(self.files[0].content);
        self.* = undefined;
    }

    pub fn source(self: *const Parsed) ast.Source {
        return .{ .positions = self.positions.items, .files = &self.files };
    }

    pub fn full(self: *const Parsed) ast.AstFull {
        return .{ .idx = self.root, .nodes = self.nodes.items, .source = self.source() };
    }
};

pub fn parse(allocator: std.mem.Allocator, filename: []const u8, content: []const u8, diagnostic: ?*Diagnostic) Error!Parsed {
    if (diagnostic) |d| d.* = .{};
    if (content.len > std.math.maxInt(u32)) return error.InputTooLarge;
    var scanner: lexer.State = .{};
    var language = grammar.language;
    language.external_scanner.?.payload = &scanner;
    var parser = ts.Parser.init(allocator);
    defer parser.deinit();
    try parser.setLanguage(language);
    var tree = try parser.parseString(content);
    defer tree.deinit();
    return fromTree(allocator, filename, content, tree.rootNode(), diagnostic);
}

/// Convert an existing Tree-sitter node. Source bytes must match its tree.
pub fn fromTree(allocator: std.mem.Allocator, filename: []const u8, content: []const u8, root: ts.Node, diagnostic: ?*Diagnostic) Error!Parsed {
    if (diagnostic) |d| d.* = .{};
    if (content.len > std.math.maxInt(u32)) return error.InputTooLarge;
    const owned_name = try allocator.dupe(u8, filename);
    errdefer allocator.free(owned_name);
    const owned_content = try allocator.dupe(u8, content);
    var result: Parsed = .{ .allocator = allocator, .files = .{.{ .filename = owned_name, .content = owned_content }} };
    // The filename has its own errdefer above.
    errdefer {
        result.nodes.deinit(allocator);
        result.positions.deinit(allocator);
        allocator.free(owned_content);
    }
    var builder: Builder = .{ .result = &result, .diagnostic = diagnostic };
    const node = try builder.convert(root);
    result.root = try builder.append(&.{node});
    return result;
}

const Builder = struct {
    result: *Parsed,
    diagnostic: ?*Diagnostic,

    fn report(self: *Builder, node: ts.Node) void {
        if (self.diagnostic) |d| {
            const point = node.startPoint();
            const offset = node.startByte();
            d.* = .{ .offset = offset, .length = node.endByte() - offset, .line = point.row + 1, .column = point.column + 1 };
        }
    }

    fn append(self: *Builder, nodes: []const ast.Ast) Error!ast.AstH {
        if (nodes.len > std.math.maxInt(u32) - self.result.nodes.items.len) return error.InputTooLarge;
        const start: ast.AstH = @intCast(self.result.nodes.items.len + 1);
        try self.result.nodes.appendSlice(self.result.allocator, nodes);
        return start;
    }

    fn position(self: *Builder, node: ts.Node) Error!ast.SrcPos {
        const start = node.startByte();
        const end = node.endByte();
        if (end < start or end > self.result.files[0].content.len) return error.InvalidTree;
        if (self.result.positions.items.len == std.math.maxInt(u32)) return error.InputTooLarge;
        try self.result.positions.append(self.result.allocator, .{ .fidx = 1, .offset = start, .length = end - start });
        return @intCast(self.result.positions.items.len);
    }

    fn field(node: ts.Node, comptime name: []const u8) ts.Node {
        return node.childByFieldName(name) orelse .{ .tree = node.tree, .index = std.math.maxInt(u32) };
    }

    fn optional(self: *Builder, node: ts.Node) Error!ast.Ast {
        return if (node.isNull()) .null else try self.convert(node);
    }

    fn collectChildren(self: *Builder, node: ts.Node, children: *ast.AstList) Error!void {
        for (0..node.childCount()) |i| {
            const child = node.child(@intCast(i)).?;
            if (!child.raw().visible) {
                try self.collectChildren(child, children);
            } else if (child.isNamed() and !std.mem.eql(u8, child.nodeType(), "comment")) {
                try children.append(self.result.allocator, try self.convert(child));
            }
        }
    }

    fn convert(self: *Builder, node: ts.Node) Error!ast.Ast {
        if (node.isNull()) return error.InvalidTree;
        if (node.hasError() or node.isError() or node.isMissing()) {
            self.report(firstError(node));
            return error.SyntaxError;
        }
        const kind = node.nodeType();
        if (!node.raw().visible) {
            if (node.childCount() != 1) return error.InvalidTree;
            return self.convert(node.child(0).?);
        }
        if (std.mem.eql(u8, kind, "empty_statement")) return .{ .empty = try self.position(node) };
        if (std.mem.eql(u8, kind, "id")) return .{ .id = try self.position(node) };
        if (std.mem.eql(u8, kind, "string")) return .{ .string = try self.position(node) };
        if (std.mem.eql(u8, kind, "number")) return .{ .number = try self.position(node) };
        if (std.mem.eql(u8, kind, "decl")) {
            const name = try self.optional(field(node, "name"));
            const ty = try self.optional(field(node, "type"));
            const value = try self.optional(field(node, "value"));
            const assignment = field(node, "assignment_op");
            const constant = !assignment.isNull() and self.result.files[0].content[assignment.startByte()] == '~';
            return .{ .decl = .{ .place = try self.append(&.{ name, ty, value }), .@"~" = constant } };
        }
        if (std.mem.eql(u8, kind, "op")) {
            const left_node = field(node, "left");
            const right_node = field(node, "right");
            const operator = field(node, "operator");
            const left = try self.convert(left_node);
            var right = try self.convert(right_node);
            var number: u32 = undefined;
            if (!operator.isNull()) {
                const pos = try self.position(operator);
                const spelling = self.result.source().text(pos);
                if (spelling.len == 0 or spelling.len > 4) return error.InvalidTree;
                number = 0;
                for (spelling, 0..) |byte, i| number |= @as(u32, byte) << @intCast(i * 8);
            } else {
                const tight = left_node.endByte() == right_node.startByte();
                const right_kind = unwrap(right_node).nodeType();
                number = @backingInt(if (tight and right == .ablock) ast.opNumbers.calla else ast.opNumbers.callp);
                if (!(tight and (right == .pblock or right == .ablock)) and !std.mem.eql(u8, right_kind, "nblock")) {
                    const start = try self.append(&.{ right, .null });
                    right = .{ .pblock = .{ .pos = try self.position(right_node), .start = start } };
                }
            }
            return .{ .op = .{ .place = try self.append(&.{ left, right }), .number_rep = number } };
        }
        if (std.mem.eql(u8, kind, "program") or std.mem.eql(u8, kind, "bblock") or std.mem.eql(u8, kind, "ablock") or std.mem.eql(u8, kind, "pblock") or std.mem.eql(u8, kind, "nblock")) {
            var children: ast.AstList = .empty;
            defer children.deinit(self.result.allocator);
            try self.collectChildren(node, &children);
            try children.append(self.result.allocator, .null);
            const block: ast.Ast.Block = .{ .pos = try self.position(node), .start = try self.append(children.items) };
            if (std.mem.eql(u8, kind, "program") or std.mem.eql(u8, kind, "bblock")) return .{ .bblock = block };
            if (std.mem.eql(u8, kind, "ablock")) return .{ .ablock = block };
            return .{ .pblock = block };
        }
        self.report(node);
        return error.UnsupportedNode;
    }
};

fn firstError(node: ts.Node) ts.Node {
    if (node.isError() or node.isMissing()) return node;
    for (0..node.childCount()) |i| {
        const child = node.child(@intCast(i)).?;
        if (child.hasError() or child.isError() or child.isMissing()) return firstError(child);
    }
    return node;
}

test "declarations preserve contiguous fields and omitted nodes" {
    var parsed = try parse(std.testing.allocator, "test", "// comment\nx ~T ~1; y ~= 2; z ~T; ;", null);
    defer parsed.deinit();
    const nodes = parsed.nodes.items;
    const children = ast.get(nodes, parsed.root).bblock.items(nodes);
    try std.testing.expectEqual(@as(usize, 4), children.len);
    const decl = children[0].decl;
    try std.testing.expect(decl.@"~");
    try std.testing.expectEqualStrings("x", parsed.source().text(decl.name(nodes).id));
    try std.testing.expectEqualStrings("T", parsed.source().text(decl.type(nodes).id));
    try std.testing.expectEqualStrings("1", parsed.source().text(decl.value(nodes).number));
    try std.testing.expect(children[1].decl.type(nodes) == .null);
    try std.testing.expect(!children[1].decl.@"~");
    try std.testing.expect(children[2].decl.value(nodes) == .null);
    try std.testing.expect(children[3] == .empty);
}

test "call forms preserve argument syntax and select call operators" {
    var parsed = try parse(std.testing.allocator, "test", "f(1,2); f[1,2]; f (1,2); f x; f {x;}; f 1,2; f(); f[];", null);
    defer parsed.deinit();
    const nodes = parsed.nodes.items;
    const calls = ast.get(nodes, parsed.root).bblock.items(nodes);
    try std.testing.expectEqual(@as(usize, 8), calls.len);
    try std.testing.expectEqual(@as(usize, 2), calls[0].op.right(nodes).pblock.items(nodes).len);
    try std.testing.expectEqual(@backingInt(ast.opNumbers.calla), calls[1].op.number_rep);
    try std.testing.expect(calls[1].op.right(nodes) == .ablock);
    const spaced = calls[2].op.right(nodes).pblock.items(nodes);
    try std.testing.expectEqual(@as(usize, 1), spaced.len);
    try std.testing.expect(spaced[0] == .pblock);
    try std.testing.expect(calls[3].op.right(nodes).pblock.items(nodes)[0] == .id);
    try std.testing.expect(calls[4].op.right(nodes).pblock.items(nodes)[0] == .bblock);
    try std.testing.expectEqual(@as(usize, 2), calls[5].op.right(nodes).pblock.items(nodes).len);
    try std.testing.expectEqual(@as(usize, 0), calls[6].op.right(nodes).pblock.items(nodes).len);
    try std.testing.expectEqual(@as(usize, 0), calls[7].op.right(nodes).ablock.items(nodes).len);
}

test "tight call chains fold left and new operators have their own spellings" {
    var parsed = try parse(std.testing.allocator, "test", "f{1;}[2](3); a <=> b xor c; a == b and c;", null);
    defer parsed.deinit();
    const nodes = parsed.nodes.items;
    const children = ast.get(nodes, parsed.root).bblock.items(nodes);
    const outer = children[0].op;
    try std.testing.expectEqual(@backingInt(ast.opNumbers.callp), outer.number_rep);
    const middle = outer.left(nodes).op;
    try std.testing.expectEqual(@backingInt(ast.opNumbers.calla), middle.number_rep);
    try std.testing.expectEqual(@backingInt(ast.opNumbers.callp), middle.left(nodes).op.number_rep);
    const boolean = children[1].op;
    try std.testing.expectEqual(@backingInt(ast.opNumbers.xor), boolean.number_rep);
    try std.testing.expectEqual(@backingInt(ast.opNumbers.cmp), boolean.left(nodes).op.number_rep);
    try std.testing.expectEqual(@backingInt(ast.opNumbers.eq), children[2].op.left(nodes).op.number_rep);
}

test "syntax errors report missing delimiters and retain no allocations" {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.SyntaxError, parse(std.testing.allocator, "test", "x ~T;\nf(1;", &diagnostic));
    try std.testing.expectEqual(@as(u32, 2), diagnostic.line);
    try std.testing.expect(diagnostic.column > 0);
}

test "empty and comment-only sources produce empty blocks" {
    for ([_][]const u8{ "", "/* empty */" }) |content| {
        var parsed = try parse(std.testing.allocator, "test", content, null);
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 0), ast.get(parsed.nodes.items, parsed.root).bblock.items(parsed.nodes.items).len);
    }
}

test "spacing and comments keep bracket and brace blocks as single loose arguments" {
    var parsed = try parse(std.testing.allocator, "test", "f [1,2]; f/* gap */(1,2); f{1;}; f[1 /* comment */,2];", null);
    defer parsed.deinit();
    const nodes = parsed.nodes.items;
    const calls = ast.get(nodes, parsed.root).bblock.items(nodes);
    try std.testing.expectEqual(@backingInt(ast.opNumbers.callp), calls[0].op.number_rep);
    try std.testing.expect(calls[0].op.right(nodes).pblock.items(nodes)[0] == .ablock);
    try std.testing.expect(calls[1].op.right(nodes).pblock.items(nodes)[0] == .pblock);
    try std.testing.expect(calls[2].op.right(nodes).pblock.items(nodes)[0] == .bblock);
    try std.testing.expectEqual(@as(usize, 2), calls[3].op.right(nodes).ablock.items(nodes).len);
}

test "allocation failures release partially converted ASTs" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var parsed = try parse(allocator, "test", "x ~~ f(1,2)[3]; { y ~T; };", null);
            defer parsed.deinit();
        }
    }.run, .{});
}

fn unwrap(node: ts.Node) ts.Node {
    var current = node;
    while (!current.raw().visible and current.childCount() == 1) current = current.child(0).?;
    return current;
}

test "nested lists and trailing commas preserve all children" {
    var parsed = try parse(std.testing.allocator, "test", "f([1,2,], (3,), {4;},);", null);
    defer parsed.deinit();
    const nodes = parsed.nodes.items;
    const call = ast.get(nodes, parsed.root).bblock.items(nodes)[0].op;
    const args = call.right(nodes).pblock.items(nodes);
    try std.testing.expectEqual(@as(usize, 3), args.len);
    try std.testing.expectEqual(@as(usize, 2), args[0].ablock.items(nodes).len);
    try std.testing.expectEqual(@as(usize, 1), args[1].pblock.items(nodes).len);
    try std.testing.expectEqual(@as(usize, 1), args[2].bblock.items(nodes).len);
}

test "native lexer preserves complete source spellings" {
    var parsed = try parse(std.testing.allocator, "test", "f(@name, -12, 0xAF, 0b10, \"a\\\"b\", andrew);", null);
    defer parsed.deinit();
    const nodes = parsed.nodes.items;
    const args = ast.get(nodes, parsed.root).bblock.items(nodes)[0].op.right(nodes).pblock.items(nodes);
    const expected = [_][]const u8{ "@name", "-12", "0xAF", "0b10", "\"a\\\"b\"", "andrew" };
    try std.testing.expectEqual(expected.len, args.len);
    for (args, expected) |arg, spelling| {
        try std.testing.expectEqualStrings(spelling, parsed.source().text(arg.srcpos(nodes)));
    }
}
