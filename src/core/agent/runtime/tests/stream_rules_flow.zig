//! Stream rules (TTSR) through the agent loop: an interrupt mid tool-call
//! stream retries with the rule, a reply's prose rule joins the turn after
//! it, a tool rule that does not interrupt follows the result, and a saved
//! injection keeps its rule from firing again after a resume (D175-D179).
const std = @import("std");
const types = @import("../../../shared/types.zig");
const io_mod = @import("../../../shared/io.zig");
const test_support = @import("support.zig");

const ToolCall = types.ToolCall;
const FakeGateway = test_support.FakeGateway;
const FakeCompletion = test_support.FakeCompletion;
const FakeAgentRuntimeDeps = test_support.FakeAgentRuntimeDeps;
const PromptFixture = test_support.PromptFixture;
const runFakePrompt = test_support.runFakePrompt;
const logIndex = test_support.logIndex;

const Workspace = struct {
    tmp: std.testing.TmpDir,
    root: []u8,

    fn init(rules: []const struct { []const u8, []const u8 }) !Workspace {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const io = io_mod.getIo();
        try tmp.dir.createDirPath(io, ".proto-fx/rules");
        for (rules) |rule| {
            var name_buf: [128]u8 = undefined;
            const path = try std.mem.print(&name_buf, ".proto-fx/rules/{s}.md", .{rule[0]});
            try tmp.dir.writeFile(io, .{ .sub_path = path, .data = rule[1] });
        }
        return .{ .tmp = tmp, .root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".") };
    }

    fn deinit(self: *Workspace) void {
        std.testing.allocator.free(self.root);
        self.tmp.cleanup();
    }
};

const no_force_rule =
    \\---
    \\description: Never force-push
    \\scope: tool:shell
    \\match: 'git push --force'
    \\---
    \\Never force-push; use --force-with-lease after confirming.
;

const force_call = [_]ToolCall{.{
    .id = "call_force",
    .name = "shell",
    .arguments_json = "{\"action\":\"run\",\"command\":\"git push --force origin main\"}",
}};

fn steeringOf(turn: types.HistoryTurn) []const types.PersistedSteering {
    return switch (turn) {
        .assistant => |entry| entry.execution.steering,
        .interrupted => |entry| entry.execution.steering,
        .compacted_summary => &.{},
    };
}

test "a rule that matches streaming tool arguments interrupts and the step retries with it" {
    const alloc = std.testing.allocator;
    var workspace = try Workspace.init(&.{.{ "no-force", no_force_rule }});
    defer workspace.deinit();
    var gateway = FakeGateway.init(alloc, &[_]FakeCompletion{
        .{ .chunks = &.{"Pushing now."}, .streamed_tool_inputs = &force_call, .tool_calls = &force_call, .honor_cancel = true },
        .{ .content = "I will not force-push; use --force-with-lease instead." },
    });
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    hooks.ttsr_enabled = true;
    var fixture = PromptFixture{ .workspace_root = workspace.root };

    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

    try std.testing.expectEqual(@as(usize, 2), gateway.request_bodies.items.len);
    const retry = gateway.request_bodies.items[1];
    try std.testing.expect(std.mem.find(u8, retry, "system-interrupt reason=\\\"rule_violation\\\" rule=\\\"no-force\\\"") != null);
    // Discard mode: the interrupted reply and its call never reach the model.
    try std.testing.expect(std.mem.find(u8, retry, "call_force") == null);
    try std.testing.expect(std.mem.find(u8, retry, "Pushing now.") == null);
    try std.testing.expect(!fixture.cancel_flag.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), hooks.executed_names.items.len);
    try std.testing.expect(logIndex(&hooks, "rule_notice:no-force · Never force-push · response restarted") != null);
    try std.testing.expectEqual(@as(usize, 1), hooks.history_turns.items.len);
    const steering = steeringOf(hooks.history_turns.items[0]);
    try std.testing.expectEqual(@as(usize, 1), steering.len);
    try std.testing.expect(std.mem.startsWith(u8, steering[0].text, "<system-interrupt reason=\"rule_violation\" rule=\"no-force\""));
}

test "a saved injection keeps its rule from firing again after resume" {
    const alloc = std.testing.allocator;
    var workspace = try Workspace.init(&.{.{ "no-force", no_force_rule }});
    defer workspace.deinit();
    var first_gateway = FakeGateway.init(alloc, &[_]FakeCompletion{
        .{ .streamed_tool_inputs = &force_call, .tool_calls = &force_call, .honor_cancel = true },
        .{ .content = "Understood." },
    });
    defer first_gateway.deinit();
    var first = FakeAgentRuntimeDeps.init(alloc);
    defer first.deinit();
    first.ttsr_enabled = true;
    var first_fixture = PromptFixture{ .workspace_root = workspace.root };
    try runFakePrompt(&first_gateway, &first, first_fixture.config(), first_fixture.job());
    try std.testing.expectEqual(@as(usize, 2), first_gateway.request_bodies.items.len);

    // The next turn carries the saved turn as history: the rule is spent,
    // so the same call now runs.
    var gateway = FakeGateway.init(alloc, &[_]FakeCompletion{
        .{ .streamed_tool_inputs = &force_call, .tool_calls = &force_call, .honor_cancel = true },
        .{ .content = "Pushed." },
    });
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    hooks.ttsr_enabled = true;
    hooks.exec_plans = &.{.{ .result = .{ .model_output = "rejected: no remote" } }};
    var fixture = PromptFixture{ .workspace_root = workspace.root };
    var job = fixture.job();
    job.history = first.history_turns.items;
    try runFakePrompt(&gateway, &hooks, fixture.config(), job);
    try std.testing.expectEqual(@as(usize, 2), gateway.request_bodies.items.len);
    try std.testing.expectEqual(@as(usize, 1), hooks.executed_names.items.len);
    try std.testing.expect(logIndex(&hooks, "rule_notice:no-force · Never force-push · response restarted") == null);
}

test "a prose rule that does not interrupt joins the turn after the reply" {
    const alloc = std.testing.allocator;
    var workspace = try Workspace.init(&.{.{
        "no-todo",
        \\---
        \\scope: text
        \\interruptMode: never
        \\match: '\bTODO\b'
        \\---
        \\Do not hand the user a TODO.
    }});
    defer workspace.deinit();
    var gateway = FakeGateway.init(alloc, &[_]FakeCompletion{
        .{ .chunks = &.{ "Remaining: TO", "DO later." }, .content = "Remaining: TODO later.", .honor_cancel = true },
        .{ .content = "Nothing is left." },
    });
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    hooks.ttsr_enabled = true;
    var fixture = PromptFixture{ .workspace_root = workspace.root };

    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

    try std.testing.expectEqual(@as(usize, 2), gateway.request_bodies.items.len);
    const follow_up = gateway.request_bodies.items[1];
    const reply_at = std.mem.find(u8, follow_up, "Remaining: TODO later.") orelse return error.TestExpectedReply;
    const rule_at = std.mem.find(u8, follow_up, "rule=\\\"no-todo\\\"") orelse return error.TestExpectedRule;
    try std.testing.expect(reply_at < rule_at);
    try std.testing.expect(logIndex(&hooks, "rule_notice:no-todo · added after the reply") != null);
}

test "a tool rule that does not interrupt follows the call's result" {
    const alloc = std.testing.allocator;
    var workspace = try Workspace.init(&.{.{
        "ls-hint",
        \\---
        \\scope: tool:shell
        \\interruptMode: never
        \\match: 'ls -la'
        \\---
        \\Prefer read_file for listings.
    }});
    defer workspace.deinit();
    const ls_call = [_]ToolCall{.{ .id = "call_ls", .name = "shell", .arguments_json = "{\"action\":\"run\",\"command\":\"ls -la\"}" }};
    var gateway = FakeGateway.init(alloc, &[_]FakeCompletion{
        .{ .streamed_tool_inputs = &ls_call, .tool_calls = &ls_call, .honor_cancel = true },
        .{ .content = "Listed." },
    });
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    hooks.ttsr_enabled = true;
    hooks.exec_plans = &.{.{ .result = .{ .model_output = "a.txt" } }};
    var fixture = PromptFixture{ .workspace_root = workspace.root };

    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

    try std.testing.expectEqual(@as(usize, 1), hooks.executed_names.items.len);
    try std.testing.expectEqual(@as(usize, 2), gateway.request_bodies.items.len);
    const next = gateway.request_bodies.items[1];
    const result_at = std.mem.find(u8, next, "a.txt") orelse return error.TestExpectedResult;
    const reminder_at = std.mem.find(u8, next, "system-reminder reason=\\\"rule_violation\\\" rule=\\\"ls-hint\\\"") orelse return error.TestExpectedReminder;
    try std.testing.expect(result_at < reminder_at);
    try std.testing.expect(logIndex(&hooks, "rule_notice:ls-hint · added to the tool result") != null);
}
