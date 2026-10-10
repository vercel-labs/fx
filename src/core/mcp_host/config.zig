//! fx's MCP servers as MCP-v2 runs them. Each config from `builtins/mcp.zig`
//! `loadNativeConfigs` (profile first, then the project's) becomes an
//! `mcp.engine.Config`, or is held back with the reason, which fx shows.

const std = @import("std");
const mcp = @import("../../mcp/mcp.zig");
const mcp_contract = @import("../mcp/mcp_contract.zig");

const Allocator = std.mem.Allocator;
const McpServerConfig = mcp_contract.McpServerConfig;

/// Why a configured server is not given to the engine.
pub const Held = enum {
    /// `"enabled": false`.
    disabled,
    /// A project server nobody approved yet.
    waiting_for_approval,
    /// A project server the user rejected.
    rejected,
    /// `"type": "sse"`: HTTP+SSE is deprecated and MCP-v2 doesn't speak it.
    /// `"type": "acp"` from an editor: a draft that ACP v1 doesn't define.
    unsupported,
    /// A header, token, or client secret names an environment variable that isn't set.
    missing_env,
};

pub const Server = struct {
    name: []const u8,
    source: mcp_contract.ConfigSource,
    scope: mcp_contract.ConfigScope,
    transport: mcp_contract.McpTransport,
    /// An HTTP server's URL, which also keys its credential; null for stdio.
    url: ?[]const u8,
    /// What a stdio server runs, to show what is trusted.
    command: ?[]const u8,
    callback_port: ?u16,
    held: ?Held = null,
    /// An editor's server whose tools go to the model every turn (ACP
    /// `_meta.fx.alwaysLoaded`).
    always_loaded: bool = false,
    /// The variable a `missing_env` server names.
    missing: ?[]const u8 = null,
};

/// Looks up the credential saved for a server; owned by `alloc`.
pub const Saved = struct {
    context: *anyopaque,
    get: *const fn (context: *anyopaque, alloc: Allocator, name: []const u8, url: []const u8) Allocator.Error!?[]u8,
};

pub const Resolved = struct {
    servers: []Server,
    /// What the engine runs, in order: `engine[i]` is `servers[engine_server[i]]`.
    engine: []mcp.engine.Config,
    engine_server: []usize,
};

/// Allocates everything with `arena`, which must outlive the engine: the
/// engine copies each config but keeps pointing at a stdio server's
/// environment. A saved credential is copied into `arena`; zero it once the
/// engine has its own copy.
/// The command and its arguments as one line, quoting what a shell would split.
fn commandLine(arena: Allocator, command: []const u8, args: []const []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..args.len + 1) |k| {
        const word = if (k == 0) command else args[k - 1];
        if (k > 0) try out.append(arena, ' ');
        const plain = word.len > 0 and std.mem.indexOfAny(u8, word, " \t\n'\"$`\\") == null;
        if (plain) {
            try out.appendSlice(arena, word);
            continue;
        }
        try out.append(arena, '\'');
        for (word) |b| if (b == '\'') try out.appendSlice(arena, "'\\''") else try out.append(arena, b);
        try out.append(arena, '\'');
    }
    return out.items;
}

pub fn resolve(
    arena: Allocator,
    configs: []const McpServerConfig,
    inherited: *const std.process.Environ.Map,
    saved: ?Saved,
) Allocator.Error!Resolved {
    const servers = try arena.alloc(Server, configs.len);
    var engine: std.ArrayList(mcp.engine.Config) = .empty;
    var engine_server: std.ArrayList(usize) = .empty;
    for (configs, servers, 0..) |*c, *s, i| {
        s.* = .{
            .name = try arena.dupe(u8, c.name),
            .source = c.source,
            .scope = c.scope,
            .transport = c.transport,
            .url = if (c.url) |u| try arena.dupe(u8, u) else null,
            .command = if (c.command) |command| try commandLine(arena, command, c.args) else null,
            .callback_port = if (c.auth) |a| a.callback_port else null,
            .always_loaded = c.always_loaded,
        };
        s.held = heldFor(c);
        if (s.held != null) continue;
        const transport = (try transportFor(arena, c, inherited, s)) orelse continue;
        var auth: @FieldType(mcp.engine.Config, "auth") = .{};
        if (c.auth) |a| {
            auth.client_id = a.client_id;
            auth.client_metadata_url = a.client_metadata_url;
            if (a.client_secret_env) |variable| {
                auth.client_secret = inherited.get(variable) orelse {
                    s.held = .missing_env;
                    s.missing = try arena.dupe(u8, variable);
                    continue;
                };
            }
        }
        if (saved) |lookup| if (s.url) |url| {
            auth.saved = try lookup.get(lookup.context, arena, s.name, url);
        };
        try engine.append(arena, .{ .name = s.name, .transport = transport, .auth = auth });
        try engine_server.append(arena, i);
    }
    return .{ .servers = servers, .engine = engine.items, .engine_server = engine_server.items };
}

fn heldFor(c: *const McpServerConfig) ?Held {
    if (!c.enabled) return .disabled;
    if (c.source == .workspace) if (c.workspace_admission) |admission| switch (admission) {
        .pending => return .waiting_for_approval,
        .rejected => return .rejected,
        .approved => {},
    };
    if (c.transport == .sse or c.acp_server_id != null) return .unsupported;
    return null;
}

/// The engine's transport, or null when the server must be held back (and
/// `s` says why).
fn transportFor(
    arena: Allocator,
    c: *const McpServerConfig,
    inherited: *const std.process.Environ.Map,
    s: *Server,
) Allocator.Error!?mcp.engine.Transport {
    switch (c.transport) {
        .stdio => {
            const argv = try arena.alloc([]const u8, 1 + c.args.len);
            argv[0] = c.command orelse return null;
            @memcpy(argv[1..], c.args);
            // No map means the process gets fx's environment as it is.
            if (c.env.len == 0) return .{ .stdio = .{ .argv = argv } };
            const map = try arena.create(std.process.Environ.Map);
            map.* = try inherited.clone(arena);
            for (c.env) |e| try map.put(e.key, e.value);
            return .{ .stdio = .{ .argv = argv, .environ_map = map } };
        },
        .http => {
            var headers: std.ArrayList(std.http.Header) = .empty;
            for (c.headers) |h| try headers.append(arena, .{ .name = h.name, .value = h.value });
            for (c.header_env) |h| {
                const value = inherited.get(h.env) orelse return missing(arena, s, h.env);
                try headers.append(arena, .{ .name = h.name, .value = value });
            }
            if (c.bearer_token_env) |variable| {
                const token = inherited.get(variable) orelse return missing(arena, s, variable);
                try headers.append(arena, .{ .name = "Authorization", .value = try std.fmt.allocPrint(arena, "Bearer {s}", .{token}) });
            }
            return .{ .http = .{ .url = s.url orelse return null, .headers = headers.items } };
        },
        .sse => return null,
    }
}

fn missing(arena: Allocator, s: *Server, variable: []const u8) Allocator.Error!?mcp.engine.Transport {
    s.held = .missing_env;
    s.missing = try arena.dupe(u8, variable);
    return null;
}

const testing = std.testing;

fn envVar(comptime key: []const u8, comptime value: []const u8) mcp_contract.McpEnvVar {
    return .{ .key = @constCast(key), .value = @constCast(value) };
}

test "stdio and HTTP servers become engine configs; the rest are held back with the reason" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var inherited: std.process.Environ.Map = .init(testing.allocator);
    defer inherited.deinit();
    try inherited.put("PATH", "/usr/bin");
    try inherited.put("TEAM_TOKEN", "t1");
    try inherited.put("CLIENT_SECRET", "s1");

    var env = [_]mcp_contract.McpEnvVar{envVar("HOME", "/Users/me")};
    var header_env = [_]mcp_contract.McpHttpHeaderEnv{.{ .name = @constCast("X-Team"), .env = @constCast("TEAM_TOKEN") }};
    var missing_header = [_]mcp_contract.McpHttpHeaderEnv{.{ .name = @constCast("X-Key"), .env = @constCast("NOT_SET") }};
    const configs = [_]McpServerConfig{
        .{ .name = "ctx", .command = "node", .args = &.{"ctx.js"} },
        .{ .name = "kit", .command = "kit", .env = &env },
        .{ .name = "linear", .transport = .http, .url = "https://mcp.linear.app/mcp", .header_env = &header_env, .auth = .{ .client_id = @constCast("c1"), .client_secret_env = @constCast("CLIENT_SECRET"), .callback_port = 33418 } },
        .{ .name = "off", .command = "x", .enabled = false },
        .{ .name = "pending", .command = "x", .source = .workspace, .workspace_admission = .pending },
        .{ .name = "no", .command = "x", .source = .workspace, .workspace_admission = .rejected },
        .{ .name = "old", .transport = .sse, .url = "https://old.example/sse" },
        .{ .name = "keyless", .transport = .http, .url = "https://k.example/mcp", .header_env = &missing_header },
        .{ .name = "carried", .transport = .http, .url = "http://acp.invalid/x", .source = .acp, .acp_server_id = @constCast("x") },
    };
    const Lookup = struct {
        fn get(_: *anyopaque, alloc: Allocator, name: []const u8, url: []const u8) Allocator.Error!?[]u8 {
            if (std.mem.eql(u8, name, "linear") and std.mem.eql(u8, url, "https://mcp.linear.app/mcp")) return try alloc.dupe(u8, "{\"access\":\"a\"}");
            return null;
        }
    };
    var context: u8 = 0;
    const r = try resolve(arena, &configs, &inherited, .{ .context = &context, .get = Lookup.get });

    try testing.expectEqual(@as(usize, 3), r.engine.len);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, r.engine_server);
    try testing.expectEqualStrings("ctx.js", r.engine[0].transport.stdio.argv[1]);
    try testing.expect(r.engine[0].transport.stdio.environ_map == null);
    const kit_env = r.engine[1].transport.stdio.environ_map.?;
    try testing.expectEqualStrings("/Users/me", kit_env.get("HOME").?);
    try testing.expectEqualStrings("/usr/bin", kit_env.get("PATH").?);

    const linear = r.engine[2];
    try testing.expectEqualStrings("https://mcp.linear.app/mcp", linear.transport.http.url);
    try testing.expectEqualStrings("X-Team", linear.transport.http.headers[0].name);
    try testing.expectEqualStrings("t1", linear.transport.http.headers[0].value);
    try testing.expectEqualStrings("c1", linear.auth.client_id.?);
    try testing.expectEqualStrings("s1", linear.auth.client_secret.?);
    try testing.expectEqualStrings("{\"access\":\"a\"}", linear.auth.saved.?);
    try testing.expectEqual(@as(?u16, 33418), r.servers[2].callback_port);

    try testing.expectEqual(@as(?Held, .disabled), r.servers[3].held);
    try testing.expectEqual(@as(?Held, .waiting_for_approval), r.servers[4].held);
    try testing.expectEqual(@as(?Held, .rejected), r.servers[5].held);
    try testing.expectEqual(@as(?Held, .unsupported), r.servers[6].held);
    try testing.expectEqual(@as(?Held, .missing_env), r.servers[7].held);
    try testing.expectEqual(@as(?Held, .unsupported), r.servers[8].held);
    try testing.expectEqualStrings("NOT_SET", r.servers[7].missing.?);
}

test "a token from the environment becomes the Authorization header" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var inherited: std.process.Environ.Map = .init(testing.allocator);
    defer inherited.deinit();
    try inherited.put("PLAIN_KEY", "k1");
    const configs = [_]McpServerConfig{
        .{ .name = "plain", .transport = .http, .url = "https://mcp.plain.com/mcp", .bearer_token_env = @constCast("PLAIN_KEY") },
        .{ .name = "unset", .transport = .http, .url = "https://u.example/mcp", .bearer_token_env = @constCast("UNSET_KEY") },
    };
    const r = try resolve(arena_state.allocator(), &configs, &inherited, null);
    try testing.expectEqual(@as(usize, 1), r.engine.len);
    try testing.expectEqualStrings("Authorization", r.engine[0].transport.http.headers[0].name);
    try testing.expectEqualStrings("Bearer k1", r.engine[0].transport.http.headers[0].value);
    try testing.expectEqual(@as(?Held, .missing_env), r.servers[1].held);
    try testing.expectEqualStrings("UNSET_KEY", r.servers[1].missing.?);
}

test "a stdio server's command line quotes what a shell would split" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("node server.js --port 3", try commandLine(arena.allocator(), "node", &.{ "server.js", "--port", "3" }));
    try std.testing.expectEqualStrings("npx '' 'a b' 'it'\\''s' '$HOME'", try commandLine(arena.allocator(), "npx", &.{ "", "a b", "it's", "$HOME" }));
}
