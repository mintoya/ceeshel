const std = @import("std");
const Asth = @import("ast.zig");
const Type = @This();
const SrcRef = Asth.SrcRef;
const AstIdx = Asth.astpos;
pub const builtins = enum(u8) {
    pub fn fromName(text: []const u8) ?@This() {
        if (text.len < 2 or text[0] != '@') return null;
        const b = std.meta.stringToEnum(@This(), text[1..]) orelse return null;
        return if (@backingInt(b) >= @backingInt(@This().add)) null else b;
    }
    // types
    void, //      @void()
    bool, //      @bool()
    type, //      @type() type of a type
    ast, //       @ast() type of an ast
    inlineast, // @inlineast() same as an ast but when returned by a function, immeediatley unquoted
    any, //       @any() marker in function that variable can be of any type, cannot exist as an actual variable even at compile time
    int, //       @int() type of an arbitrary precision compile time integer
    // runtime integers
    schar, //     @schar() signed char
    sshort, //    @sshort() signed short
    sint, //      @sint() signed int
    slong, //     @slong() signed long
    slonglong, // @slonglong() signed long long
    uchar, //     @uchar() unsigned char
    ushort, //    @ushort() unsigned short
    uint, //      @uint() unsigned int
    ulong, //     @ulong() unsigned long
    ulonglong, // @ulonglong() unsigned long long
    arr, //       @arr[n, T] array of n Ts, n known
    ptr, //       @ptr(T) pointer to T
    refT, //      @refT(T) reference to T: a place, bound once; not of a reference
    fnptr, //     @fnptr[[T, U], R] function pointer, runtime types only; @comptime is stripped
    @"comptime", //@comptime(T) comptime of t
    @"const", //  @const(T) T constant  of t
    @"volatile", //@const(T) T constant  of t
    @"struct", // @struct{...} struct type: runtime declarations are fields, the rest its namespace; @struct `x builds it from the AST x holds
    this, //      @this() the struct being declared
    ctype, //     @ctype("name") a C type, emitted by that name
    // functions
    @"fn", //     @fn[[params], ret, body] a function; unquotes written in it fire at definition
    returntype, // @returntype() the enclosing function's return type
    // control flow
    @"if", //     @if[c, then, else] else optional; yields nothing; a known c lowers only the taken branch
    loop, //      @loop(body) repeats body until @break()
    @"break", //  @break() leaves the loop, running what the scopes on the way out deferred
    @"continue", // @continue() the next pass of the loop, the same way
    cwhile, //    @cwhile[c, body] expands body while the known c holds, checked before each whole pass
    @"defer", //  @defer(x) runs x when the scope ends
    yielded, //   @yielded() in deferred code, the value its scope yielded, not the actual value it's about to yield
    // places
    where, //     @where x address of the place x; of a reference, a pointer to its target
    at, //        @at p the place pointer p points to
    ref, //       @ref(x) x as a reference
    // ast metaprogramming
    len, //       @len[x] children of an AST, length of an array or a tuple
    get, //       @get[x, i] child i of an AST (null past the end), element of an array or tuple; @get[x, i, j] the AST's children i to j as a call, reversed when i > j
    ast_stringeq, // @ast_stringeq(x, "s") whether the AST x is an atom spelled s
    apply, //     @apply[f, x] a call of f(child) for each child of the AST x
    gensym, //    @gensym(prefix) a fresh id, prefix optional, written as a bare name
    id, //        @id("s") the id spelled s, any text
    compileError, // @compileError("msg") fails compilation with msg
    compiles, //  @compiles(x) whether x lowers without an error; its code is discarded
    log, //       @log(x) prints what x expands to if an inline call, its value if known, and its type; yields x
    raw, // @raw(x): x with every operator name the builtin
    // reflection and layout
    typeof, //    @typeof(x) the type of x, lowered but never run; a reference gives its target, const is dropped
    sizeof, //    @sizeof(T) size of T in bytes
    alignof, //   @alignof(T) alignment of T in bytes
    offsetof, //  @offsetof(T, name) byte offset of field name in T
    countof, //   @countof(X) struct members in order, array length, or fn/fnptr params + 1
    membertype, // @membertype(T) an array's member type, or a pointer's target
    fieldname, // @fieldname(T, i) name of member i of struct T, as an id
    fieldval, //  @fieldval(X, i) value of i'th field
    fieldtype, // @fieldtype(X, i) type of struct member i (a constant's value type), or fn/fnptr param i, the return type last
    ptrlevel, //  @ptrlevel(x) how many pointers deep the variable x is
    isreferance, // @isreferance(x) whether the variable x is a reference
    isconst, //   @isconst(x) whether x can't be assigned: const, or a value that isn't a place
    isvolatile, // @isvolatile(x) whether x is volatile
    iscomptime, // @iscomptime(x) whether x is known: a known value or compile-time memory
    // modules
    import, //    @import "file" the file's last expression, the file lowered once
    using, //     @using S binds S's namespace members here
    unbind, //    @unbind(name) removes name from this scope, not an enclosing one, so it can be declared again TODO: not optimal
    path, //      @path "p" p relative to this source file; @path() this file
    //c
    cinclude, //  @cinclude("h") #include in the C output, top level only
    cexpr, //     @cexpr[T, "c"] C text as a value of type T; T @void() for a statement

    // operators, overloading relies on overloading
    // call is not here because it cannot be overloaded like normal
    add, //  +
    sub, //  -
    mul, //  *
    div, //  /
    mod, //  %
    eq, //   ==
    ne, //   !=
    lt, //   <
    gt, //   >
    le, //   <=
    ge, //   >=
    @"and", // and, short circuit
    @"or", // or, short circuit
    band, // band, bitwise and
    bor, //  bor, bitwise or
    bxor, // bxor, bitwise xor
    shl, //  shl, a negative count shifts right, past the width it's 0
    shr, //  shr, a negative count shifts left
    xor, //  xor, of bools
    as, //   v as T, a conversion
    cmp, // <=> // -1, 1 , or 0 , like a clamped subtraction
    set, // =
    dot, // .
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
            .type,
            .@"fn",
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
    type,
    @"fn",
};

pub const Ref = enum(u2) {
    none,
    ref, //  referance
    addr, // referance pointer // not inside the language
};

fn Mask(comptime ptr_bits: u16) type {
    return packed struct {
        @"volatile": bool = false,
        @"const": bool = false,
        @"comptime": bool = false,
        ref: Ref = .none,
        ptr: @Int(.unsigned, ptr_bits) = 0,
    };
}

type: TypeBase,
maks: Mask(@bitSizeOf(u32) - @bitSizeOf(Mask(0))), // should be 32 bits
data: u32,
