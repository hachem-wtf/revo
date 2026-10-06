const std = @import("std");

const revo = @import("revo");
const VM = revo.VM;

const ast = @import("../ast.zig");
const Node = ast.Node;
const Parser = @import("../Parser.zig");

pub const ImportCache = struct {
    sources: std.StringHashMap([]const u8),

    pub fn init(alloc: std.mem.Allocator) ImportCache {
        return .{ .sources = std.StringHashMap([]const u8).init(alloc) };
    }

    pub fn lookup(self: *const ImportCache, resolved: []const u8) ?[]const u8 {
        return self.sources.get(resolved);
    }
};

pub const Fs = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    import_dir: ?[]const u8 = null,
    project_root: []const u8 = "",
    package_path: []const []const u8 = &.{},

    pub fn fromVm(vm: *VM) Fs {
        return .{
            .io = vm.runtime.io,
            .alloc = vm.runtime.alloc,
            .import_dir = vm.import_dir,
            .project_root = vm.project_root,
            .package_path = vm.package_path.items,
        };
    }
};

/// walk AST and pre-load imported modules (best-effort, OOM propagates, others
/// are deferred to runtime where the import native fn handles them)
pub fn preloadImports(vm: *VM, root: *Node, alloc: std.mem.Allocator, cache: *ImportCache) !void {
    return preloadImportsWithFs(Fs.fromVm(vm), root, alloc, cache);
}

pub fn preloadImportsWithFs(fs: Fs, root: *Node, alloc: std.mem.Allocator, cache: *ImportCache) !void {
    var inject_nodes = try std.ArrayList(*Node).initCapacity(alloc, 8);
    defer inject_nodes.deinit(alloc);

    var visited = std.StringHashMap(void).init(alloc);
    defer visited.deinit();

    // separate visited for submod macro extraction, keyed by qualified prefix + path
    // so that re-exports through different parents both get extracted
    var visited_sub = std.StringHashMap(void).init(alloc);
    defer visited_sub.deinit();

    try walkAndProcessImportsWithFs(fs, root, alloc, &inject_nodes, &visited, &visited_sub, cache);

    if (inject_nodes.items.len > 0 and root.expr == .block) {
        const items = root.expr.block;
        var new_items = try std.ArrayList(*Node).initCapacity(alloc, items.len + inject_nodes.items.len);
        for (inject_nodes.items) |n| new_items.appendAssumeCapacity(n);
        for (items) |item| new_items.appendAssumeCapacity(item);
        root.expr.block = try new_items.toOwnedSlice(alloc);
    }
}

fn walkAndProcessImportsWithFs(
    fs: Fs,
    node: *Node,
    alloc: std.mem.Allocator,
    inject_nodes: *std.ArrayList(*Node),
    visited: *std.StringHashMap(void),
    visited_sub: *std.StringHashMap(void),
    cache: *ImportCache,
) !void {
    var visitor = ImportWalkVisitor{
        .fs = fs,
        .alloc = alloc,
        .inject_nodes = inject_nodes,
        .visited = visited,
        .visited_sub = visited_sub,
        .cache = cache,
    };
    visitor.visit(node);
    if (visitor.failed) |e| return e;
}

/// walkAST visitor matching the old hand recursion exactly
///   only block|decl|binding recurse, so imports under if/match/fn stay missed
///   first error aborts like propagation did, visit just cannot return it
const ImportWalkVisitor = struct {
    fs: Fs,
    alloc: std.mem.Allocator,
    inject_nodes: *std.ArrayList(*Node),
    visited: *std.StringHashMap(void),
    visited_sub: *std.StringHashMap(void),
    cache: *ImportCache,
    failed: ?anyerror = null,

    pub fn visit(self: *@This(), node: *const Node) void {
        if (self.failed != null) return;
        switch (node.expr) {
            .import_stmt => |stmt| processImportWithFs(
                self.fs,
                stmt.path,
                stmt.name,
                self.alloc,
                self.inject_nodes,
                self.visited,
                self.visited_sub,
                self.cache,
            ) catch |e| {
                if (self.failed == null) self.failed = e;
            },
            .block, .decl, .binding => ast.walkAST(@This(), self, node),
            else => {},
        }
    }
};

/// resolve module path matching runtime import resolution
pub fn resolveModuleFile(vm: *VM, name: []const u8) !?[]const u8 {
    return resolveModuleFileWithFs(Fs.fromVm(vm), name);
}

pub fn resolveModuleFileWithFs(fs: Fs, name: []const u8) !?[]const u8 {
    return revo.resolveImportFile(
        fs.io,
        fs.alloc,
        name,
        fs.import_dir,
        fs.project_root,
        fs.package_path,
    );
}

pub fn resolveModuleText(vm: *VM, cache: *ImportCache, path: []const u8, alloc: std.mem.Allocator) !?[]const u8 {
    return resolveModuleTextWithFs(Fs.fromVm(vm), cache, path, alloc);
}

pub fn resolveModuleTextWithFs(fs: Fs, cache: *ImportCache, path: []const u8, alloc: std.mem.Allocator) !?[]const u8 {
    const resolved = try resolveModuleFileWithFs(fs, path) orelse return null;
    defer fs.alloc.free(resolved);

    if (cache.lookup(resolved)) |hit| return hit;

    const source = std.Io.Dir.cwd().readFileAlloc(
        fs.io,
        resolved,
        alloc,
        std.Io.Limit.unlimited,
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };

    try cache.sources.put(try alloc.dupe(u8, resolved), source);

    return source;
}

fn readResolvedCachedWithFs(fs: Fs, cache: *ImportCache, resolved: []const u8, alloc: std.mem.Allocator) ![]const u8 {
    if (cache.lookup(resolved)) |hit| return hit;

    const source = try std.Io.Dir.cwd().readFileAlloc(
        fs.io,
        resolved,
        alloc,
        std.Io.Limit.unlimited,
    );
    try cache.sources.put(try alloc.dupe(u8, resolved), source);

    return source;
}

fn processImportWithFs(
    fs: Fs,
    path: []const u8,
    mod_name: []const u8,
    alloc: std.mem.Allocator,
    inject_nodes: *std.ArrayList(*Node),
    visited: *std.StringHashMap(void),
    visited_sub: *std.StringHashMap(void),
    cache: *ImportCache,
) !void {
    if (visited.contains(path)) return;
    try visited.put(path, {});

    // non-OOM errors are deferred to runtime,,, preload is best-effort
    const source = (try resolveModuleTextWithFs(fs, cache, path, alloc)) orelse return;

    const module_ast = Parser.parseSource(alloc, source, .{}) catch return;

    extractPubDefs(module_ast, mod_name, alloc, inject_nodes) catch return;
    extractPubImportsOneLevelWithFs(fs, module_ast, mod_name, alloc, inject_nodes, visited_sub, cache) catch return;
}

/// extract pub macros and procs from a module AST, qualified with prefix
/// injects them as named nodes into out for the parent scope
fn extractPubDefs(node: *Node, prefix: []const u8, alloc: std.mem.Allocator, out: *std.ArrayList(*Node)) !void {
    switch (node.expr) {
        .block => |items| {
            for (items) |item| try extractPubDefs(item, prefix, alloc, out);
        },
        .decl => |d| {
            if (d.pub_) {
                switch (d.inner.expr) {
                    .proc_macro => |pm| {
                        if (std.mem.endsWith(u8, pm.name, "!")) {
                            const qualified = try alloc.print("{s}.{s}", .{ prefix, ast.bareMacroName(pm.name) });
                            const proc_node = try ast.allocNode(alloc, d.inner.span, .{ .proc_macro = .{
                                .name = qualified,
                                .param = .{ .name = pm.param.name, .name_span = pm.param.name_span },
                                .body = pm.body,
                            } });
                            try out.append(alloc, proc_node);
                        }
                    },
                    .type_alias => |t| {
                        const ta_node = try ast.allocNode(alloc, d.inner.span, .{
                            .type_alias = .{ .name = t.name, .name_span = t.name_span, .type_expr = t.type_expr },
                        });
                        try out.append(alloc, ta_node);
                    },
                    else => {},
                }
            }
            try extractPubDefs(d.inner, prefix, alloc, out);
        },
        else => {},
    }
}

fn extractPubImportsOneLevelWithFs(
    fs: Fs,
    node: *Node,
    prefix: []const u8,
    alloc: std.mem.Allocator,
    inject_nodes: *std.ArrayList(*Node),
    visited_sub: *std.StringHashMap(void),
    cache: *ImportCache,
) !void {
    switch (node.expr) {
        .block => |items| {
            for (items) |item| try extractPubImportsOneLevelWithFs(fs, item, prefix, alloc, inject_nodes, visited_sub, cache);
        },
        .import_stmt => |stmt| {
            if (stmt.pub_) {
                // key by qualified prefix + path so different parents with same sub-path
                // both get their macros extracted
                const dedup_key = try alloc.print("{s}.{s}.{s}", .{ prefix, stmt.name, stmt.path });
                defer alloc.free(dedup_key);
                if (visited_sub.contains(dedup_key)) return;
                try visited_sub.put(dedup_key, {});

                const sub_prefix = try alloc.print("{s}.{s}", .{ prefix, stmt.name });
                defer alloc.free(sub_prefix);

                const resolved = try resolveModuleFileWithFs(fs, stmt.path) orelse return;
                defer fs.alloc.free(resolved);

                const source = try readResolvedCachedWithFs(fs, cache, resolved, alloc);

                const sub_ast = try Parser.parseSource(alloc, source, .{});
                try extractPubDefs(sub_ast, sub_prefix, alloc, inject_nodes);
            }
        },
        .decl => |d| try extractPubImportsOneLevelWithFs(fs, d.inner, prefix, alloc, inject_nodes, visited_sub, cache),
        else => {},
    }
}
