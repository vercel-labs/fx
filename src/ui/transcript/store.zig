// Host contract:
// - fields: transcript, entries, next_entry_id, last_rendered_cols,
//   transcript_cache_origin_untrimmed,
//   max_transcript_bytes, max_retained_transcript_bytes,
//   folded_command_blocks, command_output_blocks, command_output_display,
//   tool_details,
//   full_transcript, replaceable_last_line, replaceable_start,
//   replaceable_row, transcript_band_dirty, layout, cursor_row, cursor_col,
//   owned_top_row, viewport_top_row, pending_scroll_compact,
//   has_painted_transcript, last_viewport_selection,
//   last_visible_transcript_top_row, last_visible_transcript_start_line,
//   last_visible_transcript_partial_skip_rows, last_visible_transcript_split_active,
//   last_visible_transcript_split_prefix_lines,
//   last_visible_transcript_split_suffix_start_line
// - methods: assertCanMutateTranscript, advanceCursor, invalidateTranscriptAnchor,
//   recomputeCursorFromTranscript, writeTranscriptBytes,
//   writeTranscriptClassified

const std = @import("std");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const io_mod = @import("../../core/shared/io.zig");
const types = @import("../../core/shared/types.zig");
const command_output_content = @import("../../core/tooling/command_output_content.zig");
const command_output_runtime = @import("command_output_runtime.zig");
const render_engine = @import("../render_engine.zig");
const source_preparation = @import("source_preparation.zig");
const user_message_card = @import("../assistant/user_message_card.zig");
const input_visual_layout = @import("../input/visual_layout.zig");

const Allocator = std.mem.Allocator;
const Metrics = types.Metrics;
const transcript_blocks = render_engine.transcript_blocks;
const assistant_presentation = @import("../../core/agent/assistant_presentation.zig");

const AssistantTurnSegments = transcript_blocks.AssistantTurnSegments;
const RawEntryClass = transcript_blocks.RawEntryClass;
const Styles = transcript_blocks.Styles;
const ToolDetailRecord = transcript_blocks.ToolDetailRecord;
const TranscriptEntry = transcript_blocks.TranscriptEntry;
const SkillTokenSpan = input_visual_layout.SkillTokenSpan;

pub const TranscriptSourceRewriteMode = enum {
    strict,
    preserve_same_epoch,
};

pub const LifecycleEntryUpdate = struct {
    entry_id: u32,
    bytes: []const u8,
};

noinline fn requestTranscriptPaint(self: anytype) void {
    const Runtime = @TypeOf(self.*);
    if (comptime @hasDecl(Runtime, "markTranscriptContentDirty")) {
        self.markTranscriptContentDirty();
    } else if (comptime @hasDecl(Runtime, "markTranscriptDirty")) {
        self.markTranscriptDirty();
    } else {
        self.transcript_band_dirty = true;
    }
}

noinline fn requestTranscriptPaintFrom(self: anytype, entry_id: u32) void {
    const Runtime = @TypeOf(self.*);
    if (comptime @hasDecl(Runtime, "markTranscriptContentDirtyFrom")) {
        self.markTranscriptContentDirtyFrom(entry_id);
    } else {
        requestTranscriptPaint(self);
    }
}

fn reconcileTranscriptAnchorAfterSourceChange(
    self: anytype,
    force_rebase: bool,
    reason: []const u8,
    mode: TranscriptSourceRewriteMode,
) void {
    reconcileTranscriptAnchorAfterSourceChangeUsingSource(
        self,
        self.transcript.items,
        force_rebase,
        reason,
        mode,
    );
}

fn reconcileTranscriptAnchorAfterSourceChangeUsingSource(
    self: anytype,
    reconciliation_source: []const u8,
    force_rebase: bool,
    reason: []const u8,
    mode: TranscriptSourceRewriteMode,
) void {
    const Runtime = @TypeOf(self.*);
    if (comptime @hasDecl(Runtime, "reconcileTranscriptCommitSourceWithRewriteMode")) {
        self.reconcileTranscriptCommitSourceWithRewriteMode(
            reconciliation_source,
            force_rebase,
            reason,
            mode,
        );
    } else if (comptime @hasDecl(Runtime, "reconcileTranscriptCommitSource")) {
        self.reconcileTranscriptCommitSource(
            reconciliation_source,
            force_rebase,
            reason,
        );
    } else if (comptime @hasDecl(Runtime, "stableTranscriptProjectionForFlow") and
        @hasDecl(Runtime, "invalidateTranscriptAnchor"))
    {
        if (force_rebase or
            self.stableTranscriptProjectionForFlow(reconciliation_source) == null)
        {
            self.invalidateTranscriptAnchor(reason);
        }
    }
}

/// Preserve an already committed prefix while an owner-level detached build
/// replaces the transcript state. The complete source is used only for
/// reconciliation; retained entries remain authoritative after publication.
pub fn reconcileDetachedInstallSource(
    self: anytype,
    source: []const u8,
) void {
    reconcileTranscriptAnchorAfterSourceChangeUsingSource(
        self,
        source,
        false,
        "resume_projection_install",
        .strict,
    );
}

pub fn initBacking(self: anytype, alloc: Allocator) !void {
    try self.transcript.ensureTotalCapacity(alloc, self.max_transcript_bytes);
}

pub fn ensurePaintReservation(self: anytype, alloc: Allocator) !void {
    if (self.transcript.capacity < self.max_transcript_bytes) {
        try self.transcript.ensureTotalCapacity(alloc, self.max_transcript_bytes);
    }
}

pub fn rebuildTranscriptFromRendered(self: anytype, alloc: Allocator, bytes: []const u8, label: []const u8) !void {
    const start = cappedTailStart(bytes, self.max_transcript_bytes);
    try self.transcript.ensureTotalCapacity(alloc, bytes.len - start);
    self.transcript_cache_origin_untrimmed = false;
    self.transcript.clearRetainingCapacity();
    if (start > 0) {
        debug_trace.logf("transcript_cap", "{s} trimmed {d} leading bytes (bytes.len={d} cap={d})", .{ label, start, bytes.len, self.max_transcript_bytes });
    }
    self.transcript.appendSliceAssumeCapacity(bytes[start..]);
    self.transcript_cache_origin_untrimmed = start == 0;
    self.last_rendered_cols = if (self.layout.cols > 0) self.layout.cols else 80;
}

pub fn retainedStructuredBytes(self: anytype) usize {
    var total: usize = 0;
    for (self.entries.items) |entry| total += entryRetainedBytes(entry);
    for (self.folded_command_blocks.items) |block| total += command_output_runtime.foldedBlockRetainedBytes(block);
    for (self.command_output_blocks.items) |block| total += command_output_runtime.commandOutputBlockRetainedBytes(block);
    return total;
}

fn entryRetainedBytes(entry: TranscriptEntry) usize {
    return switch (entry) {
        .raw_bytes => |e| e.bytes.len,
        .semantic_notice => |e| e.topic.len + e.body.len,
        .user_turn => |e| blk: {
            var total = e.turn.text.len;
            for (e.turn.images) |img| {
                total += img.path.len;
                total += img.media_type.len;
            }
            for (e.skill_tokens) |token| {
                total += token.name.len;
                total += token.path.len;
            }
            break :blk total;
        },
        .assistant_turn => |e| e.segments.text.items.len,
        .assistant_table => |e| tableRetainedBytes(e.table),
        .assistant_code_block => |e| e.block.language.len + e.block.code.len,
        .assistant_thematic_rule => 0,
    };
}

pub fn entrySnapshotRetainedBytes(entry: TranscriptEntry) usize {
    return @sizeOf(TranscriptEntry) +| entryRetainedBytes(entry);
}

fn dupeSkillTokenSpans(alloc: Allocator, skill_tokens: []const SkillTokenSpan) ![]SkillTokenSpan {
    if (skill_tokens.len == 0) return &.{};
    const copy = try alloc.alloc(SkillTokenSpan, skill_tokens.len);
    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) {
            alloc.free(@constCast(copy[i].name));
            alloc.free(@constCast(copy[i].path));
        }
        alloc.free(copy);
    }
    while (filled < skill_tokens.len) : (filled += 1) {
        const name = try alloc.dupe(u8, skill_tokens[filled].name);
        errdefer alloc.free(name);
        copy[filled] = .{
            .raw_start = skill_tokens[filled].raw_start,
            .raw_end = skill_tokens[filled].raw_end,
            .name = name,
            .path = try alloc.dupe(u8, skill_tokens[filled].path),
            .display_source = skill_tokens[filled].display_source,
            .owns_trailing_separator = skill_tokens[filled].owns_trailing_separator,
        };
    }
    return copy;
}

fn freeSkillTokenSpans(alloc: Allocator, skill_tokens: []SkillTokenSpan) void {
    for (skill_tokens) |token| {
        alloc.free(@constCast(token.name));
        alloc.free(@constCast(token.path));
    }
    if (skill_tokens.len > 0) alloc.free(skill_tokens);
}

fn tableRetainedBytes(table: assistant_presentation.TablePayload) usize {
    var total: usize = table.alignments.len * @sizeOf(assistant_presentation.TableColumnAlign);
    for (table.rows) |row| {
        for (row.cells) |cell| total += cell.len;
    }
    return total;
}

pub fn replaceableEntryId(self: anytype) ?u32 {
    if (!self.replaceable_last_line or self.entries.items.len == 0) return null;
    const tail = self.entries.items[self.entries.items.len - 1];
    return switch (tail) {
        .raw_bytes => |e| e.id,
        else => null,
    };
}

fn protectedPreviousUserTurnId(self: anytype, protected_id: u32) ?u32 {
    for (self.entries.items, 0..) |entry, index| {
        if (entry.id() != protected_id) continue;
        if (entry != .assistant_turn or index == 0) return null;
        const previous = self.entries.items[index - 1];
        return if (previous == .user_turn) previous.user_turn.id else null;
    }
    return null;
}

fn isProtectedEntry(self: anytype, entry_id: u32, protected_id: ?u32) bool {
    if (isLifecyclePinned(self, entry_id)) return true;
    for (self.command_output_blocks.items) |block| {
        if (command_output_runtime.isPrunedRangeAnchor(block, entry_id)) return true;
    }
    if (protected_id) |id| {
        if (entry_id == id) return true;
        if (protectedPreviousUserTurnId(self, id)) |user_id| {
            if (entry_id == user_id) return true;
        }
    }
    if (replaceableEntryId(self)) |id| {
        if (entry_id == id) return true;
    }
    return false;
}

pub fn isLifecyclePinned(self: anytype, entry_id: u32) bool {
    for (self.entries.items) |entry| {
        if (entry != .raw_bytes or entry.raw_bytes.id != entry_id) continue;
        return entry.raw_bytes.lifecycle_pinned;
    }
    return false;
}

pub fn toolStatusEntryLabel(self: anytype, entry_id: u32) ?[]const u8 {
    for (self.entries.items) |entry| {
        if (entry != .raw_bytes or entry.raw_bytes.id != entry_id) continue;
        return std.mem.trimEnd(u8, entry.raw_bytes.bytes, "\r\n");
    }
    return null;
}

pub fn lifecyclePinCount(self: anytype) usize {
    var count: usize = 0;
    for (self.entries.items) |entry| {
        if (entry == .raw_bytes and entry.raw_bytes.lifecycle_pinned) count += 1;
    }
    return count;
}

pub const EntryIdSet = std.AutoHashMapUnmanaged(u32, void);

fn rebuildEntryIdSet(self: anytype, alloc: Allocator, entry_ids: *EntryIdSet) !void {
    entry_ids.clearRetainingCapacity();
    for (self.entries.items) |entry| {
        try entry_ids.put(alloc, entry.id(), {});
    }
}

fn compactEntriesToRetainedSet(
    self: anytype,
    alloc: Allocator,
    retained_entry_ids: *const EntryIdSet,
) void {
    var write_index: usize = 0;
    for (self.entries.items, 0..) |entry, read_index| {
        if (!retained_entry_ids.contains(entry.id())) {
            var removed = entry;
            removed.deinit(alloc);
            continue;
        }
        if (write_index != read_index) {
            self.entries.items[write_index] = entry;
        }
        write_index += 1;
    }
    self.entries.items.len = write_index;
}

fn buildProtectedEntryIdSet(
    self: anytype,
    alloc: Allocator,
    protected_id: ?u32,
) !EntryIdSet {
    var protected_entry_ids: EntryIdSet = .empty;
    errdefer protected_entry_ids.deinit(alloc);

    for (self.entries.items) |entry| {
        if (entry == .raw_bytes and entry.raw_bytes.lifecycle_pinned) {
            try protected_entry_ids.put(alloc, entry.raw_bytes.id, {});
        }
    }
    for (self.command_output_blocks.items) |block| {
        for (block.pruned_ranges.items) |range| {
            try protected_entry_ids.put(alloc, range.anchor_entry_id, {});
        }
    }
    if (protected_id) |id| {
        try protected_entry_ids.put(alloc, id, {});
        if (protectedPreviousUserTurnId(self, id)) |user_id| {
            try protected_entry_ids.put(alloc, user_id, {});
        }
    }
    if (replaceableEntryId(self)) |id| {
        try protected_entry_ids.put(alloc, id, {});
    }
    return protected_entry_ids;
}

fn pruneOrphanedFoldedCommandBlocks(
    self: anytype,
    alloc: Allocator,
    entry_ids: *const EntryIdSet,
) bool {
    var changed = false;
    var i: usize = 0;
    while (i < self.folded_command_blocks.items.len) {
        const summary_id = self.folded_command_blocks.items[i].summary_entry_id;
        if (summary_id) |id| {
            if (!entry_ids.contains(id)) {
                command_output_runtime.removeFoldedCommandBlock(self, alloc, i);
                changed = true;
                continue;
            }
        }
        i += 1;
    }
    return changed;
}

fn firstExistingCommandOutputSourceEntryId(
    entry_ids: *const EntryIdSet,
    block: command_output_runtime.CommandOutputBlock,
) ?u32 {
    for (block.pruned_ranges.items) |range| {
        if (entry_ids.contains(range.anchor_entry_id)) return range.anchor_entry_id;
    }
    for (block.source_entry_ids.items) |entry_id| {
        if (entry_ids.contains(entry_id)) return entry_id;
    }
    return null;
}

fn retargetCommandOutputDetails(self: anytype, old_entry_id: u32, new_entry_id: u32) void {
    if (comptime !@hasField(@TypeOf(self.*), "tool_details")) return;
    for (self.tool_details.items) |*detail| {
        if (detail.command_output_entry_id == old_entry_id) {
            detail.command_output_entry_id = new_entry_id;
        }
    }
}

fn commandOutputBlockHasDetail(
    self: anytype,
    block: command_output_runtime.CommandOutputBlock,
) bool {
    if (comptime !@hasField(@TypeOf(self.*), "tool_details")) return false;
    for (self.tool_details.items) |detail| {
        if (detail.command_output_entry_id) |entry_id| {
            if (command_output_runtime.commandBlockOwnsEntry(block, entry_id)) {
                return true;
            }
        }
        if (detail.lifecycle_id != null and block.lifecycle_id != null and
            command_output_runtime.sameLifecycleId(detail.lifecycle_id, block.lifecycle_id))
        {
            return true;
        }
    }
    return false;
}

fn removePrunedRangeAnchorEntries(
    self: anytype,
    alloc: Allocator,
    block: command_output_runtime.CommandOutputBlock,
    entry_ids: *EntryIdSet,
) void {
    var entry_index: usize = 0;
    while (entry_index < self.entries.items.len) {
        const entry_id = self.entries.items[entry_index].id();
        if (!command_output_runtime.isPrunedRangeAnchor(block, entry_id)) {
            entry_index += 1;
            continue;
        }
        var removed = self.entries.orderedRemove(entry_index);
        _ = entry_ids.remove(entry_id);
        removed.deinit(alloc);
    }
}

fn pruneOrphanedCommandOutputBlocks(
    self: anytype,
    alloc: Allocator,
    entry_ids: *EntryIdSet,
) bool {
    var changed = false;
    var i: usize = 0;
    while (i < self.command_output_blocks.items.len) {
        if (self.command_output_blocks.items[i].live_entry_ids.items.len != 0) {
            i += 1;
            continue;
        }
        if (self.command_output_display.open_command_block) |open| {
            if (open == i) {
                i += 1;
                continue;
            }
        }

        if (self.command_output_blocks.items[i].lines.items.len == 0 and
            self.command_output_blocks.items[i].pruned_ranges.items.len > 0 and
            !commandOutputBlockHasDetail(self, self.command_output_blocks.items[i]))
        {
            removePrunedRangeAnchorEntries(
                self,
                alloc,
                self.command_output_blocks.items[i],
                entry_ids,
            );
            command_output_runtime.removeCommandOutputBlock(self, alloc, i);
            changed = true;
            continue;
        }

        const entry_id = self.command_output_blocks.items[i].entry_id;
        if (entry_id) |id| {
            if (!entry_ids.contains(id)) {
                if (firstExistingCommandOutputSourceEntryId(entry_ids, self.command_output_blocks.items[i])) |replacement| {
                    self.command_output_blocks.items[i].entry_id = replacement;
                    retargetCommandOutputDetails(self, id, replacement);
                    changed = true;
                    i += 1;
                    continue;
                }
                command_output_runtime.removeCommandOutputBlock(self, alloc, i);
                changed = true;
                continue;
            }
        } else {
            if (firstExistingCommandOutputSourceEntryId(entry_ids, self.command_output_blocks.items[i])) |replacement| {
                self.command_output_blocks.items[i].entry_id = replacement;
                changed = true;
                i += 1;
                continue;
            }
            command_output_runtime.removeCommandOutputBlock(self, alloc, i);
            changed = true;
            continue;
        }
        i += 1;
    }
    return changed;
}

fn coalesceCommandOutputPrunedRanges(self: anytype, alloc: Allocator) bool {
    var changed = false;
    for (0..self.command_output_blocks.items.len) |block_index| {
        if (command_output_runtime.coalesceCommandOutputPrunedRanges(
            self,
            alloc,
            block_index,
        )) changed = true;
    }
    return changed;
}

fn trimFoldedCommandLinesToBudget(self: anytype, alloc: Allocator, cap: usize) bool {
    var changed = false;
    var total = retainedStructuredBytes(self);
    if (total <= cap) return false;

    var block_index: usize = 0;
    while (block_index < self.folded_command_blocks.items.len and total > cap) : (block_index += 1) {
        var block = &self.folded_command_blocks.items[block_index];
        while (block.lines.items.len > 0 and total > cap) {
            const line = block.lines.orderedRemove(0);
            const line_len = line.text.len;
            alloc.free(line.text);
            total -|= line_len;
            changed = true;
            debug_trace.logf("transcript_retention", "pruned folded command line bytes={d} retained={d} cap={d}", .{ line_len, total, cap });
        }
    }

    return changed;
}

fn trimCommandOutputLinesToBudget(
    self: anytype,
    alloc: Allocator,
    cap: usize,
    only_count_only_blocks: bool,
) !bool {
    var changed = false;
    var total = retainedStructuredBytes(self);
    if (total <= cap) return false;

    var block_index: usize = 0;
    while (block_index < self.command_output_blocks.items.len and total > cap) : (block_index += 1) {
        var block = &self.command_output_blocks.items[block_index];
        if (only_count_only_blocks and block.total_lines <= block.lines.items.len) continue;
        while (block.lines.items.len > 0 and total > cap) {
            const line_index = block.lines.items.len - 1;
            const line_len = block.lines.items[line_index].text.len;
            if (!try command_output_runtime.trimRetainedCommandOutputLine(
                self,
                alloc,
                block_index,
                line_index,
            )) break;
            block = &self.command_output_blocks.items[block_index];
            total = retainedStructuredBytes(self);
            changed = true;
            debug_trace.logf("transcript_retention", "pruned command output line bytes={d} retained={d} cap={d}", .{ line_len, total, cap });
        }
    }

    return changed;
}

const CommandOutputLineLocation = struct {
    block_index: usize,
    line_index: usize,
    open: bool,
};

const CommandOutputBlockIndex = std.AutoHashMapUnmanaged(u32, usize);

fn buildCommandOutputBlockIndex(self: anytype, alloc: Allocator) !CommandOutputBlockIndex {
    var index: CommandOutputBlockIndex = .empty;
    errdefer index.deinit(alloc);
    for (self.command_output_blocks.items, 0..) |block, block_index| {
        for (block.lines.items) |line| {
            if (line.entry_id) |entry_id| {
                try index.put(alloc, entry_id, block_index);
            }
        }
    }
    return index;
}

fn commandOutputLineLocation(
    self: anytype,
    block_index: *const CommandOutputBlockIndex,
    entry_id: u32,
) ?CommandOutputLineLocation {
    const index = block_index.get(entry_id) orelse return null;
    const block = self.command_output_blocks.items[index];
    for (block.lines.items, 0..) |line, line_index| {
        if (line.entry_id != entry_id) continue;
        var open = false;
        for (block.open_line_indices) |open_line_index| {
            if (open_line_index == line_index) {
                open = true;
                break;
            }
        }
        return .{
            .block_index = index,
            .line_index = line_index,
            .open = open,
        };
    }
    return null;
}

fn trimProtectedEntriesToBudget(self: anytype, alloc: Allocator, cap: usize, protected_id: ?u32) !bool {
    var changed = false;
    var total = retainedStructuredBytes(self);
    while (total > cap) {
        const excess = total - cap;
        var trimmed = false;

        for (self.entries.items) |*entry| {
            const entry_id = entry.id();
            if (!isProtectedEntry(self, entry_id, protected_id)) continue;
            if (isLifecyclePinned(self, entry_id)) continue;

            const before = entryRetainedBytes(entry.*);
            if (before == 0) continue;

            const target = before -| excess;
            if (try trimEntryRetainedBytes(alloc, entry, target)) {
                const after = entryRetainedBytes(entry.*);
                total -|= before - after;
                changed = true;
                trimmed = true;
                debug_trace.logf("transcript_retention", "trimmed protected entry id={d} before={d} after={d} retained={d} cap={d}", .{ entry_id, before, after, total, cap });
                break;
            }
        }

        if (!trimmed) break;
    }
    return changed;
}

fn trimEntryRetainedBytes(alloc: Allocator, entry: *TranscriptEntry, target: usize) !bool {
    switch (entry.*) {
        .raw_bytes => |*e| {
            if (e.bytes.len <= target) return false;
            const start = cappedTailStart(e.bytes, target);
            const retained = try alloc.dupe(u8, e.bytes[start..]);
            alloc.free(e.bytes);
            e.bytes = retained;
            return true;
        },
        .assistant_turn => |*e| {
            if (e.segments.text.items.len <= target) return false;
            const start = cappedTailStart(e.segments.text.items, target);
            if (start == 0) return false;
            const remaining = e.segments.text.items.len - start;
            std.mem.copyForwards(u8, e.segments.text.items[0..remaining], e.segments.text.items[start..]);
            e.segments.text.items.len = remaining;
            return true;
        },
        .assistant_table, .assistant_code_block, .assistant_thematic_rule => return false,
        .semantic_notice, .user_turn => return false,
    }
}

pub fn refreshFoldedCommandSummaryIndices(self: anytype, alloc: Allocator) !void {
    const cols: u16 = if (self.layout.cols > 0) self.layout.cols else 80;
    const summary_entry_ids = try alloc.alloc(?u32, self.folded_command_blocks.items.len);
    defer alloc.free(summary_entry_ids);
    for (self.folded_command_blocks.items, summary_entry_ids) |block, *entry_id| {
        entry_id.* = block.summary_entry_id;
    }

    var prepared = try transcript_blocks.renderEntriesForPreparation(
        alloc,
        self.entries.items,
        cols,
        self.command_output_render.styles,
        .{ .folded_summary_entry_ids = summary_entry_ids },
    );
    defer prepared.deinit(alloc);
    for (self.folded_command_blocks.items, prepared.folded_summary_indices) |*block, index| {
        block.summary_transcript_index = index;
    }
}

fn refreshReplaceableStateAfterEntriesRebuild(self: anytype) void {
    if (!self.replaceable_last_line) return;
    if (self.entries.items.len == 0) {
        self.replaceable_last_line = false;
        self.replaceable_start = 0;
        return;
    }

    const tail = self.entries.items[self.entries.items.len - 1];
    switch (tail) {
        .raw_bytes => |e| {
            if (e.bytes.len <= self.transcript.items.len) {
                self.replaceable_start = self.transcript.items.len - e.bytes.len;
            } else {
                debug_trace.logf("transcript.replaceable_flip", "retention: tail_bytes>transcript, tail={d} transcript={d}", .{ e.bytes.len, self.transcript.items.len });
                self.replaceable_last_line = false;
                self.replaceable_start = 0;
            }
        },
        else => {
            debug_trace.logf("transcript.replaceable_flip", "retention: tail is {s}, entries={d}", .{ @tagName(tail), self.entries.items.len });
            self.replaceable_last_line = false;
            self.replaceable_start = 0;
        },
    }
}

fn rebuildTranscriptCacheFromEntriesMode(
    self: anytype,
    alloc: Allocator,
    label: []const u8,
    mode: TranscriptSourceRewriteMode,
) !void {
    const cols: u16 = if (self.layout.cols > 0) self.layout.cols else 80;
    const fresh = try transcript_blocks.renderEntriesToBytes(
        alloc,
        self.entries.items,
        cols,
        self.command_output_render.styles,
    );
    defer alloc.free(fresh);
    try rebuildTranscriptFromRendered(self, alloc, fresh, label);
    refreshReplaceableStateAfterEntriesRebuild(self);
    reconcileTranscriptAnchorAfterSourceChange(self, false, label, mode);
}

pub fn rebuildTranscriptCacheFromEntries(self: anytype, alloc: Allocator, label: []const u8) !void {
    return rebuildTranscriptCacheFromEntriesMode(self, alloc, label, .strict);
}

pub fn rebuildTranscriptCacheAfterStructuredRewrite(
    self: anytype,
    alloc: Allocator,
    label: []const u8,
) !void {
    return rebuildTranscriptCacheFromEntriesMode(
        self,
        alloc,
        label,
        .preserve_same_epoch,
    );
}

pub fn enforceStructuredRetention(self: anytype, alloc: Allocator, protected_id: ?u32) !void {
    _ = try enforceStructuredRetentionAndReport(self, alloc, protected_id);
}

pub fn enforceStructuredRetentionAndReport(
    self: anytype,
    alloc: Allocator,
    protected_id: ?u32,
) !bool {
    const cap = self.max_retained_transcript_bytes;
    var entry_ids: EntryIdSet = .empty;
    defer entry_ids.deinit(alloc);
    try rebuildEntryIdSet(self, alloc, &entry_ids);

    var changed = pruneOrphanedFoldedCommandBlocks(self, alloc, &entry_ids);
    if (pruneOrphanedCommandOutputBlocks(self, alloc, &entry_ids)) changed = true;
    if (coalesceCommandOutputPrunedRanges(self, alloc)) {
        changed = true;
        try rebuildEntryIdSet(self, alloc, &entry_ids);
    }
    var total = retainedStructuredBytes(self);

    if (total > cap) {
        if (try trimCommandOutputLinesToBudget(self, alloc, cap, true)) {
            changed = true;
            total = retainedStructuredBytes(self);
        }
    }

    var protected_entry_ids = try buildProtectedEntryIdSet(self, alloc, protected_id);
    defer protected_entry_ids.deinit(alloc);
    try protected_entry_ids.ensureTotalCapacity(alloc, @intCast(self.entries.items.len));
    var command_output_block_index = try buildCommandOutputBlockIndex(self, alloc);
    defer command_output_block_index.deinit(alloc);
    var prune_scan_index: usize = 0;

    while (total > cap) {
        var prune_index: ?usize = null;
        for (self.entries.items[prune_scan_index..], prune_scan_index..) |entry, i| {
            if (!entry_ids.contains(entry.id())) continue;
            if (!protected_entry_ids.contains(entry.id())) {
                if (commandOutputLineLocation(self, &command_output_block_index, entry.id())) |location| {
                    if (location.open) continue;
                }
                prune_index = i;
                break;
            }
        }

        const index = prune_index orelse break;
        prune_scan_index = index;
        const entry_id = self.entries.items[index].id();
        if (commandOutputLineLocation(self, &command_output_block_index, entry_id)) |location| {
            const block_bytes_before = command_output_runtime.commandOutputBlockRetainedBytes(
                self.command_output_blocks.items[location.block_index],
            );
            const entry_bytes_before = entryRetainedBytes(self.entries.items[index]);
            const line_bytes = self.command_output_blocks.items[location.block_index]
                .lines.items[location.line_index].text.len;
            if (try command_output_runtime.trimRetainedCommandOutputLine(
                self,
                alloc,
                location.block_index,
                location.line_index,
            )) {
                changed = true;
                debug_trace.logf(
                    "transcript_retention",
                    "pruned command output entry id={d} bytes={d} retained_before={d} cap={d}",
                    .{ entry_id, line_bytes, total, cap },
                );
                try protected_entry_ids.put(alloc, entry_id, {});
                _ = command_output_block_index.remove(entry_id);
                const block_bytes_after = command_output_runtime.commandOutputBlockRetainedBytes(
                    self.command_output_blocks.items[location.block_index],
                );
                const entry_bytes_after = if (rawEntryIndex(self, entry_id)) |entry_index|
                    entryRetainedBytes(self.entries.items[entry_index])
                else
                    0;
                const before = block_bytes_before +| entry_bytes_before;
                const after = block_bytes_after +| entry_bytes_after;
                if (before >= after) {
                    total -|= before - after;
                } else {
                    total +|= after - before;
                }
                continue;
            }
        }

        const entry_bytes = entryRetainedBytes(self.entries.items[index]);
        _ = entry_ids.remove(entry_id);
        changed = true;
        debug_trace.logf("transcript_retention", "pruned entry id={d} bytes={d} retained_before={d} cap={d}", .{ entry_id, entry_bytes, total, cap });
        total -|= entry_bytes;
    }

    if (changed) {
        compactEntriesToRetainedSet(self, alloc, &entry_ids);
        if (coalesceCommandOutputPrunedRanges(self, alloc)) {
            try rebuildEntryIdSet(self, alloc, &entry_ids);
        }
        _ = pruneOrphanedFoldedCommandBlocks(self, alloc, &entry_ids);
        _ = pruneOrphanedCommandOutputBlocks(self, alloc, &entry_ids);
        total = retainedStructuredBytes(self);
    }

    if (total > cap) {
        if (trimFoldedCommandLinesToBudget(self, alloc, cap)) {
            changed = true;
            total = retainedStructuredBytes(self);
        }
    }

    if (total > cap) {
        if (try trimCommandOutputLinesToBudget(self, alloc, cap, false)) {
            changed = true;
            total = retainedStructuredBytes(self);
        }
    }

    if (changed) {
        _ = try command_output_runtime.syncCommandOutputBlockEntries(self, alloc);
        total = retainedStructuredBytes(self);
    }

    if (total > cap) {
        if (try trimProtectedEntriesToBudget(self, alloc, cap, protected_id)) {
            changed = true;
        }
    }

    if (total > cap and lifecyclePinCount(self) > 0) {
        debug_trace.logf(
            "transcript_retention",
            "pinned lifecycle bytes exceed retention cap retained={d} cap={d} pins={d}",
            .{ retainedStructuredBytes(self), cap, lifecyclePinCount(self) },
        );
    }

    if (!changed) return false;
    if (comptime @hasDecl(@TypeOf(self.*), "pruneToolDetailsForRetainedEntries")) {
        try rebuildEntryIdSet(self, alloc, &entry_ids);
        self.pruneToolDetailsForRetainedEntries(alloc, &entry_ids);
    }
    try self.refreshFoldedCommandSummaryIndices(alloc);
    try rebuildTranscriptCacheAfterStructuredRewrite(self, alloc, "structured retention");
    requestTranscriptPaint(self);
    return true;
}

pub fn clearTranscript(self: anytype, alloc: Allocator) void {
    if (self.replaceable_last_line) {
        debug_trace.logf("transcript.replaceable_flip", "clearTranscript wipe, entries={d} transcript_bytes={d}", .{ self.entries.items.len, self.transcript.items.len });
    }
    const pin_count = lifecyclePinCount(self);
    if (pin_count > 0) {
        debug_trace.logf(
            "transcript_retention",
            "clearing {d} lifecycle pins with transcript reset",
            .{pin_count},
        );
    }
    self.transcript.clearRetainingCapacity();
    self.transcript_cache_origin_untrimmed = false;
    if (comptime @hasDecl(@TypeOf(self.*), "clearFullTranscriptDetails")) {
        self.clearFullTranscriptDetails(alloc);
    } else if (comptime @hasDecl(@TypeOf(self.*), "closeFullTranscriptState")) {
        self.closeFullTranscriptState();
    }
    for (self.entries.items) |*entry| entry.deinit(alloc);
    self.entries.clearRetainingCapacity();
    for (self.folded_command_blocks.items) |*block| block.deinit(alloc);
    self.folded_command_blocks.clearRetainingCapacity();
    for (self.command_output_blocks.items) |*block| block.deinit(alloc);
    self.command_output_blocks.clearRetainingCapacity();
    const owned_top = self.owned_top_row;
    self.cursor_row = owned_top;
    self.cursor_col = 1;
    self.viewport_top_row = owned_top;
    self.pending_scroll_compact = false;
    if (comptime @hasDecl(@TypeOf(self.*), "invalidateTranscriptAnchor")) {
        self.invalidateTranscriptAnchor("clear_transcript_state");
    }
    self.has_painted_transcript = false;
    self.command_output_display = .{};
    self.replaceable_last_line = false;
    self.replaceable_start = 0;
    self.last_visible_transcript_top_row = owned_top;
    self.last_visible_transcript_start_line = 0;
    self.last_visible_transcript_partial_skip_rows = 0;
    self.last_visible_transcript_split_active = false;
    self.last_visible_transcript_split_prefix_lines = 0;
    self.last_visible_transcript_split_suffix_start_line = 0;
    self.last_viewport_selection = null;
    requestTranscriptPaint(self);
}

pub fn resetVisualEpoch(self: anytype, alloc: Allocator, welcome: []const u8) !void {
    std.debug.assert(welcome.len > 0);
    try self.assertCanMutateTranscript();

    var replacement_entries: std.ArrayList(TranscriptEntry) = .empty;
    errdefer replacement_entries.deinit(alloc);
    try replacement_entries.ensureTotalCapacity(alloc, self.entries.items.len + 1);

    // Staging borrows retained payloads until publication; only the new welcome
    // belongs to this scope on failure.
    const welcome_copy = try alloc.dupe(u8, welcome);
    errdefer alloc.free(welcome_copy);
    var replaced_welcome = false;
    var hidden_count: usize = 0;
    var pinned_count: usize = 0;
    for (self.entries.items) |entry| {
        if (entry == .raw_bytes and entry.raw_bytes.class == .welcome) {
            if (!replaced_welcome) {
                replacement_entries.appendAssumeCapacity(.{ .raw_bytes = .{
                    .id = entry.raw_bytes.id,
                    .created_at_ms = entry.raw_bytes.created_at_ms,
                    .bytes = welcome_copy,
                    .class = .welcome,
                } });
                replaced_welcome = true;
            }
            continue;
        }
        const pinned = switch (entry) {
            .raw_bytes => |raw| raw.lifecycle_pinned,
            .semantic_notice => |notice| notice.pending_replacement,
            else => false,
        };
        var retained = entry;
        if (pinned) {
            pinned_count += 1;
        } else {
            retained.hideInline();
            hidden_count += 1;
        }
        replacement_entries.appendAssumeCapacity(retained);
    }
    if (!replaced_welcome) {
        replacement_entries.appendAssumeCapacity(.{ .raw_bytes = .{
            .id = self.next_entry_id,
            .created_at_ms = io_mod.milliTimestamp(),
            .bytes = welcome_copy,
            .class = .welcome,
        } });
    }

    const cols: u16 = if (self.layout.cols > 0) self.layout.cols else 80;
    const rendered = try transcript_blocks.renderEntriesToBytes(
        alloc,
        replacement_entries.items,
        cols,
        self.command_output_render.styles,
    );
    defer alloc.free(rendered);
    const rendered_start = cappedTailStart(rendered, self.max_transcript_bytes);

    var replacement_transcript: std.ArrayList(u8) = .empty;
    errdefer replacement_transcript.deinit(alloc);
    try replacement_transcript.appendSlice(alloc, rendered[rendered_start..]);

    var old_entries = self.entries;
    self.entries = replacement_entries;
    replacement_entries = .empty;
    var old_transcript = self.transcript;
    self.transcript = replacement_transcript;
    replacement_transcript = .empty;
    self.transcript_cache_origin_untrimmed = rendered_start == 0;

    for (old_entries.items) |*entry| {
        if (entry.* == .raw_bytes and entry.raw_bytes.class == .welcome) entry.deinit(alloc);
    }
    old_entries.deinit(alloc);
    old_transcript.deinit(alloc);
    debug_trace.logf(
        "transcript.visual_epoch_reset",
        "clear display retained={d} hidden={d} pinned={d}",
        .{ self.entries.items.len - 1, hidden_count, pinned_count },
    );

    if (!replaced_welcome) self.next_entry_id +%= 1;
    self.last_rendered_cols = cols;
    if (comptime @hasDecl(@TypeOf(self.*), "closeFullTranscriptState")) {
        self.closeFullTranscriptState();
    }
    self.command_output_display = .{};
    self.replaceable_last_line = false;
    self.replaceable_start = 0;
    self.pending_scroll_compact = false;
    self.has_painted_transcript = false;
    self.last_visible_transcript_top_row = self.owned_top_row;
    self.last_visible_transcript_start_line = 0;
    self.last_visible_transcript_partial_skip_rows = 0;
    self.last_visible_transcript_split_active = false;
    self.last_visible_transcript_split_prefix_lines = 0;
    self.last_visible_transcript_split_suffix_start_line = 0;
    self.last_viewport_selection = null;
    self.recomputeCursorFromTranscript();
    if (comptime @hasDecl(@TypeOf(self.*), "invalidateTranscriptAnchor")) {
        self.invalidateTranscriptAnchor("visual_epoch_reset");
    }
    requestTranscriptPaint(self);
}

pub fn appendPinnedToolStatusAtomic(
    self: anytype,
    alloc: Allocator,
    text: []const u8,
) !u32 {
    std.debug.assert(text.len > 0);
    try self.assertCanMutateTranscript();

    var shadow = try cloneMutationState(self, alloc);
    defer shadow.deinit(alloc);

    const owned = try alloc.dupe(u8, text);
    var handed_off = false;
    errdefer if (!handed_off) alloc.free(owned);
    const entry_id = try appendRawBytesEntryClassified(
        &shadow,
        alloc,
        owned,
        .tool_status,
    );
    handed_off = true;
    const entry_index = rawEntryIndex(&shadow, entry_id) orelse
        return error.MissingLifecycleTranscriptEntry;
    shadow.entries.items[entry_index].raw_bytes.lifecycle_pinned = true;
    try enforceStructuredRetention(
        &shadow,
        alloc,
        entry_id,
    );
    try rebuildTranscriptCacheFromEntries(
        &shadow,
        alloc,
        "lifecycle entry create",
    );
    shadow.recomputeCursorFromTranscript();
    requestTranscriptPaint(&shadow);

    try commitAuthoritativeRecordedMutationState(
        self,
        &shadow,
        alloc,
        "atomic_pinned_tool_status_append",
        .preserve_same_epoch,
    );
    return entry_id;
}

fn appendSemanticNoticeEntry(
    self: anytype,
    alloc: Allocator,
    notice: types.SemanticNotice,
    pending_replacement: bool,
) !u32 {
    std.debug.assert(notice.body.len > 0);

    const owned = try types.dupeSemanticNotice(alloc, notice);
    errdefer types.freeSemanticNotice(alloc, owned);
    const entry_id = self.next_entry_id;
    try self.entries.append(alloc, .{ .semantic_notice = .{
        .id = entry_id,
        .created_at_ms = io_mod.milliTimestamp(),
        .topic = owned.topic,
        .tone = owned.tone,
        .body = owned.body,
        .visibility = owned.visibility,
        .pending_replacement = pending_replacement,
    } });
    self.next_entry_id +%= 1;
    return entry_id;
}

pub fn appendSemanticNoticeAtomic(
    self: anytype,
    alloc: Allocator,
    notice: types.SemanticNotice,
) !u32 {
    return appendSemanticNoticeAtomicPinned(self, alloc, notice, false);
}

/// Appends a semantic notice the producer intends to replace in place later.
/// The entry carries a pending-replacement pin; replaceSemanticNoticeAtomic
/// requires that pin, and the finished replacement clears it.
pub fn appendReplaceableSemanticNoticeAtomic(
    self: anytype,
    alloc: Allocator,
    notice: types.SemanticNotice,
) !u32 {
    return appendSemanticNoticeAtomicPinned(self, alloc, notice, true);
}

fn appendSemanticNoticeAtomicPinned(
    self: anytype,
    alloc: Allocator,
    notice: types.SemanticNotice,
    pending_replacement: bool,
) !u32 {
    std.debug.assert(notice.body.len > 0);
    try self.assertCanMutateTranscript();

    var shadow = try cloneMutationState(self, alloc);
    defer shadow.deinit(alloc);

    const entry_id = try appendSemanticNoticeEntry(
        &shadow,
        alloc,
        notice,
        pending_replacement,
    );
    try enforceStructuredRetention(
        &shadow,
        alloc,
        entry_id,
    );
    try rebuildTranscriptCacheFromEntries(
        &shadow,
        alloc,
        "semantic notice append",
    );
    shadow.recomputeCursorFromTranscript();
    requestTranscriptPaint(&shadow);

    try commitAuthoritativeRecordedMutationState(
        self,
        &shadow,
        alloc,
        "atomic_semantic_notice_append",
        .preserve_same_epoch,
    );
    return entry_id;
}

fn semanticNoticeIndex(self: anytype, entry_id: u32) ?usize {
    for (self.entries.items, 0..) |entry, index| {
        if (entry == .semantic_notice and entry.semantic_notice.id == entry_id) return index;
    }
    return null;
}

pub fn replaceSemanticNoticeAtomic(
    self: anytype,
    alloc: Allocator,
    entry_id: u32,
    notice: types.SemanticNotice,
) !bool {
    std.debug.assert(notice.body.len > 0);
    if (semanticNoticeIndex(self, entry_id) == null) return false;
    try self.assertCanMutateTranscript();

    var shadow = try cloneMutationState(self, alloc);
    defer shadow.deinit(alloc);
    const entry_index = semanticNoticeIndex(&shadow, entry_id) orelse return false;
    // In-place replacement requires the producer-owned pin, mirroring the
    // raw-bytes lifecycle pin: an unpinned notice is immutable history and
    // may already be released into terminal scrollback.
    if (!shadow.entries.items[entry_index].semantic_notice.pending_replacement) {
        return error.MissingNoticeReplacementPin;
    }
    const created_at_ms = shadow.entries.items[entry_index].semantic_notice.created_at_ms;
    const owned = try types.dupeSemanticNotice(alloc, notice);
    var handed_off = false;
    errdefer if (!handed_off) types.freeSemanticNotice(alloc, owned);
    var previous = shadow.entries.items[entry_index];
    shadow.entries.items[entry_index] = .{ .semantic_notice = .{
        .id = entry_id,
        .created_at_ms = created_at_ms,
        .inline_hidden = previous.semantic_notice.inline_hidden,
        .topic = owned.topic,
        .tone = owned.tone,
        .body = owned.body,
        .visibility = owned.visibility,
    } };
    handed_off = true;
    previous.deinit(alloc);

    try enforceStructuredRetention(
        &shadow,
        alloc,
        entry_id,
    );
    try rebuildTranscriptCacheFromEntries(
        &shadow,
        alloc,
        "semantic notice replacement",
    );
    shadow.recomputeCursorFromTranscript();
    requestTranscriptPaint(&shadow);
    try commitAuthoritativeRecordedMutationState(
        self,
        &shadow,
        alloc,
        "atomic_semantic_notice_replacement",
        .preserve_same_epoch,
    );
    return true;
}

pub fn writeRecordedTranscriptClassifiedAtomic(
    self: anytype,
    alloc: Allocator,
    metrics: *Metrics,
    text: []const u8,
    class: RawEntryClass,
) !u32 {
    std.debug.assert(text.len > 0);
    try self.assertCanMutateTranscript();

    var shadow = try cloneRecordedMutationState(self, alloc);
    defer shadow.deinit(alloc);
    try shadow.writeTranscriptBytes(alloc, metrics, text, true);

    const owned = try alloc.dupe(u8, text);
    var handed_off = false;
    errdefer if (!handed_off) alloc.free(owned);
    const entry_id = try appendRawBytesEntryClassified(
        &shadow,
        alloc,
        owned,
        class,
    );
    handed_off = true;
    try enforceStructuredRetention(
        &shadow,
        alloc,
        entry_id,
    );

    try commitAuthoritativeRecordedMutationState(
        self,
        &shadow,
        alloc,
        "atomic_recorded_transcript_append",
        .preserve_same_epoch,
    );
    return entry_id;
}

pub fn writeRecordedCommandOutputChunkAtomic(
    self: anytype,
    alloc: Allocator,
    metrics: *Metrics,
    styles: Styles,
    lifecycle_id: ?types.ToolLifecycleId,
    stream: command_output_content.Stream,
    text: []const u8,
) !?u32 {
    std.debug.assert(text.len > 0);
    try self.assertCanMutateTranscript();

    var mutation = try command_output_runtime.prepareCommandOutputMutation(
        self,
        alloc,
        lifecycle_id,
        stream,
        text,
        true,
    );
    defer mutation.deinit(alloc);
    if (!mutation.requiresRecordedShadow()) {
        return command_output_runtime.applyPreparedCommandOutputMutation(
            self,
            alloc,
            metrics,
            styles,
            lifecycle_id,
            stream,
            text,
            true,
            &mutation,
        );
    }

    var shadow = try cloneRecordedMutationState(self, alloc);
    defer shadow.deinit(alloc);
    var retention_changed = false;
    if (shadow.command_output_display.open_command_block == null) {
        retention_changed = try reserveNewCommandOutputAdmission(
            &shadow,
            alloc,
            command_output_runtime.commandOutputAdmissionBytes(text),
        );
    }
    const entry_id = try command_output_runtime.applyPreparedCommandOutputMutation(
        &shadow,
        alloc,
        metrics,
        styles,
        lifecycle_id,
        stream,
        text,
        true,
        &mutation,
    );
    _ = try command_output_runtime.syncCommandOutputBlockEntries(&shadow, alloc);
    const dirty_entry_id = entry_id orelse
        command_output_runtime.openCommandOutputDirtyEntryId(&shadow);
    retention_changed = (try enforceStructuredRetentionAndReport(
        &shadow,
        alloc,
        entry_id,
    )) or retention_changed;
    try rebuildCommandOutputTranscriptCache(
        &shadow,
        alloc,
        "atomic_recorded_command_output_append",
    );

    try commitAuthoritativeRecordedMutationStateFromEntry(
        self,
        &shadow,
        alloc,
        "atomic_recorded_command_output_append",
        .preserve_same_epoch,
        if (retention_changed) null else dirty_entry_id,
    );
    return entry_id;
}

fn reserveNewCommandOutputAdmission(
    self: anytype,
    alloc: Allocator,
    reservation: usize,
) !bool {
    const cap = self.max_retained_transcript_bytes;
    const target = cap -| reservation;
    if (retainedStructuredBytes(self) <= target) return false;

    self.max_retained_transcript_bytes = target;
    defer self.max_retained_transcript_bytes = cap;
    return enforceStructuredRetentionAndReport(self, alloc, null);
}

pub fn flushRecordedCommandOutputSummaryAtomic(
    self: anytype,
    alloc: Allocator,
    metrics: *Metrics,
    styles: Styles,
    lifecycle_id: ?types.ToolLifecycleId,
) !void {
    try self.assertCanMutateTranscript();

    var shadow = try cloneRecordedMutationState(self, alloc);
    defer shadow.deinit(alloc);
    const dirty_entry_id = command_output_runtime.commandOutputDirtyEntryIdForLifecycle(
        &shadow,
        lifecycle_id,
    );
    const retention_changed = try command_output_runtime.flushCommandOutputSummaryUncommitted(
        &shadow,
        alloc,
        metrics,
        styles,
        lifecycle_id,
        true,
    );
    try rebuildCommandOutputTranscriptCache(
        &shadow,
        alloc,
        "command output consolidation",
    );

    try commitAuthoritativeRecordedMutationStateFromEntry(
        self,
        &shadow,
        alloc,
        "command output consolidation",
        .preserve_same_epoch,
        if (retention_changed) null else dirty_entry_id,
    );
}

fn rebuildCommandOutputTranscriptCache(
    self: anytype,
    alloc: Allocator,
    label: []const u8,
) !void {
    const rendered = try source_preparation.renderCompactTranscriptBytes(self, alloc);
    defer alloc.free(rendered);
    try rebuildTranscriptFromRendered(self, alloc, rendered, label);
}

pub fn replacePinnedToolStatusAtomic(
    self: anytype,
    alloc: Allocator,
    entry_id: u32,
    new_bytes: []const u8,
) !bool {
    return replacePinnedToolStatusAtomicInternal(
        self,
        alloc,
        entry_id,
        new_bytes,
        false,
        .strict,
        .{},
    );
}

pub fn replacePinnedToolStatusAtEndAtomic(
    self: anytype,
    alloc: Allocator,
    entry_id: u32,
    new_bytes: []const u8,
) !bool {
    return replacePinnedToolStatusAtomicInternal(
        self,
        alloc,
        entry_id,
        new_bytes,
        true,
        .preserve_same_epoch,
        .{},
    );
}

pub fn replacePinnedToolStatusForTerminalAtomic(
    self: anytype,
    alloc: Allocator,
    entry_id: u32,
    new_bytes: []const u8,
    additional_tool_detail_capacity: usize,
    additional_command_output_capacity: usize,
    turn_cancellation_line: ?[]const u8,
) !bool {
    return replacePinnedToolStatusAtomicInternal(
        self,
        alloc,
        entry_id,
        new_bytes,
        false,
        .preserve_same_epoch,
        .{
            .tool_details = additional_tool_detail_capacity,
            .command_output_entries = additional_command_output_capacity,
            .turn_cancellation_line = turn_cancellation_line,
        },
    );
}

const LifecycleStatusReservations = struct {
    tool_details: usize = 0,
    command_output_entries: usize = 0,
    turn_cancellation_line: ?[]const u8 = null,

    fn empty(self: LifecycleStatusReservations) bool {
        return self.tool_details == 0 and
            self.command_output_entries == 0 and
            self.turn_cancellation_line == null;
    }
};

fn replacePinnedToolStatusAtomicInternal(
    self: anytype,
    alloc: Allocator,
    entry_id: u32,
    new_bytes: []const u8,
    place_at_end: bool,
    rewrite_mode: TranscriptSourceRewriteMode,
    reservations: LifecycleStatusReservations,
) !bool {
    try self.assertCanMutateTranscript();
    const entry_index = rawEntryIndex(self, entry_id) orelse return false;
    if (!self.entries.items[entry_index].raw_bytes.lifecycle_pinned) {
        return error.MissingLifecycleTranscriptPin;
    }
    const reposition = place_at_end and entry_index + 1 < self.entries.items.len;

    if (reservations.empty() and
        !reposition and
        !retentionPlanningRequired(self, entry_id, new_bytes.len))
    {
        return replacePinnedToolStatusFast(
            self,
            alloc,
            entry_index,
            new_bytes,
        );
    }

    var shadow = try cloneMutationState(self, alloc);
    defer shadow.deinit(alloc);
    try shadow.tool_details.ensureUnusedCapacity(alloc, reservations.tool_details);
    try shadow.entries.ensureUnusedCapacity(
        alloc,
        reservations.command_output_entries +
            @intFromBool(reservations.turn_cancellation_line != null),
    );
    try shadow.command_output_blocks.ensureUnusedCapacity(
        alloc,
        reservations.command_output_entries,
    );
    const shadow_index = rawEntryIndex(&shadow, entry_id) orelse
        return error.MissingLifecycleTranscriptEntry;
    const replacement = try alloc.dupe(u8, new_bytes);
    alloc.free(shadow.entries.items[shadow_index].raw_bytes.bytes);
    shadow.entries.items[shadow_index].raw_bytes.bytes = replacement;
    shadow.entries.items[shadow_index].raw_bytes.class = .tool_status;
    if (reposition) {
        const entry = shadow.entries.orderedRemove(shadow_index);
        shadow.entries.appendAssumeCapacity(entry);
    }
    var retention_anchor = entry_id;
    if (reservations.turn_cancellation_line) |cancellation_line| {
        const owned = try alloc.dupe(u8, cancellation_line);
        var handed_off = false;
        errdefer if (!handed_off) alloc.free(owned);
        retention_anchor = try appendRawBytesEntryClassified(
            &shadow,
            alloc,
            owned,
            .turn_cancellation,
        );
        handed_off = true;
    }
    const retention_changed = try enforceStructuredRetentionAndReport(
        &shadow,
        alloc,
        retention_anchor,
    );
    try rebuildTranscriptCacheFromEntries(
        &shadow,
        alloc,
        "lifecycle entry update",
    );
    shadow.recomputeCursorFromTranscript();
    requestTranscriptPaint(&shadow);

    try commitAuthoritativeRecordedMutationStateFromEntry(
        self,
        &shadow,
        alloc,
        if (reposition) "lifecycle_status_reposition" else "lifecycle_status_replacement",
        rewrite_mode,
        if (retention_changed or reposition) null else entry_id,
    );
    return true;
}

pub fn replacePinnedToolStatusesAtomic(
    self: anytype,
    alloc: Allocator,
    updates: []const LifecycleEntryUpdate,
    additional_tool_detail_capacity: usize,
    turn_cancellation_line: ?[]const u8,
) !void {
    return replacePinnedToolStatusesAtomicWithRewriteMode(
        self,
        alloc,
        updates,
        .strict,
        additional_tool_detail_capacity,
        turn_cancellation_line,
    );
}

pub fn replacePinnedToolStatusesPreservingNormalBufferAnchorAtomic(
    self: anytype,
    alloc: Allocator,
    updates: []const LifecycleEntryUpdate,
    additional_tool_detail_capacity: usize,
    turn_cancellation_line: ?[]const u8,
) !void {
    return replacePinnedToolStatusesAtomicWithRewriteMode(
        self,
        alloc,
        updates,
        .preserve_same_epoch,
        additional_tool_detail_capacity,
        turn_cancellation_line,
    );
}

fn replacePinnedToolStatusesAtomicWithRewriteMode(
    self: anytype,
    alloc: Allocator,
    updates: []const LifecycleEntryUpdate,
    rewrite_mode: TranscriptSourceRewriteMode,
    additional_tool_detail_capacity: usize,
    turn_cancellation_line: ?[]const u8,
) !void {
    if (updates.len == 0 and turn_cancellation_line == null) return;
    try self.assertCanMutateTranscript();

    var shadow = try cloneMutationState(self, alloc);
    defer shadow.deinit(alloc);
    try shadow.tool_details.ensureUnusedCapacity(
        alloc,
        additional_tool_detail_capacity,
    );
    try shadow.entries.ensureUnusedCapacity(
        alloc,
        @intFromBool(turn_cancellation_line != null),
    );
    for (updates) |update| {
        const entry_index = rawEntryIndex(&shadow, update.entry_id) orelse
            return error.MissingLifecycleTranscriptEntry;
        if (!shadow.entries.items[entry_index].raw_bytes.lifecycle_pinned) {
            return error.MissingLifecycleTranscriptPin;
        }
        const replacement = try alloc.dupe(u8, update.bytes);
        alloc.free(shadow.entries.items[entry_index].raw_bytes.bytes);
        shadow.entries.items[entry_index].raw_bytes.bytes = replacement;
        shadow.entries.items[entry_index].raw_bytes.class = .tool_status;
    }
    var turn_cancellation_entry_id: ?u32 = null;
    if (turn_cancellation_line) |line| {
        const owned = try alloc.dupe(u8, line);
        var handed_off = false;
        errdefer if (!handed_off) alloc.free(owned);
        turn_cancellation_entry_id = try appendRawBytesEntryClassified(
            &shadow,
            alloc,
            owned,
            .turn_cancellation,
        );
        handed_off = true;
    }
    const retention_changed = try enforceStructuredRetentionAndReport(
        &shadow,
        alloc,
        turn_cancellation_entry_id,
    );
    try rebuildTranscriptCacheFromEntries(
        &shadow,
        alloc,
        "lifecycle entries update",
    );
    shadow.recomputeCursorFromTranscript();
    requestTranscriptPaint(&shadow);

    var dirty_entry_id: u32 = undefined;
    if (updates.len > 0) {
        var dirty_entry_index = rawEntryIndex(&shadow, updates[0].entry_id) orelse
            return error.MissingLifecycleTranscriptEntry;
        for (updates[1..]) |update| {
            dirty_entry_index = @min(
                dirty_entry_index,
                rawEntryIndex(&shadow, update.entry_id) orelse
                    return error.MissingLifecycleTranscriptEntry,
            );
        }
        dirty_entry_id = shadow.entries.items[dirty_entry_index].id();
    } else {
        dirty_entry_id = turn_cancellation_entry_id.?;
    }
    try commitAuthoritativeRecordedMutationStateFromEntry(
        self,
        &shadow,
        alloc,
        "lifecycle_statuses_replacement",
        rewrite_mode,
        if (retention_changed) null else dirty_entry_id,
    );
}

pub fn clearLifecyclePinsAtomic(
    self: anytype,
    alloc: Allocator,
    entry_ids: []const u32,
) !void {
    if (entry_ids.len == 0) return;
    try self.assertCanMutateTranscript();

    var shadow = try cloneMutationState(self, alloc);
    defer shadow.deinit(alloc);
    for (entry_ids) |entry_id| {
        const entry_index = rawEntryIndex(&shadow, entry_id) orelse
            return error.MissingLifecycleTranscriptEntry;
        if (!shadow.entries.items[entry_index].raw_bytes.lifecycle_pinned) {
            return error.MissingLifecycleTranscriptPin;
        }
        shadow.entries.items[entry_index].raw_bytes.lifecycle_pinned = false;
    }
    var dirty_entry_index = rawEntryIndex(&shadow, entry_ids[0]) orelse
        return error.MissingLifecycleTranscriptEntry;
    for (entry_ids[1..]) |entry_id| {
        dirty_entry_index = @min(
            dirty_entry_index,
            rawEntryIndex(&shadow, entry_id) orelse
                return error.MissingLifecycleTranscriptEntry,
        );
    }
    const dirty_entry_id = shadow.entries.items[dirty_entry_index].id();
    const retention_changed = try enforceStructuredRetentionAndReport(
        &shadow,
        alloc,
        null,
    );
    try rebuildTranscriptCacheFromEntries(
        &shadow,
        alloc,
        "lifecycle cleanup",
    );
    shadow.recomputeCursorFromTranscript();
    requestTranscriptPaint(&shadow);

    try commitAuthoritativeRecordedMutationStateFromEntry(
        self,
        &shadow,
        alloc,
        "lifecycle_pin_cleanup",
        .preserve_same_epoch,
        if (retention_changed) null else dirty_entry_id,
    );
}

noinline fn rawEntryIndex(self: anytype, entry_id: u32) ?usize {
    for (self.entries.items, 0..) |entry, index| {
        if (entry == .raw_bytes and entry.raw_bytes.id == entry_id) return index;
    }
    return null;
}

fn retentionPlanningRequired(
    self: anytype,
    entry_id: u32,
    replacement_len: usize,
) bool {
    const index = rawEntryIndex(self, entry_id) orelse return false;
    const current_len = self.entries.items[index].raw_bytes.bytes.len;
    const projected = retainedStructuredBytes(self) -| current_len + replacement_len;
    if (projected <= self.max_retained_transcript_bytes) return false;

    if (self.folded_command_blocks.items.len > 0 or
        self.command_output_blocks.items.len > 0)
    {
        return true;
    }
    for (self.entries.items) |entry| {
        if (!isProtectedEntry(self, entry.id(), entry_id)) return true;
    }
    return false;
}

fn replacePinnedToolStatusFast(
    self: anytype,
    alloc: Allocator,
    entry_index: usize,
    new_bytes: []const u8,
) !bool {
    const cols: u16 = if (self.layout.cols > 0) self.layout.cols else 80;
    const previous_origin_untrimmed = self.transcript_cache_origin_untrimmed and
        self.last_rendered_cols == cols;

    const replacement = try alloc.dupe(u8, new_bytes);
    var replacement_owned = true;
    errdefer if (replacement_owned) alloc.free(replacement);

    const old_bytes = self.entries.items[entry_index].raw_bytes.bytes;
    self.entries.items[entry_index].raw_bytes.bytes = replacement;
    defer if (replacement_owned) {
        self.entries.items[entry_index].raw_bytes.bytes = old_bytes;
    };

    const rendered = try transcript_blocks.renderEntriesToBytes(
        alloc,
        self.entries.items,
        cols,
        self.command_output_render.styles,
    );
    defer alloc.free(rendered);
    const start = cappedTailStart(rendered, self.max_transcript_bytes);
    try self.transcript.ensureTotalCapacity(alloc, rendered.len - start);

    self.entries.items[entry_index].raw_bytes.class = .tool_status;
    self.transcript.clearRetainingCapacity();
    self.transcript.appendSliceAssumeCapacity(rendered[start..]);
    self.transcript_cache_origin_untrimmed = start == 0;
    refreshReplaceableStateAfterEntriesRebuild(self);
    self.last_rendered_cols = cols;
    self.recomputeCursorFromTranscript();
    requestTranscriptPaintFrom(self, self.entries.items[entry_index].raw_bytes.id);
    replacement_owned = false;
    alloc.free(old_bytes);
    if (!previous_origin_untrimmed or start != 0) {
        // Recorded entries retain their authoritative source beyond the
        // capped cache, so a capped rewrite stays in the same visual epoch.
        reconcileTranscriptAnchorAfterSourceChangeUsingSource(
            self,
            rendered,
            false,
            "lifecycle_status_replacement",
            .preserve_same_epoch,
        );
    }
    return true;
}

fn cloneRecordedMutationState(self: anytype, alloc: Allocator) !@TypeOf(self.*) {
    var shadow = try cloneMutationState(self, alloc);
    errdefer shadow.deinit(alloc);
    const transcript_storage = try alloc.alloc(u8, self.transcript.capacity);
    @memcpy(transcript_storage[0..self.transcript.items.len], self.transcript.items);
    shadow.transcript = .fromOwnedSlice(transcript_storage);
    shadow.transcript.items.len = self.transcript.items.len;
    return shadow;
}

/// Clone the transcript-owned presentation state for a detached, fallible
/// build. The caller owns the returned runtime and must deinitialize it with
/// the same allocator unless its state is consumed by an owner-level install.
pub fn cloneDetachedPresentationState(self: anytype, alloc: Allocator) !@TypeOf(self.*) {
    return cloneRecordedMutationState(self, alloc);
}

fn cloneMutationState(self: anytype, alloc: Allocator) !@TypeOf(self.*) {
    const Runtime = @TypeOf(self.*);
    var shadow: Runtime = .{
        .layout = self.layout,
        .cursor_row = self.cursor_row,
        .cursor_col = self.cursor_col,
        .owned_top_row = self.owned_top_row,
        .viewport_top_row = self.viewport_top_row,
        .entries = .empty,
        .folded_command_blocks = .empty,
        .command_output_blocks = .empty,
        .tool_details = .empty,
        .transcript = .empty,
        .next_entry_id = self.next_entry_id,
        .last_rendered_cols = self.last_rendered_cols,
        .transcript_cache_origin_untrimmed = self.transcript_cache_origin_untrimmed,
        .max_transcript_bytes = self.max_transcript_bytes,
        .max_retained_transcript_bytes = self.max_retained_transcript_bytes,
        .command_output_display = self.command_output_display,
        .command_output_render = self.command_output_render,
        .full_transcript = self.full_transcript,
        .replaceable_last_line = self.replaceable_last_line,
        .replaceable_row = self.replaceable_row,
        .replaceable_start = self.replaceable_start,
        .transcript_band_dirty = self.transcript_band_dirty,
    };
    errdefer shadow.deinit(alloc);

    shadow.entries = try cloneEntries(alloc, self.entries.items);
    shadow.tool_details = try cloneToolDetails(alloc, self.tool_details);
    shadow.folded_command_blocks = try cloneFoldedCommandBlocks(
        alloc,
        self.folded_command_blocks.items,
    );
    shadow.command_output_blocks = try cloneCommandOutputBlocks(
        alloc,
        self.command_output_blocks.items,
    );
    return shadow;
}

fn commitAuthoritativeRecordedMutationState(
    self: anytype,
    shadow: anytype,
    alloc: Allocator,
    reason: []const u8,
    rewrite_mode: TranscriptSourceRewriteMode,
) !void {
    return commitAuthoritativeRecordedMutationStateFromEntry(
        self,
        shadow,
        alloc,
        reason,
        rewrite_mode,
        null,
    );
}

fn commitAuthoritativeRecordedMutationStateFromEntry(
    self: anytype,
    shadow: anytype,
    alloc: Allocator,
    reason: []const u8,
    rewrite_mode: TranscriptSourceRewriteMode,
    dirty_entry_id: ?u32,
) !void {
    var authoritative_source = try source_preparation.prepareTranscriptSource(
        shadow,
        alloc,
        null,
    );
    defer authoritative_source.deinit(alloc);
    commitMutationStateWithReconciliationSource(
        self,
        shadow,
        reason,
        rewrite_mode,
        authoritative_source.bytes,
        dirty_entry_id,
    );
}

fn commitMutationStateWithReconciliationSource(
    self: anytype,
    shadow: anytype,
    reason: []const u8,
    rewrite_mode: TranscriptSourceRewriteMode,
    reconciliation_source: []const u8,
    dirty_entry_id: ?u32,
) void {
    const Runtime = @TypeOf(shadow.*);
    const preserves_entry_prefix = entryIdsPreservePrefix(
        self.entries.items,
        shadow.entries.items,
    );
    const requested = if (comptime @hasField(Runtime, "render_requests"))
        shadow.render_requests.hasReason(.transcript)
    else
        shadow.transcript_band_dirty;
    std.mem.swap(@TypeOf(self.entries), &self.entries, &shadow.entries);
    std.mem.swap(@TypeOf(self.tool_details), &self.tool_details, &shadow.tool_details);
    std.mem.swap(
        @TypeOf(self.folded_command_blocks),
        &self.folded_command_blocks,
        &shadow.folded_command_blocks,
    );
    std.mem.swap(
        @TypeOf(self.command_output_blocks),
        &self.command_output_blocks,
        &shadow.command_output_blocks,
    );
    std.mem.swap(@TypeOf(self.transcript), &self.transcript, &shadow.transcript);
    self.next_entry_id = shadow.next_entry_id;
    self.last_rendered_cols = shadow.last_rendered_cols;
    self.transcript_cache_origin_untrimmed = shadow.transcript_cache_origin_untrimmed;
    self.command_output_display = shadow.command_output_display;
    self.command_output_render = shadow.command_output_render;
    self.full_transcript = shadow.full_transcript;
    self.replaceable_last_line = shadow.replaceable_last_line;
    self.replaceable_row = shadow.replaceable_row;
    self.replaceable_start = shadow.replaceable_start;
    self.cursor_row = shadow.cursor_row;
    self.cursor_col = shadow.cursor_col;
    self.transcript_band_dirty = shadow.transcript_band_dirty;
    if (requested) {
        if (!preserves_entry_prefix) {
            if (comptime @hasDecl(Runtime, "markTranscriptStructureDirty")) {
                self.markTranscriptStructureDirty();
            } else if (comptime @hasDecl(Runtime, "markTranscriptContentDirty")) {
                self.markTranscriptContentDirty();
            } else {
                requestTranscriptPaint(self);
            }
        } else if (dirty_entry_id) |entry_id| {
            if (comptime @hasDecl(Runtime, "markTranscriptContentDirtyFrom")) {
                self.markTranscriptContentDirtyFrom(entry_id);
            } else {
                requestTranscriptPaint(self);
            }
        } else if (std.mem.eql(u8, reason, "atomic_recorded_command_output_append") and
            comptime @hasDecl(Runtime, "markTranscriptCommandOutputDirty"))
        {
            self.markTranscriptCommandOutputDirty();
        } else {
            requestTranscriptPaint(self);
        }
    }
    reconcileTranscriptAnchorAfterSourceChangeUsingSource(
        self,
        reconciliation_source,
        false,
        reason,
        rewrite_mode,
    );
}

fn entryIdsPreservePrefix(
    previous: []const TranscriptEntry,
    next: []const TranscriptEntry,
) bool {
    if (previous.len > next.len) return false;
    for (previous, next[0..previous.len]) |before, after| {
        if (before.id() != after.id()) return false;
    }
    return true;
}

test "entry prefix identity rejects retention and lifecycle reposition" {
    const previous = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "one" } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "two" } },
    };
    const appended = previous ++ [_]TranscriptEntry{.{ .raw_bytes = .{ .id = 3, .bytes = "three" } }};
    const retained = [_]TranscriptEntry{previous[1]};
    const repositioned = [_]TranscriptEntry{ previous[1], previous[0] };

    try std.testing.expect(entryIdsPreservePrefix(&previous, &appended));
    try std.testing.expect(!entryIdsPreservePrefix(&previous, &retained));
    try std.testing.expect(!entryIdsPreservePrefix(&previous, &repositioned));
}

fn cloneEntries(
    alloc: Allocator,
    source: []const TranscriptEntry,
) !std.ArrayList(TranscriptEntry) {
    var result: std.ArrayList(TranscriptEntry) = .empty;
    errdefer {
        for (result.items) |*entry| entry.deinit(alloc);
        result.deinit(alloc);
    }
    try result.ensureTotalCapacity(alloc, source.len);
    for (source) |entry| {
        result.appendAssumeCapacity(try cloneEntryForSnapshot(alloc, entry));
    }
    return result;
}

pub fn cloneEntryForSnapshot(alloc: Allocator, entry: TranscriptEntry) !TranscriptEntry {
    return switch (entry) {
        .raw_bytes => |raw| .{ .raw_bytes = .{
            .id = raw.id,
            .created_at_ms = raw.created_at_ms,
            .inline_hidden = raw.inline_hidden,
            .bytes = try alloc.dupe(u8, raw.bytes),
            .class = raw.class,
            .lifecycle_pinned = raw.lifecycle_pinned,
        } },
        .semantic_notice => |notice| blk: {
            const owned = try types.dupeSemanticNotice(alloc, .{
                .topic = notice.topic,
                .tone = notice.tone,
                .body = notice.body,
                .visibility = notice.visibility,
            });
            break :blk .{ .semantic_notice = .{
                .id = notice.id,
                .created_at_ms = notice.created_at_ms,
                .inline_hidden = notice.inline_hidden,
                .topic = owned.topic,
                .tone = owned.tone,
                .body = owned.body,
                .visibility = owned.visibility,
                .pending_replacement = notice.pending_replacement,
            } };
        },
        .user_turn => |user| blk: {
            const turn = try types.dupeUserTurn(alloc, user.turn);
            errdefer types.freeUserTurn(alloc, turn);
            const skill_tokens = try dupeSkillTokenSpans(alloc, user.skill_tokens);
            break :blk .{ .user_turn = .{
                .id = user.id,
                .created_at_ms = user.created_at_ms,
                .inline_hidden = user.inline_hidden,
                .turn = turn,
                .skill_tokens = skill_tokens,
            } };
        },
        .assistant_turn => |assistant| blk: {
            var segments: AssistantTurnSegments = .{};
            errdefer segments.deinit(alloc);
            try segments.text.appendSlice(alloc, assistant.segments.text.items);
            break :blk .{ .assistant_turn = .{
                .id = assistant.id,
                .created_at_ms = assistant.created_at_ms,
                .inline_hidden = assistant.inline_hidden,
                .segments = segments,
            } };
        },
        .assistant_table => |assistant| .{ .assistant_table = .{
            .id = assistant.id,
            .created_at_ms = assistant.created_at_ms,
            .inline_hidden = assistant.inline_hidden,
            .table = try assistant.table.clone(alloc),
        } },
        .assistant_code_block => |assistant| .{ .assistant_code_block = .{
            .id = assistant.id,
            .created_at_ms = assistant.created_at_ms,
            .inline_hidden = assistant.inline_hidden,
            .block = try assistant.block.clone(alloc),
        } },
        .assistant_thematic_rule => |assistant| .{ .assistant_thematic_rule = .{
            .id = assistant.id,
            .created_at_ms = assistant.created_at_ms,
            .inline_hidden = assistant.inline_hidden,
        } },
    };
}

fn cloneToolDetails(
    alloc: Allocator,
    source: std.ArrayList(ToolDetailRecord),
) !std.ArrayList(ToolDetailRecord) {
    var result: std.ArrayList(ToolDetailRecord) = .empty;
    errdefer {
        for (result.items) |*detail| detail.deinit(alloc);
        result.deinit(alloc);
    }
    const reserved_slot: usize = @intFromBool(source.capacity > source.items.len);
    try result.ensureTotalCapacityPrecise(alloc, source.items.len + reserved_slot);
    for (source.items) |detail| {
        result.appendAssumeCapacity(try cloneToolDetailForSnapshot(alloc, detail));
    }
    return result;
}

pub fn cloneToolDetailForSnapshot(alloc: Allocator, source: ToolDetailRecord) !ToolDetailRecord {
    const tool_name = try alloc.dupe(u8, source.tool_name);
    errdefer alloc.free(tool_name);
    const arguments_json = if (source.arguments_json) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (arguments_json) |value| alloc.free(value);
    const command_display = if (source.command_display) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (command_display) |value| alloc.free(value);
    const command_action_label = if (source.command_action_label) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (command_action_label) |value| alloc.free(value);
    const result = if (source.result) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (result) |value| alloc.free(value);
    const result_handle = if (source.result_handle) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (result_handle) |value| alloc.free(value);
    const command_artifact_handle = if (source.command_artifact_handle) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (command_artifact_handle) |value| alloc.free(value);
    const command_output_replay = if (source.command_output_replay) |replay|
        try types.dupeCommandOutputReplay(alloc, replay)
    else
        null;
    errdefer if (command_output_replay) |replay| {
        types.freeCommandOutputReplay(alloc, replay);
    };
    const lifecycle_id: ?types.ToolLifecycleId = if (source.lifecycle_id) |id| .{
        .turn_id = id.turn_id,
        .call_id = try alloc.dupe(u8, id.call_id),
    } else null;
    errdefer if (lifecycle_id) |id| alloc.free(@constCast(id.call_id));

    return .{
        .entry_id = source.entry_id,
        .created_at_ms = source.created_at_ms,
        .tool_name = tool_name,
        .captured_command = source.captured_command,
        .activity_kind = source.activity_kind,
        .arguments_json = arguments_json,
        .command_display = command_display,
        .command_action_label = command_action_label,
        .result = result,
        .result_handle = result_handle,
        .command_artifact_handle = command_artifact_handle,
        .command_output_replay = command_output_replay,
        .command_process_presentation = source.command_process_presentation,
        .outcome = source.outcome,
        .fallback_disposition = source.fallback_disposition,
        .origin = source.origin,
        .lifecycle_id = lifecycle_id,
        .presentation_group_id = source.presentation_group_id,
        .command_output_entry_id = source.command_output_entry_id,
    };
}

fn cloneCommandLines(
    alloc: Allocator,
    source: []const command_output_runtime.CommandOutputLine,
) !std.ArrayList(command_output_runtime.CommandOutputLine) {
    var result: std.ArrayList(command_output_runtime.CommandOutputLine) = .empty;
    errdefer {
        for (result.items) |line| alloc.free(line.text);
        result.deinit(alloc);
    }
    try result.ensureTotalCapacity(alloc, source.len);
    for (source) |line| {
        result.appendAssumeCapacity(.{
            .stream = line.stream,
            .text = try alloc.dupe(u8, line.text),
            .record_ordinal = line.record_ordinal,
            .entry_id = line.entry_id,
            .terminated = line.terminated,
            .visible = line.visible,
        });
    }
    return result;
}

fn cloneFoldedCommandBlocks(
    alloc: Allocator,
    source: []const command_output_runtime.FoldedCommandBlock,
) !std.ArrayList(command_output_runtime.FoldedCommandBlock) {
    var result: std.ArrayList(command_output_runtime.FoldedCommandBlock) = .empty;
    errdefer {
        for (result.items) |*block| block.deinit(alloc);
        result.deinit(alloc);
    }
    try result.ensureTotalCapacity(alloc, source.len);
    for (source) |block| {
        result.appendAssumeCapacity(.{
            .summary_transcript_index = block.summary_transcript_index,
            .summary_entry_id = block.summary_entry_id,
            .lines = try cloneCommandLines(alloc, block.lines.items),
        });
    }
    return result;
}

fn cloneCommandOutputBlocks(
    alloc: Allocator,
    source: []const command_output_runtime.CommandOutputBlock,
) !std.ArrayList(command_output_runtime.CommandOutputBlock) {
    var result: std.ArrayList(command_output_runtime.CommandOutputBlock) = .empty;
    errdefer {
        for (result.items) |*block| block.deinit(alloc);
        result.deinit(alloc);
    }
    try result.ensureTotalCapacity(alloc, source.len);
    for (source) |block| {
        const lifecycle_id: ?types.ToolLifecycleId = if (block.lifecycle_id) |id| .{
            .turn_id = id.turn_id,
            .call_id = try alloc.dupe(u8, id.call_id),
        } else null;
        errdefer if (lifecycle_id) |id| alloc.free(@constCast(id.call_id));
        var live_entry_ids: std.ArrayList(u32) = .empty;
        errdefer live_entry_ids.deinit(alloc);
        try live_entry_ids.appendSlice(alloc, block.live_entry_ids.items);
        var source_entry_ids: std.ArrayList(u32) = .empty;
        errdefer source_entry_ids.deinit(alloc);
        try source_entry_ids.appendSlice(alloc, block.source_entry_ids.items);
        var pruned_ranges: std.ArrayList(command_output_runtime.CommandOutputPrunedRange) = .empty;
        errdefer pruned_ranges.deinit(alloc);
        try pruned_ranges.appendSlice(alloc, block.pruned_ranges.items);
        result.appendAssumeCapacity(.{
            .entry_id = block.entry_id,
            .lifecycle_id = lifecycle_id,
            .total_lines = block.total_lines,
            .retained_text_bytes = block.retained_text_bytes,
            .lines = try cloneCommandLines(alloc, block.lines.items),
            .decoders = block.decoders,
            .open_line_indices = block.open_line_indices,
            .overflow_open_records = block.overflow_open_records,
            .overflow_record_visible = block.overflow_record_visible,
            .retention_overflow = block.retention_overflow,
            .overflow_line_index = block.overflow_line_index,
            .pruned_ranges = pruned_ranges,
            .live_entry_ids = live_entry_ids,
            .source_entry_ids = source_entry_ids,
        });
    }
    return result;
}

fn traceUnknownRawEntry(entry_id: u32, bytes_len: usize, source: []const u8) void {
    debug_trace.logf(
        "transcript.raw_class",
        "unknown_raw entry_id={d} bytes={d} source={s}",
        .{ entry_id, bytes_len, source },
    );
}

pub fn appendRawBytesEntry(self: anytype, alloc: Allocator, bytes: []const u8) !u32 {
    const entry_id = try appendRawBytesEntryClassified(self, alloc, bytes, .unknown_raw);
    traceUnknownRawEntry(entry_id, bytes.len, "appendRawBytesEntry");
    return entry_id;
}

pub fn appendRawBytesEntryClassified(
    self: anytype,
    alloc: Allocator,
    bytes: []const u8,
    class: RawEntryClass,
) !u32 {
    return appendRawBytesEntryClassifiedAt(
        self,
        alloc,
        bytes,
        class,
        io_mod.milliTimestamp(),
    );
}

pub fn appendRawBytesEntryClassifiedAt(
    self: anytype,
    alloc: Allocator,
    bytes: []const u8,
    class: RawEntryClass,
    created_at_ms: i64,
) !u32 {
    const entry_id = self.next_entry_id;
    self.next_entry_id +%= 1;
    try self.entries.append(alloc, .{ .raw_bytes = .{ .id = entry_id, .created_at_ms = created_at_ms, .bytes = bytes, .class = class } });
    return entry_id;
}

pub fn insertRawBytesEntryClassifiedAfter(
    self: anytype,
    alloc: Allocator,
    after_entry_id: u32,
    bytes: []const u8,
    class: RawEntryClass,
) !?u32 {
    const anchor_index = rawEntryIndex(self, after_entry_id) orelse return null;
    const entry_id = self.next_entry_id;
    self.next_entry_id +%= 1;
    const entry: TranscriptEntry = .{
        .raw_bytes = .{
            .id = entry_id,
            .created_at_ms = io_mod.milliTimestamp(),
            .bytes = bytes,
            .class = class,
        },
    };
    try self.entries.insert(alloc, anchor_index + 1, entry);
    return entry_id;
}

pub fn insertRawBytesEntryClassifiedAt(
    self: anytype,
    alloc: Allocator,
    index: usize,
    bytes: []const u8,
    class: RawEntryClass,
) !u32 {
    const entry_id = self.next_entry_id;
    const entry: TranscriptEntry = .{
        .raw_bytes = .{
            .id = entry_id,
            .created_at_ms = io_mod.milliTimestamp(),
            .bytes = bytes,
            .class = class,
        },
    };
    try self.entries.insert(alloc, @min(index, self.entries.items.len), entry);
    self.next_entry_id +%= 1;
    return entry_id;
}

pub fn trimTrailingBlankLines(self: anytype) void {
    while (self.transcript.items.len >= 2 and
        self.transcript.items[self.transcript.items.len - 1] == '\n' and
        self.transcript.items[self.transcript.items.len - 2] == '\n')
    {
        self.transcript.items.len -= 1;
        self.transcript_cache_origin_untrimmed = false;
    }
}

pub fn appendRawTranscriptEntry(self: anytype, alloc: Allocator, text: []const u8) !u32 {
    const entry_id = try appendRawTranscriptEntryClassified(self, alloc, text, .unknown_raw);
    traceUnknownRawEntry(entry_id, text.len, "appendRawTranscriptEntry");
    return entry_id;
}

pub fn appendRawTranscriptEntryClassified(
    self: anytype,
    alloc: Allocator,
    text: []const u8,
    class: RawEntryClass,
) !u32 {
    std.debug.assert(text.len > 0);

    const dup = try alloc.dupe(u8, text);
    var entry_owns_dup = false;
    errdefer if (!entry_owns_dup) alloc.free(dup);

    const entry_id = self.next_entry_id;
    self.next_entry_id +%= 1;
    try self.entries.append(alloc, .{ .raw_bytes = .{ .id = entry_id, .created_at_ms = io_mod.milliTimestamp(), .bytes = dup, .class = class } });
    entry_owns_dup = true;
    var rollback_entry = true;
    errdefer if (rollback_entry) {
        var removed = self.entries.orderedRemove(self.entries.items.len - 1);
        removed.deinit(alloc);
        self.next_entry_id -%= 1;
    };

    self.transcript_cache_origin_untrimmed = false;
    _ = try appendCappedWithinCapacity(
        &self.transcript,
        alloc,
        text,
        self.max_transcript_bytes,
        &self.replaceable_last_line,
        &self.replaceable_start,
    );
    self.replaceable_last_line = false;
    _ = self.advanceCursor(text);
    requestTranscriptPaintFrom(self, entry_id);
    rollback_entry = false;
    try enforceStructuredRetention(self, alloc, entry_id);
    return entry_id;
}

pub fn updateRawBytesEntry(
    self: anytype,
    alloc: Allocator,
    entry_id: u32,
    new_bytes: []const u8,
) !bool {
    var match_idx: ?usize = null;
    for (self.entries.items, 0..) |entry, i| {
        if (entry == .raw_bytes and entry.raw_bytes.id == entry_id) {
            match_idx = i;
            break;
        }
    }
    const idx = match_idx orelse return false;

    try self.assertCanMutateTranscript();

    const new_dup = try alloc.dupe(u8, new_bytes);
    var committed = false;
    errdefer if (!committed) alloc.free(new_dup);

    // Swap the pointer so renderEntriesToBytes sees the new content.
    // The paired errdefer restores the pointer on any later failure so
    // the entry keeps owning `old_bytes` (still alive until commit).
    const old_bytes = self.entries.items[idx].raw_bytes.bytes;
    self.entries.items[idx].raw_bytes.bytes = new_dup;
    errdefer if (!committed) {
        self.entries.items[idx].raw_bytes.bytes = old_bytes;
    };

    const new_buffer = try transcript_blocks.renderEntriesToBytes(
        alloc,
        self.entries.items,
        self.layout.cols,
        self.command_output_render.styles,
    );
    defer alloc.free(new_buffer);

    try ensurePaintReservation(self, alloc);
    try rebuildTranscriptFromRendered(self, alloc, new_buffer, "updateRawBytesEntry");

    // Commit: entry now owns new_dup; old_bytes is unreferenced.
    alloc.free(old_bytes);
    committed = true;

    if (idx == self.entries.items.len - 1) {
        self.replaceable_start = self.transcript.items.len - new_bytes.len;
        self.replaceable_last_line = true;
    } else {
        self.replaceable_last_line = false;
    }
    try enforceStructuredRetention(self, alloc, entry_id);
    self.recomputeCursorFromTranscript();
    requestTranscriptPaint(self);
    reconcileTranscriptAnchorAfterSourceChange(
        self,
        true,
        "raw_entry_replacement",
        .strict,
    );
    return true;
}

pub fn setRawEntryClass(self: anytype, entry_id: u32, class: RawEntryClass) bool {
    for (self.entries.items) |*entry| {
        if (entry.* == .raw_bytes and entry.raw_bytes.id == entry_id) {
            entry.raw_bytes.class = class;
            return true;
        }
    }
    return false;
}

pub fn rawEntryClass(self: anytype, entry_id: u32) ?RawEntryClass {
    for (self.entries.items) |entry| {
        if (entry == .raw_bytes and entry.raw_bytes.id == entry_id) return entry.raw_bytes.class;
    }
    return null;
}

pub fn writeUserPromptCard(
    self: anytype,
    alloc: Allocator,
    metrics: *Metrics,
    user: types.UserTurn,
    has_prior_turns: bool,
    skill_tokens: []const SkillTokenSpan,
) !u32 {
    try self.assertCanMutateTranscript();

    var shadow = try cloneRecordedMutationState(self, alloc);
    defer shadow.deinit(alloc);

    if (!has_prior_turns and shadow.cursor_col != 1) {
        _ = try appendRawTranscriptEntryClassified(
            &shadow,
            alloc,
            "\n",
            .unknown_raw,
        );
    }

    const card = try user_message_card.buildUserPromptCardWithSkillTokensForTerminalPresentation(
        alloc,
        user.text,
        user.images,
        shadow.layout.cols,
        skill_tokens,
    );
    defer alloc.free(card);
    try shadow.writeTranscriptBytes(alloc, metrics, card, true);

    const user_copy = try types.dupeUserTurn(alloc, user);
    const admission = try appendUserTurnOwnedWithSkillTokensAndRetention(
        &shadow,
        alloc,
        user_copy,
        skill_tokens,
    );

    try commitAuthoritativeRecordedMutationStateFromEntry(
        self,
        &shadow,
        alloc,
        "atomic_user_prompt_append",
        .preserve_same_epoch,
        if (admission.retention_changed) null else admission.entry_id,
    );
    self.forgetShimmer();
    return admission.entry_id;
}

pub fn appendUserTurnOwned(self: anytype, alloc: Allocator, turn: types.UserTurn) !u32 {
    return appendUserTurnOwnedWithSkillTokens(self, alloc, turn, &.{});
}

pub fn appendUserTurnOwnedWithSkillTokens(
    self: anytype,
    alloc: Allocator,
    turn: types.UserTurn,
    skill_tokens: []const SkillTokenSpan,
) !u32 {
    return (try appendUserTurnOwnedWithSkillTokensAndRetention(
        self,
        alloc,
        turn,
        skill_tokens,
    )).entry_id;
}

const UserTurnAdmission = struct {
    entry_id: u32,
    retention_changed: bool,
};

fn appendUserTurnOwnedWithSkillTokensAndRetention(
    self: anytype,
    alloc: Allocator,
    turn: types.UserTurn,
    skill_tokens: []const SkillTokenSpan,
) !UserTurnAdmission {
    var owned_skill_tokens: []SkillTokenSpan = &.{};
    var handed_off = false;
    errdefer if (!handed_off) {
        types.freeUserTurn(alloc, turn);
        freeSkillTokenSpans(alloc, owned_skill_tokens);
    };
    owned_skill_tokens = try dupeSkillTokenSpans(alloc, skill_tokens);
    const entry_id = self.next_entry_id;
    self.next_entry_id +%= 1;
    try self.entries.append(alloc, .{ .user_turn = .{
        .id = entry_id,
        .created_at_ms = io_mod.milliTimestamp(),
        .turn = turn,
        .skill_tokens = owned_skill_tokens,
    } });
    handed_off = true;
    const retention_changed = try enforceStructuredRetentionAndReport(
        self,
        alloc,
        entry_id,
    );
    return .{
        .entry_id = entry_id,
        .retention_changed = retention_changed,
    };
}

pub fn appendAssistantTurnEntry(self: anytype, alloc: Allocator) !u32 {
    const entry_id = self.next_entry_id;
    self.next_entry_id +%= 1;
    try self.entries.append(alloc, .{ .assistant_turn = .{ .id = entry_id, .created_at_ms = io_mod.milliTimestamp(), .segments = .{} } });
    try enforceStructuredRetention(self, alloc, entry_id);
    return entry_id;
}

/// Takes ownership of `table` only when it returns successfully.
pub fn appendAssistantTableOwned(
    self: anytype,
    alloc: Allocator,
    table: assistant_presentation.TablePayload,
) !u32 {
    const entry_id = self.next_entry_id;
    try self.entries.append(alloc, .{ .assistant_table = .{
        .id = entry_id,
        .created_at_ms = io_mod.milliTimestamp(),
        .table = table,
    } });
    errdefer {
        _ = self.entries.pop();
    }

    const rendered = try transcript_blocks.renderEntriesToBytes(
        alloc,
        self.entries.items,
        self.layout.cols,
        self.command_output_render.styles,
    );
    defer alloc.free(rendered);
    try ensurePaintReservation(self, alloc);
    try rebuildTranscriptFromRendered(self, alloc, rendered, "append_assistant_table");
    try enforceStructuredRetention(self, alloc, entry_id);
    requestTranscriptPaint(self);
    self.next_entry_id +%= 1;
    return entry_id;
}

/// Takes ownership of `block` only when it returns successfully.
pub fn appendAssistantCodeBlockOwned(
    self: anytype,
    alloc: Allocator,
    block: assistant_presentation.CodeBlockPayload,
) !u32 {
    const entry_id = self.next_entry_id;
    try self.entries.append(alloc, .{ .assistant_code_block = .{
        .id = entry_id,
        .created_at_ms = io_mod.milliTimestamp(),
        .block = block,
    } });
    errdefer {
        _ = self.entries.pop();
    }

    const rendered = try transcript_blocks.renderEntriesToBytes(
        alloc,
        self.entries.items,
        self.layout.cols,
        self.command_output_render.styles,
    );
    defer alloc.free(rendered);
    try ensurePaintReservation(self, alloc);
    try rebuildTranscriptFromRendered(self, alloc, rendered, "append_assistant_code_block");
    try enforceStructuredRetention(self, alloc, entry_id);
    requestTranscriptPaint(self);
    self.next_entry_id +%= 1;
    return entry_id;
}

pub fn appendAssistantThematicRule(self: anytype, alloc: Allocator) !u32 {
    const entry_id = self.next_entry_id;
    try self.entries.append(alloc, .{ .assistant_thematic_rule = .{
        .id = entry_id,
        .created_at_ms = io_mod.milliTimestamp(),
    } });
    errdefer {
        _ = self.entries.pop();
    }

    const rendered = try transcript_blocks.renderEntriesToBytes(
        alloc,
        self.entries.items,
        self.layout.cols,
        self.command_output_render.styles,
    );
    defer alloc.free(rendered);
    try ensurePaintReservation(self, alloc);
    try rebuildTranscriptFromRendered(self, alloc, rendered, "append_assistant_thematic_rule");
    try enforceStructuredRetention(self, alloc, entry_id);
    requestTranscriptPaint(self);
    self.next_entry_id +%= 1;
    return entry_id;
}

pub fn lookupAssistantSegments(self: anytype, id: u32) ?*AssistantTurnSegments {
    for (self.entries.items) |*entry| {
        switch (entry.*) {
            .assistant_turn => |*e| if (e.id == id) return &e.segments,
            else => {},
        }
    }
    return null;
}

pub fn tailAssistantSegments(self: anytype) ?*AssistantTurnSegments {
    if (self.entries.items.len == 0) return null;
    const last = &self.entries.items[self.entries.items.len - 1];
    return switch (last.*) {
        .assistant_turn => |*e| if (e.inline_hidden) null else &e.segments,
        else => null,
    };
}

const AssistantStreamAdmission = struct {
    entry_id: u32,
    opened_new_turn: bool,
    retention_changed: bool = false,
};

fn commitAssistantStreamChunkFast(
    self: anytype,
    alloc: Allocator,
    metrics: *Metrics,
    text: []const u8,
) !?AssistantStreamAdmission {
    const retained = retainedStructuredBytes(self);
    if (retained > self.max_retained_transcript_bytes or
        text.len > self.max_retained_transcript_bytes - retained)
    {
        return null;
    }

    const tail_segments = tailAssistantSegments(self);
    const entry_id = if (tail_segments != null)
        self.entries.items[self.entries.items.len - 1].id()
    else
        self.next_entry_id;

    var pending_segments: AssistantTurnSegments = .{};
    defer pending_segments.deinit(alloc);
    if (tail_segments) |segments| {
        try segments.text.ensureUnusedCapacity(alloc, text.len);
    } else {
        try pending_segments.text.appendSlice(alloc, text);
        try self.entries.ensureUnusedCapacity(alloc, 1);
    }

    const transcript_capacity = @min(
        self.max_transcript_bytes,
        self.transcript.items.len +| text.len,
    );
    try self.transcript.ensureTotalCapacity(alloc, transcript_capacity);
    try self.writeTranscriptBytesFrom(alloc, metrics, text, true, entry_id);

    if (tail_segments) |segments| {
        segments.text.appendSliceAssumeCapacity(text);
    } else {
        self.entries.appendAssumeCapacity(.{ .assistant_turn = .{
            .id = entry_id,
            .created_at_ms = io_mod.milliTimestamp(),
            .segments = pending_segments,
        } });
        pending_segments = .{};
        self.next_entry_id +%= 1;
    }

    return .{
        .entry_id = entry_id,
        .opened_new_turn = tail_segments == null,
    };
}

fn streamAssistantChunkUncommitted(
    self: anytype,
    alloc: Allocator,
    metrics: *Metrics,
    text: []const u8,
) !AssistantStreamAdmission {
    const entry_id = if (tailAssistantSegments(self) != null)
        self.entries.items[self.entries.items.len - 1].id()
    else
        self.next_entry_id;
    try self.writeTranscriptBytesFrom(alloc, metrics, text, true, entry_id);

    if (tailAssistantSegments(self)) |segments| {
        try segments.text.appendSlice(alloc, text);
        const retention_changed = try enforceStructuredRetentionAndReport(
            self,
            alloc,
            entry_id,
        );
        return .{
            .entry_id = entry_id,
            .opened_new_turn = false,
            .retention_changed = retention_changed,
        };
    }

    var segments: AssistantTurnSegments = .{};
    errdefer segments.deinit(alloc);
    try segments.text.appendSlice(alloc, text);
    try self.entries.append(alloc, .{ .assistant_turn = .{
        .id = entry_id,
        .created_at_ms = io_mod.milliTimestamp(),
        .segments = segments,
    } });
    segments = .{};
    self.next_entry_id +%= 1;
    const retention_changed = try enforceStructuredRetentionAndReport(
        self,
        alloc,
        entry_id,
    );
    return .{
        .entry_id = entry_id,
        .opened_new_turn = true,
        .retention_changed = retention_changed,
    };
}

pub fn streamAssistantChunk(
    self: anytype,
    alloc: Allocator,
    metrics: *Metrics,
    text: []const u8,
) !u32 {
    if (text.len > 0) try self.assertCanMutateTranscript();

    const prior_entry_count = self.entries.items.len;
    const prior_tail_kind: []const u8 = if (prior_entry_count == 0)
        "empty"
    else switch (self.entries.items[prior_entry_count - 1]) {
        .raw_bytes => "raw_bytes",
        .semantic_notice => "semantic_notice",
        .user_turn => "user_turn",
        .assistant_turn => "assistant_turn",
        .assistant_table => "assistant_table",
        .assistant_code_block => "assistant_code_block",
        .assistant_thematic_rule => "assistant_thematic_rule",
    };
    const admission = if (try commitAssistantStreamChunkFast(self, alloc, metrics, text)) |fast|
        fast
    else blk: {
        var shadow = try cloneRecordedMutationState(self, alloc);
        defer shadow.deinit(alloc);
        const staged = try streamAssistantChunkUncommitted(
            &shadow,
            alloc,
            metrics,
            text,
        );
        try commitAuthoritativeRecordedMutationStateFromEntry(
            self,
            &shadow,
            alloc,
            "atomic_assistant_stream_append",
            .preserve_same_epoch,
            if (staged.retention_changed) null else staged.entry_id,
        );
        self.forgetShimmer();
        break :blk staged;
    };

    if (admission.opened_new_turn) {
        debug_trace.logf(
            "transcript.stream_new_turn",
            "tail={s} text_bytes={d} entries={d}",
            .{ prior_tail_kind, text.len, prior_entry_count },
        );
    }
    return admission.entry_id;
}

pub fn retintEntriesForTheme(
    self: anytype,
    alloc: Allocator,
    from_light: bool,
    to_light: bool,
) !void {
    if (from_light == to_light) return;
    try self.assertCanMutateTranscript();

    var shadow = try cloneMutationState(self, alloc);
    defer shadow.deinit(alloc);

    for (shadow.entries.items) |*entry| {
        switch (entry.*) {
            .raw_bytes => |*raw| {
                if (!themeOwnsRawEntry(raw.class)) continue;
                if (try retintThemeBytes(alloc, raw.bytes, from_light, to_light)) |replacement| {
                    alloc.free(raw.bytes);
                    raw.bytes = replacement;
                }
            },
            .assistant_turn => |*assistant| {
                if (try retintThemeBytes(alloc, assistant.segments.text.items, from_light, to_light)) |replacement| {
                    assistant.segments.text.deinit(alloc);
                    assistant.segments.text = .fromOwnedSlice(replacement);
                }
            },
            .semantic_notice, .user_turn, .assistant_table, .assistant_code_block, .assistant_thematic_rule => {},
        }
    }

    try enforceStructuredRetention(
        &shadow,
        alloc,
        null,
    );
    try rebuildTranscriptCacheFromEntries(&shadow, alloc, "theme retint");
    shadow.recomputeCursorFromTranscript();
    requestTranscriptPaint(&shadow);
    try commitAuthoritativeRecordedMutationState(
        self,
        &shadow,
        alloc,
        "theme retint",
        .preserve_same_epoch,
    );
}

const ThemeToken = struct {
    from: []const u8,
    to: []const u8,
};

const dark_to_light_theme_tokens = [_]ThemeToken{
    .{ .from = "\x1b[1;38;5;255m", .to = "\x1b[1;38;5;235m" },
    .{ .from = "\x1b[38;5;255m", .to = "\x1b[38;5;235m" },
    .{ .from = "\x1b[1;38;5;252m", .to = "\x1b[1;38;5;238m" },
    .{ .from = "\x1b[38;5;252m", .to = "\x1b[38;5;238m" },
    .{ .from = "\x1b[38;5;250m", .to = "\x1b[38;5;241m" },
    .{ .from = "\x1b[38;5;245m", .to = "\x1b[38;5;247m" },
};

const light_to_dark_theme_tokens = [_]ThemeToken{
    .{ .from = "\x1b[1;38;5;235m", .to = "\x1b[1;38;5;255m" },
    .{ .from = "\x1b[38;5;235m", .to = "\x1b[38;5;255m" },
    .{ .from = "\x1b[1;38;5;238m", .to = "\x1b[1;38;5;252m" },
    .{ .from = "\x1b[38;5;238m", .to = "\x1b[38;5;252m" },
    .{ .from = "\x1b[38;5;241m", .to = "\x1b[38;5;250m" },
    .{ .from = "\x1b[38;5;247m", .to = "\x1b[38;5;245m" },
};

fn themeOwnsRawEntry(class: RawEntryClass) bool {
    return switch (class) {
        .welcome,
        .turn_summary,
        .tool_status,
        .diff_block,
        .question_resolution,
        .turn_cancellation,
        .subagent_status,
        => true,
        .command_output, .unknown_raw => false,
    };
}

fn retintThemeBytes(
    alloc: Allocator,
    bytes: []const u8,
    from_light: bool,
    to_light: bool,
) !?[]u8 {
    if (from_light == to_light) return null;
    const tokens = if (to_light) dark_to_light_theme_tokens[0..] else light_to_dark_theme_tokens[0..];
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    var changed = false;
    var index: usize = 0;
    while (index < bytes.len) {
        for (tokens) |token| {
            if (!std.mem.startsWith(u8, bytes[index..], token.from)) continue;
            try out.writer.writeAll(token.to);
            index += token.from.len;
            changed = true;
            break;
        } else {
            try out.writer.writeByte(bytes[index]);
            index += 1;
        }
    }

    if (!changed) {
        out.deinit();
        return null;
    }
    return try out.toOwnedSlice();
}

pub fn appendReplaceableTranscriptLine(self: anytype, alloc: Allocator, metrics: *Metrics, text: []const u8) !u32 {
    _ = metrics;
    if (text.len == 0) return 0;

    const start_row = self.cursor_row;
    debug_trace.logf("replace", "append start_row={d} text_bytes={d} transcript_len_before={d} cols={d}", .{ start_row, text.len, self.transcript.items.len, self.layout.cols });

    const entry_id = try appendReplaceableTranscriptLineSilent(self, alloc, text);
    // Buffer-only — no terminal emit here, so no natural scroll
    // to track. `advanceCursor` still updates `self.cursor_row`
    // (capped) and `self.cursor_col` for between-tick heuristics
    // in `main.zig`; the paint pass owns the authoritative cursor
    // state after the next render.
    _ = self.advanceCursor(text);
    self.replaceable_row = start_row;
    requestTranscriptPaint(self);
    return entry_id;
}

pub fn appendReplaceableTranscriptLineClassified(
    self: anytype,
    alloc: Allocator,
    metrics: *Metrics,
    text: []const u8,
    class: RawEntryClass,
) !u32 {
    const entry_id = try appendReplaceableTranscriptLine(self, alloc, metrics, text);
    _ = setRawEntryClass(self, entry_id, class);
    return entry_id;
}

pub fn replaceTrailingTranscriptLine(self: anytype, alloc: Allocator, metrics: *Metrics, text: []const u8) !bool {
    _ = metrics;
    if (!self.replaceable_last_line or text.len == 0) return false;
    if (self.replaceable_start > self.transcript.items.len) return false;

    debug_trace.logf("replace", "enter replaceable_row={d} replaceable_start={d} old_bytes={d} new_bytes={d} cols={d}", .{ self.replaceable_row, self.replaceable_start, self.transcript.items.len - self.replaceable_start, text.len, self.layout.cols });

    if (!try replaceTrailingTranscriptLineSilent(self, alloc, text)) return false;
    self.recomputeCursorFromTranscript();
    requestTranscriptPaint(self);

    debug_trace.logf("replace", "exit new_cursor={d},{d}", .{ self.cursor_row, self.cursor_col });
    return true;
}

pub fn appendReplaceableTranscriptLineSilent(self: anytype, alloc: Allocator, text: []const u8) !u32 {
    if (text.len == 0) return 0;
    try self.assertCanMutateTranscript();
    self.transcript_cache_origin_untrimmed = false;
    const appended = try appendCappedWithinCapacity(
        &self.transcript,
        alloc,
        text,
        self.max_transcript_bytes,
        &self.replaceable_last_line,
        &self.replaceable_start,
    );
    self.replaceable_start = self.transcript.items.len - appended;
    self.replaceable_last_line = true;

    // Mirror the replaceable line into the entries list as its own
    // raw_bytes entry. Subsequent replaces target this trailing
    // entry via `replaceTrailingTranscriptLineSilent` so spinners
    // stay a single entry rather than accumulating historical
    // ticks in the entries list.
    const dup = try alloc.dupe(u8, text);
    var handed_off = false;
    errdefer if (!handed_off) alloc.free(dup);
    const entry_id = try appendRawBytesEntry(self, alloc, dup);
    handed_off = true;
    try enforceStructuredRetention(self, alloc, entry_id);
    return entry_id;
}

pub fn appendReplaceableTranscriptLineSilentClassified(self: anytype, alloc: Allocator, text: []const u8, class: RawEntryClass) !u32 {
    const entry_id = try appendReplaceableTranscriptLineSilent(self, alloc, text);
    _ = setRawEntryClass(self, entry_id, class);
    return entry_id;
}

pub fn replaceTrailingTranscriptLineSilent(self: anytype, alloc: Allocator, text: []const u8) !bool {
    if (!self.replaceable_last_line or text.len == 0) return false;

    if (self.replaceable_start > self.transcript.items.len) return false;
    try self.assertCanMutateTranscript();
    self.transcript_cache_origin_untrimmed = false;
    self.transcript.items.len = self.replaceable_start;
    _ = try appendCappedWithinCapacity(
        &self.transcript,
        alloc,
        text,
        self.max_transcript_bytes,
        &self.replaceable_last_line,
        &self.replaceable_start,
    );

    // Mirror: while replaceable is active, the trailing raw_bytes
    // entry represents the replaceable content. Swap its bytes in
    // place so the entry count stays stable across ticks and the
    // spinner remains a single logical entry.
    if (self.entries.items.len > 0) {
        const tail = &self.entries.items[self.entries.items.len - 1];
        if (tail.* == .raw_bytes) {
            const old = tail.raw_bytes.bytes;
            const new_bytes = try alloc.dupe(u8, text);
            alloc.free(old);
            tail.raw_bytes.bytes = new_bytes;
            try enforceStructuredRetention(self, alloc, tail.raw_bytes.id);
        }
    }
    reconcileTranscriptAnchorAfterSourceChange(
        self,
        true,
        "replaceable_tail_replacement",
        .strict,
    );
    return true;
}

pub fn writeNotice(
    self: anytype,
    alloc: Allocator,
    metrics: *Metrics,
    notice: types.SemanticNotice,
    record: bool,
) !void {
    if (notice.body.len == 0) return;
    if (record) {
        _ = try appendSemanticNoticeAtomic(self, alloc, notice);
        return;
    }

    const cols: u16 = if (self.layout.cols > 0) self.layout.cols else 80;
    const rendered = try transcript_blocks.renderSemanticNotice(
        alloc,
        notice,
        self.command_output_render.styles,
        cols,
    );
    defer alloc.free(rendered);
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);
    try line.appendSlice(alloc, rendered);
    try line.append(alloc, '\n');
    try self.writeTranscriptBytes(alloc, metrics, line.items, false);
}

pub noinline fn cappedTailStart(bytes: []const u8, limit: usize) usize {
    if (limit == 0) return bytes.len;
    if (bytes.len <= limit) return 0;

    const raw_cut = bytes.len - limit;
    var probe = raw_cut;
    while (probe < bytes.len) : (probe += 1) {
        if (bytes[probe] == '\n') return probe + 1;
    }
    return raw_cut;
}

pub fn appendCappedWithinCapacity(
    list: *std.ArrayList(u8),
    alloc: Allocator,
    text: []const u8,
    cap: usize,
    replaceable_last_line: *bool,
    replaceable_start: *usize,
) !usize {
    if (text.len > cap) {
        const start = cappedTailStart(text, cap);
        debug_trace.logf("transcript_cap", "oversized write dropped {d} leading bytes (text.len={d} cap={d})", .{ start, text.len, cap });
        list.clearRetainingCapacity();
        replaceable_last_line.* = false;
        replaceable_start.* = 0;
        try list.appendSlice(alloc, text[start..]);
        return text.len - start;
    }

    if (list.items.len > cap - text.len) {
        const target_len = cap - text.len;
        const bytes_to_cut = list.items.len - target_len;
        var cut = bytes_to_cut;
        var probe = cut;
        while (probe < list.items.len) : (probe += 1) {
            if (list.items[probe] == '\n') {
                cut = probe + 1;
                break;
            }
        }

        debug_trace.logf("transcript_cap", "trimmed {d} leading bytes before append (prior_len={d} text.len={d} cap={d})", .{ cut, list.items.len, text.len, cap });

        const remaining = list.items.len - cut;
        std.mem.copyForwards(u8, list.items[0..remaining], list.items[cut..]);
        list.items.len = remaining;

        if (replaceable_last_line.*) {
            if (replaceable_start.* >= cut) {
                replaceable_start.* -= cut;
            } else {
                debug_trace.logf("transcript.replaceable_flip", "trim: replaceable span straddled cut, start={d} cut={d}", .{ replaceable_start.*, cut });
                replaceable_last_line.* = false;
                replaceable_start.* = 0;
            }
        }
    }

    try list.appendSlice(alloc, text);
    return text.len;
}

test "appendCappedWithinCapacity keeps latest complete line" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    var replaceable = false;
    var replaceable_start: usize = 0;

    try list.appendSlice(std.testing.allocator, "a\nb\nc\n");
    _ = try appendCappedWithinCapacity(&list, std.testing.allocator, "", 4, &replaceable, &replaceable_start);
    try std.testing.expectEqualStrings("c\n", list.items);
}

test "appendCappedWithinCapacity keeps suffix when no newline" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    var replaceable = false;
    var replaceable_start: usize = 0;

    try list.appendSlice(std.testing.allocator, "abcdefghij");
    _ = try appendCappedWithinCapacity(&list, std.testing.allocator, "", 5, &replaceable, &replaceable_start);
    try std.testing.expectEqualStrings("fghij", list.items);
}

test "cappedTailStart returns bytes.len when limit is zero" {
    try std.testing.expectEqual(@as(usize, 3), cappedTailStart("abc", 0));
    try std.testing.expectEqual(@as(usize, 0), cappedTailStart("", 0));
    try std.testing.expectEqual(@as(usize, 10), cappedTailStart("0123456789", 0));
}

test "cappedTailStart drops trailing newline-only tail" {
    try std.testing.expectEqual(@as(usize, 4), cappedTailStart("abc\n", 2));
    try std.testing.expectEqual(@as(usize, 1), cappedTailStart("\n", 0));
}

test "appendCappedWithinCapacity oversized newline tail can retain less than cap" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    var replaceable = false;
    var replaceable_start: usize = 0;

    const cap: usize = 64;
    const oversized = try std.testing.allocator.alloc(u8, cap + 16);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'z');
    const raw_cut = oversized.len - cap;
    oversized[raw_cut + 7] = '\n';
    const expected_retained_len = oversized.len - (raw_cut + 8);

    const appended = try appendCappedWithinCapacity(&list, std.testing.allocator, oversized, cap, &replaceable, &replaceable_start);

    try std.testing.expectEqual(expected_retained_len, appended);
    try std.testing.expectEqual(expected_retained_len, list.items.len);
    try std.testing.expect(list.items.len < cap);
}

test "refreshFoldedCommandSummaryIndices uses final preparation indices" {
    const alloc = std.testing.allocator;
    const FoldedBlock = struct {
        summary_entry_id: ?u32,
        summary_transcript_index: usize = 0,
    };
    const Runtime = struct {
        layout: struct { cols: u16 },
        entries: std.ArrayList(TranscriptEntry),
        folded_command_blocks: std.ArrayList(FoldedBlock),
        command_output_render: command_output_runtime.CommandOutputRenderPolicy = .{},
    };

    var runtime = Runtime{
        .layout = .{ .cols = 20 },
        .entries = .empty,
        .folded_command_blocks = .empty,
    };
    defer {
        for (runtime.entries.items) |*entry| entry.deinit(alloc);
        runtime.entries.deinit(alloc);
        runtime.folded_command_blocks.deinit(alloc);
    }

    var segments: AssistantTurnSegments = .{};
    try segments.text.appendSlice(alloc, "assistant prose");
    try runtime.entries.append(alloc, .{ .assistant_turn = .{ .id = 1, .segments = segments } });
    try runtime.entries.append(alloc, .{ .raw_bytes = .{
        .id = 2,
        .bytes = try alloc.dupe(u8, "first summary\n"),
        .class = .tool_status,
    } });

    const table = try assistant_presentation.parseTablePayload(
        alloc,
        "| Name | Status |\n" ++
            "|------|--------|\n" ++
            "| api | Complete |\n",
    );
    try runtime.entries.append(alloc, .{ .assistant_table = .{ .id = 3, .table = table } });
    try runtime.entries.append(alloc, .{ .raw_bytes = .{
        .id = 4,
        .bytes = try alloc.dupe(u8, "second summary\n"),
        .class = .tool_status,
    } });

    try runtime.entries.append(alloc, .{ .assistant_code_block = .{
        .id = 5,
        .block = .{
            .language = try alloc.dupe(u8, "zig"),
            .code = try alloc.dupe(u8, "const value = 1;"),
        },
    } });
    try runtime.entries.append(alloc, .{ .raw_bytes = .{
        .id = 6,
        .bytes = try alloc.dupe(u8, "third summary\n"),
        .class = .tool_status,
    } });

    const summary_ids = [_]?u32{ 2, 4, 6 };
    var expected = try transcript_blocks.renderEntriesForPreparation(
        alloc,
        runtime.entries.items,
        runtime.layout.cols,
        .{},
        .{ .folded_summary_entry_ids = &summary_ids },
    );
    defer expected.deinit(alloc);

    try runtime.folded_command_blocks.appendSlice(alloc, &.{
        .{ .summary_entry_id = 2 },
        .{ .summary_entry_id = 4 },
        .{ .summary_entry_id = 6 },
    });
    try refreshFoldedCommandSummaryIndices(&runtime, alloc);

    for (runtime.folded_command_blocks.items, expected.folded_summary_indices) |block, index| {
        try std.testing.expectEqual(index, block.summary_transcript_index);
    }
}
