const std = @import("std");

/// Typed contract for a user-configured OpenAI-compatible endpoint. The API
/// key itself is never stored here: `api_key_env` names the environment
/// variable read at credential resolution time.
pub const CustomProviderConfig = struct {
    /// HTTPS base URL, or loopback HTTP for local development. Trailing slash
    /// is trimmed so transports can append fixed paths like "/chat/completions".
    base_url: []const u8,
    /// Name of the environment variable holding the bearer token.
    api_key_env: []const u8,

    pub fn eql(self: CustomProviderConfig, other: CustomProviderConfig) bool {
        return std.mem.eql(u8, self.base_url, other.base_url) and
            std.mem.eql(u8, self.api_key_env, other.api_key_env);
    }
};

pub const ValidationError = error{
    missing_base_url,
    invalid_base_url,
    insecure_base_url,
    missing_api_key_env,
    invalid_api_key_env,
};

/// Validates a candidate configuration. `base_url` must be HTTPS, or plain
/// HTTP pointing at a loopback host (the same policy the gateway base URL
/// override enforces), because the bearer token rides on every request.
pub fn validate(base_url: []const u8, api_key_env: []const u8) ValidationError!void {
    if (base_url.len == 0) return error.missing_base_url;
    if (!isAcceptableBaseUrl(base_url)) return error.insecure_base_url;
    if (api_key_env.len == 0) return error.missing_api_key_env;
    if (!isValidEnvName(api_key_env)) return error.invalid_api_key_env;
}

fn isAcceptableBaseUrl(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    const is_https = std.ascii.eqlIgnoreCase(uri.scheme, "https");
    if (!is_https and !isLoopbackHttp(url)) return false;
    if (uri.user != null or uri.password != null) return false;
    const host_component = uri.host orelse return false;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = host_component.toRaw(&host_buf) catch return false;
    return host.len > 0;
}

fn isLoopbackHttp(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return false;
    const host_component = uri.host orelse return false;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = host_component.toRaw(&host_buf) catch return false;
    return std.mem.eql(u8, host, "127.0.0.1") or
        std.ascii.eqlIgnoreCase(host, "localhost") or
        std.mem.eql(u8, host, "[::1]");
}

fn isValidEnvName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!isEnvNameStart(name[0])) return false;
    for (name[1..]) |c| {
        if (!isEnvNameStart(c) and !(c >= '0' and c <= '9')) return false;
    }
    return true;
}

fn isEnvNameStart(c: u8) bool {
    return c == '_' or std.ascii.isAlphabetic(c);
}

test "accepts https endpoint with valid env name" {
    try validate("https://openrouter.ai/api/v1", "OPENROUTER_API_KEY");
}

test "accepts loopback http endpoint" {
    try validate("http://127.0.0.1:8080/v1", "LOCAL_KEY");
    try validate("http://localhost:11434/v1", "LOCAL_KEY");
}

test "rejects remote http endpoint" {
    try std.testing.expectError(error.insecure_base_url, validate("http://openrouter.ai/api/v1", "KEY"));
}

test "rejects empty and malformed base urls" {
    try std.testing.expectError(error.missing_base_url, validate("", "KEY"));
    try std.testing.expectError(error.insecure_base_url, validate("not a url", "KEY"));
}

test "rejects base url with embedded credentials" {
    try std.testing.expectError(error.insecure_base_url, validate("https://user:pass@example.com/v1", "KEY"));
}

test "rejects missing or invalid env names" {
    try std.testing.expectError(error.missing_api_key_env, validate("https://example.com/v1", ""));
    try std.testing.expectError(error.invalid_api_key_env, validate("https://example.com/v1", "1BAD"));
    try std.testing.expectError(error.invalid_api_key_env, validate("https://example.com/v1", "HAS SPACE"));
}

test "env name accepts underscores digits and letters" {
    try validate("https://example.com/v1", "_PRIVATE_KEY_2");
}

test "config equality compares both fields" {
    const a = CustomProviderConfig{ .base_url = "https://a.com", .api_key_env = "K" };
    const b = CustomProviderConfig{ .base_url = "https://a.com", .api_key_env = "K" };
    const c = CustomProviderConfig{ .base_url = "https://b.com", .api_key_env = "K" };
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}
