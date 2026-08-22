const std = @import("std");
const credentials = @import("../core/auth/credentials.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");
const opencode_session = @import("../core/auth/opencode_session.zig");
const gateway_client = @import("client.zig");

const max_catalog_models: usize = 256;
const max_model_id_bytes: usize = 256;
const max_catalog_bytes: usize = 1024 * 1024;
const fetch_timeout_ms: i64 = 30_000;

pub const zen_models_url = "https://opencode.ai/zen/v1/models";
pub const go_models_url = "https://opencode.ai/zen/go/v1/models";
pub const zen_base_url = "https://opencode.ai/zen/v1";
pub const go_base_url = "https://opencode.ai/zen/go/v1";

pub const EndpointFamily = enum {
    responses,
    messages,
    chat_completions,
    gemini,
};

pub const zen_model_catalog_provider = model_catalog.Provider{
    .context = @constCast(&opencode_session.Kind.zen),
    .fetch_fn = fetchCatalogForProvider,
};

pub const go_model_catalog_provider = model_catalog.Provider{
    .context = @constCast(&opencode_session.Kind.go),
    .fetch_fn = fetchCatalogForProvider,
};

pub const zen_cli_model_catalog_provider = gateway_provider.CliModelCatalogProvider{
    .context = @constCast(&opencode_session.Kind.zen),
    .fetch_fn = fetchCliModelCatalog,
};

pub const go_cli_model_catalog_provider = gateway_provider.CliModelCatalogProvider{
    .context = @constCast(&opencode_session.Kind.go),
    .fetch_fn = fetchCliModelCatalog,
};

pub fn kindFromContext(raw: ?*anyopaque) opencode_session.Kind {
    const kind: *const opencode_session.Kind = @ptrCast(@alignCast(raw.?));
    return kind.*;
}

pub fn modelsUrl(kind: opencode_session.Kind) []const u8 {
    return switch (kind) {
        .zen => zen_models_url,
        .go => go_models_url,
    };
}

pub fn inferenceBaseUrl(kind: opencode_session.Kind) []const u8 {
    return switch (kind) {
        .zen => zen_base_url,
        .go => go_base_url,
    };
}

pub fn requiredSource(kind: opencode_session.Kind) credentials.Source {
    return switch (kind) {
        .zen => .zen_api_key,
        .go => .go_api_key,
    };
}

pub fn stripModelPrefix(kind: opencode_session.Kind, model: []const u8) []const u8 {
    const prefix = kind.modelPrefix();
    if (std.mem.startsWith(u8, model, prefix)) return model[prefix.len..];
    return model;
}

pub fn familyFromCatalogHint(hint: []const u8) ?EndpointFamily {
    if (std.mem.indexOf(u8, hint, "responses") != null) return .responses;
    if (std.mem.indexOf(u8, hint, "messages") != null) return .messages;
    if (std.mem.indexOf(u8, hint, "chat/completions") != null or std.mem.indexOf(u8, hint, "chat_completions") != null)
        return .chat_completions;
    if (std.mem.indexOf(u8, hint, "/models/") != null or std.ascii.eqlIgnoreCase(hint, "gemini") or std.ascii.eqlIgnoreCase(hint, "google"))
        return .gemini;
    return null;
}

pub fn familyForModel(kind: opencode_session.Kind, model: []const u8) EndpointFamily {
    const id = stripModelPrefix(kind, model);
    if (std.mem.startsWith(u8, id, "gemini-")) return .gemini;
    if (std.mem.startsWith(u8, id, "claude-")) return .messages;
    if (std.mem.startsWith(u8, id, "qwen")) return .messages;
    if (kind == .go and std.mem.startsWith(u8, id, "minimax-")) return .messages;
    if (std.mem.startsWith(u8, id, "gpt-") or
        std.mem.startsWith(u8, id, "grok-") or
        std.mem.startsWith(u8, id, "muse-"))
        return .responses;
    return .chat_completions;
}

pub fn inferenceUrl(kind: opencode_session.Kind, model: []const u8, family: EndpointFamily) ![]u8 {
    // Returned slice is a compile-time constant except Gemini; callers that need
    // an owned Gemini URL should use inferenceUrlAlloc.
    _ = model;
    _ = kind;
    return switch (family) {
        .responses => error.NeedsAllocator,
        else => error.NeedsAllocator,
    };
}

pub fn inferenceUrlAlloc(alloc: std.mem.Allocator, kind: opencode_session.Kind, model: []const u8, family: EndpointFamily) ![]u8 {
    const id = stripModelPrefix(kind, model);
    const base = inferenceBaseUrl(kind);
    return switch (family) {
        .responses => try std.fmt.allocPrint(alloc, "{s}/responses", .{base}),
        .messages => try std.fmt.allocPrint(alloc, "{s}/messages", .{base}),
        .chat_completions => try std.fmt.allocPrint(alloc, "{s}/chat/completions", .{base}),
        .gemini => try std.fmt.allocPrint(alloc, "{s}/models/{s}", .{ base, id }),
    };
}

fn fetchCliModelCatalog(
    raw: ?*anyopaque,
    alloc: std.mem.Allocator,
    input: gateway_provider.CliModelCatalogInput,
) gateway_provider.CliModelCatalogResult {
    const kind = kindFromContext(raw);
    const provider = switch (kind) {
        .zen => zen_model_catalog_provider,
        .go => go_model_catalog_provider,
    };
    return switch (model_catalog.fetchWithPublicFallback(provider, alloc, .{
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
    raw: ?*anyopaque,
    alloc: std.mem.Allocator,
    input: model_catalog.FetchInput,
) std.mem.Allocator.Error!model_catalog.ProviderResult {
    const kind = kindFromContext(raw);
    if (input.access.credentialSource() != requiredSource(kind)) {
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
    }
    const credential = input.access.authorizationCredential() orelse
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };

    var fallback_cancel = std.atomic.Value(bool).init(false);
    const cancel_flag = input.cancel_flag orelse &fallback_cancel;
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(fetch_timeout_ms),
    });
    var response = fetchCatalogResponse(
        alloc,
        modelsUrl(kind),
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
    if (err == error.OpenCodeModelCatalogTooLarge) return .{ .category = .malformed_response };
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
        const extra_headers = [_]std.http.Header{.{ .name = "accept", .value = "application/json" }};
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
            error.WriteFailed => return error.OpenCodeModelCatalogTooLarge,
            else => return err,
        };
        const body = response_writer.buffered();
        if (body.len > max_catalog_bytes) return error.OpenCodeModelCatalogTooLarge;
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

fn parseCatalog(alloc: std.mem.Allocator, json: []const u8) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidOpenCodeModelCatalog;
    const data = parsed.value.object.get("data") orelse return error.InvalidOpenCodeModelCatalog;
    if (data != .array) return error.InvalidOpenCodeModelCatalog;
    if (data.array.items.len > max_catalog_models) return error.InvalidOpenCodeModelCatalog;

    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &catalog);
    for (data.array.items) |entry| {
        if (entry != .object) continue;
        const id_value = entry.object.get("id") orelse continue;
        if (id_value != .string or id_value.string.len == 0 or id_value.string.len > max_model_id_bytes) continue;
        const owned_id = try alloc.dupe(u8, id_value.string);
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

test "OpenCode family routing follows documented endpoint families" {
    try std.testing.expectEqual(EndpointFamily.responses, familyForModel(.zen, "gpt-5.5"));
    try std.testing.expectEqual(EndpointFamily.responses, familyForModel(.zen, "opencode/grok-4.5"));
    try std.testing.expectEqual(EndpointFamily.messages, familyForModel(.zen, "claude-sonnet-5"));
    try std.testing.expectEqual(EndpointFamily.messages, familyForModel(.zen, "qwen3.7-max"));
    try std.testing.expectEqual(EndpointFamily.chat_completions, familyForModel(.zen, "minimax-m3"));
    try std.testing.expectEqual(EndpointFamily.messages, familyForModel(.go, "minimax-m3"));
    try std.testing.expectEqual(EndpointFamily.chat_completions, familyForModel(.go, "kimi-k3"));
    try std.testing.expectEqual(EndpointFamily.gemini, familyForModel(.zen, "gemini-3.5-flash"));
    try std.testing.expectEqual(EndpointFamily.responses, familyFromCatalogHint("https://opencode.ai/zen/v1/responses").?);
    try std.testing.expectEqual(EndpointFamily.messages, familyFromCatalogHint("/messages").?);
}

test "OpenCode catalog parser keeps live ids without a hardcoded list" {
    const alloc = std.testing.allocator;
    var catalog = try parseCatalog(alloc, "{\"object\":\"list\",\"data\":[{\"id\":\"gpt-5.5\",\"object\":\"model\"},{\"id\":\"claude-opus-5\"}]}");
    defer model_catalog.freeModelCatalog(alloc, &catalog);
    try std.testing.expectEqual(@as(usize, 2), catalog.items.len);
    try std.testing.expectEqualStrings("gpt-5.5", catalog.items[0].id);
    try std.testing.expectEqualStrings("claude-opus-5", catalog.items[1].id);
}
