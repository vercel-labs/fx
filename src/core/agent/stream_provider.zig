const std = @import("std");
const adapter_auth = @import("../gateway/adapter_auth.zig");
const account_usage_provider = @import("../gateway/account_usage_provider.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const image_attachments = @import("../images/image_attachments.zig");
const route_snapshot = @import("../gateway/route_snapshot.zig");
const generation_usage_provider = @import("../session/generation_usage_provider.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const types = @import("../shared/types.zig");
const gateway_schema = @import("../tooling/gateway_schema.zig");
const web_search_provider = @import("../tooling/web_search_provider.zig");

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

/// Data-only capabilities that an adapter may serialize into its provider's
/// native tool advertisement format.
pub const ProviderTool = enum {
    web_search,
};

pub const ProviderToolAdvertisement = struct {
    tool: ProviderTool,
    local_schema_position: usize,
};

/// Provider-neutral description of one model request. All slices are borrowed
/// for the duration of `ProviderAdapter.stream`.
pub const ModelRequest = struct {
    tools: []const gateway_schema.FunctionSchema,
    provider_tools: []const ProviderToolAdvertisement = &.{},
    messages: []const types.ChatMessage,
    tool_choice: types.ToolChoice,
    require_tool_call: bool = false,
    /// Identifies the one pending tool call being reviewed. Adapters may use
    /// this semantic fact to preserve provider-specific history ordering.
    required_tool_call_id: ?[]const u8 = null,
    capabilities: model_capabilities.Capabilities,
    reasoning_effort: types.ReasoningEffort = .auto,
    fast_mode: bool = false,
    max_output_tokens: ?u32 = null,
    budget: ?BuildBudget = null,
    verified_images: ?[]const image_attachments.VerifiedSnapshot = null,
    response_format: ?StructuredResponseFormat = null,
};

test "model request exposes only data-only tool and vision metadata" {
    try std.testing.expect(!@hasField(ModelRequest, "tool_registry"));
    try std.testing.expect(!@hasField(ModelRequest, "serialized_tools"));
    try std.testing.expect(!@hasField(ModelRequest, "selected_dynamic_tool_schemas"));
    try std.testing.expect(@typeInfo(ProviderTool) == .@"enum");
    try std.testing.expect(!@hasField(gateway_schema.FunctionSchema, "call"));
    try std.testing.expect(!@hasField(gateway_schema.FunctionSchema, "runtime_provider"));
}

pub const BuildRequest = ModelRequest;

pub const Request = struct {
    api_key: []const u8,
    team: ?[]const u8,
    /// Borrowed for the duration of `Provider.stream`.
    session_id: ?[]const u8 = null,
    model: []const u8,
    retry_count: usize,
    chat_url: []const u8,
    payload: []const u8,
    trace_ctx: debug_trace.TraceContext,
    content_capture_limit: ?usize,
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

pub const GenerationReference = struct {
    pub const max_bytes: usize = 512;

    id: []const u8,
    lookup_scope: ?[]const u8 = null,

    pub fn validate(self: GenerationReference) error{InvalidGenerationReference}!void {
        if (!types.validGenerationReferenceId(self.id)) return error.InvalidGenerationReference;
        if (self.lookup_scope) |scope| {
            if (!types.validGenerationLookupScope(scope)) return error.InvalidGenerationReference;
        }
    }
};

pub const ToolInputStarted = struct {
    id: []const u8,
    name: []const u8,
    label: ?[]const u8 = null,
};

pub const ProviderToolResult = struct {
    call_id: []const u8,
    result: []const u8,
};

pub const StreamFailure = struct {
    category: Category,
    retryable: bool = false,
    response_code: ?u16 = null,
    delivery_ambiguous: bool = false,
    detail: ?[]const u8 = null,
    retry_after_seconds: ?u64 = null,
    transport_cause: ?TransportCause = null,
    diagnostic: ?Diagnostic = null,

    pub const Diagnostic = struct {
        summary: []const u8,
        request_shape: ?[]const u8 = null,
    };

    pub const TransportCause = enum {
        read_failed,
        connection_reset,
        connection_timed_out,
        connection_closing,
        system_resumed,
    };

    pub const Category = enum {
        authentication,
        authorization,
        configuration,
        invalid_content,
        request_too_large,
        rate_limited,
        provider_internal,
        upstream_failure,
        unavailable,
        timeout,
        transport,
        protocol,
        ambiguous_delivery,
        other,
    };
};

/// Provider-neutral usage snapshot. All slices are borrowed for one event.
pub const StreamUsage = struct {
    tokens: types.Usage = .{},
    billing: ?BillingUsage = null,

    pub const BillingUsage = struct {
        created_at_ms: i64,
        model_id: []const u8,
        total_cost: f64,
        input_tokens: u64,
        output_tokens: u64,
        cache_read_tokens: u64,
        cache_write_tokens: u64,
        reasoning_tokens: ?u64,
        billable_web_search_calls: u64,
    };
};

pub const StreamFinish = struct {
    reason: ?types.ProviderFinishReason,
    generation_reference: ?GenerationReference = null,
    generation_metadata_invalid: bool = false,
    delivery_ambiguous: bool = false,
    provider_result_identity_failure: ?types.ProviderResultIdentityFailure = null,
    provider_failure_detail: ?[]const u8 = null,
};

/// Payload slices are borrowed only for the duration of `EventSink.emit`.
pub const StreamEvent = union(enum) {
    provider_admitted,
    text_delta: []const u8,
    reasoning_delta: []const u8,
    tool_input_started: ToolInputStarted,
    tool_input_delta: []const u8,
    fx_tool_call: types.ToolCall,
    provider_tool_started: types.ToolCall,
    provider_tool_result: ProviderToolResult,
    usage: StreamUsage,
    finish: StreamFinish,
    failure: StreamFailure,
    cancelled,

    pub fn isTerminal(self: StreamEvent) bool {
        return switch (self) {
            .finish, .failure, .cancelled => true,
            else => false,
        };
    }
};

pub const EventOrderError = error{
    DuplicateProviderAdmission,
    EventBeforeProviderAdmission,
    DuplicateTerminalEvent,
    EventAfterTerminal,
    InvalidGenerationReference,
    InvalidToolProvenance,
    ProviderToolStartContainsResult,
    DuplicateProviderToolStart,
    UnknownProviderToolResult,
    DuplicateProviderToolResult,
};

const ProviderToolTransition = struct {
    id: []u8,
    result_received: bool = false,
};

/// Request-owned validator for the ordering laws shared by every adapter.
pub const EventState = struct {
    alloc: Allocator,
    provider_admitted: bool = false,
    terminal: bool = false,
    terminal_count: usize = 0,
    provider_tools_started: usize = 0,
    provider_tool_results: usize = 0,
    provider_tools: std.ArrayList(ProviderToolTransition) = .empty,

    pub fn init(alloc: Allocator) EventState {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *EventState) void {
        for (self.provider_tools.items) |transition| self.alloc.free(transition.id);
        self.provider_tools.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn accept(self: *EventState, event: StreamEvent) (EventOrderError || Allocator.Error)!void {
        if (self.terminal) {
            return if (event.isTerminal()) error.DuplicateTerminalEvent else error.EventAfterTerminal;
        }

        switch (event) {
            .provider_admitted => {
                if (self.provider_admitted) return error.DuplicateProviderAdmission;
                self.provider_admitted = true;
                return;
            },
            else => {},
        }
        if (!self.provider_admitted) {
            switch (event) {
                .failure, .cancelled => {},
                else => return error.EventBeforeProviderAdmission,
            }
        }

        switch (event) {
            .fx_tool_call => |call| {
                if (call.provenance != .fx_local) return error.InvalidToolProvenance;
            },
            .provider_tool_started => |call| {
                if (call.provenance != .provider_executed) return error.InvalidToolProvenance;
                if (call.provider_result != null) return error.ProviderToolStartContainsResult;
                for (self.provider_tools.items) |transition| {
                    if (std.mem.eql(u8, transition.id, call.id)) return error.DuplicateProviderToolStart;
                }
                const id = try self.alloc.dupe(u8, call.id);
                errdefer self.alloc.free(id);
                try self.provider_tools.append(self.alloc, .{ .id = id });
                self.provider_tools_started += 1;
            },
            .provider_tool_result => |result| {
                for (self.provider_tools.items) |*transition| {
                    if (!std.mem.eql(u8, transition.id, result.call_id)) continue;
                    if (transition.result_received) return error.DuplicateProviderToolResult;
                    transition.result_received = true;
                    break;
                } else {
                    return error.UnknownProviderToolResult;
                }
                self.provider_tool_results += 1;
            },
            .finish => |finish| if (finish.generation_reference) |reference| {
                reference.validate() catch return error.InvalidGenerationReference;
            },
            else => {},
        }

        if (event.isTerminal()) {
            self.terminal = true;
            self.terminal_count = 1;
        }
    }
};

pub const EventSink = struct {
    context: *anyopaque,
    state: *EventState,
    sink_error: *?anyerror,
    emit_fn: *const fn (*anyopaque, StreamEvent) anyerror!void,

    pub fn emit(self: EventSink, event: StreamEvent) anyerror!void {
        try self.state.accept(event);
        self.emit_fn(self.context, event) catch |err| {
            if (self.sink_error.* == null) self.sink_error.* = err;
            return err;
        };
    }
};

/// Borrowed routing and cancellation inputs for one adapter call. Credential
/// bytes never enter `ModelRequest` or any emitted event.
pub const AdapterRequest = struct {
    model_request: ModelRequest,
    serialized_request_limit_bytes: ?usize = null,
    route: *const route_snapshot.RouteSnapshot,
    credential: []const u8,
    tenant: ?[]const u8,
    session_id: ?[]const u8 = null,
    model_id: []const u8,
    retry_count: usize,
    trace_ctx: debug_trace.TraceContext,
    content_capture_limit: ?usize,
    cooperative_pulse: ?CooperativePulse = null,
    delivery: *DeliveryCertainty,
    attempt_evidence: *AttemptEvidence,
    cancel_flag: *std.atomic.Value(bool),
    provider_attempt_owner: ProviderAttemptOwner = .transport,
};

pub const AdapterStreamFn = *const fn (
    adapter: *const ProviderAdapter,
    alloc: Allocator,
    request: AdapterRequest,
    events: EventSink,
) anyerror!void;

pub const ProviderAdapter = struct {
    kind: []const u8,
    auth: ?adapter_auth.Provider = null,
    /// When set, context must remain valid until every in-flight stream returns.
    context: ?*anyopaque = null,
    /// Bounded G1 bridge for existing injected Vercel stream providers. G11
    /// removes this field after the old seam has no callers.
    legacy_provider: ?Provider = null,
    account_usage: ?account_usage_provider.Provider = null,
    generation_usage: ?generation_usage_provider.Provider = null,
    model_catalog: ?model_catalog.Provider = null,
    model_descriptors: model_catalog.ModelDescriptorProvider = model_catalog.configured_model_descriptor_provider,
    provider_tools: []const ProviderTool = &.{},
    web_search: ?web_search_provider.Provider = null,
    stream_fn: AdapterStreamFn,

    pub fn acceptsRoute(self: ProviderAdapter, route: *const route_snapshot.RouteSnapshot) bool {
        return std.mem.eql(u8, self.kind, route.adapter_kind);
    }

    pub fn stream(
        self: ProviderAdapter,
        alloc: Allocator,
        request: AdapterRequest,
        events: EventSink,
    ) anyerror!void {
        if (request.cancel_flag.load(.seq_cst)) {
            try events.emit(.cancelled);
            return error.Cancelled;
        }
        if (!self.acceptsRoute(request.route)) {
            try events.emit(.{ .failure = .{
                .category = .configuration,
                .detail = "admitted route does not match provider adapter",
            } });
            return error.RouteAdapterMismatch;
        }
        if (!request.route.containsModel(request.model_id)) {
            try events.emit(.{ .failure = .{
                .category = .configuration,
                .detail = "model is not part of the admitted route",
            } });
            return error.RouteModelMismatch;
        }

        try self.stream_fn(&self, alloc, request, events);
        if (!events.state.terminal) {
            try events.emit(.{ .failure = .{ .category = .protocol, .detail = "adapter returned without a terminal event" } });
        }
    }
};

fn unavailableAdapterStream(
    _: *const ProviderAdapter,
    _: Allocator,
    _: AdapterRequest,
    events: EventSink,
) anyerror!void {
    try events.emit(.{ .failure = .{ .category = .configuration, .detail = "provider adapter unavailable" } });
}

pub const unavailable_adapter = ProviderAdapter{
    .kind = "unavailable",
    .stream_fn = unavailableAdapterStream,
};

test "stream event state enforces tool usage and terminal ordering" {
    var state = EventState.init(std.testing.allocator);
    defer state.deinit();
    try state.accept(.provider_admitted);
    const local_call = types.ToolCall{
        .id = "local_1",
        .name = "read_file",
        .arguments_json = "{}",
    };
    const provider_call = types.ToolCall{
        .id = "provider_1",
        .name = "perplexity_search",
        .arguments_json = "{}",
        .provenance = .provider_executed,
    };

    try state.accept(.{ .tool_input_started = .{ .id = "local_1", .name = "read_file" } });
    try state.accept(.{ .fx_tool_call = local_call });
    try state.accept(.{ .provider_tool_started = provider_call });
    try state.accept(.{ .provider_tool_result = .{
        .call_id = provider_call.id,
        .result = "{\"results\":[]}",
    } });
    try state.accept(.{ .usage = .{ .tokens = .{ .input_tokens = 12, .output_tokens = 7 } } });
    try state.accept(.{ .finish = .{
        .reason = .stop,
        .generation_reference = .{ .id = "gen_safe_1" },
    } });

    try std.testing.expect(state.terminal);
    try std.testing.expectEqual(@as(usize, 1), state.terminal_count);
    try std.testing.expectEqual(@as(usize, 1), state.provider_tools_started);
    try std.testing.expectEqual(@as(usize, 1), state.provider_tool_results);
    try std.testing.expectError(error.EventAfterTerminal, state.accept(.{ .text_delta = "late" }));
    try std.testing.expectError(error.DuplicateTerminalEvent, state.accept(.cancelled));
}

test "stream event state makes cancellation absorbing" {
    var state = EventState.init(std.testing.allocator);
    defer state.deinit();
    try state.accept(.provider_admitted);
    try state.accept(.{ .reasoning_delta = "thinking" });
    try state.accept(.cancelled);

    try std.testing.expectEqual(@as(usize, 1), state.terminal_count);
    try std.testing.expectError(error.DuplicateTerminalEvent, state.accept(.{ .finish = .{ .reason = .stop } }));
    try std.testing.expectError(error.EventAfterTerminal, state.accept(.{ .usage = .{} }));
}

test "provider admission is ordered and preflight failure remains effect free" {
    var state = EventState.init(std.testing.allocator);
    defer state.deinit();

    try std.testing.expectError(error.EventBeforeProviderAdmission, state.accept(.{ .text_delta = "early" }));
    try state.accept(.provider_admitted);
    try std.testing.expectError(error.DuplicateProviderAdmission, state.accept(.provider_admitted));
    try state.accept(.{ .finish = .{ .reason = .stop } });
    try std.testing.expectError(error.EventAfterTerminal, state.accept(.provider_admitted));

    var failed = EventState.init(std.testing.allocator);
    defer failed.deinit();
    try failed.accept(.{ .failure = .{ .category = .request_too_large } });
    try std.testing.expect(!failed.provider_admitted);
    try std.testing.expect(failed.terminal);
}

test "every normalized failure category is terminal and absorbing" {
    inline for (std.meta.tags(StreamFailure.Category)) |category| {
        var state = EventState.init(std.testing.allocator);
        defer state.deinit();
        try state.accept(.{ .failure = .{ .category = category } });
        try std.testing.expectEqual(@as(usize, 1), state.terminal_count);
        try std.testing.expectError(error.DuplicateTerminalEvent, state.accept(.cancelled));
        try std.testing.expectError(error.EventAfterTerminal, state.accept(.{ .text_delta = "late" }));
    }
}

test "stream event state rejects unsafe references and provider tool identities" {
    var state = EventState.init(std.testing.allocator);
    defer state.deinit();
    try state.accept(.provider_admitted);
    try std.testing.expectError(
        error.InvalidGenerationReference,
        state.accept(.{ .finish = .{
            .reason = .stop,
            .generation_reference = .{ .id = "bad\nreference" },
        } }),
    );
    try std.testing.expect(!state.terminal);
    try std.testing.expectError(
        error.InvalidToolProvenance,
        state.accept(.{ .fx_tool_call = .{
            .id = "remote_1",
            .name = "remote",
            .arguments_json = "{}",
            .provenance = .provider_executed,
        } }),
    );
    const provider_call = types.ToolCall{
        .id = "remote_1",
        .name = "remote",
        .arguments_json = "{}",
        .provenance = .provider_executed,
    };
    var started_with_result = provider_call;
    started_with_result.provider_result = "{}";
    try std.testing.expectError(error.ProviderToolStartContainsResult, state.accept(.{ .provider_tool_started = started_with_result }));
    try state.accept(.{ .provider_tool_started = provider_call });
    try std.testing.expectError(error.DuplicateProviderToolStart, state.accept(.{ .provider_tool_started = provider_call }));
    try std.testing.expectError(
        error.UnknownProviderToolResult,
        state.accept(.{ .provider_tool_result = .{ .call_id = "unknown", .result = "{}" } }),
    );
    const result_event = StreamEvent{ .provider_tool_result = .{ .call_id = provider_call.id, .result = "{}" } };
    try state.accept(result_event);
    try std.testing.expectError(error.DuplicateProviderToolResult, state.accept(result_event));
}

test "provider adapter rejects wrong routes before traffic and handles cancellation and missing terminal" {
    const Fake = struct {
        calls: usize = 0,

        fn stream(
            adapter: *const ProviderAdapter,
            _: Allocator,
            _: AdapterRequest,
            _: EventSink,
        ) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(adapter.context.?));
            self.calls += 1;
        }
    };
    const Capture = struct {
        cancelled: bool = false,
        failures: usize = 0,
        failure_detail: ?[]const u8 = null,

        fn emit(raw: *anyopaque, event: StreamEvent) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (event) {
                .cancelled => self.cancelled = true,
                .failure => |failure| {
                    self.failures += 1;
                    self.failure_detail = failure.detail;
                },
                else => {},
            }
        }
    };

    var fake: Fake = .{};
    var capture: Capture = .{};
    var state = EventState.init(std.testing.allocator);
    defer state.deinit();
    var sink_error: ?anyerror = null;
    var cancelled = std.atomic.Value(bool).init(true);
    var delivery = DeliveryCertainty.init();
    var attempt_evidence: AttemptEvidence = .{};
    var route = route_snapshot.RouteSnapshot{
        .connection_id = @constCast("fake"),
        .adapter_kind = @constCast("fake"),
        .endpoint = @constCast("https://example.invalid"),
        .protocol = @constCast("fake"),
        .credential_ref = @constCast("fake_ref"),
        .primary_model_id = @constCast("test/model"),
        .permission_review_model_id = null,
        .vision_model_id = null,
        .subagent_model_id = @constCast("test/model"),
        .capabilities = .{},
        .capability_source = .configured,
        .selected_fast_mode = false,
        .fast_model_suffix = null,
    };
    const adapter = ProviderAdapter{ .kind = "fake", .context = &fake, .stream_fn = Fake.stream };
    const request = AdapterRequest{
        .model_request = .{
            .tools = &.{},
            .messages = &.{},
            .tool_choice = .none,
            .capabilities = .{},
        },
        .route = &route,
        .credential = "must-not-be-emitted",
        .tenant = null,
        .model_id = "test/model",
        .retry_count = 0,
        .trace_ctx = .{},
        .content_capture_limit = null,
        .delivery = &delivery,
        .attempt_evidence = &attempt_evidence,
        .cancel_flag = &cancelled,
    };
    try std.testing.expectError(error.Cancelled, adapter.stream(std.testing.allocator, request, .{
        .context = &capture,
        .state = &state,
        .sink_error = &sink_error,
        .emit_fn = Capture.emit,
    }));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expect(capture.cancelled);
    try std.testing.expectEqual(@as(usize, 1), state.terminal_count);

    cancelled.store(false, .seq_cst);
    capture = .{};
    state.deinit();
    state = EventState.init(std.testing.allocator);
    sink_error = null;
    const wrong_adapter = ProviderAdapter{ .kind = "other", .context = &fake, .stream_fn = Fake.stream };
    try std.testing.expectError(error.RouteAdapterMismatch, wrong_adapter.stream(std.testing.allocator, request, .{
        .context = &capture,
        .state = &state,
        .sink_error = &sink_error,
        .emit_fn = Capture.emit,
    }));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(@as(usize, 1), capture.failures);
    try std.testing.expectEqualStrings("admitted route does not match provider adapter", capture.failure_detail.?);
    try std.testing.expectEqual(@as(usize, 1), state.terminal_count);

    capture = .{};
    state.deinit();
    state = EventState.init(std.testing.allocator);
    sink_error = null;
    var wrong_model = request;
    wrong_model.model_id = "outside/route";
    try std.testing.expectError(error.RouteModelMismatch, adapter.stream(std.testing.allocator, wrong_model, .{
        .context = &capture,
        .state = &state,
        .sink_error = &sink_error,
        .emit_fn = Capture.emit,
    }));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(@as(usize, 1), capture.failures);
    try std.testing.expectEqualStrings("model is not part of the admitted route", capture.failure_detail.?);
    try std.testing.expectEqual(@as(usize, 1), state.terminal_count);
    try std.testing.expect(std.mem.find(u8, capture.failure_detail.?, request.credential) == null);

    capture = .{};
    state.deinit();
    state = EventState.init(std.testing.allocator);
    sink_error = null;
    try adapter.stream(std.testing.allocator, request, .{
        .context = &capture,
        .state = &state,
        .sink_error = &sink_error,
        .emit_fn = Capture.emit,
    });
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(@as(usize, 1), capture.failures);
    try std.testing.expectEqual(@as(usize, 1), state.terminal_count);
    try std.testing.expect(std.mem.find(u8, capture.failure_detail.?, request.credential) == null);
}

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
