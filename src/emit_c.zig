// IR -> C. Each instruction's result is a variable vN declared at the top of
// its function; nested bodies are C blocks. main returns !(the result), so
// a program whose result is true exits 0.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Pool = @import("pool.zig");
const Sema = @import("lower.zig");
const Value = Pool.Value;
const Ref = Sema.Ref;
const InstIdx = Sema.InstIdx;
const typeid = Pool.typeid;
const W = std.Io.Writer;

const Emit = @This();

sema: *Sema,
w: *W,
lines: bool, // #line directives back to the source
last_file: ?u32 = null,
last_line: usize = 0,
line_starts: std.AutoHashMapUnmanaged(u32, []const usize) = .empty,
// aggregate types already defined, by their undecorated type
defined: std.AutoHashMapUnmanaged(typeid, void) = .empty,
types: std.Io.Writer.Allocating, // definitions, in dependency order

pub fn emit(sema: *Sema, w: *W, lines: bool) !void {
    var e: Emit = .{ .sema = sema, .w = w, .lines = lines, .types = .init(sema.arena) };
    try e.program();
}

const prologue =
    \\#include <string.h>
    \\typedef unsigned long long cs_u64;
    \\typedef long long cs_i64;
    \\// a negative count shifts the other way; past the width it's all gone
    \\static cs_i64 cs_shr_s(cs_i64 a, cs_i64 n, int bits);
    \\static cs_i64 cs_shl_s(cs_i64 a, cs_i64 n, int bits) { if (n < 0) return cs_shr_s(a, -n, bits); if (n >= bits) return 0; return (cs_i64)((cs_u64)a << n); }
    \\static cs_i64 cs_shr_s(cs_i64 a, cs_i64 n, int bits) { if (n < 0) return cs_shl_s(a, -n, bits); if (n >= bits) return a < 0 ? -1 : 0; return a >> n; }
    \\static cs_u64 cs_shr_u(cs_u64 a, cs_i64 n, int bits);
    \\static cs_u64 cs_shl_u(cs_u64 a, cs_i64 n, int bits) { if (n < 0) return cs_shr_u(a, -n, bits); if (n >= bits) return 0; return a << n; }
    \\static cs_u64 cs_shr_u(cs_u64 a, cs_i64 n, int bits) { if (n < 0) return cs_shl_u(a, -n, bits); if (n >= bits) return 0; return a >> n; }
    \\
;

fn program(e: *Emit) !void {
    const s = e.sema;
    var code: std.Io.Writer.Allocating = .init(s.arena);
    const b = &code.writer;
    // globals, then every function's prototype, then their bodies
    for (s.globals.items, 0..) |g, i| try b.print("static {f} {s};\n", .{ try e.decl(g.type), try e.globalName(i) });
    for (s.funcs.items, 0..) |f, fi| if (fi != 0 and f.name.len != 0) try e.signature(b, @intCast(fi), true);
    for (s.funcs.items, 0..) |f, fi| if (fi != 0 and f.name.len != 0) try e.function(b, @intCast(fi));
    try e.function(b, 0);

    for (s.c_includes.items) |h| {
        if (h.len > 0 and h[0] == '<') try e.w.print("#include {s}\n", .{h}) else try e.w.print("#include \"{s}\"\n", .{h});
    }
    try e.w.writeAll(prologue);
    try e.w.writeAll(e.types.written());
    try e.w.writeAll(code.written());
}

fn signature(e: *Emit, w: *W, fi: u32, prototype: bool) !void {
    const f = e.sema.funcs.items[fi];
    try w.print("static {f} {s}(", .{ try e.decl(f.ret.?), f.name });
    for (f.params.items, 0..) |p, i| try w.print("{s}{f} {s}", .{ if (i == 0) "" else ", ", try e.decl(p), try e.paramName(fi, i) });
    if (f.params.items.len == 0) try w.writeAll("void");
    try w.writeAll(if (prototype) ");\n" else ")");
}

fn function(e: *Emit, w: *W, fi: u32) !void {
    const s = e.sema;
    const f = s.funcs.items[fi];
    if (fi == 0) try w.writeAll("int main(void)") else try e.signature(w, fi, false);
    try w.writeAll(" {\n");
    // every instruction's variable, and every local's storage, up front
    for (f.insts.items, 0..) |inst, i| {
        if (inst.type == s.t.void or inst.data == .brk or inst.data == .cont) continue;
        if (inst.data == .alloc) try w.print("  {f} {s};\n", .{ try e.decl(try s.pointee(inst.type)), try e.localName(fi, @intCast(i)) });
        try w.print("  {f} v{d};\n", .{ try e.decl(inst.type), i });
    }
    e.last_file = null;
    try e.body(w, fi, f.body, 1);
    const result = try e.ref(fi, f.result);
    if (fi == 0) {
        try w.print("  return !({s});\n}}\n", .{result});
    } else if (f.ret.? == s.t.void) {
        try w.writeAll("}\n");
    } else try w.print("  return {s};\n}}\n", .{result});
}

// a parameter is named as in the source, so @cexpr can use it, unless that
// isn't a C name
fn paramName(e: *Emit, fi: u32, n: usize) ![]const u8 {
    const name = e.sema.funcs.items[fi].param_names.items[n];
    return if (cName(name)) name else std.fmt.allocPrint(e.sema.arena, "a{d}", .{n});
}
// a local or global keeps its source name, made unique, for a debugger
fn localName(e: *Emit, fi: u32, i: InstIdx) ![]const u8 {
    const name = e.sema.funcs.items[fi].insts.items[i].data.alloc;
    if (cName(name)) return std.fmt.allocPrint(e.sema.arena, "{s}_{d}", .{ name, i });
    return std.fmt.allocPrint(e.sema.arena, "l{d}", .{i});
}
fn globalName(e: *Emit, n: usize) ![]const u8 {
    const name = e.sema.globals.items[n].name;
    if (cName(name)) return std.fmt.allocPrint(e.sema.arena, "{s}_g{d}", .{ name, n });
    return std.fmt.allocPrint(e.sema.arena, "g{d}", .{n});
}
// a source name usable as is in C: not a keyword, and not shaped like a name
// made up here (v1, l1, g1, a1, x_1, x_g1, cs_...)
fn cName(name: []const u8) bool {
    const c_keywords = [_][]const u8{ "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "restrict", "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "main" };
    var ok = name.len > 0 and !std.ascii.isDigit(name[0]);
    for (name) |c| ok = ok and (std.ascii.isAlphanumeric(c) or c == '_');
    for (c_keywords) |k| ok = ok and !std.mem.eql(u8, k, name);
    if (!ok or std.mem.startsWith(u8, name, "cs_")) return false;
    // v, l, g and a followed by digits are taken
    if (name.len > 1 and std.mem.indexOfScalar(u8, "vlga", name[0]) != null and allDigits(name[1..])) return false;
    // so is anything ending in _N or _gN
    if (std.mem.lastIndexOfScalar(u8, name, '_')) |u| {
        const tail = name[u + 1 ..];
        if (allDigits(tail) or (tail.len > 1 and tail[0] == 'g' and allDigits(tail[1..]))) return false;
    }
    return true;
}
fn allDigits(x: []const u8) bool {
    if (x.len == 0) return false;
    for (x) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

// #line for where an instruction came from, when that changed; the file is
// named again when it isn't the last one named
fn line(e: *Emit, w: *W, at: u32) !void {
    if (!e.lines) return;
    const src = e.sema.srcOf(at) orelse return;
    if (src.fileref == 0) return; // made-up names are nowhere
    const file = e.sema.ast.files.items[src.fileref];
    const starts = e.line_starts.get(src.fileref) orelse s: {
        const content = switch (file.content) {
            .file => |c| c,
            .buffer => |b| b.items,
        };
        var list: std.ArrayList(usize) = .empty;
        try list.append(e.sema.arena, 0);
        for (content, 0..) |c, n| if (c == '\n') try list.append(e.sema.arena, n + 1);
        try e.line_starts.put(e.sema.arena, src.fileref, list.items);
        break :s list.items;
    };
    // the last line starting at or before the offset
    var lo: usize = 0;
    var hi: usize = starts.len;
    while (hi - lo > 1) {
        const mid = (lo + hi) / 2;
        if (starts[mid] <= src.offset) lo = mid else hi = mid;
    }
    const n = lo + 1;
    if (e.last_file == src.fileref and e.last_line == n) return;
    if (e.last_file == src.fileref) {
        try w.print("#line {d}\n", .{n});
    } else {
        try w.print("#line {d} \"", .{n});
        for (file.name) |c| {
            if (c == '"' or c == '\\') try w.writeByte('\\');
            try w.writeByte(c);
        }
        try w.writeAll("\"\n");
    }
    e.last_file = src.fileref;
    e.last_line = n;
}

fn indent(w: *W, depth: usize) !void {
    for (0..depth) |_| try w.writeAll("  ");
}

fn body(e: *Emit, w: *W, fi: u32, insts: []const InstIdx, depth: usize) anyerror!void {
    const s = e.sema;
    for (insts) |i| {
        const inst = s.funcs.items[fi].insts.items[i];
        try e.line(w, inst.at);
        try indent(w, depth);
        const t = inst.type;
        switch (inst.data) {
            .arg => |n| try w.print("v{d} = {s};\n", .{ i, try e.paramName(fi, n) }),
            .global => |n| try w.print("v{d} = &{s};\n", .{ i, try e.globalName(n) }),
            .alloc => try w.print("v{d} = &{s};\n", .{ i, try e.localName(fi, i) }),
            // memory is bytes: copied, so any type may read what another wrote
            .load => |p| try w.print("memcpy(&v{d}, {s}, sizeof v{d});\n", .{ i, try e.ref(fi, p), i }),
            .store => |x| switch (x.value) {
                .inst => |v| try w.print("memcpy({s}, &v{d}, sizeof v{d});\n", .{ try e.ref(fi, x.place), v, v }),
                .value => |v| try w.print("{{ {f} t = {s}; memcpy({s}, &t, sizeof t); }}\n", .{ try e.decl(v.type), try e.literal(v), try e.ref(fi, x.place) }),
            },
            .cast => |x| try w.print("v{d} = ({f}){s};\n", .{ i, try e.decl(t), try e.ref(fi, x) }),
            // the same bytes: a cast between pointers, else a copy
            .retype => |x| if ((try e.decl(t)).stars > 0)
                try w.print("v{d} = ({f}){s};\n", .{ i, try e.decl(t), try e.ref(fi, x) })
            else
                try w.print("v{d} = {s};\n", .{ i, try e.ref(fi, x) }),
            .op => |x| try e.op(w, fi, i, t, x.op, x.lhs, x.rhs),
            .short => |x| {
                try w.print("v{d} = {s};\n", .{ i, try e.ref(fi, x.lhs) });
                try indent(w, depth);
                try w.print("if ({s}v{d}) {{\n", .{ if (x.op == .@"or") "!" else "", i });
                try e.body(w, fi, x.rhs_body, depth + 1);
                try indent(w, depth + 1);
                try w.print("v{d} = {s};\n", .{ i, try e.ref(fi, x.rhs) });
                try indent(w, depth);
                try w.writeAll("}\n");
            },
            .call_ptr => |x| {
                if (t != s.t.void) try w.print("v{d} = ", .{i});
                try w.print("({s})(", .{try e.ref(fi, x.callee)});
                for (x.args, 0..) |a, n| try w.print("{s}{s}", .{ if (n == 0) "" else ", ", try e.ref(fi, a) });
                try w.writeAll(");\n");
            },
            .call => |x| {
                if (t != s.t.void) try w.print("v{d} = ", .{i});
                try w.print("{s}(", .{s.funcs.items[x.func].name});
                for (x.args, 0..) |a, n| try w.print("{s}{s}", .{ if (n == 0) "" else ", ", try e.ref(fi, a) });
                try w.writeAll(");\n");
            },
            .cond => |x| {
                try w.print("if ({s}) {{\n", .{try e.ref(fi, x.cond)});
                try e.body(w, fi, x.then, depth + 1);
                try indent(w, depth);
                try w.writeAll("} else {\n");
                try e.body(w, fi, x.@"else", depth + 1);
                try indent(w, depth);
                try w.writeAll("}\n");
            },
            .loop => |x| {
                try w.writeAll("for (;;) {\n");
                try e.body(w, fi, x, depth + 1);
                try indent(w, depth);
                try w.writeAll("}\n");
            },
            .brk => try w.writeAll("break;\n"),
            .cont => try w.writeAll("continue;\n"),
            .field => |x| try w.print("v{d} = &{s}->f{d};\n", .{ i, try e.ref(fi, x.base), x.index }),
            .elem => |x| try w.print("v{d} = &{s}->e[{s}];\n", .{ i, try e.ref(fi, x.base), try e.ref(fi, x.index) }),
            .extract => |x| try w.print("v{d} = {s}.f{d};\n", .{ i, try e.ref(fi, x.base), x.index }),
            .aggregate => |x| {
                const arr = s.ty(t).type == .array;
                try w.print("v{d} = ({f}){{{s}", .{ i, try e.decl(t), if (arr) "{" else "" });
                for (x, 0..) |a, n| try w.print("{s}{s}", .{ if (n == 0) "" else ", ", try e.ref(fi, a) });
                try w.print("{s}}};\n", .{if (arr) "}" else ""});
            },
            .cexpr => |x| if (t == s.t.void)
                try w.print("{s};\n", .{x})
            else
                try w.print("v{d} = ({s});\n", .{ i, x }),
        }
    }
}

fn op(e: *Emit, w: *W, fi: u32, i: InstIdx, t: typeid, o: Pool.Type.builtins, lhs: Ref, rhs: Ref) !void {
    const s = e.sema;
    const l = try e.ref(fi, lhs);
    const r = try e.ref(fi, rhs);
    const lt = s.typeOf(fi, lhs);
    switch (o) {
        // computed unsigned, so overflow wraps instead of being undefined
        .add, .sub, .mul => {
            const u = try e.unsignedOf(lt);
            const sym: []const u8 = switch (o) {
                .add => "+",
                .sub => "-",
                else => "*",
            };
            try w.print("v{d} = ({f})(({s}){s} {s} ({s}){s});\n", .{ i, try e.decl(t), u, l, sym, u, r });
        },
        .cmp => try w.print("v{d} = ({s} > {s}) - ({s} < {s});\n", .{ i, l, r, l, r }),
        .shl, .shr => {
            const info = s.intInfo(lt).?;
            const signed = info.signedness == .signed;
            try w.print("v{d} = ({f})cs_{s}_{s}({s}, {s}, {d});\n", .{ i, try e.decl(t), @tagName(o), if (signed) "s" else "u", l, r, info.bits });
        },
        else => {
            const sym: []const u8 = switch (o) {
                .div => "/",
                .mod => "%",
                .eq => "==",
                .ne, .xor => "!=",
                .lt => "<",
                .gt => ">",
                .le => "<=",
                .ge => ">=",
                .band => "&",
                .bor => "|",
                .bxor => "^",
                else => unreachable,
            };
            try w.print("v{d} = ({f})({s} {s} {s});\n", .{ i, try e.decl(t), l, sym, r });
        },
    }
}

fn unsignedOf(e: *Emit, t: typeid) ![]const u8 {
    return switch (e.sema.ty(t).type) {
        .cschar, .cuchar => "unsigned char",
        .csshort, .cushort => "unsigned short",
        .csint, .cuint => "unsigned int",
        .cslong, .culong => "unsigned long",
        .cslonglong, .culonglong => "unsigned long long",
        else => "unsigned",
    };
}

fn ref(e: *Emit, fi: u32, r: Ref) ![]const u8 {
    _ = fi;
    return switch (r) {
        .inst => |i| std.fmt.allocPrint(e.sema.arena, "v{d}", .{i}),
        .value => |v| e.literal(v),
    };
}

// a known value as C
fn literal(e: *Emit, v: Value) anyerror![]const u8 {
    const s = e.sema;
    const a = s.arena;
    if (s.isComptime(v.type)) return error.ComptimeValueAtRuntime;
    const x = s.ty(v.type);
    if (x.maks.ref or x.maks.ptr != 0) {
        return std.fmt.allocPrint(a, "(({f})0x{x}ULL)", .{ try e.decl(v.type), std.mem.readInt(u64, v.bytes[0..8], .little) });
    }
    switch (x.type) {
        .void => return "0",
        // a function pointer's bytes are its instance's number
        .fnptr => return s.funcs.items[@intCast(std.mem.bytesToValue(usize, v.bytes[0..@sizeOf(usize)]))].name,
        .bool => return if (v.bytes[0] != 0) "1" else "0",
        .array, .@"struct" => {
            var out: std.Io.Writer.Allocating = .init(a);
            try out.writer.print("(({f}){{", .{try e.decl(v.type)});
            if (x.type == .array) {
                const arr = Pool.helpers.array_of(s.pool, x);
                const size: usize = @intCast((try s.layoutOf(0, arr.elem)).size);
                try out.writer.writeAll("{");
                for (0..@intCast(arr.len)) |n| try out.writer.print("{s}{s}", .{ if (n == 0) "" else ", ", try e.literal(.{ .type = arr.elem, .bytes = v.bytes[n * size ..][0..size] }) });
                if (arr.len == 0) try out.writer.writeAll("0");
                try out.writer.writeAll("}");
            } else {
                const st = Pool.helpers.fields_of(s.pool, x);
                for (st.fields, 0..) |f, n| {
                    const off: usize = @intCast(try s.pool.offset_of(v.type, n));
                    const size: usize = @intCast((try s.layoutOf(0, f.type)).size);
                    try out.writer.print("{s}{s}", .{ if (n == 0) "" else ", ", try e.literal(.{ .type = f.type, .bytes = v.bytes[off..][0..size] }) });
                }
                if (st.fields.len == 0) try out.writer.writeAll("0");
            }
            try out.writer.writeAll("})");
            return out.written();
        },
        else => {
            // an integer, as its bits
            var bits: u64 = 0;
            for (v.bytes, 0..) |byte, n| bits |= @as(u64, byte) << @intCast(8 * n);
            return std.fmt.allocPrint(a, "(({f})0x{x}ULL)", .{ try e.decl(v.type), bits });
        },
    }
}

const Decl = struct {
    base: []const u8,
    stars: usize,
    pub fn format(d: Decl, w: *W) W.Error!void {
        try w.writeAll(d.base);
        for (0..d.stars) |_| try w.writeAll("*");
    }
};

// the C type of t: a name, then a * per pointer or reference
fn decl(e: *Emit, t: typeid) anyerror!Decl {
    const s = e.sema;
    const x = s.ty(t);
    const stars = @as(usize, x.maks.ptr) + @intFromBool(x.maks.ref) + @intFromBool(x.maks.refaddr);
    const plain = try Pool.helpers.decorate(s.pool, t, .{});
    return .{ .base = try e.baseName(plain), .stars = stars };
}

fn baseName(e: *Emit, t: typeid) ![]const u8 {
    const s = e.sema;
    const x = s.ty(t);
    return switch (x.type) {
        .void => "void",
        .bool => "_Bool",
        .cschar => "signed char",
        .csshort => "short",
        .csint => "int",
        .cslong => "long",
        .cslonglong => "long long",
        .cuchar => "unsigned char",
        .cushort => "unsigned short",
        .cuint => "unsigned int",
        .culong => "unsigned long",
        .culonglong => "unsigned long long",
        .ctag => Pool.helpers.ctag_name(s.pool, x),
        .array, .@"struct", .fnptr => {
            const name = try std.fmt.allocPrint(s.arena, "t{d}", .{t});
            try e.define(t, name);
            return name;
        },
        else => error.ComptimeTypeAtRuntime,
    };
}

// an aggregate's definition, after the types its fields hold
fn define(e: *Emit, t: typeid, name: []const u8) !void {
    const s = e.sema;
    if (e.defined.contains(t)) return;
    try e.defined.put(s.arena, t, {});
    const x = s.ty(t);
    var def: std.Io.Writer.Allocating = .init(s.arena);
    // a struct is named first, so its fields can point to it
    if (x.type == .@"struct") try e.types.writer.print("typedef struct {s} {s};\n", .{ name, name });
    if (x.type == .fnptr) {
        const sig = Pool.helpers.signature(s.pool, x);
        try def.writer.print("typedef {f} (*{s})(", .{ try e.decl(sig.ret), name });
        for (sig.params, 0..) |p, i| try def.writer.print("{s}{f}", .{ if (i == 0) "" else ", ", try e.decl(p) });
        if (sig.params.len == 0) try def.writer.writeAll("void");
        try def.writer.writeAll(");\n");
    } else if (x.type == .array) {
        // arrays are wrapped, so they copy as values
        const arr = Pool.helpers.array_of(s.pool, x);
        try def.writer.print("typedef struct {{ {f} e[{d}]; }} {s};\n", .{ try e.decl(arr.elem), arr.len, name });
    } else {
        const st = Pool.helpers.fields_of(s.pool, x);
        try def.writer.print("struct {s} {{", .{name});
        for (st.fields, 0..) |f, i| try def.writer.print(" {f} f{d};", .{ try e.decl(f.type), i });
        try def.writer.writeAll(" };\n");
    }
    try e.types.writer.writeAll(def.written());
}
