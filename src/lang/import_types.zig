const ast = @import("ast.zig");
const std = @import("std");
const types = @import("compiler/types.zig");
const TypeInfo = types.TypeInfo;

/// ======================= pub iface of mod ast ==========================
/// this bhv shold be
/// ~ record type for the import binding & resolved type aliases
/// ~ pub fn bindings get signature types (dep generics scoped correctly)
/// ~ pub consts get literal-inferred types (or any)
/// ~ pub re-exports get any
/// ~ non pub items are skipped
///
/// ~ type aliases are compile-time only (not values)
/// ~ record is null unless a pub export or an ascribed tail types it
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
    // keyed by bare name so dotted aliases (`uri.Hi`) resolve as `Hi`
    // inside the dep, matching specs declSpec
    for (items) |item| {
        if (item.expr != .decl) continue;
        const d = item.expr.decl;
        if (d.inner.expr == .type_alias) {
            try mctx.raws.put(ast.bareName(d.inner.expr.type_alias), d.inner.expr.type_alias.type_expr);
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

        const t = d.inner.expr.type_alias;
        const name = ast.bareName(t);

        if (mctx.resolveTypeAlias(name)) |ti| {
            try aliases.append(alloc, .{ .name = name, .info = ti });
        }
    }
    if (out.items.len == 0) {
        // a pub-less module is its last expression, so an ascribed tail
        // binding types the import flat, no declare needed:
        //   const e: { add: fn(number) -> number } = import "./ext.so"
        //   e
        const tail = tailBindingType(&mctx, items);
        return .{ .record = tail, .aliases = try aliases.toOwnedSlice(alloc) };
    }
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

    pub fn check(self: *ModuleCtx) types.CheckCtx {
        return types.CheckCtx.init(self, self.alloc);
    }

    pub fn isTypeParam(self: *const ModuleCtx, name: []const u8) bool {
        for (self.type_params) |tp| if (std.mem.eql(u8, tp, name)) return true;
        return false;
    }

    pub fn resolveTypeAlias(self: *ModuleCtx, name: []const u8) ?TypeInfo {
        const raw = self.raws.get(name) orelse return null;
        for (self.stack.items) |s| if (std.mem.eql(u8, s, name)) return null;
        self.stack.append(self.alloc, name) catch return null;
        defer _ = self.stack.pop();
        return types.evalTypeExpr(self.check(), raw) catch null;
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
        const combined = types.combinedTypeParams(self.alloc, type_params, params) catch type_params;
        self.type_params = combined;
        defer self.type_params = saved;

        const sig = types.buildFnSig(
            self.alloc,
            self,
            params,
            return_type,
            combined,
            doc,
            .{ .degrade_param = true },
        ) catch return .{ .tag = .any };

        return .{ .tag = .{ .function = sig } };
    }
};

fn moduleExportInto(mctx: *ModuleCtx, node: *const ast.Node, out: *std.ArrayList(types.RecordField)) !void {
    const alloc = mctx.alloc;
    switch (node.expr) {
        .decl => |d| {
            // host contracts, no runtime value
            if (d.kind == .declare_decl and d.inner.expr == .type_alias) {
                if (!d.pub_) return;
                const t = d.inner.expr.type_alias;
                const ft = types.evalTypeExpr(mctx.check(), t.type_expr) catch TypeInfo{ .tag = .any };
                try out.append(alloc, .{ .name = t.name, .field_type = ft });
                return;
            }
            if (!d.pub_) return;
            switch (d.inner.expr) {
                .binding => |b| {
                    if (b.target.expr != .ident) return;
                    // ascription wins over inference, as in analyzeBinding
                    const inferred = types.inferExprType(mctx.check(), b.value);
                    const field_type = if (b.type_name) |tn|
                        types.evalTypeExpr(mctx.check(), tn) catch inferred
                    else
                        inferred;
                    try out.append(alloc, .{
                        .name = b.target.expr.ident,
                        // inferred with the module ctx: unknown names
                        // degrade to any inside inference, so nothing
                        // leaks across scopes
                        .field_type = field_type,
                    });
                },
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
/// the name a pub-less module evaluates to: a trailing `return e`, `e` or
///   `const e = ...`, null otherwise
pub fn tailBindingName(items: []const *ast.Node) ?[]const u8 {
    if (items.len == 0) return null;
    const last = items[items.len - 1];
    if (last.expr == .decl and last.expr.decl.inner.expr == .binding) {
        const b = last.expr.decl.inner.expr.binding;
        if (b.target.expr == .ident and !ast.isDiscardName(b.target.expr.ident)) return b.target.expr.ident;
        return null;
    }
    switch (last.expr) {
        .return_expr => |val| {
            const v = val orelse return null;
            if (v.expr != .ident or ast.isDiscardName(v.expr.ident)) return null;
            return v.expr.ident;
        },
        .ident => |n| {
            if (ast.isDiscardName(n)) return null;
            return n;
        },
        else => return null,
    }
}

/// the tail binding's ascription, newest binding first
fn tailBindingType(mctx: *ModuleCtx, items: []const *ast.Node) ?TypeInfo {
    const name = tailBindingName(items) orelse return null;
    var i = items.len;
    while (i > 0) {
        i -= 1;
        const item = items[i];
        if (item.expr == .decl and item.expr.decl.inner.expr == .binding) {
            const b = item.expr.decl.inner.expr.binding;
            if (b.target.expr == .ident and std.mem.eql(u8, b.target.expr.ident, name)) {
                if (b.type_name) |tn| {
                    return types.evalTypeExpr(mctx.check(), tn) catch null;
                }
                return null;
            }
        }
        if (item.expr == .import_stmt and std.mem.eql(u8, item.expr.import_stmt.name, name)) return null;
    }
    return null;
}
