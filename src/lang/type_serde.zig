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

            var required: usize = 0;
            for (f.params) |p| {
                if (!p.optional) required += 1;
            }

            const sig = try types.newSignature(ctx.alloc, .{
                .param_names = try param_names.toOwnedSlice(ctx.alloc),
                .params = try param_types.toOwnedSlice(ctx.alloc),
                .return_type = return_type,
                .required_count = required,
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
            .struct_type, .type_var => |s| try writer.writeAll(s),
            .table => try writer.writeAll("table"),
            .function => try writer.writeAll("function"),
            // all these are spelled out so a future payload-carrying tag breaks
            // compilation here instead of just printing its tag name
            .bool, .number, .string, .any, .never, .tuple, .@"union" => try writer.writeAll(@tagName(ti.tag)),
        }
        return;
    }
    switch (ti.tag) {
        .type_var => |n| try writer.writeAll(n),
        .struct_type => |n| try writer.writeAll(n),
        // empty atom payload is the "any atom" sentinel
        .atom => |s| if (s.len == 0) try writer.writeAll("atom") else try writer.print(":{s}", .{ast.atomName(s)}),
        // empty tuple is the "any tuple" sentinel
        .tuple => |items| if (items.len == 0) try writer.writeAll("tuple") else {
            try writer.writeByte('(');
            for (items, 0..) |item, i| {
                if (i > 0) try writer.writeAll(", ");
                try printType(item, writer, opts);
            }
            try writer.writeByte(')');
        },
        .@"union" => |variants| {
            // `T?`, for a 2-union ending in `:nil`
            if (variants.len == 2 and variants[1].types.len == 1 and variants[1].types[0].tag == .atom and
                std.mem.eql(u8, ast.atomName(variants[1].types[0].tag.atom), "nil"))
            {
                const first = variants[0].types;
                if (first.len == 1) {
                    try printType(first[0], writer, opts);
                } else {
                    try writer.writeByte('(');
                    for (first, 0..) |item, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try printType(item, writer, opts);
                    }
                    try writer.writeByte(')');
                }

                try writer.writeByte('?');
            } else for (variants, 0..) |v, i| {
                if (i > 0) try writer.writeAll(" | ");
                if (v.types.len == 1) {
                    try printType(v.types[0], writer, opts);
                } else {
                    try writer.writeByte('(');
                    for (v.types, 0..) |item, j| {
                        if (j > 0) try writer.writeAll(", ");
                        try printType(item, writer, opts);
                    }
                    try writer.writeByte(')');
                }
            }
        },
        .table => |tbl| {
            if (tbl.fields) |fields| {
                try writer.writeByte('{');
                for (fields, 0..) |f, i| {
                    if (i > 0) try writer.writeAll(", ");
                    // numeric names are positional array entries
                    const positional = f.name.len > 0 and blk: {
                        for (f.name) |c| if (!std.ascii.isDigit(c)) break :blk false;
                        break :blk true;
                    };
                    if (!positional) {
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
                if (i > 0) try writer.writeAll(" | ");
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
                if (p.optional) try writer.writeByte('?');
                if (p.name.len > 0) {
                    try writer.writeAll(p.name);
                    if (p.type_name != null) try writer.writeAll(": ");
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

// TODO: remove
pub fn formatType(alloc: std.mem.Allocator, ti: TypeInfo) std.mem.Allocator.Error![]const u8 {
    return formatTypeOpts(alloc, ti, .{});
}

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
        // optional param a; must match the one in non-type revo code
        // TODO: make it universal with all-all serde
        "fn(?a: number) -> string",
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
