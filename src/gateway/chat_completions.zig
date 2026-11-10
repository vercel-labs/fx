const std = @import("std");
const codec = @import("chat_completions_protocol.zig");
const definitions = @import("../core/config/configured_provider.zig");
const streams = @import("../core/agent/stream_provider.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const catalog = @import("../core/gateway/model_catalog.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const model_capabilities = @import("../core/config/model_capabilities.zig");
const model_catalog_metadata = @import("../core/gateway/model_catalog_metadata.zig");
const classifier = @import("../core/permissions/auto_classifier.zig");
const gateway_step = @import("../core/agent/runtime/gateway_step.zig");
const review_messages = @import("vercel_protocol.zig");
const types = @import("../core/shared/types.zig");
const model_provider = @import("../core/config/model_provider.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const sse = @import("sse.zig");
const transport = @import("configured_transport.zig");
const responses = @import("configured_responses.zig");
const responses_protocol = @import("responses_protocol.zig");
const anthropic_messages = @import("anthropic_messages_protocol.zig");
const request_fragment = @import("../core/config/request_fragment.zig");
const Allocator = std.mem.Allocator;

/// Every callback borrows the immutable definition from the owning profile runtime.
pub fn bundle(definition: *const definitions.Definition) provider_set.Bundle {
    const context: *anyopaque = @ptrCast(@constCast(definition));
    return .{
        // The image fallback asks the connection's own vision model, so it
        // is on only when the settings name one.
        .capabilities = .{ .vision_fallback = definition.vision_model != null, .vision_model = definition.vision_model },
        .title_model = definition.title_model,
        .agent_stream = .{ .context = context, .stream_fn = stream, .build_request_fn = build, .project_replay_fn = replay_projection(definition.protocol) },
        .model_catalog = model_catalog_provider(definition),
        .cli_model_catalog = .{ .context = context, .fetch_fn = fetch_cli_catalog },
        .permission_reviewer = .{ .context = context, .review_fn = review },
    };
}

/// The models the definition declares, and the server's own when its
/// settings turn `fetch_models` on. Borrows the definition, which must
/// outlive the provider.
pub fn model_catalog_provider(definition: *const definitions.Definition) catalog.Provider {
    const context: *anyopaque = @ptrCast(@constCast(definition));
    return .{ .context = context, .fetch_fn = fetch_catalog, .lookup_capabilities_fn = lookup_capabilities, .provider_id = bound_identity(definition) };
}

fn definition_at(raw: ?*anyopaque) *const definitions.Definition {
    return @ptrCast(@alignCast(raw.?));
}

fn bound_identity(definition: *const definitions.Definition) model_provider.ProviderId {
    var identity = model_provider.parse(definition.id).?;
    identity.configured.binding = definition.binding_identity();
    return identity;
}

fn build(raw: ?*anyopaque, alloc: Allocator, request: streams.RequestData) ![]u8 {
    return build_for(definition_at(raw), alloc, request);
}

/// The request body for `definition`, omitting replay parts recorded for
/// another endpoint. Caller owns the result.
pub fn build_for(definition: *const definitions.Definition, alloc: Allocator, request: streams.RequestData) ![]u8 {
    const identity = bound_identity(definition);
    for (request.messages) |message| if (message.provider_replay) |replay| {
        if (!replay.matches(.{ .provider = identity, .model = request.model })) {
            debug_trace.logf("gateway", "provider_replay_omitted reason=source_mismatch", .{});
            break;
        }
    };
    const metadata = definition.metadata_for(request.model);
    const request_fields: request_fragment.Fragment = if (metadata) |known| known.request orelse .{} else .{};
    const level = effort_fields(metadata, request.provider_options.reasoning);
    return switch (definition.protocol) {
        .@"openai-chat-completions" => codec.build_request(alloc, request, .{
            .tool_choice_mode = definition.tool_choice_mode,
            .provider = &identity,
            .output_limit_field = if (metadata) |known| known.output_limit_field orelse .max_tokens else .max_tokens,
            .request_fields = request_fields,
            .effort_fields = level,
        }),
        .@"openai-responses" => responses.build_request(alloc, request, .{
            .tool_choice_mode = definition.tool_choice_mode,
            .provider = &identity,
            .request_fields = request_fields,
            .effort_fields = level,
        }),
        .@"anthropic-messages" => anthropic_messages.build_request(alloc, request, .{
            .tool_choice_mode = definition.tool_choice_mode,
            .provider = &identity,
            .request_fields = request_fields,
            .effort_fields = level,
        }),
    };
}

/// How a connection's protocol reads a successful streamed reply.
fn consumer(protocol: definitions.Protocol) transport.ConsumeFn {
    return switch (protocol) {
        .@"openai-chat-completions" => consume,
        .@"openai-responses" => responses.consume,
        .@"anthropic-messages" => consume_messages,
    };
}

/// Which replay parts a connection's protocol keeps for a later request.
fn replay_projection(protocol: definitions.Protocol) *const fn (Allocator, ?types.ProviderReplay, []const types.ToolCall, bool, bool) anyerror!?types.ProviderReplay {
    return switch (protocol) {
        .@"openai-chat-completions" => project_replay,
        .@"openai-responses" => responses_protocol.selectReplayParts,
        .@"anthropic-messages" => anthropic_messages.project_replay,
    };
}

/// The request fields of the level `effort` names, when the model declares it.
fn effort_fields(metadata: ?definitions.ModelMetadata, effort: ?types.ReasoningEffort) ?request_fragment.Fragment {
    const known = metadata orelse return null;
    const chosen = effort orelse return null;
    const level = known.effort(chosen.label()) orelse return null;
    return level.fields;
}

pub fn project_replay(alloc: Allocator, replay: ?types.ProviderReplay, calls: []const types.ToolCall, text: bool, reasoning: bool) !?types.ProviderReplay {
    const selected = try codec.project_replay(alloc, replay, calls, text, reasoning);
    if (replay != null and selected == null) debug_trace.logf("gateway", "provider_replay_omitted reason={s}", .{if (reasoning) "associated_calls_removed" else "reasoning_removed"});
    return selected;
}

test "chat completions adapter binds replay to endpoint authority and wires projection" {
    const alloc = std.testing.allocator;
    var registry = try definitions.Registry.parse_json(alloc,
        \\{"local":{"protocol":"openai-chat-completions","base_url":"http://localhost:1234/v1","auth":{"type":"none"}}}
    );
    defer registry.deinit(alloc);
    var changed_registry = try definitions.Registry.parse_json(alloc,
        \\{"local":{"protocol":"openai-chat-completions","base_url":"http://localhost:5678/v1","auth":{"type":"none"}}}
    );
    defer changed_registry.deinit(alloc);
    const definition = registry.get("local").?;
    const adapter = bundle(definition).agent_stream.?;
    const replay: types.ProviderReplay = .{
        .source = .{ .provider = bundle(definition).model_catalog.?.provider_id, .model = "model" },
        .parts_json = "{\"reasoning_details\":[{\"signature\":\"signed\"}],\"_tool_call_ids\":[]}",
    };
    const selected = (try adapter.projectReplay(alloc, replay, &.{}, false, true)).?;
    try std.testing.expect(selected.parts_json.ptr == replay.parts_json.ptr);
    try std.testing.expect(try adapter.projectReplay(alloc, replay, &.{}, true, false) == null);
    const request: streams.RequestData = .{
        .model = "model",
        .instructions = &.{.{ .role = .system, .content = "instructions" }},
        .messages = &.{.{ .role = .assistant, .content = "answer", .provider_replay = replay }},
        .tool_choice = .auto,
        .provider_options = .{},
    };
    const matching = try adapter.build_request_fn.?(adapter.context, alloc, request);
    defer alloc.free(matching);
    try std.testing.expect(std.mem.find(u8, matching, "reasoning_details") != null);
    const other = bundle(changed_registry.get("local").?).agent_stream.?;
    const stripped = try other.build_request_fn.?(other.context, alloc, request);
    defer alloc.free(stripped);
    try std.testing.expect(std.mem.find(u8, stripped, "reasoning_details") == null);
    try std.testing.expect(request.messages[0].provider_replay.?.parts_json.ptr == replay.parts_json.ptr);
}

fn stream(raw: ?*anyopaque, alloc: Allocator, request: streams.ModelRequest) !streams.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    _ = try transport.tokenOf(definition_at(raw), request);
    const payload = request.prepared_request_body orelse try build(raw, alloc, request.data());
    defer if (request.prepared_request_body == null) alloc.free(payload);
    const definition = definition_at(raw);
    return transport.send(alloc, definition, request, payload, consumer(definition.protocol));
}

/// Parses a successful streamed Chat Completions reply from `reader`,
/// telling `progress` about each event when it is set.
pub fn consume(alloc: Allocator, reader: *std.Io.Reader, request: streams.ModelRequest, progress: ?sse.Progress) !streams.Result {
    var limits: codec.Limits = .{};
    if (request.content_capture_limit) |limit| limits.content_bytes = @min(limit, limits.content_bytes);
    return codec.consume_stream(alloc, reader, request.data(), limits, request.events, request.cancel_flag, progress);
}

/// The same for an Anthropic Messages reply.
fn consume_messages(alloc: Allocator, reader: *std.Io.Reader, request: streams.ModelRequest, progress: ?sse.Progress) !streams.Result {
    var limits: anthropic_messages.Limits = .{};
    if (request.content_capture_limit) |limit| limits.content_bytes = @min(limit, limits.content_bytes);
    return anthropic_messages.consume_stream(alloc, reader, request.data(), limits, request.events, request.cancel_flag, progress);
}

/// The returned entry borrows its strings and lists no effort levels;
/// fetch_catalog replaces the strings with owned copies and adds the levels.
fn metadata_entry(metadata: definitions.ModelMetadata) catalog.ModelCatalogEntry {
    const vision = metadata.supports_vision orelse false;
    return .{
        .id = @constCast(metadata.id),
        .model_type = @constCast("language"),
        .has_reasoning = if (metadata.reasoning_efforts) |levels| levels.len > 0 else false,
        .has_tool_use = metadata.supports_tool_use orelse false,
        // Chat completions sends images as inline base64 content parts, so
        // vision support implies file input through the same path.
        .has_vision = vision,
        .has_file_input = vision,
        .context_window = metadata.context_window orelse 0,
        .max_tokens = metadata.max_output_tokens orelse 0,
    };
}

/// The levels a model's settings declare, in their order.
fn effort_options(metadata: definitions.ModelMetadata) model_capabilities.ReasoningEffortOptions {
    var options: model_capabilities.ReasoningEffortOptions = .{};
    for (metadata.reasoning_efforts orelse return options) |level| {
        // The settings parser already holds names to this rule and count.
        options.values[options.len] = types.ReasoningEffort.parse(level.name) orelse continue;
        options.len += 1;
    }
    return options;
}

fn lookup_capabilities(raw: ?*anyopaque, model: []const u8) model_capabilities.Capabilities {
    const metadata = definition_at(raw).metadata_for(model) orelse return .{};
    var listed = model_catalog_metadata.fromCatalogEntry(metadata_entry(metadata));
    listed.reasoning_efforts = effort_options(metadata);
    return model_capabilities.mergeCapabilities(.{}, listed);
}

fn fetch_catalog(raw: ?*anyopaque, alloc: Allocator, input: catalog.FetchInput) Allocator.Error!catalog.ProviderResult {
    if (input.cancel_flag) |flag| if (flag.load(.seq_cst)) return .{ .failure = .{ .category = .cancellation } };
    var loaded = try load_models(definition_at(raw), alloc, input.cancel_flag);
    if (loaded.failure == .cancelled) {
        catalog.freeModelCatalog(alloc, &loaded.entries);
        return .{ .failure = .{ .category = .cancellation } };
    }
    return .{ .catalog = loaded.entries };
}

const LoadedModels = struct {
    /// Owned entries: the declared models in the settings' order, then
    /// the ones only the server lists, in its order.
    entries: std.ArrayList(catalog.ModelCatalogEntry),
    /// Why the server's list is missing, when fx asked for it.
    failure: ?transport.ModelsFailure = null,
};

/// The declared models, with the server's after them when the settings turn
/// `fetch_models` on. A model only the server lists takes `model_defaults`.
/// A failed request leaves the declared models
/// (`tests/tla/configured_provider/ConfiguredCatalog.tla` FallbackIsDeclared).
fn load_models(definition: *const definitions.Definition, alloc: Allocator, cancel_flag: ?*std.atomic.Value(bool)) Allocator.Error!LoadedModels {
    var entries: std.ArrayList(catalog.ModelCatalogEntry) = .empty;
    errdefer catalog.freeModelCatalog(alloc, &entries);
    for (definition.model_metadata) |declared| {
        try append_entry(alloc, &entries, definition.metadata_for(declared.id).?);
    }
    if (!definition.fetch_models) return .{ .entries = entries };
    var served = try transport.fetchModelIds(alloc, definition, cancel_flag);
    switch (served) {
        .failure => |failure| {
            debug_trace.logf("gateway", "event=configured_models_unavailable connection={s} reason={t}", .{ definition.id, failure });
            return .{ .entries = entries, .failure = failure };
        },
        .ids => |*ids| {
            defer transport.freeIds(alloc, ids);
            for (ids.items) |id| {
                if (definition.model(id) != null) continue;
                try append_entry(alloc, &entries, definition.metadata_for(id) orelse .{ .id = id });
            }
        },
    }
    return .{ .entries = entries };
}

/// Adds `metadata` to `entries` as an entry that owns its strings and levels.
fn append_entry(alloc: Allocator, entries: *std.ArrayList(catalog.ModelCatalogEntry), metadata: definitions.ModelMetadata) Allocator.Error!void {
    var entry = metadata_entry(metadata);
    entry.id = try alloc.dupe(u8, entry.id);
    errdefer alloc.free(entry.id);
    entry.model_type = try alloc.dupe(u8, entry.model_type);
    errdefer alloc.free(entry.model_type);
    errdefer entry.reasoning_efforts.deinit(alloc);
    try entry.reasoning_efforts.appendSlice(alloc, effort_options(metadata).slice());
    try entries.append(alloc, entry);
}

test "configured capability lookup matches catalog projection and preserves unknowns" {
    const alloc = std.testing.allocator;
    var registry = try definitions.Registry.parse_json(alloc,
        \\{"local":{"protocol":"openai-chat-completions","base_url":"http://localhost:1234/v1","auth":{"type":"none"},"model_metadata":{"small":{"context_window":8192,"max_output_tokens":512,"supports_tool_use":true,"supports_vision":true},"large":{"context_window":32768,"max_output_tokens":1024,"supports_tool_use":false},"partial":{"max_output_tokens":128},"unknown":{}}}}
    );
    defer registry.deinit(alloc);
    const provider = bundle(registry.get("local").?).model_catalog.?;
    var fetched = try provider.fetch(alloc, .{ .endpoint = "unused" });
    defer catalog.freeModelCatalog(alloc, &fetched.catalog);
    for (fetched.catalog.items) |entry| {
        const actual = provider.lookupCapabilities(entry.id).?;
        try model_capabilities.expectCapabilitiesEqualForTest(model_capabilities.mergeCapabilities(.{}, model_catalog_metadata.fromCatalogEntry(entry)), actual);
        const declared_vision = std.mem.eql(u8, entry.id, "small");
        try std.testing.expectEqual(declared_vision, actual.supports_vision);
        try std.testing.expectEqual(
            if (declared_vision) model_capabilities.ImageInputSupport.native else model_capabilities.ImageInputSupport.non_native,
            actual.image_input_support,
        );
    }
    try std.testing.expectEqual(@as(?u32, 512), provider.lookupCapabilities("small").?.max_output_tokens);
    try std.testing.expectEqual(@as(?u32, 1024), provider.lookupCapabilities("large").?.max_output_tokens);
    try std.testing.expect(provider.lookupCapabilities("partial").?.context_window == null);
    try std.testing.expect(provider.lookupCapabilities("unknown").?.max_output_tokens == null);
    try model_capabilities.expectCapabilitiesEqualForTest(.{}, provider.lookupCapabilities("missing-fast").?);
}

fn fetch_cli_catalog(raw: ?*anyopaque, alloc: Allocator, input: gateway_provider.CliModelCatalogInput) gateway_provider.CliModelCatalogResult {
    const provenance = catalog.Provenance{ .access = catalog.AccessMetadata.init(input.access) };
    const exhausted: gateway_provider.CliModelCatalogResult = .{ .failure = .{ .access = provenance.access, .anonymous_fallback_used = false, .failure = .{ .category = .resource_exhausted } } };
    if (input.cancel_flag) |flag| if (flag.load(.seq_cst)) return .{ .failure = .{ .access = provenance.access, .anonymous_fallback_used = false, .failure = .{ .category = .cancellation } } };
    const definition = definition_at(raw);
    var loaded = load_models(definition, alloc, input.cancel_flag) catch return exhausted;
    defer catalog.freeModelCatalog(alloc, &loaded.entries);
    if (loaded.failure == .cancelled) return .{ .failure = .{ .access = provenance.access, .anonymous_fallback_used = false, .failure = .{ .category = .cancellation } } };
    var ids = catalog.projectModelIds(alloc, loaded.entries.items) catch return exhausted;
    const notice = if (loaded.failure) |failure|
        alloc.print("could not get the model list of {s}: {s}; showing the models in settings", .{ definition.id, failure.text() }) catch {
            for (ids.items) |id| alloc.free(id);
            ids.deinit(alloc);
            return exhausted;
        }
    else
        null;
    return .{ .loaded = .{ .ids = ids, .provenance = provenance, .notice = notice } };
}

const Review = struct { definition: *const definitions.Definition, input: classifier.ProviderInput };
fn review(raw: ?*anyopaque, alloc: Allocator, input: classifier.ProviderInput, request: classifier.ReviewRequest) !classifier.ParseOutcome {
    var state = Review{ .definition = definition_at(raw), .input = input };
    return classifier.Reviewer.withTransportModel(.{ .context = &state, .build_fn = build_review, .send_fn = send_review }, input.cancel_flag, classifier.Reviewer.default_timeout_ms, state.definition.reviewer_model orelse request.review_turn.model).review(alloc, request);
}
fn build_review(raw: *anyopaque, alloc: Allocator, model: []const u8, _: []const u8, instructions: []const types.ChatMessage, messages: []const types.ChatMessage, target_id: []const u8, deadline: std.Io.Clock.Timestamp, cancel: *std.atomic.Value(bool)) ![]u8 {
    const state: *Review = @ptrCast(@alignCast(raw));
    const expanded = try review_messages.expandPendingToolReviewMessages(alloc, messages, target_id, deadline, cancel);
    defer alloc.free(expanded);
    const output_limit = if (state.definition.model(model)) |metadata| @min(metadata.max_output_tokens orelse 2048, 2048) else 2048;
    return build(@ptrCast(@constCast(state.definition)), alloc, .{ .model = model, .instructions = instructions, .messages = expanded, .tools = .{ .additional_functions = &.{classifier.function_schema} }, .tool_choice = .required, .provider_options = .{}, .max_output_tokens = output_limit });
}
fn ignore_event(_: *anyopaque, _: streams.Event) void {}
fn free_result(raw: *anyopaque, alloc: Allocator) void {
    const result: *streams.Result = @ptrCast(@alignCast(raw));
    result.deinit(alloc);
    alloc.destroy(result);
}
fn send_review(raw: *anyopaque, alloc: Allocator, model: []const u8, payload: []const u8, deadline: std.Io.Clock.Timestamp, cancel: *std.atomic.Value(bool)) !classifier.TransportOutcome {
    const state: *Review = @ptrCast(@alignCast(raw));
    var delivery: streams.DeliveryCertainty = .init();
    var evidence: streams.AttemptEvidence = .{};
    var event_context: u8 = 0;
    var result = gateway_step.streamModelCompletion(bundle(state.definition).agent_stream.?, alloc, .{
        .credential = .{ .direct = .{ .secret_bytes = state.input.credential, .source = state.input.credential_source } },
        .model = model,
        .retry_count = 1,
        .messages = &.{},
        .tools = .{ .additional_functions = &.{classifier.function_schema} },
        .tool_choice = .required,
        .provider_options = .{},
        .prepared_request_body = payload,
        .trace_ctx = .{},
        .content_capture_limit = 16 * 1024,
        .deadline = deadline,
        .delivery = &delivery,
        .attempt_evidence = &evidence,
        .events = .{ .context = &event_context, .emit_fn = ignore_event },
        .cancel_flag = cancel,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => return .cancelled,
        error.Timeout => return .timed_out,
        error.RequiredToolMissing => return .{ .completion = .{ .completion = .{} } },
        else => return .permanent_failure,
    };
    errdefer result.deinit(alloc);
    // A review the output limit cut off holds no decision, and the same
    // review would be cut off again, so it stays unavailable.
    const cut_off = result == .completed and result.completed.completion.finish_reason == .length;
    if (result == .failed or cut_off) {
        result.deinit(alloc);
        return .permanent_failure;
    }
    const owned = try alloc.create(streams.Result);
    owned.* = result;
    return .{ .completion = .{ .completion = owned.completed.completion, .context = owned, .deinit_fn = free_result } };
}
