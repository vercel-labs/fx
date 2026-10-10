const std = @import("std");
const token_estimate = @import("../../shared/token_estimate.zig");
const types = @import("../../shared/types.zig");
const stream_provider = @import("../stream_provider.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;

const textTokens = token_estimate.textTokens;

pub const RequestCost = struct {
    serialized_bytes: usize,
    /// Uncalibrated serialization estimate; non-image usage may replace it.
    text_tokens: usize,
    /// Null means no image parts. Otherwise visual cost needs applicable usage.
    image_identity: ?[32]u8 = null,
    estimated_input_tokens: usize,
};

pub const RequestTokenCalibration = struct {
    request: RequestCost,
    exact_input_tokens: usize,

    pub fn applies(self: RequestTokenCalibration, cost: RequestCost) bool {
        return self.request.serialized_bytes != 0 and self.exact_input_tokens != 0 and
            std.meta.eql(cost.image_identity, self.request.image_identity);
    }
};

const ImagePartData = struct {
    type: []const u8 = "",
    data: ?[]const u8 = null,
};

/// Responses `input_image` parts carry the URL as a string; chat-completions
/// `image_url` parts wrap it in an object.
const ImageUrl = struct {
    url: []const u8,

    pub fn jsonParse(alloc: Allocator, source: anytype, options: std.json.ParseOptions) !ImageUrl {
        if (try source.peekNextTokenType() == .string) {
            return .{ .url = try std.json.innerParse([]const u8, alloc, source, options) };
        }
        const Wrapped = struct { url: []const u8 };
        const wrapped = try std.json.innerParse(Wrapped, alloc, source, options);
        return .{ .url = wrapped.url };
    }
};

const ImagePart = struct {
    type: []const u8 = "",
    mediaType: ?[]const u8 = null,
    detail: ?[]const u8 = null,
    data: ?ImagePartData = null,
    image_url: ?ImageUrl = null,
};

const MessageContent = struct {
    parts: []const ImagePart = &.{},

    pub fn jsonParse(alloc: Allocator, source: anytype, options: std.json.ParseOptions) !MessageContent {
        if (try source.peekNextTokenType() == .array_begin) {
            return .{ .parts = try std.json.innerParse([]const ImagePart, alloc, source, options) };
        }
        try source.skipValue();
        return .{};
    }
};

const CostMessage = struct {
    role: []const u8 = "",
    type: []const u8 = "",
    content: MessageContent = .{},
    output: MessageContent = .{},
};

const CostRequest = struct {
    prompt: ?[]const CostMessage = null,
    input: ?[]const CostMessage = null,
    messages: ?[]const CostMessage = null,
};

pub const MeasurementError = error{ OutOfMemory, InvalidRequestMeasurement };

/// Borrows the prepared body and request; releases parsing scratch before returning.
/// Image payloads are transport bytes, not text. Their initial token cost is unknown.
pub fn measureProviderRequest(alloc: Allocator, body: []const u8, request: stream_provider.RequestData) MeasurementError!RequestCost {
    const has_images = image_input: {
        if (request.verified_images) |images| if (images.len != 0) break :image_input true;
        for (request.messages) |message| {
            if (message.images.len != 0) break :image_input true;
            // Retained tool images serialize as follow-up user-message file
            // parts, so they never appear in message.images. Count them as
            // image input or their base64 payloads are priced as text.
            if (message.tool_result_memory) |memory| if (memory.tool_images.len != 0) break :image_input true;
        }
        break :image_input false;
    };
    if (!has_images) {
        const tokens = textTokens(body);
        return .{ .serialized_bytes = body.len, .text_tokens = tokens, .estimated_input_tokens = tokens };
    }

    // Typed parsing borrows unescaped payload strings. Value parsing copies them.
    const parsed = std.json.parseFromSlice(CostRequest, alloc, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidRequestMeasurement,
    };
    defer parsed.deinit();
    const envelopes = @as(u8, @intFromBool(parsed.value.prompt != null)) +
        @intFromBool(parsed.value.input != null) +
        @intFromBool(parsed.value.messages != null);
    if (envelopes > 1) return error.InvalidRequestMeasurement;
    const messages = parsed.value.prompt orelse parsed.value.input orelse parsed.value.messages orelse {
        // Unrecognized envelope: degrade to the conservative text estimate
        // rather than fail the request over a shape this measurer does not know.
        const tokens = textTokens(body);
        return .{ .serialized_bytes = body.len, .text_tokens = tokens, .estimated_input_tokens = tokens };
    };
    var estimator = token_estimate.StreamingEstimator{};
    var identity = std.crypto.hash.sha2.Sha256.init(.{});
    var cursor: usize = 0;
    var found_image = false;
    for (messages) |message| {
        // Retained tool images never land in user-message content on
        // input-style bodies: the responses protocol writes them as
        // input_image parts inside function_call_output items, which carry no
        // role. Scan both carriers.
        const parts = if (std.mem.eql(u8, message.role, "user"))
            message.content.parts
        else if (parsed.value.input != null and std.mem.eql(u8, message.type, "function_call_output"))
            message.output.parts
        else
            continue;
        for (parts) |part| {
            const payload = if (parsed.value.input != null and std.mem.eql(u8, part.type, "input_image"))
                (part.image_url orelse return error.InvalidRequestMeasurement).url
            else if (parsed.value.messages != null and std.mem.eql(u8, part.type, "image_url"))
                (part.image_url orelse return error.InvalidRequestMeasurement).url
            else if (parsed.value.prompt != null and std.mem.eql(u8, part.type, "file") and
                std.mem.startsWith(u8, part.mediaType orelse "", "image/"))
            payload: {
                const data = part.data orelse return error.InvalidRequestMeasurement;
                if (!std.mem.eql(u8, data.type, "data")) return error.InvalidRequestMeasurement;
                break :payload data.data orelse return error.InvalidRequestMeasurement;
            } else continue;
            const address = @intFromPtr(payload.ptr);
            if (address < @intFromPtr(body.ptr)) return error.InvalidRequestMeasurement;
            const offset = address - @intFromPtr(body.ptr);
            if (offset < cursor or offset > body.len or payload.len > body.len - offset) return error.InvalidRequestMeasurement;
            estimator.consume(body[cursor..offset]);
            cursor = offset + payload.len;
            for ([_][]const u8{ part.type, part.mediaType orelse "", part.detail orelse "", payload }) |value| {
                identity.update(std.mem.asBytes(&value.len));
                identity.update(value);
            }
            found_image = true;
        }
    }
    estimator.consume(body[cursor..]);
    const tokens: usize = @intCast(@min(estimator.estimate(), std.math.maxInt(usize)));
    return .{
        .serialized_bytes = body.len,
        .text_tokens = tokens,
        .image_identity = if (found_image) identity.finalResult() else null,
        .estimated_input_tokens = tokens,
    };
}

pub fn calibrateProviderRequest(
    cost: RequestCost,
    calibration: RequestTokenCalibration,
) RequestCost {
    if (!calibration.applies(cost)) return cost;
    const calibrated_tokens = if (cost.image_identity != null)
        if (cost.text_tokens >= calibration.request.text_tokens)
            calibration.exact_input_tokens +| (cost.text_tokens - calibration.request.text_tokens)
        else
            calibration.exact_input_tokens -| (calibration.request.text_tokens - cost.text_tokens)
    else
        multiplyDivideCeilSaturating(cost.serialized_bytes, calibration.exact_input_tokens, calibration.request.serialized_bytes);
    var result = cost;
    result.estimated_input_tokens = if (cost.image_identity != null)
        @max(cost.text_tokens, calibrated_tokens)
    else
        @max(1, calibrated_tokens);
    return result;
}

fn multiplyDivideCeilSaturating(
    value: usize,
    numerator: usize,
    denominator: usize,
) usize {
    std.debug.assert(denominator != 0);
    const whole = std.math.mul(
        usize,
        value / denominator,
        numerator,
    ) catch return std.math.maxInt(usize);
    const remainder_product = std.math.mul(
        usize,
        value % denominator,
        numerator,
    ) catch return std.math.maxInt(usize);
    const partial = remainder_product / denominator +
        @intFromBool(remainder_product % denominator != 0);
    return std.math.add(usize, whole, partial) catch std.math.maxInt(usize);
}

pub const ProviderPrompt = struct {
    instructions: std.ArrayList(ChatMessage),
    messages: std.ArrayList(ChatMessage),

    pub fn deinit(self: *ProviderPrompt, alloc: Allocator) void {
        self.instructions.deinit(alloc);
        self.messages.deinit(alloc);
        self.* = undefined;
    }
};

pub fn buildProviderPrompt(
    alloc: Allocator,
    stable_prefix: []const ChatMessage,
    ephemeral_overlay: []const ChatMessage,
    durable_history: []const ChatMessage,
    current_user_message: ChatMessage,
    within_turn_suffix: []const ChatMessage,
) !ProviderPrompt {
    var instructions: std.ArrayList(ChatMessage) = .empty;
    errdefer instructions.deinit(alloc);
    var messages: std.ArrayList(ChatMessage) = .empty;
    errdefer messages.deinit(alloc);

    try instructions.appendSlice(alloc, stable_prefix);
    try instructions.appendSlice(alloc, ephemeral_overlay);
    try messages.appendSlice(alloc, durable_history);
    try messages.append(alloc, current_user_message);
    try messages.appendSlice(alloc, within_turn_suffix);
    return .{
        .instructions = instructions,
        .messages = messages,
    };
}

test "buildProviderPrompt separates instructions from chronological messages" {
    const alloc = std.testing.allocator;
    const stable_prefix = [_]ChatMessage{
        .{ .role = .system, .content = "stable system prompt" },
        .{ .role = .system, .content = "stable project context" },
    };
    const overlay = [_]ChatMessage{
        .{ .role = .system, .content = "volatile runtime overlay" },
    };
    const history = [_]ChatMessage{
        .{ .role = .user, .content = "history user prompt" },
        .{ .role = .assistant, .content = "history assistant answer" },
    };
    const current = ChatMessage{ .role = .user, .content = "current user prompt" };
    const suffix = [_]ChatMessage{
        .{ .role = .assistant, .content = "within turn assistant" },
    };

    var prompt = try buildProviderPrompt(alloc, &stable_prefix, &overlay, &history, current, &suffix);
    defer prompt.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 3), prompt.instructions.items.len);
    try std.testing.expectEqual(@as(usize, 4), prompt.messages.items.len);
    try std.testing.expectEqualStrings("stable system prompt", prompt.instructions.items[0].content.?);
    try std.testing.expectEqualStrings("stable project context", prompt.instructions.items[1].content.?);
    try std.testing.expectEqualStrings("volatile runtime overlay", prompt.instructions.items[2].content.?);
    try std.testing.expectEqualStrings("history user prompt", prompt.messages.items[0].content.?);
    try std.testing.expectEqualStrings("history assistant answer", prompt.messages.items[1].content.?);
    try std.testing.expectEqualStrings("current user prompt", prompt.messages.items[2].content.?);
    try std.testing.expectEqualStrings("within turn assistant", prompt.messages.items[3].content.?);
}

test "buildProviderPrompt keeps compacted session context out of instructions" {
    const session_runtime = @import("../../session/session.zig");
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var calls = [_]types.ToolCall{.{
        .id = "call_read",
        .name = "read_file",
        .arguments_json = "{\"path\":\"src/portable.zig\"}",
    }};
    var results = [_]types.PersistedToolResult{.{
        .tool_call_id = @constCast("call_read"),
        .tool_name = @constCast("read_file"),
        .status = .success,
        .output = @constCast("portable contents"),
        .output_bytes = 17,
        .stored_output_bytes = 17,
    }};
    var steps = [_]types.ToolExecutionStep{.{
        .assistant = @constCast("Reading the file."),
        .tool_calls = calls[0..],
        .tool_results = results[0..],
    }};
    var files = [_]types.FileEvidence{.{
        .path = @constCast("src/portable.zig"),
        .tool_call_id = @constCast("call_read"),
        .tool_name = @constCast("read_file"),
        .action = .read,
        .status = .success,
        .model_view_covers_full_file = true,
    }};
    const history = [_]types.HistoryTurn{
        .{ .compacted_summary = .{
            .summary = @constCast("LEADING_SUMMARY_ONLY"),
            .removed_turn_count = 2,
            .compaction_count = 1,
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("inspect portable history") },
            .assistant = @constCast("inspection complete"),
            .execution = .{ .tool_steps = steps[0..], .files = files[0..] },
        } },
        .{ .compacted_summary = .{
            .summary = @constCast("LATE_SUMMARY_ONLY"),
            .removed_turn_count = 1,
            .compaction_count = 2,
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("run portable server") },
            .assistant = @constCast("server history is inert"),
        } },
        .{ .interrupted = .{
            .user = .{ .text = @constCast("stop portable work") },
            .assistant = @constCast("partial portable work"),
        } },
    };

    var projected_history: std.ArrayList(ChatMessage) = .empty;
    defer projected_history.deinit(arena);
    try session_runtime.appendHistoryChatMessages(arena, &projected_history, &history);

    const stable_prefix = [_]ChatMessage{
        .{ .role = .system, .content = "stable system prompt" },
        .{ .role = .system, .content = "stable project context" },
    };
    const overlay = [_]ChatMessage{.{ .role = .system, .content = "ephemeral overlay" }};
    const current = ChatMessage{ .role = .user, .content = "current portable prompt" };
    const suffix = [_]ChatMessage{.{ .role = .assistant, .content = "within-turn suffix" }};
    var prompt = try buildProviderPrompt(
        arena,
        &stable_prefix,
        &overlay,
        projected_history.items,
        current,
        &suffix,
    );
    defer prompt.deinit(arena);

    var leading_summary_count: usize = 0;
    var late_summary_count: usize = 0;
    var file_evidence_count: usize = 0;
    var interruption_count: usize = 0;
    for (prompt.instructions.items) |entry| try std.testing.expectEqual(types.ChatRole.system, entry.role);
    for (prompt.messages.items) |entry| {
        try std.testing.expect(entry.role != .system);
        const content = entry.content orelse continue;
        if (std.mem.find(u8, content, "LEADING_SUMMARY_ONLY") != null) {
            try std.testing.expectEqual(types.ChatRole.user, entry.role);
            leading_summary_count += 1;
        }
        if (std.mem.find(u8, content, "LATE_SUMMARY_ONLY") != null) {
            try std.testing.expectEqual(types.ChatRole.user, entry.role);
            late_summary_count += 1;
        }
        if (std.mem.find(u8, content, "src/portable.zig") != null and
            std.mem.find(u8, content, "Session file evidence") != null)
        {
            try std.testing.expectEqual(types.ChatRole.user, entry.role);
            file_evidence_count += 1;
        }
        if (std.mem.find(u8, content, "<turn_aborted>") != null) {
            try std.testing.expectEqual(types.ChatRole.user, entry.role);
            interruption_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), leading_summary_count);
    try std.testing.expectEqual(@as(usize, 1), late_summary_count);
    try std.testing.expectEqual(@as(usize, 1), file_evidence_count);
    try std.testing.expectEqual(@as(usize, 1), interruption_count);
    try std.testing.expectEqualStrings("current portable prompt", prompt.messages.items[prompt.messages.items.len - 2].content.?);
    try std.testing.expectEqualStrings("within-turn suffix", prompt.messages.items[prompt.messages.items.len - 1].content.?);
}

test "provider request measurement includes serialized structure" {
    const compact = try measureProviderRequest(std.testing.allocator, "{\"prompt\":[{\"role\":\"user\",\"content\":\"same\"}]}", measurement_test_request(false));
    const fragmented = try measureProviderRequest(
        std.testing.allocator,
        "{\"prompt\":[{\"role\":\"user\",\"content\":\"s\"},{\"role\":\"user\",\"content\":\"a\"},{\"role\":\"user\",\"content\":\"m\"},{\"role\":\"user\",\"content\":\"e\"}]}",
        measurement_test_request(false),
    );
    try std.testing.expect(fragmented.serialized_bytes > compact.serialized_bytes);
    try std.testing.expect(fragmented.estimated_input_tokens > compact.estimated_input_tokens);
}

test "provider request image accounting excludes encoded payload length" {
    const Case = struct { prefix: []const u8, suffix: []const u8 };
    const cases = [_]Case{
        .{ .prefix = "{\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_image\",\"image_url\":\"data:image/png;base64,", .suffix = "\"}]}]}" },
        .{ .prefix = "{\"prompt\":[{\"role\":\"user\",\"content\":[{\"type\":\"file\",\"mediaType\":\"image/png\",\"data\":{\"type\":\"data\",\"data\":\"", .suffix = "\"}}]}]}" },
    };
    inline for (cases) |case| {
        const small = try measureProviderRequest(std.testing.allocator, case.prefix ++ "AAAA" ++ case.suffix, measurement_test_request(true));
        const large = try measureProviderRequest(std.testing.allocator, case.prefix ++ ("AAAA" ** 1000) ++ case.suffix, measurement_test_request(true));
        try std.testing.expect(large.serialized_bytes > small.serialized_bytes);
        try std.testing.expectEqual(small.text_tokens, large.text_tokens);
        try std.testing.expectEqual(small.estimated_input_tokens, large.estimated_input_tokens);
        try std.testing.expect(small.image_identity != null);
        try std.testing.expect(!std.meta.eql(small.image_identity, large.image_identity));
    }
}

test "provider request measurement learns the prior exact token density" {
    const current = RequestCost{
        .serialized_bytes = 1_456_988,
        .text_tokens = 365_113,
        .estimated_input_tokens = 365_113,
    };
    const calibrated = calibrateProviderRequest(current, .{
        .request = .{ .serialized_bytes = 767_736, .text_tokens = 192_000, .estimated_input_tokens = 192_000 },
        .exact_input_tokens = 398_710,
    });

    try std.testing.expect(calibrated.estimated_input_tokens > 695_142);
    try std.testing.expect(calibrated.estimated_input_tokens >= current.estimated_input_tokens);
}

test "provider usage corrects a serialized estimate downward" {
    const cost = RequestCost{ .serialized_bytes = 34_210, .text_tokens = 8_892, .estimated_input_tokens = 8_892 };
    const calibrated = calibrateProviderRequest(cost, .{ .request = cost, .exact_input_tokens = 6_030 });
    try std.testing.expectEqual(@as(usize, 6_030), calibrated.estimated_input_tokens);
    try std.testing.expectEqual(cost.text_tokens, calibrated.text_tokens);
}

fn measurement_test_request(with_images: bool) stream_provider.RequestData {
    return .{
        .model = "fixture/model",
        .messages = if (with_images) &.{.{
            .role = .user,
            .images = &.{.{ .path = @constCast("fixture.png"), .media_type = @constCast("image/png") }},
        }} else &.{},
        .tool_choice = .none,
        .provider_options = .{},
    };
}

test "provider request image accounting preserves text and tool payloads" {
    const body =
        \\{"input":[{"role":"user","content":[{"type":"input_text","text":"data:image/png;base64,AAAA"},{"image_url":"data:image/png;base64,BBBB","type":"input_image"}]},{"type":"function_call","arguments":"{\"image_url\":\"AAAA\"}"},{"type":"function_call_output","output":"data:image/png;base64,AAAA"}]}
    ;
    const measured = try measureProviderRequest(std.testing.allocator, body, measurement_test_request(true));
    const without_image_payload =
        \\{"input":[{"role":"user","content":[{"type":"input_text","text":"data:image/png;base64,AAAA"},{"image_url":"","type":"input_image"}]},{"type":"function_call","arguments":"{\"image_url\":\"AAAA\"}"},{"type":"function_call_output","output":"data:image/png;base64,AAAA"}]}
    ;
    try std.testing.expectEqual(textTokens(without_image_payload), measured.text_tokens);

    const file_text = "{\"prompt\":[{\"role\":\"user\",\"content\":[{\"type\":\"file\",\"mediaType\":\"text/plain\",\"data\":{\"type\":\"data\",\"data\":\"AAAA\"}}]}]}";
    const non_image = try measureProviderRequest(std.testing.allocator, file_text, measurement_test_request(true));
    try std.testing.expectEqual(textTokens(file_text), non_image.text_tokens);
    try std.testing.expectEqual(@as(?[32]u8, null), non_image.image_identity);
}

test "provider request measurement prices retained tool images as image input" {
    const body =
        \\{"prompt":[{"role":"tool","content":[{"type":"tool-result","toolCallId":"call_1","output":{"type":"content","value":[{"type":"text","text":"capture"}]}}]},{"role":"user","content":[{"type":"text","text":"Attached image(s) from the tool result."},{"type":"file","mediaType":"image/png","data":{"type":"data","data":"AAAABBBBCCCCDDDD"}}]}]}
    ;
    var request = measurement_test_request(false);
    request.messages = &.{.{
        .role = .tool,
        .content = "capture",
        .tool_result_memory = .{
            .tool_images = &.{.{ .data = @constCast("AAAABBBBCCCCDDDD"), .mime_type = @constCast("image/png") }},
        },
    }};
    const measured = try measureProviderRequest(std.testing.allocator, body, request);
    try std.testing.expect(measured.image_identity != null);
    const without_image_payload =
        \\{"prompt":[{"role":"tool","content":[{"type":"tool-result","toolCallId":"call_1","output":{"type":"content","value":[{"type":"text","text":"capture"}]}}]},{"role":"user","content":[{"type":"text","text":"Attached image(s) from the tool result."},{"type":"file","mediaType":"image/png","data":{"type":"data","data":""}}]}]}
    ;
    try std.testing.expectEqual(textTokens(without_image_payload), measured.text_tokens);

    // Tool images must not be priced as text: their encoded payload inflates
    // the estimate by roughly bytes/4 phantom tokens.
    const text_only = try measureProviderRequest(std.testing.allocator, body, measurement_test_request(false));
    try std.testing.expect(text_only.estimated_input_tokens > measured.estimated_input_tokens);
}

test "provider request measurement excludes responses-protocol tool image payloads" {
    // The responses protocol writes retained tool images as input_image parts
    // inside function_call_output items, which carry no role.
    const body =
        \\{"input":[{"type":"function_call_output","call_id":"call_1","output":[{"type":"input_text","text":"capture"},{"type":"input_image","image_url":"data:image/png;base64,AAAABBBBCCCCDDDD"}]},{"role":"user","content":[{"type":"input_text","text":"next"}]}]}
    ;
    var request = measurement_test_request(false);
    request.messages = &.{.{
        .role = .tool,
        .content = "capture",
        .tool_result_memory = .{
            .tool_images = &.{.{ .data = @constCast("AAAABBBBCCCCDDDD"), .mime_type = @constCast("image/png") }},
        },
    }};
    const measured = try measureProviderRequest(std.testing.allocator, body, request);
    try std.testing.expect(measured.image_identity != null);
    const without_image_payload =
        \\{"input":[{"type":"function_call_output","call_id":"call_1","output":[{"type":"input_text","text":"capture"},{"type":"input_image","image_url":""}]},{"role":"user","content":[{"type":"input_text","text":"next"}]}]}
    ;
    try std.testing.expectEqual(textTokens(without_image_payload), measured.text_tokens);
}

test "provider request measurement excludes chat-completions image payloads" {
    // Chat-completions bodies carry user images, including retained tool
    // images, as image_url parts with data URLs.
    const body =
        \\{"model":"fixture/model","messages":[{"role":"tool","tool_call_id":"call_1","content":"capture"},{"role":"user","content":[{"type":"text","text":"The tool \"read_file\" returned 1 image(s)."},{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAABBBBCCCCDDDD"}}]}]}
    ;
    var request = measurement_test_request(false);
    request.messages = &.{.{
        .role = .tool,
        .content = "capture",
        .tool_result_memory = .{
            .tool_images = &.{.{ .data = @constCast("AAAABBBBCCCCDDDD"), .mime_type = @constCast("image/png") }},
        },
    }};
    const measured = try measureProviderRequest(std.testing.allocator, body, request);
    try std.testing.expect(measured.image_identity != null);
    const without_image_payload =
        \\{"model":"fixture/model","messages":[{"role":"tool","tool_call_id":"call_1","content":"capture"},{"role":"user","content":[{"type":"text","text":"The tool \"read_file\" returned 1 image(s)."},{"type":"image_url","image_url":{"url":""}}]}]}
    ;
    try std.testing.expectEqual(textTokens(without_image_payload), measured.text_tokens);
}

test "provider request measurement degrades to text estimate on unknown envelopes" {
    const body =
        \\{"model":"fixture/model","contents":[{"role":"user","parts":[{"inline_data":{"data":"AAAA"}}]}]}
    ;
    const measured = try measureProviderRequest(std.testing.allocator, body, measurement_test_request(true));
    try std.testing.expectEqual(textTokens(body), measured.estimated_input_tokens);
    try std.testing.expectEqual(@as(?[32]u8, null), measured.image_identity);
}

test "provider request image calibration uses exact usage plus text growth without compounding" {
    const first = RequestCost{ .serialized_bytes = 4_000_000, .text_tokens = 100, .image_identity = [_]u8{1} ** 32, .estimated_input_tokens = 100 };
    var next = first;
    next.text_tokens = 150;
    next.estimated_input_tokens = 150;
    next.serialized_bytes += 200;
    const calibrated = calibrateProviderRequest(next, .{ .request = first, .exact_input_tokens = 1000 });
    try std.testing.expectEqual(@as(usize, 1050), calibrated.estimated_input_tokens);
    try std.testing.expectEqual(@as(usize, 150), calibrated.text_tokens);
    var third = next;
    third.text_tokens = 200;
    third.estimated_input_tokens = 200;
    const repeated = calibrateProviderRequest(third, .{ .request = calibrated, .exact_input_tokens = 1050 });
    try std.testing.expectEqual(@as(usize, 1100), repeated.estimated_input_tokens);
    try std.testing.expectEqual(@as(usize, 1000), calibrateProviderRequest(first, .{ .request = calibrated, .exact_input_tokens = 1050 }).estimated_input_tokens);

    next.image_identity = [_]u8{2} ** 32;
    try std.testing.expectEqual(next, calibrateProviderRequest(next, .{ .request = first, .exact_input_tokens = 1000 }));
    next.image_identity = null;
    try std.testing.expectEqual(next, calibrateProviderRequest(next, .{ .request = first, .exact_input_tokens = 1000 }));
    try std.testing.expectEqual(first, calibrateProviderRequest(first, .{ .request = next, .exact_input_tokens = 1000 }));
    try std.testing.expectEqual(first, calibrateProviderRequest(first, .{ .request = first, .exact_input_tokens = 0 }));
    try std.testing.expectEqual(@as(usize, 150), calibrateProviderRequest(calibrated, .{ .request = third, .exact_input_tokens = 1 }).estimated_input_tokens);
    try std.testing.expectEqual(std.math.maxInt(usize), calibrateProviderRequest(calibrated, .{ .request = first, .exact_input_tokens = std.math.maxInt(usize) }).estimated_input_tokens);
}

test "provider request image accounting borrows large payloads and releases scratch" {
    const alloc = std.testing.allocator;
    const payload = try alloc.alloc(u8, 4 * 1024 * 1024);
    defer alloc.free(payload);
    @memset(payload, 'A');
    const body = try std.fmt.allocPrint(alloc, "{{\"input\":[{{\"role\":\"user\",\"content\":[{{\"type\":\"input_image\",\"image_url\":\"data:image/png;base64,{s}\"}}]}}]}}", .{payload});
    defer alloc.free(body);
    var storage: [8192]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&storage);
    var tracked = std.testing.FailingAllocator.init(scratch.allocator(), .{});
    const cost = try measureProviderRequest(tracked.allocator(), body, measurement_test_request(true));
    try std.testing.expect(cost.text_tokens < 100);
    try std.testing.expectEqual(tracked.allocated_bytes, tracked.freed_bytes);
}

test "provider request image identity includes ordering media type and detail" {
    const alloc = std.testing.allocator;
    const first = "{\"type\":\"input_image\",\"image_url\":\"data:image/png;base64,AAAA\",\"detail\":\"auto\"}";
    const second = "{\"type\":\"input_image\",\"image_url\":\"data:image/png;base64,BBBB\"}";
    const reference = try measureProviderRequest(alloc, "{\"input\":[{\"role\":\"user\",\"content\":[" ++ first ++ "," ++ second ++ "]}]}", measurement_test_request(true));
    inline for (.{
        "{\"input\":[{\"role\":\"user\",\"content\":[" ++ second ++ "," ++ first ++ "]}]}",
        "{\"input\":[{\"role\":\"user\",\"content\":[" ++ first ++ "]}]}",
        "{\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_image\",\"image_url\":\"data:image/png;base64,AAAA\",\"detail\":\"high\"}," ++ second ++ "]}]}",
        "{\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_image\",\"image_url\":\"data:image/jpeg;base64,AAAA\",\"detail\":\"auto\"}," ++ second ++ "]}]}",
    }) |body| {
        const changed = try measureProviderRequest(alloc, body, measurement_test_request(true));
        try std.testing.expect(!std.meta.eql(reference.image_identity, changed.image_identity));
    }
    var no_storage: [0]u8 = .{};
    var scratch = std.heap.FixedBufferAllocator.init(&no_storage);
    const text = try measureProviderRequest(scratch.allocator(), "{\"input\":[]}", measurement_test_request(false));
    try std.testing.expectEqual(textTokens("{\"input\":[]}"), text.text_tokens);
}

test "provider request image accounting handles allocation and malformed input failures" {
    const Probe = struct {
        fn run(alloc: Allocator) !void {
            _ = try measureProviderRequest(alloc, "{\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_image\",\"image_url\":\"data:image/png;base64,AAAA\"}]}]}", measurement_test_request(true));
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});
    for ([_][]const u8{
        "{",
        "{\"input\":[],\"prompt\":[]}",
        "{\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_image\"}]}]}",
        "{\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_image\",\"image_url\":\"escaped\\nimage\"}]}]}",
        // Prompt-shape file parts must carry the nested v4 data object; every
        // other shape is rejected rather than mis-measured.
        "{\"prompt\":[{\"role\":\"user\",\"content\":[{\"type\":\"file\",\"mediaType\":\"image/png\",\"data\":\"AAAA\"}]}]}",
        "{\"prompt\":[{\"role\":\"user\",\"content\":[{\"type\":\"file\",\"mediaType\":\"image/png\"}]}]}",
        "{\"prompt\":[{\"role\":\"user\",\"content\":[{\"type\":\"file\",\"mediaType\":\"image/png\",\"data\":{\"type\":\"url\",\"url\":\"https://x/y.png\"}}]}]}",
        "{\"prompt\":[{\"role\":\"user\",\"content\":[{\"type\":\"file\",\"mediaType\":\"image/png\",\"data\":{\"type\":\"data\"}}]}]}",
        "{\"prompt\":[{\"role\":\"user\",\"content\":[{\"type\":\"file\",\"mediaType\":\"image/png\",\"data\":{\"type\":\"data\",\"data\":\"escaped\\nimage\"}}]}]}",
    }) |body| {
        try std.testing.expectError(error.InvalidRequestMeasurement, measureProviderRequest(std.testing.allocator, body, measurement_test_request(true)));
    }
}
