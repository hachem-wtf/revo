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
/// nodes becomes semantic TypeInfo values
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

/// ======================= pub iface of mod ast ==========================
/// this bhv shold be
/// ~ record type for the import binding & resolved type aliases
/// ~ pub fn bindings get signature types (dep generics scoped correctly)
/// ~ pub consts get literal-inferred types (or any)
/// ~ pub structs get struct types, pub re-exports get any
///   (really dont care about this one since structs will go anyways)
/// ~ non pub items are skipped
///
/// ~ type aliases are compile-time only (not values)
/// ~ record is null when nothing is exported: such modules evaluate to
///   their last expression, not a table, so the import stays untyped
///   (TOOD: give them types like all real closures)
/// ~ dep-local names resolve inside the dep, never in importer scope,,, all hermetic
/// ~ names borrow dep src
/// =======================================================================
pub const ModuleAlias = struct {
    name: []const u8,
    info: TypeInfo,
};

pub const ModuleIface = struct {
    record: ?TypeInfo,
    aliases: []const ModuleAlias,
};

pub fn moduleInterface(alloc: std.mem.Allocator, items: []const *ast.Node) !ModuleIface {
    var mctx = ModuleCtx{
        .alloc = alloc,
        .raws = std.StringHashMap(*ast.TypeExpr).init(alloc),
        .stack = try std.ArrayList([]const u8).initCapacity(alloc, 4),
    };
    defer mctx.raws.deinit();
    defer mctx.stack.deinit(alloc);
    // pre-collect every alias raw (pub or not) so forward references
    // and private bases resolve; only pub names are exported below
    for (items) |item| {
        if (item.expr != .decl) continue;
        const d = item.expr.decl;
        if (d.inner.expr == .type_alias) {
            try mctx.raws.put(d.inner.expr.type_alias.name, d.inner.expr.type_alias.type_expr);
        }
    }
    var out = try std.ArrayList(types.RecordField).initCapacity(alloc, items.len);
    errdefer out.deinit(alloc);
    for (items) |item| try moduleExportInto(&mctx, item, &out);
    var aliases = try std.ArrayList(ModuleAlias).initCapacity(alloc, mctx.raws.count());
    errdefer aliases.deinit(alloc);
    for (items) |item| {
        if (item.expr != .decl) continue;
        const d = item.expr.decl;
        if (!d.pub_ or d.inner.expr != .type_alias) continue;
        const name = d.inner.expr.type_alias.name;
        if (mctx.resolveTypeAlias(name)) |t| {
            try aliases.append(alloc, .{ .name = name, .info = t });
        }
    }
    if (out.items.len == 0) return .{ .record = null, .aliases = try aliases.toOwnedSlice(alloc) };
    const value = try alloc.create(TypeInfo);
    value.* = .{ .tag = .any };
    return .{
        .record = types.makeTable(null, value, try out.toOwnedSlice(alloc)),
        .aliases = try aliases.toOwnedSlice(alloc),
    };
}

/// evaluation scope for one module's interface
/// ~ dep aliases resolve here  (never in the importer's scope)
/// ~ fn type params scope per fn
const ModuleCtx = struct {
    alloc: std.mem.Allocator,
    raws: std.StringHashMap(*ast.TypeExpr),
    stack: std.ArrayList([]const u8),
    type_params: []const []const u8 = &.{},

    pub fn isTypeParam(self: *const ModuleCtx, name: []const u8) bool {
        for (self.type_params) |tp| if (std.mem.eql(u8, tp, name)) return true;
        return false;
    }

    pub fn resolveTypeAlias(self: *ModuleCtx, name: []const u8) ?TypeInfo {
        const raw = self.raws.get(name) orelse return null;
        for (self.stack.items) |s| if (std.mem.eql(u8, s, name)) return null;
        self.stack.append(self.alloc, name) catch return null;
        defer _ = self.stack.pop();
        return evalTypeExpr(self, raw) catch null;
    }

    /// qualified refs inside deps (dep on dep types) stay unresolved
    /// resolving them would recurse into subdep interfaces
    pub fn resolveImportAlias(_: *ModuleCtx, _: []const u8, _: []const u8) ?TypeInfo {
        return null;
    }

    pub fn inferIdentType(_: *ModuleCtx, _: []const u8) TypeInfo {
        return .{ .tag = .any };
    }

    pub fn inferCallReturnType(
        _: *ModuleCtx,
        _: *const ast.Node,
        _: []const *ast.Node,
        _: []const []const u8,
        _: bool,
    ) TypeInfo {
        return .{ .tag = .any };
    }

    pub fn inferFieldType(_: *ModuleCtx, _: *const ast.Node, _: []const u8) TypeInfo {
        return .{ .tag = .any };
    }

    pub fn inferFnType(
        self: *ModuleCtx,
        params: []const ast.FnParam,
        return_type: ?*ast.TypeExpr,
        type_params: []const []const u8,
        doc: ?[]const u8,
    ) TypeInfo {
        const saved = self.type_params;
        self.type_params = type_params;
        defer self.type_params = saved;

        var param_types = std.ArrayList(TypeInfo).initCapacity(self.alloc, params.len) catch return .{ .tag = .any };
        defer param_types.deinit(self.alloc);
        var param_names = std.ArrayList([]const u8).initCapacity(self.alloc, params.len) catch return .{ .tag = .any };
        defer param_names.deinit(self.alloc);
        var required: usize = 0;

        for (params) |p| {
            param_names.append(self.alloc, p.name) catch return .{ .tag = .any };
            param_types.append(self.alloc, if (p.type_name) |tn| evalTypeExpr(self, tn) catch .{ .tag = .any } else .{ .tag = .any }) catch return .{ .tag = .any };
            if (!p.optional and p.default_value == null) required += 1;
        }

        const owned_params = param_types.toOwnedSlice(self.alloc) catch return .{ .tag = .any };
        errdefer self.alloc.free(owned_params);
        const owned_names = param_names.toOwnedSlice(self.alloc) catch return .{ .tag = .any };
        errdefer self.alloc.free(owned_names);

        const ret: TypeInfo = if (return_type) |rt|
            evalTypeExpr(self, rt) catch .{ .tag = .any }
        else
            .{ .tag = .any };

        const sig = types.newSignature(self.alloc, .{
            .param_names = owned_names,
            .params = owned_params,
            .return_type = ret,
            .required_count = required,
            .type_params = type_params,
            .doc = doc,
        }) catch return .{ .tag = .any };
        return .{ .tag = .{ .function = sig } };
    }
};

fn moduleExportInto(mctx: *ModuleCtx, node: *const ast.Node, out: *std.ArrayList(types.RecordField)) !void {
    const alloc = mctx.alloc;
    switch (node.expr) {
        .decl => |d| {
            // .d.rv manifests declare host contracts
            if (d.kind == .declare_decl and d.inner.expr == .type_alias) {
                if (!d.pub_) return;
                const t = d.inner.expr.type_alias;
                const ft = evalTypeExpr(mctx, t.type_expr) catch TypeInfo{ .tag = .any };
                try out.append(alloc, .{ .name = t.name, .field_type = ft });
                return;
            }
            if (!d.pub_) return;
            switch (d.inner.expr) {
                .binding => |b| {
                    if (b.target.expr != .ident) return;
                    try out.append(alloc, .{
                        .name = b.target.expr.ident,
                        // inferred with the module ctx: unknown names
                        // degrade to any inside inference, so nothing
                        // leaks across scopes
                        .field_type = types.inferExprType(mctx, b.value),
                    });
                },
                .struct_def => |def| try out.append(alloc, .{
                    .name = def.name,
                    .field_type = .{ .tag = .{ .struct_type = def.name } },
                }),
                // type aliases are compile-time only so skip them
                else => {},
            }
        },
        // re-exports resolve in sub-dep scope, not here
        // were it not any-typed, the reads could false-flag
        .import_stmt => |stmt| if (stmt.pub_) try out.append(alloc, .{
            .name = stmt.name,
            .field_type = .{ .tag = .any },
        }),
        else => {},
    }
}

test "pos record roundtrips w/o numeric names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const mixed = try parseTypeString(BareCtx{ .alloc = alloc }, "{number, number, name: string}");
    try std.testing.expectEqualStrings("{number, number, name: string}", try mixed.formatType(alloc));

    const atoms = try parseTypeString(BareCtx{ .alloc = alloc }, "{number, :err, atom}");
    try std.testing.expectEqualStrings("{number, :err, atom}", try atoms.formatType(alloc));
}
