const std = @import("std");

const Allocator = std.mem.Allocator;

pub const default_startup_timeout_ms: u32 = 30_000;
pub const default_operation_timeout_ms: u32 = 60_000;
pub const default_elicitation_timeout_ms: u32 = 30 * 60_000;
pub const default_restart_limit: u8 = 1;

test "MCP default startup timeout allows thirty-second cold starts" {
    try std.testing.expectEqual(@as(u32, 30_000), default_startup_timeout_ms);
}

pub const max_profile_config_warning_key_bytes: usize = 128;

pub const ProfileConfigWarningCause = enum {
    ignored_mcp_servers_alias,
    suspicious_server_key,
    suspicious_key_scan_indeterminate,
};

pub const ProfileConfigWarning = struct {
    cause: ProfileConfigWarningCause,
    key_bytes: [max_profile_config_warning_key_bytes]u8 = undefined,
    key_len: u16 = 0,
    additional_matches: usize = 0,

    pub fn init(
        cause: ProfileConfigWarningCause,
        key_value: ?[]const u8,
        additional_matches: usize,
    ) ProfileConfigWarning {
        var result = ProfileConfigWarning{
            .cause = cause,
            .additional_matches = additional_matches,
        };
        if (key_value) |value| {
            const len = @min(value.len, max_profile_config_warning_key_bytes);
            @memcpy(result.key_bytes[0..len], value[0..len]);
            result.key_len = @intCast(len);
        }
        return result;
    }

    pub fn key(self: *const ProfileConfigWarning) ?[]const u8 {
        return if (self.key_len == 0) null else self.key_bytes[0..self.key_len];
    }
};

pub const ProfileConfigDiagnostic = union(enum) {
    clear,
    warning: ProfileConfigWarning,
    failed: anyerror,
};

pub const InspectProfileConfigFn = *const fn (
    Allocator,
) error{OutOfMemory}!ProfileConfigDiagnostic;

pub const McpEnvVar = struct {
    key: []u8,
    value: []u8,
};

pub const McpHttpHeader = struct {
    name: []u8,
    value: []u8,
};

pub const McpHttpHeaderEnv = struct {
    name: []u8,
    env: []u8,
};

pub const McpAuthConfig = struct {
    resource: ?[]u8 = null,
    issuer: ?[]u8 = null,
    client_id: ?[]u8 = null,
    client_secret_env: ?[]u8 = null,
    client_metadata_url: ?[]u8 = null,
    scopes: [][]u8 = &.{},
    callback_port: ?u16 = null,

    pub fn deinit(self: *McpAuthConfig, alloc: Allocator) void {
        if (self.resource) |value| alloc.free(value);
        if (self.issuer) |value| alloc.free(value);
        if (self.client_id) |value| alloc.free(value);
        if (self.client_secret_env) |value| alloc.free(value);
        if (self.client_metadata_url) |value| alloc.free(value);
        freeOwnedStrings(alloc, self.scopes);
        self.* = .{};
    }
};

pub const Progress = struct {
    progress: f64,
    total: ?f64 = null,
    message: ?[]const u8 = null,
};

pub const ProgressSink = struct {
    context: *anyopaque,
    callback: *const fn (*anyopaque, Progress) void,
};

/// Receives a borrowed, validated JSON-RPC notification object. Implementations
/// must return promptly and must not retain pointers into the value.
pub const NotificationSink = struct {
    context: *anyopaque,
    callback: *const fn (*anyopaque, std.json.Value) void,
};

/// Observes one borrowed, validated JSON-RPC response before the transport
/// publishes it to the requesting thread. Implementations must return promptly
/// and must not retain pointers into the value.
pub const ResponseObserver = struct {
    context: *anyopaque,
    callback: *const fn (*anyopaque, Allocator, std.json.Value) anyerror!void,
};

/// Receives one owned-lifetime JSON-RPC server request frame. Transports invoke
/// the optional preparation callback on the reader before dispatching later
/// frames, so it must return promptly. They invoke the main callback outside
/// reader and state locks so it may wait for input and write the response.
pub const ServerRequestSink = struct {
    context: *anyopaque,
    prepare_callback: ?*const fn (*anyopaque, Allocator, []const u8) anyerror!void = null,
    callback: *const fn (*anyopaque, Allocator, []const u8) anyerror!void,
};

/// Acquires the final authorization guard immediately before a transport
/// commits request bytes, then releases it as soon as commitment completes.
pub const TransportPrecommit = struct {
    context: *anyopaque,
    acquire_callback: *const fn (*anyopaque) anyerror!void,
    release_callback: *const fn (*anyopaque) void,
    acquired: bool = false,

    pub fn acquire(self: *TransportPrecommit) !void {
        if (self.acquired) return;
        try self.acquire_callback(self.context);
        self.acquired = true;
    }

    pub fn release(self: *TransportPrecommit) void {
        if (!self.acquired) return;
        self.acquired = false;
        self.release_callback(self.context);
    }
};

test "transport precommit acquires and releases exactly once" {
    const State = struct {
        acquisitions: usize = 0,
        releases: usize = 0,

        fn acquire(raw: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.acquisitions += 1;
        }

        fn release(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.releases += 1;
        }
    };
    var state = State{};
    var precommit = TransportPrecommit{
        .context = &state,
        .acquire_callback = State.acquire,
        .release_callback = State.release,
    };
    try precommit.acquire();
    try precommit.acquire();
    precommit.release();
    precommit.release();
    try std.testing.expectEqual(@as(usize, 1), state.acquisitions);
    try std.testing.expectEqual(@as(usize, 1), state.releases);
}

pub const McpTransport = enum { stdio, http, sse };

pub const ConfigSource = enum {
    profile,
    acp,
    workspace,
};

pub const ConfigScope = enum {
    profile,
    acp_session,
    workspace,
};

pub fn sourceAllowsScope(source: ConfigSource, scope: ConfigScope) bool {
    return switch (source) {
        .profile => scope == .profile,
        .acp => scope == .acp_session,
        .workspace => scope == .workspace,
    };
}

pub const WorkspaceAdmission = enum {
    pending,
    approved,
    rejected,
};

pub fn sourceAllowsWorkspaceAdmission(
    source: ConfigSource,
    admission: ?WorkspaceAdmission,
) bool {
    return switch (source) {
        .workspace => admission != null,
        .profile, .acp => admission == null,
    };
}

pub fn validateJsonRpcResponseEnvelope(value: std.json.Value) !void {
    if (value != .object) return error.McpInvalidJson;
    const object = value.object;
    const jsonrpc = object.get("jsonrpc") orelse return error.McpInvalidJson;
    if (jsonrpc != .string or !std.mem.eql(u8, jsonrpc.string, "2.0")) {
        return error.McpInvalidJson;
    }
    if (object.contains("result") == object.contains("error")) {
        return error.McpInvalidJson;
    }
}

/// One configured MCP server. Owns every field; `deinit` releases them.
pub const McpServerConfig = struct {
    name: []const u8,
    source: ConfigSource = .profile,
    scope: ConfigScope = .profile,
    required: bool = false,
    transport: McpTransport = .stdio,
    command: ?[]const u8 = null,
    args: []const []const u8 = &.{},
    url: ?[]const u8 = null,
    env: []McpEnvVar = &.{},
    headers: []McpHttpHeader = &.{},
    header_env: []McpHttpHeaderEnv = &.{},
    bearer_token_env: ?[]u8 = null,
    auth: ?McpAuthConfig = null,
    allow_stored_credentials: bool = false,
    enabled: bool = true,
    workspace_admission: ?WorkspaceAdmission = null,
    startup_timeout_ms: u32 = default_startup_timeout_ms,
    operation_timeout_ms: u32 = default_operation_timeout_ms,
    restart_limit: u8 = default_restart_limit,

    pub fn stdioCommand(self: *const McpServerConfig) error{McpInvalidServerConfig}![]const u8 {
        if (self.transport != .stdio) return error.McpInvalidServerConfig;
        const command = self.command orelse return error.McpInvalidServerConfig;
        if (command.len == 0) return error.McpInvalidServerConfig;
        return command;
    }

    pub fn remoteUrl(self: *const McpServerConfig) error{McpInvalidServerConfig}![]const u8 {
        if (self.transport == .stdio) return error.McpInvalidServerConfig;
        const url = self.url orelse return error.McpInvalidServerConfig;
        if (url.len == 0) return error.McpInvalidServerConfig;
        return url;
    }

    pub fn deinit(self: *McpServerConfig, alloc: Allocator) void {
        alloc.free(self.name);
        if (self.command) |command| alloc.free(command);
        freeOwnedStrings(alloc, self.args);
        if (self.url) |url| alloc.free(url);
        freeEnvVars(alloc, self.env);
        freeHttpHeaders(alloc, self.headers);
        freeHttpHeaderEnv(alloc, self.header_env);
        if (self.bearer_token_env) |value| alloc.free(value);
        if (self.auth) |*auth| auth.deinit(alloc);
        self.* = undefined;
    }
};

test "MCP server configuration exposes only the active transport target" {
    const stdio: McpServerConfig = .{ .name = "stdio", .command = "node" };
    try std.testing.expectEqualStrings("node", try stdio.stdioCommand());
    try std.testing.expectError(error.McpInvalidServerConfig, stdio.remoteUrl());

    const remote: McpServerConfig = .{
        .name = "remote",
        .transport = .http,
        .url = "https://example.test/mcp",
    };
    try std.testing.expectEqualStrings("https://example.test/mcp", try remote.remoteUrl());
    try std.testing.expectError(error.McpInvalidServerConfig, remote.stdioCommand());

    const missing_stdio: McpServerConfig = .{ .name = "missing" };
    try std.testing.expectError(error.McpInvalidServerConfig, missing_stdio.stdioCommand());

    const empty_remote: McpServerConfig = .{
        .name = "empty",
        .transport = .sse,
        .url = "",
    };
    try std.testing.expectError(error.McpInvalidServerConfig, empty_remote.remoteUrl());
}

test "profile config warning owns a bounded key inline" {
    const warning = ProfileConfigWarning.init(
        .suspicious_server_key,
        "MCP-Servers",
        2,
    );
    try std.testing.expectEqualStrings("MCP-Servers", warning.key().?);
    try std.testing.expectEqual(@as(usize, 2), warning.additional_matches);
    try std.testing.expect(ProfileConfigWarning.init(
        .suspicious_key_scan_indeterminate,
        null,
        0,
    ).key() == null);
}

test "MCP server configuration deinit owns present empty targets" {
    const alloc = std.testing.allocator;
    var config: McpServerConfig = .{
        .name = try alloc.dupe(u8, "empty-owned-targets"),
        .command = try alloc.dupe(u8, ""),
        .url = try alloc.dupe(u8, ""),
    };
    config.deinit(alloc);
}

test "MCP configuration sources admit only their product scope" {
    for ([_]ConfigSource{ .profile, .acp, .workspace }) |source| {
        for ([_]ConfigScope{ .profile, .acp_session, .workspace }) |scope| {
            const expected = switch (source) {
                .profile => scope == .profile,
                .acp => scope == .acp_session,
                .workspace => scope == .workspace,
            };
            try std.testing.expectEqual(expected, sourceAllowsScope(source, scope));
        }
    }
}

test "workspace admission is present exactly for workspace source" {
    for ([_]ConfigSource{ .profile, .acp, .workspace }) |source| {
        for ([_]?WorkspaceAdmission{ null, .pending, .approved, .rejected }) |admission| {
            const expected = if (source == .workspace) admission != null else admission == null;
            try std.testing.expectEqual(
                expected,
                sourceAllowsWorkspaceAdmission(source, admission),
            );
        }
    }
}

pub fn freeOwnedStrings(alloc: Allocator, values: []const []const u8) void {
    if (values.len == 0) return;
    for (values) |value| alloc.free(value);
    alloc.free(values);
}

pub fn freeHttpHeaderEnv(alloc: Allocator, headers: []const McpHttpHeaderEnv) void {
    if (headers.len == 0) return;
    for (headers) |header| {
        alloc.free(header.name);
        alloc.free(header.env);
    }
    alloc.free(headers);
}

pub fn freeEnvVars(alloc: Allocator, vars: []const McpEnvVar) void {
    if (vars.len == 0) return;
    for (vars) |entry| {
        alloc.free(entry.key);
        alloc.free(entry.value);
    }
    alloc.free(vars);
}

pub fn freeHttpHeaders(alloc: Allocator, headers: []const McpHttpHeader) void {
    if (headers.len == 0) return;
    for (headers) |header| {
        alloc.free(header.name);
        alloc.free(header.value);
    }
    alloc.free(headers);
}

test "JSON-RPC response envelopes require version 2.0 and one payload member" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        json: []const u8,
        valid: bool,
    }{
        .{ .json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null}", .valid = true },
        .{ .json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":null}", .valid = true },
        .{ .json = "{\"id\":1,\"result\":null}", .valid = false },
        .{ .json = "{\"jsonrpc\":\"1.0\",\"id\":1,\"result\":null}", .valid = false },
        .{ .json = "{\"jsonrpc\":\"2.0\",\"id\":1}", .valid = false },
        .{ .json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null,\"error\":null}", .valid = false },
    };
    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, case.json, .{});
        defer parsed.deinit();
        if (case.valid) {
            try validateJsonRpcResponseEnvelope(parsed.value);
        } else {
            try std.testing.expectError(
                error.McpInvalidJson,
                validateJsonRpcResponseEnvelope(parsed.value),
            );
        }
    }
}
