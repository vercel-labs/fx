const std = @import("std");
const agent_stream_provider = @import("../stream_provider.zig");
const image_attachments = @import("../../images/image_attachments.zig");
const model_capabilities = @import("../../config/model_capabilities.zig");
const types = @import("../../shared/types.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const session_usage = @import("../../session/session_usage.zig");
const runtime_gateway_step = @import("gateway_step.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;

const model = "google/gemini-2.5-flash";

pub const Request = struct {
    stream_provider: agent_stream_provider.Provider,
    api_key: []const u8,
    credential_source: ?types.CredentialSource = null,
    gateway_team: ?[]const u8,
    session_id: ?[]const u8 = null,
    retry_count: usize,
    chat_url: []const u8,
    cancel_flag: *std.atomic.Value(bool),
    usage: ?*session_usage.Usage = null,
    usage_allocator: Allocator = std.heap.c_allocator,
    trace_ctx: debug_trace.TraceContext,
    capture_limit_bytes: usize,
    response_format: agent_stream_provider.StructuredResponseFormat,
};

pub const Result = struct {
    text: []u8,
    observed_bytes: usize,
    usage: types.ToolUsage,

    pub fn deinit(self: *Result, alloc: Allocator) void {
        alloc.free(self.text);
        self.* = undefined;
    }
};

pub fn inspect(
    alloc: Allocator,
    system_prompt: []const u8,
    user_prompt: []const u8,
    images: []const image_attachments.VerifiedSnapshot,
    request: Request,
) !Result {
    const messages = [_]ChatMessage{
        .{ .role = .system, .content = system_prompt },
        .{ .role = .user, .content = user_prompt },
    };
    const provider_opts = model_capabilities.resolveProviderOptions(model, .auto, false);
    const payload = try request.stream_provider.build(
        alloc,
        .{
            .model = model,
            .serialized_tools = "[]",
            .messages = &messages,
            .tool_choice = .none,
            .provider_options = provider_opts,
            .budget = .{ .cancel_flag = request.cancel_flag },
            .verified_images = images,
            .response_format = request.response_format,
        },
    );
    defer alloc.free(payload);

    var capture = StreamCapture{
        .alloc = alloc,
        .max_bytes = request.capture_limit_bytes,
    };
    defer capture.deinit();
    var delivery = runtime_gateway_step.DeliveryCertainty.init();
    var attempt_evidence: agent_stream_provider.AttemptEvidence = .{};
    const streamed = try runtime_gateway_step.streamGatewayCompletion(
        request.stream_provider,
        alloc,
        request.api_key,
        request.credential_source,
        null,
        request.gateway_team,
        request.session_id,
        model,
        request.retry_count,
        request.chat_url,
        payload,
        null,
        &delivery,
        &attempt_evidence,
        @ptrCast(&capture),
        onContentChunk,
        null,
        null,
        null,
        request.cancel_flag,
        request.usage,
        request.usage_allocator,
        request.trace_ctx,
        request.capture_limit_bytes,
        .transport,
    );

    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (streamed.status != .ok) return error.ImageProviderUnavailable;
    if (capture.failed) return error.OutOfMemory;

    const tool_usage = types.ToolUsage{
        .input_tokens = streamed.completion.usage.input_tokens orelse 0,
        .output_tokens = streamed.completion.usage.output_tokens orelse 0,
    };
    if (capture.saw_content) {
        return .{
            .text = try capture.takeText(),
            .observed_bytes = capture.observed_bytes,
            .usage = tool_usage,
        };
    }
    if (streamed.completion.content) |content| {
        const retained_len = @min(content.len, request.capture_limit_bytes);
        return .{
            .text = try alloc.dupe(u8, content[0..retained_len]),
            .observed_bytes = content.len,
            .usage = tool_usage,
        };
    }
    return error.InvalidProviderResponse;
}

const StreamCapture = struct {
    alloc: Allocator,
    text: std.ArrayList(u8) = .empty,
    failed: bool = false,
    max_bytes: usize,
    observed_bytes: usize = 0,
    saw_content: bool = false,

    fn deinit(self: *StreamCapture) void {
        self.text.deinit(self.alloc);
        self.text = .empty;
    }

    fn takeText(self: *StreamCapture) ![]u8 {
        return self.text.toOwnedSlice(self.alloc);
    }
};

fn onContentChunk(raw: *anyopaque, chunk: []const u8) void {
    const capture: *StreamCapture = @ptrCast(@alignCast(raw));
    capture.saw_content = capture.saw_content or chunk.len > 0;
    capture.observed_bytes +|= chunk.len;
    const remaining = capture.max_bytes -| capture.text.items.len;
    capture.text.appendSlice(capture.alloc, chunk[0..@min(chunk.len, remaining)]) catch {
        capture.failed = true;
    };
}

test "shared image provider capture counts all streamed bytes while retaining its bound" {
    var capture = StreamCapture{
        .alloc = std.testing.allocator,
        .max_bytes = 4,
    };
    defer capture.deinit();

    onContentChunk(@ptrCast(&capture), "abc");
    onContentChunk(@ptrCast(&capture), "二xyz");

    try std.testing.expectEqual(@as(usize, "abc二xyz".len), capture.observed_bytes);
    try std.testing.expectEqualStrings("abc\xe4", capture.text.items);
}
