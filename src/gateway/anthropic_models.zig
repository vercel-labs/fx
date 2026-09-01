const std = @import("std");
const credentials = @import("../core/auth/credentials.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");

const Allocator = std.mem.Allocator;
const max_catalog_models: usize = 128;
const max_model_id_bytes: usize = 256;
const max_catalog_bytes: usize = 1024 * 1024;
const fetch_timeout_ms: i64 = 30_000;
const default_models_endpoint = "https://api.anthropic.com/v1/models";
pub const e2e_models_endpoint_env = "FX_E2E_ANTHROPIC_MODELS_URL";
pub const base_url_env = "FX_ANTHROPIC_BASE_URL";

pub const model_catalog_provider = model_catalog.Provider{
    .fetch_fn = fetchCatalogForProvider,
};

pub const cli_model_catalog_provider = gateway_provider.CliModelCatalogProvider{
    .fetch_fn = fetchCliModelCatalog,
};

fn fetchCliModelCatalog(
    _: ?*anyopaque,
    alloc: Allocator,
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
    alloc: Allocator,
    input: model_catalog.FetchInput,
) Allocator.Error!model_catalog.ProviderResult {
    if (input.access.credentialSource() != .anthropic_api_key) {
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
    }
    const credential = input.access.authorizationCredential() orelse
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };

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
    var response = fetchCatalogResponse(
        alloc,
        request_url,
        credential,
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
    if (err == error.AnthropicModelCatalogTooLarge) return .{ .category = .malformed_response };
    return .{ .category = .transport, .retryable = true };
}

pub const FetchResponse = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *FetchResponse, alloc: Allocator) void {
        secretFree(alloc, self.body);
        self.* = undefined;
    }
};

fn secretFree(alloc: Allocator, bytes: []u8) void {
    const secret = @import("../core/auth/secret.zig");
    secret.zeroAndFree(alloc, bytes);
}

const FetchOperation = struct {
    alloc: Allocator,
    url: []const u8,
    credential: []const u8,

    pub fn run(self: *@This()) !FetchResponse {
        var client: std.http.Client = .{ .allocator = self.alloc, .io = io_mod.getIo() };
        defer client.deinit();
        const auth_header = try std.fmt.allocPrint(self.alloc, "Bearer {s}", .{self.credential});
        defer zeroFree(self.alloc, auth_header);
        const body_buffer = try self.alloc.alloc(u8, max_catalog_bytes + 1);
        defer zeroFree(self.alloc, body_buffer);
        var response_writer = std.Io.Writer.fixed(body_buffer);
        const extra_headers = [_]std.http.Header{
            .{ .name = "accept", .value = "application/json" },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
        };
        const result = client.fetch(.{
            .location = .{ .url = self.url },
            .method = .GET,
            .headers = .{
                .authorization = .{ .override = auth_header },
                .user_agent = .{ .override = gateway_client.user_agent },
                .accept_encoding = .omit,
            },
            .extra_headers = &extra_headers,
            .response_writer = &response_writer,
            .redirect_behavior = .unhandled,
        }) catch |err| switch (err) {
            error.WriteFailed => return error.AnthropicModelCatalogTooLarge,
            else => return err,
        };
        const body = response_writer.buffered();
        try validateCatalogBodySize(body.len);
        return .{
            .status = result.status,
            .body = try self.alloc.dupe(u8, body),
        };
    }
};

fn zeroFree(alloc: Allocator, bytes: []u8) void {
    const secret = @import("../core/auth/secret.zig");
    secret.zeroAndFree(alloc, bytes);
}

fn fetchCatalogResponse(
    alloc: Allocator,
    url: []const u8,
    credential: []const u8,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
) !FetchResponse {
    var operation = FetchOperation{
        .alloc = alloc,
        .url = url,
        .credential = credential,
    };
    return gateway_client.runBoundedHttpOperation(
        FetchResponse,
        alloc,
        cancel_flag,
        deadline,
        &operation,
    );
}

fn modelsUrl(alloc: Allocator) ![]u8 {
    if (io_mod.getenv(e2e_models_endpoint_env)) |override| {
        if (!gateway_client.isLoopbackHttpUrl(override)) return error.InvalidE2EAnthropicModelsEndpoint;
        return alloc.dupe(u8, override);
    }
    const base = baseFromEnv();
    if (std.mem.endsWith(u8, base, "/v1/models")) return alloc.dupe(u8, base);
    const trimmed = std.mem.trimEnd(u8, base, "/");
    return std.fmt.allocPrint(alloc, "{s}/v1/models", .{trimmed});
}

fn baseFromEnv() []const u8 {
    const raw = io_mod.getenv(base_url_env) orelse return "https://api.anthropic.com";
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return "https://api.anthropic.com";
    return trimmed;
}

fn parseCatalog(
    alloc: Allocator,
    catalog_json: []const u8,
) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, catalog_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidAnthropicModelCatalog;
    const models = parsed.value.object.get("data") orelse
        return error.InvalidAnthropicModelCatalog;
    if (models != .array) return error.InvalidAnthropicModelCatalog;
    try validateCatalogModelCount(models.array.items.len);

    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &catalog);
    for (models.array.items) |value| {
        if (value != .object) return error.InvalidAnthropicModelCatalog;
        const object = value.object;
        const raw_type = try requiredString(object, "type");
        if (!std.mem.eql(u8, raw_type, "model")) continue;
        const raw_id = try requiredString(object, "id");
        try validateModelId(raw_id);

        const id = try alloc.dupe(u8, raw_id);
        errdefer alloc.free(id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);

        try catalog.append(alloc, .{
            .id = id,
            .model_type = model_type,
            .has_tool_use = true,
        });
    }
    return catalog;
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidAnthropicModelCatalog;
    if (value != .string or value.string.len == 0) return error.InvalidAnthropicModelCatalog;
    return value.string;
}

fn validateModelId(id: []const u8) !void {
    if (id.len == 0 or id.len > max_model_id_bytes) return error.InvalidAnthropicModelCatalog;
    for (id) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidAnthropicModelCatalog;
    }
}

fn validateCatalogBodySize(size: usize) !void {
    if (size > max_catalog_bytes) return error.AnthropicModelCatalogTooLarge;
}

fn validateCatalogModelCount(count: usize) !void {
    if (count > max_catalog_models) return error.InvalidAnthropicModelCatalog;
}

test "Anthropic catalog parser maps provider model entries" {
    const catalog_json =
        \\{"data":[
        \\  {"id":"claude-sonnet-4-5","type":"model","display_name":"Claude Sonnet 4.5"},
        \\  {"id":"claude-opus-4-6","type":"model","display_name":"Claude Opus 4.6"},
        \\  {"id":"not-a-model","type":"other"}
        \\],"has_more":false}
    ;
    var catalog = try parseCatalog(std.testing.allocator, catalog_json);
    defer model_catalog.freeModelCatalog(std.testing.allocator, &catalog);
    try std.testing.expectEqual(@as(usize, 2), catalog.items.len);
    try std.testing.expectEqualStrings("claude-sonnet-4-5", catalog.items[0].id);
    try std.testing.expectEqualStrings("language", catalog.items[0].model_type);
    try std.testing.expect(catalog.items[0].has_tool_use);
    try std.testing.expectEqualStrings("claude-opus-4-6", catalog.items[1].id);
}

test "Anthropic catalog parser rejects malformed payloads" {
    const cases = [_][]const u8{
        "[]",
        "{}",
        "{\"models\":[]}",
        "{\"data\":{}}",
        "{\"data\":[{}]}",
        "{\"data\":[{\"id\":\"\",\"type\":\"model\"}]}",
        "{\"data\":[{\"id\":\"a b\",\"type\":\"model\"}]}",
    };
    for (cases) |case| {
        try expectCatalogParseError(error.InvalidAnthropicModelCatalog, case);
    }
}

fn expectCatalogParseError(expected: anyerror, json: []const u8) !void {
    var catalog = parseCatalog(std.testing.allocator, json) catch |err| {
        try std.testing.expectEqual(expected, err);
        return;
    };
    defer model_catalog.freeModelCatalog(std.testing.allocator, &catalog);
    return error.TestExpectedCatalogFailure;
}

test "Anthropic models URL composes the provider endpoint" {
    const stable = try stableAnthropicCatalogTestEnviron();
    io_mod.setEnvironMap(stable);
    const url = try modelsUrl(std.testing.allocator);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(default_models_endpoint, url);
}

test "Anthropic model ids enforce the exact provider-local bound" {
    const exact_json = try buildCatalogJson(std.testing.allocator, max_model_id_bytes);
    defer std.testing.allocator.free(exact_json);
    var exact = try parseCatalog(std.testing.allocator, exact_json);
    defer model_catalog.freeModelCatalog(std.testing.allocator, &exact);
    try std.testing.expectEqual(@as(usize, 1), exact.items.len);
    try std.testing.expectEqual(max_model_id_bytes, exact.items[0].id.len);

    const excess_json = try buildCatalogJson(std.testing.allocator, max_model_id_bytes + 1);
    defer std.testing.allocator.free(excess_json);
    try expectCatalogParseError(error.InvalidAnthropicModelCatalog, excess_json);
}

fn buildCatalogJson(alloc: Allocator, id_bytes: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"data\":[{\"type\":\"model\",\"id\":\"");
    try out.writer.splatByteAll('a', id_bytes);
    try out.writer.writeAll("\"}]}");
    return out.toOwnedSlice();
}

test "Anthropic catalog requires the anthropic api key credential" {
    const result = try model_catalog_provider.fetch(std.testing.allocator, .{
        .access = .{ .authenticated = .{
            .source = .grok_subscription,
            .credential = "grok-token",
            .team_context = null,
        } },
        .endpoint = "",
    });
    switch (result) {
        .failure => |failure| {
            try std.testing.expectEqual(model_catalog.FailureCategory.authentication, failure.category);
            try std.testing.expectEqual(std.http.Status.unauthorized, failure.http_status.?);
        },
        .catalog => |catalog| {
            var unexpected = catalog;
            model_catalog.freeModelCatalog(std.testing.allocator, &unexpected);
            return error.TestExpectedAuthenticationFailure;
        },
    }
}

test "Anthropic oversized catalog responses are terminal malformed data" {
    const failure = catalogFetchFailure(error.AnthropicModelCatalogTooLarge);
    try std.testing.expectEqual(model_catalog.FailureCategory.malformed_response, failure.category);
    try std.testing.expect(!failure.retryable);
    const cancelled = catalogFetchFailure(error.Cancelled);
    try std.testing.expectEqual(model_catalog.FailureCategory.cancellation, cancelled.category);
    const transport = catalogFetchFailure(error.ConnectionRefused);
    try std.testing.expectEqual(model_catalog.FailureCategory.transport, transport.category);
    try std.testing.expect(transport.retryable);
}

var stable_anthropic_catalog_test_environ: ?*std.process.Environ.Map = null;

fn stableAnthropicCatalogTestEnviron() !*const std.process.Environ.Map {
    if (stable_anthropic_catalog_test_environ) |map| return map;
    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    stable_anthropic_catalog_test_environ = map;
    return map;
}
