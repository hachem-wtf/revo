const Ts = root.T;

pub const Impl = struct {
    pub fn len(vm: *VM, self: Ts.tuple) !HostResult {
        const t = try vm.tuples.get(@intFromEnum(self));
        return .data(Data.new.num(t.items.len));
    }

    pub fn add(vm: *VM, self: Ts.tuple, other: Ts.tuple) !HostResult {
        const left = try vm.tuples.get(@intFromEnum(self));
        const right = try vm.tuples.get(@intFromEnum(other));
        var items = try std.ArrayList(Data).initCapacity(vm.runtime.alloc, left.items.len + right.items.len);

        defer items.deinit(vm.runtime.alloc);
        try items.appendSlice(vm.runtime.alloc, left.items);
        try items.appendSlice(vm.runtime.alloc, right.items);

        return .data(Data.new.tuple(try vm.tuples.create(items.items)));
    }

    pub fn mul(vm: *VM, self: Ts.tuple, n: Ts.number) !HostResult {
        const times: i64 = root.numToInt(i64, n) orelse return .errType(1, "integer num", typeof(Data.new.num(n), vm));
        if (times < 0) return .errType(1, "non-negative num", "negative num");
        const tuple = try vm.tuples.get(@intFromEnum(self));
        var items = try std.ArrayList(Data).initCapacity(vm.runtime.alloc, tuple.items.len * @as(usize, @intCast(times)));
        defer items.deinit(vm.runtime.alloc);
        for (0..@as(usize, @intCast(times))) |_| {
            try items.appendSlice(vm.runtime.alloc, tuple.items);
        }
        return .data(Data.new.tuple(try vm.tuples.create(items.items)));
    }

    pub fn repeat(vm: *VM, self: Ts.tuple, n: Ts.number) !HostResult {
        return mul(vm, self, n);
    }
};

pub const impls: []const api.Impl = root.impls(Impl).val ++ &[_]api.Impl{
    .{ .name = "unwrap", .f = root.define(&[_]root.TypeSpec{.tuple}, root.try_) },
    .{ .name = "unwrap_err", .f = root.define(&[_]root.TypeSpec{.tuple}, root.unwrap_err_) },
};

test "generic unwrap_err infers T" {
    try testing.topString("(:err, \"boom\"):unwrap_err()", "boom");
    try testing.topNumber("(:err, 7):unwrap_err()", 7);
}

test "untyped receivers resolve module fns via the metatable" {
    try testing.topNumber("fn f(t) do t:unwrap_err() end f((:err, 3))", 3);
    try testing.topNumber("fn f(t) do t:len() end f((1, 2, 3))", 3);
}

test "tuple add and repeat" {
    try testing.topNumber("(1, 2):add((3, 4)):len()", 4);
    try testing.topNumber("(1, 2):repeat(3):len()", 6);
    try testing.topNumber("(1, 2):repeat(0):len()", 0);
}

const std = @import("std");

const revo = @import("../root.zig");
const Data = revo.Data;
const VM = revo.VM;
const api = @import("api.zig");
const root = @import("root.zig");
const HostResult = root.HostResult;
const typeof = root.typeof;
const testing = revo.lang.testing;
