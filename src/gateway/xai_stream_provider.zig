const std = @import("std");
const agent_stream_provider = @import("../core/agent/stream_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");
const xai_json = @import("xai_json.zig");

const Allocator = std.mem.Allocator;

pub const default_chat_url = xai_json.default_chat_url;
pub const e2e_chat_url_env = "FX_E2E_XAI_CHAT_URL";

pub fn resolveChatUrl() []const u8 {
    if (io_mod.getenv(e2e_chat_url_env)) |value| {
        const candidate = std.mem.trimEnd(u8, value, "/");
        if (isLoopbackHttpUrl(candidate)) return candidate;
    }
    return default_chat_url;
}

pub fn chatUrlForSource(source: ?types.CredentialSource) []const u8 {
    if (source == .grok_oauth) return resolveChatUrl();
    return "";
}

fn isLoopbackHttpUrl(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return false;
    const host_component = uri.host orelse return false;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = host_component.toRaw(&host_buf) catch return false;
    return std.mem.eql(u8, host, "127.0.0.1") or
        std.ascii.eqlIgnoreCase(host, "localhost") or
        std.mem.eql(u8, host, "[::1]");
}

pub fn stream(
    alloc: Allocator,
    request: agent_stream_provider.Request,
) !agent_stream_provider.Result {
    var client: std.http.Client = .{
        .allocator = alloc,
        .io = io_mod.getIo(),
    };
    defer client.deinit();

    var body = std.Io.Writer.Allocating.init(alloc);
    defer body.deinit();

    const auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{request.api_key});
    defer alloc.free(auth_header);

    request.delivery.markPossiblySent();
    const fetch_result = client.fetch(.{
        .location = .{ .url = request.chat_url },
        .method = .POST,
        .payload = request.payload,
        .headers = .{
            .user_agent = .{ .override = gateway_client.user_agent },
            .accept_encoding = .omit,
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = auth_header },
        },
        .response_writer = &body.writer,
    }) catch |err| {
        request.attempt_evidence.network_failure = gateway_client.networkFailureEvidence(
            err,
            request.delivery.load(),
        );
        return err;
    };

    const completion = try consumeSse(
        alloc,
        body.written(),
        request.callback_ctx,
        request.on_content_chunk,
        request.on_tool_start,
    );
    errdefer {
        if (completion.content) |content| alloc.free(content);
        types.freeToolCallSlice(alloc, @constCast(completion.tool_calls));
    }

    const err_body = if (fetch_result.status != .ok)
        try alloc.dupe(u8, body.written())
    else
        null;

    return .{
        .status = fetch_result.status,
        .completion = completion,
        .err_body = err_body,
        .ownership = .owned,
    };
}

fn consumeSse(
    alloc: Allocator,
    bytes: []const u8,
    callback_ctx: *anyopaque,
    on_content_chunk: agent_stream_provider.StreamCallback,
    on_tool_start: ?agent_stream_provider.ToolStartCallback,
) !types.GatewayCompletion {
    var content = std.ArrayList(u8).empty;
    errdefer content.deinit(alloc);
    var tool_id: ?[]u8 = null;
    errdefer if (tool_id) |value| alloc.free(value);
    var tool_name: ?[]u8 = null;
    errdefer if (tool_name) |value| alloc.free(value);
    var tool_arguments = std.ArrayList(u8).empty;
    errdefer tool_arguments.deinit(alloc);
    var tool_started = false;
    var finish_reason: ?types.ProviderFinishReason = null;
    var input_tokens: ?u64 = null;
    var output_tokens: ?u64 = null;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const json_bytes = xai_json.parseSseDataLine(raw_line) orelse continue;
        var delta = try xai_json.parseChatCompletionsDelta(alloc, json_bytes);
        defer delta.deinit(alloc);
        if (delta.content) |chunk| {
            try content.appendSlice(alloc, chunk);
            on_content_chunk(callback_ctx, chunk);
        }
        if (delta.tool_call_id) |id| {
            if (tool_id == null) tool_id = try alloc.dupe(u8, id);
        }
        if (delta.tool_call_name) |name| {
            if (tool_name == null) {
                tool_name = try alloc.dupe(u8, name);
                if (!tool_started) {
                    if (on_tool_start) |callback| {
                        callback(callback_ctx, tool_id orelse "", name, null);
                    }
                    tool_started = true;
                }
            }
        }
        if (delta.tool_call_arguments) |arguments| {
            try tool_arguments.appendSlice(alloc, arguments);
        }
        if (delta.finish_reason) |reason| {
            finish_reason = types.ProviderFinishReason.parse_legacy(reason);
        }
        if (delta.input_tokens) |value| input_tokens = value;
        if (delta.output_tokens) |value| output_tokens = value;
    }

    var tool_calls: []types.ToolCall = &.{};
    if (tool_id != null or tool_name != null or tool_arguments.items.len > 0) {
        const calls = try alloc.alloc(types.ToolCall, 1);
        calls[0] = .{
            .id = tool_id orelse try alloc.dupe(u8, ""),
            .name = tool_name orelse try alloc.dupe(u8, ""),
            .arguments_json = try tool_arguments.toOwnedSlice(alloc),
        };
        tool_id = null;
        tool_name = null;
        tool_calls = calls;
        if (finish_reason == null) finish_reason = .tool_calls;
    }

    return .{
        .content = if (content.items.len > 0) try content.toOwnedSlice(alloc) else null,
        .tool_calls = tool_calls,
        .finish_reason = finish_reason,
        .usage = .{
            .input_tokens = input_tokens,
            .output_tokens = output_tokens,
        },
    };
}

test "xai chat url is the public api host" {
    try std.testing.expectEqualStrings("https://api.x.ai/v1/chat/completions", default_chat_url);
    try std.testing.expect(xai_json.isXaiChatUrl(default_chat_url));
    try std.testing.expect(xai_json.isXaiChatUrl("http://127.0.0.1:9/v1/chat/completions"));
    try std.testing.expect(!xai_json.isXaiChatUrl("https://ai-gateway.vercel.sh/v3/ai/language-model"));
}
