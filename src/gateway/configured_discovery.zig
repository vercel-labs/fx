//! Discovery for configured OpenAI-compatible servers. Runtime owns caching;
//! this adapter returns one bounded fetch and never stores provider credentials.
const std = @import("std");
const definitions = @import("../core/config/configured_provider.zig");
const catalog = @import("../core/gateway/model_catalog.zig");
const io = @import("../core/shared/io.zig");
const keys = @import("../core/auth/provider_keys.zig");
const secret_command = @import("../core/config/secret_command.zig");
const secret = @import("../core/auth/secret.zig");
const request_headers = @import("configured_request.zig");
const client = @import("client.zig");
const Allocator = std.mem.Allocator;

pub const Fetched = struct {
    models: []const definitions.ModelMetadata = &.{},
    failure: ?catalog.Failure = null,
    arena: ?*std.heap.ArenaAllocator = null,

    pub fn deinit(self: *Fetched, alloc: Allocator) void {
        if (self.arena) |arena| {
            arena.deinit();
            alloc.destroy(arena);
        }
        self.* = .{};
    }
};

pub fn fetch(alloc: Allocator, definition: *const definitions.Definition, input: catalog.FetchInput) Allocator.Error!Fetched {
    return fetchOrError(alloc, definition, input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => .{ .failure = .{ .category = .cancellation } },
        error.InvalidJson => .{ .failure = .{ .category = .malformed_response } },
        error.MissingCredential => .{ .failure = .{ .category = .authentication } },
        else => .{ .failure = .{ .category = .transport, .retryable = true } },
    };
}

fn fetchOrError(alloc: Allocator, definition: *const definitions.Definition, input: catalog.FetchInput) !Fetched {
    const discovery = definition.discovery.?;
    const arena = try alloc.create(std.heap.ArenaAllocator);
    arena.* = .init(alloc);
    var result: Fetched = .{ .arena = arena };
    errdefer result.deinit(alloc);
    const a = arena.allocator();
    const token: ?[]u8 = switch (definition.auth) {
        .none => null,
        .bearer => |env| try a.dupe(u8, io.getenv(env) orelse return error.MissingCredential),
        .command => |command| try secret_command.resolve(a, command),
        .login => |env| try keys.load(a, definition.id) orelse if (env.len > 0) try a.dupe(u8, io.getenv(env) orelse return error.MissingCredential) else return error.MissingCredential,
    };
    defer if (token) |value| @memset(value, 0);
    var headers = try request_headers.resolveHeaders(a, definition, "");
    defer headers.deinit(a);
    var local_cancel = std.atomic.Value(bool).init(false);
    const cancel = input.cancel_flag orelse &local_cancel;
    const url = try discoveryUrl(a, definition.base_url, discovery);
    var response = try get(a, url, token, headers.items, cancel, discovery.timeout_ms);
    // LiteLLM's rich endpoint is optional; ordinary OpenAI catalogs remain usable.
    if ((discovery.type == .litellm or discovery.type == .@"lm-studio") and response == .status and response.status == .not_found) {
        const fallback = try discoveryUrl(a, definition.base_url, .{ .type = .@"openai-models-list" });
        response = try get(a, fallback, token, headers.items, cancel, discovery.timeout_ms);
    }
    switch (response) {
        .status => |status| result.failure = catalog.failureForHttpStatus(status),
        .body => |body| result.models = try parse(a, discovery.type, body),
    }
    return result;
}

fn openaiBase(base: []const u8) []const u8 {
    return std.mem.trimEnd(u8, base, "/");
}

pub fn discoveryUrl(a: Allocator, base: []const u8, discovery: definitions.Discovery) Allocator.Error![]u8 {
    const prefix = openaiBase(base);
    const native = if (std.mem.endsWith(u8, prefix, "/v1")) prefix[0 .. prefix.len - 3] else prefix;
    return switch (discovery.type) {
        .ollama => a.print("{s}/api/tags", .{native}),
        .@"llama.cpp" => a.print("{s}/models", .{native}),
        .litellm => a.print("{s}/model/info", .{native}),
        .@"openai-models-list" => a.print("{s}{s}/models", .{ prefix, if (discovery.inject_v1 and !std.mem.endsWith(u8, prefix, "/v1")) "/v1" else "" }),
        .@"lm-studio" => a.print("{s}/api/v1/models", .{native}),
        .proxy => a.print("{s}{s}/models", .{ prefix, if (std.mem.endsWith(u8, prefix, "/v1")) "" else "/v1" }),
    };
}

const Response = union(enum) {
    body: []u8,
    status: std.http.Status,

    pub fn deinit(self: *Response, alloc: Allocator) void {
        if (self.* == .body) alloc.free(self.body);
    }
};

fn get(alloc: Allocator, url: []const u8, token: ?[]const u8, headers: []const std.http.Header, cancel: *std.atomic.Value(bool), timeout_ms: u32) !Response {
    var operation: Get = .{ .alloc = alloc, .url = url, .token = token, .headers = headers };
    const deadline = std.Io.Clock.Timestamp.fromNow(io.getIo(), .{ .clock = .awake, .raw = .fromMilliseconds(timeout_ms) });
    return client.runBoundedHttpOperation(Response, alloc, cancel, deadline, &operation);
}

const Get = struct {
    alloc: Allocator,
    url: []const u8,
    token: ?[]const u8,
    headers: []const std.http.Header,

    pub fn run(self: *@This()) !Response {
        var http: std.http.Client = .{ .allocator = self.alloc, .io = io.getIo() };
        defer http.deinit();
        const auth = if (self.token) |token| try self.alloc.print("Bearer {s}", .{token}) else null;
        defer if (auth) |value| secret.zeroAndFree(self.alloc, value);
        var headers: std.http.Client.Request.Headers = .{};
        headers.accept_encoding = .omit;
        if (auth) |value| headers.authorization = .{ .override = value };
        var request = try http.request(.GET, try std.Uri.parse(self.url), .{ .headers = headers, .extra_headers = self.headers, .redirect_behavior = .unhandled });
        defer request.deinit();
        try request.sendBodiless();
        if (request.connection) |connection| try connection.flush();
        var response = try request.receiveHead(&.{});
        if (response.head.status != .ok) return .{ .status = response.head.status };
        var buffer: [64 * 1024]u8 = undefined;
        return .{ .body = try response.reader(&buffer).allocRemaining(self.alloc, .limited(16 * 1024 * 1024)) };
    }
};

/// Catalog dialects differ in envelopes and field names, not provider identity.
pub fn parse(a: Allocator, mode: @FieldType(definitions.Discovery, "type"), body: []const u8) ![]const definitions.ModelMetadata {
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    if (root != .object) return error.InvalidJson;
    const list = root.object.get(if (mode == .ollama) "models" else "data") orelse
        (if (mode == .@"lm-studio") root.object.get("models") else null) orelse return error.InvalidJson;
    if (list != .array) return error.InvalidJson;
    var models: std.ArrayList(definitions.ModelMetadata) = .empty;
    for (list.array.items) |item| {
        if (models.items.len == 2048) break;
        if (item != .object) continue;
        const info = object(item.object.get("model_info")) orelse item;
        if (mode == .@"lm-studio") if (string(item.object.get("type"))) |kind| {
            if (std.mem.eql(u8, kind, "embedding")) continue;
        };
        const model_mode = string(info.object.get("mode"));
        if (model_mode) |value| if (!std.mem.eql(u8, value, "chat") and !std.mem.eql(u8, value, "completion") and !std.mem.eql(u8, value, "responses")) continue;
        const id = string(item.object.get("id")) orelse string(item.object.get("key")) orelse string(item.object.get("model_name")) orelse string(item.object.get("model")) orelse string(item.object.get("name")) orelse continue;
        definitions.validate_model_id(id) catch continue;
        var metadata: definitions.ModelMetadata = .{
            .id = id,
            .name = string(item.object.get("name")) orelse id,
            .description = string(item.object.get("description")),
            .supports_tool_use = boolean(info.object.get("supports_function_calling")) orelse boolean(item.object.get("supports_tools")),
            .supports_vision = boolean(info.object.get("supports_vision")) orelse boolean(item.object.get("vision")),
            .context_window = positive(info.object.get("max_input_tokens")) orelse positive(item.object.get("context_length")) orelse positive(item.object.get("context_window")) orelse positive(item.object.get("max_model_len")) orelse positive(item.object.get("loaded_context_length")) orelse positive(item.object.get("max_context_length")),
            .max_output_tokens = positive(info.object.get("max_output_tokens")) orelse positive(item.object.get("max_tokens")),
        };
        if (object(item.object.get("meta"))) |meta| metadata.context_window = positive(meta.object.get("n_ctx")) orelse metadata.context_window;
        if (mode == .litellm) {
            const input = number(info.object.get("input_cost_per_token"));
            const output = number(info.object.get("output_cost_per_token"));
            if (input != null or output != null) metadata.cost = .{ .input = (input orelse 0) * 1_000_000, .output = (output orelse 0) * 1_000_000 };
        }
        var duplicate = false;
        for (models.items) |existing| if (std.mem.eql(u8, existing.id, id)) {
            duplicate = true;
            break;
        };
        if (!duplicate) try models.append(a, metadata);
    }
    return models.items;
}

fn object(value: ?std.json.Value) ?std.json.Value {
    const present = value orelse return null;
    return if (present == .object) present else null;
}
fn string(value: ?std.json.Value) ?[]const u8 {
    const present = value orelse return null;
    return if (present == .string and present.string.len > 0) present.string else null;
}
fn boolean(value: ?std.json.Value) ?bool {
    const present = value orelse return null;
    return if (present == .bool) present.bool else null;
}
fn positive(value: ?std.json.Value) ?u32 {
    const present = value orelse return null;
    return if (present == .integer and present.integer > 0 and present.integer <= std.math.maxInt(u32)) @intCast(present.integer) else null;
}
fn number(value: ?std.json.Value) ?f64 {
    const present = value orelse return null;
    const n: f64 = switch (present) {
        .integer => @floatFromInt(present.integer),
        .float => present.float,
        else => return null,
    };
    return if (std.math.isFinite(n) and n >= 0) n else null;
}

test "configured discovery modes map URLs and retain discovered metadata" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("http://localhost:11434/api/tags", try discoveryUrl(a, "http://localhost:11434/v1", .{ .type = .ollama }));
    try std.testing.expectEqualStrings("https://models.example/compat/models", try discoveryUrl(a, "https://models.example/compat", .{ .type = .@"openai-models-list", .inject_v1 = false }));
    try std.testing.expectEqualStrings("http://localhost:1234/api/v1/models", try discoveryUrl(a, "http://localhost:1234", .{ .type = .@"lm-studio" }));
    const ollama = try parse(a, .ollama,
        \\{"models":[{"name":"qwen3:8b"},{"name":"qwen3:8b"}]}
    );
    try std.testing.expectEqual(@as(usize, 1), ollama.len);
    try std.testing.expectEqualStrings("qwen3:8b", ollama[0].id);
    const litellm = try parse(a, .litellm,
        \\{"data":[{"model_name":"local/chat","model_info":{"mode":"chat","max_input_tokens":128000,"max_output_tokens":8192,"supports_function_calling":true,"input_cost_per_token":0.000001}},{"model_name":"embed","model_info":{"mode":"embedding"}}]}
    );
    try std.testing.expectEqual(@as(usize, 1), litellm.len);
    try std.testing.expectEqual(@as(?u32, 128000), litellm[0].context_window);
    try std.testing.expectEqual(@as(?u32, 8192), litellm[0].max_output_tokens);
    try std.testing.expectEqual(@as(f64, 1), litellm[0].cost.?.input);
}
