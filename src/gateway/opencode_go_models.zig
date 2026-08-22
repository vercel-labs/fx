const std = @import("std");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");
const gateway_client = @import("client.zig");

const max_catalog_models: usize = 128;
const max_model_id_bytes: usize = 256;
const max_catalog_bytes: usize = 1024 * 1024;
const fetch_timeout_ms: i64 = 30_000;
const default_models_endpoint = "https://opencode.ai/zen/go/v1/models";
const e2e_models_endpoint_env = "FX_E2E_OPENCODE_GO_MODELS_URL";

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
    const fetched = model_catalog_provider.fetch(alloc, .{
        .access = input.access,
        .endpoint = input.endpoint,
        .cancel_flag = input.cancel_flag,
        .view = .full,
    }) catch return .{ .failure = .{
        .access = .init(input.access),
        .anonymous_fallback_used = false,
        .failure = .{ .category = .runtime },
    } };
    return switch (fetched) {
        .catalog => |catalog| blk: {
            var owned_catalog = catalog;
            defer model_catalog.freeModelCatalog(alloc, &owned_catalog);
            const ids = model_catalog.projectModelIds(alloc, owned_catalog.items) catch return .{ .failure = .{
                .access = .init(input.access),
                .anonymous_fallback_used = false,
                .failure = .{ .category = .resource_exhausted },
            } };
            break :blk .{ .loaded = .{
                .ids = ids,
                .provenance = .{
                    .access = .init(input.access),
                    .anonymous_fallback_used = false,
                },
            } };
        },
        .failure => |failure| .{ .failure = .{
            .access = .init(input.access),
            .anonymous_fallback_used = false,
            .failure = failure,
        } },
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
    if (err == error.OpenCodeGoModelCatalogTooLarge) return .{ .category = .malformed_response };
    return .{ .category = .transport, .retryable = true };
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
    credential: []const u8,

    pub fn run(self: *@This()) !FetchResponse {
        var client: std.http.Client = .{ .allocator = self.alloc, .io = io_mod.getIo() };
        defer client.deinit();
        const auth_header = try std.fmt.allocPrint(self.alloc, "Bearer {s}", .{self.credential});
        defer secret.zeroAndFree(self.alloc, auth_header);
        const body_buffer = try self.alloc.alloc(u8, max_catalog_bytes + 1);
        defer secret.zeroAndFree(self.alloc, body_buffer);
        var response_writer = std.Io.Writer.fixed(body_buffer);
        const extra_headers = [_]std.http.Header{
            .{ .name = "accept", .value = "application/json" },
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
            error.WriteFailed => return error.OpenCodeGoModelCatalogTooLarge,
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

fn fetchCatalogResponse(
    alloc: std.mem.Allocator,
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

fn modelsUrl(alloc: std.mem.Allocator) ![]u8 {
    const base = io_mod.getenv(e2e_models_endpoint_env) orelse default_models_endpoint;
    if (io_mod.getenv(e2e_models_endpoint_env) != null and !gateway_client.isLoopbackHttpUrl(base)) {
        return error.InvalidE2EOpenCodeGoModelsEndpoint;
    }
    return alloc.dupe(u8, base);
}

fn parseCatalog(
    alloc: std.mem.Allocator,
    catalog_json: []const u8,
) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, catalog_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidOpenCodeGoModelCatalog;
    const models = parsed.value.object.get("data") orelse return error.InvalidOpenCodeGoModelCatalog;
    if (models != .array) return error.InvalidOpenCodeGoModelCatalog;
    try validateCatalogModelCount(models.array.items.len);

    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &catalog);
    for (models.array.items) |value| {
        if (value != .object) return error.InvalidOpenCodeGoModelCatalog;
        const object = value.object;
        if (object.get("object")) |kind| {
            if (kind != .string) return error.InvalidOpenCodeGoModelCatalog;
            if (!std.mem.eql(u8, kind.string, "model")) continue;
        }
        const raw_id = requiredString(object, "id") catch return error.InvalidOpenCodeGoModelCatalog;
        try validateModelId(raw_id);
        const released = if (object.get("created")) |created| blk: {
            if (created != .integer or created.integer < 0) return error.InvalidOpenCodeGoModelCatalog;
            break :blk created.integer;
        } else 0;
        const id = try alloc.dupe(u8, raw_id);
        errdefer alloc.free(id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        try catalog.append(alloc, .{
            .id = id,
            .model_type = model_type,
            .released = released,
            .has_tool_use = true,
        });
    }
    return catalog;
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidOpenCodeGoModelCatalog;
    if (value != .string or value.string.len == 0) return error.InvalidOpenCodeGoModelCatalog;
    return value.string;
}

fn validateModelId(id: []const u8) !void {
    if (id.len == 0 or id.len > max_model_id_bytes) return error.InvalidOpenCodeGoModelCatalog;
    for (id) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidOpenCodeGoModelCatalog;
    }
}

fn validateCatalogBodySize(size: usize) !void {
    if (size > max_catalog_bytes) return error.OpenCodeGoModelCatalogTooLarge;
}

fn validateCatalogModelCount(count: usize) !void {
    if (count > max_catalog_models) return error.InvalidOpenCodeGoModelCatalog;
}
test "OpenCode Go catalog parser preserves models and conservative capabilities" {
    var catalog = try parseCatalog(
        std.testing.allocator,
        "{\"object\":\"list\",\"data\":[{\"id\":\"muse-spark-1.2-contributor\",\"object\":\"model\",\"created\":1720000000,\"owned_by\":\"opencode\"},{\"id\":\"legacy\",\"object\":\"other\"},{\"id\":\"plain\"}]}",
    );
    defer model_catalog.freeModelCatalog(std.testing.allocator, &catalog);
    try std.testing.expectEqual(@as(usize, 2), catalog.items.len);
    try std.testing.expectEqualStrings("muse-spark-1.2-contributor", catalog.items[0].id);
    try std.testing.expectEqual(@as(i64, 1720000000), catalog.items[0].released);
    try std.testing.expect(catalog.items[0].has_tool_use);
    try std.testing.expect(!catalog.items[0].has_reasoning);
    try std.testing.expectEqual(@as(u32, 0), catalog.items[0].context_window);
    try std.testing.expectEqualStrings("plain", catalog.items[1].id);
}

test "OpenCode Go catalog rejects malformed entries and bounds" {
    try std.testing.expectError(
        error.InvalidOpenCodeGoModelCatalog,
        parseCatalog(std.testing.allocator, "{\"data\":[{\"id\":\"bad id\"}]}"),
    );
    try std.testing.expectError(
        error.InvalidOpenCodeGoModelCatalog,
        parseCatalog(std.testing.allocator, "{\"data\":[{\"object\":\"model\"}]}"),
    );
    try std.testing.expectError(
        error.InvalidOpenCodeGoModelCatalog,
        parseCatalog(std.testing.allocator, "{\"data\":[{\"id\":\"m\",\"created\":-1}]}"),
    );
}

test "OpenCode Go catalog rejects non-OpenCode access before network I/O" {
    const result = try model_catalog_provider.fetch(std.testing.allocator, .{
        .access = .{ .authenticated = .{
            .source = .ai_gateway_api_key,
            .credential = "gateway-token",
            .team_context = "team",
        } },
        .endpoint = "http://127.0.0.1:1/models",
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
