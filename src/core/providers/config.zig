const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const secret = @import("../auth/secret.zig");
const model_backend = @import("model_backend.zig");
const openai_secret = @import("openai_secret.zig");
const chatgpt_auth = @import("chatgpt_auth.zig");
const grok_auth = @import("grok_auth.zig");

const Allocator = std.mem.Allocator;

pub const ModelBackend = model_backend.ModelBackend;
pub const provider_env = model_backend.provider_env;
pub const openai_base_url_env = "FX_OPENAI_BASE_URL";
pub const openai_api_key_env = "FX_OPENAI_API_KEY";
pub const default_api_key_env = openai_api_key_env;
pub const max_base_url_bytes: usize = 2048;
pub const max_api_key_env_bytes: usize = 128;
pub const missing_openai_credential_message =
    "Fx needs an OpenAI-compatible API key. Run fx setup openai-compatible, or set FX_OPENAI_BASE_URL and FX_OPENAI_API_KEY.";
pub const missing_openai_interactive_credential_message =
    "Fx needs an OpenAI-compatible API key. Run /setup to add a URL and key, or set FX_OPENAI_BASE_URL and FX_OPENAI_API_KEY.";
pub const unimplemented_backend_message = "that model backend is not implemented yet";
pub const missing_chatgpt_credential_message = chatgpt_auth.missing_session_message;
pub const missing_chatgpt_interactive_credential_message = chatgpt_auth.missing_interactive_session_message;
pub const missing_grok_credential_message = grok_auth.missing_session_message;
pub const missing_grok_interactive_credential_message = grok_auth.missing_interactive_session_message;

pub const OpenAiCompatibleSettings = struct {
    base_url: ?[]const u8 = null,
    api_key_env: ?[]const u8 = null,
};

pub const EnvOverrides = struct {
    provider: ?[]const u8 = null,
    openai_base_url: ?[]const u8 = null,
    openai_api_key: ?[]const u8 = null,
};

pub const Resolved = struct {
    kind: ModelBackend = .vercel_gateway,
    openai_compatible: OpenAiCompatibleSettings = .{},
    openai_api_key_present: bool = false,

    pub fn chatCompletionsUrlAlloc(self: Resolved, alloc: Allocator) !?[]u8 {
        if (self.kind != .openai_compatible) return null;
        const base = self.openai_compatible.base_url orelse return null;
        return try joinChatCompletionsUrl(alloc, base);
    }

    pub fn modelsUrlAlloc(self: Resolved, alloc: Allocator) !?[]u8 {
        if (self.kind != .openai_compatible) return null;
        const base = self.openai_compatible.base_url orelse return null;
        return try joinModelsUrl(alloc, base);
    }

    pub fn apiKeyEnvName(self: Resolved) []const u8 {
        const name = self.openai_compatible.api_key_env orelse default_api_key_env;
        return if (name.len == 0) default_api_key_env else name;
    }

    pub fn loadApiKey(self: Resolved, alloc: Allocator) !?[]u8 {
        if (self.kind != .openai_compatible) return null;
        if (trimmedEnv(self.apiKeyEnvName())) |value| return try alloc.dupe(u8, value);
        if (!std.mem.eql(u8, self.apiKeyEnvName(), openai_api_key_env)) {
            if (trimmedEnv(openai_api_key_env)) |value| return try alloc.dupe(u8, value);
        }
        return openai_secret.load(alloc) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
    }

    pub fn hasChatgptSession(self: Resolved) bool {
        return self.kind == .chatgpt and chatgpt_auth.hasSession();
    }

    pub fn hasGrokSession(self: Resolved) bool {
        return self.kind == .grok and grok_auth.hasSession();
    }

    pub fn hasApiKey(self: Resolved) bool {
        if (self.kind != .openai_compatible) return false;
        if (self.openai_api_key_present) return true;
        if (trimmedEnv(self.apiKeyEnvName()) != null) return true;
        if (!std.mem.eql(u8, self.apiKeyEnvName(), openai_api_key_env) and trimmedEnv(openai_api_key_env) != null) {
            return true;
        }
        const loaded = openai_secret.load(std.heap.c_allocator) catch return false;
        if (loaded) |key| {
            secret.zeroAndFree(std.heap.c_allocator, key);
            return true;
        }
        return false;
    }
};

pub const SettingsView = struct {
    provider: ?ModelBackend = null,
    openai_compatible_base_url: ?[]const u8 = null,
    openai_compatible_api_key_env: ?[]const u8 = null,
};

pub fn resolve(settings: SettingsView) Resolved {
    return resolveWith(settings, processEnv());
}

pub fn resolveActive() Resolved {
    return resolve(rememberedSettings());
}

pub fn resolveKind(configured: ?ModelBackend) ModelBackend {
    return resolveActiveWith(configured).kind;
}

pub fn resolveActiveWith(configured: ?ModelBackend) Resolved {
    var settings = rememberedSettings();
    if (configured) |value| settings.provider = value;
    return resolve(settings);
}

pub fn invalidateRemembered() void {
    remembered_lock.lockUncancelable(io_mod.getIo());
    defer remembered_lock.unlock(io_mod.getIo());
    clearRememberedUnlocked();
    remembered_loaded = false;
}

const max_settings_bytes: usize = 64 * 1024;
var remembered_lock: std.Io.Mutex = .init;
var remembered_loaded: bool = false;
var remembered_kind: ?ModelBackend = null;
var remembered_base_url_buf: [max_base_url_bytes]u8 = undefined;
var remembered_base_url_len: usize = 0;
var remembered_api_key_env_buf: [max_api_key_env_bytes]u8 = undefined;
var remembered_api_key_env_len: usize = 0;

fn rememberedSettings() SettingsView {
    remembered_lock.lockUncancelable(io_mod.getIo());
    defer remembered_lock.unlock(io_mod.getIo());
    if (!remembered_loaded) {
        loadRememberedUnlocked();
        remembered_loaded = true;
    }
    return .{
        .provider = remembered_kind,
        .openai_compatible_base_url = if (remembered_base_url_len == 0)
            null
        else
            remembered_base_url_buf[0..remembered_base_url_len],
        .openai_compatible_api_key_env = if (remembered_api_key_env_len == 0)
            null
        else
            remembered_api_key_env_buf[0..remembered_api_key_env_len],
    };
}

fn clearRememberedUnlocked() void {
    remembered_kind = null;
    remembered_base_url_len = 0;
    remembered_api_key_env_len = 0;
}

fn loadRememberedUnlocked() void {
    clearRememberedUnlocked();
    const home = io_mod.getenv("HOME") orelse return;
    const path = profile_paths.settingsPath(std.heap.c_allocator, home) catch return;
    defer std.heap.c_allocator.free(path);
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch return;
    defer file.close(io_mod.getIo());
    const bytes = io_mod.readFileToEnd(std.heap.c_allocator, &file, max_settings_bytes) catch return;
    defer std.heap.c_allocator.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, bytes, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    if (parsed.value.object.get("provider")) |value| {
        if (value == .string) remembered_kind = model_backend.parse(value.string);
    }
    const openai = parsed.value.object.get("openai_compatible") orelse return;
    if (openai != .object) return;
    if (openai.object.get("base_url")) |value| {
        if (value == .string) copyRemembered(value.string, &remembered_base_url_buf, &remembered_base_url_len);
    }
    if (openai.object.get("api_key_env")) |value| {
        if (value == .string) copyRemembered(value.string, &remembered_api_key_env_buf, &remembered_api_key_env_len);
    }
}

fn copyRemembered(value: []const u8, buf: []u8, len: *usize) void {
    const n = @min(value.len, buf.len);
    if (n == 0) return;
    @memcpy(buf[0..n], value[0..n]);
    len.* = n;
}

pub fn resolveWith(settings: SettingsView, env: EnvOverrides) Resolved {
    const kind = if (env.provider) |value|
        model_backend.parse(value) orelse settings.provider orelse .vercel_gateway
    else
        settings.provider orelse .vercel_gateway;
    var openai_compatible = OpenAiCompatibleSettings{
        .base_url = settings.openai_compatible_base_url,
        .api_key_env = settings.openai_compatible_api_key_env,
    };
    if (env.openai_base_url) |value| openai_compatible.base_url = value;
    if (env.openai_api_key != null) openai_compatible.api_key_env = openai_api_key_env;
    return .{
        .kind = kind,
        .openai_compatible = openai_compatible,
        .openai_api_key_present = env.openai_api_key != null,
    };
}

pub fn processEnv() EnvOverrides {
    return .{
        .provider = trimmedEnv(provider_env),
        .openai_base_url = trimmedEnv(openai_base_url_env),
        .openai_api_key = trimmedEnv(openai_api_key_env),
    };
}

fn trimmedEnv(key: []const u8) ?[]const u8 {
    const value = io_mod.getenv(key) orelse return null;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

pub fn validateBaseUrl(raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > max_base_url_bytes) return error.InvalidOpenAiBaseUrl;
    if (!std.unicode.utf8ValidateSlice(trimmed)) return error.InvalidOpenAiBaseUrl;
    for (trimmed) |byte| {
        if (std.ascii.isControl(byte) or byte == ' ') return error.InvalidOpenAiBaseUrl;
    }
    const uri = std.Uri.parse(trimmed) catch return error.InvalidOpenAiBaseUrl;
    if ((!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) or
        uri.user != null or
        uri.password != null or
        uri.host == null)
    {
        return error.InvalidOpenAiBaseUrl;
    }
    return trimmed;
}

pub fn validateApiKeyEnvName(raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > max_api_key_env_bytes) return error.InvalidOpenAiApiKeyEnv;
    if (trimmed[0] != '_' and !std.ascii.isAlphabetic(trimmed[0])) return error.InvalidOpenAiApiKeyEnv;
    for (trimmed) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return error.InvalidOpenAiApiKeyEnv;
    }
    return trimmed;
}

pub fn joinChatCompletionsUrl(alloc: Allocator, base_url: []const u8) ![]u8 {
    return joinEndpoint(alloc, base_url, "chat/completions");
}

pub fn joinModelsUrl(alloc: Allocator, base_url: []const u8) ![]u8 {
    return joinEndpoint(alloc, base_url, "models");
}

fn joinEndpoint(alloc: Allocator, base_url: []const u8, suffix: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    if (std.mem.endsWith(u8, trimmed, suffix)) return alloc.dupe(u8, trimmed);
    if (std.mem.endsWith(u8, trimmed, "/v1")) {
        return std.fmt.allocPrint(alloc, "{s}/{s}", .{ trimmed, suffix });
    }
    return std.fmt.allocPrint(alloc, "{s}/v1/{s}", .{ trimmed, suffix });
}

test "resolver prefers FX_PROVIDER over a remembered backend" {
    const resolved = resolveWith(.{
        .provider = .vercel_gateway,
        .openai_compatible_base_url = "https://example.invalid/v1",
    }, .{
        .provider = "openai_compatible",
        .openai_base_url = "http://127.0.0.1:8080/v1",
    });
    try std.testing.expectEqual(ModelBackend.openai_compatible, resolved.kind);
    try std.testing.expectEqualStrings("http://127.0.0.1:8080/v1", resolved.openai_compatible.base_url.?);
}

test "resolver defaults to Vercel Gateway" {
    const resolved = resolveWith(.{}, .{});
    try std.testing.expectEqual(ModelBackend.vercel_gateway, resolved.kind);
    try std.testing.expect(resolved.openai_compatible.base_url == null);
    try std.testing.expect(!resolved.hasApiKey());
}

test "resolver keeps a remembered openai-compatible backend" {
    const resolved = resolveWith(.{
        .provider = .openai_compatible,
        .openai_compatible_base_url = "https://api.example.test/v1",
        .openai_compatible_api_key_env = "CUSTOM_OPENAI_KEY",
    }, .{});
    try std.testing.expectEqual(ModelBackend.openai_compatible, resolved.kind);
    try std.testing.expectEqualStrings("https://api.example.test/v1", resolved.openai_compatible.base_url.?);
    try std.testing.expectEqualStrings("CUSTOM_OPENAI_KEY", resolved.apiKeyEnvName());
}

test "resolver treats a present FX_OPENAI_API_KEY as access" {
    const resolved = resolveWith(.{ .provider = .openai_compatible }, .{
        .openai_api_key = "sk-test",
        .openai_base_url = "http://127.0.0.1:9/v1",
    });
    try std.testing.expect(resolved.hasApiKey());
    try std.testing.expectEqualStrings(openai_api_key_env, resolved.apiKeyEnvName());
}

test "chat completions and models URLs join a v1 base" {
    const chat = try joinChatCompletionsUrl(std.testing.allocator, "http://127.0.0.1:9/v1");
    defer std.testing.allocator.free(chat);
    try std.testing.expectEqualStrings("http://127.0.0.1:9/v1/chat/completions", chat);

    const models = try joinModelsUrl(std.testing.allocator, "https://api.openai.com");
    defer std.testing.allocator.free(models);
    try std.testing.expectEqualStrings("https://api.openai.com/v1/models", models);

    const already = try joinChatCompletionsUrl(std.testing.allocator, "http://127.0.0.1:9/v1/chat/completions");
    defer std.testing.allocator.free(already);
    try std.testing.expectEqualStrings("http://127.0.0.1:9/v1/chat/completions", already);
}

test "openai-compatible URL and env-name validation" {
    try std.testing.expectEqualStrings(
        "https://api.openai.com/v1",
        try validateBaseUrl("https://api.openai.com/v1"),
    );
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:8080/v1",
        try validateBaseUrl(" http://127.0.0.1:8080/v1 "),
    );
    try std.testing.expectError(error.InvalidOpenAiBaseUrl, validateBaseUrl("ftp://example.test"));
    try std.testing.expectError(error.InvalidOpenAiBaseUrl, validateBaseUrl("https://user:pass@example.test/v1"));
    try std.testing.expectError(error.InvalidOpenAiBaseUrl, validateBaseUrl("not a url"));
    try std.testing.expectEqualStrings("FX_OPENAI_API_KEY", try validateApiKeyEnvName("FX_OPENAI_API_KEY"));
    try std.testing.expectError(error.InvalidOpenAiApiKeyEnv, validateApiKeyEnvName("1BAD"));
    try std.testing.expectError(error.InvalidOpenAiApiKeyEnv, validateApiKeyEnvName("HAS-DASH"));
}
