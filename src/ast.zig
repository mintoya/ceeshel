const std = @import("std");
const List = std.ArrayList;
const Allocator = std.mem.Allocator;
const ts = @import("tree-sitter");

pub const filepos = u32;
pub const astpos = u32;

/// Four kinds of node, as grammar/grammar.js produces them:
///   atoms  id, str, num
///   list   [a, b] and (a, b), the same thing
///   block  {a; b}
///   call   anything applied: f[a, b], f x, a + b, a.b, 'x, a <<g>> b, and
///          declarations: x ~T = v is (~= x T v), x ~~ v is (~~ x v).
///          The head is the first child.
/// A one-item (x) or [x] without a comma is just x.
pub const Ast = union(enum(u8)) {
    pub const Block = struct {
        block: astpos, // null terminated span in the src lst
        pos: SrcRef,
    };
    null: void,
    id: SrcRef,
    str: SrcRef,
    num: SrcRef,
    list: Block, // [] and ()
    block: Block, // {}
    call: Block, // head, then arguments
    /// Parses a file or a string with grammar/grammar.js; the result is a
    /// block of its statements.
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
            .str => |s| {
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
        if (root.hasError()) return error.SyntaxError;

        const pos: astpos = @intCast(ctx.asts.items.len);
        try ctx.asts.append(ctx.alloc, .null);
        const top = try convert(ctx, fileref, root); // may move asts: store after
        ctx.asts.items[pos] = top;
        return pos;
    }

    fn ref(fileref: filepos, node: ts.Node) SrcRef {
        return .{ .fileref = fileref, .offset = node.startByte(), .len = node.endByte() - node.startByte() };
    }

    /// One tree-sitter node as an ast. Its children go in a run of their
    /// own, reserved before any of them is converted, so the run stays
    /// contiguous while their children are appended after it.
    fn convert(ctx: *AstState, fileref: filepos, node: ts.Node) Allocator.Error!Ast {
        const kind = node.kind();
        if (std.mem.eql(u8, kind, "id")) return .{ .id = ref(fileref, node) };
        if (std.mem.eql(u8, kind, "number")) return .{ .num = ref(fileref, node) };
        if (std.mem.eql(u8, kind, "string")) return .{ .str = ref(fileref, node) };

        // the children as an ast sees them, and for a call its head
        var parts: List(Part) = .empty;
        defer parts.deinit(ctx.alloc);
        var head: ?Part = null;
        if (std.mem.eql(u8, kind, "call")) {
            if (node.childByFieldName("name")) |name| {
                // x ~T = v: a call of ~, ~~ or ~= by its markers
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
                if (node.childByFieldName("type")) |t| try parts.append(ctx.alloc, .{ .node = t });
                if (node.childByFieldName("value")) |v| try parts.append(ctx.alloc, .{ .node = v });
            } else {
                var i: u32 = 0;
                while (i < node.childCount()) : (i += 1) {
                    const field = node.fieldNameForChild(i) orelse continue;
                    const c = node.child(i).?;
                    // a field on a hidden group, as in (a + b) * c, lands on
                    // its brackets too
                    if (!c.isNamed() and std.mem.indexOfScalar(u8, "()[]", c.kind()[0]) != null) continue;
                    if (std.mem.eql(u8, field, "function")) {
                        head = .{ .node = c };
                    } else if (std.mem.eql(u8, field, "argument")) {
                        try parts.append(ctx.alloc, .{ .node = c });
                    }
                }
            }
        } else {
            // program, list, block: their named children, less comments and `;`
            var i: u32 = 0;
            while (i < node.namedChildCount()) : (i += 1) {
                const c = node.namedChild(i).?;
                if (c.isExtra() or std.mem.eql(u8, c.kind(), "empty_statement")) continue;
                try parts.append(ctx.alloc, .{ .node = c });
            }
        }

        const count = parts.items.len + @intFromBool(head != null);
        const start: astpos = @intCast(ctx.asts.items.len);
        try ctx.asts.appendNTimes(ctx.alloc, .null, count + 1);
        var slot = start;
        // converting appends to asts, which can move it: store each result after
        if (head) |h| {
            const a = try h.ast(ctx, fileref);
            ctx.asts.items[slot] = a;
            slot += 1;
        }
        for (parts.items) |p| {
            const a = try p.ast(ctx, fileref);
            ctx.asts.items[slot] = a;
            slot += 1;
        }

        const block: Block = .{ .block = start, .pos = ref(fileref, node) };
        if (std.mem.eql(u8, kind, "call")) return .{ .call = block };
        if (std.mem.eql(u8, kind, "list")) return .{ .list = block };
        return .{ .block = block }; // block, program
    }

    /// A child to convert: a node, or a head that isn't one piece of source
    /// (~=), whose text goes in the <generic> buffer.
    const Part = union(enum) {
        node: ts.Node,
        text: []const u8,
        fn ast(self: Part, ctx: *AstState, fileref: filepos) Allocator.Error!Ast {
            switch (self) {
                .node => |n| {
                    // an operator head like + or . is a token, not a node
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
/// Text in a file. Heads that aren't one piece of source, like the ~= of
/// x ~T = v, are text in file 0, the <generic> buffer.
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
pub const AstState = struct {
    alloc: Allocator,
    files: List(FileItem),
    asts: List(Ast),
    pub fn init(allocator: anytype) !@This() {
        var result = @This(){ .alloc = allocator, .files = .empty, .asts = .empty };
        try result.files.append(allocator, .{ .name = "<generic>", .content = .{ .buffer = .empty } });
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
/// An ast with the state that holds its text and children, for printing:
/// lists as [a b], blocks as {a b}, calls as (f a b).
pub const AstCtx = struct {
    state: *const AstState,
    ast: Ast,
    pub fn format(self: @This(), w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.ast) {
            .null => try w.writeAll("null"),
            .id, .str, .num => |s| try w.writeAll(s.toslice(self.state.files)),
            .list => |b| try self.children(w, "[", b, "]"),
            .block => |b| try self.children(w, "{", b, "}"),
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
