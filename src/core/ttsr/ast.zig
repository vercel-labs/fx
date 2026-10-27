//! Structural patterns for `ast:` conditions, as a token-tree subset of
//! ast-grep.
//!
//! proto hands `ast:` patterns to ast-grep's tree-sitter grammars. proto-fx
//! ships no grammars, so a pattern here is matched over tokens instead:
//! comments and whitespace are trivia, a string literal is one token, and
//! brackets nest. A metavariable `$X` binds one expression: one or more
//! tokens and bracket groups, never crossing `,` `;` or an unbalanced
//! closer. A repeat of `$X` must bind the same text. `$$$X` binds zero or
//! more of anything balanced, and `$_` binds without a name. `where:`
//! constraints test a binding's text with a regex.
//!
//! The one `selector` understood is `predefined_type`: the pattern's
//! built-in TypeScript type keyword, matched only where a type is written
//! (after `:`, `as`, `<`, `|`, `&`, `extends`, `satisfies` or `keyof`).
//! `strictness` is accepted and has no effect.
const std = @import("std");
const regions = @import("regions.zig");
const regex = @import("regex.zig");

const Allocator = std.mem.Allocator;

pub const Token = struct {
    start: usize,
    end: usize,
    kind: Kind,

    pub const Kind = enum { word, string, punct, open, close };
};

pub const PatternToken = union(enum) {
    literal: []const u8,
    /// Empty name for `$_`.
    single: []const u8,
    multi: []const u8,
    open: u8,
    close: u8,
};

pub const Selector = enum { none, predefined_type };

pub const Pattern = struct {
    tokens: []const PatternToken,
};

pub const Constraint = struct {
    name: []const u8,
    regex: ?*const regex.Regex = null,
    not_regex: ?*const regex.Regex = null,
};

pub const Hit = struct { start: usize, end: usize };

const operators = [_][]const u8{
    "...", "===", "!==", "**=", "<<=", "=>", "==", "!=", "<=", ">=", "&&", "||", "??", "?.", "::", "->", ":=", "++", "--", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<",
};

const predefined_types = [_][]const u8{ "any", "unknown", "string", "number", "boolean", "bigint", "symbol", "object", "never", "void", "undefined", "null" };

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$' or c >= 0x80;
}

/// Tokens of `text`, skipping comments; `profile_lang` picks the comment
/// and string syntax. Caller owns the slice.
pub fn tokenize(alloc: Allocator, text: []const u8, lang: []const u8) ![]Token {
    const mode = regions.modeFor(.tool, lang) orelse return error.UnsupportedLanguage;
    if (mode == .prose) return error.UnsupportedLanguage;
    const classified = try regions.classify(alloc, text, mode);
    defer alloc.free(classified);
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(alloc);
    var index: usize = 0;
    var region_index: usize = 0;
    while (index < text.len) {
        while (region_index < classified.len and classified[region_index].end <= index) region_index += 1;
        if (region_index < classified.len and classified[region_index].start <= index) {
            const region = classified[region_index];
            if (region.kind == .string) try tokens.append(alloc, .{ .start = region.start, .end = region.end, .kind = .string });
            index = region.end;
            continue;
        }
        const limit = if (region_index < classified.len) classified[region_index].start else text.len;
        index = try scanToken(alloc, &tokens, text, index, limit);
    }
    return tokens.toOwnedSlice(alloc);
}

fn scanToken(alloc: Allocator, tokens: *std.ArrayList(Token), text: []const u8, index: usize, limit: usize) !usize {
    const c = text[index];
    if (std.ascii.isWhitespace(c)) return index + 1;
    if (isWordByte(c)) {
        var end = index + 1;
        while (end < limit and isWordByte(text[end])) end += 1;
        try tokens.append(alloc, .{ .start = index, .end = end, .kind = .word });
        return end;
    }
    switch (c) {
        '(', '[', '{' => {
            try tokens.append(alloc, .{ .start = index, .end = index + 1, .kind = .open });
            return index + 1;
        },
        ')', ']', '}' => {
            try tokens.append(alloc, .{ .start = index, .end = index + 1, .kind = .close });
            return index + 1;
        },
        else => {},
    }
    for (operators) |op| {
        if (index + op.len <= limit and std.mem.eql(u8, text[index .. index + op.len], op)) {
            try tokens.append(alloc, .{ .start = index, .end = index + op.len, .kind = .punct });
            return index + op.len;
        }
    }
    try tokens.append(alloc, .{ .start = index, .end = index + 1, .kind = .punct });
    return index + 1;
}

/// Compiles one pattern. Memory comes from `arena`.
pub fn compilePattern(arena: Allocator, source: []const u8) !Pattern {
    var out: std.ArrayList(PatternToken) = .empty;
    var index: usize = 0;
    while (index < source.len) {
        const c = source[index];
        if (std.ascii.isWhitespace(c)) {
            index += 1;
            continue;
        }
        if (c == '"' or c == '\'' or c == '`') {
            var end = index + 1;
            while (end < source.len and source[end] != c) : (end += 1) {
                if (source[end] == '\\') end += 1;
            }
            end = @min(end + 1, source.len);
            try out.append(arena, .{ .literal = source[index..end] });
            index = end;
            continue;
        }
        if (isWordByte(c)) {
            var end = index + 1;
            while (end < source.len and isWordByte(source[end])) end += 1;
            const word = source[index..end];
            try out.append(arena, metaToken(word) orelse PatternToken{ .literal = word });
            index = end;
            continue;
        }
        switch (c) {
            '(', '[', '{' => {
                try out.append(arena, .{ .open = c });
                index += 1;
                continue;
            },
            ')', ']', '}' => {
                try out.append(arena, .{ .close = c });
                index += 1;
                continue;
            },
            else => {},
        }
        var len: usize = 1;
        for (operators) |op| {
            if (std.mem.startsWith(u8, source[index..], op)) {
                len = op.len;
                break;
            }
        }
        try out.append(arena, .{ .literal = source[index .. index + len] });
        index += len;
    }
    if (out.items.len == 0) return error.EmptyPattern;
    return .{ .tokens = try out.toOwnedSlice(arena) };
}

fn metaToken(word: []const u8) ?PatternToken {
    if (std.mem.startsWith(u8, word, "$$$")) {
        const name = word[3..];
        for (name) |c| if (!(std.ascii.isUpper(c) or std.ascii.isDigit(c) or c == '_')) return null;
        return .{ .multi = name };
    }
    if (word.len < 2 or word[0] != '$') return null;
    const name = word[1..];
    if (!(std.ascii.isUpper(name[0]) or name[0] == '_')) return null;
    for (name) |c| if (!(std.ascii.isUpper(c) or std.ascii.isDigit(c) or c == '_')) return null;
    return .{ .single = if (std.mem.eql(u8, name, "_")) "" else name };
}

/// The literal words of a pattern, for the literal prefilter.
pub fn longestLiteral(pattern: Pattern) ?[]const u8 {
    var best: ?[]const u8 = null;
    for (pattern.tokens) |token| switch (token) {
        .literal => |text| if (text.len >= 3 and isWordByte(text[0]) and (best == null or text.len > best.?.len)) {
            best = text;
        },
        else => {},
    };
    return best;
}

const Binding = struct { name: []const u8, start: usize, end: usize };

pub const Matcher = struct {
    text: []const u8,
    tokens: []const Token,
    bindings: [16]Binding = undefined,
    bound: usize = 0,
    steps: usize = 0,

    /// Every match of `pattern`, up to `max`, honoring `where`.
    pub fn findAll(self: *Matcher, alloc: Allocator, pattern: Pattern, selector: Selector, where: []const Constraint, max: usize) ![]Hit {
        var hits: std.ArrayList(Hit) = .empty;
        errdefer hits.deinit(alloc);
        if (selector == .predefined_type) {
            try self.predefinedTypes(alloc, &hits, pattern, max);
            return hits.toOwnedSlice(alloc);
        }
        var start: usize = 0;
        while (start < self.tokens.len and hits.items.len < max) : (start += 1) {
            self.bound = 0;
            self.steps = 0;
            const end = self.match(pattern.tokens, 0, start, where) orelse continue;
            if (end == start) continue;
            try hits.append(alloc, .{ .start = self.tokens[start].start, .end = self.tokens[end - 1].end });
        }
        return hits.toOwnedSlice(alloc);
    }

    fn predefinedTypes(self: *Matcher, alloc: Allocator, hits: *std.ArrayList(Hit), pattern: Pattern, max: usize) !void {
        var keyword: ?[]const u8 = null;
        for (pattern.tokens) |token| switch (token) {
            .literal => |text| for (predefined_types) |name| {
                if (std.mem.eql(u8, name, text)) keyword = text;
            },
            else => {},
        };
        const wanted = keyword orelse return;
        for (self.tokens, 0..) |token, index| {
            if (hits.items.len >= max) return;
            if (token.kind != .word or !std.mem.eql(u8, self.text[token.start..token.end], wanted) or index == 0) continue;
            const prev = self.text[self.tokens[index - 1].start..self.tokens[index - 1].end];
            const type_position = for ([_][]const u8{ ":", "as", "<", "|", "&", "extends", "satisfies", "keyof" }) |marker| {
                if (std.mem.eql(u8, prev, marker)) break true;
            } else false;
            if (type_position) try hits.append(alloc, .{ .start = token.start, .end = token.end });
        }
    }

    fn tokenText(self: *const Matcher, index: usize) []const u8 {
        const token = self.tokens[index];
        return self.text[token.start..token.end];
    }

    /// The end (exclusive token index) of a match of `pattern[pi..]` at
    /// token `ti`, or null.
    fn match(self: *Matcher, pattern: []const PatternToken, pi: usize, ti: usize, where: []const Constraint) ?usize {
        self.steps += 1;
        if (self.steps > 20_000) return null;
        if (pi == pattern.len) return ti;
        switch (pattern[pi]) {
            .literal => |text| {
                if (ti >= self.tokens.len or !std.mem.eql(u8, self.tokenText(ti), text)) return null;
                return self.match(pattern, pi + 1, ti + 1, where);
            },
            .open => |c| {
                if (ti >= self.tokens.len or self.tokens[ti].kind != .open or self.tokenText(ti)[0] != c) return null;
                return self.match(pattern, pi + 1, ti + 1, where);
            },
            .close => |c| {
                if (ti >= self.tokens.len or self.tokens[ti].kind != .close or self.tokenText(ti)[0] != c) return null;
                return self.match(pattern, pi + 1, ti + 1, where);
            },
            .single, .multi => {
                const multi = pattern[pi] == .multi;
                const name = switch (pattern[pi]) {
                    .single => |n| n,
                    .multi => |n| n,
                    else => unreachable,
                };
                if (name.len > 0 and !multi) if (self.lookup(name)) |previous| {
                    return self.matchSame(pattern, pi, ti, previous, where);
                };
                var end = ti;
                var units: usize = 0;
                if (multi) {
                    if (self.tryBind(pattern, pi, name, ti, ti, where)) |result| return result;
                }
                while (units < 256) {
                    end = self.unitEnd(end, multi) orelse return null;
                    units += 1;
                    if (self.tryBind(pattern, pi, name, ti, end, where)) |result| return result;
                }
                return null;
            },
        }
    }

    fn tryBind(self: *Matcher, pattern: []const PatternToken, pi: usize, name: []const u8, from: usize, to: usize, where: []const Constraint) ?usize {
        const saved = self.bound;
        if (name.len > 0) {
            if (self.bound == self.bindings.len) return null;
            const span = self.spanOf(from, to);
            for (where) |constraint| {
                if (!std.mem.eql(u8, constraint.name, name)) continue;
                const value = self.text[span.start..span.end];
                if (constraint.regex) |re| if (!re.isMatch(value)) return null;
                if (constraint.not_regex) |re| if (re.isMatch(value)) return null;
            }
            self.bindings[self.bound] = .{ .name = name, .start = span.start, .end = span.end };
            self.bound += 1;
        }
        if (self.match(pattern, pi + 1, to, where)) |result| return result;
        self.bound = saved;
        return null;
    }

    fn spanOf(self: *const Matcher, from: usize, to: usize) Hit {
        if (from == to) {
            const at = if (from < self.tokens.len) self.tokens[from].start else self.text.len;
            return .{ .start = at, .end = at };
        }
        return .{ .start = self.tokens[from].start, .end = self.tokens[to - 1].end };
    }

    fn lookup(self: *const Matcher, name: []const u8) ?Binding {
        var index = self.bound;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.bindings[index].name, name)) return self.bindings[index];
        }
        return null;
    }

    /// A repeated metavariable matches tokens whose text equals the first.
    fn matchSame(self: *Matcher, pattern: []const PatternToken, pi: usize, ti: usize, previous: Binding, where: []const Constraint) ?usize {
        const want = self.text[previous.start..previous.end];
        var end = ti;
        while (end < self.tokens.len) {
            end = self.unitEnd(end, false) orelse return null;
            const span = self.spanOf(ti, end);
            const got = self.text[span.start..span.end];
            if (got.len > want.len + 64) return null;
            if (equalIgnoringSpace(got, want)) return self.match(pattern, pi + 1, end, where);
        }
        return null;
    }

    /// The end of one unit starting at token `ti`: a token or a balanced
    /// bracket group. Separators end a single binding.
    fn unitEnd(self: *const Matcher, ti: usize, multi: bool) ?usize {
        if (ti >= self.tokens.len) return null;
        const token = self.tokens[ti];
        switch (token.kind) {
            .close => return null,
            .open => {
                var depth: usize = 0;
                var index = ti;
                while (index < self.tokens.len) : (index += 1) {
                    switch (self.tokens[index].kind) {
                        .open => depth += 1,
                        .close => {
                            depth -= 1;
                            if (depth == 0) return index + 1;
                        },
                        else => {},
                    }
                }
                return null;
            },
            .punct => {
                if (!multi) {
                    const text = self.tokenText(ti);
                    if (std.mem.eql(u8, text, ";") or std.mem.eql(u8, text, ",")) return null;
                }
                return ti + 1;
            },
            else => return ti + 1,
        }
    }
};

fn equalIgnoringSpace(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < a.len and std.ascii.isWhitespace(a[i])) i += 1;
        while (j < b.len and std.ascii.isWhitespace(b[j])) j += 1;
        if (i == a.len or j == b.len) return i == a.len and j == b.len;
        if (a[i] != b[j]) return false;
        i += 1;
        j += 1;
    }
}

fn expectHits(source: []const u8, lang: []const u8, pattern_source: []const u8, selector: Selector, where: []const Constraint, expected: []const []const u8) !void {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const pattern = try compilePattern(arena_state.allocator(), pattern_source);
    const tokens = try tokenize(alloc, source, lang);
    defer alloc.free(tokens);
    var matcher: Matcher = .{ .text = source, .tokens = tokens };
    const hits = try matcher.findAll(alloc, pattern, selector, where, 64);
    defer alloc.free(hits);
    try std.testing.expectEqual(expected.len, hits.len);
    for (expected, hits) |want, hit| try std.testing.expectEqualStrings(want, source[hit.start..hit.end]);
}

test "ast patterns match token trees with metavariables" {
    try expectHits(
        "for i := 0; i < n; i++ {\n  sum += i // for j := 0; j < n; j++ {}\n}\nfor k := 1; k < n; k++ {}",
        "go",
        "for $I := 0; $I < $N; $I++ { $$$BODY }",
        .none,
        &.{},
        &.{"for i := 0; i < n; i++ {\n  sum += i // for j := 0; j < n; j++ {}\n}"},
    );
    try expectHits("if (this.t) clearTimeout(this.t);\nif (a) clearTimeout(b);", "ts", "if ($X) clearTimeout($X)", .none, &.{}, &.{"if (this.t) clearTimeout(this.t)"});
    try expectHits("const v = (x as { a: number }).a;", "ts", "($X as { $$$BODY }).$PROP", .none, &.{}, &.{"(x as { a: number }).a"});
    try expectHits("func ptr(v int) *int { return &v }", "go", "func $F($V $T) *$T { return &$V }", .none, &.{}, &.{"func ptr(v int) *int { return &v }"});
    try expectHits("f(\"x as any\") // x as any", "ts", "x as any", .none, &.{}, &.{});
}

test "ast where constraints and the predefined type selector" {
    var underscore = try regex.compile(std.testing.allocator, "^_");
    defer underscore.deinit();
    const where = [_]Constraint{.{ .name = "E", .regex = &underscore }};
    try expectHits("try { a() } catch (_e) { b() }\ntry { c() } catch (err) { d() }", "ts", "try { $$$BODY } catch ($E) { $$$HANDLER }", .none, &where, &.{"try { a() } catch (_e) { b() }"});
    try expectHits("let a: any = x as any; const any = 1; // : any\nfoo.any", "ts", "let x: any", .predefined_type, &.{}, &.{ "any", "any" });
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("clearTimeout", longestLiteral(try compilePattern(arena_state.allocator(), "if ($X) clearTimeout($X)")).?);
}
