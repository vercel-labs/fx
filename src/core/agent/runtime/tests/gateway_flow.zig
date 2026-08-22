const std = @import("std");
const agent_stream_provider = @import("../../stream_provider.zig");
const builtin_tools = @import("../../../../builtins/tools.zig");
const types = @import("../../../shared/types.zig");
const token_estimate = @import("../../../shared/token_estimate.zig");
const worker_runtime = @import("../../worker_runtime.zig");
const session_runtime = @import("../../../session/session.zig");
const session_codec = @import("../../../session/session_codec.zig");
const gateway_json = @import("../../../gateway/gateway_json.zig");
const model_capabilities = @import("../../../config/model_capabilities.zig");
const debug_trace = @import("../../../shared/debug_trace.zig");
const image_attachments = @import("../../../images/image_attachments.zig");
const io_mod = @import("../../../shared/io.zig");
const runtime_deps = @import("../deps.zig");
const runtime_tool_contracts = @import("../tool_contracts.zig");
const context_limits = @import("../../../config/context_limits.zig");
const vision_executor = @import("../vision_executor.zig");
const diagnostics = @import("../../../workspace/diagnostics.zig");
const lifecycle_hooks = @import("../../../hooks/hooks.zig");
const tool_dispatch = @import("../../../tooling/tool_dispatch.zig");

const test_support = @import("support.zig");

const Allocator = std.mem.Allocator;
const HistoryTurn = types.HistoryTurn;
const PermissionGrant = types.PermissionGrant;
const ToolCall = types.ToolCall;
const QueuedPrompt = worker_runtime.QueuedPrompt;

const FakeCompletion = test_support.FakeCompletion;
const FakeGateway = test_support.FakeGateway;
const FakeAgentRuntimeDeps = test_support.FakeAgentRuntimeDeps;
const ModelCapabilityOverride = test_support.ModelCapabilityOverride;
const PromptFixture = test_support.PromptFixture;
const VisionAgentToolRuntime = test_support.VisionAgentToolRuntime;
const ExecuteDelegate = test_support.ExecuteDelegate;
const ToolExecutionRequest = runtime_tool_contracts.ToolExecutionRequest;
const ToolExecutionResult = runtime_tool_contracts.ToolExecutionResult;

const runFakePrompt = test_support.runFakePrompt;
const expectBodyContains = test_support.expectBodyContains;
const expectBodyNotContains = test_support.expectBodyNotContains;
const expectBodyContainsInOrder = test_support.expectBodyContainsInOrder;
const expectGatewayPromptFinalUserText = test_support.expectGatewayPromptFinalUserText;
const countPromptEntryText = test_support.countPromptEntryText;
const countText = test_support.countText;
const countNeedle = test_support.countNeedle;
const readTraceFile = test_support.readTraceFile;
const logIndex = test_support.logIndex;
const toolCall = test_support.toolCall;

const vision_and_read_file_tools = [_]tool_dispatch.Tool{
    builtin_tools.vision,
    builtin_tools.read_file,
};
const vision_read_and_terminal_tools = [_]tool_dispatch.Tool{
    builtin_tools.vision,
    builtin_tools.read_file,
    builtin_tools.terminal,
};
const terminal_nested_tools_json =
    "[{\"type\":\"function\",\"name\":\"terminal\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"request\":{\"oneOf\":[{\"type\":\"object\"}]}},\"required\":[\"request\"],\"additionalProperties\":false}}]";

const VisionAndReadExecutor = struct {
    vision: ExecuteDelegate,

    fn delegate(self: *@This()) ExecuteDelegate {
        return .{
            .ctx = self,
            .run = execute,
            .set_agent_stream_provider = setAgentStreamProvider,
        };
    }

    fn setAgentStreamProvider(raw: *anyopaque, provider: agent_stream_provider.Provider) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.vision.set_agent_stream_provider) |set_provider| {
            set_provider(self.vision.ctx, provider);
        }
    }

    fn execute(raw: *anyopaque, request: ToolExecutionRequest) !ToolExecutionResult {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (std.mem.eql(u8, request.call.name, "vision")) {
            return self.vision.run(self.vision.ctx, request);
        }
        if (std.mem.eql(u8, request.call.name, "read_file")) {
            return .{ .model_output = "ordinary read contents" };
        }
        return error.TestUnexpectedTool;
    }
};

fn lifecycleEventCallId(event: types.ToolLifecycleEvent) ?[]const u8 {
    return switch (event) {
        .provisional => |value| value.id.call_id,
        .authoritative_started => |value| value.id.call_id,
        .progress => |value| value.id.call_id,
        .terminal => |value| value.id.call_id,
        .turn_finished => null,
    };
}

fn expectNoLifecycleForCall(events: []const types.ToolLifecycleEvent, call_id: []const u8) !void {
    for (events) |event| {
        const event_call_id = lifecycleEventCallId(event) orelse continue;
        try std.testing.expect(!std.mem.eql(u8, event_call_id, call_id));
    }
}

fn expectFailedLifecycleContains(
    events: []const types.ToolLifecycleEvent,
    call_id: []const u8,
    needle: []const u8,
) !void {
    for (events) |event| {
        if (event != .terminal) continue;
        const terminal = event.terminal;
        if (!std.mem.eql(u8, terminal.id.call_id, call_id)) continue;
        try std.testing.expectEqual(types.ToolOutcomeKind.failed, terminal.outcome.kind);
        try std.testing.expect(std.mem.find(u8, terminal.outcome.summary, needle) != null);
        return;
    }
    return error.TestExpectedEqual;
}

fn expectNoticeContains(hooks: *const FakeAgentRuntimeDeps, index: usize, needle: []const u8) !void {
    try std.testing.expect(index < hooks.system_notices.items.len);
    try std.testing.expect(std.mem.find(u8, hooks.system_notices.items[index], needle) != null);
}

fn expectRouteStatus(
    hooks: *const FakeAgentRuntimeDeps,
    index: usize,
    kind: types.RouteRecoveryStatus.Kind,
    expected_label: []const u8,
) !void {
    try std.testing.expect(index < hooks.route_recovery_statuses.items.len);
    const status = hooks.route_recovery_statuses.items[index];
    try std.testing.expectEqual(kind, status.kind);
    var label_buf: [types.RouteRecoveryStatus.label_max_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(expected_label, status.label(&label_buf));
}

test "processQueuedPrompt projects lifecycle session identity to the provider" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{.{ .content = "ok" }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    const config = fixture.config();
    var lifecycle = test_support.testLifecycleContext(
        lifecycle_hooks.RuntimeView.empty(),
        alloc,
        config.workspace_root,
    );
    lifecycle.scope.session_id = "session-provider-123";

    try test_support.runFakePromptWithLifecycle(
        &gateway,
        &hooks,
        config,
        fixture.job(),
        lifecycle,
    );

    try std.testing.expectEqual(@as(usize, 1), gateway.request_session_ids.items.len);
    try std.testing.expectEqualStrings(
        "session-provider-123",
        gateway.request_session_ids.items[0].?,
    );
}

fn makeOwnedProviderPrompt(alloc: Allocator, text: []const u8, model: []const u8) !QueuedPrompt {
    const prompt = try alloc.dupe(u8, text);
    errdefer alloc.free(prompt);
    const model_copy = try alloc.dupe(u8, model);
    errdefer alloc.free(model_copy);
    const api_key = try alloc.dupe(u8, "key");
    errdefer alloc.free(api_key);
    const history = try alloc.alloc(HistoryTurn, 0);
    errdefer alloc.free(history);
    const grants = try alloc.alloc(PermissionGrant, 0);
    errdefer alloc.free(grants);

    return .{
        .prompt = prompt,
        .images = &.{},
        .model = model_copy,
        .api_key = api_key,
        .permission_mode = .ask,
        .history = history,
        .grants = grants,
    };
}

fn expectPromptEntryRole(entry: std.json.Value, expected_role: types.ChatRole) !void {
    try std.testing.expect(entry == .object);
    const role = entry.object.get("role") orelse return error.TestExpectedPromptRoleMissing;
    try std.testing.expect(role == .string);
    try std.testing.expectEqualStrings(gateway_json.roleName(expected_role), role.string);
}

fn expectGatewayPromptRoles(gateway: *const FakeGateway, index: usize, expected_roles: []const types.ChatRole) !void {
    const alloc = std.testing.allocator;
    try std.testing.expect(index < gateway.request_bodies.items.len);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, gateway.request_bodies.items[index], .{});
    defer parsed.deinit();

    const prompt = parsed.value.object.get("prompt").?.array.items;
    try std.testing.expectEqual(expected_roles.len, prompt.len);
    for (expected_roles, 0..) |expected_role, i| {
        try expectPromptEntryRole(prompt[i], expected_role);
    }
}

fn expectGatewayPromptTailText(
    gateway: *const FakeGateway,
    index: usize,
    expected_role: types.ChatRole,
    expected_text: []const u8,
) !void {
    const alloc = std.testing.allocator;
    try std.testing.expect(index < gateway.request_bodies.items.len);

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        gateway.request_bodies.items[index],
        .{},
    );
    defer parsed.deinit();

    const prompt = parsed.value.object.get("prompt").?.array.items;
    try std.testing.expect(prompt.len > 0);
    const tail = prompt[prompt.len - 1];
    try expectPromptEntryRole(tail, expected_role);
    try std.testing.expectEqual(
        @as(usize, 1),
        countPromptEntryText(tail, expected_text),
    );
}

fn expectRootFieldAbsent(gateway: *const FakeGateway, index: usize, field: []const u8) !void {
    const alloc = std.testing.allocator;
    try std.testing.expect(index < gateway.request_bodies.items.len);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, gateway.request_bodies.items[index], .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get(field) == null);
}

fn expectGatewayPromptStringEntry(gateway: *const FakeGateway, index: usize, entry_index: usize, expected: []const u8) !void {
    const alloc = std.testing.allocator;
    try std.testing.expect(index < gateway.request_bodies.items.len);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, gateway.request_bodies.items[index], .{});
    defer parsed.deinit();

    const prompt = parsed.value.object.get("prompt").?.array.items;
    try std.testing.expect(entry_index < prompt.len);
    const entry = prompt[entry_index];
    try std.testing.expect(entry == .object);
    const content = entry.object.get("content") orelse return error.TestExpectedPromptMessageMissing;
    try std.testing.expect(content == .string);
    try std.testing.expectEqualStrings(expected, content.string);
}

fn expectGatewayToolResultOutput(
    gateway: *const FakeGateway,
    index: usize,
    tool_call_id: []const u8,
    expected: []const u8,
) !void {
    const alloc = std.testing.allocator;
    try std.testing.expect(index < gateway.request_bodies.items.len);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, gateway.request_bodies.items[index], .{});
    defer parsed.deinit();

    const prompt = parsed.value.object.get("prompt").?.array.items;
    for (prompt) |entry| {
        if (entry != .object) continue;
        const content = entry.object.get("content") orelse continue;
        if (content != .array) continue;
        for (content.array.items) |part| {
            if (part != .object) continue;
            const part_call_id = part.object.get("toolCallId") orelse continue;
            if (part_call_id != .string or !std.mem.eql(u8, part_call_id.string, tool_call_id)) continue;
            const output = part.object.get("output") orelse continue;
            if (output != .object) continue;
            const value = output.object.get("value") orelse continue;
            if (value != .string) continue;
            try std.testing.expectEqualStrings(expected, value.string);
            return;
        }
    }
    return error.TestExpectedPromptMessageMissing;
}

fn expectGatewayPromptTextCount(gateway: *const FakeGateway, index: usize, needle: []const u8, expected_count: usize) !void {
    const alloc = std.testing.allocator;
    try std.testing.expect(index < gateway.request_bodies.items.len);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, gateway.request_bodies.items[index], .{});
    defer parsed.deinit();

    const prompt = parsed.value.object.get("prompt").?.array.items;
    var count: usize = 0;
    for (prompt) |entry| count += countPromptEntryText(entry, needle);
    try std.testing.expectEqual(expected_count, count);
}

fn writeTestImagePath(alloc: Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    {
        var file = try tmp.dir.createFile(std.testing.io, "fixture-image.png", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "\x89PNG\r\n\x1a\nfixture image bytes");
    }
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, "fixture-image.png");
}

fn testSnapshotDir(alloc: Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    return std.fs.path.join(alloc, &.{ root, "snapshots" });
}

fn testCapturedImage(
    alloc: Allocator,
    tmp: *std.testing.TmpDir,
    image_path: []const u8,
    id: usize,
) !types.ImageAttachment {
    const source = [_]types.ImageAttachment{.{
        .id = id,
        .path = @constCast(image_path),
        .media_type = @constCast("image/png"),
    }};
    const owned = try types.dupeImageAttachmentSlice(alloc, &source);
    defer alloc.free(owned);

    var image = owned[0];
    errdefer types.freeImageAttachment(alloc, image);
    const snapshot_dir = try testSnapshotDir(alloc, tmp);
    defer alloc.free(snapshot_dir);
    try image_attachments.captureImageSnapshot(alloc, &image, snapshot_dir);
    return image;
}

fn freeImageSlice(alloc: Allocator, images: []types.ImageAttachment) void {
    for (images) |image| types.freeImageAttachment(alloc, image);
}

fn visionArgumentsForIds(alloc: Allocator, image_ids: []const usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"image_ids\":[");
    for (image_ids, 0..) |image_id, index| {
        if (index > 0) try out.writer.writeByte(',');
        try out.writer.print("{d}", .{image_id});
    }
    try out.writer.writeAll("],\"focus\":\"inspect all images\"}");
    return out.toOwnedSlice();
}

fn visionProviderResultForIds(alloc: Allocator, image_ids: []const usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"images\":[");
    for (image_ids, 0..) |image_id, index| {
        if (index > 0) try out.writer.writeByte(',');
        try out.writer.print(
            "{{\"image_id\":{d},\"status\":\"ok\",\"summary\":\"image {d}\",\"visible_text\":[],\"details\":[]}}",
            .{ image_id, image_id },
        );
    }
    try out.writer.writeAll("]}");
    return out.toOwnedSlice();
}

fn denseVisionProviderResult(alloc: Allocator) ![]u8 {
    const long_summary = try alloc.alloc(u8, 5000);
    defer alloc.free(long_summary);
    @memset(long_summary, 'x');

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll(
        "{\"images\":[{\"image_id\":1,\"status\":\"ok\",\"summary\":\"dense evidence\",\"visible_text\":[",
    );
    for (0..40) |index| {
        if (index > 0) try out.writer.writeByte(',');
        try out.writer.print("\"visible item {d}\"", .{index});
    }
    try out.writer.writeAll("],\"details\":[]},{\"image_id\":2,\"status\":\"ok\",\"summary\":");
    try std.json.Stringify.value(long_summary, .{}, &out.writer);
    try out.writer.writeAll(",\"visible_text\":[],\"details\":[]}]}");
    return out.toOwnedSlice();
}

fn countVisionProviderCalls(gateway: *const FakeGateway) usize {
    var count: usize = 0;
    for (gateway.request_models.items) |request_model| {
        if (std.mem.eql(u8, request_model, "google/gemini-2.5-flash")) count += 1;
    }
    return count;
}

fn oversizedVisionProviderResult(alloc: Allocator, summary_bytes: usize) ![]u8 {
    const summary = try alloc.alloc(u8, summary_bytes);
    defer alloc.free(summary);
    @memset(summary, 'a');
    return std.fmt.allocPrint(
        alloc,
        "{{\"images\":[{{\"image_id\":1,\"status\":\"ok\",\"summary\":\"{s}\",\"visible_text\":[],\"details\":[]}}]}}",
        .{summary},
    );
}

/// Drives `vision_executor.execute` against a scripted provider so a single batch's
/// retry classification can be observed without the surrounding prompt pipeline.
const VisionProviderScript = struct {
    responses: []const Response,
    calls: usize = 0,

    const Response = union(enum) {
        content: []const u8,
        http_status: std.http.Status,
        cancel,
    };

    fn stream(
        context: ?*anyopaque,
        _: Allocator,
        request: agent_stream_provider.Request,
    ) anyerror!agent_stream_provider.Result {
        const self: *VisionProviderScript = @ptrCast(@alignCast(context.?));
        if (self.calls >= self.responses.len) return error.TestVisionScriptExhausted;
        const response = self.responses[self.calls];
        self.calls += 1;
        return switch (response) {
            .content => |text| .{ .status = .ok, .completion = .{ .content = text } },
            .http_status => |status| .{ .status = status },
            .cancel => blk: {
                request.cancel_flag.store(true, .seq_cst);
                break :blk .{ .status = .ok };
            },
        };
    }
};

fn runScriptedVision(
    alloc: Allocator,
    script: *VisionProviderScript,
    catalog: []const types.ImageAttachment,
    args_json: []const u8,
    output_limit_bytes: usize,
) !runtime_tool_contracts.ToolExecutionResult {
    var provider = @import("../../../../builtins/gateway.zig").agent_stream_provider;
    provider.context = script;
    provider.stream_fn = VisionProviderScript.stream;
    return vision_executor.execute(alloc, args_json, catalog, .{
        .stream_provider = provider,
        .api_key = "key",
        .gateway_team = null,
        .retry_count = 1,
        .chat_url = "https://example.invalid",
        .cancel_flag = null,
        .usage = null,
        .usage_allocator = alloc,
        .trace_ctx = .{},
        .output_limit = .{
            .value = .{ .bytes = output_limit_bytes },
            .source = .command_line,
        },
    });
}

fn expectGatewayPromptEntryCacheControl(gateway: *const FakeGateway, index: usize, needle: []const u8, expected: bool) !void {
    const alloc = std.testing.allocator;
    try std.testing.expect(index < gateway.request_bodies.items.len);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, gateway.request_bodies.items[index], .{});
    defer parsed.deinit();

    const prompt = parsed.value.object.get("prompt").?.array.items;
    for (prompt) |entry| {
        if (countPromptEntryText(entry, needle) == 0) continue;
        try std.testing.expectEqual(expected, entry.object.get("providerOptions") != null);
        return;
    }
    return error.TestExpectedPromptMessageMissing;
}

fn expectNoPromptCacheControlAfter(gateway: *const FakeGateway, index: usize, needle: []const u8) !void {
    try std.testing.expect(index < gateway.request_bodies.items.len);
    const body = gateway.request_bodies.items[index];
    const start = std.mem.indexOf(u8, body, needle) orelse return error.TestExpectedBodyNeedleMissing;
    try std.testing.expect(std.mem.find(u8, body[start..], "cacheControl") == null);
}

test "processQueuedPrompt gates text-only images through the real Vision runtime" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try writeTestImagePath(alloc, &tmp);
    defer alloc.free(image_path);
    const image = try testCapturedImage(alloc, &tmp, image_path, 1);
    defer types.freeImageAttachment(alloc, image);
    var images = [_]types.ImageAttachment{image};

    const calls = [_]ToolCall{toolCall(
        "call_vision",
        "vision",
        "{\"image_ids\":[1],\"focus\":\"describe the image\"}",
    )};
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &calls },
        .{ .content = "{\"images\":[{\"image_id\":1,\"status\":\"ok\",\"summary\":\"FX logo\",\"visible_text\":[\"FX LOGO\"],\"details\":[\"square mark\"]}]}" },
        .{ .content = "Final selected-model answer" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.tool_registry = .{ .tools = test_support.vision_agent_test_tools[0..] };
    defer hooks.deinit();
    var vision_runtime = VisionAgentToolRuntime{ .alloc = alloc };
    defer vision_runtime.deinit();
    hooks.execute_delegate = vision_runtime.delegate();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.fast_mode = true;
    var job = fixture.job();
    job.model = @constCast("zai/glm-5.2");
    job.prompt = @constCast("Describe the attached image.");
    job.images = &images;
    job.authorized_image_catalog = &images;

    try runFakePrompt(&gateway, &hooks, config, job);

    try std.testing.expectEqual(@as(usize, 1), hooks.capability_queries.items.len);
    try std.testing.expectEqualStrings("zai/glm-5.2", hooks.capability_queries.items[0]);
    try std.testing.expectEqual(@as(usize, 3), gateway.request_models.items.len);
    try std.testing.expectEqualStrings("zai/glm-5.2", gateway.request_models.items[0]);
    try std.testing.expectEqualStrings("google/gemini-2.5-flash", gateway.request_models.items[1]);
    try std.testing.expectEqualStrings("zai/glm-5.2", gateway.request_models.items[2]);
    try expectBodyContains(&gateway, 0, "\"toolChoice\":{\"type\":\"required\"}");
    try expectBodyContains(&gateway, 0, "\"name\":\"vision\"");
    try expectBodyContains(&gateway, 0, "[Image #1]");
    try expectBodyNotContains(&gateway, 0, "\"type\":\"file\"");
    try expectBodyNotContains(&gateway, 0, image_path);
    try expectBodyContains(&gateway, 1, "\"type\":\"file\"");
    try expectBodyNotContains(&gateway, 1, image_path);
    try expectBodyContains(&gateway, 2, "FX logo");
    try expectBodyContains(&gateway, 2, "FX LOGO");
    try expectBodyNotContains(&gateway, 2, image_path);
    try std.testing.expectEqualStrings("Final selected-model answer", hooks.finish_assistant_text.?);
}

test "processQueuedPrompt recovers when a model rejects post-Vision assistant prefill" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try writeTestImagePath(alloc, &tmp);
    defer alloc.free(image_path);
    const image = try testCapturedImage(alloc, &tmp, image_path, 1);
    defer types.freeImageAttachment(alloc, image);
    var images = [_]types.ImageAttachment{image};

    const calls = [_]ToolCall{toolCall(
        "call_vision_prefill_recovery",
        "vision",
        "{\"image_ids\":[1],\"focus\":\"describe the image\"}",
    )};
    const prefill_rejection =
        "{\"error\":{\"message\":\"AI_APICallError: This model does not support " ++
        "assistant message prefill. The conversation must end with a user message.\"}}";
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &calls },
        .{ .content = "{\"images\":[{\"image_id\":1,\"status\":\"ok\",\"summary\":\"FX logo\",\"visible_text\":[],\"details\":[]}] }" },
        .{ .status = .bad_request, .err_body = prefill_rejection },
        .{ .content = "Recovered final answer" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.tool_registry = .{ .tools = test_support.vision_agent_test_tools[0..] };
    defer hooks.deinit();
    var vision_runtime = VisionAgentToolRuntime{ .alloc = alloc };
    defer vision_runtime.deinit();
    hooks.execute_delegate = vision_runtime.delegate();
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.model = @constCast("anthropic/claude-fable-5");
    job.prompt = @constCast("Describe the attached image.");
    job.images = &images;
    job.authorized_image_catalog = &images;

    try runFakePrompt(&gateway, &hooks, fixture.config(), job);

    try std.testing.expectEqual(@as(usize, 4), gateway.request_bodies.items.len);
    try expectGatewayPromptTailText(
        &gateway,
        2,
        .tool,
        "FX logo",
    );
    try expectGatewayPromptTailText(
        &gateway,
        3,
        .user,
        "Continue from the preceding tool result.",
    );
    try std.testing.expectEqual(@as(?std.http.Status, null), hooks.http_status);
    try std.testing.expectEqualStrings("Recovered final answer", hooks.finish_assistant_text.?);
}

test "text-only Vision keeps later permission restriction trusted across model steps" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try writeTestImagePath(alloc, &tmp);
    defer alloc.free(image_path);
    const image = try testCapturedImage(alloc, &tmp, image_path, 1);
    defer types.freeImageAttachment(alloc, image);
    var images = [_]types.ImageAttachment{image};

    const vision_calls = [_]ToolCall{toolCall(
        "call_vision",
        "vision",
        "{\"image_ids\":[1],\"focus\":\"describe the image\"}",
    )};
    const restricted_calls = [_]ToolCall{toolCall(
        "call_restricted_write",
        "write_file",
        "{\"path\":\"blocked.txt\",\"content\":\"must not execute\"}",
    )};
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &vision_calls },
        .{ .content = "{\"images\":[{\"image_id\":1,\"status\":\"ok\",\"summary\":\"FX logo\",\"visible_text\":[],\"details\":[]}]}" },
        .{ .tool_calls = &restricted_calls },
        .{ .content = "Final without mutation" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.tool_registry = .{ .tools = &.{ builtin_tools.vision, builtin_tools.write_file } };
    hooks.permission_decisions = &.{ .once, .permission_required };
    hooks.permission_feedback = &.{ "Do not modify any more files.", "" };
    defer hooks.deinit();
    var vision_runtime = VisionAgentToolRuntime{ .alloc = alloc };
    defer vision_runtime.deinit();
    hooks.execute_delegate = vision_runtime.delegate();
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.model = @constCast("zai/glm-5.2");
    job.prompt = @constCast("Make the requested changes.");
    job.images = &images;
    job.authorized_image_catalog = &images;
    job.permission_mode = .auto;

    try runFakePrompt(&gateway, &hooks, fixture.config(), job);

    try std.testing.expectEqual(@as(usize, 4), gateway.request_bodies.items.len);
    try std.testing.expectEqual(@as(usize, 2), hooks.permission_names.items.len);
    try std.testing.expectEqual(@as(usize, 1), hooks.executed_names.items.len);
    try std.testing.expectEqualStrings("vision", hooks.executed_names.items[0]);
    try std.testing.expectEqual(@as(usize, 0), hooks.permission_review_feedback_counts.items[1]);
    try std.testing.expect(std.mem.find(
        u8,
        hooks.permission_user_intent_contexts.items[1],
        "Do not modify any more files.",
    ) == null);
    try std.testing.expectEqual(@as(usize, 1), countNeedle(
        gateway.request_bodies.items[0],
        "<available_images>",
    ));
    try std.testing.expectEqual(@as(usize, 1), countNeedle(
        gateway.request_bodies.items[2],
        "<available_images>",
    ));
    try std.testing.expectEqual(@as(usize, 1), countNeedle(
        gateway.request_bodies.items[3],
        "<available_images>",
    ));
    try std.testing.expectEqual(@as(usize, 0), countNeedle(
        gateway.request_bodies.items[1],
        "<available_images>",
    ));
    const persisted = hooks.history_turns.items[0].assistant.execution.tool_steps[0].tool_results[0];
    try std.testing.expectEqual(@as(usize, 1), persisted.permission_feedback.len);
    try std.testing.expectEqualStrings(
        "Do not modify any more files.",
        persisted.permission_feedback[0],
    );
}

test "processQueuedPrompt settles mixed local results and recovers after one Vision attempt" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try writeTestImagePath(alloc, &tmp);
    defer alloc.free(image_path);
    var images = [_]types.ImageAttachment{
        try testCapturedImage(alloc, &tmp, image_path, 1),
        try testCapturedImage(alloc, &tmp, image_path, 2),
    };
    defer freeImageSlice(alloc, &images);
    {
        var corrupt = try std.Io.Dir.createFileAbsolute(
            std.testing.io,
            images[0].snapshot_path.?,
            .{ .truncate = true },
        );
        defer corrupt.close(std.testing.io);
        try corrupt.writeStreamingAll(std.testing.io, "\x89PNG\r\n\x1a\ncorrupt");
    }

    const calls = [_]ToolCall{toolCall(
        "call_vision_partial_local",
        "vision",
        "{\"image_ids\":[1,2],\"focus\":\"inspect both\"}",
    )};
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &calls },
        .{ .content = "{\"images\":[{\"image_id\":2,\"status\":\"ok\",\"summary\":\"healthy sibling\",\"visible_text\":[],\"details\":[]}]}" },
        .{ .content = "Final partial answer" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.tool_registry = .{ .tools = test_support.vision_agent_test_tools[0..] };
    defer hooks.deinit();
    var vision_runtime = VisionAgentToolRuntime{ .alloc = alloc };
    defer vision_runtime.deinit();
    hooks.execute_delegate = vision_runtime.delegate();
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.model = @constCast("zai/glm-5.2");
    job.images = &images;
    job.authorized_image_catalog = &images;

    try runFakePrompt(&gateway, &hooks, fixture.config(), job);

    try std.testing.expectEqual(@as(usize, 3), gateway.request_bodies.items.len);
    try std.testing.expectEqual(@as(usize, 1), countNeedle(gateway.request_bodies.items[1], "\"type\":\"file\""));
    try expectBodyContainsInOrder(
        &gateway,
        2,
        &.{ "image_id", "image_unavailable", "image_id", "healthy sibling" },
    );
    try expectBodyNotContains(&gateway, 2, "\"toolChoice\":{\"type\":\"required\"}");
    try std.testing.expectEqualStrings("Final partial answer", hooks.finish_assistant_text.?);
}

test "processQueuedPrompt delivers dense under-budget Vision evidence unchanged" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try writeTestImagePath(alloc, &tmp);
    defer alloc.free(image_path);
    var images = [_]types.ImageAttachment{
        try testCapturedImage(alloc, &tmp, image_path, 1),
        try testCapturedImage(alloc, &tmp, image_path, 2),
    };
    defer freeImageSlice(alloc, &images);

    const calls = [_]ToolCall{toolCall(
        "call_vision_dense_evidence",
        "vision",
        "{\"image_ids\":[1,2],\"focus\":\"inspect dense evidence\"}",
    )};
    const provider_result = try denseVisionProviderResult(alloc);
    defer alloc.free(provider_result);
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &calls },
        .{ .content = provider_result },
        .{ .content = "Final dense-evidence answer" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.tool_registry = .{ .tools = test_support.vision_agent_test_tools[0..] };
    defer hooks.deinit();
    var vision_runtime = VisionAgentToolRuntime{ .alloc = alloc };
    defer vision_runtime.deinit();
    hooks.execute_delegate = vision_runtime.delegate();
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.model = @constCast("zai/glm-5.2");
    job.images = &images;
    job.authorized_image_catalog = &images;

    try runFakePrompt(&gateway, &hooks, fixture.config(), job);

    try std.testing.expectEqual(@as(usize, 1), countVisionProviderCalls(&gateway));
    try std.testing.expectEqual(@as(usize, 1), hooks.history_turns.items.len);
    const persisted = hooks.history_turns.items[0].assistant.execution.tool_steps[0].tool_results[0];
    try std.testing.expectEqual(types.PersistedToolStatus.success, persisted.status);
    try std.testing.expectEqual(@as(usize, 40), std.mem.count(u8, persisted.output, "visible item "));
    try std.testing.expect(std.mem.find(u8, persisted.output, "x" ** 5000) != null);
    try expectGatewayToolResultOutput(&gateway, 2, "call_vision_dense_evidence", persisted.output);
    try expectBodyNotContains(&gateway, 2, image_path);
}

test "processQueuedPrompt preserves a provider omission as mixed success" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try writeTestImagePath(alloc, &tmp);
    defer alloc.free(image_path);
    var images = [_]types.ImageAttachment{
        try testCapturedImage(alloc, &tmp, image_path, 1),
        try testCapturedImage(alloc, &tmp, image_path, 2),
    };
    defer freeImageSlice(alloc, &images);

    const calls = [_]ToolCall{toolCall(
        "call_vision_provider_omission",
        "vision",
        "{\"image_ids\":[1,2],\"focus\":\"inspect both\"}",
    )};
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &calls },
        .{ .content = "{\"images\":[{\"image_id\":1,\"status\":\"ok\",\"summary\":\"retained evidence\",\"visible_text\":[],\"details\":[]}] }" },
        .{ .content = "Final omission answer" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.tool_registry = .{ .tools = test_support.vision_agent_test_tools[0..] };
    defer hooks.deinit();
    var vision_runtime = VisionAgentToolRuntime{ .alloc = alloc };
    defer vision_runtime.deinit();
    hooks.execute_delegate = vision_runtime.delegate();
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.model = @constCast("zai/glm-5.2");
    job.images = &images;
    job.authorized_image_catalog = &images;

    try runFakePrompt(&gateway, &hooks, fixture.config(), job);

    try std.testing.expectEqual(@as(usize, 1), countVisionProviderCalls(&gateway));
    const persisted = hooks.history_turns.items[0].assistant.execution.tool_steps[0].tool_results[0];
    try std.testing.expectEqual(types.PersistedToolStatus.success, persisted.status);
    try std.testing.expect(std.mem.find(u8, persisted.output, "retained evidence") != null);
    try std.testing.expect(std.mem.find(u8, persisted.output, "missing_provider_record") != null);
    try expectGatewayToolResultOutput(&gateway, 2, "call_vision_provider_omission", persisted.output);
    try expectBodyNotContains(&gateway, 2, "\"toolChoice\":{\"type\":\"required\"}");
}

fn deleteLocallyFilteredSnapshots(images: []const types.ImageAttachment) !void {
    for (images) |image| {
        try std.Io.Dir.deleteFileAbsolute(std.testing.io, image.snapshot_path.?);
    }
}

test "processQueuedPrompt serializes retained bytes after locally filtered paths are replaced" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try writeTestImagePath(alloc, &tmp);
    defer alloc.free(image_path);
    var images = [_]types.ImageAttachment{
        try testCapturedImage(alloc, &tmp, image_path, 1),
        try testCapturedImage(alloc, &tmp, image_path, 2),
    };
    defer freeImageSlice(alloc, &images);

    const calls = [_]ToolCall{toolCall(
        "call_vision_retained_bytes",
        "vision",
        "{\"image_ids\":[1,2],\"focus\":\"inspect both\"}",
    )};
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &calls },
        .{ .content = "{\"images\":[{\"image_id\":1,\"status\":\"ok\",\"summary\":\"first retained\",\"visible_text\":[],\"details\":[]},{\"image_id\":2,\"status\":\"ok\",\"summary\":\"second retained\",\"visible_text\":[],\"details\":[]}]}" },
        .{ .content = "Final retained-byte answer" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.tool_registry = .{ .tools = test_support.vision_agent_test_tools[0..] };
    defer hooks.deinit();
    var vision_runtime = VisionAgentToolRuntime{ .alloc = alloc };
    defer vision_runtime.deinit();
    hooks.execute_delegate = vision_runtime.delegate();
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.model = @constCast("zai/glm-5.2");
    job.images = &images;
    job.authorized_image_catalog = &images;

    vision_executor.TestHooks.after_local_filter = deleteLocallyFilteredSnapshots;
    defer vision_executor.TestHooks.after_local_filter = null;
    try runFakePrompt(&gateway, &hooks, fixture.config(), job);

    try std.testing.expectEqual(@as(usize, 3), gateway.request_bodies.items.len);
    try std.testing.expectEqual(
        @as(usize, 2),
        countNeedle(gateway.request_bodies.items[1], "\"type\":\"file\""),
    );
    try expectBodyContainsInOrder(
        &gateway,
        2,
        &.{ "first retained", "second retained" },
    );
}

test "required Vision rejects non-Vision before effects and stays required until Vision settles" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try writeTestImagePath(alloc, &tmp);
    defer alloc.free(image_path);
    const image = try testCapturedImage(alloc, &tmp, image_path, 1);
    defer types.freeImageAttachment(alloc, image);
    var images = [_]types.ImageAttachment{image};

    const wrapped_terminal_arguments =
        "{\"request\":{\"action\":\"exec\",\"command\":\"printf must-not-run\"}}";
    const blocked_calls = [_]ToolCall{toolCall(
        "call_terminal_while_vision_required",
        "terminal",
        wrapped_terminal_arguments,
    )};
    const vision_calls = [_]ToolCall{toolCall(
        "call_required_vision",
        "vision",
        "{\"image_ids\":[1],\"focus\":\"inspect\"}",
    )};
    const ordinary_calls = [_]ToolCall{toolCall(
        "call_read_after_vision",
        "read_file",
        "{\"path\":\"after-vision.txt\"}",
    )};
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &blocked_calls, .streamed_tool_starts = &blocked_calls },
        .{ .tool_calls = &vision_calls },
        .{
            .content = "{\"images\":[{\"image_id\":1,\"status\":\"ok\",\"summary\":\"required evidence\",\"visible_text\":[],\"details\":[]}]}",
        },
        .{ .tool_calls = &ordinary_calls },
        .{ .content = "Final after ordinary read" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.tool_registry = .{ .tools = vision_read_and_terminal_tools[0..] };
    defer hooks.deinit();
    var vision_runtime = VisionAgentToolRuntime{
        .alloc = alloc,
        .session_id = "session-vision-123",
    };
    defer vision_runtime.deinit();
    var executor = VisionAndReadExecutor{ .vision = vision_runtime.delegate() };
    hooks.execute_delegate = executor.delegate();
    var lifecycle_runtime = lifecycle_hooks.Runtime.init(alloc);
    defer lifecycle_runtime.deinit();
    var pre_tool = test_support.PreToolUseTestHandler{
        .alloc = alloc,
        .action = .continue_,
    };
    defer pre_tool.deinit();
    const lifecycle_view = try test_support.registerPreToolUseTestHandler(
        &lifecycle_runtime,
        &pre_tool,
    );
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.model = @constCast("zai/glm-5.2");
    job.images = &images;
    job.authorized_image_catalog = &images;
    job.permission_mode = .ask;

    var config = fixture.config();
    config.gateway_tools_json = terminal_nested_tools_json;
    var lifecycle = test_support.testLifecycleContext(
        lifecycle_view,
        alloc,
        config.workspace_root,
    );
    lifecycle.scope.session_id = "session-vision-123";
    try test_support.runFakePromptWithLifecycle(
        &gateway,
        &hooks,
        config,
        job,
        lifecycle,
    );

    try std.testing.expectEqual(@as(usize, 5), gateway.request_bodies.items.len);
    try std.testing.expectEqual(@as(usize, 5), gateway.request_session_ids.items.len);
    for (gateway.request_session_ids.items) |session_id| {
        try std.testing.expectEqualStrings("session-vision-123", session_id.?);
    }
    try expectBodyContains(&gateway, 0, "\"toolChoice\":{\"type\":\"required\"}");
    try expectBodyContains(&gateway, 1, "\"toolChoice\":{\"type\":\"required\"}");
    try expectBodyContains(&gateway, 1, "call_terminal_while_vision_required");
    try expectBodyContains(&gateway, 1, "Only Vision can be called while attached images are pending.");
    try expectBodyNotContains(&gateway, 3, "\"toolChoice\":{\"type\":\"required\"}");
    try expectBodyContains(&gateway, 2, "\"type\":\"file\"");
    try expectBodyContains(&gateway, 4, "ordinary read contents");

    try std.testing.expectEqual(@as(usize, 2), pre_tool.calls);
    try std.testing.expectEqualStrings(
        "{\"image_ids\":[1],\"focus\":\"inspect\"}",
        pre_tool.seen_arguments.items[0],
    );
    try std.testing.expectEqualStrings(
        "{\"path\":\"after-vision.txt\"}",
        pre_tool.seen_arguments.items[1],
    );
    try std.testing.expectEqual(@as(usize, 2), hooks.permission_names.items.len);
    try std.testing.expectEqualStrings("vision", hooks.permission_names.items[0]);
    try std.testing.expectEqualStrings("read_file", hooks.permission_names.items[1]);
    try std.testing.expectEqual(@as(usize, 2), hooks.executed_call_ids.items.len);
    try std.testing.expectEqualStrings("call_required_vision", hooks.executed_call_ids.items[0]);
    try std.testing.expectEqualStrings("call_read_after_vision", hooks.executed_call_ids.items[1]);
    try expectNoLifecycleForCall(
        hooks.lifecycle_events.items,
        "call_terminal_while_vision_required",
    );
    try std.testing.expectEqual(@as(usize, 1), hooks.rejected_names.items.len);
    try std.testing.expectEqualStrings("terminal", hooks.rejected_names.items[0]);
    try std.testing.expectEqual(@as(usize, 1), vision_runtime.execution_count);
    var persisted_arguments: ?[]const u8 = null;
    for (hooks.history_turns.items) |turn| {
        const assistant = switch (turn) {
            .assistant => |value| value,
            else => continue,
        };
        for (assistant.execution.tool_steps) |step| {
            for (step.tool_calls) |call| {
                if (std.mem.eql(u8, call.id, "call_terminal_while_vision_required")) {
                    persisted_arguments = call.arguments_json;
                }
            }
        }
    }
    try std.testing.expectEqualStrings(
        wrapped_terminal_arguments,
        persisted_arguments orelse return error.TestExpectedEqual,
    );
    try std.testing.expectEqualStrings("Final after ordinary read", hooks.finish_assistant_text.?);
}

test "required Vision mixed response executes Vision and rejects non-Vision sibling" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try writeTestImagePath(alloc, &tmp);
    defer alloc.free(image_path);
    const image = try testCapturedImage(alloc, &tmp, image_path, 1);
    defer types.freeImageAttachment(alloc, image);
    var images = [_]types.ImageAttachment{image};

    const mixed_calls = [_]ToolCall{
        toolCall(
            "call_mixed_vision",
            "vision",
            "{\"image_ids\":[1],\"focus\":\"inspect\"}",
        ),
        toolCall(
            "call_mixed_read_blocked",
            "read_file",
            "{\"path\":\"must-not-read-mixed.txt\"}",
        ),
    };
    const ordinary_calls = [_]ToolCall{toolCall(
        "call_mixed_read_after",
        "read_file",
        "{\"path\":\"after-mixed-vision.txt\"}",
    )};
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &mixed_calls, .streamed_tool_starts = &mixed_calls },
        .{
            .content = "{\"images\":[{\"image_id\":1,\"status\":\"ok\",\"summary\":\"mixed evidence\",\"visible_text\":[],\"details\":[]}]}",
        },
        .{ .tool_calls = &ordinary_calls },
        .{ .content = "Final mixed answer" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.tool_registry = .{ .tools = vision_and_read_file_tools[0..] };
    defer hooks.deinit();
    var vision_runtime = VisionAgentToolRuntime{ .alloc = alloc };
    defer vision_runtime.deinit();
    var executor = VisionAndReadExecutor{ .vision = vision_runtime.delegate() };
    hooks.execute_delegate = executor.delegate();
    var lifecycle_runtime = lifecycle_hooks.Runtime.init(alloc);
    defer lifecycle_runtime.deinit();
    var pre_tool = test_support.PreToolUseTestHandler{
        .alloc = alloc,
        .action = .continue_,
    };
    defer pre_tool.deinit();
    const lifecycle_view = try test_support.registerPreToolUseTestHandler(
        &lifecycle_runtime,
        &pre_tool,
    );
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.model = @constCast("zai/glm-5.2");
    job.images = &images;
    job.authorized_image_catalog = &images;
    job.permission_mode = .auto;

    const config = fixture.config();
    try test_support.runFakePromptWithLifecycle(
        &gateway,
        &hooks,
        config,
        job,
        test_support.testLifecycleContext(lifecycle_view, alloc, config.workspace_root),
    );

    try std.testing.expectEqual(@as(usize, 4), gateway.request_bodies.items.len);
    try expectBodyContains(&gateway, 0, "\"toolChoice\":{\"type\":\"required\"}");
    try expectBodyContains(&gateway, 2, "mixed evidence");
    try expectBodyContains(&gateway, 2, "Only Vision can be called while attached images are pending.");
    try expectBodyNotContains(&gateway, 2, "\"toolChoice\":{\"type\":\"required\"}");
    try expectBodyContains(&gateway, 3, "ordinary read contents");
    try std.testing.expectEqual(@as(usize, 2), hooks.executed_call_ids.items.len);
    try std.testing.expectEqualStrings("call_mixed_vision", hooks.executed_call_ids.items[0]);
    try std.testing.expectEqualStrings("call_mixed_read_after", hooks.executed_call_ids.items[1]);
    try expectNoLifecycleForCall(hooks.lifecycle_events.items, "call_mixed_read_blocked");
    try std.testing.expectEqual(@as(usize, 2), pre_tool.calls);
    try std.testing.expectEqual(@as(usize, 1), hooks.rejected_names.items.len);
    try std.testing.expectEqualStrings("read_file", hooks.rejected_names.items[0]);
    try std.testing.expectEqual(@as(usize, 1), vision_runtime.execution_count);
    try std.testing.expectEqualStrings("Final mixed answer", hooks.finish_assistant_text.?);
}

test "processQueuedPrompt batches twenty text-only images through Vision as 8 8 4" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try writeTestImagePath(alloc, &tmp);
    defer alloc.free(image_path);
    var images: [20]types.ImageAttachment = undefined;
    var initialized_images: usize = 0;
    defer freeImageSlice(alloc, images[0..initialized_images]);
    var image_ids: [20]usize = undefined;
    for (&images, &image_ids, 0..) |*image, *image_id, index| {
        const id = index + 1;
        image.* = try testCapturedImage(alloc, &tmp, image_path, id);
        initialized_images += 1;
        image_id.* = id;
    }
    const arguments = try visionArgumentsForIds(alloc, &image_ids);
    defer alloc.free(arguments);
    const first_batch = try visionProviderResultForIds(alloc, image_ids[0..8]);
    defer alloc.free(first_batch);
    const second_batch = try visionProviderResultForIds(alloc, image_ids[8..16]);
    defer alloc.free(second_batch);
    const third_batch = try visionProviderResultForIds(alloc, image_ids[16..20]);
    defer alloc.free(third_batch);
    const calls = [_]ToolCall{toolCall("call_vision_twenty", "vision", arguments)};
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &calls },
        .{ .content = first_batch },
        .{ .content = second_batch },
        .{ .content = third_batch },
        .{ .content = "Final twenty-image answer" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.tool_registry = .{ .tools = test_support.vision_agent_test_tools[0..] };
    defer hooks.deinit();
    var vision_runtime = VisionAgentToolRuntime{ .alloc = alloc };
    defer vision_runtime.deinit();
    hooks.execute_delegate = vision_runtime.delegate();
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.model = @constCast("zai/glm-5.2");
    job.prompt = @constCast("Inspect all attached images.");
    job.images = &images;
    job.authorized_image_catalog = &images;

    try runFakePrompt(&gateway, &hooks, fixture.config(), job);

    try std.testing.expectEqual(@as(usize, 5), gateway.request_bodies.items.len);
    try std.testing.expectEqual(@as(usize, 8), countNeedle(gateway.request_bodies.items[1], "\"type\":\"file\""));
    try std.testing.expectEqual(@as(usize, 8), countNeedle(gateway.request_bodies.items[2], "\"type\":\"file\""));
    try std.testing.expectEqual(@as(usize, 4), countNeedle(gateway.request_bodies.items[3], "\"type\":\"file\""));
    try expectBodyContains(&gateway, 0, "[Image #1]");
    try expectBodyContains(&gateway, 0, "[Image #20]");
    try expectBodyNotContains(&gateway, 0, image_path);
    try expectBodyContains(&gateway, 4, "image 20");
    try expectBodyNotContains(&gateway, 4, image_path);
}

test "processQueuedPrompt keeps corrupt twenty-image members inside their original batches" {
    const alloc = std.testing.allocator;
    const corrupt_indexes = [_]usize{ 0, 8, 16 };
    const expected_counts = [_][3]usize{
        .{ 7, 8, 4 },
        .{ 8, 7, 4 },
        .{ 8, 8, 3 },
    };

    for (corrupt_indexes, expected_counts) |corrupt_index, expected| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const image_path = try writeTestImagePath(alloc, &tmp);
        defer alloc.free(image_path);
        var images: [20]types.ImageAttachment = undefined;
        var initialized_images: usize = 0;
        defer freeImageSlice(alloc, images[0..initialized_images]);
        var image_ids: [20]usize = undefined;
        for (&images, &image_ids, 0..) |*image, *image_id, index| {
            const id = index + 1;
            image.* = try testCapturedImage(alloc, &tmp, image_path, id);
            initialized_images += 1;
            image_id.* = id;
        }
        {
            var corrupt = try std.Io.Dir.createFileAbsolute(
                std.testing.io,
                images[corrupt_index].snapshot_path.?,
                .{ .truncate = true },
            );
            defer corrupt.close(std.testing.io);
            try corrupt.writeStreamingAll(std.testing.io, "\x89PNG\r\n\x1a\ncorrupt");
        }

        const arguments = try visionArgumentsForIds(alloc, &image_ids);
        defer alloc.free(arguments);
        var first_ids: [8]usize = undefined;
        var first_len: usize = 0;
        var second_ids: [8]usize = undefined;
        var second_len: usize = 0;
        var third_ids: [4]usize = undefined;
        var third_len: usize = 0;
        for (image_ids, 0..) |image_id, index| {
            if (index == corrupt_index) continue;
            if (index < 8) {
                first_ids[first_len] = image_id;
                first_len += 1;
            } else if (index < 16) {
                second_ids[second_len] = image_id;
                second_len += 1;
            } else {
                third_ids[third_len] = image_id;
                third_len += 1;
            }
        }
        const first_batch = try visionProviderResultForIds(alloc, first_ids[0..first_len]);
        defer alloc.free(first_batch);
        const second_batch = try visionProviderResultForIds(alloc, second_ids[0..second_len]);
        defer alloc.free(second_batch);
        const third_batch = try visionProviderResultForIds(alloc, third_ids[0..third_len]);
        defer alloc.free(third_batch);
        const calls = [_]ToolCall{toolCall("call_vision_twenty_partial", "vision", arguments)};
        const completions = [_]FakeCompletion{
            .{ .tool_calls = &calls },
            .{ .content = first_batch },
            .{ .content = second_batch },
            .{ .content = third_batch },
            .{ .content = "Final partial twenty-image answer" },
        };
        var gateway = FakeGateway.init(alloc, &completions);
        defer gateway.deinit();
        var hooks = FakeAgentRuntimeDeps.init(alloc);
        hooks.tool_registry = .{ .tools = test_support.vision_agent_test_tools[0..] };
        defer hooks.deinit();
        var vision_runtime = VisionAgentToolRuntime{ .alloc = alloc };
        defer vision_runtime.deinit();
        hooks.execute_delegate = vision_runtime.delegate();
        var fixture = PromptFixture{};
        var job = fixture.job();
        job.model = @constCast("zai/glm-5.2");
        job.images = &images;
        job.authorized_image_catalog = &images;

        try runFakePrompt(&gateway, &hooks, fixture.config(), job);
        try std.testing.expectEqual(@as(usize, 5), gateway.request_bodies.items.len);
        try std.testing.expectEqual(expected[0], countNeedle(gateway.request_bodies.items[1], "\"type\":\"file\""));
        try std.testing.expectEqual(expected[1], countNeedle(gateway.request_bodies.items[2], "\"type\":\"file\""));
        try std.testing.expectEqual(expected[2], countNeedle(gateway.request_bodies.items[3], "\"type\":\"file\""));
        var invalid_marker: [32]u8 = undefined;
        const marker = try std.fmt.bufPrint(
            &invalid_marker,
            "image_id={d}",
            .{corrupt_index + 1},
        );
        try expectBodyNotContains(&gateway, 1 + corrupt_index / 8, marker);
        try expectBodyContainsInOrder(
            &gateway,
            4,
            &.{ "image_id", "image_unavailable", "image 20" },
        );
        try expectBodyNotContains(&gateway, 4, "\"toolChoice\":{\"type\":\"required\"}");
        try std.testing.expectEqualStrings(
            "Final partial twenty-image answer",
            hooks.finish_assistant_text.?,
        );
    }
}

test "processQueuedPrompt filters one missing image from an eight-image batch" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try writeTestImagePath(alloc, &tmp);
    defer alloc.free(image_path);
    var images: [8]types.ImageAttachment = undefined;
    var initialized_images: usize = 0;
    defer freeImageSlice(alloc, images[0..initialized_images]);
    var image_ids: [8]usize = undefined;
    for (&images, &image_ids, 0..) |*image, *image_id, index| {
        image.* = try testCapturedImage(alloc, &tmp, image_path, index + 1);
        initialized_images += 1;
        image_id.* = index + 1;
    }
    try std.Io.Dir.deleteFileAbsolute(std.testing.io, images[0].snapshot_path.?);
    const arguments = try visionArgumentsForIds(alloc, &image_ids);
    defer alloc.free(arguments);
    const provider = try visionProviderResultForIds(alloc, image_ids[1..]);
    defer alloc.free(provider);
    const calls = [_]ToolCall{toolCall("call_vision_missing", "vision", arguments)};
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &calls },
        .{ .content = provider },
        .{ .content = "Final missing-image answer" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.tool_registry = .{ .tools = test_support.vision_agent_test_tools[0..] };
    defer hooks.deinit();
    var vision_runtime = VisionAgentToolRuntime{ .alloc = alloc };
    defer vision_runtime.deinit();
    hooks.execute_delegate = vision_runtime.delegate();
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.model = @constCast("zai/glm-5.2");
    job.images = &images;
    job.authorized_image_catalog = &images;

    try runFakePrompt(&gateway, &hooks, fixture.config(), job);
    try std.testing.expectEqual(@as(usize, 7), countNeedle(gateway.request_bodies.items[1], "\"type\":\"file\""));
    try expectBodyContainsInOrder(
        &gateway,
        2,
        &.{ "image_id", "image_unavailable", "image 8" },
    );
    try expectBodyNotContains(&gateway, 2, "\"toolChoice\":{\"type\":\"required\"}");
    try std.testing.expectEqualStrings("Final missing-image answer", hooks.finish_assistant_text.?);
}

test "processQueuedPrompt skips an entirely invalid local Vision batch" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try writeTestImagePath(alloc, &tmp);
    defer alloc.free(image_path);
    var images: [8]types.ImageAttachment = undefined;
    var initialized_images: usize = 0;
    defer freeImageSlice(alloc, images[0..initialized_images]);
    var image_ids: [8]usize = undefined;
    for (&images, &image_ids, 0..) |*image, *image_id, index| {
        image.* = try testCapturedImage(alloc, &tmp, image_path, index + 1);
        initialized_images += 1;
        image_id.* = index + 1;
        try std.Io.Dir.deleteFileAbsolute(std.testing.io, image.snapshot_path.?);
    }
    const arguments = try visionArgumentsForIds(alloc, &image_ids);
    defer alloc.free(arguments);
    const calls = [_]ToolCall{toolCall("call_vision_invalid_batch", "vision", arguments)};
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &calls },
        .{ .content = "Final invalid-batch answer" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.tool_registry = .{ .tools = test_support.vision_agent_test_tools[0..] };
    defer hooks.deinit();
    var vision_runtime = VisionAgentToolRuntime{ .alloc = alloc };
    defer vision_runtime.deinit();
    hooks.execute_delegate = vision_runtime.delegate();
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.model = @constCast("zai/glm-5.2");
    job.images = &images;
    job.authorized_image_catalog = &images;

    try runFakePrompt(&gateway, &hooks, fixture.config(), job);
    try std.testing.expectEqual(@as(usize, 2), gateway.request_bodies.items.len);
    try std.testing.expectEqualStrings("zai/glm-5.2", gateway.request_models.items[0]);
    try std.testing.expectEqualStrings("zai/glm-5.2", gateway.request_models.items[1]);
    try std.testing.expectEqual(@as(usize, 8), countNeedle(gateway.request_bodies.items[1], "image_unavailable"));
    try expectBodyNotContains(&gateway, 1, "\"toolChoice\":{\"type\":\"required\"}");
    try std.testing.expectEqualStrings("Final invalid-batch answer", hooks.finish_assistant_text.?);
}

test "processQueuedPrompt preserves local failures when the filtered provider batch fails" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try writeTestImagePath(alloc, &tmp);
    defer alloc.free(image_path);
    var images = [_]types.ImageAttachment{
        try testCapturedImage(alloc, &tmp, image_path, 1),
        try testCapturedImage(alloc, &tmp, image_path, 2),
    };
    defer freeImageSlice(alloc, &images);
    try std.Io.Dir.deleteFileAbsolute(std.testing.io, images[0].snapshot_path.?);
    const calls = [_]ToolCall{toolCall(
        "call_vision_filtered_outage",
        "vision",
        "{\"image_ids\":[1,2],\"focus\":\"inspect\"}",
    )};
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &calls },
        .{ .status = .service_unavailable },
        .{ .content = "Final filtered-outage answer" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.tool_registry = .{ .tools = test_support.vision_agent_test_tools[0..] };
    hooks.enable_interactive_notices = true;
    defer hooks.deinit();
    var vision_runtime = VisionAgentToolRuntime{ .alloc = alloc };
    defer vision_runtime.deinit();
    hooks.execute_delegate = vision_runtime.delegate();
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.model = @constCast("zai/glm-5.2");
    job.images = &images;
    job.authorized_image_catalog = &images;

    try runFakePrompt(&gateway, &hooks, fixture.config(), job);
    try std.testing.expectEqual(@as(usize, 1), countNeedle(gateway.request_bodies.items[1], "\"type\":\"file\""));
    try expectBodyContainsInOrder(
        &gateway,
        2,
        &.{ "image_unavailable", "vision_unavailable" },
    );
    try std.testing.expectEqual(@as(usize, 0), hooks.interactive_notices.items.len);
    try expectBodyNotContains(&gateway, 2, "\"toolChoice\":{\"type\":\"required\"}");
    try std.testing.expectEqualStrings("Final filtered-outage answer", hooks.finish_assistant_text.?);
}

test "processQueuedPrompt advertises historical Vision access without requiring it" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try writeTestImagePath(alloc, &tmp);
    defer alloc.free(image_path);
    const image = try testCapturedImage(alloc, &tmp, image_path, 7);
    defer types.freeImageAttachment(alloc, image);
    var catalog = [_]types.ImageAttachment{image};
    const completions = [_]FakeCompletion{.{ .content = "Historical answer" }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.tool_registry = .{ .tools = test_support.vision_agent_test_tools[0..] };
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.first_call_tool_choice = .none;
    var job = fixture.job();
    job.model = @constCast("zai/glm-5.2");
    job.prompt = @constCast("Use prior image context if useful.");
    job.authorized_image_catalog = &catalog;

    try runFakePrompt(&gateway, &hooks, config, job);

    try expectBodyContains(&gateway, 0, "\"name\":\"vision\"");
    try expectBodyContains(&gateway, 0, "\"toolChoice\":{\"type\":\"none\"}");
    try expectBodyContains(&gateway, 0, "[Image #7]");
    try expectBodyNotContains(&gateway, 0, "\"type\":\"file\"");
    try expectBodyNotContains(&gateway, 0, image_path);
}

test "processQueuedPrompt preserves configured first choice for first unrestricted request after Vision gate" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try writeTestImagePath(alloc, &tmp);
    defer alloc.free(image_path);
    const image = try testCapturedImage(alloc, &tmp, image_path, 1);
    defer types.freeImageAttachment(alloc, image);
    var images = [_]types.ImageAttachment{image};

    const calls = [_]ToolCall{toolCall("call_vision", "vision", "{\"image_ids\":[1],\"focus\":\"inspect\"}")};
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &calls },
        .{
            .content = "{\"images\":[{\"image_id\":1,\"status\":\"ok\",\"summary\":\"FX logo\",\"visible_text\":[],\"details\":[]}]}",
        },
        .{ .content = "Final selected-model answer" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.tool_registry = .{ .tools = test_support.vision_agent_test_tools[0..] };
    defer hooks.deinit();
    var vision_runtime = VisionAgentToolRuntime{ .alloc = alloc };
    defer vision_runtime.deinit();
    hooks.execute_delegate = vision_runtime.delegate();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.fast_mode = true;
    config.first_call_tool_choice = .none;
    var job = fixture.job();
    job.model = @constCast("zai/glm-5.2");
    job.prompt = @constCast("Describe the attached image.");
    job.images = &images;
    job.authorized_image_catalog = &images;

    try runFakePrompt(&gateway, &hooks, config, job);

    try std.testing.expectEqual(@as(usize, 1), hooks.capability_queries.items.len);
    try std.testing.expectEqual(@as(usize, 3), gateway.request_models.items.len);
    try std.testing.expectEqualStrings("zai/glm-5.2", gateway.request_models.items[0]);
    try std.testing.expectEqualStrings("google/gemini-2.5-flash", gateway.request_models.items[1]);
    try std.testing.expectEqualStrings("zai/glm-5.2", gateway.request_models.items[2]);
    try expectBodyContains(&gateway, 0, "\"toolChoice\":{\"type\":\"required\"}");
    try expectBodyContains(&gateway, 2, "\"toolChoice\":{\"type\":\"none\"}");
    try expectBodyContains(&gateway, 2, "FX logo");
    try expectBodyNotContains(&gateway, 0, image_path);
    try expectBodyNotContains(&gateway, 2, image_path);
    try std.testing.expectEqualStrings("Final selected-model answer", hooks.finish_assistant_text.?);
}

test "processQueuedPrompt keeps unauthorized Vision calls gated" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try writeTestImagePath(alloc, &tmp);
    defer alloc.free(image_path);
    const image = try testCapturedImage(alloc, &tmp, image_path, 1);
    defer types.freeImageAttachment(alloc, image);
    var images = [_]types.ImageAttachment{image};
    const unauthorized_calls = [_]ToolCall{toolCall(
        "call_vision_unauthorized",
        "vision",
        "{\"image_ids\":[2],\"focus\":\"inspect\"}",
    )};
    const valid_calls = [_]ToolCall{toolCall(
        "call_vision_valid",
        "vision",
        "{\"image_ids\":[1],\"focus\":\"inspect\"}",
    )};
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &unauthorized_calls },
        .{ .tool_calls = &valid_calls },
        .{
            .content = "{\"images\":[{\"image_id\":1,\"status\":\"ok\",\"summary\":\"valid\",\"visible_text\":[],\"details\":[]}]}",
        },
        .{ .content = "Final" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.tool_registry = .{ .tools = test_support.vision_agent_test_tools[0..] };
    defer hooks.deinit();
    var vision_runtime = VisionAgentToolRuntime{ .alloc = alloc };
    defer vision_runtime.deinit();
    hooks.execute_delegate = vision_runtime.delegate();
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.model = @constCast("zai/glm-5.2");
    job.images = &images;
    job.authorized_image_catalog = &images;
    job.permission_mode = .auto;

    try runFakePrompt(&gateway, &hooks, fixture.config(), job);

    try std.testing.expectEqual(@as(usize, 4), gateway.request_bodies.items.len);
    try expectBodyContains(&gateway, 0, "\"toolChoice\":{\"type\":\"required\"}");
    try expectBodyContains(&gateway, 1, "\"toolChoice\":{\"type\":\"required\"}");
    try std.testing.expectEqualStrings("zai/glm-5.2", gateway.request_models.items[0]);
    try std.testing.expectEqualStrings("zai/glm-5.2", gateway.request_models.items[1]);
    try std.testing.expectEqualStrings("google/gemini-2.5-flash", gateway.request_models.items[2]);
    try expectBodyContains(&gateway, 3, "valid");
}

test "processQueuedPrompt rereads historical authorized image through optional Vision" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try writeTestImagePath(alloc, &tmp);
    defer alloc.free(image_path);
    const history_image = try testCapturedImage(alloc, &tmp, image_path, 7);
    defer types.freeImageAttachment(alloc, history_image);
    var history_images = [_]types.ImageAttachment{history_image};
    var history = [_]HistoryTurn{.{ .assistant = .{
        .user = .{
            .text = @constCast("Previous image prompt."),
            .images = &history_images,
        },
        .assistant = @constCast("Previous answer."),
    } }};

    const calls = [_]ToolCall{toolCall("call_vision_history", "vision", "{\"image_ids\":[7],\"focus\":\"reread historical text\"}")};
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &calls },
        .{
            .content = "{\"images\":[{\"image_id\":7,\"status\":\"ok\",\"summary\":\"historical FX logo\",\"visible_text\":[\"HISTORICAL FX LOGO\"],\"details\":[]}]}",
        },
        .{ .content = "Final selected-model answer" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.tool_registry = .{ .tools = test_support.vision_agent_test_tools[0..] };
    defer hooks.deinit();
    var vision_runtime = VisionAgentToolRuntime{ .alloc = alloc };
    defer vision_runtime.deinit();
    hooks.execute_delegate = vision_runtime.delegate();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.fast_mode = true;
    var job = fixture.job();
    job.model = @constCast("zai/glm-5.2");
    job.prompt = @constCast("Use the prior image and read a file.");
    job.history = history[0..];
    job.authorized_image_catalog = &history_images;

    try runFakePrompt(&gateway, &hooks, config, job);

    try std.testing.expectEqual(@as(usize, 1), hooks.capability_queries.items.len);
    try std.testing.expectEqual(@as(usize, 3), gateway.request_models.items.len);
    try std.testing.expectEqualStrings("zai/glm-5.2", gateway.request_models.items[0]);
    try std.testing.expectEqualStrings("google/gemini-2.5-flash", gateway.request_models.items[1]);
    try std.testing.expectEqualStrings("zai/glm-5.2", gateway.request_models.items[2]);
    try expectBodyContains(&gateway, 0, "\"name\":\"vision\"");
    try expectBodyContains(&gateway, 0, "[Image #7]");
    try expectBodyContains(&gateway, 2, "HISTORICAL FX LOGO");
    try expectBodyNotContains(&gateway, 0, "\"type\":\"file\"");
    try expectBodyNotContains(&gateway, 0, image_path);
    try expectBodyNotContains(&gateway, 2, image_path);
    try std.testing.expectEqualStrings("Final selected-model answer", hooks.finish_assistant_text.?);
}

test "processQueuedPrompt keeps required Vision gate cancellation neutral" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try writeTestImagePath(alloc, &tmp);
    defer alloc.free(image_path);
    const image = try testCapturedImage(alloc, &tmp, image_path, 1);
    defer types.freeImageAttachment(alloc, image);
    var images = [_]types.ImageAttachment{image};

    const completions = [_]FakeCompletion{.{
        .cancel_before_output = true,
    }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.tool_registry = .{ .tools = test_support.vision_agent_test_tools[0..] };
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.fast_mode = true;
    var job = fixture.job();
    job.model = @constCast("zai/glm-5.2");
    job.prompt = @constCast("Describe the attached image.");
    job.images = &images;
    job.authorized_image_catalog = &images;

    try runFakePrompt(&gateway, &hooks, config, job);

    try std.testing.expect(fixture.cancel_flag.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), hooks.system_notices.items.len);
    try std.testing.expectEqual(@as(usize, 1), gateway.request_models.items.len);
    try std.testing.expectEqualStrings("zai/glm-5.2", gateway.request_models.items[0]);
    try expectBodyContains(&gateway, 0, "\"toolChoice\":{\"type\":\"required\"}");
    try expectBodyNotContains(&gateway, 0, image_path);
    try std.testing.expectEqual(@as(usize, 1), hooks.interrupted_history_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.finalization_count);
    try std.testing.expectEqual(types.TurnPresentationOutcome.interrupted, hooks.finalized_outcome.?);
}

test "processQueuedPrompt reports exact Vision outage tip and permits normal recovery" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try writeTestImagePath(alloc, &tmp);
    defer alloc.free(image_path);
    const image = try testCapturedImage(alloc, &tmp, image_path, 1);
    defer types.freeImageAttachment(alloc, image);
    var images = [_]types.ImageAttachment{image};

    const calls = [_]ToolCall{toolCall("call_vision_outage", "vision", "{\"image_ids\":[1],\"focus\":\"inspect\"}")};
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &calls },
        .{ .status = .bad_gateway, .err_body = "vision unavailable" },
        .{ .content = "I could not inspect the image." },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.tool_registry = .{ .tools = test_support.vision_agent_test_tools[0..] };
    hooks.enable_interactive_notices = true;
    defer hooks.deinit();
    var vision_runtime = VisionAgentToolRuntime{ .alloc = alloc };
    defer vision_runtime.deinit();
    hooks.execute_delegate = vision_runtime.delegate();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.fast_mode = true;
    var job = fixture.job();
    job.model = @constCast("zai/glm-5.2");
    job.prompt = @constCast("Describe the attached image.");
    job.images = &images;
    job.authorized_image_catalog = &images;

    try runFakePrompt(&gateway, &hooks, config, job);
    try std.testing.expectEqual(@as(usize, 1), hooks.capability_queries.items.len);
    try std.testing.expectEqualStrings("zai/glm-5.2", hooks.capability_queries.items[0]);
    try std.testing.expectEqual(@as(usize, 3), gateway.request_models.items.len);
    try std.testing.expectEqualStrings("zai/glm-5.2", gateway.request_models.items[0]);
    try std.testing.expectEqualStrings("google/gemini-2.5-flash", gateway.request_models.items[1]);
    try std.testing.expectEqual(@as(usize, 1), hooks.interactive_notices.items.len);
    try std.testing.expectEqualStrings(
        "Tip: This model doesn’t support OCR, and Vision is unavailable right now. Try switching to a vision-capable model.",
        hooks.interactive_notices.items[0].body,
    );
    try expectBodyContains(&gateway, 2, "None of the requested images were read");
    try expectBodyNotContains(&gateway, 2, image_path);
    try expectBodyNotContains(&gateway, 2, "\"toolChoice\":{\"type\":\"required\"}");
    try std.testing.expectEqualStrings(
        "I could not inspect the image.",
        hooks.finish_assistant_text.?,
    );
}

test "processQueuedPrompt classifies empty successful Vision provider response as invalid" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try writeTestImagePath(alloc, &tmp);
    defer alloc.free(image_path);
    const image = try testCapturedImage(alloc, &tmp, image_path, 1);
    defer types.freeImageAttachment(alloc, image);
    var images = [_]types.ImageAttachment{image};

    const calls = [_]ToolCall{toolCall("call_vision_empty", "vision", "{\"image_ids\":[1],\"focus\":\"inspect\"}")};
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &calls },
        .{ .content = "{\"images\":[]}" },
        .{ .content = "{\"images\":[]}" },
        .{ .content = "I handled the invalid Vision result." },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.tool_registry = .{ .tools = test_support.vision_agent_test_tools[0..] };
    hooks.enable_interactive_notices = true;
    defer hooks.deinit();
    var vision_runtime = VisionAgentToolRuntime{ .alloc = alloc };
    defer vision_runtime.deinit();
    hooks.execute_delegate = vision_runtime.delegate();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.fast_mode = true;
    var job = fixture.job();
    job.model = @constCast("zai/glm-5.2");
    job.prompt = @constCast("Describe the attached image.");
    job.images = &images;
    job.authorized_image_catalog = &images;

    try runFakePrompt(&gateway, &hooks, config, job);
    try std.testing.expectEqual(@as(usize, 4), gateway.request_models.items.len);
    try std.testing.expectEqual(@as(usize, 2), countVisionProviderCalls(&gateway));
    try std.testing.expectEqual(@as(usize, 0), hooks.interactive_notices.items.len);
    try expectBodyContains(&gateway, 3, "provider_response_invalid");
    try expectBodyNotContains(&gateway, 3, "Vision is unavailable right now");
    try expectBodyNotContains(&gateway, 3, "None of the requested images were read");
    try expectBodyNotContains(&gateway, 3, image_path);
    try expectBodyNotContains(&gateway, 3, "\"toolChoice\":{\"type\":\"required\"}");
    try std.testing.expectEqualStrings(
        "I handled the invalid Vision result.",
        hooks.finish_assistant_text.?,
    );
}

test "processQueuedPrompt recovers from Vision capacity failure with a narrower request" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try writeTestImagePath(alloc, &tmp);
    defer alloc.free(image_path);
    var images = [_]types.ImageAttachment{
        try testCapturedImage(alloc, &tmp, image_path, 1),
        try testCapturedImage(alloc, &tmp, image_path, 2),
    };
    defer freeImageSlice(alloc, &images);

    const broad_calls = [_]ToolCall{toolCall(
        "call_vision_broad",
        "vision",
        "{\"image_ids\":[1,2],\"focus\":\"inspect the broad scene\"}",
    )};
    const narrow_calls = [_]ToolCall{toolCall(
        "call_vision_narrow",
        "vision",
        "{\"image_ids\":[1],\"focus\":\"read only the status label\"}",
    )};
    const oversized = try oversizedVisionProviderResult(alloc, 70 * 1024);
    defer alloc.free(oversized);
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &broad_calls },
        .{ .content = oversized },
        .{ .tool_calls = &narrow_calls },
        .{ .content = "{\"images\":[{\"image_id\":1,\"status\":\"ok\",\"summary\":\"narrow validated evidence\",\"visible_text\":[\"READY\"],\"details\":[]}] }" },
        .{ .content = "The later validated evidence shows READY." },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.tool_registry = .{ .tools = test_support.vision_agent_test_tools[0..] };
    defer hooks.deinit();
    var vision_runtime = VisionAgentToolRuntime{ .alloc = alloc };
    defer vision_runtime.deinit();
    hooks.execute_delegate = vision_runtime.delegate();
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.model = @constCast("zai/glm-5.2");
    job.images = &images;
    job.authorized_image_catalog = &images;

    try runFakePrompt(&gateway, &hooks, fixture.config(), job);

    try std.testing.expectEqual(@as(usize, 5), gateway.request_bodies.items.len);
    try std.testing.expectEqual(@as(usize, 2), countVisionProviderCalls(&gateway));
    try std.testing.expectEqualStrings("zai/glm-5.2", gateway.request_models.items[0]);
    try std.testing.expectEqualStrings("google/gemini-2.5-flash", gateway.request_models.items[1]);
    try std.testing.expectEqualStrings("zai/glm-5.2", gateway.request_models.items[2]);
    try std.testing.expectEqualStrings("google/gemini-2.5-flash", gateway.request_models.items[3]);
    try std.testing.expectEqualStrings("zai/glm-5.2", gateway.request_models.items[4]);
    try std.testing.expectEqual(@as(usize, 2), countNeedle(gateway.request_bodies.items[1], "\"type\":\"file\""));
    try std.testing.expectEqual(@as(usize, 1), countNeedle(gateway.request_bodies.items[3], "\"type\":\"file\""));
    try expectBodyContains(&gateway, 2, "output_limit_exceeded");
    try expectBodyContains(&gateway, 2, "narrower focus or fewer images");
    try expectBodyNotContains(&gateway, 2, "a" ** 1024);
    try expectBodyContains(&gateway, 4, "narrow validated evidence");
    try expectBodyContains(&gateway, 4, "READY");
    try expectBodyNotContains(&gateway, 4, "a" ** 1024);
    const execution = hooks.history_turns.items[0].assistant.execution;
    try std.testing.expectEqual(@as(usize, 2), execution.tool_steps.len);
    try std.testing.expectEqual(types.PersistedToolStatus.failure, execution.tool_steps[0].tool_results[0].status);
    try std.testing.expect(std.mem.find(u8, execution.tool_steps[0].tool_results[0].output, "output_limit_exceeded") != null);
    try std.testing.expectEqual(types.PersistedToolStatus.success, execution.tool_steps[1].tool_results[0].status);
    try std.testing.expect(std.mem.find(u8, execution.tool_steps[1].tool_results[0].output, "narrow validated evidence") != null);
    try std.testing.expectEqualStrings("The later validated evidence shows READY.", hooks.finish_assistant_text.?);
}

const scripted_vision_args = "{\"image_ids\":[1],\"focus\":\"inspect\"}";
const scripted_vision_ok =
    "{\"images\":[{\"image_id\":1,\"status\":\"ok\",\"summary\":\"retried evidence\"," ++
    "\"visible_text\":[],\"details\":[]}]}";

fn scriptedVisionCatalog(
    alloc: Allocator,
    tmp: *std.testing.TmpDir,
    image_path: []const u8,
) !types.ImageAttachment {
    return testCapturedImage(alloc, tmp, image_path, 1);
}

test "vision retries one malformed provider response and returns the retried evidence" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try writeTestImagePath(alloc, &tmp);
    defer alloc.free(image_path);
    const image = try scriptedVisionCatalog(alloc, &tmp, image_path);
    defer types.freeImageAttachment(alloc, image);
    const catalog = [_]types.ImageAttachment{image};

    const responses = [_]VisionProviderScript.Response{
        .{ .content = "not json at all" },
        .{ .content = scripted_vision_ok },
    };
    var script = VisionProviderScript{ .responses = &responses };
    const result = try runScriptedVision(alloc, &script, &catalog, scripted_vision_args, 64 * 1024);
    defer alloc.free(result.model_output);

    try std.testing.expectEqual(@as(usize, 2), script.calls);
    try std.testing.expectEqual(runtime_tool_contracts.ToolExecutionStatus.success, result.status);
    try std.testing.expect(std.mem.find(u8, result.model_output, "retried evidence") != null);
    try std.testing.expect(std.mem.find(u8, result.model_output, "provider_response_invalid") == null);
    try std.testing.expect(result.status_detail == null);
    try std.testing.expect(result.system_notice == null);
    try std.testing.expect(result.interactive_notice == null);
}

test "vision retries a malformed provider response at most once" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try writeTestImagePath(alloc, &tmp);
    defer alloc.free(image_path);
    const image = try scriptedVisionCatalog(alloc, &tmp, image_path);
    defer types.freeImageAttachment(alloc, image);
    const catalog = [_]types.ImageAttachment{image};

    const responses = [_]VisionProviderScript.Response{
        .{ .content = "not json at all" },
        .{ .content = "still not json" },
    };
    var script = VisionProviderScript{ .responses = &responses };
    const result = try runScriptedVision(alloc, &script, &catalog, scripted_vision_args, 64 * 1024);
    defer alloc.free(result.model_output);

    try std.testing.expectEqual(@as(usize, 2), script.calls);
    try std.testing.expectEqual(runtime_tool_contracts.ToolExecutionStatus.failure, result.status);
    try std.testing.expect(std.mem.find(u8, result.model_output, "provider_response_invalid") != null);
    try std.testing.expect(std.mem.find(u8, result.model_output, "Try a later explicit Vision call") != null);
    try std.testing.expectEqualStrings("provider response stayed invalid after one retry", result.status_detail.?);
    try std.testing.expect(result.system_notice == null);
    try std.testing.expect(result.interactive_notice == null);
}

test "vision retries a structurally unauthorized provider batch exactly once" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try writeTestImagePath(alloc, &tmp);
    defer alloc.free(image_path);
    const image = try scriptedVisionCatalog(alloc, &tmp, image_path);
    defer types.freeImageAttachment(alloc, image);
    const catalog = [_]types.ImageAttachment{image};

    const foreign_record =
        "{\"images\":[{\"image_id\":2,\"status\":\"ok\",\"summary\":\"other image\"," ++
        "\"visible_text\":[],\"details\":[]}]}";
    const responses = [_]VisionProviderScript.Response{
        .{ .content = foreign_record },
        .{ .content = scripted_vision_ok },
    };
    var script = VisionProviderScript{ .responses = &responses };
    const result = try runScriptedVision(alloc, &script, &catalog, scripted_vision_args, 64 * 1024);
    defer alloc.free(result.model_output);

    try std.testing.expectEqual(@as(usize, 2), script.calls);
    try std.testing.expect(std.mem.find(u8, result.model_output, "retried evidence") != null);
    try std.testing.expect(std.mem.find(u8, result.model_output, "other image") == null);
}

test "vision does not retry a valid provider response reporting per-image failure" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try writeTestImagePath(alloc, &tmp);
    defer alloc.free(image_path);
    const image = try scriptedVisionCatalog(alloc, &tmp, image_path);
    defer types.freeImageAttachment(alloc, image);
    const catalog = [_]types.ImageAttachment{image};

    const failure_record =
        "{\"images\":[{\"image_id\":1,\"status\":\"failed\"," ++
        "\"error\":\"vision_unavailable\"}]}";
    const responses = [_]VisionProviderScript.Response{
        .{ .content = failure_record },
        .{ .content = scripted_vision_ok },
    };
    var script = VisionProviderScript{ .responses = &responses };
    const result = try runScriptedVision(alloc, &script, &catalog, scripted_vision_args, 64 * 1024);
    defer alloc.free(result.model_output);

    try std.testing.expectEqual(@as(usize, 1), script.calls);
    try std.testing.expectEqual(runtime_tool_contracts.ToolExecutionStatus.failure, result.status);
    try std.testing.expect(std.mem.find(u8, result.model_output, "vision_unavailable") != null);
    try std.testing.expect(std.mem.find(u8, result.model_output, "retried evidence") == null);
    try std.testing.expectEqualStrings("Vision is unavailable right now", result.status_detail.?);
}

test "vision does not retry a provider outage" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try writeTestImagePath(alloc, &tmp);
    defer alloc.free(image_path);
    const image = try scriptedVisionCatalog(alloc, &tmp, image_path);
    defer types.freeImageAttachment(alloc, image);
    const catalog = [_]types.ImageAttachment{image};

    const responses = [_]VisionProviderScript.Response{
        .{ .http_status = .bad_gateway },
        .{ .content = scripted_vision_ok },
    };
    var script = VisionProviderScript{ .responses = &responses };
    const result = try runScriptedVision(alloc, &script, &catalog, scripted_vision_args, 64 * 1024);
    defer alloc.free(result.model_output);

    try std.testing.expectEqual(@as(usize, 1), script.calls);
    try std.testing.expect(std.mem.find(u8, result.model_output, "vision_unavailable") != null);
    try std.testing.expectEqualStrings("Vision is unavailable right now", result.status_detail.?);
    try std.testing.expectEqualStrings(vision_executor.outage_system_notice, result.system_notice.?);
}

test "vision does not retry a provider response over the output limit" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try writeTestImagePath(alloc, &tmp);
    defer alloc.free(image_path);
    const image = try scriptedVisionCatalog(alloc, &tmp, image_path);
    defer types.freeImageAttachment(alloc, image);
    const catalog = [_]types.ImageAttachment{image};

    const oversized = try oversizedVisionProviderResult(alloc, 4096);
    defer alloc.free(oversized);
    const responses = [_]VisionProviderScript.Response{
        .{ .content = oversized },
        .{ .content = scripted_vision_ok },
    };
    var script = VisionProviderScript{ .responses = &responses };
    const result = try runScriptedVision(alloc, &script, &catalog, scripted_vision_args, 1024);
    defer alloc.free(result.model_output);

    try std.testing.expectEqual(@as(usize, 1), script.calls);
    try std.testing.expect(std.mem.find(u8, result.model_output, "output_limit_exceeded") != null);
    const expected_message = try std.fmt.allocPrint(
        alloc,
        "Vision produced {d} bytes; the configured budget is 1024 bytes.",
        .{oversized.len},
    );
    defer alloc.free(expected_message);
    try std.testing.expect(std.mem.find(u8, result.model_output, expected_message) != null);
    try std.testing.expectEqualStrings("response exceeded the configured output budget", result.status_detail.?);
    try std.testing.expect(std.mem.find(u8, result.model_output, "retried evidence") == null);
}

test "vision makes exactly one provider call when the first response is valid" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try writeTestImagePath(alloc, &tmp);
    defer alloc.free(image_path);
    const image = try scriptedVisionCatalog(alloc, &tmp, image_path);
    defer types.freeImageAttachment(alloc, image);
    const catalog = [_]types.ImageAttachment{image};

    const responses = [_]VisionProviderScript.Response{
        .{ .content = scripted_vision_ok },
        .{ .content = scripted_vision_ok },
    };
    var script = VisionProviderScript{ .responses = &responses };
    const result = try runScriptedVision(alloc, &script, &catalog, scripted_vision_args, 64 * 1024);
    defer alloc.free(result.model_output);

    try std.testing.expectEqual(@as(usize, 1), script.calls);
    try std.testing.expectEqual(runtime_tool_contracts.ToolExecutionStatus.success, result.status);
}

test "vision propagates cancellation raised on either provider attempt" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try writeTestImagePath(alloc, &tmp);
    defer alloc.free(image_path);
    const image = try scriptedVisionCatalog(alloc, &tmp, image_path);
    defer types.freeImageAttachment(alloc, image);
    const catalog = [_]types.ImageAttachment{image};

    const first_attempt = [_]VisionProviderScript.Response{
        .cancel,
        .{ .content = scripted_vision_ok },
    };
    var first_script = VisionProviderScript{ .responses = &first_attempt };
    try std.testing.expectError(error.Cancelled, runScriptedVision(
        alloc,
        &first_script,
        &catalog,
        scripted_vision_args,
        64 * 1024,
    ));
    try std.testing.expectEqual(@as(usize, 1), first_script.calls);

    const retry_attempt = [_]VisionProviderScript.Response{
        .{ .content = "not json at all" },
        .cancel,
    };
    var retry_script = VisionProviderScript{ .responses = &retry_attempt };
    try std.testing.expectError(error.Cancelled, runScriptedVision(
        alloc,
        &retry_script,
        &catalog,
        scripted_vision_args,
        64 * 1024,
    ));
    try std.testing.expectEqual(@as(usize, 2), retry_script.calls);
}

test "vision surfaces allocation failure on either provider attempt" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try writeTestImagePath(alloc, &tmp);
    defer alloc.free(image_path);
    const image = try scriptedVisionCatalog(alloc, &tmp, image_path);
    defer types.freeImageAttachment(alloc, image);
    const catalog = [_]types.ImageAttachment{image};
    const responses = [_]VisionProviderScript.Response{
        .{ .content = "not json at all" },
        .{ .content = scripted_vision_ok },
    };

    var counting = std.testing.FailingAllocator.init(alloc, .{});
    {
        var script = VisionProviderScript{ .responses = &responses };
        const result = try runScriptedVision(
            counting.allocator(),
            &script,
            &catalog,
            scripted_vision_args,
            64 * 1024,
        );
        counting.allocator().free(result.model_output);
        try std.testing.expectEqual(@as(usize, 2), script.calls);
    }

    var fail_index: usize = 0;
    while (fail_index < counting.alloc_index) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = fail_index });
        var script = VisionProviderScript{ .responses = &responses };
        if (runScriptedVision(
            failing.allocator(),
            &script,
            &catalog,
            scripted_vision_args,
            64 * 1024,
        )) |result| {
            failing.allocator().free(result.model_output);
            return error.TestExpectedAllocationFailureToPropagate;
        } else |_| {}
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "processQueuedPrompt keeps one Vision permission decision across an internal retry" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try writeTestImagePath(alloc, &tmp);
    defer alloc.free(image_path);
    const image = try testCapturedImage(alloc, &tmp, image_path, 1);
    defer types.freeImageAttachment(alloc, image);
    var images = [_]types.ImageAttachment{image};

    const calls = [_]ToolCall{toolCall("call_vision_retry", "vision", scripted_vision_args)};
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &calls },
        .{ .content = "not json at all" },
        .{ .content = scripted_vision_ok },
        .{ .content = "The image shows retried evidence." },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.tool_registry = .{ .tools = test_support.vision_agent_test_tools[0..] };
    hooks.enable_interactive_notices = true;
    defer hooks.deinit();
    var vision_runtime = VisionAgentToolRuntime{ .alloc = alloc };
    defer vision_runtime.deinit();
    hooks.execute_delegate = vision_runtime.delegate();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.fast_mode = true;
    var job = fixture.job();
    job.model = @constCast("zai/glm-5.2");
    job.prompt = @constCast("Describe the attached image.");
    job.images = &images;
    job.authorized_image_catalog = &images;
    job.permission_mode = .ask;

    try runFakePrompt(&gateway, &hooks, config, job);

    try std.testing.expectEqual(@as(usize, 2), countVisionProviderCalls(&gateway));
    try std.testing.expectEqual(@as(usize, 1), hooks.permission_index);
    try std.testing.expectEqual(@as(usize, 1), vision_runtime.execution_count);
    try std.testing.expectEqual(@as(usize, 1), vision_runtime.result_count);
    try std.testing.expectEqual(@as(usize, 0), hooks.interactive_notices.items.len);
    try expectBodyContains(&gateway, 3, "retried evidence");
    try expectBodyNotContains(&gateway, 3, "provider_response_invalid");
    try expectBodyNotContains(&gateway, 3, image_path);
    try std.testing.expectEqualStrings(
        "The image shows retried evidence.",
        hooks.finish_assistant_text.?,
    );
}

test "processQueuedPrompt retries only the invalid batch of twenty images" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try writeTestImagePath(alloc, &tmp);
    defer alloc.free(image_path);
    var images: [20]types.ImageAttachment = undefined;
    var initialized_images: usize = 0;
    defer freeImageSlice(alloc, images[0..initialized_images]);
    var image_ids: [20]usize = undefined;
    for (&images, &image_ids, 0..) |*image, *image_id, index| {
        const id = index + 1;
        image.* = try testCapturedImage(alloc, &tmp, image_path, id);
        initialized_images += 1;
        image_id.* = id;
    }
    const arguments = try visionArgumentsForIds(alloc, &image_ids);
    defer alloc.free(arguments);
    const first_batch = try visionProviderResultForIds(alloc, image_ids[0..8]);
    defer alloc.free(first_batch);
    const second_batch = try visionProviderResultForIds(alloc, image_ids[8..16]);
    defer alloc.free(second_batch);
    const third_batch = try visionProviderResultForIds(alloc, image_ids[16..20]);
    defer alloc.free(third_batch);
    const calls = [_]ToolCall{toolCall("call_vision_batch_retry", "vision", arguments)};
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &calls },
        .{ .content = first_batch },
        .{ .content = "not json at all" },
        .{ .content = second_batch },
        .{ .content = third_batch },
        .{ .content = "Final twenty-image answer" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.tool_registry = .{ .tools = test_support.vision_agent_test_tools[0..] };
    defer hooks.deinit();
    var vision_runtime = VisionAgentToolRuntime{ .alloc = alloc };
    defer vision_runtime.deinit();
    hooks.execute_delegate = vision_runtime.delegate();
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.model = @constCast("zai/glm-5.2");
    job.prompt = @constCast("Inspect all attached images.");
    job.images = &images;
    job.authorized_image_catalog = &images;

    try runFakePrompt(&gateway, &hooks, fixture.config(), job);

    try std.testing.expectEqual(@as(usize, 6), gateway.request_bodies.items.len);
    try std.testing.expectEqual(@as(usize, 4), countVisionProviderCalls(&gateway));
    try std.testing.expectEqual(@as(usize, 8), countNeedle(gateway.request_bodies.items[1], "\"type\":\"file\""));
    try std.testing.expectEqual(@as(usize, 8), countNeedle(gateway.request_bodies.items[2], "\"type\":\"file\""));
    try std.testing.expectEqual(@as(usize, 8), countNeedle(gateway.request_bodies.items[3], "\"type\":\"file\""));
    try std.testing.expectEqual(@as(usize, 4), countNeedle(gateway.request_bodies.items[4], "\"type\":\"file\""));
    try std.testing.expectEqual(
        @as(usize, 20),
        countNeedle(gateway.request_bodies.items[5], "\\\"image_id\\\""),
    );
    try expectBodyContainsInOrder(&gateway, 5, &.{ "image 1", "image 9", "image 20" });
    try expectBodyNotContains(&gateway, 5, "provider_response_invalid");
    try expectBodyNotContains(&gateway, 5, image_path);
}

test "processQueuedPrompt keeps native image parts for vision route model" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try writeTestImagePath(alloc, &tmp);
    defer alloc.free(image_path);
    const image = try testCapturedImage(alloc, &tmp, image_path, 1);
    defer types.freeImageAttachment(alloc, image);
    var images = [_]types.ImageAttachment{image};

    const completions = [_]FakeCompletion{.{ .content = "Native image answer" }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    const capability_overrides = [_]ModelCapabilityOverride{.{
        .model = "google/gemini-2.5-flash",
        .capabilities = .{
            .supports_vision = true,
            .supports_file_input = true,
        },
    }};
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.capability_overrides = &capability_overrides;
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.model = @constCast("google/gemini-2.5-flash");
    job.prompt = @constCast("Describe the attached image.");
    job.images = &images;
    job.authorized_image_catalog = &images;

    try runFakePrompt(&gateway, &hooks, fixture.config(), job);

    try std.testing.expectEqual(@as(usize, 1), hooks.capability_queries.items.len);
    try std.testing.expectEqualStrings("google/gemini-2.5-flash", hooks.capability_queries.items[0]);
    try std.testing.expectEqual(@as(usize, 1), gateway.request_models.items.len);
    try std.testing.expectEqualStrings("google/gemini-2.5-flash", gateway.request_models.items[0]);
    try expectBodyContains(&gateway, 0, "\"type\":\"file\"");
    try expectBodyContains(&gateway, 0, "\"mediaType\":\"image/png\"");
    try expectBodyNotContains(&gateway, 0, "<image_context>");
    try expectBodyNotContains(&gateway, 0, "\"name\":\"vision\"");
    try std.testing.expectEqualStrings("Native image answer", hooks.finish_assistant_text.?);
}

test "processQueuedPrompt never uses the vision fallback for Codex" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try writeTestImagePath(alloc, &tmp);
    defer alloc.free(image_path);
    const image = try testCapturedImage(alloc, &tmp, image_path, 1);
    defer types.freeImageAttachment(alloc, image);
    var images = [_]types.ImageAttachment{image};
    const capability_overrides = [_]ModelCapabilityOverride{.{
        .model = "gpt-5.6-sol",
        .capabilities = .{},
    }};
    var gateway = FakeGateway.init(alloc, &.{});
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.capability_overrides = &capability_overrides;
    hooks.tool_registry = .{ .tools = test_support.vision_agent_test_tools[0..] };
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.provider = .codex;
    job.model = @constCast("gpt-5.6-sol");
    job.prompt = @constCast("Describe the attached image.");
    job.images = &images;
    job.authorized_image_catalog = &images;

    try std.testing.expectError(
        error.SubscriptionNativeImageUnavailable,
        runFakePrompt(&gateway, &hooks, fixture.config(), job),
    );
    try std.testing.expectEqual(@as(usize, 0), gateway.request_bodies.items.len);
}

test "processQueuedPrompt routes images natively only when vision and file input are both supported" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        label: []const u8,
        supports_vision: bool,
        supports_file_input: bool,
        expect_native: bool,
    }{
        .{ .label = "vision-file", .supports_vision = true, .supports_file_input = true, .expect_native = true },
        .{ .label = "vision-no-file", .supports_vision = true, .supports_file_input = false, .expect_native = false },
        .{ .label = "file-no-vision", .supports_vision = false, .supports_file_input = true, .expect_native = false },
        .{ .label = "neither", .supports_vision = false, .supports_file_input = false, .expect_native = false },
    };

    for (cases) |entry| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const image_path = try writeTestImagePath(alloc, &tmp);
        defer alloc.free(image_path);
        const image = try testCapturedImage(alloc, &tmp, image_path, 1);
        defer types.freeImageAttachment(alloc, image);
        var images = [_]types.ImageAttachment{image};
        const model = try std.fmt.allocPrint(alloc, "test/{s}", .{entry.label});
        defer alloc.free(model);
        const capability_overrides = [_]ModelCapabilityOverride{.{
            .model = model,
            .capabilities = .{
                .supports_vision = entry.supports_vision,
                .supports_file_input = entry.supports_file_input,
            },
        }};
        const vision_calls = [_]ToolCall{toolCall(
            "call_route_vision",
            "vision",
            "{\"image_ids\":[1],\"focus\":\"inspect\"}",
        )};
        const native_completions = [_]FakeCompletion{.{ .content = "Native route answer" }};
        const text_completions = [_]FakeCompletion{
            .{ .tool_calls = &vision_calls },
            .{
                .content = "{\"images\":[{\"image_id\":1,\"status\":\"ok\",\"summary\":\"text route evidence\",\"visible_text\":[],\"details\":[]}]}",
            },
            .{ .content = "Text route answer" },
        };
        const completions = if (entry.expect_native)
            native_completions[0..]
        else
            text_completions[0..];
        var gateway = FakeGateway.init(alloc, completions);
        defer gateway.deinit();
        var hooks = FakeAgentRuntimeDeps.init(alloc);
        hooks.capability_overrides = &capability_overrides;
        hooks.tool_registry = .{ .tools = test_support.vision_agent_test_tools[0..] };
        defer hooks.deinit();
        var vision_runtime = VisionAgentToolRuntime{ .alloc = alloc };
        defer vision_runtime.deinit();
        hooks.execute_delegate = vision_runtime.delegate();
        var fixture = PromptFixture{};
        var job = fixture.job();
        job.model = model;
        job.prompt = @constCast("Describe the attached image.");
        job.images = &images;
        job.authorized_image_catalog = &images;

        try runFakePrompt(&gateway, &hooks, fixture.config(), job);

        try std.testing.expectEqual(@as(usize, 1), hooks.capability_queries.items.len);
        try std.testing.expectEqualStrings(model, hooks.capability_queries.items[0]);
        if (entry.expect_native) {
            try std.testing.expectEqual(@as(usize, 1), gateway.request_bodies.items.len);
            try expectBodyContains(&gateway, 0, "\"type\":\"file\"");
            try expectBodyContains(&gateway, 0, "iVBORw0KGgpmaXh0dXJlIGltYWdlIGJ5dGVz");
            try expectBodyContains(&gateway, 0, "\"name\":\"vision\"");
            try std.testing.expectEqualStrings("Native route answer", hooks.finish_assistant_text.?);
        } else {
            try std.testing.expectEqual(@as(usize, 3), gateway.request_bodies.items.len);
            try expectBodyContains(&gateway, 0, "\"name\":\"vision\"");
            try expectBodyNotContains(&gateway, 0, "\"type\":\"file\"");
            try expectBodyContains(&gateway, 0, "[Image #1]");
            try expectBodyContains(&gateway, 1, "\"type\":\"file\"");
            try expectBodyContains(&gateway, 1, "iVBORw0KGgpmaXh0dXJlIGltYWdlIGJ5dGVz");
            try expectBodyContains(&gateway, 2, "text route evidence");
            try std.testing.expectEqualStrings(model, gateway.request_models.items[0]);
            try std.testing.expectEqualStrings("google/gemini-2.5-flash", gateway.request_models.items[1]);
            try std.testing.expectEqualStrings(model, gateway.request_models.items[2]);
            try std.testing.expectEqualStrings("Text route answer", hooks.finish_assistant_text.?);
        }
        for (gateway.request_bodies.items) |body| {
            try std.testing.expect(std.mem.find(u8, body, image_path) == null);
        }
    }
}

test "processQueuedPrompt rejects native-route attachment ID Vision calls before permission or execution" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image_path = try writeTestImagePath(alloc, &tmp);
    defer alloc.free(image_path);
    const image = try testCapturedImage(alloc, &tmp, image_path, 1);
    defer types.freeImageAttachment(alloc, image);
    var images = [_]types.ImageAttachment{image};

    const calls = [_]ToolCall{toolCall(
        "call_native_vision",
        "vision",
        "{\"image_ids\":[1],\"focus\":\"inspect\"}",
    )};
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &calls },
        .{ .content = "Recovered after unavailable Vision" },
        .{ .content = "Pre-fix provider continuation" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    const capability_overrides = [_]ModelCapabilityOverride{.{
        .model = "native/test-vision",
        .capabilities = .{
            .supports_vision = true,
            .supports_file_input = true,
        },
    }};
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.capability_overrides = &capability_overrides;
    hooks.tool_registry = .{ .tools = test_support.vision_agent_test_tools[0..] };
    defer hooks.deinit();
    var vision_runtime = VisionAgentToolRuntime{ .alloc = alloc };
    defer vision_runtime.deinit();
    hooks.execute_delegate = vision_runtime.delegate();
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.model = @constCast("native/test-vision");
    job.prompt = @constCast("Describe the attached image.");
    job.images = &images;
    job.authorized_image_catalog = &images;
    job.permission_mode = .auto;

    try runFakePrompt(&gateway, &hooks, fixture.config(), job);

    try std.testing.expectEqual(@as(usize, 2), gateway.request_models.items.len);
    try std.testing.expectEqualStrings("native/test-vision", gateway.request_models.items[0]);
    try std.testing.expectEqualStrings("native/test-vision", gateway.request_models.items[1]);
    try expectBodyContains(&gateway, 0, "\"type\":\"file\"");
    try expectBodyContains(&gateway, 0, "\"name\":\"vision\"");
    try expectBodyNotContains(&gateway, 1, image_path);
    try std.testing.expectEqual(@as(usize, 0), hooks.permission_names.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.executed_names.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.lifecycle_events.items.len);
    try std.testing.expectEqual(@as(usize, 0), vision_runtime.execution_count);
    try std.testing.expectEqual(@as(usize, 0), vision_runtime.result_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.rejected_names.items.len);
    try std.testing.expectEqualStrings("vision", hooks.rejected_names.items[0]);
    try std.testing.expectEqual(@as(usize, 0), hooks.system_notices.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.interactive_notices.items.len);
    try std.testing.expectEqual(@as(usize, 1), hooks.history_turns.items.len);
    const results = hooks.history_turns.items[0].assistant.execution.tool_steps[0].tool_results;
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqual(types.PersistedToolStatus.failure, results[0].status);
    try std.testing.expectEqualStrings("vision", results[0].tool_name);
    try std.testing.expect(std.mem.find(u8, results[0].output, "Vision is unavailable for this request.") != null);
    try expectBodyContains(&gateway, 1, "Vision is unavailable for this request.");
    try std.testing.expectEqualStrings("Recovered after unavailable Vision", hooks.finish_assistant_text.?);
}

test "processQueuedPrompt routes a user-supplied image path through Vision" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io_mod.getIo(), .{
        .sub_path = "photo.png",
        .data = "\x89PNG\r\n\x1a\nimage bytes",
    });
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const source_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "photo.png");
    defer alloc.free(source_path);

    const calls = [_]ToolCall{toolCall(
        "call_path_vision",
        "vision",
        "{\"paths\":[\"photo.png\"],\"focus\":\"read the image\"}",
    )};
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &calls },
        .{
            .content = "{\"images\":[{\"image_id\":1,\"status\":\"ok\",\"summary\":\"path evidence\",\"visible_text\":[],\"details\":[]}]}",
        },
        .{ .content = "Final path answer" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.tool_registry = .{ .tools = test_support.vision_agent_test_tools[0..] };
    defer hooks.deinit();
    var vision_runtime = VisionAgentToolRuntime{
        .alloc = alloc,
        .workspace_root = workspace,
    };
    defer vision_runtime.deinit();
    hooks.execute_delegate = vision_runtime.delegate();
    var fixture = PromptFixture{ .workspace_root = workspace };
    var job = fixture.job();
    job.model = @constCast("zai/glm-5.2");
    job.prompt = @constCast("Inspect photo.png.");

    try runFakePrompt(&gateway, &hooks, fixture.config(), job);

    try std.testing.expectEqual(@as(usize, 3), gateway.request_bodies.items.len);
    try expectBodyContains(&gateway, 0, "\"name\":\"vision\"");
    try expectBodyContains(&gateway, 0, "\"paths\":{\"type\":\"array\"");
    try expectBodyNotContains(&gateway, 0, "\"type\":\"file\"");
    try expectBodyContains(&gateway, 1, "\"type\":\"file\"");
    try expectBodyNotContains(&gateway, 1, source_path);
    try expectBodyContains(&gateway, 2, "path evidence");
    try std.testing.expectEqual(@as(usize, 1), hooks.permission_names.items.len);
    try std.testing.expectEqualStrings("vision", hooks.permission_names.items[0]);
    try std.testing.expectEqual(@as(usize, 1), vision_runtime.execution_count);
    try std.testing.expectEqualStrings("Final path answer", hooks.finish_assistant_text.?);
}

test "processQueuedPrompt traces selected live controls without request payloads" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "provider-options-trace.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "gateway");

    const completions = [_]FakeCompletion{.{ .content = "Done" }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    const efforts = [_]types.ReasoningEffort{types.ReasoningEffort.literal("max")};
    const capability_overrides = [_]ModelCapabilityOverride{.{
        .model = "openai/gpt-5.6-sol",
        .capabilities = model_capabilities.resolveCapabilities("openai/gpt-5.6-sol", .{
            .reasoning_efforts = .fromSlice(&efforts),
            .supports_fast_mode = true,
        }),
    }};
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.capability_overrides = &capability_overrides;
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.fast_mode = true;
    config.effort = types.ReasoningEffort.literal("max");
    var job = fixture.job();
    job.model = @constCast("openai/gpt-5.6-sol");

    try runFakePrompt(&gateway, &hooks, config, job);
    debug_trace.shutdown();

    const trace = try readTraceFile(alloc, trace_path, 65536);
    defer alloc.free(trace);

    try std.testing.expect(std.mem.find(u8, trace, "event=provider_options") != null);
    try std.testing.expect(std.mem.find(u8, trace, "model=openai/gpt-5.6-sol") != null);
    try std.testing.expect(std.mem.find(u8, trace, "fast_mode=true") != null);
    try std.testing.expect(std.mem.find(u8, trace, "effort=max") != null);
    try std.testing.expect(std.mem.find(u8, trace, "reasoning=selected") != null);
    try std.testing.expect(std.mem.find(u8, trace, "fast=selected") != null);
    try std.testing.expect(std.mem.find(u8, trace, "\"reasoning\"") == null);
    try std.testing.expect(std.mem.find(u8, trace, "api-key") == null);
    try std.testing.expect(std.mem.find(u8, trace, "user prompt") == null);
}

test "processQueuedPrompt omits Fast without catalog support" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{.{ .content = "Done" }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    const efforts = [_]types.ReasoningEffort{types.ReasoningEffort.literal("high")};
    const capability_overrides = [_]ModelCapabilityOverride{.{
        .model = "anthropic/claude-opus-4.6",
        .capabilities = model_capabilities.resolveCapabilities("anthropic/claude-opus-4.6", .{
            .reasoning_efforts = .fromSlice(&efforts),
        }),
    }};
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.capability_overrides = &capability_overrides;
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.fast_mode = true;
    config.effort = types.ReasoningEffort.literal("high");

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 1), hooks.capability_queries.items.len);
    try std.testing.expectEqual(@as(usize, 1), gateway.request_bodies.items.len);
    try expectBodyContains(&gateway, 0, "\"reasoning\":\"high\"");
    try expectRootFieldAbsent(&gateway, 0, "fast");
    try expectRootFieldAbsent(&gateway, 0, "providerOptions");
    try expectBodyNotContains(&gateway, 0, "\"maxOutputTokens\"");
}

test "processQueuedPrompt uses one available capability snapshot for history and output" {
    const alloc = std.testing.allocator;
    const old_marker = "OLD_HISTORY_MUST_BE_PROJECTED_OUT";
    const old_user = try alloc.alloc(u8, 48_000);
    defer alloc.free(old_user);
    @memset(old_user, 'u');
    @memcpy(old_user[0..old_marker.len], old_marker);
    const old_assistant = try alloc.alloc(u8, 48_000);
    defer alloc.free(old_assistant);
    @memset(old_assistant, 'a');
    var history = [_]HistoryTurn{
        .{ .assistant = .{
            .user = .{ .text = old_user },
            .assistant = old_assistant,
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("NEW_HISTORY_USER") },
            .assistant = @constCast("NEW_HISTORY_ASSISTANT"),
        } },
    };
    const available_overrides = [_]ModelCapabilityOverride{.{
        .model = "anthropic/claude-opus-4.6",
        .capabilities = model_capabilities.resolveCapabilities(
            "anthropic/claude-opus-4.6",
            .{ .context_window = 32_000, .max_output_tokens = 16_000 },
        ),
    }};
    const completions = [_]FakeCompletion{.{ .content = "Done" }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.available_capability_overrides = &available_overrides;
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.history = &history;

    try runFakePrompt(&gateway, &hooks, fixture.config(), job);

    try std.testing.expectEqual(@as(usize, 0), hooks.capability_queries.items.len);
    try expectBodyContains(&gateway, 0, "NEW_HISTORY_USER");
    try expectBodyContains(&gateway, 0, "NEW_HISTORY_ASSISTANT");
    try expectBodyNotContains(&gateway, 0, old_marker);
    try expectBodyContains(&gateway, 0, "\"maxOutputTokens\":16000");
}

test "processQueuedPrompt projects bounded output limits into gateway requests" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        context_window: ?u32,
        max_output_tokens: ?u32,
        expected_json: ?[]const u8,
    }{
        .{ .context_window = 256_000, .max_output_tokens = 32_000, .expected_json = "\"maxOutputTokens\":32000" },
        .{ .context_window = 1_048_576, .max_output_tokens = 1_048_576, .expected_json = null },
    };

    for (cases) |case| {
        const available_overrides = [_]ModelCapabilityOverride{.{
            .model = "provider/model",
            .capabilities = .{
                .context_window = case.context_window,
                .max_output_tokens = case.max_output_tokens,
            },
        }};
        const completions = [_]FakeCompletion{.{ .content = "Done" }};
        var gateway = FakeGateway.init(alloc, &completions);
        defer gateway.deinit();
        var hooks = FakeAgentRuntimeDeps.init(alloc);
        hooks.available_capability_overrides = &available_overrides;
        defer hooks.deinit();
        var fixture = PromptFixture{};
        var job = fixture.job();
        job.model = @constCast("provider/model");

        try runFakePrompt(&gateway, &hooks, fixture.config(), job);

        try std.testing.expectEqual(@as(usize, 1), gateway.request_bodies.items.len);
        if (case.expected_json) |expected| {
            try expectBodyContains(&gateway, 0, expected);
        } else {
            try expectBodyNotContains(&gateway, 0, "\"maxOutputTokens\"");
        }
        try std.testing.expectEqual(case.context_window, available_overrides[0].capabilities.context_window);
        try std.testing.expectEqual(case.max_output_tokens, available_overrides[0].capabilities.max_output_tokens);
    }
}

test "processQueuedPrompt resolves catalog capabilities for opaque effort" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "portable-reasoning-trace.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "gateway");

    const completions = [_]FakeCompletion{.{ .content = "Done" }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    const efforts = [_]types.ReasoningEffort{types.ReasoningEffort.literal("future-tier")};
    const capability_overrides = [_]ModelCapabilityOverride{.{
        .model = "provider/new-reasoning-model",
        .capabilities = model_capabilities.resolveCapabilities(
            "provider/new-reasoning-model",
            .{ .reasoning_efforts = .fromSlice(&efforts) },
        ),
    }};
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.capability_overrides = &capability_overrides;
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.effort = types.ReasoningEffort.literal("future-tier");
    var job = fixture.job();
    job.model = @constCast("provider/new-reasoning-model");

    try runFakePrompt(&gateway, &hooks, config, job);
    debug_trace.shutdown();

    try std.testing.expectEqual(@as(usize, 1), hooks.capability_queries.items.len);
    try std.testing.expectEqualStrings("provider/new-reasoning-model", hooks.capability_queries.items[0]);
    try expectBodyContains(&gateway, 0, "\"reasoning\":\"future-tier\"");
    try expectBodyNotContains(&gateway, 0, "\"providerOptions\"");

    const trace = try readTraceFile(alloc, trace_path, 65536);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "reasoning=selected") != null);
}

test "processQueuedPrompt traces why stale controls are omitted" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "stale-controls-trace.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "gateway");

    const completions = [_]FakeCompletion{.{ .content = "Done" }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.effort = types.ReasoningEffort.literal("stale-tier");
    config.fast_mode = true;
    var job = fixture.job();
    job.model = @constCast("provider/no-live-controls");

    try runFakePrompt(&gateway, &hooks, config, job);
    debug_trace.shutdown();

    try expectBodyNotContains(&gateway, 0, "\"reasoning\"");
    try expectRootFieldAbsent(&gateway, 0, "fast");
    try expectRootFieldAbsent(&gateway, 0, "providerOptions");
    const trace = try readTraceFile(alloc, trace_path, 65536);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "reasoning=unsupported_or_missing") != null);
    try std.testing.expect(std.mem.find(u8, trace, "fast=unsupported_or_missing") != null);
}

test "processQueuedPrompt persists interruption when capability resolution returns cancellation" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{.{ .content = "must not run" }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var fixture = PromptFixture{};
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.cancel_on_capability_resolution = &fixture.cancel_flag;
    defer hooks.deinit();
    var config = fixture.config();
    config.effort = types.ReasoningEffort.literal("high");
    var job = fixture.job();
    job.model = @constCast("provider/new-reasoning-model");

    try runFakePrompt(&gateway, &hooks, config, job);

    try std.testing.expectEqual(@as(usize, 1), hooks.capability_queries.items.len);
    try std.testing.expectEqual(@as(usize, 0), gateway.request_models.items.len);
    try std.testing.expectEqual(@as(usize, 1), hooks.interrupted_history_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.finalization_count);
    try std.testing.expectEqual(types.TurnPresentationOutcome.interrupted, hooks.finalized_outcome.?);
}

test "processQueuedPrompt does not dispatch when cancellation follows capability resolution" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{.{ .content = "must not run" }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    const capability_overrides = [_]ModelCapabilityOverride{.{
        .model = "provider/new-reasoning-model",
        .capabilities = model_capabilities.resolveCapabilities(
            "provider/new-reasoning-model",
            .{ .supports_reasoning = true },
        ),
    }};
    var fixture = PromptFixture{};
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.capability_overrides = &capability_overrides;
    hooks.cancel_after_capability_resolution = &fixture.cancel_flag;
    defer hooks.deinit();
    var config = fixture.config();
    config.effort = types.ReasoningEffort.literal("high");
    var job = fixture.job();
    job.model = @constCast("provider/new-reasoning-model");

    try runFakePrompt(&gateway, &hooks, config, job);

    try std.testing.expectEqual(@as(usize, 1), hooks.capability_queries.items.len);
    try std.testing.expectEqual(@as(usize, 0), gateway.request_models.items.len);
    try std.testing.expectEqual(@as(usize, 1), hooks.interrupted_history_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.finalization_count);
    try std.testing.expectEqual(types.TurnPresentationOutcome.interrupted, hooks.finalized_outcome.?);
}

test "processQueuedPrompt keeps exact model identity and emits Gateway Fast" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{.{ .content = "Done" }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    const capability_overrides = [_]ModelCapabilityOverride{.{
        .model = "zai/glm-5.2",
        .capabilities = model_capabilities.resolveCapabilities("zai/glm-5.2", .{ .supports_fast_mode = true }),
    }};
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.capability_overrides = &capability_overrides;
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.fast_mode = true;
    var job = fixture.job();
    job.model = @constCast("zai/glm-5.2");

    try runFakePrompt(&gateway, &hooks, config, job);

    try std.testing.expectEqual(@as(usize, 1), gateway.request_models.items.len);
    try std.testing.expectEqualStrings("zai/glm-5.2", gateway.request_models.items[0]);
    try std.testing.expectEqual(@as(usize, 1), hooks.capability_queries.items.len);
    try expectRootFieldAbsent(&gateway, 0, "fast");
    try expectBodyContains(&gateway, 0, "\"providerOptions\":{\"gateway\":{\"speed\":\"fast\"}}");
}

test "processQueuedPrompt keeps directly selected fast model identity for portable lookup" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{.{ .content = "Done" }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    const capability_overrides = [_]ModelCapabilityOverride{.{
        .model = "zai/glm-5.2-fast",
        .capabilities = model_capabilities.resolveCapabilities(
            "zai/glm-5.2-fast",
            .{ .reasoning_efforts = .fromSlice(&[_]types.ReasoningEffort{types.ReasoningEffort.literal("high")}) },
        ),
    }};
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.capability_overrides = &capability_overrides;
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.effort = types.ReasoningEffort.literal("high");
    var job = fixture.job();
    job.model = @constCast("zai/glm-5.2-fast");

    try runFakePrompt(&gateway, &hooks, config, job);

    try std.testing.expectEqual(@as(usize, 1), hooks.capability_queries.items.len);
    try std.testing.expectEqualStrings("zai/glm-5.2-fast", hooks.capability_queries.items[0]);
    try std.testing.expectEqualStrings("zai/glm-5.2-fast", gateway.request_models.items[0]);
}

test "processQueuedPrompt filters stale controls against each queued model" {
    const alloc = std.testing.allocator;
    var fixture = PromptFixture{};

    {
        const completions = [_]FakeCompletion{.{ .content = "Done" }};
        var gateway = FakeGateway.init(alloc, &completions);
        defer gateway.deinit();
        const efforts = [_]types.ReasoningEffort{types.ReasoningEffort.literal("xhigh")};
        const overrides = [_]ModelCapabilityOverride{.{
            .model = "anthropic/claude-opus-4.8",
            .capabilities = model_capabilities.resolveCapabilities("anthropic/claude-opus-4.8", .{
                .reasoning_efforts = .fromSlice(&efforts),
                .supports_fast_mode = true,
            }),
        }};
        var hooks = FakeAgentRuntimeDeps.init(alloc);
        hooks.capability_overrides = &overrides;
        defer hooks.deinit();
        var config = fixture.config();
        config.fast_mode = true;
        config.effort = types.ReasoningEffort.literal("xhigh");
        var job = fixture.job();
        job.model = @constCast("anthropic/claude-opus-4.8");

        try runFakePrompt(&gateway, &hooks, config, job);

        try expectBodyContains(&gateway, 0, "\"reasoning\":\"xhigh\"");
        try expectRootFieldAbsent(&gateway, 0, "fast");
        try expectBodyContains(&gateway, 0, "\"providerOptions\":{\"gateway\":{\"speed\":\"fast\"}}");
    }

    {
        const completions = [_]FakeCompletion{.{ .content = "Done" }};
        var gateway = FakeGateway.init(alloc, &completions);
        defer gateway.deinit();
        var hooks = FakeAgentRuntimeDeps.init(alloc);
        defer hooks.deinit();
        var config = fixture.config();
        config.fast_mode = true;
        config.effort = types.ReasoningEffort.literal("xhigh");
        var job = fixture.job();
        job.model = @constCast("anthropic/claude-sonnet-4.6");

        try runFakePrompt(&gateway, &hooks, config, job);

        try expectBodyNotContains(&gateway, 0, "\"reasoning\"");
        try expectRootFieldAbsent(&gateway, 0, "fast");
        try expectRootFieldAbsent(&gateway, 0, "providerOptions");
    }
}

test "processQueuedPrompt filters captured Fast by model capability" {
    const alloc = std.testing.allocator;
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.fast_mode = true;
    config.effort = types.ReasoningEffort.literal("high");

    {
        const completions = [_]FakeCompletion{.{ .content = "Done" }};
        var gateway = FakeGateway.init(alloc, &completions);
        defer gateway.deinit();
        var hooks = FakeAgentRuntimeDeps.init(alloc);
        defer hooks.deinit();
        var job = fixture.job();
        job.model = @constCast("openai/gpt-4o");

        try runFakePrompt(&gateway, &hooks, config, job);

        try std.testing.expectEqual(@as(usize, 1), gateway.request_bodies.items.len);
        try expectRootFieldAbsent(&gateway, 0, "fast");
        try expectRootFieldAbsent(&gateway, 0, "providerOptions");
    }

    {
        const completions = [_]FakeCompletion{.{ .content = "Done" }};
        var gateway = FakeGateway.init(alloc, &completions);
        defer gateway.deinit();
        const overrides = [_]ModelCapabilityOverride{.{
            .model = "anthropic/claude-opus-4.6",
            .capabilities = model_capabilities.resolveCapabilities("anthropic/claude-opus-4.6", .{ .supports_fast_mode = true }),
        }};
        var hooks = FakeAgentRuntimeDeps.init(alloc);
        hooks.capability_overrides = &overrides;
        defer hooks.deinit();

        try runFakePrompt(&gateway, &hooks, config, fixture.job());

        try std.testing.expectEqual(@as(usize, 1), gateway.request_bodies.items.len);
        try expectRootFieldAbsent(&gateway, 0, "fast");
        try expectBodyContains(&gateway, 0, "\"providerOptions\":{\"gateway\":{\"speed\":\"fast\"}}");
    }
}

test "processQueuedPrompt provider payload follows queued model sync boundaries" {
    const alloc = std.testing.allocator;
    var fixture = PromptFixture{};
    var worker = worker_runtime.WorkerRuntime{};
    defer worker.deinit(alloc);
    worker.agent_turn_settings = .{
        .fast_mode = true,
        .effort = types.ReasoningEffort.literal("high"),
    };

    try worker.enqueuePrompt(alloc, try makeOwnedProviderPrompt(alloc, "unsupported", "anthropic/claude-opus-4.6"));
    try worker.syncQueuedPromptModel(alloc, "openai/gpt-4o");
    const unsupported_job = (try worker.waitAndTakeNextPrompt(alloc)).?;
    defer worker_runtime.freeQueuedPrompt(alloc, unsupported_job);
    try std.testing.expect(unsupported_job.agent_settings.fast_mode);

    {
        const completions = [_]FakeCompletion{.{ .content = "Done" }};
        var gateway = FakeGateway.init(alloc, &completions);
        defer gateway.deinit();
        var hooks = FakeAgentRuntimeDeps.init(alloc);
        defer hooks.deinit();
        var config = fixture.config();
        config.fast_mode = unsupported_job.agent_settings.fast_mode;
        config.effort = unsupported_job.agent_settings.effort;

        try runFakePrompt(&gateway, &hooks, config, unsupported_job);

        try std.testing.expectEqual(@as(usize, 1), gateway.request_bodies.items.len);
        try expectRootFieldAbsent(&gateway, 0, "fast");
        try expectRootFieldAbsent(&gateway, 0, "providerOptions");
    }
    worker.finishProcessing();

    try worker.enqueuePrompt(alloc, try makeOwnedProviderPrompt(alloc, "supported", "openai/gpt-4o"));
    try worker.syncQueuedPromptModel(alloc, "anthropic/claude-opus-4.6");
    const supported_job = (try worker.waitAndTakeNextPrompt(alloc)).?;
    defer worker_runtime.freeQueuedPrompt(alloc, supported_job);
    try std.testing.expect(supported_job.agent_settings.fast_mode);

    {
        const completions = [_]FakeCompletion{.{ .content = "Done" }};
        var gateway = FakeGateway.init(alloc, &completions);
        defer gateway.deinit();
        const efforts = [_]types.ReasoningEffort{types.ReasoningEffort.literal("high")};
        const overrides = [_]ModelCapabilityOverride{.{
            .model = "anthropic/claude-opus-4.6",
            .capabilities = model_capabilities.resolveCapabilities("anthropic/claude-opus-4.6", .{
                .reasoning_efforts = .fromSlice(&efforts),
                .supports_fast_mode = true,
            }),
        }};
        var hooks = FakeAgentRuntimeDeps.init(alloc);
        hooks.capability_overrides = &overrides;
        defer hooks.deinit();
        var config = fixture.config();
        config.fast_mode = supported_job.agent_settings.fast_mode;
        config.effort = supported_job.agent_settings.effort;

        try runFakePrompt(&gateway, &hooks, config, supported_job);

        try std.testing.expectEqual(@as(usize, 1), gateway.request_bodies.items.len);
        try expectBodyContains(&gateway, 0, "\"reasoning\":\"high\"");
        try expectRootFieldAbsent(&gateway, 0, "fast");
        try expectBodyContains(&gateway, 0, "\"providerOptions\":{\"gateway\":{\"speed\":\"fast\"}}");
    }
}

test "processQueuedPrompt emits submitted prompt token update before streamed output" {
    const alloc = std.testing.allocator;
    const chunks = [_][]const u8{"hello"};
    const completions = [_]FakeCompletion{.{
        .chunks = &chunks,
        .content = "hello",
        .usage = .{ .input_tokens = 100, .output_tokens = 5 },
    }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};

    const job = fixture.job();
    try runFakePrompt(&gateway, &hooks, fixture.config(), job);

    try std.testing.expect(hooks.token_updates.items.len >= 3);
    var prompt_estimator = token_estimate.StreamingEstimator{};
    prompt_estimator.consume(job.prompt);
    try std.testing.expectEqual(prompt_estimator.estimate(), hooks.token_updates.items[0].input_tokens);
    try std.testing.expectEqual(@as(u64, 0), hooks.token_updates.items[0].output_tokens);
    try std.testing.expect(!hooks.token_updates.items[0].input_exact);
    try std.testing.expect(!hooks.token_updates.items[0].output_exact);
    try std.testing.expectEqual(types.TurnTokenProgress{
        .input_tokens = prompt_estimator.estimate(),
        .output_tokens = 5,
        .input_exact = false,
    }, hooks.token_updates.items[hooks.token_updates.items.len - 1]);
    var input_idx: ?usize = null;
    var text_idx: ?usize = null;
    for (hooks.log.items, 0..) |entry, i| {
        if (input_idx == null and std.mem.startsWith(u8, entry, "event:turn_tokens:")) {
            input_idx = i;
        }
        if (std.mem.startsWith(u8, entry, "text:")) {
            text_idx = i;
            break;
        }
    }
    try std.testing.expect(input_idx != null);
    try std.testing.expect(text_idx != null);
    try std.testing.expect(input_idx.? < text_idx.?);
}

test "processQueuedPrompt excludes assistant-authored subagent prompts from input progress" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{.{
        .content = "done",
        .usage = .{ .input_tokens = 40_000, .output_tokens = 5 },
    }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.origin = .subagent;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(types.TurnTokenProgress{
        .input_tokens = 0,
        .output_tokens = 5,
    }, hooks.finish_summary.?.token_progress);
}

test "processQueuedPrompt estimates raw reasoning and content independently of chunk boundaries" {
    const alloc = std.testing.allocator;
    const reasoning_chunks = [_][]const u8{ "thinking", " through" };
    const chunks = [_][]const u8{ "**bold**", " [docs](https://example.test)" };
    const completions = [_]FakeCompletion{.{
        .reasoning_chunks = &reasoning_chunks,
        .chunks = &chunks,
        .content = "**bold** [docs](https://example.test)",
    }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};

    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

    try std.testing.expect(hooks.token_updates.items.len >= 2);
    var expected_reasoning = token_estimate.StreamingEstimator{};
    for (reasoning_chunks) |chunk| expected_reasoning.consume(chunk);
    var expected_content = token_estimate.StreamingEstimator{};
    for (chunks) |chunk| expected_content.consume(chunk);
    const final_progress = hooks.token_updates.items[hooks.token_updates.items.len - 1];
    try std.testing.expectEqual(expected_reasoning.estimate() + expected_content.estimate(), final_progress.output_tokens);
    try std.testing.expect(!final_progress.output_exact);
}

test "processQueuedPrompt preserves aggregate Gateway delivery ambiguity" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{.{
        .content = "done",
        .usage = .{ .input_tokens = 100, .output_tokens = 5 },
        .delivery_ambiguous = true,
    }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};

    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

    try std.testing.expectEqual(@as(u64, 5), hooks.finish_summary.?.token_progress.output_tokens);
    try std.testing.expect(!hooks.finish_summary.?.token_progress.output_exact);
}

test "processQueuedPrompt keeps token progress publication failure non-fatal" {
    const alloc = std.testing.allocator;
    const chunks = [_][]const u8{"pending"};
    const completions = [_]FakeCompletion{.{
        .chunks = &chunks,
        .content = "pending",
    }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.stream_output_token_error = error.TestOutputTokenPublicationFailure;
    defer hooks.deinit();
    var fixture = PromptFixture{};

    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());
    try std.testing.expectEqual(@as(usize, 1), gateway.index);
    try std.testing.expectEqual(@as(usize, 1), gateway.request_bodies.items.len);
    try std.testing.expectEqual(@as(usize, 1), hooks.token_updates.items.len);
    try std.testing.expect(hooks.token_updates.items[0].input_tokens > 0);
    try std.testing.expect(hooks.texts.items.len > 0);
    try std.testing.expectEqual(@as(usize, 1), hooks.history_turns.items.len);
    try std.testing.expectEqual(@as(usize, 1), hooks.finalization_count);
    try std.testing.expectEqual(types.TurnPresentationOutcome.completed, hooks.finalized_outcome.?);
}

test "processQueuedPrompt final summary counts submitted input once across Gateway steps" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{toolCall("call_read", "read_file", "{\"path\":\"a\"}")};
    const completions = [_]FakeCompletion{
        .{
            .tool_calls = &calls,
            .usage = .{ .input_tokens = 100_000, .output_tokens = 20_000 },
        },
        .{
            .content = "Final",
            .usage = .{ .input_tokens = 200_000, .output_tokens = 30_000 },
        },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};

    const job = fixture.job();
    try runFakePrompt(&gateway, &hooks, fixture.config(), job);

    const summary = hooks.finish_summary.?;
    var prompt_estimator = token_estimate.StreamingEstimator{};
    prompt_estimator.consume(job.prompt);
    try std.testing.expectEqual(types.TurnTokenProgress{
        .input_tokens = prompt_estimator.estimate(),
        .output_tokens = 50_000,
        .input_exact = false,
    }, summary.token_progress);
    try std.testing.expect(summary.turn_duration_ms >= summary.thinking_duration_ms);
}

test "processQueuedPrompt places transient overlay before history and current prompt" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{.{ .content = "No" }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    hooks.static_context_text = "static project context unique";
    hooks.runtime_context_text = "runtime tail context unique";

    var history = [_]HistoryTurn{.{ .background_command = .{
        .user = .{ .text = @constCast("past background prompt") },
        .log_path = @constCast("/tmp/past-background.log"),
        .expect_url = false,
    } }};
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.history = &history;
    job.prompt = @constCast("is it still running");

    try runFakePrompt(&gateway, &hooks, fixture.config(), job);

    try std.testing.expectEqual(@as(usize, 1), gateway.request_bodies.items.len);
    const body = gateway.request_bodies.items[0];
    const system_idx = std.mem.indexOf(u8, body, "system") orelse return error.TestExpectedEqual;
    const static_idx = std.mem.indexOf(u8, body, "static project context unique") orelse return error.TestExpectedEqual;
    const history_idx = std.mem.indexOf(u8, body, "past background prompt") orelse return error.TestExpectedEqual;
    const current_idx = std.mem.indexOf(u8, body, "is it still running") orelse return error.TestExpectedEqual;
    const runtime_idx = std.mem.indexOf(u8, body, "runtime tail context unique") orelse return error.TestExpectedEqual;
    try std.testing.expect(system_idx < static_idx);
    try std.testing.expect(static_idx < runtime_idx);
    try std.testing.expect(runtime_idx < history_idx);
    try std.testing.expect(history_idx < current_idx);
    try expectGatewayPromptEntryCacheControl(&gateway, 0, "system", true);
    try expectGatewayPromptEntryCacheControl(&gateway, 0, "static project context unique", true);
    try expectGatewayPromptEntryCacheControl(&gateway, 0, "runtime tail context unique", false);
    try expectNoPromptCacheControlAfter(&gateway, 0, "runtime tail context unique");
    try expectGatewayPromptFinalUserText(&gateway, 0, "is it still running");
    try std.testing.expectEqual(@as(usize, 0), hooks.executed_names.items.len);
}

test "processQueuedPrompt keeps supplied system prompt components in stable order without duplication" {
    const alloc = std.testing.allocator;
    var history = [_]HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("past user guidance-order needle") },
        .assistant = @constCast("past assistant guidance-order needle"),
    } }};
    const calls = [_]ToolCall{toolCall("call_read", "read_file", "{\"path\":\"a\"}")};
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &calls },
        .{ .content = "Final guidance-order answer" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    hooks.static_context_text = "static guidance-order context";
    hooks.runtime_context_text = "transient guidance-order context";
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.system_prompt = "base guidance-order prompt";
    config.custom_tool_guidance = "custom tool guidance unique needle";
    config.skills_prompt_section = "skills guidance-order section";
    config.model_prompt_overlay = "model guidance-order overlay";
    var job = fixture.job();
    job.history = history[0..];

    try runFakePrompt(&gateway, &hooks, config, job);

    try std.testing.expectEqual(@as(usize, 2), gateway.request_bodies.items.len);
    const first_roles = [_]types.ChatRole{ .system, .system, .system, .system, .system, .system, .user, .assistant, .user };
    const second_roles = [_]types.ChatRole{ .system, .system, .system, .system, .system, .system, .user, .assistant, .user, .assistant, .tool };
    try expectGatewayPromptRoles(&gateway, 0, &first_roles);
    try expectGatewayPromptRoles(&gateway, 1, &second_roles);
    inline for (&.{ @as(usize, 0), @as(usize, 1) }) |request_index| {
        try expectGatewayPromptStringEntry(&gateway, request_index, 0, "base guidance-order prompt");
        try expectGatewayPromptStringEntry(&gateway, request_index, 1, "custom tool guidance unique needle");
        try expectGatewayPromptStringEntry(&gateway, request_index, 2, "skills guidance-order section");
        try expectGatewayPromptStringEntry(&gateway, request_index, 3, "model guidance-order overlay");
        try expectGatewayPromptTextCount(&gateway, request_index, "custom tool guidance unique needle", 1);
        try expectGatewayPromptTextCount(&gateway, request_index, "model guidance-order overlay", 1);
        const order = [_][]const u8{
            "base guidance-order prompt",
            "custom tool guidance unique needle",
            "skills guidance-order section",
            "model guidance-order overlay",
            "static guidance-order context",
            "transient guidance-order context",
            "past assistant guidance-order needle",
            "user prompt",
        };
        try expectBodyContainsInOrder(&gateway, request_index, &order);
    }

    try std.testing.expectEqual(@as(usize, 1), hooks.history_turns.items.len);
    const persisted = hooks.history_turns.items[0].assistant;
    try std.testing.expectEqualStrings("user prompt", persisted.user.text);
    try std.testing.expectEqualStrings("Final guidance-order answer", persisted.assistant);
    try std.testing.expect(std.mem.find(u8, persisted.user.text, "custom tool guidance unique needle") == null);
    try std.testing.expect(std.mem.find(u8, persisted.assistant, "custom tool guidance unique needle") == null);
}

test "processQueuedPrompt omits an empty custom tool guidance message" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{.{ .content = "Final" }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.custom_tool_guidance = "";

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    const roles = [_]types.ChatRole{ .system, .user };
    try expectGatewayPromptRoles(&gateway, 0, &roles);
    try expectGatewayPromptStringEntry(&gateway, 0, 0, "system");
}

test "processQueuedPrompt refreshes runtime overlay each step and preserves turn suffix" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{toolCall("call_read", "read_file", "{\"path\":\"a\"}")};
    const completions = [_]FakeCompletion{
        .{ .content = "Checking.", .tool_calls = &calls },
        .{ .content = "Final" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    const overlays = [_][]const u8{ "runtime overlay step one", "runtime overlay step two" };
    hooks.runtime_context_texts = &overlays;
    var fixture = PromptFixture{};

    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

    try std.testing.expectEqual(@as(usize, 2), gateway.request_bodies.items.len);
    try expectBodyContains(&gateway, 0, "runtime overlay step one");
    try expectBodyNotContains(&gateway, 0, "runtime overlay step two");
    try expectBodyContains(&gateway, 1, "runtime overlay step two");
    try expectBodyNotContains(&gateway, 1, "runtime overlay step one");
    try expectBodyContains(&gateway, 1, "Checking.");
    try expectBodyContains(&gateway, 1, "\"toolName\":\"read_file\"");
    try expectBodyContains(&gateway, 1, "\"value\":\"ok\"");
    const first_request_roles = [_]types.ChatRole{ .system, .system, .user };
    const second_request_roles = [_]types.ChatRole{ .system, .system, .user, .assistant, .tool };
    try expectGatewayPromptRoles(&gateway, 0, &first_request_roles);
    try expectGatewayPromptRoles(&gateway, 1, &second_request_roles);
    const second_request_order = [_][]const u8{ "runtime overlay step two", "user prompt", "Checking.", "\"value\":\"ok\"" };
    try expectBodyContainsInOrder(&gateway, 1, &second_request_order);
}

test "processQueuedPrompt refreshes and acknowledges parent deliveries for each tool step" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{toolCall("call_read", "read_file", "{\"path\":\"a\"}")};
    const completions = [_]FakeCompletion{
        .{ .finish_reason = .provider_error },
        .{ .content = "Checking.", .tool_calls = &calls },
        .{ .content = "Final" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    const prepared_contexts = [_][]const u8{
        "prepared child delivery for step one",
        "prepared child delivery for step two",
    };
    hooks.parent_turn_context_texts = &prepared_contexts;
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.max_provider_attempts = 2;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 2), hooks.parent_turn_prepare_count);
    try std.testing.expectEqual(@as(usize, 2), hooks.parent_turn_ack_count);
    try std.testing.expectEqual(@as(u64, 2), hooks.parent_turn_last_ack_sequence);
    try std.testing.expect(hooks.parent_turn_ack_contract_valid);
    try std.testing.expectEqual(@as(usize, 3), gateway.request_bodies.items.len);
    try expectBodyContains(&gateway, 0, "prepared child delivery for step one");
    try expectBodyNotContains(&gateway, 0, "prepared child delivery for step two");
    try expectBodyContains(&gateway, 1, "prepared child delivery for step one");
    try expectBodyNotContains(&gateway, 1, "prepared child delivery for step two");
    try expectBodyContains(&gateway, 2, "prepared child delivery for step two");
    try expectBodyNotContains(&gateway, 2, "prepared child delivery for step one");
}

test "processQueuedPrompt leaves parent delivery pending after pre-dispatch cancellation" {
    const alloc = std.testing.allocator;
    const first_completions = [_]FakeCompletion{.{ .content = "must not run" }};
    var first_gateway = FakeGateway.init(alloc, &first_completions);
    defer first_gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    hooks.parent_turn_context_text = "parent delivery survives pre-dispatch cancellation";
    hooks.parent_turn_context_sequence = 41;
    var fixture = PromptFixture{};
    fixture.cancel_flag.store(true, .seq_cst);

    try runFakePrompt(&first_gateway, &hooks, fixture.config(), fixture.job());

    try std.testing.expectEqual(@as(usize, 0), hooks.parent_turn_prepare_count);
    try std.testing.expectEqual(@as(usize, 0), hooks.parent_turn_ack_count);
    try std.testing.expectEqual(@as(usize, 0), first_gateway.request_bodies.items.len);

    fixture.cancel_flag.store(false, .seq_cst);
    const second_completions = [_]FakeCompletion{.{ .content = "Final after cancellation" }};
    var second_gateway = FakeGateway.init(alloc, &second_completions);
    defer second_gateway.deinit();
    try runFakePrompt(&second_gateway, &hooks, fixture.config(), fixture.job());

    try std.testing.expectEqual(@as(usize, 1), hooks.parent_turn_prepare_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.parent_turn_ack_count);
    try std.testing.expectEqual(@as(u64, 41), hooks.parent_turn_last_ack_sequence);
    try expectBodyContains(
        &second_gateway,
        0,
        "parent delivery survives pre-dispatch cancellation",
    );
}

test "processQueuedPrompt leaves parent delivery pending after pre-send failure" {
    const alloc = std.testing.allocator;
    const first_completions = [_]FakeCompletion{.{ .pre_send_error = error.TestTransportFailure }};
    var first_gateway = FakeGateway.init(alloc, &first_completions);
    defer first_gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    hooks.parent_turn_context_text = "parent delivery survives pre-send failure";
    hooks.parent_turn_context_sequence = 42;
    var fixture = PromptFixture{};

    try std.testing.expectError(
        error.TestTransportFailure,
        runFakePrompt(&first_gateway, &hooks, fixture.config(), fixture.job()),
    );

    try std.testing.expectEqual(@as(usize, 1), hooks.parent_turn_prepare_count);
    try std.testing.expectEqual(@as(usize, 0), hooks.parent_turn_ack_count);
    try expectBodyContains(
        &first_gateway,
        0,
        "parent delivery survives pre-send failure",
    );

    const second_completions = [_]FakeCompletion{.{ .content = "Final after pre-send failure" }};
    var second_gateway = FakeGateway.init(alloc, &second_completions);
    defer second_gateway.deinit();
    try runFakePrompt(&second_gateway, &hooks, fixture.config(), fixture.job());

    try std.testing.expectEqual(@as(usize, 2), hooks.parent_turn_prepare_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.parent_turn_ack_count);
    try std.testing.expectEqual(@as(u64, 42), hooks.parent_turn_last_ack_sequence);
    try expectBodyContains(
        &second_gateway,
        0,
        "parent delivery survives pre-send failure",
    );
}

test "processQueuedPrompt acknowledges parent delivery after ambiguous send failure" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{.{ .stream_error = error.TestTransportFailure }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    hooks.parent_turn_context_text = "parent delivery may have reached the model";
    var fixture = PromptFixture{};

    try std.testing.expectError(
        error.TestTransportFailure,
        runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job()),
    );

    try std.testing.expectEqual(@as(usize, 1), hooks.parent_turn_prepare_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.parent_turn_ack_count);
    try expectBodyContains(
        &gateway,
        0,
        "parent delivery may have reached the model",
    );
}

test "processQueuedPrompt delivers parent context created between tool steps" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{toolCall("call_read", "read_file", "{\"path\":\"a\"}")};
    const first_completions = [_]FakeCompletion{
        .{ .content = "Checking.", .tool_calls = &calls },
        .{ .content = "Final" },
    };
    var first_gateway = FakeGateway.init(alloc, &first_completions);
    defer first_gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    hooks.parent_turn_context_after_execute = "late child delivery";
    var fixture = PromptFixture{};

    try runFakePrompt(&first_gateway, &hooks, fixture.config(), fixture.job());

    try std.testing.expectEqual(@as(usize, 2), hooks.parent_turn_prepare_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.parent_turn_ack_count);
    try expectBodyNotContains(&first_gateway, 0, "late child delivery");
    try expectBodyContains(&first_gateway, 1, "late child delivery");
}

test "processQueuedPrompt blocks accidental terminal restart of non-live background history" {
    const alloc = std.testing.allocator;
    const command = "while true; do echo labs7; sleep 1; done";
    const args = "{\"action\":\"start\",\"command\":\"while true; do echo labs7; sleep 1; done\"}";
    const calls = [_]ToolCall{toolCall("call_restart", "terminal", args)};
    const completions = [_]FakeCompletion{
        .{ .content = "I will check it.", .tool_calls = &calls },
        .{ .content = "No." },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    hooks.runtime_context_text =
        "Runtime context: previous background command history includes command(s) that are no longer live. Treat these as terminal historical records, not running tasks.\n" ++
        "- command=while true; do echo labs7; sleep 1; done; log=/tmp/labs7.log; state=stopped\n" ++
        "For any listed command, answer liveness questions from this state; do not assume it is still running or reuse it as a live background task. Restart a listed command only if the user explicitly asks.";

    var fixture = PromptFixture{};
    var job = fixture.job();
    job.prompt = @constCast("Is the background command you just started still running? Do not run or restart it unless I ask.");
    job.permission_mode = .auto;

    try runFakePrompt(&gateway, &hooks, fixture.config(), job);

    try std.testing.expectEqual(@as(usize, 0), hooks.executed_names.items.len);
    try std.testing.expectEqual(@as(usize, 3), hooks.lifecycle_events.items.len);
    try std.testing.expect(hooks.lifecycle_events.items[0] == .authoritative_started);
    try std.testing.expect(hooks.lifecycle_events.items[1] == .progress);
    try std.testing.expectEqual(
        types.ToolOutcomeKind.denied,
        hooks.lifecycle_events.items[2].terminal.outcome.kind,
    );
    try std.testing.expectEqualStrings("No.", hooks.finish_assistant_text.?);
    try expectBodyContains(
        &gateway,
        1,
        "Blocked restarting non-live background command from history",
    );
    try expectBodyContains(&gateway, 1, command);
}

test "processQueuedPrompt projects history exactly once into each gateway request" {
    const alloc = std.testing.allocator;
    var history = [_]HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("past user unique history needle") },
        .assistant = @constCast("past assistant unique history needle"),
    } }};
    const calls = [_]ToolCall{toolCall("call_read", "read_file", "{\"path\":\"a\"}")};
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &calls },
        .{ .content = "Final" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.history = history[0..];

    try runFakePrompt(&gateway, &hooks, fixture.config(), job);

    try std.testing.expectEqual(@as(usize, 2), gateway.request_bodies.items.len);
    const first_request_roles = [_]types.ChatRole{ .system, .user, .assistant, .user };
    const second_request_roles = [_]types.ChatRole{ .system, .user, .assistant, .user, .assistant, .tool };
    try expectGatewayPromptRoles(&gateway, 0, &first_request_roles);
    try expectGatewayPromptRoles(&gateway, 1, &second_request_roles);
    for (0..gateway.request_bodies.items.len) |i| {
        try expectGatewayPromptTextCount(&gateway, i, "past user unique history needle", 1);
        try expectGatewayPromptTextCount(&gateway, i, "past assistant unique history needle", 1);
        try expectGatewayPromptTextCount(&gateway, i, "user prompt", 1);
    }
}

test "processQueuedPrompt keeps completed history before the final current user prompt" {
    const alloc = std.testing.allocator;
    var history = [_]HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("prior user structural needle") },
        .assistant = @constCast("prior assistant structural needle"),
    } }};
    const completions = [_]FakeCompletion{.{ .content = "Final" }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    hooks.runtime_context_text = "runtime context structural needle";
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.history = history[0..];
    job.prompt = @constCast("current structural prompt needle");

    try runFakePrompt(&gateway, &hooks, fixture.config(), job);

    const expected_roles = [_]types.ChatRole{ .system, .system, .user, .assistant, .user };
    try expectGatewayPromptRoles(&gateway, 0, &expected_roles);
    try expectGatewayPromptTextCount(&gateway, 0, "prior user structural needle", 1);
    try expectGatewayPromptTextCount(&gateway, 0, "prior assistant structural needle", 1);
    try expectGatewayPromptTextCount(&gateway, 0, "runtime context structural needle", 1);
    try expectGatewayPromptTextCount(&gateway, 0, "current structural prompt needle", 1);
    const body = gateway.request_bodies.items[0];
    const history_idx = std.mem.indexOf(u8, body, "prior assistant structural needle") orelse return error.TestExpectedEqual;
    const runtime_idx = std.mem.indexOf(u8, body, "runtime context structural needle") orelse return error.TestExpectedEqual;
    const current_idx = std.mem.indexOf(u8, body, "current structural prompt needle") orelse return error.TestExpectedEqual;
    try std.testing.expect(runtime_idx < history_idx);
    try std.testing.expect(history_idx < current_idx);
    try expectGatewayPromptFinalUserText(&gateway, 0, "current structural prompt needle");
    try expectGatewayPromptTextCount(&gateway, 0, "Earlier messages are session history from previous turns.", 0);
    try expectGatewayPromptTextCount(&gateway, 0, "Do not re-run, re-answer, or continue earlier user turns", 0);
}

test "processQueuedPrompt reconciles provider error before tool execution" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{toolCall("call_write", "write_file", "{\"path\":\"a.txt\",\"content\":\"x\"}")};
    const completions = [_]FakeCompletion{
        .{
            .tool_calls = &calls,
            .finish_reason = .provider_error,
        },
        .{ .content = "Recovered safely" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};

    var config = fixture.config();
    config.max_provider_attempts = 2;
    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 0), hooks.permission_names.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.executed_names.items.len);
    try std.testing.expectEqual(@as(usize, 1), hooks.finish_event_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.history_turns.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.route_recovery_count);
    try expectBodyContains(&gateway, 1, "\"toolChoice\":{\"type\":\"none\"}");
    try std.testing.expectEqual(@as(usize, 2), hooks.route_recovery_statuses.items.len);
    try expectRouteStatus(&hooks, 0, .auto_retry, "⚠ Provider unavailable · provider_error · checking uncertain tool state · attempt 1/2");
    try expectRouteStatus(&hooks, 1, .auto_recovered, "✓ recovered · succeeded on attempt 2/2");
}

test "processQueuedPrompt pauses when uncertain tool reconciliation returns another tool" {
    const alloc = std.testing.allocator;
    const starts = [_]ToolCall{toolCall("provider_search", "web_search", "{}")};
    const repeated = [_]ToolCall{toolCall("provider_search_repeat", "web_search", "{}")};
    const completions = [_]FakeCompletion{
        .{
            .streamed_tool_starts = &starts,
            .stream_error_after_tool_starts = error.ReadFailed,
        },
        .{ .tool_calls = &repeated, .finish_reason = .provider_error },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.enable_recovery_checkpoint = true;
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.max_provider_attempts = 3;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 2), gateway.request_models.items.len);
    try expectBodyContains(&gateway, 1, "\"toolChoice\":{\"type\":\"none\"}");
    try std.testing.expectEqual(@as(usize, 0), hooks.executed_names.items.len);
    try std.testing.expectEqual(types.TurnPresentationOutcome.paused, hooks.finalized_outcome.?);
    const status = hooks.route_recovery_statuses.items[hooks.route_recovery_statuses.items.len - 1];
    try std.testing.expectEqual(types.ModelRecoveryRequiredAction.inspect_uncertain_tool, status.required_action);
    const checkpoint = hooks.recovery_checkpoints.items[hooks.recovery_checkpoints.items.len - 1];
    try std.testing.expectEqual(session_codec.RecoveryToolState.uncertain, checkpoint.tool_state);
    try std.testing.expectEqual(@as(usize, 2), checkpoint.consumed_provider_attempts);
}

test "processQueuedPrompt preserves a confirmed provider tool result across recovery" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{.{
        .id = "provider_search_1",
        .name = "perplexity_search",
        .arguments_json = "{\"query\":\"zig\"}",
        .provider_result = "{\"content\":\"exact provider evidence\"}",
        .provenance = .provider_executed,
    }};
    const completions = [_]FakeCompletion{
        .{
            .tool_calls = &calls,
            .finish_reason = .provider_error,
            .provider_failure_detail = "failed after provider result",
        },
        .{ .content = "Recovered from the existing result" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.enable_recovery_checkpoint = true;
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.max_provider_attempts = 2;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 2), gateway.request_models.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.executed_names.items.len);
    try expectBodyContains(&gateway, 1, "provider_search_1");
    try expectBodyContains(&gateway, 1, "exact provider evidence");
    try expectBodyContains(&gateway, 1, "confirmed tool result");
    const execution = hooks.history_turns.items[0].assistant.execution;
    try std.testing.expectEqual(@as(usize, 1), execution.tool_steps.len);
    try std.testing.expectEqual(@as(usize, 1), execution.tool_steps[0].tool_results.len);
    try std.testing.expectEqualStrings(
        "provider_search_1",
        execution.tool_steps[0].tool_results[0].tool_call_id,
    );
    try std.testing.expectEqualStrings(
        "{\"content\":\"exact provider evidence\"}",
        execution.tool_steps[0].tool_results[0].output,
    );

    const settled_checkpoint = hooks.recovery_checkpoints.items[1];
    try std.testing.expectEqual(
        session_codec.RecoveryToolState.confirmed,
        settled_checkpoint.tool_state,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        settled_checkpoint.execution.tool_steps.len,
    );
    try std.testing.expectEqualStrings(
        "{\"content\":\"exact provider evidence\"}",
        settled_checkpoint.execution.tool_steps[0].tool_results[0].output,
    );

    var restored_checkpoint = try settled_checkpoint.dupe(alloc);
    defer restored_checkpoint.deinit(alloc);
    const restored_completions = [_]FakeCompletion{.{
        .content = "Recovered after checkpoint reload",
    }};
    var restored_gateway = FakeGateway.init(alloc, &restored_completions);
    defer restored_gateway.deinit();
    var restored_hooks = FakeAgentRuntimeDeps.init(alloc);
    defer restored_hooks.deinit();
    var restored_job = fixture.job();
    restored_job.recovery_checkpoint = restored_checkpoint;

    try runFakePrompt(&restored_gateway, &restored_hooks, config, restored_job);

    try expectBodyContains(&restored_gateway, 0, "provider_search_1");
    try expectBodyContains(&restored_gateway, 0, "exact provider evidence");
}

test "processQueuedPrompt preserves the provider-executed subset of mixed failed tools" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{
        .{
            .id = "provider_search_mixed",
            .name = "perplexity_search",
            .arguments_json = "{\"query\":\"zig\"}",
            .provider_result = "{\"content\":\"mixed provider evidence\"}",
            .provenance = .provider_executed,
        },
        toolCall(
            "local_write_mixed",
            "write_file",
            "{\"path\":\"a.txt\",\"content\":\"x\"}",
        ),
    };
    const completions = [_]FakeCompletion{
        .{
            .tool_calls = &calls,
            .finish_reason = .provider_error,
            .provider_failure_detail = "failed after mixed tool batch",
        },
        .{ .content = "Recovered without local execution" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.enable_recovery_checkpoint = true;
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.max_provider_attempts = 2;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 0), hooks.executed_names.items.len);
    try expectBodyContains(&gateway, 1, "provider_search_mixed");
    try expectBodyContains(&gateway, 1, "mixed provider evidence");
    const settled_checkpoint = hooks.recovery_checkpoints.items[1];
    try std.testing.expectEqual(
        session_codec.RecoveryToolState.uncertain,
        settled_checkpoint.tool_state,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        settled_checkpoint.execution.tool_steps.len,
    );
    try std.testing.expectEqualStrings(
        "provider_search_mixed",
        settled_checkpoint.execution.tool_steps[0].tool_results[0].tool_call_id,
    );
}

test "processQueuedPrompt pauses uncertain tool recovery with an inspection action" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{
        toolCall("uncertain_write", "write_file", "{\"path\":\"a.txt\",\"content\":\"x\"}"),
    };
    const completions = [_]FakeCompletion{.{
        .tool_calls = &calls,
        .finish_reason = .provider_error,
    }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.enable_recovery_checkpoint = true;
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.max_provider_attempts = 1;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 0), hooks.executed_names.items.len);
    try std.testing.expectEqual(types.TurnPresentationOutcome.paused, hooks.finalized_outcome.?);
    const status = hooks.route_recovery_statuses.items[hooks.route_recovery_statuses.items.len - 1];
    try std.testing.expectEqual(types.ModelRecoveryRequiredAction.inspect_uncertain_tool, status.required_action);
    const checkpoint = hooks.recovery_checkpoints.items[hooks.recovery_checkpoints.items.len - 1];
    try std.testing.expectEqual(session_codec.RecoveryToolState.uncertain, checkpoint.tool_state);
}

test "processQueuedPrompt suppresses a repeated confirmed provider tool identity" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{.{
        .id = "provider_search_repeat",
        .name = "perplexity_search",
        .arguments_json = "{\"query\":\"zig\"}",
        .provider_result = "{\"content\":\"one provider result\"}",
        .provenance = .provider_executed,
    }};
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &calls, .finish_reason = .provider_error },
        .{ .tool_calls = &calls },
        .{ .content = "Final after duplicate suppression" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.max_provider_attempts = 3;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 3), gateway.request_models.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.executed_names.items.len);
    const execution = hooks.history_turns.items[0].assistant.execution;
    try std.testing.expectEqual(@as(usize, 1), execution.tool_steps.len);
    try std.testing.expectEqual(@as(usize, 1), execution.tool_steps[0].tool_results.len);
    try std.testing.expectEqualStrings(
        "Final after duplicate suppression",
        hooks.history_turns.items[0].assistant.assistant,
    );
}

test "processQueuedPrompt rejects content filter before tool execution" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{toolCall("call_write", "write_file", "{\"path\":\"a.txt\",\"content\":\"x\"}")};
    const completions = [_]FakeCompletion{.{
        .tool_calls = &calls,
        .finish_reason = .content_filter,
    }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};

    try std.testing.expectError(
        error.RouteRecoveryStopped,
        runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job()),
    );

    try std.testing.expectEqual(@as(usize, 0), hooks.permission_names.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.executed_names.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.finish_event_count);
    try std.testing.expectEqual(@as(usize, 0), hooks.history_turns.items.len);
    try std.testing.expectEqual(@as(usize, 1), hooks.route_recovery_count);
    try std.testing.expectEqual(types.ProviderFinishReason.content_filter, hooks.last_route_recovery_finish_reason.?);
    try std.testing.expectEqual(@as(usize, 1), hooks.route_recovery_statuses.items.len);
    try expectRouteStatus(&hooks, 0, .content_filter, "⚠ blocked · content_filter · content filter");
}

test "processQueuedPrompt retries replay-safe provider errors before success" {
    const alloc = std.testing.allocator;
    const final_chunks = [_][]const u8{"Recovered"};
    const completions = [_]FakeCompletion{
        .{ .finish_reason = .provider_error, .provider_failure_detail = "route failed once" },
        .{ .finish_reason = .provider_error, .provider_failure_detail = "route failed twice" },
        .{ .chunks = &final_chunks, .content = "Recovered" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.gateway_retry_count = 3;
    config.max_provider_attempts = 3;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 3), gateway.request_models.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.route_recovery_count);
    try std.testing.expectEqual(@as(usize, 0), hooks.executed_names.items.len);
    try std.testing.expectEqual(@as(usize, 1), countText(&hooks, "Recovered"));
    try std.testing.expectEqual(@as(usize, 0), hooks.system_notices.items.len);
    try std.testing.expectEqual(@as(usize, 3), hooks.route_recovery_statuses.items.len);
    try expectRouteStatus(&hooks, 0, .auto_retry, "⚠ Provider unavailable · provider_error: route failed once · retrying request · attempt 1/3");
    try expectRouteStatus(&hooks, 1, .auto_retry, "⚠ Provider unavailable · provider_error: route failed twice · retrying request in 1s · attempt 2/3");
    try expectRouteStatus(&hooks, 2, .auto_recovered, "✓ recovered · succeeded on attempt 3/3");
}

test "processQueuedPrompt masks and terminal-encodes provider diagnostics" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{.{
        .finish_reason = .provider_error,
        .provider_failure_detail = "provider_down: AI_GATEWAY_API_KEY=abcdefghijklmnop bad\x1b[31m",
    }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.max_provider_attempts = 1;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 1), hooks.route_recovery_statuses.items.len);
    try expectRouteStatus(
        &hooks,
        0,
        .terminal_provider_error,
        "⚠ Provider unavailable · provider_down: AI_GATEWAY_API_KEY=[redacted] bad\\x1b[31m · recovery paused after 1/1 attempts",
    );
}

test "processQueuedPrompt cancellation during provider backoff finishes interrupted" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{
        .{ .finish_reason = .provider_error },
        .{ .content = "must not send" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    hooks.cancel_on_auto_retry_status = &fixture.cancel_flag;
    var config = fixture.config();
    config.max_provider_attempts = 3;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 1), gateway.request_models.items.len);
    try std.testing.expectEqual(types.TurnPresentationOutcome.interrupted, hooks.finalized_outcome.?);
    try std.testing.expectEqual(@as(usize, 1), hooks.interrupted_history_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.route_recovery_clear_count);
}

test "processQueuedPrompt cancellation during HTTP backoff finishes interrupted" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{
        .{ .status = .service_unavailable },
        .{ .content = "must not send" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.enable_recovery_checkpoint = true;
    defer hooks.deinit();
    var fixture = PromptFixture{};
    hooks.cancel_on_auto_retry_status = &fixture.cancel_flag;
    var config = fixture.config();
    config.max_provider_attempts = 3;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 1), gateway.request_models.items.len);
    try std.testing.expectEqual(types.TurnPresentationOutcome.interrupted, hooks.finalized_outcome.?);
    try std.testing.expectEqual(@as(usize, 1), hooks.interrupted_history_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.route_recovery_clear_count);
    const checkpoint = hooks.recovery_checkpoints.items[hooks.recovery_checkpoints.items.len - 1];
    try std.testing.expectEqual(@as(usize, 1), checkpoint.consumed_provider_attempts);
    try std.testing.expect(!checkpoint.outstanding_reservation);
}

test "processQueuedPrompt cancellation during network backoff clears retry status" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{
        .{ .stream_error = error.ReadFailed },
        .{ .content = "must not send" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    hooks.cancel_on_auto_retry_status = &fixture.cancel_flag;
    var config = fixture.config();
    config.max_provider_attempts = 3;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 1), gateway.request_models.items.len);
    try std.testing.expectEqual(types.TurnPresentationOutcome.interrupted, hooks.finalized_outcome.?);
    try std.testing.expectEqual(@as(usize, 1), hooks.interrupted_history_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.route_recovery_statuses.items.len);
    try std.testing.expectEqual(@as(usize, 1), hooks.route_recovery_clear_count);
}

test "processQueuedPrompt disables provider option fast after a replay safe SSE failure" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{
        .{ .finish_reason = .provider_error },
        .{ .content = "Recovered" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    const overrides = [_]ModelCapabilityOverride{.{
        .model = "anthropic/claude-opus-4.6",
        .capabilities = model_capabilities.resolveCapabilities("anthropic/claude-opus-4.6", .{ .supports_fast_mode = true }),
    }};
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.capability_overrides = &overrides;
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.fast_mode = true;
    config.max_provider_attempts = 2;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 2), gateway.request_models.items.len);
    try expectBodyContains(&gateway, 0, "\"providerOptions\":{\"gateway\":{\"speed\":\"fast\"}}");
    try expectRootFieldAbsent(&gateway, 0, "fast");
    try expectRootFieldAbsent(&gateway, 1, "providerOptions");
}

test "processQueuedPrompt disables provider option fast after a replay safe HTTP failure" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{
        .{ .status = .service_unavailable },
        .{ .content = "Recovered" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    const overrides = [_]ModelCapabilityOverride{.{
        .model = "anthropic/claude-opus-4.6",
        .capabilities = model_capabilities.resolveCapabilities("anthropic/claude-opus-4.6", .{ .supports_fast_mode = true }),
    }};
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.capability_overrides = &overrides;
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.fast_mode = true;
    config.max_provider_attempts = 2;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 2), gateway.request_models.items.len);
    try expectBodyContains(&gateway, 0, "\"providerOptions\":{\"gateway\":{\"speed\":\"fast\"}}");
    try expectRootFieldAbsent(&gateway, 0, "fast");
    try expectRootFieldAbsent(&gateway, 1, "providerOptions");
}

test "processQueuedPrompt retries directly selected intrinsic fast model without rewriting its ID" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{
        .{ .finish_reason = .provider_error },
        .{ .content = "Recovered" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.enable_recovery_checkpoint = true;
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.max_provider_attempts = 2;
    var job = fixture.job();
    job.model = @constCast("zai/glm-5.2-fast");

    try runFakePrompt(&gateway, &hooks, config, job);

    try std.testing.expectEqual(@as(usize, 2), gateway.request_models.items.len);
    try std.testing.expectEqualStrings("zai/glm-5.2-fast", gateway.request_models.items[0]);
    try std.testing.expectEqualStrings("zai/glm-5.2-fast", gateway.request_models.items[1]);
}

test "processQueuedPrompt HTTP retry preserves directly selected intrinsic fast model ID" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{
        .{ .status = .service_unavailable },
        .{ .content = "Recovered" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.max_provider_attempts = 2;
    var job = fixture.job();
    job.model = @constCast("zai/glm-5.2-fast");

    try runFakePrompt(&gateway, &hooks, config, job);

    try std.testing.expectEqual(@as(usize, 2), gateway.request_models.items.len);
    try std.testing.expectEqualStrings("zai/glm-5.2-fast", gateway.request_models.items[0]);
    try std.testing.expectEqualStrings("zai/glm-5.2-fast", gateway.request_models.items[1]);
}

test "processQueuedPrompt retries replay-safe ReadFailed before success" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "read-failed-retry-trace.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "gateway");

    const final_chunks = [_][]const u8{"Recovered"};
    const completions = [_]FakeCompletion{
        .{ .stream_error = error.ReadFailed },
        .{ .chunks = &final_chunks, .content = "Recovered" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.gateway_retry_count = 3;
    config.max_provider_attempts = 3;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());
    debug_trace.shutdown();

    try std.testing.expectEqual(@as(usize, 2), gateway.request_models.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.executed_names.items.len);
    try std.testing.expectEqual(@as(usize, 1), countText(&hooks, "Recovered"));
    try std.testing.expectEqual(@as(usize, 0), hooks.system_notices.items.len);
    try std.testing.expectEqual(@as(usize, 2), hooks.route_recovery_statuses.items.len);
    try expectRouteStatus(&hooks, 0, .auto_retry, "⚠ Network interrupted · ReadFailed · retrying request · attempt 1/3");
    try expectRouteStatus(&hooks, 1, .auto_recovered, "✓ recovered · succeeded on attempt 2/3");

    const trace = try readTraceFile(alloc, trace_path, 65536);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "event=stream_error") != null);
    try std.testing.expect(std.mem.find(u8, trace, "err=ReadFailed") != null);
    try std.testing.expect(std.mem.find(u8, trace, "provider_attempts=1/3") != null);
    try std.testing.expect(std.mem.find(u8, trace, "replay_safe=true") != null);
    try std.testing.expect(std.mem.find(u8, trace, "retry=true") != null);
}

test "processQueuedPrompt counts and retries a definitely unsent native setup failure" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{
        .{ .pre_send_error = error.TlsInitializationFailed },
        .{ .content = "Recovered after setup" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.enable_recovery_checkpoint = true;
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.max_provider_attempts = 2;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 2), gateway.request_models.items.len);
    try std.testing.expectEqual(@as(usize, 4), hooks.recovery_checkpoints.items.len);
    try std.testing.expectEqual(
        @as(usize, 1),
        hooks.recovery_checkpoints.items[1].consumed_provider_attempts,
    );
    try std.testing.expect(!hooks.recovery_checkpoints.items[1].outstanding_reservation);
    try expectRouteStatus(
        &hooks,
        0,
        .auto_retry,
        "⚠ Network interrupted · TlsInitializationFailed · retrying request · attempt 1/2",
    );
    try expectRouteStatus(
        &hooks,
        1,
        .auto_recovered,
        "✓ recovered · succeeded on attempt 2/2",
    );
}

test "processQueuedPrompt routes native network failure classes through one heartbeat" {
    const alloc = std.testing.allocator;
    const Stage = enum { before_send, after_send };
    const Case = struct {
        err: anyerror,
        stage: Stage,
        cause: types.ModelRecoveryCause = .network_interrupted,
    };
    const cases = [_]Case{
        .{ .err = error.TlsInitializationFailed, .stage = .before_send },
        .{ .err = error.UnknownHostName, .stage = .before_send },
        .{ .err = error.ConnectionRefused, .stage = .before_send },
        .{ .err = error.WriteFailed, .stage = .after_send },
        .{ .err = error.ReadFailed, .stage = .after_send },
        .{ .err = error.ConnectionResetByPeer, .stage = .after_send },
        .{ .err = error.SystemResumed, .stage = .after_send, .cause = .system_resumed },
    };

    for (cases) |case| {
        var completions = [_]FakeCompletion{
            .{},
            .{ .content = "Recovered" },
        };
        switch (case.stage) {
            .before_send => completions[0].pre_send_error = case.err,
            .after_send => completions[0].stream_error = case.err,
        }

        var gateway = FakeGateway.init(alloc, &completions);
        defer gateway.deinit();
        var hooks = FakeAgentRuntimeDeps.init(alloc);
        defer hooks.deinit();
        var fixture = PromptFixture{};
        var config = fixture.config();
        config.max_provider_attempts = 2;

        try runFakePrompt(&gateway, &hooks, config, fixture.job());

        try std.testing.expectEqual(@as(usize, 2), gateway.request_models.items.len);
        try std.testing.expectEqual(@as(usize, 2), hooks.route_recovery_statuses.items.len);
        try std.testing.expectEqual(types.RouteRecoveryStatus.Kind.auto_retry, hooks.route_recovery_statuses.items[0].kind);
        try std.testing.expectEqual(case.cause, hooks.route_recovery_statuses.items[0].cause.?);
        try std.testing.expectEqual(@as(usize, 1), hooks.route_recovery_statuses.items[0].failed_attempt);
        try std.testing.expectEqual(types.RouteRecoveryStatus.Kind.auto_recovered, hooks.route_recovery_statuses.items[1].kind);
        try std.testing.expectEqual(@as(usize, 2), hooks.route_recovery_statuses.items[1].succeeded_attempt);
    }
}

test "processQueuedPrompt starts network pacing independently from the shared retry budget" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{
        .{ .status = .service_unavailable, .retry_after_seconds = 0 },
        .{ .status = .service_unavailable, .retry_after_seconds = 0 },
        .{ .status = .service_unavailable, .retry_after_seconds = 0 },
        .{ .status = .service_unavailable, .retry_after_seconds = 0 },
        .{ .status = .service_unavailable, .retry_after_seconds = 0 },
        .{ .stream_error = error.ReadFailed },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    hooks.cancel_on_auto_retry_status = &fixture.cancel_flag;
    hooks.cancel_on_auto_retry_attempt = 6;

    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

    try std.testing.expectEqual(@as(usize, 6), gateway.request_models.items.len);
    try std.testing.expectEqual(@as(usize, 6), hooks.route_recovery_statuses.items.len);
    const network_status = hooks.route_recovery_statuses.items[5];
    try std.testing.expectEqual(types.RouteRecoveryStatus.Kind.auto_retry, network_status.kind);
    try std.testing.expectEqual(types.ModelRecoveryCause.network_interrupted, network_status.cause.?);
    try std.testing.expectEqual(@as(usize, 6), network_status.failed_attempt);
    try std.testing.expectEqual(@as(u64, 0), network_status.delay_seconds);
}

test "processQueuedPrompt does not retry opaque JS host stream failures" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{.{ .stream_error = error.JsHostStreamFailed }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};

    try std.testing.expectError(
        error.JsHostStreamFailed,
        runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job()),
    );

    try std.testing.expectEqual(@as(usize, 1), gateway.request_models.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.route_recovery_statuses.items.len);
}

test "processQueuedPrompt reserves and settles durable attempts before history commit cleanup" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{.{ .content = "Done" }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.enable_recovery_checkpoint = true;
    defer hooks.deinit();
    var fixture = PromptFixture{};

    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

    try std.testing.expectEqual(@as(usize, 1), gateway.request_models.items.len);
    try std.testing.expectEqual(@as(usize, 2), hooks.recovery_checkpoints.items.len);
    const reserved = hooks.recovery_checkpoints.items[0];
    try std.testing.expect(reserved.outstanding_reservation);
    try std.testing.expectEqual(@as(usize, 0), reserved.consumed_provider_attempts);
    const settled = hooks.recovery_checkpoints.items[1];
    try std.testing.expect(!settled.outstanding_reservation);
    try std.testing.expectEqual(@as(usize, 1), settled.consumed_provider_attempts);
    try std.testing.expectEqual(@as(usize, 1), hooks.history_propagation_count);
}

test "processQueuedPrompt does not consume cancellation before provider admission" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{.{ .content = "must not send" }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.enable_recovery_checkpoint = true;
    defer hooks.deinit();
    var fixture = PromptFixture{};
    hooks.cancel_on_recovery_reservation = &fixture.cancel_flag;

    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

    try std.testing.expectEqual(@as(usize, 0), gateway.request_models.items.len);
    try std.testing.expectEqual(@as(usize, 2), hooks.recovery_checkpoints.items.len);
    const reserved = hooks.recovery_checkpoints.items[0];
    try std.testing.expect(reserved.outstanding_reservation);
    try std.testing.expectEqual(@as(usize, 0), reserved.consumed_provider_attempts);
    const settled = hooks.recovery_checkpoints.items[1];
    try std.testing.expect(!settled.outstanding_reservation);
    try std.testing.expectEqual(@as(usize, 0), settled.consumed_provider_attempts);
    try std.testing.expectEqual(@as(usize, 1), hooks.interrupted_history_count);
}

test "processQueuedPrompt carries one durable budget across transport recovery" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{
        .{ .stream_error = error.ReadFailed },
        .{ .content = "Recovered" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.enable_recovery_checkpoint = true;
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.max_provider_attempts = 2;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 2), gateway.request_models.items.len);
    try std.testing.expectEqual(@as(usize, 4), hooks.recovery_checkpoints.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.recovery_checkpoints.items[0].consumed_provider_attempts);
    try std.testing.expect(hooks.recovery_checkpoints.items[0].outstanding_reservation);
    try std.testing.expectEqual(@as(usize, 1), hooks.recovery_checkpoints.items[1].consumed_provider_attempts);
    try std.testing.expect(!hooks.recovery_checkpoints.items[1].outstanding_reservation);
    try std.testing.expectEqual(@as(usize, 1), hooks.recovery_checkpoints.items[2].consumed_provider_attempts);
    try std.testing.expect(hooks.recovery_checkpoints.items[2].outstanding_reservation);
    try std.testing.expectEqual(@as(usize, 2), hooks.recovery_checkpoints.items[3].consumed_provider_attempts);
    try std.testing.expectEqual(@as(usize, 1), hooks.history_propagation_count);
}

test "processQueuedPrompt preserves fallback route and budget until selection changes" {
    const alloc = std.testing.allocator;
    var fixture = PromptFixture{};
    const checkpoint = session_codec.RecoveryCheckpoint{
        .turn_id = 44,
        .user = .{ .text = @constCast("user prompt") },
        .assistant_source = @constCast("partial"),
        .cause = .provider_unavailable,
        .action = .paused,
        .route_model = @constCast("zai/glm-5.2"),
        .requested_fast_mode = true,
        .fast_mode = false,
        .max_provider_attempts = 10,
        .consumed_provider_attempts = 3,
    };

    {
        const completions = [_]FakeCompletion{.{ .content = "partial recovered" }};
        var gateway = FakeGateway.init(alloc, &completions);
        defer gateway.deinit();
        var hooks = FakeAgentRuntimeDeps.init(alloc);
        hooks.enable_recovery_checkpoint = true;
        defer hooks.deinit();
        var config = fixture.config();
        config.fast_mode = true;
        config.max_provider_attempts = 4;
        var job = fixture.job();
        job.model = @constCast("zai/glm-5.2");
        job.recovery_checkpoint = checkpoint;

        try runFakePrompt(&gateway, &hooks, config, job);

        try std.testing.expectEqualStrings("zai/glm-5.2", gateway.request_models.items[0]);
        const reserved = hooks.recovery_checkpoints.items[0];
        try std.testing.expectEqual(@as(usize, 10), reserved.max_provider_attempts);
        try std.testing.expectEqual(@as(usize, 3), reserved.consumed_provider_attempts);
        try std.testing.expect(reserved.requested_fast_mode);
        try std.testing.expect(!reserved.fast_mode);
    }

    {
        const completions = [_]FakeCompletion{.{ .content = "partial recovered" }};
        var gateway = FakeGateway.init(alloc, &completions);
        defer gateway.deinit();
        var hooks = FakeAgentRuntimeDeps.init(alloc);
        hooks.enable_recovery_checkpoint = true;
        defer hooks.deinit();
        var config = fixture.config();
        config.fast_mode = false;
        config.max_provider_attempts = 4;
        var job = fixture.job();
        job.model = @constCast("zai/glm-5.2");
        job.recovery_checkpoint = checkpoint;

        try runFakePrompt(&gateway, &hooks, config, job);

        const reserved = hooks.recovery_checkpoints.items[0];
        try std.testing.expectEqual(@as(usize, 4), reserved.max_provider_attempts);
        try std.testing.expectEqual(@as(usize, 0), reserved.consumed_provider_attempts);
        try std.testing.expect(!reserved.requested_fast_mode);
        try std.testing.expect(!reserved.fast_mode);
    }
}

test "processQueuedPrompt restores legacy connectivity checkpoints through evidence" {
    const alloc = std.testing.allocator;
    var fixture = PromptFixture{};
    const checkpoint = session_codec.RecoveryCheckpoint{
        .turn_id = 45,
        .user = .{ .text = @constCast("user prompt") },
        .assistant_source = @constCast("partial response"),
        .cause = .system_resumed,
        .action = .waiting_for_connectivity,
        .route_model = @constCast("zai/glm-5.2"),
        .requested_fast_mode = false,
        .fast_mode = false,
        .max_provider_attempts = 10,
        .consumed_provider_attempts = 3,
    };
    const completions = [_]FakeCompletion{.{ .content = "continued response" }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.enable_recovery_checkpoint = true;
    defer hooks.deinit();
    var job = fixture.job();
    job.model = @constCast("zai/glm-5.2");
    job.recovery_checkpoint = checkpoint;

    try runFakePrompt(&gateway, &hooks, fixture.config(), job);

    try std.testing.expectEqual(@as(usize, 1), gateway.request_models.items.len);
    try std.testing.expect(std.mem.find(
        u8,
        gateway.request_bodies.items[0],
        "<partial_assistant>\\npartial response\\n</partial_assistant>",
    ) != null);
    const reserved = hooks.recovery_checkpoints.items[0];
    try std.testing.expectEqual(@as(usize, 3), reserved.consumed_provider_attempts);
    try std.testing.expect(reserved.outstanding_reservation);
    for (hooks.route_recovery_statuses.items) |status| {
        try std.testing.expect(status.action != .waiting_for_connectivity);
    }
}

test "processQueuedPrompt counts only failed provider attempts across tool followups" {
    const alloc = std.testing.allocator;
    const first_calls = [_]ToolCall{
        toolCall("call_first", "read_file", "{\"path\":\"first.txt\"}"),
    };
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &first_calls },
        .{ .status = .bad_gateway, .err_body = "gateway unavailable" },
        .{ .status = .bad_gateway, .err_body = "gateway unavailable" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.enable_recovery_checkpoint = true;
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.max_provider_attempts = 2;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 3), gateway.request_models.items.len);
    try std.testing.expectEqual(@as(usize, 1), hooks.executed_names.items.len);
    try std.testing.expectEqual(types.TurnPresentationOutcome.paused, hooks.finalized_outcome.?);
    const checkpoint = hooks.recovery_checkpoints.items[hooks.recovery_checkpoints.items.len - 1];
    try std.testing.expectEqual(@as(usize, 2), checkpoint.consumed_provider_attempts);
    try std.testing.expect(!checkpoint.outstanding_reservation);
    try std.testing.expectEqual(@as(usize, 1), checkpoint.execution.tool_steps.len);
    try std.testing.expectEqual(types.ModelRecoveryCause.provider_unavailable, checkpoint.cause);
    try expectRouteStatus(&hooks, 1, .terminal_provider_error, "⚠ Provider unavailable · HTTP 502: gateway unavailable · recovery paused after 2/2 attempts");

    var continued_checkpoint = try checkpoint.dupe(alloc);
    defer continued_checkpoint.deinit(alloc);
    const continued_completions = [_]FakeCompletion{.{ .content = "Finished after Continue" }};
    var continued_gateway = FakeGateway.init(alloc, &continued_completions);
    defer continued_gateway.deinit();
    var continued_hooks = FakeAgentRuntimeDeps.init(alloc);
    continued_hooks.enable_recovery_checkpoint = true;
    defer continued_hooks.deinit();
    var continued_job = fixture.job();
    continued_job.recovery_checkpoint = continued_checkpoint;

    try runFakePrompt(&continued_gateway, &continued_hooks, config, continued_job);

    try std.testing.expectEqual(@as(usize, 1), continued_gateway.request_models.items.len);
    try expectBodyContains(&continued_gateway, 0, "call_first");
    try expectBodyContains(&continued_gateway, 0, "Re-run the response for the same user request.");
    try std.testing.expectEqualStrings("Finished after Continue", continued_hooks.history_assistant_text.?);
}

test "processQueuedPrompt explicit checkpoint continuation starts a fresh exhausted budget" {
    const alloc = std.testing.allocator;
    const partial_chunks = [_][]const u8{"partial"};
    const interrupted = [_]FakeCompletion{.{
        .chunks = &partial_chunks,
        .stream_error_after_chunks = error.ReadFailed,
    }};
    var first_gateway = FakeGateway.init(alloc, &interrupted);
    defer first_gateway.deinit();
    var first_hooks = FakeAgentRuntimeDeps.init(alloc);
    first_hooks.enable_recovery_checkpoint = true;
    defer first_hooks.deinit();
    var fixture = PromptFixture{};
    var first_config = fixture.config();
    first_config.max_provider_attempts = 1;

    try runFakePrompt(&first_gateway, &first_hooks, first_config, fixture.job());
    const saved = first_hooks.recovery_checkpoints.items[first_hooks.recovery_checkpoints.items.len - 1];
    var checkpoint = try saved.dupe(alloc);
    defer checkpoint.deinit(alloc);

    const recovered_chunks = [_][]const u8{"partial response finished"};
    const recovered = [_]FakeCompletion{.{
        .chunks = &recovered_chunks,
        .content = "partial response finished",
    }};
    var second_gateway = FakeGateway.init(alloc, &recovered);
    defer second_gateway.deinit();
    var second_hooks = FakeAgentRuntimeDeps.init(alloc);
    second_hooks.enable_recovery_checkpoint = true;
    defer second_hooks.deinit();
    var continued_job = fixture.job();
    continued_job.recovery_checkpoint = checkpoint;
    var continued_config = fixture.config();
    continued_config.max_provider_attempts = 2;

    try runFakePrompt(&second_gateway, &second_hooks, continued_config, continued_job);

    try std.testing.expectEqual(@as(usize, 1), second_gateway.request_models.items.len);
    try expectBodyContains(&second_gateway, 0, "<partial_assistant>\\npartial\\n</partial_assistant>");
    try std.testing.expectEqualStrings("partial response finished", second_hooks.history_assistant_text.?);
    try std.testing.expectEqual(@as(usize, 1), second_hooks.history_propagation_count);
}

test "processQueuedPrompt retries system resume through the heartbeat" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{
        .{ .stream_error = error.SystemResumed },
        .{ .content = "Recovered after resume" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.enable_recovery_checkpoint = true;
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.max_provider_attempts = 2;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 2), gateway.request_models.items.len);
    try std.testing.expectEqual(types.TurnPresentationOutcome.completed, hooks.finalized_outcome.?);
    const checkpoint = hooks.recovery_checkpoints.items[hooks.recovery_checkpoints.items.len - 1];
    try std.testing.expectEqual(types.ModelRecoveryCause.system_resumed, checkpoint.cause);
    try std.testing.expectEqual(@as(usize, 2), checkpoint.consumed_provider_attempts);
    try std.testing.expect(!checkpoint.outstanding_reservation);
    try expectRouteStatus(
        &hooks,
        0,
        .auto_retry,
        "⚠ Mac woke from sleep · SystemResumed · retrying request · attempt 1/2",
    );
}

test "processQueuedPrompt interactive try later pauses instead of cancelling" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{.{ .pause_before_output = true }};
    var pause_flag = std.atomic.Value(bool).init(false);
    var gateway = FakeGateway.init(alloc, &completions);
    gateway.recovery_pause_flag = &pause_flag;
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.enable_recovery_checkpoint = true;
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.recovery_pause_flag = &pause_flag;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 1), gateway.request_models.items.len);
    try std.testing.expectEqual(types.TurnPresentationOutcome.paused, hooks.finalized_outcome.?);
    try std.testing.expectEqual(@as(usize, 0), hooks.interrupted_history_count);
    const checkpoint = hooks.recovery_checkpoints.items[hooks.recovery_checkpoints.items.len - 1];
    try std.testing.expectEqual(@as(usize, 1), checkpoint.consumed_provider_attempts);
    try std.testing.expectEqual(types.ModelRecoveryAction.paused, checkpoint.action);
}

test "processQueuedPrompt try later interrupts heartbeat backoff" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{.{ .stream_error = error.SystemResumed }};
    var pause_flag = std.atomic.Value(bool).init(false);
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.enable_recovery_checkpoint = true;
    hooks.pause_on_auto_retry_status = true;
    hooks.recovery_pause_flag = &pause_flag;
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.recovery_pause_flag = &pause_flag;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 1), gateway.request_models.items.len);
    try std.testing.expectEqual(types.TurnPresentationOutcome.paused, hooks.finalized_outcome.?);
    try std.testing.expectEqual(@as(usize, 0), hooks.interrupted_history_count);
    const checkpoint = hooks.recovery_checkpoints.items[hooks.recovery_checkpoints.items.len - 1];
    try std.testing.expectEqual(types.ModelRecoveryCause.system_resumed, checkpoint.cause);
    try std.testing.expectEqual(types.ModelRecoveryAction.paused, checkpoint.action);
}

test "processQueuedPrompt keeps the settled checkpoint when recovery pauses" {
    const alloc = std.testing.allocator;
    const chunks = [_][]const u8{"partial"};
    const completions = [_]FakeCompletion{.{
        .chunks = &chunks,
        .stream_error_after_chunks = error.ReadFailed,
    }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.enable_recovery_checkpoint = true;
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.max_provider_attempts = 1;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(types.TurnPresentationOutcome.paused, hooks.finalized_outcome.?);
    const checkpoint = hooks.recovery_checkpoints.items[hooks.recovery_checkpoints.items.len - 1];
    try std.testing.expectEqual(@as(usize, 1), checkpoint.consumed_provider_attempts);
    try std.testing.expect(!checkpoint.outstanding_reservation);
    try std.testing.expectEqualStrings("partial", checkpoint.assistant_source);
    try std.testing.expectEqual(types.ModelRecoveryAction.paused, checkpoint.action);
}

test "processQueuedPrompt sends nothing when durable reservation fails" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{.{ .content = "must not send" }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.enable_recovery_checkpoint = true;
    hooks.recovery_checkpoint_error = error.TestCheckpointWriteFailed;
    defer hooks.deinit();
    var fixture = PromptFixture{};

    try std.testing.expectError(
        error.TestCheckpointWriteFailed,
        runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job()),
    );
    try std.testing.expectEqual(@as(usize, 0), gateway.request_models.items.len);
}

test "processQueuedPrompt pauses replay-safe ReadFailed at attempt limit" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{
        .{ .stream_error = error.ReadFailed },
        .{ .stream_error = error.ReadFailed },
        .{ .stream_error = error.ReadFailed },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.gateway_retry_count = 3;
    config.max_provider_attempts = 3;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 3), gateway.request_models.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.executed_names.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.system_notices.items.len);
    try std.testing.expectEqual(types.TurnPresentationOutcome.paused, hooks.finalized_outcome.?);
    try std.testing.expectEqual(@as(usize, 3), hooks.route_recovery_statuses.items.len);
    try expectRouteStatus(&hooks, 0, .auto_retry, "⚠ Network interrupted · ReadFailed · retrying request · attempt 1/3");
    try expectRouteStatus(&hooks, 1, .auto_retry, "⚠ Network interrupted · ReadFailed · retrying request in 1s · attempt 2/3");
    try expectRouteStatus(&hooks, 2, .terminal_provider_error, "⚠ Network interrupted · ReadFailed · recovery paused after 3/3 attempts");
}

test "processQueuedPrompt replaces retry status after a different stream error" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{
        .{ .stream_error = error.ReadFailed },
        .{ .stream_error = error.ConnectionResetByPeer },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.gateway_retry_count = 3;
    config.max_provider_attempts = 2;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 2), gateway.request_models.items.len);
    try std.testing.expectEqual(@as(usize, 2), hooks.route_recovery_statuses.items.len);
    try expectRouteStatus(&hooks, 0, .auto_retry, "⚠ Network interrupted · ReadFailed · retrying request · attempt 1/2");
    try expectRouteStatus(&hooks, 1, .terminal_provider_error, "⚠ Network interrupted · ConnectionResetByPeer · recovery paused after 2/2 attempts");
}

test "processQueuedPrompt clears retry status when a replay is cancelled" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{
        .{ .stream_error = error.ReadFailed },
        .{ .cancel_before_output = true },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.gateway_retry_count = 3;
    config.max_provider_attempts = 3;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 2), gateway.request_models.items.len);
    try std.testing.expectEqual(@as(usize, 1), hooks.route_recovery_statuses.items.len);
    try expectRouteStatus(&hooks, 0, .auto_retry, "⚠ Network interrupted · ReadFailed · retrying request · attempt 1/3");
    try std.testing.expectEqual(@as(usize, 1), hooks.route_recovery_clear_count);
    try std.testing.expectEqual(types.TurnPresentationOutcome.interrupted, hooks.finalized_outcome.?);
}

test "processQueuedPrompt replaces retry status when replay finish is missing" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{
        .{ .stream_error = error.ReadFailed },
        .{ .omit_finish = true },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.gateway_retry_count = 3;
    config.max_provider_attempts = 2;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 2), gateway.request_models.items.len);
    try std.testing.expectEqual(@as(usize, 2), hooks.route_recovery_statuses.items.len);
    try expectRouteStatus(&hooks, 0, .auto_retry, "⚠ Network interrupted · ReadFailed · retrying request · attempt 1/2");
    try expectRouteStatus(&hooks, 1, .terminal_provider_error, "⚠ Response ended early · StreamInterrupted · recovery paused after 2/2 attempts");
}

test "processQueuedPrompt replaces retry status after an invalid replay completion" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{
        .{ .stream_error = error.ReadFailed },
        .{ .finish_reason = .tool_calls },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.gateway_retry_count = 3;
    config.max_provider_attempts = 3;

    try std.testing.expectError(
        error.ModelError,
        runFakePrompt(&gateway, &hooks, config, fixture.job()),
    );

    try std.testing.expectEqual(@as(usize, 2), gateway.request_models.items.len);
    try std.testing.expectEqual(@as(usize, 2), hooks.route_recovery_statuses.items.len);
    try expectRouteStatus(&hooks, 0, .auto_retry, "⚠ Network interrupted · ReadFailed · retrying request · attempt 1/3");
    try expectRouteStatus(&hooks, 1, .terminal_provider_error, "⚠ Provider unavailable · InvalidProviderCompletion · recovery paused after 2/3 attempts");
}

test "processQueuedPrompt pauses ReadFailed after assistant source is published" {
    const alloc = std.testing.allocator;
    const chunks = [_][]const u8{"partial"};
    const repeated_chunks = [_][]const u8{"partial response"};
    const completions = [_]FakeCompletion{
        .{
            .chunks = &chunks,
            .stream_error_after_chunks = error.ReadFailed,
        },
        .{
            .chunks = &repeated_chunks,
            .content = "partial response",
        },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.gateway_retry_count = 1;
    config.max_provider_attempts = 1;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 1), gateway.request_models.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.executed_names.items.len);
    try std.testing.expectEqual(@as(usize, 1), hooks.route_recovery_statuses.items.len);
    try expectRouteStatus(&hooks, 0, .terminal_provider_error, "⚠ Network interrupted · ReadFailed · recovery paused after 1/1 attempts");
    try std.testing.expectEqual(@as(usize, 1), countText(&hooks, "partial"));
    try std.testing.expectEqual(@as(usize, 0), hooks.history_turns.items.len);
    try std.testing.expectEqual(types.TurnPresentationOutcome.paused, hooks.finalized_outcome.?);
    try std.testing.expectEqual(@as(usize, 0), hooks.finish_event_count);
}

test "processQueuedPrompt preserves whitespace source bytes in a paused response" {
    const alloc = std.testing.allocator;
    const chunks = [_][]const u8{" \n"};
    const completions = [_]FakeCompletion{
        .{
            .chunks = &chunks,
            .stream_error_after_chunks = error.ReadFailed,
        },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.gateway_retry_count = 1;
    config.max_provider_attempts = 1;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 1), gateway.request_models.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.executed_names.items.len);
    try std.testing.expectEqual(@as(usize, 1), hooks.route_recovery_statuses.items.len);
    try expectRouteStatus(&hooks, 0, .terminal_provider_error, "⚠ Network interrupted · ReadFailed · recovery paused after 1/1 attempts");
    try std.testing.expectEqual(types.TurnPresentationOutcome.paused, hooks.finalized_outcome.?);
}

test "processQueuedPrompt pauses a local tool after assistant source when budget is exhausted" {
    const alloc = std.testing.allocator;
    const chunks = [_][]const u8{"I will read it."};
    const starts = [_]ToolCall{toolCall("call_read_interrupted", "read_file", "{}")};
    const completions = [_]FakeCompletion{.{
        .chunks = &chunks,
        .streamed_tool_starts = &starts,
        .stream_error_after_tool_starts = error.ReadFailed,
    }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.gateway_retry_count = 1;
    config.max_provider_attempts = 1;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 1), gateway.request_models.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.executed_names.items.len);
    try expectRouteStatus(&hooks, 0, .terminal_provider_error, "⚠ Network interrupted · ReadFailed · recovery paused after 1/1 attempts");
    try std.testing.expectEqual(@as(usize, 0), hooks.history_turns.items.len);
    try std.testing.expectEqual(types.TurnPresentationOutcome.paused, hooks.finalized_outcome.?);
}

test "processQueuedPrompt cancellation absorbs ReadFailed after published source" {
    const alloc = std.testing.allocator;
    const chunks = [_][]const u8{"partial cancelled"};
    const completions = [_]FakeCompletion{.{
        .chunks = &chunks,
        .cancel_after_chunks = true,
        .stream_error_after_chunks = error.ReadFailed,
    }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.gateway_retry_count = 3;
    config.max_provider_attempts = 3;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 1), gateway.request_models.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.route_recovery_statuses.items.len);
    try std.testing.expectEqual(@as(usize, 1), hooks.history_turns.items.len);
    try std.testing.expectEqualStrings(
        "partial cancelled",
        hooks.history_turns.items[0].interrupted.assistant.?,
    );
    try std.testing.expectEqual(types.TurnPresentationOutcome.interrupted, hooks.finalized_outcome.?);
}

test "processQueuedPrompt regenerates and executes a local tool once after ReadFailed" {
    const alloc = std.testing.allocator;
    const interrupted_starts = [_]ToolCall{toolCall("call_read_interrupted", "read_file", "{}")};
    const recovered_calls = [_]ToolCall{toolCall("call_read_recovered", "read_file", "{\"path\":\"a\"}")};
    const final_chunks = [_][]const u8{"Finished"};
    const completions = [_]FakeCompletion{
        .{
            .streamed_tool_starts = &interrupted_starts,
            .stream_error_after_tool_starts = error.ReadFailed,
        },
        .{
            .streamed_tool_starts = &recovered_calls,
            .tool_calls = &recovered_calls,
        },
        .{
            .chunks = &final_chunks,
            .content = "Finished",
        },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.gateway_retry_count = 3;
    config.max_provider_attempts = 3;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 3), gateway.request_models.items.len);
    try std.testing.expectEqual(@as(usize, 1), hooks.executed_names.items.len);
    try std.testing.expectEqualStrings("read_file", hooks.executed_names.items[0]);
    try std.testing.expectEqualStrings("call_read_recovered", hooks.executed_call_ids.items[0]);
    try std.testing.expectEqual(@as(usize, 2), hooks.route_recovery_statuses.items.len);
    try expectRouteStatus(&hooks, 0, .auto_retry, "⚠ Network interrupted · ReadFailed · regenerating unstarted tool · attempt 1/3");
    try expectRouteStatus(&hooks, 1, .auto_recovered, "✓ recovered · succeeded on attempt 2/3");
    try expectBodyContains(&gateway, 1, "did not execute the incomplete tool call");
    try expectBodyContains(&gateway, 2, "call_read_recovered");
    try expectBodyContains(&gateway, 2, "\"output\":{\"type\":\"text\",\"value\":\"ok\"}");
    try expectFailedLifecycleContains(
        hooks.lifecycle_events.items,
        "call_read_interrupted",
        "before read_file ran",
    );
    try std.testing.expectEqualStrings("Finished", hooks.history_turns.items[0].assistant.assistant);
}

test "processQueuedPrompt settles an interrupted local tool after a different stream error" {
    const alloc = std.testing.allocator;
    const starts = [_]ToolCall{toolCall("call_read_interrupted", "read_file", "{}")};
    const completions = [_]FakeCompletion{
        .{
            .streamed_tool_starts = &starts,
            .stream_error_after_tool_starts = error.ReadFailed,
        },
        .{ .stream_error = error.ConnectionResetByPeer },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.gateway_retry_count = 3;
    config.max_provider_attempts = 2;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 2), gateway.request_models.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.executed_names.items.len);
    try expectRouteStatus(&hooks, 0, .auto_retry, "⚠ Network interrupted · ReadFailed · regenerating unstarted tool · attempt 1/2");
    try expectRouteStatus(&hooks, 1, .terminal_provider_error, "⚠ Network interrupted · ConnectionResetByPeer · recovery paused after 2/2 attempts");
    try expectFailedLifecycleContains(
        hooks.lifecycle_events.items,
        "call_read_interrupted",
        "before read_file ran",
    );
}

test "processQueuedPrompt settles an interrupted local tool after an HTTP failure" {
    const alloc = std.testing.allocator;
    const starts = [_]ToolCall{toolCall("call_read_interrupted", "read_file", "{}")};
    const completions = [_]FakeCompletion{
        .{
            .streamed_tool_starts = &starts,
            .stream_error_after_tool_starts = error.ReadFailed,
        },
        .{ .status = .bad_gateway, .err_body = "upstream failed" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.gateway_retry_count = 3;
    config.max_provider_attempts = 2;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 2), gateway.request_models.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.executed_names.items.len);
    try std.testing.expectEqual(@as(?std.http.Status, null), hooks.http_status);
    try std.testing.expectEqual(types.TurnPresentationOutcome.paused, hooks.finalized_outcome.?);
    try expectFailedLifecycleContains(
        hooks.lifecycle_events.items,
        "call_read_interrupted",
        "before read_file ran",
    );
}

test "processQueuedPrompt cancels a carried local tool start" {
    const alloc = std.testing.allocator;
    const starts = [_]ToolCall{toolCall("call_read_interrupted", "read_file", "{}")};
    const completions = [_]FakeCompletion{
        .{
            .streamed_tool_starts = &starts,
            .stream_error_after_tool_starts = error.ReadFailed,
        },
        .{ .cancel_before_output = true },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.gateway_retry_count = 3;
    config.max_provider_attempts = 3;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 2), gateway.request_models.items.len);
    try std.testing.expectEqual(types.TurnPresentationOutcome.interrupted, hooks.finalized_outcome.?);
    for (hooks.lifecycle_events.items) |event| {
        if (event != .terminal) continue;
        const terminal = event.terminal;
        if (!std.mem.eql(u8, terminal.id.call_id, "call_read_interrupted")) continue;
        try std.testing.expectEqual(types.ToolOutcomeKind.cancelled, terminal.outcome.kind);
        return;
    }
    return error.TestExpectedEqual;
}

test "processQueuedPrompt reconciles a regenerated local tool with the same stream id" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{toolCall("call_read_same", "read_file", "{\"path\":\"a\"}")};
    const final_chunks = [_][]const u8{"Finished"};
    const completions = [_]FakeCompletion{
        .{
            .streamed_tool_starts = &calls,
            .stream_error_after_tool_starts = error.ReadFailed,
        },
        .{
            .streamed_tool_starts = &calls,
            .tool_calls = &calls,
        },
        .{
            .chunks = &final_chunks,
            .content = "Finished",
        },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.gateway_retry_count = 3;
    config.max_provider_attempts = 3;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 1), hooks.executed_names.items.len);
    try std.testing.expectEqualStrings("call_read_same", hooks.executed_call_ids.items[0]);
    var completed_terminal_count: usize = 0;
    var interrupted_terminal_count: usize = 0;
    for (hooks.lifecycle_events.items) |event| {
        switch (event) {
            .terminal => |terminal| {
                if (!std.mem.eql(u8, terminal.id.call_id, "call_read_same")) continue;
                if (terminal.outcome.kind == .completed) completed_terminal_count += 1;
                if (std.mem.find(u8, terminal.outcome.summary, "Connection interrupted") != null) {
                    interrupted_terminal_count += 1;
                }
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), completed_terminal_count);
    try std.testing.expectEqual(@as(usize, 0), interrupted_terminal_count);
}

test "processQueuedPrompt reconciles ReadFailed after provider-executed tool start" {
    const alloc = std.testing.allocator;
    const starts = [_]ToolCall{toolCall("call_search", "web_search", "{}")};
    const completions = [_]FakeCompletion{
        .{
            .streamed_tool_starts = &starts,
            .stream_error_after_tool_starts = error.ReadFailed,
        },
        .{ .content = "Reconciled" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.gateway_retry_count = 3;
    config.max_provider_attempts = 2;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 2), gateway.request_models.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.executed_names.items.len);
    try std.testing.expectEqual(@as(usize, 2), hooks.route_recovery_statuses.items.len);
    try expectRouteStatus(&hooks, 0, .auto_retry, "⚠ Network interrupted · ReadFailed · checking uncertain tool state · attempt 1/2");
    try expectRouteStatus(&hooks, 1, .auto_recovered, "✓ recovered · succeeded on attempt 2/2");
}

test "processQueuedPrompt continues provider error after visible text without duplication" {
    const alloc = std.testing.allocator;
    const chunks = [_][]const u8{"partial"};
    const recovered_chunks = [_][]const u8{"partial response"};
    const completions = [_]FakeCompletion{
        .{
            .chunks = &chunks,
            .content = "partial",
            .finish_reason = .provider_error,
            .provider_failure_detail = "failed after text",
        },
        .{ .chunks = &recovered_chunks, .content = "partial response" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.gateway_retry_count = 3;
    config.max_provider_attempts = 2;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 2), gateway.request_models.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.route_recovery_count);
    try std.testing.expectEqual(@as(usize, 1), countText(&hooks, "partial"));
    try std.testing.expectEqual(@as(usize, 0), hooks.system_notices.items.len);
    try std.testing.expectEqual(@as(usize, 2), hooks.route_recovery_statuses.items.len);
    try expectRouteStatus(&hooks, 0, .auto_retry, "⚠ Provider unavailable · provider_error: failed after text · continuing response · attempt 1/2");
    try expectRouteStatus(&hooks, 1, .auto_recovered, "✓ recovered · succeeded on attempt 2/2");
    try std.testing.expectEqualStrings("partial response", hooks.history_turns.items[0].assistant.assistant);
}

test "processQueuedPrompt recovers provider error after streamed tool start" {
    const alloc = std.testing.allocator;
    const starts = [_]ToolCall{toolCall("call_read", "read_file", "{}")};
    const completions = [_]FakeCompletion{
        .{
            .streamed_tool_starts = &starts,
            .finish_reason = .provider_error,
            .provider_failure_detail = "failed after tool start",
        },
        .{ .content = "Recovered without the tool" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.gateway_retry_count = 3;
    config.max_provider_attempts = 2;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 2), gateway.request_models.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.route_recovery_count);
    try std.testing.expectEqual(@as(usize, 0), hooks.executed_names.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.system_notices.items.len);
    try std.testing.expectEqual(@as(usize, 2), hooks.route_recovery_statuses.items.len);
    try expectRouteStatus(&hooks, 0, .auto_retry, "⚠ Provider unavailable · provider_error: failed after tool start · regenerating unstarted tool · attempt 1/2");
    try expectRouteStatus(&hooks, 1, .auto_recovered, "✓ recovered · succeeded on attempt 2/2");
}

test "processQueuedPrompt routes content filter to local recovery without replay" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{.{
        .finish_reason = .content_filter,
        .provider_failure_detail = "content_filter: filtered",
    }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.gateway_retry_count = 3;
    config.max_provider_attempts = 3;

    try std.testing.expectError(
        error.RouteRecoveryStopped,
        runFakePrompt(&gateway, &hooks, config, fixture.job()),
    );

    try std.testing.expectEqual(@as(usize, 1), gateway.request_models.items.len);
    try std.testing.expectEqual(@as(usize, 1), hooks.route_recovery_count);
    try std.testing.expect(!hooks.last_route_recovery_replay_safe);
    try std.testing.expectEqual(types.ProviderFinishReason.content_filter, hooks.last_route_recovery_finish_reason.?);
    try std.testing.expectEqual(@as(usize, 0), hooks.system_notices.items.len);
    try std.testing.expectEqual(@as(usize, 1), hooks.route_recovery_statuses.items.len);
    try expectRouteStatus(&hooks, 0, .content_filter, "⚠ blocked · content_filter: filtered · content filter");
}

test "processQueuedPrompt disable Fast recovery retries the same exact model" {
    const alloc = std.testing.allocator;
    const final_chunks = [_][]const u8{"Recovered without Fast"};
    const completions = [_]FakeCompletion{
        .{ .finish_reason = .provider_error, .provider_failure_detail = "fast route failed" },
        .{ .chunks = &final_chunks, .content = "Recovered without Fast" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    const efforts = [_]types.ReasoningEffort{types.ReasoningEffort.literal("high")};
    const capability_overrides = [_]ModelCapabilityOverride{.{
        .model = "zai/glm-5.2",
        .capabilities = model_capabilities.resolveCapabilities(
            "zai/glm-5.2",
            .{
                .reasoning_efforts = .fromSlice(&efforts),
                .supports_fast_mode = true,
            },
        ),
    }};
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.capability_overrides = &capability_overrides;
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.fast_mode = true;
    config.effort = types.ReasoningEffort.literal("high");
    config.gateway_retry_count = 1;
    config.max_provider_attempts = 2;
    var job = fixture.job();
    job.model = @constCast("zai/glm-5.2");

    try runFakePrompt(&gateway, &hooks, config, job);

    try std.testing.expectEqual(@as(usize, 2), gateway.request_models.items.len);
    try std.testing.expectEqualStrings("zai/glm-5.2", gateway.request_models.items[0]);
    try std.testing.expectEqualStrings("zai/glm-5.2", gateway.request_models.items[1]);
    try expectBodyContains(&gateway, 0, "\"providerOptions\":{\"gateway\":{\"speed\":\"fast\"}}");
    try expectRootFieldAbsent(&gateway, 0, "fast");
    try expectRootFieldAbsent(&gateway, 1, "providerOptions");
    try std.testing.expectEqual(@as(usize, 1), hooks.capability_queries.items.len);
    try std.testing.expectEqualStrings("zai/glm-5.2", hooks.capability_queries.items[0]);
    try std.testing.expectEqual(@as(usize, 0), hooks.route_recovery_count);
    try std.testing.expectEqual(@as(usize, 1), countText(&hooks, "Recovered without Fast"));
    try std.testing.expectEqual(@as(usize, 0), hooks.system_notices.items.len);
    try std.testing.expectEqual(@as(usize, 2), hooks.route_recovery_statuses.items.len);
    try expectRouteStatus(&hooks, 0, .auto_retry, "⚠ Provider unavailable · provider_error: fast route failed · retrying request · attempt 1/2");
    try expectRouteStatus(&hooks, 1, .auto_recovered, "✓ recovered · succeeded on attempt 2/2");
}

test "processQueuedPrompt exhaustion pauses without invoking route recovery" {
    const alloc = std.testing.allocator;
    const decisions = [_]runtime_deps.RouteRecoveryDecision{.cancel};
    const completions = [_]FakeCompletion{.{ .finish_reason = .provider_error, .provider_failure_detail = "route failed" }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.route_recovery_decisions = &decisions;
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.gateway_retry_count = 1;
    config.max_provider_attempts = 1;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 1), gateway.request_models.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.route_recovery_count);
    try std.testing.expectEqual(@as(usize, 0), hooks.system_notices.items.len);
    try std.testing.expectEqual(@as(usize, 1), hooks.route_recovery_statuses.items.len);
    try expectRouteStatus(&hooks, 0, .terminal_provider_error, "⚠ Provider unavailable · provider_error: route failed · recovery paused after 1/1 attempts");
}

test "processQueuedPrompt spacer newline is skipped for ask first tool" {
    const alloc = std.testing.allocator;
    const chunks = [_][]const u8{"Using tool"};
    const read_calls = [_]ToolCall{toolCall("call_read", "read_file", "{\"path\":\"a\"}")};
    const ask_calls = [_]ToolCall{toolCall("call_ask", "ask_user_question", "{\"questions\":[]}")};
    const non_ask_completions = [_]FakeCompletion{
        .{ .chunks = &chunks, .content = "Using tool", .tool_calls = &read_calls },
        .{ .content = "Final" },
    };
    const ask_completions = [_]FakeCompletion{
        .{ .chunks = &chunks, .content = "Using tool", .tool_calls = &ask_calls },
        .{ .content = "Final" },
    };

    var non_ask_gateway = FakeGateway.init(alloc, &non_ask_completions);
    defer non_ask_gateway.deinit();
    var non_ask_hooks = FakeAgentRuntimeDeps.init(alloc);
    defer non_ask_hooks.deinit();
    var fixture = PromptFixture{};
    try runFakePrompt(&non_ask_gateway, &non_ask_hooks, fixture.config(), fixture.job());
    try std.testing.expectEqual(@as(usize, 2), countText(&non_ask_hooks, "\n"));

    var ask_gateway = FakeGateway.init(alloc, &ask_completions);
    defer ask_gateway.deinit();
    var ask_hooks = FakeAgentRuntimeDeps.init(alloc);
    defer ask_hooks.deinit();
    var ask_fixture = PromptFixture{};
    try runFakePrompt(&ask_gateway, &ask_hooks, ask_fixture.config(), ask_fixture.job());
    try std.testing.expectEqual(@as(usize, 1), countText(&ask_hooks, "\n"));
}

test "processQueuedPrompt uses configured tool choice only for first call" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{toolCall("call_1", "read_file", "{\"path\":\"a\"}")};
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &calls },
        .{ .content = "Final" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.first_call_tool_choice = .none;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 2), gateway.request_bodies.items.len);
    try expectBodyContains(&gateway, 0, "\"toolChoice\":{\"type\":\"none\"}");
    try expectBodyContains(&gateway, 1, "\"toolChoice\":{\"type\":\"auto\"}");
}

test "processQueuedPrompt injects silent-tool continuation without synthetic assistant text" {
    const alloc = std.testing.allocator;
    const call_one = [_]ToolCall{toolCall("call_1", "read_file", "{\"path\":\"a\"}")};
    const call_two = [_]ToolCall{toolCall("call_2", "read_file", "{\"path\":\"b\"}")};
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &call_one },
        .{ .tool_calls = &call_two },
        .{},
        .{ .content = "Summary" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};

    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

    try std.testing.expectEqual(@as(usize, 4), gateway.request_bodies.items.len);
    try expectBodyContains(&gateway, 3, "Summarize what you just did.");
    try expectBodyNotContains(&gateway, 3, "Done.");
}

test "tool presentation groups span silent steps and split on visible assistant prose" {
    const alloc = std.testing.allocator;
    const call_one = [_]ToolCall{toolCall("call_1", "read_file", "{\"path\":\"a\"}")};
    const call_two = [_]ToolCall{toolCall("call_2", "read_file", "{\"path\":\"b\"}")};
    const call_three = [_]ToolCall{toolCall("call_3", "read_file", "{\"path\":\"c\"}")};
    const visible_chunks = [_][]const u8{"Starting another batch."};
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &call_one },
        .{ .tool_calls = &call_two },
        .{
            .chunks = &visible_chunks,
            .content = visible_chunks[0],
            .tool_calls = &call_three,
        },
        .{ .content = "Final" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};

    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

    var groups: [3]types.ToolPresentationGroupId = undefined;
    var group_count: usize = 0;
    for (hooks.lifecycle_events.items) |event| {
        if (event != .authoritative_started) continue;
        groups[group_count] = event.authoritative_started.presentation_group_id.?;
        group_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), group_count);
    try std.testing.expectEqual(groups[0], groups[1]);
    try std.testing.expect(
        groups[0].anchor_step_id != groups[2].anchor_step_id,
    );

    var group_b_start_index: ?usize = null;
    var group_a_terminal_count: usize = 0;
    for (hooks.lifecycle_events.items, 0..) |event, index| {
        switch (event) {
            .authoritative_started => |started| {
                if (started.presentation_group_id) |group| {
                    if (std.meta.eql(group, groups[2])) {
                        group_b_start_index = index;
                        break;
                    }
                }
            },
            .terminal => |terminal| {
                if (std.mem.eql(u8, terminal.id.call_id, "call_1") or
                    std.mem.eql(u8, terminal.id.call_id, "call_2"))
                {
                    group_a_terminal_count += 1;
                }
            },
            .provisional, .progress, .turn_finished => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 2), group_a_terminal_count);
    try std.testing.expect(group_b_start_index != null);
}

test "processQueuedPrompt no-tool length bypasses silent-tool continuation" {
    const alloc = std.testing.allocator;
    const call_one = [_]ToolCall{toolCall("call_1", "read_file", "{\"path\":\"a\"}")};
    const call_two = [_]ToolCall{toolCall("call_2", "read_file", "{\"path\":\"b\"}")};
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &call_one },
        .{ .tool_calls = &call_two },
        .{ .finish_reason = .length },
        .{ .content = "UNEXPECTED_CONTINUATION" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};

    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

    try std.testing.expectEqual(@as(usize, 3), gateway.request_bodies.items.len);
    try std.testing.expectEqual(@as(usize, 2), hooks.executed_names.items.len);
    try std.testing.expectEqual(types.TurnPresentationOutcome.completed, hooks.finalized_outcome.?);
    try std.testing.expectEqual(types.ProviderCompletionDisposition.length_limited, hooks.finalized_disposition.?);
    try std.testing.expectEqual(@as(usize, 1), hooks.finalization_count);
    try std.testing.expectEqualStrings("Done.", hooks.finish_assistant_text.?);
}

test "processQueuedPrompt non-ok gateway response trims and clips HTTP detail" {
    const alloc = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    try body.appendSlice(alloc, " \n");
    for (0..4200) |_| try body.append(alloc, 'x');
    try body.appendSlice(alloc, "\n ");
    const completions = [_]FakeCompletion{.{ .status = .bad_request, .err_body = body.items }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};

    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

    try std.testing.expectEqual(std.http.Status.bad_request, hooks.http_status.?);
    try std.testing.expectEqual(@as(usize, 4096), hooks.http_detail.?.len);
    try std.testing.expect(hooks.http_detail.?[0] == 'x');
}

test "processQueuedPrompt non-ok gateway response records schema diagnostics" {
    const alloc = std.testing.allocator;
    diagnostics.resetForTest();
    defer diagnostics.resetForTest();

    const detail =
        \\{"error":{"message":"Invalid input: expected string, received array","param":["prompt",0,"content"]}}
    ;
    const completions = [_]FakeCompletion{.{ .status = .bad_request, .err_body = detail }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};

    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

    var calls: [diagnostics.network_ring_capacity]diagnostics.NetworkCall = undefined;
    const count = diagnostics.snapshotNetworkCalls(&calls);
    try std.testing.expect(count > 0);
    const call = calls[count - 1];
    try std.testing.expectEqual(@as(u16, 400), call.status);
    try std.testing.expectEqualStrings("anthropic/claude-opus-4.6", call.model());
    try std.testing.expect(call.turn_id != 0);
    try std.testing.expect(call.step_id != 0);
    try std.testing.expectEqualStrings(
        "path=prompt.0.content expected=string received=array",
        call.gatewaySchemaDiagnostic(),
    );
    try std.testing.expect(std.mem.find(u8, call.gatewayRequestShape(), "prompt.0 role=system content=string") != null);
    try std.testing.expect(std.mem.find(u8, call.gatewayRequestShape(), "prompt.1 role=user content=array") != null);
}

test "processQueuedPrompt refreshes fx login credential before gateway request" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{.{ .content = "Done." }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.credential_refresh_tokens = &.{"fresh-key"};
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.credential_source = .fx_login;

    try runFakePrompt(&gateway, &hooks, fixture.config(), job);

    try std.testing.expectEqual(@as(usize, 1), gateway.request_api_keys.items.len);
    try std.testing.expectEqualStrings("fresh-key", gateway.request_api_keys.items[0]);
    try std.testing.expectEqual(@as(usize, 1), hooks.credential_refresh_modes.items.len);
    try std.testing.expectEqual(runtime_deps.CredentialRefreshMode.if_needed, hooks.credential_refresh_modes.items[0]);
}

test "processQueuedPrompt refreshes and retries once after fx login 401" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{
        .{
            .status = .unauthorized,
            .err_body = "{\"error\":{\"message\":\"expired\"}}",
        },
        .{ .content = "Done." },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.credential_refresh_tokens = &.{ "still-stale", "fresh-after-401" };
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.credential_source = .fx_login;

    try runFakePrompt(&gateway, &hooks, fixture.config(), job);

    try std.testing.expectEqual(@as(usize, 2), gateway.request_api_keys.items.len);
    try std.testing.expectEqualStrings("still-stale", gateway.request_api_keys.items[0]);
    try std.testing.expectEqualStrings("fresh-after-401", gateway.request_api_keys.items[1]);
    try std.testing.expectEqual(@as(usize, 2), hooks.credential_refresh_modes.items.len);
    try std.testing.expectEqual(runtime_deps.CredentialRefreshMode.if_needed, hooks.credential_refresh_modes.items[0]);
    try std.testing.expectEqual(runtime_deps.CredentialRefreshMode.force, hooks.credential_refresh_modes.items[1]);
    try std.testing.expectEqual(types.TurnPresentationOutcome.completed, hooks.finalized_outcome.?);
}

test "processQueuedPrompt does not retry a second fx login 401" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{
        .{
            .status = .unauthorized,
            .err_body = "{\"error\":{\"message\":\"expired\"}}",
        },
        .{
            .status = .unauthorized,
            .err_body = "{\"error\":{\"message\":\"still unauthorized\"}}",
        },
        .{ .content = "must not be requested" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.credential_refresh_tokens = &.{ "still-stale", "fresh-after-401", "must-not-use" };
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.credential_source = .fx_login;

    try runFakePrompt(&gateway, &hooks, fixture.config(), job);

    try std.testing.expectEqual(@as(usize, 2), gateway.request_api_keys.items.len);
    try std.testing.expectEqualStrings("still-stale", gateway.request_api_keys.items[0]);
    try std.testing.expectEqualStrings("fresh-after-401", gateway.request_api_keys.items[1]);
    try std.testing.expectEqual(@as(usize, 2), hooks.credential_refresh_modes.items.len);
    try std.testing.expectEqual(std.http.Status.unauthorized, hooks.http_status.?);
    try std.testing.expectEqual(types.TurnPresentationOutcome.failed, hooks.finalized_outcome.?);
}

test "Codex 401 replay keeps payload and semantic recovery unchanged for the captured account" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{
        .{ .status = .unauthorized, .err_body = "expired" },
        .{ .content = "Done." },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.credential_refresh_tokens = &.{ "stale-loaded", "fresh-token" };
    hooks.enable_recovery_checkpoint = true;
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.provider = .codex;
    job.credential_source = .chatgpt_subscription;
    job.account_id = @constCast("acct-a");

    try runFakePrompt(&gateway, &hooks, fixture.config(), job);

    try std.testing.expectEqual(@as(usize, 2), gateway.request_bodies.items.len);
    try std.testing.expectEqualSlices(u8, gateway.request_bodies.items[0], gateway.request_bodies.items[1]);
    try std.testing.expectEqualStrings("stale-loaded", gateway.request_api_keys.items[0]);
    try std.testing.expectEqualStrings("fresh-token", gateway.request_api_keys.items[1]);
    try std.testing.expectEqualStrings("acct-a", hooks.last_credential_refresh_expected_account.?);
    try std.testing.expectEqual(@as(usize, 0), hooks.route_recovery_count);
    try std.testing.expectEqual(types.TurnPresentationOutcome.completed, hooks.finalized_outcome.?);
}

test "Codex 401 account change makes no second provider request" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{
        .{ .status = .unauthorized, .err_body = "expired" },
        .{ .content = "must not be requested" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.credential_refresh_error = error.ChatGptAccountChanged;
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.provider = .codex;
    job.credential_source = .chatgpt_subscription;
    job.account_id = @constCast("acct-a");

    try runFakePrompt(&gateway, &hooks, fixture.config(), job);

    try std.testing.expectEqual(@as(usize, 1), gateway.request_bodies.items.len);
    try std.testing.expectEqualStrings("acct-a", hooks.last_credential_refresh_expected_account.?);
    try std.testing.expectEqual(@as(usize, 0), hooks.route_recovery_count);
    try std.testing.expectEqual(std.http.Status.unauthorized, hooks.http_status.?);
    try std.testing.expectEqual(types.TurnPresentationOutcome.failed, hooks.finalized_outcome.?);
}

test "processQueuedPrompt keeps the selected fx login credential when forced refresh is unavailable" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{
        .{
            .status = .unauthorized,
            .err_body = "{\"error\":{\"message\":\"expired\"}}",
        },
        .{ .content = "must not be requested" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.credential_refresh_tokens = &.{"selected-login-token"};
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.credential_source = .fx_login;

    try runFakePrompt(&gateway, &hooks, fixture.config(), job);

    try std.testing.expectEqual(@as(usize, 1), gateway.request_api_keys.items.len);
    try std.testing.expectEqualStrings("selected-login-token", gateway.request_api_keys.items[0]);
    try std.testing.expectEqual(@as(usize, 2), hooks.credential_refresh_modes.items.len);
    try std.testing.expectEqual(runtime_deps.CredentialRefreshMode.force, hooks.credential_refresh_modes.items[1]);
    try std.testing.expectEqual(std.http.Status.unauthorized, hooks.http_status.?);
    try std.testing.expectEqual(types.CredentialSource.fx_login, hooks.http_credential_source.?);
    try std.testing.expectEqual(types.TurnPresentationOutcome.failed, hooks.finalized_outcome.?);
}

test "processQueuedPrompt reports the selected login after refresh failure without fallback" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{
        .{
            .status = .unauthorized,
            .err_body = "{\"error\":{\"message\":\"expired\"}}",
        },
        .{ .content = "must not be requested" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.credential_refresh_error = error.OAuthRequestFailed;
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.credential_source = .fx_login;

    try runFakePrompt(&gateway, &hooks, fixture.config(), job);

    try std.testing.expectEqual(@as(usize, 1), gateway.request_api_keys.items.len);
    try std.testing.expectEqualStrings("key", gateway.request_api_keys.items[0]);
    try std.testing.expectEqual(@as(usize, 2), hooks.credential_refresh_modes.items.len);
    try std.testing.expectEqual(runtime_deps.CredentialRefreshMode.if_needed, hooks.credential_refresh_modes.items[0]);
    try std.testing.expectEqual(runtime_deps.CredentialRefreshMode.force, hooks.credential_refresh_modes.items[1]);
    try std.testing.expectEqual(std.http.Status.unauthorized, hooks.http_status.?);
    try std.testing.expectEqual(types.CredentialSource.fx_login, hooks.http_credential_source.?);
    try std.testing.expectEqual(types.TurnPresentationOutcome.failed, hooks.finalized_outcome.?);
}

test "processQueuedPrompt does not refresh or retry non-refreshable credential sources" {
    const alloc = std.testing.allocator;
    const sources = [_]types.CredentialSource{
        .vercel_oidc_token,
        .ai_gateway_api_key,
        .stored_key,
    };

    for (sources) |source| {
        const completions = [_]FakeCompletion{.{
            .status = .unauthorized,
            .err_body = "{\"error\":{\"message\":\"invalid\"}}",
        }};
        var gateway = FakeGateway.init(alloc, &completions);
        defer gateway.deinit();
        var hooks = FakeAgentRuntimeDeps.init(alloc);
        hooks.credential_refresh_tokens = &.{"must-not-use"};
        defer hooks.deinit();
        var fixture = PromptFixture{};
        var job = fixture.job();
        job.credential_source = source;

        try runFakePrompt(&gateway, &hooks, fixture.config(), job);

        try std.testing.expectEqual(@as(usize, 1), gateway.request_api_keys.items.len);
        try std.testing.expectEqualStrings("key", gateway.request_api_keys.items[0]);
        try std.testing.expectEqual(@as(usize, 0), hooks.credential_refresh_modes.items.len);
        try std.testing.expectEqual(std.http.Status.unauthorized, hooks.http_status.?);
        try std.testing.expectEqual(source, hooks.http_credential_source.?);
        try std.testing.expectEqual(types.TurnPresentationOutcome.failed, hooks.finalized_outcome.?);
    }
}

test "processQueuedPrompt does not execute tool calls from length-truncated completion" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{toolCall("call_write", "write_file", "{\"path\":\"a.txt\",\"content\":\"x\"}")};
    const completions = [_]FakeCompletion{.{
        .content = "Partial answer",
        .tool_calls = &calls,
        .finish_reason = .length,
    }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};

    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

    try std.testing.expectEqual(@as(usize, 0), hooks.permission_names.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.executed_names.items.len);
    try std.testing.expectEqual(@as(usize, 1), hooks.system_notices.items.len);
    try std.testing.expect(std.mem.find(u8, hooks.system_notices.items[0], "provider length limit") != null);
    try std.testing.expect(std.mem.find(u8, hooks.finish_assistant_text.?, "Partial answer") != null);
    try std.testing.expect(std.mem.find(u8, hooks.finish_assistant_text.?, "did not execute") != null);
    try std.testing.expectEqual(types.ProviderCompletionDisposition.length_limited, hooks.finalized_disposition.?);
    try std.testing.expectEqual(@as(usize, 1), hooks.finalization_count);
    try std.testing.expect(
        logIndex(&hooks, "event:turn_finished").? <
            logIndex(&hooks, "event:finish_prompt").?,
    );
}

test "processQueuedPrompt no-tool length preserves completed presentation with length disposition" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{.{
        .content = "Partial answer",
        .finish_reason = .length,
    }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};

    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

    try std.testing.expectEqual(types.TurnPresentationOutcome.completed, hooks.finalized_outcome.?);
    try std.testing.expectEqual(types.ProviderCompletionDisposition.length_limited, hooks.finalized_disposition.?);
    try std.testing.expectEqual(@as(usize, 1), hooks.finalization_count);
    try std.testing.expectEqualStrings("Partial answer", hooks.finish_assistant_text.?);
    try std.testing.expect(
        logIndex(&hooks, "event:turn_finished").? <
            logIndex(&hooks, "event:finish_prompt").?,
    );
}

test "processQueuedPrompt review continuation appends active review prompt after write tool" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{toolCall("call_1", "write_file", "{\"path\":\"a\",\"content\":\"x\"}")};
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &calls },
        .{ .content = "Reviewed" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.review_enabled = true;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try expectBodyContains(&gateway, 1, "Review the changes you just made. Re-read any modified files and briefly note any issues (syntax errors, missing imports, logic bugs). If everything looks correct, say so.");
}

test "processQueuedPrompt trace records history shape returned tool calls and waits" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "agent-loop-trace.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "agent,gateway,history,tool,permission,interrupt");

    const prior_call = toolCall("prior_1", "write_file", "{\"path\":\"old.txt\",\"content\":\"old secret\"}");
    var history = [_]HistoryTurn{.{ .interrupted = .{
        .user = .{ .text = @constCast("create old file") },
        .assistant = @constCast("I was about to write it."),
        .tool_call = prior_call,
    } }};
    const calls = [_]ToolCall{toolCall("call_1", "write_file", "{\"path\":\"secret.txt\",\"content\":\"super secret file contents\",\"metadata\":{\"token\":\"abc123\"}}")};
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &calls, .finish_reason = .tool_calls },
        .{ .content = "Done" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.history = history[0..];

    try runFakePrompt(&gateway, &hooks, fixture.config(), job);
    debug_trace.shutdown();

    const trace = try readTraceFile(alloc, trace_path, 131072);
    defer alloc.free(trace);

    try std.testing.expect(std.mem.find(u8, trace, "event=projection_end") != null);
    try std.testing.expect(std.mem.find(u8, trace, "history_turn_kinds=interrupted") != null);
    try std.testing.expect(std.mem.find(u8, trace, "projected_message_roles=user,assistant,tool,user") != null);
    try std.testing.expect(std.mem.find(u8, trace, "event=before_payload_build") != null);
    try std.testing.expect(std.mem.find(u8, trace, "event=after_payload_build") != null);
    try std.testing.expect(std.mem.find(u8, trace, "event=returned_tool_call") != null);
    try std.testing.expect(std.mem.find(u8, trace, "call_id=call_1 tool_name=write_file") != null);
    try std.testing.expect(std.mem.find(u8, trace, "args_preview=<object_fields=3 values=[") != null);
    try std.testing.expect(std.mem.find(u8, trace, "event=before_permission_wait") != null);
    try std.testing.expect(std.mem.find(u8, trace, "event=after_permission_decision") != null);
    try std.testing.expect(std.mem.find(u8, trace, "event=before_tool_execution") != null);
    try std.testing.expect(std.mem.find(u8, trace, "event=after_tool_execution") != null);
    try std.testing.expect(std.mem.find(u8, trace, "\"path\"") == null);
    try std.testing.expect(std.mem.find(u8, trace, "\"content\"") == null);
    try std.testing.expect(std.mem.find(u8, trace, "\"metadata\"") == null);
    try std.testing.expect(std.mem.find(u8, trace, "\"token\"") == null);
    try std.testing.expect(std.mem.find(u8, trace, "super secret file contents") == null);
    try std.testing.expect(std.mem.find(u8, trace, "secret.txt") == null);
    try std.testing.expect(std.mem.find(u8, trace, "abc123") == null);
}
