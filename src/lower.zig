const std = @import("std");
const big = std.math.big;
const Big = std.math.big.int.Const;
const List = std.ArrayList;
const Allocator = std.mem.Allocator;
const SgList = @import("sglist.zig").SgList;

const Type = Pool.Type;
const Builtin = Type.builtins;
const TypeBase = Type.TypeBase;

const Asth = @import("ast.zig");
const Ast = Asth.Ast;
const astpos = Asth.astpos;

const Pool = @import("pool.zig");
const typeid = Pool.typeid;
const strid = Pool.strid;
// just the type, thesee wont exclusivleey be stored in the pool
const Value = Pool.Value;

pub const InstIdx = u32;
pub const VRef = union(enum) { inst: InstIdx, value: Value };

pub const Inst = struct {
    type: typeid,
    src: astpos,
    data: Kind,
    pub const Kind = union(enum) {
        arg: u32,
        global: u32,
        new: Asth.SrcRef,
        read: VRef,
        store: struct {
            place: VRef,
            into: VRef,
        },
        cast: VRef,
        op: struct {
            o: Builtin,
            l: VRef,
            r: VRef,
        },
        // structure, in sequence
        @"if": VRef,
        @"else",
        endif,
        loop,
        @"break",
        @"continue",
        endloop,
        cexpr: []const u8,
        call: struct {
            @"fn": fnidx,
            args: []const VRef,
        },
    };
};

pub const Function = struct {
    params: []const typeid,
    ret: typeid,
    insts: struct { start: InstIdx, len: u32 },
};
const fnidx = u32;
pub const Error = Allocator.Error || error{ FractionalNumber, BadEscape };
pub const Function_pre = struct {
    params: astpos,
    ret: astpos,
    body: astpos,
};

const Scope = struct {
    map: std.StringHashMapUnmanaged(u32) = .empty,
    values: List(VRef) = .empty,
    parent: ?*@This() = null,

    pub fn isroot(self: @This()) bool {
        return self.parent == null;
    }
};

const Sema = @This();
// zig fmt: off
alloc       : Allocator,
arena       : std.heap.ArenaAllocator,
functions   : List(Function) = .empty,
insts       : SgList(Inst, 5, 32),
astState    : Asth.AstState,
pool        : Pool,
root        : Scope=.{},
// zig fmt: on
pub fn init(allocator: Allocator) !Sema {
    return .{
        .alloc = allocator,
        .arena = .init(allocator),
        .insts = .empty,
        .pool = try .init(allocator),
        .astState = try .init(allocator),
        .root = .{ .parent = null },
    };
}
pub fn deinit(self: *Sema) void {
    self.functions.deinit(self.alloc);
    self.insts.deinit(self.alloc);
    self.astState.deinit();
    self.pool.deinit();
    self.root.map.deinit(self.alloc);
    self.root.values.deinit(self.alloc);
    self.arena.deinit();
}
pub fn lower(_: *Sema, _: astpos) Error!VRef {}

pub fn lowerNumber(self: *Sema, src: Asth.SrcRef) Error!Value {
    const a = self.arena.allocator();
    var t = src.toslice(self.astState.files);
    const negative = t[0] == '-';
    if (negative) t = t[1..];
    var base: u8 = 10;
    if (std.mem.startsWith(u8, t, "0x")) {
        base = 16;
        t = t[2..];
    } else if (std.mem.startsWith(u8, t, "0b")) {
        base = 2;
        t = t[2..];
    }
    if (std.mem.indexOfScalar(u8, t, '.') != null) return error.FractionalNumber;
    var m = try big.int.Managed.init(a);

    m.setString(base, t) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
    if (negative) m.negate();
    const c = m.toConst();
    return .{ .type = try self.pool.scalar(.int), .bytes = try a.dupe(u8, std.mem.asBytes(&c)) };
}
pub fn lowerString(self: *Sema, src: Asth.SrcRef) Error!Value {
    const a = self.arena.allocator();
    const t = src.toslice(self.astState.files);

    var out: List(u8) = .empty;
    defer out.deinit(a);

    var i: usize = 1;
    const end = t.len - 1;
    while (i < end) : (i += 1) {
        if (t[i] != '\\') {
            try out.append(a, t[i]);
            continue;
        }
        i += 1;
        try out.append(a, switch (t[i]) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            '0' => 0,
            'x' => x: {
                if (i + 2 >= end) return error.BadEscape;
                const byte = std.fmt.parseInt(u8, t[i + 1 .. i + 3], 16) catch return error.BadEscape;
                i += 2;
                break :x byte;
            },
            else => t[i],
        });
    }
    return .{
        .type = try self.pool.array(out.items.len, try self.pool.scalar(.cschar)),
        .bytes = try out.toOwnedSlice(a),
    };
}
