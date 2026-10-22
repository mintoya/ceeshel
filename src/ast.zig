const std = @import("std");
const List = std.ArrayList;

pub const srcpos_list = List(struct {});
pub const srcpos = u32;

pub const Ast = union(enum) {
    id: srcpos,
    str: srcpos,
    num: srcpos,
    call: struct { left: *Ast, right: *Ast },
    bloc: struct { pos: srcpos, block: []*Ast }, // {}
    anon: struct { pos: srcpos, block: []*Ast }, // []
};
