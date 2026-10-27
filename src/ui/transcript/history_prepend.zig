//! Older saved history added above a transcript's entries. It belongs to the
//! full transcript only: the inline flow already printed its own history into
//! the terminal's scrollback, which cannot take lines above it. Prepending
//! leaves the existing entries and the inline flow untouched, and keeps the
//! full-transcript reader on the entry it was showing.

const std = @import("std");
const types = @import("../../core/shared/types.zig");
const full_transcript_page = @import("../../core/output/full_transcript_page.zig");
const transcript_runtime = @import("runtime.zig");

const Allocator = std.mem.Allocator;
const TranscriptRuntime = transcript_runtime.TranscriptRuntime;
const TranscriptEntry = transcript_runtime.TranscriptEntry;

pub const Error = Allocator.Error || error{EntryIdsOutOfOrder};

/// Moves the entries, tool details, and command-output blocks of `source`
/// into `target` before the entry at `insert_at`. Entry ids order the
/// transcript, so `source`'s ids must sort between the entry before
/// `insert_at` and the one at it; otherwise nothing moves. The moved entries
/// are hidden from the inline flow. `source` is left empty.
pub fn prepend(
    target: *TranscriptRuntime,
    alloc: Allocator,
    insert_at: usize,
    source: *TranscriptRuntime,
) Error!void {
    const moved = source.entries.items;
    if (moved.len == 0) return;
    const entries = target.entries.items;
    const below: u32 = if (insert_at > 0) entries[insert_at - 1].id() else 0;
    const above: u32 = if (insert_at < entries.len) entries[insert_at].id() else std.math.maxInt(u32);
    if (moved[0].id() <= below or moved[moved.len - 1].id() >= above) return error.EntryIdsOutOfOrder;

    try target.entries.ensureUnusedCapacity(alloc, moved.len);
    try target.tool_details.ensureUnusedCapacity(alloc, source.tool_details.items.len);
    try target.command_output_blocks.ensureUnusedCapacity(alloc, source.command_output_blocks.items.len);

    for (moved) |*entry| entry.hideInline();
    target.entries.replaceRangeAssumeCapacity(insert_at, 0, moved);
    source.entries.clearRetainingCapacity();

    // Details stay sorted by entry id.
    var detail_at: usize = 0;
    while (detail_at < target.tool_details.items.len and
        target.tool_details.items[detail_at].entry_id <= below) detail_at += 1;
    target.tool_details.replaceRangeAssumeCapacity(detail_at, 0, source.tool_details.items);
    source.tool_details.clearRetainingCapacity();

    // Blocks are oldest first; the open ones are held by index.
    const block_count = source.command_output_blocks.items.len;
    target.command_output_blocks.replaceRangeAssumeCapacity(0, 0, source.command_output_blocks.items);
    source.command_output_blocks.clearRetainingCapacity();
    const display = &target.command_output_display;
    if (display.open_block) |*index| index.* += block_count;
    if (display.open_command_block) |*index| index.* += block_count;

    shiftPageAnchor(target, insert_at, moved.len, .insert);
    target.markTranscriptStructureDirty();
}

/// Inserts a full-transcript-only notice with id `entry_id` at `insert_at`.
pub fn insertNotice(
    target: *TranscriptRuntime,
    alloc: Allocator,
    insert_at: usize,
    entry_id: u32,
    notice: types.SemanticNotice,
) Allocator.Error!void {
    const topic = try alloc.dupe(u8, notice.topic);
    errdefer alloc.free(topic);
    const body = try alloc.dupe(u8, notice.body);
    errdefer alloc.free(body);
    try target.entries.insert(alloc, insert_at, .{ .semantic_notice = .{
        .id = entry_id,
        .topic = topic,
        .tone = notice.tone,
        .body = body,
        .visibility = .full_only,
        .inline_hidden = true,
    } });
    shiftPageAnchor(target, insert_at, 1, .insert);
    target.markTranscriptStructureDirty();
}

/// Removes the entry with id `entry_id`, if any, without touching the rest.
/// Only for entries without tool details or command output.
pub fn removeEntry(target: *TranscriptRuntime, alloc: Allocator, entry_id: u32) void {
    const index = indexOf(target, entry_id) orelse return;
    var removed = target.entries.orderedRemove(index);
    removed.deinit(alloc);
    shiftPageAnchor(target, index, 1, .remove);
    target.markTranscriptStructureDirty();
}

/// The index of the first entry whose id is at least `entry_id`.
pub fn firstIndexFrom(target: *const TranscriptRuntime, entry_id: u32) usize {
    for (target.entries.items, 0..) |entry, index| {
        if (entry.id() >= entry_id) return index;
    }
    return target.entries.items.len;
}

fn indexOf(target: *const TranscriptRuntime, entry_id: u32) ?usize {
    for (target.entries.items, 0..) |entry, index| {
        if (entry.id() == entry_id) return index;
    }
    return null;
}

/// Whether the full transcript shows the top of its oldest entries.
pub fn readerAtTop(target: *const TranscriptRuntime) bool {
    if (!target.fullTranscriptActive()) return false;
    const page = if (target.full_transcript_installed_page) |*value| value else return false;
    return page.source.range.start == 0 and target.full_transcript.scroll_rows == 0;
}

/// Shows the entry with id `entry_id` at the top of the full transcript.
/// The page moves only when its range would not hold the entry, so the page
/// shown until the new one is laid out stays on screen.
pub fn revealEntry(target: *TranscriptRuntime, entry_id: u32) void {
    if (!target.fullTranscriptActive()) return;
    const index = indexOf(target, entry_id) orelse return;
    const range = full_transcript_page.sourceRange(.{
        .content_revision = 0,
        .cols = 0,
        .anchor = target.full_transcript_page_anchor,
    }, target.entries.items.len);
    if (index < range.start or index >= range.end) target.full_transcript_page_anchor = .{ .entry_index = index };
    target.full_transcript = target.full_transcript.select_page_boundary(entry_id);
}

const Change = enum { insert, remove };

/// Keeps an index-anchored full-transcript page on the same entry after
/// `count` entries were inserted or removed at `at`, and the page on screen
/// with it: it stays shown, as the same surface, until the page for the new
/// content is laid out off the UI thread, which then pins the reader to the
/// entry they were reading.
fn shiftPageAnchor(target: *TranscriptRuntime, at: usize, count: usize, change: Change) void {
    shiftAnchor(&target.full_transcript_page_anchor, at, count, change);
    const page = if (target.full_transcript_installed_page) |*value| value else return;
    shiftAnchor(&page.source.request.anchor, at, count, change);
    const range = &page.source.range;
    if (range.start >= at) range.start = shiftIndex(range.start, at, count, change);
    if (range.end > at) range.end = @max(range.start, shiftIndex(range.end, at, count, change));
}

fn shiftAnchor(anchor: *full_transcript_page.Anchor, at: usize, count: usize, change: Change) void {
    switch (anchor.*) {
        .tail => {},
        .entry_index => |*index| if (index.* >= at) {
            index.* = shiftIndex(index.*, at, count, change);
        },
    }
}

fn shiftIndex(index: usize, at: usize, count: usize, change: Change) usize {
    return switch (change) {
        .insert => index + count,
        .remove => @max(at, index -| count),
    };
}

fn testRuntime(entries: []const u32) !TranscriptRuntime {
    var runtime = TranscriptRuntime{ .layout = .{
        .rows = 24,
        .cols = 40,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    } };
    for (entries) |id| {
        try runtime.entries.append(std.testing.allocator, .{ .raw_bytes = .{
            .id = id,
            .bytes = try std.testing.allocator.dupe(u8, "row\n"),
        } });
    }
    return runtime;
}

test "prepend inserts below the welcome without touching existing entries" {
    const alloc = std.testing.allocator;
    var target = try testRuntime(&.{ 1, 100, 101 });
    defer target.deinit(alloc);
    var source = try testRuntime(&.{ 50, 51 });
    defer source.deinit(alloc);
    const before_ptr = target.entries.items[1].raw_bytes.bytes.ptr;
    // The inline flow already printed: prepending must not change it.
    try target.transcript.appendSlice(alloc, "row\nrow\nrow\n");
    target.full_transcript_page_anchor = .{ .entry_index = 1 };
    const revision = target.full_transcript_content_revision;

    try prepend(&target, alloc, 1, &source);

    var ids: [5]u32 = undefined;
    for (target.entries.items, 0..) |entry, index| ids[index] = entry.id();
    try std.testing.expectEqualSlices(u32, &.{ 1, 50, 51, 100, 101 }, &ids);
    // The existing entries are the same values, not re-laid-out copies, and
    // stay in the inline flow; the older ones are full-transcript only.
    try std.testing.expectEqual(before_ptr, target.entries.items[3].raw_bytes.bytes.ptr);
    try std.testing.expect(!target.entries.items[3].raw_bytes.inline_hidden);
    try std.testing.expect(target.entries.items[1].raw_bytes.inline_hidden);
    try std.testing.expectEqual(@as(usize, 0), source.entries.items.len);
    try std.testing.expectEqualStrings("row\nrow\nrow\n", target.transcript.items);
    // The page anchor follows the entry it named.
    try std.testing.expectEqual(full_transcript_page.Anchor{ .entry_index = 3 }, target.full_transcript_page_anchor);
    try std.testing.expect(target.full_transcript_content_revision != revision);
}

test "prepend refuses ids that would not sort above the welcome and below the window" {
    const alloc = std.testing.allocator;
    var target = try testRuntime(&.{ 1, 100 });
    defer target.deinit(alloc);
    var source = try testRuntime(&.{ 100, 101 });
    defer source.deinit(alloc);
    try std.testing.expectError(error.EntryIdsOutOfOrder, prepend(&target, alloc, 1, &source));
    try std.testing.expectEqual(@as(usize, 2), target.entries.items.len);
    try std.testing.expectEqual(@as(usize, 2), source.entries.items.len);
}

test "a loading notice comes and goes without moving the reader's entry" {
    const alloc = std.testing.allocator;
    var target = try testRuntime(&.{ 1, 100, 101 });
    defer target.deinit(alloc);
    target.full_transcript_page_anchor = .{ .entry_index = 2 };
    try insertNotice(&target, alloc, 1, 99, .{ .topic = "session", .tone = .neutral, .body = "Loading earlier history…" });
    try std.testing.expectEqual(@as(u32, 99), target.entries.items[1].id());
    try std.testing.expectEqual(full_transcript_page.Anchor{ .entry_index = 3 }, target.full_transcript_page_anchor);
    try std.testing.expectEqual(@as(usize, 1), firstIndexFrom(&target, 99));
    removeEntry(&target, alloc, 99);
    try std.testing.expectEqual(@as(usize, 3), target.entries.items.len);
    try std.testing.expectEqual(full_transcript_page.Anchor{ .entry_index = 2 }, target.full_transcript_page_anchor);
}
