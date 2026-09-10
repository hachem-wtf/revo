const std = @import("std");
const builtin = @import("builtin");

const lsp = @import("lsp");
const T = lsp.types;
const revo = @import("revo");
const lang = revo.lang;
const Workspace = lang.Workspace;

const completion = @import("completion.zig");

pub fn main(init: std.process.Init) !void {
    try runLsp(init.gpa, init.io, .script, "");
}

pub fn runLsp(gpa: std.mem.Allocator, io: std.Io, mode: revo.lang.RunMode, project_root: []const u8) !void {
    var read_buf: [1024]u8 = undefined;
    var stdio = lsp.Transport.Stdio.init(&read_buf, .stdin(), .stdout());

    var handler = try Handler.init(gpa, &stdio.transport, io, mode, project_root);
    handler.ws.attachVm(&handler.vm);
    defer handler.deinit();

    try lsp.basic_server.run(io, gpa, &stdio.transport, &handler, std.log.err);
}

//
// handler
//

/// per-session state,,, workspace, vm, uri<->fileid
const Handler = struct {
    alloc: std.mem.Allocator,
    transport: *lsp.Transport,
    io: std.Io,
    // ws holds a reference to vm
    ws: Workspace.Workspace,
    vm: revo.VM,
    enc: lsp.offsets.Encoding = .@"utf-16", // client preference
    uri_to_file: std.StringHashMapUnmanaged(Workspace.FileId) = .empty, // uri -> ws id
    file_to_uri: std.AutoHashMapUnmanaged(Workspace.FileId, []const u8) = .empty, // ws id -> uri
    deinited: bool = false,
    project: lang.Project = .{ .mode = .script, .root = "" },

    fn init(
        alloc: std.mem.Allocator,
        transport: *lsp.Transport,
        io: std.Io,
        mode: revo.lang.RunMode,
        project_root: []const u8,
    ) !Handler {
        var vm = try revo.VM.init(.{ .alloc = alloc, .io = io, .diag_alloc = alloc });
        errdefer vm.deinit();
        var workspace = try Workspace.Workspace.init(alloc);
        errdefer workspace.deinit();
        return .{
            .alloc = alloc,
            .transport = transport,
            .io = io,
            .ws = workspace,
            .vm = vm,
            .project = .{ .mode = mode, .root = project_root },
        };
    }

    /// free in orderof owned uri strings, then workspace, then vm
    fn deinit(h: *Handler) void {
        h.cleanup();
    }

    fn cleanup(h: *Handler) void {
        if (h.deinited) return;
        h.deinited = true;
        // free uri strings from uri_to_file keys (file_to_uri values alias them)
        {
            var it = h.uri_to_file.iterator();
            while (it.next()) |entry| h.alloc.free(entry.key_ptr.*);
        }
        h.uri_to_file.deinit(h.alloc);
        h.file_to_uri.deinit(h.alloc);
        h.ws.deinit();
        h.vm.deinit();
    }

    /// track document uri<->fileid pair (dupes uri)
    fn registerDoc(h: *Handler, uri: []const u8, file_id: Workspace.FileId) !void {
        const u = try h.alloc.dupe(u8, uri);
        errdefer h.alloc.free(u);
        try h.uri_to_file.put(h.alloc, u, file_id);
        errdefer _ = h.uri_to_file.remove(u);
        try h.file_to_uri.put(h.alloc, file_id, u);
    }

    /// remove uri from both maps and free key string
    fn unregisterDoc(h: *Handler, uri: []const u8) void {
        const kv = h.uri_to_file.fetchRemove(uri) orelse return;
        h.alloc.free(kv.key);
        _ = h.file_to_uri.remove(kv.value);
    }

    /// advertise supported features and pick position encoding from client prefs
    pub fn initialize(h: *Handler, _: std.mem.Allocator, params: T.InitializeParams) T.InitializeResult {
        // clients first known pos encoding
        if (params.capabilities.general) |general| {
            for (general.positionEncodings orelse &.{}) |pe| {
                h.enc = switch (pe) {
                    .@"utf-8" => .@"utf-8",
                    .@"utf-16" => .@"utf-16",
                    .@"utf-32" => .@"utf-32",
                    .custom_value => continue,
                };
                break;
            }
        }
        const caps = T.ServerCapabilities{
            .positionEncoding = switch (h.enc) {
                .@"utf-8" => .@"utf-8",
                .@"utf-16" => .@"utf-16",
                .@"utf-32" => .@"utf-32",
            },
            .textDocumentSync = .{
                .text_document_sync_options = .{
                    .openClose = true,
                    .change = .Full,
                },
            },
            .definitionProvider = .{ .bool = true },
            .hoverProvider = .{ .bool = true },
            .referencesProvider = .{ .bool = true },
            .documentSymbolProvider = .{ .bool = true },
            .workspaceSymbolProvider = .{ .bool = true },
            .completionProvider = .{ .triggerCharacters = &.{"."} },
            .renameProvider = .{ .rename_options = .{ .prepareProvider = true } },
            .inlayHintProvider = .{ .inlay_hint_options = .{} },
            .signatureHelpProvider = T.SignatureHelp.Options{
                .triggerCharacters = &.{},
            },
            .semanticTokensProvider = .{ .semantic_tokens_options = .{
                .legend = .{
                    .tokenTypes = &.{
                        "keyword",
                        "string",
                        "number",
                        "function",
                        "variable",
                        "operator",
                        "enumMember",
                        "comment",
                        "moduleDoc",
                    },
                    .tokenModifiers = &.{},
                },
                .range = .{ .bool = false },
                .full = .{ .bool = true },
            } },
        };
        // sanity check in debug builds
        if (builtin.mode == .Debug) {
            lsp.basic_server.validateServerCapabilities(Handler, caps);
        }
        return .{
            .serverInfo = .{ .name = "revolt", .version = @import("build_options").version },
            .capabilities = caps,
        };
    }

    /// TODO: client notification
    pub fn initialized(_: *Handler, _: std.mem.Allocator, _: T.InitializedParams) void {}

    pub fn shutdown(_: *Handler, _: std.mem.Allocator, _: void) ?void {
        return null;
    }

    /// no reply needed
    /// leaking is actually fine here, but this just prevents a ton of noise
    pub fn exit(h: *Handler, _: std.mem.Allocator, _: void) void {
        h.cleanup();
    }

    /// open a file in the workspace and publish initial diags
    pub fn @"textDocument/didOpen"(h: *Handler, arena: std.mem.Allocator, params: T.TextDocument.DidOpenParams) !void {
        // strip file:// pref for ws api
        const path = if (std.mem.startsWith(u8, params.textDocument.uri, "file://"))
            params.textDocument.uri["file://".len..]
        else
            params.textDocument.uri;
        const id = try h.project.open(&h.ws, path, params.textDocument.text);
        try h.registerDoc(params.textDocument.uri, id);
        try h.publishDiagnostics(arena, params.textDocument.uri, id);
    }

    /// full-document sync; reparse n push updated diagnostics
    pub fn @"textDocument/didChange"(
        h: *Handler,
        arena: std.mem.Allocator,
        params: T.TextDocument.DidChangeParams,
    ) !void {
        const file_id = h.uri_to_file.get(params.textDocument.uri) orelse return;
        // full sync; only the last change matters
        if (params.contentChanges.len == 0) return;
        const last = params.contentChanges.len - 1;
        const text = switch (params.contentChanges[last]) {
            .text_document_content_change_whole_document => |c| c.text,
            .text_document_content_change_partial => |c| c.text,
        };
        try h.ws.change(file_id, text);
        try h.publishDiagnostics(arena, params.textDocument.uri, file_id);
    }

    /// close the file in ws and drop uri mappings
    pub fn @"textDocument/didClose"(
        h: *Handler,
        arena: std.mem.Allocator,
        params: T.TextDocument.DidCloseParams,
    ) !void {
        if (h.uri_to_file.get(params.textDocument.uri)) |file_id| {
            h.ws.close(file_id);
        }
        h.unregisterDoc(params.textDocument.uri);
        try h.transport.writeNotification(
            h.io,
            arena,
            "textDocument/publishDiagnostics",
            T.publish_diagnostics.Params,
            .{
                .uri = params.textDocument.uri,
                .diagnostics = &.{},
            },
            .{},
        );
    }

    /// go-to-definition; position is 1-based inside workspace, 0-based otw
    pub fn @"textDocument/definition"(
        h: *Handler,
        arena: std.mem.Allocator,
        params: T.Definition.Params,
    ) !?T.Definition.Result {
        const file_id = h.uri_to_file.get(params.textDocument.uri) orelse return null;
        const snap = h.ws.snapshot(file_id) orelse return null;
        const ws_pos = clientToWs(snap.text, params.position, h.enc);
        const loc = try h.ws.definition(arena, file_id, ws_pos, .{}) orelse return null;
        const uri = h.file_to_uri.get(loc.file_id) orelse return null;
        const loc_text = (h.ws.snapshot(loc.file_id) orelse snap).text;
        return T.Definition.Result{ .definition = .{ .location = .{
            .uri = uri,
            .range = .{ .start = wsToClient(loc_text, loc.range.start, h.enc), .end = wsToClient(loc_text, loc.range.end, h.enc) },
        } } };
    }

    /// hover info at position
    pub fn @"textDocument/hover"(h: *Handler, arena: std.mem.Allocator, params: T.Hover.Params) !?T.Hover {
        const file_id = h.uri_to_file.get(params.textDocument.uri) orelse return null;
        const snap = h.ws.snapshot(file_id) orelse return null;
        const ws_pos = clientToWs(snap.text, params.position, h.enc);
        const hov = try h.ws.hover(arena, file_id, ws_pos, .{}) orelse return null;
        return T.Hover{
            .contents = .{ .markup_content = .{ .kind = .markdown, .value = hov.text } },
            .range = .{ .start = wsToClient(snap.text, hov.range.start, h.enc), .end = wsToClient(snap.text, hov.range.end, h.enc) },
        };
    }

    /// signature help at cursor position
    pub fn @"textDocument/signatureHelp"(
        h: *Handler,
        arena: std.mem.Allocator,
        params: T.SignatureHelp.Params,
    ) !?T.SignatureHelp {
        const file_id = h.uri_to_file.get(params.textDocument.uri) orelse return null;
        const snap = h.ws.snapshot(file_id) orelse return null;
        const ws_pos = clientToWs(snap.text, params.position, h.enc);
        const sig = try h.ws.signatureHelp(arena, file_id, ws_pos, .{}) orelse return null;
        // sig is arena-allocated; arena cleans up after handler returns

        // build the label like `fn_name[T](param1: t1, param2?: t2): ret`
        var label = try std.ArrayList(u8).initCapacity(arena, 64);
        try label.appendSlice(arena, sig.name);
        if (sig.type_params_text) |tps| try label.appendSlice(arena, tps);
        try label.append(arena, '(');
        for (sig.params, 0..) |p, i| {
            if (i > 0) try label.appendSlice(arena, ", ");
            try label.appendSlice(arena, p.name);
            if (p.optional) try label.append(arena, '?');
            if (p.type_name) |ti| {
                const pt = try lang.type_serde.formatType(arena, ti);
                try label.appendSlice(arena, ": ");
                try label.appendSlice(arena, pt);
            }
        }
        try label.append(arena, ')');
        if (sig.return_type) |rt| {
            const rt_str = try lang.type_serde.formatType(arena, rt);
            try label.appendSlice(arena, ": ");
            try label.appendSlice(arena, rt_str);
        }
        const label_str = try label.toOwnedSlice(arena);

        // param offsets into label
        var params_list = try std.ArrayList(T.SignatureHelp.Signature.Parameter).initCapacity(arena, sig.params.len);
        var pos: u32 = @as(u32, @intCast(sig.name.len)) + 1; // after `(`
        if (sig.type_params_text) |tps| pos += @as(u32, @intCast(tps.len));
        for (sig.params) |p| {
            const start = pos;
            // skip past `name`, `?`, and `: type`
            pos += @as(u32, @intCast(p.name.len));
            if (p.optional) pos += 1;
            if (p.type_name) |ti| {
                const pt = try lang.type_serde.formatType(arena, ti);
                pos += 2 + @as(u32, @intCast(pt.len));
            }
            params_list.appendAssumeCapacity(.{
                .label = .{ .tuple_1 = .{ start, pos } },
                .documentation = null,
            });
            pos += 2; // skip ", "
        }

        // documentation as plain string (dupe before sig.deinit)
        const doc_text = if (sig.doc) |d| try arena.dupe(u8, d) else null;
        const doc = if (doc_text) |d| T.Documentation{ .string = d } else null;

        // allocate signatures array on arena (not stack)
        const signatures = try arena.alloc(T.SignatureHelp.Signature, 1);
        signatures[0] = .{
            .label = label_str,
            .documentation = doc,
            .parameters = try params_list.toOwnedSlice(arena),
            .activeParameter = sig.active_param,
        };

        return T.SignatureHelp{
            .signatures = signatures,
            .activeSignature = 0,
            .activeParameter = sig.active_param,
        };
    }

    /// get all refs to the symbol at position
    pub fn @"textDocument/references"(
        h: *Handler,
        arena: std.mem.Allocator,
        params: T.reference.Params,
    ) !?[]const T.Location {
        const file_id = h.uri_to_file.get(params.textDocument.uri) orelse return null;
        const snap = h.ws.snapshot(file_id) orelse return null;
        const ws_pos = clientToWs(snap.text, params.position, h.enc);
        const refs = try h.ws.references(arena, file_id, ws_pos, .{});
        defer arena.free(refs);

        // map workspace file ids back to uris
        var out = try std.ArrayList(T.Location).initCapacity(arena, refs.len);
        for (refs) |ref| {
            const uri = h.file_to_uri.get(ref.file_id) orelse continue;
            const ref_text = (h.ws.snapshot(ref.file_id) orelse snap).text;
            out.appendAssumeCapacity(.{
                .uri = uri,
                .range = .{ .start = wsToClient(ref_text, ref.range.start, h.enc), .end = wsToClient(ref_text, ref.range.end, h.enc) },
            });
        }
        const result = try out.toOwnedSlice(arena);
        return @as(?[]const T.Location, result);
    }

    /// list all symbols in a document
    pub fn @"textDocument/documentSymbol"(
        h: *Handler,
        arena: std.mem.Allocator,
        params: T.DocumentSymbol.Params,
    ) !?T.DocumentSymbol.Result {
        const file_id = h.uri_to_file.get(params.textDocument.uri) orelse return null;
        const snap = h.ws.snapshot(file_id) orelse return null;
        const syms = try h.ws.documentSymbols(arena, file_id, .{});
        defer arena.free(syms);
        var list = try std.ArrayList(T.SymbolInformation).initCapacity(arena, syms.len);
        for (syms) |sym| {
            list.appendAssumeCapacity(.{
                .name = sym.name,
                .kind = switch (sym.kind) {
                    .binding => .Variable,
                    .function, .macro => .Function,
                    .param => .Variable,
                    .struct_type => .Struct,
                    .type_alias => .Class,
                },
                .location = .{
                    .uri = params.textDocument.uri,
                    .range = .{ .start = wsToClient(snap.text, sym.range.start, h.enc), .end = wsToClient(snap.text, sym.range.end, h.enc) },
                },
            });
        }
        return T.DocumentSymbol.Result{ .symbol_informations = try list.toOwnedSlice(arena) };
    }

    /// complete identifiers at cursor position
    pub fn @"textDocument/completion"(
        h: *Handler,
        arena: std.mem.Allocator,
        params: T.completion.Params,
    ) !?T.completion.Result {
        const file_id = h.uri_to_file.get(params.textDocument.uri) orelse return null;
        const snap = h.ws.snapshot(file_id) orelse return null;
        const ws_pos = clientToWs(snap.text, params.position, h.enc);
        const cursor_off = positionToOffset(snap.text, ws_pos) orelse return null;
        return @as(
            ?T.completion.Result,
            try completion.completions(&h.vm, &h.ws, arena, file_id, snap.text, cursor_off),
        );
    }

    /// search workspace-wide by query str
    pub fn @"workspace/symbol"(
        h: *Handler,
        arena: std.mem.Allocator,
        params: T.workspace.Symbol.Params,
    ) !?T.workspace.Symbol.Result {
        const syms = try h.ws.findSymbols(arena, params.query);
        defer arena.free(syms);
        var list = try std.ArrayList(T.SymbolInformation).initCapacity(arena, syms.len);
        for (syms) |sym| {
            const uri = h.file_to_uri.get(sym.file_id) orelse continue;
            const sym_text = (h.ws.snapshot(sym.file_id) orelse continue).text;
            list.appendAssumeCapacity(.{
                .name = sym.name,
                .kind = .Variable,
                .location = .{
                    .uri = uri,
                    .range = .{ .start = wsToClient(sym_text, sym.range.start, h.enc), .end = wsToClient(sym_text, sym.range.end, h.enc) },
                },
            });
        }
        return T.workspace.Symbol.Result{ .symbol_informations = try list.toOwnedSlice(arena) };
    }

    /// log unexpected client responses
    pub fn onResponse(_: *Handler, _: std.mem.Allocator, response: lsp.JsonRPCMessage.Response) void {
        std.log.warn("unexpected client response id={?}", .{response.id});
    }

    /// push textDocument/publishDiagnostics notification for a file
    fn publishDiagnostics(
        h: *Handler,
        arena: std.mem.Allocator,
        uri: []const u8,
        file_id: Workspace.FileId,
    ) !void {
        const diag = try h.ws.diagnostics(arena, file_id, .{});
        if (diag) |err| {
            defer lang.deinitError(arena, err);
            // extract the report from whichever phase produced it
            const report = switch (err) {
                .parse => |f| f.report,
                .expand => |f| f.report,
                .lower => |f| f.report,
                .semantic => |f| f.report,
            };
            const lsp_diags = try reportToDiags(arena, report, h.enc);
            try h.transport.writeNotification(
                h.io,
                arena,
                "textDocument/publishDiagnostics",
                T.publish_diagnostics.Params,
                .{
                    .uri = uri,
                    .diagnostics = lsp_diags,
                },
                .{},
            );
        } else {
            // clear previous diags
            try h.transport.writeNotification(
                h.io,
                arena,
                "textDocument/publishDiagnostics",
                T.publish_diagnostics.Params,
                .{
                    .uri = uri,
                    .diagnostics = &.{},
                },
                .{},
            );
        }
    }

    /// check rename validity
    pub fn @"textDocument/prepareRename"(
        h: *Handler,
        arena: std.mem.Allocator,
        params: T.prepare_rename.Params,
    ) !?T.prepare_rename.Result {
        const file_id = h.uri_to_file.get(params.textDocument.uri) orelse return null;
        const snap = h.ws.snapshot(file_id) orelse return null;
        const ws_pos = clientToWs(snap.text, params.position, h.enc);
        const range = try h.ws.prepareRename(arena, file_id, ws_pos, .{}) orelse return null;
        return T.prepare_rename.Result{ .range = .{ .start = wsToClient(snap.text, range.start, h.enc), .end = wsToClient(snap.text, range.end, h.enc) } };
    }

    /// rename symbol at position across the workspace
    pub fn @"textDocument/rename"(h: *Handler, arena: std.mem.Allocator, params: T.rename.Params) !?T.WorkspaceEdit {
        const file_id = h.uri_to_file.get(params.textDocument.uri) orelse return null;
        const snap = h.ws.snapshot(file_id) orelse return null;
        const ws_pos = clientToWs(snap.text, params.position, h.enc);
        const refs = try h.ws.references(arena, file_id, ws_pos, .{});
        defer arena.free(refs);

        var file_edits = std.StringHashMap(std.ArrayList(T.TextEdit)).init(arena);
        defer file_edits.deinit();

        for (refs) |ref| {
            const uri = h.file_to_uri.get(ref.file_id) orelse continue;
            const ref_text = (h.ws.snapshot(ref.file_id) orelse snap).text;
            const gop = try file_edits.getOrPut(uri);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(arena, .{
                .range = .{ .start = wsToClient(ref_text, ref.range.start, h.enc), .end = wsToClient(ref_text, ref.range.end, h.enc) },
                .newText = params.newName,
            });
        }

        var changes = std.json.ArrayHashMap([]const T.TextEdit){ .map = .empty };
        var it = file_edits.iterator();
        while (it.next()) |entry| {
            try changes.map.put(arena, entry.key_ptr.*, try entry.value_ptr.toOwnedSlice(arena));
        }
        return T.WorkspaceEdit{ .changes = changes };
    }

    /// return type inlay hints for visible bindings
    pub fn @"textDocument/inlayHint"(
        h: *Handler,
        arena: std.mem.Allocator,
        params: T.InlayHint.Params,
    ) !?[]const T.InlayHint {
        const file_id = h.uri_to_file.get(params.textDocument.uri) orelse return null;
        const snap = h.ws.snapshot(file_id) orelse return null;
        const ws_range: Workspace.Range = .{ .start = clientToWs(snap.text, params.range.start, h.enc), .end = clientToWs(snap.text, params.range.end, h.enc) };
        const ws_hints = try h.ws.inlayHints(arena, file_id, ws_range, .{});
        defer arena.free(ws_hints);

        var out = try std.ArrayList(T.InlayHint).initCapacity(arena, ws_hints.len);
        for (ws_hints) |ws_hint| {
            out.appendAssumeCapacity(.{
                .position = wsToClient(snap.text, ws_hint.position, h.enc),
                .label = .{ .string = ws_hint.label },
                .kind = switch (ws_hint.kind) {
                    .type => T.InlayHint.Kind.Type,
                    .parameter => T.InlayHint.Kind.Parameter,
                },
                .paddingLeft = false,
                .paddingRight = ws_hint.kind == .parameter,
            });
        }
        return try out.toOwnedSlice(arena);
    }

    /// highlighting
    pub fn @"textDocument/semanticTokens/full"(
        h: *Handler,
        arena: std.mem.Allocator,
        params: T.semantic_tokens.Params,
    ) !?T.semantic_tokens.Result {
        const file_id = h.uri_to_file.get(params.textDocument.uri) orelse return null;
        const snap = h.ws.snapshot(file_id) orelse return null;
        const source = snap.text;

        const lexed = try lang.lexReportAt(arena, source, .{});
        const tokens = switch (lexed) {
            .ok => |t| t,
            .err => return null,
        };

        // try parser-based role map for more accurate highlighting
        const ast_map = Workspace.buildASTSpanMap(arena, source);

        var cap: usize = tokens.len * 5;
        for (tokens) |t| {
            if (t.interp_opens.len > 0) {
                const inner_off: usize = if (t.type == .multiline_string) 3 else 1;
                const inner_start = t.start + inner_off;
                const inner_end = t.end - inner_off;
                if (inner_start >= inner_end) continue;
                var literal_start: usize = inner_start;
                for (t.interp_opens) |open| {
                    if (open.offset < literal_start) continue;
                    cap += 10; // literal prefix + #{ operator
                    const close = interpEnd(source, open.offset, inner_end) orelse {
                        literal_start = open.offset + 1;
                        continue;
                    };
                    const body_start = open.offset + 1;
                    if (close > body_start) {
                        const body = source[body_start..close];
                        if (lang.lexReportAt(arena, body, .{
                            .offset = body_start,
                            .line = open.line,
                            .column = open.column + 1,
                        })) |body_lexed| {
                            const sub = switch (body_lexed) {
                                .ok => |t2| t2,
                                .err => &.{},
                            };
                            cap += sub.len * 5;
                        } else |_| {}
                    }
                    cap += 5; // closing }
                    literal_start = close + 1;
                }
                if (inner_end > literal_start) cap += 5;
            }
        }
        var data = try std.ArrayList(u32).initCapacity(arena, cap);

        var prev_line: u32 = 0;
        var prev_col: u32 = 0;

        for (tokens) |tok| {
            if (tok.type == .eof) break;

            if (tok.interp_opens.len > 0 and (tok.type == .string or tok.type == .multiline_string)) {
                try emitInterpolatedStringTokens(arena, source, tok, &data, &prev_line, &prev_col, h.enc);
                continue;
            }

            const ctfr = switch (tok.type) {
                .ident => if (lang.identIsFunction(source, tok.end)) tc(.function) else tc(.variable),
                else => @intFromEnum(tok.type.classify() orelse .variable),
            };

            const type_idx = if (ast_map) |m|
                if (m.get(tok.start)) |t| t else ctfr
            else
                ctfr;

            emitSemanticToken(&data, &prev_line, &prev_col, tok.start, tok.end, type_idx, source, h.enc);
        }

        return T.semantic_tokens.Result{ .data = try data.toOwnedSlice(arena) };
    }
};

//
// helpers
//

fn tc(cls: lang.TokenClass) u32 {
    return @intFromEnum(cls);
}

fn interpEnd(source: []const u8, start: usize, bound: usize) ?usize {
    var depth: usize = 1;
    var quote: u8 = 0;
    var escaped = false;
    var i = start + 1;
    while (i < bound) : (i += 1) {
        const c = source[i];
        if (quote != 0) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == quote) {
                quote = 0;
            }
            continue;
        }
        if (c == '"' or c == '\'' or c == '`') {
            quote = c;
        } else if (c == '{') {
            depth += 1;
        } else if (c == '}') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn emitSemanticToken(
    data: *std.ArrayList(u32),
    prev_line: *u32,
    prev_col: *u32,
    start: usize,
    end: usize,
    type_idx: u32,
    source: []const u8,
    enc: lsp.offsets.Encoding,
) void {
    const pos = offsetToLspPos(source, start, enc);
    const line = pos.line;
    const col = pos.character;
    const dl = line - prev_line.*;
    const dc = if (dl > 0) col else col - prev_col.*;
    data.appendAssumeCapacity(dl);
    data.appendAssumeCapacity(dc);
    data.appendAssumeCapacity(@intCast(lsp.offsets.countCodeUnits(source[start..end], enc)));
    data.appendAssumeCapacity(type_idx);
    data.appendAssumeCapacity(0);
    prev_line.* = line;
    prev_col.* = col;
}

fn emitInterpolatedStringTokens(
    arena: std.mem.Allocator,
    source: []const u8,
    tok: lang.Token,
    data: *std.ArrayList(u32),
    prev_line: *u32,
    prev_col: *u32,
    enc: lsp.offsets.Encoding,
) !void {
    const inner_off: usize = if (tok.type == .multiline_string) 3 else 1;
    const inner_start = tok.start + inner_off;
    const inner_end = tok.end - inner_off;

    if (inner_start >= inner_end) return;

    var literal_start: usize = inner_start;

    for (tok.interp_opens) |open| {
        // the lexer also records nested braces inside an earlier body; skip
        if (open.offset < literal_start) continue;

        // emit literal string part before this `#{`
        if (open.offset - 1 > literal_start) {
            emitSemanticToken(data, prev_line, prev_col, literal_start, open.offset - 1, tc(.string), source, enc);
        }

        // emit #{ as operator
        emitSemanticToken(data, prev_line, prev_col, open.offset - 1, open.offset + 1, tc(.operator), source, enc);

        // find matching }
        const close = interpEnd(source, open.offset, inner_end) orelse {
            literal_start = open.offset + 1;
            continue;
        };

        // emit expression body tokens
        if (close > open.offset + 1) {
            try emitSubTokens(arena, source, open, close, data, prev_line, prev_col, enc);
        }

        // emit } as operator
        emitSemanticToken(data, prev_line, prev_col, close, close + 1, tc(.operator), source, enc);

        literal_start = close + 1;
    }

    // remaining literal string part
    if (inner_end > literal_start) {
        emitSemanticToken(data, prev_line, prev_col, literal_start, inner_end, tc(.string), source, enc);
    }
}

fn emitSubTokens(
    arena: std.mem.Allocator,
    source: []const u8,
    open: lang.InterpOpen,
    close: usize,
    data: *std.ArrayList(u32),
    prev_line: *u32,
    prev_col: *u32,
    enc: lsp.offsets.Encoding,
) !void {
    const body_start = open.offset + 1;
    const body = source[body_start..close];
    // lex the body with an origin at the `{` so sub-token offsets come out
    // absolute in the source already
    const lexed = lang.lexReportAt(arena, body, .{
        .offset = body_start,
        .line = open.line,
        .column = open.column + 1,
    }) catch return;
    const sub_tokens = switch (lexed) {
        .ok => |t| t,
        .err => return,
    };

    for (sub_tokens) |st| {
        if (st.type == .eof) break;
        const ctfr = switch (st.type) {
            .ident => if (lang.identIsFunction(body, st.end - body_start)) tc(.function) else tc(.variable),
            else => @intFromEnum(st.type.classify() orelse .variable),
        };
        emitSemanticToken(data, prev_line, prev_col, st.start, st.end, ctfr, source, enc);
    }
}

/// convert a diag report into lsp diag objects
fn reportToDiags(arena: std.mem.Allocator, report: lang.diagnostic.Report, enc: lsp.offsets.Encoding) ![]T.Diagnostic {
    const source = report.source orelse "";
    if (report.parts.len == 0) return arena.alloc(T.Diagnostic, 0);
    var out = try std.ArrayList(T.Diagnostic).initCapacity(arena, report.parts.len);

    // only span parts carry position info; each span shows its nearest
    // preceding error text, falling back through report and span labels
    var last_error: []const u8 = "";
    for (report.parts) |part| {
        if (part == .@"error") {
            last_error = part.@"error";
            continue;
        }
        if (part != .span) continue;
        const sp = part.span;
        const message = if (last_error.len > 0)
            last_error
        else if (report.message.len > 0)
            report.message
        else if (sp.message.len > 0)
            sp.message
        else
            "error";
        out.appendAssumeCapacity(.{
            .range = .{
                .start = offsetToLspPos(source, sp.span.start, enc),
                .end = offsetToLspPos(source, sp.span.end, enc),
            },
            .severity = switch (sp.role) {
                .primary => T.Diagnostic.Severity.Error,
                .secondary => T.Diagnostic.Severity.Warning,
                .context => T.Diagnostic.Severity.Information,
                .trace => T.Diagnostic.Severity.Hint,
            },
            .message = message,
            .source = "revo",
            .tags = &.{},
            .relatedInformation = &.{},
        });
    }

    // no span parts with position; so emit a file-level diagnostic instead
    if (out.items.len == 0) {
        out.appendAssumeCapacity(.{
            .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
            .severity = T.Diagnostic.Severity.Error,
            .message = if (report.message.len > 0) report.message else "error",
            .source = "revo",
            .tags = &.{},
            .relatedInformation = &.{},
        });
    }
    return out.toOwnedSlice(arena);
}

/// convert a byte offset to 9-based pos in the negotiated encoding
fn offsetToLspPos(text: []const u8, byte_off: usize, enc: lsp.offsets.Encoding) T.Position {
    const off = @min(byte_off, text.len);
    const boundary = if (off < text.len and (text[off] & 0xC0) == 0x80) blk: {
        var i = off;
        while (i > 0 and (text[i] & 0xC0) == 0x80) i -= 1;
        break :blk i;
    } else off;
    return lsp.offsets.indexToPosition(text, boundary, enc);
}

/// client position (0-based, enc units) -> workspace position (1-based, bytes)
fn clientToWs(text: []const u8, p: T.Position, enc: lsp.offsets.Encoding) Workspace.Position {
    const byte_pos = lsp.offsets.convertPositionEncoding(text, p, enc, .@"utf-8");
    return .{ .line = byte_pos.line + 1, .character = byte_pos.character + 1 };
}

/// workspace pos (1-based, bytes) -> client position (0-based, enc units)
fn wsToClient(text: []const u8, p: Workspace.Position, enc: lsp.offsets.Encoding) T.Position {
    const byte_pos: T.Position = .{ .line = p.line - 1, .character = p.character - 1 };
    return lsp.offsets.convertPositionEncoding(text, byte_pos, .@"utf-8", enc);
}

/// convert 1-based workspace position to byte offset
fn positionToOffset(text: []const u8, pos: Workspace.Position) ?usize {
    var line: u32 = 1;
    var col: u32 = 1;
    for (text, 0..) |ch, idx| {
        if (line == pos.line and col == pos.character) return idx;
        if (ch == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    if (line == pos.line and col == pos.character) return text.len;
    return null;
}
