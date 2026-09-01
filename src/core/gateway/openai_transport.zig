const std = @import("std");
const io_mod = @import("../shared/io.zig");

pub const gateway_chat_url_env = "FX_GATEWAY_CHAT_URL";

pub const openai_api_key_env = "OPENAI_API_KEY";
pub const litellm_api_key_env = "LITELLM_API_KEY";
pub const openai_base_url_env = "FX_OPENAI_BASE_URL";
pub const default_base_url = "https://api.openai.com/v1";
pub const models_path = "/v1/models";
pub const chat_completions_suffix = "/chat/completions";

pub const e2e_openai_chat_url_env = "FX_E2E_OPENAI_CHAT_URL";
pub const e2e_openai_models_url_env = "FX_E2E_OPENAI_MODELS_URL";

pub const OpenAiSettings = struct {
    openai_base_url: ?[]const u8 = null,
    openai_api_key: ?[]const u8 = null,
};

fn nonEmptyEnv(name: []const u8) ?[]const u8 {
    const raw = io_mod.getenv(name) orelse return null;
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return null;
    return raw;
}

pub fn resolveOpenAiBaseUrlFromSettings(settings: OpenAiSettings) []const u8 {
    if (nonEmptyEnv(openai_base_url_env)) |value| return value;
    if (settings.openai_base_url) |url| {
        if (std.mem.trim(u8, url, " \t\r\n").len > 0) return url;
    }
    return default_base_url;
}

pub fn openAiApiKeyConfigured(settings: OpenAiSettings) bool {
    if (nonEmptyEnv(openai_api_key_env) != null) return true;
    if (nonEmptyEnv(litellm_api_key_env) != null) return true;
    if (settings.openai_api_key) |key| {
        if (std.mem.trim(u8, key, " \t\r\n").len > 0) return true;
    }
    return false;
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

pub fn selectE2eWireUrl(
    e2e_env: ?[]const u8,
    fallback: []const u8,
) []const u8 {
    const override = e2e_env orelse return fallback;
    if (!isLoopbackHttpUrl(override)) return fallback;
    return override;
}

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

test "resolveOpenAiBaseUrlFromSettings uses profile when env unset" {
    const stable = try stableOpenAiTransportTestEnviron();
    io_mod.setEnvironMap(stable);

    try std.testing.expectEqualStrings(
        "https://litellm.example/v1",
        resolveOpenAiBaseUrlFromSettings(.{ .openai_base_url = "https://litellm.example/v1" }),
    );
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
