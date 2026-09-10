const std = @import("std");
const lsp = @import("lsp");
const revo = @import("revo");

const T = lsp.types;
const Workspace = revo.lang.Workspace;

/// complete identifiers at cursor position in `text`
pub fn completions(
    vm: *revo.VM,
    workspace: *Workspace.Workspace,
    arena: std.mem.Allocator,
    file_id: Workspace.FileId,
    text: []const u8,
    cursor_off: usize,
) !T.completion.Result {
    _ = vm;
    const items = try workspace.completions(arena, file_id, text, cursor_off);

    var result = std.ArrayList(T.completion.Item).initCapacity(arena, items.len) catch {
        return T.completion.Result{ .completion_items = &.{} };
    };

    for (items) |item| {
        result.append(arena, .{
            .label = item.label,
            .kind = switch (item.kind) {
                .keyword => .Keyword,
                .function => .Function,
                .module => .Module,
                .variable => .Variable,
                .field => .Field,
                .class => .Class,
            },
            .detail = item.detail,
            .insertText = item.insert_text,
            .insertTextFormat = if (item.insert_text != null) .Snippet else null,
            .documentation = if (item.documentation) |d|
                .{ .markup_content = .{ .kind = .markdown, .value = d } }
            else
                null,
        }) catch return T.completion.Result{ .completion_items = &.{} };
    }

    return T.completion.Result{ .completion_items = result.items };
}
