const Args = root.host.ArgTypes;

const diagnostic = revo.lang.diagnostic;

fn runSource(vm: *VM, name: []const u8, src: []const u8, module_scope: bool) !HostResult {
    const bytecode = switch (revo.lang.build(
        vm,
        .{ .name = name, .text = src },
        .{ .module_scope = module_scope },
    ) catch |err| return .other(@errorName(err))) {
        .ok => |ok| ok,
        .err => |build_err| {
            const rep = revo.lang.pipeline.errorReport(build_err);
            const table = try diagnostic.evalErrorTable(vm, rep, name, src, @tagName(build_err), null, &.{});
            vm.runtime.resetDiagArena();
            return HostResult.errValue(vm, table);
        },
    };
    defer vm.runtime.alloc.free(bytecode.instructions);
    defer vm.runtime.alloc.free(bytecode.spans);
    const result = revo.run.runBytecodeReport(vm, name, bytecode.instructions) catch |err| return .other(@errorName(err));
    return switch (result) {
        .ok => HostResult.Ok(vm, vm.currentFiber().result),
        .err => |failure| {
            var rep = failure.report;
            rep.parts = failure.parts[0..failure.part_len];
            return HostResult.errValue(vm, try diagnostic.evalErrorTable(
                vm,
                rep,
                name,
                src,
                "runtime",
                @tagName(failure.kind),
                failure.trace[0..failure.trace_len],
            ));
        },
    };
}

pub const Impl = struct {
    pub fn eval(vm: *VM, source: Args.string) !HostResult {
        const src = vm.stringValue(@backingInt(source));
        return runSource(vm, "<eval>", src, true);
    }

    pub fn compile(vm: *VM, source: Args.string) !HostResult {
        const src = vm.stringValue(@backingInt(source));
        const result = revo.lang.build(vm, .{ .text = src, .name = "<anon>" }, .{}) catch |err| return .other(@errorName(err));
        switch (result) {
            .ok => |bytecode| {
                defer vm.runtime.alloc.free(bytecode.instructions);
                defer vm.runtime.alloc.free(bytecode.spans);
                const bc = try revo.bytecode.serialize(vm, bytecode, vm.runtime.alloc);
                defer vm.runtime.alloc.free(bc);
                const sid = try vm.strings.own(bc);
                return HostResult.Ok(vm, Value.new.str(sid));
            },
            .err => |build_err| {
                const rep = revo.lang.pipeline.errorReport(build_err);
                const table = try diagnostic.evalErrorTable(vm, rep, "<anon>", src, @tagName(build_err), null, &.{});
                vm.runtime.resetDiagArena();
                return HostResult.errValue(vm, table);
            },
        }
    }

    pub fn version(vm: *VM) !HostResult {
        const v = @import("build_options").version;
        return if (@import("builtin").mode == .debug)
            .data(try vm.ownValueString("revo #" ++ v))
        else
            .data(try vm.ownValueString("revo v" ++ v));
    }

    pub fn threads(vm: *VM) !HostResult {
        return .data(Value.new.num(vm.sched.thread_count));
    }
};

pub const impls: []const specs.Impl = root.host.impls(Impl).val ++ &[_]specs.Impl{
    .{ .name = "dofile", .f = if (@import("build_options").is_freestanding) root.host.defineStub(&.{.string}) else root.host.define(&.{.string}, dofile) },
};

test "native eval works" {
    try testing.topNumber(
        \\ const {_, res} = revo.eval("21*2")
        \\ res
    , 42);
}

test "revo.compile compiles source" {
    try testing.topAtom(
        \\ revo.compile("1 + 1")[0]
    , "ok");
}

test "eval diags" {
    try testing.topAtom(
        \\ match revo.eval("let x: num = 'hi'") | {:ok, _} => :unexpected_ok | {:err, e} => e.phase
    , "semantic");
    try testing.topString(
        \\ match revo.eval("let x: num = 'hi'") | {:ok, _} => "unexpected-ok" | {:err, e} => e.code
    , "type-mismatch");
    try testing.topNumber(
        \\ match revo.eval("let x: num = 'hi'") | {:ok, _} => -1 | {:err, e} => e.line
    , 1);
    try testing.topAtom(
        \\ match revo.eval("1 + * 2") | {:ok, _} => :unexpected_ok | {:err, e} => e.phase
    , "parse");
    try testing.topNumber(
        \\ match revo.eval("1 + * 2") | {:ok, _} => -1 | {:err, e} => e.line
    , 1);
    try testing.topNumber(
        \\ match revo.eval("1 + * 2") | {:ok, _} => -1 | {:err, e} => e.column
    , 7);
    try testing.topAtom(
        \\ match revo.eval("1 + * 2") | {:ok, _} => :unexpected_ok | {:err, e} => e.rendered:contains?("-->")
    , "true");
    try testing.topAtom(
        \\ match revo.eval("let x = )") | {:ok, _} => :unexpected_ok | {:err, e} => e.line == :nil
    , "true");
    try testing.topAtom(
        \\ match revo.eval("let x = )") | {:ok, _} => :unexpected_ok | {:err, e} => e.phase
    , "parse");
    try testing.topAtom(
        \\ match revo.eval("nosuchmacro!(1)") | {:ok, _} => :unexpected_ok | {:err, e} => e.phase
    , "expand");
    try testing.topAtom(
        \\ match revo.eval("1/0") | {:ok, _} => :unexpected_ok | {:err, e} => e.phase
    , "runtime");
    try testing.topString(
        \\ match revo.eval("1/0") | {:ok, _} => "unexpected-ok" | {:err, e} => e.kind
    , "DivisionByZero");
    try testing.topString(
        \\ match revo.eval("1/0") | {:ok, _} => "unexpected-ok" | {:err, e} => e.message
    , "division by zero!");
    try testing.topAtom(
        \\ match revo.eval("1/0") | {:ok, _} => :unexpected_ok | {:err, e} => e.trace:len() > 0
    , "true");
    try testing.topAtom(
        \\ match revo.compile("let x = )") | {:ok, _} => :unexpected_ok | {:err, e} => e.phase
    , "parse");
}

pub fn dofile(args: []const Value, vm: *VM) !HostResult {
    if (args.len != 1) return .errArity(args.len, 1);

    const path = switch (args[0].tag()) {
        .string => vm.stringValue(args[0].asString().?),
        else => return .errType(0, "string", typeof(args[0], vm)),
    };

    // import-style resolution: ./mod.rv means "next to the script", not
    // "next to the cwd"; raw path is the fallback for repl/-e runs
    const resolved: ?[]const u8 = revo.resolveImportFile(
        vm.runtime.io,
        vm.runtime.alloc,
        path,
        vm.import_dir,
        vm.project_root,
        vm.package_path.items,
    ) catch null;
    defer if (resolved) |p| vm.runtime.alloc.free(p);
    const real_path = resolved orelse path;

    const source = std.Io.Dir.cwd().readFileAlloc(
        vm.runtime.io,
        real_path,
        vm.runtime.alloc,
        .limited(fs.max_read_size),
    ) catch |err| {
        const rep: diagnostic.Report = .{ .message = @errorName(err) };
        return HostResult.errValue(vm, try diagnostic.evalErrorTable(vm, rep, real_path, "", "io", null, &.{}));
    };
    defer vm.runtime.alloc.free(source);

    return runSource(vm, real_path, source, false);
}

test "revo.dofile returns the file's value" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "hi.rv", .data = "{x = 2}" });

    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);
    const file_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ dir_path, "hi.rv" });
    defer std.testing.allocator.free(file_path);

    const source = try std.testing.allocator.print(
        \\ const {{_, res}} = revo.dofile('{s}')
        \\ res.x
    , .{file_path});
    defer std.testing.allocator.free(source);

    try testing.topNumber(source, 2);
}

test "revo.dofile resolves relative paths against the module dir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "dep.rv", .data = "\"from-dep\"" });

    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    try testing.topStringInDir(dir_path,
        \\ revo.dofile("./dep.rv")[1]
    , "from-dep");
}

const revo = @import("../root.zig");
const testing = revo.lang.test_helpers;
const std = @import("std");
const Value = revo.Value;
const VM = revo.VM;
const fs = @import("fs.zig");
const root = @import("root.zig");
const specs = @import("specs.zig");
const HostResult = root.host.HostResult;
const typeof = root.typeof;
