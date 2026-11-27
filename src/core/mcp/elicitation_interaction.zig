const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");
const elicitation = @import("elicitation.zig");
const mrtr = @import("mrtr.zig");
const mem_utils = @import("../shared/mem_utils.zig");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const json_decode = @import("../shared/json_decode.zig");
const debug_trace = @import("../shared/debug_trace.zig");

const Allocator = std.mem.Allocator;

pub const Error = elicitation.Error || mrtr.Error || error{
    BrowserOpenFailed,
    InvalidAnswer,
    McpInputTimedOut,
    PresentationLimitExceeded,
    QuestionFailed,
    RetryLimitExceeded,
    UnsupportedInputRequest,
};

pub const Questioner = struct {
    context: *anyopaque,
    ask_fn: *const fn (
        *anyopaque,
        Allocator,
        []const types.QuestionBatchEntry,
        i64,
        ?*const std.atomic.Value(bool),
    ) anyerror!?[][]u8,

    pub fn ask(
        self: Questioner,
        alloc: Allocator,
        entries: []const types.QuestionBatchEntry,
        deadline_ms: i64,
        cancel_flag: ?*const std.atomic.Value(bool),
    ) Error!?[][]u8 {
        return self.ask_fn(self.context, alloc, entries, deadline_ms, cancel_flag) catch |err|
            return if (err == error.McpInputTimedOut)
                error.McpInputTimedOut
            else
                error.QuestionFailed;
    }
};

pub const Browser = struct {
    context: ?*anyopaque = null,
    open_fn: *const fn (?*anyopaque, Allocator, []const u8) anyerror!bool,

    pub fn open(self: Browser, alloc: Allocator, url: []const u8) Error!bool {
        return self.open_fn(self.context, alloc, url) catch return error.BrowserOpenFailed;
    }
};

pub const Options = struct {
    questioner: Questioner,
    browser: Browser,
    capabilities: elicitation.Capabilities,
    max_form_attempts: usize = 8,
    compact_forms: bool = false,
};

/// Who a prompt is from. An MCP server is named in its text. The host is not,
/// so a host prompt never prints a name, even one the origin carries.
const Speaker = struct {
    kind: tool_mcp_runtime.OriginKind,
    server_name: []const u8,

    fn of(origin: tool_mcp_runtime.InputOrigin) Speaker {
        return .{ .kind = origin.kind, .server_name = origin.server_name };
    }

    /// The subject a prompt names: `MCP server {name}`, or `fx`.
    fn subject(self: Speaker, alloc: Allocator, name: []const u8) Allocator.Error![]u8 {
        return switch (self.kind) {
            .mcp_server => alloc.print("MCP server {s}", .{name}),
            .host => alloc.dupe(u8, "fx"),
        };
    }

    /// The opening of a request: `MCP server {name} requests`, or `fx asks`.
    fn request(self: Speaker, alloc: Allocator, name: []const u8) Allocator.Error![]u8 {
        return switch (self.kind) {
            .mcp_server => alloc.print("MCP server {s} requests", .{name}),
            .host => alloc.dupe(u8, "fx asks"),
        };
    }
};

/// What the user hears when fx declines a server's question because it could not take it: fx's reason only,
/// never the form's fields or values. The server's name is made safe for a terminal, so every surface may
/// print the text as it is. Null when the user ended the question, which is no refusal. Owned by `alloc`.
pub fn declinedText(alloc: Allocator, server: []const u8, err: anyerror) Allocator.Error!?[]u8 {
    const reason: []const u8 = switch (err) {
        error.Cancelled => return null,
        error.LimitExceeded, error.MetadataLimitExceeded, error.PresentationLimitExceeded => "the form is larger than fx can show",
        error.RetryLimitExceeded => "the answers did not fit the form after several tries",
        error.SecretField => "the form asks for a secret, which fx never takes in a form",
        // A form that does not parse is one error to the caller, so the words name each way it can fail.
        error.InvalidInputRequired, error.InvalidRequest, error.InvalidSchema, error.UnsupportedSchema => "fx can't show the form: it is invalid, has a field type fx doesn't support, or asks for a secret",
        error.InvalidInputResponses, error.InvalidResponse, error.InvalidAnswer => "the answers did not fit the form",
        error.InvalidUrl, error.InsecureUrl => "the link in it is not a safe web address",
        error.UnsupportedMode, error.UnsupportedAction, error.UnsupportedInputRequest, error.McpInputRequired => "it asks for input that fx can't take here",
        error.McpInputTimedOut, error.Timeout, error.McpOperationTimedOut => "no answer came in time",
        error.BrowserOpenFailed => "fx couldn't open the browser",
        error.QuestionFailed => "fx couldn't show the question",
        error.OutOfMemory => "fx ran out of memory",
        else => "something went wrong",
    };
    const name = (try text_utils.encodeTerminalSafeInline(alloc, server, 160)).bytes;
    return try alloc.print("MCP server '{s}' asked for input, and fx declined it: {s}.", .{ name, reason });
}

pub fn respond(
    alloc: Allocator,
    origin: tool_mcp_runtime.InputOrigin,
    required: tool_mcp_runtime.InputRequired,
    options: Options,
) Error![]u8 {
    const requests = try mrtr.parseRequestJsonForWire(
        alloc,
        required.input_requests_json,
        origin.wire,
        .{},
    );
    defer {
        for (requests) |*request| request.deinit(alloc);
        alloc.free(requests);
    }
    if (requests.len == 0) return error.UnsupportedInputRequest;
    if (required.legacy_url_phase == .await_completion) {
        return answerLegacyUrlCompletion(
            alloc,
            Speaker.of(origin),
            requests,
            required.legacy_url_completion_signal orelse return error.InvalidAnswer,
            origin.deadline_ms,
            options.questioner,
        );
    }

    const responses = try alloc.alloc([]u8, requests.len);
    var response_count: usize = 0;
    errdefer {
        for (responses[0..response_count]) |response| alloc.free(response);
        alloc.free(responses);
    }

    var cancelled = false;
    for (requests) |request| {
        const response_json = if (cancelled)
            try alloc.dupe(u8, "{\"action\":\"cancel\"}")
        else switch (request.payload) {
            .elicitation_create => |elicitation_request| response: {
                if (!options.capabilities.supports(elicitation_request.mode)) return error.UnsupportedMode;
                const result = switch (elicitation_request.mode) {
                    .form => try answerForm(
                        alloc,
                        Speaker.of(origin),
                        elicitation_request,
                        origin.deadline_ms,
                        origin.lifecycle_cancel_flag,
                        options,
                    ),
                    .url => try answerUrl(
                        alloc,
                        Speaker.of(origin),
                        elicitation_request,
                        origin.deadline_ms,
                        origin.lifecycle_cancel_flag,
                        options,
                    ),
                    .unknown => return error.UnsupportedMode,
                };
                if (std.mem.eql(u8, result, "{\"action\":\"cancel\"}")) cancelled = true;
                break :response result;
            },
            else => return error.UnsupportedInputRequest,
        };
        responses[response_count] = response_json;
        response_count += 1;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeByte('{');
    for (requests, responses, 0..) |request, response, index| {
        if (index > 0) try out.writer.writeByte(',');
        try std.json.Stringify.value(request.key, .{}, &out.writer);
        try out.writer.writeByte(':');
        try out.writer.writeAll(response);
    }
    try out.writer.writeByte('}');
    const result = try out.toOwnedSlice();
    for (responses) |response| alloc.free(response);
    alloc.free(responses);
    return result;
}

const FieldValue = struct {
    name: []const u8,
    answered: bool = false,
    /// A host field whose condition does not hold: it has no value, gets no question,
    /// and is left out of the review.
    hidden: bool = false,
    json: ?[]u8,
    /// The menu label of the chosen option of a single-select field. The review shows
    /// it; the server still receives `json`.
    choice_label: ?[]u8 = null,

    fn deinit(self: *FieldValue, alloc: Allocator) void {
        if (self.json) |value| alloc.free(value);
        if (self.choice_label) |label| alloc.free(label);
        self.* = undefined;
    }

    fn hide(self: *FieldValue, alloc: Allocator) void {
        if (self.json) |value| alloc.free(value);
        self.json = null;
        if (self.choice_label) |label| alloc.free(label);
        self.choice_label = null;
        self.answered = false;
        self.hidden = true;
    }
};

const FieldAnswer = union(enum) {
    cancelled,
    declined,
    value: ?[]u8,
    /// A single-select answer with the index of its option, so the review shows that
    /// option's label even when another option has the same value.
    choice: ChosenChoice,
};

const ChosenChoice = struct {
    json: []u8,
    index: usize,
};

const FillAction = enum {
    enter,
    use_default,
    skip,
    cancelled,
};

const FillKind = enum {
    scalar,
    single_select,
    multi_select,

    fn action_label(self: FillKind) []const u8 {
        return switch (self) {
            .scalar => "Enter value",
            .single_select => "Select value",
            .multi_select => "Choose values",
        };
    }
};

const SingleAnswer = union(enum) {
    cancelled,
    invalid,
    /// Owned by the caller with the allocator passed to `ask_single`.
    answer: []u8,
};

fn answerForm(
    alloc: Allocator,
    speaker: Speaker,
    request: elicitation.Request,
    deadline_ms: i64,
    cancel_flag: ?*const std.atomic.Value(bool),
    options: Options,
) Error![]u8 {
    const display_name = try terminalSafeAlloc(alloc, speaker.server_name);
    defer alloc.free(display_name);
    const display_speaker: Speaker = .{ .kind = speaker.kind, .server_name = display_name };
    const display_message = try terminalSafeAlloc(alloc, request.message);
    defer alloc.free(display_message);
    var form = try elicitation.parseFormSchema(
        alloc,
        request.wire,
        request.requested_schema_json orelse return error.InvalidAnswer,
        .{},
    );
    defer form.deinit(alloc);
    const compact = options.compact_forms and form.fields.len == 1 and
        form.fields[0].kind == .single_select and form.fields[0].choices.len <= 3;

    const values = try alloc.alloc(FieldValue, form.fields.len);
    for (form.fields, values) |field, *value| {
        value.* = .{ .name = field.name, .json = null };
    }
    defer {
        for (values) |*value| value.deinit(alloc);
        alloc.free(values);
    }

    var attempt: usize = 0;
    while (attempt < options.max_form_attempts) : (attempt += 1) {
        var cancelled = false;
        var invalid = false;
        for (form.fields, values) |field, *current| {
            if (!try fieldIsShown(alloc, display_speaker, field, values)) {
                current.hide(alloc);
                continue;
            }
            current.hidden = false;
            const answer = answerField(
                alloc,
                display_speaker,
                display_message,
                askedField(display_speaker, field),
                current.*,
                deadline_ms,
                cancel_flag,
                options.questioner,
                compact,
            ) catch |err| switch (err) {
                error.InvalidAnswer => {
                    invalid = true;
                    break;
                },
                else => return err,
            };
            var chosen_index: ?usize = null;
            const value = switch (answer) {
                .declined => return alloc.dupe(u8, "{\"action\":\"decline\"}"),
                .cancelled => {
                    cancelled = true;
                    break;
                },
                .value => |value| value,
                .choice => |chosen| blk: {
                    chosen_index = chosen.index;
                    break :blk chosen.json;
                },
            };
            if (current.json) |previous| alloc.free(previous);
            current.json = value;
            if (current.choice_label) |previous| alloc.free(previous);
            current.choice_label = null;
            current.choice_label = if (chosen_index) |index|
                try choiceLabelAlloc(alloc, field.choices, &.{}, index)
            else if (value) |json|
                try choiceLabelFor(alloc, field, json)
            else
                null;
            current.answered = true;
        }
        if (cancelled) return alloc.dupe(u8, "{\"action\":\"cancel\"}");
        if (invalid or !allFieldsAnswered(values)) {
            if (!try retryInvalidForm(
                alloc,
                display_speaker,
                deadline_ms,
                cancel_flag,
                options.questioner,
            )) return alloc.dupe(u8, "{\"action\":\"cancel\"}");
            continue;
        }

        const response = try buildAcceptedFormResponse(alloc, values);
        var response_owned = true;
        defer if (response_owned) alloc.free(response);
        const action = elicitation.validateResponse(alloc, request, response, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                if (!try retryInvalidForm(
                    alloc,
                    display_speaker,
                    deadline_ms,
                    cancel_flag,
                    options.questioner,
                )) return alloc.dupe(u8, "{\"action\":\"cancel\"}");
                continue;
            },
        };
        std.debug.assert(action == .accept);
        if (compact) {
            response_owned = false;
            return response;
        }

        const review_question = try buildReviewQuestion(
            alloc,
            display_speaker,
            display_message,
            form,
            values,
        );
        defer alloc.free(review_question);
        const review_options = [_]types.QuestionOption{
            .{ .label = "Submit" },
            .{ .label = "Edit" },
            .{ .label = "Decline" },
            .{ .label = "Cancel" },
        };
        const review_answer = switch (try ask_single(
            alloc,
            review_question,
            &review_options,
            .none,
            deadline_ms,
            cancel_flag,
            options.questioner,
        )) {
            .cancelled => return alloc.dupe(u8, "{\"action\":\"cancel\"}"),
            .invalid => continue,
            .answer => |decision_text| decision_text,
        };
        defer alloc.free(review_answer);
        if (std.mem.eql(u8, review_answer, "Submit")) {
            response_owned = false;
            return response;
        }
        if (std.mem.eql(u8, review_answer, "Decline")) {
            return alloc.dupe(u8, "{\"action\":\"decline\"}");
        }
        if (std.mem.eql(u8, review_answer, "Cancel")) {
            return alloc.dupe(u8, "{\"action\":\"cancel\"}");
        }
        if (!std.mem.eql(u8, review_answer, "Edit")) continue;
    }
    return error.RetryLimitExceeded;
}

/// Whether a field is asked now. Only a host form reads `x-fx-shown-when`: its field is
/// shown while the named field holds the condition's string. Every other field is shown.
fn fieldIsShown(
    alloc: Allocator,
    speaker: Speaker,
    field: elicitation.Field,
    values: []const FieldValue,
) Error!bool {
    if (speaker.kind != .host) return true;
    const condition = field.shown_when orelse return true;
    for (values) |value| {
        if (!std.mem.eql(u8, value.name, condition.field)) continue;
        const json = value.json orelse return false;
        const expected = try stringifyString(alloc, condition.value);
        defer alloc.free(expected);
        return std.mem.eql(u8, json, expected);
    }
    return false;
}

/// A shown host field with a condition is required, so its question has no Skip step.
fn askedField(speaker: Speaker, field: elicitation.Field) elicitation.Field {
    var asked = field;
    if (speaker.kind == .host and field.shown_when != null) asked.required = true;
    return asked;
}

fn answerField(
    alloc: Allocator,
    speaker: Speaker,
    request_message: []const u8,
    field: elicitation.Field,
    current: FieldValue,
    deadline_ms: i64,
    cancel_flag: ?*const std.atomic.Value(bool),
    questioner: Questioner,
    compact: bool,
) Error!FieldAnswer {
    if (compact and !current.answered) {
        return answerCompactField(alloc, speaker, request_message, field, deadline_ms, cancel_flag, questioner);
    }
    if (current.answered) {
        const keep = try askToKeepCurrentValue(
            alloc,
            speaker,
            field,
            current.choice_label,
            current.json,
            deadline_ms,
            cancel_flag,
            questioner,
        );
        switch (keep) {
            .cancelled => return .cancelled,
            .edit => {},
            .keep => return .{ .value = if (current.json) |json|
                try alloc.dupe(u8, json)
            else
                null },
        }
    }
    if (field.kind == .multi_select) {
        return answerMultiSelect(
            alloc,
            speaker,
            request_message,
            field,
            deadline_ms,
            cancel_flag,
            questioner,
        );
    }

    const display_name = try terminalSafeAlloc(alloc, field.displayName());
    defer alloc.free(display_name);
    const display_description = if (field.description) |description|
        try terminalSafeAlloc(alloc, description)
    else
        null;
    defer if (display_description) |description| alloc.free(description);
    const opening = try speaker.request(alloc, speaker.server_name);
    defer alloc.free(opening);
    const question = if (display_description) |description|
        try alloc.print(
            "{s} {s}{s} — {s}\nReason: {s}",
            .{
                opening,
                display_name,
                if (field.required) " (required)" else " (optional)",
                description,
                request_message,
            },
        )
    else
        try alloc.print(
            "{s} {s}{s}\nReason: {s}",
            .{
                opening,
                display_name,
                if (field.required) " (required)" else " (optional)",
                request_message,
            },
        );
    defer alloc.free(question);
    if (field.default_json != null or !field.required) {
        const fill_kind: FillKind = if (field.kind == .single_select) .single_select else .scalar;
        switch (try choose_fill_action(
            alloc,
            speaker,
            request_message,
            display_name,
            field,
            fill_kind,
            deadline_ms,
            cancel_flag,
            questioner,
        )) {
            .enter => {},
            .use_default => return .{ .value = try alloc.dupe(u8, field.default_json.?) },
            .skip => return .{ .value = null },
            .cancelled => return .cancelled,
        }
    }

    var option_list: std.ArrayList(types.QuestionOption) = .empty;
    defer {
        if (field.kind == .single_select) {
            for (option_list.items) |option| {
                alloc.free(@constCast(option.label));
                if (option.description) |description| alloc.free(@constCast(description));
            }
        }
        option_list.deinit(alloc);
    }
    switch (field.kind) {
        .boolean => {},
        .single_select => for (field.choices, 0..) |choice, choice_index| {
            const label = try choiceLabelAlloc(alloc, field.choices, &.{}, choice_index);
            var owns_label = true;
            errdefer if (owns_label) alloc.free(label);
            const description = if (choice.description) |raw| blk: {
                const safe = try terminalSafeAlloc(alloc, raw);
                break :blk safe;
            } else null;
            var owns_description = description != null;
            errdefer if (owns_description) alloc.free(@constCast(description.?));
            try option_list.append(alloc, .{ .label = label, .description = description });
            owns_label = false;
            owns_description = false;
        },
        .string, .number, .integer => {},
        .multi_select => unreachable,
    }
    if (field.kind == .single_select) {
        return singleSelectAnswer(alloc, field, question, option_list.items, deadline_ms, cancel_flag, questioner);
    }
    const boolean_options = [_]types.QuestionOption{
        .{ .label = "True" },
        .{ .label = "False" },
    };
    const question_options: []const types.QuestionOption = switch (field.kind) {
        .boolean => &boolean_options,
        .single_select => unreachable,
        .string, .number, .integer => &.{},
        .multi_select => unreachable,
    };
    const answer = try ask_one(
        alloc,
        question,
        question_options,
        deadline_ms,
        cancel_flag,
        questioner,
    ) orelse return .cancelled;
    defer alloc.free(answer);

    const result: []u8 = switch (field.kind) {
        .string => try stringifyString(alloc, answer),
        .number, .integer => try validateNumberAnswer(alloc, answer),
        .boolean => if (std.mem.eql(u8, answer, "True"))
            try alloc.dupe(u8, "true")
        else if (std.mem.eql(u8, answer, "False"))
            try alloc.dupe(u8, "false")
        else
            return error.InvalidAnswer,
        .single_select => unreachable,
        .multi_select => unreachable,
    };
    errdefer alloc.free(result);
    elicitation.validateFieldJson(alloc, field, result, .{}) catch |err| switch (err) {
        error.InvalidResponse => return error.InvalidAnswer,
        else => return err,
    };
    return .{ .value = result };
}

// These local actions never share a namespace with server-supplied values.
const CompactAction = union(enum) {
    value: ?[]const u8,
    decline,
    cancel,
};

fn answerCompactField(
    alloc: Allocator,
    speaker: Speaker,
    message: []const u8,
    field: elicitation.Field,
    deadline_ms: i64,
    cancel_flag: ?*const std.atomic.Value(bool),
    questioner: Questioner,
) Error!FieldAnswer {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer mem_utils.deinit_arena(arena);
    const temp = arena.allocator();
    const display_name = try terminalSafeAlloc(temp, field.displayName());
    const description = try terminalSafeAlloc(temp, field.description orelse "");
    const opening = try speaker.request(temp, speaker.server_name);
    const question = try temp.print(
        "{s} {s}{s}\n{s}\nReason: {s}\nChoose an option to submit.",
        .{ opening, display_name, if (field.required) " (required)" else " (optional)", description, message },
    );
    var choices: std.ArrayList(types.QuestionOption) = .empty;
    var actions: std.ArrayList(CompactAction) = .empty;
    std.debug.assert(field.kind == .single_select);
    var controls: std.ArrayList([]const u8) = .empty;
    try controls.appendSlice(temp, &.{ "Decline", "Cancel" });
    if (field.default_json != null) try controls.append(temp, "Use default");
    if (!field.required) try controls.append(temp, "Skip");
    for (field.choices, 0..) |choice, index| {
        try choices.append(temp, .{
            .label = try choiceLabelAlloc(temp, field.choices, controls.items, index),
            .description = if (choice.description) |desc| try terminalSafeAlloc(temp, desc) else null,
        });
        try actions.append(temp, .{ .value = try stringifyString(temp, choice.value) });
    }
    if (field.default_json) |default| {
        try choices.append(temp, .{ .label = "Use default", .description = try terminalSafeAlloc(temp, default) });
        try actions.append(temp, .{ .value = default });
    }
    if (!field.required) {
        try choices.append(temp, .{ .label = "Skip", .description = "Submit without this optional field" });
        try actions.append(temp, .{ .value = null });
    }
    try choices.appendSlice(temp, &.{ .{ .label = "Decline" }, .{ .label = "Cancel" } });
    try actions.appendSlice(temp, &.{ .decline, .cancel });
    const answer = switch (try ask_single(
        temp,
        question,
        choices.items,
        .choice,
        deadline_ms,
        cancel_flag,
        questioner,
    )) {
        .cancelled => return .cancelled,
        .invalid => return error.InvalidAnswer,
        .answer => |answer| answer,
    };
    const parsed = json_decode.parseFromSlice(struct {
        option: usize,
    }, temp, answer, .{}) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidAnswer;
    const index = parsed.value.option;
    if (index >= actions.items.len) return error.InvalidAnswer;
    const json = switch (actions.items[index]) {
        .decline => return .declined,
        .cancel => return .cancelled,
        .value => |value| value,
    };
    if (json) |value| {
        elicitation.validateFieldJson(temp, field, value, .{}) catch |err| switch (err) {
            error.InvalidResponse => return error.InvalidAnswer,
            else => return err,
        };
        return .{ .value = try alloc.dupe(u8, value) };
    }
    return .{ .value = null };
}

const KeepCurrentDecision = enum { keep, edit, cancelled };

fn askToKeepCurrentValue(
    alloc: Allocator,
    speaker: Speaker,
    field: elicitation.Field,
    current_label: ?[]const u8,
    current_json: ?[]const u8,
    deadline_ms: i64,
    cancel_flag: ?*const std.atomic.Value(bool),
    questioner: Questioner,
) Error!KeepCurrentDecision {
    const display_name = try terminalSafeAlloc(alloc, field.displayName());
    defer alloc.free(display_name);
    // A choice label is already terminal-safe, so it is shown as it is.
    const display_value = if (current_label) |label|
        try alloc.dupe(u8, label)
    else if (current_json) |json|
        try terminalSafeAlloc(alloc, json)
    else
        try alloc.dupe(u8, "(skipped)");
    defer alloc.free(display_value);
    const who = try speaker.subject(alloc, speaker.server_name);
    defer alloc.free(who);
    const question = try alloc.print(
        "{s}: current value for {s} is {s}. Keep it or edit it?",
        .{ who, display_name, display_value },
    );
    defer alloc.free(question);
    const options = [_]types.QuestionOption{
        .{ .label = "Keep current" },
        .{ .label = "Edit value" },
        .{ .label = "Cancel" },
    };
    const answer = try ask_one(
        alloc,
        question,
        &options,
        deadline_ms,
        cancel_flag,
        questioner,
    ) orelse return .cancelled;
    defer alloc.free(answer);
    if (std.mem.eql(u8, answer, "Keep current")) return .keep;
    if (std.mem.eql(u8, answer, "Edit value")) return .edit;
    if (std.mem.eql(u8, answer, "Cancel")) return .cancelled;
    return error.InvalidAnswer;
}

fn allFieldsAnswered(values: []const FieldValue) bool {
    for (values) |value| if (!value.hidden and !value.answered) return false;
    return true;
}

fn answerMultiSelect(
    alloc: Allocator,
    speaker: Speaker,
    request_message: []const u8,
    field: elicitation.Field,
    deadline_ms: i64,
    cancel_flag: ?*const std.atomic.Value(bool),
    questioner: Questioner,
) Error!FieldAnswer {
    const display_name = try terminalSafeAlloc(alloc, field.displayName());
    defer alloc.free(display_name);
    if (field.default_json != null or !field.required) {
        switch (try choose_fill_action(
            alloc,
            speaker,
            request_message,
            display_name,
            field,
            .multi_select,
            deadline_ms,
            cancel_flag,
            questioner,
        )) {
            .enter => {},
            .use_default => return .{ .value = try alloc.dupe(u8, field.default_json.?) },
            .skip => return .{ .value = null },
            .cancelled => return .cancelled,
        }
    }

    const who = try speaker.subject(alloc, speaker.server_name);
    defer alloc.free(who);
    var selected: std.ArrayList([]const u8) = .empty;
    defer selected.deinit(alloc);
    for (field.choices) |choice| {
        const display_title = try terminalSafeAlloc(alloc, choice.title);
        defer alloc.free(display_title);
        const question = try alloc.print(
            "{s}: include {s} in {s}?\nReason: {s}",
            .{ who, display_title, display_name, request_message },
        );
        defer alloc.free(question);
        const choice_options = [_]types.QuestionOption{
            .{ .label = "Include" },
            .{ .label = "Exclude" },
        };
        const answer = try ask_one(
            alloc,
            question,
            &choice_options,
            deadline_ms,
            cancel_flag,
            questioner,
        ) orelse return .cancelled;
        defer alloc.free(answer);
        if (!std.mem.eql(u8, answer, "Include") and !std.mem.eql(u8, answer, "Exclude")) {
            return error.InvalidAnswer;
        }
        if (std.mem.eql(u8, answer, "Include")) try selected.append(alloc, choice.value);
    }
    if (field.min_items) |minimum| if (selected.items.len < minimum) return error.InvalidAnswer;
    if (field.max_items) |maximum| if (selected.items.len > maximum) return error.InvalidAnswer;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeByte('[');
    for (selected.items, 0..) |value, index| {
        if (index > 0) try out.writer.writeByte(',');
        try std.json.Stringify.value(value, .{}, &out.writer);
    }
    try out.writer.writeByte(']');
    return .{ .value = try out.toOwnedSlice() };
}

fn choose_fill_action(
    alloc: Allocator,
    speaker: Speaker,
    request_message: []const u8,
    display_name: []const u8,
    field: elicitation.Field,
    kind: FillKind,
    deadline_ms: i64,
    cancel_flag: ?*const std.atomic.Value(bool),
    questioner: Questioner,
) Error!FillAction {
    const who = try speaker.subject(alloc, speaker.server_name);
    defer alloc.free(who);
    const question = try alloc.print(
        "{s}: choose how to fill {s}{s}.\nReason: {s}",
        .{
            who,
            display_name,
            if (field.required) " (required)" else " (optional)",
            request_message,
        },
    );
    defer alloc.free(question);

    var options: [3]types.QuestionOption = undefined;
    var option_count: usize = 0;
    if (kind == .multi_select and field.default_json != null) {
        options[option_count] = .{ .label = "Use default" };
        option_count += 1;
    }
    options[option_count] = .{ .label = kind.action_label() };
    option_count += 1;
    if (kind != .multi_select and field.default_json != null) {
        options[option_count] = .{ .label = "Use default" };
        option_count += 1;
    }
    if (!field.required) {
        options[option_count] = .{ .label = "Skip" };
        option_count += 1;
    }

    const answer = try ask_one(
        alloc,
        question,
        options[0..option_count],
        deadline_ms,
        cancel_flag,
        questioner,
    ) orelse return .cancelled;
    defer alloc.free(answer);
    if (std.mem.eql(u8, answer, kind.action_label())) return .enter;
    if (std.mem.eql(u8, answer, "Use default") and field.default_json != null) {
        return .use_default;
    }
    if (std.mem.eql(u8, answer, "Skip") and !field.required) return .skip;
    return error.InvalidAnswer;
}

fn retryInvalidForm(
    alloc: Allocator,
    speaker: Speaker,
    deadline_ms: i64,
    cancel_flag: ?*const std.atomic.Value(bool),
    questioner: Questioner,
) Error!bool {
    const who = try speaker.subject(alloc, speaker.server_name);
    defer alloc.free(who);
    const question = switch (speaker.kind) {
        .host => try alloc.dupe(u8, "Your answer did not fit the question. Edit the form or cancel?"),
        .mcp_server => try alloc.print(
            "A response for {s} did not satisfy the requested form constraints. Edit the form or cancel?",
            .{who},
        ),
    };
    defer alloc.free(question);
    const options = [_]types.QuestionOption{
        .{ .label = "Edit" },
        .{ .label = "Cancel" },
    };
    const answer = switch (try ask_single(
        alloc,
        question,
        &options,
        .none,
        deadline_ms,
        cancel_flag,
        questioner,
    )) {
        .cancelled, .invalid => return false,
        .answer => |answer| answer,
    };
    defer alloc.free(answer);
    if (std.mem.eql(u8, answer, "Edit")) return true;
    if (std.mem.eql(u8, answer, "Cancel")) return false;
    return false;
}

fn buildAcceptedFormResponse(alloc: Allocator, values: []const FieldValue) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"action\":\"accept\",\"content\":{");
    var wrote = false;
    for (values) |value| {
        const json = value.json orelse continue;
        if (wrote) try out.writer.writeByte(',');
        try std.json.Stringify.value(value.name, .{}, &out.writer);
        try out.writer.writeByte(':');
        try out.writer.writeAll(json);
        wrote = true;
    }
    try out.writer.writeAll("}}");
    return out.toOwnedSlice();
}

/// Builds the only user-visible representation of entered form values. The
/// caller passes it directly to the local question adapter and frees it after
/// the decision; it is never retained in runtime, status, or model state.
fn buildReviewQuestion(
    alloc: Allocator,
    speaker: Speaker,
    message: []const u8,
    form: elicitation.FormSchema,
    values: []const FieldValue,
) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const who = try speaker.subject(alloc, speaker.server_name);
    defer alloc.free(who);
    try out.writer.print(
        "Review the completed form requested by {s}.\nReason: {s}\nCurrent values:\n",
        .{ who, message },
    );
    for (values, 0..) |value, index| {
        if (value.hidden) continue;
        const label = if (index < form.fields.len) form.fields[index].displayName() else value.name;
        const display_label = try terminalSafeAlloc(alloc, label);
        defer alloc.free(display_label);
        try out.writer.print("- {s}: ", .{display_label});
        if (value.choice_label) |chosen| {
            try out.writer.writeAll(chosen);
        } else if (value.json) |json| {
            const display_json = try terminalSafeAlloc(alloc, json);
            defer alloc.free(display_json);
            try out.writer.writeAll(display_json);
        } else {
            try out.writer.writeAll("(skipped)");
        }
        try out.writer.writeByte('\n');
    }
    try out.writer.writeAll("Choose Submit, Edit, Decline, or Cancel.");
    return out.toOwnedSlice();
}

fn stringifyString(alloc: Allocator, value: []const u8) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

/// The menu label of the option whose value is `json`, for a single-select field. The
/// review shows that label, so a repeated title keeps its value. A value that matches
/// no option, such as typed text, has no label.
fn choiceLabelFor(alloc: Allocator, field: elicitation.Field, json: []const u8) Error!?[]u8 {
    if (field.kind != .single_select) return null;
    const parsed = json_decode.parseFromSlice([]const u8, alloc, json, .{}) catch |err|
        return if (err == error.OutOfMemory) error.OutOfMemory else null;
    defer parsed.deinit();
    for (field.choices, 0..) |choice, index| {
        if (std.mem.eql(u8, parsed.value, choice.value)) {
            return try choiceLabelAlloc(alloc, field.choices, &.{}, index);
        }
    }
    return null;
}

fn validateNumberAnswer(
    alloc: Allocator,
    answer: []const u8,
) Error![]u8 {
    const trimmed = std.mem.trim(u8, answer, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidAnswer;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, trimmed, .{
        .parse_numbers = false,
    }) catch return error.InvalidAnswer;
    defer parsed.deinit();
    const valid = switch (parsed.value) {
        .integer, .float, .number_string => true,
        else => false,
    };
    if (!valid) return error.InvalidAnswer;
    // Constraint and integer checks run immediately afterward in the pure
    // elicitation core, which retains the original JSON number lexeme.
    return alloc.dupe(u8, trimmed);
}

/// The most answers one single-select question takes while each typed label matches
/// more than one choice. After that the answer is invalid.
const ambiguous_choice_attempts = 3;
const ambiguous_choice_notice = "That matches more than one choice. Type its number.";

/// Asks a single-select field and returns the chosen value as JSON, with the index of
/// the chosen option.
fn singleSelectAnswer(
    alloc: Allocator,
    field: elicitation.Field,
    question: []const u8,
    options: []const types.QuestionOption,
    deadline_ms: i64,
    cancel_flag: ?*const std.atomic.Value(bool),
    questioner: Questioner,
) Error!FieldAnswer {
    const index = (try askChoiceIndex(alloc, question, options, deadline_ms, cancel_flag, questioner)) orelse
        return .cancelled;
    const value = try stringifyString(alloc, field.choices[index].value);
    errdefer alloc.free(value);
    elicitation.validateFieldJson(alloc, field, value, .{}) catch |err| switch (err) {
        error.InvalidResponse => return error.InvalidAnswer,
        else => return err,
    };
    return .{ .choice = .{ .json = value, .index = index } };
}

/// Asks one single-select question and returns the index of the chosen option, or null
/// when the user cancels. A surface answers with JSON only: `{"option":N}` names option N,
/// and `{"value":S}` carries typed text S, which names the option whose label equals S.
/// Text that equals several labels asks again with a notice.
fn askChoiceIndex(
    alloc: Allocator,
    question: []const u8,
    options: []const types.QuestionOption,
    deadline_ms: i64,
    cancel_flag: ?*const std.atomic.Value(bool),
    questioner: Questioner,
) Error!?usize {
    var notice = false;
    for (0..ambiguous_choice_attempts) |attempt| {
        const asked = if (notice)
            try alloc.print("{s}\n{s}", .{ question, ambiguous_choice_notice })
        else
            try alloc.dupe(u8, question);
        defer alloc.free(asked);
        const answer = switch (try ask_single(alloc, asked, options, .choice, deadline_ms, cancel_flag, questioner)) {
            .cancelled => return null,
            .invalid => return error.InvalidAnswer,
            .answer => |answer| answer,
        };
        defer alloc.free(answer);
        switch (try choiceAnswerIndex(alloc, options, answer)) {
            .none => return error.InvalidAnswer,
            .one => |index| return index,
            .many => {
                debug_trace.logf(
                    "mcp",
                    "mcp elicitation dropped an ambiguous typed choice answer: it matched more than one choice attempt={d} of {d}",
                    .{ attempt + 1, ambiguous_choice_attempts },
                );
                notice = true;
            },
        }
    }
    debug_trace.logf(
        "mcp",
        "mcp elicitation dropped the typed choice answer: every answer matched more than one choice",
        .{},
    );
    return error.InvalidAnswer;
}

const ChoiceAnswer = union(enum) {
    none,
    one: usize,
    many,
};

/// The answer to a single-select question: `{"option":N}` or `{"value":S}`, and nothing else.
const ChoiceWire = struct {
    option: ?usize = null,
    value: ?[]const u8 = null,
};

fn choiceAnswerIndex(
    alloc: Allocator,
    options: []const types.QuestionOption,
    answer: []const u8,
) Error!ChoiceAnswer {
    const parsed = json_decode.parseFromSlice(ChoiceWire, alloc, answer, .{}) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.InvalidAnswer;
    };
    defer parsed.deinit();
    if (parsed.value.option) |index| {
        if (parsed.value.value != null) return error.InvalidAnswer;
        return if (index < options.len) .{ .one = index } else .none;
    }
    const text = parsed.value.value orelse return error.InvalidAnswer;
    return labelMatch(options, text);
}

fn labelMatch(options: []const types.QuestionOption, answer: []const u8) ChoiceAnswer {
    var found: ?usize = null;
    for (options, 0..) |option, index| {
        if (!std.mem.eql(u8, answer, option.label)) continue;
        if (found != null) return .many;
        found = index;
    }
    const index = found orelse return .none;
    return .{ .one = index };
}

/// The text a single-select choice shows and answers with: its title, with no
/// number. The surface that prints the menu adds the number. A title that another
/// choice, or a control in the same menu (`reserved`), also shows gets the choice's
/// value in parentheses, so each answer names one option.
fn choiceLabelAlloc(
    alloc: Allocator,
    choices: []const elicitation.Choice,
    reserved: []const []const u8,
    choice_index: usize,
) Error![]u8 {
    const title = try terminalSafeAlloc(alloc, choices[choice_index].title);
    defer alloc.free(title);
    if (!try titleRepeats(alloc, choices, reserved, choice_index, title)) return alloc.dupe(u8, title);
    const value = try terminalSafeAlloc(alloc, choices[choice_index].value);
    defer alloc.free(value);
    return alloc.print("{s} ({s})", .{ title, value });
}

/// Whether a control or another choice shows `title` once terminal-safe escaping is applied.
fn titleRepeats(
    alloc: Allocator,
    choices: []const elicitation.Choice,
    reserved: []const []const u8,
    choice_index: usize,
    title: []const u8,
) Error!bool {
    for (reserved) |control| {
        if (std.mem.eql(u8, control, title)) return true;
    }
    for (choices, 0..) |other, other_index| {
        if (other_index == choice_index) continue;
        const other_title = try terminalSafeAlloc(alloc, other.title);
        defer alloc.free(other_title);
        if (std.mem.eql(u8, other_title, title)) return true;
    }
    return false;
}

fn answerUrl(
    alloc: Allocator,
    speaker: Speaker,
    request: elicitation.Request,
    deadline_ms: i64,
    cancel_flag: ?*const std.atomic.Value(bool),
    options: Options,
) Error![]u8 {
    const url = request.url orelse return error.InvalidAnswer;
    const host = request.url_host orelse return error.InvalidAnswer;
    const display_name = try terminalSafeAlloc(alloc, speaker.server_name);
    defer alloc.free(display_name);
    const opening = try speaker.request(alloc, display_name);
    defer alloc.free(opening);
    const display_host = try terminalSafeAlloc(alloc, host);
    defer alloc.free(display_host);
    const display_url = try terminalSafeAlloc(alloc, url);
    defer alloc.free(display_url);
    const warning = switch (elicitation.classifyHost(host)) {
        .ordinary => "",
        .punycode => "\nWarning: This host uses Punycode and may disguise its destination.",
        .non_ascii => "\nWarning: This host contains non-ASCII characters and may be visually ambiguous.",
    };
    const question = try alloc.print(
        "{s} an external browser action. Target host: {s}\nComplete URL: {s}{s}\nOpen it? fx will not fetch this URL or see browser contents.",
        .{ opening, display_host, display_url, warning },
    );
    defer alloc.free(question);
    const consent_options = [_]types.QuestionOption{
        .{ .label = "Open URL" },
        .{ .label = "Decline" },
    };
    const answer = try ask_one(
        alloc,
        question,
        &consent_options,
        deadline_ms,
        cancel_flag,
        options.questioner,
    ) orelse {
        return alloc.dupe(u8, "{\"action\":\"cancel\"}");
    };
    defer alloc.free(answer);
    if (std.mem.eql(u8, answer, "Decline")) {
        return alloc.dupe(u8, "{\"action\":\"decline\"}");
    }
    if (!std.mem.eql(u8, answer, "Open URL")) return error.InvalidAnswer;

    if (try options.browser.open(alloc, url)) {
        // Accept records consent only. The originating MCP operation decides
        // completion when it is retried with this response.
        return alloc.dupe(u8, "{\"action\":\"accept\"}");
    }

    const failure_question = try alloc.print(
        "fx could not open the browser for {s}. The URL was not fetched. Continue manually, retry the browser, or cancel?",
        .{display_host},
    );
    defer alloc.free(failure_question);
    const failure_options = [_]types.QuestionOption{
        .{ .label = "Continue manually" },
        .{ .label = "Retry browser" },
        .{ .label = "Cancel" },
    };
    var retries: usize = 0;
    while (retries < 3) : (retries += 1) {
        const decision = switch (try ask_single(
            alloc,
            failure_question,
            &failure_options,
            .none,
            deadline_ms,
            cancel_flag,
            options.questioner,
        )) {
            .cancelled => return alloc.dupe(u8, "{\"action\":\"cancel\"}"),
            .invalid => continue,
            .answer => |decision_text| decision_text,
        };
        defer alloc.free(decision);
        if (std.mem.eql(u8, decision, "Continue manually")) {
            return alloc.dupe(u8, "{\"action\":\"accept\"}");
        }
        if (std.mem.eql(u8, decision, "Cancel")) {
            return alloc.dupe(u8, "{\"action\":\"cancel\"}");
        }
        if (std.mem.eql(u8, decision, "Retry browser") and try options.browser.open(alloc, url)) {
            return alloc.dupe(u8, "{\"action\":\"accept\"}");
        }
    }
    return alloc.dupe(u8, "{\"action\":\"cancel\"}");
}

fn answerLegacyUrlCompletion(
    alloc: Allocator,
    speaker: Speaker,
    requests: []const mrtr.InputRequest,
    signal: *const tool_mcp_runtime.LegacyUrlCompletionSignal,
    deadline_ms: i64,
    questioner: Questioner,
) Error![]u8 {
    for (requests) |request| {
        if (request.payload != .elicitation_create or
            request.payload.elicitation_create.mode != .url)
        {
            return error.UnsupportedInputRequest;
        }
    }
    if (signal.status.load(.acquire) == .completed) {
        return renderUniformResponses(alloc, requests, .accept);
    }
    if (signal.status.load(.acquire) == .cancelled) {
        return renderUniformResponses(alloc, requests, .cancel);
    }

    const display_name = try terminalSafeAlloc(alloc, speaker.server_name);
    defer alloc.free(display_name);
    const who = try speaker.subject(alloc, display_name);
    defer alloc.free(who);
    const question = try alloc.print(
        "Complete the browser flow requested by {s}. fx will continue automatically if the server confirms every URL request. Otherwise choose I completed it / Retry, or Cancel.",
        .{who},
    );
    defer alloc.free(question);
    const completion_options = [_]types.QuestionOption{
        .{ .label = "I completed it / Retry" },
        .{ .label = "Cancel" },
    };
    const answer_result = try ask_single(
        alloc,
        question,
        &completion_options,
        .none,
        deadline_ms,
        &signal.wake,
        questioner,
    );
    if (signal.status.load(.acquire) == .completed) {
        return renderUniformResponses(alloc, requests, .accept);
    }
    const answer = switch (answer_result) {
        .cancelled => return renderUniformResponses(alloc, requests, .cancel),
        .invalid => return error.InvalidAnswer,
        .answer => |answer| answer,
    };
    defer alloc.free(answer);
    if (std.mem.eql(u8, answer, "I completed it / Retry")) {
        return renderUniformResponses(alloc, requests, .accept);
    }
    if (std.mem.eql(u8, answer, "Cancel")) {
        return renderUniformResponses(alloc, requests, .cancel);
    }
    return error.InvalidAnswer;
}

fn renderUniformResponses(
    alloc: Allocator,
    requests: []const mrtr.InputRequest,
    action: elicitation.Action,
) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeByte('{');
    for (requests, 0..) |request, index| {
        if (index > 0) try out.writer.writeByte(',');
        try std.json.Stringify.value(request.key, .{}, &out.writer);
        try out.writer.writeAll(switch (action) {
            .accept => ":{\"action\":\"accept\"}",
            .cancel => ":{\"action\":\"cancel\"}",
            .decline, .unknown => unreachable,
        });
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn terminalSafeAlloc(alloc: Allocator, raw: []const u8) Error![]u8 {
    const max_encoded_bytes = std.math.mul(usize, raw.len, 12) catch
        return error.PresentationLimitExceeded;
    var encoded = try text_utils.encodeTerminalSafe(alloc, raw, max_encoded_bytes);
    errdefer encoded.deinit(alloc);
    if (encoded.truncated) return error.PresentationLimitExceeded;
    return encoded.bytes;
}

fn ask_one(
    alloc: Allocator,
    question: []const u8,
    options: []const types.QuestionOption,
    deadline_ms: i64,
    cancel_flag: ?*const std.atomic.Value(bool),
    questioner: Questioner,
) Error!?[]u8 {
    return switch (try ask_single(
        alloc,
        question,
        options,
        .none,
        deadline_ms,
        cancel_flag,
        questioner,
    )) {
        .cancelled => null,
        .invalid => error.InvalidAnswer,
        .answer => |answer| answer,
    };
}

fn ask_single(
    alloc: Allocator,
    question: []const u8,
    options: []const types.QuestionOption,
    submission: @FieldType(types.QuestionBatchEntry, "submission"),
    deadline_ms: i64,
    cancel_flag: ?*const std.atomic.Value(bool),
    questioner: Questioner,
) Error!SingleAnswer {
    const entries = [_]types.QuestionBatchEntry{.{
        .question = question,
        .options = options,
        .submission = submission,
    }};
    const answers = try questioner.ask(alloc, &entries, deadline_ms, cancel_flag) orelse
        return .cancelled;
    if (answers.len != 1) {
        for (answers) |answer| alloc.free(answer);
        alloc.free(answers);
        return .invalid;
    }
    const answer = answers[0];
    alloc.free(answers);
    return .{ .answer = answer };
}

test "an answer that does not fit a form is worded for the host, and an MCP server's keeps its text" {
    const alloc = std.testing.allocator;
    var host = Fixture{
        .answers = &.{"Cancel"},
        .expected_question = "Your answer did not fit the question. Edit the form or cancel?",
    };
    try std.testing.expect(!try retryInvalidForm(alloc, .{ .kind = .host, .server_name = "" }, std.math.maxInt(i64), null, host.questioner()));
    try std.testing.expect(host.saw_expected_question);

    var mcp = Fixture{
        .answers = &.{"Cancel"},
        .expected_question = "A response for MCP server Profile did not satisfy the requested form constraints. Edit the form or cancel?",
    };
    try std.testing.expect(!try retryInvalidForm(alloc, .{ .kind = .mcp_server, .server_name = "Profile" }, std.math.maxInt(i64), null, mcp.questioner()));
    try std.testing.expect(mcp.saw_expected_question);
}

test "interaction review shows every validated current value before submission" {
    const alloc = std.testing.allocator;
    var fixture = Fixture{
        .answers = &.{
            "A1",                  "Edit",
            "Ada",                 "0.5",
            "42",                  "True",
            "{\"value\":\"Red\"}", "Include",
            "Exclude",             "Edit",
            "Edit value",          "Bea",
            "Keep current",        "Keep current",
            "Keep current",        "Keep current",
            "Edit value",          "Exclude",
            "Include",             "Submit",
        },
        .expected_review_values = &.{
            "- name: \"Bea\"",
            "- ratio: 0.5",
            "- age: 42",
            "- active: true",
            "- color: Red",
            "- tags: [\"b\"]",
        },
    };
    const required = @import("../tooling/tool_mcp_runtime.zig").InputRequired{
        .input_requests_json =
        \\{"form":{"method":"elicitation/create","params":{"message":"Profile","requestedSchema":{"type":"object","properties":{"name":{"type":"string","minLength":3},"ratio":{"type":"number","minimum":0,"maximum":1},"age":{"type":"integer","minimum":18},"active":{"type":"boolean"},"color":{"type":"string","oneOf":[{"const":"red","title":"Red"},{"const":"blue","title":"Blue"}]},"tags":{"type":"array","items":{"type":"string","anyOf":[{"const":"a","title":"A"},{"const":"b","title":"B"}]},"minItems":1}},"required":["name","ratio","age","active","color","tags"]}}}}
        ,
    };
    const response = try respond(alloc, Fixture.origin(), required, .{
        .questioner = fixture.questioner(),
        .browser = fixture.browser(),
        .capabilities = .{ .form = true, .url = true },
        .compact_forms = true,
    });
    defer alloc.free(response);
    try std.testing.expectEqualStrings(
        "{\"form\":{\"action\":\"accept\",\"content\":{\"name\":\"Bea\",\"ratio\":0.5,\"age\":42,\"active\":true,\"color\":\"red\",\"tags\":[\"b\"]}}}",
        response,
    );
    try std.testing.expect(fixture.review_contained_values);
}

test "interaction review shows the enumNames title of an enum choice" {
    const alloc = std.testing.allocator;
    var fixture = Fixture{
        .answers = &.{ "{\"value\":\"Small\"}", "Submit" },
        .expected_review_values = &.{"- Size: Small"},
    };
    const required = @import("../tooling/tool_mcp_runtime.zig").InputRequired{
        .input_requests_json =
        \\{"form":{"method":"elicitation/create","params":{"message":"Size","requestedSchema":{"type":"object","properties":{"size":{"type":"string","title":"Size","enum":["s","m"],"enumNames":["Small","Medium"]}},"required":["size"]}}}}
        ,
    };
    const response = try respond(alloc, Fixture.origin(), required, .{
        .questioner = fixture.questioner(),
        .browser = fixture.browser(),
        .capabilities = .{ .form = true },
    });
    defer alloc.free(response);
    try std.testing.expectEqualStrings(
        "{\"form\":{\"action\":\"accept\",\"content\":{\"size\":\"s\"}}}",
        response,
    );
    try std.testing.expect(fixture.review_contained_values);
}

test "titled choices have no number and answer by title, and a repeated title keeps its value" {
    const alloc = std.testing.allocator;
    var fixture = Fixture{
        .answers = &.{ "{\"value\":\"Decline (c)\"}", "Submit" },
        .require_terminal_safe = true,
        .expected_display_fragments = &.{ "Decline (a)", "Cancel", "Decline (c)" },
    };
    const required = @import("../tooling/tool_mcp_runtime.zig").InputRequired{
        .input_requests_json =
        \\{"form":{"method":"elicitation/create","params":{"message":"Reply","requestedSchema":{"type":"object","properties":{"choice":{"type":"string","title":"Reply","oneOf":[{"const":"a","title":"Decline"},{"const":"b","title":"Cancel"},{"const":"c","title":"Decline"}]}},"required":["choice"]}}}}
        ,
    };
    const response = try respond(alloc, Fixture.origin(), required, .{
        .questioner = fixture.questioner(),
        .browser = fixture.browser(),
        .capabilities = .{ .form = true },
    });
    defer alloc.free(response);
    try std.testing.expectEqualStrings(
        "{\"form\":{\"action\":\"accept\",\"content\":{\"choice\":\"c\"}}}",
        response,
    );
    try std.testing.expect(fixture.saw_all_expected_display_fragments);
}

test "a typed label that matches two choices asks again, and a chosen index names its own choice" {
    const alloc = std.testing.allocator;
    var fixture = Fixture{
        .answers = &.{ "{\"value\":\"Decline (c)\"}", "{\"option\":2}", "Submit" },
        .require_terminal_safe = true,
        .expected_display_fragments = &.{"That matches more than one choice. Type its number."},
    };
    const required = @import("../tooling/tool_mcp_runtime.zig").InputRequired{
        .input_requests_json =
        \\{"form":{"method":"elicitation/create","params":{"message":"Reply","requestedSchema":{"type":"object","properties":{"choice":{"type":"string","title":"Reply","oneOf":[{"const":"a","title":"Decline"},{"const":"c","title":"Decline"},{"const":"d","title":"Decline (c)"}]}},"required":["choice"]}}}}
        ,
    };
    const response = try respond(alloc, Fixture.origin(), required, .{
        .questioner = fixture.questioner(),
        .browser = fixture.browser(),
        .capabilities = .{ .form = true },
    });
    defer alloc.free(response);
    try std.testing.expectEqualStrings(
        "{\"form\":{\"action\":\"accept\",\"content\":{\"choice\":\"d\"}}}",
        response,
    );
    try std.testing.expect(fixture.saw_all_expected_display_fragments);
}

test "a typed title that looks like an option index names its own choice" {
    const alloc = std.testing.allocator;
    var fixture = Fixture{
        .answers = &.{ "{\"value\":\"{\\\"option\\\":1}\"}", "Submit" },
    };
    const required = @import("../tooling/tool_mcp_runtime.zig").InputRequired{
        .input_requests_json =
        \\{"form":{"method":"elicitation/create","params":{"message":"Reply","requestedSchema":{"type":"object","properties":{"choice":{"type":"string","title":"Reply","oneOf":[{"const":"a","title":"{\"option\":1}"},{"const":"b","title":"Beta"}]}},"required":["choice"]}}}}
        ,
    };
    const response = try respond(alloc, Fixture.origin(), required, .{
        .questioner = fixture.questioner(),
        .browser = fixture.browser(),
        .capabilities = .{ .form = true },
    });
    defer alloc.free(response);
    try std.testing.expectEqualStrings(
        "{\"form\":{\"action\":\"accept\",\"content\":{\"choice\":\"a\"}}}",
        response,
    );
}

test "a titled choice list refuses a repeated value, so no two options share one" {
    const alloc = std.testing.allocator;
    var fixture = Fixture{ .answers = &.{} };
    try std.testing.expectError(error.InvalidInputRequired, respond(alloc, Fixture.origin(), .{
        .input_requests_json =
        \\{"form":{"method":"elicitation/create","params":{"message":"Reply","requestedSchema":{"type":"object","properties":{"choice":{"type":"string","title":"Reply","oneOf":[{"const":"a","title":"One"},{"const":"a","title":"Two"}]}},"required":["choice"]}}}}
        ,
    }, .{
        .questioner = fixture.questioner(),
        .browser = fixture.browser(),
        .capabilities = .{ .form = true },
    }));
}

test "compact menu label for a choice titled like a control keeps its value" {
    const alloc = std.testing.allocator;
    var fixture = Fixture{
        .answers = &.{"{\"option\":0}"},
        .require_terminal_safe = true,
        .expected_display_fragments = &.{"Cancel (a)"},
    };
    const response = try respond(alloc, Fixture.origin(), .{
        .input_requests_json =
        \\{"form":{"method":"elicitation/create","params":{"message":"Choose","requestedSchema":{"type":"object","properties":{"name":{"type":"string","oneOf":[{"const":"a","title":"Cancel"},{"const":"b","title":"Keep"}]}},"required":["name"]}}}}
        ,
    }, .{
        .questioner = fixture.questioner(),
        .browser = fixture.browser(),
        .capabilities = .{ .form = true },
        .compact_forms = true,
    });
    defer alloc.free(response);
    try std.testing.expectEqualStrings("{\"form\":{\"action\":\"accept\",\"content\":{\"name\":\"a\"}}}", response);
    try std.testing.expect(fixture.saw_all_expected_display_fragments);
}

test "URL interaction requires consent and does not open on decline" {
    const alloc = std.testing.allocator;
    var fixture = Fixture{
        .answers = &.{"Decline"},
        .require_terminal_safe = true,
        .expected_display_fragments = &.{
            "Target host: xn--pple-43d.test",
            "Warning: This host uses Punycode and may disguise its destination.",
        },
    };
    const required = @import("../tooling/tool_mcp_runtime.zig").InputRequired{
        .input_requests_json =
        \\{"url":{"method":"elicitation/create","params":{"mode":"url","message":"Authorize","url":"https://xn--pple-43d.test/full?state=opaque"}}}
        ,
    };
    const response = try respond(alloc, Fixture.origin(), required, .{
        .questioner = fixture.questioner(),
        .browser = fixture.browser(),
        .capabilities = .{ .url = true },
    });
    defer alloc.free(response);
    try std.testing.expectEqualStrings("{\"url\":{\"action\":\"decline\"}}", response);
    try std.testing.expectEqual(@as(usize, 0), fixture.open_calls);
    try std.testing.expect(fixture.saw_all_expected_display_fragments);
}

test "form interaction supports primitive defaults decline and cancellation" {
    const alloc = std.testing.allocator;
    const required = @import("../tooling/tool_mcp_runtime.zig").InputRequired{
        .input_requests_json =
        \\{"form":{"method":"elicitation/create","params":{"message":"Defaults","requestedSchema":{"type":"object","properties":{"note":{"type":"string","default":"default-note"},"enabled":{"type":"boolean","default":true},"tags":{"type":"array","items":{"type":"string","enum":["a","b"]},"default":["a"]}},"required":["note","enabled","tags"]}}}}
        ,
    };

    var defaults = Fixture{
        .answers = &.{ "Use default", "Use default", "Use default", "Submit" },
    };
    const accepted = try respond(alloc, Fixture.origin(), required, .{
        .questioner = defaults.questioner(),
        .browser = defaults.browser(),
        .capabilities = .{ .form = true },
    });
    defer alloc.free(accepted);
    try std.testing.expectEqualStrings(
        "{\"form\":{\"action\":\"accept\",\"content\":{\"note\":\"default-note\",\"enabled\":true,\"tags\":[\"a\"]}}}",
        accepted,
    );

    var decline = Fixture{
        .answers = &.{ "Use default", "Use default", "Use default", "Decline" },
    };
    const declined = try respond(alloc, Fixture.origin(), required, .{
        .questioner = decline.questioner(),
        .browser = decline.browser(),
        .capabilities = .{ .form = true },
    });
    defer alloc.free(declined);
    try std.testing.expectEqualStrings("{\"form\":{\"action\":\"decline\"}}", declined);

    var cancelled = Fixture{ .answers = &.{} };
    const cancelled_response = try respond(alloc, Fixture.origin(), required, .{
        .questioner = cancelled.questioner(),
        .browser = cancelled.browser(),
        .capabilities = .{ .form = true },
    });
    defer alloc.free(cancelled_response);
    try std.testing.expectEqualStrings("{\"form\":{\"action\":\"cancel\"}}", cancelled_response);
}

test "form controls are separate from literal Skip and Use default values" {
    const alloc = std.testing.allocator;
    const required = tool_mcp_runtime.InputRequired{
        .input_requests_json =
        \\{"form":{"method":"elicitation/create","params":{"message":"Literal controls","requestedSchema":{"type":"object","properties":{"literalSkip":{"type":"string"},"literalDefault":{"type":"string","default":"fallback"}},"required":["literalDefault"]}}}}
        ,
    };
    var fixture = Fixture{
        .answers = &.{
            "Enter value",
            "Skip",
            "Enter value",
            "Use default",
            "Submit",
        },
    };
    const response = try respond(alloc, Fixture.origin(), required, .{
        .questioner = fixture.questioner(),
        .browser = fixture.browser(),
        .capabilities = .{ .form = true },
    });
    defer alloc.free(response);
    try std.testing.expectEqualStrings(
        "{\"form\":{\"action\":\"accept\",\"content\":{\"literalSkip\":\"Skip\",\"literalDefault\":\"Use default\"}}}",
        response,
    );
}

const shown_when_form_json =
    \\{"form":{"method":"elicitation/create","params":{"message":"Project","requestedSchema":{"type":"object","properties":{"project":{"type":"string","title":"Project","oneOf":[{"const":"__other__","title":"Another project"},{"const":"a","title":"Alpha"}]},"other":{"type":"string","title":"Name","x-fx-shown-when":{"project":"__other__"}}},"required":["project"]}}}}
;

test "a shown-when field on a host form is asked only while its condition holds, and then with no Skip" {
    const alloc = std.testing.allocator;
    var alpha = Fixture{ .answers = &.{ "{\"option\":1}", "Submit" } };
    const alpha_response = try respond(alloc, originFor(.host, ""), .{ .input_requests_json = shown_when_form_json }, .{
        .questioner = alpha.questioner(),
        .browser = alpha.browser(),
        .capabilities = .{ .form = true },
    });
    defer alloc.free(alpha_response);
    try std.testing.expectEqualStrings("{\"form\":{\"action\":\"accept\",\"content\":{\"project\":\"a\"}}}", alpha_response);
    // Two questions only: the project and the review. The name gets no question.
    try std.testing.expectEqual(@as(usize, 2), alpha.answer_index);

    var other = Fixture{ .answers = &.{ "{\"option\":0}", "Zed", "Submit" } };
    const other_response = try respond(alloc, originFor(.host, ""), .{ .input_requests_json = shown_when_form_json }, .{
        .questioner = other.questioner(),
        .browser = other.browser(),
        .capabilities = .{ .form = true },
    });
    defer alloc.free(other_response);
    // "Zed" is the answer itself, so the name was asked with no "Enter value" or "Skip" step first.
    try std.testing.expectEqualStrings(
        "{\"form\":{\"action\":\"accept\",\"content\":{\"project\":\"__other__\",\"other\":\"Zed\"}}}",
        other_response,
    );
    try std.testing.expectEqual(@as(usize, 3), other.answer_index);
}

test "a shown-when field that an Edit hides is cleared, and its value stays out of the review" {
    const alloc = std.testing.allocator;
    var fixture = Fixture{
        .answers = &.{
            "{\"option\":0}", // project: Another project
            "Zed", // name
            "Edit", // review
            "Edit value", // keep or edit the project
            "{\"option\":1}", // project: Alpha, which hides the name
            "Submit",
        },
        .hidden_text = "Zed",
    };
    const response = try respond(alloc, originFor(.host, ""), .{ .input_requests_json = shown_when_form_json }, .{
        .questioner = fixture.questioner(),
        .browser = fixture.browser(),
        .capabilities = .{ .form = true },
    });
    defer alloc.free(response);
    try std.testing.expectEqualStrings("{\"form\":{\"action\":\"accept\",\"content\":{\"project\":\"a\"}}}", response);
    try std.testing.expectEqual(@as(usize, 6), fixture.answer_index);
    // The review before Edit shows "Zed"; the review after Edit must not.
    try std.testing.expectEqual(@as(usize, 1), fixture.reviews_with_hidden_text);
}

test "a shown-when field that an Edit shows again is asked fresh, with no Skip" {
    const alloc = std.testing.allocator;
    var fixture = Fixture{
        .answers = &.{
            "{\"option\":1}", // project: Alpha, which hides the name
            "Edit", // review
            "Edit value", // keep or edit the project
            "{\"option\":0}", // project: Another project, which shows the name
            "Zed", // name, asked for the first time
            "Submit",
        },
    };
    const response = try respond(alloc, originFor(.host, ""), .{ .input_requests_json = shown_when_form_json }, .{
        .questioner = fixture.questioner(),
        .browser = fixture.browser(),
        .capabilities = .{ .form = true },
    });
    defer alloc.free(response);
    try std.testing.expectEqualStrings(
        "{\"form\":{\"action\":\"accept\",\"content\":{\"project\":\"__other__\",\"other\":\"Zed\"}}}",
        response,
    );
    try std.testing.expectEqual(@as(usize, 6), fixture.answer_index);
}

test "a shown-when key on an MCP form is ignored, and every field is asked as today" {
    const alloc = std.testing.allocator;
    // An MCP server's optional name keeps its Skip step, and it is asked whatever the project is.
    var skipped = Fixture{ .answers = &.{ "{\"option\":1}", "Skip", "Submit" } };
    const skipped_response = try respond(alloc, originFor(.mcp_server, "docs"), .{ .input_requests_json = shown_when_form_json }, .{
        .questioner = skipped.questioner(),
        .browser = skipped.browser(),
        .capabilities = .{ .form = true },
    });
    defer alloc.free(skipped_response);
    try std.testing.expectEqualStrings("{\"form\":{\"action\":\"accept\",\"content\":{\"project\":\"a\"}}}", skipped_response);
    try std.testing.expectEqual(@as(usize, 3), skipped.answer_index);

    var entered = Fixture{ .answers = &.{ "{\"option\":0}", "Enter value", "Zed", "Submit" } };
    const entered_response = try respond(alloc, originFor(.mcp_server, "docs"), .{ .input_requests_json = shown_when_form_json }, .{
        .questioner = entered.questioner(),
        .browser = entered.browser(),
        .capabilities = .{ .form = true },
    });
    defer alloc.free(entered_response);
    try std.testing.expectEqualStrings(
        "{\"form\":{\"action\":\"accept\",\"content\":{\"project\":\"__other__\",\"other\":\"Zed\"}}}",
        entered_response,
    );
    try std.testing.expectEqual(@as(usize, 4), entered.answer_index);
}

test "single-select local identities preserve every colliding wire value" {
    const alloc = std.testing.allocator;
    const raw_titles = [_][]const u8{
        "Skip",
        "Use default",
        "Duplicate",
        "Duplicate",
        "Collision\x1b[2J",
        "Collision\\x1b[2J",
    };
    const wire_values = [_][]const u8{
        "Skip",
        "Use default",
        "value-3",
        "Duplicate",
        "escape-raw",
        "escape-literal",
    };
    var choices: [raw_titles.len]elicitation.Choice = undefined;
    for (raw_titles, 0..) |title, index| {
        choices[index] = .{
            .value = @constCast(wire_values[index]),
            .title = @constCast(title),
        };
    }
    var labels: [raw_titles.len][]u8 = undefined;
    var label_count: usize = 0;
    defer for (labels[0..label_count]) |label| alloc.free(label);
    var options: [raw_titles.len]types.QuestionOption = undefined;
    for (0..raw_titles.len) |index| {
        labels[index] = try choiceLabelAlloc(alloc, &choices, &.{}, index);
        label_count += 1;
        options[index] = .{ .label = labels[index] };
    }

    for (options, 0..) |option, index| {
        const found = labelMatch(&options, option.label);
        try std.testing.expect(std.meta.activeTag(found) == .one);
        try std.testing.expectEqual(index, found.one);
        try std.testing.expectEqualStrings(wire_values[index], choices[found.one].value);
        for (options[index + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, option.label, other.label));
        }
    }
    try std.testing.expectEqualStrings("Collision\\x1b[2J (escape-raw)", labels[4]);
    try std.testing.expectEqualStrings("Collision\\x1b[2J (escape-literal)", labels[5]);
    try std.testing.expectEqual(@as(usize, 0), labelMatch(&options, "Skip").one);
    try std.testing.expectEqual(@as(usize, 1), labelMatch(&options, "Use default").one);
    try std.testing.expect(std.meta.activeTag(labelMatch(&options, "Duplicate")) == .none);
    try std.testing.expect(std.meta.activeTag(labelMatch(&options, "escape-raw")) == .none);
}

test "URL browser failure supports manual continuation and bounded retry" {
    const alloc = std.testing.allocator;
    const required = @import("../tooling/tool_mcp_runtime.zig").InputRequired{
        .input_requests_json =
        \\{"url":{"method":"elicitation/create","params":{"mode":"url","message":"Authorize","url":"https://example.test/full?state=opaque"}}}
        ,
    };

    var manual = Fixture{
        .answers = &.{ "Open URL", "Continue manually" },
        .open_results = &.{false},
    };
    const manual_response = try respond(alloc, Fixture.origin(), required, .{
        .questioner = manual.questioner(),
        .browser = manual.browser(),
        .capabilities = .{ .url = true },
    });
    defer alloc.free(manual_response);
    try std.testing.expectEqualStrings("{\"url\":{\"action\":\"accept\"}}", manual_response);
    try std.testing.expectEqual(@as(usize, 1), manual.open_calls);

    var retry = Fixture{
        .answers = &.{ "Open URL", "Retry browser" },
        .open_results = &.{ false, true },
    };
    const retry_response = try respond(alloc, Fixture.origin(), required, .{
        .questioner = retry.questioner(),
        .browser = retry.browser(),
        .capabilities = .{ .url = true },
    });
    defer alloc.free(retry_response);
    try std.testing.expectEqualStrings("{\"url\":{\"action\":\"accept\"}}", retry_response);
    try std.testing.expectEqual(@as(usize, 2), retry.open_calls);
}

test "legacy URL completion is separate from consent and supports bounded manual retry" {
    const alloc = std.testing.allocator;
    const required_json =
        \\{"first":{"method":"elicitation/create","params":{"mode":"url","message":"One","url":"https://one.test/","elicitationId":"one"}},"second":{"method":"elicitation/create","params":{"mode":"url","message":"Two","url":"https://two.test/","elicitationId":"two"}}}
    ;
    var signal = tool_mcp_runtime.LegacyUrlCompletionSignal{};
    var manual = Fixture{ .answers = &.{"I completed it / Retry"} };
    const manual_response = try respond(
        alloc,
        Fixture.legacyOrigin(),
        .{
            .input_requests_json = required_json,
            .legacy_retry_without_responses = true,
            .legacy_url_phase = .await_completion,
            .legacy_url_completion_signal = &signal,
        },
        .{
            .questioner = manual.questioner(),
            .browser = manual.browser(),
            .capabilities = .{ .url = true },
        },
    );
    defer alloc.free(manual_response);
    try std.testing.expectEqualStrings(
        "{\"first\":{\"action\":\"accept\"},\"second\":{\"action\":\"accept\"}}",
        manual_response,
    );
    try std.testing.expectEqual(@as(usize, 0), manual.open_calls);

    signal.status.store(.completed, .release);
    signal.wake.store(true, .release);
    var automatic = Fixture{ .answers = &.{} };
    const automatic_response = try respond(
        alloc,
        Fixture.legacyOrigin(),
        .{
            .input_requests_json = required_json,
            .legacy_retry_without_responses = true,
            .legacy_url_phase = .await_completion,
            .legacy_url_completion_signal = &signal,
        },
        .{
            .questioner = automatic.questioner(),
            .browser = automatic.browser(),
            .capabilities = .{ .url = true },
        },
    );
    defer alloc.free(automatic_response);
    try std.testing.expectEqualStrings(manual_response, automatic_response);
    try std.testing.expectEqual(@as(usize, 0), automatic.answer_index);
}

fn originFor(kind: tool_mcp_runtime.OriginKind, server_name: []const u8) tool_mcp_runtime.InputOrigin {
    return .{
        .wire = .modern_mcp,
        .kind = kind,
        .server_name = server_name,
        .operation = .{ .tools_call = "fixture" },
        .connection_generation = 1,
        .client_generation = 1,
        .catalog_generation = 1,
        .request_generation = 1,
        .auth_generation = 1,
        .deadline_ms = std.math.maxInt(i64),
    };
}

/// Records the first question a prompt asks, then cancels, so a test reads its text.
const FirstQuestion = struct {
    text: [512]u8 = undefined,
    len: usize = 0,

    fn questioner(self: *FirstQuestion) Questioner {
        return .{ .context = self, .ask_fn = ask };
    }

    fn ask(
        raw: *anyopaque,
        _: Allocator,
        entries: []const types.QuestionBatchEntry,
        _: i64,
        _: ?*const std.atomic.Value(bool),
    ) anyerror!?[][]u8 {
        const self: *FirstQuestion = @ptrCast(@alignCast(raw));
        if (self.len == 0) {
            self.len = entries[0].question.len;
            @memcpy(self.text[0..self.len], entries[0].question);
        }
        return null;
    }

    fn slice(self: *const FirstQuestion) []const u8 {
        return self.text[0..self.len];
    }
};

fn refuseOpen(_: ?*anyopaque, _: Allocator, _: []const u8) anyerror!bool {
    return false;
}

fn firstQuestion(
    alloc: Allocator,
    origin: tool_mcp_runtime.InputOrigin,
    input_json: []const u8,
    compact: bool,
) !FirstQuestion {
    var capture: FirstQuestion = .{};
    const response = try respond(alloc, origin, .{ .input_requests_json = input_json }, .{
        .questioner = capture.questioner(),
        .browser = .{ .open_fn = refuseOpen },
        .capabilities = .{ .form = true },
        .compact_forms = compact,
    });
    alloc.free(response);
    return capture;
}

const text_form_json =
    \\{"form":{"method":"elicitation/create","params":{"message":"Pick a name","requestedSchema":{"type":"object","properties":{"name":{"type":"string","title":"Project name"}},"required":["name"]}}}}
;

const choice_form_json =
    \\{"form":{"method":"elicitation/create","params":{"message":"Choose one","requestedSchema":{"type":"object","properties":{"choice":{"type":"string","title":"Pick one","oneOf":[{"const":"a","title":"Alpha"},{"const":"b","title":"Beta"}]}},"required":["choice"]}}}}
;

test "Speaker words: an MCP server names itself, and the host never prints a name" {
    const alloc = std.testing.allocator;
    const server: Speaker = .{ .kind = .mcp_server, .server_name = "Profile" };
    const host: Speaker = .{ .kind = .host, .server_name = "Shadow" };
    const server_subject = try server.subject(alloc, "Profile");
    defer alloc.free(server_subject);
    try std.testing.expectEqualStrings("MCP server Profile", server_subject);
    const server_request = try server.request(alloc, "Profile");
    defer alloc.free(server_request);
    try std.testing.expectEqualStrings("MCP server Profile requests", server_request);
    const host_subject = try host.subject(alloc, "Shadow");
    defer alloc.free(host_subject);
    try std.testing.expectEqualStrings("fx", host_subject);
    const host_request = try host.request(alloc, "Shadow");
    defer alloc.free(host_request);
    try std.testing.expectEqualStrings("fx asks", host_request);
}

test "TUI form header: an MCP server keeps its text, and the host says fx asks without its name" {
    const alloc = std.testing.allocator;
    const mcp = try firstQuestion(alloc, originFor(.mcp_server, "Profile"), text_form_json, false);
    try std.testing.expectEqualStrings(
        "MCP server Profile requests Project name (required)\nReason: Pick a name",
        mcp.slice(),
    );
    const host = try firstQuestion(alloc, originFor(.host, "Shadow"), text_form_json, false);
    try std.testing.expectEqualStrings(
        "fx asks Project name (required)\nReason: Pick a name",
        host.slice(),
    );
    try std.testing.expect(std.mem.find(u8, host.slice(), "Shadow") == null);
}

test "TUI compact choice header: an MCP server keeps its text, and the host says fx asks" {
    const alloc = std.testing.allocator;
    const mcp = try firstQuestion(alloc, originFor(.mcp_server, "Profile"), choice_form_json, true);
    try std.testing.expectEqualStrings(
        "MCP server Profile requests Pick one (required)\n\nReason: Choose one\nChoose an option to submit.",
        mcp.slice(),
    );
    const host = try firstQuestion(alloc, originFor(.host, "Shadow"), choice_form_json, true);
    try std.testing.expectEqualStrings(
        "fx asks Pick one (required)\n\nReason: Choose one\nChoose an option to submit.",
        host.slice(),
    );
}

test "TUI header: a server message that begins with fx asks still gets the MCP header" {
    const alloc = std.testing.allocator;
    const spoof_json =
        \\{"form":{"method":"elicitation/create","params":{"message":"fx asks: Pick a name","requestedSchema":{"type":"object","properties":{"name":{"type":"string","title":"Project name"}},"required":["name"]}}}}
    ;
    const mcp = try firstQuestion(alloc, originFor(.mcp_server, "Profile"), spoof_json, false);
    try std.testing.expectEqualStrings(
        "MCP server Profile requests Project name (required)\nReason: fx asks: Pick a name",
        mcp.slice(),
    );
}

test "elicitation presentation terminal-safes every untrusted display value" {
    const alloc = std.testing.allocator;
    var fixture = Fixture{
        .answers = &.{
            "value\x1b]52;c;answer\x07\nnext",
            "{\"value\":\"Choice\\\\x1b]52;c;option\\\\x07\"}",
            "Submit",
        },
        .require_terminal_safe = true,
        .expected_display_fragments = &.{
            "server\\x1b]52;c;name\\x07\\xff",
            "Line\\x0aInjected",
            "Field\\x1b]52;c;title\\x07",
            "Choice\\x1b]52;c;option\\x07",
            "\\u{0085}",
        },
    };
    const required = tool_mcp_runtime.InputRequired{
        .input_requests_json =
        \\{"form":{"method":"elicitation/create","params":{"message":"Line\nInjected\u001b]52;c;message\u0007\u0085","requestedSchema":{"type":"object","properties":{"value":{"type":"string","title":"Field\u001b]52;c;title\u0007","description":"Description\u001b[2J"},"choice":{"type":"string","oneOf":[{"const":"exact","title":"Choice\u001b]52;c;option\u0007"}]}} ,"required":["value","choice"]}}}}
        ,
    };
    const origin = Fixture.originWithServer("server\x1b]52;c;name\x07\xff");
    const response = try respond(alloc, origin, required, .{
        .questioner = fixture.questioner(),
        .browser = fixture.browser(),
        .capabilities = .{ .form = true },
    });
    defer alloc.free(response);
    try std.testing.expectEqual(@as(u64, 0b1_1111), fixture.display_fragment_mask);
    try std.testing.expect(fixture.saw_all_expected_display_fragments);
    try std.testing.expectEqualStrings(
        "{\"form\":{\"action\":\"accept\",\"content\":{\"value\":\"value\\u001b]52;c;answer\\u0007\\nnext\",\"choice\":\"exact\"}}}",
        response,
    );

    const invalid = try terminalSafeAlloc(alloc, "bad\xff\x1b]52;c;x\x07\xc2\x85\nline");
    defer alloc.free(invalid);
    try std.testing.expectEqualStrings(
        "bad\\xff\\x1b]52;c;x\\x07\\u{0085}\\x0aline",
        invalid,
    );
}

test "interaction maps generic callback failures to its concrete public errors" {
    const alloc = std.testing.allocator;
    const required = tool_mcp_runtime.InputRequired{
        .input_requests_json =
        \\{"url":{"method":"elicitation/create","params":{"mode":"url","message":"Authorize","url":"https://example.test/"}}}
        ,
    };
    var question_failure = Fixture{ .answers = &.{}, .ask_error = true };
    try std.testing.expectError(
        error.QuestionFailed,
        respond(alloc, Fixture.origin(), required, .{
            .questioner = question_failure.questioner(),
            .browser = question_failure.browser(),
            .capabilities = .{ .url = true },
        }),
    );

    var browser_failure = Fixture{
        .answers = &.{"Open URL"},
        .open_error = true,
    };
    try std.testing.expectError(
        error.BrowserOpenFailed,
        respond(alloc, Fixture.origin(), required, .{
            .questioner = browser_failure.questioner(),
            .browser = browser_failure.browser(),
            .capabilities = .{ .url = true },
        }),
    );
}

test "form interaction releases an accepted response when review fails" {
    const alloc = std.testing.allocator;
    const required = tool_mcp_runtime.InputRequired{
        .input_requests_json =
        \\{"form":{"method":"elicitation/create","params":{"message":"Review","requestedSchema":{"type":"object","properties":{"value":{"type":"string"}},"required":["value"]}}}}
        ,
    };
    var fixture = Fixture{
        .answers = &.{"accepted"},
        .ask_error_after = 1,
    };
    try std.testing.expectError(
        error.QuestionFailed,
        respond(alloc, Fixture.origin(), required, .{
            .questioner = fixture.questioner(),
            .browser = fixture.browser(),
            .capabilities = .{ .form = true },
        }),
    );
}

fn checkAcceptedFormAllocationFailures(alloc: Allocator) !void {
    const required = tool_mcp_runtime.InputRequired{
        .input_requests_json =
        \\{"form":{"method":"elicitation/create","params":{"message":"Review","requestedSchema":{"type":"object","properties":{"value":{"type":"string"}},"required":["value"]}}}}
        ,
    };
    var fixture = Fixture{ .answers = &.{ "accepted", "Submit" } };
    const response = respond(alloc, Fixture.origin(), required, .{
        .questioner = fixture.questioner(),
        .browser = fixture.browser(),
        .capabilities = .{ .form = true },
    }) catch |err| switch (err) {
        // These boundaries deliberately hide allocator errors. In this
        // allocation harness, their only injected failure is OutOfMemory.
        error.QuestionFailed, error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    alloc.free(response);
}

test "form interaction owns every accepted response allocation" {
    try std.testing.checkAllAllocationFailures(
        testing_allocator.no_resize,
        checkAcceptedFormAllocationFailures,
        .{},
    );
}

test "compact form submits a choice or declines without a review" {
    const alloc = std.testing.allocator;
    for ([_]struct { answer: []const u8, expected: []const u8 }{
        .{ .answer = "{\"option\":0}", .expected = "{\"form\":{\"action\":\"accept\",\"content\":{\"name\":\"Decline\"}}}" },
        .{ .answer = "{\"option\":1}", .expected = "{\"form\":{\"action\":\"decline\"}}" },
        .{ .answer = "{\"option\":2}", .expected = "{\"form\":{\"action\":\"cancel\"}}" },
    }) |case| {
        var fixture = Fixture{ .answers = &.{case.answer} };
        const response = try respond(alloc, Fixture.origin(), .{
            .input_requests_json =
            \\{"form":{"method":"elicitation/create","params":{"message":"Name","requestedSchema":{"type":"object","properties":{"name":{"type":"string","enum":["Decline"]}},"required":["name"]}}}}
            ,
        }, .{ .questioner = fixture.questioner(), .browser = fixture.browser(), .capabilities = .{ .form = true }, .compact_forms = true });
        defer alloc.free(response);
        try std.testing.expectEqualStrings(case.expected, response);
        try std.testing.expectEqual(@as(usize, 1), fixture.answer_index);
        try std.testing.expect(!fixture.review_contained_values);
    }
}

test "a refused form is told to the user in fx's reason, never in the form's words, and a cancel is told to no one" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { err: anyerror, reason: []const u8 }{
        .{ .err = error.LimitExceeded, .reason = "the form is larger than fx can show" },
        .{ .err = error.PresentationLimitExceeded, .reason = "the form is larger than fx can show" },
        .{ .err = error.MetadataLimitExceeded, .reason = "the form is larger than fx can show" },
        .{ .err = error.RetryLimitExceeded, .reason = "the answers did not fit the form after several tries" },
        .{ .err = error.SecretField, .reason = "the form asks for a secret, which fx never takes in a form" },
        .{ .err = error.UnsupportedSchema, .reason = "fx can't show the form: it is invalid, has a field type fx doesn't support, or asks for a secret" },
        .{ .err = error.InvalidInputRequired, .reason = "fx can't show the form: it is invalid, has a field type fx doesn't support, or asks for a secret" },
        .{ .err = error.InvalidAnswer, .reason = "the answers did not fit the form" },
        .{ .err = error.InsecureUrl, .reason = "the link in it is not a safe web address" },
        .{ .err = error.UnsupportedMode, .reason = "it asks for input that fx can't take here" },
        .{ .err = error.McpInputRequired, .reason = "it asks for input that fx can't take here" },
        .{ .err = error.McpInputTimedOut, .reason = "no answer came in time" },
        .{ .err = error.BrowserOpenFailed, .reason = "fx couldn't open the browser" },
        .{ .err = error.QuestionFailed, .reason = "fx couldn't show the question" },
        .{ .err = error.OutOfMemory, .reason = "fx ran out of memory" },
        .{ .err = error.SomethingNobodyListed, .reason = "something went wrong" },
    };
    for (cases) |case| {
        const text = (try declinedText(a, "docs", case.err)).?;
        try std.testing.expectEqualStrings(try a.print("MCP server 'docs' asked for input, and fx declined it: {s}.", .{case.reason}), text);
        // The error's name is for the trace, never for the user.
        try std.testing.expect(std.mem.find(u8, text, @errorName(case.err)) == null);
    }
    try std.testing.expect((try declinedText(a, "docs", error.Cancelled)) == null);
    // A hostile server name stays inside the text, with no control byte.
    const hostile = (try declinedText(a, "evil\x1b]52;c;X\x07\n[2J", error.LimitExceeded)).?;
    for (hostile) |byte| try std.testing.expect(byte >= 0x20 and byte != 0x7f);
    try std.testing.expect(std.mem.startsWith(u8, hostile, "MCP server 'evil\\x1b]52;c;X\\x07"));
}

test "compact form defaults skip and choice labels preserve exact values" {
    const alloc = std.testing.allocator;
    for ([_]struct { answer: []const u8, content: []const u8 }{
        .{ .answer = "{\"option\":0}", .content = "{\"name\":\"a\"}" },
        .{ .answer = "{\"option\":1}", .content = "{\"name\":\"b\"}" },
        .{ .answer = "{\"option\":2}", .content = "{\"name\":\"c\"}" },
        .{ .answer = "{\"option\":3}", .content = "{\"name\":\"b\"}" },
        .{ .answer = "{\"option\":4}", .content = "{}" },
    }) |case| {
        var fixture = Fixture{ .answers = &.{case.answer} };
        const response = try respond(alloc, Fixture.origin(), .{
            .input_requests_json =
            \\{"form":{"method":"elicitation/create","params":{"message":"Choose","requestedSchema":{"type":"object","properties":{"name":{"type":"string","default":"b","oneOf":[{"const":"a","title":"Decline"},{"const":"b","title":"Cancel"},{"const":"c","title":"Decline"}]}}}}}}
            ,
        }, .{ .questioner = fixture.questioner(), .browser = fixture.browser(), .capabilities = .{ .form = true }, .compact_forms = true });
        defer alloc.free(response);
        const expected = try alloc.print("{{\"form\":{{\"action\":\"accept\",\"content\":{s}}}}}", .{case.content});
        defer alloc.free(expected);
        try std.testing.expectEqualStrings(expected, response);
        try std.testing.expectEqual(@as(usize, 1), fixture.answer_index);
    }
}

test "compact form keeps review for short text numbers and booleans" {
    const alloc = std.testing.allocator;
    for ([_]struct { kind: []const u8, answer: []const u8, value: []const u8 }{
        .{ .kind = "string", .answer = "x", .value = "\"x\"" },
        .{ .kind = "number", .answer = "0.5", .value = "0.5" },
        .{ .kind = "integer", .answer = "1", .value = "1" },
        .{ .kind = "boolean", .answer = "True", .value = "true" },
    }) |case| {
        var fixture = Fixture{ .answers = &.{ case.answer, "Submit" } };
        const requests = try alloc.print(
            "{{\"form\":{{\"method\":\"elicitation/create\",\"params\":{{\"message\":\"Value\",\"requestedSchema\":{{\"type\":\"object\",\"properties\":{{\"value\":{{\"type\":\"{s}\"}}}},\"required\":[\"value\"]}}}}}}}}",
            .{case.kind},
        );
        defer alloc.free(requests);
        const response = try respond(alloc, Fixture.origin(), .{ .input_requests_json = requests }, .{
            .questioner = fixture.questioner(),
            .browser = fixture.browser(),
            .capabilities = .{ .form = true },
            .compact_forms = true,
        });
        defer alloc.free(response);
        const expected = try alloc.print("{{\"form\":{{\"action\":\"accept\",\"content\":{{\"value\":{s}}}}}}}", .{case.value});
        defer alloc.free(expected);
        try std.testing.expectEqualStrings(expected, response);
        try std.testing.expect(fixture.review_contained_values);
        try std.testing.expectEqual(@as(usize, 2), fixture.answer_index);
    }
}

test "compact form keeps review for four choices" {
    const alloc = std.testing.allocator;
    var fixture = Fixture{ .answers = &.{ "{\"value\":\"a\"}", "Submit" } };
    const response = try respond(alloc, Fixture.origin(), .{
        .input_requests_json =
        \\{"form":{"method":"elicitation/create","params":{"message":"Choose","requestedSchema":{"type":"object","properties":{"name":{"type":"string","enum":["a","b","c","d"]}},"required":["name"]}}}}
        ,
    }, .{ .questioner = fixture.questioner(), .browser = fixture.browser(), .capabilities = .{ .form = true }, .compact_forms = true });
    defer alloc.free(response);
    try std.testing.expectEqualStrings("{\"form\":{\"action\":\"accept\",\"content\":{\"name\":\"a\"}}}", response);
    try std.testing.expect(fixture.review_contained_values);
}

const Fixture = struct {
    answers: []const []const u8,
    answer_index: usize = 0,
    open_calls: usize = 0,
    open_results: []const bool = &.{true},
    expected_review_values: []const []const u8 = &.{},
    review_contained_values: bool = false,
    require_terminal_safe: bool = false,
    expected_display_fragments: []const []const u8 = &.{},
    saw_all_expected_display_fragments: bool = false,
    display_fragment_mask: u64 = 0,
    ask_error: bool = false,
    ask_error_after: ?usize = null,
    open_error: bool = false,
    expected_question: ?[]const u8 = null,
    saw_expected_question: bool = false,
    /// Counts the reviews that show this text, so a test can prove a hidden value stays out.
    hidden_text: ?[]const u8 = null,
    reviews_with_hidden_text: usize = 0,

    fn origin() @import("../tooling/tool_mcp_runtime.zig").InputOrigin {
        return originWithServer("fixture");
    }

    fn legacyOrigin() tool_mcp_runtime.InputOrigin {
        var input_origin = originWithServer("fixture");
        input_origin.wire = .legacy_mcp_2025_11;
        return input_origin;
    }

    fn originWithServer(server_name: []const u8) tool_mcp_runtime.InputOrigin {
        return .{
            .wire = .modern_mcp,
            .server_name = server_name,
            .operation = .{ .tools_call = "fixture" },
            .connection_generation = 1,
            .client_generation = 1,
            .catalog_generation = 1,
            .request_generation = 1,
            .auth_generation = 1,
            .deadline_ms = std.math.maxInt(i64),
        };
    }

    fn questioner(self: *Fixture) Questioner {
        return .{ .context = self, .ask_fn = ask };
    }

    fn browser(self: *Fixture) Browser {
        return .{ .context = self, .open_fn = open };
    }

    fn ask(
        raw: *anyopaque,
        alloc: Allocator,
        entries: []const types.QuestionBatchEntry,
        _: i64,
        _: ?*const std.atomic.Value(bool),
    ) anyerror!?[][]u8 {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (self.ask_error or self.ask_error_after == self.answer_index) {
            return error.InjectedQuestionFailure;
        }
        if (entries.len != 1 or self.answer_index >= self.answers.len) return null;
        if (self.expected_question) |expected| {
            if (std.mem.eql(u8, entries[0].question, expected)) self.saw_expected_question = true;
        }
        if (self.hidden_text) |hidden| {
            if (std.mem.find(u8, entries[0].question, "Current values:") != null and
                std.mem.find(u8, entries[0].question, hidden) != null)
            {
                self.reviews_with_hidden_text += 1;
            }
        }
        if (self.require_terminal_safe) {
            if (std.mem.findScalar(u8, entries[0].question, 0x1b) != null or
                std.mem.findScalar(u8, entries[0].question, 0xff) != null or
                std.mem.find(u8, entries[0].question, "\xc2\x85") != null or
                std.mem.find(u8, entries[0].question, "Line\nInjected") != null)
            {
                return error.RawTerminalControl;
            }
            for (entries[0].options) |option| {
                if (std.mem.findScalar(u8, option.label, 0x1b) != null or
                    std.mem.findScalar(u8, option.label, 0xff) != null or
                    (option.description != null and
                        std.mem.findScalar(u8, option.description.?, 0x1b) != null))
                {
                    return error.RawTerminalControl;
                }
            }
            for (self.expected_display_fragments, 0..) |expected, expected_index| {
                var found = std.mem.find(u8, entries[0].question, expected) != null;
                if (!found) for (entries[0].options) |option| {
                    if (std.mem.find(u8, option.label, expected) != null or
                        (option.description != null and
                            std.mem.find(u8, option.description.?, expected) != null))
                    {
                        found = true;
                        break;
                    }
                };
                if (found and expected_index < 64) {
                    self.display_fragment_mask |= @as(u64, 1) << @intCast(expected_index);
                }
            }
            const expected_mask = if (self.expected_display_fragments.len == 64)
                std.math.maxInt(u64)
            else
                (@as(u64, 1) << @intCast(self.expected_display_fragments.len)) - 1;
            self.saw_all_expected_display_fragments =
                self.display_fragment_mask == expected_mask;
        }
        const answer = self.answers[self.answer_index];
        self.answer_index += 1;
        if (std.mem.find(u8, entries[0].question, "Current values:") != null) {
            self.review_contained_values = true;
            for (self.expected_review_values) |expected| {
                if (std.mem.find(u8, entries[0].question, expected) == null) {
                    self.review_contained_values = false;
                    break;
                }
            }
        }
        const result = try alloc.alloc([]u8, 1);
        errdefer alloc.free(result);
        result[0] = try alloc.dupe(u8, answer);
        return result;
    }

    fn open(raw: ?*anyopaque, _: Allocator, _: []const u8) anyerror!bool {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        if (self.open_error) return error.InjectedBrowserFailure;
        const index = self.open_calls;
        self.open_calls += 1;
        if (index >= self.open_results.len) return false;
        return self.open_results[index];
    }
};
