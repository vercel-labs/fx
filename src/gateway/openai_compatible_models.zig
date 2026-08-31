const std = @import("std");
const credentials = @import("../core/auth/credentials.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const openai_transport = @import("../core/gateway/openai_transport.zig");
const secret = @import("../core/auth/secret.zig");
const io_mod = @import("../core/shared/io.zig");
const gateway_client = @import("client.zig");
const openai_compatible = @import("openai_compatible.zig");

const Allocator = std.mem.Allocator;
const max_catalog_models: usize = 512;
const max_model_id_bytes: usize = 1024;
const max_catalog_bytes: usize = 4 * 1024 * 1024;
const fetch_timeout_ms: i64 = 30_000;

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
    if (input.access.credentialSource() != .stored_key) {
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
    if (err == error.OpenAiModelCatalogTooLarge) return .{ .category = .malformed_response };
    return .{ .category = .transport, .retryable = true };
}

const FetchResponse = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *FetchResponse, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.body);
        self.* = undefined;
    }
};

const FetchOperation = struct {
    alloc: Allocator,
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
            .extra_headers = &.{
                .{ .name = "accept", .value = "application/json" },
            },
            .response_writer = &response_writer,
            .redirect_behavior = .unhandled,
        }) catch |err| switch (err) {
            error.WriteFailed => return error.OpenAiModelCatalogTooLarge,
            else => return err,
        };
        const body = response_writer.buffered();
        if (body.len > max_catalog_bytes) return error.OpenAiModelCatalogTooLarge;
        return .{
            .status = result.status,
            .body = try self.alloc.dupe(u8, body),
        };
    }
};

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
        if (!gateway_client.isLoopbackHttpUrl(override)) return error.InvalidE2EOpenAiModelsEndpoint;
        return alloc.dupe(u8, override);
    }
    const formatted = try openai_transport.formatModelsUrl(alloc, openai_compatible.resolveBaseUrl());
    errdefer alloc.free(formatted);
    return formatted;
}

pub const e2e_models_endpoint_env = "FX_E2E_OPENAI_MODELS_URL";

fn parseCatalog(
    alloc: Allocator,
    json_text: []const u8,
) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidOpenAiModelCatalog;
    const models_value = parsed.value.object.get("data") orelse
        return error.InvalidOpenAiModelCatalog;
    if (models_value != .array or models_value.array.items.len > max_catalog_models) {
        return error.InvalidOpenAiModelCatalog;
    }

    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &catalog);
    for (models_value.array.items) |value| {
        if (value != .object) return error.InvalidOpenAiModelCatalog;
        const id = try requiredString(value.object, "id");
        try validateModelId(id);
        const owned_id = try alloc.dupe(u8, id);
        errdefer alloc.free(owned_id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        try catalog.append(alloc, .{
            .id = owned_id,
            .model_type = model_type,
            .has_tool_use = true,
        });
    }
    return catalog;
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidOpenAiModelCatalog;
    if (value != .string or value.string.len == 0) return error.InvalidOpenAiModelCatalog;
    return value.string;
}

fn validateModelId(id: []const u8) !void {
    if (id.len == 0 or id.len > max_model_id_bytes) return error.InvalidOpenAiModelCatalog;
    for (id) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidOpenAiModelCatalog;
    }
}

test "OpenAI-compatible catalog parser accepts standard models payload" {
    const alloc = std.testing.allocator;
    const json =
        \\{"data":[
        \\  {"id":"gpt-test","object":"model"},
        \\  {"id":"gpt-4o","object":"model"}
        \\]}
    ;
    var catalog = try parseCatalog(alloc, json);
    defer model_catalog.freeModelCatalog(alloc, &catalog);
    try std.testing.expectEqual(@as(usize, 2), catalog.items.len);
    try std.testing.expectEqualStrings("gpt-test", catalog.items[0].id);
}

test "OpenAI-compatible catalog rejects missing credentials" {
    const result = try fetchCatalogForProvider(null, std.testing.allocator, .{
        .access = .{ .public_only = .no_credential },
        .endpoint = "/v1/models",
    });
    try std.testing.expect(result.failure.category == .authentication);
}
