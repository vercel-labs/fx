//! The profile's `browser` settings (D196). Environment variables win:
//! `FX_BROWSER_CDP_URL`, `FX_BROWSER_EXECUTABLE`, and `FX_BROWSER_HEADLESS=0`.
//!
//! ```json
//! "browser": { "cdp_url": "http://127.0.0.1:9222", "executable": "/path/to/chrome",
//!              "headless": true, "screenshot_dir": "/path/to/shots" }
//! ```
const std = @import("std");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const Settings = struct {
    cdp_url: ?[]u8 = null,
    executable: ?[]u8 = null,
    headless: bool = true,
    screenshot_dir: ?[]u8 = null,

    pub fn deinit(self: *Settings, alloc: Allocator) void {
        if (self.cdp_url) |v| alloc.free(v);
        if (self.executable) |v| alloc.free(v);
        if (self.screenshot_dir) |v| alloc.free(v);
        self.* = .{};
    }
};

pub const Error = error{ InvalidBrowserSettings, OutOfMemory };

/// Parses the profile `browser` object. The caller owns the result.
pub fn parse(alloc: Allocator, value: std.json.Value) Error!Settings {
    if (value != .object) return error.InvalidBrowserSettings;
    var settings: Settings = .{};
    errdefer settings.deinit(alloc);
    settings.cdp_url = try optionalString(alloc, value, "cdp_url");
    settings.executable = try optionalString(alloc, value, "executable");
    settings.screenshot_dir = try optionalString(alloc, value, "screenshot_dir");
    if (value.object.get("headless")) |headless| {
        if (headless != .bool) return error.InvalidBrowserSettings;
        settings.headless = headless.bool;
    }
    return settings;
}

fn optionalString(alloc: Allocator, value: std.json.Value, name: []const u8) Error!?[]u8 {
    const field = value.object.get(name) orelse return null;
    if (field != .string) return error.InvalidBrowserSettings;
    const trimmed = std.mem.trim(u8, field.string, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try alloc.dupe(u8, trimmed);
}

/// Applies the environment over profile settings.
pub fn applyEnvironment(alloc: Allocator, settings: *Settings) Error!void {
    if (io_mod.getenv("FX_BROWSER_CDP_URL")) |url| if (std.mem.trim(u8, url, " ").len > 0) {
        if (settings.cdp_url) |old| alloc.free(old);
        settings.cdp_url = try alloc.dupe(u8, std.mem.trim(u8, url, " "));
    };
    if (io_mod.getenv("FX_BROWSER_EXECUTABLE")) |exe| if (std.mem.trim(u8, exe, " ").len > 0) {
        if (settings.executable) |old| alloc.free(old);
        settings.executable = try alloc.dupe(u8, std.mem.trim(u8, exe, " "));
    };
    if (io_mod.getenv("FX_BROWSER_HEADLESS")) |flag| {
        if (std.mem.eql(u8, flag, "0") or std.ascii.eqlIgnoreCase(flag, "false")) settings.headless = false;
    }
}

test "browser settings parse the profile object and reject wrong types" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, "{\"cdp_url\":\" http://127.0.0.1:9222 \",\"headless\":false,\"executable\":\"\"}", .{});
    defer parsed.deinit();
    var settings = try parse(alloc, parsed.value);
    defer settings.deinit(alloc);
    try std.testing.expectEqualStrings("http://127.0.0.1:9222", settings.cdp_url.?);
    try std.testing.expect(!settings.headless);
    try std.testing.expect(settings.executable == null);
    var bad = try std.json.parseFromSlice(std.json.Value, alloc, "{\"headless\":\"no\"}", .{});
    defer bad.deinit();
    try std.testing.expectError(error.InvalidBrowserSettings, parse(alloc, bad.value));
}
