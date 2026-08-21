//! Resolves the custom OpenAI-compatible endpoint configuration.
//!
//! The endpoint is ambient configuration shared by credential resolution and
//! the provider transport, so it lives in core rather than in either caller.
//! It comes from FX_BASE_URL, or from the `base_url` key that
//! `fx setup --base-url` writes to the user profile.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const settings_store = @import("settings_store.zig");

pub const base_url_env = "FX_BASE_URL";
pub const api_key_env = "FX_API_KEY";

pub const max_base_url_bytes: usize = settings_store.base_url_max_bytes;
/// Longest route the transport appends to the base URL.
const max_appended_path_bytes: usize = "/chat/completions".len;

var stored_base_url_buf: [max_base_url_bytes]u8 = undefined;
var stored_base_url: ?[]const u8 = null;
var stored_base_url_loaded = false;

/// True when inference should use the custom endpoint instead of AI Gateway.
pub fn isConfigured() bool {
    return baseUrl() != null;
}

/// The normalized endpoint origin, without a trailing slash.
///
/// Reads the user profile, so it must not be called before process IO is
/// installed. Callers that run during early startup use `envBaseUrl`.
pub fn baseUrl() ?[]const u8 {
    if (envBaseUrl()) |from_env| return from_env;
    return storedBaseUrl();
}

/// The endpoint from the environment only. Safe at any point in startup
/// because it performs no IO.
pub fn envBaseUrl() ?[]const u8 {
    const raw = io_mod.getenv(base_url_env) orelse return null;
    return normalize(raw);
}

/// The endpoint credential from the environment. Empty means the caller should
/// fall back to the stored key, or send no credential at all.
pub fn envApiKey() []const u8 {
    const raw = io_mod.getenv(api_key_env) orelse return "";
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return "";
    return raw;
}

/// Drops the cached profile value so the next lookup re-reads it. Called after
/// `fx setup` changes the endpoint.
pub fn invalidateStored() void {
    stored_base_url_loaded = false;
    stored_base_url = null;
}

pub fn normalize(raw: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimEnd(u8, std.mem.trim(u8, raw, " \t\r\n"), "/");
    if (trimmed.len == 0) return null;
    if (trimmed.len + max_appended_path_bytes > max_base_url_bytes) return null;
    settings_store.validateBaseUrl(trimmed) catch return null;
    return trimmed;
}

/// The profile is read directly rather than through the merged config runtime
/// because both callers need this value before merged settings exist. Only
/// this one key is consulted, and the result is cached for the process.
fn storedBaseUrl() ?[]const u8 {
    if (stored_base_url_loaded) return stored_base_url;
    stored_base_url_loaded = true;
    stored_base_url = null;

    const alloc = std.heap.c_allocator;
    const home = io_mod.getenv("HOME") orelse return null;
    var store = settings_store.Store.initFromHome(alloc, home, .read_only) catch return null;
    defer store.deinit(alloc);
    var primary = store.loadPrimary(alloc) catch return null;
    defer primary.deinit(alloc);
    const bytes = switch (primary) {
        .valid => |value| value,
        else => return null,
    };

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const value = parsed.value.object.get("base_url") orelse return null;
    if (value != .string) return null;
    const normalized = normalize(value.string) orelse return null;
    @memcpy(stored_base_url_buf[0..normalized.len], normalized);
    stored_base_url = stored_base_url_buf[0..normalized.len];
    return stored_base_url;
}

test "normalize accepts http origins and trims trailing slashes" {
    try std.testing.expectEqualStrings(
        "http://localhost:11434/v1",
        normalize("  http://localhost:11434/v1/  ").?,
    );
    try std.testing.expectEqualStrings(
        "https://api.openai.com/v1",
        normalize("https://api.openai.com/v1").?,
    );
}

test "normalize rejects non-http, empty, and credential-bearing urls" {
    try std.testing.expect(normalize("") == null);
    try std.testing.expect(normalize("   ") == null);
    try std.testing.expect(normalize("file:///etc/passwd") == null);
    try std.testing.expect(normalize("api.openai.com/v1") == null);
    try std.testing.expect(normalize("https://user:pass@api.openai.com/v1") == null);
    try std.testing.expect(normalize("https://exa mple.com/v1") == null);
}
