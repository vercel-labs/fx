const std = @import("std");
const model_capabilities = @import("../config/model_capabilities.zig");
const image_attachments = @import("../images/image_attachments.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const types = @import("../shared/types.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const model_tool_schema = @import("../tooling/model_tool_schema.zig");
const model_provider = @import("../config/model_provider.zig");
const credential_authority = @import("../auth/credential_authority.zig");

const Allocator = std.mem.Allocator;

/// Transport parser callback shapes. Provider boundaries expose `EventSink`;
/// concrete reducers may use these adapters internally.
pub const StreamCallback = *const fn (ctx: *anyopaque, chunk: []const u8) void;
pub const ToolStartCallback = *const fn (
    ctx: *anyopaque,
    tool_id: []const u8,
    tool_name: []const u8,
    label_value: ?[]const u8,
) void;

pub const Event = union(enum) {
    content_delta: []const u8,
    reasoning_delta: []const u8,
    tool_started: struct {
        id: []const u8,
        name: []const u8,
        label: ?[]const u8 = null,
    },
    tool_input_delta: []const u8,
};

pub const EventSink = struct {
    context: *anyopaque,
    emit_fn: *const fn (context: *anyopaque, event: Event) void,

    pub fn emit(self: EventSink, event: Event) void {
        self.emit_fn(self.context, event);
    }
};

pub const Admission = struct {
    context: ?*anyopaque = null,
    admit_fn: ?*const fn (context: *anyopaque) anyerror!void = null,

    /// Providers call this exactly once after request serialization and
    /// validation succeed, immediately before delivery can become possible.
    pub fn admit(self: Admission) !void {
        const admit_fn = self.admit_fn orelse return error.ProviderAdmissionMissing;
        try admit_fn(self.context orelse return error.ProviderAdmissionMissing);
    }
};

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
    schema: std.json.Value,
};

pub const DynamicFunctionTool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: std.json.Value,
    mcp_binding: ?types.McpToolBinding = null,
};

pub const ToolSelection = struct {
    registry: tool_dispatch.Registry = .{},
    advertised_names: []const []const u8 = &.{},
    advertised_functions: []const model_tool_schema.FunctionSchema = &.{},
    additional_functions: []const model_tool_schema.FunctionSchema = &.{},
    selected_dynamic: []const DynamicFunctionTool = &.{},

    pub fn advertisedFunction(self: ToolSelection, name: []const u8) ?model_tool_schema.FunctionSchema {
        for (self.advertised_functions) |function| {
            if (std.mem.eql(u8, function.name, name)) return function;
        }
        return null;
    }
};

pub const CredentialLease = types.CredentialLease;

test "host-managed credential lease exposes no secret or account metadata" {
    const lease: CredentialLease = .host_managed;
    try std.testing.expect(lease.secret() == null);
    try std.testing.expect(lease.accountId() == null);
    try std.testing.expect(lease.tenant() == null);
    try std.testing.expectEqual(types.CredentialSource.host_managed, lease.credentialSource().?);
}

/// Pure provider input used by request serializers and permission reviewers.
/// Every slice and JSON value is borrowed for the call.
pub const RequestData = struct {
    model: []const u8,
    instructions: []const types.ChatMessage = &.{},
    messages: []const types.ChatMessage,
    tools: ToolSelection = .{},
    tool_choice: types.ToolChoice,
    vision_mode: VisionMode = .unavailable,
    provider_options: model_capabilities.ResolvedProviderOptions,
    max_output_tokens: ?u32 = null,
    budget: ?BuildBudget = null,
    verified_images: ?[]const image_attachments.VerifiedSnapshot = null,
    response_format: ?StructuredResponseFormat = null,

    pub fn validatePrompt(self: RequestData) error{InvalidProviderPrompt}!void {
        try validate_prompt_lanes(self.instructions, self.messages);
    }
};

pub fn validate_prompt_lanes(
    instructions: []const types.ChatMessage,
    messages: []const types.ChatMessage,
) error{InvalidProviderPrompt}!void {
    for (instructions) |instruction| {
        if (instruction.role != .system or
            instruction.content == null or
            instruction.images.len != 0 or
            instruction.tool_call_id != null or
            instruction.tool_name != null or
            instruction.tool_calls.len != 0 or
            instruction.provider_replay != null or
            instruction.tool_result_status != null or
            instruction.tool_result_memory != null or
            instruction.permission_feedback)
        {
            return error.InvalidProviderPrompt;
        }
    }
    for (messages) |message| {
        if (message.role == .system) return error.InvalidProviderPrompt;
    }
}

/// Borrowed typed request. Providers own validation, wire serialization,
/// endpoint selection, headers, HTTP, and stream reduction.
pub const ModelRequest = struct {
    credential: types.CredentialLease,
    session_id: ?[]const u8 = null,
    model: []const u8,
    retry_count: usize,
    instructions: []const types.ChatMessage = &.{},
    messages: []const types.ChatMessage,
    tools: ToolSelection = .{},
    tool_choice: types.ToolChoice,
    vision_mode: VisionMode = .unavailable,
    provider_options: model_capabilities.ResolvedProviderOptions,
    max_output_tokens: ?u32 = null,
    budget: ?BuildBudget = null,
    verified_images: ?[]const image_attachments.VerifiedSnapshot = null,
    response_format: ?StructuredResponseFormat = null,
    /// Exact provider body already built for capacity measurement. Borrowed
    /// for this call and valid until `stream` returns.
    prepared_request_body: ?[]const u8 = null,
    trace_ctx: debug_trace.TraceContext,
    content_capture_limit: ?usize,
    /// Optional absolute provider deadline. Transports that support bounded
    /// execution must stop in-flight I/O before returning `error.Timeout`.
    deadline: ?std.Io.Clock.Timestamp = null,
    cooperative_pulse: ?CooperativePulse = null,
    delivery: *DeliveryCertainty,
    attempt_evidence: *AttemptEvidence,
    events: EventSink,
    admission: Admission = .{},
    cancel_flag: *std.atomic.Value(bool),
    provider_attempt_owner: ProviderAttemptOwner = .transport,

    pub fn data(self: ModelRequest) RequestData {
        return .{
            .model = self.model,
            .instructions = self.instructions,
            .messages = self.messages,
            .tools = self.tools,
            .tool_choice = self.tool_choice,
            .vision_mode = self.vision_mode,
            .provider_options = self.provider_options,
            .max_output_tokens = self.max_output_tokens,
            .budget = self.budget,
            .verified_images = self.verified_images,
            .response_format = self.response_format,
        };
    }
};

pub const ResultOwnership = enum {
    borrowed,
    owned,
};

pub const FailureKind = enum {
    invalid_request,
    unauthorized,
    forbidden,
    request_too_large,
    rate_limited,
    server_error,
    bad_gateway,
    unavailable,
    gateway_timeout,
    provider_error,
};

pub const FailureDiagnostics = struct {
    schema: ?[]u8 = null,
    request_shape: ?[]u8 = null,
};

pub const DeferredUsageReference = struct {
    provider: model_provider.ProviderId,
    generation_id: []const u8,
    scope: []const u8,
    tenant: ?[]const u8 = null,
    account_id: ?[]const u8 = null,
    credential_source: types.CredentialSource,
    credential_identity: ?credential_authority.Identity,
};

pub const UsageUnavailable = enum {
    unbilled,
    possibly_billed,
};

pub const UsageOutcome = union(enum) {
    exact: model_provider.ProviderId,
    deferred: DeferredUsageReference,
    unavailable: UsageUnavailable,
};

pub const Completed = struct {
    completion: types.ModelCompletion = .{},
    usage: UsageOutcome = .{ .unavailable = .unbilled },
    ownership: ResultOwnership = .borrowed,
};

pub const Failure = struct {
    kind: FailureKind,
    detail: ?[]u8 = null,
    diagnostics: FailureDiagnostics = .{},
    retry_after_seconds: ?u64 = null,
    ownership: ResultOwnership = .borrowed,
};

pub const Result = union(enum) {
    completed: Completed,
    failed: Failure,

    /// Providers mark allocated response fields as `owned`; test and embedded
    /// providers may return stable borrowed fields instead.
    pub fn deinit(self: *Result, alloc: Allocator) void {
        switch (self.*) {
            .completed => |completed| if (completed.ownership == .owned) {
                if (completed.completion.content) |content| alloc.free(@constCast(content));
                if (completed.completion.generation_id) |id| alloc.free(@constCast(id));
                if (completed.completion.billing) |billing| alloc.free(@constCast(billing.model));
                types.freeToolCallSlice(alloc, @constCast(completed.completion.tool_calls));
                if (completed.completion.provider_failure_detail) |detail| alloc.free(@constCast(detail));
                if (completed.completion.provider_state_json) |state| alloc.free(@constCast(state));
            },
            .failed => |failure| if (failure.ownership == .owned) {
                if (failure.detail) |detail| alloc.free(detail);
                if (failure.diagnostics.schema) |schema| alloc.free(schema);
                if (failure.diagnostics.request_shape) |shape| alloc.free(shape);
            },
        }
        self.* = undefined;
    }
};

pub inline fn failResult(err: anytype) @TypeOf(err)!Result {
    return @errorCast(failResultDynamic(err));
}

noinline fn failResultDynamic(err: anyerror) anyerror!Result {
    return err;
}

test "result failure writer preserves exact error type and identity" {
    const failure = failResult(error.Cancelled);
    try std.testing.expect(@TypeOf(failure) == error{Cancelled}!Result);
    try std.testing.expectError(error.Cancelled, failure);
}

pub const StreamFn = *const fn (
    context: ?*anyopaque,
    alloc: Allocator,
    request: ModelRequest,
) anyerror!Result;

pub const BuildRequestFn = *const fn (
    context: ?*anyopaque,
    alloc: Allocator,
    request: RequestData,
) anyerror![]u8;

pub const Provider = struct {
    /// When set, context must remain valid until every in-flight `stream` returns.
    context: ?*anyopaque = null,
    stream_fn: StreamFn,
    /// Optional exact provider serializer used for request-capacity decisions.
    build_request_fn: ?BuildRequestFn = null,
    /// Pure provider-owned slicing when one reply becomes separate history units.
    project_replay_fn: ?*const fn (Allocator, ?types.ProviderReplay, []const types.ToolCall, bool, bool) anyerror!?types.ProviderReplay = null,

    /// Borrows unchanged payloads; projected payloads live in the caller's arena.
    pub fn projectReplay(self: Provider, arena: Allocator, replay: ?types.ProviderReplay, calls: []const types.ToolCall, text: bool, reasoning: bool) !?types.ProviderReplay {
        if (replay == null) return null;
        const project = self.project_replay_fn orelse return error.ProviderReplayProjectionUnavailable;
        return project(arena, replay, calls, text, reasoning);
    }

    pub fn stream(self: Provider, alloc: Allocator, request: ModelRequest) !Result {
        try request.data().validatePrompt();
        return self.stream_fn(self.context, alloc, request);
    }

    /// Returns an owned provider request body when this provider exposes its
    /// serializer. The caller owns the returned allocation.
    pub fn buildRequest(
        self: Provider,
        alloc: Allocator,
        request: RequestData,
    ) !?[]u8 {
        try request.validatePrompt();
        const build = self.build_request_fn orelse return null;
        return try build(self.context, alloc, request);
    }
};

fn unavailableStream(_: ?*anyopaque, _: Allocator, _: ModelRequest) anyerror!Result {
    return failResult(error.AgentStreamProviderUnavailable);
}

pub const unavailable_provider = Provider{
    .stream_fn = unavailableStream,
};

test "stream provider accepts one typed request and emits ordered neutral events" {
    const Fake = struct {
        calls: usize = 0,
        attempt_owner: ?ProviderAttemptOwner = null,
        instruction_count: usize = 0,

        fn stream(raw: ?*anyopaque, _: Allocator, request: ModelRequest) anyerror!Result {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            self.attempt_owner = request.provider_attempt_owner;
            self.instruction_count = request.instructions.len;
            try request.admission.admit();
            request.events.emit(.{ .content_delta = "first" });
            request.events.emit(.{ .reasoning_delta = "second" });
            return .{ .completed = .{
                .completion = .{ .content = "done" },
                .usage = .{ .exact = .gateway },
            } };
        }
    };
    const Capture = struct {
        chunks: std.ArrayList(u8) = .empty,
        failed: bool = false,

        fn emit(raw: *anyopaque, event: Event) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const chunk = switch (event) {
                .content_delta => |value| value,
                .reasoning_delta => |value| value,
                else => return,
            };
            self.chunks.appendSlice(std.testing.allocator, chunk) catch {
                self.failed = true;
            };
        }
    };
    const AdmissionCapture = struct {
        calls: usize = 0,

        fn admit(raw: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
        }
    };

    var fake: Fake = .{};
    var capture: Capture = .{};
    defer capture.chunks.deinit(std.testing.allocator);
    var admission_capture: AdmissionCapture = .{};
    var delivery = DeliveryCertainty.init();
    var attempt_evidence: AttemptEvidence = .{};
    var cancelled = std.atomic.Value(bool).init(false);
    const instructions = [_]types.ChatMessage{.{ .role = .system, .content = "rules" }};
    var result = try (Provider{
        .context = &fake,
        .stream_fn = Fake.stream,
    }).stream(std.testing.allocator, .{
        .credential = .{ .direct = .{ .secret_bytes = "key" } },
        .model = "model",
        .retry_count = 1,
        .instructions = &instructions,
        .messages = &.{},
        .tools = .{},
        .tool_choice = .auto,
        .vision_mode = .unavailable,
        .provider_options = .{},
        .trace_ctx = .{},
        .content_capture_limit = null,
        .delivery = &delivery,
        .attempt_evidence = &attempt_evidence,
        .events = .{ .context = &capture, .emit_fn = Capture.emit },
        .admission = .{ .context = &admission_capture, .admit_fn = AdmissionCapture.admit },
        .cancel_flag = &cancelled,
        .provider_attempt_owner = .agent,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(@as(usize, 1), admission_capture.calls);
    try std.testing.expectEqual(@as(usize, 1), fake.instruction_count);
    try std.testing.expectEqual(ProviderAttemptOwner.agent, fake.attempt_owner.?);
    try std.testing.expect(!capture.failed);
    try std.testing.expectEqualStrings("firstsecond", capture.chunks.items);
    try std.testing.expectEqualStrings("done", result.completed.completion.content.?);
    try std.testing.expect(std.meta.activeTag(result.completed.usage) == .exact);
}

test "stream provider rejects system messages in conversation before delegation" {
    const Fake = struct {
        calls: usize = 0,

        fn stream(raw: ?*anyopaque, _: Allocator, _: ModelRequest) anyerror!Result {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            return .{ .completed = .{} };
        }

        fn event(_: *anyopaque, _: Event) void {}
    };

    var fake: Fake = .{};
    var delivery = DeliveryCertainty.init();
    var attempt_evidence: AttemptEvidence = .{};
    var cancelled = std.atomic.Value(bool).init(false);
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "rules" },
        .{ .role = .user, .content = "hello" },
    };

    try std.testing.expectError(error.InvalidProviderPrompt, (Provider{
        .context = &fake,
        .stream_fn = Fake.stream,
    }).stream(std.testing.allocator, .{
        .credential = .{ .direct = .{ .secret_bytes = "key" } },
        .model = "model",
        .retry_count = 1,
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{},
        .trace_ctx = .{},
        .content_capture_limit = null,
        .delivery = &delivery,
        .attempt_evidence = &attempt_evidence,
        .events = .{ .context = &fake, .emit_fn = Fake.event },
        .cancel_flag = &cancelled,
    }));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "stream provider exposes its exact request serializer without streaming" {
    const Builder = struct {
        calls: usize = 0,

        fn build(
            raw: ?*anyopaque,
            alloc: Allocator,
            request: RequestData,
        ) anyerror![]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            return std.fmt.allocPrint(
                alloc,
                "model={s};instructions={d};messages={d};tools={d}",
                .{ request.model, request.instructions.len, request.messages.len, request.tools.advertised_names.len },
            );
        }

        fn stream(
            _: ?*anyopaque,
            _: Allocator,
            _: ModelRequest,
        ) anyerror!Result {
            return error.TestUnexpectedStream;
        }
    };

    var builder: Builder = .{};
    const provider = Provider{
        .context = &builder,
        .stream_fn = Builder.stream,
        .build_request_fn = Builder.build,
    };
    const instructions = [_]types.ChatMessage{.{ .role = .system, .content = "rules" }};
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "hello" }};
    const names = [_][]const u8{"terminal"};
    const body = (try provider.buildRequest(std.testing.allocator, .{
        .model = "test/model",
        .instructions = &instructions,
        .messages = &messages,
        .tools = .{ .advertised_names = &names },
        .tool_choice = .auto,
        .provider_options = .{},
    })).?;
    defer std.testing.allocator.free(body);

    try std.testing.expectEqual(@as(usize, 1), builder.calls);
    try std.testing.expectEqualStrings(
        "model=test/model;instructions=1;messages=1;tools=1",
        body,
    );
}

test "stream provider rejects system messages in conversation before serialization" {
    const Builder = struct {
        calls: usize = 0,

        fn build(
            raw: ?*anyopaque,
            alloc: Allocator,
            _: RequestData,
        ) anyerror![]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            return alloc.dupe(u8, "unexpected");
        }

        fn stream(_: ?*anyopaque, _: Allocator, _: ModelRequest) anyerror!Result {
            return error.TestUnexpectedStream;
        }
    };

    var builder: Builder = .{};
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "rules" },
        .{ .role = .user, .content = "hello" },
    };
    const result = (Provider{
        .context = &builder,
        .stream_fn = Builder.stream,
        .build_request_fn = Builder.build,
    }).buildRequest(std.testing.allocator, .{
        .model = "test/model",
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{},
    });
    if (result) |body| {
        if (body) |owned| std.testing.allocator.free(owned);
        return error.TestExpectedInvalidProviderPrompt;
    } else |err| {
        try std.testing.expectEqual(error.InvalidProviderPrompt, err);
    }
    try std.testing.expectEqual(@as(usize, 0), builder.calls);
}

test "stream provider rejects non-system instructions before serialization" {
    const Builder = struct {
        calls: usize = 0,

        fn build(
            raw: ?*anyopaque,
            alloc: Allocator,
            _: RequestData,
        ) anyerror![]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            return alloc.dupe(u8, "unexpected");
        }

        fn stream(_: ?*anyopaque, _: Allocator, _: ModelRequest) anyerror!Result {
            return error.TestUnexpectedStream;
        }
    };

    var builder: Builder = .{};
    const instructions = [_]types.ChatMessage{.{ .role = .user, .content = "not trusted" }};
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "hello" }};
    const result = (Provider{
        .context = &builder,
        .stream_fn = Builder.stream,
        .build_request_fn = Builder.build,
    }).buildRequest(std.testing.allocator, .{
        .model = "test/model",
        .instructions = &instructions,
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{},
    });
    if (result) |body| {
        if (body) |owned| std.testing.allocator.free(owned);
        return error.TestExpectedInvalidProviderPrompt;
    } else |err| {
        try std.testing.expectEqual(error.InvalidProviderPrompt, err);
    }
    try std.testing.expectEqual(@as(usize, 0), builder.calls);
}
