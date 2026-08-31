const std = @import("std");
const build_checkpoint = @import("../render_engine/build_checkpoint.zig");
const transcript_blocks = @import("../render_engine/transcript_blocks.zig");
const types = @import("../../core/shared/types.zig");
const display_width = @import("../../core/shared/display_width.zig");
const sort_utils = @import("../../core/shared/sort_utils.zig");

const TranscriptEntry = transcript_blocks.TranscriptEntry;
const ToolDetailRecord = transcript_blocks.ToolDetailRecord;
const cancellation_follow_up = " · What can fx do differently?";

pub const Projection = struct {
    entry_actions: std.ArrayList(transcript_blocks.EntryRenderAction) = .empty,
    owned_overrides: std.ArrayList(OwnedOverride) = .empty,

    pub fn deinit(self: *Projection, alloc: std.mem.Allocator) void {
        for (self.owned_overrides.items) |owned| alloc.free(owned.bytes);
        self.owned_overrides.deinit(alloc);
        self.entry_actions.deinit(alloc);
        self.* = undefined;
    }

    fn setOwnedOverride(
        self: *Projection,
        alloc: std.mem.Allocator,
        entry_index: usize,
        kind: transcript_blocks.TranscriptBlockKind,
        bytes: []u8,
    ) !void {
        errdefer alloc.free(bytes);
        try self.owned_overrides.append(alloc, .{
            .entry_index = entry_index,
            .bytes = bytes,
        });
        self.entry_actions.items[entry_index] = .{ .override = .{
            .kind = kind,
            .bytes = bytes,
        } };
    }

    fn appendOwnedOverride(
        self: *Projection,
        alloc: std.mem.Allocator,
        kind: transcript_blocks.TranscriptBlockKind,
        bytes: []u8,
    ) !void {
        const entry_index = self.entry_actions.items.len;
        errdefer alloc.free(bytes);
        try self.entry_actions.ensureUnusedCapacity(alloc, 1);
        try self.owned_overrides.append(alloc, .{
            .entry_index = entry_index,
            .bytes = bytes,
        });
        self.entry_actions.appendAssumeCapacity(.{ .override = .{
            .kind = kind,
            .bytes = bytes,
        } });
    }

    pub fn replaceSuffix(
        self: *Projection,
        alloc: std.mem.Allocator,
        start_index: usize,
        suffix: *Projection,
    ) !void {
        std.debug.assert(start_index <= self.entry_actions.items.len);
        try self.entry_actions.ensureTotalCapacity(
            alloc,
            start_index + suffix.entry_actions.items.len,
        );
        var retained_owned_count: usize = 0;
        for (self.owned_overrides.items) |owned| {
            if (owned.entry_index < start_index) retained_owned_count += 1;
        }
        try self.owned_overrides.ensureTotalCapacity(
            alloc,
            retained_owned_count + suffix.owned_overrides.items.len,
        );

        var retained_index: usize = 0;
        for (self.owned_overrides.items) |owned| {
            if (owned.entry_index < start_index) {
                self.owned_overrides.items[retained_index] = owned;
                retained_index += 1;
            } else {
                alloc.free(owned.bytes);
            }
        }
        self.owned_overrides.items.len = retained_index;
        self.entry_actions.items.len = start_index;
        for (suffix.entry_actions.items) |action| {
            self.entry_actions.appendAssumeCapacity(action);
        }
        for (suffix.owned_overrides.items) |owned| {
            self.owned_overrides.appendAssumeCapacity(.{
                .entry_index = start_index + owned.entry_index,
                .bytes = owned.bytes,
            });
        }
        suffix.entry_actions.items.len = 0;
        suffix.owned_overrides.items.len = 0;
    }
};

const OwnedOverride = struct {
    entry_index: usize,
    bytes: []u8,
};

pub const SummaryStyle = struct {
    marker_style: []const u8 = "",
    text_style: []const u8 = "",
    reset_style: []const u8 = "",
};

const BuildStats = struct {
    detail_lookups: usize = 0,
};

const ProjectionMode = enum { compact, expanded };

const category_labels = [_][]const u8{
    "read",
    "list",
    "write",
    "edit",
    "open",
    "command",
    "subagent",
    "browser",
};
const command_category_index = 5;

const Summary = struct {
    total: usize = 0,
    categories: [category_labels.len]usize = @splat(0),
    failed: usize = 0,
    timed_out: usize = 0,
    denied: usize = 0,
    cancelled: usize = 0,
    deferred: usize = 0,
    completion_unreported: usize = 0,
    not_executed: usize = 0,
};

const PresentationGroup = struct {
    anchor_index: usize,
    status_indices: std.ArrayList(usize) = .empty,
    summary: Summary = .{},

    fn deinit(self: *PresentationGroup, alloc: std.mem.Allocator) void {
        self.status_indices.deinit(alloc);
        self.* = undefined;
    }
};

fn categoryIndex(kind: types.ToolActivityKind) ?usize {
    return switch (kind) {
        .read => 0,
        .list => 1,
        .write => 2,
        .edit => 3,
        .open => 4,
        .command => command_category_index,
        .subagent => 6,
        .ask => null,
    };
}

fn detailForEntry(
    details: []const ToolDetailRecord,
    detail_indices: *const std.AutoHashMapUnmanaged(u32, usize),
    entry_id: u32,
    stats: ?*BuildStats,
) ?*const ToolDetailRecord {
    if (stats) |value| value.detail_lookups += 1;
    const index = detail_indices.get(entry_id) orelse return null;
    return &details[index];
}

fn toolStatusEntryId(entry: TranscriptEntry) ?u32 {
    return switch (entry) {
        .raw_bytes => |raw| if (raw.class == .tool_status) raw.id else null,
        else => null,
    };
}

fn skipSgrSequence(text: []const u8, index: *usize) bool {
    if (index.* + 2 > text.len or text[index.*] != 0x1b or text[index.* + 1] != '[') {
        return false;
    }
    var end = index.* + 2;
    while (end < text.len and (text[end] < 0x40 or text[end] > 0x7e)) : (end += 1) {}
    if (end == text.len or text[end] != 'm') return false;
    index.* = end + 1;
    return true;
}

fn rawStatusNamesAskTool(text: []const u8) bool {
    var index: usize = 0;
    while (skipSgrSequence(text, &index)) {}
    const label = "● ask_user_question";
    if (!std.mem.startsWith(u8, text[index..], label)) return false;
    index += label.len;
    while (skipSgrSequence(text, &index)) {}
    return std.mem.eql(u8, text[index..], "") or
        std.mem.eql(u8, text[index..], "\n") or
        std.mem.eql(u8, text[index..], "\r\n");
}

fn statusNamesAsk(entry: TranscriptEntry, detail: ?*const ToolDetailRecord) bool {
    if (detail) |record| {
        return record.activity_kind == .ask or
            std.mem.eql(u8, record.tool_name, "ask_user_question");
    }
    return switch (entry) {
        .raw_bytes => |raw| rawStatusNamesAskTool(raw.bytes),
        else => false,
    };
}

fn isAttachedEntry(entry: TranscriptEntry) bool {
    return switch (entry) {
        .raw_bytes => |raw| raw.class == .command_output or raw.class == .diff_block,
        else => false,
    };
}

fn isTransparentCompactEntry(entry: TranscriptEntry) bool {
    if (!transcript_blocks.isEntryVisibleInCompactPresentation(entry)) return true;
    return switch (entry) {
        .assistant_turn => |assistant| assistant.segments.text.items.len == 0,
        else => false,
    };
}

fn commandProcessFailed(record: *const ToolDetailRecord) bool {
    if (record.activity_kind != .command) return false;
    const presentation = record.command_process_presentation orelse return false;
    return switch (presentation) {
        .exit_code => |code| code != 0,
        .signal, .timed_out, .output_capture_failed => true,
    };
}

fn commandProcessTimedOut(record: *const ToolDetailRecord) bool {
    if (record.activity_kind != .command) return false;
    const presentation = record.command_process_presentation orelse return false;
    return presentation == .timed_out;
}

fn observeTool(summary: *Summary, detail: ?*const ToolDetailRecord) void {
    summary.total += 1;
    const record = detail orelse return;
    if (record.activity_kind) |kind| {
        if (categoryIndex(kind)) |index| summary.categories[index] += 1;
    }
    if (record.fallback_disposition) |disposition| {
        switch (disposition) {
            .completion_unreported => summary.completion_unreported += 1,
            .not_executed => summary.not_executed += 1,
        }
        return;
    }
    const process_failed = commandProcessFailed(record);
    const process_timed_out = commandProcessTimedOut(record);
    if (record.outcome) |outcome| {
        switch (outcome) {
            .completed => {
                if (process_timed_out)
                    summary.timed_out += 1
                else if (process_failed)
                    summary.failed += 1;
            },
            .failed => {
                if (process_timed_out)
                    summary.timed_out += 1
                else
                    summary.failed += 1;
            },
            .denied => summary.denied += 1,
            .cancelled => summary.cancelled += 1,
            .deferred => summary.deferred += 1,
        }
    }
}

fn appendSegment(writer: *std.Io.Writer, count: usize, label: []const u8) !void {
    if (count == 0) return;
    try writer.print(" · {d} {s}", .{ count, label });
}

fn normalizeCanonicalStatus(
    scratch: std.mem.Allocator,
    text: []const u8,
) !?[]const u8 {
    var index: usize = 0;
    while (skipSgrSequence(text, &index)) {}
    const markers = [_][]const u8{ "●", "■", "⊘", "↻" };
    const marker = for (markers) |candidate| {
        if (std.mem.startsWith(u8, text[index..], candidate)) break candidate;
    } else return null;
    index += marker.len;
    while (skipSgrSequence(text, &index)) {}
    while (index < text.len and (text[index] == ' ' or text[index] == '\t')) : (index += 1) {}

    var out: std.Io.Writer.Allocating = .init(scratch);
    errdefer out.deinit();
    while (index < text.len) {
        if (skipSgrSequence(text, &index)) continue;
        const byte = text[index];
        if (byte == '\n' or byte == '\r') break;
        if (byte >= 0x20) try out.writer.writeByte(byte);
        index += 1;
    }
    const owned = try out.toOwnedSlice();
    var phrase = std.mem.trim(u8, owned, " \t");
    if (std.mem.endsWith(u8, phrase, cancellation_follow_up)) {
        phrase = std.mem.trimEnd(u8, phrase[0 .. phrase.len - cancellation_follow_up.len], " \t");
    }
    return if (phrase.len == 0) null else phrase;
}

fn normalizeStatusPhrase(
    scratch: std.mem.Allocator,
    text: []const u8,
) !?[]const u8 {
    if (try normalizeCanonicalStatus(scratch, text)) |phrase| return phrase;
    var out: std.Io.Writer.Allocating = .init(scratch);
    errdefer out.deinit();
    var index: usize = 0;
    while (index < text.len) {
        if (skipSgrSequence(text, &index)) continue;
        const byte = text[index];
        if (byte == '\n' or byte == '\r') break;
        if (byte >= 0x20) try out.writer.writeByte(byte);
        index += 1;
    }
    const owned = try out.toOwnedSlice();
    const phrase = std.mem.trim(u8, owned, " \t");
    return if (phrase.len == 0) null else phrase;
}

fn clipSummary(
    alloc: std.mem.Allocator,
    text: []const u8,
    cols: u16,
) ![]u8 {
    if (display_width.visibleWidth(text) <= cols) return try alloc.dupe(u8, text);
    if (cols == 0) return try alloc.dupe(u8, "");
    if (cols == 1) return try alloc.dupe(u8, "…");
    const prefix = display_width.prefixByWidth(text, cols - 1);
    return try std.fmt.allocPrint(alloc, "{s}…", .{prefix});
}

fn applySummaryStyle(
    alloc: std.mem.Allocator,
    text: []const u8,
    style: SummaryStyle,
) ![]u8 {
    if (style.marker_style.len == 0 and
        style.text_style.len == 0 and
        style.reset_style.len == 0)
    {
        return try alloc.dupe(u8, text);
    }

    const marker = "●";
    if (!std.mem.startsWith(u8, text, marker)) return try alloc.dupe(u8, text);
    var content_start = marker.len;
    const has_separator = content_start < text.len and text[content_start] == ' ';
    if (has_separator) content_start += 1;

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll(style.marker_style);
    try out.writer.writeAll(marker);
    try out.writer.writeAll(style.reset_style);
    if (content_start < text.len) {
        if (has_separator) try out.writer.writeByte(' ');
        try out.writer.writeAll(style.text_style);
        try out.writer.writeAll(text[content_start..]);
        try out.writer.writeAll(style.reset_style);
    }
    return try out.toOwnedSlice();
}

fn formatGroupHeader(
    alloc: std.mem.Allocator,
    summary: Summary,
    cols: u16,
    style: SummaryStyle,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.print("● {d} tool call{s}", .{
        summary.total,
        if (summary.total == 1) "" else "s",
    });
    var emitted: [category_labels.len]bool = @splat(false);
    for (0..category_labels.len) |_| {
        var next_index: ?usize = null;
        for (summary.categories, 0..) |count, index| {
            if (count == 0 or emitted[index]) continue;
            if (next_index == null or count > summary.categories[next_index.?]) {
                next_index = index;
            }
        }
        const index = next_index orelse break;
        emitted[index] = true;
        const count = summary.categories[index];
        const label = if (index == command_category_index and count != 1)
            "commands"
        else
            category_labels[index];
        try appendSegment(&out.writer, count, label);
    }
    try appendSegment(&out.writer, summary.completion_unreported, "unreported");
    try appendSegment(&out.writer, summary.not_executed, "not executed");
    try appendSegment(&out.writer, summary.timed_out, "timed out");
    try appendSegment(&out.writer, summary.failed, "failed");
    try appendSegment(&out.writer, summary.denied, "denied");
    try appendSegment(&out.writer, summary.cancelled, "cancelled");
    try appendSegment(&out.writer, summary.deferred, "deferred");

    const plain = try out.toOwnedSlice();
    defer alloc.free(plain);
    const clipped = try clipSummary(alloc, plain, cols);
    defer alloc.free(clipped);
    return applySummaryStyle(alloc, clipped, style);
}

fn formatGroupBlock(
    alloc: std.mem.Allocator,
    entries: []const TranscriptEntry,
    status_indices: []const usize,
    details: []const ToolDetailRecord,
    detail_indices: *const std.AutoHashMapUnmanaged(u32, usize),
    summary: Summary,
    focused_entry_id: ?u32,
    collapse_tool_calls: bool,
    cols: u16,
    style: SummaryStyle,
    styles: transcript_blocks.Styles,
) ![]u8 {
    const header = try formatGroupHeader(alloc, summary, cols, style);
    if (collapse_tool_calls) return header;
    defer alloc.free(header);

    var focused_in_group = false;
    var static_count: usize = 0;
    for (status_indices) |status_index| {
        const entry = entries[status_index];
        const entry_id = toolStatusEntryId(entry) orelse continue;
        const detail = detailForEntry(details, detail_indices, entry_id, null);
        if (statusNamesAsk(entry, detail)) continue;
        if (focused_entry_id == entry_id) {
            focused_in_group = true;
        } else {
            static_count += 1;
        }
    }

    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll(header);

    var static_index: usize = 0;
    for (status_indices) |status_index| {
        const entry = entries[status_index];
        const entry_id = toolStatusEntryId(entry) orelse continue;
        const detail = detailForEntry(details, detail_indices, entry_id, null);
        if (statusNamesAsk(entry, detail) or focused_entry_id == entry_id) continue;

        const phrase = switch (entry) {
            .raw_bytes => |raw| try normalizeCanonicalStatus(scratch, raw.bytes),
            else => null,
        } orelse if (detail) |record| record.tool_name else "tool activity";
        static_index += 1;
        const connector = if (!focused_in_group and static_index == static_count) "└" else "├";
        const child = try std.fmt.allocPrint(scratch, "{s} {s}", .{ connector, phrase });
        const clipped = try clipSummary(scratch, child, cols);
        try out.writer.writeByte('\n');
        if (style.text_style.len > 0) try out.writer.writeAll(style.text_style);
        try out.writer.writeAll(clipped);
        if (style.text_style.len > 0) try out.writer.writeAll(style.reset_style);
    }

    for (status_indices) |status_index| {
        const entry = entries[status_index];
        const entry_id = toolStatusEntryId(entry) orelse continue;
        const detail = detailForEntry(details, detail_indices, entry_id, null) orelse continue;
        if (detail.outcome != .cancelled) continue;

        const terminal = try transcript_blocks.renderEntryToBlock(scratch, entry, cols, styles);
        if (terminal.bytes.len > 0) {
            try out.writer.writeAll("\n\n");
            try out.writer.writeAll(terminal.bytes);
        }
        terminal.deinit(scratch);
    }
    return out.toOwnedSlice();
}

fn formatExpandedChild(
    alloc: std.mem.Allocator,
    entry: TranscriptEntry,
    detail: ?*const ToolDetailRecord,
    connector: []const u8,
    cols: u16,
) ![]u8 {
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const phrase = switch (entry) {
        .raw_bytes => |raw| try normalizeStatusPhrase(scratch, raw.bytes),
        else => null,
    } orelse if (detail) |record| record.tool_name else "tool activity";
    const child = try std.fmt.allocPrint(scratch, "{s} {s}", .{ connector, phrase });
    const clipped = try clipSummary(scratch, child, cols);
    return alloc.dupe(u8, clipped);
}

fn installExpandedGroup(
    alloc: std.mem.Allocator,
    projection: *Projection,
    entries: []const TranscriptEntry,
    status_indices: []const usize,
    details: []const ToolDetailRecord,
    detail_indices: *const std.AutoHashMapUnmanaged(u32, usize),
    summary: Summary,
    cols: u16,
    style: SummaryStyle,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !void {
    const header = try formatGroupHeader(alloc, summary, cols, style);
    defer alloc.free(header);
    for (status_indices, 0..) |status_index, child_index| {
        try build_checkpoint.tick(checkpoint);
        const entry = entries[status_index];
        const entry_id = toolStatusEntryId(entry) orelse continue;
        const detail = detailForEntry(details, detail_indices, entry_id, null);
        const connector = if (child_index + 1 == status_indices.len) "└" else "├";
        const child = try formatExpandedChild(alloc, entry, detail, connector, cols);
        defer alloc.free(child);
        const bytes = if (child_index == 0)
            try std.fmt.allocPrint(alloc, "{s}\n{s}", .{ header, child })
        else
            try alloc.dupe(u8, child);
        try projection.setOwnedOverride(alloc, status_index, .tool_status, bytes);
    }
}

fn presentationGroupId(
    detail: ?*const ToolDetailRecord,
) ?types.ToolPresentationGroupId {
    const record = detail orelse return null;
    return record.presentation_group_id;
}

fn sortedDetailForEntry(
    details: []const ToolDetailRecord,
    entry_id: u32,
) ?*const ToolDetailRecord {
    var low: usize = 0;
    var high = details.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (details[middle].entry_id < entry_id) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return if (low < details.len and details[low].entry_id == entry_id)
        &details[low]
    else
        null;
}

pub fn incrementalRebuildStart(
    entries: []const TranscriptEntry,
    details: []const ToolDetailRecord,
    dirty_entry_index: usize,
) ?usize {
    if (dirty_entry_index >= entries.len) return null;
    var first = dirty_entry_index;
    const dirty_entry_id = entries[first].id();

    const dirty_group = presentationGroupId(sortedDetailForEntry(details, dirty_entry_id));
    if (dirty_group) |group_id| {
        for (entries, 0..) |entry, index| {
            const detail = sortedDetailForEntry(details, entry.id()) orelse continue;
            const candidate = detail.presentation_group_id orelse continue;
            if (candidate.turn_id != group_id.turn_id or
                candidate.anchor_step_id != group_id.anchor_step_id) continue;
            first = @min(first, index);
        }
    }

    const first_entry = entries[first];
    if (toolStatusEntryId(first_entry) == null and
        !isAttachedEntry(first_entry) and
        !isTransparentCompactEntry(first_entry)) return first;

    while (first > 0) {
        const previous = entries[first - 1];
        if (toolStatusEntryId(previous) == null and
            !isAttachedEntry(previous) and
            !isTransparentCompactEntry(previous)) break;
        first -= 1;
    }
    return first;
}

fn statusIndexLessThan(
    entries: []const TranscriptEntry,
    lhs: usize,
    rhs: usize,
) bool {
    return toolStatusEntryId(entries[lhs]).? < toolStatusEntryId(entries[rhs]).?;
}

fn hideAttachedRows(
    entries: []const TranscriptEntry,
    entry_actions: []transcript_blocks.EntryRenderAction,
    status_index: usize,
) void {
    var index = status_index + 1;
    while (index < entries.len) : (index += 1) {
        if (toolStatusEntryId(entries[index]) != null) break;
        if (isAttachedEntry(entries[index])) {
            entry_actions[index] = .hide;
            continue;
        }
        if (!isTransparentCompactEntry(entries[index])) break;
    }
}

fn build(
    alloc: std.mem.Allocator,
    entries: []const TranscriptEntry,
    details: []const ToolDetailRecord,
    cols: u16,
) !Projection {
    return buildWithStyleAndStats(alloc, entries, details, cols, null, false, .{}, .{}, .compact, null, null) catch |err| switch (err) {
        error.InputPending => unreachable,
        else => |other| return other,
    };
}

pub fn buildStyled(
    alloc: std.mem.Allocator,
    entries: []const TranscriptEntry,
    details: []const ToolDetailRecord,
    cols: u16,
    style: SummaryStyle,
    styles: transcript_blocks.Styles,
) !Projection {
    return buildWithStyleAndStats(alloc, entries, details, cols, null, false, style, styles, .compact, null, null) catch |err| switch (err) {
        error.InputPending => unreachable,
        else => |other| return other,
    };
}

pub fn buildExpandedStyledInterruptible(
    alloc: std.mem.Allocator,
    entries: []const TranscriptEntry,
    details: []const ToolDetailRecord,
    cols: u16,
    style: SummaryStyle,
    styles: transcript_blocks.Styles,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !Projection {
    return buildWithStyleAndStats(alloc, entries, details, cols, null, false, style, styles, .expanded, null, checkpoint);
}

pub fn buildExpandedRelationshipsInterruptible(
    alloc: std.mem.Allocator,
    entries: []const TranscriptEntry,
    details: []const ToolDetailRecord,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !Projection {
    return buildWithStyleAndStats(
        alloc,
        entries,
        details,
        std.math.maxInt(u16),
        null,
        false,
        .{},
        .{},
        .expanded,
        null,
        checkpoint,
    );
}

pub fn materializeExpandedRelationshipsRangeInterruptible(
    alloc: std.mem.Allocator,
    relationships: *const Projection,
    start_index: usize,
    cols: u16,
    style: SummaryStyle,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !Projection {
    std.debug.assert(start_index <= relationships.entry_actions.items.len);
    var projection: Projection = .{};
    errdefer projection.deinit(alloc);
    try projection.entry_actions.ensureTotalCapacity(
        alloc,
        relationships.entry_actions.items.len - start_index,
    );
    for (relationships.entry_actions.items[start_index..]) |action| {
        try build_checkpoint.tick(checkpoint);
        switch (action) {
            .keep => projection.entry_actions.appendAssumeCapacity(.keep),
            .hide => projection.entry_actions.appendAssumeCapacity(.hide),
            .override => |override| {
                const bytes = try materializeExpandedOverride(
                    alloc,
                    override.bytes,
                    cols,
                    style,
                );
                try projection.appendOwnedOverride(alloc, override.kind, bytes);
            },
        }
    }
    return projection;
}

fn materializeExpandedOverride(
    alloc: std.mem.Allocator,
    bytes: []const u8,
    cols: u16,
    style: SummaryStyle,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.writer.writeByte('\n');
        first = false;
        const clipped = try clipSummary(alloc, line, cols);
        defer alloc.free(clipped);
        if (std.mem.startsWith(u8, line, "●")) {
            const styled = try applySummaryStyle(alloc, clipped, style);
            defer alloc.free(styled);
            try out.writer.writeAll(styled);
        } else {
            try out.writer.writeAll(clipped);
        }
    }
    return out.toOwnedSlice();
}

pub fn buildStyledFocused(
    alloc: std.mem.Allocator,
    entries: []const TranscriptEntry,
    details: []const ToolDetailRecord,
    cols: u16,
    focused_entry_id: ?u32,
    collapse_tool_calls: bool,
    style: SummaryStyle,
    styles: transcript_blocks.Styles,
) !Projection {
    return buildStyledFocusedInterruptible(
        alloc,
        entries,
        details,
        cols,
        focused_entry_id,
        collapse_tool_calls,
        style,
        styles,
        null,
    ) catch |err| switch (err) {
        error.InputPending => unreachable,
        else => |other| return other,
    };
}

pub fn buildStyledFocusedInterruptible(
    alloc: std.mem.Allocator,
    entries: []const TranscriptEntry,
    details: []const ToolDetailRecord,
    cols: u16,
    focused_entry_id: ?u32,
    collapse_tool_calls: bool,
    style: SummaryStyle,
    styles: transcript_blocks.Styles,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !Projection {
    return buildWithStyleAndStats(
        alloc,
        entries,
        details,
        cols,
        focused_entry_id,
        collapse_tool_calls,
        style,
        styles,
        .compact,
        null,
        checkpoint,
    );
}

fn buildWithStats(
    alloc: std.mem.Allocator,
    entries: []const TranscriptEntry,
    details: []const ToolDetailRecord,
    cols: u16,
    stats: ?*BuildStats,
) !Projection {
    return buildWithStyleAndStats(alloc, entries, details, cols, null, false, .{}, .{}, .compact, stats, null);
}

fn buildWithStyleAndStats(
    alloc: std.mem.Allocator,
    entries: []const TranscriptEntry,
    details: []const ToolDetailRecord,
    cols: u16,
    focused_entry_id: ?u32,
    collapse_tool_calls: bool,
    style: SummaryStyle,
    styles: transcript_blocks.Styles,
    mode: ProjectionMode,
    stats: ?*BuildStats,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !Projection {
    var projection: Projection = .{};
    errdefer projection.deinit(alloc);
    try projection.entry_actions.appendNTimes(alloc, .keep, entries.len);
    if (mode == .compact) {
        for (entries, projection.entry_actions.items) |entry, *action| {
            switch (entry) {
                .raw_bytes => |raw| if (raw.class == .command_output) {
                    action.* = .hide;
                },
                else => {},
            }
        }
    }

    var detail_indices: std.AutoHashMapUnmanaged(u32, usize) = .empty;
    defer detail_indices.deinit(alloc);
    for (details, 0..) |detail, detail_index| {
        try build_checkpoint.tick(checkpoint);
        const result = try detail_indices.getOrPut(alloc, detail.entry_id);
        if (!result.found_existing) result.value_ptr.* = detail_index;
    }

    const presentation_group_indices = try alloc.alloc(?usize, entries.len);
    defer alloc.free(presentation_group_indices);
    @memset(presentation_group_indices, null);

    var presentation_groups: std.ArrayList(PresentationGroup) = .empty;
    defer {
        for (presentation_groups.items) |*group| group.deinit(alloc);
        presentation_groups.deinit(alloc);
    }
    var presentation_group_by_id: std.AutoHashMapUnmanaged(
        types.ToolPresentationGroupId,
        usize,
    ) = .empty;
    defer presentation_group_by_id.deinit(alloc);

    for (entries, 0..) |entry, entry_index| {
        try build_checkpoint.tick(checkpoint);
        const entry_id = toolStatusEntryId(entry) orelse continue;
        const detail = detailForEntry(details, &detail_indices, entry_id, stats);
        if (statusNamesAsk(entry, detail)) continue;
        const group_id = presentationGroupId(detail) orelse continue;

        const result = try presentation_group_by_id.getOrPut(alloc, group_id);
        if (!result.found_existing) {
            result.value_ptr.* = presentation_groups.items.len;
            try presentation_groups.append(alloc, .{ .anchor_index = entry_index });
        }
        const group_index = result.value_ptr.*;
        const group = &presentation_groups.items[group_index];
        try group.status_indices.append(alloc, entry_index);
        observeTool(&group.summary, detail);
        presentation_group_indices[entry_index] = group_index;
    }
    for (presentation_groups.items) |*group| {
        try build_checkpoint.tick(checkpoint);
        sort_utils.sort(
            usize,
            group.status_indices.items,
            entries,
            statusIndexLessThan,
        );
    }

    if (mode == .expanded) {
        for (presentation_groups.items) |*group| {
            try build_checkpoint.tick(checkpoint);
            try installExpandedGroup(
                alloc,
                &projection,
                entries,
                group.status_indices.items,
                details,
                &detail_indices,
                group.summary,
                cols,
                style,
                checkpoint,
            );
        }

        var expanded_index: usize = 0;
        while (expanded_index < entries.len) {
            try build_checkpoint.tick(checkpoint);
            if (presentation_group_indices[expanded_index] != null) {
                expanded_index += 1;
                continue;
            }
            const entry_id = toolStatusEntryId(entries[expanded_index]) orelse {
                expanded_index += 1;
                continue;
            };
            const detail = detailForEntry(details, &detail_indices, entry_id, stats);
            if (statusNamesAsk(entries[expanded_index], detail)) {
                expanded_index += 1;
                continue;
            }

            var status_indices: std.ArrayList(usize) = .empty;
            defer status_indices.deinit(alloc);
            var summary: Summary = .{};
            while (expanded_index < entries.len) : (expanded_index += 1) {
                try build_checkpoint.tick(checkpoint);
                if (presentation_group_indices[expanded_index] != null) break;
                if (toolStatusEntryId(entries[expanded_index])) |group_entry_id| {
                    const group_detail = detailForEntry(details, &detail_indices, group_entry_id, stats);
                    if (statusNamesAsk(entries[expanded_index], group_detail)) break;
                    observeTool(&summary, group_detail);
                    try status_indices.append(alloc, expanded_index);
                    continue;
                }
                if (!isAttachedEntry(entries[expanded_index]) and
                    !isTransparentCompactEntry(entries[expanded_index])) break;
            }
            try installExpandedGroup(
                alloc,
                &projection,
                entries,
                status_indices.items,
                details,
                &detail_indices,
                summary,
                cols,
                style,
                checkpoint,
            );
        }
        return projection;
    }

    var index: usize = 0;
    while (index < entries.len) {
        try build_checkpoint.tick(checkpoint);
        if (projection.entry_actions.items[index] != .keep) {
            index += 1;
            continue;
        }
        const entry_id = toolStatusEntryId(entries[index]) orelse {
            index += 1;
            continue;
        };

        if (presentation_group_indices[index]) |group_index| {
            const group = &presentation_groups.items[group_index];
            if (index != group.anchor_index) {
                projection.entry_actions.items[index] = .hide;
                index += 1;
                continue;
            }
            for (group.status_indices.items) |status_index| {
                projection.entry_actions.items[status_index] = .hide;
                hideAttachedRows(
                    entries,
                    projection.entry_actions.items,
                    status_index,
                );
            }

            const bytes = try formatGroupBlock(
                alloc,
                entries,
                group.status_indices.items,
                details,
                &detail_indices,
                group.summary,
                focused_entry_id,
                collapse_tool_calls,
                cols,
                style,
                styles,
            );
            try projection.setOwnedOverride(alloc, index, .tool_status, bytes);
            index += 1;
            continue;
        }

        const detail = detailForEntry(details, &detail_indices, entry_id, stats);
        if (statusNamesAsk(entries[index], detail)) {
            index += 1;
            continue;
        }

        const first_index = index;
        var status_indices: std.ArrayList(usize) = .empty;
        defer status_indices.deinit(alloc);
        var summary: Summary = .{};

        while (index < entries.len) : (index += 1) {
            try build_checkpoint.tick(checkpoint);
            if (presentation_group_indices[index] != null) break;
            if (toolStatusEntryId(entries[index])) |group_entry_id| {
                const group_detail = detailForEntry(details, &detail_indices, group_entry_id, stats);
                if (statusNamesAsk(entries[index], group_detail)) break;
                observeTool(&summary, group_detail);
                try status_indices.append(alloc, index);
                projection.entry_actions.items[index] = .hide;
                continue;
            }
            if (isAttachedEntry(entries[index])) {
                projection.entry_actions.items[index] = .hide;
                continue;
            }
            if (!isTransparentCompactEntry(entries[index])) break;
        }

        const bytes = try formatGroupBlock(
            alloc,
            entries,
            status_indices.items,
            details,
            &detail_indices,
            summary,
            focused_entry_id,
            collapse_tool_calls,
            cols,
            style,
            styles,
        );
        try projection.setOwnedOverride(alloc, first_index, .tool_status, bytes);
    }

    return projection;
}

test "collapsed tool groups render only the summary header" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = @constCast("● Read file\n"), .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = @constCast("● List files\n"), .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("read_file"), .activity_kind = .read },
        .{ .entry_id = 2, .tool_name = @constCast("list_files"), .activity_kind = .list },
    };

    var projection = try buildStyledFocused(alloc, &entries, &details, 120, null, true, .{}, .{});
    defer projection.deinit(alloc);
    const block = projection.entry_actions.items[0].override.bytes;
    try std.testing.expect(std.mem.find(u8, block, "2 tool calls") != null);
    try std.testing.expect(std.mem.find(u8, block, "Read file") == null);
    try std.testing.expect(projection.entry_actions.items[1] == .hide);
}

test "tool relationship grouping retries cleanly after cancellation" {
    const alloc = std.testing.allocator;
    const entries = try alloc.alloc(TranscriptEntry, 5_000);
    defer alloc.free(entries);
    for (entries, 0..) |*entry, index| {
        entry.* = .{ .raw_bytes = .{
            .id = @intCast(index + 1),
            .bytes = @constCast("retained\n"),
        } };
    }
    const Probe = struct {
        fn pending(_: *anyopaque) bool {
            return true;
        }
    };
    var context: u8 = 0;
    var checkpoint = build_checkpoint.BuildCheckpoint.init(&context, Probe.pending);

    try std.testing.expectError(
        error.InputPending,
        buildExpandedRelationshipsInterruptible(alloc, entries, &.{}, &checkpoint),
    );
    var retry = try buildExpandedRelationshipsInterruptible(alloc, entries, &.{}, null);
    defer retry.deinit(alloc);
    try std.testing.expectEqual(entries.len, retry.entry_actions.items.len);
    try std.testing.expect(retry.entry_actions.items[0] == .keep);
    try std.testing.expect(retry.entry_actions.items[entries.len - 1] == .keep);
}

test "minimal tool group summary uses semantic category order and outcomes" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Read runtime.zig\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "● Edited main.zig\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 3, .bytes = "● Ran zig build\n", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("read_file"), .activity_kind = .read, .outcome = .completed },
        .{ .entry_id = 2, .tool_name = @constCast("edit_file"), .activity_kind = .edit, .outcome = .failed },
        .{ .entry_id = 3, .tool_name = @constCast("run_command"), .activity_kind = .command, .outcome = .completed },
    };

    var projection = try build(alloc, &entries, &details, 120);
    defer projection.deinit(alloc);

    try std.testing.expect(projection.entry_actions.items[0] == .override);
    try std.testing.expectEqualStrings(
        "● 3 tool calls · 1 read · 1 edit · 1 command · 1 failed\n" ++
            "├ Read runtime.zig\n" ++
            "├ Edited main.zig\n" ++
            "└ Ran zig build",
        projection.entry_actions.items[0].override.bytes,
    );
    try std.testing.expect(projection.entry_actions.items[1] == .hide);
    try std.testing.expect(projection.entry_actions.items[2] == .hide);
    try std.testing.expectEqual(types.ToolActivityKind.read, details[0].activity_kind.?);
}

test "small minimal tool groups surface canonical action targets" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Read\x1b[0m \x1b[38;5;245mruntime.zig\x1b[0m\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "● Searched\x1b[0m \x1b[38;5;245msnapshot\x1b[0m\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 3, .bytes = "● Editing\x1b[0m \x1b[38;5;245mstore.zig\x1b[0m\n", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("read_file"), .activity_kind = .read, .outcome = .completed },
        .{ .entry_id = 2, .tool_name = @constCast("grep_files"), .activity_kind = .read, .outcome = .completed },
        .{ .entry_id = 3, .tool_name = @constCast("edit_file"), .activity_kind = .edit, .outcome = null },
    };

    var projection = try build(alloc, &entries, &details, 120);
    defer projection.deinit(alloc);

    try std.testing.expectEqualStrings(
        "● 3 tool calls · 2 read · 1 edit\n" ++
            "├ Read runtime.zig\n" ++
            "├ Searched snapshot\n" ++
            "└ Editing store.zig",
        projection.entry_actions.items[0].override.bytes,
    );
}

test "minimal tool groups preserve denied and deferred action text" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "⊘ Denied by auto agent zig build\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "↻ Context updated runtime.zig\n", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("terminal"), .activity_kind = .command, .outcome = .denied },
        .{ .entry_id = 2, .tool_name = @constCast("read_file"), .activity_kind = .read, .outcome = .deferred },
    };

    var projection = try build(alloc, &entries, &details, 120);
    defer projection.deinit(alloc);

    try std.testing.expectEqualStrings(
        "● 2 tool calls · 1 read · 1 command · 1 denied · 1 deferred\n" ++
            "├ Denied by auto agent zig build\n" ++
            "└ Context updated runtime.zig",
        projection.entry_actions.items[0].override.bytes,
    );
}

test "focused tool remains counted but is omitted from stable child rows" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Read runtime.zig\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "● Running zig build test\n", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("read_file"), .activity_kind = .read, .outcome = .completed },
        .{ .entry_id = 2, .tool_name = @constCast("run_command"), .activity_kind = .command },
    };

    var projection = try buildStyledFocused(alloc, &entries, &details, 120, 2, false, .{}, .{});
    defer projection.deinit(alloc);

    try std.testing.expectEqualStrings(
        "● 2 tool calls · 1 read · 1 command\n├ Read runtime.zig",
        projection.entry_actions.items[0].override.bytes,
    );
    try std.testing.expect(projection.entry_actions.items[1] == .hide);
}

test "minimal command details expose running completed and failed process states" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Running\x1b[0m \x1b[38;5;245mrg snapshot\x1b[0m\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "● Ran\x1b[0m \x1b[38;5;245mzig build\x1b[0m\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 3, .bytes = "● Ran\x1b[0m \x1b[38;5;245mzig build test\x1b[0m\n", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("run_command"), .activity_kind = .command, .outcome = null },
        .{ .entry_id = 2, .tool_name = @constCast("run_command"), .activity_kind = .command, .outcome = .completed, .command_process_presentation = .{ .exit_code = 0 } },
        .{ .entry_id = 3, .tool_name = @constCast("run_command"), .activity_kind = .command, .outcome = .completed, .command_process_presentation = .{ .exit_code = 7 } },
    };

    var projection = try build(alloc, &entries, &details, 120);
    defer projection.deinit(alloc);

    try std.testing.expectEqualStrings(
        "● 3 tool calls · 3 commands · 1 failed\n" ++
            "├ Running rg snapshot\n" ++
            "├ Ran zig build\n" ++
            "└ Ran zig build test",
        projection.entry_actions.items[0].override.bytes,
    );
}

test "minimal command timeout uses its typed cause in the row and group" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Timed out sleep 5\n", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{
            .entry_id = 1,
            .tool_name = @constCast("run_command"),
            .activity_kind = .command,
            .outcome = .failed,
            .command_process_presentation = .timed_out,
        },
    };

    var projection = try build(alloc, &entries, &details, 120);
    defer projection.deinit(alloc);

    try std.testing.expectEqualStrings(
        "● 1 tool call · 1 command · 1 timed out\n" ++
            "└ Timed out sleep 5",
        projection.entry_actions.items[0].override.bytes,
    );
}

test "tool-heavy groups render every canonical action" {
    const alloc = std.testing.allocator;
    const tool_count = 20;
    var entries: [tool_count]TranscriptEntry = undefined;
    var details: [tool_count]ToolDetailRecord = undefined;

    for (&entries, &details, 0..) |*entry, *detail, index| {
        const entry_id: u32 = @intCast(index + 1);
        const is_command = index >= 10 and index < 18;
        const is_edit = index >= 18;
        const is_failed_command = index == 17;
        const is_current_edit = index == 19;
        entry.* = .{ .raw_bytes = .{
            .id = entry_id,
            .bytes = if (is_failed_command)
                @constCast("● Ran\x1b[0m \x1b[38;5;245mrg snapshot\x1b[0m\n")
            else if (is_current_edit)
                @constCast("● Editing\x1b[0m \x1b[38;5;245mruntime.zig\x1b[0m\n")
            else if (is_command)
                @constCast("● Ran\x1b[0m \x1b[38;5;245mzig build\x1b[0m\n")
            else if (is_edit)
                @constCast("● Edited\x1b[0m \x1b[38;5;245mstore.zig\x1b[0m\n")
            else
                @constCast("● Read\x1b[0m \x1b[38;5;245mfile.zig\x1b[0m\n"),
            .class = .tool_status,
        } };
        detail.* = .{
            .entry_id = entry_id,
            .tool_name = if (is_command) @constCast("run_command") else if (is_edit) @constCast("edit_file") else @constCast("read_file"),
            .activity_kind = if (is_command) .command else if (is_edit) .edit else .read,
            .outcome = if (is_current_edit) null else .completed,
            .command_process_presentation = if (is_command)
                if (is_failed_command) .{ .exit_code = 1 } else .{ .exit_code = 0 }
            else
                null,
        };
    }

    var projection = try build(alloc, &entries, &details, 100);
    defer projection.deinit(alloc);
    const summary = projection.entry_actions.items[0].override.bytes;

    try std.testing.expect(std.mem.find(u8, summary, "20 tool calls") != null);
    try std.testing.expect(std.mem.find(u8, summary, "10 read") != null);
    try std.testing.expect(std.mem.find(u8, summary, "8 commands") != null);
    try std.testing.expect(std.mem.find(u8, summary, "1 failed") != null);
    try std.testing.expect(std.mem.find(u8, summary, "Ran rg snapshot") != null);
    try std.testing.expect(std.mem.find(u8, summary, "Editing runtime.zig") != null);
    try std.testing.expectEqual(@as(usize, tool_count), std.mem.count(u8, summary, "\n"));
    var lines = std.mem.splitScalar(u8, summary, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= 100);
    }

    entries[19].raw_bytes.bytes = @constCast("● Edited\x1b[0m \x1b[38;5;245mruntime.zig\x1b[0m\n");
    details[19].outcome = .completed;
    var completed_projection = try build(alloc, &entries, &details, 100);
    defer completed_projection.deinit(alloc);
    const completed_summary = completed_projection.entry_actions.items[0].override.bytes;

    try std.testing.expect(std.mem.find(u8, completed_summary, "Edited runtime.zig") != null);
    try std.testing.expectEqual(@as(usize, tool_count), std.mem.count(u8, completed_summary, "\n"));
}

test "minimal tool group keeps cancellation in the header and child row" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "■ Cancelled sleep 30 · What can fx do differently?", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("run_command"), .activity_kind = .command, .outcome = .cancelled },
    };
    var projection = try buildStyled(alloc, &entries, &details, 120, .{}, .{});
    defer projection.deinit(alloc);

    try std.testing.expect(projection.entry_actions.items[0] == .override);
    try std.testing.expectEqualStrings(
        "● 1 tool call · 1 command · 1 cancelled\n" ++
            "└ Cancelled sleep 30\n\n" ++
            "■ Cancelled sleep 30 · What can fx do differently?",
        projection.entry_actions.items[0].override.bytes,
    );
}

test "minimal tool group clips cancellation to one child row" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{
            .id = 1,
            .bytes = "■ Cancelled sleep waiting command words extend past line two",
            .class = .tool_status,
        } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("run_command"), .activity_kind = .command, .outcome = .cancelled },
    };

    var projection = try build(alloc, &entries, &details, 24);
    defer projection.deinit(alloc);

    const bytes = projection.entry_actions.items[0].override.bytes;
    const gap = std.mem.find(u8, bytes, "\n\n") orelse return error.TestExpectedEqual;
    var group_lines = std.mem.splitScalar(u8, bytes[0..gap], '\n');
    var group_line_count: usize = 0;
    while (group_lines.next()) |line| {
        group_line_count += 1;
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= 24);
    }
    try std.testing.expectEqual(@as(usize, 2), group_line_count);

    var feedback_lines = std.mem.splitScalar(u8, bytes[gap + 2 ..], '\n');
    while (feedback_lines.next()) |line| {
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= 24);
    }
}

test "minimal tool group keeps later cancelled rows and hides other details" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "read", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "cancelled", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 3, .bytes = "output", .class = .command_output } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("read_file"), .activity_kind = .read, .outcome = .completed },
        .{ .entry_id = 2, .tool_name = @constCast("run_command"), .activity_kind = .command, .outcome = .cancelled },
    };

    var projection = try build(alloc, &entries, &details, 120);
    defer projection.deinit(alloc);

    try std.testing.expect(projection.entry_actions.items[0] == .override);
    try std.testing.expect(projection.entry_actions.items[1] == .hide);
    try std.testing.expect(projection.entry_actions.items[2] == .hide);
}

test "cancelled actions remain inside the message-delimited block" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "■ Cancelled first", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "■ Cancelled second", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 3, .bytes = "output", .class = .command_output } },
        .{ .raw_bytes = .{ .id = 4, .bytes = "read", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("run_command"), .activity_kind = .command, .outcome = .cancelled },
        .{ .entry_id = 2, .tool_name = @constCast("run_command"), .activity_kind = .command, .outcome = .cancelled },
        .{ .entry_id = 4, .tool_name = @constCast("read_file"), .activity_kind = .read, .outcome = .completed },
    };

    var projection = try build(alloc, &entries, &details, 120);
    defer projection.deinit(alloc);

    try std.testing.expect(projection.entry_actions.items[0] == .override);
    try std.testing.expect(std.mem.find(u8, projection.entry_actions.items[0].override.bytes, "├ Cancelled first") != null);
    try std.testing.expect(std.mem.find(u8, projection.entry_actions.items[0].override.bytes, "├ Cancelled second") != null);
    try std.testing.expect(projection.entry_actions.items[1] == .hide);
    try std.testing.expect(projection.entry_actions.items[2] == .hide);
    try std.testing.expect(projection.entry_actions.items[3] == .hide);
}

test "assistant prose splits tool groups and attached rows stay inside their group" {
    const alloc = std.testing.allocator;
    var entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "command", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "output", .class = .command_output } },
        .{ .raw_bytes = .{ .id = 3, .bytes = "diff", .class = .diff_block } },
        .{ .assistant_turn = .{ .id = 4, .segments = .{} } },
        .{ .raw_bytes = .{ .id = 5, .bytes = "read", .class = .tool_status } },
    };
    try entries[3].assistant_turn.segments.text.appendSlice(alloc, "assistant message");
    defer entries[3].assistant_turn.segments.deinit(alloc);
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("run_command"), .activity_kind = .command, .outcome = .completed },
        .{ .entry_id = 5, .tool_name = @constCast("read_file"), .activity_kind = .read, .outcome = .completed },
    };

    var projection = try build(alloc, &entries, &details, 120);
    defer projection.deinit(alloc);

    try std.testing.expect(projection.entry_actions.items[0] == .override);
    try std.testing.expect(projection.entry_actions.items[1] == .hide);
    try std.testing.expect(projection.entry_actions.items[2] == .hide);
    try std.testing.expect(projection.entry_actions.items[3] == .keep);
    try std.testing.expect(projection.entry_actions.items[4] == .override);
}

test "minimal hides command output separated from its tool status" {
    const alloc = std.testing.allocator;
    var entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "command", .class = .tool_status } },
        .{ .assistant_turn = .{ .id = 2, .segments = .{} } },
        .{ .raw_bytes = .{ .id = 3, .bytes = "output", .class = .command_output } },
        .{ .raw_bytes = .{ .id = 4, .bytes = "diff", .class = .diff_block } },
    };
    try entries[1].assistant_turn.segments.text.appendSlice(alloc, "provider bridge");
    defer entries[1].assistant_turn.segments.deinit(alloc);
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("run_command"), .activity_kind = .command, .outcome = .completed },
    };

    var projection = try build(alloc, &entries, &details, 120);
    defer projection.deinit(alloc);

    try std.testing.expect(projection.entry_actions.items[0] == .override);
    try std.testing.expect(projection.entry_actions.items[1] == .keep);
    try std.testing.expect(projection.entry_actions.items[2] == .hide);
    try std.testing.expect(projection.entry_actions.items[3] == .keep);
}

test "one presentation group keeps sibling tools in creation order across assistant prose" {
    const alloc = std.testing.allocator;
    var entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 3, .bytes = "● Running second", .class = .tool_status } },
        .{ .assistant_turn = .{ .id = 2, .segments = .{} } },
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Running first", .class = .tool_status } },
    };
    try entries[1].assistant_turn.segments.text.appendSlice(alloc, "provider bridge");
    defer entries[1].assistant_turn.segments.deinit(alloc);
    const details = [_]ToolDetailRecord{
        .{
            .entry_id = 1,
            .tool_name = @constCast("run_command"),
            .activity_kind = .command,
            .lifecycle_id = .{ .turn_id = 7, .call_id = @constCast("first") },
            .presentation_group_id = .{ .turn_id = 7, .anchor_step_id = 11 },
        },
        .{
            .entry_id = 3,
            .tool_name = @constCast("run_command"),
            .activity_kind = .command,
            .lifecycle_id = .{ .turn_id = 7, .call_id = @constCast("second") },
            .presentation_group_id = .{ .turn_id = 7, .anchor_step_id = 11 },
        },
    };

    var projection = try build(alloc, &entries, &details, 120);
    defer projection.deinit(alloc);

    try std.testing.expectEqualStrings(
        "● 2 tool calls · 2 commands\n" ++
            "├ Running first\n" ++
            "└ Running second",
        projection.entry_actions.items[0].override.bytes,
    );
    try std.testing.expect(projection.entry_actions.items[1] == .keep);
    try std.testing.expect(projection.entry_actions.items[2] == .hide);
}

test "different presentation groups remain separate within one turn" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Read first", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "● Read second", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{
            .entry_id = 1,
            .tool_name = @constCast("read_file"),
            .activity_kind = .read,
            .lifecycle_id = .{ .turn_id = 7, .call_id = @constCast("first") },
            .presentation_group_id = .{ .turn_id = 7, .anchor_step_id = 11 },
        },
        .{
            .entry_id = 2,
            .tool_name = @constCast("read_file"),
            .activity_kind = .read,
            .lifecycle_id = .{ .turn_id = 7, .call_id = @constCast("second") },
            .presentation_group_id = .{ .turn_id = 7, .anchor_step_id = 12 },
        },
    };

    var projection = try build(alloc, &entries, &details, 120);
    defer projection.deinit(alloc);

    try std.testing.expectEqualStrings(
        "● 1 tool call · 1 read\n└ Read first",
        projection.entry_actions.items[0].override.bytes,
    );
    try std.testing.expectEqualStrings(
        "● 1 tool call · 1 read\n└ Read second",
        projection.entry_actions.items[1].override.bytes,
    );
}

test "legacy lifecycle records without group identity respect transcript boundaries" {
    const alloc = std.testing.allocator;
    var entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Read first", .class = .tool_status } },
        .{ .assistant_turn = .{ .id = 2, .segments = .{} } },
        .{ .raw_bytes = .{ .id = 3, .bytes = "● Running second", .class = .tool_status } },
    };
    try entries[1].assistant_turn.segments.text.appendSlice(alloc, "next model step");
    defer entries[1].assistant_turn.segments.deinit(alloc);
    const details = [_]ToolDetailRecord{
        .{
            .entry_id = 1,
            .tool_name = @constCast("read_file"),
            .activity_kind = .read,
            .lifecycle_id = .{ .turn_id = 7, .call_id = @constCast("first") },
        },
        .{
            .entry_id = 3,
            .tool_name = @constCast("run_command"),
            .activity_kind = .command,
            .lifecycle_id = .{ .turn_id = 7, .call_id = @constCast("second") },
        },
    };

    var projection = try build(alloc, &entries, &details, 120);
    defer projection.deinit(alloc);

    try std.testing.expectEqualStrings(
        "● 1 tool call · 1 read\n└ Read first",
        projection.entry_actions.items[0].override.bytes,
    );
    try std.testing.expect(projection.entry_actions.items[1] == .keep);
    try std.testing.expectEqualStrings(
        "● 1 tool call · 1 command\n└ Running second",
        projection.entry_actions.items[2].override.bytes,
    );
}

fn checkPresentationGroupingAllocationFailures(alloc: std.mem.Allocator) !void {
    var entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 2, .bytes = "● Running second", .class = .tool_status } },
        .{ .assistant_turn = .{ .id = 3, .segments = .{} } },
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Running first", .class = .tool_status } },
    };
    try entries[1].assistant_turn.segments.text.appendSlice(alloc, "provider bridge");
    defer entries[1].assistant_turn.segments.deinit(alloc);
    const details = [_]ToolDetailRecord{
        .{
            .entry_id = 1,
            .tool_name = @constCast("run_command"),
            .activity_kind = .command,
            .lifecycle_id = .{ .turn_id = 7, .call_id = @constCast("first") },
            .presentation_group_id = .{ .turn_id = 7, .anchor_step_id = 11 },
        },
        .{
            .entry_id = 2,
            .tool_name = @constCast("run_command"),
            .activity_kind = .command,
            .lifecycle_id = .{ .turn_id = 7, .call_id = @constCast("second") },
            .presentation_group_id = .{ .turn_id = 7, .anchor_step_id = 11 },
        },
    };

    var projection = build(alloc, &entries, &details, 120) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer projection.deinit(alloc);
    try std.testing.expectEqualStrings(
        "● 2 tool calls · 2 commands\n" ++
            "├ Running first\n" ++
            "└ Running second",
        projection.entry_actions.items[0].override.bytes,
    );
}

test "presentation grouping is atomic across allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkPresentationGroupingAllocationFailures,
        .{},
    );
}

test "entries hidden by compact presentation do not split tool groups" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "read", .class = .tool_status } },
        .{ .assistant_turn = .{ .id = 2, .segments = .{} } },
        .{ .semantic_notice = .{
            .id = 3,
            .topic = "context",
            .tone = .warning,
            .body = "hidden",
            .visibility = .full_only,
        } },
        .{ .raw_bytes = .{ .id = 4, .bytes = "edit", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("read_file"), .activity_kind = .read, .outcome = .completed },
        .{ .entry_id = 4, .tool_name = @constCast("edit_file"), .activity_kind = .edit, .outcome = .completed },
    };

    var projection = try build(alloc, &entries, &details, 120);
    defer projection.deinit(alloc);

    try std.testing.expect(projection.entry_actions.items[0] == .override);
    try std.testing.expectEqualStrings(
        "● 2 tool calls · 1 read · 1 edit\n" ++
            "├ read_file\n" ++
            "└ edit_file",
        projection.entry_actions.items[0].override.bytes,
    );
    try std.testing.expect(projection.entry_actions.items[1] == .keep);
    try std.testing.expect(projection.entry_actions.items[2] == .keep);
    try std.testing.expect(projection.entry_actions.items[3] == .hide);
}

test "visible assistant messages split groups while silent entries do not" {
    const alloc = std.testing.allocator;
    var entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "read one", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "read two", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 3, .bytes = "read three", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 4, .bytes = "list one", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 5, .bytes = "list two", .class = .tool_status } },
        .{ .assistant_turn = .{ .id = 6, .segments = .{} } },
        .{ .raw_bytes = .{ .id = 7, .bytes = "command one", .class = .tool_status } },
        .{ .assistant_turn = .{ .id = 8, .segments = .{} } },
        .{ .raw_bytes = .{ .id = 9, .bytes = "read four", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 10, .bytes = "read five", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 11, .bytes = "read six", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 12, .bytes = "command two", .class = .tool_status } },
    };
    try entries[5].assistant_turn.segments.text.appendSlice(alloc, "permission feedback");
    defer entries[5].assistant_turn.segments.deinit(alloc);
    try entries[7].assistant_turn.segments.text.appendSlice(alloc, "next model step");
    defer entries[7].assistant_turn.segments.deinit(alloc);

    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("read_file"), .activity_kind = .read, .outcome = .completed },
        .{ .entry_id = 2, .tool_name = @constCast("read_file"), .activity_kind = .read, .outcome = .completed },
        .{ .entry_id = 3, .tool_name = @constCast("read_file"), .activity_kind = .read, .outcome = .completed },
        .{ .entry_id = 4, .tool_name = @constCast("glob_files"), .activity_kind = .list, .outcome = .completed },
        .{ .entry_id = 5, .tool_name = @constCast("glob_files"), .activity_kind = .list, .outcome = .completed },
        .{ .entry_id = 7, .tool_name = @constCast("run_command"), .activity_kind = .command, .outcome = .completed },
        .{ .entry_id = 9, .tool_name = @constCast("read_file"), .activity_kind = .read, .outcome = .completed },
        .{ .entry_id = 10, .tool_name = @constCast("read_file"), .activity_kind = .read, .outcome = .completed },
        .{ .entry_id = 11, .tool_name = @constCast("read_file"), .activity_kind = .read, .outcome = .completed },
        .{ .entry_id = 12, .tool_name = @constCast("run_command"), .activity_kind = .command, .outcome = .completed },
    };

    var projection = try build(alloc, &entries, &details, 120);
    defer projection.deinit(alloc);

    try std.testing.expectEqualStrings(
        "● 5 tool calls · 3 read · 2 list\n" ++
            "├ read_file\n├ read_file\n├ read_file\n├ glob_files\n└ glob_files",
        projection.entry_actions.items[0].override.bytes,
    );
    for (projection.entry_actions.items[1..5]) |action| {
        try std.testing.expect(action == .hide);
    }
    try std.testing.expect(projection.entry_actions.items[5] == .keep);
    try std.testing.expect(projection.entry_actions.items[6] == .override);
    try std.testing.expect(projection.entry_actions.items[7] == .keep);
    try std.testing.expectEqualStrings(
        "● 4 tool calls · 3 read · 1 command\n" ++
            "├ read_file\n├ read_file\n├ read_file\n└ run_command",
        projection.entry_actions.items[8].override.bytes,
    );
    for (projection.entry_actions.items[9..12]) |action| {
        try std.testing.expect(action == .hide);
    }
}

test "message-delimited groups hide attached detail across compact-only entries" {
    const alloc = std.testing.allocator;
    var entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "command", .class = .tool_status } },
        .{ .semantic_notice = .{
            .id = 2,
            .topic = "permission",
            .tone = .information,
            .body = "full detail",
            .visibility = .full_only,
        } },
        .{ .raw_bytes = .{ .id = 3, .bytes = "diff", .class = .diff_block } },
        .{ .assistant_turn = .{ .id = 4, .segments = .{} } },
        .{ .raw_bytes = .{ .id = 5, .bytes = "read", .class = .tool_status } },
    };
    try entries[3].assistant_turn.segments.text.appendSlice(alloc, "visible message");
    defer entries[3].assistant_turn.segments.deinit(alloc);
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("run_command"), .activity_kind = .command, .outcome = .completed },
        .{ .entry_id = 5, .tool_name = @constCast("read_file"), .activity_kind = .read, .outcome = .completed },
    };

    var projection = try build(alloc, &entries, &details, 120);
    defer projection.deinit(alloc);

    try std.testing.expect(projection.entry_actions.items[0] == .override);
    try std.testing.expect(projection.entry_actions.items[1] == .keep);
    try std.testing.expect(projection.entry_actions.items[2] == .hide);
    try std.testing.expect(projection.entry_actions.items[3] == .keep);
    try std.testing.expect(projection.entry_actions.items[4] == .override);
}

test "ask activity remains outside tool groups" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "question", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "read", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("ask_user_question"), .activity_kind = .ask, .outcome = .completed },
        .{ .entry_id = 2, .tool_name = @constCast("read_file"), .activity_kind = .read, .outcome = null },
    };

    var projection = try build(alloc, &entries, &details, 120);
    defer projection.deinit(alloc);

    try std.testing.expect(projection.entry_actions.items[0] == .keep);
    try std.testing.expect(projection.entry_actions.items[1] == .override);
    try std.testing.expectEqualStrings(
        "● 1 tool call · 1 read\n└ read_file",
        projection.entry_actions.items[1].override.bytes,
    );
}

test "ask activity remains outside tool groups without complete detail metadata" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Reading /tmp/ask_user_question", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "● ask_user_question\x1b[0m\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 3, .bytes = "read", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 4, .bytes = "● ask_user_question", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 3, .tool_name = @constCast("read_file"), .activity_kind = .read, .outcome = .completed },
        .{ .entry_id = 4, .tool_name = @constCast("ask_user_question"), .activity_kind = null, .outcome = .failed },
    };

    var projection = try build(alloc, &entries, &details, 120);
    defer projection.deinit(alloc);

    try std.testing.expect(projection.entry_actions.items[0] == .override);
    try std.testing.expect(projection.entry_actions.items[1] == .keep);
    try std.testing.expect(projection.entry_actions.items[2] == .override);
    try std.testing.expect(projection.entry_actions.items[3] == .keep);
    try std.testing.expectEqualStrings(
        "● 1 tool call\n└ Reading /tmp/ask_user_question",
        projection.entry_actions.items[0].override.bytes,
    );
    try std.testing.expectEqualStrings(
        "● 1 tool call · 1 read\n└ read_file",
        projection.entry_actions.items[2].override.bytes,
    );
}

test "narrow block clips every row without wrapping" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "read", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "edit", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 3, .bytes = "command", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("read_file"), .activity_kind = .read, .outcome = .completed },
        .{ .entry_id = 2, .tool_name = @constCast("edit_file"), .activity_kind = .edit, .outcome = .failed },
        .{ .entry_id = 3, .tool_name = @constCast("run_command"), .activity_kind = .command, .outcome = .completed },
    };
    var projection = try build(alloc, &entries, &details, 45);
    defer projection.deinit(alloc);

    const block = projection.entry_actions.items[0].override.bytes;
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, block, "\n"));
    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= 45);
    }
}

test "mixed group keeps the count header before every action" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Read one.zig", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "● Read two.zig", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 3, .bytes = "● Read three.zig", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 4, .bytes = "● Read four.zig", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 5, .bytes = "● Read five.zig", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 6, .bytes = "● Ran git -C /workspace status --short", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("read_file"), .activity_kind = .read, .outcome = .completed },
        .{ .entry_id = 2, .tool_name = @constCast("read_file"), .activity_kind = .read, .outcome = .completed },
        .{ .entry_id = 3, .tool_name = @constCast("read_file"), .activity_kind = .read, .outcome = .completed },
        .{ .entry_id = 4, .tool_name = @constCast("read_file"), .activity_kind = .read, .outcome = .completed },
        .{ .entry_id = 5, .tool_name = @constCast("read_file"), .activity_kind = .read, .outcome = .completed },
        .{ .entry_id = 6, .tool_name = @constCast("run_command"), .activity_kind = .command, .outcome = .completed, .command_process_presentation = .{ .exit_code = 0 } },
    };

    var projection = try build(alloc, &entries, &details, 60);
    defer projection.deinit(alloc);

    try std.testing.expectEqualStrings(
        "● 6 tool calls · 5 read · 1 command\n" ++
            "├ Read one.zig\n" ++
            "├ Read two.zig\n" ++
            "├ Read three.zig\n" ++
            "├ Read four.zig\n" ++
            "├ Read five.zig\n" ++
            "└ Ran git -C /workspace status --short",
        projection.entry_actions.items[0].override.bytes,
    );
}

test "styled minimal summary preserves the clipped width" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "read", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("read_file"), .activity_kind = .read },
    };

    var projection = try buildStyled(alloc, &entries, &details, 2, .{
        .marker_style = "\x1b[38;5;81m",
        .text_style = "\x1b[1;3m",
        .reset_style = "\x1b[0m",
    }, .{});
    defer projection.deinit(alloc);
    const summary = projection.entry_actions.items[0].override.bytes;

    var lines = std.mem.splitScalar(u8, summary, '\n');
    var line_count: usize = 0;
    while (lines.next()) |line| {
        line_count += 1;
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= 2);
    }
    try std.testing.expectEqual(@as(usize, 2), line_count);
}

test "expanded tool title stays primary while the group summary stays secondary" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "Listed .", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("glob_files"), .activity_kind = .list },
    };

    var projection = try buildExpandedStyledInterruptible(alloc, &entries, &details, 80, .{
        .marker_style = "<marker>",
        .text_style = "<secondary>",
        .reset_style = "<reset>",
    }, .{}, null);
    defer projection.deinit(alloc);
    const expanded = projection.entry_actions.items[0].override.bytes;

    try std.testing.expect(std.mem.find(u8, expanded, "<secondary>1 tool call · 1 list<reset>") != null);
    try std.testing.expect(std.mem.find(u8, expanded, "\n└ Listed .") != null);
    try std.testing.expect(std.mem.find(u8, expanded, "\n│\n") == null);
    try std.testing.expect(std.mem.find(u8, expanded, "<secondary>└ Listed .") == null);
}

test "expanded tool relationships materialize at multiple widths" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "Listed .", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("glob_files"), .activity_kind = .list },
    };
    const style = SummaryStyle{
        .marker_style = "\x1b[38;5;81m",
        .text_style = "\x1b[1;3m",
        .reset_style = "\x1b[0m",
    };

    var relationships = try buildExpandedRelationshipsInterruptible(
        alloc,
        &entries,
        &details,
        null,
    );
    defer relationships.deinit(alloc);
    var narrow = try materializeExpandedRelationshipsRangeInterruptible(
        alloc,
        &relationships,
        0,
        2,
        style,
        null,
    );
    defer narrow.deinit(alloc);
    var wide = try materializeExpandedRelationshipsRangeInterruptible(
        alloc,
        &relationships,
        0,
        80,
        style,
        null,
    );
    defer wide.deinit(alloc);

    var narrow_lines = std.mem.splitScalar(u8, narrow.entry_actions.items[0].override.bytes, '\n');
    while (narrow_lines.next()) |line| {
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= 2);
    }
    try std.testing.expectEqualStrings(
        "\x1b[38;5;81m●\x1b[0m \x1b[1;3m1 tool call · 1 list\x1b[0m\n└ Listed .",
        wide.entry_actions.items[0].override.bytes,
    );
}

test "ordinary append does not reopen a retained tool run" {
    const alloc = std.testing.allocator;
    const retained_count = 5_000;
    const entries = try alloc.alloc(TranscriptEntry, retained_count + 1);
    defer alloc.free(entries);
    for (entries[0..retained_count], 0..) |*entry, index| {
        entry.* = .{ .raw_bytes = .{
            .id = @intCast(index),
            .bytes = "● Read file.zig\n",
            .class = .tool_status,
        } };
    }
    entries[retained_count] = .{ .raw_bytes = .{
        .id = @intCast(retained_count),
        .bytes = "new message\n",
    } };

    try std.testing.expectEqual(
        retained_count,
        incrementalRebuildStart(entries, &.{}, @intCast(retained_count)).?,
    );
}

test "incremental rebuild uses transcript order after lifecycle reposition" {
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 2, .bytes = "second\n" } },
        .{ .raw_bytes = .{ .id = 3, .bytes = "third\n" } },
        .{ .raw_bytes = .{ .id = 1, .bytes = "repositioned\n" } },
    };

    try std.testing.expectEqual(
        @as(usize, 2),
        incrementalRebuildStart(&entries, &.{}, 2).?,
    );
}

test "tool-heavy projection performs a bounded number of indexed detail lookups" {
    const alloc = std.testing.allocator;
    const tool_count = 2_000;
    const entries = try alloc.alloc(TranscriptEntry, tool_count);
    defer alloc.free(entries);
    const details = try alloc.alloc(ToolDetailRecord, tool_count);
    defer alloc.free(details);

    for (entries, details, 0..) |*entry, *detail, index| {
        const entry_id: u32 = @intCast(index + 1);
        entry.* = .{ .raw_bytes = .{
            .id = entry_id,
            .bytes = @constCast("tool"),
            .class = .tool_status,
        } };
        detail.* = .{
            .entry_id = entry_id,
            .tool_name = @constCast("read_file"),
            .activity_kind = .read,
            .outcome = .completed,
        };
    }

    var stats: BuildStats = .{};
    var projection = try buildWithStats(alloc, entries, details, 120, &stats);
    defer projection.deinit(alloc);

    try std.testing.expectEqual(tool_count, projection.entry_actions.items.len);
    try std.testing.expect(projection.entry_actions.items[0] == .override);
    try std.testing.expect(projection.entry_actions.items[tool_count - 1] == .hide);
    try std.testing.expect(stats.detail_lookups <= tool_count * 3);
}

test "many presentation groups perform a bounded number of indexed detail lookups" {
    const alloc = std.testing.allocator;
    const tool_count = 200;
    const entries = try alloc.alloc(TranscriptEntry, tool_count);
    defer alloc.free(entries);
    const details = try alloc.alloc(ToolDetailRecord, tool_count);
    defer alloc.free(details);

    for (entries, details, 0..) |*entry, *detail, index| {
        const entry_id: u32 = @intCast(index + 1);
        entry.* = .{ .raw_bytes = .{
            .id = entry_id,
            .bytes = @constCast("tool"),
            .class = .tool_status,
        } };
        detail.* = .{
            .entry_id = entry_id,
            .tool_name = @constCast("read_file"),
            .activity_kind = .read,
            .outcome = .completed,
            .lifecycle_id = .{
                .turn_id = index + 1,
                .call_id = @constCast("call"),
            },
            .presentation_group_id = .{
                .turn_id = index + 1,
                .anchor_step_id = index + 1,
            },
        };
    }

    var stats: BuildStats = .{};
    var projection = try buildWithStats(alloc, entries, details, 120, &stats);
    defer projection.deinit(alloc);

    try std.testing.expectEqual(tool_count, projection.entry_actions.items.len);
    try std.testing.expect(projection.entry_actions.items[0] == .override);
    try std.testing.expect(projection.entry_actions.items[tool_count - 1] == .override);
    try std.testing.expect(stats.detail_lookups <= tool_count * 4);
}
