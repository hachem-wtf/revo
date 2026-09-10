const std = @import("std");

const revo = @import("revo");
const Data = revo.Data;
const Compiler = revo.lang.compiler.Compiler;

const ast = @import("../ast.zig");
const Node = ast.Node;
const state = @import("state.zig");
const ir = @import("../ir/root.zig");
const toRegister = state.toRegister;
const type_check = @import("type_check.zig");
const type_serde = @import("../type_serde.zig");
const types_mod = @import("types.zig");

pub const BindingKind = enum { global, let, con };

pub fn compileLocalBinding(
    self: *Compiler,
    name: []const u8,
    value: *const Node,
    mutable: bool,
    type_name: ?*ast.TypeExpr,
) !void {
    try self.validateName(name, value.span);
    if (!ast.isDiscardName(name)) if (state.currentFunctionState(self)) |fn_state|
        for (fn_state.import_locals.items) |il|
            if (std.mem.eql(u8, il.name, name)) {
                try self.appendFailureReport(.ParseError, &.{
                    .{ .@"error" = "name conflicts with an import" },
                    .{ .span = .{ .span = value.span, .role = .primary, .message = name } },
                });
                return error.LoweringFailed;
            };
    // fn slots can be reused if not initialized
    const slot = if (value.expr == .fn_expr)
        try state.reuseOrDeclareLocal(self, name, mutable)
    else
        try state.declareLocal(self, name, mutable);

    state.reserveLocalSlots(self);

    if (value.expr == .fn_expr) {
        try self.compileFn(
            value.expr.fn_expr.params,
            value.expr.fn_expr.return_type,
            value.expr.fn_expr.body,
            name,
            null,
            value.expr.fn_expr.type_params,
        );
    } else {
        // hide the binding's own name from its initializer so `x() = x()` and
        // `let x = x + 1` read the outer binding, not the fresh uninitialized slot
        const saved_mask = self.masking_local;
        self.masking_local = name;
        errdefer self.masking_local = saved_mask;
        try self.compile(value, true);
        self.masking_local = saved_mask;
    }

    state.markLocalInitialized(self, slot);
    state.markLocalValueKind(
        self,
        slot,
        if (value.expr == .tuple) .tuple_literal else .unknown,
    );

    const inferred_type = if (type_name) |tn|
        try type_serde.evalTypeExpr(self, tn)
    else
        type_check.inferExprType(self, value);

    try state.setLocalTypeHint(self, name, inferred_type);
    if (type_name != null) {
        state.setLocalType(self, slot, inferred_type);
        state.setLocalTypeExplicit(self, slot);
    }

    try self.emitBind(.bind_local, slot, try toRegister(self.active_registers - 1));
}

pub fn bindDeclaredPattern(
    self: *Compiler,
    pattern: *const Node,
    source_idx: usize,
    kind: BindingKind,
) !void {
    switch (pattern.expr) {
        .ident => |name| {
            if (ast.isDiscardName(name)) return;
            const slot = try state.reuseOrDeclareLocal(self, name, kind != .con);
            state.markLocalInitialized(self, slot);
            try self.emitBind(.bind_local, slot, try toRegister(source_idx));
            _ = try self.pop();
            state.reserveLocalSlots(self);
        },
        .tuple_pattern => |items| {
            for (items, 0..) |item, idx| {
                const mv_dst = try state.pushRegister(self);
                try self.spans.append(self.alloc, self.active_span);
                _ = try self.record(.move, &.{.{ .reg = try toRegister(source_idx) }}, true, mv_dst, 0);
                try self.emit(.tuple_get_const, idx);
                try bindDeclaredPattern(self, item, self.active_registers - 1, kind);
            }
        },
        else => {},
    }
}

pub fn declarePatternLocals(
    self: *Compiler,
    pattern: *const Node,
    mutable: bool,
) !void {
    switch (pattern.expr) {
        .ident => |name| {
            if (ast.isDiscardName(name)) return;
            _ = try state.reuseOrDeclareLocal(self, name, mutable);
            state.reserveLocalSlots(self);
        },
        .tuple_pattern => |items| {
            for (items) |item| {
                try declarePatternLocals(self, item, mutable);
            }
        },
        else => {},
    }
}

pub fn declareGlobalPattern(
    self: *Compiler,
    pattern: *const Node,
) !void {
    switch (pattern.expr) {
        .ident => |name| {
            if (ast.isDiscardName(name)) return;
            try self.declared_globals.put(name, {});
        },
        .tuple_pattern => |items| {
            for (items) |item| {
                try declareGlobalPattern(self, item);
            }
        },
        else => {},
    }
}

pub fn bindPattern(
    self: *Compiler,
    pattern: *const Node,
    source_idx: usize,
    kind: BindingKind,
) !void {
    switch (pattern.expr) {
        .ident => |name| {
            if (ast.isDiscardName(name)) return;
            const mv_dst = try state.pushRegister(self);
            try self.spans.append(self.alloc, self.active_span);
            _ = try self.record(.move, &.{.{ .reg = try toRegister(source_idx) }}, true, mv_dst, 0);
            try self.emit(
                if (kind == .con) .store_global_const else .store_global,
                try self.vm.internAtom(name),
            );
        },
        .tuple_pattern => |items| {
            const is_mutable = kind != .con;
            for (items, 0..) |item, idx| {
                switch (item.expr) {
                    .ident => |name| {
                        if (ast.isDiscardName(name)) continue;
                        const mv_dst2 = try state.pushRegister(self);
                        try self.spans.append(self.alloc, self.active_span);
                        _ = try self.record(.move, &.{.{ .reg = try toRegister(source_idx) }}, true, mv_dst2, 0);
                        try self.emit(.tuple_get_const, idx);
                        try self.emit(
                            if (is_mutable) .store_global else .store_global_const,
                            try self.vm.internAtom(name),
                        );
                    },
                    .tuple_pattern => {
                        const mv_dst2 = try state.pushRegister(self);
                        try self.spans.append(self.alloc, self.active_span);
                        _ = try self.record(.move, &.{.{ .reg = try toRegister(source_idx) }}, true, mv_dst2, 0);
                        try self.emit(.tuple_get_const, idx);
                        try bindPattern(self, item, self.active_registers - 1, kind);
                    },
                    else => {},
                }
            }
        },
        else => {},
    }
}

pub fn compileAssign(
    self: *Compiler,
    target: *const Node,
    value: *const Node,
) !void {
    if (target.expr == .tuple_pattern) {
        try validateTuplePatternShape(
            self,
            target.expr.tuple_pattern,
            value,
            "assignment",
        );
        try self.compile(value, true);
        const src_idx = self.active_registers - 1;
        return bindPattern(self, target, src_idx, .let);
    }
    return compileAssignSimple(self, target, value);
}

pub fn validateTuplePatternShape(
    self: *Compiler,
    pattern: []*Node,
    value: *const Node,
    context: []const u8,
) !void {
    if (value.expr != .tuple) return;
    // allow extra but not fewer
    if (value.expr.tuple.len >= pattern.len) return;
    const msg = try std.fmt.allocPrint(
        self.alloc,
        "tuple {s} expects at least {d} items, got {d}",
        .{ context, pattern.len, value.expr.tuple.len },
    );
    return self.fail(.ParseError, value, msg);
}

fn compileAssignSimple(
    self: *Compiler,
    target: *const Node,
    value: *const Node,
) !void {
    switch (target.expr) {
        .ident => |name| {
            try self.compile(value, true);
            try self.regDupe();
            if (state.resolveLocal(self, name)) |slot| {
                if (state.resolveLocalVar(self, name)) |lv| if (!lv.mutable)
                    return self.fail(.CompileError, target, "reassignment to constant!");
                try self.emit(.store_local, slot);
                state.markLocalValueKind(self, slot, .unknown);
                const inferred_type = type_check.inferExprType(self, value);
                try state.setLocalTypeHint(self, name, inferred_type);
            } else if (try state.resolveUpvalue(self, name)) |slot| {
                const fn_state = state.currentFunctionState(self) orelse
                    return self.fail(.CompileError, target, "reassignment to constant!");
                if (!fn_state.upvalues.items[slot].mutable)
                    return self.fail(.CompileError, target, "reassignment to constant!");
                try self.emit(.store_upval, slot);
            } else {
                if (self.functions.items.len == 1) {
                    const atom = try self.vm.internAtom(name);
                    const known = self.declared_globals.contains(name) or
                        self.vm.stdlib_globals.contains(atom) or
                        self.vm.globals.contains(atom) or
                        self.vm.const_globals.contains(atom);
                    if (!known) {
                        const msg = try std.fmt.allocPrint(
                            self.alloc,
                            "assignment target `{s}` is not declared",
                            .{name},
                        );
                        return self.fail(.InvalidAssignmentTarget, target, msg);
                    }
                    try self.emit(.store_global, atom);
                } else {
                    const msg = try std.fmt.allocPrint(
                        self.alloc,
                        "assignment target `{s}` is not declared",
                        .{name},
                    );
                    return self.fail(.InvalidAssignmentTarget, target, msg);
                }
            }
        },
        .field => |field| {
            try compileFieldAssign(self, field.object, field.name, value);
        },
        .index => |index| {
            try self.compile(index.object, true);
            if (index.key.expr == .hash) {
                const key_atom = try self.vm.internAtom(index.key.expr.hash);
                try self.regDupe();
                try self.compile(value, true);
                try self.emit(.table_set_atom, key_atom);
                try self.emit(.table_get_atom, key_atom);
                try widenLocalTableHint(self, index.object, index.key.expr.hash, value);
            } else {
                // evaluate object + key once; re-materialize them after the
                // set so the get doesn't re-evaluate either operand
                try self.compile(index.key, true);
                const obj_inst = self.value_stack.items[self.value_stack.items.len - 2];
                const key_inst = self.value_stack.items[self.value_stack.items.len - 1];
                try self.compile(value, true);
                try self.emit(.table_set, 0);
                // the key still lives in its original register; move it up
                // first so the obj dupe can claim that slot without losing it
                const obj_dst = try state.pushRegister(self);
                const key_dst = try state.pushRegister(self);
                try moveInstTo(self, key_dst, key_inst);
                try moveInstTo(self, obj_dst, obj_inst);
                try self.emit(.table_get, 0);

                // static string keys widen like hash keys
                // computed keys leave the hint alone
                //
                // nulling it would misguide later method-shadowing codegen,
                // and the missed precision fails w compile error rather than it being wrong
                if (index.key.expr == .string) {
                    try widenLocalTableHint(self, index.object, index.key.expr.string, value);
                }
            }
        },
        else => {
            const msg = try std.fmt.allocPrint(
                self.alloc,
                "bad assignment target: {s}",
                .{@tagName(target.expr)},
            );
            return self.fail(.InvalidAssignmentTarget, target, msg);
        },
    }
}

// push a move of an earlier stack value into a specific top register
fn moveInstTo(self: *Compiler, dst: revo.opcode.Register, src: *ir.IrInst) !void {
    try self.spans.append(self.alloc, self.active_span);
    _ = try self.record(.move, &.{.{ .inst = src }}, true, dst, 0);
}

/// `t.f = v`: extend t's known fields so later lookups see f.
/// copy-on-write over the hint's field list, never mutates shared slices;
/// unknown shapes (plain `table`) start a fresh list. hint-scoped, so a
/// conditional add only persists inside its scope
fn widenLocalTableHint(self: *Compiler, object: *const Node, field_name: []const u8, value: *const Node) !void {
    if (object.expr != .ident) return;
    const name = object.expr.ident;
    const hint = state.resolveLocalTypeHint(self, name) orelse return;
    if (hint.tag != .table) return;
    const field_type = type_check.inferExprType(self, value);
    const old = if (hint.tag.table.fields) |fs| fs else &[_]types_mod.RecordField{};
    var widened = hint;
    if (types_mod.findFieldIndex(old, field_name)) |i| {
        const owned = try self.alloc.dupe(types_mod.RecordField, old);
        owned[i].field_type = field_type;
        widened.tag.table.fields = owned;
    } else {
        const owned = try self.alloc.alloc(types_mod.RecordField, old.len + 1);
        @memcpy(owned[0..old.len], old);
        owned[old.len] = .{ .name = field_name, .field_type = field_type };
        widened.tag.table.fields = owned;
    }
    try state.setLocalTypeHint(self, name, widened);
}

fn compileFieldAssign(
    self: *Compiler,
    field_obj: *const Node,
    field_name: []const u8,
    value: *const Node,
) !void {
    const key_atom = try self.vm.internAtom(field_name);
    try self.compile(field_obj, true);
    try self.regDupe();
    try self.compile(value, true);
    try self.emit(.table_set_atom, key_atom);
    try self.emit(.table_get_atom, key_atom);
    try widenLocalTableHint(self, field_obj, field_name, value);
}

pub fn compileTable(self: *Compiler, entries: []const ast.TableEntry) !void {
    try self.emit(.table_new, 0);
    var array_index: i64 = 0;
    for (entries) |entry| {
        try self.regDupe();

        // `name = v` / `:h = v` store by atom. keyless values are array
        // elements, except named fns (`fn f() ...`, `let f = fn ...`),
        // which store under their name without declaring it as a local
        // so a keyless `let x = e` stores e itself
        var atom: ?[]const u8 = null;
        var named_fn: ?*const ast.Binding = null;
        if (entry.key) |key| {
            if (!entry.computed) switch (key.expr) {
                .ident => |n| atom = n,
                .hash => |n| atom = n,
                else => try self.compile(try isolateEntryDecls(self, key), true),
            } else try self.compile(try isolateEntryDecls(self, key), true);
        } else if (namedFnBinding(entry.value)) |b| {
            atom = b.target.expr.ident;
            named_fn = b;
        } else {
            try self.@"const"(Data.new.num(array_index));
            array_index += 1;
        }

        if (atom) |name| {
            if (named_fn) |b| {
                try self.compileFn(
                    b.value.expr.fn_expr.params,
                    b.value.expr.fn_expr.return_type,
                    b.value.expr.fn_expr.body,
                    name,
                    null,
                    b.value.expr.fn_expr.type_params,
                );
            } else {
                try self.compile(try isolateEntryDecls(self, entry.value), true);
            }
            try self.emit(.table_set_atom, try self.vm.internAtom(name));
        } else {
            try self.compile(try isolateEntryDecls(self, entry.value), true);
            try self.emit(.table_set, 0);
        }
        try self.regRelease();
    }
}

/// the binding of a keyless `fn f ...` / `let f = fn ...` entry
fn namedFnBinding(node: *const Node) ?*const ast.Binding {
    if (node.expr != .decl) return null;
    const d = node.expr.decl;
    if (d.inner.expr != .binding) return null;
    const b = &d.inner.expr.binding;
    if (b.target.expr != .ident or b.value.expr != .fn_expr) return null;
    return b;
}

/// entry values and computed keys that declare bindings or carry loop
/// machinery would reserve parent-frame registers or leave the value
/// stack unbalanced mid-expression
/// desyncing every positional window
/// around them,[] those compile inside a synthetic zero-param fn called
/// on the spot, so the child frame owns the slots
///
/// clean nodes come back unchanged
pub fn isolateEntryDecls(self: *Compiler, node: *const Node) !*Node {
    var visitor = IsolationVisitor{};
    visitor.visit(node);
    if (!visitor.found) return @constCast(node);

    const fn_node = try self.alloc.create(ast.Node);
    fn_node.* = .{ .span = node.span, .expr = .{ .fn_expr = .{
        .params = &.{},
        .body = @constCast(node),
        .type_params = &.{},
    } } };

    const call_node = try self.alloc.create(ast.Node);
    call_node.* = .{ .span = node.span, .expr = .{ .call = .{
        .callee = fn_node,
        .args = &.{},
    } } };
    return call_node;
}

/// does this expression declare bindings or carry loop machinery? both
/// desync the enclosing window, see isolateEntryDecls. fn bodies are
/// skipped, their frames isolate themselves already
pub const IsolationVisitor = struct {
    found: bool = false,

    pub fn visit(self: *IsolationVisitor, node: *const Node) void {
        if (self.found) return;
        switch (node.expr) {
            .decl, .binding, .import_stmt, .loop_expr, .for_loop, .while_loop, .labeled_block => self.found = true,
            // fn frames isolate themselves already
            .fn_expr => {},
            else => ast.walkAST(IsolationVisitor, self, node),
        }
    }
};
