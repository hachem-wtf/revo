// zlint-disable line-length
const std = @import("std");

const ast = @import("./ast.zig");
const diagnostic = @import("diagnostic.zig");
const import_types = @import("import_types.zig");
const Parser = @import("Parser.zig");
const revo = @import("revo");
const scope_graph = @import("scope_graph.zig");
const type_syntax = @import("type_syntax.zig");
const types_mod = @import("compiler/types.zig");

pub const Kind = enum {
    SemanticError,
};

pub const Failure = diagnostic.Diagnostic(Kind);

pub const ModuleResolver = struct {
    ptr: *anyopaque,
    resolveFn: *const fn (ptr: *anyopaque, path: []const u8, alloc: std.mem.Allocator) ?[]const u8,

    pub fn resolve(self: ModuleResolver, path: []const u8, alloc: std.mem.Allocator) ?[]const u8 {
        return self.resolveFn(self.ptr, path, alloc);
    }
};

/// run semantic analysis; known_globals are names that exist at runtime (builtins)
/// type_map, if set, is populated with name -> type_name during analysis
/// annotations, if set, intern every analyzed node into the table
/// module_resolver resolves import paths to source text
pub fn analyze(
    alloc: std.mem.Allocator,
    root: *const ast.Node,
    source_name: []const u8,
    source: []const u8,
    known_globals: []const []const u8,
    type_map: ?*std.StringHashMap(types_mod.TypeInfo),
    annotations: ?types_mod.Annotations,
    docs: ?*std.StringHashMap([]const u8),
    module_resolver: ModuleResolver,
    graph: ?*scope_graph.ScopeGraph,
    warnings: *?diagnostic.Report,
) !?Failure {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var checker = try SemanticChecker.init(arena_alloc, source_name, source, known_globals, type_map, annotations, docs, module_resolver, graph);
    defer checker.deinit();

    try checker.collectPredeclared(root);
    _ = try checker.analyzeNode(root);
    if (type_map) |tm| {
        try reparentMap([]const u8, std.StringHashMap(types_mod.TypeInfo), tm, alloc);
    }
    if (docs) |dm| try reparentDocs(dm, alloc);
    if (checker.errors.items.len == 0) {
        // warnings never fail the build; errors dominate so these drop with them
        if (checker.warn_parts.items.len > 0) {
            const wrep = try checker.finishWarnings();
            warnings.* = try wrep.copy(alloc);
        }
        return null;
    }

    const report = try checker.finishReport();
    const copied = try report.copy(alloc);
    return .{ .kind = .SemanticError, .report = copied };
}

/// type of a literal pattern
/// , or null when the pattern is not one
fn patternLitType(pattern: *const ast.Node) ?types_mod.TypeInfo {
    return switch (pattern.expr) {
        .atom => |name| .{ .tag = .{ .atom = name } },
        .nil => .{ .tag = .{ .atom = ":nil" } },
        .number => .{ .tag = .number },
        .string, .multiline_string => .{ .tag = .string },
        else => null,
    };
}

///
/// prior pattern fires on every value cur could match
/// prior ascriptions prove nothing here, so those do nathan
fn patternSubsumes(prior: *const ast.Node, cur: *const ast.Node) bool {
    if (prior.expr == .ident) return true;
    switch (prior.expr) {
        .atom => |name| return cur.expr == .atom and std.mem.eql(u8, ast.atomName(cur.expr.atom), ast.atomName(name)),
        .nil => return cur.expr == .nil,
        .number => |n| return cur.expr == .number and cur.expr.number.value == n.value,
        .string, .multiline_string => |s| {
            const cs = if (cur.expr == .string)
                cur.expr.string
            else if (cur.expr == .multiline_string)
                cur.expr.multiline_string
            else
                return false;
            return std.mem.eql(u8, cs, s);
        },
        .table_pattern => |pitems| {
            if (cur.expr != .table_pattern) return false;
            const citems = cur.expr.table_pattern;
            if (pitems.len != citems.len) return false;

            // heads are just element zero, no special case
            for (pitems, citems) |pi, ci|
                if (!patternSubsumes(pi, ci)) return false;

            return true;
        },
        else => return false,
    }
}

fn reparentMap(comptime K: type, comptime Map: type, map: *Map, alloc: std.mem.Allocator) !void {
    var keys = try std.ArrayList(K).initCapacity(alloc, map.count());
    defer keys.deinit(alloc);
    var vals = try std.ArrayList(types_mod.TypeInfo).initCapacity(alloc, map.count());
    defer vals.deinit(alloc);
    var it = map.iterator();
    while (it.next()) |entry| {
        if (comptime K == []const u8) {
            keys.appendAssumeCapacity(try alloc.dupe(u8, entry.key_ptr.*));
        } else {
            keys.appendAssumeCapacity(entry.key_ptr.*);
        }
        vals.appendAssumeCapacity(try types_mod.clone(entry.value_ptr.*, alloc));
    }
    map.clearRetainingCapacity();
    for (keys.items, vals.items) |k, v|
        try map.put(k, v);
}

/// docs point into the analysis arena; re-own keys and text for the caller
fn reparentDocs(map: *std.StringHashMap([]const u8), alloc: std.mem.Allocator) !void {
    var keys = try std.ArrayList([]const u8).initCapacity(alloc, map.count());
    defer keys.deinit(alloc);
    var vals = try std.ArrayList([]const u8).initCapacity(alloc, map.count());
    defer vals.deinit(alloc);
    var it = map.iterator();
    while (it.next()) |entry| {
        keys.appendAssumeCapacity(try alloc.dupe(u8, entry.key_ptr.*));
        vals.appendAssumeCapacity(try alloc.dupe(u8, entry.value_ptr.*));
    }
    map.clearRetainingCapacity();
    for (keys.items, vals.items) |k, v|
        try map.put(k, v);
}

const Scope = struct {
    values: std.StringHashMap(Entry),

    fn init(alloc: std.mem.Allocator) Scope {
        return .{ .values = std.StringHashMap(Entry).init(alloc) };
    }

    fn deinit(self: *Scope) void {
        self.values.deinit();
    }
};

/// a declaration's type plus doc; docs inherit through ident assignment
const Entry = struct {
    info: types_mod.TypeInfo,
    doc: ?[]const u8 = null,
};

const FnSig = types_mod.FunctionSignature;

const SemanticChecker = struct {
    alloc: std.mem.Allocator,
    source_name: []const u8,
    source: []const u8,
    errors: std.ArrayList(diagnostic.Part),
    /// code of the first error
    ///
    /// reports carry one code like they carry one message,
    /// for per-error codes u need to refactor the Diagnostic struct
    first_code: ?[]const u8 = null,
    /// code of the first warning, same first-wins as abve
    first_warn_code: ?[]const u8 = null,
    /// non-failing diagnostics; emitted alongside success, dropped on error
    warn_parts: std.ArrayList(diagnostic.Part),
    scopes: std.ArrayList(Scope),
    type_aliases: std.StringHashMap(types_mod.Alias),
    /// caller-owned out-map: declared name -> doc text, last declare wins
    docs: ?*std.StringHashMap([]const u8),
    /// one sig per baselib spec, keyed by the spec's const-storage address
    sig_cache: std.AutoHashMap(*const revo.baselib.specs.FnSpec, *const FnSig),
    return_types: std.ArrayList(types_mod.TypeInfo),
    type_map: ?*std.StringHashMap(types_mod.TypeInfo),
    annotations: ?types_mod.Annotations,
    typed_names: std.StringHashMap(void),
    table_field_map: std.StringHashMap(std.StringHashMap(types_mod.TypeInfo)),
    /// idents assigned inside fn bodies
    /// the closure may run anywhere, so their table shapes are no longer fully known
    /// (never cleared; may miss flags, never false-flags)
    escaped: std.StringHashMap(void),
    /// vm globals, module field resolution only applies to these so a
    /// local binding named `fs` shadows the baselib module
    known_globals: std.StringHashMap(void),
    /// known globals rebound by user code (shadowed by a local binding)
    shadowed_globals: std.StringHashMap(void),
    /// toplevel fn bindings only, so a fn may call a sibling defined below it
    ///
    /// this mirrors `predeclare` in `compiler/locals.zig` name for name
    ///
    /// anything the compiler skips there has no slot
    /// ,,, so letting it through here would typecheck
    /// and then die at runtime with an undefined variable
    ///
    /// . plain values are stay order dependent instead
    predeclared: std.StringHashMapUnmanaged(void) = .empty,
    current_type_params: []const []const u8 = &.{},
    /// > 0 while inside a fn body; gates type_map/docs exports
    fn_nesting: usize = 0,
    resolver: ModuleResolver,
    /// module name -> pub type aliases, for `a.T` annotations
    import_aliases: std.StringHashMap(std.StringHashMap(types_mod.TypeInfo)),
    /// mirror scope, null means off
    graph: ?*scope_graph.ScopeGraph = null,
    graph_scope: scope_graph.ScopeId = 0,

    fn init(
        alloc: std.mem.Allocator,
        source_name: []const u8,
        source: []const u8,
        known_globals: []const []const u8,
        type_map: ?*std.StringHashMap(types_mod.TypeInfo),
        annotations: ?types_mod.Annotations,
        docs: ?*std.StringHashMap([]const u8),
        resolver: ModuleResolver,
        graph: ?*scope_graph.ScopeGraph,
    ) !SemanticChecker {
        var checker: SemanticChecker = .{
            .alloc = alloc,
            .source_name = source_name,
            .source = source,
            .errors = try .initCapacity(alloc, 8),
            .warn_parts = try .initCapacity(alloc, 4),
            .scopes = try .initCapacity(alloc, 4),
            .type_aliases = .init(alloc),
            .docs = docs,
            .sig_cache = .init(alloc),
            .return_types = try .initCapacity(alloc, 4),
            .type_map = type_map,
            .annotations = annotations,
            .typed_names = .init(alloc),
            .table_field_map = .init(alloc),
            .escaped = .init(alloc),
            .known_globals = .init(alloc),
            .shadowed_globals = .init(alloc),
            .resolver = resolver,
            .import_aliases = .init(alloc),
            .graph = graph,
            .graph_scope = 0,
        };

        try checker.scopes.append(checker.alloc, Scope.init(checker.alloc));
        if (graph) |g| {
            checker.graph_scope = try g.fileRoot(source_name, ast.Span{ .start = 0, .end = 0, .line = 0, .column = 0 });
        }
        // builtins never export to type_map/docs - real declarations must
        // win, and repl runtime globals re-enter here untyped
        for (known_globals) |name|
            try checker.declareBuiltin(name);
        for (known_globals) |name|
            try checker.known_globals.put(name, {});

        // registers baselib function types
        for (known_globals) |name| {
            const spec = find_global: {
                for (revo.baselib.specs.full_specs) |group| for (group) |*s| {
                    if (s.is_type) continue;
                    if (!std.mem.eql(u8, s.name, name)) continue;
                    if (s.head.kind == .global) break :find_global s;
                };
                break :find_global null;
            } orelse continue;
            if (try checker.makeStdlibSig(spec)) |sig| {
                try checker.scopes.items[checker.scopes.items.len - 1].values.put(name, .{ .info = .{ .tag = .{ .function = sig } } });
                checker.mirrorDeclare(name, .function, if (spec.doc.len > 0) spec.doc else null);
            }
        }

        for (revo.baselib.specs.full_specs) |group| {
            for (group) |*s| {
                if (!s.is_type) continue;
                const t = checker.evalCheckedTypeExpr(s.type) catch types_mod.TypeInfo{ .tag = .any };
                // aliases live where values live
                // : module heads seed the per-module table
                //   (`uri.Hi`, docs ride on the spec), bare names seed globals
                if (s.head.kind == .namespaced) {
                    const gop = try checker.import_aliases.getOrPut(s.head.module.?);
                    if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap(types_mod.TypeInfo).init(checker.alloc);
                    try gop.value_ptr.put(s.name, t);
                } else {
                    const entry: types_mod.Alias = .{ .info = t, .doc = if (s.doc.len > 0) s.doc else null };
                    try checker.type_aliases.put(s.name, entry);
                }
            }
        }

        return checker;
    }

    fn deinit(self: *SemanticChecker) void {
        for (self.scopes.items) |*scope| scope.deinit();
        self.scopes.deinit(self.alloc);
        self.predeclared.deinit(self.alloc);
    }

    /// collect top-level fn binding names so forward references
    /// between them don't read as unknown names
    ///
    /// `predeclare` in the compiler is the other half
    /// ; keep the two predicates identical
    ///   or the checker will bless names the compiler never gave a slot
    fn collectPredeclared(self: *SemanticChecker, root: *const ast.Node) !void {
        const items: []const *const ast.Node = switch (root.expr) {
            .block => |exprs| exprs,
            else => return,
        };

        for (items) |item| {
            const decl = switch (item.expr) {
                .decl => |d| d,
                else => continue,
            };

            if (decl.kind == .global or decl.kind == .global_const) continue; // duh
            switch (decl.inner.expr) {
                .binding => |b| {
                    if (b.target.expr != .ident or b.value.expr != .fn_expr) continue;
                    const name = b.target.expr.ident;
                    if (ast.isDiscardName(name)) continue;
                    try self.predeclared.put(self.alloc, name, {});
                },
                else => {},
            }
        }
    }

    /// dep file ast for an import path, null when unresolvable
    ///
    /// import arm builds a record type from it on demand
    fn resolveDepAst(self: *SemanticChecker, path: []const u8) ?*const ast.Node {
        const source_alloc = self.resolver.resolve(path, self.alloc) orelse return null;
        defer self.alloc.free(source_alloc);

        const source = self.alloc.dupe(u8, source_alloc) catch return null;
        return Parser.parseSource(self.alloc, source, .{}) catch return null;
    }

    fn finishReport(self: *SemanticChecker) !diagnostic.Report {
        const parts = try self.errors.toOwnedSlice(self.alloc);
        const first_msg = for (parts) |p| {
            if (p == .@"error") break p.@"error";
        } else "";

        return .{
            .parts = parts,
            .message = if (first_msg.len > 0) try self.alloc.dupe(u8, first_msg) else "",
            .code = self.first_code,
            .source_name = try self.alloc.dupe(u8, self.source_name),
            .source = try self.alloc.dupe(u8, self.source),
        };
    }

    fn finishWarnings(self: *SemanticChecker) !diagnostic.Report {
        const parts = try self.warn_parts.toOwnedSlice(self.alloc);
        const first_msg = for (parts) |p| {
            if (p == .warn) break p.warn;
        } else "";

        return .{
            .parts = parts,
            .message = if (first_msg.len > 0) try self.alloc.dupe(u8, first_msg) else "",
            .severity = .warning,
            .code = self.first_warn_code,
            .source_name = try self.alloc.dupe(u8, self.source_name),
            .source = try self.alloc.dupe(u8, self.source),
        };
    }

    fn pushScope(self: *SemanticChecker, kind: scope_graph.ScopeKind) !void {
        try self.scopes.append(self.alloc, Scope.init(self.alloc));
        if (self.graph) |g| {
            // spans stay zero til the ide needs em
            const no_span = ast.Span{ .start = 0, .end = 0, .line = 0, .column = 0 };
            self.graph_scope = try g.childScope(self.graph_scope, kind, no_span);
        }
    }

    fn popScope(self: *SemanticChecker) void {
        _ = self.scopes.pop();
        if (self.graph) |g| {
            self.graph_scope = g.scopes.items[self.graph_scope].parent orelse self.graph_scope;
        }
    }

    fn declare(self: *SemanticChecker, name: []const u8, t: types_mod.TypeInfo, doc: ?[]const u8, kind: scope_graph.DefKind) !void {
        return self.declareInner(name, t, doc, true, kind);
    }

    /// scope-only registration; never exports to type_map/docs
    fn declareBuiltin(self: *SemanticChecker, name: []const u8) !void {
        return self.declareInner(name, .{ .tag = .any }, null, false, .binding);
    }

    /// a declaration that lands on a name already in reach
    ///
    /// newest wins silently, which is rarely what the writer meant, so
    /// say so. called from the binding and param sites, not from
    /// `declare`, because assignment and pattern tracking reuse declare
    /// and must stay quiet.
    fn warnShadow(self: *SemanticChecker, name: []const u8, span: ast.Span) !void {
        if (ast.isDiscardName(name)) return;
        // scope 0 holds the seeded baselib globals; shadowing one of those
        // is a normal thing to do, only warn once we are inside the file
        if (self.scopes.items.len <= 1) return;
        const here = self.scopes.items[self.scopes.items.len - 1].values;
        if (here.contains(name)) {
            try self.appendWarn(
                try self.alloc.print("`{s}` is already declared in this scope", .{name}),
                span,
                try self.alloc.dupe(u8, "already declared"),
                "duplicate-declaration",
            );
            return;
        }
        var i = self.scopes.items.len - 1;
        while (i > 1) {
            i -= 1;
            if (!self.scopes.items[i].values.contains(name)) continue;
            try self.appendWarn(
                try self.alloc.print("`{s}` shadows an outer binding", .{name}),
                span,
                try self.alloc.dupe(u8, "shadows outer binding"),
                "shadowed-binding",
            );
            return;
        }
    }

    /// record into the graph too
    /// , spans stay zero til the ide needs em, kinds are exact
    fn mirrorDeclare(self: *SemanticChecker, name: []const u8, kind: scope_graph.DefKind, doc: ?[]const u8) void {
        if (self.graph) |g| {
            const no_span = ast.Span{ .start = 0, .end = 0, .line = 0, .column = 0 };
            _ = g.declare(self.graph_scope, name, kind, no_span, doc) catch {};
        }
    }

    fn declareInner(self: *SemanticChecker, name: []const u8, t: types_mod.TypeInfo, doc: ?[]const u8, export_type: bool, kind: scope_graph.DefKind) !void {
        if (self.scopes.items.len == 0) try self.pushScope(.block);
        try self.scopes.items[self.scopes.items.len - 1].values.put(name, .{ .info = t, .doc = doc });
        self.mirrorDeclare(name, kind, doc);
        if (self.known_globals.contains(name)) {
            try self.shadowed_globals.put(name, {});
        }

        // module surface: top-level re-declarations shadow (newest wins);
        // fn-local bindings only fill names the surface doesn't have yet
        if (export_type) {
            if (self.type_map) |tm| {
                if (self.fn_nesting == 0) {
                    if (tm.contains(name)) _ = tm.remove(name);
                    try tm.put(try self.alloc.dupe(u8, name), t);
                } else if (!tm.contains(name)) {
                    try tm.put(try self.alloc.dupe(u8, name), t);
                }
            }
            if (self.fn_nesting == 0) {
                if (doc) |d| {
                    if (self.docs) |dm| {
                        const key = try self.alloc.dupe(u8, name);
                        errdefer self.alloc.free(key);
                        try dm.put(key, d);
                    }
                }
            }
        }
    }

    fn lookup(self: *SemanticChecker, name: []const u8) ?types_mod.TypeInfo {
        return if (self.lookupEntry(name)) |e| e.info else null;
    }

    fn lookupEntry(self: *SemanticChecker, name: []const u8) ?Entry {
        var i: usize = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].values.get(name)) |v| return v;
        }
        if (self.type_aliases.get(name)) |a| return .{ .info = a.info, .doc = a.doc };
        return null;
    }

    // the CheckCtx scope for types.zig inference
    pub fn check(self: *SemanticChecker) types_mod.CheckCtx {
        var ctx = types_mod.CheckCtx.init(self, self.alloc);
        ctx.scope = self.aliasScope();
        return ctx;
    }

    pub fn aliasScope(self: *SemanticChecker) types_mod.AliasScope {
        return .{
            .alloc = self.alloc,
            .type_params = self.current_type_params,
            .aliases = &self.type_aliases,
            .imports = &self.import_aliases,
        };
    }

    pub fn inferIdentType(self: *SemanticChecker, name: []const u8) types_mod.TypeInfo {
        return self.lookup(name) orelse .{ .tag = .any };
    }

    pub fn inferFnType(self: *SemanticChecker, params: []const ast.FnParam, return_type: ?*ast.TypeExpr, type_params: []const []const u8, doc: ?[]const u8) types_mod.TypeInfo {
        const combined = types_mod.combinedTypeParams(self.alloc, type_params, params) catch type_params;
        const saved = self.current_type_params;
        self.current_type_params = combined;
        defer self.current_type_params = saved;
        const sig = self.makeFnSig(.{ .params = params, .return_type = return_type, .type_params = type_params, .doc = doc }) catch return .{ .tag = .any };
        return .{ .tag = .{ .function = sig } };
    }

    pub fn inferCallReturnType(
        self: *SemanticChecker,
        callee: *const ast.Node,
        args: []const *ast.Node,
        type_args: []const []const u8,
        implicit_self: bool,
    ) types_mod.TypeInfo {
        const callee_type = types_mod.inferExprType(self.check(), callee);
        if (callee_type.tag == .function) {
            const sig = callee_type.tag.function;
            if (sig.type_params.len > 0 and sig.return_type.tag != .any) {
                return types_mod.substCallReturn(self.check(), sig, callee, args, type_args, implicit_self);
            }
            return sig.return_type;
        }
        return .{ .tag = .any };
    }

    /// an ident assigned inside a fn body could be mutated from anywhere
    ///   once the closure escapes
    ///
    /// only marks names bound outside the current scope
    ///   (locals assigned in their own scope r still precise)
    fn markEscaped(self: *SemanticChecker, name: []const u8) !void {
        if (self.fn_nesting == 0) return;
        if (self.scopes.items.len == 0) return;
        if (self.scopes.items[self.scopes.items.len - 1].values.contains(name)) return;
        try self.escaped.put(name, {});
    }

    /// unknown member access on a fully-known table shape
    /// so `t.a` where every field of t is known but lacks `a`
    /// ~ open tables with unknown shapes (fields == null) never flag
    /// ~ assigned and imported fields count via table_field_map
    /// ~ escaped tables (mutated through closures) never flag
    fn checkKnownField(self: *SemanticChecker, object: *const ast.Node, name: []const u8, span: ast.Span) !void {
        const object_type = types_mod.inferExprType(self.check(), object);
        switch (object_type.tag) {
            .table => |tbl| {
                if (object.expr == .ident and self.escaped.contains(object.expr.ident)) return;
                if (tbl.fields) |fs| {
                    if (types_mod.findField(fs, name) != null) return;
                    if (object.expr == .ident) {
                        if (self.table_field_map.get(object.expr.ident)) |fields| {
                            if (fields.get(name) != null) return;
                        }
                    }
                    const obj_str = try type_syntax.formatTypeOpts(self.alloc, object_type, .{});
                    const msg = try self.alloc.print("field `{s}` is not defined on {s}", .{ name, obj_str });
                    try self.appendError(msg, span, "unknown field");
                }
            },
            else => {},
        }
    }

    /// `a.T` in type position: the module must be a known import carrying
    /// the alias, otherwise the annotation cannot mean anything.
    /// unresolvable modules stay silent (the dep may simply not be on
    /// disk for tooling); evalTypeExpr already degrades those to any
    fn checkQualifiedTypes(self: *SemanticChecker, te: *const ast.TypeExpr) !void {
        switch (te.kind) {
            .qualified => |q| {
                if (self.import_aliases.get(q.module)) |aliases| {
                    if (aliases.get(q.name) == null) {
                        const msg = try self.alloc.print("unknown type `{s}` for module `{s}`", .{ q.name, q.module });
                        try self.appendError(msg, te.span, "unknown type");
                    }
                }
            },
            .union_of => |variants| for (variants) |v| try self.checkQualifiedTypes(v),
            .record => |fields| for (fields) |f| try self.checkQualifiedTypes(f.type_expr),
            .function => |f| {
                for (f.params) |p| if (p.type_name) |t| try self.checkQualifiedTypes(t);
                if (f.return_type) |ret| try self.checkQualifiedTypes(ret);
            },
            .parameterized => |p| for (p.params) |param| try self.checkQualifiedTypes(param),
            .error_union => |inner| try self.checkQualifiedTypes(inner),
            .named, .atom => {},
        }
    }

    /// user annotation: validate qualified names, then evaluate
    fn evalCheckedTypeExpr(self: *SemanticChecker, te: *const ast.TypeExpr) !types_mod.TypeInfo {
        try self.checkQualifiedTypes(te);
        return try types_mod.evalTypeExpr(self.aliasScope(), te);
    }

    pub fn inferFieldType(self: *SemanticChecker, object: *const ast.Node, name: []const u8) types_mod.TypeInfo {
        const object_type = types_mod.inferExprType(self.check(), object);
        // user-defined table fields shadow baselib methods: literal shapes
        // first, flow-sensitive assignment tracking second
        if (object_type.tag == .table) {
            if (object_type.tag.table.fields) |fs| {
                if (types_mod.findField(fs, name)) |f| return f.field_type;
            }
            if (object.expr == .ident) {
                if (self.table_field_map.get(object.expr.ident)) |fields| {
                    if (fields.get(name)) |ft| return ft;
                }
            }
        }
        // method lookup runs through the type's module table: the module
        // fn doubles as the method, e.g. `t:unwrap_err()` resolves
        // `table.unwrap_err` at runtime
        const target: ?revo.baselib.host.ParamType = switch (object_type.tag) {
            .number => .number,
            .string => .string,
            .table => .table,
            else => null,
        };
        if (target) |t| {
            if (findModuleByNameAndTarget(name, t)) |spec| {
                if (self.makeStdlibSig(spec) catch null) |sig| {
                    return .{ .tag = .{ .function = sig } };
                }
            }
        }
        // baselib module function lookup: fs.exists?, file.read, time.now.
        // only globals are modules; a local binding shadows the module
        if (object.expr == .ident and
            self.known_globals.contains(object.expr.ident) and
            !self.shadowed_globals.contains(object.expr.ident))
        {
            const module_name = object.expr.ident;
            for (revo.baselib.specs.full_specs) |group| for (group) |*spec| {
                if (spec.is_type) continue;
                if (!std.mem.eql(u8, spec.name, name)) continue;
                const head = spec.head;
                if (head.kind == .namespaced and std.mem.eql(u8, head.module.?, module_name)) {
                    if (self.makeStdlibSig(spec) catch null) |sig| {
                        return .{ .tag = .{ .function = sig } };
                    }
                }
            };
        }
        return .{ .tag = .any };
    }

    /// `T?` and `?T` both land as a union carrying `:nil`
    fn isNilableParam(te: ?*ast.TypeExpr) bool {
        const t = te orelse return false;
        const variants = switch (t.kind) {
            .union_of => |v| v,
            else => return false,
        };
        for (variants) |v| {
            if (v.kind == .atom and std.mem.startsWith(u8, v.kind.atom, ":")) return true;
        }
        return false;
    }

    /// params up to the first soft one: `?name:`, `name: T?` or a variadic
    ///   tail, all of which the host fills in
    fn fixedPrefix(params: []const ast.FnParam) usize {
        var n: usize = 0;
        for (params) |p| {
            if (p.optional or p.variadic or isNilableParam(p.type_name)) break;
            n += 1;
        }
        return n;
    }

    fn makeStdlibSig(self: *SemanticChecker, spec: *const revo.baselib.specs.FnSpec) !?*const FnSig {
        if (spec.is_type) return null;
        if (self.sig_cache.get(spec)) |sig| return sig;
        const saved = self.current_type_params;
        self.current_type_params = spec.type_params;
        defer self.current_type_params = saved;

        const ft = spec.type.kind.function;
        var param_types = try std.ArrayList(types_mod.TypeInfo).initCapacity(self.alloc, ft.params.len);
        var param_names = try std.ArrayList([]const u8).initCapacity(self.alloc, ft.params.len);

        for (ft.params) |p| {
            try param_names.append(self.alloc, p.name);
            try param_types.append(self.alloc, if (p.type_name) |tn| types_mod.evalTypeExpr(self.aliasScope(), tn) catch types_mod.TypeInfo{ .tag = .any } else types_mod.TypeInfo{ .tag = .any });
        }

        const names_slice = try param_names.toOwnedSlice(self.alloc);
        const types_slice = try param_types.toOwnedSlice(self.alloc);

        // required is the host arity, not the `?` flags, since baselib
        // spells optionals as nilable; the fixed prefix is a floor on top,
        //   so `zip(a, b, rest...)` still wants two. keep in sync
        const ret = if (ft.return_type) |r| types_mod.evalTypeExpr(self.aliasScope(), r) catch types_mod.TypeInfo{ .tag = .any } else types_mod.TypeInfo{ .tag = .any };
        const sig = try types_mod.newSignature(self.alloc, .{
            .param_names = names_slice,
            .params = types_slice,
            .return_type = ret,
            .required_count = @max(spec.f.arity, fixedPrefix(ft.params)),
            .type_params = spec.type_params,
            .doc = if (spec.doc.len > 0) spec.doc else null,
        });

        try self.sig_cache.put(spec, sig);
        return sig;
    }

    fn makeFnSig(self: *SemanticChecker, fn_expr: anytype) !*FnSig {
        const doc: ?[]const u8 = if (@hasField(@TypeOf(fn_expr), "doc")) fn_expr.doc else null;
        for (fn_expr.params) |p| if (p.type_name) |t| try self.checkQualifiedTypes(t);
        if (fn_expr.return_type) |rt| try self.checkQualifiedTypes(rt);

        return try types_mod.buildFnSig(
            self.alloc,
            self,
            fn_expr.params,
            fn_expr.return_type,
            fn_expr.type_params,
            doc,
            .{},
        );
    }

    /// true if candidate's return type eventually resolves to target's sig
    /// , so like adopting it would make one sig reference the other in a loop
    fn fnReturnCycles(candidate: *const FnSig, target: *const FnSig, depth: usize) bool {
        if (depth > 64) return true;
        if (candidate == target) return true;

        return switch (candidate.return_type.tag) {
            .function => |f| fnReturnCycles(f, target, depth + 1),
            else => false,
        };
    }

    fn analyzeFnBody(self: *SemanticChecker, fn_expr: anytype, sig: *FnSig) !types_mod.TypeInfo {
        try self.return_types.append(self.alloc, sig.return_type);
        defer _ = self.return_types.pop();

        self.fn_nesting += 1;
        defer self.fn_nesting -= 1;

        try self.pushScope(.func);
        defer self.popScope();
        for (fn_expr.params, sig.params) |param, param_type| {
            // the func scope is fresh, so anything already in it is a repeated
            // param; the second would just overwrite the first's slot
            if (!ast.isDiscardName(param.name) and
                self.scopes.items[self.scopes.items.len - 1].values.contains(param.name))
            {
                const msg = try self.alloc.print("duplicate parameter `{s}`", .{param.name});
                if (self.first_code == null) self.first_code = "duplicate-parameter";
                try self.appendError(msg, param.name_span, "duplicate parameter");
            }
            try self.warnShadow(param.name, param.name_span);
            try self.declare(param.name, param_type, null, .param);
        }
        // defaults can reference sibling params, so they analyze here where
        // params are declared; also annotates them for the compiler's default checks
        for (fn_expr.params) |param| {
            if (param.default_value) |d| _ = try self.analyzeNode(d);
        }
        const body_type = try self.analyzeNode(fn_expr.body);
        if (sig.return_type.tag == .any and body_type.tag != .any) {
            // a fn whose inferred return type is itself
            // (or cycles back thru other inferred fns)
            // would make the sig self-referential
            // and diverge every later clone/intern
            //
            // leave its return type open
            const cycles = switch (body_type.tag) {
                .function => |f| SemanticChecker.fnReturnCycles(f, sig, 0),
                else => false,
            };
            if (!cycles) sig.return_type = body_type;
        }
        // validate explicit return type against inferred body type
        if (sig.return_type.tag != .any and body_type.tag != .any and !types_mod.canCoerce(body_type, sig.return_type)) {
            try self.appendReturnMismatch(fn_expr.body.span, sig.return_type, body_type);
        }
        return .{ .tag = .{ .function = sig } };
    }

    fn pushGraphScope(self: *SemanticChecker, kind: scope_graph.ScopeKind) !void {
        if (self.graph) |g| {
            const no_span = ast.Span{ .start = 0, .end = 0, .line = 0, .column = 0 };
            self.graph_scope = try g.childScope(self.graph_scope, kind, no_span);
        }
    }

    fn popGraphScope(self: *SemanticChecker) void {
        if (self.graph) |g| {
            self.graph_scope = g.scopes.items[self.graph_scope].parent orelse self.graph_scope;
        }
    }

    fn analyzeNode(self: *SemanticChecker, node: *const ast.Node) anyerror!types_mod.TypeInfo {
        const t: types_mod.TypeInfo = switch (node.expr) {
            .binding => |b| try self.analyzeBinding(b, null, node.span),
            .decl => |d| try self.analyzeDecl(d, node.span),
            .type_alias => |alias| try self.analyzeTypeAlias(alias, null, node.span),
            .fn_expr => |fn_expr| try self.analyzeFnExpr(fn_expr, node.span),
            .block => |exprs| blk: {
                if (node.synthetic_block) {
                    try self.pushGraphScope(.transparent);
                    defer self.popGraphScope();
                    var last: types_mod.TypeInfo = .{ .tag = .any };
                    for (exprs) |expr| {
                        last = try self.analyzeNode(expr);
                    }
                    break :blk last;
                }
                break :blk try self.analyzeBlock(exprs, node.span);
            },
            .assign_expr => |assign| try self.analyzeAssign(assign, node.span),
            .compound_assign => |assign| try self.analyzeCompound(assign.target, assign.op, assign.value, node.span),
            .return_expr => |val| try self.analyzeReturn(val, node.span),
            .call => |call| try self.analyzeCall(call, node.span),
            .if_expr => |v| try self.analyzeIf(v, node.span),
            .unless_expr => |v| try self.analyzeUnless(v, node.span),
            .ident => |name| try self.analyzeIdent(name, node.span),
            .unary => |u| blk: {
                _ = try self.analyzeNode(u.expr);
                break :blk types_mod.inferExprType(self.check(), node);
            },
            .binary => |b| blk: {
                const l = try self.analyzeNode(b.left);
                const r = try self.analyzeNode(b.right);
                try self.checkBinaryOperands(b.op, l, r, node.span);
                break :blk types_mod.inferExprType(self.check(), node);
            },
            .and_expr => |v| blk: {
                _ = try self.analyzeNode(v.left);
                _ = try self.analyzeNode(v.right);
                break :blk types_mod.inferExprType(self.check(), node);
            },
            .or_expr => |v| blk: {
                _ = try self.analyzeNode(v.left);
                _ = try self.analyzeNode(v.right);
                break :blk types_mod.inferExprType(self.check(), node);
            },
            .try_expr => |inner| blk: {
                const inner_type = try self.analyzeNode(inner);
                if (inner_type.tag != .any and !types_mod.isResultType(inner_type)) {
                    try self.appendError(
                        try self.alloc.print("try expects :ok/:err tagged result, got {s}", .{try type_syntax.formatTypeOpts(self.alloc, inner_type, .{})}),
                        inner.span,
                        "not a result type",
                    );
                }
                break :blk types_mod.inferExprType(self.check(), node);
            },
            .orelse_expr => |v| blk: {
                _ = try self.analyzeNode(v.left);
                _ = try self.analyzeNode(v.right);
                break :blk types_mod.inferExprType(self.check(), node);
            },
            .field => |f| blk: {
                _ = try self.analyzeNode(f.object);
                try self.checkKnownField(f.object, f.name, node.span);
                break :blk types_mod.inferExprType(self.check(), node);
            },
            .index => |idx| blk: {
                _ = try self.analyzeNode(idx.object);
                _ = try self.analyzeNode(idx.key);
                // `t[:a]` / `t["a"]` with a static key check like `t.a`
                const static_key: ?[]const u8 = switch (idx.key.expr) {
                    .atom => |name| ast.atomName(name),
                    .string => |s| s,
                    else => null,
                };
                if (static_key) |key| try self.checkKnownField(idx.object, key, node.span);
                break :blk types_mod.inferExprType(self.check(), node);
            },
            .table => |entries| blk: {
                for (entries) |entry| {
                    if (entry.key) |key| {
                        if (entry.computed or (key.expr != .ident and key.expr != .atom)) {
                            _ = try self.analyzeNode(key);
                        }
                    }
                    _ = try self.analyzeNode(entry.value);
                }
                break :blk types_mod.inferExprType(self.check(), node);
            },
            .range_literal => |v| blk: {
                _ = try self.analyzeNode(v.start);
                _ = try self.analyzeNode(v.end);
                break :blk types_mod.inferExprType(self.check(), node);
            },
            .slice_literal => |v| blk: {
                if (v.start) |s| _ = try self.analyzeNode(s);
                if (v.step) |s| _ = try self.analyzeNode(s);
                if (v.end) |e| _ = try self.analyzeNode(e);
                break :blk types_mod.inferExprType(self.check(), node);
            },
            .comp_block => |v| blk: {
                const t = try self.analyzeNode(v.expr);
                break :blk t;
            },
            .break_expr => |b| blk: {
                if (b.value) |v| _ = try self.analyzeNode(v);
                break :blk types_mod.inferExprType(self.check(), node);
            },
            .continue_expr => |c| blk: {
                if (c.value) |v| _ = try self.analyzeNode(v);
                break :blk types_mod.inferExprType(self.check(), node);
            },
            .labeled_block => |lb| blk: {
                _ = try self.analyzeNode(lb.body);
                break :blk types_mod.inferExprType(self.check(), node);
            },
            .for_loop => |v| blk: {
                const iter_type = try self.analyzeNode(v.iter);
                try self.pushScope(.block);
                const param_type: types_mod.TypeInfo = if (v.iter.expr == .range_literal)
                    .{ .tag = .number }
                else if (iter_type.tag == .string)
                    .{ .tag = .string }
                else
                    .{ .tag = .any };
                for (v.params) |param| {
                    try self.warnShadow(param.name, param.name_span);
                    try self.declare(param.name, param_type, null, .param);
                }
                const body_type = try self.analyzeNode(v.body);
                self.popScope();
                break :blk body_type;
            },
            .match_expr => |v| blk: {
                const subject_type = try self.analyzeNode(v.subject);
                var unified: types_mod.TypeInfo = .{ .tag = .never };

                // guardless prior covers + matchers, for dead-arm detection
                var covered = std.ArrayList(types_mod.MatchCover).initCapacity(self.alloc, 8) catch break :blk unified;
                defer covered.deinit(self.alloc);
                var prior = std.ArrayList(ast.MatchMatcher).initCapacity(self.alloc, 8) catch break :blk unified;
                defer prior.deinit(self.alloc);

                for (v.arms) |arm| {
                    try self.pushScope(.block);
                    for (arm.matchers) |matcher| {
                        if (matcher == .expr) {
                            _ = try self.declarePatternNames(matcher.expr);
                            try self.narrowPatternNames(matcher.expr, subject_type);
                        }
                    }
                    if (arm.guard) |g| _ = try self.analyzeNode(g);
                    const arm_type = try self.analyzeNode(arm.then);
                    self.popScope();
                    unified = types_mod.unifyBranchType(unified, arm_type);

                    var arm_span = node.span;
                    for (arm.matchers) |matcher| {
                        if (matcher == .expr) {
                            arm_span = matcher.expr.span;
                            break;
                        }
                    }

                    const arm_covers = try types_mod.buildArmCovers(self.aliasScope(), arm);
                    defer self.alloc.free(arm_covers);

                    // degenerate subject, every arm is trivially dead; do notih
                    if (subject_type.tag != .never and arm_covers.len > 0) {
                        var overlaps = false;
                        for (arm_covers) |c| {
                            if (types_mod.matchOverlaps(subject_type, c)) {
                                overlaps = true;
                                break;
                            }
                        }
                        if (!overlaps) {
                            const subject_str = try type_syntax.formatTypeOpts(self.alloc, subject_type, .{});

                            try self.appendWarn(
                                try self.alloc.print("match pattern never matches {s}", .{subject_str}),
                                arm_span,
                                "never matches",
                                "impossible-match-arm",
                            );
                        } else {
                            var dead = arm.matchers.len > 0;
                            for (arm.matchers) |m| {
                                if (!switch (m) {
                                    .wildcard => types_mod.matchCoversAll(subject_type, covered.items),
                                    .expr => |e| sub: {
                                        if (e.expr == .ident)
                                            break :sub types_mod.matchCoversAll(subject_type, covered.items);

                                        for (prior.items) |p| {
                                            const sub = switch (p) {
                                                .wildcard => true,
                                                .expr => |pe| patternSubsumes(pe, e),
                                            };
                                            if (sub) break :sub true;
                                            // wow we have a lot of nesting... 11 levels........
                                            // but what can i even do
                                        }
                                        if (e.expr == .ascribed) {
                                            const ti = types_mod.evalTypeExpr(self.aliasScope(), e.expr.ascribed.type_name) catch break :sub false;
                                            break :sub types_mod.matchCoversAll(ti, covered.items);
                                        }
                                        if (patternLitType(e)) |lt| break :sub types_mod.matchCoversAll(lt, covered.items);
                                        break :sub false;
                                    },
                                }) {
                                    dead = false;
                                    break;
                                }
                            }
                            if (dead) try self.appendWarn("unreachable match arm", arm_span, "unreachable", "unreachable-match-arm");
                        }
                    }
                    // guarded arms never contribute coverage, a guard can fail
                    if (arm.guard == null) {
                        try covered.appendSlice(self.alloc, arm_covers);
                        try prior.appendSlice(self.alloc, arm.matchers);
                    }
                }
                // miss falls through to nil at runtime
                // so a non-exhaustive match always carries :nil in its type
                if (!types_mod.matchCoversAll(subject_type, covered.items)) {
                    unified = types_mod.withNilMiss(self.alloc, unified);
                    var tags = std.ArrayList([]const u8).initCapacity(self.alloc, 4) catch break :blk unified;

                    defer tags.deinit(self.alloc);
                    try types_mod.uncoveredTags(self.alloc, subject_type, covered.items, &tags);

                    const msg = if (tags.items.len > 0) blk_msg: {
                        const listed = try std.mem.join(self.alloc, ", :", tags.items);
                        defer self.alloc.free(listed);
                        break :blk_msg try self.alloc.print(
                            "match is not exhaustive: :{s} not covered, miss yields :nil",
                            .{listed},
                        );
                    } else blk_msg: {
                        const subject_str = try type_syntax.formatTypeOpts(self.alloc, subject_type, .{});
                        break :blk_msg try self.alloc.print(
                            "match is not exhaustive for {s}, miss yields :nil",
                            .{subject_str},
                        );
                    };
                    try self.appendWarn(msg, node.span, "non-exhaustive match", "non-exhaustive-match");
                    // suggest the actual arms:
                    // a miss evaluates to nil already,
                    // one per uncovered tag when nameable
                    // , plain `_` otherwise
                    if (v.arms.len > 0) {
                        const last = v.arms[v.arms.len - 1];
                        const ins = @min(last.then.span.end, self.source.len);
                        var anchor: ?usize = null;
                        for (last.matchers) |matcher| {
                            if (matcher == .expr) {
                                anchor = matcher.expr.span.start;
                                break;
                            }
                        }

                        const anchor_off = @min(anchor orelse last.then.span.start, self.source.len);
                        var line_start = anchor_off;
                        while (line_start > 0 and self.source[line_start - 1] != '\n') : (line_start -= 1) {}
                        var indent_end = line_start;

                        while //
                        (indent_end < anchor_off and (self.source[indent_end] == ' ' //
                        or self.source[indent_end] == '\t')) //
                        : (indent_end += 1) {}

                        var sug_line: u32 = 1;
                        var sug_col: u32 = 1;
                        var idx: usize = 0;

                        while (idx < ins and idx < self.source.len) : (idx += 1) {
                            if (self.source[idx] == '\n') {
                                sug_line += 1;
                                sug_col = 1;
                            } else {
                                sug_col += 1;
                            }
                        }

                        var patterns = std.ArrayList([]const u8).initCapacity(self.alloc, tags.items.len) catch break :blk unified;
                        defer patterns.deinit(self.alloc);

                        for (tags.items) |tag| {
                            if (try types_mod.suggestArmPattern(self.alloc, subject_type, tag)) |pat| {
                                try patterns.append(self.alloc, pat);
                            }
                        }

                        if (patterns.items.len == 0) {
                            // tables suggest shape, so fix mirrors subject
                            const fallback = (try types_mod.suggestTablePattern(self.alloc, subject_type)) orelse "_";

                            try patterns.append(self.alloc, fallback);
                        }

                        var replacement = std.ArrayList(u8).initCapacity(self.alloc, 32) catch break :blk unified;
                        defer replacement.deinit(self.alloc);

                        const indent = self.source[line_start..indent_end];

                        for (patterns.items) |pat| {
                            try replacement.appendSlice(self.alloc, "\n");
                            try replacement.appendSlice(self.alloc, indent);
                            try replacement.appendSlice(self.alloc, "| ");
                            try replacement.appendSlice(self.alloc, pat);
                            try replacement.appendSlice(self.alloc, " => :nil");
                        }
                        try self.warn_parts.append(self.alloc, .{ .suggestion = .{
                            .span = .{ .start = ins, .end = ins, .line = sug_line, .column = sug_col },
                            .message = "add an explicit nil arm",
                            .replacement = try replacement.toOwnedSlice(self.alloc),
                        } });
                    }
                }
                break :blk unified;
            },
            .loop_expr => |v| blk: {
                try self.pushScope(.block);
                _ = try self.analyzeNode(v.body);
                self.popScope();
                break :blk types_mod.inferExprType(self.check(), node);
            },
            .while_loop => |v| blk: {
                const pred_type = try self.analyzeNode(v.predicate);
                if (!types_mod.canCoerce(pred_type, .{ .tag = .bool })) {
                    try self.appendError(
                        try self.alloc.print("while predicate must be boolean, got {s}", .{try type_syntax.formatTypeOpts(self.alloc, pred_type, .{})}),
                        v.predicate.span,
                        "expected bool",
                    );
                }
                try self.pushScope(.block);
                _ = try self.analyzeNode(v.body);
                self.popScope();
                break :blk types_mod.inferExprType(self.check(), node);
            },
            .import_stmt => |stmt| blk: {
                // the dep interface becomes the binding's record type, so
                // member access, calls, and completions flow through the
                // regular table paths; unresolvable deps stay untyped
                if (self.resolveDepAst(stmt.path)) |dep| {
                    const items: []const *ast.Node = switch (dep.expr) {
                        .block => |exprs| exprs,
                        else => &[_]*ast.Node{@constCast(dep)},
                    };

                    if (import_types.moduleInterface(self.alloc, items)) |iface| {
                        var aliases = std.StringHashMap(types_mod.TypeInfo).init(self.alloc);
                        for (iface.aliases) |a| try aliases.put(a.name, a.info);
                        try self.import_aliases.put(stmt.name, aliases);

                        if (iface.record) |record| {
                            try self.declare(stmt.name, record, null, .import);
                            break :blk record;
                        }
                    } else |_| {}
                }
                try self.declare(stmt.name, .{ .tag = .any }, null, .import);
                break :blk .{ .tag = .any };
            },
            .number, .string, .multiline_string, .atom, .nil, .table_pattern, .quasiquote, .test_block, .test_suite, .proc_macro => types_mod.inferExprType(self.check(), node),
            .ascribed => blk: {
                try self.appendError(
                    "type ascriptions only go in match patterns",
                    node.span,
                    "not a value",
                );

                break :blk .{ .tag = .any };
            },
        };

        // every node leaves with an annotation; the compiler reads these
        // instead of re-inferring, so narrowing and generics edges live here now
        if (self.annotations) |ann| {
            const tv = self.annotatedType(node, t);
            if (ann.table.intern(tv)) |id| {
                ann.map.put(node, id) catch {};
            } else |_| {}
        }

        return t;
    }

    /// ident annotations go rite over flow-tracked fields onto the declared shape
    ///   mirrors inferFieldType,,, literal fields win, tracked fill gaps
    ///   transient in checker alloc, intern clones; never freed, arena-owned
    fn annotatedType(self: *SemanticChecker, node: *const ast.Node, declared: types_mod.TypeInfo) types_mod.TypeInfo {
        if (node.expr != .ident) return declared;
        if (declared.tag != .table) return declared;
        const tracked = self.table_field_map.get(node.expr.ident) orelse return declared;
        if (tracked.count() == 0) return declared;

        const base = declared.tag.table.fields orelse &.{};
        var extra: usize = 0;
        var it = tracked.iterator();
        while (it.next()) |e| {
            var found = false;
            for (base) |f| {
                if (std.mem.eql(u8, f.name, e.key_ptr.*)) {
                    found = true;
                    break;
                }
            }
            if (!found) extra += 1;
        }
        if (extra == 0) return declared;

        var fields = std.ArrayList(types_mod.RecordField).initCapacity(self.alloc, base.len + extra) catch return declared;
        for (base) |f| fields.appendAssumeCapacity(f);
        var it2 = tracked.iterator();
        while (it2.next()) |e| {
            var found = false;
            for (base) |f| {
                if (std.mem.eql(u8, f.name, e.key_ptr.*)) {
                    found = true;
                    break;
                }
            }
            if (!found) fields.appendAssumeCapacity(.{
                .name = e.key_ptr.*,
                .field_type = e.value_ptr.*,
            });
        }

        return .{ .tag = .{ .table = .{
            .key = declared.tag.table.key,
            .value = declared.tag.table.value,
            .fields = fields.items,
        } } };
    }

    fn analyzeIdent(self: *SemanticChecker, name: []const u8, span: ast.Span) !types_mod.TypeInfo {
        // baselib fns are only declared into scope when the checker runs with
        // vm globals (repl); without them, fall back to the spec registry so
        // bare calls like `print(x)` don't read as unknown
        if (self.lookup(name) == null and !ast.isDiscardName(name) and
            !(self.fn_nesting > 0 and self.predeclared.contains(name)) and revo.baselib.specs.findFn(name) == null)
        {
            const msg = try self.alloc.print("name `{s}` is not defined", .{name});
            if (self.first_code == null) self.first_code = "unknown-name";
            try self.appendError(msg, span, "unknown name");
        }
        return self.inferIdentType(name);
    }

    fn analyzeBlock(self: *SemanticChecker, exprs: []const *ast.Node, span: ast.Span) !types_mod.TypeInfo {
        _ = span;
        try self.pushScope(.block);
        defer self.popScope();
        var last: types_mod.TypeInfo = .{ .tag = .any };
        for (exprs) |expr| {
            last = try self.analyzeNode(expr);
        }
        return last;
    }

    fn analyzeDecl(self: *SemanticChecker, decl: ast.DeclNode, span: ast.Span) !types_mod.TypeInfo {
        _ = span;
        if (decl.kind == .declare_decl and decl.inner.expr == .type_alias) {
            return try self.analyzeDeclare(decl.inner.expr.type_alias, decl.doc);
        }
        return switch (decl.inner.expr) {
            .binding => |b| try self.analyzeBinding(b, decl.doc, decl.inner.span),
            .type_alias => |alias| try self.analyzeTypeAlias(alias, decl.doc, decl.inner.span),
            else => try self.analyzeNode(decl.inner),
        };
    }

    fn analyzeDeclare(self: *SemanticChecker, alias: anytype, doc: ?[]const u8) !types_mod.TypeInfo {
        // init pushes the module scope, the file body is the next scope in
        if (self.scopes.items.len != 2) {
            try self.appendError("declare must be a top-level statement", alias.type_expr.span, "declare scope");
            return .{ .tag = .any };
        }
        if (self.lookup(alias.name) != null) {
            const msg = try self.alloc.print("duplicate declaration of `{s}`", .{alias.name});
            try self.appendError(msg, alias.type_expr.span, "duplicate declare");
            return .{ .tag = .any };
        }
        const t = self.evalCheckedTypeExpr(alias.type_expr) catch types_mod.TypeInfo{ .tag = .any };
        try self.declare(alias.name, t, doc orelse alias.doc, .type_alias);
        // also usable in type positions: `const x: MAX_ITEMS = 5`
        try self.type_aliases.put(alias.name, .{ .info = t, .doc = doc orelse alias.doc });
        return .{ .tag = .any };
    }

    fn analyzeTypeAlias(self: *SemanticChecker, alias: anytype, doc: ?[]const u8, span: ast.Span) !types_mod.TypeInfo {
        _ = span;
        const t = self.evalCheckedTypeExpr(alias.type_expr) catch types_mod.TypeInfo{ .tag = .any };
        try self.type_aliases.put(ast.bareName(alias), .{ .info = t, .doc = doc orelse alias.doc });
        return .{ .tag = .any };
    }

    fn analyzeFnExpr(self: *SemanticChecker, fn_expr: anytype, span: ast.Span) !types_mod.TypeInfo {
        _ = span;
        const combined = try types_mod.combinedTypeParams(self.alloc, fn_expr.type_params, fn_expr.params);
        const saved = self.current_type_params;
        self.current_type_params = combined;
        defer self.current_type_params = saved;
        const sig = try self.makeFnSig(fn_expr);
        return self.analyzeFnBody(fn_expr, sig);
    }

    fn analyzeBinding(self: *SemanticChecker, binding: ast.Binding, decl_doc: ?[]const u8, _: ast.Span) !types_mod.TypeInfo {
        if (binding.target.expr != .ident) {
            if (binding.target.expr == .table_pattern) {
                const value_type = try self.analyzeNode(binding.value);
                _ = try self.declarePatternNames(binding.target);
                try self.checkPatternAscriptions(binding.target, value_type);

                return .{ .tag = .any };
            }
            return .{ .tag = .any };
        }
        const name = binding.target.expr.ident;
        try self.warnShadow(name, binding.target.span);
        // docs ride on the decl wrapper; ident and field values inherit the source's doc
        const doc: ?[]const u8 = decl_doc orelse binding.doc orelse blk: {
            if (binding.value.expr == .ident) {
                if (self.lookupEntry(binding.value.expr.ident)) |src| break :blk src.doc;
            } else if (binding.value.expr == .field) {
                const ft = types_mod.inferExprType(self.check(), binding.value);
                if (ft.tag == .function) break :blk ft.tag.function.doc;
                break :blk ft.doc;
            }
            break :blk null;
        };
        if (binding.value.expr == .fn_expr) {
            const combined = try types_mod.combinedTypeParams(self.alloc, binding.value.expr.fn_expr.type_params, binding.value.expr.fn_expr.params);
            const saved = self.current_type_params;
            self.current_type_params = combined;
            defer self.current_type_params = saved;
            const sig = try self.makeFnSig(binding.value.expr.fn_expr);
            const fn_type: types_mod.TypeInfo = .{ .tag = .{ .function = sig } };
            if (binding.type_name) |type_expr| {
                try self.typed_names.put(name, {});
                const expected = try self.evalCheckedTypeExpr(type_expr);
                if (!types_mod.canCoerce(fn_type, expected)) {
                    try self.appendTypeMismatch(
                        binding.target.span,
                        name,
                        expected,
                        fn_type,
                    );
                }
                try self.declare(name, expected, doc, .binding);
            } else {
                try self.declare(name, fn_type, doc, .binding);
            }
            _ = try self.analyzeFnBody(binding.value.expr.fn_expr, sig);
            if (std.mem.endsWith(u8, name, "?") and sig.return_type.tag != .bool) {
                const msg = try self.alloc.print(
                    "function ending with ? must return bool, got {s}",
                    .{try type_syntax.formatTypeOpts(self.alloc, sig.return_type, .{})},
                );
                if (self.first_code == null) self.first_code = "predicate-return-type";
                try self.appendError(msg, binding.target.span, "expected bool");
            }
            if (self.type_map) |tm| {
                _ = tm.remove(name);
                try tm.put(try self.alloc.dupe(u8, name), fn_type);
            }
            return fn_type;
        }

        // table literal -- analyze entries and record field types for method shadowing
        if (binding.value.expr == .table) {
            var fields = std.StringHashMap(types_mod.TypeInfo).init(self.alloc);
            var implicit_idx: u32 = 0;
            for (binding.value.expr.table) |entry| {
                // `fn name(self) ...` - a method definition, keyless entry
                if (entry.key == null and entry.value.expr == .decl and
                    entry.value.expr.decl.inner.expr == .binding)
                {
                    const mb = entry.value.expr.decl.inner.expr.binding;
                    if (mb.target.expr == .ident and mb.value.expr == .fn_expr) {
                        const ft = try self.analyzeNode(entry.value);
                        try fields.put(mb.target.expr.ident, ft);
                        continue;
                    }
                }
                if (entry.key) |key| {
                    if (entry.computed or (key.expr != .ident and key.expr != .atom)) {
                        _ = try self.analyzeNode(key);
                    }
                    const field_type = try self.analyzeNode(entry.value);
                    if (key.expr == .ident) try fields.put(key.expr.ident, field_type);
                } else {
                    const ft = try self.analyzeNode(entry.value);
                    const idx_name = try self.alloc.print("{d}", .{implicit_idx});
                    implicit_idx += 1;
                    try fields.put(idx_name, ft);
                }
            }
            try self.table_field_map.put(name, fields);
            const table_type = types_mod.inferExprType(self.check(), binding.value);
            if (binding.type_name) |type_expr| {
                try self.typed_names.put(name, {});
                const expected = try self.evalCheckedTypeExpr(type_expr);
                if (!types_mod.canCoerce(table_type, expected)) {
                    try self.appendTypeMismatch(
                        binding.target.span,
                        name,
                        expected,
                        table_type,
                    );
                }
                try self.declare(name, expected, doc, .binding);
                return expected;
            }
            try self.declare(name, table_type, doc, .binding);
            return table_type;
        }
        // propagate table fields through variable references
        if (binding.value.expr == .ident and !ast.isDiscardName(binding.value.expr.ident)) {
            if (self.table_field_map.get(binding.value.expr.ident)) |src| {
                const fields = try src.clone();
                try self.table_field_map.put(name, fields);
            }
        }

        const value_type = try self.analyzeNode(binding.value);
        if (binding.type_name) |type_expr| {
            try self.typed_names.put(name, {});
            const expected = try self.evalCheckedTypeExpr(type_expr);
            if (!types_mod.canCoerce(value_type, expected)) {
                try self.appendTypeMismatch(
                    binding.target.span,
                    name,
                    expected,
                    value_type,
                );
            }
            try self.declare(name, expected, doc, .binding);
            return expected;
        }

        try self.declare(name, value_type, doc, .binding);
        return value_type;
    }

    fn declarePatternNames(self: *SemanticChecker, pattern: *const ast.Node) !types_mod.TypeInfo {
        // seen is per-pattern, NOT per scope
        // : match arms deliberately bind the same name from several matchers
        // , a pattern binding it twice is a typo
        var seen = std.StringHashMap(void).init(self.alloc);
        defer seen.deinit();
        return self.declarePatternNamesSeen(pattern, &seen);
    }

    fn declarePatternNamesSeen(
        self: *SemanticChecker,
        pattern: *const ast.Node,
        seen: *std.StringHashMap(void),
    ) !types_mod.TypeInfo {
        switch (pattern.expr) {
            .ident => |name| {
                if (!ast.isDiscardName(name)) {
                    if (seen.contains(name)) {
                        const msg = try self.alloc.print("duplicate name `{s}` in pattern", .{name});
                        if (self.first_code == null) self.first_code = "duplicate-pattern-name";
                        try self.appendError(msg, pattern.span, "duplicate name");
                        return .{ .tag = .any };
                    }
                    try seen.put(name, {});
                    try self.declare(name, .{ .tag = .any }, null, .binding);
                }
            },
            .table_pattern => |items| {
                for (items) |item| {
                    _ = try self.declarePatternNamesSeen(item, seen);
                }
            },
            .ascribed => |a| {
                const inner_ti = types_mod.evalTypeExpr(self.aliasScope(), a.type_name) catch
                    types_mod.TypeInfo{ .tag = .any };

                if (a.expr.expr == .ident and !ast.isDiscardName(a.expr.expr.ident)) {
                    if (!seen.contains(a.expr.expr.ident)) {
                        try seen.put(a.expr.expr.ident, {});
                        try self.declare(a.expr.expr.ident, inner_ti, null, .binding);
                    }
                } else {
                    _ = try self.declarePatternNamesSeen(a.expr, seen);
                }
            },
            else => {},
        }

        return .{ .tag = .any };
    }

    /// binding patterns juty trust `: T` ascriptions at declaration
    /// ; this pass checks them against known element types so
    ///   `let {x: number} = {:ok}` fails instead of binding :ok as number
    ///
    /// unknown positions
    ///     (any, unions, dynamic tables)
    /// pass like nothinh happeneg since `canCoerce` treats `any` as top on both sides
    fn checkPatternAscriptions(self: *SemanticChecker, pattern: *const ast.Node, context: types_mod.TypeInfo) !void {
        const items = switch (pattern.expr) {
            .table_pattern => |items| items,
            else => return,
        };

        for (items, 0..) |item, i| {
            if (item.expr != .ascribed and item.expr != .table_pattern) continue;
            const elem = patternElemType(self, context, i) orelse continue;

            if (item.expr == .ascribed) {
                const a = item.expr.ascribed;
                const expected = types_mod.evalTypeExpr(self.aliasScope(), a.type_name) catch types_mod.TypeInfo{ .tag = .any };

                if (!types_mod.canCoerce(elem, expected)) {
                    const name = if (a.expr.expr == .ident) a.expr.expr.ident else "?";
                    try self.appendTypeMismatch(item.span, name, expected, elem);
                }

                try self.checkPatternAscriptions(a.expr, elem);
            } else {
                try self.checkPatternAscriptions(item, elem);
            }
        }
    }

    /// an `{a, b} = v` target already has a declared type from an bind
    ///   , so hold it to the element type
    ///
    /// only fires when the element type is actually known
    ///   , which needs a structurally annotated source
    fn checkPatternTargets(self: *SemanticChecker, pattern: *const ast.Node, context: types_mod.TypeInfo) !void {
        const items = switch (pattern.expr) {
            .table_pattern => |items| items,
            else => return,
        };

        for (items, 0..) |item, i| {
            const name = switch (item.expr) {
                .ident => |n| n,
                .ascribed => |a| if (a.expr.expr == .ident) a.expr.expr.ident else continue,
                .table_pattern => {
                    const elem = patternElemType(self, context, i) orelse continue;
                    try self.checkPatternTargets(item, elem);
                    continue;
                },
                else => continue,
            };
            if (ast.isDiscardName(name)) continue;
            if (!self.typed_names.contains(name)) continue;

            const expected = self.lookup(name) orelse continue;
            if (expected.tag == .any) continue;
            const elem = patternElemType(self, context, i) orelse continue;

            if (!types_mod.canCoerce(elem, expected)) {
                try self.appendTypeMismatch(item.span, name, expected, elem);
            }
        }
    }

    /// positional element type of a destructured value, or null when unknown.
    fn patternElemType(self: *SemanticChecker, context: types_mod.TypeInfo, i: usize) ?types_mod.TypeInfo {
        switch (context.tag) {
            .table => |tbl| {
                const fields = tbl.fields orelse return null;
                const key = self.alloc.print("{d}", .{i}) catch return null;
                if (types_mod.findField(fields, key)) |f| return f.field_type;
                return null;
            },

            else => return null,
        }
    }

    /// narrow match pattern bindings when the subject type is a tagged union
    /// `{:ok, v}` patterns against `{:ok, int} | {:err, string}`
    /// bind `v` as `.int`, not `.any`
    fn narrowPatternNames(self: *SemanticChecker, pattern: *const ast.Node, subject_type: types_mod.TypeInfo) !void {
        // ascriptions apply regardless of subject type
        //   ; and win over union narrowing
        if (pattern.expr == .ascribed) {
            const a = pattern.expr.ascribed;
            const inner_ti = types_mod.evalTypeExpr(self.aliasScope(), a.type_name) catch types_mod.TypeInfo{ .tag = .any };

            if (a.expr.expr == .ident and !ast.isDiscardName(a.expr.expr.ident)) {
                try self.declare(a.expr.expr.ident, inner_ti, null, .binding);

                return;
            }

            return try self.narrowPatternNames(a.expr, subject_type);
        }

        if (subject_type.tag == .any) return;

        const items = switch (pattern.expr) {
            .table_pattern => |items| items,
            else => return,
        };
        if (items.len == 0) return;
        const first = items[0];
        const tag = if (first.expr == .atom) first.expr.atom else return;
        const variants = switch (subject_type.tag) {
            .@"union" => |us| us,
            else => return,
        };
        for (variants) |variant| {
            if (!types_mod.unionVariantTagEql(variant, tag)) continue;
            var payload = std.ArrayList(types_mod.TypeInfo).initCapacity(self.alloc, 4) catch return;
            defer payload.deinit(self.alloc);
            try types_mod.appendUnionVariantPayload(self.alloc, variant, &payload);
            for (items[1..], 0..) |item, i| {
                if (item.expr == .ident and !ast.isDiscardName(item.expr.ident)) {
                    const narrowed = if (i < payload.items.len) payload.items[i] else types_mod.TypeInfo{ .tag = .any };
                    try self.declare(item.expr.ident, narrowed, null, .binding);
                }
            }
            return;
        }
    }

    fn analyzeAssign(
        self: *SemanticChecker,
        assign: anytype,
        span: ast.Span,
    ) !types_mod.TypeInfo {
        _ = span;
        const value_type = try self.analyzeNode(assign.value);
        try self.trackAssignTarget(assign.target, value_type, assign.value.span);

        return .{ .tag = .any };
    }

    fn analyzeCompound(
        self: *SemanticChecker,
        target: *const ast.Node,
        op: ast.BinOp,
        value: *const ast.Node,
        span: ast.Span,
    ) !types_mod.TypeInfo {
        const lhs = switch (target.expr) {
            .ident, .field, .index => try self.analyzeNode(target),
            else => blk: {
                _ = try self.analyzeNode(value);
                const target_kind = @tagName(target.expr);
                try self.appendError(
                    try self.alloc.print("cannot assign to {s}", .{target_kind}),
                    target.span,
                    "invalid assignment target",
                );
                break :blk types_mod.TypeInfo{ .tag = .any };
            },
        };

        if (target.expr != .ident and target.expr != .field and target.expr != .index) return .{ .tag = .any };
        const rhs = try self.analyzeNode(value);

        try self.checkBinaryOperands(op, lhs, rhs, span);
        const result = types_mod.inferBinaryOp(op, lhs, rhs);

        try self.trackAssignTarget(target, result, value.span);
        return .{ .tag = .any };
    }

    /// shared operand checks for value-level binary ops
    /// ; `.binary` and `.compound_assign` lower to
    ///     the same opcodes so they check the same
    fn checkBinaryOperands(
        self: *SemanticChecker,
        op: ast.BinOp,
        l: types_mod.TypeInfo,
        r: types_mod.TypeInfo,
        span: ast.Span,
    ) !void {
        switch (op) {
            .add, .sub, .div, .int_div, .mod, .pow => {
                if ((l.tag == .number and r.tag == .string) or (l.tag == .string and r.tag == .number)) {
                    try self.appendError(
                        try self.alloc.print("cannot {s} {s} and {s}", .{ @tagName(op), try type_syntax.formatTypeOpts(self.alloc, l, .{}), try type_syntax.formatTypeOpts(self.alloc, r, .{}) }),
                        span,
                        "invalid operands",
                    );
                }
            },
            .mul => {
                if (!isOptimisticOperand(l) and !isOptimisticOperand(r) and (l.tag != .number or r.tag != .number)) {
                    try self.appendError(
                        try self.alloc.print("cannot multiply {s} and {s}", .{ try type_syntax.formatTypeOpts(self.alloc, l, .{}), try type_syntax.formatTypeOpts(self.alloc, r, .{}) }),
                        span,
                        "invalid operands",
                    );
                }
            },
            .concat => {},
            .band, .bor, .bxor, .shl, .shr => {
                if (!isOptimisticOperand(l) and !isOptimisticOperand(r) and (l.tag != .number or r.tag != .number)) {
                    try self.appendError(
                        try self.alloc.print("cannot apply {s} to {s} and {s}", .{ @tagName(op), try type_syntax.formatTypeOpts(self.alloc, l, .{}), try type_syntax.formatTypeOpts(self.alloc, r, .{}) }),
                        span,
                        "invalid operands",
                    );
                }
            },
            .eq, .neq, .lt, .gt, .lte, .gte => {},
            .@"union" => unreachable,
        }
    }

    fn trackAssignTarget(self: *SemanticChecker, target: *const ast.Node, value_type: types_mod.TypeInfo, value_span: ast.Span) !void {
        switch (target.expr) {
            .ident => |name| {
                if (self.typed_names.contains(name)) {
                    if (self.lookup(name)) |expected| {
                        if (!types_mod.canCoerce(value_type, expected)) {
                            try self.appendTypeMismatch(
                                value_span,
                                name,
                                expected,
                                value_type,
                            );
                        }
                    }
                }
                // reassignment keeps the binding's doc
                const prev_doc: ?[]const u8 = if (self.lookupEntry(name)) |e| e.doc else null;
                try self.declare(name, value_type, prev_doc, .binding);
            },
            .field => |field| {
                const object_type = types_mod.inferExprType(self.check(), field.object);
                if (object_type.tag == .table and field.object.expr == .ident) {
                    if (self.table_field_map.getPtr(field.object.expr.ident)) |fields| {
                        try fields.put(field.name, value_type);
                    }
                    try self.markEscaped(field.object.expr.ident);
                }
            },
            .table_pattern => {
                try self.checkPatternTargets(target, value_type);
                try self.checkPatternAscriptions(target, value_type);
                _ = try self.declarePatternNames(target);
            },
            .index => |idx| {
                // static keys join the known fields so later reads see
                // them; numbers stay untracked (never field names)
                if (idx.object.expr == .ident) {
                    const key_name: ?[]const u8 = switch (idx.key.expr) {
                        .atom => |name| ast.atomName(name),
                        .string => |s| s,
                        else => null,
                    };
                    if (key_name) |key| {
                        if (self.table_field_map.getPtr(idx.object.expr.ident)) |fields| {
                            try fields.put(key, value_type);
                        }
                    }
                }

                const actual_type = try self.analyzeNode(idx.object);
                // dynamic keys hide unknown content: an ident table with a
                // fully known shape forgets its fields so later reads stay
                // sound; annotated bindings keep their contract.
                // mark first: redeclaring below shadows the name into the
                // current scope, which would defeat the outer-scope check
                if (idx.object.expr == .ident and actual_type.tag == .table and
                    !self.typed_names.contains(idx.object.expr.ident))
                {
                    try self.markEscaped(idx.object.expr.ident);
                    const static = switch (idx.key.expr) {
                        .atom, .string => true,
                        else => false,
                    };
                    if (!static and actual_type.tag.table.fields != null) {
                        var generic = actual_type;
                        generic.tag.table.fields = null;
                        const prev_doc = if (self.lookupEntry(idx.object.expr.ident)) |e| e.doc else null;
                        try self.declare(idx.object.expr.ident, generic, prev_doc, .binding);
                    }
                }
                if (!types_mod.canCoerce(types_mod.TABLE_GENERIC, actual_type)) {
                    const name_str = try type_syntax.formatTypeOpts(self.alloc, actual_type, .{});

                    try self.appendError(
                        try self.alloc.print("mutation is not allowed for {s}", .{name_str}),
                        idx.object.span,
                        "here",
                    );
                }
            },
            else => {
                const target_kind = @tagName(target.expr);
                try self.appendError(
                    try self.alloc.print("cannot assign to {s}", .{target_kind}),
                    target.span,
                    "invalid assignment target",
                );
            },
        }
    }

    fn analyzeReturn(self: *SemanticChecker, val: ?*ast.Node, span: ast.Span) !types_mod.TypeInfo {
        const expr = val orelse return .{ .tag = .any };
        const actual = try self.analyzeNode(expr);
        const expected = if (self.return_types.items.len != 0) self.return_types.items[self.return_types.items.len - 1] else types_mod.TypeInfo{ .tag = .any };
        if (expected.tag != .any and !types_mod.canCoerce(actual, expected)) {
            try self.appendReturnMismatch(span, expected, actual);
        }
        return .{ .tag = .any };
    }

    fn numberAccepts(expected: types_mod.TypeInfo, actual: types_mod.TypeInfo) bool {
        if (expected.tag == .number and actual.tag == .number) return true;
        return types_mod.canCoerce(actual, expected);
    }

    /// `any` and implicit `type_var` params are both optimistic
    /// : skip strict operand errors
    ///   , same as untyped code we had b4 generics
    fn isOptimisticOperand(t: types_mod.TypeInfo) bool {
        return t.tag == .any or t.tag == .type_var;
    }

    fn analyzeCall(self: *SemanticChecker, call: anytype, _: ast.Span) !types_mod.TypeInfo {
        // bare ident callees get the same unknown-name check as plain idents -
        // inferExprType would silently fall back to .any
        if (call.callee.expr == .ident) {
            // macro call sites: the arguments and callee name are raw syntax
            // for the macro, not real revo expressions,, just skip analysis entirely
            if (std.mem.endsWith(u8, call.callee.expr.ident, "!")) {
                return .{ .tag = .any };
            }
            _ = try self.analyzeIdent(call.callee.expr.ident, call.callee.span);
        }
        if (call.callee.expr == .field) {
            _ = try self.analyzeNode(call.callee.expr.field.object);
            // ~ dot-call callees read the field first (`t.f()`)
            // ~ colon-calls (`t:f()`) dispatch to methods
            // ~ `!` callees are macro calls, handled by expansion reporting instead
            // ~ a field that is also a baselib method (`t.len()`) dispatches
            //   at runtime, so only flag names that resolve to neither
            if (!call.implicit_self and !std.mem.endsWith(u8, call.callee.expr.field.name, "!")) {
                const f = call.callee.expr.field;
                const obj_type = types_mod.inferExprType(self.check(), f.object);
                // a dot-call matching a member of the object's module table
                // dispatches at runtime (`t.at(0)` finds `table.at`), so only
                // flag names that resolve to neither field nor module member
                const target: ?revo.baselib.host.ParamType = switch (obj_type.tag) {
                    .number => .number,
                    .string => .string,
                    .table => .table,
                    else => null,
                };
                const dispatches = if (target) |t| findModuleByNameAndTarget(f.name, t) != null else false;
                if (!dispatches) try self.checkKnownField(f.object, f.name, call.callee.span);
            }
        }
        const callee_type = types_mod.inferExprType(self.check(), call.callee);
        // typed function call validation
        if (callee_type.tag == .function) {
            const sig_ptr = callee_type.tag.function;
            if (sig_ptr.is_any_fn_sig) {
                for (call.args) |arg| _ = try self.analyzeNode(arg);
                return .{ .tag = .any };
            }
            const sig = sig_ptr.*;
            const name = switch (call.callee.expr) {
                .ident => |n| n,
                .field => |f| f.name,
                else => "call",
            };
            // method calls (implicit_self) prepend the object as arg 0 at runtime
            const self_offset: usize = if (call.implicit_self) 1 else 0;
            const total_args = call.args.len + self_offset;
            if (total_args < sig.required_count or (total_args > sig.params.len)) {
                const baselib_spec = find_spec: {
                    // same name can exist as both a global and a module
                    // member; match the call kind (`t:m()` prepends self,
                    // so only namespaced members pair with colon calls)
                    for (revo.baselib.specs.full_specs) |group| for (group) |*s| {
                        if (s.is_type) continue;
                        if (!std.mem.eql(u8, s.name, name)) continue;
                        const head = s.head;
                        if (call.implicit_self and head.kind == .namespaced) break :find_spec s;
                        if (!call.implicit_self and head.kind == .global) break :find_spec s;
                    };
                    break :find_spec revo.baselib.specs.findFn(name);
                };
                const is_variadic = if (baselib_spec) |sp| revo.baselib.specs.isVariadic(sp) else false;
                if (is_variadic and total_args >= sig.params.len -| 1) {
                    // variadic fns are fine with >= min
                } else if (total_args < sig.required_count) {
                    const label = try self.alloc.print("{d} missing args", .{
                        sig.required_count -| total_args,
                    });
                    try self.appendError(
                        try self.alloc.print("`{s}` wants at least {d} args, got {d}", .{
                            name, sig.required_count, total_args,
                        }),
                        call.callee.span,
                        label,
                    );
                } else if (total_args > sig.params.len) {
                    const label = try self.alloc.print("{d} extra args", .{
                        total_args -| sig.params.len,
                    });
                    try self.appendError(
                        try self.alloc.print("`{s}` wants {d} args, got {d}", .{
                            name, sig.params.len, total_args,
                        }),
                        call.callee.span,
                        label,
                    );
                }
            }
            // handle named arguments
            const has_named = for (call.args) |arg| {
                if (isNamedParam(arg) != null) break true;
            } else false;
            var named_seen = false;
            for (call.args, 0..) |arg, ai| {
                if (isNamedParam(arg) != null) {
                    named_seen = true;
                } else if (named_seen) {
                    try self.appendError(
                        try self.alloc.print("positional arg cannot follow named arg", .{}),
                        arg.span,
                        "here",
                    );
                }
                _ = ai;
            }
            for (call.args, 0..) |arg, i| {
                if (isNamedParam(arg)) |pn| {
                    for (call.args[i + 1 ..]) |later_arg| {
                        if (isNamedParam(later_arg)) |later_pn| {
                            if (std.mem.eql(u8, pn, later_pn)) {
                                try self.appendError(
                                    try self.alloc.print("duplicate named arg `{s}`", .{pn}),
                                    later_arg.span,
                                    "already specified",
                                );
                            }
                        }
                    }
                }
            }
            if (has_named) {
                for (0..sig.params.len) |i| {
                    if (call.implicit_self and i == 0) {
                        const actual = types_mod.inferExprType(self.check(), call.callee.expr.field.object);
                        const expected = sig.params[i];
                        if (!numberAccepts(expected, actual)) {
                            const expected_str = try type_syntax.formatTypeOpts(self.alloc, expected, .{});
                            const actual_str = try type_syntax.formatTypeOpts(self.alloc, actual, .{});
                            try self.appendError(
                                try self.alloc.print("arg 1 to `{s}` wants {s}, got {s}", .{
                                    name, expected_str, actual_str,
                                }),
                                call.callee.expr.field.object.span,
                                try self.alloc.print("not {s} (got {s})", .{
                                    expected_str, actual_str,
                                }),
                            );
                        }
                        continue;
                    }
                    const pi = i - self_offset;
                    const expected = sig.params[i];
                    var found = false;
                    for (call.args) |arg| {
                        if (isNamedParam(arg)) |pn| {
                            if (pi < sig.param_names.len and std.mem.eql(u8, sig.param_names[pi], pn)) {
                                _ = try self.analyzeNode(arg.expr.assign_expr.value);
                                const actual = types_mod.inferExprType(self.check(), arg.expr.assign_expr.value);
                                if (expected.tag == .type_var) continue;
                                if (!numberAccepts(expected, actual)) {
                                    const expected_str = try type_syntax.formatTypeOpts(self.alloc, expected, .{});
                                    const actual_str = try type_syntax.formatTypeOpts(self.alloc, actual, .{});
                                    try self.appendError(
                                        try self.alloc.print("arg `{s}` to `{s}` wants {s}, got {s}", .{
                                            pn, name, expected_str, actual_str,
                                        }),
                                        arg.span,
                                        try self.alloc.print("not {s} (got {s})", .{
                                            expected_str, actual_str,
                                        }),
                                    );
                                }
                                found = true;
                                break;
                            }
                        }
                    }
                    if (!found and pi < call.args.len) {
                        _ = try self.analyzeNode(call.args[pi]);
                        const actual = types_mod.inferExprType(self.check(), call.args[pi]);
                        if (expected.tag == .type_var) continue;
                        if (!numberAccepts(expected, actual)) {
                            const param_name = if (pi < sig.param_names.len and sig.param_names[pi].len > 0) sig.param_names[pi] else "";
                            const expected_str = try type_syntax.formatTypeOpts(self.alloc, expected, .{});
                            const actual_str = try type_syntax.formatTypeOpts(self.alloc, actual, .{});
                            try self.appendError(
                                try self.alloc.print("arg {d} (`{s}`) to `{s}` wants {s}, got {s}", .{
                                    pi + 1, param_name, name, expected_str, actual_str,
                                }),
                                call.args[pi].span,
                                try self.alloc.print("not {s} (got {s})", .{
                                    expected_str, actual_str,
                                }),
                            );
                        }
                    }
                }
                return self.substituteCallReturnType(sig_ptr, call);
            }
            const count = if (total_args < sig.params.len) total_args else sig.params.len;
            for (0..count) |i| {
                const expected = sig.params[i];
                const actual = if (call.implicit_self and i == 0)
                    types_mod.inferExprType(self.check(), call.callee.expr.field.object)
                else
                    try self.analyzeNode(call.args[i - self_offset]);
                if (expected.tag == .type_var) continue;
                if (!numberAccepts(expected, actual)) {
                    const param_name = if (i < sig.param_names.len and sig.param_names[i].len > 0) sig.param_names[i] else "";
                    const expected_str = try type_syntax.formatTypeOpts(self.alloc, expected, .{});
                    const actual_str = try type_syntax.formatTypeOpts(self.alloc, actual, .{});
                    const msg = if (call.implicit_self and i == 0)
                        try self.alloc.print("arg 1 (`{s}`) to `{s}` wants {s}, got {s}", .{
                            param_name, name, expected_str, actual_str,
                        })
                    else
                        try self.alloc.print("arg {d} (`{s}`) to `{s}` wants {s}, got {s}", .{
                            i + 1, param_name, name, expected_str, actual_str,
                        });
                    try self.appendError(
                        msg,
                        if (call.implicit_self and i == 0) call.callee.expr.field.object.span else call.args[i - self_offset].span,
                        try self.alloc.print("not {s} (got {s})", .{
                            expected_str, actual_str,
                        }),
                    );
                }
            }
            return self.substituteCallReturnType(sig_ptr, call);
        }

        for (call.args) |arg| _ = try self.analyzeNode(arg);
        return types_mod.TypeInfo{ .tag = .any };
    }

    fn substituteCallReturnType(
        self: *SemanticChecker,
        sig: *const types_mod.FunctionSignature,
        call: anytype,
    ) types_mod.TypeInfo {
        if (sig.type_params.len == 0 or sig.return_type.tag == .any) return sig.return_type;
        // inside function body where these type params are in scope?
        // if so, keep type vars abstract (no substitution)
        for (sig.type_params) |tp| {
            for (self.current_type_params) |ctp| {
                if (std.mem.eql(u8, tp, ctp)) return sig.return_type;
            }
        }
        const eff = types_mod.effectiveArgs(self.alloc, sig.params.len, call.callee, call.args, call.implicit_self) catch return sig.return_type;
        return types_mod.substCallReturn(self.check(), sig, call.callee, eff, call.type_args, false);
    }

    fn isNamedParam(arg: *const ast.Node) ?[]const u8 {
        if (arg.expr != .assign_expr) return null;
        const assign = arg.expr.assign_expr;
        if (assign.target.expr != .ident) return null;
        return assign.target.expr.ident;
    }

    fn findModuleByNameAndTarget(name: []const u8, target: revo.baselib.host.ParamType) ?*const revo.baselib.specs.FnSpec {
        const module_name = target.moduleName() orelse return null;
        for (revo.baselib.specs.full_specs) |group| {
            for (group) |*spec| {
                if (spec.is_type) continue;
                if (!std.mem.eql(u8, spec.name, name)) continue;
                const head = spec.head;
                if (head.kind == .namespaced and std.mem.eql(u8, head.module.?, module_name)) return spec;
            }
        }
        return null;
    }

    fn analyzeIf(self: *SemanticChecker, v: anytype, span: ast.Span) !types_mod.TypeInfo {
        _ = span;
        _ = try self.analyzeNode(v.condition);
        const then_type = try self.analyzeNode(v.then_expr);
        if (v.else_expr) |else_expr| {
            const else_type = try self.analyzeNode(else_expr);

            return if (then_type.tag == .any) else_type else then_type;
        }
        return .{ .tag = .any };
    }

    fn analyzeUnless(self: *SemanticChecker, v: anytype, span: ast.Span) !types_mod.TypeInfo {
        _ = span;
        _ = try self.analyzeNode(v.condition);
        const then_type = try self.analyzeNode(v.then_expr);
        if (v.else_expr) |else_expr| {
            const else_type = try self.analyzeNode(else_expr);

            return if (then_type.tag == .any) else_type else then_type;
        }
        return .{ .tag = .any };
    }

    fn appendTypeMismatch(
        self: *SemanticChecker,
        span: ast.Span,
        name: []const u8,
        expected: types_mod.TypeInfo,
        actual: types_mod.TypeInfo,
    ) !void {
        const expected_str = try type_syntax.formatTypeOpts(self.alloc, expected, .{});
        const actual_str = try type_syntax.formatTypeOpts(self.alloc, actual, .{});
        const msg = try self.alloc.print("`{s}` wants {s}, got {s}", .{
            name,
            expected_str,
            actual_str,
        });
        const label = try self.alloc.print(
            "wants {s}, got {s}",
            .{ expected_str, actual_str },
        );
        if (self.first_code == null) self.first_code = "type-mismatch";
        try self.appendError(msg, span, label);
    }

    fn appendReturnMismatch(self: *SemanticChecker, span: ast.Span, expected: types_mod.TypeInfo, actual: types_mod.TypeInfo) !void {
        const expected_str = try type_syntax.formatTypeOpts(self.alloc, expected, .{});
        const actual_str = try type_syntax.formatTypeOpts(self.alloc, actual, .{});
        const msg = try self.alloc.print("return type mismatch: wanted {s}, got {s}", .{
            expected_str,
            actual_str,
        });
        try self.appendError(msg, span, try self.alloc.print("return type not {s} (got {s})", .{
            expected_str,
            actual_str,
        }));
    }

    fn appendError(self: *SemanticChecker, message: []const u8, span: ast.Span, label: []const u8) !void {
        try self.errors.append(self.alloc, .{ .@"error" = message });
        try self.errors.append(self.alloc, .{ .span = .{ .span = span, .role = .primary, .message = try self.alloc.dupe(u8, label) } });
    }

    fn appendWarn(self: *SemanticChecker, message: []const u8, span: ast.Span, label: []const u8, code: []const u8) !void {
        if (self.first_warn_code == null) self.first_warn_code = code;
        try self.warn_parts.append(self.alloc, .{ .warn = message });
        try self.warn_parts.append(self.alloc, .{ .span = .{ .span = span, .role = .primary, .message = try self.alloc.dupe(u8, label) } });
    }
};

fn nullResolve(_: *anyopaque, _: []const u8, _: std.mem.Allocator) ?[]const u8 {
    return null;
}

// graph agrees with the checker on who lives where
// , inner scopes never leak up, kinds tell shadowing apart
test "graph mirrors the checker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src = "const x = 1\nfn f(x) do x end";
    const parsed = try Parser.parseSource(alloc, src, .{});
    // wrapped like mergeWithPreludes does in production
    // , so top decls live one scope down from the root
    const items: []const *ast.Node = switch (parsed.expr) {
        .block => |exprs| exprs,
        else => &[_]*ast.Node{@constCast(parsed)},
    };
    const wrapped = try alloc.create(ast.Node);
    wrapped.* = .{ .span = parsed.span, .expr = .{ .block = @constCast(items) } };
    var graph = scope_graph.ScopeGraph.init(alloc);
    defer graph.deinit();

    var anchor: u8 = 0;
    var checker = try SemanticChecker.init(alloc, "<test>", src, &.{}, null, null, null, .{
        .ptr = &anchor,
        .resolveFn = nullResolve,
    }, &graph);
    defer checker.deinit();
    _ = try checker.analyzeNode(wrapped);

    const file = try graph.fileRoot("<test>", ast.Span{ .start = 0, .end = 0, .line = 0, .column = 0 });
    var kids = std.ArrayList(scope_graph.ScopeId).empty;
    defer kids.deinit(alloc);
    try graph.children(file, &kids);
    try std.testing.expectEqual(@as(usize, 1), kids.items.len);
    const body = kids.items[0];

    const outer = graph.resolve(body, "x").?;
    try std.testing.expect(graph.defs.items[outer].kind == .binding);
    const fndef = graph.resolve(body, "f").?;
    try std.testing.expect(graph.defs.items[fndef].kind == .binding);

    var fnkids = std.ArrayList(scope_graph.ScopeId).empty;
    defer fnkids.deinit(alloc);
    try graph.children(body, &fnkids);
    var found_param = false;
    for (fnkids.items) |kid| {
        if (graph.resolve(kid, "x")) |def| {
            if (graph.defs.items[def].kind == .param) found_param = true;
        }
    }
    try std.testing.expect(found_param);
}
