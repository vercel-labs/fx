const std = @import("std");
const credentials = @import("../core/auth/credentials.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");

const max_models_per_surface: usize = 128;
const max_model_id_bytes: usize = 256;
const max_catalog_bytes: usize = 1024 * 1024;
const fetch_timeout_ms: i64 = 30_000;
const zen_models_endpoint = "https://opencode.ai/zen/v1/models";
const go_models_endpoint = "https://opencode.ai/zen/go/v1/models";
const e2e_zen_models_endpoint_env = "FX_E2E_OPENCODE_ZEN_MODELS_URL";
const e2e_go_models_endpoint_env = "FX_E2E_OPENCODE_GO_MODELS_URL";
const go_model_prefix = "go/";

// OpenCode's /models responses do not include each model's wire protocol. fx
// currently implements OpenAI-compatible Chat Completions for this provider,
// so intersect the live catalogs with the protocol mapping published in the
// OpenCode source tree instead of advertising Responses, Messages, or Gemini
// models through an incompatible encoder.
const zen_chat_completion_models = [_][]const u8{
    "deepseek-v4-pro",
    "deepseek-v4-flash",
    "minimax-m3",
    "minimax-m2.7",
    "minimax-m2.5",
    "glm-5.2",
    "glm-5.1",
    "glm-5",
    "kimi-k2.5",
    "kimi-k2.6",
    "kimi-k2.7-code",
    "kimi-k3",
    "big-pickle",
    "x-preview-f-free",
    "mimo-v2.5-free",
    "hy3-free",
    "nemotron-3-ultra-free",
    "nemotron-3.5-lightning-free",
};

const go_chat_completion_models = [_][]const u8{
    "glm-5.3",
    "glm-5.2",
    "glm-5.1",
    "kimi-k3",
    "kimi-k2.7-code",
    "kimi-k2.6",
    "deepseek-v4-pro",
    "deepseek-v4-flash",
    "deepseek-v4-flash-vision-exp",
    "mimo-v2.5",
    "mimo-v2.5-pro",
    "hy3",
    "ox-alpha-free",
};

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
            break :blk .{ .loaded = .{
                .ids = ids,
                .provenance = loaded.provenance,
            } };
        },
        .failed => |failure| .{ .failure = failure },
    };
}

fn fetchCatalogForProvider(
    _: ?*anyopaque,
    alloc: std.mem.Allocator,
    input: model_catalog.FetchInput,
) std.mem.Allocator.Error!model_catalog.ProviderResult {
    if (input.access.credentialSource() != .opencode_api_key) {
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
    }

    var fallback_cancel = std.atomic.Value(bool).init(false);
    const cancel_flag = input.cancel_flag orelse &fallback_cancel;
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(fetch_timeout_ms),
    });

    const zen_body = fetchModelsBody(alloc, zen_models_endpoint, e2e_zen_models_endpoint_env, cancel_flag, deadline) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = catalogFetchFailure(err) };
    };
    defer alloc.free(zen_body);
    const go_body = fetchModelsBody(alloc, go_models_endpoint, e2e_go_models_endpoint_env, cancel_flag, deadline) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = catalogFetchFailure(err) };
    };
    defer alloc.free(go_body);

    const catalog = parseCatalog(alloc, zen_body, go_body) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .malformed_response, .http_status = .ok } };
    };
    return .{ .catalog = catalog };
}

fn catalogFetchFailure(err: anyerror) model_catalog.Failure {
    if (err == error.Cancelled) return .{ .category = .cancellation };
    if (err == error.OpenCodeModelCatalogTooLarge) return .{ .category = .malformed_response };
    return .{ .category = .transport, .retryable = true };
}

const ModelsGetOperation = struct {
    alloc: std.mem.Allocator,
    url: []const u8,

    const Output = struct {
        status: std.http.Status,
        body: []u8,

        pub fn deinit(self: *Output, alloc: std.mem.Allocator) void {
            alloc.free(self.body);
        }
    };

    pub fn run(self: *@This()) !Output {
        var client: std.http.Client = .{ .allocator = self.alloc, .io = io_mod.getIo() };
        defer client.deinit();
        const body_buffer = try self.alloc.alloc(u8, max_catalog_bytes + 1);
        defer self.alloc.free(body_buffer);
        var response_writer = std.Io.Writer.fixed(body_buffer);
        const response = client.fetch(.{
            .location = .{ .url = self.url },
            .method = .GET,
            .headers = .{
                .accept_encoding = .omit,
                .user_agent = .{ .override = gateway_client.user_agent },
            },
            .response_writer = &response_writer,
        }) catch |err| switch (err) {
            error.WriteFailed => return error.OpenCodeModelCatalogTooLarge,
            else => return err,
        };
        const body = response_writer.buffered();
        if (body.len > max_catalog_bytes) return error.OpenCodeModelCatalogTooLarge;
        return .{ .status = response.status, .body = try self.alloc.dupe(u8, body) };
    }
};

fn fetchModelsBody(
    alloc: std.mem.Allocator,
    default_url: []const u8,
    e2e_url_env: []const u8,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
) ![]u8 {
    const request_url = if (io_mod.getenv(e2e_url_env)) |override| blk: {
        if (!gateway_client.isLoopbackHttpUrl(override)) return error.InvalidE2EOpenCodeEndpoint;
        break :blk override;
    } else default_url;
    var operation = ModelsGetOperation{
        .alloc = alloc,
        .url = request_url,
    };
    var output = try gateway_client.runBoundedHttpOperation(
        ModelsGetOperation.Output,
        alloc,
        cancel_flag,
        deadline,
        &operation,
    );
    if (output.status != .ok) {
        output.deinit(alloc);
        return error.OpenCodeModelsEndpointFailed;
    }
    return output.body;
}

fn parseCatalog(
    alloc: std.mem.Allocator,
    zen_json: []const u8,
    go_json: []const u8,
) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &catalog);
    try appendSurface(alloc, &catalog, zen_json, "", &zen_chat_completion_models);
    try appendSurface(alloc, &catalog, go_json, go_model_prefix, &go_chat_completion_models);
    if (catalog.items.len == 0) return error.InvalidOpenCodeModelCatalog;
    for (catalog.items, 0..) |entry, index| {
        if (!std.mem.endsWith(u8, entry.id, "-free")) continue;
        if (index > 0) std.mem.swap(model_catalog.ModelCatalogEntry, &catalog.items[0], &catalog.items[index]);
        break;
    }
    return catalog;
}

fn appendSurface(
    alloc: std.mem.Allocator,
    catalog: *std.ArrayList(model_catalog.ModelCatalogEntry),
    body: []const u8,
    id_prefix: []const u8,
    supported_models: []const []const u8,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidOpenCodeModelCatalog;
    const data = parsed.value.object.get("data") orelse return error.InvalidOpenCodeModelCatalog;
    if (data != .array) return error.InvalidOpenCodeModelCatalog;
    for (data.array.items) |value| {
        if (value != .object) continue;
        const raw_id = stringField(value.object, "id") orelse continue;
        if (raw_id.len == 0 or raw_id.len > max_model_id_bytes) continue;
        if (!containsModel(supported_models, raw_id)) continue;
        if (findDuplicate(catalog.items, id_prefix, raw_id)) continue;
        if (catalog.items.len >= max_models_per_surface * 2) return error.OpenCodeModelCatalogTooLarge;
        const id = try std.fmt.allocPrint(alloc, "{s}{s}", .{ id_prefix, raw_id });
        errdefer alloc.free(id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        try catalog.append(alloc, .{
            .id = id,
            .model_type = model_type,
            .has_tool_use = true,
        });
    }
}

fn containsModel(supported_models: []const []const u8, raw_id: []const u8) bool {
    for (supported_models) |supported| if (std.mem.eql(u8, supported, raw_id)) return true;
    return false;
}

pub fn supportsChatCompletionsModel(model: []const u8) bool {
    if (std.mem.startsWith(u8, model, go_model_prefix)) {
        return containsModel(&go_chat_completion_models, model[go_model_prefix.len..]);
    }
    return containsModel(&zen_chat_completion_models, model);
}

fn isFreeModel(model: []const u8) bool {
    return std.mem.endsWith(u8, model, "-free") or std.mem.eql(u8, model, "big-pickle");
}

fn isGoModel(model: []const u8) bool {
    return std.mem.startsWith(u8, model, go_model_prefix);
}

pub fn selectAvailableModel(model_ids: []const []u8, preferred: []const u8) ?[]const u8 {
    for (model_ids) |model| if (std.mem.eql(u8, model, preferred)) return model;

    const preferred_is_free = isFreeModel(preferred);
    const preferred_is_go = isGoModel(preferred);
    if (preferred_is_free) {
        for (model_ids) |model| {
            if (isGoModel(model) == preferred_is_go and isFreeModel(model)) return model;
        }
    }
    for (model_ids) |model| {
        if (isGoModel(model) == preferred_is_go) return model;
    }
    return if (model_ids.len > 0) model_ids[0] else null;
}

/// Rejects an exact full-id repeat within or across surfaces. The same model
/// name on both surfaces is not a duplicate: zen and go are distinct routes.
fn findDuplicate(entries: []const model_catalog.ModelCatalogEntry, id_prefix: []const u8, raw_id: []const u8) bool {
    for (entries) |entry| {
        if (entry.id.len != id_prefix.len + raw_id.len) continue;
        if (!std.mem.startsWith(u8, entry.id, id_prefix)) continue;
        if (!std.mem.eql(u8, entry.id[id_prefix.len..], raw_id)) continue;
        return true;
    }
    return false;
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

test "parseCatalog merges both surfaces and keeps same-name models as distinct routes" {
    const zen = "{\"object\":\"list\",\"data\":[{\"id\":\"kimi-k3\",\"object\":\"model\"},{\"id\":\"glm-5\",\"object\":\"model\"},{\"id\":\"gpt-5.6-sol\",\"object\":\"model\"}]}";
    const go = "{\"object\":\"list\",\"data\":[{\"id\":\"kimi-k3\",\"object\":\"model\"},{\"id\":\"kimi-k3\",\"object\":\"model\"},{\"id\":\"deepseek-v4-flash\",\"object\":\"model\"},{\"id\":\"minimax-m3\",\"object\":\"model\"}]}";
    var catalog = try parseCatalog(std.testing.allocator, zen, go);
    defer model_catalog.freeModelCatalog(std.testing.allocator, &catalog);
    try std.testing.expectEqual(@as(usize, 4), catalog.items.len);
    try std.testing.expectEqualStrings("kimi-k3", catalog.items[0].id);
    try std.testing.expectEqualStrings("glm-5", catalog.items[1].id);
    try std.testing.expectEqualStrings("go/kimi-k3", catalog.items[2].id);
    try std.testing.expectEqualStrings("go/deepseek-v4-flash", catalog.items[3].id);
    for (catalog.items) |entry| {
        try std.testing.expectEqualStrings("language", entry.model_type);
        try std.testing.expect(entry.has_tool_use);
    }
}

test "parseCatalog hides live models that require unsupported OpenCode protocols" {
    const unsupported_zen = "{\"data\":[{\"id\":\"gpt-5.6-sol\"},{\"id\":\"claude-opus-5\"}]}";
    const unsupported_go = "{\"data\":[{\"id\":\"grok-4.5\"},{\"id\":\"minimax-m3\"}]}";
    try std.testing.expectError(
        error.InvalidOpenCodeModelCatalog,
        parseCatalog(std.testing.allocator, unsupported_zen, unsupported_go),
    );
}

test "protocol allowlist distinguishes Zen and Go model routes" {
    try std.testing.expect(supportsChatCompletionsModel("big-pickle"));
    try std.testing.expect(supportsChatCompletionsModel("go/kimi-k3"));
    try std.testing.expect(!supportsChatCompletionsModel("gpt-5.6-sol"));
    try std.testing.expect(!supportsChatCompletionsModel("go/minimax-m3"));
    try std.testing.expect(!supportsChatCompletionsModel("go/"));
}

test "stale OpenCode selection stays on its surface and free tier" {
    var ids = [_][]u8{
        @constCast("deepseek-v4-pro"),
        @constCast("x-preview-f-free"),
        @constCast("go/glm-5.3"),
        @constCast("go/ox-alpha-free"),
    };
    try std.testing.expectEqualStrings("x-preview-f-free", selectAvailableModel(&ids, "deepseek-v4-flash-free").?);
    try std.testing.expectEqualStrings("go/ox-alpha-free", selectAvailableModel(&ids, "go/retired-free").?);
    try std.testing.expectEqualStrings("go/glm-5.3", selectAvailableModel(&ids, "go/retired-paid").?);
    try std.testing.expectEqualStrings("deepseek-v4-pro", selectAvailableModel(&ids, "retired-paid").?);
}

test "OpenCode catalog puts explicit free models first" {
    const zen = "{\"data\":[{\"id\":\"deepseek-v4-pro\"},{\"id\":\"x-preview-f-free\"}]}";
    const go = "{\"data\":[{\"id\":\"glm-5.3\"},{\"id\":\"ox-alpha-free\"}]}";
    var catalog = try parseCatalog(std.testing.allocator, zen, go);
    defer model_catalog.freeModelCatalog(std.testing.allocator, &catalog);
    try std.testing.expectEqualStrings("x-preview-f-free", catalog.items[0].id);
    try std.testing.expectEqualStrings("deepseek-v4-pro", catalog.items[1].id);
    try std.testing.expectEqualStrings("go/glm-5.3", catalog.items[2].id);
    try std.testing.expectEqualStrings("go/ox-alpha-free", catalog.items[3].id);
}

test "parseCatalog rejects empty or malformed catalogs" {
    try std.testing.expectError(error.InvalidOpenCodeModelCatalog, parseCatalog(std.testing.allocator, "{}", "{}"));
    try std.testing.expectError(error.InvalidOpenCodeModelCatalog, parseCatalog(std.testing.allocator, "{\"data\":[]}", "{\"data\":[]}"));
}
