//! doc extraction, docgen rendering for terminal text + html, collection for cli

const std = @import("std");
const revo = @import("../root.zig");
const api = revo.std_lib.api;
const Writer = std.Io.Writer;
const pretty = revo.pretty;

pub const FnSpec = api.FnSpec;

const bold = "\x1b[1m";
const dim = "\x1b[2m";
const reset = "\x1b[0m";
const cyan = "\x1b[36m";
const magenta = "\x1b[35m";
const blue = "\x1b[34m";
const yellow = "\x1b[33m";

fn style(w: *Writer, code: []const u8) !void {
    try revo.pretty.style(w, code);
}

// -- [extract] ---------------------------------------------------------------

pub const Extracted = struct {
    specs: []FnSpec,
    module_doc: []const u8 = "",
};

/// a `#! ... !#` block before any code is the module's own doc
fn moduleDoc(src: []const u8) ![]const u8 {
    const result = try revo.lang.lexReportAt(std.heap.page_allocator, src, .{});
    const tokens = switch (result) {
        .ok => |t| t,
        .err => return "",
    };
    defer std.heap.page_allocator.free(tokens);
    for (tokens) |tok| {
        if (tok.type != .comment) {
            if (tok.type == .module_doc) return std.mem.trim(u8, tok.text, "#! \t\r\n");
            return "";
        }
    }
    return "";
}

/// `#* ... *#`-attributed decls and a leading `#! ... !#` module doc
pub fn docsExtract(alloc: std.mem.Allocator, src: []const u8) !Extracted {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try revo.lang.parseSourceReport(a, src);
    const root_node = switch (parsed) {
        .ok => |node| node,
        .err => |f| {
            if (f.kind == .LexLateModuleDoc) return error.LateModuleDoc;
            return error.IfaceParseFailed;
        },
    };

    const specs = try api.collectSpecs(alloc, root_node, false);
    errdefer freeSpecs(alloc, specs);

    var kept = std.ArrayList(FnSpec).empty;
    errdefer kept.deinit(alloc);

    for (specs) |s| {
        if (std.mem.startsWith(u8, s.name, "__internal")) {
            s.deinit(alloc);
            continue;
        }
        try kept.append(alloc, s);
    }

    alloc.free(specs);
    return .{ .specs = try kept.toOwnedSlice(alloc), .module_doc = try moduleDoc(src) };
}

pub fn freeSpecs(alloc: std.mem.Allocator, specs: []const FnSpec) void {
    for (specs) |s| s.deinit(alloc);
    alloc.free(specs);
}

// -- [docgen] ----------------------------------------------------------------

const docgen_start_marker = "<!-- docgen:start -->";
const docgen_end_marker = "<!-- docgen:end -->";

pub fn spliceMarkdown(alloc: std.mem.Allocator, old: []const u8, body: []const u8) ![]const u8 {
    const s = std.mem.indexOf(u8, old, docgen_start_marker) orelse return error.MissingDocgenMarker;
    const e = std.mem.indexOfPos(u8, old, s + docgen_start_marker.len, docgen_end_marker) orelse return error.MissingDocgenMarker;

    return std.mem.concat(alloc, u8, &.{
        old[0..s],
        docgen_start_marker,
        "\n",
        body,
        "\n",
        docgen_end_marker,
        old[e + docgen_end_marker.len ..],
    });
}

// -- [shared] ------------------------------------------------------------

/// slugs are only meaningful for html, but both renderers make the
/// same sorted list of these so grouping/sorting logic stays shared
const Planned = struct {
    spec: *const FnSpec,
    slug: []const u8 = "",
};

fn sortByName(list: []Planned) void {
    std.mem.sort(Planned, list, {}, struct {
        fn less(_: void, a: Planned, b: Planned) bool {
            return std.mem.order(u8, a.spec.name, b.spec.name) == .lt;
        }
    }.less);
}

pub fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

const SlugSet = struct {
    map: std.StringHashMapUnmanaged(u32) = .empty,

    fn deinit(self: *SlugSet, alloc: std.mem.Allocator) void {
        self.map.deinit(alloc);
    }

    fn assign(self: *SlugSet, alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
        const base = try slugify(alloc, name);
        const n = self.map.get(base) orelse 0;
        try self.map.put(alloc, base, n + 1);
        if (n == 0) return base;

        return std.fmt.allocPrint(alloc, "{s}-{d}", .{ base, n });
    }
};

fn slugify(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try out.append(alloc, std.ascii.toLower(c));
        } else if (c == '_' or c == '-') {
            try out.append(alloc, c);
        } else if (c == ' ') {
            try out.append(alloc, '-');
        }
    }

    if (out.items.len == 0) try out.appendSlice(alloc, "anonymous");
    return out.toOwnedSlice(alloc);
}

fn collectGlobals(alloc: std.mem.Allocator, specs: []*const FnSpec) !std.ArrayList(Planned) {
    var planned = std.ArrayList(Planned).empty;
    for (specs) |s| {
        if (s.head.kind == .global) try planned.append(alloc, .{ .spec = s });
    }
    sortByName(planned.items);
    return planned;
}

fn collectModuleNames(alloc: std.mem.Allocator, specs: []*const FnSpec) !std.ArrayList([]const u8) {
    var set = std.StringHashMapUnmanaged(void){};
    defer set.deinit(alloc);
    for (specs) |s| {
        const head = s.head;
        if (head.kind == .module) try set.put(alloc, head.module.?, {});
    }
    var names = std.ArrayList([]const u8).empty;
    var it = set.keyIterator();
    while (it.next()) |k| try names.append(alloc, k.*);
    std.mem.sort([]const u8, names.items, {}, lessStr);
    return names;
}

fn collectModule(alloc: std.mem.Allocator, specs: []*const FnSpec, mod_name: []const u8) !std.ArrayList(Planned) {
    var planned = std.ArrayList(Planned).empty;
    for (specs) |s| {
        const head = s.head;
        if (head.kind == .module and std.mem.eql(u8, head.module.?, mod_name)) {
            try planned.append(alloc, .{ .spec = s });
        }
    }
    sortByName(planned.items);
    return planned;
}

fn collectMethodTargets(alloc: std.mem.Allocator, specs: []*const FnSpec) !std.ArrayList([]const u8) {
    var set = std.StringHashMapUnmanaged(void){};
    defer set.deinit(alloc);
    for (specs) |s| {
        if (s.head.target_name) |prefix| try set.put(alloc, prefix, {});
    }
    var names = std.ArrayList([]const u8).empty;
    var it = set.keyIterator();
    while (it.next()) |k| try names.append(alloc, k.*);
    std.mem.sort([]const u8, names.items, {}, lessStr);
    return names;
}

fn collectMethods(alloc: std.mem.Allocator, specs: []*const FnSpec, target_name: []const u8) !std.ArrayList(Planned) {
    var planned = std.ArrayList(Planned).empty;
    for (specs) |s| {
        if (std.mem.eql(u8, s.head.target_name orelse "", target_name)) {
            try planned.append(alloc, .{ .spec = s });
        }
    }
    sortByName(planned.items);
    return planned;
}

fn writeIndent(w: *Writer, indent: usize) !void {
    var i: usize = 0;
    while (i < indent) : (i += 1) try w.writeByte(' ');
}

// -- [text] --------------------------------------------------------------
//
// ` 0 spaces for section headers
// ` 2 spaces for toplevel definitions (functions, types, modules)
// ` 4 spaces for their direct children (descriptions, methods)
// ` 6 spaces for method descriptions and nested content

pub fn renderText(
    alloc: std.mem.Allocator,
    w: *Writer,
    specs: []*const FnSpec,
    module_doc: []const u8,
) !void {
    if (module_doc.len > 0) {
        try style(w, dim);
        try writeIndentedDoc(w, module_doc, 0);
        try style(w, reset);
        try w.writeAll("\n");
    }

    var consumed = std.StringHashMapUnmanaged(void){};
    defer consumed.deinit(alloc);

    try renderTextGlobals(alloc, w, specs, &consumed);
    try renderTextModules(alloc, w, specs, &consumed);
    try renderTextMethods(alloc, w, specs, &consumed);
}

fn renderTextGlobals(alloc: std.mem.Allocator, w: *Writer, specs: []*const FnSpec, consumed: *std.StringHashMapUnmanaged(void)) !void {
    var planned = try collectGlobals(alloc, specs);
    defer planned.deinit(alloc);
    if (planned.items.len == 0) return;

    try style(w, bold);
    try w.writeAll("top-level");
    try style(w, reset);
    try w.writeAll("\n");
    for (planned.items) |p| {
        try renderTextFn(alloc, w, p.spec, false, 2, 4);
        try renderTextNestedMethods(alloc, w, specs, p.spec.name, 4, 6, consumed);
    }
}

fn renderTextModules(alloc: std.mem.Allocator, w: *Writer, specs: []*const FnSpec, consumed: *std.StringHashMapUnmanaged(void)) !void {
    var names = try collectModuleNames(alloc, specs);
    defer names.deinit(alloc);
    if (names.items.len == 0) return;

    try style(w, bold);
    try w.writeAll("modules");
    try style(w, reset);
    try w.writeAll("\n");
    for (names.items) |mod_name| {
        var planned = try collectModule(alloc, specs, mod_name);
        defer planned.deinit(alloc);

        try w.writeAll("\n  ");
        try style(w, dim);
        try w.writeAll("module ");
        try style(w, reset);
        try style(w, bold ++ cyan);
        try w.writeAll(mod_name);
        try style(w, reset);
        try w.writeAll("\n");

        for (planned.items) |p| {
            if (p.spec.module_doc.len > 0) {
                try style(w, dim);
                try writeIndentedDoc(w, p.spec.module_doc, 4);
                try style(w, reset);
                try w.writeByte('\n');
                break;
            }
        }

        for (planned.items) |p| {
            try renderTextFn(alloc, w, p.spec, false, 4, 6);
            try renderTextNestedMethods(alloc, w, specs, p.spec.name, 6, 8, consumed);
        }
    }
}

fn renderTextMethods(alloc: std.mem.Allocator, w: *Writer, specs: []*const FnSpec, consumed: *const std.StringHashMapUnmanaged(void)) !void {
    var names = try collectMethodTargets(alloc, specs);
    defer names.deinit(alloc);

    var remaining = std.ArrayList([]const u8).empty;
    defer remaining.deinit(alloc);
    for (names.items) |n| {
        if (!consumed.contains(n)) try remaining.append(alloc, n);
    }
    if (remaining.items.len == 0) return;

    try style(w, bold);
    try w.writeAll("methods");
    try style(w, reset);
    try w.writeAll("\n");
    for (remaining.items) |target_name| {
        var planned = try collectMethods(alloc, specs, target_name);
        defer planned.deinit(alloc);

        try w.writeAll("\n  ");
        try style(w, dim);
        try w.writeAll("type ");
        try style(w, reset);
        try style(w, bold ++ blue);
        try w.writeAll(target_name);
        try style(w, reset);
        try w.writeAll("\n");

        for (planned.items) |p| try renderTextFn(alloc, w, p.spec, true, 4, 6);
    }
}

fn renderTextNestedMethods(
    alloc: std.mem.Allocator,
    w: *Writer,
    specs: []*const FnSpec,
    target_name: []const u8,
    sig_indent: usize,
    doc_indent: usize,
    consumed: *std.StringHashMapUnmanaged(void),
) !void {
    var planned = try collectMethods(alloc, specs, target_name);
    defer planned.deinit(alloc);
    if (planned.items.len == 0) return;

    try consumed.put(alloc, target_name, {});
    for (planned.items) |p| try renderTextFn(alloc, w, p.spec, true, sig_indent, doc_indent);
}

fn renderTextFn(alloc: std.mem.Allocator, w: *Writer, spec: *const FnSpec, strip_method: bool, sig_indent: usize, doc_indent: usize) !void {
    var sig_buf = std.Io.Writer.Allocating.init(alloc);
    defer sig_buf.deinit();
    if (strip_method) {
        try api.renderSignatureStripMethod(&sig_buf.writer, spec.*);
    } else {
        try api.renderSignature(&sig_buf.writer, spec.*);
    }
    const sig = sig_buf.written();
    try w.writeAll("\n");
    try writeIndent(w, sig_indent);
    if (spec.is_type) {
        try style(w, cyan);
        try w.print("{s}", .{spec.name});
        try style(w, reset);
        try w.writeAll("\n");
        try writeIndent(w, doc_indent);
        try style(w, dim);
        try w.writeAll("(value)");
        try style(w, reset);
        try w.writeAll("\n");
    } else {
        try style(w, magenta);
        try w.writeAll("fn");
        try style(w, reset);
        try w.writeByte(' ');
        const name_end = std.mem.indexOf(u8, sig, "(") orelse sig.len;
        try style(w, cyan);
        try w.writeAll(sig[0..name_end]);
        try style(w, reset);
        try w.writeAll(sig[name_end..]);
        try w.writeAll("\n");
    }

    if (api.coreKey(spec)) |k| {
        try writeIndent(w, doc_indent);
        try style(w, dim);
        try w.writeAll("metatable key: ");
        try style(w, reset);
        try style(w, yellow);
        try w.print("{s}", .{@tagName(k)});
        try style(w, reset);
        try w.writeAll("\n");
    }

    if (spec.doc.len > 0) {
        try writeIndentedDoc(w, spec.doc, doc_indent);
    } else {
        try writeIndent(w, doc_indent);
        try style(w, dim);
        try w.writeAll("undocumented :(");
        try style(w, reset);
        try w.writeAll("\n");
    }
}

fn writeIndentedDoc(w: *Writer, doc: []const u8, indent: usize) !void {
    const trimmed = std.mem.trim(u8, doc, "\n");
    if (trimmed.len == 0) return;

    const min_indent = minIndentOf(trimmed);

    var it = std.mem.splitScalar(u8, trimmed, '\n');
    while (it.next()) |line| {
        if (std.mem.trim(u8, line, " \t").len == 0) {
            try w.writeAll("\n");
            continue;
        }
        const stripped = if (line.len >= min_indent) line[min_indent..] else line;
        try writeIndent(w, indent);
        try w.writeAll(stripped);
        try w.writeAll("\n");
    }
}

/// the smallest leading-space count across all non-blank lines of `text`
fn minIndentOf(text: []const u8) usize {
    var min_indent: usize = std.math.maxInt(usize);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t").len == 0) continue;
        var n: usize = 0;
        while (n < line.len and line[n] == ' ') n += 1;
        if (n < min_indent) min_indent = n;
    }
    return if (min_indent == std.math.maxInt(usize)) 0 else min_indent;
}

// -- [html] ------------------------------------------------------------------

pub fn renderHtml(
    alloc: std.mem.Allocator,
    w: *Writer,
    specs: []*const FnSpec,
    module_doc: []const u8,
) !void {
    var slugs = SlugSet{};
    defer slugs.deinit(alloc);
    var consumed = std.StringHashMapUnmanaged(void){};
    defer consumed.deinit(alloc);

    if (module_doc.len > 0) {
        try writeHtmlTextBlock(w, 0, "<p class=\"module-doc\">", "</p>", module_doc, 0);
    }
    try renderHtmlGlobals(alloc, w, specs, &slugs, &consumed);
    try renderHtmlModules(alloc, w, specs, &slugs, &consumed);
    try renderHtmlMethods(alloc, w, specs, &slugs, &consumed);
}

fn renderHtmlGlobals(alloc: std.mem.Allocator, w: *Writer, specs: []*const FnSpec, slugs: *SlugSet, consumed: *std.StringHashMapUnmanaged(void)) !void {
    var planned = try collectGlobals(alloc, specs);
    defer planned.deinit(alloc);
    if (planned.items.len == 0) return;
    for (planned.items) |*p| p.slug = try slugs.assign(alloc, p.spec.name);

    try w.writeAll("<section class=\"section section-globals\">\n");
    try writeIndent(w, 2);
    try w.writeAll("<h2>globals</h2>\n\n");

    try renderHtmlToc(w, planned.items, 2);

    try writeIndent(w, 2);
    try w.writeAll("<details open>\n");
    try writeIndent(w, 4);
    try w.print("<summary>{d} entries</summary>\n\n", .{planned.items.len});
    for (planned.items) |p| try renderHtmlFn(w, p, false, 4, alloc, specs, slugs, consumed);
    try writeIndent(w, 2);
    try w.writeAll("</details>\n");

    try w.writeAll("</section>\n\n");
}

fn renderHtmlModules(alloc: std.mem.Allocator, w: *Writer, specs: []*const FnSpec, slugs: *SlugSet, consumed: *std.StringHashMapUnmanaged(void)) !void {
    var names = try collectModuleNames(alloc, specs);
    defer names.deinit(alloc);
    if (names.items.len == 0) return;

    try w.writeAll("<section class=\"section section-modules\">\n");
    try writeIndent(w, 2);
    try w.writeAll("<h2>modules</h2>\n\n");

    for (names.items) |mod_name| {
        var planned = try collectModule(alloc, specs, mod_name);
        defer planned.deinit(alloc);
        for (planned.items) |*p| p.slug = try slugs.assign(alloc, p.spec.name);
        try renderHtmlGroup(w, "module", mod_name, planned.items, false, 2, alloc, specs, slugs, consumed);
    }

    try w.writeAll("</section>\n\n");
}

fn renderHtmlMethods(alloc: std.mem.Allocator, w: *Writer, specs: []*const FnSpec, slugs: *SlugSet, consumed: *const std.StringHashMapUnmanaged(void)) !void {
    var names = try collectMethodTargets(alloc, specs);
    defer names.deinit(alloc);

    var remaining = std.ArrayList([]const u8).empty;
    defer remaining.deinit(alloc);
    for (names.items) |n| {
        if (!consumed.contains(n)) try remaining.append(alloc, n);
    }
    if (remaining.items.len == 0) return;

    try w.writeAll("<section class=\"section section-methods\">\n");
    try writeIndent(w, 2);
    try w.writeAll("<h2>methods</h2>\n\n");

    for (remaining.items) |target_name| {
        var planned = try collectMethods(alloc, specs, target_name);
        defer planned.deinit(alloc);
        for (planned.items) |*p| p.slug = try slugs.assign(alloc, p.spec.name);
        try renderHtmlGroup(w, "type", target_name, planned.items, true, 2, alloc, specs, slugs, @constCast(consumed));
    }

    try w.writeAll("</section>\n\n");
}

/// a `module <name>` / `type <name>` group, its own `<section>` nested
/// `indent` spaces deep; everything inside is one step further in
fn renderHtmlGroup(
    w: *Writer,
    kind: []const u8,
    name: []const u8,
    planned: []const Planned,
    strip_prefix: bool,
    indent: usize,
    alloc: std.mem.Allocator,
    specs: []*const FnSpec,
    slugs: *SlugSet,
    consumed: *std.StringHashMapUnmanaged(void),
) !void {
    try writeIndent(w, indent);
    try w.writeAll("<section class=\"group\">\n");

    try writeIndent(w, indent + 2);
    try w.writeAll("<h3><span class=\"kind\">");
    try writeHtmlEscaped(w, kind);
    try w.writeAll("</span> ");
    try writeHtmlEscaped(w, name);
    try w.writeAll("</h3>\n\n");

    for (planned) |p| {
        if (p.spec.module_doc.len > 0) {
            try writeHtmlTextBlock(w, indent + 2, "<blockquote class=\"group-doc\">", "</blockquote>", p.spec.module_doc, 0);
            break;
        }
    }

    try renderHtmlToc(w, planned, indent + 2);

    try writeIndent(w, indent + 2);
    try w.writeAll("<details>\n");
    try writeIndent(w, indent + 4);
    try w.print("<summary>{d} entries</summary>\n\n", .{planned.len});
    for (planned) |p| {
        try renderHtmlFn(w, p, strip_prefix, indent + 4, alloc, specs, slugs, consumed);
    }
    try writeIndent(w, indent + 2);
    try w.writeAll("</details>\n");

    try writeIndent(w, indent);
    try w.writeAll("</section>\n\n");
}

fn renderHtmlToc(w: *Writer, planned: []const Planned, indent: usize) !void {
    try writeIndent(w, indent);
    try w.writeAll("<nav class=\"toc\">\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("<p>\n");
    for (planned) |p| {
        try writeIndent(w, indent + 4);
        try w.writeAll("<a href=\"#");
        try w.writeAll(p.slug);
        try w.writeAll("\">");
        try writeHtmlEscaped(w, p.spec.name);
        try w.writeAll("</a> |");
    }
    try writeIndent(w, indent + 2);
    try w.writeAll("</p>\n");
    try writeIndent(w, indent);
    try w.writeAll("</nav>\n\n");
}

fn renderHtmlFn(
    w: *Writer,
    p: Planned,
    strip_prefix: bool,
    indent: usize,
    alloc: std.mem.Allocator,
    specs: []*const FnSpec,
    slugs: *SlugSet,
    consumed: *std.StringHashMapUnmanaged(void),
) anyerror!void {
    const spec = p.spec;

    try writeIndent(w, indent);
    try w.writeAll("<article class=\"entry\" id=\"");
    try w.writeAll(p.slug);
    try w.writeAll("\">\n");

    try writeHtmlTextBlock(w, indent + 2, "<h4>", "</h4>", spec.name, 0);

    if (spec.is_type) {
        try writeIndent(w, indent + 2);
        try w.writeAll("<p class=\"marker\">(value)</p>\n\n");
    } else {
        var sig_buf = std.Io.Writer.Allocating.init(alloc);
        defer sig_buf.deinit();
        if (strip_prefix) {
            try api.renderSignatureStripMethod(&sig_buf.writer, spec.*);
        } else {
            try api.renderSignature(&sig_buf.writer, spec.*);
        }
        try writeHtmlTextBlock(w, 0, "<pre class=\"signature\"><code>", "</code></pre>", sig_buf.written(), 0);
    }

    if (api.coreKey(spec)) |k| {
        try writeIndent(w, indent + 2);
        try w.writeAll("<p class=\"metatable-key\">metatable key: <code>");
        try writeHtmlEscaped(w, @tagName(k));
        try w.writeAll("</code></p>\n\n");
    }

    if (spec.doc.len == 0) {
        try writeIndent(w, indent + 2);
        try w.writeAll("<blockquote class=\"undocumented\">undocumented :(</blockquote>\n\n");
    } else {
        try renderHtmlDoc(w, spec.doc, indent + 2);
    }

    try renderHtmlNestedMethods(alloc, w, specs, spec.name, indent + 2, slugs, consumed);

    try writeIndent(w, indent);
    try w.writeAll("</article>\n\n");
}

fn renderHtmlNestedMethods(
    alloc: std.mem.Allocator,
    w: *Writer,
    specs: []*const FnSpec,
    target_name: []const u8,
    indent: usize,
    slugs: *SlugSet,
    consumed: *std.StringHashMapUnmanaged(void),
) anyerror!void {
    var planned = try collectMethods(alloc, specs, target_name);
    defer planned.deinit(alloc);
    if (planned.items.len == 0) return;

    try consumed.put(alloc, target_name, {});
    for (planned.items) |*p| p.slug = try slugs.assign(alloc, p.spec.name);

    try writeIndent(w, indent);
    try w.writeAll("<section class=\"methods\">\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("<h5>methods</h5>\n\n");
    for (planned.items) |p| {
        try renderHtmlFn(w, p, true, indent + 2, alloc, specs, slugs, consumed);
    }
    try writeIndent(w, indent);
    try w.writeAll("</section>\n\n");
}

fn renderHtmlDoc(w: *Writer, doc: []const u8, indent: usize) !void {
    const trimmed = std.mem.trim(u8, doc, "\n");

    var prose: []const u8 = trimmed;
    var code: []const u8 = "";
    if (std.mem.indexOf(u8, trimmed, "\n\n")) |idx| {
        prose = trimmed[0..idx];
        code = std.mem.trim(u8, trimmed[idx + 2 ..], "\n");
    }

    try writeHtmlTextBlock(w, indent, "<p class=\"desc\">", "</p>", prose, minIndentOf(prose));
    if (code.len > 0) {
        try writeHtmlTextBlock(w, 0, "<pre class=\"example\"><code class=\"language-revo\">", "</code></pre>", code, minIndentOf(code));
    }
}

fn writeHtmlTextBlock(w: *Writer, indent: usize, open_tag: []const u8, close_tag: []const u8, text: []const u8, strip: usize) !void {
    try writeIndent(w, indent);
    try w.writeAll(open_tag);
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) {
            try w.writeAll("\n");
            try writeIndent(w, indent);
        }
        first = false;
        const stripped = if (line.len >= strip) line[strip..] else line;
        try writeHtmlEscaped(w, stripped);
    }
    try w.writeAll(close_tag);
    try w.writeAll("\n\n");
}

fn writeHtmlEscaped(w: *Writer, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '&' => try w.writeAll("&amp;"),
            '"' => try w.writeAll("&quot;"),
            else => try w.writeByte(c),
        }
    }
}

// -- [cli] -------------------------------------------------------------------

pub const Cli = struct {
    pub fn run(
        init: std.process.Init,
        gpa: std.mem.Allocator,
        arena: std.mem.Allocator,
        path: ?[]const u8,
        html: bool,
        force_splice: bool,
    ) !void {
        const stdin_tty = try revo.stdin().isTty(init.io);
        const splice = force_splice and !stdin_tty;

        var owned = std.ArrayList([]FnSpec).empty;
        defer owned.deinit(arena);
        var flat = std.ArrayList(*const FnSpec).empty;
        defer flat.deinit(arena);
        var module_doc: []const u8 = "";

        if (path) |p| {
            if (isDir(init, p)) {
                try collectAll(init, gpa, arena, p, &owned, &flat);
            } else {
                module_doc = try addDocsFromPath(init, gpa, arena, p, &owned, &flat);
            }
        } else if (splice or stdin_tty) {
            var project = revo.lang.Project.detectFromCwd(init.io, gpa);
            defer project.deinit(gpa);
            const root_dir: []const u8 = if (project.root.len > 0) project.root else ".";
            const t = try arena.dupe(u8, root_dir);
            try collectAll(init, gpa, arena, t, &owned, &flat);
        } else {
            module_doc = try addDocsFromPath(init, gpa, arena, "/dev/stdin", &owned, &flat);
        }

        try emitDocs(init, gpa, arena, flat.items, module_doc, html, splice);
        for (owned.items) |s| freeSpecs(gpa, s);
    }

    fn collectAll(
        init: std.process.Init,
        gpa: std.mem.Allocator,
        arena: std.mem.Allocator,
        dir: []const u8,
        owned: *std.ArrayList([]FnSpec),
        flat: *std.ArrayList(*const FnSpec),
    ) !void {
        var files = std.ArrayList([]const u8).empty;
        defer files.deinit(arena);
        try collectSourceFiles(init, arena, dir, &files);
        std.mem.sort([]const u8, files.items, {}, lessStr);
        for (files.items) |f| {
            const source = std.Io.Dir.cwd().readFileAlloc(
                init.io,
                f,
                arena,
                std.Io.Limit.unlimited,
            ) catch |err| {
                printError(init, "reading {s} - {}", .{ f, err });
                return error.FileError;
            };
            const prev = owned.items.len;
            const mod_doc = addDocsFromSource(gpa, arena, source, owned, flat) catch |err| blk: {
                if (err == error.LateModuleDoc) {
                    std.debug.print("skipping {s}: module doc must be at the start of the file\n", .{f});
                    break :blk "";
                }
                if (!api.skippableForDocs(err)) return err;
                std.debug.print("skipping {s}: {s}\n", .{ f, @errorName(err) });
                break :blk "";
            };
            if (mod_doc.len > 0) {
                for (owned.items[prev..]) |file_specs| {
                    for (file_specs) |*spec| spec.module_doc = mod_doc;
                }
            }
        }
    }

    fn addDocsFromPath(
        init: std.process.Init,
        gpa: std.mem.Allocator,
        arena: std.mem.Allocator,
        path: []const u8,
        owned: *std.ArrayList([]FnSpec),
        flat: *std.ArrayList(*const FnSpec),
    ) ![]const u8 {
        const source = std.Io.Dir.cwd().readFileAlloc(
            init.io,
            path,
            arena,
            std.Io.Limit.unlimited,
        ) catch |err| {
            printError(init, "reading {s} - {}", .{ path, err });
            return error.FileError;
        };
        return addDocsFromSource(gpa, arena, source, owned, flat) catch |err| {
            // single file was asked for, so spec failures fail loud instead
            // of skipping like the directory walk does
            if (err == error.LateModuleDoc) {
                printError(init, "module doc must be at the start of the file", .{});
                return error.CompilationError;
            }
            if (err == error.IfaceParseFailed) {
                printError(init, "parse error while extracting docs", .{});
                return error.CompilationError;
            }
            if (api.skippableForDocs(err)) {
                printError(init, "cannot document {s}: {s}", .{ path, @errorName(err) });
                return error.CompilationError;
            }
            return err;
        };
    }

    fn addDocsFromSource(
        gpa: std.mem.Allocator,
        arena: std.mem.Allocator,
        source: []const u8,
        owned: *std.ArrayList([]FnSpec),
        flat: *std.ArrayList(*const FnSpec),
    ) ![]const u8 {
        const extracted = try docsExtract(gpa, source);
        try owned.append(arena, extracted.specs);
        for (extracted.specs) |*s| try flat.append(arena, s);
        return extracted.module_doc;
    }

    fn collectSourceFiles(init: std.process.Init, arena: std.mem.Allocator, dir: []const u8, out: *std.ArrayList([]const u8)) !void {
        const open_dir = std.Io.Dir.cwd().openDir(init.io, dir, .{ .iterate = true }) catch |err| {
            printError(init, "opening {s} - {}", .{ dir, err });
            return error.FileError;
        };
        defer open_dir.close(init.io);
        var it = open_dir.iterate();
        while (try it.next(init.io)) |entry| {
            switch (entry.kind) {
                .directory => {
                    if (entry.name.len > 0 and entry.name[0] == '.') continue;
                    if (std.mem.eql(u8, entry.name, "zig-out")) continue;
                    const sub = try std.fs.path.join(arena, &.{ dir, entry.name });
                    try collectSourceFiles(init, arena, sub, out);
                },
                .file => {
                    if (!std.mem.endsWith(u8, entry.name, ".rv")) continue;
                    try out.append(arena, try std.fs.path.join(arena, &.{ dir, entry.name }));
                },
                else => {},
            }
        }
    }

    fn isDir(init: std.process.Init, path: []const u8) bool {
        var d = std.Io.Dir.cwd().openDir(init.io, path, .{}) catch return false;
        d.close(init.io);
        return true;
    }

    fn printError(init: std.process.Init, comptime fmt: []const u8, args: anytype) void {
        var buf = std.Io.Writer.Allocating.init(init.gpa);
        defer buf.deinit();
        pretty.printError(&buf.writer, fmt, args) catch return;
        std.debug.print("{s}", .{buf.written()});
    }

    fn emitDocs(
        init: std.process.Init,
        gpa: std.mem.Allocator,
        arena: std.mem.Allocator,
        flat: []*const FnSpec,
        module_doc: []const u8,
        html: bool,
        splice: bool,
    ) !void {
        var buf = std.Io.Writer.Allocating.init(gpa);
        defer buf.deinit();
        if (html) {
            try renderHtml(gpa, &buf.writer, flat, module_doc);
        } else {
            try renderText(gpa, &buf.writer, flat, module_doc);
        }

        const body = std.mem.trim(u8, buf.written(), "\n");

        var out_buf: [4096]u8 = undefined;
        var out = revo.stdout().writer(init.io, &out_buf);
        if (splice) {
            const old = try std.Io.Dir.cwd().readFileAlloc(
                init.io,
                "/dev/stdin",
                arena,
                std.Io.Limit.unlimited,
            );
            const spliced = try spliceMarkdown(arena, old, body);
            try out.interface.writeAll(spliced);
        } else {
            try out.interface.writeAll(body);
            try out.interface.writeAll("\n");
        }
        try out.flush();
    }
};
