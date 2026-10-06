const std = @import("std");

const revo = @import("revo");
const lang = revo.lang;
const testing = revo.lang.test_helpers;
const Value = revo.Value;

pub fn runModule(vm: *revo.VM, source_path: []const u8, source: []const u8, module_scope: bool) !revo.RunResult {
    const opts: lang.BuildOptions = if (module_scope) .{ .module_scope = true } else .{};
    const bytecode = switch (try lang.build(vm, .{ .name = source_path, .text = source }, opts)) {
        .ok => |ok| ok,
        .err => |lang_err| {
            revo.printBuildError(vm.runtime.diagAlloc(), .{ .name = source_path, .text = source }, lang_err, vm.runtime.supports_color);
            vm.runtime.resetDiagArena();
            return error.ParseError;
        },
    };
    defer vm.runtime.alloc.free(bytecode.instructions);
    defer vm.runtime.alloc.free(bytecode.spans);
    return runBytecodeReport(vm, source_path, bytecode.instructions);
}

pub fn runImportedModule(vm: *revo.VM, source_path: []const u8, source: []const u8) !revo.Value {
    const result = try runModule(vm, source_path, source, true);
    if (result == .err) return error.RuntimeFailure;
    return vm.currentFiber().result;
}

fn swapFiberAndRun(
    vm: *revo.VM,
    source_path: []const u8,
    program: []const revo.Instruction,
) !struct { result: revo.RunResult, prev: revo.VM.Fiber } {
    try vm.setProgramSourceName(source_path);

    const import_dir = std.Io.Dir.path.dirname(source_path) orelse ".";
    const prev_import_dir = vm.import_dir;
    vm.import_dir = import_dir;
    defer vm.import_dir = prev_import_dir;

    vm.closeUpvalueList(vm.currentFiber(), 0) catch {};

    var fiber = try revo.VM.Fiber.init(vm.runtime.alloc, vm.currentFiber().id, program, revo.VM.INIT_REG_COUNT);
    fiber.debug_info_id = vm.pending_debug_info_id;

    const outer_idx = vm.sched.currentID();
    const prev = vm.swapFiber(fiber);
    errdefer {
        vm.sched.setCurrent(outer_idx);
        var finished = vm.swapFiber(prev);
        vm.closeUpvalueList(&finished, 0) catch {};
        revo.VM.Fiber.deinit(&finished, vm.runtime.alloc);
    }
    const result = try revo.vm.dispatch.runReport(vm);
    vm.sched.setCurrent(outer_idx);
    return .{ .result = result, .prev = prev };
}

pub fn runBytecodeReport(
    vm: *revo.VM,
    source_path: []const u8,
    program: []const revo.Instruction,
) !revo.RunResult {
    try vm.setProgramSourceName(source_path);

    var r = try swapFiberAndRun(vm, source_path, program);
    defer {
        var finished = vm.swapFiber(r.prev);
        // close upvalues captured by the old fiber before its registers are
        // freed: globals survive reloads and may hold closures that read them
        vm.closeUpvalueList(&finished, 0) catch {};
        revo.VM.Fiber.deinit(&finished, vm.runtime.alloc);
    }
    if (r.result == .ok) r.prev.result = vm.currentResult();
    return r.result;
}

test "module message setters clear previous values" {
    var vm = try revo.VM.init(testing.runtime());
    defer vm.deinit();

    try vm.setProgramDebugInfo(&.{}, "", "one.rv");
    try vm.setProgramSourceName("one.rv");
    try std.testing.expectEqualStrings("one.rv", vm.currentDebugSourceName().?);
    try vm.setProgramSourceName("two.rv");
    try std.testing.expectEqualStrings("two.rv", vm.currentDebugSourceName().?);

    try vm.setPanicMessage("panic-a");
    try std.testing.expectEqualStrings("panic-a", vm.panic_message.?);
    try vm.setPanicMessage("panic-b");
    try std.testing.expectEqualStrings("panic-b", vm.panic_message.?);
    vm.clearPanicMessage();
    try std.testing.expect(vm.panic_message == null);

    try vm.setRuntimeMessage("runtime-a");
    try std.testing.expectEqualStrings("runtime-a", vm.runtime_message.?);
    try vm.setRuntimeMessageFmt("runtime-{d}", .{7});
    try std.testing.expectEqualStrings("runtime-7", vm.runtime_message.?);
    vm.clearRuntimeMessage();
    try std.testing.expect(vm.runtime_message == null);
}

test "module hot reload cache" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "hot.rv",
        .data =
        \\ 1
        ,
    });

    const import_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(import_dir);

    const source_name = try alloc.print("{s}/script.rv", .{import_dir});
    defer alloc.free(source_name);

    const code =
        \\ const ns = import "./hot"
        \\ ns
    ;

    var vm = try revo.VM.init(testing.runtime());
    defer vm.deinit();
    vm.import_dir = import_dir;

    const bytecode = switch (try lang.build(&vm, .{ .name = source_name, .text = code }, .{})) {
        .ok => |ok| ok,
        .err => return error.ParseError,
    };
    defer vm.runtime.alloc.free(bytecode.instructions);
    defer vm.runtime.alloc.free(bytecode.spans);

    _ = try runBytecodeReport(&vm, source_name, bytecode.instructions);
    try std.testing.expectEqual(Value.new.num(1), vm.mainResult());

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "hot.rv",
        .data =
        \\ 2
        ,
    });

    _ = try runBytecodeReport(&vm, source_name, bytecode.instructions);
    try std.testing.expectEqual(Value.new.num(2), vm.mainResult());
}
