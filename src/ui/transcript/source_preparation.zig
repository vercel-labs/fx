const std = @import("std");
const command_output_runtime = @import("command_output_runtime.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const sort_utils = @import("../../core/shared/sort_utils.zig");
const transcript_release = @import("../../core/output/transcript_release.zig");
const build_checkpoint = @import("../render_engine/build_checkpoint.zig");
const assistant_wrap = @import("../render_engine/assistant_wrap.zig");
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
    terminal: bool,
};

const ToolTurnNomination = struct {
    earliest_entry_id: u32,
    selected_entry_id: u32,
    selected_group_id: ?types.ToolPresentationGroupId,
    selected_group_terminal: bool,
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
/// entry of each live tool turn, and a trailing assistant entry. Omitted and
/// hidden entries contribute no flow bytes and are skipped.
fn collectFinalityNominations(
    self: anytype,
    alloc: Allocator,
    omitted_entry_id: ?u32,
    entry_actions: []const transcript_blocks.EntryRenderAction,
) !std.ArrayList(FinalityNomination) {
    var nominations: std.ArrayList(FinalityNomination) = .empty;
    errdefer nominations.deinit(alloc);

    const assistant_tail_entry_id: ?u32 = if (self.entries.items.len > 0) tail: {
        const tail_index = self.entries.items.len - 1;
        const tail_entry = self.entries.items[tail_index];
        if (tail_entry != .assistant_turn or
            omitted_entry_id == tail_entry.id() or
            entryHiddenByActions(entry_actions, tail_index))
        {
            break :tail null;
        }
        break :tail tail_entry.id();
    } else null;

    var group_terminality: std.AutoHashMapUnmanaged(types.ToolPresentationGroupId, bool) = .empty;
    defer group_terminality.deinit(alloc);
    for (self.tool_details.items) |detail| {
        if (detail.origin == .recorded) continue;
        const group = detail.presentation_group_id orelse continue;
        const result = try group_terminality.getOrPut(alloc, group);
        if (!result.found_existing) result.value_ptr.* = true;
        result.value_ptr.* = result.value_ptr.* and detail.outcome != null;
    }

    var entry_tool_identities: std.AutoHashMapUnmanaged(u32, ToolFinalityIdentity) = .empty;
    defer entry_tool_identities.deinit(alloc);
    for (self.tool_details.items) |detail| {
        if (detail.origin == .recorded) continue;
        const identity: ToolFinalityIdentity = if (detail.presentation_group_id) |group|
            .{
                .turn_id = group.turn_id,
                .presentation_group_id = group,
                .terminal = group_terminality.get(group).?,
            }
        else if (detail.lifecycle_id) |lifecycle|
            .{
                .turn_id = lifecycle.turn_id,
                .presentation_group_id = null,
                .terminal = detail.outcome != null,
            }
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
                    .selected_group_terminal = identity.presentation_group_id != null and
                        identity.terminal,
                };
                continue;
            }
            const turn = result.value_ptr;
            if (turn.selected_group_id == null) continue;
            const group_id = identity.presentation_group_id orelse {
                turn.selected_entry_id = turn.earliest_entry_id;
                turn.selected_group_id = null;
                turn.selected_group_terminal = false;
                continue;
            };
            const selected_group = turn.selected_group_id.?;
            if (group_id.anchor_step_id == selected_group.anchor_step_id) {
                continue;
            }
            if (group_id.anchor_step_id > selected_group.anchor_step_id) {
                turn.selected_entry_id = entry_id;
                turn.selected_group_id = group_id;
                turn.selected_group_terminal = identity.terminal;
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
        // A later assistant entry closes a concrete group once all of its
        // tools are terminal. Any subsequent tool start after visible text
        // receives a new presentation-group identity.
        if (assistant_tail_entry_id != null and
            turn.selected_group_id != null and
            turn.selected_group_terminal)
        {
            continue;
        }
        try nominations.append(alloc, .{
            .entry_id = entry_id,
            .kind = .tool_turn,
            .turn_id = identity.turn_id,
        });
    }
    if (assistant_tail_entry_id) |entry_id| {
        try nominations.append(alloc, .{
            .entry_id = entry_id,
            .kind = .assistant_tail,
        });
    }
    return nominations;
}

/// Coordinates for the one committed/attempted source, not another text history.
/// Text remains owned by the recorded entries and the existing committed flow.
pub const RetentionIdentity = struct {
    pub const TextExtent = struct { entry_id: u32, bytes: usize };
    lines: []const transcript_blocks.LineProvenance = &.{},
    text_extents: []TextExtent = &.{},
    publication_entries: []u32 = &.{},
    publication_release_floor: u32 = 0,

    pub fn deinit(self: *RetentionIdentity, alloc: Allocator) void {
        alloc.free(self.lines);
        alloc.free(self.text_extents);
        alloc.free(self.publication_entries);
        self.* = .{};
    }

    pub fn clone(self: RetentionIdentity, alloc: Allocator) !RetentionIdentity {
        const lines = try alloc.dupe(transcript_blocks.LineProvenance, self.lines);
        errdefer alloc.free(lines);
        const text_extents = try alloc.dupe(TextExtent, self.text_extents);
        errdefer alloc.free(text_extents);
        return .{ .lines = lines, .text_extents = text_extents, .publication_entries = try alloc.dupe(u32, self.publication_entries), .publication_release_floor = self.publication_release_floor };
    }

    /// Restricts the receipt to the source prefix materialized by a held frame.
    /// Unpainted entries, including later bytes in the last entry, stay producer-owned.
    pub fn retainPrefix(identity: *RetentionIdentity, alloc: Allocator, entries: []const transcript_blocks.TranscriptEntry, prefix: []const u8, cols: u16) !u32 {
        const hard_lines = try buildHardLineStarts(alloc, prefix);
        defer hard_lines.deinit(alloc);
        const line_count = @min(identity.lines.len, hard_lines.len());
        const Span = struct { start: usize, end: usize, publication_end: u32 };
        var spans: std.AutoHashMapUnmanaged(u32, Span) = .empty;
        defer spans.deinit(alloc);
        var visual_rows: u32 = 0;
        var owner: ?u32 = null;
        for (0..hard_lines.len()) |index| {
            const ref = hardLineRefAt(hard_lines, prefix.len, index);
            visual_rows += visualRowsForLine((TranscriptRef{ .ref = ref }).resolve(.{ .bytes = prefix }), cols);
            if (index >= line_count) continue;
            owner = publication_owner(owner, identity.lines[index]);
            if (identity.lines[index] == .entry) {
                const span = try spans.getOrPut(alloc, identity.lines[index].entry.entry_id);
                const end = if (index + 1 < hard_lines.starts.len) hard_lines.starts[index + 1] else prefix.len;
                if (!span.found_existing) span.value_ptr.* = .{ .start = hard_lines.starts[index], .end = end, .publication_end = visual_rows } else span.value_ptr.end = end;
            }
            if (owner) |id| if (spans.getPtr(id)) |span| {
                span.publication_end = visual_rows;
            };
        }
        var extents: std.ArrayList(TextExtent) = .empty;
        defer extents.deinit(alloc);
        for (entries) |entry| {
            const span = spans.get(entry.id()) orelse continue;
            var bytes = switch (entry) {
                .assistant_turn => |value| value.segments.text.items.len,
                .raw_bytes => |value| value.bytes.len,
                else => continue,
            };
            if (span.end == prefix.len) {
                if (entry == .assistant_turn) {
                    var map = try assistant_wrap.retentionSourceMap(alloc, entry.assistant_turn.segments.text.items, cols);
                    defer map.deinit(alloc);
                    bytes = @min(bytes, map.sourceAt(span.end - span.start));
                } else if (entry.raw_bytes.class != .tool_status) {
                    bytes = @min(bytes, span.end - span.start);
                }
            }
            try extents.append(alloc, .{ .entry_id = entry.id(), .bytes = bytes });
        }
        const lines = try alloc.dupe(transcript_blocks.LineProvenance, identity.lines[0..line_count]);
        errdefer alloc.free(lines);
        const text_extents = try extents.toOwnedSlice(alloc);
        alloc.free(identity.lines);
        alloc.free(identity.text_extents);
        identity.lines = lines;
        identity.text_extents = text_extents;
        var release_floor: u32 = if (identity.publication_entries.len > 0) std.math.maxInt(u32) else 0;
        for (identity.publication_entries) |id| {
            release_floor = @min(release_floor, if (spans.get(id)) |span| span.publication_end else 0);
        }
        identity.publication_release_floor = release_floor;
        return visual_rows;
    }

    pub fn capture(self: anytype, alloc: Allocator, source: *const TranscriptPreparationSource) !RetentionIdentity {
        var extents: std.ArrayList(TextExtent) = .empty;
        errdefer extents.deinit(alloc);
        for (self.entries.items) |entry| {
            const bytes = switch (entry) {
                .assistant_turn => |value| value.segments.text.items.len,
                .raw_bytes => |value| value.bytes.len,
                else => continue,
            };
            try extents.append(alloc, .{ .entry_id = entry.id(), .bytes = bytes });
        }
        const lines = try alloc.dupe(transcript_blocks.LineProvenance, source.line_provenance);
        errdefer alloc.free(lines);
        const publication_entries = try alloc.dupe(u32, source.publication_entries);
        errdefer alloc.free(publication_entries);
        const release_floor = try publicationReleaseFloor(alloc, source);
        return .{ .lines = lines, .text_extents = try extents.toOwnedSlice(alloc), .publication_entries = publication_entries, .publication_release_floor = release_floor };
    }
};

pub const TranscriptPreparationSource = struct {
    bytes: []u8,
    folded_summary_indices: []usize,
    line_provenance: []const transcript_blocks.LineProvenance = &.{},
    publication_entries: []u32 = &.{},
    publication_owned_end: usize = 0,
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
        alloc.free(self.publication_entries);
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

    pub fn byteAtVisualOffset(self: *const TranscriptPreparationSource, offset: u32) usize {
        var line: usize = 0;
        while (line < self.hard_line_starts.len) : (line += 1) {
            if (self.transcript_visual_row_offsets[line + 1] <= offset) continue;
            const start = self.hard_line_starts[line];
            const end = if (line + 1 < self.hard_line_starts.len) self.hard_line_starts[line + 1] else self.bytes.len;
            return start + transcript_blocks.skipVisualRowsInLine(self.bytes[start..end], self.cols, @intCast(offset - self.transcript_visual_row_offsets[line]));
        }
        return self.bytes.len;
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
        const publication_entries = try alloc.dupe(u32, self.publication_entries);
        errdefer alloc.free(publication_entries);
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
            .publication_entries = publication_entries,
            .publication_owned_end = self.publication_owned_end,
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

/// Retention needs entry identity even when diagnostic observation is disabled.
pub fn prepareRetentionSource(self: anytype, alloc: Allocator) !TranscriptPreparationSource {
    var source = try prepareTranscriptSourceInternal(self, alloc, null, null, null, null);
    errdefer source.deinit(alloc);
    try source.ensureLineIndex(alloc);
    return source;
}

/// Entry projections own their following separators and boundary blanks;
/// other provenance ends publication ownership. Folded command output's optional
/// entry ID identifies its summary, not a retained conversation projection.
pub fn publication_owner(previous: ?u32, line: transcript_blocks.LineProvenance) ?u32 {
    return switch (line) {
        .entry => |entry| entry.entry_id,
        .block_separator, .boundary_blank => previous,
        .unattributed, .capped_continuation, .folded_command_output, .empty_transcript => null,
    };
}

fn publicationReleaseFloor(alloc: Allocator, source: *const TranscriptPreparationSource) !u32 {
    if (source.publication_entries.len == 0 or source.transcript_visual_row_offsets.len == 0) return 0;
    var ends: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer ends.deinit(alloc);
    for (source.publication_entries) |id| try ends.put(alloc, id, 0);
    var owner: ?u32 = null;
    for (source.line_provenance, 0..) |line, index| {
        owner = publication_owner(owner, line);
        if (owner) |id| {
            if (ends.getPtr(id)) |end| end.* = source.transcript_visual_row_offsets[index + 1];
        }
    }
    var floor: u32 = std.math.maxInt(u32);
    var values = ends.valueIterator();
    while (values.next()) |value| floor = @min(floor, value.*);
    return floor;
}

const PublicationRange = struct { start: usize, end: usize };

fn publicationGapStart(source: *const TranscriptPreparationSource, at: usize) usize {
    var start = at;
    while (start > 0 and (source.line_provenance[start - 1] == .block_separator or source.line_provenance[start - 1] == .boundary_blank)) start -= 1;
    return start;
}

fn publicationRanges(alloc: Allocator, source: *const TranscriptPreparationSource) !std.AutoHashMapUnmanaged(u32, PublicationRange) {
    var ranges: std.AutoHashMapUnmanaged(u32, PublicationRange) = .empty;
    errdefer ranges.deinit(alloc);
    for (source.line_provenance, 0..) |line, index| {
        if (line != .entry) continue;
        const item = try ranges.getOrPut(alloc, line.entry.entry_id);
        if (!item.found_existing) item.value_ptr.* = .{ .start = index, .end = index + 1 } else item.value_ptr.end = index + 1;
    }
    var values = ranges.valueIterator();
    while (values.next()) |range| {
        while (range.end < source.line_provenance.len and (source.line_provenance[range.end] == .block_separator or source.line_provenance[range.end] == .boundary_blank)) range.end += 1;
    }
    return ranges;
}

fn sourceLineByte(source: *const TranscriptPreparationSource, line: usize) usize {
    return if (line < source.hard_line_starts.len) source.hard_line_starts[line] else source.bytes.len;
}

fn remapPublicationByte(source: *const TranscriptPreparationSource, positions: []const usize, byte: usize) usize {
    if (byte >= source.bytes.len) return positions[positions.len - 1];
    var line: usize = 0;
    for (source.hard_line_starts, 0..) |start, index| {
        if (start > byte) break;
        line = index;
    }
    return positions[line] + byte - source.hard_line_starts[line];
}

fn publicationLineAt(source: *const TranscriptPreparationSource, byte: usize) usize {
    if (byte >= source.bytes.len) return source.hard_line_starts.len;
    var line: usize = 0;
    for (source.hard_line_starts, 0..) |start, index| {
        if (start > byte) break;
        line = index;
    }
    return line;
}

/// Keeps only projections already owned by the committed flow. The recorded
/// store remains capped; successful frame receipts own their eventual release.
pub fn preservePublicationEntries(
    alloc: Allocator,
    before: *const TranscriptPreparationSource,
    next: *TranscriptPreparationSource,
    entry_ids: []const u32,
    publication_limit: ?usize,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !void {
    try build_checkpoint.poll(checkpoint);
    if (entry_ids.len == 0) return;
    try next.ensureLineIndexInterruptible(alloc, checkpoint);
    var old_ranges = try publicationRanges(alloc, before);
    defer old_ranges.deinit(alloc);
    var next_ranges = try publicationRanges(alloc, next);
    defer next_ranges.deinit(alloc);
    const Edit = struct {
        at: usize,
        end: usize,
        old: PublicationRange,
        old_end_byte: usize,
        following_new_entry: bool = false,
        fn less(_: void, a: @This(), b: @This()) bool {
            return a.at < b.at or (a.at == b.at and a.old.start < b.old.start);
        }
    };
    var edits: std.ArrayList(Edit) = .empty;
    defer edits.deinit(alloc);
    const following_positions = try alloc.alloc(usize, before.line_provenance.len + 1);
    defer alloc.free(following_positions);
    var first_new = next.hard_line_starts.len;
    for (next.line_provenance, 0..) |line, index| {
        if (line == .entry and !old_ranges.contains(line.entry.entry_id)) {
            first_new = index;
            break;
        }
    }
    following_positions[before.line_provenance.len] = first_new;
    var reverse = before.line_provenance.len;
    while (reverse > 0) {
        reverse -= 1;
        try build_checkpoint.tick(checkpoint);
        var at = following_positions[reverse + 1];
        if (before.line_provenance[reverse] == .entry) {
            if (next_ranges.get(before.line_provenance[reverse].entry.entry_id)) |range| at = @min(at, range.start);
        }
        following_positions[reverse] = at;
    }
    for (entry_ids) |id| {
        try build_checkpoint.tick(checkpoint);
        var old = old_ranges.get(id) orelse continue;
        var old_end_byte = sourceLineByte(before, old.end);
        if (publication_limit) |limit| {
            if (std.mem.findScalar(u32, before.publication_entries, id) == null and old_end_byte > limit) {
                if (sourceLineByte(before, old.start) >= limit) continue;
                old_end_byte = limit;
                const end_line = publicationLineAt(before, limit);
                old.end = end_line + @intFromBool(sourceLineByte(before, end_line) < limit);
            }
        }
        old.start = publicationGapStart(before, old.start);
        if (next_ranges.get(id)) |range| {
            try edits.append(alloc, .{ .at = publicationGapStart(next, range.start), .end = range.end, .old = old, .old_end_byte = old_end_byte });
            continue;
        }
        const at = following_positions[old.end];
        try edits.append(alloc, .{ .at = publicationGapStart(next, at), .end = at, .old = old, .old_end_byte = old_end_byte, .following_new_entry = at == first_new and at < next.hard_line_starts.len });
    }
    if (edits.items.len == 0) return;
    sort_utils.sort(Edit, edits.items, {}, Edit.less);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(alloc);
    var provenance: std.ArrayList(transcript_blocks.LineProvenance) = .empty;
    defer provenance.deinit(alloc);
    const positions = try alloc.alloc(usize, next.hard_line_starts.len + 1);
    defer alloc.free(positions);
    var cursor: usize = 0;
    var old_through: usize = 0;
    var publication_owned_end: usize = 0;
    for (edits.items) |edit| {
        while (cursor < edit.at) : (cursor += 1) {
            positions[cursor] = bytes.items.len;
            try bytes.appendSlice(alloc, next.bytes[sourceLineByte(next, cursor)..sourceLineByte(next, cursor + 1)]);
            try provenance.append(alloc, next.line_provenance[cursor]);
        }
        const start = bytes.items.len;
        const old_start = @max(old_through, edit.old.start);
        if (start > 0 and bytes.items[start - 1] != '\n') try bytes.append(alloc, '\n');
        try build_checkpoint.consume(checkpoint, edit.old_end_byte - sourceLineByte(before, old_start));
        try bytes.appendSlice(alloc, before.bytes[sourceLineByte(before, old_start)..edit.old_end_byte]);
        try provenance.appendSlice(alloc, before.line_provenance[old_start..edit.old.end]);
        old_through = edit.old.end;
        publication_owned_end = bytes.items.len;
        if (edit.end < next.hard_line_starts.len and bytes.items.len > 0 and bytes.items[bytes.items.len - 1] != '\n') try bytes.append(alloc, '\n');
        const last_old = before.line_provenance[edit.old.end - 1];
        if (edit.following_new_entry and last_old != .block_separator and last_old != .boundary_blank) {
            try bytes.appendSlice(alloc, next.bytes[sourceLineByte(next, edit.at)..sourceLineByte(next, edit.end)]);
            try provenance.appendSlice(alloc, next.line_provenance[edit.at..edit.end]);
        }
        while (cursor < edit.end) : (cursor += 1) positions[cursor] = start;
    }
    while (cursor < next.hard_line_starts.len) : (cursor += 1) {
        positions[cursor] = bytes.items.len;
        try bytes.appendSlice(alloc, next.bytes[sourceLineByte(next, cursor)..sourceLineByte(next, cursor + 1)]);
        try provenance.append(alloc, next.line_provenance[cursor]);
    }
    positions[cursor] = bytes.items.len;
    var replacement = try prepareIndexedFullTranscriptWindowSourceInterruptible(alloc, try bytes.toOwnedSlice(alloc), next.cols, checkpoint);
    errdefer replacement.deinit(alloc);
    const natural_rows = replacement.preview.natural_visual_rows;
    replacement.preview = if (next.bytes.len == 0) before.preview else next.preview;
    replacement.preview.natural_visual_rows = natural_rows;
    replacement.line_provenance = try provenance.toOwnedSlice(alloc);
    replacement.publication_entries = try alloc.dupe(u32, entry_ids);
    replacement.publication_owned_end = publication_owned_end;
    replacement.folded_summary_indices = try alloc.dupe(usize, next.folded_summary_indices);
    for (replacement.folded_summary_indices) |*line| line.* = publicationLineAt(&replacement, remapPublicationByte(next, positions, sourceLineByte(next, line.*)));
    replacement.tail_kind = if (next.bytes.len == 0) before.tail_kind else next.tail_kind;
    replacement.tracked_entry_id = next.tracked_entry_id;
    replacement.tracked_entry_start_line = if (next.tracked_entry_start_line) |line| publicationLineAt(&replacement, remapPublicationByte(next, positions, sourceLineByte(next, line))) else null;
    replacement.replaceable_last_line = next.replaceable_last_line;
    replacement.replaceable_start = remapPublicationByte(next, positions, next.replaceable_start);
    replacement.replaceable_row = next.replaceable_row;
    replacement.welcome_cut_line = if (next.welcome_cut_line) |line| publicationLineAt(&replacement, remapPublicationByte(next, positions, sourceLineByte(next, line))) else null;
    replacement.welcome_boundary = next.welcome_boundary;
    replacement.recorded_entries_authoritative = true;
    replacement.cache_origin_untrimmed = false;
    replacement.finality = try next.finality.clone(alloc);
    if (replacement.finality.mutation_pin_start) |byte| replacement.finality.mutation_pin_start = remapPublicationByte(next, positions, byte);
    if (replacement.finality.assistant_tail_start) |byte| replacement.finality.assistant_tail_start = remapPublicationByte(next, positions, byte);
    for (@constCast(replacement.finality.tool_turn_floors)) |*floor| floor.start_byte = remapPublicationByte(next, positions, floor.start_byte);
    next.deinit(alloc);
    next.* = replacement;
}

fn checkPublicationProjectionAllocation(alloc: Allocator) !void {
    var before = try prepareIndexedFullTranscriptWindowSourceInterruptible(alloc, try alloc.dupe(u8, "old\n\nnew"), 80, null);
    defer before.deinit(alloc);
    const old_lines = [_]transcript_blocks.LineProvenance{
        .{ .entry = .{ .entry_id = 1, .entry_class = .unknown_raw } },
        .block_separator,
        .{ .entry = .{ .entry_id = 2, .entry_class = .unknown_raw } },
    };
    before.line_provenance = try alloc.dupe(transcript_blocks.LineProvenance, &old_lines);
    var next = try prepareIndexedFullTranscriptWindowSourceInterruptible(alloc, try alloc.dupe(u8, "new"), 80, null);
    defer next.deinit(alloc);
    next.line_provenance = try alloc.dupe(transcript_blocks.LineProvenance, old_lines[2..]);
    next.preview.footer_boundary_gap_rows = 1;
    next.preview.cursor_row = 7;
    next.preview.cursor_col = 4;
    next.finality.assistant_tail_start = 0;
    next.tracked_entry_id = 2;
    next.tracked_entry_start_line = 0;
    preservePublicationEntries(alloc, &before, &next, &.{1}, null, null) catch |err| {
        try std.testing.expectEqualStrings("new", next.bytes);
        try std.testing.expectEqual(@as(?usize, 0), next.finality.assistant_tail_start);
        return err;
    };
    try std.testing.expectEqualStrings("old\n\nnew", next.bytes);
    try std.testing.expectEqual(@as(u16, 1), next.preview.footer_boundary_gap_rows);
    try std.testing.expectEqual(@as(u16, 7), next.preview.cursor_row);
    try std.testing.expectEqual(@as(u16, 4), next.preview.cursor_col);
    try std.testing.expectEqual(@as(?usize, 5), next.finality.assistant_tail_start);
    try std.testing.expectEqual(@as(?usize, 2), next.tracked_entry_start_line);
}

test "rewrite publication preserves preceding gaps without committing a new separator" {
    const alloc = std.testing.allocator;
    var before = try prepareIndexedFullTranscriptWindowSourceInterruptible(alloc, try alloc.dupe(u8, "live\n\nold"), 80, null);
    defer before.deinit(alloc);
    const old_lines = [_]transcript_blocks.LineProvenance{
        .{ .entry = .{ .entry_id = 1, .entry_class = .tool_status } }, .block_separator,
        .{ .entry = .{ .entry_id = 2, .entry_class = .unknown_raw } },
    };
    before.line_provenance = try alloc.dupe(transcript_blocks.LineProvenance, &old_lines);
    var next = try prepareIndexedFullTranscriptWindowSourceInterruptible(alloc, try alloc.dupe(u8, "live\n\nnew"), 80, null);
    defer next.deinit(alloc);
    var next_lines = old_lines;
    next_lines[2].entry.entry_id = 3;
    next.line_provenance = try alloc.dupe(transcript_blocks.LineProvenance, &next_lines);
    try preservePublicationEntries(alloc, &before, &next, &.{2}, null, null);
    try std.testing.expectEqualStrings("live\n\nold\n\nnew", next.bytes);
    try std.testing.expectEqual(@as(usize, "live\n\nold".len), next.publication_owned_end);
    const entries = [_]transcript_blocks.TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "live", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 3, .bytes = "new", .class = .unknown_raw } },
    };
    const host = .{ .entries = .{ .items = &entries } };
    var identity = try RetentionIdentity.capture(&host, alloc, &next);
    defer identity.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 4), identity.publication_release_floor);
    _ = try identity.retainPrefix(alloc, &entries, "live\n\nold\n", 80);
    try std.testing.expectEqual(@as(u32, 3), identity.publication_release_floor);
    try std.testing.expectEqual(@as(usize, 1), identity.text_extents.len);
}

test "rewrite publication prefix receipts exclude unpainted raw and assistant text" {
    const alloc = std.testing.allocator;
    const Runtime = @import("runtime.zig").TranscriptRuntime;
    for ([_]bool{ false, true }) |assistant| {
        var runtime = Runtime{ .layout = .{ .cols = 80, .rows = 12, .content_bottom = 8, .divider_top_row = 9, .input_row = 10, .divider_bottom_row = 11, .hint_row = 12 } };
        defer runtime.deinit(alloc);
        var metrics: types.Metrics = .{};
        const text = "1. FIRST\n2. UNPAINTED\n";
        const id = if (assistant) try runtime.streamAssistantChunk(alloc, &metrics, text) else try runtime.appendRawTranscriptEntryClassified(alloc, text, .unknown_raw);
        var source = try prepareRetentionSource(&runtime, alloc);
        defer source.deinit(alloc);
        try std.testing.expect(source.hard_line_starts.len > 1);
        const prefix = source.bytes[0..source.hard_line_starts[1]];
        var identity = try RetentionIdentity.capture(&runtime, alloc, &source);
        defer identity.deinit(alloc);
        _ = try identity.retainPrefix(alloc, runtime.entries.items, prefix, 80);
        const extent = for (identity.text_extents) |extent| {
            if (extent.entry_id == id) break extent;
        } else return error.MissingPublishedExtent;
        try std.testing.expect(extent.bytes <= std.mem.find(u8, text, "2. UNPAINTED").?);
        try std.testing.expectEqual(@as(usize, 1), identity.lines.len);
    }
}

test "rewrite publication projection preserves preview and finality across allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkPublicationProjectionAllocation, .{});
}

/// Maps boundaries through the producer's retained version of the same source.
/// Entry identity, not rendered text equality, determines which rows survive.
pub const RetentionEntryRows = struct {
    entry_id: u32,
    removed_bytes: usize,
    before: []const usize,
    retained: []const usize,
    raw_before: ?[]const u8 = null,
    raw_retained: []const u8 = &.{},
    assistant_before: ?assistant_wrap.RetentionSourceMap = null,
    assistant_retained: ?assistant_wrap.RetentionSourceMap = null,
};

pub const RetentionRebase = struct {
    before: *const TranscriptPreparationSource,
    retained: *const TranscriptPreparationSource,
    entry_rows: []const RetentionEntryRows = &.{},
    retained_ranges: std.AutoHashMapUnmanaged(EntryIdentity, Range) = .empty,

    const EntryIdentity = @FieldType(transcript_blocks.LineProvenance, "entry");
    const Range = struct { start: usize, end: usize };

    pub fn init(alloc: Allocator, before: *const TranscriptPreparationSource, retained: *const TranscriptPreparationSource, entry_rows: []const RetentionEntryRows) !RetentionRebase {
        var result = RetentionRebase{ .before = before, .retained = retained, .entry_rows = entry_rows };
        errdefer result.deinit(alloc);
        for (retained.line_provenance, 0..) |identity, index| {
            if (identity != .entry) continue;
            const range = try result.retained_ranges.getOrPut(alloc, identity.entry);
            if (!range.found_existing) range.value_ptr.* = .{ .start = index, .end = index + 1 } else range.value_ptr.end = index + 1;
        }
        return result;
    }

    pub fn deinit(self: *RetentionRebase, alloc: Allocator) void {
        self.retained_ranges.deinit(alloc);
    }

    pub fn line(self: RetentionRebase, old_line: usize) usize {
        if (old_line >= self.before.line_provenance.len) return self.retained.hard_line_starts.len;
        var probe = old_line;
        while (probe < self.before.line_provenance.len) : (probe += 1) {
            const identity = self.before.line_provenance[probe];
            if (identity != .entry) continue;
            const range = self.retained_ranges.get(identity.entry) orelse {
                // Skip the entire absent entry, not a retained-document scan for
                // each of its old rendered rows.
                while (probe + 1 < self.before.line_provenance.len and
                    std.meta.eql(self.before.line_provenance[probe + 1], identity)) : (probe += 1)
                {}
                continue;
            };
            const start = range.start;
            const new_end = range.end;
            if (probe != old_line) {
                const previous = self.before.line_provenance[old_line];
                if (previous == .entry and previous.entry.projection_part == .group_header and identity.entry.projection_part == .group_child) return start -| 1;
                return if (self.before.line_provenance[old_line] == .block_separator)
                    start -| @min(probe - old_line, start)
                else
                    start;
            }
            var old_start = probe;
            while (old_start > 0 and std.meta.eql(self.before.line_provenance[old_start - 1], identity)) : (old_start -= 1) {}
            const ordinal = old_line - old_start;
            for (self.entry_rows) |rows| {
                if (rows.entry_id != identity.entry.entry_id) continue;
                if (ordinal >= rows.before.len or rows.retained.len == 0) return new_end;
                const retained_byte = rows.before[ordinal] -| rows.removed_bytes;
                var retained_row: usize = 0;
                for (rows.retained, 0..) |source_byte, row| {
                    if (source_byte > retained_byte) break;
                    retained_row = row;
                }
                return @min(new_end, start + retained_row);
            }
            return @min(new_end, start + ordinal);
        }
        return self.retained.hard_line_starts.len;
    }

    pub fn visual(self: RetentionRebase, old_offset: u32) u32 {
        const offsets = self.before.transcript_visual_row_offsets;
        if (offsets.len == 0) return 0;
        var old_line: usize = 0;
        while (old_line + 1 < offsets.len and offsets[old_line + 1] <= old_offset) : (old_line += 1) {}
        const new_line = self.line(old_line);
        const new_offsets = self.retained.transcript_visual_row_offsets;
        if (new_offsets.len == 0) return 0;
        const base = new_offsets[@min(new_line, new_offsets.len - 1)];
        if (old_line < self.before.line_provenance.len and new_line < self.retained.line_provenance.len and
            !std.meta.eql(self.before.line_provenance[old_line], self.retained.line_provenance[new_line])) return base;
        const partial = old_offset -| offsets[old_line];
        if (old_line < self.before.line_provenance.len) {
            const identity = self.before.line_provenance[old_line];
            if (identity == .entry) for (self.entry_rows) |rows| {
                const text = rows.raw_before orelse continue;
                if (rows.entry_id != identity.entry.entry_id) continue;
                var old_start = old_line;
                while (old_start > 0 and std.meta.eql(self.before.line_provenance[old_start - 1], identity)) : (old_start -= 1) {}
                const ordinal = old_line - old_start;
                if (ordinal >= rows.before.len) return base;
                const raw_start = rows.before[ordinal];
                const raw_end = if (ordinal + 1 < rows.before.len) rows.before[ordinal + 1] else text.len;
                const point = (raw_start + transcript_blocks.skipVisualRowsInLine(text[raw_start..raw_end], self.before.cols, @intCast(partial))) -| rows.removed_bytes;
                var new_ordinal: usize = 0;
                for (rows.retained, 0..) |start, index| {
                    if (start > point) break;
                    new_ordinal = index;
                }
                if (rows.retained.len == 0 or new_line >= self.retained.transcript_line_visual_rows.len) return base;
                const start = rows.retained[new_ordinal];
                const end = if (new_ordinal + 1 < rows.retained.len) rows.retained[new_ordinal + 1] else rows.raw_retained.len;
                var lo: u16 = 0;
                var hi = self.retained.transcript_line_visual_rows[new_line];
                while (lo + 1 < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (transcript_blocks.skipVisualRowsInLine(rows.raw_retained[start..end], self.retained.cols, mid) <= point -| start) lo = mid else hi = mid;
                }
                return base + lo;
            };
        }
        return base + if (new_line < self.retained.transcript_line_visual_rows.len)
            @min(partial, self.retained.transcript_line_visual_rows[new_line] -| 1)
        else
            @as(u32, 0);
    }

    pub fn byte(self: RetentionRebase, old_offset: usize) usize {
        if (old_offset >= self.before.bytes.len) return self.retained.bytes.len;
        var old_line: usize = 0;
        for (self.before.hard_line_starts, 0..) |start, index| {
            if (start > old_offset) break;
            old_line = index;
        }
        const new_line = self.line(old_line);
        if (new_line >= self.retained.hard_line_starts.len) return self.retained.bytes.len;
        const start = self.retained.hard_line_starts[new_line];
        const end = if (new_line + 1 < self.retained.hard_line_starts.len) self.retained.hard_line_starts[new_line + 1] else self.retained.bytes.len;
        if (old_line < self.before.line_provenance.len and self.before.line_provenance[old_line] == .entry) {
            const identity = self.before.line_provenance[old_line];
            for (self.entry_rows) |rows| {
                if (rows.entry_id != identity.entry.entry_id) continue;
                var old_start = old_line;
                while (old_start > 0 and std.meta.eql(self.before.line_provenance[old_start - 1], identity)) : (old_start -= 1) {}
                if (rows.assistant_before) |old_map| {
                    const new_map = rows.assistant_retained.?;
                    const source_point = old_map.sourceAt(old_offset - self.before.hard_line_starts[old_start]) -| rows.removed_bytes;
                    const new_entry_start = self.line(old_start);
                    return @min(self.retained.bytes.len, self.retained.hard_line_starts[new_entry_start] + new_map.renderedAt(source_point));
                }
                if (rows.raw_before == null) continue;
                const point = (rows.before[old_line - old_start] + old_offset - self.before.hard_line_starts[old_line]) -| rows.removed_bytes;
                var retained_start: usize = 0;
                for (rows.retained) |source_byte| {
                    if (source_byte > point) break;
                    retained_start = source_byte;
                }
                return start + @min(point - retained_start, end - start);
            }
        }
        if (old_line < self.before.line_provenance.len and new_line < self.retained.line_provenance.len and
            !std.meta.eql(self.before.line_provenance[old_line], self.retained.line_provenance[new_line])) return start;
        return start + @min(old_offset - self.before.hard_line_starts[old_line], end - start);
    }
};

test "retention rebase uses entry identity for duplicate content" {
    const alloc = std.testing.allocator;
    var before = try prepareIndexedFullTranscriptWindowSourceInterruptible(alloc, try alloc.dupe(u8, "same\nsame\nsame\nsame"), 80, null);
    defer before.deinit(alloc);
    var retained = try prepareIndexedFullTranscriptWindowSourceInterruptible(alloc, try alloc.dupe(u8, "same\nsame"), 80, null);
    defer retained.deinit(alloc);
    const provenance = [_]transcript_blocks.LineProvenance{
        .{ .entry = .{ .entry_id = 1, .entry_class = .unknown_raw } },
        .{ .entry = .{ .entry_id = 2, .entry_class = .unknown_raw } },
        .{ .entry = .{ .entry_id = 3, .entry_class = .unknown_raw } },
        .{ .entry = .{ .entry_id = 4, .entry_class = .unknown_raw } },
    };
    before.line_provenance = try alloc.dupe(transcript_blocks.LineProvenance, &provenance);
    retained.line_provenance = try alloc.dupe(transcript_blocks.LineProvenance, provenance[2..]);
    var mapping = try RetentionRebase.init(alloc, &before, &retained, &.{});
    defer mapping.deinit(alloc);
    for ([_]u32{ 0, 0, 0, 1, 2 }, 0..) |expected, offset| {
        try std.testing.expectEqual(expected, mapping.visual(@intCast(offset)));
        try std.testing.expectEqual(@as(usize, expected), mapping.line(offset));
    }
    try std.testing.expectEqual(@as(usize, 0), mapping.byte(2));
    try std.testing.expectEqual(@as(usize, 2), mapping.byte(12));
    try std.testing.expectEqual(retained.bytes.len, mapping.byte(before.bytes.len));
}

test "retention rebase deleted soft wrapped entry does not transfer partial rows" {
    const alloc = std.testing.allocator;
    var before = try prepareIndexedFullTranscriptWindowSourceInterruptible(alloc, try alloc.dupe(u8, "abcdefghi\njklmnopqr"), 3, null);
    defer before.deinit(alloc);
    var after = try prepareIndexedFullTranscriptWindowSourceInterruptible(alloc, try alloc.dupe(u8, "jklmnopqr"), 3, null);
    defer after.deinit(alloc);
    const provenance = [_]transcript_blocks.LineProvenance{
        .{ .entry = .{ .entry_id = 1, .entry_class = .unknown_raw } },
        .{ .entry = .{ .entry_id = 2, .entry_class = .unknown_raw } },
    };
    before.line_provenance = try alloc.dupe(transcript_blocks.LineProvenance, &provenance);
    after.line_provenance = try alloc.dupe(transcript_blocks.LineProvenance, provenance[1..]);
    var mapping = try RetentionRebase.init(alloc, &before, &after, &.{});
    defer mapping.deinit(alloc);
    for (0..4) |offset| try std.testing.expectEqual(@as(u32, 0), mapping.visual(@intCast(offset)));
    try std.testing.expectEqual(@as(usize, 0), mapping.byte(6));
}

test "retention rebase indexes a large removed entry run once" {
    const alloc = std.testing.allocator;
    var before = try prepareIndexedFullTranscriptWindowSourceInterruptible(alloc, try alloc.dupe(u8, "x\n" ** 20_000), 80, null);
    defer before.deinit(alloc);
    var after = try prepareIndexedFullTranscriptWindowSourceInterruptible(alloc, try alloc.dupe(u8, "x\n" ** 10_000), 80, null);
    defer after.deinit(alloc);
    const old_lines = try alloc.alloc(transcript_blocks.LineProvenance, 20_000);
    before.line_provenance = old_lines;
    for (old_lines, 0..) |*identity, index| identity.* = .{ .entry = .{ .entry_id = if (index < 10_000) 1 else 2, .entry_class = .unknown_raw } };
    after.line_provenance = try alloc.dupe(transcript_blocks.LineProvenance, old_lines[10_000..]);
    var mapping = try RetentionRebase.init(alloc, &before, &after, &.{});
    defer mapping.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 1), mapping.retained_ranges.count());
    for ([_]usize{ 0, 9_999, 10_000, 19_999, 20_000 }) |line_index| {
        try std.testing.expectEqual(line_index -| 10_000, mapping.line(line_index));
    }
}

test "retention rebase maps raw soft wraps and byte endpoints" {
    const alloc = std.testing.allocator;
    const text = "abcdefghi\njkl";
    var before = try prepareIndexedFullTranscriptWindowSourceInterruptible(alloc, try alloc.dupe(u8, text), 3, null);
    defer before.deinit(alloc);
    var after = try prepareIndexedFullTranscriptWindowSourceInterruptible(alloc, try alloc.dupe(u8, text[2..]), 3, null);
    defer after.deinit(alloc);
    const provenance = [_]transcript_blocks.LineProvenance{.{ .entry = .{ .entry_id = 1, .entry_class = .unknown_raw } }} ** 2;
    before.line_provenance = try alloc.dupe(transcript_blocks.LineProvenance, &provenance);
    after.line_provenance = try alloc.dupe(transcript_blocks.LineProvenance, &provenance);
    const entries = [_]RetentionEntryRows{.{
        .entry_id = 1,
        .removed_bytes = 2,
        .before = &.{ 0, 10 },
        .retained = &.{ 0, 8 },
        .raw_before = text,
        .raw_retained = text[2..],
    }};
    var mapping = try RetentionRebase.init(alloc, &before, &after, &entries);
    defer mapping.deinit(alloc);
    for ([_]u32{ 0, 0, 1, 3, 4 }, 0..) |expected, offset| try std.testing.expectEqual(expected, mapping.visual(@intCast(offset)));
    try std.testing.expectEqual(@as(usize, 1), mapping.byte(3));
    try std.testing.expectEqual(@as(usize, 8), mapping.byte(10));
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

/// Takes ownership of one bounded width-rendered full-transcript window and
/// builds its reusable line index once on the page worker.
pub fn prepareIndexedFullTranscriptWindowSourceInterruptible(
    alloc: Allocator,
    bytes: []u8,
    cols: u16,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !TranscriptPreparationSource {
    var source = TranscriptPreparationSource{
        .bytes = bytes,
        .folded_summary_indices = &.{},
        .preview = .{ .natural_visual_rows = 0 },
        .tail_kind = null,
        .tracked_entry_id = null,
        .tracked_entry_start_line = null,
        .replaceable_last_line = false,
        .replaceable_start = 0,
        .replaceable_row = 1,
        .welcome_cut_line = null,
        .welcome_boundary = null,
        .cols = cols,
    };
    errdefer source.deinit(alloc);
    try source.ensureLineIndexInterruptible(alloc, checkpoint);
    const total_rows = if (source.transcript_visual_row_offsets.len > 0)
        source.transcript_visual_row_offsets[source.transcript_visual_row_offsets.len - 1]
    else
        0;
    source.preview.natural_visual_rows = @intCast(@min(
        total_rows,
        std.math.maxInt(u16),
    ));
    return source;
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
        const capture_provenance = true;
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
        const finality_entry_floor_bytes = try alloc.alloc(?usize, finality_nominations.items.len);
        defer alloc.free(finality_entry_floor_bytes);
        for (finality_nominations.items, 0..) |nomination, index| {
            finality_entry_ids[index] = nomination.entry_id;
            finality_entry_floor_bytes[index] = null;
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
                .finality_entry_floor_bytes = finality_entry_floor_bytes,
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
            const floor_byte = finality_entry_floor_bytes[index] orelse blk: {
                // An empty assistant tail contributes no mutable rendered
                // bytes, so the complete prepared flow is final. Other empty
                // nominations remain conservative because their state may
                // still mutate an earlier rendered entry.
                const fallback = switch (nomination.kind) {
                    .assistant_tail => bytes.len,
                    .mutation_pin, .tool_turn => 0,
                };
                debug_trace.logf(
                    "scroll",
                    "finality_nomination_empty entry_id={d} kind={s} fallback={d}",
                    .{ nomination.entry_id, @tagName(nomination.kind), fallback },
                );
                break :blk fallback;
            };
            switch (nomination.kind) {
                .mutation_pin => finality.mutation_pin_start = floor_byte,
                .assistant_tail => finality.assistant_tail_start = @min(bytes.len, floor_byte),
                .tool_turn => try tool_turn_floors.append(alloc, .{
                    .turn_id = nomination.turn_id,
                    .start_byte = floor_byte,
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

    var source: TranscriptPreparationSource = .{
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
    bytes = &.{};
    folded_summary_indices = &.{};
    line_provenance = &.{};
    finality = .{};
    errdefer source.deinit(alloc);
    if (comptime @hasDecl(@TypeOf(self.*), "committedRetentionIdentity")) {
        if (!self.fullTranscriptActive()) {
            if (self.committedRetentionIdentity()) |identity| {
                if (identity.publication_entries.len > 0) {
                    if (try self.prepareCommittedRetentionSourceInterruptible(alloc, checkpoint)) |value| {
                        var before = value;
                        defer before.deinit(alloc);
                        try preservePublicationEntries(alloc, &before, &source, identity.publication_entries, null, checkpoint);
                    }
                }
            }
        }
    }
    return source;
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
        collapseView(self),
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
    if (comptime @hasField(@TypeOf(self.*), "sticky_umbrella_chrome")) {
        if (self.sticky_umbrella_chrome) |old_bytes| {
            alloc.free(old_bytes);
            self.sticky_umbrella_chrome = null;
        }
        if (projection.sticky_chrome) |chrome| {
            // Move ownership onto the shell for sticky paint; projection must
            // not free it on deinit.
            self.sticky_umbrella_chrome = chrome;
            projection.sticky_chrome = null;
        }
    }
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

fn collapseView(self: anytype) tool_group_projection.CollapseView {
    const Shell = @TypeOf(self.*);
    var view: tool_group_projection.CollapseView = .{
        .collapse_tool_calls = collapseToolCalls(self),
    };
    if (comptime @hasField(Shell, "tool_collapse")) {
        view.tree = &self.tool_collapse;
        if (self.tool_collapse.preferred_turn_key) |turn_key| {
            view.active_turn_key = turn_key;
        }
    }
    return view;
}

fn collapseToolCalls(self: anytype) bool {
    const Shell = @TypeOf(self.*);
    return if (comptime @hasField(Shell, "collapse_tool_calls"))
        self.collapse_tool_calls
    else
        false;
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
