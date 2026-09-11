const std = @import("std");
const ast = @import("ast.zig");
const types = @import("compiler/types.zig");
const TypeInfo = types.TypeInfo;

const type_serde = @import("type_serde.zig");

/// ======================= pub iface of mod ast ==========================
/// this bhv shold be
/// ~ record type for the import binding & resolved type aliases
/// ~ pub fn bindings get signature types (dep generics scoped correctly)
/// ~ pub consts get literal-inferred types (or any)
/// ~ pub re-exports get any
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
    // keyed by bare name so dotted aliases (`uri.Hi`) resolve as `Hi`
    // inside the dep, matching api declSpec
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
        return type_serde.evalTypeExpr(self, raw) catch null;
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
            param_types.append(self.alloc, if (p.type_name) |tn| type_serde.evalTypeExpr(self, tn) catch .{ .tag = .any } else .{ .tag = .any }) catch return .{ .tag = .any };
            if (!p.optional and p.default_value == null) required += 1;
        }

        const owned_params = param_types.toOwnedSlice(self.alloc) catch return .{ .tag = .any };
        errdefer self.alloc.free(owned_params);
        const owned_names = param_names.toOwnedSlice(self.alloc) catch return .{ .tag = .any };
        errdefer self.alloc.free(owned_names);

        const ret: TypeInfo = if (return_type) |rt|
            type_serde.evalTypeExpr(self, rt) catch .{ .tag = .any }
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
                const ft = type_serde.evalTypeExpr(mctx, t.type_expr) catch TypeInfo{ .tag = .any };
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
