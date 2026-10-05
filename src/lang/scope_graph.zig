//! scope graph? barely know her
//!   one map for what every name means, checker and compiler read the same one
//!
//! ~ stages keep their own string maps today and disagree sometimes
//!   , so bindings get recorded here once and every read agrees
//! ~ starts alongside the old maps, they go away one reader at a time

const std = @import("std");

const ast = @import("ast.zig");

pub const ScopeId = u32;
pub const DefId = u32;
pub const StrId = u32;

/// real lexical boundary or it does not exist
/// , transparent blocks declare into their parent, like the old bool skip did
pub const ScopeKind = enum {
    file,
    func,
    block,
    transparent,

    pub fn isTransparent(self: ScopeKind) bool {
        return self == .transparent;
    }
};

/// what a name denotes, kept coarse
/// , types live in TypeTable, slots stay in the compiler
pub const DefKind = enum {
    binding,
    function,
    param,
    type_alias,
    macro,
    import,
};

pub const Scope = struct {
    kind: ScopeKind,
    parent: ?ScopeId,
    span: ast.Span,
    members: std.AutoHashMap(StrId, DefId),
};

pub const Def = struct {
    name: StrId,
    kind: DefKind,
    scope: ScopeId,
    span: ast.Span,
    doc: ?[]const u8 = null,
};

/// compile-time name table
/// , runtime has its own atom interning in the vm, frontend stays pure
pub const Interner = struct {
    alloc: std.mem.Allocator,
    to_id: std.StringHashMap(StrId),
    names: std.ArrayList([]const u8),

    pub fn init(alloc: std.mem.Allocator) Interner {
        return .{ .alloc = alloc, .to_id = .init(alloc), .names = .empty };
    }

    pub fn deinit(self: *Interner) void {
        var it = self.to_id.iterator();
        while (it.next()) |e| self.alloc.free(e.key_ptr.*);
        self.to_id.deinit();
        self.names.deinit(self.alloc);
    }

    pub fn intern(self: *Interner, name: []const u8) !StrId {
        if (self.to_id.get(name)) |id| return id;
        const owned = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(owned);
        const id: StrId = @intCast(self.names.items.len);
        try self.names.append(self.alloc, owned);
        try self.to_id.put(owned, id);
        return id;
    }

    pub fn lookup(self: *const Interner, name: []const u8) ?StrId {
        return self.to_id.get(name);
    }

    pub fn get(self: *const Interner, id: StrId) []const u8 {
        return self.names.items[id];
    }
};

pub const ScopeGraph = struct {
    alloc: std.mem.Allocator,
    scopes: std.ArrayList(Scope),
    defs: std.ArrayList(Def),
    strings: Interner,
    files: std.AutoHashMap(StrId, ScopeId),

    pub fn init(alloc: std.mem.Allocator) ScopeGraph {
        return .{
            .alloc = alloc,
            .scopes = .empty,
            .defs = .empty,
            .strings = .init(alloc),
            .files = .init(alloc),
        };
    }

    pub fn deinit(self: *ScopeGraph) void {
        for (self.scopes.items) |*scope| scope.members.deinit();
        self.scopes.deinit(self.alloc);
        self.defs.deinit(self.alloc);
        self.strings.deinit();
        self.files.deinit();
    }

    /// root scope for a file, made once per name
    pub fn fileRoot(self: *ScopeGraph, name: []const u8, span: ast.Span) !ScopeId {
        const key = try self.strings.intern(name);
        if (self.files.get(key)) |id| return id;
        const id: ScopeId = @intCast(self.scopes.items.len);
        var members = std.AutoHashMap(StrId, DefId).init(self.alloc);
        errdefer members.deinit();
        try self.scopes.append(self.alloc, .{ .kind = .file, .parent = null, .span = span, .members = members });
        errdefer _ = self.scopes.pop();
        try self.files.put(key, id);
        return id;
    }

    /// nested scope under a parent
    pub fn childScope(self: *ScopeGraph, parent: ScopeId, kind: ScopeKind, span: ast.Span) !ScopeId {
        const id: ScopeId = @intCast(self.scopes.items.len);
        var members = std.AutoHashMap(StrId, DefId).init(self.alloc);
        errdefer members.deinit();
        try self.scopes.append(self.alloc, .{ .kind = kind, .parent = parent, .span = span, .members = members });
        return id;
    }

    /// record one binding
    /// , same scope twice replaces silently, like the old maps
    /// , transparent scopes declare into their nearest non-transparent ancestor
    /// , callers decide what counts, this only records
    pub fn declare(
        self: *ScopeGraph,
        scope: ScopeId,
        name: []const u8,
        kind: DefKind,
        span: ast.Span,
        doc: ?[]const u8,
    ) !DefId {
        const target = self.effectiveScope(scope);
        const key = try self.strings.intern(name);
        const id: DefId = @intCast(self.defs.items.len);
        try self.defs.append(self.alloc, .{ .name = key, .kind = kind, .scope = target, .span = span, .doc = doc });
        errdefer _ = self.defs.pop();
        try self.scopes.items[target].members.put(key, id);
        return id;
    }

    /// nearest non-transparent ancestor including self, file root never transparent
    pub fn effectiveScope(self: *const ScopeGraph, scope: ScopeId) ScopeId {
        var current: ScopeId = scope;
        while (self.scopes.items[current].kind.isTransparent()) {
            current = self.scopes.items[current].parent orelse return scope;
        }
        return current;
    }

    /// innermost-out lookup, first hit wins
    /// , transparent scopes hold no members by construction, skipped defensively
    pub fn resolve(self: *const ScopeGraph, scope: ScopeId, name: []const u8) ?DefId {
        const key = self.strings.lookup(name) orelse return null;
        var current: ?ScopeId = scope;
        while (current) |id| {
            const s = self.scopes.items[id];
            if (!s.kind.isTransparent()) {
                if (s.members.get(key)) |def| return def;
            }
            current = s.parent;
        }
        return null;
    }

    /// direct children of a scope, for export walks
    /// , linear scan, dozens of scopes per file at most
    pub fn children(self: *const ScopeGraph, parent: ScopeId, out: *std.ArrayList(ScopeId)) !void {
        for (self.scopes.items, 0..) |s, i| {
            if (s.parent != null and s.parent.? == parent) try out.append(self.alloc, @intCast(i));
        }
    }
};

test "graph records once, innermost wins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const span = ast.Span{ .start = 0, .end = 0, .line = 0, .column = 0 };

    var g = ScopeGraph.init(alloc);
    defer g.deinit();

    const file = try g.fileRoot("<test>", span);
    try std.testing.expectEqual(file, try g.fileRoot("<test>", span));

    _ = try g.declare(file, "x", .binding, span, null);
    const func = try g.childScope(file, .func, span);
    _ = try g.declare(func, "x", .param, span, null);

    const inner = g.resolve(func, "x").?;
    try std.testing.expect(g.defs.items[inner].kind == .param);

    const outer = g.resolve(file, "x").?;
    try std.testing.expect(g.defs.items[outer].kind == .binding);

    const second = try g.declare(file, "x", .function, span, null);
    try std.testing.expectEqual(second, g.resolve(file, "x").?);

    try std.testing.expect(g.resolve(func, "missing") == null);
}
