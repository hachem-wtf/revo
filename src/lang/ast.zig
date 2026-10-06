const std = @import("std");

pub const Span = struct {
    start: usize,
    end: usize,
    line: u32,
    column: u32,

    pub fn merge(a: Span, b: Span) Span {
        return .{
            .start = @min(a.start, b.start),
            .end = @max(a.end, b.end),
            .line = if (a.start <= b.start) a.line else b.line,
            .column = if (a.start <= b.start) a.column else b.column,
        };
    }
};

pub const discard_name = "_";

pub inline fn isDiscardName(name: []const u8) bool {
    return std.mem.eql(u8, name, discard_name);
}

// they have to match opcode names. thankfully you get a compile error today
pub const BinOp = enum {
    add,
    sub,
    mul,
    div,
    int_div,
    mod,
    concat,
    eq,
    neq,
    lt,
    gt,
    lte,
    gte,
    band,
    bor,
    bxor,
    shl,
    shr,
    pow,
    @"union",
};

pub const UnaryOp = enum {
    negate,
    not,
    spawn,
    yield,
};

pub const RecordField = struct {
    name: []const u8,
    type_expr: *TypeExpr,
    /// `?name:` fields may be absent; `name:` and `name: T?` require the key
    optional: bool = false,
    /// `#* ... *#` doc before the field in a `declare` table; borrowed like name
    doc: ?[]const u8 = null,
};

pub const TypeExpr = struct {
    kind: Kind,
    span: Span,

    pub const Kind = union(enum) {
        named: []const u8,
        atom: []const u8,
        union_of: []const *TypeExpr,
        record: []const RecordField,
        /// qualified module type: `a.T` names alias T from module a
        qualified: struct {
            module: []const u8,
            name: []const u8,
        },
        function: struct {
            params: []const FnParam,
            return_type: ?*TypeExpr,
            /// `fn<T>` binders; empty for plain `fn`. binding scope lives
            /// outside the tree (declare heads, fn exprs), never in it
            type_params: []const []const u8 = &.{},
        },
        parameterized: struct {
            name: []const u8,
            params: []const *TypeExpr,
        },
        error_union: *TypeExpr,
    };
};

pub fn allocTypeExpr(allocator: std.mem.Allocator, span: Span, kind: TypeExpr.Kind) std.mem.Allocator.Error!*TypeExpr {
    const te = try allocator.create(TypeExpr);
    te.* = .{ .span = span, .kind = kind };
    return te;
}

/// atom payload without a leading colon:
/// `:nil` and `nil` both give `nil`
pub fn atomName(name: []const u8) []const u8 {
    return if (name.len > 0 and name[0] == ':') name[1..] else name;
}

/// render a TypeExpr to the writer
/// mirrors type_syntax.parseTypeExpr: every Kind parses and prints
pub fn printTypeExpr(te: *const TypeExpr, writer: *std.Io.Writer) !void {
    switch (te.kind) {
        .named => |name| try writer.writeAll(name),
        // atom payloads come both bare (`nil` from the main parser)
        // and colon-prefixed (`:nil` from the type parser)
        .atom => |name| try writer.print(":{s}", .{atomName(name)}),
        .union_of => |variants| {
            // `T?` sugar, for a 2-union ending in `:nil`
            if (variants.len == 2 and variants[1].kind == .atom and
                std.mem.eql(u8, atomName(variants[1].kind.atom), "nil"))
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
                const positional = isPositionalName(f.name);
                if (!positional) {
                    if (f.optional) try writer.writeByte('?');
                    try writer.writeAll(f.name);
                    try writer.writeAll(": ");
                }
                try printTypeExpr(f.type_expr, writer);
            }
            try writer.writeByte('}');
        },
        .function => |f| {
            try writer.writeAll("fn");
            if (f.type_params.len > 0) {
                try writer.writeByte('<');
                for (f.type_params, 0..) |tp, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.writeAll(tp);
                }
                try writer.writeByte('>');
            }
            try writer.writeAll("(");
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

/// deep-copy a TypeExpr
/// dupe every borrowed string (names borrow source text)
///     paired with freeTypeExpr
/// default_value pointers copy over but stay unowned (type position never sets them)
pub fn cloneTypeExpr(alloc: std.mem.Allocator, te: *const TypeExpr) std.mem.Allocator.Error!*TypeExpr {
    const kind: TypeExpr.Kind = switch (te.kind) {
        .named => |n| .{ .named = try alloc.dupe(u8, n) },
        .atom => |n| .{ .atom = try alloc.dupe(u8, n) },
        .union_of => |variants| blk: {
            const owned = try alloc.alloc(*TypeExpr, variants.len);
            for (variants, owned) |v, *dst| dst.* = try cloneTypeExpr(alloc, v);
            break :blk .{ .union_of = owned };
        },
        .record => |fields| blk: {
            const owned = try alloc.alloc(RecordField, fields.len);
            for (fields, owned) |f, *dst| dst.* = .{
                .name = try alloc.dupe(u8, f.name),
                .type_expr = try cloneTypeExpr(alloc, f.type_expr),
                .optional = f.optional,
                .doc = if (f.doc) |d| try alloc.dupe(u8, d) else null,
            };
            break :blk .{ .record = owned };
        },
        .qualified => |q| .{ .qualified = .{
            .module = try alloc.dupe(u8, q.module),
            .name = try alloc.dupe(u8, q.name),
        } },
        .function => |f| blk: {
            const params = try alloc.alloc(FnParam, f.params.len);
            for (f.params, params) |p, *dst| dst.* = .{
                .name = try alloc.dupe(u8, p.name),
                .name_span = p.name_span,
                .type_name = if (p.type_name) |tn| try cloneTypeExpr(alloc, tn) else null,
                .optional = p.optional,
                .default_value = p.default_value,
                .variadic = p.variadic,
            };
            const type_params = try alloc.alloc([]const u8, f.type_params.len);
            for (f.type_params, type_params) |tp, *dst| dst.* = try alloc.dupe(u8, tp);
            break :blk .{ .function = .{
                .params = params,
                .return_type = if (f.return_type) |rt| try cloneTypeExpr(alloc, rt) else null,
                .type_params = type_params,
            } };
        },
        .parameterized => |p| blk: {
            const owned = try alloc.alloc(*TypeExpr, p.params.len);
            for (p.params, owned) |item, *dst| dst.* = try cloneTypeExpr(alloc, item);
            break :blk .{ .parameterized = .{
                .name = try alloc.dupe(u8, p.name),
                .params = owned,
            } };
        },
        .error_union => |inner| .{ .error_union = try cloneTypeExpr(alloc, inner) },
    };
    return try allocTypeExpr(alloc, te.span, kind);
}

/// free a cloneTypeExpr tree: strings, slices, nodes
pub fn freeTypeExpr(alloc: std.mem.Allocator, te: *TypeExpr) void {
    switch (te.kind) {
        .named => |n| alloc.free(n),
        .atom => |n| alloc.free(n),
        .union_of => |variants| {
            for (variants) |v| freeTypeExpr(alloc, v);
            alloc.free(variants);
        },
        .record => |fields| {
            for (fields) |f| {
                alloc.free(f.name);
                freeTypeExpr(alloc, f.type_expr);
                if (f.doc) |d| alloc.free(d);
            }
            alloc.free(fields);
        },
        .qualified => |q| {
            alloc.free(q.module);
            alloc.free(q.name);
        },
        .function => |f| {
            for (f.params) |p| {
                alloc.free(p.name);
                if (p.type_name) |tn| freeTypeExpr(alloc, tn);
            }
            alloc.free(f.params);
            if (f.return_type) |rt| freeTypeExpr(alloc, rt);
            for (f.type_params) |tp| alloc.free(tp);
            alloc.free(f.type_params);
        },
        .parameterized => |p| {
            alloc.free(p.name);
            for (p.params) |param| freeTypeExpr(alloc, param);
            alloc.free(p.params);
        },
        .error_union => |inner| freeTypeExpr(alloc, inner),
    }
    alloc.destroy(te);
}

/// static `name = v` / `:name = v` key, or null for computed keys,
/// dynamic keys, and keyless entries
pub fn staticFieldName(entry: TableEntry) ?[]const u8 {
    if (entry.computed) return null;
    const key = entry.key orelse return null;
    return switch (key.expr) {
        .ident, .atom => |name| name,
        else => null,
    };
}

pub const FnParam = struct {
    name: []const u8,
    name_span: Span,
    type_name: ?*TypeExpr = null,
    optional: bool = false,
    default_value: ?*Node = null,
    /// type position only: trailing `...` marks an open arg list
    variadic: bool = false,
};

pub const TableEntry = struct {
    key: ?*Node,
    computed: bool = false,
    value: *Node,
};

pub const DeclKind = enum {
    @"const",
    let,
    global,
    /// repl top-level `const`
    /// TODO: add actual "global const" syntax
    global_const,
    test_decl,
    suite_decl,
    type_alias_decl,
    declare_decl,
};

pub const DeclNode = struct {
    inner: *Node,
    kind: DeclKind,
    pub_: bool = false,
    doc: ?[]const u8 = null,
};

pub const MatchMatcher = union(enum) {
    wildcard,
    expr: *Node,
};

pub const MatchArm = struct {
    matchers: []MatchMatcher,
    guard: ?*Node,
    then: *Node,
};

pub const Binding = struct {
    target: *Node,
    type_name: ?*TypeExpr = null,
    value: *Node,
    mutable: bool = false,
    doc: ?[]const u8 = null,

    fn printAt(self: *const Binding, writer: *std.Io.Writer, comptime tag: []const u8, depth: ?usize) anyerror!void {
        try writer.print("({s}", .{tag});
        if (depth) |d| {
            try writer.writeByte('\n');
            try writeIndent(writer, d + 1);
            try self.target.printAt(writer, d + 1);
            if (self.type_name) |t| {
                try writer.writeByte(':');
                try printTypeExpr(t, writer);
            }
            try writer.writeByte('\n');
            try writeIndent(writer, d + 1);
            try self.value.printAt(writer, d + 1);
            try writer.writeByte('\n');
            try writeIndent(writer, d);
        } else {
            try writer.writeByte(' ');
            try self.target.printAt(writer, null);
            if (self.type_name) |t| {
                try writer.writeByte(':');
                try printTypeExpr(t, writer);
            }
            try writer.writeByte(' ');
            try self.value.printAt(writer, null);
        }
        try writer.writeByte(')');
    }
};

pub const Expr = union(enum) {
    number: NumberLiteral, // {:number, 123} or {:number, 123.0}
    string: []const u8, // {:string, "asdf"}
    multiline_string: []const u8,
    atom: []const u8,
    nil,
    ident: []const u8,
    unary: struct { op: UnaryOp, expr: *Node },
    binary: struct { op: BinOp, left: *Node, right: *Node },
    and_expr: struct { left: *Node, right: *Node },
    or_expr: struct { left: *Node, right: *Node },
    call: struct { callee: *Node, args: []*Node, implicit_self: bool = false, type_args: []const []const u8 = &.{} },
    field: struct { object: *Node, name: []const u8 },
    index: struct { object: *Node, key: *Node },
    if_expr: struct { condition: *Node, then_expr: *Node, else_expr: ?*Node },
    unless_expr: struct { condition: *Node, then_expr: *Node, else_expr: ?*Node },
    match_expr: struct { subject: *Node, arms: []MatchArm },
    fn_expr: struct {
        params: []FnParam,
        return_type: ?*TypeExpr = null,
        body: *Node,
        doc: ?[]const u8 = null,
        native: bool = false,
        type_params: []const []const u8 = &.{},
    },
    binding: Binding,
    decl: DeclNode,
    // ill probably ignore node's span field for now just do its expr
    // {:assign_expr, {:ident, "aaa"}, {:ident, "bbb"}}
    assign_expr: struct { target: *Node, value: *Node },
    compound_assign: struct { target: *Node, op: BinOp, value: *Node },
    loop_expr: struct { body: *Node, label: ?[]const u8 = null },
    for_loop: struct { params: []FnParam, iter: *Node, body: *Node, label: ?[]const u8 = null },
    comp_block: struct { expr: *Node },
    while_loop: struct { predicate: *Node, body: *Node, label: ?[]const u8 = null },
    break_expr: struct { value: ?*Node, label: ?[]const u8 },
    continue_expr: struct { value: ?*Node, label: ?[]const u8 },
    labeled_block: struct { label: []const u8, body: *Node },
    return_expr: ?*Node,
    range_literal: struct {
        start: *Node,
        step: *Node,
        end: *Node,
    },
    slice_literal: struct {
        start: ?*Node,
        step: ?*Node,
        end: ?*Node,
    },
    import_stmt: struct { name: []const u8, path: []const u8, pub_: bool = false },
    test_block: struct { name: []const u8, body: *Node, skip: bool = false },
    test_suite: struct { name: []const u8, body: *Node },
    block: []*Node,
    table_pattern: []*Node,

    table: []TableEntry,
    ascribed: struct { expr: *Node, type_name: *TypeExpr },
    proc_macro: struct { name: []const u8, param: FnParam, body: *Node },
    quasiquote: Quasiquote,
    try_expr: *Node, // expr?
    orelse_expr: struct { left: *Node, right: *Node }, // expr orelse 42
    type_alias: TypeAlias,
};

/// `pub declare` / `pub type` alias
pub const TypeAlias = struct {
    name: []const u8,
    name_span: Span,
    type_expr: *TypeExpr,
    doc: ?[]const u8 = null,
    declare_head: ?DeclareHead = null,
    declare_tps: []const []const u8 = &.{},
};

/// bare member of a possibly-dotted macro name: `uri.asdf!` -> `asdf!`
pub fn bareMacroName(name: []const u8) []const u8 {
    if (std.mem.findScalarLast(u8, name, '.')) |i| return name[i + 1 ..];
    return name;
}

/// member name of an alias: last head segment when headed, else the name
/// `uri.Hi` -> `Hi`, `Port` -> `Port`
/// . single source for every keying site so that we get
///     dotted aliases to resolve the same everywhere
pub fn bareName(t: TypeAlias) []const u8 {
    if (t.declare_head) |dh| switch (dh) {
        .module => |segs| return segs[segs.len - 1],
    };
    return t.name;
}

/// numeric field names are positional array entries (`{ number, number }`)
pub fn isPositionalName(name: []const u8) bool {
    return name.len > 0 and blk: {
        for (name) |c| if (!std.ascii.isDigit(c)) break :blk false;
        break :blk true;
    };
}

/// a declare's name may name a module instead of a plain ident:
/// `fs.open` or a plain ident (`.`/head = null)
pub const DeclareHead = union(enum) {
    module: []const []const u8, // dotted path segments: "fs.open" -> &.{"fs", "open"}
};

pub const Quasiquote = struct {
    inner: *Node,
    splices: []const []const u8,
};

pub const Node = struct {
    span: Span,
    expr: Expr,
    synthetic_block: bool = false,

    pub fn print(self: *const Node, writer: *std.Io.Writer) anyerror!void {
        return self.printAt(writer, null);
    }

    pub fn printPretty(self: *const Node, writer: *std.Io.Writer) anyerror!void {
        return self.printAt(writer, 0);
    }

    pub fn format(self: Node, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: *std.Io.Writer) !void {
        if (fmt.len == 0) return self.print(writer);
        if (std.mem.eql(u8, fmt, "p")) return self.printPretty(writer);
        @compileError("invalid format string for ast.Node; use {} or {p}");
    }

    fn printAt(self: *const Node, writer: *std.Io.Writer, depth: ?usize) anyerror!void {
        // sep/end helpers: in compact mode, just a space or nothing;
        // in pretty mode, newline + indent at d+1, or newline + indent at d
        const pretty = depth != null;

        switch (self.expr) {
            // atoms are same in both modes
            .number => |n| {
                if (std.math.isFinite(n.value) and @floor(n.value) == n.value and
                    n.value >= @as(f64, @floatFromInt(std.math.minInt(i64))) and
                    n.value <= @as(f64, @floatFromInt(std.math.maxInt(i64))) and !n.is_float)
                {
                    try writer.print("{d}", .{@as(i64, @intFromFloat(n.value))});
                } else {
                    try writer.print("{}", .{n.value});
                }
            },
            .string => |s| try writer.print("\"{s}\"", .{s}),
            .multiline_string => |s| try writer.print("\"\"\"{s}\"\"\"", .{s}),
            .atom => |h| try writer.print(":{s}", .{h}),
            .nil => try writer.writeAll("nil"),
            .ident => |name| try writer.writeAll(name),

            .decl => |d| try d.inner.printAt(writer, depth),

            .range_literal => |r| {
                try writer.writeAll("(range ");
                try r.start.print(writer);
                try writer.writeAll(" ");
                try r.step.print(writer);
                try writer.writeAll(" ");
                try r.end.print(writer);
                try writer.writeAll(")");
            },
            .slice_literal => |s| {
                try writer.writeAll("(slice");
                if (s.start) |n| {
                    try writer.writeByte(' ');
                    try n.print(writer);
                } else try writer.writeAll(" _");
                if (s.step) |n| {
                    try writer.writeByte(' ');
                    try n.print(writer);
                } else try writer.writeAll(" _");
                if (s.end) |n| {
                    try writer.writeByte(' ');
                    try n.print(writer);
                } else try writer.writeAll(" _");
                try writer.writeAll(")");
            },
            .unary => |u| {
                try writer.print("({s}", .{@tagName(u.op)});
                try sep(writer, depth, 1);
                try u.expr.printAt(writer, child(depth));
                try close(writer, depth);
            },
            .binary => |b| {
                try writer.print("({s}", .{binOpName(b.op)});
                try sep(writer, depth, 1);
                try b.left.printAt(writer, child(depth));
                try sep(writer, depth, 1);
                try b.right.printAt(writer, child(depth));
                try close(writer, depth);
            },
            .and_expr => |v| {
                try writer.writeAll("(and");
                try sep(writer, depth, 1);
                try v.left.printAt(writer, child(depth));
                try sep(writer, depth, 1);
                try v.right.printAt(writer, child(depth));
                try close(writer, depth);
            },
            .or_expr => |v| {
                try writer.writeAll("(or");
                try sep(writer, depth, 1);
                try v.left.printAt(writer, child(depth));
                try sep(writer, depth, 1);
                try v.right.printAt(writer, child(depth));
                try close(writer, depth);
            },
            .call => |call| {
                try writer.writeAll("(call");
                try sep(writer, depth, 1);
                try call.callee.printAt(writer, child(depth));
                for (call.args) |arg| {
                    try sep(writer, depth, 1);
                    try arg.printAt(writer, child(depth));
                }
                try close(writer, depth);
            },
            .field => |field| {
                try writer.writeAll("(field");
                try sep(writer, depth, 1);
                try field.object.printAt(writer, child(depth));
                try sep(writer, depth, 1);
                try writer.writeAll(field.name);
                try close(writer, depth);
            },
            .index => |index| {
                try writer.writeAll("(index");
                try sep(writer, depth, 1);
                try index.object.printAt(writer, child(depth));
                try sep(writer, depth, 1);
                try index.key.printAt(writer, child(depth));
                try close(writer, depth);
            },
            .if_expr => |v| {
                try writer.writeAll("(if");
                try sep(writer, depth, 1);
                try v.condition.printAt(writer, child(depth));
                try sep(writer, depth, 1);
                try v.then_expr.printAt(writer, child(depth));
                if (v.else_expr) |e| {
                    try sep(writer, depth, 1);
                    try e.printAt(writer, child(depth));
                }
                try close(writer, depth);
            },
            .unless_expr => |v| {
                try writer.writeAll("(unless");
                try sep(writer, depth, 1);
                try v.condition.printAt(writer, child(depth));
                try sep(writer, depth, 1);
                try v.then_expr.printAt(writer, child(depth));
                if (v.else_expr) |e| {
                    try sep(writer, depth, 1);
                    try e.printAt(writer, child(depth));
                }
                try close(writer, depth);
            },
            .match_expr => |m| {
                try writer.writeAll("(match");
                try sep(writer, depth, 1);
                try m.subject.printAt(writer, child(depth));
                for (m.arms) |arm| {
                    try sep(writer, depth, 1);
                    try printMatchArm(writer, arm, depth);
                }
                try close(writer, depth);
            },
            .fn_expr => |fn_expr| {
                try writer.writeAll("(fn (");
                for (fn_expr.params, 0..) |param, i| {
                    if (i != 0) try writer.writeByte(' ');
                    try writer.writeAll(param.name);
                    if (param.type_name) |t| {
                        try writer.writeByte(':');
                        try printTypeExpr(t, writer);
                    }
                }
                try writer.writeByte(')');
                if (fn_expr.return_type) |ret| {
                    try writer.writeAll(" -> ");
                    try printTypeExpr(ret, writer);
                }
                try sep(writer, depth, 1);
                try fn_expr.body.printAt(writer, child(depth));
                try close(writer, depth);
            },
            .proc_macro => |pm| {
                try writer.writeAll("(proc ( ");
                try writer.writeAll(pm.param.name);
                try writer.writeByte(')');
                try sep(writer, depth, 1);
                try pm.body.printAt(writer, child(depth));
                try close(writer, depth);
            },
            .test_block => |block| {
                try writer.print("(test {s}", .{block.name});
                if (block.skip) try writer.writeAll("/skip");
                try sep(writer, depth, 1);
                try block.body.printAt(writer, child(depth));
                try close(writer, depth);
            },
            .test_suite => |suite| {
                try writer.print("(suite {s}", .{suite.name});
                try suite.body.printAt(writer, child(depth));
                try close(writer, depth);
            },
            .binding => |binding| try binding.printAt(writer, "binding", depth),
            .assign_expr => |assign| {
                try writer.writeAll("(assign");
                try sep(writer, depth, 1);
                try assign.target.printAt(writer, child(depth));
                try sep(writer, depth, 1);
                try assign.value.printAt(writer, child(depth));
                try close(writer, depth);
            },
            .compound_assign => |assign| {
                try writer.print("(assign-{s}", .{binOpName(assign.op)});
                try sep(writer, depth, 1);
                try assign.target.printAt(writer, child(depth));
                try sep(writer, depth, 1);
                try assign.value.printAt(writer, child(depth));
                try close(writer, depth);
            },
            .loop_expr => |v| {
                if (v.label) |lbl| {
                    try writer.print("(loop/{s}", .{lbl});
                } else {
                    try writer.writeAll("(loop");
                }
                try sep(writer, depth, 1);
                try v.body.printAt(writer, child(depth));
                try close(writer, depth);
            },
            .while_loop => |w| {
                if (w.label) |lbl| {
                    try writer.print("(while/{s}", .{lbl});
                } else {
                    try writer.writeAll("(while");
                }
                try sep(writer, depth, 1);
                try w.predicate.print(writer);
                try sep(writer, depth, 1);
                try w.body.printAt(writer, child(depth));
                try close(writer, depth);
            },
            .for_loop => |v| {
                if (v.label) |lbl| {
                    try writer.print("(for/{s} (", .{lbl});
                } else {
                    try writer.writeAll("(for (");
                }
                for (v.params, 0..) |param, i| {
                    if (i != 0) try writer.writeByte(' ');
                    try writer.writeAll(param.name);
                    if (param.type_name) |t| {
                        try writer.writeByte(':');
                        try printTypeExpr(t, writer);
                    }
                }
                try writer.writeAll(" in ");
                try v.iter.printAt(writer, if (pretty) child(depth) else null);
                try writer.writeByte(')');
                try sep(writer, depth, 1);
                try v.body.printAt(writer, child(depth));
                try close(writer, depth);
            },
            .break_expr => |b| {
                try writer.writeAll("(break");
                if (b.label) |lbl| {
                    try writer.print("/{s}", .{lbl});
                }
                if (b.value) |expr| {
                    try sep(writer, depth, 1);
                    try expr.printAt(writer, child(depth));
                }
                try close(writer, depth);
            },
            .continue_expr => |c| {
                try writer.writeAll("(continue");
                if (c.label) |lbl| {
                    try writer.print("/{s}", .{lbl});
                }
                if (c.value) |expr| {
                    try sep(writer, depth, 1);
                    try expr.printAt(writer, child(depth));
                }
                try close(writer, depth);
            },
            .labeled_block => |lb| {
                try writer.print("(label/{s}", .{lb.label});
                try sep(writer, depth, 1);
                try lb.body.printAt(writer, child(depth));
                try close(writer, depth);
            },
            .return_expr => |value| {
                if (value) |expr| {
                    try writer.writeAll("(return");
                    try sep(writer, depth, 1);
                    try expr.printAt(writer, child(depth));
                    try close(writer, depth);
                } else {
                    try writer.writeAll("(return)");
                }
            },
            .import_stmt => |is| {
                try writer.print("(import_stmt {s} {s})", .{ is.name, is.path });
            },
            .comp_block => |cb| {
                try writer.writeAll("(comp");
                try sep(writer, depth, 1);
                try cb.expr.printAt(writer, child(depth));
                try close(writer, depth);
            },
            .block => |exprs| try printNodeList(writer, "block", exprs, depth),
            .table_pattern => |items| try printNodeList(writer, "table-pattern", items, depth),
            .ascribed => |a| {
                try writer.writeAll("(ascribed");
                try sep(writer, depth, 1);
                try a.expr.printAt(writer, child(depth));
                try sep(writer, depth, 1);
                try printTypeExpr(a.type_name, writer);
                try close(writer, depth);
            },
            .table => |entries| {
                if (entries.len == 0) {
                    try writer.writeAll("(table)");
                    return;
                }
                try writer.writeAll("(table");
                for (entries) |entry| {
                    try sep(writer, depth, 1);
                    if (entry.key) |key| {
                        try writer.writeAll("(entry");
                        if (pretty) {
                            try writer.writeByte('\n');
                            try writeIndent(writer, (if (depth) |d| d + 1 else 0) + 1);
                        } else if (entry.computed) {
                            try writer.writeAll("[ ");
                        } else {
                            try writer.writeByte(' ');
                        }
                        try key.printAt(writer, child(child(depth)));
                        if (!pretty and entry.computed) try writer.writeAll("]");
                        try sep(writer, child(depth), 1);
                        try entry.value.printAt(writer, child(child(depth)));
                        try close(writer, child(depth));
                    } else {
                        try entry.value.printAt(writer, child(depth));
                    }
                }
                try close(writer, depth);
            },
            .try_expr => |expr| {
                try writer.writeAll("(try");
                try sep(writer, depth, 1);
                try expr.printAt(writer, child(depth));
                try close(writer, depth);
            },
            .orelse_expr => |binary| {
                try writer.writeAll("(orelse");
                try sep(writer, depth, 1);
                try binary.left.printAt(writer, child(depth));
                try sep(writer, depth, 1);
                try binary.right.printAt(writer, child(depth));
                try close(writer, depth);
            },
            .type_alias => |t| {
                try writer.print("(type {s}", .{t.name});
                try sep(writer, depth, 1);
                try printTypeExpr(t.type_expr, writer);
                try close(writer, depth);
            },
            .quasiquote => |qq| {
                try writer.writeAll("(quasiquote ");
                try qq.inner.printAt(writer, depth);
                try writer.writeAll(")");
            },
        }
    }
};

pub fn spanFromNodes(items: []const *Node, fallback: Span) Span {
    if (items.len == 0) return fallback;
    return Span.merge(items[0].span, items[items.len - 1].span);
}

// depth arithmetic helpers
fn child(depth: ?usize) ?usize {
    return if (depth) |d| d + 1 else null;
}

// sep: in compact mode write a space; in pretty mode write newline & indent at d+1
fn sep(writer: *std.Io.Writer, depth: ?usize, extra: usize) !void {
    if (depth) |d| {
        try writer.writeByte('\n');
        try writeIndent(writer, d + extra);
    } else {
        try writer.writeByte(' ');
    }
}

// close: in compact mode write ')'; in pretty mode do newline & indent at d then ')'
fn close(writer: *std.Io.Writer, depth: ?usize) !void {
    if (depth) |d| {
        try writer.writeByte('\n');
        try writeIndent(writer, d);
    }
    try writer.writeByte(')');
}

fn writeIndent(writer: *std.Io.Writer, depth: usize) !void {
    for (0..(depth * 2)) |_| try writer.writeByte(' ');
}

fn printNodeList(writer: *std.Io.Writer, comptime tag: []const u8, nodes: []const *Node, depth: ?usize) !void {
    if (nodes.len == 0) {
        try writer.print("({s})", .{tag});
        return;
    }
    try writer.print("({s}", .{tag});
    for (nodes) |node| {
        try sep(writer, depth, 1);
        try node.printAt(writer, child(depth));
    }
    try close(writer, depth);
}

fn printMatchArm(writer: *std.Io.Writer, arm: MatchArm, depth: ?usize) !void {
    try writer.writeAll("(arm");
    for (arm.matchers) |matcher| {
        try sep(writer, depth, 1);
        switch (matcher) {
            .wildcard => try writer.writeAll("_"),
            .expr => |expr| try expr.printAt(writer, child(depth)),
        }
    }
    if (arm.guard) |guard| {
        try sep(writer, depth, 1);
        try writer.writeAll("(when");
        try sep(writer, child(depth), 1);
        try guard.printAt(writer, child(child(depth)));
        try close(writer, child(depth));
    }
    try sep(writer, depth, 1);
    try arm.then.printAt(writer, child(depth));
    try close(writer, depth);
}

fn binOpName(op: BinOp) []const u8 {
    return switch (op) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .int_div => "//",
        .pow => "^",
        .mod => "%",
        .concat => "~",
        .eq => "==",
        .neq => "!=",
        .lt => "<",
        .gt => ">",
        .lte => "<=",
        .gte => ">=",
        .band => "band",
        .bor => "bor",
        .bxor => "bxor",
        .shl => "shl",
        .shr => "shr",
        .@"union" => "|",
    };
}

test "prints nested expression trees" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const span: Span = .{ .start = 0, .end = 0, .line = 1, .column = 1 };

    const one = try arena.allocator().create(Node);
    one.* = .{ .span = span, .expr = .{ .number = .{ .value = 1 } } };

    const zero = try arena.allocator().create(Node);
    zero.* = .{ .span = span, .expr = .{ .number = .{ .value = 0 } } };

    const call_ident = try arena.allocator().create(Node);
    call_ident.* = .{ .span = span, .expr = .{ .ident = "@foo" } };

    const call_args = try arena.allocator().alloc(*Node, 1);
    call_args[0] = zero;

    const call_expr = try arena.allocator().create(Node);
    call_expr.* = .{ .span = span, .expr = .{ .call = .{
        .callee = call_ident,
        .args = call_args,
    } } };

    const sum = try arena.allocator().create(Node);
    sum.* = .{ .span = span, .expr = .{ .binary = .{
        .op = .add,
        .left = one,
        .right = call_expr,
    } } };

    var buf = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();
    try sum.print(&buf.writer);
    try std.testing.expectEqualStrings("(+ 1 (call @foo 0))", buf.written());
}

test "pretty prints nested expression trees" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const span: Span = .{ .start = 0, .end = 0, .line = 1, .column = 1 };

    const one = try arena.allocator().create(Node);
    one.* = .{ .span = span, .expr = .{ .number = .{ .value = 1 } } };

    const zero = try arena.allocator().create(Node);
    zero.* = .{ .span = span, .expr = .{ .number = .{ .value = 0 } } };

    const call_ident = try arena.allocator().create(Node);
    call_ident.* = .{ .span = span, .expr = .{ .ident = "@foo" } };

    const call_args = try arena.allocator().alloc(*Node, 1);
    call_args[0] = zero;

    const call_expr = try arena.allocator().create(Node);
    call_expr.* = .{ .span = span, .expr = .{ .call = .{
        .callee = call_ident,
        .args = call_args,
    } } };

    const sum = try arena.allocator().create(Node);
    sum.* = .{ .span = span, .expr = .{ .binary = .{
        .op = .add,
        .left = one,
        .right = call_expr,
    } } };

    var buf = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();
    try sum.printPretty(&buf.writer);
    try std.testing.expectEqualStrings(
        \\(+
        \\  1
        \\  (call
        \\    @foo
        \\    0
        \\  )
        \\)
    , buf.written());
}

test "span merge keeps earliest start regardless argument order" {
    const left: Span = .{ .start = 10, .end = 20, .line = 2, .column = 5 };
    const right: Span = .{ .start = 2, .end = 8, .line = 1, .column = 3 };

    const merged_lr = Span.merge(left, right);
    const merged_rl = Span.merge(right, left);

    try std.testing.expectEqual(@as(usize, 2), merged_lr.start);
    try std.testing.expectEqual(@as(usize, 20), merged_lr.end);
    try std.testing.expectEqual(@as(u32, 1), merged_lr.line);
    try std.testing.expectEqual(@as(u32, 3), merged_lr.column);

    try std.testing.expectEqual(merged_lr.start, merged_rl.start);
    try std.testing.expectEqual(merged_lr.end, merged_rl.end);
    try std.testing.expectEqual(merged_lr.line, merged_rl.line);
    try std.testing.expectEqual(merged_lr.column, merged_rl.column);
}

test "prints break and return empty and valued forms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const span: Span = .{ .start = 0, .end = 0, .line = 1, .column = 1 };
    const one = try arena.allocator().create(Node);
    one.* = .{ .span = span, .expr = .{ .number = .{ .value = 1 } } };

    const break_empty = Node{ .span = span, .expr = .{ .break_expr = .{ .value = null, .label = null } } };
    const break_value = Node{ .span = span, .expr = .{ .break_expr = .{ .value = one, .label = null } } };
    const return_empty = Node{ .span = span, .expr = .{ .return_expr = null } };
    const return_value = Node{ .span = span, .expr = .{ .return_expr = one } };

    var buf = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();

    try break_empty.print(&buf.writer);
    try std.testing.expectEqualStrings("(break)", buf.written());
    buf.clearRetainingCapacity();

    try break_value.print(&buf.writer);
    try std.testing.expectEqualStrings("(break 1)", buf.written());
    buf.clearRetainingCapacity();

    try return_empty.print(&buf.writer);
    try std.testing.expectEqualStrings("(return)", buf.written());
    buf.clearRetainingCapacity();

    try return_value.print(&buf.writer);
    try std.testing.expectEqualStrings("(return 1)", buf.written());
}

fn walkTypeExprWithVisitor(comptime Visitor: type, visitor: *Visitor, te: *const TypeExpr) void {
    switch (te.kind) {
        .named => |name| {
            var temp: Node = .{ .span = te.span, .expr = .{ .ident = name } };
            visitor.visit(&temp);
        },
        .qualified => |q| {
            var mod_temp: Node = .{ .span = te.span, .expr = .{ .ident = q.module } };
            visitor.visit(&mod_temp);
            var name_temp: Node = .{ .span = te.span, .expr = .{ .ident = q.name } };
            visitor.visit(&name_temp);
        },
        .atom => {},

        .union_of => |variants| for (variants) |v| walkTypeExprWithVisitor(Visitor, visitor, v),
        .record => |fields| for (fields) |f| walkTypeExprWithVisitor(Visitor, visitor, f.type_expr),
        .function => |f| {
            for (f.params) |p| {
                if (p.type_name) |t| walkTypeExprWithVisitor(Visitor, visitor, t);
            }
            if (f.return_type) |ret| walkTypeExprWithVisitor(Visitor, visitor, ret);
        },
        .error_union => |inner| walkTypeExprWithVisitor(Visitor, visitor, inner),
        .parameterized => |p| {
            for (p.params) |param| walkTypeExprWithVisitor(Visitor, visitor, param);
        },
    }
}

pub fn walkAST(comptime Visitor: type, visitor: *Visitor, node: *const Node) void {
    if (@hasField(Visitor, "found") and visitor.found) return;

    switch (node.expr) {
        .quasiquote => return,
        inline else => |payload| {
            const ExprType = @TypeOf(payload);

            if (ExprType == void or ExprType == f64 or ExprType == []const u8 or ExprType == bool) return;

            if (ExprType == []*Node) {
                for (payload) |c| {
                    if (@hasField(Visitor, "found") and visitor.found) return;
                    visitor.visit(c);
                }
                return;
            }
            if (ExprType == []TableEntry) {
                for (payload) |entry| {
                    if (@hasField(Visitor, "found") and visitor.found) return;
                    if (entry.key) |key| visitor.visit(key);
                    if (@hasField(Visitor, "found") and visitor.found) return;
                    visitor.visit(entry.value);
                }
                return;
            }

            const field_names, const field_types = switch (@typeInfo(ExprType)) {
                .@"struct" => |s| .{ s.field_names, s.field_types },
                .@"union" => |u| .{ u.field_names, u.field_types },
                else => return,
            };

            inline for (field_names, field_types) |field_name, FieldType| {
                if (@hasField(Visitor, "found") and visitor.found) return;

                const value = @field(payload, field_name);

                switch (FieldType) {
                    *Node => {
                        visitor.visit(value);
                    },
                    []*Node => for (value) |c| {
                        if (@hasField(Visitor, "found") and visitor.found) return;
                        visitor.visit(c);
                    },
                    ?*Node => if (value) |c| visitor.visit(c),
                    *TypeExpr => walkTypeExprWithVisitor(Visitor, visitor, value),
                    ?*TypeExpr => if (value) |te| walkTypeExprWithVisitor(Visitor, visitor, te),
                    []MatchArm => for (value) |arm| {
                        if (@hasField(Visitor, "found") and visitor.found) return;
                        for (arm.matchers) |matcher| switch (matcher) {
                            .expr => |e| visitor.visit(e),
                            .wildcard => {},
                        };
                        if (@hasField(Visitor, "found") and visitor.found) return;
                        if (arm.guard) |guard| visitor.visit(guard);
                        if (@hasField(Visitor, "found") and visitor.found) return;
                        visitor.visit(arm.then);
                    },
                    []TableEntry => for (value) |entry| {
                        if (@hasField(Visitor, "found") and visitor.found) return;
                        if (entry.key) |key| visitor.visit(key);
                        if (@hasField(Visitor, "found") and visitor.found) return;
                        visitor.visit(entry.value);
                    },
                    else => {},
                }
            }
        },
    }
}

const UnderscoreVisitor = struct {
    found: bool = false,

    pub fn visit(self: *UnderscoreVisitor, node: *const Node) void {
        if (self.found) return;

        // std.debug.print("visiting: {}\n", .{node.expr});

        switch (node.expr) {
            .ident => |name| {
                // std.debug.print("  ident: {s}\n", .{name});
                if (std.mem.eql(u8, name, "_")) {
                    self.found = true;
                }
            },
            else => {
                walkAST(UnderscoreVisitor, self, node);
            },
        }
    }
};

pub fn hasUnderscore(node: *const Node) bool {
    var visitor = UnderscoreVisitor{};
    visitor.visit(node);
    return visitor.found;
}

test "hasUnderscore" {
    const pipeline = @import("pipeline.zig");
    var alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer alloc.deinit();
    const arena = alloc.allocator();
    var res = (try pipeline.parse(arena, .{ .text = "_", .name = "<>" }, .{})).ok;
    try std.testing.expect(hasUnderscore(res.root));
    res = (try pipeline.parse(arena, .{ .text = "x", .name = "<>" }, .{})).ok;
    try std.testing.expect(!hasUnderscore(res.root));
    res = (try pipeline.parse(arena, .{ .text = "{_, x}", .name = "<>" }, .{})).ok;
    try std.testing.expect(hasUnderscore(res.root));
    res = (try pipeline.parse(arena, .{ .text = "call{_, x}", .name = "<>" }, .{})).ok;
    try std.testing.expect(hasUnderscore(res.root));
    res = (try pipeline.parse(arena, .{ .text = "{a, b}", .name = "<>" }, .{})).ok;
    try std.testing.expect(!hasUnderscore(res.root));
    res = (try pipeline.parse(arena, .{ .text = "_:meth()", .name = "<>" }, .{})).ok;
    try std.testing.expect(hasUnderscore(res.root));
    res = (try pipeline.parse(arena, .{ .text = "_ + 42", .name = "<>" }, .{})).ok;
    try std.testing.expect(hasUnderscore(res.root));
}

const IdentityWalk = struct {
    pub fn walk(_: @This(), allocator: std.mem.Allocator, expr: *Node, _: @This()) std.mem.Allocator.Error!*Node {
        return walkExpr(allocator, expr, @This(), .{});
    }
};

test "walkExpr aliases armless nodes instead of copying (known gap)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const span = Span{ .start = 0, .end = 0, .line = 0, .column = 0 };

    // leaves have no walkExpr arm, else => expr hands back the same pointer
    const leaf = try allocNode(alloc, span, .nil);
    try std.testing.expect(try walkExpr(alloc, leaf, IdentityWalk, .{}) == leaf);

    // anything with an arm rebuilds, even when children are unchanged
    const operand = try allocNode(alloc, span, .nil);
    const parent = try allocNode(alloc, span, .{ .unary = .{ .op = .not, .expr = operand } });
    try std.testing.expect(try walkExpr(alloc, parent, IdentityWalk, .{}) != parent);
}

test "walkExpr drops fn doc/native on rebuild (known gap)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const span = Span{ .start = 0, .end = 0, .line = 0, .column = 0 };

    const body = try allocNode(alloc, span, .nil);
    const f = try allocNode(alloc, span, .{ .fn_expr = .{
        .params = &[_]FnParam{},
        .body = body,
        .doc = "hi",
        .native = true,
    } });
    const out = try walkExpr(alloc, f, IdentityWalk, .{});
    try std.testing.expect(out.expr.fn_expr.doc == null);
    try std.testing.expect(out.expr.fn_expr.native == false);
}
pub const NumberLiteral = struct {
    value: f64,
    is_float: bool = false,
};

pub fn allocNode(allocator: std.mem.Allocator, span: Span, expr: Expr) !*Node {
    const node = try allocator.create(Node);
    node.* = .{ .span = span, .expr = expr };
    return node;
}

pub fn walkSliceWith(
    allocator: std.mem.Allocator,
    items: []const *Node,
    comptime Transform: type,
    ctx: Transform,
) ![]*Node {
    var out = try std.ArrayList(*Node).initCapacity(allocator, items.len);
    for (items) |item| try out.append(allocator, try ctx.walk(allocator, @constCast(item), ctx));
    return out.toOwnedSlice(allocator);
}

fn walkMatch(
    allocator: std.mem.Allocator,
    span: Span,
    match_expr: anytype,
    comptime Transform: type,
    ctx: Transform,
) !*Node {
    var arms = try std.ArrayList(MatchArm).initCapacity(allocator, match_expr.arms.len);
    for (match_expr.arms) |arm| {
        var matchers = try std.ArrayList(MatchMatcher).initCapacity(allocator, arm.matchers.len);
        for (arm.matchers) |matcher| {
            switch (matcher) {
                .wildcard => try matchers.append(allocator, .wildcard),
                .expr => |v| try matchers.append(allocator, .{ .expr = try ctx.walk(allocator, v, ctx) }),
            }
        }
        try arms.append(allocator, .{
            .matchers = try matchers.toOwnedSlice(allocator),
            .guard = if (arm.guard) |g| try ctx.walk(allocator, g, ctx) else null,
            .then = try ctx.walk(allocator, arm.then, ctx),
        });
    }
    return allocNode(allocator, span, .{ .match_expr = .{
        .subject = try ctx.walk(allocator, match_expr.subject, ctx),
        .arms = try arms.toOwnedSlice(allocator),
    } });
}

fn walkTable(
    allocator: std.mem.Allocator,
    span: Span,
    entries: []const TableEntry,
    comptime Transform: type,
    ctx: Transform,
) !*Node {
    var out = try std.ArrayList(TableEntry).initCapacity(allocator, entries.len);
    for (entries) |entry| {
        try out.append(allocator, .{
            .key = if (entry.key) |k| try ctx.walk(allocator, k, ctx) else null,
            .computed = entry.computed,
            .value = try ctx.walk(allocator, entry.value, ctx),
        });
    }
    return allocNode(allocator, span, .{ .table = try out.toOwnedSlice(allocator) });
}

pub fn walkExpr(
    allocator: std.mem.Allocator,
    expr: *Node,
    comptime Transform: type,
    ctx: Transform,
) !*Node {
    return switch (expr.expr) {
        .unary => |v| allocNode(allocator, expr.span, .{ .unary = .{
            .op = v.op,
            .expr = try ctx.walk(allocator, v.expr, ctx),
        } }),
        .binary => |v| allocNode(allocator, expr.span, .{ .binary = .{
            .op = v.op,
            .left = try ctx.walk(allocator, v.left, ctx),
            .right = try ctx.walk(allocator, v.right, ctx),
        } }),
        .and_expr => |v| allocNode(allocator, expr.span, .{ .and_expr = .{
            .left = try ctx.walk(allocator, v.left, ctx),
            .right = try ctx.walk(allocator, v.right, ctx),
        } }),
        .or_expr => |v| allocNode(allocator, expr.span, .{ .or_expr = .{
            .left = try ctx.walk(allocator, v.left, ctx),
            .right = try ctx.walk(allocator, v.right, ctx),
        } }),
        .field => |v| allocNode(allocator, expr.span, .{ .field = .{
            .object = try ctx.walk(allocator, v.object, ctx),
            .name = v.name,
        } }),
        .index => |v| allocNode(allocator, expr.span, .{ .index = .{
            .object = try ctx.walk(allocator, v.object, ctx),
            .key = try ctx.walk(allocator, v.key, ctx),
        } }),
        .if_expr => |v| allocNode(allocator, expr.span, .{ .if_expr = .{
            .condition = try ctx.walk(allocator, v.condition, ctx),
            .then_expr = try ctx.walk(allocator, v.then_expr, ctx),
            .else_expr = if (v.else_expr) |e| try ctx.walk(allocator, e, ctx) else null,
        } }),
        .unless_expr => |v| allocNode(allocator, expr.span, .{ .unless_expr = .{
            .condition = try ctx.walk(allocator, v.condition, ctx),
            .then_expr = try ctx.walk(allocator, v.then_expr, ctx),
            .else_expr = if (v.else_expr) |e| try ctx.walk(allocator, e, ctx) else null,
        } }),
        .fn_expr => |v| allocNode(allocator, expr.span, .{ .fn_expr = .{
            .params = v.params,
            .return_type = v.return_type,
            .body = try ctx.walk(allocator, v.body, ctx),
            .type_params = v.type_params,
        } }),
        .loop_expr => |v| allocNode(allocator, expr.span, .{ .loop_expr = .{
            .body = try ctx.walk(allocator, v.body, ctx),
            .label = v.label,
        } }),
        .for_loop => |v| allocNode(allocator, expr.span, .{ .for_loop = .{
            .params = v.params,
            .iter = try ctx.walk(allocator, v.iter, ctx),
            .body = try ctx.walk(allocator, v.body, ctx),
            .label = v.label,
        } }),
        .while_loop => |v| allocNode(allocator, expr.span, .{ .while_loop = .{
            .predicate = v.predicate,
            .body = try ctx.walk(allocator, v.body, ctx),
            .label = v.label,
        } }),
        .break_expr => |v| allocNode(allocator, expr.span, .{
            .break_expr = .{
                .value = if (v.value) |inner| try ctx.walk(allocator, inner, ctx) else null,
                .label = v.label,
            },
        }),
        .continue_expr => |v| allocNode(allocator, expr.span, .{
            .continue_expr = .{
                .value = if (v.value) |inner| try ctx.walk(allocator, inner, ctx) else null,
                .label = v.label,
            },
        }),
        .labeled_block => |v| allocNode(allocator, expr.span, .{
            .labeled_block = .{
                .label = v.label,
                .body = try ctx.walk(allocator, v.body, ctx),
            },
        }),
        .return_expr => |v| allocNode(allocator, expr.span, .{
            .return_expr = if (v) |inner| try ctx.walk(allocator, inner, ctx) else null,
        }),
        .import_stmt => |v| allocNode(allocator, expr.span, .{
            .import_stmt = .{ .name = v.name, .path = v.path, .pub_ = v.pub_ },
        }),
        .decl => |d| allocNode(
            allocator,
            expr.span,
            .{ .decl = .{ .inner = try ctx.walk(allocator, d.inner, ctx), .kind = d.kind, .pub_ = d.pub_ } },
        ),

        .comp_block => |cb| allocNode(allocator, expr.span, .{ .comp_block = .{
            .expr = try ctx.walk(allocator, cb.expr, ctx),
        } }),
        .assign_expr => |v| allocNode(allocator, expr.span, .{ .assign_expr = .{
            .target = try ctx.walk(allocator, v.target, ctx),
            .value = try ctx.walk(allocator, v.value, ctx),
        } }),
        .compound_assign => |v| allocNode(allocator, expr.span, .{ .compound_assign = .{
            .target = try ctx.walk(allocator, v.target, ctx),
            .op = v.op,
            .value = try ctx.walk(allocator, v.value, ctx),
        } }),
        .binding => |v| allocNode(
            allocator,
            expr.span,
            .{ .binding = .{ .target = try ctx.walk(
                allocator,
                v.target,
                ctx,
            ), .type_name = v.type_name, .value = try ctx.walk(
                allocator,
                v.value,
                ctx,
            ), .mutable = v.mutable } },
        ),

        .table_pattern => |items| allocNode(allocator, expr.span, .{
            .table_pattern = try walkSliceWith(allocator, items, Transform, ctx),
        }),
        .ascribed => |a| allocNode(allocator, expr.span, .{ .ascribed = .{
            .expr = try ctx.walk(allocator, a.expr, ctx),
            .type_name = a.type_name,
        } }),
        .block => |items| {
            const n = try allocNode(allocator, expr.span, .{
                .block = try walkSliceWith(allocator, items, Transform, ctx),
            });
            n.synthetic_block = expr.synthetic_block;
            return n;
        },
        .call => |v| allocNode(allocator, expr.span, .{ .call = .{
            .callee = try ctx.walk(allocator, v.callee, ctx),
            .args = try walkSliceWith(allocator, v.args, Transform, ctx),
            .implicit_self = v.implicit_self,
            .type_args = v.type_args,
        } }),
        .proc_macro => |pm| allocNode(allocator, expr.span, .{ .proc_macro = .{
            .name = pm.name,
            .param = pm.param,
            .body = try ctx.walk(allocator, pm.body, ctx),
        } }),
        .match_expr => |v| walkMatch(allocator, expr.span, v, Transform, ctx),
        .table => |entries| walkTable(allocator, expr.span, entries, Transform, ctx),
        .range_literal => |v| allocNode(allocator, expr.span, .{ .range_literal = .{
            .start = try ctx.walk(allocator, v.start, ctx),
            .step = try ctx.walk(allocator, v.step, ctx),
            .end = try ctx.walk(allocator, v.end, ctx),
        } }),
        .slice_literal => |v| allocNode(allocator, expr.span, .{ .slice_literal = .{
            .start = if (v.start) |n| try ctx.walk(allocator, n, ctx) else null,
            .step = if (v.step) |n| try ctx.walk(allocator, n, ctx) else null,
            .end = if (v.end) |n| try ctx.walk(allocator, n, ctx) else null,
        } }),
        .try_expr => |v| allocNode(allocator, expr.span, .{
            .try_expr = try ctx.walk(allocator, v, ctx),
        }),
        .orelse_expr => |v| allocNode(allocator, expr.span, .{ .orelse_expr = .{
            .left = try ctx.walk(allocator, v.left, ctx),
            .right = try ctx.walk(allocator, v.right, ctx),
        } }),
        .test_block => |v| allocNode(allocator, expr.span, .{ .test_block = .{
            .name = v.name,
            .body = try ctx.walk(allocator, v.body, ctx),
            .skip = v.skip,
        } }),
        .test_suite => |v| allocNode(allocator, expr.span, .{ .test_suite = .{
            .name = v.name,
            .body = try ctx.walk(allocator, v.body, ctx),
        } }),
        .type_alias => |v| allocNode(allocator, expr.span, .{ .type_alias = .{
            .name = v.name,
            .name_span = v.name_span,
            .type_expr = v.type_expr,
            .doc = v.doc,
            .declare_head = v.declare_head,
            .declare_tps = v.declare_tps,
        } }),
        else => expr,
    };
}
