const std = @import("std");
const command_admission = @import("../../permissions/command_admission.zig");
const permission_auto_classifier = @import("../../permissions/auto_classifier.zig");
const types = @import("../../shared/types.zig");
const text_utils = @import("../../shared/text_utils.zig");
const tool_dispatch = @import("../../tooling/tool_dispatch.zig");
const tool_specs = @import("../../tooling/tool_specs.zig");
const tooling_presentation = @import("../../tooling/tool_presentation.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const diff = @import("../../output/diff.zig");
const file_mutation_contract = @import("../../tooling/file_mutation_contract.zig");
const tool_result_errors = @import("../../tooling/tool_result_errors.zig");
const test_builtin_tools = if (@import("builtin").is_test)
    @import("../../../builtins/tools.zig")
else
    struct {};

const runtime_deps = @import("deps.zig");
const runtime_tool_contracts = @import("tool_contracts.zig");

const Allocator = std.mem.Allocator;
const ToolCall = types.ToolCall;
const AgentRuntimeDeps = runtime_deps.AgentRuntimeDeps;
const DiffEntryPayload = runtime_tool_contracts.DiffEntryPayload;
const ToolExecutionResult = runtime_tool_contracts.ToolExecutionResult;

pub fn isProviderSearchAlias(tool_name: []const u8) bool {
    return tooling_presentation.isProviderSearchAlias(tool_name);
}

pub fn streamStartMayHaveExecutedAtProvider(
    registry: tool_dispatch.Registry,
    tool_name: []const u8,
) bool {
    if (isProviderSearchAlias(tool_name)) return true;
    const spec = registry.lookup(tool_name) orelse return false;
    return spec.provider_executed;
}

fn fallbackToolDisplay(
    registry: tool_dispatch.Registry,
    tool_name: []const u8,
) []const u8 {
    const lookup_name = if (std.mem.eql(u8, tool_name, "run_command"))
        "terminal"
    else
        tool_name;
    return if (registry.lookup(lookup_name) != null) "tool call" else tool_name;
}

pub const ProvisionalToolStatuses = struct {
    const TrackedStatus = struct {
        id: []u8,
        tool_name: []u8,
        label_value: ?[]u8,

        fn deinit(self: *TrackedStatus, alloc: Allocator) void {
            alloc.free(self.id);
            alloc.free(self.tool_name);
            if (self.label_value) |value| alloc.free(value);
            self.* = undefined;
        }
    };

    tracked: std.ArrayList(TrackedStatus) = .empty,
    terminal_ids: std.ArrayList([]u8) = .empty,
    presentation_group_id: ?types.ToolPresentationGroupId = null,

    pub const StartPreflight = union(enum) {
        ineligible,
        eligible: struct {
            action_label: []const u8,
            activity_kind: types.ToolActivityKind,
        },
    };

    pub fn deinit(self: *ProvisionalToolStatuses, alloc: Allocator) void {
        for (self.tracked.items) |*status| status.deinit(alloc);
        self.tracked.deinit(alloc);
        for (self.terminal_ids.items) |id| alloc.free(id);
        self.terminal_ids.deinit(alloc);
    }

    pub fn preflight(registry: tool_dispatch.Registry, tool_name: []const u8) ?StartPreflight {
        if (tooling_presentation.isProviderSearchAlias(tool_name)) {
            return .{ .eligible = .{
                .action_label = "Searching",
                .activity_kind = .read,
            } };
        }
        const lookup_name = if (std.mem.eql(u8, tool_name, "run_command"))
            "terminal"
        else
            tool_name;
        const spec = registry.lookup(lookup_name) orelse return null;
        if (spec.executor_kind == .terminal) return .ineligible;
        return switch (spec.activity_kind) {
            .ask, .write, .edit => .ineligible,
            else => .{ .eligible = .{
                .action_label = spec.action_label,
                .activity_kind = spec.activity_kind,
            } },
        };
    }

    pub fn publish(
        self: *ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        alloc: Allocator,
        turn_id: u64,
        tool_id: []const u8,
        tool_name: []const u8,
        activity_kind: types.ToolActivityKind,
        action_label: []const u8,
        label_value: ?[]const u8,
    ) !void {
        if (tool_id.len == 0) {
            debug_trace.logf(
                "ui_activity",
                "suppressed provisional lifecycle with missing identity turn_id={d}",
                .{turn_id},
            );
            return;
        }

        var buf: [512]u8 = undefined;
        const label = try formatProvisionalProgressLabel(&buf, action_label, label_value);
        const recorded = try self.recordTracked(
            alloc,
            tool_id,
            tool_name,
            label_value,
        );
        hooks.push_tool_lifecycle(hooks.ctx, .{
            .provisional = .{
                .id = .{ .turn_id = turn_id, .call_id = tool_id },
                .presentation_group_id = self.presentation_group_id,
                .tool_name = tool_name,
                .activity_kind = activity_kind,
            },
        }) catch |err| {
            if (recorded) self.forget(alloc, tool_id);
            return err;
        };
        hooks.push_tool_lifecycle(hooks.ctx, .{
            .progress = .{
                .id = .{ .turn_id = turn_id, .call_id = tool_id },
                .text = label,
            },
        }) catch {};
    }

    pub fn finishMalformedToolArguments(
        self: *const ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        arena: Allocator,
        turn_id: u64,
        call: ToolCall,
    ) !void {
        const call_id = self.visibleId(call) orelse return;
        const summary = try std.fmt.allocPrint(
            arena,
            "{s} failed: invalid JSON arguments",
            .{fallbackToolDisplay(hooks.tool_registry, call.name)},
        );
        try hooks.push_tool_lifecycle(hooks.ctx, .{
            .terminal = .{
                .id = .{ .turn_id = turn_id, .call_id = call_id },
                .outcome = .{ .kind = .failed, .summary = summary },
            },
        });
    }

    pub fn finishMalformedProviderToolArguments(
        self: *const ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        arena: Allocator,
        turn_id: u64,
        calls: []const ToolCall,
    ) !void {
        for (calls) |call| {
            if (call.provenance != .provider_executed or call.argument_integrity != .malformed_json) continue;
            try self.finishMalformedToolArguments(hooks, arena, turn_id, call);
        }
    }

    pub fn finishRejectedCompletions(
        self: *const ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        arena: Allocator,
        turn_id: u64,
        calls: []const ToolCall,
        advertised_dynamic_tool_names: []const []const u8,
    ) !void {
        for (calls) |call| {
            if (!self.has(call.id)) continue;
            try finishDeniedToolStatus(
                hooks,
                arena,
                turn_id,
                call,
                true,
                null,
                "Failed",
                advertised_dynamic_tool_names,
            );
        }
    }

    /// Settles one admitted call against its tracked final or provisional id.
    /// The tracked id is consumed only after terminal publication succeeds.
    pub fn settleAdmittedCall(
        self: *ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        alloc: Allocator,
        arena: Allocator,
        turn_id: u64,
        call: ToolCall,
        label: []const u8,
        advertised_dynamic_tool_names: []const []const u8,
    ) !bool {
        return self.finishDeniedCall(
            hooks,
            alloc,
            arena,
            turn_id,
            call,
            false,
            null,
            label,
            advertised_dynamic_tool_names,
        );
    }

    pub fn settleDeferredCall(
        self: *ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        alloc: Allocator,
        arena: Allocator,
        turn_id: u64,
        call: ToolCall,
        advertised_dynamic_tool_names: []const []const u8,
    ) !bool {
        const recorded_terminal = try self.recordTerminal(alloc, call.id);
        if (!recorded_terminal) return false;
        errdefer self.forgetTerminal(alloc, call.id);
        const target = try self.ensureTerminalTarget(
            hooks,
            arena,
            turn_id,
            call,
            false,
            null,
            advertised_dynamic_tool_names,
        ) orelse {
            self.forgetTerminal(alloc, call.id);
            return false;
        };
        try finishDeferredToolStatus(
            hooks,
            arena,
            turn_id,
            target.call,
            advertised_dynamic_tool_names,
        );
        if (target.tracked_id) |tracked_id| self.forget(alloc, tracked_id);
        return true;
    }

    pub fn finishDeniedCall(
        self: *ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        alloc: Allocator,
        arena: Allocator,
        turn_id: u64,
        call: ToolCall,
        authoritative_started: bool,
        display_target: ?[]const u8,
        label: []const u8,
        advertised_dynamic_tool_names: []const []const u8,
    ) !bool {
        const recorded_terminal = try self.recordTerminal(alloc, call.id);
        if (!recorded_terminal) return false;
        errdefer self.forgetTerminal(alloc, call.id);
        const target = try self.ensureTerminalTarget(
            hooks,
            arena,
            turn_id,
            call,
            authoritative_started,
            display_target,
            advertised_dynamic_tool_names,
        ) orelse {
            self.forgetTerminal(alloc, call.id);
            return false;
        };
        try finishDeniedToolStatus(
            hooks,
            arena,
            turn_id,
            target.call,
            true,
            display_target,
            label,
            advertised_dynamic_tool_names,
        );
        if (target.tracked_id) |tracked_id| self.forget(alloc, tracked_id);
        return true;
    }

    pub fn finishExecutedCall(
        self: *ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        alloc: Allocator,
        arena: Allocator,
        turn_id: u64,
        call: ToolCall,
        authoritative_started: bool,
        display_target: ?[]const u8,
        result: ToolExecutionResult,
        safe_result: []const u8,
        result_memory: types.ToolResultMemory,
        diff_entry: ?DiffEntryPayload,
        advertised_dynamic_tool_names: []const []const u8,
    ) !bool {
        const recorded_terminal = try self.recordTerminal(alloc, call.id);
        if (!recorded_terminal) return false;
        errdefer self.forgetTerminal(alloc, call.id);
        const target = try self.ensureTerminalTarget(
            hooks,
            arena,
            turn_id,
            call,
            authoritative_started,
            display_target,
            advertised_dynamic_tool_names,
        ) orelse {
            self.forgetTerminal(alloc, call.id);
            return false;
        };
        try finishExecutedToolStatus(
            hooks,
            arena,
            turn_id,
            target.call,
            true,
            display_target,
            result,
            safe_result,
            result_memory,
            diff_entry,
            advertised_dynamic_tool_names,
        );
        if (target.tracked_id) |tracked_id| self.forget(alloc, tracked_id);
        return true;
    }

    pub fn finishCancelledCall(
        self: *ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        alloc: Allocator,
        arena: Allocator,
        turn_id: u64,
        call: ToolCall,
        authoritative_started: bool,
        display_target: ?[]const u8,
        result: ToolExecutionResult,
        advertised_dynamic_tool_names: []const []const u8,
    ) !bool {
        const recorded_terminal = try self.recordTerminal(alloc, call.id);
        if (!recorded_terminal) return false;
        errdefer self.forgetTerminal(alloc, call.id);
        const target = try self.ensureTerminalTarget(
            hooks,
            arena,
            turn_id,
            call,
            authoritative_started,
            display_target,
            advertised_dynamic_tool_names,
        ) orelse {
            self.forgetTerminal(alloc, call.id);
            return false;
        };
        try finishCancelledToolStatus(
            hooks,
            arena,
            turn_id,
            target.call,
            true,
            display_target,
            result,
            advertised_dynamic_tool_names,
        );
        if (target.tracked_id) |tracked_id| self.forget(alloc, tracked_id);
        return true;
    }

    pub fn finishTrackedCancelled(
        self: *ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        alloc: Allocator,
        arena: Allocator,
        turn_id: u64,
    ) !void {
        while (self.tracked.items.len > 0) {
            const status = &self.tracked.items[self.tracked.items.len - 1];
            if (self.hasTerminal(status.id)) {
                self.forget(alloc, status.id);
                continue;
            }
            const recorded_terminal = try self.recordTerminal(alloc, status.id);
            if (!recorded_terminal) {
                self.forget(alloc, status.id);
                continue;
            }
            errdefer self.forgetTerminal(alloc, status.id);
            const detail = status.label_value orelse
                fallbackToolDisplay(hooks.tool_registry, status.tool_name);
            const encoded = try text_utils.encodeTerminalSafe(
                arena,
                detail,
                diff.max_encoded_label_bytes,
            );
            const summary = try std.fmt.allocPrint(arena, "Cancelled {s}", .{encoded.bytes});
            try hooks.push_tool_lifecycle(hooks.ctx, .{ .terminal = .{
                .id = .{ .turn_id = turn_id, .call_id = status.id },
                .outcome = .{ .kind = .cancelled, .summary = summary },
            } });
            self.forget(alloc, status.id);
        }
    }

    /// Settles provisional starts from an interrupted, proven-unexecuted
    /// stream unless the recovered completion retained their identity.
    pub fn finishUnmatchedRecoveryStarts(
        self: *ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        alloc: Allocator,
        arena: Allocator,
        turn_id: u64,
        recovered_calls: []const ToolCall,
    ) !void {
        var index = self.tracked.items.len;
        while (index > 0) {
            index -= 1;
            const status = &self.tracked.items[index];
            if (trackedStatusMatchesCalls(status.*, recovered_calls)) continue;
            if (streamStartMayHaveExecutedAtProvider(
                hooks.tool_registry,
                status.tool_name,
            )) continue;
            if (self.hasTerminal(status.id)) {
                self.forget(alloc, status.id);
                continue;
            }
            const recorded_terminal = try self.recordTerminal(alloc, status.id);
            if (!recorded_terminal) {
                self.forget(alloc, status.id);
                continue;
            }
            errdefer self.forgetTerminal(alloc, status.id);
            const detail = status.label_value orelse
                fallbackToolDisplay(hooks.tool_registry, status.tool_name);
            const encoded = try text_utils.encodeTerminalSafe(
                arena,
                detail,
                diff.max_encoded_label_bytes,
            );
            const summary = try std.fmt.allocPrint(
                arena,
                "Connection interrupted before {s} ran",
                .{encoded.bytes},
            );
            try hooks.push_tool_lifecycle(hooks.ctx, .{ .terminal = .{
                .id = .{ .turn_id = turn_id, .call_id = status.id },
                .outcome = .{ .kind = .failed, .summary = summary },
            } });
            self.forget(alloc, status.id);
        }
    }

    pub fn visibleId(self: *const ProvisionalToolStatuses, call: ToolCall) ?[]const u8 {
        if (self.has(call.id)) return call.id;
        if (call.provisional_id) |provisional_id| {
            if (self.has(provisional_id)) return provisional_id;
        }
        return null;
    }

    fn record(self: *ProvisionalToolStatuses, alloc: Allocator, id: []const u8) !bool {
        return self.recordTracked(alloc, id, "", null);
    }

    fn recordTracked(
        self: *ProvisionalToolStatuses,
        alloc: Allocator,
        id: []const u8,
        tool_name: []const u8,
        label_value: ?[]const u8,
    ) !bool {
        if (id.len == 0) return false;
        if (self.findTracked(id)) |index| {
            const status = &self.tracked.items[index];
            if (label_value) |value| {
                const owned_value = try alloc.dupe(u8, value);
                if (status.label_value) |prior| alloc.free(prior);
                status.label_value = owned_value;
            }
            return false;
        }
        const owned_id = try alloc.dupe(u8, id);
        errdefer alloc.free(owned_id);
        const owned_tool_name = try alloc.dupe(u8, tool_name);
        errdefer alloc.free(owned_tool_name);
        const owned_label_value = if (label_value) |value| try alloc.dupe(u8, value) else null;
        errdefer if (owned_label_value) |value| alloc.free(value);
        try self.tracked.append(alloc, .{
            .id = owned_id,
            .tool_name = owned_tool_name,
            .label_value = owned_label_value,
        });
        return true;
    }

    fn has(self: *const ProvisionalToolStatuses, id: []const u8) bool {
        return self.findTracked(id) != null;
    }

    fn findTracked(self: *const ProvisionalToolStatuses, id: []const u8) ?usize {
        for (self.tracked.items, 0..) |status, i| {
            if (std.mem.eql(u8, status.id, id)) return i;
        }
        return null;
    }

    fn trackedStatusMatchesCalls(
        status: TrackedStatus,
        calls: []const ToolCall,
    ) bool {
        for (calls) |call| {
            if (std.mem.eql(u8, status.id, call.id)) return true;
            if (call.provisional_id) |provisional_id| {
                if (std.mem.eql(u8, status.id, provisional_id)) return true;
            }
        }
        return false;
    }

    fn recordTerminal(self: *ProvisionalToolStatuses, alloc: Allocator, id: []const u8) !bool {
        if (id.len == 0 or self.hasTerminal(id)) return false;
        const owned_id = try alloc.dupe(u8, id);
        errdefer alloc.free(owned_id);
        try self.terminal_ids.append(alloc, owned_id);
        return true;
    }

    fn hasTerminal(self: *const ProvisionalToolStatuses, id: []const u8) bool {
        for (self.terminal_ids.items) |existing| {
            if (std.mem.eql(u8, existing, id)) return true;
        }
        return false;
    }

    const TerminalTarget = struct {
        call: ToolCall,
        tracked_id: ?[]const u8,
    };

    fn terminalTarget(
        self: *const ProvisionalToolStatuses,
        call: ToolCall,
        authoritative_started: bool,
    ) ?TerminalTarget {
        const visible_id = self.visibleId(call);
        if (authoritative_started) {
            return .{ .call = call, .tracked_id = visible_id };
        }
        const provisional_id = visible_id orelse return null;
        var visible_call = call;
        visible_call.id = provisional_id;
        return .{ .call = visible_call, .tracked_id = provisional_id };
    }

    fn ensureTerminalTarget(
        self: *const ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        arena: Allocator,
        turn_id: u64,
        call: ToolCall,
        authoritative_started: bool,
        display_target: ?[]const u8,
        advertised_dynamic_tool_names: []const []const u8,
    ) !?TerminalTarget {
        if (self.terminalTarget(call, authoritative_started)) |target| return target;
        const started = try startToolVisibleLifecycle(
            hooks,
            arena,
            turn_id,
            self.presentation_group_id,
            call,
            display_target,
            advertised_dynamic_tool_names,
        );
        if (!started) return null;
        return .{ .call = call, .tracked_id = null };
    }

    fn forget(self: *ProvisionalToolStatuses, alloc: Allocator, id: []const u8) void {
        const index = self.findTracked(id) orelse return;
        self.tracked.items[index].deinit(alloc);
        _ = self.tracked.swapRemove(index);
    }

    fn forgetTerminal(self: *ProvisionalToolStatuses, alloc: Allocator, id: []const u8) void {
        for (self.terminal_ids.items, 0..) |existing, i| {
            if (!std.mem.eql(u8, existing, id)) continue;
            alloc.free(existing);
            _ = self.terminal_ids.swapRemove(i);
            return;
        }
    }
};

pub const ToolPresentationGroupObservation = struct {
    has_visible_tool_calls: bool,
    has_visible_text: bool,
    saw_tool_start: bool,
    saw_visible_text_after_tool_start: bool,
};

pub const ToolPresentationGroupTransition = struct {
    tool_group_id: ?types.ToolPresentationGroupId,
    active_group_id: ?types.ToolPresentationGroupId,
};

pub fn presentationGroupForStep(
    active_group_id: ?types.ToolPresentationGroupId,
    turn_id: u64,
    step_id: u64,
) types.ToolPresentationGroupId {
    if (active_group_id) |group_id| {
        if (group_id.turn_id == turn_id) return group_id;
    }
    return .{ .turn_id = turn_id, .anchor_step_id = step_id };
}

pub fn transitionPresentationGroup(
    active_group_id: ?types.ToolPresentationGroupId,
    tool_group_id: ?types.ToolPresentationGroupId,
    turn_id: u64,
    step_id: u64,
    observation: ToolPresentationGroupObservation,
) ToolPresentationGroupTransition {
    var resolved_tool_group_id = tool_group_id;
    if (observation.has_visible_tool_calls and
        (resolved_tool_group_id == null or
            (!observation.saw_tool_start and observation.has_visible_text)))
    {
        resolved_tool_group_id = .{
            .turn_id = turn_id,
            .anchor_step_id = step_id,
        };
    }

    var next_active_group_id = active_group_id;
    if (observation.has_visible_tool_calls) {
        next_active_group_id = resolved_tool_group_id;
    }
    if (observation.saw_visible_text_after_tool_start or
        (observation.has_visible_text and !observation.has_visible_tool_calls))
    {
        next_active_group_id = null;
    }
    return .{
        .tool_group_id = resolved_tool_group_id,
        .active_group_id = next_active_group_id,
    };
}

pub fn activityKind(registry: tool_dispatch.Registry, tool_name: []const u8) types.ToolActivityKind {
    if (tooling_presentation.isProviderSearchAlias(tool_name)) return .read;
    return tool_dispatch.toolActivityKind(registry, tool_name);
}

pub fn activityKindForCall(
    alloc: Allocator,
    registry: tool_dispatch.Registry,
    call: ToolCall,
) types.ToolActivityKind {
    if (tooling_presentation.isProviderSearchAlias(call.name)) return .read;
    return tool_dispatch.toolActivityKindForCall(alloc, registry, call);
}

fn formatProvisionalProgressLabel(
    buf: []u8,
    action_label: []const u8,
    label_value: ?[]const u8,
) ![]const u8 {
    if (label_value) |value| {
        return std.fmt.bufPrint(buf, "● {s}\x1b[0m \x1b[38;5;245m{s}\x1b[0m", .{ action_label, value });
    }
    return std.fmt.bufPrint(buf, "● {s}\x1b[0m", .{action_label});
}

pub fn fileMutationDisplayPath(
    arena: Allocator,
    authority: command_admission.ToolExecutionAuthority,
) !?[]const u8 {
    return switch (authority) {
        .file_mutation => |file_authority| if (file_authority.prepared) |prepared|
            prepared.display_path
        else blk: {
            const encoded = try text_utils.encodeTerminalSafe(
                arena,
                file_authority.input.path(),
                diff.max_encoded_label_bytes,
            );
            break :blk encoded.bytes;
        },
        else => null,
    };
}

pub noinline fn startToolVisibleLifecycle(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    turn_id: u64,
    presentation_group_id: ?types.ToolPresentationGroupId,
    call: ToolCall,
    display_target: ?[]const u8,
    advertised_dynamic_tool_names: []const []const u8,
) !bool {
    const activity_kind = activityKindForCall(arena, hooks.tool_registry, call);
    if (activity_kind == .ask) return false;
    const redacted_arguments = try text_utils.maskSecrets(arena, call.arguments_json);
    const activity_line = try hooks.describe_tool_action(
        hooks.ctx,
        arena,
        call,
        display_target,
        advertised_dynamic_tool_names,
    );
    try hooks.push_tool_lifecycle(hooks.ctx, .{ .authoritative_started = .{
        .id = .{ .turn_id = turn_id, .call_id = call.id },
        .presentation_group_id = presentation_group_id,
        .reconciles_provisional_call_id = call.provisional_id,
        .tool_name = call.name,
        .activity_kind = activity_kind,
        .arguments_json = redacted_arguments,
        .place_after_current_transcript = false,
    } });
    try hooks.push_tool_lifecycle(hooks.ctx, .{ .progress = .{
        .id = .{ .turn_id = turn_id, .call_id = call.id },
        .text = activity_line,
    } });
    return true;
}

pub fn finishDeniedToolStatus(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    turn_id: u64,
    call: ToolCall,
    status_started: bool,
    display_target: ?[]const u8,
    label: []const u8,
    advertised_dynamic_tool_names: []const []const u8,
) !void {
    return finishDeniedToolStatusInternal(
        hooks,
        arena,
        turn_id,
        call,
        status_started,
        display_target,
        label,
        advertised_dynamic_tool_names,
        null,
        null,
        null,
    );
}

fn finishDeferredToolStatus(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    turn_id: u64,
    call: ToolCall,
    advertised_dynamic_tool_names: []const []const u8,
) !void {
    const line = try hooks.describe_tool_action_denied(
        hooks.ctx,
        arena,
        call,
        null,
        types.context_deferred_tool_status_label,
        advertised_dynamic_tool_names,
    );
    try hooks.push_tool_lifecycle(hooks.ctx, .{ .terminal = .{
        .id = .{ .turn_id = turn_id, .call_id = call.id },
        .outcome = .{
            .kind = .deferred,
            .summary = line,
        },
    } });
}

pub fn finishDeniedToolStatusWithResultMemory(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    turn_id: u64,
    call: ToolCall,
    status_started: bool,
    display_target: ?[]const u8,
    label: []const u8,
    advertised_dynamic_tool_names: []const []const u8,
    result: ToolExecutionResult,
    safe_result: []const u8,
    result_memory: types.ToolResultMemory,
) !void {
    return finishDeniedToolStatusInternal(
        hooks,
        arena,
        turn_id,
        call,
        status_started,
        display_target,
        label,
        advertised_dynamic_tool_names,
        safe_result,
        result_memory,
        result.command_result_json,
    );
}

fn finishDeniedToolStatusInternal(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    turn_id: u64,
    call: ToolCall,
    status_started: bool,
    display_target: ?[]const u8,
    label: []const u8,
    advertised_dynamic_tool_names: []const []const u8,
    safe_result: ?[]const u8,
    result_memory: ?types.ToolResultMemory,
    command_result_json: ?[]const u8,
) !void {
    if (!status_started) return;
    const denied_line = try hooks.describe_tool_action_denied(
        hooks.ctx,
        arena,
        call,
        display_target,
        label,
        advertised_dynamic_tool_names,
    );
    const command_artifact_handle = if (activityKindForCall(arena, hooks.tool_registry, call) == .command)
        try commandArtifactHandle(arena, command_result_json)
    else
        null;
    try hooks.push_tool_lifecycle(hooks.ctx, .{
        .terminal = .{
            .id = .{ .turn_id = turn_id, .call_id = call.id },
            .outcome = .{
                .kind = if (std.mem.eql(u8, label, "Cancelled"))
                    .cancelled
                else if (std.mem.eql(u8, label, "Failed"))
                    .failed
                else
                    .denied,
                .summary = denied_line,
            },
            .result = safe_result,
            .result_memory = result_memory,
            .command_artifact_handle = command_artifact_handle,
        },
    });
}

pub fn finishCancelledToolStatus(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    turn_id: u64,
    call: ToolCall,
    status_started: bool,
    display_target: ?[]const u8,
    result: ToolExecutionResult,
    advertised_dynamic_tool_names: []const []const u8,
) !void {
    if (!status_started) return;
    const line = try hooks.describe_tool_action_denied(
        hooks.ctx,
        arena,
        call,
        display_target,
        "Cancelled",
        advertised_dynamic_tool_names,
    );
    const command_artifact_handle = if (activityKindForCall(arena, hooks.tool_registry, call) == .command)
        commandArtifactHandle(arena, result.command_result_json) catch |err| blk: {
            debug_trace.logf("tool", "cancelled command artifact handle omitted err={s}", .{@errorName(err)});
            break :blk null;
        }
    else
        null;
    try hooks.push_tool_lifecycle(hooks.ctx, .{ .terminal = .{
        .id = .{ .turn_id = turn_id, .call_id = call.id },
        .outcome = .{
            .kind = .cancelled,
            .summary = line,
        },
        .command_artifact_handle = command_artifact_handle,
    } });
}

pub fn finishExecutedToolStatus(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    turn_id: u64,
    call: ToolCall,
    status_started: bool,
    display_target: ?[]const u8,
    result: ToolExecutionResult,
    safe_result: []const u8,
    result_memory: types.ToolResultMemory,
    diff_entry: ?DiffEntryPayload,
    advertised_dynamic_tool_names: []const []const u8,
) !void {
    if (!status_started) return;
    const activity_kind = activityKindForCall(arena, hooks.tool_registry, call);
    const command_process_ran = activity_kind == .command and
        result_memory.command_process_presentation != null;
    const base_line = switch (if (command_process_ran) .success else result.status) {
        .success => if (file_mutation_contract.resultIsNoop(call.name, result.model_output))
            result.model_output
        else
            try hooks.describe_tool_action_completed(
                hooks.ctx,
                arena,
                call,
                display_target,
                advertised_dynamic_tool_names,
            ),
        .failure => blk: {
            const base = try hooks.describe_tool_action_denied(
                hooks.ctx,
                arena,
                call,
                display_target,
                "Failed",
                advertised_dynamic_tool_names,
            );
            if (std.mem.eql(u8, call.name, "terminal")) {
                if (try tool_result_errors.inspectTerminalActionFieldCorrection(
                    arena,
                    safe_result,
                )) |correction| {
                    break :blk try std.fmt.allocPrint(
                        arena,
                        "{s} · {d} invalid field{s}",
                        .{
                            base,
                            correction.invalid_field_count,
                            if (correction.invalid_field_count == 1) "" else "s",
                        },
                    );
                }
            }
            const detail = (try failureStatusDetail(
                arena,
                call,
                result,
                safe_result,
                advertised_dynamic_tool_names,
            )) orelse break :blk base;
            if (detail.len == 0) break :blk base;
            break :blk try std.fmt.allocPrint(arena, "{s}: {s}", .{ base, detail });
        },
    };
    const summary_line = if (result.web_fetch_completion) |completion|
        try formatWebFetchCompletion(arena, base_line, completion)
    else if (result.web_search_completion) |completion|
        try formatWebSearchCompletion(arena, base_line, completion)
    else
        base_line;
    const line = if (diff_entry) |payload| blk: {
        break :blk try formatToolStatusWithStats(arena, summary_line, payload.additions, payload.deletions, hooks.diff_marker_styles);
    } else summary_line;
    const command_artifact_handle = if (activity_kind == .command)
        try commandArtifactHandle(arena, result.command_result_json)
    else
        null;
    try hooks.push_tool_lifecycle(hooks.ctx, .{
        .terminal = .{
            .id = .{ .turn_id = turn_id, .call_id = call.id },
            .outcome = .{
                .kind = if (result.status == .success or command_process_ran)
                    .completed
                else
                    .failed,
                .summary = line,
            },
            .result = safe_result,
            .result_memory = result_memory,
            .command_artifact_handle = command_artifact_handle,
        },
    });
}

fn failureStatusDetail(
    arena: Allocator,
    call: ToolCall,
    result: ToolExecutionResult,
    safe_result: []const u8,
    advertised_dynamic_tool_names: []const []const u8,
) !?[]const u8 {
    if (result.status_detail) |detail| {
        if (!std.mem.eql(u8, detail, "preflight failed") or
            !file_mutation_contract.isToolName(call.name) or
            !std.mem.startsWith(u8, safe_result, call.name))
        {
            return detail;
        }

        const failure_prefix = " failed: ";
        const remainder = safe_result[call.name.len..];
        if (!std.mem.startsWith(u8, remainder, failure_prefix)) return detail;
        const actionable = remainder[failure_prefix.len..];
        if (actionable.len == 0 or
            std.mem.findScalar(u8, actionable, '\n') != null or
            std.mem.findScalar(u8, actionable, '\r') != null)
        {
            return detail;
        }
        return actionable;
    }

    if (safe_result.len == 0 or
        !containsName(advertised_dynamic_tool_names, call.name))
    {
        return null;
    }
    const detail = try mcpFailureEnvelopeText(arena, safe_result) orelse safe_result;
    const encoded = try text_utils.encodeTerminalSafe(arena, detail, 256);
    return if (encoded.bytes.len == 0) null else encoded.bytes;
}

fn mcpFailureEnvelopeText(
    arena: Allocator,
    safe_result: []const u8,
) Allocator.Error!?[]const u8 {
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        arena,
        safe_result,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();
    const envelope = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };
    const payload = envelope.get("result") orelse envelope.get("error") orelse
        return null;
    const payload_object = switch (payload) {
        .object => |object| object,
        else => return null,
    };
    if (payload_object.get("content")) |content| {
        if (content == .array) {
            for (content.array.items) |item| {
                if (item != .object) continue;
                const text = item.object.get("text") orelse continue;
                if (text == .string and text.string.len > 0) {
                    const owned: []const u8 = try arena.dupe(u8, text.string);
                    return owned;
                }
            }
        }
    }
    const message = payload_object.get("message") orelse return null;
    if (message != .string or message.string.len == 0) return null;
    const owned: []const u8 = try arena.dupe(u8, message.string);
    return owned;
}

fn containsName(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn commandArtifactHandle(
    arena: Allocator,
    command_result_json: ?[]const u8,
) !?[]const u8 {
    const json = command_result_json orelse return null;
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, json, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return null,
    };
    const kind = switch (object.get("kind") orelse return null) {
        .string => |value| value,
        else => return null,
    };
    if (!std.mem.eql(u8, kind, "foreground")) return null;
    const output_file = switch (object.get("output_file") orelse return null) {
        .string => |value| value,
        else => return null,
    };
    const handle = std.fs.path.basename(output_file);
    if (!std.mem.startsWith(u8, handle, "fx-command-") or
        !std.mem.endsWith(u8, handle, ".log") or
        std.mem.endsWith(u8, handle, ".stdout.log") or
        std.mem.endsWith(u8, handle, ".stderr.log")) return null;
    const owned: []const u8 = try arena.dupe(u8, handle);
    return owned;
}

pub fn malformedToolArgumentsResult(arena: Allocator, call: ToolCall) !ToolExecutionResult {
    return .{
        .status = .failure,
        .model_output = try tool_result_errors.malformedToolArgumentsJson(
            arena,
            call.name,
        ),
        .status_detail = "invalid JSON arguments",
    };
}

pub fn finishCommittedFileStatus(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    turn_id: u64,
    call: ToolCall,
    status_started: bool,
    display_target: ?[]const u8,
    preview: diff.FileChangePreview,
    advertised_dynamic_tool_names: []const []const u8,
) !void {
    if (!status_started) return;
    const base_line = try hooks.describe_tool_action_completed(
        hooks.ctx,
        arena,
        call,
        display_target,
        advertised_dynamic_tool_names,
    );
    const line = try formatToolStatusWithStats(
        arena,
        base_line,
        preview.additions,
        preview.deletions,
        hooks.diff_marker_styles,
    );
    try hooks.push_tool_lifecycle(hooks.ctx, .{
        .terminal = .{
            .id = .{ .turn_id = turn_id, .call_id = call.id },
            .outcome = .{
                .kind = .completed,
                .summary = line,
            },
        },
    });
}

fn formatWebSearchCompletion(arena: Allocator, base: []const u8, completion: types.WebSearchCompletion) ![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "{s} \x1b[38;5;245m| {d} search{s} | {d}ms\x1b[0m",
        .{ base, completion.searches, if (completion.searches == 1) "" else "es", completion.duration_ms },
    );
}

fn formatWebFetchCompletion(arena: Allocator, base: []const u8, completion: types.WebFetchCompletion) ![]const u8 {
    const cache = if (completion.cache_hit) "cache hit" else "fetched";
    const artifact = switch (completion.artifact_state) {
        .none => "",
        .stored => " | artifact stored",
        .unavailable => " | artifact unavailable",
    };
    return std.fmt.allocPrint(
        arena,
        "{s} \x1b[38;5;245m| {s} | {d} bytes | HTTP {d} | {d}ms | {s}{s}\x1b[0m",
        .{ base, completion.url(), completion.bytes, completion.status, completion.duration_ms, cache, artifact },
    );
}

pub fn formatToolStatusWithStats(
    arena: Allocator,
    base: []const u8,
    additions: usize,
    deletions: usize,
    markers: runtime_deps.DiffMarkerStyles,
) ![]const u8 {
    const accent = "\x1b[38;5;252m";
    const dim = "\x1b[38;5;245m";
    const reset = "\x1b[0m";
    // Fall back to the neutral accent when no marker color is supplied.
    const add_style = if (markers.added.len != 0) markers.added else accent;
    const rem_style = if (markers.removed.len != 0) markers.removed else accent;
    if (additions > 0 and deletions > 0) {
        return std.fmt.allocPrint(arena, "{s} {s}+{d}{s} {s}/{s} {s}-{d}{s}", .{ base, add_style, additions, reset, dim, reset, rem_style, deletions, reset });
    } else if (additions > 0) {
        return std.fmt.allocPrint(arena, "{s} {s}+{d}{s}", .{ base, add_style, additions, reset });
    } else if (deletions > 0) {
        return std.fmt.allocPrint(arena, "{s} {s}-{d}{s}", .{ base, rem_style, deletions, reset });
    }
    return base;
}

const test_tools = [_]tool_dispatch.Tool{
    test_builtin_tools.list_files,
    test_builtin_tools.read_file,
    test_builtin_tools.write_file,
    test_builtin_tools.edit_file,
    test_builtin_tools.terminal,
    test_builtin_tools.ask_user_question,
};
const test_tool_registry = tool_dispatch.Registry{ .tools = test_tools[0..] };
const custom_activity_tool = blk: {
    var tool = test_builtin_tools.memory;
    tool.name = "custom_activity";
    tool.action_label = "Custom activity";
    tool.activity_kind = .open;
    break :blk tool;
};
const custom_activity_registry = tool_dispatch.Registry{ .tools = &.{custom_activity_tool} };

const ProvisionalStatusTestCapture = struct {
    alloc: Allocator,
    tool_registry: tool_dispatch.Registry = test_tool_registry,
    events: std.ArrayList(types.ToolLifecycleEvent) = .empty,
    fail_provisional: bool = false,
    fail_progress: bool = false,
    fail_terminal: bool = false,
    retain_events: bool = true,

    fn deinit(self: *ProvisionalStatusTestCapture) void {
        const worker_runtime = @import("../worker_runtime.zig");
        for (self.events.items) |event| worker_runtime.freeToolLifecycleEvent(self.alloc, event);
        self.events.deinit(self.alloc);
    }

    fn hooks(self: *ProvisionalStatusTestCapture) AgentRuntimeDeps {
        return .{
            .ctx = self,
            .tool_registry = self.tool_registry,
            .append_runtime_context = noopAppendRuntimeContext,
            .request_tool_permission = noopRequestPermission,
            .describe_tool_action = describeToolAction,
            .describe_tool_action_completed = describeToolAction,
            .describe_tool_action_denied = describeDeniedToolAction,
            .permission_target_for_call = noopPermissionTarget,
            .execute_tool_call = noopExecuteToolCall,
            .publish_committed_file_handoff = noopPublishCommittedFileHandoff,
            .propagate_history_turn = noopPropagateHistoryTurn,
            .propagate_grant = noopPropagateGrant,
            .push_event = noopPushEvent,
            .push_text = noopPushText,
            .push_tool_lifecycle = captureToolLifecycle,
            .push_diff_block = noopPushDiffBlock,
            .push_system_notice = noopPushSystemNotice,
            .push_command_output_complete = noopPushCommandOutputComplete,
            .push_http_error = noopPushHttpError,
            .format_tool_execution_error = noopFormatToolExecutionError,
        };
    }

    fn noopAppendRuntimeContext(_: *anyopaque, _: Allocator, _: *std.ArrayList(types.ChatMessage)) !void {}
    fn noopRequestPermission(_: *anyopaque, _: Allocator, _: ToolCall, _: permission_auto_classifier.ReviewTurnContext, _: types.PermissionMode, _: []const types.PermissionGrant, _: ?runtime_tool_contracts.LiveToolAuthority, _: ?runtime_tool_contracts.LivePermissionRevalidation, _: []const []const u8) !command_admission.PermissionOutcome {
        return .{ .decision = .once, .execution_authority = .ordinary };
    }
    fn describeToolAction(_: *anyopaque, arena: Allocator, call: ToolCall, _: ?[]const u8, _: []const []const u8) ![]const u8 {
        return std.fmt.allocPrint(arena, "started {s}", .{call.name});
    }
    fn describeDeniedToolAction(_: *anyopaque, arena: Allocator, call: ToolCall, _: ?[]const u8, label: []const u8, _: []const []const u8) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s} {s}", .{ label, call.name });
    }
    fn noopPermissionTarget(_: *anyopaque, arena: Allocator, _: ToolCall, _: []const []const u8) ![]const u8 {
        return arena.dupe(u8, "");
    }
    fn noopExecuteToolCall(_: *anyopaque, _: runtime_tool_contracts.ToolExecutionRequest) !ToolExecutionResult {
        return .{ .model_output = "" };
    }
    fn noopPublishCommittedFileHandoff(_: *anyopaque, _: @import("../../tooling/file_mutation.zig").CommittedFileHandoff) runtime_tool_contracts.SecondaryPublicationReport {
        return .{ .diff = .skipped, .tracker = .skipped };
    }
    fn noopPropagateHistoryTurn(_: *anyopaque, _: types.HistoryTurn) !void {}
    fn noopPropagateGrant(_: *anyopaque, _: []const u8, _: []const u8) !void {}
    fn noopPushEvent(_: *anyopaque, _: @import("../worker_runtime.zig").WorkerEvent) !void {}
    fn noopPushText(_: *anyopaque, _: runtime_deps.TextEmission) !void {}
    fn noopPushDiffBlock(_: *anyopaque, _: DiffEntryPayload) !void {}
    fn noopPushSystemNotice(_: *anyopaque, _: []const u8) !void {}
    fn noopPushCommandOutputComplete(_: *anyopaque, _: ?types.ToolLifecycleId) !void {}
    fn noopPushHttpError(_: *anyopaque, _: std.http.Status, _: []const u8, _: ?types.CredentialSource) !void {}
    fn noopFormatToolExecutionError(_: *anyopaque, arena: Allocator, _: []const u8, err: anyerror) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s}", .{@errorName(err)});
    }

    fn captureToolLifecycle(raw: *anyopaque, event: types.ToolLifecycleEvent) !void {
        const self: *ProvisionalStatusTestCapture = @ptrCast(@alignCast(raw));
        switch (event) {
            .provisional => if (self.fail_provisional) return error.TestProvisionalPublicationFailure,
            .progress => if (self.fail_progress) return error.TestProgressPublicationFailure,
            .terminal => if (self.fail_terminal) return error.TestTerminalPublicationFailure,
            else => {},
        }
        if (!self.retain_events) return;

        const worker_runtime = @import("../worker_runtime.zig");
        const owned = try worker_runtime.dupeToolLifecycleEvent(self.alloc, event);
        errdefer worker_runtime.freeToolLifecycleEvent(self.alloc, owned);
        try self.events.append(self.alloc, owned);
    }
};

fn testToolCall(id: []const u8, name: []const u8) ToolCall {
    return .{ .id = id, .name = name, .arguments_json = "{}" };
}

fn eligibleActionLabel(tool_name: []const u8) []const u8 {
    return switch (ProvisionalToolStatuses.preflight(test_tool_registry, tool_name) orelse unreachable) {
        .eligible => |metadata| metadata.action_label,
        .ineligible => unreachable,
    };
}

test "formatToolStatusWithStats accents the +/- counts and falls back to neutral" {
    const alloc = std.testing.allocator;

    const colored = try formatToolStatusWithStats(alloc, "Edited x", 3, 1, .{ .added = "[G]", .removed = "[R]" });
    defer alloc.free(colored);
    try std.testing.expect(std.mem.find(u8, colored, "[G]+3") != null);
    try std.testing.expect(std.mem.find(u8, colored, "[R]-1") != null);

    const neutral = try formatToolStatusWithStats(alloc, "Edited x", 3, 1, .{});
    defer alloc.free(neutral);
    try std.testing.expect(std.mem.find(u8, neutral, "\x1b[38;5;252m+3") != null);
    try std.testing.expect(std.mem.find(u8, neutral, "\x1b[38;5;252m-1") != null);
}

test "provisional lifecycle preflight distinguishes unknown eligible and ineligible tools" {
    try std.testing.expect(ProvisionalToolStatuses.preflight(test_tool_registry, "unknown_tool") == null);

    for ([_][]const u8{ "ask_user_question", "write_file", "edit_file", "terminal", "run_command" }) |name| {
        const preflight = ProvisionalToolStatuses.preflight(test_tool_registry, name) orelse return error.TestExpectedEqual;
        switch (preflight) {
            .ineligible => {},
            .eligible => return error.TestExpectedEqual,
        }
    }

    const preflight = ProvisionalToolStatuses.preflight(test_tool_registry, "read_file") orelse return error.TestExpectedEqual;
    switch (preflight) {
        .eligible => |metadata| try std.testing.expectEqualStrings("Reading", metadata.action_label),
        .ineligible => return error.TestExpectedEqual,
    }

    for ([_][]const u8{ "perplexity_search", "parallel_search" }) |name| {
        const provider_preflight = ProvisionalToolStatuses.preflight(test_tool_registry, name) orelse return error.TestExpectedEqual;
        switch (provider_preflight) {
            .eligible => |metadata| try std.testing.expectEqualStrings("Searching", metadata.action_label),
            .ineligible => return error.TestExpectedEqual,
        }
    }
}

test "stream start execution certainty follows provider ownership" {
    const provider_registry = tool_dispatch.Registry{
        .tools = &.{test_builtin_tools.web_search},
    };

    try std.testing.expect(!streamStartMayHaveExecutedAtProvider(
        test_tool_registry,
        "read_file",
    ));
    try std.testing.expect(streamStartMayHaveExecutedAtProvider(
        provider_registry,
        "web_search",
    ));
    try std.testing.expect(streamStartMayHaveExecutedAtProvider(
        test_tool_registry,
        "perplexity_search",
    ));
    try std.testing.expect(streamStartMayHaveExecutedAtProvider(
        test_tool_registry,
        "parallel_search",
    ));
}

test "tool lifecycle uses activity metadata from the supplied registry" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var capture = ProvisionalStatusTestCapture{
        .alloc = alloc,
        .tool_registry = custom_activity_registry,
    };
    defer capture.deinit();
    const hooks = capture.hooks();

    const preflight = ProvisionalToolStatuses.preflight(hooks.tool_registry, "custom_activity") orelse return error.TestExpectedEqual;
    switch (preflight) {
        .eligible => |metadata| {
            try std.testing.expectEqualStrings("Custom activity", metadata.action_label);
            try std.testing.expectEqual(types.ToolActivityKind.open, metadata.activity_kind);
        },
        .ineligible => return error.TestExpectedEqual,
    }

    try std.testing.expect(try startToolVisibleLifecycle(
        &hooks,
        arena,
        1,
        null,
        testToolCall("custom_1", "custom_activity"),
        null,
        &.{},
    ));
    try std.testing.expectEqual(types.ToolActivityKind.open, capture.events.items[0].authoritative_started.activity_kind);
}

test "memory list authoritative lifecycle is classified as a read" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var capture = ProvisionalStatusTestCapture{
        .alloc = alloc,
        .tool_registry = .{ .tools = &.{test_builtin_tools.memory} },
    };
    defer capture.deinit();
    const hooks = capture.hooks();

    try std.testing.expect(try startToolVisibleLifecycle(
        &hooks,
        arena,
        1,
        null,
        .{
            .id = "memory_list",
            .name = "memory",
            .arguments_json = "{\"action\":\"list\"}",
        },
        null,
        &.{},
    ));

    switch (capture.events.items[0]) {
        .authoritative_started => |event| try std.testing.expectEqual(
            types.ToolActivityKind.read,
            event.activity_kind,
        ),
        else => return error.TestExpectedEqual,
    }
}

test "presentation grouping spans silent tool steps and splits on visible prose" {
    const first = presentationGroupForStep(null, 7, 11);
    try std.testing.expectEqual(
        types.ToolPresentationGroupId{ .turn_id = 7, .anchor_step_id = 11 },
        first,
    );
    const first_transition = transitionPresentationGroup(
        null,
        first,
        7,
        11,
        .{
            .has_visible_tool_calls = true,
            .has_visible_text = false,
            .saw_tool_start = false,
            .saw_visible_text_after_tool_start = false,
        },
    );
    const inherited = presentationGroupForStep(first_transition.active_group_id, 7, 12);
    try std.testing.expectEqual(first, inherited);

    const visible_transition = transitionPresentationGroup(
        first_transition.active_group_id,
        inherited,
        7,
        12,
        .{
            .has_visible_tool_calls = true,
            .has_visible_text = true,
            .saw_tool_start = false,
            .saw_visible_text_after_tool_start = false,
        },
    );
    try std.testing.expectEqual(
        types.ToolPresentationGroupId{ .turn_id = 7, .anchor_step_id = 12 },
        visible_transition.tool_group_id.?,
    );
    try std.testing.expectEqual(
        visible_transition.tool_group_id,
        visible_transition.active_group_id,
    );
}

test "visible prose after streamed tools closes the group for the next step" {
    const current = types.ToolPresentationGroupId{
        .turn_id = 7,
        .anchor_step_id = 11,
    };
    const transition = transitionPresentationGroup(
        current,
        current,
        7,
        11,
        .{
            .has_visible_tool_calls = true,
            .has_visible_text = true,
            .saw_tool_start = true,
            .saw_visible_text_after_tool_start = true,
        },
    );

    try std.testing.expectEqual(current, transition.tool_group_id.?);
    try std.testing.expect(transition.active_group_id == null);
}

test "provisional lifecycle formats labeled and unlabeled eligible tools" {
    const alloc = std.testing.allocator;
    var capture = ProvisionalStatusTestCapture{ .alloc = alloc };
    defer capture.deinit();
    const hooks = capture.hooks();
    var statuses = ProvisionalToolStatuses{};
    defer statuses.deinit(alloc);

    try statuses.publish(&hooks, alloc, 7, "read_1", "read_file", activityKind(hooks.tool_registry, "read_file"), eligibleActionLabel("read_file"), "src/main.zig");
    try statuses.publish(&hooks, alloc, 7, "list_1", "list_files", activityKind(hooks.tool_registry, "list_files"), eligibleActionLabel("list_files"), null);

    try std.testing.expectEqual(@as(usize, 4), capture.events.items.len);
    switch (capture.events.items[0]) {
        .provisional => |event| {
            try std.testing.expectEqual(@as(u64, 7), event.id.turn_id);
            try std.testing.expectEqualStrings("read_1", event.id.call_id);
            try std.testing.expectEqualStrings("read_file", event.tool_name.?);
            try std.testing.expectEqual(types.ToolActivityKind.read, event.activity_kind);
        },
        else => return error.TestExpectedEqual,
    }
    switch (capture.events.items[1]) {
        .progress => |event| try std.testing.expectEqualStrings(
            "● Reading\x1b[0m \x1b[38;5;245msrc/main.zig\x1b[0m",
            event.text,
        ),
        else => return error.TestExpectedEqual,
    }
    switch (capture.events.items[2]) {
        .provisional => |event| try std.testing.expectEqualStrings("list_1", event.id.call_id),
        else => return error.TestExpectedEqual,
    }
    switch (capture.events.items[3]) {
        .progress => |event| try std.testing.expectEqualStrings("● Listing\x1b[0m", event.text),
        else => return error.TestExpectedEqual,
    }
}

test "tracked provisional cancellation retains labels without exposing registered names" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var capture = ProvisionalStatusTestCapture{ .alloc = alloc };
    defer capture.deinit();
    const hooks = capture.hooks();
    var statuses = ProvisionalToolStatuses{};
    defer statuses.deinit(alloc);

    try statuses.publish(&hooks, alloc, 9, "read_1", "read_file", .read, "Reading", null);
    try statuses.publish(&hooks, alloc, 9, "read_1", "read_file", .read, "Reading", "src/main.zig");
    try statuses.publish(&hooks, alloc, 9, "command_1", "run_command", .command, "Running", null);
    try statuses.publish(&hooks, alloc, 9, "mcp_1", "mcp_custom", .read, "Running", null);
    try statuses.finishTrackedCancelled(&hooks, alloc, arena, 9);

    var terminal_count: usize = 0;
    for (capture.events.items) |event| {
        if (event != .terminal) continue;
        terminal_count += 1;
        try std.testing.expectEqual(types.ToolOutcomeKind.cancelled, event.terminal.outcome.kind);
        if (std.mem.eql(u8, event.terminal.id.call_id, "read_1")) {
            try std.testing.expectEqualStrings("Cancelled src/main.zig", event.terminal.outcome.summary);
        } else if (std.mem.eql(u8, event.terminal.id.call_id, "command_1")) {
            try std.testing.expectEqualStrings("Cancelled tool call", event.terminal.outcome.summary);
        } else if (std.mem.eql(u8, event.terminal.id.call_id, "mcp_1")) {
            try std.testing.expectEqualStrings("Cancelled mcp_custom", event.terminal.outcome.summary);
        } else {
            return error.TestUnexpectedToolCallId;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), terminal_count);
    try std.testing.expectEqual(@as(usize, 0), statuses.tracked.items.len);

    const event_count = capture.events.items.len;
    try statuses.finishTrackedCancelled(&hooks, alloc, arena, 9);
    try std.testing.expectEqual(event_count, capture.events.items.len);
}

test "unmatched recovery starts hide registered names but retain unknown identities" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var capture = ProvisionalStatusTestCapture{ .alloc = alloc };
    defer capture.deinit();
    const hooks = capture.hooks();
    var statuses = ProvisionalToolStatuses{};
    defer statuses.deinit(alloc);

    try statuses.publish(&hooks, alloc, 9, "command_1", "run_command", .command, "Running", null);
    try statuses.publish(&hooks, alloc, 9, "mcp_1", "mcp_custom", .read, "Running", null);
    try statuses.finishUnmatchedRecoveryStarts(&hooks, alloc, arena, 9, &.{});

    var terminal_count: usize = 0;
    for (capture.events.items) |event| {
        if (event != .terminal) continue;
        terminal_count += 1;
        if (std.mem.eql(u8, event.terminal.id.call_id, "command_1")) {
            try std.testing.expectEqualStrings(
                "Connection interrupted before tool call ran",
                event.terminal.outcome.summary,
            );
        } else if (std.mem.eql(u8, event.terminal.id.call_id, "mcp_1")) {
            try std.testing.expectEqualStrings(
                "Connection interrupted before mcp_custom ran",
                event.terminal.outcome.summary,
            );
        } else {
            return error.TestUnexpectedToolCallId;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), terminal_count);
}

test "provisional lifecycle remains distinct from authoritative lifecycle" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var capture = ProvisionalStatusTestCapture{ .alloc = alloc };
    defer capture.deinit();
    const hooks = capture.hooks();
    var statuses = ProvisionalToolStatuses{
        .presentation_group_id = .{ .turn_id = 1, .anchor_step_id = 9 },
    };
    defer statuses.deinit(alloc);

    const call = testToolCall("read_1", "read_file");
    try statuses.publish(&hooks, alloc, 1, call.id, call.name, activityKind(hooks.tool_registry, call.name), eligibleActionLabel(call.name), null);
    try std.testing.expect(try startToolVisibleLifecycle(
        &hooks,
        arena,
        1,
        statuses.presentation_group_id,
        call,
        null,
        &.{},
    ));

    switch (capture.events.items[0]) {
        .provisional => |event| try std.testing.expectEqual(
            types.ToolPresentationGroupId{ .turn_id = 1, .anchor_step_id = 9 },
            event.presentation_group_id.?,
        ),
        else => return error.TestExpectedEqual,
    }
    switch (capture.events.items[2]) {
        .authoritative_started => |event| {
            try std.testing.expectEqualStrings("read_1", event.id.call_id);
            try std.testing.expect(event.reconciles_provisional_call_id == null);
            try std.testing.expectEqual(
                types.ToolPresentationGroupId{ .turn_id = 1, .anchor_step_id = 9 },
                event.presentation_group_id.?,
            );
        },
        else => return error.TestExpectedEqual,
    }
}

test "provisional lifecycle rolls back a newly tracked id when provisional publication fails" {
    const alloc = std.testing.allocator;
    var capture = ProvisionalStatusTestCapture{ .alloc = alloc, .fail_provisional = true };
    defer capture.deinit();
    const hooks = capture.hooks();
    var statuses = ProvisionalToolStatuses{};
    defer statuses.deinit(alloc);

    try std.testing.expectError(
        error.TestProvisionalPublicationFailure,
        statuses.publish(&hooks, alloc, 1, "read_1", "read_file", activityKind(hooks.tool_registry, "read_file"), eligibleActionLabel("read_file"), null),
    );
    try std.testing.expect(!statuses.has("read_1"));
    try std.testing.expectEqual(@as(usize, 0), capture.events.items.len);
}

test "provisional lifecycle keeps a tracked id when progress publication fails" {
    const alloc = std.testing.allocator;
    var capture = ProvisionalStatusTestCapture{ .alloc = alloc, .fail_progress = true };
    defer capture.deinit();
    const hooks = capture.hooks();
    var statuses = ProvisionalToolStatuses{};
    defer statuses.deinit(alloc);

    try statuses.publish(&hooks, alloc, 1, "read_1", "read_file", activityKind(hooks.tool_registry, "read_file"), eligibleActionLabel("read_file"), null);
    try std.testing.expect(statuses.has("read_1"));
    try std.testing.expectEqual(@as(usize, 1), capture.events.items.len);
    try std.testing.expect(capture.events.items[0] == .provisional);
}

test "rejected completion ignores a tracked provisional id when final id is untracked" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var capture = ProvisionalStatusTestCapture{ .alloc = alloc };
    defer capture.deinit();
    const hooks = capture.hooks();
    var statuses = ProvisionalToolStatuses{};
    defer statuses.deinit(alloc);

    _ = try statuses.record(alloc, "provisional_read");
    const calls = [_]ToolCall{.{
        .id = "final_read",
        .provisional_id = "provisional_read",
        .name = "read_file",
        .arguments_json = "{}",
    }};
    try statuses.finishRejectedCompletions(&hooks, arena, 1, &calls, &.{});

    try std.testing.expectEqual(@as(usize, 0), capture.events.items.len);

    _ = try statuses.record(alloc, "final_read");
    try statuses.finishRejectedCompletions(&hooks, arena, 1, &calls, &.{});
    try std.testing.expectEqual(@as(usize, 1), capture.events.items.len);
    switch (capture.events.items[0]) {
        .terminal => |terminal| try std.testing.expectEqualStrings("final_read", terminal.id.call_id),
        else => return error.TestExpectedEqual,
    }
}

test "provisional lifecycle terminal matching prefers final id then provisional id" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var capture = ProvisionalStatusTestCapture{ .alloc = alloc };
    defer capture.deinit();
    const hooks = capture.hooks();
    var statuses = ProvisionalToolStatuses{};
    defer statuses.deinit(alloc);

    _ = try statuses.record(alloc, "provisional_read");
    const fallback_call = ToolCall{
        .id = "final_read",
        .provisional_id = "provisional_read",
        .name = "read_file",
        .arguments_json = "{}",
    };
    try std.testing.expectEqualStrings("provisional_read", statuses.visibleId(fallback_call).?);
    try statuses.finishMalformedToolArguments(&hooks, arena, 1, fallback_call);

    _ = try statuses.record(alloc, "final_read");
    try std.testing.expectEqualStrings("final_read", statuses.visibleId(fallback_call).?);

    const provider_calls = [_]ToolCall{.{
        .id = "provider_final",
        .provisional_id = "provisional_read",
        .name = "read_file",
        .arguments_json = "{}",
        .argument_integrity = .malformed_json,
        .provenance = .provider_executed,
    }};
    try statuses.finishMalformedProviderToolArguments(&hooks, arena, 1, &provider_calls);

    _ = try statuses.record(alloc, "mcp_invalid");
    try statuses.finishMalformedToolArguments(&hooks, arena, 1, .{
        .id = "mcp_invalid",
        .name = "mcp_lookup",
        .arguments_json = "{",
    });

    try std.testing.expectEqual(@as(usize, 3), capture.events.items.len);
    for (capture.events.items) |event| {
        switch (event) {
            .terminal => |terminal| {
                if (std.mem.eql(u8, terminal.id.call_id, "mcp_invalid")) {
                    try std.testing.expectEqualStrings("mcp_lookup failed: invalid JSON arguments", terminal.outcome.summary);
                } else {
                    try std.testing.expectEqualStrings("provisional_read", terminal.id.call_id);
                    try std.testing.expectEqualStrings("tool call failed: invalid JSON arguments", terminal.outcome.summary);
                }
            },
            else => return error.TestExpectedEqual,
        }
    }
}

test "admitted provisional settlement consumes visible identity exactly once" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var capture = ProvisionalStatusTestCapture{ .alloc = alloc };
    defer capture.deinit();
    const hooks = capture.hooks();
    var statuses = ProvisionalToolStatuses{};
    defer statuses.deinit(alloc);

    _ = try statuses.record(alloc, "provisional_read");
    const call = ToolCall{
        .id = "final_read",
        .provisional_id = "provisional_read",
        .name = "read_file",
        .arguments_json = "{}",
    };
    try std.testing.expect(try statuses.settleAdmittedCall(
        &hooks,
        alloc,
        arena,
        7,
        call,
        "Not executed",
        &.{},
    ));
    try std.testing.expect(!try statuses.settleAdmittedCall(
        &hooks,
        alloc,
        arena,
        7,
        call,
        "Not executed",
        &.{},
    ));
    try std.testing.expectEqual(@as(usize, 0), statuses.tracked.items.len);
    try std.testing.expectEqual(@as(usize, 1), capture.events.items.len);
    switch (capture.events.items[0]) {
        .terminal => |terminal| {
            try std.testing.expectEqualStrings("provisional_read", terminal.id.call_id);
            try std.testing.expectEqual(types.ToolOutcomeKind.denied, terminal.outcome.kind);
            try std.testing.expect(std.mem.find(u8, terminal.outcome.summary, "Not executed") != null);
        },
        else => return error.TestExpectedEqual,
    }
}

test "failed admitted settlement keeps identity when terminal publication fails" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var capture = ProvisionalStatusTestCapture{ .alloc = alloc, .fail_terminal = true };
    defer capture.deinit();
    const hooks = capture.hooks();
    var statuses = ProvisionalToolStatuses{};
    defer statuses.deinit(alloc);

    _ = try statuses.record(alloc, "read_1");
    const call = testToolCall("read_1", "read_file");
    try std.testing.expectError(
        error.TestTerminalPublicationFailure,
        statuses.settleAdmittedCall(&hooks, alloc, arena, 1, call, "Failed", &.{}),
    );
    try std.testing.expect(statuses.has("read_1"));
}

fn checkProvisionalLifecycleAllocationFailures(alloc: Allocator) !void {
    var capture = ProvisionalStatusTestCapture{ .alloc = alloc, .retain_events = false };
    defer capture.deinit();
    const hooks = capture.hooks();
    var statuses = ProvisionalToolStatuses{};
    defer statuses.deinit(alloc);

    try statuses.publish(&hooks, alloc, 1, "read_1", "read_file", activityKind(hooks.tool_registry, "read_file"), eligibleActionLabel("read_file"), null);
    try std.testing.expect(statuses.has("read_1"));
}

test "provisional lifecycle cleans up every copied-id allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkProvisionalLifecycleAllocationFailures,
        .{},
    );
}

test "native web_search completion status includes searches and duration" {
    const line = try formatWebSearchCompletion(std.testing.allocator, "Searched current news", .{
        .searches = 2,
        .duration_ms = 17,
    });
    defer std.testing.allocator.free(line);

    try std.testing.expect(std.mem.find(u8, line, "2 searches") != null);
    try std.testing.expect(std.mem.find(u8, line, "17ms") != null);
}

test "provider search completion keeps terminal result detail" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var capture = ProvisionalStatusTestCapture{ .alloc = alloc };
    defer capture.deinit();
    const hooks = capture.hooks();

    const safe_result = "{\"results\":[{\"url\":\"https://example.test/source\"}]}";
    try finishExecutedToolStatus(
        &hooks,
        arena,
        3,
        .{
            .id = "provider_search",
            .name = "perplexity_search",
            .arguments_json = "{}",
            .provenance = .provider_executed,
        },
        true,
        null,
        .{ .status = .success, .model_output = safe_result },
        safe_result,
        .{ .output_bytes = safe_result.len, .stored_output_bytes = safe_result.len },
        null,
        &.{},
    );

    try std.testing.expectEqual(@as(usize, 1), capture.events.items.len);
    switch (capture.events.items[0]) {
        .terminal => |terminal| {
            try std.testing.expect(terminal.result != null);
            try std.testing.expect(std.mem.find(u8, terminal.result.?, "https://example.test/source") != null);
        },
        else => return error.TestExpectedEqual,
    }
}

test "file edit preflight failure reports the exact mismatch" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var capture = ProvisionalStatusTestCapture{ .alloc = alloc };
    defer capture.deinit();
    const hooks = capture.hooks();
    const failure = "edit_file failed: old_string not found in file";

    try finishExecutedToolStatus(
        &hooks,
        arena,
        4,
        .{ .id = "edit_preflight", .name = "edit_file", .arguments_json = "{}" },
        true,
        null,
        .{
            .status = .failure,
            .model_output = failure,
            .status_detail = "preflight failed",
        },
        failure,
        .{ .output_bytes = failure.len, .stored_output_bytes = failure.len },
        null,
        &.{},
    );

    try std.testing.expectEqual(@as(usize, 1), capture.events.items.len);
    const terminal = capture.events.items[0].terminal;
    try std.testing.expectEqual(types.ToolOutcomeKind.failed, terminal.outcome.kind);
    try std.testing.expectEqualStrings(
        "Failed edit_file: old_string not found in file",
        terminal.outcome.summary,
    );
}

test "dynamic MCP failure derives a bounded terminal-safe detail from the safe result" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var capture = ProvisionalStatusTestCapture{ .alloc = alloc };
    defer capture.deinit();
    const hooks = capture.hooks();
    const failure =
        \\{"server":"plain","tool":"mcp_plain_getThreads","result":{"resultType":"complete","isError":true,"content":[{"type":"text","text":"Invalid input: labels require at least one item\nretry rejected"}]}}
    ;
    const advertised = [_][]const u8{"mcp_plain_getThreads"};

    try finishExecutedToolStatus(
        &hooks,
        arena,
        7,
        .{
            .id = "plain_failure",
            .name = "mcp_plain_getThreads",
            .arguments_json = "{}",
        },
        true,
        null,
        .{ .status = .failure, .model_output = failure },
        failure,
        .{ .output_bytes = failure.len, .stored_output_bytes = failure.len },
        null,
        &advertised,
    );

    const terminal = capture.events.items[0].terminal;
    try std.testing.expectEqual(types.ToolOutcomeKind.failed, terminal.outcome.kind);
    try std.testing.expectEqualStrings(
        "Failed mcp_plain_getThreads: Invalid input: labels require at least one item\\x0aretry rejected",
        terminal.outcome.summary,
    );
}

test "terminal path scope failure appends the exact status detail" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var capture = ProvisionalStatusTestCapture{ .alloc = alloc };
    defer capture.deinit();
    var hooks = capture.hooks();
    hooks.describe_tool_action_denied = struct {
        fn describe(
            _: *anyopaque,
            target: Allocator,
            _: ToolCall,
            _: ?[]const u8,
            label: []const u8,
            _: []const []const u8,
        ) ![]const u8 {
            return std.fmt.allocPrint(target, "{s} start", .{label});
        }
    }.describe;
    const failure = "{\"failure\":{\"action\":\"start\",\"code\":\"path_outside_workspace\"}}";

    try finishExecutedToolStatus(
        &hooks,
        arena,
        5,
        .{
            .id = "terminal_path_scope",
            .name = "terminal",
            .arguments_json = "{\"action\":\"start\"}",
        },
        true,
        null,
        .{
            .status = .failure,
            .model_output = failure,
            .status_detail = "path is outside the workspace",
        },
        failure,
        .{ .output_bytes = failure.len, .stored_output_bytes = failure.len },
        null,
        &.{},
    );

    try std.testing.expectEqual(@as(usize, 1), capture.events.items.len);
    const terminal = capture.events.items[0].terminal;
    try std.testing.expectEqual(types.ToolOutcomeKind.failed, terminal.outcome.kind);
    try std.testing.expectEqualStrings(
        "Failed start: path is outside the workspace",
        terminal.outcome.summary,
    );
}

test "command completion publishes its combined artifact handle" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var capture = ProvisionalStatusTestCapture{ .alloc = alloc };
    defer capture.deinit();
    const hooks = capture.hooks();

    try finishExecutedToolStatus(
        &hooks,
        arena,
        4,
        .{ .id = "command", .name = "run_command", .arguments_json = "{}" },
        true,
        null,
        .{
            .model_output = "truncated command preview",
            .command_result_json =
            \\{"kind":"foreground","output_file":"/tmp/fx-command-combined.log"}
            ,
        },
        "truncated command preview",
        .{
            .output_bytes = 1_000_000,
            .stored_output_bytes = 128_000,
            .truncated = true,
            .command_output_replay = .{ .available = .{
                .handle = "fx-command-replay-terminal.bin",
                .framed_bytes = 123,
            } },
        },
        null,
        &.{},
    );

    try std.testing.expectEqual(@as(usize, 1), capture.events.items.len);
    switch (capture.events.items[0]) {
        .terminal => |terminal| {
            try std.testing.expectEqualStrings(
                "truncated command preview",
                terminal.result.?,
            );
            try std.testing.expectEqualStrings(
                "fx-command-combined.log",
                terminal.command_artifact_handle.?,
            );
            const replay = terminal.result_memory.?.command_output_replay.?;
            const descriptor = switch (replay) {
                .available => |value| value,
                .unavailable => return error.TestExpectedReplay,
            };
            try std.testing.expectEqualStrings(
                "fx-command-replay-terminal.bin",
                descriptor.handle,
            );
            try std.testing.expectEqual(@as(usize, 123), descriptor.framed_bytes);
        },
        else => return error.TestExpectedEqual,
    }
}

test "nonzero command process is presented as Ran without changing model failure" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var capture = ProvisionalStatusTestCapture{ .alloc = alloc };
    defer capture.deinit();
    const hooks = capture.hooks();

    try finishExecutedToolStatus(
        &hooks,
        arena_state.allocator(),
        6,
        .{ .id = "command_nonzero", .name = "run_command", .arguments_json = "{}" },
        true,
        null,
        .{ .status = .failure, .model_output = "tool_execution_failed" },
        "tool_execution_failed",
        .{
            .output_bytes = 21,
            .stored_output_bytes = 21,
            .command_process_presentation = .{ .exit_code = 7 },
        },
        null,
        &.{},
    );

    const terminal = capture.events.items[0].terminal;
    try std.testing.expectEqual(types.ToolOutcomeKind.completed, terminal.outcome.kind);
    try std.testing.expectEqualStrings("started run_command", terminal.outcome.summary);
    try std.testing.expectEqualStrings("tool_execution_failed", terminal.result.?);
    try std.testing.expectEqual(
        types.CommandProcessPresentation{ .exit_code = 7 },
        terminal.result_memory.?.command_process_presentation.?,
    );
}

test "cancelled command ignores malformed artifact metadata" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var capture = ProvisionalStatusTestCapture{ .alloc = alloc };
    defer capture.deinit();
    const hooks = capture.hooks();

    try finishCancelledToolStatus(
        &hooks,
        arena_state.allocator(),
        5,
        .{ .id = "command", .name = "run_command", .arguments_json = "{}" },
        true,
        null,
        .{
            .status = .failure,
            .cancelled = true,
            .model_output = "command cancelled\n",
            .command_result_json = "{",
        },
        &.{},
    );

    try std.testing.expectEqual(@as(usize, 1), capture.events.items.len);
    const terminal = capture.events.items[0].terminal;
    try std.testing.expectEqual(types.ToolOutcomeKind.cancelled, terminal.outcome.kind);
    try std.testing.expect(terminal.command_artifact_handle == null);
}
