const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const mem_utils = @import("../shared/mem_utils.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const model_provider = @import("../config/model_provider.zig");
const session = @import("session.zig");
const session_child_store = @import("session_child_store.zig");
const session_codec = @import("session_codec.zig");
const types = @import("../shared/types.zig");
const session_event = @import("session_event.zig");
const history_snapshot = @import("history_snapshot.zig");
const session_layout = @import("session_layout.zig");
const session_replay = @import("session_replay.zig");
const result_store = @import("result_store.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const json_decode = @import("../shared/json_decode.zig");
const private_file_permissions = std.Io.File.Permissions.fromMode(0o600);

const Allocator = std.mem.Allocator;
const Identifier = session_event.Identifier;
const private_dir_permissions = std.Io.File.Permissions.fromMode(0o700);
/// Real first events stay under 2 KiB; this leaves room for two maximum-length
/// workspace paths while keeping listing reads independent of log size.
const listed_first_event_max_bytes: usize = 16 * 1024;
const events_file = "events.jsonl";
const manifest_file = "session.json";
const permission_state_file = "permissions.json";
const recovery_checkpoint_file = "recovery.json";

/// Counts a turn's steps and steering as its frames arrive, as a context cut
/// counts them.
pub const ConversationProgress = struct {
    point: types.ContextHistoryCut = .{},
    pending: usize = 0,
    coverage: u64 = 0,
    reached: bool = false,
    pending_assistant: ?struct { seq: u64, has_replay: bool } = null,

    pub fn observe(self: *ConversationProgress, seq: u64, event: session_event.ConversationEvent, cut: ?types.ContextHistoryCut) !void {
        if (self.pending_assistant) |assistant| {
            const standalone = switch (event) {
                .assistant, .context_checkpoint, .interrupted => true,
                // A note counts no step, as steering does (D93, D94).
                .steering, .context_note, .runtime_context => assistant.has_replay,
                else => false,
            };
            if (standalone) {
                self.point.tool_steps += 1;
                if (cut) |target| if (!self.reached and std.meta.eql(self.point, target)) {
                    self.coverage = assistant.seq;
                    self.reached = true;
                };
            }
            self.pending_assistant = null;
        }
        if (cut) |target| if (std.meta.eql(self.point, target) and self.pending == 0) {
            self.reached = true;
        };
        switch (event) {
            .assistant => |value| {
                if (value.standalone_response) {
                    self.point.tool_steps += 1;
                } else if (value.text.len > 0 or value.provider_replay != null) {
                    self.pending_assistant = .{ .seq = seq, .has_replay = value.provider_replay != null };
                }
            },
            .tool_call => self.pending += 1,
            .tool_result => {
                if (self.pending == 0) return error.InvalidConversationFrame;
                self.pending -= 1;
                if (self.pending == 0) self.point.tool_steps += 1;
            },
            .steering => self.point.steering += 1,
            .turn_completed, .interrupted => {
                self.point.turns += 1;
                self.point.tool_steps = 0;
                self.point.steering = 0;
                self.pending = 0;
            },
            else => {},
        }
        if (cut) |target| {
            if (!self.reached and std.meta.eql(self.point, target) and self.pending == 0) {
                self.coverage = seq;
                self.reached = true;
            }
        }
    }
};

test "conversation cut counts standalone text without changing steering prefixes" {
    var progress: ConversationProgress = .{};
    const cut: types.ContextHistoryCut = .{ .tool_steps = 1 };
    try progress.observe(1, .{ .user = .{ .text = "request" } }, cut);
    try progress.observe(2, .{ .assistant = .{ .text = "CANDIDATE_741" } }, cut);
    try progress.observe(3, .{ .assistant = .{ .text = "FINAL_852" } }, cut);
    try std.testing.expectEqual(@as(usize, 1), progress.point.tool_steps);
    try std.testing.expectEqual(@as(u64, 2), progress.coverage);
    try std.testing.expect(progress.reached);

    var steering: ConversationProgress = .{};
    try steering.observe(1, .{ .user = .{ .text = "request" } }, null);
    try steering.observe(2, .{ .assistant = .{ .text = "prefix" } }, null);
    try steering.observe(3, .{ .steering = .{ .text = "human update" } }, null);
    try std.testing.expectEqual(@as(usize, 0), steering.point.tool_steps);
    try std.testing.expectEqual(@as(usize, 1), steering.point.steering);
}

/// What a replay of a v1 conversation log has seen so far.
const ReplayState = struct {
    alloc: Allocator,
    last_seq: u64 = 0,
    latest_checkpoint_coverage: u64 = 0,
    turn_open: bool = false,
    pending_tool_calls: std.ArrayList(session_event.PendingToolCall) = .empty,

    fn pendingIndex(self: *const ReplayState, call_id: []const u8) ?usize {
        for (self.pending_tool_calls.items, 0..) |pending, index| {
            if (std.mem.eql(u8, pending.call_id, call_id)) return index;
        }
        return null;
    }

    fn clearPendingToolCalls(self: *ReplayState) void {
        for (self.pending_tool_calls.items) |pending| {
            self.alloc.free(@constCast(pending.call_id));
            self.alloc.free(@constCast(pending.tool_name));
        }
        self.pending_tool_calls.clearRetainingCapacity();
    }

    fn applyReplayedEvent(
        self: *ReplayState,
        seq: u64,
        event: session_event.ConversationEvent,
    ) !void {
        const turn_open = try nextConversationTurnOpen(self.turn_open, event);
        switch (event) {
            .tool_call => |call| {
                const call_id = try self.alloc.dupe(u8, call.call_id);
                errdefer mem_utils.free(self.alloc, call_id);
                const tool_name = try self.alloc.dupe(u8, call.tool_name);
                errdefer mem_utils.free(self.alloc, tool_name);
                try self.pending_tool_calls.append(self.alloc, .{
                    .call_id = call_id,
                    .tool_name = tool_name,
                    .seq = seq,
                });
            },
            .tool_result => |result| {
                const index = self.pendingIndex(result.call_id) orelse
                    return error.OrphanToolResult;
                const completed = self.pending_tool_calls.orderedRemove(index);
                self.alloc.free(@constCast(completed.call_id));
                self.alloc.free(@constCast(completed.tool_name));
            },
            .context_checkpoint => |checkpoint| {
                self.latest_checkpoint_coverage = checkpoint.covers_through_seq;
            },
            .interrupted => self.clearPendingToolCalls(),
            .user, .assistant, .steering, .turn_completed => {},
            // Only a v2 session saves a context note or runtime context (D93, D94).
            .context_note, .runtime_context => return error.InvalidConversationFrame,
        }
        self.last_seq = seq;
        self.turn_open = turn_open;
    }
};

fn nextConversationTurnOpen(open: bool, event: session_event.ConversationEvent) !bool {
    return switch (event) {
        .user => if (open) error.InvalidConversationFrame else true,
        .turn_completed, .interrupted => if (open) false else error.InvalidConversationFrame,
        .assistant, .tool_call, .tool_result, .steering => if (open) true else error.InvalidConversationFrame,
        .context_checkpoint => open,
        // v1 logs never hold a context note or runtime context; only a v2
        // session saves them (D93, D94). Every v1 reader below refuses both.
        .context_note, .runtime_context => error.InvalidConversationFrame,
    };
}

pub fn loadConversationPermissionState(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
) !session_permission_state.State {
    const bytes = readManagedFileAlloc(
        alloc,
        dir,
        permission_state_file,
        session_codec.max_permission_state_bytes,
    ) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer alloc.free(bytes);
    return session_codec.decodePermissionState(alloc, bytes);
}

/// The checkpoint `recovery.json` holds for the log's last seq, or null when
/// it names an earlier one (v1 drops it). Caller owns the result.
pub fn loadConversationRecoveryCheckpoint(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    conversation_seq: u64,
) !?session_codec.RecoveryCheckpoint {
    const bytes = readManagedFileAlloc(
        alloc,
        dir,
        recovery_checkpoint_file,
        session_codec.max_recovery_checkpoint_bytes + 128,
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer alloc.free(bytes);
    var parsed = json_decode.parseFromSlice(struct {
        conversation_seq: u64,
        checkpoint: std.json.Value,
    }, alloc, bytes, .{
        .max_value_len = session_codec.max_recovery_checkpoint_bytes,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidRecoveryCheckpoint,
    };
    defer parsed.deinit();
    if (parsed.value.conversation_seq < conversation_seq) return null;
    if (parsed.value.conversation_seq != conversation_seq) return error.InvalidRecoveryCheckpoint;
    return session_codec.parseRecoveryCheckpoint(alloc, parsed.value.checkpoint) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidRecoveryCheckpoint,
    };
}

fn loadConversationStateIfPresent(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    expected_session_id: []const u8,
) !?session_codec.DurableSessionState {
    return load_conversation_state_at_boundary(alloc, dir, expected_session_id, null);
}

fn load_conversation_state_at_boundary(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    expected_session_id: []const u8,
    recovery: ?ConversationRecoveryBoundary,
) !?session_codec.DurableSessionState {
    const metadata_bytes = readManagedFileAlloc(
        alloc,
        dir,
        manifest_file,
        session_codec.max_session_metadata_bytes,
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer alloc.free(metadata_bytes);
    var probe = std.json.parseFromSlice(std.json.Value, alloc, metadata_bytes, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer probe.deinit();
    const object = if (probe.value == .object) probe.value.object else return null;
    const version_value = object.get("schema_version") orelse return null;
    if (version_value != .number_string or
        !std.mem.eql(u8, version_value.number_string, "4"))
    {
        return null;
    }

    var metadata = try session_codec.decodeSessionMetadata(alloc, metadata_bytes);
    defer metadata.deinit();
    if (!std.mem.eql(u8, metadata.value.id, expected_session_id)) {
        return error.InvalidSessionMetadata;
    }
    var conversation_seq: u64 = 0;
    var open_work_id: ?[]u8 = null;
    defer if (open_work_id) |work_id| alloc.free(work_id);
    const history = blk: {
        var event_file = try openManagedFile(dir, events_file, .read_only);
        defer event_file.close(io_mod.getIo());
        const length = if (recovery) |boundary| boundary.bytes else try event_file.length(io_mod.getIo());
        // Recovery boundaries keep the raw-log path; the snapshot cache covers
        // only full loads, where a prefix replay splices into the live log.
        if (recovery != null) {
            var pure_log = HistoryFrameSource{ .log_file = event_file, .log_length = length, .limit = length };
            break :blk try replayConversationHistory(alloc, &pure_log, &conversation_seq, &open_work_id);
        }
        var frames = try HistoryFrameSource.open(alloc, dir, expected_session_id, event_file, length);
        defer frames.deinit(alloc);
        const result = replayConversationHistory(alloc, &frames, &conversation_seq, &open_work_id) catch |err| retry: {
            if (err == error.OutOfMemory or frames.verified == null) return err;
            // A cache-sourced replay failure is a cache problem, not a log
            // problem: retry once from the raw log so the cache can never fail
            // a load.
            debug_trace.logf("session", "history cache replay rejected id={s} err={s}; reading log", .{ expected_session_id, @errorName(err) });
            conversation_seq = 0;
            open_work_id = null;
            frames.verified_cleanup(alloc);
            frames.reset();
            break :retry try replayConversationHistory(alloc, &frames, &conversation_seq, &open_work_id);
        };
        break :blk result;
    };
    errdefer session.freeHistoryTurnSlice(alloc, history);
    if (recovery == null) try restoreContextResultBodies(alloc, dir, history);
    const latest_work_id = if (recovery != null and recovery.?.turn_open and open_work_id != null)
        open_work_id
    else
        latestConversationWorkId(history);
    const last_work_id = if (latest_work_id) |work_id|
        try alloc.dupe(u8, work_id)
    else
        null;
    errdefer if (last_work_id) |work_id| mem_utils.free(alloc, work_id);
    var permission_state = try loadConversationPermissionState(alloc, dir);
    errdefer permission_state.deinit(alloc);
    var recovery_checkpoint = if (recovery == null)
        try loadConversationRecoveryCheckpoint(alloc, dir, conversation_seq)
    else
        null;
    errdefer if (recovery_checkpoint) |*checkpoint| checkpoint.deinit(alloc);
    if (recovery_checkpoint) |*checkpoint| {
        var capability: ?session_child_store.SessionChildCapability = null;
        defer if (capability) |*value| value.deinit();
        try restoreExecutionResultBodies(alloc, dir, &capability, &checkpoint.execution);
        if (checkpoint.user.work_id == null) {
            checkpoint.user.work_id = open_work_id;
            open_work_id = null;
        }
    }
    const id = try alloc.dupe(u8, metadata.value.id);
    errdefer mem_utils.free(alloc, id);
    const origin = try alloc.dupe(u8, metadata.value.origin_workspace_root);
    errdefer mem_utils.free(alloc, origin);
    const workspace = try alloc.dupe(u8, metadata.value.workspace_root);
    errdefer mem_utils.free(alloc, workspace);
    const model = try alloc.dupe(u8, metadata.value.model);
    errdefer mem_utils.free(alloc, model);
    const language = session.ConversationLanguage.fromSlice(
        metadata.value.conversation_language,
    ) catch return error.InvalidSessionMetadata;
    const provider = metadata.value.provider;
    const effort = types.ReasoningEffort.parse(metadata.value.effort) orelse
        return error.InvalidSessionMetadata;
    return .{
        .id = id,
        .origin_workspace_root = origin,
        .workspace_root = workspace,
        .created_at_ms = metadata.value.created_at_ms,
        .updated_at_ms = metadata.value.updated_at_ms,
        .conversation_language = language,
        .preferences = .{
            .provider = provider,
            .model = model,
            .effort = effort,
            .fast_mode = metadata.value.fast_mode,
            .ultrafast_mode = metadata.value.ultrafast_mode orelse false,
        },
        .history = history,
        .context_history_start = latestConversationCheckpointIndex(history),
        .total_input_tokens = 0,
        .total_output_tokens = 0,
        .permission_state = permission_state,
        .last_subagent_work_id = last_work_id,
        .recovery_checkpoint = recovery_checkpoint,
        .subagent_child = metadata.value.subagent_child,
    };
}

fn latestConversationWorkId(history: []const session.HistoryTurn) ?[]const u8 {
    var latest: ?[]const u8 = null;
    for (history) |turn| {
        if (session.historyTurnWorkId(turn)) |work_id| latest = work_id;
    }
    return latest;
}

pub fn hasConversationMetadata(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
) !bool {
    const bytes = (try readConversationMetadataBytes(alloc, dir)) orelse return false;
    defer alloc.free(bytes);
    return isConversationMetadata(alloc, bytes);
}

pub const ConversationRecoveryBoundary = struct {
    bytes: u64 = 0,
    seq: u64 = 0,
    timestamp_ms: i64 = 0,
    turn_open: bool = false,
};

fn find_conversation_recovery_boundary(alloc: Allocator, dir: *io_mod.VerifiedDir) !ConversationRecoveryBoundary {
    const scan = try scan_conversation_recovery(alloc, dir);
    if (scan.complete) return error.SessionRecoveryNotNeeded;
    return scan.boundary;
}

const ConversationRecovery = struct {
    boundary: ConversationRecoveryBoundary,
};

pub fn classify_conversation_recovery(alloc: Allocator, dir: *io_mod.VerifiedDir, _: []const u8) !ConversationRecovery {
    const scan = try scan_conversation_recovery(alloc, dir);
    if (scan.complete) return error.SessionRecoveryNotNeeded;
    return .{ .boundary = scan.boundary };
}

/// Reads only. The existing transition validator remains the record authority.
fn scan_conversation_recovery(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
) !struct { boundary: ConversationRecoveryBoundary, complete: bool } {
    var history_buffer: [8192]u8 = undefined;
    var reader = try ConversationHistoryReader.init(alloc, dir, &history_buffer);
    defer reader.deinit();
    const file = reader.file;
    const length = reader.length;
    reader.length = 0;
    var state = ReplayState{ .alloc = alloc };
    defer {
        state.clearPendingToolCalls();
        state.pending_tool_calls.deinit(alloc);
    }
    var boundary: ConversationRecoveryBoundary = .{};
    var offset: u64 = 0;
    var coverage_seq: u64 = 0;
    var coverage_progress: ConversationProgress = .{};
    var buffer: [8192]u8 = undefined;
    var lines = file.reader(io_mod.getIo(), &buffer);
    var coverage_buffer: [8192]u8 = undefined;
    var coverage_lines = file.reader(io_mod.getIo(), &coverage_buffer);
    scan: while (offset < length) {
        const line = session_replay.readBufferedLine(alloc, &lines, length, null) catch |err| switch (err) {
            error.TruncatedEventFrame, error.EventFrameTooLarge => break,
            else => return err,
        } orelse break;
        defer alloc.free(line.bytes);
        var decoded = session_event.decodeConversationFrame(alloc, line.bytes) catch |err| switch (err) {
            error.InvalidConversationFrame => break,
            else => return err,
        };
        defer decoded.deinit();
        session_event.validateConversationTransition(.{
            .last_seq = state.last_seq,
            .latest_checkpoint_coverage = state.latest_checkpoint_coverage,
            .pending_tool_calls = state.pending_tool_calls.items,
        }, decoded.value) catch break;
        if (decoded.value.event == .context_checkpoint) {
            const coverage = decoded.value.event.context_checkpoint.covers_through_seq;
            // Coverage is monotone, so historical cuts need only one extra scan.
            while (coverage_seq < coverage) {
                const covered = (try session_replay.readBufferedLine(alloc, &coverage_lines, offset, null)) orelse
                    return error.SessionRecoveryBoundaryInvalid;
                defer alloc.free(covered.bytes);
                var frame = try session_event.decodeConversationFrame(alloc, covered.bytes);
                defer frame.deinit();
                try coverage_progress.observe(frame.value.seq, frame.value.event, null);
                coverage_seq = frame.value.seq;
            }
            if (coverage_progress.pending != 0) break :scan;
        }
        state.applyReplayedEvent(decoded.value.seq, decoded.value.event) catch |err| switch (err) {
            error.InvalidConversationFrame => break :scan,
            else => return err,
        };
        // A valid frame must also be replayable before it can extend the copy.
        reader.length = line.next_offset;
        if (reader.next() catch |err| switch (err) {
            error.InvalidConversationFrame, error.ConversationSizeOverflow => break :scan,
            else => return err,
        }) |turn| session.freeHistoryTurn(alloc, turn);
        offset = line.next_offset;
        if (!state.turn_open or
            (decoded.value.event == .context_checkpoint and state.pending_tool_calls.items.len == 0))
        {
            boundary = .{
                .bytes = offset,
                .seq = state.last_seq,
                .timestamp_ms = decoded.value.timestamp_ms,
                .turn_open = state.turn_open,
            };
        }
    }
    const complete = offset == length and boundary.bytes == length;
    if (!complete and boundary.bytes == 0) return error.SessionRecoveryBoundaryInvalid;
    debug_trace.logf("session", "event=conversation_recovery_boundary source_bytes={d} retained_bytes={d} through_seq={d}", .{ length, boundary.bytes, boundary.seq });
    return .{ .boundary = boundary, .complete = complete };
}

/// Caller owns the returned complete archive, with a checkpointed open turn
/// explicitly interrupted rather than scheduling its abandoned continuation.
pub fn load_conversation_recovery_state(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    boundary: ConversationRecoveryBoundary,
) !session_codec.DurableSessionState {
    const loaded = load_conversation_state_at_boundary(alloc, dir, session_id, boundary) catch |err| switch (err) {
        error.InvalidSessionMetadata, error.InvalidSessionFormat => return error.SessionRecoveryBoundaryInvalid,
        else => return err,
    };
    var state = loaded orelse return error.SessionRecoveryBoundaryInvalid;
    errdefer state.deinit(alloc);
    const file = try openManagedFile(dir, events_file, .read_only);
    defer file.close(io_mod.getIo());
    const archive = try load_conversation_archive_from_file(alloc, file, boundary.bytes, boundary.turn_open);
    session.freeHistoryTurnSlice(alloc, state.history);
    state.history = archive;
    state.context_history_start = latestConversationCheckpointIndex(archive);
    return state;
}

test "conversation recovery boundary validates prefix and never edits source" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = io_mod.VerifiedDir{ .dir = tmp.dir };
    const prefix =
        "{\"schema_version\":1,\"seq\":1,\"timestamp_ms\":1,\"event\":{\"user\":{\"text\":\"fact\"}}}\n" ++
        "{\"schema_version\":1,\"seq\":2,\"timestamp_ms\":1,\"event\":{\"assistant\":{\"text\":\"saved\"}}}\n" ++
        "{\"schema_version\":1,\"seq\":3,\"timestamp_ms\":1,\"event\":{\"turn_completed\":{}}}\n";
    const suffixes = [_][]const u8{
        "{",
        "invalid\n",
        "{\"schema_version\":1,\"seq\":99,\"timestamp_ms\":1,\"event\":{\"user\":{\"text\":\"wrong sequence\"}}}\n",
        "{\"schema_version\":1,\"seq\":4,\"timestamp_ms\":1,\"event\":{\"context_checkpoint\":{\"covers_through_seq\":9,\"summary\":\"invalid coverage\"}}}\n",
        "{\"schema_version\":1,\"seq\":4,\"timestamp_ms\":1,\"event\":{\"user\":{\"text\":\"unfinished batch\"}}}\n" ++
            "{\"schema_version\":1,\"seq\":5,\"timestamp_ms\":1,\"event\":{\"tool_call\":{\"call_id\":\"one\",\"tool_name\":\"shell\",\"arguments_json\":\"{}\"}}}\n" ++
            "{\"schema_version\":1,\"seq\":6,\"timestamp_ms\":1,\"event\":{\"tool_call\":{\"call_id\":\"two\",\"tool_name\":\"shell\",\"arguments_json\":\"{}\"}}}\n" ++
            "{\"schema_version\":1,\"seq\":7,\"timestamp_ms\":1,\"event\":{\"interrupted\":{\"reason\":\"failed\"}}}\ninvalid\n",
    };
    for (suffixes) |suffix| {
        const bytes = try std.mem.concat(alloc, u8, &.{ prefix, suffix });
        defer alloc.free(bytes);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = events_file, .data = bytes, .flags = .{ .permissions = private_file_permissions } });
        const boundary = try find_conversation_recovery_boundary(alloc, &dir);
        try std.testing.expectEqual(prefix.len, boundary.bytes);
        try std.testing.expectEqual(@as(u64, 3), boundary.seq);
        try std.testing.expect(!boundary.turn_open);
        const actual = try readManagedFileAlloc(alloc, &dir, events_file, bytes.len);
        defer alloc.free(actual);
        try std.testing.expectEqualStrings(bytes, actual);
    }
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = events_file, .data = prefix, .flags = .{ .permissions = private_file_permissions } });
    try std.testing.expectError(error.SessionRecoveryNotNeeded, find_conversation_recovery_boundary(alloc, &dir));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = events_file, .data = "invalid\n", .flags = .{ .permissions = private_file_permissions } });
    try std.testing.expectError(error.SessionRecoveryBoundaryInvalid, find_conversation_recovery_boundary(alloc, &dir));
}

test "conversation recovery rejects checkpoint cuts inside tool batches" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = io_mod.VerifiedDir{ .dir = tmp.dir };
    const prefix =
        "{\"schema_version\":1,\"seq\":1,\"timestamp_ms\":1,\"event\":{\"user\":{\"text\":\"request\"}}}\n" ++
        "{\"schema_version\":1,\"seq\":2,\"timestamp_ms\":1,\"event\":{\"tool_call\":{\"call_id\":\"one\",\"tool_name\":\"shell\",\"arguments_json\":\"{}\"}}}\n" ++
        "{\"schema_version\":1,\"seq\":3,\"timestamp_ms\":1,\"event\":{\"tool_call\":{\"call_id\":\"two\",\"tool_name\":\"shell\",\"arguments_json\":\"{}\"}}}\n" ++
        "{\"schema_version\":1,\"seq\":4,\"timestamp_ms\":1,\"event\":{\"tool_result\":{\"call_id\":\"one\",\"tool_name\":\"shell\",\"status\":\"success\",\"artifact_ref\":\"one.txt\",\"stored_bytes\":0,\"completeness\":\"complete\"}}}\n" ++
        "{\"schema_version\":1,\"seq\":5,\"timestamp_ms\":1,\"event\":{\"tool_result\":{\"call_id\":\"two\",\"tool_name\":\"shell\",\"status\":\"success\",\"artifact_ref\":\"two.txt\",\"stored_bytes\":0,\"completeness\":\"complete\"}}}\n" ++
        "{\"schema_version\":1,\"seq\":6,\"timestamp_ms\":1,\"event\":{\"turn_completed\":{}}}\n";
    for ([_]u64{ 1, 2, 3, 4, 5, 6 }) |coverage| {
        for ([_][]const u8{ "", "invalid\n" }) |tail| {
            const bytes = try alloc.print("{s}{{\"schema_version\":1,\"seq\":7,\"timestamp_ms\":1,\"event\":{{\"context_checkpoint\":{{\"covers_through_seq\":{d},\"summary\":\"checkpoint\"}}}}}}\n{s}", .{ prefix, coverage, tail });
            defer alloc.free(bytes);
            try tmp.dir.writeFile(std.testing.io, .{ .sub_path = events_file, .data = bytes, .flags = .{ .permissions = private_file_permissions } });
            if (coverage >= 2 and coverage <= 4) {
                const boundary = try find_conversation_recovery_boundary(alloc, &dir);
                try std.testing.expectEqual(prefix.len, boundary.bytes);
                try std.testing.expectEqual(@as(u64, 6), boundary.seq);
            } else if (tail.len == 0) {
                try std.testing.expectError(error.SessionRecoveryNotNeeded, find_conversation_recovery_boundary(alloc, &dir));
            } else {
                const boundary = try find_conversation_recovery_boundary(alloc, &dir);
                try std.testing.expectEqual(bytes.len - tail.len, boundary.bytes);
            }
        }
    }
}

test "conversation recovery allocation failures do not become corruption" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = io_mod.VerifiedDir{ .dir = tmp.dir };
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = events_file, .flags = .{ .permissions = private_file_permissions }, .data = "{\"schema_version\":1,\"seq\":1,\"timestamp_ms\":1,\"event\":{\"user\":{\"text\":\"fact\"}}}\n" ++
        "{\"schema_version\":1,\"seq\":2,\"timestamp_ms\":1,\"event\":{\"assistant\":{\"text\":\"saved\"}}}\n" ++
        "{\"schema_version\":1,\"seq\":3,\"timestamp_ms\":1,\"event\":{\"turn_completed\":{}}}\n" ++
        "{\"schema_version\":1,\"seq\":4,\"timestamp_ms\":1,\"event\":{\"context_checkpoint\":{\"covers_through_seq\":1,\"summary\":\"retained fact\"}}}\n" ++
        "{\"schema_version\":1,\"seq\":5,\"timestamp_ms\":1,\"event\":{\"user\":{\"text\":\"pending\"}}}\n" ++
        "{\"schema_version\":1,\"seq\":6,\"timestamp_ms\":1,\"event\":{\"tool_call\":{\"call_id\":\"call1\",\"tool_name\":\"shell\",\"arguments_json\":\"{}\"}}}\ninvalid\n" });
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, struct {
        fn check(alloc: Allocator, source: *io_mod.VerifiedDir) !void {
            const boundary = try find_conversation_recovery_boundary(alloc, source);
            try std.testing.expectEqual(@as(u64, 4), boundary.seq);
        }
    }.check, .{&dir});
}

test "conversation recovery state preserves allocation errors and contains invalid metadata" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = io_mod.VerifiedDir{ .dir = tmp.dir };
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = manifest_file, .flags = .{ .permissions = private_file_permissions }, .data = "{\"schema_version\":4,\"id\":\"recovery-source\",\"created_at_ms\":1,\"updated_at_ms\":1,\"origin_workspace_root\":\"/tmp\",\"workspace_root\":\"/tmp\",\"conversation_language\":\"en\",\"provider\":\"gateway\",\"model\":\"test/model\",\"effort\":\"auto\",\"fast_mode\":false,\"title\":null,\"subagent_child\":false}" });
    const prefix =
        "{\"schema_version\":1,\"seq\":1,\"timestamp_ms\":1,\"event\":{\"user\":{\"text\":\"fact\"}}}\n" ++
        "{\"schema_version\":1,\"seq\":2,\"timestamp_ms\":1,\"event\":{\"assistant\":{\"text\":\"saved\"}}}\n" ++
        "{\"schema_version\":1,\"seq\":3,\"timestamp_ms\":1,\"event\":{\"turn_completed\":{}}}\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = events_file, .flags = .{ .permissions = private_file_permissions }, .data = prefix ++ "invalid\n" });
    const boundary = try find_conversation_recovery_boundary(alloc, &dir);
    try std.testing.expectError(error.SessionRecoveryBoundaryInvalid, load_conversation_recovery_state(alloc, &dir, "wrong-id", boundary));
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, struct {
        fn check(a: Allocator, source: *io_mod.VerifiedDir, cut: ConversationRecoveryBoundary) !void {
            var state = try load_conversation_recovery_state(a, source, "recovery-source", cut);
            defer state.deinit(a);
            try std.testing.expectEqual(@as(usize, 1), state.history.len);
            try std.testing.expect(state.recovery_checkpoint == null);
        }
    }.check, .{ &dir, boundary });
}

/// Reads and validates current metadata once. The caller owns the decoded value.
pub fn readConversationMetadata(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
) !?session_codec.DecodedSessionMetadata {
    const bytes = (try readConversationMetadataBytes(alloc, dir)) orelse return null;
    defer alloc.free(bytes);
    if (!try isConversationMetadata(alloc, bytes)) return null;
    return session_codec.decodeSessionMetadata(alloc, bytes) catch |err| switch (err) {
        error.SessionMetadataTooLarge => error.InvalidSessionFormat,
        else => err,
    };
}

fn readConversationMetadataBytes(alloc: Allocator, dir: *io_mod.VerifiedDir) !?[]u8 {
    const bytes = readManagedFileAlloc(
        alloc,
        dir,
        manifest_file,
        session_codec.max_session_metadata_bytes,
    ) catch |err| switch (err) {
        error.FileNotFound, error.InvalidSessionFormat => return null,
        else => return err,
    };
    return bytes;
}

fn isConversationMetadata(alloc: Allocator, bytes: []const u8) !bool {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    defer parsed.deinit();
    const object = if (parsed.value == .object) parsed.value.object else return false;
    const version = object.get("schema_version") orelse return false;
    return version == .number_string and std.mem.eql(u8, version.number_string, "4");
}

/// One replay frame regardless of origin. Snapshot frames carry their verified
/// decoded envelope; log frames decode the JSON line as before.
const HistoryFrame = struct {
    log_offset: u64,
    log_bytes: u32,
    line_crc: u32,
    envelope: session_event.ConversationEnvelope,

    fn nextOffset(self: HistoryFrame) u64 {
        return self.log_offset + self.log_bytes;
    }
};

/// Serves replay frames from the verified snapshot prefix, then the log
/// suffix. When no usable snapshot exists, serves the whole log. Never writes;
/// callers on writable paths decide whether to rebuild or extend the cache.
const HistoryFrameSource = struct {
    log_file: std.Io.File,
    log_length: u64,
    /// Fixed read boundary for recovery loads; null follows the physical
    /// length so later passes see frames appended after the source opened.
    limit: ?u64 = null,
    verified: ?history_snapshot.Verified = null,
    cursor: history_snapshot.Cursor = undefined,
    buffer: [8192]u8 = undefined,
    reader: ?std.Io.File.Reader = null,
    log_next: u64 = 0,
    /// Cache-file offset of the last frame served from the snapshot, null when
    /// the last frame came from the log. The writable scan uses this to mirror
    /// log truncations into the cache.
    last_frame_snapshot_file_offset: ?u64 = null,

    /// Verifies the snapshot against the already-open log file and prepares a
    /// merged source. Pure log when the cache is absent or invalid.
    fn open(
        alloc: Allocator,
        dir: *io_mod.VerifiedDir,
        session_id: []const u8,
        log_file: std.Io.File,
        log_length: u64,
    ) !HistoryFrameSource {
        var source = HistoryFrameSource{ .log_file = log_file, .log_length = log_length };
        if (history_snapshot.openAndVerify(alloc, dir, session_id, log_file, log_length) catch |err| blk: {
            debug_trace.logf("session", "history cache verify failed id={s} err={s}", .{ session_id, @errorName(err) });
            break :blk null;
        }) |verified| {
            source.verified = verified;
            source.cursor = .{ .file = verified.file, .frames = verified.frames };
            source.log_next = verified.covered_log_bytes;
        }
        return source;
    }

    fn deinit(self: *HistoryFrameSource, alloc: Allocator) void {
        if (self.verified) |*verified| verified.deinit(alloc);
        self.* = undefined;
    }

    /// Drops the cache portion after a cache-sourced failure; the source
    /// becomes pure log. Callers then reset() and replay from the log.
    fn verified_cleanup(self: *HistoryFrameSource, alloc: Allocator) void {
        if (self.verified) |*verified| verified.deinit(alloc);
        self.verified = null;
        self.cursor = undefined;
        self.reader = null;
        self.log_next = 0;
        self.last_frame_snapshot_file_offset = null;
    }

    fn coveredLogBytes(self: *const HistoryFrameSource) u64 {
        return if (self.verified) |*verified| verified.covered_log_bytes else 0;
    }

    /// Re-stats the log so a pass that follows an open-time truncation or a
    /// recovery append reads the current file, not the length captured at open.
    fn refresh(self: *HistoryFrameSource) !void {
        const physical = try self.log_file.length(io_mod.getIo());
        self.log_length = if (self.limit) |limit| @min(physical, limit) else physical;
    }

    /// Repositions the source at the frame starting at `log_offset`.
    fn seekLogOffset(self: *HistoryFrameSource, log_offset: u64) !void {
        try self.refresh();
        if (self.verified) |*verified| {
            if (log_offset < verified.covered_log_bytes) {
                try self.cursor.seekLogOffset(log_offset);
                self.log_next = verified.covered_log_bytes;
                self.reader = null;
                return;
            }
            self.cursor.index = verified.frames.len;
        }
        if (log_offset > self.log_length) return error.InvalidConversationFrame;
        self.log_next = log_offset;
        self.reader = null;
    }

    fn reset(self: *HistoryFrameSource) void {
        if (self.verified != null) self.cursor.reset();
        self.reader = null;
        self.last_frame_snapshot_file_offset = null;
        self.refresh() catch |err| {
            debug_trace.logf("session", "history source refresh failed err={s}; keeping stale length", .{@errorName(err)});
        };
        self.log_next = self.coveredLogBytes();
    }

    /// Returns the next frame in log order, or null at the end. Decoded memory
    /// is owned by `arena`.
    fn next(self: *HistoryFrameSource, arena: Allocator) !?HistoryFrame {
        if (self.verified) |*verified| {
            if (self.cursor.index < verified.frames.len) {
                const meta = verified.frames[self.cursor.index];
                const envelope = (try self.cursor.next(arena)) orelse return error.InvalidCache;
                self.last_frame_snapshot_file_offset = meta.file_offset;
                return .{
                    .log_offset = meta.log_offset,
                    .log_bytes = meta.log_bytes,
                    .line_crc = meta.line_crc,
                    .envelope = envelope,
                };
            }
        }
        self.last_frame_snapshot_file_offset = null;
        return self.nextFromLog(arena);
    }

    fn nextFromLog(self: *HistoryFrameSource, arena: Allocator) !?HistoryFrame {
        if (self.log_next >= self.log_length) return null;
        if (self.reader == null) {
            self.reader = self.log_file.reader(io_mod.getIo(), &self.buffer);
            self.reader.?.pos = self.log_next;
        }
        const frame_offset = self.log_next;
        const line = (try session_replay.readBufferedLine(arena, &self.reader.?, self.log_length, null)) orelse return null;
        self.log_next = line.next_offset;
        const decoded = try session_event.decodeConversationFrame(arena, line.bytes);
        return .{
            .log_offset = frame_offset,
            .log_bytes = @intCast(line.bytes.len),
            .line_crc = std.hash.Crc32.hash(line.bytes),
            .envelope = decoded.value,
        };
    }

    /// Reads exactly the frame starting at `log_offset`.
    fn readAtLogOffset(self: *HistoryFrameSource, arena: Allocator, log_offset: u64) !?HistoryFrame {
        try self.refresh();
        if (self.verified) |*verified| {
            if (log_offset < verified.covered_log_bytes) {
                var probe = self.cursor;
                try probe.seekLogOffset(log_offset);
                const meta = probe.frames[probe.index];
                const envelope = (try probe.next(arena)) orelse return error.InvalidCache;
                return .{
                    .log_offset = meta.log_offset,
                    .log_bytes = meta.log_bytes,
                    .line_crc = meta.line_crc,
                    .envelope = envelope,
                };
            }
        }
        const line = (try session_replay.readLineAt(arena, self.log_file, log_offset, self.log_length)) orelse return null;
        const decoded = try session_event.decodeConversationFrame(arena, line.bytes);
        return .{
            .log_offset = log_offset,
            .log_bytes = @intCast(line.bytes.len),
            .line_crc = std.hash.Crc32.hash(line.bytes),
            .envelope = decoded.value,
        };
    }
};

fn replayConversationHistory(
    alloc: Allocator,
    source: *HistoryFrameSource,
    conversation_seq: *u64,
    open_work_id: *?[]u8,
) ![]session.HistoryTurn {
    const window = try findConversationReplayWindow(alloc, source);
    conversation_seq.* = window.last_complete_seq;
    var history: std.ArrayList(session.HistoryTurn) = .empty;
    errdefer {
        for (history.items) |turn| session.freeHistoryTurn(alloc, turn);
        history.deinit(alloc);
    }
    var turn = ConversationTurnBuilder.init(alloc);
    defer turn.deinit();
    var frame_arena = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(frame_arena);
    if (window.checkpoint_offset) |checkpoint_offset| {
        const frame = (try source.readAtLogOffset(frame_arena.allocator(), checkpoint_offset)) orelse return error.InvalidConversationFrame;
        const summary = try alloc.dupe(u8, frame.envelope.event.context_checkpoint.summary);
        errdefer mem_utils.free(alloc, summary);
        try history.append(alloc, .{ .compacted_summary = .{
            .summary = summary,
            .removed_turn_count = window.prior_turn_count,
            .compaction_count = window.compaction_count,
            .root_user_messages_complete = false,
            .permission_feedback_complete = false,
        } });
    }
    if (window.active_user_offset) |user_offset| {
        const frame = (try source.readAtLogOffset(frame_arena.allocator(), user_offset)) orelse
            return error.InvalidConversationFrame;
        if (frame.envelope.event != .user) return error.InvalidConversationFrame;
        try turn.begin(frame.envelope.event.user);
    }
    var checkpoint_turn_open = window.active_user_offset != null;
    try source.seekLogOffset(window.offset);
    while (true) {
        const frame = source.next(frame_arena.allocator()) catch |err| switch (err) {
            error.TruncatedEventFrame => break,
            else => return err,
        } orelse break;
        switch (frame.envelope.event) {
            .user => |value| try turn.begin(value),
            .assistant => |value| try turn.appendAssistant(value),
            .tool_call => |value| try turn.appendToolCall(value),
            .tool_result => |value| try turn.appendToolResult(value),
            .steering => |value| try turn.appendSteering(value.text),
            .context_note, .runtime_context => return error.InvalidConversationFrame,
            .turn_completed => |value| {
                const completed = try turn.finishAssistant(value);
                checkpoint_turn_open = false;
                errdefer session.freeHistoryTurn(alloc, completed);
                try history.append(alloc, completed);
            },
            .interrupted => |value| {
                const completed = try turn.finishInterrupted(value);
                checkpoint_turn_open = false;
                errdefer session.freeHistoryTurn(alloc, completed);
                try history.append(alloc, completed);
            },
            .context_checkpoint => {
                try turn.finishStandalone();
                checkpoint_turn_open = turn.user != null;
            },
        }
        _ = frame_arena.reset(.retain_capacity);
    }
    // A concurrent writer may have exposed a complete-record prefix of its
    // final batched turn before sync. The next writable open truncates that
    // incomplete turn; read-only replay returns the preceding complete turns.
    const completed = try history.toOwnedSlice(alloc);
    if (checkpoint_turn_open) {
        if (turn.user) |*user| {
            open_work_id.* = user.work_id;
            user.work_id = null;
        }
    }
    return completed;
}

/// Reads complete canonical turns while retaining only the turn being built.
/// Each returned turn is owned by the caller.
const ConversationHistoryReader = struct {
    alloc: Allocator,
    file: std.Io.File,
    reader: std.Io.File.Reader,
    length: u64,
    offset: u64 = 0,
    builder: ConversationTurnBuilder,

    /// Borrows buffer until deinit; owns the opened file and current turn.
    pub fn init(alloc: Allocator, dir: *io_mod.VerifiedDir, buffer: []u8) !ConversationHistoryReader {
        var file = try openManagedFile(dir, events_file, .read_only);
        errdefer file.close(io_mod.getIo());
        return .{
            .alloc = alloc,
            .file = file,
            .length = try file.length(io_mod.getIo()),
            .reader = file.reader(io_mod.getIo(), buffer),
            .builder = ConversationTurnBuilder.init(alloc),
        };
    }

    pub fn deinit(self: *ConversationHistoryReader) void {
        self.builder.deinit();
        self.file.close(io_mod.getIo());
        self.* = undefined;
    }

    pub fn next(self: *ConversationHistoryReader) !?session.HistoryTurn {
        while (self.offset < self.length) {
            const line = session_replay.readBufferedLine(self.alloc, &self.reader, self.length, null) catch |err| switch (err) {
                error.TruncatedEventFrame => return null,
                else => return err,
            } orelse return null;
            defer self.alloc.free(line.bytes);
            var decoded = try session_event.decodeConversationFrame(self.alloc, line.bytes);
            defer decoded.deinit();
            const completed: ?session.HistoryTurn = switch (decoded.value.event) {
                .user => |value| blk: {
                    try self.builder.begin(value);
                    break :blk null;
                },
                .assistant => |value| blk: {
                    try self.builder.appendAssistant(value);
                    break :blk null;
                },
                .tool_call => |value| blk: {
                    try self.builder.appendToolCall(value);
                    break :blk null;
                },
                .tool_result => |value| blk: {
                    try self.builder.appendToolResult(value);
                    break :blk null;
                },
                .steering => |value| blk: {
                    try self.builder.appendSteering(value.text);
                    break :blk null;
                },
                .context_note, .runtime_context => return error.InvalidConversationFrame,
                .turn_completed => |value| try self.builder.finishAssistant(value),
                .interrupted => |value| try self.builder.finishInterrupted(value),
                .context_checkpoint => blk: {
                    if (self.builder.calls.items.len != 0 or self.builder.results.items.len != 0) {
                        return error.InvalidConversationFrame;
                    }
                    try self.builder.finishStandalone();
                    break :blk null;
                },
            };
            self.offset = line.next_offset;
            if (completed) |turn| return turn;
        }
        return null;
    }
};

pub fn loadConversationArchive(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
) ![]session.HistoryTurn {
    var file = try openManagedFile(dir, events_file, .read_only);
    defer file.close(io_mod.getIo());
    const length = try file.length(io_mod.getIo());
    var source = HistoryFrameSource{ .log_file = file, .log_length = length, .limit = length };
    if (readConversationMetadata(alloc, dir) catch null) |metadata| {
        defer metadata.deinit();
        const opened: ?HistoryFrameSource = HistoryFrameSource.open(alloc, dir, metadata.value.id, file, length) catch |err| blk: {
            debug_trace.logf("session", "history cache archive open failed err={s}; reading log", .{@errorName(err)});
            break :blk null;
        };
        if (opened) |with_cache| {
            if (with_cache.verified != null) {
                // Keep the load bounded at open time, matching the raw-log path.
                var bounded = with_cache;
                bounded.limit = length;
                source = bounded;
            }
        }
    }
    defer source.deinit(alloc);
    return load_conversation_archive_from_source(alloc, &source, false) catch |err| {
        if (err == error.OutOfMemory or source.verified == null) return err;
        debug_trace.logf("session", "history cache archive rejected err={s}; reading log", .{@errorName(err)});
        source.verified_cleanup(alloc);
        source.reset();
        return load_conversation_archive_from_source(alloc, &source, false);
    };
}

fn load_conversation_archive_from_file(
    alloc: Allocator,
    file: std.Io.File,
    length: u64,
    close_open_turn: bool,
) ![]session.HistoryTurn {
    var source = HistoryFrameSource{ .log_file = file, .log_length = length, .limit = length };
    return load_conversation_archive_from_source(alloc, &source, close_open_turn);
}

fn load_conversation_archive_from_source(
    alloc: Allocator,
    source: *HistoryFrameSource,
    close_open_turn: bool,
) ![]session.HistoryTurn {
    var turns: std.ArrayList(session.HistoryTurn) = .empty;
    errdefer {
        for (turns.items) |turn| session.freeHistoryTurn(alloc, turn);
        turns.deinit(alloc);
    }
    var builder = ConversationTurnBuilder.init(alloc);
    defer builder.deinit();
    var raw_turn_count: usize = 0;
    var compaction_count: usize = 0;
    var frame_arena = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(frame_arena);
    source.reset();
    while (true) {
        const frame = source.next(frame_arena.allocator()) catch |err| switch (err) {
            error.TruncatedEventFrame => break,
            else => return err,
        } orelse break;
        const decoded_value = frame.envelope;
        const completed: ?session.HistoryTurn = switch (decoded_value.event) {
            .user => |value| blk: {
                try builder.begin(value);
                break :blk null;
            },
            .assistant => |value| blk: {
                try builder.appendAssistant(value);
                break :blk null;
            },
            .tool_call => |value| blk: {
                try builder.appendToolCall(value);
                break :blk null;
            },
            .tool_result => |value| blk: {
                try builder.appendToolResult(value);
                break :blk null;
            },
            .steering => |value| blk: {
                try builder.appendSteering(value.text);
                break :blk null;
            },
            .context_note, .runtime_context => return error.InvalidConversationFrame,
            .turn_completed => |value| try builder.finishAssistant(value),
            .interrupted => |value| try builder.finishInterrupted(value),
            .context_checkpoint => |value| blk: {
                if (builder.calls.items.len != 0 or builder.results.items.len != 0) {
                    return error.InvalidConversationFrame;
                }
                try builder.finishStandalone();
                compaction_count += 1;
                break :blk .{ .compacted_summary = .{
                    .summary = try alloc.dupe(u8, value.summary),
                    .removed_turn_count = raw_turn_count,
                    .compaction_count = compaction_count,
                    .root_user_messages_complete = false,
                    .permission_feedback_complete = false,
                } };
            },
        };
        if (completed) |turn| {
            errdefer session.freeHistoryTurn(alloc, turn);
            try turns.append(alloc, turn);
            if (turn != .compacted_summary) raw_turn_count += 1;
        }
        _ = frame_arena.reset(.retain_capacity);
    }
    if (close_open_turn and builder.user != null) {
        const completed = try builder.finishInterrupted(.{ .reason = .failed });
        errdefer session.freeHistoryTurn(alloc, completed);
        try turns.append(alloc, completed);
    }
    return turns.toOwnedSlice(alloc);
}

const ConversationReplayWindow = struct {
    offset: u64 = 0,
    prior_turn_count: usize = 0,
    compaction_count: usize = 0,
    last_complete_seq: u64 = 0,
    active_user_offset: ?u64 = null,
    checkpoint_offset: ?u64 = null,
    coverage: u64 = 0,
};

const ConversationReplayScan = struct {
    window: ConversationReplayWindow = .{},
    turn_count: usize = 0,
    last_seq: u64 = 0,
    active_user_offset: ?u64 = null,

    fn observe(self: *ConversationReplayScan, offset: u64, seq: u64, event: session_event.ConversationEvent) !void {
        const expected_seq = std.math.add(u64, self.last_seq, 1) catch return error.InvalidConversationFrame;
        if (seq != expected_seq) return error.InvalidConversationFrame;
        self.last_seq = seq;
        switch (event) {
            .user => {
                if (self.active_user_offset != null) return error.InvalidConversationFrame;
                self.active_user_offset = offset;
            },
            .turn_completed, .interrupted => {
                if (self.active_user_offset == null) return error.InvalidConversationFrame;
                self.active_user_offset = null;
                self.turn_count = std.math.add(usize, self.turn_count, 1) catch return error.InvalidConversationFrame;
                self.window.last_complete_seq = seq;
            },
            .context_checkpoint => |checkpoint| {
                self.window = .{
                    .offset = offset,
                    .prior_turn_count = self.turn_count,
                    .compaction_count = std.math.add(usize, self.window.compaction_count, 1) catch return error.InvalidConversationFrame,
                    .last_complete_seq = seq,
                    .active_user_offset = self.active_user_offset,
                    .checkpoint_offset = offset,
                    .coverage = checkpoint.covers_through_seq,
                };
            },
            .context_note, .runtime_context => return error.InvalidConversationFrame,
            else => {},
        }
    }

    fn finish(self: *const ConversationReplayScan, alloc: Allocator, source: *HistoryFrameSource) !ConversationReplayWindow {
        var window = self.window;
        // Coverage can precede the checkpoint: retain the recent exchanges
        // between those boundaries rather than replaying only after the record.
        if (window.checkpoint_offset != null) {
            window.offset = 0;
            window.active_user_offset = null;
            window.prior_turn_count = 0;
            source.reset();
            var frame_arena = std.heap.ArenaAllocator.init(alloc);
            defer mem_utils.deinit_arena(frame_arena);
            while (true) {
                const frame = (try source.next(frame_arena.allocator())) orelse break;
                if (frame.envelope.seq > window.coverage) break;
                switch (frame.envelope.event) {
                    .user => window.active_user_offset = frame.log_offset,
                    .turn_completed, .interrupted => {
                        window.active_user_offset = null;
                        window.prior_turn_count += 1;
                    },
                    else => {},
                }
                window.offset = frame.nextOffset();
                _ = frame_arena.reset(.retain_capacity);
            }
        }
        return window;
    }
};

fn findConversationReplayWindow(
    alloc: Allocator,
    source: *HistoryFrameSource,
) !ConversationReplayWindow {
    var scan: ConversationReplayScan = .{};
    source.reset();
    var frame_arena = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(frame_arena);
    while (true) {
        const frame = source.next(frame_arena.allocator()) catch |err| switch (err) {
            error.TruncatedEventFrame => break,
            else => return err,
        } orelse break;
        try scan.observe(frame.log_offset, frame.envelope.seq, frame.envelope.event);
        _ = frame_arena.reset(.retain_capacity);
    }
    return scan.finish(alloc, source);
}

pub const ConversationTurnBuilder = struct {
    alloc: Allocator,
    user: ?types.UserTurn = null,
    pending_assistant: ?[]u8 = null,
    pending_replay: ?types.ProviderReplay = null,
    calls: std.ArrayList(types.ToolCall) = .empty,
    results: std.ArrayList(types.PersistedToolResult) = .empty,
    steps: std.ArrayList(types.ToolExecutionStep) = .empty,
    steering: std.ArrayList(types.PersistedSteering) = .empty,
    context_notes: std.ArrayList(types.PersistedContextNote) = .empty,
    runtime_context: ?[][]u8 = null,

    pub fn init(alloc: Allocator) ConversationTurnBuilder {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *ConversationTurnBuilder) void {
        if (self.user) |user| types.freeUserTurn(self.alloc, user);
        if (self.pending_assistant) |text| self.alloc.free(text);
        if (self.pending_replay) |replay| types.freeProviderReplay(self.alloc, replay);
        for (self.calls.items) |call| types.freeToolCall(self.alloc, call);
        self.calls.deinit(self.alloc);
        for (self.results.items) |result| freeConversationToolResult(self.alloc, result);
        self.results.deinit(self.alloc);
        for (self.steps.items) |step| {
            if (step.assistant) |text| self.alloc.free(text);
            if (step.provider_replay) |replay| types.freeProviderReplay(self.alloc, replay);
            types.freeToolCallSlice(self.alloc, step.tool_calls);
            types.freePersistedToolResults(self.alloc, step.tool_results);
        }
        for (self.steering.items) |item| {
            self.alloc.free(item.text);
            if (item.assistant_prefix) |text| self.alloc.free(text);
        }
        self.steps.deinit(self.alloc);
        self.steering.deinit(self.alloc);
        for (self.context_notes.items) |item| types.freePersistedContextNote(self.alloc, item);
        self.context_notes.deinit(self.alloc);
        if (self.runtime_context) |texts| types.freeRuntimeContext(self.alloc, texts);
        self.* = undefined;
    }

    pub fn isIdle(self: *const ConversationTurnBuilder) bool {
        return self.user == null and
            self.pending_assistant == null and
            self.calls.items.len == 0 and
            self.results.items.len == 0 and
            self.steps.items.len == 0 and
            self.steering.items.len == 0 and
            self.context_notes.items.len == 0 and
            self.runtime_context == null;
    }

    pub fn begin(
        self: *ConversationTurnBuilder,
        value: session_event.ConversationUser,
    ) !void {
        if (!self.isIdle()) return error.InvalidConversationFrame;
        self.user = try types.dupeUserTurn(self.alloc, .{
            .text = @constCast(value.text),
            .images = @constCast(value.images),
            .work_id = if (value.work_id) |work_id| @constCast(work_id) else null,
        });
    }

    /// Marks who wrote the message that opened the turn being built.
    pub fn setUserAuthor(self: *ConversationTurnBuilder, author: types.MessageAuthor) !void {
        if (self.user) |*user| {
            user.author = author;
        } else return error.InvalidConversationFrame;
    }

    pub fn appendAssistant(self: *ConversationTurnBuilder, value: session_event.ConversationAssistant) !void {
        if (self.calls.items.len == 0 and self.results.items.len == 0) try self.finishStandalone();
        if (self.user == null or self.pending_assistant != null or self.calls.items.len != 0) {
            return error.InvalidConversationFrame;
        }
        {
            const text = try self.alloc.dupe(u8, value.text);
            errdefer mem_utils.free(self.alloc, text);
            self.pending_replay = if (value.provider_replay) |replay| try types.dupeProviderReplay(self.alloc, replay) else null;
            self.pending_assistant = text;
        }
        if (value.standalone_response) try self.finishStep();
    }

    pub fn appendToolCall(
        self: *ConversationTurnBuilder,
        value: session_event.ConversationToolCall,
    ) !void {
        if (self.user == null or self.results.items.len != 0) {
            return error.InvalidConversationFrame;
        }
        for (self.calls.items) |call| {
            if (std.mem.eql(u8, call.id, value.call_id)) return error.InvalidConversationFrame;
        }
        const call = try types.dupeToolCall(self.alloc, .{
            .id = value.call_id,
            .name = value.tool_name,
            .arguments_json = value.arguments_json,
            .argument_integrity = value.argument_integrity,
            .provisional_id = value.provisional_id,
            .provider_result = value.provider_result,
            .final_identity = value.final_identity,
            .provenance = value.provenance,
        });
        errdefer types.freeToolCall(self.alloc, call);
        try self.calls.append(self.alloc, call);
    }

    pub fn appendToolResult(
        self: *ConversationTurnBuilder,
        value: session_event.ConversationToolResult,
    ) !void {
        if (self.user == null or self.calls.items.len == 0) {
            return error.InvalidConversationFrame;
        }
        var matching_call = false;
        for (self.calls.items) |call| {
            if (!std.mem.eql(u8, call.id, value.call_id)) continue;
            if (!std.mem.eql(u8, call.name, value.tool_name)) {
                return error.InvalidConversationFrame;
            }
            matching_call = true;
            break;
        }
        if (!matching_call) return error.InvalidConversationFrame;
        for (self.results.items) |result| {
            if (std.mem.eql(u8, result.tool_call_id, value.call_id)) {
                return error.InvalidConversationFrame;
            }
        }

        const result = try dupeConversationToolResult(self.alloc, value);
        errdefer freeConversationToolResult(self.alloc, result);
        try self.results.append(self.alloc, result);
        if (self.results.items.len == self.calls.items.len) try self.finishStep();
    }

    /// Gives the result of `call_id`, already appended in this turn, the
    /// full-diff rows its edit saved apart from it. Copies `rows`. Returns
    /// false, keeping nothing, when no such result has a presentation
    /// without a full-diff source of its own.
    pub fn attachReviewLines(
        self: *ConversationTurnBuilder,
        call_id: []const u8,
        lifecycle_id: types.ToolLifecycleId,
        rows: []const types.CommittedFilePresentationLine,
    ) !bool {
        const result = self.findResult(call_id) orelse return false;
        const presentation = if (result.committed_file_presentation) |*value| value else return false;
        if (presentation.review_lines != null or presentation.lifecycle_id != null or
            presentation.previous_content != null or presentation.after_content != null or
            presentation.content_handle != null) return false;
        const owned_rows = try types.dupeCommittedFilePresentationLines(self.alloc, rows);
        errdefer types.freeCommittedFilePresentationLines(self.alloc, owned_rows);
        const owned_call_id = try self.alloc.dupe(u8, lifecycle_id.call_id);
        presentation.review_lines = owned_rows;
        presentation.lifecycle_id = .{ .turn_id = lifecycle_id.turn_id, .call_id = owned_call_id };
        return true;
    }

    /// The result of `call_id` in the open step or in a step this turn
    /// already finished.
    fn findResult(self: *ConversationTurnBuilder, call_id: []const u8) ?*types.PersistedToolResult {
        for (self.results.items) |*result| {
            if (std.mem.eql(u8, result.tool_call_id, call_id)) return result;
        }
        var index = self.steps.items.len;
        while (index > 0) {
            index -= 1;
            for (self.steps.items[index].tool_results) |*result| {
                if (std.mem.eql(u8, result.tool_call_id, call_id)) return result;
            }
        }
        return null;
    }

    pub fn finishStandalone(self: *ConversationTurnBuilder) !void {
        if (self.calls.items.len != 0 or self.results.items.len != 0) return error.InvalidConversationFrame;
        const text = self.pending_assistant orelse return;
        if (text.len == 0 and self.pending_replay == null) {
            self.alloc.free(text);
            self.pending_assistant = null;
            return;
        }
        try self.finishStep();
    }

    pub fn finishStep(self: *ConversationTurnBuilder) !void {
        try self.steps.ensureUnusedCapacity(self.alloc, 1);
        const calls = try self.calls.toOwnedSlice(self.alloc);
        errdefer types.freeToolCallSlice(self.alloc, calls);
        const results = try self.results.toOwnedSlice(self.alloc);
        errdefer types.freePersistedToolResults(self.alloc, results);
        self.steps.appendAssumeCapacity(.{
            .assistant = self.pending_assistant,
            .provider_replay = self.pending_replay,
            .tool_calls = calls,
            .tool_results = results,
        });
        self.pending_assistant = null;
        self.pending_replay = null;
    }

    pub fn appendSteering(self: *ConversationTurnBuilder, text: []const u8) !void {
        if (self.user == null or self.calls.items.len != 0 or self.results.items.len != 0) {
            return error.InvalidConversationFrame;
        }
        if (self.pending_replay != null) try self.finishStep();
        const owned = try self.alloc.dupe(u8, text);
        errdefer mem_utils.free(self.alloc, owned);
        try self.steering.append(self.alloc, .{
            .text = owned,
            .assistant_prefix = self.pending_assistant,
            .after_tool_step_count = self.steps.items.len,
        });
        self.pending_assistant = null;
    }

    /// The runtime context a turn captured comes right after its user message,
    /// once (D94).
    pub fn setRuntimeContext(self: *ConversationTurnBuilder, messages: []const []const u8) !void {
        if (self.user == null or self.runtime_context != null or self.steps.items.len != 0 or
            self.calls.items.len != 0 or self.results.items.len != 0 or self.pending_assistant != null or
            self.pending_replay != null or self.steering.items.len != 0 or self.context_notes.items.len != 0)
        {
            return error.InvalidConversationFrame;
        }
        if (messages.len == 0) return error.InvalidConversationFrame;
        self.runtime_context = try types.dupeRuntimeContext(self.alloc, messages);
    }

    /// A note sits at a step boundary: after the user's message or a step's
    /// last result, and before any steering or assistant text there (D93).
    pub fn appendContextNote(self: *ConversationTurnBuilder, text: []const u8, sources: []const types.ContextNoteSource) !void {
        if (self.user == null or self.calls.items.len != 0 or self.results.items.len != 0) {
            return error.InvalidConversationFrame;
        }
        if (self.pending_replay != null) try self.finishStep();
        if (self.pending_assistant != null) return error.InvalidConversationFrame;
        const owned = try self.alloc.dupe(u8, text);
        errdefer mem_utils.free(self.alloc, owned);
        const owned_sources = try types.dupeNoteSources(self.alloc, sources);
        errdefer types.freeNoteSources(self.alloc, owned_sources);
        try self.context_notes.append(self.alloc, .{
            .text = owned,
            .after_tool_step_count = self.steps.items.len,
            .sources = owned_sources,
        });
    }

    pub fn finishAssistant(
        self: *ConversationTurnBuilder,
        completed: session_event.ConversationTurnCompleted,
    ) !session.HistoryTurn {
        if (self.user == null or self.calls.items.len != 0 or self.results.items.len != 0) {
            return error.InvalidConversationFrame;
        }
        const assistant = if (self.pending_assistant) |text|
            text
        else
            try self.alloc.dupe(u8, "");
        const execution = try self.takeExecution(
            completed.files,
            completed.turn_summary,
        );
        const user = self.user.?;
        self.user = null;
        self.pending_assistant = null;
        const replay = self.pending_replay;
        self.pending_replay = null;
        return .{ .assistant = .{
            .user = user,
            .assistant = assistant,
            .execution = execution,
            .provider_replay = replay,
        } };
    }

    pub fn finishInterrupted(
        self: *ConversationTurnBuilder,
        value: session_event.ConversationInterruption,
    ) !session.HistoryTurn {
        if (self.user == null or self.results.items.len != 0 or self.calls.items.len > 1) {
            return error.InvalidConversationFrame;
        }
        if (self.calls.items.len == 0) try self.finishStandalone();
        const tool_call = if (self.calls.items.len == 1)
            self.calls.orderedRemove(0)
        else
            null;
        errdefer if (tool_call) |call| types.freeToolCall(self.alloc, call);
        if (self.pending_assistant) |text| {
            self.alloc.free(text);
            self.pending_assistant = null;
        }
        if (self.pending_replay) |replay| {
            debug_trace.logf("session", "provider replay omitted reason=interrupted_association", .{});
            types.freeProviderReplay(self.alloc, replay);
            self.pending_replay = null;
        }
        const assistant = if (value.partial_text) |text|
            try self.alloc.dupe(u8, text)
        else
            null;
        errdefer if (assistant) |text| mem_utils.free(self.alloc, text);
        const replay = if (value.command_replay_ref) |handle| blk: {
            const owned_handle = try self.alloc.dupe(u8, handle);
            break :blk types.CommandOutputReplay{ .available = .{
                .handle = owned_handle,
                .framed_bytes = std.math.cast(
                    usize,
                    value.command_replay_bytes.?,
                ) orelse {
                    self.alloc.free(owned_handle);
                    return error.ConversationSizeOverflow;
                },
            } };
        } else null;
        errdefer if (replay) |owned| types.freeCommandOutputReplay(self.alloc, owned);
        const command_artifact = if (value.command_artifact_ref) |handle|
            try self.alloc.dupe(u8, handle)
        else
            null;
        errdefer if (command_artifact) |handle| mem_utils.free(self.alloc, handle);
        const cancelled_command = if (replay != null or command_artifact != null)
            types.CancelledCommandPresentation{
                .output_replay = replay,
                .command_artifact_handle = command_artifact,
            }
        else
            null;
        const execution = try self.takeExecution(
            value.files,
            value.turn_summary,
        );
        const user = self.user.?;
        self.user = null;
        return .{ .interrupted = .{
            .user = user,
            .assistant = assistant,
            .tool_call = tool_call,
            .execution = execution,
            .cancelled_command = cancelled_command,
            .terminal_reason = value.reason,
            .cancellation_origin = value.cancellation_origin,
        } };
    }

    pub fn takeExecution(
        self: *ConversationTurnBuilder,
        files_source: []const types.FileEvidence,
        turn_summary: ?types.TurnSummary,
    ) !types.ExecutionMemory {
        const steps = try self.steps.toOwnedSlice(self.alloc);
        errdefer types.freeToolExecutionSteps(self.alloc, steps);
        const steering = try self.steering.toOwnedSlice(self.alloc);
        errdefer types.freePersistedSteering(self.alloc, steering);
        const context_notes = try self.context_notes.toOwnedSlice(self.alloc);
        errdefer types.freePersistedContextNotes(self.alloc, context_notes);
        const files = try types.dupeFileEvidenceSlice(self.alloc, files_source);
        const runtime_context = self.runtime_context;
        self.runtime_context = null;
        return .{
            .tool_steps = steps,
            .files = files,
            .steering = steering,
            .context_notes = context_notes,
            .runtime_context = runtime_context,
            .turn_summary = turn_summary,
        };
    }
};

test "conversation replay keeps reasoning-only assistant units before the final reply" {
    const alloc = std.testing.allocator;
    var builder = ConversationTurnBuilder.init(alloc);
    defer builder.deinit();
    const replay = types.ProviderReplay{ .source = .{ .provider = .gateway, .model = "test" }, .parts_json = "[{\"type\":\"reasoning\",\"text\":\"\"}]" };
    try builder.begin(.{ .text = "question" });
    try builder.appendAssistant(.{ .text = "", .provider_replay = replay });
    try builder.appendAssistant(.{ .text = "answer" });
    const turn = try builder.finishAssistant(.{});
    defer types.freeHistoryTurn(alloc, turn);
    try std.testing.expectEqualStrings("answer", turn.assistant.assistant);
    try std.testing.expectEqual(@as(usize, 1), turn.assistant.execution.tool_steps.len);
    try std.testing.expectEqualStrings(replay.parts_json, turn.assistant.execution.tool_steps[0].provider_replay.?.parts_json);
}

test "review rows attach once, only to a turn's edit with no full-diff source" {
    const alloc = std.testing.allocator;
    var builder = ConversationTurnBuilder.init(alloc);
    defer builder.deinit();
    const preview = [_]types.CommittedFilePresentationLine{.{ .kind = .addition, .new_line = 1, .text = "new" }};
    const rows = [_]types.CommittedFilePresentationLine{
        .{ .kind = .addition, .new_line = 1, .text = "new" },
        .{ .kind = .context, .old_line = 1, .new_line = 2, .text = "tail" },
    };
    try builder.begin(.{ .text = "edit" });
    try builder.appendToolCall(.{ .call_id = "edit-1", .tool_name = "edit_file", .arguments_json = "{}" });
    try builder.appendToolCall(.{ .call_id = "write-1", .tool_name = "write_file", .arguments_json = "{}" });
    try builder.appendToolResult(.{
        .call_id = "edit-1",
        .tool_name = "edit_file",
        .status = .success,
        .artifact_ref = "result.txt",
        .stored_bytes = 0,
        .completeness = .complete,
        .committed_file_presentation = .{ .path = "a.txt", .kind = .edited, .lines = &preview, .additions = 1, .deletions = 0, .truncated = false },
    });
    // The second result finishes the step; attaching still finds both.
    try builder.appendToolResult(.{
        .call_id = "write-1",
        .tool_name = "write_file",
        .status = .success,
        .artifact_ref = "result.txt",
        .stored_bytes = 0,
        .completeness = .complete,
        .committed_file_presentation = .{ .path = "b.txt", .kind = .added, .lines = &preview, .additions = 1, .deletions = 0, .truncated = false, .previous_content = "", .after_content = "new\n" },
    });
    const edit_id: types.ToolLifecycleId = .{ .turn_id = 1, .call_id = "edit-1" };
    try std.testing.expect(!try builder.attachReviewLines("missing", edit_id, &rows));
    try std.testing.expect(!try builder.attachReviewLines("write-1", .{ .turn_id = 1, .call_id = "write-1" }, &rows));
    try std.testing.expect(try builder.attachReviewLines("edit-1", edit_id, &rows));
    try std.testing.expect(!try builder.attachReviewLines("edit-1", edit_id, &rows));
    try builder.appendAssistant(.{ .text = "done" });
    const turn = try builder.finishAssistant(.{});
    defer types.freeHistoryTurn(alloc, turn);
    const results = turn.assistant.execution.tool_steps[0].tool_results;
    const edit = results[0].committed_file_presentation.?;
    try std.testing.expectEqual(rows.len, edit.review_lines.?.len);
    try std.testing.expectEqualStrings("tail", edit.review_lines.?[1].text);
    try std.testing.expectEqualStrings("edit-1", edit.lifecycle_id.?.call_id);
    try std.testing.expect(results[1].committed_file_presentation.?.review_lines == null);
}

test "reasoning-only checkpoint coverage and replay count the same completed unit" {
    const alloc = std.testing.allocator;
    const replay = types.ProviderReplay{ .source = .{ .provider = .gateway, .model = "test" }, .parts_json = "[{\"type\":\"reasoning\",\"text\":\"\"}]" };
    const events = [_]session_event.ConversationEvent{
        .{ .user = .{ .text = "question" } },
        .{ .assistant = .{ .text = "", .provider_replay = replay } },
        .{ .context_checkpoint = .{ .covers_through_seq = 2, .summary = "prior facts" } },
    };
    var progress: ConversationProgress = .{};
    var builder = ConversationTurnBuilder.init(alloc);
    defer builder.deinit();
    for (events, 1..) |event, seq| {
        try progress.observe(@intCast(seq), event, .{ .tool_steps = 1 });
        switch (event) {
            .user => |value| try builder.begin(value),
            .assistant => |value| try builder.appendAssistant(value),
            .context_checkpoint => try builder.finishStep(),
            else => unreachable,
        }
    }
    try std.testing.expectEqual(@as(u64, 2), progress.coverage);
    try std.testing.expectEqual(@as(usize, 1), progress.point.tool_steps);
    try std.testing.expectEqual(progress.point.tool_steps, builder.steps.items.len);
    try builder.appendAssistant(.{ .text = "final", .provider_replay = replay });
    try progress.observe(4, .{ .assistant = .{ .text = "final", .provider_replay = replay } }, null);
    try progress.observe(5, .{ .turn_completed = .{} }, null);
    const turn = try builder.finishAssistant(.{});
    defer types.freeHistoryTurn(alloc, turn);
    try std.testing.expectEqual(@as(usize, 1), progress.point.turns);
    try std.testing.expectEqual(@as(usize, 1), turn.assistant.execution.tool_steps.len);
    try std.testing.expectEqualStrings(replay.parts_json, turn.assistant.provider_replay.?.parts_json);
}

test "reasoning-only history keeps an empty final response as a distinct boundary" {
    const alloc = std.testing.allocator;
    const replay = types.ProviderReplay{ .source = .{ .provider = .gateway, .model = "test" }, .parts_json = "[{\"type\":\"reasoning\",\"text\":\"\"}]" };
    var steps = [_]types.ToolExecutionStep{.{ .provider_replay = replay }};
    var events: std.ArrayList(session_event.ConversationEvent) = .empty;
    defer events.deinit(alloc);
    try session_event.appendHistoryTurnConversationEvents(alloc, &events, .{ .assistant = .{
        .user = .{ .text = @constCast("question") },
        .assistant = @constCast(""),
        .execution = .{ .tool_steps = &steps },
    } });
    var builder = ConversationTurnBuilder.init(alloc);
    defer builder.deinit();
    var progress: ConversationProgress = .{};
    for (events.items, 1..) |event, seq| {
        try progress.observe(@intCast(seq), event, .{ .tool_steps = 1 });
        switch (event) {
            .user => |value| try builder.begin(value),
            .assistant => |value| try builder.appendAssistant(value),
            .turn_completed => |value| {
                const turn = try builder.finishAssistant(value);
                defer types.freeHistoryTurn(alloc, turn);
                try std.testing.expectEqual(@as(usize, 1), turn.assistant.execution.tool_steps.len);
                try std.testing.expectEqualStrings("", turn.assistant.assistant);
                try std.testing.expect(turn.assistant.provider_replay == null);
            },
            else => unreachable,
        }
    }
    try std.testing.expectEqual(@as(u64, 2), progress.coverage);
}

fn dupeConversationToolResult(
    alloc: Allocator,
    value: session_event.ConversationToolResult,
) !types.PersistedToolResult {
    const call_id = try alloc.dupe(u8, value.call_id);
    errdefer mem_utils.free(alloc, call_id);
    const tool_name = try alloc.dupe(u8, value.tool_name);
    errdefer mem_utils.free(alloc, tool_name);
    const output = try alloc.dupe(u8, value.preview orelse "");
    errdefer mem_utils.free(alloc, output);
    const handle = try alloc.dupe(u8, value.artifact_ref);
    errdefer mem_utils.free(alloc, handle);
    const image_handle = if (value.tool_image_handle) |image_ref| try alloc.dupe(u8, image_ref) else null;
    errdefer if (image_handle) |image_ref| mem_utils.free(alloc, image_ref);
    const preview = if (value.preview) |text| try alloc.dupe(u8, text) else null;
    errdefer if (preview) |text| mem_utils.free(alloc, text);
    var permission_feedback: [][]u8 = if (value.permission_feedback.len > 0)
        try alloc.alloc([]u8, value.permission_feedback.len)
    else
        &.{};
    errdefer if (permission_feedback.len > 0) mem_utils.free(alloc, permission_feedback);
    var feedback_count: usize = 0;
    errdefer for (permission_feedback[0..feedback_count]) |feedback| {
        alloc.free(feedback);
    };
    for (value.permission_feedback, 0..) |feedback, index| {
        permission_feedback[index] = try alloc.dupe(u8, feedback);
        feedback_count += 1;
    }
    const command_output_replay: ?types.CommandOutputReplay = if (value.command_replay_ref) |replay_ref| blk: {
        const replay_handle = try alloc.dupe(u8, replay_ref);
        break :blk .{ .available = .{
            .handle = replay_handle,
            .framed_bytes = std.math.cast(
                usize,
                value.command_replay_bytes.?,
            ) orelse {
                alloc.free(replay_handle);
                return error.ConversationSizeOverflow;
            },
        } };
    } else null;
    errdefer if (command_output_replay) |replay| {
        types.freeCommandOutputReplay(alloc, replay);
    };
    const committed_file_presentation = if (value.committed_file_presentation) |presentation|
        try types.dupeCommittedFilePresentation(alloc, presentation)
    else
        null;
    errdefer if (committed_file_presentation) |presentation| {
        types.freeCommittedFilePresentation(alloc, presentation);
    };
    const stored_bytes = std.math.cast(usize, value.stored_bytes) orelse
        return error.ConversationSizeOverflow;
    const output_bytes = std.math.cast(
        usize,
        value.output_bytes orelse value.stored_bytes,
    ) orelse return error.ConversationSizeOverflow;
    return .{
        .tool_call_id = call_id,
        .tool_name = tool_name,
        .status = value.status,
        .output = output,
        .output_handle = handle,
        .tool_image_handle = image_handle,
        .preview = preview,
        .output_bytes = output_bytes,
        .stored_output_bytes = stored_bytes,
        .truncated = value.completeness != .complete,
        .provider_native = value.provider_native,
        .review_feedback = value.review_feedback,
        .created_at_ms = value.created_at_ms,
        .permission_feedback = permission_feedback,
        .committed_file_presentation = committed_file_presentation,
        .command_output_replay = command_output_replay,
        .command_process_presentation = value.command_process_presentation,
        .terminal_action_presentation = value.terminal_action_presentation,
    };
}

fn freeConversationToolResult(
    alloc: Allocator,
    result: types.PersistedToolResult,
) void {
    alloc.free(result.tool_call_id);
    alloc.free(result.tool_name);
    alloc.free(result.output);
    if (result.output_handle) |handle| alloc.free(handle);
    types.freeToolImages(alloc, result.tool_images);
    if (result.tool_image_handle) |handle| alloc.free(handle);
    if (result.preview) |preview| alloc.free(preview);
    for (result.permission_feedback) |feedback| alloc.free(feedback);
    if (result.permission_feedback.len > 0) alloc.free(result.permission_feedback);
    if (result.committed_file_presentation) |presentation| {
        types.freeCommittedFilePresentation(alloc, presentation);
    }
    if (result.command_output_replay) |replay| {
        types.freeCommandOutputReplay(alloc, replay);
    }
}

fn latestConversationCheckpointIndex(history: []const session.HistoryTurn) usize {
    var index: usize = 0;
    for (history, 0..) |turn, candidate| {
        if (turn == .compacted_summary) index = candidate;
    }
    return index;
}

fn restoreContextResultBodies(alloc: Allocator, dir: *io_mod.VerifiedDir, history: []session.HistoryTurn) !void {
    var capability: ?session_child_store.SessionChildCapability = null;
    defer if (capability) |*value| value.deinit();
    for (history) |*turn| {
        const execution = switch (turn.*) {
            .assistant => |*entry| &entry.execution,
            .interrupted => |*entry| &entry.execution,
            .compacted_summary => continue,
        };
        try restoreExecutionResultBodies(alloc, dir, &capability, execution);
    }
}

fn restoreExecutionResultBodies(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    capability: *?session_child_store.SessionChildCapability,
    execution: *types.ExecutionMemory,
) !void {
    for (execution.tool_steps) |*step| for (step.tool_results) |*result| {
        const handle = result.output_handle orelse continue;
        if (!result.truncated and result.output.len == result.stored_output_bytes) continue;
        const body = if (result.truncated)
            try result_store.formatStoredResultOutput(alloc, handle, result.preview orelse "", result.stored_output_bytes)
        else blk: {
            if (capability.* == null) {
                const path = try io_mod.dirRealpathAlloc(alloc, dir.dir, ".");
                defer alloc.free(path);
                capability.* = try session_child_store.SessionChildCapability.init(alloc, dir.dir, path, .read_only);
            }
            break :blk result_store.readForReplayManaged(alloc, &capability.*.?, handle, result.stored_output_bytes) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    debug_trace.logf("session", "event=context_result_unavailable handle={s} err={s}; marking content unavailable", .{ handle, @errorName(err) });
                    const unavailable = try alloc.dupe(u8, "Saved tool-result content is unavailable. The complete output could not be restored.");
                    result.truncated = true;
                    break :blk unavailable;
                },
            };
        };
        alloc.free(result.output);
        result.output = body;
    };
}

pub fn externalizeConversationTurnResults(
    alloc: Allocator,
    turn: *session.HistoryTurn,
    capability: ?*session_child_store.SessionChildCapability,
) !void {
    const execution = switch (turn.*) {
        .assistant => |*entry| &entry.execution,
        .interrupted => |*entry| &entry.execution,
        .compacted_summary => return,
    };
    var has_results = false;
    for (execution.tool_steps) |step| {
        if (step.tool_results.len != 0) {
            has_results = true;
            break;
        }
    }
    if (!has_results) return;
    try externalizeExecutionResults(
        alloc,
        execution,
        capability,
        false,
    );
}

fn externalizeExecutionResults(
    alloc: Allocator,
    execution: *types.ExecutionMemory,
    capability: ?*session_child_store.SessionChildCapability,
    legacy_completeness_unknown: bool,
) !void {
    for (execution.tool_steps) |*step| {
        for (step.tool_results) |*result| {
            if (result.tool_images.len > 0 and result.tool_image_handle == null) {
                result.tool_image_handle = try result_store.storeToolImages(
                    alloc,
                    capability orelse return error.SessionChildCapabilityUnavailable,
                    result.tool_call_id,
                    result.tool_name,
                    result.tool_images,
                );
            }
            if (result.output_handle == null) {
                result.output_handle = try result_store.storeLargeResultManaged(
                    alloc,
                    capability orelse return error.SessionChildCapabilityUnavailable,
                    result.tool_call_id,
                    result.tool_name,
                    result.output,
                );
                if (legacy_completeness_unknown) result.truncated = true;
                result.stored_output_bytes = result.output.len;
            }
            if (result.preview == null) {
                result.preview = try result_store.previewText(
                    alloc,
                    result.output,
                    result_store.preview_bytes,
                );
            }
        }
    }
}

pub const OpenMode = enum {
    read_only,
    writable,
};

pub const CommitPosition = session_replay.CommitPosition;

test {
    _ = session_replay;
    _ = session_permission_state;
}

/// Drops file evidence an older format kept with an empty path, as v1's
/// migration does; returns how many. Also used by the v1 converter.
pub fn discardEmptyLegacyFileEvidence(alloc: Allocator, history: []session.HistoryTurn) !usize {
    var discarded: usize = 0;
    for (history) |*turn| {
        const execution = switch (turn.*) {
            .assistant => |*entry| &entry.execution,
            .interrupted => |*entry| &entry.execution,
            .compacted_summary => continue,
        };
        const files = execution.files;
        var retained_count: usize = 0;
        for (files) |file| if (file.path.len > 0) {
            retained_count += 1;
        };
        if (retained_count == files.len) continue;
        const retained = try alloc.alloc(types.FileEvidence, retained_count);
        var index: usize = 0;
        for (files) |file| {
            if (file.path.len == 0) {
                types.freeFileEvidence(alloc, file);
            } else {
                retained[index] = file;
                index += 1;
            }
        }
        discarded += files.len - retained_count;
        alloc.free(files);
        execution.files = retained;
    }
    return discarded;
}

pub const Root = struct {
    sessions: ?io_mod.VerifiedDir,
    display_root: []u8,
    mode: OpenMode,

    pub fn initFromHome(
        alloc: Allocator,
        home_path: []const u8,
        mode: OpenMode,
    ) !Root {
        const zio = io_mod.getIo();
        var home = std.Io.Dir.openDirAbsolute(zio, home_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => blk: {
                if (mode == .read_only) {
                    return .{
                        .sessions = null,
                        .display_root = try std.Io.Dir.path.join(
                            alloc,
                            &.{ home_path, profile_paths.root_dir_name, profile_paths.sessions_dir_name },
                        ),
                        .mode = mode,
                    };
                }
                std.Io.Dir.createDirAbsolute(zio, home_path, private_dir_permissions) catch |create_err| switch (create_err) {
                    error.PathAlreadyExists => {},
                    else => return create_err,
                };
                break :blk try std.Io.Dir.openDirAbsolute(zio, home_path, .{ .iterate = true });
            },
            else => return err,
        };
        defer home.close(zio);

        var durable_home = home.openDir(zio, profile_paths.root_dir_name, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => blk: {
                if (mode == .read_only) {
                    return .{
                        .sessions = null,
                        .display_root = try std.Io.Dir.path.join(
                            alloc,
                            &.{ home_path, profile_paths.root_dir_name, profile_paths.sessions_dir_name },
                        ),
                        .mode = mode,
                    };
                }
                var verified_home = io_mod.VerifiedDir{
                    .dir = try std.Io.Dir.openDirAbsolute(zio, home_path, .{
                        .iterate = true,
                    }),
                };
                defer verified_home.close();
                const created = try io_mod.openOrCreateVerifiedPrivateDir(
                    &verified_home,
                    profile_paths.root_dir_name,
                );
                break :blk created.dir;
            },
            error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
            else => return err,
        };
        defer durable_home.close(zio);
        if (mode == .writable) {
            durable_home.setPermissions(zio, private_dir_permissions) catch
                return error.PrivateStatePermissionsUnsupported;
        }
        try verifyPrivateDir(durable_home, mode);

        var sessions_dir = durable_home.openDir(zio, profile_paths.sessions_dir_name, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => blk: {
                if (mode == .read_only) {
                    return .{
                        .sessions = null,
                        .display_root = try std.Io.Dir.path.join(
                            alloc,
                            &.{ home_path, profile_paths.root_dir_name, profile_paths.sessions_dir_name },
                        ),
                        .mode = mode,
                    };
                }
                var parent = io_mod.VerifiedDir{ .dir = durable_home };
                const created = try io_mod.openOrCreateVerifiedPrivateDir(
                    &parent,
                    profile_paths.sessions_dir_name,
                );
                break :blk created.dir;
            },
            error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
            else => return err,
        };
        errdefer sessions_dir.close(zio);
        if (mode == .writable) {
            sessions_dir.setPermissions(zio, private_dir_permissions) catch
                return error.PrivateStatePermissionsUnsupported;
        }
        try verifyPrivateDir(sessions_dir, mode);
        const display_root = try io_mod.dirRealpathAlloc(alloc, sessions_dir, ".");
        return .{
            .sessions = .{ .dir = sessions_dir },
            .display_root = display_root,
            .mode = mode,
        };
    }

    pub fn deinit(self: *Root, alloc: Allocator) void {
        if (self.sessions) |*dir| dir.close();
        alloc.free(self.display_root);
        self.* = undefined;
    }

    pub fn loadReadOnly(
        self: *Root,
        alloc: Allocator,
        session_id: []const u8,
    ) !session_codec.DurableSessionState {
        if (self.sessions == null) return error.SessionNotFound;
        var session_dir = openSessionDir(
            &self.sessions.?,
            session_id,
            .read_only,
        ) catch |err| switch (err) {
            error.FileNotFound => return error.SessionNotFound,
            else => return err,
        };
        defer session_dir.close();
        return (try loadConversationStateIfPresent(
            alloc,
            &session_dir,
            session_id,
        )) orelse error.SessionMigrationRequired;
    }

    /// Reads the child identity a legacy session records in its first event,
    /// for a session discovery classified as legacy, whose metadata carries no
    /// child bit. The event is read only within `listed_first_event_max_bytes`,
    /// so listing never scans a log; a longer first line fails with
    /// `error.TruncatedEventFrame`.
    pub fn loadListedLegacyChildIdentity(
        self: *const Root,
        alloc: Allocator,
        session_id: []const u8,
    ) !bool {
        var sessions = self.sessions orelse return error.SessionNotFound;
        try session_layout.validateSessionId(session_id);
        var session_dir = openSessionDir(
            &sessions,
            session_id,
            .read_only,
        ) catch |err| switch (err) {
            error.FileNotFound => return error.SessionNotFound,
            else => return err,
        };
        defer session_dir.close();
        var log_file = try openManagedFile(&session_dir, events_file, .read_only);
        defer log_file.close(io_mod.getIo());
        return session_replay.readSubagentChildIdentityWithin(alloc, log_file, listed_first_event_max_bytes);
    }
};

fn validateLeaf(name: []const u8) !void {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or
        std.mem.eql(u8, name, "..") or
        std.mem.findAny(u8, name, "/\\") != null)
    {
        return error.SessionPathUnsafe;
    }
}

fn verifyPrivateDir(dir: std.Io.Dir, mode: OpenMode) !void {
    const stat = try dir.stat(io_mod.getIo());
    if (stat.kind != .directory) return error.SessionPathUnsafe;
    if (mode == .writable and stat.permissions.toMode() & 0o777 != 0o700) {
        return error.PrivateStatePermissionsUnsupported;
    }
}

fn verifyManagedFile(file: std.Io.File, mode: OpenMode) !void {
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.nlink != 1) return error.SessionPathUnsafe;
    if (mode == .writable and stat.permissions.toMode() & 0o777 != 0o600) {
        return error.PrivateStatePermissionsUnsupported;
    }
}

fn openSessionDir(
    sessions: *io_mod.VerifiedDir,
    session_id: []const u8,
    mode: OpenMode,
) !io_mod.VerifiedDir {
    try session_layout.validateSessionId(session_id);
    var dir = sessions.dir.openDir(io_mod.getIo(), session_id, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
        else => return err,
    };
    errdefer dir.close(io_mod.getIo());
    if (mode == .writable) {
        dir.setPermissions(io_mod.getIo(), private_dir_permissions) catch
            return error.PrivateStatePermissionsUnsupported;
    }
    try verifyPrivateDir(dir, mode);
    return .{ .dir = dir };
}

/// Opens an existing session file without waiting on a special file such as
/// a FIFO; non-regular, hard-linked, or linked targets are unsafe.
fn openManagedFile(
    dir: *io_mod.VerifiedDir,
    name: []const u8,
    mode: std.Io.Dir.OpenFileOptions.Mode,
) !std.Io.File {
    try validateLeaf(name);
    var file = io_mod.openExistingRegularFile(dir.dir, name, mode) catch |err| switch (err) {
        error.DurablePathUnsafe, error.IsDir, error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
        else => return err,
    };
    errdefer file.close(io_mod.getIo());
    try verifyManagedFile(file, if (mode == .read_only) .read_only else .writable);
    return file;
}

fn readManagedFileAlloc(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    name: []const u8,
    max_bytes: usize,
) ![]u8 {
    var file = try openManagedFile(dir, name, .read_only);
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, max_bytes + 1) catch |err| switch (err) {
        error.StreamTooLong => error.InvalidSessionFormat,
        else => err,
    };
}

test "root init rejects symlinked durable and sessions roots" {
    const alloc = std.testing.allocator;

    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(io_mod.getIo(), "home");
        try tmp.dir.createDirPath(io_mod.getIo(), "outside");
        tmp.dir.symLink(
            io_mod.getIo(),
            "../outside",
            "home/.fx",
            .{ .is_directory = true },
        ) catch |err| switch (err) {
            error.AccessDenied => return error.SkipZigTest,
            else => return err,
        };
        const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
        defer alloc.free(home);

        try std.testing.expectError(
            error.SessionPathUnsafe,
            Root.initFromHome(alloc, home, .writable),
        );
    }

    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
        try tmp.dir.createDirPath(io_mod.getIo(), "outside");
        tmp.dir.symLink(
            io_mod.getIo(),
            "../../outside",
            "home/.fx/sessions",
            .{ .is_directory = true },
        ) catch |err| switch (err) {
            error.AccessDenied => return error.SkipZigTest,
            else => return err,
        };
        const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
        defer alloc.free(home);

        try std.testing.expectError(
            error.SessionPathUnsafe,
            Root.initFromHome(alloc, home, .writable),
        );
    }
}

test "legacy import file projection cleans up allocation failures" {
    const Check = struct {
        fn run(alloc: Allocator) !void {
            const files = [_]types.FileEvidence{
                .{ .path = @constCast(""), .new_path = @constCast("unusable.txt"), .tool_call_id = @constCast("old-call"), .tool_name = @constCast("read_file") },
                .{ .path = @constCast("retained.txt"), .tool_call_id = @constCast("old-call"), .tool_name = @constCast("read_file") },
            };
            var history = [_]session.HistoryTurn{.{ .assistant = .{
                .user = .{ .text = @constCast("request") },
                .assistant = @constCast("response"),
                .execution = .{ .files = try types.dupeFileEvidenceSlice(alloc, &files) },
            } }};
            defer types.freeFileEvidenceSlice(alloc, history[0].assistant.execution.files);
            try std.testing.expectEqual(@as(usize, 1), try discardEmptyLegacyFileEvidence(alloc, &history));
            try std.testing.expectEqualStrings("retained.txt", history[0].assistant.execution.files[0].path);
        }
    };
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, Check.run, .{});
}

test "legacy steering prefix records retain their original boundary" {
    const alloc = std.testing.allocator;
    for ([_]u8{ 1, 2 }) |schema_version| {
        const bytes = try alloc.print(
            "{{\"schema_version\":{d},\"seq\":2,\"timestamp_ms\":10,\"event\":{{\"assistant\":{{\"text\":\"legacy prefix\"}}}}}}\n",
            .{schema_version},
        );
        defer alloc.free(bytes);
        var decoded = try session_event.decodeConversationFrame(alloc, bytes);
        defer decoded.deinit();
        var progress: ConversationProgress = .{};
        try progress.observe(1, .{ .user = .{ .text = "request" } }, null);
        try progress.observe(2, decoded.value.event, null);
        try progress.observe(3, .{ .steering = .{ .text = "human update" } }, null);
        try std.testing.expectEqual(@as(usize, 0), progress.point.tool_steps);
        try std.testing.expectEqual(@as(usize, 1), progress.point.steering);
        var builder = ConversationTurnBuilder.init(alloc);
        defer builder.deinit();
        try builder.begin(.{ .text = "request" });
        try builder.appendAssistant(decoded.value.event.assistant);
        try builder.appendSteering("human update");
        const execution = try builder.takeExecution(&.{}, null);
        defer types.freeExecutionMemory(alloc, execution);
        try std.testing.expectEqual(@as(usize, 0), execution.tool_steps.len);
        try std.testing.expectEqual(@as(usize, 1), execution.steering.len);
        try std.testing.expectEqual(@as(usize, 0), execution.steering[0].after_tool_step_count);
        try std.testing.expectEqualStrings("legacy prefix", execution.steering[0].assistant_prefix.?);
    }
}

test "takeExecution frees provider replay on allocation failure" {
    for ([_]bool{ false, true }) |standalone_response| try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, struct {
        fn run(alloc: Allocator, standalone: bool) !void {
            var builder = ConversationTurnBuilder.init(alloc);
            defer builder.deinit();
            try builder.begin(.{ .text = "request" });
            try builder.appendAssistant(.{
                .text = "earlier reply",
                .standalone_response = standalone,
                .provider_replay = .{
                    .source = .{ .provider = .gateway, .model = "test-model" },
                    .parts_json = "[{\"type\":\"reasoning\",\"text\":\"private state\"}]",
                },
            });
            try builder.appendSteering("human update");
            const execution = try builder.takeExecution(&.{.{
                .path = @constCast("result.txt"),
                .tool_call_id = @constCast("call-1"),
                .tool_name = @constCast("read_file"),
            }}, null);
            defer types.freeExecutionMemory(alloc, execution);
            try std.testing.expectEqual(@as(usize, 1), execution.tool_steps.len);
            try std.testing.expect(execution.tool_steps[0].provider_replay != null);
            try std.testing.expectEqual(@as(usize, 1), execution.steering.len);
            try std.testing.expectEqual(@as(usize, 1), execution.files.len);
        }
    }.run, .{standalone_response});
}
