// zlint-disable line-length -- yeah
const std = @import("std");
const ast = @import("ast.zig");

//
// lexer
//

pub const LexError = struct {
    kind: Kind,
    span: ast.Span,
    message: []const u8,

    pub const Kind = enum {
        UnexpectedCharacter,
        UnterminatedComment,
        UnterminatedString,
        LateModuleDoc,
        Unknown,
    };
};

pub const LexResult = union(enum) {
    ok: []Token,
    err: LexError,
};

pub const TokenType = enum {
    number,
    string,
    multiline_string,
    backtick_string,
    hash,
    ident,
    kw_const,
    kw_let,
    kw_macro,
    kw_test,
    kw_suite,
    kw_skip,
    kw_type,
    kw_fn,
    kw_if,
    kw_unless,
    kw_else,
    kw_match,
    kw_when,
    kw_do,
    kw_end,
    kw_loop,
    kw_for,
    kw_while,
    kw_global,
    kw_in,
    kw_break,
    kw_continue,
    kw_return,
    kw_import,
    kw_spawn,
    kw_join,
    kw_yield,
    kw_and,
    kw_or,
    kw_not,
    kw_band,
    kw_bor,
    kw_bxor,
    kw_shl,
    kw_shr,
    kw_comp,
    kw_proc,
    kw_orelse,
    kw_pub,
    kw_declare,
    plus,
    minus,
    star,
    slash,
    slash_slash,
    percent,
    caret,
    caret_assign,
    eq,
    neq,
    lt,
    gt,
    lte,
    gte,
    assign,
    plus_assign,
    minus_assign,
    star_assign,
    slash_assign,
    percent_assign,
    concat,
    concat_assign,
    arrow,
    fat_arrow,
    dot,
    dotdot,
    colon,
    comma,
    semicolon,
    pipe,
    pipe_forward,
    huh,
    bang,
    lparen,
    rparen,
    lbracket,
    rbracket,
    lsquiggly,
    rsquiggly,
    comment,
    doc_comment,
    module_doc,
    eof,
    attribute,

    pub fn classify(self: TokenType) ?TokenClass {
        return switch (self) {
            .number => .number,
            .string, .multiline_string, .backtick_string => .string,
            .hash => .enum_member,
            .kw_const, .kw_let, .kw_macro, .kw_test, .kw_suite, .kw_skip, .kw_type, .kw_fn, .kw_if, .kw_unless, .kw_else, .kw_match, .kw_when, .kw_do, .kw_end, .kw_loop, .kw_for, .kw_while, .kw_global, .kw_in, .kw_break, .kw_continue, .kw_return, .kw_import, .kw_spawn, .kw_join, .kw_yield, .kw_and, .kw_or, .kw_not, .kw_band, .kw_bor, .kw_bxor, .kw_shl, .kw_shr, .kw_comp, .kw_proc, .kw_orelse, .kw_pub, .kw_declare => .keyword,
            .plus, .minus, .star, .slash, .slash_slash, .percent, .caret, .caret_assign, .eq, .neq, .lt, .gt, .lte, .gte, .assign, .plus_assign, .minus_assign, .star_assign, .slash_assign, .percent_assign, .concat, .concat_assign, .arrow, .fat_arrow, .dot, .dotdot, .colon, .comma, .semicolon, .pipe, .pipe_forward, .huh, .bang, .lparen, .rparen, .lbracket, .rbracket, .lsquiggly, .rsquiggly, .attribute => .operator,
            .comment => .comment,
            .doc_comment => .comment,
            .module_doc => .module_doc,
            .ident, .eof => null,
        };
    }

    // i think this does perfect hash but prolly not
    pub const of_string = std.StaticStringMap(TokenType).initComptime(.{
        .{ "const", .kw_const },
        .{ "global", .kw_global },
        .{ "let", .kw_let },

        .{ "comp", .kw_comp },
        .{ "proc", .kw_proc },
        .{ "macro", .kw_macro },
        .{ "test", .kw_test },
        .{ "suite", .kw_suite },
        .{ "skip", .kw_skip },
        .{ "type", .kw_type },
        .{ "fn", .kw_fn },
        .{ "if", .kw_if },
        .{ "unless", .kw_unless },
        .{ "else", .kw_else },
        .{ "match", .kw_match },
        .{ "when", .kw_when },
        .{ "do", .kw_do },
        .{ "end", .kw_end },
        .{ "loop", .kw_loop },
        .{ "for", .kw_for },
        .{ "while", .kw_while },
        .{ "in", .kw_in },
        .{ "break", .kw_break },
        .{ "continue", .kw_continue },
        .{ "return", .kw_return },
        .{ "import", .kw_import },
        .{ "spawn", .kw_spawn },
        .{ "join", .kw_join },
        .{ "yield", .kw_yield },
        .{ "and", .kw_and },
        .{ "or", .kw_or },
        .{ "not", .kw_not },
        .{ "band", .kw_band },
        .{ "bor", .kw_bor },
        .{ "bxor", .kw_bxor },
        .{ "shl", .kw_shl },
        .{ "shr", .kw_shr },
        .{ "orelse", .kw_orelse },
        .{ "pub", .kw_pub },
        .{ "declare", .kw_declare },
    });
};

pub const InterpOpen = struct {
    offset: usize,
    line: u32,
    column: u32,
    idx: usize,
};

/// absolute src pos please
pub const Origin = struct {
    offset: usize = 0,
    line: u32 = 1,
    column: u32 = 1,
};

pub const Token = struct {
    type: TokenType,
    text: []const u8,
    interp_opens: []const InterpOpen = &.{},
    line: u32,
    column: u32,
    start: usize,
    end: usize,

    // mainly for diagnostic use
    pub fn span(self: Token) ast.Span {
        return .{
            .start = self.start,
            .end = self.end,
            .line = self.line,
            .column = self.column,
        };
    }
};

pub fn freeTokenStrings(alloc: std.mem.Allocator, tok: Token) void {
    alloc.free(tok.text);
    alloc.free(tok.interp_opens);
}

pub const testing = struct {
    pub const ExpectedToken = struct {
        t: TokenType,
        v: ?[]const u8 = null,
        interpolation: ?bool = null,
    };

    pub fn expectTokens(source: []const u8, expected: []const ExpectedToken) !void {
        const tokens = try lexAt(std.testing.allocator, source, .{});
        defer {
            for (tokens) |tok| {
                if (tok.type == .string or tok.type == .backtick_string or tok.type == .multiline_string) {
                    freeTokenStrings(std.testing.allocator, tok);
                }
            }
            std.testing.allocator.free(tokens);
        }

        try std.testing.expectEqual(expected.len, tokens.len);
        for (expected, tokens, 0..) |want, got, i| {
            try std.testing.expectEqual(want.t, got.type);
            if (want.v) |text| {
                try std.testing.expectEqualStrings(text, got.text);
            }
            if (want.interpolation) |has| {
                try std.testing.expectEqual(has, got.interp_opens.len > 0);
            }
            _ = i;
        }
    }

    pub fn expectTypes(source: []const u8, expected: []const TokenType) !void {
        const tokens = try lexAt(std.testing.allocator, source, .{});
        defer {
            for (tokens) |tok| {
                if (tok.type == .string or tok.type == .backtick_string or tok.type == .multiline_string) {
                    freeTokenStrings(std.testing.allocator, tok);
                }
            }
            std.testing.allocator.free(tokens);
        }

        try std.testing.expectEqual(expected.len, tokens.len);
        for (expected, tokens) |want, got| {
            try std.testing.expectEqual(want, got.type);
        }
    }
};

// for syntax highlighting
pub const TokenClass = enum {
    keyword,
    string,
    number,
    function,
    variable,
    operator,
    enum_member,
    comment,
    module_doc,
};

/// check if an ident token at `pos` (byte offset right after the ident) is a function call
pub fn identIsFunction(text: []const u8, pos: usize) bool {
    var i = pos;
    while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
    return i < text.len and text[i] == '(';
}

/// like lex but positions are offset by `origin`
pub fn lexAt(allocator: std.mem.Allocator, source: []const u8, origin: Origin) ![]Token {
    var lexer = Lexer.init(source, allocator);
    lexer.base_offset = origin.offset;
    lexer.line = origin.line;
    lexer.column = origin.column;
    var tokens = try std.ArrayList(Token).initCapacity(allocator, 32);
    errdefer tokens.deinit(allocator);

    while (true) {
        const token = try lexer.next();
        try tokens.append(allocator, token);
        if (token.type == .eof) break;
    }

    return tokens.toOwnedSlice(allocator);
}

/// like lexReport but positions are offset by `origin`
pub fn lexReportAt(allocator: std.mem.Allocator, source: []const u8, origin: Origin) !LexResult {
    var lexer = Lexer.init(source, allocator);
    lexer.base_offset = origin.offset;
    lexer.line = origin.line;
    lexer.column = origin.column;
    var tokens = try std.ArrayList(Token).initCapacity(allocator, 32);
    errdefer tokens.deinit(allocator);

    while (true) {
        const token = lexer.next() catch |err| {
            // your lexer obj should always be managed by an arena
            // , and therefore shouldn't take 1000s of cpu cycles up by deallocating
            // but just to be safe,
            tokens.deinit(allocator);
            return .{ .err = lexer.lexFailure(err) };
        };
        try tokens.append(allocator, token);
        if (token.type == .eof) break;
    }

    return .{ .ok = try tokens.toOwnedSlice(allocator) };
}

/// character-at-a-time, no backtracking
const Lexer = @This();

source: []const u8,
alloc: std.mem.Allocator,
/// byte offset in source
pos: usize = 0,
/// added to emitted start/end for fragments
base_offset: usize = 0,
line: u32 = 1,
column: u32 = 1,
/// at start of line (for indent-sensitive tokens)
line_start: bool = true,
/// saved for error recovery
pending_error_span: ?ast.Span = null,
/// set after first non-comment token, rejects late module_doc. kind of a botch
some_seen: bool = false,

pub fn init(source: []const u8, alloc: std.mem.Allocator) Lexer {
    return .{ .source = source, .alloc = alloc };
}

fn next(self: *Lexer) !Token {
    while (!self.atEnd()) {
        const c = self.peek();
        if (std.ascii.isWhitespace(c)) {
            _ = self.advance();
            continue;
        }
        if (c == '#') {
            return try self.lexComment();
        }
        break;
    }

    self.some_seen = true;

    if (self.atEnd()) return self.makeToken(.eof, self.pos, self.pos, 0, 0);

    const start = self.pos;
    const line = self.line;
    const column = self.column;
    const c = self.advance();

    return switch (c) {
        '|' => if (self.matchChar('>'))
            self.makeToken(.pipe_forward, start, self.pos, line, column)
        else
            self.makeToken(.pipe, start, self.pos, line, column),
        '+' => if (self.matchChar('='))
            self.makeToken(.plus_assign, start, self.pos, line, column)
        else
            self.makeToken(.plus, start, self.pos, line, column),
        '-' => if (self.matchChar('='))
            self.makeToken(.minus_assign, start, self.pos, line, column)
        else if (self.matchChar('>'))
            self.makeToken(.arrow, start, self.pos, line, column)
        else
            self.makeToken(.minus, start, self.pos, line, column),
        '*' => if (self.matchChar('='))
            self.makeToken(.star_assign, start, self.pos, line, column)
        else
            self.makeToken(.star, start, self.pos, line, column),
        '/' => if (self.matchChar('='))
            self.makeToken(.slash_assign, start, self.pos, line, column)
        else if (self.matchChar('/'))
            self.makeToken(.slash_slash, start, self.pos, line, column)
        else
            self.makeToken(.slash, start, self.pos, line, column),
        '%' => if (self.matchChar('='))
            self.makeToken(.percent_assign, start, self.pos, line, column)
        else
            self.makeToken(.percent, start, self.pos, line, column),
        '^' => if (self.matchChar('='))
            self.makeToken(.caret_assign, start, self.pos, line, column)
        else
            self.makeToken(.caret, start, self.pos, line, column),
        ':' => if (isIdentStart(self.peek()) or isSymbolAtomStart(self.peek()))
            self.lexHash(start, line, column)
        else
            self.makeToken(.colon, start, self.pos, line, column),
        '=' => if (self.matchChar('='))
            self.makeToken(.eq, start, self.pos, line, column)
        else if (self.matchChar('>'))
            self.makeToken(.fat_arrow, start, self.pos, line, column)
        else
            self.makeToken(.assign, start, self.pos, line, column),
        '!' => if (self.matchChar('='))
            self.makeToken(.neq, start, self.pos, line, column)
        else
            self.makeToken(.bang, start, self.pos, line, column),
        '<' => if (self.matchChar('='))
            self.makeToken(.lte, start, self.pos, line, column)
        else
            self.makeToken(.lt, start, self.pos, line, column),
        '>' => if (self.matchChar('='))
            self.makeToken(.gte, start, self.pos, line, column)
        else
            self.makeToken(.gt, start, self.pos, line, column),
        '"' => if (self.matchTripleQuote())
            self.lexMultilineString(start, line, column)
        else
            self.lexString(start, line, column),
        '\'' => self.lexSingleLineString(start, line, column),
        '`' => self.lexBacktickString(start, line, column),

        '$' => return error.UnexpectedCharacter,
        '@' => if (isIdentStart(self.peek()))
            self.lexAttribute(start, line, column)
        else
            return error.UnexpectedCharacter,
        '(' => self.makeToken(.lparen, start, self.pos, line, column),
        ')' => self.makeToken(.rparen, start, self.pos, line, column),
        '[' => self.makeToken(.lbracket, start, self.pos, line, column),
        ']' => self.makeToken(.rbracket, start, self.pos, line, column),
        '{' => self.makeToken(.lsquiggly, start, self.pos, line, column),
        '}' => self.makeToken(.rsquiggly, start, self.pos, line, column),
        ',' => self.makeToken(.comma, start, self.pos, line, column),
        '.' => if (self.matchChar('.'))
            self.makeToken(.dotdot, start, self.pos, line, column)
        else
            self.makeToken(.dot, start, self.pos, line, column),
        ';' => self.makeToken(.semicolon, start, self.pos, line, column),
        '?' => self.makeToken(.huh, start, self.pos, line, column),
        '~' => if (self.matchChar('='))
            self.makeToken(.concat_assign, start, self.pos, line, column)
        else
            self.makeToken(.concat, start, self.pos, line, column),
        else => {
            if (std.ascii.isDigit(c)) return self.lexNumber(start, line, column);
            if (isIdentStart(c)) return self.lexIdent(start, line, column);
            return error.UnexpectedCharacter;
        },
    };
}

fn lexFailure(self: *const Lexer, err: anyerror) LexError {
    const span = self.pending_error_span orelse self.currentSpan();
    return switch (err) {
        error.UnexpectedCharacter => .{ .kind = .UnexpectedCharacter, .span = span, .message = "unexpected character" },
        error.UnterminatedComment => .{ .kind = .UnterminatedComment, .span = span, .message = "unterminated multiline comment" },
        error.UnterminatedString => .{ .kind = .UnterminatedString, .span = span, .message = "unterminated string" },
        error.LateModuleDoc => .{ .kind = .LateModuleDoc, .span = span, .message = "module doc must be at the start of the file" },
        else => .{ .kind = .Unknown, .span = span, .message = "lexing failed" },
    };
}

fn currentSpan(self: *const Lexer) ast.Span {
    if (self.pos == 0) {
        return .{ .start = self.base_offset, .end = self.base_offset, .line = self.line, .column = self.column };
    }

    const start = self.pos - 1 + self.base_offset;
    return .{ .start = start, .end = self.pos + self.base_offset, .line = self.line, .column = self.column -| 1 };
}

fn atEnd(self: *Lexer) bool {
    return self.pos >= self.source.len;
}

fn peek(self: *Lexer) u8 {
    return if (self.atEnd()) 0 else self.source[self.pos];
}

fn peekN(self: *Lexer, offset: usize) u8 {
    const idx = self.pos + offset;
    return if (idx >= self.source.len) 0 else self.source[idx];
}

fn advance(self: *Lexer) u8 {
    const c = self.source[self.pos];
    self.pos += 1;
    if (c == '\n') {
        self.line += 1;
        self.column = 1;
        self.line_start = true;
    } else {
        self.column += 1;
        if (c != ' ' and c != '\t' and c != '\r') self.line_start = false;
    }
    return c;
}

fn matchChar(self: *Lexer, c: u8) bool {
    if (self.peek() != c) return false;
    _ = self.advance();
    return true;
}

fn matchTripleQuote(self: *Lexer) bool {
    if (self.peek() != '"' or self.peekN(1) != '"') return false;
    _ = self.advance();
    _ = self.advance();
    return true;
}

fn lexComment(self: *Lexer) !Token {
    const start = self.pos;
    const line = self.line;
    const column = self.column;
    _ = self.advance(); // consume first #
    if (self.peek() == '*') {
        _ = self.advance(); // consume *
        var body_start = self.pos;
        self.pending_error_span = .{
            .start = start,
            .end = self.pos,
            .line = line,
            .column = column,
        };
        while (!self.atEnd()) {
            if (self.peek() == '*' and self.peekN(1) == '#') {
                self.pending_error_span = null;
                // body on its own line: drop the leading newline, like
                // multiline strings
                if (body_start < self.pos and self.source[body_start] == '\n') body_start += 1;
                const body_end = self.pos;
                _ = self.advance();
                _ = self.advance();
                return self.makeToken(.doc_comment, body_start, body_end, line, column);
            }
            _ = self.advance();
        }
        return error.UnterminatedComment;
    }
    if (self.peek() == '!') {
        if (self.some_seen) return error.LateModuleDoc;
        _ = self.advance(); // consume !
        var body_start = self.pos;
        while (!self.atEnd()) {
            if (self.peek() == '!' and self.peekN(1) == '#') {
                if (body_start < self.pos and self.source[body_start] == '\n') body_start += 1;
                const body_end = self.pos;
                _ = self.advance();
                _ = self.advance();
                return self.makeToken(.module_doc, body_start, body_end, line, column);
            }
            _ = self.advance();
        }
        return error.UnterminatedComment;
    }
    if (self.peek() == '#') {
        _ = self.advance(); // consume second #
        self.pending_error_span = .{
            .start = start,
            .end = self.pos,
            .line = line,
            .column = column,
        };
        while (!self.atEnd()) {
            if (self.peek() == '#' and self.peekN(1) == '#') {
                _ = self.advance();
                _ = self.advance();
                self.pending_error_span = null;
                return self.makeToken(.comment, start, self.pos, line, column);
            }
            _ = self.advance();
        }
        return error.UnterminatedComment;
    }
    while (!self.atEnd() and self.peek() != '\n') _ = self.advance();
    return self.makeToken(.comment, start, self.pos, line, column);
}

fn lexHash(self: *Lexer, start: usize, line: u32, column: u32) !Token {
    while (isAtomContinue(self.peek())) _ = self.advance();
    return self.makeToken(.hash, start, self.pos, line, column);
}

fn lexNumber(self: *Lexer, start: usize, line: u32, column: u32) Token {
    var base: u8 = 10;

    if (self.source[start] == '0') {
        switch (self.peek()) {
            'x', 'X' => {
                base = 16;
                _ = self.advance();
            },
            'b', 'B' => {
                base = 2;
                _ = self.advance();
            },
            'o', 'O' => {
                base = 8;
                _ = self.advance();
            },
            else => {},
        }
    }

    while (true) {
        const c = self.peek();
        if (std.ascii.isDigit(c) or c == '_') {
            _ = self.advance();
        } else if (base == 16 and std.ascii.isHex(c)) {
            _ = self.advance();
        } else if (c == '.' and self.peekN(1) != '.') {
            _ = self.advance();
        } else if (c == 'e' or c == 'E') {
            if (base != 10) break;
            _ = self.advance();
            if (self.peek() == '+' or self.peek() == '-') _ = self.advance();
        } else if (c == 'p' or c == 'P') {
            if (base != 16) break;
            _ = self.advance();
            if (self.peek() == '+' or self.peek() == '-') _ = self.advance();
        } else {
            break;
        }
    }

    return self.makeToken(.number, start, self.pos, line, column);
}

fn lexString(self: *Lexer, start: usize, line: u32, column: u32) !Token {
    self.pending_error_span = .{ .start = start + self.base_offset, .end = start + 1 + self.base_offset, .line = line, .column = column };
    var buf = try std.ArrayList(u8).initCapacity(self.alloc, 16);
    defer buf.deinit(self.alloc);
    var interp_opens = try std.ArrayList(InterpOpen).initCapacity(self.alloc, 2);
    defer interp_opens.deinit(self.alloc);
    // decoded `"` (from \" escapes) opens a nested string; braces inside it
    // are literal, matching interpolationEnd's quote handling
    var quote: u8 = 0;
    while (!self.atEnd()) {
        const c = self.advance();
        if (c == '\\') {
            if (self.atEnd()) return error.UnterminatedString;
            const from = self.pos - 1;
            var offset = from;
            switch (std.zig.string_literal.parseEscapeSequence(self.source, &offset)) {
                .success => |lit| {
                    while (self.pos < offset) _ = self.advance();
                    var enc: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(lit, &enc) catch return error.UnterminatedString;
                    if (lit == '"') quote = if (quote == 0) '"' else 0;
                    try buf.appendSlice(self.alloc, enc[0..n]);
                },
                .failure => {
                    // `\#{` is the escape for a literal `#{`: the backslash is consumed
                    if (from + 2 < self.source.len and
                        self.source[from + 1] == '#' and self.source[from + 2] == '{')
                    {
                        try buf.appendSlice(self.alloc, "#{");
                        _ = self.advance();
                        _ = self.advance();
                        continue;
                    }
                    try buf.append(self.alloc, '\\');
                    _ = self.advance();
                    try buf.append(self.alloc, self.source[self.pos - 1]);
                },
            }
            continue;
        }
        if (c == '"') {
            self.pending_error_span = null;
            const text = try buf.toOwnedSlice(self.alloc);
            errdefer self.alloc.free(text);
            return .{
                .type = .string,
                .text = text,
                .interp_opens = try interp_opens.toOwnedSlice(self.alloc),
                .line = line,
                .column = column,
                .start = start + self.base_offset,
                .end = self.pos + self.base_offset,
            };
        }
        if (quote != 0) {
            try buf.append(self.alloc, c);
            continue;
        }
        if (c == '#') {
            // `#{` opens an interpolation: record the `{` the way a bare `{`
            // used to be recorded, but keep the `#` out of the decoded text
            if (!self.atEnd() and self.peek() == '{') {
                _ = self.advance();
                try interp_opens.append(self.alloc, .{
                    .offset = self.pos - 1 + self.base_offset,
                    .line = self.line,
                    .column = self.column - 1,
                    .idx = buf.items.len,
                });
                try buf.append(self.alloc, '{');
                continue;
            }
            try buf.append(self.alloc, c);
            continue;
        }
        if (c == '{') {
            if (!self.atEnd() and self.peek() == '{') {
                try buf.append(self.alloc, '{');
                _ = self.advance();
                continue;
            }
        } else if (c == '}') {
            if (!self.atEnd() and self.peek() == '}') {
                try buf.append(self.alloc, '}');
                _ = self.advance();
                continue;
            }
        }
        try buf.append(self.alloc, c);
    }
    return error.UnterminatedString;
}

fn lexSingleLineString(self: *Lexer, start: usize, line: u32, column: u32) !Token {
    self.pending_error_span = .{
        .start = start + self.base_offset,
        .end = start + 1 + self.base_offset,
        .line = line,
        .column = column,
    };
    var buf = try std.ArrayList(u8).initCapacity(self.alloc, 16);
    defer buf.deinit(self.alloc);
    var interp_opens = try std.ArrayList(InterpOpen).initCapacity(self.alloc, 0);
    defer interp_opens.deinit(self.alloc);
    while (!self.atEnd()) {
        const c = self.advance();
        if (c == '\'') {
            const text = try buf.toOwnedSlice(self.alloc);
            self.pending_error_span = null;
            return .{
                .type = .string,
                .text = text,
                .interp_opens = try interp_opens.toOwnedSlice(self.alloc),
                .line = line,
                .column = column,
                .start = start + self.base_offset,
                .end = self.pos + self.base_offset,
            };
        }
        try buf.append(self.alloc, c);
    }
    return error.UnterminatedString;
}

fn lexMultilineString(self: *Lexer, start: usize, line: u32, column: u32) !Token {
    self.pending_error_span = .{ .start = start + self.base_offset, .end = start + 3 + self.base_offset, .line = line, .column = column };
    var buf = try std.ArrayList(u8).initCapacity(self.alloc, 64);
    defer buf.deinit(self.alloc);
    var interp_opens = try std.ArrayList(InterpOpen).initCapacity(self.alloc, 2);
    defer interp_opens.deinit(self.alloc);
    // decoded `"` (from \" escapes) opens a nested string; braces inside it
    // are literal, matching interpolationEnd's quote handling
    var quote: u8 = 0;
    while (!self.atEnd()) {
        if (self.peek() == '"' and self.peekN(1) == '"' and self.peekN(2) == '"') {
            _ = self.advance();
            _ = self.advance();
            _ = self.advance();
            const raw = try buf.toOwnedSlice(self.alloc);
            self.pending_error_span = null;
            const dedent = try dedentMultiline(self.alloc, raw);
            const text = dedent.text;
            defer self.alloc.free(dedent.losses);
            if (dedent.dedented) {
                // dedent shifts decoded positions: the leading \n plus whatever
                // was actually removed from each line. whitespace-only lines
                // shorter than the indent lose fewer chars, so count per line
                // instead of assuming strip every line
                var nl: usize = 0;
                var line_end: usize = 1;
                var removed: usize = 1 + dedent.losses[0];
                for (interp_opens.items) |*open| {
                    while (std.mem.indexOfScalar(u8, raw[line_end..open.idx], '\n')) |nl_pos| {
                        line_end += nl_pos + 1;
                        nl += 1;
                        removed += dedent.losses[nl];
                    }
                    open.idx -|= removed;
                }
            }
            self.alloc.free(raw);
            return .{
                .type = .multiline_string,
                .text = text,
                .interp_opens = try interp_opens.toOwnedSlice(self.alloc),
                .line = line,
                .column = column,
                .start = start + self.base_offset,
                .end = self.pos + self.base_offset,
            };
        }
        const c = self.advance();
        if (c == '\\') {
            if (self.atEnd()) return error.UnterminatedString;
            const from = self.pos - 1;
            var offset = from;
            switch (std.zig.string_literal.parseEscapeSequence(self.source, &offset)) {
                .success => |lit| {
                    while (self.pos < offset) _ = self.advance();
                    var enc: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(lit, &enc) catch return error.UnterminatedString;
                    if (lit == '"') quote = if (quote == 0) '"' else 0;
                    try buf.appendSlice(self.alloc, enc[0..n]);
                },
                .failure => {
                    // `\#{` is the escape for a literal `#{`: the backslash is consumed
                    if (from + 2 < self.source.len and
                        self.source[from + 1] == '#' and self.source[from + 2] == '{')
                    {
                        try buf.appendSlice(self.alloc, "#{");
                        _ = self.advance();
                        _ = self.advance();
                        continue;
                    }
                    try buf.append(self.alloc, '\\');
                    _ = self.advance();
                    try buf.append(self.alloc, self.source[self.pos - 1]);
                },
            }
            continue;
        }
        if (quote != 0) {
            try buf.append(self.alloc, c);
            continue;
        }
        if (c == '#') {
            // `#{` opens an interpolation: record the `{` the way a bare `{`
            // used to be recorded, but keep the `#` out of the decoded text
            if (!self.atEnd() and self.peek() == '{') {
                _ = self.advance();
                try interp_opens.append(self.alloc, .{
                    .offset = self.pos - 1 + self.base_offset,
                    .line = self.line,
                    .column = self.column - 1,
                    .idx = buf.items.len,
                });
                try buf.append(self.alloc, '{');
                continue;
            }
            try buf.append(self.alloc, c);
            continue;
        }
        if (c == '{') {
            if (!self.atEnd() and self.peek() == '{') {
                try buf.append(self.alloc, '{');
                _ = self.advance();
                continue;
            }
        } else if (c == '}') {
            if (!self.atEnd() and self.peek() == '}') {
                try buf.append(self.alloc, '}');
                _ = self.advance();
                continue;
            }
        }
        try buf.append(self.alloc, c);
    }
    return error.UnterminatedString;
}

fn dedentMultiline(alloc: std.mem.Allocator, text: []const u8) !struct {
    text: []u8,
    /// chars removed from each body line (after the leading \n); lines shorter
    /// than the indent lose fewer than strip
    losses: []usize,
    dedented: bool,
} {
    if (text.len == 0 or text[0] != '\n') return .{ .text = try alloc.dupe(u8, text), .losses = &.{}, .dedented = false };

    const body = text[1..];
    var lines = try std.ArrayList([]const u8).initCapacity(alloc, 8);
    defer lines.deinit(alloc);

    var min_indent: ?usize = null;
    var iter = std.mem.splitScalar(u8, body, '\n');
    while (iter.next()) |line| {
        try lines.append(alloc, line);
        if (line.len > 0) {
            var count: usize = 0;
            for (line) |ch| {
                if (ch == ' ' or ch == '\t') {
                    count += 1;
                } else {
                    break;
                }
            }
            if (min_indent) |m| {
                if (count < m) min_indent = count;
            } else {
                min_indent = count;
            }
        }
    }

    const strip = min_indent orelse 0;
    // chars removed per line, tracked before editing: whitespace-only lines
    // shorter than the indent lose fewer than strip
    const losses = try alloc.alloc(usize, lines.items.len);
    for (lines.items, 0..) |line, i| {
        losses[i] = if (line.len > strip) strip else line.len;
    }
    // dedent each line in place
    for (lines.items) |*line| {
        if (line.len > strip) {
            line.* = line.*[strip..];
        } else {
            line.* = "";
        }
    }
    // strip trailing empty lines again after dedent
    while (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) {
        _ = lines.pop();
    }

    var buf = try std.ArrayList(u8).initCapacity(alloc, 64);
    errdefer buf.deinit(alloc);

    for (lines.items, 0..) |line, i| {
        if (i > 0) try buf.append(alloc, '\n');
        try buf.appendSlice(alloc, line);
    }

    return .{ .text = try buf.toOwnedSlice(alloc), .losses = losses, .dedented = true };
}

fn lexBacktickString(self: *Lexer, start: usize, line: u32, column: u32) !Token {
    self.pending_error_span = .{ .start = start + self.base_offset, .end = start + 1 + self.base_offset, .line = line, .column = column };
    var buf = try std.ArrayList(u8).initCapacity(self.alloc, 16);
    defer buf.deinit(self.alloc);
    var interp_opens = try std.ArrayList(InterpOpen).initCapacity(self.alloc, 0);
    defer interp_opens.deinit(self.alloc);
    while (!self.atEnd()) {
        const c = self.advance();
        if (c == '\\') {
            if (self.atEnd()) return error.UnterminatedString;
            if (self.source[self.pos] == '`') {
                _ = self.advance();
                try buf.append(self.alloc, '`');
                continue;
            }
            const from = self.pos - 1;
            var offset = from;
            switch (std.zig.string_literal.parseEscapeSequence(self.source, &offset)) {
                .success => |lit| {
                    while (self.pos < offset) _ = self.advance();
                    var enc: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(lit, &enc) catch return error.UnterminatedString;
                    try buf.appendSlice(self.alloc, enc[0..n]);
                },
                .failure => {
                    try buf.append(self.alloc, '\\');
                    _ = self.advance();
                    try buf.append(self.alloc, self.source[self.pos - 1]);
                },
            }
            continue;
        }
        if (c == '`') {
            const text = try buf.toOwnedSlice(self.alloc);
            errdefer self.alloc.free(text);
            self.pending_error_span = null;
            return .{
                .type = .backtick_string,
                .text = text,
                .interp_opens = try interp_opens.toOwnedSlice(self.alloc),
                .line = line,
                .column = column,
                .start = start + self.base_offset,
                .end = self.pos + self.base_offset,
            };
        }
        try buf.append(self.alloc, c);
    }
    return error.UnterminatedString;
}

fn lexIdent(self: *Lexer, start: usize, line: u32, column: u32) Token {
    while (isIdentContinue(self.peek())) _ = self.advance();
    const text = self.source[start..self.pos];
    const kind = TokenType.of_string.get(text) orelse .ident;
    return .{
        .type = kind,
        .text = text,
        .line = line,
        .column = column,
        .start = start + self.base_offset,
        .end = self.pos + self.base_offset,
    };
}

fn lexAttribute(self: *Lexer, start: usize, line: u32, column: u32) Token {
    while (isIdentContinue(self.peek())) _ = self.advance();
    return self.makeToken(.attribute, start, self.pos, line, column);
}

fn makeToken(self: *Lexer, kind: TokenType, start: usize, end: usize, line: u32, column: u32) Token {
    return .{
        .type = kind,
        .text = self.source[start..end],
        .line = line,
        .column = column,
        .start = start + self.base_offset,
        .end = end + self.base_offset,
    };
}

pub fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

pub fn isIdentContinue(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c) or c == '!' or c == '?';
}

pub fn isSymbolAtomStart(c: u8) bool {
    return switch (c) {
        '-', '+', '*', '/', '=', '<', '>', '.', '@', '$', '~', '^', '?', '!' => true,
        else => false,
    };
}

pub fn isAtomContinue(c: u8) bool {
    return isIdentContinue(c) or isSymbolAtomStart(c);
}

test "lexes calls with sigils and hash literals" {
    try testing.expectTokens("if foo(0) == :WriteDenied bar(1)", &.{
        .{ .t = .kw_if, .v = "if" },
        .{ .t = .ident, .v = "foo" },
        .{ .t = .lparen, .v = "(" },
        .{ .t = .number, .v = "0" },
        .{ .t = .rparen, .v = ")" },
        .{ .t = .eq, .v = "==" },
        .{ .t = .hash, .v = ":WriteDenied" },
        .{ .t = .ident, .v = "bar" },
        .{ .t = .lparen, .v = "(" },
        .{ .t = .number, .v = "1" },
        .{ .t = .rparen, .v = ")" },
        .{ .t = .eof, .v = "" },
    });
}

test "lexes macros and pipe-forward" {
    try testing.expectTokens("macro call_it! `` `@foo(0)` |> print", &.{
        .{ .t = .kw_macro, .v = "macro" },
        .{ .t = .ident, .v = "call_it!" },
        .{ .t = .backtick_string, .v = "" },
        .{ .t = .backtick_string, .v = "@foo(0)" },
        .{ .t = .pipe_forward, .v = "|>" },
        .{ .t = .ident, .v = "print" },
        .{ .t = .eof, .v = "" },
    });
}

test "lexes multiline strings" {
    const allocator = std.testing.allocator;
    const tokens = try lexAt(allocator,
        \\"""hello
        \\world"""
    , .{});
    defer {
        freeTokenStrings(allocator, tokens[0]);
        allocator.free(tokens);
    }

    try std.testing.expectEqual(TokenType.multiline_string, tokens[0].type);
    try std.testing.expectEqualStrings(
        \\hello
        \\world
    , tokens[0].text);
}

test "marks strings containing interpolation" {
    try testing.expectTokens("\"hello #{name}\"", &.{
        .{ .t = .string, .v = "hello {name}", .interpolation = true },
        .{ .t = .eof, .v = "" },
    });
    try testing.expectTokens("\"hello \\#{name}\"", &.{
        .{ .t = .string, .v = "hello #{name}", .interpolation = false },
        .{ .t = .eof, .v = "" },
    });
    try testing.expectTokens("\"hello {name}\"", &.{
        .{ .t = .string, .v = "hello {name}", .interpolation = false },
        .{ .t = .eof, .v = "" },
    });
    try testing.expectTokens("'hello #{name}'", &.{
        .{ .t = .string, .v = "hello #{name}", .interpolation = false },
        .{ .t = .eof, .v = "" },
    });
}

test "lexAt reports absolute positions for fragments" {
    const allocator = std.testing.allocator;
    const tokens = try lexAt(allocator, "\"hi #{name}\"", .{ .offset = 40, .line = 3, .column = 5 });
    defer {
        for (tokens) |tok| {
            if (tok.type == .string or tok.type == .backtick_string or tok.type == .multiline_string) {
                freeTokenStrings(allocator, tok);
            }
        }
        allocator.free(tokens);
    }

    try std.testing.expectEqual(@as(usize, 40), tokens[0].start);
    try std.testing.expectEqual(@as(usize, 52), tokens[0].end);
    try std.testing.expectEqual(@as(u32, 3), tokens[0].line);
    try std.testing.expectEqual(@as(u32, 5), tokens[0].column);
    try std.testing.expectEqual(@as(usize, 1), tokens[0].interp_opens.len);
    const open = tokens[0].interp_opens[0];
    try std.testing.expectEqual(@as(usize, 45), open.offset);
    try std.testing.expectEqual(@as(u32, 3), open.line);
    try std.testing.expectEqual(@as(u32, 10), open.column);
    try std.testing.expectEqual(@as(usize, 3), open.idx);
    try std.testing.expectEqual(@as(usize, 52), tokens[1].start);
}

test "lexes float numbers and range without conflict" {
    try testing.expectTokens("1.25 0..10", &.{
        .{ .t = .number, .v = "1.25" },
        .{ .t = .number, .v = "0" },
        .{ .t = .dotdot, .v = ".." },
        .{ .t = .number, .v = "10" },
        .{ .t = .eof, .v = "" },
    });
}

test "lexes floor division and bitwise keywords" {
    try testing.expectTokens("5 // 2 band bor bxor shl shr", &.{
        .{ .t = .number, .v = "5" },
        .{ .t = .slash_slash, .v = "//" },
        .{ .t = .number, .v = "2" },
        .{ .t = .kw_band, .v = "band" },
        .{ .t = .kw_bor, .v = "bor" },
        .{ .t = .kw_bxor, .v = "bxor" },
        .{ .t = .kw_shl, .v = "shl" },
        .{ .t = .kw_shr, .v = "shr" },
        .{ .t = .eof, .v = "" },
    });
}

test "lexes caret and caret assign" {
    try testing.expectTokens("2 ^ 3 x ^= 4", &.{
        .{ .t = .number, .v = "2" },
        .{ .t = .caret, .v = "^" },
        .{ .t = .number, .v = "3" },
        .{ .t = .ident, .v = "x" },
        .{ .t = .caret_assign, .v = "^=" },
        .{ .t = .number, .v = "4" },
        .{ .t = .eof, .v = "" },
    });
}

const t = @import("testing.zig");
test "lexes match type and text" {
    const source = "match :true | (1 + 1) / (2 * 2) == 4 :good | 1 + 8 == 2 :bad";
    try t.expectTypes(source, &.{ .kw_match, .hash, .pipe, .lparen, .number, .plus, .number, .rparen, .slash, .lparen, .number, .star, .number, .rparen, .eq, .number, .hash, .pipe, .number, .plus, .number, .eq, .number, .hash, .eof });
    try t.expectTokens(source, &.{
        .{ .t = .kw_match, .v = "match" },
        .{ .t = .hash, .v = ":true" },
        .{ .t = .pipe, .v = "|" },
        .{ .t = .lparen, .v = "(" },
        .{ .t = .number, .v = "1" },
        .{ .t = .plus, .v = "+" },
        .{ .t = .number, .v = "1" },
        .{ .t = .rparen, .v = ")" },
        .{ .t = .slash, .v = "/" },
        .{ .t = .lparen, .v = "(" },
        .{ .t = .number, .v = "2" },
        .{ .t = .star, .v = "*" },
        .{ .t = .number, .v = "2" },
        .{ .t = .rparen, .v = ")" },
        .{ .t = .eq, .v = "==" },
        .{ .t = .number, .v = "4" },
        .{ .t = .hash, .v = ":good" },
        .{ .t = .pipe, .v = "|" },
        .{ .t = .number, .v = "1" },
        .{ .t = .plus, .v = "+" },
        .{ .t = .number, .v = "8" },
        .{ .t = .eq, .v = "==" },
        .{ .t = .number, .v = "2" },
        .{ .t = .hash, .v = ":bad" },
        .{ .t = .eof, .v = "" },
    });
}

test "lexes multiline block syntax" {
    try t.expectTypes(
        \\do
        \\    sys.print "hello"
        \\    if peek(idx) == :ok :good else :bad
        \\end
    , &.{
        .kw_do,
        .ident,
        .dot,
        .ident,
        .string,
        .kw_if,
        .ident,
        .lparen,
        .ident,
        .rparen,
        .eq,
        .hash,
        .hash,
        .kw_else,
        .hash,
        .kw_end,
        .eof,
    });
}

test "lexes declarations loop return and import" {
    try t.expectTypes(
        \\do
        \\    const sys = import "sys"
        \\    const pluralise = fn(n) n
        \\    let num: int = loop(x) do return len(consume(idx + 1)) end
        \\end
    , &.{
        .kw_do,
        .kw_const,
        .ident,
        .assign,
        .kw_import,
        .string,
        .kw_const,
        .ident,
        .assign,
        .kw_fn,
        .lparen,
        .ident,
        .rparen,
        .ident,
        .kw_let,
        .ident,
        .colon,
        .ident,
        .assign,
        .kw_loop,
        .lparen,
        .ident,
        .rparen,
        .kw_do,
        .kw_return,
        .ident,
        .lparen,
        .ident,
        .lparen,
        .ident,
        .plus,
        .number,
        .rparen,
        .rparen,
        .kw_end,
        .kw_end,
        .eof,
    });
}

test "lexes fiber keywords" {
    try t.expectTypes(
        \\ spawn join yield
    , &.{
        .kw_spawn,
        .kw_join,
        .kw_yield,
        .eof,
    });
}

test "lexes test keyword" {
    try t.expectTypes(
        \\ test "smoke" do ok? end
    , &.{
        .kw_test,
        .string,
        .kw_do,
        .ident,
        .kw_end,
        .eof,
    });
}

test "lexes macro literals and pipe-forward" {
    try t.expectTypes(
        \\do
        \\    macro dup! `` `@peek(0)`
        \\    |> print
        \\end
    , &.{
        .kw_do,
        .kw_macro,
        .ident,
        .backtick_string,
        .backtick_string,
        .pipe_forward,
        .ident,
        .kw_end,
        .eof,
    });
}

test "lexes function block with multiline string and table" {
    try t.expectTokens(
        \\fn(msg: str) do
        \\    sys.print """hello
        \\world"""
        \\    {message = msg, status = :ok}
        \\end
    , &.{
        .{ .t = .kw_fn, .v = "fn" },
        .{ .t = .lparen, .v = "(" },
        .{ .t = .ident, .v = "msg" },
        .{ .t = .colon, .v = ":" },
        .{ .t = .ident, .v = "str" },
        .{ .t = .rparen, .v = ")" },
        .{ .t = .kw_do, .v = "do" },
        .{ .t = .ident, .v = "sys" },
        .{ .t = .dot, .v = "." },
        .{ .t = .ident, .v = "print" },
        .{ .t = .multiline_string, .v =
        \\hello
        \\world
        },
        .{ .t = .lsquiggly, .v = "{" },
        .{ .t = .ident, .v = "message" },
        .{ .t = .assign, .v = "=" },
        .{ .t = .ident, .v = "msg" },
        .{ .t = .comma, .v = "," },
        .{ .t = .ident, .v = "status" },
        .{ .t = .assign, .v = "=" },
        .{ .t = .hash, .v = ":ok" },
        .{ .t = .rsquiggly, .v = "}" },
        .{ .t = .kw_end, .v = "end" },
        .{ .t = .eof, .v = "" },
    });
}

test "lexes comments" {
    try t.expectTypes(
        \\do # line comment
        \\    ## comment
        \\    adsf
        \\    eeee ##
        \\    let x = 1
        \\end
    , &.{
        .kw_do,
        .comment,
        .comment,
        .kw_let,
        .ident,
        .assign,
        .number,
        .kw_end,
        .eof,
    });
}

test "lexes doc comments, body text between the delimiters" {
    try t.expectTypes(
        \\#* one line doc *# const x = 1
        \\#* multi
        \\   line doc *# fn f() 1
        \\#* a *# #* b *# const y = 2
    , &.{
        .doc_comment,
        .kw_const,
        .ident,
        .assign,
        .number,
        .doc_comment,
        .kw_fn,
        .ident,
        .lparen,
        .rparen,
        .number,
        .doc_comment,
        .doc_comment,
        .kw_const,
        .ident,
        .assign,
        .number,
        .eof,
    });
    const toks = try lexAt(std.testing.allocator, "#* body text *#", .{});
    defer std.testing.allocator.free(toks);
    try std.testing.expectEqualStrings(" body text ", toks[0].text);
}

test "lexes module doc comments" {
    try t.expectTypes(
        \\#! module docs here !#
        \\const x = 1
    , &.{
        .module_doc,
        .kw_const,
        .ident,
        .assign,
        .number,
        .eof,
    });
    {
        const toks = try lexAt(std.testing.allocator, "#! hello !#", .{});
        defer std.testing.allocator.free(toks);
        try std.testing.expectEqualStrings(" hello ", toks[0].text);
    }
    // leading newline is dropped, like multiline strings
    {
        const toks = try lexAt(std.testing.allocator, "#!\n line one\n line two\n!#", .{});
        defer std.testing.allocator.free(toks);
        try std.testing.expectEqualStrings(" line one\n line two\n", toks[0].text);
    }
}

test "rejects module doc after code" {
    try std.testing.expectError(error.LateModuleDoc, lexAt(std.testing.allocator, "const x = 1\n#! too late !#", .{}));
}

test "lexes ident with special symbols" {
    try t.expectTypes(
        \\ one? two!
    , &.{
        .ident,
        .ident,
        .eof,
    });
}

test "lexer reports unterminated strings comments and unexpected characters" {
    try std.testing.expectError(error.UnterminatedString, lexAt(std.testing.allocator, "\"unterminated", .{}));
    try std.testing.expectError(error.UnterminatedComment, lexAt(std.testing.allocator, "## never closed", .{}));
    try std.testing.expectError(error.UnterminatedComment, lexAt(std.testing.allocator, "#* never closed", .{}));
    try std.testing.expectError(error.UnterminatedComment, lexAt(std.testing.allocator, "#! never closed", .{}));
    try std.testing.expectError(error.UnexpectedCharacter, lexAt(std.testing.allocator, "@", .{}));
    {
        const toks = try lexAt(std.testing.allocator, "!", .{});
        defer std.testing.allocator.free(toks);
        try std.testing.expectEqual(TokenType.bang, toks[0].type);
    }
    try std.testing.expectError(error.UnexpectedCharacter, lexAt(std.testing.allocator, "$", .{}));
}

test "token span includes line column start end" {
    const tokens = try lexAt(std.testing.allocator, "const x = 1\nlet y = 2", .{});
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(TokenType.kw_const, tokens[0].type);
    try std.testing.expectEqual(@as(u32, 1), tokens[0].line);
    try std.testing.expectEqual(@as(u32, 1), tokens[0].column);
    try std.testing.expectEqual(@as(usize, 0), tokens[0].start);
    try std.testing.expectEqual(@as(usize, 5), tokens[0].end);

    try std.testing.expectEqual(TokenType.kw_let, tokens[4].type);
    const span = tokens[4].span();
    try std.testing.expectEqual(@as(u32, 2), span.line);
    try std.testing.expectEqual(@as(u32, 1), span.column);
    try std.testing.expectEqual(@as(usize, 12), span.start);
    try std.testing.expectEqual(@as(usize, 15), span.end);
}

test "lexes string with newline escape" {
    const tokens = try lexAt(std.testing.allocator, "\"hello\\nworld\"", .{});
    defer {
        for (tokens) |tok| {
            if (tok.type == .string) freeTokenStrings(std.testing.allocator, tok);
        }
        std.testing.allocator.free(tokens);
    }

    try std.testing.expectEqual(TokenType.string, tokens[0].type);
    try std.testing.expectEqualStrings("hello\nworld", tokens[0].text);
}

test "unterminated string span points at opening quote" {
    const report = try lexReportAt(std.testing.allocator,
        \\  
        \\  "unterminated
    , .{});
    try std.testing.expect(report == .err);
    try std.testing.expect(report == .err);
    try std.testing.expectEqual(LexError.Kind.UnterminatedString, report.err.kind);
    try std.testing.expectEqual(@as(u32, 2), report.err.span.line);
    try std.testing.expectEqual(@as(u32, 3), report.err.span.column);
}

test "unterminated multiline comment span points at opening hashes" {
    const report = try lexReportAt(std.testing.allocator,
        \\  
        \\  ## never closed
    , .{});
    try std.testing.expect(report == .err);
    try std.testing.expect(report == .err);
    try std.testing.expectEqual(LexError.Kind.UnterminatedComment, report.err.kind);
    try std.testing.expectEqual(@as(u32, 2), report.err.span.line);
    try std.testing.expectEqual(@as(u32, 3), report.err.span.column);
}

test "lexes string with tab escape" {
    const tokens = try lexAt(std.testing.allocator, "\"hi\\tworld\"", .{});
    defer {
        for (tokens) |tok| {
            if (tok.type == .string) freeTokenStrings(std.testing.allocator, tok);
        }
        std.testing.allocator.free(tokens);
    }

    try std.testing.expectEqual(TokenType.string, tokens[0].type);
    try std.testing.expectEqualStrings("hi\tworld", tokens[0].text);
}

test "lexes string with backslash escape" {
    const tokens = try lexAt(std.testing.allocator, "\"path\\\\to\\\\file\"", .{});
    defer {
        for (tokens) |tok| {
            if (tok.type == .string) freeTokenStrings(std.testing.allocator, tok);
        }
        std.testing.allocator.free(tokens);
    }

    try std.testing.expectEqual(TokenType.string, tokens[0].type);
    try std.testing.expectEqualStrings("path\\to\\file", tokens[0].text);
}

test "lexes string with quote escape" {
    const tokens = try lexAt(std.testing.allocator, "\"say \\\"hello\\\"\"", .{});
    defer {
        for (tokens) |tok| {
            if (tok.type == .string) freeTokenStrings(std.testing.allocator, tok);
        }
        std.testing.allocator.free(tokens);
    }

    try std.testing.expectEqual(TokenType.string, tokens[0].type);
    try std.testing.expectEqualStrings("say \"hello\"", tokens[0].text);
}

test "lexes string with carriage return escape" {
    const tokens = try lexAt(std.testing.allocator, "\"line1\\rline2\"", .{});
    defer {
        for (tokens) |tok| {
            if (tok.type == .string) freeTokenStrings(std.testing.allocator, tok);
        }
        std.testing.allocator.free(tokens);
    }

    try std.testing.expectEqual(TokenType.string, tokens[0].type);
    try std.testing.expectEqualStrings("line1\rline2", tokens[0].text);
}

test "lexes single quoted string is raw" {
    const tokens = try lexAt(std.testing.allocator, "'hello\\nworld'", .{});
    defer {
        for (tokens) |tok| {
            if (tok.type == .string) freeTokenStrings(std.testing.allocator, tok);
        }
        std.testing.allocator.free(tokens);
    }

    try std.testing.expectEqual(TokenType.string, tokens[0].type);
    try std.testing.expectEqualStrings("hello\\nworld", tokens[0].text);
}

test "lexes backtick string with escapes" {
    const tokens = try lexAt(std.testing.allocator, "`hello\\nworld`", .{});
    defer {
        for (tokens) |tok| {
            if (tok.type == .backtick_string) freeTokenStrings(std.testing.allocator, tok);
        }
        std.testing.allocator.free(tokens);
    }

    try std.testing.expectEqual(TokenType.backtick_string, tokens[0].type);
    try std.testing.expectEqualStrings("hello\nworld", tokens[0].text);
}

test "lexes backtick string with backtick escape" {
    const tokens = try lexAt(std.testing.allocator, "`say \\`hi\\``", .{});
    defer {
        for (tokens) |tok| {
            if (tok.type == .backtick_string) freeTokenStrings(std.testing.allocator, tok);
        }
        std.testing.allocator.free(tokens);
    }

    try std.testing.expectEqual(TokenType.backtick_string, tokens[0].type);
    try std.testing.expectEqualStrings("say `hi`", tokens[0].text);
}

test "lexes string with unknown escape passed through" {
    const tokens = try lexAt(std.testing.allocator, "\"hello\\qworld\"", .{});
    defer {
        for (tokens) |tok| {
            if (tok.type == .string) freeTokenStrings(std.testing.allocator, tok);
        }
        std.testing.allocator.free(tokens);
    }

    try std.testing.expectEqual(TokenType.string, tokens[0].type);
    try std.testing.expectEqualStrings("hello\\qworld", tokens[0].text);
}

test "lexes pub keyword" {
    try testing.expectTypes("pub const x = 1", &.{ .kw_pub, .kw_const, .ident, .assign, .number, .eof });
}

test "lexes declare keyword" {
    try testing.expectTypes(
        "declare ring = fn(volume: number, label: string) -> bool",
        &.{
            .kw_declare, .ident,  .assign, .kw_fn, .lparen, .ident, .colon, .ident, .comma, .ident, .colon,
            .ident,      .rparen, .arrow,  .ident, .eof,
        },
    );
}
