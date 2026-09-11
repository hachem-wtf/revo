const std = @import("std");
const revo = @import("revo");
const api = @import("api.zig");
const root = @import("root.zig");
const table_std = @import("table.zig");
// const pool = @import("pool.zig");
const Ts = root.T;

const math = std.math;
const typeof = root.typeof;
const memory = revo.memory;
const Data = memory.Data;
const VM = revo.VM;
const HostResult = root.HostResult;
const Table = revo.table.Table;
const testing = revo.lang.testing;
const table_methods = table_std.Impl;

// type Frame = table<string, table<any>>

pub const Impl = struct {

    // frame.select(Frame, table<string>) -> Frame
    pub fn select(vm: *VM, frame_table_id: Ts.table, names_table_id: Ts.table) !HostResult {
        const frame_table = try vm.tables.get(@intFromEnum(frame_table_id));
        const names_table = try vm.tables.get(@intFromEnum(names_table_id));
        const result_table_id = try vm.tables.create();
        const result_table = try vm.tables.get(result_table_id);

        // In order of strings given to the select() function
        for (names_table.array.items) |colname| {
            // if the array string is in the hashmap
            const maybe_coltable = frame_table.getRaw(colname, vm);
            if (maybe_coltable) |coltable| {
                // clone it, place it in the result table under the same string name
                const copied_table_id = switch (try table_methods.copy(vm, @enumFromInt(coltable.asTable().?))) {
                    .ok => |v| v.asTable().?,
                    .err => |e| return .{ .err = e },
                };
                try result_table.put(result_table_id, vm, colname, Data.new.table(copied_table_id));
            }
        }

        return .data(Data.new.table(result_table_id));
    }
};

pub const impls: []const api.Impl = root.impls(Impl).val;

// frame.rename(Frame) -> Frame
// frame.arrange(Frame) -> Frame
// frame.unique(Frame) -> Frame
// frame.mutate(Frame) -> Frame
// frame.filter(Frame) -> Frame
// frame.summarize(Frame) -> Frame
// frame.group_by(Frame) -> Frame
// frame.gather(Frame) -> Frame
// frame.inner_join(Frame) -> Frame
// frame.stack(table<Frame>) -> Frame

test "frame functions and methods" {
    try testing.topTrue("{\"foos\" = {1, 2, 3}, \"bars\" = {4, 5, 6}, \"bazzes\" = {7, 8, 9}} |> frame.select({\"foos\", \"bazzes\"}) == {\"foos\" = {1, 2, 3}, \"bazzes\" = {7, 8, 9}}");
}
