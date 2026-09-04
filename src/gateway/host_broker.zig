const std = @import("std");
const credentials = @import("../core/auth/credentials.zig");
const io_mod = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");

const max_url_bytes: usize = 2048;
const max_token_bytes: usize = 4096;

pub const protocol_header_name = "x-fx-host-protocol";
pub const protocol_header_value = "1";
pub const request_id_header_name = "x-fx-request-id";

pub const Route = enum {
    gateway_chat,
    gateway_models,
    gateway_credits,
    gateway_generation,
    codex_responses,
    codex_models,
    grok_responses,
    grok_models,
    grok_modalities,

    fn path(self: Route) []const u8 {
        return switch (self) {
            .gateway_chat => "/v1/gateway/chat",
            .gateway_models => "/v1/gateway/models",
            .gateway_credits => "/v1/gateway/credits",
            .gateway_generation => "/v1/gateway/generation",
            .codex_responses => "/v1/codex/responses",
            .codex_models => "/v1/codex/models",
            .grok_responses => "/v1/grok/responses",
            .grok_models => "/v1/grok/models",
            .grok_modalities => "/v1/grok/modalities",
        };
    }
};

pub const Broker = struct {
    base_url: []const u8,
    token: []const u8,

    /// Returns an owned broker URL. The caller must free it with `alloc`.
    fn route_url(
        self: Broker,
        alloc: std.mem.Allocator,
        route: Route,
        query: ?[]const u8,
    ) ![]u8 {
        var total = std.math.add(usize, self.base_url.len, route.path().len) catch
            return error.InvalidHostBrokerUrl;
        if (query) |value| {
            if (!valid_query(value)) return error.InvalidHostBrokerQuery;
            total = std.math.add(usize, total, value.len + 1) catch
                return error.InvalidHostBrokerUrl;
            if (total > max_url_bytes) return error.InvalidHostBrokerUrl;
            return std.fmt.allocPrint(alloc, "{s}{s}?{s}", .{ self.base_url, route.path(), value });
        }
        if (total > max_url_bytes) return error.InvalidHostBrokerUrl;
        return std.fmt.allocPrint(alloc, "{s}{s}", .{ self.base_url, route.path() });
    }
};

pub const Prepared = struct {
    url: []u8,
    token: []const u8,
    base_url: []const u8,
    request_id: [32]u8,

    pub fn deinit(self: *Prepared, alloc: std.mem.Allocator) void {
        alloc.free(self.url);
        self.* = undefined;
    }

    /// Acknowledgement means the host settled this request, not that a provider
    /// refunded it. Cleanup is independent of the cancelled inference task.
    pub fn cancel(self: *const Prepared, alloc: std.mem.Allocator) bool {
        const io = io_mod.getIo();
        const previous = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(previous);
        const Event = union(enum) { response: bool, timeout: void };
        var buffer: [2]Event = undefined;
        var select: std.Io.Select(Event) = .init(io, &buffer);
        defer select.cancelDiscard();
        select.concurrent(.timeout, cancel_deadline, .{}) catch return false;
        select.concurrent(.response, cancel_http, .{ self, alloc }) catch return false;
        const event = select.await() catch return false;
        return switch (event) {
            .response => |confirmed| confirmed,
            .timeout => false,
        };
    }

    fn cancel_deadline() void {
        io_mod.getIo().sleep(.fromMilliseconds(1000), .awake) catch {};
    }

    fn cancel_http(self: *const Prepared, alloc: std.mem.Allocator) bool {
        const url = std.fmt.allocPrint(alloc, "{s}/v1/cancel", .{self.base_url}) catch return false;
        defer alloc.free(url);
        const authorization = std.fmt.allocPrint(alloc, "Bearer {s}", .{self.token}) catch return false;
        defer secret.zeroAndFree(alloc, authorization);
        var payload_buffer: [64]u8 = undefined;
        var payload_writer = std.Io.Writer.fixed(&payload_buffer);
        std.json.Stringify.value(.{ .request_id = @as([]const u8, &self.request_id) }, .{}, &payload_writer) catch return false;
        const payload = payload_writer.buffered();
        var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
        defer client.deinit();
        var request = client.request(.POST, std.Uri.parse(url) catch return false, .{
            .headers = .{
                .authorization = .{ .override = authorization },
                .content_type = .{ .override = "application/json" },
                .accept_encoding = .omit,
            },
            .extra_headers = &.{.{ .name = protocol_header_name, .value = protocol_header_value }},
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        }) catch return false;
        defer request.deinit();
        request.transfer_encoding = .{ .content_length = payload.len };
        var send_buffer: [128]u8 = undefined;
        var body = request.sendBodyUnflushed(&send_buffer) catch return false;
        body.writer.writeAll(payload) catch return false;
        body.end() catch return false;
        if (request.connection) |connection| connection.flush() catch return false;
        const response = request.receiveHead(&.{}) catch return false;
        return response.head.status == .no_content;
    }
};

pub const Config = union(enum) {
    disabled,
    configured: Broker,

    pub fn parse(
        auth_mode: credentials.AuthMode,
        raw_url: ?[]const u8,
        raw_token: ?[]const u8,
    ) !Config {
        if (raw_url == null and raw_token == null) return .disabled;
        if (raw_url == null or raw_token == null) return error.IncompleteHostBrokerConfiguration;
        if (auth_mode != .host_managed) return error.HostBrokerRequiresHostManagedAuth;

        const base_url = std.mem.trimEnd(u8, raw_url.?, "/");
        if (!valid_base_url(base_url)) return error.InvalidHostBrokerUrl;
        if (!valid_token(raw_token.?)) return error.InvalidHostBrokerToken;
        return .{ .configured = .{
            .base_url = base_url,
            .token = raw_token.?,
        } };
    }
};

fn process_config() !Config {
    const auth_mode = credentials.parseAuthMode(io_mod.getenv("FX_AUTH_MODE")) catch
        return error.InvalidHostBrokerConfiguration;
    return Config.parse(
        auth_mode,
        io_mod.getenv("FX_HOST_BROKER_URL"),
        io_mod.getenv("FX_HOST_BROKER_TOKEN"),
    );
}

pub fn prepare(
    alloc: std.mem.Allocator,
    route: Route,
    query: ?[]const u8,
) !?Prepared {
    const broker = switch (try process_config()) {
        .disabled => return null,
        .configured => |configured| configured,
    };
    var random_bytes: [16]u8 = undefined;
    io_mod.getIo().random(&random_bytes);
    return .{
        .url = try broker.route_url(alloc, route, query),
        .token = broker.token,
        .base_url = broker.base_url,
        .request_id = std.fmt.bytesToHex(random_bytes, .lower),
    };
}

fn valid_base_url(value: []const u8) bool {
    if (value.len == 0 or value.len > max_url_bytes) return false;
    const uri = std.Uri.parse(value) catch return false;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return false;
    if (uri.host == null) return false;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return true;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return false;

    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = uri.getHost(&host_buffer) catch return false;
    return std.mem.eql(u8, host.bytes, "127.0.0.1") or
        std.mem.eql(u8, host.bytes, "localhost") or
        std.mem.eql(u8, host.bytes, "::1");
}

fn valid_token(value: []const u8) bool {
    if (value.len == 0 or value.len > max_token_bytes) return false;
    for (value) |byte| if (byte < 0x21 or byte > 0x7e) return false;
    return true;
}

fn valid_query(value: []const u8) bool {
    if (value.len == 0 or value.len > max_url_bytes) return false;
    var equals_count: usize = 0;
    for (value) |byte| switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => {},
        '=' => equals_count += 1,
        else => return false,
    };
    return equals_count == 1;
}

test "host broker configuration is complete explicit and bounded" {
    try std.testing.expectEqual(Config.disabled, try Config.parse(.host_managed, null, null));
    try std.testing.expectError(
        error.IncompleteHostBrokerConfiguration,
        Config.parse(.host_managed, "https://broker.example/fx", null),
    );
    try std.testing.expectError(
        error.HostBrokerRequiresHostManagedAuth,
        Config.parse(.local, "https://broker.example/fx", "sandbox-reference"),
    );
    try std.testing.expectError(
        error.InvalidHostBrokerUrl,
        Config.parse(.host_managed, "https://user@broker.example/fx", "sandbox-reference"),
    );
    try std.testing.expectError(
        error.InvalidHostBrokerToken,
        Config.parse(.host_managed, "https://broker.example/fx", "bad\nvalue"),
    );

    const config = try Config.parse(
        credentials.AuthMode.host_managed,
        "https://broker.example/fx/",
        "sandbox-reference",
    );
    try std.testing.expectEqualStrings("https://broker.example/fx", config.configured.base_url);
    try std.testing.expectEqualStrings("sandbox-reference", config.configured.token);

    const root_config = try Config.parse(
        .host_managed,
        "https://broker.example",
        "sandbox-reference",
    );
    try std.testing.expectEqualStrings("https://broker.example", root_config.configured.base_url);
}

test "host broker routes are closed and preserve validated query values" {
    const config = (try Config.parse(
        .host_managed,
        "https://broker.example/fx",
        "sandbox-reference",
    )).configured;
    const cases = [_]struct {
        route: Route,
        query: ?[]const u8 = null,
        expected: []const u8,
    }{
        .{ .route = .gateway_chat, .expected = "https://broker.example/fx/v1/gateway/chat" },
        .{ .route = .gateway_models, .expected = "https://broker.example/fx/v1/gateway/models" },
        .{ .route = .gateway_credits, .query = "teamId=team_123", .expected = "https://broker.example/fx/v1/gateway/credits?teamId=team_123" },
        .{ .route = .gateway_generation, .query = "id=gen_123", .expected = "https://broker.example/fx/v1/gateway/generation?id=gen_123" },
        .{ .route = .codex_responses, .expected = "https://broker.example/fx/v1/codex/responses" },
        .{ .route = .codex_models, .expected = "https://broker.example/fx/v1/codex/models" },
        .{ .route = .grok_responses, .expected = "https://broker.example/fx/v1/grok/responses" },
        .{ .route = .grok_models, .expected = "https://broker.example/fx/v1/grok/models" },
        .{ .route = .grok_modalities, .expected = "https://broker.example/fx/v1/grok/modalities" },
    };
    for (cases) |case| {
        const url = try config.route_url(std.testing.allocator, case.route, case.query);
        defer std.testing.allocator.free(url);
        try std.testing.expectEqualStrings(case.expected, url);
    }
    try std.testing.expectError(
        error.InvalidHostBrokerQuery,
        config.route_url(std.testing.allocator, .gateway_credits, "teamId=x&redirect=https://evil.example"),
    );

    const oversized_base = "https://broker.example/" ++ ("a" ** 2020);
    const oversized = (try Config.parse(
        .host_managed,
        oversized_base,
        "sandbox-reference",
    )).configured;
    try std.testing.expectError(
        error.InvalidHostBrokerUrl,
        oversized.route_url(std.testing.allocator, .gateway_chat, null),
    );
}
