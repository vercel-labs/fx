//! fx's own questions (`ask_user_question`) as an ACP form: the params of an
//! `elicitation/create` request, and the answers in the client's response.
//!
//! Each question becomes two fields, as the TUI offers it: a single choice of
//! the model's options plus "Other", and an optional text field for the
//! answer the user types when they pick Other. An answer is the chosen
//! option's label, or that typed text.

const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");
const question_prompt = @import("../core/agent/question_prompt.zig");
const types = @import("../core/shared/types.zig");

const Allocator = std.mem.Allocator;

/// The choice that asks for a typed answer: the TUI's label, unless a model
/// option already uses it.
fn otherChoice(entry: types.QuestionBatchEntry) []const u8 {
    for (entry.options) |option| {
        if (std.mem.eql(u8, option.label, question_prompt.freeform_option_label)) return "Other (type your answer)";
    }
    return question_prompt.freeform_option_label;
}

fn writeFieldName(w: *std.Io.Writer, index: usize, other: bool) !void {
    try w.print("\"question_{d}{s}\"", .{ index + 1, if (other) "_other" else "" });
}

/// Writes the params of an `elicitation/create` request that asks `entries`
/// in session `session_id`. The caller owns the result.
pub fn createParams(alloc: Allocator, session_id: []const u8, entries: []const types.QuestionBatchEntry) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"sessionId\":");
    try jsonrpc.writeJsonStr(session_id, w);
    try w.writeAll(",\"mode\":\"form\",\"message\":");
    if (entries.len == 1) {
        try jsonrpc.writeJsonStr("fx has a question for you.", w);
    } else {
        try w.print("\"fx has {d} questions for you.\"", .{entries.len});
    }
    try w.writeAll(",\"requestedSchema\":{\"type\":\"object\",\"properties\":{");
    for (entries, 0..) |entry, index| {
        if (index > 0) try w.writeByte(',');
        try writeFieldName(w, index, false);
        try w.writeAll(":{\"type\":\"string\",\"title\":");
        try jsonrpc.writeJsonStr(entry.question, w);
        if (hasDescriptions(entry)) {
            var description: std.Io.Writer.Allocating = .init(alloc);
            defer description.deinit();
            for (entry.options) |option| {
                const text = option.description orelse continue;
                if (description.written().len > 0) try description.writer.writeByte('\n');
                try description.writer.print("{s}: {s}", .{ option.label, text });
            }
            try w.writeAll(",\"description\":");
            try jsonrpc.writeJsonStr(description.written(), w);
        }
        try w.writeAll(",\"oneOf\":[");
        for (entry.options) |option| {
            try w.writeAll("{\"const\":");
            try jsonrpc.writeJsonStr(option.label, w);
            try w.writeAll(",\"title\":");
            try jsonrpc.writeJsonStr(option.label, w);
            try w.writeAll("},");
        }
        try w.writeAll("{\"const\":");
        try jsonrpc.writeJsonStr(otherChoice(entry), w);
        try w.writeAll(",\"title\":");
        try jsonrpc.writeJsonStr(otherChoice(entry), w);
        try w.writeAll("}]},");
        try writeFieldName(w, index, true);
        try w.writeAll(":{\"type\":\"string\",\"title\":\"Other answer\",\"description\":");
        try jsonrpc.writeJsonStr("If you pick Other, type your answer here.", w);
        try w.writeByte('}');
    }
    try w.writeAll("},\"required\":[");
    for (entries, 0..) |_, index| {
        if (index > 0) try w.writeByte(',');
        try writeFieldName(w, index, false);
    }
    try w.writeAll("]}}");
    return out.toOwnedSlice();
}

fn hasDescriptions(entry: types.QuestionBatchEntry) bool {
    for (entry.options) |option| if (option.description != null) return true;
    return false;
}

pub const AnswerError = Allocator.Error || error{InvalidQuestionAnswer};

/// Reads the answers in an `elicitation/create` result: one per entry, owned
/// by `alloc`, or null when the user declined or cancelled the form. A result
/// that answers a question with no known choice, or picks Other with no
/// text, is invalid.
pub fn answersFromResult(alloc: Allocator, entries: []const types.QuestionBatchEntry, result_json: []const u8) AnswerError!?[][]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, result_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidQuestionAnswer,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidQuestionAnswer;
    const action = parsed.value.object.get("action") orelse return error.InvalidQuestionAnswer;
    if (action != .string) return error.InvalidQuestionAnswer;
    if (std.mem.eql(u8, action.string, "decline") or std.mem.eql(u8, action.string, "cancel")) return null;
    if (!std.mem.eql(u8, action.string, "accept")) return error.InvalidQuestionAnswer;
    const content = parsed.value.object.get("content") orelse return error.InvalidQuestionAnswer;
    if (content != .object) return error.InvalidQuestionAnswer;

    const answers = try alloc.alloc([]u8, entries.len);
    var filled: usize = 0;
    errdefer {
        for (answers[0..filled]) |answer| alloc.free(answer);
        alloc.free(answers);
    }
    var name_buffer: [32]u8 = undefined;
    for (entries, 0..) |entry, index| {
        const choice_name = std.mem.print(&name_buffer, "question_{d}", .{index + 1}) catch unreachable;
        const choice = content.object.get(choice_name) orelse return error.InvalidQuestionAnswer;
        if (choice != .string) return error.InvalidQuestionAnswer;
        const answer: []const u8 = answer: {
            for (entry.options) |option| {
                if (std.mem.eql(u8, option.label, choice.string)) break :answer option.label;
            }
            if (!std.mem.eql(u8, choice.string, otherChoice(entry))) return error.InvalidQuestionAnswer;
            const other_name = std.mem.print(&name_buffer, "question_{d}_other", .{index + 1}) catch unreachable;
            const typed = content.object.get(other_name) orelse return error.InvalidQuestionAnswer;
            if (typed != .string) return error.InvalidQuestionAnswer;
            const trimmed = std.mem.trim(u8, typed.string, " \t\r\n");
            if (trimmed.len == 0) return error.InvalidQuestionAnswer;
            break :answer trimmed;
        };
        answers[index] = try alloc.dupe(u8, answer);
        filled += 1;
    }
    return answers;
}

fn freeAnswers(alloc: Allocator, answers: []const []u8) void {
    for (answers) |answer| alloc.free(answer);
    alloc.free(answers);
}

const test_entries = [_]types.QuestionBatchEntry{
    .{ .question = "Which database?", .options = &.{
        .{ .label = "Staging", .description = "The shared one" },
        .{ .label = "Local" },
    } },
    .{ .question = "Run the tests?", .options = &.{ .{ .label = "Yes" }, .{ .label = "No" } } },
};

test "fx's questions become one choice and one Other text field each" {
    const alloc = std.testing.allocator;
    const params = try createParams(alloc, "sess_1", &test_entries);
    defer alloc.free(params);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, params, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("sess_1", root.get("sessionId").?.string);
    try std.testing.expectEqualStrings("form", root.get("mode").?.string);
    try std.testing.expectEqualStrings("fx has 2 questions for you.", root.get("message").?.string);
    const schema = root.get("requestedSchema").?.object;
    const properties = schema.get("properties").?.object;
    try std.testing.expectEqual(@as(usize, 4), properties.count());
    const first = properties.get("question_1").?.object;
    try std.testing.expectEqualStrings("Which database?", first.get("title").?.string);
    try std.testing.expectEqualStrings("Staging: The shared one", first.get("description").?.string);
    const choices = first.get("oneOf").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), choices.len);
    try std.testing.expectEqualStrings("Local", choices[1].object.get("const").?.string);
    try std.testing.expectEqualStrings("Other", choices[2].object.get("const").?.string);
    try std.testing.expect(properties.get("question_2").?.object.get("description") == null);
    try std.testing.expectEqualStrings("string", properties.get("question_2_other").?.object.get("type").?.string);
    const required = schema.get("required").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), required.len);
    try std.testing.expectEqualStrings("question_2", required[1].string);
}

test "an answer is the chosen label, or the typed text when the user picks Other" {
    const alloc = std.testing.allocator;
    const answers = (try answersFromResult(alloc, &test_entries,
        \\{"action":"accept","content":{"question_1":"Other","question_1_other":"  The new one ","question_2":"Yes","question_2_other":"ignored"}}
    )).?;
    defer freeAnswers(alloc, answers);
    try std.testing.expectEqualStrings("The new one", answers[0]);
    try std.testing.expectEqualStrings("Yes", answers[1]);
}

test "a declined or cancelled form answers no question" {
    const alloc = std.testing.allocator;
    try std.testing.expect(try answersFromResult(alloc, &test_entries, "{\"action\":\"decline\"}") == null);
    try std.testing.expect(try answersFromResult(alloc, &test_entries, "{\"action\":\"cancel\"}") == null);
}

test "an unknown choice, a missing answer, or Other with no text is invalid" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{
        "{\"action\":\"accept\",\"content\":{\"question_1\":\"Prod\",\"question_2\":\"Yes\"}}",
        "{\"action\":\"accept\",\"content\":{\"question_1\":\"Local\"}}",
        "{\"action\":\"accept\",\"content\":{\"question_1\":\"Other\",\"question_1_other\":\"  \",\"question_2\":\"Yes\"}}",
        "{\"action\":\"accept\"}",
        "{\"action\":\"maybe\"}",
        "[]",
    }) |result| {
        try std.testing.expectError(error.InvalidQuestionAnswer, answersFromResult(alloc, &test_entries, result));
    }
}

test "the Other choice keeps clear of a model option named Other" {
    const alloc = std.testing.allocator;
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Pick one", .options = &.{ .{ .label = "Other" }, .{ .label = "None" } } },
    };
    const params = try createParams(alloc, "s", &entries);
    defer alloc.free(params);
    try std.testing.expect(std.mem.find(u8, params, "\"const\":\"Other (type your answer)\"") != null);
    const picked = (try answersFromResult(alloc, &entries, "{\"action\":\"accept\",\"content\":{\"question_1\":\"Other\"}}")).?;
    defer freeAnswers(alloc, picked);
    try std.testing.expectEqualStrings("Other", picked[0]);
}
