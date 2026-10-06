//! parse -> expand -> check -> compile orchestration
//! stage companions live in pipeline/: scope_wiring (@exports wiring)
//! and import_scan (compile-time import extraction)

pub fn build(vm: *VM, source: Source, opts: BuildOptions) !BuildResult {
    var dropped: ?diagnostic.Report = null;
    const result = try buildWithWarnings(vm, source, opts, &dropped);
    if (dropped) |*wr| wr.deinit(vm.runtime.alloc);
    return result;
}

///
/// build with an opt-in warnings outparam
///
/// ; warnings never fail the build
///     TODO: add a -Werror
///
/// the report is owned by vm.runtime.alloc
///     , deinit it when done
///
/// known globals off the vm, caller owns the list
///   frozen first, then user
pub fn knownGlobalsFromVm(vm: *VM, alloc: std.mem.Allocator) ![]const []const u8 {
    var list = try std.ArrayList([]const u8).initCapacity(
        alloc,
        vm.frozen_globals.count() + vm.user_globals.count(),
    );

    var cit = vm.frozen_globals.keyIterator();
    while (cit.next()) |atom_id| {
        try list.append(alloc, vm.stringValue(atom_id.*));
    }

    var git = vm.user_globals.iterator();
    while (git.next()) |entry| {
        try list.append(alloc, vm.stringValue(entry.key_ptr.*));
    }

    return list.toOwnedSlice(alloc);
}

pub fn buildWithWarnings(vm: *VM, source: Source, opts: BuildOptions, warnings: *?diagnostic.Report) !BuildResult {
    var arena = std.heap.ArenaAllocator.init(vm.runtime.alloc);
    defer arena.deinit();

    // set import_dir from source name so preloadImports can find local modules
    const prev_import_dir = vm.import_dir;
    defer vm.import_dir = prev_import_dir;
    if (source.name) |name| {
        if (std.Io.Dir.path.dirname(name)) |dir| {
            vm.import_dir = dir;
        }
    }

    var parsed = switch (try parse(arena.allocator(), source, .{
        .include_baselib_macros = opts.include_baselib_macros,
        .repl_mode = opts.repl_mode,
    })) {
        .ok => |ok| ok,
        .err => |failure| {
            var diag = failure;
            diag.report = try diag.report.copy(vm.runtime.diag_alloc);
            if (source.name) |name| diag.report.source_name = try vm.runtime.diag_alloc.dupe(u8, name);
            return .{ .err = .{ .parse = diag } };
        },
    };
    // module scope? wrap ast to build exports table from pub decls
    if (opts.module_scope)
        parsed.root = try scope_wiring.wrapModule(arena.allocator(), parsed.root);

    // closures with pub decls should return their @exports table
    parsed.root = try scope_wiring.wrapPubFunctions(arena.allocator(), parsed.root);

    // import text cache, populated by preload, read by semantic resolver
    //   empty when preload is skipped, lookups just miss
    var import_cache = import_scan.ImportCache.init(arena.allocator());

    if (!opts.skip_preload and comptime !revo.is_freestanding)
        import_scan.preloadImports(vm, parsed.root, arena.allocator(), &import_cache) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => revo.term.fatal("preload: {s}", .{@errorName(err)}, vm),
        };

    const expand_result = try expandWithVmSource(
        vm,
        arena.allocator(),
        parsed,
        source.name orelse "",
        source.text,
    );

    const expanded = switch (expand_result) {
        .ok => |ok| ok,
        .proc_err, .macro_err => |report| {
            var copied = try report.copy(vm.runtime.diag_alloc);
            if (source.name) |name| copied.source_name = try vm.runtime.diag_alloc.dupe(u8, name);
            copied.source = try vm.runtime.diag_alloc.dupe(u8, source.text);
            return .{ .err = .{ .expand = .{ .report = copied } } };
        },
    };

    var type_annotations = std.AutoHashMap(*const Node, compiler.types.TypeId).init(vm.runtime.alloc);
    defer type_annotations.deinit();
    var type_table = compiler.types.TypeTable.init(arena.allocator());
    var scope_graph = scope_graph_mod.ScopeGraph.init(arena.allocator());
    const annotations = compiler.types.Annotations{ .map = &type_annotations, .table = &type_table };

    const known_globals = try knownGlobalsFromVm(vm, vm.runtime.alloc);
    defer vm.runtime.alloc.free(known_globals);

    const PipelineResolver = struct {
        fs: import_scan.Fs,
        cache: *import_scan.ImportCache,
        fn resolve(ptr: *anyopaque, path: []const u8, a: std.mem.Allocator) ?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (comptime !revo.is_freestanding) {
                const resolved = (import_scan.resolveModuleFileWithFs(self.fs, path) catch return null) orelse return null;
                defer self.fs.alloc.free(resolved);
                // shared libs are opaque to the compiler; the module resolves untyped
                if (std.mem.endsWith(u8, resolved, ".so") or std.mem.endsWith(u8, resolved, ".dylib")) {
                    return null;
                }
                if (self.cache.lookup(resolved)) |hit| return a.dupe(u8, hit) catch null;

                return std.Io.Dir.cwd().readFileAlloc(self.fs.io, resolved, a, std.Io.Limit.unlimited) catch null;
            }
            return null;
        }
    };
    var pipeline_resolver = PipelineResolver{ .fs = import_scan.Fs.fromVm(vm), .cache = &import_cache };

    if (try semantic.analyze(
        vm.runtime.alloc,
        expanded.root,
        source.name orelse "",
        source.text,
        known_globals,
        null,
        annotations,
        null,
        .{ .ptr = &pipeline_resolver, .resolveFn = PipelineResolver.resolve },
        &scope_graph,
        warnings,
    )) |failure| {
        // the original report is arena-owned inside semantic.analyze; copy it
        // out and take ownership of the source text (deinitError frees it)
        var copied = try failure.report.copy(vm.runtime.diag_alloc);
        if (source.name) |name| copied.source_name = try vm.runtime.diag_alloc.dupe(u8, name);
        copied.source = try vm.runtime.diag_alloc.dupe(u8, source.text);
        deinitError(vm.runtime.alloc, .{ .semantic = failure });
        return .{ .err = .{ .semantic = .{ .kind = failure.kind, .report = copied } } };
    }

    const compile_result = try compile(vm, expanded, .{
        .install_debug_info = opts.install_debug_info,
        .source = source,
        .test_mode = opts.test_mode,
    }, annotations);
    return switch (compile_result) {
        .ok => |bytecode| .{ .ok = bytecode },
        .err => |failure| .{ .err = .{ .compile = failure } },
    };
}

pub const Source = struct {
    text: []const u8,
    name: ?[]const u8 = null,
};

pub const Fs = import_scan.Fs;

pub const Sigs = struct {
    known_globals: []const []const u8 = &.{},

    pub fn fromVmGlobals(known_globals: []const []const u8) Sigs {
        return .{ .known_globals = known_globals };
    }
};

pub const ParseOptions = struct {
    include_baselib_macros: bool = false,
    repl_mode: bool = false,
};

pub const CompileOptions = struct {
    install_debug_info: bool = false,
    source: ?Source = null,
    test_mode: bool = false,
};
pub const ProjectMode = enum {
    script,
    project,
};

pub const BuildOptions = struct {
    include_baselib_macros: bool = true,
    install_debug_info: bool = true,
    test_mode: bool = false,
    mode: ProjectMode = .script,
    module_scope: bool = false, // build exports table from pub decls
    skip_preload: bool = false, // for repl
    repl_mode: bool = false,
};

fn parserOpts(opts: ParseOptions) Parser.Options {
    return .{ .repl_mode = opts.repl_mode };
}

pub const Parsed = struct {
    root: *Node,
};

pub const Expanded = struct {
    root: *Node,
};

pub const ExpandFailure = struct {
    report: diagnostic.Report,
};

pub const Error = union(enum) {
    parse: Parser.ParseFailure,
    expand: ExpandFailure,
    compile: compiler.CompileFailure,
    semantic: semantic.Failure,
};

pub const ParseResult = Result(Parsed, Parser.ParseFailure);
pub const ExpandError = macro_proc.ExpandError;
pub const ExpandResult = Result(Expanded, ExpandError);
pub const ExpandWithVmResult = union(enum) {
    ok: Expanded,
    proc_err: diagnostic.Report,
    macro_err: diagnostic.Report,
};

/// a `!` call surviving all expansion passes.
const UnexpandedMacro = struct {
    name: []const u8,
    span: ast.Span,
};

/// owned `a.b.c!` dotted path for a bang field callee, null when not one
///   walks the object chain up to 16 deep, caller frees the hit
fn dottedMacroName(alloc: std.mem.Allocator, callee: *const Node) !?[]u8 {
    if (callee.expr != .field) return null;

    const f = callee.expr.field;
    if (!std.mem.endsWith(u8, f.name, "!")) return null;

    var parts: [16][]const u8 = undefined;
    var part_count: usize = 0;
    {
        var cur: *const Node = f.object;
        while (true) {
            switch (cur.expr) {
                .ident => |n| {
                    parts[part_count] = n;
                    part_count += 1;
                    break;
                },
                .field => |fld| {
                    parts[part_count] = fld.name;
                    part_count += 1;
                    cur = fld.object;
                },
                else => break,
            }
            if (part_count == parts.len) break;
        }
    }
    // reverse parts so they're in base..field order
    var i: usize = 0;
    var j: usize = part_count;
    while (i < j) {
        j -= 1;
        const tmp = parts[i];
        parts[i] = parts[j];
        parts[j] = tmp;
        i += 1;
    }
    // append f.name as the final field
    if (part_count < parts.len) {
        parts[part_count] = f.name;
        part_count += 1;
    }
    var name = try alloc.dupe(u8, parts[0]);
    errdefer alloc.free(name);
    for (parts[1..part_count]) |part| {
        const combined = try alloc.print("{s}.{s}", .{ name, part });
        alloc.free(name);
        name = combined;
    }

    return name;
}

const UnexpandedVisitor = struct {
    alloc: std.mem.Allocator,
    out: *std.ArrayList(UnexpandedMacro),

    pub fn visit(self: *@This(), node: *const Node) void {
        if (node.expr == .call) {
            const callee = node.expr.call.callee;
            switch (callee.expr) {
                .ident => |n| if (std.mem.endsWith(u8, n, "!")) {
                    self.out.append(self.alloc, .{ .name = n, .span = callee.span }) catch return;
                },
                .field => |f| if (std.mem.endsWith(u8, f.name, "!")) {
                    const full_name = (dottedMacroName(self.alloc, callee) catch return) orelse return;
                    self.out.append(self.alloc, .{ .name = full_name, .span = callee.span }) catch {
                        self.alloc.free(full_name);
                        return;
                    };
                },
                else => {},
            }
        }
        ast.walkAST(UnexpandedVisitor, self, node);
    }
};

/// unknown macros are like pattern misses; both fail at runtime
/// quasiquote pruned by the walk
fn collectUnexpandedMacros(alloc: std.mem.Allocator, root: *const Node) ![]UnexpandedMacro {
    var out = try std.ArrayList(UnexpandedMacro).initCapacity(alloc, 4);
    errdefer out.deinit(alloc);

    var visitor = UnexpandedVisitor{ .alloc = alloc, .out = &out };
    visitor.visit(root);

    return out.toOwnedSlice(alloc);
}

pub const CompileResult = Result(Bytecode, compiler.CompileFailure);
pub const BuildResult = Result(Bytecode, Error);

pub fn parse(allocator: std.mem.Allocator, source: Source, opts: ParseOptions) !ParseResult {
    if (!opts.include_baselib_macros) {
        return switch (try Parser.parseSourceReport(allocator, source.text, parserOpts(opts))) {
            .ok => |expr| .{ .ok = .{ .root = expr } },
            .err => |failure| blk: {
                var diag = failure;
                if (source.name) |name| diag.report.source_name = name;
                break :blk .{ .err = diag };
            },
        };
    }

    // baselib macros merge as preludes: same merge shape,
    // authority lives in base.rv instead of a lang-side string.
    // the list is permanent like full_specs, never freed.
    const macro_srcs = try revo.baselib.specs.macroSources(allocator);
    var preludes = try std.ArrayList(*Node).initCapacity(allocator, macro_srcs.len);
    defer preludes.deinit(allocator);
    for (macro_srcs) |src| {
        switch (try Parser.parseSourceReport(allocator, src, parserOpts(opts))) {
            .ok => |root| try preludes.append(allocator, root),
            .err => |failure| return .{ .err = failure },
        }
    }
    const user: ParseResult = switch (try Parser.parseSourceReport(allocator, source.text, parserOpts(opts))) {
        .ok => |root| .{ .ok = .{ .root = root } },
        .err => |failure| blk: {
            var diag = failure;
            if (source.name) |name| diag.report.source_name = name;
            break :blk .{ .err = diag };
        },
    };
    if (user == .err) return .{ .err = user.err };
    return .{ .ok = .{ .root = try mergeWithPreludes(allocator, preludes.items, user.ok.root) } };
}

pub fn expandWithVmSource(
    vm: *VM,
    allocator: std.mem.Allocator,
    parsed: Parsed,
    source_name: []const u8,
    source: []const u8,
) !ExpandWithVmResult {
    const proc_result = try macro_proc.expandExprWithSource(vm, allocator, parsed.root, source_name, source);

    if (proc_result.error_report) |report|
        return .{ .proc_err = report };

    const final = proc_result.root.?;
    const missed = try collectUnexpandedMacros(allocator, final);

    if (missed.len > 0) {
        return .{ .macro_err = try macroReport(allocator, source_name, source, missed) };
    }
    return .{ .ok = .{ .root = final } };
}

/// one unknown-macro error per surviving callsite
fn macroReport(
    allocator: std.mem.Allocator,
    source_name: []const u8,
    source: []const u8,
    missed: []UnexpandedMacro,
) !diagnostic.Report {
    const fmt = "unknown macro `{s}`";
    var b = diagnostic.DiagnosticBuilder.init(allocator);
    errdefer b.deinit();

    for (missed) |m| {
        const msg = try allocator.print(fmt, .{m.name});
        try b.err(msg, m.span);
    }

    const first = try allocator.print(fmt, .{missed[0].name});
    errdefer allocator.free(first);

    var report = try b.finish(first, .err);
    report.source_name = source_name;
    report.source = source;

    return report;
}

pub fn compile(
    vm: *VM,
    expanded: Expanded,
    opts: CompileOptions,
    annotations: ?compiler.types.Annotations,
) !CompileResult {
    const compiled = try compiler.compileExprReport(
        vm,
        expanded.root,
        opts.test_mode,
        annotations,
    );
    return switch (compiled) {
        .ok => |bytecode| blk: {
            if (opts.install_debug_info) {
                const source: Source = opts.source orelse Source{ .text = "", .name = "<source>" };
                try vm.setProgramDebugInfo(bytecode.spans, source.text, source.name orelse "<source>");
            }
            break :blk .{ .ok = bytecode };
        },
        .err => |failure| blk: {
            var diag = failure;
            if (opts.source) |source| {
                if (source.name) |name| diag.report.source_name = name;
            }
            break :blk .{ .err = diag };
        },
    };
}

pub fn errorReport(err: Error) diagnostic.Report {
    return switch (err) {
        .parse => |failure| failure.report,
        .expand => |failure| failure.report,
        .compile => |failure| failure.report,
        .semantic => |failure| failure.report,
    };
}

pub fn renderError(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    source: Source,
    err: Error,
    opts: diagnostic.RenderOptions,
) !void {
    var report = errorReport(err);
    report.source_name = report.source_name orelse source.name;
    report.source = source.text;
    return diagnostic.renderReport(allocator, writer, report, opts);
}

/// render a warnings report
///   ; same shape as errors
///     , never fails the build
pub fn renderWarnings(allocator: std.mem.Allocator, writer: *std.Io.Writer, source: Source, report: diagnostic.Report, opts: diagnostic.RenderOptions) !void {
    var rep = report;
    rep.source_name = rep.source_name orelse source.name;
    rep.source = source.text;
    return diagnostic.renderReport(allocator, writer, rep, opts);
}

pub fn deinitError(alloc: std.mem.Allocator, err: Error) void {
    var report = errorReport(err);
    report.deinit(alloc);
}

/// flat merge of prelude roots before user code: one shared scope, so
/// later definitions win on redeclaration
fn mergeWithPreludes(allocator: std.mem.Allocator, preludes: []const *Node, user: *Node) !*Node {
    var items = try std.ArrayList(*Node).initCapacity(allocator, 8);
    var span = user.span;
    for (preludes) |pre| {
        span = ast.Span.merge(span, pre.span);
        switch (pre.expr) {
            .block => |block| try items.appendSlice(allocator, block),
            else => try items.append(allocator, pre),
        }
    }
    switch (user.expr) {
        .block => |block| {
            if (user.synthetic_block) {
                try items.appendSlice(allocator, block);
            } else {
                try items.append(allocator, user);
            }
        },
        else => try items.append(allocator, user),
    }
    const node = try allocator.create(Node);
    node.* = .{
        .span = span,
        .expr = .{ .block = try items.toOwnedSlice(allocator) },
    };
    return node;
}

const std = @import("std");

const revo = @import("revo");
const VM = revo.VM;
const Result = revo.Result;

const ast = @import("ast.zig");
const Node = ast.Node;
const compiler = @import("compiler/root.zig");
const diagnostic = @import("diagnostic.zig");
const import_scan = @import("pipeline/import_scan.zig");
const macro_proc = @import("macro_proc.zig");
const Parser = @import("Parser.zig");
const scope_graph_mod = @import("scope_graph.zig");
const scope_wiring = @import("pipeline/scope_wiring.zig");
const semantic = @import("semantic.zig");
pub const Bytecode = compiler.Bytecode;
pub const ParseFailure = Parser.ParseFailure;
pub const CompileErrorKind = compiler.CompileErrorKind;
pub const CompileFailure = compiler.CompileFailure;
