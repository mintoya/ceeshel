const std = @import("std");
const List = std.ArrayList;
const Allocator = std.mem.Allocator;
const big = std.math.big;
pub const Type = @import("type.zig");

pub const typeid = u32;
pub const strid = u32;

pub const Mask = @FieldType(Type, "maks");

pub const StructField = extern struct { name: strid, type: typeid };
pub const Value = struct { type: typeid, bytes: []const u8 };

alloc: Allocator,
keys: std.heap.ArenaAllocator,

extra: List(u32) = .empty,
types: List(Type) = .empty,
parts: std.StringHashMapUnmanaged(u32) = .empty,
type_map: std.AutoHashMapUnmanaged(Type, typeid) = .empty,

int_map: std.StringHashMapUnmanaged(big.int.Const) = .empty,

strings: List([]const u8) = .empty,
string_map: std.StringHashMapUnmanaged(strid) = .empty,

const Pool = @This();

pub fn init(alloc: Allocator) Allocator.Error!Pool {
    var self: Pool = .{ .alloc = alloc, .keys = .init(alloc) };
    try self.extra.append(alloc, 0);
    return self;
}
pub fn deinit(self: *Pool) void {
    self.types.deinit(self.alloc);
    self.type_map.deinit(self.alloc);
    self.extra.deinit(self.alloc);
    self.parts.deinit(self.alloc);
    self.int_map.deinit(self.alloc);
    self.strings.deinit(self.alloc);
    self.string_map.deinit(self.alloc);
    self.keys.deinit();
}

pub fn intern(self: *Pool, t: Type) Allocator.Error!typeid {
    try self.types.ensureUnusedCapacity(self.alloc, 1);
    const gop = try self.type_map.getOrPut(self.alloc, t);
    if (!gop.found_existing) {
        gop.value_ptr.* = @intCast(self.types.items.len);
        self.types.appendAssumeCapacity(t);
    }
    return gop.value_ptr.*;
}

fn store(self: *Pool, words: []const u32) Allocator.Error!u32 {
    const key = std.mem.sliceAsBytes(words);
    if (self.parts.get(key)) |offset| return offset;
    const owned = try self.keys.allocator().dupe(u8, key);
    const offset: u32 = @intCast(self.extra.items.len);
    try self.extra.appendSlice(self.alloc, words);
    try self.parts.put(self.alloc, owned, offset);
    return offset;
}
pub const helpers = struct {
    pub fn get(self: *const Pool, t: typeid) Type {
        return self.types.items[t];
    }
    pub fn scalar(self: *Pool, base: Type.TypeBase) Allocator.Error!typeid {
        return self.intern(.{ .type = base, .maks = .{}, .data = 0 });
    }
    pub fn decorate(self: *Pool, t: typeid, mask: Mask) Allocator.Error!typeid {
        var x = get(self, t);
        x.maks = mask;
        return self.intern(x);
    }
    pub fn array(self: *Pool, len: u64, elem: typeid) Allocator.Error!typeid {
        return compound(self, .array, &.{ @truncate(len), @intCast(len >> 32), elem });
    }
    pub fn function(self: *Pool, base: Type.TypeBase, params: []const typeid, ret: typeid) Allocator.Error!typeid {
        var data: List(u32) = try .initCapacity(self.alloc, params.len);
        defer data.deinit(self.alloc);
        try data.append(self.alloc, @intCast(params.len));
        try data.appendSlice(self.alloc, params);
        try data.append(self.alloc, ret);
        return compound(self, base, data.items);
    }
    pub fn structure(self: *Pool, id: u32, fields: []const StructField) Allocator.Error!typeid {
        var words: List(u32) = .empty;
        defer words.deinit(self.alloc);
        try words.appendSlice(self.alloc, &.{ id, @intCast(fields.len) });
        try words.appendSlice(self.alloc, std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(fields)));
        return compound(self, .@"struct", words.items);
    }
    // A struct's fields exist once declared, so a struct type is made
    // empty and its fields set as they come; its identity is the id.
    pub fn structure_new(self: *Pool, id: u32) Allocator.Error!typeid {
        const offset: u32 = @intCast(self.extra.items.len);
        try self.extra.appendSlice(self.alloc, &.{ id, 0 });
        return self.intern(.{ .type = .@"struct", .maks = .{}, .data = offset });
    }
    // every type made from t (refs, pointers, const) sees the new fields
    pub fn structure_set(self: *Pool, t: typeid, fields: []const StructField) Allocator.Error!void {
        const old = self.types.items[t].data;
        const offset: u32 = @intCast(self.extra.items.len);
        try self.extra.appendSlice(self.alloc, &.{ self.extra.items[old], @intCast(fields.len) });
        try self.extra.appendSlice(self.alloc, std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(fields)));
        for (self.types.items, 0..) |*ty, i| {
            if (ty.type != .@"struct" or ty.data != old) continue;
            _ = self.type_map.remove(ty.*);
            ty.data = offset;
            try self.type_map.put(self.alloc, ty.*, @intCast(i));
        }
    }
    pub fn ctag(self: *Pool, name: []const u8) Allocator.Error!typeid {
        return compound(self, .ctag, &.{try self.string(name)});
    }
    fn compound(self: *Pool, base: Type.TypeBase, data: []const u32) Allocator.Error!typeid {
        return self.intern(.{
            .type = base,
            .maks = .{},
            .data = try self.store(data),
        });
    }

    pub fn array_of(self: *const Pool, t: Type) struct { len: u64, elem: typeid } {
        std.debug.assert(t.type == .array);
        const w = self.extra.items[t.data..];
        return .{ .len = @as(u64, w[1]) << 32 | w[0], .elem = w[2] };
    }
    pub fn signature(self: *const Pool, t: Type) struct { params: []const typeid, ret: typeid } {
        std.debug.assert(t.type == .@"fn" or t.type == .fnptr);
        const n = self.extra.items[t.data];
        const params = self.extra.items[t.data + 1 ..][0..n];
        return .{ .params = params, .ret = self.extra.items[t.data + 1 + n] };
    }
    pub fn fields_of(self: *const Pool, t: Type) struct { id: u32, fields: []const StructField } {
        std.debug.assert(t.type == .@"struct");
        const n = self.extra.items[t.data + 1];
        const words = self.extra.items[t.data + 2 ..][0 .. 2 * n];
        return .{ .id = self.extra.items[t.data], .fields = std.mem.bytesAsSlice(StructField, std.mem.sliceAsBytes(words)) };
    }
    pub fn ctag_name(self: *const Pool, t: Type) []const u8 {
        std.debug.assert(t.type == .ctag);
        return self.strings.items[self.extra.items[t.data]];
    }
};

pub const LayoutError = error{NoLayout};
pub const Layout = struct { size: u64, alignment: u64 };

pub fn layout(self: *const Pool, ti: typeid) LayoutError!Layout {
    const t = helpers.get(self, ti);
    if (t.maks.ref or t.maks.ptr != 0) return .{
        .size = @sizeOf(*anyopaque),
        .alignment = @alignOf(*anyopaque),
    };
    const of = struct {
        pub fn of(comptime T: type) Layout {
            return .{ .size = @sizeOf(T), .alignment = @alignOf(T) };
        }
    }.of;
    return switch (t.type) {
        .void => .{ .size = 0, .alignment = 1 },
        .bool => .{ .size = 1, .alignment = 1 },
        .cschar, .cuchar => of(c_char),
        .csshort, .cushort => of(c_short),
        .csint, .cuint => of(c_int),
        .cslong, .culong => of(c_long),
        .cslonglong, .culonglong => of(c_longlong),
        .fnptr => of(*const fn () callconv(.c) void),
        .type, .@"fn", .builtin => of(u32),
        .ast, .inlineast => of(u32),
        .int => of(big.int.Const),
        .array => bl: {
            const a = helpers.array_of(self, t);
            const e = try self.layout(a.elem);
            break :bl .{ .size = a.len * e.size, .alignment = e.alignment };
        },
        .@"struct" => blk: {
            var size: u64 = 0;
            var alignment: u64 = 1;
            for (helpers.fields_of(self, t).fields) |f| {
                const l = try self.layout(f.type);
                size = std.mem.alignForward(u64, size, l.alignment) + l.size;
                alignment = @max(alignment, l.alignment);
            }
            break :blk .{ .size = std.mem.alignForward(u64, size, alignment), .alignment = alignment };
        },
        .any, .ctag => error.NoLayout,
    };
}
pub fn offset_of(self: *const Pool, ti: typeid, i: usize) LayoutError!u64 {
    var at: u64 = 0;
    for (helpers.fields_of(self, helpers.get(self, ti)).fields[0 .. i + 1], 0..) |f, n| {
        const l = try self.layout(f.type);
        at = std.mem.alignForward(u64, at, l.alignment);
        if (n == i) break;
        at += l.size;
    }
    return at;
}

pub fn string(self: *Pool, text: []const u8) Allocator.Error!strid {
    if (self.string_map.get(text)) |s| return s;
    const owned = try self.keys.allocator().dupe(u8, text);
    const s: strid = @intCast(self.strings.items.len);
    try self.strings.append(self.alloc, owned);
    try self.string_map.put(self.alloc, owned, s);
    return s;
}
