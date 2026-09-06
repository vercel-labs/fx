const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const model_provider = @import("../config/model_provider.zig");
const session = @import("session.zig");
const session_child_store = @import("session_child_store.zig");
const session_codec = @import("session_codec.zig");
const types = @import("../shared/types.zig");
const session_event = @import("session_event.zig");
const session_layout = @import("session_layout.zig");
const session_replay = @import("session_replay.zig");
const session_display_metadata = @import("session_display_metadata.zig");
const result_store = @import("result_store.zig");
const session_usage = @import("session_usage.zig");
const session_usage_sidecar = @import("session_usage_sidecar.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");

const Allocator = std.mem.Allocator;
const Identifier = session_event.Identifier;
const private_dir_permissions = std.Io.File.Permissions.fromMode(0o700);
const private_file_permissions = std.Io.File.Permissions.fromMode(0o600);
const lock_deadline_ms: u64 = 2000;
const events_file = "events.jsonl";
const authority_file = "authority.json";
const authority_intent_file = "authority.pending.json";
const publication_intent_file = "commit.pending.json";
const manifest_file = "session.json";
const permission_state_file = "permissions.json";
const recovery_checkpoint_file = "recovery.json";
const conversation_migration_temp_file = "events.v4.tmp";
const conversation_migration_backup_file = "events.v3.backup";
const checkpoint_file = "checkpoint.json";
const session_lock_file = "session.lock";
const commit_lock_file = "commit.lock";

const ConversationProgress = struct {
    point: types.ContextHistoryCut = .{},
    pending: usize = 0,
    coverage: u64 = 0,
    reached: bool = false,
    pending_assistant: ?struct { seq: u64, has_replay: bool } = null,

    fn observe(self: *ConversationProgress, seq: u64, event: session_event.ConversationEvent, cut: ?types.ContextHistoryCut) !void {
        if (self.pending_assistant) |assistant| {
            const standalone = switch (event) {
                .assistant, .context_checkpoint, .interrupted => true,
                .steering => assistant.has_replay,
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

pub const ConversationWriter = struct {
    alloc: Allocator,
    file: std.Io.File,
    committed_bytes: u64 = 0,
    last_seq: u64 = 0,
    latest_checkpoint_coverage: u64 = 0,
    turn_open: bool = false,
    pending_tool_calls: std.ArrayList(session_event.PendingToolCall) = .empty,

    /// Takes ownership of `file` only on success.
    pub fn init(alloc: Allocator, file: std.Io.File) !ConversationWriter {
        var writer = ConversationWriter{ .alloc = alloc, .file = file };
        errdefer {
            writer.clearPendingToolCalls();
            writer.pending_tool_calls.deinit(alloc);
        }
        try writer.replayCommitted();
        return writer;
    }

    /// Rebuilds the in-memory view from the file, discarding an unfinished
    /// turn the way a fresh open does. On failure the writer no longer
    /// describes the file and must not be appended to.
    fn replayCommitted(writer: *ConversationWriter) !void {
        const alloc = writer.alloc;
        const file = writer.file;
        const length = try file.length(io_mod.getIo());
        writer.clearPendingToolCalls();
        writer.committed_bytes = 0;
        writer.last_seq = 0;
        writer.latest_checkpoint_coverage = 0;
        writer.turn_open = false;
        var offset: u64 = 0;
        var open_turn_offset: ?u64 = null;
        var open_turn_prior_seq: u64 = 0;
        var checkpointed_turn = false;
        while (offset < length) {
            const line = session_replay.readLineAt(alloc, file, offset, length) catch |err| switch (err) {
                error.TruncatedEventFrame => {
                    try file.setLength(io_mod.getIo(), offset);
                    try file.sync(io_mod.getIo());
                    writer.committed_bytes = offset;
                    break;
                },
                else => return err,
            } orelse break;
            defer alloc.free(line.bytes);
            var decoded = try session_event.decodeConversationFrame(alloc, line.bytes);
            defer decoded.deinit();
            try session_event.validateConversationTransition(.{
                .last_seq = writer.last_seq,
                .latest_checkpoint_coverage = writer.latest_checkpoint_coverage,
                .pending_tool_calls = writer.pending_tool_calls.items,
            }, decoded.value);
            switch (decoded.value.event) {
                .user => {
                    if (open_turn_offset != null) return error.InvalidConversationFrame;
                    open_turn_offset = offset;
                    open_turn_prior_seq = writer.last_seq;
                },
                .turn_completed, .interrupted => {
                    if (open_turn_offset == null) return error.InvalidConversationFrame;
                    open_turn_offset = null;
                    checkpointed_turn = false;
                },
                .context_checkpoint => if (open_turn_offset != null) {
                    open_turn_offset = line.next_offset;
                    open_turn_prior_seq = decoded.value.seq;
                    checkpointed_turn = true;
                },
                .assistant, .tool_call, .tool_result, .steering => if (open_turn_offset == null) {
                    return error.InvalidConversationFrame;
                },
            }
            try writer.applyReplayedEvent(decoded.value.seq, decoded.value.event);
            offset = line.next_offset;
            writer.committed_bytes = offset;
        }
        if (open_turn_offset) |truncate_from| {
            debug_trace.logf(
                "session",
                "event=conversation_unfinished_turn_discarded offset={d} bytes={d}",
                .{ truncate_from, writer.committed_bytes - truncate_from },
            );
            try file.setLength(io_mod.getIo(), truncate_from);
            try file.sync(io_mod.getIo());
            writer.clearPendingToolCalls();
            writer.committed_bytes = truncate_from;
            writer.last_seq = open_turn_prior_seq;
            writer.turn_open = checkpointed_turn;
        }
    }

    pub fn deinit(self: *ConversationWriter) void {
        for (self.pending_tool_calls.items) |pending| {
            self.alloc.free(@constCast(pending.call_id));
            self.alloc.free(@constCast(pending.tool_name));
        }
        self.pending_tool_calls.deinit(self.alloc);
        self.file.close(io_mod.getIo());
        self.* = undefined;
    }

    pub fn append(
        self: *ConversationWriter,
        alloc: Allocator,
        timestamp_ms: i64,
        event: session_event.ConversationEvent,
    ) !u64 {
        const seq = std.math.add(u64, self.last_seq, 1) catch
            return error.ConversationSequenceOverflow;
        const envelope = session_event.ConversationEnvelope{
            .seq = seq,
            .timestamp_ms = timestamp_ms,
            .event = event,
        };
        try session_event.validateConversationTransition(.{
            .last_seq = self.last_seq,
            .latest_checkpoint_coverage = self.latest_checkpoint_coverage,
            .pending_tool_calls = self.pending_tool_calls.items,
        }, envelope);
        const turn_open = try nextConversationTurnOpen(self.turn_open, event);

        var owned_pending: ?session_event.PendingToolCall = null;
        errdefer if (owned_pending) |pending| {
            self.alloc.free(@constCast(pending.call_id));
            self.alloc.free(@constCast(pending.tool_name));
        };
        const completed_index: ?usize = switch (event) {
            .tool_call => |call| blk: {
                try self.pending_tool_calls.ensureUnusedCapacity(self.alloc, 1);
                const call_id = try self.alloc.dupe(u8, call.call_id);
                errdefer self.alloc.free(call_id);
                const tool_name = try self.alloc.dupe(u8, call.tool_name);
                owned_pending = .{
                    .call_id = call_id,
                    .tool_name = tool_name,
                    .seq = seq,
                };
                break :blk null;
            },
            .tool_result => |result| self.pendingIndex(result.call_id),
            else => null,
        };

        const frame = try session_event.encodeConversationFrame(alloc, envelope);
        defer alloc.free(frame);
        if (try self.file.length(io_mod.getIo()) != self.committed_bytes) {
            try self.file.setLength(io_mod.getIo(), self.committed_bytes);
            try self.file.sync(io_mod.getIo());
        }
        try self.file.writePositionalAll(io_mod.getIo(), frame, self.committed_bytes);
        try self.file.sync(io_mod.getIo());
        self.committed_bytes = std.math.add(u64, self.committed_bytes, frame.len) catch
            return error.ConversationSizeOverflow;
        self.last_seq = seq;
        self.turn_open = turn_open;

        if (owned_pending) |pending| {
            self.pending_tool_calls.appendAssumeCapacity(pending);
            owned_pending = null;
        }
        if (completed_index) |index| {
            const completed = self.pending_tool_calls.orderedRemove(index);
            self.alloc.free(@constCast(completed.call_id));
            self.alloc.free(@constCast(completed.tool_name));
        }
        if (event == .interrupted) self.clearPendingToolCalls();
        if (event == .context_checkpoint) {
            self.latest_checkpoint_coverage = event.context_checkpoint.covers_through_seq;
        }
        return seq;
    }

    pub fn pendingToolCallCount(self: *const ConversationWriter) usize {
        return self.pending_tool_calls.items.len;
    }

    pub fn appendHistoryTurn(
        self: *ConversationWriter,
        alloc: Allocator,
        timestamp_ms: i64,
        turn: types.HistoryTurn,
    ) !void {
        if (turn == .compacted_summary) {
            _ = try self.append(alloc, timestamp_ms, .{
                .context_checkpoint = .{
                    .covers_through_seq = self.last_seq,
                    .summary = turn.compacted_summary.summary,
                },
            });
            return;
        }

        try self.appendTurnBatch(alloc, timestamp_ms, turn, null);
    }

    fn appendContextCompaction(
        self: *ConversationWriter,
        alloc: Allocator,
        timestamp_ms: i64,
        summary: types.CompactedSummaryHistoryTurn,
        prefix: ?types.AssistantHistoryTurn,
        retained_from: ?types.ContextHistoryCut,
    ) !void {
        if (prefix) |entry| {
            if (entry.assistant.len != 0) return error.InvalidConversationEvent;
            try self.appendTurnBatchWithCut(alloc, timestamp_ms, .{ .assistant = entry }, summary.summary, retained_from);
        } else {
            const coverage = if (retained_from) |cut| try self.contextCoverage(alloc, cut, &.{}) else self.last_seq;
            _ = try self.append(alloc, timestamp_ms, .{ .context_checkpoint = .{
                .covers_through_seq = coverage,
                .summary = summary.summary,
            } });
        }
    }

    fn appendTurnBatch(
        self: *ConversationWriter,
        alloc: Allocator,
        timestamp_ms: i64,
        turn: types.HistoryTurn,
        checkpoint_summary: ?[]const u8,
    ) !void {
        return self.appendTurnBatchWithCut(alloc, timestamp_ms, turn, checkpoint_summary, null);
    }

    fn appendTurnBatchWithCut(
        self: *ConversationWriter,
        alloc: Allocator,
        timestamp_ms: i64,
        turn: types.HistoryTurn,
        checkpoint_summary: ?[]const u8,
        retained_from: ?types.ContextHistoryCut,
    ) !void {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        // A checkpoint can have already committed the recent execution prefix.
        // Finalization supplies that prefix for model history; append only its
        // not-yet-written suffix to the conversation log.
        const unwritten = if (self.turn_open) blk: {
            var progress: ConversationProgress = .{};
            try self.scanContext(alloc, &progress, null);
            const view = try session.contextHistoryRange(arena.allocator(), &.{turn}, .{
                .tool_steps = progress.point.tool_steps,
                .steering = progress.point.steering,
            }, null);
            if (view.len != 1) return error.InvalidConversationEvent;
            break :blk view[0];
        } else turn;
        var events: std.ArrayList(session_event.ConversationEvent) = .empty;
        defer events.deinit(alloc);
        try session_event.appendHistoryTurnConversationEvents(alloc, &events, unwritten);
        const start: usize = if (self.turn_open) 1 else 0;
        if (checkpoint_summary) |summary| {
            _ = events.pop();
            const covers_through_seq = if (retained_from) |cut|
                try self.contextCoverage(alloc, cut, events.items[start..])
            else
                std.math.add(u64, self.last_seq, events.items.len - start) catch
                    return error.ConversationSequenceOverflow;
            try events.append(alloc, .{ .context_checkpoint = .{
                .covers_through_seq = covers_through_seq,
                .summary = summary,
            } });
        }
        var projected_images: ?[]types.ImageAttachment = null;
        defer if (projected_images) |images| {
            types.freeImageAttachmentSlice(alloc, images);
        };
        for (events.items[start..]) |*event| switch (event.*) {
            .user => |*user| {
                if (user.images.len == 0) continue;
                const images = try types.dupeImageAttachmentSlice(alloc, user.images);
                projectConversationImageLocators(alloc, images) catch |err| {
                    types.freeImageAttachmentSlice(alloc, images);
                    return err;
                };
                user.images = images;
                projected_images = images;
            },
            else => {},
        };
        try self.appendBatch(alloc, timestamp_ms, events.items[start..]);
    }

    fn scanContext(self: *const ConversationWriter, alloc: Allocator, progress: *ConversationProgress, cut: ?types.ContextHistoryCut) !void {
        progress.coverage = self.latest_checkpoint_coverage;
        var offset: u64 = 0;
        while (offset < self.committed_bytes) {
            const line = try session_replay.readLineAt(alloc, self.file, offset, self.committed_bytes) orelse break;
            defer alloc.free(line.bytes);
            var decoded = try session_event.decodeConversationFrame(alloc, line.bytes);
            defer decoded.deinit();
            if (decoded.value.seq > self.latest_checkpoint_coverage) {
                try progress.observe(decoded.value.seq, decoded.value.event, cut);
            }
            offset = line.next_offset;
        }
    }

    fn contextCoverage(self: *const ConversationWriter, alloc: Allocator, cut: types.ContextHistoryCut, upcoming: []const session_event.ConversationEvent) !u64 {
        var progress: ConversationProgress = .{};
        try self.scanContext(alloc, &progress, cut);
        for (upcoming, 0..) |event, index| {
            const seq = std.math.add(u64, self.last_seq, index + 1) catch return error.ConversationSequenceOverflow;
            try progress.observe(seq, event, cut);
        }
        if (!progress.reached and !std.meta.eql(cut, types.ContextHistoryCut{})) return error.InvalidContextHistoryStart;
        return progress.coverage;
    }

    pub fn readAllForTest(self: *const ConversationWriter, alloc: Allocator) ![]u8 {
        const size = std.math.cast(usize, self.committed_bytes) orelse
            return error.ConversationTooLarge;
        const bytes = try alloc.alloc(u8, size);
        errdefer alloc.free(bytes);
        const count = try self.file.readPositionalAll(io_mod.getIo(), bytes, 0);
        if (count != size) return error.TruncatedConversation;
        return bytes;
    }

    fn pendingIndex(self: *const ConversationWriter, call_id: []const u8) ?usize {
        for (self.pending_tool_calls.items, 0..) |pending, index| {
            if (std.mem.eql(u8, pending.call_id, call_id)) return index;
        }
        return null;
    }

    fn appendBatch(
        self: *ConversationWriter,
        alloc: Allocator,
        timestamp_ms: i64,
        events: []const session_event.ConversationEvent,
    ) !void {
        if (events.len == 0) return;
        if (self.pending_tool_calls.items.len != 0) return error.UnresolvedToolCall;

        var pending: std.ArrayList(session_event.PendingToolCall) = .empty;
        defer pending.deinit(alloc);
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        var seq = self.last_seq;
        var checkpoint_coverage = self.latest_checkpoint_coverage;
        var turn_open = self.turn_open;
        for (events) |event| {
            seq = std.math.add(u64, seq, 1) catch
                return error.ConversationSequenceOverflow;
            const envelope = session_event.ConversationEnvelope{
                .seq = seq,
                .timestamp_ms = timestamp_ms,
                .event = event,
            };
            try session_event.validateConversationTransition(.{
                .last_seq = seq - 1,
                .latest_checkpoint_coverage = checkpoint_coverage,
                .pending_tool_calls = pending.items,
            }, envelope);
            turn_open = try nextConversationTurnOpen(turn_open, event);
            switch (event) {
                .tool_call => |call| try pending.append(alloc, .{
                    .call_id = call.call_id,
                    .tool_name = call.tool_name,
                    .seq = seq,
                }),
                .tool_result => |result| {
                    for (pending.items, 0..) |call, index| {
                        if (std.mem.eql(u8, call.call_id, result.call_id)) {
                            _ = pending.orderedRemove(index);
                            break;
                        }
                    }
                },
                .interrupted => pending.clearRetainingCapacity(),
                .context_checkpoint => |checkpoint| checkpoint_coverage =
                    checkpoint.covers_through_seq,
                else => {},
            }
            const frame = try session_event.encodeConversationFrame(alloc, envelope);
            defer alloc.free(frame);
            try out.writer.writeAll(frame);
        }
        if (pending.items.len != 0) return error.UnresolvedToolCall;
        if (try self.file.length(io_mod.getIo()) != self.committed_bytes) {
            try self.file.setLength(io_mod.getIo(), self.committed_bytes);
            try self.file.sync(io_mod.getIo());
        }
        try self.file.writePositionalAll(
            io_mod.getIo(),
            out.written(),
            self.committed_bytes,
        );
        try self.file.sync(io_mod.getIo());
        self.committed_bytes = std.math.add(
            u64,
            self.committed_bytes,
            out.written().len,
        ) catch return error.ConversationSizeOverflow;
        self.last_seq = seq;
        self.latest_checkpoint_coverage = checkpoint_coverage;
        self.turn_open = turn_open;
    }

    fn clearPendingToolCalls(self: *ConversationWriter) void {
        for (self.pending_tool_calls.items) |pending| {
            self.alloc.free(@constCast(pending.call_id));
            self.alloc.free(@constCast(pending.tool_name));
        }
        self.pending_tool_calls.clearRetainingCapacity();
    }

    fn applyReplayedEvent(
        self: *ConversationWriter,
        seq: u64,
        event: session_event.ConversationEvent,
    ) !void {
        const turn_open = try nextConversationTurnOpen(self.turn_open, event);
        switch (event) {
            .tool_call => |call| {
                const call_id = try self.alloc.dupe(u8, call.call_id);
                errdefer self.alloc.free(call_id);
                const tool_name = try self.alloc.dupe(u8, call.tool_name);
                errdefer self.alloc.free(tool_name);
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
    };
}

fn createConversationStorage(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    metadata: session_codec.SessionMetadata,
) !ConversationWriter {
    const metadata_bytes = try session_codec.encodeSessionMetadata(alloc, metadata);
    defer alloc.free(metadata_bytes);
    try io_mod.durableReplaceVerified(alloc, dir, manifest_file, metadata_bytes);
    errdefer {
        dir.dir.deleteFile(io_mod.getIo(), manifest_file) catch {};
        io_mod.syncVerifiedDir(dir.dir) catch {};
    }

    const file = createManagedFile(dir, events_file) catch |err| switch (err) {
        error.PathAlreadyExists => return error.SessionAlreadyExists,
        else => return err,
    };
    errdefer file.close(io_mod.getIo());
    return ConversationWriter.init(alloc, file);
}

fn writeConversationMetadata(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    state: session_codec.DurableSessionState,
) !void {
    const existing = readManagedFileAlloc(
        alloc,
        dir,
        manifest_file,
        session_codec.max_session_metadata_bytes,
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (existing) |bytes| alloc.free(bytes);
    var decoded = if (existing) |bytes|
        try session_codec.decodeSessionMetadata(alloc, bytes)
    else
        null;
    defer if (decoded) |*metadata| metadata.deinit();
    const bytes = try encodeConversationMetadataWithTitle(
        alloc,
        state,
        if (decoded) |metadata| metadata.value.title else null,
    );
    defer alloc.free(bytes);
    try io_mod.durableReplaceVerified(alloc, dir, manifest_file, bytes);
}

fn encodeConversationMetadata(
    alloc: Allocator,
    state: session_codec.DurableSessionState,
) ![]u8 {
    return encodeConversationMetadataWithTitle(alloc, state, null);
}

fn encodeConversationMetadataWithTitle(
    alloc: Allocator,
    state: session_codec.DurableSessionState,
    title: ?[]const u8,
) ![]u8 {
    return session_codec.encodeSessionMetadata(alloc, .{
        .id = state.id,
        .origin_workspace_root = state.origin_workspace_root,
        .workspace_root = state.workspace_root,
        .created_at_ms = state.created_at_ms,
        .updated_at_ms = state.updated_at_ms,
        .conversation_language = state.conversation_language.view(),
        .provider = @tagName(state.preferences.provider),
        .model = state.preferences.model,
        .effort = state.preferences.effort.label(),
        .fast_mode = state.preferences.fast_mode,
        .title = title,
        .subagent_child = state.subagent_child,
    });
}

fn writeConversationControlState(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    state: session_codec.DurableSessionState,
    conversation_seq: u64,
) !void {
    const permission_bytes = try session_codec.encodePermissionState(
        alloc,
        state.permission_state,
    );
    defer alloc.free(permission_bytes);
    try io_mod.durableReplaceVerified(
        alloc,
        dir,
        permission_state_file,
        permission_bytes,
    );
    if (state.usage) |usage| {
        try session_usage_sidecar.write(alloc, dir, state.id, usage);
    }
    try writeConversationRecoveryState(alloc, dir, state.recovery_checkpoint, conversation_seq);
}

fn writeConversationRecoveryState(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    recovery_checkpoint: ?session_codec.RecoveryCheckpoint,
    conversation_seq: u64,
) !void {
    if (recovery_checkpoint) |checkpoint| {
        const recovery_bytes = try session_codec.encodeRecoveryCheckpoint(
            alloc,
            checkpoint,
        );
        defer alloc.free(recovery_bytes);
        const bound_bytes = try std.fmt.allocPrint(
            alloc,
            "{{\"conversation_seq\":{d},\"checkpoint\":{s}}}\n",
            .{ conversation_seq, recovery_bytes },
        );
        defer alloc.free(bound_bytes);
        try io_mod.durableReplaceVerified(
            alloc,
            dir,
            recovery_checkpoint_file,
            bound_bytes,
        );
    } else {
        dir.dir.deleteFile(io_mod.getIo(), recovery_checkpoint_file) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        try io_mod.syncVerifiedDir(dir.dir);
    }
}

fn loadConversationPermissionState(
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

fn loadConversationRecoveryCheckpoint(
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
    var parsed = std.json.parseFromSlice(struct {
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
    var event_file = try openManagedFile(dir, events_file, .read_only);
    defer event_file.close(io_mod.getIo());
    var conversation_seq: u64 = 0;
    var open_work_id: ?[]u8 = null;
    defer if (open_work_id) |work_id| alloc.free(work_id);
    const length = if (recovery) |boundary| boundary.bytes else try event_file.length(io_mod.getIo());
    const history = try replayConversationHistory(alloc, event_file, length, &conversation_seq, &open_work_id);
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
    errdefer if (last_work_id) |work_id| alloc.free(work_id);
    var usage = try session_usage_sidecar.load(
        alloc,
        dir,
        expected_session_id,
    );
    errdefer if (usage) |*snapshot| snapshot.deinit(alloc);
    var permission_state = try loadConversationPermissionState(alloc, dir);
    errdefer permission_state.deinit(alloc);
    var recovery_checkpoint = if (recovery == null)
        try loadConversationRecoveryCheckpoint(alloc, dir, conversation_seq)
    else
        null;
    errdefer if (recovery_checkpoint) |*checkpoint| checkpoint.deinit(alloc);
    if (recovery_checkpoint) |*checkpoint| {
        if (checkpoint.user.work_id == null) {
            checkpoint.user.work_id = open_work_id;
            open_work_id = null;
        }
    }
    const id = try alloc.dupe(u8, metadata.value.id);
    errdefer alloc.free(id);
    const origin = try alloc.dupe(u8, metadata.value.origin_workspace_root);
    errdefer alloc.free(origin);
    const workspace = try alloc.dupe(u8, metadata.value.workspace_root);
    errdefer alloc.free(workspace);
    const model = try alloc.dupe(u8, metadata.value.model);
    errdefer alloc.free(model);
    const language = session.ConversationLanguage.fromSlice(
        metadata.value.conversation_language,
    ) catch return error.InvalidSessionMetadata;
    const provider = model_provider.parse(metadata.value.provider) orelse
        return error.InvalidSessionMetadata;
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
        },
        .history = history,
        .context_history_start = latestConversationCheckpointIndex(history),
        .total_input_tokens = 0,
        .total_output_tokens = 0,
        .permission_state = permission_state,
        .last_subagent_work_id = last_work_id,
        .usage = usage,
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

/// Reads only. The existing transition validator remains the record authority.
pub fn find_conversation_recovery_boundary(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
) !ConversationRecoveryBoundary {
    var reader = try ConversationHistoryReader.init(alloc, dir);
    defer reader.deinit();
    const file = reader.file;
    const length = reader.length;
    reader.length = 0;
    var state = ConversationWriter{ .alloc = alloc, .file = file };
    defer {
        state.clearPendingToolCalls();
        state.pending_tool_calls.deinit(alloc);
    }
    var boundary: ConversationRecoveryBoundary = .{};
    var offset: u64 = 0;
    var coverage_offset: u64 = 0;
    var coverage_seq: u64 = 0;
    var coverage_progress: ConversationProgress = .{};
    scan: while (offset < length) {
        const line = session_replay.readLineAt(alloc, file, offset, length) catch |err| switch (err) {
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
                const covered = (try session_replay.readLineAt(alloc, file, coverage_offset, offset)) orelse
                    return error.SessionRecoveryBoundaryInvalid;
                defer alloc.free(covered.bytes);
                var frame = try session_event.decodeConversationFrame(alloc, covered.bytes);
                defer frame.deinit();
                try coverage_progress.observe(frame.value.seq, frame.value.event, null);
                coverage_seq = frame.value.seq;
                coverage_offset = covered.next_offset;
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
    if (offset == length and boundary.bytes == length) return error.SessionRecoveryNotNeeded;
    if (boundary.bytes == 0) return error.SessionRecoveryBoundaryInvalid;
    debug_trace.logf("session", "event=conversation_recovery_boundary source_bytes={d} retained_bytes={d} through_seq={d}", .{ length, boundary.bytes, boundary.seq });
    return boundary;
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

/// Installs exact validated records in an unpublished target; never edits source.
pub fn copy_conversation_recovery_prefix(
    alloc: Allocator,
    source: *io_mod.VerifiedDir,
    target: *io_mod.VerifiedDir,
    boundary: ConversationRecoveryBoundary,
) !void {
    const input = try openManagedFile(source, events_file, .read_only);
    defer input.close(io_mod.getIo());
    const output = try openManagedFile(target, events_file, .read_write);
    defer output.close(io_mod.getIo());
    var buffer: [8192]u8 = undefined;
    var offset: u64 = 0;
    while (offset < boundary.bytes) {
        const count: usize = @intCast(@min(buffer.len, boundary.bytes - offset));
        if (try input.readPositionalAll(io_mod.getIo(), buffer[0..count], offset) != count)
            return error.SessionRecoveryBoundaryInvalid;
        try output.writePositionalAll(io_mod.getIo(), buffer[0..count], offset);
        offset += count;
    }
    if (boundary.turn_open) {
        const interrupted = try session_event.encodeConversationFrame(alloc, .{
            .seq = try std.math.add(u64, boundary.seq, 1),
            .timestamp_ms = boundary.timestamp_ms,
            .event = .{ .interrupted = .{ .reason = .failed } },
        });
        defer alloc.free(interrupted);
        try output.writePositionalAll(io_mod.getIo(), interrupted, offset);
        offset = try std.math.add(u64, offset, interrupted.len);
    }
    try output.setLength(io_mod.getIo(), offset);
    try output.sync(io_mod.getIo());
    debug_trace.logf("session", "event=conversation_recovery_prefix bytes={d} through_seq={d} interrupted={}", .{ boundary.bytes, boundary.seq, boundary.turn_open });
}

/// Where to cut a conversation log, in the turn numbering of the surface
/// that asked for it.
pub const ConversationCut = union(enum) {
    /// Turns as `loadConversationArchive` numbers them: every completed or
    /// interrupted turn and every compaction summary, in log order. This is
    /// what `fx session <id>` labels.
    archive_turns: usize,
    /// Turns as a resumed session holds them: the latest compaction summary,
    /// if any, followed by the turns replayed after it.
    window_turns: usize,
    /// The whole committed log.
    everything,
};

pub const ConversationTruncation = struct {
    boundary: ConversationRecoveryBoundary,
    /// Turns left after the cut, counted the way the cut was. This can exceed
    /// the request by one when a turn was open at a compaction checkpoint,
    /// because the cut closes that turn as interrupted, and by more when the
    /// requested window ends before the checkpoint record that summarizes it,
    /// because the summary cannot outlive its record.
    retained_turns: usize,
    /// Turns of the current log that the cut removes.
    dropped_turns: usize,
    /// Turns the current log holds, counted the way the cut was.
    total_turns: usize,
};

pub fn planConversationCut(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    cut: ConversationCut,
) !ConversationTruncation {
    const file = try openManagedFile(dir, events_file, .read_only);
    defer file.close(io_mod.getIo());
    return planConversationTruncation(alloc, file, try file.length(io_mod.getIo()), cut);
}

/// Reads only. Fails with `error.SessionTurnOutOfRange` when the cut asks
/// for more turns than the log holds.
pub fn planConversationTruncation(
    alloc: Allocator,
    file: std.Io.File,
    length: u64,
    cut: ConversationCut,
) !ConversationTruncation {
    const window: ?ConversationReplayWindow = switch (cut) {
        .window_turns => try findConversationReplayWindow(alloc, file, length),
        .archive_turns, .everything => null,
    };
    const counted_from: u64 = if (window) |value| value.offset else 0;
    const checkpoint_offset: ?u64 = if (window) |value| value.checkpoint_offset else null;
    const summary_turns: usize = if (checkpoint_offset != null) 1 else 0;

    const requested_count: ?usize = switch (cut) {
        inline .archive_turns, .window_turns => |count| count,
        .everything => null,
    };
    var total: usize = summary_turns;
    var boundary: ?ConversationRecoveryBoundary = null;
    var end: ConversationRecoveryBoundary = .{};
    var checkpoint_boundary: ?ConversationRecoveryBoundary = null;
    var turns_before_checkpoint: usize = 0;
    var turn_open = false;
    var offset: u64 = 0;
    while (offset < length) {
        const line = session_replay.readLineAt(alloc, file, offset, length) catch |err| switch (err) {
            error.TruncatedEventFrame => break,
            else => return err,
        } orelse break;
        defer alloc.free(line.bytes);
        var decoded = try session_event.decodeConversationFrame(alloc, line.bytes);
        defer decoded.deinit();
        const event = decoded.value.event;
        turn_open = try nextConversationTurnOpen(turn_open, event);
        end = .{
            .bytes = line.next_offset,
            .seq = decoded.value.seq,
            .timestamp_ms = decoded.value.timestamp_ms,
            .turn_open = turn_open,
        };
        if (checkpoint_offset != null and offset == checkpoint_offset.?) {
            checkpoint_boundary = end;
            turns_before_checkpoint = total - summary_turns;
        }
        const completes = switch (cut) {
            .archive_turns, .everything => switch (event) {
                .turn_completed, .interrupted, .context_checkpoint => true,
                .user, .assistant, .tool_call, .tool_result, .steering => false,
            },
            .window_turns => switch (event) {
                .turn_completed, .interrupted => offset >= counted_from,
                .user, .assistant, .tool_call, .tool_result, .steering, .context_checkpoint => false,
            },
        };
        if (completes) {
            total += 1;
            if (boundary == null and requested_count == total) boundary = end;
        }
        offset = line.next_offset;
    }

    const requested = requested_count orelse total;
    if (requested > total) return error.SessionTurnOutOfRange;
    var chosen: ConversationRecoveryBoundary = undefined;
    var retained: usize = undefined;
    if (cut == .everything) {
        chosen = end;
        retained = total;
    } else if (requested == 0) {
        chosen = .{};
        retained = 0;
    } else if (boundary) |found| {
        chosen = found;
        retained = requested;
    } else {
        // Only the summary was requested, so no completion set the boundary.
        std.debug.assert(requested == summary_turns);
        chosen = checkpoint_boundary.?;
        retained = summary_turns + turns_before_checkpoint;
    }
    // A kept summary needs its checkpoint record, and every turn before that
    // record stays with it.
    if (checkpoint_boundary) |record| {
        if (retained > 0 and chosen.bytes < record.bytes) {
            chosen = record;
            retained = summary_turns + turns_before_checkpoint;
        }
    }
    const dropped = total - retained;
    if (dropped > 0 and chosen.turn_open) retained += 1;
    return .{
        .boundary = chosen,
        .retained_turns = retained,
        .dropped_turns = dropped,
        .total_turns = total,
    };
}

test "conversation cut plans count archive turns and close a checkpointed open turn" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = io_mod.VerifiedDir{ .dir = tmp.dir };
    const first =
        "{\"schema_version\":1,\"seq\":1,\"timestamp_ms\":1,\"event\":{\"user\":{\"text\":\"one\"}}}\n" ++
        "{\"schema_version\":1,\"seq\":2,\"timestamp_ms\":1,\"event\":{\"assistant\":{\"text\":\"first\"}}}\n" ++
        "{\"schema_version\":1,\"seq\":3,\"timestamp_ms\":1,\"event\":{\"turn_completed\":{}}}\n";
    const second_open =
        "{\"schema_version\":1,\"seq\":4,\"timestamp_ms\":2,\"event\":{\"user\":{\"text\":\"two\"}}}\n" ++
        "{\"schema_version\":1,\"seq\":5,\"timestamp_ms\":2,\"event\":{\"assistant\":{\"text\":\"partial\"}}}\n";
    const checkpoint =
        "{\"schema_version\":1,\"seq\":6,\"timestamp_ms\":3,\"event\":{\"context_checkpoint\":{\"covers_through_seq\":3,\"summary\":\"summary\"}}}\n";
    const second_close =
        "{\"schema_version\":1,\"seq\":7,\"timestamp_ms\":4,\"event\":{\"assistant\":{\"text\":\"rest\"}}}\n" ++
        "{\"schema_version\":1,\"seq\":8,\"timestamp_ms\":4,\"event\":{\"turn_completed\":{}}}\n";
    const bytes = first ++ second_open ++ checkpoint ++ second_close;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = events_file, .data = bytes, .flags = .{ .permissions = private_file_permissions } });

    // Archive order: turn one, the summary, then turn two.
    const whole = try planConversationCut(alloc, &dir, .{ .archive_turns = 3 });
    try std.testing.expectEqual(@as(usize, 3), whole.total_turns);
    try std.testing.expectEqual(@as(usize, 0), whole.dropped_turns);
    try std.testing.expectEqual(bytes.len, whole.boundary.bytes);

    const one = try planConversationCut(alloc, &dir, .{ .archive_turns = 1 });
    try std.testing.expectEqual(first.len, one.boundary.bytes);
    try std.testing.expectEqual(@as(u64, 3), one.boundary.seq);
    try std.testing.expect(!one.boundary.turn_open);
    try std.testing.expectEqual(@as(usize, 1), one.retained_turns);
    try std.testing.expectEqual(@as(usize, 2), one.dropped_turns);

    // Keeping the summary cuts inside turn two, which the cut then closes.
    const at_summary = try planConversationCut(alloc, &dir, .{ .archive_turns = 2 });
    try std.testing.expectEqual(first.len + second_open.len + checkpoint.len, at_summary.boundary.bytes);
    try std.testing.expect(at_summary.boundary.turn_open);
    try std.testing.expectEqual(@as(usize, 3), at_summary.retained_turns);
    try std.testing.expectEqual(@as(usize, 1), at_summary.dropped_turns);

    const empty = try planConversationCut(alloc, &dir, .{ .archive_turns = 0 });
    try std.testing.expectEqual(@as(u64, 0), empty.boundary.bytes);
    try std.testing.expectEqual(@as(usize, 3), empty.dropped_turns);

    try std.testing.expectError(error.SessionTurnOutOfRange, planConversationCut(alloc, &dir, .{ .archive_turns = 4 }));

    const everything = try planConversationCut(alloc, &dir, .everything);
    try std.testing.expectEqual(bytes.len, everything.boundary.bytes);
    try std.testing.expectEqual(@as(usize, 0), everything.dropped_turns);
}

test "conversation cut plans count window turns and keep the checkpoint record" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = io_mod.VerifiedDir{ .dir = tmp.dir };
    const covered =
        "{\"schema_version\":1,\"seq\":1,\"timestamp_ms\":1,\"event\":{\"user\":{\"text\":\"one\"}}}\n" ++
        "{\"schema_version\":1,\"seq\":2,\"timestamp_ms\":1,\"event\":{\"assistant\":{\"text\":\"first\"}}}\n" ++
        "{\"schema_version\":1,\"seq\":3,\"timestamp_ms\":1,\"event\":{\"turn_completed\":{}}}\n";
    const kept_verbatim =
        "{\"schema_version\":1,\"seq\":4,\"timestamp_ms\":2,\"event\":{\"user\":{\"text\":\"two\"}}}\n" ++
        "{\"schema_version\":1,\"seq\":5,\"timestamp_ms\":2,\"event\":{\"assistant\":{\"text\":\"second\"}}}\n" ++
        "{\"schema_version\":1,\"seq\":6,\"timestamp_ms\":2,\"event\":{\"turn_completed\":{}}}\n";
    const checkpoint =
        "{\"schema_version\":1,\"seq\":7,\"timestamp_ms\":3,\"event\":{\"context_checkpoint\":{\"covers_through_seq\":3,\"summary\":\"summary\"}}}\n";
    const after =
        "{\"schema_version\":1,\"seq\":8,\"timestamp_ms\":4,\"event\":{\"user\":{\"text\":\"three\"}}}\n" ++
        "{\"schema_version\":1,\"seq\":9,\"timestamp_ms\":4,\"event\":{\"assistant\":{\"text\":\"third\"}}}\n" ++
        "{\"schema_version\":1,\"seq\":10,\"timestamp_ms\":4,\"event\":{\"turn_completed\":{}}}\n";
    const bytes = covered ++ kept_verbatim ++ checkpoint ++ after;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = events_file, .data = bytes, .flags = .{ .permissions = private_file_permissions } });

    // A resumed session holds the summary, turn two, then turn three.
    const whole = try planConversationCut(alloc, &dir, .{ .window_turns = 3 });
    try std.testing.expectEqual(@as(usize, 3), whole.total_turns);
    try std.testing.expectEqual(@as(usize, 0), whole.dropped_turns);

    const two = try planConversationCut(alloc, &dir, .{ .window_turns = 2 });
    try std.testing.expectEqual(covered.len + kept_verbatim.len + checkpoint.len, two.boundary.bytes);
    try std.testing.expectEqual(@as(usize, 2), two.retained_turns);
    try std.testing.expectEqual(@as(usize, 1), two.dropped_turns);

    // Turn two precedes the checkpoint record, so the summary cannot be kept
    // without it.
    const summary_only = try planConversationCut(alloc, &dir, .{ .window_turns = 1 });
    try std.testing.expectEqual(two.boundary.bytes, summary_only.boundary.bytes);
    try std.testing.expectEqual(@as(usize, 2), summary_only.retained_turns);
    try std.testing.expectEqual(@as(usize, 1), summary_only.dropped_turns);

    const empty = try planConversationCut(alloc, &dir, .{ .window_turns = 0 });
    try std.testing.expectEqual(@as(u64, 0), empty.boundary.bytes);
    try std.testing.expectEqual(@as(usize, 3), empty.dropped_turns);

    try std.testing.expectError(error.SessionTurnOutOfRange, planConversationCut(alloc, &dir, .{ .window_turns = 4 }));

    // Without a checkpoint the window is the archive.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = events_file, .data = covered ++ kept_verbatim, .flags = .{ .permissions = private_file_permissions } });
    const plain = try planConversationCut(alloc, &dir, .{ .window_turns = 1 });
    try std.testing.expectEqual(covered.len, plain.boundary.bytes);
    try std.testing.expectEqual(@as(usize, 1), plain.retained_turns);
    try std.testing.expectEqual(@as(usize, 2), plain.total_turns);
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
            const bytes = try std.fmt.allocPrint(alloc, "{s}{{\"schema_version\":1,\"seq\":7,\"timestamp_ms\":1,\"event\":{{\"context_checkpoint\":{{\"covers_through_seq\":{d},\"summary\":\"checkpoint\"}}}}}}\n{s}", .{ prefix, coverage, tail });
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
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
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
    try std.testing.checkAllAllocationFailures(alloc, struct {
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

fn openConversationWritableSession(
    alloc: Allocator,
    writable: *WritableSessionDir,
) !LoadedWritableSession {
    var event_file = try openManagedFile(&writable.dir, events_file, .read_write);
    var conversation_writer = ConversationWriter.init(alloc, event_file) catch |err| {
        event_file.close(io_mod.getIo());
        return err;
    };
    errdefer conversation_writer.deinit();
    if (conversation_writer.turn_open) {
        var recovery = try loadConversationRecoveryCheckpoint(
            alloc,
            &writable.dir,
            conversation_writer.last_seq,
        );
        defer if (recovery) |*checkpoint| checkpoint.deinit(alloc);
        if (recovery == null) {
            _ = try conversation_writer.append(alloc, io_mod.milliTimestamp(), .{
                .interrupted = .{ .reason = .failed },
            });
        }
    }
    var state = (try loadConversationStateIfPresent(
        alloc,
        &writable.dir,
        writable.session_id,
    )) orelse return error.InvalidSessionMetadata;
    errdefer state.deinit(alloc);
    const active_id = try alloc.dupe(u8, writable.session_id);
    errdefer alloc.free(active_id);
    const generation = randomIdentifier();
    const position = CommitPosition{
        .log_generation = generation,
        .through_seq = conversation_writer.last_seq,
        .through_event_id = randomIdentifier(),
        .through_event_log_bytes = conversation_writer.committed_bytes,
    };
    const result = LoadedWritableSession{
        .active_id = active_id,
        .state = state,
        .conversation_writer = conversation_writer,
        .log = writable.*,
        .position = position,
    };
    writable.* = undefined;
    return result;
}

fn replayConversationHistory(
    alloc: Allocator,
    file: std.Io.File,
    length: u64,
    conversation_seq: *u64,
    open_work_id: *?[]u8,
) ![]session.HistoryTurn {
    const window = try findConversationReplayWindow(alloc, file, length);
    conversation_seq.* = window.last_complete_seq;
    var offset = window.offset;
    var history: std.ArrayList(session.HistoryTurn) = .empty;
    errdefer {
        for (history.items) |turn| session.freeHistoryTurn(alloc, turn);
        history.deinit(alloc);
    }
    var turn = ConversationTurnBuilder.init(alloc);
    defer turn.deinit();
    if (window.checkpoint_offset) |checkpoint_offset| {
        const line = try session_replay.readLineAt(alloc, file, checkpoint_offset, length) orelse return error.InvalidConversationFrame;
        defer alloc.free(line.bytes);
        var decoded = try session_event.decodeConversationFrame(alloc, line.bytes);
        defer decoded.deinit();
        const summary = try alloc.dupe(u8, decoded.value.event.context_checkpoint.summary);
        errdefer alloc.free(summary);
        try history.append(alloc, .{ .compacted_summary = .{
            .summary = summary,
            .removed_turn_count = window.prior_turn_count,
            .compaction_count = window.compaction_count,
            .root_user_messages_complete = false,
            .permission_feedback_complete = false,
        } });
    }
    if (window.active_user_offset) |user_offset| {
        const line = try session_replay.readLineAt(alloc, file, user_offset, length) orelse
            return error.InvalidConversationFrame;
        defer alloc.free(line.bytes);
        var decoded = try session_event.decodeConversationFrame(alloc, line.bytes);
        defer decoded.deinit();
        if (decoded.value.event != .user) return error.InvalidConversationFrame;
        try turn.begin(decoded.value.event.user);
    }
    var checkpoint_turn_open = window.active_user_offset != null;

    while (offset < length) {
        const line = session_replay.readLineAt(alloc, file, offset, length) catch |err| switch (err) {
            error.TruncatedEventFrame => break,
            else => return err,
        } orelse break;
        defer alloc.free(line.bytes);
        var decoded = try session_event.decodeConversationFrame(alloc, line.bytes);
        defer decoded.deinit();
        switch (decoded.value.event) {
            .user => |value| try turn.begin(value),
            .assistant => |value| try turn.appendAssistant(value),
            .tool_call => |value| try turn.appendToolCall(value),
            .tool_result => |value| try turn.appendToolResult(value),
            .steering => |value| try turn.appendSteering(value.text),
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
        offset = line.next_offset;
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
pub const ConversationHistoryReader = struct {
    alloc: Allocator,
    file: std.Io.File,
    length: u64,
    offset: u64 = 0,
    builder: ConversationTurnBuilder,

    pub fn init(alloc: Allocator, dir: *io_mod.VerifiedDir) !ConversationHistoryReader {
        var file = try openManagedFile(dir, events_file, .read_only);
        errdefer file.close(io_mod.getIo());
        return .{
            .alloc = alloc,
            .file = file,
            .length = try file.length(io_mod.getIo()),
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
            const line = session_replay.readLineAt(self.alloc, self.file, self.offset, self.length) catch |err| switch (err) {
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

pub fn loadConversationHistoryRange(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    start: usize,
    end: usize,
) ![]session.HistoryTurn {
    if (start > end) return error.InvalidHistoryPageCursor;
    var reader = try ConversationHistoryReader.init(alloc, dir);
    defer reader.deinit();
    var turns: std.ArrayList(session.HistoryTurn) = .empty;
    errdefer {
        for (turns.items) |turn| session.freeHistoryTurn(alloc, turn);
        turns.deinit(alloc);
    }
    var turn_index: usize = 0;
    while (turn_index < end) : (turn_index += 1) {
        const turn = (try reader.next()) orelse break;
        if (turn_index >= start) {
            errdefer session.freeHistoryTurn(alloc, turn);
            try turns.append(alloc, turn);
        } else {
            session.freeHistoryTurn(alloc, turn);
        }
    }
    return turns.toOwnedSlice(alloc);
}

pub fn loadConversationArchive(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
) ![]session.HistoryTurn {
    var file = try openManagedFile(dir, events_file, .read_only);
    defer file.close(io_mod.getIo());
    const length = try file.length(io_mod.getIo());
    return load_conversation_archive_from_file(alloc, file, length, false);
}

fn load_conversation_archive_from_file(
    alloc: Allocator,
    file: std.Io.File,
    length: u64,
    close_open_turn: bool,
) ![]session.HistoryTurn {
    var offset: u64 = 0;
    var turns: std.ArrayList(session.HistoryTurn) = .empty;
    errdefer {
        for (turns.items) |turn| session.freeHistoryTurn(alloc, turn);
        turns.deinit(alloc);
    }
    var builder = ConversationTurnBuilder.init(alloc);
    defer builder.deinit();
    var raw_turn_count: usize = 0;
    var compaction_count: usize = 0;
    while (offset < length) {
        const line = session_replay.readLineAt(alloc, file, offset, length) catch |err| switch (err) {
            error.TruncatedEventFrame => break,
            else => return err,
        } orelse break;
        defer alloc.free(line.bytes);
        var decoded = try session_event.decodeConversationFrame(alloc, line.bytes);
        defer decoded.deinit();
        const completed: ?session.HistoryTurn = switch (decoded.value.event) {
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
        offset = line.next_offset;
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

fn findConversationReplayWindow(
    alloc: Allocator,
    file: std.Io.File,
    length: u64,
) !ConversationReplayWindow {
    var window: ConversationReplayWindow = .{};
    var offset: u64 = 0;
    var turn_count: usize = 0;
    var last_seq: u64 = 0;
    var compaction_count: usize = 0;
    var last_complete_seq: u64 = 0;
    var active_user_offset: ?u64 = null;
    while (offset < length) {
        const line = session_replay.readLineAt(alloc, file, offset, length) catch |err| switch (err) {
            error.TruncatedEventFrame => break,
            else => return err,
        } orelse break;
        defer alloc.free(line.bytes);
        var decoded = try session_event.decodeConversationFrame(alloc, line.bytes);
        defer decoded.deinit();
        const expected_seq = std.math.add(u64, last_seq, 1) catch
            return error.InvalidConversationFrame;
        if (decoded.value.seq != expected_seq) return error.InvalidConversationFrame;
        last_seq = decoded.value.seq;
        switch (decoded.value.event) {
            .user => {
                if (active_user_offset != null) return error.InvalidConversationFrame;
                active_user_offset = offset;
            },
            .turn_completed, .interrupted => {
                if (active_user_offset == null) return error.InvalidConversationFrame;
                active_user_offset = null;
                turn_count = std.math.add(usize, turn_count, 1) catch
                    return error.InvalidConversationFrame;
                last_complete_seq = decoded.value.seq;
            },
            .context_checkpoint => |checkpoint| {
                last_complete_seq = decoded.value.seq;
                compaction_count = std.math.add(
                    usize,
                    compaction_count,
                    1,
                ) catch return error.InvalidConversationFrame;
                window = .{
                    .offset = offset,
                    .prior_turn_count = turn_count,
                    .compaction_count = compaction_count,
                    .active_user_offset = active_user_offset,
                    .checkpoint_offset = offset,
                    .coverage = checkpoint.covers_through_seq,
                };
            },
            else => {},
        }
        offset = line.next_offset;
    }
    window.last_complete_seq = last_complete_seq;
    // Coverage is the summarized prefix. Recent exchanges can precede the
    // checkpoint record and must be replayed after its summary, unchanged.
    if (window.checkpoint_offset != null) {
        offset = 0;
        window.offset = 0;
        window.active_user_offset = null;
        window.prior_turn_count = 0;
        while (offset < length) {
            const line = try session_replay.readLineAt(alloc, file, offset, length) orelse break;
            defer alloc.free(line.bytes);
            var decoded = try session_event.decodeConversationFrame(alloc, line.bytes);
            defer decoded.deinit();
            if (decoded.value.seq > window.coverage) break;
            switch (decoded.value.event) {
                .user => window.active_user_offset = offset,
                .turn_completed, .interrupted => {
                    window.active_user_offset = null;
                    window.prior_turn_count += 1;
                },
                else => {},
            }
            offset = line.next_offset;
            window.offset = offset;
        }
    }
    return window;
}

const ConversationTurnBuilder = struct {
    alloc: Allocator,
    user: ?types.UserTurn = null,
    pending_assistant: ?[]u8 = null,
    pending_replay: ?types.ProviderReplay = null,
    calls: std.ArrayList(types.ToolCall) = .empty,
    results: std.ArrayList(types.PersistedToolResult) = .empty,
    steps: std.ArrayList(types.ToolExecutionStep) = .empty,
    steering: std.ArrayList(types.PersistedSteering) = .empty,

    fn init(alloc: Allocator) ConversationTurnBuilder {
        return .{ .alloc = alloc };
    }

    fn deinit(self: *ConversationTurnBuilder) void {
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
        self.* = undefined;
    }

    fn isIdle(self: *const ConversationTurnBuilder) bool {
        return self.user == null and
            self.pending_assistant == null and
            self.calls.items.len == 0 and
            self.results.items.len == 0 and
            self.steps.items.len == 0 and
            self.steering.items.len == 0;
    }

    fn begin(
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

    fn appendAssistant(self: *ConversationTurnBuilder, value: session_event.ConversationAssistant) !void {
        if (self.calls.items.len == 0 and self.results.items.len == 0) try self.finishStandalone();
        if (self.user == null or self.pending_assistant != null or self.calls.items.len != 0) {
            return error.InvalidConversationFrame;
        }
        {
            const text = try self.alloc.dupe(u8, value.text);
            errdefer self.alloc.free(text);
            self.pending_replay = if (value.provider_replay) |replay| try types.dupeProviderReplay(self.alloc, replay) else null;
            self.pending_assistant = text;
        }
        if (value.standalone_response) try self.finishStep();
    }

    fn appendToolCall(
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

    fn appendToolResult(
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

    fn finishStandalone(self: *ConversationTurnBuilder) !void {
        if (self.calls.items.len != 0 or self.results.items.len != 0) return error.InvalidConversationFrame;
        const text = self.pending_assistant orelse return;
        if (text.len == 0 and self.pending_replay == null) {
            self.alloc.free(text);
            self.pending_assistant = null;
            return;
        }
        try self.finishStep();
    }

    fn finishStep(self: *ConversationTurnBuilder) !void {
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

    fn appendSteering(self: *ConversationTurnBuilder, text: []const u8) !void {
        if (self.user == null or self.calls.items.len != 0 or self.results.items.len != 0) {
            return error.InvalidConversationFrame;
        }
        if (self.pending_replay != null) try self.finishStep();
        const owned = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(owned);
        try self.steering.append(self.alloc, .{
            .text = owned,
            .assistant_prefix = self.pending_assistant,
            .after_tool_step_count = self.steps.items.len,
        });
        self.pending_assistant = null;
    }

    fn finishAssistant(
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

    fn finishInterrupted(
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
        errdefer if (assistant) |text| self.alloc.free(text);
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
        errdefer if (command_artifact) |handle| self.alloc.free(handle);
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
        } };
    }

    fn takeExecution(
        self: *ConversationTurnBuilder,
        files_source: []const types.FileEvidence,
        turn_summary: ?types.TurnSummary,
    ) !types.ExecutionMemory {
        const steps = try self.steps.toOwnedSlice(self.alloc);
        errdefer types.freeToolExecutionSteps(self.alloc, steps);
        const steering = try self.steering.toOwnedSlice(self.alloc);
        errdefer types.freePersistedSteering(self.alloc, steering);
        const files = try types.dupeFileEvidenceSlice(self.alloc, files_source);
        return .{
            .tool_steps = steps,
            .files = files,
            .steering = steering,
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
    errdefer alloc.free(call_id);
    const tool_name = try alloc.dupe(u8, value.tool_name);
    errdefer alloc.free(tool_name);
    const output = try alloc.dupe(u8, value.preview orelse "");
    errdefer alloc.free(output);
    const handle = try alloc.dupe(u8, value.artifact_ref);
    errdefer alloc.free(handle);
    const image_handle = if (value.tool_image_handle) |image_ref| try alloc.dupe(u8, image_ref) else null;
    errdefer if (image_handle) |image_ref| alloc.free(image_ref);
    const preview = if (value.preview) |text| try alloc.dupe(u8, text) else null;
    errdefer if (preview) |text| alloc.free(text);
    var permission_feedback: [][]u8 = if (value.permission_feedback.len > 0)
        try alloc.alloc([]u8, value.permission_feedback.len)
    else
        &.{};
    errdefer if (permission_feedback.len > 0) alloc.free(permission_feedback);
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
        for (execution.tool_steps) |*step| for (step.tool_results) |*result| {
            const handle = result.output_handle orelse continue;
            if (!result.truncated and result.output.len == result.stored_output_bytes) continue;
            const body = if (result.truncated)
                try result_store.formatStoredResultOutput(alloc, handle, result.preview orelse "", result.stored_output_bytes)
            else blk: {
                if (capability == null) {
                    const path = try io_mod.dirRealpathAlloc(alloc, dir.dir, ".");
                    defer alloc.free(path);
                    capability = try session_child_store.SessionChildCapability.init(alloc, dir.dir, path, .read_only);
                }
                break :blk result_store.readForReplayManaged(alloc, &capability.?, handle, result.stored_output_bytes) catch |err| switch (err) {
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
}

fn isCurrentConversationCheckpoint(turn: session.HistoryTurn) bool {
    return switch (turn) {
        .compacted_summary => |entry| std.mem.startsWith(
            u8,
            entry.summary,
            types.context_handoff_open,
        ),
        else => false,
    };
}

fn retainLatestCheckpointHistory(
    alloc: Allocator,
    state: *session_codec.DurableSessionState,
) !void {
    if (state.history.len == 0 or
        !isCurrentConversationCheckpoint(state.history[state.history.len - 1]))
    {
        return error.InvalidConversationEvent;
    }
    const retained = try alloc.alloc(session.HistoryTurn, 1);
    retained[0] = state.history[state.history.len - 1];
    for (state.history[0 .. state.history.len - 1]) |turn| {
        session.freeHistoryTurn(alloc, turn);
    }
    alloc.free(state.history);
    state.history = retained;
    state.context_history_start = 0;
}

fn projectConversationSnapshotLocators(
    alloc: Allocator,
    history: []session.HistoryTurn,
) !void {
    for (history) |*turn| {
        const images = switch (turn.*) {
            .assistant => |*entry| entry.user.images,
            .interrupted => |*entry| entry.user.images,
            .compacted_summary => continue,
        };
        try projectConversationImageLocators(alloc, images);
    }
}

fn projectConversationImageLocators(
    alloc: Allocator,
    images: []types.ImageAttachment,
) !void {
    for (images) |*image| {
        const snapshot_path = image.snapshot_path orelse continue;
        if (!std.fs.path.isAbsolute(snapshot_path)) continue;
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const projected = try session.projectSnapshotLocator(
            &buffer,
            snapshot_path,
        );
        const owned = try alloc.dupe(u8, projected);
        alloc.free(snapshot_path);
        image.snapshot_path = owned;
    }
}

fn externalizeConversationResults(
    alloc: Allocator,
    state: *session_codec.DurableSessionState,
    capability: *session_child_store.SessionChildCapability,
) !void {
    for (state.history) |*turn| switch (turn.*) {
        .assistant => |*entry| try externalizeExecutionResults(
            alloc,
            &entry.execution,
            capability,
            true,
        ),
        .interrupted => |*entry| try externalizeExecutionResults(
            alloc,
            &entry.execution,
            capability,
            true,
        ),
        .compacted_summary => {},
    };
}

fn externalizeConversationTurnResults(
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

fn deleteConversationMigrationFile(
    dir: *io_mod.VerifiedDir,
    name: []const u8,
) !void {
    dir.dir.deleteFile(io_mod.getIo(), name) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
}

fn deleteLegacyConversationFiles(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    source_generation: ?Identifier,
) !void {
    const names = [_][]const u8{
        conversation_migration_backup_file,
        "session.legacy.json",
        authority_file,
        authority_intent_file,
        publication_intent_file,
        checkpoint_file,
        commit_lock_file,
        session_display_metadata.sidecar_file,
        "resume-view.bin",
    };
    for (names) |name| try deleteConversationMigrationFile(dir, name);
    if (source_generation) |generation| {
        const watermark = try watermarkName(alloc, generation);
        defer alloc.free(watermark);
        try deleteConversationMigrationFile(dir, watermark);
    }
    try io_mod.syncVerifiedDir(dir.dir);
}

pub fn legacyImportRecoveryNeeded(dir: *io_mod.VerifiedDir) !bool {
    return entryExists(dir, conversation_migration_backup_file);
}

/// Repairs the only two interrupted publication states produced by the
/// one-way legacy importer. The old event log remains the authority until the
/// current metadata is durable; after that point the current log wins.
pub fn recoverInterruptedLegacyImport(
    alloc: Allocator,
    writable: *WritableSessionDir,
) !void {
    if (!try legacyImportRecoveryNeeded(&writable.dir)) return;
    const current_metadata = try hasConversationMetadata(alloc, &writable.dir);
    const current_events = try entryExists(&writable.dir, events_file);
    if (current_metadata) {
        if (!current_events) return error.SessionMigrationIncomplete;
        try deleteConversationMigrationFile(
            &writable.dir,
            conversation_migration_backup_file,
        );
        try deleteConversationMigrationFile(
            &writable.dir,
            conversation_migration_temp_file,
        );
        try io_mod.syncVerifiedDir(writable.dir.dir);
        return;
    }

    if (current_events) {
        try deleteConversationMigrationFile(&writable.dir, events_file);
    }
    try writable.dir.dir.rename(
        conversation_migration_backup_file,
        writable.dir.dir,
        events_file,
        io_mod.getIo(),
    );
    try deleteConversationMigrationFile(
        &writable.dir,
        conversation_migration_temp_file,
    );
    try io_mod.syncVerifiedDir(writable.dir.dir);
}

pub const Boundary = enum {
    latest_barrier_contended,
    latest_barrier_completed,
};

pub const LockKind = enum {
    session,
};

pub const TestControls = struct {
    context: ?*anyopaque = null,
    boundary_fn: ?*const fn (?*anyopaque, Boundary) anyerror!void = null,
    lock_fn: ?*const fn (?*anyopaque, LockKind) void = null,

    pub fn boundary(self: TestControls, point: Boundary) !void {
        if (self.boundary_fn) |callback| try callback(self.context, point);
    }

    fn lock(self: TestControls, kind: LockKind) void {
        if (self.lock_fn) |callback| callback(self.context, kind);
    }
};

pub const Options = struct {
    test_controls: TestControls = .{},
    session_lock_deadline_ms: u64 = lock_deadline_ms,
};

pub const SessionUpdate = union(enum) {
    preferences_changed: session_event.PreferencesChanged,
    workspace_rebound: session_event.WorkspaceRebound,
    history_turn_committed: session_event.HistoryTurnCommitted,
    usage_checkpointed: session_event.UsageCheckpointed,
    recovery_checkpoint_set: session_event.RecoveryCheckpointSet,
    recovery_checkpoint_cleared: session_event.RecoveryCheckpointCleared,
};

pub const OpenMode = enum {
    read_only,
    writable,
};

pub const CommitPosition = session_replay.CommitPosition;

test {
    _ = session_replay;
    _ = session_permission_state;
}

pub const CleanupReport = struct {
    removed: usize = 0,
    report_only: usize = 0,
    ignored: usize = 0,
};

pub const WritableSessionDir = struct {
    dir: io_mod.VerifiedDir,
    writer_lock: ?io_mod.TimedAdvisoryLock,
    session_id: []u8,

    pub fn deinit(self: *WritableSessionDir, alloc: Allocator) void {
        if (self.writer_lock) |*lock| lock.release();
        self.dir.close();
        alloc.free(self.session_id);
        self.* = undefined;
    }

    pub fn isParked(self: *const WritableSessionDir) bool {
        return self.writer_lock == null;
    }

    /// Release `session.lock` while keeping the session directory open for a
    /// later `unpark` in the same process (idle job-control suspend).
    pub fn park(self: *WritableSessionDir) void {
        const lock = &(self.writer_lock orelse return);
        lock.release();
        self.writer_lock = null;
    }

    /// Reacquire `session.lock` after `park`. Fails with `SessionBusy` when
    /// another process already owns the writer lock.
    pub fn unpark(self: *WritableSessionDir) !void {
        if (self.writer_lock != null) return;
        self.writer_lock = acquireLock(&self.dir, session_lock_file, true) catch |err| {
            return mapSessionLockError(err);
        };
    }

    pub fn eventLogLengthForTest(self: *WritableSessionDir) !u64 {
        var file = try openManagedFile(&self.dir, events_file, .read_only);
        defer file.close(io_mod.getIo());
        return file.length(io_mod.getIo());
    }

    fn entryExistsForTest(self: *WritableSessionDir, name: []const u8) !bool {
        return entryExists(&self.dir, name);
    }
};

pub const LoadedWritableSession = struct {
    pub const ExternalPromptOrigin = enum {
        root,
        persistent_child,
    };

    active_id: []u8,
    state: session_codec.DurableSessionState,
    conversation_writer: ConversationWriter,
    log: WritableSessionDir,
    freshly_started: bool = false,
    child_capability: ?*session_child_store.SessionChildCapability = null,
    position: CommitPosition,
    migration_source_schema_version: ?u8 = null,
    migration_source_bytes: ?u64 = null,
    /// Runtime-only provenance installed by subagent resume admission. These
    /// fields are never written into the session event log.
    external_prompt_origin: ExternalPromptOrigin = .root,
    external_root_user_messages: [][]u8 = &.{},
    external_root_user_evidence_complete: bool = false,

    pub fn deinit(self: *LoadedWritableSession, alloc: Allocator) void {
        self.conversation_writer.deinit();
        if (self.child_capability) |capability| {
            capability.deinit();
            alloc.destroy(capability);
        }
        for (self.external_root_user_messages) |message| alloc.free(message);
        if (self.external_root_user_messages.len > 0) {
            alloc.free(self.external_root_user_messages);
        }
        alloc.free(self.active_id);
        self.state.deinit(alloc);
        self.log.deinit(alloc);
        self.* = undefined;
    }

    /// Returns a borrowed address that remains stable until deinit.
    pub fn childCapability(
        self: *LoadedWritableSession,
    ) !*session_child_store.SessionChildCapability {
        return if (self.child_capability) |capability|
            capability
        else
            error.SessionChildCapabilityUnavailable;
    }

    /// Releases the one-time resume projection after the owning runtime has
    /// restored it. New conversation events continue through `ConversationWriter`.
    pub fn releaseHydrationHistory(
        self: *LoadedWritableSession,
        alloc: Allocator,
    ) void {
        session.freeHistoryTurnSlice(alloc, self.state.history);
        self.state.history = &.{};
        self.state.context_history_start = 0;
    }

    pub fn prepareHistoryTurnForCommit(
        self: *LoadedWritableSession,
        alloc: Allocator,
        turn: *session.HistoryTurn,
    ) !void {
        try externalizeConversationTurnResults(
            alloc,
            turn,
            self.child_capability,
        );
    }

    pub fn renameConversation(
        self: *LoadedWritableSession,
        alloc: Allocator,
        title: []const u8,
    ) !bool {
        const bytes = try readManagedFileAlloc(
            alloc,
            &self.log.dir,
            manifest_file,
            session_codec.max_session_metadata_bytes,
        );
        defer alloc.free(bytes);
        var metadata = try session_codec.decodeSessionMetadata(alloc, bytes);
        defer metadata.deinit();
        const encoded = try session_codec.encodeSessionMetadata(alloc, .{
            .id = metadata.value.id,
            .origin_workspace_root = metadata.value.origin_workspace_root,
            .workspace_root = metadata.value.workspace_root,
            .created_at_ms = metadata.value.created_at_ms,
            .updated_at_ms = metadata.value.updated_at_ms,
            .conversation_language = metadata.value.conversation_language,
            .provider = metadata.value.provider,
            .model = metadata.value.model,
            .effort = metadata.value.effort,
            .fast_mode = metadata.value.fast_mode,
            .title = title,
            .subagent_child = metadata.value.subagent_child,
        });
        defer alloc.free(encoded);
        try io_mod.durableReplaceVerified(
            alloc,
            &self.log.dir,
            manifest_file,
            encoded,
        );
        return true;
    }

    pub fn conversationTitle(
        self: *LoadedWritableSession,
        alloc: Allocator,
    ) !?[]u8 {
        const bytes = try readManagedFileAlloc(
            alloc,
            &self.log.dir,
            manifest_file,
            session_codec.max_session_metadata_bytes,
        );
        defer alloc.free(bytes);
        var metadata = try session_codec.decodeSessionMetadata(alloc, bytes);
        defer metadata.deinit();
        return if (metadata.value.title) |title|
            try alloc.dupe(u8, title)
        else
            null;
    }

    pub fn appendEvent(
        self: *LoadedWritableSession,
        alloc: Allocator,
        event: SessionUpdate,
        timestamp_ms: i64,
    ) !CommitPosition {
        return switch (event) {
            .history_turn_committed => self.appendConversationHistoryEvent(
                alloc,
                event,
                timestamp_ms,
            ),
            .preferences_changed, .workspace_rebound => self.appendConversationMetadataEvent(
                alloc,
                event,
                timestamp_ms,
            ),
            .usage_checkpointed => self.appendConversationUsageEvent(
                alloc,
                event,
                timestamp_ms,
            ),
            .recovery_checkpoint_set, .recovery_checkpoint_cleared => self.appendConversationRecoveryEvent(
                alloc,
                event,
                timestamp_ms,
            ),
        };
    }

    pub fn commitContextCompaction(
        self: *LoadedWritableSession,
        alloc: Allocator,
        summary: types.CompactedSummaryHistoryTurn,
        active_prefix: ?types.AssistantHistoryTurn,
        retained_from: ?types.ContextHistoryCut,
        timestamp_ms: i64,
    ) !CommitPosition {
        var prepared: ?session.HistoryTurn = if (active_prefix) |prefix|
            try session.dupeHistoryTurn(alloc, .{ .assistant = prefix })
        else
            null;
        defer if (prepared) |turn| session.freeHistoryTurn(alloc, turn);
        if (prepared) |*turn| try self.prepareHistoryTurnForCommit(alloc, turn);
        try self.conversation_writer.appendContextCompaction(
            alloc,
            timestamp_ms,
            summary,
            if (prepared) |turn| turn.assistant else null,
            retained_from,
        );
        if (prepared) |turn| self.writeFirstConversationTitle(alloc, turn);
        return self.finishConversationCommit(alloc, timestamp_ms);
    }

    /// Cuts the conversation log at a planned boundary. A turn left open at
    /// the cut is closed as interrupted, and a paused response is dropped with
    /// the tail it belonged to. The hydration history is released because it
    /// no longer matches the log; reopen the session to project it again.
    pub fn truncateConversation(
        self: *LoadedWritableSession,
        alloc: Allocator,
        plan: ConversationTruncation,
        timestamp_ms: i64,
    ) !void {
        const writer = &self.conversation_writer;
        if (plan.boundary.bytes > writer.committed_bytes) return error.InvalidConversationFrame;
        try writer.file.setLength(io_mod.getIo(), plan.boundary.bytes);
        try writer.file.sync(io_mod.getIo());
        try writer.replayCommitted();
        if (writer.turn_open) {
            _ = try writer.append(alloc, timestamp_ms, .{
                .interrupted = .{ .reason = .failed },
            });
        }
        try writeConversationRecoveryState(alloc, &self.log.dir, null, writer.last_seq);
        if (self.state.recovery_checkpoint) |*checkpoint| {
            checkpoint.deinit(alloc);
            self.state.recovery_checkpoint = null;
        }
        self.releaseHydrationHistory(alloc);
        self.state.updated_at_ms = timestamp_ms;
        self.position = .{
            .log_generation = self.position.log_generation,
            .through_seq = writer.last_seq,
            .through_event_id = randomIdentifier(),
            .through_event_log_bytes = writer.committed_bytes,
        };
        self.freshly_started = false;
        debug_trace.logf(
            "session",
            "event=conversation_truncated session={s} bytes={d} through_seq={d} interrupted={}",
            .{ self.active_id, plan.boundary.bytes, plan.boundary.seq, plan.boundary.turn_open },
        );
    }

    fn appendConversationHistoryEvent(
        self: *LoadedWritableSession,
        alloc: Allocator,
        event: SessionUpdate,
        timestamp_ms: i64,
    ) !CommitPosition {
        const payload = switch (event) {
            .history_turn_committed => |value| value,
            else => return error.InvalidConversationEvent,
        };
        const work_id = if (payload.work_id) |value|
            try alloc.dupe(u8, value)
        else
            null;
        errdefer if (work_id) |value| alloc.free(value);
        try self.conversation_writer.appendHistoryTurn(
            alloc,
            timestamp_ms,
            payload.turn,
        );
        self.writeFirstConversationTitle(alloc, payload.turn);
        if (work_id) |value| {
            if (self.state.last_subagent_work_id) |old| alloc.free(old);
            self.state.last_subagent_work_id = value;
        }
        self.state.conversation_language = payload.conversation_language;
        self.state.total_input_tokens = payload.total_input_tokens;
        self.state.total_output_tokens = payload.total_output_tokens;
        return self.finishConversationCommit(alloc, timestamp_ms);
    }

    fn writeFirstConversationTitle(self: *LoadedWritableSession, alloc: Allocator, turn: session.HistoryTurn) void {
        if (!self.freshly_started) return;
        var display = session_display_metadata.deriveFromHistory(alloc, &.{turn}) catch return;
        defer display.deinit(alloc);
        if (!display.present) return;
        _ = self.renameConversation(alloc, display.title) catch |err| {
            debug_trace.logf(
                "session",
                "derived session title not persisted session={s} err={s}",
                .{ self.active_id, @errorName(err) },
            );
        };
    }

    fn finishConversationCommit(self: *LoadedWritableSession, alloc: Allocator, timestamp_ms: i64) CommitPosition {
        if (self.state.recovery_checkpoint != null) {
            writeConversationRecoveryState(alloc, &self.log.dir, null, self.conversation_writer.last_seq) catch |err| {
                debug_trace.logf(
                    "session",
                    "event=committed_turn_recovery_cleanup_failed session={s} err={s}",
                    .{ self.active_id, @errorName(err) },
                );
            };
            self.state.recovery_checkpoint.?.deinit(alloc);
            self.state.recovery_checkpoint = null;
        }
        self.state.updated_at_ms = timestamp_ms;
        self.position = .{
            .log_generation = self.position.log_generation,
            .through_seq = self.conversation_writer.last_seq,
            .through_event_id = randomIdentifier(),
            .through_event_log_bytes = self.conversation_writer.committed_bytes,
        };
        self.freshly_started = false;
        return self.position;
    }

    fn appendConversationMetadataEvent(
        self: *LoadedWritableSession,
        alloc: Allocator,
        event: SessionUpdate,
        timestamp_ms: i64,
    ) !CommitPosition {
        switch (event) {
            .preferences_changed => |patch| {
                var preferences = try self.state.preferences.dupe(alloc);
                errdefer preferences.deinit(alloc);
                if (patch.model) |model| {
                    const copy = try alloc.dupe(u8, model);
                    alloc.free(preferences.model);
                    preferences.model = copy;
                }
                if (patch.provider) |provider| preferences.provider = provider;
                if (patch.effort) |effort| preferences.effort = effort;
                if (patch.fast_mode) |fast_mode| preferences.fast_mode = fast_mode;
                var proposed = self.state;
                proposed.preferences = preferences;
                proposed.updated_at_ms = timestamp_ms;
                try session_codec.validateState(proposed);
                try writeConversationMetadata(alloc, &self.log.dir, proposed);
                self.state.preferences.deinit(alloc);
                self.state.preferences = preferences;
            },
            .workspace_rebound => |rebound| {
                if (!std.mem.eql(
                    u8,
                    rebound.previous_workspace_root,
                    self.state.workspace_root,
                ) or std.mem.eql(
                    u8,
                    rebound.workspace_root,
                    self.state.workspace_root,
                )) {
                    return error.ImmutableSessionIdentity;
                }
                const workspace_root = try alloc.dupe(u8, rebound.workspace_root);
                errdefer alloc.free(workspace_root);
                var proposed = self.state;
                proposed.workspace_root = workspace_root;
                proposed.updated_at_ms = timestamp_ms;
                try session_codec.validateState(proposed);
                try writeConversationMetadata(alloc, &self.log.dir, proposed);
                alloc.free(self.state.workspace_root);
                self.state.workspace_root = workspace_root;
            },
            else => return error.InvalidConversationEvent,
        }
        self.state.updated_at_ms = timestamp_ms;
        self.freshly_started = false;
        return self.position;
    }

    fn appendConversationUsageEvent(
        self: *LoadedWritableSession,
        alloc: Allocator,
        event: SessionUpdate,
        timestamp_ms: i64,
    ) !CommitPosition {
        const snapshot = switch (event) {
            .usage_checkpointed => |payload| payload.usage,
            else => return error.InvalidConversationEvent,
        };
        var next_usage = try session_usage.dupeSnapshotOwned(alloc, snapshot);
        errdefer next_usage.deinit(alloc);
        try session_usage_sidecar.write(
            alloc,
            &self.log.dir,
            self.active_id,
            snapshot,
        );
        if (self.state.usage) |*prior| prior.deinit(alloc);
        self.state.usage = next_usage;
        next_usage = undefined;
        self.state.updated_at_ms = timestamp_ms;
        return self.position;
    }

    fn appendConversationRecoveryEvent(
        self: *LoadedWritableSession,
        alloc: Allocator,
        event: SessionUpdate,
        timestamp_ms: i64,
    ) !CommitPosition {
        switch (event) {
            .recovery_checkpoint_set => |payload| {
                const checkpoint = try payload.checkpoint.dupe(alloc);
                errdefer {
                    var owned = checkpoint;
                    owned.deinit(alloc);
                }
                try writeConversationRecoveryState(
                    alloc,
                    &self.log.dir,
                    checkpoint,
                    self.conversation_writer.last_seq,
                );
                if (self.state.recovery_checkpoint) |*prior| prior.deinit(alloc);
                self.state.recovery_checkpoint = checkpoint;
            },
            .recovery_checkpoint_cleared => {
                try writeConversationRecoveryState(alloc, &self.log.dir, null, self.conversation_writer.last_seq);
                if (self.state.recovery_checkpoint) |*prior| prior.deinit(alloc);
                self.state.recovery_checkpoint = null;
            },
            else => return error.InvalidConversationEvent,
        }
        self.state.updated_at_ms = timestamp_ms;
        return self.position;
    }

    pub fn replacePermissionState(
        self: *LoadedWritableSession,
        alloc: Allocator,
        permission_state: session_permission_state.State,
        timestamp_ms: i64,
    ) !void {
        var next = try session_permission_state.dupe(alloc, permission_state);
        errdefer next.deinit(alloc);
        const bytes = try session_codec.encodePermissionState(alloc, next);
        defer alloc.free(bytes);
        try io_mod.durableReplaceVerified(
            alloc,
            &self.log.dir,
            permission_state_file,
            bytes,
        );
        self.state.permission_state.deinit(alloc);
        self.state.permission_state = next;
        self.state.updated_at_ms = timestamp_ms;
        self.freshly_started = false;
    }
};

/// Consumes a validated legacy snapshot and its locked directory, then writes
/// the current conversation representation directly. The legacy metadata stays
/// authoritative until the complete event log is durable; callers receive only
/// a current-format writable session.
pub fn importLegacySnapshotState(
    alloc: Allocator,
    writable: *WritableSessionDir,
    state: session_codec.DurableSessionState,
    source_schema_version: u8,
    source_bytes: u64,
    source_generation: ?Identifier,
) !LoadedWritableSession {
    return importLegacySnapshotStateWithOps(
        alloc,
        writable,
        state,
        source_schema_version,
        source_bytes,
        source_generation,
        .{},
    );
}

fn discardEmptyLegacyFileEvidence(alloc: Allocator, history: []session.HistoryTurn) !usize {
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

fn importLegacySnapshotStateWithOps(
    alloc: Allocator,
    writable: *WritableSessionDir,
    state: session_codec.DurableSessionState,
    source_schema_version: u8,
    source_bytes: u64,
    source_generation: ?Identifier,
    metadata_ops: io_mod.DurableOps,
) !LoadedWritableSession {
    try recoverInterruptedLegacyImport(alloc, writable);
    var migrated_permissions = if (state.permission_state.version != session_permission_state.schema_version)
        try session_permission_state.migrateV1ToV2(alloc, state.permission_state)
    else
        null;
    defer if (migrated_permissions) |*permissions| permissions.deinit(alloc);
    var import_state = state;
    if (migrated_permissions) |permissions| import_state.permission_state = permissions;
    var converted = try import_state.dupe(alloc);
    errdefer converted.deinit(alloc);
    if (try converted.archive_legacy_recovery(alloc)) {
        debug_trace.logf("session", "legacy recovery archived session_id={s} reason=unverifiable_route_authority", .{converted.id});
    }
    const discarded = try discardEmptyLegacyFileEvidence(alloc, converted.history);
    if (discarded > 0) debug_trace.logf("session", "legacy import discarded file evidence count={d} reason=empty_path", .{discarded});
    try projectConversationSnapshotLocators(alloc, converted.history);

    const display_path = try io_mod.dirRealpathAlloc(
        alloc,
        writable.dir.dir,
        ".",
    );
    defer alloc.free(display_path);
    var capability = try session_child_store.SessionChildCapability.init(
        alloc,
        writable.dir.dir,
        display_path,
        .writable,
    );
    defer capability.deinit();
    try externalizeConversationResults(alloc, &converted, &capability);

    const active_id = try alloc.dupe(u8, writable.session_id);
    errdefer alloc.free(active_id);
    try deleteConversationMigrationFile(
        &writable.dir,
        conversation_migration_temp_file,
    );
    var temp_file = try createManagedFile(
        &writable.dir,
        conversation_migration_temp_file,
    );
    var writer = ConversationWriter.init(alloc, temp_file) catch |err| {
        temp_file.close(io_mod.getIo());
        return err;
    };
    var writer_owned = true;
    defer if (writer_owned) writer.deinit();
    for (converted.history, 0..) |turn, index| {
        if (turn == .compacted_summary) {
            // Legacy archives can retain raw turns before the active summary.
            // Earlier summaries stay archived without advancing that cut.
            const coverage = if (index > 0 and index == converted.context_history_start)
                try writer.contextCoverage(alloc, .{ .turns = turn.compacted_summary.removed_turn_count }, &.{})
            else
                writer.latest_checkpoint_coverage;
            _ = try writer.append(alloc, converted.updated_at_ms, .{ .context_checkpoint = .{
                .covers_through_seq = coverage,
                .summary = turn.compacted_summary.summary,
            } });
        } else {
            try writer.appendHistoryTurn(alloc, converted.updated_at_ms, turn);
        }
    }
    const conversation_seq = writer.last_seq;
    writer.deinit();
    writer_owned = false;

    try writeConversationControlState(alloc, &writable.dir, converted, conversation_seq);
    var display = try session_display_metadata.deriveFromHistory(
        alloc,
        converted.history,
    );
    defer display.deinit(alloc);
    const metadata_bytes = try encodeConversationMetadataWithTitle(
        alloc,
        converted,
        if (display.present) display.title else null,
    );
    defer alloc.free(metadata_bytes);
    const had_previous_log = try entryExists(&writable.dir, events_file);
    var old_log_renamed = false;
    var new_log_published = false;
    var metadata_published = false;
    errdefer if (!metadata_published) {
        if (new_log_published) {
            deleteConversationMigrationFile(&writable.dir, events_file) catch {};
        }
        if (old_log_renamed) {
            writable.dir.dir.rename(
                conversation_migration_backup_file,
                writable.dir.dir,
                events_file,
                io_mod.getIo(),
            ) catch {};
        }
        io_mod.syncVerifiedDir(writable.dir.dir) catch {};
    };
    if (had_previous_log) {
        try writable.dir.dir.rename(
            events_file,
            writable.dir.dir,
            conversation_migration_backup_file,
            io_mod.getIo(),
        );
        old_log_renamed = true;
    }
    try writable.dir.dir.rename(
        conversation_migration_temp_file,
        writable.dir.dir,
        events_file,
        io_mod.getIo(),
    );
    new_log_published = true;
    try io_mod.syncVerifiedDir(writable.dir.dir);
    io_mod.durableReplaceVerifiedWithOps(
        alloc,
        &writable.dir,
        manifest_file,
        metadata_bytes,
        metadata_ops,
    ) catch |err| {
        // A failed directory sync can leave the new metadata visible. Keep
        // both logs so recovery can select the metadata that survived.
        if (err == error.DurableReplacePostRenameFailed) metadata_published = true;
        return err;
    };
    metadata_published = true;

    var hydrated = (try loadConversationStateIfPresent(alloc, &writable.dir, converted.id)) orelse
        return error.InvalidSessionMetadata;
    defer hydrated.deinit(alloc);
    session.freeHistoryTurnSlice(alloc, converted.history);
    converted.history = hydrated.history;
    hydrated.history = &.{};
    converted.context_history_start = hydrated.context_history_start;

    var event_file = try openManagedFile(
        &writable.dir,
        events_file,
        .read_write,
    );
    var conversation_writer = ConversationWriter.init(alloc, event_file) catch |err| {
        event_file.close(io_mod.getIo());
        return err;
    };
    errdefer conversation_writer.deinit();
    deleteLegacyConversationFiles(
        alloc,
        &writable.dir,
        source_generation,
    ) catch |err| debug_trace.logf(
        "session",
        "event=legacy_session_cleanup_failed session={s} err={s}",
        .{ writable.session_id, @errorName(err) },
    );

    const position = CommitPosition{
        .log_generation = randomIdentifier(),
        .through_seq = conversation_writer.last_seq,
        .through_event_id = randomIdentifier(),
        .through_event_log_bytes = conversation_writer.committed_bytes,
    };
    const result = LoadedWritableSession{
        .active_id = active_id,
        .state = converted,
        .conversation_writer = conversation_writer,
        .log = writable.*,
        .position = position,
        .migration_source_schema_version = source_schema_version,
        .migration_source_bytes = source_bytes,
    };
    converted = undefined;
    writable.* = undefined;
    return result;
}
/// Preserves each call's exact error set while sharing one dynamic return ABI.
pub inline fn failLoadedWritableSession(err: anytype) @TypeOf(err)!LoadedWritableSession {
    return @errorCast(failLoadedWritableSessionDynamic(err));
}

noinline fn failLoadedWritableSessionDynamic(err: anyerror) anyerror!LoadedWritableSession {
    return err;
}

test "large session errors preserve their exact error type and identity" {
    const result = failLoadedWritableSession(error.NoSavedSessions);
    try std.testing.expect(
        @TypeOf(result) == error{NoSavedSessions}!LoadedWritableSession,
    );
    try std.testing.expectError(error.NoSavedSessions, result);
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
                        .display_root = try std.fs.path.join(
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
                        .display_root = try std.fs.path.join(
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
                        .display_root = try std.fs.path.join(
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

    pub fn startConversationSession(
        self: *Root,
        alloc: Allocator,
        initial_state: session_codec.DurableSessionState,
        options: Options,
    ) !LoadedWritableSession {
        if (self.mode != .writable or self.sessions == null) {
            return failLoadedWritableSession(error.SessionStoreUnavailable);
        }
        try session_codec.validateState(initial_state);
        const sessions = &self.sessions.?;
        if (try entryExists(sessions, initial_state.id)) {
            return failLoadedWritableSession(error.SessionAlreadyExists);
        }

        sessions.dir.createDir(
            io_mod.getIo(),
            initial_state.id,
            private_dir_permissions,
        ) catch |err| switch (err) {
            error.PathAlreadyExists => return failLoadedWritableSession(error.SessionAlreadyExists),
            else => return failLoadedWritableSession(error.SessionStartFailed),
        };
        io_mod.syncVerifiedDir(sessions.dir) catch
            return failLoadedWritableSession(error.SessionStartFailed);

        var session_dir = try openSessionDir(sessions, initial_state.id, .writable);
        options.test_controls.lock(.session);
        var writer_lock = acquireLockWithDeadline(
            &session_dir,
            session_lock_file,
            true,
            options.session_lock_deadline_ms,
        ) catch |err| {
            session_dir.close();
            return mapSessionLockError(err);
        };
        const session_id = alloc.dupe(u8, initial_state.id) catch |err| {
            writer_lock.release();
            session_dir.close();
            return err;
        };
        var writable = WritableSessionDir{
            .dir = session_dir,
            .writer_lock = writer_lock,
            .session_id = session_id,
        };
        errdefer writable.deinit(alloc);
        return createNativeSession(
            alloc,
            &writable,
            initial_state,
            options,
        );
    }

    pub fn resumeForWrite(
        self: *Root,
        alloc: Allocator,
        session_id: []const u8,
        options: Options,
    ) !LoadedWritableSession {
        options.test_controls.lock(.session);
        var writable = try self.openWritableSessionDir(
            alloc,
            session_id,
            options.session_lock_deadline_ms,
        );
        if (!try hasConversationMetadata(alloc, &writable.dir)) {
            writable.deinit(alloc);
            return error.SessionMigrationRequired;
        }
        return openConversationWritableSession(alloc, &writable) catch |err| {
            writable.deinit(alloc);
            return err;
        };
    }

    pub fn loadReadOnly(
        self: *Root,
        alloc: Allocator,
        session_id: []const u8,
        _: Options,
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

    /// Reads the immutable child-privacy bit from current session metadata.
    /// Legacy sessions retain their read-only first-event compatibility path.
    pub fn loadSubagentChildIdentity(
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
        if (try hasConversationMetadata(alloc, &session_dir)) {
            const metadata_bytes = try readManagedFileAlloc(
                alloc,
                &session_dir,
                manifest_file,
                session_codec.max_session_metadata_bytes,
            );
            defer alloc.free(metadata_bytes);
            var metadata = try session_codec.decodeSessionMetadata(
                alloc,
                metadata_bytes,
            );
            defer metadata.deinit();
            if (!std.mem.eql(u8, metadata.value.id, session_id)) {
                return error.InvalidSessionMetadata;
            }
            return metadata.value.subagent_child;
        }
        var log_file = try openManagedFile(&session_dir, events_file, .read_only);
        defer log_file.close(io_mod.getIo());
        return session_replay.readSubagentChildIdentity(alloc, log_file);
    }

    fn openWritableSessionDir(
        self: *Root,
        alloc: Allocator,
        session_id: []const u8,
        deadline_ms: u64,
    ) !WritableSessionDir {
        if (self.mode != .writable or self.sessions == null) return error.SessionNotFound;
        try session_layout.validateSessionId(session_id);
        var dir = openSessionDir(&self.sessions.?, session_id, .writable) catch |err| switch (err) {
            error.FileNotFound => return error.SessionNotFound,
            else => return err,
        };
        var writer_lock = acquireLockWithDeadline(
            &dir,
            session_lock_file,
            true,
            deadline_ms,
        ) catch |err| {
            dir.close();
            return mapSessionLockError(err);
        };
        const owned_id = alloc.dupe(u8, session_id) catch |err| {
            writer_lock.release();
            dir.close();
            return err;
        };
        return .{
            .dir = dir,
            .writer_lock = writer_lock,
            .session_id = owned_id,
        };
    }

    fn entryExistsForTest(
        self: *Root,
        alloc: Allocator,
        session_id: []const u8,
        name: []const u8,
    ) !bool {
        _ = alloc;
        if (self.sessions == null) return false;
        var dir = openSessionDir(&self.sessions.?, session_id, .read_only) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer dir.close();
        return entryExists(&dir, name);
    }
};

fn validateLeaf(name: []const u8) !void {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or
        std.mem.eql(u8, name, "..") or
        std.mem.indexOfAny(u8, name, "/\\") != null)
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

fn openManagedFile(
    dir: *io_mod.VerifiedDir,
    name: []const u8,
    mode: std.Io.Dir.OpenFileOptions.Mode,
) !std.Io.File {
    try validateLeaf(name);
    var file = dir.dir.openFile(io_mod.getIo(), name, .{
        .mode = mode,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.IsDir, error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
        else => return err,
    };
    errdefer file.close(io_mod.getIo());
    try verifyManagedFile(file, if (mode == .read_only) .read_only else .writable);
    return file;
}

fn createManagedFile(
    dir: *io_mod.VerifiedDir,
    name: []const u8,
) !std.Io.File {
    try validateLeaf(name);
    var file = dir.dir.createFile(io_mod.getIo(), name, .{
        .read = true,
        .truncate = false,
        .exclusive = true,
        .permissions = private_file_permissions,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.IsDir, error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
        else => return err,
    };
    errdefer file.close(io_mod.getIo());
    file.setPermissions(io_mod.getIo(), private_file_permissions) catch
        return error.PrivateStatePermissionsUnsupported;
    try verifyManagedFile(file, .writable);
    return file;
}

fn entryExists(dir: *io_mod.VerifiedDir, name: []const u8) !bool {
    try validateLeaf(name);
    const stat = dir.dir.statFile(io_mod.getIo(), name, .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
        else => return err,
    };
    if (stat.kind != .file and stat.kind != .directory) return error.SessionPathUnsafe;
    if (stat.kind == .file and stat.nlink != 1) return error.SessionPathUnsafe;
    return true;
}

fn acquireLock(
    dir: *io_mod.VerifiedDir,
    name: []const u8,
    create: bool,
) !io_mod.TimedAdvisoryLock {
    return acquireLockWithDeadline(dir, name, create, lock_deadline_ms);
}

fn acquireLockWithDeadline(
    dir: *io_mod.VerifiedDir,
    name: []const u8,
    create: bool,
    deadline_ms: u64,
) !io_mod.TimedAdvisoryLock {
    if (create) {
        return io_mod.acquireTimedAdvisoryLock(dir, name, deadline_ms);
    }
    var file = try openManagedFile(dir, name, .read_write);
    errdefer file.close(io_mod.getIo());
    const started = io_mod.milliTimestamp();
    while (true) {
        const locked = file.tryLock(io_mod.getIo(), .exclusive) catch |err| switch (err) {
            error.FileLocksUnsupported => return error.LockUnsupported,
            else => return err,
        };
        if (locked) return .{ .file = file };
        if (io_mod.milliTimestamp() - started >= deadline_ms) return error.LockBusy;
        io_mod.sleep(10 * std.time.ns_per_ms);
    }
}

fn mapSessionLockError(err: anyerror) anyerror {
    return switch (err) {
        error.LockBusy => error.SessionBusy,
        error.LockUnsupported => error.SessionLockUnsupported,
        else => err,
    };
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

fn randomIdentifier() Identifier {
    var id: Identifier = undefined;
    io_mod.getIo().random(&id);
    return id;
}

fn watermarkName(alloc: Allocator, generation: Identifier) ![]u8 {
    const hex = std.fmt.bytesToHex(generation, .lower);
    return std.fmt.allocPrint(alloc, "commit.{s}.json", .{hex});
}

fn createNativeSession(
    alloc: Allocator,
    writable: *WritableSessionDir,
    initial_state: session_codec.DurableSessionState,
    _: Options,
) !LoadedWritableSession {
    var synthesized_usage: ?session_usage.Snapshot = null;
    if (initial_state.usage == null) {
        var fresh_usage = session_usage.Usage.initFresh();
        defer fresh_usage.deinit(alloc);
        synthesized_usage = try fresh_usage.snapshot(alloc);
    }
    defer if (synthesized_usage) |*usage| usage.deinit(alloc);

    var display = try session_display_metadata.deriveFromHistory(
        alloc,
        initial_state.history,
    );
    defer display.deinit(alloc);
    var conversation_writer = try createConversationStorage(alloc, &writable.dir, .{
        .id = initial_state.id,
        .origin_workspace_root = initial_state.origin_workspace_root,
        .workspace_root = initial_state.workspace_root,
        .created_at_ms = initial_state.created_at_ms,
        .updated_at_ms = initial_state.updated_at_ms,
        .conversation_language = initial_state.conversation_language.view(),
        .provider = @tagName(initial_state.preferences.provider),
        .model = initial_state.preferences.model,
        .effort = initial_state.preferences.effort.label(),
        .fast_mode = initial_state.preferences.fast_mode,
        .title = if (display.present) display.title else null,
        .subagent_child = initial_state.subagent_child,
    });
    errdefer conversation_writer.deinit();
    for (initial_state.history) |turn| {
        if (turn == .compacted_summary and conversation_writer.last_seq == 0) continue;
        try conversation_writer.appendHistoryTurn(
            alloc,
            initial_state.updated_at_ms,
            turn,
        );
    }

    var state = try initial_state.dupe(alloc);
    errdefer state.deinit(alloc);
    if (state.usage == null) {
        state.usage = synthesized_usage;
        synthesized_usage = null;
    }
    try writeConversationControlState(alloc, &writable.dir, state, conversation_writer.last_seq);
    const active_id = try alloc.dupe(u8, writable.session_id);
    errdefer alloc.free(active_id);
    const generation = randomIdentifier();
    const position = CommitPosition{
        .log_generation = generation,
        .through_seq = conversation_writer.last_seq,
        .through_event_id = randomIdentifier(),
        .through_event_log_bytes = conversation_writer.committed_bytes,
    };
    const result = LoadedWritableSession{
        .active_id = active_id,
        .state = state,
        .conversation_writer = conversation_writer,
        .log = writable.*,
        .freshly_started = true,
        .position = position,
    };
    writable.* = undefined;
    return result;
}

pub fn durableStatesEqual(
    first: session_codec.DurableSessionState,
    second: session_codec.DurableSessionState,
) !bool {
    var first_buffer: [4096]u8 = undefined;
    var first_discard = std.Io.Writer.Discarding.init(&first_buffer);
    const first_summary = try session_codec.encodeState(
        first,
        &first_discard.writer,
    );
    var second_buffer: [4096]u8 = undefined;
    var second_discard = std.Io.Writer.Discarding.init(&second_buffer);
    const second_summary = try session_codec.encodeState(
        second,
        &second_discard.writer,
    );
    return first_summary.encoded_bytes == second_summary.encoded_bytes and
        std.mem.eql(
            u8,
            &first_summary.sha256,
            &second_summary.sha256,
        );
}

const TempRoot = struct {
    tmp: std.testing.TmpDir,
    home: []u8,
    root: Root,

    fn init(alloc: Allocator) !TempRoot {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDir(io_mod.getIo(), "home", std.Io.File.Permissions.fromMode(0o700));
        const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
        errdefer alloc.free(home);
        var root = try Root.initFromHome(alloc, home, .writable);
        errdefer root.deinit(alloc);
        return .{ .tmp = tmp, .home = home, .root = root };
    }

    fn deinit(self: *TempRoot, alloc: Allocator) void {
        self.root.deinit(alloc);
        alloc.free(self.home);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

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

fn testState(alloc: Allocator, id: []const u8, updated_at_ms: i64) !session_codec.DurableSessionState {
    return .{
        .id = try alloc.dupe(u8, id),
        .origin_workspace_root = try alloc.dupe(u8, "/tmp/fx-plan-03"),
        .workspace_root = try alloc.dupe(u8, "/tmp/fx-plan-03"),
        .created_at_ms = 10,
        .updated_at_ms = updated_at_ms,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .preferences = .{
            .model = try alloc.dupe(u8, "test/model"),
            .effort = types.ReasoningEffort.literal("high"),
            .fast_mode = false,
        },
        .history = &.{},
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
}

test "conversation writer appends one durable line per event" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "events.jsonl", .{
        .read = true,
        .truncate = true,
    });
    var writer = try ConversationWriter.init(alloc, file);
    defer writer.deinit();

    try std.testing.expectEqual(@as(u64, 1), try writer.append(alloc, 10, .{
        .user = .{ .text = "Run the command." },
    }));
    try std.testing.expectEqual(@as(u64, 2), try writer.append(alloc, 11, .{
        .tool_call = .{
            .call_id = "call-shell",
            .tool_name = "shell",
            .arguments_json = "{\"command\":\"printf done\"}",
        },
    }));
    try std.testing.expectEqual(@as(u64, 3), try writer.append(alloc, 12, .{
        .tool_result = .{
            .call_id = "call-shell",
            .tool_name = "shell",
            .status = .success,
            .artifact_ref = "sha256:abc",
            .stored_bytes = 4,
            .completeness = .complete,
            .preview = "done",
        },
    }));
    try std.testing.expectEqual(@as(usize, 0), writer.pendingToolCallCount());

    const bytes = try writer.readAllForTest(alloc);
    defer alloc.free(bytes);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, bytes, "\n"));
    try std.testing.expect(std.mem.find(u8, bytes, "commit.pending") == null);
    try std.testing.expect(std.mem.find(u8, bytes, "state_replacement") == null);
}

test "conversation writer repairs only a partial final record and continues" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const file = try tmp.dir.createFile(std.testing.io, "events.jsonl", .{
            .read = true,
            .truncate = true,
        });
        var writer = try ConversationWriter.init(alloc, file);
        defer writer.deinit();
        try writer.appendHistoryTurn(alloc, 10, .{ .assistant = .{
            .user = .{ .text = @constCast("first") },
            .assistant = @constCast("answer"),
        } });
    }
    const valid_bytes = blk: {
        const file = try tmp.dir.openFile(std.testing.io, "events.jsonl", .{});
        defer file.close(std.testing.io);
        break :blk try file.length(std.testing.io);
    };
    {
        const file = try tmp.dir.openFile(std.testing.io, "events.jsonl", .{
            .mode = .read_write,
        });
        defer file.close(std.testing.io);
        try file.writePositionalAll(std.testing.io, "{\"schema_version\":1", valid_bytes);
        try file.sync(std.testing.io);
    }

    const file = try tmp.dir.openFile(std.testing.io, "events.jsonl", .{
        .mode = .read_write,
    });
    var resumed = try ConversationWriter.init(alloc, file);
    defer resumed.deinit();
    try std.testing.expectEqual(@as(u64, 3), resumed.last_seq);
    try std.testing.expectEqual(valid_bytes, resumed.committed_bytes);
    try std.testing.expectEqual(valid_bytes, try resumed.file.length(std.testing.io));
    try resumed.appendHistoryTurn(alloc, 11, .{ .assistant = .{
        .user = .{ .text = @constCast("continued") },
        .assistant = @constCast("done"),
    } });
    try std.testing.expectEqual(@as(u64, 6), resumed.last_seq);
}

test "conversation writer truncates a complete-record partial turn" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var valid_bytes: u64 = 0;
    {
        const file = try tmp.dir.createFile(std.testing.io, "events.jsonl", .{
            .read = true,
            .truncate = true,
        });
        var writer = try ConversationWriter.init(alloc, file);
        defer writer.deinit();
        try writer.appendHistoryTurn(alloc, 10, .{ .assistant = .{
            .user = .{ .text = @constCast("complete") },
            .assistant = @constCast("answer"),
        } });
        valid_bytes = writer.committed_bytes;
        const dangling = try session_event.encodeConversationFrame(alloc, .{
            .seq = 4,
            .timestamp_ms = 11,
            .event = .{ .user = .{ .text = "dangling" } },
        });
        defer alloc.free(dangling);
        try writer.file.writePositionalAll(std.testing.io, dangling, valid_bytes);
        try writer.file.sync(std.testing.io);
    }

    const file = try tmp.dir.openFile(std.testing.io, "events.jsonl", .{
        .mode = .read_write,
    });
    var resumed = try ConversationWriter.init(alloc, file);
    defer resumed.deinit();
    try std.testing.expectEqual(@as(u64, 3), resumed.last_seq);
    try std.testing.expectEqual(valid_bytes, resumed.committed_bytes);
    try std.testing.expectEqual(valid_bytes, try resumed.file.length(std.testing.io));
}

test "conversation writer removes an unfinished turn before a torn final record" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var valid_bytes: u64 = 0;
    {
        const file = try tmp.dir.createFile(std.testing.io, "events.jsonl", .{ .read = true });
        var writer = try ConversationWriter.init(alloc, file);
        defer writer.deinit();
        try writer.appendHistoryTurn(alloc, 10, .{ .assistant = .{
            .user = .{ .text = @constCast("saved request") },
            .assistant = @constCast("saved answer"),
        } });
        valid_bytes = writer.committed_bytes;
        _ = try writer.append(alloc, 11, .{ .user = .{ .text = "unfinished request" } });
        _ = try writer.append(alloc, 11, .{ .tool_call = .{
            .call_id = "unfinished-call",
            .tool_name = "command",
            .arguments_json = "{}",
        } });
        try file.writePositionalAll(std.testing.io, "{\"schema_version\":1", writer.committed_bytes);
    }
    {
        const file = try tmp.dir.openFile(std.testing.io, "events.jsonl", .{ .mode = .read_write });
        var writer = try ConversationWriter.init(alloc, file);
        defer writer.deinit();
        try std.testing.expectEqual(valid_bytes, writer.committed_bytes);
        try std.testing.expectEqual(@as(u64, 3), writer.last_seq);
        try std.testing.expectEqual(@as(usize, 0), writer.pendingToolCallCount());
        try writer.appendHistoryTurn(alloc, 12, .{ .assistant = .{
            .user = .{ .text = @constCast("next request") },
            .assistant = @constCast("next answer"),
        } });
    }
    const file = try tmp.dir.openFile(std.testing.io, "events.jsonl", .{ .mode = .read_write });
    var reopened = try ConversationWriter.init(alloc, file);
    defer reopened.deinit();
    try std.testing.expectEqual(@as(u64, 6), reopened.last_seq);
}

test "conversation writer initialization leaves file ownership with caller on failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "events.jsonl", .{ .read = true });
    try file.writeStreamingAll(std.testing.io, "invalid\n");
    var failed = false;
    if (ConversationWriter.init(std.testing.allocator, file)) |value| {
        var writer = value;
        writer.deinit();
    } else |_| {
        failed = true;
    }
    const still_open = std.c.fcntl(file.handle, std.c.F.GETFD) != -1;
    if (still_open) file.close(std.testing.io);
    try std.testing.expect(failed);
    try std.testing.expect(still_open);
}

test "conversation writer flattens a canonical history turn" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "events.jsonl", .{
        .read = true,
        .truncate = true,
    });
    var writer = try ConversationWriter.init(alloc, file);
    defer writer.deinit();

    var calls = [_]types.ToolCall{.{
        .id = "call-shell",
        .name = "shell",
        .arguments_json = "{\"command\":\"printf done\"}",
        .provider_result = "{\"native\":true}",
        .provenance = .provider_executed,
    }};
    var feedback = [_][]u8{@constCast("inspect the result")};
    var results = [_]types.PersistedToolResult{.{
        .tool_call_id = @constCast("call-shell"),
        .tool_name = @constCast("shell"),
        .status = .success,
        .output = @constCast("done"),
        .output_handle = @constCast("result-shell.txt"),
        .output_bytes = 4,
        .stored_output_bytes = 4,
        .permission_feedback = &feedback,
        .command_output_replay = .{ .available = .{
            .handle = @constCast("fx-command-replay-test.bin"),
            .framed_bytes = 42,
        } },
    }};
    var steps = [_]types.ToolExecutionStep{.{
        .assistant = @constCast("Running it."),
        .tool_calls = &calls,
        .tool_results = &results,
    }};
    var images = [_]types.ImageAttachment{.{
        .id = 1,
        .path = @constCast("/tmp/session/images/image-1-aaaaaaaaaaaaaaaa.bin"),
        .media_type = @constCast("image/png"),
        .snapshot_path = @constCast("/tmp/session/images/image-1-aaaaaaaaaaaaaaaa.bin"),
        .snapshot_sha256 = @constCast("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
    }};
    try writer.appendHistoryTurn(alloc, 10, .{ .assistant = .{
        .user = .{
            .text = @constCast("Run the command."),
            .images = &images,
        },
        .assistant = @constCast("It completed."),
        .execution = .{ .tool_steps = &steps },
    } });

    const bytes = try writer.readAllForTest(alloc);
    defer alloc.free(bytes);
    try std.testing.expectEqual(@as(usize, 6), std.mem.count(u8, bytes, "\n"));
    try std.testing.expectEqual(@as(u64, 6), writer.last_seq);
    try std.testing.expectEqual(@as(usize, 0), writer.pendingToolCallCount());
    try std.testing.expect(std.mem.find(
        u8,
        bytes,
        "\"snapshot_path\":\"images/image-1-aaaaaaaaaaaaaaaa.bin\"",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        bytes,
        "\"snapshot_path\":\"/tmp/session/images",
    ) == null);
}

test "conversation truncation cuts the log, closes an open turn, and drops a paused response" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);

    var initial = try testState(alloc, "truncate-conversation", 10);
    defer initial.deinit(alloc);
    {
        var loaded = try temp.root.startConversationSession(alloc, initial, .{});
        defer loaded.deinit(alloc);
        for ([_][]const u8{ "one", "two", "three" }) |prompt| {
            const turn = try session.makeAssistantTurn(alloc, prompt, "answer");
            defer session.freeHistoryTurn(alloc, turn);
            _ = try loaded.appendEvent(alloc, .{ .history_turn_committed = .{
                .conversation_language = initial.conversation_language,
                .total_input_tokens = 0,
                .total_output_tokens = 0,
                .turn = turn,
            } }, 20);
        }
        _ = try loaded.appendEvent(alloc, .{ .recovery_checkpoint_set = .{ .checkpoint = .{
            .turn_id = 4,
            .user = .{ .text = @constCast("paused") },
            .assistant_source = @constCast(""),
            .cause = .network_interrupted,
            .action = .retrying_request,
            .authority = .{ .provider = .gateway, .model = @constCast("test/model") },
            .requested_fast_mode = false,
            .fast_mode = false,
            .max_provider_attempts = 10,
            .consumed_provider_attempts = 1,
        } } }, 30);

        const writer = &loaded.conversation_writer;
        const plan = try planConversationTruncation(alloc, writer.file, writer.committed_bytes, .{ .archive_turns = 1 });
        try std.testing.expectEqual(@as(usize, 2), plan.dropped_turns);
        try loaded.truncateConversation(alloc, plan, 40);
        try std.testing.expectEqual(plan.boundary.bytes, writer.committed_bytes);
        try std.testing.expectEqual(@as(u64, 3), writer.last_seq);
        try std.testing.expect(!writer.turn_open);
        try std.testing.expect(loaded.state.recovery_checkpoint == null);
        try std.testing.expectEqual(@as(usize, 0), loaded.state.history.len);

        // The writer keeps appending at the cut.
        const turn = try session.makeAssistantTurn(alloc, "four", "answer");
        defer session.freeHistoryTurn(alloc, turn);
        _ = try loaded.appendEvent(alloc, .{ .history_turn_committed = .{
            .conversation_language = initial.conversation_language,
            .total_input_tokens = 0,
            .total_output_tokens = 0,
            .turn = turn,
        } }, 50);
    }
    var reopened = try temp.root.resumeForWrite(alloc, initial.id, .{});
    defer reopened.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), reopened.state.history.len);
    try std.testing.expectEqualStrings("one", reopened.state.history[0].assistant.user.text);
    try std.testing.expectEqualStrings("four", reopened.state.history[1].assistant.user.text);
    try std.testing.expect(reopened.state.recovery_checkpoint == null);

    // A cut inside a checkpointed turn closes that turn as interrupted.
    var checkpointed = try testState(alloc, "truncate-checkpointed-turn", 10);
    defer checkpointed.deinit(alloc);
    var loaded = try temp.root.startConversationSession(alloc, checkpointed, .{});
    defer loaded.deinit(alloc);
    {
        const turn = try session.makeAssistantTurn(alloc, "before", "answer");
        defer session.freeHistoryTurn(alloc, turn);
        _ = try loaded.appendEvent(alloc, .{ .history_turn_committed = .{
            .conversation_language = checkpointed.conversation_language,
            .total_input_tokens = 0,
            .total_output_tokens = 0,
            .turn = turn,
        } }, 20);
    }
    _ = try loaded.commitContextCompaction(alloc, .{
        .summary = @constCast("summary"),
        .removed_turn_count = 1,
        .compaction_count = 1,
    }, .{
        .user = .{ .text = @constCast("open request") },
        .assistant = @constCast(""),
        .execution = .{},
    }, .{ .turns = 1 }, 30);
    try std.testing.expect(loaded.conversation_writer.turn_open);
    {
        const turn = try session.makeAssistantTurn(alloc, "open request", "finished later");
        defer session.freeHistoryTurn(alloc, turn);
        _ = try loaded.appendEvent(alloc, .{ .history_turn_committed = .{
            .conversation_language = checkpointed.conversation_language,
            .total_input_tokens = 0,
            .total_output_tokens = 0,
            .turn = turn,
        } }, 40);
    }
    const writer = &loaded.conversation_writer;
    const plan = try planConversationTruncation(alloc, writer.file, writer.committed_bytes, .{ .archive_turns = 2 });
    try std.testing.expect(plan.boundary.turn_open);
    try std.testing.expectEqual(@as(usize, 3), plan.retained_turns);
    try loaded.truncateConversation(alloc, plan, 50);
    try std.testing.expect(!writer.turn_open);
    const archive = try loadConversationArchive(alloc, &loaded.log.dir);
    defer session.freeHistoryTurnSlice(alloc, archive);
    try std.testing.expectEqual(@as(usize, 3), archive.len);
    try std.testing.expect(archive[1] == .compacted_summary);
    try std.testing.expect(archive[2] == .interrupted);
    try std.testing.expectEqualStrings("open request", archive[2].interrupted.user.text);
}

test "legacy import recovery restores old authority or keeps published current data" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);

    var initial = try testState(alloc, "legacy-import-recovery", 10);
    defer initial.deinit(alloc);
    {
        var loaded = try temp.root.startConversationSession(alloc, initial, .{});
        defer loaded.deinit(alloc);
        const turn = try session.makeAssistantTurn(alloc, "question", "answer");
        defer session.freeHistoryTurn(alloc, turn);
        _ = try loaded.appendEvent(alloc, .{ .history_turn_committed = .{
            .conversation_language = initial.conversation_language,
            .total_input_tokens = 0,
            .total_output_tokens = 0,
            .turn = turn,
        } }, 20);
    }

    {
        var writable = try temp.root.openWritableSessionDir(
            alloc,
            initial.id,
            lock_deadline_ms,
        );
        defer writable.deinit(alloc);
        const original = try readManagedFileAlloc(
            alloc,
            &writable.dir,
            events_file,
            session_event.event_frame_max_bytes,
        );
        defer alloc.free(original);
        try writable.dir.dir.rename(
            events_file,
            writable.dir.dir,
            conversation_migration_backup_file,
            io_mod.getIo(),
        );
        var replacement = try createManagedFile(&writable.dir, events_file);
        try replacement.writeStreamingAll(io_mod.getIo(), "new-but-unpublished\n");
        replacement.close(io_mod.getIo());
        var abandoned = try createManagedFile(
            &writable.dir,
            conversation_migration_temp_file,
        );
        abandoned.close(io_mod.getIo());
        try io_mod.durableReplaceVerified(
            alloc,
            &writable.dir,
            manifest_file,
            "{\"schema_version\":3}\n",
        );

        try recoverInterruptedLegacyImport(alloc, &writable);
        const restored = try readManagedFileAlloc(
            alloc,
            &writable.dir,
            events_file,
            session_event.event_frame_max_bytes,
        );
        defer alloc.free(restored);
        try std.testing.expectEqualStrings(original, restored);
        try std.testing.expect(!try legacyImportRecoveryNeeded(&writable.dir));
        try std.testing.expect(!try entryExists(
            &writable.dir,
            conversation_migration_temp_file,
        ));
    }

    // Recreate a current-format session to prove that a crash after metadata
    // publication keeps the new log and only removes the old backup.
    try temp.root.sessions.?.dir.deleteTree(io_mod.getIo(), initial.id);
    {
        var loaded = try temp.root.startConversationSession(alloc, initial, .{});
        defer loaded.deinit(alloc);
    }
    {
        var writable = try temp.root.openWritableSessionDir(
            alloc,
            initial.id,
            lock_deadline_ms,
        );
        defer writable.deinit(alloc);
        const current = try readManagedFileAlloc(
            alloc,
            &writable.dir,
            events_file,
            session_event.event_frame_max_bytes,
        );
        defer alloc.free(current);
        var backup = try createManagedFile(
            &writable.dir,
            conversation_migration_backup_file,
        );
        try backup.writeStreamingAll(io_mod.getIo(), "old\n");
        backup.close(io_mod.getIo());

        try recoverInterruptedLegacyImport(alloc, &writable);
        const retained = try readManagedFileAlloc(
            alloc,
            &writable.dir,
            events_file,
            session_event.event_frame_max_bytes,
        );
        defer alloc.free(retained);
        try std.testing.expectEqualStrings(current, retained);
        try std.testing.expect(!try legacyImportRecoveryNeeded(&writable.dir));
    }
}

test "legacy import migrates permissions before publishing controls" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "legacy-permission-import", 20);
    defer initial.deinit(alloc);
    initial.permission_state.version = 1;
    const history = [_]session.HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("existing question") },
        .assistant = @constCast("existing answer"),
    } }};
    initial.history = try session.snapshotOwnedContextHistory(alloc, &history, 0, 0);
    try temp.root.sessions.?.dir.createDir(std.testing.io, initial.id, private_dir_permissions);
    {
        var writable = try temp.root.openWritableSessionDir(alloc, initial.id, lock_deadline_ms);
        var writable_owned = true;
        defer if (writable_owned) writable.deinit(alloc);
        try io_mod.durableReplaceVerified(alloc, &writable.dir, manifest_file, "{\"schema_version\":3}\n");
        var migrated = try importLegacySnapshotState(alloc, &writable, initial, 3, 0, null);
        writable_owned = false;
        defer migrated.deinit(alloc);
        try std.testing.expectEqual(@as(u8, 2), migrated.state.permission_state.version);
        try std.testing.expectEqual(@as(u8, 1), initial.permission_state.version);
        try std.testing.expectEqualStrings("existing answer", migrated.state.history[0].assistant.assistant);
    }
    var reopened = try temp.root.resumeForWrite(alloc, initial.id, .{});
    defer reopened.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 2), reopened.state.permission_state.version);
    try std.testing.expectEqualStrings("existing question", reopened.state.history[0].assistant.user.text);
}

test "legacy import omits empty file paths without losing execution history" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "legacy-empty-file-import", 20);
    defer initial.deinit(alloc);
    var calls = [_]types.ToolCall{.{ .id = "recorded-read", .name = "read_file", .arguments_json = "{\"path\":\"source.txt\"}" }};
    var results = [_]types.PersistedToolResult{.{
        .tool_call_id = @constCast("recorded-read"),
        .tool_name = @constCast("read_file"),
        .status = .success,
        .output = @constCast("recorded output"),
        .output_bytes = 15,
        .stored_output_bytes = 15,
    }};
    var steps = [_]types.ToolExecutionStep{.{ .tool_calls = &calls, .tool_results = &results }};
    var files = [_]types.FileEvidence{
        .{ .path = @constCast("source.txt"), .tool_call_id = @constCast("recorded-read"), .tool_name = @constCast("read_file") },
        .{ .path = @constCast(""), .tool_call_id = @constCast("recorded-read"), .tool_name = @constCast("read_file") },
        .{ .path = @constCast("before.txt"), .new_path = @constCast("after.txt"), .tool_call_id = @constCast("recorded-read"), .tool_name = @constCast("read_file") },
    };
    const history = [_]session.HistoryTurn{
        .{ .assistant = .{ .user = .{ .text = @constCast("read existing file") }, .assistant = @constCast("read finished"), .execution = .{ .tool_steps = &steps, .files = &files } } },
        .{ .interrupted = .{ .user = .{ .text = @constCast("cancelled follow-up") }, .execution = .{ .files = files[1..2] } } },
    };
    try std.testing.expectError(error.InvalidConversationEvent, session_event.encodeConversationFrame(alloc, .{
        .seq = 1,
        .timestamp_ms = 20,
        .event = .{ .turn_completed = .{ .files = &files } },
    }));
    initial.history = try session.snapshotOwnedContextHistory(alloc, &history, 0, 0);
    try temp.root.sessions.?.dir.createDir(std.testing.io, initial.id, private_dir_permissions);
    {
        var writable = try temp.root.openWritableSessionDir(alloc, initial.id, lock_deadline_ms);
        var writable_owned = true;
        defer if (writable_owned) writable.deinit(alloc);
        try io_mod.durableReplaceVerified(alloc, &writable.dir, manifest_file, "{\"schema_version\":3}\n");
        var migrated = try importLegacySnapshotState(alloc, &writable, initial, 3, 0, null);
        writable_owned = false;
        defer migrated.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 3), initial.history[0].assistant.execution.files.len);
        try std.testing.expectEqualStrings("", initial.history[0].assistant.execution.files[1].path);
    }
    var reopened = try temp.root.resumeForWrite(alloc, initial.id, .{});
    defer reopened.deinit(alloc);
    const execution = reopened.state.history[0].assistant.execution;
    try std.testing.expectEqual(@as(usize, 2), reopened.state.history.len);
    try std.testing.expectEqual(@as(usize, 1), execution.tool_steps.len);
    try std.testing.expectEqualStrings("recorded-read", execution.tool_steps[0].tool_calls[0].id);
    try std.testing.expectEqualStrings("recorded output", execution.tool_steps[0].tool_results[0].preview.?);
    try std.testing.expectEqual(@as(usize, 2), execution.files.len);
    try std.testing.expectEqualStrings("source.txt", execution.files[0].path);
    try std.testing.expectEqualStrings("before.txt", execution.files[1].path);
    try std.testing.expectEqualStrings("after.txt", execution.files[1].new_path.?);
    try std.testing.expectEqual(@as(usize, 0), reopened.state.history[1].interrupted.execution.files.len);
    try std.testing.expectEqualStrings("cancelled follow-up", reopened.state.history[1].interrupted.user.text);
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
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

test "legacy import preserves the active retained tail and complete archive" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "legacy-retained-tail", 10);
    defer initial.deinit(alloc);
    const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII=";
    var images = [_]types.ToolImage{.{ .data = @constCast(png), .mime_type = @constCast("image/png") }};
    var calls = [_]types.ToolCall{.{ .id = "image-call", .name = "mcp_browser", .arguments_json = "{}" }};
    var results = [_]types.PersistedToolResult{.{
        .tool_call_id = @constCast("image-call"),
        .tool_name = @constCast("mcp_browser"),
        .status = .success,
        .output = @constCast(""),
        .output_bytes = 0,
        .stored_output_bytes = 0,
        .tool_images = &images,
    }};
    var steps = [_]types.ToolExecutionStep{.{ .tool_calls = &calls, .tool_results = &results }};
    const history = [_]session.HistoryTurn{
        .{ .assistant = .{ .user = .{ .text = @constCast("removed request") }, .assistant = @constCast("removed answer") } },
        .{ .compacted_summary = .{ .summary = @constCast("<context_handoff>earlier summary</context_handoff>"), .removed_turn_count = 1, .compaction_count = 1 } },
        .{ .assistant = .{ .user = .{ .text = @constCast("retained request") }, .assistant = @constCast("retained answer"), .execution = .{ .tool_steps = &steps } } },
        .{ .compacted_summary = .{ .summary = @constCast("<context_handoff>active summary</context_handoff>"), .removed_turn_count = 1, .compaction_count = 2 } },
        .{ .assistant = .{ .user = .{ .text = @constCast("later request") }, .assistant = @constCast("later answer") } },
    };
    initial.history = try session.snapshotOwnedContextHistory(alloc, &history, 0, 0);
    initial.context_history_start = 3;
    try temp.root.sessions.?.dir.createDir(std.testing.io, initial.id, private_dir_permissions);
    {
        var writable = try temp.root.openWritableSessionDir(alloc, initial.id, lock_deadline_ms);
        var writable_owned = true;
        defer if (writable_owned) writable.deinit(alloc);
        try io_mod.durableReplaceVerified(alloc, &writable.dir, manifest_file, "{\"schema_version\":3}\n");
        var migrated = try importLegacySnapshotState(alloc, &writable, initial, 3, 0, null);
        writable_owned = false;
        defer migrated.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 3), migrated.state.history.len);
        try std.testing.expectEqualStrings(history[3].compacted_summary.summary, migrated.state.history[0].compacted_summary.summary);
        try std.testing.expectEqualStrings("retained answer", migrated.state.history[1].assistant.assistant);
        try std.testing.expectEqualStrings("later answer", migrated.state.history[2].assistant.assistant);
        const archive = try loadConversationArchive(alloc, &migrated.log.dir);
        defer session.freeHistoryTurnSlice(alloc, archive);
        try std.testing.expectEqual(history.len, archive.len);
        try std.testing.expectEqualStrings("removed answer", archive[0].assistant.assistant);
        try std.testing.expectEqualStrings(history[1].compacted_summary.summary, archive[1].compacted_summary.summary);
    }
    var resumed = try temp.root.resumeForWrite(alloc, initial.id, .{});
    defer resumed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), resumed.state.history.len);
    try std.testing.expectEqualStrings(history[3].compacted_summary.summary, resumed.state.history[0].compacted_summary.summary);
    try std.testing.expectEqualStrings("retained answer", resumed.state.history[1].assistant.assistant);
    try std.testing.expectEqualStrings("later answer", resumed.state.history[2].assistant.assistant);
    const result = resumed.state.history[1].assistant.execution.tool_steps[0].tool_results[0];
    try std.testing.expectEqual(@as(usize, 0), result.tool_images.len);
    try std.testing.expect(result.tool_image_handle != null);
    const resumed_path = try io_mod.dirRealpathAlloc(alloc, resumed.log.dir.dir, ".");
    defer alloc.free(resumed_path);
    var capability = try session_child_store.SessionChildCapability.init(alloc, resumed.log.dir.dir, resumed_path, .read_only);
    defer capability.deinit();
    const stored_images = try result_store.loadToolImages(alloc, &capability, result.tool_image_handle.?);
    defer types.freeToolImages(alloc, stored_images);
    try std.testing.expectEqual(@as(usize, 1), stored_images.len);
    try std.testing.expectEqualStrings(png, stored_images[0].data);
}

test "legacy import preserves published events and active recovery after metadata sync failure" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "legacy-metadata-sync-failure", 10);
    defer initial.deinit(alloc);
    const history = try alloc.alloc(session.HistoryTurn, 1);
    history[0] = try session.makeAssistantTurn(alloc, "saved request", "saved answer");
    initial.history = history;
    initial.recovery_checkpoint = try (session_codec.RecoveryCheckpoint{
        .turn_id = 7,
        .user = .{ .text = @constCast("continue the next request") },
        .assistant_source = @constCast("partial"),
        .cause = .network_interrupted,
        .action = .retrying_request,
        .authority = .{ .provider = .gateway, .model = @constCast("test/model") },
        .requested_fast_mode = false,
        .fast_mode = false,
        .max_provider_attempts = 3,
        .consumed_provider_attempts = 1,
    }).dupe(alloc);
    try temp.root.sessions.?.dir.createDir(std.testing.io, initial.id, private_dir_permissions);
    {
        var writable = try temp.root.openWritableSessionDir(alloc, initial.id, lock_deadline_ms);
        defer writable.deinit(alloc);
        try io_mod.durableReplaceVerified(alloc, &writable.dir, manifest_file, "{\"schema_version\":3}\n");
        try io_mod.durableReplaceVerified(alloc, &writable.dir, events_file, "legacy-source\n");
        const Fail = struct {
            fn syncDir(_: ?*anyopaque, _: std.Io.Dir) anyerror!void {
                return error.InjectedSyncFailure;
            }
        };
        try std.testing.expectError(error.DurableReplacePostRenameFailed, importLegacySnapshotStateWithOps(
            alloc,
            &writable,
            initial,
            3,
            14,
            null,
            .{ .sync_dir = Fail.syncDir },
        ));
        try std.testing.expect(try hasConversationMetadata(alloc, &writable.dir));
        try std.testing.expect(try legacyImportRecoveryNeeded(&writable.dir));
        try recoverInterruptedLegacyImport(alloc, &writable);
    }
    var resumed = try temp.root.resumeForWrite(alloc, initial.id, .{});
    defer resumed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), resumed.state.history.len);
    try std.testing.expectEqualStrings("saved answer", resumed.state.history[0].assistant.assistant);
    try std.testing.expectEqual(@as(u64, 7), resumed.state.recovery_checkpoint.?.turn_id);
}

test "conversation storage creates only metadata and event log" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var directory = io_mod.VerifiedDir{
        .dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true }),
    };
    defer directory.close();

    var writer = try createConversationStorage(alloc, &directory, .{
        .id = "session-1",
        .origin_workspace_root = "/tmp/origin",
        .workspace_root = "/tmp/current",
        .created_at_ms = 10,
        .updated_at_ms = 10,
        .conversation_language = "en",
        .provider = "gateway",
        .model = "openai/gpt-5.6",
        .effort = "high",
        .fast_mode = false,
    });
    defer writer.deinit();

    var count: usize = 0;
    var saw_events = false;
    var saw_metadata = false;
    var iterator = directory.dir.iterate();
    while (try iterator.next(std.testing.io)) |entry| {
        count += 1;
        if (std.mem.eql(u8, entry.name, "events.jsonl")) saw_events = true;
        if (std.mem.eql(u8, entry.name, "session.json")) saw_metadata = true;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expect(saw_events);
    try std.testing.expect(saw_metadata);
}

test "root starts a cache-free conversation session" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "cache-free-session", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startConversationSession(alloc, initial, .{});
    defer loaded.deinit(alloc);

    var count: usize = 0;
    var saw_events = false;
    var saw_metadata = false;
    var saw_writer_lock = false;
    var saw_permissions = false;
    var saw_usage = false;
    var iterator = loaded.log.dir.dir.iterate();
    while (try iterator.next(std.testing.io)) |entry| {
        count += 1;
        if (std.mem.eql(u8, entry.name, "events.jsonl")) saw_events = true;
        if (std.mem.eql(u8, entry.name, "session.json")) saw_metadata = true;
        if (std.mem.eql(u8, entry.name, "session.lock")) saw_writer_lock = true;
        if (std.mem.eql(u8, entry.name, "permissions.json")) saw_permissions = true;
        if (std.mem.eql(u8, entry.name, "usage-v2.json")) saw_usage = true;
    }
    try std.testing.expectEqual(@as(usize, 5), count);
    try std.testing.expect(saw_events);
    try std.testing.expect(saw_metadata);
    try std.testing.expect(saw_writer_lock);
    try std.testing.expect(saw_permissions);
    try std.testing.expect(saw_usage);
}

test "conversation writer appends without duplicating live history" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "conversation-append", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startConversationSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    const turn = types.HistoryTurn{ .assistant = .{
        .user = .{ .text = @constCast("question") },
        .assistant = @constCast("answer"),
    } };

    _ = try loaded.appendEvent(
        alloc,
        .{ .history_turn_committed = .{
            .conversation_language = .literal("en"),
            .total_input_tokens = 1,
            .total_output_tokens = 1,
            .turn = turn,
        } },
        20,
    );

    try std.testing.expectEqual(@as(usize, 0), loaded.state.history.len);
    try std.testing.expectEqual(@as(u64, 3), loaded.conversation_writer.last_seq);
    var count: usize = 0;
    var iterator = loaded.log.dir.dir.iterate();
    while (try iterator.next(std.testing.io)) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 5), count);
}

test "cache-free conversation session resumes from metadata and JSONL" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "conversation-resume", 10);
    defer initial.deinit(alloc);
    {
        var loaded = try temp.root.startConversationSession(alloc, initial, .{});
        defer loaded.deinit(alloc);
        _ = try loaded.appendEvent(
            alloc,
            .{ .history_turn_committed = .{
                .conversation_language = .literal("en"),
                .total_input_tokens = 1,
                .total_output_tokens = 1,
                .turn = .{ .assistant = .{
                    .user = .{ .text = @constCast("question") },
                    .assistant = @constCast("answer"),
                } },
            } },
            20,
        );
    }

    var resumed = try temp.root.loadReadOnly(alloc, initial.id, .{});
    defer resumed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), resumed.history.len);
    try std.testing.expectEqualStrings("question", resumed.history[0].assistant.user.text);
    try std.testing.expectEqualStrings("answer", resumed.history[0].assistant.assistant);
}

test "conversation preserves standalone replies across completion and interruption" {
    const alloc = std.testing.allocator;
    const Outcome = enum { completed, cancelled, failed, active_call };
    for ([_]bool{ false, true }) |with_replay| {
        for (std.enums.values(Outcome)) |outcome| {
            var temp = try TempRoot.init(alloc);
            defer temp.deinit(alloc);
            var initial = try testState(alloc, "standalone-replies", 10);
            defer initial.deinit(alloc);
            const replay: types.ProviderReplay = .{
                .source = .{ .provider = .gateway, .model = "test-model" },
                .parts_json = "[{\"type\":\"reasoning\",\"text\":\"private state\"}]",
            };
            var steps = [_]types.ToolExecutionStep{.{
                .assistant = @constCast("earlier reply"),
                .provider_replay = if (with_replay) replay else null,
            }};
            const user: types.UserTurn = .{ .text = @constCast("request") };
            const turn: types.HistoryTurn = if (outcome == .completed) .{ .assistant = .{
                .user = user,
                .assistant = @constCast("current reply"),
                .execution = .{ .tool_steps = &steps },
            } } else .{ .interrupted = .{
                .user = user,
                .assistant = @constCast("partial reply"),
                .execution = .{ .tool_steps = &steps },
                .terminal_reason = if (outcome == .failed) .failed else .cancelled,
                .tool_call = if (outcome == .active_call) .{ .id = "pending", .name = "read_file", .arguments_json = "{\"path\":\"file\"}" } else null,
            } };
            {
                var loaded = try temp.root.startConversationSession(alloc, initial, .{});
                defer loaded.deinit(alloc);
                _ = try loaded.appendEvent(alloc, .{ .history_turn_committed = .{
                    .conversation_language = .literal("en"),
                    .total_input_tokens = 1,
                    .total_output_tokens = 1,
                    .turn = turn,
                } }, 20);
            }
            var resumed = try temp.root.loadReadOnly(alloc, initial.id, .{});
            defer resumed.deinit(alloc);
            try std.testing.expectEqual(@as(usize, 1), resumed.history.len);
            const execution = switch (resumed.history[0]) {
                .assistant => |entry| blk: {
                    try std.testing.expectEqual(Outcome.completed, outcome);
                    try std.testing.expectEqualStrings("current reply", entry.assistant);
                    break :blk entry.execution;
                },
                .interrupted => |entry| blk: {
                    try std.testing.expectEqualStrings("partial reply", entry.assistant.?);
                    try std.testing.expectEqual(outcome == .active_call, entry.tool_call != null);
                    try std.testing.expectEqual(if (outcome == .failed) types.InterruptedTerminalReason.failed else .cancelled, entry.terminal_reason);
                    break :blk entry.execution;
                },
                else => return error.TestUnexpectedResult,
            };
            try std.testing.expectEqual(@as(usize, 1), execution.tool_steps.len);
            try std.testing.expectEqualStrings("earlier reply", execution.tool_steps[0].assistant.?);
            try std.testing.expectEqual(with_replay, execution.tool_steps[0].provider_replay != null);
            if (execution.tool_steps[0].provider_replay) |saved| try std.testing.expectEqualStrings(replay.parts_json, saved.parts_json);
            try std.testing.expectEqual(@as(usize, 0), execution.tool_steps[0].tool_calls.len);
        }
    }
}

test "standalone steering round trip preserves step boundaries" {
    try checkStandaloneSteering(false);
}

test "standalone steering checkpoint preserves step boundaries" {
    try checkStandaloneSteering(true);
}

fn checkStandaloneSteering(checkpoint: bool) !void {
    const alloc = std.testing.allocator;
    for ([_]bool{ false, true }) |with_replay| {
        var temp = try TempRoot.init(alloc);
        defer temp.deinit(alloc);
        var initial = try testState(alloc, "standalone-steering", 10);
        defer initial.deinit(alloc);
        const replay: types.ProviderReplay = .{
            .source = .{ .provider = .gateway, .model = "test-model" },
            .parts_json = "[{\"type\":\"reasoning\",\"text\":\"private state\"}]",
        };
        var steps = [_]types.ToolExecutionStep{.{
            .assistant = @constCast("earlier reply"),
            .provider_replay = if (with_replay) replay else null,
        }};
        var steering = [_]types.PersistedSteering{.{
            .text = @constCast("human update"),
            .after_tool_step_count = 1,
        }};
        const user: types.UserTurn = .{ .text = @constCast("request") };
        {
            var loaded = try temp.root.startConversationSession(alloc, initial, .{});
            defer loaded.deinit(alloc);
            if (checkpoint) {
                _ = try loaded.commitContextCompaction(alloc, .{
                    .summary = @constCast("<context_handoff>Earlier reply.</context_handoff>"),
                    .removed_turn_count = 0,
                    .compaction_count = 1,
                }, .{
                    .user = user,
                    .assistant = @constCast(""),
                    .execution = .{ .tool_steps = &steps, .steering = &steering },
                }, .{ .tool_steps = 1 }, 20);
                steering[0].after_tool_step_count = 0;
            }
            _ = try loaded.appendEvent(alloc, .{ .history_turn_committed = .{
                .conversation_language = .literal("en"),
                .total_input_tokens = 1,
                .total_output_tokens = 1,
                .turn = .{ .assistant = .{
                    .user = user,
                    .assistant = @constCast("final reply"),
                    .execution = .{
                        .tool_steps = if (checkpoint) &.{} else &steps,
                        .steering = &steering,
                    },
                } },
            } }, 30);
        }
        var resumed = try temp.root.resumeForWrite(alloc, initial.id, .{});
        defer resumed.deinit(alloc);
        try std.testing.expectEqual(@as(usize, if (checkpoint) 2 else 1), resumed.state.history.len);
        const active = resumed.state.history[if (checkpoint) 1 else 0].assistant;
        try std.testing.expectEqualStrings("final reply", active.assistant);
        try std.testing.expectEqual(@as(usize, if (checkpoint) 0 else 1), active.execution.tool_steps.len);
        try std.testing.expectEqual(@as(usize, 1), active.execution.steering.len);
        try std.testing.expectEqual(@as(usize, if (checkpoint) 0 else 1), active.execution.steering[0].after_tool_step_count);
        try std.testing.expect(active.execution.steering[0].assistant_prefix == null);
        try std.testing.expectEqualStrings("human update", active.execution.steering[0].text);
        const archive = try loadConversationHistoryRange(alloc, &resumed.log.dir, 0, 1);
        defer session.freeHistoryTurnSlice(alloc, archive);
        const execution = archive[0].assistant.execution;
        try std.testing.expectEqual(@as(usize, 1), execution.tool_steps.len);
        try std.testing.expectEqualStrings("earlier reply", execution.tool_steps[0].assistant.?);
        try std.testing.expectEqual(with_replay, execution.tool_steps[0].provider_replay != null);
        if (execution.tool_steps[0].provider_replay) |saved| try std.testing.expectEqualStrings(replay.parts_json, saved.parts_json);
        try std.testing.expectEqual(@as(usize, 1), execution.steering.len);
        try std.testing.expectEqual(@as(usize, 1), execution.steering[0].after_tool_step_count);
        try std.testing.expect(execution.steering[0].assistant_prefix == null);
    }
}

test "legacy steering prefix records retain their original boundary" {
    const alloc = std.testing.allocator;
    for ([_]u8{ 1, 2 }) |schema_version| {
        const bytes = try std.fmt.allocPrint(
            alloc,
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
    for ([_]bool{ false, true }) |standalone_response| try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
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

test "standalone checkpoint boundaries do not create empty replies" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "standalone-checkpoint", 10);
    defer initial.deinit(alloc);
    var steps = [_]types.ToolExecutionStep{
        .{ .assistant = @constCast("older reply") },
        .{ .assistant = @constCast("recent reply") },
    };
    const user: types.UserTurn = .{ .text = @constCast("request") };
    {
        var loaded = try temp.root.startConversationSession(alloc, initial, .{});
        defer loaded.deinit(alloc);
        _ = try loaded.commitContextCompaction(alloc, .{
            .summary = @constCast("<context_handoff>Earlier context.</context_handoff>"),
            .removed_turn_count = 0,
            .compaction_count = 1,
        }, .{ .user = user, .assistant = @constCast(""), .execution = .{ .tool_steps = &steps } }, .{ .tool_steps = 1 }, 20);
        _ = try loaded.appendEvent(alloc, .{ .history_turn_committed = .{
            .conversation_language = .literal("en"),
            .total_input_tokens = 1,
            .total_output_tokens = 1,
            .turn = .{ .assistant = .{ .user = user, .assistant = @constCast("final reply"), .execution = .{ .tool_steps = steps[1..] } } },
        } }, 30);
    }
    var resumed = try temp.root.resumeForWrite(alloc, initial.id, .{});
    defer resumed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), resumed.state.history.len);
    const active = resumed.state.history[1].assistant;
    try std.testing.expectEqual(@as(usize, 1), active.execution.tool_steps.len);
    try std.testing.expectEqualStrings("recent reply", active.execution.tool_steps[0].assistant.?);
    try std.testing.expectEqualStrings("final reply", active.assistant);
    const archive = try loadConversationHistoryRange(alloc, &resumed.log.dir, 0, 1);
    defer session.freeHistoryTurnSlice(alloc, archive);
    try std.testing.expectEqual(@as(usize, 2), archive[0].assistant.execution.tool_steps.len);
    try std.testing.expectEqualStrings("older reply", archive[0].assistant.execution.tool_steps[0].assistant.?);
    try std.testing.expectEqualStrings("recent reply", archive[0].assistant.execution.tool_steps[1].assistant.?);
}

test "cache-free writable resume continues the conversation sequence" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "conversation-write-resume", 10);
    defer initial.deinit(alloc);
    {
        var loaded = try temp.root.startConversationSession(alloc, initial, .{});
        defer loaded.deinit(alloc);
        _ = try loaded.appendEvent(alloc, .{ .history_turn_committed = .{
            .conversation_language = .literal("en"),
            .total_input_tokens = 1,
            .total_output_tokens = 1,
            .turn = .{ .assistant = .{
                .user = .{ .text = @constCast("first question") },
                .assistant = @constCast("first answer"),
            } },
        } }, 20);
    }
    {
        var resumed = try temp.root.resumeForWrite(alloc, initial.id, .{});
        defer resumed.deinit(alloc);
        try std.testing.expectEqual(@as(u64, 3), resumed.conversation_writer.last_seq);
        _ = try resumed.appendEvent(alloc, .{ .history_turn_committed = .{
            .conversation_language = .literal("en"),
            .total_input_tokens = 2,
            .total_output_tokens = 2,
            .turn = .{ .assistant = .{
                .user = .{ .text = @constCast("second question") },
                .assistant = @constCast("second answer"),
            } },
        } }, 30);
    }

    var loaded = try temp.root.loadReadOnly(alloc, initial.id, .{});
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), loaded.history.len);
    try std.testing.expectEqualStrings("second answer", loaded.history[1].assistant.assistant);
}

test "cache-free metadata changes rewrite metadata without conversation records" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "conversation-metadata", 10);
    defer initial.deinit(alloc);
    var committed_bytes: u64 = 0;
    {
        var loaded = try temp.root.startConversationSession(alloc, initial, .{});
        defer loaded.deinit(alloc);
        committed_bytes = loaded.conversation_writer.committed_bytes;
        _ = try loaded.appendEvent(alloc, .{ .preferences_changed = .{
            .model = @constCast("updated/model"),
            .fast_mode = true,
        } }, 20);
        try std.testing.expect(try loaded.renameConversation(alloc, "renamed session"));
        const title = (try loaded.conversationTitle(alloc)) orelse
            return error.TestExpectedConversationTitle;
        defer alloc.free(title);
        try std.testing.expectEqualStrings("renamed session", title);
        try std.testing.expectEqual(
            committed_bytes,
            loaded.conversation_writer.committed_bytes,
        );
    }

    var resumed = try temp.root.loadReadOnly(alloc, initial.id, .{});
    defer resumed.deinit(alloc);
    try std.testing.expectEqualStrings("updated/model", resumed.preferences.model);
    try std.testing.expect(resumed.preferences.fast_mode);
}

test "cache-free usage checkpoints stay outside conversation history" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "conversation-usage", 10);
    defer initial.deinit(alloc);
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    try usage.recordCommittedLines(9, 4);
    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    var committed_bytes: u64 = 0;
    {
        var loaded = try temp.root.startConversationSession(alloc, initial, .{});
        defer loaded.deinit(alloc);
        committed_bytes = loaded.conversation_writer.committed_bytes;
        _ = try loaded.appendEvent(alloc, .{
            .usage_checkpointed = .{ .usage = snapshot },
        }, 20);
        try std.testing.expectEqual(
            committed_bytes,
            loaded.conversation_writer.committed_bytes,
        );
        try std.testing.expect(loaded.freshly_started);
    }

    var resumed = try temp.root.loadReadOnly(alloc, initial.id, .{});
    defer resumed.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 9), resumed.usage.?.lines_added);
    try std.testing.expectEqual(@as(u64, 4), resumed.usage.?.lines_removed);
    try std.testing.expectEqual(@as(usize, 0), resumed.history.len);
}

test "cache-free recovery checkpoint resumes and clears independently" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "conversation-recovery", 10);
    defer initial.deinit(alloc);
    const checkpoint = session_codec.RecoveryCheckpoint{
        .turn_id = 7,
        .user = .{ .text = @constCast("continue the request") },
        .assistant_source = @constCast("partial"),
        .cause = .network_interrupted,
        .action = .retrying_request,
        .authority = .{ .provider = .gateway, .model = @constCast("test/model") },
        .requested_fast_mode = false,
        .fast_mode = false,
        .max_provider_attempts = 3,
        .consumed_provider_attempts = 1,
    };
    {
        var loaded = try temp.root.startConversationSession(alloc, initial, .{});
        defer loaded.deinit(alloc);
        _ = try loaded.appendEvent(alloc, .{
            .recovery_checkpoint_set = .{ .checkpoint = checkpoint },
        }, 20);
    }
    {
        var resumed = try temp.root.resumeForWrite(alloc, initial.id, .{});
        defer resumed.deinit(alloc);
        try std.testing.expectEqual(@as(u64, 7), resumed.state.recovery_checkpoint.?.turn_id);
        _ = try resumed.appendEvent(alloc, .{
            .recovery_checkpoint_cleared = .{},
        }, 30);
    }

    var cleared = try temp.root.loadReadOnly(alloc, initial.id, .{});
    defer cleared.deinit(alloc);
    try std.testing.expectEqual(@as(?session_codec.RecoveryCheckpoint, null), cleared.recovery_checkpoint);
}

test "committed conversation supersedes recovery after interrupted cleanup" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "conversation-stale-recovery", 10);
    defer initial.deinit(alloc);
    const checkpoint = session_codec.RecoveryCheckpoint{
        .turn_id = 7,
        .user = .{ .text = @constCast("continue the request") },
        .assistant_source = @constCast("partial"),
        .cause = .network_interrupted,
        .action = .retrying_request,
        .authority = .{ .provider = .gateway, .model = @constCast("test/model") },
        .requested_fast_mode = false,
        .fast_mode = false,
        .max_provider_attempts = 3,
        .consumed_provider_attempts = 1,
    };
    {
        var loaded = try temp.root.startConversationSession(alloc, initial, .{});
        defer loaded.deinit(alloc);
        _ = try loaded.appendEvent(alloc, .{
            .recovery_checkpoint_set = .{ .checkpoint = checkpoint },
        }, 20);
        // Model a process death after the durable conversation append but
        // before recovery cleanup by using the writer at that boundary.
        try loaded.conversation_writer.appendHistoryTurn(alloc, 30, .{ .assistant = .{
            .user = checkpoint.user,
            .assistant = @constCast("finished answer"),
        } });
    }
    var resumed = try temp.root.resumeForWrite(alloc, initial.id, .{});
    defer resumed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), resumed.state.history.len);
    try std.testing.expectEqual(@as(?session_codec.RecoveryCheckpoint, null), resumed.state.recovery_checkpoint);
}

test "mid-turn checkpoint resumes only its suffix while preserving archived tool execution" {
    const alloc = std.testing.allocator;
    for ([_]bool{ false, true }) |finish_turn| {
        var temp = try TempRoot.init(alloc);
        defer temp.deinit(alloc);
        var initial = try testState(alloc, "conversation-active-checkpoint", 10);
        defer initial.deinit(alloc);
        {
            var loaded = try temp.root.startConversationSession(alloc, initial, .{});
            defer loaded.deinit(alloc);
            for ([_][]const u8{ "first-summarized-call", "second-summarized-call" }, 0..) |call_id, index| {
                var calls = [_]types.ToolCall{.{ .id = call_id, .name = "command", .arguments_json = "{}" }};
                var results = [_]types.PersistedToolResult{.{
                    .tool_call_id = @constCast(call_id),
                    .tool_name = @constCast("command"),
                    .status = .success,
                    .output = @constCast("summarized output"),
                    .output_handle = @constCast("saved-result.log"),
                    .output_bytes = 16,
                    .stored_output_bytes = 16,
                }};
                var steps = [_]types.ToolExecutionStep{.{ .tool_calls = &calls, .tool_results = &results }};
                _ = try loaded.commitContextCompaction(alloc, .{
                    .summary = @constCast("<context_handoff>prior work completed</context_handoff>"),
                    .removed_turn_count = 0,
                    .compaction_count = index + 1,
                }, .{
                    .user = .{ .text = @constCast("complete the request") },
                    .assistant = @constCast(""),
                    .execution = .{ .tool_steps = &steps },
                }, null, 20);
            }
            if (finish_turn) {
                _ = try loaded.appendEvent(alloc, .{ .history_turn_committed = .{
                    .conversation_language = initial.conversation_language,
                    .total_input_tokens = 0,
                    .total_output_tokens = 0,
                    .turn = .{ .assistant = .{
                        .user = .{ .text = @constCast("complete the request") },
                        .assistant = @constCast("remaining answer"),
                    } },
                } }, 30);
            } else {
                const writer = &loaded.conversation_writer;
                const partial_suffix = try session_event.encodeConversationFrame(alloc, .{
                    .seq = writer.last_seq + 1,
                    .timestamp_ms = 30,
                    .event = .{ .assistant = .{ .text = "unfinished suffix" } },
                });
                defer alloc.free(partial_suffix);
                try writer.file.writePositionalAll(std.testing.io, partial_suffix, writer.committed_bytes);
                try writer.file.writePositionalAll(std.testing.io, "{\"schema_version\":1", writer.committed_bytes + partial_suffix.len);
            }
        }
        var resumed = try temp.root.resumeForWrite(alloc, initial.id, .{});
        defer resumed.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 2), resumed.state.history.len);
        try std.testing.expect(resumed.state.history[0] == .compacted_summary);
        const title = (try resumed.conversationTitle(alloc)).?;
        defer alloc.free(title);
        try std.testing.expectEqualStrings("complete the request", title);
        const suffix = resumed.state.history[1];
        if (finish_turn) {
            try std.testing.expectEqualStrings("remaining answer", suffix.assistant.assistant);
            try std.testing.expectEqual(@as(usize, 0), suffix.assistant.execution.tool_steps.len);
        } else {
            try std.testing.expect(suffix == .interrupted);
            try std.testing.expectEqual(@as(usize, 0), suffix.interrupted.execution.tool_steps.len);
        }
        const archive = try loadConversationHistoryRange(alloc, &resumed.log.dir, 0, 1);
        defer session.freeHistoryTurnSlice(alloc, archive);
        try std.testing.expectEqual(@as(usize, 1), archive.len);
        const archived_execution = switch (archive[0]) {
            .assistant => |entry| entry.execution,
            .interrupted => |entry| entry.execution,
            .compacted_summary => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(@as(usize, 2), archived_execution.tool_steps.len);
        try std.testing.expectEqualStrings("first-summarized-call", archived_execution.tool_steps[0].tool_calls[0].id);
        try std.testing.expectEqualStrings("second-summarized-call", archived_execution.tool_steps[1].tool_calls[0].id);
        const full_archive = try loadConversationArchive(alloc, &resumed.log.dir);
        defer session.freeHistoryTurnSlice(alloc, full_archive);
        var raw_turns: usize = 0;
        for (full_archive) |turn| {
            if (turn != .compacted_summary) raw_turns += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), raw_turns);
        const bytes = try resumed.conversation_writer.readAllForTest(alloc);
        defer alloc.free(bytes);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\"user\":{"));
    }
}

test "retained context checkpoint survives restart and appends each execution once" {
    const alloc = std.testing.allocator;
    for ([_]bool{ false, true }) |repeat| {
        for ([_]bool{ false, true }) |finish| {
            var temp = try TempRoot.init(alloc);
            defer temp.deinit(alloc);
            var initial = try testState(alloc, "retained-context-checkpoint", 10);
            defer initial.deinit(alloc);
            const ids = [_][]const u8{ "older-call", "recent-call", "newest-call", "final-call" };
            var calls: [4][1]types.ToolCall = undefined;
            var results: [4][1]types.PersistedToolResult = undefined;
            var steps: [4]types.ToolExecutionStep = undefined;
            for (ids, 0..) |id, index| {
                calls[index] = .{.{ .id = id, .name = "shell", .arguments_json = "{\"command\":\"printf evidence\"}" }};
                results[index] = .{.{
                    .tool_call_id = @constCast(id),
                    .tool_name = @constCast("shell"),
                    .status = .success,
                    .output = @constCast("exact observed bytes\n"),
                    .output_handle = @constCast(id),
                    .preview = @constCast("exact observed bytes\n"),
                    .output_bytes = 21,
                    .stored_output_bytes = 21,
                }};
                steps[index] = .{ .tool_calls = &calls[index], .tool_results = &results[index] };
            }
            const user = types.UserTurn{ .text = @constCast("continue this work") };
            {
                var loaded = try temp.root.startConversationSession(alloc, initial, .{});
                defer loaded.deinit(alloc);
                _ = try loaded.commitContextCompaction(alloc, .{
                    .summary = @constCast("<context_handoff>Older evidence.</context_handoff>"),
                    .removed_turn_count = 0,
                    .compaction_count = 1,
                }, .{ .user = user, .assistant = @constCast(""), .execution = .{ .tool_steps = steps[0..2] } }, .{ .tool_steps = 1 }, 20);
                if (repeat) {
                    _ = try loaded.commitContextCompaction(alloc, .{
                        .summary = @constCast("<context_handoff>Updated older evidence.</context_handoff>"),
                        .removed_turn_count = 0,
                        .compaction_count = 2,
                    }, .{ .user = user, .assistant = @constCast(""), .execution = .{ .tool_steps = steps[1..3] } }, .{ .tool_steps = 1 }, 30);
                }
                if (finish) {
                    const first: usize = if (repeat) 2 else 1;
                    _ = try loaded.appendEvent(alloc, .{ .history_turn_committed = .{
                        .conversation_language = initial.conversation_language,
                        .total_input_tokens = 0,
                        .total_output_tokens = 0,
                        .turn = .{ .assistant = .{
                            .user = user,
                            .assistant = @constCast("done"),
                            .execution = .{ .tool_steps = steps[first .. first + 2] },
                        } },
                    } }, 40);
                }
            }
            var resumed = try temp.root.resumeForWrite(alloc, initial.id, .{});
            defer resumed.deinit(alloc);
            try std.testing.expectEqual(@as(usize, 2), resumed.state.history.len);
            try std.testing.expect(resumed.state.history[0] == .compacted_summary);
            const entry = resumed.state.history[1];
            const execution = switch (entry) {
                .assistant => |turn| turn.execution,
                .interrupted => |turn| turn.execution,
                else => return error.TestUnexpectedResult,
            };
            try std.testing.expectEqual(@as(usize, if (finish) 2 else 1), execution.tool_steps.len);
            try std.testing.expectEqualStrings(ids[if (repeat) @as(usize, 2) else 1], execution.tool_steps[0].tool_calls[0].id);
            const archive = try loadConversationHistoryRange(alloc, &resumed.log.dir, 0, 1);
            defer session.freeHistoryTurnSlice(alloc, archive);
            const archived = switch (archive[0]) {
                .assistant => |turn| turn.execution,
                .interrupted => |turn| turn.execution,
                else => return error.TestUnexpectedResult,
            };
            const count: usize = 2 + @as(usize, @intFromBool(repeat)) + @as(usize, @intFromBool(finish));
            try std.testing.expectEqual(count, archived.tool_steps.len);
            for (archived.tool_steps, 0..) |step, index| {
                try std.testing.expectEqualStrings(ids[index], step.tool_calls[0].id);
                try std.testing.expectEqualStrings("exact observed bytes\n", step.tool_results[0].preview.?);
            }
        }
    }
}

test "mid-turn checkpoint retains a bound recovery suffix across writable resume" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "conversation-checkpoint-recovery", 10);
    defer initial.deinit(alloc);
    const user = types.UserTurn{
        .text = @constCast("finish the request"),
        .work_id = @constCast("exact-open-work"),
    };
    var recovery_before: ?[]u8 = null;
    defer if (recovery_before) |bytes| alloc.free(bytes);
    {
        var loaded = try temp.root.startConversationSession(alloc, initial, .{});
        defer loaded.deinit(alloc);
        _ = try loaded.commitContextCompaction(alloc, .{
            .summary = @constCast("<context_handoff>prior work completed</context_handoff>"),
            .removed_turn_count = 0,
            .compaction_count = 1,
        }, .{ .user = user, .assistant = @constCast("") }, null, 20);
        _ = try loaded.appendEvent(alloc, .{ .recovery_checkpoint_set = .{ .checkpoint = .{
            .turn_id = 7,
            .user = .{ .text = user.text },
            .assistant_source = @constCast("remaining draft"),
            .cause = .network_interrupted,
            .action = .retrying_request,
            .authority = .{ .provider = .gateway, .model = @constCast("test/model") },
            .requested_fast_mode = false,
            .fast_mode = false,
            .max_provider_attempts = 3,
            .consumed_provider_attempts = 1,
        } } }, 30);
        recovery_before = try readManagedFileAlloc(alloc, &loaded.log.dir, recovery_checkpoint_file, session_codec.max_recovery_checkpoint_bytes);
    }
    {
        var readonly = try temp.root.loadReadOnly(alloc, initial.id, .{});
        defer readonly.deinit(alloc);
        try std.testing.expectEqualStrings("exact-open-work", readonly.recovery_checkpoint.?.user.work_id orelse return error.MissingRecoveryWorkId);
    }
    {
        var resumed = try temp.root.resumeForWrite(alloc, initial.id, .{});
        defer resumed.deinit(alloc);
        try std.testing.expect(resumed.conversation_writer.turn_open);
        try std.testing.expectEqual(@as(usize, 1), resumed.state.history.len);
        try std.testing.expectEqualStrings("remaining draft", resumed.state.recovery_checkpoint.?.assistant_source);
        try std.testing.expectEqualStrings("exact-open-work", resumed.state.recovery_checkpoint.?.user.work_id orelse return error.MissingRecoveryWorkId);
        const recovery_after = try readManagedFileAlloc(alloc, &resumed.log.dir, recovery_checkpoint_file, session_codec.max_recovery_checkpoint_bytes);
        defer alloc.free(recovery_after);
        try std.testing.expectEqualStrings(recovery_before.?, recovery_after);
        _ = try resumed.appendEvent(alloc, .{ .history_turn_committed = .{
            .conversation_language = initial.conversation_language,
            .total_input_tokens = 0,
            .total_output_tokens = 0,
            .turn = .{ .assistant = .{ .user = user, .assistant = @constCast("remaining answer") } },
        } }, 40);
    }
    var completed = try temp.root.resumeForWrite(alloc, initial.id, .{});
    defer completed.deinit(alloc);
    try std.testing.expect(!completed.conversation_writer.turn_open);
    try std.testing.expectEqual(@as(usize, 2), completed.state.history.len);
    try std.testing.expect(completed.state.recovery_checkpoint == null);
    try std.testing.expectEqualStrings("remaining answer", completed.state.history[1].assistant.assistant);
}

test "recovery cleanup failure does not reject a durable conversation append" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "conversation-recovery-cleanup", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startConversationSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    const checkpoint = session_codec.RecoveryCheckpoint{
        .turn_id = 7,
        .user = .{ .text = @constCast("continue the request") },
        .assistant_source = @constCast("partial"),
        .cause = .network_interrupted,
        .action = .retrying_request,
        .authority = .{ .provider = .gateway, .model = @constCast("test/model") },
        .requested_fast_mode = false,
        .fast_mode = false,
        .max_provider_attempts = 3,
        .consumed_provider_attempts = 1,
    };
    _ = try loaded.appendEvent(alloc, .{
        .recovery_checkpoint_set = .{ .checkpoint = checkpoint },
    }, 20);
    try loaded.log.dir.dir.deleteFile(std.testing.io, recovery_checkpoint_file);
    try loaded.log.dir.dir.createDir(std.testing.io, recovery_checkpoint_file, private_dir_permissions);
    const position = try loaded.appendEvent(alloc, .{ .history_turn_committed = .{
        .conversation_language = initial.conversation_language,
        .total_input_tokens = 0,
        .total_output_tokens = 0,
        .turn = .{ .assistant = .{
            .user = checkpoint.user,
            .assistant = @constCast("finished answer"),
        } },
    } }, 30);
    try std.testing.expectEqual(@as(u64, 3), position.through_seq);
    try std.testing.expectEqual(@as(?session_codec.RecoveryCheckpoint, null), loaded.state.recovery_checkpoint);
}

test "cache-free permission state resumes from its domain file" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "conversation-permission", 10);
    defer initial.deinit(alloc);
    const key = try session_permission_state.RuleKey.init(
        .command,
        "command\x00/workspace\x00zig build",
    );
    var applied = try session_permission_state.apply(alloc, .{}, .{ .set = .{
        .key = key,
        .display_identity = "zig build",
        .decision = .deny,
        .expected_generation = null,
    } });
    var permissions = applied.takeApplied() orelse return error.TestUnexpectedResult;
    defer permissions.deinit(alloc);
    {
        var loaded = try temp.root.startConversationSession(alloc, initial, .{});
        defer loaded.deinit(alloc);
        try loaded.replacePermissionState(
            alloc,
            permissions,
            20,
        );
    }

    var resumed = try temp.root.loadReadOnly(alloc, initial.id, .{});
    defer resumed.deinit(alloc);
    try std.testing.expectEqual(
        session_permission_state.StateDecision.deny,
        session_permission_state.decide(resumed.permission_state, key),
    );
}

test "cache-free resume rebuilds tool calls and external result references" {
    const alloc = std.testing.allocator;
    const provider_state = types.ProviderReplay{ .source = .{ .provider = .gateway, .model = "test" }, .parts_json = "[{\"type\":\"reasoning\",\"text\":\"kept\"}]" };
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "conversation-tool-resume", 10);
    defer initial.deinit(alloc);
    var calls = [_]types.ToolCall{.{
        .id = "call-shell",
        .name = "shell",
        .arguments_json = "{\"command\":\"printf done\"}",
        .provider_result = "{\"native\":true}",
        .provenance = .provider_executed,
    }};
    var feedback = [_][]u8{@constCast("inspect the result")};
    const presentation_lines = [_]types.CommittedFilePresentationLine{.{
        .kind = .addition,
        .new_line = 1,
        .text = "done",
    }};
    var results = [_]types.PersistedToolResult{.{
        .tool_call_id = @constCast("call-shell"),
        .tool_name = @constCast("shell"),
        .status = .success,
        .output = @constCast("done"),
        .output_handle = @constCast("result-shell.txt"),
        .output_bytes = 9,
        .stored_output_bytes = 4,
        .truncated = true,
        .provider_native = true,
        .created_at_ms = 19,
        .permission_feedback = &feedback,
        .committed_file_presentation = .{
            .path = "done.txt",
            .kind = .added,
            .lines = &presentation_lines,
            .additions = 1,
            .deletions = 0,
            .truncated = false,
            .after_content = "done\n",
            .lifecycle_id = .{ .turn_id = 7, .call_id = "call-shell" },
        },
        .command_output_replay = .{ .available = .{
            .handle = @constCast("fx-command-replay-test.bin"),
            .framed_bytes = 42,
        } },
        .command_process_presentation = .{ .exit_code = 7 },
        .terminal_action_presentation = .{ .returned = .{ .exited = 7 } },
    }};
    var steps = [_]types.ToolExecutionStep{.{
        .assistant = @constCast("Running it."),
        .provider_replay = provider_state,
        .tool_calls = &calls,
        .tool_results = &results,
    }};
    var files = [_]types.FileEvidence{.{
        .path = @constCast("done.txt"),
        .tool_call_id = @constCast("call-shell"),
        .tool_name = @constCast("shell"),
        .action = .write,
        .model_view_covers_full_file = true,
    }};
    {
        var loaded = try temp.root.startConversationSession(alloc, initial, .{});
        defer loaded.deinit(alloc);
        _ = try loaded.appendEvent(alloc, .{ .history_turn_committed = .{
            .conversation_language = .literal("en"),
            .total_input_tokens = 1,
            .total_output_tokens = 1,
            .turn = .{ .assistant = .{
                .user = .{ .text = @constCast("Run it.") },
                .provider_replay = provider_state,
                .assistant = @constCast("Done."),
                .execution = .{
                    .tool_steps = &steps,
                    .files = &files,
                    .turn_summary = .{
                        .started_at_ms = 10,
                        .completed_at_ms = 20,
                        .turn_duration_ms = 10,
                    },
                },
            } },
        } }, 20);
    }

    var resumed = try temp.root.loadReadOnly(alloc, initial.id, .{});
    defer resumed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), resumed.history.len);
    const execution = resumed.history[0].assistant.execution;
    try std.testing.expectEqualStrings(provider_state.parts_json, resumed.history[0].assistant.provider_replay.?.parts_json);
    try std.testing.expectEqualStrings(provider_state.parts_json, execution.tool_steps[0].provider_replay.?.parts_json);
    try std.testing.expectEqual(@as(usize, 1), execution.tool_steps.len);
    try std.testing.expectEqualStrings("call-shell", execution.tool_steps[0].tool_calls[0].id);
    try std.testing.expectEqual(
        types.ToolExecutionProvenance.provider_executed,
        execution.tool_steps[0].tool_calls[0].provenance,
    );
    try std.testing.expectEqualStrings(
        "{\"native\":true}",
        execution.tool_steps[0].tool_calls[0].provider_result.?,
    );
    try std.testing.expectEqualStrings(
        "result-shell.txt",
        execution.tool_steps[0].tool_results[0].output_handle.?,
    );
    try std.testing.expectEqualStrings(
        "inspect the result",
        execution.tool_steps[0].tool_results[0].permission_feedback[0],
    );
    const result = execution.tool_steps[0].tool_results[0];
    try std.testing.expectEqual(@as(usize, 9), result.output_bytes);
    try std.testing.expectEqual(@as(usize, 4), result.stored_output_bytes);
    try std.testing.expect(result.truncated);
    try std.testing.expect(result.provider_native);
    try std.testing.expectEqual(@as(i64, 19), result.created_at_ms);
    try std.testing.expectEqual(
        types.CommandProcessPresentation{ .exit_code = 7 },
        result.command_process_presentation.?,
    );
    try std.testing.expectEqual(
        types.TerminalActionPresentation{ .returned = .{ .exited = 7 } },
        result.terminal_action_presentation.?,
    );
    const presentation = result.committed_file_presentation.?;
    try std.testing.expectEqualStrings("done.txt", presentation.path);
    try std.testing.expectEqualStrings("done\n", presentation.after_content.?);
    try std.testing.expectEqual(@as(u64, 7), presentation.lifecycle_id.?.turn_id);
    try std.testing.expectEqual(@as(usize, 1), execution.files.len);
    try std.testing.expectEqualStrings("done.txt", execution.files[0].path);
    try std.testing.expect(execution.files[0].model_view_covers_full_file);
    try std.testing.expectEqual(@as(u64, 10), execution.turn_summary.?.turn_duration_ms);
    const replay = execution.tool_steps[0].tool_results[0].command_output_replay orelse
        return error.TestExpectedCommandReplay;
    switch (replay) {
        .available => |descriptor| {
            try std.testing.expectEqualStrings(
                "fx-command-replay-test.bin",
                descriptor.handle,
            );
            try std.testing.expectEqual(@as(usize, 42), descriptor.framed_bytes);
        },
        .unavailable => return error.TestExpectedCommandReplay,
    }
}

fn checkCompleteSkillReplayArtifact(artifact: enum { intact, missing, mismatched }) !void {
    const alloc = std.testing.allocator;
    const runtime_memory = @import("../agent/runtime/execution_memory.zig");
    const execution_memory = @import("../agent/execution_memory.zig");
    const full_output = "<skill_content name=\"workflow\" location=\"/skills/workflow\" resource=\"SKILL.md\" complete=\"true\">\n" ++
        ("required instruction\n" ** 1200) ++ "COMPLETE_SKILL_TAIL\n</skill_content>";
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "complete-skill-replay", 10);
    defer initial.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var calls = [_]types.ToolCall{.{ .id = "load-skill", .name = "skill", .arguments_json = "{\"location\":\"/skills/workflow\"}" }};
    {
        var loaded = try temp.root.startConversationSession(alloc, initial, .{});
        defer loaded.deinit(alloc);
        const session_path = try io_mod.dirRealpathAlloc(alloc, loaded.log.dir.dir, ".");
        defer alloc.free(session_path);
        var capability = try session_child_store.SessionChildCapability.init(alloc, loaded.log.dir.dir, session_path, .writable);
        defer capability.deinit();
        const prepared = try runtime_memory.prepareToolExecutionOutput(arena, .{
            .system_prompt = "",
            .gateway_retry_count = 0,
            .gateway_chat_url = "",
            .agent_step_limit = 1,
            .cancel_flag = &cancel_flag,
            .session_child_capability = &capability,
        }, calls[0], .{ .status = .success, .model_content_kind = .complete_skill, .model_output = full_output }, null);
        try std.testing.expect(full_output.len > result_store.large_result_threshold_bytes);
        try std.testing.expect(!prepared.memory.truncated);
        try std.testing.expectEqualStrings(full_output, prepared.model_output);
        var results = [_]types.PersistedToolResult{try execution_memory.makePersistedToolResult(
            alloc,
            calls[0].id,
            calls[0].name,
            .success,
            prepared.model_output,
            prepared.memory,
        )};
        defer freeConversationToolResult(alloc, results[0]);
        var steps = [_]types.ToolExecutionStep{.{ .tool_calls = &calls, .tool_results = &results }};
        _ = try loaded.appendEvent(alloc, .{ .history_turn_committed = .{
            .conversation_language = .literal("en"),
            .total_input_tokens = 1,
            .total_output_tokens = 1,
            .turn = .{ .assistant = .{
                .user = .{ .text = @constCast("Use this skill.") },
                .assistant = @constCast("Loaded the instructions."),
                .execution = .{ .tool_steps = &steps },
            } },
        } }, 20);
        const handle = prepared.memory.output_handle.?;
        switch (artifact) {
            .intact => {},
            .missing => try capability.delete(.tool_results, handle),
            .mismatched => {
                var replacement = try capability.atomicReplace(alloc, .tool_results, handle, "different-sized content");
                replacement.deinit(alloc);
            },
        }
    }
    var resumed = try temp.root.loadReadOnly(alloc, initial.id, .{});
    defer resumed.deinit(alloc);
    const execution = resumed.history[0].assistant.execution;
    const replayed = execution.tool_steps[0].tool_results[0];
    try std.testing.expectEqual(types.PersistedToolStatus.success, replayed.status);
    try std.testing.expectEqual(full_output.len, replayed.stored_output_bytes);
    var messages: std.ArrayList(types.ChatMessage) = .empty;
    try session.appendExecutionMemoryChatMessages(arena, &messages, execution);
    const projected = messages.items[1].content.?;
    if (artifact == .intact) {
        try std.testing.expect(!replayed.truncated);
        try std.testing.expectEqualStrings(full_output, projected);
    } else {
        try std.testing.expect(replayed.truncated);
        try std.testing.expect(std.mem.find(u8, projected, "unavailable") != null);
        try std.testing.expect(std.mem.find(u8, projected, "complete=\"true\"") == null);
        try std.testing.expect(std.mem.find(u8, projected, "required instruction") == null);
    }
}

test "complete skill replay retains intact full artifacts" {
    try checkCompleteSkillReplayArtifact(.intact);
}

test "complete skill replay marks missing artifacts unavailable" {
    try checkCompleteSkillReplayArtifact(.missing);
}

test "complete skill replay marks mismatched artifacts unavailable" {
    try checkCompleteSkillReplayArtifact(.mismatched);
}

test "cache-free resume loads only the latest checkpoint and suffix" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "conversation-checkpoint", 10);
    defer initial.deinit(alloc);
    {
        var loaded = try temp.root.startConversationSession(alloc, initial, .{});
        defer loaded.deinit(alloc);
        _ = try loaded.appendEvent(alloc, .{ .history_turn_committed = .{
            .conversation_language = .literal("en"),
            .total_input_tokens = 1,
            .total_output_tokens = 1,
            .turn = .{ .assistant = .{
                .user = .{ .text = @constCast("old question") },
                .assistant = @constCast("old answer"),
            } },
        } }, 20);
        _ = try loaded.appendEvent(alloc, .{ .history_turn_committed = .{
            .conversation_language = .literal("en"),
            .total_input_tokens = 2,
            .total_output_tokens = 2,
            .turn = .{ .compacted_summary = .{
                .summary = @constCast("<context_handoff>summary</context_handoff>"),
                .removed_turn_count = 1,
                .compaction_count = 1,
            } },
        } }, 30);
        _ = try loaded.appendEvent(alloc, .{ .history_turn_committed = .{
            .conversation_language = .literal("en"),
            .total_input_tokens = 3,
            .total_output_tokens = 3,
            .turn = .{ .assistant = .{
                .user = .{ .text = @constCast("new question") },
                .assistant = @constCast("new answer"),
            } },
        } }, 40);
    }

    var resumed = try temp.root.loadReadOnly(alloc, initial.id, .{});
    defer resumed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), resumed.history.len);
    try std.testing.expect(resumed.history[0] == .compacted_summary);
    try std.testing.expectEqualStrings("new question", resumed.history[1].assistant.user.text);

    var session_dir = try temp.root.sessions.?.dir.openDir(
        std.testing.io,
        initial.id,
        .{},
    );
    defer session_dir.close(std.testing.io);
    var event_file = try session_dir.openFile(std.testing.io, "events.jsonl", .{});
    defer event_file.close(std.testing.io);
    const bytes = try io_mod.readFileToEnd(alloc, &event_file, 1024 * 1024);
    defer alloc.free(bytes);
    try std.testing.expect(std.mem.find(u8, bytes, "old question") != null);
}
