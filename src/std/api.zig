// stdlib as data: sigs and docs live in `src/std/iface/*.d.rv`, one file
// per group. `#* ... *#` blocks are markdown docs (bare ``` fences for
// code), `pub declare <head> = fn(...) -> ret` lines are sigs, `#`/`##`
// lines are editorial comments. heads may carry a `[T]` generic suffix; a
// bare `__call`/`__index` head sets the core key. zig supplies impls only
// (`pub const impls: []const api.Impl` per file).
//
// `loadAllSpecs` merges the two at boot; a missing or orphaned impl is a
// hard error, so docs can't drift from the runtime. the primitive type
// metatable *is* the module table: dynamic `x:method()` dispatch gets a
// single direct `getRaw`, numeric indexing the one exception via the
// `__index` native stashed inside the module table

const std = @import("std");

const revo = @import("../root.zig");
const ast = @import("../lang/ast.zig");
const Data = revo.Data;
const root = @import("root.zig");
const TypeSpec = root.TypeSpec;
const HostFunc = root.HostFunc;

pub const regex_on = @import("build_options").regex;

pub const IfaceGroup = struct {
    name: []const u8,
    src: []const u8,
};

pub const iface_groups: []const IfaceGroup = &.{
    .{ .name = "root", .src = @embedFile("iface/root.d.rv") },
    .{ .name = "os", .src = @embedFile("iface/os.d.rv") },
    .{ .name = "re", .src = @embedFile("iface/re.d.rv") },
    .{ .name = "number", .src = @embedFile("iface/number.d.rv") },
    .{ .name = "string", .src = @embedFile("iface/string.d.rv") },
    .{ .name = "table", .src = @embedFile("iface/table.d.rv") },
    .{ .name = "tuple", .src = @embedFile("iface/tuple.d.rv") },
    .{ .name = "iter", .src = @embedFile("iface/iter.d.rv") },
    .{ .name = "math", .src = @embedFile("iface/math.d.rv") },
    .{ .name = "stats", .src = @embedFile("iface/stats.d.rv") },
    .{ .name = "json", .src = @embedFile("iface/json.d.rv") },
    .{ .name = "csv", .src = @embedFile("iface/csv.d.rv") },
    .{ .name = "time", .src = @embedFile("iface/time.d.rv") },
    .{ .name = "net", .src = @embedFile("iface/net.d.rv") },
    .{ .name = "http", .src = @embedFile("iface/http.d.rv") },
    .{ .name = "uri", .src = @embedFile("iface/uri.d.rv") },
    .{ .name = "fs", .src = @embedFile("iface/fs.d.rv") },
    .{ .name = "revo", .src = @embedFile("iface/revo.d.rv") },
    .{ .name = "compress", .src = @embedFile("iface/compress.d.rv") },
    .{ .name = "rng", .src = @embedFile("iface/rng.d.rv") },
    .{ .name = "argparse", .src = @embedFile("iface/argparse.d.rv") },
};

/// the zig side of one spec: registry key + implementation
pub const Impl = struct {
    name: []const u8,
    f: HostFunc,
};

pub const ImplGroup = struct {
    name: []const u8,
    impls: []const Impl,
};

/// the `re` group is dropped at comptime when regex is off so the
/// mvzr/io chain never reaches targets like freestanding wasm
pub const impl_groups: []const ImplGroup = if (regex_on) &.{
    .{ .name = "root", .impls = @import("root.zig").root_impls },
    .{ .name = "os", .impls = @import("root.zig").os_impls },
    .{ .name = "re", .impls = @import("regex.zig").impls },
    .{ .name = "number", .impls = @import("number.zig").impls },
    .{ .name = "string", .impls = @import("string.zig").impls },
    .{ .name = "table", .impls = @import("table.zig").impls },
    .{ .name = "tuple", .impls = @import("tuple.zig").impls },
    .{ .name = "iter", .impls = @import("iter.zig").impls },
    .{ .name = "math", .impls = @import("math.zig").impls },
    .{ .name = "stats", .impls = @import("stats.zig").impls },
    .{ .name = "json", .impls = @import("json.zig").impls },
    .{ .name = "csv", .impls = @import("csv.zig").impls },
    .{ .name = "time", .impls = @import("time.zig").impls },
    .{ .name = "net", .impls = @import("net.zig").impls },
    .{ .name = "http", .impls = @import("http.zig").impls },
    .{ .name = "uri", .impls = @import("uri.zig").impls },
    .{ .name = "fs", .impls = @import("fs.zig").impls },
    .{ .name = "revo", .impls = @import("revo.zig").impls },
    .{ .name = "compress", .impls = @import("compress.zig").impls },
    .{ .name = "rng", .impls = @import("rng.zig").impls },
    .{ .name = "argparse", .impls = @import("argparse_std.zig").impls },
} else &.{
    .{ .name = "root", .impls = @import("root.zig").root_impls },
    .{ .name = "os", .impls = @import("root.zig").os_impls },
    .{ .name = "number", .impls = @import("number.zig").impls },
    .{ .name = "string", .impls = @import("string.zig").impls },
    .{ .name = "table", .impls = @import("table.zig").impls },
    .{ .name = "tuple", .impls = @import("tuple.zig").impls },
    .{ .name = "iter", .impls = @import("iter.zig").impls },
    .{ .name = "math", .impls = @import("math.zig").impls },
    .{ .name = "stats", .impls = @import("stats.zig").impls },
    .{ .name = "json", .impls = @import("json.zig").impls },
    .{ .name = "time", .impls = @import("time.zig").impls },
    .{ .name = "net", .impls = @import("net.zig").impls },
    .{ .name = "http", .impls = @import("http.zig").impls },
    .{ .name = "uri", .impls = @import("uri.zig").impls },
    .{ .name = "fs", .impls = @import("fs.zig").impls },
    .{ .name = "revo", .impls = @import("revo.zig").impls },
    .{ .name = "compress", .impls = @import("compress.zig").impls },
    .{ .name = "rng", .impls = @import("rng.zig").impls },
    .{ .name = "argparse", .impls = @import("argparse_std.zig").impls },
};

/// merged, runtime view of the stdlib surface; built by `loadAllSpecs`
pub var full_specs: []const []const FnSpec = &.{};

var permanent_cache: ?[]const []const FnSpec = null;

pub fn loadAllSpecs(caller_alloc: std.mem.Allocator) ![]const []const FnSpec {
    if (permanent_cache) |cached| {
        full_specs = cached;
        return cached;
    }

    const pa = if (revo.is_freestanding) caller_alloc else std.heap.page_allocator;

    var groups = try std.ArrayList([]const FnSpec).initCapacity(pa, impl_groups.len);
    errdefer {
        for (groups.items) |g| {
            for (g) |s| s.deinit(pa);
            pa.free(g);
        }
        groups.deinit(pa);
    }
    for (impl_groups) |ig| {
        const src = ifaceSrc(ig.name);
        const specs = try parseGroup(pa, src);
        for (specs, 0..) |*s, i| {
            var k: usize = 0;
            if (i > 0) for (specs[0..i]) |other| {
                if (std.mem.eql(u8, other.name, s.name)) k += 1;
            };
            s.f = implFor(ig.impls, s, k) orelse {
                std.debug.print("missing {s}\n", .{s.sig});
                @panic("missing an std def");
            };
        }
        for (ig.impls) |imp| {
            if (findSpec(specs, imp.name) == null) return error.StdlibImplUnused;
        }
        try groups.append(pa, specs);
    }
    const owned = try groups.toOwnedSlice(pa);
    permanent_cache = owned;
    full_specs = owned;
    return owned;
}

/// permanent cache
/// the cache lives in page_allocator so no debug allocator tracks it
pub fn freeLoadedSpecs(_: std.mem.Allocator, _: []const []const FnSpec) void {}

fn ifaceSrc(name: []const u8) []const u8 {
    for (iface_groups) |ig| {
        if (std.mem.eql(u8, ig.name, name)) return ig.src;
    }
    return "";
}

/// callable head of sig: `fs.open(path: string)` -> `fs.open`
fn specHead(sig: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, sig, '(') orelse sig.len;
    var head = sig[0..end];
    if (std.mem.indexOfScalar(u8, head, '[')) |open| head = head[0..open];
    return head;
}

/// impl registered under the full head like `f nfs.stat` pairs outright
/// otherwise the k-th spec with this name takes the k-th bare-named impl
fn implFor(impls: []const Impl, spec: *const FnSpec, k: usize) ?HostFunc {
    const head = specHead(spec.sig);
    for (impls) |imp| if (std.mem.eql(u8, imp.name, head)) return imp.f;
    var seen: usize = 0;
    for (impls) |imp| {
        if (!std.mem.eql(u8, imp.name, spec.name)) continue;
        if (seen == k) return imp.f;
        seen += 1;
    }
    return null;
}

fn findSpec(specs: []const FnSpec, impl_name: []const u8) ?*const FnSpec {
    for (specs) |*s| {
        if (std.mem.eql(u8, s.name, impl_name)) return s;
        if (std.mem.eql(u8, specHead(s.sig), impl_name)) return s;
    }
    return null;
}

/// first match wins
pub fn find(name: []const u8) ?*const FnSpec {
    for (full_specs) |group| for (group) |*spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec;
    };
    return null;
}

/// a sig is the rendered signature: `fs.open(path: string) -> !table`
pub fn renderSignature(w: *std.Io.Writer, spec: FnSpec) !void {
    try w.writeAll(spec.sig);
}

pub const Kind = enum { global, module, method };

/// who a spec belongs to:
///   filled at build time, read everywhere else
///   never re-derived from the sig string
pub const Head = struct {
    kind: Kind,
    module: ?[]const u8 = null,
    target: ?TypeSpec = null,
    /// owned: `tuple` in `tuple:len`, for grouping display
    target_name: ?[]const u8 = null,
};

pub const FnSpec = struct {
    name: []const u8,
    /// display only, never parsed
    sig: []const u8,
    head: Head,
    type_params: []const []const u8,
    /// cloned trees; untyped only outside iface files
    params: []ast.FnParam,
    ret: ?*ast.TypeExpr,
    doc: []const u8 = "",
    module_doc: []const u8 = "",
    variadic: bool = false,
    /// a plain value binding (`const width = 80`), not callable
    is_value: bool = false,
    /// when set, the metatable key is this core atom (e.g. `__index`)
    /// instead of `internAtom(name)`. only `__index` uses it today
    core_key: ?revo.core_atoms = null,
    /// default values for optional params (parallel to params, nullis no default)
    default_values: []const ?*ast.Node = &.{},
    f: HostFunc,

    /// release one spec's owned strings and trees, not the spec struct itself
    pub fn deinit(self: *const FnSpec, alloc: std.mem.Allocator) void {
        alloc.free(self.sig);
        alloc.free(self.name);

        if (self.head.module) |m| alloc.free(m);
        if (self.head.target_name) |t| alloc.free(t);
        for (self.type_params) |tp| alloc.free(tp);
        alloc.free(self.type_params);

        for (self.params) |p| {
            alloc.free(p.name);
            if (p.type_name) |tn| revo.lang.type_serde.freeTypeExpr(alloc, tn);
        }

        alloc.free(self.params);
        if (self.ret) |r| revo.lang.type_serde.freeTypeExpr(alloc, r);
        alloc.free(self.doc);
        if (self.default_values.len > 0) alloc.free(self.default_values);
    }
};

// -- [iface] -----------------------------------------------------------------

/// parse one `.d.rv` group with the real language front-end and collect the
/// `pub declare` decls. the source is ordinary revo - `#* ... *#` doc
/// comments, `#`/`##` comments and `fn(...) -> t` type expressions all work - so the
/// doc/sig extraction is just an AST walk, no string scanning
fn parseGroup(alloc: std.mem.Allocator, src: []const u8) ![]FnSpec {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try revo.lang.parseSourceReport(a, src);
    const root_node = switch (parsed) {
        .ok => |node| node,
        .err => return error.IfaceParseFailed,
    };

    return collectSpecs(alloc, root_node, true);
}

/// the spec surface of a parsed node: `pub declare` aliases, plus,outside
/// iface files, `#* ... *#`-attributed plain fn bindings
pub fn collectSpecs(alloc: std.mem.Allocator, node: *const revo.lang.Node, iface: bool) ![]FnSpec {
    var specs = std.ArrayList(FnSpec).empty;
    errdefer specs.deinit(alloc);

    const items: []const *const revo.lang.Node = if (node.expr != .block) &.{node} else node.expr.block;
    for (items) |item| {
        // method-style `fn math:twice(x)` parses to a bare assign_expr, no
        // decl wrapper - only docgen collects these
        if (item.expr == .assign_expr) {
            if (iface) continue;
            const v = item.expr.assign_expr.value;
            if (v.expr != .fn_expr) continue;
            if (v.expr.fn_expr.doc == null) continue;
            try specs.append(alloc, try specFromAssign(alloc, item.expr.assign_expr, v.expr.fn_expr.doc));
            continue;
        }
        if (item.expr != .decl) continue;
        const d = item.expr.decl;
        switch (d.inner.expr) {
            .type_alias => |t| {
                if (d.kind != .declare_decl) continue;
                try specs.append(alloc, try specFromDecl(alloc, t, d.doc orelse t.doc, iface));
            },
            .binding => |b| {
                const doc = d.doc orelse b.doc;
                if (iface) continue;
                if (doc == null) continue;
                if (b.target.expr != .ident) continue;
                if (b.value.expr == .fn_expr) {
                    try specs.append(alloc, try specFromBinding(alloc, b, doc));
                } else {
                    try specs.append(alloc, try specFromConst(alloc, b.target.expr.ident, doc));
                }
            },
            else => {},
        }
    }
    return specs.toOwnedSlice(alloc);
}

/// a `#* ... *#`-attributed `fn obj:name(...)` assignment, spec'd like a
/// declare: head marks it a method on `obj`
fn specFromAssign(alloc: std.mem.Allocator, ae: anytype, doc: ?[]const u8) !FnSpec {
    const t = ae.value.expr.fn_expr;
    const ix = switch (ae.target.expr) {
        .index => |x| x,
        else => return error.IfaceBadBindingTarget,
    };
    if (ix.object.expr != .ident) return error.IfaceBadBindingTarget;
    const key: []const u8 = switch (ix.key.expr) {
        .hash => |h| h,
        .ident => |n| n,
        else => return error.IfaceBadBindingTarget,
    };
    const head = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ ix.object.expr.ident, key });
    defer alloc.free(head);
    return specFromFn(alloc, head, head, .{
        .kind = .method,
        .target = root.typeFromName(ix.object.expr.ident),
        .target_name = ix.object.expr.ident,
    }, &.{}, t.params, t.return_type, doc, false);
}

/// a `#* ... *#`-attributed `const f = fn(...)` binding, spec'd like a declare
fn specFromBinding(alloc: std.mem.Allocator, b: ast.Binding, doc: ?[]const u8) !FnSpec {
    const t = b.value.expr.fn_expr;
    const name = b.target.expr.ident;
    return specFromFn(alloc, name, name, .{ .kind = .global }, &.{}, t.params, t.return_type, doc, false);
}

/// a `#* ... *#`-attributed non-fn binding (`const a = 5`): named value with
/// no call signature, so the spec's sig is just the name
fn specFromConst(alloc: std.mem.Allocator, name: []const u8, doc: ?[]const u8) !FnSpec {
    var doc_buf = std.ArrayList(u8).empty;
    defer doc_buf.deinit(alloc);
    if (doc) |d| {
        try doc_buf.appendSlice(alloc, d);
        try docFromMarkdown(alloc, &doc_buf);
    }
    return .{
        .name = try alloc.dupe(u8, name),
        .sig = try alloc.dupe(u8, name),
        .head = .{ .kind = .global },
        .type_params = &.{},
        .params = &.{},
        .ret = null,
        .doc = try alloc.dupe(u8, std.mem.trimEnd(u8, doc_buf.items, "\n")),
        .is_value = true,
        .f = undefined,
    };
}

pub fn specFromDecl(alloc: std.mem.Allocator, alias: ast.TypeAlias, doc: ?[]const u8, strict: bool) !FnSpec {
    const tps = if (alias.declare_tps.len > 0) blk: {
        const joined = try std.mem.join(alloc, ", ", alias.declare_tps);
        defer alloc.free(joined);
        break :blk try std.fmt.allocPrint(alloc, "[{s}]", .{joined});
    } else "";
    defer if (tps.len > 0) alloc.free(tps);

    var name: []const u8 = alias.name;
    var head: Head = .{ .kind = .global };
    var mod_text: ?[]u8 = null;
    defer if (mod_text) |m| alloc.free(m);
    const head_text: []const u8 = if (alias.declare_head) |dh|
        switch (dh) {
            .module => |segs| blk: {
                name = segs[segs.len - 1];
                if (segs.len > 1) {
                    mod_text = try std.mem.join(alloc, ".", segs[0 .. segs.len - 1]);
                    head = .{ .kind = .module, .module = mod_text.? };
                }
                const joined = try std.mem.join(alloc, ".", segs);
                defer alloc.free(joined);
                break :blk try std.fmt.allocPrint(alloc, "{s}{s}", .{ joined, tps });
            },
            .core => |c| blk: {
                name = c.key;
                head = .{ .kind = .method, .target = root.typeFromName(c.target), .target_name = c.target };
                break :blk try std.fmt.allocPrint(alloc, "{s}:{s}{s}", .{ c.target, c.key, tps });
            },
        }
    else
        try std.fmt.allocPrint(alloc, "{s}{s}", .{ alias.name, tps });
    defer alloc.free(head_text);

    if (alias.type_expr.kind != .function) {
        // non-function alias: a named type, documented like a value
        var doc_buf = std.Io.Writer.Allocating.init(alloc);
        defer doc_buf.deinit();
        try doc_buf.writer.writeAll("alias for `");
        try revo.lang.type_serde.printTypeExpr(alias.type_expr, &doc_buf.writer);
        try doc_buf.writer.writeAll("`");

        if (doc) |d| {
            try doc_buf.writer.writeAll("\n\n");
            try doc_buf.writer.writeAll(d);
        }
        const owned_tps = try alloc.alloc([]const u8, alias.declare_tps.len);
        for (alias.declare_tps, owned_tps) |tp, *dst| dst.* = try alloc.dupe(u8, tp);
        return .{
            .name = try alloc.dupe(u8, name),
            .sig = try alloc.dupe(u8, head_text),
            .head = .{
                .kind = head.kind,
                .module = if (head.module) |m| try alloc.dupe(u8, m) else null,
                .target = head.target,
                .target_name = if (head.target_name) |t| try alloc.dupe(u8, t) else null,
            },
            .type_params = owned_tps,
            .params = &.{},
            .ret = null,
            .doc = try alloc.dupe(u8, std.mem.trimEnd(u8, doc_buf.written(), "\n")),
            .is_value = true,
            .f = undefined,
        };
    }
    const fn_type = alias.type_expr.kind.function;

    return specFromFn(alloc, name, head_text, head, alias.declare_tps, fn_type.params, fn_type.return_type, doc orelse alias.doc, strict);
}

/// shared assembly: params, sig text, doc normalization, core key. `strict`
/// iface sources require every param typed
/// plain fn bindings may skip
/// the single way types enter a spec: trees are cloned here
pub fn specFromFn(
    alloc: std.mem.Allocator,
    name: []const u8,
    head_text: []const u8,
    head: Head,
    type_params: []const []const u8,
    params_in: []const ast.FnParam,
    return_type: ?*ast.TypeExpr,
    doc: ?[]const u8,
    strict: bool,
) !FnSpec {
    var params = try std.ArrayList(ast.FnParam).initCapacity(alloc, params_in.len);
    errdefer params.deinit(alloc);

    var defaults = try std.ArrayList(?*ast.Node).initCapacity(alloc, params_in.len);
    errdefer defaults.deinit(alloc);

    var variadic = false;
    var rendered = std.Io.Writer.Allocating.init(alloc);
    defer rendered.deinit();
    var args = std.ArrayList(u8).empty;
    defer args.deinit(alloc);

    for (params_in, 0..) |p, i| {
        if (i > 0) try args.appendSlice(alloc, ", ");
        if (p.optional) try args.appendSlice(alloc, "?");
        try args.appendSlice(alloc, p.name);
        if (p.type_name) |tn| {
            rendered.clearRetainingCapacity();
            try revo.lang.type_serde.printTypeExpr(tn, &rendered.writer);
            try args.appendSlice(alloc, ": ");
            try args.appendSlice(alloc, rendered.written());
        } else if (strict) {
            return error.IfaceParamNotTyped;
        }
        if (p.variadic) {
            variadic = true;
            if (p.type_name == null) try args.appendSlice(alloc, ": ");
            try args.appendSlice(alloc, "...");
        }

        try params.append(alloc, .{
            .name = try alloc.dupe(u8, p.name),
            .name_span = p.name_span,
            .type_name = if (p.type_name) |tn| try revo.lang.type_serde.cloneTypeExpr(alloc, tn) else null,
            .optional = p.optional,
            .default_value = p.default_value,
            .variadic = p.variadic,
        });
        try defaults.append(alloc, p.default_value);
    }

    var ret_buf = std.Io.Writer.Allocating.init(alloc);
    defer ret_buf.deinit();
    const ret_tree: ?*ast.TypeExpr = if (return_type) |r| blk: {
        try revo.lang.type_serde.printTypeExpr(r, &ret_buf.writer);
        break :blk try revo.lang.type_serde.cloneTypeExpr(alloc, r);
    } else null;

    const sig = if (ret_buf.written().len > 0)
        try std.fmt.allocPrint(alloc, "{s}({s}) -> {s}", .{ head_text, args.items, ret_buf.written() })
    else
        try std.fmt.allocPrint(alloc, "{s}({s})", .{ head_text, args.items });

    const tps_owned = try alloc.alloc([]const u8, type_params.len);
    for (type_params, tps_owned) |tp, *dst| dst.* = try alloc.dupe(u8, tp);

    var doc_buf = std.ArrayList(u8).empty;
    defer doc_buf.deinit(alloc);
    if (doc) |d| {
        try doc_buf.appendSlice(alloc, d);
        try docFromMarkdown(alloc, &doc_buf);
    }

    var core_key: ?revo.core_atoms = null;
    if (std.mem.startsWith(u8, name, "__")) {
        if (std.meta.stringToEnum(revo.core_atoms, name)) |atom| {
            core_key = atom;
        } else if (head.kind != .global) {
            // a __-name on a target must be a real metatable slot; bare
            // unknown __names are plain globals (__internal_dotest etc)
            return error.BadCoreKey;
        }
    }

    return .{
        .name = try alloc.dupe(u8, name),
        .sig = sig,
        .head = .{
            .kind = head.kind,
            .module = if (head.module) |m| try alloc.dupe(u8, m) else null,
            .target = head.target,
            .target_name = if (head.target_name) |t| try alloc.dupe(u8, t) else null,
        },
        .type_params = tps_owned,
        .params = try params.toOwnedSlice(alloc),
        .ret = ret_tree,
        .doc = try alloc.dupe(u8, std.mem.trimEnd(u8, doc_buf.items, "\n")),
        .variadic = variadic,
        .core_key = core_key,
        .default_values = try defaults.toOwnedSlice(alloc),
        .f = undefined,
    };
}

/// markdown is the authoring form; strip fences and dedent the code block
/// so docgen keeps rendering the prose/code shape it already knows
fn docFromMarkdown(alloc: std.mem.Allocator, doc: *std.ArrayList(u8)) !void {
    const raw = try alloc.dupe(u8, doc.items);
    defer alloc.free(raw);
    const fence = std.mem.indexOf(u8, raw, "```") orelse return;
    const code_rest = raw[fence + 3 ..];
    const code_start: usize = if (code_rest.len > 0 and code_rest[0] == '\n') 1 else 0;
    const code_body = code_rest[code_start..];
    const close = std.mem.indexOf(u8, code_body, "```") orelse return error.BadDoc;
    const code = code_body[0..close];
    const prose = std.mem.trimEnd(u8, raw[0..fence], "\n");

    var min_indent: usize = std.math.maxInt(usize);
    {
        var it = std.mem.splitScalar(u8, code, '\n');
        while (it.next()) |l| {
            if (l.len == 0) continue;
            var n: usize = 0;
            while (n < l.len and l[n] == ' ') n += 1;
            if (n < min_indent) min_indent = n;
        }
    }
    if (min_indent == std.math.maxInt(usize)) min_indent = 0;

    doc.clearRetainingCapacity();
    try doc.appendSlice(alloc, prose);
    try doc.appendSlice(alloc, "\n\n");
    var it = std.mem.splitScalar(u8, code, '\n');
    while (it.next()) |l| {
        if (l.len >= min_indent) try doc.appendSlice(alloc, l[min_indent..]);
        if (it.peek() != null) try doc.append(alloc, '\n');
    }
}

// -- [register] --------------------------------------------------------------

/// returns a Data value to anchor the metatable at `target`. the
/// value itself is discarded; only the metatable slot matters
pub const PrototypeFn = fn (target: TypeSpec, vm: *revo.VM) anyerror!revo.Data;

pub fn registerAll(
    vm: *revo.VM,
    groups: []const []const FnSpec,
    prototype: PrototypeFn,
) !void {
    var module_funcs: std.StringHashMapUnmanaged(std.ArrayList(ModuleEntry)) = .empty;
    var module_calls: std.StringHashMapUnmanaged(revo.memory.FunctionID) = .empty;
    var indexers: std.AutoHashMapUnmanaged(TypeSpec, revo.memory.FunctionID) = .empty;
    var global_funcs: std.ArrayList(GlobalEntry) = .empty;

    defer {
        var mit = module_funcs.iterator();
        while (mit.next()) |e| e.value_ptr.deinit(vm.runtime.alloc);
        module_funcs.deinit(vm.runtime.alloc);
        module_calls.deinit(vm.runtime.alloc);
        indexers.deinit(vm.runtime.alloc);
        global_funcs.deinit(vm.runtime.alloc);
    }

    for (groups) |specs| {
        for (specs) |spec| {
            const head = spec.head;
            const fn_id = try vm.installHost(spec.name, spec.f);
            switch (head.kind) {
                .global => try global_funcs.append(vm.runtime.alloc, .{ .name = spec.name, .fn_id = fn_id }),
                .module => {
                    if (spec.core_key == .__call) {
                        try module_calls.put(vm.runtime.alloc, head.module.?, fn_id);
                    } else {
                        const gop = try module_funcs.getOrPutValue(vm.runtime.alloc, head.module.?, .empty);
                        try gop.value_ptr.append(vm.runtime.alloc, .{ .name = spec.name, .fn_id = fn_id });
                    }
                },
                .method => if (spec.core_key == .__index) {
                    try indexers.put(vm.runtime.alloc, head.target.?, fn_id);
                } else {
                    return error.SpecMethodUnplaceable;
                },
            }
        }
    }

    for (global_funcs.items) |gf| try vm.registerGlobal(gf.name, gf.fn_id);

    {
        var it = module_funcs.iterator();
        while (it.next()) |entry| {
            const table_id = try vm.ensureModule(entry.key_ptr.*);
            for (entry.value_ptr.items) |f| try vm.putInTable(table_id, f.name, f.fn_id);

            if (module_calls.get(entry.key_ptr.*)) |call_fn_id| {
                const mt_id = try vm.tables.create();
                try vm.putInTableAtom(mt_id, @intFromEnum(revo.core_atoms.__call), call_fn_id);
                try vm.setMetatable(Data.new.table(table_id), mt_id);
            }
        }
    }

    {
        // the type metatable for each primitive iS its module table, so a
        // dynamic `x:method()` resolves in one `getRaw`. the numeric-indexing
        // natives are the only `__index` holders and live inside the module
        // table, keeping the fallback path identical for all four targets
        const primitives = [_]TypeSpec{ .number, .string, .tuple, .table };
        for (primitives) |target| {
            const module_tid = moduleTableFor(vm, target) orelse continue;
            if (indexers.get(target)) |fn_id| {
                try vm.putInTableAtom(module_tid, @intFromEnum(revo.core_atoms.__index), fn_id);
            }
            try vm.setMetatable(try prototype(target, vm), module_tid);
        }
    }
}

/// the module table for a primitive target, if one is registered
fn moduleTableFor(vm: *revo.VM, target: TypeSpec) ?revo.memory.TableID {
    const name = switch (target) {
        .number => "number",
        .string => "string",
        .tuple => "tuple",
        .table => "table",
        else => return null,
    };
    const val = vm.stdlib_globals.get(vm.internAtom(name) catch return null) orelse return null;
    return val.asTable();
}

const ModuleEntry = struct {
    name: []const u8,
    fn_id: revo.memory.FunctionID,
};
const GlobalEntry = struct {
    name: []const u8,
    fn_id: revo.memory.FunctionID,
};

// -- [test] ------------------------------------------------------------------

const testing = @import("std").testing;

test "parseGroup round trip: sig, params, doc, variadic, core key" {
    const src =
        \\# random comment is skipped
        \\#* single-line doc *#
        \\pub declare iter.range = fn(bound: num, rest: num...) -> function
        \\
        \\#*
        \\finds first occurrence
        \\with a second line
        \\*#
        \\pub declare string:__index = fn(self: string, idx: any) -> string
        \\#*
        \\converts value
        \\
        \\```
        \\fizz(1) => 2
        \\```
        \\*#
        \\pub declare num.__call = fn(value: any) -> num
        \\
        \\#* generic suffix *#
        \\pub declare tuple.unwrap_err[T] = fn(self: (:err, T)) -> T
        \\
        \\#* escaped "quotes" *#
        \\pub declare debug = fn() -> table
        \\
        \\#* optional input *#
        \\pub declare maybe = fn(?opts: table...) -> !string
    ;
    const specs = try parseGroup(testing.allocator, src);
    defer {
        for (specs) |s| s.deinit(testing.allocator);
        testing.allocator.free(specs);
    }
    try testing.expectEqual(@as(usize, 6), specs.len);

    const range = specs[0];
    try testing.expectEqualStrings("range", range.name);
    try testing.expectEqualStrings("iter.range(bound: num, rest: num...) -> function", range.sig);
    try testing.expectEqual(@as(usize, 2), range.params.len);
    try testing.expectEqualStrings("bound", range.params[0].name);
    try testing.expectEqualStrings("num", range.params[0].type_name.?.kind.named);
    try testing.expectEqualStrings("rest", range.params[1].name);
    try testing.expect(range.params[1].variadic);
    try testing.expectEqualStrings("num", range.params[1].type_name.?.kind.named);
    try testing.expect(range.variadic);
    try testing.expectEqualStrings("single-line doc", range.doc);

    const idx = specs[1];
    try testing.expectEqualStrings("__index", idx.name);
    try testing.expectEqual(revo.core_atoms.__index, idx.core_key.?);
    try testing.expectEqualStrings("finds first occurrence\nwith a second line", idx.doc);

    const call = specs[2];
    try testing.expectEqualStrings("num.__call(value: any) -> num", call.sig);
    try testing.expectEqual(revo.core_atoms.__call, call.core_key.?);
    try testing.expectEqualStrings("converts value\n\nfizz(1) => 2", call.doc);

    const unwrap_err = specs[3];
    try testing.expectEqualStrings("tuple.unwrap_err[T](self: (:err, T)) -> T", unwrap_err.sig);
    try testing.expectEqualStrings("unwrap_err", unwrap_err.name);
    var ubuf = std.Io.Writer.Allocating.init(testing.allocator);
    defer ubuf.deinit();
    try revo.lang.type_serde.printTypeExpr(unwrap_err.params[0].type_name.?, &ubuf.writer);
    try testing.expectEqualStrings("(:err, T)", ubuf.written());
    ubuf.clearRetainingCapacity();
    try revo.lang.type_serde.printTypeExpr(unwrap_err.ret.?, &ubuf.writer);
    try testing.expectEqualStrings("T", ubuf.written());
    try testing.expect(!unwrap_err.variadic);

    const debug = specs[4];
    try testing.expectEqualStrings("debug() -> table", debug.sig);
    try testing.expectEqual(@as(usize, 0), debug.params.len);
    try testing.expectEqualStrings("escaped \"quotes\"", debug.doc);

    const maybe = specs[5];
    try testing.expectEqualStrings("maybe(?opts: table...) -> !string", maybe.sig);
    try testing.expectEqualStrings("opts", maybe.params[0].name);
    try testing.expect(maybe.params[0].optional);
    try testing.expect(maybe.params[0].variadic);
    try testing.expect(maybe.variadic);
    var mbuf = std.Io.Writer.Allocating.init(testing.allocator);
    defer mbuf.deinit();
    try revo.lang.type_serde.printTypeExpr(maybe.params[0].type_name.?, &mbuf.writer);
    try testing.expectEqualStrings("table", mbuf.written());
}

test "loadAllSpecs pairs every spec with its impl" {
    const groups = try loadAllSpecs(testing.allocator);
    var count: usize = 0;
    for (full_specs) |g| for (g) |*s| {
        try testing.expect(s.sig.len > 0);
        count += 1;
    };
    try testing.expect(count > 100);
    try testing.expectEqualStrings("floor", find("floor").?.name);
    freeLoadedSpecs(testing.allocator, groups);
}
