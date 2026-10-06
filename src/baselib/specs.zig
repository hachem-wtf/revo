//!
//! welcome to baselib as data
//!
//! ~ sigs and docs live in `src/baselib/base.rv`
//!   one `pub declare mod = { ... }` table per module in a single file
//!   (root/os globals and `pub type` aliases stay flat)
//! ~ zig supplies impls only (`pub const impls: []const specs.Impl` per file)
//! ~ each spec stores the whole RHS type once and derives sig text,
//!   variadic-ness and core keys from it, so new shapes need no new fields
//! ~ `loadAllSpecs` merges the two at boot
//!   a missing or orphaned impl is a hard error,
//!   so docs can't drift from the runtime
//! ~ the primitive type metatable *is* the module table, so dynamic
//!   `x:method()` dispatch is one direct `getRaw`; numeric indexing is
//!   the exception, via the `__index` native stashed inside it
//!

const std = @import("std");

const ast = @import("../lang/ast.zig");
const builtin = @import("builtin");
const revo = @import("../root.zig");
const Value = revo.Value;
const root = @import("root.zig");
const ParamType = root.host.ParamType;
const HostFunc = root.host.HostFunc;

pub const regex_on = @import("build_options").regex;
pub const ffi_on = @import("build_options").ffi;
pub const http_on = !revo.is_freestanding;
pub const fs_on = !revo.is_freestanding;
pub const net_on = !revo.is_freestanding;

/// the zig side of one spec: registry key + implementation
pub const Impl = struct {
    name: []const u8,
    f: HostFunc,
};

pub const Group = struct {
    name: []const u8,
    src: []const u8,
    /// searched in order, keeping the old pairing order; disabled modules
    ///   contribute empty slices
    impls: []const []const Impl,

    fn init(name: []const u8, src: []const u8, impls: []const []const Impl) Group {
        return .{ .name = name, .src = src, .impls = impls };
    }
};

/// the whole surface in one file; `re`/`ffi` specs are filtered at load when
/// regex/ffi are off so the mvzr/io chain never reaches targets like
/// freestanding wasm
pub const groups: []const Group = &.{
    Group.init("std", @embedFile("base.rv"), &.{
        @import("root.zig").root_impls,
        @import("root.zig").os_impls,
        if (regex_on) @import("regex.zig").impls else &.{},
        if (ffi_on) @import("ffi_lib.zig").impls else &.{},
        @import("number.zig").impls,
        @import("string.zig").impls,
        @import("table.zig").impls,
        @import("dataframe.zig").impls,
        @import("iter.zig").impls,
        @import("math.zig").impls,
        @import("stats.zig").impls,
        @import("json.zig").impls,
        @import("csv.zig").impls,
        @import("time.zig").impls,
        @import("datetime.zig").impls,
        @import("net.zig").impls,
        if (http_on) @import("http.zig").impls else &.{},
        @import("uri.zig").impls,
        @import("fs.zig").impls,
        @import("revo.zig").impls,
        @import("compress.zig").impls,
        @import("rng.zig").impls,
        @import("argparse.zig").impls,
    }),
};

/// merged, runtime view of the baselib surface; built by `loadAllSpecs`
pub var full_specs: []const []const FnSpec = &.{};

var permanent_cache: ?[]const []const FnSpec = null;

pub fn loadAllSpecs(caller_alloc: std.mem.Allocator) ![]const []const FnSpec {
    if (permanent_cache) |cached| {
        full_specs = cached;
        return cached;
    }

    const pa = if (revo.is_freestanding) caller_alloc else std.heap.page_allocator;

    var loaded = try std.ArrayList([]const FnSpec).initCapacity(pa, groups.len);
    errdefer {
        for (loaded.items) |g| {
            for (g) |s| s.deinit(pa);
            pa.free(g);
        }
        loaded.deinit(pa);
    }
    for (groups) |ig| {
        var specs = parseGroup(pa, ig.src) catch |err| {
            if (comptime !revo.is_freestanding)
                std.debug.print("iface group '{s}' failed to parse: {s}\n", .{ ig.name, @errorName(err) });
            return err;
        };
        specs = try dropDisabledModules(pa, specs);
        for (specs, 0..) |*s, i| {
            if (s.is_type) continue;
            var k: usize = 0;

            if (i > 0) for (specs[0..i]) |other| {
                if (other.is_type) continue;
                if (std.mem.eql(u8, other.name, s.name)) k += 1;
            };

            s.f = implFor(ig.impls, s, k) orelse {
                if (comptime !revo.is_freestanding) {
                    var err_buf = std.Io.Writer.Allocating.init(pa);
                    defer err_buf.deinit();
                    renderSignature(&err_buf.writer, s.*) catch {};

                    std.debug.print("missing {s}\n", .{err_buf.written()});
                }
                @panic("missing an std def");
            };
            try checkImplSig(s.*);
        }
        for (ig.impls) |slice| {
            for (slice) |imp| {
                if (findSpec(specs, imp.name) == null) return error.StdlibImplUnused;
            }
        }
        try loaded.append(pa, specs);
    }
    const owned = try loaded.toOwnedSlice(pa);
    permanent_cache = owned;
    full_specs = owned;
    return owned;
}

/// permanent cache
/// the cache lives in page_allocator so no debug allocator tracks it
pub fn freeLoadedSpecs(_: std.mem.Allocator, _: []const []const FnSpec) void {}

/// spans of every `pub macro` / `pub proc` decl in one source
/// . span values only
/// , no lifetimes involved
fn collectMacroSpans(alloc: std.mem.Allocator, src: []const u8) ![]ast.Span {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const parsed = try revo.lang.parseSourceReport(arena.allocator(), src, .{});

    const tree = switch (parsed) {
        .ok => |node| node,
        .err => return error.IfaceParseFailed,
    };

    const items: []const *const revo.lang.Node = if (tree.expr == .block) tree.expr.block else &.{tree};
    var out = std.ArrayList(ast.Span).empty;
    errdefer out.deinit(alloc);

    for (items) |item| {
        if (item.expr != .decl) continue;
        const d = item.expr.decl;
        if (!d.pub_) continue;

        switch (d.inner.expr) {
            .proc_macro => try out.append(alloc, item.span),
            else => {},
        }
    }
    return out.toOwnedSlice(alloc);
}

var macro_sources_cache: ?[]const []const u8 = null;

/// source slices of every `pub macro` / `pub proc` across embedded groups
pub fn macroSources(caller_alloc: std.mem.Allocator) ![]const []const u8 {
    if (macro_sources_cache) |cached| return cached;

    const pa = if (revo.is_freestanding) caller_alloc else std.heap.page_allocator;

    var out = std.ArrayList([]const u8).empty;
    errdefer out.deinit(pa);
    for (groups) |g| {
        // happy path
        //   macro decls need their keyword spelled out, so most
        //   groups skip the parse entirely (prose mentions still parse)
        if (std.mem.find(u8, g.src, "macro") == null and
            std.mem.find(u8, g.src, "proc") == null) continue;
        const spans = try collectMacroSpans(pa, g.src);
        defer pa.free(spans);
        for (spans) |span| try out.append(pa, g.src[span.start..span.end]);
    }
    const owned = try out.toOwnedSlice(pa);
    macro_sources_cache = owned;
    return owned;
}

/// registry key for impl pairing
/// , derived from the head: `fs.open`, else the bare name
fn headKey(spec: *const FnSpec, buf: []u8) []const u8 {
    return switch (spec.head.kind) {
        .global => spec.name,
        .namespaced => std.mem.print(buf, "{s}.{s}", .{ spec.head.module.?, spec.name }) catch spec.name,
    };
}

/// impl registered under the full head like `fs.stat` pairs outright
/// otherwise the k-th spec with this name takes the k-th bare-named impl.
/// slices are searched in group order, preserving the old per-group pairing.
fn implFor(impls: []const []const Impl, spec: *const FnSpec, k: usize) ?HostFunc {
    var key_buf: [256]u8 = undefined;
    const head = headKey(spec, &key_buf);
    for (impls) |slice| {
        for (slice) |imp| if (std.mem.eql(u8, imp.name, head)) return imp.f;
    }
    var seen: usize = 0;
    for (impls) |slice| {
        for (slice) |imp| {
            if (!std.mem.eql(u8, imp.name, spec.name)) continue;
            if (seen == k) return imp.f;
            seen += 1;
        }
    }
    return null;
}

/// the surface and the zig impl must agree on the shape
///
/// only two things are actually promised, so only two are checked:
///   the impl never needs more args than the surface lets you pass,
///   and a declared `...` really is open ended
///
/// optionals are exempt on purpose: the surface spells them nilable
/// (`mode: string?`) where the host marks them optional or variadic,
/// and both are the same promise
const checkable_types: std.StaticStringMap(ParamType) = std.StaticStringMap(ParamType).initComptime(.{
    .{ "number", .number },
    .{ "num", .number },
    .{ "int", .number },
    .{ "string", .string },
    .{ "bool", .bool },
    .{ "atom", .atom },
    .{ "table", .table },
    .{ "function", .function },
    .{ "resource", .resource },
});

/// stderr is the test runner's own channel, a print from inside a test
///   corrupts the build-server protocol, so tests stay quiet
fn note(comptime format: []const u8, args: anytype) void {
    if (builtin.is_test) return;
    std.debug.print(format, args);
}

/// null when the declared type is richer than a ParamType can say
fn declaredParamType(te: ?*ast.TypeExpr) ?ParamType {
    const t = te orelse return null;
    return switch (t.kind) {
        .named => |n| checkable_types.get(n),
        .atom => .atom,
        else => null,
    };
}

fn checkImplSig(spec: FnSpec) !void {
    // metatable slots prepend the receiver and modules disagree on whether
    // the surface spells it out, so only plain members are comparable
    if (coreKey(&spec) != null) return;
    const fnty = switch (spec.type.kind) {
        .function => |f| f,
        else => return,
    };
    var key_buf: [256]u8 = undefined;
    const key = headKey(&spec, &key_buf);
    const params = fnty.params;
    const variadic = params.len > 0 and params[params.len - 1].variadic;
    if (spec.f.arity > params.len or (variadic and !spec.f.variadic)) {
        note("sig shape mismatch on {s}: surface allows {d} params{s}, impl needs {d}\n", .{
            key, params.len, if (variadic) " variadic" else "", spec.f.arity,
        });
        return error.ImplSigMismatch;
    }
    // a variadic impl types only its fixed prefix, the open tail rides along
    const typed_n = @min(params.len, spec.f.param_types.len);
    for (params[0..typed_n], spec.f.param_types[0..typed_n]) |p, want| {
        // `.any` on the impl side means it range-checks the arg itself
        if (want.toTag() == (@as(ParamType, .any)).toTag()) continue;
        const got = declaredParamType(p.type_name) orelse continue;
        if (got.toTag() == want.toTag()) continue;
        note("sig param mismatch on {s}: `{s}` declares {s}, impl wants {s}\n", .{
            key, p.name, @tagName(got), @tagName(want),
        });
        return error.ImplSigMismatch;
    }
}

/// drop specs of compiled-out modules; `re`/`ffi` declare no globals or
/// methods, so a namespaced-module match is exact
fn dropDisabledModules(alloc: std.mem.Allocator, specs: []FnSpec) ![]FnSpec {
    var kept = std.ArrayList(FnSpec).empty;
    errdefer kept.deinit(alloc);
    for (specs) |s| {
        const disabled = s.head.kind == .namespaced and s.head.module != null and
            ((std.mem.eql(u8, s.head.module.?, "re") and !regex_on) or
                (std.mem.eql(u8, s.head.module.?, "ffi") and !ffi_on) or
                (std.mem.eql(u8, s.head.module.?, "http") and !http_on) or
                (std.mem.eql(u8, s.head.module.?, "fs") and !fs_on) or
                (std.mem.eql(u8, s.head.module.?, "file") and !fs_on) or
                (std.mem.eql(u8, s.head.module.?, "net") and !net_on) or
                (std.mem.eql(u8, s.head.module.?, "socket") and !net_on));
        if (disabled) {
            s.deinit(alloc);
            continue;
        }
        try kept.append(alloc, s);
    }
    alloc.free(specs);
    return kept.toOwnedSlice(alloc);
}

fn findSpec(specs: []const FnSpec, impl_name: []const u8) ?*const FnSpec {
    var key_buf: [256]u8 = undefined;
    for (specs) |*s| {
        if (s.is_type) continue;
        if (std.mem.eql(u8, s.name, impl_name)) return s;
        if (std.mem.eql(u8, headKey(s, &key_buf), impl_name)) return s;
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

/// true when `name` heads a baselib module table; drives the module hover card
pub fn isModule(name: []const u8) bool {
    for (full_specs) |group| for (group) |*spec| {
        if (spec.head.kind == .namespaced) if (spec.head.module) |m| {
            if (std.mem.eql(u8, m, name)) return true;
        };
    };
    return false;
}

/// first callable match wins
/// ; type-only aliases are not values
pub fn findFn(name: []const u8) ?*const FnSpec {
    for (full_specs) |group| for (group) |*spec| {
        if (spec.is_type) continue;
        if (std.mem.eql(u8, spec.name, name)) return spec;
    };
    return null;
}

/// qualified lookup for help + repl
/// `fs.open`, `file.stat`
pub fn findQualified(name: []const u8) ?*const FnSpec {
    var sep: ?usize = null;
    var i = name.len;
    while (i > 0) {
        i -= 1;
        if (name[i] == '.') {
            sep = i;
            break;
        }
    }
    if (sep) |s| {
        if (s == 0 or s + 1 >= name.len) return null;
        const mod = name[0..s];
        const member = name[s + 1 ..];

        for (full_specs) |group| for (group) |*spec| {
            if (!std.mem.eql(u8, spec.name, member)) continue;

            if (spec.head.kind == .namespaced) if (spec.head.module) |m| {
                if (std.mem.eql(u8, m, mod)) return spec;
            };
        };
        return null;
    }
    for (full_specs) |group| for (group) |*spec| {
        if (spec.head.kind != .global) continue;
        if (std.mem.eql(u8, spec.name, name)) return spec;
    };
    return null;
}

/// the doc of a module table, "" when it has none; borrowed from the sig source
pub fn moduleDoc(mod: []const u8) []const u8 {
    for (full_specs) |group| for (group) |*spec| {
        if (spec.head.kind == .namespaced) if (spec.head.module) |m| {
            if (std.mem.eql(u8, m, mod)) return spec.module_doc;
        };
    };
    return "";
}

/// `fs.open(path: string) -> !table` for fns,
///   the bare head for type-only aliases
/// . computed from the stored type, never stored
/// , so new type shapes render without new code
pub fn renderSignature(w: *std.Io.Writer, spec: FnSpec) !void {
    try renderSignatureInner(w, spec);
}

/// head plus `<T>` suffix: `fs.open`, `table.unwrap_err<T>`
fn renderHead(w: *std.Io.Writer, spec: FnSpec) !void {
    switch (spec.head.kind) {
        .global => try w.writeAll(spec.name),
        .namespaced => try w.print("{s}.{s}", .{ spec.head.module.?, spec.name }),
    }
    if (spec.type_params.len > 0) {
        try w.writeByte('<');
        for (spec.type_params, 0..) |tp, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll(tp);
        }
        try w.writeByte('>');
    }
}

fn renderSignatureInner(w: *std.Io.Writer, spec: FnSpec) !void {
    try renderHead(w, spec);
    if (spec.is_type) return;
    const f = spec.type.kind.function;
    try w.writeAll("(");

    for (f.params, 0..) |p, i| {
        if (i > 0) try w.writeAll(", ");
        if (p.optional) try w.writeByte('?');
        try w.writeAll(p.name);
        if (p.type_name) |tn| {
            try w.writeAll(": ");
            try revo.lang.ast.printTypeExpr(tn, w);
        }
        if (p.variadic) try w.writeAll("...");
    }
    try w.writeAll(")");
    if (f.return_type) |r| {
        try w.writeAll(" -> ");
        try revo.lang.ast.printTypeExpr(r, w);
    }
}

/// `true` when any fn param is variadic; derived from the stored type
pub fn isVariadic(spec: *const FnSpec) bool {
    if (spec.is_type) return false;
    for (spec.type.kind.function.params) |p| if (p.variadic) return true;
    return false;
}

/// metatable key for `__` names, validated at parse time; null otherwise
pub fn coreKey(spec: *const FnSpec) ?revo.CoreAtoms {
    if (!std.mem.startsWith(u8, spec.name, "__")) return null;
    return std.meta.stringToEnum(revo.CoreAtoms, spec.name);
}

pub const FnKind = enum { global, namespaced };

/// who a spec belongs to, derived once from the declare head at parse time
pub const Head = struct {
    kind: FnKind,
    module: ?[]const u8 = null,
};

/// one declaration from the sig surface (`base.rv`)
pub const FnSpec = struct {
    name: []const u8,
    head: Head,
    type_params: []const []const u8,
    type: *ast.TypeExpr,
    is_type: bool = false,
    doc: []const u8 = "",
    module_doc: []const u8 = "",
    f: HostFunc,

    /// release one spec's owned strings and trees, not the spec struct itself
    /// `module_doc` is borrowed from the docs pass, never freed here
    pub fn deinit(self: *const FnSpec, alloc: std.mem.Allocator) void {
        alloc.free(self.name);

        if (self.head.module) |m| alloc.free(m);
        for (self.type_params) |tp| alloc.free(tp);
        alloc.free(self.type_params);

        revo.lang.ast.freeTypeExpr(alloc, self.type);
        alloc.free(self.doc);
    }
};

// -- [iface] -----------------------------------------------------------------

/// parse one sig group and collect specs
fn parseGroup(alloc: std.mem.Allocator, src: []const u8) ![]FnSpec {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try revo.lang.parseSourceReport(a, src, .{});
    const root_node = switch (parsed) {
        .ok => |node| node,
        .err => return error.IfaceParseFailed,
    };

    return collectSpecs(alloc, root_node, true);
}

/// the spec surface of a parsed node
pub fn collectSpecs(alloc: std.mem.Allocator, node: *const revo.lang.Node, iface: bool) ![]FnSpec {
    var specs = std.ArrayList(FnSpec).empty;
    errdefer specs.deinit(alloc);

    const items: []const *const revo.lang.Node = if (node.expr != .block) &.{node} else node.expr.block;
    for (items) |item| {
        // method-style `fn math:twice(x)` parses to a bare assign_expr
        // , no decl wrapper
        // - only docgen collects these
        if (item.expr == .assign_expr) {
            if (iface) continue;
            const ae = item.expr.assign_expr;
            if (ae.value.expr != .fn_expr) continue;
            const t = ae.value.expr.fn_expr;
            if (t.doc == null) continue;

            const ix = switch (ae.target.expr) {
                .index => |x| x,
                else => continue,
            };

            if (ix.object.expr != .ident) continue;
            const key: []const u8 = switch (ix.key.expr) {
                .atom => |h| h,
                .ident => |n| n,
                else => continue,
            };

            // stack shell, declSpec clones what it keeps
            var shell = ast.TypeExpr{ .span = item.span, .kind = .{ .function = .{ .params = t.params, .return_type = t.return_type } } };
            const segs = [_][]const u8{ ix.object.expr.ident, key };
            const synth = ast.TypeAlias{
                .name = key,
                .name_span = item.span,
                .type_expr = &shell,
                .declare_head = .{ .module = &segs },
            };

            try specs.append(alloc, try declSpec(alloc, synth, t.doc, false));
            continue;
        }
        if (item.expr != .decl) continue;
        const d = item.expr.decl;
        switch (d.inner.expr) {
            .type_alias => |t| {
                if (d.kind == .declare_decl) {
                    // a module table desugars to one spec per field, sharing
                    //   the dotted `MOD.field` head (pairing, docs, metatables)
                    if (t.declare_head == null and t.type_expr.kind == .record) {
                        try expandTableDeclare(alloc, &specs, t, iface, d.doc orelse t.doc);
                    } else {
                        try specs.append(alloc, try declSpec(alloc, t, d.doc orelse t.doc, iface));
                    }
                } else if (d.kind == .type_alias_decl and d.pub_) {
                    try specs.append(alloc, try typeSpec(alloc, t, d.doc orelse t.doc));
                } else continue;
            },
            // macros ride along as source via macroSources, never as specs
            .proc_macro => {},
            .binding => |b| {
                const doc = d.doc orelse b.doc;
                if (iface) continue;
                if (doc == null) continue;
                if (b.target.expr != .ident) continue;
                if (b.value.expr == .fn_expr) {
                    const t = b.value.expr.fn_expr;
                    var shell = ast.TypeExpr{
                        .span = item.span,
                        .kind = .{ .function = .{ .params = t.params, .return_type = t.return_type } },
                    };

                    const synth = ast.TypeAlias{
                        .name = b.target.expr.ident,
                        .name_span = item.span,
                        .type_expr = &shell,
                    };
                    try specs.append(alloc, try declSpec(alloc, synth, doc, false));
                } else {
                    var shell = ast.TypeExpr{ .span = item.span, .kind = .{ .named = "any" } };
                    const synth = ast.TypeAlias{
                        .name = b.target.expr.ident,
                        .name_span = item.span,
                        .type_expr = &shell,
                    };
                    try specs.append(alloc, try declSpecRaw(alloc, synth, doc));
                }
            },
            else => {},
        }
    }
    return specs.toOwnedSlice(alloc);
}

/// `pub type` aliases, type-namespace, never strict, even for fn rhs
fn typeSpec(alloc: std.mem.Allocator, alias: ast.TypeAlias, doc: ?[]const u8) !FnSpec {
    return declSpecInner(alloc, alias, doc, false, true);
}

fn expandTableDeclare(
    alloc: std.mem.Allocator,
    specs: *std.ArrayList(FnSpec),
    t: ast.TypeAlias,
    iface: bool,
    module_doc: ?[]const u8,
) !void {
    if (t.declare_tps.len > 0) return error.DuplicateGenericParams;
    const parent = t.name;

    for (t.type_expr.kind.record) |f| {
        // positional array entries (`{ number, number }`) are not members
        if (f.name.len == 0) continue;
        var all_digits = true;
        for (f.name) |c| if (!std.ascii.isDigit(c)) {
            all_digits = false;
            break;
        };

        if (all_digits) continue;
        const segs = try alloc.alloc([]const u8, 2);
        defer alloc.free(segs);
        segs[0] = parent;
        segs[1] = f.name;

        const synth = ast.TypeAlias{
            .name = f.name,
            .name_span = t.name_span,
            .type_expr = f.type_expr,
            .doc = f.doc,
            .declare_head = .{ .module = segs },
        };
        // borrowed from src
        var spec = if (f.type_expr.kind == .function)
            try declSpec(alloc, synth, f.doc, iface)
        else
            // nested alias (`Stat: {...}`); same as `pub type MOD.Stat`
            try typeSpec(alloc, synth, f.doc);
        spec.module_doc = module_doc orelse "";
        try specs.append(alloc, spec);
    }
}

/// the single way declarations enter a spec
fn declSpec(alloc: std.mem.Allocator, alias: ast.TypeAlias, doc: ?[]const u8, strict: bool) !FnSpec {
    return declSpecInner(alloc, alias, doc, strict, false);
}

fn declSpecInner(alloc: std.mem.Allocator, alias: ast.TypeAlias, doc: ?[]const u8, strict: bool, force_type: bool) !FnSpec {
    // bare member name is shared logic (ast.bareName)
    // ; the parser always produces 2+ segments for module heads
    // , so no length guard here
    const name: []const u8 = ast.bareName(alias);
    var head: Head = .{ .kind = .global };
    if (alias.declare_head) |dh| switch (dh) {
        .module => |segs| {
            head = .{ .kind = .namespaced, .module = try std.mem.join(alloc, ".", segs[0 .. segs.len - 1]) };
        },
    };
    errdefer if (head.module) |m| alloc.free(m);

    if (strict and alias.type_expr.kind == .function) {
        for (alias.type_expr.kind.function.params) |p| {
            if (p.type_name == null) return error.IfaceParamNotTyped;
        }
    }

    if (std.mem.startsWith(u8, name, "__")) {
        // a __-name on a target must be a real metatable slot
        // ; bare unknown __names are plain globals (__internal_dotest etc)
        if (std.meta.stringToEnum(revo.CoreAtoms, name) == null and head.kind != .global) {
            if (head.module) |m| alloc.free(m);
            return error.BadCoreKey;
        }
    }

    // tps live on the head (`f<T> = ...`) or, for bare fn types, on the
    // type itself (`f = fn<T>(...)`); both is an error
    const fn_tps: []const []const u8 = if (alias.type_expr.kind == .function)
        alias.type_expr.kind.function.type_params
    else
        &.{};
    if (alias.declare_tps.len > 0 and fn_tps.len > 0) return error.DuplicateGenericParams;
    const src_tps = if (alias.declare_tps.len > 0) alias.declare_tps else fn_tps;
    const owned_tps = try alloc.alloc([]const u8, src_tps.len);
    errdefer alloc.free(owned_tps);
    for (src_tps, owned_tps) |tp, *dst| dst.* = try alloc.dupe(u8, tp);
    errdefer for (owned_tps) |tp| alloc.free(tp);

    const type_tree = try revo.lang.ast.cloneTypeExpr(alloc, alias.type_expr);
    errdefer revo.lang.ast.freeTypeExpr(alloc, type_tree);

    const is_type = force_type or type_tree.kind != .function;
    var doc_text: []const u8 = "";
    if (is_type) {
        var doc_buf = std.Io.Writer.Allocating.init(alloc);
        defer doc_buf.deinit();
        try doc_buf.writer.writeAll("alias for\n```revo\n");

        try revo.lang.ast.printTypeExpr(type_tree, &doc_buf.writer);
        try doc_buf.writer.writeAll("\n```");

        if (doc) |d| {
            try doc_buf.writer.writeAll("\n\n");
            try doc_buf.writer.writeAll(d);
        }

        doc_text = try alloc.dupe(u8, std.mem.trimEnd(u8, doc_buf.written(), "\n"));
    } else if (doc) |d| {
        var doc_buf = std.ArrayList(u8).empty;
        defer doc_buf.deinit(alloc);

        try doc_buf.appendSlice(alloc, d);
        try docFromMarkdown(alloc, &doc_buf);

        doc_text = try alloc.dupe(u8, std.mem.trimEnd(u8, doc_buf.items, "\n"));
    } else {
        doc_text = try alloc.dupe(u8, "");
    }
    errdefer alloc.free(doc_text);

    return .{
        .name = try alloc.dupe(u8, name),
        .head = .{
            .kind = head.kind,
            .module = head.module,
        },
        .type_params = owned_tps,
        .type = type_tree,
        .is_type = is_type,
        .doc = doc_text,
        .f = undefined,
    };
}

/// docs-mode const values (`const a = 5` with `#*`)
fn declSpecRaw(alloc: std.mem.Allocator, alias: ast.TypeAlias, doc: ?[]const u8) !FnSpec {
    var doc_text: []const u8 = "";
    if (doc) |d| {
        var doc_buf = std.ArrayList(u8).empty;
        defer doc_buf.deinit(alloc);
        try doc_buf.appendSlice(alloc, d);
        try docFromMarkdown(alloc, &doc_buf);
        doc_text = try alloc.dupe(u8, std.mem.trimEnd(u8, doc_buf.items, "\n"));
    } else {
        doc_text = try alloc.dupe(u8, "");
    }
    errdefer alloc.free(doc_text);

    return .{
        .name = try alloc.dupe(u8, alias.name),
        .head = .{ .kind = .global },
        .type_params = &.{},
        .type = try revo.lang.ast.cloneTypeExpr(alloc, alias.type_expr),
        .is_type = true,
        .doc = doc_text,
        .f = undefined,
    };
}

/// docs runs over arbitrary user files
/// : per-file spec failures skip the file
///   , anything else (OOM etc) aborts
pub fn skippableForDocs(err: anyerror) bool {
    return switch (err) {
        error.IfaceParseFailed,
        error.IfaceParamNotTyped,
        error.BadCoreKey,
        error.BadDoc,
        error.DuplicateGenericParams,
        => true,
        else => false,
    };
}

/// markdown is the authoring form; strip fences and dedent the code block
/// so docgen keeps rendering the prose/code shape it already knows
fn docFromMarkdown(alloc: std.mem.Allocator, doc: *std.ArrayList(u8)) !void {
    const raw = try alloc.dupe(u8, doc.items);
    defer alloc.free(raw);
    const fence = std.mem.find(u8, raw, "```") orelse return;
    const code_rest = raw[fence + 3 ..];
    const code_start: usize = if (code_rest.len > 0 and code_rest[0] == '\n') 1 else 0;
    const code_body = code_rest[code_start..];
    const close = std.mem.find(u8, code_body, "```") orelse return error.BadDoc;
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

/// returns a Value value to anchor the metatable at `target`. the
/// value itself is discarded; only the metatable slot matters
pub const PrototypeFn = fn (target: ParamType, vm: *revo.VM) anyerror!revo.Value;

pub fn registerAll(
    vm: *revo.VM,
    spec_groups: []const []const FnSpec,
    prototype: PrototypeFn,
) !void {
    // plain names go in the table, `__` keys in its metatable, so new metamethods dont need no new arms anywhere
    var mod_entries: std.StringHashMapUnmanaged(std.ArrayList(ModEntry)) = .empty;
    var global_funcs: std.ArrayList(GlobalEntry) = .empty;

    defer {
        var mit = mod_entries.iterator();
        while (mit.next()) |e| e.value_ptr.deinit(vm.runtime.alloc);
        mod_entries.deinit(vm.runtime.alloc);

        global_funcs.deinit(vm.runtime.alloc);
    }

    for (spec_groups) |specs| {
        for (specs) |spec| {
            if (spec.is_type) continue;
            const head = spec.head;
            const fn_id = try vm.installHost(spec.name, spec.f);
            switch (head.kind) {
                .global => try global_funcs.append(vm.runtime.alloc, .{ .name = spec.name, .fn_id = fn_id }),
                .namespaced => {
                    const gop = try mod_entries.getOrPutValue(vm.runtime.alloc, head.module.?, .empty);
                    try gop.value_ptr.append(vm.runtime.alloc, .{ .name = spec.name, .atom = coreKey(&spec), .fn_id = fn_id });
                },
            }
        }
    }

    for (global_funcs.items) |gf| try vm.registerGlobal(gf.name, gf.fn_id);

    {
        var it = mod_entries.iterator();
        while (it.next()) |entry| {
            const table_id = try vm.ensureModule(entry.key_ptr.*);
            var has_meta = false;
            for (entry.value_ptr.items) |f| {
                if (f.atom != null) {
                    has_meta = true;
                } else {
                    try vm.putField(table_id, f.name, Value.new.function(f.fn_id));
                }
            }
            if (has_meta) {
                const mt_id = try vm.tables.create();
                for (entry.value_ptr.items) |f| {
                    if (f.atom) |atom| try vm.putInTable(mt_id, @backingInt(atom), f.fn_id);
                }
                try vm.setMetatable(Value.new.table(table_id), mt_id);
            }
        }
    }

    {
        // the type metatable for each primitive iS its module table
        // , so a dynamic `x:method()` dispatch gets a single direct `getRaw`
        const primitives = [_]ParamType{ .number, .string, .table };
        for (primitives) |target| {
            const module_tid = moduleTableFor(vm, target) orelse continue;
            try vm.setMetatable(try prototype(target, vm), module_tid);
        }
    }
}

/// the module table for a primitive target, if one is registered
fn moduleTableFor(vm: *revo.VM, target: ParamType) ?revo.memory.TableID {
    const name = target.moduleName() orelse return null;
    const val = vm.builtin_globals.get(vm.internAtom(name) catch return null) orelse return null;
    return val.asTable();
}

const ModEntry = struct {
    name: []const u8,
    atom: ?revo.CoreAtoms,
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
        \\pub declare string = {
        \\  #* metatable index *#
        \\  __index: fn(self: string, idx: any) -> string,
        \\}
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
        \\pub declare table.unwrap_err<T> = fn(self: {:err, T}) -> T
        \\
        \\#* escaped "quotes" *#
        \\pub declare debug_info = fn() -> table
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
    {
        const sig = try renderAlloc(testing.allocator, range);
        defer testing.allocator.free(sig);
        try testing.expectEqualStrings("iter.range(bound: num, rest: num...) -> function", sig);
    }
    try testing.expectEqual(@as(usize, 2), range.type.kind.function.params.len);
    try testing.expectEqualStrings("bound", range.type.kind.function.params[0].name);
    try testing.expectEqualStrings("num", range.type.kind.function.params[0].type_name.?.kind.named);
    try testing.expectEqualStrings("rest", range.type.kind.function.params[1].name);
    try testing.expect(range.type.kind.function.params[1].variadic);
    try testing.expectEqualStrings("num", range.type.kind.function.params[1].type_name.?.kind.named);
    try testing.expect(isVariadic(&range));
    try testing.expectEqualStrings("single-line doc", range.doc);

    const idx = specs[1];
    try testing.expectEqualStrings("__index", idx.name);
    try testing.expectEqual(revo.CoreAtoms.__index, coreKey(&idx).?);
    try testing.expectEqualStrings("metatable index", idx.doc);

    const call = specs[2];
    {
        const sig = try renderAlloc(testing.allocator, call);
        defer testing.allocator.free(sig);
        try testing.expectEqualStrings("num.__call(value: any) -> num", sig);
    }
    try testing.expectEqual(revo.CoreAtoms.__call, coreKey(&call).?);
    try testing.expectEqualStrings("converts value\n\nfizz(1) => 2", call.doc);

    const unwrap_err = specs[3];
    {
        const sig = try renderAlloc(testing.allocator, unwrap_err);
        defer testing.allocator.free(sig);
        try testing.expectEqualStrings("table.unwrap_err<T>(self: {:err, T}) -> T", sig);
    }
    try testing.expectEqualStrings("unwrap_err", unwrap_err.name);
    var ubuf = std.Io.Writer.Allocating.init(testing.allocator);
    defer ubuf.deinit();
    try revo.lang.ast.printTypeExpr(unwrap_err.type.kind.function.params[0].type_name.?, &ubuf.writer);
    try testing.expectEqualStrings("{:err, T}", ubuf.written());
    ubuf.clearRetainingCapacity();
    try revo.lang.ast.printTypeExpr(unwrap_err.type.kind.function.return_type.?, &ubuf.writer);
    try testing.expectEqualStrings("T", ubuf.written());
    try testing.expect(!isVariadic(&unwrap_err));

    const debug_info = specs[4];
    {
        const sig = try renderAlloc(testing.allocator, debug_info);
        defer testing.allocator.free(sig);
        try testing.expectEqualStrings("debug_info() -> table", sig);
    }
    try testing.expectEqual(@as(usize, 0), debug_info.type.kind.function.params.len);
    try testing.expectEqualStrings("escaped \"quotes\"", debug_info.doc);

    const maybe = specs[5];
    {
        const sig = try renderAlloc(testing.allocator, maybe);
        defer testing.allocator.free(sig);
        try testing.expectEqualStrings("maybe(?opts: table...) -> !string", sig);
    }
    try testing.expectEqualStrings("opts", maybe.type.kind.function.params[0].name);
    try testing.expect(maybe.type.kind.function.params[0].optional);
    try testing.expect(maybe.type.kind.function.params[0].variadic);
    try testing.expect(isVariadic(&maybe));
    var mbuf = std.Io.Writer.Allocating.init(testing.allocator);
    defer mbuf.deinit();
    try revo.lang.ast.printTypeExpr(maybe.type.kind.function.params[0].type_name.?, &mbuf.writer);
    try testing.expectEqualStrings("table", mbuf.written());
}

test "parseGroup accepts resource params and nested methods" {
    const src =
        \\pub declare total_add = fn(handle: resource, amount: num) -> num
        \\pub declare resource = {
        \\  close: fn(self: resource),
        \\}
    ;
    const specs = try parseGroup(testing.allocator, src);
    defer {
        for (specs) |s| s.deinit(testing.allocator);
        testing.allocator.free(specs);
    }
    try testing.expectEqual(@as(usize, 2), specs.len);
    try testing.expectEqualStrings("handle", specs[0].type.kind.function.params[0].name);
    try testing.expectEqualStrings("resource", specs[0].type.kind.function.params[0].type_name.?.kind.named);
    try testing.expectEqualStrings("close", specs[1].name);
}

fn renderAlloc(alloc: std.mem.Allocator, spec: FnSpec) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();
    try renderSignature(&buf.writer, spec);
    return alloc.dupe(u8, buf.written());
}

test "checkImplSig catches a surface that lies about the impl" {
    const cases = [_]struct { src: []const u8, f: HostFunc, bad: bool }{
        // impl needs two args where the surface offers one
        .{ .src = "pub declare fs.open = fn(path: string) -> !table", .bad = true, .f = .{
            .arity = 2,
            .param_types = &.{ .string, .string },
            .func = struct {
                fn call(_: []const Value, _: *revo.VM) anyerror!root.host.HostResult {
                    unreachable;
                }
            }.call,
        } },
        // a param the impl receives as a string, the surface says number
        .{ .src = "pub declare fs.exists? = fn(path: num) -> bool", .bad = true, .f = .{
            .arity = 1,
            .param_types = &.{.string},
            .func = struct {
                fn call(_: []const Value, _: *revo.VM) anyerror!root.host.HostResult {
                    unreachable;
                }
            }.call,
        } },
        // the honest shapes pass
        .{ .src = "pub declare fs.open = fn(path: string, mode: string?) -> !table", .bad = false, .f = .{
            .arity = 1,
            .param_types = &.{.string},
            .func = struct {
                fn call(_: []const Value, _: *revo.VM) anyerror!root.host.HostResult {
                    unreachable;
                }
            }.call,
        } },
        // a variadic impl backs a nilable optional, both say "maybe one more"
        .{ .src = "pub declare fs.open = fn(path: string, mode: string?) -> !table", .bad = false, .f = .{
            .arity = 1,
            .variadic = true,
            .param_types = &.{.string},
            .func = struct {
                fn call(_: []const Value, _: *revo.VM) anyerror!root.host.HostResult {
                    unreachable;
                }
            }.call,
        } },
        // and a declared `...` needs a variadic impl
        .{ .src = "pub declare fmt = fn(spec: string, args: any...) -> string", .bad = true, .f = .{
            .arity = 1,
            .param_types = &.{.string},
            .func = struct {
                fn call(_: []const Value, _: *revo.VM) anyerror!root.host.HostResult {
                    unreachable;
                }
            }.call,
        } },
    };

    for (cases) |c| {
        const specs = try parseGroup(testing.allocator, c.src);
        defer {
            for (specs) |s| s.deinit(testing.allocator);
            testing.allocator.free(specs);
        }
        try testing.expectEqual(@as(usize, 1), specs.len);
        specs[0].f = c.f;
        if (c.bad) {
            try testing.expectError(error.ImplSigMismatch, checkImplSig(specs[0]));
        } else {
            try checkImplSig(specs[0]);
        }
    }
}

test "parseGroup collects pub type as type-only alias" {
    const src =
        \\#* a port number *#
        \\pub type Port = num
        \\
        \\pub declare open = fn(path: string) -> string
        \\
        \\#* handler alias over fn type stays a type, not a callable *#
        \\pub type Handler = fn(x: num) -> num
        \\
        \\#* namespaced alias keeps its head with a bare name *#
        \\pub type uri.Hi = {n: string}
        \\
        \\type Private = num
    ;
    const specs = try parseGroup(testing.allocator, src);
    defer {
        for (specs) |s| s.deinit(testing.allocator);
        testing.allocator.free(specs);
    }
    try testing.expectEqual(@as(usize, 4), specs.len);

    const port = specs[0];
    try testing.expectEqualStrings("Port", port.name);
    try testing.expect(port.is_type);
    var pbuf = std.Io.Writer.Allocating.init(testing.allocator);
    defer pbuf.deinit();
    try revo.lang.ast.printTypeExpr(port.type, &pbuf.writer);
    try testing.expectEqualStrings("num", pbuf.written());

    const open = specs[1];
    try testing.expect(!open.is_type);
    {
        const sig = try renderAlloc(testing.allocator, open);
        defer testing.allocator.free(sig);
        try testing.expectEqualStrings("open(path: string) -> string", sig);
    }

    const handler = specs[2];
    try testing.expectEqualStrings("Handler", handler.name);
    try testing.expect(handler.is_type);
    try testing.expect(handler.type.kind == .function);

    const hi = specs[3];
    try testing.expect(hi.is_type);
    try testing.expectEqualStrings("Hi", hi.name);
    try testing.expect(hi.head.kind == .namespaced);
    try testing.expectEqualStrings("uri", hi.head.module.?);
    {
        const sig = try renderAlloc(testing.allocator, hi);
        defer testing.allocator.free(sig);
        try testing.expectEqualStrings("uri.Hi", sig);
    }
}

test "parseGroup expands table declare into headed specs" {
    const src =
        \\pub declare fs = {
        \\  #* opens a path *#
        \\  open: fn(path: string) -> !table,
        \\  Stat: { size: num },
        \\}
        \\
        \\pub declare string = {
        \\  #* length *#
        \\  len: fn(self: string) -> num,
        \\  at: fn<T>(self: table<T>, index: num) -> T | :undef,
        \\  __call: fn(value: any) -> string,
        \\}
    ;
    const specs = try parseGroup(testing.allocator, src);
    defer {
        for (specs) |s| s.deinit(testing.allocator);
        testing.allocator.free(specs);
    }
    try testing.expectEqual(@as(usize, 5), specs.len);

    const open = specs[0];
    try testing.expectEqualStrings("open", open.name);
    try testing.expect(!open.is_type);
    try testing.expect(open.head.kind == .namespaced);
    try testing.expectEqualStrings("fs", open.head.module.?);
    try testing.expectEqualStrings("opens a path", open.doc);

    const stat = specs[1];
    try testing.expect(stat.is_type);
    try testing.expectEqualStrings("Stat", stat.name);
    try testing.expect(stat.head.kind == .namespaced);
    try testing.expectEqualStrings("fs", stat.head.module.?);

    const len = specs[2];
    try testing.expectEqualStrings("len", len.name);
    try testing.expect(len.head.kind == .namespaced);
    try testing.expectEqualStrings("string", len.head.module.?);
    try testing.expectEqualStrings("length", len.doc);

    const at = specs[3];
    try testing.expectEqualStrings("at", at.name);
    try testing.expect(at.head.kind == .namespaced);
    try testing.expectEqualStrings("string", at.head.module.?);
    try testing.expectEqual(@as(usize, 1), at.type_params.len);
    try testing.expectEqualStrings("T", at.type_params[0]);

    const call = specs[4];
    try testing.expectEqualStrings("__call", call.name);
    try testing.expectEqual(revo.CoreAtoms.__call, coreKey(&call).?);

    {
        const sig = try renderAlloc(testing.allocator, open);
        defer testing.allocator.free(sig);
        try testing.expectEqualStrings("fs.open(path: string) -> !table", sig);
    }
}

test "module doc keeps paragraphs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\#*
        \\first paragraph
        \\
        \\second paragraph
        \\*#
        \\pub declare mymod = {
        \\  go: fn(n: num) -> num,
        \\}
    ;
    const parsed = try revo.lang.parseSourceReport(a, src, .{});
    const node = switch (parsed) {
        .ok => |n| n,
        .err => return error.IfaceParseFailed,
    };
    const specs = try collectSpecs(a, node, true);
    try testing.expectEqualStrings("first paragraph\n\nsecond paragraph", specs[0].module_doc);
}

test "moduleDoc finds table docs in the single file" {
    _ = try loadAllSpecs(testing.allocator);
    try testing.expectEqualStrings("filesystem access & ops", moduleDoc("fs"));
    try testing.expectEqualStrings("filesystem access & ops", moduleDoc("file"));
    // `re` must not match the `revo` table
    try testing.expectEqualStrings("regular expressions!", moduleDoc("re"));
    try testing.expect(moduleDoc("revo").len > 0);
    try testing.expectEqualStrings("numeric math", moduleDoc("math"));
    try testing.expectEqualStrings("command-line arguments parsing", moduleDoc("argparse"));
    try testing.expectEqualStrings("", moduleDoc("nosuchmod"));
    try testing.expectEqualStrings("", moduleDoc("root"));
}

test "collectMacroSpans finds pub procs only" {
    const src =
        \\pub proc uri.asdf!(m) do m end
        \\proc private!(m) do m end
        \\pub declare x = fn() -> num
    ;
    const spans = try collectMacroSpans(testing.allocator, src);
    defer testing.allocator.free(spans);
    try testing.expectEqual(@as(usize, 1), spans.len);
    try testing.expect(std.mem.find(u8, src[spans[0].start..spans[0].end], "uri.asdf!") != null);
}

test "loadAllSpecs pairs every spec with its impl" {
    const loaded = try loadAllSpecs(testing.allocator);
    var count: usize = 0;
    for (full_specs) |g| for (g) |*s| {
        var sig_buf = std.Io.Writer.Allocating.init(testing.allocator);
        defer sig_buf.deinit();
        try renderSignature(&sig_buf.writer, s.*);
        try testing.expect(sig_buf.written().len > 0);
        count += 1;
    };
    try testing.expect(count > 100);
    try testing.expectEqualStrings("floor", find("floor").?.name);
    freeLoadedSpecs(testing.allocator, loaded);
}
