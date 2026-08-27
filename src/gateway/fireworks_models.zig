const std = @import("std");
const credentials = @import("../core/auth/credentials.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");
const gateway_client = @import("client.zig");

const max_catalog_models: usize = 256;
const max_model_id_bytes: usize = 1024;
const max_catalog_bytes: usize = 2 * 1024 * 1024;
const fetch_timeout_ms: i64 = 30_000;
const default_models_endpoint = "https://api.fireworks.ai/inference/v1/models";
const e2e_models_endpoint_env = "FX_E2E_FIREWORKS_MODELS_URL";

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
    if (input.access.credentialSource() != .fireworks_api_key) {
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
    }
    const credential = input.access.authorizationCredential() orelse
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
    const url = modelsUrl() catch return .{ .failure = .{ .category = .runtime } };
    var fallback_cancel = std.atomic.Value(bool).init(false);
    const cancel_flag = input.cancel_flag orelse &fallback_cancel;
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(fetch_timeout_ms),
    });
    var operation = FetchOperation{ .alloc = alloc, .url = url, .credential = credential };
    var response = gateway_client.runBoundedHttpOperation(
        FetchResponse,
        alloc,
        cancel_flag,
        deadline,
        &operation,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = if (err == error.Cancelled)
            .{ .category = .cancellation }
        else
            .{ .category = .transport, .retryable = true } };
    };
    defer response.deinit(alloc);
    if (response.status != .ok) return .{ .failure = model_catalog.failureForHttpStatus(response.status) };
    const catalog = parseCatalog(alloc, response.body) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .malformed_response, .http_status = .ok } };
    };
    return .{ .catalog = catalog };
}

const FetchResponse = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *FetchResponse, alloc: std.mem.Allocator) void {
        secret.zeroAndFree(alloc, self.body);
    }
};

const FetchOperation = struct {
    alloc: std.mem.Allocator,
    url: []const u8,
    credential: []const u8,

    pub fn run(self: *@This()) !FetchResponse {
        var client: std.http.Client = .{ .allocator = self.alloc, .io = io_mod.getIo() };
        defer client.deinit();
        const auth_header = try std.fmt.allocPrint(self.alloc, "Bearer {s}", .{self.credential});
        defer secret.zeroAndFree(self.alloc, auth_header);
        const body_buffer = try self.alloc.alloc(u8, max_catalog_bytes + 1);
        defer secret.zeroAndFree(self.alloc, body_buffer);
        var response_writer = std.Io.Writer.fixed(body_buffer);
        const result = client.fetch(.{
            .location = .{ .url = self.url },
            .method = .GET,
            .headers = .{
                .authorization = .{ .override = auth_header },
                .user_agent = .{ .override = gateway_client.user_agent },
                .accept_encoding = .omit,
            },
            .extra_headers = &.{.{ .name = "accept", .value = "application/json" }},
            .response_writer = &response_writer,
            .redirect_behavior = .unhandled,
        }) catch |err| switch (err) {
            error.WriteFailed => return error.FireworksModelCatalogTooLarge,
            else => return err,
        };
        return .{ .status = result.status, .body = try self.alloc.dupe(u8, response_writer.buffered()) };
    }
};

fn modelsUrl() ![]const u8 {
    const value = io_mod.getenv(e2e_models_endpoint_env) orelse return default_models_endpoint;
    if (!gateway_client.isLoopbackHttpUrl(value)) return error.InvalidE2EFireworksModelsEndpoint;
    return value;
}

fn parseCatalog(alloc: std.mem.Allocator, body: []const u8) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidFireworksModelCatalog;
    const data = parsed.value.object.get("data") orelse return error.InvalidFireworksModelCatalog;
    if (data != .array or data.array.items.len > max_catalog_models) return error.InvalidFireworksModelCatalog;

    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &catalog);
    for (data.array.items) |value| {
        if (value != .object) return error.InvalidFireworksModelCatalog;
        const object = value.object;
        if (!optionalBool(object, "supports_chat") or !optionalBool(object, "supports_tools")) continue;
        const kind = optionalString(object, "kind") orelse "";
        if (containsIgnoreCase(kind, "embedding") or containsIgnoreCase(kind, "rerank")) continue;
        const raw_id = optionalString(object, "id") orelse return error.InvalidFireworksModelCatalog;
        try validateModelId(raw_id);
        const id = try alloc.dupe(u8, raw_id);
        errdefer alloc.free(id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        try catalog.append(alloc, .{
            .id = id,
            .model_type = model_type,
            .released = optionalInteger(object, "created") orelse 0,
            .has_tool_use = true,
            .has_vision = optionalBool(object, "supports_image_input"),
            .has_file_input = optionalBool(object, "supports_image_input"),
            .context_window = optionalPositiveU32(object, "context_length") orelse 0,
        });
    }
    return catalog;
}

fn optionalString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn optionalBool(object: std.json.ObjectMap, key: []const u8) bool {
    const value = object.get(key) orelse return false;
    return value == .bool and value.bool;
}

fn optionalInteger(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return if (value == .integer) value.integer else null;
}

fn optionalPositiveU32(object: std.json.ObjectMap, key: []const u8) ?u32 {
    const value = object.get(key) orelse return null;
    if (value != .integer or value.integer <= 0) return null;
    return std.math.cast(u32, value.integer);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn validateModelId(id: []const u8) !void {
    if (id.len == 0 or id.len > max_model_id_bytes) return error.InvalidFireworksModelCatalog;
    for (id) |byte| if (byte <= 0x20 or byte == 0x7f) return error.InvalidFireworksModelCatalog;
}

test "Fireworks catalog keeps only chat models with tool use" {
    const body =
        \\{"data":[
        \\  {"id":"accounts/fireworks/models/kimi-k3","kind":"HF_BASE_MODEL","supports_chat":true,"supports_tools":true,"supports_image_input":true,"context_length":1048576,"created":10},
        \\  {"id":"accounts/fireworks/models/embed","kind":"EMBEDDING","supports_chat":true,"supports_tools":true},
        \\  {"id":"accounts/fireworks/models/no-tools","kind":"HF_BASE_MODEL","supports_chat":true,"supports_tools":false}
        \\]}
    ;
    var catalog = try parseCatalog(std.testing.allocator, body);
    defer model_catalog.freeModelCatalog(std.testing.allocator, &catalog);
    try std.testing.expectEqual(@as(usize, 1), catalog.items.len);
    try std.testing.expectEqualStrings("accounts/fireworks/models/kimi-k3", catalog.items[0].id);
    try std.testing.expect(catalog.items[0].has_tool_use);
    try std.testing.expect(catalog.items[0].has_vision);
    try std.testing.expectEqual(@as(u32, 1_048_576), catalog.items[0].context_window);
}
