const std = @import("std");
const List = std.ArrayList;
const Allocator = std.mem.Allocator;
const ts = @import("tree-sitter");

pub const filepos = u32;
pub const astpos = u32;

pub const Ast = union(enum(u8)) {
    pub const Block = struct {
        block: astpos, // null terminated span in the src lst
        pos: SrcRef,
    };
    null: void,
    id: SrcRef,
    str: SrcRef,
    num: SrcRef,
    call: Block, // head, then arguments;
                 // [a, b] is ([] a b),
                 // {a; b} is ({} a b)
    pub fn parse(
        io: std.Io,
        src: union(enum) {
            filename: [:0]const u8,
            str: []const u8,
        },
        ctx: *AstState,
    ) !astpos {
        const fileref: filepos = @intCast(ctx.files.items.len);
        switch (src) {
            .filename => |name| {
                const text = try std.Io.Dir.cwd().readFileAlloc(io, name, ctx.alloc, .unlimited);
                try ctx.files.append(ctx.alloc, .{ .name = name, .content = .{ .file = text } });
            },
            .str => |s| { // bit stupid
                var buffer: List(u8) = .empty;
                try buffer.appendSlice(ctx.alloc, s);
                try ctx.files.append(ctx.alloc, .{ .name = "<string>", .content = .{ .buffer = buffer } });
            },
        }
        const text = switch (ctx.files.items[fileref].content) {
            .file => |s| s,
            .buffer => |b| b.items,
        };

        const parser = ts.Parser.create();
        defer parser.destroy();
        try parser.setLanguage(tree_sitter_cshl());
        const tree = parser.parseString(text, null) orelse return error.ParseFailed;
        defer tree.destroy();
        const root = tree.rootNode();
        if (root.hasError()) {
            ctx.syntax_error = ref(fileref, firstError(root));
            return error.SyntaxError;
        }

        const pos: astpos = @intCast(ctx.asts.items.len);
        try ctx.asts.append(ctx.alloc, .null);
        const top = try convert(ctx, fileref, root); // may move asts: store after
        ctx.asts.items[pos] = top;
        return pos;
    }

    // the first node the parser couldn't place, or had to make up
    fn firstError(node: ts.Node) ts.Node {
        for (0..node.childCount()) |i| {
            const c = node.child(@intCast(i)).?;
            if (c.isError() or c.isMissing()) return c;
            if (c.hasError()) return firstError(c);
        }
        return node;
    }

    fn ref(fileref: filepos, node: ts.Node) SrcRef {
        return .{ .fileref = fileref, .offset = node.startByte(), .len = node.endByte() - node.startByte() };
    }

    fn convert(ctx: *AstState, fileref: filepos, node: ts.Node) Allocator.Error!Ast {
        const kind = node.kind();
        if (std.mem.eql(u8, kind, "id")) return .{ .id = ref(fileref, node) };
        if (std.mem.eql(u8, kind, "number")) return .{ .num = ref(fileref, node) };
        if (std.mem.eql(u8, kind, "string")) return .{ .str = ref(fileref, node) };

        var parts: List(Part) = .empty;
        defer parts.deinit(ctx.alloc);
        var head: ?Part = null;
        if (std.mem.eql(u8, kind, "call")) {
            if (namedField(node, "name")) |name| {
                var marks: [2]u8 = undefined;
                var n: usize = 0;
                var i: u32 = 0;
                while (i < node.childCount()) : (i += 1) {
                    const field = node.fieldNameForChild(i) orelse continue;
                    if (std.mem.eql(u8, field, "function") and n < 2) {
                        marks[n] = node.child(i).?.kind()[0];
                        n += 1;
                    }
                }
                const has_value = node.childByFieldName("value") != null;
                head = .{ .text = if (!has_value) "~" else if (marks[n - 1] == '=') "~=" else "~~" };
                try parts.append(ctx.alloc, .{ .node = name });
                if (namedField(node, "type")) |t| try parts.append(ctx.alloc, .{ .node = t });
                if (namedField(node, "value")) |v| try parts.append(ctx.alloc, .{ .node = v });
            } else {
                var bracket: u8 = 0;
                var i: u32 = 0;
                while (i < node.childCount()) : (i += 1) {
                    const c = node.child(i).?;
                    if (!c.isNamed() and std.mem.indexOfScalar(u8, "([", c.kind()[0]) != null and bracket == 0) bracket = c.kind()[0];
                    const field = node.fieldNameForChild(i) orelse continue;
                    if (!c.isNamed() and std.mem.indexOfScalar(u8, "()[]", c.kind()[0]) != null) continue;
                    if (std.mem.eql(u8, field, "function")) {
                        head = .{ .node = c };
                    } else if (std.mem.eql(u8, field, "argument")) {
                        try parts.append(ctx.alloc, .{ .node = c });
                    }
                }
                // a quote mark against [a, b] or (a, b) quotes the list: '[a, b] is '([a, b])
                const marks = [_][]const u8{ "'", "`", "\\", ".." };
                const h = head.?.node;
                const is_mark = std.mem.eql(u8, h.kind(), "id") and for (marks) |m| {
                    if (std.mem.eql(u8, text_of(ctx, fileref, h), m)) break true;
                } else false;
                if (is_mark and (bracket == '[' or (bracket == '(' and parts.items.len != 1))) {
                    const nodes = try ctx.alloc.alloc(ts.Node, parts.items.len);
                    for (nodes, parts.items) |*n, p| n.* = p.node;
                    parts.clearRetainingCapacity();
                    try parts.append(ctx.alloc, .{ .list = .{ .nodes = nodes, .at = node } });
                }
            }
        } else {
            head = .{ .text = if (std.mem.eql(u8, kind, "list")) "[]" else "{}" }; // block, program
            var i: u32 = 0;
            while (i < node.namedChildCount()) : (i += 1) {
                const c = node.namedChild(i).?;
                if (c.isExtra() or std.mem.eql(u8, c.kind(), "empty_statement")) continue;
                try parts.append(ctx.alloc, .{ .node = c });
            }
        }

        return build(ctx, fileref, node, head, parts.items);
    }

    // the node in a field: a field on a hidden (x) is on its parentheses too
    fn namedField(node: ts.Node, field: []const u8) ?ts.Node {
        var i: u32 = 0;
        while (i < node.childCount()) : (i += 1) {
            const f = node.fieldNameForChild(i) orelse continue;
            const c = node.child(i).?;
            if (c.isNamed() and std.mem.eql(u8, f, field)) return c;
        }
        return null;
    }

    fn text_of(ctx: *AstState, fileref: filepos, node: ts.Node) []const u8 {
        return ref(fileref, node).toslice(ctx.files);
    }

    fn build(ctx: *AstState, fileref: filepos, node: ts.Node, head: ?Part, parts: []const Part) Allocator.Error!Ast {
        const count = parts.len + @intFromBool(head != null);
        const start: astpos = @intCast(ctx.asts.items.len);
        try ctx.asts.appendNTimes(ctx.alloc, .null, count + 1);
        var slot = start;
        if (head) |h| {
            const a = try h.ast(ctx, fileref);
            ctx.asts.items[slot] = a;
            slot += 1;
        }
        for (parts) |p| {
            const a = try p.ast(ctx, fileref);
            ctx.asts.items[slot] = a;
            slot += 1;
        }

        return .{ .call = .{ .block = start, .pos = ref(fileref, node) } };
    }

    const Part = union(enum) {
        node: ts.Node,
        text: []const u8,
        list: struct { nodes: []const ts.Node, at: ts.Node }, // a [] list of these
        fn ast(self: Part, ctx: *AstState, fileref: filepos) Allocator.Error!Ast {
            switch (self) {
                .list => |l| {
                    defer ctx.alloc.free(l.nodes);
                    const parts = try ctx.alloc.alloc(Part, l.nodes.len);
                    defer ctx.alloc.free(parts);
                    for (parts, l.nodes) |*p, n| p.* = .{ .node = n };
                    return build(ctx, fileref, l.at, .{ .text = "[]" }, parts);
                },
                .node => |n| {
                    if (!n.isNamed()) return .{ .id = ref(fileref, n) };
                    return convert(ctx, fileref, n);
                },
                .text => |t| {
                    const generic = &ctx.files.items[0].content.buffer;
                    const offset: u32 = @intCast(generic.items.len);
                    try generic.appendSlice(ctx.alloc, t);
                    return .{ .id = .{ .fileref = 0, .offset = offset, .len = @intCast(t.len) } };
                },
            }
        }
    };
};

extern fn tree_sitter_cshl() callconv(.c) *const ts.Language;
pub const FileItem = struct {
    name: [:0]const u8,
    content: union(enum) {
        file: []const u8,
        buffer: List(u8),
    },
};
pub const SrcRef = struct {
    fileref: filepos,
    len: u32,
    offset: u32,
    pub fn toslice(self: @This(), state: List(FileItem)) []const u8 {
        const file = state.items[self.fileref];
        return switch (file.content) {
            .file => |s| s,
            .buffer => |b| b.items,
        }[self.offset .. self.len + self.offset];
    }
};
// "file:line:col"
pub const SrcFmt = struct {
    state: *const AstState,
    src: SrcRef,
    pub fn format(self: SrcFmt, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const file = self.state.files.items[self.src.fileref];
        const content = switch (file.content) {
            .file => |c| c,
            .buffer => |b| b.items,
        };
        const before = content[0..self.src.offset];
        const line = std.mem.count(u8, before, "\n") + 1;
        const col = self.src.offset - (if (std.mem.lastIndexOfScalar(u8, before, '\n')) |n| n + 1 else 0) + 1;
        try w.print("{s}:{d}:{d}", .{ file.name, line, col });
    }
};
pub const AstState = struct {
    alloc: Allocator,
    files: List(FileItem),
    asts: List(Ast),
    // where the last error.SyntaxError is
    syntax_error: ?SrcRef = null,
    pub fn init(allocator: anytype) !@This() {
        var result = @This(){ .alloc = allocator, .files = .empty, .asts = .empty };
        try result.files.append(allocator, .{ .name = "<generic>", .content = .{ .buffer = .empty } });
        try result.asts.append(allocator, .null); // slot 0: the empty AST
        return result;
    }
    pub fn deinit(self: *@This()) void {
        for (self.files.items) |*f| switch (f.content) {
            .file => |s| self.alloc.free(s),
            .buffer => |*b| b.deinit(self.alloc),
        };
        self.files.deinit(self.alloc);
        self.asts.deinit(self.alloc);
    }
};
pub const AstCtx = struct {
    state: *const AstState,
    ast: Ast,
    pub fn format(self: @This(), w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.ast) {
            .null => try w.writeAll("null"),
            .id, .str, .num => |s| try w.writeAll(s.toslice(self.state.files)),
            .call => |b| try self.children(w, "(", b, ")"),
        }
    }
    fn children(self: @This(), w: *std.Io.Writer, open: []const u8, b: Ast.Block, close: []const u8) std.Io.Writer.Error!void {
        try w.writeAll(open);
        var i = b.block;
        while (self.state.asts.items[i] != .null) : (i += 1) {
            if (i != b.block) try w.writeAll(" ");
            try (AstCtx{ .state = self.state, .ast = self.state.asts.items[i] }).format(w);
        }
        try w.writeAll(close);
    }
};
