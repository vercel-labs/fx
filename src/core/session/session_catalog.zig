const std = @import("std");
const session_display_metadata = @import("session_display_metadata.zig");
const session_store = @import("session_store.zig");
const session_summary_codec = @import("session_summary_codec.zig");
const text_utils = @import("../shared/text_utils.zig");
const fuzzy_match = @import("../shared/fuzzy_match.zig");

const Allocator = std.mem.Allocator;

pub const Scope = enum {
    current_workspace,
    all_workspaces,
};

pub const LoadState = enum {
    loading,
    ready,
    failed,
};

pub const ResumeFailure = enum {
    open_elsewhere,
    being_updated,
    unavailable,
};

pub fn filteredCount(summaries: []const session_store.SessionSummary, query: []const u8) usize {
    return pickerFilter(summaries, null, query, .any).count();
}

pub fn summaryAt(
    summaries: []const session_store.SessionSummary,
    query: []const u8,
    display_index: usize,
) ?*const session_store.SessionSummary {
    return &summaries[pickerFilter(summaries, null, query, .any).at(display_index) orelse return null];
}

/// Which summaries a filter considers: every one, or only those the resume
/// picker can open.
const Candidates = enum { any, resumable };

/// The sessions the resume picker lists for `query` from newest-first
/// `summaries`, in `workspace_root` or every workspace when it is null,
/// kept in their order (`fuzzy_match.Filter`): the ones that match as typed
/// when any does, and otherwise every match.
pub fn pickerFilter(
    summaries: []const session_store.SessionSummary,
    workspace_root: ?[]const u8,
    query: []const u8,
    candidates: Candidates,
) fuzzy_match.Filter(PickerMatches) {
    return .init(.{ .summaries = summaries, .workspace_root = workspace_root, .query = query, .candidates = candidates }, summaries.len);
}

const PickerMatches = struct {
    summaries: []const session_store.SessionSummary,
    workspace_root: ?[]const u8,
    query: []const u8,
    candidates: Candidates,

    pub fn matchAt(self: PickerMatches, position: usize) ?fuzzy_match.Match {
        const summary = self.summaries[position];
        if (self.workspace_root) |root| {
            const summary_workspace = summary.workspace_root orelse return null;
            if (!std.mem.eql(u8, summary_workspace, root)) return null;
        }
        if (self.candidates == .resumable and !summary.hasResumableContent()) return null;
        return sessionMatch(summary, self.query);
    }
};

/// One resume picker page from newest-first `summaries`: up to `limit` that
/// the picker lists for `query` in `workspace_root`, after `continuation`.
/// `has_more` is set only when another listed summary follows, so loading
/// more always has a match to show. Caller owns the returned page.
pub fn resumablePage(
    alloc: Allocator,
    summaries: []const session_store.SessionSummary,
    workspace_root: ?[]const u8,
    query: []const u8,
    continuation: ?session_store.ResumableSessionContinuation,
    limit: usize,
) !session_store.ResumableSessionPage {
    const page_limit = @max(limit, 1);
    var page: session_store.ResumableSessionPage = .{};
    errdefer page.deinit(alloc);
    const listed = pickerFilter(summaries, workspace_root, query, .resumable);
    for (summaries, 0..) |summary, index| {
        if (!listed.keeps(index)) continue;
        if (continuation) |position| {
            if (!session_summary_codec.summaryFollowsContinuation(summary, position)) continue;
        }
        if (page.summaries.items.len >= page_limit) {
            page.has_more = true;
            break;
        }
        var copied = try session_summary_codec.cloneSessionSummary(alloc, summary);
        page.summaries.append(alloc, copied) catch |err| {
            copied.deinit(alloc);
            return err;
        };
    }
    return page;
}

pub fn displayTitle(summary: session_store.SessionSummary) []const u8 {
    return summary.title orelse session_display_metadata.fallback_title;
}

pub fn workspacePath(summary: session_store.SessionSummary) []const u8 {
    return summary.workspace_root orelse summary.origin_workspace_root orelse "(unknown workspace)";
}

pub fn relativeActivityAge(buf: []u8, updated_at_ms: i64, now_ms: i64) []const u8 {
    const delta_ms: i64 = @max(0, now_ms - updated_at_ms);
    if (delta_ms < std.time.ms_per_min) return "just now";
    if (delta_ms < std.time.ms_per_hour) {
        return std.mem.print(buf, "{d}m ago", .{@divFloor(delta_ms, std.time.ms_per_min)}) catch "recently";
    }
    if (delta_ms < std.time.ms_per_day) {
        return std.mem.print(buf, "{d}h ago", .{@divFloor(delta_ms, std.time.ms_per_hour)}) catch "recently";
    }
    return std.mem.print(buf, "{d}d ago", .{@divFloor(delta_ms, std.time.ms_per_day)}) catch "recently";
}

// Same buckets as relativeActivityAge without the " ago" suffix, for tight
// single-line layouts: "now", "5m", "2h", "1d".
pub fn relativeActivityAgeCompact(buf: []u8, updated_at_ms: i64, now_ms: i64) []const u8 {
    const delta_ms: i64 = @max(0, now_ms - updated_at_ms);
    if (delta_ms < std.time.ms_per_min) return "now";
    if (delta_ms < std.time.ms_per_hour) {
        return std.mem.print(buf, "{d}m", .{@divFloor(delta_ms, std.time.ms_per_min)}) catch "recently";
    }
    if (delta_ms < std.time.ms_per_day) {
        return std.mem.print(buf, "{d}h", .{@divFloor(delta_ms, std.time.ms_per_hour)}) catch "recently";
    }
    return std.mem.print(buf, "{d}d", .{@divFloor(delta_ms, std.time.ms_per_day)}) catch "recently";
}

/// A session matches by its title, or by the words of its workspace path or
/// preview.
fn sessionMatch(summary: session_store.SessionSummary, query: []const u8) ?fuzzy_match.Match {
    return fuzzy_match.match(query, &.{
        .{ .text = displayTitle(summary) },
        .{ .text = workspacePath(summary), .kind = .text },
        .{ .text = summary.preview orelse "", .kind = .text },
    });
}

test "session catalog filters titles previews and workspace paths" {
    const summaries = [_]session_store.SessionSummary{
        .{
            .id = @constCast("one"),
            .workspace_root = @constCast("/worktrees/alpha"),
            .title = @constCast("Fix renderer"),
            .preview = @constCast("inspect footer state"),
            .created_at_ms = 1,
            .updated_at_ms = 2,
            .conversation_language = .literal("en"),
            .history_len = 4,
        },
        .{
            .id = @constCast("two"),
            .workspace_root = @constCast("/worktrees/beta"),
            .title = @constCast("Review sessions"),
            .created_at_ms = 1,
            .updated_at_ms = 3,
            .conversation_language = .literal("en"),
            .history_len = 2,
        },
    };

    try std.testing.expectEqual(@as(usize, 2), filteredCount(&summaries, ""));
    try std.testing.expectEqual(@as(usize, 1), filteredCount(&summaries, "RENDER"));
    try std.testing.expectEqualStrings("two", summaryAt(&summaries, "beta", 0).?.id);
    try std.testing.expectEqualStrings("one", summaryAt(&summaries, "footer", 0).?.id);
    try std.testing.expect(summaryAt(&summaries, "missing", 0) == null);

    // Words in any order, and letters in order from a title word.
    try std.testing.expectEqualStrings("one", summaryAt(&summaries, "renderer fix", 0).?.id);
    try std.testing.expectEqualStrings("one", summaryAt(&summaries, "fxrndr", 0).?.id);
    try std.testing.expectEqualStrings("two", summaryAt(&summaries, "rvw", 0).?.id);
    try std.testing.expectEqual(@as(usize, 1), filteredCount(&summaries, "rvw"));
    // Words may come from the preview and the workspace path together, but
    // a path never matches letters in order.
    try std.testing.expectEqualStrings("one", summaryAt(&summaries, "footer alpha", 0).?.id);
    try std.testing.expectEqual(@as(usize, 0), filteredCount(&summaries, "wrktrs"));
}

test "session catalog pages checkpoint-only sessions without changing turn counts" {
    const alloc = std.testing.allocator;
    const checkpoint = session_store.SessionSummary{
        .id = @constCast("checkpoint"),
        .created_at_ms = 1,
        .updated_at_ms = 2,
        .conversation_language = .literal("en"),
        .history_len = 0,
        .has_checkpoint = true,
    };
    var empty = checkpoint;
    empty.id = @constCast("empty");
    empty.has_checkpoint = false;
    var page = try resumablePage(alloc, &.{ checkpoint, empty }, null, "", null, 10);
    defer page.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), page.summaries.items.len);
    try std.testing.expectEqualStrings("checkpoint", page.summaries.items[0].id);
    try std.testing.expect(page.summaries.items[0].has_checkpoint);
    try std.testing.expectEqual(@as(usize, 0), page.summaries.items[0].history_len);
}

test "session catalog pages filter the workspace and preserve append cursor order" {
    var summaries = [_]session_store.SessionSummary{
        .{ .id = @constCast("new"), .workspace_root = @constCast("/workspace"), .created_at_ms = 1, .updated_at_ms = 4, .conversation_language = .literal("en"), .history_len = 1 },
        .{ .id = @constCast("foreign"), .workspace_root = @constCast("/foreign"), .created_at_ms = 1, .updated_at_ms = 3, .conversation_language = .literal("en"), .history_len = 1 },
        .{ .id = @constCast("old"), .workspace_root = @constCast("/workspace"), .created_at_ms = 1, .updated_at_ms = 1, .conversation_language = .literal("en"), .history_len = 1 },
    };
    session_summary_codec.sortSummariesNewestFirst(&summaries);
    var page = try resumablePage(std.testing.allocator, &summaries, "/workspace", "", null, 1);
    defer page.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), page.summaries.items.len);
    try std.testing.expectEqualStrings("new", page.summaries.items[0].id);
    try std.testing.expect(page.has_more);

    var next = try resumablePage(std.testing.allocator, &summaries, "/workspace", "", .{
        .updated_at_ms = page.summaries.items[0].updated_at_ms,
        .id = page.summaries.items[0].id,
    }, 1);
    defer next.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), next.summaries.items.len);
    try std.testing.expectEqualStrings("old", next.summaries.items[0].id);
    try std.testing.expect(!next.has_more);
}

test "session catalog activity age uses the last update" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("just now", relativeActivityAge(&buf, 1_000, 1_000));
    try std.testing.expectEqualStrings("3m ago", relativeActivityAge(&buf, 1_000, 1_000 + 3 * std.time.ms_per_min));
    try std.testing.expectEqualStrings("2h ago", relativeActivityAge(&buf, 1_000, 1_000 + 2 * std.time.ms_per_hour));
    try std.testing.expectEqualStrings("3d ago", relativeActivityAge(&buf, 1_000, 1_000 + 3 * std.time.ms_per_day));
}

test "session catalog compact activity age drops the ago suffix" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("now", relativeActivityAgeCompact(&buf, 1_000, 1_000));
    try std.testing.expectEqualStrings("3m", relativeActivityAgeCompact(&buf, 1_000, 1_000 + 3 * std.time.ms_per_min));
    try std.testing.expectEqualStrings("2h", relativeActivityAgeCompact(&buf, 1_000, 1_000 + 2 * std.time.ms_per_hour));
    try std.testing.expectEqualStrings("3d", relativeActivityAgeCompact(&buf, 1_000, 1_000 + 3 * std.time.ms_per_day));
}
