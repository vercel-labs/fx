//! MCPv2 module root and public API.
//!
//! Files under `src/mcp/` import only `std` and each other. The host passes in
//! `std.Io` and everything else through `host.zig`. See `docs/approach.md`.

const std = @import("std");

/// JSON-RPC message decoding and encoding.
pub const wire = @import("protocol/wire.zig");

/// Tool list pages, the per-server tool store, and tool calls.
pub const tools = @import("protocol/tools.zig");

/// Multi round-trip requests: input_required rounds and retries.
pub const mrtr = @import("protocol/mrtr.zig");

/// Subscriptions: the listen request and what comes back on it.
pub const subscriptions = @import("protocol/subscriptions.zig");
pub const elicitation = @import("protocol/elicitation.zig");

/// OAuth: discovery and the authorization code flow (pure), and the
/// client `server` uses for one HTTP server.
pub const auth = struct {
    pub const discovery = @import("auth/discovery.zig");
    pub const oauth = @import("auth/oauth.zig");
    pub const client = @import("auth/client.zig");
};

/// Streamable HTTP request headers and x-mcp-header checks.
pub const http_headers = @import("protocol/http_headers.zig");

/// Runs one stdio server process.
pub const stdio = @import("io/process.zig");

/// Streamable HTTP (2026) POSTs over std.http.Client.
pub const http = @import("io/http.zig");

/// One server, over stdio or Streamable HTTP, as the client sees it.
pub const server = @import("server.zig");

/// Every configured server behind one API: lazy starts, the host's
/// permission before each call, status, and one event stream.
pub const engine = @import("engine.zig");

/// What the host gives the engine.
pub const Host = @import("host.zig").Host;

/// Step trace format shared by the I/O layer, the dev tools, and the Bun bridge.
pub const trace = @import("io/trace.zig");

/// Pure protocol machines, one per unit. Public so the dev labs and the
/// Bun driver can exercise them directly; fx itself uses the engine API.
pub const core = struct {
    pub const request = @import("core/request.zig");
    pub const stdio_conn = @import("core/stdio_conn.zig");
    pub const era = @import("core/era.zig");
    pub const catalog = @import("core/catalog.zig");
    pub const http_modern = @import("core/http_modern.zig");
    pub const http_legacy = @import("core/http_legacy.zig");
    pub const mrtr = @import("core/mrtr.zig");
    pub const auth = @import("core/auth.zig");
    pub const subscription = @import("core/subscription.zig");
    pub const elicitation = @import("core/elicitation.zig");
    pub const engine = @import("core/engine.zig");
};

test {
    // Reference every file in the module here so `zig test src/mcp/mcp.zig`
    // runs all of their inline tests.
    _ = wire;
    _ = tools;
    _ = mrtr;
    _ = subscriptions;
    _ = elicitation;
    _ = auth.discovery;
    _ = auth.oauth;
    _ = auth.client;
    _ = http_headers;
    _ = @import("protocol/sse.zig");
    _ = trace;
    _ = stdio;
    _ = http;
    _ = server;
    _ = engine;
    _ = @import("io/lines.zig");
    _ = @import("io/bell.zig");
    _ = core.request;
    _ = core.stdio_conn;
    _ = core.era;
    _ = core.catalog;
    _ = core.http_modern;
    _ = core.http_legacy;
    _ = core.mrtr;
    _ = core.auth;
    _ = core.subscription;
    _ = core.elicitation;
    _ = core.engine;
}
