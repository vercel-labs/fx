const std = @import("std");
const agent_stream_provider = @import("../stream_provider.zig");
const image_attachments = @import("../../images/image_attachments.zig");
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
    const instructions = [_]ChatMessage{.{ .role = .system, .content = system_prompt }};
    const messages = [_]ChatMessage{.{ .role = .user, .content = user_prompt }};
    var capture = StreamCapture{
        .alloc = alloc,
        .max_bytes = request.capture_limit_bytes,
    };
    defer capture.deinit();
    var delivery = runtime_gateway_step.DeliveryCertainty.init();
    var attempt_evidence: agent_stream_provider.AttemptEvidence = .{};
    var streamed = try runtime_gateway_step.streamModelCompletion(
        request.stream_provider,
        alloc,
        .{
            .credential = if (request.credential_source == .host_managed)
                .host_managed
            else
                .{ .direct = .{
                    .secret_bytes = request.api_key,
                    .source = request.credential_source orelse .ai_gateway_api_key,
                    .tenant_context = request.gateway_team,
                } },
            .session_id = request.session_id,
            .model = model,
            .retry_count = request.retry_count,
            .instructions = &instructions,
            .messages = &messages,
            .tool_choice = .none,
            .provider_options = .{},
            .budget = .{ .cancel_flag = request.cancel_flag },
            .verified_images = images,
            .response_format = request.response_format,
            .trace_ctx = request.trace_ctx,
            .content_capture_limit = request.capture_limit_bytes,
            .delivery = &delivery,
            .attempt_evidence = &attempt_evidence,
            .events = .{ .context = &capture, .emit_fn = onEvent },
            .cancel_flag = request.cancel_flag,
        },
        request.usage,
        request.usage_allocator,
    );
    defer streamed.deinit(alloc);

    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (std.meta.activeTag(streamed) == .failed) return error.ImageProviderUnavailable;
    if (capture.failed) return error.OutOfMemory;
    const completion = streamed.completed.completion;

    const tool_usage = types.ToolUsage{
        .input_tokens = completion.usage.input_tokens orelse 0,
        .output_tokens = completion.usage.output_tokens orelse 0,
    };
    if (capture.saw_content) {
        return .{
            .text = try capture.takeText(),
            .observed_bytes = capture.observed_bytes,
            .usage = tool_usage,
        };
    }
    if (completion.content) |content| {
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

fn onEvent(raw: *anyopaque, event: agent_stream_provider.Event) void {
    switch (event) {
        .content_delta => |chunk| onContentChunk(raw, chunk),
        else => {},
    }
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
