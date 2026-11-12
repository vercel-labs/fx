const std = @import("std");
const testing_allocator = @import("../../core/shared/testing_allocator.zig");
const build_checkpoint = @import("../render_engine/build_checkpoint.zig");
const transcript_blocks = @import("../render_engine/transcript_blocks.zig");
const types = @import("../../core/shared/types.zig");
const display_width = @import("../../core/shared/display_width.zig");
const mem_utils = @import("../../core/shared/mem_utils.zig");
const shared_theme = @import("../../core/shared/theme.zig");
const sort_utils = @import("../../core/shared/sort_utils.zig");
const ui_render = @import("../render.zig");
const code_highlight = @import("../../core/agent/presentation/code_highlight.zig");
const code_highlight_languages = @import("../../core/agent/presentation/code_highlight_languages.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const command_lex = @import("../../core/shell_command/command_lex.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");

const TranscriptEntry = transcript_blocks.TranscriptEntry;
const ToolDetailRecord = transcript_blocks.ToolDetailRecord;
const cancellation_follow_up = " · What can fx do differently?";

pub const Projection = struct {
    entry_actions: std.ArrayList(transcript_blocks.EntryRenderAction) = .empty,
    owned_overrides: std.ArrayList(OwnedOverride) = .empty,

    pub fn deinit(self: *Projection, alloc: std.mem.Allocator) void {
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
    "subagent call",
    "browser",
    "MCP call",
};
const command_category_index = 5;
const subagent_category_index = 6;
const mcp_category_index = 8;

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
        .subagent => subagent_category_index,
        .ask => null,
        .mcp => mcp_category_index,
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
    const marker = for (status_markers) |candidate| {
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

// `■` is the cancelled marker older sessions recorded before `▪`.
const status_markers = [_][]const u8{ "●", "▪", "■", "⊘", "↻" };

/// The state mark a tool's status line opens with, in its own color, so a
/// denied or cancelled call keeps its mark in Ctrl+O. A line without one gets
/// a plain `●`.
fn statusMarker(entry: TranscriptEntry) []const u8 {
    const text = switch (entry) {
        .raw_bytes => |raw| raw.bytes,
        else => return "●",
    };
    var index: usize = 0;
    while (skipSgrSequence(text, &index)) {}
    const marker = for (status_markers) |candidate| {
        if (std.mem.startsWith(u8, text[index..], candidate)) break candidate;
    } else return "●";
    index += marker.len;
    while (skipSgrSequence(text, &index)) {}
    return text[0..index];
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
    const clipped = try alloc.print("{s}…", .{prefix});
    // A cut inside a styled run can leave the final SGR open; close it so the
    // accent cannot bleed into whatever the terminal paints next.
    if (std.mem.find(u8, clipped, "\x1b") == null or std.mem.endsWith(u8, clipped, "\x1b[0m"))
        return clipped;
    defer alloc.free(clipped);
    return try alloc.print("{s}\x1b[0m", .{clipped});
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

/// The "+N" of a "+N / -M" pair that ends in `last`, if there is one.
fn pairedAddedStat(text: []const u8, last: StatToken) ?StatToken {
    if (last.added or last.start < 2 or text[last.start - 2] != '/') return null;
    const before_slash = std.mem.trimEnd(u8, text[0 .. last.start - 2], " ");
    const first = trailingStatToken(before_slash) orelse return null;
    return if (first.added) first else null;
}

/// Index of the space before the trailing "+N", "-N", or "+N / -M" diff
/// counts of a plain status phrase, or null when it has none.
fn diffStatsSuffixStart(text: []const u8) ?usize {
    const last = trailingStatToken(text) orelse return null;
    const first = pairedAddedStat(text, last) orelse last;
    return first.start - 1;
}

/// Clips a write_file or edit_file row like clipSummary, but keeps its
/// trailing diff counts: the phrase before them ends in "…" and the counts
/// follow it. When the counts would take more than half the row, the row
/// clips from the right like any other. Caller owns the returned slice.
fn clipKeepingDiffStats(
    alloc: std.mem.Allocator,
    text: []const u8,
    cols: u16,
) ![]u8 {
    if (display_width.visibleWidthIgnoringAnsi(text) <= cols) return try alloc.dupe(u8, text);
    const suffix_start = diffStatsSuffixStart(text) orelse return clipSummary(alloc, text, cols);
    const suffix = text[suffix_start..];
    const suffix_width = display_width.visibleWidthIgnoringAnsi(suffix);
    if (suffix_width * 2 > cols) return clipSummary(alloc, text, cols);
    const phrase = try clipSummary(alloc, text[0..suffix_start], @intCast(cols - suffix_width));
    defer alloc.free(phrase);
    return try alloc.print("{s}{s}", .{ phrase, suffix });
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
    if (pairedAddedStat(text, last)) |first| {
        const before_slash = std.mem.trimEnd(u8, text[0 .. last.start - 2], " ");
        return try alloc.print("{s}{s}{s}{s}{s} / {s}{s}{s}", .{
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
    const style = if (last.added) added_style else removed_style;
    if (style.len == 0) return try alloc.dupe(u8, text);
    return try alloc.print("{s}{s}{s}{s}", .{
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

/// Compact group header: the summary clipped to one row and styled.
fn formatGroupHeader(
    alloc: std.mem.Allocator,
    summary: Summary,
    cols: u16,
    style: SummaryStyle,
) ![]u8 {
    const plain = try formatGroupSummary(alloc, summary);
    defer alloc.free(plain);
    const clipped = try clipSummary(alloc, plain, cols);
    defer alloc.free(clipped);
    return applySummaryStyle(alloc, clipped, style);
}

/// Unstyled, unclipped "● N tool calls · ..." summary row. Caller owns it.
fn formatGroupSummary(alloc: std.mem.Allocator, summary: Summary) ![]u8 {
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
        const label = if (count == 1) category_labels[index] else switch (index) {
            command_category_index => "commands",
            subagent_category_index => "subagent calls",
            mcp_category_index => "MCP calls",
            else => category_labels[index],
        };
        try appendSegment(&out.writer, count, label);
    }
    try appendSegment(&out.writer, summary.completion_unreported, "unreported");
    try appendSegment(&out.writer, summary.not_executed, "not executed");
    try appendSegment(&out.writer, summary.timed_out, "timed out");
    try appendSegment(&out.writer, summary.failed, "failed");
    try appendSegment(&out.writer, summary.denied, "denied");
    try appendSegment(&out.writer, summary.cancelled, "cancelled");
    return out.toOwnedSlice();
}

// Story presentation. A group header names the main event of the group and
// how it ended. Calls that repeat one task share a row that shows their latest
// state. A failed call gets one reason line, and the turn summary leads with a
// recap of what the turn changed and ran.

/// Keeps printable text on one line: drops escape sequences and control
/// bytes, folds whitespace runs to one space, caps the length, and writes
/// what remains terminal-safe, so a C1 control or an invalid UTF-8 byte shows
/// as its visible escape.
fn storySafeLine(scratch: std.mem.Allocator, text: []const u8, max_bytes: usize) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(scratch);
    var index: usize = 0;
    var pending_space = false;
    while (index < text.len and out.written().len < max_bytes) {
        const byte = text[index];
        if (byte == 0x1b) {
            index += 1;
            if (index < text.len and text[index] == '[') {
                index += 1;
                while (index < text.len and (text[index] < 0x40 or text[index] > 0x7e)) : (index += 1) {}
            }
            index += 1;
            continue;
        }
        if (byte < 0x20 or byte == 0x7f or byte == ' ') {
            pending_space = out.written().len > 0;
            index += 1;
            continue;
        }
        if (pending_space) try out.writer.writeByte(' ');
        pending_space = false;
        try out.writer.writeByte(byte);
        index += 1;
    }
    const written = out.written();
    // Never end inside a UTF-8 sequence.
    var end = written.len;
    while (end > 0 and (written[end - 1] & 0xC0) == 0x80) end -= 1;
    if (end > 0 and written[end - 1] >= 0xC0) {
        const lead = written[end - 1];
        const need: usize = if (lead >= 0xF0) 4 else if (lead >= 0xE0) 3 else 2;
        if (written.len - (end - 1) < need) return scratch.print("{f}", .{text_utils.terminalSafe(written[0 .. end - 1])});
    }
    return scratch.print("{f}", .{text_utils.terminalSafe(written)});
}

fn storyArgs(scratch: std.mem.Allocator, record: *const ToolDetailRecord) ?std.json.ObjectMap {
    const json = record.arguments_json orelse return null;
    const value = std.json.parseFromSliceLeaky(std.json.Value, scratch, json, .{}) catch return null;
    if (value != .object) return null;
    // A call can wrap its fields in {"request": {...}}, which core unwraps the
    // same way (src/core/tooling/tool_presentation.zig).
    if (value.object.get("request")) |request| return if (request == .object) request.object else null;
    return value.object;
}

fn storyArgString(scratch: std.mem.Allocator, record: *const ToolDetailRecord, key: []const u8) ?[]const u8 {
    const args = storyArgs(scratch, record) orelse return null;
    const value = args.get(key) orelse return null;
    return if (value == .string and value.string.len > 0) value.string else null;
}

const DiffTotals = struct { added: usize = 0, removed: usize = 0 };

fn diffTotalsOfPhrase(phrase: []const u8) DiffTotals {
    var totals: DiffTotals = .{};
    const last = trailingStatToken(phrase) orelse return totals;
    const last_value = std.fmt.parseInt(usize, phrase[last.start + 1 ..], 10) catch 0;
    if (last.added) totals.added = last_value else totals.removed = last_value;
    if (pairedAddedStat(phrase, last)) |first| {
        const before_slash = std.mem.trimEnd(u8, phrase[0 .. last.start - 2], " ");
        totals.added = std.fmt.parseInt(usize, before_slash[first.start + 1 ..], 10) catch 0;
    }
    return totals;
}

fn storyCommandFailed(record: *const ToolDetailRecord) bool {
    if (record.outcome) |outcome| if (outcome == .failed) return true;
    return commandProcessFailed(record);
}

const StoryTally = struct {
    changed_paths: std.ArrayList([]const u8) = .empty,
    change_calls: usize = 0,
    write_calls: usize = 0,
    /// Edits and writes that have not finished.
    changes_running: usize = 0,
    diff: DiffTotals = .{},
    read_paths: std.ArrayList([]const u8) = .empty,
    /// read_file calls whose saved arguments name no path, as in old records.
    unnamed_reads: usize = 0,
    /// Searches by tool and pattern, each once, so a pattern searched in
    /// two folders counts as one.
    search_keys: std.ArrayList([]const u8) = .empty,
    /// Searches that name no pattern, as in old records, and other listings.
    unkeyed_searches: usize = 0,
    web_searches: usize = 0,
    web_reads: usize = 0,
    commands: usize = 0,
    /// Sessions that later calls sent input to or stopped. Those calls are
    /// not new commands, so they count here instead.
    followed_sessions: std.ArrayList([]const u8) = .empty,
    unnamed_session_calls: usize = 0,
    commands_failed: usize = 0,
    /// Whether the latest command failed, so the result mark reports where
    /// the work ended rather than every retry on the way.
    last_command_failed: ?bool = null,
    /// Commands that have not finished, which hold back the ✓.
    commands_running: usize = 0,
    /// Calls other than commands that failed, such as an edit that did not
    /// apply.
    other_failures: usize = 0,
    /// Calls held until fx reads the project instructions they reach.
    deferred: usize = 0,
    /// Rows whose latest command failed, other than the group's last
    /// command, whose result the mark already shows. A command that passed on
    /// a retry shares one row with its failures and does not count.
    earlier_command_failures: usize = 0,
    /// toolbox calls that open a tool or search for one, which read no file.
    tool_opens: usize = 0,
    toolbox_searches: usize = 0,
    subagent_calls: usize = 0,
    subagent_names: std.ArrayList([]const u8) = .empty,
    /// Reports and messages from subagents, which show as subagent calls
    /// with empty arguments (src/core/subagent/reports.zig, Row.call).
    subagent_updates: usize = 0,
    subagent_waits: usize = 0,
    mcp_calls: usize = 0,
    opens: usize = 0,

    fn addDistinct(list: *std.ArrayList([]const u8), scratch: std.mem.Allocator, value: []const u8) !void {
        for (list.items) |existing| if (std.mem.eql(u8, existing, value)) return;
        try list.append(scratch, value);
    }

    fn observe(
        self: *StoryTally,
        scratch: std.mem.Allocator,
        entry: TranscriptEntry,
        detail: ?*const ToolDetailRecord,
    ) !void {
        const record = detail orelse return;
        if (record.fallback_disposition != null) return;
        // A denied, cancelled, or deferred call did not run, so the story
        // does not count it as work.
        if (record.outcome) |outcome| switch (outcome) {
            .denied, .cancelled => return,
            .deferred => {
                self.deferred += 1;
                return;
            },
            else => {},
        };
        const name = record.tool_name;
        const kind = record.activity_kind orelse return;
        // Another call that failed did not do its work, so the header counts
        // it only as a failure.
        if (kind != .command) if (record.outcome) |outcome| if (outcome == .failed) {
            self.other_failures += 1;
            return;
        };
        switch (kind) {
            .edit, .write => {
                self.change_calls += 1;
                if (record.outcome == null) self.changes_running += 1;
                if (kind == .write) self.write_calls += 1;
                if (storyArgString(scratch, record, "path")) |path| try addDistinct(&self.changed_paths, scratch, path);
                const phrase = switch (entry) {
                    .raw_bytes => |raw| try normalizeCanonicalStatus(scratch, raw.bytes),
                    else => null,
                } orelse "";
                const totals = diffTotalsOfPhrase(phrase);
                self.diff.added += totals.added;
                self.diff.removed += totals.removed;
            },
            .command => {
                const follow_up = isSessionFollowUp(scratch, record);
                if (!follow_up) {
                    self.commands += 1;
                } else if (storyArgString(scratch, record, "session_id")) |id| {
                    try addDistinct(&self.followed_sessions, scratch, id);
                } else {
                    self.unnamed_session_calls += 1;
                }
                if (record.outcome == null and record.command_process_presentation == null) {
                    if (!follow_up) self.commands_running += 1;
                    return;
                }
                const failed = storyCommandFailed(record);
                if (failed) self.commands_failed += 1;
                self.last_command_failed = failed;
            },
            .read, .list => {
                if (std.mem.eql(u8, name, "read_file")) {
                    if (storyArgString(scratch, record, "path")) |path| try addDistinct(&self.read_paths, scratch, path) else self.unnamed_reads += 1;
                } else if (std.mem.eql(u8, name, "toolbox")) {
                    if (storyArgString(scratch, record, "open") != null) self.tool_opens += 1 else self.toolbox_searches += 1;
                } else if (std.mem.eql(u8, name, "web_search") or isProviderSearchName(name)) {
                    self.web_searches += 1;
                } else if (std.mem.eql(u8, name, "web_fetch")) {
                    self.web_reads += 1;
                } else if (try storySearchKey(scratch, record)) |key| {
                    try addDistinct(&self.search_keys, scratch, key);
                } else {
                    self.unkeyed_searches += 1;
                }
            },
            .subagent => {
                self.subagent_calls += 1;
                // Old records keep no arguments, so they say nothing more.
                if (storyArgs(scratch, record) == null) return;
                if (storyArgString(scratch, record, "agent")) |agent| {
                    try addDistinct(&self.subagent_names, scratch, agent);
                } else if (storyArgString(scratch, record, "action")) |action| {
                    if (std.mem.eql(u8, action, "wait") or std.mem.eql(u8, action, "status")) self.subagent_waits += 1;
                } else {
                    self.subagent_updates += 1;
                }
            },
            .mcp => self.mcp_calls += 1,
            .open => self.opens += 1,
            .ask => {},
        }
    }

    fn sessionsFollowed(self: StoryTally) usize {
        return self.followed_sessions.items.len + self.unnamed_session_calls;
    }

    fn reads(self: StoryTally) usize {
        return self.read_paths.items.len + self.unnamed_reads;
    }

    fn changedFiles(self: StoryTally) usize {
        return if (self.changed_paths.items.len > 0) self.changed_paths.items.len else self.change_calls;
    }
};

/// A shell call that sends input to a running session or stops it, rather
/// than running a command.
fn isSessionFollowUp(scratch: std.mem.Allocator, record: *const ToolDetailRecord) bool {
    const action = storyArgString(scratch, record, "action") orelse return false;
    return std.mem.eql(u8, action, "interact") or std.mem.eql(u8, action, "stop");
}

fn isProviderSearchName(name: []const u8) bool {
    return std.mem.eql(u8, name, "web_search_preview") or std.mem.eql(u8, name, "google_search");
}

fn pluralWord(count: usize, singular: []const u8, plural_form: []const u8) []const u8 {
    return if (count == 1) singular else plural_form;
}

/// Writes " +N -M" with the same accents the rows' diff counts use, then
/// returns to the header's own style.
fn writeDiffTotals(writer: *std.Io.Writer, diff: DiffTotals, style: SummaryStyle) !void {
    if (diff.added > 0) try writeDiffCount(writer, '+', diff.added, ui_render.diff_added_marker_style, style);
    if (diff.removed > 0) try writeDiffCount(writer, '-', diff.removed, ui_render.diff_removed_marker_style, style);
}

fn writeDiffCount(writer: *std.Io.Writer, sign: u8, count: usize, accent: []const u8, style: SummaryStyle) !void {
    if (accent.len == 0) return writer.print(" {c}{d}", .{ sign, count });
    try writer.print(" {s}{c}{d}\x1b[0m{s}", .{ accent, sign, count, style.text_style });
}

/// Where the group's commands ended: ✗ when the latest finished command
/// failed, and ✓ when it passed and every command finished, so a command that
/// passed on a retry still ends its group with ✓. Other calls that failed show
/// as " · N failed" instead, so the mark never blames a command for them.
fn writeResultMark(writer: *std.Io.Writer, tally: StoryTally) !void {
    const latest_failed = tally.last_command_failed orelse return;
    if (latest_failed) {
        try writer.writeAll(" ✗");
    } else if (tally.commands_running == 0) {
        try writer.writeAll(" ✓");
    }
}

/// A story header, and where its subject ends: the diff counts, the result
/// mark, and the call states after it stay when the header is clipped.
const StoryHeader = struct {
    text: []u8,
    tail_start: usize,
};

/// "● Ran 3 shell commands ✗": the main event of the group and its result. The main
/// event is the strongest change the group made: edits, then subagents, then
/// commands, then the web, then reads and searches. Returns null when the
/// group has nothing the story can name, so the caller keeps the count
/// summary. Caller owns the returned text.
fn formatStoryHeader(
    alloc: std.mem.Allocator,
    tally: StoryTally,
    summary: Summary,
    style: SummaryStyle,
) !?StoryHeader {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("● ");
    var tail_start: ?usize = null;

    const changed = tally.changedFiles();
    const reads = tally.reads();
    if (changed > 0) {
        const writes_only = tally.write_calls == tally.change_calls;
        const verb = if (tally.changes_running > 0)
            (if (writes_only) "Writing" else "Editing")
        else if (writes_only) "Wrote" else "Edited";
        if (tally.changed_paths.items.len == 1)
            try w.print("{s} {f}", .{ verb, text_utils.terminalSafe(tally.changed_paths.items[0]) })
        else
            try w.print("{s} {d} {s}", .{ verb, changed, pluralWord(changed, "file", "files") });
        tail_start = out.written().len;
        try writeDiffTotals(w, tally.diff, style);
    } else if (tally.subagent_calls > 0) {
        const agents = tally.subagent_names.items.len;
        if (agents > 0)
            try w.print("Started {d} {s}", .{ agents, pluralWord(agents, "subagent", "subagents") })
        else if (tally.subagent_updates > 0)
            try w.print("Got {d} subagent {s}", .{ tally.subagent_updates, pluralWord(tally.subagent_updates, "update", "updates") })
        else if (tally.subagent_waits == tally.subagent_calls)
            try w.writeAll("Waited for subagents")
        else
            try w.print("Made {d} subagent {s}", .{ tally.subagent_calls, pluralWord(tally.subagent_calls, "call", "calls") });
    } else if (tally.commands > 0) {
        const verb = if (tally.commands_running == tally.commands) "Running" else "Ran";
        try w.print("{s} {d} shell {s}", .{ verb, tally.commands, pluralWord(tally.commands, "command", "commands") });
    } else if (tally.sessionsFollowed() > 0) {
        const sessions = tally.sessionsFollowed();
        try w.print("Checked {d} shell {s}", .{ sessions, pluralWord(sessions, "session", "sessions") });
    } else if (tally.mcp_calls > 0) {
        try w.print("Made {d} {s}", .{ tally.mcp_calls, pluralWord(tally.mcp_calls, "MCP call", "MCP calls") });
    } else if (tally.web_reads > 0) {
        try w.print("Read {d} web {s}", .{ tally.web_reads, pluralWord(tally.web_reads, "page", "pages") });
    } else if (tally.web_searches > 0) {
        try w.writeAll("Searched the web");
    } else if (tally.tool_opens > 0) {
        try w.print("Opened {d} {s}", .{ tally.tool_opens, pluralWord(tally.tool_opens, "tool", "tools") });
    } else if (tally.toolbox_searches > 0) {
        try w.writeAll("Searched the toolbox");
    } else if (reads > 0) {
        try w.print("Read {d} {s}", .{ reads, pluralWord(reads, "file", "files") });
    } else if (tally.search_keys.items.len + tally.unkeyed_searches > 0) {
        const searches = tally.search_keys.items.len + tally.unkeyed_searches;
        try w.print("Searched for {d} {s}", .{ searches, pluralWord(searches, "pattern", "patterns") });
    } else if (tally.opens > 0) {
        try w.print("Opened {d} {s}", .{ tally.opens, pluralWord(tally.opens, "file", "files") });
    } else if (tally.other_failures > 0) {
        try w.print("{d} {s} failed", .{ tally.other_failures, pluralWord(tally.other_failures, "call", "calls") });
    } else if (tally.deferred > 0) {
        try w.writeAll(std.mem.trimEnd(u8, types.context_deferred_tool_status_label, ":"));
    } else {
        out.deinit();
        return null;
    }
    if (tail_start == null) tail_start = out.written().len;
    try writeResultMark(w, tally);
    if (!std.mem.endsWith(u8, out.written()[0..tail_start.?], " failed"))
        try appendSegment(w, tally.other_failures + tally.earlier_command_failures, "failed");
    try appendSegment(w, summary.completion_unreported, "unreported");
    try appendSegment(w, summary.not_executed, "not executed");
    try appendSegment(w, summary.timed_out, "timed out");
    try appendSegment(w, summary.denied, "denied");
    try appendSegment(w, summary.cancelled, "cancelled");
    return .{ .text = try out.toOwnedSlice(), .tail_start = tail_start.? };
}

/// Clips a story header to `cols` from the end of its subject, so its diff
/// counts, result mark, and call states stay. When they would take more than
/// half the row, the header clips from the right like any other summary.
fn clipStoryHeader(alloc: std.mem.Allocator, header: StoryHeader, cols: u16) ![]u8 {
    return clipKeepingTail(alloc, header.text[0..header.tail_start], header.text[header.tail_start..], cols, "");
}

/// Clips `body` so `tail` still fits after it in `cols`, the way a row keeps
/// its diff counts: a merge note such as " ×3 · passed on the 3rd run" or a
/// result mark stays when a long command clips. When the tail would take more
/// than half the row, the whole line clips from the right like any other.
/// A clip inside a highlight ends in a reset, so `restyle`, the row's own
/// style, comes back before the tail. Caller owns the returned slice.
fn clipKeepingTail(alloc: std.mem.Allocator, body: []const u8, tail: []const u8, cols: u16, restyle: []const u8) ![]u8 {
    const whole = try std.mem.concat(alloc, u8, &.{ body, tail });
    if (display_width.visibleWidthIgnoringAnsi(whole) <= cols) return whole;
    defer alloc.free(whole);
    const tail_width = display_width.visibleWidthIgnoringAnsi(tail);
    if (tail_width * 2 > cols) return try clipSummary(alloc, whole, cols);
    const clipped = try clipSummary(alloc, body, cols - @as(u16, @intCast(tail_width)));
    defer alloc.free(clipped);
    const reset = std.mem.endsWith(u8, clipped, "\x1b[0m") and !std.mem.endsWith(u8, body, "\x1b[0m");
    return try std.mem.concat(alloc, u8, &.{ clipped, if (reset) restyle else "", tail });
}

/// How a call joins the row of an earlier call that does the same task.
const StoryRowKind = enum {
    /// Its own row.
    single,
    /// The same command again, one call after the other.
    command,
    /// The same shell session: its run, input, and stop.
    session,
    /// The same file, read in parts one after the other.
    read,
    /// The same subagent: its messages, status, and close.
    subagent,
    /// A subagent wait or status that names no agent, keyed by its action.
    subagent_wait,
    /// The same pattern with the same search tool, in one folder or several.
    search,
};

const StoryIdentity = struct {
    kind: StoryRowKind = .single,
    key: []const u8 = "",
};

const StoryRow = struct {
    entry: TranscriptEntry,
    entry_id: u32,
    detail: ?*const ToolDetailRecord,
    identity: StoryIdentity,
    count: usize = 1,
    /// How many of the calls that share the row failed.
    failures: usize = 0,
    /// The folders a search row looked in, each once, in the order of its
    /// calls; "" for a search that named none.
    search_paths: std.ArrayList([]const u8) = .empty,
};

/// The key that joins searches for the same pattern with the same tool,
/// wherever they look. Null for other calls.
fn storySearchKey(scratch: std.mem.Allocator, record: *const ToolDetailRecord) !?[]const u8 {
    const name = record.tool_name;
    if (!std.mem.eql(u8, name, "grep_files") and !std.mem.eql(u8, name, "glob_files")) return null;
    const pattern = storyArgString(scratch, record, "pattern") orelse return null;
    return try scratch.print("{s}\x00{s}", .{ name, pattern });
}

fn addSearchPath(scratch: std.mem.Allocator, row: *StoryRow, detail: ?*const ToolDetailRecord) !void {
    if (row.identity.kind != .search) return;
    const record = detail orelse return;
    const path = storyArgString(scratch, record, "path") orelse "";
    const trimmed = std.mem.trimEnd(u8, path, "/");
    try StoryTally.addDistinct(&row.search_paths, scratch, if (trimmed.len == 0 and path.len > 0) "/" else trimmed);
}

/// How many leading parts two paths share, split at "/".
fn sharedPathParts(a: []const u8, b: []const u8) usize {
    var a_parts = std.mem.splitScalar(u8, a, '/');
    var b_parts = std.mem.splitScalar(u8, b, '/');
    var count: usize = 0;
    while (a_parts.next()) |a_part| {
        const b_part = b_parts.next() orelse break;
        if (!std.mem.eql(u8, a_part, b_part)) break;
        count += 1;
    }
    return count;
}

/// A folder by the part of its path after the `shared` leading parts. The
/// shared folder itself shows by its last part, and no path shows as ".".
fn folderName(path: []const u8, shared: usize) []const u8 {
    if (path.len == 0) return ".";
    var rest = path;
    var skipped: usize = 0;
    while (skipped < shared) : (skipped += 1) {
        const slash = std.mem.findScalar(u8, rest, '/') orelse {
            rest = "";
            break;
        };
        rest = rest[slash + 1 ..];
    }
    if (rest.len > 0) return rest;
    const last = std.mem.findScalarLast(u8, path, '/') orelse return path;
    return if (last + 1 < path.len) path[last + 1 ..] else path;
}

/// Names the folders of a search row by the part of each path that differs
/// from the others, so "/w/reviews" and "/w/docs" are "reviews, docs". Up
/// to three show, then "+N more". Every name is terminal-safe.
fn searchFolderNames(scratch: std.mem.Allocator, paths: []const []const u8) ![]const u8 {
    var shared: usize = std.math.maxInt(usize);
    for (paths[1..]) |path| shared = @min(shared, sharedPathParts(paths[0], path));
    var out: std.Io.Writer.Allocating = .init(scratch);
    const shown = @min(paths.len, short_command_max_steps);
    for (paths[0..shown], 0..) |path, position| {
        if (position > 0) try out.writer.writeAll(", ");
        try out.writer.print("{f}", .{text_utils.terminalSafe(folderName(path, shared))});
    }
    if (paths.len > shown) try out.writer.print(" +{d} more", .{paths.len - shown});
    return out.written();
}

fn storyRowCallFailed(detail: ?*const ToolDetailRecord) bool {
    const record = detail orelse return false;
    return record.activity_kind == .command and storyCallFailed(detail);
}

fn storyIdentity(scratch: std.mem.Allocator, detail: ?*const ToolDetailRecord) !StoryIdentity {
    const record = detail orelse return .{};
    // A deferred call waits for project instructions and has not run, so it
    // keeps its own row instead of counting as a run of the same command.
    if (record.outcome == .deferred) return .{};
    const kind = record.activity_kind orelse return .{};
    switch (kind) {
        .command => {
            if (storyArgString(scratch, record, "session_id")) |id| return .{ .kind = .session, .key = id };
            if (record.result) |result| {
                if (std.json.parseFromSliceLeaky(std.json.Value, scratch, result, .{})) |parsed| {
                    if (parsed == .object) if (parsed.object.get("session_id")) |id| if (id == .string and id.string.len > 0)
                        return .{ .kind = .session, .key = id.string };
                } else |_| {}
            }
            const command = storyArgString(scratch, record, "command") orelse record.command_display orelse "";
            if (command.len > 0) return .{ .kind = .command, .key = command };
            return .{};
        },
        .read, .list => {
            if (try storySearchKey(scratch, record)) |key| return .{ .kind = .search, .key = key };
            if (kind != .read or !std.mem.eql(u8, record.tool_name, "read_file")) return .{};
            const path = storyArgString(scratch, record, "path") orelse return .{};
            return .{ .kind = .read, .key = path };
        },
        .subagent => {
            if (storyArgString(scratch, record, "agent")) |agent| return .{ .kind = .subagent, .key = agent };
            // A report row carries no call; only a bare wait or status
            // joins other subagent rows.
            const action = storyArgString(scratch, record, "action") orelse return .{};
            if (std.mem.eql(u8, action, "wait") or std.mem.eql(u8, action, "status")) return .{ .kind = .subagent_wait, .key = action };
            return .{};
        },
        else => return .{},
    }
}

/// The rows of a group after calls for the same task share one row. Rows
/// keep the position of their first call and show their latest call.
fn collectStoryRows(
    scratch: std.mem.Allocator,
    entries: []const TranscriptEntry,
    status_indices: []const usize,
    details: []const ToolDetailRecord,
    detail_indices: *const std.AutoHashMapUnmanaged(u32, usize),
    focused_entry_id: ?u32,
) !std.ArrayList(StoryRow) {
    var rows: std.ArrayList(StoryRow) = .empty;
    for (status_indices) |status_index| {
        const entry = entries[status_index];
        const entry_id = toolStatusEntryId(entry) orelse continue;
        const detail = detailForEntry(details, detail_indices, entry_id, null);
        if (statusNamesAsk(entry, detail) or focused_entry_id == entry_id) continue;
        const identity = try storyIdentity(scratch, detail);

        const target: ?*StoryRow = switch (identity.kind) {
            .single => null,
            .session, .subagent, .search => blk: {
                for (rows.items) |*row| {
                    if (row.identity.kind == identity.kind and std.mem.eql(u8, row.identity.key, identity.key)) break :blk row;
                }
                break :blk null;
            },
            .subagent_wait => blk: {
                // A bare wait or status says what main did while its
                // subagents worked, so it keeps a row of its own. Later
                // calls with the same action join it with their latest state;
                // a status and a wait stay apart, so neither hides the other.
                for (rows.items) |*row| {
                    if (row.identity.kind == .subagent_wait and std.mem.eql(u8, row.identity.key, identity.key)) break :blk row;
                }
                break :blk null;
            },
            .command, .read => blk: {
                if (rows.items.len == 0) break :blk null;
                const last = &rows.items[rows.items.len - 1];
                if (last.identity.kind == identity.kind and std.mem.eql(u8, last.identity.key, identity.key)) break :blk last;
                break :blk null;
            },
        };
        if (target) |row| {
            row.count += 1;
            if (storyRowCallFailed(detail)) row.failures += 1;
            row.entry = entry;
            row.entry_id = entry_id;
            row.detail = detail;
            try addSearchPath(scratch, row, detail);
            continue;
        }
        try rows.append(scratch, .{
            .entry = entry,
            .entry_id = entry_id,
            .detail = detail,
            .identity = identity,
            .failures = if (storyRowCallFailed(detail)) 1 else 0,
        });
        try addSearchPath(scratch, &rows.items[rows.items.len - 1], detail);
    }
    return rows;
}

const StoryRowText = struct {
    /// The phrase and the merge note together.
    display: []const u8,
    /// The phrase alone, which clips first when the row is too wide.
    body: []const u8,
    /// How many calls share the row, such as " ×3" or " · 2 calls".
    suffix: []const u8,
    split_failure: ?SplitFailure,
};

/// One row's phrase: the recorded status of its latest call, then how many
/// calls share the row. A command that passed after failing says so, so the
/// earlier failures stay in the story.
fn storyRowText(scratch: std.mem.Allocator, row: StoryRow, style: SummaryStyle) !StoryRowText {
    const merged_read = row.identity.kind == .read and row.count > 1;
    const status_phrase = if (merged_read)
        try scratch.print("Read {f}", .{text_utils.terminalSafe(row.identity.key)})
    else
        switch (row.entry) {
            .raw_bytes => |raw| try normalizeCanonicalStatus(scratch, raw.bytes),
            else => null,
        } orelse if (row.detail) |record| record.tool_name else "tool activity";
    const split_failure = splitFailedPhrase(status_phrase, row.detail);
    const raw_phrase = if (split_failure) |split| split.row else status_phrase;
    const full_phrase = try reprojectTruncatedCommandPhrase(scratch, raw_phrase, row.detail) orelse raw_phrase;
    const phrase = if (try shortenCommandPhrase(scratch, full_phrase, row.detail, style.text_style)) |short|
        short
    else
        try highlightCommandPhrase(scratch, full_phrase, row.detail, style.text_style) orelse full_phrase;
    // A pattern searched in several folders names them, so its calls do not
    // look like one search made twice.
    const many_folders = row.identity.kind == .search and row.search_paths.items.len > 1;
    const display = if (many_folders)
        try scratch.print("{s} in {s}", .{ phrase, try searchFolderNames(scratch, row.search_paths.items) })
    else
        phrase;
    const passed_after_failing = row.failures > 0 and row.detail != null and
        row.detail.?.outcome != null and !storyCallFailed(row.detail);
    const suffix: []const u8 = if (row.count < 2) "" else switch (row.identity.kind) {
        .command => if (passed_after_failing)
            try scratch.print(" ×{d} · passed on the {d}{s} run", .{ row.count, row.count, ordinalSuffix(row.count) })
        else
            try scratch.print(" ×{d}", .{row.count}),
        .session => try scratch.print(" · {d} calls", .{row.count}),
        .read => try scratch.print(" · {d} parts", .{row.count}),
        .search => if (many_folders) "" else try scratch.print(" ×{d}", .{row.count}),
        .single, .subagent, .subagent_wait => "",
    };
    return .{
        .display = if (suffix.len == 0) display else try scratch.print("{s}{s}", .{ display, suffix }),
        .body = display,
        .suffix = suffix,
        .split_failure = split_failure,
    };
}

/// A phrase that still says the call is running, such as the status line
/// `fx ask` prints when a command starts and never rewrites.
fn phraseShowsProgress(phrase: []const u8) bool {
    return std.mem.startsWith(u8, phrase, "Running ");
}

/// Whether a row's own status already says it failed, as an old record with
/// no exit code can ("Exited 1 make"), so it never gets a ✓.
fn phraseNamesFailure(phrase: []const u8) bool {
    const labels = [_][]const u8{ "Exited ", "Failed", "Timed out", "Killed", "Denied", "Cancelled" };
    for (labels) |label| if (std.mem.startsWith(u8, phrase, label)) return true;
    return false;
}

fn ordinalSuffix(number: usize) []const u8 {
    if (number % 100 >= 11 and number % 100 <= 13) return "th";
    return switch (number % 10) {
        1 => "st",
        2 => "nd",
        3 => "rd",
        else => "th",
    };
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

/// The line of command output that says what went wrong: the first line that
/// mentions an error or a failure, else the last line.
/// Command output kept in its escaped form, where text_utils.encodeTerminalSafe
/// writes every control byte, line feeds included, as "\xNN", gets its escaped
/// line feeds back as line breaks, so the reason line can pick one line of it.
/// Text with real line breaks is returned as is.
fn storyOutputLines(scratch: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.findScalar(u8, text, '\n') != null) return text;
    if (std.mem.find(u8, text, "\\x0a") == null) return text;
    return std.mem.replaceOwned(u8, scratch, text, "\\x0a", "\n");
}

fn verdictLine(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (containsIgnoreCase(trimmed, "error") or containsIgnoreCase(trimmed, "fail")) return trimmed;
    }
    return lastNonEmptyLine(text);
}

fn lastNonEmptyLine(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitBackwardsScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) return trimmed;
    }
    return null;
}

fn firstNonEmptyLine(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) return trimmed;
    }
    return null;
}

fn storyCallFailed(detail: ?*const ToolDetailRecord) bool {
    const record = detail orelse return false;
    if (record.fallback_disposition != null) return false;
    const failed = if (record.outcome) |outcome| outcome == .failed else false;
    return failed or commandProcessFailed(record);
}

/// A failed non-command row reads "Failed <target>: <error>". Splits it so the
/// row keeps "Failed <target>" and the error moves to the reason line.
const SplitFailure = struct { row: []const u8, reason: []const u8 };

fn splitFailedPhrase(phrase: []const u8, detail: ?*const ToolDetailRecord) ?SplitFailure {
    const record = detail orelse return null;
    if (record.activity_kind == .command or !storyCallFailed(detail)) return null;
    const colon = std.mem.find(u8, phrase, ": ") orelse return null;
    // "Failed: <action>: <error>", as `fx ask` writes it, names no target
    // before its first colon, so the row keeps the whole phrase.
    if (std.mem.eql(u8, std.mem.trim(u8, phrase[0..colon], " "), "Failed")) return null;
    const reason = std.mem.trim(u8, phrase[colon + 2 ..], " ");
    if (reason.len == 0) return null;
    return .{ .row = phrase[0..colon], .reason = reason };
}

/// One plain line that says why a call failed, such as
/// "exit 1 · 1 failed: backoff adds 500ms". Null for calls that did not fail
/// and for failures whose output has no line to show.
fn storyFailureReason(scratch: std.mem.Allocator, detail: ?*const ToolDetailRecord) !?[]const u8 {
    const record = detail orelse return null;
    if (!storyCallFailed(detail)) return null;

    var out: std.Io.Writer.Allocating = .init(scratch);
    const w = &out.writer;
    if (record.command_process_presentation) |presentation| switch (presentation) {
        .exit_code => |code| try w.print("exit {d}", .{code}),
        .signal => |signal| try w.print("signal {d}", .{signal}),
        .timed_out => try w.writeAll("timed out"),
        .output_capture_failed => try w.writeAll("output not captured"),
    };
    const is_command = record.activity_kind == .command;
    const line: ?[]const u8 = if (record.result) |result| blk: {
        // Command details keep the plain output, where the line that names
        // the error says the most; other tools lead with their error.
        const plain_line = if (is_command) verdictLine(try storyOutputLines(scratch, result)) else firstNonEmptyLine(result);
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, scratch, result, .{}) catch break :blk plain_line;
        if (parsed != .object) break :blk plain_line;
        if (parsed.object.get("output_delta")) |value| if (value == .string) break :blk verdictLine(value.string);
        if (parsed.object.get("error")) |value| if (value == .string) break :blk firstNonEmptyLine(value.string);
        if (parsed.object.get("message")) |value| if (value == .string) break :blk firstNonEmptyLine(value.string);
        break :blk null;
    } else null;
    // Without a line of output the reason would only repeat the row's own
    // status, such as "Exited 2" or "Timed out", so there is no reason line.
    const text = line orelse return null;
    const safe = try storySafeLine(scratch, text, 160);
    if (safe.len == 0) return null;
    if (out.written().len > 0) try w.writeAll(" · ");
    try w.writeAll(safe);
    return out.written();
}

/// The recap a turn summary leads with: "1 file changed +2 -1 · ran 4
/// commands · ". It has no result mark, since the group headers show how
/// each command ended. Empty when the turn changed and ran nothing.
fn formatTurnRecap(scratch: std.mem.Allocator, tally: StoryTally) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(scratch);
    const w = &out.writer;
    const changed = tally.changedFiles();
    if (changed > 0) {
        try w.print("{d} {s} changed", .{ changed, pluralWord(changed, "file", "files") });
        if (tally.diff.added > 0) try w.print(" +{d}", .{tally.diff.added});
        if (tally.diff.removed > 0) try w.print(" -{d}", .{tally.diff.removed});
        try w.writeAll(" · ");
    }
    if (tally.last_command_failed != null) {
        try w.print("ran {d} {s} · ", .{ tally.commands, pluralWord(tally.commands, "command", "commands") });
    }
    // A turn that handed its work to subagents did more than explore.
    if (changed == 0 and tally.commands == 0 and tally.subagent_calls == 0 and tally.read_paths.items.len > 0) {
        const reads = tally.read_paths.items.len;
        try w.print("explored {d} {s} · ", .{ reads, pluralWord(reads, "file", "files") });
    }
    const recap = out.written();
    if (recap.len > 0) recap[0] = std.ascii.toUpper(recap[0]);
    return recap;
}

/// Inserts the turn recap before the first visible character of a turn
/// summary row, after its indent and any leading style. Null when the turn
/// has nothing to recap or the longer row would not fit `cols`, since the
/// painter shows a turn summary as it is and never wraps it. Caller owns it.
fn recapTurnSummary(
    alloc: std.mem.Allocator,
    entries: []const TranscriptEntry,
    details: []const ToolDetailRecord,
    detail_indices: *const std.AutoHashMapUnmanaged(u32, usize),
    summary_index: usize,
    cols: u16,
) !?[]u8 {
    const summary_bytes = switch (entries[summary_index]) {
        .raw_bytes => |raw| raw.bytes,
        else => return null,
    };
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(scratch_state);
    const scratch = scratch_state.allocator();

    var turn_start = summary_index;
    while (turn_start > 0) {
        const entry = entries[turn_start - 1];
        const boundary = switch (entry) {
            .user_turn => true,
            .raw_bytes => |raw| raw.class == .turn_summary or raw.class == .turn_cancellation,
            else => false,
        };
        if (boundary) break;
        turn_start -= 1;
    }
    var tally: StoryTally = .{};
    for (entries[turn_start..summary_index]) |entry| {
        const entry_id = toolStatusEntryId(entry) orelse continue;
        const detail = detailForEntry(details, detail_indices, entry_id, null);
        if (statusNamesAsk(entry, detail)) continue;
        try tally.observe(scratch, entry, detail);
    }
    const recap = try formatTurnRecap(scratch, tally);
    if (recap.len == 0) return null;

    var insert_at: usize = 0;
    while (insert_at < summary_bytes.len) {
        if (skipSgrSequence(summary_bytes, &insert_at)) continue;
        if (summary_bytes[insert_at] != ' ') break;
        insert_at += 1;
    }
    const recapped = try scratch.print("{s}{s}{s}", .{ summary_bytes[0..insert_at], recap, summary_bytes[insert_at..] });
    if (display_width.visibleWidthIgnoringAnsi(std.mem.trimEnd(u8, recapped, "\n")) > cols) return null;
    return try alloc.dupe(u8, recapped);
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
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(scratch_state);
    const scratch = scratch_state.allocator();

    var tally: StoryTally = .{};
    var focused_in_group = false;
    for (status_indices) |status_index| {
        const entry = entries[status_index];
        const entry_id = toolStatusEntryId(entry) orelse continue;
        const detail = detailForEntry(details, detail_indices, entry_id, null);
        if (statusNamesAsk(entry, detail)) continue;
        if (focused_entry_id == entry_id) focused_in_group = true;
        try tally.observe(scratch, entry, detail);
    }
    const rows = try collectStoryRows(scratch, entries, status_indices, details, detail_indices, focused_entry_id);
    var last_command_row: ?usize = null;
    for (rows.items, 0..) |row, index| {
        if (row.detail) |record| if (record.activity_kind == .command) {
            last_command_row = index;
        };
    }
    for (rows.items, 0..) |row, index| {
        if (index != last_command_row and storyRowCallFailed(row.detail)) tally.earlier_command_failures += 1;
    }

    // A group left with one row needs no summary above it: the row is the
    // header, so nothing is said twice.
    const single_row: ?StoryRow = if (!focused_in_group and rows.items.len == 1) rows.items[0] else null;
    const single_text: ?StoryRowText = if (single_row) |row| try storyRowText(scratch, row, style) else null;

    const header = if (single_row) |row| blk: {
        const text = single_text.?;
        const succeeded_command = if (row.detail) |record|
            record.activity_kind == .command and record.outcome == .completed and
                !storyCallFailed(row.detail) and !phraseNamesFailure(text.display) and
                !phraseShowsProgress(text.display)
        else
            false;
        // A failure the phrase does not name, such as a status line `fx ask`
        // never rewrites, still shows on the header.
        const unnamed_failure = storyCallFailed(row.detail) and !phraseNamesFailure(text.display);
        const mark = if (succeeded_command) " ✓" else if (unnamed_failure) " ✗" else "";
        const shows_diff_stats = entryShowsDiffStats(row.detail);
        // The merge note and the mark stay when the phrase is clipped, like
        // the diff counts.
        const clipped = if (shows_diff_stats) clip: {
            const line = try scratch.print("● {s}", .{text.display});
            const mark_width: u16 = @intCast(display_width.visibleWidthIgnoringAnsi(mark));
            const phrase_cols = if (cols > mark_width * 2) cols - mark_width else cols;
            const clipped_phrase = try clipKeepingDiffStats(scratch, line, phrase_cols);
            break :clip if (phrase_cols == cols) clipped_phrase else try scratch.print("{s}{s}", .{ clipped_phrase, mark });
        } else try clipKeepingTail(
            scratch,
            try scratch.print("● {s}", .{text.body}),
            try scratch.print("{s}{s}", .{ text.suffix, mark }),
            cols,
            style.text_style,
        );
        const accented = if (shows_diff_stats) try accentTrailingDiffStats(scratch, clipped, style.text_style) else clipped;
        break :blk try applySummaryStyle(alloc, accented, style);
    } else if (try formatStoryHeader(scratch, tally, summary, style)) |story| blk: {
        const clipped = try clipStoryHeader(scratch, story, cols);
        break :blk try applySummaryStyle(alloc, clipped, style);
    } else try formatGroupHeader(alloc, summary, cols, style);
    defer alloc.free(header);
    var lines: std.ArrayList(transcript_blocks.LineProvenance) = .empty;
    errdefer lines.deinit(alloc);
    const header_entry_id = if (single_row) |row| row.entry_id else entries[status_indices[0]].id();
    try lines.append(alloc, .{ .entry = .{ .entry_id = header_entry_id, .entry_class = .tool_status, .projection_part = .group_header } });
    if (collapse_tool_calls) {
        const bytes = try alloc.dupe(u8, header);
        errdefer alloc.free(bytes);
        return .{ .bytes = bytes, .lines = try lines.toOwnedSlice(alloc) };
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll(header);

    if (single_row) |row| {
        try writeRowDetails(alloc, scratch, &out.writer, &lines, row, single_text.?, "  ", cols, style);
    } else for (rows.items, 0..) |row, row_index| {
        const text = try storyRowText(scratch, row, style);
        const last_static_row = !focused_in_group and row_index + 1 == rows.items.len;
        const connector = if (last_static_row) "└" else "├";
        const shows_diff_stats = entryShowsDiffStats(row.detail);
        const clipped = if (shows_diff_stats)
            try clipKeepingDiffStats(scratch, try scratch.print("{s} {s}", .{ connector, text.display }), cols)
        else
            try clipKeepingTail(scratch, try scratch.print("{s} {s}", .{ connector, text.body }), text.suffix, cols, style.text_style);
        try lines.append(alloc, .{ .entry = .{ .entry_id = row.entry_id, .entry_class = .tool_status, .projection_part = .group_child } });
        const accented = if (shows_diff_stats)
            try accentTrailingDiffStats(scratch, clipped, style.text_style)
        else
            clipped;
        try out.writer.writeByte('\n');
        if (style.text_style.len > 0) try out.writer.writeAll(style.text_style);
        try out.writer.writeAll(accented);
        if (style.text_style.len > 0) try out.writer.writeAll(style.reset_style);
        try writeRowDetails(alloc, scratch, &out.writer, &lines, row, text, if (last_static_row) "  " else "│ ", cols, style);
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

/// The lines under a row: a subagent's model line and the reason its latest
/// call failed, each behind `indent`.
fn writeRowDetails(
    alloc: std.mem.Allocator,
    scratch: std.mem.Allocator,
    writer: *std.Io.Writer,
    lines: *std.ArrayList(transcript_blocks.LineProvenance),
    row: StoryRow,
    text: StoryRowText,
    indent: []const u8,
    cols: u16,
    style: SummaryStyle,
) !void {
    if (subagentStatusContinuation(row.entry, row.detail)) |continuation| {
        const continuation_row = try scratch.print("{s}{s}", .{ indent, continuation });
        const clipped_continuation = try clipSummary(scratch, continuation_row, cols);
        try lines.append(alloc, .{ .entry = .{ .entry_id = row.entry_id, .entry_class = .tool_status, .projection_part = .group_child } });
        try writer.writeByte('\n');
        if (style.text_style.len > 0) try writer.writeAll(style.text_style);
        try writer.writeAll(clipped_continuation);
        if (style.text_style.len > 0) try writer.writeAll(style.reset_style);
    }
    const failure_reason = if (text.split_failure) |split|
        try storySafeLine(scratch, split.reason, 160)
    else
        try storyFailureReason(scratch, row.detail);
    if (failure_reason) |reason| {
        const failure_row = try scratch.print("{s}✗ {s}", .{ indent, reason });
        const clipped_failure = try clipSummary(scratch, failure_row, cols);
        try lines.append(alloc, .{ .entry = .{ .entry_id = row.entry_id, .entry_class = .tool_status, .projection_part = .group_child } });
        try writer.writeByte('\n');
        try writer.writeAll(ui_render.red_style);
        try writer.writeAll(clipped_failure);
        try writer.writeAll(ui_render.reset_style);
    }
}

/// The minimum tail length accepted as an identity match in
/// reprojectTruncatedCommandPhrase. Genuinely truncated command phrases carry
/// roughly 116 bytes of command prefix (the compact activity bound), so a long
/// threshold cannot reject a real row; it exists to stop a short coincidental
/// tail from rewriting an unrelated one.
const min_reclip_tail_bytes = 16;

/// Returns the longest suffix of `text` that is also a prefix of `base`, when
/// it is long enough to prove the two share a command. O(n^2) over a frozen
/// phrase of at most ~120 bytes; the loop count is bounded and tiny.
fn commandTailMatch(text: []const u8, base: []const u8) ?[]const u8 {
    var len: usize = @min(text.len, base.len);
    while (len >= min_reclip_tail_bytes) : (len -= 1) {
        const tail = text[text.len - len ..];
        if (std.mem.startsWith(u8, base, tail)) return tail;
    }
    return null;
}

/// Substitutes the stored full command for a status phrase that was truncated
/// to the compact activity bound at generation time. Records carry the full
/// display whenever the command is known — captured runs, tty runs, and
/// terminal-session actions — so the phrase can be reclipped to the live
/// terminal width instead of keeping the frozen "..." marker.
///
/// The row's own leading label is preserved ("Running", "Ran", "Exited 1"):
/// the stored action label is a start-time prediction that cannot know the
/// settled outcome, and an active row must never be rewritten to the
/// completed label. Identity is proven by the command itself — the frozen
/// tail is a generation-time prefix of the stored display — which is a
/// stronger guard than comparing the predicted label against the row.
fn reprojectTruncatedCommandPhrase(
    scratch: std.mem.Allocator,
    phrase: []const u8,
    detail: ?*const ToolDetailRecord,
) !?[]const u8 {
    const record = detail orelse return null;
    if (!std.mem.endsWith(u8, phrase, "...")) return null;
    const command = record.command_display orelse return null;
    if (command.len == 0) return null;
    const body = phrase[0 .. phrase.len - "...".len];
    const tail = commandTailMatch(body, command) orelse return null;
    const label = body[0 .. body.len - tail.len];
    if (label.len == 0 or label[label.len - 1] != ' ') return null;
    return try scratch.print("{s}{s}", .{ label, command });
}

/// A one-step command up to this many bytes keeps its full text in a row.
const short_command_max_len = 60;

/// Programs that change the shell's own state rather than run work, so a
/// step that starts with one says nothing about what the command did.
const shell_setup_programs = std.StaticStringMap(void).initComptime(.{
    .{"cd"},     .{"pushd"}, .{"popd"},  .{"export"},   .{"set"},    .{"unset"},
    .{"source"}, .{"."},     .{"true"},  .{":"},        .{"exit"},   .{"wait"},
    .{"trap"},   .{"shopt"}, .{"alias"}, .{"ulimit"},   .{"umask"},  .{"["},
    .{"[["},     .{"test"},  .{"break"}, .{"continue"}, .{"return"},
});

/// Shell words that lead into the command after them.
const leading_keywords = std.StaticStringMap(void).initComptime(.{
    .{"if"}, .{"then"}, .{"else"}, .{"elif"}, .{"do"}, .{"while"}, .{"until"}, .{"!"},
});

/// Shell words whose whole step runs no program of its own, such as a loop's
/// header or its end.
const step_keywords = std.StaticStringMap(void).initComptime(.{
    .{"for"}, .{"select"}, .{"case"}, .{"esac"}, .{"done"}, .{"fi"}, .{"in"}, .{"function"},
});

/// Programs that run the program after them.
const wrapper_programs = std.StaticStringMap(void).initComptime(.{
    .{"sudo"}, .{"time"},    .{"nohup"}, .{"exec"},    .{"command"},
    .{"env"},  .{"builtin"}, .{"nice"},  .{"timeout"},
});

/// Programs that only reshape the output of the step before a pipe.
const output_filter_programs = std.StaticStringMap(void).initComptime(.{
    .{"head"},   .{"tail"}, .{"grep"}, .{"rg"},   .{"egrep"}, .{"fgrep"},
    .{"jq"},     .{"sed"},  .{"awk"},  .{"sort"}, .{"uniq"},  .{"wc"},
    .{"cut"},    .{"tr"},   .{"tee"},  .{"less"}, .{"more"},  .{"cat"},
    .{"column"}, .{"fold"}, .{"nl"},
});

/// Programs whose next words are arguments, not subcommands.
const plain_programs = std.StaticStringMap(void).initComptime(.{
    .{"echo"},     .{"printf"},   .{"cat"},   .{"ls"},    .{"grep"},     .{"rg"},
    .{"find"},     .{"fd"},       .{"sed"},   .{"awk"},   .{"head"},     .{"tail"},
    .{"sleep"},    .{"rm"},       .{"cp"},    .{"mv"},    .{"mkdir"},    .{"rmdir"},
    .{"touch"},    .{"chmod"},    .{"chown"}, .{"ln"},    .{"wc"},       .{"sort"},
    .{"uniq"},     .{"cut"},      .{"tr"},    .{"tee"},   .{"xargs"},    .{"which"},
    .{"test"},     .{"pwd"},      .{"date"},  .{"curl"},  .{"wget"},     .{"jq"},
    .{"diff"},     .{"stat"},     .{"du"},    .{"df"},    .{"ps"},       .{"kill"},
    .{"pkill"},    .{"pgrep"},    .{"open"},  .{"tar"},   .{"unzip"},    .{"zip"},
    .{"ssh"},      .{"scp"},      .{"rsync"}, .{"file"},  .{"basename"}, .{"dirname"},
    .{"realpath"}, .{"readlink"}, .{"seq"},   .{"watch"}, .{"uname"},    .{"whoami"},
});

/// Shells whose `-c` flag runs the script that follows it.
const shell_programs = std.StaticStringMap(void).initComptime(.{
    .{"sh"}, .{"bash"}, .{"zsh"}, .{"dash"}, .{"ksh"},
});

/// How deep the short form looks into `sh -c` scripts inside `sh -c` scripts.
const short_command_max_depth = 2;

/// Programs that run a script named by their first argument.
const interpreter_programs = std.StaticStringMap(void).initComptime(.{
    .{"sh"},      .{"bash"}, .{"zsh"}, .{"dash"}, .{"fish"}, .{"python"},
    .{"python3"}, .{"node"}, .{"bun"}, .{"deno"}, .{"ruby"}, .{"perl"},
    .{"php"},     .{"tsx"},
});

const command_operators = std.StaticStringMap(void).initComptime(.{
    .{";"}, .{"("}, .{")"}, .{"{"}, .{"}"}, .{"|"}, .{"||"}, .{"&"}, .{"&&"},
});

const redirection_operators = std.StaticStringMap(void).initComptime(.{
    .{"<"},  .{">"},  .{">>"}, .{"<<"},  .{"<<<"}, .{"<&"}, .{"<>"},
    .{">|"}, .{">&"}, .{"&>"}, .{"&>>"},
});

/// One step of a shell command as the short form shows it.
const ShortStep = struct {
    program: []const u8 = "",
    words: [2][]const u8 = .{ "", "" },
    word_count: usize = 0,
    /// The step's own words are done: a flag, a path, or quoted text ended
    /// them, or its program takes none.
    closed: bool = false,
    /// A wrapper such as `timeout` came first, so its flags and its number
    /// are skipped until the program it runs.
    after_wrapper: bool = false,
    /// git's `-C <dir>` and `-c <key=value>` take the next token.
    skip_next: bool = false,
    after_pipe: bool = false,
    /// A loop header or a block's end, which the short form leaves out.
    dropped: bool = false,
    /// A shell's `-c` came, so the next token is the script it runs.
    script_flag: bool = false,
    /// The script a `sh -c` step runs, whose own steps the short form shows.
    inline_script: ?[]const u8 = null,
};

fn isWordToken(token: command_lex.ArgvToken) bool {
    if (token.quoted or token.value.len == 0) return false;
    if (!std.ascii.isLower(token.value[0])) return false;
    for (token.value) |byte| {
        if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '-' or byte == '_' or byte == ':')) return false;
    }
    return true;
}

fn looksLikeWrapperArgument(value: []const u8) bool {
    if (value.len == 0) return false;
    if (value[0] == '-') return true;
    // A duration or a count: "30", "5m", "1.5s".
    if (!std.ascii.isDigit(value[0])) return false;
    for (value) |byte| if (!(std.ascii.isDigit(byte) or byte == '.' or std.ascii.isLower(byte))) return false;
    return true;
}

/// A program as the short form names it: the base name of a path, except a
/// script in the current folder ("./build.sh"), which stays as written.
fn shortProgramName(value: []const u8) []const u8 {
    const slash = std.mem.findScalarLast(u8, value, '/') orelse return value;
    if (std.mem.startsWith(u8, value, "./") and slash == 1) return value;
    return value[slash + 1 ..];
}

fn addShortToken(step: *ShortStep, token: command_lex.ArgvToken) void {
    const value = token.value;
    if (step.program.len == 0) {
        if (command_lex.is_safe_env_assignment(value) or isEnvAssignment(value)) return;
        // The `$` of a leading `$( ... )`, whose program comes after it.
        if (!token.quoted and std.mem.eql(u8, value, "$")) return;
        if (step.after_wrapper and looksLikeWrapperArgument(value)) return;
        if (wrapper_programs.has(value)) {
            step.after_wrapper = true;
            return;
        }
        if (!token.quoted and leading_keywords.has(value)) return;
        if (!token.quoted and step_keywords.has(value)) {
            step.program = value;
            step.dropped = true;
            step.closed = true;
            return;
        }
        step.program = shortProgramName(value);
        if (plain_programs.has(step.program)) step.closed = true;
        return;
    }
    if (step.closed) return;
    if (step.script_flag) {
        step.inline_script = value;
        step.closed = true;
        return;
    }
    // `sh -c`, `bash -lc`: the next token is the script the shell runs.
    if (step.word_count == 0 and shell_programs.has(step.program) and !token.quoted and
        value.len > 1 and value[0] == '-' and value[1] != '-' and std.mem.findScalar(u8, value, 'c') != null)
    {
        step.script_flag = true;
        return;
    }
    if (step.skip_next) {
        step.skip_next = false;
        return;
    }
    if (step.word_count == 0 and std.mem.eql(u8, step.program, "git") and token.value.len > 0 and value[0] == '-') {
        step.skip_next = std.mem.eql(u8, value, "-C") or std.mem.eql(u8, value, "-c");
        return;
    }
    if (isWordToken(token)) {
        step.words[step.word_count] = value;
        step.word_count += 1;
        if (step.word_count == step.words.len) step.closed = true;
        return;
    }
    // An interpreter's first argument names the script it runs, quoted or not.
    if (step.word_count == 0 and interpreter_programs.has(step.program) and value.len > 0 and value[0] != '-') {
        step.words[0] = shortProgramName(value);
        if (std.mem.startsWith(u8, step.words[0], "./")) step.words[0] = step.words[0][2..];
        step.word_count = 1;
    }
    step.closed = true;
}

fn isEnvAssignment(value: []const u8) bool {
    const eq = std.mem.findScalar(u8, value, '=') orelse return false;
    if (eq == 0) return false;
    for (value[0..eq], 0..) |byte, index| {
        const ok = byte == '_' or std.ascii.isAlphabetic(byte) or (index > 0 and std.ascii.isDigit(byte));
        if (!ok) return false;
    }
    return true;
}

/// The errors of the short-form step walk, which recurses into `sh -c`
/// scripts and so cannot infer them.
const ShortStepError = std.mem.Allocator.Error || std.Io.Writer.Error;

fn finishShortStep(
    scratch: std.mem.Allocator,
    steps: *std.ArrayList([]const u8),
    raw_steps: *usize,
    step: ShortStep,
    depth: usize,
) ShortStepError!void {
    if (step.program.len == 0 and !step.after_wrapper) return;
    // A `sh -c` step shows the steps of its script, when they lex.
    if (step.inline_script) |script| if (depth < short_command_max_depth) {
        const before = steps.items.len;
        if (try collectShortSteps(scratch, script, steps, raw_steps, depth + 1) and steps.items.len > before) return;
    };
    raw_steps.* += 1;
    if (step.dropped or step.program.len == 0 or shell_setup_programs.has(step.program)) return;
    if (step.after_pipe and output_filter_programs.has(step.program)) return;
    var text: std.Io.Writer.Allocating = .init(scratch);
    try text.writer.writeAll(step.program);
    for (step.words[0..step.word_count]) |word| try text.writer.print(" {s}", .{word});
    try steps.append(scratch, text.written());
}

/// The closing byte of the expansion that the token at `index` opens: `)`
/// for the `(` of a `$(`, and `}` for a `{` right after a `$` or with no
/// space after it, as in `${name}` and `{1..80}`. A `{ cmd; }` group has the
/// space, so it opens no expansion. Null for other tokens.
fn expansionClose(command: []const u8, tokens: []const command_lex.ArgvToken, index: usize) ?u8 {
    const token = tokens[index];
    if (token.quoted or token.value.len != 1) return null;
    const after_dollar = token.start > 0 and command[token.start - 1] == '$';
    return switch (token.value[0]) {
        '(' => if (after_dollar) ')' else null,
        '{' => if (after_dollar or (token.end < command.len and !std.ascii.isWhitespace(command[token.end]))) '}' else null,
        else => null,
    };
}

/// Whether the token at `index` is the file descriptor of a redirection
/// right after it, as the `2` in `2>&1`.
fn isRedirectionFd(tokens: []const command_lex.ArgvToken, index: usize) bool {
    const token = tokens[index];
    if (token.quoted or token.value.len == 0 or index + 1 >= tokens.len) return false;
    for (token.value) |byte| if (!std.ascii.isDigit(byte)) return false;
    const next = tokens[index + 1];
    return !next.quoted and next.start == token.end and redirection_operators.has(next.value);
}

fn expansionOpen(close: u8) u8 {
    return if (close == ')') '(' else '{';
}

fn gapHasNewline(command: []const u8, from: usize, to: usize) bool {
    if (from >= to) return false;
    return std.mem.findScalar(u8, command[from..to], '\n') != null;
}

/// A shell command's short form: the first steps it runs, and how many more.
const ShortCommand = struct {
    steps: []const []const u8,
    more: usize,
};

const short_command_max_steps = 3;

/// The short form as plain text, such as "npm ci, npm run build".
fn shortCommand(scratch: std.mem.Allocator, command: []const u8) !?[]const u8 {
    const short = try shortCommandSteps(scratch, command) orelse return null;
    return try formatShortCommand(scratch, short, null);
}

/// Writes a short form, with every step made terminal-safe. With a style,
/// each step takes the shell palette on its own, so every step's program
/// shows in the same color, and the ", " between them stays plain.
fn formatShortCommand(scratch: std.mem.Allocator, short: ShortCommand, base_style: ?[]const u8) ![]const u8 {
    const profile = if (base_style != null) code_highlight_languages.resolve("sh") else null;
    const variant: code_highlight.Theme = if (shared_theme.current().light) .light else .dark;
    var out: std.Io.Writer.Allocating = .init(scratch);
    for (short.steps, 0..) |step, position| {
        if (position > 0) try out.writer.writeAll(", ");
        const safe = try scratch.print("{f}", .{text_utils.terminalSafe(step)});
        if (profile) |shell| {
            const style = base_style.?;
            try out.writer.writeAll(try code_highlight.highlight(scratch, safe, shell, variant, if (style.len > 0) style else null));
        } else try out.writer.writeAll(safe);
    }
    if (short.more > 0) try out.writer.print(" +{d} more", .{short.more});
    return out.written();
}

/// The steps a shell command runs, by program and subcommand, without flags,
/// arguments, `cd`, variables, wrappers, and output filters, so
/// "cd desktop && npm ci --no-audit && npm run build -- --mode production"
/// is "npm ci, npm run build". A one-step command of at most
/// short_command_max_len bytes keeps its full text. Null when the command
/// keeps its text or does not lex. The steps live in `scratch`.
fn shortCommandSteps(scratch: std.mem.Allocator, command: []const u8) !?ShortCommand {
    var steps: std.ArrayList([]const u8) = .empty;
    var raw_steps: usize = 0;
    if (!try collectShortSteps(scratch, command, &steps, &raw_steps, 0)) return null;
    // The same step twice in a row shows once.
    var shown: std.ArrayList([]const u8) = .empty;
    for (steps.items) |text| {
        if (shown.items.len > 0 and std.mem.eql(u8, shown.items[shown.items.len - 1], text)) continue;
        try shown.append(scratch, text);
    }
    if (shown.items.len == 0) return null;
    if (raw_steps <= 1 and command.len <= short_command_max_len) return null;
    // A command that is already its own short form keeps its text.
    if (shown.items.len == 1 and std.mem.eql(u8, shown.items[0], command)) return null;
    const kept = @min(shown.items.len, short_command_max_steps);
    return .{ .steps = shown.items[0..kept], .more = shown.items.len - kept };
}

/// Appends the steps `command` runs to `steps`, and counts every step it has,
/// shown or not, in `raw_steps`. False when the command does not lex.
fn collectShortSteps(
    scratch: std.mem.Allocator,
    command: []const u8,
    steps: *std.ArrayList([]const u8),
    raw_steps: *usize,
    depth: usize,
) ShortStepError!bool {
    const argv = command_lex.tokenize_argv(scratch, command) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    const tokens = argv.tokens;

    var step: ShortStep = .{};
    var index: usize = 0;
    while (index <= tokens.len) : (index += 1) {
        const at_end = index == tokens.len;
        const token: ?command_lex.ArgvToken = if (at_end) null else tokens[index];
        // A comment runs to the end of its line.
        if (!at_end and !tokens[index].quoted and std.mem.startsWith(u8, tokens[index].raw, "#")) {
            while (index + 1 < tokens.len and !gapHasNewline(command, tokens[index].end, tokens[index + 1].start)) index += 1;
            continue;
        }
        // A command substitution, `$( ... )`, and an expansion such as
        // `{1..80}` or `${name}` belong to the word around them.
        if (!at_end) if (expansionClose(command, tokens, index)) |close| {
            var nesting: usize = 0;
            while (index < tokens.len) : (index += 1) {
                const inner = tokens[index];
                if (inner.quoted or inner.value.len != 1) continue;
                if (inner.value[0] == expansionOpen(close)) nesting += 1;
                if (inner.value[0] == close) {
                    nesting -= 1;
                    if (nesting == 0) break;
                }
            }
            continue;
        };
        const operator = if (token) |t| !t.quoted and command_operators.has(t.value) else false;
        const new_line = if (token) |t| index > 0 and gapHasNewline(command, tokens[index - 1].end, t.start) else false;
        const heredoc_end = blk: {
            const t = token orelse break :blk false;
            if (t.quoted or !std.mem.startsWith(u8, t.value, "<<") or std.mem.eql(u8, t.value, "<<<")) break :blk false;
            // A here-document: skip its delimiter and its body, which ends
            // the step at the closing delimiter.
            if (index + 1 >= tokens.len) {
                index = tokens.len - 1;
                break :blk true;
            }
            const delimiter = tokens[index + 1].value;
            var end = index + 2;
            while (end < tokens.len and !std.mem.eql(u8, tokens[end].value, delimiter)) : (end += 1) {}
            index = @min(end, tokens.len - 1);
            break :blk true;
        };
        if (at_end or operator or new_line or heredoc_end) {
            try finishShortStep(scratch, steps, raw_steps, step, depth);
            step = .{ .after_pipe = operator and std.mem.eql(u8, token.?.value, "|") };
            if (operator or heredoc_end or at_end) continue;
        }
        const t = token.?;
        if (isRedirectionFd(tokens, index)) continue;
        if (!t.quoted and redirection_operators.has(t.value)) {
            // A redirection's target is not a word of the step.
            index += 1;
            continue;
        }
        addShortToken(&step, t);
    }
    return true;
}

/// Replaces the command a command row ends with by its short form, so a long
/// command does not fill the row, and colors each step. `base_style` is the
/// row's text style, as for highlightCommandPhrase. The full command stays in
/// Ctrl+O and in approval prompts. Null when the row keeps its full command.
fn shortenCommandPhrase(
    scratch: std.mem.Allocator,
    phrase: []const u8,
    detail: ?*const ToolDetailRecord,
    base_style: []const u8,
) !?[]const u8 {
    const record = detail orelse return null;
    if (record.activity_kind != .command) return null;
    const display = record.command_display orelse return null;
    if (display.len == 0 or phrase.len <= display.len or !std.mem.endsWith(u8, phrase, display)) return null;
    const label = phrase[0 .. phrase.len - display.len];
    if (label[label.len - 1] != ' ') return null;
    // Lex the command as the model sent it. The display folds its lines into
    // one, which would turn a comment line into a comment over the whole
    // command.
    const source = storyArgString(scratch, record, "command") orelse display;
    const short = try shortCommandSteps(scratch, source) orelse return null;
    return try scratch.print("{s}{s}", .{ label, try formatShortCommand(scratch, short, base_style) });
}

/// Shell-highlight the command portion of a command phrase ("Running <cmd>",
/// "Ran <cmd>"). The leading action word and connector stay in the row's
/// ambient style; only the command's syntax tokens pick up palette colors.
/// `base_style` (the row's text style, when any) is re-established after every
/// token close so untokenized text keeps the row's color.
/// Multi-word status labels that can lead a command row when no label was
/// recorded. Mirrors the terminal-outcome labels composed in
/// tool_admission.permissionDeniedStatusLabel and the lifecycle rows.
const known_multiword_labels = [_][]const u8{
    "Denied by auto agent",
    "Review evidence incomplete",
    "Permission required",
    "Safety caution",
    "Review unavailable",
    "Timed out",
};

fn knownLabelPrefix(phrase: []const u8) ?usize {
    for (known_multiword_labels) |label| {
        if (std.mem.startsWith(u8, phrase, label) and phrase.len > label.len and phrase[label.len] == ' ')
            return label.len;
    }
    return null;
}

fn highlightCommandPhrase(
    scratch: std.mem.Allocator,
    phrase: []const u8,
    detail: ?*const ToolDetailRecord,
    base_style: []const u8,
) !?[]const u8 {
    const record = detail orelse return null;
    if (record.activity_kind != .command) return null;
    // Prefer the recorded action label so multi-word labels ("Timed out")
    // split at the true boundary. Otherwise trust the stored command text:
    // prose-prefixed rows ("Reading project instructions before continuing:
    // <cmd>") end with it. Then known multi-word labels, then first space.
    const label_end = if (record.command_action_label) |action|
        if (std.mem.startsWith(u8, phrase, action) and phrase.len > action.len and phrase[action.len] == ' ')
            action.len
        else
            null
    else
        null;
    const display_end = if (record.command_display) |display| blk: {
        if (display.len == 0 or phrase.len <= display.len + 1) break :blk null;
        if (!std.mem.endsWith(u8, phrase, display)) break :blk null;
        const split_at = phrase.len - display.len - 1;
        break :blk if (phrase[split_at] == ' ') split_at else null;
    } else null;
    const split = label_end orelse display_end orelse knownLabelPrefix(phrase) orelse std.mem.findScalar(u8, phrase, ' ') orelse return null;
    const command = phrase[split + 1 ..];
    if (command.len == 0) return null;
    const theme = shared_theme.current();
    const profile = code_highlight_languages.resolve("sh") orelse return null;
    const variant: code_highlight.Theme = if (theme.light) .light else .dark;
    // Commands without tokens keep their exact plain bytes.
    const plain = try code_highlight.highlight(scratch, command, profile, variant, null);
    if (std.mem.eql(u8, plain, command)) return null;
    const highlighted = try code_highlight.highlight(
        scratch,
        command,
        profile,
        variant,
        if (base_style.len > 0) base_style else null,
    );
    return try scratch.print("{s} {s}", .{ phrase[0..split], highlighted });
}

/// One expanded child as complete logical rows. Expanded rows are never
/// clipped; materializeExpandedOverride wraps them to the live width.
/// Ctrl+O's line for one tool call: its state mark, then its phrase at the
/// two-column indent responses use, with no tree marks, and any status
/// continuation under the four-column detail indent.
fn formatExpandedChild(
    alloc: std.mem.Allocator,
    entry: TranscriptEntry,
    detail: ?*const ToolDetailRecord,
) ![]u8 {
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(scratch_state);
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
    // Expanded rows carry no ambient text style, so tokens highlight over the
    // terminal default foreground.
    const display_phrase = try highlightCommandPhrase(scratch, phrase, detail, "") orelse phrase;
    const marker = statusMarker(entry);
    // A colored mark ends its color before the phrase.
    const marker_reset = if (std.mem.findScalar(u8, marker, 0x1b) != null and
        !std.mem.endsWith(u8, marker, ui_render.reset_style))
        ui_render.reset_style
    else
        "";
    const child = try scratch.print("{s}{s} {s}", .{ marker, marker_reset, display_phrase });
    const accented = if (entryShowsDiffStats(detail))
        try accentTrailingDiffStats(scratch, child, "")
    else
        child;
    const continuation = subagentStatusContinuation(entry, detail) orelse return alloc.dupe(u8, accented);
    return alloc.print("{s}\n    {s}", .{ accented, continuation });
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
    const row = try formatExpandedChild(alloc, entry, &detail);
    defer alloc.free(row);

    try std.testing.expectEqualStrings(
        "● reviewer working · inspect auth\n    gpt-5.5 · high · 12k/256k 4%",
        row,
    );
}

/// Every call of a group gets its own line in Ctrl+O, in order, with no
/// group header: the main screen's summary would only repeat them.
fn installExpandedGroup(
    alloc: std.mem.Allocator,
    projection: *Projection,
    entries: []const TranscriptEntry,
    status_indices: []const usize,
    details: []const ToolDetailRecord,
    detail_indices: *const std.AutoHashMapUnmanaged(u32, usize),
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !void {
    for (status_indices) |status_index| {
        try build_checkpoint.tick(checkpoint);
        const entry = entries[status_index];
        const entry_id = toolStatusEntryId(entry) orelse continue;
        const detail = detailForEntry(details, detail_indices, entry_id, null);
        // The projection owns the line from here, and frees it on failure.
        try projection.setOwnedOverride(alloc, status_index, .tool_status, try formatExpandedChild(alloc, entry, detail));
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

/// Full-transcript tool rows fitted to `cols`. Builds the same relationships
/// the live full transcript caches and materializes them, so every
/// full-transcript build shares one width policy.
pub fn buildExpandedStyledInterruptible(
    alloc: std.mem.Allocator,
    entries: []const TranscriptEntry,
    details: []const ToolDetailRecord,
    cols: u16,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !Projection {
    var relationships = try buildExpandedRelationshipsInterruptible(alloc, entries, details, checkpoint);
    defer relationships.deinit(alloc);
    return materializeExpandedRelationshipsRangeInterruptible(alloc, &relationships, 0, cols, checkpoint);
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
                const bytes = try materializeExpandedOverride(alloc, override.bytes, cols);
                try projection.appendOwnedOverride(alloc, override.kind, bytes);
            },
        }
    }
    return projection;
}

/// Fits one expanded override to `cols` without hiding any of it. The full
/// transcript exists to show everything, so rows word-wrap instead of
/// clipping, and each wrapped row continues under the detail indent.
fn materializeExpandedOverride(
    alloc: std.mem.Allocator,
    bytes: []const u8,
    cols: u16,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.writer.writeByte('\n');
        first = false;
        const wrapped = try transcript_blocks.wrapFullToolStatus(alloc, line, cols, "    ");
        defer alloc.free(wrapped);
        try out.writer.writeAll(wrapped);
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
            while (expanded_index < entries.len) : (expanded_index += 1) {
                try build_checkpoint.tick(checkpoint);
                if (presentation_group_indices[expanded_index] != null) break;
                if (toolStatusEntryId(entries[expanded_index])) |group_entry_id| {
                    const group_detail = detailForEntry(details, &detail_indices, group_entry_id, stats);
                    if (statusNamesAsk(entries[expanded_index], group_detail)) break;
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
                checkpoint,
            );
        }
        return projection;
    }

    var index: usize = 0;
    while (index < entries.len) {
        try build_checkpoint.tick(checkpoint);
        // Hidden entries keep their action, but grouping below skips them, so
        // they must not anchor a group either.
        if (projection.entry_actions.items[index] != .keep or
            !transcript_blocks.isEntryVisibleInCompactPresentation(entries[index]))
        {
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
            try projection.setOwnedGroup(alloc, index, bytes);
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
            if (!transcript_blocks.isEntryVisibleInCompactPresentation(entries[index])) continue;
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
        try projection.setOwnedGroup(alloc, first_index, bytes);
    }

    for (entries, 0..) |entry, entry_index| {
        try build_checkpoint.tick(checkpoint);
        const raw = switch (entry) {
            .raw_bytes => |value| value,
            else => continue,
        };
        if (raw.class != .turn_summary or projection.entry_actions.items[entry_index] != .keep) continue;
        if (!transcript_blocks.isEntryVisibleInCompactPresentation(entry)) continue;
        const recapped = try recapTurnSummary(alloc, entries, details, &detail_indices, entry_index, cols) orelse continue;
        try projection.setOwnedOverride(alloc, entry_index, .turn_summary, recapped);
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
    try std.testing.expectEqualStrings("● Read 1 file", block);
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

test "group header names the main event and marks a failed call" {
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
        "● Ran 1 shell command ✓ · 1 failed\n" ++
            "├ Read runtime.zig\n" ++
            "├ Edited main.zig\n" ++
            "└ Ran \x1b[38;5;252mzig\x1b[39m build",
        projection.entry_actions.items[0].override.bytes,
    );
    try std.testing.expect(projection.entry_actions.items[1] == .hide);
    try std.testing.expect(projection.entry_actions.items[2] == .hide);
    try std.testing.expectEqual(types.ToolActivityKind.read, details[0].activity_kind.?);
}

test "grouped subagent status keeps the vertical continuation for middle rows" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Subagent working · inspect auth\n  glm-5.3-flash · max\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "● Subagent working · inspect auth\n  glm-5.3-flash · max\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 3, .bytes = "● Subagent working · inspect auth\n  glm-5.3-flash · max\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 4, .bytes = "● Subagent working · inspect auth\n  glm-5.3-flash · max\n", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("subagent"), .activity_kind = .subagent },
        .{ .entry_id = 2, .tool_name = @constCast("subagent"), .activity_kind = .subagent },
        .{ .entry_id = 3, .tool_name = @constCast("subagent"), .activity_kind = .subagent },
        .{ .entry_id = 4, .tool_name = @constCast("subagent"), .activity_kind = .subagent },
    };

    var projection = try build(alloc, &entries, &details, 120);
    defer projection.deinit(alloc);

    try std.testing.expectEqualStrings(
        "● Made 4 subagent calls\n" ++
            "├ Subagent working · inspect auth\n│ glm-5.3-flash · max\n" ++
            "├ Subagent working · inspect auth\n│ glm-5.3-flash · max\n" ++
            "├ Subagent working · inspect auth\n│ glm-5.3-flash · max\n" ++
            "└ Subagent working · inspect auth\n  glm-5.3-flash · max",
        projection.entry_actions.items[0].override.bytes,
    );
}

test "group summary uses singular and plural subagent labels" {
    const alloc = std.testing.allocator;
    var summary: Summary = .{ .total = 2 };
    summary.categories[command_category_index] = 1;
    summary.categories[subagent_category_index] = 1;
    const single = try formatGroupSummary(alloc, summary);
    defer alloc.free(single);
    try std.testing.expectEqualStrings("● 2 tool calls · 1 command · 1 subagent call", single);

    summary = .{ .total = 5 };
    summary.categories[command_category_index] = 2;
    summary.categories[subagent_category_index] = 3;
    const plural = try formatGroupSummary(alloc, summary);
    defer alloc.free(plural);
    try std.testing.expectEqualStrings("● 5 tool calls · 3 subagent calls · 2 commands", plural);
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
        "● Editing 1 file\n" ++
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
        "● Edited 2 files [G]+155\x1b[0m [R]-3\x1b[0m\n" ++
            "├ Read runtime.zig\n" ++
            "├ Wrote note.txt [G]+143\x1b[0m\n" ++
            "└ Edited main.zig [G]+12\x1b[0m / [R]-3\x1b[0m",
        projection.entry_actions.items[0].override.bytes,
    );
}

test "collapsed tool group keeps diff counts when the path is clipped" {
    const alloc = std.testing.allocator;
    const saved_added = ui_render.diff_added_marker_style;
    const saved_removed = ui_render.diff_removed_marker_style;
    defer ui_render.diff_added_marker_style = saved_added;
    defer ui_render.diff_removed_marker_style = saved_removed;
    ui_render.diff_added_marker_style = "[G]";
    ui_render.diff_removed_marker_style = "[R]";

    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Wrote\x1b[0m \x1b[38;5;245mdocs/release-notes/very-long-file-name.md\x1b[0m \x1b[38;2;48;164;108m+143\x1b[0m\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "● Edited\x1b[0m \x1b[38;5;245msrc/ui/transcript/tool_group_projection.zig\x1b[0m \x1b[38;2;229;72;77m-27\x1b[0m\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 3, .bytes = "● Edited\x1b[0m \x1b[38;5;245msrc/ui/transcript/tool_group_projection.zig\x1b[0m \x1b[38;2;48;164;108m+12\x1b[0m \x1b[38;5;245m/\x1b[0m \x1b[38;2;229;72;77m-3\x1b[0m\n", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("write_file"), .activity_kind = .write, .outcome = .completed },
        .{ .entry_id = 2, .tool_name = @constCast("edit_file"), .activity_kind = .edit, .outcome = .completed },
        .{ .entry_id = 3, .tool_name = @constCast("edit_file"), .activity_kind = .edit, .outcome = .completed },
    };
    const cols: u16 = 40;

    var projection = try build(alloc, &entries, &details, cols);
    defer projection.deinit(alloc);
    const bytes = projection.entry_actions.items[0].override.bytes;

    // The phrase ends in the ellipsis and the counts follow it, so each row
    // fills the width exactly instead of losing its counts to the clip.
    try std.testing.expectEqualStrings(
        "● Edited 3 files [G]+155\x1b[0m [R]-30\x1b[0m\n" ++
            "├ Wrote docs/release-notes/very-lo… [G]+143\x1b[0m\n" ++
            "├ Edited src/ui/transcript/tool_gro… [R]-27\x1b[0m\n" ++
            "└ Edited src/ui/transcript/too… [G]+12\x1b[0m / [R]-3\x1b[0m",
        bytes,
    );
    var rows = std.mem.splitScalar(u8, bytes, '\n');
    _ = rows.next();
    while (rows.next()) |row| {
        try std.testing.expectEqual(@as(usize, cols), try widthWithoutTestMarkersForTest(alloc, row));
    }
}

test "a long edit path keeps the header's diff counts" {
    const alloc = std.testing.allocator;
    const saved_added = ui_render.diff_added_marker_style;
    const saved_removed = ui_render.diff_removed_marker_style;
    defer ui_render.diff_added_marker_style = saved_added;
    defer ui_render.diff_removed_marker_style = saved_removed;
    ui_render.diff_added_marker_style = "[G]";
    ui_render.diff_removed_marker_style = "[R]";

    const path = "packages/render-pipeline/transcript-projection/grouped-rows/edit-row-fixture.ts";
    const status = "● Edited " ++ path ++ " +1 / -1\n";
    const arguments = "{\"path\":\"" ++ path ++ "\"}";
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = status, .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = status, .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("edit_file"), .activity_kind = .edit, .outcome = .completed, .arguments_json = @constCast(arguments) },
        .{ .entry_id = 2, .tool_name = @constCast("edit_file"), .activity_kind = .edit, .outcome = .completed, .arguments_json = @constCast(arguments) },
    };
    const cols: u16 = 60;

    var projection = try build(alloc, &entries, &details, cols);
    defer projection.deinit(alloc);
    const bytes = projection.entry_actions.items[0].override.bytes;
    const header = bytes[0 .. std.mem.findScalar(u8, bytes, '\n') orelse bytes.len];

    // The path ends in the ellipsis and the counts follow it. The header is
    // clipped with the counts' styles in place, so the "[G]" and "[R]"
    // stand-ins count as visible text here, where real styles have no width.
    try std.testing.expect(std.mem.find(u8, header, "…") != null);
    try std.testing.expect(std.mem.endsWith(u8, header, " [G]+2\x1b[0m [R]-2\x1b[0m"));
    try std.testing.expectEqual(@as(usize, cols), display_width.visibleWidthIgnoringAnsi(header));
}

test "a failed call whose row does not say so gets a failure mark" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Reading missing.txt\n", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("read_file"), .activity_kind = .read, .outcome = .failed },
    };
    var projection = try build(alloc, &entries, &details, 80);
    defer projection.deinit(alloc);
    try std.testing.expectEqualStrings("● Reading missing.txt ✗", projection.entry_actions.items[0].override.bytes);
}

test "a failure that names no target keeps its whole phrase" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Failed: Reading missing.txt: Path not found: missing.txt\n", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("read_file"), .activity_kind = .read, .outcome = .failed },
    };
    var projection = try build(alloc, &entries, &details, 100);
    defer projection.deinit(alloc);
    try std.testing.expectEqualStrings(
        "● Failed: Reading missing.txt: Path not found: missing.txt",
        projection.entry_actions.items[0].override.bytes,
    );
}

test "a command whose row still says Running gets no mark" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Running printf notice-test > ask-notice.txt\n", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("shell"), .activity_kind = .command, .outcome = .completed },
    };
    var projection = try build(alloc, &entries, &details, 80);
    defer projection.deinit(alloc);
    const bytes = projection.entry_actions.items[0].override.bytes;
    try std.testing.expect(std.mem.startsWith(u8, bytes, "● Running "));
    try std.testing.expect(std.mem.find(u8, bytes, "✓") == null);
}

/// Visible width of a row once the "[G]" and "[R]" stand-ins for the diff
/// marker styles are removed, since the stand-ins are visible text.
fn widthWithoutTestMarkersForTest(alloc: std.mem.Allocator, row: []const u8) !usize {
    const without_added = try std.mem.replaceOwned(u8, alloc, row, "[G]", "");
    defer alloc.free(without_added);
    const plain = try std.mem.replaceOwned(u8, alloc, without_added, "[R]", "");
    defer alloc.free(plain);
    return display_width.visibleWidthIgnoringAnsi(plain);
}

test "clipped diff counts fall back to a plain clip below half the row" {
    const alloc = std.testing.allocator;
    const saved_added = ui_render.diff_added_marker_style;
    const saved_removed = ui_render.diff_removed_marker_style;
    defer ui_render.diff_added_marker_style = saved_added;
    defer ui_render.diff_removed_marker_style = saved_removed;
    ui_render.diff_added_marker_style = "[G]";
    ui_render.diff_removed_marker_style = "[R]";

    const both = "● Edited\x1b[0m \x1b[38;5;245mmain.zig\x1b[0m \x1b[38;2;48;164;108m+12\x1b[0m \x1b[38;5;245m/\x1b[0m \x1b[38;2;229;72;77m-3\x1b[0m\n";
    const wide = "● Edited\x1b[0m \x1b[38;5;245m文档文档文档文档文档文档.md\x1b[0m \x1b[38;2;229;72;77m-7\x1b[0m\n";
    const cases = [_]struct { bytes: []const u8, cols: u16, row: []const u8 }{
        // A one-call group is its own header line. " +12 / -3" takes 9 of 18
        // cells: the counts still fit in half the row.
        .{ .bytes = both, .cols = 18, .row = "● Edited… [G]+12\x1b[0m / [R]-3\x1b[0m" },
        // One cell narrower, the counts would take more than half the row,
        // so the row clips from the right like any other row.
        .{ .bytes = both, .cols = 17, .row = "● Edited main.zi…" },
        .{ .bytes = both, .cols = 12, .row = "● Edited ma…" },
        // A two-cell glyph that would cross the cut is dropped whole.
        .{ .bytes = wide, .cols = 20, .row = "● Edited 文档文… [R]-7\x1b[0m" },
    };
    for (cases) |case| {
        const entries = [_]TranscriptEntry{
            .{ .raw_bytes = .{ .id = 1, .bytes = case.bytes, .class = .tool_status } },
        };
        const details = [_]ToolDetailRecord{
            .{ .entry_id = 1, .tool_name = @constCast("edit_file"), .activity_kind = .edit, .outcome = .completed },
        };
        var projection = try build(alloc, &entries, &details, case.cols);
        defer projection.deinit(alloc);
        const row = projection.entry_actions.items[0].override.bytes;
        try std.testing.expect(std.mem.findScalar(u8, row, '\n') == null);
        try std.testing.expectEqualStrings(case.row, row);
        try std.testing.expect(try widthWithoutTestMarkersForTest(alloc, row) <= case.cols);
    }
}

test "grouped command lines shell-highlight verbs and numeric flags" {
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
        "● Wrote 1 file [G]+2\x1b[0m ✓\n" ++
            "├ Ran \x1b[38;5;252mcat\x1b[39m log.txt \x1b[38;5;252m|\x1b[39m \x1b[38;5;252mhead\x1b[39m \x1b[38;5;250m-80\x1b[39m\n" ++
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

    var projection = try buildExpandedStyledInterruptible(alloc, &entries, &details, 80, null);
    defer projection.deinit(alloc);
    const expanded = projection.entry_actions.items[0].override.bytes;

    try std.testing.expectEqualStrings("● Wrote note.txt [G]+143\x1b[0m", expanded);
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
        "● Reading project instructions before continuing · 1 denied\n" ++
            "├ Denied by auto agent \x1b[38;5;252mzig\x1b[39m build\n" ++
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

    var projection = try buildStyledFocused(alloc, &entries, &details, 120, 2, false, .{}, .{});
    defer projection.deinit(alloc);

    try std.testing.expectEqualStrings(
        "● Running 1 shell command\n├ Read runtime.zig",
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
        "● Ran 3 shell commands ✗\n" ++
            "├ Running \x1b[38;5;252mrg\x1b[39m snapshot\n" ++
            "├ Ran \x1b[38;5;252mzig\x1b[39m build\n" ++
            "└ Ran \x1b[38;5;252mzig\x1b[39m build test",
        projection.entry_actions.items[0].override.bytes,
    );
}

test "completed command rows shell-highlight quoted strings without coloring the action" {
    const alloc = std.testing.allocator;
    const command = "printf 'hello world'";
    const arguments_json = try alloc.print(
        "{{\"command\":{f}}}",
        .{std.json.fmt(command, .{})},
    );
    defer alloc.free(arguments_json);
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Ran\x1b[0m \x1b[38;5;245mprintf 'hello world'\x1b[0m\n", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{.{
        .entry_id = 1,
        .tool_name = @constCast("shell"),
        .captured_command = true,
        .activity_kind = .command,
        .arguments_json = arguments_json,
        .command_display = @constCast(command),
        .command_action_label = @constCast("Ran"),
        .outcome = .completed,
        .command_process_presentation = .{ .exit_code = 0 },
    }};

    var projection = try build(alloc, &entries, &details, 240);
    defer projection.deinit(alloc);
    const row = projection.entry_actions.items[0].override.bytes;

    // The header, connector, and action label stay uncolored; the command
    // verb and quoted string pick up the syntax palette and close again.
    try std.testing.expect(std.mem.startsWith(u8, row, "● Ran \x1b[38;5;252mprintf\x1b[39m "));
    try std.testing.expect(std.mem.endsWith(u8, row, " ✓"));
    try std.testing.expect(std.mem.find(u8, row, "\x1b[38;5;250m'hello world'\x1b[39m") != null);
}

test "completed command rows reproject stored commands, then show their short form" {
    const alloc = std.testing.allocator;
    const command = "printf " ++ text_utils.repeat("alpha-beta-gamma-delta-", 8);
    const arguments_json = try alloc.print(
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

    // The frozen "..." row gets its full command back, and a command this
    // long shows in short form at every width.
    var narrow = try build(alloc, &entries, &details, 80);
    defer narrow.deinit(alloc);
    try std.testing.expectEqualStrings("● Ran \x1b[38;5;252mprintf\x1b[39m ✓", narrow.entry_actions.items[0].override.bytes);

    var wide = try build(alloc, &entries, &details, 240);
    defer wide.deinit(alloc);
    try std.testing.expectEqualStrings("● Ran \x1b[38;5;252mprintf\x1b[39m ✓", wide.entry_actions.items[0].override.bytes);

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
    try std.testing.expect(std.mem.endsWith(u8, legacy.entry_actions.items[0].override.bytes, "... ✓"));

    const relative_command = "cd ./packages/cli && " ++ text_utils.repeat("printf relative-path ", 6);
    const relative_arguments_json = try alloc.print(
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
    // The `cd` step drops out of the short form.
    try std.testing.expectEqualStrings("● Ran \x1b[38;5;252mprintf\x1b[39m ✓", relative.entry_actions.items[0].override.bytes);

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
    try std.testing.expectEqualStrings("● Installed skill \x1b[38;5;252mprintf\x1b[39m ✓", compatibility.entry_actions.items[0].override.bytes);
}

test "completed session and tty command rows reproject stored commands at the current width" {
    const alloc = std.testing.allocator;
    const tty_command = "bun run " ++ text_utils.repeat("pipeline-stage-", 10);
    const observe_command = "npm run " ++ text_utils.repeat("dev-server-", 12);
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
    try std.testing.expect(std.mem.startsWith(u8, narrow_tty, "├ Ran \x1b[38;5;252mbun\x1b[39m run pipeline-stage-"));
    try std.testing.expect(std.mem.endsWith(u8, narrow_tty, "…\x1b[0m"));
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(narrow_tty) <= 80);
    try std.testing.expect(std.mem.startsWith(u8, narrow_observe, "└ Observed \x1b[38;5;252mnpm\x1b[39m run dev-server-"));
    try std.testing.expect(std.mem.endsWith(u8, narrow_observe, "…\x1b[0m"));
    // Reprojection replaces the frozen ASCII marker before reclipping.
    try std.testing.expect(std.mem.find(u8, narrow_rows, "...") == null);

    var wide = try build(alloc, &entries, &details, 400);
    defer wide.deinit(alloc);
    try std.testing.expectEqualStrings(
        "● Ran 2 shell commands ✓\n" ++
            "├ Ran \x1b[38;5;252mbun\x1b[39m run " ++ text_utils.repeat("pipeline-stage-", 10) ++ "\n" ++
            "└ Observed \x1b[38;5;252mnpm\x1b[39m run " ++ text_utils.repeat("dev-server-", 12),
        wide.entry_actions.items[0].override.bytes,
    );
}

/// Paints expanded rows through the terminal engine so tests assert what the
/// full transcript shows. Each row must already fit `cols`.
fn paintExpandedRowsForTest(alloc: std.mem.Allocator, bytes: []const u8, cols: u16) !vt_emulator.Grid {
    var rows: u16 = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| : (rows += 1) {
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= cols);
    }
    var grid = try vt_emulator.Grid.init(alloc, cols, rows);
    errdefer grid.deinit();
    try grid.feed(bytes);
    return grid;
}

/// Visible text of grid rows `first..last` with tree glyphs and spaces
/// removed, so a wrapped row compares equal to its source wherever the wrap
/// fell. The caller owns the result.
fn paintedTreeTextForTest(
    alloc: std.mem.Allocator,
    grid: *const vt_emulator.Grid,
    first: u16,
    last: u16,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var row_text: std.ArrayList(u8) = .empty;
    defer row_text.deinit(alloc);
    var row = first;
    while (row <= last) : (row += 1) {
        row_text.clearRetainingCapacity();
        try grid.rowTextTrimmed(row, &row_text);
        var text: []const u8 = row_text.items;
        for ([_][]const u8{ "├", "└", "│" }) |glyph| {
            if (std.mem.startsWith(u8, text, glyph)) {
                text = text[glyph.len..];
                break;
            }
        }
        for (text) |byte| {
            if (byte != ' ') try out.append(alloc, byte);
        }
    }
    return out.toOwnedSlice(alloc);
}

fn withoutSpacesForTest(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (text) |byte| {
        if (byte != ' ') try out.append(alloc, byte);
    }
    return out.toOwnedSlice(alloc);
}

fn lastContentCellForTest(grid: *const vt_emulator.Grid, row: u16) vt_emulator.Cell {
    var col = grid.cols;
    while (col > 1) : (col -= 1) {
        const cell = grid.cellAt(row, col).?;
        if (cell.width > 0 and cell.codepoint != ' ') return cell;
    }
    return grid.cellAt(row, 1).?;
}

test "Ctrl+O tool lines wrap under the detail indent and keep command styling" {
    const alloc = std.testing.allocator;
    const first_command = "printf 'alpha beta gamma delta epsilon zeta eta theta'";
    const last_command = "printf 'iota kappa lambda mu nu xi omicron pi rho'";
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Ran\x1b[0m \x1b[38;5;245m" ++ first_command ++ "\x1b[0m\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "● Ran\x1b[0m \x1b[38;5;245m" ++ last_command ++ "\x1b[0m\n", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{
            .entry_id = 1,
            .tool_name = @constCast("shell"),
            .activity_kind = .command,
            .command_display = @constCast(first_command),
            .command_action_label = @constCast("Ran"),
            .outcome = .completed,
        },
        .{
            .entry_id = 2,
            .tool_name = @constCast("shell"),
            .activity_kind = .command,
            .command_display = @constCast(last_command),
            .command_action_label = @constCast("Ran"),
            .outcome = .completed,
        },
    };
    const cols: u16 = 24;

    var projection = try buildExpandedStyledInterruptible(alloc, &entries, &details, cols, null);
    defer projection.deinit(alloc);
    const rows = try alloc.print("{s}\n{s}", .{
        projection.entry_actions.items[0].override.bytes,
        projection.entry_actions.items[1].override.bytes,
    });
    defer alloc.free(rows);
    try std.testing.expect(std.mem.find(u8, rows, "…") == null);

    var grid = try paintExpandedRowsForTest(alloc, rows, cols);
    defer grid.deinit();
    // Each call starts its own line with its mark, its words at the response
    // indent.
    try std.testing.expectEqual(@as(u21, 'R'), grid.cellAt(1, 3).?.codepoint);
    var second_row: u16 = 2;
    while (second_row <= grid.rows and grid.cellAt(second_row, 3).?.codepoint != 'R') : (second_row += 1) {}
    try std.testing.expect(second_row > 2 and second_row < grid.rows);

    // Wrapped rows continue under the blank detail indent, and the quoted
    // argument keeps its color across every wrap.
    var row: u16 = 2;
    while (row <= grid.rows) : (row += 1) {
        if (row == second_row) continue;
        for (1..5) |col| try std.testing.expectEqual(@as(u21, ' '), grid.cellAt(row, @intCast(col)).?.codepoint);
        const first = grid.cellAt(row, 5).?;
        try std.testing.expect(first.codepoint != ' ');
        try std.testing.expect(!first.style.fg.eql(.default));
    }

    // Nothing is hidden: each call's rows hold its whole command.
    const first_painted = try paintedTreeTextForTest(alloc, &grid, 1, second_row - 1);
    defer alloc.free(first_painted);
    const first_expected = try withoutSpacesForTest(alloc, "● Ran " ++ first_command);
    defer alloc.free(first_expected);
    try std.testing.expectEqualStrings(first_expected, first_painted);
    const last_painted = try paintedTreeTextForTest(alloc, &grid, second_row, grid.rows);
    defer alloc.free(last_painted);
    const last_expected = try withoutSpacesForTest(alloc, "● Ran " ++ last_command);
    defer alloc.free(last_expected);
    try std.testing.expectEqualStrings(last_expected, last_painted);
}

test "Ctrl+O keeps each call's own state mark and its color" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "\x1b[31m⊘\x1b[0m Denied write note.txt\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "\x1b[33m▪ Ran sleep 5\n", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("write_file"), .activity_kind = .write, .outcome = .denied },
        .{ .entry_id = 2, .tool_name = @constCast("shell"), .activity_kind = .command, .outcome = .cancelled },
    };

    var projection = try buildExpandedStyledInterruptible(alloc, &entries, &details, 80, null);
    defer projection.deinit(alloc);
    try std.testing.expectEqualStrings("\x1b[31m⊘\x1b[0m Denied write note.txt", projection.entry_actions.items[0].override.bytes);
    // A mark whose color runs on ends it before the phrase.
    const cancelled = projection.entry_actions.items[1].override.bytes;
    try std.testing.expect(std.mem.startsWith(u8, cancelled, "\x1b[33m▪" ++ ui_render.reset_style ++ " Ran"));
}

test "Ctrl+O shows every call of a group on its own line, with no group header" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Read a.zig\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "● Ran zig build\n", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("read_file"), .activity_kind = .read },
        .{ .entry_id = 2, .tool_name = @constCast("shell"), .activity_kind = .command, .outcome = .failed },
    };

    var projection = try buildExpandedStyledInterruptible(alloc, &entries, &details, 16, null);
    defer projection.deinit(alloc);
    try std.testing.expectEqualStrings("● Read a.zig", projection.entry_actions.items[0].override.bytes);
    const second = projection.entry_actions.items[1].override.bytes;
    try std.testing.expect(std.mem.startsWith(u8, second, "● Ran"));
    try std.testing.expect(std.mem.find(u8, second, "zig") != null);
    try std.testing.expect(std.mem.find(u8, second, "tool call") == null);
}

test "expanded group children reproject stored commands at the current width" {
    const alloc = std.testing.allocator;
    const command = "bun run " ++ text_utils.repeat("pipeline-stage-", 10);
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

    var wide = try buildExpandedStyledInterruptible(alloc, &entries, &details, 400, null);
    defer wide.deinit(alloc);
    try std.testing.expectEqualStrings(
        "● Ran \x1b[38;5;252mbun\x1b[39m run " ++ text_utils.repeat("pipeline-stage-", 10),
        wide.entry_actions.items[0].override.bytes,
    );

    // A narrower full transcript wraps the stored command instead of clipping
    // it, and the frozen generation marker never returns.
    var narrow = try buildExpandedStyledInterruptible(alloc, &entries, &details, 80, null);
    defer narrow.deinit(alloc);
    const narrow_rows = narrow.entry_actions.items[0].override.bytes;
    try std.testing.expect(std.mem.find(u8, narrow_rows, "…") == null);
    try std.testing.expect(std.mem.find(u8, narrow_rows, "...") == null);
    var grid = try paintExpandedRowsForTest(alloc, narrow_rows, 80);
    defer grid.deinit();
    try std.testing.expect(grid.rows > 1);
    const painted = try paintedTreeTextForTest(alloc, &grid, 1, grid.rows);
    defer alloc.free(painted);
    const expected = try withoutSpacesForTest(alloc, "● Ran " ++ command);
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, painted);
}

test "command reprojection rejects a record carrying a different command" {
    const alloc = std.testing.allocator;
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
        .command_display = @constCast("zig build test --release"),
        .command_action_label = @constCast("Ran"),
        .outcome = .completed,
        .command_process_presentation = .{ .exit_code = 0 },
    }};

    var projection = try build(alloc, &entries, &details, 240);
    defer projection.deinit(alloc);
    // The frozen tail is no prefix of the stored command, so the row is left
    // untouched rather than rewritten with unrelated content.
    try std.testing.expect(std.mem.endsWith(u8, projection.entry_actions.items[0].override.bytes, "... ✓"));
    try std.testing.expect(std.mem.find(u8, projection.entry_actions.items[0].override.bytes, "zig build") == null);
}

test "command reprojection keeps the row's own label across lifecycle states" {
    const alloc = std.testing.allocator;
    const command = "printf " ++ text_utils.repeat("alpha-beta-gamma-delta-", 8);
    const frozen_tail = "printf alpha-beta-gamma-delta-alpha-beta-gamma-delta-alpha-beta-gamma-delta-alpha-beta-gamma-delta-alpha-beta-gamma-";

    const Case = struct {
        label: []const u8,
        outcome: ?types.ToolOutcomeKind,
        stored_action: []const u8,
    };
    const cases = [_]Case{
        // Active row: outcome not yet set, stored label is the start-time
        // prediction. The live row must keep "Running", never flip to "Ran".
        .{ .label = "Running", .outcome = null, .stored_action = "Ran" },
        // Plain success: the historical happy path.
        .{ .label = "Ran", .outcome = .completed, .stored_action = "Ran" },
        // Nonzero exit: the tool completed but the settled label carries the
        // exit code the start-time prediction could not know.
        .{ .label = "Exited 1", .outcome = .completed, .stored_action = "Ran" },
        // Failed tool outcome with a divergent settled label.
        .{ .label = "Failed", .outcome = .failed, .stored_action = "Observed" },
    };

    for (cases, 0..) |case, index| {
        const bytes = try alloc.print(
            "● {s}\x1b[0m \x1b[38;5;245m{s}...\x1b[0m\n",
            .{ case.label, frozen_tail },
        );
        defer alloc.free(bytes);
        const entries = [_]TranscriptEntry{
            .{ .raw_bytes = .{ .id = @intCast(index + 1), .bytes = bytes, .class = .tool_status } },
        };
        const details = [_]ToolDetailRecord{.{
            .entry_id = @intCast(index + 1),
            .tool_name = @constCast("shell"),
            .activity_kind = .command,
            .command_display = @constCast(command),
            .command_action_label = @constCast(case.stored_action),
            .outcome = case.outcome,
        }};

        var projection = try build(alloc, &entries, &details, 240);
        defer projection.deinit(alloc);
        const row = projection.entry_actions.items[0].override.bytes;

        // The frozen marker is gone, the command shows in short form, and
        // the row keeps its own label rather than the stored prediction.
        try std.testing.expect(std.mem.find(u8, row, "...") == null);
        try std.testing.expect(std.mem.find(u8, row, "alpha-beta") == null);
        try std.testing.expect(std.mem.find(u8, row, "printf") != null);
        // A one-call group is its own header line.
        const expected_prefix = try alloc.print("● {s} ", .{case.label});
        defer alloc.free(expected_prefix);
        try std.testing.expect(std.mem.startsWith(u8, row, expected_prefix));
    }
}

test "command tail match requires an identity-length prefix" {
    try std.testing.expect(commandTailMatch("Ran zig build test --release", "zig build test --release --verbose") != null);
    try std.testing.expect(commandTailMatch("Ran head -6; echo done", "git status") == null);
    try std.testing.expect(commandTailMatch("Ran x", "x") == null);
    try std.testing.expect(commandTailMatch("", "anything") == null);
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
        "● Timed out \x1b[38;5;252msleep\x1b[39m 5",
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

    // The header names the main event, the edits, in the tense of the one
    // still running, and the last command's failure.
    try std.testing.expect(std.mem.startsWith(u8, summary, "● Editing 2 files ✗\n"));
    try std.testing.expect(std.mem.find(u8, summary, "Ran \x1b[38;5;252mrg\x1b[39m snapshot") != null);
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

    try std.testing.expect(std.mem.startsWith(u8, completed_summary, "● Edited 2 files ✗\n"));
    try std.testing.expect(std.mem.find(u8, completed_summary, "Edited runtime.zig") != null);
    try std.testing.expectEqual(@as(usize, tool_count), std.mem.count(u8, completed_summary, "\n"));
}

test "a cancelled call is its group's header above the cancellation block" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "▪ Cancelled sleep 30 · What can fx do differently?", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("run_command"), .activity_kind = .command, .outcome = .cancelled },
    };
    var projection = try buildStyled(alloc, &entries, &details, 120, .{}, .{});
    defer projection.deinit(alloc);

    try std.testing.expect(projection.entry_actions.items[0] == .override);
    try std.testing.expectEqualStrings(
        "● Cancelled \x1b[38;5;252msleep\x1b[39m 30\n\n" ++
            "▪ Cancelled sleep 30 · What can fx do differently?",
        projection.entry_actions.items[0].override.bytes,
    );
}

test "a cancelled call clips its header to one row" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{
            .id = 1,
            .bytes = "▪ Cancelled sleep waiting command words extend past line two",
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
    try std.testing.expectEqual(@as(usize, 1), group_line_count);

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
        .{ .raw_bytes = .{ .id = 1, .bytes = "▪ Cancelled first", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "▪ Cancelled second", .class = .tool_status } },
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
    try std.testing.expect(std.mem.find(u8, projection.entry_actions.items[0].override.bytes, "├ Cancelled \x1b[38;5;252mfirst\x1b[39m") != null);
    try std.testing.expect(std.mem.find(u8, projection.entry_actions.items[0].override.bytes, "├ Cancelled \x1b[38;5;252msecond\x1b[39m") != null);
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
        "● Running 2 shell commands\n" ++
            "├ Running \x1b[38;5;252mfirst\x1b[39m\n" ++
            "└ Running \x1b[38;5;252msecond\x1b[39m",
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
        "● Read first",
        projection.entry_actions.items[0].override.bytes,
    );
    try std.testing.expectEqualStrings(
        "● Read second",
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
        "● Read first",
        projection.entry_actions.items[0].override.bytes,
    );
    try std.testing.expect(projection.entry_actions.items[1] == .keep);
    try std.testing.expectEqualStrings(
        "● Running \x1b[38;5;252msecond\x1b[39m",
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
        "● Running 2 shell commands\n" ++
            "├ Running \x1b[38;5;252mfirst\x1b[39m\n" ++
            "└ Running \x1b[38;5;252msecond\x1b[39m",
        projection.entry_actions.items[0].override.bytes,
    );
}

test "presentation grouping is atomic across allocation failures" {
    try std.testing.checkAllAllocationFailures(
        testing_allocator.no_resize,
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
        "● Edited 1 file\n" ++
            "├ read_file\n" ++
            "└ edit_file",
        projection.entry_actions.items[0].override.bytes,
    );
    try std.testing.expect(projection.entry_actions.items[1] == .keep);
    try std.testing.expect(projection.entry_actions.items[2] == .keep);
    try std.testing.expect(projection.entry_actions.items[3] == .hide);
}

test "tool status hidden by a display clear does not start a compact group" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "welcome", .class = .welcome } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "command", .class = .tool_status, .inline_hidden = true } },
        .{ .raw_bytes = .{ .id = 3, .bytes = "output", .class = .command_output, .inline_hidden = true } },
        .{ .raw_bytes = .{ .id = 4, .bytes = "4s", .class = .turn_summary, .inline_hidden = true } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 2, .tool_name = @constCast("run_command"), .activity_kind = .command, .outcome = .completed },
    };

    var projection = try build(alloc, &entries, &details, 120);
    defer projection.deinit(alloc);

    try std.testing.expect(projection.entry_actions.items[0] == .keep);
    try std.testing.expect(projection.entry_actions.items[1] == .keep);
    try std.testing.expect(projection.entry_actions.items[2] == .hide);
    try std.testing.expect(projection.entry_actions.items[3] == .keep);
}

test "visible tool status after a display clear keeps its compact group" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "command", .class = .tool_status, .inline_hidden = true } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "read", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("run_command"), .activity_kind = .command, .outcome = .completed },
        .{ .entry_id = 2, .tool_name = @constCast("read_file"), .activity_kind = .read, .outcome = .completed },
    };

    var projection = try build(alloc, &entries, &details, 120);
    defer projection.deinit(alloc);

    try std.testing.expect(projection.entry_actions.items[0] == .keep);
    try std.testing.expect(projection.entry_actions.items[1] == .override);
    const block = projection.entry_actions.items[1].override.bytes;
    try std.testing.expectEqualStrings("● read_file", block);
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
        "● Read 3 files\n" ++
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
        "● Ran 1 shell command ✓\n" ++
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
        "● read_file",
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
        "● Reading /tmp/ask_user_question",
        projection.entry_actions.items[0].override.bytes,
    );
    try std.testing.expectEqualStrings(
        "● read_file",
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

test "mixed group keeps its header before every action" {
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
        "● Ran 1 shell command ✓\n" ++
            "├ Read one.zig\n" ++
            "├ Read two.zig\n" ++
            "├ Read three.zig\n" ++
            "├ Read four.zig\n" ++
            "├ Read five.zig\n" ++
            "└ Ran \x1b[38;5;252mgit\x1b[39m \x1b[38;5;250m-C\x1b[39m /workspace status \x1b[38;5;250m--short\x1b[39m",
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
    // A one-call group is a single header line.
    try std.testing.expectEqual(@as(usize, 1), line_count);
}

test "Ctrl+O shows a tool call as its own line with no group header or tree marks" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "Listed .", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("glob_files"), .activity_kind = .list },
    };

    var projection = try buildExpandedStyledInterruptible(alloc, &entries, &details, 80, null);
    defer projection.deinit(alloc);
    const expanded = projection.entry_actions.items[0].override.bytes;

    // A line saved without a mark gets a plain one.
    try std.testing.expectEqualStrings("● Listed .", expanded);
}

test "expanded tool relationships materialize at multiple widths" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "Listed .", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("glob_files"), .activity_kind = .list },
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
        null,
    );
    defer narrow.deinit(alloc);
    var wide = try materializeExpandedRelationshipsRangeInterruptible(
        alloc,
        &relationships,
        0,
        80,
        null,
    );
    defer wide.deinit(alloc);

    var narrow_lines = std.mem.splitScalar(u8, narrow.entry_actions.items[0].override.bytes, '\n');
    while (narrow_lines.next()) |line| {
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= 2);
    }
    try std.testing.expectEqualStrings("● Listed .", wide.entry_actions.items[0].override.bytes);
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

test "prose-prefixed command rows highlight only the trailing stored command" {
    const alloc = std.testing.allocator;
    const command = "cat AGENTS.md && printf done";
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Ran echo ok\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "↻ Reading project instructions before continuing: cat AGENTS.md && printf done\n", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{
            .entry_id = 1,
            .tool_name = @constCast("shell"),
            .captured_command = true,
            .activity_kind = .command,
            .command_display = @constCast("echo ok"),
            .command_action_label = @constCast("Ran"),
            .outcome = .completed,
            .command_process_presentation = .{ .exit_code = 0 },
        },
        .{
            .entry_id = 2,
            .tool_name = @constCast("shell"),
            .activity_kind = .command,
            .arguments_json = @constCast("{\"command\":\"cat AGENTS.md && printf done\"}"),
            .command_display = @constCast(command),
            .outcome = .deferred,
        },
    };

    var projection = try build(alloc, &entries, &details, 200);
    defer projection.deinit(alloc);
    const rows = projection.entry_actions.items[0].override.bytes;

    // The prose prefix stays plain; the trailing command shows in short form,
    // with each step's program highlighted and the ", " between them plain.
    try std.testing.expect(std.mem.endsWith(u8, rows, "\n└ Reading project instructions before continuing: \x1b[38;5;252mcat\x1b[39m, \x1b[38;5;252mprintf\x1b[39m"));
}

test "a deferred call keeps its own row and does not count as a run" {
    const alloc = std.testing.allocator;
    const arguments = "{\"command\":\"cat AGENTS.md\"}";
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "↻ Reading project instructions before continuing: cat AGENTS.md\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "● Ran cat AGENTS.md\n", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("shell"), .activity_kind = .command, .arguments_json = @constCast(arguments), .command_display = @constCast("cat AGENTS.md"), .outcome = .deferred },
        .{ .entry_id = 2, .tool_name = @constCast("shell"), .activity_kind = .command, .arguments_json = @constCast(arguments), .command_display = @constCast("cat AGENTS.md"), .outcome = .completed, .command_process_presentation = .{ .exit_code = 0 } },
    };
    var projection = try build(alloc, &entries, &details, 100);
    defer projection.deinit(alloc);
    const bytes = projection.entry_actions.items[0].override.bytes;
    try std.testing.expect(std.mem.startsWith(u8, bytes, "● Ran 1 shell command ✓\n"));
    try std.testing.expect(std.mem.find(u8, bytes, "\n├ Reading project instructions before continuing: ") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "\n└ Ran ") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "×") == null);
}

fn storyCommandDetail(
    entry_id: u32,
    arguments_json: []const u8,
    exit_code: i64,
    result: ?[]const u8,
) ToolDetailRecord {
    return .{
        .entry_id = entry_id,
        .tool_name = @constCast("shell"),
        .activity_kind = .command,
        .arguments_json = @constCast(arguments_json),
        .result = if (result) |text| @constCast(text) else null,
        .outcome = .completed,
        .command_process_presentation = .{ .exit_code = exit_code },
    };
}

test "repeated runs of one command share a row that keeps the earlier failures" {
    const alloc = std.testing.allocator;
    const args = "{\"action\":\"run\",\"command\":\"sh test.sh\"}";
    const passing = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Exited 1 sh test.sh\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "● Exited 1 sh test.sh\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 3, .bytes = "● Ran sh test.sh\n", .class = .tool_status } },
    };
    const passing_details = [_]ToolDetailRecord{
        storyCommandDetail(1, args, 1, "Error: Test timed out."),
        storyCommandDetail(2, args, 1, "Error: Test timed out."),
        storyCommandDetail(3, args, 0, "Tests 24 passed (24)"),
    };
    var passed = try build(alloc, &passing, &passing_details, 120);
    defer passed.deinit(alloc);
    try std.testing.expectEqualStrings(
        "● Ran \x1b[38;5;252msh\x1b[39m test.sh ×3 · passed on the 3rd run ✓",
        passed.entry_actions.items[0].override.bytes,
    );
    try std.testing.expect(passed.entry_actions.items[1] == .hide);
    try std.testing.expect(passed.entry_actions.items[2] == .hide);

    const failing_details = [_]ToolDetailRecord{
        storyCommandDetail(1, args, 1, "Error: Test timed out."),
        storyCommandDetail(2, args, 1, "Error: Test timed out."),
        storyCommandDetail(3, args, 1, "running 4 tests\n FAIL  quits on click\nError: Test timed out."),
    };
    var failed = try build(alloc, &passing, &failing_details, 120);
    defer failed.deinit(alloc);
    const failed_bytes = failed.entry_actions.items[0].override.bytes;
    try std.testing.expect(std.mem.startsWith(u8, failed_bytes, "● Ran \x1b[38;5;252msh\x1b[39m test.sh ×3 ✗\n"));
    // The reason comes from the latest run: its first line that names a failure.
    try std.testing.expect(std.mem.find(u8, failed_bytes, "  ✗ exit 1 · FAIL quits on click") != null);
}

fn storySearchDetail(entry_id: u32, tool_name: []const u8, kind: types.ToolActivityKind, arguments_json: []const u8) ToolDetailRecord {
    return .{
        .entry_id = entry_id,
        .tool_name = @constCast(tool_name),
        .activity_kind = kind,
        .arguments_json = @constCast(arguments_json),
        .outcome = .completed,
    };
}

test "a command that starts with a comment line shows the steps after it" {
    const alloc = std.testing.allocator;
    // The display folds the command's lines into one, as core stores it.
    const display = "# check that the build left the tree clean git status --short && git diff --stat";
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Ran " ++ display ++ "\n", .class = .tool_status } },
    };
    var details = [_]ToolDetailRecord{storyCommandDetail(1, "{\"command\":\"# check that the build left the tree clean\\ngit status --short && git diff --stat\"}", 0, null)};
    details[0].command_display = @constCast(display);
    var projection = try build(alloc, &entries, &details, 120);
    defer projection.deinit(alloc);
    const row = projection.entry_actions.items[0].override.bytes;
    try std.testing.expect(std.mem.startsWith(u8, row, "● Ran \x1b[38;5;252mgit\x1b[39m status, \x1b[38;5;252mgit\x1b[39m diff ✓"));
    try std.testing.expect(std.mem.find(u8, row, "check that") == null);
}

test "searches for one pattern share a row that names their folders" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Searched P0\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "● Searched P0\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 3, .bytes = "● Matched *triage*\n", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        storySearchDetail(1, "grep_files", .read, "{\"pattern\":\"P0\",\"path\":\"/Users/example/fx/reviews\"}"),
        storySearchDetail(2, "grep_files", .read, "{\"pattern\":\"P0\",\"path\":\"/Users/example/fx/docs/\"}"),
        storySearchDetail(3, "glob_files", .list, "{\"pattern\":\"*triage*\",\"path\":\"/Users/example/fx\"}"),
    };
    var projection = try build(alloc, &entries, &details, 120);
    defer projection.deinit(alloc);
    // The header counts patterns, not calls.
    try std.testing.expectEqualStrings(
        "● Searched for 2 patterns\n├ Searched P0 in reviews, docs\n└ Matched *triage*",
        std.mem.trimEnd(u8, projection.entry_actions.items[0].override.bytes, "\n"),
    );

    // The same pattern in the same folder twice is one search made twice.
    var again = try build(alloc, entries[0..2], &.{ details[0], storySearchDetail(2, "grep_files", .read, details[0].arguments_json.?) }, 120);
    defer again.deinit(alloc);
    try std.testing.expectEqualStrings("● Searched P0 ×2", std.mem.trimEnd(u8, again.entry_actions.items[0].override.bytes, "\n"));

    // A grep and a glob for the same text do different things, so they keep
    // their own rows.
    const mixed = [_]ToolDetailRecord{ details[0], storySearchDetail(2, "glob_files", .list, "{\"pattern\":\"P0\"}") };
    var apart = try build(alloc, entries[0..2], &mixed, 120);
    defer apart.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, apart.entry_actions.items[0].override.bytes, "● Searched for 2 patterns\n├ Searched P0\n└ Searched P0"));
}

test "search folder names stay terminal-safe and short" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("reviews, docs", try searchFolderNames(arena, &.{ "/w/reviews", "/w/docs" }));
    // The shared folder itself shows by its last part, and no path as ".".
    try std.testing.expectEqualStrings("w, docs", try searchFolderNames(arena, &.{ "/w", "/w/docs" }));
    try std.testing.expectEqualStrings("., src", try searchFolderNames(arena, &.{ "", "src" }));
    try std.testing.expectEqualStrings("a/x, b/y", try searchFolderNames(arena, &.{ "/r/a/x", "/r/b/y" }));
    try std.testing.expectEqualStrings("a, b, c +2 more", try searchFolderNames(arena, &.{ "/r/a", "/r/b", "/r/c", "/r/d", "/r/e" }));
    // A path from the model never reaches the terminal as raw control bytes.
    const hostile = try searchFolderNames(arena, &.{ "/w/a\x1b]0;owned\x07", "/w/b" });
    try std.testing.expect(std.mem.findScalar(u8, hostile, 0x1b) == null);
    try std.testing.expect(std.mem.findScalar(u8, hostile, 0x07) == null);
}

test "input to a running session and its stop are not new commands" {
    const alloc = std.testing.allocator;
    const run = "{\"action\":\"run\",\"command\":\"npm run dev\",\"tty\":true}";
    const interact = "{\"action\":\"interact\",\"session_id\":\"shell-7\",\"chars\":\"q\"}";
    const stop = "{\"action\":\"stop\",\"session_id\":\"shell-7\"}";
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Ran npm run dev\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "● Observed npm run dev\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 3, .bytes = "● Stopped npm run dev\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 4, .bytes = "  2s", .class = .turn_summary } },
    };
    const details = [_]ToolDetailRecord{
        storyCommandDetail(1, run, 0, null),
        storyCommandDetail(2, interact, 0, null),
        storyCommandDetail(3, stop, 0, null),
    };
    var projection = try build(alloc, &entries, &details, 120);
    defer projection.deinit(alloc);
    const bytes = projection.entry_actions.items[0].override.bytes;
    try std.testing.expect(std.mem.startsWith(u8, bytes, "● Ran 1 shell command ✓\n"));
    try std.testing.expect(std.mem.find(u8, bytes, " · 2 calls") != null);
    try std.testing.expectEqualStrings("  Ran 1 command · 2s", projection.entry_actions.items[3].override.bytes);

    // A group that only checks on the session names the session.
    var follow_ups = try build(alloc, entries[1..3], details[1..3], 120);
    defer follow_ups.deinit(alloc);
    const follow_bytes = follow_ups.entry_actions.items[0].override.bytes;
    try std.testing.expect(std.mem.startsWith(u8, follow_bytes, "● Stopped "));
    try std.testing.expect(std.mem.endsWith(u8, follow_bytes, " · 2 calls ✓") or std.mem.endsWith(u8, follow_bytes, " · 2 calls"));
}

test "toolbox lookups and wrapped arguments name what the group did" {
    const alloc = std.testing.allocator;
    // A toolbox open reads no file, so it is not a search or a read.
    const opened = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Opened mcp_fixture_echo\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "● Failed mcp_fixture_echo: Invalid input\n", .class = .tool_status } },
    };
    const opened_details = [_]ToolDetailRecord{
        .{ .entry_id = 1, .tool_name = @constCast("toolbox"), .activity_kind = .read, .outcome = .completed, .arguments_json = @constCast("{\"open\":\"mcp_fixture_echo\"}") },
        .{ .entry_id = 2, .tool_name = @constCast("toolbox"), .activity_kind = .mcp, .outcome = .failed, .arguments_json = @constCast("{\"run\":\"mcp_fixture_echo\"}") },
    };
    var opened_projection = try build(alloc, &opened, &opened_details, 100);
    defer opened_projection.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, opened_projection.entry_actions.items[0].override.bytes, "● Opened 1 tool · 1 failed\n"));

    // Fields inside {"request": {...}} count like top-level ones.
    const run = "{\"request\":{\"action\":\"run\",\"command\":\"npm run dev\",\"tty\":true}}";
    const stop = "{\"request\":{\"action\":\"stop\",\"session_id\":\"shell-7\"}}";
    const session = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Ran npm run dev\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "● Stopped npm run dev\n", .class = .tool_status } },
    };
    const session_details = [_]ToolDetailRecord{
        storyCommandDetail(1, run, 0, null),
        storyCommandDetail(2, stop, 0, null),
    };
    var session_projection = try build(alloc, &session, &session_details, 100);
    defer session_projection.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, session_projection.entry_actions.items[0].override.bytes, "● Ran 1 shell command ✓\n"));
}

test "a command that failed before the last one still counts in the header" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Ran sh fast.sh\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "● Exited 1 sh failed.sh\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 3, .bytes = "● Ran sh last.sh\n", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        storyCommandDetail(1, "{\"command\":\"sh fast.sh\"}", 0, null),
        storyCommandDetail(2, "{\"command\":\"sh failed.sh\"}", 1, null),
        storyCommandDetail(3, "{\"command\":\"sh last.sh\"}", 0, null),
    };
    var projection = try build(alloc, &entries, &details, 120);
    defer projection.deinit(alloc);
    const bytes = projection.entry_actions.items[0].override.bytes;
    try std.testing.expect(std.mem.startsWith(u8, bytes, "● Ran 3 shell commands ✓ · 1 failed\n"));

    // When the last command is the one that failed, the mark says so alone.
    const last_failed = [_]ToolDetailRecord{
        storyCommandDetail(1, "{\"command\":\"sh fast.sh\"}", 0, null),
        storyCommandDetail(2, "{\"command\":\"sh failed.sh\"}", 0, null),
        storyCommandDetail(3, "{\"command\":\"sh last.sh\"}", 1, null),
    };
    var last = try build(alloc, &entries, &last_failed, 120);
    defer last.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, last.entry_actions.items[0].override.bytes, "● Ran 3 shell commands ✗\n"));
}

test "a long shell command shows its steps in short form" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct { command: []const u8, short: ?[]const u8 }{
        .{ .command = "cd desktop && npm ci --no-audit --no-fund --loglevel=error && npm run build -- --mode production", .short = "npm ci, npm run build" },
        .{ .command = "gh issue list -R vercel-labs/fx --state open --limit 300 --json number,title,labels --jq 'length'; gh label list -R vercel-labs/fx", .short = "gh issue list, gh label list" },
        .{ .command = "cd desktop && git status --short --branch && git log --oneline -5", .short = "git status, git log" },
        .{ .command = "git fetch origin --quiet && git rev-list --left-right --count HEAD...origin/main", .short = "git fetch origin, git rev-list" },
        // Variables, wrappers, redirections, and output filters drop out.
        .{ .command = "FORCE_COLOR=0 CI=1 timeout 300 zig build test --summary all 2>&1 | tail -20", .short = "zig build test" },
        .{ .command = "git -C /Users/example/fx worktree add --detach /Users/example/worktrees/task origin/main", .short = "git worktree add" },
        .{ .command = "cd tests/e2e && FX_SOUND=0 bun test tui-tool-story.test.ts", .short = "bun test" },
        .{ .command = "cd /tmp && sh ./scripts/run-everything.sh --verbose", .short = "sh run-everything.sh" },
        .{ .command = "make; echo \"exit: $?\"", .short = "make, echo" },
        .{ .command = "for i in $(seq 1 96); do printf 'marker %03d\\n' \"$i\"; sleep 0.03; done", .short = "printf, sleep" },
        .{ .command = "echo \"$(date)\" started && npm test -- --run --reporter=dot --bail", .short = "echo, npm test" },
        .{ .command = "cat AGENTS.md && printf 'executed\\n' >> executions.log", .short = "cat, printf" },
        // A comment runs to the end of its line.
        .{ .command = "# large lifecycle\nprintf 'LARGE_MARKER\\n' && seq 1 200000 > /dev/null", .short = "printf, seq" },
        .{ .command = "npm test -- --run --reporter=dot --bail # watch the flaky one && retry", .short = "npm test" },
        // A shell's `-c` script shows its own steps.
        .{ .command = "sh -c 'printf \"CTRL_O_LIVE_HEAD\\n\"; sleep 1; printf \"CTRL_O_LIVE_TAIL\\n\"'", .short = "printf, sleep, printf" },
        .{ .command = "zsh -lc 'for i in {1..80}; do printf \"%03d\\n\" \"$i\"; done; sleep 2; : > done.txt'", .short = "printf, sleep" },
        .{ .command = "bash -c \"cd desktop && npm ci && npm run build -- --mode production\"", .short = "npm ci, npm run build" },
        // A `{ ...; }` group is not an expansion, so its commands show.
        .{ .command = "{ make lint; make test; } 2>&1 | tail -40 && echo \"${status:-ok}\"", .short = "make lint, make test, echo" },
        .{ .command = "$(git rev-parse --show-toplevel)/scripts/check.sh --fast && make lint", .short = "check.sh, make lint" },
        .{ .command = "exec python3 '/Users/example/fx/terminal-session-fixture.py' '/Users/example/fx/state.json'", .short = "python3 terminal-session-fixture.py" },
        .{ .command = "cat <<'EOF' > notes.txt\nfirst line && more\nEOF\nsleep 300", .short = "cat, sleep" },
        .{ .command = "printf ok && printf '%s' alpha-beta-gamma-delta-epsilon-zeta-eta-theta >/dev/null", .short = "printf" },
        .{ .command = "make && npm test && cargo build --release && go vet ./... && zig build", .short = "make, npm test, cargo build +2 more" },
        // Loops and conditions show the commands inside them.
        .{ .command = "while true; do curl -s localhost:3000 && break; sleep 1; done", .short = "curl, sleep" },
        .{ .command = "if [ -f package.json ]; then npm test; fi", .short = "npm test" },
        .{ .command = "for f in src/*.zig; do zig fmt --check \"$f\"; done", .short = "zig fmt" },
        // Short one-step commands, and commands that do not lex, stay whole.
        .{ .command = "git status --short --branch", .short = null },
        .{ .command = "pwd", .short = null },
        .{ .command = "sh test.sh", .short = null },
        .{ .command = "echo 'unclosed && ls -la /a/very/long/path/that/goes/on/and/on/for/a/while", .short = null },
        .{ .command = "cd desktop", .short = null },
    };
    for (cases) |case| {
        const short = try shortCommand(arena, case.command);
        if (case.short) |expected| {
            try std.testing.expectEqualStrings(expected, short orelse return error.TestExpectedShortForm);
        } else {
            try std.testing.expect(short == null);
        }
    }
}

test "a command row shows the short form and keeps its label" {
    const alloc = std.testing.allocator;
    const command = "cd desktop && npm ci --no-audit --no-fund --loglevel=error && npm run build -- --mode production";
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Exited 2 " ++ command ++ "\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "● Read src/main.ts\n", .class = .tool_status } },
    };
    var details = [_]ToolDetailRecord{
        storyCommandDetail(1, "{\"command\":\"" ++ command ++ "\"}", 2, null),
        .{ .entry_id = 2, .tool_name = @constCast("read_file"), .activity_kind = .read, .outcome = .completed, .arguments_json = @constCast("{\"path\":\"src/main.ts\"}") },
    };
    details[0].command_display = @constCast(command);
    details[0].command_action_label = @constCast("Ran");
    var projection = try build(alloc, &entries, &details, 120);
    defer projection.deinit(alloc);
    const bytes = projection.entry_actions.items[0].override.bytes;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    _ = lines.next();
    const row = lines.next().?;
    try std.testing.expect(std.mem.startsWith(u8, row, "├ Exited 2 "));
    try std.testing.expect(std.mem.find(u8, row, "--no-audit") == null);
    try std.testing.expect(std.mem.find(u8, row, "npm") != null);
    try std.testing.expect(std.mem.find(u8, row, "build") != null);
}

test "a long command keeps its merge note when its row is clipped" {
    const alloc = std.testing.allocator;
    const command = "cd desktop && npm ci --no-audit --no-fund --loglevel=error && npm run build -- --mode production";
    const args = "{\"command\":\"" ++ command ++ "\"}";
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Exited 1 " ++ command ++ "\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "● Ran " ++ command ++ "\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 3, .bytes = "● Read src/main.ts\n", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        storyCommandDetail(1, args, 1, null),
        storyCommandDetail(2, args, 0, null),
        .{ .entry_id = 3, .tool_name = @constCast("read_file"), .activity_kind = .read, .outcome = .completed, .arguments_json = @constCast("{\"path\":\"src/main.ts\"}") },
    };
    const cols: u16 = 72;
    var projection = try build(alloc, &entries, &details, cols);
    defer projection.deinit(alloc);
    const bytes = projection.entry_actions.items[0].override.bytes;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    _ = lines.next();
    const merged = lines.next().?;
    try std.testing.expect(std.mem.startsWith(u8, merged, "├ Ran "));
    // The clipped command closes its highlight before the note.
    try std.testing.expect(std.mem.endsWith(u8, merged, "…\x1b[0m ×2 · passed on the 2nd run"));
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(merged) <= cols);
}

test "a command between two runs of another keeps all three rows" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Ran sh build.sh\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "● Ran sh lint.sh\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 3, .bytes = "● Ran sh build.sh\n", .class = .tool_status } },
    };
    const details = [_]ToolDetailRecord{
        storyCommandDetail(1, "{\"command\":\"sh build.sh\"}", 0, null),
        storyCommandDetail(2, "{\"command\":\"sh lint.sh\"}", 0, null),
        storyCommandDetail(3, "{\"command\":\"sh build.sh\"}", 0, null),
    };
    var projection = try build(alloc, &entries, &details, 120);
    defer projection.deinit(alloc);
    try std.testing.expectEqualStrings(
        "● Ran 3 shell commands ✓\n" ++
            "├ Ran \x1b[38;5;252msh\x1b[39m build.sh\n" ++
            "├ Ran \x1b[38;5;252msh\x1b[39m lint.sh\n" ++
            "└ Ran \x1b[38;5;252msh\x1b[39m build.sh",
        projection.entry_actions.items[0].override.bytes,
    );
}

test "one file read in parts shares a row" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Read src/main.zig\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "● Read src/main.zig\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 3, .bytes = "● Read src/main.zig\n", .class = .tool_status } },
    };
    var details: [3]ToolDetailRecord = undefined;
    const args = [_][]const u8{
        "{\"path\":\"src/main.zig\",\"start_line\":1,\"line_count\":40}",
        "{\"path\":\"src/main.zig\",\"start_line\":41,\"line_count\":40}",
        "{\"path\":\"src/main.zig\",\"start_line\":81,\"line_count\":40}",
    };
    for (&details, args, 0..) |*detail, arguments_json, index| detail.* = .{
        .entry_id = @intCast(index + 1),
        .tool_name = @constCast("read_file"),
        .activity_kind = .read,
        .arguments_json = @constCast(arguments_json),
        .outcome = .completed,
    };
    var projection = try build(alloc, &entries, &details, 120);
    defer projection.deinit(alloc);
    try std.testing.expectEqualStrings("● Read src/main.zig · 3 parts", projection.entry_actions.items[0].override.bytes);
}

test "repeated bare subagent waits share one row of their own" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● sent to reviewer · review the change\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "● sent to tester · run the tests\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 3, .bytes = "● waited for reviewer, tester\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 4, .bytes = "● checked reviewer, tester\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 5, .bytes = "● waited for tester\n", .class = .tool_status } },
    };
    const args = [_][]const u8{
        "{\"action\":\"message\",\"agent\":\"reviewer\",\"message\":\"review the change\"}",
        "{\"action\":\"message\",\"agent\":\"tester\",\"message\":\"run the tests\"}",
        "{\"action\":\"wait\"}",
        "{\"action\":\"status\"}",
        "{\"action\":\"wait\"}",
    };
    var details: [5]ToolDetailRecord = undefined;
    for (&details, args, 0..) |*detail, arguments_json, index| detail.* = .{
        .entry_id = @intCast(index + 1),
        .tool_name = @constCast("subagent"),
        .activity_kind = .subagent,
        .arguments_json = @constCast(arguments_json),
        .outcome = .completed,
    };
    var projection = try build(alloc, &entries, &details, 120);
    defer projection.deinit(alloc);
    // Main's waits share one row that shows the latest of them, and its
    // status keeps its own row, so each says what main did.
    try std.testing.expectEqualStrings(
        "● Started 2 subagents\n" ++
            "├ sent to reviewer · review the change\n" ++
            "├ sent to tester · run the tests\n" ++
            "├ waited for tester\n" ++
            "└ checked reviewer, tester",
        projection.entry_actions.items[0].override.bytes,
    );

    // Two waits alone are one row, which is the group's header.
    const lone_entries = [_]TranscriptEntry{ entries[2], entries[4] };
    const lone_details = [_]ToolDetailRecord{ details[2], details[4] };
    var waits = try build(alloc, &lone_entries, &lone_details, 120);
    defer waits.deinit(alloc);
    try std.testing.expectEqualStrings("● waited for tester", waits.entry_actions.items[0].override.bytes);
}

test "saved arguments that are not usable leave rows unmerged" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Read one.zig\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "● Read one.zig\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 3, .bytes = "● Ran make\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 4, .bytes = "● Ran make\n", .class = .tool_status } },
    };
    const args = [_][]const u8{ "{\"path\":", "{\"path\":7}", "[]", "{\"command\":\"\"}" };
    const tools = [_][]const u8{ "read_file", "read_file", "shell", "shell" };
    const kinds = [_]types.ToolActivityKind{ .read, .read, .command, .command };
    var details: [4]ToolDetailRecord = undefined;
    for (&details, args, tools, kinds, 0..) |*detail, arguments_json, tool, kind, index| detail.* = .{
        .entry_id = @intCast(index + 1),
        .tool_name = @constCast(tool),
        .activity_kind = kind,
        .arguments_json = @constCast(arguments_json),
        .outcome = .completed,
    };
    var projection = try build(alloc, &entries, &details, 120);
    defer projection.deinit(alloc);
    const bytes = projection.entry_actions.items[0].override.bytes;
    try std.testing.expect(std.mem.startsWith(u8, bytes, "● Ran 2 shell commands ✓\n"));
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, bytes, "\n"));
}

test "a failure reason is one line of plain text within the width" {
    const alloc = std.testing.allocator;
    const cols: u16 = 64;
    const hostile = "\x1b[31mstarting\x1b[0m\r\tstep\nerror: " ++ text_utils.repeat("x", 500) ++ " \xff\xfe end\n";
    const escaped = "\\x1b[31mstarting\\x1b[0m\\x0aerror: boom \\xff end";
    for ([_][]const u8{ hostile, escaped }) |result| {
        const entries = [_]TranscriptEntry{
            .{ .raw_bytes = .{ .id = 1, .bytes = "● Exited 3 sh hostile.sh\n", .class = .tool_status } },
        };
        const details = [_]ToolDetailRecord{storyCommandDetail(1, "{\"command\":\"sh hostile.sh\"}", 3, result)};
        var projection = try build(alloc, &entries, &details, cols);
        defer projection.deinit(alloc);
        const bytes = projection.entry_actions.items[0].override.bytes;
        const newline = std.mem.findScalar(u8, bytes, '\n') orelse return error.TestExpectedEqual;
        const reason = bytes[newline + 1 ..];
        try std.testing.expect(std.mem.findScalar(u8, reason, '\n') == null);
        try std.testing.expect(std.mem.find(u8, reason, "✗ exit 3 · error: ") != null);
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(reason) <= cols);
        try std.testing.expect(std.mem.find(u8, reason, "starting") == null);
        var index: usize = 0;
        while (index < reason.len) : (index += 1) {
            if (skipSgrSequence(reason, &index)) {
                index -= 1;
                continue;
            }
            try std.testing.expect(reason[index] >= 0x20 and reason[index] != 0x7f);
        }
    }
}

test "the turn summary leads with a recap of what the turn changed and ran" {
    const alloc = std.testing.allocator;
    const entries = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Edited main.zig +2 / -1\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "● Exited 2 sh build.sh\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 3, .bytes = "● Ran sh build.sh\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 4, .bytes = "  3s (↑1 ↓2)", .class = .turn_summary } },
    };
    const details = [_]ToolDetailRecord{
        .{
            .entry_id = 1,
            .tool_name = @constCast("edit_file"),
            .activity_kind = .edit,
            .arguments_json = @constCast("{\"path\":\"main.zig\"}"),
            .outcome = .completed,
        },
        storyCommandDetail(2, "{\"command\":\"sh build.sh\"}", 2, null),
        storyCommandDetail(3, "{\"command\":\"sh build.sh\"}", 0, null),
    };
    var projection = try build(alloc, &entries, &details, 120);
    defer projection.deinit(alloc);
    try std.testing.expectEqualStrings(
        "  1 file changed +2 -1 · ran 2 commands · 3s (↑1 ↓2)",
        projection.entry_actions.items[3].override.bytes,
    );

    // When the longer row would not fit, the turn summary stays as it was.
    var narrow = try build(alloc, &entries, &details, 30);
    defer narrow.deinit(alloc);
    try std.testing.expect(narrow.entry_actions.items[3] == .keep);

    // A turn that only read files says so; a turn with no tools keeps its line.
    const reads = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● Read a.zig\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "  1s", .class = .turn_summary } },
    };
    const read_details = [_]ToolDetailRecord{.{
        .entry_id = 1,
        .tool_name = @constCast("read_file"),
        .activity_kind = .read,
        .arguments_json = @constCast("{\"path\":\"a.zig\"}"),
        .outcome = .completed,
    }};
    var read_projection = try build(alloc, &reads, &read_details, 120);
    defer read_projection.deinit(alloc);
    try std.testing.expectEqualStrings("  Explored 1 file · 1s", read_projection.entry_actions.items[1].override.bytes);
    var quiet = try build(alloc, reads[1..], &.{}, 120);
    defer quiet.deinit(alloc);
    try std.testing.expect(quiet.entry_actions.items[0] == .keep);

    // A turn that started subagents did more than explore, so its line stays.
    const delegated = [_]TranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .bytes = "● sent to helper · Check one-off cleanup\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "● Read a.zig\n", .class = .tool_status } },
        .{ .raw_bytes = .{ .id = 3, .bytes = "  1s", .class = .turn_summary } },
    };
    const delegated_details = [_]ToolDetailRecord{
        .{
            .entry_id = 1,
            .tool_name = @constCast("subagent"),
            .activity_kind = .subagent,
            .arguments_json = @constCast("{\"action\":\"message\",\"agent\":\"helper\",\"message\":\"Check one-off cleanup\"}"),
            .outcome = .completed,
        },
        .{
            .entry_id = 2,
            .tool_name = @constCast("read_file"),
            .activity_kind = .read,
            .arguments_json = @constCast("{\"path\":\"a.zig\"}"),
            .outcome = .completed,
        },
    };
    var delegated_projection = try build(alloc, &delegated, &delegated_details, 120);
    defer delegated_projection.deinit(alloc);
    try std.testing.expect(delegated_projection.entry_actions.items[2] == .keep);
}

/// Reads a fuzz input one choice at a time; past its end every byte is 0.
const StoryFuzzBytes = struct {
    bytes: []const u8,
    index: usize = 0,

    fn byte(self: *StoryFuzzBytes) u8 {
        if (self.index >= self.bytes.len) return 0;
        defer self.index += 1;
        return self.bytes[self.index];
    }

    fn chunk(self: *StoryFuzzBytes, max: usize) []const u8 {
        const wanted = self.byte() % (max + 1);
        const len = @min(wanted, self.bytes.len -| self.index);
        defer self.index += len;
        return self.bytes[self.index..][0..len];
    }
};

/// Builds one compact group and its turn summary from fuzz bytes: core status
/// lines from a fixed set, with model arguments and command output taken from
/// the input, and checks that every line fits the width and carries no
/// control byte but a style's escape.
fn checkStoryRows(input: []const u8) !void {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fuzz: StoryFuzzBytes = .{ .bytes = input };

    const statuses = [_][]const u8{
        "● Ran sh test.sh\n",
        "● Exited 1 sh test.sh\n",
        "● Read desktop/src/main.ts\n",
        "● Edited main.zig +2 / -1\n",
        "● Failed main.zig: old_string not found\n",
        "● sent to reviewer · review\n",
        "▪ Cancelled sleep 30 · What can fx do differently?",
        "⊘ Denied by auto agent rm -rf build\n",
        "● Searched createWindow(\n",
    };
    const Tool = struct { name: []const u8, kind: types.ToolActivityKind, key: []const u8 };
    const tools = [_]Tool{
        .{ .name = "shell", .kind = .command, .key = "command" },
        .{ .name = "read_file", .kind = .read, .key = "path" },
        .{ .name = "grep_files", .kind = .read, .key = "pattern" },
        .{ .name = "glob_files", .kind = .list, .key = "pattern" },
        .{ .name = "edit_file", .kind = .edit, .key = "path" },
        .{ .name = "write_file", .kind = .write, .key = "path" },
        .{ .name = "subagent", .kind = .subagent, .key = "agent" },
        .{ .name = "web_search", .kind = .read, .key = "query" },
    };
    const outcomes = [_]?types.ToolOutcomeKind{ null, .completed, .failed, .denied, .cancelled, .deferred };

    const max_calls = 12;
    var entries: [max_calls + 1]TranscriptEntry = undefined;
    var details: [max_calls]ToolDetailRecord = undefined;
    const count = 1 + fuzz.byte() % max_calls;
    for (0..count) |index| {
        const entry_id: u32 = @intCast(index + 1);
        const tool = tools[fuzz.byte() % tools.len];
        entries[index] = .{ .raw_bytes = .{
            .id = entry_id,
            .bytes = statuses[fuzz.byte() % statuses.len],
            .class = .tool_status,
        } };
        const arguments_json: ?[]u8 = switch (fuzz.byte() % 4) {
            0 => null,
            1 => try arena.dupe(u8, fuzz.chunk(64)),
            2 => blk: {
                var out: std.Io.Writer.Allocating = .init(arena);
                try out.writer.print("{{\"action\":\"run\",\"{s}\":", .{tool.key});
                std.json.Stringify.value(fuzz.chunk(48), .{}, &out.writer) catch try out.writer.writeAll("\"\"");
                try out.writer.writeByte('}');
                break :blk out.written();
            },
            else => try arena.dupe(u8, "{}"),
        };
        const result = fuzz.chunk(160);
        details[index] = .{
            .entry_id = entry_id,
            .tool_name = @constCast(tool.name),
            .activity_kind = tool.kind,
            .arguments_json = arguments_json,
            .result = if (result.len == 0) null else try arena.dupe(u8, result),
            .outcome = outcomes[fuzz.byte() % outcomes.len],
            .command_process_presentation = switch (fuzz.byte() % 5) {
                0 => null,
                1 => .{ .exit_code = 0 },
                2 => .{ .exit_code = fuzz.byte() },
                3 => .timed_out,
                else => .{ .signal = 9 },
            },
        };
    }
    entries[count] = .{ .raw_bytes = .{ .id = @intCast(count + 1), .bytes = "  2s (↑1 ↓2)", .class = .turn_summary } };
    const cols: u16 = 1 + @as(u16, fuzz.byte()) % 160;

    // Some shell calls get a recorded command, which the row can show in
    // short form. Inputs that end before here keep every row as it was.
    const pieces = [_][]const u8{
        "cd desktop",    "&&",            "git status",     "--short",    "|",        "head -5",
        "'quoted && x'", "npm run build", ";",              "FOO=1",      "sudo",     "<<EOF",
        "EOF",           "\n",            "2>&1",           "timeout 30", "./run.sh", "echo done",
        "gh issue list", "-R",            "vercel-labs/fx", "\"",         "\\",       "git -C x fetch",
    };
    for (0..count) |index| {
        if (details[index].activity_kind != .command or fuzz.byte() % 2 != 1) continue;
        var raw: std.Io.Writer.Allocating = .init(arena);
        const piece_count = 1 + fuzz.byte() % 12;
        for (0..piece_count) |piece| {
            if (piece > 0) try raw.writer.writeByte(' ');
            if (fuzz.byte() % 4 == 0) try raw.writer.writeAll(fuzz.chunk(12)) else try raw.writer.writeAll(pieces[fuzz.byte() % pieces.len]);
        }
        const display = try arena.print("{f}", .{text_utils.terminalSafe(raw.written())});
        details[index].command_display = display;
        entries[index] = .{ .raw_bytes = .{
            .id = @intCast(index + 1),
            .bytes = try arena.print("● Ran {s}\n", .{display}),
            .class = .tool_status,
        } };
    }

    var projection = try build(alloc, entries[0 .. count + 1], details[0..count], cols);
    defer projection.deinit(alloc);
    for (projection.entry_actions.items) |action| {
        if (action != .override) continue;
        var lines = std.mem.splitScalar(u8, action.override.bytes, '\n');
        while (lines.next()) |line| {
            try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= cols);
            // Apart from the styles fx writes, every byte is terminal-safe.
            var plain: std.Io.Writer.Allocating = .init(arena);
            var index: usize = 0;
            while (index < line.len) {
                if (skipSgrSequence(line, &index)) continue;
                try plain.writer.writeByte(line[index]);
                index += 1;
            }
            try std.testing.expect(text_utils.isTerminalSafe(plain.written()));
        }
    }
}

fn fuzzStoryRows(_: void, smith: *std.testing.Smith) !void {
    var buffer: [2048]u8 = undefined;
    const len = smith.slice(&buffer);
    try checkStoryRows(buffer[0..len]);
}

test "story rows fit the width and stay plain text for fuzzed arguments and output" {
    try std.testing.fuzz({}, fuzzStoryRows, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "",
            "\x02\x00\x01\x02\x0ash test.sh\x00\x01\x02\x01",
            "\x05\x01\x02\x01\x10{\"path\":\"a.zig\"}\x00\x01\x01\x63",
        }) ++ @import("fuzz_corpus").tool_story_rows.*),
    });
}
