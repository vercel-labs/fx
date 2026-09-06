const std = @import("std");
const chatgpt_oauth = @import("../core/auth/chatgpt_oauth.zig");
const credentials = @import("../core/auth/credentials.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");
const versions = @import("../core/gateway/provider_versions.zig");
const version_lookup = @import("provider_versions.zig");

const max_catalog_models: usize = 128;
const max_model_id_bytes: usize = 1024;
const max_catalog_bytes: usize = 4 * 1024 * 1024;
const fetch_timeout_ms: i64 = 30_000;
const default_models_endpoint = "https://chatgpt.com/backend-api/codex/models";
const e2e_models_endpoint_env = "FX_E2E_OPENAI_CODEX_MODELS_URL";

pub const reviewer_model = "gpt-5.6-luna";

pub const model_catalog_provider = model_catalog.Provider{
    .fetch_fn = fetchCatalogForProvider,
    .provider_id = .codex,
    .refresh_interval_ms = versions.refresh_interval_ms,
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
    const request_auth = catalogRequestAuth(input.access) orelse
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
    var owned_account_id: ?[]u8 = null;
    defer if (owned_account_id) |account| alloc.free(account);
    const account_id = request_auth.account_id orelse if (request_auth.credential) |credential| account: {
        owned_account_id = chatgpt_oauth.extractAccountId(alloc, credential) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
        };
        break :account owned_account_id.?;
    } else null;
    var fallback_cancel = std.atomic.Value(bool).init(false);
    const cancel_flag = input.cancel_flag orelse &fallback_cancel;
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(fetch_timeout_ms),
    });
    const version = if (request_auth.credential != null)
        version_lookup.resolve(alloc, .codex, cancel_flag, deadline) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .failure = .{
                .category = if (err == error.Cancelled) .cancellation else .transport,
                .retryable = err != error.Cancelled,
            } };
        }
    else
        null;
    const request_url = modelsUrl(alloc, version) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .runtime } };
    };
    defer alloc.free(request_url);

    var operation = FetchOperation{
        .alloc = alloc,
        .url = request_url,
        .credential = request_auth.credential,
        .account_id = account_id,
    };
    var response = gateway_client.runBoundedHttpOperation(
        FetchResponse,
        alloc,
        cancel_flag,
        deadline,
        &operation,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{
            .category = if (err == error.Cancelled) .cancellation else .transport,
            .retryable = err != error.Cancelled,
        } };
    };
    defer response.deinit(alloc);
    if (response.status != .ok) {
        return .{ .failure = model_catalog.failureForHttpStatus(response.status) };
    }
    var catalog = parseCatalog(alloc, response.body) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .malformed_response, .http_status = .ok } };
    };
    var reviewer_available = false;
    for (catalog.items) |entry| {
        if (std.mem.eql(u8, entry.id, reviewer_model)) {
            reviewer_available = true;
            break;
        }
    }
    if (!reviewer_available) {
        model_catalog.freeModelCatalog(alloc, &catalog);
        return .{ .failure = .{ .category = .malformed_response, .http_status = .ok } };
    }
    return .{ .catalog = catalog };
}

const CatalogRequestAuth = struct {
    credential: ?[]const u8 = null,
    account_id: ?[]const u8 = null,
};

fn catalogRequestAuth(access: credentials.CatalogAccess) ?CatalogRequestAuth {
    return switch (access) {
        .host_managed => .{},
        .public_only => null,
        .authenticated => |authenticated| if (authenticated.source == .chatgpt_subscription)
            .{
                .credential = authenticated.credential,
                .account_id = authenticated.account_id,
            }
        else
            null,
    };
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
    account_id: ?[]const u8,

    pub fn run(self: *@This()) !FetchResponse {
        var client: std.http.Client = .{ .allocator = self.alloc, .io = io_mod.getIo() };
        defer client.deinit();
        var auth_header: ?[]u8 = null;
        defer if (auth_header) |value| secret.zeroAndFree(self.alloc, value);
        var headers: std.http.Client.Request.Headers = .{
            .user_agent = .{ .override = gateway_client.user_agent },
            .accept_encoding = .omit,
        };
        if (self.credential) |credential| {
            auth_header = try std.fmt.allocPrint(self.alloc, "Bearer {s}", .{credential});
            headers.authorization = .{ .override = auth_header.? };
        }
        const body_buffer = try self.alloc.alloc(u8, max_catalog_bytes + 1);
        defer secret.zeroAndFree(self.alloc, body_buffer);
        var response_writer = std.Io.Writer.fixed(body_buffer);
        var extra_headers: [3]std.http.Header = undefined;
        var extra_len: usize = 0;
        if (self.account_id) |account_id| {
            extra_headers[extra_len] = .{ .name = "chatgpt-account-id", .value = account_id };
            extra_len += 1;
        }
        extra_headers[extra_len] = .{ .name = "originator", .value = "fx" };
        extra_len += 1;
        extra_headers[extra_len] = .{ .name = "accept", .value = "application/json" };
        extra_len += 1;
        const result = client.fetch(.{
            .location = .{ .url = self.url },
            .method = .GET,
            .headers = headers,
            .extra_headers = extra_headers[0..extra_len],
            .response_writer = &response_writer,
            .redirect_behavior = .unhandled,
        }) catch |err| switch (err) {
            error.WriteFailed => return error.CodexModelCatalogTooLarge,
            else => return err,
        };
        const body = response_writer.buffered();
        if (body.len > max_catalog_bytes) return error.CodexModelCatalogTooLarge;
        return .{
            .status = result.status,
            .body = try self.alloc.dupe(u8, body),
        };
    }
};

fn modelsUrl(alloc: std.mem.Allocator, version: ?versions.Version) ![]u8 {
    const base = io_mod.getenv(e2e_models_endpoint_env) orelse default_models_endpoint;
    if (io_mod.getenv(e2e_models_endpoint_env) != null and !gateway_client.isLoopbackHttpUrl(base)) {
        return error.InvalidE2ECodexModelsEndpoint;
    }
    const compatible = version orelse return alloc.dupe(u8, base);
    const separator: u8 = if (std.mem.findScalar(u8, base, '?') == null) '?' else '&';
    return std.fmt.allocPrint(
        alloc,
        "{s}{c}client_version={s}",
        .{ base, separator, compatible.slice() },
    );
}

fn parseCatalog(
    alloc: std.mem.Allocator,
    json_text: []const u8,
) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCodexModelCatalog;
    const models_value = parsed.value.object.get("models") orelse
        return error.InvalidCodexModelCatalog;
    if (models_value != .array or models_value.array.items.len > max_catalog_models) {
        return error.InvalidCodexModelCatalog;
    }

    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &catalog);
    for (models_value.array.items) |value| {
        if (value != .object) return error.InvalidCodexModelCatalog;
        const object = value.object;
        const visibility = try requiredString(object, "visibility");
        const supported = try requiredBool(object, "supported_in_api");
        if (!supported or !std.mem.eql(u8, visibility, "list")) continue;

        const slug = try requiredString(object, "slug");
        try validateModelId(slug);
        const id = try alloc.dupe(u8, slug);
        errdefer alloc.free(id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        var reasoning_efforts: std.ArrayList(types.ReasoningEffort) = .empty;
        errdefer reasoning_efforts.deinit(alloc);
        try appendReasoningEfforts(alloc, &reasoning_efforts, object);
        const context_window = try optionalPositiveU32(object, "context_window");
        const has_vision = try stringArrayContains(object, "input_modalities", "image");
        const supports_fast = try stringArrayContains(object, "additional_speed_tiers", "fast");

        try catalog.append(alloc, .{
            .id = id,
            .model_type = model_type,
            .has_tool_use = true,
            .has_reasoning = reasoning_efforts.items.len > 0,
            .reasoning_efforts = reasoning_efforts,
            .supports_fast_mode = supports_fast,
            .has_vision = has_vision,
            .has_file_input = has_vision,
            .has_implicit_caching = true,
            .context_window = context_window,
        });
    }
    return catalog;
}

fn appendReasoningEfforts(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(types.ReasoningEffort),
    object: std.json.ObjectMap,
) !void {
    const value = object.get("supported_reasoning_levels") orelse return;
    if (value != .array or value.array.items.len > types.ReasoningEffort.max_options) {
        return error.InvalidCodexModelCatalog;
    }
    for (value.array.items) |entry| {
        if (entry != .object) return error.InvalidCodexModelCatalog;
        const effort = try requiredString(entry.object, "effort");
        const parsed = types.ReasoningEffort.parse(effort) orelse
            return error.InvalidCodexModelCatalog;
        try out.append(alloc, parsed);
    }
}

fn stringArrayContains(
    object: std.json.ObjectMap,
    key: []const u8,
    expected: []const u8,
) !bool {
    const value = object.get(key) orelse return false;
    if (value != .array or value.array.items.len > 32) return error.InvalidCodexModelCatalog;
    for (value.array.items) |entry| {
        if (entry != .string) return error.InvalidCodexModelCatalog;
        if (std.mem.eql(u8, entry.string, expected)) return true;
    }
    return false;
}

fn optionalPositiveU32(object: std.json.ObjectMap, key: []const u8) !u32 {
    const value = object.get(key) orelse return 0;
    if (value == .null) return 0;
    if (value != .integer or value.integer < 0) return error.InvalidCodexModelCatalog;
    return std.math.cast(u32, value.integer) orelse error.InvalidCodexModelCatalog;
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidCodexModelCatalog;
    if (value != .string or value.string.len == 0) return error.InvalidCodexModelCatalog;
    return value.string;
}

fn requiredBool(object: std.json.ObjectMap, key: []const u8) !bool {
    const value = object.get(key) orelse return error.InvalidCodexModelCatalog;
    if (value != .bool) return error.InvalidCodexModelCatalog;
    return value.bool;
}

fn validateModelId(id: []const u8) !void {
    if (id.len == 0 or id.len > max_model_id_bytes) return error.InvalidCodexModelCatalog;
    for (id) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidCodexModelCatalog;
    }
}

test "Codex catalog parser keeps visible API models and live capabilities" {
    const alloc = std.testing.allocator;
    const json =
        \\{"models":[
        \\  {"slug":"gpt-5.4-mini","visibility":"list","supported_in_api":true,"priority":7,"supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}],"additional_speed_tiers":[],"input_modalities":["text","image"],"context_window":272000},
        \\  {"slug":"hidden","visibility":"hide","supported_in_api":true,"priority":8,"supported_reasoning_levels":[],"additional_speed_tiers":["fast"],"input_modalities":["text"],"context_window":1},
        \\  {"slug":"unsupported","visibility":"list","supported_in_api":false,"priority":9,"supported_reasoning_levels":[],"additional_speed_tiers":[],"input_modalities":["text"],"context_window":1}
        \\]}
    ;
    var catalog = try parseCatalog(alloc, json);
    defer model_catalog.freeModelCatalog(alloc, &catalog);

    try std.testing.expectEqual(@as(usize, 1), catalog.items.len);
    const model = catalog.items[0];
    try std.testing.expectEqualStrings("gpt-5.4-mini", model.id);
    try std.testing.expect(model.has_tool_use);
    try std.testing.expect(model.has_reasoning);
    try std.testing.expectEqual(@as(usize, 2), model.reasoning_efforts.items.len);
    try std.testing.expect(!model.supports_fast_mode);
    try std.testing.expect(model.has_vision);
    try std.testing.expect(model.has_file_input);
    try std.testing.expectEqual(@as(u32, 272_000), model.context_window);
}

test "Codex catalog URL uses the resolved compatibility version" {
    const url = try modelsUrl(std.testing.allocator, versions.Version.parse("0.999.1").?);
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.find(u8, url, "client_version=0.999.1") != null);
    try std.testing.expect(std.mem.find(u8, url, "client_version=0.148.0") == null);
}

test "host-managed Codex catalog auth carries no local headers" {
    const auth = catalogRequestAuth(.host_managed) orelse return error.TestExpectedHostManagedCatalogAuth;
    try std.testing.expect(auth.credential == null);
    try std.testing.expect(auth.account_id == null);
}
