const std = @import("std");
const build_checkpoint = @import("../render_engine/build_checkpoint.zig");
const transcript_blocks = @import("../render_engine/transcript_blocks.zig");
const types = @import("../../core/shared/types.zig");
const display_width = @import("../../core/shared/display_width.zig");
const sort_utils = @import("../../core/shared/sort_utils.zig");
const ui_render = @import("../render.zig");
const tool_collapse_state = @import("tool_collapse_state.zig");

const TranscriptEntry = transcript_blocks.TranscriptEntry;
const ToolDetailRecord = transcript_blocks.ToolDetailRecord;
const cancellation_follow_up = " · What can fx do differently?";

/// Compact-view collapse policy for Marionette-style T0/T1 projection.
pub const CollapseView = struct {
    collapse_tool_calls: bool = false,
    tree: ?*const tool_collapse_state.ToolCollapseTree = null,
    active_turn_key: ?u64 = null,
    active_turn_elapsed_seconds: ?i64 = null,

    fn defaults(self: CollapseView) tool_collapse_state.CollapseDefaults {
        return tool_collapse_state.CollapseDefaults.fromCollapseToolCalls(self.collapse_tool_calls);
    }

    fn turnExpanded(self: CollapseView, turn_key: u64) bool {
        const defs = self.defaults();
        if (self.tree) |tree| return tree.turnIsExpanded(turn_key, defs);
        return defs.turn_expanded;
    }

    fn groupExpanded(self: CollapseView, group_key: u64) bool {
        const defs = self.defaults();
        if (self.tree) |tree| return tree.groupIsExpanded(group_key, defs);
        return defs.group_expanded;
    }
};

pub const Projection = struct {
    entry_actions: std.ArrayList(transcript_blocks.EntryRenderAction) = .empty,
    owned_overrides: std.ArrayList(OwnedOverride) = .empty,
    /// T0 (+ optional T1 header) chrome for the preferred live turn, painted as a
    /// sticky top inset while the main transcript scrolls underneath.
    sticky_chrome: ?[]u8 = null,

    pub fn deinit(self: *Projection, alloc: std.mem.Allocator) void {
        if (self.sticky_chrome) |bytes| alloc.free(bytes);
        for (self.owned_overrides.items) |owned| {
            alloc.free(owned.bytes);
            alloc.free(owned.line_provenance);
        }
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

    fn setOwnedGroup(self: *Projection, alloc: std.mem.Allocator, index: usize, group: GroupBlock) !void {
        errdefer alloc.free(group.lines);
        try self.setOwnedOverride(alloc, index, .tool_status, group.bytes);
        self.owned_overrides.items[self.owned_overrides.items.len - 1].line_provenance = group.lines;
        self.entry_actions.items[index].override.line_provenance = group.lines;
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
                alloc.free(owned.line_provenance);
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
                .line_provenance = owned.line_provenance,
            });
        }
        suffix.entry_actions.items.len = 0;
        suffix.owned_overrides.items.len = 0;
    }
};

const OwnedOverride = struct {
    entry_index: usize,
    bytes: []u8,
    line_provenance: []const transcript_blocks.LineProvenance = &.{},
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
            .deferred => {},
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

fn subagentStatusContinuation(
    entry: TranscriptEntry,
    detail: ?*const ToolDetailRecord,
) ?[]const u8 {
    const record = detail orelse return null;
    if (record.activity_kind != .subagent) return null;
    const text = switch (entry) {
        .raw_bytes => |raw| raw.bytes,
        else => return null,
    };
    const newline = std.mem.findScalar(u8, text, '\n') orelse return null;
    const continuation = std.mem.trim(u8, text[newline + 1 ..], " \t\r\n");
    return if (continuation.len == 0) null else continuation;
}

fn clipSummary(
    alloc: std.mem.Allocator,
    text: []const u8,
    cols: u16,
) ![]u8 {
    if (display_width.visibleWidthIgnoringAnsi(text) <= cols) return try alloc.dupe(u8, text);
    if (cols == 0) return try alloc.dupe(u8, "");
    if (cols == 1) return try alloc.dupe(u8, "…");
    const prefix = display_width.prefixByWidthIgnoringAnsi(text, cols - 1);
    const clipped = try std.fmt.allocPrint(alloc, "{s}…", .{prefix});
    // A cut inside a styled run can leave the final SGR open; close it so the
    // accent cannot bleed into whatever the terminal paints next.
    if (std.mem.find(u8, clipped, "\x1b") == null or std.mem.endsWith(u8, clipped, "\x1b[0m"))
        return clipped;
    defer alloc.free(clipped);
    return try std.fmt.allocPrint(alloc, "{s}\x1b[0m", .{clipped});
}

const StatToken = struct {
    /// Index of the sign character.
    start: usize,
    added: bool,
};

/// Diff counts exist only on write_file/edit_file status lines; every other
/// phrase can end in a coincidental " +N" / "-N" (for example `head -80`).
fn entryShowsDiffStats(detail: ?*const ToolDetailRecord) bool {
    const record = detail orelse return false;
    return std.mem.eql(u8, record.tool_name, "write_file") or
        std.mem.eql(u8, record.tool_name, "edit_file");
}

/// Matches a trailing " +N" or " -N" diff count in a plain status phrase.
fn trailingStatToken(text: []const u8) ?StatToken {
    var index = text.len;
    while (index > 0 and std.ascii.isDigit(text[index - 1])) : (index -= 1) {}
    if (index == text.len) return null;
    if (index < 2) return null;
    const sign = text[index - 1];
    if (sign != '+' and sign != '-') return null;
    if (text[index - 2] != ' ') return null;
    return .{ .start = index - 1, .added = sign == '+' };
}

/// Re-applies the diff add/remove marker accents to the trailing "+N" / "-N"
/// counts of a normalized tool status phrase. Normalization strips SGR so
/// grouped lines stay uniform; the counts keep their green/red so file edits
/// stay scannable inside collapsed and expanded groups. `ambient_style` is
/// re-applied between the two counts so the " / " separator keeps the line's
/// surrounding style. Returns `text` unchanged when no diff count suffix is
/// present. Caller owns the returned slice.
fn accentTrailingDiffStats(
    alloc: std.mem.Allocator,
    text: []const u8,
    ambient_style: []const u8,
) ![]u8 {
    const added_style = ui_render.diff_added_marker_style;
    const removed_style = ui_render.diff_removed_marker_style;
    if (added_style.len == 0 and removed_style.len == 0) return try alloc.dupe(u8, text);
    const reset = "\x1b[0m";

    const last = trailingStatToken(text) orelse return try alloc.dupe(u8, text);
    if (!last.added and last.start >= 2 and text[last.start - 2] == '/') {
        const before_slash = std.mem.trimEnd(u8, text[0 .. last.start - 2], " ");
        if (trailingStatToken(before_slash)) |first| {
            if (first.added) {
                return try std.fmt.allocPrint(alloc, "{s}{s}{s}{s}{s} / {s}{s}{s}", .{
                    before_slash[0..first.start],
                    added_style,
                    before_slash[first.start..],
                    reset,
                    ambient_style,
                    removed_style,
                    text[last.start..],
                    reset,
                });
            }
        }
    }
    const style = if (last.added) added_style else removed_style;
    if (style.len == 0) return try alloc.dupe(u8, text);
    return try std.fmt.allocPrint(alloc, "{s}{s}{s}{s}", .{
        text[0..last.start],
        style,
        text[last.start..],
        reset,
    });
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

    const plain = try out.toOwnedSlice();
    defer alloc.free(plain);
    const clipped = try clipSummary(alloc, plain, cols);
    defer alloc.free(clipped);
    return applySummaryStyle(alloc, clipped, style);
}

const GroupBlock = struct { bytes: []u8, lines: []const transcript_blocks.LineProvenance };

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
) !GroupBlock {
    const header = try formatGroupHeader(alloc, summary, cols, style);
    defer alloc.free(header);
    var lines: std.ArrayList(transcript_blocks.LineProvenance) = .empty;
    errdefer lines.deinit(alloc);
    try lines.append(alloc, .{ .entry = .{ .entry_id = entries[status_indices[0]].id(), .entry_class = .tool_status, .projection_part = .group_header } });
    if (collapse_tool_calls) {
        const bytes = try alloc.dupe(u8, header);
        errdefer alloc.free(bytes);
        return .{ .bytes = bytes, .lines = try lines.toOwnedSlice(alloc) };
    }

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

        const raw_phrase = switch (entry) {
            .raw_bytes => |raw| try normalizeCanonicalStatus(scratch, raw.bytes),
            else => null,
        } orelse if (detail) |record| record.tool_name else "tool activity";
        const phrase = try reprojectTruncatedCommandPhrase(
            scratch,
            raw_phrase,
            detail,
        ) orelse raw_phrase;
        static_index += 1;
        const connector = if (!focused_in_group and static_index == static_count) "└" else "├";
        const child = try std.fmt.allocPrint(scratch, "{s} {s}", .{ connector, phrase });
        const clipped = try clipSummary(scratch, child, cols);
        try lines.append(alloc, .{ .entry = .{ .entry_id = entry_id, .entry_class = .tool_status, .projection_part = .group_child } });
        const accented = if (entryShowsDiffStats(detail))
            try accentTrailingDiffStats(scratch, clipped, style.text_style)
        else
            clipped;
        try out.writer.writeByte('\n');
        if (style.text_style.len > 0) try out.writer.writeAll(style.text_style);
        try out.writer.writeAll(accented);
        if (style.text_style.len > 0) try out.writer.writeAll(style.reset_style);
        if (subagentStatusContinuation(entry, detail)) |continuation| {
            const continuation_row = try std.fmt.allocPrint(scratch, "  {s}", .{continuation});
            const clipped_continuation = try clipSummary(scratch, continuation_row, cols);
            try lines.append(alloc, .{ .entry = .{ .entry_id = entry_id, .entry_class = .tool_status, .projection_part = .group_child } });
            try out.writer.writeByte('\n');
            if (style.text_style.len > 0) try out.writer.writeAll(style.text_style);
            try out.writer.writeAll(clipped_continuation);
            if (style.text_style.len > 0) try out.writer.writeAll(style.reset_style);
        }
    }

    for (status_indices) |status_index| {
        const entry = entries[status_index];
        const entry_id = toolStatusEntryId(entry) orelse continue;
        const detail = detailForEntry(details, detail_indices, entry_id, null) orelse continue;
        if (detail.outcome != .cancelled) continue;

        const terminal = try transcript_blocks.renderEntryToBlock(scratch, entry, cols, styles);
        if (terminal.bytes.len > 0) {
            try lines.append(alloc, .block_separator);
            const count = std.mem.count(u8, std.mem.trimEnd(u8, terminal.bytes, "\n"), "\n") + 1;
            try lines.appendNTimes(alloc, .{ .entry = .{ .entry_id = entry_id, .entry_class = .tool_status, .projection_part = .group_cancel } }, count);
            try out.writer.writeAll("\n\n");
            try out.writer.writeAll(terminal.bytes);
        }
        terminal.deinit(scratch);
    }
    const bytes = try out.toOwnedSlice();
    errdefer alloc.free(bytes);
    return .{ .bytes = bytes, .lines = try lines.toOwnedSlice(alloc) };
}

/// Substitutes the stored full command for a settled status phrase that was
/// truncated to the compact activity bound at generation time. Records carry
/// the full display whenever the command is known — captured runs, tty runs,
/// and terminal-session actions — so the phrase can be reclipped to the live
/// terminal width instead of keeping the frozen "..." marker.
fn reprojectTruncatedCommandPhrase(
    scratch: std.mem.Allocator,
    phrase: []const u8,
    detail: ?*const ToolDetailRecord,
) !?[]const u8 {
    const record = detail orelse return null;
    if (record.outcome != .completed) return null;
    if (!std.mem.endsWith(u8, phrase, "...")) return null;
    const command = record.command_display orelse return null;
    const action = record.command_action_label orelse return null;
    // The stored pair must match the phrase it replaces: a record carrying a
    // mismatched label would rewrite an unrelated row.
    if (!std.mem.startsWith(u8, phrase, action)) return null;
    return try std.fmt.allocPrint(scratch, "{s} {s}", .{ action, command });
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
    const raw_phrase = switch (entry) {
        .raw_bytes => |raw| try normalizeStatusPhrase(scratch, raw.bytes),
        else => null,
    } orelse if (detail) |record| record.tool_name else "tool activity";
    const phrase = try reprojectTruncatedCommandPhrase(
        scratch,
        raw_phrase,
        detail,
    ) orelse raw_phrase;
    const child = try std.fmt.allocPrint(scratch, "{s} {s}", .{ connector, phrase });
    const clipped = try clipSummary(scratch, child, cols);
    const accented = if (entryShowsDiffStats(detail))
        try accentTrailingDiffStats(scratch, clipped, "")
    else
        clipped;
    const continuation = subagentStatusContinuation(entry, detail) orelse return alloc.dupe(u8, accented);
    const continuation_row = try std.fmt.allocPrint(scratch, "  {s}", .{continuation});
    return std.fmt.allocPrint(alloc, "{s}\n{s}", .{ accented, try clipSummary(scratch, continuation_row, cols) });
}

test "expanded subagent row preserves status continuation" {
    const alloc = std.testing.allocator;
    const entry = TranscriptEntry{ .raw_bytes = .{
        .id = 7,
        .bytes = "● reviewer working · inspect auth\n  gpt-5.5 · high · 12k/256k 4%\n",
        .class = .tool_status,
    } };
    const detail = ToolDetailRecord{
        .entry_id = 7,
        .tool_name = @constCast("subagent"),
        .activity_kind = .subagent,
    };
    const row = try formatExpandedChild(alloc, entry, &detail, "└", 120);
    defer alloc.free(row);

    try std.testing.expectEqualStrings(
        "└ reviewer working · inspect auth\n  gpt-5.5 · high · 12k/256k 4%",
        row,
    );
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
    return buildWithStyleAndStats(alloc, entries, details, cols, null, .{}, .{}, .{}, .compact, null, null) catch |err| switch (err) {
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
    return buildWithStyleAndStats(alloc, entries, details, cols, null, .{}, style, styles, .compact, null, null) catch |err| switch (err) {
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
    return buildWithStyleAndStats(alloc, entries, details, cols, null, .{}, style, styles, .expanded, null, checkpoint);
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
        .{},
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
    collapse: CollapseView,
    style: SummaryStyle,
    styles: transcript_blocks.Styles,
) !Projection {
    return buildStyledFocusedInterruptible(
        alloc,
        entries,
        details,
        cols,
        focused_entry_id,
        collapse,
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
    collapse: CollapseView,
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
        collapse,
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
    return buildWithStyleAndStats(alloc, entries, details, cols, null, .{}, .{}, .{}, .compact, stats, null);
}

const TieredGroup = struct {
    group_key: u64,
    status_indices: std.ArrayList(usize) = .empty,
    summary: Summary = .{},

    fn deinit(self: *TieredGroup, alloc: std.mem.Allocator) void {
        self.status_indices.deinit(alloc);
        self.* = undefined;
    }
};

fn isProtectedProseEntry(entry: TranscriptEntry) bool {
    return switch (entry) {
        .assistant_turn => |assistant| assistant.segments.text.items.len > 0,
        else => false,
    };
}

fn turnKeyForSpan(
    entries: []const TranscriptEntry,
    details: []const ToolDetailRecord,
    detail_indices: *const std.AutoHashMapUnmanaged(u32, usize),
    span_start: usize,
    span_end: usize,
) u64 {
    var index = span_start;
    while (index < span_end) : (index += 1) {
        const entry_id = toolStatusEntryId(entries[index]) orelse continue;
        const detail = detailForEntry(details, detail_indices, entry_id, null) orelse continue;
        if (detail.lifecycle_id) |lifecycle| {
            return tool_collapse_state.turnKeyFromLifecycle(lifecycle.turn_id);
        }
        if (detail.presentation_group_id) |group| {
            return tool_collapse_state.turnKeyFromLifecycle(group.turn_id);
        }
    }
    const start_id = if (span_start < entries.len) entries[span_start].id() else 0;
    return tool_collapse_state.turnKeySynthetic(start_id);
}

/// Prefer the sticky live umbrella key when this span belongs to it, so mid-stream
/// hotkey force flags always match the painted turn (avoids open/close-only feel).
fn resolveTurnKeyForSpan(
    entries: []const TranscriptEntry,
    details: []const ToolDetailRecord,
    detail_indices: *const std.AutoHashMapUnmanaged(u32, usize),
    span_start: usize,
    span_end: usize,
    collapse: CollapseView,
) u64 {
    const computed = turnKeyForSpan(entries, details, detail_indices, span_start, span_end);
    const preferred = collapse.active_turn_key orelse
        (if (collapse.tree) |tree| tree.preferred_turn_key else null) orelse
        return computed;
    if (computed == preferred) return preferred;
    // Span tools that share the preferred lifecycle/presentation turn win.
    var index = span_start;
    while (index < span_end) : (index += 1) {
        const entry_id = toolStatusEntryId(entries[index]) orelse continue;
        const detail = detailForEntry(details, detail_indices, entry_id, null) orelse continue;
        if (detail.lifecycle_id) |lifecycle| {
            if (tool_collapse_state.turnKeyFromLifecycle(lifecycle.turn_id) == preferred)
                return preferred;
        }
        if (detail.presentation_group_id) |group| {
            if (tool_collapse_state.turnKeyFromLifecycle(group.turn_id) == preferred)
                return preferred;
        }
    }
    // Synthetic key on the live preferred turn: keep sticky key so force flags apply.
    if ((computed & 0xC000_0000_0000_0000) == 0xC000_0000_0000_0000) {
        if (collapse.active_turn_key == preferred) return preferred;
    }
    return computed;
}

fn formatElapsedSeconds(alloc: std.mem.Allocator, seconds: i64) ![]u8 {
    const secs = @mod(seconds, 60);
    const total_minutes = @divTrunc(seconds, 60);
    const mins = @mod(total_minutes, 60);
    const hours = @divTrunc(total_minutes, 60);
    if (hours > 0) return try std.fmt.allocPrint(alloc, "{d}h{d}m{d}s", .{ hours, mins, secs });
    if (mins > 0) return try std.fmt.allocPrint(alloc, "{d}m{d}s", .{ mins, secs });
    return try std.fmt.allocPrint(alloc, "{d}s", .{secs});
}

fn formatTurnUmbrellaHeader(
    alloc: std.mem.Allocator,
    total_tools: usize,
    cols: u16,
    style: SummaryStyle,
    collapse: CollapseView,
    turn_key: u64,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const expanded = collapse.turnExpanded(turn_key);
    try out.writer.writeAll(if (expanded) "▼ " else "▶ ");
    var used_elapsed = false;
    if (collapse.active_turn_key == turn_key) {
        if (collapse.active_turn_elapsed_seconds) |seconds| {
            if (seconds >= 0) {
                const elapsed = try formatElapsedSeconds(alloc, seconds);
                defer alloc.free(elapsed);
                try out.writer.print("Worked for {s}", .{elapsed});
                used_elapsed = true;
            }
        }
    }
    if (!used_elapsed) try out.writer.writeAll("Tool activity");
    if (total_tools > 0) {
        try out.writer.print(" · {d} tool call{s}", .{
            total_tools,
            if (total_tools == 1) "" else "s",
        });
    }
    const plain = try out.toOwnedSlice();
    defer alloc.free(plain);
    const clipped = try clipSummary(alloc, plain, cols);
    defer alloc.free(clipped);
    return applySummaryStyle(alloc, clipped, style);
}

fn indentBlockLines(alloc: std.mem.Allocator, block: []const u8, indent: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var lines = std.mem.splitScalar(u8, block, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.writer.writeByte('\n');
        first = false;
        try out.writer.writeAll(indent);
        try out.writer.writeAll(line);
    }
    return out.toOwnedSlice();
}

fn collapseExcessBlankLines(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var newline_run: usize = 0;
    for (text) |byte| {
        if (byte == '\n') {
            newline_run += 1;
            // Cap at one blank row between prose (two newlines).
            if (newline_run <= 2) try out.writer.writeByte('\n');
            continue;
        }
        newline_run = 0;
        try out.writer.writeByte(byte);
    }
    return out.toOwnedSlice();
}

fn appendProtectedProse(
    alloc: std.mem.Allocator,
    out: *std.Io.Writer.Allocating,
    entries: []const TranscriptEntry,
    prose_indices: []const usize,
) !void {
    // Model chunks often already end with \n / \n\n. Trim edges, cap blank runs
    // at one empty row, and join turns with a single blank line so relocated
    // prose does not stack into huge gaps.
    var wrote_any = false;
    for (prose_indices) |index| {
        const raw = switch (entries[index]) {
            .assistant_turn => |assistant| assistant.segments.text.items,
            else => continue,
        };
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) continue;
        const chunk = try collapseExcessBlankLines(alloc, trimmed);
        defer alloc.free(chunk);
        if (wrote_any) try out.writer.writeAll("\n\n");
        try out.writer.writeAll(chunk);
        wrote_any = true;
    }
}

fn projectLegacyGroupsInSpan(
    alloc: std.mem.Allocator,
    projection: *Projection,
    entries: []const TranscriptEntry,
    details: []const ToolDetailRecord,
    detail_indices: *const std.AutoHashMapUnmanaged(u32, usize),
    presentation_group_indices: []const ?usize,
    presentation_groups: []PresentationGroup,
    tool_indices: []const usize,
    focused_entry_id: ?u32,
    collapse: CollapseView,
    cols: u16,
    style: SummaryStyle,
    styles: transcript_blocks.Styles,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !void {
    var seen_presentation: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer seen_presentation.deinit(alloc);

    for (tool_indices) |tool_index| {
        try build_checkpoint.tick(checkpoint);
        const group_index = presentation_group_indices[tool_index] orelse continue;
        const result = try seen_presentation.getOrPut(alloc, group_index);
        if (result.found_existing) continue;
        const group = presentation_groups[group_index];
        for (group.status_indices.items) |status_index| {
            projection.entry_actions.items[status_index] = .hide;
            hideAttachedRows(entries, projection.entry_actions.items, status_index);
        }
        const entry_id = toolStatusEntryId(entries[group.anchor_index]) orelse continue;
        const group_key = blk: {
            const detail = detailForEntry(details, detail_indices, entry_id, null);
            if (presentationGroupId(detail)) |gid|
                break :blk tool_collapse_state.groupKeyForPresentation(gid);
            break :blk tool_collapse_state.groupKeyForSequentialAnchor(entry_id);
        };
        const block = try formatGroupBlock(
            alloc,
            entries,
            group.status_indices.items,
            details,
            detail_indices,
            group.summary,
            focused_entry_id,
            !collapse.groupExpanded(group_key),
            cols,
            style,
            styles,
        );
        try projection.setOwnedGroup(alloc, group.anchor_index, block);
    }

    var i: usize = 0;
    while (i < tool_indices.len) : (i += 1) {
        try build_checkpoint.tick(checkpoint);
        const tool_index = tool_indices[i];
        if (presentation_group_indices[tool_index] != null) continue;
        if (projection.entry_actions.items[tool_index] == .override) continue;

        var status_indices: std.ArrayList(usize) = .empty;
        defer status_indices.deinit(alloc);
        var summary: Summary = .{};
        var j = i;
        while (j < tool_indices.len) : (j += 1) {
            const idx = tool_indices[j];
            if (presentation_group_indices[idx] != null) break;
            if (j > i) {
                const prev = tool_indices[j - 1];
                var gap = prev + 1;
                var split = false;
                while (gap < idx) : (gap += 1) {
                    if (isAttachedEntry(entries[gap])) continue;
                    // Ask rows and other tool statuses between members are hard splits.
                    if (toolStatusEntryId(entries[gap]) != null) {
                        split = true;
                        break;
                    }
                    if (!isTransparentCompactEntry(entries[gap])) {
                        split = true;
                        break;
                    }
                }
                if (split) break;
            }
            const entry_id = toolStatusEntryId(entries[idx]).?;
            const detail = detailForEntry(details, detail_indices, entry_id, null);
            if (statusNamesAsk(entries[idx], detail)) break;
            observeTool(&summary, detail);
            try status_indices.append(alloc, idx);
        }
        if (status_indices.items.len == 0) continue;
        const first_index = status_indices.items[0];
        for (status_indices.items) |status_index| {
            projection.entry_actions.items[status_index] = .hide;
            hideAttachedRows(entries, projection.entry_actions.items, status_index);
        }
        const group_key = tool_collapse_state.groupKeyForSequentialAnchor(
            toolStatusEntryId(entries[first_index]).?,
        );
        const block = try formatGroupBlock(
            alloc,
            entries,
            status_indices.items,
            details,
            detail_indices,
            summary,
            focused_entry_id,
            !collapse.groupExpanded(group_key),
            cols,
            style,
            styles,
        );
        try projection.setOwnedGroup(alloc, first_index, block);
        i = j - 1;
    }
}

fn projectTieredTurn(
    alloc: std.mem.Allocator,
    projection: *Projection,
    entries: []const TranscriptEntry,
    details: []const ToolDetailRecord,
    detail_indices: *const std.AutoHashMapUnmanaged(u32, usize),
    presentation_group_indices: []const ?usize,
    presentation_groups: []PresentationGroup,
    span_start: usize,
    span_end: usize,
    focused_entry_id: ?u32,
    collapse: CollapseView,
    cols: u16,
    style: SummaryStyle,
    styles: transcript_blocks.Styles,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
    is_tail_span: bool,
) !void {
    var tool_indices: std.ArrayList(usize) = .empty;
    defer tool_indices.deinit(alloc);
    var prose_indices: std.ArrayList(usize) = .empty;
    defer prose_indices.deinit(alloc);

    var index = span_start;
    while (index < span_end) : (index += 1) {
        try build_checkpoint.tick(checkpoint);
        const entry = entries[index];
        if (!transcript_blocks.isEntryVisibleInCompactPresentation(entry)) continue;
        if (toolStatusEntryId(entry)) |entry_id| {
            const detail = detailForEntry(details, detail_indices, entry_id, null);
            if (statusNamesAsk(entry, detail)) continue;
            try tool_indices.append(alloc, index);
            continue;
        }
        if (isProtectedProseEntry(entry)) try prose_indices.append(alloc, index);
    }
    if (tool_indices.items.len == 0) return;

    const preferred = collapse.active_turn_key orelse
        (if (collapse.tree) |tree| tree.preferred_turn_key else null);
    var turn_key = resolveTurnKeyForSpan(entries, details, detail_indices, span_start, span_end, collapse);
    // Umbrella when:
    // - protected prose is interleaved (Marionette relocate), or
    // - this span resolves to the live/preferred turn key, or
    // - this is the live/tail Generating span under an active collapse tree
    //   (tools before prose / before preferred catches up must not flash legacy chips).
    // A bare tree pointer must NOT force umbrella on older non-tail spans.
    const matches_preferred = if (preferred) |pref| pref == turn_key else false;
    const use_umbrella = prose_indices.items.len > 0 or matches_preferred or
        (is_tail_span and collapse.tree != null);
    if (use_umbrella and is_tail_span) {
        if (preferred) |pref| turn_key = pref;
    }
    if (!use_umbrella) {
        try projectLegacyGroupsInSpan(
            alloc,
            projection,
            entries,
            details,
            detail_indices,
            presentation_group_indices,
            presentation_groups,
            tool_indices.items,
            focused_entry_id,
            collapse,
            cols,
            style,
            styles,
            checkpoint,
        );
        return;
    }

    const t0_expanded = collapse.turnExpanded(turn_key);
    var tiered_groups: std.ArrayList(TieredGroup) = .empty;
    defer {
        for (tiered_groups.items) |*group| group.deinit(alloc);
        tiered_groups.deinit(alloc);
    }
    var seen_presentation: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer seen_presentation.deinit(alloc);

    for (tool_indices.items) |tool_index| {
        const group_index = presentation_group_indices[tool_index] orelse continue;
        const result = try seen_presentation.getOrPut(alloc, group_index);
        if (result.found_existing) continue;
        const source = presentation_groups[group_index];
        var group: TieredGroup = .{
            .group_key = blk: {
                const entry_id = toolStatusEntryId(entries[tool_index]).?;
                const detail = detailForEntry(details, detail_indices, entry_id, null);
                if (presentationGroupId(detail)) |gid|
                    break :blk tool_collapse_state.groupKeyForPresentation(gid);
                break :blk tool_collapse_state.groupKeyForSequentialAnchor(entry_id);
            },
            .summary = source.summary,
        };
        errdefer group.deinit(alloc);
        for (source.status_indices.items) |status_index| {
            if (status_index < span_start or status_index >= span_end) continue;
            try group.status_indices.append(alloc, status_index);
        }
        if (group.status_indices.items.len == 0) {
            group.deinit(alloc);
            continue;
        }
        try tiered_groups.append(alloc, group);
    }

    var sequential: TieredGroup = .{
        .group_key = tool_collapse_state.groupKeyForSequentialAnchor(
            toolStatusEntryId(entries[tool_indices.items[0]]).?,
        ),
    };
    var sequential_owned = true;
    errdefer if (sequential_owned) sequential.deinit(alloc);
    for (tool_indices.items) |tool_index| {
        if (presentation_group_indices[tool_index] != null) continue;
        const entry_id = toolStatusEntryId(entries[tool_index]).?;
        const detail = detailForEntry(details, detail_indices, entry_id, null);
        observeTool(&sequential.summary, detail);
        try sequential.status_indices.append(alloc, tool_index);
    }
    if (sequential.status_indices.items.len > 0) {
        sequential.group_key = tool_collapse_state.groupKeyForSequentialAnchor(
            toolStatusEntryId(entries[sequential.status_indices.items[0]]).?,
        );
        try tiered_groups.append(alloc, sequential);
        sequential_owned = false;
    } else {
        sequential.deinit(alloc);
        sequential_owned = false;
    }

    var total_tools: usize = 0;
    for (tiered_groups.items) |group| total_tools += group.summary.total;

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var lines: std.ArrayList(transcript_blocks.LineProvenance) = .empty;
    errdefer lines.deinit(alloc);

    const header = try formatTurnUmbrellaHeader(alloc, total_tools, cols, style, collapse, turn_key);
    defer alloc.free(header);
    try out.writer.writeAll(header);
    const anchor_entry_id = toolStatusEntryId(entries[tool_indices.items[0]]).?;
    try lines.append(alloc, .{ .entry = .{
        .entry_id = anchor_entry_id,
        .entry_class = .tool_status,
        .projection_part = .group_header,
    } });

    if (t0_expanded) {
        for (tiered_groups.items) |group| {
            try build_checkpoint.tick(checkpoint);
            const block = try formatGroupBlock(
                alloc,
                entries,
                group.status_indices.items,
                details,
                detail_indices,
                group.summary,
                focused_entry_id,
                !collapse.groupExpanded(group.group_key),
                cols,
                style,
                styles,
            );
            defer {
                alloc.free(block.bytes);
                alloc.free(block.lines);
            }
            const indented = try indentBlockLines(alloc, block.bytes, "  ");
            defer alloc.free(indented);
            try out.writer.writeByte('\n');
            try out.writer.writeAll(indented);
            try lines.appendSlice(alloc, block.lines);
        }
    }

    if (prose_indices.items.len > 0) {
        // Match formatGroupBlock cancel spacing: "\n\n" introduces a blank hard
        // line that must carry .block_separator provenance, or compact render
        // hits `block_provenance.len >= renderedHardLineCount` (resume/`-c` panic).
        const mark = out.writer.end;
        try out.writer.writeAll("\n\n");
        const prose_start = out.writer.end;
        try appendProtectedProse(alloc, &out, entries, prose_indices.items);
        if (out.writer.end > prose_start) {
            try lines.append(alloc, .block_separator);
            const prose_entry_id = entries[prose_indices.items[0]].id();
            const prose_bytes = out.writer.buffer[prose_start..out.writer.end];
            const prose_line_count = std.mem.count(u8, std.mem.trimEnd(u8, prose_bytes, "\n"), "\n") + 1;
            try lines.appendNTimes(alloc, .{ .entry = .{
                .entry_id = prose_entry_id,
                .entry_class = .assistant_turn,
                .projection_part = .body,
            } }, prose_line_count);
        } else {
            out.writer.end = mark;
        }
    }

    for (tool_indices.items) |tool_index| {
        projection.entry_actions.items[tool_index] = .hide;
        hideAttachedRows(entries, projection.entry_actions.items, tool_index);
    }
    for (prose_indices.items) |prose_index| {
        projection.entry_actions.items[prose_index] = .hide;
    }
    // Compact: hide orphaned attachments left behind after prose relocation.
    var span_index = span_start;
    while (span_index < span_end) : (span_index += 1) {
        if (isAttachedEntry(entries[span_index])) {
            projection.entry_actions.items[span_index] = .hide;
        }
    }

    const bytes = try out.toOwnedSlice();
    const owned_lines = lines.toOwnedSlice(alloc) catch |err| {
        alloc.free(bytes);
        return err;
    };
    // Sticky chrome: always T0 header; when T0 expanded, also keep compact T1
    // headers so the umbrella stays visible while details/prose scroll in body.
    // Pin chrome to sticky for the live/preferred umbrella turn. Live tail
    // umbrella before preferred is seeded must also split — otherwise T0/T1
    // stay in the scrolling body and leave gutter crumbs under sticky paint.
    const sticky_for_turn = blk: {
        if (collapse.active_turn_key) |active| break :blk active == turn_key;
        if (collapse.tree) |tree| {
            if (tree.preferred_turn_key) |pref| break :blk pref == turn_key;
        }
        break :blk is_tail_span and use_umbrella;
    };
    var body_bytes = bytes;
    var body_lines = owned_lines;
    if (sticky_for_turn) {
        const split = splitStickyChromeFromBody(alloc, bytes, owned_lines, t0_expanded) catch |err| {
            alloc.free(bytes);
            alloc.free(owned_lines);
            return err;
        };
        if (projection.sticky_chrome) |prior| alloc.free(prior);
        projection.sticky_chrome = split.sticky;
        // Body no longer owns the pre-split buffers.
        alloc.free(bytes);
        alloc.free(owned_lines);
        body_bytes = split.body;
        body_lines = split.body_lines;
    }
    // setOwnedGroup takes ownership; on failure it frees bytes/lines itself.
    try projection.setOwnedGroup(alloc, tool_indices.items[0], .{ .bytes = body_bytes, .lines = body_lines });
}

fn lineContainsMarker(line: []const u8, marker: []const u8) bool {
    return std.mem.indexOf(u8, line, marker) != null;
}

const StickyBodySplit = struct {
    sticky: []u8,
    body: []u8,
    body_lines: []transcript_blocks.LineProvenance,
};

/// Sticky owns T0 (+ compact T1 headers). Scrolling body keeps drawers + prose
/// only so scrollback cannot double-paint the umbrella chrome.
fn splitStickyChromeFromBody(
    alloc: std.mem.Allocator,
    block: []const u8,
    lines: []const transcript_blocks.LineProvenance,
    t0_expanded: bool,
) !StickyBodySplit {
    var sticky_out: std.Io.Writer.Allocating = .init(alloc);
    errdefer sticky_out.deinit();
    var body_out: std.Io.Writer.Allocating = .init(alloc);
    errdefer body_out.deinit();
    var body_prov: std.ArrayList(transcript_blocks.LineProvenance) = .empty;
    errdefer body_prov.deinit(alloc);

    var hard_lines = std.mem.splitScalar(u8, block, '\n');
    var index: usize = 0;
    var phase: enum { sticky_t0, sticky_t1, body } = .sticky_t0;
    var wrote_sticky = false;
    var wrote_body = false;

    while (hard_lines.next()) |line| {
        const prov: ?transcript_blocks.LineProvenance = if (index < lines.len) lines[index] else null;
        index += 1;

        const is_t0 = lineContainsMarker(line, "▼ ") or lineContainsMarker(line, "▶ ");
        const is_t1_header = lineContainsMarker(line, "● ");
        const is_drawer = lineContainsMarker(line, "├") or lineContainsMarker(line, "└");

        switch (phase) {
            .sticky_t0 => {
                if (is_t0) {
                    try sticky_out.writer.writeAll(line);
                    wrote_sticky = true;
                    phase = if (t0_expanded) .sticky_t1 else .body;
                    continue;
                }
                phase = .body;
            },
            .sticky_t1 => {
                if (is_t1_header and !is_drawer) {
                    try sticky_out.writer.writeByte('\n');
                    try sticky_out.writer.writeAll(line);
                    continue;
                }
                phase = .body;
            },
            .body => {},
        }

        if (wrote_body) try body_out.writer.writeByte('\n');
        try body_out.writer.writeAll(line);
        wrote_body = true;
        if (prov) |p| try body_prov.append(alloc, p);
    }

    const sticky = if (wrote_sticky) try sticky_out.toOwnedSlice() else blk: {
        sticky_out.deinit();
        break :blk try alloc.dupe(u8, "");
    };
    errdefer alloc.free(sticky);

    const body = try body_out.toOwnedSlice();
    errdefer alloc.free(body);
    const body_lines = try body_prov.toOwnedSlice(alloc);

    return .{ .sticky = sticky, .body = body, .body_lines = body_lines };
}


fn projectCompactTieredTurns(
    alloc: std.mem.Allocator,
    projection: *Projection,
    entries: []const TranscriptEntry,
    details: []const ToolDetailRecord,
    detail_indices: *const std.AutoHashMapUnmanaged(u32, usize),
    presentation_group_indices: []const ?usize,
    presentation_groups: []PresentationGroup,
    focused_entry_id: ?u32,
    collapse: CollapseView,
    cols: u16,
    style: SummaryStyle,
    styles: transcript_blocks.Styles,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !void {
    var span_start: usize = 0;
    var index: usize = 0;
    while (index <= entries.len) : (index += 1) {
        const at_boundary = index == entries.len or entries[index] == .user_turn;
        if (!at_boundary) continue;
        if (index > span_start) {
            const is_tail_span = index == entries.len;
            try projectTieredTurn(
                alloc,
                projection,
                entries,
                details,
                detail_indices,
                presentation_group_indices,
                presentation_groups,
                span_start,
                index,
                focused_entry_id,
                collapse,
                cols,
                style,
                styles,
                checkpoint,
                is_tail_span,
            );
        }
        span_start = index + 1;
    }
}

fn buildWithStyleAndStats(
    alloc: std.mem.Allocator,
    entries: []const TranscriptEntry,
    details: []const ToolDetailRecord,
    cols: u16,
    focused_entry_id: ?u32,
    collapse: CollapseView,
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
        if (mode == .compact and !transcript_blocks.isEntryVisibleInCompactPresentation(entry)) continue;
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

    try projectCompactTieredTurns(
        alloc,
        &projection,
        entries,
        details,
        &detail_indices,
        presentation_group_indices,
        presentation_groups.items,
        focused_entry_id,
        collapse,
        cols,
        style,
        styles,
        checkpoint,
    );

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

    var projection = try buildStyledFocused(alloc, &entries, &details, 120, null, .{ .collapse_tool_calls = true }, .{}, .{});
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

test "accentTrailingDiffStats re-applies add and remove marker styles" {
    const alloc = std.testing.allocator;
    const saved_added = ui_render.diff_added_marker_style;
    const saved_removed = ui_render.diff_removed_marker_style;
    defer ui_render.diff_added_marker_style = saved_added;
    defer ui_render.diff_removed_marker_style = saved_removed;
    ui_render.diff_added_marker_style = "[G]";
    ui_render.diff_removed_marker_style = "[R]";

    const added = try accentTrailingDiffStats(alloc, "Wrote note.txt +143", "");
    defer alloc.free(added);
    try std.testing.expectEqualStrings("Wrote note.txt [G]+143\x1b[0m", added);

    const removed = try accentTrailingDiffStats(alloc, "Edited main.zig -27", "");
    defer alloc.free(removed);
    try std.testing.expectEqualStrings("Edited main.zig [R]-27\x1b[0m", removed);

    const both = try accentTrailingDiffStats(alloc, "Edited main.zig +12 / -3", "[dim]");
    defer alloc.free(both);
    try std.testing.expectEqualStrings("Edited main.zig [G]+12\x1b[0m[dim] / [R]-3\x1b[0m", both);

    const plain = try accentTrailingDiffStats(alloc, "Read runtime.zig", "");
    defer alloc.free(plain);
    try std.testing.expectEqualStrings("Read runtime.zig", plain);

    const not_a_stat = try accentTrailingDiffStats(alloc, "Wrote notes v2", "");
    defer alloc.free(not_a_stat);
    try std.testing.expectEqualStrings("Wrote notes v2", not_a_stat);

    ui_render.diff_added_marker_style = "";
    ui_render.diff_removed_marker_style = "";
    const unstyled = try accentTrailingDiffStats(alloc, "Wrote note.txt +143", "");
    defer alloc.free(unstyled);
    try std.testing.expectEqualStrings("Wrote note.txt +143", unstyled);
}

test "collapsed tool group keeps diff count accents" {
    const alloc = std.testing.allocator;
    const saved_added = ui_render.diff_added_marker_style;
    const saved_removed = ui_render.diff_removed_marker_style;
    defer ui_render.diff_added_marker_style = saved_added;
    defer ui_render.diff_removed_marker_style = saved_removed;
    ui_render.diff_added_marker_style = "[G]";
    ui_render.diff_removed_marker_style = "[R]";

    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Read\x1b[0m \x1b[38;5;245mruntime.zig\x1b[0m\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "● Wrote\x1b[0m \x1b[38;5;245mnote.txt\x1b[0m \x1b[38;2;48;164;108m+143\x1b[0m\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 3, .bytes = "● Edited\x1b[0m \x1b[38;5;245mmain.zig\x1b[0m \x1b[38;2;48;164;108m+12\x1b[0m \x1b[38;5;245m/\x1b[0m \x1b[38;2;229;72;77m-3\x1b[0m\n", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("read_file"), .activity_kind = .read, .outcome = .completed },
        .{ .entry_id = 2, .tool_name = @constCast("write_file"), .activity_kind = .write, .outcome = .completed },
        .{ .entry_id = 3, .tool_name = @constCast("edit_file"), .activity_kind = .edit, .outcome = .completed },
    };

    var projection = try build(alloc, &entries, &details, 120);
    defer projection.deinit(alloc);

    try std.testing.expectEqualStrings(
        "● 3 tool calls · 1 read · 1 write · 1 edit\n" ++
            "├ Read runtime.zig\n" ++
            "├ Wrote note.txt [G]+143\x1b[0m\n" ++
            "└ Edited main.zig [G]+12\x1b[0m / [R]-3\x1b[0m",
        projection.entry_actions.items[0].override.bytes,
    );
}

test "grouped command lines keep numeric flags uncolored" {
    const alloc = std.testing.allocator;
    const saved_added = ui_render.diff_added_marker_style;
    const saved_removed = ui_render.diff_removed_marker_style;
    defer ui_render.diff_added_marker_style = saved_added;
    defer ui_render.diff_removed_marker_style = saved_removed;
    ui_render.diff_added_marker_style = "[G]";
    ui_render.diff_removed_marker_style = "[R]";

    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Ran\x1b[0m \x1b[38;5;245mcat log.txt | head -80\x1b[0m\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "● Wrote\x1b[0m \x1b[38;5;245mnote.txt\x1b[0m \x1b[38;2;48;164;108m+2\x1b[0m\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 3, .bytes = "● Wrote\x1b[0m \x1b[38;5;245mdetached.txt\x1b[0m \x1b[38;2;48;164;108m+7\x1b[0m\n", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("shell"), .activity_kind = .command, .outcome = .completed },
        .{ .entry_id = 2, .tool_name = @constCast("write_file"), .activity_kind = .write, .outcome = .completed },
        // entry 3 has no detail record; without a recorded file mutation the
        // suffix cannot be trusted and stays plain.
    };

    var projection = try build(alloc, &entries, &details, 120);
    defer projection.deinit(alloc);

    try std.testing.expectEqualStrings(
        "● 3 tool calls · 1 write · 1 command\n" ++
            "├ Ran cat log.txt | head -80\n" ++
            "├ Wrote note.txt [G]+2\x1b[0m\n" ++
            "└ Wrote detached.txt +7",
        projection.entry_actions.items[0].override.bytes,
    );
}

test "expanded tool group keeps diff count accents" {
    const alloc = std.testing.allocator;
    const saved_added = ui_render.diff_added_marker_style;
    const saved_removed = ui_render.diff_removed_marker_style;
    defer ui_render.diff_added_marker_style = saved_added;
    defer ui_render.diff_removed_marker_style = saved_removed;
    ui_render.diff_added_marker_style = "[G]";
    ui_render.diff_removed_marker_style = "[R]";

    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Wrote\x1b[0m \x1b[38;5;245mnote.txt\x1b[0m \x1b[38;2;48;164;108m+143\x1b[0m\n", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("write_file"), .activity_kind = .write, .outcome = .completed },
    };

    var projection = try buildExpandedStyledInterruptible(alloc, &entries, &details, 80, .{
        .marker_style = "<marker>",
        .text_style = "<secondary>",
        .reset_style = "<reset>",
    }, .{}, null);
    defer projection.deinit(alloc);
    const expanded = projection.entry_actions.items[0].override.bytes;

    try std.testing.expect(std.mem.find(u8, expanded, "\n└ Wrote note.txt [G]+143\x1b[0m") != null);
}

test "clipSummary clips styled text by visible width and closes open SGR" {
    const alloc = std.testing.allocator;

    const before_style = try clipSummary(alloc, "├ Wrote a/very/long/path/that/overflows.zig \x1b[32m+143\x1b[0m", 20);
    defer alloc.free(before_style);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(before_style) <= 20);
    try std.testing.expect(std.mem.find(u8, before_style, "\x1b") == null);

    const inside_style = try clipSummary(alloc, "├ Wrote x \x1b[32m+143\x1b[0m", 13);
    defer alloc.free(inside_style);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(inside_style) <= 13);
    try std.testing.expect(std.mem.endsWith(u8, inside_style, "\x1b[0m"));
}

test "minimal tool groups keep instruction refresh neutral and denials visible" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "⊘ Denied by auto agent zig build\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "↻ Reading project instructions before continuing: runtime.zig\n", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("terminal"), .activity_kind = .command, .outcome = .denied },
        .{ .entry_id = 2, .tool_name = @constCast("read_file"), .activity_kind = .read, .outcome = .deferred },
    };

    var projection = try build(alloc, &entries, &details, 120);
    defer projection.deinit(alloc);

    try std.testing.expectEqualStrings(
        "● 2 tool calls · 1 read · 1 command · 1 denied\n" ++
            "├ Denied by auto agent zig build\n" ++
            "└ Reading project instructions before continuing: runtime.zig",
        projection.entry_actions.items[0].override.bytes,
    );
}

test "minimal tool group counts instruction refresh attempts without failure counts" {
    const alloc = std.testing.allocator;
    var summary = Summary{};
    for (0..3) |_| {
        observeTool(&summary, &.{
            .entry_id = 1,
            .tool_name = @constCast("shell"),
            .activity_kind = .command,
            .outcome = .deferred,
        });
    }
    const header = try formatGroupHeader(alloc, summary, 120, .{});
    defer alloc.free(header);

    try std.testing.expectEqualStrings("● 3 tool calls · 3 commands", header);
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

    var projection = try buildStyledFocused(alloc, &entries, &details, 120, 2, .{}, .{}, .{});
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

test "minimal completed command rows reproject stored arguments at the current width" {
    const alloc = std.testing.allocator;
    const command = "printf " ++ ("alpha-beta-gamma-delta-" ** 8);
    const arguments_json = try std.fmt.allocPrint(
        alloc,
        "{{\"command\":{f}}}",
        .{std.json.fmt(command, .{})},
    );
    defer alloc.free(arguments_json);
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{
            .id = 1,
            .bytes = "● Ran\x1b[0m \x1b[38;5;245mprintf alpha-beta-gamma-delta-alpha-beta-gamma-delta-alpha-beta-gamma-delta-alpha-beta-gamma-delta-alpha-beta-gamma-...\x1b[0m\n",
            .class = .tool_status,
        } },
    };
    const details = [_]ToolDetailRecord{
        .{
            .entry_id = 1,
            .tool_name = @constCast("shell"),
            .captured_command = true,
            .activity_kind = .command,
            .arguments_json = arguments_json,
            .command_display = @constCast(command),
            .command_action_label = @constCast("Ran"),
            .outcome = .completed,
            .command_process_presentation = .{ .exit_code = 0 },
        },
    };

    var narrow = try build(alloc, &entries, &details, 80);
    defer narrow.deinit(alloc);
    const narrow_row = narrow.entry_actions.items[0].override.bytes;
    try std.testing.expect(std.mem.endsWith(u8, narrow_row, "…"));
    try std.testing.expect(std.mem.find(u8, narrow_row, "alpha-beta-gamma") != null);

    var wide = try build(alloc, &entries, &details, 240);
    defer wide.deinit(alloc);
    try std.testing.expectEqualStrings(
        "● 1 tool call · 1 command\n└ Ran " ++ command,
        wide.entry_actions.items[0].override.bytes,
    );

    const legacy_details = [_]ToolDetailRecord{
        .{
            .entry_id = 1,
            .tool_name = @constCast("run_command"),
            .activity_kind = .command,
            .outcome = .completed,
        },
    };
    var legacy = try build(alloc, &entries, &legacy_details, 240);
    defer legacy.deinit(alloc);
    try std.testing.expect(std.mem.endsWith(u8, legacy.entry_actions.items[0].override.bytes, "..."));

    const relative_command = "cd ./packages/cli && " ++ ("printf relative-path " ** 6);
    const relative_arguments_json = try std.fmt.allocPrint(
        alloc,
        "{{\"command\":{f}}}",
        .{std.json.fmt(relative_command, .{})},
    );
    defer alloc.free(relative_arguments_json);
    const relative_entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{
            .id = 1,
            .bytes = "● Ran cd ./packages/cli && printf relative-path printf relative-path printf relative-path printf relative-path printf relative-path pri...\n",
            .class = .tool_status,
        } },
    };
    const relative_details = [_]ToolDetailRecord{
        .{
            .entry_id = 1,
            .tool_name = @constCast("shell"),
            .captured_command = true,
            .activity_kind = .command,
            .arguments_json = relative_arguments_json,
            .command_display = @constCast(relative_command),
            .command_action_label = @constCast("Ran"),
            .outcome = .completed,
            .command_process_presentation = .{ .exit_code = 0 },
        },
    };
    var relative = try build(alloc, &relative_entries, &relative_details, 240);
    defer relative.deinit(alloc);
    try std.testing.expectEqualStrings(
        "● 1 tool call · 1 command\n└ Ran " ++ relative_command,
        relative.entry_actions.items[0].override.bytes,
    );

    const compatibility_entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{
            .id = 1,
            .bytes = "● Installed skill printf alpha-beta-gamma-delta-alpha-beta-gamma-delta-alpha-beta-gamma-delta-alpha-beta-gamma-delta-alpha-beta-gamma-...\n",
            .class = .tool_status,
        } },
    };
    const compatibility_details = [_]ToolDetailRecord{.{
        .entry_id = 1,
        .tool_name = @constCast("shell"),
        .captured_command = true,
        .activity_kind = .command,
        .arguments_json = arguments_json,
        .command_display = @constCast(command),
        .command_action_label = @constCast("Installed skill"),
        .outcome = .completed,
        .command_process_presentation = .{ .exit_code = 0 },
    }};
    var compatibility = try build(alloc, &compatibility_entries, &compatibility_details, 240);
    defer compatibility.deinit(alloc);
    try std.testing.expectEqualStrings(
        "● 1 tool call · 1 command\n└ Installed skill " ++ command,
        compatibility.entry_actions.items[0].override.bytes,
    );
}

test "completed session and tty command rows reproject stored commands at the current width" {
    const alloc = std.testing.allocator;
    const tty_command = "bun run " ++ ("pipeline-stage-" ** 10);
    const observe_command = "npm run " ++ ("dev-server-" ** 12);
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{
            .id = 1,
            .bytes = "● Ran\x1b[0m \x1b[38;5;245mbun run pipeline-stage-pipeline-stage-pipeline-stage-pipeline-stage-pipeline-stage-pipeline-stage-pipeli...\x1b[0m\n",
            .class = .tool_status,
        } },
        .{ .raw_bytes = .{
            .id = 2,
            .bytes = "● Observed\x1b[0m \x1b[38;5;245mnpm run dev-server-dev-server-dev-server-dev-server-dev-server-dev-server-dev-server-dev-server-dev-s...\x1b[0m\n",
            .class = .tool_status,
        } },
    };
    // tty runs and terminal-session observations are not captured commands;
    // their full display arrives only through stored command metadata.
    const details = [_]ToolDetailRecord{
        .{
            .entry_id = 1,
            .tool_name = @constCast("shell"),
            .captured_command = false,
            .activity_kind = .command,
            .command_display = @constCast(tty_command),
            .command_action_label = @constCast("Ran"),
            .outcome = .completed,
            .command_process_presentation = .{ .exit_code = 0 },
        },
        .{
            .entry_id = 2,
            .tool_name = @constCast("shell"),
            .captured_command = false,
            .activity_kind = .command,
            .command_display = @constCast(observe_command),
            .command_action_label = @constCast("Observed"),
            .outcome = .completed,
        },
    };

    var narrow = try build(alloc, &entries, &details, 80);
    defer narrow.deinit(alloc);
    const narrow_rows = narrow.entry_actions.items[0].override.bytes;
    var narrow_lines = std.mem.splitScalar(u8, narrow_rows, '\n');
    _ = narrow_lines.next(); // group header
    const narrow_tty = narrow_lines.next().?;
    const narrow_observe = narrow_lines.next().?;
    try std.testing.expect(std.mem.startsWith(u8, narrow_tty, "├ Ran bun run pipeline-stage-"));
    try std.testing.expect(std.mem.endsWith(u8, narrow_tty, "…"));
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(narrow_tty) <= 80);
    try std.testing.expect(std.mem.startsWith(u8, narrow_observe, "└ Observed npm run dev-server-"));
    try std.testing.expect(std.mem.endsWith(u8, narrow_observe, "…"));
    // Reprojection replaces the frozen ASCII marker before reclipping.
    try std.testing.expect(std.mem.find(u8, narrow_rows, "...") == null);

    var wide = try build(alloc, &entries, &details, 400);
    defer wide.deinit(alloc);
    try std.testing.expectEqualStrings(
        "● 2 tool calls · 2 commands\n" ++
            "├ Ran " ++ tty_command ++ "\n" ++
            "└ Observed " ++ observe_command,
        wide.entry_actions.items[0].override.bytes,
    );
}

test "expanded group children reproject stored commands at the current width" {
    const alloc = std.testing.allocator;
    const command = "bun run " ++ ("pipeline-stage-" ** 10);
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{
            .id = 1,
            .bytes = "● Ran\x1b[0m \x1b[38;5;245mbun run pipeline-stage-pipeline-stage-pipeline-stage-pipeline-stage-pipeline-stage-pipeline-stage-pipeli...\x1b[0m\n",
            .class = .tool_status,
        } },
    };
    const details = [_]ToolDetailRecord{.{
        .entry_id = 1,
        .tool_name = @constCast("shell"),
        .captured_command = false,
        .activity_kind = .command,
        .command_display = @constCast(command),
        .command_action_label = @constCast("Ran"),
        .outcome = .completed,
        .command_process_presentation = .{ .exit_code = 0 },
    }};

    var wide = try buildExpandedStyledInterruptible(alloc, &entries, &details, 400, .{}, .{}, null);
    defer wide.deinit(alloc);
    try std.testing.expectEqualStrings(
        "● 1 tool call · 1 command\n└ Ran " ++ command,
        wide.entry_actions.items[0].override.bytes,
    );

    var narrow = try buildExpandedStyledInterruptible(alloc, &entries, &details, 80, .{}, .{}, null);
    defer narrow.deinit(alloc);
    try std.testing.expect(std.mem.endsWith(u8, narrow.entry_actions.items[0].override.bytes, "…"));
    try std.testing.expect(std.mem.find(u8, narrow.entry_actions.items[0].override.bytes, "...") == null);
}

test "command reprojection rejects a phrase that does not start with the stored action label" {
    const alloc = std.testing.allocator;
    const command = "printf " ++ ("alpha-beta-gamma-delta-" ** 8);
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{
            .id = 1,
            .bytes = "● Ran\x1b[0m \x1b[38;5;245mprintf alpha-beta-gamma-delta-alpha-beta-gamma-delta-alpha-beta-gamma-delta-alpha-beta-gamma-delta-alpha-beta-gamma-...\x1b[0m\n",
            .class = .tool_status,
        } },
    };
    const details = [_]ToolDetailRecord{.{
        .entry_id = 1,
        .tool_name = @constCast("shell"),
        .activity_kind = .command,
        .command_display = @constCast(command),
        .command_action_label = @constCast("Observed"),
        .outcome = .completed,
        .command_process_presentation = .{ .exit_code = 0 },
    }};

    var projection = try build(alloc, &entries, &details, 240);
    defer projection.deinit(alloc);
    // The frozen phrase stays untouched when the stored label does not lead it.
    try std.testing.expect(std.mem.endsWith(u8, projection.entry_actions.items[0].override.bytes, "..."));
    try std.testing.expect(std.mem.find(u8, projection.entry_actions.items[0].override.bytes, "Observed") == null);
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

test "assistant prose relocates beneath turn umbrella with tools coalesced" {
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
    try std.testing.expect(projection.entry_actions.items[3] == .hide);
    try std.testing.expect(projection.entry_actions.items[4] == .hide);
    const override = projection.entry_actions.items[0].override;
    const block = override.bytes;
    try std.testing.expect(std.mem.find(u8, block, "Tool activity") != null);
    try std.testing.expect(std.mem.find(u8, block, "assistant message") != null);
    try std.testing.expect(std.mem.find(u8, block, "2 tool call") != null);
    try std.testing.expect(override.line_provenance.len >= hardLineCount(block));
}

test "umbrella prose join trims stacked newlines" {
    const alloc = std.testing.allocator;
    var entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "command", .class = .tool_status } },
        .{ .assistant_turn = .{ .id = 2, .segments = .{} } },
        .{ .assistant_turn = .{ .id = 3, .segments = .{} } },
    };
    try entries[1].assistant_turn.segments.text.appendSlice(alloc, "first paragraph\n\n");
    try entries[2].assistant_turn.segments.text.appendSlice(alloc, "\n\nsecond paragraph\n");
    defer entries[1].assistant_turn.segments.deinit(alloc);
    defer entries[2].assistant_turn.segments.deinit(alloc);
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("run_command"), .activity_kind = .command, .outcome = .completed },
    };

    var projection = try build(alloc, &entries, &details, 120);
    defer projection.deinit(alloc);
    const block = projection.entry_actions.items[0].override.bytes;
    try std.testing.expect(std.mem.find(u8, block, "first paragraph\n\nsecond paragraph") != null);
    try std.testing.expect(std.mem.find(u8, block, "first paragraph\n\n\n\nsecond") == null);
}

test "umbrella prose provenance covers blank separator when T0 collapsed" {
    const alloc = std.testing.allocator;
    var entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "command", .class = .tool_status } },
        .{ .assistant_turn = .{ .id = 2, .segments = .{} } },
    };
    try entries[1].assistant_turn.segments.text.appendSlice(alloc, "protected prose");
    defer entries[1].assistant_turn.segments.deinit(alloc);
    const details = [_]ToolDetailRecord{
        .{
            .entry_id = 1,
            .tool_name = @constCast("run_command"),
            .activity_kind = .command,
            .outcome = .completed,
            .lifecycle_id = .{ .turn_id = 9, .call_id = @constCast("one") },
        },
    };
    var tree: tool_collapse_state.ToolCollapseTree = .{};
    defer tree.deinit(alloc);
    try tree.setTurnExpanded(alloc, 9, false);

    var projection = try buildStyledFocused(
        alloc,
        &entries,
        &details,
        120,
        null,
        .{ .tree = &tree },
        .{},
        .{},
    );
    defer projection.deinit(alloc);

    try std.testing.expect(projection.entry_actions.items[0] == .override);
    try std.testing.expect(projection.entry_actions.items[1] == .hide);
    const override = projection.entry_actions.items[0].override;
    const sticky = projection.sticky_chrome orelse "";
    const painted = try std.mem.concat(alloc, u8, &.{ sticky, "\n", override.bytes });
    defer alloc.free(painted);
    try std.testing.expect(std.mem.find(u8, painted, "Tool activity") != null);
    try std.testing.expect(std.mem.find(u8, override.bytes, "protected prose") != null);
    try std.testing.expect(std.mem.find(u8, painted, "▶ ") != null);
    try std.testing.expect(override.line_provenance.len >= hardLineCount(override.bytes));
}

test "umbrella+prose mid-Generating shape survives compact render appendBlock" {
    // Cary crash shape: interleaved tool + streaming prose under T0 umbrella with a live
    // collapse tree (MCP/puppetmaster path). Missing .block_separator for the "\n\n" gap
    // made appendBlock hit assert(block_provenance.len >= renderedHardLineCount).
    const alloc = std.testing.allocator;
    var entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Running mcp", .class = .tool_status } },
        .{ .assistant_turn = .{ .id = 2, .segments = .{} } },
        .{ .raw_bytes = .{ .id = 3, .bytes = "● Read file", .class = .tool_status } },
    };
    try entries[1].assistant_turn.segments.text.appendSlice(alloc, "Working on it…\npartial stream");
    defer entries[1].assistant_turn.segments.deinit(alloc);
    const details = [_]ToolDetailRecord{
        .{
            .entry_id = 1,
            .tool_name = @constCast("mcp_tool"),
            .activity_kind = .command,
            .outcome = null,
            .lifecycle_id = .{ .turn_id = 42, .call_id = @constCast("a") },
        },
        .{
            .entry_id = 3,
            .tool_name = @constCast("read_file"),
            .activity_kind = .read,
            .outcome = null,
            .lifecycle_id = .{ .turn_id = 42, .call_id = @constCast("b") },
        },
    };
    var tree: tool_collapse_state.ToolCollapseTree = .{};
    defer tree.deinit(alloc);
    try tree.setTurnExpanded(alloc, 42, true);

    var projection = try buildStyledFocused(
        alloc,
        &entries,
        &details,
        120,
        null,
        .{ .tree = &tree },
        .{},
        .{},
    );
    defer projection.deinit(alloc);

    try std.testing.expect(projection.entry_actions.items[0] == .override);
    const override = projection.entry_actions.items[0].override;
    try std.testing.expect(override.line_provenance.len >= hardLineCount(override.bytes));

    // Drive the real compact preparation path — this is where ReleaseSafe aborted mid-Generating.
    var prepared = try transcript_blocks.renderEntriesForPreparation(
        alloc,
        &entries,
        120,
        .{},
        .{
            .entry_actions = projection.entry_actions.items,
            .capture_provenance = true,
        },
    );
    defer prepared.deinit(alloc);
    // Sticky owns T0 chrome when preferred is set; body/preparation keep prose + provenance.
    const sticky = projection.sticky_chrome orelse "";
    try std.testing.expect(std.mem.find(u8, sticky, "Tool activity") != null or
        std.mem.find(u8, prepared.bytes, "Tool activity") != null);
    try std.testing.expect(std.mem.find(u8, prepared.bytes, "Working on it") != null);
    try std.testing.expect(prepared.line_provenance.len > 0);
}

fn hardLineCount(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    var total: usize = 1;
    for (bytes[0 .. bytes.len - 1]) |byte| {
        if (byte == '\n') total += 1;
    }
    return total;
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
    try std.testing.expect(projection.entry_actions.items[1] == .hide);
    try std.testing.expect(projection.entry_actions.items[2] == .hide);
    try std.testing.expect(projection.entry_actions.items[3] == .hide);
    try std.testing.expect(std.mem.find(u8, projection.entry_actions.items[0].override.bytes, "provider bridge") != null);
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

    const sibling_block = projection.entry_actions.items[0].override.bytes;
    try std.testing.expect(std.mem.find(u8, sibling_block, "Tool activity") != null);
    try std.testing.expect(std.mem.find(u8, sibling_block, "2 tool calls · 2 commands") != null);
    try std.testing.expect(std.mem.find(u8, sibling_block, "Running first") != null);
    try std.testing.expect(std.mem.find(u8, sibling_block, "Running second") != null);
    try std.testing.expect(std.mem.find(u8, sibling_block, "provider bridge") != null);
    try std.testing.expect(projection.entry_actions.items[1] == .hide);
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

    try std.testing.expect(projection.entry_actions.items[0] == .override);
    try std.testing.expect(projection.entry_actions.items[1] == .hide);
    try std.testing.expect(projection.entry_actions.items[2] == .hide);
    const legacy_block = projection.entry_actions.items[0].override.bytes;
    try std.testing.expect(std.mem.find(u8, legacy_block, "Tool activity") != null);
    try std.testing.expect(std.mem.find(u8, legacy_block, "next model step") != null);
    try std.testing.expect(std.mem.find(u8, legacy_block, "Read first") != null);
    try std.testing.expect(std.mem.find(u8, legacy_block, "Running second") != null);
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
    const alloc_block = projection.entry_actions.items[0].override.bytes;
    try std.testing.expect(std.mem.find(u8, alloc_block, "2 tool calls · 2 commands") != null);
    try std.testing.expect(std.mem.find(u8, alloc_block, "Running first") != null);
    try std.testing.expect(std.mem.find(u8, alloc_block, "Running second") != null);
}



test "live preferred turn with tools and zero prose uses umbrella" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Running one", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "● Running two", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{
            .entry_id = 1,
            .tool_name = @constCast("run_command"),
            .activity_kind = .command,
            .outcome = .completed,
            .lifecycle_id = .{ .turn_id = 7, .call_id = @constCast("a") },
        },
        .{
            .entry_id = 2,
            .tool_name = @constCast("read_file"),
            .activity_kind = .read,
            .outcome = .completed,
            .lifecycle_id = .{ .turn_id = 7, .call_id = @constCast("b") },
        },
    };
    var tree: tool_collapse_state.ToolCollapseTree = .{};
    defer tree.deinit(alloc);
    tree.ensurePreferredTurn(7);

    var projection = try buildStyledFocused(
        alloc,
        &entries,
        &details,
        120,
        null,
        .{ .tree = &tree, .active_turn_key = 7, .collapse_tool_calls = true },
        .{},
        .{},
    );
    defer projection.deinit(alloc);

    // Live Generating before prose: umbrella path (sticky and/or in-flow), not legacy chips only.
    const sticky = projection.sticky_chrome orelse "";
    const body = projection.entry_actions.items[0].override.bytes;
    const combined = try std.mem.concat(alloc, u8, &.{ sticky, "\n", body });
    defer alloc.free(combined);
    try std.testing.expect(std.mem.find(u8, combined, "Tool activity") != null);
    try std.testing.expect(std.mem.find(u8, combined, "▼ ") != null or std.mem.find(u8, combined, "▶ ") != null);
}

test "live tail tools under collapse tree umbrella before preferred catches up" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Running early", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "● Running batch", .class = .tool_status } },
    };
    // No lifecycle yet — early live tool batch before preferred is seeded.
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("run_command"), .activity_kind = .command },
        .{ .entry_id = 2, .tool_name = @constCast("read_file"), .activity_kind = .read },
    };
    var tree: tool_collapse_state.ToolCollapseTree = .{};
    defer tree.deinit(alloc);
    // Tree present, preferred still null (live Generating before ensurePreferredTurn).
    var projection = try buildStyledFocused(
        alloc,
        &entries,
        &details,
        120,
        null,
        .{ .tree = &tree, .collapse_tool_calls = true },
        .{},
        .{},
    );
    defer projection.deinit(alloc);
    // Live-tail umbrella pins T0 into sticky even before preferred is seeded.
    const sticky = projection.sticky_chrome orelse "";
    const body = projection.entry_actions.items[0].override.bytes;
    const combined = try std.mem.concat(alloc, u8, &.{ sticky, "\n", body });
    defer alloc.free(combined);
    try std.testing.expect(std.mem.find(u8, combined, "Tool activity") != null);
    try std.testing.expect(std.mem.find(u8, sticky, "Tool activity") != null);
    try std.testing.expect(std.mem.find(u8, sticky, "▼ ") != null or std.mem.find(u8, sticky, "▶ ") != null);
    try std.testing.expect(std.mem.find(u8, body, "▼ ") == null);
    try std.testing.expect(std.mem.find(u8, body, "▶ ") == null);
}

test "historical tool-only turn without preferred match stays legacy grouped" {
    const alloc = std.testing.allocator;
    // Historical span before a later live turn. Preferred points at the live turn
    // so this older tool-only span must stay legacy despite tree != null.
    const user_text = try alloc.dupe(u8, "next prompt");
    defer alloc.free(user_text);
    var entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● old command", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "● old read", .class = .tool_status } },
        .{ .user_turn = .{ .id = 3, .turn = .{ .text = user_text, .images = &.{} } } },
        .{ .raw_bytes = .{ .id = 4, .bytes = "● live tool", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{
            .entry_id = 1,
            .tool_name = @constCast("run_command"),
            .activity_kind = .command,
            .outcome = .completed,
            .lifecycle_id = .{ .turn_id = 3, .call_id = @constCast("a") },
        },
        .{
            .entry_id = 2,
            .tool_name = @constCast("read_file"),
            .activity_kind = .read,
            .outcome = .completed,
            .lifecycle_id = .{ .turn_id = 3, .call_id = @constCast("b") },
        },
        .{
            .entry_id = 4,
            .tool_name = @constCast("run_command"),
            .activity_kind = .command,
            .lifecycle_id = .{ .turn_id = 9, .call_id = @constCast("c") },
        },
    };
    var tree: tool_collapse_state.ToolCollapseTree = .{};
    defer tree.deinit(alloc);
    tree.ensurePreferredTurn(9);

    var projection = try buildStyledFocused(
        alloc,
        &entries,
        &details,
        120,
        null,
        .{ .tree = &tree, .active_turn_key = 9, .collapse_tool_calls = true },
        .{},
        .{},
    );
    defer projection.deinit(alloc);

    // Historical span (before user_turn): legacy chips, no Tool activity umbrella.
    try std.testing.expect(projection.entry_actions.items[0] == .override);
    const historical = projection.entry_actions.items[0].override.bytes;
    try std.testing.expect(std.mem.find(u8, historical, "Tool activity") == null);
    try std.testing.expect(std.mem.find(u8, historical, "tool call") != null);

    // Live tail: umbrella path.
    const sticky = projection.sticky_chrome orelse "";
    try std.testing.expect(projection.entry_actions.items[3] == .override or sticky.len > 0);
    const live_body = if (projection.entry_actions.items[3] == .override)
        projection.entry_actions.items[3].override.bytes
    else
        "";
    const combined = try std.mem.concat(alloc, u8, &.{ sticky, "\n", live_body });
    defer alloc.free(combined);
    try std.testing.expect(std.mem.find(u8, combined, "Tool activity") != null);
}

test "sticky chrome is stripped from in-flow body to avoid duplicate rows" {
    const alloc = std.testing.allocator;
    var entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Running one", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "● Running two", .class = .tool_status } },
        .{ .assistant_turn = .{ .id = 3, .segments = .{} } },
    };
    try entries[2].assistant_turn.segments.text.appendSlice(alloc, "streaming prose");
    defer entries[2].assistant_turn.segments.deinit(alloc);
    const details = [_]ToolDetailRecord{
        .{
            .entry_id = 1,
            .tool_name = @constCast("run_command"),
            .activity_kind = .command,
            .outcome = .completed,
            .lifecycle_id = .{ .turn_id = 11, .call_id = @constCast("a") },
        },
        .{
            .entry_id = 2,
            .tool_name = @constCast("read_file"),
            .activity_kind = .read,
            .outcome = .completed,
            .lifecycle_id = .{ .turn_id = 11, .call_id = @constCast("b") },
        },
    };
    var tree: tool_collapse_state.ToolCollapseTree = .{};
    defer tree.deinit(alloc);
    const defaults = tool_collapse_state.CollapseDefaults.fromCollapseToolCalls(true);
    try tree.setTurnExpanded(alloc, 11, false);
    try tree.stepExpand(alloc, 11, defaults);
    try tree.stepExpand(alloc, 11, defaults);

    var projection = try buildStyledFocused(
        alloc,
        &entries,
        &details,
        120,
        null,
        .{ .tree = &tree, .active_turn_key = 11, .collapse_tool_calls = true },
        .{},
        .{},
    );
    defer projection.deinit(alloc);

    const sticky = projection.sticky_chrome orelse return error.TestExpectedStickyChrome;
    try std.testing.expect(std.mem.find(u8, sticky, "Tool activity") != null);
    try std.testing.expect(std.mem.find(u8, sticky, "▼ ") != null);
    // Sticky may include T1 headers but must not include drawers.
    try std.testing.expect(std.mem.find(u8, sticky, "├") == null);
    try std.testing.expect(std.mem.find(u8, sticky, "└") == null);

    const body = projection.entry_actions.items[0].override.bytes;
    // In-flow body must not repeat sticky T0 chrome.
    try std.testing.expect(std.mem.find(u8, body, "Tool activity") == null);
    try std.testing.expect(std.mem.find(u8, body, "▼ ") == null);
    try std.testing.expect(std.mem.find(u8, body, "▶ ") == null);
    // Drawers + prose remain in the scrolling body.
    try std.testing.expect(std.mem.find(u8, body, "├") != null or std.mem.find(u8, body, "└") != null);
    try std.testing.expect(std.mem.find(u8, body, "streaming prose") != null);
}

test "stepExpand twice yields individual tool rows with box drawers" {
    const alloc = std.testing.allocator;
    var entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Running one", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "● Running two", .class = .tool_status } },
        .{ .assistant_turn = .{ .id = 3, .segments = .{} } },
    };
    try entries[2].assistant_turn.segments.text.appendSlice(alloc, "streaming prose");
    defer entries[2].assistant_turn.segments.deinit(alloc);
    const details = [_]ToolDetailRecord{
        .{
            .entry_id = 1,
            .tool_name = @constCast("run_command"),
            .activity_kind = .command,
            .outcome = .completed,
            .lifecycle_id = .{ .turn_id = 7, .call_id = @constCast("a") },
        },
        .{
            .entry_id = 2,
            .tool_name = @constCast("read_file"),
            .activity_kind = .read,
            .outcome = .completed,
            .lifecycle_id = .{ .turn_id = 7, .call_id = @constCast("b") },
        },
    };
    var tree: tool_collapse_state.ToolCollapseTree = .{};
    defer tree.deinit(alloc);
    const defaults = tool_collapse_state.CollapseDefaults.fromCollapseToolCalls(true);
    try tree.collapseAllToT0(alloc);
    try tree.setTurnExpanded(alloc, 7, false);
    try tree.stepExpand(alloc, 7, defaults);
    try tree.stepExpand(alloc, 7, defaults);
    try std.testing.expectEqual(tool_collapse_state.Level.t1_details, tree.levelForTurn(7, defaults));
    try std.testing.expect(tree.groupIsExpanded(tool_collapse_state.groupKeyForSequentialAnchor(1), defaults));

    var projection = try buildStyledFocused(
        alloc,
        &entries,
        &details,
        120,
        null,
        .{ .tree = &tree, .active_turn_key = 7, .collapse_tool_calls = true },
        .{},
        .{},
    );
    defer projection.deinit(alloc);

    try std.testing.expect(projection.entry_actions.items[0] == .override);
    const block = projection.entry_actions.items[0].override.bytes;
    const sticky = projection.sticky_chrome orelse "";
    const painted = try std.mem.concat(alloc, u8, &.{ sticky, "\n", block });
    defer alloc.free(painted);
    try std.testing.expect(std.mem.find(u8, painted, "▼ ") != null);
    try std.testing.expect(std.mem.find(u8, painted, "Tool activity") != null);
    // Level 3 must show stock-style child rows, not headers only.
    const has_drawer = std.mem.find(u8, block, "├") != null or std.mem.find(u8, block, "└") != null;
    try std.testing.expect(has_drawer);
    try std.testing.expect(std.mem.find(u8, block, "streaming prose") != null);
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

    try std.testing.expect(projection.entry_actions.items[0] == .override);
    for (projection.entry_actions.items[1..]) |action| {
        try std.testing.expect(action == .hide);
    }
    const visible_block = projection.entry_actions.items[0].override.bytes;
    try std.testing.expect(std.mem.find(u8, visible_block, "Tool activity") != null);
    try std.testing.expect(std.mem.find(u8, visible_block, "permission feedback") != null);
    try std.testing.expect(std.mem.find(u8, visible_block, "next model step") != null);
    try std.testing.expect(std.mem.find(u8, visible_block, "10 tool call") != null);
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
    try std.testing.expect(projection.entry_actions.items[3] == .hide);
    try std.testing.expect(projection.entry_actions.items[4] == .hide);
    try std.testing.expect(std.mem.find(u8, projection.entry_actions.items[0].override.bytes, "visible message") != null);
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
