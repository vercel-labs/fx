//! The agent loop's door to the user's hooks: builds hook events from the
//! turn's data and hands back what the hooks answered.

const std = @import("std");
const hooks_engine = @import("../../../hooks/hooks.zig");
const text_utils = @import("../../shared/text_utils.zig");
const runtime_lifecycle = @import("lifecycle.zig");
const deps_mod = @import("deps.zig");
const types = @import("../../shared/types.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const host_target = @import("../../hosts/target.zig");
const old_hooks = @import("../../hooks/hooks.zig");
const io_mod = @import("../../shared/io.zig");
const testing_listener = @import("../../shared/testing_listener.zig");
const profile_paths = @import("../../shared/profile_paths.zig");
const permission_auto_classifier = @import("../../permissions/auto_classifier.zig");
const runtime_tool_batch = @import("tool_batch.zig");
const tool_result_limits = @import("../../tooling/tool_result_limits.zig");
const context_contract = @import("../../workspace/context_contract.zig");
const hooks_host = @import("../../hooks_host/hooks_host.zig");

const AgentRuntimeDeps = deps_mod.AgentRuntimeDeps;

/// How many PermissionDenied retries a turn can take from its hooks. The cap bounds
/// how often a hook can make the model try a denied call again.
pub const max_denied_retries: u8 = 3;

/// What the user's PreCompact hooks decided about one compaction.
pub const PreCompactApplied = struct {
    /// Set when a hook blocked the compaction; the caller skips it and shows this notice.
    blocked_notice: ?[]const u8 = null,
    /// Extra instructions for the summary, as the hook wrote them.
    instructions: ?[]const u8 = null,
};

/// What the user's UserPromptSubmit hooks decided about one prompt.
pub const PromptSubmitApplied = struct {
    /// Set when a hook blocked or stopped the prompt. Its text is the notice the person sees.
    blocked_notice: ?[]const u8 = null,
    /// A hook's replacement prompt, which the model sees in place of the person's text.
    prompt: ?[]const u8 = null,
    /// Framed context for this turn's model-visible user message.
    context: ?[]const u8 = null,
};

/// What the post-tool hooks changed about one tool result.
pub const PostToolApplied = struct {
    /// The output the model sees: the tool's own, or a hook's replacement.
    output: []const u8,
    replaced: bool = false,
};

pub const TurnHooks = struct {
    deps: *const AgentRuntimeDeps,
    runtime: ?*runtime_lifecycle.UserHooksRuntime,
    trust_required: bool,
    surface: hooks_engine.Surface,
    session_id: ?[]const u8,
    subagent_id: ?u64,
    workspace_root: []const u8,
    turn_id: ?u64,
    cancel: ?*const std.atomic.Value(bool),
    /// PreToolUse context waiting for the step's results; arena memory, never freed one by one.
    pending_notes: std.ArrayList([]const u8) = .empty,
    /// The permission mode the turn's hooks report; the orchestrator sets it at each step.
    mode: types.PermissionMode = .ask,
    /// How many PermissionDenied retries hooks gave in this turn; at most `max_denied_retries`.
    denied_retries: u8 = 0,
    /// The person's tool result limit. A hook's replacement output is cut to it, as a tool's own output is.
    max_tool_result_bytes: usize = tool_result_limits.default_max_tool_result_bytes,

    pub fn init(
        lifecycle: runtime_lifecycle.LifecycleContext,
        deps: *const AgentRuntimeDeps,
        turn_id: ?u64,
        cancel: ?*const std.atomic.Value(bool),
    ) TurnHooks {
        return .{
            .deps = deps,
            .runtime = lifecycle.user_hooks,
            .trust_required = lifecycle.trust_required,
            .surface = surfaceOf(lifecycle),
            .session_id = lifecycle.scope.session_id,
            .subagent_id = lifecycle.scope.subagent_id,
            .workspace_root = lifecycle.scope.workspace_root,
            .turn_id = turn_id,
            .cancel = cancel,
        };
    }

    /// Whether any user hook can run in this turn.
    pub fn active(self: *const TurnHooks) bool {
        if (comptime host_target.is_wasm) return false;
        return self.runtime != null;
    }

    pub fn scope(self: *const TurnHooks, mode: types.PermissionMode) hooks_engine.Scope {
        return .{
            .surface = self.surface,
            .session_id = self.session_id,
            .turn_id = self.turn_id,
            .subagent_id = self.subagent_id,
            .cwd = self.workspace_root,
            .project_dir = self.workspace_root,
            .permission_mode = mode.label(),
            .transcript_path = null,
        };
    }

    /// Whether a hook listens for this event (cheap; no process starts).
    pub fn wants(self: *const TurnHooks, name: hooks_engine.EventName, match_value: ?[]const u8) bool {
        if (comptime host_target.is_wasm) return false;
        if (!self.active()) return false;
        const runtime = self.runtime.?;
        return runtime.wants(name, match_value, self.trust_required);
    }

    /// Runs the hooks for one event. Null when none listens. The outcome is
    /// allocated with `arena`; its notices are already shown.
    pub fn dispatch(
        self: *const TurnHooks,
        arena: std.mem.Allocator,
        name: hooks_engine.EventName,
        match_value: ?[]const u8,
        fields: []const hooks_engine.Field,
        mode: types.PermissionMode,
    ) std.mem.Allocator.Error!?hooks_engine.Outcome {
        if (comptime host_target.is_wasm) return null;
        if (!self.active()) return null;
        const runtime = self.runtime.?;
        if (!runtime.wants(name, match_value, self.trust_required)) return null;

        const event = hooks_engine.Event{
            .name = name,
            .scope = self.scope(mode),
            .match_value = match_value,
            .fields = fields,
        };
        const maybe = try runtime.dispatch(arena, event, self.trust_required, self.cancel);
        if (maybe) |held| {
            var outcome = held;
            self.applyNotices(arena, &outcome);
            return outcome;
        }
        return null;
    }

    /// Shows each notice of `outcome` as a system notice.
    pub fn applyNotices(self: *const TurnHooks, arena: std.mem.Allocator, outcome: *const hooks_engine.Outcome) void {
        if (comptime host_target.is_wasm) return;
        for (outcome.notices) |notice| {
            const text = noticeText(arena, notice) catch |err| {
                debug_trace.logf("hooks", "dropped hook notice: {s}", .{@errorName(err)});
                continue;
            };
            self.deps.pushHookNotice(hookNoticeTone(notice.kind), text) catch |err| {
                debug_trace.logf("hooks", "dropped hook notice: {s}", .{@errorName(err)});
            };
        }
    }

    /// The callback that asks the user's PermissionRequest hooks before a person is asked, or null when no hook can run.
    pub fn permissionRequestHook(self: *TurnHooks) ?permission_auto_classifier.PermissionRequestHook {
        if (comptime host_target.is_wasm) return null;
        if (!self.active()) return null;
        return .{ .context = self, .run = runPermissionRequest };
    }

    /// Runs the PermissionRequest hooks for one prompt. An allow or deny answer
    /// stands in for the person; no answer, or a failed hook, leaves the prompt to them.
    fn runPermissionRequest(
        context: *anyopaque,
        arena: std.mem.Allocator,
        call: types.ToolCall,
        label: []const u8,
    ) ?permission_auto_classifier.PermissionRequestVerdict {
        const self: *TurnHooks = @ptrCast(@alignCast(context));
        const fields = [_]hooks_engine.Field{
            .{ .key = "tool_name", .value = .{ .string = call.name } },
            .{ .key = "tool_input", .value = .{ .json = if (call.arguments_json.len > 0) call.arguments_json else "{}" } },
            .{ .key = "tool_use_id", .value = .{ .string = call.id } },
            .{ .key = "permission_label", .value = .{ .string = label } },
        };
        const outcome = (self.dispatch(arena, .permission_request, call.name, &fields, self.mode) catch |err| {
            debug_trace.logf("hooks", "dropped PermissionRequest hooks: {s}; fx asks the person", .{@errorName(err)});
            return null;
        }) orelse return null;
        return switch (outcome.decision) {
            .allow => .allow,
            .deny => .{ .deny = outcome.reason orelse "no reason given" },
            .proceed, .ask => null,
        };
    }

    /// Runs the user's PermissionDenied hooks after the automatic reviewer denied `call`.
    /// True when a hook allows one retry and the turn still has retries left.
    pub fn permissionDenied(
        self: *TurnHooks,
        arena: std.mem.Allocator,
        call: types.ToolCall,
        reason: []const u8,
    ) bool {
        if (comptime host_target.is_wasm) return false;
        if (!self.active()) return false;
        // Checked before any hook starts, so a capped turn never runs the hooks again.
        if (self.denied_retries >= max_denied_retries) return false;
        if (!self.wants(.permission_denied, call.name)) return false;

        const fields = [_]hooks_engine.Field{
            .{ .key = "tool_name", .value = .{ .string = call.name } },
            .{ .key = "tool_input", .value = .{ .json = if (call.arguments_json.len > 0) call.arguments_json else "{}" } },
            .{ .key = "tool_use_id", .value = .{ .string = call.id } },
            .{ .key = "reason", .value = .{ .string = reason } },
        };
        const outcome = (self.dispatch(arena, .permission_denied, call.name, &fields, self.mode) catch |err| {
            debug_trace.logf("hooks", "dropped PermissionDenied hooks: {s}", .{@errorName(err)});
            return false;
        }) orelse return false;
        if (!outcome.retry) return false;
        self.denied_retries += 1;
        return true;
    }

    /// Runs PostToolUse (`succeeded`) or PostToolUseFailure hooks for one tool result.
    /// Added context and a stop request go into `batch`; a replacement output replaces the model's copy.
    pub fn postToolResult(
        self: *TurnHooks,
        arena: std.mem.Allocator,
        batch: *runtime_tool_batch.StepBatchState,
        call: types.ToolCall,
        output: []const u8,
        succeeded: bool,
    ) PostToolApplied {
        if (comptime host_target.is_wasm) return .{ .output = output };
        if (!self.active()) return .{ .output = output };
        const event_name: hooks_engine.EventName = if (succeeded) .post_tool_use else .post_tool_use_failure;
        if (!self.wants(event_name, call.name)) return .{ .output = output };
        const outcome = self.postToolDispatch(arena, succeeded, call, output) orelse return .{ .output = output };

        var applied = PostToolApplied{ .output = output };
        if (succeeded) {
            if (outcome.updated_output) |updated| {
                applied = self.capReplacement(arena, call.name, updated, output);
            }
        }
        const framed_event: []const u8 = if (succeeded) "PostToolUse" else "PostToolUseFailure";
        if (outcome.additional_context) |text| appendPostToolNote(arena, batch, framed_event, call.name, text);
        if (outcome.stop_reason) |reason| {
            if (batch.stop_reason == null) {
                batch.stop_reason = reason;
            } else {
                debug_trace.logf("hooks", "dropped a second post-tool stop request for {s}; the first one stands", .{call.name});
            }
        }
        return applied;
    }

    /// Cuts a hook's replacement output to the tool result limit, with the marker a tool's own
    /// output gets, and shows the person a notice when it was cut. A failed cut keeps the tool's output.
    fn capReplacement(
        self: *TurnHooks,
        arena: std.mem.Allocator,
        tool_name: []const u8,
        updated: []const u8,
        original: []const u8,
    ) PostToolApplied {
        const prepared = tool_result_limits.prepareModelOutputWithTruncation(arena, tool_name, updated, self.max_tool_result_bytes) catch |err| {
            debug_trace.logf("hooks", "dropped a post-tool replacement for {s}: {s}; the tool's own output is kept", .{ tool_name, @errorName(err) });
            return .{ .output = original };
        };
        if (prepared.truncated) {
            if (arena.print("Hook output for {s} was cut to {d} bytes, the tool result limit", .{ tool_name, self.max_tool_result_bytes })) |text| {
                self.deps.pushHookNotice(.neutral, text) catch |err| {
                    debug_trace.logf("hooks", "dropped hook notice: {s}", .{@errorName(err)});
                };
            } else |err| {
                debug_trace.logf("hooks", "dropped the cut notice for {s}: {s}", .{ tool_name, @errorName(err) });
            }
        }
        return .{ .output = prepared.model_output, .replaced = true };
    }

    /// Dispatches one post-tool event. A failed dispatch is traced and gives no answer.
    fn postToolDispatch(
        self: *TurnHooks,
        arena: std.mem.Allocator,
        succeeded: bool,
        call: types.ToolCall,
        output: []const u8,
    ) ?hooks_engine.Outcome {
        const input_json = if (call.arguments_json.len > 0) call.arguments_json else "{}";
        if (succeeded) {
            const fields = [_]hooks_engine.Field{
                .{ .key = "tool_name", .value = .{ .string = call.name } },
                .{ .key = "tool_input", .value = .{ .json = input_json } },
                .{ .key = "tool_use_id", .value = .{ .string = call.id } },
                .{ .key = "tool_response", .value = toolResponseValue(arena, output) },
            };
            return self.dispatch(arena, .post_tool_use, call.name, &fields, self.mode) catch |err| {
                debug_trace.logf("hooks", "dropped post-tool hooks for {s}: {s}; the tool's own output is kept", .{ call.name, @errorName(err) });
                return null;
            };
        }
        const fields = [_]hooks_engine.Field{
            .{ .key = "tool_name", .value = .{ .string = call.name } },
            .{ .key = "tool_input", .value = .{ .json = input_json } },
            .{ .key = "tool_use_id", .value = .{ .string = call.id } },
            .{ .key = "error", .value = .{ .string = output } },
            .{ .key = "is_interrupt", .value = .{ .boolean = false } },
        };
        return self.dispatch(arena, .post_tool_use_failure, call.name, &fields, self.mode) catch |err| {
            debug_trace.logf("hooks", "dropped post-tool hooks for {s}: {s}; the tool's own output is kept", .{ call.name, @errorName(err) });
            return null;
        };
    }

    /// Runs the user's PostToolBatch hooks once, after every call of a step has its result.
    /// Added context and a stop request go into `batch`.
    pub fn postToolBatch(
        self: *TurnHooks,
        arena: std.mem.Allocator,
        batch: *runtime_tool_batch.StepBatchState,
        calls: []const types.ToolCall,
    ) void {
        if (comptime host_target.is_wasm) return;
        if (!self.active()) return;
        if (calls.len == 0) return;
        if (!self.wants(.post_tool_batch, null)) return;

        const tool_calls = toolCallsJson(arena, calls) catch |err| {
            debug_trace.logf("hooks", "dropped PostToolBatch hooks: {s}", .{@errorName(err)});
            return;
        };
        const fields = [_]hooks_engine.Field{
            .{ .key = "tool_calls", .value = .{ .json = tool_calls } },
        };
        const outcome = (self.dispatch(arena, .post_tool_batch, null, &fields, self.mode) catch |err| {
            debug_trace.logf("hooks", "dropped PostToolBatch hooks: {s}", .{@errorName(err)});
            return;
        }) orelse return;

        if (outcome.additional_context) |text| {
            const framed = frameContext(arena, "PostToolBatch", null, text) catch |err| {
                debug_trace.logf("hooks", "dropped PostToolBatch context: {s}", .{@errorName(err)});
                return;
            };
            runtime_tool_batch.appendToolNotice(arena, batch, framed) catch |err| {
                debug_trace.logf("hooks", "dropped PostToolBatch context: {s}", .{@errorName(err)});
            };
        }
        if (outcome.stop_reason) |reason| {
            if (batch.stop_reason == null) {
                batch.stop_reason = reason;
            } else {
                debug_trace.logf("hooks", "dropped a second PostToolBatch stop request; the first one stands", .{});
            }
        }
    }

    /// Runs the user's Stop hooks (SubagentStop in a subagent turn) on a finished reply.
    /// Returns the model message that makes the agent continue, or null to let the turn end.
    pub fn stop(self: *TurnHooks, arena: std.mem.Allocator, last_reply: []const u8, continuations: u8) ?[]const u8 {
        if (comptime host_target.is_wasm) return null;
        if (!self.active()) return null;
        // Checked before any hook starts, so a capped turn never runs the hooks again.
        if (continuations >= self.stopCap()) return null;
        const event_name = self.stopEvent();
        if (!self.wants(event_name, null)) return null;

        const fields = [_]hooks_engine.Field{
            .{ .key = "stop_hook_active", .value = .{ .boolean = continuations > 0 } },
            .{ .key = "last_assistant_message", .value = .{ .string = last_reply } },
        };
        const outcome = (self.dispatch(arena, event_name, null, &fields, self.mode) catch |err| {
            debug_trace.logf("hooks", "dropped Stop hooks: {s}; the turn ends", .{@errorName(err)});
            return null;
        }) orelse return null;
        const reason = outcome.continue_reason orelse return null;
        return frameContext(arena, event_name.fileName(), null, reason) catch |err| {
            debug_trace.logf("hooks", "dropped Stop continuation: {s}; the turn ends", .{@errorName(err)});
            return null;
        };
    }

    /// Whether the user's Stop hooks still have to check this reply: they listen, the
    /// reply is not checked yet, and the cap has room. `stop` makes the same checks.
    pub fn stopPending(self: *const TurnHooks, continuations: u8, done: bool) bool {
        if (comptime host_target.is_wasm) return false;
        if (!self.active() or done) return false;
        if (continuations >= self.stopCap()) return false;
        return self.wants(self.stopEvent(), null);
    }

    /// Runs the user's SessionStart hooks (SubagentStart in a subagent turn) the first time this
    /// session has a turn in this process, and keeps their context for the session.
    pub fn sessionStart(self: *TurnHooks, arena: std.mem.Allocator, resumed: bool) void {
        if (comptime host_target.is_wasm) return;
        if (!self.active()) return;
        const session_id = self.session_id orelse return;
        const first = self.runtime.?.beginSession(.{
            .session_id = session_id,
            .surface = self.surface,
            .cwd = self.workspace_root,
            .permission_mode = self.mode.label(),
            .trust_required = self.trust_required,
        }) catch |err| {
            debug_trace.logf("hooks", "dropped SessionStart hooks: {s}", .{@errorName(err)});
            return;
        };
        self.noticeWaitingHooks(arena, session_id);
        if (!first) return;

        if (self.surface == .subagent) {
            // The subagent's number reaches a SubagentStart hook as the scope's `agent_id`, which
            // protocol.zig writes, so the event adds no field of its own.
            const outcome = self.dispatch(arena, .subagent_start, null, &.{}, self.mode) catch |err| {
                debug_trace.logf("hooks", "dropped SubagentStart hooks: {s}", .{@errorName(err)});
                return;
            };
            self.keepStartContext(arena, session_id, "SubagentStart", outcome);
            return;
        }

        // The session's source is both the matcher value and a field, so a matcher can name it.
        const source: []const u8 = if (resumed) "resume" else "startup";
        const fields = [_]hooks_engine.Field{.{ .key = "source", .value = .{ .string = source } }};
        const outcome = self.dispatch(arena, .session_start, source, &fields, self.mode) catch |err| {
            debug_trace.logf("hooks", "dropped SessionStart hooks: {s}", .{@errorName(err)});
            return;
        };
        self.keepStartContext(arena, session_id, "SessionStart", outcome);
    }

    /// Tells the person, at the start of each interactive turn where the count of hooks waiting for trust
    /// rose, that they wait and do not run. Only the interactive shell asks for trust, so only its turns are told.
    fn noticeWaitingHooks(self: *const TurnHooks, arena: std.mem.Allocator, session_id: []const u8) void {
        if (comptime host_target.is_wasm) return;
        if (!self.trust_required or self.surface != .interactive) return;
        const runtime = self.runtime orelse return;
        const count = runtime.waitingHooks();
        const due = runtime.trustNoticeDue(session_id, count) orelse return;
        const text = waitingTrustText(arena, due) catch |err| {
            debug_trace.logf("hooks", "dropped the trust notice: {s}", .{@errorName(err)});
            return;
        };
        self.deps.pushHookNotice(.neutral, text) catch |err| {
            debug_trace.logf("hooks", "dropped the trust notice: {s}", .{@errorName(err)});
        };
    }

    /// The session's start context, framed for the model, or null when no start hook added any.
    pub fn sessionContext(self: *TurnHooks, arena: std.mem.Allocator) ?[]const u8 {
        if (comptime host_target.is_wasm) return null;
        if (!self.active()) return null;
        const session_id = self.session_id orelse return null;
        return self.runtime.?.sessionContext(arena, session_id) catch |err| {
            debug_trace.logf("hooks", "dropped session context: {s}", .{@errorName(err)});
            return null;
        };
    }

    /// Keeps the context a start hook added, framed as the event's context, for the rest of the session.
    fn keepStartContext(
        self: *const TurnHooks,
        arena: std.mem.Allocator,
        session_id: []const u8,
        event: []const u8,
        outcome: ?hooks_engine.Outcome,
    ) void {
        const raw = (outcome orelse return).additional_context orelse return;
        // Room for the tags and the event name that frameContext adds. The raw text is cut before framing,
        // so the framed text fits the session limit and keeps its closing tag.
        const frame_reserve_chars: usize = 128;
        comptime std.debug.assert(hooks_engine.limits.text_chars > frame_reserve_chars);
        const room = hooks_engine.limits.text_chars - frame_reserve_chars;
        const cut = hooks_engine.limits.cutChars(raw, room);
        if (cut.was_cut) debug_trace.logf("hooks", "{s} context cut to {d} characters to fit the session limit", .{ event, room });
        const framed = frameContext(arena, event, null, cut.text) catch |err| {
            debug_trace.logf("hooks", "dropped {s} context: {s}", .{ event, @errorName(err) });
            return;
        };
        self.runtime.?.setSessionContext(session_id, framed) catch |err| {
            debug_trace.logf("hooks", "dropped {s} context: {s}", .{ event, @errorName(err) });
        };
    }

    /// The event a finished reply is checked with: SubagentStop in a subagent turn, else Stop.
    fn stopEvent(self: *const TurnHooks) hooks_engine.EventName {
        return if (self.surface == .subagent) .subagent_stop else .stop;
    }

    /// How many continuations this turn's checks may take: Stop and SubagentStop each have
    /// their own cap in the hooks limits. The caps stop a hook that always asks for more
    /// from holding the turn open.
    fn stopCap(self: *const TurnHooks) u8 {
        return switch (self.stopEvent()) {
            .subagent_stop => hooks_engine.limits.subagent_stop_continuations,
            else => hooks_engine.limits.stop_continuations_per_turn,
        };
    }

    /// Runs the user's UserPromptSubmit hooks on one prompt a person sent. A block or stop
    /// gives the notice the person sees; a rewrite gives the prompt the model sees instead;
    /// added context gives a framed note for the turn's model-visible message.
    pub fn userPromptSubmit(self: *TurnHooks, arena: std.mem.Allocator, prompt: []const u8) PromptSubmitApplied {
        if (comptime host_target.is_wasm) return .{};
        if (!self.active()) return .{};
        if (!self.wants(.user_prompt_submit, null)) return .{};

        const fields = [_]hooks_engine.Field{
            .{ .key = "prompt", .value = .{ .string = prompt } },
        };
        const outcome = (self.dispatch(arena, .user_prompt_submit, null, &fields, self.mode) catch |err| {
            debug_trace.logf("hooks", "dropped UserPromptSubmit hooks: {s}; the prompt goes on unchanged", .{@errorName(err)});
            return .{};
        }) orelse return .{};

        // A block never turns into a proceed: if the notice cannot be built, a fixed notice is used.
        if (outcome.decision == .deny or outcome.stop_reason != null) {
            const reason = if (outcome.decision == .deny) outcome.reason orelse "no reason given" else outcome.stop_reason.?;
            const notice = arena.print("A hook blocked this prompt: {f}", .{text_utils.terminalSafe(reason)}) catch |err| blk: {
                debug_trace.logf("hooks", "blocked prompt notice shortened: {s}", .{@errorName(err)});
                break :blk "A hook blocked this prompt.";
            };
            return .{ .blocked_notice = notice };
        }

        var applied: PromptSubmitApplied = .{ .prompt = outcome.updated_input };
        if (outcome.additional_context) |text| {
            applied.context = frameContext(arena, "UserPromptSubmit", null, text) catch |err| blk: {
                debug_trace.logf("hooks", "dropped UserPromptSubmit context: {s}", .{@errorName(err)});
                break :blk null;
            };
        }
        return applied;
    }

    /// Runs the user's PreCompact hooks before one compaction. A deny skips it. The hook's
    /// context is not framed: it goes to the summary model as instructions only.
    pub fn preCompact(self: *TurnHooks, arena: std.mem.Allocator, trigger: []const u8) PreCompactApplied {
        if (comptime host_target.is_wasm) return .{};
        if (!self.active()) return .{};
        if (!self.wants(.pre_compact, trigger)) return .{};

        const fields = [_]hooks_engine.Field{
            .{ .key = "trigger", .value = .{ .string = trigger } },
            .{ .key = "custom_instructions", .value = .null_value },
        };
        const outcome = (self.dispatch(arena, .pre_compact, trigger, &fields, self.mode) catch |err| {
            debug_trace.logf("hooks", "dropped PreCompact hooks: {s}; the compaction goes on unchanged", .{@errorName(err)});
            return .{};
        }) orelse return .{};

        if (outcome.decision == .deny) {
            const reason = outcome.reason orelse "no reason given";
            const notice = arena.print("A hook blocked this compaction: {f}", .{text_utils.terminalSafe(reason)}) catch |err| blk: {
                debug_trace.logf("hooks", "blocked compaction notice shortened: {s}", .{@errorName(err)});
                break :blk "A hook blocked this compaction.";
            };
            return .{ .blocked_notice = notice };
        }
        return .{ .instructions = outcome.additional_context };
    }

    /// Runs the user's PostCompact hooks after a compaction committed. The event only observes.
    pub fn postCompact(self: *TurnHooks, arena: std.mem.Allocator, trigger: []const u8, removed_turns: usize, summary_bytes: usize) void {
        if (comptime host_target.is_wasm) return;
        if (!self.active()) return;
        if (!self.wants(.post_compact, trigger)) return;

        const fields = [_]hooks_engine.Field{
            .{ .key = "trigger", .value = .{ .string = trigger } },
            .{ .key = "removed_turns", .value = tokenValue(@as(u64, removed_turns)) },
            .{ .key = "summary_bytes", .value = tokenValue(@as(u64, summary_bytes)) },
        };
        _ = self.dispatch(arena, .post_compact, trigger, &fields, self.mode) catch |err| {
            debug_trace.logf("hooks", "dropped PostCompact hooks: {s}", .{@errorName(err)});
            return;
        };
    }

    /// The notes queued for this turn's session, each already framed, joined; or null. Taking them
    /// empties the queue, so each note reaches exactly one turn.
    pub fn takeSessionNotes(self: *TurnHooks, arena: std.mem.Allocator) ?[]const u8 {
        if (comptime host_target.is_wasm) return null;
        if (!self.active()) return null;
        const session_id = self.session_id orelse return null;
        return self.runtime.?.takeSessionNotes(arena, session_id) catch |err| {
            debug_trace.logf("hooks", "dropped queued session notes: {s}", .{@errorName(err)});
            return null;
        };
    }

    /// Runs the user's Interrupt hooks once after the user stopped the turn.
    /// The event cannot change the turn, so only the hooks' notices are used.
    pub fn interrupt(self: *TurnHooks, arena: std.mem.Allocator) void {
        if (comptime host_target.is_wasm) return;
        if (!self.active()) return;
        if (!self.wants(.interrupt, null)) return;

        _ = self.dispatch(arena, .interrupt, null, &.{}, self.mode) catch |err| {
            debug_trace.logf("hooks", "dropped Interrupt hooks: {s}", .{@errorName(err)});
            return;
        };
    }

    /// Runs the user's StopFailure hooks once when the turn ends on a failed model request.
    /// The event cannot change the turn, so only the hooks' notices are used; the answer is dropped.
    pub fn stopFailure(self: *TurnHooks, arena: std.mem.Allocator, status: u16, detail: []const u8) void {
        if (comptime host_target.is_wasm) return;
        if (!self.active()) return;
        if (!self.wants(.stop_failure, null)) return;

        const fields = [_]hooks_engine.Field{
            .{ .key = "error", .value = .{ .string = detail } },
            .{ .key = "status", .value = .{ .integer = status } },
        };
        _ = self.dispatch(arena, .stop_failure, null, &fields, self.mode) catch |err| {
            debug_trace.logf("hooks", "dropped StopFailure hooks: {s}", .{@errorName(err)});
            return;
        };
    }

    /// Runs the user's PreModelRequest hooks before one of the turn's model requests.
    pub fn preModelRequest(self: *TurnHooks, arena: std.mem.Allocator, model: []const u8, message_count: usize) void {
        if (comptime host_target.is_wasm) return;
        if (!self.active()) return;
        if (!self.wants(.pre_model_request, null)) return;

        const fields = [_]hooks_engine.Field{
            .{ .key = "model", .value = .{ .string = model } },
            .{ .key = "message_count", .value = .{ .integer = @intCast(message_count) } },
        };
        _ = self.dispatch(arena, .pre_model_request, null, &fields, self.mode) catch |err| {
            debug_trace.logf("hooks", "dropped PreModelRequest hooks: {s}", .{@errorName(err)});
            return;
        };
    }

    /// Runs the user's PostModelRequest hooks after one of the turn's model requests returned. The outcome
    /// is `completed`, `failed`, or the name of the error that ended the request.
    pub fn postModelRequest(
        self: *TurnHooks,
        arena: std.mem.Allocator,
        model: []const u8,
        outcome: []const u8,
        input_tokens: ?u64,
        output_tokens: ?u64,
    ) void {
        if (comptime host_target.is_wasm) return;
        if (!self.active()) return;
        if (!self.wants(.post_model_request, null)) return;

        const fields = [_]hooks_engine.Field{
            .{ .key = "model", .value = .{ .string = model } },
            .{ .key = "outcome", .value = .{ .string = outcome } },
            .{ .key = "input_tokens", .value = tokenValue(input_tokens) },
            .{ .key = "output_tokens", .value = tokenValue(output_tokens) },
        };
        _ = self.dispatch(arena, .post_model_request, null, &fields, self.mode) catch |err| {
            debug_trace.logf("hooks", "dropped PostModelRequest hooks: {s}", .{@errorName(err)});
            return;
        };
    }

    /// A token count as a hook field. Null when the provider did not report it, or when it does not fit.
    fn tokenValue(count: ?u64) hooks_engine.Value {
        const value = count orelse return .null_value;
        const fits = std.math.cast(i64, value) orelse {
            debug_trace.logf("hooks", "token count {d} does not fit a hook field; sent as null", .{value});
            return .null_value;
        };
        return .{ .integer = fits };
    }

    /// Runs PreToolUse for one ready call and applies the answer to `prepared` and `subject`.
    pub fn preToolUse(
        self: *TurnHooks,
        arena: std.mem.Allocator,
        mode: types.PermissionMode,
        prepared: *runtime_lifecycle.PreparedToolCall,
        subject: *?types.ToolCall,
    ) std.mem.Allocator.Error!PreToolUseApplied {
        if (comptime host_target.is_wasm) return .{};
        if (!self.active()) return .{};
        if (prepared.* != .ready) return .{};

        const call = subject.* orelse prepared.call();
        const name = call.name;
        if (!self.wants(.pre_tool_use, name)) return .{};

        const fields = [_]hooks_engine.Field{
            .{ .key = "tool_name", .value = .{ .string = name } },
            .{ .key = "tool_input", .value = .{ .json = if (call.arguments_json.len > 0) call.arguments_json else "{}" } },
            .{ .key = "tool_use_id", .value = .{ .string = call.id } },
        };

        const outcome = (try self.dispatch(arena, .pre_tool_use, name, &fields, mode)) orelse return .{};

        if (outcome.stop_reason) |stop_reason| {
            const reason = try arena.print("A hook ended the turn: {s}", .{stop_reason});
            prepared.* = try runtime_lifecycle.makePreparedBlocked(arena, prepared.call(), .lifecycle_block, reason);
            subject.* = null;
            return .{ .stop_reason = stop_reason };
        }

        if (outcome.decision == .deny) {
            const notice = try denyNoticeText(arena, outcome.decided_by orelse "?", name, outcome.reason);
            self.deps.pushHookNotice(.warning, notice) catch |err| {
                debug_trace.logf("hooks", "dropped hook notice: {s}", .{@errorName(err)});
            };
            prepared.* = try runtime_lifecycle.makePreparedBlocked(
                arena,
                prepared.call(),
                .lifecycle_block,
                outcome.reason orelse "A hook blocked this call.",
            );
            subject.* = null;
            return .{};
        }

        if (outcome.updated_input) |updated| {
            if (try isJsonObject(arena, updated)) {
                try applyUpdatedInput(arena, prepared, subject, updated);
            } else {
                const who = outcome.decided_by orelse "?";
                const notice = try arena.print("Hook {f} returned updated input that is not a JSON object; fx ignores it", .{text_utils.terminalSafe(who)});
                self.deps.pushHookNotice(.warning, notice) catch |err| {
                    debug_trace.logf("hooks", "dropped hook notice: {s}", .{@errorName(err)});
                };
            }
        }

        if (outcome.additional_context) |text| {
            try self.pending_notes.append(arena, try frameContext(arena, "PreToolUse", name, text));
        }

        return .{ .permission = switch (outcome.decision) {
            .allow => .allow,
            .ask => .ask,
            else => .none,
        } };
    }
};

/// The warning a PreToolUse deny shows on screen: the hook, the tool it stopped, and its reason
/// when it gave one. The model gets the bare reason separately, unescaped. The hook's id and reason
/// are hook text, so they are escaped here, where the person's text is built (R4.6).
fn denyNoticeText(arena: std.mem.Allocator, hook_id: []const u8, tool: []const u8, reason: ?[]const u8) std.mem.Allocator.Error![]u8 {
    if (reason) |text| {
        if (text.len > 0) return arena.print("Hook {f} blocked {s}: {f}", .{ text_utils.terminalSafe(hook_id), tool, text_utils.terminalSafe(text) });
    }
    return arena.print("Hook {f} blocked {s}.", .{ text_utils.terminalSafe(hook_id), tool });
}

/// The notice a PreToolUse hook's stop shows the person: the reason the hook gave, escaped as the
/// other hook notices are (R4.6). The model's copy of the reason is a tool result, built elsewhere.
pub fn stopNoticeText(arena: std.mem.Allocator, reason: []const u8) std.mem.Allocator.Error![]u8 {
    return arena.print("A hook ended the turn: {f}", .{text_utils.terminalSafe(reason)});
}

/// What a PreToolUse hook asked of fx's permission check for one call.
pub const PermissionHint = permission_auto_classifier.HookPermission;

/// What PreToolUse changed beyond the call itself.
pub const PreToolUseApplied = struct { permission: PermissionHint = .none, stop_reason: ?[]const u8 = null };

/// Puts the hook's input on the call. A toolbox run's subject executes the input,
/// while the outer call keeps its `run` and takes the input as its arguments.
fn applyUpdatedInput(
    arena: std.mem.Allocator,
    prepared: *runtime_lifecycle.PreparedToolCall,
    subject: *?types.ToolCall,
    updated: []const u8,
) std.mem.Allocator.Error!void {
    switch (prepared.*) {
        .ready => |*ready| {
            if (subject.*) |*carried| {
                carried.arguments_json = updated;
                if (carried.carried_by != null) {
                    ready.arguments_json = try toolboxWithArguments(arena, ready.arguments_json, updated);
                } else {
                    ready.arguments_json = updated;
                }
            } else {
                ready.arguments_json = updated;
            }
            ready.argument_integrity = .valid;
            ready.argument_diagnostic = null;
        },
        else => {},
    }
}

fn isJsonObject(arena: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!bool {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    return value == .object;
}

/// Frames hook context so the model can tell it came from a hook.
fn frameContext(arena: std.mem.Allocator, event: []const u8, tool: ?[]const u8, text: []const u8) std.mem.Allocator.Error![]u8 {
    if (tool) |name| {
        return arena.print("<hook-context event=\"{s}\" tool=\"{s}\">\n{s}\n</hook-context>", .{ event, name, text });
    }
    return arena.print("<hook-context event=\"{s}\">\n{s}\n</hook-context>", .{ event, text });
}

/// The step's calls as one JSON array, in order, for the PostToolBatch hook input.
fn toolCallsJson(arena: std.mem.Allocator, calls: []const types.ToolCall) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    try writer.writeAll("[");
    for (calls, 0..) |call, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.writeAll("{\"tool_name\":");
        try writer.writeAll(try std.json.Stringify.valueAlloc(arena, call.name, .{}));
        try writer.writeAll(",\"tool_use_id\":");
        try writer.writeAll(try std.json.Stringify.valueAlloc(arena, call.id, .{}));
        try writer.writeAll(",\"tool_input\":");
        try writer.writeAll(try batchToolInput(arena, call));
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
    return out.toOwnedSlice();
}

/// A call's arguments when they are a JSON object, else `{}`, so the hook input stays valid JSON.
fn batchToolInput(arena: std.mem.Allocator, call: types.ToolCall) ![]const u8 {
    if (call.arguments_json.len == 0) return "{}";
    if (try isJsonObject(arena, call.arguments_json)) return call.arguments_json;
    debug_trace.logf("hooks", "PostToolBatch input for {s} is not a JSON object; sent as {{}}", .{call.name});
    return "{}";
}

/// Adds one hook context note to the step. A failure is traced and the note is dropped.
fn appendPostToolNote(
    arena: std.mem.Allocator,
    batch: *runtime_tool_batch.StepBatchState,
    event: []const u8,
    tool: []const u8,
    text: []const u8,
) void {
    const framed = frameContext(arena, event, tool, text) catch |err| {
        debug_trace.logf("hooks", "dropped {s} context for {s}: {s}", .{ event, tool, @errorName(err) });
        return;
    };
    runtime_tool_batch.appendToolNotice(arena, batch, framed) catch |err| {
        debug_trace.logf("hooks", "dropped {s} context for {s}: {s}", .{ event, tool, @errorName(err) });
    };
}

/// The tool's output as hook input: parsed JSON when it parses, else plain text.
fn toolResponseValue(arena: std.mem.Allocator, output: []const u8) hooks_engine.Value {
    _ = std.json.parseFromSliceLeaky(std.json.Value, arena, output, .{}) catch return .{ .string = output };
    return .{ .json = output };
}

/// Runs the user's Notification hooks in the background when fx needs the person: a permission
/// prompt, a question, or a route-recovery choice. The caller does not wait; the runtime's
/// `deinit` waits for the run.
pub fn notification(lifecycle: runtime_lifecycle.LifecycleContext, notification_type: []const u8, message: []const u8) void {
    if (comptime host_target.is_wasm) return;
    const runtime = lifecycle.user_hooks orelse return;
    // A background event can arrive with no turn, so pick up an edited hook file first.
    runtime.refresh();

    const fields = [_]hooks_engine.Field{
        .{ .key = "notification_type", .value = .{ .string = notification_type } },
        .{ .key = "message", .value = .{ .string = message } },
    };
    const event: hooks_engine.Event = .{
        .name = .notification,
        .scope = noModeScope(lifecycle),
        .match_value = notification_type,
        .fields = &fields,
    };
    runtime.dispatchDetached(event, lifecycle.trust_required);
}

/// The scope of an event that fx raises outside a turn. Such an event has no permission mode,
/// so the scope reports an empty one.
fn noModeScope(lifecycle: runtime_lifecycle.LifecycleContext) hooks_engine.Scope {
    return .{
        .surface = surfaceOf(lifecycle),
        .session_id = lifecycle.scope.session_id,
        .subagent_id = lifecycle.scope.subagent_id,
        .cwd = lifecycle.scope.workspace_root,
        .project_dir = lifecycle.scope.workspace_root,
        .permission_mode = "",
    };
}

/// Holds the lifecycle that the instruction filter asks the user's InstructionsLoaded hooks with.
/// `filter` gives the context gather a pointer to this value, so it must outlive that gather.
/// Without a lifecycle, or one without user hooks, there is no filter and every file loads.
pub const InstructionFilterState = struct {
    lifecycle: ?runtime_lifecycle.LifecycleContext = null,

    /// The filter to pass into a context input, or null when no user hooks can run here. With no
    /// InstructionsLoaded hook for either reason, there is no filter, so the gather does no stat or hook work.
    pub fn filter(self: *InstructionFilterState) ?context_contract.InstructionFilter {
        if (comptime host_target.is_wasm) return null;
        const lifecycle = self.lifecycle orelse return null;
        const runtime = lifecycle.user_hooks orelse return null;
        const trust = lifecycle.trust_required;
        if (!runtime.wants(.instructions_loaded, @tagName(context_contract.InstructionLoadReason.session_start), trust) and
            !runtime.wants(.instructions_loaded, @tagName(context_contract.InstructionLoadReason.nested_traversal), trust)) return null;
        return .{ .context = self, .allow = allowInstruction };
    }
};

/// Asks the user's InstructionsLoaded hooks whether an instruction file may load. A remembered answer
/// for this session, path, and stamp is reused, so each file is asked once per session and stamp. Only
/// a real allow or deny is remembered: a hook that fails leaves the file loading, and the next gather asks.
fn allowInstruction(context: *anyopaque, path: []const u8, reason: context_contract.InstructionLoadReason, stamp: u64) bool {
    const state: *InstructionFilterState = @ptrCast(@alignCast(context));
    const lifecycle = state.lifecycle orelse return true;
    const runtime = lifecycle.user_hooks orelse return true;
    const session_id = lifecycle.scope.session_id;
    if (session_id) |id| {
        if (runtime.instructionDecision(id, path, stamp)) |allow| return allow;
    }
    const reason_name = @tagName(reason);
    if (!runtime.wants(.instructions_loaded, reason_name, lifecycle.trust_required)) return true;

    // The runtime's own allocator, the one its owner passed in at init: no global allocator.
    var arena_state = std.heap.ArenaAllocator.init(runtime.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fields = [_]hooks_engine.Field{
        .{ .key = "file_path", .value = .{ .string = path } },
        .{ .key = "load_reason", .value = .{ .string = reason_name } },
    };
    const event: hooks_engine.Event = .{
        .name = .instructions_loaded,
        .scope = noModeScope(lifecycle),
        .match_value = reason_name,
        .fields = &fields,
    };
    const outcome = (runtime.dispatch(arena, event, lifecycle.trust_required, null) catch |err| {
        debug_trace.logf("hooks", "dropped InstructionsLoaded hooks for {s}: {s}; the file loads", .{ path, @errorName(err) });
        return true;
    }) orelse return true;
    for (outcome.notices) |notice| debug_trace.logf("hooks", "InstructionsLoaded notice: kind={s} bytes={d}", .{ @tagName(notice.kind), notice.text.len });
    const allow = outcome.decision != .deny;
    if (session_id) |id| {
        runtime.rememberInstructionDecision(id, path, stamp, allow) catch |err| {
            debug_trace.logf("hooks", "InstructionsLoaded decision not remembered for {s}: {s}", .{ path, @errorName(err) });
        };
    }
    return allow;
}

/// Runs the user's ConfigChange hooks before a setting changes during a session. It runs them
/// synchronously, because a refusal must come back before the change. Returns the refusal to show
/// when a hook refused the change, with the notices of the hooks that ran. A null refusal lets the
/// change go ahead.
pub fn configChange(
    lifecycle: runtime_lifecycle.LifecycleContext,
    arena: std.mem.Allocator,
    source: []const u8,
    key: []const u8,
    old_value: ?[]const u8,
    new_value: []const u8,
) ChangeDecision {
    if (comptime host_target.is_wasm) return .{};
    const runtime = lifecycle.user_hooks orelse return .{};
    // A setting can change with no turn, so pick up an edited hook file first.
    runtime.refresh();
    if (!runtime.wants(.config_change, source, lifecycle.trust_required)) return .{};

    const fields = [_]hooks_engine.Field{
        .{ .key = "source", .value = .{ .string = source } },
        .{ .key = "key", .value = .{ .string = key } },
        .{ .key = "old_value", .value = if (old_value) |text| hooks_engine.Value{ .string = text } else hooks_engine.Value.null_value },
        .{ .key = "new_value", .value = .{ .string = new_value } },
    };
    const event: hooks_engine.Event = .{
        .name = .config_change,
        .scope = noModeScope(lifecycle),
        .match_value = source,
        .fields = &fields,
    };
    return decideChange(runtime, arena, event, lifecycle.trust_required, null, .setting);
}

/// Runs the user's PreModelSwitch hooks before the active model changes. A deny refuses the
/// change, and the returned refusal says why; a null refusal lets the change go ahead. The
/// notices of the hooks that ran come back with it.
pub fn preModelSwitch(lifecycle: runtime_lifecycle.LifecycleContext, arena: std.mem.Allocator, old_model: []const u8, new_model: []const u8) ChangeDecision {
    if (comptime host_target.is_wasm) return .{};
    const runtime = lifecycle.user_hooks orelse return .{};
    // A model can change with no turn, so pick up an edited hook file first.
    runtime.refresh();
    if (!runtime.wants(.pre_model_switch, null, lifecycle.trust_required)) return .{};

    const fields = modelSwitchFields(old_model, new_model);
    const event = modelSwitchEvent(lifecycle, .pre_model_switch, &fields);
    return decideChange(runtime, arena, event, lifecycle.trust_required, null, .model);
}

/// The two fields a model-switch event carries: the model before the change and the model it selects.
fn modelSwitchFields(old_model: []const u8, new_model: []const u8) [2]hooks_engine.Field {
    return .{
        .{ .key = "old_model", .value = .{ .string = old_model } },
        .{ .key = "new_model", .value = .{ .string = new_model } },
    };
}

/// A model-switch event over `fields`, which the caller keeps alive while the event is used.
fn modelSwitchEvent(lifecycle: runtime_lifecycle.LifecycleContext, name: hooks_engine.EventName, fields: []const hooks_engine.Field) hooks_engine.Event {
    return .{ .name = name, .scope = noModeScope(lifecycle), .fields = fields };
}

/// What a ChangeDecision is about: a refusal names it, and the fallback text uses it when the reason cannot be written.
/// `observed` is an observe-only event (PostModelSwitch): it never refuses, so its refusal texts are never shown.
pub const ChangeKind = enum {
    setting,
    model,
    observed,

    fn subject(self: ChangeKind) []const u8 {
        return switch (self) {
            .setting => "this setting change",
            .model, .observed => "the model change",
        };
    }

    fn fallbackRefusal(self: ChangeKind) []const u8 {
        return switch (self) {
            .setting => "A hook refused this setting change.",
            .model, .observed => "A hook refused the model change.",
        };
    }
};

/// The one decision for a ConfigChange or PreModelSwitch event (R1.8). It runs the hooks that listen for `event`
/// with `cancel` (null when nothing can cancel it), and returns the refusal (null when no hook refused) and the
/// notices. The synchronous callers and the HookGate thread both call it, so they decide alike. A dispatch error
/// lets the change go ahead.
fn decideChange(
    runtime: *runtime_lifecycle.UserHooksRuntime,
    arena: std.mem.Allocator,
    event: hooks_engine.Event,
    trust_required: bool,
    cancel: ?*const std.atomic.Value(bool),
    kind: ChangeKind,
) ChangeDecision {
    if (kind == .observed) return observeEvent(runtime, arena, event, trust_required, cancel);
    const label = event.name.fileName();
    const outcome = (runtime.dispatch(arena, event, trust_required, cancel) catch |err| {
        debug_trace.logf("hooks", "dropped {s} hooks: {s}; the change goes ahead", .{ label, @errorName(err) });
        return .{};
    }) orelse return .{};
    for (outcome.notices) |notice| debug_trace.logf("hooks", "{s} notice: kind={s} bytes={d}", .{ label, @tagName(notice.kind), notice.text.len });
    const notices = decidedNotices(arena, outcome.notices);
    if (outcome.decision != .deny) return .{ .notices = notices };

    const reason = outcome.reason orelse "no reason given";
    const refusal = arena.print("A hook refused {s}: {f}", .{ kind.subject(), text_utils.terminalSafe(reason) }) catch |err| blk: {
        debug_trace.logf("hooks", "refusal notice shortened: {s}", .{@errorName(err)});
        break :blk kind.fallbackRefusal();
    };
    return .{ .refusal = refusal, .notices = notices };
}

/// Whether an enabled, trusted hook listens for this event, so the change must wait for its answer. It picks up an
/// edited hook file first, as the synchronous paths do. False means no trusted hook runs: the change applies at once.
pub fn wouldRunFor(lifecycle: runtime_lifecycle.LifecycleContext, name: hooks_engine.EventName, match_value: ?[]const u8) bool {
    if (comptime host_target.is_wasm) return false;
    const runtime = lifecycle.user_hooks orelse return false;
    runtime.refresh();
    return runtime.hasTrustedMatch(name, match_value) catch |err| blk: {
        debug_trace.logf("hooks", "could not check for a {s} hook: {s}; the change waits for its answer", .{ name.fileName(), @errorName(err) });
        break :blk true;
    };
}

/// Starts the ConfigChange check for a setting change on `gate`, when a trusted hook would run for it.
/// Returns false when none would: the caller applies the change now. The gate copies the event, so the
/// caller's strings may go away once this returns. Errors when the gate cannot start.
pub fn beginConfigChange(
    gate: *HookGate,
    lifecycle: runtime_lifecycle.LifecycleContext,
    source: []const u8,
    key: []const u8,
    old_value: []const u8,
    new_value: []const u8,
) !bool {
    if (comptime host_target.is_wasm) return false;
    if (!wouldRunFor(lifecycle, .config_change, source)) return false;
    const runtime = lifecycle.user_hooks orelse return false;
    const fields = [_]hooks_engine.Field{
        .{ .key = "source", .value = .{ .string = source } },
        .{ .key = "key", .value = .{ .string = key } },
        .{ .key = "old_value", .value = .{ .string = old_value } },
        .{ .key = "new_value", .value = .{ .string = new_value } },
    };
    const event: hooks_engine.Event = .{
        .name = .config_change,
        .scope = noModeScope(lifecycle),
        .match_value = source,
        .fields = &fields,
    };
    try gate.start(runtime, .setting, event, lifecycle.trust_required);
    return true;
}

/// Copies every string an event borrows into `arena`, so the copy does not depend on the caller's memory.
fn copyEvent(arena: std.mem.Allocator, event: hooks_engine.Event) std.mem.Allocator.Error!hooks_engine.Event {
    const fields = try arena.alloc(hooks_engine.Field, event.fields.len);
    for (event.fields, fields) |source, *target| {
        target.* = .{ .key = try arena.dupe(u8, source.key), .value = try copyValue(arena, source.value) };
    }
    var scope = event.scope;
    scope.session_id = try dupeOptional(arena, event.scope.session_id);
    scope.cwd = try arena.dupe(u8, event.scope.cwd);
    scope.project_dir = try arena.dupe(u8, event.scope.project_dir);
    scope.permission_mode = try arena.dupe(u8, event.scope.permission_mode);
    scope.transcript_path = try dupeOptional(arena, event.scope.transcript_path);
    return .{
        .name = event.name,
        .scope = scope,
        .match_value = try dupeOptional(arena, event.match_value),
        .fields = fields,
    };
}

fn copyValue(arena: std.mem.Allocator, value: hooks_engine.Value) std.mem.Allocator.Error!hooks_engine.Value {
    return switch (value) {
        .string => |text| .{ .string = try arena.dupe(u8, text) },
        .json => |text| .{ .json = try arena.dupe(u8, text) },
        .boolean, .integer, .null_value => value,
    };
}

fn dupeOptional(arena: std.mem.Allocator, text: ?[]const u8) std.mem.Allocator.Error!?[]const u8 {
    const value = text orelse return null;
    return try arena.dupe(u8, value);
}

/// Runs one ConfigChange or PreModelSwitch decision on a thread, so the UI thread never waits for a hook (R2.1).
/// The hook adapter owns it. `start` copies the event into the gate's own arena, so the caller may reuse its buffers.
/// `requestCancel` sets the flag the hooks poll (R2.4). `take` returns the result once the task has finished, and
/// never waits for it. A gate cancelled while its task still runs stays open until the task ends, and the next
/// `take` frees it. `deinit` cancels and awaits a gate that is still open, for exit (R3.9).
pub const HookGate = struct {
    alloc: std.mem.Allocator,
    current: ?*Job = null,

    pub const Outcome = enum { allowed, refused, cancelled };

    /// A finished gate: what it decided, and the text it owns. `deinit` frees that text.
    pub const Result = struct {
        outcome: Outcome,
        /// The refusal text when a hook refused the change; null otherwise.
        refusal: ?[]const u8 = null,
        /// The notices of the hooks that ran, in order.
        notices: []const deps_mod.HookNotice = &.{},
        /// The framed context of an observe-only event, for the session's next turn. Null otherwise, and when cancelled.
        context: ?[]const u8 = null,
        arena: std.heap.ArenaAllocator,

        pub fn deinit(self: *Result) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };

    const Job = struct {
        runtime: *runtime_lifecycle.UserHooksRuntime,
        kind: ChangeKind,
        trust_required: bool,
        /// The copied event and the decision text. It goes to the Result when `take` returns.
        arena: std.heap.ArenaAllocator,
        event: hooks_engine.Event = undefined,
        decision: ChangeDecision = .{},
        cancel: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        /// The task that runs `run`. `take` and `deinit` await it.
        future: ?std.Io.Future(void) = null,

        fn run(self: *Job) void {
            defer self.done.store(true, .release);
            self.decision = decideChange(self.runtime, self.arena.allocator(), self.event, self.trust_required, &self.cancel, self.kind);
        }
    };

    /// Starts the decision as an `std.Io` task. `runtime` must outlive the gate: `take` or `deinit` must run before the runtime
    /// is freed. Returns error.HookGateBusy while another gate is open.
    pub fn start(self: *HookGate, runtime: *runtime_lifecycle.UserHooksRuntime, kind: ChangeKind, event: hooks_engine.Event, trust_required: bool) !void {
        if (self.current != null) return error.HookGateBusy;
        const job = try self.alloc.create(Job);
        errdefer self.alloc.destroy(job);
        job.* = .{ .runtime = runtime, .kind = kind, .trust_required = trust_required, .arena = std.heap.ArenaAllocator.init(self.alloc) };
        errdefer job.arena.deinit();
        job.event = try copyEvent(job.arena.allocator(), event);
        job.future = try io_mod.getIo().concurrent(Job.run, .{job});
        self.current = job;
    }

    /// The finished gate's result, or null while its task still runs or no gate is open. It awaits the task only
    /// once the task has finished, so this never waits on a hook.
    pub fn take(self: *HookGate) ?Result {
        const job = self.current orelse return null;
        if (!job.done.load(.acquire)) return null;
        if (job.future) |*future| future.await(io_mod.getIo());
        self.current = null;
        const outcome: Outcome = if (job.cancel.load(.acquire)) .cancelled else if (job.decision.refusal != null) .refused else .allowed;
        var context = job.decision.context;
        if (outcome == .cancelled and context != null) {
            debug_trace.logf("hooks", "dropped PostModelSwitch context: its check was cancelled", .{});
            context = null;
        }
        const result: Result = .{
            .outcome = outcome,
            .refusal = if (outcome == .refused) job.decision.refusal else null,
            .notices = job.decision.notices,
            .context = context,
            .arena = job.arena,
        };
        self.alloc.destroy(job);
        return result;
    }

    /// Asks the open decision to stop. The hooks stop within one poll, and the next `take` returns `cancelled`. It
    /// does not wait. Returns false when no gate is open.
    pub fn requestCancel(self: *HookGate) bool {
        const job = self.current orelse return false;
        job.cancel.store(true, .seq_cst);
        return true;
    }

    /// Whether a gate is open: started, and not yet taken.
    fn isOpen(self: *const HookGate) bool {
        return self.current != null;
    }

    /// Cancels and awaits an open gate, then frees it. The hooks stop within one poll, so exit does not wait on them.
    pub fn deinit(self: *HookGate) void {
        const job = self.current orelse return;
        job.cancel.store(true, .seq_cst);
        if (job.future) |*future| future.await(io_mod.getIo());
        job.arena.deinit();
        self.alloc.destroy(job);
        self.current = null;
    }
};

/// Runs the user's PostModelSwitch hooks after the active model changed, on the calling thread. Their context is
/// queued for the session's next turn, because the event cannot change the turn it follows. Returns the notices of
/// the hooks that ran. The UI path starts the same check on the hook gate instead (`beginPostModelSwitch`).
pub fn postModelSwitch(lifecycle: runtime_lifecycle.LifecycleContext, arena: std.mem.Allocator, old_model: []const u8, new_model: []const u8) []const deps_mod.HookNotice {
    if (comptime host_target.is_wasm) return &.{};
    const runtime = lifecycle.user_hooks orelse return &.{};
    // A model can change with no turn, so pick up an edited hook file first.
    runtime.refresh();
    if (!runtime.wants(.post_model_switch, null, lifecycle.trust_required)) return &.{};

    const fields = modelSwitchFields(old_model, new_model);
    const event = modelSwitchEvent(lifecycle, .post_model_switch, &fields);
    const decision = observeEvent(runtime, arena, event, lifecycle.trust_required, null);
    if (decision.context) |framed| queueObservedContext(runtime, lifecycle.scope.session_id, framed);
    return decision.notices;
}

/// Runs an observe-only event's hooks with `cancel` (null when nothing can cancel them). Nothing is refused. The
/// notices come back, and the context the hooks gave comes back framed for the session's next turn. A dispatch
/// error keeps no context and the notices of the hooks that ran.
fn observeEvent(
    runtime: *runtime_lifecycle.UserHooksRuntime,
    arena: std.mem.Allocator,
    event: hooks_engine.Event,
    trust_required: bool,
    cancel: ?*const std.atomic.Value(bool),
) ChangeDecision {
    const label = event.name.fileName();
    const outcome = (runtime.dispatch(arena, event, trust_required, cancel) catch |err| {
        debug_trace.logf("hooks", "dropped {s} hooks: {s}", .{ label, @errorName(err) });
        return .{};
    }) orelse return .{};
    for (outcome.notices) |notice| debug_trace.logf("hooks", "{s} notice: kind={s} bytes={d}", .{ label, @tagName(notice.kind), notice.text.len });
    const notices = decidedNotices(arena, outcome.notices);
    const text = outcome.additional_context orelse return .{ .notices = notices };
    const framed = frameContext(arena, label, null, text) catch |err| {
        debug_trace.logf("hooks", "dropped {s} context: {s}", .{ label, @errorName(err) });
        return .{ .notices = notices };
    };
    return .{ .notices = notices, .context = framed };
}

/// Queues the framed context of an observe-only event for the session's next turn. A context with no session id, or
/// one the runtime cannot keep, is traced. Its notices show either way.
pub fn queueObservedContext(runtime: *runtime_lifecycle.UserHooksRuntime, session_id: ?[]const u8, framed: []const u8) void {
    if (comptime host_target.is_wasm) return;
    const id = session_id orelse {
        debug_trace.logf("hooks", "dropped PostModelSwitch context: the scope has no session id", .{});
        return;
    };
    runtime.queueSessionNote(id, framed) catch |err| {
        debug_trace.logf("hooks", "dropped PostModelSwitch context: {s}", .{@errorName(err)});
    };
}

/// Starts the PreModelSwitch check for a model change on `gate`, when a trusted hook would run for it. Returns false
/// when none would: the caller applies the change now. The gate copies the event, so the caller's strings may go away
/// once this returns. Errors when the gate cannot start.
pub fn beginPreModelSwitch(gate: *HookGate, lifecycle: runtime_lifecycle.LifecycleContext, old_model: []const u8, new_model: []const u8) !bool {
    if (comptime host_target.is_wasm) return false;
    if (!wouldRunFor(lifecycle, .pre_model_switch, null)) return false;
    const runtime = lifecycle.user_hooks orelse return false;
    const fields = modelSwitchFields(old_model, new_model);
    try gate.start(runtime, .model, modelSwitchEvent(lifecycle, .pre_model_switch, &fields), lifecycle.trust_required);
    return true;
}

/// Starts the PostModelSwitch check for a model change that already applied, on `gate`, when a trusted hook would run
/// for it. The check is observe-only: its notices and context come back with the result. Returns false when no hook
/// would run. The gate copies the event, as `beginPreModelSwitch` describes.
pub fn beginPostModelSwitch(gate: *HookGate, lifecycle: runtime_lifecycle.LifecycleContext, old_model: []const u8, new_model: []const u8) !bool {
    if (comptime host_target.is_wasm) return false;
    if (!wouldRunFor(lifecycle, .post_model_switch, null)) return false;
    const runtime = lifecycle.user_hooks orelse return false;
    const fields = modelSwitchFields(old_model, new_model);
    try gate.start(runtime, .observed, modelSwitchEvent(lifecycle, .post_model_switch, &fields), lifecycle.trust_required);
    return true;
}

/// The note the model reads when a PermissionDenied hook allowed one retry of `tool`.
pub fn deniedRetryNote(arena: std.mem.Allocator, tool: []const u8) ![]u8 {
    return frameContext(arena, "PermissionDenied", tool, "A user hook allows one retry of this denied call. Try it again only if a change makes it safe.");
}

/// Rewrites a toolbox run's outer arguments so its `arguments` key holds `updated`.
fn toolboxWithArguments(arena: std.mem.Allocator, outer_json: []const u8, updated: []const u8) std.mem.Allocator.Error![]const u8 {
    var outer = std.json.parseFromSliceLeaky(std.json.Value, arena, outer_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("hooks", "could not rewrite toolbox arguments; the call runs with the hook's input", .{});
            return outer_json;
        },
    };
    if (outer != .object) {
        debug_trace.logf("hooks", "could not rewrite toolbox arguments; the call runs with the hook's input", .{});
        return outer_json;
    }
    const updated_value = std.json.parseFromSliceLeaky(std.json.Value, arena, updated, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("hooks", "could not rewrite toolbox arguments; the call runs with the hook's input", .{});
            return outer_json;
        },
    };
    try outer.object.put(arena, "arguments", updated_value);
    return std.json.Stringify.valueAlloc(arena, outer, .{});
}

fn surfaceOf(lifecycle: runtime_lifecycle.LifecycleContext) hooks_engine.Surface {
    return switch (lifecycle.scope.kind) {
        .interactive => .interactive,
        .ask => .ask,
        .acp => if (lifecycle.libfx) .libfx else .acp,
        .subagent => .subagent,
    };
}

/// What a ConfigChange or PreModelSwitch hook decided, and the notices its hooks gave. The refusal
/// and the notices are allocated with the call's arena.
pub const ChangeDecision = struct {
    /// The refusal text when a hook denied the change; null lets the change go ahead.
    refusal: ?[]const u8 = null,
    /// The notices of the hooks that ran, in order. Empty when none spoke.
    notices: []const deps_mod.HookNotice = &.{},
    /// The context an observe-only event gave, framed for the session's next turn; null when none did.
    context: ?[]const u8 = null,
};

/// The notice type that settings and model hooks return with their decision.
pub const HookNotice = deps_mod.HookNotice;

/// The notices of a settings or model hook, with the text and tone a turn's notice has. A notice
/// that cannot be built or stored is traced and skipped. Allocated with `arena`.
fn decidedNotices(arena: std.mem.Allocator, notices: []const hooks_engine.answer.Notice) []const deps_mod.HookNotice {
    var out: std.ArrayList(deps_mod.HookNotice) = .empty;
    for (notices) |notice| {
        const text = noticeText(arena, notice) catch |err| {
            debug_trace.logf("hooks", "dropped hook notice: {s}", .{@errorName(err)});
            continue;
        };
        out.append(arena, .{ .tone = hookNoticeTone(notice.kind), .text = text }) catch |err| {
            debug_trace.logf("hooks", "dropped hook notice: {s}", .{@errorName(err)});
        };
    }
    return out.toOwnedSlice(arena) catch |err| {
        debug_trace.logf("hooks", "dropped hook notices: {s}", .{@errorName(err)});
        return &.{};
    };
}

/// The text a person reads for a hook notice. Hook text is escaped here, where the notice is built (R4.6),
/// so every consumer (the screen, `fx ask`, ACP) gets safe text and must not escape it again.
/// Allocated with `arena`.
fn noticeText(arena: std.mem.Allocator, notice: hooks_engine.answer.Notice) std.mem.Allocator.Error![]u8 {
    return switch (notice.kind) {
        .message => arena.print("Hook {f}: {f}", .{ text_utils.terminalSafe(notice.hook_id), text_utils.terminalSafe(notice.text) }),
        else => arena.print("Hook {f}", .{text_utils.terminalSafe(notice.text)}),
    };
}

/// The tone a hook notice shows with: a failure or a dropped answer is a warning, a message or a cut is neutral.
fn hookNoticeTone(kind: hooks_engine.answer.NoticeKind) deps_mod.HookNoticeTone {
    return switch (kind) {
        .failure, .dropped => .warning,
        .message, .cut => .neutral,
    };
}

/// The trust notice's text: the singular for one hook, the plural for more. Allocated with `arena`.
fn waitingTrustText(arena: std.mem.Allocator, count: usize) std.mem.Allocator.Error![]u8 {
    if (count == 1) return arena.dupe(u8, "1 hook waits for trust and does not run. Run /hook list to review it.");
    return arena.print("{d} hooks wait for trust and do not run. Run /hook list to review them.", .{count});
}

fn testLifecycle(kind: @import("../../hooks/definitions.zig").ScopeKind) runtime_lifecycle.LifecycleContext {
    return .{
        .view = @import("../../hooks/hooks.zig").RuntimeView.empty(),
        .scope = .{ .kind = kind, .workspace_root = "/fixture" },
        .outcome_allocator = std.testing.allocator,
    };
}

test "with no runtime nothing runs" {
    const lifecycle = testLifecycle(.ask);
    const turn = TurnHooks.init(lifecycle, undefined, 3, null);

    try std.testing.expect(!turn.active());
    try std.testing.expect(!turn.wants(.pre_tool_use, "shell"));
    const outcome = try turn.dispatch(std.testing.allocator, .pre_tool_use, "shell", &.{}, .auto);
    try std.testing.expect(outcome == null);
}

test "each surface kind maps to its engine surface" {
    try std.testing.expectEqual(hooks_engine.Surface.interactive, surfaceOf(testLifecycle(.interactive)));
    try std.testing.expectEqual(hooks_engine.Surface.ask, surfaceOf(testLifecycle(.ask)));
    try std.testing.expectEqual(hooks_engine.Surface.acp, surfaceOf(testLifecycle(.acp)));
    try std.testing.expectEqual(hooks_engine.Surface.subagent, surfaceOf(testLifecycle(.subagent)));

    var libfx = testLifecycle(.acp);
    libfx.libfx = true;
    try std.testing.expectEqual(hooks_engine.Surface.libfx, surfaceOf(libfx));
}

/// Records what `applyNotices` hands the host, for the notice tone tests.
const NoticeCapture = struct {
    tones: [4]deps_mod.HookNoticeTone = undefined,
    hook_texts: [4][]const u8 = undefined,
    hook_count: usize = 0,
    system_texts: [4][]const u8 = undefined,
    system_count: usize = 0,

    fn pushHook(ctx: *anyopaque, tone: deps_mod.HookNoticeTone, text: []const u8) anyerror!void {
        const self: *NoticeCapture = @ptrCast(@alignCast(ctx));
        self.tones[self.hook_count] = tone;
        self.hook_texts[self.hook_count] = text;
        self.hook_count += 1;
    }

    fn pushSystem(ctx: *anyopaque, text: []const u8) anyerror!void {
        const self: *NoticeCapture = @ptrCast(@alignCast(ctx));
        self.system_texts[self.system_count] = text;
        self.system_count += 1;
    }
};

test "applyNotices shows a failure or a dropped answer as a warning and the rest as neutral, under the hook tone" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    var capture = NoticeCapture{};
    var deps: AgentRuntimeDeps = undefined;
    deps.ctx = &capture;
    deps.push_system_notice = NoticeCapture.pushSystem;
    deps.push_hook_notice = NoticeCapture.pushHook;
    const turn = TurnHooks.init(testLifecycle(.interactive), &deps, 3, null);

    var notices = [_]hooks_engine.answer.Notice{
        .{ .kind = .message, .hook_id = @constCast("guard"), .text = @constCast("remember the style guide") },
        .{ .kind = .failure, .hook_id = @constCast("slow"), .text = @constCast("slow failed: timed out") },
        .{ .kind = .cut, .hook_id = @constCast("slow"), .text = @constCast("slow: the added context was cut to 10000 characters") },
        .{ .kind = .dropped, .hook_id = @constCast("slow"), .text = @constCast("slow returned a retry request, which PostToolUse does not accept") },
    };
    var outcome: hooks_engine.Outcome = .{ .notices = &notices };
    turn.applyNotices(arena_state.allocator(), &outcome);

    try std.testing.expectEqual(@as(usize, 4), capture.hook_count);
    try std.testing.expectEqual(deps_mod.HookNoticeTone.neutral, capture.tones[0]);
    try std.testing.expectEqualStrings("Hook guard: remember the style guide", capture.hook_texts[0]);
    try std.testing.expectEqual(deps_mod.HookNoticeTone.warning, capture.tones[1]);
    try std.testing.expectEqualStrings("Hook slow failed: timed out", capture.hook_texts[1]);
    try std.testing.expectEqual(deps_mod.HookNoticeTone.neutral, capture.tones[2]);
    try std.testing.expectEqualStrings("Hook slow: the added context was cut to 10000 characters", capture.hook_texts[2]);
    try std.testing.expectEqual(deps_mod.HookNoticeTone.warning, capture.tones[3]);
    try std.testing.expectEqualStrings("Hook slow returned a retry request, which PostToolUse does not accept", capture.hook_texts[3]);
    try std.testing.expectEqual(@as(usize, 0), capture.system_count);
}

test "applyNotices falls back to a system notice when the host has no hook tone" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    var capture = NoticeCapture{};
    var deps: AgentRuntimeDeps = undefined;
    deps.ctx = &capture;
    deps.push_system_notice = NoticeCapture.pushSystem;
    deps.push_hook_notice = null;
    const turn = TurnHooks.init(testLifecycle(.interactive), &deps, 3, null);

    var notices = [_]hooks_engine.answer.Notice{
        .{ .kind = .failure, .hook_id = @constCast("slow"), .text = @constCast("slow failed: timed out") },
    };
    var outcome: hooks_engine.Outcome = .{ .notices = &notices };
    turn.applyNotices(arena_state.allocator(), &outcome);

    try std.testing.expectEqual(@as(usize, 0), capture.hook_count);
    try std.testing.expectEqual(@as(usize, 1), capture.system_count);
    try std.testing.expectEqualStrings("Hook slow failed: timed out", capture.system_texts[0]);
}

const guard_hooks_text = "{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"shell\",\"hooks\":[{\"type\":\"command\",\"command\":\"true\",\"id\":\"guard\"}]}]}}";
const two_hooks_text = "{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"shell\",\"hooks\":[{\"type\":\"command\",\"command\":\"true\",\"id\":\"guard\"}]}],\"PostToolUse\":[{\"matcher\":\"shell\",\"hooks\":[{\"type\":\"command\",\"command\":\"true\",\"id\":\"log\"}]}]}}";

/// Runs `turns` session starts of one session in a workspace whose `.fx/hooks.json` is `hooks_text`
/// (empty: no file). What the host was shown lands in `capture`; its texts live in `arena`.
fn sessionStartsWithHooks(
    alloc: std.mem.Allocator,
    arena: std.mem.Allocator,
    capture: *NoticeCapture,
    hooks_text: []const u8,
    trust_required: bool,
    kind: @import("../../hooks/definitions.zig").ScopeKind,
    turns: usize,
) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/.fx");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    if (hooks_text.len > 0) {
        const hooks_path = try std.Io.Dir.path.join(alloc, &.{ workspace, ".fx", "hooks.json" });
        defer alloc.free(hooks_path);
        try io_mod.writeFileAtomic(alloc, hooks_path, hooks_text);
    }

    var runtime = try runtime_lifecycle.UserHooksRuntime.init(alloc, .{ .enabled = true, .home = home, .workspace_root = workspace });
    defer runtime.deinit();
    runtime.refresh();

    var lifecycle = testLifecycle(kind);
    lifecycle.user_hooks = &runtime;
    lifecycle.trust_required = trust_required;
    lifecycle.scope.session_id = "session-trust-notice";
    lifecycle.scope.workspace_root = workspace;

    var deps: AgentRuntimeDeps = undefined;
    deps.ctx = capture;
    deps.push_system_notice = NoticeCapture.pushSystem;
    deps.push_hook_notice = NoticeCapture.pushHook;
    var turn = TurnHooks.init(lifecycle, &deps, 1, null);
    for (0..turns) |_| turn.sessionStart(arena, false);
}

test "the first interactive turn tells the person once that one hook waits for trust" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    var capture = NoticeCapture{};
    try sessionStartsWithHooks(alloc, arena_state.allocator(), &capture, guard_hooks_text, true, .interactive, 2);
    try std.testing.expectEqual(@as(usize, 1), capture.hook_count);
    try std.testing.expectEqual(deps_mod.HookNoticeTone.neutral, capture.tones[0]);
    try std.testing.expectEqualStrings(
        "1 hook waits for trust and does not run. Run /hook list to review it.",
        capture.hook_texts[0],
    );
    try std.testing.expectEqual(@as(usize, 0), capture.system_count);
}

test "the trust notice counts several hooks in the plural" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    var capture = NoticeCapture{};
    try sessionStartsWithHooks(alloc, arena_state.allocator(), &capture, two_hooks_text, true, .interactive, 1);
    try std.testing.expectEqual(@as(usize, 1), capture.hook_count);
    try std.testing.expectEqualStrings(
        "2 hooks wait for trust and do not run. Run /hook list to review them.",
        capture.hook_texts[0],
    );
}

test "the trust notice stays silent without trust, off the interactive shell, or with no hook waiting" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var without_trust = NoticeCapture{};
    try sessionStartsWithHooks(alloc, arena, &without_trust, guard_hooks_text, false, .interactive, 1);
    try std.testing.expectEqual(@as(usize, 0), without_trust.hook_count);

    var subagent = NoticeCapture{};
    try sessionStartsWithHooks(alloc, arena, &subagent, guard_hooks_text, true, .subagent, 1);
    try std.testing.expectEqual(@as(usize, 0), subagent.hook_count);

    var nothing_waiting = NoticeCapture{};
    try sessionStartsWithHooks(alloc, arena, &nothing_waiting, "", true, .interactive, 1);
    try std.testing.expectEqual(@as(usize, 0), nothing_waiting.hook_count);
}

test "a rise in the waiting count is told again mid-session, and a fall is not" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/.fx");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const hooks_path = try std.Io.Dir.path.join(alloc, &.{ workspace, ".fx", "hooks.json" });
    defer alloc.free(hooks_path);
    try io_mod.writeFileAtomic(alloc, hooks_path, guard_hooks_text);

    var runtime = try runtime_lifecycle.UserHooksRuntime.init(alloc, .{ .enabled = true, .home = home, .workspace_root = workspace });
    defer runtime.deinit();
    runtime.refresh();

    var lifecycle = testLifecycle(.interactive);
    lifecycle.user_hooks = &runtime;
    lifecycle.trust_required = true;
    lifecycle.scope.session_id = "session-trust-rise";
    lifecycle.scope.workspace_root = workspace;

    var capture = NoticeCapture{};
    var deps: AgentRuntimeDeps = undefined;
    deps.ctx = &capture;
    deps.push_system_notice = NoticeCapture.pushSystem;
    deps.push_hook_notice = NoticeCapture.pushHook;
    var turn = TurnHooks.init(lifecycle, &deps, 1, null);

    // The first turn tells the singular once; a repeat turn with the same count tells nothing.
    turn.sessionStart(arena, false);
    turn.sessionStart(arena, false);
    try std.testing.expectEqual(@as(usize, 1), capture.hook_count);
    try std.testing.expectEqualStrings(
        "1 hook waits for trust and does not run. Run /hook list to review it.",
        capture.hook_texts[0],
    );

    // The hook files reload with a second waiting hook: the count rises, so the plural is told once.
    try io_mod.writeFileAtomic(alloc, hooks_path, two_hooks_text);
    runtime.refresh();
    turn.sessionStart(arena, false);
    turn.sessionStart(arena, false);
    try std.testing.expectEqual(@as(usize, 2), capture.hook_count);
    try std.testing.expectEqualStrings(
        "2 hooks wait for trust and do not run. Run /hook list to review them.",
        capture.hook_texts[1],
    );

    // The count falls to one (a person trusted a hook, say): nothing is told. Back to two, it is told again.
    try io_mod.writeFileAtomic(alloc, hooks_path, guard_hooks_text);
    runtime.refresh();
    turn.sessionStart(arena, false);
    try std.testing.expectEqual(@as(usize, 2), capture.hook_count);

    try io_mod.writeFileAtomic(alloc, hooks_path, two_hooks_text);
    runtime.refresh();
    turn.sessionStart(arena, false);
    try std.testing.expectEqual(@as(usize, 3), capture.hook_count);
    try std.testing.expectEqualStrings(
        "2 hooks wait for trust and do not run. Run /hook list to review them.",
        capture.hook_texts[2],
    );
}

test "the scope carries the turn's data" {
    const turn = TurnHooks{
        .deps = undefined,
        .runtime = null,
        .trust_required = false,
        .surface = .subagent,
        .session_id = "s1",
        .subagent_id = 7,
        .workspace_root = "/workspace",
        .turn_id = 9,
        .cancel = null,
    };

    const scope = turn.scope(.auto);
    try std.testing.expectEqual(hooks_engine.Surface.subagent, scope.surface);
    try std.testing.expectEqualStrings("s1", scope.session_id.?);
    try std.testing.expectEqual(@as(?u64, 9), scope.turn_id);
    try std.testing.expectEqual(@as(?u64, 7), scope.subagent_id);
    try std.testing.expectEqualStrings("/workspace", scope.cwd);
    try std.testing.expectEqualStrings("/workspace", scope.project_dir);
    try std.testing.expectEqualStrings("auto", scope.permission_mode);
    try std.testing.expect(scope.transcript_path == null);
}

const deny_file =
    \\{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"printf '%s' '{\"hookSpecificOutput\":{\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"no rm\"}}'"}]}]}}
;

const allow_file =
    \\{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"printf '%s' '{\"hookSpecificOutput\":{\"permissionDecision\":\"allow\",\"updatedInput\":{\"command\":\"pwd\"}}}'"}]}]}}
;

const stop_file =
    \\{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"printf '%s' '{\"continue\":false,\"stopReason\":\"done\"}'"}]}]}}
;

const context_file =
    \\{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"printf '%s' '{\"hookSpecificOutput\":{\"additionalContext\":\"use rg\"}}'"}]}]}}
;

const permission_allow_file =
    \\{"hooks":{"PermissionRequest":[{"matcher":"*","hooks":[{"type":"command","command":"printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"allow\"}}}'"}]}]}}
;

const permission_deny_file =
    \\{"hooks":{"PermissionRequest":[{"matcher":"*","hooks":[{"type":"command","command":"printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"deny\",\"message\":\"not here\"}}}'"}]}]}}
;

const permission_retry_file =
    \\{"hooks":{"PermissionDenied":[{"matcher":"*","hooks":[{"type":"command","command":"printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionDenied\",\"retry\":true}}'"}]}]}}
;

/// A PermissionDenied hook that touches `marker`, then answers retry. A file
/// appears only when the hook actually ran.
fn permissionDeniedMarkerFile(arena: std.mem.Allocator, marker: []const u8) ![]u8 {
    return arena.print(
        "{{\"hooks\":{{\"PermissionDenied\":[{{\"matcher\":\"*\",\"hooks\":[{{\"type\":\"command\",\"command\":\"touch '{s}'; printf '%s' '{{\\\"hookSpecificOutput\\\":{{\\\"hookEventName\\\":\\\"PermissionDenied\\\",\\\"retry\\\":true}}}}'\"}}]}}]}}}}",
        .{marker},
    );
}

const post_tool_redact_file =
    \\{"hooks":{"PostToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"updatedToolOutput\":\"redacted\"}}'"}]}]}}
;

const post_tool_context_file =
    \\{"hooks":{"PostToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"additionalContext\":\"check the log\"}}'"}]}]}}
;

const post_tool_failure_stop_file =
    \\{"hooks":{"PostToolUseFailure":[{"matcher":"*","hooks":[{"type":"command","command":"printf '%s' '{\"continue\":false,\"stopReason\":\"tool broke\"}'"}]}]}}
;

/// A PostToolUseFailure hook that touches `marker`, then adds a context note.
fn postToolFailureMarkerFile(arena: std.mem.Allocator, marker: []const u8) ![]u8 {
    return arena.print(
        "{{\"hooks\":{{\"PostToolUseFailure\":[{{\"matcher\":\"*\",\"hooks\":[{{\"type\":\"command\",\"command\":\"touch '{s}'; printf '%s' '{{\\\"hookSpecificOutput\\\":{{\\\"hookEventName\\\":\\\"PostToolUseFailure\\\",\\\"additionalContext\\\":\\\"ran\\\"}}}}'\"}}]}}]}}}}",
        .{marker},
    );
}

/// A PostToolBatch hook that copies its input to `path`, then adds a context note.
fn postToolBatchCopyFile(arena: std.mem.Allocator, path: []const u8) ![]u8 {
    return arena.print(
        "{{\"hooks\":{{\"PostToolBatch\":[{{\"hooks\":[{{\"type\":\"command\",\"command\":\"cat > '{s}'; printf '%s' '{{\\\"hookSpecificOutput\\\":{{\\\"hookEventName\\\":\\\"PostToolBatch\\\",\\\"additionalContext\\\":\\\"batch checked\\\"}}}}'\"}}]}}]}}}}",
        .{path},
    );
}

const post_batch_stop_file =
    \\{"hooks":{"PostToolBatch":[{"hooks":[{"type":"command","command":"printf '%s' '{\"continue\":false,\"stopReason\":\"enough\"}'"}]}]}}
;

/// A PostToolBatch hook that touches `marker` and answers nothing.
fn postToolBatchMarkerFile(arena: std.mem.Allocator, marker: []const u8) ![]u8 {
    return arena.print(
        "{{\"hooks\":{{\"PostToolBatch\":[{{\"hooks\":[{{\"type\":\"command\",\"command\":\"touch '{s}'; printf '%s' '{{}}'\"}}]}}]}}}}",
        .{marker},
    );
}

const HookFixtures = struct {
    tmp: std.testing.TmpDir,
    home: []u8,
    workspace: []u8,
    env: std.process.Environ.Map,

    fn init(alloc: std.mem.Allocator) !HookFixtures {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
        try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
        const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
        errdefer alloc.free(home);
        const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
        errdefer alloc.free(workspace);
        var env = std.process.Environ.Map.init(alloc);
        errdefer env.deinit();
        try env.put("PATH", "/usr/bin:/bin");
        return .{ .tmp = tmp, .home = home, .workspace = workspace, .env = env };
    }

    fn deinit(self: *HookFixtures, alloc: std.mem.Allocator) void {
        alloc.free(self.home);
        alloc.free(self.workspace);
        self.env.deinit();
        self.tmp.cleanup();
        self.* = undefined;
    }
};

fn writeHookFile(alloc: std.mem.Allocator, fixture: *const HookFixtures, text: []const u8) !void {
    const file_path = try profile_paths.rootPath(alloc, fixture.home, &.{"hooks.json"});
    defer alloc.free(file_path);
    try io_mod.writeFileAtomic(alloc, file_path, text);
    try std.Io.Dir.cwd().setFilePermissions(io_mod.getIo(), file_path, std.Io.File.Permissions.fromMode(0o600), .{});
}

fn startRuntime(alloc: std.mem.Allocator, fixture: *HookFixtures) !runtime_lifecycle.UserHooksRuntime {
    var runtime = try runtime_lifecycle.UserHooksRuntime.init(alloc, .{
        .enabled = true,
        .home = fixture.home,
        .workspace_root = fixture.workspace,
    });
    runtime.native.base_env = &fixture.env;
    runtime.refresh();
    return runtime;
}

/// Deps for tests that do not check notices: both notice sinks take a notice and drop it.
var ignoring_notice_deps: AgentRuntimeDeps = undefined;
var ignoring_notice_ctx: u8 = 0;

fn ignoreHookNoticeForTest(_: *anyopaque, _: deps_mod.HookNoticeTone, _: []const u8) anyerror!void {}
fn ignoreSystemNoticeForTest(_: *anyopaque, _: []const u8) anyerror!void {}

fn ignoringNoticeDeps() *const AgentRuntimeDeps {
    ignoring_notice_deps.ctx = &ignoring_notice_ctx;
    ignoring_notice_deps.push_system_notice = ignoreSystemNoticeForTest;
    ignoring_notice_deps.push_hook_notice = ignoreHookNoticeForTest;
    return &ignoring_notice_deps;
}

fn hookTurn(runtime: *runtime_lifecycle.UserHooksRuntime, workspace: []const u8, arena: std.mem.Allocator) TurnHooks {
    return hookTurnWithDeps(runtime, workspace, arena, ignoringNoticeDeps());
}

fn hookTurnWithDeps(
    runtime: *runtime_lifecycle.UserHooksRuntime,
    workspace: []const u8,
    arena: std.mem.Allocator,
    deps: *const AgentRuntimeDeps,
) TurnHooks {
    return TurnHooks.init(.{
        .view = old_hooks.RuntimeView.empty(),
        .scope = .{ .kind = .interactive, .workspace_root = workspace },
        .outcome_allocator = arena,
        .user_hooks = runtime,
        .trust_required = false,
    }, deps, 1, null);
}

fn readyCall() runtime_lifecycle.PreparedToolCall {
    return .{ .ready = .{
        .id = "call-1",
        .name = "shell",
        .arguments_json = "{\"command\":\"rm -rf /\"}",
    } };
}

test "hook context is framed for the model" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "<hook-context event=\"PreToolUse\" tool=\"shell\">\nuse rg\n</hook-context>",
        try frameContext(arena, "PreToolUse", "shell", "use rg"),
    );
    try std.testing.expectEqualStrings(
        "<hook-context event=\"Stop\">\ngo\n</hook-context>",
        try frameContext(arena, "Stop", null, "go"),
    );
}

test "a toolbox run takes the rewritten arguments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rewritten = try toolboxWithArguments(arena, "{\"run\":\"shell\",\"arguments\":{\"command\":\"ls\"}}", "{\"command\":\"pwd\"}");
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, rewritten, .{});
    try std.testing.expectEqualStrings("shell", parsed.object.get("run").?.string);
    try std.testing.expectEqualStrings("pwd", parsed.object.get("arguments").?.object.get("command").?.string);

    const replaced = try toolboxWithArguments(arena, "{\"run\":\"shell\",\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"}", "{\"command\":\"pwd\"}");
    const replaced_value = try std.json.parseFromSliceLeaky(std.json.Value, arena, replaced, .{});
    try std.testing.expectEqualStrings("pwd", replaced_value.object.get("arguments").?.object.get("command").?.string);

    const untouched = "not json";
    try std.testing.expectEqualStrings(untouched, try toolboxWithArguments(arena, untouched, "{\"command\":\"pwd\"}"));
}

test "PreToolUse applies deny, allow, stop, and context" {
    const alloc = std.testing.allocator;
    var fixture = try HookFixtures.init(alloc);
    defer fixture.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var runtime = try startRuntime(alloc, &fixture);
    defer runtime.deinit();
    var capture = NoticeCapture{};
    var deps: AgentRuntimeDeps = undefined;
    deps.ctx = &capture;
    deps.push_system_notice = NoticeCapture.pushSystem;
    deps.push_hook_notice = NoticeCapture.pushHook;
    var turn = hookTurnWithDeps(&runtime, fixture.workspace, arena, &deps);

    try writeHookFile(alloc, &fixture, deny_file);
    runtime.refresh();
    var denied_call = readyCall();
    var denied_subject: ?types.ToolCall = null;
    const denied = try turn.preToolUse(arena, .auto, &denied_call, &denied_subject);
    switch (denied_call) {
        .blocked => |blocked| try std.testing.expectEqual(runtime_lifecycle.PreparedToolBlockKind.lifecycle_block, blocked.kind),
        else => return error.ExpectedBlocked,
    }
    try std.testing.expect(denied_subject == null);
    try std.testing.expectEqual(PermissionHint.none, denied.permission);
    // The person sees which hook blocked which tool, and why.
    try std.testing.expectEqual(@as(usize, 1), capture.hook_count);
    try std.testing.expectEqual(deps_mod.HookNoticeTone.warning, capture.tones[0]);
    try std.testing.expect(std.mem.startsWith(u8, capture.hook_texts[0], "Hook "));
    try std.testing.expect(std.mem.endsWith(u8, capture.hook_texts[0], " blocked shell: no rm"));

    try writeHookFile(alloc, &fixture, allow_file);
    runtime.refresh();
    var allowed_call = readyCall();
    var allowed_subject: ?types.ToolCall = null;
    const allowed = try turn.preToolUse(arena, .auto, &allowed_call, &allowed_subject);
    try std.testing.expectEqual(PermissionHint.allow, allowed.permission);
    const rewritten = try std.json.parseFromSliceLeaky(std.json.Value, arena, allowed_call.ready.arguments_json, .{});
    try std.testing.expectEqualStrings("pwd", rewritten.object.get("command").?.string);
    try std.testing.expectEqual(types.ToolArgumentIntegrity.valid, allowed_call.ready.argument_integrity);

    try writeHookFile(alloc, &fixture, stop_file);
    runtime.refresh();
    var stopped_call = readyCall();
    var stopped_subject: ?types.ToolCall = null;
    const stopped = try turn.preToolUse(arena, .auto, &stopped_call, &stopped_subject);
    switch (stopped_call) {
        .blocked => {},
        else => return error.ExpectedBlocked,
    }
    try std.testing.expectEqualStrings("done", stopped.stop_reason.?);

    try writeHookFile(alloc, &fixture, context_file);
    runtime.refresh();
    var context_call = readyCall();
    var context_subject: ?types.ToolCall = null;
    _ = try turn.preToolUse(arena, .auto, &context_call, &context_subject);
    try std.testing.expectEqual(@as(usize, 1), turn.pending_notes.items.len);
    try std.testing.expectEqualStrings(
        "<hook-context event=\"PreToolUse\" tool=\"shell\">\nuse rg\n</hook-context>",
        turn.pending_notes.items[0],
    );
}

test "a PermissionRequest hook allow answers the prompt" {
    const alloc = std.testing.allocator;
    var fixture = try HookFixtures.init(alloc);
    defer fixture.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var runtime = try startRuntime(alloc, &fixture);
    defer runtime.deinit();
    var turn = hookTurn(&runtime, fixture.workspace, arena);
    try writeHookFile(alloc, &fixture, permission_allow_file);
    runtime.refresh();

    const hook = turn.permissionRequestHook() orelse return error.ExpectedHook;
    const call = types.ToolCall{ .id = "call-1", .name = "shell", .arguments_json = "{\"command\":\"rm -rf /\"}" };
    const verdict = hook.run(hook.context, arena, call, "shell: rm -rf /") orelse return error.ExpectedVerdict;
    switch (verdict) {
        .allow => {},
        .deny => return error.ExpectedAllow,
    }
}

test "a PermissionRequest hook deny carries its message" {
    const alloc = std.testing.allocator;
    var fixture = try HookFixtures.init(alloc);
    defer fixture.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var runtime = try startRuntime(alloc, &fixture);
    defer runtime.deinit();
    var turn = hookTurn(&runtime, fixture.workspace, arena);
    try writeHookFile(alloc, &fixture, permission_deny_file);
    runtime.refresh();

    const hook = turn.permissionRequestHook() orelse return error.ExpectedHook;
    const call = types.ToolCall{ .id = "call-1", .name = "shell", .arguments_json = "{\"command\":\"rm -rf /\"}" };
    const verdict = hook.run(hook.context, arena, call, "shell: rm -rf /") orelse return error.ExpectedVerdict;
    switch (verdict) {
        .allow => return error.ExpectedDeny,
        .deny => |reason| try std.testing.expectEqualStrings("not here", reason),
    }
}

test "a turn with no PermissionRequest hook gives no verdict" {
    const alloc = std.testing.allocator;
    var fixture = try HookFixtures.init(alloc);
    defer fixture.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var runtime = try startRuntime(alloc, &fixture);
    defer runtime.deinit();
    var turn = hookTurn(&runtime, fixture.workspace, arena);
    try writeHookFile(alloc, &fixture, deny_file);
    runtime.refresh();

    const hook = turn.permissionRequestHook() orelse return error.ExpectedHook;
    const call = types.ToolCall{ .id = "call-1", .name = "shell", .arguments_json = "{\"command\":\"rm -rf /\"}" };
    try std.testing.expect(hook.run(hook.context, arena, call, "shell: rm -rf /") == null);
}

test "a PermissionDenied hook that answers retry allows one more try" {
    const alloc = std.testing.allocator;
    var fixture = try HookFixtures.init(alloc);
    defer fixture.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var runtime = try startRuntime(alloc, &fixture);
    defer runtime.deinit();
    var turn = hookTurn(&runtime, fixture.workspace, arena);
    try writeHookFile(alloc, &fixture, permission_retry_file);
    runtime.refresh();

    const call = types.ToolCall{ .id = "call-1", .name = "shell", .arguments_json = "{\"command\":\"rm -rf /\"}" };
    try std.testing.expect(turn.permissionDenied(arena, call, "auto_denied"));
    try std.testing.expectEqual(@as(u8, 1), turn.denied_retries);
}

test "a PermissionDenied retry stops after the turn's cap" {
    const alloc = std.testing.allocator;
    var fixture = try HookFixtures.init(alloc);
    defer fixture.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var runtime = try startRuntime(alloc, &fixture);
    defer runtime.deinit();
    var turn = hookTurn(&runtime, fixture.workspace, arena);
    const call = types.ToolCall{ .id = "call-1", .name = "shell", .arguments_json = "{\"command\":\"rm -rf /\"}" };

    // Control: the hook runs below the cap, so its marker file appears.
    const first_marker = try std.Io.Dir.path.join(arena, &.{ fixture.workspace, "first.txt" });
    try writeHookFile(alloc, &fixture, try permissionDeniedMarkerFile(arena, first_marker));
    runtime.refresh();
    try std.testing.expect(turn.permissionDenied(arena, call, "auto_denied"));
    var first = try fixture.tmp.dir.openFile(io_mod.getIo(), "workspace/first.txt", .{});
    first.close(io_mod.getIo());

    // At the cap, the same hook must not run, so its marker file never appears.
    turn.denied_retries = max_denied_retries;
    const capped_marker = try std.Io.Dir.path.join(arena, &.{ fixture.workspace, "capped.txt" });
    try writeHookFile(alloc, &fixture, try permissionDeniedMarkerFile(arena, capped_marker));
    runtime.refresh();
    try std.testing.expect(!turn.permissionDenied(arena, call, "auto_denied"));
    try std.testing.expectError(
        error.FileNotFound,
        fixture.tmp.dir.openFile(io_mod.getIo(), "workspace/capped.txt", .{}),
    );
}

test "a turn with no PermissionDenied hook keeps the denial" {
    const alloc = std.testing.allocator;
    var fixture = try HookFixtures.init(alloc);
    defer fixture.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var runtime = try startRuntime(alloc, &fixture);
    defer runtime.deinit();
    var turn = hookTurn(&runtime, fixture.workspace, arena);
    try writeHookFile(alloc, &fixture, deny_file);
    runtime.refresh();

    const call = types.ToolCall{ .id = "call-1", .name = "shell", .arguments_json = "{\"command\":\"rm -rf /\"}" };
    try std.testing.expect(!turn.permissionDenied(arena, call, "auto_denied"));
    try std.testing.expectEqual(@as(u8, 0), turn.denied_retries);
}

test "the PermissionDenied retry note is framed for the model" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "<hook-context event=\"PermissionDenied\" tool=\"shell\">\nA user hook allows one retry of this denied call. Try it again only if a change makes it safe.\n</hook-context>",
        try deniedRetryNote(arena, "shell"),
    );
}

/// A PostToolUse hook that answers with `replacement` as its updated tool output. The answer sits in
/// a file the hook prints, so the replacement needs no shell quoting.
fn postToolReplaceFile(arena: std.mem.Allocator, fixture: *const HookFixtures, replacement: []const u8) ![]u8 {
    const answer_path = try arena.print("{s}/replacement.json", .{fixture.workspace});
    const answer = try arena.print(
        "{{\"hookSpecificOutput\":{{\"hookEventName\":\"PostToolUse\",\"updatedToolOutput\":\"{s}\"}}}}",
        .{replacement},
    );
    try io_mod.writeFileAtomic(arena, answer_path, answer);
    return arena.print(
        "{{\"hooks\":{{\"PostToolUse\":[{{\"matcher\":\"*\",\"hooks\":[{{\"type\":\"command\",\"command\":\"cat '{s}'\"}}]}}]}}}}",
        .{answer_path},
    );
}

test "a PostToolUse replacement longer than the tool result limit is cut like a tool's output and noticed once" {
    const alloc = std.testing.allocator;
    var fixture = try HookFixtures.init(alloc);
    defer fixture.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const long = try arena.alloc(u8, 300);
    @memset(long, 'x');
    var runtime = try startRuntime(alloc, &fixture);
    defer runtime.deinit();
    try writeHookFile(alloc, &fixture, try postToolReplaceFile(arena, &fixture, long));
    runtime.refresh();

    var capture = NoticeCapture{};
    var deps: AgentRuntimeDeps = undefined;
    deps.ctx = &capture;
    deps.push_system_notice = NoticeCapture.pushSystem;
    deps.push_hook_notice = NoticeCapture.pushHook;
    var turn = hookTurnWithDeps(&runtime, fixture.workspace, arena, &deps);
    turn.max_tool_result_bytes = 200;

    var batch = runtime_tool_batch.StepBatchState{};
    const call = types.ToolCall{ .id = "call-1", .name = "shell", .arguments_json = "{\"command\":\"ls\"}" };
    const applied = turn.postToolResult(arena, &batch, call, "short", true);
    try std.testing.expect(applied.replaced);
    try std.testing.expect(applied.output.len <= 200);
    try std.testing.expect(std.mem.find(u8, applied.output, "\n... [tool result truncated for shell: original 300 bytes; cap is 200 bytes]\n") != null);
    try std.testing.expectEqual(@as(usize, 1), capture.hook_count);
    try std.testing.expectEqual(deps_mod.HookNoticeTone.neutral, capture.tones[0]);
    try std.testing.expectEqualStrings("Hook output for shell was cut to 200 bytes, the tool result limit", capture.hook_texts[0]);
}

test "a PostToolUse replacement within the tool result limit is kept as it is, with no notice" {
    const alloc = std.testing.allocator;
    var fixture = try HookFixtures.init(alloc);
    defer fixture.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var runtime = try startRuntime(alloc, &fixture);
    defer runtime.deinit();
    try writeHookFile(alloc, &fixture, try postToolReplaceFile(arena, &fixture, "redacted"));
    runtime.refresh();

    var capture = NoticeCapture{};
    var deps: AgentRuntimeDeps = undefined;
    deps.ctx = &capture;
    deps.push_system_notice = NoticeCapture.pushSystem;
    deps.push_hook_notice = NoticeCapture.pushHook;
    var turn = hookTurnWithDeps(&runtime, fixture.workspace, arena, &deps);
    turn.max_tool_result_bytes = 200;

    var batch = runtime_tool_batch.StepBatchState{};
    const call = types.ToolCall{ .id = "call-1", .name = "shell", .arguments_json = "{\"command\":\"ls\"}" };
    const applied = turn.postToolResult(arena, &batch, call, "API_KEY=secret", true);
    try std.testing.expect(applied.replaced);
    try std.testing.expectEqualStrings("redacted", applied.output);
    try std.testing.expectEqual(@as(usize, 0), capture.hook_count);
}

test "a PostToolUse hook replaces the output the model reads" {
    const alloc = std.testing.allocator;
    var fixture = try HookFixtures.init(alloc);
    defer fixture.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var runtime = try startRuntime(alloc, &fixture);
    defer runtime.deinit();
    var turn = hookTurn(&runtime, fixture.workspace, arena);
    try writeHookFile(alloc, &fixture, post_tool_redact_file);
    runtime.refresh();

    var batch = runtime_tool_batch.StepBatchState{};
    const call = types.ToolCall{ .id = "call-1", .name = "shell", .arguments_json = "{\"command\":\"cat .env\"}" };
    const applied = turn.postToolResult(arena, &batch, call, "API_KEY=secret", true);
    try std.testing.expect(applied.replaced);
    try std.testing.expectEqualStrings("redacted", applied.output);
}

test "a PostToolUse hook's context joins the step's results as one note" {
    const alloc = std.testing.allocator;
    var fixture = try HookFixtures.init(alloc);
    defer fixture.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var runtime = try startRuntime(alloc, &fixture);
    defer runtime.deinit();
    var turn = hookTurn(&runtime, fixture.workspace, arena);
    try writeHookFile(alloc, &fixture, post_tool_context_file);
    runtime.refresh();

    var batch = runtime_tool_batch.StepBatchState{};
    const call = types.ToolCall{ .id = "call-1", .name = "shell", .arguments_json = "{\"command\":\"ls\"}" };
    const applied = turn.postToolResult(arena, &batch, call, "ok", true);
    try std.testing.expect(!applied.replaced);
    try std.testing.expectEqualStrings("ok", applied.output);
    try std.testing.expectEqual(@as(usize, 1), batch.pending_notices.items.len);
    try std.testing.expectEqualStrings(
        "<hook-context event=\"PostToolUse\" tool=\"shell\">\ncheck the log\n</hook-context>",
        batch.pending_notices.items[0].content.?,
    );
}

test "a PostToolUseFailure hook's stop request ends the turn after the step" {
    const alloc = std.testing.allocator;
    var fixture = try HookFixtures.init(alloc);
    defer fixture.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var runtime = try startRuntime(alloc, &fixture);
    defer runtime.deinit();
    var turn = hookTurn(&runtime, fixture.workspace, arena);
    try writeHookFile(alloc, &fixture, post_tool_failure_stop_file);
    runtime.refresh();

    var batch = runtime_tool_batch.StepBatchState{};
    const call = types.ToolCall{ .id = "call-1", .name = "shell", .arguments_json = "{\"command\":\"make\"}" };
    _ = turn.postToolResult(arena, &batch, call, "make: error", false);
    try std.testing.expectEqualStrings("tool broke", batch.stop_reason.?);
}

test "a PostToolUseFailure hook does not run for a successful result" {
    const alloc = std.testing.allocator;
    var fixture = try HookFixtures.init(alloc);
    defer fixture.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var runtime = try startRuntime(alloc, &fixture);
    defer runtime.deinit();
    var turn = hookTurn(&runtime, fixture.workspace, arena);
    var batch = runtime_tool_batch.StepBatchState{};
    const call = types.ToolCall{ .id = "call-1", .name = "shell", .arguments_json = "{\"command\":\"ls\"}" };

    // Control: a failed result runs the hook, so its marker file appears.
    const failure_marker = try std.Io.Dir.path.join(arena, &.{ fixture.workspace, "failure.txt" });
    try writeHookFile(alloc, &fixture, try postToolFailureMarkerFile(arena, failure_marker));
    runtime.refresh();
    _ = turn.postToolResult(arena, &batch, call, "boom", false);
    var failure_file = try fixture.tmp.dir.openFile(io_mod.getIo(), "workspace/failure.txt", .{});
    failure_file.close(io_mod.getIo());

    // A successful result must not run the failure hook, so its marker never appears.
    const success_marker = try std.Io.Dir.path.join(arena, &.{ fixture.workspace, "success.txt" });
    try writeHookFile(alloc, &fixture, try postToolFailureMarkerFile(arena, success_marker));
    runtime.refresh();
    const applied = turn.postToolResult(arena, &batch, call, "fine", true);
    try std.testing.expect(!applied.replaced);
    try std.testing.expectEqualStrings("fine", applied.output);
    try std.testing.expectError(
        error.FileNotFound,
        fixture.tmp.dir.openFile(io_mod.getIo(), "workspace/success.txt", .{}),
    );
}

test "a PostToolBatch hook sees every call of the step in order and adds one note" {
    const alloc = std.testing.allocator;
    var fixture = try HookFixtures.init(alloc);
    defer fixture.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var runtime = try startRuntime(alloc, &fixture);
    defer runtime.deinit();
    var turn = hookTurn(&runtime, fixture.workspace, arena);
    const copied_path = try std.Io.Dir.path.join(arena, &.{ fixture.workspace, "batch.json" });
    try writeHookFile(alloc, &fixture, try postToolBatchCopyFile(arena, copied_path));
    runtime.refresh();

    var batch = runtime_tool_batch.StepBatchState{};
    const calls = [_]types.ToolCall{
        .{ .id = "call-1", .name = "shell", .arguments_json = "{\"command\":\"ls\"}" },
        .{ .id = "call-2", .name = "read_file", .arguments_json = "{\"path\":\"a.txt\"}" },
    };
    turn.postToolBatch(arena, &batch, &calls);

    try std.testing.expectEqual(@as(usize, 1), batch.pending_notices.items.len);
    try std.testing.expectEqualStrings(
        "<hook-context event=\"PostToolBatch\">\nbatch checked\n</hook-context>",
        batch.pending_notices.items[0].content.?,
    );

    var copied = try fixture.tmp.dir.openFile(io_mod.getIo(), "workspace/batch.json", .{});
    defer copied.close(io_mod.getIo());
    const input = try io_mod.readFileToEnd(alloc, &copied, 65536);
    defer alloc.free(input);
    try std.testing.expect(std.mem.find(u8, input, "\"tool_calls\":[") != null);
    const shell_at = std.mem.find(u8, input, "\"tool_name\":\"shell\"") orelse return error.MissingShellCall;
    const read_at = std.mem.find(u8, input, "\"tool_name\":\"read_file\"") orelse return error.MissingReadCall;
    try std.testing.expect(shell_at < read_at);
}

test "a SubagentStart hook gets the subagent id once, as agent_id" {
    const alloc = std.testing.allocator;
    var fixture = try HookFixtures.init(alloc);
    defer fixture.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var runtime = try startRuntime(alloc, &fixture);
    defer runtime.deinit();
    const copied_path = try std.Io.Dir.path.join(arena, &.{ fixture.workspace, "subagent-start.json" });
    try writeHookFile(alloc, &fixture, try arena.print(
        "{{\"hooks\":{{\"SubagentStart\":[{{\"hooks\":[{{\"type\":\"command\",\"command\":\"cat > '{s}'\"}}]}}]}}}}",
        .{copied_path},
    ));
    runtime.refresh();

    var turn = TurnHooks.init(.{
        .view = old_hooks.RuntimeView.empty(),
        .scope = .{
            .kind = .subagent,
            .workspace_root = fixture.workspace,
            .session_id = "child-1",
            .subagent_id = 3,
        },
        .outcome_allocator = arena,
        .user_hooks = &runtime,
        .trust_required = false,
    }, ignoringNoticeDeps(), 1, null);
    turn.sessionStart(arena, false);

    var copied = try fixture.tmp.dir.openFile(io_mod.getIo(), "workspace/subagent-start.json", .{});
    defer copied.close(io_mod.getIo());
    const input = try io_mod.readFileToEnd(alloc, &copied, 65536);
    defer alloc.free(input);
    try std.testing.expect(std.mem.find(u8, input, "\"hook_event_name\":\"SubagentStart\"") != null);
    try std.testing.expect(std.mem.find(u8, input, "\"agent_id\":\"3\"") != null);

    var count: usize = 0;
    var rest: []const u8 = input;
    while (std.mem.find(u8, rest, "\"agent_id\"")) |at| {
        count += 1;
        rest = rest[at + "\"agent_id\"".len ..];
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "a PostToolBatch hook's stop request ends the turn after the step" {
    const alloc = std.testing.allocator;
    var fixture = try HookFixtures.init(alloc);
    defer fixture.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var runtime = try startRuntime(alloc, &fixture);
    defer runtime.deinit();
    var turn = hookTurn(&runtime, fixture.workspace, arena);
    try writeHookFile(alloc, &fixture, post_batch_stop_file);
    runtime.refresh();

    var batch = runtime_tool_batch.StepBatchState{};
    const calls = [_]types.ToolCall{
        .{ .id = "call-1", .name = "shell", .arguments_json = "{\"command\":\"ls\"}" },
    };
    turn.postToolBatch(arena, &batch, &calls);
    try std.testing.expectEqualStrings("enough", batch.stop_reason.?);
}

test "a PostToolBatch hook does not run for a step with no calls" {
    const alloc = std.testing.allocator;
    var fixture = try HookFixtures.init(alloc);
    defer fixture.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var runtime = try startRuntime(alloc, &fixture);
    defer runtime.deinit();
    var turn = hookTurn(&runtime, fixture.workspace, arena);
    var batch = runtime_tool_batch.StepBatchState{};
    const calls = [_]types.ToolCall{
        .{ .id = "call-1", .name = "shell", .arguments_json = "{\"command\":\"ls\"}" },
    };

    // Control: a step with calls runs the hook, so its marker file appears.
    const with_calls = try std.Io.Dir.path.join(arena, &.{ fixture.workspace, "with-calls.txt" });
    try writeHookFile(alloc, &fixture, try postToolBatchMarkerFile(arena, with_calls));
    runtime.refresh();
    turn.postToolBatch(arena, &batch, &calls);
    var with_calls_file = try fixture.tmp.dir.openFile(io_mod.getIo(), "workspace/with-calls.txt", .{});
    with_calls_file.close(io_mod.getIo());

    // A step with no calls must not run the hook, so its marker file never appears.
    const no_calls = try std.Io.Dir.path.join(arena, &.{ fixture.workspace, "no-calls.txt" });
    try writeHookFile(alloc, &fixture, try postToolBatchMarkerFile(arena, no_calls));
    runtime.refresh();
    turn.postToolBatch(arena, &batch, &.{});
    try std.testing.expectError(
        error.FileNotFound,
        fixture.tmp.dir.openFile(io_mod.getIo(), "workspace/no-calls.txt", .{}),
    );
}

test "a notice reads as one system line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const message = hooks_engine.answer.Notice{
        .kind = .message,
        .hook_id = @constCast("guard"),
        .text = @constCast("remember the style guide"),
    };
    try std.testing.expectEqualStrings("Hook guard: remember the style guide", try noticeText(arena, message));

    const failure = hooks_engine.answer.Notice{
        .kind = .failure,
        .hook_id = @constCast("slow"),
        .text = @constCast("slow failed: timed out"),
    };
    try std.testing.expectEqualStrings("Hook slow failed: timed out", try noticeText(arena, failure));
}

test "a session start context at the text limit keeps its closing tag" {
    const alloc = std.testing.allocator;
    var fixture = try HookFixtures.init(alloc);
    defer fixture.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The hook prints as many characters as the engine keeps, so framing alone would push past the limit.
    const hooks_json =
        \\{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"yes x | head -c 10000"}]}]}}
    ;
    try writeHookFile(alloc, &fixture, hooks_json);
    var runtime = try startRuntime(alloc, &fixture);
    defer runtime.deinit();
    var turn = hookTurn(&runtime, fixture.workspace, arena);
    turn.session_id = "session-limit";

    turn.sessionStart(arena, false);
    const context = turn.sessionContext(arena) orelse return error.MissingSessionContext;
    try std.testing.expect(std.mem.startsWith(u8, context, "<hook-context event=\"SessionStart\">"));
    try std.testing.expect(std.mem.endsWith(u8, context, "</hook-context>"));
    try std.testing.expect(context.len <= hooks_engine.limits.text_chars);
}

test "a Notification hook runs in the background with its type" {
    const alloc = std.testing.allocator;
    var fixture = try HookFixtures.init(alloc);
    defer fixture.deinit(alloc);
    const out_path = try std.Io.Dir.path.join(alloc, &.{ fixture.workspace, "notification.txt" });
    defer alloc.free(out_path);
    const command = try std.mem.concat(alloc, u8, &.{ "cat > '", out_path, "'" });
    defer alloc.free(command);
    const hooks_json = try std.mem.concat(alloc, u8, &.{
        "{\"hooks\":{\"Notification\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"",
        command,
        "\"}]}]}}",
    });
    defer alloc.free(hooks_json);
    try writeHookFile(alloc, &fixture, hooks_json);
    var runtime = try startRuntime(alloc, &fixture);
    var runtime_live = true;
    defer if (runtime_live) runtime.deinit();

    const lifecycle: runtime_lifecycle.LifecycleContext = .{
        .view = old_hooks.RuntimeView.empty(),
        .scope = .{ .kind = .interactive, .workspace_root = fixture.workspace },
        .outcome_allocator = alloc,
        .user_hooks = &runtime,
        .trust_required = false,
    };
    notification(lifecycle, "permission_prompt", "fx needs your permission to continue");
    // The run is in the background. deinit cancels a background run at exit (R2.5), so wait for it first.
    runtime.waitDetached();
    runtime.deinit();
    runtime_live = false;

    var file = try fixture.tmp.dir.openFile(io_mod.getIo(), "workspace/notification.txt", .{});
    defer file.close(io_mod.getIo());
    const written = try io_mod.readFileToEnd(alloc, &file, 65536);
    defer alloc.free(written);
    try std.testing.expect(std.mem.find(u8, written, "\"notification_type\":\"permission_prompt\"") != null);
    try std.testing.expect(std.mem.find(u8, written, "fx needs your permission to continue") != null);
}

test "an InstructionsLoaded hook decides each instruction file once per session and stamp" {
    const alloc = std.testing.allocator;
    var fixture = try HookFixtures.init(alloc);
    defer fixture.deinit(alloc);
    const marker = try std.Io.Dir.path.join(alloc, &.{ fixture.workspace, "instructions.txt" });
    defer alloc.free(marker);
    const command = try std.mem.concat(alloc, u8, &.{ "echo ran >> '", marker, "'; exit 2" });
    defer alloc.free(command);
    const hooks_json = try std.mem.concat(alloc, u8, &.{
        "{\"hooks\":{\"InstructionsLoaded\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"",
        command,
        "\"}]}]}}",
    });
    defer alloc.free(hooks_json);
    try writeHookFile(alloc, &fixture, hooks_json);
    var runtime = try startRuntime(alloc, &fixture);
    defer runtime.deinit();

    const lifecycle: runtime_lifecycle.LifecycleContext = .{
        .view = old_hooks.RuntimeView.empty(),
        .scope = .{ .kind = .interactive, .workspace_root = fixture.workspace, .session_id = "session-1" },
        .outcome_allocator = alloc,
        .user_hooks = &runtime,
        .trust_required = false,
    };
    var state: InstructionFilterState = .{ .lifecycle = lifecycle };
    const filter = state.filter() orelse return error.MissingInstructionFilter;
    const path = "/workspace/sub/AGENTS.md";
    try std.testing.expect(!filter.allow(filter.context, path, .nested_traversal, 7));
    // The same path at the same stamp is answered from memory, so the hook does not run again.
    try std.testing.expect(!filter.allow(filter.context, path, .nested_traversal, 7));
    // A new stamp asks the hook again.
    try std.testing.expect(!filter.allow(filter.context, path, .nested_traversal, 8));

    var file = try fixture.tmp.dir.openFile(io_mod.getIo(), "workspace/instructions.txt", .{});
    defer file.close(io_mod.getIo());
    const written = try io_mod.readFileToEnd(alloc, &file, 65536);
    defer alloc.free(written);
    try std.testing.expectEqualStrings("ran\nran\n", written);
}

test "hook text a person reads is escaped where it is built, and the model's copy keeps its bytes" {
    const alloc = std.testing.allocator;
    var fixture = try HookFixtures.init(alloc);
    defer fixture.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The hook writes an ESC sequence to stderr, and that is its refusal reason.
    try writeHookFile(alloc, &fixture, "{\"hooks\":{\"ConfigChange\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"printf '\\\\033[31mred\\\\033[0m' >&2; exit 2\"}]}]}}");
    var runtime = try startRuntime(alloc, &fixture);
    defer runtime.deinit();
    const lifecycle: runtime_lifecycle.LifecycleContext = .{
        .view = old_hooks.RuntimeView.empty(),
        .scope = .{ .kind = .interactive, .workspace_root = fixture.workspace },
        .outcome_allocator = alloc,
        .user_hooks = &runtime,
        .trust_required = false,
    };

    // The refusal the person reads shows the sequence as text, with no raw ESC byte.
    const refusal = configChange(lifecycle, arena, "settings", "sound.max", "false", "true").refusal orelse return error.MissingRefusal;
    try std.testing.expect(std.mem.indexOfScalar(u8, refusal, 0x1b) == null);
    try std.testing.expectEqualStrings("A hook refused this setting change: \\x1b[31mred\\x1b[0m", refusal);

    // A notice from a hook escapes its id and its text where the notice is built.
    const notice = try noticeText(arena, .{ .kind = .message, .hook_id = @constCast("guard\x1b[2J"), .text = @constCast("\x1b[31mred\x1b[0m") });
    try std.testing.expect(std.mem.indexOfScalar(u8, notice, 0x1b) == null);
    try std.testing.expectEqualStrings("Hook guard\\x1b[2J: \\x1b[31mred\\x1b[0m", notice);

    // The model's copy keeps its bytes: the context a hook gives is framed, not escaped.
    const context = try frameContext(arena, "UserPromptSubmit", null, "\x1b[31mcontext");
    try std.testing.expect(std.mem.indexOfScalar(u8, context, 0x1b) != null);
}

test "terminal-safe hook text does not change when it is escaped again" {
    const alloc = std.testing.allocator;
    const samples = [_][]const u8{ "plain text", "\x1b[31mred\x1b[0m", "tab\there\x7f", "back\\slash \\x1b[0m", "\xc2\x9b31m" };
    for (samples) |raw| {
        const once = try alloc.print("{f}", .{text_utils.terminalSafe(raw)});
        defer alloc.free(once);
        const twice = try alloc.print("{f}", .{text_utils.terminalSafe(once)});
        defer alloc.free(twice);
        try std.testing.expectEqualStrings(once, twice);
    }
}

test "a ConfigChange hook refuses a setting change" {
    const alloc = std.testing.allocator;
    var fixture = try HookFixtures.init(alloc);
    defer fixture.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try writeHookFile(alloc, &fixture, "{\"hooks\":{\"ConfigChange\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"echo locked >&2; exit 2\"}]}]}}");
    var refusing = try startRuntime(alloc, &fixture);
    defer refusing.deinit();
    const refusing_lifecycle: runtime_lifecycle.LifecycleContext = .{
        .view = old_hooks.RuntimeView.empty(),
        .scope = .{ .kind = .interactive, .workspace_root = fixture.workspace },
        .outcome_allocator = alloc,
        .user_hooks = &refusing,
        .trust_required = false,
    };
    const notice = configChange(refusing_lifecycle, arena, "settings", "sound.max", "false", "true").refusal orelse return error.MissingRefusal;
    try std.testing.expectEqualStrings("A hook refused this setting change: locked", notice);

    // Without a ConfigChange hook, the same change is not refused.
    try writeHookFile(alloc, &fixture, "{}");
    var quiet = try startRuntime(alloc, &fixture);
    defer quiet.deinit();
    const quiet_lifecycle: runtime_lifecycle.LifecycleContext = .{
        .view = old_hooks.RuntimeView.empty(),
        .scope = .{ .kind = .interactive, .workspace_root = fixture.workspace },
        .outcome_allocator = alloc,
        .user_hooks = &quiet,
        .trust_required = false,
    };
    try std.testing.expect(configChange(quiet_lifecycle, arena, "settings", "sound.max", "false", "true").refusal == null);
}

test "a PreToolUse deny notice names the hook and the tool, with the reason when there is one" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("Hook guard blocked shell: no rm", try denyNoticeText(arena, "guard", "shell", "no rm"));
    try std.testing.expectEqualStrings("Hook guard blocked shell.", try denyNoticeText(arena, "guard", "shell", null));
    try std.testing.expectEqualStrings("Hook guard blocked shell.", try denyNoticeText(arena, "guard", "shell", ""));
}

test "a ConfigChange hook that fails does not refuse, and its notice names the hook" {
    const alloc = std.testing.allocator;
    var fixture = try HookFixtures.init(alloc);
    defer fixture.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try writeHookFile(alloc, &fixture, "{\"hooks\":{\"ConfigChange\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"echo broke >&2; exit 1\",\"id\":\"tuner\"}]}]}}");
    var runtime = try startRuntime(alloc, &fixture);
    defer runtime.deinit();
    const lifecycle: runtime_lifecycle.LifecycleContext = .{
        .view = old_hooks.RuntimeView.empty(),
        .scope = .{ .kind = .interactive, .workspace_root = fixture.workspace },
        .outcome_allocator = alloc,
        .user_hooks = &runtime,
        .trust_required = false,
    };
    const decision = configChange(lifecycle, arena, "settings", "sound.max", "false", "true");
    try std.testing.expect(decision.refusal == null);
    try std.testing.expectEqual(@as(usize, 1), decision.notices.len);
    try std.testing.expectEqual(deps_mod.HookNoticeTone.warning, decision.notices[0].tone);
    try std.testing.expect(std.mem.startsWith(u8, decision.notices[0].text, "Hook tuner failed"));
}

test "a PostModelSwitch hook whose context is cut gives a neutral notice" {
    const alloc = std.testing.allocator;
    var fixture = try HookFixtures.init(alloc);
    defer fixture.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try writeHookFile(alloc, &fixture, "{\"hooks\":{\"PostModelSwitch\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"yes a | head -c 10500\",\"id\":\"wide\"}]}]}}");
    var runtime = try startRuntime(alloc, &fixture);
    defer runtime.deinit();
    const lifecycle: runtime_lifecycle.LifecycleContext = .{
        .view = old_hooks.RuntimeView.empty(),
        .scope = .{ .kind = .interactive, .workspace_root = fixture.workspace, .session_id = "session-1" },
        .outcome_allocator = alloc,
        .user_hooks = &runtime,
        .trust_required = false,
    };
    const notices = postModelSwitch(lifecycle, arena, "provider/a", "provider/b");
    try std.testing.expectEqual(@as(usize, 1), notices.len);
    try std.testing.expectEqual(deps_mod.HookNoticeTone.neutral, notices[0].tone);
    try std.testing.expect(std.mem.find(u8, notices[0].text, "cut") != null);
}

test "a PreModelSwitch hook refuses a model change" {
    const alloc = std.testing.allocator;
    var fixture = try HookFixtures.init(alloc);
    defer fixture.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try writeHookFile(alloc, &fixture, "{\"hooks\":{\"PreModelSwitch\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"echo pinned >&2; exit 2\"}]}]}}");
    var runtime = try startRuntime(alloc, &fixture);
    defer runtime.deinit();
    const lifecycle: runtime_lifecycle.LifecycleContext = .{
        .view = old_hooks.RuntimeView.empty(),
        .scope = .{ .kind = .interactive, .workspace_root = fixture.workspace },
        .outcome_allocator = alloc,
        .user_hooks = &runtime,
        .trust_required = false,
    };
    const notice = preModelSwitch(lifecycle, arena, "provider/a", "provider/b").refusal orelse return error.MissingRefusal;
    try std.testing.expectEqualStrings("A hook refused the model change: pinned", notice);
}

/// Gate tests wait for a decision or a pid with a deadline, and never sleep (R7.3).
const gate_wait_ms = 5000;

/// Waits for the gate's check to finish, then takes its decision. A gate that never finishes fails the test.
fn waitForGate(gate: *HookGate) !HookGate.Result {
    const job = gate.current orelse return error.GateTimedOut;
    if (!testing_listener.waitFor(&job.done, gate_wait_ms)) return error.GateTimedOut;
    return gate.take() orelse error.GateTimedOut;
}

/// The pid a hook wrote to `signal` with `echo $$ > path`. The hook writes it before it sleeps.
fn waitForPid(signal: *hooks_host.test_signal.Signal) !std.posix.pid_t {
    var buf: [64]u8 = undefined;
    const line = signal.waitLine(&buf, gate_wait_ms) catch |err| switch (err) {
        error.Timeout => return error.HookDidNotStart,
        else => return err,
    };
    return std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, line, " \n"), 10);
}

/// Whether a process group has no members left, by the kernel's answer to signal 0.
fn groupGone(group: std.posix.pid_t) bool {
    std.posix.kill(-group, @fromBackingInt(@intCast(0))) catch |err| return err == error.ProcessNotFound;
    return false;
}

/// A ConfigChange event for a setting, as `configChange` builds it. `source` is also the match value.
fn settingEvent(fixture: *const HookFixtures, source: []const u8, fields: []const hooks_engine.Field) hooks_engine.Event {
    return .{
        .name = .config_change,
        .scope = .{ .surface = .interactive, .cwd = fixture.workspace, .project_dir = fixture.workspace, .permission_mode = "auto" },
        .match_value = source,
        .fields = fields,
    };
}

/// Trusts the one hook in `text`, as `fx hook trust` does, so a test can run it without a trust step.
fn trustOnlyHook(alloc: std.mem.Allocator, fixture: *const HookFixtures, text: []const u8) !void {
    var parsed = try hooks_engine.config.parse(alloc, text, .{ .layer = .profile, .workspace_root = fixture.workspace });
    defer parsed.deinit(alloc);
    var named = try hooks_host.trust.namedFiles(alloc, parsed.hooks[0].command, fixture.workspace, fixture.home);
    defer named.deinit(alloc);
    const value = try hooks_host.trust.digest(alloc, &parsed.hooks[0], fixture.workspace, named.files);
    var store = hooks_host.trust.Store{};
    defer store.deinit(alloc);
    try store.add(alloc, value, "gate test hook");
    const trust_file = try hooks_host.trust.path(alloc, fixture.home);
    defer alloc.free(trust_file);
    try hooks_host.trust.save(alloc, trust_file, &store);
}

fn gateLifecycle(alloc: std.mem.Allocator, fixture: *const HookFixtures, runtime: *runtime_lifecycle.UserHooksRuntime) runtime_lifecycle.LifecycleContext {
    return .{
        .view = old_hooks.RuntimeView.empty(),
        .scope = .{ .kind = .interactive, .workspace_root = fixture.workspace },
        .outcome_allocator = alloc,
        .user_hooks = runtime,
    };
}

test "a gate copies its event, so the caller may overwrite its buffers" {
    const alloc = std.testing.allocator;
    var fixture = try HookFixtures.init(alloc);
    defer fixture.deinit(alloc);
    const stdin_path = try std.Io.Dir.path.join(alloc, &.{ fixture.workspace, "hook-input.json" });
    defer alloc.free(stdin_path);
    const command = try std.mem.concat(alloc, u8, &.{ "cat > '", stdin_path, "'" });
    defer alloc.free(command);
    const text = try std.mem.concat(alloc, u8, &.{
        "{\"hooks\":{\"ConfigChange\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"",
        command,
        "\"}]}]}}",
    });
    defer alloc.free(text);
    try writeHookFile(alloc, &fixture, text);
    var runtime = try startRuntime(alloc, &fixture);
    defer runtime.deinit();
    var gate: HookGate = .{ .alloc = alloc };
    defer gate.deinit();

    // The caller's buffers are overwritten right after `start`, so the hook must get the values it was given.
    const source = try alloc.dupe(u8, "settings");
    defer alloc.free(source);
    const key = try alloc.dupe(u8, "sound.max");
    defer alloc.free(key);
    const new_value = try alloc.dupe(u8, "true");
    defer alloc.free(new_value);
    const fields = [_]hooks_engine.Field{
        .{ .key = "source", .value = .{ .string = source } },
        .{ .key = "key", .value = .{ .string = key } },
        .{ .key = "new_value", .value = .{ .string = new_value } },
    };
    try gate.start(&runtime, .setting, settingEvent(&fixture, source, &fields), false);
    @memset(source, 'x');
    @memset(key, 'x');
    @memset(new_value, 'x');

    var result = try waitForGate(&gate);
    defer result.deinit();
    try std.testing.expectEqual(HookGate.Outcome.allowed, result.outcome);
    var file = try fixture.tmp.dir.openFile(io_mod.getIo(), "workspace/hook-input.json", .{});
    defer file.close(io_mod.getIo());
    const written = try io_mod.readFileToEnd(alloc, &file, 65536);
    defer alloc.free(written);
    try std.testing.expect(std.mem.find(u8, written, "\"source\":\"settings\"") != null);
    try std.testing.expect(std.mem.find(u8, written, "\"key\":\"sound.max\"") != null);
    try std.testing.expect(std.mem.find(u8, written, "\"new_value\":\"true\"") != null);
}

test "a gate reports a refusal with its reason, and an allowing hook gives none" {
    const alloc = std.testing.allocator;
    var fixture = try HookFixtures.init(alloc);
    defer fixture.deinit(alloc);
    var gate: HookGate = .{ .alloc = alloc };
    defer gate.deinit();
    const fields = [_]hooks_engine.Field{.{ .key = "source", .value = .{ .string = "settings" } }};

    try writeHookFile(alloc, &fixture, "{\"hooks\":{\"ConfigChange\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"echo locked >&2; exit 2\"}]}]}}");
    var refusing = try startRuntime(alloc, &fixture);
    defer refusing.deinit();
    try gate.start(&refusing, .setting, settingEvent(&fixture, "settings", &fields), false);
    var refused = try waitForGate(&gate);
    defer refused.deinit();
    try std.testing.expectEqual(HookGate.Outcome.refused, refused.outcome);
    try std.testing.expectEqualStrings("A hook refused this setting change: locked", refused.refusal orelse return error.MissingRefusal);

    try writeHookFile(alloc, &fixture, "{}");
    var quiet = try startRuntime(alloc, &fixture);
    defer quiet.deinit();
    try gate.start(&quiet, .setting, settingEvent(&fixture, "settings", &fields), false);
    var allowed = try waitForGate(&gate);
    defer allowed.deinit();
    try std.testing.expectEqual(HookGate.Outcome.allowed, allowed.outcome);
    try std.testing.expect(allowed.refusal == null);
}

test "requestCancel stops the hooks, and take returns cancelled once they are gone" {
    const alloc = std.testing.allocator;
    var fixture = try HookFixtures.init(alloc);
    defer fixture.deinit(alloc);
    var pid_signal = try hooks_host.test_signal.Signal.create(alloc, fixture.workspace, "gate.pid");
    defer pid_signal.deinit(alloc);
    const command = try std.mem.concat(alloc, u8, &.{ "echo $$ > '", pid_signal.path, "'; exec sleep 30" });
    defer alloc.free(command);
    const text = try std.mem.concat(alloc, u8, &.{
        "{\"hooks\":{\"ConfigChange\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"",
        command,
        "\"}]}]}}",
    });
    defer alloc.free(text);
    try writeHookFile(alloc, &fixture, text);
    var runtime = try startRuntime(alloc, &fixture);
    defer runtime.deinit();
    var gate: HookGate = .{ .alloc = alloc };
    defer gate.deinit();
    const fields = [_]hooks_engine.Field{.{ .key = "source", .value = .{ .string = "settings" } }};

    try gate.start(&runtime, .setting, settingEvent(&fixture, "settings", &fields), false);
    const pid = try waitForPid(&pid_signal);
    try std.testing.expect(gate.requestCancel());
    var result = try waitForGate(&gate);
    defer result.deinit();
    try std.testing.expectEqual(HookGate.Outcome.cancelled, result.outcome);
    try std.testing.expect(result.refusal == null);
    try std.testing.expect(groupGone(pid));
}

test "deinit stops an open gate's hooks, so a late write never happens" {
    const alloc = std.testing.allocator;
    var fixture = try HookFixtures.init(alloc);
    defer fixture.deinit(alloc);
    var pid_signal = try hooks_host.test_signal.Signal.create(alloc, fixture.workspace, "gate.pid");
    defer pid_signal.deinit(alloc);
    // The hook writes late.txt only when its sleep ends, so the file exists only if deinit let the hook run on.
    const command = try std.mem.concat(alloc, u8, &.{ "echo $$ > '", pid_signal.path, "'; sleep 30; echo late > '", fixture.workspace, "/late.txt'" });
    defer alloc.free(command);
    const text = try std.mem.concat(alloc, u8, &.{
        "{\"hooks\":{\"ConfigChange\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"",
        command,
        "\"}]}]}}",
    });
    defer alloc.free(text);
    try writeHookFile(alloc, &fixture, text);
    var runtime = try startRuntime(alloc, &fixture);
    defer runtime.deinit();
    var gate: HookGate = .{ .alloc = alloc };
    defer gate.deinit();
    const fields = [_]hooks_engine.Field{.{ .key = "source", .value = .{ .string = "settings" } }};

    try gate.start(&runtime, .setting, settingEvent(&fixture, "settings", &fields), false);
    _ = try waitForPid(&pid_signal);
    gate.deinit();
    // The check is the late write. The group kill reaches the hook's sleep, so no write happens. Group membership
    // is not checked: a killed grandchild stays a zombie until init reaps it, so `groupGone` can read false.
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.openFile(io_mod.getIo(), "workspace/late.txt", .{}));
}

test "a second gate is refused while one is open, and the first one still finishes" {
    const alloc = std.testing.allocator;
    var fixture = try HookFixtures.init(alloc);
    defer fixture.deinit(alloc);
    try writeHookFile(alloc, &fixture, "{\"hooks\":{\"ConfigChange\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"exec sleep 30\"}]}]}}");
    var runtime = try startRuntime(alloc, &fixture);
    defer runtime.deinit();
    var gate: HookGate = .{ .alloc = alloc };
    defer gate.deinit();
    const fields = [_]hooks_engine.Field{.{ .key = "source", .value = .{ .string = "settings" } }};

    try gate.start(&runtime, .setting, settingEvent(&fixture, "settings", &fields), false);
    try std.testing.expect(gate.isOpen());
    try std.testing.expectError(error.HookGateBusy, gate.start(&runtime, .model, settingEvent(&fixture, "settings", &fields), false));

    try std.testing.expect(gate.requestCancel());
    var result = try waitForGate(&gate);
    defer result.deinit();
    try std.testing.expectEqual(HookGate.Outcome.cancelled, result.outcome);
    try std.testing.expect(!gate.isOpen());
}

test "wouldRunFor is true only for an enabled, trusted hook that listens for the event" {
    const alloc = std.testing.allocator;
    var fixture = try HookFixtures.init(alloc);
    defer fixture.deinit(alloc);
    const hook_text = "{\"hooks\":{\"ConfigChange\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"exit 0\"}]}]}}";

    try writeHookFile(alloc, &fixture, "{}");
    var none = try startRuntime(alloc, &fixture);
    defer none.deinit();
    try std.testing.expect(!wouldRunFor(gateLifecycle(alloc, &fixture, &none), .config_change, "settings"));

    // A hook that nobody trusted waits for trust, so a run would not wait for it: the change applies at once.
    try writeHookFile(alloc, &fixture, hook_text);
    var untrusted = try startRuntime(alloc, &fixture);
    defer untrusted.deinit();
    try std.testing.expect(!wouldRunFor(gateLifecycle(alloc, &fixture, &untrusted), .config_change, "settings"));

    try trustOnlyHook(alloc, &fixture, hook_text);
    var trusted = try startRuntime(alloc, &fixture);
    defer trusted.deinit();
    try std.testing.expect(wouldRunFor(gateLifecycle(alloc, &fixture, &trusted), .config_change, "settings"));
}

test "a PostModelSwitch hook's context is queued for the session's next turn only" {
    const alloc = std.testing.allocator;
    var fixture = try HookFixtures.init(alloc);
    defer fixture.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try writeHookFile(alloc, &fixture, "{\"hooks\":{\"PostModelSwitch\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"printf '%s' 'the new model is faster'\"}]}]}}");
    var runtime = try startRuntime(alloc, &fixture);
    defer runtime.deinit();
    const lifecycle: runtime_lifecycle.LifecycleContext = .{
        .view = old_hooks.RuntimeView.empty(),
        .scope = .{ .kind = .interactive, .workspace_root = fixture.workspace, .session_id = "session-1" },
        .outcome_allocator = alloc,
        .user_hooks = &runtime,
        .trust_required = false,
    };
    _ = postModelSwitch(lifecycle, arena, "provider/a", "provider/b");

    var turn = hookTurn(&runtime, fixture.workspace, arena);
    turn.session_id = "session-1";
    const notes = turn.takeSessionNotes(arena) orelse return error.MissingNotes;
    try std.testing.expect(std.mem.startsWith(u8, notes, "<hook-context event=\"PostModelSwitch\">"));
    try std.testing.expect(std.mem.find(u8, notes, "the new model is faster") != null);
    try std.testing.expect(turn.takeSessionNotes(arena) == null);
}
