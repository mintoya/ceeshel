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
        call: struct {
            @"fn": fnidx,
            args: []const VR,
        },
    };
};

pub const Function = struct {
    params: []const typeid,
    ret: typeid,
    insts: struct { start: InstIdx, len: u32 },
};
const fnidx = u32;
pub const Error = Allocator.Error || Pool.LayoutError || error{
    FractionalNumber,
    BadEscape,
    UnboundName,
    Unsupported,
    NotCallable,
    ArgumentCount,
    ExpectedType,
    ExpectedPointer,
    InvalidFree,
    RuntimeAtCompileTime,
    InvalidAllocationType,
    PointerDepthOverflow,
};
const Allocation = struct { bytes: []u8, alignment: std.mem.Alignment };
pub const Function_pre = struct {
    params: astpos,
    ret: astpos,
    body: astpos,
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
heap        : std.AutoHashMapUnmanaged(usize, Allocation) = .empty,
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
fn find(self: *Sema, sc: *Scope, name: []const u8) Error!VR {
    _ = self;
    var current: ?*Scope = sc;
    while (current) |scope| : (current = scope.parent) {
        if (scope.map.get(name)) |index| return scope.values.items[index];
    }
    return error.UnboundName;
}
pub fn deinit(self: *Sema) void {
    var allocations = self.heap.valueIterator();
    while (allocations.next()) |allocation| {
        self.alloc.rawFree(allocation.bytes, allocation.alignment, @returnAddress());
    }
    self.heap.deinit(self.alloc);
    self.functions.deinit(self.alloc);
    self.insts.deinit(self.alloc);
    self.astState.deinit();
    self.pool.deinit();
    self.root.map.deinit(self.alloc);
    self.root.values.deinit(self.alloc);
    self.arena.deinit();
}
pub fn lower(self: *Sema, pos: astpos) Error!VR {
    return switch (self.astState.asts.items[pos]) {
        .none => .{ .value = try self.voidValue() },
        .num => |src| .{ .value = try self.lowerNumber(src) },
        .str => |src| .{ .value = try self.lowerString(src) },
        .id => |src| self.find(&self.root, src.toslice(self.astState.files)),
        .call => |index| blk: {
            const call = self.astState.calls.items[index];
            const children = self.astState.children(index);
            if (children.len == 0) return error.NotCallable;
            if (children[0] == .id and std.mem.eql(u8, children[0].id.toslice(self.astState.files), "{}")) {
                var result: VR = .{ .value = try self.voidValue() };
                for (1..children.len) |i| result = try self.lower(call.start + @as(u32, @intCast(i)));
                break :blk result;
            }
            const head = try known(try self.lower(call.start));
            if (self.pool.get(head.type).type != .builtin) return error.NotCallable;
            const builtin: Builtin = @fromBackingInt(@as(u8, @intCast(std.mem.bytesToValue(u32, head.bytes))));
            const scalar: ?TypeBase = switch (builtin) {
                .void => .void,
                .bool => .bool,
                .type => .type,
                .int => .int,
                .any => .any,
                .schar => .cschar,
                .uchar => .cuchar,
                .sshort => .csshort,
                .ushort => .cushort,
                .sint => .csint,
                .uint => .cuint,
                .slong => .cslong,
                .ulong => .culong,
                .slonglong => .cslonglong,
                .ulonglong => .culonglong,
                else => null,
            };
            if (scalar) |base| {
                if (children.len != 1) return error.ArgumentCount;
                break :blk .{ .value = try self.typeValue(try self.pool.scalar(base)) };
            }
            switch (builtin) {
                .alloc, .free, .ptr => {
                    if (children.len != 2) return error.ArgumentCount;
                    const argument = try known(try self.lower(call.start + 1));
                    const result = switch (builtin) {
                        .alloc => try self.allocate(try self.asType(argument)),
                        .free => try self.release(argument),
                        .ptr => try self.typeValue(try self.pointerType(try self.asType(argument))),
                        else => unreachable,
                    };
                    break :blk .{ .value = result };
                },
                else => return error.Unsupported,
            }
        },
    };
}

fn known(v: VR) Error!Value {
    return switch (v) {
        .value => |value| value,
        .inst => error.RuntimeAtCompileTime,
    };
}
fn voidValue(self: *Sema) Error!Value {
    return .{ .type = try self.pool.scalar(.void), .bytes = &.{} };
}
fn typeValue(self: *Sema, t: typeid) Error!Value {
    return .{ .type = try self.pool.scalar(.type), .bytes = try self.arena.allocator().dupe(u8, std.mem.asBytes(&t)) };
}
fn asType(self: *Sema, value: Value) Error!typeid {
    if (value.type != try self.pool.scalar(.type)) return error.ExpectedType;
    return std.mem.bytesToValue(typeid, value.bytes);
}
fn pointerType(self: *Sema, t: typeid) Error!typeid {
    var mask = self.pool.get(t).maks;
    if (mask.ref != .none) return error.InvalidAllocationType;
    if (mask.ptr == std.math.maxInt(@TypeOf(mask.ptr))) return error.PointerDepthOverflow;
    mask.ptr += 1;
    return self.pool.decorate(t, mask);
}

/// Storage is owned by the compile-time heap, independently of arena-backed values.
pub fn allocate(self: *Sema, t: typeid) Error!Value {
    const pointer_type = try self.pointerType(t);
    const layout = try self.pool.layout(t);
    const size = std.math.cast(usize, layout.size) orelse return error.OutOfMemory;
    const alignment = std.mem.Alignment.fromByteUnits(layout.alignment);
    // Even zero-sized objects get a distinct allocation that can be freed.
    const bytes = (self.alloc.rawAlloc(@max(size, 1), alignment, @returnAddress()) orelse return error.OutOfMemory)[0..@max(size, 1)];
    errdefer self.alloc.rawFree(bytes, alignment, @returnAddress());
    const address = @intFromPtr(bytes.ptr);
    const value_bytes = try self.arena.allocator().dupe(u8, std.mem.asBytes(&address));
    try self.heap.put(self.alloc, address, .{ .bytes = bytes, .alignment = alignment });
    return .{ .type = pointer_type, .bytes = value_bytes };
}

pub fn release(self: *Sema, pointer: Value) Error!Value {
    const t = self.pool.get(pointer.type);
    if (t.maks.ptr == 0 or t.maks.ref != .none) return error.ExpectedPointer;
    const address = std.mem.bytesToValue(usize, pointer.bytes);
    const result = try self.voidValue();
    const allocation = self.heap.fetchRemove(address) orelse return error.InvalidFree;
    self.alloc.rawFree(allocation.value.bytes, allocation.value.alignment, @returnAddress());
    return result;
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

test "compile-time allocations have aligned writable storage and can be released" {
    const testing = std.testing;
    var sema = try Sema.init(testing.allocator);
    defer sema.deinit();
    const integer = try sema.pool.scalar(.cslonglong);
    const array = try sema.pool.array(8, integer);
    const pointer = try sema.allocate(array);
    const address = std.mem.bytesToValue(usize, pointer.bytes);
    const storage: *[8]c_longlong = @ptrFromInt(address);
    storage.* = @splat(42);
    try testing.expectEqual(@as(c_longlong, 42), storage[7]);
    try testing.expectEqual(@as(usize, 0), address % @alignOf(c_longlong));
    try testing.expectEqual(@as(usize, 1), sema.heap.count());
    const result = try sema.release(pointer);
    try testing.expectEqual(TypeBase.void, sema.pool.get(result.type).type);
    try testing.expectEqual(@as(usize, 0), sema.heap.count());
    try testing.expectError(error.InvalidFree, sema.release(pointer));
    try testing.expectError(error.ExpectedPointer, sema.release(result));
    var foreign: c_longlong = 0;
    const foreign_address = @intFromPtr(&foreign);
    try testing.expectError(error.InvalidFree, sema.release(.{
        .type = pointer.type,
        .bytes = std.mem.asBytes(&foreign_address),
    }));
    try testing.expectError(error.NoLayout, sema.allocate(try sema.pool.scalar(.any)));
}

test "zero sized and outstanding allocations are reclaimed" {
    var sema = try Sema.init(std.testing.allocator);
    defer sema.deinit();
    const empty = try sema.pool.scalar(.void);
    const a = try sema.allocate(empty);
    const b = try sema.allocate(empty);
    try std.testing.expect(std.mem.bytesToValue(usize, a.bytes) != std.mem.bytesToValue(usize, b.bytes));
    _ = try sema.release(a);
    // deinit must free b, checked by the testing allocator.
}

test "alloc and free lower from source with argument validation" {
    const cases = [_]struct { source: []const u8, err: ?Error }{
        .{ .source = "@free[@alloc[@sint()]]", .err = null },
        .{ .source = "@free[@alloc[@ptr(@sint())]]", .err = null },
        .{ .source = "@alloc[]", .err = error.ArgumentCount },
        .{ .source = "@free[]", .err = error.ArgumentCount },
        .{ .source = "@alloc[1]", .err = error.ExpectedType },
        .{ .source = "@free[1]", .err = error.ExpectedPointer },
        .{ .source = "@alloc[@any()]", .err = error.NoLayout },
    };
    for (cases) |case| {
        var sema = try Sema.init(std.testing.allocator);
        defer sema.deinit();
        const entry = try Ast.parse(std.testing.io, .{ .str = case.source }, &sema.astState);
        if (case.err) |err| {
            try std.testing.expectError(err, sema.lower(entry));
        } else {
            const result = try known(try sema.lower(entry));
            try std.testing.expectEqual(TypeBase.void, sema.pool.get(result.type).type);
            try std.testing.expectEqual(@as(usize, 0), sema.heap.count());
        }
    }
}
