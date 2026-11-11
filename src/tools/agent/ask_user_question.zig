const std = @import("std");
const observation = @import("../../core/agent/runtime/observation.zig");
const question_answer = @import("../../core/agent/question_answer.zig");
const question_prompt = @import("../../core/agent/question_prompt.zig");
const core_types = @import("../../core/shared/types.zig");
const testing_allocator = @import("../../core/shared/testing_allocator.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

const whitespace = " \t\r\n";
const legacy_permission_request_sentinel =
    "(ask_user_question: permission_request_id is no longer supported; use the safety review advice to choose a different action)";

pub const cancel_sentinel = "(user cancelled the question)";
pub const not_available_sentinel = "(ask_user_question is only available in the interactive shell; ask the user freeform instead)";

const invalid_args_sentinel = "(ask_user_question: invalid arguments; provide {questions})";
const question_count_sentinel = std.fmt.comptimePrint(
    "(ask_user_question: provide 1 to {d} questions)",
    .{question_answer.max_questions},
);

const QuestionBatchParseError = Allocator.Error || error{
    InvalidArguments,
    MissingQuestions,
    QuestionsNotArray,
    QuestionCount,
    QuestionNotObject,
    MissingQuestionText,
    QuestionTextNotString,
    EmptyQuestionText,
    MissingOptions,
    OptionsNotArray,
    OptionCount,
    OptionNotObject,
    MissingOptionLabel,
    OptionLabelNotString,
    EmptyOptionLabel,
    DuplicateOptionLabel,
};

/// Where a parse error sits in the batch, counted from 1; 0 is unset.
const ParsePosition = struct {
    question: usize = 0,
    option: usize = 0,
};

pub const Input = struct {
    args_json: []u8,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.args_json);
        self.* = .{ .args_json = &.{} };
    }
};

pub const Requester = struct {
    observer: ?*observation.Observer = null,
    call_id: ?[]const u8 = null,
    ctx: ?*anyopaque,
    response_alloc: Allocator,
    request: tool_dispatch.AskQuestionBatchFn,
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .args_json = try ctx.allocator.dupe(u8, args_json) };
    errdefer input.deinit(ctx.allocator);

    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn validate(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!?[]u8 {
    const input = erased.as(Input);
    if (try hasLegacyPermissionRequestId(ctx.allocator, input.args_json)) {
        return try ctx.allocator.dupe(u8, legacy_permission_request_sentinel);
    }
    return null;
}

fn hasLegacyPermissionRequestId(
    alloc: Allocator,
    args_json: []const u8,
) Allocator.Error!bool {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, args_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer parsed.deinit();
    return parsed.value == .object and
        parsed.value.object.get("permission_request_id") != null;
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const request = ctx.ask_question_batch orelse {
        return .{ .success = try ctx.allocator.dupe(u8, not_available_sentinel) };
    };
    const input = erased.as(Input);
    const output = executeWithRequester(ctx.allocator, input.args_json, .{
        .observer = ctx.observer,
        .call_id = ctx.tool_call_id,
        .ctx = ctx.ask_question_ctx,
        .response_alloc = ctx.allocator,
        .request = request,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = try ctx.allocator.print("ask_user_question failed: {s}", .{@errorName(err)}) },
    };
    return .{ .success = output };
}

pub fn executeWithRequester(result_alloc: Allocator, args_json: []const u8, requester: Requester) ![]u8 {
    var parse_arena_state = std.heap.ArenaAllocator.init(result_alloc);
    defer parse_arena_state.deinit();
    const parse_arena = parse_arena_state.allocator();

    var position: ParsePosition = .{};
    const entries = parseQuestionBatch(parse_arena, args_json, &position) catch |err| return invalidArgsBody(result_alloc, err, position);
    const wait = if (requester.observer) |observer| observer.beginWait(.{ .kind = .question, .call_id = requester.call_id, .questions = entries }) else null;
    const answers_opt = requester.request(requester.ctx, requester.response_alloc, entries) catch |err| {
        if (wait) |value| value.end(.failed, &.{}, @errorName(err));
        return err;
    };
    if (wait) |value| value.end(if (answers_opt == null) .cancelled else .accepted, answers_opt orelse &.{}, null);
    if (answers_opt) |answers| {
        defer freeAnswers(requester.response_alloc, answers);
        return question_answer.encodeJson(result_alloc, entries, answers);
    }
    return result_alloc.dupe(u8, cancel_sentinel);
}

test "question observer records answers cancellation and failure at the real requester" {
    const Fixture = struct {
        cancelled: bool = false,
        failure: bool = false,
        fn request(raw: ?*anyopaque, alloc: Allocator, _: []const core_types.QuestionBatchEntry) Allocator.Error!?[][]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (self.failure) return error.OutOfMemory;
            if (self.cancelled) return null;
            const answers = try alloc.alloc([]u8, 1);
            errdefer alloc.free(answers);
            answers[0] = try alloc.dupe(u8, "Yes");
            return answers;
        }
    };
    var fixture: Fixture = .{};
    var capture: @import("../../core/agent/runtime/observation_testing.zig").Capture = .{ .expected_call = "question-call" };
    var observer = capture.observer();
    for ([_]bool{ false, true }) |cancelled| {
        fixture.cancelled = cancelled;
        const output = try executeWithRequester(std.testing.allocator, "{\"questions\":[{\"question\":\"Continue?\",\"options\":[{\"label\":\"Yes\"},{\"label\":\"No\"}]}]}", .{
            .ctx = &fixture,
            .response_alloc = std.testing.allocator,
            .request = Fixture.request,
            .observer = &observer,
            .call_id = "question-call",
        });
        defer std.testing.allocator.free(output);
        try std.testing.expect(if (cancelled) std.mem.eql(u8, output, cancel_sentinel) else std.mem.find(u8, output, "Yes") != null);
    }
    fixture.failure = true;
    try std.testing.expectError(error.OutOfMemory, executeWithRequester(std.testing.allocator, "{\"questions\":[{\"question\":\"Continue?\",\"options\":[{\"label\":\"Yes\"},{\"label\":\"No\"}]}]}", .{
        .ctx = &fixture,
        .response_alloc = std.testing.allocator,
        .request = Fixture.request,
        .observer = &observer,
        .call_id = "question-call",
    }));
    try std.testing.expectEqual(@as(usize, 3), capture.count(.wait_start));
    try std.testing.expectEqual(capture.count(.wait_start), capture.count(.wait_end));
    try std.testing.expect(!capture.invalid);
}

/// Parses the batch into `arena`. On a question or option error, `position`
/// names the failing one.
fn parseQuestionBatch(
    arena: Allocator,
    args_json: []const u8,
    position: *ParsePosition,
) QuestionBatchParseError![]const core_types.QuestionBatchEntry {
    var parsed = std.json.parseFromSlice(std.json.Value, arena, args_json, .{}) catch {
        return error.InvalidArguments;
    };
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidArguments;
    const args = parsed.value.object;

    var questions_value = args.get("questions") orelse return error.MissingQuestions;
    // Some models send the array as JSON text. It names the same batch.
    tool_args.normalizeCompositeArrayValue(arena, &questions_value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.QuestionsNotArray,
    };
    if (questions_value != .array) return error.QuestionsNotArray;

    const questions_arr = questions_value.array;
    if (questions_arr.items.len < 1 or questions_arr.items.len > question_answer.max_questions) return error.QuestionCount;

    var entries_buf: std.ArrayList(core_types.QuestionBatchEntry) = .empty;
    try entries_buf.ensureTotalCapacity(arena, questions_arr.items.len);

    for (questions_arr.items, 1..) |q_item, question_number| {
        position.* = .{ .question = question_number };
        if (q_item != .object) return error.QuestionNotObject;

        const question_value = q_item.object.get("question") orelse return error.MissingQuestionText;
        if (question_value != .string) return error.QuestionTextNotString;
        const question_trimmed = std.mem.trim(u8, question_value.string, whitespace);
        if (question_trimmed.len == 0) return error.EmptyQuestionText;
        const question_safe = try dupeQuestionMarkdown(arena, question_trimmed);

        const options_value = q_item.object.get("options") orelse return error.MissingOptions;
        if (options_value != .array) return error.OptionsNotArray;

        const options_arr = options_value.array;
        if (options_arr.items.len < 2 or options_arr.items.len > 6) return error.OptionCount;

        var options_buf: std.ArrayList(core_types.QuestionOption) = .empty;
        try options_buf.ensureTotalCapacity(arena, options_arr.items.len);
        var saw_freeform_label = false;

        for (options_arr.items, 1..) |item, option_number| {
            position.option = option_number;
            if (item != .object) return error.OptionNotObject;
            const label_value = item.object.get("label") orelse return error.MissingOptionLabel;
            if (label_value != .string) return error.OptionLabelNotString;
            const label_trimmed = std.mem.trim(u8, label_value.string, whitespace);
            if (label_trimmed.len == 0) return error.EmptyOptionLabel;
            const label_safe = try dupeLabelText(arena, label_trimmed);

            // The prompt adds its own "Other" row for a typed answer, so a
            // second one from the model would only return the word itself.
            if (std.ascii.eqlIgnoreCase(label_safe, question_prompt.freeform_option_label)) {
                if (saw_freeform_label) return error.DuplicateOptionLabel;
                saw_freeform_label = true;
                continue;
            }
            for (options_buf.items) |existing| {
                if (std.ascii.eqlIgnoreCase(existing.label, label_safe)) return error.DuplicateOptionLabel;
            }

            var desc_slice: ?[]const u8 = null;
            if (item.object.get("description")) |desc_value| {
                if (desc_value == .string) {
                    const trimmed_desc = std.mem.trim(u8, desc_value.string, whitespace);
                    if (trimmed_desc.len > 0) desc_slice = try dupeDescriptionMarkdown(arena, trimmed_desc);
                }
            }

            options_buf.appendAssumeCapacity(.{
                .label = label_safe,
                .description = desc_slice,
            });
        }

        position.option = 0;
        entries_buf.appendAssumeCapacity(.{
            .question = question_safe,
            .markdown = true,
            .options = try options_buf.toOwnedSlice(arena),
        });
    }

    return entries_buf.toOwnedSlice(arena);
}

/// A label is one line: it names an option and comes back as the answer.
/// Line breaks and tabs become one space, and control bytes become visible
/// escapes, so model text cannot drive the terminal.
fn dupeLabelText(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    if (text_utils.isTerminalSafe(text)) return arena.dupe(u8, text);
    const encoded = try text_utils.encodeTerminalSafeInline(arena, text, std.math.maxInt(usize));
    return encoded.bytes;
}

/// A question keeps its lines. It is Markdown, which the prompt renders as
/// the transcript renders a reply. Control bytes become visible escapes.
fn dupeQuestionMarkdown(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    // A carriage return ends a line with or without a line feed after it.
    var lines: std.ArrayList(u8) = .empty;
    try lines.ensureTotalCapacity(arena, text.len);
    for (text, 0..) |byte, index| {
        if (byte != '\r') {
            lines.appendAssumeCapacity(byte);
        } else if (index + 1 >= text.len or text[index + 1] != '\n') {
            lines.appendAssumeCapacity('\n');
        }
    }
    if (text_utils.isTerminalSafeText(lines.items)) return lines.items;

    var out: std.ArrayList(u8) = .empty;
    try text_utils.appendTerminalSafeText(arena, &out, lines.items);
    return out.items;
}

/// A description keeps its lines and is Markdown, as the question is.
/// Blank lines are dropped so an option's rows stay together, and control
/// bytes become visible escapes.
fn dupeDescriptionMarkdown(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |raw_line| {
        // A line's indent can nest a list item, so only its end is trimmed.
        const line = std.mem.trimEnd(u8, raw_line, " \t");
        if (line.len == 0) continue;
        if (out.items.len > 0) try out.append(arena, '\n');
        try text_utils.appendTerminalSafeText(arena, &out, line);
    }
    return out.items;
}

/// Explains a parse error to the model. An error inside a question or an
/// option leads with its position, so a long batch needs no search.
fn invalidArgsBody(
    alloc: Allocator,
    err: QuestionBatchParseError,
    position: ParsePosition,
) Allocator.Error![]u8 {
    const reason = switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidArguments => return alloc.dupe(u8, invalid_args_sentinel),
        error.MissingQuestions => return alloc.dupe(u8, "(ask_user_question: missing required array \"questions\")"),
        error.QuestionsNotArray => return alloc.dupe(u8, "(ask_user_question: \"questions\" must be an array)"),
        error.QuestionCount => return alloc.dupe(u8, question_count_sentinel),
        error.QuestionNotObject => "must be an object with a \"question\" and \"options\"",
        error.MissingQuestionText => "requires a \"question\" string",
        error.QuestionTextNotString => "\"question\" must be a string",
        error.EmptyQuestionText => "question text must not be empty",
        error.MissingOptions => "requires an \"options\" array",
        error.OptionsNotArray => "\"options\" must be an array",
        error.OptionCount => "provide 2 to 6 options",
        error.OptionNotObject => "must be an object with a \"label\"",
        error.MissingOptionLabel => "requires a \"label\" string",
        error.OptionLabelNotString => "\"label\" must be a string",
        error.EmptyOptionLabel => "label must not be empty",
        error.DuplicateOptionLabel => "label repeats an earlier option; labels must be unique within a question",
    };
    if (position.option > 0) {
        return alloc.print("(ask_user_question: question {d}, option {d}: {s})", .{ position.question, position.option, reason });
    }
    return alloc.print("(ask_user_question: question {d}: {s})", .{ position.question, reason });
}

fn freeAnswers(alloc: Allocator, answers: [][]u8) void {
    for (answers) |answer| alloc.free(answer);
    alloc.free(answers);
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn requesterCancel(_: ?*anyopaque, _: Allocator, _: []const core_types.QuestionBatchEntry) anyerror!?[][]u8 {
    return null;
}

const FakeRequester = struct {
    called: bool = false,
    saw_trimmed: bool = false,

    fn request(raw_ctx: ?*anyopaque, alloc: Allocator, entries: []const core_types.QuestionBatchEntry) anyerror!?[][]u8 {
        const self: *FakeRequester = @ptrCast(@alignCast(raw_ctx.?));
        self.called = true;
        if (entries.len == 1 and
            std.mem.eql(u8, entries[0].question, "Choose?") and
            entries[0].options.len == 2 and
            std.mem.eql(u8, entries[0].options[0].label, "Yes") and
            entries[0].options[0].description != null and
            std.mem.eql(u8, entries[0].options[0].description.?, "Go ahead") and
            entries[0].options[1].description == null)
        {
            self.saw_trimmed = true;
        }

        const answers = try alloc.alloc([]u8, entries.len);
        errdefer alloc.free(answers);
        var filled: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < filled) : (i += 1) alloc.free(answers[i]);
        }
        while (filled < entries.len) : (filled += 1) {
            answers[filled] = try alloc.dupe(u8, entries[filled].options[0].label);
        }
        return answers;
    }
};

const TerminalSafeRequester = struct {
    called: bool = false,
    saw_terminal_safe: bool = false,

    fn request(raw_ctx: ?*anyopaque, alloc: Allocator, entries: []const core_types.QuestionBatchEntry) anyerror!?[][]u8 {
        const self: *TerminalSafeRequester = @ptrCast(@alignCast(raw_ctx.?));
        self.called = true;
        if (entries.len == 1 and
            std.mem.eql(u8, entries[0].question, "Q\n\\x1b[31m?") and
            entries[0].markdown and
            entries[0].options.len == 2 and
            std.mem.eql(u8, entries[0].options[0].label, "Alpha Fake") and
            entries[0].options[0].description != null and
            std.mem.eql(u8, entries[0].options[0].description.?, "Desc\tGap") and
            std.mem.eql(u8, entries[0].options[1].label, "\\x1b[31mRed\\x1b[0m"))
        {
            self.saw_terminal_safe = true;
        }

        const answers = try alloc.alloc([]u8, entries.len);
        errdefer alloc.free(answers);
        var filled: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < filled) : (i += 1) alloc.free(answers[i]);
        }
        while (filled < entries.len) : (filled += 1) {
            answers[filled] = try alloc.dupe(u8, entries[filled].options[0].label);
        }
        return answers;
    }
};

fn expectRequesterOutput(args_json: []const u8, expected: []const u8) !void {
    const alloc = std.testing.allocator;
    var fake = FakeRequester{};
    const output = try executeWithRequester(alloc, args_json, .{
        .ctx = &fake,
        .response_alloc = alloc,
        .request = FakeRequester.request,
    });
    defer alloc.free(output);
    try std.testing.expectEqualStrings(expected, output);
}

test "ask_user_question validates arguments and returns active sentinels" {
    try expectRequesterOutput("not-json", invalid_args_sentinel);
    try expectRequesterOutput("[]", invalid_args_sentinel);
    try expectRequesterOutput("{}", "(ask_user_question: missing required array \"questions\")");
    try expectRequesterOutput("{\"questions\":{}}", "(ask_user_question: \"questions\" must be an array)");
    try expectRequesterOutput("{\"questions\":[]}", "(ask_user_question: provide 1 to 20 questions)");
    try expectRequesterOutput("{\"questions\":[1]}", "(ask_user_question: question 1: must be an object with a \"question\" and \"options\")");
    try expectRequesterOutput("{\"questions\":[{}]}", "(ask_user_question: question 1: requires a \"question\" string)");
    try expectRequesterOutput("{\"questions\":[{\"question\":1}]}", "(ask_user_question: question 1: \"question\" must be a string)");
    try expectRequesterOutput("{\"questions\":[{\"question\":\"  \",\"options\":[]}]}", "(ask_user_question: question 1: question text must not be empty)");
    try expectRequesterOutput("{\"questions\":[{\"question\":\"Q?\"}]}", "(ask_user_question: question 1: requires an \"options\" array)");
    try expectRequesterOutput("{\"questions\":[{\"question\":\"Q?\",\"options\":1}]}", "(ask_user_question: question 1: \"options\" must be an array)");
    try expectRequesterOutput("{\"questions\":[{\"question\":\"Q?\",\"options\":[]}]}", "(ask_user_question: question 1: provide 2 to 6 options)");
    try expectRequesterOutput("{\"questions\":[{\"question\":\"Q?\",\"options\":[1,2]}]}", "(ask_user_question: question 1, option 1: must be an object with a \"label\")");
    try expectRequesterOutput("{\"questions\":[{\"question\":\"Q?\",\"options\":[{},{}]}]}", "(ask_user_question: question 1, option 1: requires a \"label\" string)");
    try expectRequesterOutput("{\"questions\":[{\"question\":\"Q?\",\"options\":[{\"label\":1},{\"label\":\"No\"}]}]}", "(ask_user_question: question 1, option 1: \"label\" must be a string)");
    try expectRequesterOutput("{\"questions\":[{\"question\":\"Q?\",\"options\":[{\"label\":\"\"},{\"label\":\"No\"}]}]}", "(ask_user_question: question 1, option 1: label must not be empty)");
    try expectRequesterOutput("{\"questions\":[{\"question\":\"Q?\",\"options\":[{\"label\":\"Yes\"},{\"label\":\" yes \"}]}]}", "(ask_user_question: question 1, option 2: label repeats an earlier option; labels must be unique within a question)");
}

test "ask_user_question names the question and option an error is in" {
    const valid = "{\"question\":\"Q?\",\"options\":[{\"label\":\"Yes\"},{\"label\":\"No\"}]}";
    inline for (.{
        .{ "{\"question\":\"Q?\",\"options\":[{\"label\":\"Yes\"}]}", "(ask_user_question: question 3: provide 2 to 6 options)" },
        .{ "{\"question\":\"Q?\",\"options\":[{\"label\":\"Yes\"},{\"label\":\"No\"},\"Maybe\"]}", "(ask_user_question: question 3, option 3: must be an object with a \"label\")" },
        .{ "{\"options\":[{\"label\":\"Yes\"},{\"label\":\"No\"}]}", "(ask_user_question: question 3: requires a \"question\" string)" },
    }) |case| {
        try expectRequesterOutput("{\"questions\":[" ++ valid ++ "," ++ valid ++ "," ++ case[0] ++ "]}", case[1]);
    }
}

const OtherLabelRequester = struct {
    option_counts: [2]usize = .{ 0, 0 },

    fn request(raw_ctx: ?*anyopaque, alloc: Allocator, entries: []const core_types.QuestionBatchEntry) anyerror!?[][]u8 {
        const self: *OtherLabelRequester = @ptrCast(@alignCast(raw_ctx.?));
        for (entries, 0..) |entry, index| {
            self.option_counts[index] = entry.options.len;
            for (entry.options) |option| {
                if (std.ascii.eqlIgnoreCase(option.label, "Other")) return error.TestUnexpectedResult;
            }
        }
        const answers = try alloc.alloc([]u8, entries.len);
        errdefer alloc.free(answers);
        var filled: usize = 0;
        errdefer for (answers[0..filled]) |answer| alloc.free(answer);
        while (filled < entries.len) : (filled += 1) {
            answers[filled] = try alloc.dupe(u8, entries[filled].options[0].label);
        }
        return answers;
    }
};

test "ask_user_question leaves the Other row to the prompt" {
    const alloc = std.testing.allocator;
    var requester = OtherLabelRequester{};
    const output = try executeWithRequester(
        alloc,
        "{\"questions\":[" ++
            "{\"question\":\"First?\",\"options\":[{\"label\":\"Yes\"},{\"label\":\"No\"},{\"label\":\" other \",\"description\":\"Something else\"}]}," ++
            "{\"question\":\"Second?\",\"options\":[{\"label\":\"Other\"},{\"label\":\"Keep\"}]}]}",
        .{ .ctx = &requester, .response_alloc = alloc, .request = OtherLabelRequester.request },
    );
    defer alloc.free(output);
    try std.testing.expectEqual([2]usize{ 2, 1 }, requester.option_counts);
    try std.testing.expectEqualStrings(
        "[{\"question\":\"First?\",\"answer\":\"Yes\"},{\"question\":\"Second?\",\"answer\":\"Keep\"}]",
        output,
    );

    try expectRequesterOutput(
        "{\"questions\":[{\"question\":\"Q?\",\"options\":[{\"label\":\"Other\"},{\"label\":\"other\"}]}]}",
        "(ask_user_question: question 1, option 2: label repeats an earlier option; labels must be unique within a question)",
    );
}

test "ask_user_question normalizes descriptions and encodes ordered answers" {
    const alloc = std.testing.allocator;
    var fake = FakeRequester{};
    const output = try executeWithRequester(
        alloc,
        "{\"questions\":[{\"question\":\" Choose? \",\"options\":[{\"label\":\" Yes \",\"description\":\" Go ahead \"},{\"label\":\"No\",\"description\":3}]}]}",
        .{
            .ctx = &fake,
            .response_alloc = alloc,
            .request = FakeRequester.request,
        },
    );
    defer alloc.free(output);

    try std.testing.expect(fake.called);
    try std.testing.expect(fake.saw_trimmed);
    try std.testing.expectEqualStrings("[{\"question\":\"Choose?\",\"answer\":\"Yes\"}]", output);
}

test "ask_user_question accepts the questions array sent as JSON text" {
    const alloc = std.testing.allocator;
    var fake = FakeRequester{};
    const output = try executeWithRequester(
        alloc,
        "{\"questions\":\"[{\\\"question\\\":\\\" Choose? \\\",\\\"options\\\":[{\\\"label\\\":\\\" Yes \\\"},{\\\"label\\\":\\\"No\\\"}]}]\"}",
        .{
            .ctx = &fake,
            .response_alloc = alloc,
            .request = FakeRequester.request,
        },
    );
    defer alloc.free(output);

    try std.testing.expect(fake.called);
    try std.testing.expectEqualStrings("[{\"question\":\"Choose?\",\"answer\":\"Yes\"}]", output);
    try expectRequesterOutput("{\"questions\":\"not json\"}", "(ask_user_question: \"questions\" must be an array)");
    try expectRequesterOutput("{\"questions\":\"{}\"}", "(ask_user_question: \"questions\" must be an array)");
}

const max_fuzz_questions_text_bytes: usize = 16 * 1024;

fn fuzzQuestionsText(_: void, smith: *std.testing.Smith) !void {
    var buffer: [max_fuzz_questions_text_bytes + 1]u8 = undefined;
    const text = buffer[0..smith.slice(&buffer)];
    // Text that is not UTF-8 fails the argument parse before questions is
    // read, so it never reaches the JSON-text decode this target covers.
    if (!std.unicode.utf8ValidateSlice(text)) return;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args_json = try std.json.Stringify.valueAlloc(arena, .{ .questions = text }, .{});
    var position: ParsePosition = .{};
    if (parseQuestionBatch(arena, args_json, &position)) |entries| {
        try std.testing.expect(entries.len >= 1 and entries.len <= question_answer.max_questions);
    } else |err| switch (err) {
        error.OutOfMemory => return err,
        else => {},
    }
}

test "ask_user_question questions sent as JSON text decode or refuse arbitrary bytes" {
    try std.testing.fuzz({}, fuzzQuestionsText, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "[{\"question\":\"Pick one?\",\"options\":[{\"label\":\"A\"},{\"label\":\"B\"}]}]",
            "[{\"question\":\"Pick one?\",\"options\":[{\"label\":\"A\"}]}]",
            "[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]",
            "{}",
            "[",
        }) ++ @import("fuzz_corpus").ask_questions_text.*),
    });
}

test "ask_user_question makes model-controlled prompt text safe for terminal display" {
    const alloc = std.testing.allocator;
    var requester = TerminalSafeRequester{};
    const output = try executeWithRequester(
        alloc,
        "{\"questions\":[{\"question\":\"Q\\n\\u001b[31m?\",\"options\":[{\"label\":\"Alpha\\nFake\",\"description\":\"Desc\\tGap\"},{\"label\":\"\\u001b[31mRed\\u001b[0m\"}]}]}",
        .{
            .ctx = &requester,
            .response_alloc = alloc,
            .request = TerminalSafeRequester.request,
        },
    );
    defer alloc.free(output);

    try std.testing.expect(requester.called);
    try std.testing.expect(requester.saw_terminal_safe);
    try std.testing.expectEqualStrings(
        "[{\"question\":\"Q\\n\\\\x1b[31m?\",\"answer\":\"Alpha Fake\"}]",
        output,
    );
}

const MultilineRequester = struct {
    question: []const u8 = "",
    descriptions: [3][]const u8 = .{ "", "", "" },
    labels: [3][]const u8 = .{ "", "", "" },
    markdown: bool = false,
    arena: Allocator,

    fn request(raw_ctx: ?*anyopaque, alloc: Allocator, entries: []const core_types.QuestionBatchEntry) anyerror!?[][]u8 {
        const self: *MultilineRequester = @ptrCast(@alignCast(raw_ctx.?));
        self.question = try self.arena.dupe(u8, entries[0].question);
        self.markdown = entries[0].markdown;
        for (entries[0].options, 0..) |option, index| {
            self.labels[index] = try self.arena.dupe(u8, option.label);
            self.descriptions[index] = try self.arena.dupe(u8, option.description orelse "");
        }
        const answers = try alloc.alloc([]u8, 1);
        errdefer alloc.free(answers);
        answers[0] = try alloc.dupe(u8, entries[0].options[0].label);
        return answers;
    }
};

test "ask_user_question keeps the lines of a question and a description" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var requester = MultilineRequester{ .arena = arena_state.allocator() };

    const args = try std.json.Stringify.valueAlloc(arena_state.allocator(), .{ .questions = .{.{
        .question = "\n  Two ways to migrate:\r\n\r\n- **online**\r- `offline`\n\n```sh\n\tfx migrate\n```\n\nWhich one?  \n",
        .options = .{
            .{ .label = "Online\nnow", .description = " No downtime.\n \t\n  Takes two\thours. \rSlow writes.\r\n" },
            .{ .label = "Offline", .description = "\n \n" },
            .{ .label = "Later", .description = "One line." },
        },
    }} }, .{});
    const output = try executeWithRequester(alloc, args, .{
        .ctx = &requester,
        .response_alloc = alloc,
        .request = MultilineRequester.request,
    });
    defer alloc.free(output);

    try std.testing.expect(requester.markdown);
    try std.testing.expectEqualStrings(
        "Two ways to migrate:\n\n- **online**\n- `offline`\n\n```sh\n\tfx migrate\n```\n\nWhich one?",
        requester.question,
    );
    try std.testing.expectEqualStrings("Online now", requester.labels[0]);
    try std.testing.expectEqualStrings("No downtime.\n  Takes two\thours.\nSlow writes.", requester.descriptions[0]);
    try std.testing.expectEqualStrings("", requester.descriptions[1]);
    try std.testing.expectEqualStrings("One line.", requester.descriptions[2]);

    // The result returns the question as it was shown, so a saved session
    // replays the same card.
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, output, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(requester.question, parsed.value.array.items[0].object.get("question").?.string);
    try std.testing.expectEqualStrings("Online now", parsed.value.array.items[0].object.get("answer").?.string);
}

test "ask_user_question shows control bytes on every line of a question and a description" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var requester = MultilineRequester{ .arena = arena_state.allocator() };

    const args = try std.json.Stringify.valueAlloc(arena_state.allocator(), .{ .questions = .{.{
        .question = "First \x1b[2J line\nSecond \x1b]0;title\x07 line\x08",
        .options = .{
            .{ .label = "Yes", .description = "Clear \x1b[2J\nscroll \x1b[3J back" },
            .{ .label = "No" },
        },
    }} }, .{});
    const output = try executeWithRequester(alloc, args, .{
        .ctx = &requester,
        .response_alloc = alloc,
        .request = MultilineRequester.request,
    });
    defer alloc.free(output);

    try std.testing.expectEqualStrings(
        "First \\x1b[2J line\nSecond \\x1b]0;title\\x07 line\\x08",
        requester.question,
    );
    try std.testing.expectEqualStrings("Clear \\x1b[2J\nscroll \\x1b[3J back", requester.descriptions[0]);
    for ([_][]const u8{ requester.question, requester.descriptions[0] }) |text| {
        try std.testing.expect(text_utils.isTerminalSafeText(text));
        try std.testing.expect(std.mem.findScalar(u8, text, 0x1b) == null);
    }
}

const batch_option_count = 6;

/// Writes `ask_user_question` arguments with `count` questions of six options
/// each. The caller owns the returned slice.
fn questionBatchArgs(alloc: Allocator, count: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"questions\":[");
    for (0..count) |question| {
        if (question > 0) try out.writer.writeByte(',');
        try out.writer.print("{{\"question\":\"Question {d}?\",\"options\":[", .{question + 1});
        for (0..batch_option_count) |option| {
            if (option > 0) try out.writer.writeByte(',');
            try out.writer.print(
                "{{\"label\":\"Q{d} option {d}\",\"description\":\"Consequence {d}.{d}\"}}",
                .{ question + 1, option + 1, question + 1, option + 1 },
            );
        }
        try out.writer.writeAll("]}");
    }
    try out.writer.writeAll("]}");
    return out.toOwnedSlice();
}

/// Answers question `i` with option `i % 6` and records whether every entry
/// arrived in order with all of its options.
const FullBatchRequester = struct {
    calls: usize = 0,
    entry_count: usize = 0,
    entries_in_order: bool = true,

    fn request(raw_ctx: ?*anyopaque, alloc: Allocator, entries: []const core_types.QuestionBatchEntry) anyerror!?[][]u8 {
        const self: *FullBatchRequester = @ptrCast(@alignCast(raw_ctx.?));
        self.calls += 1;
        self.entry_count = entries.len;
        for (entries, 0..) |entry, index| {
            var expected_buf: [32]u8 = undefined;
            const expected = try std.mem.print(&expected_buf, "Question {d}?", .{index + 1});
            if (!std.mem.eql(u8, entry.question, expected) or entry.options.len != batch_option_count) {
                self.entries_in_order = false;
            }
        }

        const answers = try alloc.alloc([]u8, entries.len);
        errdefer alloc.free(answers);
        var filled: usize = 0;
        errdefer for (answers[0..filled]) |answer| alloc.free(answer);
        while (filled < entries.len) : (filled += 1) {
            answers[filled] = try alloc.dupe(u8, entries[filled].options[filled % batch_option_count].label);
        }
        return answers;
    }
};

test "ask_user_question accepts a full batch and rejects one more question" {
    const alloc = std.testing.allocator;
    const full_args = try questionBatchArgs(alloc, question_answer.max_questions);
    defer alloc.free(full_args);

    var requester = FullBatchRequester{};
    const output = try executeWithRequester(alloc, full_args, .{
        .ctx = &requester,
        .response_alloc = alloc,
        .request = FullBatchRequester.request,
    });
    defer alloc.free(output);

    try std.testing.expectEqual(@as(usize, 1), requester.calls);
    try std.testing.expectEqual(@as(usize, question_answer.max_questions), requester.entry_count);
    try std.testing.expect(requester.entries_in_order);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const answers = (try question_answer.decodeJson(arena_state.allocator(), output)).?;
    try std.testing.expectEqual(@as(usize, question_answer.max_questions), answers.len);
    for (answers, 0..) |pair, index| {
        var question_buf: [32]u8 = undefined;
        var answer_buf: [32]u8 = undefined;
        try std.testing.expectEqualStrings(
            try std.mem.print(&question_buf, "Question {d}?", .{index + 1}),
            pair.question,
        );
        try std.testing.expectEqualStrings(
            try std.mem.print(&answer_buf, "Q{d} option {d}", .{ index + 1, index % batch_option_count + 1 }),
            pair.answer,
        );
    }

    const oversized_args = try questionBatchArgs(alloc, question_answer.max_questions + 1);
    defer alloc.free(oversized_args);
    var oversized_requester = FullBatchRequester{};
    const rejected = try executeWithRequester(alloc, oversized_args, .{
        .ctx = &oversized_requester,
        .response_alloc = alloc,
        .request = FullBatchRequester.request,
    });
    defer alloc.free(rejected);
    try std.testing.expectEqualStrings("(ask_user_question: provide 1 to 20 questions)", rejected);
    try std.testing.expectEqual(@as(usize, 0), oversized_requester.calls);
}

test "ask_user_question full batch frees every allocation when any allocation fails" {
    const args = try questionBatchArgs(std.testing.allocator, question_answer.max_questions);
    defer std.testing.allocator.free(args);

    // Sweep each allocation of a full batch, parse through answer encoding,
    // until a run completes without an injected failure.
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing_allocator.no_resize, .{ .fail_index = fail_index });
        const alloc = failing.allocator();
        var requester = FullBatchRequester{};
        const completed = if (executeWithRequester(alloc, args, .{
            .ctx = &requester,
            .response_alloc = alloc,
            .request = FullBatchRequester.request,
        })) |output| blk: {
            alloc.free(output);
            break :blk !failing.has_induced_failure;
        } else |err| switch (err) {
            // The answer encoder reports allocation failure as a write failure.
            error.OutOfMemory, error.WriteFailed => blk: {
                try std.testing.expect(failing.has_induced_failure);
                break :blk false;
            },
            else => return err,
        };
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (completed) break;
    }
    // The requester alone allocates one answer per question.
    try std.testing.expect(fail_index > question_answer.max_questions);
}

test "ask_user_question cancellation returns sentinel" {
    const alloc = std.testing.allocator;
    const output = try executeWithRequester(
        alloc,
        "{\"questions\":[{\"question\":\"Q?\",\"options\":[{\"label\":\"Yes\"},{\"label\":\"No\"}]}]}",
        .{
            .ctx = null,
            .response_alloc = alloc,
            .request = requesterCancel,
        },
    );
    defer alloc.free(output);

    try std.testing.expectEqualStrings(cancel_sentinel, output);
}

test "ask_user_question validation rejects legacy permission references before prompting" {
    const alloc = std.testing.allocator;
    const decoded = try decode(
        .{ .allocator = alloc },
        "{\"permission_request_id\":\"legacy\",\"questions\":[]}",
    );
    const input = switch (decoded) {
        .failure => |body| {
            defer alloc.free(body);
            return error.TestExpectedEqual;
        },
        .input => |owned| owned,
    };
    defer input.deinit(alloc);
    const failure = (try validate(.{ .allocator = alloc }, input)) orelse
        return error.TestExpectedEqual;
    defer alloc.free(failure);
    try std.testing.expectEqualStrings(legacy_permission_request_sentinel, failure);
}

test "ask_user_question noninteractive returns sentinel before parsing" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "not-json");
    const input = switch (decoded) {
        .failure => |body| {
            defer alloc.free(body);
            return error.TestExpectedEqual;
        },
        .input => |owned| owned,
    };
    defer input.deinit(alloc);

    const result = try call(.{ .allocator = alloc }, input);
    defer result.deinit(alloc);

    switch (result) {
        .rich => return error.TestUnexpectedRichResult,
        .success => |body| try std.testing.expectEqualStrings(not_available_sentinel, body),
        .failure => return error.TestExpectedEqual,
    }
}
