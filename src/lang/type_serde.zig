//!
//! welcome to our type serde
//!
//! all type text conversion is here: text -> TypeExpr -> TypeInfo and back
//! the two mirrors (parse/printTypeExpr, evalTypeExpr/toTypeExpr) must stay in sync
//!     keep them adjacent.
//!
//! the ast <-> type_serde cycle is intentional:
//! Node printing embeds type printing, so ast calls printTypeExpr while this module
//! operates on ast.TypeExpr
//! type refs flow one way (here -> ast only)
//! dont add comptime cross-refs
//! same shape as the revo <-> vm cycle

const std = @import("std");
const ast = @import("ast.zig");
const Lexer = @import("Lexer.zig");
const types = @import("compiler/types.zig");
const TypeInfo = types.TypeInfo;
const UnionVariant = types.UnionVariant;
const Token = Lexer.Token;
const TokenType = Lexer.TokenType;

/// parse a type string from stdlib annotations and compiler fn signatures
/// handles T... (variadic marker, stripped) and delegates to parse() + evalTypeExpr()
/// ex: "number?" -> int | :nil,  "string..." -> string,  "int | :nil" -> int | :nil
///     ctx must support .alloc and .resolveTypeAlias(name) -> ?TypeInfo
pub fn parseTypeString(ctx: anytype, s: []const u8) !TypeInfo {
    const trimmed = if (std.mem.endsWith(u8, s, "...")) s[0 .. s.len - 3] else s;
    if (trimmed.len == 0) return .{ .tag = .any };
    const tokens = try Lexer.lexAt(ctx.alloc, trimmed, .{});
    var pos: usize = 0;
    const te = try parse(tokens, &pos, ctx.alloc);
    return try evalTypeExpr(ctx, te);
}

/// shared shim for parseTypeString callers that work against raw spec strings
pub const BareCtx = struct {
    alloc: std.mem.Allocator,
    pub fn isTypeParam(_: @This(), _: []const u8) bool {
        return false;
    }
    pub fn resolveTypeAlias(_: @This(), _: []const u8) ?types.TypeInfo {
        return null;
    }

    /// bare ctx has no module scope, so qualified types always degrade
    pub fn resolveImportAlias(_: @This(), _: []const u8, _: []const u8) ?types.TypeInfo {
        return null;
    }
};

/// advances pos past the consumed tokens
pub fn parse(tokens: []const Token, pos: *usize, alloc: std.mem.Allocator) !*ast.TypeExpr {
    var p = Parser{ .tokens = tokens, .pos = pos, .alloc = alloc };
    return try p.parseExpr();
}

/// type params declared in a generic sig head, e.g. `tuple:unwrap[T](self: (:err, T)) -> T`
/// -> @["T"]. names borrow the sig string; empty when the head has no `[...]`
pub fn sigTypeParams(alloc: std.mem.Allocator, sig: []const u8) ![]const []const u8 {
    const head_end = std.mem.indexOfScalar(u8, sig, '(') orelse sig.len;
    const head = sig[0..head_end];
    const open = std.mem.indexOfScalar(u8, head, '[') orelse return &.{};
    const close = std.mem.indexOfScalar(u8, head[open + 1 ..], ']') orelse return &.{};
    const body = head[open + 1 .. open + 1 + close];
    var out = try std.ArrayList([]const u8).initCapacity(alloc, 2);
    errdefer out.deinit(alloc);
    var it = std.mem.splitScalar(u8, body, ',');
    while (it.next()) |p| {
        const t = std.mem.trim(u8, p, " ");
        if (t.len == 0) continue;
        try out.append(alloc, t);
    }
    return out.toOwnedSlice(alloc);
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
        if (self.match(.pipe)) {
            var variants = try std.ArrayList(*ast.TypeExpr).initCapacity(self.alloc, 4);
            errdefer variants.deinit(self.alloc);
            try flattenUnion(self.alloc, &variants, left);
            try flattenUnion(self.alloc, &variants, try self.parseAtom());
            while (self.match(.pipe))
                try flattenUnion(self.alloc, &variants, try self.parseAtom());
            result = try ast.allocTypeExpr(self.alloc, left.span, .{ .union_of = try variants.toOwnedSlice(self.alloc) });
        }
        // `!any/:ExpectFailed` - a `/`-tagged error atom after the type; the
        // runtime reads only the union, so claim and drop the tag here too
        if (self.match(.slash)) _ = try self.parseAtom();
        return result;
    }

    /// atomic type expression with no union operators
    /// ~ ident (name):      "number", "string", "MyStruct"
    /// ~ a.T (qualified):   module a's alias T
    /// ~ ident? (optional): "number?" -> union_of(named("number"), atom(":nil"))
    /// ~ ident<T>:          "table<int>", "table<string, int>"
    /// ~ :atom (hash):      ":nil", ":ok", ":err"
    /// ~ fn(T) -> U:        "fn(int) -> bool"
    /// ~ (T):               "(int | string)" (paren grouping), "(int, string)" (tuple)
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
                    return try ast.allocTypeExpr(self.alloc, self.span(start), .{
                        .qualified = .{ .module = tok.text, .name = name_tok.text },
                    });
                }
                return try ast.allocTypeExpr(self.alloc, tok.span(), .{ .named = tok.text });
            },
            .hash => {
                return try ast.allocTypeExpr(self.alloc, self.advance().span(), .{ .atom = tok.text });
            },
            .kw_fn => {
                const start = self.advance();
                _ = try self.expect(.lparen);
                const params = try self.parseFnParams();
                _ = try self.expect(.rparen);
                const return_type = if (self.match(.arrow)) try self.parseExpr() else null;
                return try ast.allocTypeExpr(self.alloc, self.span(start), .{
                    .function = .{ .params = params, .return_type = return_type },
                });
            },
            .lparen => {
                const start = self.advance();
                const inner = try self.parseExpr();
                if (self.match(.comma)) {
                    var items = try std.ArrayList(*ast.TypeExpr).initCapacity(self.alloc, 4);
                    errdefer items.deinit(self.alloc);
                    try items.append(self.alloc, inner);
                    while (!self.check(.rparen)) {
                        try items.append(self.alloc, try self.parseExpr());
                        if (!self.match(.comma)) break;
                    }
                    _ = try self.expect(.rparen);
                    return try ast.allocTypeExpr(self.alloc, self.span(start), .{
                        .tuple = try items.toOwnedSlice(self.alloc),
                    });
                }
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
                    // `name:` prefix means a named field, anything else is a
                    // positional array entry (`{ number, number }`); field
                    // names may be contextual kws (`type`, `end`)
                    const cur = self.peek();
                    const is_named = (cur.type == .ident or std.mem.startsWith(u8, @tagName(cur.type), "kw_")) and blk: {
                        var i = self.pos.* + 1;
                        while (i < self.tokens.len and self.tokens[i].type == .comment) : (i += 1) {}
                        break :blk i < self.tokens.len and self.tokens[i].type == .colon;
                    };

                    if (is_named) {
                        self.pos.* += 1;
                        _ = try self.expect(.colon);
                        try fields.append(self.alloc, .{ .name = cur.text, .type_expr = try self.parseExpr() });
                    } else {
                        const te = try self.parseExpr();
                        const idx_name = try std.fmt.allocPrint(self.alloc, "{d}", .{pos_idx});
                        pos_idx += 1;
                        try fields.append(self.alloc, .{ .name = idx_name, .type_expr = te });
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
            // param names may be contextual keywords (`fn`, `end`)
            const name = self.peek();
            if (name.type != .ident and !std.mem.startsWith(u8, @tagName(name.type), "kw_"))
                return error.UnexpectedToken;
            self.pos.* += 1;
            const type_name = if (self.match(.colon)) try self.parseExpr() else null;
            // `...` lexes as `..` + `.`; claimed only here in type position
            const variadic = self.match(.dotdot) and self.match(.dot);
            // synthesized from a type string, no source span to attach
            try params.append(self.alloc, .{ .name = name.text, .name_span = .{ .start = 0, .end = 0, .line = 0, .column = 0 }, .type_name = type_name, .variadic = variadic });
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

/// type ast back into a TypeInfo
/// every TypeExpr kind must be handled here; this is the single place where AST type
/// nodes becomes semantic TypeInfo values. mirrors toTypeExpr below
/// ctx must support .alloc, .isTypeParam(name) -> bool, and .resolveTypeAlias(name) -> ?TypeInfo
pub fn evalTypeExpr(ctx: anytype, te: *const ast.TypeExpr) !TypeInfo {
    switch (te.kind) {
        // "number" -> int (from type_name_map), "MyStruct" -> struct_type
        .named => |name| {
            if (ctx.isTypeParam(name)) return .{ .tag = .{ .type_var = name } };
            if (types.type_name_map.get(name)) |res| return res;
            if (ctx.resolveTypeAlias(name)) |aliased| return aliased;
            return .{ .tag = .{ .struct_type = name } };
        },
        // "a.T" -> module a's alias T, or any when unresolvable (the
        // compiler has no dep IO, so it always lands here; semantic
        // validates qualified names separately and errors first)
        .qualified => |q| {
            if (ctx.resolveImportAlias(q.module, q.name)) |t| return t;
            return .{ .tag = .any };
        },
        // ":nil", ":ok" -> atom
        .atom => |name| return .{ .tag = .{ .atom = name } },
        // "(int, string)" -> tuple(@[int, string])
        .tuple => |items| {
            var resolved = try std.ArrayList(TypeInfo).initCapacity(ctx.alloc, items.len);
            errdefer resolved.deinit(ctx.alloc);
            for (items) |item| try resolved.append(ctx.alloc, try evalTypeExpr(ctx, item));
            return .{ .tag = .{ .tuple = try resolved.toOwnedSlice(ctx.alloc) } };
        },
        // "int | :nil" -> union(@[{name="", types=@[int]}, {name="", types=@[:nil]}])
        // "number?" -> union_of(named("number"), atom(":nil")) from parseAtom
        .union_of => |variants| {
            var collected = try std.ArrayList(UnionVariant).initCapacity(ctx.alloc, 4);
            errdefer collected.deinit(ctx.alloc);
            for (variants) |v| {
                const inner = try evalTypeExpr(ctx, v);
                try types.collectVariants(ctx.alloc, inner, &collected);
            }
            return .{ .tag = .{ .@"union" = try collected.toOwnedSlice(ctx.alloc) } };
        },
        // "fn(int) -> bool" -> function(param_types=@[int], return_type=bool)
        .function => |f| {
            var param_types = try std.ArrayList(TypeInfo).initCapacity(ctx.alloc, f.params.len);
            errdefer param_types.deinit(ctx.alloc);
            for (f.params) |p| {
                try param_types.append(ctx.alloc, if (p.type_name) |tn| try evalTypeExpr(ctx, tn) else .{ .tag = .any });
            }

            var param_names = try std.ArrayList([]const u8).initCapacity(ctx.alloc, f.params.len);
            errdefer param_names.deinit(ctx.alloc);
            for (f.params) |p| try param_names.append(ctx.alloc, p.name);
            const return_type = if (f.return_type) |rt| try evalTypeExpr(ctx, rt) else TypeInfo{ .tag = .any };

            const sig = try types.newSignature(ctx.alloc, .{
                .param_names = try param_names.toOwnedSlice(ctx.alloc),
                .params = try param_types.toOwnedSlice(ctx.alloc),
                .return_type = return_type,
                .required_count = f.params.len,
            });

            return .{ .tag = .{ .function = sig } };
        },
        // "table<int>" -> table(key=null, value=int), "table<string, int>" -> table(key=string, value=int)
        .parameterized => |p| {
            var params = try std.ArrayList(TypeInfo).initCapacity(ctx.alloc, p.params.len);
            errdefer params.deinit(ctx.alloc);
            for (p.params) |param| try params.append(ctx.alloc, try evalTypeExpr(ctx, param));
            const resolved = try params.toOwnedSlice(ctx.alloc);
            if (std.mem.eql(u8, p.name, "table")) {
                if (resolved.len == 1) {
                    const v = try ctx.alloc.create(TypeInfo);
                    v.* = resolved[0];
                    return .{ .tag = .{ .table = .{ .key = null, .value = v } } };
                }
                if (resolved.len == 2) {
                    const k = try ctx.alloc.create(TypeInfo);
                    k.* = resolved[0];
                    const v = try ctx.alloc.create(TypeInfo);
                    v.* = resolved[1];
                    return .{ .tag = .{ .table = .{ .key = k, .value = v } } };
                }
            }
            return .{ .tag = .any };
        },
        // "{ name: string, age: num }" -> table with per-field types;
        // names borrow source text like .named does, owners clone
        .record => |fields| {
            const owned = try ctx.alloc.alloc(types.RecordField, fields.len);
            for (fields, owned) |f, *dst| dst.* = .{
                .name = f.name,
                .field_type = try evalTypeExpr(ctx, f.type_expr),
            };
            const value = try ctx.alloc.create(TypeInfo);
            value.* = .{ .tag = .any };
            return types.makeTable(null, value, owned);
        },
        // "!int" -> union(@[{name="", types=@[:ok, int]}, {name="", types=@[:err, any]}])
        // the same shape the literal `(:ok, int) | (:err, any)` produces
        .error_union => |inner| {
            const t = try evalTypeExpr(ctx, inner);
            const ok_types = try ctx.alloc.dupe(TypeInfo, &.{ .{ .tag = .{ .atom = ":ok" } }, t });
            const err_types = try ctx.alloc.dupe(TypeInfo, &.{ .{ .tag = .{ .atom = ":err" } }, .{ .tag = .any } });
            const variants = try ctx.alloc.dupe(UnionVariant, &.{
                .{ .name = "", .types = ok_types },
                .{ .name = "", .types = err_types },
            });
            return .{ .tag = .{ .@"union" = variants } };
        },
    }
}

const empty_span: ast.Span = .{ .start = 0, .end = 0, .line = 0, .column = 0 };

fn namedExpr(alloc: std.mem.Allocator, name: []const u8) !*ast.TypeExpr {
    return try ast.allocTypeExpr(alloc, empty_span, .{ .named = name });
}

/// semantic TypeInfo back into syntax form for printing; mirrors
/// evalTypeExpr above, names borrow self
fn toTypeExpr(alloc: std.mem.Allocator, ti: TypeInfo) std.mem.Allocator.Error!*ast.TypeExpr {
    return switch (ti.tag) {
        .bool => try namedExpr(alloc, "bool"),
        .number => try namedExpr(alloc, "number"),
        .string => try namedExpr(alloc, "string"),
        .any => try namedExpr(alloc, "any"),
        .never => try namedExpr(alloc, "never"),
        .type_var => |n| try namedExpr(alloc, n),
        .struct_type => |n| try namedExpr(alloc, n),
        // empty atom payload is the "any atom" sentinel
        .atom => |s| if (s.len == 0) try namedExpr(alloc, "atom") else try ast.allocTypeExpr(alloc, empty_span, .{ .atom = ast.atomName(s) }),
        // empty tuple is the "any tuple" sentinel
        .tuple => |items| if (items.len == 0) try namedExpr(alloc, "tuple") else blk: {
            const owned = try alloc.alloc(*ast.TypeExpr, items.len);
            for (items, owned) |item, *dst| dst.* = try toTypeExpr(alloc, item);
            break :blk try ast.allocTypeExpr(alloc, empty_span, .{ .tuple = owned });
        },
        .@"union" => |variants| blk: {
            const owned = try alloc.alloc(*ast.TypeExpr, variants.len);
            for (variants, owned) |v, *dst| {
                const inner = if (v.types.len == 1) try toTypeExpr(alloc, v.types[0]) else blk2: {
                    const items = try alloc.alloc(*ast.TypeExpr, v.types.len);
                    for (v.types, items) |vt, *d| d.* = try toTypeExpr(alloc, vt);
                    break :blk2 try ast.allocTypeExpr(alloc, empty_span, .{ .tuple = items });
                };
                dst.* = inner;
            }
            break :blk try ast.allocTypeExpr(alloc, empty_span, .{ .union_of = owned });
        },
        .table => |tbl| blk: {
            // known fields render as records, same precedence as before
            if (tbl.fields) |fields| {
                const owned = try alloc.alloc(ast.RecordField, fields.len);
                for (fields, owned) |f, *dst| dst.* = .{
                    .name = f.name,
                    .type_expr = try toTypeExpr(alloc, f.field_type),
                };
                break :blk try ast.allocTypeExpr(alloc, empty_span, .{ .record = owned });
            }
            // bare `table` stays bare
            if (tbl.key == null and tbl.value.tag == .any) break :blk try namedExpr(alloc, "table");
            var params = try std.ArrayList(*ast.TypeExpr).initCapacity(alloc, 2);
            if (tbl.key) |k| try params.append(alloc, try toTypeExpr(alloc, k.*));
            try params.append(alloc, try toTypeExpr(alloc, tbl.value.*));
            break :blk try ast.allocTypeExpr(alloc, empty_span, .{
                .parameterized = .{ .name = "table", .params = try params.toOwnedSlice(alloc) },
            });
        },
        .function => |sig| blk: {
            const params = try alloc.alloc(ast.FnParam, sig.params.len);
            for (sig.params, 0..) |p, i| {
                const name = if (i < sig.param_names.len) sig.param_names[i] else "";
                params[i] = .{
                    .name = name,
                    .name_span = empty_span,
                    .type_name = try toTypeExpr(alloc, p),
                };
            }
            const ret = try toTypeExpr(alloc, sig.return_type);
            break :blk try ast.allocTypeExpr(alloc, empty_span, .{
                .function = .{ .params = params, .return_type = ret },
            });
        },
    };
}

/// render a TypeExpr via printTypeExpr; mirrors parse above
pub fn printTypeExpr(te: *const ast.TypeExpr, writer: *std.Io.Writer) !void {
    switch (te.kind) {
        .named => |name| try writer.writeAll(name),
        // atom payloads come both bare (`nil` from the main parser)
        // and colon-prefixed (`:nil` from the type parser)
        .atom => |name| try writer.print(":{s}", .{ast.atomName(name)}),
        .tuple => |items| {
            try writer.writeByte('(');
            for (items, 0..) |item, i| {
                if (i > 0) try writer.writeAll(", ");
                try printTypeExpr(item, writer);
            }
            try writer.writeByte(')');
        },
        .union_of => |variants| {
            // `T?` sugar, for a 2-union ending in `:nil`
            if (variants.len == 2 and variants[1].kind == .atom and
                std.mem.eql(u8, ast.atomName(variants[1].kind.atom), "nil"))
            {
                try printTypeExpr(variants[0], writer);
                try writer.writeByte('?');
            } else for (variants, 0..) |v, i| {
                if (i > 0) try writer.writeByte('|');
                try printTypeExpr(v, writer);
            }
        },
        .qualified => |q| {
            try writer.writeAll(q.module);
            try writer.writeByte('.');
            try writer.writeAll(q.name);
        },
        .record => |fields| {
            try writer.writeByte('{');
            for (fields, 0..) |f, i| {
                if (i > 0) try writer.writeAll(", ");
                // numeric names are positional array entries (`{ number, number }`)
                const positional = f.name.len > 0 and blk: {
                    for (f.name) |c| if (!std.ascii.isDigit(c)) break :blk false;
                    break :blk true;
                };
                if (!positional) {
                    try writer.writeAll(f.name);
                    try writer.writeAll(": ");
                }
                try printTypeExpr(f.type_expr, writer);
            }
            try writer.writeByte('}');
        },
        .function => |f| {
            try writer.writeAll("fn(");
            for (f.params, 0..) |p, i| {
                if (i > 0) try writer.writeAll(", ");
                if (p.name.len > 0) {
                    try writer.writeAll(p.name);
                    if (p.type_name != null) try writer.writeByte(':');
                }

                if (p.type_name) |t| try printTypeExpr(t, writer);
                if (p.variadic) try writer.writeAll("...");
            }
            try writer.writeByte(')');
            if (f.return_type) |ret| {
                try writer.writeAll(" -> ");
                try printTypeExpr(ret, writer);
            }
        },
        .parameterized => |p| {
            try writer.writeAll(p.name);
            try writer.writeByte('<');
            for (p.params, 0..) |param, i| {
                if (i > 0) try writer.writeAll(", ");
                try printTypeExpr(param, writer);
            }
            try writer.writeByte('>');
        },
        .error_union => |inner| {
            try writer.writeByte('!');
            try printTypeExpr(inner, writer);
        },
    }
}

/// render a TypeInfo via printTypeExpr: build syntax form,
/// print it, drop transient tree (names borrow self, like eval)
pub fn formatType(alloc: std.mem.Allocator, ti: TypeInfo) std.mem.Allocator.Error![]const u8 {
    var buf = std.Io.Writer.Allocating.init(alloc);
    errdefer buf.deinit();
    const te = try toTypeExpr(alloc, ti);
    // the allocating writer only fails on oom; printTypeExpr is generic
    // over writers so its error set is wider than what happens here
    printTypeExpr(te, &buf.writer) catch |err| {
        if (err != error.OutOfMemory) unreachable;
        return error.OutOfMemory;
    };
    return try buf.toOwnedSlice();
}

test "type serde roundtrips" {
    const cases = [_][]const u8{
        "{number, number, name: string}",
        "{number, :err, atom}",
        "{name: string}",
        "{}",
        "number?",
        "(:ok, table) | (:err, any)",
        "fn() -> string",
        "fn(a: number) -> string",
        "fn(?a: number) -> string", // optional param a; must match the one in non-type revo code
        "table<string, number>",
        "(:ok, any) | (:err, any)",
        "{user: {name: string}}",
        "{:ok, any}",
        "{:ok, any} | {:err, any}",
    };
    for (cases) |c| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const ti = try parseTypeString(BareCtx{ .alloc = alloc }, c);
        try std.testing.expectEqualStrings(c, try formatType(alloc, ti));
    }
}
