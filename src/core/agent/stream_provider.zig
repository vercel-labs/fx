const std = @import("std");
const model_capabilities = @import("../config/model_capabilities.zig");
const image_attachments = @import("../images/image_attachments.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const types = @import("../shared/types.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

pub const StreamCallback = *const fn (ctx: *anyopaque, chunk: []const u8) void;
pub const ToolStartCallback = *const fn (
    ctx: *anyopaque,
    tool_id: []const u8,
    tool_name: []const u8,
    label_value: ?[]const u8,
) void;

/// Monotonic evidence for whether a request could have reached its provider.
/// Core uses it to distinguish safe retries from potentially billed delivery.
pub const DeliveryCertainty = struct {
    state: std.atomic.Value(State) = .init(.definitely_unsent),

    pub const State = enum(u8) {
        definitely_unsent,
        possibly_sent,
    };

    pub fn init() DeliveryCertainty {
        return .{};
    }

    pub fn markPossiblySent(self: *DeliveryCertainty) void {
        self.state.store(.possibly_sent, .seq_cst);
    }

    pub fn load(self: *const DeliveryCertainty) State {
        return self.state.load(.seq_cst);
    }
};

/// Selects the layer that owns retries for a provider request.
/// Agent-owned model attempts must not be retried again by the transport.
pub const ProviderAttemptOwner = enum {
    transport,
    agent,
};

pub const NetworkFailureCause = enum {
    transport_interrupted,
    system_resumed,
};

/// Stable native transport evidence consumed by model recovery policy.
/// Providers that cannot distinguish failure stages leave this unset.
pub const NetworkFailureEvidence = struct {
    cause: NetworkFailureCause,
    delivery: DeliveryCertainty.State,
};

pub const AttemptEvidence = struct {
    provider_admitted: bool = false,
    network_failure: ?NetworkFailureEvidence = null,
};

/// Gives a cooperative single-threaded host a chance to publish UI and runtime
/// state while provider transport remains pending.
pub const CooperativePulse = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque) anyerror!void,

    pub fn pulse(self: CooperativePulse) anyerror!void {
        try self.run(self.ctx);
    }
};

pub const VisionMode = enum {
    unavailable,
    optional,
    required,
};

pub const BuildBudget = struct {
    deadline: ?std.Io.Clock.Timestamp = null,
    cancel_flag: ?*std.atomic.Value(bool) = null,
};

pub const StructuredResponseFormat = struct {
    name: []const u8,
    description: []const u8,
    schema_json: []const u8,
};

pub const BuildRequest = struct {
    model: []const u8,
    tool_registry: tool_dispatch.Registry = .{},
    serialized_tools: []const u8,
    messages: []const types.ChatMessage,
    tool_choice: types.ToolChoice,
    selected_dynamic_tool_schemas: []const []const u8 = &.{},
    vision_mode: VisionMode = .unavailable,
    provider_options: model_capabilities.ResolvedProviderOptions,
    max_output_tokens: ?u32 = null,
    budget: ?BuildBudget = null,
    verified_images: ?[]const image_attachments.VerifiedSnapshot = null,
    response_format: ?StructuredResponseFormat = null,
};

pub const Request = struct {
    api_key: []const u8,
    credential_source: ?types.CredentialSource = null,
    /// Borrowed provider account identity captured with the admitted credential.
    account_id: ?[]const u8 = null,
    team: ?[]const u8,
    /// Borrowed for the duration of `Provider.stream`.
    session_id: ?[]const u8 = null,
    model: []const u8,
    retry_count: usize,
    chat_url: []const u8,
    payload: []const u8,
    trace_ctx: debug_trace.TraceContext,
    content_capture_limit: ?usize,
    /// Optional absolute provider deadline. Transports that support bounded
    /// execution must stop in-flight I/O before returning `error.Timeout`.
    deadline: ?std.Io.Clock.Timestamp = null,
    cooperative_pulse: ?CooperativePulse = null,
    delivery: *DeliveryCertainty,
    attempt_evidence: *AttemptEvidence,
    callback_ctx: *anyopaque,
    on_content_chunk: StreamCallback,
    on_tool_start: ?ToolStartCallback,
    on_reasoning_chunk: ?StreamCallback,
    on_tool_input_chunk: ?StreamCallback = null,
    cancel_flag: *std.atomic.Value(bool),
    provider_attempt_owner: ProviderAttemptOwner = .transport,
};

pub const ResultOwnership = enum {
    borrowed,
    owned,
};

pub const Result = struct {
    status: std.http.Status,
    completion: types.GatewayCompletion = .{},
    err_body: ?[]u8 = null,
    /// Borrowed base URL used to reconcile generation usage for this result.
    generation_origin: []const u8 = "",
    reconcile_generation_usage: bool = false,
    failure_schema: ?[]u8 = null,
    failure_request_shape: ?[]u8 = null,
    retry_after_seconds: ?u64 = null,
    ownership: ResultOwnership = .borrowed,

    /// Providers mark allocated response fields as `owned`; test and embedded
    /// providers may return stable borrowed fields instead.
    pub fn deinit(self: *Result, alloc: Allocator) void {
        if (self.ownership == .owned) {
            if (self.err_body) |body| alloc.free(body);
            if (self.completion.content) |content| alloc.free(@constCast(content));
            if (self.completion.generation_id) |id| alloc.free(@constCast(id));
            if (self.completion.billing) |billing| alloc.free(@constCast(billing.model));
            types.freeToolCallSlice(alloc, @constCast(self.completion.tool_calls));
            if (self.completion.provider_failure_detail) |detail| alloc.free(@constCast(detail));
            if (self.completion.provider_state_json) |state| alloc.free(@constCast(state));
            if (self.failure_schema) |schema| alloc.free(schema);
            if (self.failure_request_shape) |shape| alloc.free(shape);
        }
        const status = self.status;
        self.* = .{ .status = status };
    }
};

pub const StreamFn = *const fn (
    context: ?*anyopaque,
    alloc: Allocator,
    request: Request,
) anyerror!Result;

pub const BuildFn = *const fn (
    context: ?*anyopaque,
    alloc: Allocator,
    request: BuildRequest,
) anyerror![]u8;

pub const Provider = struct {
    /// When set, context must remain valid until every in-flight `stream` returns.
    context: ?*anyopaque = null,
    build_fn: BuildFn = unavailableBuild,
    stream_fn: StreamFn,

    /// The returned request bytes are owned by `alloc`.
    pub fn build(self: Provider, alloc: Allocator, request: BuildRequest) ![]u8 {
        return self.build_fn(self.context, alloc, request);
    }

    pub fn stream(self: Provider, alloc: Allocator, request: Request) !Result {
        return self.stream_fn(self.context, alloc, request);
    }
};

fn unavailableBuild(_: ?*anyopaque, _: Allocator, _: BuildRequest) anyerror![]u8 {
    return error.AgentStreamProviderUnavailable;
}

fn unavailableStream(_: ?*anyopaque, _: Allocator, _: Request) anyerror!Result {
    return error.AgentStreamProviderUnavailable;
}

pub const unavailable_provider = Provider{
    .stream_fn = unavailableStream,
};

test "stream provider dispatches request and preserves ordered callbacks" {
    const Fake = struct {
        calls: usize = 0,
        attempt_owner: ?ProviderAttemptOwner = null,

        fn stream(raw: ?*anyopaque, _: Allocator, request: Request) anyerror!Result {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            self.attempt_owner = request.provider_attempt_owner;
            request.on_content_chunk(request.callback_ctx, "first");
            request.on_reasoning_chunk.?(request.callback_ctx, "second");
            return .{
                .status = .ok,
                .completion = .{ .content = "done" },
                .retry_after_seconds = 17,
            };
        }
    };
    const Capture = struct {
        chunks: std.ArrayList(u8) = .empty,
        failed: bool = false,

        fn append(raw: *anyopaque, chunk: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.chunks.appendSlice(std.testing.allocator, chunk) catch {
                self.failed = true;
            };
        }
    };

    var fake: Fake = .{};
    var capture: Capture = .{};
    defer capture.chunks.deinit(std.testing.allocator);
    var delivery = DeliveryCertainty.init();
    var attempt_evidence: AttemptEvidence = .{};
    var cancelled = std.atomic.Value(bool).init(false);
    var result = try (Provider{
        .context = &fake,
        .stream_fn = Fake.stream,
    }).stream(std.testing.allocator, .{
        .api_key = "key",
        .team = null,
        .model = "model",
        .retry_count = 1,
        .chat_url = "https://example.test/chat",
        .payload = "{}",
        .trace_ctx = .{},
        .content_capture_limit = null,
        .delivery = &delivery,
        .attempt_evidence = &attempt_evidence,
        .callback_ctx = &capture,
        .on_content_chunk = Capture.append,
        .on_tool_start = null,
        .on_reasoning_chunk = Capture.append,
        .cancel_flag = &cancelled,
        .provider_attempt_owner = .agent,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(ProviderAttemptOwner.agent, fake.attempt_owner.?);
    try std.testing.expect(!capture.failed);
    try std.testing.expectEqualStrings("firstsecond", capture.chunks.items);
    try std.testing.expectEqualStrings("done", result.completion.content.?);
    try std.testing.expectEqual(@as(?u64, 17), result.retry_after_seconds);
}
