//!
//! welcome to type serde
//!
//! the text layer of types: text -> TypeExpr in parseTypeExpr below,
//! TypeInfo -> text in printType. TypeExpr printing, cloning, and freeing
//! live next to the TypeExpr definition in ast.zig (pure ast operations),
//! and TypeExpr -> TypeInfo evaluation lives in compiler/types.zig next to
//! inference (it takes an AliasScope filled from the caller's maps).
//! type refs flow one way: here -> ast, here -> compiler/types
//!

const ast = @import("ast.zig");
const Lexer = @import("Lexer.zig");
const std = @import("std");
const types = @import("compiler/types.zig");
const TypeInfo = types.TypeInfo;
const Token = Lexer.Token;
const TokenType = Lexer.TokenType;

/// advances pos past the consumed tokens
/// mirrors ast.printTypeExpr: every Kind parses and prints
pub fn parseTypeExpr(tokens: []const Token, pos: *usize, alloc: std.mem.Allocator) !*ast.TypeExpr {
    var p = Parser{ .tokens = tokens, .pos = pos, .alloc = alloc };
    return try p.parseExpr();
}

const Parser = struct {
    tokens: []const Token,
    pos: *usize,
    alloc: std.mem.Allocator,
    fn peek(self: *Parser) Token {
        while (self.pos.* < self.tokens.len and self.tokens[self.pos.*].type == .comment) {
            self.pos.* += 1;
        }
        return self.tokens[self.pos.*];
    }
    fn advance(self: *Parser) Token {
        const t = self.tokens[self.pos.*];
        self.pos.* += 1;
        return t;
    }
    fn check(self: *Parser, t: TokenType) bool {
        return self.peek().type == t;
    }
    fn match(self: *Parser, t: TokenType) bool {
        if (self.check(t)) {
            _ = self.advance();
            return true;
        }
        return false;
    }
    /// token type ahead positions past pos, skipping comments (lookahead for `?name:`)
    fn peekAt(self: *Parser, ahead: usize) TokenType {
        var i = self.pos.*;
        var skipped: usize = 0;
        while (i < self.tokens.len and skipped <= ahead) : (i += 1) {
            if (self.tokens[i].type == .comment) continue;
            if (skipped == ahead) return self.tokens[i].type;
            skipped += 1;
        }
        return .eof;
    }
    fn expect(self: *Parser, t: TokenType) !Token {
        if (self.check(t)) return self.advance();
        return error.UnexpectedToken;
    }

    fn span(self: *Parser, start: Token) ast.Span {
        return ast.Span.merge(start.span(), self.tokens[self.pos.* - 1].span());
    }

    /// type union expression (lowest-precedence operator)
    /// * "int | string"  "number? | :nil"  "int"
    fn parseExpr(self: *Parser) anyerror!*ast.TypeExpr {
        const left = try self.parseAtom();
        var result = left;
        if (self.match(.bar)) {
            var variants = try std.ArrayList(*ast.TypeExpr).initCapacity(self.alloc, 4);
            errdefer variants.deinit(self.alloc);
            try flattenUnion(self.alloc, &variants, left);
            try flattenUnion(self.alloc, &variants, try self.parseAtom());
            while (self.match(.bar))
                try flattenUnion(self.alloc, &variants, try self.parseAtom());
            result = try ast.allocTypeExpr(self.alloc, left.span, .{ .union_of = try variants.toOwnedSlice(self.alloc) });
        }
        // `!any/:ExpectFailed` - a `/`-tagged error atom after the type; the
        // runtime reads only the union, so claim and drop the tag here too
        if (self.match(.slash)) _ = try self.parseAtom();
        return result;
    }

    /// atomic type expression with no union operators
    /// ~ ident (name):      "number", "string", custom alias
    /// ~ a.T (qualified):   module a's alias T
    /// ~ ident? (optional): "number?" -> union_of(named("number"), atom(":nil"))
    /// ~ ident<T>:          "table<int>", "table<string, int>"
    /// ~ :atom:      ":nil", ":ok", ":err"
    /// ~ fn(T) -> U:        "fn(int) -> bool", "fn<T>(x: T) -> T"
    /// ~ (T):               "(int | string)" (paren grouping)
    /// ~ {f: T, ...}:       "{ name: string, age: num }" (structural table)
    /// ~ {T, f: U, ...}:    "{ number, number, name: string }" (positional array entries)
    /// ~ !T / ?T:           "!int", "?int" (error union - prefix bang or kw_not)
    fn parseAtom(self: *Parser) !*ast.TypeExpr {
        const tok = self.peek();
        switch (tok.type) {
            .ident, .kw_type, .kw_import => {
                const start = self.advance();
                const text = start.text;
                // "number?" -> optional; lexer treats ? as ident-char, so it splits here
                if (std.mem.endsWith(u8, text, "?")) {
                    const name = try ast.allocTypeExpr(self.alloc, start.span(), .{ .named = text[0 .. text.len - 1] });
                    const nil_atom = try ast.allocTypeExpr(self.alloc, start.span(), .{ .atom = ":nil" });
                    const variants = try self.alloc.alloc(*ast.TypeExpr, 2);
                    variants[0] = name;
                    variants[1] = nil_atom;
                    return try ast.allocTypeExpr(self.alloc, start.span(), .{ .union_of = variants });
                }
                if (self.match(.lt)) {
                    var params = try std.ArrayList(*ast.TypeExpr).initCapacity(self.alloc, 4);
                    errdefer params.deinit(self.alloc);
                    try params.append(self.alloc, try self.parseExpr());
                    while (self.match(.comma))
                        try params.append(self.alloc, try self.parseExpr());
                    _ = try self.expect(.gt);
                    return try ast.allocTypeExpr(self.alloc, self.span(start), .{
                        .parameterized = .{ .name = tok.text, .params = try params.toOwnedSlice(self.alloc) },
                    });
                }
                // qualified module type: `a.T` names alias T from module a
                if (self.match(.dot)) {
                    const name_tok = try self.expect(.ident);
                    // `a.b?` is optional, same sugar as `b?` on a bare name
                    //   the lexer glues the `?` onto the ident, so strip it here
                    if (std.mem.endsWith(u8, name_tok.text, "?")) {
                        const named = try ast.allocTypeExpr(self.alloc, name_tok.span(), .{
                            .qualified = .{ .module = tok.text, .name = name_tok.text[0 .. name_tok.text.len - 1] },
                        });
                        const nil_atom = try ast.allocTypeExpr(self.alloc, name_tok.span(), .{ .atom = ":nil" });
                        const variants = try self.alloc.alloc(*ast.TypeExpr, 2);
                        variants[0] = named;
                        variants[1] = nil_atom;
                        return try ast.allocTypeExpr(self.alloc, self.span(start), .{ .union_of = variants });
                    }
                    return try ast.allocTypeExpr(self.alloc, self.span(start), .{
                        .qualified = .{ .module = tok.text, .name = name_tok.text },
                    });
                }
                return try ast.allocTypeExpr(self.alloc, tok.span(), .{ .named = tok.text });
            },
            .atom => {
                return try ast.allocTypeExpr(self.alloc, self.advance().span(), .{ .atom = tok.text });
            },
            .kw_fn => {
                const start = self.advance();
                var tps = try std.ArrayList([]const u8).initCapacity(self.alloc, 2);
                errdefer tps.deinit(self.alloc);
                if (self.match(.lt)) {
                    while (!self.check(.gt)) {
                        const tp_tok = try self.expect(.ident);
                        try tps.append(self.alloc, tp_tok.text);
                        if (!self.match(.comma)) break;
                    }
                    _ = try self.expect(.gt);
                }
                _ = try self.expect(.lparen);
                const params = try self.parseFnParams();
                _ = try self.expect(.rparen);
                const return_type = if (self.match(.arrow)) try self.parseExpr() else null;
                return try ast.allocTypeExpr(self.alloc, self.span(start), .{
                    .function = .{ .params = params, .return_type = return_type, .type_params = try tps.toOwnedSlice(self.alloc) },
                });
            },
            .lparen => {
                _ = self.advance();
                const inner = try self.parseExpr();
                if (self.match(.comma)) return error.UnexpectedToken;
                _ = try self.expect(.rparen);
                return inner;
            },
            .kw_not, .bang => {
                const start = self.advance();
                const inner = try self.parseExpr();
                return try ast.allocTypeExpr(self.alloc, self.span(start), .{ .error_union = inner });
            },
            .lsquiggly => {
                const start = self.advance();
                var fields = try std.ArrayList(ast.RecordField).initCapacity(self.alloc, 4);
                errdefer fields.deinit(self.alloc);
                var pos_idx: u32 = 0;

                while (!self.check(.rsquiggly) and !self.check(.eof)) {
                    // `#* ... *#` before a field documents it (declare tables);
                    // plain `#` comments are already skipped by peek
                    var field_doc: ?[]const u8 = null;
                    while (self.check(.doc_comment)) {
                        const dt = self.advance();
                        field_doc = std.mem.trim(u8, dt.text, " \t\n\r");
                    }
                    // `name:` prefix means a named field, anything else is a
                    // positional array entry (`{ number, number }`); field
                    // names may be contextual kws (`type`, `end`)
                    const cur = self.peek();
                    const is_named = (cur.type == .ident or std.mem.startsWith(u8, @tagName(cur.type), "kw_")) and blk: {
                        var i = self.pos.* + 1;
                        while (i < self.tokens.len and self.tokens[i].type == .comment) : (i += 1) {}
                        break :blk i < self.tokens.len and self.tokens[i].type == .colon;
                    };

                    // `?name:` is an optional field (may be absent);
                    // a bare `?` is the `?T` optional-type prefix instead
                    const is_optional = cur.type == .huh and self.peekAt(1) == .ident and self.peekAt(2) == .colon;
                    if (is_optional) {
                        _ = self.advance();
                        const name_tok = try self.expect(.ident);
                        _ = try self.expect(.colon);
                        try fields.append(self.alloc, .{ .name = name_tok.text, .type_expr = try self.parseExpr(), .optional = true, .doc = field_doc });
                    } else if (is_named) {
                        self.pos.* += 1;
                        _ = try self.expect(.colon);
                        try fields.append(self.alloc, .{ .name = cur.text, .type_expr = try self.parseExpr(), .doc = field_doc });
                    } else {
                        const te = try self.parseExpr();
                        const idx_name = try self.alloc.print("{d}", .{pos_idx});
                        pos_idx += 1;
                        try fields.append(self.alloc, .{ .name = idx_name, .type_expr = te, .doc = field_doc });
                    }

                    if (!self.match(.comma)) break;
                }
                _ = try self.expect(.rsquiggly);
                return try ast.allocTypeExpr(self.alloc, self.span(start), .{
                    .record = try fields.toOwnedSlice(self.alloc),
                });
            },
            else => return error.UnexpectedToken,
        }
    }

    fn parseFnParams(self: *Parser) ![]const ast.FnParam {
        var params = try std.ArrayList(ast.FnParam).initCapacity(self.alloc, 4);
        errdefer params.deinit(self.alloc);
        while (!self.check(.rparen) and !self.check(.eof)) {
            // `?` prefix marks optional params, same as value-level fn syntax
            const optional = self.match(.huh);
            // param names may be contextual keywords (`fn`, `end`)
            const name = self.peek();
            if (name.type != .ident and !std.mem.startsWith(u8, @tagName(name.type), "kw_"))
                return error.UnexpectedToken;
            self.pos.* += 1;
            const type_name = if (self.match(.colon)) try self.parseExpr() else null;
            // `...` lexes as `..` + `.`; claimed only here in type position
            const variadic = self.match(.dotdot) and self.match(.dot);
            // synthesized from a type string, no source span to attach
            try params.append(self.alloc, .{ .name = name.text, .name_span = .{ .start = 0, .end = 0, .line = 0, .column = 0 }, .type_name = type_name, .variadic = variadic, .optional = optional });
            if (!self.match(.comma)) break;
        }
        return try params.toOwnedSlice(self.alloc);
    }
};

fn flattenUnion(alloc: std.mem.Allocator, variants: *std.ArrayList(*ast.TypeExpr), te: *ast.TypeExpr) !void {
    if (te.kind == .union_of) {
        try variants.appendSlice(alloc, te.kind.union_of);
    } else {
        try variants.append(alloc, te);
    }
}

/// render a TypeInfo straight to the writer
/// trailing params past required_count print `?` (for optional)
pub fn printType(ti: TypeInfo, writer: *std.Io.Writer, opts: PrintOptions) !void {
    if (opts.short) {
        switch (ti.tag) {
            .atom => |s| if (s.len == 0)
                try writer.writeAll("atom")
            else if (s[0] == ':')
                try writer.writeAll(s)
            else
                try writer.print(":{s}", .{s}),
            .type_var => |s| try writer.writeAll(s),
            .table => try writer.writeAll("table"),
            .function => try writer.writeAll("function"),
            // all these are spelled out so a future payload-carrying tag breaks
            // compilation here instead of just printing its tag name
            .bool, .number, .string, .resource, .any, .never, .@"union" => try writer.writeAll(@tagName(ti.tag)),
        }
        return;
    }
    switch (ti.tag) {
        .type_var => |n| try writer.writeAll(n),
        // empty atom payload is the "any atom" sentinel
        .atom => |s| if (s.len == 0) try writer.writeAll("atom") else try writer.print(":{s}", .{ast.atomName(s)}),
        .@"union" => |variants| {
            // `T?`, for a 2-union ending in `:nil`
            if (variants.len == 2 and variants[1].types.len == 1 and variants[1].types[0].tag == .atom and
                std.mem.eql(u8, ast.atomName(variants[1].types[0].tag.atom), "nil"))
            {
                const first = variants[0].types;
                try printType(first[0], writer, opts);

                try writer.writeByte('?');
            } else for (variants, 0..) |v, i| {
                if (i > 0) try writer.writeAll(" | ");
                try printType(v.types[0], writer, opts);
            }
        },
        .table => |tbl| {
            if (tbl.fields) |fields| {
                try writer.writeByte('{');
                for (fields, 0..) |f, i| {
                    if (i > 0) try writer.writeAll(", ");
                    // numeric names are positional array entries
                    const positional = ast.isPositionalName(f.name);
                    if (!positional) {
                        if (f.optional) try writer.writeByte('?');
                        try writer.writeAll(f.name);
                        try writer.writeAll(": ");
                    }

                    try printType(f.field_type, writer, opts);
                    for (opts.values) |p| if (std.mem.eql(u8, p.name, f.name)) {
                        try writer.writeAll(" = ");
                        try writer.writeAll(p.preview);
                        break;
                    };
                }
                try writer.writeByte('}');
            } else if (tbl.key == null and tbl.value.tag == .any) {
                // bare `table` still bare
                // TODO: remove in favour of `{}`
                try writer.writeAll("table");
            } else {
                try writer.writeAll("table<");
                if (tbl.key) |k| {
                    try printType(k.*, writer, opts);
                    try writer.writeAll(", ");
                }

                try printType(tbl.value.*, writer, opts);
                try writer.writeByte('>');
            }
        },
        .function => |sig| {
            try writer.writeAll("fn(");
            for (sig.params, 0..) |p, i| {
                if (i > 0) try writer.writeAll(", ");
                // required params come first, so everything past
                // required_count is `?`
                if (i >= sig.required_count) try writer.writeByte('?');
                const name = if (i < sig.param_names.len) sig.param_names[i] else "";
                if (name.len > 0) {
                    try writer.writeAll(name);
                    try writer.writeAll(": ");
                }
                try printType(p, writer, opts);
            }
            try writer.writeByte(')');
            try writer.writeAll(" -> ");
            try printType(sig.return_type, writer, opts);
        },
        .bool => try writer.writeAll("bool"),
        .number => try writer.writeAll("number"),
        .string => try writer.writeAll("string"),
        .resource => try writer.writeAll("resource"),
        .any => try writer.writeAll("any"),
        .never => try writer.writeAll("never"),
    }
}

/// short gives single-word tag names
/// values appends ` = <preview>` per record field (hover)
pub const PrintOptions = struct {
    short: bool = false,
    values: []const FieldPreview = &.{},
};

pub const FieldPreview = struct {
    name: []const u8,
    preview: []const u8,
};

/// formatType with display options (`.short` for tag words, `.values` for hover)
pub fn formatTypeOpts(alloc: std.mem.Allocator, ti: TypeInfo, opts: PrintOptions) std.mem.Allocator.Error![]const u8 {
    var buf = std.Io.Writer.Allocating.init(alloc);
    errdefer buf.deinit();

    // allocating writer only fails on oom
    // printType is generic over writers so its error set is wider than what happens here
    printType(ti, &buf.writer, opts) catch |err| {
        if (err != error.OutOfMemory) unreachable;
        return error.OutOfMemory;
    };
    return try buf.toOwnedSlice();
}

test "qualified optional type is a nilable union" {
    // `a.b?` used to read as the name `b?`, so `a.b` never resolved
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try Lexer.lexAt(alloc, "argparse.ResultMsg?", .{});
    var pos: usize = 0;
    const te = try parseTypeExpr(tokens, &pos, alloc);

    try std.testing.expect(te.kind == .union_of);
    const variants = te.kind.union_of;
    try std.testing.expectEqual(@as(usize, 2), variants.len);
    try std.testing.expect(variants[0].kind == .qualified);
    try std.testing.expectEqualStrings("argparse", variants[0].kind.qualified.module);
    try std.testing.expectEqualStrings("ResultMsg", variants[0].kind.qualified.name);
    try std.testing.expectEqualStrings(":nil", variants[1].kind.atom);
}

test "type serde roundtrips" {
    const cases = [_][]const u8{
        "{number, number, name: string}",
        "{number, :err, atom}",
        "{name: string}",
        "{}",
        "number?",
        "fn() -> string",
        "fn(a: number) -> string",
        "fn(?a: number) -> string",
        "table<string, number>",
        "{user: {name: string}}",
        "{:ok, any}",
        "{:ok, any} | {:err, any}",
    };
    for (cases) |c| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const tokens = try Lexer.lexAt(alloc, c, .{});
        var pos: usize = 0;
        const te = try parseTypeExpr(tokens, &pos, alloc);
        const ti = try types.evalBare(alloc, te);
        try std.testing.expectEqualStrings(c, try formatTypeOpts(alloc, ti, .{}));
    }
}
