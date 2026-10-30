// AST -> IR. Every expression lowers to a Res: a value (known now, or a
// runtime instruction), a runtime place, or a compile-time variable.
// Compile-time calls are lowered with known arguments, so they fold the way
// Zig's Sema folds them; nothing is interpreted.
const std = @import("std");
const List = std.ArrayList;
const Allocator = std.mem.Allocator;
const big = std.math.big;
const Asth = @import("ast.zig");
const Pool = @import("pool.zig");
const Type = Pool.Type;
const TypeBase = Type.TypeBase;
const Builtin = Type.builtins;
const typeid = Pool.typeid;
const Value = Pool.Value;
const astpos = Asth.astpos;

pub const InstIdx = u32;

// A place is an address: an instruction for a runtime place, a known
// pointer into compile-time memory for a compile-time variable.
pub const Res = union(enum) { val: Ref, place: Ref };
pub const Ref = union(enum) { value: Value, inst: InstIdx };
pub const Inst = struct {
    type: typeid,
    data: Data,
    at: astpos, // where it came from, for errors at runtime
    pub const Data = union(enum) {
        arg: u32,
        global: u32, // the address of global n
        alloc: []const u8, // the address of a new local, named as in the source ("" for a temporary)
        load: Ref, // through an address or a reference
        store: struct { place: Ref, value: Ref },
        cast: Ref, // between integer types
        retype: Ref, // the same bytes as another type: an address as a reference
        op: struct { op: Builtin, lhs: Ref, rhs: Ref },
        // and/or: rhs_body only runs when lhs doesn't decide
        short: struct { op: Builtin, lhs: Ref, rhs_body: []const InstIdx, rhs: Ref },
        call: struct { func: u32, args: []const Ref },
        call_ptr: struct { callee: Ref, args: []const Ref }, // through a function pointer
        cond: struct { cond: Ref, then: []const InstIdx, @"else": []const InstIdx },
        loop: []const InstIdx,
        brk,
        cont,
        field: struct { base: Ref, index: u32 }, // the address of a field, from the struct's
        elem: struct { base: Ref, index: Ref }, // the address of an element, from the array's
        extract: struct { base: Ref, index: u32 }, // a field of a struct value
        aggregate: []const Ref, // a struct or array from its fields
        cexpr: []const u8, // C of the instruction's type; void C is a statement, as written
    };
};

pub const Func = struct {
    name: []const u8,

    params: List(typeid) = .empty,
    ret: ?typeid, // null while an `any` return is being worked out

    param_names: List([]const u8) = .empty,
    insts: List(Inst) = .empty,
    body: []const InstIdx = &.{},
    result: Ref = undefined,
};
const Function = struct { params: astpos, ret: astpos, body: astpos, scope: *Scope };

pub const Global = struct { name: []const u8, type: typeid };

const Field = struct { name: []const u8, type: typeid, default: ?Value };
// members: every name declared in the body, fields and constants, in order
const StructInfo = struct { scope: *Scope, type: typeid, fields: List(Field) = .empty, members: List([]const u8) = .empty };
const tuple_id = std.math.maxInt(u32); // tuples are structural

const Place = struct {
    where: union(enum) { local: struct { func: u32, inst: InstIdx }, global: u32 },
    type: typeid, // held; const when the place is constant
};
const Binding = union(enum) {
    value: Value,
    mem: struct { addr: [*]u8, type: typeid }, // a compile-time variable: memory the language can point to
    rt: struct { ref: Ref, func: u32 }, // a runtime constant, maybe a reference
    place: Place,
};

const Scope = struct {
    parent: ?*Scope,
    names: std.StringHashMapUnmanaged(Binding) = .empty,
    file: bool = false, // runtime declarations here are globals
    struct_id: ?u32 = null, // the body of @struct: declarations are fields
    function: bool = false, // a function body: control flow doesn't leave it
    ret: ?typeid = null, // with function
    loop: bool = false, // @break and @continue target this
    deferred: bool = false, // a deferred body: control flow doesn't leave it
    yielded: ?Res = null, // with deferred
    yielded_type: typeid = 0,
    defers: List(astpos) = .empty,
};

const Block = struct {
    func: ?u32, // null: compile time, nothing may happen at runtime
    body: List(InstIdx) = .empty,
    branch: u32 = 0, // how many runtime conditions it runs under
    typeof_only: bool = false, // lowered for the type: any frame may be named
};

pub const Error = error{Lower} || Allocator.Error;

const Sema = @This();

arena: Allocator,
io: std.Io,
ast: *Asth.AstState,
pool: *Pool,
funcs: List(Func) = .empty,
fns: List(Function) = .empty,
structs: List(StructInfo) = .empty,
globals: List(Global) = .empty,
instances: std.StringHashMapUnmanaged(u32) = .empty,
c_includes: List([]const u8) = .empty,
root: *Scope,
main_block: *Block = undefined, // imported files run here
imports: std.StringHashMapUnmanaged(?Value) = .empty, // null while being imported
gensyms: u32 = 0,
// compile-time memory, with the runtime conditions it was made under: a store
// from under more conditions than that depends on them, and can't happen
comptime_allocs: List(struct { mem: []u8, branch: u32 }) = .empty,
scratch: ?u32 = null, // the function @typeof lowers into; never run or emitted
// compile-time results by instance: compile-time effects happen once per instance
comptime_results: std.StringHashMapUnmanaged(Value) = .empty,
t: struct { void: typeid, bool: typeid, int: typeid, type: typeid, ast: typeid, inlineast: typeid, any: typeid, @"fn": typeid, builtin: typeid, schar: typeid },
err: ?struct { code: []const u8, detail: []const u8, at: astpos } = null,
// the expression @log is given: when it's an inline call, its expansion is printed
log_call: ?astpos = null,
log_expansion: ?Value = null,

pub fn init(arena: Allocator, io: std.Io, ast: *Asth.AstState, pool: *Pool) Error!Sema {
    const P = Pool.helpers;
    var s: Sema = .{
        .arena = arena,
        .io = io,
        .ast = ast,
        .pool = pool,
        .root = try arena.create(Scope),
        .t = .{
            .void = try P.scalar(pool, .void),
            .bool = try P.scalar(pool, .bool),
            .int = try P.scalar(pool, .int),
            .type = try P.scalar(pool, .type),
            .ast = try P.scalar(pool, .ast),
            .inlineast = try P.scalar(pool, .inlineast),
            .any = try P.scalar(pool, .any),
            .@"fn" = try P.scalar(pool, .@"fn"),
            .builtin = try P.scalar(pool, .builtin),
            .schar = try P.scalar(pool, .cschar),
        },
    };
    s.root.* = .{ .parent = null };
    for (operators) |o| try s.root.names.put(arena, o[0], .{ .value = try s.vBuiltin(o[1]) });
    return s;
}

// operators are names, bound to these at the root and inside @raw
const operators = [_]struct { []const u8, Builtin }{
    .{ "+", .add },    .{ "-", .sub },     .{ "*", .mul },   .{ "/", .div },
    .{ "%", .mod },    .{ "==", .eq },     .{ "!=", .ne },   .{ "<", .lt },
    .{ ">", .gt },     .{ "<=", .le },     .{ ">=", .ge },   .{ "and", .@"and" },
    .{ "or", .@"or" }, .{ "band", .band }, .{ "bor", .bor }, .{ "bxor", .bxor },
    .{ "shl", .shl },  .{ "shr", .shr },   .{ "xor", .xor }, .{ "as", .as },
    .{ "<=>", .cmp },  .{ "=", .set },     .{ ".", .dot },
};

// the program is the body of main; its last expression is the result
pub fn lowerProgram(s: *Sema, entry: astpos) Error!u32 {
    try s.funcs.append(s.arena, .{ .name = "main", .ret = null });
    const file = try s.arena.create(Scope);
    file.* = .{ .parent = s.root, .file = true };
    var b: Block = .{ .func = 0 };
    s.main_block = &b;
    const res = try s.lowerStatements(&b, file, (try s.children(entry))[1..], null);
    const result = try s.rvalue(&b, entry, res);
    try s.runDefers(&b, file, .{ .val = result });
    const main = &s.funcs.items[0];
    main.ret = s.typeOf(0, result);
    main.result = result;
    main.body = b.body.items;
    return 0;
}

pub fn fail(s: *Sema, at: astpos, code: []const u8, comptime fmt: []const u8, args: anytype) Error {
    s.err = .{ .code = code, .detail = try std.fmt.allocPrint(s.arena, fmt, args), .at = at };
    return error.Lower;
}

// ---- AST access

fn node(s: *Sema, a: astpos) Asth.Ast {
    return s.ast.asts.items[a];
}
fn text(s: *Sema, a: astpos) []const u8 {
    return switch (s.node(a)) {
        .id, .str, .num => |r| r.toslice(s.ast.files),
        else => "",
    };
}
// a call's children, head first
fn children(s: *Sema, a: astpos) Allocator.Error![]const astpos {
    if (s.node(a) != .call) return &.{};
    const c = s.node(a).call;
    var n: astpos = c.block;
    while (s.node(n) != .null) n += 1;
    const out = try s.arena.alloc(astpos, n - c.block);
    for (out, c.block..) |*o, i| o.* = @intCast(i);
    return out;
}
fn headIs(s: *Sema, a: astpos, name: []const u8) bool {
    if (s.node(a) != .call) return false;
    const h = s.node(a).call.block;
    return s.node(h) == .id and std.mem.eql(u8, s.text(h), name);
}
pub fn srcOf(s: *Sema, a: astpos) ?Asth.SrcRef {
    return switch (s.node(a)) {
        .null => null,
        .id, .str, .num => |r| r,
        .call => |c| c.pos,
    };
}
// "file:line:col: ", or nothing for a node with no source
pub fn fmtAt(s: *Sema, a: astpos) AtFmt {
    return .{ .s = s, .a = a };
}
const AtFmt = struct {
    s: *Sema,
    a: astpos,
    pub fn format(self: AtFmt, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const src = self.s.srcOf(self.a) orelse return;
        try w.print("{f}: ", .{Asth.SrcFmt{ .state = self.s.ast, .src = src }});
    }
};
// a new id node, its text in the generic buffer
fn makeId(s: *Sema, name: []const u8) Error!astpos {
    const generic = &s.ast.files.items[0].content.buffer;
    const offset: u32 = @intCast(generic.items.len);
    try generic.appendSlice(s.ast.alloc, name);
    try s.ast.asts.append(s.ast.alloc, .{ .id = .{ .fileref = 0, .offset = offset, .len = @intCast(name.len) } });
    return @intCast(s.ast.asts.items.len - 1);
}
// a new call node of these children, placed at `pos`
fn makeCall(s: *Sema, kids: []const Asth.Ast, pos: Asth.SrcRef) Error!astpos {
    const asts = &s.ast.asts;
    const start: astpos = @intCast(asts.items.len);
    try asts.appendSlice(s.ast.alloc, kids);
    try asts.append(s.ast.alloc, .null);
    try asts.append(s.ast.alloc, .{ .call = .{ .block = start, .pos = pos } });
    return @intCast(asts.items.len - 1);
}
fn posOf(s: *Sema, a: astpos) Asth.SrcRef {
    return s.srcOf(a) orelse .{ .fileref = 0, .offset = 0, .len = 0 };
}
// structural equality of two ASTs
fn astEql(s: *Sema, x: astpos, y: astpos) Allocator.Error!bool {
    const nx = s.node(x);
    const ny = s.node(y);
    if (std.meta.activeTag(nx) != std.meta.activeTag(ny)) return false;
    if (nx != .call) return std.mem.eql(u8, s.text(x), s.text(y));
    const kx = try s.children(x);
    const ky = try s.children(y);
    if (kx.len != ky.len) return false;
    for (kx, ky) |p, q| if (!try s.astEql(p, q)) return false;
    return true;
}

// an AST's structure, for an instance key
fn keyAst(s: *Sema, key: *List(u8), x: astpos) Allocator.Error!void {
    const n = s.node(x);
    try key.append(s.arena, @backingInt(std.meta.activeTag(n)));
    if (n != .call) {
        const t = s.text(x);
        try key.appendSlice(s.arena, std.mem.asBytes(&@as(u32, @intCast(t.len))));
        return key.appendSlice(s.arena, t);
    }
    const kids = try s.children(x);
    try key.appendSlice(s.arena, std.mem.asBytes(&@as(u32, @intCast(kids.len))));
    for (kids) |k| try s.keyAst(key, k);
}
// a known value by what it holds: an @int's bytes point at its digits, and
// an AST is by its structure, also inside structs and arrays
fn keyValue(s: *Sema, key: *List(u8), at: astpos, v: Value) Error!void {
    const t = try s.unconst(v.type);
    if (!s.isComptime(t)) return key.appendSlice(s.arena, v.bytes);
    if (t == s.t.int) {
        const c = try s.toBig(v);
        try key.append(s.arena, @intFromBool(c.positive));
        try key.appendSlice(s.arena, std.mem.asBytes(&@as(u32, @intCast(c.limbs.len))));
        return key.appendSlice(s.arena, std.mem.sliceAsBytes(c.limbs));
    }
    if (t == s.t.ast or t == s.t.inlineast) return s.keyAst(key, asU32(v));
    if (s.structOf(t)) |st| {
        for (0..st.fields.len) |i| try s.keyValue(key, at, try s.slice(at, t, v.bytes, @intCast(i)));
        return;
    }
    if (s.arrayOf(t)) |arr| {
        const size = (try s.layoutOf(at, arr.elem)).size;
        for (0..arr.len) |i| try s.keyValue(key, at, .{ .type = arr.elem, .bytes = v.bytes[i * size ..][0..size] });
        return;
    }
    return key.appendSlice(s.arena, v.bytes);
}

// ---- values

fn bytes(s: *Sema, x: anytype) Allocator.Error![]const u8 {
    return s.arena.dupe(u8, std.mem.asBytes(&x));
}
fn asU32(v: Value) u32 {
    return std.mem.bytesToValue(u32, v.bytes[0..4]);
}
fn vType(s: *Sema, t: typeid) !Value {
    return .{ .type = s.t.type, .bytes = try s.bytes(@as(u32, t)) };
}
fn vAst(s: *Sema, a: astpos) !Value {
    return .{ .type = s.t.ast, .bytes = try s.bytes(@as(u32, a)) };
}
fn vBuiltin(s: *Sema, b: Builtin) !Value {
    return .{ .type = s.t.builtin, .bytes = try s.bytes(@as(u32, @backingInt(b))) };
}
pub fn vBool(s: *Sema, x: bool) !Value {
    return .{ .type = s.t.bool, .bytes = try s.bytes(@as(u8, @intFromBool(x))) };
}
pub fn vVoid(s: *Sema) Value {
    return .{ .type = s.t.void, .bytes = &.{} };
}
fn vInt(s: *Sema, n: anytype) !Value {
    var m = try big.int.Managed.initSet(s.arena, n);
    return s.vBig(s.t.int, m.toConst());
}
fn vString(s: *Sema, str: []const u8) !Value {
    return .{ .type = try Pool.helpers.array(s.pool, str.len, s.t.schar), .bytes = try s.arena.dupe(u8, str) };
}
fn voidRes(s: *Sema) Res {
    return .{ .val = .{ .value = s.vVoid() } };
}

const IntInfo = struct { signedness: std.builtin.Signedness, bits: usize };
pub fn intInfo(s: *Sema, t: typeid) ?IntInfo {
    const x = s.ty(t);
    if (x.maks.ref or x.maks.ptr != 0) return null;
    const signed = switch (x.type) {
        .cschar, .csshort, .csint, .cslong, .cslonglong => true,
        .cuchar, .cushort, .cuint, .culong, .culonglong, .bool => false,
        else => return null,
    };
    return .{ .signedness = if (signed) .signed else .unsigned, .bits = x.type.rtint_bits() catch unreachable };
}
// a fixed-width integer type (not bool)
fn isInt(s: *Sema, t: typeid) bool {
    return s.ty(t).type != .bool and s.intInfo(t) != null;
}
fn isNum(s: *Sema, t: typeid) bool {
    return t == s.t.int or s.isInt(t);
}

// an @int's bytes are its big.int.Const; a fixed-width integer's are its C bytes
pub fn vBig(s: *Sema, t: typeid, c: big.int.Const) !Value {
    if (t == s.t.int) {
        const owned: big.int.Const = .{ .limbs = try s.arena.dupe(big.Limb, c.limbs), .positive = c.positive };
        return .{ .type = t, .bytes = try s.bytes(owned) };
    }
    const info = s.intInfo(t).?;
    var m: big.int.Mutable = .{
        .limbs = try s.arena.alloc(big.Limb, big.int.calcTwosCompLimbCount(info.bits)),
        .len = 1,
        .positive = true,
    };
    m.truncate(c, info.signedness, info.bits); // out-of-range values keep the low bits, as in cshl
    const out = try s.arena.alloc(u8, (info.bits + 7) / 8);
    m.toConst().writeTwosComplement(out, .little);
    return .{ .type = t, .bytes = out };
}
pub fn toBig(s: *Sema, v: Value) !big.int.Const {
    if (v.type == s.t.int) return std.mem.bytesToValue(big.int.Const, v.bytes);
    const info = s.intInfo(v.type).?;
    var m: big.int.Mutable = .{
        .limbs = try s.arena.alloc(big.Limb, big.int.calcTwosCompLimbCount(info.bits)),
        .len = 1,
        .positive = true,
    };
    m.readTwosComplement(v.bytes, info.bits, .little, info.signedness);
    return m.toConst();
}
pub fn toIndex(s: *Sema, at: astpos, v: Value) Error!usize {
    const c = try s.toBig(v);
    return c.toInt(usize) catch s.fail(at, "INDEX_OUT_OF_BOUNDS", "{f}", .{c});
}
fn valueEql(s: *Sema, a: Value, b: Value) !bool {
    if (a.type != b.type) return false;
    if (a.type == s.t.int) return (try s.toBig(a)).eql(try s.toBig(b));
    if (a.type == s.t.ast or a.type == s.t.inlineast) return s.astEql(asU32(a), asU32(b));
    return std.mem.eql(u8, a.bytes, b.bytes);
}

// ---- types

pub fn ty(s: *Sema, t: typeid) Type {
    return Pool.helpers.get(s.pool, t);
}
fn withMask(s: *Sema, t: typeid, mask: Pool.Mask) !typeid {
    return Pool.helpers.decorate(s.pool, t, mask);
}
fn refT(s: *Sema, t: typeid) !typeid {
    var mask = s.ty(t).maks;
    mask.ref = true;
    return s.withMask(t, mask);
}
fn ptrTo(s: *Sema, t: typeid) !typeid {
    var mask = s.ty(t).maks;
    std.debug.assert(!mask.refaddr);
    if (mask.ref) mask.refaddr = true else mask.ptr += 1;
    return s.withMask(t, mask);
}
fn constT(s: *Sema, t: typeid) !typeid {
    var mask = s.ty(t).maks;
    mask.@"const" = true;
    return s.withMask(t, mask);
}
// the type of the value, without what was declared about where it's kept
fn unconst(s: *Sema, t: typeid) !typeid {
    var mask = s.ty(t).maks;
    if (mask.ptr != 0 or mask.ref) return t; // the const of what is pointed to stays
    mask.@"const" = false;
    mask.@"comptime" = false;
    return s.withMask(t, mask);
}
fn isRef(s: *Sema, t: typeid) bool {
    const m = s.ty(t).maks;
    return m.ref and !m.refaddr;
}
fn isPtr(s: *Sema, t: typeid) bool {
    const m = s.ty(t).maks;
    return m.refaddr or (!m.ref and m.ptr != 0);
}
// what an address or a reference points to
pub fn pointee(s: *Sema, t: typeid) !typeid {
    var mask = s.ty(t).maks;
    if (mask.refaddr) mask.refaddr = false else if (mask.ref) mask.ref = false else mask.ptr -= 1;
    return s.withMask(t, mask);
}
fn isConst(s: *Sema, t: typeid) bool {
    return s.ty(t).maks.@"const";
}
// a struct (or tuple), not behind a reference
fn structOf(s: *Sema, t: typeid) ?struct { id: u32, fields: []const Pool.StructField } {
    const x = s.ty(t);
    if (x.type != .@"struct" or x.maks.ref or x.maks.ptr != 0) return null;
    const f = Pool.helpers.fields_of(s.pool, x);
    return .{ .id = f.id, .fields = f.fields };
}
fn arrayOf(s: *Sema, t: typeid) ?struct { len: u64, elem: typeid } {
    const x = s.ty(t);
    if (x.type != .array or x.maks.ref or x.maks.ptr != 0) return null;
    const a = Pool.helpers.array_of(s.pool, x);
    return .{ .len = a.len, .elem = a.elem };
}
// compile-time only: never reaches C. A struct or array is if any part is.
// A pointer to something compile-time is too.
pub fn isComptime(s: *Sema, t: typeid) bool {
    const x = s.ty(t);
    if (x.type.is_comptime() or x.maks.@"comptime") return true;
    if (x.type == .@"struct") for (Pool.helpers.fields_of(s.pool, x).fields) |f| {
        // a pointer field only by what it points to, so a struct can point to itself
        const fx = s.ty(f.type);
        if (if (fx.maks.ref or fx.maks.ptr != 0) fx.type.is_comptime() else s.isComptime(f.type)) return true;
    };
    if (x.type == .array) return s.isComptime(Pool.helpers.array_of(s.pool, x).elem);
    return false;
}
pub fn layoutOf(s: *Sema, at: astpos, t: typeid) Error!Pool.Layout {
    return s.pool.layout(t) catch s.fail(at, "NO_LAYOUT", "{f} has no layout", .{s.fmtType(t)});
}
fn fieldName(s: *Sema, f: Pool.StructField) []const u8 {
    return s.pool.strings.items[f.name];
}
fn fieldIndex(s: *Sema, t: typeid, name: []const u8) ?u32 {
    const st = s.structOf(t) orelse return null;
    for (st.fields, 0..) |f, i| if (std.mem.eql(u8, s.fieldName(f), name)) return @intCast(i);
    return null;
}
// the namespace scope of a struct type, if it has one
fn namespace(s: *Sema, t: typeid) ?*Scope {
    const st = s.structOf(t) orelse return null;
    if (st.id == tuple_id) return null;
    return s.structs.items[st.id].scope;
}
// the tuple of these element types: structural
fn tupleType(s: *Sema, elems: []const typeid) Error!typeid {
    const fields = try s.arena.alloc(Pool.StructField, elems.len);
    for (fields, elems, 0..) |*f, e, i| f.* = .{ .name = try s.pool.string(try std.fmt.allocPrint(s.arena, "{d}", .{i})), .type = e };
    return Pool.helpers.structure(s.pool, tuple_id, fields);
}

pub fn typeOf(s: *Sema, func: ?u32, r: Ref) typeid {
    return switch (r) {
        .value => |v| v.type,
        .inst => |i| s.funcs.items[func.?].insts.items[i].type,
    };
}
// the type a Res holds
fn heldType(s: *Sema, b: *const Block, r: Res) Error!typeid {
    return switch (r) {
        .val => |x| s.typeOf(b.func, x),
        .place => |x| s.pointee(s.typeOf(b.func, x)),
    };
}

// the function @typeof lowers into
fn scratchFunc(s: *Sema) Error!u32 {
    if (s.scratch == null) {
        s.scratch = @intCast(s.funcs.items.len);
        try s.funcs.append(s.arena, .{ .name = "", .ret = s.t.void, .result = .{ .value = s.vVoid() } });
    }
    return s.scratch.?;
}

// a type expression, always lowered at compile time
fn lowerType(s: *Sema, sc: *Scope, a: astpos) Error!typeid {
    const v = try s.comptimeValue(sc, a);
    if (v.type != s.t.type) return s.fail(a, "EXPECTED_TYPE", "got a value of type {f}", .{s.fmtType(v.type)});
    return asU32(v);
}
fn comptimeValue(s: *Sema, sc: *Scope, a: astpos) Error!Value {
    var cb: Block = .{ .func = null };
    return (try s.lowerValue(&cb, sc, a, null)).value;
}

// ---- emitting

fn emit(s: *Sema, b: *Block, at: astpos, t: typeid, data: Inst.Data) Error!Ref {
    const f = b.func orelse return s.fail(at, "RUNTIME_AT_COMPILE_TIME", "this has to happen at runtime", .{});
    if (t != s.t.void and s.isComptime(t)) return s.fail(at, "COMPTIME_AT_RUNTIME", "a runtime {f}", .{s.fmtType(t)});
    switch (data) {
        inline else => |payload| {
            const P = @TypeOf(payload);
            if (P == Ref) try s.runtimeOperand(at, payload);
            if (P == []const Ref) for (payload) |r| try s.runtimeOperand(at, r);
            if (@typeInfo(P) == .@"struct") {
                const info = @typeInfo(P).@"struct";
                inline for (info.field_names, info.field_types) |name, ft| {
                    if (ft == Ref) try s.runtimeOperand(at, @field(payload, name));
                }
            }
        },
    }
    const insts = &s.funcs.items[f].insts;
    const i: InstIdx = @intCast(insts.items.len);
    try insts.append(s.arena, .{ .type = t, .data = data, .at = at });
    try b.body.append(s.arena, i);
    return .{ .inst = i };
}

// a pointer into compile-time memory can't reach runtime code
fn runtimeOperand(s: *Sema, at: astpos, r: Ref) Error!void {
    if (r == .value and (s.isPtr(r.value.type) or s.isRef(r.value.type)))
        return s.fail(at, "COMPTIME_POINTER_AT_RUNTIME", "a pointer to compile-time memory", .{});
}

// ---- compile-time memory

fn knownAddr(r: Ref) ?[*]u8 {
    return switch (r) {
        .value => |v| @ptrFromInt(std.mem.bytesToValue(usize, v.bytes[0..@sizeOf(usize)])),
        .inst => null,
    };
}
fn vAddr(s: *Sema, t: typeid, addr: [*]u8) !Value {
    return .{ .type = t, .bytes = try s.bytes(@intFromPtr(addr)) };
}
// new compile-time memory holding v
// new compile-time memory holding v, made under b's runtime conditions
fn comptimeMem(s: *Sema, b: *const Block, at: astpos, v: Value) Error![*]u8 {
    const mem = try s.arena.alloc(u8, @max((try s.layoutOf(at, v.type)).size, 1));
    @memset(mem, 0);
    @memcpy(mem[0..v.bytes.len], v.bytes);
    try s.comptime_allocs.append(s.arena, .{ .mem = mem, .branch = b.branch });
    return mem.ptr;
}
// how many runtime conditions the compile-time memory at addr was made under
fn memBranch(s: *Sema, addr: [*]u8) u32 {
    var i = s.comptime_allocs.items.len;
    while (i > 0) {
        i -= 1;
        const m = s.comptime_allocs.items[i].mem;
        if (@intFromPtr(addr) >= @intFromPtr(m.ptr) and @intFromPtr(addr) < @intFromPtr(m.ptr) + m.len) return s.comptime_allocs.items[i].branch;
    }
    return 0;
}
fn memValue(s: *Sema, at: astpos, t: typeid, addr: [*]u8) Error!Value {
    return .{ .type = t, .bytes = try s.arena.dupe(u8, addr[0..(try s.layoutOf(at, t)).size]) };
}

// the value a Res holds
fn load(s: *Sema, b: *Block, at: astpos, r: Res) Error!Ref {
    return switch (r) {
        .val => |x| x,
        .place => |x| {
            const t = try s.pointee(s.typeOf(b.func, x));
            if (knownAddr(x)) |addr| return .{ .value = try s.memValue(at, try s.unconst(t), addr) };
            return s.emit(b, at, t, .{ .load = x });
        },
    };
}
// the value, through any reference
pub fn rvalue(s: *Sema, b: *Block, at: astpos, r: Res) Error!Ref {
    var x = try s.load(b, at, r);
    while (s.isRef(s.typeOf(b.func, x))) x = try s.load(b, at, .{ .place = x });
    return x;
}
// a place to write to or take the address of: a reference value is one
fn asPlace(s: *Sema, b: *Block, at: astpos, r: Res) Error!Res {
    var p = r;
    if (p == .val) {
        if (!s.isRef(s.typeOf(b.func, p.val))) return s.fail(at, "NOT_ADDRESSABLE", "this is a value", .{});
        const addr = p.val;
        p = .{ .place = addr };
    }
    // a place holding a reference is the place it refers to
    while (p == .place and s.isRef(try s.pointee(s.typeOf(b.func, p.place)))) {
        const addr = try s.load(b, at, p);
        p = .{ .place = addr };
    }
    return p;
}

fn lowerValue(s: *Sema, b: *Block, sc: *Scope, a: astpos, dest: ?typeid) Error!Ref {
    return s.coerce(b, a, try s.lower(b, sc, a, dest), dest);
}

// a Res as a value of type dest
fn coerce(s: *Sema, b: *Block, at: astpos, r: Res, dest: ?typeid) Error!Ref {
    const to = dest orelse return s.load(b, at, r);
    if (to == s.t.any) return s.load(b, at, r);
    if (to == s.t.void) return .{ .value = s.vVoid() };
    if (s.isRef(to)) {
        // a reference to the place
        const p = try s.asPlace(b, at, r);
        const target = try s.pointee(to);
        const addr = p.place;
        const held = try s.pointee(s.typeOf(b.func, addr));
        if ((try s.unconst(held)) != (try s.unconst(target)) or (s.isConst(held) and !s.isConst(target)))
            return s.fail(at, "CANNOT_CAST", "expected {f}, got a place of {f}", .{ s.fmtType(to), s.fmtType(held) });
        return s.retypeValue(b, at, addr, to);
    }
    const x = try s.rvalue(b, at, r);
    if (s.ty(to).maks.@"comptime" and x == .inst) return s.fail(at, "RUNTIME_AT_COMPILE_TIME", "{f} is assured to be known", .{s.fmtType(to)});
    const from = s.typeOf(b.func, x);
    if (from == s.t.@"fn" and s.fnptrOf(to) != null) return .{ .value = try s.fnPointer(at, asU32(x.value), to) };
    if (from == to or (try s.unconst(from)) == (try s.unconst(to))) return s.retypeValue(b, at, x, to);
    const asts = [_]typeid{ s.t.ast, s.t.inlineast };
    if (std.mem.indexOfScalar(typeid, &asts, from) != null and std.mem.indexOfScalar(typeid, &asts, to) != null)
        return s.retypeValue(b, at, x, to);
    if (s.isNum(from) and s.isInt(to)) switch (x) {
        .value => |v| return .{ .value = try s.vBig(to, try s.toBig(v)) },
        .inst => return s.emit(b, at, to, .{ .cast = x }),
    };
    return s.fail(at, "CANNOT_CAST", "expected {f}, got {f}", .{ s.fmtType(to), s.fmtType(from) });
}
fn retypeValue(s: *Sema, b: *Block, at: astpos, x: Ref, to: typeid) Error!Ref {
    if (s.typeOf(b.func, x) == to) return x;
    return switch (x) {
        .value => |v| .{ .value = .{ .type = to, .bytes = v.bytes } },
        .inst => s.emit(b, at, to, .{ .retype = x }),
    };
}
// a new local or compile-time variable of type t
fn temporary(s: *Sema, b: *Block, at: astpos, t: typeid) Error!Res {
    if (s.isComptime(t) or b.func == null)
        return .{ .place = .{ .value = try s.vAddr(try s.ptrTo(t), try s.comptimeMem(b, at, try s.zero(at, t))) } };
    return .{ .place = try s.emit(b, at, try s.ptrTo(t), .{ .alloc = "" }) };
}
// a condition: a bool, or an AST (empty is false)
fn condition(s: *Sema, b: *Block, sc: *Scope, a: astpos) Error!Ref {
    const x = try s.rvalue(b, a, try s.lower(b, sc, a, null));
    const t = s.typeOf(b.func, x);
    if (t == s.t.ast or t == s.t.inlineast) {
        const n = asU32(x.value);
        return .{ .value = try s.vBool(n != 0 and s.node(n) != .null) };
    }
    return s.coerce(b, a, .{ .val = x }, s.t.bool);
}

// ---- lowering

fn lower(s: *Sema, b: *Block, sc: *Scope, a: astpos, dest: ?typeid) Error!Res {
    return switch (s.node(a)) {
        .null => s.voidRes(),
        .num => .{ .val = .{ .value = try s.lowerNumber(a) } },
        .str => .{ .val = .{ .value = try s.lowerString(a) } },
        .id => s.lowerId(b, sc, a),
        .call => s.lowerCall(b, sc, a, dest),
    };
}

fn lowerNumber(s: *Sema, a: astpos) Error!Value {
    var t = s.text(a);
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
    const digits = try s.arena.alloc(u8, t.len);
    var n: usize = 0;
    for (t) |c| if (c != '_') {
        digits[n] = c;
        n += 1;
    };
    if (std.mem.indexOfScalar(u8, digits[0..n], '.') != null)
        return s.fail(a, "UNIMPLEMENTED", "fractional numbers", .{});
    var m = try big.int.Managed.init(s.arena);
    m.setString(base, digits[0..n]) catch return s.fail(a, "BAD_NUMBER", "{s}", .{s.text(a)});
    if (negative) m.negate();
    return s.vBig(s.t.int, m.toConst());
}

// a string is an array of i8, without a terminator
fn lowerString(s: *Sema, a: astpos) Error!Value {
    const t = s.text(a);
    var out: List(u8) = .empty;
    var i: usize = 1;
    while (i < t.len - 1) : (i += 1) {
        if (t[i] != '\\') {
            try out.append(s.arena, t[i]);
            continue;
        }
        i += 1;
        if (t[i] == 'x' and i + 2 < t.len) {
            try out.append(s.arena, std.fmt.parseInt(u8, t[i + 1 .. i + 3], 16) catch return s.fail(a, "BAD_STRING", "\\x takes two hex digits", .{}));
            i += 2;
            continue;
        }
        try out.append(s.arena, switch (t[i]) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            '0' => 0,
            else => t[i],
        });
    }
    return s.vString(out.items);
}

fn lookup(sc: *Scope, name: []const u8) ?Binding {
    var at: ?*Scope = sc;
    while (at) |x| : (at = x.parent) if (x.names.get(name)) |bnd| return bnd;
    return null;
}

// names are copied: generated ones live in a buffer that moves as it grows
fn bind(s: *Sema, sc: *Scope, at: astpos, name: []const u8, bnd: Binding) Error!void {
    const gop = try sc.names.getOrPut(s.arena, name);
    if (gop.found_existing) return s.fail(at, "REDECLARED", "{s}", .{name});
    gop.key_ptr.* = try s.arena.dupe(u8, name);
    gop.value_ptr.* = bnd;
    if (sc.struct_id) |id| try s.structs.items[id].members.append(s.arena, gop.key_ptr.*);
}

// a runtime value from another function's frame can't be reached
fn checkFrame(s: *Sema, b: *Block, at: astpos, func: u32) Error!void {
    if (b.func == null) return s.fail(at, "RUNTIME_AT_COMPILE_TIME", "{s} is only known at runtime", .{s.text(at)});
    if (b.func.? != func) return s.fail(at, "CAPTURES_RUNTIME", "{s} belongs to another function's frame", .{s.text(at)});
}

fn placeAddr(s: *Sema, b: *Block, at: astpos, p: Place) Error!Ref {
    switch (p.where) {
        .local => |l| {
            try s.checkFrame(b, at, l.func);
            return .{ .inst = l.inst };
        },
        .global => |g| return s.emit(b, at, try s.ptrTo(p.type), .{ .global = g }),
    }
}

fn resolve(s: *Sema, b: *Block, at: astpos, bnd: Binding) Error!Res {
    // for @typeof, a value from another frame is a placeholder of its type
    if (b.typeof_only) switch (bnd) {
        .rt => |r| if (r.func != b.func.?)
            return .{ .val = try s.emit(b, at, s.typeOf(r.func, r.ref), .{ .arg = 0 }) },
        .place => |p| if (p.where == .local and p.where.local.func != b.func.?)
            return .{ .place = try s.emit(b, at, try s.ptrTo(p.type), .{ .arg = 0 }) },
        else => {},
    };
    return switch (bnd) {
        .value => |v| .{ .val = .{ .value = v } },
        .mem => |m| .{ .place = .{ .value = try s.vAddr(try s.ptrTo(m.type), m.addr) } },
        .rt => |r| {
            try s.checkFrame(b, at, r.func);
            return .{ .val = r.ref };
        },
        .place => |p| .{ .place = try s.placeAddr(b, at, p) },
    };
}

fn lowerId(s: *Sema, b: *Block, sc: *Scope, a: astpos) Error!Res {
    const name = s.text(a);
    if (name[0] == '@') {
        const bi = Builtin.fromName(name) orelse return s.fail(a, "UNKNOWN_BUILTIN", "{s}", .{name});
        return .{ .val = .{ .value = try s.vBuiltin(bi) } };
    }
    const bnd = lookup(sc, name) orelse return s.fail(a, "UNBOUND_ID", "{s}", .{name});
    return s.resolve(b, a, bnd);
}

fn lowerStatements(s: *Sema, b: *Block, sc: *Scope, stmts: []const astpos, dest: ?typeid) Error!Res {
    var last: Res = s.voidRes();
    for (stmts, 0..) |st, i| last = try s.lower(b, sc, st, if (i == stmts.len - 1) dest else null);
    return last;
}

// {a; b}: a scope; yields b, after running what it deferred
fn lowerBlock(s: *Sema, b: *Block, parent: *Scope, stmts: []const astpos, dest: ?typeid) Error!Res {
    const sc = try s.newScope(parent);
    var r = try s.lowerStatements(b, sc, stmts, dest);
    if (sc.defers.items.len == 0) return r;
    // the value is taken before the deferred code runs
    const at = if (stmts.len > 0) stmts[stmts.len - 1] else 0;
    if (r != .val or s.isRef(s.typeOf(b.func, r.val))) {
        const v = try s.load(b, at, r);
        r = .{ .val = v };
    }
    try s.runDefers(b, sc, r);
    return r;
}

fn runDefers(s: *Sema, b: *Block, sc: *Scope, yielded: Res) Error!void {
    var i = sc.defers.items.len;
    while (i > 0) {
        i -= 1;
        const ds = try s.newScope(sc);
        ds.deferred = true;
        ds.yielded = yielded;
        ds.yielded_type = try s.heldType(b, yielded);
        _ = try s.lower(b, ds, sc.defers.items[i], null);
    }
}

fn newScope(s: *Sema, parent: *Scope) Error!*Scope {
    const sc = try s.arena.create(Scope);
    sc.* = .{ .parent = parent };
    return sc;
}

fn eq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

fn lowerCall(s: *Sema, b: *Block, sc: *Scope, a: astpos, dest: ?typeid) Error!Res {
    const kids = try s.children(a);
    const head = kids[0];
    const args = kids[1..];
    if (s.node(head) == .id) {
        const h = s.text(head);
        if (eq(h, "~") or eq(h, "~~") or eq(h, "~=")) return s.lowerDecl(b, sc, a, h, args);
        if (eq(h, "=")) return s.operatorName(b, sc, a, "=", .set, args, dest);
        if (eq(h, "{}")) return s.lowerBlock(b, sc, args, dest);
        if (eq(h, "[]")) return s.lowerList(b, sc, a, args, dest);
        if (eq(h, "|>")) return s.lowerPipe(b, sc, a, args, dest);
        if (eq(h, ".")) return s.operatorName(b, sc, a, ".", .dot, args, dest);
        if (eq(h, "'")) return .{ .val = .{ .value = try s.vAst(try s.quote(sc, args[0])) } };
        if (eq(h, "`")) return s.lower(b, sc, try s.astValue(sc, args[0]), dest);
        if (eq(h, "..")) return s.fail(a, "SPLICE_OUTSIDE_QUOTE", ".. only means something inside a quote", .{});
        if (eq(h, "\\")) return s.fail(a, "ESCAPE_OUTSIDE_QUOTE", "\\ only means something inside a quote", .{});
        if (eq(h, ":")) return s.fail(a, "METHOD_NOT_CALLED", "x:m is called: x:m(...)", .{});
    }
    // x:m(args): m from x's type, x first
    if (s.headIs(head, ":")) {
        const parts = try s.children(head);
        const recv = try s.lower(b, sc, parts[1], null);
        return s.callMethod(b, sc, a, recv, parts[1], parts[2], args, dest);
    }
    const callee = try s.lower(b, sc, head, null);
    if (callee == .val and callee.val == .value) {
        const v = callee.val.value;
        if (v.type == s.t.builtin) return s.callBuiltin(b, sc, a, @fromBackingInt(@intCast(asU32(v))), args, dest);
        if (v.type == s.t.@"fn") return s.callFn(b, sc, a, asU32(v), try s.astArgs(args), dest);
    }
    // a function pointer is called through
    const held = try s.heldType(b, callee);
    if (s.fnptrOf(if (s.isRef(held)) try s.pointee(held) else held)) |sig| return s.callPointer(b, sc, a, head, callee, sig.params, sig.ret, args);
    // calls are special: any other value is called through its () member
    return s.callMember(b, sc, a, callee, head, head, "()", args, dest);
}

// = and . are names: the raw builtin, unless the user declared one
fn operatorName(s: *Sema, b: *Block, sc: *Scope, a: astpos, name: []const u8, raw: Builtin, args: []const astpos, dest: ?typeid) Error!Res {
    const f = try s.bindingValue(a, lookup(sc, name).?);
    if (f.type == s.t.builtin and @as(Builtin, @fromBackingInt(@intCast(asU32(f)))) == raw) return s.callBuiltin(b, sc, a, raw, args, dest);
    return s.callValue(b, sc, a, f, try s.astArgs(args), dest);
}

const Arg = union(enum) { ast: astpos, res: struct { res: Res, at: astpos } };
fn astArgs(s: *Sema, args: []const astpos) Error![]Arg {
    const out = try s.arena.alloc(Arg, args.len);
    for (out, args) |*o, x| o.* = .{ .ast = x };
    return out;
}

fn bindingValue(s: *Sema, at: astpos, bnd: Binding) Error!Value {
    return switch (bnd) {
        .value => |v| v,
        .mem => |m| s.memValue(at, m.type, m.addr),
        else => s.fail(at, "NOT_CALLABLE", "a runtime value", .{}),
    };
}
fn callValue(s: *Sema, b: *Block, sc: *Scope, a: astpos, f: Value, args: []const Arg, dest: ?typeid) Error!Res {
    if (f.type != s.t.@"fn") return s.fail(a, "NOT_CALLABLE", "a value of type {f}", .{s.fmtType(f.type)});
    return s.callFn(b, sc, a, asU32(f), args, dest);
}

fn callMethod(s: *Sema, b: *Block, sc: *Scope, a: astpos, recv: Res, recv_at: astpos, name_ast: astpos, args: []const astpos, dest: ?typeid) Error!Res {
    return s.callMember(b, sc, a, recv, recv_at, name_ast, try s.memberName(sc, name_ast), args, dest);
}
fn callMember(s: *Sema, b: *Block, sc: *Scope, a: astpos, recv: Res, recv_at: astpos, name_ast: astpos, name: []const u8, args: []const astpos, dest: ?typeid) Error!Res {
    var t = try s.heldType(b, recv);
    if (s.isRef(t)) t = try s.pointee(t);
    t = try s.unconst(t);
    const ns = s.namespace(t) orelse return s.fail(name_ast, "NO_SUCH_METHOD", "{f} has no methods", .{s.fmtType(t)});
    const f = ns.names.get(name) orelse return s.fail(name_ast, "NO_SUCH_METHOD", "{f} has no {s}", .{ s.fmtType(t), name });
    const all = try s.arena.alloc(Arg, args.len + 1);
    all[0] = .{ .res = .{ .res = recv, .at = recv_at } };
    for (all[1..], args) |*x, y| x.* = .{ .ast = y };
    return s.callValue(b, sc, a, try s.bindingValue(name_ast, f), all, dest);
}

// a struct's members in the order declared: its fields and its constants
const Member = struct { name: []const u8, type: typeid };
fn members(s: *Sema, at: astpos, t: typeid) Error!?[]const Member {
    const st = s.structOf(t) orelse return null;
    if (st.id == tuple_id) {
        const out = try s.arena.alloc(Member, st.fields.len);
        for (out, st.fields) |*o, f| o.* = .{ .name = s.pool.strings.items[f.name], .type = f.type };
        return out;
    }
    const info = s.structs.items[st.id];
    const out = try s.arena.alloc(Member, info.members.items.len);
    for (out, info.members.items) |*o, name| {
        o.name = name;
        o.type = for (info.fields.items) |f| {
            if (eq(f.name, name)) break f.type;
        } else (try s.bindingValue(at, info.scope.names.get(name).?)).type;
    }
    return out;
}

// what @countof and @fieldtype see: a struct's field types, or a function's
// (or function pointer's) parameter types and then its return type
fn typeParts(s: *Sema, at: astpos, v: Value) Error![]const typeid {
    if (v.type == s.t.@"fn") {
        const f = s.fns.items[asU32(v)];
        const infos = try s.paramInfos(f);
        const types = try s.newScope(f.scope);
        const out = try s.arena.alloc(typeid, infos.len + 1);
        for (infos, out[0..infos.len]) |info, *t| t.* = try s.lowerType(types, info.type_ast);
        out[infos.len] = try s.lowerType(types, f.ret);
        return out;
    }
    if (v.type != s.t.type) return s.fail(at, "EXPECTED_TYPE", "got a value of type {f}", .{s.fmtType(v.type)});
    const t = asU32(v);
    if (try s.members(at, t)) |ms| {
        const out = try s.arena.alloc(typeid, ms.len);
        for (out, ms) |*o, m| o.* = m.type;
        return out;
    }
    const x = s.ty(t);
    if (x.type == .fnptr and x.maks.ptr == 0 and !x.maks.ref) {
        const sig = Pool.helpers.signature(s.pool, x);
        const out = try s.arena.alloc(typeid, sig.params.len + 1);
        @memcpy(out[0..sig.params.len], sig.params);
        out[sig.params.len] = sig.ret;
        return out;
    }
    return s.fail(at, "TYPE_MISMATCH", "a struct, a function or a function pointer, not {f}", .{s.fmtType(t)});
}

// ---- function pointers

fn fnptrOf(s: *Sema, t: typeid) ?struct { params: []const typeid, ret: typeid } {
    const x = s.ty(t);
    if (x.type != .fnptr or x.maks.ptr != 0 or x.maks.ref) return null;
    const sig = Pool.helpers.signature(s.pool, x);
    return .{ .params = sig.params, .ret = sig.ret };
}
// a type a runtime function can take or give: @comptime(T) is just T there;
// a type that only exists at compile time can't be one
fn runtimeType(s: *Sema, at: astpos, t: typeid) Error!typeid {
    var mask = s.ty(t).maks;
    mask.@"comptime" = false;
    const plain = try s.withMask(t, mask);
    if (s.isComptime(plain)) return s.fail(at, "FNPTR_COMPTIME", "{f} isn't a runtime type", .{s.fmtType(plain)});
    return plain;
}
// the function's runtime instance for exactly to's parameter types, as a
// pointer: the one a call with arguments of those types would make
fn fnPointer(s: *Sema, at: astpos, fid: u32, to: typeid) Error!Value {
    const sig = s.fnptrOf(to).?;
    const f = s.fns.items[fid];
    const inst = try s.newScope(f.scope);
    inst.function = true;
    const infos = try s.paramInfos(f);
    if (infos.len != sig.params.len) return s.fail(at, "FNPTR_SIGNATURE", "{d} parameters for {f}", .{ infos.len, s.fmtType(to) });
    var key: List(u8) = .empty;
    try key.appendSlice(s.arena, std.mem.asBytes(&fid));
    const types = try s.newScope(inst);
    const params = try s.arena.alloc(RtParam, infos.len);
    for (infos, sig.params, params) |info, want, *p| {
        const t = try s.lowerType(types, info.type_ast);
        if (t != want) return s.fail(info.type_ast, "FNPTR_SIGNATURE", "{s} is {f}, not {f}", .{ info.name, s.fmtType(t), s.fmtType(want) });
        try key.appendSlice(s.arena, std.mem.asBytes(&t));
        var scratch: Block = .{ .func = try s.scratchFunc(), .typeof_only = true };
        try s.bind(types, info.name_ast, info.name, .{ .rt = .{ .ref = try s.emit(&scratch, info.name_ast, t, .{ .arg = 0 }), .func = scratch.func.? } });
        p.* = .{ .name = info.name, .at = info.name_ast, .ref = undefined, .type = t };
    }
    const ret = try s.lowerType(types, f.ret);
    if (ret != s.t.any and ret != sig.ret) return s.fail(f.ret, "FNPTR_SIGNATURE", "returns {f}, not {f}", .{ s.fmtType(ret), s.fmtType(sig.ret) });
    const fi = s.instances.get(key.items) orelse try s.instantiate(f, inst, ret, params, key.items, fid);
    const got = s.funcs.items[fi].ret orelse return s.fail(at, "RECURSIVE_ANY_RETURN", "the return type is still being worked out", .{});
    if (got != sig.ret) return s.fail(f.ret, "FNPTR_SIGNATURE", "returns {f}, not {f}", .{ s.fmtType(got), s.fmtType(sig.ret) });
    var bits: usize = fi;
    return .{ .type = to, .bytes = try s.arena.dupe(u8, std.mem.asBytes(&bits)) };
}
fn callPointer(s: *Sema, b: *Block, sc: *Scope, a: astpos, head: astpos, callee: Res, params: []const typeid, ret: typeid, args: []const astpos) Error!Res {
    try s.argCount(a, args, params.len);
    const vals = try s.arena.alloc(Ref, args.len);
    for (vals, args, params) |*v, x, t| v.* = try s.coerce(b, x, try s.lower(b, sc, x, t), t);
    const p = try s.rvalue(b, head, callee);
    // a known pointer is a known function
    if (p == .value) {
        const fi: u32 = @intCast(std.mem.bytesToValue(usize, p.value.bytes[0..@sizeOf(usize)]));
        return .{ .val = try s.emit(b, a, ret, .{ .call = .{ .func = fi, .args = vals } }) };
    }
    return .{ .val = try s.emit(b, a, ret, .{ .call_ptr = .{ .callee = p, .args = vals } }) };
}

// what @len and @get look into: an AST, an array or a tuple
const Seq = union(enum) { ast: astpos, array: struct { len: u64, elem: typeid }, tuple: []const Pool.StructField };
fn sequence(s: *Sema, b: *Block, a: astpos, x: Res) Error!Seq {
    var t = try s.heldType(b, x);
    if (s.isRef(t)) t = try s.pointee(t);
    t = try s.unconst(t);
    if (t == s.t.ast or t == s.t.inlineast) {
        const v = try s.load(b, a, x);
        if (v != .value) return s.fail(a, "EXPECTED_AST", "a runtime value", .{});
        return .{ .ast = asU32(v.value) };
    }
    if (s.arrayOf(t)) |arr| return .{ .array = .{ .len = arr.len, .elem = arr.elem } };
    if (s.structOf(t)) |st| if (st.id == tuple_id) return .{ .tuple = st.fields };
    return s.fail(a, "TYPE_MISMATCH", "an AST, an array or a tuple, not {f}", .{s.fmtType(t)});
}

// @get[a, i] is a place in the array
fn arrayGet(s: *Sema, b: *Block, sc: *Scope, a: astpos, recv: Res, len: u64, elem: typeid, ia: astpos) Error!Res {
    const idx = try s.rvalue(b, ia, try s.lower(b, sc, ia, null));
    if (!s.isNum(s.typeOf(b.func, idx))) return s.fail(ia, "TYPE_MISMATCH", "an index is an integer", .{});
    // a zero-length array's length is known elsewhere: unchecked
    if (idx == .value and len != 0 and try s.toIndex(ia, idx.value) >= len)
        return s.fail(ia, "INDEX_OUT_OF_BOUNDS", "{d} elements", .{len});
    var place = recv;
    if (recv == .val and !s.isRef(s.typeOf(b.func, recv.val))) {
        const x = recv.val;
        if (x == .value and idx == .value) {
            const size = (try s.layoutOf(a, elem)).size;
            const i = try s.toIndex(ia, idx.value);
            return .{ .val = .{ .value = .{ .type = elem, .bytes = x.value.bytes[i * size ..][0..size] } } };
        }
        const tmp = try s.temporary(b, a, s.typeOf(b.func, x));
        try s.store(b, a, tmp, x);
        place = tmp;
    } else place = try s.asPlace(b, a, recv);
    const held = try s.pointee(s.typeOf(b.func, place.place));
    const e = if (s.isConst(held)) try s.constT(elem) else elem;
    if (knownAddr(place.place)) |addr| {
        if (idx != .value) return s.fail(ia, "RUNTIME_AT_COMPILE_TIME", "a compile-time array's index", .{});
        const at_i = addr + try s.toIndex(ia, idx.value) * (try s.layoutOf(a, elem)).size;
        return .{ .place = .{ .value = try s.vAddr(try s.ptrTo(e), at_i) } };
    }
    const index = if (idx == .value and idx.value.type == s.t.int)
        Ref{ .value = try s.vBig(try Pool.helpers.scalar(s.pool, .culonglong), try s.toBig(idx.value)) }
    else
        idx;
    return .{ .place = try s.emit(b, a, try s.ptrTo(e), .{ .elem = .{ .base = place.place, .index = index } }) };
}
// a tuple's fields differ in type, so the index is known
fn tupleGet(s: *Sema, b: *Block, sc: *Scope, a: astpos, recv: Res, fields: []const Pool.StructField, ia: astpos) Error!Res {
    const i = try s.toIndex(ia, try s.comptimeValue(sc, ia));
    if (i >= fields.len) return s.fail(ia, "INDEX_OUT_OF_BOUNDS", "{d} elements", .{fields.len});
    return s.fieldOf(b, a, recv, @intCast(i));
}

// x.name: a field, else a member of x's namespace; T.name: a member
fn lowerDot(s: *Sema, b: *Block, sc: *Scope, a: astpos, base_ast: astpos, name_ast: astpos) Error!Res {
    const base = try s.lower(b, sc, base_ast, null);
    const name = try s.memberName(sc, name_ast);
    const held = try s.heldType(b, base);
    if (held == s.t.type) {
        const t = asU32((try s.load(b, a, base)).value);
        const ns = s.namespace(t) orelse return s.fail(name_ast, "NO_SUCH_MEMBER", "{f} has no namespace", .{s.fmtType(t)});
        const bnd = ns.names.get(name) orelse return s.fail(name_ast, "NO_SUCH_MEMBER", "{f} has no {s}", .{ s.fmtType(t), name });
        return s.resolve(b, name_ast, bnd);
    }
    if (held == s.t.ast or held == s.t.inlineast) {
        const x = asU32((try s.load(b, a, base)).value);
        const kind: ?std.meta.Tag(Asth.Ast) = if (eq(name, "id")) .id else if (eq(name, "num")) .num else if (eq(name, "str")) .str else if (eq(name, "call")) .call else null;
        const k = kind orelse return s.fail(name_ast, "NO_SUCH_MEMBER", "an AST has id, num, str and call", .{});
        return .{ .val = .{ .value = try s.vAst(if (std.meta.activeTag(s.node(x)) == k) x else 0) } };
    }
    const t = try s.unconst(if (s.isRef(held)) try s.pointee(held) else held);
    if (s.fieldIndex(t, name)) |i| return s.fieldOf(b, a, base, i);
    if (s.namespace(t)) |ns| if (ns.names.get(name)) |bnd| return s.resolve(b, name_ast, bnd);
    return s.fail(name_ast, "NO_SUCH_MEMBER", "{f} has no {s}", .{ s.fmtType(t), name });
}

// field i of a struct value or place
fn fieldOf(s: *Sema, b: *Block, at: astpos, base: Res, i: u32) Error!Res {
    // through references: to the place they refer to
    const r = if ((base == .val and s.isRef(s.typeOf(b.func, base.val))) or base == .place) try s.asPlace(b, at, base) else base;
    switch (r) {
        .val => |x| {
            const t = try s.unconst(s.typeOf(b.func, x));
            const f = s.structOf(t).?.fields[i];
            switch (x) {
                .value => |v| return .{ .val = .{ .value = try s.slice(at, t, v.bytes, i) } },
                .inst => return .{ .val = try s.emit(b, at, f.type, .{ .extract = .{ .base = x, .index = i } }) },
            }
        },
        .place => |addr| {
            const held = try s.pointee(s.typeOf(b.func, addr));
            const f = s.structOf(try s.unconst(held)).?.fields[i];
            const ft = if (s.isConst(held)) try s.constT(f.type) else f.type;
            if (knownAddr(addr)) |p| {
                const off = s.pool.offset_of(try s.unconst(held), i) catch return s.fail(at, "NO_LAYOUT", "", .{});
                return .{ .place = .{ .value = try s.vAddr(try s.ptrTo(ft), p + off) } };
            }
            return .{ .place = try s.emit(b, at, try s.ptrTo(ft), .{ .field = .{ .base = addr, .index = i } }) };
        },
    }
}
// field i of a known struct's bytes
fn slice(s: *Sema, at: astpos, t: typeid, data: []const u8, i: u32) Error!Value {
    const f = s.structOf(t).?.fields[i];
    const off = s.pool.offset_of(t, i) catch return s.fail(at, "NO_LAYOUT", "", .{});
    const size = (try s.layoutOf(at, f.type)).size;
    return .{ .type = f.type, .bytes = data[off..][0..size] };
}

// the name after . or :, or of a declaration: an id, or an AST naming one
fn memberName(s: *Sema, sc: *Scope, a: astpos) Error![]const u8 {
    return switch (s.node(a)) {
        .id, .num => s.text(a),
        .str => (try s.lowerString(a)).bytes,
        .call => {
            // x.`(e): the name is the AST e gives; x.@id("n") and the like give one too
            const x = if (s.headIs(a, "`")) try s.astValue(sc, (try s.children(a))[1]) else try s.astValue(sc, a);
            if (s.node(x) != .id) return s.fail(a, "EXPECTED_NAME", "the AST isn't a name", .{});
            return s.text(x);
        },
        .null => s.fail(a, "EXPECTED_NAME", "", .{}),
    };
}

// x ~T, x ~T = v, x ~T ~ v, x ~= v, x ~~ v
fn lowerDecl(s: *Sema, b: *Block, sc: *Scope, a: astpos, kind: []const u8, args: []const astpos) Error!Res {
    const constant = eq(kind, "~~");
    const name_ast = args[0];
    const name = try s.memberName(sc, name_ast);
    const has_type = eq(kind, "~") or args.len == 3;
    const declared: ?typeid = if (has_type) try s.lowerType(sc, args[1]) else null;
    const value_ast: ?astpos = if (eq(kind, "~")) null else args[args.len - 1];

    if (sc.struct_id) |id| if (!constant) return s.declareField(sc, a, id, name, declared, value_ast);
    // a variable declared any takes its value's type
    const typed: ?typeid = if (declared == s.t.any) null else declared;
    if (declared == s.t.any and value_ast == null) return s.fail(a, "NO_DEFAULT", "an any variable takes its value's type", .{});

    // x ~T = v and x ~= v: x is declared, then the = in scope gives it v
    if (!constant and value_ast != null) {
        const f = try s.bindingValue(a, lookup(sc, "=").?);
        if (!(f.type == s.t.builtin and @as(Builtin, @fromBackingInt(@intCast(asU32(f)))) == .set)) {
            const r = try s.lower(b, sc, value_ast.?, typed);
            const t = typed orelse try s.unconst(try s.heldType(b, r));
            // a reference is bound where it is declared: nothing to assign
            if (s.isRef(t)) {
                _ = try s.declareStorage(b, sc, a, name_ast, name, t, try s.coerce(b, value_ast.?, r, t), false);
                return s.voidRes();
            }
            const target = try s.declareStorage(b, sc, a, name_ast, name, t, null, false);
            const pair = [_]Arg{ .{ .res = .{ .res = target, .at = name_ast } }, .{ .res = .{ .res = r, .at = value_ast.? } } };
            _ = try s.callValue(b, sc, a, f, &pair, null);
            return s.voidRes();
        }
    }

    var value: ?Ref = null;
    var t: typeid = undefined;
    if (value_ast) |va| {
        const r = try s.lower(b, sc, va, declared);
        // without a type: the held type, references included; a copy of a constant isn't constant
        t = typed orelse try s.unconst(try s.heldType(b, r));
        value = try s.coerce(b, va, r, t);
    } else t = declared.?;

    if (constant and value.? == .value) {
        try s.bind(sc, name_ast, name, .{ .value = value.?.value });
        return s.voidRes();
    }
    _ = try s.declareStorage(b, sc, a, name_ast, name, t, value, constant);
    return s.voidRes();
}

// a declared variable's storage, holding value if there is one; its place
fn declareStorage(s: *Sema, b: *Block, sc: *Scope, a: astpos, name_ast: astpos, name: []const u8, t: typeid, value: ?Ref, constant: bool) Error!Res {
    if (!constant and (s.isComptime(t) or b.func == null)) {
        const start = if (value) |v| switch (v) {
            .value => |x| x,
            .inst => return s.fail(a, "RUNTIME_AT_COMPILE_TIME", "{s} is compile-time but its value is runtime", .{name}),
        } else try s.zero(a, t);
        const addr = try s.comptimeMem(b, a, .{ .type = t, .bytes = start.bytes });
        try s.bind(sc, name_ast, name, .{ .mem = .{ .addr = addr, .type = t } });
        return .{ .place = .{ .value = try s.vAddr(try s.ptrTo(t), addr) } };
    }
    if (value == null and s.isRef(t)) return s.fail(a, "NO_DEFAULT", "a reference refers to something", .{});
    // in a function a runtime constant is just its value; a reference is constant
    if (!sc.file and (constant or s.isRef(t))) {
        try s.bind(sc, name_ast, name, .{ .rt = .{ .ref = value.?, .func = b.func.? } });
        return .{ .val = value.? };
    }
    var place: Place = .{ .where = undefined, .type = if (constant and !s.isRef(t)) try s.constT(t) else t };
    if (sc.file) {
        place.where = .{ .global = @intCast(s.globals.items.len) };
        try s.globals.append(s.arena, .{ .name = try s.arena.dupe(u8, name), .type = t });
    } else {
        const r = try s.emit(b, a, try s.ptrTo(t), .{ .alloc = try s.arena.dupe(u8, name) });
        place.where = .{ .local = .{ .func = b.func.?, .inst = r.inst } };
    }
    if (value) |v| _ = try s.emit(b, a, s.t.void, .{ .store = .{ .place = try s.placeAddr(b, a, place), .value = v } });
    try s.bind(sc, name_ast, name, .{ .place = place });
    return .{ .place = try s.placeAddr(b, a, place) };
}

// a field of the struct being declared
fn declareField(s: *Sema, sc: *Scope, a: astpos, id: u32, name: []const u8, declared: ?typeid, value_ast: ?astpos) Error!Res {
    const info = &s.structs.items[id];
    var default: ?Value = null;
    if (value_ast) |va| default = try s.coerceValue(sc, va, declared);
    const t = declared orelse default.?.type;
    if (t == s.t.any) return s.fail(a, "FIELD_ANY", "a struct is a layout: {s} needs a type", .{name});
    for (info.fields.items) |f| if (eq(f.name, name)) return s.fail(a, "REDECLARED", "{s}", .{name});
    try info.fields.append(s.arena, .{ .name = try s.arena.dupe(u8, name), .type = t, .default = default });
    try info.members.append(s.arena, info.fields.items[info.fields.items.len - 1].name);
    const fields = try s.arena.alloc(Pool.StructField, info.fields.items.len);
    for (fields, info.fields.items) |*f, x| f.* = .{ .name = try s.pool.string(x.name), .type = x.type };
    try Pool.helpers.structure_set(s.pool, info.type, fields);
    return s.voidRes();
}
// a compile-time value, as type t
fn coerceValue(s: *Sema, sc: *Scope, a: astpos, t: ?typeid) Error!Value {
    var cb: Block = .{ .func = null };
    return (try s.lowerValue(&cb, sc, a, t)).value;
}

// the value of a declaration without one
fn zero(s: *Sema, at: astpos, t: typeid) Error!Value {
    if (t == s.t.ast or t == s.t.inlineast) return s.vAst(0);
    if (t == s.t.int) return s.vInt(0);
    if (t == s.t.type) return s.vType(s.t.void);
    if (s.isRef(t) or t == s.t.@"fn" or t == s.t.builtin or t == s.t.any)
        return s.fail(at, "NO_DEFAULT", "{f} has no default value", .{s.fmtType(t)});
    // runtime types start zeroed; a struct's fields start at their defaults
    const size = (try s.layoutOf(at, t)).size;
    const out = try s.arena.alloc(u8, size);
    @memset(out, 0);
    if (s.structOf(try s.unconst(t))) |st| for (st.fields, 0..) |f, i| {
        const fv = try s.zero(at, f.type);
        const off = s.pool.offset_of(t, i) catch unreachable;
        @memcpy(out[off..][0..fv.bytes.len], fv.bytes);
    };
    return .{ .type = t, .bytes = out };
}

// target = value: yields the target
fn lowerAssign(s: *Sema, b: *Block, sc: *Scope, a: astpos, args: []const astpos) Error!Res {
    const lhs = try s.lower(b, sc, args[0], null);
    if (lhs == .val and !s.isRef(s.typeOf(b.func, lhs.val))) return s.fail(args[0], "ASSIGN_CONST", "a constant", .{});
    const target = try s.asPlace(b, args[0], lhs);
    const t = try s.heldType(b, target);
    if (s.isConst(t)) return s.fail(args[0], "ASSIGN_CONST", "a constant", .{});
    try s.store(b, a, target, try s.lowerValue(b, sc, args[1], t));
    return target;
}
fn store(s: *Sema, b: *Block, at: astpos, target: Res, r: Ref) Error!void {
    const addr = target.place;
    if (knownAddr(addr)) |p| {
        if (b.branch > s.memBranch(p)) return s.fail(at, "COMPTIME_STORE_IN_RUNTIME_BRANCH", "the variable is compile-time", .{});
        const v = switch (r) {
            .value => |v| v,
            .inst => return s.fail(at, "RUNTIME_AT_COMPILE_TIME", "the variable is compile-time", .{}),
        };
        @memcpy(p[0..v.bytes.len], v.bytes);
        return;
    }
    _ = try s.emit(b, at, s.t.void, .{ .store = .{ .place = addr, .value = r } });
}

// left |> body: `_` is left, the place itself when left is one
fn lowerPipe(s: *Sema, b: *Block, sc: *Scope, a: astpos, args: []const astpos, dest: ?typeid) Error!Res {
    const left = try s.lower(b, sc, args[0], null);
    const inner = try s.newScope(sc);
    var bnd: Binding = undefined;
    switch (left) {
        .place => |addr| bnd = if (addr == .value)
            .{ .value = (try s.asRef(b, a, addr)).value }
        else
            .{ .rt = .{ .ref = try s.asRef(b, a, addr), .func = b.func.? } },
        .val => |x| switch (x) {
            .value => |v| bnd = .{ .value = v },
            .inst => if (s.isRef(s.typeOf(b.func, x))) {
                bnd = .{ .rt = .{ .ref = x, .func = b.func.? } };
            } else {
                // a temporary, so _ is a place
                const tmp = try s.temporary(b, a, s.typeOf(b.func, x));
                try s.store(b, a, tmp, x);
                bnd = .{ .rt = .{ .ref = try s.asRef(b, a, tmp.place), .func = b.func.? } };
            },
        },
    }
    try s.bind(inner, a, "_", bnd);
    return s.lower(b, inner, args[1], dest);
}
// an address as a reference to what is there
fn asRef(s: *Sema, b: *Block, at: astpos, addr: Ref) Error!Ref {
    return s.retypeValue(b, at, addr, try s.refT(try s.pointee(s.typeOf(b.func, addr))));
}

// [a, b], [x = a, y = b]: built against the destination's type
fn lowerList(s: *Sema, b: *Block, sc: *Scope, a: astpos, items: []const astpos, dest: ?typeid) Error!Res {
    const to = dest orelse return s.fail(a, "NO_DESTINATION", "a list needs a type to build", .{});
    if (to == s.t.any) return s.lowerTuple(b, sc, a, items);
    const t = try s.unconst(to);
    if (s.arrayOf(t)) |arr| {
        if (items.len != arr.len) return s.fail(a, "ARRAY_COUNT", "{f} has {d} elements, got {d}", .{ s.fmtType(t), arr.len, items.len });
        const elems = try s.arena.alloc(Ref, items.len);
        for (elems, items) |*e, x| e.* = try s.lowerValue(b, sc, x, arr.elem);
        return .{ .val = try s.aggregate(b, a, t, elems) };
    }
    const st = s.structOf(t) orelse return s.fail(a, "TYPE_MISMATCH", "a list can't build {f}", .{s.fmtType(t)});
    if (st.id == tuple_id) {
        if (items.len != st.fields.len) return s.fail(a, "ARRAY_COUNT", "{d} elements, got {d}", .{ st.fields.len, items.len });
        const elems = try s.arena.alloc(Ref, items.len);
        for (elems, items, st.fields) |*e, x, f| e.* = try s.lowerValue(b, sc, x, f.type);
        return .{ .val = try s.aggregate(b, a, t, elems) };
    }
    const info = s.structs.items[st.id];
    const elems = try s.arena.alloc(?Ref, st.fields.len);
    @memset(elems, null);
    // elements in source order: all by position, or all by name
    var next: usize = 0;
    var named = false;
    for (items, 0..) |x, n| {
        const by_name = try s.namedElement(x);
        if (n > 0 and named != (by_name != null)) return s.fail(x, "MIXED_ELEMENTS", "give every field by name or none", .{});
        named = by_name != null;
        var i: usize = undefined;
        var value_ast = x;
        if (by_name) |e| {
            const name = try s.memberName(sc, e.name);
            i = s.fieldIndex(t, name) orelse return s.fail(e.name, "NO_SUCH_MEMBER", "{f} has no {s}", .{ s.fmtType(t), name });
            value_ast = e.value;
        } else {
            if (next >= st.fields.len) return s.fail(x, "TOO_MANY_ELEMENTS", "{f} has {d} fields", .{ s.fmtType(t), st.fields.len });
            i = next;
            next += 1;
        }
        if (elems[i] != null) return s.fail(x, "FIELD_GIVEN_TWICE", "{s}", .{info.fields.items[i].name});
        elems[i] = try s.lowerValue(b, sc, value_ast, st.fields[i].type);
    }
    const done = try s.arena.alloc(Ref, st.fields.len);
    for (done, elems, info.fields.items) |*d, e, f| d.* = e orelse
        if (f.default) |v| Ref{ .value = v } else return s.fail(a, "MISSING_FIELD", "{s} has no value and no default", .{f.name});
    return .{ .val = try s.aggregate(b, a, t, done) };
}

// a list reaching `any`: a tuple of its elements' types. An @int beside
// runtime integers takes their type (the wider one).
fn lowerTuple(s: *Sema, b: *Block, sc: *Scope, a: astpos, items: []const astpos) Error!Res {
    const elems = try s.arena.alloc(Ref, items.len);
    var peer: ?typeid = null;
    var runtime = false;
    for (elems, items) |*e, x| {
        e.* = try s.rvalue(b, x, try s.lower(b, sc, x, s.t.any));
        const et = try s.unconst(s.typeOf(b.func, e.*));
        runtime = runtime or e.* == .inst;
        if (s.isInt(et) and e.* == .inst) peer = if (peer) |p| (if (s.intInfo(p).?.bits >= s.intInfo(et).?.bits) p else et) else et;
    }
    const types = try s.arena.alloc(typeid, items.len);
    for (elems, types, items) |*e, *t, x| {
        if (runtime and e.* == .value and e.value.type == s.t.int) {
            const p = peer orelse return s.fail(x, "COMPTIME_STRUCT_RUNTIME_FIELD", "an @int beside runtime values that aren't integers", .{});
            e.* = try s.coerce(b, x, .{ .val = e.* }, p);
        }
        t.* = try s.unconst(s.typeOf(b.func, e.*));
        if (runtime and s.isComptime(t.*)) return s.fail(x, "TUPLE_CANNOT_MIX", "compile-time and runtime elements", .{});
        e.* = try s.retypeValue(b, x, e.*, t.*);
    }
    return .{ .val = try s.aggregate(b, a, try s.tupleType(types), elems) };
}

// a struct or array from its fields: known when they all are
fn aggregate(s: *Sema, b: *Block, at: astpos, t: typeid, elems: []const Ref) Error!Ref {
    for (elems) |e| if (e == .inst) return s.emit(b, at, t, .{ .aggregate = elems });
    const out = try s.arena.alloc(u8, (try s.layoutOf(at, t)).size);
    @memset(out, 0);
    var off: usize = 0;
    for (elems, 0..) |e, i| {
        if (s.structOf(t) != null) off = s.pool.offset_of(t, i) catch unreachable;
        @memcpy(out[off..][0..e.value.bytes.len], e.value.bytes);
        off += e.value.bytes.len;
    }
    return .{ .value = .{ .type = t, .bytes = out } };
}

fn astValue(s: *Sema, sc: *Scope, a: astpos) Error!astpos {
    const v = try s.comptimeValue(sc, a);
    if (v.type != s.t.ast and v.type != s.t.inlineast)
        return s.fail(a, "EXPECTED_AST", "got a value of type {f}", .{s.fmtType(v.type)});
    return asU32(v);
}

// 'x: x as data, with `y replaced by the AST y holds, ..`y spliced into the
// surrounding call, and \y inserted as written
fn quote(s: *Sema, sc: *Scope, a: astpos) Error!astpos {
    if (s.node(a) != .call) return a;
    if (s.headIs(a, "`")) return s.astValue(sc, (try s.children(a))[1]);
    if (s.headIs(a, "\\")) return (try s.children(a))[1];
    var parts: List(Asth.Ast) = .empty;
    for (try s.children(a)) |k| {
        if (!s.headIs(k, "..")) {
            try parts.append(s.arena, s.node(try s.quote(sc, k)));
            continue;
        }
        const spliced = try s.quote(sc, (try s.children(k))[1]);
        if (s.node(spliced) == .null) continue; // nothing to splice
        if (s.node(spliced) != .call) return s.fail(k, "SPLICE", "only a call's children can be spliced", .{});
        for (try s.children(spliced)) |x| try parts.append(s.arena, s.node(x));
    }
    return s.makeCall(parts.items, s.node(a).call.pos);
}

// ---- builtins

fn argCount(s: *Sema, a: astpos, args: []const astpos, n: usize) Error!void {
    if (args.len != n) return s.fail(a, "ARG_COUNT", "expected {d} arguments, got {d}", .{ n, args.len });
}
fn known(v: Value) Res {
    return .{ .val = .{ .value = v } };
}

fn callBuiltin(s: *Sema, b: *Block, sc: *Scope, a: astpos, bi: Builtin, args: []const astpos, dest: ?typeid) Error!Res {
    const scalar: ?TypeBase = switch (bi) {
        .void => .void,
        .bool => .bool,
        .type => .type,
        .ast => .ast,
        .inlineast => .inlineast,
        .any => .any,
        .int => .int,
        .schar => .cschar,
        .sshort => .csshort,
        .sint => .csint,
        .slong => .cslong,
        .slonglong => .cslonglong,
        .uchar => .cuchar,
        .ushort => .cushort,
        .uint => .cuint,
        .ulong => .culong,
        .ulonglong => .culonglong,
        else => null,
    };
    if (scalar) |base| {
        try s.argCount(a, args, 0);
        return known(try s.vType(try Pool.helpers.scalar(s.pool, base)));
    }
    switch (bi) {
        .@"fn" => {
            try s.argCount(a, args, 3);
            // syntax, but an unquote written there fires now
            const id: u32 = @intCast(s.fns.items.len);
            try s.fns.append(s.arena, .{
                .params = try s.fired(sc, args[0]),
                .ret = try s.fired(sc, args[1]),
                .body = try s.fired(sc, args[2]),
                .scope = sc,
            });
            return known(.{ .type = s.t.@"fn", .bytes = try s.bytes(id) });
        },
        .add, .sub, .mul, .div, .mod, .eq, .ne, .lt, .gt, .le, .ge, .band, .bor, .bxor, .shl, .shr, .xor, .cmp => {
            try s.argCount(a, args, 2);
            const l = try s.rvalue(b, args[0], try s.lower(b, sc, args[0], null));
            const r = try s.rvalue(b, args[1], try s.lower(b, sc, args[1], null));
            return .{ .val = try s.binop(b, a, bi, l, r) };
        },
        .@"and", .@"or" => {
            try s.argCount(a, args, 2);
            return .{ .val = try s.shortCircuit(b, sc, a, bi, args[0], args[1]) };
        },
        .as => {
            try s.argCount(a, args, 2);
            const t = try s.lowerType(sc, args[1]);
            // t is the operand's destination, so [a, b] as T builds a T
            return .{ .val = try s.cast(b, a, try s.rvalue(b, args[0], try s.lower(b, sc, args[0], t)), t) };
        },
        .arr => {
            try s.argCount(a, args, 2);
            const n = try s.toIndex(args[0], try s.comptimeValue(sc, args[0]));
            return known(try s.vType(try Pool.helpers.array(s.pool, n, try s.lowerType(sc, args[1]))));
        },
        .fnptr => {
            try s.argCount(a, args, 2);
            if (!s.headIs(args[0], "[]")) return s.fail(args[0], "FNPTR_PARAMS", "the parameter types are a [...] list", .{});
            const ps = (try s.children(args[0]))[1..];
            const params = try s.arena.alloc(typeid, ps.len);
            for (params, ps) |*t, p| t.* = try s.runtimeType(p, try s.lowerType(sc, p));
            const ret = try s.runtimeType(args[1], try s.lowerType(sc, args[1]));
            return known(try s.vType(try Pool.helpers.function(s.pool, .fnptr, params, ret)));
        },
        .ptr, .refT => {
            try s.argCount(a, args, 1);
            const t = try s.lowerType(sc, args[0]);
            if (s.isRef(t)) return s.fail(a, "REF_OF_REF", "{f} is already a reference", .{s.fmtType(t)});
            return known(try s.vType(if (bi == .ptr) try s.ptrTo(t) else try s.refT(t)));
        },
        .@"comptime" => {
            try s.argCount(a, args, 1);
            const t = try s.lowerType(sc, args[0]);
            var mask = s.ty(t).maks;
            mask.@"comptime" = true;
            return known(try s.vType(try s.withMask(t, mask)));
        },
        .@"struct" => {
            try s.argCount(a, args, 1);
            return known(try s.vType(try s.lowerStruct(sc, args[0])));
        },
        .this => {
            try s.argCount(a, args, 0);
            var at: ?*Scope = sc;
            while (at) |x| : (at = x.parent) if (x.struct_id) |id| return known(try s.vType(s.structs.items[id].type));
            return s.fail(a, "THIS_OUTSIDE_STRUCT", "@this() is the struct being declared", .{});
        },
        .ctype => {
            try s.argCount(a, args, 1);
            return known(try s.vType(try Pool.helpers.ctag(s.pool, try s.stringArg(sc, args[0]))));
        },
        .returntype => {
            try s.argCount(a, args, 0);
            var at: ?*Scope = sc;
            while (at) |x| : (at = x.parent) if (x.function) return known(try s.vType(x.ret orelse s.t.any));
            return s.fail(a, "RETURNTYPE_OUTSIDE_FUNCTION", "", .{});
        },
        .yielded => {
            try s.argCount(a, args, 0);
            var at: ?*Scope = sc;
            while (at) |x| : (at = x.parent) {
                if (x.function) break;
                if (!x.deferred) continue;
                // for @typeof, a placeholder of its type
                const y = x.yielded.?;
                if (b.typeof_only and !(y == .val and y.val == .value))
                    return .{ .val = try s.emit(b, a, x.yielded_type, .{ .arg = 0 }) };
                return y;
            }
            return s.fail(a, "YIELDED_OUTSIDE_DEFER", "@yielded() is the value a deferring scope yielded", .{});
        },
        .@"if" => {
            if (args.len != 2 and args.len != 3) try s.argCount(a, args, 3);
            const c = try s.condition(b, sc, args[0]);
            if (c == .value) {
                const pick: ?astpos = if (c.value.bytes[0] != 0) args[1] else if (args.len == 3) args[2] else null;
                if (pick) |p| _ = try s.lower(b, try s.newScope(sc), p, null);
                return s.voidRes();
            }
            var then: Block = .{ .func = b.func, .branch = b.branch + 1 };
            _ = try s.lower(&then, try s.newScope(sc), args[1], null);
            var other: Block = .{ .func = b.func, .branch = b.branch + 1 };
            if (args.len == 3) _ = try s.lower(&other, try s.newScope(sc), args[2], null);
            _ = try s.emit(b, a, s.t.void, .{ .cond = .{ .cond = c, .then = then.body.items, .@"else" = other.body.items } });
            return s.voidRes();
        },
        .loop => {
            try s.argCount(a, args, 1);
            var body: Block = .{ .func = b.func, .branch = b.branch + 1 };
            const ls = try s.newScope(sc);
            ls.loop = true;
            _ = try s.lower(&body, ls, args[0], null);
            _ = try s.emit(b, a, s.t.void, .{ .loop = body.body.items });
            return s.voidRes();
        },
        .@"break", .@"continue" => {
            try s.argCount(a, args, 0);
            // what each scope on the way out deferred runs first
            var at: ?*Scope = sc;
            while (at) |x| : (at = x.parent) {
                if (x.deferred) return s.fail(a, "DEFER_CONTROL", "deferred code can't leave its scope", .{});
                if (x.function) break;
                try s.runDefers(b, x, s.voidRes());
                if (x.loop) {
                    _ = try s.emit(b, a, s.t.void, if (bi == .@"break") .brk else .cont);
                    return s.voidRes();
                }
            }
            return s.fail(a, "LOOP_CONTROL_OUTSIDE_LOOP", "@{s} needs a loop in this function", .{@tagName(bi)});
        },
        .cwhile => {
            // a scope is never half expanded: the condition decides before each whole pass
            try s.argCount(a, args, 2);
            var n: usize = 0;
            while (true) : (n += 1) {
                if (n > 1_000_000) return s.fail(a, "CWHILE_LIMIT", "a million passes", .{});
                const c = try s.condition(b, sc, args[0]);
                if (c != .value) return s.fail(args[0], "RUNTIME_AT_COMPILE_TIME", "@cwhile's condition is compile-time", .{});
                if (c.value.bytes[0] == 0) break;
                _ = try s.lower(b, try s.newScope(sc), args[1], null);
            }
            return s.voidRes();
        },
        .@"defer" => {
            try s.argCount(a, args, 1);
            try sc.defers.append(s.arena, args[0]);
            return s.voidRes();
        },
        .where => {
            try s.argCount(a, args, 1);
            const p = try s.asPlace(b, args[0], try s.lower(b, sc, args[0], null));
            // a reference's address is a plain pointer to what it refers to
            const t = s.typeOf(b.func, p.place);
            if (s.isRef(t)) return .{ .val = try s.retypeValue(b, args[0], p.place, try s.ptrTo(try s.pointee(t))) };
            return .{ .val = p.place };
        },
        .at => {
            try s.argCount(a, args, 1);
            const p = try s.rvalue(b, args[0], try s.lower(b, sc, args[0], null));
            if (!s.isPtr(s.typeOf(b.func, p))) return s.fail(a, "NOT_POINTER", "got {f}", .{s.fmtType(s.typeOf(b.func, p))});
            return .{ .place = p };
        },
        .ref => {
            try s.argCount(a, args, 1);
            const r = try s.lower(b, sc, args[0], null);
            const t = try s.heldType(b, r);
            return .{ .val = try s.coerce(b, args[0], r, try s.refT(if (s.isRef(t)) try s.pointee(t) else t)) };
        },
        .typeof => {
            try s.argCount(a, args, 1);
            // lowered for its type, into a function that never runs
            var scratch: Block = .{ .func = try s.scratchFunc(), .branch = b.branch + 1, .typeof_only = true };
            const t = try s.heldType(&scratch, try s.lower(&scratch, sc, args[0], null));
            return known(try s.vType(try s.unconst(if (s.isRef(t)) try s.pointee(t) else t)));
        },
        .sizeof, .alignof => {
            try s.argCount(a, args, 1);
            const l = try s.layoutOf(a, try s.lowerType(sc, args[0]));
            return known(try s.vInt(if (bi == .sizeof) l.size else l.alignment));
        },
        .offsetof => {
            try s.argCount(a, args, 2);
            const t = try s.lowerType(sc, args[0]);
            const name = try s.memberName(sc, args[1]);
            const i = s.fieldIndex(t, name) orelse return s.fail(args[1], "NO_SUCH_MEMBER", "{f} has no {s}", .{ s.fmtType(t), name });
            return known(try s.vInt(s.pool.offset_of(t, i) catch return s.fail(a, "NO_LAYOUT", "", .{})));
        },
        .countof => {
            try s.argCount(a, args, 1);
            const v = try s.comptimeValue(sc, args[0]);
            if (v.type == s.t.type) if (s.arrayOf(asU32(v))) |arr| return known(try s.vInt(arr.len));
            return known(try s.vInt((try s.typeParts(args[0], v)).len));
        },
        .fieldtype => {
            try s.argCount(a, args, 2);
            const ps = try s.typeParts(args[0], try s.comptimeValue(sc, args[0]));
            const i = try s.toIndex(args[1], try s.comptimeValue(sc, args[1]));
            if (i >= ps.len) return s.fail(args[1], "INDEX_OUT_OF_BOUNDS", "{d} fields", .{ps.len});
            return known(try s.vType(ps[i]));
        },
        .fieldname => {
            try s.argCount(a, args, 2);
            const t = try s.lowerType(sc, args[0]);
            const ms = try s.members(args[0], t) orelse return s.fail(args[0], "TYPE_MISMATCH", "a struct, not {f}", .{s.fmtType(t)});
            const i = try s.toIndex(args[1], try s.comptimeValue(sc, args[1]));
            if (i >= ms.len) return s.fail(args[1], "INDEX_OUT_OF_BOUNDS", "{d} members", .{ms.len});
            return known(try s.vAst(try s.makeId(ms[i].name)));
        },
        // an array's member, or what a pointer points to
        .membertype => {
            try s.argCount(a, args, 1);
            const t = try s.lowerType(sc, args[0]);
            if (s.arrayOf(t)) |arr| return known(try s.vType(arr.elem));
            if (s.isPtr(t)) return known(try s.vType(try s.pointee(t)));
            return s.fail(args[0], "TYPE_MISMATCH", "an array or a pointer, not {f}", .{s.fmtType(t)});
        },
        // a variable's: its type stripped of these, so they're asked of it
        .ptrlevel, .isreferance, .isconst, .isvolatile, .iscomptime => {
            try s.argCount(a, args, 1);
            var scratch: Block = .{ .func = try s.scratchFunc(), .branch = b.branch + 1, .typeof_only = true };
            const r = try s.lower(&scratch, sc, args[0], null);
            const held = try s.heldType(&scratch, r);
            if (bi == .isreferance) return known(try s.vBool(s.isRef(held)));
            // known: a known value, or compile-time memory
            if (bi == .iscomptime) return known(try s.vBool(switch (r) {
                .val => |x| x == .value,
                .place => |x| knownAddr(x) != null,
            }));
            const t = if (s.isRef(held)) try s.pointee(held) else held;
            return known(switch (bi) {
                .ptrlevel => try s.vInt(s.ty(t).maks.ptr),
                // a value that isn't a place can't be assigned either
                .isconst => try s.vBool(s.isConst(t) or (r == .val and !s.isRef(held))),
                else => try s.vBool(s.ty(t).maks.@"volatile"),
            });
        },
        .len => {
            try s.argCount(a, args, 1);
            return known(try s.vInt(switch (try s.sequence(b, args[0], try s.lower(b, sc, args[0], null))) {
                .ast => |x| (try s.children(x)).len,
                .array => |arr| arr.len,
                .tuple => |fields| fields.len,
            }));
        },
        .get => {
            if (args.len != 2 and args.len != 3) try s.argCount(a, args, 3);
            const recv = try s.lower(b, sc, args[0], null);
            const x = switch (try s.sequence(b, args[0], recv)) {
                .ast => |x| x,
                .array => |arr| {
                    try s.argCount(a, args, 2);
                    return s.arrayGet(b, sc, a, recv, arr.len, arr.elem, args[1]);
                },
                .tuple => |fields| {
                    try s.argCount(a, args, 2);
                    return s.tupleGet(b, sc, a, recv, fields, args[1]);
                },
            };
            const kids = try s.children(x);
            const ia = try s.toBig(try s.comptimeValue(sc, args[1]));
            if (args.len == 2) {
                const i = ia.toInt(usize) catch return known(try s.vAst(0));
                return known(try s.vAst(if (i < kids.len) kids[i] else 0));
            }
            // a slice is a call of those children, reversed when start > end
            const ea = try s.toBig(try s.comptimeValue(sc, args[2]));
            const start = ia.toInt(usize) catch return known(try s.vAst(0));
            const end = ea.toInt(usize) catch return known(try s.vAst(0));
            // the start is in it and the end isn't, either way round
            var parts: List(Asth.Ast) = .empty;
            if (start <= end) {
                if (end > kids.len) return known(try s.vAst(0));
                for (kids[start..end]) |k| try parts.append(s.arena, s.node(k));
            } else {
                if (start >= kids.len) return known(try s.vAst(0));
                var i = start;
                while (i > end) : (i -= 1) try parts.append(s.arena, s.node(kids[i]));
            }
            return known(try s.vAst(try s.makeCall(parts.items, s.posOf(x))));
        },
        .ast_stringeq => {
            try s.argCount(a, args, 2);
            const x = try s.astValue(sc, args[0]);
            const str = try s.stringArg(sc, args[1]);
            return known(try s.vBool(s.node(x) != .call and s.node(x) != .null and eq(s.text(x), str)));
        },
        .apply => {
            try s.argCount(a, args, 2);
            const f = try s.comptimeValue(sc, args[0]);
            const xs = try s.astValue(sc, args[1]);
            var parts: List(Asth.Ast) = .empty;
            for (try s.children(xs)) |k| {
                const one = [_]Arg{.{ .res = .{ .res = known(try s.vAst(k)), .at = args[1] } }};
                var cb: Block = .{ .func = null };
                const r = (try s.load(&cb, a, try s.callValue(&cb, sc, a, f, &one, null))).value;
                if (r.type != s.t.ast) return s.fail(args[0], "EXPECTED_AST", "@apply's function returns ASTs", .{});
                try parts.append(s.arena, s.node(asU32(r)));
            }
            return known(try s.vAst(try s.makeCall(parts.items, s.posOf(xs))));
        },
        .gensym => {
            if (args.len > 1) try s.argCount(a, args, 1);
            // the prefix is a name as written, as in cshl: @gensym(tmp)
            if (args.len == 1 and s.node(args[0]) != .id) return s.fail(args[0], "EXPECTED_NAME", "a gensym prefix is a name", .{});
            const prefix = if (args.len == 1) s.text(args[0]) else "g";
            s.gensyms += 1;
            return known(try s.vAst(try s.makeId(try std.fmt.allocPrint(s.arena, "{s}#{d}", .{ prefix, s.gensyms }))));
        },
        .id => {
            try s.argCount(a, args, 1);
            return known(try s.vAst(try s.makeId(try s.stringArg(sc, args[0]))));
        },
        .compileError => {
            try s.argCount(a, args, 1);
            return s.fail(a, "COMPILE_ERROR", "{s}", .{try s.stringArg(sc, args[0])});
        },
        .log => {
            try s.argCount(a, args, 1);
            const outer = .{ s.log_call, s.log_expansion };
            s.log_call = args[0];
            s.log_expansion = null;
            const r = try s.lower(b, sc, args[0], dest);
            const expansion = s.log_expansion;
            s.log_call, s.log_expansion = outer;
            const t = try s.heldType(b, r);
            const x = args[0];
            // a known value, or one in compile-time memory, is shown
            const v: ?Value = switch (r) {
                .val => |v| if (v == .value) v.value else null,
                .place => |p| if (p == .value) (try s.load(b, x, r)).value else null,
            };
            var line: std.Io.Writer.Allocating = .init(s.arena);
            const w = &line.writer;
            if (expansion) |e| w.print("expands to {f}", .{s.fmtValue(e)}) catch {};
            if (t != s.t.void) {
                if (expansion != null) w.writeAll(", giving ") catch {};
                if (v) |known_v|
                    w.print("{f} ~{f}", .{ s.fmtValue(known_v), s.fmtType(t) }) catch {}
                else
                    w.print("~{f} at runtime", .{s.fmtType(t)}) catch {};
            } else if (expansion == null) w.writeAll("void") catch {};
            std.debug.print("{f}log: {s}\n", .{ s.fmtAt(a), line.written() });
            return r;
        },
        .compiles => {
            try s.argCount(a, args, 1);
            var scratch: Block = .{ .func = b.func, .branch = b.branch };
            const ok = if (s.lower(&scratch, try s.newScope(sc), args[0], null)) |_| true else |e| switch (e) {
                error.Lower => false,
                else => return e,
            };
            s.err = null;
            return known(try s.vBool(ok));
        },
        .dot => {
            try s.argCount(a, args, 2);
            return s.lowerDot(b, sc, a, args[0], args[1]);
        },
        .set => {
            try s.argCount(a, args, 2);
            return s.lowerAssign(b, sc, a, args);
        },
        .raw => {
            // the operators as the builtins, whatever is declared outside
            try s.argCount(a, args, 1);
            const rs = try s.newScope(sc);
            for (operators) |o| try rs.names.put(s.arena, o[0], .{ .value = try s.vBuiltin(o[1]) });
            return s.lower(b, rs, args[0], dest);
        },
        .using => {
            try s.argCount(a, args, 1);
            const t = try s.lowerType(sc, args[0]);
            const ns = s.namespace(t) orelse return s.fail(args[0], "USING_NOT_STRUCT", "{f} has no namespace", .{s.fmtType(t)});
            var it = ns.names.iterator();
            while (it.next()) |e| try s.bind(sc, a, e.key_ptr.*, e.value_ptr.*);
            return s.voidRes();
        },
        .unbind => {
            try s.argCount(a, args, 1);
            const name = try s.memberName(sc, args[0]);
            if (!sc.names.remove(name)) return s.fail(args[0], "UNBOUND_ID", "{s} isn't bound in this scope", .{name});
            if (sc.struct_id) |id| {
                const ms = &s.structs.items[id].members;
                for (ms.items, 0..) |m, i| if (eq(m, name)) {
                    _ = ms.orderedRemove(i);
                    break;
                };
            }
            return s.voidRes();
        },
        .path => {
            if (args.len > 1) try s.argCount(a, args, 1);
            const src = s.srcOf(a) orelse return s.fail(a, "NO_SOURCE", "this code has no source file", .{});
            if (src.fileref == 0) return s.fail(a, "NO_SOURCE", "this code has no source file", .{});
            const file = s.ast.files.items[src.fileref].name;
            if (args.len == 0) return known(try s.vString(file));
            const name = try s.stringArg(sc, args[0]);
            const joined = if (std.fs.path.isAbsolute(name)) name else try std.fs.path.join(s.arena, &.{ std.fs.path.dirname(file) orelse ".", name });
            return known(try s.vString(try normalize(s.arena, joined)));
        },
        .import => {
            try s.argCount(a, args, 1);
            return known(try s.import(a, try s.stringArg(sc, args[0])));
        },
        .cinclude => {
            try s.argCount(a, args, 1);
            if (b.func != 0) return s.fail(a, "CINCLUDE_INSIDE_FUNCTION", "", .{});
            try s.c_includes.append(s.arena, try s.stringArg(sc, args[0]));
            return s.voidRes();
        },
        .cexpr => {
            try s.argCount(a, args, 2);
            return .{ .val = try s.emit(b, a, try s.lowerType(sc, args[0]), .{ .cexpr = try s.stringArg(sc, args[1]) }) };
        },
        else => return s.fail(a, "UNIMPLEMENTED", "@{s}", .{@tagName(bi)}),
    }
}

// @struct{...}: fields are its runtime declarations, its namespace the rest
fn lowerStruct(s: *Sema, sc: *Scope, written: astpos) Error!typeid {
    // @struct `x: the body is the AST x holds, as for an ast parameter
    const body = if (s.headIs(written, "`")) try s.astValue(sc, (try s.children(written))[1]) else written;
    const id: u32 = @intCast(s.structs.items.len);
    const ns = try s.newScope(sc);
    ns.struct_id = id;
    const t = try Pool.helpers.structure_new(s.pool, id);
    try s.structs.append(s.arena, .{ .scope = ns, .type = t });
    var cb: Block = .{ .func = null };
    const stmts = if (s.headIs(body, "{}")) (try s.children(body))[1..] else &[_]astpos{body};
    _ = try s.lowerStatements(&cb, ns, stmts, null);
    return t;
}

// a compile-time string argument
fn stringArg(s: *Sema, sc: *Scope, a: astpos) Error![]const u8 {
    const v = try s.comptimeValue(sc, a);
    const arr = s.arrayOf(v.type);
    if (arr == null or s.ty(arr.?.elem).type != .cschar)
        return s.fail(a, "EXPECTED_STRING", "got a value of type {f}", .{s.fmtType(v.type)});
    return v.bytes;
}

// a/./b/../c -> a/c
fn normalize(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    var parts: List([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |p| {
        if (eq(p, ".")) continue;
        if (eq(p, "..") and parts.items.len > 0 and !eq(parts.items[parts.items.len - 1], "..")) {
            _ = parts.pop();
            continue;
        }
        try parts.append(arena, p);
    }
    const joined = try std.mem.join(arena, "/", parts.items);
    if (path.len > 0 and path[0] == '/') return std.mem.concat(arena, u8, &.{ "/", joined });
    return if (joined.len == 0) "." else joined;
}

// a file's value is its last expression; each file is lowered once, its
// runtime code running in main where it is first imported
fn import(s: *Sema, a: astpos, path: []const u8) Error!Value {
    const gop = try s.imports.getOrPut(s.arena, path);
    if (gop.found_existing) return gop.value_ptr.* orelse s.fail(a, "IMPORT_CYCLE", "{s} imports itself", .{path});
    gop.key_ptr.* = try s.arena.dupe(u8, path);
    gop.value_ptr.* = null;
    const entry = Asth.Ast.parse(s.io, .{ .filename = try s.arena.dupeSentinel(u8, path, 0) }, s.ast) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return s.fail(a, "IMPORT_MISSING", "{s}", .{path}),
        error.SyntaxError => return s.fail(a, "PARSE", "syntax error at {f}", .{Asth.SrcFmt{ .state = s.ast, .src = s.ast.syntax_error.? }}),
        else => return s.fail(a, "IMPORT", "{s}: {t}", .{ path, e }),
    };
    const file = try s.arena.create(Scope);
    file.* = .{ .parent = s.root, .file = true };
    const r = try s.lowerStatements(s.main_block, file, (try s.children(entry))[1..], null);
    const v = switch (try s.load(s.main_block, entry, r)) {
        .value => |v| v,
        .inst => return s.fail(a, "IMPORT", "{s} ends in a runtime value", .{path}),
    };
    s.imports.putAssumeCapacity(path, v);
    return v;
}

// ---- operators

fn binop(s: *Sema, b: *Block, a: astpos, op: Builtin, l: Ref, r: Ref) Error!Ref {
    const compare = switch (op) {
        .eq, .ne, .lt, .gt, .le, .ge => true,
        else => false,
    };
    const lt = try s.unconst(s.typeOf(b.func, l));
    const rt = try s.unconst(s.typeOf(b.func, r));
    const lint = s.isNum(lt);
    const rint = s.isNum(rt);

    // equality of anything known, by value
    if ((op == .eq or op == .ne) and !(lint and rint) and l == .value and r == .value) {
        if (lt != rt) return s.fail(a, "TYPE_MISMATCH", "comparing {f} with {f}", .{ s.fmtType(lt), s.fmtType(rt) });
        return .{ .value = try s.vBool((try s.valueEql(l.value, r.value)) == (op == .eq)) };
    }
    // pointers compare by address
    if ((op == .eq or op == .ne) and s.isPtr(lt) and s.isPtr(rt)) {
        if (lt != rt) return s.fail(a, "TYPE_MISMATCH", "comparing {f} with {f}", .{ s.fmtType(lt), s.fmtType(rt) });
        return s.emit(b, a, s.t.bool, .{ .op = .{ .op = op, .lhs = l, .rhs = r } });
    }
    // shifts keep the left operand's type
    if (op == .shl or op == .shr) {
        if (!lint or !rint) return s.fail(a, "TYPE_MISMATCH", "{s} of {f} and {f}", .{ @tagName(op), s.fmtType(lt), s.fmtType(rt) });
        if (l == .value and r == .value) return .{ .value = try s.fold(a, op, lt, l.value, r.value) };
        if (lt == s.t.int) return s.fail(a, "RUNTIME_AT_COMPILE_TIME", "an @int shifted by a runtime amount", .{});
        return s.emit(b, a, lt, .{ .op = .{ .op = op, .lhs = l, .rhs = try s.coerce(b, a, .{ .val = r }, if (rt == s.t.int) lt else rt) } });
    }
    // the operand type: a literal takes the other side's type; of two
    // integer types the wider wins, unsigned at equal widths
    const t: typeid = if (lt == rt) lt else if (lt == s.t.int and rint) rt else if (rt == s.t.int and lint) lt else if (lint and rint) w: {
        const li = s.intInfo(lt).?;
        const ri = s.intInfo(rt).?;
        if (li.bits != ri.bits) break :w if (li.bits > ri.bits) lt else rt;
        break :w if (li.signedness == .unsigned) lt else rt;
    } else return s.fail(a, "TYPE_MISMATCH", "{s} of {f} and {f}", .{ @tagName(op), s.fmtType(lt), s.fmtType(rt) });
    const boolean = t == s.t.bool and (op == .eq or op == .ne or op == .xor or op == .band or op == .bor or op == .bxor);
    if (!s.isNum(t) and !boolean)
        return s.fail(a, "TYPE_MISMATCH", "{s} of {f}", .{ @tagName(op), s.fmtType(t) });
    if (op == .xor and !boolean) return s.fail(a, "TYPE_MISMATCH", "xor is of bools; bxor of integers", .{});

    if (op == .cmp and !s.isNum(t)) return s.fail(a, "TYPE_MISMATCH", "<=> of {f}", .{s.fmtType(t)});

    const lc = try s.coerce(b, a, .{ .val = l }, t);
    const rc = try s.coerce(b, a, .{ .val = r }, t);
    if (lc == .value and rc == .value) return .{ .value = try s.fold(a, op, t, lc.value, rc.value) };
    // <=> is -1, 0 or 1: an @int when known, a C int at runtime
    const result_t = if (compare) s.t.bool else if (op == .cmp) try Pool.helpers.scalar(s.pool, .csint) else t;
    return s.emit(b, a, result_t, .{ .op = .{ .op = op, .lhs = lc, .rhs = rc } });
}

pub fn fold(s: *Sema, a: astpos, op: Builtin, t: typeid, l: Value, r: Value) Error!Value {
    // pointers: by address
    if (s.isPtr(t)) return s.vBool(std.mem.eql(u8, l.bytes, r.bytes) == (op == .eq));
    if (s.ty(t).type == .bool) {
        const x = l.bytes[0] != 0;
        const y = r.bytes[0] != 0;
        return s.vBool(switch (op) {
            .eq => x == y,
            .ne, .xor, .bxor => x != y,
            .band => x and y,
            .bor => x or y,
            else => unreachable,
        });
    }
    const x = try s.toBig(l);
    const y = try s.toBig(r);
    var out = try big.int.Managed.init(s.arena);
    var xm = try x.toManaged(s.arena);
    var ym = try y.toManaged(s.arena);
    switch (op) {
        .add => try out.add(&xm, &ym),
        .sub => try out.sub(&xm, &ym),
        .mul => try out.mul(&xm, &ym),
        .div, .mod => {
            if (y.eqlZero()) return s.fail(a, "DIVIDE_BY_ZERO", "", .{});
            var rem = try big.int.Managed.init(s.arena);
            try out.divTrunc(&rem, &xm, &ym);
            if (op == .mod) out = rem;
        },
        .band => try out.bitAnd(&xm, &ym),
        .bor => try out.bitOr(&xm, &ym),
        .bxor => try out.bitXor(&xm, &ym),
        .shl, .shr => {
            // a negative count shifts the other way; past the width it's all gone
            const n = y.toInt(isize) catch std.math.maxInt(isize);
            const left = (op == .shl) == (n >= 0);
            const count: usize = @abs(n);
            if (t != s.t.int and count >= s.intInfo(t).?.bits) {
                if (!left and !x.positive) try out.set(-1);
            } else if (left) try out.shiftLeft(&xm, count) else try out.shiftRight(&xm, count);
        },
        .eq => return s.vBool(x.eql(y)),
        .ne => return s.vBool(!x.eql(y)),
        .lt => return s.vBool(x.order(y) == .lt),
        .gt => return s.vBool(x.order(y) == .gt),
        .le => return s.vBool(x.order(y) != .gt),
        .ge => return s.vBool(x.order(y) != .lt),
        .cmp => return s.vInt(@as(i8, switch (x.order(y)) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        })),
        else => unreachable,
    }
    return s.vBig(t, out.toConst());
}

// x as T: between integer types, or pointer types
fn cast(s: *Sema, b: *Block, a: astpos, x: Ref, to: typeid) Error!Ref {
    const from = s.typeOf(b.func, x);
    if (s.isNum(from) and s.isInt(to)) return s.coerce(b, a, .{ .val = x }, to);
    if (from == s.t.@"fn" and s.fnptrOf(to) != null) return s.coerce(b, a, .{ .val = x }, to);
    if (s.isPtr(from) and s.isPtr(to)) return s.retypeValue(b, a, x, to);
    if ((try s.unconst(from)) == (try s.unconst(to))) return s.retypeValue(b, a, x, to);
    return s.fail(a, "CANNOT_CAST", "{f} as {f}", .{ s.fmtType(from), s.fmtType(to) });
}

fn shortCircuit(s: *Sema, b: *Block, sc: *Scope, a: astpos, op: Builtin, lhs: astpos, rhs: astpos) Error!Ref {
    const l = try s.condition(b, sc, lhs);
    if (l == .value) {
        const decided = (l.value.bytes[0] != 0) == (op == .@"or");
        if (decided) return l;
        return s.condition(b, sc, rhs);
    }
    var sub: Block = .{ .func = b.func, .branch = b.branch + 1 };
    const r = try s.condition(&sub, sc, rhs);
    return s.emit(b, a, s.t.bool, .{ .short = .{ .op = op, .lhs = l, .rhs_body = sub.body.items, .rhs = r } });
}

// ---- calls

// Each parameter on its own: an ast parameter gets the syntax; a
// compile-time value goes into the instance key; `any` takes the argument's
// type; a runtime value becomes a real parameter. The body runs now (inlined
// at the call) when it must: at compile time, for an inline or compile-time
// return, or when an ast parameter or an `any` return leaves nothing to
// call at runtime. Otherwise the call goes to a cached runtime instance.
fn callFn(s: *Sema, b: *Block, sc: *Scope, a: astpos, fid: u32, given: []const Arg, dest: ?typeid) Error!Res {
    const f = s.fns.items[fid];
    const inst = try s.newScope(f.scope);
    inst.function = true;
    const infos = try s.paramInfos(f);
    const args = try s.matchArgs(a, inst, infos, given);
    var p = try s.bindParams(b, sc, a, inst, fid, infos, args);

    const ret = try s.lowerType(p.types, f.ret);
    inst.ret = if (ret == s.t.any) null else ret;
    const ret_comptime = ret == s.t.inlineast or (ret != s.t.any and s.isComptime(ret));
    // only arguments not known yet need a runtime call
    var unknown = false;
    for (p.runtime.items) |rp| unknown = unknown or rp.ref == .inst;
    const now = b.func == null or ret_comptime or p.known_ptr or (!unknown and (p.has_ast or ret == s.t.any));
    if (!now) return s.callInstance(b, a, f, fid, inst, ret, &p);

    // the same compile-time arguments give the same compile-time result
    const cacheable = !p.has_ast and !unknown and !p.known_ptr and ret != s.t.inlineast;
    if (cacheable) {
        for (p.runtime.items) |rp| try p.key.appendSlice(s.arena, rp.ref.value.bytes);
        if (s.comptime_results.get(p.key.items)) |v| return known(v);
    }
    const res = try s.runNow(b, sc, a, f, inst, ret, &p, dest);
    if (cacheable and res == .val and res.val == .value and s.isComptime(res.val.value.type))
        try s.comptime_results.put(s.arena, p.key.items, res.val.value);
    return res;
}

const ParamInfo = struct { name_ast: astpos, name: []const u8, type_ast: astpos, default: ?astpos };

// [a ~T, b ~U = default]
fn paramInfos(s: *Sema, f: Function) Error![]ParamInfo {
    if (!s.headIs(f.params, "[]")) return s.fail(f.params, "FN_PARAMS", "parameters are a [...] list", .{});
    const params = (try s.children(f.params))[1..];
    const infos = try s.arena.alloc(ParamInfo, params.len);
    for (params, infos) |p, *info| {
        const kids = try s.children(p);
        if (!(s.headIs(p, "~") and kids.len == 3) and !(s.headIs(p, "~=") and kids.len == 4))
            return s.fail(p, "FN_PARAMS", "a parameter is `name ~Type` or `name ~Type = default`", .{});
        info.* = .{ .name_ast = kids[1], .name = s.text(kids[1]), .type_ast = kids[2], .default = if (kids.len == 4) kids[3] else null };
    }
    return infos;
}

// arguments to parameters: by position, or by name; a lone ast or any
// parameter takes the whole list
fn matchArgs(s: *Sema, a: astpos, inst: *Scope, infos: []const ParamInfo, given: []const Arg) Error![]?Arg {
    const args = try s.arena.alloc(?Arg, infos.len);
    @memset(args, null);
    if (infos.len == 1 and given.len != 1) {
        const t = try s.lowerType(inst, infos[0].type_ast);
        if (t == s.t.ast or t == s.t.any) {
            var kids: List(Asth.Ast) = .empty;
            try kids.append(s.arena, s.node(try s.makeId("[]")));
            for (given) |g| switch (g) {
                .ast => |x| try kids.append(s.arena, s.node(x)),
                .res => return s.fail(a, "ARG_COUNT", "one parameter", .{}),
            };
            args[0] = .{ .ast = try s.makeCall(kids.items, s.posOf(a)) };
            return args;
        }
    }
    var next: usize = 0;
    for (given) |g| {
        // name ~~ v gives the parameter named name; name = v is an assignment
        if (g == .ast) if (try s.namedElement(g.ast)) |e| {
            const name = s.text(e.name);
            const n = for (infos, 0..) |info, i| {
                if (eq(info.name, name)) break i;
            } else return s.fail(e.name, "NO_SUCH_PARAMETER", "{s}", .{name});
            if (args[n] != null) return s.fail(e.name, "ARG_GIVEN_TWICE", "{s}", .{name});
            args[n] = .{ .ast = e.value };
            continue;
        };
        if (next >= infos.len) return s.fail(a, "ARG_COUNT", "expected {d} arguments, got {d}", .{ infos.len, given.len });
        args[next] = g;
        next += 1;
    }
    return args;
}

// name ~~ value: an argument or a field given by name, as a declaration says it
fn namedElement(s: *Sema, x: astpos) Error!?struct { name: astpos, value: astpos } {
    if (!s.headIs(x, "~~")) return null;
    const kids = try s.children(x);
    if (kids.len != 3) return s.fail(x, "NAMED_ELEMENT", "a named element is name ~~ value", .{});
    if (s.node(kids[1]) != .id) return s.fail(kids[1], "EXPECTED_NAME", "", .{});
    return .{ .name = kids[1], .value = kids[2] };
}

const RtParam = struct { name: []const u8, at: astpos, ref: Ref, type: typeid };
const Bound = struct {
    key: List(u8), // the instance: the function, then each parameter's type and compile-time value
    types: *Scope, // where parameter types and the return type are lowered
    runtime: List(RtParam) = .empty,
    has_ast: bool = false,
    known_ptr: bool = false, // a pointer into compile-time memory: the call happens now, every time
};

// each parameter by its kind: ast and compile-time ones are bound in inst,
// runtime ones collected; the types see the parameters before them, runtime
// ones as placeholders of their types
fn bindParams(s: *Sema, b: *Block, sc: *Scope, a: astpos, inst: *Scope, fid: u32, infos: []const ParamInfo, args: []const ?Arg) Error!Bound {
    var p: Bound = .{ .key = .empty, .types = try s.newScope(inst) };
    try p.key.appendSlice(s.arena, std.mem.asBytes(&fid));
    for (infos, args) |info, arg_opt| {
        const t = try s.lowerType(p.types, info.type_ast);
        if (t == s.t.ast or t == s.t.inlineast) {
            p.has_ast = true;
            const x: astpos = if (arg_opt) |arg| switch (arg) {
                .ast => |x| try s.astArgument(sc, x),
                .res => |r| try s.astOfRes(b, sc, r.res),
            } else if (info.default) |d| try s.astValue(inst, d) else return s.fail(a, "MISSING_ARGUMENT", "{s}", .{info.name});
            try s.bind(inst, info.name_ast, info.name, .{ .value = try s.vAst(x) });
            // a runtime instance is per AST, by its structure
            try s.keyAst(&p.key, x);
            continue;
        }
        const want: ?typeid = if (t == s.t.any) null else t;
        const given_at: astpos = if (arg_opt) |arg| switch (arg) {
            .ast => |x| x,
            .res => |x| x.at,
        } else a;
        const res: Res = if (arg_opt) |arg| switch (arg) {
            .ast => |x| try s.lower(b, sc, x, t),
            .res => |x| x.res,
        } else if (info.default) |d| try s.lower(b, inst, d, want) else return s.fail(a, "MISSING_ARGUMENT", "{s}", .{info.name});
        // @refT(@any()): a reference to a place of any type, which it has to be
        const r = if (s.isRef(t) and try s.pointee(t) == s.t.any) r: {
            const place = try s.asPlace(b, given_at, res);
            break :r try s.retypeValue(b, given_at, place.place, try s.refT(try s.heldType(b, place)));
        } else try s.coerce(b, given_at, res, want);
        if (r == .value and (s.isPtr(r.value.type) or s.isRef(r.value.type))) p.known_ptr = true;
        // a constant's value isn't constant in the callee
        const rt = try s.unconst(s.typeOf(b.func, r));
        try p.key.appendSlice(s.arena, std.mem.asBytes(&rt));
        if (s.isComptime(rt)) {
            try s.bind(inst, info.name_ast, info.name, .{ .value = r.value });
            try s.keyValue(&p.key, given_at, .{ .type = rt, .bytes = r.value.bytes });
            continue;
        }
        try p.runtime.append(s.arena, .{ .name = info.name, .at = info.name_ast, .ref = try s.retypeValue(b, a, r, rt), .type = rt });
        var scratch: Block = .{ .func = try s.scratchFunc(), .typeof_only = true };
        try s.bind(p.types, info.name_ast, info.name, .{ .rt = .{ .ref = try s.emit(&scratch, info.name_ast, rt, .{ .arg = 0 }), .func = scratch.func.? } });
    }
    return p;
}

// the body lowered here, with the arguments as they are
fn runNow(s: *Sema, b: *Block, sc: *Scope, a: astpos, f: Function, inst: *Scope, ret: typeid, p: *const Bound, dest: ?typeid) Error!Res {
    // a compile-time result: the body runs now, its variables in compile-time
    // memory; a runtime-typed argument known now is its value, one that
    // isn't is there only for its type
    if (ret != s.t.inlineast and ret != s.t.any and s.isComptime(ret)) {
        const cs = try s.newScope(inst);
        for (p.runtime.items) |rp| try s.bind(cs, rp.at, rp.name, switch (rp.ref) {
            .value => |v| .{ .value = v },
            .inst => p.types.names.get(rp.name).?,
        });
        var cb: Block = .{ .func = null };
        const res = try s.lower(&cb, cs, f.body, ret);
        return .{ .val = try s.coerce(&cb, f.body, res, ret) };
    }
    for (p.runtime.items) |rp| try s.bind(inst, rp.at, rp.name, switch (rp.ref) {
        .value => |v| .{ .value = v },
        .inst => .{ .rt = .{ .ref = rp.ref, .func = b.func.? } },
    });
    const body_dest: ?typeid = if (ret == s.t.any) null else ret;
    const res = try s.lower(b, inst, f.body, body_dest);
    if (ret == s.t.inlineast) {
        const r = try s.load(b, f.body, res);
        if (r != .value or (r.value.type != s.t.ast and r.value.type != s.t.inlineast))
            return s.fail(f.body, "EXPECTED_AST", "an inline function returns an AST", .{});
        if (s.log_call == a) s.log_expansion = r.value;
        // an inline result is expanded where the call was
        return s.lower(b, sc, asU32(r.value), dest);
    }
    const d = body_dest orelse return res;
    const r = try s.coerce(b, f.body, res, d);
    if (s.isComptime(ret) and r == .inst) return s.fail(f.body, "COMPTIME_RETURN_RUNTIME_ARGUMENT", "the result depends on a runtime argument", .{});
    return .{ .val = r };
}

// a call of the runtime instance for these arguments, made the first time
fn callInstance(s: *Sema, b: *Block, a: astpos, f: Function, fid: u32, inst: *Scope, ret: typeid, p: *const Bound) Error!Res {
    const fi = s.instances.get(p.key.items) orelse try s.instantiate(f, inst, ret, p.runtime.items, p.key.items, fid);
    const ret_t = s.funcs.items[fi].ret orelse return s.fail(a, "RECURSIVE_ANY_RETURN", "the return type is still being worked out", .{});
    const call_args = try s.arena.alloc(Ref, p.runtime.items.len);
    for (call_args, p.runtime.items) |*c, rp| c.* = rp.ref;
    return .{ .val = try s.emit(b, a, ret_t, .{ .call = .{ .func = fi, .args = call_args } }) };
}

// an ast parameter given a value: an AST is itself; anything else is bound
// to a new name where the call is, and the name is the syntax
fn astOfRes(s: *Sema, b: *Block, sc: *Scope, r: Res) Error!astpos {
    if (r == .val and r.val == .value and (r.val.value.type == s.t.ast or r.val.value.type == s.t.inlineast)) return asU32(r.val.value);
    s.gensyms += 1;
    const name = try std.fmt.allocPrint(s.arena, "arg#{d}", .{s.gensyms});
    try s.bind(sc, 0, name, switch (r) {
        .place => |addr| if (addr == .value)
            .{ .value = (try s.asRef(b, 0, addr)).value }
        else
            .{ .rt = .{ .ref = try s.asRef(b, 0, addr), .func = b.func.? } },
        .val => |x| switch (x) {
            .value => |v| .{ .value = v },
            .inst => .{ .rt = .{ .ref = x, .func = b.func.? } },
        },
    });
    return s.makeId(name);
}

// syntax, with an unquote at its top fired
fn fired(s: *Sema, sc: *Scope, x: astpos) Error!astpos {
    if (s.headIs(x, "`")) return s.astValue(sc, (try s.children(x))[1]);
    return x;
}

// What an ast parameter gets: the syntax as written, a name as the name.
// `y passes the AST y holds: unquoted here, quoted again by the parameter.
fn astArgument(s: *Sema, sc: *Scope, x: astpos) Error!astpos {
    return s.fired(sc, x);
}

fn instantiate(s: *Sema, f: Function, sc: *Scope, ret: typeid, params: anytype, key: []const u8, fid: u32) Error!u32 {
    const fi: u32 = @intCast(s.funcs.items.len);
    const name = try std.fmt.allocPrint(s.arena, "fn{d}_{d}", .{ fid, fi });
    try s.funcs.append(s.arena, .{ .name = name, .ret = if (ret == s.t.any) null else ret });
    try s.instances.put(s.arena, key, fi);
    var b: Block = .{ .func = fi };
    for (params, 0..) |p, i| {
        try s.funcs.items[fi].params.append(s.arena, p.type);
        try s.funcs.items[fi].param_names.append(s.arena, try s.arena.dupe(u8, p.name));
        const r = try s.emit(&b, p.at, p.type, .{ .arg = @intCast(i) });
        try s.bind(sc, p.at, p.name, .{ .rt = .{ .ref = r, .func = fi } });
    }
    const body_dest: ?typeid = if (ret == s.t.any) null else ret;
    const res = try s.lower(&b, sc, f.body, body_dest);
    const r = if (body_dest) |d| try s.coerce(&b, f.body, res, d) else try s.load(&b, f.body, res);
    const func = &s.funcs.items[fi];
    func.ret = s.typeOf(fi, r);
    func.result = r;
    func.body = b.body.items;
    return fi;
}

// ---- printing

const TypeFmt = struct {
    s: *Sema,
    t: typeid,
    pub fn format(self: TypeFmt, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const s = self.s;
        const x = s.ty(self.t);
        if (x.maks.@"comptime") try w.writeAll("comptime ");
        if (x.maks.@"const") try w.writeAll("const ");
        if (x.maks.refaddr) try w.writeAll("*");
        if (x.maks.ref) try w.writeAll("&");
        for (0..@as(usize, x.maks.ptr)) |_| try w.writeAll("*");
        switch (x.type) {
            .array => {
                const arr = Pool.helpers.array_of(s.pool, x);
                try w.print("[{d}]{f}", .{ arr.len, s.fmtType(arr.elem) });
            },
            .@"struct" => {
                const st = Pool.helpers.fields_of(s.pool, x);
                if (st.id != tuple_id) return w.print("struct#{d}", .{st.id});
                try w.writeAll("(");
                for (st.fields, 0..) |f, i| try w.print("{s}{f}", .{ if (i == 0) "" else ", ", s.fmtType(f.type) });
                try w.writeAll(")");
            },
            .ctag => try w.print("ctype {s}", .{Pool.helpers.ctag_name(s.pool, x)}),
            .fnptr => {
                const sig = Pool.helpers.signature(s.pool, x);
                try w.writeAll("fnptr[[");
                for (sig.params, 0..) |p, i| try w.print("{s}{f}", .{ if (i == 0) "" else ", ", s.fmtType(p) });
                try w.print("], {f}]", .{s.fmtType(sig.ret)});
            },
            else => try w.writeAll(@tagName(x.type)),
        }
    }
};
pub fn fmtType(s: *Sema, t: typeid) TypeFmt {
    return .{ .s = s, .t = t };
}
pub fn fmtValue(s: *Sema, v: Value) RefFmt {
    return .{ .s = s, .r = .{ .value = v } };
}

const RefFmt = struct {
    s: *Sema,
    r: Ref,
    pub fn format(self: RefFmt, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const s = self.s;
        const v = switch (self.r) {
            .inst => |i| return w.print("%{d}", .{i}),
            .value => |v| v,
        };
        const x = s.ty(v.type);
        if (x.maks.ref or x.maks.ptr != 0) return w.print("<{f}>", .{s.fmtType(v.type)});
        if (s.isNum(v.type)) {
            const c = s.toBig(v) catch return error.WriteFailed;
            return w.print("{f}", .{c});
        }
        switch (x.type) {
            .void => try w.writeAll("void"),
            .bool => try w.writeAll(if (v.bytes[0] != 0) "true" else "false"),
            .type => try w.print("{f}", .{s.fmtType(asU32(v))}),
            .ast, .inlineast => try w.print("'{f}", .{Asth.AstCtx{ .state = s.ast, .ast = s.node(asU32(v)) }}),
            .@"fn" => try w.print("fn#{d}", .{asU32(v)}),
            .builtin => try w.print("@{s}", .{@tagName(@as(Builtin, @fromBackingInt(@intCast(asU32(v)))))}),
            .array => {
                const arr = Pool.helpers.array_of(s.pool, x);
                if (s.ty(arr.elem).type == .cschar) return w.print("\"{s}\"", .{v.bytes});
                const size: usize = @intCast((s.pool.layout(arr.elem) catch return error.WriteFailed).size);
                try w.writeAll("[");
                for (0..@intCast(arr.len)) |i| try w.print("{s}{f}", .{ if (i == 0) "" else ", ", s.fmtValue(.{ .type = arr.elem, .bytes = v.bytes[i * size ..][0..size] }) });
                try w.writeAll("]");
            },
            .@"struct" => {
                const st = Pool.helpers.fields_of(s.pool, x);
                try w.writeAll("[");
                for (st.fields, 0..) |f, i| {
                    const off: usize = @intCast(s.pool.offset_of(v.type, i) catch return error.WriteFailed);
                    const size: usize = @intCast((s.pool.layout(f.type) catch return error.WriteFailed).size);
                    try w.print("{s}{s} = {f}", .{ if (i == 0) "" else ", ", s.fieldName(f), s.fmtValue(.{ .type = f.type, .bytes = v.bytes[off..][0..size] }) });
                }
                try w.writeAll("]");
            },
            else => try w.print("<{f}>", .{s.fmtType(v.type)}),
        }
    }
};

pub fn dump(s: *Sema, w: *std.Io.Writer) std.Io.Writer.Error!void {
    for (s.globals.items, 0..) |g, i| try w.print("global {d} {s}: {f}\n", .{ i, g.name, s.fmtType(g.type) });
    for (s.funcs.items, 0..) |f, fi| {
        if (f.name.len == 0) continue;
        try w.print("{s}(", .{f.name});
        for (f.params.items, 0..) |p, i| try w.print("{s}{f}", .{ if (i == 0) "" else ", ", s.fmtType(p) });
        try w.print(") {f} {{\n", .{s.fmtType(f.ret orelse s.t.any)});
        try s.dumpBody(w, @intCast(fi), f.body, 1);
        try w.print("  => {f}\n}}\n", .{RefFmt{ .s = s, .r = f.result }});
    }
}

fn dumpBody(s: *Sema, w: *std.Io.Writer, fi: u32, body: []const InstIdx, depth: usize) std.Io.Writer.Error!void {
    const f = s.funcs.items[fi];
    const R = struct {
        fn r(sm: *Sema, x: Ref) RefFmt {
            return .{ .s = sm, .r = x };
        }
    }.r;
    for (body) |i| {
        const inst = f.insts.items[i];
        for (0..depth) |_| try w.writeAll("  ");
        try w.print("%{d}: {f} = {s}", .{ i, s.fmtType(inst.type), @tagName(inst.data) });
        switch (inst.data) {
            .arg, .global => |n| try w.print(" {d}", .{n}),
            .alloc, .brk, .cont => {},
            .load, .cast, .retype => |x| try w.print(" {f}", .{R(s, x)}),
            .store => |x| try w.print(" {f} <- {f}", .{ R(s, x.place), R(s, x.value) }),
            .op => |x| try w.print(" {s} {f}, {f}", .{ @tagName(x.op), R(s, x.lhs), R(s, x.rhs) }),
            .field => |x| try w.print(" {f}.{d}", .{ R(s, x.base), x.index }),
            .extract => |x| try w.print(" {f}.{d}", .{ R(s, x.base), x.index }),
            .elem => |x| try w.print(" {f}[{f}]", .{ R(s, x.base), R(s, x.index) }),
            .cexpr => |x| try w.print(" \"{s}\"", .{x}),
            .call_ptr => |x| {
                try w.print(" ({f})(", .{R(s, x.callee)});
                for (x.args, 0..) |arg, n| try w.print("{s}{f}", .{ if (n == 0) "" else ", ", R(s, arg) });
                try w.writeAll(")");
            },
            .call => |x| {
                try w.print(" {s}(", .{s.funcs.items[x.func].name});
                for (x.args, 0..) |arg, n| try w.print("{s}{f}", .{ if (n == 0) "" else ", ", R(s, arg) });
                try w.writeAll(")");
            },
            .aggregate => |x| {
                try w.writeAll(" [");
                for (x, 0..) |arg, n| try w.print("{s}{f}", .{ if (n == 0) "" else ", ", R(s, arg) });
                try w.writeAll("]");
            },
            .short => |x| {
                try w.print(" {s} {f} {{\n", .{ @tagName(x.op), R(s, x.lhs) });
                try s.dumpBody(w, fi, x.rhs_body, depth + 1);
                for (0..depth + 1) |_| try w.writeAll("  ");
                try w.print("=> {f}\n", .{R(s, x.rhs)});
                for (0..depth) |_| try w.writeAll("  ");
                try w.writeAll("}");
            },
            .cond => |x| {
                try w.print(" {f} {{\n", .{R(s, x.cond)});
                try s.dumpBody(w, fi, x.then, depth + 1);
                for (0..depth) |_| try w.writeAll("  ");
                try w.writeAll("} else {\n");
                try s.dumpBody(w, fi, x.@"else", depth + 1);
                for (0..depth) |_| try w.writeAll("  ");
                try w.writeAll("}");
            },
            .loop => |x| {
                try w.writeAll(" {\n");
                try s.dumpBody(w, fi, x, depth + 1);
                for (0..depth) |_| try w.writeAll("  ");
                try w.writeAll("}");
            },
        }
        try w.writeAll("\n");
    }
}
