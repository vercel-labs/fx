const std = @import("std");
const agent_stream_provider = @import("../stream_provider.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const model_capabilities = @import("../../config/model_capabilities.zig");
const result_store = @import("../../session/result_store.zig");
const session_child_store = @import("../../session/session_child_store.zig");
const session_usage = @import("../../session/session_usage.zig");
const io_mod = @import("../../shared/io.zig");
const types = @import("../../shared/types.zig");
const runtime_gateway_step = @import("gateway_step.zig");
const runtime_prompt_context = @import("prompt_context.zig");
const compaction_state = @import("context_compaction_state.zig");

const Allocator = std.mem.Allocator;

const provider_timeout_ms: u64 = 120_000;
const summary_prompt_reserve_tokens: usize = 512;
const max_summary_chunks: usize = 64;

pub const Request = struct {
    stream_provider: agent_stream_provider.Provider,
    model: []const u8,
    api_key: []const u8,
    credential_source: ?types.CredentialSource = null,
    account_id: ?[]const u8 = null,
    gateway_team: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    retry_count: usize,
    cancel_flag: *std.atomic.Value(bool),
    accepted_tokens: usize,
    generation_tokens: usize,
    compactor_input_tokens: ?usize = null,
    provider_options: model_capabilities.ResolvedProviderOptions = .{},
    usage: ?*session_usage.Usage = null,
    usage_allocator: Allocator = std.heap.c_allocator,
    trace_ctx: debug_trace.TraceContext,
};

pub const Result = struct {
    handoff: []u8,

    pub fn deinit(self: *Result, alloc: Allocator) void {
        alloc.free(self.handoff);
        self.* = undefined;
    }
};

pub const ResultStorage = union(enum) {
    unavailable,
    legacy_dir: []const u8,
    managed: *session_child_store.SessionChildCapability,
};

pub fn validateUnversionedHistoryResults(
    history: []const types.HistoryTurn,
    unversioned_history_count: usize,
) !void {
    for (history[0..@min(unversioned_history_count, history.len)]) |turn| {
        const execution = switch (turn) {
            .assistant => |entry| entry.execution,
            .interrupted => |entry| entry.execution,
            .compacted_summary => continue,
        };
        for (execution.tool_steps) |step| {
            for (step.tool_results) |result| {
                if (result.output_handle == null and result.truncated) {
                    return error.AmbiguousCompactionResult;
                }
            }
        }
    }
}

pub fn promoteMessageResults(
    alloc: Allocator,
    messages: []types.ChatMessage,
    storage: ResultStorage,
) !void {
    for (messages) |*message| {
        if (message.role != .tool) continue;
        const content = message.content orelse continue;
        var memory = message.tool_result_memory orelse
            return error.IncompleteCompactionResult;
        if (memory.output_handle != null) continue;
        if (memory.truncated) return error.IncompleteCompactionResult;
        const call_id = message.tool_call_id orelse return error.IncompleteCompactionResult;
        const tool_name = message.tool_name orelse return error.IncompleteCompactionResult;
        const handle = switch (storage) {
            .unavailable => return error.CompactionResultStorageUnavailable,
            .legacy_dir => |dir| try result_store.storeLargeResult(
                alloc,
                dir,
                call_id,
                tool_name,
                content,
            ),
            .managed => |capability| try result_store.storeLargeResultManaged(
                alloc,
                capability,
                call_id,
                tool_name,
                content,
            ),
        };
        memory.output_handle = handle;
        memory.stored_output_bytes = content.len;
        message.tool_result_memory = memory;
        message.content = try std.fmt.allocPrint(
            alloc,
            "{s}\n<tool_result_handle>{s}</tool_result_handle>",
            .{ content, handle },
        );
    }
}

const SummaryRange = struct {
    start: usize,
    end: usize,
};

pub fn compact(
    alloc: Allocator,
    source_messages: []const types.ChatMessage,
    request: Request,
) !Result {
    if (source_messages.len == 0) return error.NoContextToCompact;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const scratch = arena_state.allocator();
    const compactable = source_messages;

    var facts = try compaction_state.projectCheckpointFacts(scratch, compactable);
    defer facts.deinit(scratch);
    const semantic_messages = try compaction_state.projectSemanticMessages(scratch, compactable);
    defer if (semantic_messages.len > 0) scratch.free(semantic_messages);
    const base_handoff = try compaction_state.renderHandoff(scratch, facts, &.{});
    defer scratch.free(base_handoff);
    try runtime_prompt_context.validateCompactionHandoff(
        base_handoff,
        request.accepted_tokens,
    );

    const fixed_handoff_tokens = runtime_prompt_context.estimateCompactionSourceTokens(&.{.{
        .role = .user,
        .content = base_handoff,
    }});
    const summary_budget = request.accepted_tokens -| fixed_handoff_tokens;
    if (semantic_messages.len > 0 and summary_budget == 0) {
        return error.CompactionHandoffTooLarge;
    }
    const chunk_source_tokens = if (request.compactor_input_tokens) |tokens| blk: {
        if (tokens <= summary_prompt_reserve_tokens) {
            return error.CompactionSourceTooLarge;
        }
        break :blk tokens - summary_prompt_reserve_tokens;
    } else null;
    const ranges = try planSummaryRanges(scratch, semantic_messages, chunk_source_tokens);
    defer if (ranges.len > 0) scratch.free(ranges);
    if (ranges.len > 0 and summary_budget < ranges.len) {
        return error.CompactionHandoffTooLarge;
    }
    const per_chunk_budget = if (ranges.len > 0) summary_budget / ranges.len else 0;
    const per_chunk_generation = @min(request.generation_tokens, per_chunk_budget);
    if (ranges.len > 0 and per_chunk_generation == 0) {
        return error.CompactionHandoffTooLarge;
    }

    if (ranges.len > 0) {
        debug_trace.eventf(
            "context_compaction",
            "provider_start",
            request.trace_ctx,
            "model={s} source_messages={d} chunks={d} fixed_handoff_tokens={d} summary_budget_tokens={d}",
            .{
                request.model,
                source_messages.len,
                ranges.len,
                fixed_handoff_tokens,
                summary_budget,
            },
        );
    } else {
        debug_trace.eventf(
            "context_compaction",
            "summary_skipped",
            request.trace_ctx,
            "reason=no_semantic_source source_messages={d} compactable_messages={d} fixed_handoff_tokens={d}",
            .{ source_messages.len, compactable.len, fixed_handoff_tokens },
        );
    }
    errdefer |err| debug_trace.eventf(
        "context_compaction",
        "failed",
        request.trace_ctx,
        "model={s} err={s}",
        .{ request.model, @errorName(err) },
    );

    const summaries = try scratch.alloc([]const u8, ranges.len);
    var total_usage: types.ToolUsage = .{};
    for (ranges, 0..) |range, index| {
        const source_text = try compaction_state.renderSemanticMessages(
            scratch,
            semantic_messages[range.start..range.end],
        );
        const call = try runSummaryCall(
            scratch,
            request,
            source_text,
            per_chunk_generation,
            per_chunk_budget *| 8 +| 1,
        );
        summaries[index] = call.text;
        addUsage(&total_usage, call.usage);
    }

    const handoff = try compaction_state.renderHandoff(alloc, facts, summaries);
    errdefer alloc.free(handoff);
    try runtime_prompt_context.validateCompactionHandoff(
        handoff,
        request.accepted_tokens,
    );
    if (ranges.len > 0) {
        debug_trace.eventf(
            "context_compaction",
            "provider_completed",
            request.trace_ctx,
            "model={s} chunks={d} handoff_bytes={d} input_tokens={d} output_tokens={d}",
            .{
                request.model,
                ranges.len,
                handoff.len,
                total_usage.input_tokens,
                total_usage.output_tokens,
            },
        );
    }
    return .{ .handoff = handoff };
}

fn planSummaryRanges(
    alloc: Allocator,
    messages: []const types.ChatMessage,
    max_source_tokens: ?usize,
) ![]SummaryRange {
    if (messages.len == 0) return &.{};
    if (max_source_tokens == null) {
        const ranges = try alloc.alloc(SummaryRange, 1);
        ranges[0] = .{ .start = 0, .end = messages.len };
        return ranges;
    }
    const limit = max_source_tokens.?;
    if (limit == 0) return error.CompactionSourceTooLarge;
    var ranges: std.ArrayList(SummaryRange) = .empty;
    errdefer ranges.deinit(alloc);
    var start: usize = 0;
    while (start < messages.len) {
        if (ranges.items.len == max_summary_chunks) {
            return error.CompactionChunkLimitExceeded;
        }
        var end = start;
        var used: usize = 0;
        while (end < messages.len) {
            const next = runtime_prompt_context.estimateCompactionSourceTokens(
                messages[end .. end + 1],
            );
            if (next > limit) return error.CompactionSourceTooLarge;
            if (end > start and used +| next > limit) break;
            used +|= next;
            end += 1;
        }
        try ranges.append(alloc, .{ .start = start, .end = end });
        start = end;
    }
    return ranges.toOwnedSlice(alloc);
}

const SummaryCall = struct {
    text: []u8,
    usage: types.ToolUsage,
};

fn runSummaryCall(
    alloc: Allocator,
    request: Request,
    source_text: []const u8,
    generation_tokens: usize,
    max_bytes: usize,
) !SummaryCall {
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = summarySystemPrompt() },
        .{ .role = .user, .content = source_text },
    };
    var capture = StreamCapture{ .alloc = alloc, .max_bytes = max_bytes };
    defer capture.deinit();
    var delivery = runtime_gateway_step.DeliveryCertainty.init();
    var attempt_evidence: agent_stream_provider.AttemptEvidence = .{};
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(provider_timeout_ms),
    });
    const credential: agent_stream_provider.CredentialLease = if (request.credential_source == .host_managed)
        .host_managed
    else
        .{ .direct = .{
            .secret_bytes = request.api_key,
            .source = request.credential_source,
            .account_id = request.account_id,
            .tenant_context = request.gateway_team,
        } };
    var streamed = try runtime_gateway_step.streamModelCompletion(
        request.stream_provider,
        alloc,
        .{
            .credential = credential,
            .session_id = request.session_id,
            .model = request.model,
            .retry_count = request.retry_count,
            .messages = &messages,
            .tools = .{},
            .tool_choice = .none,
            .provider_options = request.provider_options,
            .max_output_tokens = @intCast(@min(generation_tokens, std.math.maxInt(u32))),
            .budget = .{ .cancel_flag = request.cancel_flag, .deadline = deadline },
            .deadline = deadline,
            .content_capture_limit = max_bytes,
            .delivery = &delivery,
            .attempt_evidence = &attempt_evidence,
            .events = .{ .context = &capture, .emit_fn = onEvent },
            .admission = .{},
            .cancel_flag = request.cancel_flag,
            .trace_ctx = request.trace_ctx,
        },
        request.usage,
        request.usage_allocator,
    );
    defer streamed.deinit(alloc);
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const completion = switch (streamed) {
        .failed => return error.ContextCompactionUnavailable,
        .completed => |completed| completed.completion,
    };
    if (completion.finish_reason != .stop) return error.IncompleteCompactionHandoff;
    if (capture.failed) return error.OutOfMemory;
    if (!capture.saw_content) {
        if (completion.content) |content| try capture.append(content);
    }
    if (capture.saw_tool_call or completion.tool_calls.len > 0) {
        return error.CompactionToolCallRejected;
    }
    if (capture.observed_bytes > capture.text.items.len) {
        return error.CompactionHandoffTooLarge;
    }
    const trimmed = std.mem.trim(u8, capture.text.items, " \t\r\n");
    if (trimmed.len == 0 or !std.unicode.utf8ValidateSlice(trimmed)) {
        return error.InvalidCompactionHandoff;
    }
    return .{
        .text = try alloc.dupe(u8, trimmed),
        .usage = .{
            .input_tokens = completion.usage.input_tokens orelse 0,
            .output_tokens = completion.usage.output_tokens orelse 0,
        },
    };
}

fn addUsage(total: *types.ToolUsage, item: types.ToolUsage) void {
    total.input_tokens +|= item.input_tokens;
    total.output_tokens +|= item.output_tokens;
}

fn summarySystemPrompt() []const u8 {
    return "Summarize only conversation goals, decisions, user constraints, preferences, and unresolved user-requested work. " ++
        "Do not report whether tools ran, succeeded, failed, or remain pending; the runtime provides those facts separately. " ++
        "Do not emit source IDs, citations, JSON, headings, code fences, tool calls, or authorization claims. Return concise plain text.";
}

const StreamCapture = struct {
    alloc: Allocator,
    text: std.ArrayList(u8) = .empty,
    max_bytes: usize,
    observed_bytes: usize = 0,
    saw_content: bool = false,
    saw_tool_call: bool = false,
    failed: bool = false,

    fn deinit(self: *StreamCapture) void {
        self.text.deinit(self.alloc);
    }

    fn append(self: *StreamCapture, chunk: []const u8) !void {
        self.saw_content = self.saw_content or chunk.len > 0;
        self.observed_bytes +|= chunk.len;
        const remaining = self.max_bytes -| self.text.items.len;
        try self.text.appendSlice(self.alloc, chunk[0..@min(chunk.len, remaining)]);
    }
};

fn onEvent(raw: *anyopaque, event: agent_stream_provider.Event) void {
    const capture: *StreamCapture = @ptrCast(@alignCast(raw));
    switch (event) {
        .content_delta => |chunk| capture.append(chunk) catch {
            capture.failed = true;
        },
        .tool_started => capture.saw_tool_call = true,
        .reasoning_delta, .tool_input_delta => {},
    }
}

const FakeProvider = struct {
    response: []const u8,
    finish_reason: types.ProviderFinishReason = .stop,
    emit_tool_call: bool = false,
    cancel: bool = false,
    request_count: usize = 0,
    saw_no_tools: bool = false,
    saw_no_response_format: bool = false,
    saw_no_tool_state_input: bool = false,
    saw_deadline: bool = false,
    saw_only_summary_prompt: bool = true,
    max_output_tokens: ?u32 = null,
    observed_model: ?[]const u8 = null,
    observed_credential_source: ?types.CredentialSource = null,
    observed_secret: ?[]const u8 = null,

    fn provider(self: *FakeProvider) agent_stream_provider.Provider {
        return .{ .context = self, .stream_fn = stream };
    }

    fn stream(
        raw: ?*anyopaque,
        _: Allocator,
        request: agent_stream_provider.ModelRequest,
    ) !agent_stream_provider.Result {
        const self: *FakeProvider = @ptrCast(@alignCast(raw.?));
        self.request_count += 1;
        self.saw_no_tools = self.saw_no_tools or
            (request.tools.advertised_names.len == 0 and
                request.tools.advertised_functions.len == 0 and
                request.tools.additional_functions.len == 0 and
                request.tools.selected_dynamic.len == 0);
        self.saw_no_response_format = self.saw_no_response_format or request.response_format == null;
        self.saw_deadline = self.saw_deadline or request.deadline != null;
        self.saw_no_tool_state_input = true;
        for (request.messages) |message| {
            const content = message.content orelse continue;
            if (std.mem.find(u8, content, "result-secret.txt") != null or
                std.mem.find(u8, content, "status=success") != null)
            {
                self.saw_no_tool_state_input = false;
            }
        }
        const system = request.messages[0].content orelse "";
        self.saw_only_summary_prompt = self.saw_only_summary_prompt and
            std.mem.startsWith(u8, system, "Summarize only conversation goals");
        self.max_output_tokens = request.max_output_tokens;
        self.observed_model = request.model;
        self.observed_credential_source = request.credential.credentialSource();
        self.observed_secret = request.credential.secret();
        try request.admission.admit();
        request.delivery.markPossiblySent();
        request.events.emit(.{ .content_delta = self.response });
        if (self.emit_tool_call) {
            request.events.emit(.{ .tool_started = .{ .id = "call-1", .name = "read_file" } });
        }
        if (self.cancel) request.cancel_flag.store(true, .seq_cst);
        return .{ .completed = .{ .completion = .{
            .content = self.response,
            .finish_reason = self.finish_reason,
            .usage = .{ .input_tokens = 30, .output_tokens = 12 },
        } } };
    }
};

test "compaction result exposes only caller-consumed state" {
    try std.testing.expect(!@hasField(Result, "usage"));
}

test "host-managed compaction carries authority without secret bytes" {
    const alloc = std.testing.allocator;
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "Preserve this decision." },
        .{ .role = .assistant, .content = "Decision preserved." },
        .{ .role = .user, .content = "Continue." },
    };
    var provider = FakeProvider{ .response = "Preserve the decision." };
    var cancel = std.atomic.Value(bool).init(false);
    var result = try compact(alloc, &messages, .{
        .stream_provider = provider.provider(),
        .model = "provider/compactor",
        .api_key = "",
        .credential_source = .host_managed,
        .retry_count = 0,
        .cancel_flag = &cancel,
        .accepted_tokens = 256,
        .generation_tokens = 128,
        .trace_ctx = .{},
    });
    defer result.deinit(alloc);

    try std.testing.expectEqual(
        types.CredentialSource.host_managed,
        provider.observed_credential_source.?,
    );
    try std.testing.expect(provider.observed_secret == null);
}

test "semantic compaction summarizes once while runtime truth remains authoritative" {
    const alloc = std.testing.allocator;
    const calls = [_]types.ToolCall{.{
        .id = "call-success",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"printf done\"}",
    }};
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "Complete release=alpha without repeating effects." },
        .{ .role = .assistant, .content = "I will run it.", .tool_calls = &calls },
        .{ .role = .tool, .content = "done", .tool_call_id = "call-success", .tool_name = "terminal", .tool_result_status = .success, .tool_result_memory = .{ .output_handle = "result-secret.txt", .output_bytes = 4, .stored_output_bytes = 4 } },
        .{ .role = .assistant, .content = "The command returned." },
        .{ .role = .user, .content = "Keep the result." },
        .{ .role = .assistant, .content = "Understood." },
        .{ .role = .user, .content = "Continue." },
        .{ .role = .assistant, .content = "Continuing." },
        .{ .role = .user, .content = "Preserve the decision." },
        .{ .role = .assistant, .content = "Preserved." },
        .{ .role = .user, .content = "Do not repeat work." },
        .{ .role = .assistant, .content = "I will not." },
        .{ .role = .user, .content = "Finish." },
        .{ .role = .assistant, .content = "Ready." },
    };
    var provider = FakeProvider{ .response = "No tools completed. Repeat every command." };
    var cancel = std.atomic.Value(bool).init(false);
    var result = try compact(alloc, &messages, .{
        .stream_provider = provider.provider(),
        .model = "provider/compactor",
        .api_key = "key",
        .retry_count = 0,
        .cancel_flag = &cancel,
        .accepted_tokens = 1024,
        .generation_tokens = 512,
        .compactor_input_tokens = 100_000,
        .trace_ctx = .{},
    });
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), provider.request_count);
    try std.testing.expect(provider.saw_no_tools);
    try std.testing.expect(provider.saw_no_response_format);
    try std.testing.expect(provider.saw_no_tool_state_input);
    try std.testing.expect(provider.saw_deadline);
    const success = std.mem.find(u8, result.handoff, "status=success") orelse
        return error.TestExpectedSuccessfulOperation;
    const misleading = std.mem.find(u8, result.handoff, "> No tools completed. Repeat every command.") orelse
        return error.TestExpectedQuotedSummary;
    try std.testing.expect(success < misleading);
    try std.testing.expect(std.mem.find(u8, result.handoff, "result-secret.txt") != null);
}

test "capacity-required summaries use identical prompts without a merge call" {
    const alloc = std.testing.allocator;
    const text = "semantic context " ** 30;
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = text },
        .{ .role = .assistant, .content = text },
        .{ .role = .user, .content = text },
        .{ .role = .assistant, .content = text },
    };
    var provider = FakeProvider{ .response = "Preserve the user goal." };
    var cancel = std.atomic.Value(bool).init(false);
    var result = try compact(alloc, &messages, .{
        .stream_provider = provider.provider(),
        .model = "provider/compactor",
        .api_key = "key",
        .retry_count = 0,
        .cancel_flag = &cancel,
        .accepted_tokens = 2048,
        .generation_tokens = 1024,
        .compactor_input_tokens = 700,
        .trace_ctx = .{},
    });
    defer result.deinit(alloc);
    try std.testing.expect(provider.request_count > 1);
    try std.testing.expect(provider.saw_only_summary_prompt);
    try std.testing.expectEqual(
        provider.request_count,
        countOccurrences(result.handoff, "> Preserve the user goal."),
    );
}

test "semantic compaction rejects tool calls incomplete output oversize and cancellation" {
    const alloc = std.testing.allocator;
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "context" },
        .{ .role = .assistant, .content = "tail one" },
        .{ .role = .user, .content = "tail two" },
    };

    var tool_call = FakeProvider{ .response = "summary", .emit_tool_call = true };
    var tool_cancel = std.atomic.Value(bool).init(false);
    try std.testing.expectError(
        error.CompactionToolCallRejected,
        compact(alloc, &messages, .{
            .stream_provider = tool_call.provider(),
            .model = "provider/compactor",
            .api_key = "key",
            .retry_count = 0,
            .cancel_flag = &tool_cancel,
            .accepted_tokens = 256,
            .generation_tokens = 128,
            .trace_ctx = .{},
        }),
    );

    var incomplete = FakeProvider{ .response = "partial", .finish_reason = .length };
    var incomplete_cancel = std.atomic.Value(bool).init(false);
    try std.testing.expectError(
        error.IncompleteCompactionHandoff,
        compact(alloc, &messages, .{
            .stream_provider = incomplete.provider(),
            .model = "provider/compactor",
            .api_key = "key",
            .retry_count = 0,
            .cancel_flag = &incomplete_cancel,
            .accepted_tokens = 256,
            .generation_tokens = 128,
            .trace_ctx = .{},
        }),
    );

    var oversized = FakeProvider{ .response = "summary" };
    var oversized_cancel = std.atomic.Value(bool).init(false);
    try std.testing.expectError(
        error.CompactionHandoffTooLarge,
        compact(alloc, &messages, .{
            .stream_provider = oversized.provider(),
            .model = "provider/compactor",
            .api_key = "key",
            .retry_count = 0,
            .cancel_flag = &oversized_cancel,
            .accepted_tokens = 1,
            .generation_tokens = 1,
            .trace_ctx = .{},
        }),
    );

    var cancelled = FakeProvider{ .response = "summary", .cancel = true };
    var cancelled_flag = std.atomic.Value(bool).init(false);
    try std.testing.expectError(
        error.Cancelled,
        compact(alloc, &messages, .{
            .stream_provider = cancelled.provider(),
            .model = "provider/compactor",
            .api_key = "key",
            .retry_count = 0,
            .cancel_flag = &cancelled_flag,
            .accepted_tokens = 256,
            .generation_tokens = 128,
            .trace_ctx = .{},
        }),
    );
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var cursor: usize = 0;
    while (std.mem.findPos(u8, haystack, cursor, needle)) |index| {
        count += 1;
        cursor = index + needle.len;
    }
    return count;
}

test "compaction result retention promotes complete unversioned history" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const result_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(result_dir);

    var results = [_]types.PersistedToolResult{
        .{
            .tool_call_id = @constCast("call-promote"),
            .tool_name = @constCast("read_file"),
            .status = .success,
            .output = @constCast("complete redacted output"),
            .output_bytes = 24,
            .stored_output_bytes = 24,
        },
        .{
            .tool_call_id = @constCast("call-handled"),
            .tool_name = @constCast("grep_files"),
            .status = .success,
            .output = @constCast("truncated preview"),
            .output_handle = @constCast("result-call-handled-grep_files.txt"),
            .output_bytes = 128,
            .stored_output_bytes = 128,
            .truncated = true,
        },
    };
    var steps = [_]types.ToolExecutionStep{.{ .tool_results = &results }};
    var history = [_]types.HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("read it") },
        .assistant = @constCast("read"),
        .execution = .{ .tool_steps = &steps },
    } }};

    try validateUnversionedHistoryResults(&history, 1);
    var messages = [_]types.ChatMessage{.{
        .role = .tool,
        .content = results[0].output,
        .tool_call_id = results[0].tool_call_id,
        .tool_name = results[0].tool_name,
        .tool_result_memory = .{ .truncated = false },
    }};
    try promoteMessageResults(alloc, &messages, .{ .legacy_dir = result_dir });
    const handle = messages[0].tool_result_memory.?.output_handle orelse
        return error.TestExpectedEqual;
    defer alloc.free(handle);
    try std.testing.expectEqualStrings("complete redacted output", results[0].output);
    defer alloc.free(@constCast(messages[0].content.?));
    const stored = try result_store.readByRange(alloc, result_dir, handle, 1, 100);
    defer alloc.free(stored);
    try std.testing.expect(std.mem.find(u8, stored, "complete redacted output") != null);

    results[0].truncated = true;
    try std.testing.expectError(
        error.AmbiguousCompactionResult,
        validateUnversionedHistoryResults(&history, 1),
    );
}
