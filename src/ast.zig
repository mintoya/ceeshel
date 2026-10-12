const std = @import("std");

pub const AstH = u32;
pub const SrcPos = u32;
pub const AstList = std.ArrayList(Ast);

pub fn opNumber(comptime s: []const u8) u32 {
    if (s.len == 0 or s.len > 4)
        @compileError("operators must contain one to four bytes");
    var number: u32 = 0;
    for (s, 0..) |byte, i| number |= @as(u32, byte) << @intCast(i * 8);
    return number;
}

pub const opNumbers = enum(u32) {
    callp = opNumber("()"),
    calla = opNumber("[]"),
    as = opNumber("as"),
    dot = opNumber("."),
    colon = opNumber(":"),

    mul = opNumber("*"),
    div = opNumber("/"),
    mod = opNumber("%"),
    plus = opNumber("+"),
    minus = opNumber("-"),

    mor = opNumber(">"),
    les = opNumber("<"),
    moq = opNumber(">="),
    leq = opNumber("<="),
    eq = opNumber("=="),
    neq = opNumber("!="),
    cmp = opNumber("<=>"),

    oand = opNumber("and"),
    oor = opNumber("or"),
    xor = opNumber("xor"),
    oband = opNumber("band"),
    obor = opNumber("bor"),
    bxor = opNumber("bxor"),
    shr = opNumber("shr"),
    shl = opNumber("shl"),

    pipe = opNumber("|>"),
    set = opNumber("="),
};

pub const Ast = union(enum(u8)) {
    null,
    empty: SrcPos,
    id: SrcPos,
    string: SrcPos,
    number: SrcPos,
    decl: Decl,
    op: Op,
    ablock: Block,
    bblock: Block,
    pblock: Block,

    pub const Decl = struct {
        place: AstH,
        @"~": bool,
        pub fn name(this: @This(), nodes: []const Ast) Ast {
            return get(nodes, this.place);
        }
        pub fn @"type"(this: @This(), nodes: []const Ast) Ast {
            return get(nodes, this.place + 1);
        }
        pub fn value(this: @This(), nodes: []const Ast) Ast {
            return get(nodes, this.place + 2);
        }
    };

    pub const Op = struct {
        /// Left and right operands occupy two consecutive nodes.
        place: AstH,
        number_rep: u32,

        pub fn left(self: Op, nodes: []const Ast) Ast {
            return get(nodes, self.place);
        }

        pub fn right(self: Op, nodes: []const Ast) Ast {
            return get(nodes, self.place + 1);
        }

        pub fn symbol(self: Op) [4]u8 {
            return .{
                @truncate(self.number_rep),
                @truncate(self.number_rep >> 8),
                @truncate(self.number_rep >> 16),
                @truncate(self.number_rep >> 24),
            };
        }
    };

    pub const Block = struct {
        pos: SrcPos,
        start: AstH,

        pub fn items(self: Block, nodes: []const Ast) []const Ast {
            std.debug.assert(self.start != 0 and self.start <= nodes.len);
            const start = self.start - 1;
            var end: usize = start;
            while (end < nodes.len and nodes[end] != .null) : (end += 1) {}
            std.debug.assert(end < nodes.len);
            return nodes[start..end];
        }
    };

    pub fn srcpos(self: Ast, nodes: []const Ast) SrcPos {
        const firstSrcPos = struct {
            fn firstSrcPos(nodess: []const Ast, start: AstH, count: u32) SrcPos {
                for (0..count) |offset| {
                    const pos = get(nodess, start + @as(u32, @intCast(offset))).srcpos(nodess);
                    if (pos != 0) return pos;
                }
                return 0;
            }
        }.firstSrcPos;
        return switch (self) {
            .null => 0,
            .empty, .id, .string, .number => |pos| pos,
            .ablock, .bblock, .pblock => |block| block.pos,
            .op => |op| firstSrcPos(nodes, op.place, 2),
            .decl => |decl| firstSrcPos(nodes, decl.place, 3),
        };
    }
};

pub fn get(nodes: []const Ast, handle: AstH) Ast {
    std.debug.assert(handle != 0 and handle <= nodes.len);
    return nodes[handle - 1];
}

pub const File = struct {
    filename: []const u8,
    content: []const u8,
};

pub const Position = struct {
    /// One-based file index.
    fidx: u32,
    offset: u32,
    length: u32,
};

pub const Source = struct {
    positions: []const Position,
    files: []const File,

    pub fn text(self: Source, pos: SrcPos) []const u8 {
        if (pos == 0 or pos > self.positions.len) return "";
        const p = self.positions[pos - 1];
        if (p.fidx == 0 or p.fidx > self.files.len) return "";
        const content = self.files[p.fidx - 1].content;
        if (p.offset > content.len or p.length > content.len - p.offset) return "";
        return content[p.offset..][0..p.length];
    }
};

/// AST handle with the context needed for debug printing.
pub const AstFull = struct {
    idx: AstH,
    nodes: []const Ast,
    source: Source,

    pub fn format(self: AstFull, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try self.writeNode(self.idx, writer);
    }

    fn writeNode(self: AstFull, idx: AstH, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (idx == 0) return writer.writeAll("(n)");
        switch (get(self.nodes, idx)) {
            .null => try writer.writeAll("(n)"),
            .empty => try writer.writeAll("(e)"),
            .id => |pos| try writer.print("(i {s})", .{self.source.text(pos)}),
            .string => |pos| try writer.print("(s {s})", .{self.source.text(pos)}),
            .number => |pos| try writer.print("(n {s})", .{self.source.text(pos)}),
            .decl => |decl| {
                try writer.writeAll(if (decl.@"~") "(d :const" else "(d");
                for (0..3) |offset| {
                    try writer.writeByte(',');
                    try self.writeNode(decl.place + @as(u32, @intCast(offset)), writer);
                }
                try writer.writeByte(')');
            },
            .op => |op| {
                const symbol = op.symbol();
                const len = std.mem.indexOfScalar(u8, &symbol, 0) orelse symbol.len;
                try writer.print("(o \"{s}\",", .{symbol[0..len]});
                try self.writeNode(op.place, writer);
                try writer.writeByte(',');
                try self.writeNode(op.place + 1, writer);
                try writer.writeByte(')');
            },
            .ablock, .bblock, .pblock => |block| {
                const name = switch (get(self.nodes, idx)) {
                    .ablock => "ab",
                    .bblock => "bb",
                    .pblock => "pb",
                    else => unreachable,
                };
                try writer.print("({s}", .{name});
                var child = block.start;
                while (get(self.nodes, child) != .null) : (child += 1) {
                    if (child != block.start) try writer.writeByte(',');
                    try self.writeNode(child, writer);
                }
                try writer.writeByte(')');
            },
        }
    }
};

test "operator spellings round trip including four-byte operators" {
    try std.testing.expectEqual(@as(u32, 0x2928), @backingInt(opNumbers.callp));
    const op: Ast.Op = .{ .place = 1, .number_rep = @backingInt(opNumbers.oband) };
    try std.testing.expectEqualStrings("band", &op.symbol());
}

test "source positions fall back through contiguous operands" {
    const nodes = [_]Ast{
        .null,                                      .{ .empty = 0 },                                                        .{ .id = 1 },
        .{ .decl = .{ .place = 1, .@"~" = true } }, .{ .op = .{ .place = 2, .number_rep = @backingInt(opNumbers.callp) } },
    };
    try std.testing.expectEqual(@as(SrcPos, 1), nodes[3].srcpos(&nodes));
    try std.testing.expectEqual(@as(SrcPos, 1), nodes[4].srcpos(&nodes));
    try std.testing.expectEqual(@as(SrcPos, 0), nodes[0].srcpos(&nodes));
}

test "source text validates one-based indices and bounds" {
    const source: Source = .{
        .files = &.{.{ .filename = "test", .content = "abc" }},
        .positions = &.{
            .{ .fidx = 1, .offset = 1, .length = 2 },
            .{ .fidx = 0, .offset = 0, .length = 1 },
            .{ .fidx = 1, .offset = 2, .length = 2 },
        },
    };
    try std.testing.expectEqualStrings("bc", source.text(1));
    for ([_]SrcPos{ 0, 2, 3, 4 }) |pos| try std.testing.expectEqualStrings("", source.text(pos));
}

test "debug printer follows block sentinels and operand handles" {
    const nodes = [_]Ast{
        .{ .pblock = .{ .pos = 1, .start = 2 } },
        .{ .op = .{ .place = 4, .number_rep = @backingInt(opNumbers.oband) } },
        .null,
        .{ .id = 1 },
        .{ .number = 2 },
    };
    const full: AstFull = .{
        .idx = 1,
        .nodes = &nodes,
        .source = .{
            .files = &.{.{ .filename = "test", .content = "x1" }},
            .positions = &.{
                .{ .fidx = 1, .offset = 0, .length = 1 },
                .{ .fidx = 1, .offset = 1, .length = 1 },
            },
        },
    };
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writer.print("{f}", .{full});
    try std.testing.expectEqualStrings("(PBlock(Op \"band\",(Id x),(Num 1)))", writer.buffered());
}

test "helpers return declaration fields, operands, and block items" {
    const nodes = [_]Ast{ .{ .id = 1 }, .{ .empty = 2 }, .{ .number = 3 }, .null };
    const decl: Ast.Decl = .{ .place = 1, .@"~" = true };
    try std.testing.expectEqual(@as(SrcPos, 1), decl.name(&nodes).id);
    try std.testing.expectEqual(@as(SrcPos, 2), decl.type(&nodes).empty);
    try std.testing.expectEqual(@as(SrcPos, 3), decl.value(&nodes).number);
    const op: Ast.Op = .{ .place = 2, .number_rep = @backingInt(opNumbers.plus) };
    try std.testing.expectEqual(@as(SrcPos, 2), op.left(&nodes).empty);
    try std.testing.expectEqual(@as(SrcPos, 3), op.right(&nodes).number);
    const block: Ast.Block = .{ .pos = 0, .start = 1 };
    try std.testing.expectEqual(@as(usize, 3), block.items(&nodes).len);
    try std.testing.expect(block.items(&nodes).ptr == nodes[0..].ptr);
    const empty: Ast.Block = .{ .pos = 0, .start = 4 };
    try std.testing.expectEqual(@as(usize, 0), empty.items(&nodes).len);
}
