//! full builds, quick inspection, diagnostics, fn sigs

const std = @import("std");

const revo = @import("revo");

const ast = @import("../ast.zig");
const common = @import("common.zig");
const diagnostic = @import("../diagnostic.zig");
const pipeline = @import("../pipeline.zig");
const scope_graph_mod = @import("../scope_graph.zig");
const semantic = @import("../semantic.zig");
const types = @import("../compiler/types.zig");

const W = @import("../Workspace.zig");
const Workspace = W.Workspace;
const FileId = W.FileId;
const Analysis = W.Analysis;
const Symbol = W.Symbol;
const FnSig = W.FnSig;
const DiagnosticsBundle = W.DiagnosticsBundle;

/// full compile; returns BuildResult (ok/err)
pub fn analyze(
    self: *Workspace,
    alloc: std.mem.Allocator,
    id: FileId,
    opts: pipeline.BuildOptions,
) !pipeline.BuildResult {
    var analysis = try analyzeDetailed(self, alloc, id, opts);
    if (analysis.bytecode) |bytecode| {
        analysis.bytecode = null;
        defer analysis.deinit(alloc);
        return .{ .ok = bytecode };
    }
    defer analysis.deinit(alloc);
    return .{ .err = analysis.diagnostics.? };
}

/// full compile
/// ret: detailed Analysis with bytecode + diagnostics
pub fn analyzeDetailed(
    self: *Workspace,
    alloc: std.mem.Allocator,
    id: FileId,
    opts: pipeline.BuildOptions,
) !Analysis {
    const snap = self.snapshot(id) orelse return error.FileNotOpen;
    const vm = self.vm orelse return error.VmUnavailable;
    if (self.cache.get(id)) |cached| {
        if (cached.version == snap.version and common.sameOpts(cached.opts, opts)) {
            const bytecode = try common.copyBytecode(alloc, cached.bytecode);
            errdefer common.deinitBytecode(alloc, bytecode);
            var warnings: ?diagnostic.Report = null;
            errdefer if (warnings) |*w| w.deinit(alloc);
            if (cached.warnings) |cached_w| {
                var wcopy = try cached_w.copy(alloc);
                wcopy.source_name = alloc.dupe(u8, snap.name) catch |e| {
                    wcopy.deinit(alloc);
                    return e;
                };
                wcopy.source = alloc.dupe(u8, snap.text) catch |e| {
                    wcopy.deinit(alloc);
                    return e;
                };
                warnings = wcopy;
            }
            if (opts.install_debug_info) {
                try vm.setProgramDebugInfo(bytecode.spans, snap.text, snap.name);
            }
            return .{
                .snapshot = snap,
                .bytecode = bytecode,
                .warnings = warnings,
                .cached = true,
                .symbols = try common.copySymbols(alloc, cached.symbols),
                .dependencies = try self.copyDeps(alloc, id),
            };
        }
    }

    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();

    const parsed = try pipeline.parse(arena.allocator(), .{
        .name = snap.name,
        .text = snap.text,
    }, .{
        .include_baselib_macros = opts.include_baselib_macros,
    });

    if (parsed == .err) {
        var report = try parsed.err.report.copy(alloc);
        report.source_name = try alloc.dupe(u8, snap.name);
        report.source = try alloc.dupe(u8, snap.text);
        return .{
            .snapshot = snap,
            .diagnostics = .{ .parse = .{
                .kind = parsed.err.kind,
                .report = report,
            } },
            .cached = false,
            .symbols = try alloc.alloc(Symbol, 0),
            .dependencies = try alloc.alloc(FileId, 0),
        };
    }

    const root = parsed.ok.root;
    const symbols = try self.collectSymbolsFromParsed(root, snap.text);
    defer common.freeSymbols(self.alloc, symbols);
    const deps = try self.collectDepsFromParsed(snap, root);
    errdefer self.alloc.free(deps);
    try self.updateDeps(id, deps);

    var warn_report: ?diagnostic.Report = null;
    const build_result = try pipeline.buildWithWarnings(vm, .{
        .name = snap.name,
        .text = snap.text,
    }, opts, &warn_report);

    return switch (build_result) {
        .ok => |bytecode| blk: {
            defer common.deinitBytecode(vm.runtime.alloc, bytecode);
            const cache_bytecode = try common.copyBytecode(self.alloc, bytecode);
            errdefer common.deinitBytecode(self.alloc, cache_bytecode);

            const cache_symbols = try common.copySymbols(self.alloc, symbols);
            errdefer common.freeSymbols(self.alloc, cache_symbols);

            // warnings are owned by vm.runtime.alloc
            // re-own for the caller and the cache
            var cache_warnings: ?diagnostic.Report = null;
            errdefer if (cache_warnings) |*w| w.deinit(self.alloc);
            var warnings = if (warn_report) |wr| blk_w: {
                var owned = try wr.copy(alloc);
                owned.source_name = try alloc.dupe(u8, snap.name);
                owned.source = try alloc.dupe(u8, snap.text);

                cache_warnings = try wr.copy(self.alloc);
                cache_warnings.?.source_name = try self.alloc.dupe(u8, snap.name);
                cache_warnings.?.source = try self.alloc.dupe(u8, snap.text);

                var mutable = wr;
                mutable.deinit(vm.runtime.alloc);

                break :blk_w owned;
            } else null;

            try self.putCache(id, snap.version, opts, cache_bytecode, cache_symbols, cache_warnings);
            cache_warnings = null;

            const copy = try common.copyBytecode(alloc, bytecode);
            errdefer common.deinitBytecode(alloc, copy);

            errdefer if (warnings) |*w| w.deinit(alloc);
            break :blk .{
                .snapshot = snap,
                .bytecode = copy,
                .warnings = warnings,
                .cached = false,
                .symbols = try common.copySymbols(alloc, symbols),
                .dependencies = try self.copyDeps(alloc, id),
            };
        },
        .err => |err| blk: {
            // errors dominate
            // warnings drop with them
            if (warn_report) |*wr| wr.deinit(vm.runtime.alloc);
            break :blk .{
                .snapshot = snap,
                .diagnostics = try common.copyError(alloc, err, snap.name, snap.text),
                .cached = false,
                .symbols = try common.copySymbols(alloc, symbols),
                .dependencies = try self.copyDeps(alloc, id),
            };
        },
    };
}

/// get diagnostics for a file (or null if clean)
/// runs both semantic and full compile to catch all errors
pub fn diagnostics(
    self: *Workspace,
    alloc: std.mem.Allocator,
    id: FileId,
    opts: pipeline.BuildOptions,
) !?pipeline.Error {
    var bundle = try diagnosticsWithWarnings(self, alloc, id, opts);
    if (bundle.warnings) |*w| w.deinit(alloc);
    return bundle.err;
}

/// same as diagnostics
///   plus non-failing warnings off full build
pub fn diagnosticsWithWarnings(
    self: *Workspace,
    alloc: std.mem.Allocator,
    id: FileId,
    opts: pipeline.BuildOptions,
) !DiagnosticsBundle {
    const sem_snap = self.snapshot(id) orelse return error.FileNotOpen;
    const sem_entry = try ensureInspect(self, alloc, id, opts);

    var sem_diag: ?pipeline.Error = if (sem_entry.diagnostics) |diag|
        try common.copyError(alloc, diag, sem_snap.name, sem_snap.text)
    else
        null;
    errdefer if (sem_diag) |d| pipeline.deinitError(alloc, d);

    var full = analyzeDetailed(self, alloc, id, opts) catch |err| switch (err) {
        error.VmUnavailable => {
            if (sem_diag) |diag| {
                sem_diag = null;
                return .{ .err = diag };
            }
            return .{};
        },
        else => |e| return e,
    };
    // every return below hands off the reports it keeps, so drop the rest
    defer full.deinit(alloc);

    if (full.diagnostics) |full_diag| {
        if (sem_diag) |sem_d| {
            const merged_report = try common.mergeReports(alloc, sem_d, full_diag);
            // errorKind hardly matters for display
            full.diagnostics = null;
            pipeline.deinitError(alloc, sem_d);
            pipeline.deinitError(alloc, full_diag);
            sem_diag = null;
            const warnings = full.warnings;
            full.warnings = null;
            return .{ .err = pipeline.Error{ .compile = .{ .kind = .CompileError, .report = merged_report } }, .warnings = warnings };
        }
        full.diagnostics = null;
        const warnings = full.warnings;
        full.warnings = null;
        return .{ .err = full_diag, .warnings = warnings };
    }

    if (sem_diag) |diag| {
        sem_diag = null;
        const warnings = full.warnings;
        full.warnings = null;
        return .{ .err = diag, .warnings = warnings };
    }

    const warnings = full.warnings;
    full.warnings = null;
    return .{ .warnings = warnings };
}

// quick inspect off the cache, no full compile
pub fn inspectDetailed(
    self: *Workspace,
    alloc: std.mem.Allocator,
    id: FileId,
    opts: pipeline.BuildOptions,
) !Analysis {
    const snap = self.snapshot(id) orelse return error.FileNotOpen;
    const entry = try ensureInspect(self, alloc, id, opts);

    const symbols = try common.copySymbols(alloc, entry.symbols);
    errdefer common.freeSymbols(alloc, symbols);

    const dependencies = try self.copyDeps(alloc, id);
    errdefer alloc.free(dependencies);

    const diags = if (entry.diagnostics) |diag|
        try common.copyError(alloc, diag, snap.name, snap.text)
    else
        null;

    return .{
        .snapshot = snap,
        .diagnostics = diags,
        .cached = true,
        .symbols = symbols,
        .dependencies = dependencies,
    };
}

/// borrowed inspect, no copies
///   `scratch` is temporaries only
///   back pointer borrows `self`, good til next cache mutation
pub fn ensureInspect(
    self: *Workspace,
    scratch: std.mem.Allocator,
    id: FileId,
    opts: pipeline.BuildOptions,
) !*W.InspectCacheEntry {
    const snap = self.snapshot(id) orelse return error.FileNotOpen;
    if (self.inspect_cache.getPtr(id)) |cached| {
        if (cached.version == snap.version and common.sameOpts(cached.opts, opts)) return cached;
    }

    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();

    //
    // analysis never merges manifest macros
    //
    //   their spans point into the embedded sources,
    //   so theyd comw up as weird symbols/hovers with
    //   wrong lines
    //      (expansion and compilation keep merging; completions
    //      derive the names from the same manifest sources instead)
    //
    const parsed = try pipeline.parse(arena.allocator(), .{
        .name = snap.name,
        .text = snap.text,
    }, .{
        .include_baselib_macros = false,
    });

    if (parsed == .err) {
        var report = try parsed.err.report.copy(self.alloc);
        report.source_name = try self.alloc.dupe(u8, snap.name);
        report.source = try self.alloc.dupe(u8, snap.text);

        const parse_error: pipeline.Error = .{ .parse = .{ .kind = parsed.err.kind, .report = report } };
        const cache_diag = try common.copyError(self.alloc, parse_error, snap.name, snap.text);
        errdefer pipeline.deinitError(self.alloc, cache_diag);
        // first copy is ours, cache keeps the second
        pipeline.deinitError(self.alloc, parse_error);

        const empty_syms = try self.alloc.alloc(Symbol, 0);
        errdefer self.alloc.free(empty_syms);

        const empty_deps = try self.alloc.alloc(FileId, 0);
        errdefer self.alloc.free(empty_deps);

        try self.putInspectCache(id, snap.version, opts, empty_syms, empty_deps, cache_diag, .empty, .init(self.alloc));
        return self.inspect_cache.getPtr(id) orelse return error.FileNotOpen;
    }

    const root = parsed.ok.root;
    const symbols = try self.collectSymbolsFromParsed(root, snap.text);
    defer common.freeSymbols(self.alloc, symbols);
    const deps = try self.collectDepsFromParsed(snap, root);
    errdefer self.alloc.free(deps);
    try self.updateDeps(id, deps);
    const known_globals = try common.getKnownGlobals(self, scratch);
    defer scratch.free(known_globals);

    var type_map = std.StringHashMap(types.TypeInfo).init(scratch);
    defer {
        var it = type_map.iterator();
        while (it.next()) |entry| {
            scratch.free(entry.key_ptr.*);
            types.deinitType(entry.value_ptr, scratch);
        }
        type_map.deinit();
    }

    var type_annotations = std.AutoHashMap(*const ast.Node, types.TypeId).init(scratch);
    defer type_annotations.deinit();
    var type_table = types.TypeTable.init(arena.allocator());
    defer type_table.deinit();
    var scope_graph = scope_graph_mod.ScopeGraph.init(arena.allocator());
    defer scope_graph.deinit();

    const WorkspaceResolver = struct {
        ws: *Workspace,
        source_name: []const u8,
        mode: pipeline.ProjectMode,
        project_root: []const u8,
        fn resolve(ptr: *anyopaque, path: []const u8, a: std.mem.Allocator) ?[]const u8 {
            const s: *@This() = @ptrCast(@alignCast(ptr));
            const file_id = s.ws.resolveOpenImport(s.source_name, path, s.mode, s.project_root) orelse return null;
            const snap2 = s.ws.snapshot(file_id) orelse return null;
            return a.dupe(u8, snap2.text) catch null;
        }
    };
    const project_root = blk: {
        const entry = self.entryPtr(snap.id) catch break :blk "";
        break :blk entry.project_root;
    };
    var ws_resolver = WorkspaceResolver{
        .ws = self,
        .source_name = snap.name,
        .mode = opts.mode,
        .project_root = project_root,
    };

    var docs = std.StringHashMap([]const u8).init(self.alloc);
    errdefer {
        var dit = docs.iterator();
        while (dit.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*);
        }
        docs.deinit();
    }

    var dropped_warn: ?diagnostic.Report = null;
    const semantic_error = try semantic.analyze(
        scratch,
        root,
        snap.name,
        snap.text,
        known_globals,
        &type_map,
        .{ .map = &type_annotations, .table = &type_table },
        &docs,
        .{ .ptr = &ws_resolver, .resolveFn = WorkspaceResolver.resolve },
        &scope_graph,
        &dropped_warn,
    );

    if (dropped_warn) |*wr| wr.deinit(scratch);

    const cache_diag = if (semantic_error) |failure|
        try common.copyError(self.alloc, .{ .semantic = failure }, snap.name, snap.text)
    else
        null;
    errdefer if (cache_diag) |d| pipeline.deinitError(self.alloc, d);

    for (symbols) |*sym| {
        if (type_map.get(sym.name)) |t| {
            sym.type_name = try types.clone(t, self.alloc);
        }
    }

    var sig_map: std.StringHashMapUnmanaged(FnSig) = .empty;
    errdefer if (sig_map.size > 0) common.freeSigMap(self.alloc, &sig_map);
    self.collectSigsFromParsed(root, &sig_map);

    // docs live in request arena, re-own em for cache
    var cache_docs = std.StringHashMap([]const u8).init(self.alloc);
    errdefer {
        var cit = cache_docs.iterator();
        while (cit.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*);
        }
        cache_docs.deinit();
    }
    var doc_it = docs.iterator();
    while (doc_it.next()) |e| {
        try cache_docs.put(
            try self.alloc.dupe(u8, e.key_ptr.*),
            try self.alloc.dupe(u8, e.value_ptr.*),
        );
    }

    // fill holes from type_map where the sig left em blank
    var sig_it = sig_map.iterator();
    while (sig_it.next()) |sig_entry| {
        for (sig_entry.value_ptr.params) |*p| {
            if (p.type_name == null) {
                if (type_map.get(p.name)) |t| {
                    p.type_name = try types.clone(t, self.alloc);
                }
            }
        }
        if (sig_entry.value_ptr.return_type == null) {
            if (type_map.get(sig_entry.key_ptr.*)) |t| {
                if (t.tag == .function) {
                    sig_entry.value_ptr.return_type = try types.clone(t.tag.function.return_type, self.alloc);
                }
            }
        }
    }

    const cache_symbols = try common.copySymbols(self.alloc, symbols);
    errdefer common.freeSymbols(self.alloc, cache_symbols);
    const cache_deps = try self.copyDeps(self.alloc, id);
    errdefer self.alloc.free(cache_deps);
    try self.putInspectCache(id, snap.version, opts, cache_symbols, cache_deps, cache_diag, sig_map, cache_docs);

    // docs buckets are self.alloc, entries got reparented to scratch
    //   free entries with scratch, table with self.alloc
    {
        var dit = docs.iterator();
        while (dit.next()) |e| {
            scratch.free(e.key_ptr.*);
            scratch.free(e.value_ptr.*);
        }
        docs.deinit();
    }

    // semantic_error borrows scratch, cache keeps its own copy
    if (semantic_error) |err| {
        var owned = err;
        owned.report.deinit(scratch);
    }

    return self.inspect_cache.getPtr(id) orelse return error.FileNotOpen;
}

/// fn sig off the inspect cache
pub fn fnSig(self: *Workspace, scratch: std.mem.Allocator, id: FileId, name: []const u8) !?FnSig {
    return fnSigOpts(self, scratch, id, name, .{});
}

/// same lookup with your `opts`
///   keeps hover/signature/completion from thrashing cache
pub fn fnSigOpts(
    self: *Workspace,
    scratch: std.mem.Allocator,
    id: FileId,
    name: []const u8,
    opts: pipeline.BuildOptions,
) !?FnSig {
    const entry = try ensureInspect(self, scratch, id, opts);
    return entry.sig_map.get(name);
}

test "workspace caches repeated analysis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var vm = try revo.VM.init(.{ .alloc = alloc, .io = std.testing.io, .diag_alloc = alloc });
    defer vm.deinit();

    var ws = try Workspace.initWithVm(&vm, alloc);
    defer ws.deinit();

    const id = try ws.open("<test>", "1 + 1", .{});
    const first = try ws.analyze(alloc, id, .{});
    try std.testing.expect(first == .ok);

    const second = try ws.analyze(alloc, id, .{});
    try std.testing.expect(second == .ok);
    try std.testing.expectEqual(first.ok.instructions.len, second.ok.instructions.len);
}

test "workspace invalidates cache on change" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var vm = try revo.VM.init(.{ .alloc = alloc, .io = std.testing.io, .diag_alloc = alloc });
    defer vm.deinit();

    var ws = try Workspace.initWithVm(&vm, alloc);
    defer ws.deinit();

    const id = try ws.open("<test>", "1 + 1", .{});
    const first = try ws.analyze(alloc, id, .{});
    defer switch (first) {
        .ok => |bytecode| {
            alloc.free(bytecode.instructions);
            alloc.free(bytecode.spans);
        },
        .err => |err| pipeline.deinitError(alloc, err),
    };

    try ws.change(id, "1 + 2");
    const snap = ws.snapshot(id).?;
    try std.testing.expectEqual(@as(u32, 2), snap.version);

    const second = try ws.analyze(alloc, id, .{});
    defer switch (second) {
        .ok => |bytecode| {
            alloc.free(bytecode.instructions);
            alloc.free(bytecode.spans);
        },
        .err => |err| pipeline.deinitError(alloc, err),
    };
    try std.testing.expect(second == .ok);
}

test "workspace invalidates dependent caches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var vm = try revo.VM.init(.{ .alloc = alloc, .io = std.testing.io, .diag_alloc = alloc });
    defer vm.deinit();

    var ws = try Workspace.initWithVm(&vm, alloc);
    defer ws.deinit();

    const a = try ws.open("dir/a.rv", "1", .{});
    const b = try ws.open("dir/b.rv", "import \"a\"", .{});
    const c = try ws.open("dir/c.rv", "import \"b\"", .{});

    const res_b = try ws.analyze(alloc, b, .{});
    defer switch (res_b) {
        .ok => |bytecode| {
            alloc.free(bytecode.instructions);
            alloc.free(bytecode.spans);
        },
        .err => |err| pipeline.deinitError(alloc, err),
    };

    const res_c = try ws.analyze(alloc, c, .{});
    defer switch (res_c) {
        .ok => |bytecode| {
            alloc.free(bytecode.instructions);
            alloc.free(bytecode.spans);
        },
        .err => |err| pipeline.deinitError(alloc, err),
    };

    try std.testing.expect(ws.cache.get(b) != null);
    try std.testing.expect(ws.cache.get(c) != null);

    try ws.change(a, "2");

    try std.testing.expect(ws.cache.get(b) == null);
    try std.testing.expect(ws.cache.get(c) == null);
}

test "identical text change keeps caches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var vm = try revo.VM.init(.{ .alloc = alloc, .io = std.testing.io, .diag_alloc = alloc });
    defer vm.deinit();

    var ws = try Workspace.initWithVm(&vm, alloc);
    defer ws.deinit();

    const id = try ws.open("<test>", "1 + 1", .{});
    var first = try ws.analyzeDetailed(alloc, id, .{});
    defer first.deinit(alloc);
    try std.testing.expect(!first.cached);

    const e1 = try ws.ensureInspect(alloc, id, .{});

    try ws.change(id, "1 + 1");
    try std.testing.expectEqual(@as(u32, 1), ws.snapshot(id).?.version);

    const e2 = try ws.ensureInspect(alloc, id, .{});
    try std.testing.expect(e1 == e2);

    var second = try ws.analyzeDetailed(alloc, id, .{});
    defer second.deinit(alloc);
    try std.testing.expect(second.cached);
}

test "analysis returns snapshot and bytecode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var vm = try revo.VM.init(.{ .alloc = alloc, .io = std.testing.io, .diag_alloc = alloc });
    defer vm.deinit();

    var ws = try Workspace.initWithVm(&vm, alloc);
    defer ws.deinit();

    const id = try ws.open("<test>", "1 + 1", .{});
    var analysis = try ws.analyzeDetailed(alloc, id, .{});
    defer analysis.deinit(alloc);

    try std.testing.expectEqualStrings("<test>", analysis.snapshot.name);
    try std.testing.expect(analysis.bytecode != null);
    try std.testing.expect(analysis.diagnostics == null);
}

test "workspace diagnostics query" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ws = try Workspace.init(alloc);
    defer ws.deinit();

    const id = try ws.open("<test>", "const x =", .{});
    const diag = try ws.diagnostics(alloc, id, .{});
    try std.testing.expect(diag != null);
}

test "workspace diagnostics clean file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // *vm attached like the lsp does, baselib fns come from its globals*
    var vm = try revo.VM.init(.{ .alloc = alloc, .io = std.testing.io, .diag_alloc = alloc });
    defer vm.deinit();
    var ws = try Workspace.initWithVm(&vm, alloc);
    defer ws.deinit();

    const id = try ws.open("<test>", "let x = 1\nprint(x)", .{});
    const diag = try ws.diagnostics(alloc, id, .{});
    try std.testing.expect(diag == null);
}

test "workspace diagnostics undefined name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ws = try Workspace.init(alloc);
    defer ws.deinit();

    const id = try ws.open("<test>", "hiasdhfasduf", .{});
    const diag = try ws.diagnostics(alloc, id, .{});
    try std.testing.expect(diag != null);
}

test "workspace diagnostics warn on missing return arrow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ws = try Workspace.init(alloc);
    defer ws.deinit();

    const id = try ws.open("<test>",
        \\ fn demo() string do
        \\   "ok"
        \\ end
    , .{});
    const diag = try ws.diagnostics(alloc, id, .{});
    try std.testing.expect(diag != null);
}

test "workspace diagnostics merge semantic and compile failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ws = try Workspace.init(alloc);
    defer ws.deinit();

    const source =
        \\ type Result = {:ok, any} | {:err, atom}
        \\ fn bind(what: any, where: num) -> Result do
        \\   "ok"
        \\ end
        \\ bind(1, "hi")
    ;
    const id = try ws.open("<test>", source, .{});
    const diag = try ws.diagnostics(alloc, id, .{});
    try std.testing.expect(diag != null);

    const report = switch (diag.?) {
        .parse => |f| f.report,
        .expand => |f| f.report,
        .compile => |f| f.report,
        .semantic => |f| f.report,
    };

    var err_count: usize = 0;
    for (report.parts) |part| {
        if (part == .@"error") err_count += 1;
    }
    try std.testing.expect(err_count >= 2);
    try std.testing.expect(report.message.len != 0);
    try std.testing.expect(std.mem.find(u8, report.message, "return type") != null);
}

test "workspace sig map survives typed fn invalidation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ws = try Workspace.init(alloc);
    defer ws.deinit();

    const id = try ws.open("<sig>",
        \\const f = fn(x: table, y: fn(num) -> str) x
        \\type T = fn(table<int>, num) -> table<string, int>
        \\
    , .{});
    _ = try ws.inspectDetailed(alloc, id, .{});

    try ws.change(id, "const f = fn(x: table) x");
    _ = try ws.inspectDetailed(alloc, id, .{});

    const cache = ws.inspect_cache.getPtr(id) orelse return error.TestUnexpectedResult;
    const sig = cache.sig_map.get("f") orelse return error.TestUnexpectedResult;
    const p = sig.params[0].type_name.?;
    try std.testing.expect(p.tag == .table);
    try std.testing.expect(p.tag.table.key == null);
    try std.testing.expect(p.tag.table.value.*.tag == .any);
}
