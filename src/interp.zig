// Runs lowered IR. Runtime values are Values too: bytes laid out as
// Pool.layout says, and an address's bytes are the address of its storage.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Pool = @import("pool.zig");
const Sema = @import("lower.zig");
const Value = Pool.Value;
const Ref = Sema.Ref;
const InstIdx = Sema.InstIdx;

const Interp = @This();

sema: *Sema,
arena: Allocator,
globals: [][]u8,

pub fn init(sema: *Sema) Sema.Error!Interp {
    const globals = try sema.arena.alloc([]u8, sema.globals.items.len);
    for (globals, sema.globals.items) |*g, decl| {
        g.* = try sema.arena.alloc(u8, try size(sema, decl.type));
        @memset(g.*, 0);
    }
    return .{ .sema = sema, .arena = sema.arena, .globals = globals };
}

fn size(sema: *Sema, t: Pool.typeid) Sema.Error!usize {
    return @intCast((try sema.layoutOf(0, t)).size);
}

fn address(v: Value) [*]u8 {
    return @ptrFromInt(std.mem.bytesToValue(usize, v.bytes[0..@sizeOf(usize)]));
}
fn addressValue(it: *Interp, t: Pool.typeid, at: [*]u8) Allocator.Error!Value {
    return .{ .type = t, .bytes = try it.arena.dupe(u8, std.mem.asBytes(&@intFromPtr(at))) };
}

pub fn run(it: *Interp, fi: u32, args: []const Value) Sema.Error!Value {
    const f = it.sema.funcs.items[fi];
    const frame = try it.arena.alloc(Value, f.insts.items.len);
    _ = try it.exec(fi, frame, args, f.body);
    return get(frame, f.result);
}

fn get(frame: []const Value, r: Ref) Value {
    return switch (r) {
        .value => |v| v,
        .inst => |i| frame[i],
    };
}

const Flow = enum { next, brk, cont };

fn exec(it: *Interp, fi: u32, frame: []Value, args: []const Value, body: []const InstIdx) Sema.Error!Flow {
    const s = it.sema;
    for (body) |i| {
        const inst = s.funcs.items[fi].insts.items[i];
        frame[i] = switch (inst.data) {
            .arg => |n| args[n],
            .global => |n| try it.addressValue(inst.type, it.globals[n].ptr),
            .alloc => a: {
                const mem = try it.arena.alloc(u8, try size(s, try s.pointee(inst.type)));
                @memset(mem, 0);
                break :a try it.addressValue(inst.type, mem.ptr);
            },
            .load => |p| .{ .type = inst.type, .bytes = try it.arena.dupe(u8, address(get(frame, p))[0..try size(s, inst.type)]) },
            .store => |x| st: {
                const v = get(frame, x.value);
                @memcpy(address(get(frame, x.place))[0..v.bytes.len], v.bytes);
                break :st s.vVoid();
            },
            .cast => |x| try s.vBig(inst.type, try s.toBig(get(frame, x))),
            .retype => |x| .{ .type = inst.type, .bytes = get(frame, x).bytes },
            .op => |x| op: {
                const v = try s.fold(inst.at, x.op, s.typeOf(fi, x.lhs), get(frame, x.lhs), get(frame, x.rhs));
                // <=> folds to an @int; at runtime it is the instruction's type
                break :op if (x.op == .cmp) try s.vBig(inst.type, try s.toBig(v)) else v;
            },
            .short => |x| sc: {
                const l = get(frame, x.lhs);
                if ((l.bytes[0] != 0) == (x.op == .@"or")) break :sc l;
                const flow = try it.exec(fi, frame, args, x.rhs_body);
                if (flow != .next) return flow;
                break :sc get(frame, x.rhs);
            },
            .call => |x| c: {
                const vals = try it.arena.alloc(Value, x.args.len);
                for (vals, x.args) |*v, a| v.* = get(frame, a);
                break :c try it.run(x.func, vals);
            },
            // a function pointer's bytes are its instance's number
            .call_ptr => |x| c: {
                const vals = try it.arena.alloc(Value, x.args.len);
                for (vals, x.args) |*v, a| v.* = get(frame, a);
                const callee = get(frame, x.callee);
                break :c try it.run(@intCast(std.mem.bytesToValue(usize, callee.bytes[0..@sizeOf(usize)])), vals);
            },
            .cond => |x| c: {
                const flow = try it.exec(fi, frame, args, if (get(frame, x.cond).bytes[0] != 0) x.then else x.@"else");
                if (flow != .next) return flow;
                break :c s.vVoid();
            },
            .loop => |x| l: {
                while (true) if (try it.exec(fi, frame, args, x) == .brk) break;
                break :l s.vVoid();
            },
            .brk => return .brk,
            .cont => return .cont,
            .field => |x| f: {
                const base = get(frame, x.base);
                const st = try s.pointee(s.typeOf(fi, x.base));
                const off = s.pool.offset_of(st, x.index) catch return s.fail(0, "NO_LAYOUT", "", .{});
                break :f try it.addressValue(inst.type, address(base) + off);
            },
            .elem => |x| e: {
                const base = get(frame, x.base);
                const elem_t = try s.pointee(inst.type);
                const arr = Pool.helpers.array_of(s.pool, Pool.helpers.get(s.pool, try s.pointee(s.typeOf(fi, x.base))));
                const n = try s.toIndex(inst.at, get(frame, x.index));
                // a zero-length array's length is known elsewhere
                if (arr.len != 0 and n >= arr.len) return s.fail(inst.at, "INDEX_OUT_OF_BOUNDS", "{d} of {d} elements", .{ n, arr.len });
                break :e try it.addressValue(inst.type, address(base) + n * try size(s, elem_t));
            },
            .extract => |x| e: {
                const base = get(frame, x.base);
                const st = s.typeOf(fi, x.base);
                const off = s.pool.offset_of(st, x.index) catch return s.fail(0, "NO_LAYOUT", "", .{});
                break :e .{ .type = inst.type, .bytes = base.bytes[off..][0..try size(s, inst.type)] };
            },
            .aggregate => |x| ag: {
                const out = try it.arena.alloc(u8, try size(s, inst.type));
                @memset(out, 0);
                var off: usize = 0;
                const is_struct = Pool.helpers.get(s.pool, inst.type).type == .@"struct";
                for (x, 0..) |e, n| {
                    const v = get(frame, e);
                    if (is_struct) off = s.pool.offset_of(inst.type, n) catch unreachable;
                    @memcpy(out[off..][0..v.bytes.len], v.bytes);
                    off += v.bytes.len;
                }
                break :ag .{ .type = inst.type, .bytes = out };
            },
            .cexpr => return s.fail(inst.at, "NOT_INTERPRETABLE", "C code only runs compiled", .{}),
        };
    }
    return .next;
}
