//! Coordinator tests: interrupt, reminder and deferred paths, settled
//! conditions, the repeat ledger across a rebuilt conversation, and
//! cancellation of the stream.
const std = @import("std");
const coordinator_mod = @import("coordinator.zig");
const rule_mod = @import("rule.zig");
const evaluate = @import("evaluate.zig");

const Coordinator = coordinator_mod.Coordinator;

const Call = struct { name: []const u8, arguments_json: []const u8 };
const Message = struct {
    role: enum { system, user, assistant, tool },
    content: ?[]const u8 = null,
    tool_calls: []const Call = &.{},
};

const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,
    rules: std.ArrayList(rule_mod.Rule) = .empty,

    fn init() Fixture {
        return .{ .arena_state = std.heap.ArenaAllocator.init(std.testing.allocator) };
    }

    fn deinit(self: *Fixture) void {
        self.arena_state.deinit();
    }

    fn add(self: *Fixture, name: []const u8, frontmatter: []const u8) !void {
        const arena = self.arena_state.allocator();
        const content = try arena.print("---\n{s}\n---\nRule {s} body.", .{ frontmatter, name });
        try self.rules.append(arena, (try rule_mod.parseMarkdown(arena, name, content, try arena.print("/ws/.proto-fx/rules/{s}.md", .{name}), .project)).?);
    }

    fn coordinator(self: *Fixture, settings: @import("settings.zig").Settings) !*Coordinator {
        return Coordinator.init(std.testing.allocator, settings, self.rules.items, "/ws", "/home/me");
    }
};

test "an interrupting tool rule cancels the stream and renders the retry injection" {
    var f = Fixture.init();
    defer f.deinit();
    try f.add("no-force-push", "description: Never force-push\nscope: tool:shell\nmatch: 'git push (-f|--force)'");
    const c = try f.coordinator(.{});
    defer c.deinit();
    var cancel = std.atomic.Value(bool).init(false);
    c.beginAttempt(&cancel);
    c.onToolStart("call_1", "shell", null);
    c.onToolInput("call_1", "{\"action\":\"run\",\"command\":\"git push --fo");
    try std.testing.expect(!cancel.load(.seq_cst));
    c.onToolInput("call_1", "rce origin main\"}");
    try std.testing.expect(cancel.load(.seq_cst));
    try std.testing.expect(c.abort_requested and c.interruptPending());

    const arena = f.arena_state.allocator();
    const injection = (try c.takeInterrupt(arena)).?;
    try std.testing.expect(std.mem.startsWith(u8, injection.text, "<system-interrupt reason=\"rule_violation\" rule=\"no-force-push\" path=\".proto-fx/rules/no-force-push.md\">"));
    try std.testing.expect(std.mem.find(u8, injection.text, "<matched>\nL1: git push --force origin main\n</matched>") != null);
    try std.testing.expectEqualStrings("no-force-push · Never force-push · response restarted", injection.notice);
    try std.testing.expect(!c.abort_requested);

    // The retry sees the injection in the conversation: the rule is spent.
    const messages = [_]Message{
        .{ .role = .user, .content = "push it" },
        .{ .role = .user, .content = injection.text },
    };
    try c.sync(&messages);
    cancel.store(false, .seq_cst);
    c.beginAttempt(&cancel);
    c.onToolStart("call_2", "shell", "{\"command\":\"git push --force\"}");
    try std.testing.expect(!cancel.load(.seq_cst));
}

test "a never-mode tool rule becomes a reminder on that call's result" {
    var f = Fixture.init();
    defer f.deinit();
    try f.add("py-print", "scope: 'tool:write_file(**/*.py)'\ninterruptMode: never\nmatch: { regex: 'print\\(', in: code }");
    const c = try f.coordinator(.{});
    defer c.deinit();
    var cancel = std.atomic.Value(bool).init(false);
    c.beginAttempt(&cancel);
    c.onToolStart("w1", "write_file", null);
    c.onToolInput("w1", "{\"path\":\"src/app.py\",\"content\":\"# print(x) in a comment\\nprint(x)\\n\"}");
    try std.testing.expect(!cancel.load(.seq_cst));
    const arena = f.arena_state.allocator();
    try std.testing.expect(try c.takeReminder(arena, "other") == null);
    const reminder = (try c.takeReminder(arena, "w1")).?;
    try std.testing.expect(std.mem.startsWith(u8, reminder.text, "<system-reminder reason=\"rule_violation\" rule=\"py-print\""));
    try std.testing.expect(std.mem.find(u8, reminder.text, "L2: print(x)") != null);
    try std.testing.expectEqualStrings("py-print · added to the tool result", reminder.notice);
    try std.testing.expect(try c.takeReminder(arena, "w1") == null);
}

test "a never-mode prose rule is deferred until the reply ends" {
    var f = Fixture.init();
    defer f.deinit();
    try f.add("no-hedge", "scope: text\ninterruptMode: never\nmatch: 'I think'");
    const c = try f.coordinator(.{});
    defer c.deinit();
    var cancel = std.atomic.Value(bool).init(false);
    c.beginAttempt(&cancel);
    c.onText("Well, I th");
    c.onText("ink it works.");
    try std.testing.expect(!cancel.load(.seq_cst));
    try std.testing.expect(c.hasDeferred());
    const deferred = (try c.takeDeferred(f.arena_state.allocator())).?;
    try std.testing.expect(std.mem.find(u8, deferred.text, "rule=\"no-hedge\"") != null);
    try std.testing.expectEqualStrings("no-hedge · added after the reply", deferred.notice);
    try std.testing.expect(!c.hasDeferred());
}

test "heredoc writes match in the written file's language" {
    var f = Fixture.init();
    defer f.deinit();
    try f.add("ts-any", "scope: tool:shell\nmatch: { if: { lang: [ts] }, then: { regex: ': any\\b', in: code } }");
    const c = try f.coordinator(.{});
    defer c.deinit();
    var cancel = std.atomic.Value(bool).init(false);
    c.beginAttempt(&cancel);
    c.onToolStart("s1", "shell", null);
    c.onToolInput("s1", "{\"command\":\"cat > a.ts <<'EOF'\\n// x: any\\nconst v: any = 1;\\nEOF\"}");
    try std.testing.expect(cancel.load(.seq_cst));
}

test "settled tool calls resolve ast and llm conditions" {
    var f = Fixture.init();
    defer f.deinit();
    try f.add("go-range", "scope: tool:write_file\ninterruptMode: never\nmatch: { all: [ { lang: [go] }, { ast: 'for $I := 0; $I < $N; $I++ { $$$BODY }' } ] }");
    try f.add("judged", "scope: text\ninterruptMode: never\nmatch: { all: [ { regex: 'done' }, { llm: 'Is the claim unsupported?' } ] }");
    const c = try f.coordinator(.{});
    defer c.deinit();
    const Yes = struct {
        fn ask(_: *anyopaque, _: evaluate.JudgeRequest) ?bool {
            return true;
        }
    };
    var dummy: u8 = 0;
    c.judge = .{ .ctx = &dummy, .ask = Yes.ask };
    var cancel = std.atomic.Value(bool).init(false);
    c.beginAttempt(&cancel);
    const args = "{\"path\":\"main.go\",\"content\":\"func f() { for i := 0; i < n; i++ { g(i) } }\"}";
    c.onToolStart("w1", "write_file", args);
    const arena = f.arena_state.allocator();
    try std.testing.expect(try c.takeReminder(arena, "w1") == null);
    try c.settleToolCall("w1", "write_file", args);
    try std.testing.expect((try c.takeReminder(arena, "w1")) != null);
    c.onText("All done.");
    try std.testing.expect(!c.hasDeferred());
    try c.settleProse("All done.");
    try std.testing.expect(c.hasDeferred());
}

test "repeat ledger: once never refires, after-gap refires after enough messages" {
    var f = Fixture.init();
    defer f.deinit();
    try f.add("no-hedge", "scope: text\nmatch: 'I think'");
    const arena = f.arena_state.allocator();
    const injection = (try @import("envelope.zig").renderAll(arena, .interrupt, &.{.{ .name = "no-hedge", .path = "p", .content = "c" }}));
    const history = [_]Message{
        .{ .role = .user, .content = "q" },
        .{ .role = .user, .content = injection },
        .{ .role = .assistant, .content = "a1" },
        .{ .role = .assistant, .content = "a2", .tool_calls = &.{.{ .name = "read_file", .arguments_json = "{\"path\":\"src/a.zig\"}" }} },
    };
    {
        const c = try f.coordinator(.{});
        defer c.deinit();
        try c.sync(&history);
        try std.testing.expectEqual(@as(usize, 1), c.history.len);
        try std.testing.expectEqualStrings("src/a.zig", c.history[0].paths[0]);
        var cancel = std.atomic.Value(bool).init(false);
        c.beginAttempt(&cancel);
        c.onText("I think so");
        try std.testing.expect(!cancel.load(.seq_cst));
    }
    {
        const c = try f.coordinator(.{ .repeat_mode = .after_gap, .repeat_gap = 2 });
        defer c.deinit();
        try c.sync(&history);
        var cancel = std.atomic.Value(bool).init(false);
        c.beginAttempt(&cancel);
        c.onText("I think so");
        try std.testing.expect(cancel.load(.seq_cst));
    }
    {
        const c = try f.coordinator(.{ .repeat_mode = .after_gap, .repeat_gap = 3 });
        defer c.deinit();
        try c.sync(&history);
        var cancel = std.atomic.Value(bool).init(false);
        c.beginAttempt(&cancel);
        c.onText("I think so");
        try std.testing.expect(!cancel.load(.seq_cst));
    }
}

test "interrupt modes split prose and tool sources, and attempts reset buffers" {
    var f = Fixture.init();
    defer f.deinit();
    try f.add("prose", "scope: [text, tool]\ninterruptMode: prose-only\nmatch: 'XYZ'");
    const c = try f.coordinator(.{});
    defer c.deinit();
    var cancel = std.atomic.Value(bool).init(false);
    c.beginAttempt(&cancel);
    c.onToolStart("t1", "web_search", "{\"query\":\"XYZ\"}");
    try std.testing.expect(!cancel.load(.seq_cst));
    try std.testing.expect((try c.takeReminder(f.arena_state.allocator(), "t1")) != null);
    c.beginAttempt(&cancel);
    c.onText("XY");
    c.beginAttempt(&cancel);
    c.onText("Z");
    try std.testing.expect(!cancel.load(.seq_cst));
    c.onText(" XYZ");
    try std.testing.expect(cancel.load(.seq_cst));
}
