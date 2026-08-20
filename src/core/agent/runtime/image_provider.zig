const std = @import("std");
const agent_stream_provider = @import("../stream_provider.zig");
const route_snapshot = @import("../../gateway/route_snapshot.zig");
const image_attachments = @import("../../images/image_attachments.zig");
const session_usage = @import("../../session/session_usage.zig");
const types = @import("../../shared/types.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const runtime_gateway_step = @import("gateway_step.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;

pub const Request = struct {
    adapter: agent_stream_provider.ProviderAdapter,
    route: *const route_snapshot.RouteSnapshot,
    credential: []const u8,
    tenant: ?[]const u8,
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
    const messages = [_]ChatMessage{
        .{ .role = .system, .content = system_prompt },
        .{ .role = .user, .content = user_prompt },
    };
    const descriptor = request.route.visionDescriptor() orelse
        return error.VisionUnavailable;
    var capture = StreamCapture{
        .alloc = alloc,
        .max_bytes = request.capture_limit_bytes,
    };
    defer capture.deinit();
    var delivery = runtime_gateway_step.DeliveryCertainty.init();
    var attempt_evidence: agent_stream_provider.AttemptEvidence = .{};
    var streamed = try runtime_gateway_step.streamModelRequest(
        request.adapter,
        alloc,
        request.route,
        request.credential,
        request.tenant,
        request.session_id,
        descriptor.id,
        request.retry_count,
        .{
            .model = descriptor.id,
            .serialized_tools = "[]",
            .messages = &messages,
            .tool_choice = .none,
            .capabilities = descriptor.capabilities,
            .budget = .{ .cancel_flag = request.cancel_flag },
            .verified_images = images,
            .response_format = request.response_format,
        },
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
        null,
        request.capture_limit_bytes,
        null,
        .transport,
    );
    defer streamed.deinit(alloc);

    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (streamed.status != .ok) return error.ImageProviderUnavailable;
    if (capture.failed) return error.OutOfMemory;
    if (capture.saw_content) {
        return .{
            .text = try capture.takeText(),
            .observed_bytes = capture.observed_bytes,
            .usage = .{
                .input_tokens = streamed.completion.usage.input_tokens orelse 0,
                .output_tokens = streamed.completion.usage.output_tokens orelse 0,
            },
        };
    }
    if (streamed.completion.content) |content| {
        const retained_len = @min(content.len, request.capture_limit_bytes);
        return .{
            .text = try alloc.dupe(u8, content[0..retained_len]),
            .observed_bytes = content.len,
            .usage = .{
                .input_tokens = streamed.completion.usage.input_tokens orelse 0,
                .output_tokens = streamed.completion.usage.output_tokens orelse 0,
            },
        };
    }
    return error.InvalidProviderResponse;
}

fn onContentChunk(raw: *anyopaque, chunk: []const u8) void {
    const capture: *StreamCapture = @ptrCast(@alignCast(raw));
    capture.appendContent(chunk);
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

    fn appendContent(self: *StreamCapture, chunk: []const u8) void {
        self.saw_content = self.saw_content or chunk.len > 0;
        self.observed_bytes +|= chunk.len;
        const remaining = self.max_bytes -| self.text.items.len;
        self.text.appendSlice(self.alloc, chunk[0..@min(chunk.len, remaining)]) catch {
            self.failed = true;
        };
    }
};

test "shared image provider capture counts all streamed bytes while retaining its bound" {
    var capture = StreamCapture{
        .alloc = std.testing.allocator,
        .max_bytes = 4,
    };
    defer capture.deinit();

    capture.appendContent("abc");
    capture.appendContent("二xyz");

    try std.testing.expectEqual(@as(usize, "abc二xyz".len), capture.observed_bytes);
    try std.testing.expectEqualStrings("abc\xe4", capture.text.items);
}
