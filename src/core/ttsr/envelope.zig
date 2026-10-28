//! The model-facing text of an injected rule, proto's
//! `ttsr-interrupt.md` and `ttsr-tool-reminder.md`, and the reverse: the
//! rule names an injection in saved history carries. The envelope is what
//! persists, so a resumed session rebuilds its repeat ledger from it.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Kind = enum { interrupt, reminder };

/// How a rule reached the conversation, for its transcript row.
pub const NoticeKind = enum { interrupt, reminder, deferred };

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

/// A rule's transcript row: its names, the description of a single rule,
/// and what happened. The live turn and every replay share it. Caller owns
/// the result.
pub fn noticeBody(alloc: Allocator, names: []const []const u8, description: ?[]const u8, kind: NoticeKind) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (names, 0..) |name, index| {
        if (index > 0) try out.appendSlice(alloc, ", ");
        try out.appendSlice(alloc, name);
    }
    if (names.len == 1) if (description) |text| {
        const first_line = std.mem.sliceTo(text, '\n');
        if (first_line.len > 0) try out.print(alloc, " · {s}", .{first_line[0..@min(first_line.len, 160)]});
    };
    try out.appendSlice(alloc, switch (kind) {
        .interrupt => " · response restarted",
        .reminder => " · added to the tool result",
        .deferred => " · added after the reply",
    });
    return out.toOwnedSlice(alloc);
}

/// The transcript row for an injection restored from a saved session, as
/// the live turn gave it. An interrupt envelope saved after a whole reply
/// was added after it; one saved with no reply restarted the response.
/// `description` is the single rule's, when it can still be read. Caller
/// owns the result.
pub fn restoredNotice(alloc: Allocator, text: []const u8, after_reply: bool, description: ?[]const u8) !?[]u8 {
    if (!isInjection(text)) return null;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(alloc);
    const Collect = struct {
        names: *std.ArrayList([]const u8),
        alloc: Allocator,
        failed: bool = false,
        fn visit(state: *@This(), name: []const u8) void {
            state.names.append(state.alloc, name) catch {
                state.failed = true;
            };
        }
    };
    var state: Collect = .{ .names = &names, .alloc = alloc };
    eachRuleName(text, &state, Collect.visit);
    if (state.failed) return error.OutOfMemory;
    const kind: NoticeKind = if (std.mem.startsWith(u8, text, reminder_open)) .reminder else if (after_reply) .deferred else .interrupt;
    // Names are escaped as attributes; the row shows them as written.
    const shown = try alloc.alloc([]const u8, names.items.len);
    defer {
        for (shown) |name| alloc.free(name);
        alloc.free(shown);
    }
    for (names.items, shown) |name, *out| out.* = try unescapeAttr(alloc, name);
    return try noticeBody(alloc, shown, description, kind);
}

/// The path attribute of an envelope that names exactly one rule, as
/// written in the rule's row. Caller owns the result.
pub fn singleRulePath(alloc: Allocator, text: []const u8) !?[]u8 {
    if (!isInjection(text)) return null;
    const open = if (std.mem.startsWith(u8, text, interrupt_open)) interrupt_open else reminder_open;
    if (std.mem.findPos(u8, text, open.len, open) != null) return null;
    const marker = "\" path=\"";
    const at = std.mem.findPos(u8, text, open.len, marker) orelse return null;
    const start = at + marker.len;
    const end = std.mem.findScalarPos(u8, text, start, '"') orelse return null;
    return try unescapeAttr(alloc, text[start..end]);
}

fn unescapeAttr(alloc: Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var index: usize = 0;
    while (index < value.len) {
        const rest = value[index..];
        inline for (.{ .{ "&quot;", '"' }, .{ "&amp;", '&' }, .{ "&lt;", '<' } }) |pair| {
            if (std.mem.startsWith(u8, rest, pair[0])) {
                try out.append(alloc, pair[1]);
                index += pair[0].len;
                break;
            }
        } else {
            try out.append(alloc, value[index]);
            index += 1;
        }
    }
    return out.toOwnedSlice(alloc);
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
    const restored = (try restoredNotice(alloc, text, false, null)).?;
    defer alloc.free(restored);
    try std.testing.expectEqualStrings("no-force, py-print · response restarted", restored);
    const deferred = (try restoredNotice(alloc, text, true, null)).?;
    defer alloc.free(deferred);
    try std.testing.expectEqualStrings("no-force, py-print · added after the reply", deferred);
    try std.testing.expect((try singleRulePath(alloc, text)) == null);
    const single = (try restoredNotice(alloc, reminder, false, "Use the logger.\nMore.")).?;
    defer alloc.free(single);
    try std.testing.expectEqualStrings("a\"b · Use the logger. · added to the tool result", single);
    const path = (try singleRulePath(alloc, reminder)).?;
    defer alloc.free(path);
    try std.testing.expectEqualStrings("p", path);
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
