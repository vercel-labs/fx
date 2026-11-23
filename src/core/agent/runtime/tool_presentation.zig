const std = @import("std");
const toolbox = @import("../../tooling/toolbox.zig");
const testing_allocator = @import("../../shared/testing_allocator.zig");
const command_admission = @import("../../permissions/command_admission.zig");
const managed_execution = @import("../../execution/managed_execution.zig");
const permission_auto_classifier = @import("../../permissions/auto_classifier.zig");
const types = @import("../../shared/types.zig");
const shared_theme = @import("../../shared/theme.zig");
const text_utils = @import("../../shared/text_utils.zig");
const tool_dispatch = @import("../../tooling/tool_dispatch.zig");
const tool_args = @import("../../tooling/tool_args.zig");
const tool_specs = @import("../../tooling/tool_specs.zig");
const tooling_presentation = @import("../../tooling/tool_presentation.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const mcp_tool_result = @import("../../mcp/tool_result.zig");
const result_store = @import("../../session/result_store.zig");
const diff = @import("../../output/diff.zig");
const file_mutation_contract = @import("../../tooling/file_mutation_contract.zig");
const tool_result_errors = @import("../../tooling/tool_result_errors.zig");
const tool_result_display = @import("../../tooling/tool_result_display.zig");
const read_result_presentation = @import("../../tooling/read_tool_result_presentation.zig");
const command_result_mapping = if (@import("builtin").is_test)
    @import("../../tooling/command_result_mapping.zig")
else
    struct {};
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

/// Whether a tool that may run at the provider only reads, as a search does,
/// so running it again after a failed attempt is safe.
pub fn providerToolOnlyReads(
    registry: tool_dispatch.Registry,
    tool_name: []const u8,
) bool {
    if (isProviderSearchAlias(tool_name)) return true;
    const spec = registry.lookup(tool_name) orelse return false;
    return spec.provider_executed and spec.activity_kind == .read;
}

fn fallbackToolDisplay(
    registry: tool_dispatch.Registry,
    tool_name: []const u8,
) []const u8 {
    // Provider-executed search backends are never registered locally; their
    // stream names (exa_search, ...) are internal identifiers, not display copy.
    if (tooling_presentation.isProviderSearchAlias(tool_name)) return "web search";
    const lookup_name = if (std.mem.eql(u8, tool_name, "run_command"))
        "shell"
    else
        tool_name;
    return if (registry.lookup(lookup_name) != null) "tool call" else tool_name;
}

pub const ProvisionalToolStatuses = struct {
    const TrackedStatus = struct {
        id: []u8,
        tool_name: []u8,
        label_value: ?[]u8,
        /// Whether the call's row was published. A toolbox call's row waits,
        /// hidden, until its arguments name what it does.
        shown: bool = true,

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
            "shell"
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
        arguments_json: ?[]const u8,
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
        var scratch = std.heap.ArenaAllocator.init(alloc);
        defer scratch.deinit();
        // A toolbox call's row, once its arguments arrive, reads as what it
        // opens, runs, or searches, since the first string in them may be
        // any of those.
        const is_toolbox = std.mem.eql(u8, tool_name, toolbox.tool_name);
        var observed_label = if (is_toolbox) null else label_value;
        var observed_kind = activity_kind;
        var shown_tool_name = tool_name;
        const argument_label: ?[]const u8 = if (is_toolbox) resource: {
            const json = arguments_json orelse break :resource null;
            if (try toolboxBuiltinRunRow(scratch.allocator(), hooks.tool_registry, json, &buf)) |row| {
                observed_label = row.label_value;
                observed_kind = row.activity_kind;
                shown_tool_name = row.tool_name;
                break :resource row.label;
            }
            // While the arguments stream in they do not parse yet, but the
            // action and the whole name after it already say what the call
            // does, so its row does not read as a bare "Using" until they end.
            const args = tool_args.parseToolArgsObject(scratch.allocator(), json) catch streamed: {
                const action = tooling_presentation.toolboxStreamedAction(scratch.allocator(), json) catch break :resource null;
                break :streamed tool_args.parseToolArgsObject(scratch.allocator(), action orelse break :resource null) catch break :resource null;
            };
            const spec = hooks.tool_registry.lookup(tool_name) orelse break :resource null;
            const presentation = tool_dispatch.presentationForArgs(spec.*, args);
            const value = tool_dispatch.presentationLabelValue(presentation, args) orelse break :resource null;
            const encoded = text_utils.encodeTerminalSafe(scratch.allocator(), value, buf.len) catch break :resource null;
            if (encoded.truncated) break :resource null;
            const formatted = formatProvisionalProgressLabel(&buf, presentation.action_label, encoded.bytes) catch break :resource null;
            observed_label = value;
            observed_kind = presentation.activity_kind;
            break :resource formatted;
        } else null;
        // A subagent call's row names its subagent once its arguments hold
        // the name, while they stream in or once complete, and keeps a name
        // it already shows; the first string in them is its action.
        const is_subagent = std.mem.eql(u8, tool_name, "subagent");
        if (is_subagent) {
            observed_label = tooling_presentation.subagentStreamedAgent(arguments_json orelse "") orelse self.trackedLabel(tool_id);
        }
        // Any other builtin call's row names its target, such as the file a
        // read opens, once that value streams in.
        const builtin = hooks.tool_registry.lookup(tool_name);
        const streamed_value = if (builtin) |spec| if (!is_toolbox and !is_subagent and observed_label == null)
            tooling_presentation.streamedLabelValue(spec.label_arg_kind, arguments_json orelse "")
        else
            null else null;
        if (streamed_value) |value| observed_label = value;
        const shown_label = if (is_subagent and observed_label != null)
            (try text_utils.encodeTerminalSafe(scratch.allocator(), observed_label.?, 64)).bytes
        else if (streamed_value) |value|
            (try text_utils.encodeTerminalSafe(scratch.allocator(), value, 240)).bytes
        else
            observed_label;
        const label = argument_label orelse try formatProvisionalProgressLabel(&buf, action_label, shown_label);
        const recorded = try self.recordTracked(
            alloc,
            tool_id,
            tool_name,
            observed_label,
        );
        const index = self.findTracked(tool_id).?;
        // A toolbox call says nothing about itself until its arguments name
        // what it opens, runs, or searches, so its row never reads a bare
        // "Using": it stays hidden until that name streams in, or until the
        // call itself starts.
        if (is_toolbox and argument_label == null) {
            if (recorded) self.tracked.items[index].shown = false;
            return;
        }
        self.tracked.items[index].shown = true;
        hooks.push_tool_lifecycle(hooks.ctx, .{
            .provisional = .{
                .id = .{ .turn_id = turn_id, .call_id = tool_id },
                .presentation_group_id = self.presentation_group_id,
                .tool_name = shown_tool_name,
                .activity_kind = observed_kind,
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

    /// Names a streaming call's row as soon as its arguments so far say what
    /// it is for, while the rest of the call streams in: the subagent a
    /// `subagent` call is for once its whole name is in, so the row reads
    /// `Managing reviewer`, and what a `toolbox` call searches or opens
    /// once that whole value is in, so the row reads `Opening fixture`. A
    /// toolbox run of a builtin tool waits, hidden, until that tool's own
    /// target is in too, so the row reads `Matching *.md` as a direct
    /// glob_files call does. A row already named stays as it is.
    pub fn observeArguments(
        self: *ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        alloc: Allocator,
        turn_id: u64,
        tool_id: []const u8,
        arguments: []const u8,
    ) !void {
        const index = self.findTracked(tool_id) orelse return;
        const status = self.tracked.items[index];
        if (status.label_value != null) return;
        if (std.mem.eql(u8, status.tool_name, "subagent")) {
            if (tooling_presentation.subagentStreamedAgent(arguments) == null) return;
        } else if (std.mem.eql(u8, status.tool_name, toolbox.tool_name)) {
            const action = try tooling_presentation.toolboxStreamedAction(alloc, arguments) orelse return;
            alloc.free(action);
        } else {
            const spec = hooks.tool_registry.lookup(status.tool_name) orelse return;
            if (tooling_presentation.streamedLabelValue(spec.label_arg_kind, arguments) == null) return;
        }
        const metadata = switch (preflight(hooks.tool_registry, status.tool_name) orelse return) {
            .ineligible => return,
            .eligible => |metadata| metadata,
        };
        try self.publish(hooks, alloc, turn_id, status.id, status.tool_name, metadata.activity_kind, metadata.action_label, null, arguments);
    }

    fn trackedLabel(self: *const ProvisionalToolStatuses, id: []const u8) ?[]const u8 {
        const index = self.findTracked(id) orelse return null;
        return self.tracked.items[index].label_value;
    }

    pub fn finishMalformedToolArguments(
        self: *const ProvisionalToolStatuses,
        hooks: *const AgentRuntimeDeps,
        arena: Allocator,
        turn_id: u64,
        call: ToolCall,
    ) !void {
        const call_id = self.visibleId(call) orelse return;
        const summary = try arena.print(
            "{s} failed: {s}",
            .{ fallbackToolDisplay(hooks.tool_registry, call.name), if (call.argument_integrity == .non_object_json) "non-object arguments" else "invalid JSON arguments" },
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
            // A hidden call has no row to settle.
            if (self.hasTerminal(status.id) or !status.shown) {
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
            const summary = try arena.print("Cancelled {s}", .{encoded.bytes});
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
            // A hidden call has no row to settle.
            if (self.hasTerminal(status.id) or !status.shown) {
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
            const summary = try arena.print(
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

    /// Whether the call's row was published. A hidden call has no row to
    /// settle, so the call's own start shows it.
    fn has(self: *const ProvisionalToolStatuses, id: []const u8) bool {
        const index = self.findTracked(id) orelse return false;
        return self.tracked.items[index].shown;
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

/// How a streaming toolbox call's row reads when it runs a built-in tool.
const BuiltinRunRow = struct {
    /// The tool it runs, which the row is for.
    tool_name: []const u8,
    activity_kind: types.ToolActivityKind,
    /// The row's text, or null while the row stays hidden.
    label: ?[]const u8,
    /// What the row names, so it is not named again as more arguments
    /// arrive. Null while the row waits for the tool's target.
    label_value: ?[]const u8,
};

/// The row of a streaming toolbox call whose arguments so far, whole or
/// still streaming in, run a built-in tool (`toolbox.shownBuiltinRun`). It
/// reads as a direct call of that tool does once that call names its
/// target: the tool's verb and the target in the run's `arguments`, as in
/// `Fetching https://example.com/page`. Until both the tool and its target
/// are in, and for a tool whose direct call shows no row while it streams,
/// the row stays hidden, so it never reads as a bare verb, and the call's
/// own start shows it. Null for any other toolbox call. The label is
/// written into `buf`.
fn toolboxBuiltinRunRow(
    scratch: Allocator,
    registry: tool_dispatch.Registry,
    arguments_json: []const u8,
    buf: []u8,
) !?BuiltinRunRow {
    // While the arguments stream in, only the run's tool may be whole.
    const whole = if (tool_args.parseToolArgsObject(scratch, arguments_json)) |_| true else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => false,
    };
    const source = if (whole)
        arguments_json
    else
        (try tooling_presentation.toolboxStreamedAction(scratch, arguments_json)) orelse return null;
    const shown = (try toolbox.shownBuiltinRun(scratch, registry, .{ .id = "", .name = toolbox.tool_name, .arguments_json = source })) orelse return null;
    const spec = registry.lookup(shown.name) orelse return null;
    switch (ProvisionalToolStatuses.preflight(registry, shown.name) orelse return null) {
        .ineligible => return .{ .tool_name = shown.name, .activity_kind = spec.activity_kind, .label = null, .label_value = shown.name },
        .eligible => {},
    }
    // The target comes from the whole arguments once they parse, as the
    // call's start names it, and from the run's arguments while they stream
    // in, as a direct call's row reads its own.
    var action_label = spec.action_label;
    var activity_kind = spec.activity_kind;
    const target: ?[]const u8 = if (whole) parsed: {
        const args = tool_args.parseToolArgsObject(scratch, shown.arguments_json) catch break :parsed null;
        const presentation = tool_dispatch.presentationForArgs(spec.*, args);
        action_label = presentation.action_label;
        activity_kind = presentation.activity_kind;
        break :parsed tool_dispatch.presentationLabelValue(presentation, args);
    } else tooling_presentation.streamedRunLabelValue(spec.label_arg_kind, arguments_json);
    const value = target orelse "";
    if (value.len == 0) return .{ .tool_name = shown.name, .activity_kind = activity_kind, .label = null, .label_value = null };
    const encoded = try text_utils.encodeTerminalSafe(scratch, value, 240);
    return .{
        .tool_name = shown.name,
        .activity_kind = activity_kind,
        .label = try formatProvisionalProgressLabel(buf, action_label, encoded.bytes),
        .label_value = value,
    };
}

fn formatProvisionalProgressLabel(
    buf: []u8,
    action_label: []const u8,
    label_value: ?[]const u8,
) ![]const u8 {
    if (label_value) |value| {
        return std.mem.print(buf, "● {s}\x1b[0m {s}{s}\x1b[0m", .{ action_label, shared_theme.current().tool_stdout_style, value });
    }
    return std.mem.print(buf, "● {s}\x1b[0m", .{action_label});
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

/// The handles under which a tool result keeps its full output or images.
fn savedOutputHandles(
    output_handle: ?[]const u8,
    tool_image_handle: ?[]const u8,
    command_output_replay: ?types.CommandOutputReplay,
) [3]?[]const u8 {
    return .{
        output_handle,
        tool_image_handle,
        if (command_output_replay) |replay| switch (replay) {
            .available => |descriptor| descriptor.handle,
            .unavailable => null,
        } else null,
    };
}

/// Finds which call saved an output among a running prompt's messages: the
/// newest tool result that keeps the handle, and the call that produced it.
pub const TurnSavedOutputSources = struct {
    registry: tool_dispatch.Registry,
    workspace_root: []const u8,
    /// Message lists in conversation order, searched newest first.
    turns: []const []const types.ChatMessage,

    /// Returns the terminal-safe name of the call that saved `handle`, or null
    /// when no message still holds it. The arena owns the returned text.
    pub fn find(self: TurnSavedOutputSources, arena: Allocator, handle: []const u8) !?[]const u8 {
        var turn_index = self.turns.len;
        while (turn_index > 0) {
            turn_index -= 1;
            const messages = self.turns[turn_index];
            var message_index = messages.len;
            while (message_index > 0) {
                message_index -= 1;
                const message = messages[message_index];
                if (message.role != .tool) continue;
                const memory = message.tool_result_memory orelse continue;
                if (!holdsHandle(savedOutputHandles(memory.output_handle, memory.tool_image_handle, memory.command_output_replay), handle)) continue;
                const source = self.findCall(message.tool_call_id orelse return null) orelse return null;
                return tooling_presentation.savedOutputSourceLabel(arena, self.registry, self.workspace_root, source);
            }
        }
        return null;
    }

    fn findCall(self: TurnSavedOutputSources, call_id: []const u8) ?ToolCall {
        var turn_index = self.turns.len;
        while (turn_index > 0) {
            turn_index -= 1;
            const messages = self.turns[turn_index];
            var message_index = messages.len;
            while (message_index > 0) {
                message_index -= 1;
                const message = messages[message_index];
                if (message.role != .assistant) continue;
                for (message.tool_calls) |call| {
                    if (std.mem.eql(u8, call.id, call_id)) return call;
                }
            }
        }
        return null;
    }
};

/// Names of the calls whose saved output later `read_tool_result` calls read,
/// recorded while a saved conversation replays in order and keyed by output
/// handle. Owns its keys and names; free them with `deinit`.
pub const ReplayedSavedOutputSources = struct {
    map: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn deinit(self: *ReplayedSavedOutputSources, alloc: Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        self.map.deinit(alloc);
    }

    /// Records `call` under each handle that keeps `result`'s output. A later
    /// call saving the same handle wins.
    pub fn record(
        self: *ReplayedSavedOutputSources,
        alloc: Allocator,
        registry: tool_dispatch.Registry,
        workspace_root: []const u8,
        call: ToolCall,
        result: types.PersistedToolResult,
    ) Allocator.Error!void {
        const handles = savedOutputHandles(result.output_handle, result.tool_image_handle, result.command_output_replay);
        for (handles) |maybe_handle| {
            if (maybe_handle != null) break;
        } else return;
        const label = (try tooling_presentation.savedOutputSourceLabel(alloc, registry, workspace_root, call)) orelse return;
        defer alloc.free(label);
        for (handles) |maybe_handle| {
            const handle = maybe_handle orelse continue;
            const owned_handle = try alloc.dupe(u8, handle);
            errdefer alloc.free(owned_handle);
            const owned_label = try alloc.dupe(u8, label);
            errdefer alloc.free(owned_label);
            const gop = try self.map.getOrPut(alloc, owned_handle);
            if (gop.found_existing) {
                alloc.free(owned_handle);
                alloc.free(gop.value_ptr.*);
            }
            gop.value_ptr.* = owned_label;
        }
    }

    /// The name of the call that saved `handle`, borrowed from the map, for
    /// `readToolResultDisplayTarget`.
    pub fn find(self: *const ReplayedSavedOutputSources, _: Allocator, handle: []const u8) error{}!?[]const u8 {
        return self.map.get(handle);
    }
};

fn holdsHandle(handles: [3]?[]const u8, handle: []const u8) bool {
    for (handles) |candidate| {
        if (std.mem.eql(u8, candidate orelse continue, handle)) return true;
    }
    return false;
}

/// Row text for a `read_tool_result` call: what it reads, and the earlier
/// call whose output that is when `sources.find(arena, handle)` still knows
/// it. Returns null for other tools. The arena owns the returned text.
pub fn readToolResultDisplayTarget(
    arena: Allocator,
    registry: tool_dispatch.Registry,
    call: ToolCall,
    sources: anytype,
) !?[]const u8 {
    const spec = registry.lookup(call.name) orelse return null;
    if (spec.executor_kind != .read_tool_result) return null;
    const source = if (try read_result_presentation.requestedHandle(arena, call.arguments_json)) |handle|
        try sources.find(arena, handle)
    else
        null;
    return try read_result_presentation.displayTarget(arena, call.arguments_json, source);
}

test "read_tool_result rows name the earlier call whose output they read" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const registry = test_builtin_tools.advertisement_set.registry;
    const replay = "fx-command-replay-0123.bin";
    const earlier_turn = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = &.{.{
            .id = "read-1",
            .name = "read_file",
            .arguments_json = "{\"path\":\"src/main.zig\"}",
        }} },
        .{ .role = .tool, .tool_call_id = "read-1", .tool_result_memory = .{ .output_handle = "result-read_file-1.txt" } },
    };
    const current_turn = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = &.{.{
            .id = "run-1",
            .name = "shell",
            .arguments_json = "{\"action\":\"run\",\"command\":\"zig build test\"}",
        }} },
        .{ .role = .tool, .tool_call_id = "run-1", .tool_result_memory = .{
            .command_output_replay = .{ .available = .{ .handle = replay, .framed_bytes = 64 } },
        } },
    };
    const sources: TurnSavedOutputSources = .{
        .registry = registry,
        .workspace_root = "/workspace",
        .turns = &.{ earlier_turn[0..], current_turn[0..] },
    };
    const cases = [_]struct { arguments_json: []const u8, expected: ?[]const u8 }{
        .{ .arguments_json = "{\"request\":{\"handle\":\"" ++ replay ++ "\",\"start_byte\":9}}", .expected = "more output from zig build test" },
        .{ .arguments_json = "{\"request\":{\"handle\":\"" ++ replay ++ "\",\"query\":\"error:\"}}", .expected = "zig build test output for \"error:\"" },
        // The model may drop the `.txt` that `validate` restores.
        .{ .arguments_json = "{\"request\":{\"handle\":\"result-read_file-1\"}}", .expected = "more output from src/main.zig" },
        .{ .arguments_json = "{\"request\":{\"handle\":\"fx-command-replay-ffff.bin\"}}", .expected = null },
        .{ .arguments_json = "{\"request\":{\"handle\":\"T5\"}}", .expected = "earlier tool call T5" },
    };
    for (cases) |case| {
        const call: ToolCall = .{ .id = "page", .name = "read_tool_result", .arguments_json = case.arguments_json };
        const target = try readToolResultDisplayTarget(arena, registry, call, sources);
        if (case.expected) |expected| {
            try std.testing.expectEqualStrings(expected, target orelse return error.TestExpectedDisplayTarget);
        } else {
            try std.testing.expect(target == null);
        }
    }
    const other: ToolCall = .{ .id = "grep", .name = "grep_files", .arguments_json = "{\"pattern\":\"x\"}" };
    try std.testing.expect(try readToolResultDisplayTarget(arena, registry, other, sources) == null);
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
    const activity_line = if (call.argument_integrity == .valid) try hooks.describe_tool_action(
        hooks.ctx,
        arena,
        call,
        display_target,
        advertised_dynamic_tool_names,
    ) else null;
    try hooks.push_tool_lifecycle(hooks.ctx, .{ .authoritative_started = .{
        .id = .{ .turn_id = turn_id, .call_id = call.id },
        .presentation_group_id = presentation_group_id,
        .reconciles_provisional_call_id = call.provisional_id,
        .tool_name = call.name,
        .activity_kind = activity_kind,
        .arguments_json = redacted_arguments,
        .place_after_current_transcript = false,
        .resolved_display_target = call.resolved_display_target,
    } });
    if (activity_line) |line| {
        try hooks.push_tool_lifecycle(hooks.ctx, .{ .progress = .{
            .id = .{ .turn_id = turn_id, .call_id = call.id },
            .text = line,
        } });
    }
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
    const label = if (try isShellWaitCall(arena, call))
        "Stopped waiting for"
    else
        "Cancelled";
    const line = try hooks.describe_tool_action_denied(
        hooks.ctx,
        arena,
        call,
        display_target,
        label,
        advertised_dynamic_tool_names,
    );
    const command_activity = activityKindForCall(
        arena,
        hooks.tool_registry,
        call,
    ) == .command;
    const shell_command = command_activity and std.mem.eql(u8, call.name, "shell");
    const command_artifact_handle = if (command_activity and !shell_command)
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
        .result_memory = result.tool_result_memory,
        .command_artifact_handle = command_artifact_handle,
    } });
}

fn isShellWaitCall(arena: Allocator, call: ToolCall) Allocator.Error!bool {
    if (!std.mem.eql(u8, call.name, "shell")) return false;
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        arena,
        call.arguments_json,
        .{},
    ) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => false,
    };
    defer parsed.deinit();
    const outer = switch (parsed.value) {
        .object => |object| object,
        else => return false,
    };
    const object = (try tool_args.unwrapRequest(parsed.arena.allocator(), outer)) orelse return false;
    const action = switch (object.get("action") orelse return false) {
        .string => |value| value,
        else => return false,
    };
    return std.mem.eql(u8, action, "wait");
}

pub fn publishSubagentCompletionPreview(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    turn_id: u64,
    call: ToolCall,
    result: ToolExecutionResult,
    advertised_dynamic_tool_names: []const []const u8,
) !bool {
    if (!std.mem.eql(u8, call.name, "subagent")) return false;
    const base_line = if (try tooling_presentation.subagentStatusLine(
        arena,
        call,
        result.model_output,
    )) |line|
        try arena.print("● {s}", .{line})
    else switch (result.status) {
        .success => try hooks.describe_tool_action_completed(
            hooks.ctx,
            arena,
            call,
            null,
            advertised_dynamic_tool_names,
        ),
        .failure => try hooks.describe_tool_action_denied(
            hooks.ctx,
            arena,
            call,
            null,
            try tooling_presentation.subagentFailureLabel(
                arena,
                call,
                result.model_output,
            ),
            advertised_dynamic_tool_names,
        ),
    };
    const line = if (result.subagent_completion) |status|
        renderedSubagentSummary(hooks, arena, base_line, status)
    else
        base_line;
    try hooks.push_tool_lifecycle(hooks.ctx, .{ .progress = .{
        .id = .{ .turn_id = turn_id, .call_id = call.id },
        .text = line,
    } });
    return true;
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
    const command_decision = if (activity_kind == .command)
        (try commandOutcomeDecision(arena, result_memory.command_process_presentation)) orelse
            try runningCommandDecision(arena, call, result.model_output)
    else
        null;
    const terminal_action_decision = if (std.mem.eql(u8, call.name, "shell"))
        try terminalActionOutcomeDecision(arena, result_memory.terminal_action_presentation)
    else
        null;
    const outcome_decision = command_decision orelse terminal_action_decision;
    const base_line = if (try tooling_presentation.subagentStatusLine(arena, call, result.model_output)) |line|
        line
    else if (outcome_decision) |decision| blk: {
        const base = try hooks.describe_tool_action_denied(
            hooks.ctx,
            arena,
            call,
            display_target,
            decision.label,
            advertised_dynamic_tool_names,
        );
        break :blk if (decision.detail) |detail|
            try arena.print("{s}: {s}", .{ base, detail })
        else
            base;
    } else switch (result.status) {
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
                try tooling_presentation.subagentFailureLabel(arena, call, safe_result),
                advertised_dynamic_tool_names,
            );
            if (std.mem.eql(u8, call.name, "shell")) {
                if (try tool_result_errors.isTerminalEndedFailure(arena, safe_result)) {
                    break :blk try arena.print("{s} · ended when fx exited", .{base});
                }
                if (try tool_result_errors.inspectTerminalActionFieldCorrection(
                    arena,
                    safe_result,
                )) |correction| {
                    break :blk try arena.print(
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
            break :blk try arena.print("{s}: {s}", .{ base, detail });
        },
    };
    const summary_line = if (result.web_fetch_completion) |completion|
        try formatWebFetchCompletion(arena, base_line, completion)
    else if (result.web_search_completion) |completion|
        try formatWebSearchCompletion(arena, base_line, completion)
    else if (result.subagent_completion) |status|
        renderedSubagentSummary(hooks, arena, base_line, status)
    else
        base_line;
    const line = if (diff_entry) |payload| blk: {
        break :blk try formatToolStatusWithStats(arena, summary_line, payload.additions, payload.deletions, hooks.diff_marker_styles);
    } else summary_line;
    const shell_command = activity_kind == .command and
        std.mem.eql(u8, call.name, "shell");
    const presentation_result = try presentedToolResult(
        arena,
        call,
        activity_kind,
        if (shell_command) result.model_output else safe_result,
    );
    var presentation_memory = result_memory;
    if (shell_command) {
        presentation_memory.output_handle = null;
        presentation_memory.preview = presentation_result;
    }
    const command_artifact_handle = if (activity_kind == .command and
        !shell_command)
        try commandArtifactHandle(arena, result.command_result_json)
    else
        null;
    try hooks.push_tool_lifecycle(hooks.ctx, .{
        .terminal = .{
            .id = .{ .turn_id = turn_id, .call_id = call.id },
            .outcome = .{
                .kind = if (outcome_decision) |decision|
                    decision.outcome
                else if (result.status == .success)
                    .completed
                else
                    .failed,
                .summary = line,
            },
            .result = presentation_result,
            .result_memory = presentation_memory,
            .command_artifact_handle = command_artifact_handle,
            .check_found_command_ended = shell_command and try checkFoundCommandEnded(arena, call, result.model_output),
            .resolved_path = readFileResolvedPath(call, result.status == .success, safe_result),
        },
    });
}

/// The file a completed read_file call read, as core resolved it with
/// symlinks followed: the path its result names (`readPathOfResult`), in
/// the text the session saves, so a resumed row finds the same path. Null
/// for any other call, and for one that failed, whose path core never
/// resolved to a file.
fn readFileResolvedPath(call: ToolCall, succeeded: bool, saved_result: []const u8) ?[]const u8 {
    if (!succeeded or !std.mem.eql(u8, call.name, "read_file")) return null;
    return tool_result_display.readPathOfResult(saved_result);
}

test "a finished read tells the transcript the file core read" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var capture = ProvisionalStatusTestCapture{ .alloc = alloc };
    defer capture.deinit();
    const hooks = capture.hooks();
    // The call named a symlink; core read the file it points to.
    const call = ToolCall{ .id = "read", .name = "read_file", .arguments_json = "{\"path\":\"notes.md\"}" };
    const output = "<path>real/real.md</path>\n<content>\n1\tok\n</content>";
    try finishExecutedToolStatus(&hooks, arena_state.allocator(), 4, call, true, null, .{ .status = .success, .model_output = output }, output, .{}, null, &.{});
    try std.testing.expectEqualStrings("real/real.md", capture.events.items[0].terminal.resolved_path.?);
    // A failed read, and a call of another tool, resolved no file.
    try finishExecutedToolStatus(&hooks, arena_state.allocator(), 4, call, true, null, .{ .status = .failure, .model_output = output }, output, .{}, null, &.{});
    try std.testing.expect(capture.events.items[1].terminal.resolved_path == null);
    const search = ToolCall{ .id = "search", .name = "grep_files", .arguments_json = "{\"pattern\":\"a\"}" };
    try finishExecutedToolStatus(&hooks, arena_state.allocator(), 4, search, true, null, .{ .status = .success, .model_output = output }, output, .{}, null, &.{});
    try std.testing.expect(capture.events.items[2].terminal.resolved_path == null);
}

fn presentedToolResult(
    arena: Allocator,
    call: ToolCall,
    activity_kind: types.ToolActivityKind,
    safe_result: []const u8,
) Allocator.Error![]const u8 {
    if (activity_kind != .command or !std.mem.eql(u8, call.name, "shell")) {
        return safe_result;
    }
    return try managed_execution.modelOutputDelta(arena, safe_result) orelse
        safe_result;
}

test "shell command presentation projects output delta without changing other results" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const shell_call = ToolCall{
        .id = "shell-result",
        .name = "shell",
        .arguments_json = "{}",
    };
    try std.testing.expectEqualStrings(
        "visible output\n",
        try presentedToolResult(
            arena,
            shell_call,
            .command,
            "{\"output_delta\":\"visible output\\n\",\"exit_code\":0}",
        ),
    );
    const malformed = "not-json";
    try std.testing.expectEqualStrings(
        malformed,
        try presentedToolResult(arena, shell_call, .command, malformed),
    );
    const read_call = ToolCall{
        .id = "read-result",
        .name = "read_file",
        .arguments_json = "{}",
    };
    try std.testing.expectEqualStrings(
        "unchanged",
        try presentedToolResult(arena, read_call, .read, "unchanged"),
    );
}

pub const ToolOutcomeDecision = struct {
    outcome: types.ToolOutcomeKind,
    label: []const u8,
    detail: ?[]const u8 = null,
};

pub fn commandOutcomeDecision(
    arena: Allocator,
    presentation: ?types.CommandProcessPresentation,
) !?ToolOutcomeDecision {
    const value = presentation orelse return null;
    return switch (value) {
        .exit_code => |code| if (code == 0)
            .{ .outcome = .completed, .label = "Ran" }
        else
            .{
                .outcome = .failed,
                .label = try arena.print("Exited {d}", .{code}),
            },
        .signal => |signal| .{
            .outcome = .failed,
            .label = try arena.print("Signaled {d}", .{signal}),
        },
        .timed_out => .{ .outcome = .failed, .label = "Timed out" },
        .output_capture_failed => .{
            .outcome = .failed,
            .label = "Output capture failed",
        },
    };
}

/// The label of a shell `run` whose command was still running when the call
/// returned, such as when steering moved it to the background or its
/// `yield_time_ms` ran out. It has no exit status, so it must not read "Ran".
pub const still_running_label = "Still running";

/// The outcome of a shell `run` call whose result `output` reports
/// `"state":"running"`, or null for any other call or result.
pub fn runningCommandDecision(
    arena: Allocator,
    call: ToolCall,
    output: []const u8,
) !?ToolOutcomeDecision {
    if (!std.mem.eql(u8, call.name, "shell")) return null;
    if (std.mem.find(u8, output, "\"running\"") == null) return null;
    // Only text that is not JSON gives no decision; running out of memory is
    // reported, so the row does not read "Ran" for a command that still runs.
    const args = tool_args.parseToolArgsObject(arena, call.arguments_json) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const action = tool_args.optionalStringArg(args, "action") orelse "run";
    if (!std.mem.eql(u8, action, "run")) return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, output, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (parsed != .object) return null;
    const state = parsed.object.get("state") orelse return null;
    if (state != .string or !std.mem.eql(u8, state.string, "running")) return null;
    return .{ .outcome = .completed, .label = still_running_label };
}

test "a shell run that returns its command running reads Still running" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const run = ToolCall{ .id = "run", .name = "shell", .arguments_json = "{\"action\":\"run\",\"command\":\"sleep 30\"}" };
    const running = "{\"session_id\":\"shell-1\",\"state\":\"running\",\"steering_notice\":\"New steering arrived\"}";
    const decision = (try runningCommandDecision(arena, run, running)).?;
    try std.testing.expectEqualStrings(still_running_label, decision.label);
    try std.testing.expectEqual(types.ToolOutcomeKind.completed, decision.outcome);

    const no_action = ToolCall{ .id = "run", .name = "shell", .arguments_json = "{\"command\":\"sleep 30\"}" };
    try std.testing.expect((try runningCommandDecision(arena, no_action, running)) != null);

    const finished = "{\"session_id\":\"shell-1\",\"state\":\"completed\",\"exit_code\":0,\"output_delta\":\"running\"}";
    try std.testing.expect((try runningCommandDecision(arena, run, finished)) == null);
    const interact = ToolCall{ .id = "i", .name = "shell", .arguments_json = "{\"action\":\"interact\",\"session_id\":\"shell-1\"}" };
    try std.testing.expect((try runningCommandDecision(arena, interact, running)) == null);
    const read = ToolCall{ .id = "r", .name = "read_file", .arguments_json = "{}" };
    try std.testing.expect((try runningCommandDecision(arena, read, running)) == null);
    try std.testing.expect((try runningCommandDecision(arena, run, "not json \"running\"")) == null);
}

/// Whether a shell check, an `interact` call that sends no input, found its
/// session's command ended, from the check's result `output`. A check that
/// found it passed reads `Observed`, as one does while the command runs on,
/// since the shell gives a check an exit status only when the command failed
/// (publishSnapshotMetadata in src/tools/shell/shell.zig).
pub fn checkFoundCommandEnded(arena: Allocator, call: ToolCall, output: []const u8) !bool {
    if (!std.mem.eql(u8, call.name, "shell")) return false;
    if (std.mem.find(u8, output, "\"completed\"") == null) return false;
    const args = tool_args.parseToolArgsObject(arena, call.arguments_json) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    const action = tool_args.optionalStringArg(args, "action") orelse return false;
    if (!std.mem.eql(u8, action, "interact")) return false;
    if (tool_args.optionalStringArg(args, "chars")) |chars| if (chars.len > 0) return false;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, output, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    if (parsed != .object) return false;
    const state = parsed.object.get("state") orelse return false;
    return state == .string and std.mem.eql(u8, state.string, "completed");
}

test "a shell check finds its command ended only from a completed result" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const check = ToolCall{ .id = "c", .name = "shell", .arguments_json = "{\"action\":\"interact\",\"session_id\":\"shell-1\"}" };
    const passed = "{\"state\":\"completed\",\"exit_code\":0,\"duration_ms\":2004,\"output_delta\":\"CAPTURED_DONE\"}";
    try std.testing.expect(try checkFoundCommandEnded(arena, check, passed));
    const empty_chars = ToolCall{ .id = "c", .name = "shell", .arguments_json = "{\"action\":\"interact\",\"session_id\":\"shell-1\",\"chars\":\"\"}" };
    try std.testing.expect(try checkFoundCommandEnded(arena, empty_chars, passed));
    const failed = "{\"state\":\"completed\",\"exit_code\":1,\"output_delta\":\"\"}";
    try std.testing.expect(try checkFoundCommandEnded(arena, check, failed));

    const running = "{\"session_id\":\"shell-1\",\"state\":\"running\",\"running_ms\":30008,\"output_delta\":\"completed\"}";
    try std.testing.expect(!try checkFoundCommandEnded(arena, check, running));
    const stopped = "{\"state\":\"stopped\",\"signal\":15,\"output_delta\":\"completed\"}";
    try std.testing.expect(!try checkFoundCommandEnded(arena, check, stopped));
    const send = ToolCall{ .id = "s", .name = "shell", .arguments_json = "{\"action\":\"interact\",\"session_id\":\"shell-1\",\"chars\":\"y\\n\"}" };
    try std.testing.expect(!try checkFoundCommandEnded(arena, send, passed));
    const run = ToolCall{ .id = "r", .name = "shell", .arguments_json = "{\"action\":\"run\",\"command\":\"true\"}" };
    try std.testing.expect(!try checkFoundCommandEnded(arena, run, passed));
    const read = ToolCall{ .id = "f", .name = "read_file", .arguments_json = "{\"action\":\"interact\"}" };
    try std.testing.expect(!try checkFoundCommandEnded(arena, read, passed));
    try std.testing.expect(!try checkFoundCommandEnded(arena, check, "not json \"completed\""));
}

test "a check tells the transcript it found its command ended and keeps its own status" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const check = ToolCall{ .id = "check", .name = "shell", .arguments_json = "{\"action\":\"interact\",\"session_id\":\"shell-1\"}" };
    const cases = [_]struct { output: []const u8, ended: bool }{
        .{ .output = "{\"state\":\"completed\",\"exit_code\":0,\"output_delta\":\"done\"}", .ended = true },
        .{ .output = "{\"session_id\":\"shell-1\",\"state\":\"running\",\"output_delta\":\"\"}", .ended = false },
    };
    for (cases) |case| {
        var capture = ProvisionalStatusTestCapture{ .alloc = alloc };
        defer capture.deinit();
        const hooks = capture.hooks();
        try finishExecutedToolStatus(
            &hooks,
            arena,
            3,
            check,
            true,
            null,
            .{ .status = .success, .model_output = case.output },
            case.output,
            .{ .output_bytes = case.output.len, .stored_output_bytes = case.output.len },
            null,
            &.{},
        );
        const terminal = capture.events.items[0].terminal;
        try std.testing.expectEqual(case.ended, terminal.check_found_command_ended);
        // The status line Ctrl+O, ACP, and `fx ask` show is the same either way.
        try std.testing.expectEqual(types.ToolOutcomeKind.completed, terminal.outcome.kind);
        try std.testing.expectEqualStrings("started shell", terminal.outcome.summary);
    }
}

fn checkRunningCommandDecisionAllocationFailures(alloc: Allocator) !void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const run = ToolCall{ .id = "run", .name = "shell", .arguments_json = "{\"action\":\"run\",\"command\":\"sleep 30\"}" };
    const running = "{\"session_id\":\"shell-1\",\"state\":\"running\"}";
    const decision = (try runningCommandDecision(arena_state.allocator(), run, running)).?;
    try std.testing.expectEqualStrings(still_running_label, decision.label);
}

test "a running shell result reports out of memory instead of reading Ran" {
    try std.testing.checkAllAllocationFailures(
        testing_allocator.no_resize,
        checkRunningCommandDecisionAllocationFailures,
        .{},
    );
}

pub fn terminalActionOutcomeDecision(
    arena: Allocator,
    presentation: ?types.TerminalActionPresentation,
) !?ToolOutcomeDecision {
    const value = presentation orelse return null;
    return switch (value) {
        .returned => |returned| switch (returned) {
            .started => .{ .outcome = .completed, .label = "Started" },
            .condition_met => .{ .outcome = .completed, .label = "Condition met for" },
            .safety_ceiling => .{ .outcome = .completed, .label = "Wait limit reached for" },
            .cancelled => .{ .outcome = .cancelled, .label = "Cancelled" },
            .exited => |code| .{
                .outcome = if (code == 0) .completed else .failed,
                .label = try arena.print("Exited {d}", .{code}),
            },
            .signal => |signal| .{
                .outcome = .failed,
                .label = try arena.print("Terminated by signal {d}", .{signal}),
            },
        },
        .failed => |failed| if (failed == .cancelled)
            .{ .outcome = .cancelled, .label = "Cancelled" }
        else
            .{
                .outcome = .failed,
                .label = "Failed",
                .detail = failed.detail(),
            },
    };
}

fn failureStatusDetail(
    arena: Allocator,
    call: ToolCall,
    result: ToolExecutionResult,
    safe_result: []const u8,
    advertised_dynamic_tool_names: []const []const u8,
) !?[]const u8 {
    switch (call.argument_integrity) {
        .malformed_json => return "invalid JSON arguments",
        .non_object_json => return "non-object arguments",
        .valid => {},
    }
    if (result.status_detail) |detail| {
        if (!std.mem.eql(u8, detail, "preflight failed")) return detail;

        if (file_mutation_contract.isToolName(call.name) and
            std.mem.startsWith(u8, safe_result, call.name))
        {
            const failure_prefix = " failed: ";
            const remainder = safe_result[call.name.len..];
            if (std.mem.startsWith(u8, remainder, failure_prefix)) {
                // Lines after the first carry detail for the model, such as
                // the text a failed edit most likely meant.
                const reason = remainder[failure_prefix.len..];
                const actionable = reason[0 .. std.mem.findScalar(u8, reason, '\n') orelse reason.len];
                if (actionable.len > 0 and
                    std.mem.findScalar(u8, actionable, '\r') == null)
                {
                    const masked = try text_utils.maskSecrets(arena, actionable);
                    const encoded = try text_utils.encodeTerminalSafeInline(arena, masked, 256);
                    return if (encoded.bytes.len == 0) detail else encoded.bytes;
                }
            }
        }

        if (safe_result.len == 0) return detail;
        const masked = try text_utils.maskSecrets(arena, safe_result);
        const encoded = try text_utils.encodeTerminalSafeInline(arena, masked, 256);
        return if (encoded.bytes.len == 0) detail else encoded.bytes;
    }

    // An MCP call shows why it failed, made directly or through toolbox.
    const mcp_call = containsName(advertised_dynamic_tool_names, call.name) or
        if (try toolbox.carriedCall(arena, call.name, call.arguments_json)) |run| types.isMcpToolName(run.name) else false;
    if (safe_result.len == 0 or !mcp_call) return null;
    // A result over the cap is stored, and the model's copy is the head of the text in a preview block.
    // The cause comes from that head, as it does in the trace.
    const model_text = result_store.storedPreview(safe_result) orelse safe_result;
    const server_text = try mcpFailureEnvelopeText(arena, model_text) orelse model_text;
    // A refused call's parameters read as which fields and types, not as the
    // start of a protocol dump; the model still gets the server's own words.
    // The line shows what the server said, and no error's data, which only the model gets.
    const detail = try mcp_tool_result.invalidParamsCause(arena, server_text) orelse
        try mcp_tool_result.protocolErrorWithoutData(arena, server_text);
    const masked_detail = try text_utils.maskSecrets(arena, detail);
    const encoded = try text_utils.encodeTerminalSafeInline(arena, masked_detail, 256);
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
    if (!std.mem.eql(u8, kind, "command") and
        !std.mem.eql(u8, kind, "foreground")) return null;
    const output_file = switch (object.get("output_file") orelse return null) {
        .string => |value| value,
        else => return null,
    };
    const handle = std.Io.Dir.path.basename(output_file);
    if (!std.mem.startsWith(u8, handle, "fx-command-") or
        !std.mem.endsWith(u8, handle, ".log") or
        std.mem.endsWith(u8, handle, ".stdout.log") or
        std.mem.endsWith(u8, handle, ".stderr.log")) return null;
    const owned: []const u8 = try arena.dupe(u8, handle);
    return owned;
}

pub fn finishCommittedFileStatus(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    turn_id: u64,
    call: ToolCall,
    status_started: bool,
    display_target: ?[]const u8,
    preview: diff.FileChangePreview,
    /// The file the change wrote, resolved: `CommittedFileHandoff`'s
    /// tracker path.
    resolved_path: []const u8,
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
            .resolved_path = resolved_path,
        },
    });
}

test "a committed file change tells the transcript the file core resolved" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var capture = ProvisionalStatusTestCapture{ .alloc = alloc };
    defer capture.deinit();
    const hooks = capture.hooks();
    const call = ToolCall{ .id = "edit", .name = "edit_file", .arguments_json = "{\"path\":\"./tsec/x.tse\"}" };
    try finishCommittedFileStatus(&hooks, arena_state.allocator(), 4, call, true, null, .{
        .path = "./tsec/x.tse",
        .lines = &.{},
        .additions = 1,
        .deletions = 2,
        .truncated = false,
    }, "/w/tsec/x.tse", &.{});
    const terminal = capture.events.items[0].terminal;
    try std.testing.expectEqualStrings("/w/tsec/x.tse", terminal.resolved_path.?);
    // What Ctrl+O, ACP, and `fx ask` show of the call does not change.
    try std.testing.expect(terminal.result == null);
    try std.testing.expect(std.mem.startsWith(u8, terminal.outcome.summary, "started edit_file"));
}

fn renderedSubagentSummary(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    base: []const u8,
    status: types.SubagentStatus,
) []const u8 {
    const renderer = hooks.subagent_status_renderer orelse return base;
    var buf: [256]u8 = undefined;
    const status_line = renderer.render(&buf, status);
    if (status_line.len == 0) return base;
    return arena.print("{s}\n  {s}", .{ base, status_line }) catch base;
}

fn formatWebSearchCompletion(arena: Allocator, base: []const u8, completion: types.WebSearchCompletion) ![]const u8 {
    return arena.print(
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
    return arena.print(
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
        return arena.print("{s} {s}+{d}{s} {s}/{s} {s}-{d}{s}", .{ base, add_style, additions, reset, dim, reset, rem_style, deletions, reset });
    } else if (additions > 0) {
        return arena.print("{s} {s}+{d}{s}", .{ base, add_style, additions, reset });
    } else if (deletions > 0) {
        return arena.print("{s} {s}-{d}{s}", .{ base, rem_style, deletions, reset });
    }
    return base;
}

const test_tools = [_]tool_dispatch.Tool{
    test_builtin_tools.glob_files,
    test_builtin_tools.read_file,
    test_builtin_tools.write_file,
    test_builtin_tools.edit_file,
    test_builtin_tools.shell,
    test_builtin_tools.ask_user_question,
    test_builtin_tools.toolbox,
    test_builtin_tools.subagent,
};
const test_tool_registry = tool_dispatch.Registry{ .tools = test_tools[0..] };
const custom_activity_tool = blk: {
    var tool = test_builtin_tools.read_file;
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
    fn noopRequestPermission(_: *anyopaque, _: Allocator, _: ToolCall, _: permission_auto_classifier.ReviewTurnContext, _: types.PermissionMode, _: []const types.PermissionGrant, _: ?runtime_tool_contracts.LiveToolAuthority, _: ?runtime_tool_contracts.LivePermissionRevalidation, _: []const []const u8, _: ?[]const u8) !command_admission.PermissionOutcome {
        return .{ .decision = .once, .execution_authority = .ordinary };
    }
    fn describeToolAction(_: *anyopaque, arena: Allocator, call: ToolCall, _: ?[]const u8, _: []const []const u8) ![]const u8 {
        return arena.print("started {s}", .{call.name});
    }
    fn describeDeniedToolAction(_: *anyopaque, arena: Allocator, call: ToolCall, _: ?[]const u8, label: []const u8, _: []const []const u8) ![]const u8 {
        return arena.print("{s} {s}", .{ label, call.name });
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
        return arena.print("{s}", .{@errorName(err)});
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

test "fallback tool display never exposes provider search backend names" {
    for ([_][]const u8{ "exa_search", "perplexity_search", "parallel_search" }) |name| {
        try std.testing.expectEqualStrings("web search", fallbackToolDisplay(test_tool_registry, name));
    }
    try std.testing.expectEqualStrings("tool call", fallbackToolDisplay(test_tool_registry, "read_file"));
    try std.testing.expectEqualStrings("tool call", fallbackToolDisplay(test_tool_registry, "run_command"));
    try std.testing.expectEqualStrings("mcp_custom", fallbackToolDisplay(test_tool_registry, "mcp_custom"));
}

test "provisional lifecycle preflight distinguishes unknown eligible and ineligible tools" {
    try std.testing.expect(ProvisionalToolStatuses.preflight(test_tool_registry, "unknown_tool") == null);

    for ([_][]const u8{ "ask_user_question", "write_file", "edit_file", "shell", "run_command" }) |name| {
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

    for ([_][]const u8{ "exa_search", "perplexity_search", "parallel_search" }) |name| {
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
        "exa_search",
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

test "only a provider-run tool that reads is safe to run again" {
    const writing_provider_tool = blk: {
        var spec = test_builtin_tools.web_search;
        spec.name = "provider_publish";
        spec.activity_kind = .write;
        break :blk spec;
    };
    const provider_registry = tool_dispatch.Registry{
        .tools = &.{ test_builtin_tools.web_search, writing_provider_tool, test_builtin_tools.read_file },
    };

    try std.testing.expect(providerToolOnlyReads(provider_registry, "web_search"));
    try std.testing.expect(providerToolOnlyReads(provider_registry, "exa_search"));
    try std.testing.expect(!providerToolOnlyReads(provider_registry, "provider_publish"));
    // A local tool is not a provider-run tool, and an unknown name is not
    // known to read.
    try std.testing.expect(!providerToolOnlyReads(provider_registry, "read_file"));
    try std.testing.expect(!providerToolOnlyReads(provider_registry, "unknown_tool"));
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

    try statuses.publish(&hooks, alloc, 7, "read_1", "read_file", activityKind(hooks.tool_registry, "read_file"), eligibleActionLabel("read_file"), "src/main.zig", null);
    try statuses.publish(&hooks, alloc, 7, "list_1", "glob_files", activityKind(hooks.tool_registry, "glob_files"), eligibleActionLabel("glob_files"), null, null);

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
        .progress => |event| try std.testing.expectEqualStrings("● Matching\x1b[0m", event.text),
        else => return error.TestExpectedEqual,
    }
}

test "provisional toolbox labels read as what the call opens, runs, or searches" {
    // The stream's hint is the first string in the arguments, which may name
    // what a run runs or what a search looks for, so it never labels the row.
    // The action and its whole value label it as soon as they stream in.
    const Case = struct {
        arguments_json: ?[]const u8,
        label: []const u8,
        value: ?[]const u8 = null,
        /// The tool the row is for, when it differs from toolbox.
        tool_name: []const u8 = toolbox.tool_name,
        /// The call shows no row yet.
        hidden: bool = false,
    };
    const cases = [_]Case{
        .{ .arguments_json = null, .label = "Using", .hidden = true },
        .{ .arguments_json = "{\"run\":\"glob", .label = "Using", .hidden = true },
        .{ .arguments_json = "{}", .label = "Using", .hidden = true },
        // A run of a built-in tool reads as a direct call of it once that
        // call would name its target, and shows no row before then, so it
        // never reads as a bare verb.
        .{ .arguments_json = "{\"run\":\"glob_files\",\"argu", .label = "Matching", .hidden = true },
        .{ .arguments_json = "{\"run\":\"read_file\",\"arguments\":{\"path\":\"no", .label = "Reading", .hidden = true },
        .{ .arguments_json = "{\"run\":\"read_file\",\"arguments\":{\"path\":\"a\\\"b\"", .label = "Reading", .hidden = true },
        .{ .arguments_json = "{\"run\":\"read_file\",\"arguments\":{\"path\":\"notes.txt\",\"off", .label = "Reading", .value = "notes.txt", .tool_name = "read_file" },
        .{ .arguments_json = "{\"run\":\"read_file\",\"arguments\":{}}", .label = "Reading", .hidden = true },
        .{ .arguments_json = "{\"run\":\"mcp_fixture_echo\",\"arguments\":{\"te", .label = tooling_presentation.mcp_running_label, .value = "mcp_fixture_echo" },
        // A name fx doesn't hold keeps toolbox's own row, which names it.
        .{ .arguments_json = "{\"run\":\"no_such_tool\",\"argu", .label = "Running", .value = "no_such_tool" },
        .{ .arguments_json = "{\"search\":\"list files\"", .label = "Searching toolbox", .value = "list files" },
        .{ .arguments_json = "{\"open\":\"fixture\",\"res", .label = "Opening", .value = "fixture" },
        // A streamed skill location reads as the skill's name, never the
        // opaque location.
        .{ .arguments_json = "{\"open\":\"skill:0123456789abcdef:6/ste-english\",\"res", .label = "Opening", .value = "ste-english" },
        .{ .arguments_json = "{\"run\":\"glob_files\",\"arguments\":{\"pattern\":\"*.md\"}}", .label = "Matching", .value = "*.md", .tool_name = "glob_files" },
        .{ .arguments_json = "{\"run\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"notes.txt\\\"}\"}", .label = "Reading", .value = "notes.txt", .tool_name = "read_file" },
        .{ .arguments_json = "{\"run\":\"mcp_fixture_echo\",\"arguments\":{}}", .label = tooling_presentation.mcp_running_label, .value = "mcp_fixture_echo" },
        .{ .arguments_json = "{\"search\":\"list files\"}", .label = "Searching toolbox", .value = "list files" },
        .{ .arguments_json = "{\"open\":\"fixture\"}", .label = "Opening", .value = "fixture" },
        // A skill's file reads as that file.
        .{ .arguments_json = "{\"open\":\"skill:opaque/location\",\"resource\":\"references/types.md\"}", .label = "Reading skill resource", .value = "references/types.md" },
    };
    const alloc = std.testing.allocator;
    for (cases) |case| {
        var capture = ProvisionalStatusTestCapture{ .alloc = alloc };
        defer capture.deinit();
        const hooks = capture.hooks();
        var statuses = ProvisionalToolStatuses{};
        defer statuses.deinit(alloc);
        try statuses.publish(&hooks, alloc, 7, "toolbox_1", toolbox.tool_name, .read, eligibleActionLabel(toolbox.tool_name), "glob_files", case.arguments_json);
        errdefer std.debug.print("arguments: {?s}\n", .{case.arguments_json});
        // A call that names nothing yet shows no row, so no bare "Using",
        // and it stays unnamed, so more arguments can name it.
        if (case.hidden) {
            try std.testing.expectEqual(@as(usize, 0), capture.events.items.len);
            try std.testing.expect(!statuses.has("toolbox_1"));
            try std.testing.expect(statuses.tracked.items[0].label_value == null);
            continue;
        }
        try std.testing.expectEqual(@as(usize, 2), capture.events.items.len);
        try std.testing.expectEqualStrings(case.tool_name, capture.events.items[0].provisional.tool_name.?);
        var expected_buf: [512]u8 = undefined;
        const expected = try formatProvisionalProgressLabel(&expected_buf, case.label, case.value);
        try std.testing.expectEqualStrings(expected, capture.events.items[1].progress.text);
        if (case.value) |value| {
            try std.testing.expectEqualStrings(value, statuses.tracked.items[0].label_value.?);
        } else {
            try std.testing.expect(statuses.tracked.items[0].label_value == null);
        }
    }
}

test "a streaming toolbox run of a built-in tool shows a row only when a direct call of it would" {
    const alloc = std.testing.allocator;
    // A direct write, edit, question, or shell call shows no row while its
    // arguments stream in, so a toolbox run of one shows none either, and
    // the call's own start shows it.
    for ([_][]const u8{
        "{\"run\":\"write_file\",\"argu",
        "{\"run\":\"edit_file\",\"arguments\":{\"path\":\"a.txt\"}}",
        "{\"run\":\"ask_user_question\",\"argu",
        "{\"run\":\"shell\",\"arguments\":{\"action\":\"run\",\"command\":\"ls\"}}",
    }) |arguments_json| {
        var capture = ProvisionalStatusTestCapture{ .alloc = alloc };
        defer capture.deinit();
        const hooks = capture.hooks();
        var statuses = ProvisionalToolStatuses{};
        defer statuses.deinit(alloc);
        const kind = activityKind(hooks.tool_registry, toolbox.tool_name);
        const action = eligibleActionLabel(toolbox.tool_name);
        try statuses.publish(&hooks, alloc, 7, "toolbox_1", toolbox.tool_name, kind, action, null, arguments_json);
        try std.testing.expectEqual(@as(usize, 0), capture.events.items.len);
        try std.testing.expect(!statuses.has("toolbox_1"));
        // More arguments name nothing new, so the row stays hidden.
        try statuses.observeArguments(&hooks, alloc, 7, "toolbox_1", arguments_json);
        try std.testing.expectEqual(@as(usize, 0), capture.events.items.len);
        // A stream that ends early settles no row it never showed.
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        if (std.mem.find(u8, arguments_json, "write_file") != null) {
            try statuses.finishUnmatchedRecoveryStarts(&hooks, alloc, arena_state.allocator(), 7, &.{});
        } else {
            try statuses.finishTrackedCancelled(&hooks, alloc, arena_state.allocator(), 7);
        }
        try std.testing.expectEqual(@as(usize, 0), capture.events.items.len);
        try std.testing.expectEqual(@as(usize, 0), statuses.tracked.items.len);
    }
}

test "a streaming builtin call's row names its target once that value arrives, and keeps it" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        tool: []const u8,
        partial: []const u8,
        named: ?[]const u8,
        value: []const u8 = "",
    }{
        .{ .tool = "read_file", .partial = "{\"pa", .named = "{\"path\":\"src/main.zig\",\"off", .value = "src/main.zig" },
        .{ .tool = "glob_files", .partial = "{\"pattern\":\"*.m", .named = "{\"pattern\":\"*.md\"", .value = "*.md" },
        // A value with an escape in it would read wrongly, so the row waits
        // for the call.
        .{ .tool = "read_file", .partial = "{\"path\":\"a\\\"b", .named = null },
    };
    for (cases) |case| {
        var capture = ProvisionalStatusTestCapture{ .alloc = alloc };
        defer capture.deinit();
        const hooks = capture.hooks();
        var statuses = ProvisionalToolStatuses{};
        defer statuses.deinit(alloc);
        errdefer std.debug.print("tool: {s}\n", .{case.tool});
        const action = eligibleActionLabel(case.tool);
        try statuses.publish(&hooks, alloc, 7, "call_1", case.tool, activityKind(hooks.tool_registry, case.tool), action, null, null);
        try std.testing.expectEqual(@as(usize, 2), capture.events.items.len);
        var bare_buf: [512]u8 = undefined;
        try std.testing.expectEqualStrings(try formatProvisionalProgressLabel(&bare_buf, action, null), capture.events.items[1].progress.text);
        // Part of the value is not yet a value.
        try statuses.observeArguments(&hooks, alloc, 7, "call_1", case.partial);
        try std.testing.expectEqual(@as(usize, 2), capture.events.items.len);
        const named = case.named orelse continue;
        try statuses.observeArguments(&hooks, alloc, 7, "call_1", named);
        try std.testing.expectEqual(@as(usize, 4), capture.events.items.len);
        try std.testing.expectEqualStrings("call_1", capture.events.items[2].provisional.id.call_id);
        var named_buf: [512]u8 = undefined;
        try std.testing.expectEqualStrings(try formatProvisionalProgressLabel(&named_buf, action, case.value), capture.events.items[3].progress.text);
        // The rest of the arguments stream in without another publication.
        const more = try std.mem.concat(alloc, u8, &.{ named, "\"" });
        defer alloc.free(more);
        try statuses.observeArguments(&hooks, alloc, 7, "call_1", more);
        try std.testing.expectEqual(@as(usize, 4), capture.events.items.len);
    }
}

test "a streaming toolbox run's row shows once its tool and that tool's target arrive, and keeps it" {
    const alloc = std.testing.allocator;
    var capture = ProvisionalStatusTestCapture{ .alloc = alloc };
    defer capture.deinit();
    const hooks = capture.hooks();
    var statuses = ProvisionalToolStatuses{};
    defer statuses.deinit(alloc);
    const kind = activityKind(hooks.tool_registry, toolbox.tool_name);
    const action = eligibleActionLabel(toolbox.tool_name);
    var named_buf: [512]u8 = undefined;
    // It reads as a direct glob_files call does once that call names its
    // pattern.
    const named = try formatProvisionalProgressLabel(&named_buf, "Matching", "*.md");

    // The call shows no row until its arguments name the tool it runs and
    // that tool's target.
    try statuses.publish(&hooks, alloc, 7, "toolbox_1", toolbox.tool_name, kind, action, null, null);
    try std.testing.expectEqual(@as(usize, 0), capture.events.items.len);
    try std.testing.expect(!statuses.has("toolbox_1"));
    for ([_][]const u8{
        // Part of the name is not yet a name.
        "{\"run\":\"glob",
        // The tool alone would read as a bare verb.
        "{\"run\":\"glob_files\",",
        "{\"run\":\"glob_files\",\"arguments\":{\"pat",
        "{\"run\":\"glob_files\",\"arguments\":{\"pattern\":\"*.m",
    }) |arguments| {
        try statuses.observeArguments(&hooks, alloc, 7, "toolbox_1", arguments);
        try std.testing.expectEqual(@as(usize, 0), capture.events.items.len);
    }
    try statuses.observeArguments(&hooks, alloc, 7, "toolbox_1", "{\"run\":\"glob_files\",\"arguments\":{\"pattern\":\"*.md\"");
    try std.testing.expectEqual(@as(usize, 2), capture.events.items.len);
    try std.testing.expectEqualStrings("toolbox_1", capture.events.items[0].provisional.id.call_id);
    try std.testing.expectEqualStrings("glob_files", capture.events.items[0].provisional.tool_name.?);
    try std.testing.expectEqual(types.ToolActivityKind.list, capture.events.items[0].provisional.activity_kind);
    try std.testing.expectEqualStrings(named, capture.events.items[1].progress.text);
    try std.testing.expect(statuses.has("toolbox_1"));
    // The rest of the call streams in without another publication.
    try statuses.observeArguments(&hooks, alloc, 7, "toolbox_1", "{\"run\":\"glob_files\",\"arguments\":{\"pattern\":\"*.md\",\"pa");
    try statuses.observeArguments(&hooks, alloc, 7, "toolbox_1", "{\"run\":\"glob_files\",\"arguments\":{\"pattern\":\"*.md\"}}");
    try std.testing.expectEqual(@as(usize, 2), capture.events.items.len);

    // A search with no words yet may list one server's tools, so it waits.
    try statuses.publish(&hooks, alloc, 7, "toolbox_2", toolbox.tool_name, kind, action, null, null);
    const before = capture.events.items.len;
    try statuses.observeArguments(&hooks, alloc, 7, "toolbox_2", "{\"search\":\"\",\"server\":\"sl");
    try std.testing.expectEqual(before, capture.events.items.len);
}

test "a toolbox run streamed byte by byte never reads as a bare verb and names its tool's target once" {
    const alloc = std.testing.allocator;
    const tools = [_]tool_dispatch.Tool{ test_builtin_tools.toolbox, test_builtin_tools.web_fetch, test_builtin_tools.web_search, test_builtin_tools.read_file };
    const registry: tool_dispatch.Registry = .{ .tools = &tools };
    const cases = [_]struct { call: []const u8, tool: []const u8, label: []const u8, value: []const u8 }{
        .{ .call = "{\"run\":\"web_fetch\",\"arguments\":{\"url\":\"http://127.0.0.1/page\"}}", .tool = "web_fetch", .label = "Fetching", .value = "http://127.0.0.1/page" },
        .{ .call = "{\"run\":\"web_search\",\"arguments\":{\"query\":\"zig release notes\"}}", .tool = "web_search", .label = "Searching", .value = "zig release notes" },
        .{ .call = "{\"arguments\":{\"path\":\"notes.txt\"},\"run\":\"read_file\"}", .tool = "read_file", .label = "Reading", .value = "notes.txt" },
    };
    for (cases) |case| {
        errdefer std.debug.print("call: {s}\n", .{case.call});
        var capture = ProvisionalStatusTestCapture{ .alloc = alloc, .tool_registry = registry };
        defer capture.deinit();
        const hooks = capture.hooks();
        var statuses = ProvisionalToolStatuses{};
        defer statuses.deinit(alloc);
        const metadata = (ProvisionalToolStatuses.preflight(registry, toolbox.tool_name).?).eligible;
        try statuses.publish(&hooks, alloc, 7, "toolbox_1", toolbox.tool_name, metadata.activity_kind, metadata.action_label, null, null);
        var named_buf: [512]u8 = undefined;
        const named = try formatProvisionalProgressLabel(&named_buf, case.label, case.value);
        // Every prefix the stream may stop at shows no row or the named one.
        for (1..case.call.len + 1) |end| {
            try statuses.observeArguments(&hooks, alloc, 7, "toolbox_1", case.call[0..end]);
            for (capture.events.items) |event| switch (event) {
                .progress => |progress| try std.testing.expectEqualStrings(named, progress.text),
                else => {},
            };
        }
        try std.testing.expectEqual(@as(usize, 2), capture.events.items.len);
        try std.testing.expectEqualStrings(case.tool, capture.events.items[0].provisional.tool_name.?);
        try std.testing.expectEqualStrings(case.value, statuses.tracked.items[0].label_value.?);
    }
}

test "a streaming subagent call's row names its subagent once the name arrives, and keeps it" {
    const alloc = std.testing.allocator;
    var capture = ProvisionalStatusTestCapture{ .alloc = alloc };
    defer capture.deinit();
    const hooks = capture.hooks();
    var statuses = ProvisionalToolStatuses{};
    defer statuses.deinit(alloc);
    const kind = activityKind(hooks.tool_registry, "subagent");
    const action = eligibleActionLabel("subagent");
    var named_buf: [512]u8 = undefined;
    const named = try formatProvisionalProgressLabel(&named_buf, action, "reviewer");

    try statuses.publish(&hooks, alloc, 7, "sub_1", "subagent", kind, action, null, null);
    try std.testing.expectEqual(@as(usize, 2), capture.events.items.len);
    try std.testing.expectEqualStrings("● Managing\x1b[0m", capture.events.items[1].progress.text);
    // Part of the name is not yet a name.
    try statuses.observeArguments(&hooks, alloc, 7, "sub_1", "{\"request\":{\"action\":\"message\",\"agent\":\"revi");
    try std.testing.expectEqual(@as(usize, 2), capture.events.items.len);
    try statuses.observeArguments(&hooks, alloc, 7, "sub_1", "{\"request\":{\"action\":\"message\",\"agent\":\"reviewer\"");
    try std.testing.expectEqual(@as(usize, 4), capture.events.items.len);
    try std.testing.expectEqualStrings("sub_1", capture.events.items[2].provisional.id.call_id);
    try std.testing.expectEqualStrings(named, capture.events.items[3].progress.text);
    // The rest of the call streams in without another publication.
    try statuses.observeArguments(&hooks, alloc, 7, "sub_1", "{\"request\":{\"action\":\"message\",\"agent\":\"reviewer\",\"message\":\"Review");
    try std.testing.expectEqual(@as(usize, 4), capture.events.items.len);
    // The stream's final start keeps the name.
    try statuses.publish(&hooks, alloc, 7, "sub_1", "subagent", kind, action, null, "{\"request\":{\"action\":\"message\",\"agent\":\"reviewer\",\"message\":\"Review it\"}}");
    try std.testing.expectEqualStrings(named, capture.events.items[5].progress.text);

    // A call without `request` starts with its action, which the stream's
    // hint would name; the row names its subagent instead.
    try statuses.publish(&hooks, alloc, 7, "sub_2", "subagent", kind, action, "message", "{\"action\":\"message\",\"agent\":\"tester\",\"message\":\"Run it\"}");
    var tester_buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(try formatProvisionalProgressLabel(&tester_buf, action, "tester"), capture.events.items[7].progress.text);

    // Other tools and unknown calls are left alone.
    try statuses.publish(&hooks, alloc, 7, "read_1", "read_file", activityKind(hooks.tool_registry, "read_file"), eligibleActionLabel("read_file"), null, null);
    const before = capture.events.items.len;
    try statuses.observeArguments(&hooks, alloc, 7, "read_1", "{\"agent\":\"reviewer\"");
    try statuses.observeArguments(&hooks, alloc, 7, "missing", "{\"agent\":\"reviewer\"");
    try std.testing.expectEqual(before, capture.events.items.len);
}

test "provisional toolbox labels decode escaped UTF-8 and encode terminal controls before copying" {
    const alloc = std.testing.allocator;
    var capture = ProvisionalStatusTestCapture{ .alloc = alloc };
    defer capture.deinit();
    const hooks = capture.hooks();
    var statuses = ProvisionalToolStatuses{};
    defer statuses.deinit(alloc);
    {
        const json = try alloc.dupe(u8, "{\"open\":\"skill:opaque/location\",\"resource\":\"r/\\u00e9\\u4e2d\\\"\\u001b[31m\\n\\r\\t\\u0000\\u0080.md\"}");
        defer alloc.free(json);
        try statuses.publish(&hooks, alloc, 7, "toolbox_1", toolbox.tool_name, .read, eligibleActionLabel(toolbox.tool_name), "skill:opaque/location", json);
    }
    try std.testing.expectEqualStrings(
        "● Reading skill resource\x1b[0m \x1b[38;5;245mr/é中\"\\x1b[31m\\x0a\\x0d\\x09\\x00\\u{0080}.md\x1b[0m",
        capture.events.items[1].progress.text,
    );
    try std.testing.expectEqualStrings("r/é中\"\x1b[31m\n\r\t\x00\u{0080}.md", statuses.tracked.items[0].label_value.?);
}

test "provisional toolbox labels wait for the call when an encoded resource exceeds the progress buffer" {
    const alloc = std.testing.allocator;
    const max_detail = 512 - "● Reading skill resource\x1b[0m \x1b[38;5;245m\x1b[0m".len;
    for ([_]usize{ max_detail, max_detail + 1, 512, 513, 4096 }) |len| {
        var capture = ProvisionalStatusTestCapture{ .alloc = alloc };
        defer capture.deinit();
        const hooks = capture.hooks();
        var statuses = ProvisionalToolStatuses{};
        defer statuses.deinit(alloc);
        const resource = try alloc.alloc(u8, len);
        defer alloc.free(resource);
        @memset(resource, 'a');
        const json = try alloc.print("{{\"open\":\"skill:opaque/location\",\"resource\":\"{s}\"}}", .{resource});
        defer alloc.free(json);
        try statuses.publish(&hooks, alloc, 7, "toolbox_1", toolbox.tool_name, .read, eligibleActionLabel(toolbox.tool_name), "skill:opaque/location", json);
        if (len == max_detail) {
            const text = capture.events.items[1].progress.text;
            try std.testing.expectEqual(@as(usize, 512), text.len);
            try std.testing.expectEqualStrings(resource, statuses.tracked.items[0].label_value.?);
        } else {
            // A label too long for the row names nothing, so the call shows
            // no row until it starts, rather than a bare "Using".
            try std.testing.expectEqual(@as(usize, 0), capture.events.items.len);
            try std.testing.expect(statuses.tracked.items[0].label_value == null);
            try std.testing.expect(!statuses.has("toolbox_1"));
        }
    }
}

test "provisional non-skill labels retain hints regardless of completed arguments" {
    const alloc = std.testing.allocator;
    for ([_]?[]const u8{ null, "not JSON", "{\"path\":\"different.txt\",\"resource\":\"references/types.md\"}" }) |json| {
        var capture = ProvisionalStatusTestCapture{ .alloc = alloc };
        defer capture.deinit();
        const hooks = capture.hooks();
        var statuses = ProvisionalToolStatuses{};
        defer statuses.deinit(alloc);
        try statuses.publish(&hooks, alloc, 7, "read_1", "read_file", .read, eligibleActionLabel("read_file"), "original.txt", json);
        try std.testing.expectEqualStrings("● Reading\x1b[0m \x1b[38;5;245moriginal.txt\x1b[0m", capture.events.items[1].progress.text);
        try std.testing.expectEqualStrings("original.txt", statuses.tracked.items[0].label_value.?);
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

    try statuses.publish(&hooks, alloc, 9, "read_1", "read_file", .read, "Reading", null, null);
    try statuses.publish(&hooks, alloc, 9, "read_1", "read_file", .read, "Reading", "src/main.zig", null);
    try statuses.publish(&hooks, alloc, 9, "command_1", "run_command", .command, "Running", null, null);
    try statuses.publish(&hooks, alloc, 9, "mcp_1", "mcp_custom", .read, "Running", null, null);
    try statuses.publish(&hooks, alloc, 9, "search_1", "exa_search", .read, "Searching", null, null);
    try statuses.publish(&hooks, alloc, 9, "search_2", "perplexity_search", .read, "Searching", null, null);
    try statuses.publish(&hooks, alloc, 9, "search_3", "exa_search", .read, "Searching", "cmux theme docs", null);
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
        } else if (std.mem.eql(u8, event.terminal.id.call_id, "search_1")) {
            try std.testing.expectEqualStrings("Cancelled web search", event.terminal.outcome.summary);
        } else if (std.mem.eql(u8, event.terminal.id.call_id, "search_2")) {
            try std.testing.expectEqualStrings("Cancelled web search", event.terminal.outcome.summary);
        } else if (std.mem.eql(u8, event.terminal.id.call_id, "search_3")) {
            try std.testing.expectEqualStrings("Cancelled cmux theme docs", event.terminal.outcome.summary);
        } else {
            return error.TestUnexpectedToolCallId;
        }
    }
    try std.testing.expectEqual(@as(usize, 6), terminal_count);
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

    try statuses.publish(&hooks, alloc, 9, "command_1", "run_command", .command, "Running", null, null);
    try statuses.publish(&hooks, alloc, 9, "mcp_1", "mcp_custom", .read, "Running", null, null);
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
    try statuses.publish(&hooks, alloc, 1, call.id, call.name, activityKind(hooks.tool_registry, call.name), eligibleActionLabel(call.name), null, null);
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
        statuses.publish(&hooks, alloc, 1, "read_1", "read_file", activityKind(hooks.tool_registry, "read_file"), eligibleActionLabel("read_file"), null, null),
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

    try statuses.publish(&hooks, alloc, 1, "read_1", "read_file", activityKind(hooks.tool_registry, "read_file"), eligibleActionLabel("read_file"), null, null);
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

    _ = try statuses.record(alloc, "provider_search_invalid");
    try statuses.finishMalformedProviderToolArguments(&hooks, arena, 1, &.{.{
        .id = "provider_search_invalid",
        .name = "exa_search",
        .arguments_json = "{",
        .argument_integrity = .malformed_json,
        .provenance = .provider_executed,
    }});

    try std.testing.expectEqual(@as(usize, 4), capture.events.items.len);
    for (capture.events.items) |event| {
        switch (event) {
            .terminal => |terminal| {
                if (std.mem.eql(u8, terminal.id.call_id, "mcp_invalid")) {
                    try std.testing.expectEqualStrings("mcp_lookup failed: invalid JSON arguments", terminal.outcome.summary);
                } else if (std.mem.eql(u8, terminal.id.call_id, "provider_search_invalid")) {
                    try std.testing.expectEqualStrings("web search failed: invalid JSON arguments", terminal.outcome.summary);
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

test "malformed final settlement retains diagnostics and consumes identity once" {
    const alloc = std.testing.allocator;
    for ([_]bool{ false, true }) |streamed| {
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var capture = ProvisionalStatusTestCapture{ .alloc = alloc };
        defer capture.deinit();
        const hooks = capture.hooks();
        var statuses = ProvisionalToolStatuses{};
        defer statuses.deinit(alloc);
        if (streamed) _ = try statuses.record(alloc, "streamed_id");
        const call: ToolCall = .{
            .id = "final_id",
            .name = "shell",
            .arguments_json = "{}",
            .argument_integrity = .malformed_json,
            .provisional_id = if (streamed) "streamed_id" else null,
        };
        const result: ToolExecutionResult = .{ .status = .failure, .model_output = "safe diagnostic" };
        const memory: types.ToolResultMemory = .{ .output_bytes = 15, .stored_output_bytes = 15 };
        capture.fail_terminal = true;
        try std.testing.expectError(error.TestTerminalPublicationFailure, statuses.finishExecutedCall(
            &hooks,
            alloc,
            arena,
            1,
            call,
            false,
            null,
            result,
            result.model_output,
            memory,
            null,
            &.{},
        ));
        try std.testing.expect(!statuses.hasTerminal(call.id));
        if (streamed) try std.testing.expect(statuses.has("streamed_id"));
        capture.fail_terminal = false;
        try std.testing.expect(try statuses.finishExecutedCall(
            &hooks,
            alloc,
            arena,
            1,
            call,
            false,
            null,
            result,
            result.model_output,
            memory,
            null,
            &.{},
        ));
        try std.testing.expect(!try statuses.finishExecutedCall(
            &hooks,
            alloc,
            arena,
            1,
            call,
            false,
            null,
            result,
            result.model_output,
            memory,
            null,
            &.{},
        ));
        try std.testing.expectEqual(@as(usize, 0), statuses.tracked.items.len);
        var terminal_count: usize = 0;
        for (capture.events.items) |event| switch (event) {
            .terminal => |terminal| {
                terminal_count += 1;
                try std.testing.expectEqualStrings(if (streamed) "streamed_id" else "final_id", terminal.id.call_id);
                try std.testing.expectEqual(types.ToolOutcomeKind.failed, terminal.outcome.kind);
                try std.testing.expectEqualStrings("Failed shell: invalid JSON arguments", terminal.outcome.summary);
                try std.testing.expectEqualStrings(result.model_output, terminal.result.?);
                try std.testing.expectEqual(@as(usize, 15), terminal.result_memory.?.output_bytes);
            },
            .progress => return error.TestUnexpectedResult,
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 1), terminal_count);
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

    try statuses.publish(&hooks, alloc, 1, "read_1", "read_file", activityKind(hooks.tool_registry, "read_file"), eligibleActionLabel("read_file"), null, null);
    try std.testing.expect(statuses.has("read_1"));
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    try std.testing.expect(try statuses.finishExecutedCall(
        &hooks,
        alloc,
        arena_state.allocator(),
        1,
        .{ .id = "read_1", .name = "read_file", .arguments_json = "{}", .argument_integrity = .malformed_json },
        false,
        null,
        .{ .status = .failure, .model_output = "diagnostic" },
        "diagnostic",
        .{},
        null,
        &.{},
    ));
}

test "provisional lifecycle cleans up every copied-id allocation failure" {
    try std.testing.checkAllAllocationFailures(
        testing_allocator.no_resize,
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

test "subagent completion preview updates progress without publishing a terminal" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var capture = ProvisionalStatusTestCapture{ .alloc = alloc };
    defer capture.deinit();
    const hooks = capture.hooks();
    const call = ToolCall{
        .id = "child",
        .name = "subagent",
        .arguments_json = "{\"action\":\"message\",\"agent\":\"reviewer\",\"message\":\"inspect auth\"}",
    };

    try std.testing.expect(try publishSubagentCompletionPreview(
        &hooks,
        arena,
        3,
        call,
        .{ .model_output = "{\"ok\":true,\"pending\":true}" },
        &.{},
    ));

    try std.testing.expectEqual(@as(usize, 1), capture.events.items.len);
    switch (capture.events.items[0]) {
        .progress => |progress| {
            try std.testing.expectEqual(@as(u64, 3), progress.id.turn_id);
            try std.testing.expectEqualStrings("child", progress.id.call_id);
            try std.testing.expectEqualStrings("● reviewer still running · inspect auth", progress.text);
        },
        else => return error.TestExpectedEqual,
    }
}

test "subagent terminal summary preserves request row before child status" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var capture = ProvisionalStatusTestCapture{ .alloc = alloc };
    defer capture.deinit();
    var hooks = capture.hooks();
    var renderer_context: u8 = 0;
    hooks.subagent_status_renderer = .{
        .ctx = &renderer_context,
        .render_fn = struct {
            fn render(_: *anyopaque, buf: []u8, status: types.SubagentStatus) []const u8 {
                return std.mem.print(buf, "{s} · {s} · {d}k", .{ status.model, status.effort.displayLabel(), status.input_tokens / 1000 }) catch "";
            }
        }.render,
    };

    try finishExecutedToolStatus(
        &hooks,
        arena,
        3,
        .{ .id = "child", .name = "subagent", .arguments_json = "{\"action\":\"run\",\"task\":\"inspect auth\"}" },
        true,
        null,
        .{
            .model_output = "{\"ok\":true,\"result\":\"done\"}",
            .subagent_completion = .{
                .model = "openai/gpt-5.5",
                .effort = types.ReasoningEffort.literal("high"),
                .input_tokens = 12_000,
                .context_window = 100_000,
            },
        },
        "{\"ok\":true,\"result\":\"done\"}",
        .{},
        null,
        &.{},
    );

    try std.testing.expectEqual(@as(usize, 1), capture.events.items.len);
    switch (capture.events.items[0]) {
        .terminal => |terminal| try std.testing.expectEqualStrings("started subagent\n  openai/gpt-5.5 · high · 12k", terminal.outcome.summary),
        else => return error.TestExpectedEqual,
    }

    try finishExecutedToolStatus(
        &hooks,
        arena,
        3,
        .{ .id = "child-fallback", .name = "subagent", .arguments_json = "{\"action\":\"run\",\"task\":\"inspect auth\"}" },
        true,
        null,
        .{ .model_output = "{\"ok\":true,\"result\":\"done\"}" },
        "{\"ok\":true,\"result\":\"done\"}",
        .{},
        null,
        &.{},
    );
    switch (capture.events.items[1]) {
        .terminal => |terminal| try std.testing.expectEqualStrings("started subagent", terminal.outcome.summary),
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

test "permission target preflight failure reports the actionable reason" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var capture = ProvisionalStatusTestCapture{ .alloc = alloc };
    defer capture.deinit();
    const hooks = capture.hooks();
    const failure = "Path not found: /tmp/missing";

    try finishExecutedToolStatus(
        &hooks,
        arena,
        5,
        .{
            .id = "grep_preflight",
            .name = "grep_files",
            .arguments_json = "{\"pattern\":\"upgrade\",\"path\":\"/tmp/missing\"}",
        },
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
        "Failed grep_files: Path not found: /tmp/missing",
        terminal.outcome.summary,
    );
}

test "dynamic MCP failure flattens a multi-line detail into a terminal-safe summary" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var capture = ProvisionalStatusTestCapture{ .alloc = alloc };
    defer capture.deinit();
    const hooks = capture.hooks();
    const failure =
        \\{"server":"plain","tool":"mcp_plain_getThreads","result":{"resultType":"complete","isError":true,"content":[{"type":"text","text":"Invalid input:\u001b[31m labels require at least one item\nretry rejected\n"}]}}
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
        "Failed mcp_plain_getThreads: Invalid input:\\x1b[31m labels require at least one item retry rejected",
        terminal.outcome.summary,
    );
    try std.testing.expect(std.mem.findScalar(u8, terminal.outcome.summary, 0x1b) == null);
    try std.testing.expect(std.mem.findScalar(u8, terminal.outcome.summary, '\n') == null);
}

test "dynamic MCP failure flattens a pretty-printed JSON error body" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var capture = ProvisionalStatusTestCapture{ .alloc = alloc };
    defer capture.deinit();
    const hooks = capture.hooks();
    const failure =
        \\{"server":"vercel","tool":"mcp_vercel_web_fetch_vercel_url","result":{"resultType":"complete","isError":true,"content":[{"type":"text","text":"{\n  \"success\": false,\n  \"info\": \"Unable to create share\"\n}"}]}}
    ;
    const advertised = [_][]const u8{"mcp_vercel_web_fetch_vercel_url"};

    try finishExecutedToolStatus(
        &hooks,
        arena,
        7,
        .{
            .id = "vercel_failure",
            .name = "mcp_vercel_web_fetch_vercel_url",
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
        "Failed mcp_vercel_web_fetch_vercel_url: { \"success\": false, \"info\": \"Unable to create share\" }",
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
            return target.print("{s} start", .{label});
        }
    }.describe;
    const failure = "{\"failure\":{\"action\":\"start\",\"code\":\"path_outside_workspace\"}}";

    try finishExecutedToolStatus(
        &hooks,
        arena,
        5,
        .{
            .id = "terminal_path_scope",
            .name = "shell",
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
            \\{"kind":"command","output_file":"/tmp/fx-command-combined.log"}
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

test "command process failures name the typed cause without changing model failure" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var capture = ProvisionalStatusTestCapture{ .alloc = alloc };
    defer capture.deinit();
    const hooks = capture.hooks();

    const cases = [_]struct {
        id: []const u8,
        presentation: types.CommandProcessPresentation,
        expected_summary: []const u8,
    }{
        .{
            .id = "command_nonzero",
            .presentation = .{ .exit_code = 7 },
            .expected_summary = "Exited 7 run_command",
        },
        .{
            .id = "command_signal",
            .presentation = .{ .signal = 9 },
            .expected_summary = "Signaled 9 run_command",
        },
    };
    for (cases) |case| {
        try finishExecutedToolStatus(
            &hooks,
            arena_state.allocator(),
            6,
            .{ .id = case.id, .name = "run_command", .arguments_json = "{}" },
            true,
            null,
            .{ .status = .failure, .model_output = "tool_execution_failed" },
            "tool_execution_failed",
            .{
                .output_bytes = 21,
                .stored_output_bytes = 21,
                .command_process_presentation = case.presentation,
            },
            null,
            &.{},
        );
    }

    try std.testing.expectEqual(@as(usize, cases.len), capture.events.items.len);
    for (capture.events.items, cases) |event, case| {
        const terminal = event.terminal;
        try std.testing.expectEqual(types.ToolOutcomeKind.failed, terminal.outcome.kind);
        try std.testing.expectEqualStrings(case.expected_summary, terminal.outcome.summary);
        try std.testing.expectEqualStrings("tool_execution_failed", terminal.result.?);
        try std.testing.expectEqual(
            case.presentation,
            terminal.result_memory.?.command_process_presentation.?,
        );
    }
}

test "command timeout and output capture failure name their actual cause" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var capture = ProvisionalStatusTestCapture{ .alloc = alloc };
    defer capture.deinit();
    const hooks = capture.hooks();

    const timeout = try command_result_mapping.Command.timeoutFailure(
        arena,
        "sleep 5",
        "/tmp",
        25,
        null,
    );
    try finishExecutedToolStatus(
        &hooks,
        arena,
        7,
        .{ .id = "command_timeout", .name = "run_command", .arguments_json = "{}" },
        true,
        null,
        timeout,
        timeout.model_output,
        timeout.tool_result_memory orelse .{},
        null,
        &.{},
    );

    const capture_failure = try command_result_mapping.Command.outputCaptureFailure(arena);
    try finishExecutedToolStatus(
        &hooks,
        arena,
        7,
        .{ .id = "command_capture", .name = "run_command", .arguments_json = "{}" },
        true,
        null,
        capture_failure,
        capture_failure.model_output,
        capture_failure.tool_result_memory orelse .{},
        null,
        &.{},
    );

    try std.testing.expectEqual(@as(usize, 2), capture.events.items.len);
    try std.testing.expectEqualStrings(
        "Timed out run_command",
        capture.events.items[0].terminal.outcome.summary,
    );
    try std.testing.expectEqualStrings(
        "Output capture failed run_command",
        capture.events.items[1].terminal.outcome.summary,
    );
    for (capture.events.items) |event| {
        try std.testing.expectEqual(types.ToolOutcomeKind.failed, event.terminal.outcome.kind);
    }
}

test "terminal action outcomes map to one typed visible decision" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct {
        presentation: types.TerminalActionPresentation,
        outcome: types.ToolOutcomeKind,
        label: []const u8,
        detail: ?[]const u8 = null,
    }{
        .{
            .presentation = .{ .returned = .started },
            .outcome = .completed,
            .label = "Started",
        },
        .{
            .presentation = .{ .returned = .condition_met },
            .outcome = .completed,
            .label = "Condition met for",
        },
        .{
            .presentation = .{ .returned = .safety_ceiling },
            .outcome = .completed,
            .label = "Wait limit reached for",
        },
        .{
            .presentation = .{ .returned = .cancelled },
            .outcome = .cancelled,
            .label = "Cancelled",
        },
        .{
            .presentation = .{ .returned = .{ .exited = 0 } },
            .outcome = .completed,
            .label = "Exited 0",
        },
        .{
            .presentation = .{ .returned = .{ .exited = 7 } },
            .outcome = .failed,
            .label = "Exited 7",
        },
        .{
            .presentation = .{ .returned = .{ .signal = 9 } },
            .outcome = .failed,
            .label = "Terminated by signal 9",
        },
        .{
            .presentation = .{ .failed = .session_not_found },
            .outcome = .failed,
            .label = "Failed",
            .detail = "terminal session not found",
        },
        .{
            .presentation = .{ .failed = .cancelled },
            .outcome = .cancelled,
            .label = "Cancelled",
        },
    };

    for (cases) |case| {
        const decision = (try terminalActionOutcomeDecision(
            arena,
            case.presentation,
        )).?;
        try std.testing.expectEqual(case.outcome, decision.outcome);
        try std.testing.expectEqualStrings(case.label, decision.label);
        if (case.detail) |expected| {
            try std.testing.expectEqualStrings(expected, decision.detail.?);
        } else {
            try std.testing.expect(decision.detail == null);
        }
    }
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

test "a shell wait is read from top-level arguments and from either request wrapper" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct { arguments_json: []const u8, wait: bool }{
        .{ .arguments_json = "{\"action\":\"wait\",\"session_id\":\"shell-1\"}", .wait = true },
        .{ .arguments_json = "{\"request\":{\"action\":\"wait\",\"session_id\":\"shell-1\"}}", .wait = true },
        .{ .arguments_json = "{\"request\":\"{\\\"action\\\":\\\"wait\\\",\\\"session_id\\\":\\\"shell-1\\\"}\"}", .wait = true },
        .{ .arguments_json = "{\"request\":\"{\\\"action\\\":\\\"run\\\"}\"}", .wait = false },
        .{ .arguments_json = "{\"request\":\"[\\\"wait\\\"]\"}", .wait = false },
        .{ .arguments_json = "not json", .wait = false },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.wait, try isShellWaitCall(arena, .{
            .id = "shell-wait",
            .name = "shell",
            .arguments_json = case.arguments_json,
        }));
    }
}

test "cancelled shell wait names the observation instead of the process" {
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
        .{
            .id = "shell-wait",
            .name = "shell",
            .arguments_json = "{\"action\":\"wait\",\"session_id\":\"shell-running\"}",
        },
        true,
        "long-running command",
        .{
            .status = .failure,
            .cancelled = true,
            .model_output = "wait cancelled\n",
        },
        &.{},
    );

    try std.testing.expectEqual(@as(usize, 1), capture.events.items.len);
    const terminal = capture.events.items[0].terminal;
    try std.testing.expectEqual(types.ToolOutcomeKind.cancelled, terminal.outcome.kind);
    try std.testing.expect(std.mem.find(
        u8,
        terminal.outcome.summary,
        "Stopped waiting for",
    ) != null);
}

const zod_limit_issue = "{\"code\":\"invalid_type\",\"expected\":\"number\",\"received\":\"string\",\"path\":[\"limit\"]}";
const limit_cause = "arguments rejected: limit is a string, the schema wants a number";

/// The text a refused MCP call gives the model, as the result cap's store gives it back: the first
/// `preview_bytes` of `text` in a preview block, because `text` is over the cap.
fn storedFailureText(arena: Allocator, text: []const u8) ![]const u8 {
    const head = try result_store.previewText(arena, text, result_store.preview_bytes);
    return result_store.formatStoredResultOutput(arena, "result-mcp-aaaa-bbbb.txt", head, text.len);
}

fn mcpFailureDetail(arena: Allocator, safe_result: []const u8) !?[]const u8 {
    const call: ToolCall = .{ .id = "call_mcp", .name = "mcp__fixture__echo", .arguments_json = "{}" };
    const result: ToolExecutionResult = .{ .model_output = "", .status = .failure };
    return failureStatusDetail(arena, call, result, safe_result, &.{"mcp__fixture__echo"});
}

test "failure status detail names the cause of a refused MCP call whose text the result cap stored" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const zod = "Invalid arguments: [" ++ zod_limit_issue ++ "]";
    // Data that forges a cause of its own: a zod list and eight labels.
    const forged = "{\"errors\":[{\"expected\":\"string\",\"received\":\"number\",\"path\":[\"forged\"]}],\"hint\":\"" ++ "; data=; data=; data=; data=; data=; data=; data=; data=";
    // 3 KiB of data, so the text is over a cap of 2,000 and the whole of it is in the preview; then 8 KiB, so
    // only the first 4 KiB of it is.
    for ([_]usize{ 3000, 8000 }) |filler| {
        const padded = try arena.alloc(u8, filler);
        @memset(padded, 'x');
        const text_zod = try arena.print("MCP protocol error -32602: {s}; data={s}{s}\"}}", .{ zod, forged, padded });
        const text_plain = try arena.print("MCP protocol error -32602: Invalid params; data={s}{s}\"}}", .{ forged, padded });
        try std.testing.expect(text_zod.len > 2000);
        const zod_detail = (try mcpFailureDetail(arena, try storedFailureText(arena, text_zod))).?;
        try std.testing.expectEqualStrings(limit_cause, zod_detail);
        // The plain message has no cause of its own, and the data's list is not one.
        const plain_detail = (try mcpFailureDetail(arena, try storedFailureText(arena, text_plain))).?;
        try std.testing.expectEqualStrings("the server rejected the call's parameters (-32602)", plain_detail);
        // The text kept in the session reads the same.
        try std.testing.expectEqualStrings(limit_cause, (try mcpFailureDetail(arena, text_zod)).?);
    }
}

test "failure status detail names the cause of a zod message that alone is over the result cap" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const filler = try arena.alloc(u8, 2600);
    @memset(filler, 'y');
    // One issue with a long message of its own: the text has no data and is still over a cap of 2,000.
    const text = try arena.print(
        "MCP protocol error -32602: Invalid arguments: [{{\"code\":\"invalid_type\",\"expected\":\"number\",\"received\":\"string\",\"path\":[\"limit\"],\"message\":\"{s}\"}}]",
        .{filler},
    );
    try std.testing.expect(text.len > 2000 and text.len < result_store.preview_bytes);
    try std.testing.expectEqualStrings(limit_cause, (try mcpFailureDetail(arena, try storedFailureText(arena, text))).?);
}

test "failure status detail never shows the preview block of a stored refusal" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A zod list whose head is cut inside it names no field, so the cause is the general one.
    var list: std.Io.Writer.Allocating = .init(arena);
    for (0..60) |_| try list.writer.print("{s},", .{zod_limit_issue});
    const cut = try arena.print("MCP protocol error -32602: Invalid arguments: [{s}{{}}]", .{list.written()});
    try std.testing.expect(cut.len > result_store.preview_bytes);
    try std.testing.expectEqualStrings(
        "the server rejected the call's parameters (-32602)",
        (try mcpFailureDetail(arena, try storedFailureText(arena, cut))).?,
    );
    // Words that are not a protocol error show as they are, not as the block that holds them.
    const because = try arena.alloc(u8, 4800);
    @memset(because, 'b');
    const words = try arena.print("the server could not run the tool: {s}", .{because});
    const detail = (try mcpFailureDetail(arena, try storedFailureText(arena, words))).?;
    try std.testing.expect(std.mem.startsWith(u8, detail, "the server could not run the tool: bbbb"));
    try std.testing.expect(std.mem.find(u8, detail, "tool_result_preview") == null);
}

test "failure status detail shows an MCP error's message and never its data, for a code other than -32602" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const shown = "MCP protocol error -32603: Internal error";
    // Data with a zod-like list and eight labels. The text is whole, then past the 4 KiB the result store keeps.
    const forged = "{\"errors\":[{\"expected\":\"string\",\"received\":\"number\",\"path\":[\"forged\"]}],\"hint\":\"; data=; data=; data=; data=; data=; data=; data=; data=";
    for ([_]usize{ 3000, 8000 }) |filler| {
        const padded = try arena.alloc(u8, filler);
        @memset(padded, 'x');
        const text = try arena.print("{s}; data={s}{s}\"}}", .{ shown, forged, padded });
        try std.testing.expectEqualStrings(shown, (try mcpFailureDetail(arena, text)).?);
        // As the result store gives it back: the first 4 KiB in a preview block, so the head ends inside the data.
        try std.testing.expectEqualStrings(shown, (try mcpFailureDetail(arena, try storedFailureText(arena, text))).?);
    }
    // A head that holds the message and the start of the label shows no data either.
    const head = try storedFailureText(arena, try arena.print("{s}; data=", .{shown}));
    try std.testing.expectEqualStrings(shown, (try mcpFailureDetail(arena, head)).?);
    // Without data the line is the message, as before.
    try std.testing.expectEqualStrings(shown, (try mcpFailureDetail(arena, shown)).?);
}

// Secret-shaped test needles are written as concatenated fragments so
// interactive tool-result masking never rewrites the literal in flight.
test "failure status detail masks secret-shaped failure output" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const call: ToolCall = .{
        .id = "call_fail",
        .name = "mcp__fixture__echo",
        .arguments_json = "{}",
    };
    const result: ToolExecutionResult = .{
        .model_output = "",
        .status = .failure,
        .status_detail = "preflight failed",
    };
    const failure_output = "MY_NOTE_" ++ "TOKEN=abcdefgh";
    const detail = (try failureStatusDetail(arena, call, result, failure_output, &.{})).?;
    try std.testing.expect(std.mem.find(u8, detail, "[redacted]") != null);
    try std.testing.expect(std.mem.find(u8, detail, "abcdefgh") == null);
}

test "failure status detail masks the actionable edit failure reason" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const call: ToolCall = .{
        .id = "call_edit_fail",
        .name = "edit_file",
        .arguments_json = "{}",
    };
    const result: ToolExecutionResult = .{
        .model_output = "",
        .status = .failure,
        .status_detail = "preflight failed",
    };
    const failure_output = "edit_file failed: MY_NOTE_" ++ "TOKEN=abcdefgh";
    const detail = (try failureStatusDetail(arena, call, result, failure_output, &.{})).?;
    try std.testing.expectEqualStrings("MY_NOTE_" ++ "TOKEN=[redacted]", detail);
}

test "failure status detail shows the first line of a multi-line edit failure" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const call: ToolCall = .{
        .id = "call_edit_fail",
        .name = "edit_file",
        .arguments_json = "{}",
    };
    const result: ToolExecutionResult = .{
        .model_output = "",
        .status = .failure,
        .status_detail = "preflight failed",
    };
    const failure_output = "edit_file failed: old_string not found in file; the closest match is line 2.\nIt currently reads:\nconst limit = 3;\nIf the change is already applied, do not retry this edit.";
    const detail = (try failureStatusDetail(arena, call, result, failure_output, &.{})).?;
    try std.testing.expectEqualStrings("old_string not found in file; the closest match is line 2.", detail);
}

test "failure status detail terminal-encodes the actionable edit failure reason" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const call: ToolCall = .{
        .id = "call_edit_fail",
        .name = "edit_file",
        .arguments_json = "{}",
    };
    const result: ToolExecutionResult = .{
        .model_output = "",
        .status = .failure,
        .status_detail = "preflight failed",
    };
    const failure_output = "edit_file failed: reset terminal\x1b[2J";
    const detail = (try failureStatusDetail(arena, call, result, failure_output, &.{})).?;
    try std.testing.expect(std.mem.findScalar(u8, detail, 0x1b) == null);
    try std.testing.expect(std.mem.find(u8, detail, "\\x1b") != null);
}
