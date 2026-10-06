//! shared bits of both macro expanders, no behavior of its own
//!   template `macro!` and VM-run `proc!` both dispatch on `mod.name!`
//!   calls the same way and rebuild untouched calls the same way
//!   envs stay separate: ProcEnv carries a recursion guard plus error
//!   attribution with no pattern analogue, unifying em would drop it

const std = @import("std");

const ast = @import("ast.zig");
const Node = ast.Node;
const Span = ast.Span;

/// owned `mod.name!` for `.field` callees with ident object + bang name
///   null otherwise, caller frees the hit
pub fn qualifiedMacroName(alloc: std.mem.Allocator, callee: *const Node) !?[]u8 {
    if (callee.expr != .field) return null;

    const f = callee.expr.field;
    if (f.object.expr != .ident) return null;
    if (!std.mem.endsWith(u8, f.name, "!")) return null;

    return try alloc.print("{s}.{s}", .{ f.object.expr.ident, f.name });
}

/// rebuild an unexpanded call after callee + args already expanded
pub fn rebuildCall(alloc: std.mem.Allocator, span: Span, callee: *Node, args: []*Node, implicit_self: bool) !*Node {
    return ast.allocNode(alloc, span, .{ .call = .{
        .callee = callee,
        .args = args,
        .implicit_self = implicit_self,
    } });
}

/// leaf tags both codec sides must spell the same way, drift breaks the mirror
pub const number_tag = "number";
pub const float_marker = "float";
pub const true_atom = "true";
pub const false_atom = "false";
