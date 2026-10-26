const std = @import("std");
const Asth = @import("ast.zig");
const SrcRef = Asth.SrcRef;
const AstIdx = Asth.astpos;
pub const builtins = union(enum) {};
pub const TypeBase = union(enum(u8)) {
    pub fn is_rtint(self: @This()) bool {
        return switch (self) {
            .cschar,
            .csshort,
            .csint,
            .cslong,
            .cslonglong,
            .cuchar,
            .cushort,
            .cuint,
            .culong,
            .culonglong,
            .bool,
            => true,
            _ => false,
        };
    }
    pub fn rtint_bits(self: @This()) !usize {
        return switch (self) {
            .cschar => @bitSizeOf(c_char),
            .cuchar => @bitSizeOf(c_char),
            .csshort => @bitSizeOf(c_short),
            .cushort => @bitSizeOf(c_ushort),
            .csint => @bitSizeOf(c_int),
            .cuint => @bitSizeOf(c_uint),
            .cslong => @bitSizeOf(c_long),
            .culong => @bitSizeOf(c_ulong),
            .cslonglong => @bitSizeOf(c_longlong),
            .culonglong => @bitSizeOf(c_ulonglong),
            .bool => 1,
            _ => error.NotAnInteger,
        };
    }
    void,
    // integer types
    cschar,
    csshort,
    csint,
    cslong,
    cslonglong,
    cuchar,
    cushort,
    cuint,
    culong,
    culonglong,
    bool,
    // meta
    functionpointer,
    tag, // handle for namespace things
    ctag, // opaque
    @"struct": struct {},
    array,
    //comptime
    builtin: builtins,
    any: void,
    ast: AstIdx,
    inlineast: AstIdx,
    int: std.math.big.int.Managed,
    typeinfo: union(enum) {
        name: [16]u8,
    },
    namespace, // idk about this one
    type, //later
    function: struct {
        result: Type,
    },
};
pub const Type = struct {
    TypeBase,
    packed struct {
        @"volatile": bool,
        @"const": bool,
        ref: bool,
        ptr: @Int(.unsigned, @bitSizeOf(u32) - 3),
    },
};
