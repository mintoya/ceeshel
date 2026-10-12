//! Translate this grammar's generated LR tables to the native Zig runtime.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Failure = Allocator.Error || error{ InvalidGeneratedParser, WriteFailed };

const Cursor = struct {
    tokens: []const []const u8,
    at: usize = 0,

    fn peek(self: Cursor) []const u8 {
        return if (self.at < self.tokens.len) self.tokens[self.at] else "";
    }
    fn take(self: *Cursor) Failure![]const u8 {
        if (self.at == self.tokens.len) return error.InvalidGeneratedParser;
        const token = self.tokens[self.at];
        self.at += 1;
        return token;
    }
    fn eat(self: *Cursor, token: []const u8) bool {
        if (!std.mem.eql(u8, self.peek(), token)) return false;
        self.at += 1;
        return true;
    }
    fn expect(self: *Cursor, token: []const u8) Failure!void {
        if (!self.eat(token)) return error.InvalidGeneratedParser;
    }
    fn number(self: *Cursor) Failure!u16 {
        return std.fmt.parseInt(u16, try self.take(), 10) catch error.InvalidGeneratedParser;
    }
};

fn tokenize(gpa: Allocator, source: []const u8) Failure![]const []const u8 {
    var tokens: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < source.len) {
        if (std.ascii.isWhitespace(source[i])) {
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, source[i..], "//")) {
            i += std.mem.indexOfScalar(u8, source[i..], '\n') orelse source.len - i;
            continue;
        }
        if (std.mem.startsWith(u8, source[i..], "/*")) {
            i += 2;
            i += (std.mem.indexOf(u8, source[i..], "*/") orelse return error.InvalidGeneratedParser) + 2;
            continue;
        }
        const start = i;
        const quote = source[i];
        if (quote == '"' or quote == '\'') {
            i += 1;
            while (i < source.len and source[i] != quote) : (i += 1) {
                if (source[i] == '\\') i += 1;
            }
            if (i == source.len) return error.InvalidGeneratedParser;
            i += 1;
        } else if (std.ascii.isAlphanumeric(source[i]) or source[i] == '_') {
            i += 1;
            while (i < source.len and (std.ascii.isAlphanumeric(source[i]) or source[i] == '_')) : (i += 1) {}
        } else i += 1;
        try tokens.append(gpa, source[start..i]);
    }
    return tokens.toOwnedSlice(gpa);
}

fn initializer(tokens: []const []const u8, name: []const u8, is_enum: bool) Failure!Cursor {
    for (tokens, 0..) |token, i| {
        if (!std.mem.eql(u8, token, name)) continue;
        var cursor: Cursor = .{ .tokens = tokens, .at = i + 1 };
        if (!is_enum) while (!cursor.eat("=")) {
            _ = try cursor.take();
        };
        while (!cursor.eat("{")) {
            _ = try cursor.take();
        }
        const start = cursor.at;
        var depth: usize = 1;
        while (depth != 0) {
            const t = try cursor.take();
            if (std.mem.eql(u8, t, "{")) depth += 1;
            if (std.mem.eql(u8, t, "}")) depth -= 1;
        }
        return .{ .tokens = tokens[start .. cursor.at - 1] };
    }
    return error.InvalidGeneratedParser;
}

fn define(tokens: []const []const u8, name: []const u8) Failure!u16 {
    for (tokens, 0..) |token, i| {
        if (i > 0 and std.mem.eql(u8, token, name) and std.mem.eql(u8, tokens[i - 1], "define")) {
            return std.fmt.parseInt(u16, tokens[i + 1], 10) catch error.InvalidGeneratedParser;
        }
    }
    return error.InvalidGeneratedParser;
}

const Symbol = struct {
    name: []const u8 = "",
    public: u16 = 0,
    visible: bool = false,
    named: bool = false,
};
const Reduce = struct { symbol: u16, count: u16, precedence: i32, production: u16 };
const Action = union(enum) { none, extra, shift: u16, reduce: Reduce, accept, recover };
const Entry = struct { kind: enum { action, goto }, index: u16 };
const Field = struct { name: []const u8, child: u16 };
const Slice = struct { index: u16 = 0, length: u16 = 0 };

const Generator = struct {
    gpa: Allocator,
    tokens: []const []const u8,
    ids: std.StringHashMap(u16),
    symbols: []Symbol,
    actions: std.AutoHashMap(u16, Action),
    states: [][]?Entry,
    fields: []const []const u8,
    bindings: []const Field,
    productions: []Slice,
    token_count: u16,

    fn symbol(self: Generator, cursor: *Cursor) Failure!u16 {
        return self.ids.get(try cursor.take()) orelse error.InvalidGeneratedParser;
    }

    fn init(gpa: Allocator, source: []const u8) Failure!Generator {
        const tokens = try tokenize(gpa, source);
        const symbols = try gpa.alloc(Symbol, try define(tokens, "SYMBOL_COUNT"));
        for (symbols, 0..) |*sym, i| sym.* = .{ .public = @intCast(i) };
        var self: Generator = .{
            .gpa = gpa,
            .tokens = tokens,
            .symbols = symbols,
            .ids = std.StringHashMap(u16).init(gpa),
            .actions = std.AutoHashMap(u16, Action).init(gpa),
            .states = try gpa.alloc([]?Entry, try define(tokens, "STATE_COUNT")),
            .fields = &.{},
            .bindings = &.{},
            .productions = try gpa.alloc(Slice, try define(tokens, "PRODUCTION_ID_COUNT")),
            .token_count = try define(tokens, "TOKEN_COUNT"),
        };
        for (self.states) |*state| {
            state.* = try gpa.alloc(?Entry, symbols.len);
            @memset(state.*, null);
        }
        @memset(self.productions, .{});
        try self.ids.put("ts_builtin_sym_end", 0);
        var cursor = try initializer(tokens, "ts_symbol_identifiers", true);
        while (cursor.peek().len != 0) {
            const name = try cursor.take();
            try cursor.expect("=");
            const id = try cursor.number();
            if (id >= symbols.len) return error.InvalidGeneratedParser;
            try self.ids.put(name, id);
            try cursor.expect(",");
        }
        cursor = try initializer(tokens, "ts_symbol_names", false);
        while (cursor.eat("[")) {
            const id = try self.symbol(&cursor);
            try cursor.expect("]");
            try cursor.expect("=");
            // Generated names are string literals valid in both C and Zig.
            symbols[id].name = try cursor.take();
            try cursor.expect(",");
        }
        cursor = try initializer(tokens, "ts_symbol_map", false);
        while (cursor.eat("[")) {
            const id = try self.symbol(&cursor);
            try cursor.expect("]");
            try cursor.expect("=");
            symbols[id].public = try self.symbol(&cursor);
            try cursor.expect(",");
        }
        cursor = try initializer(tokens, "ts_symbol_metadata", false);
        while (cursor.eat("[")) {
            const id = try self.symbol(&cursor);
            try cursor.expect("]");
            try cursor.expect("=");
            try cursor.expect("{");
            while (!cursor.eat("}")) {
                try cursor.expect(".");
                const key = try cursor.take();
                try cursor.expect("=");
                const enabled = std.mem.eql(u8, try cursor.take(), "true");
                if (std.mem.eql(u8, key, "visible")) symbols[id].visible = enabled else if (std.mem.eql(u8, key, "named")) symbols[id].named = enabled else return error.InvalidGeneratedParser;
                try cursor.expect(",");
            }
            try cursor.expect(",");
        }
        try self.readActions();
        try self.readStates();
        try self.readFields();
        // This grammar has no production aliases or external C scanner.
        if (try define(tokens, "EXTERNAL_TOKEN_COUNT") != 0) return error.InvalidGeneratedParser;
        cursor = try initializer(tokens, "ts_alias_sequences", false);
        try cursor.expect("[");
        if (try cursor.number() != 0) return error.InvalidGeneratedParser;
        try cursor.expect("]");
        try cursor.expect("=");
        try cursor.expect("{");
        if (try cursor.number() != 0) return error.InvalidGeneratedParser;
        try cursor.expect("}");
        try cursor.expect(",");
        if (cursor.peek().len != 0) return error.InvalidGeneratedParser;
        return self;
    }

    fn readActions(self: *Generator) Failure!void {
        var cursor = try initializer(self.tokens, "ts_parse_actions", false);
        while (cursor.eat("[")) {
            const index = try cursor.number();
            try cursor.expect("]");
            try cursor.expect("=");
            try cursor.expect("{");
            try cursor.expect(".");
            try cursor.expect("entry");
            try cursor.expect("=");
            try cursor.expect("{");
            try cursor.expect(".");
            try cursor.expect("count");
            try cursor.expect("=");
            const count = try cursor.number();
            try cursor.expect(",");
            try cursor.expect(".");
            try cursor.expect("reusable");
            try cursor.expect("=");
            _ = try cursor.take();
            try cursor.expect("}");
            try cursor.expect("}");
            try cursor.expect(",");
            if (count > 2) return error.InvalidGeneratedParser;
            var action: Action = .none;
            for (0..count) |i| {
                const kind = try cursor.take();
                try cursor.expect("(");
                var next: Action = undefined;
                if (std.mem.eql(u8, kind, "SHIFT") or std.mem.eql(u8, kind, "SHIFT_REPEAT")) next = .{ .shift = try cursor.number() } else if (std.mem.eql(u8, kind, "REDUCE")) {
                    const symbol_id = try self.symbol(&cursor);
                    try cursor.expect(",");
                    const children = try cursor.number();
                    try cursor.expect(",");
                    const negative = cursor.eat("-");
                    const precedence: i32 = try cursor.number();
                    try cursor.expect(",");
                    const production = try cursor.number();
                    if (children == 0) {
                        if (symbol_id != self.ids.get("sym_program").?) return error.InvalidGeneratedParser;
                        next = .accept;
                    } else next = .{ .reduce = .{ .symbol = symbol_id, .count = children, .precedence = if (negative) -precedence else precedence, .production = production } };
                } else if (std.mem.eql(u8, kind, "SHIFT_EXTRA")) next = .extra else if (std.mem.eql(u8, kind, "ACCEPT_INPUT")) next = .accept else if (std.mem.eql(u8, kind, "RECOVER")) next = .recover else return error.InvalidGeneratedParser;
                try cursor.expect(")");
                try cursor.expect(",");
                if (i == 1) {
                    if (action != .reduce or next != .shift) return error.InvalidGeneratedParser;
                    const reduced = action.reduce.symbol;
                    const allowed = [_][]const u8{ "aux_sym_program_repeat1", "aux_sym_nblock_repeat1", "sym_nblock", "sym__expression" };
                    var known = false;
                    for (allowed) |name| if (self.ids.get(name)) |id| {
                        if (id == reduced) {
                            known = true;
                            break;
                        }
                    };
                    if (!known) return error.InvalidGeneratedParser;
                    // Complete a type expression before the second '~'.
                    if (reduced == self.ids.get("sym__expression").?) continue;
                }
                action = next;
            }
            try self.actions.put(index, action);
        }
    }

    fn tableEntry(cursor: *Cursor) Failure!Entry {
        const kind = try cursor.take();
        try cursor.expect("(");
        const index = try cursor.number();
        try cursor.expect(")");
        return .{ .kind = if (std.mem.eql(u8, kind, "ACTIONS")) .action else if (std.mem.eql(u8, kind, "STATE")) .goto else return error.InvalidGeneratedParser, .index = index };
    }

    fn readStates(self: *Generator) Failure!void {
        var cursor = try initializer(self.tokens, "ts_parse_table", false);
        while (cursor.eat("[")) {
            try cursor.expect("STATE");
            try cursor.expect("(");
            const state = try cursor.number();
            try cursor.expect(")");
            try cursor.expect("]");
            try cursor.expect("=");
            try cursor.expect("{");
            while (cursor.eat("[")) {
                const symbol_id = try self.symbol(&cursor);
                try cursor.expect("]");
                try cursor.expect("=");
                self.states[state][symbol_id] = try tableEntry(&cursor);
                try cursor.expect(",");
            }
            try cursor.expect("}");
            try cursor.expect(",");
        }
        var offsets = std.AutoHashMap(u16, u16).init(self.gpa);
        cursor = try initializer(self.tokens, "ts_small_parse_table_map", false);
        const large = try define(self.tokens, "LARGE_STATE_COUNT");
        while (cursor.eat("[")) {
            try cursor.expect("SMALL_STATE");
            try cursor.expect("(");
            const state = try cursor.number();
            try cursor.expect(")");
            try cursor.expect("]");
            try cursor.expect("=");
            const offset = try cursor.number();
            if (state < large or state >= self.states.len) return error.InvalidGeneratedParser;
            try offsets.put(offset, state);
            try cursor.expect(",");
        }
        cursor = try initializer(self.tokens, "ts_small_parse_table", false);
        while (cursor.eat("[")) {
            const offset = try cursor.number();
            try cursor.expect("]");
            try cursor.expect("=");
            const state = offsets.get(offset) orelse return error.InvalidGeneratedParser;
            const groups = try cursor.number();
            try cursor.expect(",");
            for (0..groups) |_| {
                const entry = try tableEntry(&cursor);
                try cursor.expect(",");
                const count = try cursor.number();
                try cursor.expect(",");
                for (0..count) |_| {
                    self.states[state][try self.symbol(&cursor)] = entry;
                    try cursor.expect(",");
                }
            }
        }
    }

    fn readFields(self: *Generator) Failure!void {
        var field_ids = std.StringHashMap(u16).init(self.gpa);
        const names = try self.gpa.alloc([]const u8, try define(self.tokens, "FIELD_COUNT"));
        var cursor = try initializer(self.tokens, "ts_field_names", false);
        while (cursor.eat("[")) {
            const key = try cursor.take();
            try cursor.expect("]");
            try cursor.expect("=");
            const name = try cursor.take();
            if (!std.mem.eql(u8, key, "0")) {
                const index: u16 = @intCast(field_ids.count());
                names[index] = name;
                try field_ids.put(key, index);
            }
            try cursor.expect(",");
        }
        self.fields = names;
        cursor = try initializer(self.tokens, "ts_field_map_slices", false);
        while (cursor.eat("[")) {
            const prod = try cursor.number();
            try cursor.expect("]");
            try cursor.expect("=");
            try cursor.expect("{");
            try cursor.expect(".");
            try cursor.expect("index");
            try cursor.expect("=");
            const index = try cursor.number();
            try cursor.expect(",");
            try cursor.expect(".");
            try cursor.expect("length");
            try cursor.expect("=");
            const length = try cursor.number();
            try cursor.expect("}");
            try cursor.expect(",");
            self.productions[prod] = .{ .index = index, .length = length };
        }
        var bindings: std.ArrayList(Field) = .empty;
        cursor = try initializer(self.tokens, "ts_field_map_entries", false);
        while (cursor.peek().len != 0) {
            if (cursor.eat("[")) {
                if (try cursor.number() != bindings.items.len) return error.InvalidGeneratedParser;
                try cursor.expect("]");
                try cursor.expect("=");
            }
            try cursor.expect("{");
            const field_id = field_ids.get(try cursor.take()) orelse return error.InvalidGeneratedParser;
            try cursor.expect(",");
            const child = try cursor.number();
            try cursor.expect("}");
            try cursor.expect(",");
            try bindings.append(self.gpa, .{ .name = names[field_id], .child = child });
        }
        self.bindings = bindings.items;
    }

    fn writeAction(writer: *std.Io.Writer, action: Action) !void {
        switch (action) {
            .none => try writer.writeAll(".none"),
            .accept => try writer.writeAll(".accept"),
            .recover => try writer.writeAll(".recover"),
            .shift => |state| try writer.print(".{{ .shift = {d} }}", .{state}),
            .reduce => |r| try writer.print(".{{ .reduce = .{{ .symbol = {d}, .child_count = {d}, .dynamic_precedence = {d}, .production_id = {d} }} }}", .{ r.symbol, r.count, r.precedence, r.production }),
            .extra => unreachable,
        }
    }

    fn write(self: Generator, writer: *std.Io.Writer) !void {
        try writer.writeAll("// Generated by tools/generate_native_parser.zig; do not edit.\nconst ts = @import(\"treesitter\");\npub const lexer = @import(\"lexer.zig\");\nconst lex = lexer;\npub const language: ts.Language = .{\n");
        try writer.print(".metadata = .{{ .name = \"cshl\", .abi_version = ts.currentAbiVersion, .symbol_count = {d}, .state_count = {d}, .field_count = {d} }},\n.symbols = &.{{\n", .{ self.symbols.len + 2, self.states.len, self.fields.len });
        for (self.symbols, 0..) |symbol_info, i| {
            const public = self.symbols[symbol_info.public];
            const kind = if (i == 0) "end" else if (i < self.token_count) "terminal" else "non_terminal";
            const extra = i == self.ids.get("sym_comment").?;
            try writer.print(".{{ .id = {d}, .name = {s}, .kind = .{s}, .metadata = .{{ .visible = {}, .named = {}, .extra = {} }} }},\n", .{ i, public.name, kind, public.visible, public.named, extra });
        }
        const err = self.symbols.len;
        const space = err + 1;
        try writer.print(".{{ .id = {d}, .name = \"ERROR\", .kind = .non_terminal }},\n.{{ .id = {d}, .name = \"whitespace\", .metadata = .{{ .named = false, .visible = false, .extra = true }} }},\n}},\n.extra_symbols = &.{{ {d}, {d} }},\n", .{ err, space, self.ids.get("sym_comment").?, space });
        try writer.print(".token_matchers = &.{{ .{{ .symbol = {d}, .match = lex.whitespace }}, .{{ .symbol = {d}, .match = lex.comment }} }},\n", .{ space, self.ids.get("sym_comment").? });
        try writer.print(".external_scanner = .{{ .scan = lex.scan, .reset = lex.reset }},\n.table = .{{ .start_state = 1, .end_symbol = 0, .error_symbol = {d}, .states = &.{{\n", .{err});
        for (self.states) |state| {
            try writer.writeAll(".{ .actions = &.{\n");
            for (state, 0..) |maybe_entry, symbol_id| if (maybe_entry) |entry| {
                if (entry.kind != .action) continue;
                const action = self.actions.get(entry.index) orelse return error.InvalidGeneratedParser;
                if (action == .extra) continue;
                try writer.print(".{{ .symbol = {d}, .action = ", .{symbol_id});
                try writeAction(writer, action);
                try writer.writeAll(" },\n");
            };
            try writer.writeAll("}, .gotos = &.{\n");
            for (state, 0..) |maybe_entry, symbol_id| if (maybe_entry) |entry| {
                if (entry.kind == .goto) try writer.print(".{{ .symbol = {d}, .state = {d} }},\n", .{ symbol_id, entry.index });
            };
            try writer.writeAll("} },\n");
        }
        try writer.writeAll("} },\n.fields = .{ .names = &.{");
        for (self.fields) |field| try writer.print("{s},", .{field});
        try writer.writeAll("}, .productions = &.{\n");
        for (self.productions, 0..) |slice, prod| {
            if (slice.length == 0) continue;
            try writer.print(".{{ .production_id = {d}, .bindings = &.{{\n", .{prod});
            for (self.bindings[slice.index..][0..slice.length]) |field| try writer.print(".{{ .name = {s}, .child_index = {d} }},\n", .{ field.name, field.child });
            try writer.writeAll("} },\n");
        }
        try writer.writeAll("} },\n};\npub const tokens = struct {\n");
        for (0..self.token_count) |id| {
            var it = self.ids.iterator();
            while (it.next()) |entry| if (entry.value_ptr.* == id) {
                try writer.print("pub const {s} = {d};\n", .{ entry.key_ptr.*, id });
                break;
            };
        }
        try writer.writeAll("};\n");
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    var args = try init.minimal.args.iterateAllocator(gpa);
    _ = args.next();
    const input = args.next() orelse return error.MissingInputPath;
    const output = args.next() orelse return error.MissingOutputPath;
    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, input, gpa, .unlimited);
    const generator = try Generator.init(gpa, source);
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    try generator.write(&buffer.writer);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output, .data = buffer.written() });
}
