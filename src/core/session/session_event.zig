const std = @import("std");
const builtin = @import("builtin");
const session = @import("session.zig");
const session_codec = @import("session_codec.zig");
const session_usage = @import("session_usage.zig");
const types = @import("../shared/types.zig");
const model_provider = @import("../config/model_provider.zig");
const context_limits = @import("../config/context_limits.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const event_frame_max_bytes: usize = context_limits.emergency_ceiling_bytes;
pub const raw_state_chunk_bytes: usize = 4 * 1024 * 1024;
pub const Identifier = [16]u8;
pub const Digest = [Sha256.digest_length]u8;

pub const conversation_schema_version: u8 = 2;
pub const max_conversation_text_bytes: usize = event_frame_max_bytes;
pub const max_conversation_identity_bytes: usize = types.ConversationIdentity.max_bytes;
pub const max_conversation_arguments_bytes: usize = event_frame_max_bytes;
pub const max_conversation_preview_bytes: usize = 4 * 1024;

pub const ArtifactCompleteness = enum {
    complete,
    partial,
    unknown,
};

pub const ConversationText = struct {
    text: []const u8,
};

pub const ConversationAssistant = struct {
    text: []const u8,
    provider_replay: ?types.ProviderReplay = null,
    standalone_response: bool = false,
};

pub const ConversationUser = struct {
    text: []const u8,
    images: []const types.ImageAttachment = &.{},
    work_id: ?[]const u8 = null,
};

pub const ConversationToolCall = struct {
    call_id: []const u8,
    tool_name: []const u8,
    arguments_json: []const u8,
    argument_integrity: types.ToolArgumentIntegrity = .valid,
    provisional_id: ?[]const u8 = null,
    provider_result: ?[]const u8 = null,
    final_identity: types.FinalToolIdentity = .valid,
    provenance: types.ToolExecutionProvenance = .fx_local,
};

pub const ConversationToolResult = struct {
    call_id: []const u8,
    tool_name: []const u8,
    status: types.PersistedToolStatus,
    artifact_ref: []const u8,
    tool_image_handle: ?[]const u8 = null,
    output_bytes: ?u64 = null,
    stored_bytes: u64,
    completeness: ArtifactCompleteness,
    preview: ?[]const u8 = null,
    provider_native: bool = false,
    created_at_ms: i64 = 0,
    permission_feedback: []const []const u8 = &.{},
    committed_file_presentation: ?types.CommittedFilePresentation = null,
    command_replay_ref: ?[]const u8 = null,
    command_replay_bytes: ?u64 = null,
    command_process_presentation: ?types.CommandProcessPresentation = null,
    terminal_action_presentation: ?types.TerminalActionPresentation = null,
};

pub const ConversationInterruption = struct {
    reason: session.InterruptedTerminalReason,
    partial_text: ?[]const u8 = null,
    command_replay_ref: ?[]const u8 = null,
    command_replay_bytes: ?u64 = null,
    command_artifact_ref: ?[]const u8 = null,
    files: []const types.FileEvidence = &.{},
    turn_summary: ?types.TurnSummary = null,
};

pub const ConversationTurnCompleted = struct {
    files: []const types.FileEvidence = &.{},
    turn_summary: ?types.TurnSummary = null,
};

pub const ConversationCheckpoint = struct {
    covers_through_seq: u64,
    summary: []const u8,
};

pub const ConversationEvent = union(enum) {
    user: ConversationUser,
    assistant: ConversationAssistant,
    tool_call: ConversationToolCall,
    tool_result: ConversationToolResult,
    steering: ConversationText,
    turn_completed: ConversationTurnCompleted,
    interrupted: ConversationInterruption,
    context_checkpoint: ConversationCheckpoint,
};

pub const ConversationEnvelope = struct {
    schema_version: u8 = conversation_schema_version,
    seq: u64,
    timestamp_ms: i64,
    event: ConversationEvent,
};

pub const DecodedConversationFrame = std.json.Parsed(ConversationEnvelope);

pub const PendingToolCall = struct {
    call_id: []const u8,
    tool_name: []const u8,
    seq: u64,
};

pub const ConversationStateView = struct {
    last_seq: u64 = 0,
    latest_checkpoint_coverage: u64 = 0,
    pending_tool_calls: []const PendingToolCall = &.{},
};

pub const ConversationTransitionError = error{
    UnsupportedConversationSchema,
    OutOfOrderConversationEvent,
    InvalidConversationEvent,
    DuplicateToolCall,
    OrphanToolResult,
    ToolIdentityMismatch,
    InvalidCheckpointCoverage,
    UnresolvedToolCall,
};

pub fn validateConversationTransition(
    state: ConversationStateView,
    envelope: ConversationEnvelope,
) ConversationTransitionError!void {
    if (envelope.schema_version != 1 and envelope.schema_version != conversation_schema_version) {
        return error.UnsupportedConversationSchema;
    }
    const expected_seq = std.math.add(u64, state.last_seq, 1) catch
        return error.OutOfOrderConversationEvent;
    if (envelope.seq != expected_seq) return error.OutOfOrderConversationEvent;
    if (envelope.timestamp_ms < 0) return error.InvalidConversationEvent;
    try validateConversationEventShape(envelope.event, envelope.schema_version);

    switch (envelope.event) {
        .tool_call => |call| {
            for (state.pending_tool_calls) |pending| {
                if (std.mem.eql(u8, pending.call_id, call.call_id)) {
                    return error.DuplicateToolCall;
                }
            }
        },
        .tool_result => |result| {
            const pending = findPendingToolCall(state.pending_tool_calls, result.call_id) orelse
                return error.OrphanToolResult;
            if (!std.mem.eql(u8, pending.tool_name, result.tool_name)) {
                return error.ToolIdentityMismatch;
            }
        },
        .context_checkpoint => |checkpoint| {
            if (checkpoint.covers_through_seq < state.latest_checkpoint_coverage or
                checkpoint.covers_through_seq > state.last_seq)
            {
                return error.InvalidCheckpointCoverage;
            }
            for (state.pending_tool_calls) |pending| {
                if (pending.seq <= checkpoint.covers_through_seq) {
                    return error.UnresolvedToolCall;
                }
            }
        },
        .turn_completed => if (state.pending_tool_calls.len != 0) {
            return error.UnresolvedToolCall;
        },
        .user, .assistant, .steering, .interrupted => {},
    }
}

fn validateConversationEventShape(event: ConversationEvent, schema_version: u8) ConversationTransitionError!void {
    switch (event) {
        .user => |value| {
            try validateConversationText(value.text);
            if (value.images.len > 128) return error.InvalidConversationEvent;
            for (value.images) |image| {
                if (image.path.len == 0 or
                    image.path.len > std.Io.Dir.max_path_bytes or
                    image.media_type.len == 0 or
                    image.media_type.len > max_conversation_identity_bytes or
                    !std.unicode.utf8ValidateSlice(image.path) or
                    !std.unicode.utf8ValidateSlice(image.media_type))
                {
                    return error.InvalidConversationEvent;
                }
            }
            if (value.work_id) |work_id| try validateConversationIdentity(work_id);
        },
        .assistant => |value| {
            if (schema_version == 1 and (value.text.len == 0 or value.provider_replay != null)) return error.InvalidConversationEvent;
            try validateOptionalConversationText(value.text);
            if (value.provider_replay) |replay| {
                try validateConversationIdentity(replay.source.model);
                if (replay.parts_json.len == 0 or replay.parts_json.len > types.ProviderReplay.max_bytes or
                    !std.unicode.utf8ValidateSlice(replay.parts_json)) return error.InvalidConversationEvent;
            }
        },
        .steering => |value| try validateConversationText(value.text),
        .tool_call => |call| {
            try validateConversationIdentity(call.call_id);
            try validateConversationIdentity(call.tool_name);
            if (call.arguments_json.len == 0 or
                call.arguments_json.len > max_conversation_arguments_bytes or
                !std.unicode.utf8ValidateSlice(call.arguments_json))
            {
                return error.InvalidConversationEvent;
            }
            if (call.provisional_id) |value| try validateConversationIdentity(value);
            if (call.provider_result) |value| {
                if (value.len > max_conversation_arguments_bytes or
                    !std.unicode.utf8ValidateSlice(value))
                {
                    return error.InvalidConversationEvent;
                }
            }
        },
        .tool_result => |result| {
            try validateConversationIdentity(result.call_id);
            try validateConversationIdentity(result.tool_name);
            if (result.artifact_ref.len == 0 or
                result.artifact_ref.len > max_conversation_identity_bytes or
                !std.unicode.utf8ValidateSlice(result.artifact_ref))
            {
                return error.InvalidConversationEvent;
            }
            if (result.preview) |preview| {
                if (preview.len > max_conversation_preview_bytes or
                    !std.unicode.utf8ValidateSlice(preview))
                {
                    return error.InvalidConversationEvent;
                }
            }
            if (result.tool_image_handle) |handle| {
                try validateConversationIdentity(handle);
            }
            if (result.created_at_ms < 0) return error.InvalidConversationEvent;
            for (result.permission_feedback) |feedback| {
                try validateOptionalConversationText(feedback);
            }
            if (result.committed_file_presentation) |presentation| {
                try validateConversationPath(presentation.path);
                for (presentation.lines) |line| {
                    try validateOptionalConversationText(line.text);
                }
                if (presentation.previous_content) |content| {
                    try validateOptionalConversationText(content);
                }
                if (presentation.after_content) |content| {
                    try validateOptionalConversationText(content);
                }
                if (presentation.lifecycle_id) |lifecycle_id| {
                    try validateConversationIdentity(lifecycle_id.call_id);
                }
            }
            if ((result.command_replay_ref == null) !=
                (result.command_replay_bytes == null))
            {
                return error.InvalidConversationEvent;
            }
            if (result.command_replay_ref) |handle| {
                try validateConversationIdentity(handle);
            }
        },
        .interrupted => |interrupted| {
            if (interrupted.partial_text) |text| try validateOptionalConversationText(text);
            if ((interrupted.command_replay_ref == null) !=
                (interrupted.command_replay_bytes == null))
            {
                return error.InvalidConversationEvent;
            }
            if (interrupted.command_replay_ref) |handle| {
                try validateConversationIdentity(handle);
            }
            if (interrupted.command_artifact_ref) |handle| {
                try validateConversationIdentity(handle);
            }
            try validateConversationFiles(interrupted.files);
        },
        .context_checkpoint => |checkpoint| try validateConversationText(checkpoint.summary),
        .turn_completed => |completed| try validateConversationFiles(completed.files),
    }
}

fn validateConversationFiles(files: []const types.FileEvidence) ConversationTransitionError!void {
    for (files) |file| {
        try validateConversationPath(file.path);
        if (file.new_path) |path| try validateConversationPath(path);
        try validateConversationIdentity(file.tool_call_id);
        try validateConversationIdentity(file.tool_name);
    }
}

fn validateConversationPath(path: []const u8) ConversationTransitionError!void {
    if (path.len == 0 or
        path.len > std.Io.Dir.max_path_bytes or
        !std.unicode.utf8ValidateSlice(path))
    {
        return error.InvalidConversationEvent;
    }
}

fn validateConversationText(text: []const u8) ConversationTransitionError!void {
    if (text.len == 0) return error.InvalidConversationEvent;
    return validateOptionalConversationText(text);
}

fn validateOptionalConversationText(text: []const u8) ConversationTransitionError!void {
    if (text.len > max_conversation_text_bytes or !std.unicode.utf8ValidateSlice(text)) {
        return error.InvalidConversationEvent;
    }
}

fn validateConversationIdentity(value: []const u8) ConversationTransitionError!void {
    if (types.ConversationIdentity.invalidReason(value) != null) {
        return error.InvalidConversationEvent;
    }
}

fn findPendingToolCall(
    pending_calls: []const PendingToolCall,
    call_id: []const u8,
) ?PendingToolCall {
    for (pending_calls) |pending| {
        if (std.mem.eql(u8, pending.call_id, call_id)) return pending;
    }
    return null;
}

pub fn encodeConversationFrame(
    alloc: Allocator,
    envelope: ConversationEnvelope,
) ![]u8 {
    if (envelope.schema_version != conversation_schema_version or
        envelope.seq == 0 or
        envelope.timestamp_ms < 0)
    {
        return error.InvalidConversationEvent;
    }
    try validateConversationEventShape(envelope.event, envelope.schema_version);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(envelope, .{}, &out.writer);
    try out.writer.writeByte('\n');
    if (out.written().len > event_frame_max_bytes) return error.EventFrameTooLarge;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

pub fn decodeConversationFrame(
    alloc: Allocator,
    bytes: []const u8,
) !DecodedConversationFrame {
    if (bytes.len == 0 or bytes.len > event_frame_max_bytes or bytes[bytes.len - 1] != '\n') {
        return error.InvalidConversationFrame;
    }
    var parsed = std.json.parseFromSlice(ConversationEnvelope, alloc, bytes, .{
        .allocate = .alloc_always,
        .max_value_len = event_frame_max_bytes,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidConversationFrame,
    };
    errdefer parsed.deinit();
    if ((parsed.value.schema_version != 1 and parsed.value.schema_version != conversation_schema_version) or
        parsed.value.seq == 0 or
        parsed.value.timestamp_ms < 0)
    {
        return error.InvalidConversationFrame;
    }
    validateConversationEventShape(parsed.value.event, parsed.value.schema_version) catch
        return error.InvalidConversationFrame;
    return parsed;
}

/// Appends borrowed conversational events for one canonical history turn.
/// The caller owns only the destination list storage; event payloads remain
/// valid for the lifetime of `turn`.
pub fn appendHistoryTurnConversationEvents(
    alloc: Allocator,
    events: *std.ArrayList(ConversationEvent),
    turn: types.HistoryTurn,
) !void {
    const initial_len = events.items.len;
    errdefer events.shrinkRetainingCapacity(initial_len);
    switch (turn) {
        .assistant => |entry| {
            try events.append(alloc, .{ .user = .{
                .text = entry.user.text,
                .images = entry.user.images,
                .work_id = entry.user.work_id,
            } });
            try appendExecutionConversationEvents(alloc, events, entry.execution);
            const follows_standalone = entry.execution.tool_steps.len > 0 and
                entry.execution.tool_steps[entry.execution.tool_steps.len - 1].tool_calls.len == 0;
            if (entry.assistant.len > 0 or entry.provider_replay != null or follows_standalone) {
                try events.append(alloc, .{ .assistant = .{ .text = entry.assistant, .provider_replay = entry.provider_replay } });
            }
            try events.append(alloc, .{ .turn_completed = .{
                .files = entry.execution.files,
                .turn_summary = entry.execution.turn_summary,
            } });
        },
        .interrupted => |entry| {
            try events.append(alloc, .{ .user = .{
                .text = entry.user.text,
                .images = entry.user.images,
                .work_id = entry.user.work_id,
            } });
            try appendExecutionConversationEvents(alloc, events, entry.execution);
            if (entry.tool_call) |call| {
                if (entry.execution.tool_steps.len > 0 and
                    entry.execution.tool_steps[entry.execution.tool_steps.len - 1].tool_calls.len == 0)
                {
                    try events.append(alloc, .{ .assistant = .{ .text = "" } });
                }
                try events.append(alloc, .{ .tool_call = .{
                    .call_id = call.id,
                    .tool_name = call.name,
                    .arguments_json = call.arguments_json,
                    .argument_integrity = call.argument_integrity,
                    .provisional_id = call.provisional_id,
                    .provider_result = call.provider_result,
                    .final_identity = call.final_identity,
                    .provenance = call.provenance,
                } });
            }
            try events.append(alloc, .{ .interrupted = .{
                .reason = entry.terminal_reason,
                .partial_text = entry.assistant,
                .command_replay_ref = interruptedCommandReplayRef(entry),
                .command_replay_bytes = interruptedCommandReplayBytes(entry),
                .command_artifact_ref = if (entry.cancelled_command) |presentation|
                    presentation.command_artifact_handle
                else
                    null,
                .files = entry.execution.files,
                .turn_summary = entry.execution.turn_summary,
            } });
        },
        .compacted_summary => return error.ConversationCheckpointRequiresSequence,
    }
}

fn interruptedCommandReplayRef(
    entry: types.InterruptedHistoryTurn,
) ?[]const u8 {
    const replay = (entry.cancelled_command orelse return null).output_replay orelse
        return null;
    return switch (replay) {
        .available => |descriptor| descriptor.handle,
        .unavailable => null,
    };
}

fn interruptedCommandReplayBytes(
    entry: types.InterruptedHistoryTurn,
) ?u64 {
    const replay = (entry.cancelled_command orelse return null).output_replay orelse
        return null;
    return switch (replay) {
        .available => |descriptor| @intCast(descriptor.framed_bytes),
        .unavailable => null,
    };
}

fn appendExecutionConversationEvents(
    alloc: Allocator,
    events: *std.ArrayList(ConversationEvent),
    execution: types.ExecutionMemory,
) !void {
    var steering_index: usize = 0;
    while (steering_index < execution.steering.len and
        execution.steering[steering_index].after_tool_step_count == 0)
    {
        try appendSteeringConversationEvents(alloc, events, execution.steering[steering_index]);
        steering_index += 1;
    }
    for (execution.tool_steps, 0..) |step, step_index| {
        const assistant: []const u8 = step.assistant orelse "";
        const follows_standalone = step_index > 0 and execution.tool_steps[step_index - 1].tool_calls.len == 0;
        if (assistant.len > 0 or step.provider_replay != null or follows_standalone) {
            try events.append(alloc, .{ .assistant = .{
                .text = assistant,
                .provider_replay = step.provider_replay,
                .standalone_response = step.tool_calls.len == 0,
            } });
        }
        for (step.tool_calls) |call| {
            try events.append(alloc, .{ .tool_call = .{
                .call_id = call.id,
                .tool_name = call.name,
                .arguments_json = call.arguments_json,
                .argument_integrity = call.argument_integrity,
                .provisional_id = call.provisional_id,
                .provider_result = call.provider_result,
                .final_identity = call.final_identity,
                .provenance = call.provenance,
            } });
        }
        for (step.tool_results) |result| {
            const artifact_ref = resultArtifactRef(result) orelse
                return error.ConversationArtifactRequired;
            if (result.tool_images.len > 0 and result.tool_image_handle == null) {
                return error.ConversationArtifactRequired;
            }
            try events.append(alloc, .{ .tool_result = .{
                .call_id = result.tool_call_id,
                .tool_name = result.tool_name,
                .status = result.status,
                .artifact_ref = artifact_ref,
                .tool_image_handle = result.tool_image_handle,
                .output_bytes = std.math.cast(u64, result.output_bytes) orelse
                    return error.InvalidConversationEvent,
                .stored_bytes = std.math.cast(u64, result.stored_output_bytes) orelse
                    return error.InvalidConversationEvent,
                .completeness = if (result.truncated) .partial else .complete,
                .preview = result.preview orelse if (result.output.len <= max_conversation_preview_bytes)
                    result.output
                else
                    null,
                .provider_native = result.provider_native,
                .created_at_ms = result.created_at_ms,
                .permission_feedback = result.permission_feedback,
                .committed_file_presentation = result.committed_file_presentation,
                .command_replay_ref = resultCommandReplayRef(result),
                .command_replay_bytes = resultCommandReplayBytes(result),
                .command_process_presentation = result.command_process_presentation,
                .terminal_action_presentation = result.terminal_action_presentation,
            } });
        }
        const completed_steps = step_index + 1;
        while (steering_index < execution.steering.len and
            execution.steering[steering_index].after_tool_step_count == completed_steps)
        {
            try appendSteeringConversationEvents(alloc, events, execution.steering[steering_index]);
            steering_index += 1;
        }
    }
    if (steering_index != execution.steering.len) {
        return error.InvalidConversationEvent;
    }
}

fn appendSteeringConversationEvents(
    alloc: Allocator,
    events: *std.ArrayList(ConversationEvent),
    steering: types.PersistedSteering,
) !void {
    if (steering.assistant_prefix) |assistant| {
        if (assistant.len > 0) try events.append(alloc, .{ .assistant = .{ .text = assistant } });
    }
    if (steering.text.len > 0) {
        try events.append(alloc, .{ .steering = .{ .text = steering.text } });
    }
}

fn resultArtifactRef(result: types.PersistedToolResult) ?[]const u8 {
    if (result.output_handle) |handle| return handle;
    const replay = result.command_output_replay orelse return null;
    return switch (replay) {
        .available => |descriptor| descriptor.handle,
        .unavailable => null,
    };
}

fn resultCommandReplayRef(result: types.PersistedToolResult) ?[]const u8 {
    const replay = result.command_output_replay orelse return null;
    return switch (replay) {
        .available => |descriptor| descriptor.handle,
        .unavailable => null,
    };
}

fn resultCommandReplayBytes(result: types.PersistedToolResult) ?u64 {
    const replay = result.command_output_replay orelse return null;
    return switch (replay) {
        .available => |descriptor| @intCast(descriptor.framed_bytes),
        .unavailable => null,
    };
}

pub const Kind = enum {
    session_started,
    preferences_changed,
    workspace_rebound,
    history_turn_committed,
    usage_checkpointed,
    recovery_checkpoint_set,
    recovery_checkpoint_cleared,
    state_replacement_started,
    state_replacement_chunk,
    state_replacement_committed,
};

pub const ReplacementReason = enum {
    compaction,
    migration,
    recovery,
    log_compaction,
};

pub const SessionStarted = struct {
    id: []u8,
    created_at_ms: i64,
    origin_workspace_root: []u8,
    workspace_root: []u8,
    conversation_language: session.ConversationLanguage,
    preferences: session_codec.DurableSessionPreferences,
    usage: ?session_usage.Snapshot = null,
    subagent_child: bool = false,

    fn deinit(self: *SessionStarted, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.origin_workspace_root);
        alloc.free(self.workspace_root);
        self.preferences.deinit(alloc);
        if (self.usage) |*usage| usage.deinit(alloc);
        self.* = undefined;
    }
};

pub const PreferencesChanged = struct {
    provider: ?model_provider.ProviderId = null,
    model: ?[]u8 = null,
    effort: ?types.ReasoningEffort = null,
    fast_mode: ?bool = null,

    fn deinit(self: *PreferencesChanged, alloc: Allocator) void {
        if (self.model) |model| alloc.free(model);
        self.* = undefined;
    }
};

pub const WorkspaceRebound = struct {
    previous_workspace_root: []u8,
    workspace_root: []u8,

    fn deinit(self: *WorkspaceRebound, alloc: Allocator) void {
        alloc.free(self.previous_workspace_root);
        alloc.free(self.workspace_root);
        self.* = undefined;
    }
};

pub const HistoryTurnCommitted = struct {
    conversation_language: session.ConversationLanguage,
    total_input_tokens: u64,
    total_output_tokens: u64,
    work_id: ?[]u8 = null,
    turn: session.HistoryTurn,

    fn deinit(self: *HistoryTurnCommitted, alloc: Allocator) void {
        if (self.work_id) |id| alloc.free(id);
        session.freeHistoryTurn(alloc, self.turn);
        self.* = undefined;
    }
};

pub const UsageCheckpointed = struct {
    /// Full cumulative replacement; reducers must not add it to prior usage.
    usage: session_usage.Snapshot,

    fn deinit(self: *UsageCheckpointed, alloc: Allocator) void {
        self.usage.deinit(alloc);
        self.* = undefined;
    }
};

pub const RecoveryCheckpointSet = struct {
    checkpoint: session_codec.RecoveryCheckpoint,

    fn deinit(self: *RecoveryCheckpointSet, alloc: Allocator) void {
        self.checkpoint.deinit(alloc);
        self.* = undefined;
    }
};

pub const RecoveryCheckpointCleared = struct {};

pub const StateReplacementStarted = struct {
    replacement_id: Identifier,
    reason: ReplacementReason,
    encoded_bytes: u64,
    sha256: Digest,
    chunk_count: u64,
};

pub const StateReplacementChunk = struct {
    replacement_id: Identifier,
    chunk_index: u64,
    raw_bytes: u64,
    chunk_sha256: Digest,
    bytes: []u8,

    fn deinit(self: *StateReplacementChunk, alloc: Allocator) void {
        alloc.free(self.bytes);
        self.* = undefined;
    }
};

pub const StateReplacementCommitted = struct {
    replacement_id: Identifier,
    encoded_bytes: u64,
    sha256: Digest,
    chunk_count: u64,
};

pub const Event = union(Kind) {
    session_started: SessionStarted,
    preferences_changed: PreferencesChanged,
    workspace_rebound: WorkspaceRebound,
    history_turn_committed: HistoryTurnCommitted,
    usage_checkpointed: UsageCheckpointed,
    recovery_checkpoint_set: RecoveryCheckpointSet,
    recovery_checkpoint_cleared: RecoveryCheckpointCleared,
    state_replacement_started: StateReplacementStarted,
    state_replacement_chunk: StateReplacementChunk,
    state_replacement_committed: StateReplacementCommitted,

    fn deinit(self: *Event, alloc: Allocator) void {
        switch (self.*) {
            .session_started => |*payload| payload.deinit(alloc),
            .preferences_changed => |*payload| payload.deinit(alloc),
            .workspace_rebound => |*payload| payload.deinit(alloc),
            .history_turn_committed => |*payload| payload.deinit(alloc),
            .usage_checkpointed => |*payload| payload.deinit(alloc),
            .recovery_checkpoint_set => |*payload| payload.deinit(alloc),
            .recovery_checkpoint_cleared => {},
            .state_replacement_chunk => |*payload| payload.deinit(alloc),
            .state_replacement_started, .state_replacement_committed => {},
        }
        self.* = undefined;
    }
};

pub const Envelope = struct {
    log_generation: Identifier,
    seq: u64,
    event_id: Identifier,
    timestamp_ms: i64,
    event: Event,

    pub fn kind(self: Envelope) Kind {
        return std.meta.activeTag(self.event);
    }

    pub fn deinit(self: *Envelope, alloc: Allocator) void {
        self.event.deinit(alloc);
        self.* = undefined;
    }
};

pub const SequenceValidator = struct {
    generation: ?Identifier = null,
    next_seq: u64 = 1,

    pub fn validate(self: *SequenceValidator, envelope: Envelope) !void {
        if (envelope.seq != self.next_seq) return error.NonContiguousSequence;
        if (self.generation) |generation| {
            if (!std.mem.eql(u8, &generation, &envelope.log_generation)) {
                return error.GenerationChanged;
            }
        } else {
            self.generation = envelope.log_generation;
        }
        self.next_seq = std.math.add(u64, self.next_seq, 1) catch
            return error.NonContiguousSequence;
    }
};

pub const ReductionStart = struct {
    generation: ?Identifier = null,
    next_seq: u64 = 1,
};

pub const ReductionBoundary = struct {
    log_generation: Identifier,
    seq: u64,
    event_id: Identifier,
    byte_offset: u64,
};

pub const Reduction = struct {
    state: session_codec.DurableSessionState,
    truncate_from: ?u64 = null,
    through: ?ReductionBoundary = null,
    bytes_consumed: u64 = 0,

    pub fn deinit(self: *Reduction, alloc: Allocator) void {
        self.state.deinit(alloc);
        self.* = undefined;
    }
};

/// Test-fixture encoder for the read-only v3 importer. Current runtime code
/// must never emit the legacy envelope.
pub fn encodeLegacyFixtureFrame(alloc: Allocator, envelope: Envelope) ![]u8 {
    if (!builtin.is_test) @compileError("legacy session encoding is test-only");
    try validateEnvelope(envelope);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"schema_version\":1,\"log_generation\":");
    try writeHexString(&out.writer, &envelope.log_generation);
    try out.writer.print(",\"seq\":{d},\"event_id\":", .{envelope.seq});
    try writeHexString(&out.writer, &envelope.event_id);
    try out.writer.print(",\"timestamp_ms\":{d},\"kind\":", .{envelope.timestamp_ms});
    try writeJsonString(&out.writer, @tagName(envelope.kind()));
    try out.writer.writeAll(",\"payload\":");
    try writePayload(&out.writer, envelope.event);
    try out.writer.writeAll("}\n");
    if (out.written().len > event_frame_max_bytes) return error.EventFrameTooLarge;
    return try out.toOwnedSlice();
}

inline fn failEnvelope(err: anytype) @TypeOf(err)!Envelope {
    return @errorCast(failEnvelopeDynamic(err));
}

noinline fn failEnvelopeDynamic(err: anyerror) anyerror!Envelope {
    return err;
}

test "session envelope failures preserve exact error types and identities" {
    const invalid = failEnvelope(error.InvalidEventFrame);
    try std.testing.expect(@TypeOf(invalid) == error{InvalidEventFrame}!Envelope);
    try std.testing.expectError(error.InvalidEventFrame, invalid);
    try std.testing.expectError(error.OutOfMemory, failEnvelope(error.OutOfMemory));
}

pub fn decodeFrame(alloc: Allocator, line: []const u8) !Envelope {
    if (line.len > event_frame_max_bytes) return failEnvelope(error.EventFrameTooLarge);
    if (line.len == 0 or line[line.len - 1] != '\n') {
        return failEnvelope(error.InvalidEventFrame);
    }
    if (std.mem.indexOfScalar(u8, line[0 .. line.len - 1], '\n') != null) {
        return failEnvelope(error.InvalidEventFrame);
    }

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, line[0 .. line.len - 1], .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return failEnvelope(error.OutOfMemory),
        else => return failEnvelope(error.InvalidEventFrame),
    };
    defer parsed.deinit();
    const root = try exactObject(parsed.value, &.{
        "schema_version",
        "log_generation",
        "seq",
        "event_id",
        "timestamp_ms",
        "kind",
        "payload",
    });
    if (try requireU64(root, "schema_version") != 1) return failEnvelope(error.UnsupportedEventSchema);
    const kind = std.meta.stringToEnum(Kind, try requireString(root, "kind")) orelse
        return failEnvelope(error.InvalidEventFrame);
    var envelope = Envelope{
        .log_generation = try parseIdentifier(try requireString(root, "log_generation")),
        .seq = try requireU64(root, "seq"),
        .event_id = try parseIdentifier(try requireString(root, "event_id")),
        .timestamp_ms = try requireI64(root, "timestamp_ms"),
        .event = try parsePayload(alloc, kind, root.get("payload") orelse return failEnvelope(error.InvalidEventFrame)),
    };
    errdefer envelope.deinit(alloc);
    try validateEnvelope(envelope);
    return envelope;
}

pub fn reduceJsonl(
    alloc: Allocator,
    source: *std.Io.Reader,
    initial: ?session_codec.DurableSessionState,
) !Reduction {
    return reduceJsonlFrom(alloc, source, initial, .{});
}

/// Applies one contiguous semantic event frame to caller-owned state.
/// On failure, `state` remains valid and unchanged.
pub fn applyEventFrame(
    alloc: Allocator,
    state: *session_codec.DurableSessionState,
    frame: []const u8,
    start: ReductionStart,
    expected_event_id: Identifier,
) !ReductionBoundary {
    if (start.generation == null or start.next_seq == 0) {
        return error.InvalidReductionStart;
    }
    const frame_bytes = std.math.cast(u64, frame.len) orelse
        return error.InvalidEventFrame;
    var envelope = try decodeFrame(alloc, frame);
    defer envelope.deinit(alloc);
    var validator = SequenceValidator{
        .generation = start.generation,
        .next_seq = start.next_seq,
    };
    try validator.validate(envelope);
    if (!std.mem.eql(u8, &envelope.event_id, &expected_event_id)) {
        return error.InvalidEventFrame;
    }
    if (envelope.kind() == .session_started or
        envelope.kind() == .state_replacement_started or
        envelope.kind() == .state_replacement_chunk or
        envelope.kind() == .state_replacement_committed)
    {
        return error.InvalidEventFrame;
    }

    var current: ?session_codec.DurableSessionState = state.*;
    try applyDelta(alloc, &current, envelope);
    state.* = current.?;
    return reductionBoundary(envelope, frame_bytes);
}

inline fn failReduction(err: anytype) @TypeOf(err)!Reduction {
    return @errorCast(failReductionDynamic(err));
}

noinline fn failReductionDynamic(err: anyerror) anyerror!Reduction {
    return err;
}

test "session event reduction failures preserve exact error types and identities" {
    const invalid = failReduction(error.InvalidReductionStart);
    try std.testing.expect(
        @TypeOf(invalid) == error{InvalidReductionStart}!Reduction,
    );
    try std.testing.expectError(error.InvalidReductionStart, invalid);
    try std.testing.expectError(error.MissingSessionStarted, failReduction(error.MissingSessionStarted));
}

pub fn reduceJsonlFrom(
    alloc: Allocator,
    source: *std.Io.Reader,
    initial: ?session_codec.DurableSessionState,
    start: ReductionStart,
) !Reduction {
    var state = initial;
    errdefer if (state) |*owned| owned.deinit(alloc);
    if (start.next_seq == 0 or
        (state == null and (start.generation != null or start.next_seq != 1)))
    {
        return failReduction(error.InvalidReductionStart);
    }
    var validator = SequenceValidator{
        .generation = start.generation,
        .next_seq = start.next_seq,
    };
    var byte_offset: u64 = 0;
    var through: ?ReductionBoundary = null;

    while (true) {
        const line = readFrameLine(alloc, source) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        defer alloc.free(line);
        const frame_start = byte_offset;
        byte_offset += line.len;

        var envelope = try decodeFrame(alloc, line);
        defer envelope.deinit(alloc);
        try validator.validate(envelope);

        if (envelope.kind() == .state_replacement_started) {
            if (state == null) return failReduction(error.InvalidReplacement);
            const replacement = try reduceReplacement(
                alloc,
                source,
                &validator,
                &byte_offset,
                envelope,
                state.?,
            );
            if (replacement.state) |next| {
                state.?.deinit(alloc);
                state = next;
                through = replacement.through;
            } else {
                return .{
                    .state = state.?,
                    .truncate_from = frame_start,
                    .through = through,
                    .bytes_consumed = byte_offset,
                };
            }
            continue;
        }
        if (envelope.kind() == .state_replacement_chunk or
            envelope.kind() == .state_replacement_committed)
        {
            return failReduction(error.InvalidReplacement);
        }
        try applyDelta(alloc, &state, envelope);
        through = reductionBoundary(envelope, byte_offset);
    }

    return .{
        .state = state orelse return failReduction(error.MissingSessionStarted),
        .through = through,
        .bytes_consumed = byte_offset,
    };
}

const ReplacementOutcome = struct {
    state: ?session_codec.DurableSessionState,
    through: ?ReductionBoundary = null,
};

fn reduceReplacement(
    alloc: Allocator,
    source: *std.Io.Reader,
    validator: *SequenceValidator,
    byte_offset: *u64,
    start_envelope: Envelope,
    prior: session_codec.DurableSessionState,
) !ReplacementOutcome {
    const start = start_envelope.event.state_replacement_started;
    var chunk_reader: ReplacementStateReader = undefined;
    try chunk_reader.init(
        alloc,
        source,
        validator,
        byte_offset,
        start_envelope.log_generation,
        start,
    );
    defer chunk_reader.deinit();

    var decoded = session_codec.decodeState(alloc, &chunk_reader.interface, .{}) catch |err| {
        if (chunk_reader.truncated) return .{ .state = null };
        if (chunk_reader.failure) |failure| return failure;
        return err;
    };
    errdefer decoded.deinit(alloc);
    try chunk_reader.finish();

    const commit_line = readFrameLine(alloc, source) catch |err| switch (err) {
        error.EndOfStream, error.TruncatedEventFrame => {
            decoded.deinit(alloc);
            return .{ .state = null };
        },
        else => return err,
    };
    defer alloc.free(commit_line);
    byte_offset.* += commit_line.len;
    var commit_envelope = try decodeFrame(alloc, commit_line);
    defer commit_envelope.deinit(alloc);
    try validator.validate(commit_envelope);
    if (commit_envelope.kind() != .state_replacement_committed) return error.InvalidReplacement;
    const commit = commit_envelope.event.state_replacement_committed;
    if (!std.mem.eql(u8, &commit.replacement_id, &start.replacement_id) or
        commit.encoded_bytes != start.encoded_bytes or
        commit.chunk_count != start.chunk_count or
        !std.mem.eql(u8, &commit.sha256, &start.sha256))
    {
        return error.InvalidReplacement;
    }

    if (!std.mem.eql(u8, decoded.id, prior.id) or
        decoded.created_at_ms != prior.created_at_ms or
        !std.mem.eql(u8, decoded.origin_workspace_root, prior.origin_workspace_root) or
        !std.mem.eql(u8, decoded.workspace_root, prior.workspace_root) or
        decoded.updated_at_ms != commit_envelope.timestamp_ms)
    {
        return error.ImmutableSessionIdentity;
    }
    if (start.reason == .log_compaction and
        commit_envelope.timestamp_ms != prior.updated_at_ms)
    {
        return error.InvalidReplacement;
    }
    return .{
        .state = decoded,
        .through = reductionBoundary(commit_envelope, byte_offset.*),
    };
}

fn reductionBoundary(envelope: Envelope, byte_offset: u64) ReductionBoundary {
    return .{
        .log_generation = envelope.log_generation,
        .seq = envelope.seq,
        .event_id = envelope.event_id,
        .byte_offset = byte_offset,
    };
}

const ReplacementStateReader = struct {
    alloc: Allocator,
    source: *std.Io.Reader,
    validator: *SequenceValidator,
    byte_offset: *u64,
    generation: Identifier,
    start: StateReplacementStarted,
    chunk_index: u64 = 0,
    raw_total: u64 = 0,
    overall_sha256: Sha256 = Sha256.init(.{}),
    current: ?Envelope = null,
    current_offset: usize = 0,
    truncated: bool = false,
    failure: ?anyerror = null,
    buffer: [4096]u8 = undefined,
    interface: std.Io.Reader = undefined,

    fn init(
        self: *ReplacementStateReader,
        alloc: Allocator,
        source: *std.Io.Reader,
        validator: *SequenceValidator,
        byte_offset: *u64,
        generation: Identifier,
        start: StateReplacementStarted,
    ) !void {
        if (start.encoded_bytes == 0 or start.chunk_count == 0 or
            start.chunk_count != std.math.divCeil(
                u64,
                start.encoded_bytes,
                raw_state_chunk_bytes,
            ) catch return error.InvalidReplacement)
        {
            return error.InvalidReplacement;
        }
        self.* = .{
            .alloc = alloc,
            .source = source,
            .validator = validator,
            .byte_offset = byte_offset,
            .generation = generation,
            .start = start,
        };
        self.interface = .{
            .vtable = &.{
                .stream = stream,
                .readVec = readVec,
            },
            .buffer = &self.buffer,
            .seek = 0,
            .end = 0,
        };
    }

    fn deinit(self: *ReplacementStateReader) void {
        if (self.current) |*envelope| envelope.deinit(self.alloc);
        self.* = undefined;
    }

    fn finish(self: *ReplacementStateReader) !void {
        if (self.chunk_index != self.start.chunk_count or
            self.raw_total != self.start.encoded_bytes or
            !std.mem.eql(u8, &self.overall_sha256.finalResult(), &self.start.sha256))
        {
            return error.InvalidReplacement;
        }
    }

    fn readVec(reader: *std.Io.Reader, destinations: [][]u8) std.Io.Reader.Error!usize {
        const self: *ReplacementStateReader = @alignCast(@fieldParentPtr("interface", reader));
        for (destinations) |destination| {
            if (destination.len == 0) continue;
            return self.copyInto(destination) catch |err| {
                if (err == error.EndOfStream) return error.EndOfStream;
                self.failure = err;
                return error.ReadFailed;
            };
        }
        const destination = reader.buffer[reader.end..];
        if (destination.len == 0) return 0;
        const count = self.copyInto(destination) catch |err| {
            if (err == error.EndOfStream) return error.EndOfStream;
            self.failure = err;
            return error.ReadFailed;
        };
        reader.end += count;
        return 0;
    }

    fn copyInto(self: *ReplacementStateReader, destination: []u8) !usize {
        if (self.currentBytes().len == 0) try self.loadChunk();
        const available = self.currentBytes();
        const count = @min(destination.len, available.len);
        @memcpy(destination[0..count], available[0..count]);
        self.current_offset += count;
        return count;
    }

    fn stream(
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const destination = limit.slice(try writer.writableSliceGreedy(1));
        var destinations = [1][]u8{destination};
        const count = readVec(reader, &destinations) catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            error.ReadFailed => return error.ReadFailed,
        };
        writer.advance(count);
        return count;
    }

    fn currentBytes(self: *ReplacementStateReader) []const u8 {
        const envelope = self.current orelse return &.{};
        const bytes = envelope.event.state_replacement_chunk.bytes;
        return bytes[self.current_offset..];
    }

    fn loadChunk(self: *ReplacementStateReader) !void {
        if (self.current) |*envelope| {
            envelope.deinit(self.alloc);
            self.current = null;
        }
        self.current_offset = 0;
        if (self.chunk_index == self.start.chunk_count) return error.EndOfStream;

        const line = readFrameLine(self.alloc, self.source) catch |err| switch (err) {
            error.EndOfStream, error.TruncatedEventFrame => {
                self.truncated = true;
                return error.EndOfStream;
            },
            else => return err,
        };
        defer self.alloc.free(line);
        self.byte_offset.* += line.len;
        var envelope = try decodeFrame(self.alloc, line);
        errdefer envelope.deinit(self.alloc);
        try self.validator.validate(envelope);
        if (!std.mem.eql(u8, &envelope.log_generation, &self.generation) or
            envelope.kind() != .state_replacement_chunk)
        {
            return error.InvalidReplacement;
        }
        const chunk = envelope.event.state_replacement_chunk;
        const final = self.chunk_index + 1 == self.start.chunk_count;
        const expected_raw: u64 = if (final)
            self.start.encoded_bytes - self.raw_total
        else
            raw_state_chunk_bytes;
        if (!std.mem.eql(u8, &chunk.replacement_id, &self.start.replacement_id) or
            chunk.chunk_index != self.chunk_index or
            chunk.raw_bytes != expected_raw or
            chunk.bytes.len != expected_raw or
            (!final and chunk.raw_bytes != raw_state_chunk_bytes) or
            (final and (chunk.raw_bytes == 0 or chunk.raw_bytes > raw_state_chunk_bytes)) or
            !std.mem.eql(u8, &sha256(chunk.bytes), &chunk.chunk_sha256))
        {
            return error.InvalidReplacement;
        }
        self.overall_sha256.update(chunk.bytes);
        self.raw_total += chunk.raw_bytes;
        self.chunk_index += 1;
        self.current = envelope;
    }
};

fn applyDelta(
    alloc: Allocator,
    state: *?session_codec.DurableSessionState,
    envelope: Envelope,
) !void {
    switch (envelope.event) {
        .session_started => |payload| {
            if (state.* != null) {
                return error.ImmutableSessionIdentity;
            }
            var next = session_codec.DurableSessionState{
                .id = try alloc.dupe(u8, payload.id),
                .origin_workspace_root = undefined,
                .workspace_root = undefined,
                .created_at_ms = payload.created_at_ms,
                .updated_at_ms = envelope.timestamp_ms,
                .conversation_language = payload.conversation_language,
                .preferences = undefined,
                .history = &.{},
                .total_input_tokens = 0,
                .total_output_tokens = 0,
                .subagent_child = payload.subagent_child,
            };
            errdefer alloc.free(next.id);
            next.origin_workspace_root = try alloc.dupe(u8, payload.origin_workspace_root);
            errdefer alloc.free(next.origin_workspace_root);
            next.workspace_root = try alloc.dupe(u8, payload.workspace_root);
            errdefer alloc.free(next.workspace_root);
            next.preferences = try payload.preferences.dupe(alloc);
            errdefer next.preferences.deinit(alloc);
            next.usage = if (payload.usage) |snapshot|
                try session_usage.dupeSnapshotOwned(alloc, snapshot)
            else
                null;
            errdefer if (next.usage) |*usage| usage.deinit(alloc);
            try session_codec.validateState(next);
            state.* = next;
        },
        .preferences_changed => |payload| {
            var current = &(state.* orelse return error.MissingSessionStarted);
            var proposed = current.*;
            if (payload.provider) |provider| proposed.preferences.provider = provider;
            if (payload.model) |model| proposed.preferences.model = model;
            if (payload.effort) |effort| proposed.preferences.effort = effort;
            if (payload.fast_mode) |fast_mode| proposed.preferences.fast_mode = fast_mode;
            proposed.updated_at_ms = envelope.timestamp_ms;
            try session_codec.validateState(proposed);
            const model_copy = if (payload.model) |model|
                try alloc.dupe(u8, model)
            else
                null;
            if (model_copy) |copy| {
                alloc.free(current.preferences.model);
                current.preferences.model = copy;
            }
            if (payload.provider) |provider| current.preferences.provider = provider;
            if (payload.effort) |effort| current.preferences.effort = effort;
            if (payload.fast_mode) |fast_mode| current.preferences.fast_mode = fast_mode;
            current.updated_at_ms = envelope.timestamp_ms;
        },
        .workspace_rebound => |payload| {
            var current = &(state.* orelse return error.MissingSessionStarted);
            if (!std.mem.eql(u8, payload.previous_workspace_root, current.workspace_root) or
                std.mem.eql(u8, payload.workspace_root, current.workspace_root))
            {
                return error.ImmutableSessionIdentity;
            }
            var proposed = current.*;
            proposed.workspace_root = payload.workspace_root;
            proposed.updated_at_ms = envelope.timestamp_ms;
            try session_codec.validateState(proposed);
            const copy = try alloc.dupe(u8, payload.workspace_root);
            alloc.free(current.workspace_root);
            current.workspace_root = copy;
            current.updated_at_ms = envelope.timestamp_ms;
        },
        .history_turn_committed => |payload| {
            var current = &(state.* orelse return error.MissingSessionStarted);
            const association = session.decideWorkIdAssociation(
                payload.turn,
                payload.work_id,
            ) catch return error.InvalidEventFrame;
            var turn = try session.dupeHistoryTurn(alloc, payload.turn);
            errdefer session.freeHistoryTurn(alloc, turn);
            if (association == .copy_event) {
                session.copyWorkIdToTurn(alloc, &turn, payload.work_id.?) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidWorkId, error.ConflictingWorkId => return error.InvalidEventFrame,
                };
            }
            const work_id = if (payload.work_id) |id| try alloc.dupe(u8, id) else null;
            errdefer if (work_id) |id| alloc.free(id);
            if (current.history.len == 0) {
                current.history = try alloc.alloc(session.HistoryTurn, 1);
            } else {
                current.history = try alloc.realloc(current.history, current.history.len + 1);
            }
            current.history[current.history.len - 1] = turn;
            if (payload.turn == .compacted_summary) {
                current.context_history_start = current.history.len - 1;
            }
            current.conversation_language = payload.conversation_language;
            current.total_input_tokens = payload.total_input_tokens;
            current.total_output_tokens = payload.total_output_tokens;
            if (work_id) |id| {
                if (current.last_subagent_work_id) |old| alloc.free(old);
                current.last_subagent_work_id = id;
            }
            // A session owns at most one active model turn. Clearing its
            // checkpoint in the same reduction as the history commit closes
            // the crash window between durable completion and a later clear.
            if (current.recovery_checkpoint) |*checkpoint| checkpoint.deinit(alloc);
            current.recovery_checkpoint = null;
            current.updated_at_ms = envelope.timestamp_ms;
        },
        .usage_checkpointed => |payload| {
            var current = &(state.* orelse return error.MissingSessionStarted);
            const usage = try session_usage.dupeSnapshotOwned(alloc, payload.usage);
            if (current.usage) |*old| old.deinit(alloc);
            current.usage = usage;
            current.updated_at_ms = envelope.timestamp_ms;
        },
        .recovery_checkpoint_set => |payload| {
            var current = &(state.* orelse return error.MissingSessionStarted);
            const checkpoint = try payload.checkpoint.dupe(alloc);
            if (current.recovery_checkpoint) |*old| old.deinit(alloc);
            current.recovery_checkpoint = checkpoint;
            current.updated_at_ms = envelope.timestamp_ms;
        },
        .recovery_checkpoint_cleared => {
            var current = &(state.* orelse return error.MissingSessionStarted);
            if (current.recovery_checkpoint) |*checkpoint| checkpoint.deinit(alloc);
            current.recovery_checkpoint = null;
            current.updated_at_ms = envelope.timestamp_ms;
        },
        .state_replacement_started, .state_replacement_chunk, .state_replacement_committed => {
            return error.InvalidReplacement;
        },
    }
}

pub fn applyEventToState(
    alloc: Allocator,
    state: *session_codec.DurableSessionState,
    event: Event,
    timestamp_ms: i64,
) !void {
    const zero_id = [_]u8{0} ** 16;
    const envelope = Envelope{
        .log_generation = zero_id,
        .seq = 1,
        .event_id = zero_id,
        .timestamp_ms = timestamp_ms,
        .event = event,
    };
    try validateEnvelope(envelope);
    var current: ?session_codec.DurableSessionState = state.*;
    try applyDelta(alloc, &current, envelope);
    state.* = current.?;
}

fn validateEnvelope(envelope: Envelope) !void {
    if (envelope.seq == 0 or envelope.timestamp_ms < 0) return error.InvalidEventFrame;
    switch (envelope.event) {
        .session_started => |payload| {
            const state = session_codec.DurableSessionState{
                .id = payload.id,
                .origin_workspace_root = payload.origin_workspace_root,
                .workspace_root = payload.workspace_root,
                .created_at_ms = payload.created_at_ms,
                .updated_at_ms = envelope.timestamp_ms,
                .conversation_language = payload.conversation_language,
                .preferences = payload.preferences,
                .history = &.{},
                .total_input_tokens = 0,
                .total_output_tokens = 0,
                .usage = payload.usage,
                .subagent_child = payload.subagent_child,
            };
            try session_codec.validateState(state);
        },
        .preferences_changed => |payload| {
            if (payload.provider == null and payload.model == null and payload.effort == null and payload.fast_mode == null) {
                return error.InvalidEventFrame;
            }
            if (payload.model) |model| {
                const state = session_codec.DurableSessionState{
                    .id = @constCast("validation"),
                    .origin_workspace_root = @constCast("/"),
                    .workspace_root = @constCast("/"),
                    .created_at_ms = 0,
                    .updated_at_ms = 0,
                    .conversation_language = session.ConversationLanguage.literal("en"),
                    .preferences = .{
                        .model = model,
                        .effort = .auto,
                        .fast_mode = false,
                    },
                    .history = &.{},
                    .total_input_tokens = 0,
                    .total_output_tokens = 0,
                };
                try session_codec.validateState(state);
            }
        },
        .workspace_rebound => |payload| {
            if (payload.previous_workspace_root.len == 0 or payload.workspace_root.len == 0) {
                return error.InvalidEventFrame;
            }
        },
        .history_turn_committed => |payload| _ = session.decideWorkIdAssociation(
            payload.turn,
            payload.work_id,
        ) catch return error.InvalidEventFrame,
        .usage_checkpointed => |payload| try session_usage.validateSnapshot(payload.usage),
        .recovery_checkpoint_set => |payload| {
            const state = session_codec.DurableSessionState{
                .id = @constCast("validation"),
                .origin_workspace_root = @constCast("/"),
                .workspace_root = @constCast("/"),
                .created_at_ms = 0,
                .updated_at_ms = 0,
                .conversation_language = session.ConversationLanguage.literal("en"),
                .preferences = .{
                    .model = @constCast("test/model"),
                    .effort = .auto,
                    .fast_mode = false,
                },
                .history = &.{},
                .total_input_tokens = 0,
                .total_output_tokens = 0,
                .recovery_checkpoint = payload.checkpoint,
            };
            try session_codec.validateState(state);
        },
        .recovery_checkpoint_cleared => {},
        .state_replacement_started => |payload| {
            if (payload.encoded_bytes == 0 or payload.chunk_count == 0) {
                return error.InvalidReplacement;
            }
        },
        .state_replacement_chunk => |payload| {
            if (payload.raw_bytes == 0 or payload.raw_bytes > raw_state_chunk_bytes or
                payload.bytes.len != payload.raw_bytes or
                !std.mem.eql(u8, &sha256(payload.bytes), &payload.chunk_sha256))
            {
                return error.InvalidReplacement;
            }
        },
        .state_replacement_committed => |payload| {
            if (payload.encoded_bytes == 0 or payload.chunk_count == 0) {
                return error.InvalidReplacement;
            }
        },
    }
}

fn writePayload(writer: *std.Io.Writer, event: Event) !void {
    switch (event) {
        .session_started => |payload| {
            try writer.writeAll("{\"id\":");
            try writeJsonString(writer, payload.id);
            try writer.print(",\"created_at_ms\":{d},\"origin_workspace_root\":", .{payload.created_at_ms});
            try writeJsonString(writer, payload.origin_workspace_root);
            try writer.writeAll(",\"workspace_root\":");
            try writeJsonString(writer, payload.workspace_root);
            try writer.writeAll(",\"conversation_language\":");
            try writeJsonString(writer, payload.conversation_language.view());
            try writer.writeAll(",\"preferences\":");
            try writePreferences(writer, payload.preferences);
            if (payload.usage) |usage| {
                try writer.writeAll(",\"usage\":");
                try session_usage.writeSnapshot(writer, usage);
            }
            if (payload.subagent_child) {
                try writer.writeAll(",\"subagent_child\":true");
            }
            try writer.writeByte('}');
        },
        .preferences_changed => |payload| {
            try writer.writeByte('{');
            var wrote = false;
            if (payload.provider) |provider| {
                try writer.writeAll("\"provider\":");
                try writeJsonString(writer, @tagName(provider));
                wrote = true;
            }
            if (payload.model) |model| {
                if (wrote) try writer.writeByte(',');
                try writer.writeAll("\"model\":");
                try writeJsonString(writer, model);
                wrote = true;
            }
            if (payload.effort) |effort| {
                if (wrote) try writer.writeByte(',');
                try writer.writeAll("\"effort\":");
                try writeJsonString(writer, effort.label());
                wrote = true;
            }
            if (payload.fast_mode) |fast_mode| {
                if (wrote) try writer.writeByte(',');
                try writer.print("\"fast_mode\":{s}", .{if (fast_mode) "true" else "false"});
            }
            try writer.writeByte('}');
        },
        .workspace_rebound => |payload| {
            try writer.writeAll("{\"previous_workspace_root\":");
            try writeJsonString(writer, payload.previous_workspace_root);
            try writer.writeAll(",\"workspace_root\":");
            try writeJsonString(writer, payload.workspace_root);
            try writer.writeByte('}');
        },
        .history_turn_committed => |payload| {
            try writer.writeAll("{\"conversation_language\":");
            try writeJsonString(writer, payload.conversation_language.view());
            try writer.print(",\"total_input_tokens\":{d},\"total_output_tokens\":{d},\"turn\":", .{
                payload.total_input_tokens,
                payload.total_output_tokens,
            });
            try session_codec.writeHistoryTurn(writer, payload.turn);
            if (payload.work_id) |id| {
                try writer.writeAll(",\"work_id\":");
                try writeJsonString(writer, id);
            }
            try writer.writeByte('}');
        },
        .usage_checkpointed => |payload| {
            try writer.writeAll("{\"usage\":");
            try session_usage.writeSnapshot(writer, payload.usage);
            try writer.writeByte('}');
        },
        .recovery_checkpoint_set => |payload| {
            try writer.writeAll("{\"checkpoint\":");
            try session_codec.writeRecoveryCheckpoint(writer, payload.checkpoint);
            try writer.writeByte('}');
        },
        .recovery_checkpoint_cleared => try writer.writeAll("{}"),
        .state_replacement_started => |payload| {
            try writer.writeAll("{\"replacement_id\":");
            try writeHexString(writer, &payload.replacement_id);
            try writer.writeAll(",\"reason\":");
            try writeJsonString(writer, @tagName(payload.reason));
            try writer.print(",\"encoded_bytes\":{d},\"sha256\":", .{payload.encoded_bytes});
            try writeHexString(writer, &payload.sha256);
            try writer.print(",\"chunk_count\":{d}}}", .{payload.chunk_count});
        },
        .state_replacement_chunk => |payload| {
            try writer.writeAll("{\"replacement_id\":");
            try writeHexString(writer, &payload.replacement_id);
            try writer.print(",\"chunk_index\":{d},\"raw_bytes\":{d},\"chunk_sha256\":", .{
                payload.chunk_index,
                payload.raw_bytes,
            });
            try writeHexString(writer, &payload.chunk_sha256);
            try writer.writeAll(",\"base64\":\"");
            try std.base64.standard.Encoder.encodeWriter(writer, payload.bytes);
            try writer.writeAll("\"}");
        },
        .state_replacement_committed => |payload| {
            try writer.writeAll("{\"replacement_id\":");
            try writeHexString(writer, &payload.replacement_id);
            try writer.print(",\"encoded_bytes\":{d},\"sha256\":", .{payload.encoded_bytes});
            try writeHexString(writer, &payload.sha256);
            try writer.print(",\"chunk_count\":{d}}}", .{payload.chunk_count});
        },
    }
}

fn parsePayload(alloc: Allocator, kind: Kind, value: std.json.Value) !Event {
    return switch (kind) {
        .session_started => blk: {
            const source = try requireObject(value);
            if (source.count() < 6 or source.count() > 8) {
                return error.InvalidEventFrame;
            }
            try rejectUnknownKeys(source, &.{
                "id",
                "created_at_ms",
                "origin_workspace_root",
                "workspace_root",
                "conversation_language",
                "preferences",
                "usage",
                "subagent_child",
            });
            const object = source;
            const id = try dupeString(alloc, object, "id");
            errdefer alloc.free(id);
            const origin = try dupeString(alloc, object, "origin_workspace_root");
            errdefer alloc.free(origin);
            const current = try dupeString(alloc, object, "workspace_root");
            errdefer alloc.free(current);
            const preferences = try parsePreferences(
                alloc,
                object.get("preferences") orelse return error.InvalidEventFrame,
            );
            errdefer {
                var owned = preferences;
                owned.deinit(alloc);
            }
            var usage = if (object.get("usage")) |usage_value|
                session_usage.parseSnapshotValue(alloc, usage_value) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidEventFrame,
                }
            else
                null;
            errdefer if (usage) |*snapshot| snapshot.deinit(alloc);
            const subagent_child = if (object.get("subagent_child")) |raw|
                if (raw == .bool and raw.bool)
                    true
                else
                    return error.InvalidEventFrame
            else
                false;
            break :blk .{ .session_started = .{
                .id = id,
                .created_at_ms = try requireI64(object, "created_at_ms"),
                .origin_workspace_root = origin,
                .workspace_root = current,
                .conversation_language = parseLanguage(
                    try requireString(object, "conversation_language"),
                ) catch return error.InvalidEventFrame,
                .preferences = preferences,
                .usage = usage,
                .subagent_child = subagent_child,
            } };
        },
        .preferences_changed => blk: {
            const object = try requireObject(value);
            if (object.count() == 0 or object.count() > 4) return error.InvalidEventFrame;
            try rejectUnknownKeys(object, &.{ "provider", "model", "effort", "fast_mode" });
            const provider = if (object.get("provider")) |provider_value| provider_blk: {
                if (provider_value != .string) return error.InvalidEventFrame;
                break :provider_blk model_provider.parse(provider_value.string) orelse return error.InvalidEventFrame;
            } else null;
            const model = if (object.get("model")) |_| try dupeString(alloc, object, "model") else null;
            errdefer if (model) |owned| alloc.free(owned);
            const effort = if (object.get("effort")) |_|
                types.ReasoningEffort.parse(try requireString(object, "effort")) orelse
                    return error.InvalidEventFrame
            else
                null;
            const fast_mode = if (object.get("fast_mode")) |_| try requireBool(object, "fast_mode") else null;
            break :blk .{ .preferences_changed = .{
                .provider = provider,
                .model = model,
                .effort = effort,
                .fast_mode = fast_mode,
            } };
        },
        .workspace_rebound => blk: {
            const object = try exactObject(value, &.{ "previous_workspace_root", "workspace_root" });
            const previous = try dupeString(alloc, object, "previous_workspace_root");
            errdefer alloc.free(previous);
            break :blk .{ .workspace_rebound = .{
                .previous_workspace_root = previous,
                .workspace_root = try dupeString(alloc, object, "workspace_root"),
            } };
        },
        .history_turn_committed => blk: {
            const source = try requireObject(value);
            const object = if (source.count() == 4)
                try exactObject(value, &.{
                    "conversation_language",
                    "total_input_tokens",
                    "total_output_tokens",
                    "turn",
                })
            else
                try exactObject(value, &.{
                    "conversation_language",
                    "total_input_tokens",
                    "total_output_tokens",
                    "turn",
                    "work_id",
                });
            const turn = try session_codec.parseHistoryTurn(
                alloc,
                object.get("turn") orelse return error.InvalidEventFrame,
            );
            errdefer session.freeHistoryTurn(alloc, turn);
            const work_id = if (object.get("work_id")) |_| try dupeString(alloc, object, "work_id") else null;
            errdefer if (work_id) |id| alloc.free(id);
            break :blk .{ .history_turn_committed = .{
                .conversation_language = parseLanguage(
                    try requireString(object, "conversation_language"),
                ) catch return error.InvalidEventFrame,
                .total_input_tokens = try requireU64(object, "total_input_tokens"),
                .total_output_tokens = try requireU64(object, "total_output_tokens"),
                .work_id = work_id,
                .turn = turn,
            } };
        },
        .usage_checkpointed => blk: {
            const object = try exactObject(value, &.{"usage"});
            var usage = session_usage.parseSnapshotValue(
                alloc,
                object.get("usage") orelse return error.InvalidEventFrame,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidEventFrame,
            };
            errdefer usage.deinit(alloc);
            break :blk .{ .usage_checkpointed = .{ .usage = usage } };
        },
        .recovery_checkpoint_set => blk: {
            const object = try exactObject(value, &.{"checkpoint"});
            const checkpoint = session_codec.parseRecoveryCheckpoint(
                alloc,
                object.get("checkpoint") orelse return error.InvalidEventFrame,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidEventFrame,
            };
            break :blk .{ .recovery_checkpoint_set = .{ .checkpoint = checkpoint } };
        },
        .recovery_checkpoint_cleared => blk: {
            _ = try exactObject(value, &.{});
            break :blk .{ .recovery_checkpoint_cleared = .{} };
        },
        .state_replacement_started => blk: {
            const object = try exactObject(value, &.{
                "replacement_id",
                "reason",
                "encoded_bytes",
                "sha256",
                "chunk_count",
            });
            break :blk .{ .state_replacement_started = .{
                .replacement_id = try parseIdentifier(try requireString(object, "replacement_id")),
                .reason = std.meta.stringToEnum(
                    ReplacementReason,
                    try requireString(object, "reason"),
                ) orelse return error.InvalidEventFrame,
                .encoded_bytes = try requireU64(object, "encoded_bytes"),
                .sha256 = try parseDigest(try requireString(object, "sha256")),
                .chunk_count = try requireU64(object, "chunk_count"),
            } };
        },
        .state_replacement_chunk => blk: {
            const object = try exactObject(value, &.{
                "replacement_id",
                "chunk_index",
                "raw_bytes",
                "chunk_sha256",
                "base64",
            });
            const encoded = try requireString(object, "base64");
            const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch
                return error.InvalidEventFrame;
            const bytes = try alloc.alloc(u8, decoded_len);
            errdefer alloc.free(bytes);
            std.base64.standard.Decoder.decode(bytes, encoded) catch return error.InvalidEventFrame;
            const canonical = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
            defer alloc.free(canonical);
            const rendered = std.base64.standard.Encoder.encode(canonical, bytes);
            if (!std.mem.eql(u8, rendered, encoded)) return error.InvalidEventFrame;
            break :blk .{ .state_replacement_chunk = .{
                .replacement_id = try parseIdentifier(try requireString(object, "replacement_id")),
                .chunk_index = try requireU64(object, "chunk_index"),
                .raw_bytes = try requireU64(object, "raw_bytes"),
                .chunk_sha256 = try parseDigest(try requireString(object, "chunk_sha256")),
                .bytes = bytes,
            } };
        },
        .state_replacement_committed => blk: {
            const object = try exactObject(value, &.{
                "replacement_id",
                "encoded_bytes",
                "sha256",
                "chunk_count",
            });
            break :blk .{ .state_replacement_committed = .{
                .replacement_id = try parseIdentifier(try requireString(object, "replacement_id")),
                .encoded_bytes = try requireU64(object, "encoded_bytes"),
                .sha256 = try parseDigest(try requireString(object, "sha256")),
                .chunk_count = try requireU64(object, "chunk_count"),
            } };
        },
    };
}

fn readFrameLine(alloc: Allocator, source: *std.Io.Reader) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    _ = source.streamDelimiterLimit(
        &out.writer,
        '\n',
        .limited(event_frame_max_bytes),
    ) catch |err| switch (err) {
        error.StreamTooLong => return error.EventFrameTooLarge,
        error.ReadFailed => return error.ReadFailed,
        error.WriteFailed => return error.OutOfMemory,
    };
    const next = source.takeByte() catch |err| switch (err) {
        error.EndOfStream => {
            if (out.written().len == 0) return error.EndOfStream;
            return error.TruncatedEventFrame;
        },
        else => return err,
    };
    if (next != '\n') return error.InvalidEventFrame;
    try out.writer.writeByte('\n');
    return try out.toOwnedSlice();
}

fn parsePreferences(alloc: Allocator, value: std.json.Value) !session_codec.DurableSessionPreferences {
    return session_codec.parse_preferences(alloc, value) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidEventFrame,
    };
}

fn writePreferences(
    writer: *std.Io.Writer,
    preferences: session_codec.DurableSessionPreferences,
) !void {
    try writer.writeAll("{\"model\":");
    try writeJsonString(writer, preferences.model);
    try writer.writeAll(",\"effort\":");
    try writeJsonString(writer, preferences.effort.label());
    try writer.print(",\"fast_mode\":{s},\"provider\":", .{
        if (preferences.fast_mode) "true" else "false",
    });
    try writeJsonString(writer, @tagName(preferences.provider));
    try writer.writeByte('}');
}

fn exactObject(value: std.json.Value, keys: []const []const u8) !std.json.ObjectMap {
    const object = try requireObject(value);
    if (object.count() != keys.len) return error.InvalidEventFrame;
    try rejectUnknownKeys(object, keys);
    return object;
}

fn rejectUnknownKeys(object: std.json.ObjectMap, keys: []const []const u8) !void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        var known = false;
        for (keys) |key| {
            if (std.mem.eql(u8, entry.key_ptr.*, key)) {
                known = true;
                break;
            }
        }
        if (!known) return error.InvalidEventFrame;
    }
}

fn requireObject(value: std.json.Value) !std.json.ObjectMap {
    if (value != .object) return error.InvalidEventFrame;
    return value.object;
}

fn requireString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidEventFrame;
    if (value != .string) return error.InvalidEventFrame;
    return value.string;
}

fn dupeString(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    return try alloc.dupe(u8, try requireString(object, key));
}

fn requireBool(object: std.json.ObjectMap, key: []const u8) !bool {
    const value = object.get(key) orelse return error.InvalidEventFrame;
    if (value != .bool) return error.InvalidEventFrame;
    return value.bool;
}

fn requireI64(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return error.InvalidEventFrame;
    return switch (value) {
        .integer => |number| number,
        .number_string => |raw| std.fmt.parseInt(i64, raw, 10) catch
            error.InvalidEventFrame,
        else => error.InvalidEventFrame,
    };
}

fn requireU64(object: std.json.ObjectMap, key: []const u8) !u64 {
    const value = object.get(key) orelse return error.InvalidEventFrame;
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else error.InvalidEventFrame,
        .number_string => |raw| std.fmt.parseUnsigned(u64, raw, 10) catch
            error.InvalidEventFrame,
        else => error.InvalidEventFrame,
    };
}

fn parseLanguage(raw: []const u8) !session.ConversationLanguage {
    return session_codec.parseConversationLanguage(raw);
}

fn parseIdentifier(hex: []const u8) !Identifier {
    return parseHex(Identifier, hex);
}

fn parseDigest(hex: []const u8) !Digest {
    return parseHex(Digest, hex);
}

fn parseHex(comptime T: type, hex: []const u8) !T {
    if (hex.len != @sizeOf(T) * 2) return error.InvalidEventFrame;
    var value: T = undefined;
    _ = std.fmt.hexToBytes(&value, hex) catch return error.InvalidEventFrame;
    const canonical = std.fmt.bytesToHex(value, .lower);
    if (!std.mem.eql(u8, &canonical, hex)) return error.InvalidEventFrame;
    return value;
}

fn writeHexString(writer: *std.Io.Writer, bytes: []const u8) !void {
    try writer.writeByte('"');
    const alphabet = "0123456789abcdef";
    for (bytes) |byte| {
        try writer.writeByte(alphabet[byte >> 4]);
        try writer.writeByte(alphabet[byte & 0x0f]);
    }
    try writer.writeByte('"');
}

fn writeJsonString(writer: *std.Io.Writer, bytes: []const u8) !void {
    try std.json.Stringify.value(bytes, .{}, writer);
}

fn sha256(bytes: []const u8) Digest {
    var hash: Digest = undefined;
    Sha256.hash(bytes, &hash, .{});
    return hash;
}

test "session event kind contract contains exactly ten stable variants" {
    try std.testing.expectEqual(@as(usize, 10), @typeInfo(Kind).@"enum".fields.len);
    try std.testing.expectEqualStrings("session_started", @tagName(Kind.session_started));
    try std.testing.expectEqualStrings("preferences_changed", @tagName(Kind.preferences_changed));
    try std.testing.expectEqualStrings("workspace_rebound", @tagName(Kind.workspace_rebound));
    try std.testing.expectEqualStrings("history_turn_committed", @tagName(Kind.history_turn_committed));
    try std.testing.expectEqualStrings("usage_checkpointed", @tagName(Kind.usage_checkpointed));
    try std.testing.expectEqualStrings("state_replacement_started", @tagName(Kind.state_replacement_started));
    try std.testing.expectEqualStrings("state_replacement_chunk", @tagName(Kind.state_replacement_chunk));
    try std.testing.expectEqualStrings("state_replacement_committed", @tagName(Kind.state_replacement_committed));
}

test "event frame codec is deterministic and validates contiguous sequence and generation" {
    const alloc = std.testing.allocator;
    const generation = identifier(0x10);
    const frame = Envelope{
        .log_generation = generation,
        .seq = 1,
        .event_id = identifier(0x20),
        .timestamp_ms = 50,
        .event = .{ .session_started = .{
            .id = @constCast("session-1"),
            .created_at_ms = 10,
            .origin_workspace_root = @constCast("/tmp/origin"),
            .workspace_root = @constCast("/tmp/current"),
            .conversation_language = session.ConversationLanguage.literal("en"),
            .preferences = .{
                .model = @constCast("openai/gpt-test"),
                .effort = types.ReasoningEffort.literal("medium"),
                .fast_mode = false,
            },
            .subagent_child = true,
        } },
    };

    const first = try encodeLegacyFixtureFrame(alloc, frame);
    defer alloc.free(first);
    const second = try encodeLegacyFixtureFrame(alloc, frame);
    defer alloc.free(second);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(first[first.len - 1] == '\n');

    var decoded = try decodeFrame(alloc, first);
    defer decoded.deinit(alloc);
    try std.testing.expectEqual(Kind.session_started, decoded.kind());
    try std.testing.expect(decoded.event.session_started.subagent_child);
    try std.testing.expectEqualSlices(u8, &generation, &decoded.log_generation);
    try std.testing.expectEqual(@as(u64, 1), decoded.seq);

    var validator: SequenceValidator = .{};
    try validator.validate(decoded);

    var gap = decoded;
    gap.seq = 3;
    try std.testing.expectError(error.NonContiguousSequence, validator.validate(gap));

    var wrong_generation = decoded;
    wrong_generation.seq = 2;
    wrong_generation.log_generation = identifier(0x30);
    try std.testing.expectError(error.GenerationChanged, validator.validate(wrong_generation));
}

test "history_turn_committed event decode repairs duplicate-key tool arguments" {
    const duplicate_arguments = "{\"depth\":1,\"depth\":2}";
    var calls = [_]session.ToolCall{.{
        .id = "call_bad",
        .name = "read_file",
        .arguments_json = duplicate_arguments,
    }};
    var results = [_]session.PersistedToolResult{.{
        .tool_call_id = @constCast("call_bad"),
        .tool_name = @constCast("read_file"),
        .status = .success,
        .output = @constCast("stale success"),
        .output_bytes = 13,
        .stored_output_bytes = 13,
        .truncated = false,
        .provider_native = false,
        .created_at_ms = 1,
    }};
    var steps = [_]session.ToolExecutionStep{.{
        .tool_calls = calls[0..],
        .tool_results = results[0..],
    }};
    const frame = Envelope{
        .log_generation = identifier(0x10),
        .seq = 1,
        .event_id = identifier(0x20),
        .timestamp_ms = 50,
        .event = .{ .history_turn_committed = .{
            .conversation_language = session.ConversationLanguage.literal("en"),
            .total_input_tokens = 1,
            .total_output_tokens = 2,
            .turn = .{ .assistant = .{
                .user = .{ .text = @constCast("inspect") },
                .assistant = @constCast("failed"),
                .execution = .{ .tool_steps = steps[0..] },
            } },
        } },
    };

    const encoded = try encodeLegacyFixtureFrame(std.testing.allocator, frame);
    defer std.testing.allocator.free(encoded);
    var decoded = try decodeFrame(std.testing.allocator, encoded);
    defer decoded.deinit(std.testing.allocator);

    const step = decoded.event.history_turn_committed.turn.assistant.execution.tool_steps[0];
    try std.testing.expectEqualStrings("{}", step.tool_calls[0].arguments_json);
    try std.testing.expectEqual(types.ToolArgumentIntegrity.valid, step.tool_calls[0].argument_integrity);
    try std.testing.expectEqual(session.PersistedToolStatus.failure, step.tool_results[0].status);
    try std.testing.expect(std.mem.find(u8, step.tool_results[0].output, "tool_execution_failed") != null);
    try std.testing.expect(std.mem.find(u8, step.tool_results[0].output, duplicate_arguments) == null);
}

test "event frame cap is inclusive of the required newline" {
    const alloc = std.testing.allocator;
    const frame = Envelope{
        .log_generation = identifier(0x10),
        .seq = 1,
        .event_id = identifier(0x20),
        .timestamp_ms = 1,
        .event = .{ .preferences_changed = .{ .fast_mode = true } },
    };
    const encoded = try encodeLegacyFixtureFrame(alloc, frame);
    defer alloc.free(encoded);

    const exact = try alloc.alloc(u8, event_frame_max_bytes);
    defer alloc.free(exact);
    @memcpy(exact[0 .. encoded.len - 1], encoded[0 .. encoded.len - 1]);
    @memset(exact[encoded.len - 1 .. exact.len - 1], ' ');
    exact[exact.len - 1] = '\n';
    var decoded = try decodeFrame(alloc, exact);
    decoded.deinit(alloc);

    const oversized = try alloc.alloc(u8, event_frame_max_bytes + 1);
    defer alloc.free(oversized);
    @memcpy(oversized[0..exact.len], exact);
    oversized[oversized.len - 2] = ' ';
    oversized[oversized.len - 1] = '\n';
    try std.testing.expectError(error.EventFrameTooLarge, decodeFrame(alloc, oversized));
}

test "semantic reducer uses event timestamps and enforces immutable identity" {
    const alloc = std.testing.allocator;
    const generation = identifier(0x41);
    const frames = [_]Envelope{
        .{
            .log_generation = generation,
            .seq = 1,
            .event_id = identifier(0x51),
            .timestamp_ms = 100,
            .event = .{ .session_started = .{
                .id = @constCast("session-1"),
                .created_at_ms = 10,
                .origin_workspace_root = @constCast("/tmp/origin"),
                .workspace_root = @constCast("/tmp/a"),
                .conversation_language = session.ConversationLanguage.literal("en"),
                .preferences = .{
                    .model = @constCast("model-a"),
                    .effort = .auto,
                    .fast_mode = false,
                },
            } },
        },
        .{
            .log_generation = generation,
            .seq = 2,
            .event_id = identifier(0x52),
            .timestamp_ms = 90,
            .event = .{ .preferences_changed = .{ .fast_mode = true } },
        },
        .{
            .log_generation = generation,
            .seq = 3,
            .event_id = identifier(0x53),
            .timestamp_ms = 80,
            .event = .{ .workspace_rebound = .{
                .previous_workspace_root = @constCast("/tmp/a"),
                .workspace_root = @constCast("/tmp/b"),
            } },
        },
    };

    var jsonl: std.Io.Writer.Allocating = .init(alloc);
    defer jsonl.deinit();
    for (frames) |frame| {
        const line = try encodeLegacyFixtureFrame(alloc, frame);
        defer alloc.free(line);
        try jsonl.writer.writeAll(line);
    }

    var source = std.Io.Reader.fixed(jsonl.written());
    var reduced = try reduceJsonl(alloc, &source, null);
    defer reduced.deinit(alloc);
    try std.testing.expectEqual(@as(i64, 80), reduced.state.updated_at_ms);
    try std.testing.expectEqualStrings("/tmp/origin", reduced.state.origin_workspace_root);
    try std.testing.expectEqualStrings("/tmp/b", reduced.state.workspace_root);
    try std.testing.expect(reduced.state.preferences.fast_mode);

    var bad = frames[2];
    bad.event.workspace_rebound.previous_workspace_root = @constCast("/tmp/not-current");
    const bad_line = try encodeLegacyFixtureFrame(alloc, bad);
    defer alloc.free(bad_line);
    var bad_log: std.Io.Writer.Allocating = .init(alloc);
    defer bad_log.deinit();
    for (frames[0..2]) |frame| {
        const line = try encodeLegacyFixtureFrame(alloc, frame);
        defer alloc.free(line);
        try bad_log.writer.writeAll(line);
    }
    try bad_log.writer.writeAll(bad_line);
    var bad_source = std.Io.Reader.fixed(bad_log.written());
    try std.testing.expectError(error.ImmutableSessionIdentity, reduceJsonl(alloc, &bad_source, null));
}

test "semantic reducer resumes a contiguous suffix from owned state" {
    const alloc = std.testing.allocator;
    const generation = identifier(0x81);
    const initial = session_codec.DurableSessionState{
        .id = @constCast("session-tail"),
        .origin_workspace_root = @constCast("/tmp/origin"),
        .workspace_root = @constCast("/tmp/current"),
        .created_at_ms = 10,
        .updated_at_ms = 20,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .preferences = .{
            .model = @constCast("model-a"),
            .effort = .auto,
            .fast_mode = false,
        },
        .history = @constCast(&.{}),
        .total_input_tokens = 1,
        .total_output_tokens = 2,
    };
    const envelope = Envelope{
        .log_generation = generation,
        .seq = 5,
        .event_id = identifier(0x82),
        .timestamp_ms = 30,
        .event = .{ .preferences_changed = .{ .fast_mode = true } },
    };
    const line = try encodeLegacyFixtureFrame(alloc, envelope);
    defer alloc.free(line);

    var source = std.Io.Reader.fixed(line);
    var reduced = try reduceJsonlFrom(
        alloc,
        &source,
        try initial.dupe(alloc),
        .{ .generation = generation, .next_seq = 5 },
    );
    defer reduced.deinit(alloc);
    try std.testing.expect(reduced.truncate_from == null);
    try std.testing.expect(reduced.state.preferences.fast_mode);
    try std.testing.expectEqual(@as(i64, 30), reduced.state.updated_at_ms);
    try std.testing.expectEqual(@as(u64, line.len), reduced.bytes_consumed);
    const through = reduced.through orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u64, 5), through.seq);
    try std.testing.expectEqualSlices(u8, &envelope.event_id, &through.event_id);
    try std.testing.expectEqual(@as(u64, line.len), through.byte_offset);

    var wrong_source = std.Io.Reader.fixed(line);
    try std.testing.expectError(
        error.NonContiguousSequence,
        reduceJsonlFrom(
            alloc,
            &wrong_source,
            try initial.dupe(alloc),
            .{ .generation = generation, .next_seq = 4 },
        ),
    );
}

test "single event application updates caller-owned state without replaying its prefix" {
    const alloc = std.testing.allocator;
    const generation = identifier(0x91);
    const initial = singleEventTestState("session-single-event");
    var state = try initial.dupe(alloc);
    defer state.deinit(alloc);

    var calls = [_]session.ToolCall{.{
        .id = @constCast("call-1"),
        .name = @constCast("read_file"),
        .arguments_json = @constCast("{\"path\":\"README.md\"}"),
    }};
    var results = [_]session.PersistedToolResult{.{
        .tool_call_id = @constCast("call-1"),
        .tool_name = @constCast("read_file"),
        .status = .success,
        .output = @constCast("fixture output"),
        .output_bytes = 14,
        .stored_output_bytes = 14,
        .truncated = false,
        .provider_native = false,
        .created_at_ms = 21,
    }};
    var steps = [_]session.ToolExecutionStep{.{
        .tool_calls = calls[0..],
        .tool_results = results[0..],
    }};
    const history = Envelope{
        .log_generation = generation,
        .seq = 5,
        .event_id = identifier(0x92),
        .timestamp_ms = 30,
        .event = .{ .history_turn_committed = .{
            .conversation_language = session.ConversationLanguage.literal("fr"),
            .total_input_tokens = 100,
            .total_output_tokens = 50,
            .turn = .{ .assistant = .{
                .user = .{ .text = @constCast("inspect") },
                .assistant = @constCast("done"),
                .execution = .{ .tool_steps = steps[0..] },
            } },
        } },
    };
    const line = try encodeLegacyFixtureFrame(alloc, history);
    defer alloc.free(line);
    const boundary = try applyEventFrame(
        alloc,
        &state,
        line,
        .{ .generation = generation, .next_seq = 5 },
        history.event_id,
    );

    try std.testing.expectEqual(@as(u64, 5), boundary.seq);
    try std.testing.expectEqualSlices(u8, &history.event_id, &boundary.event_id);
    try std.testing.expectEqual(@as(u64, line.len), boundary.byte_offset);
    try std.testing.expectEqual(@as(usize, 1), state.history.len);
    try std.testing.expectEqualStrings(
        "fixture output",
        state.history[0].assistant.execution.tool_steps[0].tool_results[0].output,
    );
    try std.testing.expectEqualStrings("fr", state.conversation_language.view());
    try std.testing.expectEqual(@as(u64, 100), state.total_input_tokens);
    try std.testing.expectEqual(@as(u64, 50), state.total_output_tokens);
    try std.testing.expectEqual(@as(i64, 30), state.updated_at_ms);
}

test "compacted summary event advances the durable replacement boundary" {
    const alloc = std.testing.allocator;
    var state: ?session_codec.DurableSessionState = try singleEventTestState(
        "session-compaction-checkpoint",
    ).dupe(alloc);
    defer if (state) |*current| current.deinit(alloc);

    const generation = identifier(0xb0);
    try applyDelta(alloc, &state, .{
        .log_generation = generation,
        .seq = 1,
        .event_id = identifier(0xb1),
        .timestamp_ms = 30,
        .event = .{ .history_turn_committed = .{
            .conversation_language = session.ConversationLanguage.literal("en"),
            .total_input_tokens = 10,
            .total_output_tokens = 5,
            .turn = .{ .assistant = .{
                .user = .{ .text = @constCast("exact prompt") },
                .assistant = @constCast("exact reply"),
            } },
        } },
    });
    try applyDelta(alloc, &state, .{
        .log_generation = generation,
        .seq = 2,
        .event_id = identifier(0xb2),
        .timestamp_ms = 40,
        .event = .{ .history_turn_committed = .{
            .conversation_language = session.ConversationLanguage.literal("en"),
            .total_input_tokens = 20,
            .total_output_tokens = 10,
            .turn = .{ .compacted_summary = .{
                .summary = @constCast("<context_handoff>\nsummary\n</context_handoff>"),
                .removed_turn_count = 1,
                .compaction_count = 1,
            } },
        } },
    });

    try std.testing.expectEqual(@as(usize, 2), state.?.history.len);
    try std.testing.expectEqual(@as(usize, 1), state.?.context_history_start);
    try std.testing.expectEqualStrings("exact prompt", state.?.history[0].assistant.user.text);
}

test "single event application preserves caller-owned state on allocation failure" {
    const alloc = std.testing.allocator;
    const generation = identifier(0xa1);
    const event = Envelope{
        .log_generation = generation,
        .seq = 7,
        .event_id = identifier(0xa2),
        .timestamp_ms = 30,
        .event = .{ .history_turn_committed = .{
            .conversation_language = session.ConversationLanguage.literal("fr"),
            .total_input_tokens = 10,
            .total_output_tokens = 5,
            .turn = .{ .assistant = .{
                .user = .{ .text = @constCast("new prompt") },
                .assistant = @constCast("new response"),
            } },
        } },
    };
    const line = try encodeLegacyFixtureFrame(alloc, event);
    defer alloc.free(line);

    const AllocationCheck = struct {
        fn run(
            failing_alloc: Allocator,
            frame: []const u8,
            expected_generation: Identifier,
        ) !void {
            const initial = singleEventTestState("session-single-event-oom");
            var state = try initial.dupe(failing_alloc);
            defer state.deinit(failing_alloc);

            const boundary = applyEventFrame(
                failing_alloc,
                &state,
                frame,
                .{ .generation = expected_generation, .next_seq = 7 },
                identifier(0xa2),
            ) catch |err| {
                try std.testing.expectEqualStrings("model-a", state.preferences.model);
                try std.testing.expectEqualStrings("/tmp/current", state.workspace_root);
                try std.testing.expectEqual(@as(usize, 0), state.history.len);
                try std.testing.expectEqual(@as(i64, 20), state.updated_at_ms);
                return err;
            };
            try std.testing.expectEqual(@as(u64, 7), boundary.seq);
            try std.testing.expectEqual(@as(usize, 1), state.history.len);
            try std.testing.expectEqualStrings(
                "new response",
                state.history[0].assistant.assistant,
            );
        }
    };
    try std.testing.checkAllAllocationFailures(
        alloc,
        AllocationCheck.run,
        .{ line, generation },
    );
}

test "single event application validates boundaries for every semantic event kind" {
    const alloc = std.testing.allocator;
    const generation = identifier(0xb1);
    const initial = singleEventTestState("session-single-event-kinds");
    var state = try initial.dupe(alloc);
    defer state.deinit(alloc);
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    try usage.recordCommittedLines(7, 3);
    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);

    const events = [_]Envelope{
        .{
            .log_generation = generation,
            .seq = 5,
            .event_id = identifier(0xb2),
            .timestamp_ms = 21,
            .event = .{ .preferences_changed = .{
                .model = @constCast("model-b"),
                .effort = types.ReasoningEffort.literal("high"),
                .fast_mode = true,
            } },
        },
        .{
            .log_generation = generation,
            .seq = 6,
            .event_id = identifier(0xb3),
            .timestamp_ms = 22,
            .event = .{ .workspace_rebound = .{
                .previous_workspace_root = @constCast("/tmp/current"),
                .workspace_root = @constCast("/tmp/next"),
            } },
        },
        .{
            .log_generation = generation,
            .seq = 7,
            .event_id = identifier(0xb4),
            .timestamp_ms = 23,
            .event = .{ .usage_checkpointed = .{ .usage = snapshot } },
        },
    };

    for (events, 0..) |event, index| {
        const line = try encodeLegacyFixtureFrame(alloc, event);
        defer alloc.free(line);
        if (index == 0) {
            try std.testing.expectError(
                error.InvalidEventFrame,
                applyEventFrame(
                    alloc,
                    &state,
                    line,
                    .{ .generation = generation, .next_seq = event.seq },
                    identifier(0xff),
                ),
            );
            try std.testing.expectEqualStrings("model-a", state.preferences.model);
        }
        if (index == 1) {
            try std.testing.expectError(
                error.NonContiguousSequence,
                applyEventFrame(
                    alloc,
                    &state,
                    line,
                    .{ .generation = generation, .next_seq = event.seq - 1 },
                    event.event_id,
                ),
            );
            try std.testing.expectEqualStrings("/tmp/current", state.workspace_root);
        }
        _ = try applyEventFrame(
            alloc,
            &state,
            line,
            .{ .generation = generation, .next_seq = event.seq },
            event.event_id,
        );
    }

    try std.testing.expectEqualStrings("model-b", state.preferences.model);
    try std.testing.expectEqual(types.ReasoningEffort.literal("high"), state.preferences.effort);
    try std.testing.expect(state.preferences.fast_mode);
    try std.testing.expectEqualStrings("/tmp/next", state.workspace_root);
    try std.testing.expectEqual(@as(u64, 7), state.usage.?.lines_added);
    try std.testing.expectEqual(@as(u64, 3), state.usage.?.lines_removed);
}

fn singleEventTestState(id: []const u8) session_codec.DurableSessionState {
    return .{
        .id = @constCast(id),
        .origin_workspace_root = @constCast("/tmp/origin"),
        .workspace_root = @constCast("/tmp/current"),
        .created_at_ms = 10,
        .updated_at_ms = 20,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .preferences = .{
            .model = @constCast("model-a"),
            .effort = .auto,
            .fast_mode = false,
        },
        .history = @constCast(&.{}),
        .total_input_tokens = 1,
        .total_output_tokens = 2,
    };
}

test "semantic reducer releases owned state when the reduction start is invalid" {
    const alloc = std.testing.allocator;
    const initial = session_codec.DurableSessionState{
        .id = @constCast("session-invalid-start"),
        .origin_workspace_root = @constCast("/tmp/origin"),
        .workspace_root = @constCast("/tmp/current"),
        .created_at_ms = 10,
        .updated_at_ms = 20,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .preferences = .{
            .model = @constCast("model-a"),
            .effort = types.ReasoningEffort.literal("low"),
            .fast_mode = false,
        },
        .history = @constCast(&.{}),
        .total_input_tokens = 1,
        .total_output_tokens = 2,
    };
    var source = std.Io.Reader.fixed("");
    try std.testing.expectError(
        error.InvalidReductionStart,
        reduceJsonlFrom(
            alloc,
            &source,
            try initial.dupe(alloc),
            .{ .next_seq = 0 },
        ),
    );
}

test "history_turn_committed leaves absent session usage unchanged" {
    const alloc = std.testing.allocator;
    const generation = identifier(0x60);

    const started = Envelope{
        .log_generation = generation,
        .seq = 1,
        .event_id = identifier(0x61),
        .timestamp_ms = 100,
        .event = .{ .session_started = .{
            .id = @constCast("session-1"),
            .created_at_ms = 10,
            .origin_workspace_root = @constCast("/tmp/origin"),
            .workspace_root = @constCast("/tmp/current"),
            .conversation_language = session.ConversationLanguage.literal("en"),
            .preferences = .{
                .model = @constCast("openai/gpt-test"),
                .effort = types.ReasoningEffort.literal("medium"),
                .fast_mode = false,
            },
        } },
    };
    const committed = Envelope{
        .log_generation = generation,
        .seq = 2,
        .event_id = identifier(0x62),
        .timestamp_ms = 110,
        .event = .{ .history_turn_committed = .{
            .conversation_language = session.ConversationLanguage.literal("fr"),
            .total_input_tokens = 128,
            .total_output_tokens = 64,
            .work_id = @constCast("work-17"),
            .turn = .{ .assistant = .{
                .user = .{ .text = @constCast("hello") },
                .assistant = @constCast("world"),
            } },
        } },
    };

    const committed_line = try encodeLegacyFixtureFrame(alloc, committed);
    defer alloc.free(committed_line);

    var decoded = try decodeFrame(alloc, committed_line);
    defer decoded.deinit(alloc);
    try std.testing.expectEqual(
        @as(u64, 128),
        decoded.event.history_turn_committed.total_input_tokens,
    );
    try std.testing.expectEqual(
        @as(u64, 64),
        decoded.event.history_turn_committed.total_output_tokens,
    );
    try std.testing.expectEqualStrings(
        "world",
        decoded.event.history_turn_committed.turn.assistant.assistant,
    );
    try std.testing.expectEqualStrings(
        "work-17",
        decoded.event.history_turn_committed.work_id.?,
    );

    var jsonl: std.Io.Writer.Allocating = .init(alloc);
    defer jsonl.deinit();
    const started_line = try encodeLegacyFixtureFrame(alloc, started);
    defer alloc.free(started_line);
    try jsonl.writer.writeAll(started_line);
    try jsonl.writer.writeAll(committed_line);

    var source = std.Io.Reader.fixed(jsonl.written());
    var reduced = try reduceJsonl(alloc, &source, null);
    defer reduced.deinit(alloc);
    try std.testing.expect(reduced.state.usage == null);
    try std.testing.expectEqual(@as(u64, 128), reduced.state.total_input_tokens);
    try std.testing.expectEqual(@as(u64, 64), reduced.state.total_output_tokens);
    try std.testing.expectEqual(@as(usize, 1), reduced.state.history.len);
    try std.testing.expectEqualStrings("work-17", reduced.state.last_subagent_work_id.?);
    try std.testing.expectEqualStrings(
        "work-17",
        reduced.state.history[0].assistant.user.work_id.?,
    );
    try std.testing.expectEqualStrings(
        "world",
        reduced.state.history[0].assistant.assistant,
    );
}

test "replay associates each committed work ID with its exact user turn" {
    const alloc = std.testing.allocator;
    const generation = identifier(0x80);
    var state: ?session_codec.DurableSessionState = null;
    defer if (state) |*current| current.deinit(alloc);
    try applyDelta(alloc, &state, .{
        .log_generation = generation,
        .seq = 1,
        .event_id = identifier(0x81),
        .timestamp_ms = 1,
        .event = .{ .session_started = .{
            .id = @constCast("provenance-replay"),
            .created_at_ms = 1,
            .origin_workspace_root = @constCast("/tmp/origin"),
            .workspace_root = @constCast("/tmp/current"),
            .conversation_language = session.ConversationLanguage.literal("en"),
            .preferences = .{
                .model = @constCast("test/model"),
                .effort = .auto,
                .fast_mode = false,
            },
        } },
    });
    try applyDelta(alloc, &state, .{
        .log_generation = generation,
        .seq = 2,
        .event_id = identifier(0x82),
        .timestamp_ms = 2,
        .event = .{ .history_turn_committed = .{
            .conversation_language = session.ConversationLanguage.literal("en"),
            .total_input_tokens = 1,
            .total_output_tokens = 1,
            .work_id = @constCast("work-first"),
            .turn = .{ .assistant = .{
                .user = .{ .text = @constCast("first") },
                .assistant = @constCast("one"),
            } },
        } },
    });
    try applyDelta(alloc, &state, .{
        .log_generation = generation,
        .seq = 3,
        .event_id = identifier(0x83),
        .timestamp_ms = 3,
        .event = .{ .history_turn_committed = .{
            .conversation_language = session.ConversationLanguage.literal("en"),
            .total_input_tokens = 2,
            .total_output_tokens = 2,
            .work_id = @constCast("work-second"),
            .turn = .{ .assistant = .{
                .user = .{
                    .text = @constCast("second"),
                    .work_id = @constCast("work-second"),
                },
                .assistant = @constCast("two"),
            } },
        } },
    });
    try applyDelta(alloc, &state, .{
        .log_generation = generation,
        .seq = 4,
        .event_id = identifier(0x84),
        .timestamp_ms = 4,
        .event = .{ .history_turn_committed = .{
            .conversation_language = session.ConversationLanguage.literal("en"),
            .total_input_tokens = 3,
            .total_output_tokens = 3,
            .turn = .{ .assistant = .{
                .user = .{ .text = @constCast("ordinary") },
                .assistant = @constCast("three"),
            } },
        } },
    });

    try std.testing.expectEqual(@as(usize, 3), state.?.history.len);
    try std.testing.expectEqualStrings(
        "work-first",
        state.?.history[0].assistant.user.work_id.?,
    );
    try std.testing.expectEqualStrings(
        "work-second",
        state.?.history[1].assistant.user.work_id.?,
    );
    try std.testing.expect(state.?.history[2].assistant.user.work_id == null);
    try std.testing.expectEqualStrings("work-second", state.?.last_subagent_work_id.?);
    try std.testing.expect(
        state.?.history[1].assistant.user.work_id.?.ptr !=
            state.?.last_subagent_work_id.?.ptr,
    );
}

test "history event provenance rejects conflicts and malformed IDs" {
    const base = Envelope{
        .log_generation = identifier(0x90),
        .seq = 1,
        .event_id = identifier(0x91),
        .timestamp_ms = 1,
        .event = .{ .history_turn_committed = .{
            .conversation_language = session.ConversationLanguage.literal("en"),
            .total_input_tokens = 1,
            .total_output_tokens = 1,
            .work_id = @constCast("event-work"),
            .turn = .{ .assistant = .{
                .user = .{
                    .text = @constCast("prompt"),
                    .work_id = @constCast("turn-work"),
                },
                .assistant = @constCast("reply"),
            } },
        } },
    };
    try std.testing.expectError(error.InvalidEventFrame, validateEnvelope(base));

    var persisted_conflict = base;
    persisted_conflict.event.history_turn_committed.work_id = @constCast("work-a");
    persisted_conflict.event.history_turn_committed.turn.assistant.user.work_id = @constCast("work-a");
    const encoded = try encodeLegacyFixtureFrame(std.testing.allocator, persisted_conflict);
    defer std.testing.allocator.free(encoded);
    const final_id = std.mem.lastIndexOf(u8, encoded, "work-a") orelse
        return error.TestExpectedEqual;
    encoded[final_id + "work-".len] = 'b';
    try std.testing.expectError(
        error.InvalidEventFrame,
        decodeFrame(std.testing.allocator, encoded),
    );

    var absent_event = base;
    absent_event.event.history_turn_committed.work_id = null;
    try std.testing.expectError(error.InvalidEventFrame, validateEnvelope(absent_event));

    var malformed = base;
    malformed.event.history_turn_committed.work_id = @constCast("bad\x00id");
    malformed.event.history_turn_committed.turn.assistant.user.work_id = null;
    try std.testing.expectError(error.InvalidEventFrame, validateEnvelope(malformed));

    var summary = base;
    summary.event.history_turn_committed.work_id = @constCast("event-work");
    summary.event.history_turn_committed.turn = .{ .compacted_summary = .{
        .summary = @constCast("summary"),
        .removed_turn_count = 1,
        .compaction_count = 1,
    } };
    try std.testing.expectError(error.InvalidEventFrame, validateEnvelope(summary));
}

fn checkHistoryProvenanceReplayAllocationFailures(alloc: Allocator) !void {
    var state: ?session_codec.DurableSessionState = null;
    defer if (state) |*current| current.deinit(alloc);
    const generation = identifier(0xa0);
    try applyDelta(alloc, &state, .{
        .log_generation = generation,
        .seq = 1,
        .event_id = identifier(0xa1),
        .timestamp_ms = 1,
        .event = .{ .session_started = .{
            .id = @constCast("allocation-provenance"),
            .created_at_ms = 1,
            .origin_workspace_root = @constCast("/tmp/origin"),
            .workspace_root = @constCast("/tmp/current"),
            .conversation_language = session.ConversationLanguage.literal("en"),
            .preferences = .{
                .model = @constCast("test/model"),
                .effort = .auto,
                .fast_mode = false,
            },
        } },
    });
    try applyDelta(alloc, &state, .{
        .log_generation = generation,
        .seq = 2,
        .event_id = identifier(0xa2),
        .timestamp_ms = 2,
        .event = .{ .history_turn_committed = .{
            .conversation_language = session.ConversationLanguage.literal("en"),
            .total_input_tokens = 1,
            .total_output_tokens = 1,
            .work_id = @constCast("allocation-work"),
            .turn = .{ .assistant = .{
                .user = .{ .text = @constCast("prompt") },
                .assistant = @constCast("reply"),
            } },
        } },
    });
    try std.testing.expectEqualStrings(
        "allocation-work",
        state.?.history[0].assistant.user.work_id.?,
    );
}

test "history provenance replay frees every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkHistoryProvenanceReplayAllocationFailures,
        .{},
    );
}

test "usage checkpoint event decodes a cumulative snapshot" {
    const alloc = std.testing.allocator;
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    try usage.recordCommittedLines(7, 3);
    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);

    var frame: std.Io.Writer.Allocating = .init(alloc);
    defer frame.deinit();
    try frame.writer.writeAll(
        "{\"schema_version\":1," ++
            "\"log_generation\":\"000102030405060708090a0b0c0d0e0f\"," ++
            "\"seq\":2," ++
            "\"event_id\":\"101112131415161718191a1b1c1d1e1f\"," ++
            "\"timestamp_ms\":200," ++
            "\"kind\":\"usage_checkpointed\"," ++
            "\"payload\":{\"usage\":",
    );
    try session_usage.writeSnapshot(&frame.writer, snapshot);
    try frame.writer.writeAll("}}\n");

    var decoded = try decodeFrame(alloc, frame.written());
    defer decoded.deinit(alloc);
    try std.testing.expectEqualStrings("usage_checkpointed", @tagName(decoded.kind()));

    const started = Envelope{
        .log_generation = identifier(0x00),
        .seq = 1,
        .event_id = identifier(0x20),
        .timestamp_ms = 100,
        .event = .{ .session_started = .{
            .id = @constCast("session-checkpoint"),
            .created_at_ms = 100,
            .origin_workspace_root = @constCast("/tmp/origin"),
            .workspace_root = @constCast("/tmp/current"),
            .conversation_language = session.ConversationLanguage.literal("en"),
            .preferences = .{
                .model = @constCast("test/model"),
                .effort = types.ReasoningEffort.literal("medium"),
                .fast_mode = false,
            },
        } },
    };
    const started_line = try encodeLegacyFixtureFrame(alloc, started);
    defer alloc.free(started_line);
    var jsonl: std.Io.Writer.Allocating = .init(alloc);
    defer jsonl.deinit();
    try jsonl.writer.writeAll(started_line);
    try jsonl.writer.writeAll(frame.written());
    var source = std.Io.Reader.fixed(jsonl.written());
    var reduced = try reduceJsonl(alloc, &source, null);
    defer reduced.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 7), reduced.state.usage.?.lines_added);
    try std.testing.expectEqual(@as(u64, 3), reduced.state.usage.?.lines_removed);
    try std.testing.expectEqual(@as(i64, 200), reduced.state.updated_at_ms);
}

test "later usage events replace snapshots while legacy turns preserve them" {
    const alloc = std.testing.allocator;
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    try usage.recordCommittedLines(1, 0);
    var started_usage = try usage.snapshot(alloc);
    defer started_usage.deinit(alloc);
    try usage.recordCommittedLines(6, 0);
    var first_checkpoint = try usage.snapshot(alloc);
    defer first_checkpoint.deinit(alloc);
    try usage.recordCommittedLines(2, 0);
    var second_checkpoint = try usage.snapshot(alloc);
    defer second_checkpoint.deinit(alloc);

    var state: ?session_codec.DurableSessionState = null;
    defer if (state) |*current| current.deinit(alloc);
    const generation = identifier(0x70);
    try applyDelta(alloc, &state, .{
        .log_generation = generation,
        .seq = 1,
        .event_id = identifier(0x71),
        .timestamp_ms = 100,
        .event = .{ .session_started = .{
            .id = @constCast("session-usage-order"),
            .created_at_ms = 100,
            .origin_workspace_root = @constCast("/tmp/origin"),
            .workspace_root = @constCast("/tmp/current"),
            .conversation_language = session.ConversationLanguage.literal("en"),
            .preferences = .{
                .model = @constCast("test/model"),
                .effort = types.ReasoningEffort.literal("medium"),
                .fast_mode = false,
            },
            .usage = started_usage,
        } },
    });
    try std.testing.expectEqual(@as(u64, 1), state.?.usage.?.lines_added);

    try applyDelta(alloc, &state, .{
        .log_generation = generation,
        .seq = 2,
        .event_id = identifier(0x72),
        .timestamp_ms = 110,
        .event = .{ .usage_checkpointed = .{ .usage = first_checkpoint } },
    });
    try std.testing.expectEqual(@as(u64, 7), state.?.usage.?.lines_added);

    try applyDelta(alloc, &state, .{
        .log_generation = generation,
        .seq = 3,
        .event_id = identifier(0x73),
        .timestamp_ms = 120,
        .event = .{ .history_turn_committed = .{
            .conversation_language = session.ConversationLanguage.literal("en"),
            .total_input_tokens = 5,
            .total_output_tokens = 3,
            .turn = .{ .assistant = .{
                .user = .{ .text = @constCast("hello") },
                .assistant = @constCast("world"),
            } },
        } },
    });
    try std.testing.expectEqual(@as(u64, 7), state.?.usage.?.lines_added);

    try applyDelta(alloc, &state, .{
        .log_generation = generation,
        .seq = 4,
        .event_id = identifier(0x74),
        .timestamp_ms = 130,
        .event = .{ .usage_checkpointed = .{ .usage = second_checkpoint } },
    });
    try std.testing.expectEqual(@as(u64, 9), state.?.usage.?.lines_added);
}

test "recovery checkpoint events replace and clear deterministically" {
    const alloc = std.testing.allocator;
    var state: ?session_codec.DurableSessionState = null;
    defer if (state) |*current| current.deinit(alloc);
    const generation = identifier(0x80);
    try applyDelta(alloc, &state, .{
        .log_generation = generation,
        .seq = 1,
        .event_id = identifier(0x81),
        .timestamp_ms = 100,
        .event = .{ .session_started = .{
            .id = @constCast("session-recovery-events"),
            .created_at_ms = 100,
            .origin_workspace_root = @constCast("/tmp/origin"),
            .workspace_root = @constCast("/tmp/current"),
            .conversation_language = session.ConversationLanguage.literal("en"),
            .preferences = .{
                .model = @constCast("test/model"),
                .effort = types.ReasoningEffort.literal("medium"),
                .fast_mode = false,
            },
        } },
    });

    const first = session_codec.RecoveryCheckpoint{
        .turn_id = 11,
        .user = .{ .text = @constCast("prompt") },
        .assistant_source = @constCast("partial"),
        .cause = .network_interrupted,
        .action = .continuing_response,
        .authority = .{ .provider = .gateway, .model = @constCast("test/model") },
        .requested_fast_mode = false,
        .fast_mode = false,
        .max_provider_attempts = 10,
        .consumed_provider_attempts = 2,
    };
    try applyDelta(alloc, &state, .{
        .log_generation = generation,
        .seq = 2,
        .event_id = identifier(0x82),
        .timestamp_ms = 110,
        .event = .{ .recovery_checkpoint_set = .{ .checkpoint = first } },
    });
    try std.testing.expectEqualStrings("partial", state.?.recovery_checkpoint.?.assistant_source);

    var replacement = first;
    replacement.assistant_source = @constCast("partial plus more");
    replacement.consumed_provider_attempts = 3;
    try applyDelta(alloc, &state, .{
        .log_generation = generation,
        .seq = 3,
        .event_id = identifier(0x83),
        .timestamp_ms = 120,
        .event = .{ .recovery_checkpoint_set = .{ .checkpoint = replacement } },
    });
    try std.testing.expectEqualStrings(
        "partial plus more",
        state.?.recovery_checkpoint.?.assistant_source,
    );
    try std.testing.expectEqual(@as(usize, 3), state.?.recovery_checkpoint.?.consumed_provider_attempts);

    try applyDelta(alloc, &state, .{
        .log_generation = generation,
        .seq = 4,
        .event_id = identifier(0x84),
        .timestamp_ms = 130,
        .event = .{ .history_turn_committed = .{
            .conversation_language = session.ConversationLanguage.literal("en"),
            .total_input_tokens = 4,
            .total_output_tokens = 2,
            .turn = .{ .assistant = .{
                .user = .{ .text = @constCast("prompt") },
                .assistant = @constCast("partial plus more"),
            } },
        } },
    });
    try std.testing.expect(state.?.recovery_checkpoint == null);

    try applyDelta(alloc, &state, .{
        .log_generation = generation,
        .seq = 5,
        .event_id = identifier(0x85),
        .timestamp_ms = 140,
        .event = .{ .recovery_checkpoint_set = .{ .checkpoint = replacement } },
    });
    try applyDelta(alloc, &state, .{
        .log_generation = generation,
        .seq = 6,
        .event_id = identifier(0x86),
        .timestamp_ms = 150,
        .event = .{ .recovery_checkpoint_cleared = .{} },
    });
    try std.testing.expect(state.?.recovery_checkpoint == null);

    try applyDelta(alloc, &state, .{
        .log_generation = generation,
        .seq = 7,
        .event_id = identifier(0x87),
        .timestamp_ms = 160,
        .event = .{ .recovery_checkpoint_cleared = .{} },
    });
    try std.testing.expect(state.?.recovery_checkpoint == null);
}

fn identifier(seed: u8) Identifier {
    var value: Identifier = undefined;
    for (&value, 0..) |*byte, i| byte.* = seed +% @as(u8, @intCast(i));
    return value;
}

test "conversation transition validates sequence tool identity and checkpoint safety" {
    try validateConversationTransition(.{}, .{
        .seq = 1,
        .timestamp_ms = 10,
        .event = .{ .context_checkpoint = .{
            .covers_through_seq = 0,
            .summary = "first-turn checkpoint",
        } },
    });
    const pending = [_]PendingToolCall{.{ .call_id = "call-shell", .tool_name = "shell", .seq = 2 }};
    const state = ConversationStateView{ .last_seq = 2, .pending_tool_calls = &pending };
    try validateConversationTransition(state, .{
        .seq = 3,
        .timestamp_ms = 10,
        .event = .{ .tool_result = .{
            .call_id = "call-shell",
            .tool_name = "shell",
            .status = .success,
            .artifact_ref = "sha256:abc",
            .stored_bytes = 4,
            .completeness = .complete,
            .preview = "done",
        } },
    });
    try std.testing.expectError(error.OrphanToolResult, validateConversationTransition(.{ .last_seq = 2 }, .{
        .seq = 3,
        .timestamp_ms = 10,
        .event = .{ .tool_result = .{
            .call_id = "missing",
            .tool_name = "shell",
            .status = .success,
            .artifact_ref = "sha256:missing",
            .stored_bytes = 0,
            .completeness = .unknown,
        } },
    }));
    try std.testing.expectError(error.UnresolvedToolCall, validateConversationTransition(state, .{
        .seq = 3,
        .timestamp_ms = 10,
        .event = .{ .context_checkpoint = .{ .covers_through_seq = 2, .summary = "checkpoint" } },
    }));
    try std.testing.expectError(error.UnresolvedToolCall, validateConversationTransition(state, .{
        .seq = 3,
        .timestamp_ms = 10,
        .event = .{ .turn_completed = .{} },
    }));
    try validateConversationTransition(state, .{
        .seq = 3,
        .timestamp_ms = 10,
        .event = .{ .context_checkpoint = .{ .covers_through_seq = 1, .summary = "checkpoint" } },
    });
    const checkpointed = ConversationStateView{ .last_seq = 3, .latest_checkpoint_coverage = 1, .pending_tool_calls = &pending };
    try validateConversationTransition(checkpointed, .{
        .seq = 4,
        .timestamp_ms = 10,
        .event = .{ .context_checkpoint = .{ .covers_through_seq = 1, .summary = "same covered prefix" } },
    });
    try std.testing.expectError(error.InvalidCheckpointCoverage, validateConversationTransition(checkpointed, .{
        .seq = 4,
        .timestamp_ms = 10,
        .event = .{ .context_checkpoint = .{ .covers_through_seq = 0, .summary = "backwards coverage" } },
    }));
    try std.testing.expectError(error.InvalidCheckpointCoverage, validateConversationTransition(checkpointed, .{
        .seq = 4,
        .timestamp_ms = 10,
        .event = .{ .context_checkpoint = .{ .covers_through_seq = 4, .summary = "future coverage" } },
    }));
    try std.testing.expectError(error.OutOfOrderConversationEvent, validateConversationTransition(state, .{
        .seq = 4,
        .timestamp_ms = 10,
        .event = .{ .assistant = .{ .text = "skipped sequence" } },
    }));
}

test "conversation frame round trips an external tool result reference" {
    const alloc = std.testing.allocator;
    const encoded = try encodeConversationFrame(alloc, .{
        .seq = 7,
        .timestamp_ms = 42,
        .event = .{ .tool_result = .{
            .call_id = "call-shell",
            .tool_name = "shell",
            .status = .success,
            .artifact_ref = "sha256:abcdef",
            .stored_bytes = 4096,
            .completeness = .partial,
            .preview = "bounded preview",
        } },
    });
    defer alloc.free(encoded);
    try std.testing.expect(std.mem.endsWith(u8, encoded, "\n"));
    try std.testing.expect(std.mem.find(u8, encoded, "full result bytes") == null);
    try std.testing.expect(std.mem.find(u8, encoded, "DurableSessionState") == null);

    var decoded = try decodeConversationFrame(alloc, encoded);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u64, 7), decoded.value.seq);
    try std.testing.expectEqual(@as(i64, 42), decoded.value.timestamp_ms);
    const result = decoded.value.event.tool_result;
    try std.testing.expectEqualStrings("call-shell", result.call_id);
    try std.testing.expectEqualStrings("shell", result.tool_name);
    try std.testing.expectEqualStrings("sha256:abcdef", result.artifact_ref);
    try std.testing.expectEqual(ArtifactCompleteness.partial, result.completeness);
    try std.testing.expectEqualStrings("bounded preview", result.preview.?);
}

test "conversation frame reads old records and preserves new reasoning-only assistants" {
    const alloc = std.testing.allocator;
    var old = try decodeConversationFrame(alloc, "{\"schema_version\":1,\"seq\":1,\"timestamp_ms\":1,\"event\":{\"assistant\":{\"text\":\"old\"}}}\n");
    defer old.deinit();
    try std.testing.expect(old.value.event.assistant.provider_replay == null);
    try validateConversationTransition(.{}, old.value);
    const replay = types.ProviderReplay{ .source = .{ .provider = .gateway, .model = "test" }, .parts_json = "[{\"type\":\"reasoning\",\"text\":\"\"}]" };
    const encoded = try encodeConversationFrame(alloc, .{ .seq = 2, .timestamp_ms = 2, .event = .{ .assistant = .{ .text = "", .provider_replay = replay } } });
    defer alloc.free(encoded);
    var current = try decodeConversationFrame(alloc, encoded);
    defer current.deinit();
    try std.testing.expectEqual(@as(u8, 2), current.value.schema_version);
    try std.testing.expectEqualStrings(replay.parts_json, current.value.event.assistant.provider_replay.?.parts_json);
    try validateConversationTransition(.{ .last_seq = 1 }, current.value);
}

test "conversation frame decoder stays bounded under fuzzed bytes" {
    try std.testing.fuzz({}, fuzzConversationFrame, .{
        .corpus = &.{
            "",
            "{}\n",
            "{\"schema_version\":1}\n",
            "{\"schema_version\":1,\"seq\":1,\"timestamp_ms\":0,\"event\":{\"assistant\":{\"text\":\"ok\"}}}\n",
        },
    });
}

fn fuzzConversationFrame(_: void, smith: *std.testing.Smith) !void {
    var buffer: [4096]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    var decoded = decodeConversationFrame(
        std.testing.allocator,
        buffer[0..len],
    ) catch return;
    decoded.deinit();
}

test "history turn projects to flat conversation events with artifact references" {
    var images = [_]types.ToolImage{.{ .data = @constCast("image bytes"), .mime_type = @constCast("image/png") }};
    var calls = [_]types.ToolCall{.{
        .id = "call-shell",
        .name = "shell",
        .arguments_json = "{\"command\":\"printf done\"}",
    }};
    var results = [_]types.PersistedToolResult{.{
        .tool_call_id = @constCast("call-shell"),
        .tool_name = @constCast("shell"),
        .status = .success,
        .output = @constCast("done"),
        .output_handle = @constCast("result-shell.txt"),
        .tool_image_handle = @constCast("image-result-shell.txt"),
        .tool_images = &images,
        .output_bytes = 4,
        .stored_output_bytes = 4,
    }};
    var steps = [_]types.ToolExecutionStep{.{
        .assistant = @constCast("I will run it."),
        .tool_calls = &calls,
        .tool_results = &results,
    }};
    const turn = types.HistoryTurn{ .assistant = .{
        .user = .{ .text = @constCast("Run the command.") },
        .assistant = @constCast("It completed."),
        .execution = .{ .tool_steps = &steps },
    } };
    var events: std.ArrayList(ConversationEvent) = .empty;
    defer events.deinit(std.testing.allocator);

    try appendHistoryTurnConversationEvents(std.testing.allocator, &events, turn);

    try std.testing.expectEqual(@as(usize, 6), events.items.len);
    try std.testing.expectEqualStrings("Run the command.", events.items[0].user.text);
    try std.testing.expectEqualStrings("I will run it.", events.items[1].assistant.text);
    try std.testing.expectEqualStrings("call-shell", events.items[2].tool_call.call_id);
    try std.testing.expectEqualStrings("result-shell.txt", events.items[3].tool_result.artifact_ref);
    try std.testing.expectEqualStrings("image-result-shell.txt", events.items[3].tool_result.tool_image_handle.?);
    const encoded = try encodeConversationFrame(std.testing.allocator, .{
        .seq = 4,
        .timestamp_ms = 1,
        .event = events.items[3],
    });
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(std.mem.find(u8, encoded, "image bytes") == null);
    var decoded = try decodeConversationFrame(std.testing.allocator, encoded);
    defer decoded.deinit();
    try std.testing.expectEqualStrings("image-result-shell.txt", decoded.value.event.tool_result.tool_image_handle.?);
    try std.testing.expectEqualStrings("It completed.", events.items[4].assistant.text);
    try std.testing.expect(events.items[5] == .turn_completed);
    results[0].tool_image_handle = null;
    try std.testing.expectError(error.ConversationArtifactRequired, appendHistoryTurnConversationEvents(std.testing.allocator, &events, turn));
}
