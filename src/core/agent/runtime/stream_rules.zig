//! The agent loop's side of stream rules (TTSR, `core/ttsr`).
//!
//! A turn loads the workspace's rules once, hands the coordinator to each
//! step's stream, and acts on what it decided:
//!
//! - an interrupt cancels the stream through the turn's cancel flag; the
//!   loop recognizes its own cancel, clears the flag, adds the rule to the
//!   turn's suffix (after the partial reply when `context_mode = keep`) and
//!   runs the step again (D176);
//! - a tool call's reminder is prepended to that call's result before the
//!   next request;
//! - a prose rule that did not interrupt is added after the reply, and the
//!   turn continues for one more step.
//!
//! Injections are user messages in the within-turn suffix, so the cached
//! prefix is never rewritten (D131), and they persist as steering, which is
//! what the repeat ledger is rebuilt from on resume (D178).
const std = @import("std");
const ttsr = @import("../../ttsr/ttsr.zig");
const types = @import("../../shared/types.zig");
const io_mod = @import("../../shared/io.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const model_capabilities = @import("../../config/model_capabilities.zig");
const model_roles = @import("../../config/model_roles.zig");
const runtime_deps = @import("deps.zig");
const runtime_config = @import("config.zig");
const runtime_text_completion = @import("text_completion.zig");
const agent_stream_provider = @import("../stream_provider.zig");
const command_admission = @import("../../permissions/command_admission.zig");
const permission_auto_classifier = @import("../../permissions/auto_classifier.zig");
const runtime_tool_contracts = @import("tool_contracts.zig");
const file_mutation = @import("../../tooling/file_mutation.zig");
const worker_runtime = @import("../worker_runtime.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;
const AgentRuntimeDeps = runtime_deps.AgentRuntimeDeps;

/// The current request's model connection, which `llm:` judges reuse.
pub const JudgeFallback = struct {
    stream_provider: runtime_deps.ModelBinding,
};

pub const JudgeBinding = struct {
    credential: types.CredentialLease,
    session_id: ?[]const u8,
    model: []const u8,
    provider_options: model_capabilities.ResolvedProviderOptions,
    trace_ctx: debug_trace.TraceContext,
    fallbacks: []const JudgeFallback = &.{},
};

pub const TurnRules = struct {
    coordinator: ?*ttsr.Coordinator = null,
    /// Rule files, settings and programs for the turn.
    arena: std.heap.ArenaAllocator,
    judge: ?ttsr.judge.Judge = null,
    deps: *const AgentRuntimeDeps,
    config: *const runtime_config.Config,
    binding: ?JudgeBinding = null,

    /// Loads the rules for this turn. Hosts opt in with `deps.ttsr_enabled`;
    /// a failure to load leaves the turn without rules.
    pub fn begin(self: *TurnRules) void {
        if (!self.deps.ttsr_enabled) return;
        const arena = self.arena.allocator();
        // Tests read only the workspace's rules, never the person's own.
        const home = if (@import("builtin").is_test) null else io_mod.homeDir();
        const settings = ttsr.settings.load(arena, home, self.config.workspace_root);
        if (!settings.enabled) return;
        const loaded = ttsr.discovery.load(arena, .{
            .workspace_root = self.config.workspace_root,
            .home = home,
            .settings = settings,
        }) catch |err| {
            debug_trace.logf("ttsr", "rule discovery failed err={s}", .{@errorName(err)});
            return;
        };
        for (loaded.warnings) |warning| debug_trace.logf("ttsr", "rule skipped: {s}", .{warning});
        if (loaded.rules.len == 0) return;
        const coordinator = ttsr.Coordinator.init(std.heap.c_allocator, settings, loaded.rules, self.config.workspace_root, home) catch |err| {
            debug_trace.logf("ttsr", "coordinator init failed err={s}", .{@errorName(err)});
            return;
        };
        for (coordinator.manager.errors.items) |failure| debug_trace.logf("ttsr", "rule {s} not registered: {s}", .{ failure.rule, failure.message });
        if (!coordinator.active()) {
            coordinator.deinit();
            return;
        }
        if (coordinator.manager.hasJudgeRules()) {
            self.judge = ttsr.judge.Judge.init(std.heap.c_allocator, .{ .ctx = self, .complete = completeJudge });
            coordinator.judge = self.judge.?.asJudge();
        }
        self.coordinator = coordinator;
        debug_trace.logf("ttsr", "turn rules active count={d}", .{coordinator.manager.entries.items.len});
    }

    pub fn end(self: *TurnRules) void {
        if (self.coordinator) |coordinator| coordinator.deinit();
        if (self.judge) |*judge| judge.deinit();
        self.arena.deinit();
    }

    pub fn bind(self: *TurnRules, binding: JudgeBinding) void {
        self.binding = binding;
    }
};

pub fn init(deps: *const AgentRuntimeDeps, config: *const runtime_config.Config) TurnRules {
    return .{ .arena = std.heap.ArenaAllocator.init(std.heap.c_allocator), .deps = deps, .config = config };
}

fn completeJudge(raw: *anyopaque, alloc: Allocator, roles: []const []const u8, prompt: []const u8) ?[]u8 {
    const self: *TurnRules = @ptrCast(@alignCast(raw));
    const binding = self.binding orelse return null;
    // Resolve every judge role through the typed provider binding supplied by
    // the host. Provider, credentials, transport, and options stay together.
    var model = binding.model;
    var credential = binding.credential;
    var stream_provider = self.deps.agent_stream_provider;
    var provider_options = binding.provider_options;
    var fallbacks = binding.fallbacks;
    var typed_fallbacks: [8]JudgeFallback = undefined;
    var typed_fallback_count: usize = 0;
    var typed_primary = false;
    if (self.deps.resolve_role_chain) |resolve| if (self.deps.bind_model) |bind| {
        role_loop: for (roles) |raw_role| {
            const role_name = if (raw_role.len > 0 and raw_role[0] == '@') raw_role[1..] else raw_role;
            const role = model_roles.parseRoleId(role_name) orelse continue;
            var chain: [64]model_roles.Selection = undefined;
            const chain_count = @min(resolve(self.deps.ctx, role, &chain), chain.len);
            for (chain[0..chain_count]) |candidate| {
                const bound = bind(self.deps.ctx, self.arena.allocator(), candidate) catch null orelse continue;
                if (!typed_primary) {
                    typed_primary = true;
                    model = bound.selection.model;
                    credential = bound.credential;
                    stream_provider = bound.stream_provider;
                    provider_options = bound.provider_options;
                } else if (typed_fallback_count < typed_fallbacks.len) {
                    typed_fallbacks[typed_fallback_count] = .{ .stream_provider = bound };
                    typed_fallback_count += 1;
                }
            }
            if (typed_primary) break :role_loop;
        }
        if (typed_primary) fallbacks = typed_fallbacks[0..typed_fallback_count];
    };
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const fallback = if (attempt < fallbacks.len) fallbacks[attempt].stream_provider else null;
        const attempt_credential = if (fallback) |value| value.credential else credential;
        const attempt_stream_provider = if (fallback) |value| value.stream_provider else stream_provider;
        const attempt_model = if (fallback) |value| value.selection.model else model;
        const attempt_options = if (fallback) |value| value.provider_options else provider_options;
        const outcome = runtime_text_completion.complete(alloc, .{
            .observer = self.deps.observer,
            .stream_provider = attempt_stream_provider,
            .cooperative_pulse = self.deps.cooperative_transport_pulse,
            .credential = attempt_credential,
            .session_id = binding.session_id,
            .model = attempt_model,
            .retry_count = self.config.gateway_retry_count,
            .cancel_flag = self.config.cancel_flag,
            .provider_options = attempt_options,
            .max_output_tokens = 2048,
            .max_bytes = 8 * 1024,
            .trace_ctx = binding.trace_ctx,
            .system = "",
            .user = prompt,
        }) catch return null;
        switch (outcome) {
            .text => |text| return text,
            .failed => |failure| {
                debug_trace.logf("ttsr", "judge completion failed reason={s}", .{@tagName(failure.reason)});
                alloc.free(failure.detail);
                if (attempt >= fallbacks.len) return null;
            },
        }
    }
}

fn publishNotice(deps: *const AgentRuntimeDeps, body: []const u8) void {
    // Event payloads travel through the worker queue, which frees them with
    // the process allocator.
    const owned = types.dupeSemanticNotice(std.heap.c_allocator, .{ .topic = "rule", .tone = .warning, .body = body }) catch return;
    deps.push_event(deps.ctx, .{ .semantic_notice = owned }) catch {
        types.freeSemanticNotice(std.heap.c_allocator, owned);
    };
}

/// Before a step's request: rebuild the ledger and `did:` history from the
/// conversation, prepend reminders to the results they belong to, and add
/// prose rules a finished step left pending.
pub fn beforeStep(rules: *TurnRules, arena: Allocator, history: []const ChatMessage, suffix: *std.ArrayList(ChatMessage)) !void {
    const coordinator = rules.coordinator orelse return;
    // Reminders follow the results they belong to as one message, which
    // persists as steering; a result itself is saved before it reaches
    // the model, so text prepended to it would not survive a resume (D179).
    var reminders: std.ArrayList(u8) = .empty;
    for (suffix.items) |message| {
        if (message.role != .tool) continue;
        const id = message.tool_call_id orelse continue;
        const reminder = try coordinator.takeReminder(arena, id) orelse continue;
        if (reminders.items.len > 0) try reminders.appendSlice(arena, "\n\n");
        try reminders.appendSlice(arena, reminder.text);
        publishNotice(rules.deps, reminder.notice);
    }
    if (reminders.items.len > 0) try suffix.append(arena, .{ .role = .user, .content = reminders.items });
    if (try coordinator.takeDeferred(arena)) |deferred| {
        try suffix.append(arena, .{ .role = .user, .content = deferred.text });
        publishNotice(rules.deps, deferred.notice);
    }
    const conversation = try std.mem.concat(arena, ChatMessage, &.{ history, suffix.items });
    try coordinator.sync(conversation);
}

/// A new response attempt begins on `stream`.
pub fn beginAttempt(rules: *TurnRules, cancel_flag: *std.atomic.Value(bool)) void {
    const coordinator = rules.coordinator orelse return;
    coordinator.beginAttempt(cancel_flag);
}

/// Whether the loop's cancel came from a rule, not the person.
pub fn interrupted(rules: *const TurnRules) bool {
    const coordinator = rules.coordinator orelse return false;
    return coordinator.interruptPending();
}

/// Turns a rule's interrupt into the retry: clears the cancel the rule
/// raised, keeps the partial reply when configured, adds the rule, and
/// tells the person. False when no rule interrupted.
pub fn retryAfterInterrupt(
    rules: *TurnRules,
    arena: Allocator,
    cancel_flag: *std.atomic.Value(bool),
    suffix: *std.ArrayList(ChatMessage),
    partial_assistant: []const u8,
) !bool {
    const coordinator = rules.coordinator orelse return false;
    if (!coordinator.interruptPending()) return false;
    const injection = try coordinator.takeInterrupt(arena) orelse return false;
    cancel_flag.store(false, .seq_cst);
    const keep = coordinator.settings.context_mode == .keep and std.mem.trim(u8, partial_assistant, " \t\r\n").len > 0;
    if (keep) try suffix.append(arena, .{ .role = .assistant, .content = try arena.dupe(u8, partial_assistant), .standalone_response = true });
    try suffix.append(arena, .{ .role = .user, .content = injection.text });
    if (partial_assistant.len > 0) try rules.deps.push_text(rules.deps.ctx, .{ .assistant_rendered = "\n" });
    publishNotice(rules.deps, injection.notice);
    debug_trace.logf("ttsr", "interrupt retry kept_partial={} bytes={d}", .{ keep, injection.text.len });
    return true;
}

/// Settles the response's final tool calls before any runs; true when a
/// rule interrupts them.
pub fn settleToolCalls(rules: *TurnRules, calls: []const types.ToolCall) bool {
    const coordinator = rules.coordinator orelse return false;
    for (calls) |call| {
        coordinator.settleToolCall(call.id, call.name, call.arguments_json) catch |err| {
            debug_trace.logf("ttsr", "settle failed tool={s} err={s}", .{ call.name, @errorName(err) });
        };
        if (coordinator.interruptPending()) return true;
    }
    return false;
}

/// After a final reply: settles judged prose rules and, when a rule is
/// pending, keeps the reply in the turn, adds the rule and continues.
pub fn deferAfterReply(
    rules: *TurnRules,
    arena: Allocator,
    suffix: *std.ArrayList(ChatMessage),
    reply: []const u8,
    replay: ?types.ProviderReplay,
) !bool {
    const coordinator = rules.coordinator orelse return false;
    coordinator.settleProse(reply) catch |err| {
        debug_trace.logf("ttsr", "settle prose failed err={s}", .{@errorName(err)});
    };
    const deferred = try coordinator.takeDeferred(arena) orelse return false;
    try suffix.append(arena, .{ .role = .assistant, .content = reply, .provider_replay = replay, .standalone_response = true });
    try suffix.append(arena, .{ .role = .user, .content = deferred.text });
    try rules.deps.push_text(rules.deps.ctx, .{ .assistant_rendered = "\n" });
    publishNotice(rules.deps, deferred.notice);
    return true;
}

const TinyJudgeFixture = struct {
    primary: agent_stream_provider.Provider,
    fallback: agent_stream_provider.Provider,
    primary_calls: usize = 0,
    fallback_calls: usize = 0,
    primary_model: ?[]const u8 = null,
    fallback_model: ?[]const u8 = null,
    primary_credential: ?[]const u8 = null,
    fallback_credential: ?[]const u8 = null,

    fn stream(raw_ctx: ?*anyopaque, _: Allocator, request: agent_stream_provider.ModelRequest) anyerror!agent_stream_provider.Result {
        const self: *TinyJudgeFixture = @ptrCast(@alignCast(raw_ctx.?));
        if (std.mem.eql(u8, request.model, "tiny-primary")) {
            self.primary_calls += 1;
            self.primary_model = request.model;
            self.primary_credential = request.credential.secret();
            return .{ .failed = .{ .kind = .server_error } };
        }
        self.fallback_calls += 1;
        self.fallback_model = request.model;
        self.fallback_credential = request.credential.secret();
        return .{ .completed = .{ .completion = .{ .content = "yes", .finish_reason = .stop } } };
    }

    fn provider(self: *TinyJudgeFixture, _: bool) agent_stream_provider.Provider {
        return .{
            .context = @ptrCast(self),
            .stream_fn = stream,
        };
    }
};

fn tinyJudgeAppendRuntimeContext(_: *anyopaque, _: Allocator, _: *std.ArrayList(ChatMessage)) !void {}

fn tinyJudgeRequestToolPermission(
    _: *anyopaque,
    _: Allocator,
    _: types.ToolCall,
    _: permission_auto_classifier.ReviewTurnContext,
    _: types.PermissionMode,
    _: []const types.PermissionGrant,
    _: ?runtime_deps.LiveToolAuthority,
    _: ?runtime_tool_contracts.LivePermissionRevalidation,
    _: []const []const u8,
    _: ?[]const u8,
) !command_admission.PermissionOutcome {
    return .{};
}

fn tinyJudgeDescribeToolAction(
    _: *anyopaque,
    _: Allocator,
    _: types.ToolCall,
    _: ?[]const u8,
    _: []const []const u8,
) ![]const u8 {
    return "";
}

fn tinyJudgeDescribeToolActionCompleted(
    _: *anyopaque,
    _: Allocator,
    _: types.ToolCall,
    _: ?[]const u8,
    _: []const []const u8,
) ![]const u8 {
    return "";
}

fn tinyJudgeDescribeToolActionDenied(
    _: *anyopaque,
    _: Allocator,
    _: types.ToolCall,
    _: ?[]const u8,
    _: []const u8,
    _: []const []const u8,
) ![]const u8 {
    return "";
}

fn tinyJudgePermissionTarget(
    _: *anyopaque,
    _: Allocator,
    _: types.ToolCall,
    _: []const []const u8,
) ![]const u8 {
    return "";
}

fn tinyJudgeExecuteToolCall(_: *anyopaque, _: runtime_tool_contracts.ToolExecutionRequest) !runtime_tool_contracts.ToolExecutionResult {
    return .{ .model_output = "" };
}

fn tinyJudgePublishCommittedFileHandoff(
    _: *anyopaque,
    _: file_mutation.CommittedFileHandoff,
) runtime_tool_contracts.SecondaryPublicationReport {
    return .{ .diff = .skipped, .tracker = .skipped };
}

fn tinyJudgePropagateHistoryTurn(_: *anyopaque, _: types.HistoryTurn) !void {}
fn tinyJudgePropagateGrant(_: *anyopaque, _: []const u8, _: []const u8) !void {}
fn tinyJudgePushEvent(_: *anyopaque, _: worker_runtime.WorkerEvent) !void {}
fn tinyJudgePushText(_: *anyopaque, _: runtime_deps.TextEmission) !void {}
fn tinyJudgePushDiffBlock(_: *anyopaque, _: runtime_tool_contracts.DiffEntryPayload) !void {}
fn tinyJudgePushSystemNotice(_: *anyopaque, _: []const u8) !void {}
fn tinyJudgePushCommandOutputComplete(_: *anyopaque, _: ?types.ToolLifecycleId) !void {}
fn tinyJudgePushHttpError(_: *anyopaque, _: std.http.Status, _: []const u8, _: ?types.CredentialSource) !void {}
fn tinyJudgeFormatToolExecutionError(_: *anyopaque, _: Allocator, _: []const u8, _: anyerror) ![]const u8 {
    return "";
}

const TinyJudgeBindingContext = struct {
    fixture: *TinyJudgeFixture,

    fn resolveRoleChain(raw_ctx: *anyopaque, role: model_roles.RoleId, out: []model_roles.Selection) usize {
        const self: *TinyJudgeBindingContext = @ptrCast(@alignCast(raw_ctx));
        if (role != .builtin or role.builtin != .tiny or out.len < 2) return 0;
        out[0] = .{ .provider = .gateway, .model = "tiny-primary", .source = role };
        out[1] = .{ .provider = .codex, .model = "tiny-fallback", .source = role };
        _ = self;
        return 2;
    }

    fn bindModel(raw_ctx: *anyopaque, _: Allocator, selection: model_roles.Selection) anyerror!?runtime_deps.ModelBinding {
        const self: *TinyJudgeBindingContext = @ptrCast(@alignCast(raw_ctx));
        if (selection.provider == .gateway) return .{ .selection = selection, .stream_provider = self.fixture.primary, .credential = .{ .direct = .{ .secret_bytes = "primary-key", .source = .ai_gateway_api_key } }, .capabilities = .{} };
        if (selection.provider == .codex) return .{ .selection = selection, .stream_provider = self.fixture.fallback, .credential = .{ .direct = .{ .secret_bytes = "fallback-key", .source = .chatgpt_subscription, .account_id = "account" } }, .capabilities = .{} };
        return null;
    }
};

test "tiny judge retries a failed primary with the provider-qualified credential" {
    var fixture = TinyJudgeFixture{ .primary = undefined, .fallback = undefined };
    fixture.primary = fixture.provider(true);
    fixture.fallback = fixture.provider(false);
    var context = TinyJudgeBindingContext{ .fixture = &fixture };
    var deps: runtime_deps.AgentRuntimeDeps = .{
        .ctx = @ptrCast(&context),
        .agent_stream_provider = fixture.primary,
        .append_runtime_context = tinyJudgeAppendRuntimeContext,
        .request_tool_permission = tinyJudgeRequestToolPermission,
        .describe_tool_action = tinyJudgeDescribeToolAction,
        .describe_tool_action_completed = tinyJudgeDescribeToolActionCompleted,
        .describe_tool_action_denied = tinyJudgeDescribeToolActionDenied,
        .permission_target_for_call = tinyJudgePermissionTarget,
        .execute_tool_call = tinyJudgeExecuteToolCall,
        .publish_committed_file_handoff = tinyJudgePublishCommittedFileHandoff,
        .propagate_history_turn = tinyJudgePropagateHistoryTurn,
        .propagate_grant = tinyJudgePropagateGrant,
        .push_event = tinyJudgePushEvent,
        .push_text = tinyJudgePushText,
        .push_diff_block = tinyJudgePushDiffBlock,
        .push_system_notice = tinyJudgePushSystemNotice,
        .push_command_output_complete = tinyJudgePushCommandOutputComplete,
        .push_http_error = tinyJudgePushHttpError,
        .format_tool_execution_error = tinyJudgeFormatToolExecutionError,
        .resolve_role_chain = TinyJudgeBindingContext.resolveRoleChain,
        .bind_model = TinyJudgeBindingContext.bindModel,
    };
    var cancel = std.atomic.Value(bool).init(false);
    var config: runtime_config.Config = .{
        .system_prompt = "",
        .gateway_retry_count = 0,
        .gateway_chat_url = "",
        .agent_step_limit = 1,
        .cancel_flag = &cancel,
    };
    var rules = TurnRules{
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .deps = &deps,
        .config = &config,
    };
    defer rules.arena.deinit();
    rules.bind(.{
        .credential = .{ .direct = .{ .secret_bytes = "session-key", .source = .ai_gateway_api_key } },
        .session_id = null,
        .model = "session-model",
        .provider_options = .{},
        .trace_ctx = .{},
    });

    const answer = completeJudge(@ptrCast(&rules), std.testing.allocator, &.{"@tiny"}, "judge this");
    defer if (answer) |text| std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("yes", answer.?);
    try std.testing.expectEqual(@as(usize, 1), fixture.primary_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.fallback_calls);
    try std.testing.expectEqualStrings("tiny-primary", fixture.primary_model.?);
    try std.testing.expectEqualStrings("tiny-fallback", fixture.fallback_model.?);
    try std.testing.expectEqualStrings("primary-key", fixture.primary_credential.?);
    try std.testing.expectEqualStrings("fallback-key", fixture.fallback_credential.?);
}
