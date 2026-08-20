const std = @import("std");
const debug_trace = @import("../../shared/debug_trace.zig");
const types = @import("../../shared/types.zig");
const execution_memory_helpers = @import("../execution_memory.zig");
const result_store = @import("../../session/result_store.zig");
const command_replay_store = @import("../../session/command_replay_store.zig");
const session_child_store = @import("../../session/session_child_store.zig");
const command_output_content = @import("../../tooling/command_output_content.zig");
const io_mod = @import("../../shared/io.zig");
const file_mutation = @import("../../tooling/file_mutation.zig");
const tool_result_errors = @import("../../tooling/tool_result_errors.zig");
const tool_result_limits = @import("../../tooling/tool_result_limits.zig");

const runtime_config = @import("config.zig");
const runtime_tool_contracts = @import("tool_contracts.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;
const ToolCall = types.ToolCall;
const Config = runtime_config.Config;
const ToolExecutionStatus = runtime_tool_contracts.ToolExecutionStatus;

pub fn persistedStatusForCurrentFxLocalResult(
    status: ToolExecutionStatus,
    output: []const u8,
) types.PersistedToolStatus {
    if (status == .failure) return .failure;
    return if (tool_result_errors.isToolOutputError(output)) .failure else .success;
}

pub fn classifyProviderExecutedResultStatus(output: []const u8) types.PersistedToolStatus {
    return if (tool_result_errors.isToolOutputError(output)) .failure else .success;
}

pub fn buildExecutionMemory(alloc: Allocator, within_turn_suffix: []const ChatMessage) !types.ExecutionMemory {
    return execution_memory_helpers.buildNormalChatExecutionMemory(
        alloc,
        within_turn_suffix,
    );
}

pub fn buildInterruptedExecutionMemory(
    alloc: Allocator,
    current_turn_messages: []const ChatMessage,
    active_tool_call: ?ToolCall,
) !types.ExecutionMemory {
    var filtered: std.ArrayList(ChatMessage) = .empty;
    defer filtered.deinit(alloc);
    try filtered.ensureTotalCapacity(alloc, current_turn_messages.len);
    var allocated_call_slices: std.ArrayList([]ToolCall) = .empty;
    defer {
        for (allocated_call_slices.items) |calls| alloc.free(calls);
        allocated_call_slices.deinit(alloc);
    }

    var i: usize = 0;
    while (i < current_turn_messages.len) {
        const item = current_turn_messages[i];
        if (item.role != .assistant or item.tool_calls.len == 0) {
            i += 1;
            continue;
        }

        var result_end = i + 1;
        while (result_end < current_turn_messages.len and
            current_turn_messages[result_end].role == .tool) : (result_end += 1)
        {}
        const result_messages = current_turn_messages[i + 1 .. result_end];
        var user_tail_end = result_end;
        while (user_tail_end < current_turn_messages.len and
            current_turn_messages[user_tail_end].role == .user) : (user_tail_end += 1)
        {}
        const user_tail = current_turn_messages[result_end..user_tail_end];

        var completed_count: usize = 0;
        for (item.tool_calls) |call| {
            if (active_tool_call) |active| {
                if (std.mem.eql(u8, call.id, active.id)) continue;
            }
            if (hasToolResultForCall(result_messages, call.id)) {
                completed_count += 1;
            }
        }

        if (completed_count > 0) {
            const calls = try alloc.alloc(ToolCall, completed_count);
            errdefer alloc.free(calls);
            try allocated_call_slices.append(alloc, calls);

            var completed_index: usize = 0;
            for (item.tool_calls) |call| {
                if (active_tool_call) |active| {
                    if (std.mem.eql(u8, call.id, active.id)) continue;
                }
                if (!hasToolResultForCall(result_messages, call.id)) continue;
                calls[completed_index] = call;
                completed_index += 1;
            }

            var projected = item;
            projected.tool_calls = calls;
            filtered.appendAssumeCapacity(projected);
            for (result_messages) |result| {
                const result_call_id = result.tool_call_id orelse continue;
                if (execution_memory_helpers.findToolCallById(
                    calls,
                    result_call_id,
                ) != null) {
                    filtered.appendAssumeCapacity(result);
                }
            }
            for (user_tail) |entry| {
                if (!entry.permission_feedback) continue;
                if (entry.tool_call_id) |source_tool_call_id| {
                    if (execution_memory_helpers.findToolCallById(calls, source_tool_call_id) == null) {
                        continue;
                    }
                }
                filtered.appendAssumeCapacity(entry);
            }
        }
        i = user_tail_end;
    }

    return buildExecutionMemory(alloc, filtered.items);
}

test "interrupted execution memory retains marked feedback through mixed user tail" {
    const alloc = std.testing.allocator;
    var calls = [_]ToolCall{
        .{ .id = "call_first", .name = "run_command", .arguments_json = "{\"command\":\"printf first\"}" },
        .{ .id = "call_second", .name = "run_command", .arguments_json = "{\"command\":\"printf second\"}" },
        .{ .id = "call_active", .name = "run_command", .arguments_json = "{\"command\":\"printf active\"}" },
    };
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = calls[0..] },
        .{ .role = .tool, .content = "first command completed", .tool_call_id = calls[0].id, .tool_name = calls[0].name, .tool_result_status = .success },
        .{ .role = .tool, .content = "second command completed", .tool_call_id = calls[1].id, .tool_name = calls[1].name, .tool_result_status = .success },
        .{ .role = .user, .content = "first command feedback marker", .tool_call_id = calls[0].id, .permission_feedback = true },
        .{ .role = .user, .content = "sandbox hint", .permission_feedback = false },
        .{ .role = .user, .content = "second command feedback marker", .tool_call_id = calls[1].id, .permission_feedback = true },
    };

    const memory = try buildInterruptedExecutionMemory(alloc, &messages, calls[2]);
    defer types.freeExecutionMemory(alloc, memory);

    const results = memory.tool_steps[0].tool_results;
    try std.testing.expectEqual(@as(usize, 1), results[0].permission_feedback.len);
    try std.testing.expectEqualStrings("first command feedback marker", results[0].permission_feedback[0]);
    try std.testing.expectEqual(@as(usize, 1), results[1].permission_feedback.len);
    try std.testing.expectEqualStrings("second command feedback marker", results[1].permission_feedback[0]);
}

fn hasToolResultForCall(
    result_messages: []const ChatMessage,
    call_id: []const u8,
) bool {
    for (result_messages) |result| {
        if (result.tool_call_id) |result_call_id| {
            if (std.mem.eql(u8, result_call_id, call_id)) return true;
        }
    }
    return false;
}

pub fn prepareToolModelOutput(arena: Allocator, config: Config, tool_call: ToolCall, raw_output: []const u8) !result_store.PreparedResult {
    if ((config.session_child_capability != null or config.tool_result_dir != null) and
        raw_output.len > result_store.large_result_threshold_bytes)
    {
        const redacted_output = try execution_memory_helpers.redactText(
            arena,
            raw_output,
        );
        if (config.session_child_capability != null) {
            return result_store.prepareManaged(
                arena,
                config.session_child_capability,
                tool_call.id,
                tool_call.name,
                raw_output.len,
                redacted_output,
                config.max_tool_result_bytes,
            );
        }
        return result_store.prepare(
            arena,
            config.tool_result_dir,
            tool_call.id,
            tool_call.name,
            raw_output.len,
            redacted_output,
            config.max_tool_result_bytes,
        );
    }
    const safe_output = try tool_result_limits.prepareModelOutput(
        arena,
        tool_call.name,
        raw_output,
        config.max_tool_result_bytes,
    );
    return .{
        .model_output = safe_output,
        .memory = .{
            .output_bytes = raw_output.len,
            .stored_output_bytes = safe_output.len,
            .truncated = safe_output.len < raw_output.len,
        },
    };
}

pub fn applyToolResultMemory(
    prepared: *types.ToolResultMemory,
    source: ?types.ToolResultMemory,
) void {
    const source_memory = source orelse return;
    prepared.command_output_replay = source_memory.command_output_replay;
    prepared.command_process_presentation = source_memory.command_process_presentation;
    const source_covers_full_file =
        source_memory.model_view_covers_full_file orelse return;
    prepared.model_view_covers_full_file =
        source_covers_full_file and
        !source_memory.truncated and
        source_memory.output_handle == null and
        !prepared.truncated and
        prepared.output_handle == null;
}

/// Consumes a tentative interactive command capture after ordinary result
/// storage has selected the exact source that completed Ctrl-O and resume will
/// read. Exact round trips delete the candidate; every unprovable case keeps a
/// private tagged replay descriptor.
pub fn finalizeCommandReplay(
    arena: Allocator,
    tool_call: ToolCall,
    prepared: *result_store.PreparedResult,
    session_child_capability: ?*session_child_store.SessionChildCapability,
    capture: ?*command_replay_store.Capture,
) void {
    const candidate = capture orelse return;
    if (!isCapturedCommandCall(arena, tool_call)) {
        candidate.abort(arena);
        return;
    }
    if (!candidate.hasOutput()) {
        candidate.discard(arena);
        return;
    }

    var captured = candidate.canonicalizeForComparison(arena) catch |err| {
        debug_trace.logf(
            "session",
            "command replay comparison unavailable call_id_bytes={d} err={s}",
            .{ tool_call.id.len, @errorName(err) },
        );
        retainCommandReplay(arena, candidate, &prepared.memory);
        return;
    } orelse {
        retainCommandReplay(arena, candidate, &prepared.memory);
        return;
    };
    defer captured.deinit(arena);

    const source = selectedCommandSource(
        arena,
        prepared.*,
        session_child_capability,
        candidate.comparisonLimit(),
    ) catch |err| {
        debug_trace.logf(
            "session",
            "command replay source comparison failed call_id_bytes={d} err={s}",
            .{ tool_call.id.len, @errorName(err) },
        );
        retainCommandReplay(arena, candidate, &prepared.memory);
        return;
    } orelse {
        retainCommandReplay(arena, candidate, &prepared.memory);
        return;
    };
    defer arena.free(source);
    var ordinary = (command_output_content.canonicalizeForegroundResult(
        arena,
        source,
    ) catch |err| {
        debug_trace.logf(
            "session",
            "command replay envelope comparison failed call_id_bytes={d} err={s}",
            .{ tool_call.id.len, @errorName(err) },
        );
        retainCommandReplay(arena, candidate, &prepared.memory);
        return;
    }) orelse {
        retainCommandReplay(arena, candidate, &prepared.memory);
        return;
    };
    defer ordinary.deinit(arena);

    if (command_output_content.eql(captured, ordinary)) {
        candidate.discard(arena);
        return;
    }
    retainCommandReplay(arena, candidate, &prepared.memory);
}

fn isCapturedCommandCall(arena: Allocator, call: ToolCall) bool {
    if (std.mem.eql(u8, call.name, "run_command")) return true;
    if (!std.mem.eql(u8, call.name, "terminal")) return false;
    var parsed = std.json.parseFromSlice(std.json.Value, arena, call.arguments_json, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const action = parsed.value.object.get("action") orelse return false;
    return action == .string and std.mem.eql(u8, action.string, "exec");
}

fn selectedCommandSource(
    arena: Allocator,
    prepared: result_store.PreparedResult,
    session_child_capability: ?*session_child_store.SessionChildCapability,
    comparison_limit: usize,
) !?[]u8 {
    const source_limit = std.math.add(
        usize,
        comparison_limit,
        command_output_content.max_foreground_result_envelope_bytes,
    ) catch return null;
    if (prepared.memory.output_handle) |handle| {
        const capability = session_child_capability orelse return null;
        var reader = try result_store.openReaderManaged(arena, capability, handle);
        defer reader.deinit();
        if (reader.size != prepared.memory.stored_output_bytes or
            reader.size > source_limit) return null;

        const source = try arena.alloc(u8, reader.size);
        errdefer arena.free(source);
        var offset: usize = 0;
        while (offset < source.len) {
            const page_len = @min(source.len - offset, 4 * 1024);
            const page = try reader.readPage(arena, offset, page_len);
            defer arena.free(page);
            if (page.len != page_len) return error.UnexpectedEndOfResult;
            @memcpy(source[offset..][0..page.len], page);
            offset += page.len;
        }
        return source;
    }
    if (prepared.model_output.len > source_limit) return null;
    const source = try execution_memory_helpers.redactText(arena, prepared.model_output);
    if (source.len > source_limit) {
        arena.free(source);
        return null;
    }
    return source;
}

fn retainCommandReplay(
    arena: Allocator,
    candidate: *command_replay_store.Capture,
    memory: *types.ToolResultMemory,
) void {
    memory.command_output_replay = candidate.retain(arena);
}

pub fn captureCommittedFilePresentation(
    alloc: Allocator,
    handoff: file_mutation.CommittedFileHandoff,
) !types.CommittedFilePresentation {
    const path = try alloc.dupe(u8, handoff.preview.path);
    errdefer alloc.free(path);
    const lines = try alloc.alloc(types.CommittedFilePresentationLine, handoff.preview.lines.len);
    errdefer alloc.free(lines);
    var copied_lines: usize = 0;
    errdefer {
        for (lines[0..copied_lines]) |line| alloc.free(@constCast(line.text));
    }
    for (handoff.preview.lines, 0..) |line, index| {
        lines[index] = .{
            .kind = switch (line.op) {
                .context => .context,
                .addition => .addition,
                .deletion => .deletion,
                .elision => .elision,
                .notice => .notice,
            },
            .old_line = line.old_line,
            .new_line = line.new_line,
            .text = try alloc.dupe(u8, line.text),
        };
        copied_lines += 1;
    }
    const full_view = handoff.full_view;
    const previous_content = if (full_view != null) if (handoff.tracker.previous_content) |content|
        try alloc.dupe(u8, content)
    else
        null else null;
    errdefer if (previous_content) |content| alloc.free(content);
    const after_content = if (full_view) |full|
        try alloc.dupe(u8, full.after_content)
    else
        null;
    errdefer if (after_content) |content| alloc.free(content);
    const lifecycle_id: ?types.ToolLifecycleId = if (full_view) |full| .{
        .turn_id = full.lifecycle_id.turn_id,
        .call_id = try alloc.dupe(u8, full.lifecycle_id.call_id),
    } else null;
    errdefer if (lifecycle_id) |id| alloc.free(@constCast(id.call_id));
    return .{
        .path = path,
        .kind = switch (handoff.tracker.kind) {
            .write => .added,
            .edit => .edited,
        },
        .lines = lines,
        .additions = handoff.preview.additions,
        .deletions = handoff.preview.deletions,
        .truncated = handoff.preview.truncated,
        .previous_content = previous_content,
        .after_content = after_content,
        .lifecycle_id = lifecycle_id,
    };
}

fn toolCall(id: []const u8, name: []const u8, args: []const u8) ToolCall {
    return .{ .id = id, .name = name, .arguments_json = args };
}

test "command sidebands merge without file-view metadata" {
    var prepared: types.ToolResultMemory = .{};
    applyToolResultMemory(&prepared, .{
        .command_output_replay = .unavailable,
        .command_process_presentation = .{ .signal = 9 },
    });
    switch (prepared.command_output_replay.?) {
        .unavailable => {},
        .available => return error.TestExpectedUnavailableReplay,
    }
    try std.testing.expectEqual(
        types.CommandProcessPresentation{ .signal = 9 },
        prepared.command_process_presentation.?,
    );
    try std.testing.expect(prepared.model_view_covers_full_file == null);
}

test "exact command sources delete replay and missing handles retain it" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(
        io_mod.getIo(),
        "session",
        std.Io.File.Permissions.fromMode(0o700),
    );
    var session_dir = try tmp.dir.openDir(io_mod.getIo(), "session", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer session_dir.close(io_mod.getIo());
    const display_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "session");
    defer alloc.free(display_path);
    var capability = try session_child_store.SessionChildCapability.initForTesting(
        alloc,
        session_dir,
        display_path,
        .writable,
        .{},
    );
    defer capability.deinit();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const capture = try command_replay_store.Capture.create(arena, 46, &capability);
    capture.appendAccepted(arena, .stdout, "o");
    capture.appendAccepted(arena, .stdout, "n");
    capture.appendAccepted(arena, .stdout, "e");
    capture.appendAccepted(arena, .stdout, "\n");
    capture.seal(arena);
    var before = try capability.iterate(alloc, .command_artifacts);
    defer before.deinit();
    try std.testing.expectEqual(@as(usize, 1), before.names.len);

    var cancel_flag = std.atomic.Value(bool).init(false);
    var prepared = result_store.PreparedResult{
        .model_output = "exit_code=0\n<stdout>\none\n</stdout>\n",
        .memory = .{
            .output_bytes = 42,
            .stored_output_bytes = 42,
        },
    };
    finalizeCommandReplay(
        arena,
        toolCall("command_exact", "run_command", "{}"),
        &prepared,
        &capability,
        capture,
    );

    try std.testing.expect(prepared.memory.command_output_replay == null);
    var after = try capability.iterate(alloc, .command_artifacts);
    defer after.deinit();
    try std.testing.expectEqual(@as(usize, 0), after.names.len);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(arena);
    try body.appendNTimes(arena, 'x', 80 * 1024);
    const stored_source = try std.fmt.allocPrint(
        arena,
        "exit_code=0\n<stdout>\n{s}\n</stdout>\n",
        .{body.items},
    );
    const stored_capture = try command_replay_store.Capture.create(
        arena,
        1024,
        &capability,
    );
    stored_capture.setComparisonLimit(body.items.len);
    stored_capture.appendAccepted(arena, .stdout, body.items);
    stored_capture.seal(arena);
    var stored_prepared = try prepareToolModelOutput(
        arena,
        .{
            .system_prompt = "",
            .gateway_retry_count = 0,
            .gateway_chat_url = "",
            .model_tools = &.{},
            .agent_step_limit = 1,
            .cancel_flag = &cancel_flag,
            .session_child_capability = &capability,
        },
        toolCall("command_stored_exact", "run_command", "{}"),
        stored_source,
    );
    try std.testing.expect(stored_prepared.memory.output_handle != null);
    finalizeCommandReplay(
        arena,
        toolCall("command_stored_exact", "run_command", "{}"),
        &stored_prepared,
        &capability,
        stored_capture,
    );
    try std.testing.expect(stored_prepared.memory.command_output_replay == null);
    var after_stored = try capability.iterate(alloc, .command_artifacts);
    defer after_stored.deinit();
    try std.testing.expectEqual(@as(usize, 0), after_stored.names.len);

    const TransformCase = struct {
        raw: []const u8,
        projected: []const u8,
    };
    const transform_cases = [_]TransformCase{
        .{ .raw = "\x00\n", .projected = "\\x00" },
        .{ .raw = "\xff\n", .projected = "\\xff" },
        .{ .raw = "\xc2\x80\n", .projected = "\\u{0080}" },
        .{ .raw = "\x1b[31mred\x1b[0m\n", .projected = "red" },
        .{ .raw = "old\rnew\n", .projected = "new" },
    };
    for (transform_cases) |case| {
        const transformed_capture = try command_replay_store.Capture.create(
            arena,
            256,
            &capability,
        );
        transformed_capture.appendAccepted(arena, .stdout, case.raw);
        transformed_capture.seal(arena);
        const projected_source = try std.fmt.allocPrint(
            arena,
            "exit_code=0\n<stdout>\n{s}\n</stdout>\n",
            .{case.projected},
        );
        var transformed_prepared = result_store.PreparedResult{
            .model_output = projected_source,
            .memory = .{
                .output_bytes = projected_source.len,
                .stored_output_bytes = projected_source.len,
            },
        };
        finalizeCommandReplay(
            arena,
            toolCall("command_transformed", "run_command", "{}"),
            &transformed_prepared,
            &capability,
            transformed_capture,
        );
        const transformed_replay = transformed_prepared.memory.command_output_replay orelse
            return error.TestExpectedReplay;
        switch (transformed_replay) {
            .available => {},
            .unavailable => return error.TestExpectedReplay,
        }
    }

    var before_literal = try capability.iterate(alloc, .command_artifacts);
    defer before_literal.deinit();
    const literal_capture = try command_replay_store.Capture.create(
        arena,
        1,
        &capability,
    );
    literal_capture.setComparisonLimit(256);
    literal_capture.appendAccepted(arena, .stdout, "\\x00\n");
    literal_capture.seal(arena);
    var literal_prepared = result_store.PreparedResult{
        .model_output = "exit_code=0\n<stdout>\n\\x00\n</stdout>\n",
        .memory = .{
            .output_bytes = 40,
            .stored_output_bytes = 40,
        },
    };
    finalizeCommandReplay(
        arena,
        toolCall("command_literal", "run_command", "{}"),
        &literal_prepared,
        &capability,
        literal_capture,
    );
    try std.testing.expect(literal_prepared.memory.command_output_replay == null);
    var after_literal = try capability.iterate(alloc, .command_artifacts);
    defer after_literal.deinit();
    try std.testing.expectEqual(before_literal.names.len, after_literal.names.len);

    const missing_capture = try command_replay_store.Capture.create(
        arena,
        64 * 1024,
        &capability,
    );
    missing_capture.appendAccepted(arena, .stdout, "one\n");
    missing_capture.seal(arena);
    var missing_prepared = result_store.PreparedResult{
        .model_output = "stored result preview",
        .memory = .{
            .output_handle = "result-run-command-missing.txt",
            .output_bytes = 42,
            .stored_output_bytes = 42,
            .truncated = true,
        },
    };
    finalizeCommandReplay(
        arena,
        toolCall("command_missing", "run_command", "{}"),
        &missing_prepared,
        &capability,
        missing_capture,
    );
    const retained = missing_prepared.memory.command_output_replay orelse
        return error.TestExpectedReplay;
    switch (retained) {
        .available => {},
        .unavailable => return error.TestExpectedReplay,
    }
    var after_missing = try capability.iterate(alloc, .command_artifacts);
    defer after_missing.deinit();
    try std.testing.expectEqual(transform_cases.len + 1, after_missing.names.len);
}

test "common execution memory does not mark stored read previews as full" {
    const session_runtime = @import("../../session/session.zig");
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const result_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(result_dir);
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(alloc);
    try raw.appendNTimes(
        alloc,
        'x',
        result_store.large_result_threshold_bytes + 128,
    );
    var cancel_flag = std.atomic.Value(bool).init(false);
    const prepared = try prepareToolModelOutput(
        arena,
        .{
            .system_prompt = "",
            .gateway_retry_count = 0,
            .gateway_chat_url = "",
            .model_tools = &.{},
            .agent_step_limit = 1,
            .cancel_flag = &cancel_flag,
            .tool_result_dir = result_dir,
        },
        toolCall(
            "call_large_read",
            "read_file",
            "{\"path\":\"large.txt\"}",
        ),
        raw.items,
    );
    try std.testing.expect(prepared.memory.output_handle != null);
    try std.testing.expect(prepared.memory.truncated);

    var calls = [_]ToolCall{.{
        .id = "call_large_read",
        .name = "read_file",
        .arguments_json = "{\"path\":\"large.txt\"}",
    }};
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = calls[0..] },
        .{
            .role = .tool,
            .content = prepared.model_output,
            .tool_call_id = "call_large_read",
            .tool_name = "read_file",
            .tool_result_status = .success,
            .tool_result_memory = prepared.memory,
        },
    };

    const execution = try buildExecutionMemory(alloc, &messages);
    defer types.freeExecutionMemory(alloc, execution);

    try std.testing.expectEqual(@as(usize, 1), execution.tool_steps.len);
    try std.testing.expect(execution.tool_steps[0].tool_results[0].truncated);
    try std.testing.expectEqual(@as(usize, 1), execution.files.len);
    try std.testing.expect(!execution.files[0].model_view_covers_full_file);

    const replay = try session_runtime.formatExecutionFileContext(alloc, execution.files);
    defer alloc.free(replay);
    try std.testing.expect(std.mem.find(u8, replay, "model_view=full") == null);
}

test "execution memory redacts secret argument values without breaking JSON" {
    const alloc = std.testing.allocator;
    var calls = [_]ToolCall{.{
        .id = "call_secret",
        .name = "run_command",
        .arguments_json = "{\"command\":\"echo ok\",\"api_key\":\"secret-value\"}",
    }};
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = calls[0..] },
        .{ .role = .tool, .content = "ok", .tool_call_id = "call_secret", .tool_name = "run_command", .tool_result_status = .success },
    };

    const memory = try buildExecutionMemory(alloc, &messages);
    defer types.freeExecutionMemory(alloc, memory);
    try std.testing.expectEqual(@as(usize, 1), memory.tool_steps.len);
    const args = memory.tool_steps[0].tool_calls[0].arguments_json;
    try std.testing.expect(std.mem.find(u8, args, "secret-value") == null);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, args, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("[REDACTED]", parsed.value.object.get("api_key").?.string);
    try std.testing.expectEqualStrings("echo ok", parsed.value.object.get("command").?.string);
}

test "execution memory redacts credentialed web_fetch url arguments" {
    const alloc = std.testing.allocator;
    var calls = [_]ToolCall{.{
        .id = "call_fetch",
        .name = "web_fetch",
        .arguments_json = "{\"url\":\"https://user:pass@example.com/docs?token=QUERY_SECRET_SHOULD_NOT_PERSIST\"}",
    }};
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = calls[0..] },
        .{ .role = .tool, .content = "Web fetch result.", .tool_call_id = "call_fetch", .tool_name = "web_fetch", .tool_result_status = .success },
    };

    const memory = try buildExecutionMemory(alloc, &messages);
    defer types.freeExecutionMemory(alloc, memory);
    const args = memory.tool_steps[0].tool_calls[0].arguments_json;
    try std.testing.expect(std.mem.find(u8, args, "user:pass") == null);
    try std.testing.expect(std.mem.find(u8, args, "QUERY_SECRET_SHOULD_NOT_PERSIST") == null);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, args, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("prompt") == null);
    try std.testing.expectEqualStrings("https://[redacted]@example.com/docs?token=[redacted]", parsed.value.object.get("url").?.string);
}

test "large result storage redacts secret-bearing output before preview and disk persistence" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir);

    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(alloc);
    try raw.appendSlice(alloc, "api_key=super-secret-value\n");
    try raw.appendNTimes(alloc, 'x', result_store.large_result_threshold_bytes + 64);

    var cancel_flag = std.atomic.Value(bool).init(false);
    const prepared = try prepareToolModelOutput(arena, .{
        .system_prompt = "",
        .gateway_retry_count = 0,
        .gateway_chat_url = "",
        .model_tools = &.{},
        .agent_step_limit = 1,
        .cancel_flag = &cancel_flag,
        .tool_result_dir = dir,
    }, toolCall("call_secret_large", "run_command", "{}"), raw.items);

    try std.testing.expect(prepared.memory.output_handle != null);
    try std.testing.expect(std.mem.find(u8, prepared.model_output, "super-secret-value") == null);
    try std.testing.expect(std.mem.find(u8, prepared.model_output, "api_key=[redacted]") != null);

    const stored = try result_store.readByRange(alloc, dir, prepared.memory.output_handle.?, 1, 512);
    defer alloc.free(stored);
    try std.testing.expect(std.mem.find(u8, stored, "super-secret-value") == null);
    try std.testing.expect(std.mem.find(u8, stored, "api_key=[redacted]") != null);
}

test "transcript does not mark native web_search as provider resource placeholder" {
    const alloc = std.testing.allocator;
    const record = try execution_memory_helpers.makePersistedToolResult(
        alloc,
        "call_search",
        "web_search",
        .success,
        "bounded search output",
        null,
    );
    const records = try alloc.alloc(types.PersistedToolResult, 1);
    records[0] = record;
    defer types.freePersistedToolResults(alloc, records);

    try std.testing.expect(!records[0].provider_native);
    try std.testing.expectEqualStrings("bounded search output", records[0].output);
}
