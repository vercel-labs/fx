//! Slack signs in as fx's Slack app, since Slack has no client registration,
//! with the redirect `http://localhost:3118/callback`. Slack refreshes a PKCE
//! app's tokens without the app's secret only for a localhost redirect
//! (Slack's "Using PKCE"), so a login made through any other one lasts only
//! until its first token expires. The engine signs in as for any server, asking
//! for the scopes the app has.

const std = @import("std");
const io_mod = @import("../shared/io.zig");

/// Slack's MCP server, which `add slack` uses when no URL is given.
pub const server_url = "https://mcp.slack.com/mcp";

/// fx's Slack app, used for Slack when the config names no app of its own.
pub const client_id = "12364000946.12017137861236";

/// The port of the one redirect fx's Slack app allows,
/// `http://localhost:3118/callback`. A config's `oauth.callback_port`
/// replaces it.
pub const callback_port: u16 = 3118;

/// The user scopes fx's Slack app has; it may ask for no others.
pub const scopes = "channels:history channels:read channels:write chat:write emoji:read files:write groups:history groups:read im:history im:read mpim:history mpim:read search:read.im search:read.mpim search:read.private search:read.public search:read.users users:read";

/// Whether `url` is Slack's MCP server.
pub fn isSlack(url: ?[]const u8) bool {
    const u = url orelse return false;
    return std.mem.eql(u8, u, "https://mcp.slack.com") or std.mem.startsWith(u8, u, "https://mcp.slack.com/");
}

/// A stand-in for Slack's server in tests, on 127.0.0.1
/// (`FX_E2E_SLACK_ORIGIN`), as v1 takes it; null otherwise.
fn standIn() ?[]const u8 {
    const configured = io_mod.getenv("FX_E2E_SLACK_ORIGIN") orelse return null;
    return if (loopbackOrigin(configured)) configured else null;
}

/// Whether `url` may sign in as fx's Slack app: Slack's MCP server, or in
/// tests the server at the stand-in's own `{origin}/mcp`. Another server that
/// names fx's app signs in with a redirect the app doesn't allow, so Slack
/// never sends it a code.
pub fn appServer(url: ?[]const u8) bool {
    return appServerAt(url orelse return false, standIn());
}

fn appServerAt(url: []const u8, stand_in: ?[]const u8) bool {
    if (isSlack(url)) return true;
    const o = stand_in orelse return false;
    return std.mem.startsWith(u8, url, o) and std.mem.eql(u8, url[o.len..], "/mcp");
}

fn loopbackOrigin(o: []const u8) bool {
    const prefix = "http://127.0.0.1:";
    if (!std.mem.startsWith(u8, o, prefix)) return false;
    const port = std.fmt.parseInt(u16, o[prefix.len..], 10) catch return false;
    return port >= 1024;
}

const testing = std.testing;

test "only Slack's MCP server, and only a loopback test stand-in" {
    try testing.expect(isSlack("https://mcp.slack.com/mcp"));
    try testing.expect(isSlack("https://mcp.slack.com"));
    try testing.expect(!isSlack("https://mcp.slack.com.evil.example/mcp"));
    try testing.expect(!isSlack(null));
    try testing.expect(loopbackOrigin("http://127.0.0.1:8080"));
    try testing.expect(!loopbackOrigin("http://127.0.0.1:80"));
    try testing.expect(!loopbackOrigin("https://evil.example"));
    try testing.expect(!loopbackOrigin("http://127.0.0.1:8080/x"));
}

test "fx's Slack app signs in only to Slack's MCP server, or a test stand-in's own" {
    try testing.expect(appServerAt("https://mcp.slack.com/mcp", null));
    try testing.expect(!appServerAt("https://mcp.example.com/mcp", null));
    try testing.expect(!appServerAt("http://127.0.0.1:8080/mcp", null));
    try testing.expect(appServerAt("http://127.0.0.1:8080/mcp", "http://127.0.0.1:8080"));
    try testing.expect(appServerAt("https://mcp.slack.com/mcp", "http://127.0.0.1:8080"));
    try testing.expect(!appServerAt("http://127.0.0.1:9090/mcp", "http://127.0.0.1:8080"));
    try testing.expect(!appServerAt("http://127.0.0.1:80800/mcp", "http://127.0.0.1:8080"));
    try testing.expect(!appServerAt("http://127.0.0.1:8080/other", "http://127.0.0.1:8080"));
    try testing.expect(!appServer(null));
}
