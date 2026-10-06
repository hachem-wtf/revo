const std = @import("std");
const alloc = std.testing.allocator;

const revo = @import("revo");
const lang = revo.lang;
const VM = revo.VM;

const t = revo.lang.test_helpers;


test "lang surface exports parse and build pipeline entrypoints" {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const parsed = try lang.parse(arena.allocator(), .{ .text = "sys.print \"hello\"" }, .{});
    try std.testing.expect(parsed == .ok);
    try std.testing.expect(parsed.ok.root.expr == .call);

    var vm = try VM.init(t.runtime());
    defer vm.deinit();
    const built = try lang.build(&vm, .{ .text = "1 + 1" }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);
    try std.testing.expect(built.ok.instructions.len != 0);
}

test "parser treats semicolons as whitespace characters" {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const source =
        \\ const langs = {
        \\   "C", "C++",
        \\   "Java", "C#",
        \\   "Perl", "PHP",
        \\ };
        \\ fn fellow_heart_attacker(lang) do
        \\   "An old {lang} programmer won't have a heart attack " ~
        \\   "over a habitually placed closing semicolon.";
        \\ end
        \\ for lang in langs do
        \\   const statement = fellow_heart_attacker(lang);
        \\   print(statement);
        \\ end
    ;
    const parsed = try lang.parse(arena.allocator(), .{ .text = source }, .{});
    try std.testing.expect(parsed == .ok);
}

test "parser reports multiple syntax errors in one pass" {
    var vm = try VM.init(t.runtime());
    defer vm.deinit();

    const source =
        \\ let x = )
        \\ let y = )
    ;
    const built = try lang.build(&vm, .{ .text = source }, .{});
    try std.testing.expect(built == .err);
    switch (built.err) {
        .parse => |failure| {
            var error_count: usize = 0;
            for (failure.report.parts) |part| {
                if (part == .@"error") error_count += 1;
            }
            try std.testing.expect(error_count >= 2);

            var buf = std.Io.Writer.Allocating.init(alloc);
            defer buf.deinit();
            try lang.renderError(alloc, &buf.writer, .{ .text = source }, .{ .parse = failure }, .{});
            try std.testing.expect(buf.written().len != 0);
        },
        else => return error.ExpectedCompileFailure,
    }
}

