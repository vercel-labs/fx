const std = @import("std");
const permission_auto_classifier = @import("../core/permissions/auto_classifier.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const io_mod = @import("../core/shared/io.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const session_usage = @import("../core/session/session_usage.zig");
const vercel_protocol = @import("vercel_protocol.zig");

const Allocator = std.mem.Allocator;

pub const BuildFn = *const fn (Allocator, stream_provider.RequestData) anyerror![]u8;
pub const SendFn = *const fn (
    Allocator,
    stream_provider.ModelRequest,
    []const u8,
) anyerror!stream_provider.Result;
pub const ValidateFn = *const fn (
    Allocator,
    permission_auto_classifier.ProviderInput,
) anyerror!void;

pub const Adapter = struct {
    source: types.CredentialSource,
    model: []const u8,
    require_account: bool = false,
    validate_fn: ValidateFn,
    build_fn: BuildFn,
    send_fn: SendFn,
};

const Runtime = struct {
    input: permission_auto_classifier.ProviderInput,
    adapter: Adapter,
};

pub fn review(
    alloc: Allocator,
    input: permission_auto_classifier.ProviderInput,
    request: permission_auto_classifier.ReviewRequest,
    adapter: Adapter,
) !permission_auto_classifier.ParseOutcome {
    if (reviewInputFailure(input, adapter.require_account)) |reason| {
        return .{ .invalid = reason };
    }
    if (input.credential_source != .host_managed) {
        adapter.validate_fn(alloc, input) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .invalid = .provider_failed };
        };
    }
    var runtime = Runtime{ .input = input, .adapter = adapter };
    return permission_auto_classifier.Reviewer.withTransportModel(
        .{
            .context = &runtime,
            .build_fn = buildReviewPayload,
            .send_fn = sendReview,
        },
        input.cancel_flag,
        permission_auto_classifier.Reviewer.default_timeout_ms,
        adapter.model,
    ).review(alloc, request);
}

fn reviewInputFailure(
    input: permission_auto_classifier.ProviderInput,
    require_account: bool,
) ?permission_auto_classifier.InvalidReason {
    if (input.credential_source == .host_managed) return null;
    if (input.credential.len == 0) return .provider_context_missing;
    if (require_account and input.account_id == null) return .provider_context_missing;
    return null;
}

fn buildReviewPayload(
    raw: *anyopaque,
    alloc: Allocator,
    model: []const u8,
    _: []const u8,
    messages: []const types.ChatMessage,
    target_call_id: []const u8,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: *std.atomic.Value(bool),
) ![]u8 {
    const runtime: *Runtime = @ptrCast(@alignCast(raw));
    const expanded = try vercel_protocol.expandPendingToolReviewMessages(
        alloc,
        messages,
        target_call_id,
        deadline,
        cancel_flag,
    );
    defer alloc.free(expanded);
    return runtime.adapter.build_fn(alloc, .{
        .model = model,
        .messages = expanded,
        .tools = .{ .additional_functions = &.{permission_auto_classifier.function_schema} },
        .tool_choice = .required,
        .provider_options = .{},
        .max_output_tokens = 2048,
        .budget = .{ .deadline = deadline, .cancel_flag = cancel_flag },
    });
}

pub fn buildPayloadForTest(
    alloc: Allocator,
    model: []const u8,
    messages: []const types.ChatMessage,
    target_call_id: []const u8,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: *std.atomic.Value(bool),
    build_fn: BuildFn,
) ![]u8 {
    var runtime = Runtime{
        .input = .{},
        .adapter = .{
            .source = .ai_gateway_api_key,
            .model = model,
            .build_fn = build_fn,
            .validate_fn = validateUnavailable,
            .send_fn = undefined,
        },
    };
    return buildReviewPayload(
        &runtime,
        alloc,
        model,
        "",
        messages,
        target_call_id,
        deadline,
        cancel_flag,
    );
}

fn validateUnavailable(_: Allocator, _: permission_auto_classifier.ProviderInput) !void {}

test "host-managed permission review accepts absent local credential metadata" {
    try std.testing.expect(reviewInputFailure(.{
        .credential_source = .host_managed,
    }, true) == null);
}

const OwnedResult = struct {
    result: stream_provider.Result,
};

const ReviewAdmission = struct {
    usage: ?*session_usage.Usage,
    evidence: *stream_provider.AttemptEvidence,
    observation: ?session_usage.InvocationObservation = null,

    fn admit(raw: *anyopaque) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.observation != null) return error.ProviderAdmissionRepeated;
        self.observation = try session_usage.InvocationObservation.begin(self.usage);
        self.evidence.provider_admitted = true;
    }
};

fn deinitOwnedResult(raw: *anyopaque, alloc: Allocator) void {
    const owned: *OwnedResult = @ptrCast(@alignCast(raw));
    owned.result.deinit(alloc);
    alloc.destroy(owned);
}

fn ignoreEvent(_: *anyopaque, _: stream_provider.Event) void {}

fn sendReview(
    raw: *anyopaque,
    alloc: Allocator,
    model: []const u8,
    payload: []const u8,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: *std.atomic.Value(bool),
) !permission_auto_classifier.TransportOutcome {
    const runtime: *Runtime = @ptrCast(@alignCast(raw));
    if (cancel_flag.load(.seq_cst)) return .cancelled;
    if (!std.Io.Clock.Timestamp.compare(
        std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake),
        .lt,
        deadline,
    )) return .timed_out;

    var delivery = stream_provider.DeliveryCertainty.init();
    var evidence: stream_provider.AttemptEvidence = .{};
    var admission = ReviewAdmission{
        .usage = runtime.input.usage,
        .evidence = &evidence,
    };
    var callback_context: u8 = 0;
    var result = runtime.adapter.send_fn(alloc, .{
        .credential = if (runtime.input.credential_source == .host_managed)
            .host_managed
        else
            .{ .direct = .{
                .secret_bytes = runtime.input.credential,
                .source = runtime.adapter.source,
                .account_id = runtime.input.account_id,
                .tenant_context = runtime.input.tenant,
            } },
        .model = model,
        .retry_count = 1,
        .messages = &.{},
        .tool_choice = .required,
        .provider_options = .{},
        .trace_ctx = .{},
        .content_capture_limit = 16 * 1024,
        .deadline = deadline,
        .delivery = &delivery,
        .attempt_evidence = &evidence,
        .events = .{ .context = &callback_context, .emit_fn = ignoreEvent },
        .admission = .{ .context = &admission, .admit_fn = ReviewAdmission.admit },
        .cancel_flag = cancel_flag,
        .provider_attempt_owner = .transport,
    }, payload) catch |err| {
        if (admission.observation) |observation| observation.fail(
            if (delivery.load() == .possibly_sent) .ambiguous_delivery else .unbilled,
        ) catch |usage_err| {
            debugUsageFailure("transport_failure", usage_err);
            return .permanent_failure;
        };
        if (err == error.OutOfMemory) return error.OutOfMemory;
        const outcome: permission_auto_classifier.TransportOutcome =
            if (err == error.Cancelled or cancel_flag.load(.seq_cst))
                .cancelled
            else if (err == error.Timeout)
                .timed_out
            else
                .transient_failure;
        debug_trace.logf(
            "permission",
            "event=auto_review_transport result={s} reason=transport_error error={s}",
            .{ @tagName(std.meta.activeTag(outcome)), @errorName(err) },
        );
        return outcome;
    };
    var result_owned = true;
    defer if (result_owned) result.deinit(alloc);
    const observation = admission.observation orelse {
        debugUsageFailure("completion", error.ProviderAdmissionMissing);
        return .permanent_failure;
    };
    (switch (result) {
        .failed => observation.fail(.unbilled),
        .completed => |completed| observation.complete(
            runtime.input.usage_allocator,
            completed.completion,
            completed.usage,
        ),
    }) catch |err| {
        debugUsageFailure("completion", err);
        return .permanent_failure;
    };
    if (cancel_flag.load(.seq_cst)) return .cancelled;
    if (std.meta.activeTag(result) == .failed) {
        const outcome: permission_auto_classifier.TransportOutcome = switch (result.failed.kind) {
            .rate_limited, .server_error, .bad_gateway, .unavailable, .gateway_timeout => .transient_failure,
            else => .permanent_failure,
        };
        debug_trace.logf(
            "permission",
            "event=auto_review_transport result={s} reason=provider_failure failure_kind={s}",
            .{ @tagName(std.meta.activeTag(outcome)), @tagName(result.failed.kind) },
        );
        return outcome;
    }
    if (result.completed.completion.finish_reason) |reason| switch (reason) {
        .provider_error => {
            debug_trace.logf(
                "permission",
                "event=auto_review_transport result=transient_failure reason=provider_error",
                .{},
            );
            return .transient_failure;
        },
        .content_filter => {
            debug_trace.logf(
                "permission",
                "event=auto_review_transport result=permanent_failure reason=content_filter",
                .{},
            );
            return .permanent_failure;
        },
        .stop, .length, .tool_calls, .other => {},
    };
    debug_trace.logf(
        "permission",
        "event=auto_review_transport result=completion finish_reason={s} tool_calls={d} content_bytes={d}",
        .{
            if (result.completed.completion.finish_reason) |reason| @tagName(reason) else "absent",
            result.completed.completion.tool_calls.len,
            if (result.completed.completion.content) |content| content.len else 0,
        },
    );
    const owned = try alloc.create(OwnedResult);
    owned.* = .{ .result = result };
    result_owned = false;
    return .{ .completion = .{
        .completion = owned.result.completed.completion,
        .context = owned,
        .deinit_fn = deinitOwnedResult,
    } };
}

fn debugUsageFailure(phase: []const u8, err: anyerror) void {
    debug_trace.logf(
        "permission",
        "event=auto_review_usage result=permanent_failure phase={s} reason={s}",
        .{ phase, @errorName(err) },
    );
}

test "direct review exact usage settles through the session ledger" {
    const Fake = struct {
        fn validate(_: Allocator, _: permission_auto_classifier.ProviderInput) !void {}

        fn build(_: Allocator, _: stream_provider.RequestData) ![]u8 {
            return error.TestUnexpectedBuild;
        }

        fn send(
            _: Allocator,
            request: stream_provider.ModelRequest,
            _: []const u8,
        ) !stream_provider.Result {
            try request.admission.admit();
            request.delivery.markPossiblySent();
            return .{ .completed = .{
                .completion = .{
                    .content = "clear",
                    .generation_id = "response-review-1",
                    .billing = .{
                        .created_at_ms = 1,
                        .model = "codex/gpt-review",
                        .total_cost = 0,
                        .input_tokens = 11,
                        .output_tokens = 3,
                        .cache_read_tokens = 0,
                        .cache_write_tokens = 0,
                        .reasoning_tokens = null,
                        .billable_web_search_calls = 0,
                    },
                    .finish_reason = .stop,
                },
                .usage = .{ .exact = .codex },
            } };
        }
    };

    const alloc = std.testing.allocator;
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    var runtime = Runtime{
        .input = .{ .usage = &usage, .usage_allocator = alloc },
        .adapter = .{
            .source = .chatgpt_subscription,
            .model = "gpt-review",
            .validate_fn = Fake.validate,
            .build_fn = Fake.build,
            .send_fn = Fake.send,
        },
    };
    var cancelled = std.atomic.Value(bool).init(false);
    var outcome = try sendReview(
        &runtime,
        alloc,
        "gpt-review",
        "{}",
        std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromSeconds(5),
        }),
        &cancelled,
    );
    defer if (outcome == .completion) outcome.completion.deinit(alloc);

    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 11), snapshot.input_tokens);
    try std.testing.expectEqual(@as(u64, 3), snapshot.output_tokens);
    try std.testing.expectEqual(@as(?u64, 1), snapshot.request_count);
}

test "direct review settles every post-admission outcome before projection" {
    const Fake = struct {
        fn validate(_: Allocator, _: permission_auto_classifier.ProviderInput) !void {}

        fn build(_: Allocator, _: stream_provider.RequestData) ![]u8 {
            return error.TestUnexpectedBuild;
        }

        fn exactCompletion() stream_provider.Result {
            return .{ .completed = .{
                .completion = .{
                    .generation_id = "response-review-outcome",
                    .billing = .{
                        .created_at_ms = 1,
                        .model = "codex/gpt-review",
                        .total_cost = 0,
                        .input_tokens = 11,
                        .output_tokens = 3,
                        .cache_read_tokens = 0,
                        .cache_write_tokens = 0,
                        .reasoning_tokens = null,
                        .billable_web_search_calls = 0,
                    },
                    .finish_reason = .stop,
                },
                .usage = .{ .exact = .codex },
            } };
        }

        fn send(
            _: Allocator,
            request: stream_provider.ModelRequest,
            payload: []const u8,
        ) !stream_provider.Result {
            try request.admission.admit();
            if (std.mem.eql(u8, payload, "cancelled")) {
                request.delivery.markPossiblySent();
                return error.Cancelled;
            }
            if (std.mem.eql(u8, payload, "timed_out")) {
                request.delivery.markPossiblySent();
                return error.Timeout;
            }
            if (std.mem.eql(u8, payload, "provider_failure")) {
                return .{ .failed = .{ .kind = .unauthorized } };
            }
            if (std.mem.eql(u8, payload, "malformed")) {
                return .{ .completed = .{
                    .completion = .{ .finish_reason = .stop },
                    .usage = .{ .unavailable = .possibly_billed },
                } };
            }
            if (std.mem.eql(u8, payload, "cancel_after_completion")) {
                request.cancel_flag.store(true, .seq_cst);
                return exactCompletion();
            }
            if (std.mem.eql(u8, payload, "provider_error")) {
                var result = exactCompletion();
                result.completed.completion.finish_reason = .provider_error;
                return result;
            }
            return error.TestUnexpectedPayload;
        }
    };

    const cases = [_]struct {
        payload: []const u8,
        outcome: std.meta.Tag(permission_auto_classifier.TransportOutcome),
        billing: session_usage.Availability,
        request_count: ?u64,
    }{
        .{ .payload = "cancelled", .outcome = .cancelled, .billing = .incomplete, .request_count = 0 },
        .{ .payload = "timed_out", .outcome = .timed_out, .billing = .incomplete, .request_count = 0 },
        .{ .payload = "provider_failure", .outcome = .permanent_failure, .billing = .complete, .request_count = 0 },
        .{ .payload = "malformed", .outcome = .completion, .billing = .incomplete, .request_count = 0 },
        .{ .payload = "cancel_after_completion", .outcome = .cancelled, .billing = .complete, .request_count = 1 },
        .{ .payload = "provider_error", .outcome = .transient_failure, .billing = .complete, .request_count = 1 },
    };

    for (cases) |case| {
        var usage = session_usage.Usage.initFresh();
        defer usage.deinit(std.testing.allocator);
        var runtime = Runtime{
            .input = .{ .usage = &usage, .usage_allocator = std.testing.allocator },
            .adapter = .{
                .source = .chatgpt_subscription,
                .model = "gpt-review",
                .validate_fn = Fake.validate,
                .build_fn = Fake.build,
                .send_fn = Fake.send,
            },
        };
        var cancelled = std.atomic.Value(bool).init(false);
        var outcome = try sendReview(
            &runtime,
            std.testing.allocator,
            "gpt-review",
            case.payload,
            std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
                .clock = .awake,
                .raw = .fromSeconds(5),
            }),
            &cancelled,
        );
        defer if (outcome == .completion) outcome.completion.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.outcome, std.meta.activeTag(outcome));

        var snapshot = try usage.snapshot(std.testing.allocator);
        defer snapshot.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.billing, snapshot.billing);
        try std.testing.expectEqual(case.request_count, snapshot.request_count);
        try std.testing.expectEqual(@as(u64, 2), snapshot.next_sequence);
        try std.testing.expectEqual(@as(u64, 1), snapshot.settled_through_sequence);
        try std.testing.expectEqual(@as(usize, 0), snapshot.pending.len);
    }
}
