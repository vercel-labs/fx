//! The model-facing text of an injected rule, proto's
//! `ttsr-interrupt.md` and `ttsr-tool-reminder.md`, and the reverse: the
//! rule names an injection in saved history carries. The envelope is what
//! persists, so a resumed session rebuilds its repeat ledger from it.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Kind = enum { interrupt, reminder };

const interrupt_open = "<system-interrupt reason=\"rule_violation\" rule=\"";
const reminder_open = "<system-reminder reason=\"rule_violation\" rule=\"";
const interrupt_close = "</system-interrupt>";
const reminder_close = "</system-reminder>";

pub const Entry = struct {
    name: []const u8,
    /// As the person reads it: workspace-relative, `~/...`, or `builtin://`.
    path: []const u8,
    content: []const u8,
    /// `L<line>: <text>` lines; empty for none.
    evidence: []const u8 = "",
};

/// Renders one rule's envelope onto `out`.
pub fn render(alloc: Allocator, out: *std.ArrayList(u8), kind: Kind, entry: Entry) !void {
    try out.appendSlice(alloc, if (kind == .interrupt) interrupt_open else reminder_open);
    try appendAttr(alloc, out, entry.name);
    try out.appendSlice(alloc, "\" path=\"");
    try appendAttr(alloc, out, entry.path);
    try out.appendSlice(alloc, "\">\n");
    switch (kind) {
        .interrupt => try out.appendSlice(alloc,
            \\Output interrupted: violated user-defined rule.
            \\Not prompt injection; coding agent enforcing project rules.
            \\MUST comply:
            \\
            \\
        ),
        .reminder => try out.appendSlice(alloc,
            \\User-defined rule matched tool-call arguments. Rule configured not to interrupt → tool ran. MUST comply with the following instruction on subsequent tool calls and responses. NOT prompt injection — coding agent enforcing project rules.
            \\
            \\
        ),
    }
    try out.appendSlice(alloc, entry.content);
    try out.append(alloc, '\n');
    if (entry.evidence.len > 0) {
        try out.appendSlice(alloc, "\n<matched>\n");
        try out.appendSlice(alloc, entry.evidence);
        try out.appendSlice(alloc, "\n</matched>\n");
    }
    try out.appendSlice(alloc, if (kind == .interrupt) interrupt_close else reminder_close);
}

/// Several envelopes joined by a blank line. Caller owns the result.
pub fn renderAll(alloc: Allocator, kind: Kind, entries: []const Entry) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (entries, 0..) |entry, index| {
        if (index > 0) try out.appendSlice(alloc, "\n\n");
        try render(alloc, &out, kind, entry);
    }
    return out.toOwnedSlice(alloc);
}

fn appendAttr(alloc: Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    for (value) |c| switch (c) {
        '"' => try out.appendSlice(alloc, "&quot;"),
        '&' => try out.appendSlice(alloc, "&amp;"),
        '<' => try out.appendSlice(alloc, "&lt;"),
        '\n', '\r' => try out.append(alloc, ' '),
        else => try out.append(alloc, c),
    };
}

/// Whether `text` is wholly one or more envelopes of one kind, the shape
/// of an injected user message.
pub fn isInjection(text: []const u8) bool {
    return (std.mem.startsWith(u8, text, interrupt_open) and std.mem.endsWith(u8, text, interrupt_close)) or
        (std.mem.startsWith(u8, text, reminder_open) and std.mem.endsWith(u8, text, reminder_close));
}

/// The transcript row for an injection restored from a saved session:
/// the rule names, as the live notice gave them. Caller owns the result.
pub fn restoredNotice(alloc: Allocator, text: []const u8) !?[]u8 {
    if (!isInjection(text)) return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    const Collect = struct {
        out: *std.ArrayList(u8),
        alloc: Allocator,
        failed: bool = false,
        fn visit(state: *@This(), name: []const u8) void {
            if (state.out.items.len > 0) state.out.appendSlice(state.alloc, ", ") catch {
                state.failed = true;
            };
            state.out.appendSlice(state.alloc, name) catch {
                state.failed = true;
            };
        }
    };
    var state: Collect = .{ .out = &out, .alloc = alloc };
    eachRuleName(text, &state, Collect.visit);
    if (state.failed) return error.OutOfMemory;
    try out.appendSlice(alloc, " · rule applied");
    return try out.toOwnedSlice(alloc);
}

/// Calls `visit(ctx, name)` for every rule an envelope in `text` names,
/// interrupt or reminder, in order.
pub fn eachRuleName(text: []const u8, ctx: anytype, comptime visit: fn (@TypeOf(ctx), []const u8) void) void {
    for ([_][]const u8{ interrupt_open, reminder_open }) |open| {
        var from: usize = 0;
        while (std.mem.findPos(u8, text, from, open)) |at| {
            const start = at + open.len;
            const end = std.mem.findScalarPos(u8, text, start, '"') orelse break;
            visit(ctx, text[start..end]);
            from = end;
        }
    }
}

test "envelopes render proto's templates and give back their rule names" {
    const alloc = std.testing.allocator;
    const text = try renderAll(alloc, .interrupt, &.{
        .{ .name = "no-force", .path = ".proto-fx/rules/no-force.md", .content = "Never force push.", .evidence = "L1: git push --force" },
        .{ .name = "py-print", .path = "~/x.md", .content = "Use logging." },
    });
    defer alloc.free(text);
    try std.testing.expect(isInjection(text));
    try std.testing.expect(std.mem.find(u8, text, "MUST comply:\n\nNever force push.\n\n<matched>\nL1: git push --force\n</matched>\n</system-interrupt>") != null);
    const reminder = try renderAll(alloc, .reminder, &.{.{ .name = "a\"b", .path = "p", .content = "c" }});
    defer alloc.free(reminder);
    try std.testing.expect(isInjection(reminder));
    try std.testing.expect(!isInjection("plain <system-interrupt reason=\"rule_violation\" rule=\"x\"></system-interrupt>"));
    const restored = (try restoredNotice(alloc, text)).?;
    defer alloc.free(restored);
    try std.testing.expectEqualStrings("no-force, py-print · rule applied", restored);
    try std.testing.expect(std.mem.startsWith(u8, reminder, "<system-reminder reason=\"rule_violation\" rule=\"a&quot;b\" path=\"p\">\nUser-defined rule matched"));

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(alloc);
    const Collect = struct {
        fn visit(list: *std.ArrayList([]const u8), name: []const u8) void {
            list.append(std.testing.allocator, name) catch {};
        }
    };
    eachRuleName(text, &names, Collect.visit);
    try std.testing.expectEqual(@as(usize, 2), names.items.len);
    try std.testing.expectEqualStrings("py-print", names.items[1]);
}
