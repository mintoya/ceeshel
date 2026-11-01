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
const Value = Pool.Value;

pub const InstIdx = u32;
pub const VR = union(enum) { inst: InstIdx, value: Value };

pub const Inst = struct {
    type: typeid,
    src: astpos,
    data: Kind,
    pub const Kind = union(enum) {
        arg: u32,
        global: u32,
        new: Asth.SrcRef,
        read: VR,
        store: struct {
            place: VR,
            into: VR,
        },
        cast: VR,
        op: struct {
            o: Builtin,
            l: VR,
            r: VR,
        },
        @"if": VR,
        @"else",
        endif,
        loop,
        @"break",
        @"continue",
        endloop,
        cexpr: []const u8,
        // call: struct {
        //     @"fn": fnidx,
        //     args: []const VR,
        // },
    };
};

pub const Function = struct {
    // might be more prudent to just use the type as a typeid
    // just runtime
    params: []const typeid,
    ret: typeid,
    insts: struct { start: InstIdx, len: u32 },
};
pub const Function_pre = struct {
    params: astpos,
    ret: astpos,
    body: astpos,
};
const fnidx = u32;

pub const Error = Allocator.Error || error{
    FractionalNumber,
    BadEscape,
    UnboundName,
    UnImplemented,
};

const Scope = struct {
    map: std.StringHashMapUnmanaged(u32) = .empty,
    values: List(VR) = .empty,
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
insts       : SgList(Inst, 5, 32) = .empty,
astState    : Asth.AstState,
pool        : Pool,
root        : Scope = .{},
heap        : std.AutoHashMapUnmanaged(usize, []u8) = .empty,
// zig fmt: on
pub fn init(allocator: Allocator) Error!Sema {
    const operatorName = struct {
        fn f(b: Builtin) []const u8 {
            return switch (b) {
                .add => "+",
                .sub => "-",
                .mul => "*",
                .div => "/",
                .mod => "%",
                .eq => "==",
                .ne => "!=",
                .lt => "<",
                .gt => ">",
                .le => "<=",
                .ge => ">=",
                .cmp => "<=>",
                .set => "=",
                .dot => ".",
                else => @tagName(b), // and or band bor bxor shl shr xor as
            };
        }
    }.f;
    var pool = try Pool.init(allocator);
    const ast_state = Asth.AstState.init(allocator) catch |err| {
        pool.deinit();
        return err;
    };
    var self: Sema = .{
        .alloc = allocator,
        .arena = .init(allocator),
        .pool = pool,
        .astState = ast_state,
    };
    errdefer self.deinit();

    const builtin = try self.pool.scalar(.builtin);
    const info = @typeInfo(Builtin).@"enum";
    inline for (info.field_names, info.field_values) |field, value| {
        const id: u32 = value;
        const name = if (value < @backingInt(Builtin.add)) "@" ++ field else operatorName(@fromBackingInt(@intCast(value)));
        const bytes = try self.arena.allocator().dupe(u8, std.mem.asBytes(&id));
        try self.bind(&self.root, name, .{ .value = .{ .type = builtin, .bytes = bytes } });
    }
    return self;
}
fn bind(self: *Sema, sc: *Scope, name: []const u8, v: VR) Error!void {
    try sc.values.ensureUnusedCapacity(self.alloc, 1);
    try sc.map.put(self.alloc, name, @intCast(sc.values.items.len));
    sc.values.appendAssumeCapacity(v);
}
fn find(sc: *Scope, name: []const u8) Error!VR {
    var current: ?*Scope = sc;
    while (current) |scope| : (current = scope.parent) {
        if (scope.map.get(name)) |index| return scope.values.items[index];
    }
    return error.UnboundName;
}
pub fn deinit(self: *Sema) void {
    // var allocations = self.heap.valueIterator();
    // while (allocations.next()) |allocation| {
    //     self.alloc.rawFree(allocation.bytes, allocation.alignment, @returnAddress());
    // }
    // self.heap.deinit(self.alloc);
    self.functions.deinit(self.alloc);
    self.insts.deinit(self.alloc);
    self.astState.deinit();
    self.pool.deinit();
    self.root.map.deinit(self.alloc);
    self.root.values.deinit(self.alloc);
    self.arena.deinit();
}

pub fn parseFile(self: *Sema, io: std.Io, path: [:0]const u8) !astpos {
    return Ast.parse(io, .{ .filename = path }, &self.astState);
}
pub fn lower(self: *Sema, pos: astpos) Error!VR {
    return switch (self.astState.asts.items[pos]) {
        .none => .{ .value = try self.voidValue() },
        .num => |src| .{ .value = try self.lowerNumber(src) },
        .str => |src| .{ .value = try self.lowerString(src) },
        .id => |src| .{ .value = try self.lowerId(src) },
        .call => |index| blk: {
            _ = index;
            break :blk Error.UnImplemented;
        },
    };
}
pub fn lowerId(self: *Sema, id: Asth.SrcRef) Error!Value {
    return self.find(&self.root, id.toslice(self.astState.files));
}
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
    if (std.mem.indexOfScalar(u8, t, '.') != null) return Error.FractionalNumber;
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
