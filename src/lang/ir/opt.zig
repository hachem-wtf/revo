//! fused optimizer: fold then dce then peephole, one file
//!   same order, same compacts, same buffers as the old three passes
//!   bodies moved verbatim; only the file boundary changed

const std = @import("std");

const revo = @import("revo");
const Compiler = @import("../compiler/root.zig").Compiler;
const Opcode = revo.opcode.Opcode;
const Operand = revo.Operand;
const Register = revo.opcode.Register;
const Value = revo.Value;

const ir = @import("root.zig");

/// run all three phases in pipeline order, bit-identical to separate calls
pub fn optimize(self: *Compiler) !void {
    try foldIr(self);
    try dceIr(self);
    try peepholeIr(self);
}

//
// fold: walk ir and fold constant expressions
// safe bc operands use .inst pointers (not register names),
// so data flow is correct whatever the control flow is
//
// folding frees the operands of the folded instruction, but the operand
// instructions themselves are only reclaimed by dce below; fold must
// therefore always be followed by dce before the ir is lowered
//

pub fn foldIr(self: *Compiler) !void {
    for (self.ir_builder.instructions.items) |inst| {
        _ = tryFoldInst(self, inst) catch continue;
    }
}

fn tryFoldInst(self: *Compiler, inst: *ir.IrInst) !bool {
    switch (inst.opcode) {
        .add, .sub, .mul, .div, .mod, .concat, .pow, .band, .bor, .bxor, .shl, .shr, .int_div, .eq, .neq, .lt, .gt, .lte, .gte, .eq_int, .neq_int, .lt_int, .gt_int, .lte_int, .gte_int => {
            if (try tryFoldBinary(self, inst)) return true;
            return tryFoldIdentity(self, inst);
        },
        .add_imm, .sub_imm, .mul_imm, .band_imm, .lt_int_imm => {
            return tryFoldIdentityImm(self, inst);
        },
        .negate, .not => {
            return tryFoldUnary(self, inst);
        },
        else => return false,
    }
}

fn extractConst(self: *Compiler, v: *const ir.IrInst) ?Value {
    switch (v.opcode) {
        .load_small_int => return Value.new.num(@as(i64, @intCast(v.op_arg))),
        .load_const => {
            if (v.op_arg < self.vm.constants.items.len) {
                return self.vm.constants.items[v.op_arg];
            }
            return null;
        },
        .load_nil => return Value.new.nil(),
        .move => {
            // chase the copied value so moves don't block folding; operands
            // point at earlier instructions so the recursion always ends
            if (v.operands.len == 1) {
                if (v.operands[0] == .inst) return extractConst(self, v.operands[0].inst);
            }
            return null;
        },
        else => return null,
    }
}

fn rewriteToConst(self: *Compiler, inst: *ir.IrInst, val: Value) !void {
    // allocate the replacement first so a failure can't leave inst.operands
    // pointing at already-freed memory for a later dce/deinit double free
    const new_ops = try self.alloc.alloc(ir.IrValue, 0);
    self.alloc.free(inst.operands);
    inst.operands = new_ops;

    if (val.asNumOpt()) |n| {
        if (n >= 0 and n <= 65535 and @trunc(n) == n) {
            inst.opcode = .load_small_int;
            inst.op_arg = @intFromFloat(n);
            return;
        }
    }
    const idx = try self.vm.addConstant(val);
    inst.opcode = .load_const;
    inst.op_arg = idx;
}

fn tryFoldBinary(self: *Compiler, inst: *ir.IrInst) !bool {
    if (inst.operands.len != 2) return false;
    const lhs = inst.operands[0];
    const rhs = inst.operands[1];
    if (lhs != .inst or rhs != .inst) return false;

    const lv = extractConst(self, lhs.inst) orelse return false;
    const rv = extractConst(self, rhs.inst) orelse return false;

    // numeric fold
    if (lv.isNumber() and rv.isNumber()) {
        const ln = lv.asNumOpt().?;
        const rn = rv.asNumOpt().?;
        const is_comp = switch (inst.opcode) {
            .eq, .neq, .lt, .gt, .lte, .gte, .eq_int, .neq_int, .lt_int, .gt_int, .lte_int, .gte_int => true,
            else => false,
        };
        const is_int = switch (inst.opcode) {
            .band, .bor, .bxor, .shl, .shr, .int_div, .eq_int, .neq_int, .lt_int, .gt_int, .lte_int, .gte_int => true,
            else => false,
        };

        // bitwise folds only on integral values; `//` folds for floats too
        // (floor), no fold on div-by-zero or non-finite results
        const is_int_only = switch (inst.opcode) {
            .band, .bor, .bxor, .shl, .shr => true,
            else => false,
        };
        const is_floor_div = switch (inst.opcode) {
            .int_div => true,
            else => false,
        };
        const is_pow = switch (inst.opcode) {
            .pow => true,
            else => false,
        };
        if (is_int_only or is_floor_div or is_pow) {
            if (is_int_only) {
                const li = revo.memory.numToI64(ln) orelse return false;
                const ri = revo.memory.numToI64(rn) orelse return false;
                const raw: f64 = switch (inst.opcode) {
                    .band => @floatFromInt(li & ri),
                    .bor => @floatFromInt(li | ri),
                    .bxor => @floatFromInt(li ^ ri),
                    .shl => blk: {
                        if (ri < 0 or ri > 63) break :blk std.math.nan(f64);
                        const shifted: i64 = @bitCast(@as(u64, @bitCast(li)) << @as(u6, @intCast(ri)));
                        break :blk @floatFromInt(shifted);
                    },
                    .shr => blk: {
                        if (ri < 0 or ri > 63) break :blk std.math.nan(f64);
                        break :blk @floatFromInt(li >> @as(u6, @intCast(ri)));
                    },
                    else => unreachable,
                };
                if (!std.math.isFinite(raw)) return false;
                try rewriteToConst(self, inst, Value.new.num(raw));
                return true;
            }
            if (is_floor_div) {
                if (rn == 0) return false;
                const li = revo.memory.numToI64(ln);
                const ri = revo.memory.numToI64(rn);
                const raw: f64 = if (li != null and ri != null)
                    @floatFromInt(@divFloor(li.?, ri.?))
                else
                    @floor(ln / rn);
                if (!std.math.isFinite(raw)) return false;
                try rewriteToConst(self, inst, Value.new.num(raw));
                return true;
            }
            if (is_pow) {
                const li = revo.memory.numToI64(ln);
                const ri = revo.memory.numToI64(rn);
                const raw: f64 = if (li != null and ri != null and ri.? >= 0) blk: {
                    break :blk @floatFromInt(revo.memory.ipow(li.?, ri.?));
                } else std.math.pow(f64, ln, rn);
                if (!std.math.isFinite(raw)) return false;
                try rewriteToConst(self, inst, Value.new.num(raw));
                return true;
            }
            unreachable;
        }

        const raw: f64 = switch (inst.opcode) {
            .add => ln + rn,
            .sub => ln - rn,
            .mul => ln * rn,
            .div => if (rn == 0.0) return false else ln / rn,
            // mirror the vm's .mod: i32-range integers mod via i64 @mod
            // (sign of divisor), everything else fmod (sign of dividend)
            .mod => blk: {
                if (rn == 0.0) return false;
                const li = revo.memory.numToI64(ln);
                const ri = revo.memory.numToI64(rn);
                if (li != null and ri != null and
                    li.? >= std.math.minInt(i32) and li.? <= std.math.maxInt(i32) and
                    ri.? >= std.math.minInt(i32) and ri.? <= std.math.maxInt(i32))
                    break :blk @floatFromInt(@mod(li.?, ri.?));
                break :blk @mod(ln, rn);
            },
            .eq, .eq_int => if (ln == rn) 1.0 else 0.0,
            .neq, .neq_int => if (ln != rn) 1.0 else 0.0,
            .lt, .lt_int => if (ln < rn) 1.0 else 0.0,
            .gt, .gt_int => if (ln > rn) 1.0 else 0.0,
            .lte, .lte_int => if (ln <= rn) 1.0 else 0.0,
            .gte, .gte_int => if (ln >= rn) 1.0 else 0.0,
            else => return false,
        };

        if (is_comp) {
            // comparisons produce :true/:false atoms
            try rewriteToConst(self, inst, Value.new.boolean(raw != 0.0));
        } else {
            if (!std.math.isFinite(raw)) return false;
            if (is_int) {
                if (@floor(raw) != raw) return false;
                const min: f64 = @floatFromInt(std.math.minInt(i64));
                const max: f64 = @floatFromInt(std.math.maxInt(i64));
                if (raw < min or raw > max) return false;
                try rewriteToConst(self, inst, Value.new.num(@as(i64, @intFromFloat(raw))));
            } else {
                try rewriteToConst(self, inst, Value.new.num(raw));
            }
        }
        return true;
    }

    // string concat for .concat with two string constants
    if (lv.isString() and rv.isString() and inst.opcode == .concat) {
        const ls = try self.vm.strings.get(lv.asString().?);
        const rs = try self.vm.strings.get(rv.asString().?);
        const s = try std.mem.concat(self.alloc, u8, &.{ ls, rs });
        defer self.alloc.free(s);
        try rewriteToConst(self, inst, try self.vm.ownValueString(s));
        return true;
    }

    return false;
}

//
// rewrite `x OP c` where the constant makes the result equal to one
// operand (`x + 0`, `x * 1`) or a constant (`x & 0`)
//
// surviving operand becomes a copy
// ; dce and the peephole clean up.
// only integral small constants participate
//
// identity folds hold for floats too (including NaN)
// annihilators apply only where the op is exact on all inputs it accepts:
//   band_imm requires integral lhs, so x&0 is 0,
//
// but mul_imm takes any float and NaN*0 is NaN, so it has no annihilator
//
fn tryFoldIdentity(self: *Compiler, inst: *ir.IrInst) !bool {
    if (inst.operands.len != 2) return false;
    const lhs = inst.operands[0];
    const rhs = inst.operands[1];
    if (lhs != .inst or rhs != .inst) return false;

    const lc = constInt(self, lhs.inst);
    const rc = constInt(self, rhs.inst);
    if (lc == null and rc == null) return false;
    if (lc != null and rc != null) return false;

    const op = inst.opcode;
    if (rc != null) {
        if (identityWith(op, rc.?)) return try makeMove(self, inst, lhs.inst);
        if (annihilatorWith(op, rc.?)) return try makeZero(self, inst);
    }
    if (lc != null and commutative(op)) {
        if (identityWith(op, lc.?)) return try makeMove(self, inst, rhs.inst);
        if (annihilatorWith(op, lc.?)) return try makeZero(self, inst);
    }
    return false;
}

fn tryFoldIdentityImm(self: *Compiler, inst: *ir.IrInst) !bool {
    if (inst.operands.len != 1) return false;
    const acc = inst.operands[0];
    if (acc != .inst) return false;
    const k: i64 = @intCast(inst.op_arg);
    if (identityWith(inst.opcode, k)) return try makeMove(self, inst, acc.inst);
    if (annihilatorWith(inst.opcode, k)) return try makeZero(self, inst);
    return false;
}

fn makeMove(self: *Compiler, inst: *ir.IrInst, src: *ir.IrInst) !bool {
    self.alloc.free(inst.operands);
    inst.operands = try self.alloc.dupe(ir.IrValue, &.{.{ .inst = src }});
    inst.opcode = .move;
    return true;
}

fn makeZero(self: *Compiler, inst: *ir.IrInst) !bool {
    try rewriteToConst(self, inst, Value.new.num(0));
    return true;
}

fn constInt(self: *Compiler, v: *const ir.IrInst) ?i64 {
    const d = extractConst(self, v) orelse return null;
    const n = d.asNumOpt() orelse return null;
    const iv = revo.memory.numToI64(n) orelse return null;
    if (@as(f64, @floatFromInt(iv)) != n) return null;
    return iv;
}

fn commutative(op: Opcode) bool {
    return switch (op) {
        .add, .mul, .band, .bor, .bxor => true,
        else => false,
    };
}

fn identityWith(op: Opcode, c: i64) bool {
    return switch (op) {
        .add, .add_imm, .sub, .sub_imm => c == 0,
        .mul, .mul_imm, .div, .int_div => c == 1,
        else => false,
    };
}

fn annihilatorWith(op: Opcode, c: i64) bool {
    return switch (op) {
        .band_imm => c == 0,
        else => false,
    };
}

fn tryFoldUnary(self: *Compiler, inst: *ir.IrInst) !bool {
    if (inst.operands.len != 1) return false;
    const operand = inst.operands[0];
    if (operand != .inst) return false;

    const val = extractConst(self, operand.inst) orelse return false;
    if (!val.isNumber()) return false;

    const n = val.asNumOpt().?;
    const is_not = inst.opcode == .not;
    const raw: f64 = switch (inst.opcode) {
        .negate => -n,
        .not => if (n == 0.0) 1.0 else 0.0,
        else => return false,
    };

    if (is_not) {
        try rewriteToConst(self, inst, Value.new.boolean(n == 0.0));
    } else {
        if (!std.math.isFinite(raw)) return false;
        try rewriteToConst(self, inst, Value.new.num(raw));
    }
    return true;
}

//
// dce: walks the ir and removes instructions whose results are never used
// an instruction is live if it has side effects: stores, calls, control
// flow, or if its result flows into another live instruction
//
// data flow uses .inst pointers, not register names, so liveness traces
// correctly across the whole instruction list. jump targets live in op_arg
// as instruction indices and get remapped after compaction
//
// registers also carry values across control flow, so register liveness is
// computed per basic block over the register lowering encoding
//
// runs after folding so folded-to-constant operands are already freed,
// dce cleans up the dead constants that folding leaves behind
//

const Block = struct { start: usize, end: usize };

/// side-effecting opcodes that must never be eliminated
///
/// `move` is deliberately absent: moves are pure register copies and are
/// kept only when register liveness shows their destination is still read.
/// loop-break and branch-merge results flow through a move into a shared
/// register that later code reads by name, and the per-block register
/// liveness below keeps exactly those moves alive
fn isSideEffect(op: Opcode) bool {
    return switch (op) {
        // zig fmt: off
        .store_user_global, .store_user_global_const, .store_local, .bind_local,
        .store_upval, .table_set, .table_set_atom, .call, .call_field, .spawn,
        .yield, .ret, .halt,
        .range_init, .unwrap_result
        // zig fmt: on
        => true,
        else => ir.isBranch(op),
    };
}

pub fn dceIr(self: *Compiler) !void {
    const insts = self.ir_builder.instructions.items;
    const n = insts.len;
    if (n == 0) return;

    // dense positions for `.inst` operand res, operands always point backward, so every target is in this list
    for (insts, 0..) |inst, i| inst.tmp_index = i;

    var live = try self.alloc.alloc(bool, n);
    defer self.alloc.free(live);
    @memset(live, false);

    // -- [pass 1] ------------------------------------------------------------
    // mark side-effecting instructions as live
    for (insts, 0..) |inst, i| {
        if (isSideEffect(inst.opcode)) live[i] = true;
    }

    // -- [pass 2a] -----------------------------------------------------------
    // split into basic blocks: a block starts at index 0, at every jump
    // target, and after every terminator
    var is_block_start = try self.alloc.alloc(bool, n);
    defer self.alloc.free(is_block_start);
    @memset(is_block_start, false);
    is_block_start[0] = true;
    for (insts) |inst| {
        if (ir.isBranch(inst.opcode)) {
            if (inst.op_arg < n) is_block_start[inst.op_arg] = true;
        }
    }
    for (insts, 0..) |inst, i| {
        if (i + 1 < n and (ir.isBranch(inst.opcode) or inst.opcode == .ret or inst.opcode == .halt))
            is_block_start[i + 1] = true;
    }

    var blocks = try std.ArrayList(Block).initCapacity(self.alloc, 0);
    defer blocks.deinit(self.alloc);
    var block_of = try self.alloc.alloc(usize, n);
    defer self.alloc.free(block_of);
    {
        var start: usize = 0;
        while (start < n) {
            var end = start + 1;
            while (end < n and !is_block_start[end]) : (end += 1) {}
            for (start..end) |j| block_of[j] = blocks.items.len;
            try blocks.append(self.alloc, .{ .start = start, .end = end });
            start = end;
        }
    }
    const nb = blocks.items.len;

    // registers can hold values written on multiple control-flow paths,
    // so register liveness is per-block (see readRegs/writeRegs)
    const reg_count = ir.maxRegister(insts) + 1;

    // there's no concise way to un-ugly this sorry
    var block_uses = try self.alloc.alloc(bool, nb * reg_count);
    defer self.alloc.free(block_uses);
    var block_writes = try self.alloc.alloc(bool, nb * reg_count);
    defer self.alloc.free(block_writes);
    var live_in = try self.alloc.alloc(bool, nb * reg_count);
    defer self.alloc.free(live_in);
    var live_out = try self.alloc.alloc(bool, nb * reg_count);
    defer self.alloc.free(live_out);
    var next_out = try self.alloc.alloc(bool, reg_count);
    defer self.alloc.free(next_out);
    var written_regs = try self.alloc.alloc(bool, reg_count);
    defer self.alloc.free(written_regs);
    var read_buf = try self.alloc.alloc(Register, reg_count);
    defer self.alloc.free(read_buf);

    @memset(block_writes, false);
    for (insts, 0..) |inst, i| {
        var wbuf: [3]Register = undefined;
        const wcnt = ir.writeRegs(inst, &wbuf);
        const row = block_of[i] * reg_count;
        for (wbuf[0..wcnt]) |reg| block_writes[row + @as(usize, reg)] = true;
    }

    // -- [pass 2b] -----------------------------------------------------------
    // propagate liveness until stable
    //
    // ~ backward through .inst operands (data flow)
    // ~ forward to jump targets (control flow)
    // ~ register liveness across the block graph (backward data flow)
    @memset(live_in, false);
    var changed = true;
    while (changed) {
        changed = false;

        // dataflow thru .inst operands and control flow
        //
        // walk instructions backward: operands always sit at earlier
        // indices, so one pass propagates a whole dependency chain and
        // the outer loop only re-runs for forward jump chains
        var di = n;
        while (di > 0) {
            di -= 1;
            const inst = insts[di];
            if (!live[di]) continue;
            for (inst.operands) |op| {
                if (op == .inst) {
                    const j = op.inst.tmp_index;
                    if (j < n and !live[j]) {
                        live[j] = true;
                        changed = true;
                    }
                }
            }
            if (ir.isBranch(inst.opcode)) {
                const target = inst.op_arg;
                if (target < n and !live[target]) {
                    live[target] = true;
                    changed = true;
                }
            }
        }

        // registers read by live instructions, per block
        //
        // a register only counts as a block use if it is read before its
        // first write in the block; otherwise its value is produced inside
        // the block and the block needs nothing from its predecessors
        @memset(block_uses, false);
        for (blocks.items, 0..) |b, bi| {
            const base = bi * reg_count;
            @memset(written_regs, false);
            for (b.start..b.end) |i| {
                const inst = insts[i];
                if (live[i]) {
                    const rcnt = ir.readRegsAll(inst, read_buf);
                    std.debug.assert(rcnt <= reg_count);
                    for (read_buf[0..rcnt]) |reg| {
                        if (!written_regs[reg]) block_uses[base + @as(usize, reg)] = true;
                    }
                }
                var wbuf: [3]Register = undefined;
                const wcnt = ir.writeRegs(inst, &wbuf);
                for (wbuf[0..wcnt]) |reg| written_regs[reg] = true;
            }
        }

        // block liveness: live_out[b] = union of live_in[succ];
        // live_in[b] = reads[b] | (live_out[b] & !writes[b])
        //
        // live_in is warm-started (not reset)
        // liveness only grows across outer iterations, so the previous state is a lower bound and the
        // fixpoint converges from it faster than from empty
        var liveness_changed = true;
        while (liveness_changed) {
            liveness_changed = false;
            for (blocks.items, 0..) |b, bi| {
                const base = bi * reg_count;
                const last_inst = insts[b.end - 1];
                @memset(next_out, false);

                if (last_inst.opcode == .jump) {
                    const tb = block_of[last_inst.op_arg];
                    for (0..reg_count) |reg| next_out[reg] = live_in[tb * reg_count + reg];
                } else if (ir.isBranch(last_inst.opcode)) {
                    const tb = block_of[last_inst.op_arg];
                    for (0..reg_count) |reg| next_out[reg] = live_in[tb * reg_count + reg];
                    if (b.end < n) {
                        const fb = block_of[b.end];
                        for (0..reg_count) |reg| next_out[reg] = next_out[reg] or live_in[fb * reg_count + reg];
                    }
                } else if (last_inst.opcode == .ret or last_inst.opcode == .halt) {
                    // no successors
                } else {
                    if (b.end < n) {
                        const fb = block_of[b.end];
                        for (0..reg_count) |reg| next_out[reg] = live_in[fb * reg_count + reg];
                    }
                }
                for (0..reg_count) |reg| live_out[base + reg] = next_out[reg];
                for (0..reg_count) |reg| {
                    const v = block_uses[base + reg] or (next_out[reg] and !block_writes[base + reg]);
                    if (v != live_in[base + reg]) {
                        live_in[base + reg] = v;
                        liveness_changed = true;
                    }
                }
            }
        }

        // within each block, walk backward marking the writers of
        // registers that are live at the point they are written
        for (blocks.items, 0..) |b, bi| {
            const base = bi * reg_count;
            var cur: []bool = live_out[base .. base + reg_count];
            var j: usize = b.end;
            while (j > b.start) {
                j -= 1;
                const inst = insts[j];
                var wbuf: [3]Register = undefined;
                const wcnt = ir.writeRegs(inst, &wbuf);
                var needed = false;
                for (wbuf[0..wcnt]) |reg| {
                    if (cur[reg]) needed = true;
                }
                if (needed) {
                    for (wbuf[0..wcnt]) |reg| cur[reg] = false;
                    if (!live[j]) {
                        live[j] = true;
                        changed = true;
                    }
                }
                if (live[j]) {
                    const rcnt = ir.readRegsAll(inst, read_buf);
                    std.debug.assert(rcnt <= reg_count);
                    for (read_buf[0..rcnt]) |reg| cur[reg] = true;
                }
            }
        }
    }

    // -- [pass 3] ------------------------------------------------------------
    // compact
    //
    // keep live instructions, destroy dead ones; spans stay in 1:1
    // correspondence with instructions, and jump targets / template addrs
    // (instruction indices) are remapped. for dead positions the remap points
    // at the next live slot so stale addresses still land on real code.
    try self.compactIr(n, live);
}

//
// peephole: local pass over ir, runs after dce
//
// `foldIr` folds constant expressions (including identities like
// `x + 0`) and dce drops dead instructions, but a few patterns survive
// ~ redundant copies: `move rA, rA` self-moves, which dce keeps because
//   the register is live
// ~ control flow: jumps that chain into other jumps, conditional jumps
//   immediately followed by an unconditional jump, and jumps that land on
//   the very next instruction
//
// deletes instructions in place and compacts at the end, remapping jump
// targets and function entry points exactly like dce
//

pub fn peepholeIr(self: *Compiler) !void {
    const insts = self.ir_builder.instructions.items;
    const n = insts.len;
    if (n == 0) return;

    var live = try self.alloc.alloc(bool, n);
    defer self.alloc.free(live);
    @memset(live, true);

    // chase jump -> jump chains first so that rewrites below see final
    // targets (a chain that ends in a dead fallthru jump is handled by
    // the compaction remap)
    for (insts) |inst| threadJumps(insts, inst);

    // jump targets, used to keep copy propagation within straightline code
    // (a branch into the middle of a move's live range could bypass the move
    // and leave its source register holding a different value)
    var is_target = try self.alloc.alloc(bool, n);
    defer self.alloc.free(is_target);
    @memset(is_target, false);
    for (insts) |inst| if (ir.isBranch(inst.opcode)) {
        if (inst.op_arg < n) is_target[inst.op_arg] = true;
    };

    // register reads can span contiguous ranges (call args,
    // slice), so reuse the shared model with a buffer sized to the register file
    const read_buf = try self.alloc.alloc(Register, ir.maxRegister(insts) + 1);
    defer self.alloc.free(read_buf);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (!live[i]) continue;
        const inst = insts[i];
        switch (inst.opcode) {
            .move => {
                eliminateSelfMove(i, insts, live);
                if (live[i]) _ = try propagateMove(i, insts, live, is_target, read_buf);
            },
            .store_local, .bind_local => eliminateSelfLoad(i, insts, live, is_target),
            .table_set_atom => eliminateFieldRefetch(i, insts, live, is_target),
            .table_get_atom => reuseObjectLoad(i, insts, live, is_target),
            .jump => {
                if (inst.op_arg == i + 1) live[i] = false;
            },
            .jump_if_false, .jump_if_true, .jump_err => {
                if (inst.op_arg == i + 1) {
                    live[i] = false;
                } else if (inst.opcode == .jump_if_false or inst.opcode == .jump_if_true) {
                    _ = invertBranch(i, insts, live);
                }
            },
            else => {},
        }
    }

    try self.compactIr(n, live);
}

fn threadJumps(insts: []*ir.IrInst, inst: *ir.IrInst) void {
    if (!ir.isBranch(inst.opcode)) return;
    var target = inst.op_arg;
    var steps: usize = 0;
    while (target < insts.len and insts[target].opcode == .jump and steps < insts.len) : (steps += 1) {
        target = insts[target].op_arg;
    }
    inst.op_arg = target;
}

/// opcodes that read exactly their `result_reg` and write no register at all
/// these are the only safe destinations for copy propagation: rewriting the
/// read register cannot shift a register block that later instructions rely on
fn isPureReader(op: Opcode) bool {
    return switch (op) {
        .store_local, .bind_local, .store_user_global, .store_user_global_const, .store_upval, .ret, .halt, .jump_if_false, .jump_if_true, .jump_err => true,
        else => false,
    };
}

/// `move rD, rS` where the only user of rD is an instruction that reads a
/// single register (`store_local slot, rD`), rewrite that reader to use rS and
/// drop the copy. rS must not be overwritten between the move and the read,
/// and the read must sit in straight-line code after the move so the source
/// register provably still holds the copied value when the reader runs.
///
/// dce already eliminated moves whose destination is never read, so a live
/// move here has at least one reader; this folds away the single-reader case
/// that `eliminateMove` cannot touch
fn propagateMove(i: usize, insts: []*ir.IrInst, live: []bool, is_target: []const bool, read_buf: []Register) !bool {
    const m = insts[i];
    if (m.operands.len != 1) return false;
    const src_val = m.operands[0];
    const src_reg: Register = ir.valueReg(src_val);
    const dst_reg = m.result_reg;
    if (src_reg == dst_reg) return false;

    var user_idx: usize = 0;
    var found = false;
    // once the copy's destination register is written again, the register
    // holds a different value and later readers are not users of the copy
    var dst_written = false;
    for (i + 1..insts.len) |j| {
        if (!live[j]) continue;
        var is_user = false;
        for (insts[j].operands) |op| {
            if (op == .inst and op.inst == m) {
                is_user = true;
                break;
            }
            if (op == .reg and op.reg == dst_reg and !dst_written) {
                is_user = true;
                break;
            }
        }
        // a consumer can read the copy's destination register by encoded
        // position without naming the move: its operand may point at a
        // different, already-eliminated instruction while the bytecode still
        // reads dst_reg. count those readers as users so a later reader is
        // never separated from the value the copy deposited
        if (!is_user and !dst_written and readsReg(insts[j], dst_reg, read_buf)) {
            is_user = true;
        }
        // a table setter reads its object through `result_reg`, not
        // an operand, so a move feeding it would otherwise look orphaned
        if (!is_user and !dst_written) switch (insts[j].opcode) {
            .table_set_atom, .table_set => {
                if (insts[j].result_reg == dst_reg) is_user = true;
            },
            else => {},
        };
        if (is_user) {
            if (found) return false;
            user_idx = j;
            found = true;
        }
        if (writesReg(insts[j], dst_reg)) dst_written = true;
    }
    if (!found) return false;

    const user = insts[user_idx];

    // `t.field = value` compiles to a dup of the object so the value can
    // land beside it (`table_set_atom` reads `result_reg` and `result_reg+1`);
    // when the value is straight-line and never touches the object register,
    // shift the value down one register, point the setter at the object, and
    // drop the copy
    if (user.opcode == .table_set_atom or user.opcode == .table_set) {
        return shiftSetterCopy(i, insts, live, is_target, read_buf, user_idx);
    }

    if (!isPureReader(user.opcode)) return false;
    // the reader encodes its register as `result_reg`; a single-register read
    // must be sitting at the move's register or the encoding model is off
    if (user.result_reg != dst_reg) return false;

    // the user must be reachable only through the move's fall-through: no
    // branch into the range, no branch out, and no write to the source
    // register, or the source may no longer hold the copied value
    if (is_target[user_idx]) return false;
    for (i + 1..user_idx) |k| {
        if (is_target[k]) return false;
        switch (insts[k].opcode) {
            .jump, .jump_if_false, .jump_if_true, .jump_err => return false,
            else => {},
        }
        var wbuf: [3]Register = undefined;
        const wcnt = ir.writeRegs(insts[k], &wbuf);
        for (wbuf[0..wcnt]) |w| if (w == src_reg) return false;
    }

    // repoint the reader at the source value and make it read the source
    // register, then let the compaction drop the copy
    for (user.operands) |*op| {
        if (op.* == .inst and op.inst == m) {
            op.* = src_val;
            break;
        }
        if (op.* == .reg and op.reg == dst_reg) {
            op.* = src_val;
            break;
        }
    }
    user.result_reg = src_reg;
    live[i] = false;
    return true;
}

/// `bind_local slotS, rR` (or `store_local`) followed by `load_local rR, slotS`
/// reloads a slot into the very register that just wrote it: a no-op the dce
/// keeps because the register is live. scan forward through straight-line
/// code and drop the load while the register still provably holds the slot's
/// value (nothing writes the register or the slot, no branch into the run).
fn eliminateSelfLoad(i: usize, insts: []*ir.IrInst, live: []bool, is_target: []const bool) void {
    const store = insts[i];
    const slot = store.op_arg;
    const reg = store.result_reg;
    var j: usize = i + 1;
    while (j < insts.len) : (j += 1) {
        if (is_target[j]) return;
        if (!live[j]) continue;
        const inst = insts[j];
        if (inst.opcode == .load_local and inst.result_reg == reg and inst.op_arg == slot) {
            live[j] = false;
            return;
        }
        // a jump can leave the current function or merge in control flow that
        // did not pass through the store, so the store no longer dominates
        // anything after it
        if (ir.isBranch(inst.opcode)) return;
        switch (inst.opcode) {
            .bind_local, .store_local => {
                if (inst.op_arg == slot) return;
            },
            .yield, .ret, .halt => return,
            else => {},
        }
        if (writesReg(inst, reg)) return;
    }
}

/// `t.field = value` followed by `load_local rV, slot; table_get_atom rV, rV, :field`
/// reloads the object to read back the field the setter just wrote. the value
/// register still holds the stored value, so when the reload reads the same
/// object (its slot matches the load that fed the setter) the reload and the
/// refetch are a no-op and both drop; the value register already holds the
/// field's value for the consumers of the refetch.
///
/// this is the readback that `shiftSetterCopy` collapses when it sits right
/// after the setter; here the compiler emitted a reload in between, so the
/// register value still proves the field's value only if the object is
/// provably the same one the setter wrote to
fn eliminateFieldRefetch(i: usize, insts: []*ir.IrInst, live: []bool, is_target: []const bool) void {
    const set = insts[i];
    const obj_reg = set.result_reg;
    const val_reg = obj_reg + 1;
    if (i + 2 >= insts.len) return;
    if (!live[i + 1] or !live[i + 2]) return;
    const reload = insts[i + 1];
    if (reload.opcode != .load_local) return;
    if (reload.result_reg != val_reg) return;
    const slot = reload.op_arg;
    if (!isFieldReadback(insts[i + 2], set.opcode, set.op_arg, val_reg)) return;
    if (is_target[i + 1] or is_target[i + 2]) return;

    // the setter's object register must have been loaded from the same slot,
    // with no branch into the run and no rewrite of the register or the slot
    // in between, or the reload reads a different object than the setter
    var obj_load: ?usize = null;
    var k: usize = i;
    while (k > 0) {
        k -= 1;
        if (!live[k]) continue;
        if (is_target[k]) return;
        if (ir.isBranch(insts[k].opcode)) return;
        if (writesReg(insts[k], obj_reg)) {
            if (insts[k].opcode != .load_local or insts[k].op_arg != slot) return;
            obj_load = k;
            break;
        }
    }
    const ol = obj_load orelse return;
    for (ol + 1..i + 3) |j| {
        if (!live[j]) continue;
        switch (insts[j].opcode) {
            .bind_local, .store_local => if (insts[j].op_arg == slot) return,
            else => {},
        }
    }

    // the reload is immediately followed by the refetch, so the refetch is
    // the only reader of the reload's result; dropping both leaves the value
    // register holding the stored value, which is what the refetch produced
    live[i + 1] = false;
    live[i + 2] = false;
}

/// `load_local rX, slot; table_get_atom rX, rX, off` reloads an object that
/// an earlier live `load_local rO, slot` already fetched and that is still
/// sitting in rO: nothing rewrites rO or the slot and no branch enters or
/// leaves the run, so the field read can consume rO directly and the reload
/// drops. field assignment compiles the object first (for the setter) and
/// then reloads it once per field read, so this folds those reloads away.
fn reuseObjectLoad(i: usize, insts: []*ir.IrInst, live: []bool, is_target: []const bool) void {
    const inst = insts[i];
    if (inst.operands.len != 1) return;
    const obj_val = inst.operands[0];
    if (obj_val != .inst) return;
    const obj_inst = obj_val.inst;
    if (obj_inst.opcode != .load_local) return;
    const obj_reg = obj_inst.result_reg;
    const slot = obj_inst.op_arg;

    var reuse: ?usize = null;
    var redundant: ?usize = null;
    var j = i;
    while (j > 0) {
        j -= 1;
        if (!live[j]) continue;
        if (is_target[j]) return;
        if (ir.isBranch(insts[j].opcode)) return;
        switch (insts[j].opcode) {
            .bind_local, .store_local => if (insts[j].op_arg == slot) return,
            else => {},
        }
        // the read's own load writes obj_reg; it is the redundant reload, not
        // a clobber of the object, so keep scanning past it
        if (insts[j] == obj_inst) {
            redundant = j;
            continue;
        }
        if (writesReg(insts[j], obj_reg)) return;
        if (insts[j].opcode == .load_local and insts[j].op_arg == slot and insts[j].result_reg != obj_reg) {
            reuse = j;
            break;
        }
    }
    const r_idx = reuse orelse return;
    const r_reg = insts[r_idx].result_reg;

    // the candidate's register must still hold the slot's value when the read
    // runs: nothing may rewrite it (the slot writes were checked above)
    for (r_idx + 1..i) |k| {
        if (!live[k]) continue;
        if (writesReg(insts[k], r_reg)) return;
    }

    inst.operands[0] = .{ .inst = insts[r_idx] };
    if (redundant) |rd| live[rd] = false;
}

fn isFieldReadback(inst: *const ir.IrInst, set_op: Opcode, field: Operand, reg: Register) bool {
    if (set_op != .table_set_atom) return false;
    if (inst.opcode != .table_get_atom) return false;
    if (inst.result_reg != reg) return false;
    if (inst.op_arg != field) return false;
    return true;
}

/// `t.field = value` compiles to `move rD, rS` (a dup of the object) followed
/// by the value expression and a `table_set_atom` that reads the object and
/// the value back-to-back from `result_reg` and `result_reg + 1`. the copy
/// only exists to lay the value next to the object, so when the whole value
/// expression is straight-line and never touches the object register, shift
/// every value register down one, point the setter at the object register,
/// and drop the copy.
///
/// when the assignment's expression result reads the stored field back with a
/// `table_get_atom` that follows the setter, drop that readback, the shifted
/// value already occupies the result register. later reads of that
/// register are legitimate consumers of the assignment result
///
/// the shift is safe only if no instruction between the copy and the setter
/// writes either register, no later instruction reads the freed dup register
/// (the assignment's expression result reads it back), and no raw `.reg`
/// operand anywhere after the copy points into the shifted value range.
fn shiftSetterCopy(i: usize, insts: []*ir.IrInst, live: []bool, is_target: []const bool, read_buf: []Register, user_idx: usize) bool {
    const m = insts[i];
    if (m.operands[0] != .inst) return false;
    const src_reg = m.operands[0].inst.result_reg;
    const dst_reg = m.result_reg;
    const user = insts[user_idx];
    // the copy must sit one above the object so the value, shifted down by
    // one, lands exactly where the setter reads it next to the object
    if (dst_reg != src_reg + 1) return false;
    if (user.result_reg != dst_reg) return false;
    if (is_target[user_idx]) return false;

    // the value expression between the copy and the setter must be
    // straight-line, must not touch the object or the copy register, must
    // stay above the copy's register (its lowest register is dst after the
    // shift), and must reference registers only through instructions
    var value_max: Register = dst_reg;
    for (i + 1..user_idx) |k| {
        if (!live[k]) continue;
        if (is_target[k]) return false;
        switch (insts[k].opcode) {
            .jump, .jump_if_false, .jump_if_true, .jump_err => return false,
            else => {},
        }
        if (writesReg(insts[k], src_reg)) return false;
        if (writesReg(insts[k], dst_reg)) return false;
        if (insts[k].result_reg <= dst_reg) return false;
        for (insts[k].operands) |op| if (op == .reg) return false;
        if (insts[k].result_reg > value_max) value_max = insts[k].result_reg;
    }

    // the setter's expression result reads the stored field back with a
    // `table_get_atom` right after the set; drop that readback, the shifted
    // value already occupies the result register. later reads of that
    // register are legitimate consumers of the assignment result
    var readback: ?usize = null;
    for (user_idx + 1..insts.len) |k| {
        if (!live[k]) continue;
        if (readback == null and k == user_idx + 1 and isFieldReadback(insts[k], user.opcode, user.op_arg, dst_reg)) {
            readback = k;
            continue;
        }
        if (readback == null) {
            if (readsReg(insts[k], dst_reg, read_buf)) return false;
        }
        for (insts[k].operands) |op| {
            if (op == .reg and op.reg > dst_reg and op.reg <= value_max) return false;
        }
        if (writesReg(insts[k], dst_reg)) break;
    }

    // shift the value expression down one register, point the setter at the
    // object register, and let the compaction drop the copy and the readback
    for (i + 1..user_idx) |k| {
        if (!live[k]) continue;
        insts[k].result_reg -= 1;
    }
    user.result_reg = src_reg;
    live[i] = false;
    if (readback) |rb| live[rb] = false;
    return true;
}

fn readsReg(inst: *const ir.IrInst, reg: Register, buf: []Register) bool {
    const cnt = ir.readRegsAll(inst, buf);
    for (buf[0..cnt]) |r| if (r == reg) return true;
    return false;
}

fn writesReg(inst: *const ir.IrInst, reg: Register) bool {
    var buf: [3]Register = undefined;
    const cnt = ir.writeRegs(inst, &buf);
    for (buf[0..cnt]) |r| if (r == reg) return true;
    return false;
}

/// `move rA, rA` is a register no-op: repoint users so their `.inst`
/// operands stay valid, then drop it. anything more global (destination
/// overwritten before read) is dce's job via register liveness
fn eliminateSelfMove(i: usize, insts: []*ir.IrInst, live: []bool) void {
    const m = insts[i];
    if (m.operands.len != 1) return;
    const src_val = m.operands[0];
    if (ir.valueReg(src_val) != m.result_reg) return;
    ir.repointUsers(insts, i + 1, m, src_val);
    live[i] = false;
}

/// `jump_if_false rA, L1; jump L2; L1: ...` inverts to
/// `jump_if_true rA, L2; L1: ...` when L1 is the very next slot, dropping
/// the unconditional jump
fn invertBranch(i: usize, insts: []*ir.IrInst, live: []bool) bool {
    const inst = insts[i];
    const j = i + 1;
    if (j >= insts.len) return false;
    if (!live[j]) return false;
    if (insts[j].opcode != .jump) return false;
    if (inst.op_arg != j + 1) return false;
    inst.opcode = if (inst.opcode == .jump_if_false) .jump_if_true else .jump_if_false;
    inst.op_arg = insts[j].op_arg;
    live[j] = false;
    return true;
}
