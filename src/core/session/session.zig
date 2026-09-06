const std = @import("std");
const kernel_agent = @import("../agent/runtime/agent.zig");
const core_types = @import("../shared/types.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const message = @import("../shared/message.zig");
const text_utils = @import("../shared/text_utils.zig");
const language_script = @import("../shared/language_script.zig");
const tool_result_errors = @import("../tooling/tool_result_errors.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const image_attachments = @import("../images/image_attachments.zig");
const generation_usage_provider = @import("generation_usage_provider.zig");
const web_fetch_artifacts = @import("web_fetch_artifacts.zig");
const command_replay_store = @import("command_replay_store.zig");
pub const session_usage = @import("session_usage.zig");
pub const profile_usage_runtime = @import("profile_usage_runtime.zig");
const command_contract = @import("../execution/command_contract.zig");
const sort_utils = @import("../shared/sort_utils.zig");
const Allocator = std.mem.Allocator;

test {
    _ = session_usage;
    _ = profile_usage_runtime;
}

const compact_continuation_preamble = "This session is being continued from earlier compacted context. The summary below covers the earlier portion of the conversation.\n\n";
const compact_recent_messages_note = "Recent conversation turns are preserved verbatim.";
const compact_direct_resume_instruction = "Continue the conversation from where it left off without asking the user to repeat context. Resume directly.";
const compact_summary_max_chars: usize = 1200;
const compact_summary_max_lines: usize = 24;
const compact_summary_max_line_chars: usize = 160;

pub const interrupted_turn_notice: core_types.SemanticNotice = .{
    .topic = "system",
    .tone = .cancelled,
    .body = "cancelled",
};

pub const failed_turn_notice: core_types.SemanticNotice = .{
    .topic = "system",
    .tone = .@"error",
    .body = "failed",
};

pub fn interruptedTurnNotice(entry: InterruptedHistoryTurn) core_types.SemanticNotice {
    return switch (entry.terminal_reason) {
        .cancelled => interrupted_turn_notice,
        .failed => failed_turn_notice,
    };
}

pub const interrupted_turn_context =
    "<turn_aborted>\n" ++
    "The previous turn ended before completion. Any tools or commands may have partially executed. " ++
    "Do not continue this request unless the user explicitly asks to continue.\n" ++
    "</turn_aborted>";

pub fn projectSnapshotLocator(buffer: []u8, path: []const u8) ![]const u8 {
    if (!std.fs.path.isAbsolute(path)) return path;
    return std.fmt.bufPrint(buffer, "images/{s}", .{std.fs.path.basename(path)});
}

pub const interrupted_before_completion_output = "The previous response ended before completion.";
pub const aborted_tool_output = "aborted by user";

/// Conversation language tag stored in session records.
pub const ConversationLanguage = core_types.ConversationLanguage;
/// Image attachment metadata stored on user turns.
pub const ImageAttachment = core_types.ImageAttachment;
/// User-side text and image attachments for a stored history turn.
pub const UserTurn = core_types.UserTurn;
/// Gateway tool call metadata stored when an interrupted turn is cancelled during a tool call.
pub const ToolCall = core_types.ToolCall;
/// Stored assistant response paired with the user turn that produced it.
pub const AssistantHistoryTurn = core_types.AssistantHistoryTurn;
/// Stored background command metadata paired with the user turn that produced it.
pub const CancelledCommandPresentation = core_types.CancelledCommandPresentation;
/// Stored interrupted turn marker, optionally paired with the active tool call.
pub const InterruptedHistoryTurn = core_types.InterruptedHistoryTurn;
pub const InterruptedTerminalReason = core_types.InterruptedTerminalReason;

fn formatInterruptedToolOutput(
    alloc: Allocator,
    entry: InterruptedHistoryTurn,
) ![]u8 {
    const presentation = entry.cancelled_command orelse
        return alloc.dupe(u8, aborted_tool_output);
    const replay = presentation.output_replay orelse
        return alloc.dupe(u8, aborted_tool_output);
    const descriptor = switch (replay) {
        .available => |value| value,
        .unavailable => return alloc.dupe(u8, aborted_tool_output),
    };
    return command_replay_store.appendModelHandleNotice(
        alloc,
        aborted_tool_output,
        descriptor.handle,
    ) catch |err| switch (err) {
        error.InvalidReplayHandle => {
            debug_trace.logf(
                "session",
                "cancelled command replay handle omitted from model context handle_bytes={d}",
                .{descriptor.handle.len},
            );
            return alloc.dupe(u8, aborted_tool_output);
        },
        else => return err,
    };
}

/// Stored compacted context summary produced by core history compaction.
pub const CompactedSummaryHistoryTurn = core_types.CompactedSummaryHistoryTurn;
/// One persisted session history record.
pub const HistoryTurn = core_types.HistoryTurn;
pub const freeUserTurn = core_types.freeUserTurn;
pub const dupeUserTurn = core_types.dupeUserTurn;
pub const max_work_id_bytes: usize = 128;

pub const WorkIdAssociation = enum {
    none,
    copy_event,
    already_associated,
};

pub const WorkIdError = error{
    InvalidWorkId,
    ConflictingWorkId,
};

pub fn validateWorkId(work_id: []const u8) WorkIdError!void {
    if (work_id.len == 0 or work_id.len > max_work_id_bytes or
        !std.unicode.utf8ValidateSlice(work_id) or
        std.mem.indexOfScalar(u8, work_id, 0) != null)
    {
        return error.InvalidWorkId;
    }
}

pub fn historyTurnWorkId(turn: HistoryTurn) ?[]const u8 {
    return switch (turn) {
        .assistant => |entry| entry.user.work_id,
        .interrupted => |entry| entry.user.work_id,
        .compacted_summary => null,
    };
}

/// Purely decides how authoritative event provenance relates to one turn.
pub fn decideWorkIdAssociation(
    turn: HistoryTurn,
    event_work_id: ?[]const u8,
) WorkIdError!WorkIdAssociation {
    const turn_work_id = historyTurnWorkId(turn);
    if (turn_work_id) |work_id| try validateWorkId(work_id);
    if (event_work_id) |work_id| try validateWorkId(work_id);

    if (event_work_id == null) {
        return if (turn_work_id == null) .none else error.ConflictingWorkId;
    }
    if (turn == .compacted_summary) return error.ConflictingWorkId;
    if (turn_work_id) |work_id| {
        return if (std.mem.eql(u8, work_id, event_work_id.?))
            .already_associated
        else
            error.ConflictingWorkId;
    }
    return .copy_event;
}

/// Installs a separately owned work ID after pure association succeeds.
pub fn copyWorkIdToTurn(
    alloc: Allocator,
    turn: *HistoryTurn,
    work_id: []const u8,
) (Allocator.Error || WorkIdError)!void {
    if (try decideWorkIdAssociation(turn.*, work_id) != .copy_event) return;
    const owned = try alloc.dupe(u8, work_id);
    switch (turn.*) {
        .assistant => |*entry| entry.user.work_id = owned,
        .interrupted => |*entry| entry.user.work_id = owned,
        .compacted_summary => unreachable,
    }
}

pub const freeHistoryTurn = core_types.freeHistoryTurn;
pub const dupeToolCall = core_types.dupeToolCall;
pub const freeToolCall = core_types.freeToolCall;
pub const dupeCompletedToolNames = core_types.dupeCompletedToolNames;
pub const freeCompletedToolNames = core_types.freeCompletedToolNames;
pub const ExecutionMemory = core_types.ExecutionMemory;
pub const ToolExecutionStep = core_types.ToolExecutionStep;
pub const PersistedToolResult = core_types.PersistedToolResult;
pub const PersistedToolStatus = core_types.PersistedToolStatus;
pub const FileEvidence = core_types.FileEvidence;
pub const FileEvidenceAction = core_types.FileEvidenceAction;
pub const freeExecutionMemory = core_types.freeExecutionMemory;
pub const freeToolCallSlice = core_types.freeToolCallSlice;
pub const freePersistedToolResults = core_types.freePersistedToolResults;

/// Builds a sorted, independently owned attachment catalog from complete
/// canonical history plus current-turn images. The caller frees the returned
/// slice with `core_types.freeImageAttachmentSlice` using the same allocator.
pub fn collect_image_catalog(
    alloc: Allocator,
    canonical_history: []const HistoryTurn,
    current_images: []const ImageAttachment,
) (Allocator.Error || error{
    ImageCatalogTooLarge,
    InvalidImageId,
    DuplicateImageId,
})![]ImageAttachment {
    var attachment_count = current_images.len;
    for (canonical_history) |turn| {
        attachment_count = std.math.add(
            usize,
            attachment_count,
            images_for_history_turn(turn).len,
        ) catch return error.ImageCatalogTooLarge;
    }
    if (attachment_count == 0) return &.{};

    const catalog = try alloc.alloc(ImageAttachment, attachment_count);
    errdefer alloc.free(catalog);
    var copied: usize = 0;
    errdefer for (catalog[0..copied]) |attachment| {
        core_types.freeImageAttachment(alloc, attachment);
    };

    for (canonical_history) |turn| {
        for (images_for_history_turn(turn)) |attachment| {
            catalog[copied] = try dupeImageAttachment(alloc, attachment);
            copied += 1;
        }
    }
    for (current_images) |attachment| {
        catalog[copied] = try dupeImageAttachment(alloc, attachment);
        copied += 1;
    }

    sort_utils.sort(ImageAttachment, catalog, {}, image_id_less_than);
    var previous_id: ?usize = null;
    for (catalog) |attachment| {
        if (attachment.id == 0) return error.InvalidImageId;
        if (previous_id == attachment.id) return error.DuplicateImageId;
        previous_id = attachment.id;
    }
    std.debug.assert(image_attachments.imageAttachmentsSortedById(catalog));
    return catalog;
}

/// Returns a new owned catalog containing any image authority introduced by a
/// completed history turn. Existing IDs must either match exactly or the
/// queued catalog is rejected as stale.
pub fn merge_image_catalog_history_turn(
    alloc: Allocator,
    catalog: []const ImageAttachment,
    turn: HistoryTurn,
) (Allocator.Error || error{
    ImageCatalogTooLarge,
    InvalidImageId,
    DuplicateImageId,
    StaleImageCatalog,
})![]ImageAttachment {
    try validate_image_catalog(catalog);
    const additions = images_for_history_turn(turn);
    var missing_count: usize = 0;
    for (additions, 0..) |addition, index| {
        if (addition.id == 0) return error.InvalidImageId;
        for (additions[0..index]) |prior| {
            if (prior.id == addition.id) return error.DuplicateImageId;
        }
        if (image_attachment_for_id(catalog, addition.id)) |existing| {
            if (!image_attachments_equal(existing, addition)) return error.StaleImageCatalog;
        } else {
            missing_count += 1;
        }
    }

    const attachment_count = std.math.add(usize, catalog.len, missing_count) catch
        return error.ImageCatalogTooLarge;
    if (attachment_count == 0) return &.{};
    const merged = try alloc.alloc(ImageAttachment, attachment_count);
    errdefer alloc.free(merged);
    var copied: usize = 0;
    errdefer for (merged[0..copied]) |attachment| {
        core_types.freeImageAttachment(alloc, attachment);
    };
    for (catalog) |attachment| {
        merged[copied] = try dupeImageAttachment(alloc, attachment);
        copied += 1;
    }
    for (additions) |attachment| {
        if (image_attachment_for_id(catalog, attachment.id) != null) continue;
        merged[copied] = try dupeImageAttachment(alloc, attachment);
        copied += 1;
    }
    sort_utils.sort(ImageAttachment, merged, {}, image_id_less_than);
    try validate_image_catalog(merged);
    return merged;
}

fn validate_image_catalog(catalog: []const ImageAttachment) error{
    InvalidImageId,
    DuplicateImageId,
}!void {
    var previous_id: ?usize = null;
    for (catalog) |attachment| {
        if (attachment.id == 0) return error.InvalidImageId;
        if (previous_id != null and previous_id.? >= attachment.id) {
            if (previous_id.? == attachment.id) return error.DuplicateImageId;
            return error.InvalidImageId;
        }
        previous_id = attachment.id;
    }
}

fn image_attachment_for_id(
    attachments: []const ImageAttachment,
    id: usize,
) ?ImageAttachment {
    for (attachments) |attachment| {
        if (attachment.id == id) return attachment;
    }
    return null;
}

fn image_attachments_equal(lhs: ImageAttachment, rhs: ImageAttachment) bool {
    return lhs.id == rhs.id and
        std.mem.eql(u8, lhs.path, rhs.path) and
        std.mem.eql(u8, lhs.media_type, rhs.media_type) and
        optionalBytesEqual(lhs.snapshot_path, rhs.snapshot_path) and
        optionalBytesEqual(lhs.snapshot_sha256, rhs.snapshot_sha256);
}

fn optionalBytesEqual(lhs: ?[]const u8, rhs: ?[]const u8) bool {
    if (lhs == null or rhs == null) return lhs == null and rhs == null;
    return std.mem.eql(u8, lhs.?, rhs.?);
}

fn images_for_history_turn(turn: HistoryTurn) []const ImageAttachment {
    return switch (turn) {
        .compacted_summary => &.{},
        .assistant => |entry| entry.user.images,
        .interrupted => |entry| entry.user.images,
    };
}

fn mutable_images_for_history_turn(turn: *HistoryTurn) []ImageAttachment {
    return switch (turn.*) {
        .compacted_summary => &.{},
        .assistant => |*entry| entry.user.images,
        .interrupted => |*entry| entry.user.images,
    };
}

fn mutable_images_slice_for_history_turn(turn: *HistoryTurn) ?*[]ImageAttachment {
    return switch (turn.*) {
        .compacted_summary => null,
        .assistant => |*entry| &entry.user.images,
        .interrupted => |*entry| &entry.user.images,
    };
}

fn user_text_for_history_turn(turn: HistoryTurn) []const u8 {
    return switch (turn) {
        .compacted_summary => "",
        .assistant => |entry| entry.user.text,
        .interrupted => |entry| entry.user.text,
    };
}

const LegacyImagePlaceholderIterator = struct {
    text: []const u8,
    offset: usize = 0,

    const prefix = "[Image #";
    const Slot = struct {
        id: ?usize,
        start: usize,
        length: usize,
    };

    fn next(self: *@This()) ?Slot {
        const relative_start = std.mem.indexOf(u8, self.text[self.offset..], prefix) orelse
            return null;
        const start = self.offset + relative_start;
        if (image_attachments.matchImagePlaceholder(self.text, start)) |match| {
            self.offset = start + match.length;
            return .{ .id = match.id, .start = start, .length = match.length };
        }

        const body_start = start + prefix.len;
        self.offset = if (std.mem.indexOfScalar(u8, self.text[body_start..], ']')) |relative_end|
            body_start + relative_end + 1
        else
            body_start;
        return .{ .id = null, .start = start, .length = self.offset - start };
    }
};

const LegacyImageRepair = struct {
    turn_index: usize,
    image_index: usize,
    placeholder: ?LegacyImagePlaceholderIterator.Slot,
    assigned_id: usize = 0,
};

const LegacyTurnTextRepair = struct {
    turn_index: usize,
    text: []u8,
};

fn history_placeholder_id_count(history: []const HistoryTurn, id: usize) usize {
    var count: usize = 0;
    for (history) |turn| {
        var placeholders = LegacyImagePlaceholderIterator{
            .text = user_text_for_history_turn(turn),
        };
        while (placeholders.next()) |placeholder| {
            if (placeholder.id != null and placeholder.id.? == id) count += 1;
        }
    }
    return count;
}

fn legacy_placeholder_claim(
    history: []const HistoryTurn,
    placeholder: ?LegacyImagePlaceholderIterator.Slot,
) ?usize {
    const slot = placeholder orelse return null;
    const placeholder_id = slot.id orelse return null;
    if (placeholder_id == 0) return null;
    if (history_placeholder_id_count(history, placeholder_id) != 1) return null;
    if (history_contains_image_id(history, placeholder_id)) return null;
    return placeholder_id;
}

fn legacy_repairs_contain_id(repairs: []const LegacyImageRepair, id: usize) bool {
    for (repairs) |repair| {
        if (repair.assigned_id == id) return true;
    }
    return false;
}

fn assign_legacy_image_ids(
    history: []const HistoryTurn,
    repairs: []LegacyImageRepair,
) error{ImageIdOverflow}!void {
    for (repairs) |*repair| {
        repair.assigned_id = legacy_placeholder_claim(history, repair.placeholder) orelse 0;
    }

    var candidate: usize = 1;
    for (repairs) |*repair| {
        if (repair.assigned_id != 0) continue;
        while (history_contains_image_id(history, candidate) or
            legacy_repairs_contain_id(repairs, candidate))
        {
            candidate = std.math.add(usize, candidate, 1) catch
                return error.ImageIdOverflow;
        }
        repair.assigned_id = candidate;
    }
}

fn rebuilt_legacy_turn_text(
    alloc: Allocator,
    history: []const HistoryTurn,
    turn_index: usize,
    repairs: []const LegacyImageRepair,
) Allocator.Error!?[]u8 {
    const text = user_text_for_history_turn(history[turn_index]);
    var needs_rebuild = false;
    for (repairs) |repair| {
        if (repair.turn_index != turn_index) continue;
        const placeholder = repair.placeholder orelse continue;
        const legacy_id = placeholder.id orelse continue;
        if (legacy_id != repair.assigned_id) needs_rebuild = true;
    }
    if (!needs_rebuild) return null;

    var rebuilt: std.Io.Writer.Allocating = .init(alloc);
    errdefer rebuilt.deinit();
    var cursor: usize = 0;
    for (repairs) |repair| {
        if (repair.turn_index != turn_index) continue;
        const placeholder = repair.placeholder orelse continue;
        const legacy_id = placeholder.id orelse continue;
        if (legacy_id == repair.assigned_id) continue;

        std.debug.assert(placeholder.start >= cursor);
        std.debug.assert(placeholder.start + placeholder.length <= text.len);
        rebuilt.writer.writeAll(text[cursor..placeholder.start]) catch return error.OutOfMemory;
        image_attachments.writeImagePlaceholder(&rebuilt.writer, repair.assigned_id) catch return error.OutOfMemory;
        cursor = placeholder.start + placeholder.length;
    }
    rebuilt.writer.writeAll(text[cursor..]) catch return error.OutOfMemory;
    return rebuilt.toOwnedSlice() catch return error.OutOfMemory;
}

fn mutable_user_for_history_turn(turn: *HistoryTurn) ?*UserTurn {
    return switch (turn.*) {
        .compacted_summary => null,
        .assistant => |*entry| &entry.user,
        .interrupted => |*entry| &entry.user,
    };
}

/// Repairs image IDs omitted by the legacy session deep-copy path. This is
/// only for allocator-owned history loaded from durable storage. Rebuilt text
/// remains owned by its history turn. Returns whether any attachment changed.
pub fn repair_legacy_zero_image_ids(
    alloc: Allocator,
    history: []HistoryTurn,
) (Allocator.Error || error{ImageIdOverflow})!bool {
    var repairs: std.ArrayList(LegacyImageRepair) = .empty;
    defer repairs.deinit(alloc);
    for (history, 0..) |*turn, turn_index| {
        var placeholders = LegacyImagePlaceholderIterator{
            .text = user_text_for_history_turn(turn.*),
        };
        for (mutable_images_for_history_turn(turn), 0..) |attachment, image_index| {
            const placeholder = placeholders.next();
            if (attachment.id != 0) continue;
            try repairs.append(alloc, .{
                .turn_index = turn_index,
                .image_index = image_index,
                .placeholder = placeholder,
            });
        }
    }
    if (repairs.items.len == 0) return false;

    try assign_legacy_image_ids(history, repairs.items);

    var text_repairs: std.ArrayList(LegacyTurnTextRepair) = .empty;
    defer text_repairs.deinit(alloc);
    errdefer for (text_repairs.items) |repair| alloc.free(repair.text);
    for (history, 0..) |_, turn_index| {
        const rebuilt = try rebuilt_legacy_turn_text(
            alloc,
            history,
            turn_index,
            repairs.items,
        ) orelse continue;
        text_repairs.append(alloc, .{ .turn_index = turn_index, .text = rebuilt }) catch |err| {
            alloc.free(rebuilt);
            return err;
        };
    }

    for (repairs.items) |repair| {
        mutable_images_for_history_turn(&history[repair.turn_index])[repair.image_index].id =
            repair.assigned_id;
    }
    for (text_repairs.items) |repair| {
        const user = mutable_user_for_history_turn(&history[repair.turn_index]).?;
        alloc.free(user.text);
        user.text = repair.text;
    }
    return true;
}

pub fn repair_legacy_image_snapshots(
    alloc: Allocator,
    history: []HistoryTurn,
    snapshot_dir: []const u8,
) Allocator.Error!bool {
    const snapshot_dir_existed = snapshot_directory_exists(snapshot_dir);
    const candidate = try alloc.alloc(HistoryTurn, history.len);
    var copied: usize = 0;
    errdefer {
        for (candidate[0..copied]) |turn| freeHistoryTurn(alloc, turn);
        alloc.free(candidate);
    }
    while (copied < history.len) : (copied += 1) {
        candidate[copied] = try dupeHistoryTurn(alloc, history[copied]);
    }

    const changed = repair_legacy_image_snapshots_in_place(
        alloc,
        candidate,
        snapshot_dir,
    ) catch |err| {
        cleanup_candidate_snapshot_files(candidate, history);
        if (!snapshot_dir_existed) remove_empty_snapshot_directory(snapshot_dir);
        return err;
    };
    if (!changed) {
        freeHistoryTurnSlice(alloc, candidate);
        return false;
    }

    for (history, candidate) |*current, *replacement| {
        std.mem.swap(HistoryTurn, current, replacement);
    }
    freeHistoryTurnSlice(alloc, candidate);
    return true;
}

pub fn repair_legacy_images_transactionally(
    alloc: Allocator,
    history: []HistoryTurn,
    snapshot_dir: []const u8,
) (Allocator.Error || error{ImageIdOverflow})!bool {
    const candidate = try alloc.alloc(HistoryTurn, history.len);
    var copied: usize = 0;
    errdefer {
        for (candidate[0..copied]) |turn| freeHistoryTurn(alloc, turn);
        alloc.free(candidate);
    }
    while (copied < history.len) : (copied += 1) {
        candidate[copied] = try dupeHistoryTurn(alloc, history[copied]);
    }

    const ids_changed = try repair_legacy_zero_image_ids(alloc, candidate);
    const snapshots_changed = try repair_legacy_image_snapshots(
        alloc,
        candidate,
        snapshot_dir,
    );
    if (!ids_changed and !snapshots_changed) {
        freeHistoryTurnSlice(alloc, candidate);
        return false;
    }

    for (history, candidate) |*current, *replacement| {
        std.mem.swap(HistoryTurn, current, replacement);
    }
    freeHistoryTurnSlice(alloc, candidate);
    return true;
}

fn snapshot_directory_exists(path: []const u8) bool {
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), path, .{}) catch return false;
    dir.close(io_mod.getIo());
    return true;
}

fn remove_empty_snapshot_directory(path: []const u8) void {
    std.Io.Dir.deleteDirAbsolute(io_mod.getIo(), path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => debug_trace.logf(
            "session",
            "event=legacy_snapshot_directory_cleanup_failed err={s}",
            .{@errorName(err)},
        ),
    };
}

fn repair_legacy_image_snapshots_in_place(
    alloc: Allocator,
    history: []HistoryTurn,
    snapshot_dir: []const u8,
) Allocator.Error!bool {
    var changed = false;
    for (history) |*turn| {
        const images_ptr = mutable_images_slice_for_history_turn(turn) orelse continue;
        if (images_ptr.*.len == 0) continue;

        var drop_indexes: std.ArrayList(usize) = .empty;
        defer drop_indexes.deinit(alloc);
        for (images_ptr.*, 0..) |*image, image_index| {
            if (image.snapshot_path != null and image.snapshot_sha256 != null) continue;
            image_attachments.captureImageSnapshot(alloc, image, snapshot_dir) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    debug_trace.logf(
                        "session",
                        "legacy image snapshot unavailable id={d} err={s}",
                        .{ image.id, @errorName(err) },
                    );
                    try drop_indexes.append(alloc, image_index);
                    continue;
                },
            };
            changed = true;
        }
        if (drop_indexes.items.len == 0) continue;

        const retained_len = images_ptr.*.len - drop_indexes.items.len;
        var retained: []ImageAttachment = if (retained_len > 0)
            try alloc.alloc(ImageAttachment, retained_len)
        else
            &.{};
        var retained_index: usize = 0;
        var drop_cursor: usize = 0;
        for (images_ptr.*, 0..) |image, image_index| {
            const drop = drop_cursor < drop_indexes.items.len and
                drop_indexes.items[drop_cursor] == image_index;
            if (drop) {
                core_types.freeImageAttachment(alloc, image);
                drop_cursor += 1;
                continue;
            }
            retained[retained_index] = image;
            retained_index += 1;
        }
        alloc.free(images_ptr.*);
        images_ptr.* = retained;
        changed = true;
    }
    return changed;
}

fn cleanup_candidate_snapshot_files(
    candidate: []const HistoryTurn,
    original: []const HistoryTurn,
) void {
    for (candidate, original) |candidate_turn, original_turn| {
        image_attachments.deleteUnreferencedImageSnapshots(
            images_for_history_turn(candidate_turn),
            images_for_history_turn(original_turn),
        );
    }
}

fn make_owned_legacy_image_turn(
    alloc: Allocator,
    text: []const u8,
    assistant: []const u8,
    path: []const u8,
) !HistoryTurn {
    var turn = try makeAssistantTurn(alloc, text, assistant);
    errdefer freeHistoryTurn(alloc, turn);
    turn.assistant.user.images = try core_types.dupeImageAttachmentSlice(alloc, &.{.{
        .path = @constCast(path),
        .media_type = @constCast("image/png"),
    }});
    return turn;
}

fn sessionTestSnapshotDir(alloc: Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    return std.fs.path.join(alloc, &.{ root, "snapshots" });
}

fn writeSessionTestImage(
    alloc: Allocator,
    tmp: *std.testing.TmpDir,
    name: []const u8,
    data: []const u8,
) ![]u8 {
    {
        var file = try tmp.dir.createFile(std.testing.io, name, .{ .truncate = true });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, data);
    }
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, name);
}

test "legacy image snapshot repair captures available path once" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_a = "\x89PNG\r\n\x1a\nlegacy-a";
    const image_b = "\x89PNG\r\n\x1a\nlegacy-b";
    const path = try writeSessionTestImage(alloc, &tmp, "legacy.png", image_a);
    defer alloc.free(path);
    const snapshot_dir = try sessionTestSnapshotDir(alloc, &tmp);
    defer alloc.free(snapshot_dir);
    var turn = try make_owned_legacy_image_turn(alloc, "legacy [Image #1]", "answer", path);
    var turn_owned = true;
    errdefer if (turn_owned) freeHistoryTurn(alloc, turn);
    turn.assistant.user.images[0].id = 1;
    var history = [_]HistoryTurn{turn};
    defer freeHistoryTurn(alloc, history[0]);
    turn_owned = false;

    try std.testing.expect(try repair_legacy_image_snapshots(alloc, &history, snapshot_dir));
    try std.testing.expect(history[0].assistant.user.images[0].snapshot_path != null);
    try std.testing.expect(history[0].assistant.user.images[0].snapshot_sha256 != null);
    const replaced_path = try writeSessionTestImage(alloc, &tmp, "legacy.png", image_b);
    defer alloc.free(replaced_path);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try image_attachments.writeImageFilePartJson(alloc, &out.writer, history[0].assistant.user.images[0]);
    var expected_buf: [128]u8 = undefined;
    const expected = std.base64.standard.Encoder.encode(&expected_buf, image_a);
    var unexpected_buf: [128]u8 = undefined;
    const unexpected = std.base64.standard.Encoder.encode(&unexpected_buf, image_b);
    try std.testing.expect(std.mem.find(u8, out.written(), expected) != null);
    try std.testing.expect(std.mem.find(u8, out.written(), unexpected) == null);
}

test "legacy image snapshot repair drops unavailable path-only images" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const missing_path = try std.fs.path.join(alloc, &.{ root, "missing.png" });
    defer alloc.free(missing_path);
    const snapshot_dir = try sessionTestSnapshotDir(alloc, &tmp);
    defer alloc.free(snapshot_dir);
    var turn = try make_owned_legacy_image_turn(alloc, "legacy [Image #1]", "answer", missing_path);
    var turn_owned = true;
    errdefer if (turn_owned) freeHistoryTurn(alloc, turn);
    turn.assistant.user.images[0].id = 1;
    var history = [_]HistoryTurn{turn};
    defer freeHistoryTurn(alloc, history[0]);
    turn_owned = false;

    try std.testing.expect(try repair_legacy_image_snapshots(alloc, &history, snapshot_dir));
    try std.testing.expectEqual(@as(usize, 0), history[0].assistant.user.images.len);
}

test "legacy image snapshot repair propagates OOM without changing memory or disk" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_bytes = "\x89PNG\r\n\x1a\nlegacy-oom";
    const path = try writeSessionTestImage(alloc, &tmp, "legacy-oom.png", image_bytes);
    defer alloc.free(path);
    var reached_success = false;
    for (0..256) |fail_index| {
        var name_buf: [64]u8 = undefined;
        const snapshot_name = try std.fmt.bufPrint(
            &name_buf,
            "snapshots-{d}",
            .{fail_index},
        );
        const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
        defer alloc.free(root);
        const snapshot_dir = try std.fs.path.join(alloc, &.{ root, snapshot_name });
        defer alloc.free(snapshot_dir);
        const turn = try make_owned_legacy_image_turn(
            alloc,
            "legacy [Image #1]",
            "answer",
            path,
        );
        var history = [_]HistoryTurn{turn};
        var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = fail_index });

        if (repair_legacy_images_transactionally(
            failing.allocator(),
            &history,
            snapshot_dir,
        )) |changed| {
            try std.testing.expect(changed);
            try std.testing.expect(!failing.has_induced_failure);
            freeHistoryTurn(failing.allocator(), history[0]);
            reached_success = true;
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(failing.has_induced_failure);
            try std.testing.expectEqualStrings("legacy [Image #1]", history[0].assistant.user.text);
            try std.testing.expectEqual(@as(usize, 1), history[0].assistant.user.images.len);
            const image = history[0].assistant.user.images[0];
            try std.testing.expectEqual(@as(usize, 0), image.id);
            try std.testing.expectEqualStrings(path, image.path);
            try std.testing.expect(image.snapshot_path == null);
            try std.testing.expect(image.snapshot_sha256 == null);
            try std.testing.expectError(
                error.FileNotFound,
                std.Io.Dir.openDirAbsolute(std.testing.io, snapshot_dir, .{ .iterate = true }),
            );
            freeHistoryTurn(alloc, history[0]);
        }
    }
    try std.testing.expect(reached_success);
}

test "legacy image repair rewrites repeated per-turn ordinals to stable session ids" {
    const alloc = std.testing.allocator;
    const first = try make_owned_legacy_image_turn(
        alloc,
        "first prose [Image #1] tail",
        "first answer",
        "/tmp/legacy-first.png",
    );
    var first_owned = true;
    errdefer if (first_owned) freeHistoryTurn(alloc, first);
    const second = try make_owned_legacy_image_turn(
        alloc,
        "second prose [Image #1] tail",
        "second answer",
        "/tmp/legacy-second.png",
    );
    var second_owned = true;
    errdefer if (second_owned) freeHistoryTurn(alloc, second);
    var history = [_]HistoryTurn{
        first,
        second,
    };
    defer for (history) |turn| freeHistoryTurn(alloc, turn);
    first_owned = false;
    second_owned = false;

    try std.testing.expect(try repair_legacy_zero_image_ids(alloc, &history));

    try std.testing.expectEqual(@as(usize, 1), history[0].assistant.user.images[0].id);
    try std.testing.expectEqualStrings(
        "first prose [Image #1] tail",
        history[0].assistant.user.text,
    );
    try std.testing.expectEqual(@as(usize, 2), history[1].assistant.user.images[0].id);
    try std.testing.expectEqualStrings(
        "second prose [Image #2] tail",
        history[1].assistant.user.text,
    );
    try std.testing.expectEqualStrings(
        "/tmp/legacy-first.png",
        history[0].assistant.user.images[0].path,
    );
    try std.testing.expectEqualStrings(
        "/tmp/legacy-second.png",
        history[1].assistant.user.images[0].path,
    );

    var first_badge: std.Io.Writer.Allocating = .init(alloc);
    defer first_badge.deinit();
    _ = try image_attachments.expandPlaceholdersWithBadges(
        alloc,
        &first_badge.writer,
        history[0].assistant.user.text,
        history[0].assistant.user.images,
        null,
    );
    try std.testing.expect(std.mem.find(u8, first_badge.written(), "[Image 1]") != null);
    try std.testing.expect(std.mem.find(u8, first_badge.written(), "file://") == null);
    try std.testing.expect(std.mem.find(u8, first_badge.written(), "/tmp/legacy-first.png") == null);
    try std.testing.expect(std.mem.find(u8, first_badge.written(), "/tmp/legacy-second.png") == null);

    var second_badge: std.Io.Writer.Allocating = .init(alloc);
    defer second_badge.deinit();
    _ = try image_attachments.expandPlaceholdersWithBadges(
        alloc,
        &second_badge.writer,
        history[1].assistant.user.text,
        history[1].assistant.user.images,
        null,
    );
    try std.testing.expect(std.mem.find(u8, second_badge.written(), "[Image 2]") != null);
    try std.testing.expect(std.mem.find(u8, second_badge.written(), "file://") == null);
    try std.testing.expect(std.mem.find(u8, second_badge.written(), "/tmp/legacy-second.png") == null);
    try std.testing.expect(std.mem.find(u8, second_badge.written(), "/tmp/legacy-first.png") == null);

    const catalog = try collect_image_catalog(alloc, &history, &.{});
    defer freeImageAttachmentSlice(alloc, catalog);
    const authorized = try image_attachments.resolve_authorized_images(alloc, catalog, &.{2});
    defer alloc.free(authorized);
    try std.testing.expectEqual(@as(usize, 1), authorized.len);
    try std.testing.expectEqualStrings("/tmp/legacy-second.png", authorized[0].path);

    const bounds = try image_attachments.calculate_next_image_id(catalog);
    try std.testing.expectEqual(@as(?usize, 2), bounds.maximum_id);
    try std.testing.expectEqual(@as(usize, 3), bounds.next_id);
}

test "legacy image repair rewrites three repeated ordinals across persisted turn variants" {
    const alloc = std.testing.allocator;
    const assistant_text = try alloc.dupe(u8, "assistant [Image #1]");
    var assistant_text_owned = true;
    errdefer if (assistant_text_owned) alloc.free(assistant_text);
    const background_text = try alloc.dupe(u8, "background [Image #1]");
    var background_text_owned = true;
    errdefer if (background_text_owned) alloc.free(background_text);
    const interrupted_text = try alloc.dupe(u8, "interrupted [Image #1]");
    var interrupted_text_owned = true;
    errdefer if (interrupted_text_owned) alloc.free(interrupted_text);

    var assistant_images = [_]ImageAttachment{.{
        .id = 0,
        .path = @constCast("/tmp/assistant-one.png"),
        .media_type = @constCast("image/png"),
    }};
    var background_images = [_]ImageAttachment{.{
        .id = 0,
        .path = @constCast("/tmp/background-one.png"),
        .media_type = @constCast("image/png"),
    }};
    var interrupted_images = [_]ImageAttachment{.{
        .id = 0,
        .path = @constCast("/tmp/interrupted-one.png"),
        .media_type = @constCast("image/png"),
    }};
    var history = [_]HistoryTurn{
        .{ .assistant = .{
            .user = .{ .text = assistant_text, .images = &assistant_images },
            .assistant = @constCast("answer"),
        } },
        .{ .assistant = .{
            .user = .{ .text = background_text, .images = &background_images },
            .assistant = @constCast("historical command"),
        } },
        .{ .interrupted = .{
            .user = .{ .text = interrupted_text, .images = &interrupted_images },
            .assistant = @constCast("partial"),
        } },
    };
    defer alloc.free(history[0].assistant.user.text);
    defer alloc.free(history[1].assistant.user.text);
    defer alloc.free(history[2].interrupted.user.text);
    assistant_text_owned = false;
    background_text_owned = false;
    interrupted_text_owned = false;

    try std.testing.expect(try repair_legacy_zero_image_ids(alloc, &history));

    try std.testing.expectEqual(@as(usize, 1), assistant_images[0].id);
    try std.testing.expectEqual(@as(usize, 2), background_images[0].id);
    try std.testing.expectEqual(@as(usize, 3), interrupted_images[0].id);
    try std.testing.expectEqualStrings("assistant [Image #1]", history[0].assistant.user.text);
    try std.testing.expectEqualStrings(
        "background [Image #2]",
        history[1].assistant.user.text,
    );
    try std.testing.expectEqualStrings(
        "interrupted [Image #3]",
        history[2].interrupted.user.text,
    );
}

test "legacy image repair leaves history unchanged when text reconstruction runs out of memory" {
    const alloc = std.testing.allocator;
    var first_images = [_]ImageAttachment{.{
        .id = 0,
        .path = @constCast("/tmp/first.png"),
        .media_type = @constCast("image/png"),
    }};
    var second_images = [_]ImageAttachment{.{
        .id = 0,
        .path = @constCast("/tmp/second.png"),
        .media_type = @constCast("image/png"),
    }};
    var third_images = [_]ImageAttachment{.{
        .id = 0,
        .path = @constCast("/tmp/third.png"),
        .media_type = @constCast("image/png"),
    }};
    const first_text = try alloc.dupe(u8, "first [Image #1]");
    var first_text_owned = true;
    errdefer if (first_text_owned) alloc.free(first_text);
    const second_text = try alloc.dupe(u8, "second [Image #1]");
    var second_text_owned = true;
    errdefer if (second_text_owned) alloc.free(second_text);
    const third_text = try alloc.dupe(u8, "third [Image #1]");
    var third_text_owned = true;
    errdefer if (third_text_owned) alloc.free(third_text);
    var history = [_]HistoryTurn{
        .{ .assistant = .{
            .user = .{ .text = first_text, .images = &first_images },
            .assistant = @constCast("answer"),
        } },
        .{ .assistant = .{
            .user = .{ .text = second_text, .images = &second_images },
            .assistant = @constCast("answer"),
        } },
        .{ .assistant = .{
            .user = .{ .text = third_text, .images = &third_images },
            .assistant = @constCast("answer"),
        } },
    };
    defer alloc.free(history[0].assistant.user.text);
    defer alloc.free(history[1].assistant.user.text);
    defer alloc.free(history[2].assistant.user.text);
    first_text_owned = false;
    second_text_owned = false;
    third_text_owned = false;

    // Metadata and the first rebuilt turn succeed; the second rebuild fails.
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 2 });
    try std.testing.expectError(
        error.OutOfMemory,
        repair_legacy_zero_image_ids(failing.allocator(), &history),
    );

    try std.testing.expectEqual(@as(usize, 0), first_images[0].id);
    try std.testing.expectEqual(@as(usize, 0), second_images[0].id);
    try std.testing.expectEqual(@as(usize, 0), third_images[0].id);
    try std.testing.expectEqualStrings("first [Image #1]", history[0].assistant.user.text);
    try std.testing.expectEqualStrings("second [Image #1]", history[1].assistant.user.text);
    try std.testing.expectEqualStrings("third [Image #1]", history[2].assistant.user.text);
}

test "legacy image repair preserves canonical placeholder identity by attachment order" {
    var first_images = [_]ImageAttachment{.{
        .id = 0,
        .path = @constCast("/tmp/five.png"),
        .media_type = @constCast("image/png"),
    }};
    var mixed_images = [_]ImageAttachment{
        .{
            .id = 0,
            .path = @constCast("/tmp/nine.png"),
            .media_type = @constCast("image/png"),
        },
        .{
            .id = 3,
            .path = @constCast("/tmp/three.png"),
            .media_type = @constCast("image/png"),
        },
    };
    var skipped_images = [_]ImageAttachment{.{
        .id = 0,
        .path = @constCast("/tmp/twelve.png"),
        .media_type = @constCast("image/png"),
    }};
    var history = [_]HistoryTurn{
        .{ .assistant = .{
            .user = .{ .text = @constCast("first [Image #5]"), .images = &first_images },
            .assistant = @constCast("first answer"),
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("mixed [Image #9] [Image #3]"), .images = &mixed_images },
            .assistant = @constCast("mixed answer"),
        } },
        .{ .interrupted = .{
            .user = .{ .text = @constCast("later [Image #12]"), .images = &skipped_images },
            .assistant = @constCast("partial"),
        } },
    };

    _ = try repair_legacy_zero_image_ids(std.testing.allocator, &history);

    try std.testing.expectEqual(@as(usize, 5), first_images[0].id);
    try std.testing.expectEqual(@as(usize, 9), mixed_images[0].id);
    try std.testing.expectEqual(@as(usize, 3), mixed_images[1].id);
    try std.testing.expectEqual(@as(usize, 12), skipped_images[0].id);
    try std.testing.expectEqualStrings("first [Image #5]", history[0].assistant.user.text);
    try std.testing.expectEqualStrings("/tmp/five.png", first_images[0].path);
}

test "legacy image repair reserves a later low placeholder before an earlier fallback" {
    var fallback_images = [_]ImageAttachment{.{
        .id = 0,
        .path = @constCast("/tmp/fallback.png"),
        .media_type = @constCast("image/png"),
    }};
    var reserved_images = [_]ImageAttachment{.{
        .id = 0,
        .path = @constCast("/tmp/reserved-one.png"),
        .media_type = @constCast("image/png"),
    }};
    var history = [_]HistoryTurn{
        .{ .assistant = .{
            .user = .{ .text = @constCast("missing placeholder"), .images = &fallback_images },
            .assistant = @constCast("fallback answer"),
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("reserved [Image #1]"), .images = &reserved_images },
            .assistant = @constCast("reserved answer"),
        } },
    };

    _ = try repair_legacy_zero_image_ids(std.testing.allocator, &history);

    try std.testing.expectEqual(@as(usize, 2), fallback_images[0].id);
    try std.testing.expectEqual(@as(usize, 1), reserved_images[0].id);
}

test "legacy image repair preserves a low reservation before a later fallback" {
    var reserved_images = [_]ImageAttachment{.{
        .id = 0,
        .path = @constCast("/tmp/reserved-one.png"),
        .media_type = @constCast("image/png"),
    }};
    var fallback_images = [_]ImageAttachment{.{
        .id = 0,
        .path = @constCast("/tmp/fallback.png"),
        .media_type = @constCast("image/png"),
    }};
    var history = [_]HistoryTurn{
        .{ .assistant = .{
            .user = .{ .text = @constCast("reserved [Image #1]"), .images = &reserved_images },
            .assistant = @constCast("reserved answer"),
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("missing placeholder"), .images = &fallback_images },
            .assistant = @constCast("fallback answer"),
        } },
    };

    _ = try repair_legacy_zero_image_ids(std.testing.allocator, &history);

    try std.testing.expectEqual(@as(usize, 1), reserved_images[0].id);
    try std.testing.expectEqual(@as(usize, 2), fallback_images[0].id);
}

test "legacy image repair reserves low ids before interleaved fallbacks across turns" {
    var missing_images = [_]ImageAttachment{.{
        .id = 0,
        .path = @constCast("/tmp/missing.png"),
        .media_type = @constCast("image/png"),
    }};
    var reserved_one_images = [_]ImageAttachment{.{
        .id = 0,
        .path = @constCast("/tmp/reserved-one.png"),
        .media_type = @constCast("image/png"),
    }};
    var malformed_images = [_]ImageAttachment{.{
        .id = 0,
        .path = @constCast("/tmp/malformed.png"),
        .media_type = @constCast("image/png"),
    }};
    var reserved_two_images = [_]ImageAttachment{.{
        .id = 0,
        .path = @constCast("/tmp/reserved-two.png"),
        .media_type = @constCast("image/png"),
    }};
    var later_missing_images = [_]ImageAttachment{.{
        .id = 0,
        .path = @constCast("/tmp/later-missing.png"),
        .media_type = @constCast("image/png"),
    }};
    var reserved_four_images = [_]ImageAttachment{.{
        .id = 0,
        .path = @constCast("/tmp/reserved-four.png"),
        .media_type = @constCast("image/png"),
    }};
    var positive_images = [_]ImageAttachment{.{
        .id = 5,
        .path = @constCast("/tmp/positive-five.png"),
        .media_type = @constCast("image/png"),
    }};
    var history = [_]HistoryTurn{
        .{ .assistant = .{
            .user = .{ .text = @constCast("missing placeholder"), .images = &missing_images },
            .assistant = @constCast("answer"),
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("reserved [Image #1]"), .images = &reserved_one_images },
            .assistant = @constCast("answer"),
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("malformed [Image #oops]"), .images = &malformed_images },
            .assistant = @constCast("answer"),
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("reserved [Image #2]"), .images = &reserved_two_images },
            .assistant = @constCast("answer"),
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("later missing placeholder"), .images = &later_missing_images },
            .assistant = @constCast("answer"),
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("reserved [Image #4]"), .images = &reserved_four_images },
            .assistant = @constCast("answer"),
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("existing positive"), .images = &positive_images },
            .assistant = @constCast("answer"),
        } },
    };

    _ = try repair_legacy_zero_image_ids(std.testing.allocator, &history);

    try std.testing.expectEqual(@as(usize, 3), missing_images[0].id);
    try std.testing.expectEqual(@as(usize, 1), reserved_one_images[0].id);
    try std.testing.expectEqual(@as(usize, 6), malformed_images[0].id);
    try std.testing.expectEqual(@as(usize, 2), reserved_two_images[0].id);
    try std.testing.expectEqual(@as(usize, 7), later_missing_images[0].id);
    try std.testing.expectEqual(@as(usize, 4), reserved_four_images[0].id);
    try std.testing.expectEqual(@as(usize, 5), positive_images[0].id);
}

test "legacy image repair gives existing positive ids priority over placeholder claims" {
    const alloc = std.testing.allocator;
    const conflicting_text = try alloc.dupe(u8, "conflicting [Image #1]");
    var positive_images = [_]ImageAttachment{.{
        .id = 1,
        .path = @constCast("/tmp/positive-one.png"),
        .media_type = @constCast("image/png"),
    }};
    var conflicting_images = [_]ImageAttachment{.{
        .id = 0,
        .path = @constCast("/tmp/conflicting-one.png"),
        .media_type = @constCast("image/png"),
    }};
    var history = [_]HistoryTurn{
        .{ .assistant = .{
            .user = .{ .text = @constCast("existing positive"), .images = &positive_images },
            .assistant = @constCast("answer"),
        } },
        .{ .assistant = .{
            .user = .{ .text = conflicting_text, .images = &conflicting_images },
            .assistant = @constCast("answer"),
        } },
    };
    defer alloc.free(history[1].assistant.user.text);

    _ = try repair_legacy_zero_image_ids(alloc, &history);

    try std.testing.expectEqual(@as(usize, 1), positive_images[0].id);
    try std.testing.expectEqual(@as(usize, 2), conflicting_images[0].id);
    try std.testing.expectEqualStrings("conflicting [Image #2]", history[1].assistant.user.text);
}

test "legacy image repair falls back for missing malformed zero duplicate and conflicting placeholders" {
    const alloc = std.testing.allocator;
    const conflicting_text = try alloc.dupe(u8, "conflict [Image #3]");
    var conflicting_text_owned = true;
    errdefer if (conflicting_text_owned) alloc.free(conflicting_text);
    const zero_text = try alloc.dupe(u8, "zero [Image #0]");
    var zero_text_owned = true;
    errdefer if (zero_text_owned) alloc.free(zero_text);
    const duplicate_text = try alloc.dupe(u8, "duplicate [Image #50] [Image #50]");
    var duplicate_text_owned = true;
    errdefer if (duplicate_text_owned) alloc.free(duplicate_text);
    var positive_images = [_]ImageAttachment{.{
        .id = 3,
        .path = @constCast("/tmp/positive.png"),
        .media_type = @constCast("image/png"),
    }};
    var conflicting_images = [_]ImageAttachment{.{
        .id = 0,
        .path = @constCast("/tmp/conflicting.png"),
        .media_type = @constCast("image/png"),
    }};
    var missing_images = [_]ImageAttachment{.{
        .id = 0,
        .path = @constCast("/tmp/missing.png"),
        .media_type = @constCast("image/png"),
    }};
    var malformed_images = [_]ImageAttachment{.{
        .id = 0,
        .path = @constCast("/tmp/malformed.png"),
        .media_type = @constCast("image/png"),
    }};
    var zero_images = [_]ImageAttachment{.{
        .id = 0,
        .path = @constCast("/tmp/zero.png"),
        .media_type = @constCast("image/png"),
    }};
    var duplicate_images = [_]ImageAttachment{
        .{
            .id = 0,
            .path = @constCast("/tmp/duplicate-a.png"),
            .media_type = @constCast("image/png"),
        },
        .{
            .id = 0,
            .path = @constCast("/tmp/duplicate-b.png"),
            .media_type = @constCast("image/png"),
        },
    };
    var history = [_]HistoryTurn{
        .{ .assistant = .{
            .user = .{ .text = @constCast("owned [Image #3]"), .images = &positive_images },
            .assistant = @constCast("answer"),
        } },
        .{ .assistant = .{
            .user = .{ .text = conflicting_text, .images = &conflicting_images },
            .assistant = @constCast("answer"),
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("missing placeholder"), .images = &missing_images },
            .assistant = @constCast("answer"),
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("malformed [Image #oops]"), .images = &malformed_images },
            .assistant = @constCast("answer"),
        } },
        .{ .assistant = .{
            .user = .{ .text = zero_text, .images = &zero_images },
            .assistant = @constCast("answer"),
        } },
        .{ .assistant = .{
            .user = .{ .text = duplicate_text, .images = &duplicate_images },
            .assistant = @constCast("answer"),
        } },
    };
    defer alloc.free(history[1].assistant.user.text);
    defer alloc.free(history[4].assistant.user.text);
    defer alloc.free(history[5].assistant.user.text);
    conflicting_text_owned = false;
    zero_text_owned = false;
    duplicate_text_owned = false;

    _ = try repair_legacy_zero_image_ids(alloc, &history);

    try std.testing.expectEqual(@as(usize, 3), positive_images[0].id);
    try std.testing.expectEqual(@as(usize, 1), conflicting_images[0].id);
    try std.testing.expectEqual(@as(usize, 2), missing_images[0].id);
    try std.testing.expectEqual(@as(usize, 4), malformed_images[0].id);
    try std.testing.expectEqual(@as(usize, 5), zero_images[0].id);
    try std.testing.expectEqual(@as(usize, 6), duplicate_images[0].id);
    try std.testing.expectEqual(@as(usize, 7), duplicate_images[1].id);
    try std.testing.expectEqualStrings("owned [Image #3]", history[0].assistant.user.text);
    try std.testing.expectEqualStrings("conflict [Image #1]", history[1].assistant.user.text);
    try std.testing.expectEqualStrings("missing placeholder", history[2].assistant.user.text);
    try std.testing.expectEqualStrings("malformed [Image #oops]", history[3].assistant.user.text);
    try std.testing.expectEqualStrings("zero [Image #5]", history[4].assistant.user.text);
    try std.testing.expectEqualStrings(
        "duplicate [Image #6] [Image #7]",
        history[5].assistant.user.text,
    );
}

test "legacy image repair binds transcript and Vision authorization to reserved paths" {
    const alloc = std.testing.allocator;
    var fallback_images = [_]ImageAttachment{.{
        .id = 0,
        .path = @constCast("/tmp/fallback.png"),
        .media_type = @constCast("image/png"),
    }};
    var reserved_images = [_]ImageAttachment{.{
        .id = 0,
        .path = @constCast("/tmp/reserved-one.png"),
        .media_type = @constCast("image/png"),
    }};
    var history = [_]HistoryTurn{
        .{ .assistant = .{
            .user = .{ .text = @constCast("missing placeholder"), .images = &fallback_images },
            .assistant = @constCast("fallback answer"),
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("inspect [Image #1]"), .images = &reserved_images },
            .assistant = @constCast("reserved answer"),
        } },
    };

    _ = try repair_legacy_zero_image_ids(std.testing.allocator, &history);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const expanded = try image_attachments.expandPlaceholdersWithBadges(
        alloc,
        &out.writer,
        history[1].assistant.user.text,
        history[1].assistant.user.images,
        null,
    );
    const catalog = try collect_image_catalog(alloc, &history, &.{});
    defer freeImageAttachmentSlice(alloc, catalog);
    const authorized = try image_attachments.resolve_authorized_images(alloc, catalog, &.{ 1, 2 });
    defer alloc.free(authorized);

    try std.testing.expect(expanded.expanded_any);
    try std.testing.expect(std.mem.find(u8, out.written(), "[Image 1]") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "file://") == null);
    try std.testing.expect(std.mem.find(u8, out.written(), "/tmp/reserved-one.png") == null);
    try std.testing.expect(std.mem.find(u8, out.written(), "/tmp/fallback.png") == null);
    try std.testing.expect(std.mem.find(u8, out.written(), "[Image #1]") == null);
    try std.testing.expectEqualStrings("/tmp/reserved-one.png", authorized[0].path);
    try std.testing.expectEqualStrings("/tmp/fallback.png", authorized[1].path);
}

fn history_contains_image_id(history: []const HistoryTurn, id: usize) bool {
    for (history) |turn| {
        for (images_for_history_turn(turn)) |attachment| {
            if (attachment.id == id) return true;
        }
    }
    return false;
}

fn image_id_less_than(_: void, lhs: ImageAttachment, rhs: ImageAttachment) bool {
    return lhs.id < rhs.id;
}

pub const PersistedToolArgumentsSource = enum {
    schema_v3,
    legacy,
};

pub fn repairPersistedToolArguments(
    alloc: Allocator,
    calls: []ToolCall,
    results: []PersistedToolResult,
    source: PersistedToolArgumentsSource,
) !void {
    for (calls) |call| {
        if (call.argument_integrity != .valid) {
            _ = try persistedResultForMalformedCall(calls, results, call);
        }
    }

    for (calls) |*call| {
        if (call.argument_integrity == .valid) continue;
        const result = try persistedResultForMalformedCall(calls, results, call.*);
        const integrity = call.argument_integrity;
        if (integrity == .non_object_json) {
            // Repair replay input without changing what the stored result says happened.
            if (call.provider_result != null or result.provider_native) {
                call.provenance = .provider_executed;
                call.argument_integrity = .valid;
                continue;
            }
            const safe_arguments = try alloc.dupe(u8, "{}");
            alloc.free(call.arguments_json);
            call.arguments_json = safe_arguments;
            call.argument_integrity = .valid;
            tracePersistedToolArgumentsRepair(call.*, source, true, integrity);
            continue;
        }
        const failure_output = try tool_result_errors.malformedToolArgumentsJson(alloc, call.name);

        alloc.free(result.output);
        if (result.output_handle) |handle| alloc.free(handle);
        if (result.preview) |preview| alloc.free(preview);
        result.status = .failure;
        result.output = failure_output;
        result.output_handle = null;
        result.preview = null;
        result.output_bytes = failure_output.len;
        result.stored_output_bytes = failure_output.len;
        result.truncated = false;
        result.provider_native = false;
        call.argument_integrity = .valid;
        tracePersistedToolArgumentsRepair(call.*, source, true, integrity);
    }
}

pub fn repairPersistedInterruptedToolArguments(
    alloc: Allocator,
    call: *ToolCall,
    source: PersistedToolArgumentsSource,
) Allocator.Error!void {
    if (call.argument_integrity == .valid) return;
    const integrity = call.argument_integrity;
    if (integrity == .non_object_json) {
        if (call.provider_result != null) {
            call.provenance = .provider_executed;
            call.argument_integrity = .valid;
            return;
        }
        const safe_arguments = try alloc.dupe(u8, "{}");
        alloc.free(call.arguments_json);
        call.arguments_json = safe_arguments;
    }
    call.argument_integrity = .valid;
    tracePersistedToolArgumentsRepair(call.*, source, false, integrity);
}

fn persistedResultForMalformedCall(
    calls: []ToolCall,
    results: []PersistedToolResult,
    call: ToolCall,
) !*PersistedToolResult {
    var matching_calls: usize = 0;
    for (calls) |candidate| {
        if (std.mem.eql(u8, candidate.id, call.id)) matching_calls += 1;
    }
    if (matching_calls != 1) return error.InvalidSessionFormat;

    var matched_result: ?*PersistedToolResult = null;
    for (results) |*result| {
        if (!std.mem.eql(u8, result.tool_call_id, call.id)) continue;
        if (matched_result != null) return error.InvalidSessionFormat;
        matched_result = result;
    }

    const result = matched_result orelse return error.InvalidSessionFormat;
    if (!std.mem.eql(u8, result.tool_name, call.name)) return error.InvalidSessionFormat;
    return result;
}

fn tracePersistedToolArgumentsRepair(
    call: ToolCall,
    source: PersistedToolArgumentsSource,
    paired_result: bool,
    integrity: core_types.ToolArgumentIntegrity,
) void {
    debug_trace.eventf(
        "session",
        "persisted_tool_arguments_repaired",
        .{},
        "source={s} call_id={s} tool={s} failure={s} paired_result={s}",
        .{ @tagName(source), call.id, call.name, @tagName(integrity), if (paired_result) "true" else "false" },
    );
}

pub const WebFetchArtifactState = union(enum) {
    none,
    store: web_fetch_artifacts.Store,
    unavailable: anyerror,
};

pub const SessionRuntime = struct {
    agent: kernel_agent.Agent = .{},
    context_notice_hashes: std.AutoHashMapUnmanaged(u64, void) = .empty,
    context_notice_lock: std.Io.Mutex = .init,
    web_fetch_artifacts: WebFetchArtifactState = .none,
    language_lock: std.Io.Mutex = .init,
    conversation_language: ConversationLanguage = ConversationLanguage.default(),
    usage: session_usage.Usage = session_usage.Usage.initFresh(),
    profile_usage: profile_usage_runtime.Runtime = .{},
    permission_state_lock: std.Io.Mutex = .init,
    permission_state: session_permission_state.State = .{},
    /// Count limit for owned model-context snapshots; canonical history is not truncated.
    max_history_turns: usize,
    /// In-memory boundary for handle-free history loaded without writer
    /// provenance. It is never persisted; accepted checkpoints move the model
    /// window beyond it.
    unversioned_history_len: usize = 0,

    pub fn init(
        max_history_turns: usize,
        provider: generation_usage_provider.Provider,
    ) SessionRuntime {
        return .{
            .usage = session_usage.Usage.initFreshWithProvider(provider),
            .max_history_turns = max_history_turns,
        };
    }

    pub fn initWithProviders(
        max_history_turns: usize,
        providers: generation_usage_provider.Set,
    ) SessionRuntime {
        return .{
            .usage = session_usage.Usage.initFreshWithProviders(providers),
            .max_history_turns = max_history_turns,
        };
    }

    pub fn deinit(self: *SessionRuntime, alloc: Allocator) void {
        self.clearWebFetchArtifacts();
        self.usage.configurePublicationSink(null);
        self.usage.configureCheckpointSink(null);
        self.usage.deinit(alloc);
        self.profile_usage.deinit(alloc);
        self.permission_state.deinit(alloc);
        self.agent.deinit(alloc);
        self.context_notice_hashes.deinit(alloc);
    }

    pub fn initializeProfileUsage(
        self: *SessionRuntime,
        alloc: Allocator,
        home_path: ?[]const u8,
    ) !profile_usage_runtime.InitializeOutcome {
        self.usage.configurePublicationSink(null);
        return self.profile_usage.initialize(alloc, home_path);
    }

    /// Attaches callbacks only after the host has placed SessionRuntime at its
    /// final address.
    pub fn attachProfileUsagePublisher(
        self: *SessionRuntime,
        alloc: Allocator,
    ) void {
        self.usage.configurePublicationSink(
            if (self.profile_usage.isAvailable())
                self.profile_usage.publisherSink(alloc)
            else
                null,
        );
    }

    pub fn ensureProfileUsageReadable(
        self: *SessionRuntime,
        alloc: Allocator,
        home_path: ?[]const u8,
    ) !profile_usage_runtime.InitializeOutcome {
        if (self.profile_usage.isAvailable()) return .available;
        return self.initializeProfileUsage(alloc, home_path);
    }

    pub fn reset(self: *SessionRuntime, alloc: Allocator) void {
        self.clearWebFetchArtifacts();
        self.usage.resetFresh(alloc);
        self.clearPermissionState(alloc);
        self.clearHistory(alloc);
        self.clearContextNotices();
        self.setConversationLanguage(ConversationLanguage.default());
    }

    pub fn restore(self: *SessionRuntime, alloc: Allocator, language: ConversationLanguage, history: []const HistoryTurn) !void {
        self.clearWebFetchArtifacts();
        self.usage.resetLegacy(alloc);
        self.clearPermissionState(alloc);
        self.clearHistory(alloc);
        self.clearContextNotices();
        self.setConversationLanguage(language);

        for (history) |turn| {
            try self.appendHistoryEntry(alloc, turn);
        }
        self.unversioned_history_len = if (self.agent.history.items.len > 0 and
            isCurrentCompactionCheckpoint(self.agent.history.items[0]))
            0
        else
            self.agent.history.items.len;
    }

    pub fn restoreWithPermissionState(
        self: *SessionRuntime,
        alloc: Allocator,
        language: ConversationLanguage,
        history: []const HistoryTurn,
        permission_state: session_permission_state.State,
    ) !void {
        var permission_copy = try session_permission_state.dupe(
            alloc,
            permission_state,
        );
        errdefer permission_copy.deinit(alloc);
        try self.restore(alloc, language, history);
        self.permission_state_lock.lockUncancelable(io_mod.getIo());
        defer self.permission_state_lock.unlock(io_mod.getIo());
        self.permission_state.deinit(alloc);
        self.permission_state = permission_copy;
    }

    pub fn snapshotPermissionState(
        self: *SessionRuntime,
        alloc: Allocator,
    ) !session_permission_state.State {
        self.permission_state_lock.lockUncancelable(io_mod.getIo());
        defer self.permission_state_lock.unlock(io_mod.getIo());
        return session_permission_state.dupe(alloc, self.permission_state);
    }

    pub fn applyPermissionEvent(
        self: *SessionRuntime,
        alloc: Allocator,
        event: session_permission_state.ConfirmedRuleEvent,
    ) !session_permission_state.ApplyStatus {
        self.permission_state_lock.lockUncancelable(io_mod.getIo());
        defer self.permission_state_lock.unlock(io_mod.getIo());
        const result = try session_permission_state.apply(
            alloc,
            self.permission_state,
            event,
        );
        return switch (result) {
            .applied => |next| blk: {
                self.permission_state.deinit(alloc);
                self.permission_state = next;
                break :blk .applied;
            },
            .stale => .stale,
            .full => .full,
            .invalid => .invalid,
        };
    }

    pub fn replacePermissionStateOwned(
        self: *SessionRuntime,
        alloc: Allocator,
        state: *session_permission_state.State,
    ) void {
        self.permission_state_lock.lockUncancelable(io_mod.getIo());
        defer self.permission_state_lock.unlock(io_mod.getIo());
        self.permission_state.deinit(alloc);
        self.permission_state = state.*;
        state.* = .{};
    }

    fn clearPermissionState(self: *SessionRuntime, alloc: Allocator) void {
        self.permission_state_lock.lockUncancelable(io_mod.getIo());
        defer self.permission_state_lock.unlock(io_mod.getIo());
        self.permission_state.deinit(alloc);
    }

    pub fn configureWebFetchArtifacts(self: *SessionRuntime, alloc: Allocator, session_dir: []const u8) void {
        self.clearWebFetchArtifacts();
        const store = web_fetch_artifacts.Store.init(alloc, session_dir) catch |err| {
            self.web_fetch_artifacts = .{ .unavailable = err };
            return;
        };
        self.web_fetch_artifacts = .{ .store = store };
    }

    pub fn clearWebFetchArtifacts(self: *SessionRuntime) void {
        switch (self.web_fetch_artifacts) {
            .store => |*store| store.deinit(),
            .none, .unavailable => {},
        }
        self.web_fetch_artifacts = .none;
    }

    /// Returns true once for each distinct source-limit notice in this live
    /// session. Size and limit are part of the rendered notice, so either
    /// changing makes the updated condition visible again.
    pub fn claimContextNotice(self: *SessionRuntime, alloc: Allocator, notice: []const u8) !bool {
        self.context_notice_lock.lockUncancelable(io_mod.getIo());
        defer self.context_notice_lock.unlock(io_mod.getIo());
        const result = try self.context_notice_hashes.getOrPut(
            alloc,
            std.hash.Wyhash.hash(0, notice),
        );
        return !result.found_existing;
    }

    pub fn clearContextNotices(self: *SessionRuntime) void {
        self.context_notice_lock.lockUncancelable(io_mod.getIo());
        defer self.context_notice_lock.unlock(io_mod.getIo());
        self.context_notice_hashes.clearRetainingCapacity();
    }

    pub fn webFetchArtifactStore(self: *SessionRuntime) ?*web_fetch_artifacts.Store {
        return switch (self.web_fetch_artifacts) {
            .store => |*store| store,
            .none, .unavailable => null,
        };
    }

    pub fn webFetchArtifactError(self: *SessionRuntime) ?anyerror {
        return switch (self.web_fetch_artifacts) {
            .unavailable => |err| err,
            .none, .store => null,
        };
    }

    pub fn clearHistory(self: *SessionRuntime, alloc: Allocator) void {
        self.agent.clearHistory(alloc);
        self.unversioned_history_len = 0;
    }

    pub fn historyLen(self: *const SessionRuntime) usize {
        return self.agent.history.items.len;
    }

    pub fn unversionedHistoryEnd(self: *const SessionRuntime) usize {
        return @min(self.unversioned_history_len, self.agent.history.items.len);
    }

    pub fn hasContextToCompact(self: *const SessionRuntime) bool {
        for (self.agent.history.items) |turn| {
            if (turn != .compacted_summary) return true;
        }
        return false;
    }

    pub fn compactedTurnCount(self: *const SessionRuntime) usize {
        if (self.agent.history.items.len == 0) return 0;
        return switch (self.agent.history.items[0]) {
            .compacted_summary => |entry| entry.removed_turn_count,
            else => 0,
        };
    }

    pub fn compactionCount(self: *const SessionRuntime) usize {
        if (self.agent.history.items.len == 0) return 0;
        return switch (self.agent.history.items[0]) {
            .compacted_summary => |entry| entry.compaction_count,
            else => 0,
        };
    }

    pub fn snapshotHistory(self: *const SessionRuntime, alloc: Allocator) ![]HistoryTurn {
        return self.agent.snapshotHistory(alloc);
    }

    pub fn snapshotImageCatalog(
        self: *const SessionRuntime,
        alloc: Allocator,
        current_images: []const ImageAttachment,
    ) ![]ImageAttachment {
        return collect_image_catalog(alloc, self.agent.history.items, current_images);
    }

    pub fn snapshotContextHistory(self: *const SessionRuntime, alloc: Allocator) ![]HistoryTurn {
        return snapshotOwnedContextHistory(
            alloc,
            self.agent.history.items,
            0,
            self.max_history_turns,
        );
    }

    pub fn appendHistoryEntry(self: *SessionRuntime, alloc: Allocator, turn: HistoryTurn) !void {
        const prepared = try self.prepareHistoryEntry(alloc, turn);
        self.commitPreparedHistoryEntry(alloc, prepared);
    }

    pub fn prepareHistoryEntry(
        self: *SessionRuntime,
        alloc: Allocator,
        turn: HistoryTurn,
    ) !HistoryTurn {
        try self.agent.history.ensureUnusedCapacity(alloc, 1);
        return dupeHistoryTurn(alloc, turn);
    }

    pub fn commitPreparedHistoryEntry(
        self: *SessionRuntime,
        alloc: Allocator,
        turn: HistoryTurn,
    ) void {
        if (isCurrentCompactionCheckpoint(turn)) {
            self.agent.clearHistory(alloc);
            self.unversioned_history_len = 0;
        }
        self.agent.history.appendAssumeCapacity(turn);
        self.agent.fresh = false;
        if (turn == .compacted_summary and isCurrentCompactionCheckpoint(turn)) {
            self.unversioned_history_len = 0;
        }
    }

    /// Takes ownership of a fully prepared replacement only after durable commit.
    pub fn commitCompactedHistory(self: *SessionRuntime, alloc: Allocator, history: []HistoryTurn) void {
        const uncertain = self.unversioned_history_len != 0;
        self.agent.clearHistory(alloc);
        self.agent.history.deinit(alloc);
        self.agent.history = std.ArrayList(HistoryTurn).fromOwnedSlice(history);
        self.agent.fresh = false;
        self.unversioned_history_len = if (uncertain) history.len else 0;
    }

    pub fn appendAssistantHistoryTurn(self: *SessionRuntime, alloc: Allocator, user: []const u8, assistant: []const u8) !void {
        const turn = try makeAssistantTurn(alloc, user, assistant);
        var owns_turn = true;
        errdefer if (owns_turn) freeHistoryTurn(alloc, turn);

        try self.agent.history.append(alloc, turn);
        owns_turn = false;
    }

    pub fn appendHistoryMessages(
        alloc: Allocator,
        messages: *std.ArrayList(message.Message),
        history: []const HistoryTurn,
    ) !void {
        try appendHistoryMessagesImpl(alloc, messages, history);
    }

    pub fn appendHistoryChatMessages(
        alloc: Allocator,
        messages: *std.ArrayList(core_types.ChatMessage),
        history: []const HistoryTurn,
    ) !void {
        try appendHistoryChatMessagesImpl(alloc, messages, history, .closed);
    }

    pub fn setConversationLanguageFromUserMessage(self: *SessionRuntime, text: []const u8) void {
        const fallback = self.languageSnapshot();
        self.setConversationLanguage(inferConversationLanguage(text, fallback));
    }

    pub fn languageSnapshot(self: *const SessionRuntime) ConversationLanguage {
        const mutable: *SessionRuntime = @constCast(self);
        mutable.language_lock.lockUncancelable(io_mod.getIo());
        defer mutable.language_lock.unlock(io_mod.getIo());
        return mutable.conversation_language;
    }

    pub fn lastAssistantReply(self: *const SessionRuntime) ?[]const u8 {
        var i = self.agent.history.items.len;
        while (i > 0) {
            i -= 1;
            switch (self.agent.history.items[i]) {
                .assistant => |entry| {
                    if (entry.assistant.len > 0) return entry.assistant;
                },
                else => {},
            }
        }
        return null;
    }

    pub fn lastSummary(self: *const SessionRuntime) ?[]const u8 {
        var index = self.agent.history.items.len;
        while (index > 0) {
            index -= 1;
            if (self.agent.history.items[index] == .compacted_summary) {
                return self.agent.history.items[index].compacted_summary.summary;
            }
        }
        return null;
    }
    fn setConversationLanguage(self: *SessionRuntime, language: ConversationLanguage) void {
        self.language_lock.lockUncancelable(io_mod.getIo());
        defer self.language_lock.unlock(io_mod.getIo());
        self.conversation_language = language;
    }
};

fn appendHistoryCopies(
    alloc: Allocator,
    destination: *std.ArrayList(HistoryTurn),
    history: []const HistoryTurn,
) !void {
    try destination.ensureUnusedCapacity(alloc, history.len);
    for (history) |turn| {
        const copy = try dupeHistoryTurn(alloc, turn);
        destination.appendAssumeCapacity(copy);
    }
}

/// Builds an independently owned prompt-history snapshot from canonical history.
pub fn snapshotOwnedContextHistory(
    alloc: Allocator,
    canonical_history: []const HistoryTurn,
    _: usize,
    _: usize,
) ![]HistoryTurn {
    var copy: std.ArrayList(HistoryTurn) = .empty;
    errdefer {
        for (copy.items) |turn| freeHistoryTurn(alloc, turn);
        copy.deinit(alloc);
    }
    try appendHistoryCopies(alloc, &copy, canonical_history);
    return copy.toOwnedSlice(alloc);
}

/// Borrows payloads. Only descriptors and rebased steering are arena-owned.
pub fn contextHistoryRange(
    arena: Allocator,
    history: []const HistoryTurn,
    start: core_types.ContextHistoryCut,
    end: ?core_types.ContextHistoryCut,
) ![]HistoryTurn {
    var view: std.ArrayList(HistoryTurn) = .empty;
    var raw_index: usize = 0;
    for (history) |original| {
        if (original == .compacted_summary) continue;
        const index = raw_index;
        raw_index += 1;
        if (index < start.turns) continue;
        if (end) |limit| {
            if (index > limit.turns or (index == limit.turns and limit.tool_steps == 0 and limit.steering == 0)) break;
        }
        var turn = original;
        const execution = switch (turn) {
            .assistant => |*entry| &entry.execution,
            .interrupted => |*entry| &entry.execution,
            .compacted_summary => unreachable,
        };
        const first_step = if (index == start.turns) start.tool_steps else 0;
        const first_steering = if (index == start.turns) start.steering else 0;
        const partial_end = if (end) |limit| index == limit.turns else false;
        const last_step = if (partial_end) end.?.tool_steps else execution.tool_steps.len;
        const last_steering = if (partial_end) end.?.steering else execution.steering.len;
        if (first_step > last_step or last_step > execution.tool_steps.len or
            first_steering > last_steering or last_steering > execution.steering.len)
            return error.InvalidContextHistoryStart;
        execution.tool_steps = execution.tool_steps[first_step..last_step];
        execution.steering = execution.steering[first_steering..last_steering];
        if (first_step > 0 and execution.steering.len > 0) {
            execution.steering = try arena.dupe(core_types.PersistedSteering, execution.steering);
            for (execution.steering) |*item| {
                if (item.after_tool_step_count < first_step) return error.InvalidContextHistoryStart;
                item.after_tool_step_count -= first_step;
            }
        }
        if (partial_end) {
            execution.files = &.{};
            execution.turn_summary = null;
            switch (turn) {
                .assistant => |*entry| entry.assistant = @constCast(""),
                .interrupted => |*entry| {
                    entry.assistant = null;
                    entry.tool_call = null;
                    entry.completed_tool_names = &.{};
                    entry.cancelled_command = null;
                },
                .compacted_summary => unreachable,
            }
        }
        try view.append(arena, turn);
    }
    return view.toOwnedSlice(arena);
}

pub fn prepareCompactedHistory(
    alloc: Allocator,
    history: []const HistoryTurn,
    summary: CompactedSummaryHistoryTurn,
    cut: core_types.ContextHistoryCut,
) ![]HistoryTurn {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const retained = try contextHistoryRange(arena_state.allocator(), history, cut, null);
    var next: std.ArrayList(HistoryTurn) = .empty;
    errdefer {
        for (next.items) |turn| freeHistoryTurn(alloc, turn);
        next.deinit(alloc);
    }
    try next.ensureTotalCapacity(alloc, retained.len + 1);
    next.appendAssumeCapacity(try dupeHistoryTurn(alloc, .{ .compacted_summary = summary }));
    for (retained) |turn| next.appendAssumeCapacity(try dupeHistoryTurn(alloc, turn));
    return next.toOwnedSlice(alloc);
}

test "retained context history replacement is allocation-failure atomic" {
    const Fixture = struct {
        fn run(alloc: Allocator) !void {
            const source = [_]HistoryTurn{
                .{ .assistant = .{ .user = .{ .text = @constCast("older request") }, .assistant = @constCast("older reply") } },
                .{ .assistant = .{ .user = .{ .text = @constCast("recent request") }, .assistant = @constCast("recent reply") } },
            };
            const prepared = try prepareCompactedHistory(alloc, &source, .{
                .summary = @constCast("<context_handoff>older facts</context_handoff>"),
                .removed_turn_count = 1,
                .compaction_count = 1,
            }, .{ .turns = 1 });
            defer freeHistoryTurnSlice(alloc, prepared);
            try std.testing.expectEqual(@as(usize, 2), prepared.len);
            try std.testing.expectEqualStrings("recent reply", prepared[1].assistant.assistant);
            try std.testing.expectEqualStrings("older reply", source[0].assistant.assistant);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Fixture.run, .{});
}

/// Frees an owned image attachment slice and each attachment field.
pub fn freeImageAttachmentSlice(alloc: Allocator, attachments: []ImageAttachment) void {
    for (attachments) |attachment| {
        core_types.freeImageAttachment(alloc, attachment);
    }
    if (attachments.len > 0) alloc.free(attachments);
}
/// Frees an owned history slice; callers pass slices returned by session helpers.
pub fn freeHistoryTurnSlice(alloc: Allocator, turns: []HistoryTurn) void {
    for (turns) |turn| freeHistoryTurn(alloc, turn);
    if (turns.len > 0) alloc.free(turns);
}
/// Deep-copies an image attachment slice; caller owns the returned slice and frees with freeImageAttachmentSlice.
pub fn dupeImageAttachmentSlice(alloc: Allocator, attachments: []const ImageAttachment) ![]ImageAttachment {
    if (attachments.len == 0) return &.{};
    const copy = try alloc.alloc(ImageAttachment, attachments.len);
    errdefer alloc.free(copy);
    var copied: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < copied) : (i += 1) {
            core_types.freeImageAttachment(alloc, copy[i]);
        }
    }
    for (attachments, 0..) |attachment, i| {
        copy[i] = try dupeImageAttachment(alloc, attachment);
        copied += 1;
    }
    return copy;
}
fn dupeImageAttachment(alloc: Allocator, src: ImageAttachment) !ImageAttachment {
    const path = try alloc.dupe(u8, src.path);
    errdefer alloc.free(path);
    const media_type = try alloc.dupe(u8, src.media_type);
    errdefer alloc.free(media_type);
    const snapshot_path = if (src.snapshot_path) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (snapshot_path) |value| alloc.free(value);
    const snapshot_sha256 = if (src.snapshot_sha256) |value|
        try alloc.dupe(u8, value)
    else
        null;
    return .{
        .id = src.id,
        .path = path,
        .media_type = media_type,
        .snapshot_path = snapshot_path,
        .snapshot_sha256 = snapshot_sha256,
    };
}
/// Deep-copies one history turn; caller owns the returned turn and frees with freeHistoryTurn.
pub fn dupeHistoryTurn(alloc: Allocator, turn: HistoryTurn) !HistoryTurn {
    switch (turn) {
        .compacted_summary => |entry| {
            const summary = try alloc.dupe(u8, entry.summary);
            errdefer alloc.free(summary);
            const root_user_messages = try core_types.dupeCompletedToolNames(
                alloc,
                entry.root_user_messages,
            );
            errdefer core_types.freeCompletedToolNames(alloc, root_user_messages);
            const permission_feedback = try core_types.dupePermissionFeedback(
                alloc,
                entry.permission_feedback,
            );
            return .{ .compacted_summary = .{
                .summary = summary,
                .removed_turn_count = entry.removed_turn_count,
                .compaction_count = entry.compaction_count,
                .root_user_messages = root_user_messages,
                .root_user_messages_complete = entry.root_user_messages_complete,
                .permission_feedback = permission_feedback,
                .permission_feedback_complete = entry.permission_feedback_complete,
            } };
        },
        .assistant => |entry| {
            const user = try dupeUserTurn(alloc, entry.user);
            errdefer freeUserTurn(alloc, user);
            const assistant_copy = try alloc.dupe(u8, entry.assistant);
            errdefer alloc.free(assistant_copy);
            const execution = try core_types.dupeExecutionMemory(alloc, entry.execution);
            errdefer core_types.freeExecutionMemory(alloc, execution);
            const assistant_parts = if (entry.assistant_parts) |parts|
                try core_types.dupeAssistantParts(alloc, parts)
            else
                null;
            return .{ .assistant = .{
                .user = user,
                .assistant = assistant_copy,
                .execution = execution,
                .assistant_parts = assistant_parts,
            } };
        },
        .interrupted => |entry| {
            const user = try dupeUserTurn(alloc, entry.user);
            errdefer freeUserTurn(alloc, user);
            const assistant = if (entry.assistant) |text| try alloc.dupe(u8, text) else null;
            errdefer if (assistant) |text| alloc.free(text);
            const tool_call = if (entry.tool_call) |call| try core_types.dupeToolCall(alloc, call) else null;
            errdefer if (tool_call) |call| core_types.freeToolCall(alloc, call);
            const completed_tool_names = try core_types.dupeCompletedToolNames(alloc, entry.completed_tool_names);
            errdefer core_types.freeCompletedToolNames(alloc, completed_tool_names);
            const cancelled_command = if (entry.cancelled_command) |presentation|
                try core_types.dupeCancelledCommandPresentation(alloc, presentation)
            else
                null;
            errdefer if (cancelled_command) |presentation| {
                core_types.freeCancelledCommandPresentation(alloc, presentation);
            };
            const execution = try core_types.dupeExecutionMemory(alloc, entry.execution);
            errdefer core_types.freeExecutionMemory(alloc, execution);
            const assistant_parts = if (entry.assistant_parts) |parts|
                try core_types.dupeAssistantParts(alloc, parts)
            else
                null;
            return .{ .interrupted = .{
                .user = user,
                .assistant = assistant,
                .tool_call = tool_call,
                .completed_tool_names = completed_tool_names,
                .execution = execution,
                .cancelled_command = cancelled_command,
                .terminal_reason = entry.terminal_reason,
                .assistant_parts = assistant_parts,
            } };
        },
    }
}
pub fn appendAssistantTurnWithExecution(
    alloc: Allocator,
    current: []HistoryTurn,
    user_text: []const u8,
    assistant_text: []const u8,
    execution: *core_types.ExecutionMemory,
) ![]HistoryTurn {
    const user_copy = try alloc.dupe(u8, user_text);
    errdefer alloc.free(user_copy);
    const assistant_copy = try alloc.dupe(u8, assistant_text);
    errdefer alloc.free(assistant_copy);
    const next = try alloc.alloc(HistoryTurn, current.len + 1);
    errdefer alloc.free(next);

    std.mem.copyForwards(HistoryTurn, next[0..current.len], current);
    next[current.len] = .{ .assistant = .{
        .user = .{ .text = user_copy, .images = &.{} },
        .assistant = assistant_copy,
        .execution = execution.*,
    } };
    execution.* = .{};
    if (current.len > 0) alloc.free(current);
    return next;
}

/// Appends a finished turn to an owned prompt-context projection and reapplies its turn limit.
/// Builds one owned assistant history turn; caller frees with freeHistoryTurn.
pub fn makeAssistantTurn(alloc: Allocator, user_text: []const u8, assistant_text: []const u8) !HistoryTurn {
    const user_copy = try alloc.dupe(u8, user_text);
    errdefer alloc.free(user_copy);
    const assistant_copy = try alloc.dupe(u8, assistant_text);
    errdefer alloc.free(assistant_copy);
    return .{ .assistant = .{
        .user = .{ .text = user_copy, .images = &.{} },
        .assistant = assistant_copy,
    } };
}

test "unavailable profile usage keeps reconciled generation pending in host runtime" {
    const alloc = std.testing.allocator;
    const Checkpoint = struct {
        calls: usize = 0,

        fn persist(raw: *anyopaque, _: session_usage.Snapshot) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
        }
    };

    var checkpoint = Checkpoint{};
    var runtime: SessionRuntime = .{ .max_history_turns = 8 };
    defer runtime.deinit(alloc);
    try std.testing.expectEqual(
        profile_usage_runtime.InitializeOutcome.unavailable,
        try runtime.initializeProfileUsage(alloc, null),
    );
    runtime.attachProfileUsagePublisher(alloc);
    runtime.usage.configureCheckpointSink(.{
        .context = &checkpoint,
        .allocator = alloc,
        .persist = Checkpoint.persist,
    });

    const sequence = try runtime.usage.reserveInvocation();
    try runtime.usage.finishObservedInvocation(
        alloc,
        sequence,
        1,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "https://ai-gateway.vercel.sh",
        null,
    );
    try runtime.usage.applyGeneration(alloc, .{
        .id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        .created_at_ms = 1000,
        .model = "provider/model",
        .total_cost = 0.25,
        .input_tokens = 10,
        .output_tokens = 2,
        .cache_read_tokens = 1,
        .cache_write_tokens = 0,
        .reasoning_tokens = 1,
        .billable_web_search_calls = 0,
    });

    var snapshot = try runtime.usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(session_usage.Availability.pending, snapshot.billing);
    try std.testing.expectEqual(@as(usize, 1), snapshot.pending.len);
    try std.testing.expectEqual(@as(u64, 0), snapshot.input_tokens);
    try std.testing.expectEqual(@as(usize, 1), checkpoint.calls);
}

test "readable profile usage does not attach publishers or flush recovery" {
    const alloc = std.testing.allocator;
    const Checkpoint = struct {
        calls: usize = 0,

        fn persist(raw: *anyopaque, _: session_usage.Snapshot) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);

    var checkpoint = Checkpoint{};
    var runtime: SessionRuntime = .{ .max_history_turns = 8 };
    defer runtime.deinit(alloc);
    try std.testing.expectEqual(
        profile_usage_runtime.InitializeOutcome.available,
        try runtime.initializeProfileUsage(alloc, home),
    );
    runtime.usage.configureCheckpointSink(.{
        .context = &checkpoint,
        .allocator = alloc,
        .persist = Checkpoint.persist,
    });

    const sequence = try runtime.usage.reserveInvocation();
    try runtime.usage.finishObservedInvocation(
        alloc,
        sequence,
        1,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "https://ai-gateway.vercel.sh",
        null,
    );
    try runtime.usage.applyGeneration(alloc, .{
        .id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        .created_at_ms = 1000,
        .model = "provider/model",
        .total_cost = 0.25,
        .input_tokens = 10,
        .output_tokens = 2,
        .cache_read_tokens = 1,
        .cache_write_tokens = 0,
        .reasoning_tokens = 1,
        .billable_web_search_calls = 0,
    });

    const checkpoint_calls = checkpoint.calls;
    try std.testing.expectEqual(
        profile_usage_runtime.InitializeOutcome.available,
        try runtime.ensureProfileUsageReadable(alloc, home),
    );
    var saved = try runtime.usage.snapshot(alloc);
    defer saved.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), saved.publication_backlog.len);
    try std.testing.expectEqual(checkpoint_calls, checkpoint.calls);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access(io_mod.getIo(), ".fx/usage.jsonl", .{}),
    );
}

test "appendAssistantTurnWithExecution transfers memory and clears the source" {
    const alloc = std.testing.allocator;
    var execution = core_types.ExecutionMemory{
        .tool_steps = try alloc.alloc(core_types.ToolExecutionStep, 1),
    };
    execution.tool_steps[0] = .{
        .assistant = try alloc.dupe(u8, "tool step"),
    };

    const history = try appendAssistantTurnWithExecution(
        alloc,
        &.{},
        "user",
        "assistant",
        &execution,
    );
    defer freeHistoryTurnSlice(alloc, history);

    try std.testing.expectEqual(@as(usize, 0), execution.tool_steps.len);
    try std.testing.expectEqual(@as(usize, 1), history[0].assistant.execution.tool_steps.len);
    try std.testing.expectEqualStrings(
        "tool step",
        history[0].assistant.execution.tool_steps[0].assistant.?,
    );
}

test "appendAssistantTurnWithExecution keeps source memory on allocation failure" {
    const alloc = std.testing.allocator;

    for (0..3) |fail_index| {
        var execution = core_types.ExecutionMemory{
            .tool_steps = try alloc.alloc(core_types.ToolExecutionStep, 1),
        };
        execution.tool_steps[0] = .{
            .assistant = try alloc.dupe(u8, "tool step"),
        };
        defer core_types.freeExecutionMemory(alloc, execution);

        var failing = std.testing.FailingAllocator.init(
            alloc,
            .{ .fail_index = fail_index },
        );
        try std.testing.expectError(
            error.OutOfMemory,
            appendAssistantTurnWithExecution(
                failing.allocator(),
                &.{},
                "user",
                "assistant",
                &execution,
            ),
        );

        try std.testing.expectEqual(@as(usize, 1), execution.tool_steps.len);
        try std.testing.expectEqualStrings(
            "tool step",
            execution.tool_steps[0].assistant.?,
        );
    }
}

/// Projects stored history into request messages while preserving stored turn order.
pub fn appendHistoryMessages(
    alloc: Allocator,
    messages: *std.ArrayList(message.Message),
    history: []const HistoryTurn,
) !void {
    try appendHistoryMessagesImpl(alloc, messages, history);
}

pub fn appendHistoryChatMessages(
    alloc: Allocator,
    messages: *std.ArrayList(core_types.ChatMessage),
    history: []const HistoryTurn,
) !void {
    try appendHistoryChatMessagesImpl(alloc, messages, history, .closed);
}

/// Projects the latest current checkpoint and its suffix for semantic
/// compaction. Without a current checkpoint, projects raw canonical turns and
/// returns the message boundary whose result provenance remains uncertain.
pub fn appendCompactionHistoryChatMessages(
    alloc: Allocator,
    messages: *std.ArrayList(core_types.ChatMessage),
    history: []const HistoryTurn,
    uncertain_history_count: usize,
) !usize {
    var checkpoint_index: ?usize = null;
    for (history, 0..) |turn, index| {
        if (isCurrentCompactionCheckpoint(turn)) checkpoint_index = index;
    }
    if (checkpoint_index) |start| {
        const boundary = @max(start, @min(uncertain_history_count, history.len));
        try appendHistoryChatMessagesImpl(alloc, messages, history[start..boundary], .closed);
        const uncertain_message_count = messages.items.len;
        try appendHistoryChatMessagesImpl(alloc, messages, history[boundary..], .closed);
        return uncertain_message_count;
    }

    const boundary = @min(uncertain_history_count, history.len);
    for (history[0..boundary], 0..) |turn, index| {
        if (turn == .compacted_summary) continue;
        try appendHistoryChatMessagesImpl(alloc, messages, history[index .. index + 1], .closed);
    }
    const uncertain_message_count = messages.items.len;
    for (history[boundary..], boundary..) |turn, index| {
        if (turn == .compacted_summary) continue;
        try appendHistoryChatMessagesImpl(alloc, messages, history[index .. index + 1], .closed);
    }
    return uncertain_message_count;
}

fn isCurrentCompactionCheckpoint(turn: HistoryTurn) bool {
    return switch (turn) {
        .compacted_summary => |entry| std.mem.startsWith(
            u8,
            entry.summary,
            core_types.context_handoff_open,
        ),
        else => false,
    };
}

/// Projects the active model window from one complete canonical snapshot.
/// New checkpoints may retain raw turns immediately before the appended
/// checkpoint; those turns are emitted after the checkpoint without
/// duplicating them in canonical storage.
pub fn appendActiveContextHistoryChatMessages(
    alloc: Allocator,
    messages: *std.ArrayList(core_types.ChatMessage),
    history: []const HistoryTurn,
    context_history_start: usize,
) !void {
    return appendActiveContextHistoryChatMessagesWithTrailingProjection(
        alloc,
        messages,
        history,
        context_history_start,
        .closed,
    );
}

pub fn appendSteeringActiveContextHistoryChatMessages(
    alloc: Allocator,
    messages: *std.ArrayList(core_types.ChatMessage),
    history: []const HistoryTurn,
    context_history_start: usize,
) !void {
    return appendActiveContextHistoryChatMessagesWithTrailingProjection(
        alloc,
        messages,
        history,
        context_history_start,
        .steering_continuation,
    );
}

fn appendActiveContextHistoryChatMessagesWithTrailingProjection(
    alloc: Allocator,
    messages: *std.ArrayList(core_types.ChatMessage),
    history: []const HistoryTurn,
    context_history_start: usize,
    interrupted_projection: InterruptedChatProjection,
) !void {
    if (context_history_start > history.len) {
        return error.InvalidContextHistoryStart;
    }
    if (context_history_start == 0) {
        return appendHistoryChatMessagesWithTrailingProjection(
            alloc,
            messages,
            history,
            interrupted_projection,
        );
    }
    if (context_history_start == history.len or
        history[context_history_start] != .compacted_summary)
    {
        return error.InvalidContextHistoryStart;
    }
    const checkpoint = history[context_history_start].compacted_summary;
    var raw_before: usize = 0;
    for (history[0..context_history_start]) |turn| {
        if (turn != .compacted_summary) raw_before += 1;
    }
    if (checkpoint.removed_turn_count > raw_before) {
        return error.InvalidContextHistoryStart;
    }
    const retained_count = raw_before - checkpoint.removed_turn_count;
    try appendHistoryChatMessagesImpl(
        alloc,
        messages,
        history[context_history_start .. context_history_start + 1],
        .closed,
    );
    if (retained_count > 0) {
        var retained_start = context_history_start;
        var remaining = retained_count;
        while (retained_start > 0 and remaining > 0) {
            retained_start -= 1;
            if (history[retained_start] != .compacted_summary) remaining -= 1;
        }
        if (remaining != 0) return error.InvalidContextHistoryStart;
        for (history[retained_start..context_history_start], retained_start..) |turn, index| {
            if (turn == .compacted_summary) continue;
            try appendHistoryChatMessagesImpl(
                alloc,
                messages,
                history[index .. index + 1],
                .closed,
            );
        }
    }
    if (context_history_start + 1 < history.len) {
        try appendHistoryChatMessagesImpl(
            alloc,
            messages,
            history[context_history_start + 1 ..],
            interrupted_projection,
        );
    }
}

pub fn rawHistoryTurnCount(history: []const HistoryTurn) usize {
    var count: usize = 0;
    for (history) |turn| if (turn != .compacted_summary) {
        count += 1;
    };
    return count;
}

pub fn retainedHistoryTurnCountForMessageTail(
    alloc: Allocator,
    history: []const HistoryTurn,
    wanted_messages: usize,
) !usize {
    if (wanted_messages == 0) return 0;
    var remaining = wanted_messages;
    var retained_turns: usize = 0;
    var index = history.len;
    while (index > 0 and remaining > 0) {
        index -= 1;
        if (history[index] == .compacted_summary) continue;
        var projected: std.ArrayList(core_types.ChatMessage) = .empty;
        defer projected.deinit(alloc);
        try appendHistoryChatMessagesImpl(
            alloc,
            &projected,
            history[index .. index + 1],
            .closed,
        );
        if (projected.items.len == 0) continue;
        retained_turns += 1;
        remaining -|= projected.items.len;
    }
    return retained_turns;
}

pub const RetainedHistoryTail = struct {
    turn_count: usize,
    message_count: usize,
};

pub fn retainedHistoryTailForMessageCount(
    alloc: Allocator,
    history: []const HistoryTurn,
    wanted_messages: usize,
) !RetainedHistoryTail {
    const turn_count = try retainedHistoryTurnCountForMessageTail(
        alloc,
        history,
        wanted_messages,
    );
    if (turn_count == 0) return .{ .turn_count = 0, .message_count = 0 };
    if (turn_count == rawHistoryTurnCount(history)) {
        return .{ .turn_count = 0, .message_count = 0 };
    }

    var retained_start = history.len;
    var remaining = turn_count;
    while (retained_start > 0 and remaining > 0) {
        retained_start -= 1;
        if (history[retained_start] != .compacted_summary) remaining -= 1;
    }
    if (remaining != 0) return error.InvalidContextHistoryStart;

    var projected: std.ArrayList(core_types.ChatMessage) = .empty;
    defer projected.deinit(alloc);
    _ = try appendCompactionHistoryChatMessages(
        alloc,
        &projected,
        history[retained_start..],
        0,
    );
    return .{
        .turn_count = turn_count,
        .message_count = projected.items.len,
    };
}

test "retained compaction tail expands requested messages to complete raw turns" {
    const alloc = std.testing.allocator;
    var calls = [_]core_types.ToolCall{.{
        .id = @constCast("tail-call"),
        .name = @constCast("terminal"),
        .arguments_json = @constCast("{\"action\":\"exec\",\"command\":\"printf tail\"}"),
    }};
    var results = [_]core_types.PersistedToolResult{.{
        .tool_call_id = @constCast("tail-call"),
        .tool_name = @constCast("terminal"),
        .status = .success,
        .output = @constCast("tail result"),
        .output_bytes = 11,
        .stored_output_bytes = 11,
    }};
    var steps = [_]core_types.ToolExecutionStep{.{
        .assistant = @constCast("running"),
        .tool_calls = &calls,
        .tool_results = &results,
    }};
    var history = [_]HistoryTurn{
        .{ .assistant = .{
            .user = .{ .text = @constCast("older raw user") },
            .assistant = @constCast("older raw assistant"),
        } },
        .{ .compacted_summary = .{
            .summary = @constCast("older summary"),
            .removed_turn_count = 1,
            .compaction_count = 1,
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("run the tail command") },
            .assistant = @constCast("tail complete"),
            .execution = .{ .tool_steps = &steps },
        } },
    };

    const tail = try retainedHistoryTailForMessageCount(alloc, &history, 2);
    try std.testing.expectEqual(@as(usize, 1), tail.turn_count);
    try std.testing.expectEqual(@as(usize, 4), tail.message_count);

    const only_tail = try retainedHistoryTailForMessageCount(alloc, history[1..], 2);
    try std.testing.expectEqual(@as(usize, 0), only_tail.turn_count);
    try std.testing.expectEqual(@as(usize, 0), only_tail.message_count);
}

test "active context projects checkpoint before retained raw tail" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const history = [_]HistoryTurn{
        .{ .assistant = .{
            .user = .{ .text = @constCast("removed user") },
            .assistant = @constCast("removed assistant"),
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("retained user") },
            .assistant = @constCast("retained assistant"),
        } },
        .{ .compacted_summary = .{
            .summary = @constCast("<context_handoff>checkpoint</context_handoff>"),
            .removed_turn_count = 1,
            .compaction_count = 1,
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("later user") },
            .assistant = @constCast("later assistant"),
        } },
    };
    var messages: std.ArrayList(core_types.ChatMessage) = .empty;
    defer messages.deinit(arena);
    try appendActiveContextHistoryChatMessages(arena, &messages, &history, 2);
    try std.testing.expectEqual(@as(usize, 5), messages.items.len);
    try std.testing.expect(std.mem.find(u8, messages.items[0].content.?, "checkpoint") != null);
    try std.testing.expectEqualStrings("retained user", messages.items[1].content.?);
    try std.testing.expectEqualStrings("retained assistant", messages.items[2].content.?);
    try std.testing.expectEqualStrings("later user", messages.items[3].content.?);
    try std.testing.expectEqualStrings("later assistant", messages.items[4].content.?);
}

test "active context rejects corrupt retained-tail accounting" {
    const history = [_]HistoryTurn{
        .{ .assistant = .{
            .user = .{ .text = @constCast("user") },
            .assistant = @constCast("assistant"),
        } },
        .{ .compacted_summary = .{
            .summary = @constCast("summary"),
            .removed_turn_count = 2,
            .compaction_count = 1,
        } },
    };
    var messages: std.ArrayList(core_types.ChatMessage) = .empty;
    defer messages.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidContextHistoryStart,
        appendActiveContextHistoryChatMessages(
            std.testing.allocator,
            &messages,
            &history,
            1,
        ),
    );
}

test "compaction history keeps permission feedback non-authoritative" {
    var feedback = [_][]u8{@constCast("allow this write")};
    var calls = [_]core_types.ToolCall{.{
        .id = "call",
        .name = "write_file",
        .arguments_json = "{}",
    }};
    var results = [_]core_types.PersistedToolResult{.{
        .tool_call_id = @constCast("call"),
        .tool_name = @constCast("write_file"),
        .status = .failure,
        .output = @constCast("denied"),
        .output_bytes = 6,
        .stored_output_bytes = 6,
        .permission_feedback = &feedback,
    }};
    var steps = [_]core_types.ToolExecutionStep{.{
        .tool_calls = &calls,
        .tool_results = &results,
    }};
    const history = [_]HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("write it") },
        .assistant = @constCast("requesting write"),
        .execution = .{ .tool_steps = &steps },
    } }};
    var messages: std.ArrayList(core_types.ChatMessage) = .empty;
    defer messages.deinit(std.testing.allocator);
    _ = try appendCompactionHistoryChatMessages(
        std.testing.allocator,
        &messages,
        &history,
        0,
    );
    var feedback_count: usize = 0;
    for (messages.items) |entry| {
        if (entry.permission_feedback) feedback_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), feedback_count);
}

test "compaction history starts at the latest checkpoint" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const history = [_]HistoryTurn{
        .{ .assistant = .{ .user = .{ .text = @constCast("old user must stay out") }, .assistant = @constCast("old assistant must stay out") } },
        .{ .compacted_summary = .{ .summary = @constCast("<context_handoff>prior checkpoint</context_handoff>"), .removed_turn_count = 1, .compaction_count = 1 } },
        .{ .assistant = .{ .user = .{ .text = @constCast("new user") }, .assistant = @constCast("new assistant") } },
    };
    var messages: std.ArrayList(core_types.ChatMessage) = .empty;
    defer messages.deinit(arena);
    _ = try appendCompactionHistoryChatMessages(arena, &messages, &history, 0);
    try std.testing.expectEqual(@as(usize, 3), messages.items.len);
    try std.testing.expect(std.mem.find(u8, messages.items[0].content.?, "prior checkpoint") != null);
    try std.testing.expectEqualStrings("new user", messages.items[1].content.?);
    try std.testing.expectEqualStrings("new assistant", messages.items[2].content.?);
    for (messages.items) |entry| {
        const content = entry.content orelse continue;
        try std.testing.expect(std.mem.find(u8, content, "must stay out") == null);
    }
}

pub const HistoryBudgetOptions = struct {
    max_tokens: usize = 0,
};

pub fn appendHistoryMessagesBudgeted(
    alloc: Allocator,
    messages: *std.ArrayList(message.Message),
    history: []const HistoryTurn,
    opts: HistoryBudgetOptions,
) !void {
    const keep = try selectBudgetedHistoryTurns(alloc, history, opts) orelse
        return appendHistoryMessages(alloc, messages, history);
    defer alloc.free(keep);

    const trimmed_context = try formatBudgetTrimmedHistoryContext(
        alloc,
        history,
        keep,
    );
    var owns_trimmed_context = true;
    errdefer if (owns_trimmed_context) alloc.free(trimmed_context);
    try messages.append(
        alloc,
        message.Message.userOwned(trimmed_context),
    );
    owns_trimmed_context = false;

    for (history, 0..) |_, idx| {
        if (!keep[idx]) continue;
        try appendHistoryMessagesImpl(alloc, messages, history[idx .. idx + 1]);
    }
}

pub fn appendHistoryChatMessagesBudgeted(
    alloc: Allocator,
    messages: *std.ArrayList(core_types.ChatMessage),
    history: []const HistoryTurn,
    opts: HistoryBudgetOptions,
) !void {
    return appendHistoryChatMessagesBudgetedImpl(
        alloc,
        messages,
        history,
        opts,
        .closed,
    );
}

/// Projects a handoff turn without telling the model that the user aborted it.
/// Stored execution evidence remains unchanged; only the trailing interruption
/// closure is omitted because the current prompt already carries steering intent.
pub fn appendSteeringContinuationHistoryChatMessagesBudgeted(
    alloc: Allocator,
    messages: *std.ArrayList(core_types.ChatMessage),
    history: []const HistoryTurn,
    opts: HistoryBudgetOptions,
) !void {
    return appendHistoryChatMessagesBudgetedImpl(
        alloc,
        messages,
        history,
        opts,
        .steering_continuation,
    );
}

const InterruptedChatProjection = enum {
    closed,
    steering_continuation,
};

fn appendHistoryChatMessagesBudgetedImpl(
    alloc: Allocator,
    messages: *std.ArrayList(core_types.ChatMessage),
    history: []const HistoryTurn,
    opts: HistoryBudgetOptions,
    trailing_interrupted_projection: InterruptedChatProjection,
) !void {
    const keep = try selectBudgetedHistoryTurns(alloc, history, opts) orelse
        return appendHistoryChatMessagesWithTrailingProjection(
            alloc,
            messages,
            history,
            trailing_interrupted_projection,
        );
    defer alloc.free(keep);

    const trimmed_context = try formatBudgetTrimmedHistoryContext(alloc, history, keep);
    errdefer alloc.free(trimmed_context);
    try messages.append(alloc, .{ .role = .user, .content = trimmed_context });

    for (history, 0..) |_, idx| {
        if (!keep[idx]) continue;
        try appendHistoryChatMessagesImpl(
            alloc,
            messages,
            history[idx .. idx + 1],
            if (idx + 1 == history.len)
                trailing_interrupted_projection
            else
                .closed,
        );
    }
}

fn appendHistoryChatMessagesWithTrailingProjection(
    alloc: Allocator,
    messages: *std.ArrayList(core_types.ChatMessage),
    history: []const HistoryTurn,
    trailing_interrupted_projection: InterruptedChatProjection,
) !void {
    if (history.len == 0 or trailing_interrupted_projection == .closed) {
        try appendHistoryChatMessagesImpl(alloc, messages, history, .closed);
        return;
    }

    if (history.len > 1) {
        try appendHistoryChatMessagesImpl(
            alloc,
            messages,
            history[0 .. history.len - 1],
            .closed,
        );
    }
    try appendHistoryChatMessagesImpl(
        alloc,
        messages,
        history[history.len - 1 ..],
        trailing_interrupted_projection,
    );
}

fn selectBudgetedHistoryTurns(
    alloc: Allocator,
    history: []const HistoryTurn,
    opts: HistoryBudgetOptions,
) !?[]bool {
    if (opts.max_tokens == 0 or history.len == 0) return null;

    const keep = try alloc.alloc(bool, history.len);
    errdefer alloc.free(keep);
    @memset(keep, false);

    var used_tokens: usize = 0;
    var kept_count: usize = 0;
    var i = history.len;
    while (i > 0) {
        i -= 1;
        const cost = estimateHistoryTurnTokens(history[i]);
        if (kept_count == 0 or used_tokens + cost <= opts.max_tokens) {
            keep[i] = true;
            used_tokens += cost;
            kept_count += 1;
        }
    }

    if (kept_count == history.len) {
        alloc.free(keep);
        return null;
    }
    return keep;
}

fn appendHistoryMessagesImpl(
    alloc: Allocator,
    messages: *std.ArrayList(message.Message),
    history: []const HistoryTurn,
) !void {
    for (history) |turn| {
        switch (turn) {
            .compacted_summary => |entry| {
                const text = try formatCompactedContinuationMessage(alloc, entry.summary);
                errdefer alloc.free(text);
                try messages.append(alloc, message.Message.userOwned(text));
            },
            .assistant => |entry| {
                try messages.append(alloc, .{
                    .role = .user,
                    .content = .{ .text = entry.user.text },
                    .images = entry.user.images,
                });
                try appendExecutionMemoryMessages(alloc, messages, entry.execution);
                if (entry.assistant.len > 0) {
                    try messages.append(alloc, message.Message.assistantBorrowed(entry.assistant, &.{}));
                }
            },
            .interrupted => |entry| {
                try messages.append(alloc, .{
                    .role = .user,
                    .content = .{ .text = entry.user.text },
                    .images = entry.user.images,
                });
                try appendExecutionMemoryMessages(alloc, messages, entry.execution);
                if (entry.tool_call) |tool_call| {
                    const assistant_content = try formatInterruptedAssistantToolContent(alloc, entry);
                    var owns_assistant_content = assistant_content != null;
                    errdefer if (owns_assistant_content) {
                        if (assistant_content) |text| alloc.free(text);
                    };
                    const calls = try alloc.alloc(core_types.ToolCall, 1);
                    var owns_calls = true;
                    var calls_initialized = false;
                    errdefer if (owns_calls) {
                        if (calls_initialized) core_types.freeToolCall(alloc, calls[0]);
                        alloc.free(calls);
                    };
                    calls[0] = try core_types.dupeToolCall(alloc, tool_call);
                    calls_initialized = true;
                    try messages.append(alloc, .{
                        .role = .assistant,
                        .content = if (assistant_content) |text| .{ .text = text } else null,
                        .tool_calls = calls,
                        .owns_content = assistant_content != null,
                        .owns_tool_calls = true,
                    });
                    owns_assistant_content = false;
                    owns_calls = false;
                    const tool_output = try formatInterruptedToolOutput(alloc, entry);
                    var owns_tool_output = true;
                    errdefer if (owns_tool_output) alloc.free(tool_output);
                    try messages.append(alloc, .{
                        .role = .tool,
                        .content = .{ .text = tool_output },
                        .tool_call_id = tool_call.id,
                        .tool_name = tool_call.name,
                        .tool_result_status = .failure,
                        .owns_content = true,
                    });
                    owns_tool_output = false;
                } else {
                    const assistant_content = try formatInterruptedAssistantClosedContent(alloc, entry);
                    var owns_assistant_content = true;
                    errdefer if (owns_assistant_content) alloc.free(assistant_content);
                    try messages.append(alloc, message.Message.assistantOwned(assistant_content, &.{}));
                    owns_assistant_content = false;
                }
                const text = try formatInterruptedHistoryContext(alloc, entry);
                errdefer alloc.free(text);
                try messages.append(alloc, message.Message.userOwned(text));
            },
        }
    }
}

fn appendExecutionMemoryMessages(
    alloc: Allocator,
    messages: *std.ArrayList(message.Message),
    execution: core_types.ExecutionMemory,
) !void {
    var steering_index: usize = 0;
    for (execution.tool_steps, 0..) |step, step_index| {
        while (steering_index < execution.steering.len and
            execution.steering[steering_index].after_tool_step_count == step_index)
        {
            const steering = execution.steering[steering_index];
            if (steering.assistant_prefix) |prefix| {
                if (prefix.len > 0) {
                    try messages.append(alloc, message.Message.assistantBorrowed(prefix, &.{}));
                }
            }
            if (steering.text.len > 0) {
                try messages.append(alloc, message.Message.userText(steering.text));
            }
            steering_index += 1;
        }
        if (step.tool_calls.len == 0) continue;
        try messages.append(alloc, .{
            .role = .assistant,
            .content = if (step.assistant) |text| .{ .text = text } else null,
            .tool_calls = step.tool_calls,
        });
        for (step.tool_results) |result| {
            try messages.append(alloc, .{
                .role = .tool,
                .content = .{ .text = result.output },
                .tool_call_id = result.tool_call_id,
                .tool_name = result.tool_name,
                .tool_result_status = result.status,
            });
        }
        for (step.tool_results) |result| {
            for (result.permission_feedback) |feedback| {
                try messages.append(alloc, message.Message.userText(feedback));
            }
        }
    }
    if (execution.files.len > 0) {
        const text = try formatExecutionFileContext(alloc, execution.files);
        errdefer alloc.free(text);
        try messages.append(alloc, message.Message.userOwned(text));
    }
    while (steering_index < execution.steering.len) : (steering_index += 1) {
        const steering = execution.steering[steering_index];
        if (steering.assistant_prefix) |prefix| {
            if (prefix.len > 0) {
                try messages.append(alloc, message.Message.assistantBorrowed(prefix, &.{}));
            }
        }
        if (steering.text.len == 0) continue;
        try messages.append(alloc, message.Message.userText(steering.text));
    }
}

pub fn appendExecutionMemoryChatMessages(
    alloc: Allocator,
    messages: *std.ArrayList(core_types.ChatMessage),
    execution: core_types.ExecutionMemory,
) !void {
    var steering_index: usize = 0;
    for (execution.tool_steps, 0..) |step, step_index| {
        while (steering_index < execution.steering.len and
            execution.steering[steering_index].after_tool_step_count == step_index)
        {
            const steering = execution.steering[steering_index];
            if (steering.assistant_prefix) |prefix| {
                if (prefix.len > 0) {
                    try messages.append(alloc, .{ .role = .assistant, .content = prefix });
                }
            }
            if (steering.text.len > 0) {
                try messages.append(alloc, .{ .role = .user, .content = steering.text });
            }
            steering_index += 1;
        }
        if (step.tool_calls.len == 0) continue;
        try messages.append(alloc, .{
            .role = .assistant,
            .content = step.assistant,
            .tool_calls = step.tool_calls,
        });
        for (step.tool_results) |result| {
            try messages.append(alloc, .{
                .role = .tool,
                .content = result.output,
                .tool_call_id = result.tool_call_id,
                .tool_name = result.tool_name,
                .tool_result_status = result.status,
                .tool_result_memory = toolResultMemory(result),
            });
        }
        for (step.tool_results) |result| {
            for (result.permission_feedback) |feedback| {
                try messages.append(alloc, .{
                    .role = .user,
                    .content = feedback,
                    .permission_feedback = true,
                });
            }
        }
    }
    if (execution.files.len > 0) {
        const text = try formatExecutionFileContext(alloc, execution.files);
        errdefer alloc.free(text);
        try messages.append(alloc, .{ .role = .user, .content = text });
    }
    while (steering_index < execution.steering.len) : (steering_index += 1) {
        const steering = execution.steering[steering_index];
        if (steering.assistant_prefix) |prefix| {
            if (prefix.len > 0) {
                try messages.append(alloc, .{ .role = .assistant, .content = prefix });
            }
        }
        if (steering.text.len == 0) continue;
        try messages.append(alloc, .{ .role = .user, .content = steering.text });
    }
}

fn toolResultMemory(result: core_types.PersistedToolResult) core_types.ToolResultMemory {
    return .{
        .tool_images = result.tool_images,
        .tool_image_handle = result.tool_image_handle,
        .output_handle = result.output_handle,
        .preview = result.preview,
        .output_bytes = result.output_bytes,
        .stored_output_bytes = result.stored_output_bytes,
        .truncated = result.truncated,
        .committed_file_presentation = result.committed_file_presentation,
        .command_output_replay = result.command_output_replay,
        .command_process_presentation = result.command_process_presentation,
        .terminal_action_presentation = result.terminal_action_presentation,
    };
}

fn appendHistoryChatMessagesImpl(
    alloc: Allocator,
    messages: *std.ArrayList(core_types.ChatMessage),
    history: []const HistoryTurn,
    interrupted_projection: InterruptedChatProjection,
) !void {
    for (history) |turn| {
        switch (turn) {
            .compacted_summary => |entry| {
                const text = try formatCompactedContinuationMessage(alloc, entry.summary);
                errdefer alloc.free(text);
                try messages.append(alloc, .{
                    .role = .user,
                    .content = text,
                });
            },
            .assistant => |entry| {
                try messages.append(alloc, .{ .role = .user, .content = entry.user.text, .images = entry.user.images });
                try appendExecutionMemoryChatMessages(alloc, messages, entry.execution);
                if (entry.assistant.len > 0) {
                    try messages.append(alloc, .{ .role = .assistant, .content = entry.assistant });
                }
            },
            .interrupted => |entry| {
                try messages.append(alloc, .{ .role = .user, .content = entry.user.text, .images = entry.user.images });
                try appendExecutionMemoryChatMessages(alloc, messages, entry.execution);
                if (entry.tool_call) |tool_call| {
                    const assistant_content = try formatInterruptedAssistantToolContent(alloc, entry);
                    const calls = try alloc.alloc(core_types.ToolCall, 1);
                    calls[0] = try core_types.dupeToolCall(alloc, tool_call);
                    try messages.append(alloc, .{ .role = .assistant, .content = assistant_content, .tool_calls = calls });
                    const tool_output = try formatInterruptedToolOutput(alloc, entry);
                    try messages.append(alloc, .{
                        .role = .tool,
                        .content = tool_output,
                        .tool_call_id = tool_call.id,
                        .tool_name = tool_call.name,
                        .tool_result_status = .failure,
                    });
                } else if (interrupted_projection == .steering_continuation) {
                    if (entry.assistant) |assistant| {
                        if (assistant.len > 0) {
                            try messages.append(alloc, .{ .role = .assistant, .content = assistant });
                        }
                    }
                } else {
                    const assistant_content = try formatInterruptedAssistantClosedContent(alloc, entry);
                    try messages.append(alloc, .{ .role = .assistant, .content = assistant_content });
                }
                if (interrupted_projection == .steering_continuation) continue;
                const text = try formatInterruptedHistoryContext(alloc, entry);
                errdefer alloc.free(text);
                try messages.append(alloc, .{ .role = .user, .content = text });
            },
        }
    }
}
/// Infers a conversation language tag from text using core's script-counting heuristic.
pub fn inferConversationLanguage(text: []const u8, fallback: ConversationLanguage) ConversationLanguage {
    const script = language_script.profile(text).script orelse return fallback;
    return switch (script) {
        .japanese => ConversationLanguage.literal("ja"),
        .hangul => ConversationLanguage.literal("ko"),
        .han => ConversationLanguage.literal("und-Hani"),
        .arabic => ConversationLanguage.literal("und-Arab"),
        .hebrew => ConversationLanguage.literal("und-Hebr"),
        .cyrillic => ConversationLanguage.literal("und-Cyrl"),
        .greek => ConversationLanguage.literal("und-Grek"),
        .devanagari => ConversationLanguage.literal("und-Deva"),
        .thai => ConversationLanguage.literal("und-Thai"),
        .latin => ConversationLanguage.literal("und-Latn"),
    };
}

pub fn formatCompactedContinuationMessage(alloc: Allocator, summary: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "{s}{s}\n\n{s}\n{s}",
        .{ compact_continuation_preamble, summary, compact_recent_messages_note, compact_direct_resume_instruction },
    );
}

pub fn formatExecutionFileContext(alloc: Allocator, files: []const core_types.FileEvidence) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    out.writer.writeAll("Session file evidence from previous tool execution. Re-read stale paths before relying on exact contents:") catch return error.OutOfMemory;
    for (files) |file| {
        out.writer.print("\n- action={s} status={s} path={s}", .{ @tagName(file.action), @tagName(file.status), file.path }) catch return error.OutOfMemory;
        if (file.new_path) |new_path| {
            out.writer.print(" new_path={s}", .{new_path}) catch return error.OutOfMemory;
        }
        if (file.model_view_covers_full_file) {
            out.writer.writeAll(" model_view=full") catch return error.OutOfMemory;
        }
        if (file.stale) {
            out.writer.writeAll(" stale=true") catch return error.OutOfMemory;
        }
        out.writer.print(" tool={s}", .{file.tool_name}) catch return error.OutOfMemory;
    }

    return out.toOwnedSlice() catch return error.OutOfMemory;
}

pub fn formatExecutionReplayContext(
    alloc: Allocator,
    execution: core_types.ExecutionMemory,
) !?[]u8 {
    if (execution.isEmpty()) return null;

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    out.writer.writeAll("Previous tool execution:") catch return error.OutOfMemory;

    for (execution.tool_steps) |step| {
        if (step.assistant) |assistant| {
            if (assistant.len > 0) {
                out.writer.print("\n\nAssistant:\n{s}", .{assistant}) catch return error.OutOfMemory;
            }
        }
        for (step.tool_results) |result| {
            out.writer.print(
                "\n\nTool {s} ({s}):\n{s}",
                .{ result.tool_name, @tagName(result.status), result.output },
            ) catch return error.OutOfMemory;
            for (result.permission_feedback) |feedback| {
                out.writer.print(
                    "\n\nUser permission feedback:\n{s}",
                    .{feedback},
                ) catch return error.OutOfMemory;
            }
        }
    }
    if (execution.files.len > 0) {
        const files = try formatExecutionFileContext(alloc, execution.files);
        defer alloc.free(files);
        out.writer.print("\n\n{s}", .{files}) catch return error.OutOfMemory;
    }

    return out.toOwnedSlice() catch return error.OutOfMemory;
}

test "turn summary alone does not create model execution replay context" {
    const execution = ExecutionMemory{ .turn_summary = .{
        .started_at_ms = 100,
        .completed_at_ms = 250,
        .thinking_duration_ms = 40,
        .turn_duration_ms = 150,
        .token_progress = .{ .input_tokens = 12, .output_tokens = 34 },
    } };

    const context = try formatExecutionReplayContext(
        std.testing.allocator,
        execution,
    );
    defer if (context) |value| std.testing.allocator.free(value);
    try std.testing.expect(context == null);
}

pub fn formatInterruptedHistoryContext(alloc: Allocator, entry: InterruptedHistoryTurn) ![]u8 {
    _ = entry;
    return alloc.dupe(u8, interrupted_turn_context);
}

pub fn formatCompletedToolSummary(alloc: Allocator, names: []const []u8) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    out.writer.print(
        "Interrupted by user after completing {d} tool call{s}: ",
        .{ names.len, if (names.len == 1) "" else "s" },
    ) catch return error.OutOfMemory;
    for (names, 0..) |name, i| {
        if (i > 0) out.writer.writeAll(", ") catch return error.OutOfMemory;
        out.writer.writeAll(name) catch return error.OutOfMemory;
    }
    out.writer.writeByte('.') catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn formatInterruptedAssistantToolContent(alloc: Allocator, entry: InterruptedHistoryTurn) Allocator.Error!?[]u8 {
    const assistant = entry.assistant;
    const has_assistant = assistant != null and assistant.?.len > 0;
    const has_completed_tools = entry.completed_tool_names.len > 0;
    if (!has_assistant and !has_completed_tools) return null;

    if (!has_completed_tools) return @as(?[]u8, try alloc.dupe(u8, assistant.?));

    const summary = try formatCompletedToolSummary(alloc, entry.completed_tool_names);
    var owns_summary = true;
    errdefer if (owns_summary) alloc.free(summary);
    if (!has_assistant) return @as(?[]u8, summary);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    out.writer.print("{s}\n\n{s}", .{ assistant.?, summary }) catch return error.OutOfMemory;
    alloc.free(summary);
    owns_summary = false;
    return @as(?[]u8, out.toOwnedSlice() catch return error.OutOfMemory);
}

fn formatInterruptedAssistantClosedContent(alloc: Allocator, entry: InterruptedHistoryTurn) Allocator.Error![]u8 {
    if (entry.completed_tool_names.len > 0) {
        if (try formatInterruptedAssistantToolContent(alloc, entry)) |text| return text;
    }
    if (entry.assistant) |assistant| {
        if (assistant.len > 0) return formatInterruptedPartialAssistantClosedContent(alloc, assistant);
    }
    return alloc.dupe(u8, interrupted_before_completion_output);
}

fn formatInterruptedPartialAssistantClosedContent(alloc: Allocator, assistant: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ assistant, interrupted_before_completion_output });
}

fn formatBudgetTrimmedHistoryContext(alloc: Allocator, history: []const HistoryTurn, keep: []const bool) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(arena);

    var omitted: usize = 0;
    for (keep) |kept| {
        if (!kept) omitted += 1;
    }
    try lines.append(arena, try std.fmt.allocPrint(arena, "Context budget trimmed {d} older history turn(s). Recent turns are preserved verbatim.", .{omitted}));
    try appendBudgetCompactedSummaryLines(arena, &lines, history, keep);
    try lines.append(arena, "Preserved key evidence from trimmed turns:");

    var added: usize = 0;
    for (history, 0..) |turn, idx| {
        if (keep[idx]) continue;
        added += try appendBudgetEvidenceForTurn(arena, &lines, turn, 6 - @min(added, 6));
        if (added >= 6) break;
    }
    if (added == 0) try lines.append(arena, "- No tool evidence was present in trimmed turns.");
    return compressSummaryLines(alloc, lines.items);
}

fn appendBudgetCompactedSummaryLines(arena: Allocator, lines: *std.ArrayList([]const u8), history: []const HistoryTurn, keep: []const bool) !void {
    for (history, 0..) |turn, idx| {
        if (keep[idx]) continue;
        const entry = switch (turn) {
            .compacted_summary => |value| value,
            else => continue,
        };

        try lines.append(arena, "Preserved compacted summary from trimmed history:");
        var added: usize = 0;
        var summary_lines = std.mem.splitScalar(u8, entry.summary, '\n');
        while (summary_lines.next()) |line| {
            const summary = compactLineText(arena, line, compact_summary_max_line_chars - 4) catch continue;
            if (summary.len == 0) continue;
            try lines.append(arena, try std.fmt.allocPrint(arena, "- {s}", .{summary}));
            added += 1;
            if (added >= 6) break;
        }
        if (added == 0) try lines.append(arena, "- Compacted summary was present but empty.");
        return;
    }
}

fn appendBudgetEvidenceForTurn(arena: Allocator, lines: *std.ArrayList([]const u8), turn: HistoryTurn, remaining: usize) !usize {
    if (remaining == 0) return 0;
    const execution = switch (turn) {
        .assistant => |entry| entry.execution,
        .interrupted => |entry| entry.execution,
        else => return 0,
    };
    var added: usize = 0;
    for (execution.tool_steps) |step| {
        for (step.tool_results) |result| {
            try lines.append(arena, try formatToolResultEvidenceLine(arena, result));
            added += 1;
            if (added >= remaining) return added;
        }
    }
    for (execution.files) |file| {
        const stale = if (file.stale) ", stale" else "";
        try lines.append(arena, try std.fmt.allocPrint(arena, "- file {s}: {s}{s}", .{ @tagName(file.action), file.path, stale }));
        added += 1;
        if (added >= remaining) return added;
    }
    return added;
}

fn formatToolResultEvidenceLine(arena: Allocator, result: core_types.PersistedToolResult) ![]const u8 {
    if (result.output_handle) |handle| {
        if (result.preview) |preview| {
            const compact_preview = try compactLineText(arena, preview, 96);
            return std.fmt.allocPrint(arena, "- {s} {s} ({d} stored bytes, handle={s}, preview={s})", .{ result.tool_name, @tagName(result.status), result.stored_output_bytes, handle, compact_preview });
        }
        return std.fmt.allocPrint(arena, "- {s} {s} ({d} stored bytes, handle={s})", .{ result.tool_name, @tagName(result.status), result.stored_output_bytes, handle });
    }
    return std.fmt.allocPrint(arena, "- {s} {s} ({d} stored bytes)", .{ result.tool_name, @tagName(result.status), result.stored_output_bytes });
}

fn estimateHistoryTurnTokens(turn: HistoryTurn) usize {
    return switch (turn) {
        .compacted_summary => |entry| estimateTextTokens(entry.summary),
        .assistant => |entry| estimateTextTokens(entry.user.text) + estimateTextTokens(entry.assistant) + estimateExecutionTokens(entry.execution),
        .interrupted => |entry| estimateTextTokens(entry.user.text) +
            (if (entry.assistant) |assistant| estimateTextTokens(assistant) else 0) +
            estimateExecutionTokens(entry.execution),
    };
}

fn estimateExecutionTokens(execution: core_types.ExecutionMemory) usize {
    var total: usize = 0;
    for (execution.tool_steps) |step| {
        if (step.assistant) |assistant| total += estimateTextTokens(assistant);
        for (step.tool_calls) |call| {
            total += estimateTextTokens(call.name) + estimateTextTokens(call.arguments_json);
        }
        for (step.tool_results) |result| {
            if (result.preview) |preview| {
                total += estimateTextTokens(preview);
            } else {
                total += estimateTextTokens(result.output);
            }
            if (result.output_handle) |handle| total += estimateTextTokens(handle);
            for (result.permission_feedback) |feedback| {
                total += estimateTextTokens(feedback);
            }
        }
    }
    for (execution.files) |file| {
        total += estimateTextTokens(file.path) + estimateTextTokens(file.tool_name);
    }
    return total;
}

fn estimateTextTokens(text: []const u8) usize {
    var count: usize = 0;
    var span_len: usize = 0;
    for (text) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            if (span_len > 0) {
                count += (span_len + 3) / 4;
                span_len = 0;
            }
        } else {
            span_len += 1;
        }
    }
    if (span_len > 0) count += (span_len + 3) / 4;
    return count;
}

fn compressSummaryLines(alloc: Allocator, lines: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(alloc);

    var line_count: usize = 0;
    var char_count: usize = 0;
    var omitted: usize = 0;

    for (lines) |line| {
        const normalized = std.mem.trim(u8, line, " \t\r\n");
        if (normalized.len == 0) continue;
        if (containsLine(seen.items, normalized)) {
            omitted += 1;
            continue;
        }

        try seen.append(alloc, normalized);

        const candidate_chars = normalized.len + @intFromBool(line_count > 0);
        if (line_count >= compact_summary_max_lines or char_count + candidate_chars > compact_summary_max_chars) {
            omitted += 1;
            continue;
        }

        if (line_count > 0) try out.writer.writeByte('\n');
        try out.writer.writeAll(normalized);
        line_count += 1;
        char_count += candidate_chars;
    }

    if (omitted > 0 and line_count < compact_summary_max_lines) {
        const notice = try std.fmt.allocPrint(alloc, "- ... {d} additional line(s) omitted.", .{omitted});
        defer alloc.free(notice);
        const candidate_chars = notice.len + @intFromBool(line_count > 0);
        if (char_count + candidate_chars <= compact_summary_max_chars) {
            if (line_count > 0) try out.writer.writeByte('\n');
            try out.writer.writeAll(notice);
        }
    }

    return try out.toOwnedSlice();
}

fn containsLine(lines: []const []const u8, candidate: []const u8) bool {
    for (lines) |line| {
        if (std.mem.eql(u8, line, candidate)) return true;
    }
    return false;
}

fn compactLineText(arena: Allocator, text: []const u8, max_bytes: usize) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();

    var wrote_space = false;
    var i: usize = 0;
    while (i < text.len) {
        const byte = text[i];
        const is_space = byte == ' ' or byte == '\n' or byte == '\r' or byte == '\t';
        if (is_space) {
            if (out.written().len > 0) wrote_space = true;
            i += 1;
            continue;
        }

        if (wrote_space and out.written().len < max_bytes) {
            try out.writer.writeByte(' ');
            wrote_space = false;
        }
        if (out.written().len >= max_bytes) break;
        const next_i = text_utils.utf8ForwardBoundary(text, i + 1);
        const codepoint_len = next_i - i;
        if (codepoint_len > max_bytes - out.written().len) break;
        try out.writer.writeAll(text[i..next_i]);
        i = next_i;
    }

    const written = std.mem.trim(u8, out.written(), " \t\r\n");
    return if (written.len == 0) arena.dupe(u8, "") else arena.dupe(u8, written);
}

test "resume-history-to-request conversion preserves user assistant ordering" {
    const alloc = std.testing.allocator;
    var history = try alloc.alloc(HistoryTurn, 2);
    history[0] = try makeAssistantTurn(alloc, "first", "one");
    history[1] = try makeAssistantTurn(alloc, "second", "two");
    defer freeHistoryTurnSlice(alloc, history);
    var messages: std.ArrayList(message.Message) = .empty;
    defer {
        for (messages.items) |*msg| msg.deinit(alloc);
        messages.deinit(alloc);
    }
    try appendHistoryMessages(alloc, &messages, history);
    try std.testing.expectEqual(@as(usize, 4), messages.items.len);
    try std.testing.expectEqual(.user, messages.items[0].role);
    try std.testing.expectEqualStrings("first", messages.items[0].content.?.asText());
    try std.testing.expectEqual(.assistant, messages.items[1].role);
    try std.testing.expectEqualStrings("one", messages.items[1].content.?.asText());
    try std.testing.expectEqual(.user, messages.items[2].role);
    try std.testing.expectEqualStrings("second", messages.items[2].content.?.asText());
    try std.testing.expectEqual(.assistant, messages.items[3].role);
    try std.testing.expectEqualStrings("two", messages.items[3].content.?.asText());
}
test "appendHistoryMessages frees owned projection text when append fails" {
    const compact = [_]HistoryTurn{.{ .compacted_summary = .{ .summary = @constCast("summary"), .removed_turn_count = 1, .compaction_count = 1 } }};
    var compact_failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var compact_messages: std.ArrayList(message.Message) = .empty;
    try std.testing.expectError(error.OutOfMemory, appendHistoryMessages(compact_failing.allocator(), &compact_messages, &compact));
}
test "dupeImageAttachment frees path when media_type allocation fails" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    try std.testing.expectError(error.OutOfMemory, dupeImageAttachment(failing.allocator(), .{
        .path = @constCast("/tmp/a.png"),
        .media_type = @constCast("image/png"),
    }));
}
test "dupeImageAttachment preserves stable image id" {
    const alloc = std.testing.allocator;
    const copy = try dupeImageAttachment(alloc, .{
        .id = 41,
        .path = @constCast("/tmp/a.png"),
        .media_type = @constCast("image/png"),
    });
    defer {
        alloc.free(copy.path);
        alloc.free(copy.media_type);
    }

    try std.testing.expectEqual(@as(usize, 41), copy.id);
}
test "conversation-language inference matches script signals" {
    try std.testing.expectEqual(ConversationLanguage.literal("und-Latn"), inferConversationLanguage("puoi aprire la landing page", ConversationLanguage.default()));
    try std.testing.expectEqual(ConversationLanguage.literal("ja"), inferConversationLanguage("ランディングページを開いて", ConversationLanguage.default()));
    try std.testing.expectEqual(ConversationLanguage.literal("und-Arab"), inferConversationLanguage("افتح الصفحة الرئيسية", ConversationLanguage.default()));
    try std.testing.expectEqual(ConversationLanguage.literal("und-Latn"), inferConversationLanguage("12345 !!!", ConversationLanguage.literal("und-Latn")));
}
test "history projection keeps system role only for leading summaries" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const history = [_]HistoryTurn{
        .{ .compacted_summary = .{
            .summary = @constCast("leading summary"),
            .removed_turn_count = 2,
            .compaction_count = 1,
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("old request " ++ ("u" ** 800)) },
            .assistant = @constCast("old answer " ++ ("a" ** 800)),
        } },
        .{ .compacted_summary = .{
            .summary = @constCast("nonleading summary marker"),
            .removed_turn_count = 1,
            .compaction_count = 2,
        } },
        .{ .interrupted = .{
            .user = .{ .text = @constCast("interrupt me") },
            .assistant = @constCast("partial answer"),
        } },
    };

    var messages: std.ArrayList(message.Message) = .empty;
    defer deinitMessages(alloc, &messages);
    try appendHistoryMessages(alloc, &messages, &history);

    var chat_messages: std.ArrayList(core_types.ChatMessage) = .empty;
    defer chat_messages.deinit(arena);
    try appendHistoryChatMessages(arena, &chat_messages, &history);

    try std.testing.expectEqual(@as(usize, 7), messages.items.len);
    try std.testing.expectEqual(messages.items.len, chat_messages.items.len);
    for (messages.items, chat_messages.items) |projected, chat| {
        try std.testing.expectEqualStrings(@tagName(projected.role), @tagName(chat.role));
        try std.testing.expectEqualStrings(projected.content.?.asText(), chat.content.?);
    }
    try std.testing.expectEqual(.user, messages.items[0].role);
    try std.testing.expectEqual(.user, messages.items[3].role);
    try std.testing.expect(std.mem.find(u8, messages.items[3].content.?.asText(), "nonleading summary marker") != null);
    try std.testing.expectEqual(.user, messages.items[6].role);
    try std.testing.expect(std.mem.find(u8, messages.items[6].content.?.asText(), "<turn_aborted>") != null);

    var budgeted_messages: std.ArrayList(message.Message) = .empty;
    defer deinitMessages(alloc, &budgeted_messages);
    try appendHistoryMessagesBudgeted(alloc, &budgeted_messages, &history, .{ .max_tokens = 128 });

    var budgeted_chat_messages: std.ArrayList(core_types.ChatMessage) = .empty;
    defer budgeted_chat_messages.deinit(arena);
    try appendHistoryChatMessagesBudgeted(arena, &budgeted_chat_messages, &history, .{ .max_tokens = 128 });

    try std.testing.expectEqual(budgeted_messages.items.len, budgeted_chat_messages.items.len);
    var saw_nonleading_summary = false;
    var saw_interruption_marker = false;
    var saw_non_system = false;
    for (budgeted_messages.items, budgeted_chat_messages.items) |projected, chat| {
        try std.testing.expectEqualStrings(@tagName(projected.role), @tagName(chat.role));
        try std.testing.expectEqualStrings(projected.content.?.asText(), chat.content.?);
        if (projected.role == .system) {
            try std.testing.expect(!saw_non_system);
        } else {
            saw_non_system = true;
        }
        const text = projected.content.?.asText();
        if (std.mem.find(u8, text, "nonleading summary marker") != null and
            std.mem.startsWith(u8, text, compact_continuation_preamble))
        {
            try std.testing.expectEqual(.user, projected.role);
            try std.testing.expect(!saw_nonleading_summary);
            saw_nonleading_summary = true;
        }
        if (std.mem.find(u8, text, "<turn_aborted>") != null) {
            try std.testing.expectEqual(.user, projected.role);
            try std.testing.expect(!saw_interruption_marker);
            saw_interruption_marker = true;
        }
    }
    try std.testing.expectEqual(.user, budgeted_messages.items[0].role);
    try std.testing.expect(saw_nonleading_summary);
    try std.testing.expect(saw_interruption_marker);
}

test "resume history projects steering before the final assistant" {
    const alloc = std.testing.allocator;
    var steering = [_]core_types.PersistedSteering{
        .{ .text = @constCast("use file B instead"), .after_tool_step_count = 0 },
        .{ .text = @constCast("keep the result concise"), .after_tool_step_count = 0 },
    };
    const history = [_]HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("modify file A") },
        .assistant = @constCast("updated file B"),
        .execution = .{ .steering = steering[0..] },
    } }};

    var messages: std.ArrayList(message.Message) = .empty;
    defer deinitMessages(alloc, &messages);
    try appendHistoryMessages(alloc, &messages, &history);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var chat_messages: std.ArrayList(core_types.ChatMessage) = .empty;
    defer chat_messages.deinit(arena);
    try appendHistoryChatMessages(arena, &chat_messages, &history);

    try std.testing.expectEqual(@as(usize, 4), messages.items.len);
    try std.testing.expectEqual(messages.items.len, chat_messages.items.len);
    const expected_roles = [_]message.Role{ .user, .user, .user, .assistant };
    const expected_text = [_][]const u8{
        "modify file A",
        "use file B instead",
        "keep the result concise",
        "updated file B",
    };
    for (messages.items, chat_messages.items, expected_roles, expected_text) |projected, chat, role, text| {
        try std.testing.expectEqual(role, projected.role);
        try std.testing.expectEqualStrings(@tagName(role), @tagName(chat.role));
        try std.testing.expectEqualStrings(text, projected.content.?.asText());
        try std.testing.expectEqualStrings(text, chat.content.?);
    }
}

test "resume history preserves steering between tool episodes" {
    const alloc = std.testing.allocator;
    var first_calls = [_]ToolCall{.{
        .id = "call_first",
        .name = "read_file",
        .arguments_json = "{\"path\":\"first\"}",
    }};
    var first_results = [_]PersistedToolResult{.{
        .tool_call_id = @constCast("call_first"),
        .tool_name = @constCast("read_file"),
        .status = .success,
        .output = @constCast("first result"),
        .output_bytes = "first result".len,
        .stored_output_bytes = "first result".len,
    }};
    var second_calls = [_]ToolCall{.{
        .id = "call_second",
        .name = "read_file",
        .arguments_json = "{\"path\":\"second\"}",
    }};
    var second_results = [_]PersistedToolResult{.{
        .tool_call_id = @constCast("call_second"),
        .tool_name = @constCast("read_file"),
        .status = .success,
        .output = @constCast("second result"),
        .output_bytes = "second result".len,
        .stored_output_bytes = "second result".len,
    }};
    var steps = [_]ToolExecutionStep{
        .{ .tool_calls = &first_calls, .tool_results = &first_results },
        .{ .tool_calls = &second_calls, .tool_results = &second_results },
    };
    var steering = [_]core_types.PersistedSteering{
        .{ .text = @constCast("after first"), .after_tool_step_count = 1 },
        .{ .text = @constCast("after second"), .after_tool_step_count = 2 },
    };
    const history = [_]HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("run both") },
        .assistant = @constCast("finished"),
        .execution = .{
            .tool_steps = &steps,
            .steering = &steering,
        },
    } }};

    var messages: std.ArrayList(message.Message) = .empty;
    defer deinitMessages(alloc, &messages);
    try appendHistoryMessages(alloc, &messages, &history);

    try std.testing.expectEqual(@as(usize, 8), messages.items.len);
    const expected_roles = [_]message.Role{
        .user,
        .assistant,
        .tool,
        .user,
        .assistant,
        .tool,
        .user,
        .assistant,
    };
    for (messages.items, expected_roles) |projected, role| {
        try std.testing.expectEqual(role, projected.role);
    }
    try std.testing.expectEqualStrings("after first", messages.items[3].content.?.asText());
    try std.testing.expectEqualStrings("after second", messages.items[6].content.?.asText());
}

test "resume projection replays assistant tool execution memory before final answer" {
    const alloc = std.testing.allocator;
    var calls = [_]ToolCall{.{
        .id = "call_read",
        .name = "read_file",
        .arguments_json = "{\"path\":\"src/main.zig\"}",
    }};
    var results = [_]PersistedToolResult{.{
        .tool_call_id = @constCast("call_read"),
        .tool_name = @constCast("read_file"),
        .status = .success,
        .output = @constCast("file contents"),
        .output_bytes = 13,
        .stored_output_bytes = 13,
    }};
    var steps = [_]ToolExecutionStep{.{
        .assistant = @constCast("I'll read it."),
        .tool_calls = calls[0..],
        .tool_results = results[0..],
    }};
    var files = [_]FileEvidence{.{
        .path = @constCast("src/main.zig"),
        .tool_call_id = @constCast("call_read"),
        .tool_name = @constCast("read_file"),
        .action = .read,
        .status = .success,
        .model_view_covers_full_file = true,
    }};
    const history = [_]HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("inspect main") },
        .assistant = @constCast("main wires the app"),
        .execution = .{ .tool_steps = steps[0..], .files = files[0..] },
    } }};

    var messages: std.ArrayList(message.Message) = .empty;
    defer deinitMessages(alloc, &messages);
    try appendHistoryMessages(alloc, &messages, &history);

    try std.testing.expectEqual(@as(usize, 5), messages.items.len);
    try std.testing.expectEqual(.user, messages.items[0].role);
    try std.testing.expectEqual(.assistant, messages.items[1].role);
    try std.testing.expectEqualStrings("call_read", messages.items[1].tool_calls[0].id);
    try std.testing.expectEqual(.tool, messages.items[2].role);
    try std.testing.expectEqualStrings("file contents", messages.items[2].content.?.asText());
    try std.testing.expectEqual(.user, messages.items[3].role);
    try std.testing.expect(std.mem.find(u8, messages.items[3].content.?.asText(), "model_view=full") != null);
    try std.testing.expectEqual(.assistant, messages.items[4].role);
    try std.testing.expectEqualStrings("main wires the app", messages.items[4].content.?.asText());
}

test "resume projections omit empty terminal assistant after completed execution" {
    const alloc = std.testing.allocator;
    var calls = [_]ToolCall{.{
        .id = "call_read",
        .name = "read_file",
        .arguments_json = "{\"path\":\"src/main.zig\"}",
    }};
    var results = [_]PersistedToolResult{.{
        .tool_call_id = @constCast("call_read"),
        .tool_name = @constCast("read_file"),
        .status = .success,
        .output = @constCast("file contents"),
        .output_bytes = 13,
        .stored_output_bytes = 13,
    }};
    var steps = [_]ToolExecutionStep{.{
        .tool_calls = calls[0..],
        .tool_results = results[0..],
    }};
    const history = [_]HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("inspect main") },
        .assistant = @constCast(""),
        .execution = .{ .tool_steps = steps[0..] },
    } }};

    var messages: std.ArrayList(message.Message) = .empty;
    defer deinitMessages(alloc, &messages);
    try appendHistoryMessages(alloc, &messages, &history);
    try std.testing.expectEqual(@as(usize, 3), messages.items.len);
    try std.testing.expectEqual(.user, messages.items[0].role);
    try std.testing.expectEqual(.assistant, messages.items[1].role);
    try std.testing.expectEqualStrings("call_read", messages.items[1].tool_calls[0].id);
    try std.testing.expectEqual(.tool, messages.items[2].role);
    try std.testing.expectEqualStrings("file contents", messages.items[2].content.?.asText());

    var chat_messages: std.ArrayList(core_types.ChatMessage) = .empty;
    defer chat_messages.deinit(alloc);
    try appendHistoryChatMessages(alloc, &chat_messages, &history);
    try std.testing.expectEqual(@as(usize, 3), chat_messages.items.len);
    try std.testing.expectEqual(core_types.ChatRole.user, chat_messages.items[0].role);
    try std.testing.expectEqual(core_types.ChatRole.assistant, chat_messages.items[1].role);
    try std.testing.expectEqualStrings("call_read", chat_messages.items[1].tool_calls[0].id);
    try std.testing.expectEqual(core_types.ChatRole.tool, chat_messages.items[2].role);
    try std.testing.expectEqualStrings("file contents", chat_messages.items[2].content.?);
}

test "resume projections place permission feedback after its tool result" {
    const alloc = std.testing.allocator;
    var feedback = [_][]u8{@constCast("read it after writing")};
    var calls = [_]ToolCall{.{
        .id = "call_feedback",
        .name = "write_file",
        .arguments_json = "{\"path\":\"note.txt\"}",
    }};
    var results = [_]PersistedToolResult{.{
        .tool_call_id = @constCast("call_feedback"),
        .tool_name = @constCast("write_file"),
        .status = .success,
        .output = @constCast("wrote note.txt"),
        .output_bytes = 15,
        .stored_output_bytes = 15,
        .permission_feedback = feedback[0..],
    }};
    var steps = [_]ToolExecutionStep{.{
        .tool_calls = calls[0..],
        .tool_results = results[0..],
    }};
    const history = [_]HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("write a note") },
        .assistant = @constCast("done"),
        .execution = .{ .tool_steps = steps[0..] },
    } }};

    var messages: std.ArrayList(message.Message) = .empty;
    defer deinitMessages(alloc, &messages);
    try appendHistoryMessages(alloc, &messages, &history);
    try std.testing.expectEqual(@as(usize, 5), messages.items.len);
    try std.testing.expectEqual(.tool, messages.items[2].role);
    try std.testing.expectEqual(.user, messages.items[3].role);
    try std.testing.expectEqualStrings(
        "read it after writing",
        messages.items[3].content.?.asText(),
    );
    try std.testing.expectEqual(.assistant, messages.items[4].role);

    var chat_messages: std.ArrayList(core_types.ChatMessage) = .empty;
    defer chat_messages.deinit(alloc);
    try appendHistoryChatMessages(alloc, &chat_messages, &history);
    try std.testing.expectEqual(@as(usize, 5), chat_messages.items.len);
    try std.testing.expectEqual(core_types.ChatRole.tool, chat_messages.items[2].role);
    try std.testing.expectEqual(core_types.ChatRole.user, chat_messages.items[3].role);
    try std.testing.expectEqualStrings("read it after writing", chat_messages.items[3].content.?);
    try std.testing.expectEqual(core_types.ChatRole.assistant, chat_messages.items[4].role);
}

test "resume projections group two tool results before their feedback" {
    const alloc = std.testing.allocator;
    var first_feedback = [_][]u8{@constCast("first command feedback marker")};
    var second_feedback = [_][]u8{@constCast("second command feedback marker")};
    var calls = [_]ToolCall{
        .{ .id = "call_first", .name = "run_command", .arguments_json = "{\"command\":\"printf first\"}" },
        .{ .id = "call_second", .name = "run_command", .arguments_json = "{\"command\":\"printf second\"}" },
    };
    var results = [_]PersistedToolResult{
        .{
            .tool_call_id = @constCast("call_first"),
            .tool_name = @constCast("run_command"),
            .status = .success,
            .output = @constCast("first command completed"),
            .output_bytes = 23,
            .stored_output_bytes = 23,
            .permission_feedback = first_feedback[0..],
        },
        .{
            .tool_call_id = @constCast("call_second"),
            .tool_name = @constCast("run_command"),
            .status = .success,
            .output = @constCast("second command completed"),
            .output_bytes = 24,
            .stored_output_bytes = 24,
            .permission_feedback = second_feedback[0..],
        },
    };
    var steps = [_]ToolExecutionStep{.{
        .tool_calls = calls[0..],
        .tool_results = results[0..],
    }};
    const history = [_]HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("run both commands") },
        .assistant = @constCast("done"),
        .execution = .{ .tool_steps = steps[0..] },
    } }};

    var messages: std.ArrayList(message.Message) = .empty;
    defer deinitMessages(alloc, &messages);
    try appendHistoryMessages(alloc, &messages, &history);
    try std.testing.expectEqual(@as(usize, 7), messages.items.len);
    try std.testing.expectEqual(.tool, messages.items[2].role);
    try std.testing.expectEqual(.tool, messages.items[3].role);
    try std.testing.expectEqual(.user, messages.items[4].role);
    try std.testing.expectEqual(.user, messages.items[5].role);

    var chat_messages: std.ArrayList(core_types.ChatMessage) = .empty;
    defer chat_messages.deinit(alloc);
    try appendHistoryChatMessages(alloc, &chat_messages, &history);
    try std.testing.expectEqual(@as(usize, 7), chat_messages.items.len);
    try std.testing.expectEqual(core_types.ChatRole.tool, chat_messages.items[2].role);
    try std.testing.expectEqual(core_types.ChatRole.tool, chat_messages.items[3].role);
    try std.testing.expectEqual(core_types.ChatRole.user, chat_messages.items[4].role);
    try std.testing.expectEqual(core_types.ChatRole.user, chat_messages.items[5].role);
}

test "execution replay context and token estimate include permission feedback" {
    const alloc = std.testing.allocator;
    var feedback = [_][]u8{@constCast("read it after writing")};
    var with_feedback_results = [_]PersistedToolResult{.{
        .tool_call_id = @constCast("call_feedback"),
        .tool_name = @constCast("write_file"),
        .status = .success,
        .output = @constCast("wrote note.txt"),
        .output_bytes = 15,
        .stored_output_bytes = 15,
        .permission_feedback = feedback[0..],
    }};
    var without_feedback_results = [_]PersistedToolResult{.{
        .tool_call_id = @constCast("call_feedback"),
        .tool_name = @constCast("write_file"),
        .status = .success,
        .output = @constCast("wrote note.txt"),
        .output_bytes = 15,
        .stored_output_bytes = 15,
    }};
    var with_feedback_steps = [_]ToolExecutionStep{.{ .tool_results = with_feedback_results[0..] }};
    var without_feedback_steps = [_]ToolExecutionStep{.{ .tool_results = without_feedback_results[0..] }};
    const with_feedback = ExecutionMemory{ .tool_steps = with_feedback_steps[0..] };
    const without_feedback = ExecutionMemory{ .tool_steps = without_feedback_steps[0..] };

    const context = (try formatExecutionReplayContext(alloc, with_feedback)).?;
    defer alloc.free(context);
    try std.testing.expect(std.mem.find(u8, context, "wrote note.txt") != null);
    try std.testing.expect(std.mem.find(u8, context, "read it after writing") != null);
    try std.testing.expect(estimateExecutionTokens(with_feedback) > estimateExecutionTokens(without_feedback));
}

test "budgeted resume projection preserves latest turn and summarizes trimmed handle evidence" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var large_calls = [_]ToolCall{.{
        .id = "call_large",
        .name = "run_command",
        .arguments_json = "{\"command\":\"make lots of evidence\"}",
    }};
    var large_results = [_]PersistedToolResult{.{
        .tool_call_id = @constCast("call_large"),
        .tool_name = @constCast("run_command"),
        .status = .success,
        .output = @constCast("<tool_result_preview handle=\"result-call_large-abc.txt\">preview evidence</tool_result_preview>"),
        .output_bytes = 80_000,
        .stored_output_bytes = 80_000,
        .truncated = true,
        .provider_native = false,
        .created_at_ms = 1,
        .output_handle = @constCast("result-call_large-abc.txt"),
        .preview = @constCast("preview evidence"),
    }};
    var large_steps = [_]ToolExecutionStep{.{
        .tool_calls = large_calls[0..],
        .tool_results = large_results[0..],
    }};
    const history = [_]HistoryTurn{
        .{ .assistant = .{
            .user = .{ .text = @constCast("old large request") },
            .assistant = @constCast("old large answer"),
            .execution = .{ .tool_steps = large_steps[0..] },
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("latest request that must survive") },
            .assistant = @constCast("latest answer"),
        } },
    };

    var messages: std.ArrayList(core_types.ChatMessage) = .empty;
    defer messages.deinit(arena);
    try appendHistoryChatMessagesBudgeted(arena, &messages, &history, .{ .max_tokens = 12 });

    try std.testing.expect(messages.items.len >= 3);
    try std.testing.expectEqual(core_types.ChatRole.user, messages.items[0].role);
    try std.testing.expect(std.mem.find(u8, messages.items[0].content.?, "result-call_large-abc.txt") != null);
    try std.testing.expect(std.mem.find(u8, messages.items[0].content.?, "preview evidence") != null);
    try std.testing.expectEqualStrings("latest request that must survive", messages.items[messages.items.len - 2].content.?);
    try std.testing.expectEqualStrings("latest answer", messages.items[messages.items.len - 1].content.?);
}

test "budgeted resume projection preserves compacted summary when older handle evidence is trimmed" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var large_calls = [_]ToolCall{.{
        .id = "call_large",
        .name = "run_command",
        .arguments_json = "{\"command\":\"make lots of evidence\"}",
    }};
    var large_results = [_]PersistedToolResult{.{
        .tool_call_id = @constCast("call_large"),
        .tool_name = @constCast("run_command"),
        .status = .success,
        .output = @constCast("<tool_result_preview handle=\"result-call_large-summary.txt\">summary preview evidence</tool_result_preview>"),
        .output_bytes = 80_000,
        .stored_output_bytes = 80_000,
        .truncated = true,
        .provider_native = false,
        .created_at_ms = 1,
        .output_handle = @constCast("result-call_large-summary.txt"),
        .preview = @constCast("summary preview evidence"),
    }};
    var large_steps = [_]ToolExecutionStep{.{
        .tool_calls = large_calls[0..],
        .tool_results = large_results[0..],
    }};
    const history = [_]HistoryTurn{
        .{ .compacted_summary = .{
            .summary = @constCast("Conversation summary:\n- Prior compacted decision needle " ++ ("x" ** 240)),
            .removed_turn_count = 6,
            .compaction_count = 2,
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("old large request") },
            .assistant = @constCast("old large answer"),
            .execution = .{ .tool_steps = large_steps[0..] },
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("latest request that must survive") },
            .assistant = @constCast("latest answer"),
        } },
    };

    var messages: std.ArrayList(core_types.ChatMessage) = .empty;
    defer messages.deinit(arena);
    try appendHistoryChatMessagesBudgeted(arena, &messages, &history, .{ .max_tokens = 12 });

    try std.testing.expect(messages.items.len >= 3);
    try std.testing.expectEqual(core_types.ChatRole.user, messages.items[0].role);
    try std.testing.expect(std.mem.find(u8, messages.items[0].content.?, "Prior compacted decision needle") != null);
    try std.testing.expect(std.mem.find(u8, messages.items[0].content.?, "result-call_large-summary.txt") != null);
    try std.testing.expect(std.mem.find(u8, messages.items[0].content.?, "summary preview evidence") != null);
    try std.testing.expectEqualStrings("latest request that must survive", messages.items[messages.items.len - 2].content.?);
    try std.testing.expectEqualStrings("latest answer", messages.items[messages.items.len - 1].content.?);
}

test "budgeted Message and Chat projections retain latest turn and identical trimmed evidence" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var trimmed_calls = [_]ToolCall{.{
        .id = "call_trimmed",
        .name = "run_command",
        .arguments_json = "{\"command\":\"produce extensive evidence\"}",
    }};
    var trimmed_results = [_]PersistedToolResult{.{
        .tool_call_id = @constCast("call_trimmed"),
        .tool_name = @constCast("run_command"),
        .status = .failure,
        .output = @constCast("trimmed failure output"),
        .output_bytes = 22,
        .stored_output_bytes = 22,
        .output_handle = @constCast("result-call_trimmed.txt"),
        .preview = @constCast("trimmed failure preview"),
    }};
    var trimmed_files = [_]FileEvidence{.{
        .path = @constCast("src/trimmed.zig"),
        .tool_call_id = @constCast("call_trimmed"),
        .tool_name = @constCast("run_command"),
        .action = .write,
        .status = .failure,
        .stale = true,
    }};
    var trimmed_steps = [_]ToolExecutionStep{.{
        .assistant = @constCast("collecting extensive trimmed evidence"),
        .tool_calls = trimmed_calls[0..],
        .tool_results = trimmed_results[0..],
    }};
    var retained_calls = [_]ToolCall{.{
        .id = "call_retained",
        .name = "read_file",
        .arguments_json = "{\"path\":\"src/retained.zig\"}",
    }};
    var retained_results = [_]PersistedToolResult{.{
        .tool_call_id = @constCast("call_retained"),
        .tool_name = @constCast("read_file"),
        .status = .failure,
        .output = @constCast("retained failure"),
        .output_bytes = 16,
        .stored_output_bytes = 16,
    }};
    var retained_files = [_]FileEvidence{.{
        .path = @constCast("src/retained.zig"),
        .tool_call_id = @constCast("call_retained"),
        .tool_name = @constCast("read_file"),
        .action = .read,
        .status = .failure,
        .model_view_covers_full_file = true,
    }};
    var retained_steps = [_]ToolExecutionStep{.{
        .assistant = @constCast("reading retained"),
        .tool_calls = retained_calls[0..],
        .tool_results = retained_results[0..],
    }};
    var background_images = [_]ImageAttachment{.{
        .id = 7,
        .path = @constCast("/tmp/background.png"),
        .media_type = @constCast("image/png"),
    }};
    var interrupted_images = [_]ImageAttachment{.{
        .id = 8,
        .path = @constCast("/tmp/interrupted.jpg"),
        .media_type = @constCast("image/jpeg"),
    }};
    var latest_images = [_]ImageAttachment{.{
        .id = 9,
        .path = @constCast("/tmp/latest.webp"),
        .media_type = @constCast("image/webp"),
    }};
    const history = [_]HistoryTurn{
        .{ .compacted_summary = .{
            .summary = @constCast("prior compacted decision needle " ++ ("x" ** 320)),
            .removed_turn_count = 5,
            .compaction_count = 2,
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("old request " ++ ("y" ** 240)) },
            .assistant = @constCast("old answer " ++ ("z" ** 240)),
            .execution = .{
                .tool_steps = trimmed_steps[0..],
                .files = trimmed_files[0..],
            },
        } },
        .{ .assistant = .{
            .user = .{
                .text = @constCast("run retained"),
                .images = background_images[0..],
            },
            .assistant = @constCast("server ready"),
            .execution = .{
                .tool_steps = retained_steps[0..],
                .files = retained_files[0..],
            },
        } },
        .{ .interrupted = .{
            .user = .{
                .text = @constCast("stop retained"),
                .images = interrupted_images[0..],
            },
            .assistant = @constCast("partial retained"),
            .tool_call = .{
                .id = "call_interrupted",
                .name = "browser_navigate",
                .arguments_json = "{\"url\":\"http://localhost:3000\"}",
            },
        } },
        .{ .assistant = .{
            .user = .{
                .text = @constCast("latest request"),
                .images = latest_images[0..],
            },
            .assistant = @constCast("latest answer"),
        } },
    };

    var messages: std.ArrayList(message.Message) = .empty;
    defer deinitMessages(arena, &messages);
    try appendHistoryMessagesBudgeted(
        arena,
        &messages,
        &history,
        .{ .max_tokens = 64 },
    );
    var chat_messages: std.ArrayList(core_types.ChatMessage) = .empty;
    defer chat_messages.deinit(arena);
    try appendHistoryChatMessagesBudgeted(
        arena,
        &chat_messages,
        &history,
        .{ .max_tokens = 64 },
    );

    try std.testing.expectEqual(messages.items.len, chat_messages.items.len);
    var saw_interrupted = false;
    var saw_failure_status = false;
    var saw_file_evidence = false;
    var saw_background_image = false;
    var saw_interrupted_image = false;
    var saw_latest_image = false;
    for (messages.items, chat_messages.items) |projected, chat| {
        try std.testing.expectEqualStrings(
            @tagName(projected.role),
            @tagName(chat.role),
        );
        try std.testing.expectEqual(projected.content == null, chat.content == null);
        if (projected.content) |content| {
            try std.testing.expectEqualStrings(content.asText(), chat.content.?);
            saw_interrupted = saw_interrupted or
                std.mem.find(u8, content.asText(), "<turn_aborted>") != null;
            saw_file_evidence = saw_file_evidence or
                std.mem.find(u8, content.asText(), "src/retained.zig") != null;
        }
        try std.testing.expectEqual(projected.images.len, chat.images.len);
        for (projected.images, chat.images) |projected_image, chat_image| {
            try std.testing.expectEqual(projected_image.id, chat_image.id);
            try std.testing.expectEqualStrings(projected_image.path, chat_image.path);
            try std.testing.expectEqualStrings(
                projected_image.media_type,
                chat_image.media_type,
            );
            saw_background_image = saw_background_image or
                std.mem.eql(u8, projected_image.path, "/tmp/background.png");
            saw_interrupted_image = saw_interrupted_image or
                std.mem.eql(u8, projected_image.path, "/tmp/interrupted.jpg");
            saw_latest_image = saw_latest_image or
                std.mem.eql(u8, projected_image.path, "/tmp/latest.webp");
        }
        try std.testing.expectEqual(projected.tool_calls.len, chat.tool_calls.len);
        for (projected.tool_calls, chat.tool_calls) |projected_call, chat_call| {
            try std.testing.expectEqualStrings(projected_call.id, chat_call.id);
            try std.testing.expectEqualStrings(projected_call.name, chat_call.name);
            try std.testing.expectEqualStrings(
                projected_call.arguments_json,
                chat_call.arguments_json,
            );
        }
        try std.testing.expectEqual(projected.tool_result_status, chat.tool_result_status);
        saw_failure_status = saw_failure_status or
            projected.tool_result_status == .failure;
    }

    const trimmed_context = messages.items[0].content.?.asText();
    try std.testing.expect(std.mem.find(
        u8,
        trimmed_context,
        "prior compacted decision needle",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        trimmed_context,
        "result-call_trimmed.txt",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        trimmed_context,
        "src/trimmed.zig",
    ) != null);
    try std.testing.expect(saw_interrupted);
    try std.testing.expect(saw_failure_status);
    try std.testing.expect(saw_file_evidence);
    try std.testing.expect(saw_background_image);
    try std.testing.expect(saw_interrupted_image);
    try std.testing.expect(saw_latest_image);
    try std.testing.expectEqualStrings(
        "latest request",
        messages.items[messages.items.len - 2].content.?.asText(),
    );
    try std.testing.expectEqualStrings(
        "latest answer",
        messages.items[messages.items.len - 1].content.?.asText(),
    );
}

test "active context snapshot preserves large result handles exactly" {
    const alloc = std.testing.allocator;
    var runtime: SessionRuntime = .{ .max_history_turns = 2 };
    defer runtime.deinit(alloc);

    var calls = [_]ToolCall{.{
        .id = "call_large",
        .name = "run_command",
        .arguments_json = "{\"command\":\"large\"}",
    }};
    var results = [_]PersistedToolResult{.{
        .tool_call_id = @constCast("call_large"),
        .tool_name = @constCast("run_command"),
        .status = .success,
        .output = @constCast("<tool_result_preview handle=\"result-call_large-abc.txt\">important preview</tool_result_preview>"),
        .output_bytes = 70_000,
        .stored_output_bytes = 70_000,
        .truncated = true,
        .provider_native = false,
        .created_at_ms = 1,
        .output_handle = @constCast("result-call_large-abc.txt"),
        .preview = @constCast("important preview"),
    }};
    var steps = [_]ToolExecutionStep{.{
        .tool_calls = calls[0..],
        .tool_results = results[0..],
    }};
    const old_turn: HistoryTurn = .{ .assistant = .{
        .user = .{ .text = @constCast("old") },
        .assistant = @constCast("old answer"),
        .execution = .{ .tool_steps = steps[0..] },
    } };
    try runtime.appendHistoryEntry(alloc, old_turn);
    try runtime.appendAssistantHistoryTurn(alloc, "middle", "middle answer");
    try runtime.appendAssistantHistoryTurn(alloc, "latest", "latest answer");

    try std.testing.expectEqual(@as(usize, 3), runtime.historyLen());
    try std.testing.expectEqualStrings(
        "call_large",
        runtime.agent.history.items[0].assistant.execution.tool_steps[0].tool_calls[0].id,
    );
    try std.testing.expectEqualStrings(
        "result-call_large-abc.txt",
        runtime.agent.history.items[0].assistant.execution.tool_steps[0].tool_results[0].output_handle.?,
    );

    const context = try runtime.snapshotContextHistory(alloc);
    defer freeHistoryTurnSlice(alloc, context);
    try std.testing.expectEqual(@as(usize, 3), context.len);
    try std.testing.expectEqual(HistoryTurn.assistant, std.meta.activeTag(context[0]));
    try std.testing.expectEqualStrings(
        "result-call_large-abc.txt",
        context[0].assistant.execution.tool_steps[0].tool_results[0].output_handle.?,
    );
    try std.testing.expectEqualStrings(
        "important preview",
        context[0].assistant.execution.tool_steps[0].tool_results[0].preview.?,
    );
}

test "interrupted history projects marker and aborted tool result" {
    const alloc = std.testing.allocator;
    const replay_sentinel = "PRESENTATION_REPLAY_SENTINEL.bin";
    const artifact_sentinel = "PRESENTATION_ARTIFACT_SENTINEL.log";
    const history = [_]HistoryTurn{.{ .interrupted = .{
        .user = .{ .text = @constCast("run a command") },
        .tool_call = .{
            .id = "call-command",
            .name = "run_command",
            .arguments_json = "{\"command\":\"slow\"}",
        },
        .cancelled_command = .{
            .output_replay = .{ .available = .{
                .handle = replay_sentinel,
                .framed_bytes = 42,
            } },
            .command_artifact_handle = artifact_sentinel,
        },
    } }};

    var messages: std.ArrayList(message.Message) = .empty;
    defer deinitMessages(alloc, &messages);
    try appendHistoryMessages(alloc, &messages, &history);

    try std.testing.expectEqual(@as(usize, 4), messages.items.len);
    try std.testing.expectEqual(.user, messages.items[0].role);
    try std.testing.expectEqualStrings("run a command", messages.items[0].content.?.asText());
    try std.testing.expectEqual(.assistant, messages.items[1].role);
    try std.testing.expect(messages.items[1].content == null);
    try std.testing.expectEqual(@as(usize, 1), messages.items[1].tool_calls.len);
    try std.testing.expectEqualStrings("call-command", messages.items[1].tool_calls[0].id);
    try std.testing.expectEqualStrings("run_command", messages.items[1].tool_calls[0].name);
    try std.testing.expectEqual(.tool, messages.items[2].role);
    try std.testing.expect(
        std.mem.find(u8, messages.items[2].content.?.asText(), aborted_tool_output) != null,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, messages.items[2].content.?.asText(), replay_sentinel),
    );
    try std.testing.expectEqualStrings("call-command", messages.items[2].tool_call_id.?);
    try std.testing.expectEqual(.user, messages.items[3].role);
    try std.testing.expect(std.mem.find(u8, messages.items[3].content.?.asText(), "<turn_aborted>") != null);
    try std.testing.expect(std.mem.find(u8, messages.items[3].content.?.asText(), "Do not continue") != null);
    for (messages.items) |entry| {
        if (entry.content) |content| {
            try std.testing.expect(std.mem.find(u8, content.asText(), artifact_sentinel) == null);
        }
    }

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var chat_messages: std.ArrayList(core_types.ChatMessage) = .empty;
    defer chat_messages.deinit(arena);
    try appendHistoryChatMessages(arena, &chat_messages, &history);

    try std.testing.expectEqual(@as(usize, 4), chat_messages.items.len);
    try std.testing.expectEqual(core_types.ChatRole.assistant, chat_messages.items[1].role);
    try std.testing.expect(chat_messages.items[1].content == null);
    try std.testing.expectEqualStrings("run_command", chat_messages.items[1].tool_calls[0].name);
    try std.testing.expectEqual(core_types.ChatRole.tool, chat_messages.items[2].role);
    try std.testing.expect(
        std.mem.find(u8, chat_messages.items[2].content.?, aborted_tool_output) != null,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, chat_messages.items[2].content.?, replay_sentinel),
    );
    try std.testing.expectEqual(core_types.ChatRole.user, chat_messages.items[3].role);
    try std.testing.expect(std.mem.find(u8, chat_messages.items[3].content.?, "<turn_aborted>") != null);
    for (chat_messages.items) |entry| {
        if (entry.content) |content| {
            try std.testing.expect(std.mem.find(u8, content, artifact_sentinel) == null);
        }
    }
}

test "no-output interrupted history projects synthetic assistant before marker" {
    const alloc = std.testing.allocator;
    const history = [_]HistoryTurn{.{ .interrupted = .{
        .user = .{ .text = @constCast("create test.md with 200 lines") },
    } }};

    var messages: std.ArrayList(message.Message) = .empty;
    defer deinitMessages(alloc, &messages);
    try appendHistoryMessages(alloc, &messages, &history);

    try std.testing.expectEqual(@as(usize, 3), messages.items.len);
    try std.testing.expectEqual(.user, messages.items[0].role);
    try std.testing.expectEqualStrings("create test.md with 200 lines", messages.items[0].content.?.asText());
    try std.testing.expectEqual(.assistant, messages.items[1].role);
    try std.testing.expectEqualStrings(interrupted_before_completion_output, messages.items[1].content.?.asText());
    try std.testing.expectEqual(.user, messages.items[2].role);
    try std.testing.expect(std.mem.find(u8, messages.items[2].content.?.asText(), "<turn_aborted>") != null);
    try std.testing.expect(std.mem.find(u8, messages.items[2].content.?.asText(), "user interrupted") == null);
    try std.testing.expect(std.mem.find(u8, messages.items[2].content.?.asText(), "Do not continue this request unless") != null);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var chat_messages: std.ArrayList(core_types.ChatMessage) = .empty;
    defer chat_messages.deinit(arena);
    try appendHistoryChatMessages(arena, &chat_messages, &history);

    try std.testing.expectEqual(@as(usize, 3), chat_messages.items.len);
    try std.testing.expectEqual(core_types.ChatRole.user, chat_messages.items[0].role);
    try std.testing.expectEqualStrings("create test.md with 200 lines", chat_messages.items[0].content.?);
    try std.testing.expectEqual(core_types.ChatRole.assistant, chat_messages.items[1].role);
    try std.testing.expectEqualStrings(interrupted_before_completion_output, chat_messages.items[1].content.?);
    try std.testing.expectEqual(core_types.ChatRole.user, chat_messages.items[2].role);
    try std.testing.expect(std.mem.find(u8, chat_messages.items[2].content.?, "<turn_aborted>") != null);
    try std.testing.expect(std.mem.find(u8, chat_messages.items[2].content.?, "user interrupted") == null);
}

test "steering continuation omits only the trailing interrupted closure" {
    const alloc = std.testing.allocator;
    const history = [_]HistoryTurn{
        .{ .interrupted = .{
            .user = .{ .text = @constCast("older interrupted request") },
            .assistant = @constCast("older partial"),
        } },
        .{ .interrupted = .{
            .user = .{ .text = @constCast("active request") },
            .assistant = @constCast("active partial"),
        } },
    };

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var messages: std.ArrayList(core_types.ChatMessage) = .empty;
    defer messages.deinit(arena);

    try appendSteeringContinuationHistoryChatMessagesBudgeted(
        arena,
        &messages,
        &history,
        .{},
    );

    try std.testing.expectEqual(@as(usize, 5), messages.items.len);
    try std.testing.expect(std.mem.find(u8, messages.items[2].content.?, "<turn_aborted>") != null);
    try std.testing.expectEqual(core_types.ChatRole.user, messages.items[3].role);
    try std.testing.expectEqualStrings("active request", messages.items[3].content.?);
    try std.testing.expectEqual(core_types.ChatRole.assistant, messages.items[4].role);
    try std.testing.expectEqualStrings("active partial", messages.items[4].content.?);
    try std.testing.expect(std.mem.find(u8, messages.items[4].content.?, interrupted_before_completion_output) == null);
}

test "partial-text interrupted history projects partial assistant with closure before marker" {
    const alloc = std.testing.allocator;
    const expected_assistant =
        "Once there was a partial answer.\n\n" ++
        interrupted_before_completion_output;
    const history = [_]HistoryTurn{.{ .interrupted = .{
        .user = .{ .text = @constCast("tell me a story") },
        .assistant = @constCast("Once there was a partial answer."),
    } }};

    var messages: std.ArrayList(message.Message) = .empty;
    defer deinitMessages(alloc, &messages);
    try appendHistoryMessages(alloc, &messages, &history);

    try std.testing.expectEqual(@as(usize, 3), messages.items.len);
    try std.testing.expectEqual(.user, messages.items[0].role);
    try std.testing.expectEqualStrings("tell me a story", messages.items[0].content.?.asText());
    try std.testing.expectEqual(.assistant, messages.items[1].role);
    try std.testing.expectEqualStrings(expected_assistant, messages.items[1].content.?.asText());
    try std.testing.expectEqual(.user, messages.items[2].role);
    try std.testing.expect(std.mem.find(u8, messages.items[2].content.?.asText(), "<turn_aborted>") != null);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var chat_messages: std.ArrayList(core_types.ChatMessage) = .empty;
    defer chat_messages.deinit(arena);
    try appendHistoryChatMessages(arena, &chat_messages, &history);

    try std.testing.expectEqual(@as(usize, 3), chat_messages.items.len);
    try std.testing.expectEqual(core_types.ChatRole.user, chat_messages.items[0].role);
    try std.testing.expectEqualStrings("tell me a story", chat_messages.items[0].content.?);
    try std.testing.expectEqual(core_types.ChatRole.assistant, chat_messages.items[1].role);
    try std.testing.expectEqualStrings(expected_assistant, chat_messages.items[1].content.?);
    try std.testing.expectEqual(core_types.ChatRole.user, chat_messages.items[2].role);
    try std.testing.expect(std.mem.find(u8, chat_messages.items[2].content.?, "<turn_aborted>") != null);
}

test "completed-tool interrupted history projects summary before marker" {
    const alloc = std.testing.allocator;
    var completed_tool_names = [_][]u8{ @constCast("glob_files"), @constCast("glob_files") };
    const history = [_]HistoryTurn{.{ .interrupted = .{
        .user = .{ .text = @constCast("use all ur tools 1 by 1 - I need u to test them") },
        .completed_tool_names = completed_tool_names[0..],
    } }};

    var messages: std.ArrayList(message.Message) = .empty;
    defer deinitMessages(alloc, &messages);
    try appendHistoryMessages(alloc, &messages, &history);

    try std.testing.expectEqual(@as(usize, 3), messages.items.len);
    try std.testing.expectEqual(.user, messages.items[0].role);
    try std.testing.expectEqualStrings("use all ur tools 1 by 1 - I need u to test them", messages.items[0].content.?.asText());
    try std.testing.expectEqual(.assistant, messages.items[1].role);
    try std.testing.expectEqualStrings("Interrupted by user after completing 2 tool calls: glob_files, glob_files.", messages.items[1].content.?.asText());
    try std.testing.expectEqual(.user, messages.items[2].role);
    try std.testing.expect(std.mem.find(u8, messages.items[2].content.?.asText(), "<turn_aborted>") != null);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var chat_messages: std.ArrayList(core_types.ChatMessage) = .empty;
    defer chat_messages.deinit(arena);
    try appendHistoryChatMessages(arena, &chat_messages, &history);

    try std.testing.expectEqual(@as(usize, 3), chat_messages.items.len);
    try std.testing.expectEqual(core_types.ChatRole.user, chat_messages.items[0].role);
    try std.testing.expectEqualStrings("use all ur tools 1 by 1 - I need u to test them", chat_messages.items[0].content.?);
    try std.testing.expectEqual(core_types.ChatRole.assistant, chat_messages.items[1].role);
    try std.testing.expectEqualStrings("Interrupted by user after completing 2 tool calls: glob_files, glob_files.", chat_messages.items[1].content.?);
    try std.testing.expectEqual(core_types.ChatRole.user, chat_messages.items[2].role);
    try std.testing.expect(std.mem.find(u8, chat_messages.items[2].content.?, "<turn_aborted>") != null);
}

test "two interrupted text turns project in order with partial assistant text" {
    const alloc = std.testing.allocator;
    const history = [_]HistoryTurn{
        .{ .interrupted = .{
            .user = .{ .text = @constCast("tell me a story in 200 words") },
            .assistant = @constCast("Once there was a quiet signal in the woods."),
        } },
        .{ .interrupted = .{
            .user = .{ .text = @constCast("go on") },
            .assistant = @constCast("The signal crossed the valley and found a door."),
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("go on") },
            .assistant = @constCast("The door opened, and the story ended in daylight."),
        } },
    };

    var messages: std.ArrayList(message.Message) = .empty;
    defer deinitMessages(alloc, &messages);
    try appendHistoryMessages(alloc, &messages, &history);

    try std.testing.expectEqual(@as(usize, 8), messages.items.len);
    try std.testing.expectEqual(.user, messages.items[0].role);
    try std.testing.expectEqualStrings("tell me a story in 200 words", messages.items[0].content.?.asText());
    try std.testing.expectEqual(.assistant, messages.items[1].role);
    try std.testing.expectEqualStrings(
        "Once there was a quiet signal in the woods.\n\n" ++ interrupted_before_completion_output,
        messages.items[1].content.?.asText(),
    );
    try std.testing.expectEqual(.user, messages.items[2].role);
    try std.testing.expect(std.mem.find(u8, messages.items[2].content.?.asText(), "<turn_aborted>") != null);
    try std.testing.expectEqual(.user, messages.items[3].role);
    try std.testing.expectEqualStrings("go on", messages.items[3].content.?.asText());
    try std.testing.expectEqual(.assistant, messages.items[4].role);
    try std.testing.expectEqualStrings(
        "The signal crossed the valley and found a door.\n\n" ++ interrupted_before_completion_output,
        messages.items[4].content.?.asText(),
    );
    try std.testing.expectEqual(.user, messages.items[5].role);
    try std.testing.expect(std.mem.find(u8, messages.items[5].content.?.asText(), "<turn_aborted>") != null);
    try std.testing.expectEqual(.user, messages.items[6].role);
    try std.testing.expectEqualStrings("go on", messages.items[6].content.?.asText());
    try std.testing.expectEqual(.assistant, messages.items[7].role);
    try std.testing.expectEqualStrings("The door opened, and the story ended in daylight.", messages.items[7].content.?.asText());

    var joined = std.ArrayList(u8).empty;
    defer joined.deinit(alloc);
    for (messages.items) |msg| {
        if (msg.content) |content| try joined.appendSlice(alloc, content.asText());
    }
    try std.testing.expect(std.mem.find(u8, joined.items, "storygo ongo on") == null);
    try std.testing.expect(std.mem.find(u8, joined.items, "tell me a story in 200 wordsgo on") == null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, joined.items, interrupted_before_completion_output));
}

test "SessionRuntime.restore replaces history, updates language, and preserves exact deep copies" {
    const alloc = std.testing.allocator;
    var runtime: SessionRuntime = .{ .max_history_turns = 2 };
    defer runtime.deinit(alloc);

    try runtime.appendAssistantHistoryTurn(alloc, "old", "old reply");

    var restore_history = [_]HistoryTurn{
        try makeAssistantTurn(alloc, "one", "reply one"),
        try makeAssistantTurn(alloc, "two", "reply two"),
        try makeAssistantTurn(alloc, "three", "reply three"),
    };
    defer {
        for (&restore_history) |turn| freeHistoryTurn(alloc, turn);
    }

    try runtime.restore(alloc, ConversationLanguage.literal("es"), &restore_history);

    try std.testing.expectEqual(ConversationLanguage.literal("es"), runtime.languageSnapshot());
    try std.testing.expectEqual(@as(usize, 3), runtime.historyLen());
    try std.testing.expectEqualStrings("one", runtime.agent.history.items[0].assistant.user.text);
    try std.testing.expectEqualStrings("reply one", runtime.agent.history.items[0].assistant.assistant);
    try std.testing.expectEqualStrings("three", runtime.agent.history.items[2].assistant.user.text);
    try std.testing.expectEqualStrings("reply three", runtime.agent.history.items[2].assistant.assistant);
    try std.testing.expect(runtime.agent.history.items[0].assistant.user.text.ptr != restore_history[0].assistant.user.text.ptr);
    try std.testing.expect(runtime.agent.history.items[2].assistant.assistant.ptr != restore_history[2].assistant.assistant.ptr);
}

test "SessionRuntime.restore may retain earlier restored turns after later append failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 3 });
    const alloc = failing.allocator();
    var runtime: SessionRuntime = .{ .max_history_turns = 0 };
    defer runtime.deinit(alloc);

    const restore_history = [_]HistoryTurn{
        .{ .assistant = .{
            .user = .{ .text = @constCast("first") },
            .assistant = @constCast("one"),
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("second") },
            .assistant = @constCast("two"),
        } },
    };

    try std.testing.expectError(error.OutOfMemory, runtime.restore(alloc, ConversationLanguage.literal("fr"), &restore_history));
    try std.testing.expectEqual(ConversationLanguage.literal("fr"), runtime.languageSnapshot());
    try std.testing.expectEqual(@as(usize, 1), runtime.historyLen());
    try std.testing.expectEqualStrings("first", runtime.agent.history.items[0].assistant.user.text);
}

test "SessionRuntime.reset clears history and restores default language" {
    const alloc = std.testing.allocator;
    var runtime: SessionRuntime = .{ .max_history_turns = 8 };
    defer runtime.deinit(alloc);

    try runtime.appendAssistantHistoryTurn(alloc, "hola", "que tal");
    runtime.setConversationLanguageFromUserMessage("ランディングページを開いて");
    try std.testing.expectEqual(ConversationLanguage.literal("ja"), runtime.languageSnapshot());

    runtime.reset(alloc);

    try std.testing.expectEqual(@as(usize, 0), runtime.historyLen());
    try std.testing.expectEqual(ConversationLanguage.default(), runtime.languageSnapshot());
}

test "SessionRuntime deduplicates context notices until facts change or the session resets" {
    const alloc = std.testing.allocator;
    var runtime: SessionRuntime = .{ .max_history_turns = 8 };
    defer runtime.deinit(alloc);

    try std.testing.expect(try runtime.claimContextNotice(alloc, "observed=20 effective=10"));
    try std.testing.expect(!try runtime.claimContextNotice(alloc, "observed=20 effective=10"));
    try std.testing.expect(try runtime.claimContextNotice(alloc, "observed=21 effective=10"));
    try std.testing.expect(try runtime.claimContextNotice(alloc, "observed=21 effective=11"));
    runtime.clearContextNotices();
    try std.testing.expect(try runtime.claimContextNotice(alloc, "observed=20 effective=10"));
}

test "SessionRuntime.clearHistory empties owned turns and keeps runtime reusable" {
    const alloc = std.testing.allocator;
    var runtime: SessionRuntime = .{ .max_history_turns = 8 };
    defer runtime.deinit(alloc);

    try runtime.appendAssistantHistoryTurn(alloc, "first", "one");
    try runtime.appendAssistantHistoryTurn(alloc, "second", "two");

    runtime.clearHistory(alloc);
    try std.testing.expectEqual(@as(usize, 0), runtime.historyLen());

    try runtime.appendAssistantHistoryTurn(alloc, "third", "three");
    try std.testing.expectEqual(@as(usize, 1), runtime.historyLen());
    try std.testing.expectEqualStrings("three", runtime.lastAssistantReply().?);
}

test "SessionRuntime appends every canonical history turn without compaction" {
    const alloc = std.testing.allocator;
    var runtime = SessionRuntime{ .max_history_turns = 2 };
    defer runtime.deinit(alloc);

    const first = try makeAssistantTurn(alloc, "one", "first");
    defer freeHistoryTurn(alloc, first);
    try runtime.appendHistoryEntry(alloc, first);

    const second = try makeAssistantTurn(alloc, "two", "second");
    defer freeHistoryTurn(alloc, second);
    try runtime.appendHistoryEntry(alloc, second);

    const third = try makeAssistantTurn(alloc, "three", "third");
    defer freeHistoryTurn(alloc, third);
    try runtime.appendHistoryEntry(alloc, third);
    try std.testing.expectEqual(@as(usize, 3), runtime.historyLen());
}

test "compactLineText preserves complete UTF-8 codepoints at the byte cap" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const split = try compactLineText(arena, "ab★z", 3);
    try std.testing.expectEqualStrings("ab", split);
    try std.testing.expect(std.unicode.utf8ValidateSlice(split));

    const exact = try compactLineText(arena, "ab★z", 5);
    try std.testing.expectEqualStrings("ab★", exact);

    const collapsed = try compactLineText(arena, "  alpha\n\tbeta  ", 10);
    try std.testing.expectEqualStrings("alpha beta", collapsed);
}

test "compacted Unicode history remains conversational context" {
    const alloc = std.testing.allocator;
    const context = [_]HistoryTurn{
        .{ .compacted_summary = .{
            .summary = @constCast(("a" ** 155) ++ "★"),
            .removed_turn_count = 2,
            .compaction_count = 1,
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("preserved user") },
            .assistant = @constCast("preserved reply"),
        } },
    };

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var messages: std.ArrayList(core_types.ChatMessage) = .empty;
    defer messages.deinit(arena);
    try appendHistoryChatMessages(arena, &messages, &context);
    try messages.append(arena, .{ .role = .user, .content = "current user" });

    try std.testing.expectEqual(core_types.ChatRole.user, messages.items[0].role);
    try std.testing.expect(messages.items[0].content != null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(messages.items[0].content.?));
    try std.testing.expectEqualStrings("preserved user", messages.items[1].content.?);
}

test "SessionRuntime context snapshot preserves the active history exactly" {
    const alloc = std.testing.allocator;
    var runtime: SessionRuntime = .{ .max_history_turns = 4 };
    defer runtime.deinit(alloc);

    try runtime.appendAssistantHistoryTurn(alloc, "one", "reply one");
    try runtime.appendAssistantHistoryTurn(alloc, "two", "reply two");
    try runtime.appendAssistantHistoryTurn(alloc, "three", "reply three");
    try runtime.appendAssistantHistoryTurn(alloc, "four", "reply four");
    try runtime.appendAssistantHistoryTurn(alloc, "five", "reply five");

    try std.testing.expectEqual(@as(usize, 5), runtime.historyLen());
    try std.testing.expectEqualStrings("one", runtime.agent.history.items[0].assistant.user.text);
    try std.testing.expectEqualStrings("five", runtime.agent.history.items[4].assistant.user.text);
    try std.testing.expectEqualStrings("reply five", runtime.lastAssistantReply().?);

    const context = try runtime.snapshotContextHistory(alloc);
    defer freeHistoryTurnSlice(alloc, context);
    try std.testing.expectEqual(@as(usize, 5), context.len);
    try std.testing.expectEqualStrings("one", context[0].assistant.user.text);
    try std.testing.expectEqualStrings("three", context[2].assistant.user.text);
    try std.testing.expectEqualStrings("five", context[4].assistant.user.text);
}

test "accepted semantic checkpoint releases summarized model memory" {
    const alloc = std.testing.allocator;
    var runtime: SessionRuntime = .{ .max_history_turns = 8 };
    defer runtime.deinit(alloc);

    try runtime.appendAssistantHistoryTurn(alloc, "first exact prompt", "first exact reply");
    try runtime.appendAssistantHistoryTurn(alloc, "second exact prompt", "second exact reply");
    try runtime.appendHistoryEntry(alloc, .{ .compacted_summary = .{
        .summary = @constCast("<context_handoff>\n# Objective\nContinue exact work.\n</context_handoff>"),
        .removed_turn_count = 2,
        .compaction_count = 1,
    } });

    try std.testing.expectEqual(@as(usize, 1), runtime.historyLen());
    try std.testing.expect(runtime.agent.history.items[0] == .compacted_summary);

    const compacted = try runtime.snapshotHistory(alloc);
    defer freeHistoryTurnSlice(alloc, compacted);
    try std.testing.expectEqual(@as(usize, 1), compacted.len);
    var projected_messages: std.ArrayList(core_types.ChatMessage) = .empty;
    defer projected_messages.deinit(alloc);
    try appendActiveContextHistoryChatMessages(
        alloc,
        &projected_messages,
        compacted,
        0,
    );
    defer alloc.free(@constCast(projected_messages.items[0].content.?));
    try std.testing.expectEqual(core_types.ChatRole.user, projected_messages.items[0].role);

    try runtime.appendAssistantHistoryTurn(alloc, "post-checkpoint prompt", "post-checkpoint reply");
    const continued = try runtime.snapshotHistory(alloc);
    defer freeHistoryTurnSlice(alloc, continued);
    try std.testing.expectEqual(@as(usize, 2), continued.len);
    try std.testing.expect(continued[0] == .compacted_summary);
    try std.testing.expectEqualStrings("post-checkpoint prompt", continued[1].assistant.user.text);
}

test "restored history keeps an in-memory unversioned prefix boundary" {
    const alloc = std.testing.allocator;
    const restored_history = [_]HistoryTurn{
        try makeAssistantTurn(alloc, "legacy one", "legacy reply one"),
        try makeAssistantTurn(alloc, "legacy two", "legacy reply two"),
    };
    defer for (restored_history) |turn| freeHistoryTurn(alloc, turn);

    var runtime: SessionRuntime = .{ .max_history_turns = 8 };
    defer runtime.deinit(alloc);
    try runtime.restore(
        alloc,
        ConversationLanguage.literal("en"),
        &restored_history,
    );
    try std.testing.expectEqual(@as(usize, 2), runtime.unversionedHistoryEnd());

    try runtime.appendAssistantHistoryTurn(alloc, "fresh", "fresh reply");
    try std.testing.expectEqual(@as(usize, 2), runtime.unversionedHistoryEnd());
    runtime.reset(alloc);
    try std.testing.expectEqual(@as(usize, 0), runtime.unversionedHistoryEnd());
}

test "current checkpoint clears restored unversioned history provenance" {
    const alloc = std.testing.allocator;
    const restored_history = [_]HistoryTurn{
        try makeAssistantTurn(alloc, "legacy prompt", "legacy reply"),
        .{ .compacted_summary = .{
            .summary = try alloc.dupe(
                u8,
                "<context_handoff>\ncurrent checkpoint\n</context_handoff>",
            ),
            .removed_turn_count = 1,
            .compaction_count = 1,
        } },
    };
    defer for (restored_history) |turn| freeHistoryTurn(alloc, turn);

    var runtime: SessionRuntime = .{ .max_history_turns = 8 };
    defer runtime.deinit(alloc);
    try runtime.restore(
        alloc,
        ConversationLanguage.literal("en"),
        restored_history[1..],
    );
    try std.testing.expectEqual(@as(usize, 0), runtime.unversionedHistoryEnd());

    try runtime.appendAssistantHistoryTurn(alloc, "fresh", "fresh reply");
    try std.testing.expectEqual(@as(usize, 0), runtime.unversionedHistoryEnd());
}

test "legacy checkpoint keeps restored provenance conservative" {
    const alloc = std.testing.allocator;
    const restored_history = [_]HistoryTurn{
        try makeAssistantTurn(alloc, "legacy prompt", "legacy reply"),
        .{ .compacted_summary = .{
            .summary = try alloc.dupe(u8, "legacy free-form summary"),
            .removed_turn_count = 1,
            .compaction_count = 1,
        } },
    };
    defer for (restored_history) |turn| freeHistoryTurn(alloc, turn);

    var runtime: SessionRuntime = .{ .max_history_turns = 8 };
    defer runtime.deinit(alloc);
    try runtime.restore(
        alloc,
        ConversationLanguage.literal("en"),
        &restored_history,
    );
    try std.testing.expectEqual(@as(usize, 2), runtime.unversionedHistoryEnd());
}

test "SessionRuntime context snapshot allocation failure preserves canonical state" {
    const alloc = std.testing.allocator;
    var runtime: SessionRuntime = .{ .max_history_turns = 8 };
    defer runtime.deinit(alloc);

    try runtime.appendAssistantHistoryTurn(alloc, "first prompt", "first reply");
    try runtime.appendAssistantHistoryTurn(alloc, "second prompt", "second reply");

    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        runtime.snapshotContextHistory(failing.allocator()),
    );

    try std.testing.expectEqual(@as(usize, 2), runtime.historyLen());
    try std.testing.expectEqualStrings(
        "first prompt",
        runtime.agent.history.items[0].assistant.user.text,
    );
    try std.testing.expectEqualStrings(
        "second prompt",
        runtime.agent.history.items[1].assistant.user.text,
    );
}

fn expectCanonicalHistoryFixtureUnchanged(
    canonical: []const HistoryTurn,
    context_history_start: usize,
) !void {
    try std.testing.expectEqual(@as(usize, 1), context_history_start);
    try std.testing.expectEqual(@as(usize, 3), canonical.len);
    try std.testing.expectEqualStrings(
        "canonical prefix",
        canonical[0].assistant.user.text,
    );
    try std.testing.expectEqualStrings(
        "prefix assistant",
        canonical[0].assistant.assistant,
    );
    try std.testing.expectEqual(@as(usize, 1), canonical[0].assistant.user.images.len);
    try std.testing.expectEqual(@as(usize, 1), canonical[0].assistant.user.images[0].id);
    try std.testing.expectEqualStrings(
        "/tmp/prefix.png",
        canonical[0].assistant.user.images[0].path,
    );
    try std.testing.expectEqualStrings(
        "image/png",
        canonical[0].assistant.user.images[0].media_type,
    );
    try std.testing.expectEqualStrings(
        "canonical background",
        canonical[1].assistant.user.text,
    );
    try std.testing.expectEqualStrings(
        "background assistant",
        canonical[1].assistant.assistant,
    );
    try std.testing.expectEqual(@as(usize, 1), canonical[1].assistant.execution.tool_steps.len);
    try std.testing.expectEqualStrings(
        "checking preserved evidence",
        canonical[1].assistant.execution.tool_steps[0].assistant.?,
    );
    try std.testing.expectEqual(@as(usize, 1), canonical[1].assistant.execution.tool_steps[0].tool_calls.len);
    try std.testing.expectEqualStrings(
        "call_preserved",
        canonical[1].assistant.execution.tool_steps[0].tool_calls[0].id,
    );
    try std.testing.expectEqualStrings(
        "read_file",
        canonical[1].assistant.execution.tool_steps[0].tool_calls[0].name,
    );
    try std.testing.expectEqualStrings(
        "{\"path\":\"fixture.txt\"}",
        canonical[1].assistant.execution.tool_steps[0].tool_calls[0].arguments_json,
    );
    try std.testing.expectEqual(@as(usize, 1), canonical[1].assistant.execution.tool_steps[0].tool_results.len);
    try std.testing.expectEqual(
        PersistedToolStatus.failure,
        canonical[1].assistant.execution.tool_steps[0].tool_results[0].status,
    );
    try std.testing.expectEqualStrings(
        "preserved failure",
        canonical[1].assistant.execution.tool_steps[0].tool_results[0].output,
    );
    try std.testing.expectEqualStrings(
        "result-call_preserved.txt",
        canonical[1].assistant.execution.tool_steps[0].tool_results[0].output_handle.?,
    );
    try std.testing.expectEqualStrings(
        "preserved preview",
        canonical[1].assistant.execution.tool_steps[0].tool_results[0].preview.?,
    );
    try std.testing.expectEqual(@as(usize, 17), canonical[1].assistant.execution.tool_steps[0].tool_results[0].output_bytes);
    try std.testing.expectEqual(@as(usize, 17), canonical[1].assistant.execution.tool_steps[0].tool_results[0].stored_output_bytes);
    try std.testing.expectEqual(@as(usize, 1), canonical[1].assistant.execution.files.len);
    try std.testing.expectEqualStrings(
        "src/preserved.zig",
        canonical[1].assistant.execution.files[0].path,
    );
    try std.testing.expectEqualStrings(
        "src/preserved-renamed.zig",
        canonical[1].assistant.execution.files[0].new_path.?,
    );
    try std.testing.expectEqualStrings(
        "call_preserved",
        canonical[1].assistant.execution.files[0].tool_call_id,
    );
    try std.testing.expectEqualStrings(
        "read_file",
        canonical[1].assistant.execution.files[0].tool_name,
    );
    try std.testing.expectEqual(
        FileEvidenceAction.rename,
        canonical[1].assistant.execution.files[0].action,
    );
    try std.testing.expectEqual(
        PersistedToolStatus.failure,
        canonical[1].assistant.execution.files[0].status,
    );
    try std.testing.expect(canonical[1].assistant.execution.files[0].model_view_covers_full_file);
    try std.testing.expect(canonical[1].assistant.execution.files[0].stale);
    try std.testing.expectEqualStrings(
        "canonical interrupted",
        canonical[2].interrupted.user.text,
    );
    try std.testing.expectEqualStrings(
        "partial assistant",
        canonical[2].interrupted.assistant.?,
    );
    try std.testing.expectEqualStrings(
        "call_interrupted",
        canonical[2].interrupted.tool_call.?.id,
    );
    try std.testing.expectEqualStrings(
        "browser_navigate",
        canonical[2].interrupted.tool_call.?.name,
    );
    try std.testing.expectEqualStrings(
        "{\"url\":\"http://localhost:3000\"}",
        canonical[2].interrupted.tool_call.?.arguments_json,
    );
    try std.testing.expectEqual(@as(usize, 1), canonical[2].interrupted.completed_tool_names.len);
    try std.testing.expectEqualStrings(
        "read_file",
        canonical[2].interrupted.completed_tool_names[0],
    );
}

fn checkPromptHistorySnapshotAllocationFailures(alloc: Allocator) !void {
    var prefix_images = [_]ImageAttachment{.{
        .id = 1,
        .path = @constCast("/tmp/prefix.png"),
        .media_type = @constCast("image/png"),
    }};
    var calls = [_]ToolCall{.{
        .id = "call_preserved",
        .name = "read_file",
        .arguments_json = "{\"path\":\"fixture.txt\"}",
    }};
    var results = [_]PersistedToolResult{.{
        .tool_call_id = @constCast("call_preserved"),
        .tool_name = @constCast("read_file"),
        .status = .failure,
        .output = @constCast("preserved failure"),
        .output_bytes = 17,
        .stored_output_bytes = 17,
        .output_handle = @constCast("result-call_preserved.txt"),
        .preview = @constCast("preserved preview"),
    }};
    var files = [_]FileEvidence{.{
        .path = @constCast("src/preserved.zig"),
        .new_path = @constCast("src/preserved-renamed.zig"),
        .tool_call_id = @constCast("call_preserved"),
        .tool_name = @constCast("read_file"),
        .action = .rename,
        .status = .failure,
        .model_view_covers_full_file = true,
        .stale = true,
    }};
    var steps = [_]ToolExecutionStep{.{
        .assistant = @constCast("checking preserved evidence"),
        .tool_calls = calls[0..],
        .tool_results = results[0..],
    }};
    var completed_tool_names = [_][]u8{@constCast("read_file")};
    var canonical = [_]HistoryTurn{
        .{ .assistant = .{
            .user = .{
                .text = @constCast("canonical prefix"),
                .images = prefix_images[0..],
            },
            .assistant = @constCast("prefix assistant"),
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("canonical background") },
            .assistant = @constCast("background assistant"),
            .execution = .{
                .tool_steps = steps[0..],
                .files = files[0..],
            },
        } },
        .{ .interrupted = .{
            .user = .{ .text = @constCast("canonical interrupted") },
            .assistant = @constCast("partial assistant"),
            .tool_call = .{
                .id = "call_interrupted",
                .name = "browser_navigate",
                .arguments_json = "{\"url\":\"http://localhost:3000\"}",
            },
            .completed_tool_names = completed_tool_names[0..],
        } },
    };
    const context_history_start: usize = 1;

    const prompt_history = snapshotOwnedContextHistory(
        alloc,
        &canonical,
        context_history_start,
        8,
    ) catch |err| {
        try expectCanonicalHistoryFixtureUnchanged(
            &canonical,
            context_history_start,
        );
        return err;
    };
    defer freeHistoryTurnSlice(alloc, prompt_history);
    try expectCanonicalHistoryFixtureUnchanged(
        &canonical,
        context_history_start,
    );
}

test "prompt history snapshot failure preserves canonical ownership" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkPromptHistorySnapshotAllocationFailures,
        .{},
    );
}

fn checkPromptHistoryMessageProjectionAllocationFailures(
    alloc: Allocator,
    prompt_history: []const HistoryTurn,
) !void {
    var messages: std.ArrayList(message.Message) = .empty;
    defer deinitMessages(alloc, &messages);

    appendHistoryMessagesBudgeted(
        alloc,
        &messages,
        prompt_history,
        .{ .max_tokens = 1 },
    ) catch |err| {
        try std.testing.expectEqualStrings(
            "old user",
            prompt_history[0].assistant.user.text,
        );
        try std.testing.expectEqualStrings(
            "latest user",
            prompt_history[1].assistant.user.text,
        );
        try std.testing.expectEqual(
            PersistedToolStatus.failure,
            prompt_history[1].assistant.execution.tool_steps[0].tool_results[0].status,
        );
        return switch (err) {
            error.WriteFailed => error.OutOfMemory,
            else => err,
        };
    };

    try std.testing.expect(messages.items.len >= 6);
    try std.testing.expectEqualStrings(
        "latest user",
        messages.items[messages.items.len - 5].content.?.asText(),
    );
    try std.testing.expectEqual(
        PersistedToolStatus.failure,
        messages.items[messages.items.len - 3].tool_result_status.?,
    );
    try std.testing.expect(std.mem.find(
        u8,
        messages.items[messages.items.len - 2].content.?.asText(),
        "src/latest.zig",
    ) != null);
}

test "prompt history cleanup is independent after snapshot creation" {
    const alloc = std.testing.allocator;
    var calls = [_]ToolCall{.{
        .id = "call_latest",
        .name = "read_file",
        .arguments_json = "{\"path\":\"src/latest.zig\"}",
    }};
    var results = [_]PersistedToolResult{.{
        .tool_call_id = @constCast("call_latest"),
        .tool_name = @constCast("read_file"),
        .status = .failure,
        .output = @constCast("latest failure"),
        .output_bytes = 14,
        .stored_output_bytes = 14,
    }};
    var files = [_]FileEvidence{.{
        .path = @constCast("src/latest.zig"),
        .tool_call_id = @constCast("call_latest"),
        .tool_name = @constCast("read_file"),
        .action = .read,
        .status = .failure,
    }};
    var steps = [_]ToolExecutionStep{.{
        .assistant = @constCast("checking latest"),
        .tool_calls = calls[0..],
        .tool_results = results[0..],
    }};
    const canonical = [_]HistoryTurn{
        .{ .assistant = .{
            .user = .{ .text = @constCast("old user") },
            .assistant = @constCast("old assistant"),
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("latest user") },
            .assistant = @constCast("latest assistant"),
            .execution = .{
                .tool_steps = steps[0..],
                .files = files[0..],
            },
        } },
    };

    const prompt_history = try snapshotOwnedContextHistory(
        alloc,
        &canonical,
        0,
        8,
    );
    defer freeHistoryTurnSlice(alloc, prompt_history);

    try std.testing.checkAllAllocationFailures(
        alloc,
        checkPromptHistoryMessageProjectionAllocationFailures,
        .{prompt_history},
    );

    try std.testing.expectEqualStrings(
        "old user",
        canonical[0].assistant.user.text,
    );
    try std.testing.expectEqualStrings(
        "latest user",
        canonical[1].assistant.user.text,
    );
}

test "owned prompt history selection matches SessionRuntime context snapshot" {
    const alloc = std.testing.allocator;
    var runtime: SessionRuntime = .{ .max_history_turns = 2 };
    defer runtime.deinit(alloc);
    try runtime.appendAssistantHistoryTurn(alloc, "one", "reply one");
    try runtime.appendAssistantHistoryTurn(alloc, "two", "reply two");
    try runtime.appendAssistantHistoryTurn(alloc, "three", "reply three");

    const direct = try snapshotOwnedContextHistory(
        alloc,
        runtime.agent.history.items,
        0,
        runtime.max_history_turns,
    );
    defer freeHistoryTurnSlice(alloc, direct);
    const through_runtime = try runtime.snapshotContextHistory(alloc);
    defer freeHistoryTurnSlice(alloc, through_runtime);

    try std.testing.expectEqual(through_runtime.len, direct.len);
    for (through_runtime, direct) |runtime_turn, direct_turn| {
        try std.testing.expectEqual(
            std.meta.activeTag(runtime_turn),
            std.meta.activeTag(direct_turn),
        );
    }
    try std.testing.expectEqual(@as(usize, 3), direct.len);
    try std.testing.expectEqualStrings("one", direct[0].assistant.user.text);
    try std.testing.expectEqualStrings("three", direct[2].assistant.user.text);
}

test "SessionRuntime context projection preserves nine typed canonical turns" {
    const alloc = std.testing.allocator;
    var runtime: SessionRuntime = .{ .max_history_turns = 8 };
    defer runtime.deinit(alloc);

    var calls = [_]ToolCall{.{
        .id = "call_first",
        .name = "read_file",
        .arguments_json = "{\"path\":\"fixture.txt\"}",
    }};
    var results = [_]PersistedToolResult{.{
        .tool_call_id = @constCast("call_first"),
        .tool_name = @constCast("read_file"),
        .status = .success,
        .output = @constCast("first result sentinel"),
        .output_bytes = 21,
        .stored_output_bytes = 21,
    }};
    var steps = [_]ToolExecutionStep{.{
        .tool_calls = calls[0..],
        .tool_results = results[0..],
    }};
    try runtime.appendHistoryEntry(alloc, .{ .assistant = .{
        .user = .{ .text = @constCast("first prompt") },
        .assistant = @constCast("first reply"),
        .execution = .{ .tool_steps = steps[0..] },
    } });
    for (1..9) |index| {
        const user = try std.fmt.allocPrint(alloc, "prompt {d}", .{index});
        defer alloc.free(user);
        const assistant = try std.fmt.allocPrint(alloc, "reply {d}", .{index});
        defer alloc.free(assistant);
        try runtime.appendAssistantHistoryTurn(alloc, user, assistant);
    }

    try std.testing.expectEqual(@as(usize, 9), runtime.historyLen());
    try std.testing.expectEqualStrings(
        "call_first",
        runtime.agent.history.items[0].assistant.execution.tool_steps[0].tool_calls[0].id,
    );
    try std.testing.expectEqualStrings(
        "first result sentinel",
        runtime.agent.history.items[0].assistant.execution.tool_steps[0].tool_results[0].output,
    );

    const context = try runtime.snapshotContextHistory(alloc);
    defer freeHistoryTurnSlice(alloc, context);
    try std.testing.expectEqual(@as(usize, 9), context.len);
    try std.testing.expectEqualStrings("first prompt", context[0].assistant.user.text);
    try std.testing.expectEqualStrings("prompt 5", context[5].assistant.user.text);
    try std.testing.expectEqualStrings("prompt 8", context[8].assistant.user.text);

    try std.testing.expectEqual(@as(usize, 9), runtime.historyLen());
    try std.testing.expectEqualStrings(
        "call_first",
        runtime.agent.history.items[0].assistant.execution.tool_steps[0].tool_calls[0].id,
    );
}

test "SessionRuntime.snapshotHistory returns deep copy that outlives runtime history" {
    const alloc = std.testing.allocator;
    var runtime: SessionRuntime = .{ .max_history_turns = 8 };
    defer runtime.deinit(alloc);

    try runtime.appendAssistantHistoryTurn(alloc, "hello", "world");
    try runtime.appendAssistantHistoryTurn(alloc, "run", "historical command");

    const snapshot = try runtime.snapshotHistory(alloc);
    defer freeHistoryTurnSlice(alloc, snapshot);

    try std.testing.expect(snapshot[0].assistant.user.text.ptr != runtime.agent.history.items[0].assistant.user.text.ptr);
    try std.testing.expect(snapshot[1].assistant.assistant.ptr != runtime.agent.history.items[1].assistant.assistant.ptr);

    runtime.clearHistory(alloc);

    try std.testing.expectEqualStrings("hello", snapshot[0].assistant.user.text);
    try std.testing.expectEqualStrings("historical command", snapshot[1].assistant.assistant);
}

test "work provenance survives owned runtime snapshots without entering model context" {
    const alloc = std.testing.allocator;
    var source = try makeAssistantTurn(alloc, "delegated prompt", "delegated reply");
    defer freeHistoryTurn(alloc, source);
    try copyWorkIdToTurn(alloc, &source, "work-λ");

    var runtime: SessionRuntime = .{ .max_history_turns = 8 };
    defer runtime.deinit(alloc);
    try runtime.restore(alloc, ConversationLanguage.literal("en"), &.{source});
    try runtime.appendAssistantHistoryTurn(alloc, "direct human prompt", "direct reply");

    const snapshot = try runtime.snapshotHistory(alloc);
    defer freeHistoryTurnSlice(alloc, snapshot);
    try std.testing.expectEqualStrings("work-λ", snapshot[0].assistant.user.work_id.?);
    try std.testing.expect(snapshot[0].assistant.user.work_id.?.ptr != source.assistant.user.work_id.?.ptr);
    try std.testing.expect(snapshot[0].assistant.user.work_id.?.ptr != runtime.agent.history.items[0].assistant.user.work_id.?.ptr);
    try std.testing.expect(snapshot[1].assistant.user.work_id == null);

    var messages: std.ArrayList(message.Message) = .empty;
    defer deinitMessages(alloc, &messages);
    try appendHistoryMessages(alloc, &messages, snapshot);
    try std.testing.expectEqualStrings(
        "delegated prompt",
        messages.items[0].content.?.asText(),
    );
    try std.testing.expect(std.mem.find(
        u8,
        messages.items[0].content.?.asText(),
        "work-λ",
    ) == null);
}

fn checkWorkProvenanceOwnershipFailures(alloc: Allocator) !void {
    var images = [_]ImageAttachment{.{
        .id = 1,
        .path = @constCast("/tmp/image.png"),
        .media_type = @constCast("image/png"),
    }};
    const copy = try dupeUserTurn(alloc, .{
        .text = @constCast("prompt"),
        .images = &images,
        .work_id = @constCast("work-owned"),
    });
    freeUserTurn(alloc, copy);
}

test "work provenance user ownership frees every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkWorkProvenanceOwnershipFailures,
        .{},
    );
}

test "SessionRuntime.snapshotHistory frees partial copies on allocation failure" {
    const base = std.testing.allocator;
    var runtime: SessionRuntime = .{ .max_history_turns = 8 };
    defer runtime.deinit(base);

    try runtime.appendAssistantHistoryTurn(base, "first", "one");
    try runtime.appendAssistantHistoryTurn(base, "second", "two");

    var failing = std.testing.FailingAllocator.init(base, .{ .fail_index = 3 });
    try std.testing.expectError(error.OutOfMemory, runtime.snapshotHistory(failing.allocator()));
}

test "active context and image catalog retain historical images" {
    const alloc = std.testing.allocator;
    var historical_images = [_]ImageAttachment{.{
        .id = 3,
        .path = @constCast("/tmp/historical.png"),
        .media_type = @constCast("image/png"),
    }};
    const history = [_]HistoryTurn{
        .{ .assistant = .{
            .user = .{ .text = @constCast("old image"), .images = &historical_images },
            .assistant = @constCast("old answer"),
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("recent text") },
            .assistant = @constCast("recent answer"),
        } },
    };

    const budgeted = try snapshotOwnedContextHistory(alloc, &history, 0, 1);
    defer freeHistoryTurnSlice(alloc, budgeted);
    try std.testing.expectEqual(@as(usize, 2), budgeted.len);
    try std.testing.expectEqual(@as(usize, 1), budgeted[0].assistant.user.images.len);

    const catalog = try collect_image_catalog(alloc, &history, &.{});
    defer core_types.freeImageAttachmentSlice(alloc, catalog);
    try std.testing.expectEqual(@as(usize, 1), catalog.len);
    try std.testing.expectEqual(@as(usize, 3), catalog[0].id);
    try std.testing.expectEqualStrings("/tmp/historical.png", catalog[0].path);
}

test "full image catalog merges canonical history and current images" {
    const alloc = std.testing.allocator;
    var historical_images = [_]ImageAttachment{.{
        .id = 2,
        .path = @constCast("/tmp/historical.png"),
        .media_type = @constCast("image/png"),
    }};
    const history = [_]HistoryTurn{.{ .interrupted = .{
        .user = .{ .text = @constCast("old image"), .images = &historical_images },
    } }};
    const current = [_]ImageAttachment{.{
        .id = 8,
        .path = @constCast("/tmp/current.jpg"),
        .media_type = @constCast("image/jpeg"),
    }};

    const catalog = try collect_image_catalog(alloc, &history, &current);
    defer core_types.freeImageAttachmentSlice(alloc, catalog);
    try std.testing.expectEqual(@as(usize, 2), catalog.len);
    try std.testing.expectEqual(@as(usize, 2), catalog[0].id);
    try std.testing.expectEqual(@as(usize, 8), catalog[1].id);
}

fn checkImageCatalogHistoryMergeAllocationFailures(alloc: Allocator) !void {
    const catalog = [_]ImageAttachment{.{
        .id = 2,
        .path = @constCast("/tmp/history.png"),
        .media_type = @constCast("image/png"),
    }};
    var added = [_]ImageAttachment{.{
        .id = 8,
        .path = @constCast("/tmp/completed.png"),
        .media_type = @constCast("image/png"),
    }};
    const turn: HistoryTurn = .{ .assistant = .{
        .user = .{ .text = @constCast("completed"), .images = &added },
        .assistant = @constCast("done"),
    } };
    const merged = try merge_image_catalog_history_turn(alloc, &catalog, turn);
    defer core_types.freeImageAttachmentSlice(alloc, merged);
    try std.testing.expectEqual(@as(usize, 2), merged.len);
}

test "image catalog history merge cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkImageCatalogHistoryMergeAllocationFailures,
        .{},
    );
}

test "full image catalog rejects duplicate authority ids" {
    var historical_images = [_]ImageAttachment{.{
        .id = 5,
        .path = @constCast("/tmp/historical.png"),
        .media_type = @constCast("image/png"),
    }};
    const history = [_]HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("old image"), .images = &historical_images },
        .assistant = @constCast("answer"),
    } }};
    const current = [_]ImageAttachment{.{
        .id = 5,
        .path = @constCast("/tmp/current.png"),
        .media_type = @constCast("image/png"),
    }};
    try std.testing.expectError(
        error.DuplicateImageId,
        collect_image_catalog(std.testing.allocator, &history, &current),
    );
}

test "full image catalog rejects zero ids outside durable resume repair" {
    const current = [_]ImageAttachment{.{
        .id = 0,
        .path = @constCast("/tmp/live-zero.png"),
        .media_type = @constCast("image/png"),
    }};
    try std.testing.expectError(
        error.InvalidImageId,
        collect_image_catalog(std.testing.allocator, &.{}, &current),
    );
}

test "full image catalog cleans up every allocation failure" {
    var historical_images = [_]ImageAttachment{.{
        .id = 1,
        .path = @constCast("/tmp/historical.png"),
        .media_type = @constCast("image/png"),
    }};
    const history = [_]HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("old image"), .images = &historical_images },
        .assistant = @constCast("answer"),
    } }};
    const current = [_]ImageAttachment{.{
        .id = 2,
        .path = @constCast("/tmp/current.jpg"),
        .media_type = @constCast("image/jpeg"),
    }};

    var probe = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const probed = try collect_image_catalog(probe.allocator(), &history, &current);
    core_types.freeImageAttachmentSlice(probe.allocator(), probed);
    for (0..probe.alloc_index) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        try std.testing.expectError(
            error.OutOfMemory,
            collect_image_catalog(failing.allocator(), &history, &current),
        );
    }
}

test "SessionRuntime.setConversationLanguageFromUserMessage preserves fallback without script signal" {
    var runtime: SessionRuntime = .{ .max_history_turns = 8 };

    runtime.setConversationLanguageFromUserMessage("привет");
    try std.testing.expectEqual(ConversationLanguage.literal("und-Cyrl"), runtime.languageSnapshot());

    runtime.setConversationLanguageFromUserMessage("12345 !!!");
    try std.testing.expectEqual(ConversationLanguage.literal("und-Cyrl"), runtime.languageSnapshot());
}

test "SessionRuntime.languageSnapshot reads restored language through mutex path" {
    const alloc = std.testing.allocator;
    var runtime: SessionRuntime = .{ .max_history_turns = 8 };
    defer runtime.deinit(alloc);

    try runtime.restore(alloc, ConversationLanguage.literal("und-Grek"), &.{});
    try std.testing.expectEqual(ConversationLanguage.literal("und-Grek"), runtime.languageSnapshot());
}

test "SessionRuntime.lastAssistantReply and lastSummary return borrowed stored slices" {
    const alloc = std.testing.allocator;
    var runtime: SessionRuntime = .{ .max_history_turns = 0 };
    defer runtime.deinit(alloc);

    try std.testing.expect(runtime.lastAssistantReply() == null);
    try std.testing.expect(runtime.lastSummary() == null);

    try runtime.appendHistoryEntry(alloc, .{ .compacted_summary = .{
        .summary = @constCast("first summary"),
        .removed_turn_count = 2,
        .compaction_count = 1,
    } });
    try runtime.appendAssistantHistoryTurn(alloc, "first", "one");
    try runtime.appendHistoryEntry(alloc, .{ .compacted_summary = .{
        .summary = @constCast("second summary"),
        .removed_turn_count = 4,
        .compaction_count = 2,
    } });
    try runtime.appendAssistantHistoryTurn(alloc, "second", "two");
    try runtime.appendAssistantHistoryTurn(alloc, "execution only", "");

    const reply = runtime.lastAssistantReply().?;
    const summary = runtime.lastSummary().?;
    try std.testing.expectEqualStrings("two", reply);
    try std.testing.expectEqualStrings("second summary", summary);
    try std.testing.expect(reply.ptr == runtime.agent.history.items[3].assistant.assistant.ptr);
    try std.testing.expect(summary.ptr == runtime.agent.history.items[2].compacted_summary.summary.ptr);
}

test "SessionRuntime owns permission transitions and immutable snapshots" {
    const alloc = std.testing.allocator;
    var runtime: SessionRuntime = .{ .max_history_turns = 8 };
    defer runtime.deinit(alloc);
    const key = try session_permission_state.RuleKey.init(
        .command,
        "command\x00/workspace\x00git status",
    );

    try std.testing.expectEqual(
        session_permission_state.ApplyStatus.applied,
        try runtime.applyPermissionEvent(alloc, .{ .set = .{
            .key = key,
            .display_identity = "git status in /workspace",
            .decision = .deny,
            .expected_generation = null,
        } }),
    );
    var snapshot = try runtime.snapshotPermissionState(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(
        session_permission_state.StateDecision.deny,
        session_permission_state.decide(snapshot, key),
    );

    var restored: SessionRuntime = .{ .max_history_turns = 8 };
    defer restored.deinit(alloc);
    try restored.restoreWithPermissionState(
        alloc,
        ConversationLanguage.literal("en"),
        &.{},
        snapshot,
    );
    var restored_snapshot = try restored.snapshotPermissionState(alloc);
    defer restored_snapshot.deinit(alloc);
    try std.testing.expectEqual(
        session_permission_state.StateDecision.deny,
        session_permission_state.decide(restored_snapshot, key),
    );
}

test "SessionRuntime.appendHistoryMessages matches top-level projection and preserves ownership flags" {
    const alloc = std.testing.allocator;
    const history = [_]HistoryTurn{
        .{ .compacted_summary = .{
            .summary = @constCast("Conversation summary:\n- Earlier turns compacted: 2"),
            .removed_turn_count = 2,
            .compaction_count = 1,
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("question") },
            .assistant = @constCast("answer"),
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("run dev") },
            .assistant = @constCast("historical command"),
        } },
    };

    var static_messages: std.ArrayList(message.Message) = .empty;
    defer deinitMessages(alloc, &static_messages);
    var top_level_messages: std.ArrayList(message.Message) = .empty;
    defer deinitMessages(alloc, &top_level_messages);

    try SessionRuntime.appendHistoryMessages(alloc, &static_messages, &history);
    try appendHistoryMessages(alloc, &top_level_messages, &history);

    try std.testing.expectEqual(static_messages.items.len, top_level_messages.items.len);
    for (static_messages.items, top_level_messages.items) |static_msg, top_level_msg| {
        try std.testing.expectEqual(static_msg.role, top_level_msg.role);
        try std.testing.expectEqualStrings(static_msg.content.?.asText(), top_level_msg.content.?.asText());
        try std.testing.expectEqual(static_msg.owns_content, top_level_msg.owns_content);
    }

    try std.testing.expect(static_messages.items[0].owns_content);
    try std.testing.expect(!static_messages.items[1].owns_content);
    try std.testing.expect(!static_messages.items[2].owns_content);
    try std.testing.expect(!static_messages.items[3].owns_content);
}

test "SessionRuntime.appendHistoryMessages frees owned system text when append fails" {
    const compact = [_]HistoryTurn{.{ .compacted_summary = .{
        .summary = @constCast("summary"),
        .removed_turn_count = 1,
        .compaction_count = 1,
    } }};
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var messages: std.ArrayList(message.Message) = .empty;

    try std.testing.expectError(error.OutOfMemory, SessionRuntime.appendHistoryMessages(failing.allocator(), &messages, &compact));
}

test "history context formatters return exact text" {
    const alloc = std.testing.allocator;

    const compacted = try formatCompactedContinuationMessage(alloc, "summary");
    defer alloc.free(compacted);
    try std.testing.expectEqualStrings(
        "This session is being continued from earlier compacted context. The summary below covers the earlier portion of the conversation.\n\n" ++
            "summary\n\n" ++
            "Recent conversation turns are preserved verbatim.\n" ++
            "Continue the conversation from where it left off without asking the user to repeat context. Resume directly.",
        compacted,
    );
}

fn deinitMessages(alloc: Allocator, messages: *std.ArrayList(message.Message)) void {
    for (messages.items) |*msg| msg.deinit(alloc);
    messages.deinit(alloc);
}
