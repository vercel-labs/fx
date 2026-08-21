const std = @import("std");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");

pub const gateway_chat_url_env = "FX_GATEWAY_CHAT_URL";

pub const openai_api_key_env = "OPENAI_API_KEY";
pub const openai_base_url_env = "FX_OPENAI_BASE_URL";
pub const openai_api_style_env = "FX_OPENAI_API_STYLE";
pub const default_base_url = "https://api.openai.com/v1";
pub const models_path = "/v1/models";
pub const chat_completions_suffix = "/chat/completions";
pub const responses_suffix = "/responses";

pub const e2e_openai_chat_url_env = "FX_E2E_OPENAI_CHAT_URL";
pub const e2e_openai_responses_url_env = "FX_E2E_OPENAI_RESPONSES_URL";
pub const e2e_openai_models_url_env = "FX_E2E_OPENAI_MODELS_URL";

pub const WireKind = enum {
    gateway,
    openai_chat,
    openai_responses,
};

pub const ApiStyle = enum {
    chat,
    responses,

    pub fn parse(raw: []const u8) ?ApiStyle {
        if (std.ascii.eqlIgnoreCase(raw, "chat")) return .chat;
        if (std.ascii.eqlIgnoreCase(raw, "responses")) return .responses;
        return null;
    }

    pub fn label(self: ApiStyle) []const u8 {
        return switch (self) {
            .chat => "chat",
            .responses => "responses",
        };
    }
};

pub fn isOpenAiCredentialSource(source: types.CredentialSource) bool {
    return source == .openai_api_key;
}

fn nonEmptyEnv(name: []const u8) ?[]const u8 {
    const raw = io_mod.getenv(name) orelse return null;
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return null;
    return raw;
}

pub fn resolveOpenAiBaseUrl() []const u8 {
    if (nonEmptyEnv(openai_base_url_env)) |value| return value;
    if (profileBaseUrl()) |url| return url;
    return default_base_url;
}

/// Immutable routing snapshot for one credential selection. Built when the
/// credential changes and carried with each request so in-flight workers cannot
/// observe a different transport mode than the credential they were started with.
pub const TransportRoute = struct {
    wire_kind: WireKind = .gateway,
    wire_url: []u8 = "",
    models_url: []u8 = "",

    pub const gateway = TransportRoute{};

    pub fn deinit(self: *TransportRoute, alloc: std.mem.Allocator) void {
        if (self.wire_url.len > 0) alloc.free(self.wire_url);
        if (self.models_url.len > 0) alloc.free(self.models_url);
        self.* = .{};
    }

    pub fn chatUrl(self: TransportRoute, gateway_fallback: []const u8) []const u8 {
        if (self.wire_kind != .gateway) return self.wire_url;
        return gateway_fallback;
    }
};

pub fn buildTransportRoute(
    alloc: std.mem.Allocator,
    source: ?types.CredentialSource,
) !TransportRoute {
    const selected = source orelse return .{};
    if (!isOpenAiCredentialSource(selected)) return .{};

    const base = resolveOpenAiBaseUrl();
    const style = resolveOpenAiApiStyle();
    const wire_url = try formatWireUrl(alloc, base, style);
    errdefer alloc.free(wire_url);
    const models_url = try formatModelsUrl(alloc, base);
    errdefer alloc.free(models_url);

    return .{
        .wire_kind = switch (style) {
            .chat => .openai_chat,
            .responses => .openai_responses,
        },
        .wire_url = wire_url,
        .models_url = models_url,
    };
}

pub fn formatWireUrl(
    alloc: std.mem.Allocator,
    base_url: []const u8,
    style: ApiStyle,
) ![]u8 {
    var buf: [1024]u8 = undefined;
    const formatted = switch (style) {
        .chat => formatChatUrl(&buf, base_url),
        .responses => formatResponsesUrl(&buf, base_url),
    } catch {
        if (!std.mem.eql(u8, base_url, default_base_url)) return error.OpenAiWireUrlTooLong;
        const suffix = switch (style) {
            .chat => chat_completions_suffix,
            .responses => responses_suffix,
        };
        return std.fmt.allocPrint(alloc, "{s}{s}", .{ default_base_url, suffix });
    };
    return try alloc.dupe(u8, formatted);
}

pub fn resolveGatewayChatUrl(fallback: []const u8, override: ?[]const u8) []const u8 {
    const candidate = override orelse return fallback;
    if (!isLoopbackHttpUrl(candidate)) return fallback;
    return candidate;
}

fn isLoopbackHttpUrl(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") or
        uri.user != null or
        uri.password != null or
        uri.port == null)
    {
        return false;
    }

    const host_component = uri.host orelse return false;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = host_component.toRaw(&host_buf) catch return false;
    return std.mem.eql(u8, host, "127.0.0.1") or
        std.ascii.eqlIgnoreCase(host, "localhost") or
        std.mem.eql(u8, host, "[::1]");
}

var profile_base_url_storage: [512]u8 = undefined;
var profile_base_url_len: usize = 0;
var profile_openai_api_key_storage: [512]u8 = undefined;
var profile_openai_api_key_len: usize = 0;
var profile_api_style: ApiStyle = .chat;
var profile_api_style_configured: bool = false;

/// Returns false when a non-empty profile key exceeds the fixed storage cap.
pub fn configureProfileApiKey(key: ?[]const u8) bool {
    profile_openai_api_key_len = 0;
    if (key) |value| {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len == 0) return true;
        if (trimmed.len > profile_openai_api_key_storage.len) return false;
        @memcpy(profile_openai_api_key_storage[0..trimmed.len], trimmed);
        profile_openai_api_key_len = trimmed.len;
    }
    return true;
}

pub fn profileOpenAiApiKey() ?[]const u8 {
    if (profile_openai_api_key_len == 0) return null;
    return profile_openai_api_key_storage[0..profile_openai_api_key_len];
}

pub fn profileOpenAiApiKeyPresent() bool {
    return profileOpenAiApiKey() != null;
}

/// Returns false when a non-empty profile URL exceeds the fixed storage cap.
pub fn configureProfileBaseUrl(url: ?[]const u8) bool {
    profile_base_url_len = 0;
    if (url) |value| {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len == 0) return true;
        if (trimmed.len > profile_base_url_storage.len) return false;
        @memcpy(profile_base_url_storage[0..trimmed.len], trimmed);
        profile_base_url_len = trimmed.len;
    }
    return true;
}

pub fn configureProfileApiStyle(style: ?[]const u8) void {
    profile_api_style = .chat;
    profile_api_style_configured = false;
    if (style) |value| {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len == 0) return;
        if (ApiStyle.parse(trimmed)) |parsed| {
            profile_api_style = parsed;
            profile_api_style_configured = true;
        }
    }
}

pub fn resolveOpenAiApiStyle() ApiStyle {
    if (nonEmptyEnv(openai_api_style_env)) |value| {
        if (ApiStyle.parse(value)) |parsed| return parsed;
    }
    if (profile_api_style_configured) return profile_api_style;
    return .chat;
}

fn profileBaseUrl() ?[]const u8 {
    if (profile_base_url_len == 0) return null;
    return profile_base_url_storage[0..profile_base_url_len];
}

/// Writes `{base}/chat/completions` into `buf` and returns the used slice.
pub fn formatChatUrl(buf: []u8, base_url: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    if (std.mem.endsWith(u8, trimmed, chat_completions_suffix)) {
        if (trimmed.len > buf.len) return error.PathTooLong;
        @memcpy(buf[0..trimmed.len], trimmed);
        return buf[0..trimmed.len];
    }
    const path_suffix = if (trimmed.len == 0) chat_completions_suffix else "chat/completions";
    const total = if (trimmed.len == 0)
        path_suffix.len
    else
        trimmed.len + 1 + path_suffix.len;
    if (total > buf.len) return error.PathTooLong;
    if (trimmed.len == 0) {
        @memcpy(buf[0..path_suffix.len], path_suffix);
        return buf[0..path_suffix.len];
    }
    @memcpy(buf[0..trimmed.len], trimmed);
    buf[trimmed.len] = '/';
    @memcpy(buf[trimmed.len + 1 .. trimmed.len + 1 + path_suffix.len], path_suffix);
    return buf[0 .. trimmed.len + 1 + path_suffix.len];
}

/// Writes `{base}/responses` into `buf` and returns the used slice.
pub fn formatResponsesUrl(buf: []u8, base_url: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    if (std.mem.endsWith(u8, trimmed, responses_suffix)) {
        if (trimmed.len > buf.len) return error.PathTooLong;
        @memcpy(buf[0..trimmed.len], trimmed);
        return buf[0..trimmed.len];
    }
    const path_suffix = if (trimmed.len == 0) responses_suffix else "responses";
    const total = if (trimmed.len == 0)
        path_suffix.len
    else
        trimmed.len + 1 + path_suffix.len;
    if (total > buf.len) return error.PathTooLong;
    if (trimmed.len == 0) {
        @memcpy(buf[0..path_suffix.len], path_suffix);
        return buf[0..path_suffix.len];
    }
    @memcpy(buf[0..trimmed.len], trimmed);
    buf[trimmed.len] = '/';
    @memcpy(buf[trimmed.len + 1 .. trimmed.len + 1 + path_suffix.len], path_suffix);
    return buf[0 .. trimmed.len + 1 + path_suffix.len];
}

pub const max_streamed_tool_index: usize = 64;

pub fn formatModelsUrl(alloc: std.mem.Allocator, base_url: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    if (std.mem.endsWith(u8, trimmed, "/models")) {
        return alloc.dupe(u8, trimmed);
    }
    const suffix = if (std.mem.endsWith(u8, trimmed, "/v1")) "/models" else models_path;
    if (std.mem.endsWith(u8, trimmed, "/")) {
        return std.fmt.allocPrint(alloc, "{s}{s}", .{ trimmed, suffix[1..] });
    }
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ trimmed, suffix });
}

test "buildTransportRoute snapshots OpenAI wire endpoints for OpenAI credentials" {
    const alloc = std.testing.allocator;
    configureProfileApiStyle("responses");
    defer configureProfileApiStyle(null);
    try std.testing.expect(configureProfileBaseUrl("https://litellm.example/v1"));
    defer {
        _ = configureProfileBaseUrl(null);
    }

    var route = try buildTransportRoute(alloc, .openai_api_key);
    defer route.deinit(alloc);
    try std.testing.expectEqual(WireKind.openai_responses, route.wire_kind);
    try std.testing.expectEqualStrings("https://litellm.example/v1/responses", route.wire_url);
    try std.testing.expectEqualStrings("https://litellm.example/v1/models", route.models_url);
}

test "buildTransportRoute returns gateway route for non-OpenAI credentials" {
    const alloc = std.testing.allocator;
    var route = try buildTransportRoute(alloc, .ai_gateway_api_key);
    defer route.deinit(alloc);
    try std.testing.expectEqual(WireKind.gateway, route.wire_kind);
    try std.testing.expectEqualStrings("https://gateway.example/chat", route.chatUrl("https://gateway.example/chat"));
}

test "resolveOpenAiApiStyle uses profile when env unset" {
    configureProfileApiStyle("responses");
    defer configureProfileApiStyle(null);
    try std.testing.expectEqual(ApiStyle.responses, resolveOpenAiApiStyle());
}

test "ApiStyle parse accepts chat and responses" {
    try std.testing.expectEqual(ApiStyle.chat, ApiStyle.parse("chat").?);
    try std.testing.expectEqual(ApiStyle.responses, ApiStyle.parse("RESPONSES").?);
    try std.testing.expect(ApiStyle.parse("invalid") == null);
}

test "formatResponsesUrl composes base and suffix" {
    var buf: [128]u8 = undefined;
    const official = try formatResponsesUrl(&buf, "https://api.openai.com/v1");
    try std.testing.expectEqualStrings("https://api.openai.com/v1/responses", official);

    const ollama = try formatResponsesUrl(&buf, "http://127.0.0.1:11434/v1/");
    try std.testing.expectEqualStrings("http://127.0.0.1:11434/v1/responses", ollama);
}

test "configureProfileBaseUrl rejects oversized profile URLs" {
    var oversized: [513]u8 = undefined;
    @memset(&oversized, 'a');
    try std.testing.expect(!configureProfileBaseUrl(oversized[0..]));

    try std.testing.expect(configureProfileBaseUrl("https://litellm.example/v1"));
    defer {
        _ = configureProfileBaseUrl(null);
    }
    try std.testing.expectEqualStrings("https://litellm.example/v1", resolveOpenAiBaseUrl());
}

test "formatChatUrl composes base and suffix" {
    var buf: [128]u8 = undefined;
    const official = try formatChatUrl(&buf, "https://api.openai.com/v1");
    try std.testing.expectEqualStrings("https://api.openai.com/v1/chat/completions", official);

    const ollama = try formatChatUrl(&buf, "http://127.0.0.1:11434/v1/");
    try std.testing.expectEqualStrings("http://127.0.0.1:11434/v1/chat/completions", ollama);

    const already = try formatChatUrl(&buf, "http://127.0.0.1:1/v1/chat/completions");
    try std.testing.expectEqualStrings("http://127.0.0.1:1/v1/chat/completions", already);
}

test "formatModelsUrl composes OpenAI models endpoint" {
    const alloc = std.testing.allocator;
    const url = try formatModelsUrl(alloc, "https://api.openai.com/v1");
    defer alloc.free(url);
    try std.testing.expectEqualStrings("https://api.openai.com/v1/models", url);
}

var stable_openai_transport_test_environ: ?*std.process.Environ.Map = null;

fn stableOpenAiTransportTestEnviron() !*const std.process.Environ.Map {
    if (stable_openai_transport_test_environ) |map| return map;

    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    stable_openai_transport_test_environ = map;
    return map;
}

test "formatWireUrl fails for oversized custom OpenAI base URL" {
    const alloc = std.testing.allocator;
    var long_host: [1000]u8 = undefined;
    @memset(&long_host, 'a');
    const oversized = try std.fmt.allocPrint(alloc, "https://{s}/v1", .{long_host[0..]});
    defer alloc.free(oversized);
    try std.testing.expectError(error.OpenAiWireUrlTooLong, formatWireUrl(alloc, oversized, .chat));
}

test "buildTransportRoute fails closed on oversized OpenAI base URL" {
    const alloc = std.testing.allocator;
    var long_host: [1000]u8 = undefined;
    @memset(&long_host, 'a');
    const oversized = try std.fmt.allocPrint(alloc, "https://{s}/v1", .{long_host[0..]});
    defer alloc.free(oversized);

    var map = std.process.Environ.Map.init(alloc);
    defer map.deinit();
    try map.put(openai_base_url_env, oversized);
    const stable = try stableOpenAiTransportTestEnviron();
    io_mod.setEnvironMap(&map);
    defer io_mod.setEnvironMap(stable);

    try std.testing.expectError(error.OpenAiWireUrlTooLong, buildTransportRoute(alloc, .openai_api_key));
}
