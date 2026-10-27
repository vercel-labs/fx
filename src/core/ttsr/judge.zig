//! The model judge behind `llm:` conditions, ported from proto's
//! `ttsr-judge.ts`.
//!
//! A judge answers one yes/no question about one settled buffer on a small
//! model. Verdicts are cached by question, role chain and buffer hash, and
//! a judge spends at most `max_judgements` model calls, so a pathological
//! rule cannot turn every step into a model call. The host supplies the
//! model call through `Completer`, which resolves the rule's roles to a
//! model; until model roles exist the host answers with the session's own
//! model.
const std = @import("std");
const evaluate = @import("evaluate.zig");

const Allocator = std.mem.Allocator;

const max_content_bytes = 6000;
const max_content_lines = 200;
pub const max_judgements = 64;

pub const Completer = struct {
    ctx: *anyopaque,
    /// One completion for `prompt` on the model `roles` resolve to, tried in
    /// order. Returns text allocated with `alloc`, or null when no model
    /// answered.
    complete: *const fn (ctx: *anyopaque, alloc: Allocator, roles: []const []const u8, prompt: []const u8) ?[]u8,
};

pub const Judge = struct {
    gpa: Allocator,
    completer: Completer,
    verdicts: std.AutoHashMapUnmanaged(u64, bool) = .empty,
    spent: usize = 0,

    pub fn init(gpa: Allocator, completer: Completer) Judge {
        return .{ .gpa = gpa, .completer = completer };
    }

    pub fn deinit(self: *Judge) void {
        self.verdicts.deinit(self.gpa);
    }

    pub fn asJudge(self: *Judge) evaluate.Judge {
        return .{ .ctx = self, .ask = ask };
    }

    fn ask(raw: *anyopaque, request: evaluate.JudgeRequest) ?bool {
        const self: *Judge = @ptrCast(@alignCast(raw));
        var hasher = std.hash.Wyhash.init(0);
        for (request.roles) |role| {
            hasher.update(role);
            hasher.update("\x01");
        }
        hasher.update(request.question);
        hasher.update("\x00");
        hasher.update(request.text);
        const key = hasher.final();
        if (self.verdicts.get(key)) |cached| return cached;
        if (self.spent >= max_judgements) return null;
        self.spent += 1;
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const prompt = renderPrompt(arena, request) catch return null;
        const answer = self.completer.complete(self.completer.ctx, arena, request.roles, prompt) orelse return null;
        const verdict = parseVerdict(answer) orelse return null;
        self.verdicts.put(self.gpa, key, verdict) catch {};
        return verdict;
    }
};

/// The last `yes` or `no` word wins: a model that explains itself first
/// still lands on its conclusion last.
pub fn parseVerdict(text: []const u8) ?bool {
    var verdict: ?bool = null;
    var index: usize = 0;
    while (index < text.len) {
        if (!std.ascii.isAlphabetic(text[index])) {
            index += 1;
            continue;
        }
        const start = index;
        while (index < text.len and std.ascii.isAlphanumeric(text[index])) index += 1;
        const word = text[start..index];
        if (std.ascii.eqlIgnoreCase(word, "yes")) verdict = true;
        if (std.ascii.eqlIgnoreCase(word, "no")) verdict = false;
    }
    return verdict;
}

fn origin(arena: Allocator, request: evaluate.JudgeRequest) ![]const u8 {
    return switch (request.source) {
        .text => "assistant message",
        .thinking => "assistant reasoning",
        .tool => blk: {
            const tool = request.tool_name orelse break :blk "tool call";
            if (request.file_paths.len > 0) break :blk try arena.print("{s} tool call — {s}", .{ tool, request.file_paths[0] });
            break :blk try arena.print("{s} tool call", .{tool});
        },
    };
}

/// Keeps the head and tail of a large buffer; the middle carries no verdict.
fn truncateMiddle(arena: Allocator, text: []const u8) ![]const u8 {
    const lines = std.mem.count(u8, text, "\n") + 1;
    if (text.len <= max_content_bytes and lines <= max_content_lines) return text;
    var head_end: usize = 0;
    var seen: usize = 0;
    while (head_end < text.len and head_end < max_content_bytes / 2 and seen < max_content_lines / 2) : (head_end += 1) {
        if (text[head_end] == '\n') seen += 1;
    }
    var tail_start = text.len;
    seen = 0;
    while (tail_start > head_end and text.len - tail_start < max_content_bytes / 2 and seen < max_content_lines / 2) {
        tail_start -= 1;
        if (text[tail_start] == '\n') seen += 1;
    }
    while (head_end > 0 and head_end < text.len and (text[head_end] & 0xc0) == 0x80) head_end -= 1;
    while (tail_start < text.len and (text[tail_start] & 0xc0) == 0x80) tail_start += 1;
    return arena.print("{s}\n[… {d} bytes omitted …]\n{s}", .{ text[0..head_end], tail_start - head_end, text[tail_start..] });
}

pub fn renderPrompt(arena: Allocator, request: evaluate.JudgeRequest) ![]const u8 {
    return arena.print(
        \\You are a strict code-review classifier. A project rule needs one yes/no verdict about the content below.
        \\
        \\Rules:
        \\- Answer only about what the content actually does. Text that merely mentions, quotes, or discusses the subject is not an instance of it.
        \\- Incomplete content is normal — it is a snapshot of work in progress. Judge what is there.
        \\- When the evidence is ambiguous or absent, answer NO.
        \\
        \\Question:
        \\{s}
        \\
        \\Origin: {s}
        \\Content:
        \\<content>
        \\{s}
        \\</content>
        \\
        \\Answer one word: YES if the answer to the question is yes; NO otherwise.
    , .{ request.question, try origin(arena, request), try truncateMiddle(arena, request.text) });
}

const FakeModel = struct {
    reply: ?[]const u8,
    calls: usize = 0,

    fn complete(raw: *anyopaque, alloc: Allocator, roles: []const []const u8, prompt: []const u8) ?[]u8 {
        const self: *FakeModel = @ptrCast(@alignCast(raw));
        self.calls += 1;
        std.debug.assert(roles.len > 0);
        std.debug.assert(std.mem.find(u8, prompt, "<content>\nx as any\n</content>") != null);
        return alloc.dupe(u8, self.reply orelse return null) catch null;
    }
};

test "judge parses the last verdict word, caches and budgets" {
    try std.testing.expectEqual(true, parseVerdict("YES").?);
    try std.testing.expectEqual(false, parseVerdict("Yes it mentions it, but no.").?);
    try std.testing.expect(parseVerdict("maybe; nothing certain") == null);
    try std.testing.expect(parseVerdict("yesterday nobody") == null);

    var model: FakeModel = .{ .reply = "Looking at it: yes" };
    var judge = Judge.init(std.testing.allocator, .{ .ctx = &model, .complete = FakeModel.complete });
    defer judge.deinit();
    const j = judge.asJudge();
    const request: evaluate.JudgeRequest = .{ .question = "Real cast?", .roles = &.{"smol"}, .text = "x as any", .source = .tool, .lang = "ts", .tool_name = "write_file", .file_paths = &.{"a.ts"} };
    try std.testing.expectEqual(true, j.ask(j.ctx, request).?);
    try std.testing.expectEqual(true, j.ask(j.ctx, request).?);
    try std.testing.expectEqual(@as(usize, 1), model.calls);
    model.reply = null;
    var other = request;
    other.question = "Another?";
    try std.testing.expect(j.ask(j.ctx, other) == null);
    judge.spent = max_judgements;
    other.question = "Third?";
    try std.testing.expect(j.ask(j.ctx, other) == null);
    try std.testing.expectEqual(@as(usize, 2), model.calls);
}

test "judge prompts keep the head and tail of large buffers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var big: [1000]u8 = undefined;
    for (&big, 0..) |*c, i| c.* = if (i % 2 == 0) 'a' else '\n';
    const prompt = try renderPrompt(arena_state.allocator(), .{ .question = "Q?", .roles = &.{}, .text = &big, .source = .text, .lang = null, .tool_name = null, .file_paths = &.{} });
    try std.testing.expect(std.mem.find(u8, prompt, "bytes omitted") != null);
    try std.testing.expect(std.mem.find(u8, prompt, "Origin: assistant message") != null);
}
