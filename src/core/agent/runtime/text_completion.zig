//! Asks a model once for text: one system message and one user message, no
//! tools, or one more user message after a conversation sent exactly as the
//! agent was about to send it. Also offers a conversation's connection to
//! fx-compactor as its model caller.

const std = @import("std");
const agent_stream_provider = @import("../stream_provider.zig");
const runtime_gateway_step = @import("gateway_step.zig");
const compactor = @import("../../compactor/compactor.zig");
const session_usage = @import("../../session/session_usage.zig");
const model_capabilities = @import("../../config/model_capabilities.zig");
const model_provider = @import("../../config/model_provider.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const text_utils = @import("../../shared/text_utils.zig");
const types = @import("../../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const Request = struct {
    pricing: ?@import("../../config/model_pricing.zig").Pricing = null,
    stream_provider: agent_stream_provider.Provider,
    cooperative_pulse: ?agent_stream_provider.CooperativePulse = null,
    credential: agent_stream_provider.CredentialLease,
    session_id: ?[]const u8 = null,
    model: []const u8,
    retry_count: usize,
    cancel_flag: *std.atomic.Value(bool),
    provider_options: model_capabilities.ResolvedProviderOptions = .{},
    max_output_tokens: ?u32 = null,
    /// Longest text kept; a longer reply counts as truncated.
    max_bytes: usize,
    usage: ?*session_usage.Usage = null,
    usage_allocator: Allocator = std.heap.c_allocator,
    trace_ctx: debug_trace.TraceContext,
    system: []const u8,
    user: []const u8,
    /// When set, `user` follows this request's messages, sent with its
    /// instructions, tools and tool choice unchanged, so the provider can
    /// reuse what it cached of them; `system` is not sent. Borrowed.
    conversation: ?agent_stream_provider.RequestData = null,
    /// Receives what the provider reported the request used.
    usage_out: ?*types.Usage = null,
};

pub const Reason = enum {
    /// The request did not complete.
    transport,
    /// The provider answered with an error.
    provider,
    /// The model called a tool instead of answering.
    tool_call,
    /// The model stopped before finishing, for example at its output limit.
    incomplete,
    /// The reply was longer than `max_bytes`, or not valid UTF-8.
    truncated,
};

pub const Outcome = union(enum) {
    /// Allocated with the caller's allocator.
    text: []u8,
    /// No usable text. `detail` names the cause in `key=value` form, safe to
    /// trace; allocated with the caller's allocator.
    failed: struct { reason: Reason, detail: []u8 },
};

pub const Error = error{ Cancelled, OutOfMemory };

/// Sends `request` and waits for the whole reply.
pub fn complete(alloc: Allocator, request: Request) Error!Outcome {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const instructions = [_]types.ChatMessage{.{ .role = .system, .content = request.system }};
    const user: types.ChatMessage = .{ .role = .user, .content = request.user };
    const alone = [_]types.ChatMessage{user};
    const conversation = request.conversation;
    const messages: []const types.ChatMessage = if (conversation) |sent| joined: {
        const all = try alloc.alloc(types.ChatMessage, sent.messages.len + 1);
        @memcpy(all[0..sent.messages.len], sent.messages);
        all[sent.messages.len] = user;
        break :joined all;
    } else &alone;
    defer if (conversation != null) alloc.free(messages);
    var capture = StreamCapture{ .alloc = alloc, .max_bytes = request.max_bytes };
    defer capture.deinit();
    var delivery = runtime_gateway_step.DeliveryCertainty.init();
    var attempt_evidence: agent_stream_provider.AttemptEvidence = .{};
    var streamed = runtime_gateway_step.streamModelCompletion(
        request.stream_provider,
        alloc,
        .{
            .credential = request.credential,
            .session_id = request.session_id,
            .model = request.model,
            .pricing = request.pricing,
            .retry_count = request.retry_count,
            .instructions = if (conversation) |sent| sent.instructions else &instructions,
            .messages = messages,
            .tools = if (conversation) |sent| sent.tools else .{},
            .tool_choice = if (conversation) |sent| sent.tool_choice else .none,
            .vision_mode = if (conversation) |sent| sent.vision_mode else .unavailable,
            .verified_images = if (conversation) |sent| sent.verified_images else null,
            .provider_options = request.provider_options,
            .max_output_tokens = request.max_output_tokens,
            .budget = .{ .cancel_flag = request.cancel_flag },
            .content_capture_limit = request.max_bytes,
            .delivery = &delivery,
            .attempt_evidence = &attempt_evidence,
            .events = .{ .context = &capture, .emit_fn = onEvent },
            .admission = .{},
            .cancel_flag = request.cancel_flag,
            .trace_ctx = request.trace_ctx,
            .cooperative_pulse = request.cooperative_pulse,
        },
        request.usage,
        request.usage_allocator,
    ) catch |err| switch (err) {
        error.Cancelled => return error.Cancelled,
        error.OutOfMemory => return error.OutOfMemory,
        else => return failed(alloc, .transport, "err={s}", .{@errorName(err)}),
    };
    defer streamed.deinit(alloc);
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const completion = switch (streamed) {
        .failed => |failure| {
            // Provider error bodies are third-party text: mask secrets and
            // neutralize control bytes before the detail reaches /trace.
            const masked = text_utils.maskSecrets(alloc, failure.detail orelse "") catch return error.OutOfMemory;
            defer alloc.free(masked);
            var detail_buf: [512]u8 = undefined;
            const safe_detail = debug_trace.preview(debug_trace.terminalPreview(&detail_buf, masked), 240);
            return failed(alloc, .provider, "kind={s} detail={s}", .{ @tagName(failure.kind), safe_detail });
        },
        .completed => |completed| completed.completion,
    };
    if (request.usage_out) |usage| usage.* = completion.usage;
    if (capture.failed) return error.OutOfMemory;
    if (!capture.saw_content) if (completion.content) |content| capture.append(content) catch return error.OutOfMemory;
    if (capture.saw_tool_call or completion.tool_calls.len > 0) return failed(alloc, .tool_call, "", .{});
    if (completion.finish_reason != .stop) {
        return failed(alloc, .incomplete, "finish_reason={s} bytes={d}", .{ if (completion.finish_reason) |reason| @tagName(reason) else "missing", capture.text.items.len });
    }
    if (capture.observed_bytes > capture.text.items.len or !std.unicode.utf8ValidateSlice(capture.text.items)) {
        return failed(alloc, .truncated, "bytes={d}", .{capture.observed_bytes});
    }
    return .{ .text = try alloc.dupe(u8, capture.text.items) };
}

fn failed(alloc: Allocator, reason: Reason, comptime fmt: []const u8, args: anytype) Error!Outcome {
    return .{ .failed = .{ .reason = reason, .detail = try std.fmt.allocPrint(alloc, fmt, args) } };
}

const StreamCapture = struct {
    alloc: Allocator,
    max_bytes: usize,
    text: std.ArrayList(u8) = .empty,
    observed_bytes: usize = 0,
    saw_content: bool = false,
    saw_tool_call: bool = false,
    failed: bool = false,

    fn deinit(self: *StreamCapture) void {
        self.text.deinit(self.alloc);
    }

    fn append(self: *StreamCapture, chunk: []const u8) !void {
        self.saw_content = self.saw_content or chunk.len > 0;
        self.observed_bytes +|= chunk.len;
        const room = self.max_bytes -| self.text.items.len;
        try self.text.appendSlice(self.alloc, chunk[0..@min(chunk.len, room)]);
    }
};

fn onEvent(raw: *anyopaque, event: agent_stream_provider.Event) void {
    const capture: *StreamCapture = @ptrCast(@alignCast(raw));
    switch (event) {
        .content_delta => |chunk| capture.append(chunk) catch {
            capture.failed = true;
        },
        .tool_started => capture.saw_tool_call = true,
        .reasoning_delta, .tool_input_delta => {},
    }
}

/// A conversation's connection to its model, offered to fx-compactor. Its own
/// options and output limit apply to its own model; another model keeps the
/// provider routing and prompt caching but gets only the reasoning asked for
/// and its own output limit. A request after the conversation keeps the
/// conversation's options as they are.
pub const CompactorCaller = struct {
    stream_provider: agent_stream_provider.Provider,
    cooperative_transport_pulse: ?agent_stream_provider.CooperativePulse = null,
    provider: model_provider.ProviderId,
    /// The conversation's model.
    model: []const u8,
    api_key: []const u8,
    credential_source: ?types.CredentialSource = null,
    account_id: ?[]const u8 = null,
    gateway_team: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    retry_count: usize,
    provider_options: model_capabilities.ResolvedProviderOptions = .{},
    max_output_tokens: ?u32 = null,
    /// What each model accepts.
    capabilities_context: *anyopaque,
    capabilities_fn: *const fn (context: *anyopaque, model: []const u8) model_capabilities.Capabilities,
    usage: ?*session_usage.Usage = null,
    usage_allocator: Allocator = std.heap.c_allocator,
    /// The request the agent was about to send. A request after the
    /// conversation repeats it unchanged before its own message. Borrowed.
    conversation: ?agent_stream_provider.RequestData = null,

    /// Borrows `self`, which must outlive the compaction.
    pub fn caller(self: *CompactorCaller) compactor.ModelCaller {
        return .{
            .context = self,
            .vtable = &.{ .capabilities = capabilities, .send = send },
            .model = self.model,
            .provider = self.provider,
            .credential_source = self.credential_source,
            .sends_after_conversation = self.conversation != null,
        };
    }

    fn capabilities(context: *anyopaque, model: []const u8) model_capabilities.Capabilities {
        const self: *CompactorCaller = @ptrCast(@alignCast(context));
        return self.capabilities_fn(self.capabilities_context, model);
    }

    fn send(context: *anyopaque, alloc: Allocator, call: compactor.Call) compactor.CallError!compactor.Reply {
        const self: *CompactorCaller = @ptrCast(@alignCast(context));
        const own = std.mem.eql(u8, call.model, self.model);
        // Only the conversation's own model reads it; the request is built
        // for that model.
        var conversation: ?agent_stream_provider.RequestData = null;
        if (call.after_conversation) {
            if (!own or self.conversation == null) return .{ .failed = .{ .reason = .provider, .detail = try alloc.dupe(u8, "kind=no_conversation") } };
            conversation = self.conversation;
        }
        // After the conversation, the agent's own options, reasoning too: the
        // provider reuses its cache only for the same settings. Another model
        // keeps the user's provider routing but none of the options chosen
        // for this one.
        var options: model_capabilities.ResolvedProviderOptions = if (conversation) |sent| sent.provider_options else if (own) self.provider_options else .{
            .prompt_caching = self.provider_options.prompt_caching,
            .provider_order = self.provider_options.provider_order,
            .provider_strict = self.provider_options.provider_strict,
        };
        if (conversation == null) options.reasoning = call.reasoning;
        var usage: types.Usage = .{};
        const outcome = try complete(alloc, .{
            .stream_provider = self.stream_provider,
            .cooperative_pulse = self.cooperative_transport_pulse,
            .credential = if (self.credential_source == .host_managed) .host_managed else .{ .direct = .{
                .secret_bytes = self.api_key,
                .source = self.credential_source,
                .account_id = self.account_id,
                .tenant_context = self.gateway_team,
            } },
            .session_id = self.session_id,
            .model = call.model,
            .pricing = self.capabilities_fn(self.capabilities_context, call.model).pricing,
            .retry_count = self.retry_count,
            .cancel_flag = call.cancel_flag,
            .provider_options = options,
            .max_output_tokens = if (own) self.max_output_tokens else model_capabilities.requestOutputTokens(self.capabilities_fn(self.capabilities_context, call.model)),
            .max_bytes = call.max_bytes,
            .usage = self.usage,
            .usage_allocator = self.usage_allocator,
            .trace_ctx = call.trace_ctx,
            .system = call.system,
            .user = call.user,
            .conversation = conversation,
            .usage_out = &usage,
        });
        compactor.traceLog(false, "compaction model call model={s} after_conversation={} input_tokens={any} cache_read_tokens={any} cache_write_tokens={any} output_tokens={any}", .{
            call.model,               call.after_conversation, usage.input_tokens, usage.cache_read_tokens,
            usage.cache_write_tokens, usage.output_tokens,
        });
        return switch (outcome) {
            .text => |text| .{ .text = text },
            .failed => |failure| .{ .failed = .{
                .reason = switch (failure.reason) {
                    .transport => .transport,
                    .provider => .provider,
                    .tool_call => .tool_call,
                    .incomplete => .incomplete,
                    .truncated => .truncated,
                },
                .detail = failure.detail,
            } },
        };
    }
};

test "a compactor request after the conversation sends it unchanged, then the request" {
    const testing = std.testing;
    const Fake = struct {
        instruction: []const u8 = "",
        instructions: usize = 0,
        messages: usize = 0,
        last_message: []const u8 = "",
        tools: usize = 0,
        tool_choice: types.ToolChoice = .required,
        reasoning: ?types.ReasoningEffort = null,

        fn stream(raw: ?*anyopaque, alloc: Allocator, request: agent_stream_provider.ModelRequest) !runtime_gateway_step.StreamResult {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try request.admission.admit();
            self.reasoning = request.provider_options.reasoning;
            self.instructions = request.instructions.len;
            self.instruction = request.instructions[0].content.?;
            self.messages = request.messages.len;
            self.last_message = request.messages[request.messages.len - 1].content.?;
            self.tools = request.tools.advertised_names.len;
            self.tool_choice = request.tool_choice;
            return .{ .completed = .{
                .completion = .{ .content = try alloc.dupe(u8, "notes"), .finish_reason = .stop },
                .ownership = .owned,
            } };
        }

        fn capabilities(_: *anyopaque, _: []const u8) model_capabilities.Capabilities {
            return .{};
        }
    };
    var fake: Fake = .{};
    const instructions = [_]types.ChatMessage{.{ .role = .system, .content = "the agent's instructions" }};
    const history = [_]types.ChatMessage{ .{ .role = .user, .content = "fix the build" }, .{ .role = .assistant, .content = "Fixed." } };
    var summary_model: CompactorCaller = .{
        .stream_provider = .{ .context = &fake, .stream_fn = Fake.stream },
        .provider = .gateway,
        .model = "m",
        .api_key = "fixture-key",
        .retry_count = 1,
        .capabilities_context = &fake,
        .capabilities_fn = Fake.capabilities,
        .conversation = .{ .model = "m", .instructions = &instructions, .messages = &history, .tools = .{ .advertised_names = &.{"shell"} }, .tool_choice = .auto, .provider_options = .{ .reasoning = types.ReasoningEffort.literal("high") } },
    };
    const caller = summary_model.caller();
    try testing.expect(caller.sends_after_conversation);
    var cancel = std.atomic.Value(bool).init(false);
    var call: compactor.Call = .{ .model = "m", .reasoning = types.ReasoningEffort.literal("none"), .system = "the compactor's instructions", .user = "write the notes", .after_conversation = true, .max_bytes = 1024, .cancel_flag = &cancel, .trace_ctx = .{} };

    const after = try caller.vtable.send(caller.context, testing.allocator, call);
    defer testing.allocator.free(after.text);
    try testing.expectEqualStrings("notes", after.text);
    try testing.expectEqualStrings("the agent's instructions", fake.instruction);
    try testing.expectEqual(@as(usize, 3), fake.messages);
    try testing.expectEqualStrings("write the notes", fake.last_message);
    try testing.expectEqual(@as(usize, 1), fake.tools);
    try testing.expectEqual(types.ToolChoice.auto, fake.tool_choice);
    // The provider reuses its cache only for the agent's own reasoning.
    try testing.expect(fake.reasoning.?.eql(types.ReasoningEffort.literal("high")));

    // Without it, one system message and one user message, no tools, at the
    // reasoning asked for.
    call.after_conversation = false;
    const alone = try caller.vtable.send(caller.context, testing.allocator, call);
    defer testing.allocator.free(alone.text);
    try testing.expectEqualStrings("the compactor's instructions", fake.instruction);
    try testing.expectEqual(@as(usize, 1), fake.messages);
    try testing.expectEqual(@as(usize, 0), fake.tools);
    try testing.expectEqual(types.ToolChoice.none, fake.tool_choice);
    try testing.expect(fake.reasoning.?.eql(types.ReasoningEffort.literal("none")));

    // Another model never reads the conversation.
    call.after_conversation = true;
    call.model = "other";
    const other = try caller.vtable.send(caller.context, testing.allocator, call);
    defer testing.allocator.free(other.failed.detail);
    try testing.expect(other.failed.reason == .provider);
}

test "a compactor request carries host-managed authority without secret bytes and the host's pulse" {
    const testing = std.testing;
    const Fake = struct {
        credential_source: ?types.CredentialSource = null,
        secret: ?[]const u8 = null,

        fn stream(raw: ?*anyopaque, alloc: Allocator, request: agent_stream_provider.ModelRequest) !runtime_gateway_step.StreamResult {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try request.admission.admit();
            if (request.cooperative_pulse) |pulse| try pulse.pulse();
            self.credential_source = request.credential.credentialSource();
            self.secret = request.credential.secret();
            return .{ .completed = .{
                .completion = .{ .content = try alloc.dupe(u8, "notes"), .finish_reason = .stop },
                .ownership = .owned,
            } };
        }

        fn capabilities(_: *anyopaque, _: []const u8) model_capabilities.Capabilities {
            return .{};
        }
    };
    const Pulse = struct {
        calls: usize = 0,

        fn run(raw: *anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
        }
    };
    var fake: Fake = .{};
    var pulse: Pulse = .{};
    var summary_model: CompactorCaller = .{
        .stream_provider = .{ .context = &fake, .stream_fn = Fake.stream },
        .cooperative_transport_pulse = .{ .ctx = &pulse, .run = Pulse.run },
        .provider = .gateway,
        .model = "m",
        .api_key = "",
        .credential_source = .host_managed,
        .retry_count = 0,
        .capabilities_context = &fake,
        .capabilities_fn = Fake.capabilities,
    };
    const caller = summary_model.caller();
    try testing.expectEqual(types.CredentialSource.host_managed, caller.credential_source.?);
    var cancel = std.atomic.Value(bool).init(false);
    var call: compactor.Call = .{ .model = "m", .reasoning = types.ReasoningEffort.literal("none"), .system = "s", .user = "u", .max_bytes = 1024, .cancel_flag = &cancel, .trace_ctx = .{} };
    // The conversation's model and the fallback model alike.
    for ([_][]const u8{ "m", "other" }, 1..) |model, calls| {
        call.model = model;
        fake.credential_source = null;
        fake.secret = "unset";
        const reply = try caller.vtable.send(caller.context, testing.allocator, call);
        defer testing.allocator.free(reply.text);
        try testing.expectEqual(types.CredentialSource.host_managed, fake.credential_source.?);
        try testing.expect(fake.secret == null);
        try testing.expectEqual(calls, pulse.calls);
    }
}
