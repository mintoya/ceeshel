const std = @import("std");
const Asth = @import("ast.zig");
const SrcRef = Asth.SrcRef;
const AstIdx = Asth.astpos;
pub const builtins = enum(u8) {
    pub fn fromName(text: []const u8) ?@This() {
        if (text.len < 2 or text[0] != '@') return null;
        const b = std.meta.stringToEnum(@This(), text[1..]) orelse return null;
        return if (@backingInt(b) >= @backingInt(@This().add)) null else b;
    }
    // types
    void,
    bool,
    type,
    ast,
    inlineast,
    any,
    int,
    // runtime integers, one per C type (spelling still open in spec.md)
    schar,
    sshort,
    sint,
    slong,
    slonglong,
    uchar,
    ushort,
    uint,
    ulong,
    ulonglong,
    arr,
    ptr,
    refT,
    @"struct",
    this,
    ctype,
    // functions
    @"fn",
    returntype,
    yielded,
    // control flow
    @"if",
    loop,
    @"break",
    @"continue",
    cloop,
    cbreak,
    ccontinue,
    @"defer",
    // places
    where,
    at,
    // ast metaprogramming
    len,
    get,
    ast_stringeq,
    apply,
    gensym,
    id,
    compileError,
    compiles,
    // reflection and layout
    typeof,
    typeinfo,
    sizeof,
    alignof,
    offsetof,
    // modules and C
    import,
    using,
    path,
    cinclude,
    cout,

    // operators, overloading relies on overloading
    add,
    sub,
    mul,
    div,
    mod,
    eq,
    ne,
    lt,
    gt,
    le,
    ge,
    @"and",
    @"or",
};
pub const TypeBase = enum(u8) {
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
            else => false,
        };
    }
    pub fn is_comptime(self: @This()) bool {
        return switch (self) {
            .builtin,
            .any,
            .ast,
            .inlineast,
            .int,
            .typeinfo,
            .type,
            .function,
            => true,
            else => false,
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
            else => error.NotAnInteger,
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
    fnptr,
    ctag, // opaque
    @"struct",
    array,
    //comptime
    builtin,
    any,
    ast,
    inlineast,
    int,
    typeinfo,
    type,
    @"fn",
};

pub const TypeInfo = extern struct {
    tag: [16]u8,
    data: union {},
};

type: TypeBase,
maks: packed struct {
    @"volatile": bool = false,
    @"const": bool = false,
    ref: bool = false,
    ptr: @Int(.unsigned, @bitSizeOf(u32) - 3) = 0,
},
data: u32,
