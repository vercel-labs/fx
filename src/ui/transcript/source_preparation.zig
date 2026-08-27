const std = @import("std");
const command_output_runtime = @import("command_output_runtime.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const transcript_release = @import("../../core/output/transcript_release.zig");
const build_checkpoint = @import("../render_engine/build_checkpoint.zig");
const tool_group_projection = @import("tool_group_projection.zig");
const render_engine = @import("../render_engine.zig");
const user_message_card = @import("../assistant/user_message_card.zig");
const ui_render = @import("../render.zig");
const types = @import("../../core/shared/types.zig");

const Allocator = std.mem.Allocator;
const transcript_blocks = render_engine.transcript_blocks;
const viewport_selection = render_engine.viewport_selection;

const FoldedCommandBlock = command_output_runtime.FoldedCommandBlock;
const TranscriptBuffer = viewport_selection.TranscriptBuffer;
const TranscriptRef = viewport_selection.TranscriptRef;
const buildHardLineStarts = viewport_selection.buildHardLineStarts;
const buildHardLineStartsInterruptible = viewport_selection.buildHardLineStartsInterruptible;
const hardLineRefAt = viewport_selection.hardLineRefAt;
const leadingWelcomeBoundary = transcript_blocks.leadingWelcomeBoundary;
const leadingWelcomeCutLine = transcript_blocks.leadingWelcomeCutLine;
const stripTrailingNewline = transcript_blocks.stripTrailingNewline;
const tailVisibleBlockKind = transcript_blocks.tailVisibleBlockKind;
const visualRowsForLine = transcript_blocks.visualRowsForLine;

test {
    _ = tool_group_projection;
}

const FinalityNominationKind = enum { mutation_pin, tool_turn, assistant_tail };

const FinalityNomination = struct {
    entry_id: u32,
    kind: FinalityNominationKind,
    turn_id: u64 = 0,
};

const ToolFinalityIdentity = struct {
    turn_id: u64,
    presentation_group_id: ?types.ToolPresentationGroupId,
};

const ToolTurnNomination = struct {
    earliest_entry_id: u32,
    selected_entry_id: u32,
    selected_group_id: ?types.ToolPresentationGroupId,
};

fn entryHiddenByActions(
    entry_actions: []const transcript_blocks.EntryRenderAction,
    index: usize,
) bool {
    if (entry_actions.len == 0) return false;
    return entry_actions[index] == .hide;
}

/// Nominate the entries whose rendered start bytes bound the final flow
/// prefix: the first entry carrying a live mutation pin, the first rendered
/// entry of each tool turn, and a trailing assistant entry. Omitted and
/// hidden entries contribute no flow bytes and are skipped.
fn collectFinalityNominations(
    self: anytype,
    alloc: Allocator,
    omitted_entry_id: ?u32,
    entry_actions: []const transcript_blocks.EntryRenderAction,
) !std.ArrayList(FinalityNomination) {
    var nominations: std.ArrayList(FinalityNomination) = .empty;
    errdefer nominations.deinit(alloc);

    var entry_tool_identities: std.AutoHashMapUnmanaged(u32, ToolFinalityIdentity) = .empty;
    defer entry_tool_identities.deinit(alloc);
    for (self.tool_details.items) |detail| {
        const identity: ToolFinalityIdentity = if (detail.presentation_group_id) |group|
            .{ .turn_id = group.turn_id, .presentation_group_id = group }
        else if (detail.lifecycle_id) |lifecycle|
            .{ .turn_id = lifecycle.turn_id, .presentation_group_id = null }
        else
            continue;
        try entry_tool_identities.put(alloc, detail.entry_id, identity);
    }

    var mutation_pin_entry_id: ?u32 = null;
    var turn_nominations: std.AutoHashMapUnmanaged(u64, ToolTurnNomination) = .empty;
    defer turn_nominations.deinit(alloc);
    for (self.entries.items, 0..) |entry, index| {
        const entry_id = entry.id();
        if (omitted_entry_id == entry_id) continue;
        if (entryHiddenByActions(entry_actions, index)) continue;
        const tool_identity = if (entry == .raw_bytes and entry.raw_bytes.class == .tool_status)
            entry_tool_identities.get(entry_id)
        else
            null;
        if (mutation_pin_entry_id == null) {
            const pinned = switch (entry) {
                .raw_bytes => |raw| raw.lifecycle_pinned and tool_identity == null,
                .semantic_notice => |notice| notice.pending_replacement,
                else => false,
            };
            if (pinned) mutation_pin_entry_id = entry_id;
        }

        if (tool_identity) |identity| {
            const result = try turn_nominations.getOrPut(alloc, identity.turn_id);
            if (!result.found_existing) {
                result.value_ptr.* = .{
                    .earliest_entry_id = entry_id,
                    .selected_entry_id = entry_id,
                    .selected_group_id = identity.presentation_group_id,
                };
                continue;
            }
            const turn = result.value_ptr;
            if (turn.selected_group_id == null) continue;
            const group_id = identity.presentation_group_id orelse {
                turn.selected_entry_id = turn.earliest_entry_id;
                turn.selected_group_id = null;
                continue;
            };
            const selected_group = turn.selected_group_id.?;
            if (group_id.anchor_step_id > selected_group.anchor_step_id) {
                turn.selected_entry_id = entry_id;
                turn.selected_group_id = group_id;
            }
        }
    }

    for (self.entries.items, 0..) |entry, index| {
        const entry_id = entry.id();
        if (omitted_entry_id == entry_id) continue;
        if (entryHiddenByActions(entry_actions, index)) continue;
        if (mutation_pin_entry_id == entry_id) {
            try nominations.append(alloc, .{
                .entry_id = entry_id,
                .kind = .mutation_pin,
            });
        }
        if (entry != .raw_bytes or entry.raw_bytes.class != .tool_status) continue;
        const identity = entry_tool_identities.get(entry_id) orelse continue;
        const turn = turn_nominations.get(identity.turn_id).?;
        if (turn.selected_entry_id != entry_id) continue;
        try nominations.append(alloc, .{
            .entry_id = entry_id,
            .kind = .tool_turn,
            .turn_id = identity.turn_id,
        });
    }
    if (self.entries.items.len > 0) {
        const tail = self.entries.items[self.entries.items.len - 1];
        if (tail == .assistant_turn and
            omitted_entry_id != tail.id() and
            !entryHiddenByActions(entry_actions, self.entries.items.len - 1))
        {
            try nominations.append(alloc, .{
                .entry_id = tail.id(),
                .kind = .assistant_tail,
            });
        }
    }
    return nominations;
}

pub const TranscriptPreparationSource = struct {
    bytes: []u8,
    folded_summary_indices: []usize,
    line_provenance: []const transcript_blocks.LineProvenance = &.{},
    preview: render_engine.frame_layout.TranscriptFlowPreview,
    tail_kind: ?transcript_blocks.TranscriptBlockKind,
    tracked_entry_id: ?u32,
    tracked_entry_start_line: ?usize,
    replaceable_last_line: bool,
    replaceable_start: usize,
    replaceable_row: u16,
    welcome_cut_line: ?usize,
    welcome_boundary: ?transcript_blocks.LeadingWelcomeBoundary,
    cols: u16,
    recorded_entries_authoritative: bool = false,
    cache_origin_untrimmed: bool = false,
    hard_line_starts: []usize = &.{},
    hard_lines_end_with_newline: bool = false,
    transcript_visible_lines: []viewport_selection.VisibleTranscriptLine = &.{},
    transcript_line_visual_rows: []u16 = &.{},
    transcript_visual_row_offsets: []u32 = &.{},
    finality: transcript_release.Candidates = .{},

    pub fn deinit(self: *TranscriptPreparationSource, alloc: Allocator) void {
        if (self.bytes.len > 0) alloc.free(self.bytes);
        if (self.folded_summary_indices.len > 0) alloc.free(self.folded_summary_indices);
        if (self.line_provenance.len > 0) alloc.free(self.line_provenance);
        if (self.hard_line_starts.len > 0) alloc.free(self.hard_line_starts);
        if (self.transcript_visible_lines.len > 0) alloc.free(self.transcript_visible_lines);
        if (self.transcript_line_visual_rows.len > 0) alloc.free(self.transcript_line_visual_rows);
        if (self.transcript_visual_row_offsets.len > 0) alloc.free(self.transcript_visual_row_offsets);
        self.finality.deinit(alloc);
        self.* = undefined;
    }

    pub fn ensureLineIndex(self: *TranscriptPreparationSource, alloc: Allocator) !void {
        return self.ensureLineIndexInterruptible(alloc, null) catch |err| switch (err) {
            error.InputPending => unreachable,
            else => |other| return other,
        };
    }

    pub fn ensureLineIndexInterruptible(
        self: *TranscriptPreparationSource,
        alloc: Allocator,
        checkpoint: ?*build_checkpoint.BuildCheckpoint,
    ) !void {
        if (self.bytes.len == 0) return build_checkpoint.poll(checkpoint);
        if (self.hard_line_starts.len > 0) return;
        const hard_lines = try buildHardLineStartsInterruptible(alloc, self.bytes, checkpoint);
        errdefer hard_lines.deinit(alloc);
        const line_visual_rows = try alloc.alloc(u16, hard_lines.len());
        errdefer alloc.free(line_visual_rows);
        const visible_lines = try alloc.alloc(viewport_selection.VisibleTranscriptLine, hard_lines.len());
        errdefer alloc.free(visible_lines);
        const visual_row_offsets = try alloc.alloc(u32, hard_lines.len() + 1);
        errdefer alloc.free(visual_row_offsets);
        visual_row_offsets[0] = 0;
        const transcript = TranscriptBuffer{ .bytes = self.bytes };
        for (line_visual_rows, visible_lines, 0..) |*rows, *line, index| {
            const ref = hardLineRefAt(hard_lines, self.bytes.len, index);
            const bytes = (TranscriptRef{ .ref = ref }).resolve(transcript);
            try build_checkpoint.consume(checkpoint, bytes.len);
            rows.* = visualRowsForLine(bytes, self.cols);
            line.* = viewport_selection.visibleFromTranscript(ref);
            visual_row_offsets[index + 1] = visual_row_offsets[index] + rows.*;
        }
        self.hard_line_starts = hard_lines.starts;
        self.hard_lines_end_with_newline = hard_lines.ends_with_newline;
        self.transcript_visible_lines = visible_lines;
        self.transcript_line_visual_rows = line_visual_rows;
        self.transcript_visual_row_offsets = visual_row_offsets;
    }

    pub fn clone(self: *const TranscriptPreparationSource, alloc: Allocator) !TranscriptPreparationSource {
        const bytes = try alloc.dupe(u8, self.bytes);
        errdefer alloc.free(bytes);
        const folded_summary_indices = try alloc.dupe(usize, self.folded_summary_indices);
        errdefer alloc.free(folded_summary_indices);
        const line_provenance = try alloc.dupe(
            transcript_blocks.LineProvenance,
            self.line_provenance,
        );
        errdefer alloc.free(line_provenance);
        const hard_line_starts = try alloc.dupe(usize, self.hard_line_starts);
        errdefer alloc.free(hard_line_starts);
        const transcript_visible_lines = try alloc.dupe(
            viewport_selection.VisibleTranscriptLine,
            self.transcript_visible_lines,
        );
        errdefer alloc.free(transcript_visible_lines);
        const transcript_line_visual_rows = try alloc.dupe(u16, self.transcript_line_visual_rows);
        errdefer alloc.free(transcript_line_visual_rows);
        const transcript_visual_row_offsets = try alloc.dupe(u32, self.transcript_visual_row_offsets);
        errdefer alloc.free(transcript_visual_row_offsets);
        var finality = try self.finality.clone(alloc);
        errdefer finality.deinit(alloc);
        return .{
            .bytes = bytes,
            .folded_summary_indices = folded_summary_indices,
            .line_provenance = line_provenance,
            .preview = self.preview,
            .tail_kind = self.tail_kind,
            .tracked_entry_id = self.tracked_entry_id,
            .tracked_entry_start_line = self.tracked_entry_start_line,
            .replaceable_last_line = self.replaceable_last_line,
            .replaceable_start = self.replaceable_start,
            .replaceable_row = self.replaceable_row,
            .welcome_cut_line = self.welcome_cut_line,
            .welcome_boundary = self.welcome_boundary,
            .cols = self.cols,
            .recorded_entries_authoritative = self.recorded_entries_authoritative,
            .cache_origin_untrimmed = self.cache_origin_untrimmed,
            .hard_line_starts = hard_line_starts,
            .hard_lines_end_with_newline = self.hard_lines_end_with_newline,
            .transcript_visible_lines = transcript_visible_lines,
            .transcript_line_visual_rows = transcript_line_visual_rows,
            .transcript_visual_row_offsets = transcript_visual_row_offsets,
            .finality = finality,
        };
    }
};

pub fn prepareTranscriptSource(
    self: anytype,
    alloc: Allocator,
    tracked_entry_id: ?u32,
) !TranscriptPreparationSource {
    return prepareTranscriptSourceInternal(self, alloc, tracked_entry_id, null, null, null) catch |err| switch (err) {
        error.InputPending => unreachable,
        else => |other| return other,
    };
}

pub fn prepareTranscriptSourceWithFocusedEntry(
    self: anytype,
    alloc: Allocator,
    focused_entry_id: u32,
) !TranscriptPreparationSource {
    return prepareTranscriptSourceInternal(self, alloc, focused_entry_id, focused_entry_id, null, null) catch |err| switch (err) {
        error.InputPending => unreachable,
        else => |other| return other,
    };
}

pub fn prepareTranscriptSourceOmittingEntry(
    self: anytype,
    alloc: Allocator,
    omitted_entry_id: u32,
) !TranscriptPreparationSource {
    return prepareTranscriptSourceInternal(self, alloc, null, null, omitted_entry_id, null) catch |err| switch (err) {
        error.InputPending => unreachable,
        else => |other| return other,
    };
}

pub fn prepareTranscriptSourceInterruptible(
    self: anytype,
    alloc: Allocator,
    tracked_entry_id: ?u32,
    focused_entry_id: ?u32,
    omitted_entry_id: ?u32,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !TranscriptPreparationSource {
    return prepareTranscriptSourceInternal(
        self,
        alloc,
        tracked_entry_id,
        focused_entry_id,
        omitted_entry_id,
        checkpoint,
    );
}

pub fn renderCompactTranscriptBytes(
    self: anytype,
    alloc: Allocator,
) ![]u8 {
    var command_overrides = try buildCommandOutputOverrides(self, alloc);
    defer command_overrides.deinit(alloc);
    const styles = self.command_output_render.styles;

    var projection = try buildCompactTranscriptProjection(
        self,
        alloc,
        &command_overrides,
        null,
    );
    defer projection.deinit(alloc);
    return transcript_blocks.renderEntriesWithProjectionToBytes(
        alloc,
        self.entries.items,
        self.layout.cols,
        styles,
        projection.entry_actions.items,
    );
}

/// Takes ownership of a bounded full-transcript visual window and prepares it
/// for the ordinary transcript surface painter. Ctrl-O uses this only after
/// the full document source has selected its current visual window.
pub fn prepareFullTranscriptViewportSource(
    self: anytype,
    alloc: Allocator,
    bytes: []u8,
) !TranscriptPreparationSource {
    return prepareFullTranscriptViewportSourceInterruptible(self, alloc, bytes, null) catch |err| switch (err) {
        error.InputPending => unreachable,
        else => |other| return other,
    };
}

pub fn prepareFullTranscriptViewportSourceInterruptible(
    self: anytype,
    alloc: Allocator,
    bytes: []u8,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !TranscriptPreparationSource {
    errdefer alloc.free(bytes);
    const line_provenance = if (observationEnabled(self, alloc))
        try unattributedLineProvenance(alloc, bytes)
    else
        &.{};
    errdefer if (line_provenance.len > 0) alloc.free(line_provenance);
    const tail_kind = tailVisibleBlockKind(self.entries.items);
    const preview = try transcriptFlowPreviewFromSourceInterruptible(
        self,
        alloc,
        bytes,
        &.{},
        0,
        false,
        tail_kind,
        checkpoint,
    );
    return .{
        .bytes = bytes,
        .folded_summary_indices = try alloc.alloc(usize, 0),
        .line_provenance = line_provenance,
        .preview = preview,
        .tail_kind = tail_kind,
        .tracked_entry_id = null,
        .tracked_entry_start_line = null,
        .replaceable_last_line = false,
        .replaceable_start = 0,
        .replaceable_row = self.replaceable_row,
        .welcome_cut_line = null,
        .welcome_boundary = null,
        .cols = self.layout.cols,
    };
}

fn prepareTranscriptSourceInternal(
    self: anytype,
    alloc: Allocator,
    tracked_entry_id: ?u32,
    focused_entry_id: ?u32,
    omitted_entry_id: ?u32,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !TranscriptPreparationSource {
    var bytes: []u8 = &.{};
    errdefer if (bytes.len > 0) alloc.free(bytes);
    var folded_summary_indices: []usize = &.{};
    errdefer if (folded_summary_indices.len > 0) alloc.free(folded_summary_indices);
    var line_provenance: []const transcript_blocks.LineProvenance = &.{};
    errdefer if (line_provenance.len > 0) alloc.free(line_provenance);
    var trailing_boundary_blank_rows: u16 = 0;
    var tracked_entry_start_line: ?usize = null;
    var replaceable_entry_start_byte: ?usize = null;
    var rendered_from_entries = false;

    var command_overrides = try buildCommandOutputOverridesInterruptible(self, alloc, checkpoint);
    defer command_overrides.deinit(alloc);
    var compact_projection: ?tool_group_projection.Projection = null;
    defer if (compact_projection) |*projection| projection.deinit(alloc);
    if (self.entries.items.len > 0 and self.layout.cols > 0) {
        compact_projection = try buildCompactTranscriptProjectionInterruptible(
            self,
            alloc,
            &command_overrides,
            focused_entry_id,
            checkpoint,
        );
    }

    const aligned_actions = if (compact_projection == null)
        try buildCommandOutputActions(
            alloc,
            &command_overrides,
            self.entries.items.len,
        )
    else
        &.{};
    defer if (aligned_actions.len > 0) alloc.free(aligned_actions);

    const entry_actions = if (compact_projection) |*projection|
        projection.entry_actions.items
    else
        aligned_actions;

    var finality: transcript_release.Candidates = .{};
    errdefer finality.deinit(alloc);
    if (self.entries.items.len > 0 and self.layout.cols > 0) {
        rendered_from_entries = true;
        const capture_provenance = observationEnabled(self, alloc) or
            self.command_output_blocks.items.len > 0;
        const replaceable_entry_id: ?u32 = if (self.replaceable_last_line and
            self.entries.items[self.entries.items.len - 1] == .raw_bytes)
            self.entries.items[self.entries.items.len - 1].raw_bytes.id
        else
            null;
        var finality_nominations = try collectFinalityNominations(
            self,
            alloc,
            omitted_entry_id,
            entry_actions,
        );
        defer finality_nominations.deinit(alloc);
        const finality_entry_ids = try alloc.alloc(u32, finality_nominations.items.len);
        defer alloc.free(finality_entry_ids);
        const finality_entry_start_bytes = try alloc.alloc(?usize, finality_nominations.items.len);
        defer alloc.free(finality_entry_start_bytes);
        for (finality_nominations.items, 0..) |nomination, index| {
            finality_entry_ids[index] = nomination.entry_id;
            finality_entry_start_bytes[index] = null;
        }
        const summary_entry_ids = try alloc.alloc(?u32, self.folded_command_blocks.items.len);
        defer alloc.free(summary_entry_ids);
        for (self.folded_command_blocks.items, 0..) |block, index| {
            summary_entry_ids[index] = block.summary_entry_id;
        }

        const rendered = try transcript_blocks.renderEntriesForPreparationInterruptible(
            alloc,
            self.entries.items,
            self.layout.cols,
            self.command_output_render.styles,
            .{
                .target_entry_id = tracked_entry_id,
                .target_byte_entry_id = replaceable_entry_id,
                .finality_entry_ids = finality_entry_ids,
                .finality_entry_start_bytes = finality_entry_start_bytes,
                .omitted_entry_id = omitted_entry_id,
                .folded_summary_entry_ids = summary_entry_ids,
                .capture_provenance = capture_provenance,
                .entry_actions = entry_actions,
            },
            checkpoint,
        );
        bytes = rendered.bytes;
        folded_summary_indices = rendered.folded_summary_indices;
        line_provenance = rendered.line_provenance;
        trailing_boundary_blank_rows = rendered.trailing_boundary_blank_rows;
        tracked_entry_start_line = rendered.target_entry_start_line;
        replaceable_entry_start_byte = rendered.target_entry_start_byte;
        var tool_turn_floors: std.ArrayList(transcript_release.ToolTurnFloor) = .empty;
        errdefer tool_turn_floors.deinit(alloc);
        for (finality_nominations.items, 0..) |nomination, index| {
            const start_byte = finality_entry_start_bytes[index] orelse blk: {
                // A nominated entry that produced no bytes cannot anchor the
                // boundary; hold the whole flow rather than release past it.
                debug_trace.logf(
                    "scroll",
                    "finality_nomination_unrecorded entry_id={d} kind={s}",
                    .{ nomination.entry_id, @tagName(nomination.kind) },
                );
                break :blk 0;
            };
            switch (nomination.kind) {
                .mutation_pin => finality.mutation_pin_start = start_byte,
                .assistant_tail => finality.assistant_tail_start = start_byte,
                .tool_turn => try tool_turn_floors.append(alloc, .{
                    .turn_id = nomination.turn_id,
                    .start_byte = start_byte,
                }),
            }
        }
        finality.tool_turn_floors = try tool_turn_floors.toOwnedSlice(alloc);
    } else {
        bytes = try alloc.dupe(u8, self.transcript.items);
        folded_summary_indices = try alloc.alloc(usize, self.folded_command_blocks.items.len);
        for (self.folded_command_blocks.items, 0..) |block, index| {
            folded_summary_indices[index] = block.summary_transcript_index;
        }
        if (observationEnabled(self, alloc)) {
            line_provenance = try unattributedLineProvenance(alloc, bytes);
        }
    }

    var replaceable_last_line = self.replaceable_last_line;
    var replaceable_start = self.replaceable_start;
    if (replaceable_last_line and self.entries.items.len > 0) {
        const tail = &self.entries.items[self.entries.items.len - 1];
        switch (tail.*) {
            .raw_bytes => {
                if (replaceable_entry_start_byte) |start| {
                    replaceable_start = start;
                } else {
                    replaceable_last_line = false;
                    replaceable_start = 0;
                }
            },
            else => {
                replaceable_last_line = false;
                replaceable_start = 0;
            },
        }
    }

    const tail_start = if (rendered_from_entries)
        0
    else
        cappedTailStart(bytes, self.max_transcript_bytes);
    const cache_origin_untrimmed = tail_start == 0 and omitted_entry_id == null and
        (rendered_from_entries or self.transcript_cache_origin_untrimmed);
    const retained_len = bytes.len - tail_start;
    const removed_line_count = std.mem.count(u8, bytes[0..tail_start], "\n");
    const retained_origin_is_line_start =
        tail_start == 0 or bytes[tail_start - 1] == '\n';
    for (folded_summary_indices) |*summary_index| {
        if (summary_index.* == 0) continue;
        summary_index.* = if (rebaseLineIndexForCappedTail(
            summary_index.* - 1,
            retained_len,
            removed_line_count,
            retained_origin_is_line_start,
        )) |line_index|
            line_index + 1
        else
            0;
    }
    if (tracked_entry_start_line) |line_index| {
        tracked_entry_start_line = rebaseLineIndexForCappedTail(
            line_index,
            retained_len,
            removed_line_count,
            retained_origin_is_line_start,
        );
    }
    if (replaceable_last_line) {
        if (retained_len == 0 or replaceable_start >= bytes.len) {
            replaceable_last_line = false;
            replaceable_start = 0;
        } else if (replaceable_start > tail_start) {
            replaceable_start -= tail_start;
        } else {
            replaceable_start = 0;
        }
    }
    if (tail_start > 0) {
        const capped = try alloc.dupe(u8, bytes[tail_start..]);
        if (line_provenance.len > 0) {
            const rebased = try rebaseLineProvenanceForCappedTail(
                alloc,
                line_provenance,
                capped,
                removed_line_count,
                retained_origin_is_line_start,
            );
            alloc.free(line_provenance);
            line_provenance = rebased;
        }
        alloc.free(bytes);
        bytes = capped;
    }

    const tail_kind = transcript_blocks.compactTailVisibleBlockKindForProjection(
        self.entries.items,
        omitted_entry_id,
        entry_actions,
    );
    const preview = try transcriptFlowPreviewFromSourceInterruptible(
        self,
        alloc,
        bytes,
        folded_summary_indices,
        trailing_boundary_blank_rows,
        replaceable_last_line,
        tail_kind,
        checkpoint,
    );
    const welcome_boundary = if (tail_start == 0)
        try leadingWelcomeBoundary(
            alloc,
            self.entries.items,
            self.layout.cols,
            self.command_output_render.styles,
        )
    else
        null;
    const welcome_cut_line = if (tail_start > 0 or frameCommitted(self))
        null
    else
        try leadingWelcomeCutLine(
            alloc,
            self.entries.items,
            self.layout.cols,
            self.command_output_render.styles,
        );

    return .{
        .bytes = bytes,
        .folded_summary_indices = folded_summary_indices,
        .line_provenance = line_provenance,
        .preview = preview,
        .tail_kind = tail_kind,
        .tracked_entry_id = tracked_entry_id,
        .tracked_entry_start_line = tracked_entry_start_line,
        .replaceable_last_line = replaceable_last_line,
        .replaceable_start = replaceable_start,
        .replaceable_row = self.replaceable_row,
        .welcome_cut_line = welcome_cut_line,
        .welcome_boundary = welcome_boundary,
        .cols = self.layout.cols,
        .recorded_entries_authoritative = rendered_from_entries,
        .cache_origin_untrimmed = cache_origin_untrimmed,
        .finality = finality,
    };
}

const CommandOutputOverrides = struct {
    items: std.ArrayList(CommandOutputOverride) = .empty,
    owned_bytes: std.ArrayList([]u8) = .empty,
    entry_indices: std.AutoHashMapUnmanaged(u32, usize) = .empty,

    fn deinit(self: *CommandOutputOverrides, alloc: Allocator) void {
        for (self.owned_bytes.items) |bytes| alloc.free(bytes);
        self.owned_bytes.deinit(alloc);
        self.items.deinit(alloc);
        self.entry_indices.deinit(alloc);
        self.* = undefined;
    }
};

const CommandOutputOverride = struct {
    entry_id: u32,
    kind: transcript_blocks.TranscriptBlockKind,
    bytes: []const u8,
};

fn buildCommandOutputActions(
    alloc: Allocator,
    command_overrides: *const CommandOutputOverrides,
    entry_count: usize,
) ![]transcript_blocks.EntryRenderAction {
    if (command_overrides.items.items.len == 0) return &.{};
    const entry_actions = try alloc.alloc(
        transcript_blocks.EntryRenderAction,
        entry_count,
    );
    @memset(entry_actions, .keep);
    applyCommandOutputOverrides(entry_actions, command_overrides);
    return entry_actions;
}

fn buildCompactTranscriptProjection(
    self: anytype,
    alloc: Allocator,
    command_overrides: *const CommandOutputOverrides,
    focused_entry_id: ?u32,
) !tool_group_projection.Projection {
    return buildCompactTranscriptProjectionInterruptible(
        self,
        alloc,
        command_overrides,
        focused_entry_id,
        null,
    ) catch |err| switch (err) {
        error.InputPending => unreachable,
        else => |other| return other,
    };
}

fn buildCompactTranscriptProjectionInterruptible(
    self: anytype,
    alloc: Allocator,
    command_overrides: *const CommandOutputOverrides,
    focused_entry_id: ?u32,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !tool_group_projection.Projection {
    var projection = try tool_group_projection.buildStyledFocusedInterruptible(
        alloc,
        self.entries.items,
        self.tool_details.items,
        self.layout.cols,
        focused_entry_id,
        .{
            .marker_style = user_message_card.promptMarkerStyle(),
            .text_style = ui_render.statusline_style,
            .reset_style = "\x1b[0m",
        },
        self.command_output_render.styles,
        checkpoint,
    );
    errdefer projection.deinit(alloc);

    applyCommandOutputOverrides(
        projection.entry_actions.items,
        command_overrides,
    );
    return projection;
}

fn applyCommandOutputOverrides(
    entry_actions: []transcript_blocks.EntryRenderAction,
    command_overrides: *const CommandOutputOverrides,
) void {
    for (command_overrides.items.items) |override| {
        const index = command_overrides.entry_indices.get(override.entry_id) orelse continue;
        if (entry_actions[index] != .keep) continue;
        entry_actions[index] = .{ .override = .{
            .kind = override.kind,
            .bytes = override.bytes,
        } };
    }
}

fn buildCommandOutputOverrides(
    self: anytype,
    alloc: Allocator,
) !CommandOutputOverrides {
    return buildCommandOutputOverridesInterruptible(self, alloc, null) catch |err| switch (err) {
        error.InputPending => unreachable,
        else => |other| return other,
    };
}

fn buildCommandOutputOverridesInterruptible(
    self: anytype,
    alloc: Allocator,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !CommandOutputOverrides {
    var overrides: CommandOutputOverrides = .{};
    errdefer overrides.deinit(alloc);
    if (self.layout.cols == 0) return overrides;

    if (self.tool_details.items.len > 0 or self.command_output_blocks.items.len > 0) {
        for (self.entries.items, 0..) |entry, index| {
            try build_checkpoint.tick(checkpoint);
            const result = try overrides.entry_indices.getOrPut(alloc, entry.id());
            if (!result.found_existing) result.value_ptr.* = index;
        }
    }

    for (self.tool_details.items) |detail| {
        try build_checkpoint.tick(checkpoint);
        if (!detail.isCapturedCommand()) continue;
        const entry_index = overrides.entry_indices.get(detail.entry_id) orelse continue;
        const entry = self.entries.items[entry_index];
        const raw = switch (entry) {
            .raw_bytes => |raw| raw,
            else => continue,
        };
        if (raw.class != .tool_status) continue;
        const bytes = try transcript_blocks.formatCompactCommandStatus(
            alloc,
            raw.bytes,
            self.layout.cols,
        );
        var bytes_owned = true;
        errdefer if (bytes_owned) alloc.free(bytes);
        try overrides.owned_bytes.append(alloc, bytes);
        bytes_owned = false;
        try overrides.items.append(alloc, .{
            .entry_id = detail.entry_id,
            .kind = .tool_status,
            .bytes = bytes,
        });
    }

    for (self.command_output_blocks.items) |block| {
        try build_checkpoint.poll(checkpoint);
        var projection = try command_output_runtime.renderCompactCommandOutputWithProcessPresentation(
            alloc,
            block,
            self.command_output_render,
            self.layout.cols,
            command_output_runtime.processPresentationForBlock(self, block),
        );
        defer projection.deinit(alloc);
        for (projection.entries.items) |entry| {
            const bytes = try alloc.dupe(
                u8,
                projection.bytes.items[entry.byte_start..entry.byte_end],
            );
            var bytes_owned = true;
            errdefer if (bytes_owned) alloc.free(bytes);
            try overrides.owned_bytes.append(alloc, bytes);
            bytes_owned = false;
            try overrides.items.append(alloc, .{
                .entry_id = entry.entry_id,
                .kind = .command_output,
                .bytes = bytes,
            });
        }
    }
    return overrides;
}

fn observationEnabled(self: anytype, alloc: Allocator) bool {
    const Shell = @TypeOf(self.*);
    if (comptime @hasField(Shell, "ui_observer")) {
        return self.ui_observer.enabled(alloc);
    }
    return false;
}

fn unattributedLineProvenance(
    alloc: Allocator,
    bytes: []const u8,
) ![]transcript_blocks.LineProvenance {
    const line_count = try sourceLineCount(alloc, bytes);
    if (line_count == 0) return &.{};
    const provenance = try alloc.alloc(transcript_blocks.LineProvenance, line_count);
    @memset(provenance, .unattributed);
    return provenance;
}

fn rebaseLineProvenanceForCappedTail(
    alloc: Allocator,
    source: []const transcript_blocks.LineProvenance,
    retained_bytes: []const u8,
    removed_line_count: usize,
    retained_origin_is_line_start: bool,
) ![]transcript_blocks.LineProvenance {
    const retained_line_count = try sourceLineCount(alloc, retained_bytes);
    if (retained_line_count == 0) return &.{};

    const rebased = try alloc.alloc(transcript_blocks.LineProvenance, retained_line_count);
    var source_index = removed_line_count;
    var target_index: usize = 0;
    if (!retained_origin_is_line_start) {
        rebased[0] = .capped_continuation;
        target_index = 1;
        source_index += 1;
    }
    while (target_index < rebased.len) : (target_index += 1) {
        rebased[target_index] = if (source_index < source.len)
            source[source_index]
        else
            .unattributed;
        source_index += 1;
    }
    return rebased;
}

fn sourceLineCount(alloc: Allocator, bytes: []const u8) !usize {
    if (bytes.len == 0) return 0;
    const hard_lines = try buildHardLineStarts(alloc, bytes);
    defer hard_lines.deinit(alloc);
    return hard_lines.len();
}

fn transcriptFlowPreviewFromSourceInterruptible(
    self: anytype,
    alloc: Allocator,
    bytes: []const u8,
    folded_summary_indices: []const usize,
    trailing_boundary_blank_rows: u16,
    replaceable_last_line: bool,
    tail_kind: ?transcript_blocks.TranscriptBlockKind,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !render_engine.frame_layout.TranscriptFlowPreview {
    var natural_rows: u32 = 0;
    if (bytes.len > 0) {
        const transcript_buf = TranscriptBuffer{ .bytes = bytes };
        const hard_lines = try buildHardLineStartsInterruptible(alloc, transcript_buf.bytes, checkpoint);
        defer hard_lines.deinit(alloc);

        var transcript_index: usize = 0;
        while (transcript_index < hard_lines.len()) : (transcript_index += 1) {
            if (foldedBlockAtTranscriptLine(self, folded_summary_indices, transcript_index)) |block| {
                const effective_cols: u16 = if (self.layout.cols > 2) self.layout.cols - 2 else self.layout.cols;
                for (block.lines.items) |line| {
                    try build_checkpoint.consume(checkpoint, line.text.len);
                    natural_rows += visualRowsForLine(stripTrailingNewline(line.text), effective_cols);
                }
                continue;
            }

            const ref = hardLineRefAt(hard_lines, transcript_buf.bytes.len, transcript_index);
            const transcript_ref = TranscriptRef{ .ref = ref };
            const line = transcript_ref.resolve(transcript_buf);
            try build_checkpoint.consume(checkpoint, line.len);
            natural_rows += visualRowsForLine(line, self.layout.cols);
        }
    }

    return .{
        .natural_visual_rows = @intCast(@min(natural_rows, std.math.maxInt(u16))),
        .trailing_boundary_blank_rows = if (bytes.len > 0)
            trailing_boundary_blank_rows
        else
            0,
        .footer_boundary_gap_rows = transcript_blocks.footerBoundaryGapRowsForTail(if (bytes.len > 0) tail_kind else null),
        .cursor_row = self.cursor_row,
        .cursor_col = self.cursor_col,
        .replaceable_row = self.replaceable_row,
        .tail_kind = if (bytes.len > 0) tail_kind else null,
        .replaceable_active = replaceable_last_line,
    };
}

fn rebaseLineIndexForCappedTail(
    line_index: usize,
    retained_len: usize,
    removed_line_count: usize,
    retained_origin_is_line_start: bool,
) ?usize {
    if (retained_len == 0 or line_index < removed_line_count) return null;
    if (line_index == removed_line_count and !retained_origin_is_line_start) {
        return null;
    }
    return line_index - removed_line_count;
}

pub fn foldedBlockAtTranscriptLine(
    self: anytype,
    folded_summary_indices: []const usize,
    transcript_index: usize,
) ?*const FoldedCommandBlock {
    if (!self.fullTranscriptActive()) return null;
    for (self.folded_command_blocks.items, 0..) |*block, index| {
        if (index < folded_summary_indices.len and
            folded_summary_indices[index] == transcript_index + 1)
        {
            return block;
        }
    }
    return null;
}

pub fn visibleTranscriptLineCountFromSource(
    self: anytype,
    transcript_total: usize,
    folded_summary_indices: []const usize,
) usize {
    var total = transcript_total;
    if (!self.fullTranscriptActive()) return total;
    for (self.folded_command_blocks.items, 0..) |block, index| {
        if (index >= folded_summary_indices.len) continue;
        const summary_index = folded_summary_indices[index];
        if (summary_index == 0 or summary_index > transcript_total) continue;
        total -= 1;
        total += block.lines.items.len;
    }
    return total;
}

fn cappedTailStart(bytes: []const u8, limit: usize) usize {
    if (limit == 0) return bytes.len;
    if (bytes.len <= limit) return 0;

    const raw_cut = bytes.len - limit;
    var probe = raw_cut;
    while (probe < bytes.len) : (probe += 1) {
        if (bytes[probe] == '\n') return probe + 1;
    }
    return raw_cut;
}

fn frameCommitted(self: anytype) bool {
    const Shell = @TypeOf(self.*);
    if (comptime @hasField(Shell, "has_committed_frame")) {
        return self.has_committed_frame;
    }
    return false;
}

test "command output override preserves a hidden projection entry" {
    const alloc = std.testing.allocator;
    var overrides: CommandOutputOverrides = .{};
    defer overrides.deinit(alloc);
    try overrides.items.append(alloc, .{
        .entry_id = 7,
        .kind = .command_output,
        .bytes = "replacement\n",
    });
    try overrides.entry_indices.put(alloc, 7, 0);

    var actions = [_]transcript_blocks.EntryRenderAction{.hide};
    applyCommandOutputOverrides(&actions, &overrides);
    try std.testing.expect(actions[0] == .hide);
}

test "minimal projection does not take ownership of command output overrides" {
    const alloc = std.testing.allocator;
    const TestSource = struct {
        entries: std.ArrayList(transcript_blocks.TranscriptEntry) = .empty,
        tool_details: std.ArrayList(transcript_blocks.ToolDetailRecord) = .empty,
        command_output_blocks: std.ArrayList(command_output_runtime.CommandOutputBlock) = .empty,
        command_output_display: transcript_blocks.CommandOutputDisplayState = .{},
        layout: struct { cols: u16 = 80 } = .{},
        command_output_render: command_output_runtime.CommandOutputRenderPolicy = .{},

        fn deinit(self: *@This(), allocator: Allocator) void {
            for (self.command_output_blocks.items) |*block| block.deinit(allocator);
            self.command_output_blocks.deinit(allocator);
            self.tool_details.deinit(allocator);
            self.entries.deinit(allocator);
        }

        fn fullTranscriptActive(_: *const @This()) bool {
            return false;
        }
    };

    var source: TestSource = .{};
    defer source.deinit(alloc);
    try source.entries.append(alloc, .{ .raw_bytes = .{
        .id = 1,
        .bytes = @constCast("original\n"),
    } });
    var block = command_output_runtime.CommandOutputBlock{ .entry_id = 1 };
    errdefer block.deinit(alloc);
    try block.lines.append(alloc, .{
        .stream = .stdout,
        .text = try alloc.dupe(u8, "replacement\n"),
        .entry_id = 1,
        .terminated = true,
    });
    block.total_lines = 1;
    block.retained_text_bytes = "replacement\n".len;
    try source.command_output_blocks.append(alloc, block);

    const bytes = try renderCompactTranscriptBytes(&source, alloc);
    defer alloc.free(bytes);
    try std.testing.expect(std.mem.find(u8, bytes, "replacement") != null);
}
