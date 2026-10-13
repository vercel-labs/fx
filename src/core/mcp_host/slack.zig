//! Slack signs in through fx.sh, as v1 did: Slack has no client
//! registration, and fx's Slack app redirects only to fx.sh, whose page
//! hands the code back to fx on 127.0.0.1. MCP-v2 runs the sign-in as for
//! any server; only the redirect, the page the browser opens, and the
//! callback fx takes differ.

const std = @import("std");
const io_mod = @import("../shared/io.zig");

/// Slack's MCP server, which `add slack` uses when no URL is given.
pub const server_url = "https://mcp.slack.com/mcp";

/// fx's Slack app, used for Slack when the config names no app of its own.
pub const client_id = "12364000946.12017137861236";

/// The user scopes fx's Slack app has, encoded for a query. fx.sh takes
/// exactly these.
const scopes_query = "channels:history%20channels:read%20channels:write%20chat:write%20emoji:read%20files:write%20search:read.public%20search:read.users%20users:read";

/// Whether `url` is Slack's MCP server.
pub fn isSlack(url: ?[]const u8) bool {
    const u = url orelse return false;
    return std.mem.eql(u8, u, "https://mcp.slack.com") or std.mem.startsWith(u8, u, "https://mcp.slack.com/");
}

/// fx.sh, or for tests a bridge on 127.0.0.1 (`FX_E2E_SLACK_ORIGIN`), as v1 takes it.
pub fn origin() []const u8 {
    const configured = io_mod.getenv("FX_E2E_SLACK_ORIGIN") orelse return "https://fx.sh";
    return if (loopbackOrigin(configured)) configured else "https://fx.sh";
}

fn loopbackOrigin(o: []const u8) bool {
    const prefix = "http://127.0.0.1:";
    if (!std.mem.startsWith(u8, o, prefix)) return false;
    const port = std.fmt.parseInt(u16, o[prefix.len..], 10) catch return false;
    return port >= 1024;
}

/// Where Slack sends the browser back to: the one redirect fx's Slack app
/// allows, even when a test bridge stands in for fx.sh's pages.
pub const redirect_uri = "https://fx.sh/api/slack/oauth/callback";

/// The page the browser opens instead of Slack's: fx.sh's start, with the
/// state, PKCE challenge, and client from MCP-v2's `authorize` address, and
/// the port fx waits on. Owned by `alloc`; null when the address lacks one.
pub fn startUrl(alloc: std.mem.Allocator, bridge_origin: []const u8, authorize: []const u8, port: u16) std.mem.Allocator.Error!?[]u8 {
    const query = authorize[(std.mem.findScalar(u8, authorize, '?') orelse return null) + 1 ..];
    const state = param(query, "state") orelse return null;
    const challenge = param(query, "code_challenge") orelse return null;
    const client = param(query, "client_id") orelse return null;
    // All three are already encoded for a query, as MCP-v2 wrote them.
    return try alloc.print("{s}/api/slack/auth?state={s}&challenge={s}&client_id={s}&scope={s}&port={d}", .{
        bridge_origin, state, challenge, client, scopes_query, port,
    });
}

/// A query parameter's raw value, if it's there once or more; the first wins.
fn param(query: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.findScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

const testing = std.testing;

test "fx.sh's start carries MCP-v2's state, challenge, and client, fx's scopes, and the port" {
    const authorize = "https://slack.com/oauth/v2_user/authorize?response_type=code&client_id=12364000946.12017137861236" ++
        "&redirect_uri=https%3A%2F%2Ffx.sh%2Fapi%2Fslack%2Foauth%2Fcallback&scope=a%20b&state=S1&code_challenge=C1&code_challenge_method=S256";
    const url = (try startUrl(testing.allocator, "https://fx.sh", authorize, 53883)).?;
    defer testing.allocator.free(url);
    try testing.expectEqualStrings("https://fx.sh/api/slack/auth?state=S1&challenge=C1&client_id=12364000946.12017137861236" ++
        "&scope=channels:history%20channels:read%20channels:write%20chat:write%20emoji:read%20files:write%20search:read.public%20search:read.users%20users:read&port=53883", url);
    try testing.expectEqual(@as(?[]u8, null), try startUrl(testing.allocator, "https://fx.sh", "https://slack.com/oauth?state=S1", 1));
}

test "only Slack's MCP server, and only a loopback test bridge" {
    try testing.expect(isSlack("https://mcp.slack.com/mcp"));
    try testing.expect(isSlack("https://mcp.slack.com"));
    try testing.expect(!isSlack("https://mcp.slack.com.evil.example/mcp"));
    try testing.expect(!isSlack(null));
    try testing.expect(loopbackOrigin("http://127.0.0.1:8080"));
    try testing.expect(!loopbackOrigin("http://127.0.0.1:80"));
    try testing.expect(!loopbackOrigin("https://evil.example"));
    try testing.expect(!loopbackOrigin("http://127.0.0.1:8080/x"));
}
