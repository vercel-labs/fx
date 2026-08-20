const std = @import("std");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

const max_root_user_bytes: usize = 1024;
const max_persisted_permission_feedback_bytes: usize = 320;
const max_same_turn_permission_feedback_bytes: usize = 384;
const current_label = "current_request: ";
const first_root_user_label = "first_root_user_request: ";
const recent_root_user_label = "recent_root_user_request: ";
const omitted_root_user_label = "omitted_proven_root_user_turns: ";
const trusted_permission_feedback_label = "trusted_user_permission_feedback: ";
const omitted_permission_feedback_label = "omitted_trusted_user_permission_feedback: ";
const content_omission_marker = " [... omitted ...] ";
const count_marker_reserve: usize = 64;

pub fn isCanonicalRootUserContext(context: []const u8) bool {
    if (context.len == 0 or context.len > max_root_user_bytes or
        !std.mem.endsWith(u8, context, "\n"))
    {
        return false;
    }

    var lines = std.mem.splitScalar(u8, context[0 .. context.len - 1], '\n');
    const current = lines.next() orelse return false;
    if (!canonicalTextLine(current, current_label)) return false;

    var saw_first = false;
    var saw_recent = false;
    var saw_omitted_root = false;
    var feedback_started = false;
    var saw_omitted_feedback = false;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, first_root_user_label)) {
            if (feedback_started or saw_first or saw_recent or saw_omitted_root or
                !canonicalTextLine(line, first_root_user_label)) return false;
            saw_first = true;
        } else if (std.mem.startsWith(u8, line, recent_root_user_label)) {
            if (feedback_started or saw_omitted_root or
                !canonicalTextLine(line, recent_root_user_label)) return false;
            saw_recent = true;
        } else if (std.mem.startsWith(u8, line, omitted_root_user_label)) {
            if (feedback_started or saw_omitted_root or
                !canonicalCountLine(line, omitted_root_user_label)) return false;
            saw_omitted_root = true;
        } else if (std.mem.startsWith(u8, line, trusted_permission_feedback_label)) {
            if (saw_omitted_feedback or
                !canonicalTextLine(line, trusted_permission_feedback_label)) return false;
            feedback_started = true;
        } else if (std.mem.startsWith(u8, line, omitted_permission_feedback_label)) {
            if (saw_omitted_feedback or
                !canonicalCountLine(line, omitted_permission_feedback_label)) return false;
            feedback_started = true;
            saw_omitted_feedback = true;
        } else return false;
    }
    return true;
}

pub fn currentRootUserRequest(context: []const u8) ?[]const u8 {
    if (!isCanonicalRootUserContext(context)) return null;
    return lineValue(context, current_label);
}

/// Returns the bounded proven root-request portion of canonical context.
/// Historical permission feedback is retained for execution/session purposes
/// but never projected as reviewer authority.
pub fn reviewRootUserContext(context: []const u8) ?[]const u8 {
    if (!isCanonicalRootUserContext(context)) return null;
    return context[0..canonicalFeedbackStart(context)];
}

fn canonicalTextLine(line: []const u8, label: []const u8) bool {
    if (!std.mem.startsWith(u8, line, label)) return false;
    const value = line[label.len..];
    return value.len > 0 and text_utils.isTerminalSafe(value);
}

fn canonicalCountLine(line: []const u8, label: []const u8) bool {
    if (!std.mem.startsWith(u8, line, label)) return false;
    const value = line[label.len..];
    if (value.len == 0 or value[0] == '0') return false;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
    return (std.fmt.parseInt(usize, value, 10) catch return false) > 0;
}

/// Builds bounded trusted context from canonical session history. Compacted
/// summaries are never treated as user-authored evidence. Caller owns the
/// returned slice.
pub fn buildCanonicalRootUserContext(
    alloc: Allocator,
    current_request: []const u8,
    history: []const types.HistoryTurn,
) ![]u8 {
    var turns: std.ArrayList([]const u8) = .empty;
    defer turns.deinit(alloc);
    var permission_feedback: std.ArrayList([]const u8) = .empty;
    defer permission_feedback.deinit(alloc);

    var has_compacted_summary = false;
    var compacted_prefix_turns: usize = 0;
    for (history) |turn| {
        switch (turn) {
            .compacted_summary => |entry| {
                has_compacted_summary = true;
                compacted_prefix_turns = @max(
                    compacted_prefix_turns,
                    entry.removed_turn_count,
                );
                try permission_feedback.appendSlice(
                    alloc,
                    entry.permission_feedback,
                );
            },
            .assistant => |entry| {
                try turns.append(alloc, entry.user.text);
                try appendExecutionPermissionFeedback(alloc, &permission_feedback, entry.execution);
            },
            .background_command => |entry| {
                try turns.append(alloc, entry.user.text);
                try appendExecutionPermissionFeedback(alloc, &permission_feedback, entry.execution);
            },
            .interrupted => |entry| {
                try turns.append(alloc, entry.user.text);
                try appendExecutionPermissionFeedback(alloc, &permission_feedback, entry.execution);
            },
        }
    }
    try turns.append(alloc, current_request);

    return buildRootUserContextWithFeedback(
        alloc,
        turns.items,
        permission_feedback.items,
        if (has_compacted_summary) @max(@as(usize, 1), compacted_prefix_turns) else 0,
        !has_compacted_summary,
    );
}

/// Refreshes a queued prompt's bounded trusted context with one exact finished
/// root turn. The existing serialized context preserves a true-first anchor or
/// an explicit unknown prefix. Caller owns the returned slice.
pub fn refreshQueuedRootUserContext(
    alloc: Allocator,
    current_request: []const u8,
    existing_context: []const u8,
    finished_turn: types.HistoryTurn,
) ![]u8 {
    const Finished = struct {
        user: []const u8,
        execution: types.ExecutionMemory,
    };
    const finished: Finished = switch (finished_turn) {
        .assistant => |entry| .{ .user = entry.user.text, .execution = entry.execution },
        .background_command => |entry| .{ .user = entry.user.text, .execution = entry.execution },
        .interrupted => |entry| .{ .user = entry.user.text, .execution = entry.execution },
        .compacted_summary => return alloc.dupe(u8, existing_context),
    };
    const finished_user = finished.user;

    var turns: std.ArrayList([]const u8) = .empty;
    defer turns.deinit(alloc);
    const prior_omitted_root_turns = priorOmittedRootTurns(existing_context);
    const first = lineValue(existing_context, first_root_user_label);
    const has_unknown_prefix = first == null and prior_omitted_root_turns > 0;
    if (first) |first_request| {
        try turns.append(alloc, first_request);
        if (lineValue(existing_context, recent_root_user_label)) |recent| {
            if (!std.mem.eql(u8, recent, first_request) and !std.mem.eql(u8, recent, finished_user)) {
                try turns.append(alloc, recent);
            }
        }
        if (!std.mem.eql(u8, first_request, finished_user)) try turns.append(alloc, finished_user);
    } else {
        if (has_unknown_prefix) {
            if (lineValue(existing_context, recent_root_user_label)) |recent| {
                if (!std.mem.eql(u8, recent, finished_user)) {
                    try turns.append(alloc, recent);
                }
            }
        }
        try turns.append(alloc, finished_user);
    }
    try turns.append(alloc, current_request);

    var permission_feedback: std.ArrayList([]const u8) = .empty;
    defer permission_feedback.deinit(alloc);
    try appendSerializedPermissionFeedback(alloc, &permission_feedback, existing_context);
    try appendExecutionPermissionFeedback(alloc, &permission_feedback, finished.execution);
    return buildRootUserContextWithFeedback(
        alloc,
        turns.items,
        permission_feedback.items,
        prior_omitted_root_turns,
        !has_unknown_prefix,
    );
}

/// Returns a bounded trusted-only projection for a tool execution. Human
/// permission feedback is included, while assistant/tool review evidence is
/// intentionally excluded. Caller owns the returned slice.
pub fn buildToolExecutionRootUserContext(
    alloc: Allocator,
    root_user_context: []const u8,
    trusted_permission_feedback: []const []const u8,
) ![]u8 {
    const new_feedback = try buildTrustedPermissionFeedback(
        alloc,
        trusted_permission_feedback,
        max_same_turn_permission_feedback_bytes,
    );
    defer alloc.free(new_feedback);
    if (new_feedback.len == 0) return alloc.dupe(u8, root_user_context);

    const feedback_start = canonicalFeedbackStart(root_user_context);
    const merged_feedback = try mergePermissionFeedback(
        alloc,
        root_user_context[feedback_start..],
        new_feedback,
    );
    defer alloc.free(merged_feedback);
    const root_requests = root_user_context[0..feedback_start];
    if (root_requests.len + merged_feedback.len <= max_root_user_bytes) {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try out.writer.writeAll(root_requests);
        try out.writer.writeAll(merged_feedback);
        return try out.toOwnedSlice();
    }

    const minimum_request_bytes = current_label.len + 2;
    if (merged_feedback.len + minimum_request_bytes > max_root_user_bytes) {
        return error.RootUserContextOverflow;
    }
    const requests = try rebuildRootRequestsBounded(
        alloc,
        root_requests,
        max_root_user_bytes - merged_feedback.len,
    );
    defer alloc.free(requests);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll(requests);
    try out.writer.writeAll(merged_feedback);
    std.debug.assert(out.written().len <= max_root_user_bytes);
    return try out.toOwnedSlice();
}

fn canonicalFeedbackStart(context: []const u8) usize {
    var start = context.len;
    if (std.mem.find(u8, context, "\n" ++ trusted_permission_feedback_label)) |index| {
        start = @min(start, index + 1);
    }
    if (std.mem.find(u8, context, "\n" ++ omitted_permission_feedback_label)) |index| {
        start = @min(start, index + 1);
    }
    return start;
}

fn mergePermissionFeedback(
    alloc: Allocator,
    existing: []const u8,
    appended: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var omitted: usize = 0;
    for ([_][]const u8{ existing, appended }) |block| {
        var lines = std.mem.splitScalar(u8, block, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (std.mem.startsWith(u8, line, trusted_permission_feedback_label)) {
                try out.writer.writeAll(line);
                try out.writer.writeByte('\n');
                continue;
            }
            if (std.mem.startsWith(u8, line, omitted_permission_feedback_label)) {
                const count = std.fmt.parseInt(
                    usize,
                    line[omitted_permission_feedback_label.len..],
                    10,
                ) catch return error.InvalidRootUserContext;
                omitted +|= count;
                continue;
            }
            return error.InvalidRootUserContext;
        }
    }
    if (omitted > 0) {
        try out.writer.print("{s}{d}\n", .{ omitted_permission_feedback_label, omitted });
    }
    return try out.toOwnedSlice();
}

fn rebuildRootRequestsBounded(
    alloc: Allocator,
    context: []const u8,
    max_bytes: usize,
) ![]u8 {
    const current = lineValue(context, current_label) orelse
        return error.InvalidRootUserContext;
    const first = lineValue(context, first_root_user_label);

    var recent: std.ArrayList([]const u8) = .empty;
    defer recent.deinit(alloc);
    var lines = std.mem.splitScalar(u8, context, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, recent_root_user_label)) {
            try recent.append(alloc, line[recent_root_user_label.len..]);
        }
    }

    var turns: std.ArrayList([]const u8) = .empty;
    defer turns.deinit(alloc);
    if (first) |value| try turns.append(alloc, value);
    var index = recent.items.len;
    while (index > 0) {
        index -= 1;
        try turns.append(alloc, recent.items[index]);
    }
    try turns.append(alloc, current);

    const prior_omitted = if (lineValue(context, omitted_root_user_label)) |value|
        std.fmt.parseInt(usize, value, 10) catch 0
    else
        0;
    return buildRootUserContextBounded(
        alloc,
        turns.items,
        max_bytes,
        prior_omitted,
        first != null,
    );
}

fn buildRootUserContextWithFeedback(
    alloc: Allocator,
    turns: []const []const u8,
    permission_feedback: []const []const u8,
    prior_omitted_root_turns: usize,
    first_root_user_is_proven: bool,
) ![]u8 {
    const feedback = try buildTrustedPermissionFeedback(
        alloc,
        permission_feedback,
        max_persisted_permission_feedback_bytes,
    );
    defer alloc.free(feedback);
    const requests = try buildRootUserContextBounded(
        alloc,
        turns,
        max_root_user_bytes - feedback.len,
        prior_omitted_root_turns,
        first_root_user_is_proven,
    );
    defer alloc.free(requests);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll(requests);
    try out.writer.writeAll(feedback);
    std.debug.assert(out.written().len <= max_root_user_bytes);
    return try out.toOwnedSlice();
}

fn priorOmittedRootTurns(context: []const u8) usize {
    var retained_recent = false;
    var omitted: usize = 0;
    var lines = std.mem.splitScalar(u8, context, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, recent_root_user_label)) {
            if (retained_recent) omitted += 1 else retained_recent = true;
            continue;
        }
        if (std.mem.startsWith(u8, line, omitted_root_user_label)) {
            omitted += std.fmt.parseInt(usize, line[omitted_root_user_label.len..], 10) catch 0;
        }
    }
    return omitted;
}

fn lineValue(context: []const u8, label: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, context, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, label)) return line[label.len..];
    }
    return null;
}

fn appendSerializedPermissionFeedback(
    alloc: Allocator,
    feedback: *std.ArrayList([]const u8),
    context: []const u8,
) !void {
    var lines = std.mem.splitScalar(u8, context, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, trusted_permission_feedback_label)) continue;
        const value = line[trusted_permission_feedback_label.len..];
        if (value.len > 0) try feedback.append(alloc, value);
    }
}

const RequiredAnchorBudgets = struct {
    current: usize,
    first: usize,
    recent: usize,
};

fn requiredAnchorBudgets(
    current_len: usize,
    first_len: ?usize,
    recent_len: ?usize,
    capacity: usize,
) RequiredAnchorBudgets {
    const lengths = [3]?usize{ current_len, first_len, recent_len };
    var budgets = [3]usize{ 0, 0, 0 };
    var present_count: usize = 0;
    for (lengths) |length| {
        if (length != null) present_count += 1;
    }

    const initial_share = capacity / present_count;
    var used: usize = 0;
    for (lengths, 0..) |maybe_length, index| {
        if (maybe_length) |length| {
            budgets[index] = @min(length, initial_share);
            used += budgets[index];
        }
    }

    var remaining = capacity - used;
    while (remaining > 0) {
        var unfinished_count: usize = 0;
        for (lengths, budgets) |maybe_length, budget| {
            if (maybe_length) |length| {
                if (budget < length) unfinished_count += 1;
            }
        }
        if (unfinished_count == 0) break;

        const share = @max(@as(usize, 1), remaining / unfinished_count);
        for (lengths, &budgets) |maybe_length, *budget| {
            const length = maybe_length orelse continue;
            const added = @min(length - budget.*, @min(share, remaining));
            budget.* += added;
            remaining -= added;
            if (remaining == 0) break;
        }
    }

    return .{
        .current = budgets[0],
        .first = budgets[1],
        .recent = budgets[2],
    };
}

fn buildRootUserContextBounded(
    alloc: Allocator,
    turns: []const []const u8,
    max_bytes: usize,
    prior_omitted_root_turns: usize,
    first_root_user_is_proven: bool,
) ![]u8 {
    const latest_raw = if (turns.len > 0) turns[turns.len - 1] else "";
    const latest = try encodeText(alloc, latest_raw);
    defer alloc.free(latest);

    const first = if (first_root_user_is_proven and turns.len > 1)
        try encodeText(alloc, turns[0])
    else
        null;
    defer if (first) |text| alloc.free(text);

    const first_turn_count: usize = if (first != null) 1 else 0;
    const recent_total = turns.len -| (1 + first_turn_count);
    const has_recent = recent_total > 0;
    const newest_recent = if (has_recent)
        try encodeText(alloc, turns[turns.len - 2])
    else
        null;
    defer if (newest_recent) |text| alloc.free(text);

    const omitted_after_required = recent_total - @intFromBool(has_recent) +
        prior_omitted_root_turns;
    const anchor_overhead = current_label.len + 1 +
        (if (first != null) first_root_user_label.len + 1 else 0) +
        (if (newest_recent != null) recent_root_user_label.len + 1 else 0);
    const recent_marker_reserve = if (omitted_after_required > 0) count_marker_reserve else 0;
    const anchor_content_budget = max_bytes - anchor_overhead - recent_marker_reserve;
    const budgets = requiredAnchorBudgets(
        latest.len,
        if (first) |text| text.len else null,
        if (newest_recent) |text| text.len else null,
        anchor_content_budget,
    );

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll(current_label);
    try writeHeadTail(&out.writer, latest, budgets.current);
    try out.writer.writeByte('\n');
    if (first) |first_text| {
        try out.writer.writeAll(first_root_user_label);
        try writeHeadTail(&out.writer, first_text, budgets.first);
        try out.writer.writeByte('\n');
    }
    if (newest_recent) |recent_text| {
        try out.writer.writeAll(recent_root_user_label);
        try writeHeadTail(&out.writer, recent_text, budgets.recent);
        try out.writer.writeByte('\n');
    }

    var selected_recent: usize = @intFromBool(newest_recent != null);
    var history_index = if (turns.len > 1) turns.len - 2 else 0;
    while (history_index > first_turn_count) {
        history_index -= 1;
        const older_turns_remaining = history_index - first_turn_count;
        const omission_reserve = if (older_turns_remaining > 0 or prior_omitted_root_turns > 0)
            count_marker_reserve
        else
            0;
        const used = out.written().len;
        const entry_overhead = recent_root_user_label.len + 1;
        if (used + entry_overhead + content_omission_marker.len + omission_reserve > max_bytes) break;

        const encoded = try encodeText(alloc, turns[history_index]);
        defer alloc.free(encoded);
        const content_budget = max_bytes - used - entry_overhead - omission_reserve;
        try out.writer.writeAll(recent_root_user_label);
        try writeHeadTail(&out.writer, encoded, content_budget);
        try out.writer.writeByte('\n');
        selected_recent += 1;
    }

    const omitted_recent = recent_total - selected_recent + prior_omitted_root_turns;
    if (omitted_recent > 0) {
        try out.writer.print("{s}{d}\n", .{ omitted_root_user_label, omitted_recent });
    }
    std.debug.assert(out.written().len <= max_bytes);
    return try out.toOwnedSlice();
}

fn appendExecutionPermissionFeedback(
    alloc: Allocator,
    feedback: *std.ArrayList([]const u8),
    execution: types.ExecutionMemory,
) !void {
    for (execution.tool_steps) |step| {
        for (step.tool_results) |result| {
            for (result.permission_feedback) |item| {
                if (item.len > 0) try feedback.append(alloc, item);
            }
        }
    }
}

fn buildTrustedPermissionFeedback(
    alloc: Allocator,
    feedback: []const []const u8,
    max_bytes: usize,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var selected: usize = 0;
    var index = feedback.len;
    while (index > 0) {
        index -= 1;
        const omission_reserve = if (index > 0) count_marker_reserve else 0;
        const encoded = try encodeText(alloc, feedback[index]);
        defer alloc.free(encoded);
        const used = out.written().len;
        const overhead = trusted_permission_feedback_label.len + 1;
        if (used + overhead + content_omission_marker.len + omission_reserve > max_bytes) break;
        try out.writer.writeAll(trusted_permission_feedback_label);
        try writeHeadTail(&out.writer, encoded, max_bytes - used - overhead - omission_reserve);
        try out.writer.writeByte('\n');
        selected += 1;
    }
    const omitted = feedback.len - selected;
    if (omitted > 0) {
        try out.writer.print("{s}{d}\n", .{ omitted_permission_feedback_label, omitted });
    }
    std.debug.assert(out.written().len <= max_bytes);
    return try out.toOwnedSlice();
}

fn encodeText(alloc: Allocator, raw: []const u8) ![]u8 {
    const masked = try text_utils.maskSecrets(alloc, raw);
    defer if (masked.ptr != raw.ptr) alloc.free(masked);
    const encoded = try text_utils.encodeTerminalSafe(alloc, masked, std.math.maxInt(usize));
    return encoded.bytes;
}

fn writeHeadTail(writer: *std.Io.Writer, text: []const u8, max_content_bytes: usize) !void {
    try text_utils.writeHeadTailBounded(
        writer,
        text,
        max_content_bytes,
        content_omission_marker,
        .up,
    );
}

test "root user context keeps first latest and newest recent turns with visible omission" {
    const turns = [_][]const u8{
        "first-root-authorization",
        "oldest-middle " ++ ("a" ** 280),
        "older-middle " ++ ("b" ** 280),
        "middle-three " ++ ("d" ** 280),
        "middle-four " ++ ("e" ** 280),
        "middle-five " ++ ("f" ** 280),
        "middle-six " ++ ("g" ** 280),
        "recent-middle " ++ ("c" ** 280),
        "newest-recent-root-request",
        "latest-root-request",
    };
    const context = try buildRootUserContextBounded(std.testing.allocator, &turns, max_root_user_bytes, 0, true);
    defer std.testing.allocator.free(context);

    try std.testing.expect(context.len <= max_root_user_bytes);
    try std.testing.expect(std.mem.find(u8, context, "current_request: latest-root-request") != null);
    try std.testing.expect(std.mem.find(u8, context, "first_root_user_request: first-root-authorization") != null);
    try std.testing.expect(std.mem.find(u8, context, "recent_root_user_request: newest-recent-root-request") != null);
    try std.testing.expect(std.mem.find(u8, context, "omitted_proven_root_user_turns:") != null);
    try std.testing.expect(std.mem.find(u8, context, "oldest-middle") == null);
}

test "root user context reserves capacity for every required oversized anchor" {
    const turns = [_][]const u8{
        "first-required-marker " ++ ("a" ** 4096),
        "older-middle-one-marker " ++ ("b" ** 4096),
        "older-middle-two-marker " ++ ("c" ** 4096),
        "older-middle-three-marker " ++ ("d" ** 4096),
        "newest-recent-required-marker " ++ ("e" ** 4096),
        "current-required-marker " ++ ("f" ** 4096),
    };
    const context = try buildRootUserContextBounded(
        std.testing.allocator,
        &turns,
        max_root_user_bytes,
        0,
        true,
    );
    defer std.testing.allocator.free(context);

    try std.testing.expect(context.len <= max_root_user_bytes);
    try std.testing.expect(isCanonicalRootUserContext(context));
    try std.testing.expect(std.mem.find(u8, context, "current-required-marker") != null);
    try std.testing.expect(std.mem.find(u8, context, "first-required-marker") != null);
    try std.testing.expect(std.mem.find(u8, context, "newest-recent-required-marker") != null);
    try std.testing.expect(std.mem.find(u8, context, "older-middle-one-marker") == null);
    try std.testing.expect(std.mem.find(u8, context, "older-middle-two-marker") == null);
    try std.testing.expect(std.mem.find(u8, context, "older-middle-three-marker") == null);
    try std.testing.expectEqualStrings(
        "3",
        lineValue(context, omitted_root_user_label).?,
    );
}

test "root user context redistributes unused required anchor capacity" {
    const turns = [_][]const u8{
        "first-required-marker " ++ ("a" ** 4096),
        "newest-recent-required-marker " ++ ("b" ** 4096),
        "current",
    };
    const context = try buildRootUserContextBounded(
        std.testing.allocator,
        &turns,
        max_root_user_bytes,
        0,
        true,
    );
    defer std.testing.allocator.free(context);

    try std.testing.expectEqual(max_root_user_bytes, context.len);
    try std.testing.expect(isCanonicalRootUserContext(context));
    try std.testing.expectEqualStrings("current", lineValue(context, current_label).?);
    try std.testing.expect(std.mem.find(u8, context, "first-required-marker") != null);
    try std.testing.expect(std.mem.find(u8, context, "newest-recent-required-marker") != null);
    try std.testing.expect(lineValue(context, omitted_root_user_label) == null);
}

test "compacted prefix remains unknown across queued context refresh" {
    var compacted_feedback = [_][]u8{
        @constCast("Never modify files outside the workspace."),
    };
    const history = [_]types.HistoryTurn{
        .{ .compacted_summary = .{
            .summary = @constCast("untrusted compacted summary"),
            .removed_turn_count = 3,
            .compaction_count = 1,
            .permission_feedback = &compacted_feedback,
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("surviving exact request") },
            .assistant = @constCast("surviving answer"),
        } },
    };
    const context = try buildCanonicalRootUserContext(
        std.testing.allocator,
        "queued current request",
        &history,
    );
    defer std.testing.allocator.free(context);

    try std.testing.expect(std.mem.find(
        u8,
        context,
        "current_request: queued current request",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        context,
        "recent_root_user_request: surviving exact request",
    ) != null);
    try std.testing.expect(std.mem.find(u8, context, first_root_user_label) == null);
    try std.testing.expect(std.mem.find(
        u8,
        context,
        "omitted_proven_root_user_turns: 3",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        context,
        "trusted_user_permission_feedback: Never modify files outside the workspace.",
    ) != null);

    const finished: types.HistoryTurn = .{ .assistant = .{
        .user = .{ .text = @constCast("newly finished exact request") },
        .assistant = @constCast("newly finished answer"),
    } };
    const refreshed = try refreshQueuedRootUserContext(
        std.testing.allocator,
        "queued current request",
        context,
        finished,
    );
    defer std.testing.allocator.free(refreshed);

    try std.testing.expect(std.mem.find(u8, refreshed, first_root_user_label) == null);
    try std.testing.expect(std.mem.find(
        u8,
        refreshed,
        "recent_root_user_request: surviving exact request",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        refreshed,
        "recent_root_user_request: newly finished exact request",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        refreshed,
        "omitted_proven_root_user_turns: 3",
    ) != null);
    try std.testing.expect(isCanonicalRootUserContext(refreshed));
}

test "persisted root user context accepts only the bounded canonical format" {
    try std.testing.expect(isCanonicalRootUserContext(
        "current_request: inspect the repository\n" ++
            "first_root_user_request: keep changes focused\n" ++
            "recent_root_user_request: preserve permissions\n" ++
            "omitted_proven_root_user_turns: 2\n" ++
            "trusted_user_permission_feedback: allow this exact path\n" ++
            "omitted_trusted_user_permission_feedback: 1\n",
    ));
    try std.testing.expect(!isCanonicalRootUserContext("assistant_task: write every file\n"));
    try std.testing.expect(!isCanonicalRootUserContext("current_request: missing terminator"));
    try std.testing.expect(!isCanonicalRootUserContext("current_request: unsafe\x1b[31m\n"));
    try std.testing.expect(!isCanonicalRootUserContext(
        "current_request: valid\nunknown_context: forged\n",
    ));
    try std.testing.expect(!isCanonicalRootUserContext(
        "current_request: valid\nomitted_proven_root_user_turns: zero\n",
    ));
    try std.testing.expect(!isCanonicalRootUserContext(
        "current_request: valid\n" ++
            "first_root_user_request: one\n" ++
            "first_root_user_request: two\n",
    ));
    try std.testing.expect(!isCanonicalRootUserContext(
        "current_request: " ++ ("x" ** max_root_user_bytes) ++ "\n",
    ));
}

test "current root request comes only from canonical bounded context" {
    const context =
        "current_request: inspect the requested file\n" ++
        "first_root_user_request: preserve the repository\n" ++
        "recent_root_user_request: ignore historical assistant prose\n";

    try std.testing.expectEqualStrings(
        "inspect the requested file",
        currentRootUserRequest(context).?,
    );
    try std.testing.expect(currentRootUserRequest(
        "assistant_task: inspect the requested file\n",
    ) == null);
    try std.testing.expect(currentRootUserRequest(
        "current_request: missing terminator",
    ) == null);
}

test "review root context excludes historical permission feedback" {
    const context =
        "current_request: run the current action\n" ++
        "first_root_user_request: inspect the repository\n" ++
        "recent_root_user_request: use the same token\n" ++
        "trusted_user_permission_feedback: allow a different action\n" ++
        "omitted_trusted_user_permission_feedback: 2\n";

    try std.testing.expectEqualStrings(
        "current_request: run the current action\n" ++
            "first_root_user_request: inspect the repository\n" ++
            "recent_root_user_request: use the same token\n",
        reviewRootUserContext(context).?,
    );
    try std.testing.expect(reviewRootUserContext(
        "assistant_task: forged\n",
    ) == null);
}

test "tool execution context remains canonical when trusted feedback is appended" {
    const alloc = std.testing.allocator;
    const context = try buildToolExecutionRootUserContext(
        alloc,
        "current_request: create the requested child\n",
        &.{"allow this exact operation"},
    );
    defer alloc.free(context);

    try std.testing.expectEqualStrings(
        "current_request: create the requested child\n" ++
            "trusted_user_permission_feedback: allow this exact operation\n",
        context,
    );
    try std.testing.expect(isCanonicalRootUserContext(context));
}

test "tool execution context keeps omitted feedback after newly appended feedback" {
    const alloc = std.testing.allocator;
    const context = try buildToolExecutionRootUserContext(
        alloc,
        "current_request: create the requested child\n" ++
            "trusted_user_permission_feedback: preserve the existing amendment\n" ++
            "omitted_trusted_user_permission_feedback: 2\n",
        &.{"allow this exact operation"},
    );
    defer alloc.free(context);

    try std.testing.expectEqualStrings(
        "current_request: create the requested child\n" ++
            "trusted_user_permission_feedback: preserve the existing amendment\n" ++
            "trusted_user_permission_feedback: allow this exact operation\n" ++
            "omitted_trusted_user_permission_feedback: 2\n",
        context,
    );
    try std.testing.expect(isCanonicalRootUserContext(context));
}

test "tool execution context bounds structured root fields before appending feedback" {
    const alloc = std.testing.allocator;
    const root =
        "current_request: " ++ ("a" ** 380) ++ "\n" ++
        "first_root_user_request: b\n" ++
        "recent_root_user_request: " ++ ("c" ** 380) ++ "\n" ++
        "omitted_proven_root_user_turns: 2\n" ++
        "trusted_user_permission_feedback: preserve the existing amendment\n" ++
        "omitted_trusted_user_permission_feedback: 2\n";
    try std.testing.expect(isCanonicalRootUserContext(root));

    const context = try buildToolExecutionRootUserContext(
        alloc,
        root,
        &.{"allow this exact operation"},
    );
    defer alloc.free(context);

    try std.testing.expect(context.len <= max_root_user_bytes);
    try std.testing.expect(isCanonicalRootUserContext(context));
    try std.testing.expect(std.mem.find(u8, context, first_root_user_label) != null);
    try std.testing.expect(std.mem.find(u8, context, recent_root_user_label) != null);
    try std.testing.expect(std.mem.find(u8, context, "preserve the existing amendment") != null);
    try std.testing.expect(std.mem.find(u8, context, trusted_permission_feedback_label) != null);
    try std.testing.expect(std.mem.find(u8, context, omitted_permission_feedback_label) != null);
}
