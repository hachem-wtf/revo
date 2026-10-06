//! symbol collection, sig maps, workspace symbol index

const std = @import("std");

const revo = @import("revo");

const ast = @import("../ast.zig");
const common = @import("common.zig");
const pipeline = @import("../pipeline.zig");
const txt = @import("text.zig");
const type_syntax = @import("../type_syntax.zig");
const types = @import("../compiler/types.zig");

const W = @import("../Workspace.zig");
const Workspace = W.Workspace;
const FileId = W.FileId;
const Location = W.Location;
const Snapshot = W.Snapshot;
const Symbol = W.Symbol;
const SymbolKind = W.SymbolKind;
const FnSig = W.FnSig;
const ParamInfo = W.ParamInfo;
const IndexedSymbol = W.IndexedSymbol;

pub fn rebuildSymbolIndex(self: *Workspace) void {
    {
        var it = self.symbol_index.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.value_ptr.*);
            self.alloc.free(entry.key_ptr.*);
        }
    }
    self.symbol_index.clearRetainingCapacity();

    for (self.files.items) |file| {
        const cached = self.inspect_cache.get(file.id) orelse continue;
        for (cached.symbols) |sym| {
            const name_copy = self.alloc.dupe(u8, sym.name) catch continue;
            const entry = IndexedSymbol{
                .file_id = file.id,
                .range = sym.range,
                .kind = sym.kind,
            };
            if (self.symbol_index.getPtr(name_copy)) |list| {
                self.alloc.free(name_copy);
                const new_len = list.len + 1;
                const new_list = self.alloc.realloc(list.*, new_len) catch {
                    continue;
                };
                new_list[new_len - 1] = entry;
                list.* = new_list;
            } else {
                const new_list = self.alloc.alloc(IndexedSymbol, 1) catch {
                    self.alloc.free(name_copy);
                    continue;
                };
                new_list[0] = entry;
                self.symbol_index.put(name_copy, new_list) catch {
                    self.alloc.free(new_list);
                    self.alloc.free(name_copy);
                    continue;
                };
            }
        }
    }
    self.symbol_index_dirty = false;
}

/// workspace/symbol lookup across all open files
pub fn findSymbols(self: *Workspace, alloc: std.mem.Allocator, name: []const u8) ![]Location {
    if (self.symbol_index_dirty) self.rebuildSymbolIndex();
    const syms = self.symbol_index.get(name) orelse return alloc.alloc(Location, 0);
    const locations = try alloc.alloc(Location, syms.len);
    for (syms, locations) |sym, *loc| {
        _ = self.snapshot(sym.file_id) orelse {
            alloc.free(locations);
            return error.FileNotOpen;
        };
        loc.* = .{
            .file_id = sym.file_id,
            .name = try alloc.dupe(u8, name),
            .range = sym.range,
        };
    }
    return locations;
}

/// outline syms for a file
pub fn documentSymbols(
    self: *Workspace,
    alloc: std.mem.Allocator,
    id: FileId,
    opts: pipeline.BuildOptions,
) ![]Symbol {
    const entry = try self.ensureInspect(alloc, id, opts);
    // params resolve for hover/def but dont outline
    return common.copyFilteredSymbols(alloc, entry.symbols, true);
}

///
/// walk ast & collect
///     bindings, functions, type aliases
///
/// full dotted macro names from baselib manifests
///     (`uri.asdf!`)
///
/// names borrow the embedded sources (static)
/// ; only the list is owned
/// . callers split scope from member
/// ; the parser caps heads at one dot.
///
pub fn baselibMacroNames(self: *Workspace, arena: std.mem.Allocator) [][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    const srcs = revo.baselib.specs.macroSources(arena) catch return out.items;

    for (srcs) |src| {
        const parsed = pipeline.parse(arena, .{ .name = "<baselib-macros>", .text = src }, .{ .include_baselib_macros = false }) catch continue;
        if (parsed != .ok) continue;
        const syms = collectSymbolsFromParsed(self, parsed.ok.root, src) catch continue;
        defer common.freeSymbols(self.alloc, @constCast(syms));

        for (syms) |sym| {
            if (sym.kind != .macro) continue;
            const owned = arena.dupe(u8, sym.name) catch return out.items;
            out.append(arena, owned) catch return out.items;
        }
    }
    return out.items;
}

/// cached variant: parsed once, reused per keystroke
///   names owned by `ws.alloc`;
///   caller must not free
///   same content as `baselibMacroNames`
pub fn baselibMacroNamesCached(self: *Workspace) [][]const u8 {
    if (self.macro_names_cache) |cached| return cached;
    // parse with scratch arena, then re-own names in ws.alloc
    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();

    const fresh = self.baselibMacroNames(arena.allocator());
    const owned = self.alloc.alloc([]const u8, fresh.len) catch return &.{};
    var done: usize = 0;

    for (fresh) |src| {
        owned[done] = self.alloc.dupe(u8, src) catch {
            for (owned[0..done]) |n| self.alloc.free(n);
            self.alloc.free(owned);
            return &.{};
        };
        done += 1;
    }

    self.macro_names_cache = owned;
    return owned;
}

pub fn collectSymbolsFromParsed(self: *Workspace, root: *ast.Node, text: []const u8) ![]Symbol {
    var out = try std.ArrayList(Symbol).initCapacity(self.alloc, 8);
    errdefer out.deinit(self.alloc);
    var visitor = SymbolVisitor{ .alloc = self.alloc, .out = &out, .text = text };
    visitor.visit(root);
    return out.toOwnedSlice(self.alloc);
}

/// walk AST for fn_expr bindings and populate sig_map with ParamInfo slices
pub fn collectSigsFromParsed(
    self: *Workspace,
    root: *const ast.Node,
    sig_map: *std.StringHashMapUnmanaged(FnSig),
) void {
    var visitor = SigVisitor{
        .ws = self,
        .sig_map = sig_map,
        .alloc = self.alloc,
    };
    visitor.visit(root);
}

const SigVisitor = struct {
    ws: *Workspace,
    sig_map: *std.StringHashMapUnmanaged(FnSig),
    alloc: std.mem.Allocator,

    /// evalTypeExpr can return shared comptime sentinels or types borrowing ast
    /// sig_map can outlive both so we need deepcopy
    fn ownedType(self: *@This(), te: *const ast.TypeExpr) ?types.TypeInfo {
        const t = types.evalBare(self.alloc, te) catch return null;
        return types.clone(t, self.alloc) catch null;
    }

    fn paramInfos(self: *@This(), fn_expr: anytype) ?[]ParamInfo {
        const params = self.alloc.alloc(ParamInfo, fn_expr.params.len) catch return null;
        errdefer self.alloc.free(params);
        for (fn_expr.params, params) |src, *dst| {
            dst.* = .{
                .name = self.alloc.dupe(u8, src.name) catch return null,
                .type_name = if (src.type_name) |te| self.ownedType(te) else null,
                .optional = src.optional or src.default_value != null,
            };
        }
        return params;
    }

    pub fn visit(self: *@This(), node: *const ast.Node) void {
        switch (node.expr) {
            .type_alias => |t| {
                switch (t.type_expr.kind) {
                    .function => |f| {
                        const name = t.name;

                        const params = self.alloc.alloc(ParamInfo, f.params.len) catch return;
                        errdefer self.alloc.free(params);
                        for (f.params, params) |src, *dst| {
                            dst.* = .{
                                .name = self.alloc.dupe(u8, src.name) catch return,
                                .type_name = if (src.type_name) |te| self.ownedType(te) else null,
                                .optional = src.optional or src.default_value != null,
                            };
                        }

                        const return_type: ?types.TypeInfo = if (f.return_type) |rt| self.ownedType(rt) else null;

                        const name_owned = self.alloc.dupe(u8, name) catch return;
                        self.sig_map.put(self.alloc, name_owned, .{
                            .params = params,
                            .return_type = return_type,
                        }) catch return;
                    },
                    else => {},
                }
            },
            .binding => |b| {
                if (b.target.expr != .ident) return;
                const name = b.target.expr.ident;
                if (b.value.expr == .fn_expr) {
                    const fn_expr = b.value.expr.fn_expr;

                    const params = self.paramInfos(fn_expr) orelse return;

                    const name_owned = self.alloc.dupe(u8, name) catch return;
                    self.sig_map.put(self.alloc, name_owned, .{
                        .params = params,
                        .return_type = null,
                        .type_params_text = common.formatTypeParams(self.alloc, fn_expr.type_params) catch return,
                    }) catch return;
                    return;
                }
                // ascribed re-export:
                // the value isn't a literal fn, so the sig comes from the annotation instead
                const tn = b.type_name orelse return;
                const ft_owned = self.ownedType(tn) orelse return;
                var ft = ft_owned;

                defer types.deinitType(&ft, self.alloc);
                if (ft.tag != .function) return;

                const fsig = ft.tag.function;
                const params = self.alloc.alloc(ParamInfo, fsig.params.len) catch return;
                errdefer self.alloc.free(params);

                for (fsig.params, fsig.param_names, params, 0..) |pt, pn, *dst, i| {
                    dst.* = .{
                        .name = self.alloc.dupe(u8, pn) catch return,
                        .type_name = types.clone(pt, self.alloc) catch return,
                        .optional = i >= fsig.required_count,
                    };
                }

                const return_type: ?types.TypeInfo = types.clone(fsig.return_type, self.alloc) catch null;
                const name_owned = self.alloc.dupe(u8, name) catch return;
                self.sig_map.put(self.alloc, name_owned, .{
                    .params = params,
                    .return_type = return_type,
                    .type_params_text = common.formatTypeParams(self.alloc, fsig.type_params) catch return,
                }) catch return;
            },
            .assign_expr => |ae| {
                if (ae.value.expr != .fn_expr) return;
                const fn_expr = ae.value.expr.fn_expr;
                if (fn_expr.doc == null) return;

                const name: []const u8 = switch (ae.target.expr) {
                    .field => |f| f.name,
                    .ident => |i| i,
                    else => return,
                };

                const params = self.paramInfos(fn_expr) orelse return;

                const return_type: ?types.TypeInfo = null;
                const name_owned = self.alloc.dupe(u8, name) catch return;
                self.sig_map.put(self.alloc, name_owned, .{
                    .params = params,
                    .return_type = return_type,
                    .type_params_text = common.formatTypeParams(self.alloc, fn_expr.type_params) catch return,
                }) catch return;
            },
            else => ast.walkAST(@This(), self, node),
        }
    }
};

/// walk AST for import expressions and resolve them to FileIds
pub fn collectDepsFromParsed(self: *Workspace, snap: Snapshot, root: *ast.Node) ![]FileId {
    var out = try std.ArrayList(FileId).initCapacity(self.alloc, 4);
    errdefer out.deinit(self.alloc);
    const file_entry = self.entryPtr(snap.id) catch return out.toOwnedSlice(self.alloc);
    var visitor = ImportVisitor{
        .ws = self,
        .out = &out,
        .base = snap.name,
        .mode = file_entry.mode,
        .project_root = file_entry.project_root,
        .failed = false,
    };
    visitor.visit(root);
    if (visitor.failed) return error.OutOfMemory;
    return out.toOwnedSlice(self.alloc);
}

const SymbolVisitor = struct {
    alloc: std.mem.Allocator,
    out: *std.ArrayList(Symbol),
    text: []const u8,
    /// a binding like `const x = import "foo"` names the module itself
    import_named: bool = false,

    pub fn visit(self: *@This(), node: *const ast.Node) void {
        switch (node.expr) {
            .binding => |b| self.addBinding(b),
            .fn_expr => |f| for (f.params) |p| self.addName(p.name, .param, p.name_span),
            .type_alias => |t| self.addName(ast.bareName(t), .type_alias, t.name_span),
            // proc macros take the .macro kind
            // ; node span lands on the decl start (no name span)
            // . bare member names, like type aliases: `q.macc!`
            //   in a dep file completes as `macc!` under import name
            .proc_macro => |pm| self.addName(ast.bareMacroName(pm.name), .macro, node.span),
            .import_stmt => |is| {
                if (self.import_named) {
                    self.import_named = false;
                } else {
                    self.addName(is.name, .binding, self.importNameSpan(node, is.name));
                }
            },
            else => {},
        }
        // decls fall through - walkAST reaches every binding exactly once
        ast.walkAST(SymbolVisitor, self, node);
    }

    fn addBinding(self: *@This(), b: ast.Binding) void {
        self.import_named = b.value.expr == .import_stmt;
        switch (b.target.expr) {
            .ident => |name| {
                const before = self.out.items.len;
                self.addName(name, .binding, b.target.span);
                // table literals carry hover previews on the just-added
                // symbol (append-only, so a failed addName leaves len alone)
                if (b.value.expr == .table and self.out.items.len > before) {
                    if (self.tableFieldPreviews(b.value.expr.table)) |previews| {
                        self.out.items[self.out.items.len - 1].field_values = previews;
                    }
                }
            },
            .table_pattern => |items| {
                for (items) |item| {
                    if (item.expr == .ident and !ast.isDiscardName(item.expr.ident))
                        self.addName(item.expr.ident, .binding, item.span);
                }
            },
            else => {},
        }
    }

    /// condensed `{k = v}` source slices for single-line literal fields;
    /// null when nothing previewable
    fn tableFieldPreviews(self: *@This(), entries: []const ast.TableEntry) ?[]type_syntax.FieldPreview {
        var out = std.ArrayList(type_syntax.FieldPreview).initCapacity(self.alloc, entries.len) catch return null;
        var implicit_idx: u32 = 0;
        for (entries) |entry| {
            if (entry.key == null and entry.value.expr == .decl and
                entry.value.expr.decl.inner.expr == .binding and
                entry.value.expr.decl.inner.expr.binding.value.expr == .fn_expr)
                continue;

            const name = ast.staticFieldName(entry);
            if (name) |n| {
                const span = entry.value.span;
                if (span.end > self.text.len or span.start > span.end) continue;
                const slice = self.text[span.start..span.end];
                if (slice.len == 0 or std.mem.findScalar(u8, slice, '\n') != null) continue;

                out.append(self.alloc, .{
                    .name = self.alloc.dupe(u8, n) catch return null,
                    .preview = self.alloc.dupe(u8, slice) catch return null,
                }) catch return null;
            } else {
                const idx = implicit_idx;
                implicit_idx += 1;
                const span = entry.value.span;

                if (span.end > self.text.len or span.start > span.end) continue;
                const slice = self.text[span.start..span.end];
                if (slice.len == 0 or std.mem.findScalar(u8, slice, '\n') != null) continue;

                out.append(self.alloc, .{
                    .name = self.alloc.print("{d}", .{idx}) catch return null,
                    .preview = self.alloc.dupe(u8, slice) catch return null,
                }) catch return null;
            }
        }
        if (out.items.len == 0) return null;
        return out.toOwnedSlice(self.alloc) catch null;
    }

    /// module name = right after the path's opening quote; fall back to the
    /// whole statement (subdir paths, table form)
    fn importNameSpan(self: *@This(), node: *const ast.Node, name: []const u8) ast.Span {
        var q = node.span.start;
        while (q < node.span.end and self.text[q] != '\'' and self.text[q] != '"') q += 1;
        const start = q + 1;

        if (q >= node.span.end or start + name.len > node.span.end) return node.span;
        if (!std.mem.eql(u8, self.text[start .. start + name.len], name)) return node.span;
        if (start + name.len < node.span.end and txt.isWordChar(self.text[start + name.len])) return node.span;

        var line = node.span.line;
        var column = node.span.column;
        var i = node.span.start;

        while (i < start) : (i += 1) {
            if (self.text[i] == '\n') {
                line += 1;
                column = 1;
            } else {
                column += 1;
            }
        }
        return .{ .start = start, .end = start + name.len, .line = line, .column = column };
    }

    fn addName(self: *@This(), name: []const u8, kind: SymbolKind, span: ast.Span) void {
        const owned = self.alloc.dupe(u8, name) catch return;
        self.out.append(self.alloc, .{
            .name = owned,
            .kind = kind,
            .range = .{
                .start = .{ .line = span.line, .character = @intCast(span.column) },
                .end = .{ .line = span.line, .character = @intCast(span.column + name.len) },
            },
            .field_values = null,
        }) catch {};
    }
};

//
// import visitor
//

const ImportVisitor = struct {
    ws: *Workspace,
    out: *std.ArrayList(FileId),
    base: []const u8,
    mode: pipeline.ProjectMode,
    project_root: []const u8,
    failed: bool,

    // walk the AST; collect import statements and resolve them
    pub fn visit(self: *@This(), node: *const ast.Node) void {
        if (node.expr == .import_stmt) {
            const raw = node.expr.import_stmt.path;
            if (raw.len != 0) {
                const id = self.ws.resolveOpenImport(self.base, raw, self.mode, self.project_root) orelse
                    self.ws.resolveOpenImportOrOpen(self.base, raw, self.mode, self.project_root);
                if (id) |resolved| {
                    if (!txt.containsId(self.out.items, resolved)) {
                        self.out.append(self.ws.alloc, resolved) catch {
                            self.failed = true;
                        };
                    }
                }
            }
        }
        ast.walkAST(ImportVisitor, self, node);
    }
};

test "workspace cross-file symbol index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ws = try Workspace.init(alloc);
    defer ws.deinit();

    // *opens two files with overlapping symbol names*
    const a = try ws.open("<a>", "const x = 1\nconst y = 2", .{});
    const b = try ws.open("<b>", "const x = 3\nconst z = 4", .{});

    // *populates inspect caches*
    _ = try ws.inspectDetailed(alloc, a, .{});
    _ = try ws.inspectDetailed(alloc, b, .{});

    // findSymbols works across files
    const xs = try ws.findSymbols(alloc, "x");
    defer alloc.free(xs);
    try std.testing.expectEqual(@as(usize, 2), xs.len);

    const ys = try ws.findSymbols(alloc, "y");
    defer alloc.free(ys);
    try std.testing.expectEqual(@as(usize, 1), ys.len);

    const zs = try ws.findSymbols(alloc, "z");
    defer alloc.free(zs);
    try std.testing.expectEqual(@as(usize, 1), zs.len);

    // unknown name returns empty
    const ws2 = try ws.findSymbols(alloc, "nobody");
    defer alloc.free(ws2);
    try std.testing.expectEqual(@as(usize, 0), ws2.len);

    // after change, index is rebuilt
    try ws.change(a, "const x = 10");
    _ = try ws.inspectDetailed(alloc, a, .{});
    const xs2 = try ws.findSymbols(alloc, "x");
    defer alloc.free(xs2);
    try std.testing.expectEqual(@as(usize, 2), xs2.len);
}
