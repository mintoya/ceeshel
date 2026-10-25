const std = @import("std");
const isSpace = std.ascii.isWhitespace;
const isDigit = std.ascii.isDigit;
const isHex = std.ascii.isHex;
const List = std.ArrayList;

pub const Token = union(enum) {
    pub const span = struct { start: u32, len: u32 };
    pub const offset = u32;

    pub fn isblock(self: @This()) bool {
        return switch (self) {
            .@"{", .@"}", .@"(", .@")", .@"[", .@"]" => true,
            else => false,
        };
    }

    pub fn isblockleft(self: @This()) bool {
        return switch (self) {
            .@"{", .@"(", .@"[" => true,
            else => false,
        };
    }

    /// Lower value binds tighter.
    pub const Precedence = enum(u8) {
        access = 0,
        tight = 1,
        as = 2,
        mul = 3,
        add = 4,
        bit = 5,
        cmp = 6,
        infix = 7,
        call = 8,
        pipe = 9,
        eq = 10,
    };

    pub fn startsOperand(self: @This()) bool {
        return switch (self) {
            .id, .str, .num, .@"(", .@"[", .@"{" => true,
            else => false,
        };
    }

    pub fn endsOperand(self: @This()) bool {
        return switch (self) {
            .id, .str, .num, .@")", .@"]", .@"}" => true,
            else => false,
        };
    }

    pub fn prec(self: @This()) !Precedence {
        return switch (self) {
            .tight => .tight,
            .@".", .@":" => .access,
            .as => .as,
            .@"*", .@"/", .@"%" => .mul,
            .@"+", .@"-" => .add,
            .@"and", .@"or", .xor, .shr, .shl, .band, .bor, .bxor => .bit,
            .@"<=>", .@"<", .@">", .@"<=", .@">=", .@"==", .@"!=" => .cmp,
            .@"<<" => .infix,
            .@"|>" => .pipe,
            .@"=" => .eq,
            else => error.NotInPrecedenceList,
        };
    }

    id: span,
    str: span, // contents only, without the surrounding quotes
    num: span,
    /// Synthesized and zero-width: a block opens immediately after an operand.
    tight: void,
    @"{": offset,
    @"}": offset,
    @"(": offset,
    @")": offset,
    @"[": offset,
    @"]": offset,
    //
    @",": offset,
    @";": offset,
    @"~": offset,
    //
    @".": offset,
    @":": offset,
    //
    as: offset,
    //
    @"*": offset,
    @"/": offset,
    @"%": offset,
    //
    @"+": offset,
    @"-": offset,
    //
    @"and": offset,
    @"or": offset,
    xor: offset,
    shr: offset,
    shl: offset,
    band: offset,
    bor: offset,
    bxor: offset,
    //
    @"<=>": offset,
    @"<": offset,
    @">": offset,
    @"<=": offset,
    @">=": offset,
    @"==": offset,
    @"!=": offset,
    //
    /// `a <<f>> b` calls f with [a, b]; any expression can go between.
    @"<<": offset,
    @">>": offset,
    //
    @"|>": offset,
    //
    @"=": offset,
};

pub const Error = error{
    UnexpectedByte,
    UnterminatedString,
    UnterminatedComment,
} || std.mem.Allocator.Error;

const words = .{ "as", "and", "or", "xor", "shr", "shl", "band", "bor", "bxor" };

const operators = .{
    "<=>", "<<", ">>", "<=", ">=", "==", "!=", "|>",
    "{",   "}",  "(",  ")",  "[",  "]",  ".",  ":",
    "*",   "/",  "%",  "+",  "-",  "<",  ">",  "=",
    ",",   ";",  "~",
};

fn isExtra(c: u8) bool {
    return switch (c) {
        '_', '#', '$', '?', '!' => true,
        else => false,
    };
}
fn isIdStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or isExtra(c);
}
fn isIdCont(c: u8) bool {
    return isIdStart(c) or isDigit(c);
}

fn idLen(rest: []const u8) usize {
    if (rest[0] == '\'' or rest[0] == '`' or rest[0] == '\\') return 1;
    if (std.mem.startsWith(u8, rest, "..")) return 2; // splice
    const j: usize = if (rest[0] == '@') 1 else 0;
    if (j >= rest.len or !isIdStart(rest[j])) return 0;
    var k = j + 1;
    while (k < rest.len and isIdCont(rest[k])) k += 1;
    return k;
}

fn numLen(rest: []const u8) usize {
    const j: usize = if (rest[0] == '-') 1 else 0;
    if (j >= rest.len or !isDigit(rest[j])) return 0;

    if (rest[j] == '0' and j + 2 < rest.len) {
        if (rest[j + 1] == 'x' and isHex(rest[j + 2])) {
            var k = j + 3;
            while (k < rest.len and isHex(rest[k])) k += 1;
            return k;
        }
        if (rest[j + 1] == 'b' and (rest[j + 2] == '0' or rest[j + 2] == '1')) {
            var k = j + 3;
            while (k < rest.len and (rest[k] == '0' or rest[k] == '1')) k += 1;
            return k;
        }
    }

    var k = j + 1;
    while (k < rest.len and (isDigit(rest[k]) or rest[k] == '_')) k += 1;
    if (k + 1 < rest.len and rest[k] == '.' and isDigit(rest[k + 1])) {
        k += 1;
        while (k < rest.len and (isDigit(rest[k]) or rest[k] == '_')) k += 1;
    }
    return k;
}

const Op = struct { tok: Token, len: usize };

fn matchOperator(rest: []const u8, start: u32) ?Op {
    inline for (operators) |op| {
        if (std.mem.startsWith(u8, rest, op)) {
            return .{ .tok = @unionInit(Token, op, start), .len = op.len };
        }
    }
    return null;
}

fn keywordOrId(text: []const u8, start: u32) Token {
    inline for (words) |kw| {
        if (std.mem.eql(u8, text, kw)) return @unionInit(Token, kw, start);
    }
    return .{ .id = .{ .start = start, .len = @intCast(text.len) } };
}

const Emitter = struct {
    toks: List(Token) = .empty,
    last_end: ?usize = null,

    fn push(self: *Emitter, alloc: std.mem.Allocator, tok: Token, start: usize, end: usize) !void {
        if (tok.isblockleft() and self.last_end == start) {
            try self.toks.append(alloc, .tight);
        }
        try self.toks.append(alloc, tok);
        self.last_end = if (tok.endsOperand()) end else null;
    }
};

pub fn tokenize(alloc: std.mem.Allocator, src: []const u8) Error![]Token {
    var em: Emitter = .{};
    errdefer em.toks.deinit(alloc);

    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];

        if (isSpace(c)) {
            i += 1;
            continue;
        }

        if (c == '/' and i + 1 < src.len) {
            if (src[i + 1] == '/') {
                i = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
                continue;
            }
            if (src[i + 1] == '*') {
                const close = std.mem.indexOfPos(u8, src, i + 2, "*/") orelse
                    return error.UnterminatedComment;
                i = close + 2;
                continue;
            }
        }

        const start: u32 = @intCast(i);
        const rest = src[i..];

        if (c != '-' or em.last_end != i) {
            const n = numLen(rest);
            if (n > 0) {
                try em.push(alloc, .{ .num = .{ .start = start, .len = @intCast(n) } }, i, i + n);
                i += n;
                continue;
            }
        }

        if (c == '"') {
            var j = i + 1;
            while (j < src.len and src[j] != '"') {
                if (src[j] == '\\') j += 1; // skip the escaped byte
                j += 1;
            }
            if (j >= src.len) return error.UnterminatedString;
            const tok: Token = .{ .str = .{
                .start = start + 1,
                .len = @intCast(j - (i + 1)),
            } };
            try em.push(alloc, tok, i, j + 1);
            i = j + 1; // past closing quote
            continue;
        }

        // identifiers/keywords vs operators: longest match wins, so `!=` is
        // an operator even though `!` alone is a valid identifier.
        const id_n = idLen(rest);
        const op = matchOperator(rest, start);
        if (id_n > 0 and (op == null or id_n > op.?.len)) {
            try em.push(alloc, keywordOrId(rest[0..id_n], start), i, i + id_n);
            i += id_n;
            continue;
        }
        if (op) |o| {
            try em.push(alloc, o.tok, i, i + o.len);
            i += o.len;
            continue;
        }

        return error.UnexpectedByte;
    }

    return em.toks.toOwnedSlice(alloc);
}
