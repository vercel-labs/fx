const std = @import("std");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");
const sort_utils = @import("../core/shared/sort_utils.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");

/// OpenRouter's catalog restricted to tool-capable models.
///
/// fx is an agentic client: every turn may issue tool calls, so a model without
/// tool support produces a session that breaks on the first step. Filtering at
/// the source means every listed model can actually run.
const default_models_endpoint = "https://openrouter.ai/api/v1/models?supported_parameters=tools";
const e2e_models_endpoint_env = "FX_E2E_OPENROUTER_MODELS_URL";

const max_catalog_models: usize = 2048;
const max_model_id_bytes: usize = 256;
const max_catalog_bytes: usize = 4 * 1024 * 1024;
const fetch_timeout_ms: i64 = 30_000;

/// OpenRouter names every zero-cost variant with the shared `:free` suffix, so
/// the catalog-level predicate applies unchanged. The parser still derives
/// `is_free` from published pricing; a test pins the two together.
const isFreeModelId = model_catalog.isFreeModelId;

pub const model_catalog_provider = model_catalog.Provider{
    .fetch_fn = fetchCatalogForProvider,
};

pub const cli_model_catalog_provider = gateway_provider.CliModelCatalogProvider{
    .fetch_fn = fetchCliModelCatalog,
};

fn fetchCliModelCatalog(
    _: ?*anyopaque,
    alloc: std.mem.Allocator,
    input: gateway_provider.CliModelCatalogInput,
) gateway_provider.CliModelCatalogResult {
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

fn fetchCatalogForProvider(
    _: ?*anyopaque,
    alloc: std.mem.Allocator,
    input: model_catalog.FetchInput,
) std.mem.Allocator.Error!model_catalog.ProviderResult {
    const request_url = modelsUrl(alloc) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .runtime } };
    };
    defer alloc.free(request_url);

    var fallback_cancel = std.atomic.Value(bool).init(false);
    const cancel_flag = input.cancel_flag orelse &fallback_cancel;
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(fetch_timeout_ms),
    });

    // OpenRouter publishes its catalog without authentication, so an absent or
    // rejected credential still yields the full list rather than a failure.
    var response = fetchCatalogResponse(
        alloc,
        request_url,
        input.access.authorizationCredential(),
        cancel_flag,
        deadline,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = catalogFetchFailure(err) };
    };
    defer response.deinit(alloc);
    if (response.status != .ok) {
        return .{ .failure = model_catalog.failureForHttpStatus(response.status) };
    }

    const catalog = parseCatalog(alloc, response.body) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .malformed_response, .http_status = .ok } };
    };
    return .{ .catalog = catalog };
}

fn catalogFetchFailure(err: anyerror) model_catalog.Failure {
    if (err == error.Cancelled) return .{ .category = .cancellation };
    if (err == error.OpenRouterModelCatalogTooLarge) return .{ .category = .malformed_response };
    return .{ .category = .transport, .retryable = true };
}

fn modelsUrl(alloc: std.mem.Allocator) ![]u8 {
    const override = io_mod.getenv(e2e_models_endpoint_env);
    if (override) |url| {
        if (!gateway_client.isLoopbackHttpUrl(url)) return error.InvalidE2EOpenRouterModelsEndpoint;
        return alloc.dupe(u8, url);
    }
    return alloc.dupe(u8, default_models_endpoint);
}

const FetchResponse = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *FetchResponse, alloc: std.mem.Allocator) void {
        secret.zeroAndFree(alloc, self.body);
        self.* = undefined;
    }
};

const FetchOperation = struct {
    alloc: std.mem.Allocator,
    url: []const u8,
    credential: ?[]const u8,

    pub fn run(self: *@This()) !FetchResponse {
        var client: std.http.Client = .{ .allocator = self.alloc, .io = io_mod.getIo() };
        defer client.deinit();

        const auth_header = if (self.credential) |value|
            try std.fmt.allocPrint(self.alloc, "Bearer {s}", .{value})
        else
            null;
        defer if (auth_header) |header| secret.zeroAndFree(self.alloc, header);

        const body_buffer = try self.alloc.alloc(u8, max_catalog_bytes + 1);
        defer secret.zeroAndFree(self.alloc, body_buffer);
        var response_writer = std.Io.Writer.fixed(body_buffer);
        var extra_headers: [1]std.http.Header = .{.{ .name = "accept", .value = "application/json" }};

        const result = client.fetch(.{
            .location = .{ .url = self.url },
            .method = .GET,
            .headers = .{
                .authorization = if (auth_header) |header|
                    .{ .override = header }
                else
                    .omit,
                .user_agent = .{ .override = gateway_client.user_agent },
                .accept_encoding = .omit,
            },
            .extra_headers = &extra_headers,
            .response_writer = &response_writer,
            .redirect_behavior = .unhandled,
        }) catch |err| switch (err) {
            error.WriteFailed => return error.OpenRouterModelCatalogTooLarge,
            else => return err,
        };
        const body = response_writer.buffered();
        if (body.len > max_catalog_bytes) return error.OpenRouterModelCatalogTooLarge;
        return .{ .status = result.status, .body = try self.alloc.dupe(u8, body) };
    }
};

fn fetchCatalogResponse(
    alloc: std.mem.Allocator,
    url: []const u8,
    credential: ?[]const u8,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
) !FetchResponse {
    var operation = FetchOperation{ .alloc = alloc, .url = url, .credential = credential };
    return gateway_client.runBoundedHttpOperation(
        FetchResponse,
        alloc,
        cancel_flag,
        deadline,
        &operation,
    );
}

/// Parses the `/api/v1/models` payload into catalog entries, free models first.
///
/// The response is dominated by `description` prose that fx never renders, so
/// those fields are skipped rather than copied and discarded.
pub fn parseCatalog(
    alloc: std.mem.Allocator,
    catalog_json: []const u8,
) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, catalog_json, .{}) catch
        return error.InvalidOpenRouterModelCatalog;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidOpenRouterModelCatalog;
    const data = parsed.value.object.get("data") orelse return error.InvalidOpenRouterModelCatalog;
    if (data != .array) return error.InvalidOpenRouterModelCatalog;
    if (data.array.items.len > max_catalog_models) return error.InvalidOpenRouterModelCatalog;

    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &catalog);

    for (data.array.items) |entry| {
        if (entry != .object) return error.InvalidOpenRouterModelCatalog;
        const object = entry.object;

        const raw_id = stringField(object, "id") orelse return error.InvalidOpenRouterModelCatalog;
        if (raw_id.len == 0 or raw_id.len > max_model_id_bytes) return error.InvalidOpenRouterModelCatalog;

        // Skip anything that cannot drive an agent turn. The endpoint is
        // already filtered, but a mirrored or overridden URL may not be.
        if (!supportsParameter(object, "tools")) continue;
        if (!producesText(object)) continue;

        const id = try alloc.dupe(u8, raw_id);
        errdefer alloc.free(id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);

        var reasoning_efforts: std.ArrayList(types.ReasoningEffort) = .empty;
        errdefer reasoning_efforts.deinit(alloc);
        const has_reasoning = supportsParameter(object, "reasoning");
        if (has_reasoning) try appendReasoningEfforts(alloc, &reasoning_efforts, object);

        const top_provider = object.get("top_provider");
        try catalog.append(alloc, .{
            .id = id,
            .model_type = model_type,
            .released = integerField(object, "created") orelse 0,
            .has_tool_use = true,
            .has_reasoning = has_reasoning,
            .reasoning_efforts = reasoning_efforts,
            .has_vision = hasInputModality(object, "image"),
            .has_file_input = hasInputModality(object, "file"),
            // OpenRouter exposes web search as a request-level `plugins`
            // opt-in rather than a per-model capability.
            .has_web_search = false,
            .context_window = boundedU32(integerField(object, "context_length")),
            .max_tokens = if (top_provider) |value|
                if (value == .object) boundedU32(integerField(value.object, "max_completion_tokens")) else 0
            else
                0,
            .is_free = isFreePricing(object),
        });
    }

    // Free models lead so the zero-cost options are the first thing a user
    // sees in `/model` and `fx models`.
    sort_utils.sort(model_catalog.ModelCatalogEntry, catalog.items, {}, compareFreeFirst);
    return catalog;
}

/// Free first, then newest, then id. Ordering is this provider's own: the
/// gateway's `compareModelCatalogEntries` and `projectPickerModelCatalog`
/// encode Vercel-specific product policy and are never applied here.
fn compareFreeFirst(
    _: void,
    a: model_catalog.ModelCatalogEntry,
    b: model_catalog.ModelCatalogEntry,
) bool {
    if (a.is_free != b.is_free) return a.is_free;
    if (a.released != b.released) return a.released > b.released;
    return std.mem.lessThan(u8, a.id, b.id);
}

/// A model is free when both token prices are exactly zero. Pricing is the
/// authoritative signal; the `:free` id suffix is only a display convenience.
fn isFreePricing(object: std.json.ObjectMap) bool {
    const pricing = object.get("pricing") orelse return false;
    if (pricing != .object) return false;
    const prompt = stringField(pricing.object, "prompt") orelse return false;
    const completion = stringField(pricing.object, "completion") orelse return false;
    return isZeroPrice(prompt) and isZeroPrice(completion);
}

/// Prices arrive as decimal strings ("0", "0.0", "0.0000025").
fn isZeroPrice(raw: []const u8) bool {
    const value = std.fmt.parseFloat(f64, raw) catch return false;
    return value == 0;
}

fn supportsParameter(object: std.json.ObjectMap, name: []const u8) bool {
    const value = object.get("supported_parameters") orelse return false;
    if (value != .array) return false;
    for (value.array.items) |item| {
        if (item != .string) continue;
        if (std.mem.eql(u8, item.string, name)) return true;
    }
    return false;
}

fn producesText(object: std.json.ObjectMap) bool {
    const architecture = object.get("architecture") orelse return true;
    if (architecture != .object) return true;
    const modalities = architecture.object.get("output_modalities") orelse return true;
    if (modalities != .array) return true;
    for (modalities.array.items) |item| {
        if (item != .string) continue;
        if (std.mem.eql(u8, item.string, "text")) return true;
    }
    return false;
}

fn hasInputModality(object: std.json.ObjectMap, name: []const u8) bool {
    const architecture = object.get("architecture") orelse return false;
    if (architecture != .object) return false;
    const modalities = architecture.object.get("input_modalities") orelse return false;
    if (modalities != .array) return false;
    for (modalities.array.items) |item| {
        if (item != .string) continue;
        if (std.mem.eql(u8, item.string, name)) return true;
    }
    return false;
}

fn appendReasoningEfforts(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(types.ReasoningEffort),
    object: std.json.ObjectMap,
) !void {
    const reasoning = object.get("reasoning") orelse return;
    if (reasoning != .object) return;
    const efforts = reasoning.object.get("supported_efforts") orelse return;
    if (efforts != .array) return;
    for (efforts.array.items) |item| {
        if (item != .string) continue;
        if (out.items.len >= types.ReasoningEffort.max_options) break;
        const effort = types.ReasoningEffort.parse(item.string) orelse continue;
        try out.append(alloc, effort);
    }
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn integerField(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |integer| integer,
        .float => |float| @intFromFloat(float),
        else => null,
    };
}

fn boundedU32(value: ?i64) u32 {
    const raw = value orelse return 0;
    if (raw <= 0) return 0;
    return std.math.cast(u32, raw) orelse std.math.maxInt(u32);
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

/// A trimmed capture of the real `/api/v1/models?supported_parameters=tools`
/// response: one free model, two paid ones (reasoning and vision), a
/// non-tool-capable model, and an image-only output model.
const catalog_fixture =
    \\{"data":[
    \\{"id":"z-ai/glm-5.3-flash","created":1787752741,"context_length":1048576,
    \\ "architecture":{"input_modalities":["text","image","video"],"output_modalities":["text"]},
    \\ "pricing":{"prompt":"0.000000075","completion":"0.00000025"},
    \\ "top_provider":{"max_completion_tokens":131072},
    \\ "supported_parameters":["max_tokens","reasoning","tool_choice","tools"],
    \\ "reasoning":{"mandatory":true,"supported_efforts":["max","high","low"]}},
    \\{"id":"z-ai/glm-5.2:free","created":1781631930,"context_length":1048576,
    \\ "architecture":{"input_modalities":["text"],"output_modalities":["text"]},
    \\ "pricing":{"prompt":"0","completion":"0"},
    \\ "top_provider":{"max_completion_tokens":230400},
    \\ "supported_parameters":["max_tokens","reasoning","tool_choice","tools"],
    \\ "reasoning":{"mandatory":false,"supported_efforts":["xhigh","high"]}},
    \\{"id":"vendor/no-tools","created":1787773060,"context_length":128000,
    \\ "architecture":{"input_modalities":["text"],"output_modalities":["text"]},
    \\ "pricing":{"prompt":"0","completion":"0"},
    \\ "supported_parameters":["max_tokens","temperature"]},
    \\{"id":"vendor/image-out","created":1787773061,"context_length":128000,
    \\ "architecture":{"input_modalities":["text"],"output_modalities":["image"]},
    \\ "pricing":{"prompt":"0","completion":"0"},
    \\ "supported_parameters":["tools"]},
    \\{"id":"qwen/qwen3.8-flash","created":1787773060,"context_length":1000000,
    \\ "architecture":{"input_modalities":["text","image","file"],"output_modalities":["text"]},
    \\ "pricing":{"prompt":"0.00000015","completion":"0.00000047"},
    \\ "top_provider":{"max_completion_tokens":131072},
    \\ "supported_parameters":["max_tokens","tool_choice","tools"]}
    \\],"total_count":5}
;

test "OpenRouter catalog maps published fields onto the neutral entry" {
    var catalog = try parseCatalog(testing.allocator, catalog_fixture);
    defer model_catalog.freeModelCatalog(testing.allocator, &catalog);

    // Non-tool and non-text-output models never reach the catalog.
    try testing.expectEqual(@as(usize, 3), catalog.items.len);
    for (catalog.items) |entry| {
        try testing.expect(!std.mem.eql(u8, entry.id, "vendor/no-tools"));
        try testing.expect(!std.mem.eql(u8, entry.id, "vendor/image-out"));
        try testing.expect(entry.has_tool_use);
        try testing.expectEqualStrings("language", entry.model_type);
        // Web search is a request-level plugin on OpenRouter, never a model trait.
        try testing.expect(!entry.has_web_search);
    }

    const free = catalog.items[0];
    try testing.expectEqualStrings("z-ai/glm-5.2:free", free.id);
    try testing.expectEqual(@as(u32, 1_048_576), free.context_window);
    try testing.expectEqual(@as(u32, 230_400), free.max_tokens);
    try testing.expectEqual(@as(i64, 1781631930), free.released);
    try testing.expect(free.has_reasoning);
    try testing.expectEqual(@as(usize, 2), free.reasoning_efforts.items.len);
    try testing.expectEqualStrings("xhigh", free.reasoning_efforts.items[0].label());
    try testing.expect(!free.has_vision);

    const vision = for (catalog.items) |entry| {
        if (std.mem.eql(u8, entry.id, "qwen/qwen3.8-flash")) break entry;
    } else unreachable;
    try testing.expect(vision.has_vision);
    try testing.expect(vision.has_file_input);
    try testing.expect(!vision.has_reasoning);
}

test "OpenRouter catalog lists free models first" {
    var catalog = try parseCatalog(testing.allocator, catalog_fixture);
    defer model_catalog.freeModelCatalog(testing.allocator, &catalog);

    try testing.expect(catalog.items[0].is_free);
    // Everything after the free block is paid, newest first.
    var seen_paid = false;
    for (catalog.items) |entry| {
        if (!entry.is_free) {
            seen_paid = true;
        } else {
            try testing.expect(!seen_paid);
        }
    }
    // Within the paid block, newest first: qwen (1787773060) precedes
    // glm-5.3-flash (1787752741).
    try testing.expectEqualStrings("qwen/qwen3.8-flash", catalog.items[1].id);
    try testing.expectEqualStrings("z-ai/glm-5.3-flash", catalog.items[2].id);
}

test "OpenRouter free pricing and the :free id suffix agree" {
    // `is_free` comes from published pricing; `isFreeModelId` is the cheap
    // display predicate used where only an id string is available. This test
    // is what keeps the two from silently diverging.
    var catalog = try parseCatalog(testing.allocator, catalog_fixture);
    defer model_catalog.freeModelCatalog(testing.allocator, &catalog);

    for (catalog.items) |entry| {
        try testing.expectEqual(entry.is_free, isFreeModelId(entry.id));
    }

    try testing.expect(isFreeModelId("z-ai/glm-5.2:free"));
    try testing.expect(!isFreeModelId("z-ai/glm-5.2"));
    try testing.expect(!isFreeModelId("free/model"));
}

test "OpenRouter zero-price detection accepts every decimal spelling" {
    try testing.expect(isZeroPrice("0"));
    try testing.expect(isZeroPrice("0.0"));
    try testing.expect(isZeroPrice("0.00000000"));
    try testing.expect(!isZeroPrice("0.0000025"));
    try testing.expect(!isZeroPrice(""));
    try testing.expect(!isZeroPrice("free"));
}

test "OpenRouter catalog rejects malformed payloads" {
    for ([_][]const u8{
        "[]",
        "{}",
        "{\"data\":{}}",
        "{\"data\":[3]}",
        "not json",
    }) |body| {
        try testing.expectError(
            error.InvalidOpenRouterModelCatalog,
            parseCatalog(testing.allocator, body),
        );
    }

    // A model with a missing or oversized id is a malformed catalog, not a
    // silently skipped row.
    try testing.expectError(error.InvalidOpenRouterModelCatalog, parseCatalog(
        testing.allocator,
        "{\"data\":[{\"context_length\":10,\"supported_parameters\":[\"tools\"]}]}",
    ));
}

test "OpenRouter catalog tolerates absent optional fields" {
    var catalog = try parseCatalog(
        testing.allocator,
        "{\"data\":[{\"id\":\"vendor/minimal\",\"supported_parameters\":[\"tools\"]}]}",
    );
    defer model_catalog.freeModelCatalog(testing.allocator, &catalog);

    try testing.expectEqual(@as(usize, 1), catalog.items.len);
    const entry = catalog.items[0];
    try testing.expectEqualStrings("vendor/minimal", entry.id);
    try testing.expectEqual(@as(u32, 0), entry.context_window);
    try testing.expectEqual(@as(u32, 0), entry.max_tokens);
    try testing.expect(!entry.is_free);
    try testing.expect(!entry.has_reasoning);
    try testing.expectEqual(@as(usize, 0), entry.reasoning_efforts.items.len);
}

test "OpenRouter models endpoint override is restricted to loopback" {
    // The default endpoint pre-filters to tool-capable models.
    try testing.expect(std.mem.indexOf(u8, default_models_endpoint, "supported_parameters=tools") != null);
    try testing.expect(!gateway_client.isLoopbackHttpUrl("https://evil.example/api/v1/models"));
    try testing.expect(gateway_client.isLoopbackHttpUrl("http://127.0.0.1:9/api/v1/models"));
}
