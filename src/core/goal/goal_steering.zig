const std = @import("std");
const goal_store = @import("goal_store.zig");

const Allocator = std.mem.Allocator;

pub const TemplateValue = struct { name: []const u8, value: []const u8 };

/// Renders a `{{ name }}` template by interpolating the provided values.
/// Supports only placeholder interpolation and literal `{{{{` / `}}}}` escapes
/// for the three goal templates.
pub fn render(
    alloc: Allocator,
    template: []const u8,
    values: []const TemplateValue,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var i: usize = 0;
    while (i < template.len) {
        if (i + 1 < template.len and template[i] == '{' and template[i + 1] == '{') {
            // Escape for literal {{
            if (i + 3 < template.len and
                template[i] == '{' and template[i + 1] == '{' and
                template[i + 2] == '{' and template[i + 3] == '{')
            {
                try out.writer.writeAll("{");
                i += 4;
                continue;
            }
            // Find closing }}
            const start = i + 2;
            const close = std.mem.findPos(u8, template, start, "}}") orelse return error.UnterminatedPlaceholder;
            const raw = template[start..close];
            const name = std.mem.trim(u8, raw, " \t");
            if (name.len == 0) return error.EmptyPlaceholder;
            if (std.mem.find(u8, name, "{{") != null) return error.NestedPlaceholder;
            const value = lookupValue(name, values) orelse return error.MissingValue;
            try out.writer.writeAll(value);
            i = close + 2;
            continue;
        }
        try out.writer.writeByte(template[i]);
        i += 1;
    }
    return try out.toOwnedSlice();
}

fn lookupValue(name: []const u8, values: []const TemplateValue) ?[]const u8 {
    for (values) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.value;
    }
    return null;
}

fn escapeXmlText(alloc: Allocator, input: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    for (input) |c| {
        switch (c) {
            '&' => try out.writer.writeAll("&amp;"),
            '<' => try out.writer.writeAll("&lt;"),
            '>' => try out.writer.writeAll("&gt;"),
            else => try out.writer.writeByte(c),
        }
    }
    return try out.toOwnedSlice();
}

/// Formats an optional integer as a string, or `none_label` when null.
fn formatOptInt(alloc: Allocator, val: ?i64, none_label: []const u8) ![]u8 {
    if (val) |v| return std.fmt.allocPrint(alloc, "{d}", .{v});
    return alloc.dupe(u8, none_label);
}

/// Formats remaining tokens for a goal, or `unbounded_label` when no budget.
fn formatRemainingTokens(alloc: Allocator, goal: goal_store.Goal, unbounded_label: []const u8) ![]u8 {
    if (goal.token_budget) |b| {
        const rem = if (b > goal.tokens_used) b - goal.tokens_used else 0;
        return std.fmt.allocPrint(alloc, "{d}", .{rem});
    }
    return alloc.dupe(u8, unbounded_label);
}

const continuation_template = @embedFile("templates/continuation.md");
const budget_limit_template = @embedFile("templates/budget_limit.md");
const objective_updated_template = @embedFile("templates/objective_updated.md");

/// Continuation prompt injected to re-engage an active goal after a turn ends.
pub fn continuationPrompt(alloc: Allocator, goal: goal_store.Goal) ![]u8 {
    const objective = try escapeXmlText(alloc, goal.objective);
    defer alloc.free(objective);
    const tokens_used = try std.fmt.allocPrint(alloc, "{d}", .{goal.tokens_used});
    defer alloc.free(tokens_used);
    const token_budget = try formatOptInt(alloc, goal.token_budget, "none");
    defer alloc.free(token_budget);
    const remaining_tokens = try formatRemainingTokens(alloc, goal, "unbounded");
    defer alloc.free(remaining_tokens);
    return render(alloc, continuation_template, &.{
        .{ .name = "objective", .value = objective },
        .{ .name = "tokens_used", .value = tokens_used },
        .{ .name = "token_budget", .value = token_budget },
        .{ .name = "remaining_tokens", .value = remaining_tokens },
    });
}

/// Budget-limit prompt injected when a goal exhausts its token budget.
pub fn budgetLimitPrompt(alloc: Allocator, goal: goal_store.Goal) ![]u8 {
    const objective = try escapeXmlText(alloc, goal.objective);
    defer alloc.free(objective);
    const time_used_seconds = try std.fmt.allocPrint(alloc, "{d}", .{goal.time_used_seconds});
    defer alloc.free(time_used_seconds);
    const tokens_used = try std.fmt.allocPrint(alloc, "{d}", .{goal.tokens_used});
    defer alloc.free(tokens_used);
    const token_budget = try formatOptInt(alloc, goal.token_budget, "none");
    defer alloc.free(token_budget);
    return render(alloc, budget_limit_template, &.{
        .{ .name = "objective", .value = objective },
        .{ .name = "time_used_seconds", .value = time_used_seconds },
        .{ .name = "tokens_used", .value = tokens_used },
        .{ .name = "token_budget", .value = token_budget },
    });
}

/// Objective-updated prompt injected after the user edits the active goal's objective.
pub fn objectiveUpdatedPrompt(alloc: Allocator, goal: goal_store.Goal) ![]u8 {
    const objective = try escapeXmlText(alloc, goal.objective);
    defer alloc.free(objective);
    const tokens_used = try std.fmt.allocPrint(alloc, "{d}", .{goal.tokens_used});
    defer alloc.free(tokens_used);
    const token_budget = try formatOptInt(alloc, goal.token_budget, "none");
    defer alloc.free(token_budget);
    const remaining_tokens = try formatRemainingTokens(alloc, goal, "unknown");
    defer alloc.free(remaining_tokens);
    return render(alloc, objective_updated_template, &.{
        .{ .name = "objective", .value = objective },
        .{ .name = "tokens_used", .value = tokens_used },
        .{ .name = "token_budget", .value = token_budget },
        .{ .name = "remaining_tokens", .value = remaining_tokens },
    });
}

test "render interpolates placeholders" {
    const alloc = std.testing.allocator;
    const out = try render(alloc, "Hello {{ name }}!", &.{.{ .name = "name", .value = "world" }});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Hello world!", out);
}

test "render rejects unterminated placeholder" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.UnterminatedPlaceholder, render(alloc, "{{ name", &.{}));
}

test "render rejects missing value" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.MissingValue, render(alloc, "{{ name }}", &.{}));
}

test "continuationPrompt renders budget fields" {
    const alloc = std.testing.allocator;
    var goal: goal_store.Goal = .{
        .goal_id = try alloc.dupe(u8, "g1"),
        .objective = try alloc.dupe(u8, "ship <release>"),
        .token_budget = 1000,
        .tokens_used = 250,
        .created_at_ms = 1,
        .updated_at_ms = 2,
    };
    defer goal.deinit(alloc);
    const prompt = try continuationPrompt(alloc, goal);
    defer alloc.free(prompt);
    try std.testing.expect(std.mem.find(u8, prompt, "ship &lt;release&gt;") != null);
    try std.testing.expect(std.mem.find(u8, prompt, "Tokens used: 250") != null);
    try std.testing.expect(std.mem.find(u8, prompt, "Token budget: 1000") != null);
    try std.testing.expect(std.mem.find(u8, prompt, "Tokens remaining: 750") != null);
}

test "continuationPrompt renders unbounded when no budget" {
    const alloc = std.testing.allocator;
    var goal: goal_store.Goal = .{
        .goal_id = try alloc.dupe(u8, "g1"),
        .objective = try alloc.dupe(u8, "ship it"),
        .token_budget = null,
        .tokens_used = 100,
        .created_at_ms = 1,
        .updated_at_ms = 2,
    };
    defer goal.deinit(alloc);
    const prompt = try continuationPrompt(alloc, goal);
    defer alloc.free(prompt);
    try std.testing.expect(std.mem.find(u8, prompt, "Token budget: none") != null);
    try std.testing.expect(std.mem.find(u8, prompt, "Tokens remaining: unbounded") != null);
}

test "budgetLimitPrompt includes time used" {
    const alloc = std.testing.allocator;
    var goal: goal_store.Goal = .{
        .goal_id = try alloc.dupe(u8, "g1"),
        .objective = try alloc.dupe(u8, "ship it"),
        .token_budget = 500,
        .tokens_used = 500,
        .time_used_seconds = 120,
        .created_at_ms = 1,
        .updated_at_ms = 2,
    };
    defer goal.deinit(alloc);
    const prompt = try budgetLimitPrompt(alloc, goal);
    defer alloc.free(prompt);
    try std.testing.expect(std.mem.find(u8, prompt, "Time spent pursuing goal: 120 seconds") != null);
}

test "objectiveUpdatedPrompt renders unknown remaining when no budget" {
    const alloc = std.testing.allocator;
    var goal: goal_store.Goal = .{
        .goal_id = try alloc.dupe(u8, "g1"),
        .objective = try alloc.dupe(u8, "ship it"),
        .token_budget = null,
        .tokens_used = 0,
        .created_at_ms = 1,
        .updated_at_ms = 2,
    };
    defer goal.deinit(alloc);
    const prompt = try objectiveUpdatedPrompt(alloc, goal);
    defer alloc.free(prompt);
    try std.testing.expect(std.mem.find(u8, prompt, "Tokens remaining: unknown") != null);
}
