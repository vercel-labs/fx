const std = @import("std");
const agent_stream_provider = @import("../agent/stream_provider.zig");
const runtime_gateway_step = @import("../agent/runtime/gateway_step.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const max_title_chars: usize = 50;
const max_prompt_bytes: usize = 960;
const max_response_bytes: usize = 256;

const instructions =
    "Generate a brief title that helps the user find this conversation later. " ++
    "Use the user's language. Focus on the main task or question. " ++
    "Return one natural single-line title of at most 50 characters. " ++
    "Do not answer the request. Do not use quotes, markdown, or trailing punctuation.";

pub const Request = struct {
    stream_provider: agent_stream_provider.Provider,
    credential: agent_stream_provider.CredentialLease,
    session_id: ?[]const u8,
    model: []const u8,
    retry_count: usize,
    user_prompt: []const u8,
    cancel_flag: *std.atomic.Value(bool),
    trace_ctx: debug_trace.TraceContext,
};

/// Returns an owned generated title, or null when the provider response does
/// not contain a usable title. The caller owns the returned bytes.
pub fn generate(alloc: Allocator, request: Request) !?[]u8 {
    const prompt = try buildPrompt(alloc, request.user_prompt);
    defer alloc.free(prompt);
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = prompt }};
    var capture: StreamCapture = .{};
    var delivery = runtime_gateway_step.DeliveryCertainty.init();
    var attempt_evidence: agent_stream_provider.AttemptEvidence = .{};

    var streamed = try runtime_gateway_step.streamModelCompletion(
        request.stream_provider,
        alloc,
        .{
            .credential = request.credential,
            .session_id = request.session_id,
            .model = request.model,
            .retry_count = request.retry_count,
            .messages = &messages,
            .tool_choice = .none,
            .provider_options = .{},
            .max_output_tokens = 64,
            .budget = .{ .cancel_flag = request.cancel_flag },
            .trace_ctx = request.trace_ctx,
            .content_capture_limit = max_response_bytes,
            .delivery = &delivery,
            .attempt_evidence = &attempt_evidence,
            .events = .{ .context = &capture, .emit_fn = StreamCapture.onEvent },
            .cancel_flag = request.cancel_flag,
        },
        null,
        alloc,
    );
    defer streamed.deinit(alloc);

    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (std.meta.activeTag(streamed) == .failed) return null;
    const completion = streamed.completed.completion;
    const raw = if (capture.len > 0)
        capture.buffer[0..capture.len]
    else
        completion.content orelse return null;
    return try parseTitle(alloc, raw);
}

fn buildPrompt(alloc: Allocator, user_prompt: []const u8) ![]u8 {
    const prefix = instructions ++ "\n\nUser request:\n";
    const budget = max_prompt_bytes -| prefix.len;
    const trimmed = std.mem.trim(u8, user_prompt, " \t\r\n");
    var end = @min(trimmed.len, budget);
    while (end > 0 and !std.unicode.utf8ValidateSlice(trimmed[0..end])) end -= 1;
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, trimmed[0..end] });
}

pub fn parseTitle(alloc: Allocator, raw: []const u8) !?[]u8 {
    if (!std.unicode.utf8ValidateSlice(raw)) return null;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\"'`");
        if (trimmed.len == 0) continue;
        var normalized: std.ArrayList(u8) = .empty;
        errdefer normalized.deinit(alloc);
        var words = std.mem.tokenizeAny(u8, trimmed, " \t\r");
        while (words.next()) |word| {
            if (normalized.items.len > 0) try normalized.append(alloc, ' ');
            try normalized.appendSlice(alloc, word);
        }
        while (normalized.items.len > 0 and switch (normalized.items[normalized.items.len - 1]) {
            '.', '?', '!', '"', '\'', '`' => true,
            else => false,
        }) _ = normalized.pop();
        if (normalized.items.len == 0) {
            normalized.deinit(alloc);
            continue;
        }
        for (normalized.items) |byte| if (byte < 0x20 or byte == 0x7f) {
            normalized.deinit(alloc);
            return null;
        };
        const bounded = utf8PrefixByChars(normalized.items, max_title_chars);
        const owned = try alloc.dupe(u8, bounded);
        normalized.deinit(alloc);
        return owned;
    }
    return null;
}

fn utf8PrefixByChars(text: []const u8, max_chars: usize) []const u8 {
    var view = std.unicode.Utf8View.initUnchecked(text);
    var it = view.iterator();
    var count: usize = 0;
    var end: usize = 0;
    while (count < max_chars) : (count += 1) {
        const before = it.i;
        _ = it.nextCodepoint() orelse break;
        end = it.i;
        std.debug.assert(end > before);
    }
    return text[0..end];
}

const StreamCapture = struct {
    buffer: [max_response_bytes]u8 = undefined,
    len: usize = 0,

    fn onEvent(raw: *anyopaque, event: agent_stream_provider.Event) void {
        const self: *StreamCapture = @ptrCast(@alignCast(raw));
        const chunk = switch (event) {
            .content_delta => |value| value,
            else => return,
        };
        const length = @min(chunk.len, self.buffer.len - self.len);
        @memcpy(self.buffer[self.len..][0..length], chunk[0..length]);
        self.len += length;
    }
};

test "parseTitle normalizes and bounds a generated title" {
    const alloc = std.testing.allocator;
    const title = (try parseTitle(alloc, "  `Fix   session title generation!`  \nignored")) orelse
        return error.TestExpectedTitle;
    defer alloc.free(title);
    try std.testing.expectEqualStrings("Fix session title generation", title);

    const long = ("界" ** 60) ++ "\n";
    const bounded = (try parseTitle(alloc, long)) orelse return error.TestExpectedTitle;
    defer alloc.free(bounded);
    try std.testing.expectEqual(@as(usize, max_title_chars * 3), bounded.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(bounded));
}

test "parseTitle rejects empty and control-bearing responses" {
    try std.testing.expect((try parseTitle(std.testing.allocator, " \n\t")) == null);
    try std.testing.expect((try parseTitle(std.testing.allocator, "bad\x07title")) == null);
}
