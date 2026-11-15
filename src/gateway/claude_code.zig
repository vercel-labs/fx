//! The Claude Code provider: fx's conversation runs on the user's own
//! Claude subscription through their installed, signed-in `claude` binary.
//!
//! fx keeps its own interface, tools, permissions, and sessions. Claude Code
//! supplies the model loop and the sign-in. fx never runs a Claude sign-in,
//! never reads Claude Code's files or credentials, and never calls
//! Anthropic's API itself: every model request goes through the `claude`
//! process, started with its documented flags. A user who isn't signed in is
//! told to run `claude` and sign in there.
//!
//! `claude_code_session.zig` runs the conversation, `claude_code_wire.zig`
//! holds the protocol, and this file is the provider fx selects: the stream
//! entry point, the model list, the permission reviewer, the MCP bridge
//! process, and the status check.
const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const classifier = @import("../core/permissions/auto_classifier.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const types = @import("../core/shared/types.zig");
const review_messages = @import("vercel_protocol.zig");
const session_runtime = @import("claude_code_session.zig");
const wire = @import("claude_code_wire.zig");

const Allocator = std.mem.Allocator;
const posix = std.posix;

pub const bridge_mode = session_runtime.bridge_mode;
pub const not_installed_message = session_runtime.not_installed_message;
pub const not_signed_in_message = session_runtime.not_signed_in_message;
pub const stopAll = session_runtime.stopAll;

/// The model a new selection starts with.
pub const default_model = @import("../core/config/model_provider.zig").claude_code_default_model;
/// Titles come from the smallest model, in a one-shot `claude -p`.
pub const title_model = "claude-haiku-5-5";

const Model = struct { id: []const u8, name: []const u8 };

/// The models Claude Code offers a subscription. Claude Code resolves each
/// id itself, so this list only names them.
pub const models = [_]Model{
    .{ .id = "claude-opus-5-5", .name = "Claude Opus 5.5" },
    .{ .id = "claude-sonnet-5-5", .name = "Claude Sonnet 5.5" },
    .{ .id = "claude-haiku-5-5", .name = "Claude Haiku 5.5" },
    .{ .id = "claude-fable-5-2", .name = "Claude Fable 5.2" },
};

/// `claude --effort` levels.
const efforts = [_][]const u8{ "low", "medium", "high", "xhigh", "max" };

pub const bundle_capabilities = provider_set.Bundle.Capabilities{
    // Images and fx's image fallback aren't carried over the bridge yet.
    .vision_fallback = false,
};

pub const agent_stream_provider = stream_provider.Provider{
    .stream_fn = stream,
    .project_replay_fn = projectReplay,
};

/// A reply's replay record names the Claude session and how much of the
/// history it saw. It belongs to the whole reply, so every part keeps it.
fn projectReplay(_: Allocator, replay: ?types.ProviderReplay, _: []const types.ToolCall, _: bool, _: bool) !?types.ProviderReplay {
    return replay;
}

/// Whether `lease` is the one fx resolves for this provider, which holds no
/// secret: Claude Code keeps its own sign-in.
pub fn acceptsCredential(lease: types.CredentialLease) bool {
    return lease.credentialSource() == .claude_code;
}

fn effortFor(options: anytype) ?[]const u8 {
    const effort = options.reasoning orelse return null;
    const label = effort.label();
    for (efforts) |known| if (std.mem.eql(u8, known, label)) return known;
    return null;
}

fn stream(_: ?*anyopaque, alloc: Allocator, request: stream_provider.ModelRequest) anyerror!stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return stream_provider.failResult(error.Cancelled);
    if (!acceptsCredential(request.credential)) return stream_provider.failResult(error.ClaudeCodeCredentialRequired);
    if (request.response_format != null or request.vision_mode == .required) {
        return unsupported(alloc, "Claude Code can't read images through fx yet.");
    }
    return switch (request.purpose) {
        .agent => session_runtime.agentStep(alloc, .{ .request = request, .effort = effortFor(request.provider_options) }),
        .title, .compaction => oneShotStep(alloc, request),
        .vision => unsupported(alloc, "Claude Code can't read images through fx yet."),
        .permission_review, .auxiliary => unsupported(alloc, "This request isn't sent through Claude Code."),
    };
}

fn unsupported(alloc: Allocator, text: []const u8) !stream_provider.Result {
    return .{ .failed = .{ .kind = .invalid_request, .detail = try alloc.dupe(u8, text), .ownership = .owned } };
}

/// A side call's conversation as one prompt.
fn writePrompt(alloc: Allocator, writer: *std.Io.Writer, messages: []const types.ChatMessage) !void {
    var start = messages.len;
    while (start > 0 and (messages[start - 1].role == .user or messages[start - 1].role == .system)) start -= 1;
    if (start == 0) return wire.writeUserText(writer, messages);
    try wire.writeSeededPrompt(alloc, writer, messages[0..start], messages[start..]);
}

fn joinInstructions(writer: *std.Io.Writer, instructions: []const types.ChatMessage) !void {
    var first = true;
    for (instructions) |message| {
        const text = message.content orelse continue;
        if (!first) try writer.writeAll("\n\n");
        first = false;
        try writer.writeAll(text);
    }
    if (first) try writer.writeAll("You are a helpful assistant.");
}

fn oneShotStep(alloc: Allocator, request: stream_provider.ModelRequest) !stream_provider.Result {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prompt: std.Io.Writer.Allocating = .init(arena);
    try writePrompt(arena, &prompt.writer, request.messages);
    var system: std.Io.Writer.Allocating = .init(arena);
    try joinInstructions(&system.writer, request.instructions);
    try request.admission.admit();
    request.delivery.markPossiblySent();
    const reply = try session_runtime.oneShot(alloc, .{
        .model = request.model,
        .system_prompt = system.written(),
        .prompt = prompt.written(),
        .cancel_flag = request.cancel_flag,
        .deadline = request.deadline,
    });
    return switch (reply) {
        .failed => |failure| .{ .failed = failure },
        .text, .structured => |text| blk: {
            if (text.len > 0) request.events.emit(.{ .content_delta = text });
            break :blk .{ .completed = .{
                .completion = .{ .content = text, .finish_reason = .stop },
                .ownership = .owned,
            } };
        },
    };
}

// ---------------------------------------------------------------------------
// Models

pub const model_catalog_provider = model_catalog.Provider{
    .fetch_fn = fetchCatalog,
    .lookup_capabilities_fn = lookupCapabilities,
    .provider_id = .claude_code,
};

pub const cli_model_catalog_provider = gateway_provider.CliModelCatalogProvider{
    .fetch_fn = fetchCliModelCatalog,
};

pub fn isKnownModel(id: []const u8) bool {
    for (models) |model| if (std.mem.eql(u8, model.id, id)) return true;
    return false;
}

fn fetchCatalog(_: ?*anyopaque, alloc: Allocator, _: model_catalog.FetchInput) Allocator.Error!model_catalog.ProviderResult {
    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &catalog);
    for (models) |model| {
        const id = try alloc.dupe(u8, model.id);
        errdefer alloc.free(id);
        const name = try alloc.dupe(u8, model.name);
        errdefer alloc.free(name);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        var reasoning: std.ArrayList(types.ReasoningEffort) = .empty;
        errdefer reasoning.deinit(alloc);
        inline for (efforts) |effort| try reasoning.append(alloc, .literal(effort));
        try catalog.append(alloc, .{
            .id = id,
            .name = name,
            .model_type = model_type,
            .has_tool_use = true,
            .has_reasoning = true,
            .reasoning_efforts = reasoning,
            .has_implicit_caching = true,
            // Left unknown on purpose: Claude Code keeps and compacts the
            // conversation itself, so fx must not compact it on its own.
            .context_window = 0,
        });
    }
    return .{ .catalog = catalog };
}

fn lookupCapabilities(_: ?*anyopaque, model: []const u8) @import("../core/config/model_capabilities.zig").Capabilities {
    var capabilities: @import("../core/config/model_capabilities.zig").Capabilities = .{
        .supports_tool_use = true,
        .supports_reasoning = isKnownModel(model),
        .supports_implicit_caching = true,
    };
    if (isKnownModel(model)) {
        var options: [efforts.len]types.ReasoningEffort = undefined;
        for (efforts, &options) |effort, *option| option.* = types.ReasoningEffort.parse(effort).?;
        capabilities.reasoning_efforts = .fromSlice(&options);
    }
    return capabilities;
}

fn fetchCliModelCatalog(_: ?*anyopaque, alloc: Allocator, input: gateway_provider.CliModelCatalogInput) gateway_provider.CliModelCatalogResult {
    return switch (model_catalog.fetchWithPublicFallback(model_catalog_provider, alloc, .{
        .access = input.access,
        .endpoint = input.endpoint,
        .cancel_flag = input.cancel_flag,
        .view = .full,
    })) {
        .loaded => |loaded| blk: {
            var catalog = loaded.catalog;
            defer model_catalog.freeModelCatalog(alloc, &catalog);
            const ids = model_catalog.projectModelIds(alloc, catalog.items) catch return .{ .failure = .{
                .access = loaded.provenance.access,
                .anonymous_fallback_used = false,
                .failure = .{ .category = .resource_exhausted },
            } };
            break :blk .{ .loaded = .{ .ids = ids, .provenance = loaded.provenance } };
        },
        .failed => |failure| .{ .failure = failure },
    };
}

// ---------------------------------------------------------------------------
// Permission reviews in auto mode

pub const permission_reviewer = classifier.Provider{ .review_fn = review };
const reviewer_model = "claude-sonnet-5-5";

fn review(_: ?*anyopaque, alloc: Allocator, input: classifier.ProviderInput, request: classifier.ReviewRequest) anyerror!classifier.ParseOutcome {
    var context: u8 = 0;
    const model = if (input.reviewer_model.len > 0) input.reviewer_model else reviewer_model;
    // Starting `claude` takes part of the time a review gets.
    return classifier.Reviewer.withTransportModel(
        .{ .context = &context, .build_fn = buildReview, .send_fn = sendReview },
        input.cancel_flag,
        classifier.Reviewer.default_timeout_ms * 2,
        model,
    ).review(alloc, request);
}

/// The review as one JSON payload: its instructions and its conversation as
/// a prompt. `sendReview` runs it.
fn buildReview(
    _: *anyopaque,
    alloc: Allocator,
    model: []const u8,
    _: []const u8,
    instructions: []const types.ChatMessage,
    messages: []const types.ChatMessage,
    target_id: []const u8,
    deadline: std.Io.Clock.Timestamp,
    cancel: *std.atomic.Value(bool),
) anyerror![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const expanded = try review_messages.expandPendingToolReviewMessages(arena, messages, target_id, deadline, cancel);
    var system: std.Io.Writer.Allocating = .init(arena);
    try joinInstructions(&system.writer, instructions);
    var prompt: std.Io.Writer.Allocating = .init(arena);
    try wire.writeTranscript(&prompt.writer, expanded);
    try prompt.writer.writeAll("Review the pending action above and return your decision.");
    var schema: std.Io.Writer.Allocating = .init(arena);
    try model_tool_schema.writeObjectSchema(arena, &schema.writer, classifier.function_schema.input_schema);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(.{
        .model = model,
        .system = system.written(),
        .prompt = prompt.written(),
        .schema = schema.written(),
    }, .{}, &out.writer);
    return out.toOwnedSlice();
}

const ReviewPayload = struct { model: []const u8, system: []const u8, prompt: []const u8, schema: []const u8 };

fn sendReview(
    _: *anyopaque,
    alloc: Allocator,
    _: []const u8,
    payload: []const u8,
    deadline: std.Io.Clock.Timestamp,
    cancel: *std.atomic.Value(bool),
) anyerror!classifier.TransportOutcome {
    var parsed = std.json.parseFromSlice(ReviewPayload, alloc, payload, .{}) catch return .permanent_failure;
    defer parsed.deinit();
    const reply = session_runtime.oneShot(alloc, .{
        .model = parsed.value.model,
        .system_prompt = parsed.value.system,
        .prompt = parsed.value.prompt,
        .json_schema = parsed.value.schema,
        .cancel_flag = cancel,
        .deadline = deadline,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => return .cancelled,
        error.Timeout => return .timed_out,
        else => return .permanent_failure,
    };
    switch (reply) {
        .failed => |failure| {
            var owned = stream_provider.Result{ .failed = failure };
            owned.deinit(alloc);
            return if (failure.kind == .unavailable or failure.kind == .provider_error) .transient_failure else .permanent_failure;
        },
        .text => |text| {
            alloc.free(text);
            return .permanent_failure;
        },
        .structured => |json| {
            const owned = try alloc.create(ReviewCompletion);
            errdefer alloc.destroy(owned);
            owned.* = .{ .call = .{ .id = "claude-code-review", .name = classifier.tool_name, .arguments_json = json } };
            return .{ .completion = .{
                .completion = .{ .tool_calls = (&owned.call)[0..1], .finish_reason = .tool_calls },
                .context = owned,
                .deinit_fn = freeReviewCompletion,
            } };
        },
    }
}

const ReviewCompletion = struct { call: types.ToolCall };

fn freeReviewCompletion(raw: *anyopaque, alloc: Allocator) void {
    const owned: *ReviewCompletion = @ptrCast(@alignCast(raw));
    alloc.free(owned.call.arguments_json);
    alloc.destroy(owned);
}

// ---------------------------------------------------------------------------
// The MCP bridge process

/// Whether fx was started as the bridge: `fx --fx-internal-claude-code-bridge
/// <socket> <token>`, which Claude Code runs as its MCP server.
pub fn isBridgeModeRaw(raw_args: []const [*:0]const u8) bool {
    return raw_args.len == 4 and std.mem.eql(u8, std.mem.sliceTo(raw_args[1], 0), bridge_mode);
}

/// Relays MCP lines between Claude Code, on stdin and stdout, and the fx
/// process that started it, on its socket. Ends when either side closes.
pub fn runBridge(raw_args: []const [*:0]const u8) !void {
    if (!isBridgeModeRaw(raw_args)) return error.InvalidBridgeArguments;
    const io = io_mod.getIo();
    const socket_path = std.mem.sliceTo(raw_args[2], 0);
    const token = std.mem.sliceTo(raw_args[3], 0);
    const address = try std.Io.net.UnixAddress.init(socket_path);
    const stream_conn = try address.connect(io);
    defer stream_conn.close(io);
    const fd = stream_conn.socket.handle;
    if (!writeAll(fd, token) or !writeAll(fd, "\n")) return error.BridgeConnectionLost;
    var task = try io.concurrent(relaySocketToStdout, .{fd});
    relayStdinToSocket(fd);
    // Claude Code closed stdin: it is done with the server.
    _ = std.c.shutdown(fd, 2);
    task.await(io);
}

fn relayStdinToSocket(fd: posix.socket_t) void {
    var buffer: [16 * 1024]u8 = undefined;
    while (true) {
        const rc = std.c.read(posix.STDIN_FILENO, &buffer, buffer.len);
        if (rc < 0 and posix.errno(rc) == .INTR) continue;
        if (rc <= 0) return;
        if (!writeAll(fd, buffer[0..@intCast(rc)])) return;
    }
}

fn relaySocketToStdout(fd: posix.socket_t) void {
    var buffer: [16 * 1024]u8 = undefined;
    while (true) {
        const rc = std.c.read(fd, &buffer, buffer.len);
        if (rc < 0 and posix.errno(rc) == .INTR) continue;
        if (rc <= 0) break;
        if (!writeAll(posix.STDOUT_FILENO, buffer[0..@intCast(rc)])) break;
    }
    // fx is gone: so is the server.
    _ = std.c.close(posix.STDIN_FILENO);
    std.process.exit(0);
}

fn writeAll(fd: posix.fd_t, bytes: []const u8) bool {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const rc = std.c.write(fd, bytes[sent..].ptr, bytes.len - sent);
        if (rc < 0) {
            if (posix.errno(rc) == .INTR) continue;
            return false;
        }
        sent += @intCast(rc);
    }
    return true;
}

// ---------------------------------------------------------------------------
// Status

pub const Status = struct {
    installed: bool = false,
    /// `claude --version`, trimmed.
    version: ?[]u8 = null,
    signed_in: ?bool = null,
    /// How Claude Code signs in, such as `claude.ai` for a subscription.
    auth_method: ?[]u8 = null,
    /// The subscription's plan, such as `max`.
    subscription: ?[]u8 = null,

    pub fn deinit(self: *Status, alloc: Allocator) void {
        if (self.version) |value| alloc.free(value);
        if (self.auth_method) |value| alloc.free(value);
        if (self.subscription) |value| alloc.free(value);
        self.* = .{};
    }
};

/// Asks the `claude` binary whether it is installed and signed in, through
/// `claude --version` and `claude auth status --json`. Reads only the
/// sign-in state those commands print, never Claude Code's files. Owned by
/// `alloc`.
pub fn probeStatus(alloc: Allocator) !Status {
    var status: Status = .{};
    errdefer status.deinit(alloc);
    const version = runClaude(alloc, &.{ "claude", "--version" }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return status,
    };
    defer alloc.free(version.stdout);
    status.installed = true;
    const trimmed = std.mem.trim(u8, version.stdout, " \t\r\n");
    if (trimmed.len > 0) status.version = try alloc.dupe(u8, trimmed);

    const auth = runClaude(alloc, &.{ "claude", "auth", "status", "--json" }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return status,
    };
    defer alloc.free(auth.stdout);
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, auth.stdout, .{}) catch return status;
    defer parsed.deinit();
    if (parsed.value != .object) return status;
    const object = parsed.value.object;
    if (object.get("loggedIn")) |value| if (value == .bool) {
        status.signed_in = value.bool;
    };
    if (object.get("authMethod")) |value| if (value == .string and value.string.len > 0 and value.string.len <= 64) {
        status.auth_method = try alloc.dupe(u8, value.string);
    };
    if (object.get("subscriptionType")) |value| if (value == .string and value.string.len > 0 and value.string.len <= 64) {
        status.subscription = try alloc.dupe(u8, value.string);
    };
    return status;
}

const Ran = struct { stdout: []u8 };

fn runClaude(alloc: Allocator, argv: []const []const u8) !Ran {
    const io = io_mod.getIo();
    const result = try std.process.run(alloc, io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
    });
    alloc.free(result.stderr);
    switch (result.term) {
        .exited => {},
        else => {
            alloc.free(result.stdout);
            return error.ClaudeFailed;
        },
    }
    return .{ .stdout = result.stdout };
}

test "claude code: the model list offers every effort and leaves the window unknown" {
    const alloc = std.testing.allocator;
    var result = try fetchCatalog(null, alloc, .{ .endpoint = "" });
    defer model_catalog.freeModelCatalog(alloc, &result.catalog);
    try std.testing.expectEqual(models.len, result.catalog.items.len);
    try std.testing.expectEqualStrings(default_model, result.catalog.items[0].id);
    try std.testing.expectEqual(@as(usize, efforts.len), result.catalog.items[0].reasoning_efforts.items.len);
    try std.testing.expectEqual(@as(u32, 0), result.catalog.items[0].context_window);
    try std.testing.expect(isKnownModel(title_model));
    try std.testing.expect(lookupCapabilities(null, default_model).context_window == null);
}

test "claude code: the bridge mode needs its socket and token" {
    const args = [_][*:0]const u8{ "fx", bridge_mode, "/tmp/s", "token" };
    try std.testing.expect(isBridgeModeRaw(&args));
    try std.testing.expect(!isBridgeModeRaw(args[0..2]));
}

test "claude code: a side call's history becomes one prompt" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writePrompt(std.testing.allocator, &out.writer, &.{.{ .role = .user, .content = "Name this chat." }});
    try std.testing.expectEqualStrings("Name this chat.", out.written());
}
