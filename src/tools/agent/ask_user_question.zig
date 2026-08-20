const std = @import("std");
const question_answer = @import("../../core/agent/question_answer.zig");
const core_types = @import("../../core/shared/types.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

const whitespace = " \t\r\n";
pub const permission_request_id_hex_bytes = std.crypto.hash.sha2.Sha256.digest_length * 2;

pub const cancel_sentinel = "(user cancelled the question)";
pub const not_available_sentinel = "(ask_user_question is only available in the interactive shell; ask the user freeform instead)";

const invalid_args_sentinel = "(ask_user_question: invalid arguments; provide {questions})";

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

pub const Input = struct {
    args_json: []u8,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.args_json);
        self.* = .{ .args_json = &.{} };
    }
};

pub const PermissionRequestReference = union(enum) {
    none,
    invalid,
    id: [std.crypto.hash.sha2.Sha256.digest_length]u8,
};

pub fn permissionRequestReference(
    alloc: Allocator,
    args_json: []const u8,
) Allocator.Error!PermissionRequestReference {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, args_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .invalid,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return .invalid;
    const value = parsed.value.object.get("permission_request_id") orelse
        return .none;
    if (value != .string or
        value.string.len != permission_request_id_hex_bytes) return .invalid;
    var id: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&id, value.string) catch return .invalid;
    const canonical = std.fmt.bytesToHex(id, .lower);
    if (!std.mem.eql(u8, &canonical, value.string)) return .invalid;
    return .{ .id = id };
}

pub const Requester = struct {
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

pub fn validate(_: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const request = ctx.ask_question_batch orelse {
        return .{ .success = try ctx.allocator.dupe(u8, not_available_sentinel) };
    };
    const input = erased.as(Input);
    const output = executeWithRequester(ctx.allocator, input.args_json, .{
        .ctx = ctx.ask_question_ctx,
        .response_alloc = ctx.allocator,
        .request = request,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "ask_user_question failed: {s}", .{@errorName(err)}) },
    };
    return .{ .success = output };
}

pub fn executeWithRequester(result_alloc: Allocator, args_json: []const u8, requester: Requester) ![]u8 {
    var parse_arena_state = std.heap.ArenaAllocator.init(result_alloc);
    defer parse_arena_state.deinit();
    const parse_arena = parse_arena_state.allocator();

    const entries = parseQuestionBatch(parse_arena, args_json) catch |err| return invalidArgsBody(result_alloc, err);
    const answers_opt = try requester.request(requester.ctx, requester.response_alloc, entries);
    if (answers_opt) |answers| {
        defer freeAnswers(requester.response_alloc, answers);
        return question_answer.encodeJson(result_alloc, entries, answers);
    }
    return result_alloc.dupe(u8, cancel_sentinel);
}

fn parseQuestionBatch(arena: Allocator, args_json: []const u8) QuestionBatchParseError![]const core_types.QuestionBatchEntry {
    var parsed = std.json.parseFromSlice(std.json.Value, arena, args_json, .{}) catch {
        return error.InvalidArguments;
    };
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidArguments;
    const args = parsed.value.object;

    const questions_value = args.get("questions") orelse return error.MissingQuestions;
    if (questions_value != .array) return error.QuestionsNotArray;

    const questions_arr = questions_value.array;
    if (questions_arr.items.len < 1 or questions_arr.items.len > 4) return error.QuestionCount;

    var entries_buf: std.ArrayList(core_types.QuestionBatchEntry) = .empty;
    try entries_buf.ensureTotalCapacity(arena, questions_arr.items.len);

    for (questions_arr.items) |q_item| {
        if (q_item != .object) return error.QuestionNotObject;

        const question_value = q_item.object.get("question") orelse return error.MissingQuestionText;
        if (question_value != .string) return error.QuestionTextNotString;
        const question_trimmed = std.mem.trim(u8, question_value.string, whitespace);
        if (question_trimmed.len == 0) return error.EmptyQuestionText;
        const question_safe = try dupeTerminalSafeQuestionText(arena, question_trimmed);

        const options_value = q_item.object.get("options") orelse return error.MissingOptions;
        if (options_value != .array) return error.OptionsNotArray;

        const options_arr = options_value.array;
        if (options_arr.items.len < 2 or options_arr.items.len > 6) return error.OptionCount;

        var options_buf: std.ArrayList(core_types.QuestionOption) = .empty;
        try options_buf.ensureTotalCapacity(arena, options_arr.items.len);

        for (options_arr.items) |item| {
            if (item != .object) return error.OptionNotObject;
            const label_value = item.object.get("label") orelse return error.MissingOptionLabel;
            if (label_value != .string) return error.OptionLabelNotString;
            const label_trimmed = std.mem.trim(u8, label_value.string, whitespace);
            if (label_trimmed.len == 0) return error.EmptyOptionLabel;
            const label_safe = try dupeTerminalSafeQuestionText(arena, label_trimmed);

            for (options_buf.items) |existing| {
                if (std.ascii.eqlIgnoreCase(existing.label, label_safe)) return error.DuplicateOptionLabel;
            }

            var desc_slice: ?[]const u8 = null;
            if (item.object.get("description")) |desc_value| {
                if (desc_value == .string) {
                    const trimmed_desc = std.mem.trim(u8, desc_value.string, whitespace);
                    if (trimmed_desc.len > 0) desc_slice = try dupeTerminalSafeQuestionText(arena, trimmed_desc);
                }
            }

            options_buf.appendAssumeCapacity(.{
                .label = label_safe,
                .description = desc_slice,
            });
        }

        entries_buf.appendAssumeCapacity(.{
            .question = question_safe,
            .options = try options_buf.toOwnedSlice(arena),
        });
    }

    return entries_buf.toOwnedSlice(arena);
}

fn dupeTerminalSafeQuestionText(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    if (text_utils.isTerminalSafe(text)) return arena.dupe(u8, text);
    const encoded = try text_utils.encodeTerminalSafe(arena, text, std.math.maxInt(usize));
    return encoded.bytes;
}

fn invalidArgsBody(alloc: Allocator, err: QuestionBatchParseError) Allocator.Error![]u8 {
    const body = switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidArguments => invalid_args_sentinel,
        error.MissingQuestions => "(ask_user_question: missing required array \"questions\")",
        error.QuestionsNotArray => "(ask_user_question: \"questions\" must be an array)",
        error.QuestionCount => "(ask_user_question: provide 1 to 4 questions)",
        error.QuestionNotObject => "(ask_user_question: each question must be an object with a \"question\" and \"options\")",
        error.MissingQuestionText => "(ask_user_question: each question requires a \"question\" string)",
        error.QuestionTextNotString => "(ask_user_question: question \"question\" must be a string)",
        error.EmptyQuestionText => "(ask_user_question: question text must not be empty)",
        error.MissingOptions => "(ask_user_question: each question requires an \"options\" array)",
        error.OptionsNotArray => "(ask_user_question: \"options\" must be an array)",
        error.OptionCount => "(ask_user_question: provide 2 to 6 options per question)",
        error.OptionNotObject => "(ask_user_question: each option must be an object with a \"label\")",
        error.MissingOptionLabel => "(ask_user_question: each option requires a \"label\" string)",
        error.OptionLabelNotString => "(ask_user_question: option \"label\" must be a string)",
        error.EmptyOptionLabel => "(ask_user_question: option labels must not be empty)",
        error.DuplicateOptionLabel => "(ask_user_question: option labels must be unique within a question)",
    };
    return alloc.dupe(u8, body);
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
            std.mem.eql(u8, entries[0].question, "Q\\x0a\\x1b[31m?") and
            entries[0].options.len == 2 and
            std.mem.eql(u8, entries[0].options[0].label, "Alpha\\x0aFake") and
            entries[0].options[0].description != null and
            std.mem.eql(u8, entries[0].options[0].description.?, "Desc\\x09Gap") and
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
    try expectRequesterOutput("{\"questions\":[]}", "(ask_user_question: provide 1 to 4 questions)");
    try expectRequesterOutput("{\"questions\":[1]}", "(ask_user_question: each question must be an object with a \"question\" and \"options\")");
    try expectRequesterOutput("{\"questions\":[{}]}", "(ask_user_question: each question requires a \"question\" string)");
    try expectRequesterOutput("{\"questions\":[{\"question\":1}]}", "(ask_user_question: question \"question\" must be a string)");
    try expectRequesterOutput("{\"questions\":[{\"question\":\"  \",\"options\":[]}]}", "(ask_user_question: question text must not be empty)");
    try expectRequesterOutput("{\"questions\":[{\"question\":\"Q?\"}]}", "(ask_user_question: each question requires an \"options\" array)");
    try expectRequesterOutput("{\"questions\":[{\"question\":\"Q?\",\"options\":1}]}", "(ask_user_question: \"options\" must be an array)");
    try expectRequesterOutput("{\"questions\":[{\"question\":\"Q?\",\"options\":[]}]}", "(ask_user_question: provide 2 to 6 options per question)");
    try expectRequesterOutput("{\"questions\":[{\"question\":\"Q?\",\"options\":[1,2]}]}", "(ask_user_question: each option must be an object with a \"label\")");
    try expectRequesterOutput("{\"questions\":[{\"question\":\"Q?\",\"options\":[{},{}]}]}", "(ask_user_question: each option requires a \"label\" string)");
    try expectRequesterOutput("{\"questions\":[{\"question\":\"Q?\",\"options\":[{\"label\":1},{\"label\":\"No\"}]}]}", "(ask_user_question: option \"label\" must be a string)");
    try expectRequesterOutput("{\"questions\":[{\"question\":\"Q?\",\"options\":[{\"label\":\"\"},{\"label\":\"No\"}]}]}", "(ask_user_question: option labels must not be empty)");
    try expectRequesterOutput("{\"questions\":[{\"question\":\"Q?\",\"options\":[{\"label\":\"Yes\"},{\"label\":\" yes \"}]}]}", "(ask_user_question: option labels must be unique within a question)");
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

test "ask_user_question encodes model-controlled prompt text for terminal display" {
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
        "[{\"question\":\"Q\\\\x0a\\\\x1b[31m?\",\"answer\":\"Alpha\\\\x0aFake\"}]",
        output,
    );
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

test "permission request reference accepts only canonical action ids" {
    const valid_hex = "0123456789abcdef" ** 4;
    const valid = try permissionRequestReference(
        std.testing.allocator,
        "{\"permission_request_id\":\"" ++ valid_hex ++ "\",\"questions\":[]}",
    );
    try std.testing.expectEqual(
        std.meta.Tag(PermissionRequestReference).id,
        std.meta.activeTag(valid),
    );
    const expected = [_]u8{
        0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
    } ** 4;
    try std.testing.expectEqualSlices(u8, &expected, &valid.id);

    const absent = try permissionRequestReference(
        std.testing.allocator,
        "{\"questions\":[]}",
    );
    try std.testing.expectEqual(
        std.meta.Tag(PermissionRequestReference).none,
        std.meta.activeTag(absent),
    );
    for ([_][]const u8{
        "{\"permission_request_id\":\"short\",\"questions\":[]}",
        "{\"permission_request_id\":\"0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF\",\"questions\":[]}",
        "{\"permission_request_id\":3,\"questions\":[]}",
        "not-json",
    }) |input| {
        const invalid = try permissionRequestReference(std.testing.allocator, input);
        try std.testing.expectEqual(
            std.meta.Tag(PermissionRequestReference).invalid,
            std.meta.activeTag(invalid),
        );
    }
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
        .success => |body| try std.testing.expectEqualStrings(not_available_sentinel, body),
        .failure => return error.TestExpectedEqual,
    }
}
