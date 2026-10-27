//! Evaluates a compiled `match:` program against one buffer.
//!
//! Three-valued like proto: a leaf that cannot settle yet reports unknown,
//! and an unknown verdict never fires a rule. `ast:` leaves settle only on a
//! settled buffer (a finished tool call), since a streaming prefix is
//! partial source; `llm:` leaves settle only on a settled buffer with a
//! judge, and settle as no match on a settled buffer without one.
//! Evaluation returns the spans that survived, so a firing rule can quote
//! the lines that tripped it.
const std = @import("std");
const matcher = @import("matcher.zig");
const regions = @import("regions.zig");
const ast = @import("ast.zig");
const paths = @import("paths.zig");
const shell_code = @import("shell_code.zig");

const Allocator = std.mem.Allocator;
const Node = matcher.Node;

pub const Source = regions.Source;

pub const Span = struct { start: usize, end: usize };

pub const Snippet = struct { line: usize, text: []const u8 };

pub const Evidence = struct { snippets: []const Snippet };

/// One tool call the session already made, as `did:` sees it.
pub const ToolCallRecord = struct {
    name: []const u8,
    paths: []const []const u8 = &.{},
    args: ?[]const u8 = null,
};

pub const JudgeRequest = struct {
    question: []const u8,
    /// Model roles to try in order.
    roles: []const []const u8,
    text: []const u8,
    source: regions.Source,
    lang: ?[]const u8,
    tool_name: ?[]const u8,
    file_paths: []const []const u8,
};

/// Answers `llm:` leaves; null means it could not answer, which counts as
/// no match.
pub const Judge = struct {
    ctx: *anyopaque,
    ask: *const fn (ctx: *anyopaque, request: JudgeRequest) ?bool,
};

pub const Input = struct {
    text: []const u8,
    source: regions.Source,
    /// Overrides the language derived from `file_paths`.
    lang: ?[]const u8 = null,
    file_paths: []const []const u8 = &.{},
    tool_name: ?[]const u8 = null,
    cwd: []const u8 = "/",
    home: ?[]const u8 = null,
    history: []const ToolCallRecord = &.{},
    judge: ?Judge = null,
    /// The buffer is final: `ast:` and `llm:` leaves may settle.
    settled: bool = false,
};

const max_regex_spans = 256;
const max_ast_matches = 64;
const max_snippets = 3;
const max_snippet_bytes = 200;

const Result = struct {
    matched: bool,
    unknown: bool = false,
    spans: []const Span = &.{},
};

const unmatched: Result = .{ .matched = false };
const unknown: Result = .{ .matched = false, .unknown = true };

/// Per-buffer state shared by every rule evaluated against it: regions,
/// tokens, resolved targets and judge verdicts are computed once.
pub const Context = struct {
    arena: Allocator,
    input: Input,
    lang_buf: [16]u8 = undefined,
    lang: ?[]const u8 = null,
    lang_resolved: bool = false,
    region_list: ?[]const regions.Region = null,
    region_mode: ?regions.Mode = null,
    regions_resolved: bool = false,
    tokens: ?[]const ast.Token = null,
    tokens_resolved: bool = false,
    targets: ?[]const paths.Target = null,
    verdicts: std.AutoHashMapUnmanaged(*const Node, bool) = .empty,
    shell_scan: ?shell_code.Scan = null,

    pub fn init(arena: Allocator, input: Input) Context {
        return .{ .arena = arena, .input = input };
    }

    pub fn language(self: *Context) ?[]const u8 {
        if (!self.lang_resolved) {
            self.lang_resolved = true;
            self.lang = if (self.input.lang) |l| l else paths.deriveLang(&self.lang_buf, self.input.file_paths);
        }
        return self.lang;
    }

    fn resolvedRegions(self: *Context) !?[]const regions.Region {
        if (!self.regions_resolved) {
            self.regions_resolved = true;
            self.region_mode = regions.modeFor(self.input.source, self.language());
            if (self.region_mode) |mode| self.region_list = try regions.classify(self.arena, self.input.text, mode);
        }
        return self.region_list;
    }

    fn resolvedTargets(self: *Context) ![]const paths.Target {
        if (self.targets == null) self.targets = try paths.resolveTargets(self.arena, self.input.file_paths, self.input.cwd, self.input.home);
        return self.targets.?;
    }

    fn resolvedTokens(self: *Context) !?[]const ast.Token {
        if (!self.tokens_resolved) {
            self.tokens_resolved = true;
            const lang = self.language() orelse return null;
            self.tokens = ast.tokenize(self.arena, self.input.text, lang) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
        }
        return self.tokens;
    }
};

/// The evidence when `program` fires on the context's buffer, else null.
pub fn evaluate(program: matcher.Program, ctx: *Context) !?Evidence {
    const result = try node(program.root, ctx);
    if (!result.matched or result.unknown) return null;
    return .{ .snippets = try snippetsFor(ctx, result.spans) };
}

fn node(n: *const Node, ctx: *Context) error{OutOfMemory}!Result {
    switch (n.kind) {
        .regex => return finish(n, try regexSpans(n, ctx), ctx),
        .shell => |leaf| {
            const lang = ctx.language() orelse return unmatched;
            if (!std.mem.eql(u8, lang, "bash") and !std.mem.eql(u8, lang, "sh") and !std.mem.eql(u8, lang, "zsh")) return unmatched;
            if (ctx.shell_scan == null) ctx.shell_scan = try shell_code.scan(ctx.arena, ctx.input.text);
            var spans: std.ArrayList(Span) = .empty;
            for (ctx.shell_scan.?.cells) |cell| {
                if (cell.language == leaf.language and cell.kernel == leaf.kernel) try spans.append(ctx.arena, .{ .start = cell.start, .end = cell.end });
            }
            return finish(n, spans.items, ctx);
        },
        .ast => {
            if (!ctx.input.settled) return unknown;
            const spans = try astSpans(n, ctx) orelse return unmatched;
            return finish(n, spans, ctx);
        },
        .lang => |langs| {
            const lang = ctx.language() orelse return unmatched;
            for (langs) |want| if (std.ascii.eqlIgnoreCase(want, lang)) return .{ .matched = true };
            return unmatched;
        },
        .path => |predicate| return .{ .matched = try matchesPathTargets(predicate, try ctx.resolvedTargets(), ctx) },
        .did => |did| return .{ .matched = try matchesDid(did, ctx) },
        .llm => |leaf| {
            if (ctx.verdicts.get(n)) |verdict| return .{ .matched = verdict };
            if (!ctx.input.settled) return unknown;
            const verdict = if (ctx.input.judge) |judge| judge.ask(judge.ctx, .{
                .question = leaf.question,
                .roles = leaf.roles,
                .text = ctx.input.text,
                .source = ctx.input.source,
                .lang = ctx.language(),
                .tool_name = ctx.input.tool_name,
                .file_paths = ctx.input.file_paths,
            }) orelse false else false;
            try ctx.verdicts.put(ctx.arena, n, verdict);
            return .{ .matched = verdict };
        },
        .not => |child| {
            const result = try node(child, ctx);
            if (result.unknown) return unknown;
            return .{ .matched = !result.matched };
        },
        .@"if" => |branch| {
            const guard = try node(branch.guard, ctx);
            if (guard.unknown) return unknown;
            const chosen = if (guard.matched) branch.then else branch.@"else" orelse return unmatched;
            const result = try node(chosen, ctx);
            if (result.unknown) return unknown;
            return if (result.matched) finish(n, result.spans, ctx) else unmatched;
        },
        .all => |children| {
            var spans: std.ArrayList(Span) = .empty;
            var saw_unknown = false;
            for (children) |child| {
                const result = try node(child, ctx);
                if (result.unknown) {
                    saw_unknown = true;
                    continue;
                }
                if (!result.matched) return unmatched;
                try spans.appendSlice(ctx.arena, result.spans);
            }
            return if (saw_unknown) unknown else finish(n, spans.items, ctx);
        },
        .any => |children| {
            var spans: std.ArrayList(Span) = .empty;
            var matched = false;
            var saw_unknown = false;
            for (children) |child| {
                // Decided already; a judge could only add evidence.
                if (matched and child.cost >= matcher.cost_judge) continue;
                const result = try node(child, ctx);
                if (result.unknown) {
                    saw_unknown = true;
                    continue;
                }
                if (!result.matched) continue;
                matched = true;
                try spans.appendSlice(ctx.arena, result.spans);
            }
            if (matched) return finish(n, spans.items, ctx);
            return if (saw_unknown) unknown else unmatched;
        },
    }
}

fn finish(n: *const Node, spans: []const Span, ctx: *Context) !Result {
    if (spans.len == 0) {
        // A group or branch of context tests matches without evidence.
        const context_only = switch (n.kind) {
            .all, .any, .@"if" => n.count == 1,
            else => false,
        };
        return if (context_only) .{ .matched = true } else unmatched;
    }
    var filtered = spans;
    inline for (.{ .{ "inside", true, true }, .{ "not_inside", true, false }, .{ "has", false, true }, .{ "not_has", false, false } }) |entry| {
        if (@field(n, entry[0])) |child| {
            const result = try node(child, ctx);
            if (result.unknown) return unknown;
            var kept: std.ArrayList(Span) = .empty;
            for (filtered) |span| {
                var hit = false;
                for (result.spans) |other| {
                    const contained = if (entry[1])
                        other.start <= span.start and other.end >= span.end
                    else
                        span.start <= other.start and span.end >= other.end;
                    if (contained) {
                        hit = true;
                        break;
                    }
                }
                if (hit == entry[2]) try kept.append(ctx.arena, span);
            }
            filtered = kept.items;
        }
    }
    return if (filtered.len >= n.count) .{ .matched = true, .spans = filtered } else unmatched;
}

fn regexSpans(n: *const Node, ctx: *Context) ![]const Span {
    const leaf = n.kind.regex;
    const text = ctx.input.text;
    var spans: std.ArrayList(Span) = .empty;
    for (leaf.patterns) |pattern| {
        var from: usize = 0;
        while (spans.items.len < max_regex_spans and from <= text.len) {
            const found = pattern.find(text, from) orelse break;
            const end = @min(if (found.end > found.start) found.end else found.start + 1, text.len);
            try spans.append(ctx.arena, .{ .start = found.start, .end = end });
            from = if (found.end > found.start) found.end else found.start + 1;
        }
    }
    const wanted = leaf.regions orelse return spans.items;
    // Fail closed: an unclassifiable buffer cannot prove its region.
    const classified = try ctx.resolvedRegions() orelse return &.{};
    const fallback: regions.Kind = if (ctx.region_mode.? == .prose) .prose else .code;
    var kept: std.ArrayList(Span) = .empty;
    for (spans.items) |span| {
        const kind = regions.spanKind(classified, span.start, span.end, fallback) orelse continue;
        if (std.mem.findScalar(regions.Kind, wanted, kind) != null) try kept.append(ctx.arena, span);
    }
    return kept.items;
}

fn astSpans(n: *const Node, ctx: *Context) !?[]const Span {
    const leaf = n.kind.ast;
    const tokens = try ctx.resolvedTokens() orelse return null;
    var spans: std.ArrayList(Span) = .empty;
    var m: ast.Matcher = .{ .text = ctx.input.text, .tokens = tokens };
    for (leaf.patterns) |pattern| {
        const hits = try m.findAll(ctx.arena, pattern, leaf.selector, leaf.where, max_ast_matches);
        for (hits) |hit| try spans.append(ctx.arena, .{ .start = hit.start, .end = hit.end });
    }
    return spans.items;
}

fn matchesPathTargets(predicate: matcher.PathPredicate, targets: []const paths.Target, ctx: *Context) !bool {
    for (targets) |target| {
        if (predicate.globs.len > 0) {
            const hit = for (predicate.globs) |glob| {
                if (paths.matchesTarget(glob, target)) break true;
            } else false;
            if (!hit) continue;
        }
        if (predicate.patterns.len > 0) {
            const hit = for (predicate.patterns) |pattern| {
                if (pattern.isMatch(target.raw)) break true;
                if (target.relative) |r| if (pattern.isMatch(r)) break true;
                if (target.absolute) |a| if (pattern.isMatch(a)) break true;
            } else false;
            if (!hit) continue;
        }
        if (predicate.under.len > 0 or predicate.outside.len > 0) {
            // Scheme URIs have no filesystem location.
            const absolute = target.absolute orelse continue;
            if (predicate.under.len > 0) {
                var inside = false;
                for (predicate.under) |root| {
                    if (paths.isUnderRoot(absolute, try paths.resolveRoot(ctx.arena, root, ctx.input.cwd, ctx.input.home))) inside = true;
                }
                if (!inside) continue;
            }
            var escaped = true;
            for (predicate.outside) |root| {
                if (paths.isUnderRoot(absolute, try paths.resolveRoot(ctx.arena, root, ctx.input.cwd, ctx.input.home))) escaped = false;
            }
            if (!escaped) continue;
        }
        return true;
    }
    return false;
}

/// A host with no history reports "never did it", so `not: { did: ... }`
/// fires there.
fn matchesDid(did: matcher.Did, ctx: *Context) !bool {
    var entries = ctx.input.history;
    if (did.within) |within| if (within < entries.len) {
        entries = entries[entries.len - within ..];
    };
    for (entries) |entry| {
        if (did.tools.len > 0) {
            const named = for (did.tools) |tool| {
                if (std.mem.eql(u8, tool, entry.name)) break true;
            } else false;
            if (!named) continue;
        }
        if (did.patterns.len > 0) {
            const args = entry.args orelse continue;
            const hit = for (did.patterns) |pattern| {
                if (pattern.isMatch(args)) break true;
            } else false;
            if (!hit) continue;
        }
        if (did.path) |predicate| {
            const targets = try paths.resolveTargets(ctx.arena, entry.paths, ctx.input.cwd, ctx.input.home);
            if (!try matchesPathTargets(predicate, targets, ctx)) continue;
        }
        return true;
    }
    return false;
}

fn snippetsFor(ctx: *Context, spans: []const Span) ![]const Snippet {
    const text = ctx.input.text;
    const sorted = try ctx.arena.dupe(Span, spans);
    std.sort.pdq(Span, sorted, {}, struct {
        fn less(_: void, a: Span, b: Span) bool {
            return a.start < b.start;
        }
    }.less);
    var snippets: std.ArrayList(Snippet) = .empty;
    for (sorted) |span| {
        const line = std.mem.count(u8, text[0..@min(span.start, text.len)], "\n") + 1;
        if (snippets.items.len > 0 and snippets.items[snippets.items.len - 1].line == line) continue;
        const line_start = if (std.mem.findScalarLast(u8, text[0..@min(span.start, text.len)], '\n')) |i| i + 1 else 0;
        const line_end = std.mem.findScalarPos(u8, text, @min(span.start, text.len), '\n') orelse text.len;
        var body = std.mem.trim(u8, text[line_start..line_end], " \t\r");
        if (body.len > max_snippet_bytes) {
            var cut: usize = max_snippet_bytes;
            while (cut > 0 and (body[cut] & 0xc0) == 0x80) cut -= 1;
            body = try ctx.arena.print("{s}…", .{body[0..cut]});
        }
        try snippets.append(ctx.arena, .{ .line = line, .text = body });
        if (snippets.items.len >= max_snippets) break;
    }
    return snippets.items;
}
