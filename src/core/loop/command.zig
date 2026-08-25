const std = @import("std");
const interval = @import("interval.zig");
const types = @import("types.zig");

pub const default_interval_secs: u64 = 10 * 60;

pub const Create = struct {
    interval_secs: u64,
    prompt: []const u8,
    recurring: bool = true,
};

pub const Action = union(enum) {
    list,
    stop: []const u8,
    create: Create,
};

pub const ParseError = error{
    InvalidInterval,
    MissingPrompt,
    MissingTaskId,
    PromptTooLong,
};

/// Parses the payload after `/loop`.
///
/// Supported forms:
/// - empty or `list`: list tasks
/// - `stop <id>`: cancel one task
/// - `<interval> <prompt>`: recurring task
/// - `once <interval> <prompt>`: one-shot task
/// - `<prompt>`: recurring task at the default ten-minute interval
pub fn parse(payload: []const u8) ParseError!Action {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "list")) return .list;

    if (consume_keyword(trimmed, "stop")) |rest| {
        if (rest.len == 0) return error.MissingTaskId;
        return .{ .stop = rest };
    }

    var recurring = true;
    const create_payload = if (consume_keyword(trimmed, "once")) |rest| blk: {
        recurring = false;
        break :blk rest;
    } else trimmed;

    const split = split_first_token(create_payload);
    if (split.token.len > 0 and std.ascii.isDigit(split.token[0]) and
        !interval.is_interval_token(split.token))
    {
        return error.InvalidInterval;
    }
    const parsed_interval = if (interval.is_interval_token(split.token))
        interval.parse_interval(split.token) catch return error.InvalidInterval
    else
        default_interval_secs;
    const prompt = if (interval.is_interval_token(split.token)) split.rest else create_payload;
    if (prompt.len == 0) return error.MissingPrompt;
    if (prompt.len > types.max_prompt_bytes) return error.PromptTooLong;

    return .{ .create = .{
        .interval_secs = parsed_interval,
        .prompt = prompt,
        .recurring = recurring,
    } };
}

const TokenSplit = struct {
    token: []const u8,
    rest: []const u8,
};

fn split_first_token(text: []const u8) TokenSplit {
    const end = std.mem.indexOfAny(u8, text, " \t\r\n") orelse text.len;
    return .{
        .token = text[0..end],
        .rest = std.mem.trimStart(u8, text[end..], " \t\r\n"),
    };
}

fn consume_keyword(text: []const u8, keyword: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, text, keyword)) return null;
    if (text.len == keyword.len) return "";
    if (!std.ascii.isWhitespace(text[keyword.len])) return null;
    return std.mem.trim(u8, text[keyword.len..], " \t\r\n");
}

test "empty and list payloads list tasks" {
    try std.testing.expectEqual(std.meta.Tag(Action).list, std.meta.activeTag(try parse("")));
    try std.testing.expectEqual(std.meta.Tag(Action).list, std.meta.activeTag(try parse(" list ")));
}

test "stop requires and returns task id" {
    const action = try parse("stop abc123");
    try std.testing.expectEqualStrings("abc123", action.stop);
    try std.testing.expectError(error.MissingTaskId, parse("stop"));
}

test "explicit interval creates recurring task" {
    const action = try parse("5m check the deploy");
    try std.testing.expectEqual(@as(u64, 300), action.create.interval_secs);
    try std.testing.expectEqualStrings("check the deploy", action.create.prompt);
    try std.testing.expect(action.create.recurring);
}

test "prompt-only form uses default interval" {
    const action = try parse("check the deploy");
    try std.testing.expectEqual(default_interval_secs, action.create.interval_secs);
    try std.testing.expectEqualStrings("check the deploy", action.create.prompt);
}

test "once creates a one-shot task" {
    const action = try parse("once 2h remind me");
    try std.testing.expectEqual(@as(u64, 7200), action.create.interval_secs);
    try std.testing.expectEqualStrings("remind me", action.create.prompt);
    try std.testing.expect(!action.create.recurring);
}

test "explicit interval requires prompt" {
    try std.testing.expectError(error.MissingPrompt, parse("5m"));
    try std.testing.expectError(error.MissingPrompt, parse("once 5m"));
}

test "malformed numeric interval is rejected" {
    try std.testing.expectError(error.InvalidInterval, parse("5x check deploy"));
    try std.testing.expectError(error.InvalidInterval, parse("123 check deploy"));
}

test "keyword prefixes remain ordinary prompts" {
    const action = try parse("stopping should not cancel");
    try std.testing.expectEqualStrings("stopping should not cancel", action.create.prompt);
}
