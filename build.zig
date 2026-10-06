const bindings = @import("src/capi/header_gen.zig");
const builtin = @import("builtin");
const std = @import("std");
const Translator = @import("translate_c").Translator;

const Build = std.Build;
const Module = Build.Module;
const logger = std.log.scoped(.@"build/revo");

const VERSION = "0.1.2";

const ReleaseTarget = struct {
    triple: []const u8,
    wasi_cli: bool = false,
};

const release_targets: []const ReleaseTarget = &.{
    .{ .triple = "aarch64-macos" }, // good
    // golden target for linux (static musl cant load .so's)
    .{ .triple = "x86_64-linux-gnu" }, // good
    .{ .triple = "aarch64-linux-gnu" }, // probably good
    // plus static musl ones for machines with no (or ancient) glibc
    .{ .triple = "x86_64-linux-musl" }, // good
    .{ .triple = "aarch64-linux-musl" }, // probably good
    .{ .triple = "x86_64-macos" }, // untested
    .{ .triple = "x86_64-windows" }, // missing dll loading, isocline and async
    // we want at least one freestanding target in the matrix
    //   at all times to confirm this can work on the rest of freestanding
    .{ .triple = "wasm32-freestanding" }, // good, see `wasm/`
    // .{ .triple = "wasm64-freestanding" }, // good, see `wasm/`. use wasm32 instead
    .{ .triple = "wasm32-wasi" }, // web build with js host imports
    .{ .triple = "wasm32-wasi", .wasi_cli = true }, // cli build with wasi syscalls (wasmtime/runnable)

    // entirely untested:
    .{ .triple = "x86_64-freebsd-none" }, // probably good
    .{ .triple = "x86_64-openbsd-none" }, // probably good
    // nobody runs netbsd anymore
};

const Features = packed struct {
    /// ~ requires libc, not available on windows/wasi/freestanding
    isocline: bool = false,
    /// ~  available everywhere except freestanding
    lsp: bool = false,
    /// ~  available everywhere
    regex: bool = false,
    /// ~  available everywhere except freestanding
    mimalloc: bool = false,
    /// ~ dynamic c calls need dlopen; posix only
    ffi: bool = false,
    zig_backend: bool = false,
    // ~ async: requires posix threads, not available on windows/wasi/freestanding
};

const release_target_queries = blk: {
    // zig master's target-query parse path can exceed the default comptime quota???
    @setEvalBranchQuota(200_000);
    // pre-computes queries
    var arr: [release_targets.len]std.Target.Query = undefined;
    var bad_targets: []const u8 = &.{};
    for (release_targets, &arr) |target_def, *out| {
        out.* = std.Target.Query.parse(.{ .arch_os_abi = target_def.triple }) catch {
            if (bad_targets.len >= 1) {
                bad_targets = bad_targets ++ ", ";
            }
            bad_targets = bad_targets ++ "\"" ++ target_def.triple ++ "\"";
        };
    }
    if (bad_targets.len >= 1) {
        @compileError("Invalid target(s): " ++ bad_targets);
    }

    const c_arr = arr;
    break :blk &c_arr;
};

const BinaryType = enum { nightly, release };

fn emptyStr(s: []const u8) bool {
    for (s) |c| switch (c) {
        ' ', '\n', '\r', '\t' => continue,
        else => return false,
    } else return true;
}

fn getFeatures(features: []const u8) Features {
    var ret = Features{};
    if (features.len == 0) return ret;

    var it = std.mem.splitScalar(u8, features, ',');
    while (it.next()) |token| {
        if (emptyStr(token)) continue;

        const info = @typeInfo(Features).@"struct";
        inline for (info.field_names) |field_name| {
            if (std.mem.eql(u8, token, field_name)) {
                if (@field(ret, field_name)) {
                    std.log.warn("Duplicate feature: {s}", .{token});
                }
                @field(ret, field_name) = true;
                break;
            }
        } else std.log.warn("Unknown feature: {s}", .{token});
    }
    return ret;
}

/// for release bin names
fn binName(b: *std.Build, triple: []const u8, btype: BinaryType) []const u8 {
    const epoch_secs = std.time.epoch.EpochSeconds{
        .secs = @intCast(std.Io.Clock.real.now(b.graph.io).toSeconds()),
    };
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const date_str = b.fmt("{d}{d:0>2}{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
    });
    return switch (btype) {
        .nightly => b.fmt("revo-nightly-{s}-{s}", .{ triple, date_str }),
        .release => b.fmt("revo-{s}-{s}", .{ VERSION, triple }),
    };
}

pub fn build(b: *Build) !void {
    // Defaults to 'musl' toolchain for linux system because otherwise the build fails with default settings,
    // but not when enabled 'llvm' and 'lld'. -hamza (Jun 14 2026)
    const with_glibc = builtin.target.os.tag == .linux and
        (b.option(bool, "glibc", "build with LLVM and link with glibc") orelse false);

    const with_dynamic = b.option(bool, "dynamic", "force dynamic libc linking if available (warns if unsupported)") orelse true;
    // if (with_dynamic and builtin.target.os.tag != .linux) {
    //     logger.warn("-Ddynamic is only meaningful on linux (other platforms already use dynamic libc)", .{});
    // }

    const wasi_cli = b.option(bool, "wasi-cli", "build wasi target as cli (uses wasi syscalls instead of js imports)") orelse false;

    const target = if (builtin.target.os.tag == .linux)
        b.standardTargetOptions(.{ .default_target = if (with_glibc or with_dynamic) .{ .abi = .gnu } else .{ .abi = .musl } })
    else
        b.standardTargetOptions(.{});

    const is_freestanding = target.result.os.tag == .freestanding;
    const is_wasm = target.result.cpu.arch.isWasm();

    const optimize = b.standardOptimizeOption(.{});

    const perf = b.option(bool, "perf", "enable VM perf counters") orelse false;

    // botch: wasm64 has a codegen bug in Debug mode that causes "memory access out of
    // bounds" at runtime for some reason
    // force ReleaseSmall for ALL modules linked into the wasm binary, so the VM code gets the fix too
    const effective_optimize: std.lang.Optimize = if (is_wasm) .small else optimize;
    if (optimize != effective_optimize)
        logger.warn("Debug mode crashes wasm64 builds; forcing ReleaseSmall for all modules", .{});

    const features_str = b.option([]const u8, "features", "available: isocline, lsp, regex, mimalloc, ffi, zig_backend") orelse
        // isocline needs libc and not wasm; wasi gets lsp but not isocline
        // async is disabled on windows/wasi/freestanding (handled in src/root.zig)
        if (is_freestanding) "" else if (is_wasm) "lsp,regex" else "isocline,lsp,regex,mimalloc,ffi";

    // windows missing features: isocline (no libc), ffi (no dlopen), async (no posix threads)
    if (builtin.target.os.tag == .windows) {
        if (std.mem.find(u8, features_str, "isocline") != null) {
            logger.warn("isocline is not available on windows, disabling", .{});
        }
        if (std.mem.find(u8, features_str, "ffi") != null) {
            logger.warn("ffi is not available on windows, disabling", .{});
        }
    }

    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "only run tests within the arr",
    ) orelse &.{};

    const lsp_kit_dep = b.dependency("lsp_kit", .{});

    const features = getFeatures(features_str);

    const mimalloc_enabled = !is_freestanding and features.mimalloc;
    const ffi_enabled = !is_freestanding and !is_wasm and target.result.os.tag != .windows and features.ffi;

    const git_result = b.runFallible(&.{ "git", "rev-parse", "--short", "HEAD" }, .{
        .stderr_behavior = .ignore,
    });
    const git_version = switch (git_result) {
        .success => |output| output,
        else => VERSION,
    };

    const dev_version = std.mem.trim(u8, git_version, " \n\r");

    // used for dev builds
    const debug_options = b.addOptions();
    debug_options.addOption(bool, "is_freestanding", is_freestanding);
    debug_options.addOption(bool, "mimalloc", mimalloc_enabled);
    debug_options.addOption(bool, "ffi", ffi_enabled);
    debug_options.addOption(bool, "isocline", features.isocline);
    debug_options.addOption(bool, "regex", features.regex);
    debug_options.addOption([]const u8, "version", VERSION);
    debug_options.addOption([]const u8, "git_commit", dev_version);
    debug_options.addOption(bool, "lsp_enabled", features.lsp);
    debug_options.addOption(bool, "perf", perf);
    const debug_options_mod = debug_options.createModule();

    // used for release builds
    // note: is_freestanding captures top-level, not per-release.
    // this doesn't really matter but it might break something
    const release_options = b.addOptions();
    release_options.addOption(bool, "is_freestanding", is_freestanding);
    release_options.addOption(bool, "mimalloc", mimalloc_enabled);
    release_options.addOption(bool, "ffi", ffi_enabled);
    release_options.addOption(bool, "isocline", features.isocline);
    release_options.addOption(bool, "regex", features.regex);
    release_options.addOption([]const u8, "version", VERSION);
    release_options.addOption([]const u8, "git_commit", dev_version);
    release_options.addOption(bool, "lsp_enabled", features.lsp);
    release_options.addOption(bool, "perf", perf);
    const release_options_mod = release_options.createModule();

    //
    // modules
    //
    const isocline_mod = builds.isocline(b, features.isocline, target, effective_optimize, "dev");
    const vm_mod = b.addModule("vm", .{
        .root_source_file = b.path("src/vm/root.zig"),
        .target = target,
        .optimize = effective_optimize,
        .link_libc = !is_freestanding,
    });
    const revo_mod = b.addModule("revo", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = effective_optimize,
        .link_libc = !is_freestanding,
    });
    const c_mod = b.addModule("capi", .{
        .root_source_file = b.path("src/capi/root.zig"),
        .target = target,
        .optimize = effective_optimize,
        .link_libc = !is_freestanding,
    });
    const mimalloc_mod = b.createModule(.{
        .root_source_file = b.path("src/mimalloc.zig"),
        .target = target,
        .optimize = effective_optimize,
        .link_libc = !is_freestanding,
    });
    const revolt_mod = b.createModule(.{
        .root_source_file = if (features.lsp)
            b.path("src/lsp/server.zig")
        else
            b.path("src/lsp/disabled.zig"),
        .target = target,
        .optimize = effective_optimize,
        .link_libc = !is_freestanding,
        .imports = if (features.lsp) &.{
            .{ .name = "lsp", .module = lsp_kit_dep.module("lsp") },
        } else &.{},
    });
    // wasi-cli uses cli.zig (wasi syscalls), web uses wasm_entry.zig (js imports)
    const is_wasi_cli = wasi_cli and is_wasm;
    const exe_mod = b.createModule(.{
        .root_source_file = b.path(if (is_wasi_cli) "src/cli.zig" else if (is_wasm) "src/wasm_entry.zig" else "src/cli.zig"),
        .target = target,
        .optimize = effective_optimize,
        .link_libc = !is_freestanding,
        .imports = &.{
            .{ .name = "lsp_main", .module = revolt_mod },
        },
    });
    const erevo_mod = if (!is_freestanding)
        b.addModule("embed", .{
            .root_source_file = b.path("src/capi/embed.zig"),
            .target = target,
            .optimize = effective_optimize,
            .link_libc = !is_freestanding,
        })
    else
        null;

    const all_mods: []const *Module = if (is_freestanding) &.{
        vm_mod,  revo_mod,
        c_mod,   revolt_mod,
        exe_mod,
    } else &.{
        vm_mod,  revo_mod,
        c_mod,   revolt_mod,
        exe_mod, erevo_mod.?,
    };
    var import_list: std.ArrayList(Module.Import) = .empty;
    defer import_list.deinit(b.allocator);
    try import_list.append(b.allocator, .{ .name = "revo", .module = revo_mod });
    try import_list.append(b.allocator, .{ .name = "vm", .module = vm_mod });
    try import_list.append(b.allocator, .{ .name = "capi", .module = c_mod });
    try import_list.append(b.allocator, .{ .name = "mimalloc", .module = mimalloc_mod });
    const imports = try import_list.toOwnedSlice(b.allocator);
    const shared_build_options = if (optimize == .debug) debug_options_mod else release_options_mod;
    for (all_mods) |mod| {
        for (imports) |imp| {
            mod.addImport(imp.name, imp.module);
        }
        mod.addImport("build_options", shared_build_options);
    }

    exe_mod.addImport("isocline", isocline_mod);

    // only linked into artifacts that reference it
    const mimalloc_dep = if (mimalloc_enabled) b.dependencyLazy("mimalloc", .{}) catch null else null;
    const mimalloc_lib = if (mimalloc_dep) |dep|
        try builds.mimalloc(b, target, effective_optimize, dep)
    else
        null;
    if (mimalloc_lib) |ml| {
        exe_mod.linkLibrary(ml);
        if (erevo_mod) |em| em.linkLibrary(ml);
    }

    // vendored libffi, posix only; proves fetch+configure+link
    // , nothing references its symbols yet (that lands with ffi.zig)
    const ffi_dep = if (ffi_enabled) b.dependencyLazy("libffi", .{
        .target = target,
        .optimize = effective_optimize,
    }) catch null else null;
    var test_ffi_lib: ?*std.Build.Step.Compile = null;
    if (ffi_dep) |dep| {
        const ffi_lib = dep.artifact("ffi");
        exe_mod.linkLibrary(ffi_lib);
        if (erevo_mod) |em| em.linkLibrary(ffi_lib);
        // revo_mod carriers: tests link it directly, exes inherit it
        revo_mod.linkLibrary(ffi_lib);
        test_ffi_lib = ffi_lib;

        const c_ffi: Translator = builds.translate_c_header(
            b,
            b.dependency("translate_c", .{}),
            "c_ffi",
            "ffi.h",
            target,
            effective_optimize,
        );
        c_ffi.linkLibrary(ffi_lib);
        revo_mod.addImport("c_ffi", c_ffi.mod);
    }

    if (features.isocline and !is_freestanding) {
        const c_signal: Translator = builds.translate_c_header(
            b,
            b.dependency("translate_c", .{}),
            "c_signal",
            "signal.h",
            target,
            effective_optimize,
        );
        exe_mod.addImport("c_signal", c_signal.mod);
    }

    const header_wf = b.addWriteFiles();
    const header_data = bindings.data(b.allocator, VERSION) catch |err| {
        std.debug.print("failed to autogen header\n", .{});
        return err;
    };
    _ = header_wf.add("revo.h", header_data);

    const vm_test = b.addTest(.{ .root_module = vm_mod, .filters = test_filters });
    const revo_test = b.addTest(.{ .root_module = revo_mod, .filters = test_filters });
    const exe_test = b.addTest(.{ .root_module = exe_mod, .filters = test_filters });
    const c_test = b.addTest(.{ .root_module = c_mod, .filters = test_filters });
    const revolt_test = b.addTest(.{ .root_module = revolt_mod, .filters = test_filters });
    // header_gen unit tests (type mapping, REVO_API emission, dup/export checks)
    const header_gen_mod = b.createModule(.{
        .root_source_file = b.path("src/capi/header_gen.zig"),
        .target = target,
        .optimize = effective_optimize,
    });
    const header_test = b.addTest(.{ .root_module = header_gen_mod, .filters = test_filters });

    if (is_freestanding) {
        const wasm_lib = b.addExecutable(.{ .name = "revo", .root_module = exe_mod });
        wasm_lib.entry = .disabled;
        wasm_lib.rdynamic = true;
        // the vm dispatch loop's frame alone can exceed the default 1mb size in ReleaseSafe
        wasm_lib.stack_size = 16 * 1024 * 1024;
        const wasm_install = b.addInstallArtifact(wasm_lib, .{});
        b.getInstallStep().dependOn(&wasm_install.step);
    } else if (is_wasm) {
        // wasm builds (wasi-cli) need larger stack for dispatch frame
        // yes its that big lol my bad
        const wasm_exe = b.addExecutable(.{ .name = "revo", .root_module = exe_mod });
        wasm_exe.stack_size = 16 * 1024 * 1024;
        wasm_exe.rdynamic = true;
        const wasm_install = b.addInstallArtifact(wasm_exe, .{});
        b.getInstallStep().dependOn(&wasm_install.step);
    } else {
        const exe = b.addExecutable(.{ .name = "revo", .root_module = exe_mod });
        const lib = b.addLibrary(.{ .name = "erevo", .root_module = erevo_mod.? });

        if (features.zig_backend) {
            lib.use_llvm = false;
            lib.use_lld = false;
        }

        if (optimize == .debug) exe.lto = .none;
        exe.rdynamic = true;
        if (features.zig_backend) exe.use_llvm = false;
        if (features.zig_backend) exe.use_lld = false;
        if (builtin.target.os.tag == .linux and with_glibc) {
            exe.use_llvm = true;
            exe.use_lld = true;
        }

        const exe_install = b.addInstallArtifact(exe, .{});
        const lib_install = b.addInstallArtifact(lib, .{});
        const header_install = b.addInstallDirectory(.{
            .source_dir = header_wf.getDirectory(),
            .install_subdir = "revo",
            .install_dir = .header,
        });
        b.getInstallStep().dependOn(&exe_install.step);
        lib_install.step.dependOn(&header_install.step);

        const lib_step = b.step("lib", "build the erevo library");
        lib_step.dependOn(&lib_install.step);

        //
        // run step
        //
        const run_step = b.step("run", "run the cli");
        {
            const run_exe = b.addRunArtifact(exe);
            run_exe.addPassthruArgs();
            run_step.dependOn(&run_exe.step);
        }

        //
        // check step
        //
        const check_step = b.step("check", "type-check without codegen or linking");
        check_step.dependOn(&vm_test.step);
        check_step.dependOn(&revo_test.step);
        check_step.dependOn(&exe_test.step);
        check_step.dependOn(&c_test.step);
        check_step.dependOn(&revolt_test.step);
        check_step.dependOn(&header_test.step);

        //
        // tests
        //
        const test_step = b.step("test", "run all tests");
        {
            const test_vm_step = b.step("test-vm", "test only the vm module");
            test_vm_step.dependOn(&b.addRunArtifact(vm_test).step);
            test_step.dependOn(test_vm_step);

            const test_revo_step = b.step("test-revo", "test only the revo module");
            test_revo_step.dependOn(&b.addRunArtifact(revo_test).step);
            test_step.dependOn(test_revo_step);

            const test_exe_step = b.step("test-exe", "test only the exe root");
            test_exe_step.dependOn(&b.addRunArtifact(exe_test).step);
            test_step.dependOn(test_exe_step);

            test_step.dependOn(&b.addRunArtifact(c_test).step);
            test_step.dependOn(&b.addRunArtifact(header_test).step);

            const test_lang_step = b.step("test-lang", "run the split lang suite");
            test_step.dependOn(test_lang_step);
            {
                // todo dont do this lol
                const areas = [_][]const u8{
                    "parse",       "tables",       "arithmetic",     "fibers",
                    "bindings",    "strings",      "closures_loops", "reports",
                    "imports",     "match",        "scope",          "functions",
                    "pipe_params", "modules",      "typed",          "match_types",
                    "generics",    "declare_repl",
                };
                for (areas) |area| {
                    const mod = b.createModule(.{
                        .root_source_file = b.path(b.fmt("src/lang/tests/{s}.zig", .{area})),
                        .target = target,
                        .optimize = effective_optimize,
                        .link_libc = !is_freestanding,
                    });
                    mod.addImport("revo", revo_mod);
                    if (test_ffi_lib) |ffi| mod.linkLibrary(ffi);
                    const t = b.addTest(.{ .root_module = mod, .filters = test_filters });
                    const run = b.addRunArtifact(t);
                    const area_step = b.step(
                        b.fmt("test-lang-{s}", .{area}),
                        b.fmt("run lang {s} tests", .{area}),
                    );
                    area_step.dependOn(&run.step);
                    test_lang_step.dependOn(&run.step);
                }
            }
        }

        //
        // c test suite
        //
        const test_c_step = b.step("test-c", "run c api tests");
        {
            // real .so the c suite imports for e2e cfn coverage (ok paths + HostResult err propagation)
            const test_ext_mod = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = !is_freestanding,
            });
            test_ext_mod.addCSourceFile(.{
                .file = b.path("examples/foreign/c/extension.c"),
                .flags = &.{
                    "-std=c99", "-Wall", "-Wextra", "-fPIC",
                },
            });
            test_ext_mod.addIncludePath(header_wf.getDirectory());
            const test_ext_lib = b.addLibrary(.{
                .name = "revo_test_ext",
                .root_module = test_ext_mod,
                .linkage = .dynamic,
            });
            test_ext_lib.linker_allow_shlib_undefined = true;

            // plain c fixture for ffi e2e (no revo types in signatures)
            const ffi_fixture_mod = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = !is_freestanding,
            });
            ffi_fixture_mod.addCSourceFile(.{
                .file = b.path("src/capi/fixture.c"),
                .flags = &.{
                    "-std=c99", "-Wall", "-Wextra", "-fPIC",
                },
            });
            const ffi_fixture_lib = b.addLibrary(.{
                .name = "revo_ffi_fixture",
                .root_module = ffi_fixture_mod,
                .linkage = .dynamic,
            });

            const c_test_exe = b.addExecutable(.{
                .name = "revo-c-test",
                .root_module = b.createModule(.{
                    .target = target,
                    .optimize = optimize,
                    .link_libc = !is_freestanding,
                }),
            });
            c_test_exe.rdynamic = true;
            c_test_exe.root_module.addCSourceFile(.{
                .file = b.path("src/capi/tests.c"),
                .flags = &.{
                    "-std=c99", "-Wall", "-Wextra",
                },
            });
            c_test_exe.root_module.addIncludePath(header_wf.getDirectory());
            c_test_exe.root_module.linkLibrary(lib);
            c_test_exe.root_module.linkSystemLibrary("m", .{ .needed = true });
            if (test_ffi_lib) |fl| c_test_exe.root_module.linkLibrary(fl);

            const c_test_run = b.addRunArtifact(c_test_exe);
            // argv[1]: test .so path, absent when built standalone
            c_test_run.addFileArg(test_ext_lib.getEmittedBin());
            // argv[2]: ffi fixture .so path, absent when built standalone
            c_test_run.addFileArg(ffi_fixture_lib.getEmittedBin());
            test_c_step.dependOn(&c_test_run.step);

            // c++ compat (must compile as c++ and link)
            const cpp_test_exe = b.addExecutable(.{
                .name = "revo-cpp-test",
                .root_module = b.createModule(.{
                    .target = target,
                    .optimize = optimize,
                    .link_libc = !is_freestanding,
                }),
            });
            cpp_test_exe.rdynamic = true;
            cpp_test_exe.root_module.addCSourceFile(.{
                .file = b.path("src/capi/test.cpp"),
                .flags = &.{
                    "-Wall", "-Wextra",
                },
            });
            cpp_test_exe.root_module.addIncludePath(header_wf.getDirectory());
            cpp_test_exe.root_module.linkLibrary(lib);
            cpp_test_exe.root_module.linkSystemLibrary("m", .{ .needed = true });
            if (test_ffi_lib) |fl| cpp_test_exe.root_module.linkLibrary(fl);
            test_c_step.dependOn(&b.addRunArtifact(cpp_test_exe).step);
        }
    }

    //
    // release step
    //
    const release_step = b.step("release", "build release binaries for all targets");
    {
        const install_options = Build.Step.InstallArtifact.Options{
            .dest_dir = .{ .override = .{ .custom = "release" } },
        };

        for (release_targets, release_target_queries) |target_def, query| {
            const target_str = target_def.triple;
            const release_target = b.resolveTargetQuery(query);
            const release_is_fs = release_target.result.os.tag == .freestanding;
            const release_is_wasm = release_target.result.cpu.arch.isWasm();
            const release_is_wasi = release_target.result.os.tag == .wasi;
            const release_is_wasi_cli = target_def.wasi_cli;
            const release_optimize: std.lang.Optimize = if (release_is_wasm) .small else .safe;

            const release_lsp_enabled = features.lsp and !release_is_fs;

            // isocline not available on windows, wasi, or freestanding
            const release_isocline_enabled = features.isocline and
                !release_is_fs and
                !release_is_wasi and
                release_target.result.os.tag != .windows;

            const release_ffi_enabled = features.ffi and
                !release_is_fs and
                !release_is_wasm and
                release_target.result.os.tag != .windows;

            const rel_options = b.addOptions();
            rel_options.addOption(bool, "is_freestanding", release_is_fs);
            rel_options.addOption(bool, "mimalloc", !release_is_fs and mimalloc_enabled);
            rel_options.addOption(bool, "ffi", release_ffi_enabled);
            rel_options.addOption(bool, "isocline", release_isocline_enabled);
            // TODO: regex compiles for freestanding, it isn't the issue here
            rel_options.addOption(
                bool,
                "regex",
                release_target.result.os.tag != .freestanding and features.regex,
            );
            rel_options.addOption([]const u8, "version", VERSION);
            rel_options.addOption([]const u8, "git_commit", dev_version);
            rel_options.addOption(bool, "lsp_enabled", release_lsp_enabled);
            rel_options.addOption(bool, "perf", perf);
            const rel_options_mod = rel_options.createModule();

            const rel_vm_mod = b.createModule(.{
                .root_source_file = b.path("src/vm/root.zig"),
                .target = release_target,
                .optimize = release_optimize,
                .link_libc = !release_is_fs,
            });
            const rel_revo_mod = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = release_target,
                .optimize = release_optimize,
                .link_libc = !release_is_fs,
            });
            const rel_c_mod = b.createModule(.{
                .root_source_file = b.path("src/capi/root.zig"),
                .target = release_target,
                .optimize = release_optimize,
                .link_libc = !release_is_fs,
            });

            const rel_mimalloc_mod = b.createModule(.{
                .root_source_file = b.path("src/mimalloc.zig"),
                .target = release_target,
                .optimize = release_optimize,
                .link_libc = !release_is_fs,
            });
            const rel_core_mods: []const *Module = &.{ rel_vm_mod, rel_revo_mod, rel_c_mod };
            for (rel_core_mods) |mod| {
                mod.addImport("revo", rel_revo_mod);
                mod.addImport("vm", rel_vm_mod);
                mod.addImport("capi", rel_c_mod);
                mod.addImport("build_options", rel_options_mod);
            }

            const rel_isocline_mod = builds.isocline(
                b,
                release_isocline_enabled,
                release_target,
                release_optimize,
                b.fmt("release_{s}", .{target_str}),
            );

            const rel_revolt_mod = b.createModule(.{
                .root_source_file = if (release_lsp_enabled)
                    b.path("src/lsp/server.zig")
                else
                    b.path("src/lsp/disabled.zig"),
                .target = release_target,
                .optimize = release_optimize,
                .link_libc = !release_is_fs,
                .imports = if (release_lsp_enabled) &[_]Module.Import{
                    .{ .name = "revo", .module = rel_revo_mod },
                    .{ .name = "vm", .module = rel_vm_mod },
                    .{ .name = "capi", .module = rel_c_mod },
                    .{ .name = "build_options", .module = rel_options_mod },
                    .{ .name = "lsp", .module = lsp_kit_dep.module("lsp") },
                } else &.{},
            });

            // wasi-cli uses cli.zig (wasi syscalls), web uses wasm_entry.zig (js imports)
            const release_main_file = if (release_is_wasi_cli)
                "src/cli.zig"
            else if (release_is_wasm)
                "src/wasm_entry.zig"
            else
                "src/cli.zig";

            const release_mod = b.createModule(.{
                .root_source_file = b.path(release_main_file),
                .target = release_target,
                .optimize = release_optimize,
                .link_libc = !release_is_fs,
                .imports = &[_]Module.Import{
                    .{ .name = "revo", .module = rel_revo_mod },
                    .{ .name = "vm", .module = rel_vm_mod },
                    .{ .name = "capi", .module = rel_c_mod },
                    .{ .name = "build_options", .module = rel_options_mod },
                    .{ .name = "isocline", .module = rel_isocline_mod },
                    .{ .name = "mimalloc", .module = rel_mimalloc_mod },
                    .{ .name = "lsp_main", .module = rel_revolt_mod },
                },
            });

            if (!release_is_fs and mimalloc_enabled) {
                const rel_mimalloc = try builds.mimalloc(b, release_target, release_optimize, mimalloc_dep.?);
                release_mod.linkLibrary(rel_mimalloc);
            }

            if (release_ffi_enabled) {
                const rel_c_ffi: Translator = builds.translate_c_header(
                    b,
                    b.dependency("translate_c", .{}),
                    "c_ffi",
                    "ffi.h",
                    release_target,
                    release_optimize,
                );
                if (b.dependencyLazy("libffi", .{
                    .target = release_target,
                    .optimize = release_optimize,
                }) catch null) |rel_ffi_dep| {
                    const rel_ffi_lib = rel_ffi_dep.artifact("ffi");
                    rel_c_ffi.linkLibrary(rel_ffi_lib);
                    release_mod.linkLibrary(rel_ffi_lib);
                }
                for (rel_core_mods) |mod| mod.addImport("c_ffi", rel_c_ffi.mod);
            }
            if (release_isocline_enabled) {
                const rel_c_signal: Translator = builds.translate_c_header(
                    b,
                    b.dependency("translate_c", .{}),
                    "c_signal",
                    "signal.h",
                    release_target,
                    release_optimize,
                );
                release_mod.addImport("c_signal", rel_c_signal.mod);
            }

            const release_exe = b.addExecutable(.{
                .name = if (release_is_wasi_cli)
                    binName(b, "wasm32-wasi-cli", .release)
                else
                    binName(b, target_str, .release),
                .root_module = release_mod,
            });
            if (release_is_fs) {
                release_exe.entry = .disabled;
                // same oversized dispatch frame as the dev wasm build
                release_exe.stack_size = 16 * 1024 * 1024;
            } else if (release_is_wasm) {
                // wasm builds need larger stack for dispatch frame
                release_exe.stack_size = 16 * 1024 * 1024;
            }
            release_exe.rdynamic = true;

            release_step.dependOn(&b.addInstallArtifact(release_exe, install_options).step);
        }
    }
    //
    // lint
    //
    const zlinter = @import("zlinter");
    const lint_cmd = b.step("lint", "lint with zlinter");
    lint_cmd.dependOn(step: {
        // ref:
        // https://github.com/KurtWagner/zlinter/blob/master/RULES.md
        var builder = zlinter.builder(b, .{});
        builder.addRule(.{ .builtin = .field_naming }, .{});
        builder.addRule(.{ .builtin = .declaration_naming }, .{});
        builder.addRule(.{ .builtin = .function_naming }, .{});
        builder.addRule(.{ .builtin = .file_naming }, .{});
        builder.addRule(.{ .builtin = .switch_case_ordering }, .{});
        builder.addRule(.{ .builtin = .no_deprecated }, .{});
        builder.addRule(.{ .builtin = .no_orelse_unreachable }, .{});
        // autofixable
        builder.addRule(.{ .builtin = .no_unused }, .{});
        // fucks with comments and layouts as of [git blame to check date] dont use
        // builder.addRule(.{ .builtin = .field_ordering }, .{});
        builder.addRule(.{ .builtin = .import_ordering }, .{});
        builder.setCompileUnits(&.{.@"test"});
        break :step builder.build();
    });
    //
    // chore
    //   : fmt, lint, test, markdown fmt
    //
    // an ofa you should run before a commit thats supposed to be 100% correct
    // you really dont have to do it all the time
    //
    // if this passes, your state is very likely correct
    //
    const chore_step = b.step("chore", "run zig fmt, check, lint, tests, c tests, lsp pytest, and rumdl fmt");
    {
        const chore_fmt = b.addFmt(.{ .paths = b.pathList(&.{"./src"}) });

        const chore_check = b.addSystemCommand(&.{ "zig", "build", "check" });
        chore_check.step.dependOn(&chore_fmt.step);

        // TODO: when you fix all `zig build lint` suggestions, do both regular lint and autofix
        const chore_lint = b.addSystemCommand(&.{ "zig", "build", "lint", "--", "--fix" });
        chore_lint.step.dependOn(&chore_check.step);

        const chore_test = b.addSystemCommand(&.{ "zig", "build", "test", "--error-style", "minimal" });
        chore_test.step.dependOn(&chore_lint.step);

        const chore_test_c = b.addSystemCommand(&.{ "zig", "build", "test-c", "--error-style", "minimal" });
        chore_test_c.step.dependOn(&chore_test.step);

        const chore_pytest = b.addSystemCommand(&.{ "python3", "-m", "pytest", "src/lsp/test.py", "-v" });
        chore_pytest.step.dependOn(&chore_test_c.step);

        const chore_rumdl = b.addSystemCommand(&.{ "rumdl", "fmt", "./src" });
        chore_rumdl.step.dependOn(&chore_pytest.step);

        chore_step.dependOn(&chore_rumdl.step);
    }
}
const builds = struct {
    fn translate_c_header(
        b: *Build,
        dep: *Build.Dependency,
        name: []const u8,
        header: []const u8,
        target: Build.ResolvedTarget,
        optimize: std.lang.Optimize,
    ) Translator {
        const stub = b.addWriteFiles().add(
            b.fmt("{s}_stub.h", .{name}),
            b.fmt("#include <{s}>\n", .{header}),
        );
        return .init(dep, .{
            .name = name,
            .c_source_file = stub,
            .target = target,
            .optimize = optimize,
        });
    }

    /// build translate-c mod when enabled else stub
    fn isocline(
        b: *Build,
        enabled: bool,
        target: Build.ResolvedTarget,
        optimize: std.lang.Optimize,
        tag: []const u8,
    ) *Module {
        if (enabled) {
            if (b.dependencyLazy("isocline", .{}) catch null) |isocline_dep| {
                const translate_c_dep = b.dependency("translate_c", .{});
                const translator: Translator = .init(translate_c_dep, .{
                    .c_source_file = isocline_dep.path("include/isocline.h"),
                    .target = target,
                    .optimize = optimize,
                });
                const mod = translator.mod;
                mod.addCSourceFile(.{
                    .file = isocline_dep.path("src/isocline.c"),
                    .flags = &.{},
                });
                return mod;
            }
        }

        return b.createModule(.{
            .root_source_file = b.addWriteFiles().add(b.fmt("no_isocline_{s}.zig", .{tag}), ""),
        });
    }

    /// static
    fn mimalloc(
        b: *Build,
        target: Build.ResolvedTarget,
        optimize: std.lang.Optimize,
        dep: *Build.Dependency,
    ) !*std.Build.Step.Compile {
        const lib = b.addLibrary(
            .{
                .name = "mimalloc",
                .linkage = .static,
                .use_llvm = true,
                .root_module = b.createModule(
                    .{
                        .target = target,
                        .optimize = optimize,
                        .link_libc = true,
                        .pic = true,
                    },
                ),
            },
        );

        lib.root_module.addIncludePath(dep.path("include"));

        lib.root_module.addCSourceFiles(
            .{
                .root = dep.path("src"),
                .files = &.{
                    "alloc.c",
                    "alloc-aligned.c",
                    "alloc-posix.c",
                    "arena.c",
                    "bitmap.c",
                    "heap.c",
                    "init.c",
                    "libc.c",
                    "options.c",
                    "os.c",
                    "page.c",
                    "random.c",
                    "segment.c",
                    "segment-map.c",
                    "stats.c",
                    "prim/prim.c",
                },
                .flags = if (lib.root_module.optimize != .debug)
                    &.{
                        "-DNDEBUG=1",
                        "-DMI_SECURE=0",
                        "-DMI_STAT=0",
                        "-DMI_SHOW_ERRORS=1",
                        "-DMI_SKIP_COLLECT_ON_EXIT=1",
                        "-fno-sanitize=undefined",
                        "-Wno-date-time",
                    }
                else
                    &.{
                        "-DMI_SKIP_COLLECT_ON_EXIT=1",
                        "-fno-sanitize=undefined",
                        "-Wno-date-time",
                    },
            },
        );

        return lib;
    }
};
