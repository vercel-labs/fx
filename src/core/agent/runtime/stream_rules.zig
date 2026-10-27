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
const runtime_deps = @import("deps.zig");
const runtime_config = @import("config.zig");
const runtime_text_completion = @import("text_completion.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;
const AgentRuntimeDeps = runtime_deps.AgentRuntimeDeps;

/// The current request's model connection, which `llm:` judges reuse.
pub const JudgeBinding = struct {
    credential: types.CredentialLease,
    session_id: ?[]const u8,
    model: []const u8,
    provider_options: model_capabilities.ResolvedProviderOptions,
    trace_ctx: debug_trace.TraceContext,
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
    // Model roles pick the judge's model when the host resolves them; the
    // session's own model answers otherwise.
    var model = binding.model;
    if (self.deps.resolve_judge_model) |resolve| {
        if (resolve(self.deps.ctx, roles)) |resolved| model = resolved;
    }
    const same_model = std.mem.eql(u8, model, binding.model);
    const outcome = runtime_text_completion.complete(alloc, .{
        .observer = self.deps.observer,
        .stream_provider = self.deps.agent_stream_provider,
        .cooperative_pulse = self.deps.cooperative_transport_pulse,
        .credential = binding.credential,
        .session_id = binding.session_id,
        .model = model,
        .retry_count = self.config.gateway_retry_count,
        .cancel_flag = self.config.cancel_flag,
        .provider_options = if (same_model) binding.provider_options else .{
            .prompt_caching = binding.provider_options.prompt_caching,
            .provider_order = binding.provider_options.provider_order,
            .provider_strict = binding.provider_options.provider_strict,
        },
        .max_output_tokens = 2048,
        .max_bytes = 8 * 1024,
        .trace_ctx = binding.trace_ctx,
        .system = "",
        .user = prompt,
    }) catch return null;
    return switch (outcome) {
        .text => |text| text,
        .failed => |failure| blk: {
            debug_trace.logf("ttsr", "judge completion failed reason={s}", .{@tagName(failure.reason)});
            break :blk null;
        },
    };
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
