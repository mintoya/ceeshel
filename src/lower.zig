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
pub const Error = Allocator.Error || error{};
pub const Function_pre = struct {
    params: astpos,
    ret: astpos,
    body: astpos,
};

const Sema = @This();
// zig fmt: off
alloc       : Allocator,
functions   : List(Function) = .empty,
insts       : SgList(Inst, 5, 32),
pool        : Pool,
astState    : Asth.AstState,
// zig fmt: on
pub fn init(allocator: Allocator) !Sema {
    return .{
        .alloc = allocator,
        .insts = .empty,
        .pool = try .init(allocator),
        .astState = try .init(allocator),
    };
}
pub fn deinit(self: *Sema) void {
    self.functions.deinit(self.alloc);
    self.globals.deinit(self.alloc);
    self.insts.deinit(self.alloc);
    self.astState.deinit();
    self.pool.deinit();
}
pub fn lower(_: *Sema, _: astpos) Error!VRef {}
