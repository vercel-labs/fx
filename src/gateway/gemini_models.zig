//! Discover Google models with the selected Google key. Never use public fallback.
const std = @import("std");
const catalog = @import("../core/gateway/model_catalog.zig");
const gateway = @import("../core/gateway/gateway_provider.zig");
const capabilities = @import("../core/config/model_capabilities.zig");
const io_mod = @import("../core/shared/io.zig");
const client_mod = @import("client.zig");
const protocol = @import("gemini_protocol.zig");
const Allocator = std.mem.Allocator;
const max_bytes = 4 * 1024 * 1024;
pub const default_model = "gemini-3.8-flash";
pub const reviewer_model = "gemini-3.5-flash-lite";
pub const model_catalog_provider = catalog.Provider{ .fetch_fn = fetchCatalog, .provider_id = .gemini };
pub const cli_model_catalog_provider = gateway.CliModelCatalogProvider{ .fetch_fn = fetchCli };

pub fn fallbackCapabilities(model: []const u8) capabilities.Capabilities {
    const thinking = (std.mem.startsWith(u8, model, "gemini-3") or std.mem.startsWith(u8, model, "gemini-2.5"));
    return .{ .supports_tool_use = true, .supports_vision = true, .supports_file_input = true, .image_input_support = .native, .supports_reasoning = thinking, .reasoning_efforts = if (thinking) .fromSlice(&.{ .literal("low"), .literal("medium"), .literal("high") }) else .{}, .supports_implicit_caching = true, .parallel_tool_calls = true };
}

fn fetchCli(_: ?*anyopaque, alloc: Allocator, input: gateway.CliModelCatalogInput) gateway.CliModelCatalogResult {
    return switch (catalog.fetchWithPublicFallback(model_catalog_provider, alloc, .{ .access = input.access, .endpoint = input.endpoint, .cancel_flag = input.cancel_flag, .view = .full })) {
        .loaded => |loaded| blk: {
            var models = loaded.catalog;
            defer catalog.freeModelCatalog(alloc, &models);
            const ids = catalog.projectModelIds(alloc, models.items) catch return .{ .failure = .{ .access = loaded.provenance.access, .anonymous_fallback_used = false, .failure = .{ .category = .resource_exhausted } } };
            break :blk .{ .loaded = .{ .ids = ids, .provenance = loaded.provenance } };
        },
        .failed => |failure| .{ .failure = failure },
    };
}

const Response = struct {
    status: std.http.Status,
    body: []u8,
    pub fn deinit(self: *@This(), alloc: Allocator) void {
        alloc.free(self.body);
    }
};
const Fetch = struct {
    alloc: Allocator,
    url: []const u8,
    key: ?[]const u8,
    pub fn run(self: *@This()) !Response {
        var client: std.http.Client = .{ .allocator = self.alloc, .io = io_mod.getIo() };
        defer client.deinit();
        const buffer = try self.alloc.alloc(u8, max_bytes + 1);
        defer self.alloc.free(buffer);
        var writer = std.Io.Writer.fixed(buffer);
        var headers: [2]std.http.Header = undefined;
        headers[0] = .{ .name = "accept", .value = "application/json" };
        var n: usize = 1;
        if (self.key) |key| {
            headers[n] = .{ .name = "x-goog-api-key", .value = key };
            n += 1;
        }
        const result = try client.fetch(.{ .location = .{ .url = self.url }, .method = .GET, .headers = .{ .accept_encoding = .omit }, .extra_headers = headers[0..n], .response_writer = &writer, .redirect_behavior = .unhandled });
        if (writer.buffered().len > max_bytes) return error.GeminiCatalogTooLarge;
        return .{ .status = result.status, .body = try self.alloc.dupe(u8, writer.buffered()) };
    }
};
fn fetchCatalog(_: ?*anyopaque, alloc: Allocator, input: catalog.FetchInput) Allocator.Error!catalog.ProviderResult {
    if (input.access.credentialSource() != .gemini_api_key and input.access.credentialSource() != .host_managed) return .{ .failure = .{ .category = .authentication } };
    return .{ .catalog = fetchAll(alloc, input) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = switch (err) {
            error.Cancelled => .cancellation,
            error.AuthenticationRejected => .authentication,
            error.RateLimited => .rate_limited,
            error.InvalidGeminiCatalog, error.GeminiCatalogTooLarge => .malformed_response,
            else => .transport,
        }, .retryable = err == error.RateLimited or err == error.Timeout } };
    } };
}
fn fetchAll(alloc: Allocator, input: catalog.FetchInput) !std.ArrayList(catalog.ModelCatalogEntry) {
    const base = io_mod.getenv("FX_E2E_GEMINI_MODELS_URL") orelse "https://generativelanguage.googleapis.com/v1beta/models";
    if (io_mod.getenv("FX_E2E_GEMINI_MODELS_URL") != null and !client_mod.isLoopbackHttpUrl(base)) return error.InvalidE2EGeminiModelsEndpoint;
    var result: std.ArrayList(catalog.ModelCatalogEntry) = .empty;
    errdefer catalog.freeModelCatalog(alloc, &result);
    var token: ?[]u8 = null;
    defer if (token) |v| alloc.free(v);
    var cancel = std.atomic.Value(bool).init(false);
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{ .clock = .awake, .raw = .fromSeconds(30) });
    for (0..16) |_| {
        var url: std.Io.Writer.Allocating = .init(alloc);
        defer url.deinit();
        try url.writer.print("{s}?pageSize=1000", .{base});
        if (token) |t| {
            try url.writer.writeAll("&pageToken=");
            for (t) |c| if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.') {
                try url.writer.writeByte(c);
            } else try url.writer.print("%{X:0>2}", .{c});
        }
        var operation = Fetch{ .alloc = alloc, .url = url.written(), .key = input.access.authorizationCredential() };
        var response = try client_mod.runBoundedHttpOperation(Response, alloc, input.cancel_flag orelse &cancel, deadline, &operation);
        defer response.deinit(alloc);
        if (response.status == .unauthorized or response.status == .forbidden) return error.AuthenticationRejected;
        if (response.status == .too_many_requests) return error.RateLimited;
        if (response.status != .ok) return error.GeminiCatalogRequestFailed;
        const next = try appendCatalog(alloc, &result, response.body);
        if (next == null) return result;
        if (token) |old| {
            if (std.mem.eql(u8, old, next.?)) {
                alloc.free(next.?);
                return error.InvalidGeminiCatalog;
            }
            alloc.free(old);
        }
        token = next;
    }
    return error.GeminiCatalogTooLarge;
}
fn appendCatalog(alloc: Allocator, out: *std.ArrayList(catalog.ModelCatalogEntry), bytes: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidGeminiCatalog;
    const models = parsed.value.object.get("models") orelse return error.InvalidGeminiCatalog;
    if (models != .array or models.array.items.len > 1000 or out.items.len + models.array.items.len > 4096) return error.InvalidGeminiCatalog;
    for (models.array.items) |v| {
        if (v != .object) return error.InvalidGeminiCatalog;
        const name = v.object.get("name") orelse return error.InvalidGeminiCatalog;
        if (name != .string or !std.mem.startsWith(u8, name.string, "models/")) return error.InvalidGeminiCatalog;
        const id = name.string[7..];
        protocol.validateModel(id) catch continue;
        var excluded = false;
        for ([_][]const u8{ "image", "tts", "audio", "live", "embedding", "robotics", "computer-use" }) |term| if (std.mem.find(u8, id, term) != null) {
            excluded = true;
            break;
        };
        if (excluded) continue;
        var duplicate = false;
        for (out.items) |entry| if (std.mem.eql(u8, entry.id, id)) {
            duplicate = true;
            break;
        };
        if (duplicate) continue;
        const caps = fallbackCapabilities(id);
        var entry = catalog.ModelCatalogEntry{ .id = try alloc.dupe(u8, id), .model_type = undefined };
        errdefer alloc.free(entry.id);
        entry.model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(entry.model_type);
        entry.has_tool_use = true;
        entry.has_vision = true;
        entry.has_file_input = true;
        entry.has_implicit_caching = true;
        entry.has_reasoning = caps.supports_reasoning;
        errdefer entry.reasoning_efforts.deinit(alloc);
        try entry.reasoning_efforts.appendSlice(alloc, caps.reasoning_efforts.slice());
        entry.context_window = positiveU32(v, "inputTokenLimit");
        entry.max_tokens = positiveU32(v, "outputTokenLimit");
        try out.append(alloc, entry);
    }
    if (parsed.value.object.get("nextPageToken")) |next| {
        if (next != .string or next.string.len > 4096) return error.InvalidGeminiCatalog;
        if (next.string.len > 0) return try alloc.dupe(u8, next.string);
    }
    return null;
}
fn positiveU32(v: std.json.Value, name: []const u8) u32 {
    const n = v.object.get(name) orelse return 0;
    return if (n == .integer and n.integer > 0 and n.integer <= std.math.maxInt(u32)) @intCast(n.integer) else 0;
}

test "Gemini catalog filters non-agent models and keeps limits" {
    const a = std.testing.allocator;
    var models: std.ArrayList(catalog.ModelCatalogEntry) = .empty;
    defer catalog.freeModelCatalog(a, &models);
    const next = try appendCatalog(a, &models,
        \\{"models":[{"name":"models/gemini-3.8-flash","inputTokenLimit":1048576,"outputTokenLimit":65536},{"name":"models/gemini-3.8-flash"},{"name":"models/gemini-3.8-flash-image"},{"name":"models/text-embedding-004"}],"nextPageToken":"next/+ page"}
    );
    defer if (next) |v| a.free(v);
    try std.testing.expectEqual(@as(usize, 1), models.items.len);
    try std.testing.expectEqualStrings(default_model, models.items[0].id);
    try std.testing.expectEqual(@as(u32, 1048576), models.items[0].context_window);
    try std.testing.expectEqualStrings("next/+ page", next.?);
    try std.testing.expectEqual(@as(usize, 3), models.items[0].reasoning_efforts.items.len);
}

test "Gemini catalog rejects unrelated credentials before HTTP" {
    const result = try fetchCatalog(null, std.testing.allocator, .{ .access = .{ .authenticated = .{ .credential = "gateway-key", .source = .ai_gateway_api_key, .team_context = null } }, .endpoint = "unused" });
    try std.testing.expect(result == .failure);
    try std.testing.expectEqual(catalog.FailureCategory.authentication, result.failure.category);
}
