const std = @import("std");
const List = std.ArrayList;
const Tokenizer = @import("tokinize.zig");
const Allocator = std.mem.Allocator;

pub const filepos = u32;
pub const astpos = u32;

pub const Ast = union(enum(u8)) {
    pub const Block = struct {
        block: astpos, // [*:.null]Ast
        pos: SrcRef,
    };
    null: void,
    id: SrcRef,
    str: SrcRef,
    num: SrcRef,
    call: astpos, // struct {left,right}
    bloc: Block, // {}
    anon: Block, //[]
    decl: astpos, // struct {name,value,type}
    pub fn parse(
        io: std.Io,
        src: union(enum) {
            filename: [:0]const u8,
            str: []const u8,
        },
        ctx: *AstState,
    ) !astpos {
        var srcidx: SrcRef =
            switch (src) {
                .filename => |path| br: {
                    const srctext = try std.Io.Dir.cwd().readFileAlloc(io, path, ctx.alloc, .limited(std.math.maxInt(u32)));
                    const fidx: filepos = @intCast(ctx.files.items.len);
                    try ctx.files.append(ctx.alloc, FileItem{ .name = path, .content = .{ .file = srctext } });
                    break :br .{ .fileref = fidx, .len = @intCast(srctext.len), .offset = 0 };
                },
                .str => |str| br: {
                    const offset = ctx.files.items[0].content.buffer.items.len;
                    try ctx.files.items[0].content.buffer.appendSlice(ctx.alloc, str);
                    break :br .{ .fileref = 0, .len = @intCast(str.len), .offset = @intCast(offset) };
                },
            };
        var arena = std.heap.ArenaAllocator.init(ctx.alloc);
        defer arena.deinit();
        const arenaAlloc = arena.allocator();
        const tokens = Tokenizer.tokenize(arenaAlloc, srcidx.toslice(ctx.files));
        std.debug.print("{any}", .{tokens});
        if (true)
            return error.NotImplemented;
        return 0;
    }
};
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
pub const AstState = struct {
    alloc: Allocator,
    files: List(FileItem),
    asts: List(Ast),
    pub fn init(allocator: anytype) !@This() {
        var result = @This(){ .alloc = allocator, .files = .empty, .asts = .empty };
        try result.files.append(allocator, .{ .name = "<generic>", .content = .{ .buffer = .empty } });
        return result;
    }
};
pub const AstCtx = struct { state: *const AstState, ast: Ast };
