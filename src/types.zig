const std = @import("std");
const Lists = std.MultiArrayList(struct {
    types: Type,
});
const Type = union {
    uint: u32,
    sint: u32,
    ptr: TypeH,
    stS: StructH,
    btS: BitSH,
};
const Struct = struct {};
const TypeH = struct { u32 };
const StructH = struct { u32 };
const BitSH = struct { u32 };
