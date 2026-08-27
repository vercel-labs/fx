const std = @import("std");
const types = @import("../../shared/types.zig");
const tool_dispatch = @import("../../tooling/tool_dispatch.zig");
const io_mod = @import("../../shared/io.zig");

const runtime_deps = @import("deps.zig");
const runtime_tool_contracts = @import("tool_contracts.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;
const PermissionGrant = types.PermissionGrant;
const ToolCall = types.ToolCall;
const AgentRuntimeDeps = runtime_deps.AgentRuntimeDeps;
const ToolExecutionResult = runtime_tool_contracts.ToolExecutionResult;

pub fn isReadOnlyCall(registry: tool_dispatch.Registry, call: ToolCall) bool {
    if (call.provider_result != null) return false;

    const tool = registry.lookup(call.name) orelse return false;
    return switch (tool.executor_kind) {
        .list_files, .glob_files => tool.activity_kind == .list,
        .read_file,
        .read_tool_result,
        .semantic_search,
        .grep_files,
        .file_info,
        .skill,
        .web_fetch,
        .web_search,
        => tool.activity_kind == .read,
        else => false,
    };
}

pub fn parallelReadOnlyPrefixLen(registry: tool_dispatch.Registry, calls: []const ToolCall) usize {
    var len: usize = 0;
    while (len < calls.len and isReadOnlyCall(registry, calls[len])) : (len += 1) {}
    return len;
}

pub const ParallelToolResult = struct {
    call_id: []const u8,
    tool_name: []const u8,
    execution: ToolExecutionResult,
};

pub const ParallelToolAttempt = union(enum) {
    completed: ParallelToolResult,
    cancelled,
};

pub const ParallelRunResult = struct {
    attempts: []ParallelToolAttempt,
    first_cancelled_index: ?usize = null,

    pub fn deinit(self: *ParallelRunResult, alloc: Allocator) void {
        for (self.attempts) |attempt| {
            switch (attempt) {
                .completed => |result| freeParallelToolResult(alloc, result),
                .cancelled => {},
            }
        }
        alloc.free(self.attempts);
        self.* = undefined;
    }
};

pub const ParallelHookExecContext = struct {
    hooks: *const AgentRuntimeDeps,
    turn_id: u64,
    root_user_intent_context: []const u8,
    current_turn_messages: []const ChatMessage,
    session_grants: []const PermissionGrant,
    permission_mode: types.PermissionMode,
    advertised_dynamic_tool_names: []const []const u8,
    max_tool_result_bytes: usize,
    classification_complete: []const bool = &.{},
};

const ParallelExecuteFn = *const fn (*anyopaque, Allocator, ToolCall, usize) anyerror!ToolExecutionResult;
const ParallelFormatErrorFn = *const fn (*anyopaque, Allocator, []const u8, anyerror) anyerror![]const u8;

pub const ParallelRunOptions = struct {
    exec_ctx: *anyopaque,
    execute: ParallelExecuteFn,
    format_ctx: *anyopaque,
    format_error: ParallelFormatErrorFn,
    cancel_flag: ?*std.atomic.Value(bool) = null,
};

const ParallelWorkerSlot = struct {
    arena_state: std.heap.ArenaAllocator,
    thread: ?std.Thread = null,
    result: ?ToolExecutionResult = null,
    err: ?anyerror = null,
    owner_cancelled_at_error: bool = false,
};

pub fn runSequentialReadOnlyCalls(
    alloc: Allocator,
    calls: []const ToolCall,
    options: ParallelRunOptions,
) Allocator.Error!ParallelRunResult {
    const attempts = try alloc.alloc(ParallelToolAttempt, calls.len);
    var initialized: usize = 0;
    errdefer {
        for (attempts[0..initialized]) |attempt| switch (attempt) {
            .completed => |result| freeParallelToolResult(alloc, result),
            .cancelled => {},
        };
        alloc.free(attempts);
    }

    var first_cancelled_index: ?usize = null;
    for (calls, 0..) |call, index| {
        if (options.cancel_flag) |flag| {
            if (flag.load(.seq_cst)) {
                attempts[index] = .cancelled;
                initialized += 1;
                if (first_cancelled_index == null) first_cancelled_index = index;
                continue;
            }
        }
        const execution = options.execute(options.exec_ctx, alloc, call, index) catch |err| blk: {
            const output = options.format_error(options.format_ctx, alloc, call.name, err) catch
                try std.fmt.allocPrint(alloc, "Tool execution failed: {s}", .{@errorName(err)});
            defer alloc.free(output);
            break :blk ToolExecutionResult{
                .status = .failure,
                .model_output = output,
            };
        };
        attempts[index] = .{
            .completed = try duplicateParallelToolResult(alloc, call, execution),
        };
        initialized += 1;
    }
    return .{ .attempts = attempts, .first_cancelled_index = first_cancelled_index };
}

pub fn runParallelReadOnlyCalls(
    alloc: Allocator,
    calls: []const ToolCall,
    options: ParallelRunOptions,
) Allocator.Error!ParallelRunResult {
    var slots = try alloc.alloc(ParallelWorkerSlot, calls.len);
    defer alloc.free(slots);

    for (slots) |*slot| {
        slot.* = .{ .arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator) };
    }
    defer {
        for (slots) |*slot| {
            if (slot.thread) |thread| thread.join();
            slot.arena_state.deinit();
        }
    }

    var started: usize = 0;
    for (calls, 0..) |call, index| {
        slots[index].thread = std.Thread.spawn(.{}, parallelWorkerMain, .{ &slots[index], options, call, index }) catch |err| {
            for (slots[0..started]) |*slot| {
                if (slot.thread) |thread| thread.join();
                slot.thread = null;
            }
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.OutOfMemory,
            };
        };
        started += 1;
    }

    for (slots) |*slot| {
        if (slot.thread) |thread| {
            thread.join();
            slot.thread = null;
        }
    }

    const attempts = try alloc.alloc(ParallelToolAttempt, calls.len);
    var initialized_count: usize = 0;
    errdefer {
        for (attempts[0..initialized_count]) |attempt| {
            switch (attempt) {
                .completed => |result| freeParallelToolResult(alloc, result),
                .cancelled => {},
            }
        }
        alloc.free(attempts);
    }

    var first_cancelled_index: ?usize = null;
    for (calls, slots, 0..) |call, *slot, index| {
        if (slot.err) |err| {
            if (err == error.Cancelled and slot.owner_cancelled_at_error) {
                attempts[index] = .cancelled;
                initialized_count += 1;
                if (first_cancelled_index == null) first_cancelled_index = index;
                continue;
            }
        }

        var formatted_failure: ?[]const u8 = null;
        defer if (formatted_failure) |output| alloc.free(output);
        const execution: ToolExecutionResult = if (slot.err) |err| .{
            .status = .failure,
            .model_output = blk: {
                const output = options.format_error(options.format_ctx, alloc, call.name, err) catch |format_err| try std.fmt.allocPrint(
                    alloc,
                    "Tool execution failed: {s}; additionally failed to format error: {s}",
                    .{ @errorName(err), @errorName(format_err) },
                );
                formatted_failure = output;
                break :blk output;
            },
        } else slot.result.?;
        attempts[index] = .{
            .completed = try duplicateParallelToolResult(alloc, call, execution),
        };
        initialized_count += 1;
    }

    return .{
        .attempts = attempts,
        .first_cancelled_index = first_cancelled_index,
    };
}

fn parallelWorkerMain(slot: *ParallelWorkerSlot, options: ParallelRunOptions, call: ToolCall, index: usize) void {
    if (cancelRequested(options.cancel_flag)) {
        slot.err = error.Cancelled;
        slot.owner_cancelled_at_error = true;
        return;
    }
    const worker_alloc = slot.arena_state.allocator();
    slot.result = options.execute(options.exec_ctx, worker_alloc, call, index) catch |err| {
        slot.err = err;
        slot.owner_cancelled_at_error =
            err == error.Cancelled and cancelRequested(options.cancel_flag);
        return;
    };
}

fn cancelRequested(cancel_flag: ?*std.atomic.Value(bool)) bool {
    return if (cancel_flag) |flag| flag.load(.seq_cst) else false;
}

pub fn parallelHookExecute(ctx: *anyopaque, alloc: Allocator, call: ToolCall, index: usize) !ToolExecutionResult {
    const exec_ctx: *ParallelHookExecContext = @ptrCast(@alignCast(ctx));
    return exec_ctx.hooks.execute_tool_call(exec_ctx.hooks.ctx, .{
        .call_allocator = alloc,
        .result_allocator = alloc,
        .call = call,
        .authority = .ordinary,
        .permission_mode = exec_ctx.permission_mode,
        .root_user_intent_context = exec_ctx.root_user_intent_context,
        .current_turn_messages = exec_ctx.current_turn_messages,
        .session_grants = exec_ctx.session_grants,
        .advertised_dynamic_tool_names = exec_ctx.advertised_dynamic_tool_names,
        .max_tool_result_bytes = exec_ctx.max_tool_result_bytes,
        .classification_complete = index < exec_ctx.classification_complete.len and
            exec_ctx.classification_complete[index],
        .lifecycle_id = .{ .turn_id = exec_ctx.turn_id, .call_id = call.id },
    });
}

pub fn parallelHookFormatError(ctx: *anyopaque, alloc: Allocator, tool_name: []const u8, err: anyerror) ![]const u8 {
    const exec_ctx: *ParallelHookExecContext = @ptrCast(@alignCast(ctx));
    return exec_ctx.hooks.format_tool_execution_error(exec_ctx.hooks.ctx, alloc, tool_name, err);
}

fn duplicateParallelToolResult(alloc: Allocator, call: ToolCall, execution: ToolExecutionResult) Allocator.Error!ParallelToolResult {
    const call_id = try alloc.dupe(u8, call.id);
    errdefer alloc.free(call_id);
    const tool_name = try alloc.dupe(u8, call.name);
    errdefer alloc.free(tool_name);

    if (execution.background_command != null or
        execution.diff_entry != null or
        execution.finish_turn or
        execution.selected_dynamic_tool_name != null or
        execution.selected_dynamic_tool_schema_json != null or
        execution.prepared_result_memory != null or
        execution.committed_file_handoff != null or
        execution.deferred_tool_completion != null)
    {
        return .{
            .call_id = call_id,
            .tool_name = tool_name,
            .execution = .{
                .status = .failure,
                .model_output = try alloc.dupe(u8, "Parallel read-only tool returned an unsupported side-effect payload."),
            },
        };
    }
    var duplicated_execution: ToolExecutionResult = .{
        .status = execution.status,
        .model_output = try alloc.dupe(u8, execution.model_output),
        .web_search_completion = execution.web_search_completion,
        .web_fetch_completion = execution.web_fetch_completion,
        .inner_usage = execution.inner_usage,
    };
    errdefer freeOwnedToolExecutionResult(alloc, duplicated_execution);
    if (execution.status_detail) |detail| {
        duplicated_execution.status_detail = try alloc.dupe(u8, detail);
    }
    if (execution.display_output) |display| {
        duplicated_execution.display_output = try alloc.dupe(u8, display);
    }
    if (execution.system_notice) |notice| {
        duplicated_execution.system_notice = try alloc.dupe(u8, notice);
    }
    if (execution.interactive_notice) |notice| {
        duplicated_execution.interactive_notice = try types.dupeSemanticNotice(alloc, notice);
    }
    duplicated_execution.context_notices = try duplicateContextNotices(alloc, execution.context_notices);
    if (execution.command_result_json) |json| {
        duplicated_execution.command_result_json = try alloc.dupe(u8, json);
    }
    duplicated_execution.tool_result_memory = try duplicateToolResultMemory(
        alloc,
        execution.tool_result_memory,
    );

    return .{
        .call_id = call_id,
        .tool_name = tool_name,
        .execution = duplicated_execution,
    };
}

fn duplicateToolResultMemory(
    alloc: Allocator,
    source: ?types.ToolResultMemory,
) Allocator.Error!?types.ToolResultMemory {
    const memory = source orelse return null;
    const output_handle = if (memory.output_handle) |handle|
        try alloc.dupe(u8, handle)
    else
        null;
    errdefer if (output_handle) |handle| alloc.free(handle);
    const preview = if (memory.preview) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (preview) |value| alloc.free(value);
    const command_output_replay = if (memory.command_output_replay) |replay|
        try types.dupeCommandOutputReplay(alloc, replay)
    else
        null;
    errdefer if (command_output_replay) |replay| types.freeCommandOutputReplay(alloc, replay);

    return .{
        .output_handle = output_handle,
        .preview = preview,
        .output_bytes = memory.output_bytes,
        .stored_output_bytes = memory.stored_output_bytes,
        .truncated = memory.truncated,
        .model_view_covers_full_file = memory.model_view_covers_full_file,
        .command_output_replay = command_output_replay,
        .command_process_presentation = memory.command_process_presentation,
    };
}

pub fn reportInnerToolUsage(hooks: *const AgentRuntimeDeps, tool_name: []const u8, execution: ToolExecutionResult) void {
    const usage = execution.inner_usage orelse return;
    const report = hooks.report_inner_tool_usage orelse return;
    report(hooks.ctx, tool_name, usage);
}

fn freeParallelToolResult(alloc: Allocator, result: ParallelToolResult) void {
    alloc.free(result.call_id);
    alloc.free(result.tool_name);
    freeOwnedToolExecutionResult(alloc, result.execution);
}

fn freeOwnedToolExecutionResult(alloc: Allocator, result: ToolExecutionResult) void {
    alloc.free(result.model_output);
    if (result.status_detail) |value| alloc.free(value);
    if (result.display_output) |value| alloc.free(value);
    if (result.system_notice) |value| alloc.free(value);
    if (result.interactive_notice) |notice| types.freeSemanticNotice(alloc, notice);
    freeContextNotices(alloc, result.context_notices);
    if (result.command_result_json) |value| alloc.free(value);
    if (result.tool_result_memory) |memory| {
        if (memory.output_handle) |value| alloc.free(value);
        if (memory.preview) |value| alloc.free(value);
        if (memory.command_output_replay) |replay| {
            types.freeCommandOutputReplay(alloc, replay);
        }
    }
}

fn duplicateContextNotices(alloc: Allocator, notices: []const []const u8) Allocator.Error![]const []const u8 {
    if (notices.len == 0) return &.{};

    const duplicated = try alloc.alloc([]const u8, notices.len);
    var copied: usize = 0;
    errdefer {
        for (duplicated[0..copied]) |notice| alloc.free(notice);
        alloc.free(duplicated);
    }
    for (notices, 0..) |notice, i| {
        duplicated[i] = try alloc.dupe(u8, notice);
        copied += 1;
    }
    return duplicated;
}

fn freeContextNotices(alloc: Allocator, notices: []const []const u8) void {
    for (notices) |notice| alloc.free(notice);
    if (notices.len > 0) alloc.free(notices);
}

const ParallelTestPlan = struct {
    output: []const u8 = "",
    err: ?anyerror = null,
    delay_ms: u64 = 0,
    cancel: bool = false,
};

const ParallelTestFixture = struct {
    plans: []const ParallelTestPlan,
    cancel_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    in_flight: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    max_in_flight: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
};

fn runParallelReadOnlyCallsForTest(
    alloc: Allocator,
    calls: []const ToolCall,
    fixture: *ParallelTestFixture,
) Allocator.Error!ParallelRunResult {
    return runParallelReadOnlyCalls(alloc, calls, .{
        .exec_ctx = fixture,
        .execute = parallelTestExecute,
        .format_ctx = fixture,
        .format_error = parallelTestFormatError,
        .cancel_flag = &fixture.cancel_flag,
    });
}

fn parallelTestExecute(ctx: *anyopaque, alloc: Allocator, call: ToolCall, index: usize) !ToolExecutionResult {
    _ = call;
    const fixture: *ParallelTestFixture = @ptrCast(@alignCast(ctx));
    const in_flight = fixture.in_flight.fetchAdd(1, .seq_cst) + 1;
    updateMaxInFlight(&fixture.max_in_flight, in_flight);
    defer _ = fixture.in_flight.fetchSub(1, .seq_cst);

    const plan = fixture.plans[index];
    if (plan.delay_ms > 0) io_mod.sleep(plan.delay_ms * std.time.ns_per_ms);
    if (plan.cancel) fixture.cancel_flag.store(true, .seq_cst);
    if (plan.err) |err| return err;
    return .{ .status = .success, .model_output = try alloc.dupe(u8, plan.output) };
}

fn updateMaxInFlight(max_in_flight: *std.atomic.Value(usize), candidate: usize) void {
    var current = max_in_flight.load(.seq_cst);
    while (candidate > current) {
        const result = max_in_flight.cmpxchgWeak(current, candidate, .seq_cst, .seq_cst);
        if (result == null) return;
        current = result.?;
    }
}

fn parallelTestFormatError(_: *anyopaque, alloc: Allocator, tool_name: []const u8, err: anyerror) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s} failed with {s}", .{ tool_name, @errorName(err) });
}

fn toolCall(id: []const u8, name: []const u8, args: []const u8) ToolCall {
    return .{ .id = id, .name = name, .arguments_json = args };
}

test "parallel classifier uses active registry metadata" {
    const builtin_tools = @import("../../../builtins/tools.zig");
    const calls = [_]ToolCall{toolCall("read", "read_file", "{\"path\":\"README.md\"}")};
    const tools = [_]tool_dispatch.Tool{builtin_tools.read_file};
    const active_registry = tool_dispatch.Registry{ .tools = &tools };
    const empty_registry = tool_dispatch.Registry{};
    var mislabeled_read = builtin_tools.read_file;
    mislabeled_read.activity_kind = .write;
    const mislabeled_tools = [_]tool_dispatch.Tool{mislabeled_read};
    const mislabeled_registry = tool_dispatch.Registry{ .tools = &mislabeled_tools };

    try std.testing.expectEqual(@as(usize, 1), parallelReadOnlyPrefixLen(active_registry, &calls));
    try std.testing.expectEqual(@as(usize, 0), parallelReadOnlyPrefixLen(empty_registry, &calls));
    try std.testing.expectEqual(@as(usize, 0), parallelReadOnlyPrefixLen(mislabeled_registry, &calls));
}

test "parallel classifier keeps only a leading safe read-only group" {
    const builtin_tools = @import("../../../builtins/tools.zig");
    const tools = [_]tool_dispatch.Tool{
        builtin_tools.read_file,
        builtin_tools.grep_files,
        builtin_tools.write_file,
    };
    const registry = tool_dispatch.Registry{ .tools = &tools };
    const calls = [_]ToolCall{
        toolCall("read_1", "read_file", "{\"path\":\"src/main.zig\"}"),
        toolCall("grep_1", "grep_files", "{\"pattern\":\"processQueuedPrompt\"}"),
        toolCall("write_1", "write_file", "{\"path\":\"tmp.txt\",\"content\":\"x\"}"),
        toolCall("read_2", "read_file", "{\"path\":\"README.md\"}"),
    };

    try std.testing.expectEqual(@as(usize, 2), parallelReadOnlyPrefixLen(registry, &calls));
    try std.testing.expect(isReadOnlyCall(registry, calls[0]));
    try std.testing.expect(isReadOnlyCall(registry, calls[1]));
    try std.testing.expect(!isReadOnlyCall(registry, calls[2]));
}

test "parallel classifier admits approval-bearing web fetch read groups" {
    const builtin_tools = @import("../../../builtins/tools.zig");
    const tools = [_]tool_dispatch.Tool{
        builtin_tools.web_fetch,
        builtin_tools.read_file,
    };
    const registry = tool_dispatch.Registry{ .tools = &tools };
    const calls = [_]ToolCall{
        toolCall("fetch_1", "web_fetch", "{\"url\":\"https://example.com\"}"),
        toolCall("read_1", "read_file", "{\"path\":\"README.md\"}"),
    };

    try std.testing.expectEqual(@as(usize, 2), parallelReadOnlyPrefixLen(registry, &calls));
}

test "parallel classifier admits installed skill reads" {
    const builtin_tools = @import("../../../builtins/tools.zig");
    const tools = [_]tool_dispatch.Tool{builtin_tools.skill};
    const registry = tool_dispatch.Registry{ .tools = &tools };
    const calls = [_]ToolCall{toolCall(
        "skill_1",
        "skill",
        "{\"name\":\"demo\",\"location\":\"/tmp/demo\",\"resource\":\"SKILL.md\"}",
    )};

    try std.testing.expectEqual(@as(usize, 1), parallelReadOnlyPrefixLen(registry, &calls));
    try std.testing.expect(isReadOnlyCall(registry, calls[0]));
}

test "parallel classifier rejects prompts approvals dynamic tools and mutations" {
    const builtin_tools = @import("../../../builtins/tools.zig");
    const tools = [_]tool_dispatch.Tool{
        builtin_tools.ask_user_question,
        builtin_tools.mcp_select_tool,
        builtin_tools.subagent,
        builtin_tools.install_skill,
        builtin_tools.terminal,
        builtin_tools.read_file,
    };
    const registry = tool_dispatch.Registry{ .tools = &tools };
    const cases = [_]ToolCall{
        toolCall("ask_1", "ask_user_question", "{\"questions\":[]}"),
        toolCall("mcp_1", "mcp_select_tool", "{\"name\":\"tool\"}"),
        toolCall("subagent_1", "subagent", "{\"command\":{\"inspect\":{\"id\":\"01J00000000000000000000000\",\"sections\":[\"status\"]}}}"),
        toolCall("skill_1", "install_skill", "{\"source\":\"repo\"}"),
        toolCall("browser_1", "browser_snapshot", "{}"),
        toolCall("command_1", "run_command", "{\"command\":\"git status --short\"}"),
        toolCall("unknown_1", "dynamic_mcp_tool", "{}"),
    };

    for (cases) |call| {
        try std.testing.expect(!isReadOnlyCall(registry, call));
    }

    var provider_call = toolCall("provider_1", "read_file", "{\"path\":\"README.md\"}");
    provider_call.provider_result = "provider result";
    try std.testing.expect(!isReadOnlyCall(registry, provider_call));
}

test "parallel read-only execution preserves order and failure fan-in" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{
        toolCall("first", "read_file", "{\"path\":\"a\"}"),
        toolCall("second", "grep_files", "{\"pattern\":\"b\"}"),
        toolCall("third", "file_info", "{\"path\":\"c\"}"),
    };
    const plans = [_]ParallelTestPlan{
        .{ .output = "first output", .delay_ms = 20 },
        .{ .err = error.TestExpectedEqual, .delay_ms = 5 },
        .{ .output = "third output", .delay_ms = 1 },
    };
    var fixture = ParallelTestFixture{ .plans = &plans };

    var run = try runParallelReadOnlyCallsForTest(alloc, &calls, &fixture);
    defer run.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 3), run.attempts.len);
    try std.testing.expectEqualStrings("first", run.attempts[0].completed.call_id);
    try std.testing.expectEqualStrings("first output", run.attempts[0].completed.execution.model_output);
    try std.testing.expectEqualStrings("second", run.attempts[1].completed.call_id);
    try std.testing.expectEqual(.failure, run.attempts[1].completed.execution.status);
    try std.testing.expect(std.mem.find(u8, run.attempts[1].completed.execution.model_output, "TestExpectedEqual") != null);
    try std.testing.expectEqualStrings("third", run.attempts[2].completed.call_id);
    try std.testing.expectEqualStrings("third output", run.attempts[2].completed.execution.model_output);
    try std.testing.expect(run.first_cancelled_index == null);
    try std.testing.expect(fixture.max_in_flight.load(.seq_cst) > 1);
}

test "parallel read-only execution preserves exact cancelled identity and completed peers" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{
        toolCall("first", "read_file", "{\"path\":\"a\"}"),
        toolCall("second", "grep_files", "{\"pattern\":\"b\"}"),
        toolCall("third", "file_info", "{\"path\":\"c\"}"),
    };
    const plans = [_]ParallelTestPlan{
        .{ .output = "first output", .delay_ms = 10 },
        .{ .err = error.Cancelled, .delay_ms = 5, .cancel = true },
        .{ .output = "third output", .delay_ms = 20 },
    };
    var fixture = ParallelTestFixture{ .plans = &plans };

    var run = try runParallelReadOnlyCallsForTest(alloc, &calls, &fixture);
    defer run.deinit(alloc);

    try std.testing.expect(fixture.cancel_flag.load(.seq_cst));
    try std.testing.expectEqual(@as(?usize, 1), run.first_cancelled_index);
    try std.testing.expectEqualStrings("first", run.attempts[0].completed.call_id);
    try std.testing.expect(run.attempts[1] == .cancelled);
    try std.testing.expectEqualStrings("third", run.attempts[2].completed.call_id);
    try std.testing.expectEqual(@as(usize, 0), fixture.in_flight.load(.seq_cst));
}

test "parallel workers start no execution when owner cancellation is already set" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{
        toolCall("first", "read_file", "{\"path\":\"a\"}"),
        toolCall("second", "grep_files", "{\"pattern\":\"b\"}"),
    };
    const plans = [_]ParallelTestPlan{
        .{ .output = "must not execute" },
        .{ .output = "must not execute" },
    };
    var fixture = ParallelTestFixture{ .plans = &plans };
    fixture.cancel_flag.store(true, .seq_cst);

    var run = try runParallelReadOnlyCallsForTest(alloc, &calls, &fixture);
    defer run.deinit(alloc);

    try std.testing.expectEqual(@as(?usize, 0), run.first_cancelled_index);
    try std.testing.expect(run.attempts[0] == .cancelled);
    try std.testing.expect(run.attempts[1] == .cancelled);
    try std.testing.expectEqual(@as(usize, 0), fixture.max_in_flight.load(.seq_cst));
}

test "parallel read-only execution does not relabel earlier ordinary cancellation" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{
        toolCall("first", "read_file", "{\"path\":\"a\"}"),
        toolCall("second", "grep_files", "{\"pattern\":\"b\"}"),
        toolCall("third", "file_info", "{\"path\":\"c\"}"),
    };
    const plans = [_]ParallelTestPlan{
        .{ .err = error.Cancelled, .delay_ms = 1 },
        .{ .output = "second output", .delay_ms = 50, .cancel = true },
        .{ .output = "third output", .delay_ms = 10 },
    };
    var fixture = ParallelTestFixture{ .plans = &plans };

    var run = try runParallelReadOnlyCallsForTest(alloc, &calls, &fixture);
    defer run.deinit(alloc);

    try std.testing.expect(fixture.cancel_flag.load(.seq_cst));
    try std.testing.expect(run.first_cancelled_index == null);
    try std.testing.expectEqual(.failure, run.attempts[0].completed.execution.status);
    try std.testing.expect(std.mem.find(
        u8,
        run.attempts[0].completed.execution.model_output,
        "Cancelled",
    ) != null);
    try std.testing.expectEqualStrings(
        "second output",
        run.attempts[1].completed.execution.model_output,
    );
    try std.testing.expectEqualStrings(
        "third output",
        run.attempts[2].completed.execution.model_output,
    );
}

test "parallel read-only execution reports no active call when cancellation follows completed attempts" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{
        toolCall("first", "read_file", "{\"path\":\"a\"}"),
        toolCall("second", "grep_files", "{\"pattern\":\"b\"}"),
    };
    const plans = [_]ParallelTestPlan{
        .{ .output = "first output", .delay_ms = 5, .cancel = true },
        .{ .output = "second output", .delay_ms = 10 },
    };
    var fixture = ParallelTestFixture{ .plans = &plans };

    var run = try runParallelReadOnlyCallsForTest(alloc, &calls, &fixture);
    defer run.deinit(alloc);

    try std.testing.expect(fixture.cancel_flag.load(.seq_cst));
    try std.testing.expect(run.first_cancelled_index == null);
    try std.testing.expect(run.attempts[0] == .completed);
    try std.testing.expect(run.attempts[1] == .completed);
}

fn checkParallelResultDuplicationAllocationFailures(alloc: Allocator) !void {
    const call = toolCall(
        "call_read",
        "read_file",
        "{\"path\":\"notes.txt\"}",
    );
    const execution: ToolExecutionResult = .{
        .model_output = "contents",
        .status_detail = "detail",
        .display_output = "display",
        .system_notice = "notice",
        .interactive_notice = .{
            .topic = "background",
            .tone = .information,
            .body = "Command #7 started. Log: /tmp/run.log",
        },
        .context_notices = &.{ "first context notice", "second context notice" },
        .command_result_json = "{}",
        .tool_result_memory = .{
            .output_handle = "result-handle",
            .preview = "preview",
            .output_bytes = 8,
            .stored_output_bytes = 8,
            .model_view_covers_full_file = true,
        },
    };
    const duplicated = try duplicateParallelToolResult(
        alloc,
        call,
        execution,
    );
    defer freeParallelToolResult(alloc, duplicated);
    try std.testing.expectEqualStrings("notice", duplicated.execution.system_notice.?);
    const interactive_notice = duplicated.execution.interactive_notice.?;
    try std.testing.expectEqualStrings("background", interactive_notice.topic);
    try std.testing.expectEqual(types.NoticeTone.information, interactive_notice.tone);
    try std.testing.expectEqualStrings("Command #7 started. Log: /tmp/run.log", interactive_notice.body);
    try std.testing.expectEqual(@as(usize, 2), duplicated.execution.context_notices.len);
    try std.testing.expectEqualStrings("first context notice", duplicated.execution.context_notices[0]);
    try std.testing.expectEqualStrings("second context notice", duplicated.execution.context_notices[1]);
}

test "parallel result duplication cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkParallelResultDuplicationAllocationFailures,
        .{},
    );
}
