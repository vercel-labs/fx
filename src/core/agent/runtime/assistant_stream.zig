const std = @import("std");
const command_admission = @import("../../permissions/command_admission.zig");
const permission_auto_classifier = @import("../../permissions/auto_classifier.zig");
const types = @import("../../shared/types.zig");
const text_utils = @import("../../shared/text_utils.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const token_estimate = @import("../../shared/token_estimate.zig");
const assistant_presentation = @import("../assistant_presentation.zig");
const io_mod = @import("../../shared/io.zig");
const file_mutation = @import("../../tooling/file_mutation.zig");
const tool_dispatch = @import("../../tooling/tool_dispatch.zig");
const worker_runtime = @import("../worker_runtime.zig");
const test_builtin_tools = if (@import("builtin").is_test)
    @import("../../../builtins/tools.zig")
else
    struct {};

const runtime_deps = @import("deps.zig");
const runtime_telemetry = @import("telemetry.zig");
const runtime_tool_contracts = @import("tool_contracts.zig");
const runtime_tool_presentation = @import("tool_presentation.zig");
const response_language = @import("response_language.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;
const HistoryTurn = types.HistoryTurn;
const PermissionGrant = types.PermissionGrant;
const PermissionMode = types.PermissionMode;
const ToolCall = types.ToolCall;
const WorkerEvent = worker_runtime.WorkerEvent;
const sanitizeAssistantText = text_utils.sanitizeAssistantText;
const AgentRuntimeDeps = runtime_deps.AgentRuntimeDeps;
const DiffEntryPayload = runtime_tool_contracts.DiffEntryPayload;
const SecondaryPublicationReport = runtime_tool_contracts.SecondaryPublicationReport;
const ToolExecutionResult = runtime_tool_contracts.ToolExecutionResult;
const TablePayload = assistant_presentation.TablePayload;
const CodeBlockPayload = assistant_presentation.CodeBlockPayload;
const response_language_probe_limit_bytes: usize = 4096;

const test_tools = [_]tool_dispatch.Tool{
    test_builtin_tools.read_file,
    test_builtin_tools.write_file,
    test_builtin_tools.edit_file,
    test_builtin_tools.shell,
    test_builtin_tools.ask_user_question,
};
const test_tool_registry = tool_dispatch.Registry{ .tools = test_tools[0..] };

pub const SemanticPresentationSink = struct {
    ctx: *anyopaque,
    /// Takes ownership of `table` only when it returns successfully.
    table: *const fn (ctx: *anyopaque, table: TablePayload) anyerror!void,
    /// Takes ownership of `block` only when it returns successfully.
    code_block: *const fn (ctx: *anyopaque, block: CodeBlockPayload) anyerror!void,
    thematic_rule: *const fn (ctx: *anyopaque) anyerror!void,
};

pub const StreamChunkContext = struct {
    hooks: *const AgentRuntimeDeps,
    flush_assistant_stream_per_content_chunk: bool = false,
    semantic_presentation: ?SemanticPresentationSink = null,
    token_progress: ?*runtime_telemetry.TurnSummaryAccumulator = null,
    turn_id: u64,
    step_id: u64 = 0,
    alloc: Allocator = std.heap.c_allocator,
    saw_visible_text: bool = false,
    saw_tool_start: bool = false,
    saw_provider_tool_start: bool = false,
    saw_visible_text_after_tool_start: bool = false,
    last_byte_was_newline: bool = false,
    trailing_newline_count: u8 = 0,
    first_model_output_at_ms: ?i64 = null,
    markdown: assistant_presentation.MarkdownProcessor = .{},
    raw_text: std.ArrayList(u8) = .empty,
    interrupted_source: std.ArrayList(u8) = .empty,
    response_started: bool = false,
    published_phase: ?types.TurnPhase = null,
    initial_line_prefix: std.ArrayList(u8) = .empty,
    provisional_statuses: runtime_tool_presentation.ProvisionalToolStatuses = .{},
    response_language_expected: ?response_language.Script = null,
    response_language_accepted: bool = false,
    response_language_hold_until_completion: bool = false,
    response_language_next_probe_bytes: usize = 5,

    fn markModelOutput(self: *StreamChunkContext) void {
        if (self.first_model_output_at_ms == null) self.first_model_output_at_ms = io_mod.milliTimestamp();
    }

    fn recordTextOutput(self: *StreamChunkContext, text: []const u8) void {
        if (text.len > 0 and self.saw_tool_start) {
            self.saw_visible_text_after_tool_start = true;
        }
        var trailing: usize = 0;
        while (trailing < text.len and text[text.len - trailing - 1] == '\n') : (trailing += 1) {}
        if (trailing == 0) {
            self.last_byte_was_newline = false;
            self.trailing_newline_count = 0;
            return;
        }

        self.last_byte_was_newline = true;
        const bounded: u8 = @intCast(@min(trailing, @as(usize, 2)));
        self.trailing_newline_count = if (trailing == text.len)
            @min(2, self.trailing_newline_count + bounded)
        else
            bounded;
    }

    fn recordSemanticBoundary(self: *StreamChunkContext) void {
        if (self.saw_tool_start) {
            self.saw_visible_text_after_tool_start = true;
        }
        self.last_byte_was_newline = true;
        self.trailing_newline_count = 1;
    }

    pub fn deinit(self: *StreamChunkContext) void {
        self.markdown.deinit(self.alloc);
        self.raw_text.deinit(self.alloc);
        self.interrupted_source.deinit(self.alloc);
        self.initial_line_prefix.deinit(self.alloc);
        self.provisional_statuses.deinit(self.alloc);
    }

    pub fn start_response(self: *StreamChunkContext) !void {
        if (self.response_started) return;
        try self.hooks.push_text(self.hooks.ctx, .assistant_started);
        self.response_started = true;
    }

    pub fn beginRecoveryAttempt(self: *StreamChunkContext) !void {
        if (self.response_language_staging()) {
            self.drop_staged_response_language_candidate();
        }
        if (self.raw_text.items.len > 0) {
            try flushAssistantStream(self);
            try self.hooks.push_text(self.hooks.ctx, .{
                .assistant_restarted = "\n\n[Response interrupted. Restarting.]\n\n",
            });
            debug_trace.logf("agent", "restarting response preview_bytes={d} superseded_preview_bytes={d}", .{
                self.raw_text.items.len,
                self.interrupted_source.items.len,
            });
            std.mem.swap(std.ArrayList(u8), &self.raw_text, &self.interrupted_source);
            self.raw_text.clearRetainingCapacity();
        }
        self.markdown.deinit(self.alloc);
        self.markdown = .{};
        self.initial_line_prefix.clearRetainingCapacity();
        self.saw_visible_text = false;
        self.response_started = false;
        self.last_byte_was_newline = false;
        self.trailing_newline_count = 0;
        self.response_language_accepted = false;
        self.response_language_next_probe_bytes = 5;
        self.saw_tool_start = false;
        self.saw_provider_tool_start = false;
        self.saw_visible_text_after_tool_start = false;
        self.first_model_output_at_ms = null;
        self.published_phase = null;
    }

    pub fn accepted_source(self: *const StreamChunkContext) []const u8 {
        return if (self.response_language_staging()) "" else self.raw_text.items;
    }

    pub fn accepted_source_or(self: *const StreamChunkContext, fallback: []const u8) []const u8 {
        if (self.response_language_staging()) return "";
        return if (self.raw_text.items.len > 0) self.raw_text.items else fallback;
    }

    pub fn interruption_source_or(self: *const StreamChunkContext, fallback: []const u8) []const u8 {
        if (!self.response_language_staging()) {
            if (self.raw_text.items.len > 0) return self.raw_text.items;
            return if (fallback.len > 0) fallback else self.interrupted_source.items;
        }
        const candidate = if (self.raw_text.items.len > 0) self.raw_text.items else fallback;
        if (candidate.len == 0) return self.interrupted_source.items;
        const actual = response_language.evidence(candidate).script orelse return candidate;
        return if (actual == self.response_language_expected.?) candidate else self.interrupted_source.items;
    }

    pub fn accept_staged_response_language(self: *StreamChunkContext) !void {
        if (!self.response_language_staging()) return;
        self.response_language_accepted = true;
        try publishAssistantChunkResolved(self, self.raw_text.items);
    }

    pub fn drop_staged_response_language_candidate(self: *StreamChunkContext) void {
        if (!self.response_language_staging()) return;
        if (self.raw_text.items.len > 0) {
            debug_trace.logf(
                "agent",
                "dropping rejected response language candidate bytes={d}",
                .{self.raw_text.items.len},
            );
        }
        self.raw_text.clearRetainingCapacity();
        self.initial_line_prefix.clearRetainingCapacity();
        self.saw_visible_text = false;
        self.last_byte_was_newline = false;
        self.trailing_newline_count = 0;
        self.response_language_next_probe_bytes = 5;
    }

    fn response_language_staging(self: *const StreamChunkContext) bool {
        return self.response_language_expected != null and
            !self.response_language_accepted;
    }

    /// Restores durable partial source before a restarted turn sends anything.
    /// The next attempt retains it as interruption evidence and starts fresh.
    /// Surfaces that already show the preview do not emit it again here.
    pub fn restoreRecoverySource(
        self: *StreamChunkContext,
        source: []const u8,
        already_presented: bool,
    ) !void {
        if (source.len == 0) return;
        if (already_presented) {
            try self.raw_text.appendSlice(self.alloc, source);
            self.response_language_accepted = true;
            return;
        }
        try streamAssistantChunk(self, source);
        try flushAssistantStream(self);
    }
};

pub fn onStreamContentChunk(ctx: *anyopaque, chunk: []const u8) void {
    const stream_ctx: *StreamChunkContext = @ptrCast(@alignCast(ctx));
    stream_ctx.markModelOutput();
    publishTurnPhase(stream_ctx, .generating);
    if (stream_ctx.token_progress) |progress| {
        pushTokenProgressUpdate(stream_ctx, progress.consumeContent(chunk)) catch |err| {
            debug_trace.logf("agent", "token progress publication failed source=content err={s}", .{@errorName(err)});
        };
    }
    streamAssistantChunk(stream_ctx, chunk) catch {};
    if (stream_ctx.flush_assistant_stream_per_content_chunk) {
        flushAssistantStream(stream_ctx) catch {};
    }
}

pub fn onStreamReasoningChunk(ctx: *anyopaque, chunk: []const u8) void {
    const stream_ctx: *StreamChunkContext = @ptrCast(@alignCast(ctx));
    stream_ctx.markModelOutput();
    publishTurnPhase(stream_ctx, .thinking);
    if (stream_ctx.token_progress) |progress| {
        pushTokenProgressUpdate(stream_ctx, progress.consumeReasoning(chunk)) catch |err| {
            debug_trace.logf("agent", "token progress publication failed source=reasoning err={s}", .{@errorName(err)});
        };
    }
    if (stream_ctx.hooks.push_reasoning_delta) |push| {
        push(stream_ctx.hooks.ctx, chunk) catch |err| {
            debug_trace.logf("agent", "reasoning publication failed err={s}", .{@errorName(err)});
        };
    }
}

pub fn publishTurnPhase(stream_ctx: *StreamChunkContext, phase: types.TurnPhase) void {
    if (stream_ctx.published_phase == phase) return;
    stream_ctx.hooks.push_event(stream_ctx.hooks.ctx, .{ .turn_phase_update = .{
        .turn_id = stream_ctx.turn_id,
        .step_id = stream_ctx.step_id,
        .phase = phase,
    } }) catch |err| {
        debug_trace.logf("agent", "turn phase publication failed phase={s} err={s}", .{ @tagName(phase), @errorName(err) });
        return;
    };
    stream_ctx.published_phase = phase;
}

pub fn onStreamToolInputChunk(ctx: *anyopaque, chunk: []const u8) void {
    const stream_ctx: *StreamChunkContext = @ptrCast(@alignCast(ctx));
    publishTurnPhase(stream_ctx, .running);
    if (stream_ctx.token_progress) |progress| {
        pushTokenProgressUpdate(stream_ctx, progress.consumeToolInput(chunk)) catch |err| {
            debug_trace.logf("agent", "token progress publication failed source=tool_input err={s}", .{@errorName(err)});
        };
    }
}

pub fn pushTokenProgressUpdate(stream_ctx: *StreamChunkContext, update: runtime_telemetry.TokenProgressUpdate) !void {
    switch (update) {
        .unchanged => {},
        .changed => {
            const progress = stream_ctx.token_progress orelse return;
            try stream_ctx.hooks.push_event(stream_ctx.hooks.ctx, .{ .turn_token_update = progress.tokenProgress() });
        },
        .invalid => debug_trace.logf("agent", "token progress observation ignored reason=invalid_sequence", .{}),
    }
}

pub fn onStreamToolStart(ctx: *anyopaque, tool_id: []const u8, tool_name: []const u8, label_value: ?[]const u8) void {
    const stream_ctx: *StreamChunkContext = @ptrCast(@alignCast(ctx));
    const first_tool_in_step = !stream_ctx.saw_tool_start;
    recordStreamToolStart(ctx, tool_name);
    const preflight = runtime_tool_presentation.ProvisionalToolStatuses.preflight(stream_ctx.hooks.tool_registry, tool_name) orelse {
        publishTurnPhase(stream_ctx, .running);
        return;
    };
    stream_ctx.markModelOutput();
    flushAssistantStream(stream_ctx) catch {};
    if (stream_ctx.saw_visible_text and !stream_ctx.last_byte_was_newline) {
        stream_ctx.hooks.push_text(stream_ctx.hooks.ctx, .{ .assistant_rendered = "\n" }) catch {};
        stream_ctx.recordTextOutput("\n");
    }
    if (first_tool_in_step and
        stream_ctx.saw_visible_text and
        stream_ctx.turn_id != 0 and
        stream_ctx.step_id != 0)
    {
        stream_ctx.provisional_statuses.presentation_group_id = .{
            .turn_id = stream_ctx.turn_id,
            .anchor_step_id = stream_ctx.step_id,
        };
    }
    publishTurnPhase(stream_ctx, .running);
    switch (preflight) {
        // Published last: the flush above can push the response's trailing
        // newline, and any text landing after the notice reopens the response
        // row.
        .ineligible => {},
        .eligible => |metadata| stream_ctx.provisional_statuses.publish(
            stream_ctx.hooks,
            stream_ctx.alloc,
            stream_ctx.turn_id,
            tool_id,
            tool_name,
            metadata.activity_kind,
            metadata.action_label,
            label_value,
        ) catch {},
    }
}

pub fn recordStreamToolStart(ctx: *anyopaque, tool_name: []const u8) void {
    const stream_ctx: *StreamChunkContext = @ptrCast(@alignCast(ctx));
    stream_ctx.saw_tool_start = true;
    if (runtime_tool_presentation.streamStartMayHaveExecutedAtProvider(
        stream_ctx.hooks.tool_registry,
        tool_name,
    )) {
        stream_ctx.saw_provider_tool_start = true;
    }
}

fn streamAssistantChunk(stream_ctx: *StreamChunkContext, chunk: []const u8) !void {
    if (chunk.len == 0) return;
    const alloc = stream_ctx.alloc;
    try stream_ctx.raw_text.appendSlice(alloc, chunk);
    if (stream_ctx.response_language_staging()) {
        if (stream_ctx.response_language_hold_until_completion) return;
        if (stream_ctx.raw_text.items.len >= stream_ctx.response_language_next_probe_bytes) {
            const prefix_len = @min(
                stream_ctx.raw_text.items.len,
                response_language_probe_limit_bytes,
            );
            const prefix = stream_ctx.raw_text.items[0..prefix_len];
            if (response_language.evidence(prefix).script == stream_ctx.response_language_expected) {
                try stream_ctx.accept_staged_response_language();
            } else if (prefix_len == response_language_probe_limit_bytes) {
                stream_ctx.response_language_next_probe_bytes = std.math.maxInt(usize);
            } else {
                stream_ctx.response_language_next_probe_bytes = @min(
                    response_language_probe_limit_bytes,
                    @max(stream_ctx.raw_text.items.len +| 1, stream_ctx.raw_text.items.len *| 2),
                );
            }
        }
        return;
    }
    try publishAssistantChunkResolved(stream_ctx, chunk);
}

fn publishAssistantChunkResolved(stream_ctx: *StreamChunkContext, chunk: []const u8) !void {
    if (chunk.len == 0) return;
    const alloc = stream_ctx.alloc;
    try stream_ctx.start_response();
    try stream_ctx.hooks.push_text(stream_ctx.hooks.ctx, .{ .assistant_source = chunk });
    if (!stream_ctx.hooks.render_assistant_text) {
        if (std.mem.trim(u8, chunk, " \t\r\n").len > 0) stream_ctx.saw_visible_text = true;
        stream_ctx.recordTextOutput(chunk);
        return;
    }

    var start: usize = 0;
    var initial_prefix_to_emit: ?[]const u8 = null;
    var clear_initial_line_prefix = false;
    defer if (clear_initial_line_prefix) stream_ctx.initial_line_prefix.clearRetainingCapacity();
    if (!stream_ctx.saw_visible_text) {
        while (start < chunk.len and isTrimmedAssistantPrefixByte(chunk[start])) : (start += 1) {
            switch (chunk[start]) {
                ' ', '\t' => try stream_ctx.initial_line_prefix.append(alloc, chunk[start]),
                '\n' => stream_ctx.initial_line_prefix.clearRetainingCapacity(),
                else => {},
            }
        }
        if (start == chunk.len) return;
        if (hasResponseLeadingIndentedCodePrefix(stream_ctx.initial_line_prefix.items)) {
            initial_prefix_to_emit = stream_ctx.initial_line_prefix.items;
        }
        stream_ctx.saw_visible_text = true;
        clear_initial_line_prefix = true;
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    var completion = assistant_presentation.TableCompletion{
        .ctx = stream_ctx,
        .deliver = deliverSemanticTable,
    };
    var code_completion = assistant_presentation.CodeBlockCompletion{
        .ctx = stream_ctx,
        .deliver = deliverSemanticCodeBlock,
    };
    var thematic_rule_completion = assistant_presentation.ThematicRuleCompletion{
        .ctx = stream_ctx,
        .deliver = deliverSemanticThematicRule,
    };
    const table_completion: ?*const assistant_presentation.TableCompletion = if (stream_ctx.semantic_presentation != null)
        &completion
    else
        null;
    const semantic_code_completion: ?*const assistant_presentation.CodeBlockCompletion = if (stream_ctx.semantic_presentation != null)
        &code_completion
    else
        null;
    const semantic_thematic_rule_completion: ?*const assistant_presentation.ThematicRuleCompletion = if (stream_ctx.semantic_presentation != null)
        &thematic_rule_completion
    else
        null;
    if (initial_prefix_to_emit) |prefix| {
        try stream_ctx.markdown.pushWithCompletions(alloc, prefix, &out, .{
            .table = table_completion,
            .code = semantic_code_completion,
            .thematic_rule = semantic_thematic_rule_completion,
        });
    }
    try stream_ctx.markdown.pushWithCompletions(alloc, chunk[start..], &out, .{
        .table = table_completion,
        .code = semantic_code_completion,
        .thematic_rule = semantic_thematic_rule_completion,
    });
    if (out.items.len == 0) return;
    try stream_ctx.hooks.push_text(stream_ctx.hooks.ctx, .{ .assistant_rendered = out.items });
    stream_ctx.recordTextOutput(out.items);
}

pub fn flushAssistantStream(stream_ctx: *StreamChunkContext) !void {
    if (stream_ctx.response_language_staging()) return;
    if (!stream_ctx.hooks.render_assistant_text) return;
    const alloc = stream_ctx.alloc;
    stream_ctx.initial_line_prefix.clearRetainingCapacity();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    var completion = assistant_presentation.TableCompletion{
        .ctx = stream_ctx,
        .deliver = deliverSemanticTable,
    };
    var code_completion = assistant_presentation.CodeBlockCompletion{
        .ctx = stream_ctx,
        .deliver = deliverSemanticCodeBlock,
    };
    var thematic_rule_completion = assistant_presentation.ThematicRuleCompletion{
        .ctx = stream_ctx,
        .deliver = deliverSemanticThematicRule,
    };
    const table_completion: ?*const assistant_presentation.TableCompletion = if (stream_ctx.semantic_presentation != null)
        &completion
    else
        null;
    const semantic_code_completion: ?*const assistant_presentation.CodeBlockCompletion = if (stream_ctx.semantic_presentation != null)
        &code_completion
    else
        null;
    const semantic_thematic_rule_completion: ?*const assistant_presentation.ThematicRuleCompletion = if (stream_ctx.semantic_presentation != null)
        &thematic_rule_completion
    else
        null;
    try stream_ctx.markdown.flushWithCompletions(alloc, &out, .{
        .table = table_completion,
        .code = semantic_code_completion,
        .thematic_rule = semantic_thematic_rule_completion,
    });
    if (out.items.len == 0) return;
    const text = if (stream_ctx.trailing_newline_count >= 2 and beginsFootnoteProjection(out.items))
        out.items[1..]
    else
        out.items;
    try stream_ctx.hooks.push_text(stream_ctx.hooks.ctx, .{ .assistant_rendered = text });
    stream_ctx.recordTextOutput(text);
}

fn beginsFootnoteProjection(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "\n\x1b[2m[");
}

fn deliverSemanticTable(raw: *anyopaque, table: TablePayload, out: *std.ArrayList(u8)) !void {
    const stream_ctx: *StreamChunkContext = @ptrCast(@alignCast(raw));
    const alloc = stream_ctx.alloc;

    if (out.items.len > 0) {
        try stream_ctx.hooks.push_text(stream_ctx.hooks.ctx, .{ .assistant_rendered = out.items });
        stream_ctx.recordTextOutput(out.items);
        out.clearRetainingCapacity();
    }

    var compatibility: std.ArrayList(u8) = .empty;
    defer compatibility.deinit(alloc);
    try assistant_presentation.renderTablePayload(alloc, table, &compatibility);
    const sink = stream_ctx.semantic_presentation orelse return error.MissingTableSink;
    try sink.table(sink.ctx, table);
    stream_ctx.recordSemanticBoundary();
}

fn deliverSemanticCodeBlock(raw: *anyopaque, block: CodeBlockPayload, out: *std.ArrayList(u8)) !void {
    const stream_ctx: *StreamChunkContext = @ptrCast(@alignCast(raw));
    const alloc = stream_ctx.alloc;

    if (out.items.len > 0) {
        try stream_ctx.hooks.push_text(stream_ctx.hooks.ctx, .{ .assistant_rendered = out.items });
        stream_ctx.recordTextOutput(out.items);
        out.clearRetainingCapacity();
    }

    var compatibility: std.ArrayList(u8) = .empty;
    defer compatibility.deinit(alloc);
    try assistant_presentation.renderCodeBlockPayload(alloc, block, &compatibility);
    const sink = stream_ctx.semantic_presentation orelse return error.MissingCodeBlockSink;
    try sink.code_block(sink.ctx, block);
    stream_ctx.recordSemanticBoundary();
}

fn deliverSemanticThematicRule(raw: *anyopaque, out: *std.ArrayList(u8)) !void {
    const stream_ctx: *StreamChunkContext = @ptrCast(@alignCast(raw));
    const alloc = stream_ctx.alloc;

    if (out.items.len > 0) {
        try stream_ctx.hooks.push_text(stream_ctx.hooks.ctx, .{ .assistant_rendered = out.items });
        stream_ctx.recordTextOutput(out.items);
        out.clearRetainingCapacity();
    }

    var compatibility: std.ArrayList(u8) = .empty;
    defer compatibility.deinit(alloc);
    try assistant_presentation.writeHorizontalRule(alloc, &compatibility);
    const sink = stream_ctx.semantic_presentation orelse return error.MissingThematicRuleSink;
    try sink.thematic_rule(sink.ctx);
    stream_ctx.recordSemanticBoundary();
}

pub fn emitProviderLengthNotice(hooks: *const AgentRuntimeDeps, arena: Allocator, disposition: types.ProviderCompletionDisposition) !void {
    if (disposition != .length_limited) return;
    const line = try std.fmt.allocPrint(arena, "response hit provider length limit; output may be incomplete", .{});
    try hooks.push_system_notice(hooks.ctx, line);
}

pub fn finishLengthLimitedToolCallCompletion(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    completion: types.ModelCompletion,
    streamed_content_len: usize,
) ![]const u8 {
    const blocker = "Provider response hit the length limit, so I did not execute the returned tool calls. Latest partial response is preserved above; retry with a narrower prompt or inspect stored tool output before continuing.";

    const has_content = completion.content != null and completion.content.?.len > 0;
    const normalized = if (has_content) try normalizeAssistantTextForDisplay(arena, completion.content.?) else "";
    const rendered = if (normalized.len > 0)
        try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ normalized, blocker })
    else
        blocker;

    if (!has_content or streamed_content_len == 0) {
        if (has_content) {
            try hooks.push_text(hooks.ctx, .{ .assistant_source = completion.content.? });
            try hooks.push_text(hooks.ctx, .{ .assistant_rendered = normalized });
            try hooks.push_text(hooks.ctx, .{ .operational = "\n\n" });
        }
        try hooks.push_text(hooks.ctx, .{ .operational = blocker });
        try hooks.push_text(hooks.ctx, .{ .operational = "\n" });
    } else {
        try hooks.push_text(hooks.ctx, .{ .operational = "\n" });
        try hooks.push_text(hooks.ctx, .{ .operational = blocker });
        try hooks.push_text(hooks.ctx, .{ .operational = "\n" });
    }
    return rendered;
}

pub fn normalizeAssistantTextForDisplay(alloc: Allocator, raw_text: []const u8) ![]u8 {
    const base = sanitizeAssistantText(raw_text);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    var saw_visible_text = false;
    var pending_stars: u8 = 0;

    for (base) |byte| {
        if (!saw_visible_text and isTrimmedAssistantPrefixByte(byte)) {
            continue;
        }
        saw_visible_text = true;

        if (byte == '*') {
            if (pending_stars < std.math.maxInt(u8)) {
                pending_stars += 1;
            }
            continue;
        }
        pending_stars = 0;

        if (byte == '`') continue;
        try out.writer.writeByte(byte);
    }

    const rendered = std.mem.trimEnd(u8, out.written(), " \t\r\n");
    const owned = try out.toOwnedSlice();
    if (rendered.len == owned.len) return owned;

    const trimmed = try alloc.dupe(u8, rendered);
    alloc.free(owned);
    return trimmed;
}

pub fn textForCompletedPresentation(raw_text: []const u8, normalized_text: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, raw_text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) {
            return raw_text;
        }
    }
    return normalized_text;
}

test "completed presentation preserves fenced code while ordinary text stays normalized" {
    const fenced = "```\nconst hook = await resumeHook(token, { cleanup: true } as CleanupSignal);\n```";
    const tilde_fenced = "~~~zig\nconst hook = await resumeHook(token, { cleanup: true } as CleanupSignal);\n~~~";

    try std.testing.expectEqualStrings(
        fenced,
        textForCompletedPresentation(fenced, "const hook = await resumeHook(token, { cleanup: true } as CleanupSignal);"),
    );
    try std.testing.expectEqualStrings(
        tilde_fenced,
        textForCompletedPresentation(tilde_fenced, "const hook = await resumeHook(token, { cleanup: true } as CleanupSignal);"),
    );
    try std.testing.expectEqualStrings(
        "Hello",
        textForCompletedPresentation(" **Hello** ", "Hello"),
    );
}

fn isTrimmedAssistantPrefixByte(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

fn hasResponseLeadingIndentedCodePrefix(prefix: []const u8) bool {
    return prefix.len > 0 and (prefix[0] == '\t' or (prefix.len >= 4 and std.mem.eql(u8, prefix[0..4], "    ")));
}

const NoticeCapture = struct {
    notices: std.ArrayList([]u8) = .empty,

    fn deinit(self: *@This(), alloc: Allocator) void {
        for (self.notices.items) |notice| alloc.free(notice);
        self.notices.deinit(alloc);
    }

    fn hooks(self: *@This()) AgentRuntimeDeps {
        return .{
            .ctx = self,
            .tool_registry = test_tool_registry,
            .append_runtime_context = appendRuntimeContext,
            .request_tool_permission = requestPermission,
            .describe_tool_action = describeAction,
            .describe_tool_action_completed = describeAction,
            .describe_tool_action_denied = describeDenied,
            .permission_target_for_call = permissionTarget,
            .execute_tool_call = execute,
            .publish_committed_file_handoff = publishCommittedFileHandoff,
            .propagate_history_turn = propagateHistory,
            .propagate_grant = propagateGrant,
            .push_event = pushEvent,
            .push_text = pushText,
            .push_diff_block = pushDiff,
            .push_system_notice = systemNotice,
            .push_command_output_complete = commandOutputComplete,
            .push_http_error = httpError,
            .format_tool_execution_error = formatError,
        };
    }

    fn appendRuntimeContext(_: *anyopaque, _: Allocator, _: *std.ArrayList(ChatMessage)) !void {}

    fn requestPermission(_: *anyopaque, _: Allocator, _: ToolCall, _: permission_auto_classifier.ReviewTurnContext, _: PermissionMode, _: []const PermissionGrant, _: ?runtime_tool_contracts.LiveToolAuthority, _: ?runtime_tool_contracts.LivePermissionRevalidation, _: []const []const u8, _: ?[]const u8) !command_admission.PermissionOutcome {
        return .{
            .decision = .once,
            .execution_authority = .ordinary,
        };
    }

    fn describeAction(_: *anyopaque, arena: Allocator, call: ToolCall, _: ?[]const u8, _: []const []const u8) ![]const u8 {
        return arena.dupe(u8, call.name);
    }

    fn describeDenied(_: *anyopaque, arena: Allocator, call: ToolCall, _: ?[]const u8, label: []const u8, _: []const []const u8) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s} {s}", .{ label, call.name });
    }

    fn permissionTarget(_: *anyopaque, arena: Allocator, _: ToolCall, _: []const []const u8) ![]const u8 {
        return arena.dupe(u8, "");
    }

    fn execute(
        _: *anyopaque,
        _: runtime_tool_contracts.ToolExecutionRequest,
    ) !ToolExecutionResult {
        return .{ .model_output = "" };
    }

    fn publishCommittedFileHandoff(
        _: *anyopaque,
        _: file_mutation.CommittedFileHandoff,
    ) SecondaryPublicationReport {
        return .{ .diff = .skipped, .tracker = .skipped };
    }

    fn propagateHistory(_: *anyopaque, _: HistoryTurn) !void {}
    fn propagateGrant(_: *anyopaque, _: []const u8, _: []const u8) !void {}
    fn pushEvent(_: *anyopaque, _: WorkerEvent) !void {}
    fn pushText(_: *anyopaque, _: runtime_deps.TextEmission) !void {}
    fn pushDiff(_: *anyopaque, _: DiffEntryPayload) !void {}

    fn systemNotice(raw: *anyopaque, text: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        try self.notices.append(std.testing.allocator, try std.testing.allocator.dupe(u8, text));
    }

    fn commandOutputComplete(_: *anyopaque, _: ?types.ToolLifecycleId) !void {}
    fn httpError(_: *anyopaque, _: std.http.Status, _: []const u8, _: ?types.CredentialSource) !void {}

    fn formatError(_: *anyopaque, arena: Allocator, _: []const u8, err: anyerror) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s}", .{@errorName(err)});
    }
};

const StreamCapture = struct {
    lifecycle_events: std.ArrayList(types.ToolLifecycleEvent) = .empty,
    source_spans: std.ArrayList([]u8) = .empty,
    text_spans: std.ArrayList([]u8) = .empty,
    tables: std.ArrayList(TablePayload) = .empty,
    code_blocks: std.ArrayList(assistant_presentation.CodeBlockPayload) = .empty,
    thematic_rule_count: usize = 0,
    token_progress_updates: std.ArrayList(types.TurnTokenProgress) = .empty,
    phase_updates: std.ArrayList(types.TurnPhase) = .empty,
    trace: std.ArrayList(StreamTraceEntry) = .empty,
    presentation_order: std.ArrayList(PresentationEntry) = .empty,
    capture_alloc: Allocator = std.testing.allocator,
    event_error: ?anyerror = null,
    source_error: ?anyerror = null,
    text_error: ?anyerror = null,
    lifecycle_error: ?anyerror = null,
    event_calls: usize = 0,
    source_calls: usize = 0,
    text_calls: usize = 0,
    lifecycle_calls: usize = 0,

    fn deinit(self: *@This(), alloc: Allocator) void {
        self.lifecycle_events.deinit(alloc);
        for (self.source_spans.items) |text| alloc.free(text);
        self.source_spans.deinit(alloc);
        for (self.text_spans.items) |text| alloc.free(text);
        self.text_spans.deinit(alloc);
        for (self.tables.items) |*table| table.deinit(alloc);
        self.tables.deinit(alloc);
        for (self.code_blocks.items) |*block| block.deinit(alloc);
        self.code_blocks.deinit(alloc);
        self.token_progress_updates.deinit(alloc);
        self.phase_updates.deinit(alloc);
        self.trace.deinit(alloc);
        self.presentation_order.deinit(alloc);
    }

    fn hooks(self: *@This()) AgentRuntimeDeps {
        return .{
            .ctx = self,
            .tool_registry = test_tool_registry,
            .append_runtime_context = noopAppendRuntimeContext,
            .request_tool_permission = noopRequestPermission,
            .describe_tool_action = noopDescribeAction,
            .describe_tool_action_completed = noopDescribeAction,
            .describe_tool_action_denied = noopDescribeDenied,
            .permission_target_for_call = noopPermissionTarget,
            .execute_tool_call = noopExecute,
            .publish_committed_file_handoff = noopPublishCommittedFileHandoff,
            .propagate_history_turn = noopPropagateHistory,
            .propagate_grant = noopPropagateGrant,
            .push_event = captureEvent,
            .push_text = captureText,
            .push_tool_lifecycle = captureToolLifecycle,
            .push_diff_block = noopPushDiff,
            .push_system_notice = noopSystemNotice,
            .push_command_output_complete = noopCommandOutputComplete,
            .push_http_error = noopHttpError,
            .format_tool_execution_error = noopFormatError,
        };
    }

    fn semanticPresentationSink(self: *@This()) SemanticPresentationSink {
        return .{
            .ctx = self,
            .table = captureTable,
            .code_block = captureCodeBlock,
            .thematic_rule = captureThematicRule,
        };
    }

    fn noopAppendRuntimeContext(_: *anyopaque, _: Allocator, _: *std.ArrayList(ChatMessage)) !void {}
    fn noopRequestPermission(_: *anyopaque, _: Allocator, _: ToolCall, _: permission_auto_classifier.ReviewTurnContext, _: PermissionMode, _: []const PermissionGrant, _: ?runtime_tool_contracts.LiveToolAuthority, _: ?runtime_tool_contracts.LivePermissionRevalidation, _: []const []const u8, _: ?[]const u8) !command_admission.PermissionOutcome {
        return .{ .decision = .once, .execution_authority = .ordinary };
    }
    fn noopDescribeAction(_: *anyopaque, arena: Allocator, call: ToolCall, _: ?[]const u8, _: []const []const u8) ![]const u8 {
        return arena.dupe(u8, call.name);
    }
    fn noopDescribeDenied(_: *anyopaque, arena: Allocator, call: ToolCall, _: ?[]const u8, label: []const u8, _: []const []const u8) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s} {s}", .{ label, call.name });
    }
    fn noopPermissionTarget(_: *anyopaque, arena: Allocator, _: ToolCall, _: []const []const u8) ![]const u8 {
        return arena.dupe(u8, "");
    }
    fn noopExecute(_: *anyopaque, _: runtime_tool_contracts.ToolExecutionRequest) !ToolExecutionResult {
        return .{ .model_output = "" };
    }
    fn noopPublishCommittedFileHandoff(_: *anyopaque, _: file_mutation.CommittedFileHandoff) SecondaryPublicationReport {
        return .{ .diff = .skipped, .tracker = .skipped };
    }
    fn noopPropagateHistory(_: *anyopaque, _: HistoryTurn) !void {}
    fn noopPropagateGrant(_: *anyopaque, _: []const u8, _: []const u8) !void {}
    fn noopPushDiff(_: *anyopaque, _: DiffEntryPayload) !void {}
    fn noopSystemNotice(_: *anyopaque, _: []const u8) !void {}
    fn noopCommandOutputComplete(_: *anyopaque, _: ?types.ToolLifecycleId) !void {}
    fn noopHttpError(_: *anyopaque, _: std.http.Status, _: []const u8, _: ?types.CredentialSource) !void {}
    fn noopFormatError(_: *anyopaque, arena: Allocator, _: []const u8, err: anyerror) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s}", .{@errorName(err)});
    }

    fn captureToolLifecycle(raw: *anyopaque, event: types.ToolLifecycleEvent) !void {
        const self: *StreamCapture = @ptrCast(@alignCast(raw));
        self.lifecycle_calls += 1;
        if (self.lifecycle_error) |err| return err;
        try self.lifecycle_events.append(self.capture_alloc, event);
        const index = self.lifecycle_events.items.len - 1;
        switch (event) {
            .provisional => try self.trace.append(self.capture_alloc, .{ .provisional = index }),
            .progress => try self.trace.append(self.capture_alloc, .{ .progress = index }),
            else => {},
        }
    }

    fn captureEvent(raw: *anyopaque, event: WorkerEvent) !void {
        const self: *StreamCapture = @ptrCast(@alignCast(raw));
        self.event_calls += 1;
        if (self.event_error) |err| return err;
        const progress = switch (event) {
            .turn_token_update => |update| update,
            .turn_phase_update => |update| {
                try self.phase_updates.append(self.capture_alloc, update.phase);
                try self.trace.append(self.capture_alloc, .{ .turn_phase = update.phase });
                return;
            },
            else => return,
        };
        try self.token_progress_updates.append(self.capture_alloc, progress);
    }

    fn captureText(raw: *anyopaque, emission: runtime_deps.TextEmission) !void {
        const self: *StreamCapture = @ptrCast(@alignCast(raw));
        switch (emission) {
            .assistant_started => return,
            .assistant_source => |text| {
                self.source_calls += 1;
                if (self.source_error) |err| return err;
                try self.source_spans.ensureUnusedCapacity(self.capture_alloc, 1);
                const owned = try self.capture_alloc.dupe(u8, text);
                self.source_spans.appendAssumeCapacity(owned);
                return;
            },
            .assistant_rendered, .assistant_restarted, .operational => {},
        }

        self.text_calls += 1;
        if (self.text_error) |err| return err;

        const text = switch (emission) {
            .assistant_started => unreachable,
            .assistant_source => unreachable,
            .assistant_rendered => |text| text,
            .assistant_restarted => |text| text,
            .operational => |text| text,
        };

        try self.text_spans.ensureUnusedCapacity(self.capture_alloc, 1);
        try self.presentation_order.ensureUnusedCapacity(self.capture_alloc, 1);
        try self.trace.ensureUnusedCapacity(self.capture_alloc, 1);
        const owned = try self.capture_alloc.dupe(u8, text);
        self.text_spans.appendAssumeCapacity(owned);
        self.presentation_order.appendAssumeCapacity(.text);
        self.trace.appendAssumeCapacity(.{ .text = self.text_spans.items.len - 1 });
    }

    fn captureTable(raw: *anyopaque, table: TablePayload) !void {
        const self: *StreamCapture = @ptrCast(@alignCast(raw));
        try self.tables.ensureUnusedCapacity(self.capture_alloc, 1);
        try self.presentation_order.ensureUnusedCapacity(self.capture_alloc, 1);
        self.tables.appendAssumeCapacity(table);
        self.presentation_order.appendAssumeCapacity(.table);
    }

    fn captureCodeBlock(raw: *anyopaque, block: assistant_presentation.CodeBlockPayload) !void {
        const self: *StreamCapture = @ptrCast(@alignCast(raw));
        try self.code_blocks.ensureUnusedCapacity(self.capture_alloc, 1);
        try self.presentation_order.ensureUnusedCapacity(self.capture_alloc, 1);
        self.code_blocks.appendAssumeCapacity(block);
        self.presentation_order.appendAssumeCapacity(.code_block);
    }

    fn captureThematicRule(raw: *anyopaque) !void {
        const self: *StreamCapture = @ptrCast(@alignCast(raw));
        try self.presentation_order.append(self.capture_alloc, .thematic_rule);
        self.thematic_rule_count += 1;
    }
};

test "provider callbacks publish each activity phase transition once" {
    const alloc = std.testing.allocator;
    var capture = StreamCapture{};
    defer capture.deinit(alloc);
    var hook_set = capture.hooks();
    var stream_ctx = StreamChunkContext{
        .hooks = &hook_set,
        .turn_id = 7,
        .step_id = 11,
        .alloc = alloc,
    };
    defer stream_ctx.deinit();

    onStreamReasoningChunk(&stream_ctx, "reasoning");
    onStreamReasoningChunk(&stream_ctx, " continues");
    onStreamContentChunk(&stream_ctx, "response");
    onStreamContentChunk(&stream_ctx, " continues\n");
    onStreamToolStart(&stream_ctx, "command_1", "shell", null);

    try std.testing.expectEqualSlices(
        types.TurnPhase,
        &.{ .thinking, .generating, .running },
        capture.phase_updates.items,
    );
}

const PresentationEntry = enum { text, table, code_block, thematic_rule };

const StreamTraceEntry = union(enum) {
    text: usize,
    provisional: usize,
    progress: usize,
    turn_phase: types.TurnPhase,
};

const ansi_span_fixture_env = "FX_TEST_C04_STREAM_ANSI_OSC8_FIXTURE";
const ansi_span_test_name = "streamed presentation preserves ANSI OSC 8 code fence and table spans";

fn ansi_span_fixture_enabled() bool {
    const value = std.process.Environ.getAlloc(
        std.testing.environ,
        std.testing.allocator,
        ansi_span_fixture_env,
    ) catch return false;
    defer std.testing.allocator.free(value);
    return std.mem.eql(u8, value, "1");
}

fn assert_frozen_ansi_span_fixture() !void {
    const alloc = std.testing.allocator;
    var capture = StreamCapture{};
    defer capture.deinit(alloc);
    var hook_set = capture.hooks();
    var stream_ctx = StreamChunkContext{
        .hooks = &hook_set,
        .semantic_presentation = null,
        .turn_id = 1,
        .alloc = alloc,
    };
    defer stream_ctx.deinit();

    try streamAssistantChunk(&stream_ctx, "**bo");
    try streamAssistantChunk(&stream_ctx, "ld** and *it");
    try streamAssistantChunk(&stream_ctx, "alic*\n");
    try streamAssistantChunk(&stream_ctx, "[docs](https://example.com)\n");
    try streamAssistantChunk(&stream_ctx, "https://example.com/docs,\n");

    var oversized_url: [3000]u8 = undefined;
    @memset(&oversized_url, 'a');
    var oversized_line_buf: [3072]u8 = undefined;
    const oversized_line = try std.fmt.bufPrint(
        &oversized_line_buf,
        "literal [x]({s})\n",
        .{oversized_url[0..]},
    );
    try streamAssistantChunk(&stream_ctx, oversized_line);

    try streamAssistantChunk(&stream_ctx, "```zig\n");
    try streamAssistantChunk(&stream_ctx, "const x = **literal**;\n");
    try streamAssistantChunk(&stream_ctx, "```\n");

    try streamAssistantChunk(&stream_ctx, "| Name | Age |\n");
    try streamAssistantChunk(&stream_ctx, "|------|-----|\n");
    try streamAssistantChunk(&stream_ctx, "| Ana  | 30  |\n");
    try flushAssistantStream(&stream_ctx);

    try streamAssistantChunk(&stream_ctx, "tail **open");
    try flushAssistantStream(&stream_ctx);

    const expected_spans = [_][]const u8{
        "\x1b[1mbold\x1b[22m and \x1b[3mitalic\x1b[23m\n",
        "\x1b]8;id=fx-1;https://example.com\x1b\\\x1b[4mdocs\x1b[24m\x1b]8;;\x1b\\\n",
        "\x1b]8;id=fx-2;https://example.com/docs\x1b\\\x1b[4mhttps://example.com/docs\x1b[24m\x1b]8;;\x1b\\,\n",
        oversized_line,
        "\x1b[2m\xe2\x94\x82 \x1b[22mconst x = **literal**;\n",
        "\x1b[1mName\x1b[22m \xe2\x94\x82 \x1b[1mAge\x1b[22m\n" ++
            "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\xbc\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n" ++
            "Ana  \xe2\x94\x82 30 \n",
        "tail \x1b[1mopen\x1b[22m",
    };

    try std.testing.expectEqual(expected_spans.len, capture.text_spans.items.len);
    for (expected_spans, capture.text_spans.items) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
    try std.testing.expect(std.mem.find(u8, capture.text_spans.items[3], "\x1b]8;") == null);
}

test "streamed tool starts emit lifecycle only for identified read-only tools" {
    const alloc = std.testing.allocator;
    var capture = StreamCapture{};
    defer capture.deinit(alloc);
    var hook_set = capture.hooks();
    var stream_ctx = StreamChunkContext{
        .hooks = &hook_set,
        .turn_id = 1,
        .alloc = alloc,
    };
    defer stream_ctx.deinit();

    onStreamToolStart(&stream_ctx, "write_1", "write_file", "file1.txt");
    onStreamToolStart(&stream_ctx, "edit_1", "edit_file", "file2.txt");
    onStreamToolStart(&stream_ctx, "ask_1", "request_user_input", null);
    onStreamToolStart(&stream_ctx, "", "read_file", "src/main.zig");

    try std.testing.expect(stream_ctx.first_model_output_at_ms != null);
    try std.testing.expectEqual(@as(usize, 0), capture.lifecycle_events.items.len);

    onStreamToolStart(&stream_ctx, "read_1", "read_file", "src/main.zig");

    try std.testing.expectEqual(@as(usize, 2), capture.lifecycle_events.items.len);
    try std.testing.expectEqualStrings(
        "read_1",
        capture.lifecycle_events.items[0].provisional.id.call_id,
    );
    try std.testing.expectEqualStrings(
        "read_file",
        capture.lifecycle_events.items[0].provisional.tool_name.?,
    );
    try std.testing.expectEqualStrings(
        "read_1",
        capture.lifecycle_events.items[1].progress.id.call_id,
    );
}

test "streamed unknown tool start preserves the buffered stream boundary" {
    const alloc = std.testing.allocator;
    var capture = StreamCapture{};
    defer capture.deinit(alloc);
    var hook_set = capture.hooks();
    var stream_ctx = StreamChunkContext{ .hooks = &hook_set, .turn_id = 1, .alloc = alloc };
    defer stream_ctx.deinit();

    try streamAssistantChunk(&stream_ctx, "buffered text");
    onStreamToolStart(&stream_ctx, "unknown_1", "unknown_tool", null);

    try std.testing.expect(stream_ctx.first_model_output_at_ms == null);
    try std.testing.expectEqualStrings("buffered text", stream_ctx.raw_text.items);
    try std.testing.expectEqual(@as(usize, 0), capture.text_spans.items.len);
    try std.testing.expectEqual(@as(usize, 0), capture.lifecycle_events.items.len);
}

test "streamed presentation preserves fragmented byte spans and raw capture" {
    const alloc = std.testing.allocator;
    var capture = StreamCapture{};
    defer capture.deinit(alloc);
    var hook_set = capture.hooks();
    var stream_ctx = StreamChunkContext{ .hooks = &hook_set, .turn_id = 1, .alloc = alloc };
    defer stream_ctx.deinit();

    try streamAssistantChunk(&stream_ctx, " \t");
    try std.testing.expectEqual(@as(usize, 0), capture.text_spans.items.len);

    try streamAssistantChunk(&stream_ctx, "\n");
    try std.testing.expectEqual(@as(usize, 0), capture.text_spans.items.len);

    try streamAssistantChunk(&stream_ctx, "first");
    try std.testing.expectEqual(@as(usize, 0), capture.text_spans.items.len);

    try streamAssistantChunk(&stream_ctx, " line\n");
    try streamAssistantChunk(&stream_ctx, "second");
    try streamAssistantChunk(&stream_ctx, " line\n");

    try std.testing.expectEqualStrings(" \t\nfirst line\nsecond line\n", stream_ctx.raw_text.items);
    const expected_source_spans = [_][]const u8{ " \t", "\n", "first", " line\n", "second", " line\n" };
    try std.testing.expectEqual(expected_source_spans.len, capture.source_spans.items.len);
    for (expected_source_spans, capture.source_spans.items) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
    try std.testing.expectEqual(@as(usize, 2), capture.text_spans.items.len);
    try std.testing.expectEqualStrings("first line\n", capture.text_spans.items[0]);
    try std.testing.expectEqualStrings("second line\n", capture.text_spans.items[1]);
}

test "source-only consumers preserve bytes without Markdown work across restart" {
    const alloc = std.testing.allocator;
    var capture = StreamCapture{};
    defer capture.deinit(alloc);
    var hook_set = capture.hooks();
    hook_set.render_assistant_text = false;
    var stream_ctx = StreamChunkContext{
        .hooks = &hook_set,
        .semantic_presentation = capture.semanticPresentationSink(),
        .turn_id = 1,
        .alloc = alloc,
    };
    defer stream_ctx.deinit();
    const source = " \t\n# Heading\n[link](https://example.com)\n```zig\nconst n =";
    try streamAssistantChunk(&stream_ctx, source);
    try flushAssistantStream(&stream_ctx);
    try std.testing.expectEqualStrings(source, stream_ctx.accepted_source());
    try std.testing.expectEqualStrings(source, capture.source_spans.items[0]);
    try std.testing.expectEqual(@as(usize, 0), capture.text_spans.items.len);
    try std.testing.expectEqual(@as(usize, 0), capture.code_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 0), stream_ctx.markdown.line_buf.capacity);
    try stream_ctx.beginRecoveryAttempt();
    try streamAssistantChunk(&stream_ctx, "Replacement.");
    try flushAssistantStream(&stream_ctx);
    try std.testing.expectEqualStrings("Replacement.", stream_ctx.accepted_source());
    try std.testing.expectEqualStrings(source, stream_ctx.interrupted_source.items);
    try std.testing.expectEqual(@as(usize, 1), capture.text_spans.items.len);
    try std.testing.expect(std.mem.find(u8, capture.text_spans.items[0], "Response interrupted") != null);
}

test "recovery starts a fresh response while retaining interrupted evidence" {
    const alloc = std.testing.allocator;
    var capture = StreamCapture{};
    defer capture.deinit(alloc);
    var hook_set = capture.hooks();
    var stream_ctx = StreamChunkContext{ .hooks = &hook_set, .turn_id = 1, .alloc = alloc };
    defer stream_ctx.deinit();

    try streamAssistantChunk(&stream_ctx, "software");
    try stream_ctx.beginRecoveryAttempt();
    try std.testing.expectEqualStrings("", stream_ctx.accepted_source());
    try std.testing.expectEqualStrings("software", stream_ctx.interruption_source_or(""));
    try std.testing.expect(std.mem.find(u8, capture.text_spans.items[capture.text_spans.items.len - 1], "Response interrupted") != null);
    try streamAssistantChunk(&stream_ctx, "2. A complete replacement.");
    try flushAssistantStream(&stream_ctx);
    try std.testing.expectEqualStrings("2. A complete replacement.", stream_ctx.accepted_source());
    try std.testing.expectEqualStrings("2. A complete replacement.", capture.source_spans.items[1]);

    try stream_ctx.beginRecoveryAttempt();
    try stream_ctx.beginRecoveryAttempt();
    try std.testing.expectEqualStrings("2. A complete replacement.", stream_ctx.interruption_source_or(""));
    try streamAssistantChunk(&stream_ctx, "2. A complete replacement.");
    try std.testing.expectEqualStrings("2. A complete replacement.", stream_ctx.accepted_source());
}

test "interruption source retains accepted preview until a valid replacement" {
    const alloc = std.testing.allocator;
    const prior = "The accepted English preview.";
    const replacement = "The valid English replacement.";
    const rejected = "我会先检查锁文件和依赖清单。";
    const cases = [_]struct {
        prior: []const u8,
        candidate: []const u8,
        interruption: []const u8,
        accepted: []const u8,
    }{
        .{ .prior = prior, .candidate = rejected, .interruption = prior, .accepted = "" },
        .{ .prior = "", .candidate = rejected, .interruption = "", .accepted = "" },
        .{ .prior = prior, .candidate = "", .interruption = prior, .accepted = "" },
        .{ .prior = prior, .candidate = replacement, .interruption = replacement, .accepted = replacement },
    };

    for (cases) |case| {
        var capture = StreamCapture{};
        defer capture.deinit(alloc);
        var hook_set = capture.hooks();
        hook_set.render_assistant_text = false;
        var stream_ctx = StreamChunkContext{
            .hooks = &hook_set,
            .turn_id = 1,
            .alloc = alloc,
            .response_language_expected = .latin,
        };
        defer stream_ctx.deinit();
        try stream_ctx.restoreRecoverySource(case.prior, true);
        try stream_ctx.beginRecoveryAttempt();
        try streamAssistantChunk(&stream_ctx, case.candidate);

        try std.testing.expectEqualStrings(case.interruption, stream_ctx.interruption_source_or(""));
        try std.testing.expectEqualStrings(case.accepted, stream_ctx.accepted_source());
        try std.testing.expectEqual(@as(usize, if (case.accepted.len == 0) 0 else 1), capture.source_spans.items.len);
    }
}

test "checkpoint recovery restarts Markdown without replaying an unfinished code fence" {
    const alloc = std.testing.allocator;
    var capture = StreamCapture{};
    defer capture.deinit(alloc);
    var hook_set = capture.hooks();
    var stream_ctx = StreamChunkContext{
        .hooks = &hook_set,
        .semantic_presentation = capture.semanticPresentationSink(),
        .turn_id = 1,
        .alloc = alloc,
    };
    defer stream_ctx.deinit();

    const partial = "Before code.\n```zig\nconst value =";
    try stream_ctx.restoreRecoverySource(partial, true);
    try std.testing.expectEqual(@as(usize, 0), capture.source_spans.items.len);
    try stream_ctx.beginRecoveryAttempt();
    const replacement = "```zig\nconst value = 2;\n```\nAfter code.\n";
    try streamAssistantChunk(&stream_ctx, replacement);
    try flushAssistantStream(&stream_ctx);

    try std.testing.expectEqualStrings(replacement, stream_ctx.accepted_source());
    try std.testing.expectEqualStrings(partial, stream_ctx.interrupted_source.items);
    try std.testing.expectEqual(@as(usize, 1), capture.source_spans.items.len);
    try std.testing.expectEqualStrings(replacement, capture.source_spans.items[0]);
    try std.testing.expectEqual(@as(usize, 1), capture.code_blocks.items.len);
    try std.testing.expectEqualStrings("const value = 2;\n", capture.code_blocks.items[0].code);
    try std.testing.expectEqualStrings("After code.\n", capture.text_spans.items[capture.text_spans.items.len - 1]);
}

test "streamed hard breaks preserve raw source and EOF backslashes" {
    const alloc = std.testing.allocator;
    var capture = StreamCapture{};
    defer capture.deinit(alloc);
    var hook_set = capture.hooks();
    var stream_ctx = StreamChunkContext{ .hooks = &hook_set, .turn_id = 1, .alloc = alloc };
    defer stream_ctx.deinit();

    try streamAssistantChunk(&stream_ctx, "hard\\");
    try std.testing.expectEqual(@as(usize, 0), capture.text_spans.items.len);

    try streamAssistantChunk(&stream_ctx, "\n");
    try std.testing.expectEqual(@as(usize, 1), capture.text_spans.items.len);
    try std.testing.expectEqualStrings("hard\n", capture.text_spans.items[0]);

    try streamAssistantChunk(&stream_ctx, "eof\\");
    try std.testing.expectEqual(@as(usize, 1), capture.text_spans.items.len);
    try flushAssistantStream(&stream_ctx);

    try std.testing.expectEqualStrings("hard\\\neof\\", stream_ctx.raw_text.items);
    try std.testing.expectEqual(@as(usize, 2), capture.text_spans.items.len);
    try std.testing.expectEqualStrings("eof\\", capture.text_spans.items[1]);
}

test "streamed heading waits for its newline and keeps heading styles" {
    const alloc = std.testing.allocator;
    var capture = StreamCapture{};
    defer capture.deinit(alloc);
    var hook_set = capture.hooks();
    var stream_ctx = StreamChunkContext{ .hooks = &hook_set, .turn_id = 1, .alloc = alloc };
    defer stream_ctx.deinit();

    try streamAssistantChunk(&stream_ctx, "# Workspace overview");
    try std.testing.expectEqual(@as(usize, 0), capture.text_spans.items.len);

    try streamAssistantChunk(&stream_ctx, "\n");
    try std.testing.expectEqual(@as(usize, 1), capture.text_spans.items.len);
    try std.testing.expectEqualStrings(
        "\x1b[1m\x1b[4mWorkspace overview\x1b[24m\x1b[22m\n",
        capture.text_spans.items[0],
    );
}

test "streamed markdown image retains raw source and publishes its rendered label" {
    const alloc = std.testing.allocator;
    var capture = StreamCapture{};
    defer capture.deinit(alloc);
    var hook_set = capture.hooks();
    var stream_ctx = StreamChunkContext{ .hooks = &hook_set, .turn_id = 1, .alloc = alloc };
    defer stream_ctx.deinit();

    try streamAssistantChunk(&stream_ctx, "![architecture");
    try std.testing.expectEqual(@as(usize, 0), capture.text_spans.items.len);
    try streamAssistantChunk(&stream_ctx, "](https://example.com/diagram.png)\n");

    try std.testing.expectEqualStrings(
        "![architecture](https://example.com/diagram.png)\n",
        stream_ctx.raw_text.items,
    );
    try std.testing.expectEqual(@as(usize, 1), capture.text_spans.items.len);
    try std.testing.expect(std.mem.indexOf(u8, capture.text_spans.items[0], "▧ architecture") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.text_spans.items[0], "![architecture]") == null);
}

test "streamed angle autolinks retain raw source and publish rendered labels" {
    const alloc = std.testing.allocator;
    var capture = StreamCapture{};
    defer capture.deinit(alloc);
    var hook_set = capture.hooks();
    var stream_ctx = StreamChunkContext{ .hooks = &hook_set, .turn_id = 1, .alloc = alloc };
    defer stream_ctx.deinit();

    try streamAssistantChunk(&stream_ctx, "see <https://example.com/");
    try std.testing.expectEqual(@as(usize, 0), capture.text_spans.items.len);
    try streamAssistantChunk(&stream_ctx, "docs> and <dev@example.com>\n");

    try std.testing.expectEqualStrings(
        "see <https://example.com/docs> and <dev@example.com>\n",
        stream_ctx.raw_text.items,
    );
    try std.testing.expectEqual(@as(usize, 1), capture.text_spans.items.len);
    try std.testing.expect(std.mem.indexOf(u8, capture.text_spans.items[0], "\x1b]8;") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.text_spans.items[0], "https://example.com/docs") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.text_spans.items[0], "mailto:dev@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.text_spans.items[0], "<https://example.com/docs>") == null);
    try std.testing.expect(std.mem.indexOf(u8, capture.text_spans.items[0], "<dev@example.com>") == null);
}

test "streamed setext heading waits for its underline and flushes before a tool" {
    const alloc = std.testing.allocator;
    var capture = StreamCapture{};
    defer capture.deinit(alloc);
    var hook_set = capture.hooks();
    var stream_ctx = StreamChunkContext{
        .hooks = &hook_set,
        .semantic_presentation = capture.semanticPresentationSink(),
        .turn_id = 1,
        .alloc = alloc,
    };
    defer stream_ctx.deinit();

    try streamAssistantChunk(&stream_ctx, "Streamed");
    try streamAssistantChunk(&stream_ctx, " title\n");
    try streamAssistantChunk(&stream_ctx, "--");
    try streamAssistantChunk(&stream_ctx, "-");
    try std.testing.expectEqual(@as(usize, 0), capture.text_spans.items.len);

    onStreamToolStart(&stream_ctx, "read_1", "read_file", null);

    try std.testing.expectEqualStrings("Streamed title\n---", stream_ctx.raw_text.items);
    try std.testing.expectEqual(@as(usize, 0), capture.thematic_rule_count);
    try std.testing.expectEqual(@as(usize, 2), capture.text_spans.items.len);
    try std.testing.expectEqualStrings("\x1b[1mStreamed title\x1b[22m", capture.text_spans.items[0]);
    try std.testing.expectEqualStrings("\n", capture.text_spans.items[1]);
    try std.testing.expect(stream_ctx.last_byte_was_newline);
    try std.testing.expectEqualSlices(
        PresentationEntry,
        &.{ .text, .text },
        capture.presentation_order.items,
    );
}

test "streamed definition list retains source and clears before a tool" {
    const alloc = std.testing.allocator;
    var capture = StreamCapture{};
    defer capture.deinit(alloc);
    var hook_set = capture.hooks();
    var stream_ctx = StreamChunkContext{
        .hooks = &hook_set,
        .semantic_presentation = capture.semanticPresentationSink(),
        .turn_id = 1,
        .alloc = alloc,
    };
    defer stream_ctx.deinit();

    try streamAssistantChunk(&stream_ctx, "Sta");
    try streamAssistantChunk(&stream_ctx, "tus\n: **Run");
    try streamAssistantChunk(&stream_ctx, "ning**\n");
    onStreamToolStart(&stream_ctx, "read_1", "read_file", null);
    try streamAssistantChunk(&stream_ctx, ": stale\n");
    try flushAssistantStream(&stream_ctx);

    try std.testing.expectEqualStrings(
        "Status\n: **Running**\n: stale\n",
        stream_ctx.raw_text.items,
    );
    try std.testing.expectEqual(@as(usize, 2), capture.text_spans.items.len);
    try std.testing.expectEqualStrings(
        "Status\n\x1b[2m  \x1b[22m\x1b[1mRunning\x1b[22m\n",
        capture.text_spans.items[0],
    );
    try std.testing.expectEqualStrings(": stale\n", capture.text_spans.items[1]);
}

test "streamed presentation preserves ANSI OSC 8 code fence and table spans" {
    if (ansi_span_fixture_enabled()) return assert_frozen_ansi_span_fixture();

    const alloc = std.testing.allocator;
    var environ = try std.process.Environ.createMap(std.testing.environ, alloc);
    defer environ.deinit();
    try environ.put(ansi_span_fixture_env, "1");

    const cwd = try std.process.currentPathAlloc(std.testing.io, alloc);
    defer alloc.free(cwd);
    const result = try std.process.run(alloc, std.testing.io, .{
        .argv = &.{ "zig", "test", "-lc", "-Mroot=src/main.zig", "--test-filter", ansi_span_test_name },
        .cwd = .{ .path = cwd },
        .environ_map = &environ,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    switch (result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestExpectedEqual,
    }
    try std.testing.expect(std.mem.find(u8, result.stderr, ansi_span_test_name) != null);
}

test "streamed footnotes retain raw source and flush before a tool" {
    const alloc = std.testing.allocator;
    var capture = StreamCapture{};
    defer capture.deinit(alloc);
    var hook_set = capture.hooks();
    var stream_ctx = StreamChunkContext{
        .hooks = &hook_set,
        .semantic_presentation = capture.semanticPresentationSink(),
        .turn_id = 1,
        .alloc = alloc,
    };
    defer stream_ctx.deinit();

    try streamAssistantChunk(&stream_ctx, "The deployment is stable[^status].\n");
    try streamAssistantChunk(
        &stream_ctx,
        "| Component | State |\n" ++
            "| --- | --- |\n" ++
            "| api | [^status] |\n",
    );
    try streamAssistantChunk(&stream_ctx, "[^status]: OBSERVER_FOOTNOTE_PROJECTION\n");
    onStreamToolStart(&stream_ctx, "read_1", "read_file", null);

    try std.testing.expectEqualStrings(
        "The deployment is stable[^status].\n" ++
            "| Component | State |\n" ++
            "| --- | --- |\n" ++
            "| api | [^status] |\n" ++
            "[^status]: OBSERVER_FOOTNOTE_PROJECTION\n",
        stream_ctx.raw_text.items,
    );
    try std.testing.expectEqualSlices(
        PresentationEntry,
        &.{ .text, .table, .text },
        capture.presentation_order.items,
    );
    try std.testing.expect(std.mem.indexOf(u8, capture.text_spans.items[0], "\x1b[2m[1]\x1b[22m") != null);
    try std.testing.expectEqualStrings(
        "\n\x1b[2m[1] \x1b[22mOBSERVER_FOOTNOTE_PROJECTION\n",
        capture.text_spans.items[1],
    );
    try std.testing.expectEqual(@as(usize, 2), capture.lifecycle_events.items.len);
}

test "streamed footnotes keep one separator after a blank source line" {
    const alloc = std.testing.allocator;
    var capture = StreamCapture{};
    defer capture.deinit(alloc);
    var hook_set = capture.hooks();
    var stream_ctx = StreamChunkContext{ .hooks = &hook_set, .turn_id = 1, .alloc = alloc };
    defer stream_ctx.deinit();

    try streamAssistantChunk(&stream_ctx, "The deployment is stable[^status].\n\n");
    try streamAssistantChunk(&stream_ctx, "[^status]: Deployment notes are deferred.\n");
    try flushAssistantStream(&stream_ctx);

    try std.testing.expectEqual(@as(usize, 2), capture.text_spans.items.len);
    try std.testing.expectEqualStrings(
        "The deployment is stable\x1b[2m[1]\x1b[22m.\n\n",
        capture.text_spans.items[0],
    );
    try std.testing.expectEqualStrings(
        "\x1b[2m[1] \x1b[22mDeployment notes are deferred.\n",
        capture.text_spans.items[1],
    );
}

test "streamed tool start flushes presentation before separator and lifecycle" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        id: []const u8,
        name: []const u8,
        emits_lifecycle: bool,
    }{
        .{ .id = "read_1", .name = "read_file", .emits_lifecycle = true },
        .{ .id = "command_1", .name = "run_command", .emits_lifecycle = false },
        .{ .id = "write_1", .name = "write_file", .emits_lifecycle = false },
        .{ .id = "edit_1", .name = "edit_file", .emits_lifecycle = false },
        .{ .id = "ask_1", .name = "ask_user_question", .emits_lifecycle = false },
    };

    for (cases) |case| {
        var capture = StreamCapture{};
        defer capture.deinit(alloc);
        var hook_set = capture.hooks();
        var stream_ctx = StreamChunkContext{ .hooks = &hook_set, .turn_id = 1, .alloc = alloc };
        defer stream_ctx.deinit();

        try streamAssistantChunk(&stream_ctx, "partial");
        onStreamToolStart(&stream_ctx, case.id, case.name, null);

        try std.testing.expectEqual(@as(usize, 2), capture.text_spans.items.len);
        try std.testing.expectEqualStrings("partial", capture.text_spans.items[0]);
        try std.testing.expectEqualStrings("\n", capture.text_spans.items[1]);

        if (case.emits_lifecycle) {
            try std.testing.expectEqual(@as(usize, 2), capture.lifecycle_events.items.len);
            try std.testing.expectEqualStrings(case.id, capture.lifecycle_events.items[0].provisional.id.call_id);
            try std.testing.expectEqualStrings(case.name, capture.lifecycle_events.items[0].provisional.tool_name.?);
            try std.testing.expectEqualStrings(case.id, capture.lifecycle_events.items[1].progress.id.call_id);
            try std.testing.expectEqual(@as(usize, 5), capture.trace.items.len);
            try std.testing.expectEqual(StreamTraceEntry{ .text = 0 }, capture.trace.items[0]);
            try std.testing.expectEqual(StreamTraceEntry{ .text = 1 }, capture.trace.items[1]);
            try std.testing.expectEqual(types.TurnPhase.running, capture.trace.items[2].turn_phase);
            try std.testing.expectEqual(StreamTraceEntry{ .provisional = 0 }, capture.trace.items[3]);
            try std.testing.expectEqual(StreamTraceEntry{ .progress = 1 }, capture.trace.items[4]);
        } else {
            try std.testing.expectEqual(@as(usize, 0), capture.lifecycle_events.items.len);
            // The working phase lands after the separator: text arriving after
            // it would hand the activity row back to the response.
            try std.testing.expectEqual(@as(usize, 3), capture.trace.items.len);
            try std.testing.expectEqual(StreamTraceEntry{ .text = 0 }, capture.trace.items[0]);
            try std.testing.expectEqual(StreamTraceEntry{ .text = 1 }, capture.trace.items[1]);
            try std.testing.expectEqual(types.TurnPhase.running, capture.trace.items[2].turn_phase);
        }
    }

    var newline_capture = StreamCapture{};
    defer newline_capture.deinit(alloc);
    var newline_hook_set = newline_capture.hooks();
    var newline_stream_ctx = StreamChunkContext{ .hooks = &newline_hook_set, .turn_id = 1, .alloc = alloc };
    defer newline_stream_ctx.deinit();

    try streamAssistantChunk(&newline_stream_ctx, "complete line\n");
    onStreamToolStart(&newline_stream_ctx, "read_newline", "read_file", null);

    try std.testing.expectEqual(@as(usize, 1), newline_capture.text_spans.items.len);
    try std.testing.expectEqualStrings("complete line\n", newline_capture.text_spans.items[0]);
    try std.testing.expectEqual(@as(usize, 2), newline_capture.lifecycle_events.items.len);
    try std.testing.expectEqual(@as(usize, 4), newline_capture.trace.items.len);
    try std.testing.expectEqual(StreamTraceEntry{ .text = 0 }, newline_capture.trace.items[0]);
    try std.testing.expectEqual(types.TurnPhase.running, newline_capture.trace.items[1].turn_phase);
    try std.testing.expectEqual(StreamTraceEntry{ .provisional = 0 }, newline_capture.trace.items[2]);
    try std.testing.expectEqual(StreamTraceEntry{ .progress = 1 }, newline_capture.trace.items[3]);
}

test "assistant prose before the first tool starts a new presentation group" {
    const alloc = std.testing.allocator;
    var capture = StreamCapture{};
    defer capture.deinit(alloc);
    var hook_set = capture.hooks();
    var stream_ctx = StreamChunkContext{
        .hooks = &hook_set,
        .turn_id = 7,
        .step_id = 12,
        .alloc = alloc,
        .provisional_statuses = .{
            .presentation_group_id = .{ .turn_id = 7, .anchor_step_id = 11 },
        },
    };
    defer stream_ctx.deinit();

    try streamAssistantChunk(&stream_ctx, "new batch");
    onStreamToolStart(&stream_ctx, "read_1", "read_file", null);

    try std.testing.expectEqual(
        types.ToolPresentationGroupId{ .turn_id = 7, .anchor_step_id = 12 },
        capture.lifecycle_events.items[0].provisional.presentation_group_id.?,
    );
}

test "assistant prose between streamed sibling tools keeps their presentation group" {
    const alloc = std.testing.allocator;
    var capture = StreamCapture{};
    defer capture.deinit(alloc);
    var hook_set = capture.hooks();
    var stream_ctx = StreamChunkContext{
        .hooks = &hook_set,
        .turn_id = 7,
        .step_id = 11,
        .alloc = alloc,
        .provisional_statuses = .{
            .presentation_group_id = .{ .turn_id = 7, .anchor_step_id = 11 },
        },
    };
    defer stream_ctx.deinit();

    onStreamToolStart(&stream_ctx, "read_1", "read_file", null);
    try streamAssistantChunk(&stream_ctx, "provider bridge");
    onStreamToolStart(&stream_ctx, "read_2", "read_file", null);

    const expected = types.ToolPresentationGroupId{
        .turn_id = 7,
        .anchor_step_id = 11,
    };
    try std.testing.expectEqual(
        expected,
        capture.lifecycle_events.items[0].provisional.presentation_group_id.?,
    );
    try std.testing.expectEqual(
        expected,
        capture.lifecycle_events.items[2].provisional.presentation_group_id.?,
    );
    try std.testing.expect(stream_ctx.saw_visible_text_after_tool_start);
}

test "semantic output after a streamed tool closes its presentation group" {
    const alloc = std.testing.allocator;
    var capture = StreamCapture{};
    defer capture.deinit(alloc);
    var hook_set = capture.hooks();
    var stream_ctx = StreamChunkContext{
        .hooks = &hook_set,
        .turn_id = 7,
        .alloc = alloc,
        .saw_tool_start = true,
    };
    defer stream_ctx.deinit();

    stream_ctx.recordSemanticBoundary();

    try std.testing.expect(stream_ctx.saw_visible_text_after_tool_start);
}

test "semantic table flushes before a tool without visible text or extra separator" {
    const alloc = std.testing.allocator;
    var capture = StreamCapture{};
    defer capture.deinit(alloc);
    var hook_set = capture.hooks();
    var stream_ctx = StreamChunkContext{
        .hooks = &hook_set,
        .semantic_presentation = capture.semanticPresentationSink(),
        .turn_id = 1,
        .alloc = alloc,
    };
    defer stream_ctx.deinit();

    try streamAssistantChunk(
        &stream_ctx,
        "| Name | Count |\n" ++
            "|------|------:|\n" ++
            "| api | 7 |\n",
    );
    onStreamToolStart(&stream_ctx, "read_1", "read_file", null);

    try std.testing.expectEqual(@as(usize, 1), capture.tables.items.len);
    try std.testing.expectEqual(@as(usize, 0), capture.text_spans.items.len);
    try std.testing.expect(stream_ctx.last_byte_was_newline);
}

test "null semantic presentation sink retains rendered table text" {
    const alloc = std.testing.allocator;
    var capture = StreamCapture{};
    defer capture.deinit(alloc);
    var hook_set = capture.hooks();
    var stream_ctx = StreamChunkContext{
        .hooks = &hook_set,
        .semantic_presentation = null,
        .turn_id = 1,
        .alloc = alloc,
    };
    defer stream_ctx.deinit();

    try streamAssistantChunk(
        &stream_ctx,
        "| Name | Count |\n" ++
            "|------|------:|\n" ++
            "| api  | 7     |\n",
    );
    try flushAssistantStream(&stream_ctx);

    try std.testing.expectEqual(@as(usize, 0), capture.tables.items.len);
    try std.testing.expectEqual(@as(usize, 1), capture.text_spans.items.len);
    try std.testing.expect(std.mem.find(u8, capture.text_spans.items[0], "Name") != null);
}

test "semantic thematic rule flushes at EOF before a tool after a blank separator" {
    const alloc = std.testing.allocator;
    var capture = StreamCapture{};
    defer capture.deinit(alloc);
    var hook_set = capture.hooks();
    var stream_ctx = StreamChunkContext{
        .hooks = &hook_set,
        .semantic_presentation = capture.semanticPresentationSink(),
        .turn_id = 1,
        .alloc = alloc,
    };
    defer stream_ctx.deinit();

    try streamAssistantChunk(&stream_ctx, "Before rule.\n\n---");
    onStreamToolStart(&stream_ctx, "read_1", "read_file", null);

    try std.testing.expectEqualStrings("Before rule.\n\n---", stream_ctx.raw_text.items);
    try std.testing.expectEqual(@as(usize, 1), capture.thematic_rule_count);
    try std.testing.expectEqual(@as(usize, 1), capture.text_spans.items.len);
    try std.testing.expectEqualStrings("Before rule.\n\n", capture.text_spans.items[0]);
    try std.testing.expect(stream_ctx.last_byte_was_newline);
    try std.testing.expectEqualSlices(
        PresentationEntry,
        &.{ .text, .thematic_rule },
        capture.presentation_order.items,
    );
}

test "semantic table preserves surrounding streamed text order" {
    const alloc = std.testing.allocator;
    var capture = StreamCapture{};
    defer capture.deinit(alloc);
    var hook_set = capture.hooks();
    var stream_ctx = StreamChunkContext{
        .hooks = &hook_set,
        .semantic_presentation = capture.semanticPresentationSink(),
        .turn_id = 1,
        .alloc = alloc,
    };
    defer stream_ctx.deinit();

    try streamAssistantChunk(
        &stream_ctx,
        "Before table.\n" ++
            "| Name | Count |\n" ++
            "|------|------:|\n" ++
            "| api | 7 |\n" ++
            "After table.\n",
    );
    try flushAssistantStream(&stream_ctx);

    try std.testing.expectEqualStrings("Before table.\n", capture.text_spans.items[0]);
    try std.testing.expectEqualStrings("After table.\n", capture.text_spans.items[1]);
    try std.testing.expectEqualSlices(
        PresentationEntry,
        &.{ .text, .table, .text },
        capture.presentation_order.items,
    );
}

test "semantic code block preserves surrounding streamed text order" {
    const alloc = std.testing.allocator;
    var capture = StreamCapture{};
    defer capture.deinit(alloc);
    var hook_set = capture.hooks();
    var stream_ctx = StreamChunkContext{
        .hooks = &hook_set,
        .semantic_presentation = capture.semanticPresentationSink(),
        .turn_id = 1,
        .alloc = alloc,
    };
    defer stream_ctx.deinit();

    try streamAssistantChunk(
        &stream_ctx,
        "Before code.\n" ++
            "```zig\n" ++
            "  const value = **1**;\n" ++
            "```\n" ++
            "After code.\n",
    );
    try flushAssistantStream(&stream_ctx);

    try std.testing.expectEqual(@as(usize, 1), capture.code_blocks.items.len);
    try std.testing.expectEqualStrings("zig", capture.code_blocks.items[0].language);
    try std.testing.expectEqualStrings("  const value = **1**;\n", capture.code_blocks.items[0].code);
    try std.testing.expectEqualStrings("Before code.\n", capture.text_spans.items[0]);
    try std.testing.expectEqualStrings("After code.\n", capture.text_spans.items[1]);
    try std.testing.expectEqualSlices(
        PresentationEntry,
        &.{ .text, .code_block, .text },
        capture.presentation_order.items,
    );
}

test "streamed response-leading indented code retains fragmented prefix and payload order" {
    const alloc = std.testing.allocator;
    var capture = StreamCapture{};
    defer capture.deinit(alloc);
    var hook_set = capture.hooks();
    var stream_ctx = StreamChunkContext{
        .hooks = &hook_set,
        .semantic_presentation = capture.semanticPresentationSink(),
        .turn_id = 1,
        .alloc = alloc,
    };
    defer stream_ctx.deinit();

    try streamAssistantChunk(&stream_ctx, "  ");
    try streamAssistantChunk(&stream_ctx, "  const ready = true;\n");
    try streamAssistantChunk(&stream_ctx, "After code.\n");
    try flushAssistantStream(&stream_ctx);

    try std.testing.expectEqualStrings("    const ready = true;\nAfter code.\n", stream_ctx.raw_text.items);
    try std.testing.expectEqual(@as(usize, 1), capture.code_blocks.items.len);
    try std.testing.expectEqualStrings("", capture.code_blocks.items[0].language);
    try std.testing.expectEqualStrings("const ready = true;\n", capture.code_blocks.items[0].code);
    try std.testing.expectEqualStrings("After code.\n", capture.text_spans.items[0]);
    try std.testing.expectEqualSlices(
        PresentationEntry,
        &.{ .code_block, .text },
        capture.presentation_order.items,
    );
}

test "streamed response-leading tab code retains its remaining indentation" {
    const alloc = std.testing.allocator;
    var capture = StreamCapture{};
    defer capture.deinit(alloc);
    var hook_set = capture.hooks();
    var stream_ctx = StreamChunkContext{
        .hooks = &hook_set,
        .semantic_presentation = capture.semanticPresentationSink(),
        .turn_id = 1,
        .alloc = alloc,
    };
    defer stream_ctx.deinit();

    try streamAssistantChunk(&stream_ctx, "\t  const tabbed = true;\n");
    try flushAssistantStream(&stream_ctx);

    try std.testing.expectEqualStrings("\t  const tabbed = true;\n", stream_ctx.raw_text.items);
    try std.testing.expectEqual(@as(usize, 1), capture.code_blocks.items.len);
    try std.testing.expectEqualStrings("  const tabbed = true;\n", capture.code_blocks.items[0].code);
}

test "streamed leading blank retains the following indented code opener" {
    const alloc = std.testing.allocator;
    var capture = StreamCapture{};
    defer capture.deinit(alloc);
    var hook_set = capture.hooks();
    var stream_ctx = StreamChunkContext{
        .hooks = &hook_set,
        .semantic_presentation = capture.semanticPresentationSink(),
        .turn_id = 1,
        .alloc = alloc,
    };
    defer stream_ctx.deinit();

    try streamAssistantChunk(&stream_ctx, "\n    const blank_prefixed = true;\nAfter code.\n");
    try flushAssistantStream(&stream_ctx);

    try std.testing.expectEqualStrings("\n    const blank_prefixed = true;\nAfter code.\n", stream_ctx.raw_text.items);
    try std.testing.expectEqual(@as(usize, 1), capture.code_blocks.items.len);
    try std.testing.expectEqualStrings("const blank_prefixed = true;\n", capture.code_blocks.items[0].code);
    try std.testing.expectEqualStrings("After code.\n", capture.text_spans.items[0]);
}

test "streamed response-leading indented code retains its prefix with the production allocator" {
    const alloc = std.heap.c_allocator;
    var capture = StreamCapture{ .capture_alloc = alloc };
    defer capture.deinit(alloc);
    var hook_set = capture.hooks();
    var stream_ctx = StreamChunkContext{
        .hooks = &hook_set,
        .semantic_presentation = capture.semanticPresentationSink(),
        .turn_id = 1,
        .alloc = alloc,
    };
    defer stream_ctx.deinit();

    try streamAssistantChunk(&stream_ctx, "    const production_allocator = true;\nAfter code.\n");
    try flushAssistantStream(&stream_ctx);

    try std.testing.expectEqual(@as(usize, 1), capture.code_blocks.items.len);
    try std.testing.expectEqualStrings("const production_allocator = true;\n", capture.code_blocks.items[0].code);
    try std.testing.expectEqualStrings("After code.\n", capture.text_spans.items[0]);
}

test "streamed prefix without a code opener is discarded before a tool boundary" {
    const alloc = std.testing.allocator;
    var capture = StreamCapture{};
    defer capture.deinit(alloc);
    var hook_set = capture.hooks();
    var stream_ctx = StreamChunkContext{ .hooks = &hook_set, .turn_id = 1, .alloc = alloc };
    defer stream_ctx.deinit();

    try streamAssistantChunk(&stream_ctx, "   ");
    onStreamToolStart(&stream_ctx, "read_1", "read_file", "src/main.zig");
    try streamAssistantChunk(&stream_ctx, "after tool\n");

    try std.testing.expectEqualStrings("   after tool\n", stream_ctx.raw_text.items);
    try std.testing.expectEqual(@as(usize, 0), capture.code_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 1), capture.text_spans.items.len);
    try std.testing.expectEqualStrings("after tool\n", capture.text_spans.items[0]);
}

test "semantic tilde code block preserves split streamed text order" {
    const alloc = std.testing.allocator;
    var capture = StreamCapture{};
    defer capture.deinit(alloc);
    var hook_set = capture.hooks();
    var stream_ctx = StreamChunkContext{
        .hooks = &hook_set,
        .semantic_presentation = capture.semanticPresentationSink(),
        .turn_id = 1,
        .alloc = alloc,
    };
    defer stream_ctx.deinit();

    try streamAssistantChunk(&stream_ctx, "Before code.\n~~");
    try streamAssistantChunk(
        &stream_ctx,
        "~zig\n" ++
            "  const value = **1**;\n" ++
            "```\n" ++
            "~~~\n" ++
            "After code.\n",
    );
    try flushAssistantStream(&stream_ctx);

    try std.testing.expectEqualStrings(
        "Before code.\n~~~zig\n  const value = **1**;\n```\n~~~\nAfter code.\n",
        stream_ctx.raw_text.items,
    );
    try std.testing.expectEqual(@as(usize, 1), capture.code_blocks.items.len);
    try std.testing.expectEqualStrings("zig", capture.code_blocks.items[0].language);
    try std.testing.expectEqualStrings("  const value = **1**;\n```\n", capture.code_blocks.items[0].code);
    try std.testing.expectEqualStrings("Before code.\n", capture.text_spans.items[0]);
    try std.testing.expectEqualStrings("After code.\n", capture.text_spans.items[1]);
    try std.testing.expectEqualSlices(
        PresentationEntry,
        &.{ .text, .code_block, .text },
        capture.presentation_order.items,
    );
}

test "stream callbacks publish absolute raw output token progress" {
    const alloc = std.testing.allocator;
    var capture = StreamCapture{};
    defer capture.deinit(alloc);
    var hook_set = capture.hooks();
    var accumulator = runtime_telemetry.TurnSummaryAccumulator.init(0, "request payload");
    accumulator.prepareTokenRequest();
    var stream_ctx = StreamChunkContext{
        .hooks = &hook_set,
        .token_progress = &accumulator,
        .turn_id = 1,
        .alloc = alloc,
    };
    defer stream_ctx.deinit();

    try pushTokenProgressUpdate(&stream_ctx, .changed);
    onStreamReasoningChunk(&stream_ctx, "thinking ");
    onStreamContentChunk(&stream_ctx, "visible");
    onStreamContentChunk(&stream_ctx, " later\n");

    var expected_output = token_estimate.StreamingEstimator{};
    expected_output.consume("thinking ");
    expected_output.consume("visible");
    expected_output.consume(" later\n");
    try std.testing.expect(capture.token_progress_updates.items.len >= 4);
    const latest = capture.token_progress_updates.items[capture.token_progress_updates.items.len - 1];
    try std.testing.expectEqual(expected_output.estimate(), latest.output_tokens);
    try std.testing.expect(!latest.input_exact);
    try std.testing.expect(!latest.output_exact);
}

test "streamed presentation suppresses callback-time failures" {
    const alloc = std.testing.allocator;

    {
        var capture = StreamCapture{};
        defer capture.deinit(alloc);
        var hook_set = capture.hooks();
        var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
        var stream_ctx = StreamChunkContext{
            .hooks = &hook_set,
            .turn_id = 1,
            .alloc = failing.allocator(),
        };
        defer stream_ctx.deinit();

        onStreamContentChunk(&stream_ctx, "visible\n");

        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expect(stream_ctx.first_model_output_at_ms != null);
        try std.testing.expectEqual(@as(usize, 0), stream_ctx.raw_text.items.len);
        try std.testing.expectEqual(@as(usize, 0), capture.text_calls);
    }

    {
        var capture = StreamCapture{};
        defer capture.deinit(alloc);
        var hook_set = capture.hooks();
        var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 1 });
        var stream_ctx = StreamChunkContext{
            .hooks = &hook_set,
            .turn_id = 1,
            .alloc = failing.allocator(),
        };
        defer stream_ctx.deinit();

        onStreamContentChunk(&stream_ctx, "visible\n");

        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqualStrings("visible\n", stream_ctx.raw_text.items);
        try std.testing.expectEqual(@as(usize, 0), capture.text_calls);
    }

    {
        var capture = StreamCapture{ .source_error = error.TestSourcePublicationFailure };
        defer capture.deinit(alloc);
        var hook_set = capture.hooks();
        var stream_ctx = StreamChunkContext{ .hooks = &hook_set, .turn_id = 1, .alloc = alloc };
        defer stream_ctx.deinit();

        onStreamContentChunk(&stream_ctx, "visible\n");

        try std.testing.expectEqualStrings("visible\n", stream_ctx.raw_text.items);
        try std.testing.expectEqual(@as(usize, 1), capture.source_calls);
        try std.testing.expectEqual(@as(usize, 1), capture.event_calls);
        try std.testing.expectEqual(@as(usize, 0), capture.text_calls);
    }

    {
        var capture = StreamCapture{ .event_error = error.TestOutputTokenPublicationFailure };
        defer capture.deinit(alloc);
        var hook_set = capture.hooks();
        var stream_ctx = StreamChunkContext{ .hooks = &hook_set, .turn_id = 1, .alloc = alloc };
        defer stream_ctx.deinit();

        onStreamContentChunk(&stream_ctx, "visible\n");

        try std.testing.expectEqualStrings("visible\n", stream_ctx.raw_text.items);
        try std.testing.expectEqual(@as(usize, 1), capture.event_calls);
        try std.testing.expectEqual(@as(usize, 1), capture.text_calls);
    }

    {
        var capture = StreamCapture{ .text_error = error.TestTextPublicationFailure };
        defer capture.deinit(alloc);
        var hook_set = capture.hooks();
        var stream_ctx = StreamChunkContext{ .hooks = &hook_set, .turn_id = 1, .alloc = alloc };
        defer stream_ctx.deinit();

        onStreamContentChunk(&stream_ctx, "visible\n");

        try std.testing.expectEqualStrings("visible\n", stream_ctx.raw_text.items);
        try std.testing.expectEqual(@as(usize, 1), capture.event_calls);
        try std.testing.expectEqual(@as(usize, 1), capture.text_calls);
    }

    {
        var capture = StreamCapture{ .lifecycle_error = error.TestLifecyclePublicationFailure };
        defer capture.deinit(alloc);
        var hook_set = capture.hooks();
        var stream_ctx = StreamChunkContext{ .hooks = &hook_set, .turn_id = 1, .alloc = alloc };
        defer stream_ctx.deinit();

        onStreamToolStart(&stream_ctx, "read_1", "read_file", null);

        try std.testing.expectEqual(@as(usize, 1), capture.lifecycle_calls);
        try std.testing.expectEqual(@as(usize, 0), capture.lifecycle_events.items.len);
        try std.testing.expect(stream_ctx.provisional_statuses.visibleId(.{
            .id = "read_1",
            .name = "read_file",
            .arguments_json = "{}",
        }) == null);
    }
}

test "flushAssistantStream does not publish rendered token updates" {
    const alloc = std.testing.allocator;
    var capture = StreamCapture{ .event_error = error.TestOutputTokenPublicationFailure };
    defer capture.deinit(alloc);
    var hook_set = capture.hooks();
    var stream_ctx = StreamChunkContext{ .hooks = &hook_set, .turn_id = 1, .alloc = alloc };
    defer stream_ctx.deinit();

    try streamAssistantChunk(&stream_ctx, "pending");

    try flushAssistantStream(&stream_ctx);
    try std.testing.expectEqual(@as(usize, 0), capture.event_calls);
    try std.testing.expectEqual(@as(usize, 1), capture.text_calls);
}

fn checkStreamPresentationAllocationFailures(alloc: Allocator) !void {
    var capture = StreamCapture{ .capture_alloc = alloc };
    defer capture.deinit(alloc);
    var hook_set = capture.hooks();
    var stream_ctx = StreamChunkContext{ .hooks = &hook_set, .turn_id = 1, .alloc = alloc };
    defer stream_ctx.deinit();

    try streamAssistantChunk(&stream_ctx, "**rendered**\n");
    try streamAssistantChunk(&stream_ctx, "buffered **flush**");
    try flushAssistantStream(&stream_ctx);

    try std.testing.expectEqualStrings(
        "**rendered**\nbuffered **flush**",
        stream_ctx.raw_text.items,
    );
    try std.testing.expectEqual(@as(usize, 2), capture.text_spans.items.len);
}

fn checkSemanticTableCaptureAllocationFailures(alloc: Allocator) !void {
    var capture = StreamCapture{ .capture_alloc = alloc };
    defer capture.deinit(alloc);
    var hook_set = capture.hooks();
    var stream_ctx = StreamChunkContext{
        .hooks = &hook_set,
        .semantic_presentation = capture.semanticPresentationSink(),
        .turn_id = 1,
        .alloc = alloc,
    };
    defer stream_ctx.deinit();

    try streamAssistantChunk(
        &stream_ctx,
        "| Name | Count |\n" ++
            "|------|------:|\n" ++
            "| api  | 7     |\n",
    );
    try flushAssistantStream(&stream_ctx);

    try std.testing.expectEqual(@as(usize, 1), capture.tables.items.len);
}

fn checkSemanticCodeBlockCaptureAllocationFailures(alloc: Allocator) !void {
    var capture = StreamCapture{ .capture_alloc = alloc };
    defer capture.deinit(alloc);
    var hook_set = capture.hooks();
    var stream_ctx = StreamChunkContext{
        .hooks = &hook_set,
        .semantic_presentation = capture.semanticPresentationSink(),
        .turn_id = 1,
        .alloc = alloc,
    };
    defer stream_ctx.deinit();

    try streamAssistantChunk(
        &stream_ctx,
        "    const value = 1;\n" ++
            "after code\n",
    );

    try std.testing.expectEqual(@as(usize, 1), capture.code_blocks.items.len);
}

test "streamed presentation cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkStreamPresentationAllocationFailures,
        .{},
    );
}

test "semantic table capture cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkSemanticTableCaptureAllocationFailures,
        .{},
    );
}

test "semantic code block capture cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkSemanticCodeBlockCaptureAllocationFailures,
        .{},
    );
}

test "normalizeAssistantTextForDisplay removes leading blanks markdown emphasis backticks and trailing whitespace" {
    const alloc = std.testing.allocator;
    const normalized = try normalizeAssistantTextForDisplay(alloc, "\n\n\t **`Hello`** *world*  \n");
    defer alloc.free(normalized);

    try std.testing.expectEqualStrings("Hello world", normalized);
}

test {
    _ = @import("tool_presentation.zig");
}

test "emitProviderLengthNotice emits exact length notice" {
    const alloc = std.testing.allocator;
    var capture = NoticeCapture{};
    defer capture.deinit(alloc);
    const hooks = capture.hooks();

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    try emitProviderLengthNotice(&hooks, arena_state.allocator(), .length_limited);

    try std.testing.expectEqual(@as(usize, 1), capture.notices.items.len);
    try std.testing.expectEqualStrings("response hit provider length limit; output may be incomplete", capture.notices.items[0]);
}

test "emitProviderLengthNotice ignores non-length finish reasons" {
    const alloc = std.testing.allocator;
    var capture = NoticeCapture{};
    defer capture.deinit(alloc);
    const hooks = capture.hooks();

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    try emitProviderLengthNotice(&hooks, arena_state.allocator(), .completed);

    try std.testing.expectEqual(@as(usize, 0), capture.notices.items.len);
}
