//! shared memory + report helpers for ws providers
//!
//! copy/free routines every provider needs so none of them
//! duplicate ownership logic

const std = @import("std");

const revo = @import("revo");

const ast = @import("../ast.zig");
const diagnostic = @import("../diagnostic.zig");
const pipeline = @import("../pipeline.zig");
const type_syntax = @import("../type_syntax.zig");
const types = @import("../compiler/types.zig");

const W = @import("../Workspace.zig");
const Workspace = W.Workspace;
const Symbol = W.Symbol;
const FnSig = W.FnSig;

pub fn sameOpts(a: pipeline.BuildOptions, b: pipeline.BuildOptions) bool {
    return std.meta.eql(a, b);
}

pub fn copyBytecode(alloc: std.mem.Allocator, bytecode: pipeline.Bytecode) !pipeline.Bytecode {
    return .{
        .instructions = try alloc.dupe(revo.Instruction, bytecode.instructions),
        .spans = try alloc.dupe(ast.Span, bytecode.spans),
    };
}

pub fn deinitBytecode(alloc: std.mem.Allocator, bytecode: pipeline.Bytecode) void {
    alloc.free(bytecode.instructions);
    alloc.free(bytecode.spans);
}

/// merge two error reports into one (dedup span parts by range+message)
///
/// parts get copied, callers can free both inputs right after
pub fn mergeReports(alloc: std.mem.Allocator, a: pipeline.Error, b: pipeline.Error) !diagnostic.Report {
    const a_report = pipeline.errorReport(a);
    const b_report = pipeline.errorReport(b);
    const total = a_report.parts.len + b_report.parts.len;
    var all_parts = try std.ArrayList(diagnostic.Part).initCapacity(alloc, total);

    errdefer for (all_parts.items) |part| part.deinit(alloc);
    for (a_report.parts) |p| try all_parts.append(alloc, try p.copy(alloc));
    for (b_report.parts) |p| {
        var dup = false;
        if (p == .span) {
            for (a_report.parts) |ap| {
                if (ap == .span and
                    ap.span.span.start == p.span.span.start and
                    ap.span.span.end == p.span.span.end and
                    std.mem.eql(u8, ap.span.message, p.span.message))
                {
                    dup = true;
                    break;
                }
            }
        }
        if (p == .@"error") {
            for (a_report.parts) |ap| {
                if (ap == .@"error" and std.mem.eql(u8, ap.@"error", p.@"error")) {
                    dup = true;
                    break;
                }
            }
        }
        if (!dup) try all_parts.append(alloc, try p.copy(alloc));
    }
    const message = if (a_report.message.len > 0)
        try alloc.dupe(u8, a_report.message)
    else if (b_report.message.len > 0)
        try alloc.dupe(u8, b_report.message)
    else
        "";
    return .{
        .parts = try all_parts.toOwnedSlice(alloc),
        .message = message,
        .code = a_report.code orelse b_report.code,
        .source_name = try alloc.dupe(u8, a_report.source_name orelse b_report.source_name orelse ""),
        .source = try alloc.dupe(u8, a_report.source orelse b_report.source orelse ""),
    };
}

pub fn copyError(
    alloc: std.mem.Allocator,
    err: pipeline.Error,
    source_name: []const u8,
    source: []const u8,
) !pipeline.Error {
    var report = try pipeline.errorReport(err).copy(alloc);
    errdefer report.deinit(alloc);
    report.source_name = try alloc.dupe(u8, source_name);
    report.source = try alloc.dupe(u8, source);
    return switch (err) {
        .parse => |failure| .{ .parse = .{ .kind = failure.kind, .report = report } },
        .expand => .{ .expand = .{ .report = report } },
        .compile => |failure| .{ .compile = .{ .kind = failure.kind, .report = report } },
        .semantic => |failure| .{ .semantic = .{ .kind = failure.kind, .report = report } },
    };
}

pub fn copySymbols(alloc: std.mem.Allocator, symbols: []const Symbol) ![]Symbol {
    return copyFilteredSymbols(alloc, symbols, false);
}

/// one filtered copy for outlines + module members
///   params resolve for hover/definition but stay out of those lists
///   single home for `documentSymbols` + `symbolsFromDep`
pub fn copyFilteredSymbols(
    alloc: std.mem.Allocator,
    symbols: []const Symbol,
    comptime exclude_param: bool,
) ![]Symbol {
    var out = try std.ArrayList(Symbol).initCapacity(alloc, symbols.len);
    errdefer {
        for (out.items) |*s| {
            alloc.free(s.name);
            if (s.type_name) |*ti| types.deinitType(ti, alloc);
            if (s.field_values) |fvs| {
                for (fvs) |fv| {
                    alloc.free(fv.name);
                    alloc.free(fv.preview);
                }
                alloc.free(fvs);
            }
        }
        out.deinit(alloc);
    }

    for (symbols) |s| {
        if (exclude_param and s.kind == .param) continue;
        try out.append(alloc, .{
            .name = try alloc.dupe(u8, s.name),
            .kind = s.kind,
            .range = s.range,
            .type_name = if (s.type_name) |ti| try types.clone(ti, alloc) else null,
            .field_values = if (s.field_values) |fvs| try cloneFieldPreviews(alloc, fvs) else null,
        });
    }

    return out.toOwnedSlice(alloc);
}

pub fn cloneFieldPreviews(alloc: std.mem.Allocator, fvs: []const type_syntax.FieldPreview) ![]type_syntax.FieldPreview {
    const owned = try alloc.alloc(type_syntax.FieldPreview, fvs.len);
    for (fvs, owned) |fv, *dst| dst.* = .{
        .name = try alloc.dupe(u8, fv.name),
        .preview = try alloc.dupe(u8, fv.preview),
    };
    return owned;
}

pub fn freeSymbols(alloc: std.mem.Allocator, symbols: []Symbol) void {
    for (symbols) |*sym| {
        alloc.free(sym.name);
        if (sym.type_name) |*ti| types.deinitType(ti, alloc);
        if (sym.field_values) |fvs| {
            for (fvs) |fv| {
                alloc.free(fv.name);
                alloc.free(fv.preview);
            }
            alloc.free(fvs);
        }
    }
    alloc.free(symbols);
}

pub fn freeSigMap(alloc: std.mem.Allocator, map: *const std.StringHashMapUnmanaged(FnSig)) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        alloc.free(entry.key_ptr.*);
        for (entry.value_ptr.params) |*p| {
            if (p.name.len > 0) alloc.free(p.name);
            if (p.type_name) |*ti| types.deinitType(ti, alloc);
        }
        alloc.free(entry.value_ptr.params);
        if (entry.value_ptr.return_type) |*rt| types.deinitType(rt, alloc);
        if (entry.value_ptr.type_params_text) |t| alloc.free(t);
    }
    const mut = @constCast(map);
    mut.deinit(alloc);
}

/// `<T, U>` or null when empty
/// caller owns the result
pub fn formatTypeParams(alloc: std.mem.Allocator, type_params: []const []const u8) !?[]const u8 {
    if (type_params.len == 0) return null;
    var buf = std.Io.Writer.Allocating.init(alloc);
    errdefer buf.deinit();
    try buf.writer.writeByte('<');

    for (type_params, 0..) |tp, i| {
        if (i > 0) try buf.writer.writeAll(", ");
        try buf.writer.writeAll(tp);
    }

    try buf.writer.writeByte('>');
    const owned: []const u8 = try buf.toOwnedSlice();
    return owned;
}

/// one `fn name(params) -> ret`, caller owns it
///   byte-identical to old `hover.renderDefinition` branch
pub fn formatSig(alloc: std.mem.Allocator, name: []const u8, sig: FnSig) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(alloc);
    errdefer buf.deinit();

    try buf.writer.print("fn {s}", .{name});
    if (sig.type_params_text) |tps| try buf.writer.writeAll(tps);
    try buf.writer.writeByte('(');

    for (sig.params, 0..) |p, i| {
        if (i > 0) try buf.writer.print(", ", .{});
        try buf.writer.writeAll(p.name);
        if (p.optional) try buf.writer.writeByte('?');
        if (p.type_name) |ti| {
            const pt = try type_syntax.formatTypeOpts(alloc, ti, .{});
            defer alloc.free(pt);
            try buf.writer.print(": {s}", .{pt});
        }
    }

    try buf.writer.writeByte(')');
    if (sig.return_type) |rt| {
        const rt_str = try type_syntax.formatTypeOpts(alloc, rt, .{});
        defer alloc.free(rt_str);
        try buf.writer.print(" -> {s}", .{rt_str});
    }

    return buf.toOwnedSlice();
}

/// one baselib lookup so providers share a call site
///   replaces four `specs.findFn` spellings
pub fn baselibSig(name: []const u8) ?*const revo.baselib.specs.FnSpec {
    return revo.baselib.specs.findFn(name);
}

/// get known global names from the vm
pub fn getKnownGlobals(ws: *Workspace, alloc: std.mem.Allocator) ![]const []const u8 {
    const vm = ws.vm orelse return &.{};

    return pipeline.knownGlobalsFromVm(vm, alloc);
}

test "mergeReports owns part text after both inputs are freed" {
    const alloc = std.testing.allocator;

    const a: pipeline.Error = .{ .parse = .{ .kind = .UnexpectedToken, .report = .{
        .message = try alloc.dupe(u8, "unexpected token"),
        .code = "unexpected-token",
        .source_name = try alloc.dupe(u8, "a.rv"),
        .source = try alloc.dupe(u8, "print(1 2)\n"),
        .parts = try alloc.dupe(diagnostic.Part, &.{
            .{ .@"error" = try alloc.dupe(u8, "unexpected token") },
            .{ .span = .{
                .span = .{ .start = 8, .end = 9, .line = 1, .column = 9 },
                .role = .primary,
                .message = try alloc.dupe(u8, "here"),
            } },
        }),
    } } };

    const b: pipeline.Error = .{ .semantic = .{ .kind = .SemanticError, .report = .{
        .message = try alloc.dupe(u8, "name `foo` is not defined"),
        .source_name = try alloc.dupe(u8, "a.rv"),
        .source = try alloc.dupe(u8, "print(1 2)\n"),
        .parts = try alloc.dupe(diagnostic.Part, &.{
            .{ .@"error" = try alloc.dupe(u8, "name `foo` is not defined") },
        }),
    } } };

    var merged = try mergeReports(alloc, a, b);
    defer merged.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), merged.parts.len);

    // :: aliasing
    //   merged text is never the input text, freeing the inputs
    //   then poisons those bytes under a debug allocator
    try std.testing.expect(a.parse.report.parts[0].@"error".ptr != merged.parts[0].@"error".ptr);
    try std.testing.expect(a.parse.report.parts[1].span.message.ptr != merged.parts[1].span.message.ptr);
    try std.testing.expect(b.semantic.report.parts[0].@"error".ptr != merged.parts[2].@"error".ptr);

    pipeline.deinitError(alloc, a);
    pipeline.deinitError(alloc, b);

    try std.testing.expectEqualStrings("unexpected token", merged.parts[0].@"error");
    try std.testing.expectEqualStrings("here", merged.parts[1].span.message);
    try std.testing.expectEqualStrings("name `foo` is not defined", merged.parts[2].@"error");
    try std.testing.expectEqualStrings("a.rv", merged.source_name.?);
}
