//! A stream rule: Markdown whose frontmatter says when it fires and whose
//! body is the instruction the model receives.
//!
//! Frontmatter fields: `description`, `globs`, `scope` (`text`, `thinking`,
//! `tool`, `tool:<name>` and `tool:<name>(<path glob>)`), `interruptMode`
//! (`never`, `prose-only`, `tool-only`, `always`), `match` (the expression
//! tree in `matcher.zig`), the legacy flat `condition` and `astCondition`
//! lists, and `enabled: false` to switch a file off.
const std = @import("std");
const yaml = @import("yaml.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const InterruptMode = enum {
    never,
    prose_only,
    tool_only,
    always,

    pub fn parse(text: []const u8) ?InterruptMode {
        if (std.mem.eql(u8, text, "never")) return .never;
        if (std.mem.eql(u8, text, "prose-only")) return .prose_only;
        if (std.mem.eql(u8, text, "tool-only")) return .tool_only;
        if (std.mem.eql(u8, text, "always")) return .always;
        return null;
    }

    pub fn label(self: InterruptMode) []const u8 {
        return switch (self) {
            .never => "never",
            .prose_only => "prose-only",
            .tool_only => "tool-only",
            .always => "always",
        };
    }
};

/// Where a rule came from; earlier sources win a name clash.
pub const Provider = enum {
    project,
    user,
    cursor,
    windsurf,
    builtin,
    file,

    pub fn label(self: Provider) []const u8 {
        return switch (self) {
            .project => "project",
            .user => "user",
            .cursor => "cursor",
            .windsurf => "windsurf",
            .builtin => "built-in",
            .file => "file",
        };
    }
};

pub const Rule = struct {
    name: []const u8,
    path: []const u8,
    /// The body after the frontmatter: the instruction text.
    content: []const u8,
    description: ?[]const u8 = null,
    globs: []const []const u8 = &.{},
    scope: []const []const u8 = &.{},
    interrupt_mode: ?InterruptMode = null,
    match: ?Value = null,
    condition: []const []const u8 = &.{},
    ast_condition: []const []const u8 = &.{},
    provider: Provider,

    /// Only rules with a condition stream; the rest are plain guidance.
    pub fn hasCondition(self: Rule) bool {
        return self.match != null or self.condition.len > 0 or self.ast_condition.len > 0;
    }
};

pub const Split = struct { frontmatter: ?[]const u8, body: []const u8 };

/// Splits a leading `---` fenced frontmatter block from the body.
pub fn splitFrontmatter(content: []const u8) Split {
    var text = content;
    if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text = text[3..];
    if (!std.mem.startsWith(u8, text, "---")) return .{ .frontmatter = null, .body = content };
    const first_newline = std.mem.findScalar(u8, text, '\n') orelse return .{ .frontmatter = null, .body = content };
    if (std.mem.trim(u8, text[0..first_newline], " \r").len != 3) return .{ .frontmatter = null, .body = content };
    var pos = first_newline + 1;
    while (pos <= text.len) {
        const line_end = std.mem.findScalarPos(u8, text, pos, '\n') orelse text.len;
        if (std.mem.eql(u8, std.mem.trimEnd(u8, text[pos..line_end], " \r"), "---")) {
            const body_start = @min(line_end + 1, text.len);
            return .{ .frontmatter = text[first_newline + 1 .. pos], .body = std.mem.trimStart(u8, text[body_start..], "\r\n") };
        }
        if (line_end == text.len) break;
        pos = line_end + 1;
    }
    return .{ .frontmatter = null, .body = content };
}

/// Builds a rule from a Markdown file; null when `enabled: false`.
/// Memory comes from `arena`.
pub fn parseMarkdown(arena: Allocator, name: []const u8, content: []const u8, path: []const u8, provider: Provider) !?Rule {
    const split = splitFrontmatter(content);
    var rule: Rule = .{
        .name = name,
        .path = path,
        .content = std.mem.trim(u8, split.body, " \t\r\n"),
        .provider = provider,
    };
    const raw = split.frontmatter orelse return rule;
    const doc = yaml.parse(arena, raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidYaml => return error.InvalidFrontmatter,
    };
    if (doc != .object) return error.InvalidFrontmatter;
    const fields = doc.object;
    if (fields.get("enabled")) |value| if (value == .bool and !value.bool) return null;
    if (fields.get("description")) |value| if (value == .string) {
        rule.description = std.mem.trim(u8, value.string, " \t\r\n");
    };
    if (fields.get("globs")) |value| rule.globs = try globList(arena, value);
    if (fields.get("scope")) |value| rule.scope = try scopeList(arena, value);
    if (fields.get("interruptMode")) |value| if (value == .string) {
        rule.interrupt_mode = InterruptMode.parse(value.string);
    };
    if (fields.get("match")) |value| switch (value) {
        .string, .array, .object => rule.match = value,
        else => {},
    };
    const condition = fields.get("condition") orelse fields.get("ttsr_trigger") orelse fields.get("ttsrTrigger");
    if (condition) |value| rule.condition = try fieldList(arena, value);
    if (fields.get("astCondition")) |value| rule.ast_condition = try fieldList(arena, value);
    return rule;
}

/// Unique trimmed strings from a string or list.
fn fieldList(arena: Allocator, value: Value) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    switch (value) {
        .string => |s| try appendUnique(arena, &out, s),
        .array => |items| for (items.items) |item| if (item == .string) try appendUnique(arena, &out, item.string),
        else => {},
    }
    return out.items;
}

fn appendUnique(arena: Allocator, out: *std.ArrayList([]const u8), raw: []const u8) !void {
    const token = std.mem.trim(u8, raw, " \t\r\n");
    if (token.len == 0) return;
    for (out.items) |existing| if (std.mem.eql(u8, existing, token)) return;
    try out.append(arena, token);
}

/// Globs from a list, or from Cursor's comma-separated string.
fn globList(arena: Allocator, value: Value) ![]const []const u8 {
    if (value != .string or std.mem.findScalar(u8, value.string, '{') != null) return fieldList(arena, value);
    var out: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, value.string, ',');
    while (parts.next()) |part| try appendUnique(arena, &out, part);
    return out.items;
}

/// Scope tokens, splitting on commas outside brackets and quotes.
fn scopeList(arena: Allocator, value: Value) ![]const []const u8 {
    const raw = try fieldList(arena, value);
    var out: std.ArrayList([]const u8) = .empty;
    for (raw) |entry| {
        var depth: usize = 0;
        var quote: ?u8 = null;
        var start: usize = 0;
        for (entry, 0..) |c, i| {
            if (quote) |q| {
                if (c == q) quote = null;
                continue;
            }
            switch (c) {
                '"', '\'' => quote = c,
                '(', '[', '{' => depth += 1,
                ')', ']', '}' => depth -|= 1,
                ',' => if (depth == 0) {
                    try appendUnique(arena, &out, unquote(entry[start..i]));
                    start = i + 1;
                },
                else => {},
            }
        }
        try appendUnique(arena, &out, unquote(entry[start..]));
    }
    return out.items;
}

fn unquote(raw: []const u8) []const u8 {
    const token = std.mem.trim(u8, raw, " \t");
    if (token.len >= 2 and (token[0] == '"' or token[0] == '\'') and token[token.len - 1] == token[0]) return std.mem.trim(u8, token[1 .. token.len - 1], " ");
    return token;
}

pub const ToolScope = struct {
    /// Lowercased; null for any tool.
    tool: ?[]const u8 = null,
    path_glob: ?[]const u8 = null,
};

pub const Scope = struct {
    text: bool,
    thinking: bool,
    any_tool: bool,
    tools: []const ToolScope,

    pub fn reachable(self: Scope) bool {
        return self.text or self.thinking or self.any_tool or self.tools.len > 0;
    }
};

/// The streams a rule watches. No scope means assistant text and every
/// tool call, as in proto. Invalid tokens are skipped.
pub fn buildScope(arena: Allocator, tokens: []const []const u8) !Scope {
    if (tokens.len == 0) return .{ .text = true, .thinking = false, .any_tool = true, .tools = &.{} };
    var scope: Scope = .{ .text = false, .thinking = false, .any_tool = false, .tools = &.{} };
    var tools: std.ArrayList(ToolScope) = .empty;
    for (tokens) |token| {
        if (std.ascii.eqlIgnoreCase(token, "text")) {
            scope.text = true;
        } else if (std.ascii.eqlIgnoreCase(token, "thinking")) {
            scope.thinking = true;
        } else if (std.ascii.eqlIgnoreCase(token, "tool") or std.ascii.eqlIgnoreCase(token, "toolcall")) {
            scope.any_tool = true;
        } else if (try parseToolScope(arena, token)) |tool_scope| {
            if (tool_scope.tool == null and tool_scope.path_glob == null) scope.any_tool = true else try tools.append(arena, tool_scope);
        }
    }
    scope.tools = tools.items;
    return scope;
}

fn parseToolScope(arena: Allocator, token: []const u8) !?ToolScope {
    var name_part = token;
    var glob: ?[]const u8 = null;
    if (std.mem.findScalar(u8, token, '(')) |open| {
        if (token[token.len - 1] != ')') return null;
        glob = std.mem.trim(u8, token[open + 1 .. token.len - 1], " ");
        if (glob.?.len == 0) return null;
        name_part = token[0..open];
    }
    var tool: ?[]const u8 = null;
    if (std.ascii.startsWithIgnoreCase(name_part, "tool:")) {
        tool = name_part[5..];
    } else if (std.ascii.eqlIgnoreCase(name_part, "tool")) {
        tool = null;
    } else {
        tool = name_part;
    }
    if (tool) |name| {
        if (name.len == 0) return null;
        for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return null;
        tool = try std.ascii.allocLowerString(arena, name);
    }
    return .{ .tool = tool, .path_glob = glob };
}

test "rules parse frontmatter, scope and interrupt mode" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const content =
        \\---
        \\description: No force pushes
        \\scope: "tool:shell, text, tool:edit_file(src/**/*.py)"
        \\interruptMode: tool-only
        \\globs: "*.py,*.pyi"
        \\match:
        \\  regex: 'git push (-f|--force)'
        \\---
        \\
        \\Never force push.
    ;
    const rule = (try parseMarkdown(arena, "no-force", content, "/r/no-force.md", .project)).?;
    try std.testing.expectEqualStrings("Never force push.", rule.content);
    try std.testing.expectEqualStrings("No force pushes", rule.description.?);
    try std.testing.expectEqual(InterruptMode.tool_only, rule.interrupt_mode.?);
    try std.testing.expectEqual(@as(usize, 2), rule.globs.len);
    try std.testing.expect(rule.hasCondition());
    try std.testing.expectEqual(@as(usize, 3), rule.scope.len);
    const scope = try buildScope(arena, rule.scope);
    try std.testing.expect(scope.text and !scope.thinking and !scope.any_tool);
    try std.testing.expectEqualStrings("shell", scope.tools[0].tool.?);
    try std.testing.expectEqualStrings("src/**/*.py", scope.tools[1].path_glob.?);
    try std.testing.expect(try parseMarkdown(arena, "off", "---\nenabled: false\n---\nbody", "/r/off.md", .user) == null);
    const plain = (try parseMarkdown(arena, "plain", "Just guidance.", "/r/plain.md", .user)).?;
    try std.testing.expect(!plain.hasCondition());
    const default_scope = try buildScope(arena, &.{});
    try std.testing.expect(default_scope.text and default_scope.any_tool and !default_scope.thinking);
    try std.testing.expectError(error.InvalidFrontmatter, parseMarkdown(arena, "bad", "---\nmatch: [a\n---\n", "/r/bad.md", .user));
}
