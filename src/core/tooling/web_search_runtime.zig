const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const diagnostics = @import("../workspace/diagnostics.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");
const tool_dispatch = @import("tool_dispatch.zig");
const tool_result_errors = @import("tool_result_errors.zig");
const model_request_budget = @import("model_request_budget.zig");
const web_search_contract = @import("web_search_contract.zig");
const web_search_policy = @import("web_search_policy.zig");
const web_search_provider = @import("web_search_provider.zig");
const test_builtin_tools = if (@import("builtin").is_test)
    @import("../../builtins/tools.zig")
else
    struct {};

const Allocator = std.mem.Allocator;

pub const ClockFn = *const fn (*anyopaque) i64;

var default_clock_context: u8 = 0;

pub const Clock = struct {
    ctx: *anyopaque = @ptrCast(&default_clock_context),
    now_fn: ClockFn = defaultNow,

    fn now(self: Clock) i64 {
        return self.now_fn(self.ctx);
    }
};

pub const Config = struct {
    clock: Clock = .{},
};

pub const Inputs = web_search_provider.Inputs;

pub const ExecutionOutput = web_search_contract.ExecutionOutput;

pub const Runtime = struct {
    clock: Clock,
    fallback_cancel_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(config: Config) Runtime {
        return .{
            .clock = config.clock,
        };
    }

    pub fn deinit(_: *Runtime) void {}

    pub fn dispatchBackend(self: *Runtime) tool_dispatch.WebSearchBackend {
        return .{ .ctx = @ptrCast(self), .execute_fn = executeForDispatch };
    }

    pub fn execute(
        self: *Runtime,
        alloc: Allocator,
        invocation: tool_dispatch.WebSearchInvocation,
        request: web_search_contract.Request,
        cancel_flag: *std.atomic.Value(bool),
    ) !ExecutionOutput {
        return self.executeWithProgress(alloc, invocation, request, cancel_flag, null, null);
    }

    pub fn executeWithProgress(
        self: *Runtime,
        alloc: Allocator,
        invocation: tool_dispatch.WebSearchInvocation,
        input: web_search_contract.Request,
        cancel_flag: *std.atomic.Value(bool),
        on_progress: ?web_search_contract.ProgressFn,
        progress_ctx: ?*anyopaque,
    ) !ExecutionOutput {
        const started_at_ms = self.clock.now();
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;

        const provider = invocation.provider;
        const inputs = invocation.inputs;
        var policy = provider.policy;
        if (try provider.preferredBackends()) |preferred_backends| {
            policy.preferred_backends = preferred_backends;
        }
        const selected_backend = web_search_policy.selectBackend(policy, .{
            .has_allowed_domains = hasValues(input.allowed_domains),
            .has_blocked_domains = hasValues(input.blocked_domains),
        }) orelse return error.UnsupportedWebSearchFeatures;
        if (!model_request_budget.searchWorkerInputFitsLimit(
            provider.input_overhead_bytes,
            input.query,
            input.allowed_domains,
            input.blocked_domains,
            policy.max_input_bytes,
        )) return error.WebSearchRequestTooLarge;
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;

        const request = web_search_contract.ProviderRequest{
            .backend = selected_backend.id,
            .query = input.query,
            .allowed_domains = input.allowed_domains,
            .blocked_domains = input.blocked_domains,
            .max_uses = policy.max_uses,
            .max_results = policy.max_results,
            .max_output_tokens = policy.max_output_tokens,
            .max_output_chars = policy.max_output_chars,
            .timeout_ms = policy.timeout_ms,
            .cancel_flag = cancel_flag,
        };

        const transport_started_at_ms = self.clock.now();
        var response = provider.execute(alloc, inputs, request, on_progress, progress_ctx) catch |err| {
            if (shouldRecordFailedNetworkCall(err)) {
                recordNetworkCall(inputs.model, transport_started_at_ms, self.clock.now(), 0, null, null, @errorName(err));
            }
            return err;
        };
        defer response.deinit(alloc);

        const transport_finished_at_ms = self.clock.now();
        const usage = response.usage;
        const web_search_requests = if (usage) |value| value.web_search_requests else 0;
        recordNetworkCall(inputs.model, transport_started_at_ms, transport_finished_at_ms, @intFromEnum(std.http.Status.ok), usage, response.stop_reason, "");
        const results = response.takeContent();
        const duration_ms = elapsedMs(started_at_ms, self.clock.now());
        debug_trace.logf("web_search", "complete backend={s} model={s} duration_ms={d} requests={d} stop_reason={s}", .{
            selected_backend.id.value,
            inputs.model,
            duration_ms,
            web_search_requests,
            response.stop_reason orelse "(none)",
        });
        return .{
            .output = .{
                .query = input.query,
                .results = results,
                .incomplete = hasTerminalIncomplete(results),
                .duration_ms = duration_ms,
                .web_search_requests = web_search_requests,
            },
            .inner_usage = usage,
        };
    }
};

const ProgressForwarder = struct {
    dispatch: tool_dispatch.DispatchContext,

    fn onProgress(raw_ctx: *anyopaque, progress: web_search_contract.Progress) void {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx));
        const callback = self.dispatch.on_web_search_progress orelse return;
        const callback_ctx = self.dispatch.web_search_progress_ctx orelse return;
        const update: types.WebSearchProgress = switch (progress) {
            .query_update => |query| .{ .query_started = query },
            .results_received => |entry| .{ .results_received = .{
                .query = entry.query,
                .result_count = entry.result_count,
            } },
        };
        callback(callback_ctx, self.dispatch.tool_call_id, update);
    }
};

fn executeForDispatch(
    raw_ctx: *anyopaque,
    ctx: tool_dispatch.DispatchContext,
    request: web_search_contract.Request,
) anyerror!web_search_contract.ExecutionOutput {
    const self: *Runtime = @ptrCast(@alignCast(raw_ctx));
    const invocation = ctx.web_search_invocation orelse return error.MissingWebSearchProvider;
    var progress_forwarder = ProgressForwarder{ .dispatch = ctx };
    return self.executeWithProgress(
        ctx.allocator,
        invocation,
        request,
        ctx.cancel_flag orelse &self.fallback_cancel_flag,
        if (ctx.on_web_search_progress != null) ProgressForwarder.onProgress else null,
        if (ctx.on_web_search_progress != null) @ptrCast(&progress_forwarder) else null,
    );
}

fn defaultNow(_: *anyopaque) i64 {
    return io_mod.milliTimestamp();
}

fn elapsedMs(started_at_ms: i64, finished_at_ms: i64) u64 {
    if (finished_at_ms <= started_at_ms) return 0;
    return @intCast(finished_at_ms - started_at_ms);
}

fn recordNetworkCall(
    model: []const u8,
    started_at_ms: i64,
    finished_at_ms: i64,
    status: u16,
    usage: ?types.ToolUsage,
    stop_reason: ?[]const u8,
    error_name: []const u8,
) void {
    var call: diagnostics.NetworkCall = .{
        .kind = .web_search,
        .started_at_ms = started_at_ms,
        .duration_ms = clampU64ToU32(elapsedMs(started_at_ms, finished_at_ms)),
        .status = status,
        .input_tokens = if (usage) |value| clampU64ToU32(value.input_tokens) else 0,
        .output_tokens = if (usage) |value| clampU64ToU32(value.output_tokens) else 0,
        .is_web_search = true,
        .web_search_requests = if (usage) |value| value.web_search_requests else 0,
    };
    call.setModel(model);
    if (stop_reason) |reason| call.setTerminalStopReason(reason);
    if (error_name.len > 0) call.setError(error_name);
    diagnostics.recordNetworkCall(call);
}

fn clampU64ToU32(value: u64) u32 {
    return @intCast(@min(value, std.math.maxInt(u32)));
}

fn shouldRecordFailedNetworkCall(err: anyerror) bool {
    return switch (err) {
        error.Cancelled,
        error.ConflictingDomainFilters,
        error.MissingGatewaySearchConfiguration,
        error.MissingWebSearchProvider,
        error.OutOfMemory,
        => false,
        else => true,
    };
}

fn hasValues(maybe_strings: ?[]const []const u8) bool {
    return if (maybe_strings) |strings| strings.len > 0 else false;
}

fn hasTerminalIncomplete(items: []const web_search_contract.ResultItem) bool {
    for (items) |item| {
        if (item == .terminal_incomplete) return true;
    }
    return false;
}

const FakeProvider = struct {
    calls: usize = 0,
    last_backend: ?web_search_contract.SearchBackendId = null,
    preferred_backends: ?[]const web_search_contract.SearchBackendId = null,
    configured_inputs_seen: bool = false,
    response_kind: enum { empty, source, incomplete, interleaved_incomplete } = .empty,
    transport_error: ?enum { cancelled, timeout } = null,
    policy: web_search_policy.WebSearchPolicy = test_policy,

    fn provider(self: *@This()) web_search_provider.Provider {
        return .{
            .context = @ptrCast(self),
            .policy = self.policy,
            .preferred_backends_fn = preferredBackends,
            .execute_fn = executeProvider,
        };
    }

    fn preferredBackends(raw_ctx: ?*anyopaque) !?[]const web_search_contract.SearchBackendId {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx orelse return error.MissingTestProvider));
        return self.preferred_backends;
    }

    fn executeProvider(
        raw_ctx: ?*anyopaque,
        alloc: Allocator,
        inputs: Inputs,
        request: web_search_contract.ProviderRequest,
        on_progress: ?web_search_contract.ProgressFn,
        progress_ctx: ?*anyopaque,
    ) !web_search_contract.ProviderResponse {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx orelse return error.MissingTestProvider));
        self.configured_inputs_seen = std.mem.eql(u8, inputs.credential, "provider-key") and
            std.mem.eql(u8, inputs.model, "provider/private-worker") and
            inputs.retry_count == 2 and
            std.mem.eql(u8, inputs.endpoint, "https://gateway.test/chat");
        return execute(@ptrCast(self), alloc, request, on_progress, progress_ctx);
    }

    fn execute(
        raw_ctx: *anyopaque,
        alloc: Allocator,
        request: web_search_contract.ProviderRequest,
        _: ?web_search_contract.ProgressFn,
        _: ?*anyopaque,
    ) anyerror!web_search_contract.ProviderResponse {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx));
        self.calls += 1;
        self.last_backend = request.backend;
        if (self.transport_error) |transport_error| {
            return switch (transport_error) {
                .cancelled => error.Cancelled,
                .timeout => error.TimeoutExpired,
            };
        }
        return switch (self.response_kind) {
            .empty => .{},
            .source => .{
                .content = try alloc.dupe(web_search_contract.ResultItem, &.{
                    .{ .search = .{
                        .tool_use_id = try alloc.dupe(u8, "search_1"),
                        .content = try alloc.dupe(web_search_contract.Source, &.{
                            .{
                                .title = try alloc.dupe(u8, "Zig release"),
                                .url = try alloc.dupe(u8, "https://ziglang.org/download/"),
                            },
                        }),
                    } },
                }),
                .usage = .{ .input_tokens = 12, .output_tokens = 34, .web_search_requests = 1 },
            },
            .incomplete => .{
                .content = try alloc.dupe(web_search_contract.ResultItem, &.{
                    .{ .commentary = try alloc.dupe(u8, "partial") },
                    .{ .terminal_incomplete = .{
                        .stop_reason = try alloc.dupe(u8, "max_tokens"),
                        .message = try alloc.dupe(u8, "incomplete"),
                    } },
                }),
                .stop_reason = try alloc.dupe(u8, "max_tokens"),
                .usage = .{ .web_search_requests = 1 },
            },
            .interleaved_incomplete => .{
                .content = try alloc.dupe(web_search_contract.ResultItem, &.{
                    .{ .commentary = try alloc.dupe(u8, "commentary A") },
                    .{ .search = .{
                        .tool_use_id = try alloc.dupe(u8, "search_1"),
                        .content = try alloc.dupe(web_search_contract.Source, &.{
                            .{
                                .title = try alloc.dupe(u8, "Zig release"),
                                .url = try alloc.dupe(u8, "https://ziglang.org/download/"),
                            },
                        }),
                    } },
                    .{ .error_text = try alloc.dupe(u8, "too_many_requests") },
                    .{ .commentary = try alloc.dupe(u8, "commentary B") },
                    .{ .search = .{
                        .tool_use_id = try alloc.dupe(u8, "search_2"),
                        .content = try alloc.dupe(web_search_contract.Source, &.{
                            .{
                                .title = try alloc.dupe(u8, "Release notes"),
                                .url = try alloc.dupe(u8, "https://ziglang.org/release-notes/"),
                            },
                        }),
                    } },
                    .{ .terminal_incomplete = .{
                        .stop_reason = try alloc.dupe(u8, "max_tokens"),
                        .message = try alloc.dupe(u8, "incomplete"),
                    } },
                }),
                .stop_reason = try alloc.dupe(u8, "max_tokens"),
                .usage = .{ .input_tokens = 12, .output_tokens = 34, .web_search_requests = 2 },
            },
        };
    }
};

const test_primary_backend = web_search_contract.SearchBackendId{ .value = "test.primary" };
const test_secondary_backend = web_search_contract.SearchBackendId{ .value = "test.secondary" };
const test_backend_order = [_]web_search_contract.SearchBackendId{ test_primary_backend, test_secondary_backend };
const test_backend_policies = [_]web_search_policy.BackendPolicy{
    .{
        .id = test_primary_backend,
        .features = .{
            .max_uses = .best_effort,
            .allowed_domains = .pass_through,
            .blocked_domains = .pass_through,
            .ordered_sources = true,
            .usage = true,
            .terminal_incomplete = true,
            .timeout = true,
            .cancellation = true,
            .result_bounds = .post_filter,
        },
    },
    .{
        .id = test_secondary_backend,
        .features = .{
            .max_uses = .best_effort,
            .allowed_domains = .pass_through,
            .blocked_domains = .pass_through,
            .ordered_sources = true,
            .usage = true,
            .terminal_incomplete = true,
            .timeout = true,
            .cancellation = true,
            .result_bounds = .pass_through,
        },
    },
};
const test_policy = web_search_policy.WebSearchPolicy{
    .preferred_backends = &test_backend_order,
    .backend_policies = &test_backend_policies,
};

fn testInvocation(fake: *FakeProvider) tool_dispatch.WebSearchInvocation {
    return .{
        .provider = fake.provider(),
        .inputs = .{
            .connection_id = "connection-a",
            .credential = "provider-key",
            .model = "provider/private-worker",
            .retry_count = 2,
            .endpoint = "https://gateway.test/chat",
        },
    };
}

test "runtime routes configured inputs and backend selection through provider" {
    const alloc = std.testing.allocator;
    const secondary_only = [_]web_search_contract.SearchBackendId{test_secondary_backend};
    var fake = FakeProvider{ .preferred_backends = &secondary_only };
    var runtime = Runtime.init(.{});
    var cancel_flag = std.atomic.Value(bool).init(false);
    const input = web_search_contract.Request{ .query = "latest Zig release" };

    var output = try runtime.execute(alloc, testInvocation(&fake), input, &cancel_flag);
    defer output.deinit(alloc);

    try std.testing.expect(fake.configured_inputs_seen);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expect(test_secondary_backend.eql(fake.last_backend.?));
}

test "pinned connection A search ignores later connection B selection" {
    const alloc = std.testing.allocator;
    var connection_a = FakeProvider{ .response_kind = .source };
    var connection_b = FakeProvider{};
    const pinned_a = testInvocation(&connection_a);
    var selected = pinned_a;
    selected = testInvocation(&connection_b);
    try std.testing.expect(selected.provider.context != pinned_a.provider.context);
    var runtime = Runtime.init(.{});
    var cancel_flag = std.atomic.Value(bool).init(false);

    var output = try runtime.execute(
        alloc,
        pinned_a,
        .{ .query = "latest Zig release" },
        &cancel_flag,
    );
    defer output.deinit(alloc);

    try std.testing.expect(connection_a.configured_inputs_seen);
    try std.testing.expectEqual(@as(usize, 1), connection_a.calls);
    try std.testing.expectEqual(@as(usize, 0), connection_b.calls);
}

test "runtime invokes primary backend after allow" {
    const alloc = std.testing.allocator;
    var fake = FakeProvider{};
    var runtime = Runtime.init(.{});
    var cancel_flag = std.atomic.Value(bool).init(false);
    const input = web_search_contract.Request{ .query = "latest Zig release" };

    var output = try runtime.execute(alloc, testInvocation(&fake), input, &cancel_flag);
    defer output.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expect(test_primary_backend.eql(fake.last_backend.?));
}

test "runtime invokes secondary backend after allow" {
    const alloc = std.testing.allocator;
    var fake = FakeProvider{};
    var runtime = Runtime.init(.{});
    fake.policy.preferred_backends = &.{test_secondary_backend};
    var cancel_flag = std.atomic.Value(bool).init(false);
    const input = web_search_contract.Request{ .query = "latest Zig release" };

    var output = try runtime.execute(alloc, testInvocation(&fake), input, &cancel_flag);
    defer output.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expect(test_secondary_backend.eql(fake.last_backend.?));
}

test "runtime falls back before request when first backend cannot satisfy strict filter" {
    const alloc = std.testing.allocator;
    var fake = FakeProvider{};
    var runtime = Runtime.init(.{});
    var unsupported = test_backend_policies[0];
    unsupported.features.allowed_domains = .unsupported;
    const backends = [_]web_search_policy.BackendPolicy{
        unsupported,
        test_backend_policies[1],
    };
    fake.policy.backend_policies = &backends;
    var cancel_flag = std.atomic.Value(bool).init(false);
    const allowed_domains = [_][]const u8{"ziglang.org"};
    const input = web_search_contract.Request{
        .query = "latest Zig release",
        .allowed_domains = &allowed_domains,
    };

    var output = try runtime.execute(alloc, testInvocation(&fake), input, &cancel_flag);
    defer output.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expect(test_secondary_backend.eql(fake.last_backend.?));
}

test "unsupported strict filters perform zero backend search requests" {
    const alloc = std.testing.allocator;
    var fake = FakeProvider{};
    var runtime = Runtime.init(.{});
    var unsupported = test_backend_policies[0];
    unsupported.features.allowed_domains = .unsupported;
    fake.policy.preferred_backends = &.{test_primary_backend};
    fake.policy.backend_policies = &.{unsupported};
    var cancel_flag = std.atomic.Value(bool).init(false);
    const allowed_domains = [_][]const u8{"ziglang.org"};
    const input = web_search_contract.Request{
        .query = "latest Zig release",
        .allowed_domains = &allowed_domains,
    };

    try std.testing.expectError(error.UnsupportedWebSearchFeatures, runtime.execute(alloc, testInvocation(&fake), input, &cancel_flag));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "oversized worker request performs zero backend search requests" {
    const alloc = std.testing.allocator;
    var fake = FakeProvider{};
    var runtime = Runtime.init(.{});
    fake.policy.max_input_bytes = 8;
    var cancel_flag = std.atomic.Value(bool).init(false);
    const input = web_search_contract.Request{ .query = "latest Zig release" };

    try std.testing.expectError(error.WebSearchRequestTooLarge, runtime.execute(alloc, testInvocation(&fake), input, &cancel_flag));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "cancelled runtime performs zero backend search requests" {
    const alloc = std.testing.allocator;
    var fake = FakeProvider{};
    var runtime = Runtime.init(.{});
    var cancel_flag = std.atomic.Value(bool).init(true);
    const input = web_search_contract.Request{ .query = "latest Zig release" };

    try std.testing.expectError(error.Cancelled, runtime.execute(alloc, testInvocation(&fake), input, &cancel_flag));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "missing selected adapter invocation records no network request" {
    const alloc = std.testing.allocator;
    diagnostics.resetForTest();
    defer diagnostics.resetForTest();
    var runtime = Runtime.init(.{});
    try std.testing.expectError(error.MissingWebSearchProvider, executeForDispatch(
        @ptrCast(&runtime),
        .{ .allocator = alloc },
        .{ .query = "latest Zig release" },
    ));
    var calls: [diagnostics.network_ring_capacity]diagnostics.NetworkCall = undefined;
    try std.testing.expectEqual(@as(usize, 0), diagnostics.snapshotNetworkCalls(&calls));
}

test "runtime normalizes source usage and terminal incomplete state" {
    const alloc = std.testing.allocator;
    var source_fake = FakeProvider{ .response_kind = .source };
    var source_runtime = Runtime.init(.{});
    var cancel_flag = std.atomic.Value(bool).init(false);
    const input = web_search_contract.Request{ .query = "latest Zig release" };

    var source = try source_runtime.execute(alloc, testInvocation(&source_fake), input, &cancel_flag);
    defer source.deinit(alloc);
    try std.testing.expectEqualStrings("Zig release", source.output.results[0].search.content[0].title);
    try std.testing.expectEqual(@as(u32, 1), source.inner_usage.?.web_search_requests);

    var incomplete_fake = FakeProvider{ .response_kind = .incomplete };
    var incomplete_runtime = Runtime.init(.{});
    var incomplete = try incomplete_runtime.execute(alloc, testInvocation(&incomplete_fake), input, &cancel_flag);
    defer incomplete.deinit(alloc);
    try std.testing.expect(incomplete.output.incomplete);
    try std.testing.expectEqualStrings("max_tokens", incomplete.output.results[1].terminal_incomplete.stop_reason);
}

test "runtime preserves ordered commentary search errors sources and terminal incomplete state" {
    const alloc = std.testing.allocator;
    var fake = FakeProvider{ .response_kind = .interleaved_incomplete };
    var runtime = Runtime.init(.{});
    var cancel_flag = std.atomic.Value(bool).init(false);
    const input = web_search_contract.Request{ .query = "latest Zig release" };

    var output = try runtime.execute(alloc, testInvocation(&fake), input, &cancel_flag);
    defer output.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 6), output.output.results.len);
    try std.testing.expectEqualStrings("commentary A", output.output.results[0].commentary);
    try std.testing.expectEqualStrings("search_1", output.output.results[1].search.tool_use_id);
    try std.testing.expectEqualStrings("too_many_requests", output.output.results[2].error_text);
    try std.testing.expectEqualStrings("commentary B", output.output.results[3].commentary);
    try std.testing.expectEqualStrings("search_2", output.output.results[4].search.tool_use_id);
    try std.testing.expectEqualStrings("max_tokens", output.output.results[5].terminal_incomplete.stop_reason);
    try std.testing.expect(output.output.incomplete);
}

test "runtime reports bounded backend timeout" {
    const alloc = std.testing.allocator;
    var fake = FakeProvider{ .transport_error = .timeout };
    var runtime = Runtime.init(.{});
    var cancel_flag = std.atomic.Value(bool).init(false);
    const input = web_search_contract.Request{ .query = "latest Zig release" };

    try std.testing.expectError(error.TimeoutExpired, runtime.execute(alloc, testInvocation(&fake), input, &cancel_flag));
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
}

var permission_decider_calls: usize = 0;

fn denyPermission(_: *const tool_dispatch.Tool, _: tool_dispatch.ToolInput, _: tool_dispatch.DispatchContext) @import("../permissions/permission_gate.zig").Decision {
    permission_decider_calls += 1;
    return .{ .action = .deny, .reason = "test deny" };
}

fn allowPermission(_: *const tool_dispatch.Tool, _: tool_dispatch.ToolInput, _: tool_dispatch.DispatchContext) @import("../permissions/permission_gate.zig").Decision {
    permission_decider_calls += 1;
    return .{ .action = .allow, .reason = "test allow" };
}

test "denied web_search performs zero backend search requests" {
    const alloc = std.testing.allocator;
    var fake = FakeProvider{};
    var runtime = Runtime.init(.{});
    const registry = tool_dispatch.Registry{ .tools = &.{test_builtin_tools.web_search} };

    permission_decider_calls = 0;
    var result = try tool_dispatch.dispatchToolCall(.{
        .allocator = alloc,
        .permission_decider = denyPermission,
        .tool_capabilities = .{ .web_search_runtime_ready = true },
        .web_search_backend = runtime.dispatchBackend(),
        .web_search_invocation = testInvocation(&fake),
    }, registry, .{
        .id = "search",
        .name = "web_search",
        .arguments_json = "{\"query\":\"latest Zig release\"}",
    });
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), permission_decider_calls);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "invalid web_search performs zero backend search requests" {
    const alloc = std.testing.allocator;
    var fake = FakeProvider{};
    var runtime = Runtime.init(.{});
    const registry = tool_dispatch.Registry{ .tools = &.{test_builtin_tools.web_search} };

    permission_decider_calls = 0;
    var result = try tool_dispatch.dispatchToolCall(.{
        .allocator = alloc,
        .permission_decider = allowPermission,
        .tool_capabilities = .{ .web_search_runtime_ready = true },
        .web_search_backend = runtime.dispatchBackend(),
        .web_search_invocation = testInvocation(&fake),
    }, registry, .{
        .id = "search",
        .name = "web_search",
        .arguments_json = "{\"query\":\"x\"}",
    });
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), permission_decider_calls);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "missing runtime web_search performs zero backend search requests" {
    const alloc = std.testing.allocator;
    const registry = tool_dispatch.Registry{ .tools = &.{test_builtin_tools.web_search} };

    permission_decider_calls = 0;
    var result = try tool_dispatch.dispatchToolCall(.{
        .allocator = alloc,
        .permission_decider = allowPermission,
    }, registry, .{
        .id = "search",
        .name = "web_search",
        .arguments_json = "{\"query\":\"latest Zig release\"}",
    });
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), permission_decider_calls);
}

test "allowed web_search invokes selected backend exactly once" {
    const alloc = std.testing.allocator;
    var fake = FakeProvider{ .response_kind = .source };
    var runtime = Runtime.init(.{});
    const registry = tool_dispatch.Registry{ .tools = &.{test_builtin_tools.web_search} };

    permission_decider_calls = 0;
    var result = try tool_dispatch.dispatchToolCall(.{
        .allocator = alloc,
        .permission_decider = allowPermission,
        .tool_capabilities = .{ .web_search_runtime_ready = true },
        .web_search_backend = runtime.dispatchBackend(),
        .web_search_invocation = testInvocation(&fake),
    }, registry, .{
        .id = "search",
        .name = "web_search",
        .arguments_json = "{\"query\":\"latest Zig release\"}",
    });
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), permission_decider_calls);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.find(u8, result.body, "Zig release") != null);
    try std.testing.expectEqual(@as(u32, 1), result.inner_usage.?.web_search_requests);
    try std.testing.expectEqual(@as(u32, 1), result.web_search_completion.?.searches);
}

test "cancelled registered web_search performs zero backend requests" {
    const alloc = std.testing.allocator;
    var fake = FakeProvider{};
    var runtime = Runtime.init(.{});
    const registry = tool_dispatch.Registry{ .tools = &.{test_builtin_tools.web_search} };
    var cancel_flag = std.atomic.Value(bool).init(true);

    permission_decider_calls = 0;
    var result = try tool_dispatch.dispatchToolCall(.{
        .allocator = alloc,
        .cancel_flag = &cancel_flag,
        .permission_decider = allowPermission,
        .tool_capabilities = .{ .web_search_runtime_ready = true },
        .web_search_backend = runtime.dispatchBackend(),
        .web_search_invocation = testInvocation(&fake),
    }, registry, .{
        .id = "search",
        .name = "web_search",
        .arguments_json = "{\"query\":\"latest Zig release\"}",
    });
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), permission_decider_calls);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(.failure, result.status);
    try std.testing.expect(tool_result_errors.isToolExecutionFailedOutput(result.body));
}
