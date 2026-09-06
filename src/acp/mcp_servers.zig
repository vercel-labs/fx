const std = @import("std");
const builtin_tools = @import("../builtins/tools.zig");
const mcp_contract = @import("../core/mcp/mcp_contract.zig");
const mcp_runtime = @import("../core/mcp/mcp_runtime.zig");
const streamable_http = @import("../core/mcp/streamable_http.zig");
const elicitation = @import("../core/mcp/elicitation.zig");
const tool_mcp_runtime = @import("../core/tooling/tool_mcp_runtime.zig");

const Allocator = std.mem.Allocator;

pub const ParseError = Allocator.Error || error{
    MissingParams,
    InvalidParams,
    InvalidMcpServers,
    InvalidMcpServer,
    MissingServerName,
    InvalidServerName,
    MissingCommand,
    InvalidCommand,
    CommandNotAbsolute,
    MissingArgs,
    InvalidArgs,
    MissingEnv,
    InvalidEnv,
    MissingUrl,
    InvalidUrl,
    MissingHeaders,
    InvalidHeaders,
    InvalidTransport,
};

pub const OwnedServerConfigs = struct {
    items: std.ArrayList(mcp_contract.McpServerConfig) = .empty,

    pub fn deinit(self: *OwnedServerConfigs, alloc: Allocator) void {
        for (self.items.items) |*config| config.deinit(alloc);
        self.items.deinit(alloc);
        self.* = undefined;
    }
};

pub const Preparation = union(enum) {
    ready: ?*mcp_runtime.McpRuntime,
    failed: []u8,

    pub fn deinit(self: *Preparation, alloc: Allocator) void {
        switch (self.*) {
            .ready => |maybe_runtime| {
                if (maybe_runtime) |runtime| {
                    runtime.deinit();
                    alloc.destroy(runtime);
                }
            },
            .failed => |message| alloc.free(message),
        }
        self.* = undefined;
    }

    pub fn takeRuntime(self: *Preparation) ?*mcp_runtime.McpRuntime {
        return switch (self.*) {
            .ready => |runtime| blk: {
                self.* = .{ .ready = null };
                break :blk runtime;
            },
            .failed => unreachable,
        };
    }
};

/// Parses the authoritative ACP `mcpServers` list into owned core configs.
/// An omitted list is authoritative empty. The returned configs must be
/// deinitialized or moved into `prepare`.
pub fn parse(alloc: Allocator, params_raw: ?[]const u8) ParseError!OwnedServerConfigs {
    const params = params_raw orelse return error.MissingParams;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, params, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidParams,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidParams;

    const servers_value = parsed.value.object.get("mcpServers") orelse return .{};
    if (servers_value != .array) return error.InvalidMcpServers;

    var configs: OwnedServerConfigs = .{};
    errdefer configs.deinit(alloc);
    try configs.items.ensureTotalCapacity(alloc, servers_value.array.items.len);
    for (servers_value.array.items) |server_value| {
        var config: mcp_contract.McpServerConfig = undefined;
        try parseServerInto(&config, alloc, server_value);
        configs.items.appendAssumeCapacity(config);
    }
    return configs;
}

/// Parses the authoritative ACP `session/resume` MCP server list.
pub fn parseResume(alloc: Allocator, params_raw: ?[]const u8) ParseError!OwnedServerConfigs {
    return parse(alloc, params_raw);
}

/// Moves parsed configs into an existing MCP runtime and performs required
/// server startup. A failed result owns its rendered diagnostic.
pub fn prepare(
    alloc: Allocator,
    configs: *OwnedServerConfigs,
    elicitation_capabilities: elicitation.Capabilities,
    legacy_url_completion_sink: ?tool_mcp_runtime.LegacyUrlCompletionSink,
) Allocator.Error!Preparation {
    if (configs.items.items.len == 0) return .{ .ready = null };

    const runtime = try alloc.create(mcp_runtime.McpRuntime);
    runtime.* = mcp_runtime.McpRuntime.initWithElicitation(alloc, elicitation_capabilities);
    runtime.setLegacyUrlCompletionSink(legacy_url_completion_sink);
    var runtime_owned = true;
    defer if (runtime_owned) {
        runtime.deinit();
        alloc.destroy(runtime);
    };

    while (configs.items.items.len > 0) {
        var config = configs.items.orderedRemove(0);
        runtime.addServer(config) catch |err| {
            config.deinit(alloc);
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.McpConfigScopeMismatch, error.McpConfigAdmissionMismatch, error.McpRuntimeAlreadyStarted => unreachable,
            };
        };
    }
    runtime.connectAllForAcp(builtin_tools.registry);

    for (runtime.servers.items) |server_state| {
        if (server_state.state.load(.acquire) == .ready or !server_state.config.required) continue;
        const reason = server_state.last_error orelse @tagName(server_state.state.load(.acquire));
        const acp_reason = if (std.mem.startsWith(
            u8,
            reason,
            "Authentication required.",
        ))
            "Authentication required; supply an Authorization header in the ACP MCP server configuration."
        else
            reason;
        return .{ .failed = try std.fmt.allocPrint(
            alloc,
            "Required MCP server '{s}' failed to start: {s}",
            .{ server_state.config.name, acp_reason },
        ) };
    }

    runtime_owned = false;
    return .{ .ready = runtime };
}

pub fn parseErrorMessage(err: ParseError) []const u8 {
    return switch (err) {
        error.OutOfMemory => "Out of memory",
        error.MissingParams => "Missing params",
        error.InvalidParams => "Invalid params",
        error.InvalidMcpServers => "mcpServers must be an array",
        error.InvalidMcpServer => "Each mcpServers entry must be an object",
        error.MissingServerName => "Each MCP server requires name",
        error.InvalidServerName => "MCP server name must be a non-empty string",
        error.MissingCommand => "Each stdio MCP server requires command",
        error.InvalidCommand => "MCP server command must be a non-empty string",
        error.CommandNotAbsolute => "MCP server command must be an absolute executable path",
        error.MissingArgs => "Each stdio MCP server requires args",
        error.InvalidArgs => "MCP server args must be an array of strings",
        error.MissingEnv => "Each stdio MCP server requires env",
        error.InvalidEnv => "MCP server env must be an array of name/value string entries",
        error.MissingUrl => "Each HTTP MCP server requires url",
        error.InvalidUrl => "MCP server url must be a valid HTTPS or explicit loopback HTTP endpoint",
        error.MissingHeaders => "Each HTTP MCP server requires headers",
        error.InvalidHeaders => "MCP server headers must be valid unique name/value string entries",
        error.InvalidTransport => "Unsupported MCP server transport",
    };
}

// Keep fallible config construction behind caller-owned storage so error
// returns do not materialize the complete config payload.
noinline fn parseServerInto(
    out: *mcp_contract.McpServerConfig,
    alloc: Allocator,
    server_value: std.json.Value,
) ParseError!void {
    if (server_value != .object) return error.InvalidMcpServer;
    const object = server_value.object;

    const name_value = object.get("name") orelse return error.MissingServerName;
    if (name_value != .string or name_value.string.len == 0) {
        return error.InvalidServerName;
    }

    if (object.get("type")) |transport_value| {
        if (transport_value != .string) return error.InvalidTransport;
        const transport: mcp_contract.McpTransport =
            if (std.mem.eql(u8, transport_value.string, "http"))
                .http
            else if (std.mem.eql(u8, transport_value.string, "sse"))
                .sse
            else
                return error.InvalidTransport;
        return parseRemoteServerInto(
            out,
            alloc,
            object,
            name_value.string,
            transport,
        );
    }

    const command_value = object.get("command") orelse return error.MissingCommand;
    if (command_value != .string or command_value.string.len == 0) {
        return error.InvalidCommand;
    }
    if (!std.fs.path.isAbsolute(command_value.string)) {
        return error.CommandNotAbsolute;
    }
    const args_value = object.get("args") orelse return error.MissingArgs;
    const env_value = object.get("env") orelse return error.MissingEnv;

    const owned_name = try alloc.dupe(u8, name_value.string);
    errdefer alloc.free(owned_name);
    const owned_command = try alloc.dupe(u8, command_value.string);
    errdefer alloc.free(owned_command);
    const owned_args = try parseArgs(alloc, args_value);
    errdefer mcp_contract.freeOwnedStrings(alloc, owned_args);
    const owned_env = try parseEnv(alloc, env_value);
    errdefer mcp_contract.freeEnvVars(alloc, owned_env);

    out.* = .{
        .name = owned_name,
        .source = .acp,
        .scope = .acp_session,
        .required = true,
        .command = owned_command,
        .args = owned_args,
        .env = owned_env,
    };
}

fn parseRemoteServerInto(
    out: *mcp_contract.McpServerConfig,
    alloc: Allocator,
    object: std.json.ObjectMap,
    name: []const u8,
    transport: mcp_contract.McpTransport,
) ParseError!void {
    const url_value = object.get("url") orelse return error.MissingUrl;
    if (url_value != .string or url_value.string.len == 0) return error.InvalidUrl;
    streamable_http.validateEndpoint(url_value.string) catch return error.InvalidUrl;

    const headers_value = object.get("headers") orelse return error.MissingHeaders;
    const headers = try parseHttpHeaders(alloc, headers_value);
    errdefer mcp_contract.freeHttpHeaders(alloc, headers);

    const owned_name = try alloc.dupe(u8, name);
    errdefer alloc.free(owned_name);
    const owned_url = try alloc.dupe(u8, url_value.string);

    out.* = .{
        .name = owned_name,
        .source = .acp,
        .scope = .acp_session,
        .required = true,
        .transport = transport,
        .url = owned_url,
        .headers = headers,
    };
}

fn parseHttpHeaders(
    alloc: Allocator,
    headers_value: std.json.Value,
) ParseError![]mcp_contract.McpHttpHeader {
    if (headers_value != .array) return error.InvalidHeaders;
    if (headers_value.array.items.len == 0) return &.{};

    const headers = try alloc.alloc(
        mcp_contract.McpHttpHeader,
        headers_value.array.items.len,
    );
    var owned_count: usize = 0;
    errdefer {
        for (headers[0..owned_count]) |header| {
            alloc.free(header.name);
            alloc.free(header.value);
        }
        alloc.free(headers);
    }

    for (headers_value.array.items, 0..) |header_value, index| {
        if (header_value != .object) return error.InvalidHeaders;
        const name_value = header_value.object.get("name") orelse return error.InvalidHeaders;
        const value_value = header_value.object.get("value") orelse return error.InvalidHeaders;
        if (name_value != .string or value_value != .string) return error.InvalidHeaders;

        const owned_name = try alloc.dupe(u8, name_value.string);
        errdefer alloc.free(owned_name);
        const owned_value = try alloc.dupe(u8, value_value.string);
        headers[index] = .{ .name = owned_name, .value = owned_value };
        owned_count += 1;
    }

    streamable_http.validateStaticHeaders(headers) catch return error.InvalidHeaders;
    return headers;
}

fn parseArgs(alloc: Allocator, args_value: std.json.Value) ParseError![]const []const u8 {
    if (args_value != .array) return error.InvalidArgs;
    if (args_value.array.items.len == 0) return &.{};

    const args = try alloc.alloc([]const u8, args_value.array.items.len);
    var owned_count: usize = 0;
    errdefer {
        for (args[0..owned_count]) |arg| alloc.free(arg);
        alloc.free(args);
    }
    for (args_value.array.items, 0..) |arg_value, index| {
        if (arg_value != .string) return error.InvalidArgs;
        args[index] = try alloc.dupe(u8, arg_value.string);
        owned_count += 1;
    }
    return args;
}

fn parseEnv(alloc: Allocator, env_value: std.json.Value) ParseError![]mcp_contract.McpEnvVar {
    if (env_value != .array) return error.InvalidEnv;
    if (env_value.array.items.len == 0) return &.{};

    const env = try alloc.alloc(mcp_contract.McpEnvVar, env_value.array.items.len);
    var owned_count: usize = 0;
    errdefer {
        for (env[0..owned_count]) |entry| {
            alloc.free(entry.key);
            alloc.free(entry.value);
        }
        alloc.free(env);
    }
    for (env_value.array.items, 0..) |entry_value, index| {
        if (entry_value != .object) return error.InvalidEnv;
        const name_value = entry_value.object.get("name") orelse return error.InvalidEnv;
        const value_value = entry_value.object.get("value") orelse return error.InvalidEnv;
        if (name_value != .string or name_value.string.len == 0 or value_value != .string) {
            return error.InvalidEnv;
        }
        const key = try alloc.dupe(u8, name_value.string);
        errdefer alloc.free(key);
        const value = try alloc.dupe(u8, value_value.string);
        env[index] = .{ .key = key, .value = value };
        owned_count += 1;
    }
    return env;
}

test "ACP MCP parser owns official stdio request fields" {
    const alloc = std.testing.allocator;
    var configs = try parse(alloc,
        \\{"cwd":"/tmp","mcpServers":[{"name":"fixture","command":"/usr/bin/node","args":["server.mjs","--flag"],"env":[{"name":"TOKEN","value":"secret"}]}]}
    );
    defer configs.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), configs.items.items.len);
    const config = configs.items.items[0];
    try std.testing.expectEqualStrings("fixture", config.name);
    try std.testing.expectEqualStrings("/usr/bin/node", try config.stdioCommand());
    try std.testing.expectEqual(@as(usize, 2), config.args.len);
    try std.testing.expectEqualStrings("server.mjs", config.args[0]);
    try std.testing.expectEqualStrings("--flag", config.args[1]);
    try std.testing.expectEqualStrings("TOKEN", config.env[0].key);
    try std.testing.expectEqualStrings("secret", config.env[0].value);
}

test "ACP MCP parser accepts an authoritative empty list" {
    const alloc = std.testing.allocator;
    var configs = try parse(alloc, "{\"mcpServers\":[]}");
    defer configs.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), configs.items.items.len);
}

test "ACP MCP parsers treat an omitted list as authoritative empty" {
    const alloc = std.testing.allocator;
    var new_or_load_configs = try parse(alloc, "{}");
    defer new_or_load_configs.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), new_or_load_configs.items.items.len);

    var configs = try parseResume(alloc, "{\"sessionId\":\"session\",\"cwd\":\"/tmp\"}");
    defer configs.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), configs.items.items.len);

    try std.testing.expectError(error.InvalidMcpServers, parseResume(
        alloc,
        "{\"sessionId\":\"session\",\"cwd\":\"/tmp\",\"mcpServers\":null}",
    ));
}

test "ACP MCP parser rejects malformed required stdio fields" {
    const cases = [_]struct {
        json: ?[]const u8,
        expected: ParseError,
    }{
        .{ .json = null, .expected = error.MissingParams },
        .{ .json = "[]", .expected = error.InvalidParams },
        .{ .json = "{\"mcpServers\":{}}", .expected = error.InvalidMcpServers },
        .{ .json = "{\"mcpServers\":[null]}", .expected = error.InvalidMcpServer },
        .{ .json = "{\"mcpServers\":[{}]}", .expected = error.MissingServerName },
        .{ .json = "{\"mcpServers\":[{\"name\":\"\"}]}", .expected = error.InvalidServerName },
        .{ .json = "{\"mcpServers\":[{\"name\":\"x\"}]}", .expected = error.MissingCommand },
        .{ .json = "{\"mcpServers\":[{\"name\":\"x\",\"command\":\"node\",\"args\":[],\"env\":[]}]}", .expected = error.CommandNotAbsolute },
        .{ .json = "{\"mcpServers\":[{\"name\":\"x\",\"command\":\"/bin/x\",\"env\":[]}]}", .expected = error.MissingArgs },
        .{ .json = "{\"mcpServers\":[{\"name\":\"x\",\"command\":\"/bin/x\",\"args\":[1],\"env\":[]}]}", .expected = error.InvalidArgs },
        .{ .json = "{\"mcpServers\":[{\"name\":\"x\",\"command\":\"/bin/x\",\"args\":[]}]}", .expected = error.MissingEnv },
        .{ .json = "{\"mcpServers\":[{\"name\":\"x\",\"command\":\"/bin/x\",\"args\":[],\"env\":[{\"name\":\"TOKEN\",\"value\":1}]}]}", .expected = error.InvalidEnv },
    };

    for (cases) |case| {
        try std.testing.expectError(case.expected, parse(std.testing.allocator, case.json));
    }
}

test "ACP MCP parser owns official HTTP request fields" {
    const alloc = std.testing.allocator;
    var configs = try parse(
        alloc,
        "{\"mcpServers\":[{\"type\":\"http\",\"name\":\"remote\",\"url\":\"https://example.test/mcp\",\"headers\":[{\"name\":\"Authorization\",\"value\":\"Bearer secret\"}]}]}",
    );
    defer configs.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), configs.items.items.len);
    const config = configs.items.items[0];
    try std.testing.expectEqual(mcp_contract.McpTransport.http, config.transport);
    try std.testing.expectEqualStrings("remote", config.name);
    try std.testing.expectEqualStrings("https://example.test/mcp", try config.remoteUrl());
    try std.testing.expectEqualStrings("Authorization", config.headers[0].name);
    try std.testing.expectEqualStrings("Bearer secret", config.headers[0].value);
}

test "ACP MCP parser accepts deprecated SSE without losing identity" {
    const alloc = std.testing.allocator;
    var configs = try parse(
        alloc,
        "{\"mcpServers\":[{\"type\":\"sse\",\"name\":\"legacy\",\"url\":\"https://example.test/sse\",\"headers\":[{\"name\":\"X-Workspace\",\"value\":\"one\"}]}]}",
    );
    defer configs.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), configs.items.items.len);
    const config = configs.items.items[0];
    try std.testing.expectEqual(mcp_contract.McpTransport.sse, config.transport);
    try std.testing.expectEqualStrings("https://example.test/sse", try config.remoteUrl());
    try std.testing.expectEqualStrings("X-Workspace", config.headers[0].name);
}

test "ACP MCP parser rejects invalid remote transports" {
    try std.testing.expectError(
        error.MissingHeaders,
        parse(std.testing.allocator, "{\"mcpServers\":[{\"type\":\"http\",\"name\":\"remote\",\"url\":\"https://example.test\"}]}"),
    );
    try std.testing.expectError(
        error.InvalidUrl,
        parse(std.testing.allocator, "{\"mcpServers\":[{\"type\":\"http\",\"name\":\"remote\",\"url\":\"http://example.test\",\"headers\":[]}]}"),
    );
    try std.testing.expectError(
        error.InvalidHeaders,
        parse(std.testing.allocator, "{\"mcpServers\":[{\"type\":\"http\",\"name\":\"remote\",\"url\":\"https://example.test\",\"headers\":[{\"name\":\"Mcp-Method\",\"value\":\"override\"}]}]}"),
    );
    try std.testing.expectError(
        error.InvalidHeaders,
        parse(std.testing.allocator, "{\"mcpServers\":[{\"type\":\"sse\",\"name\":\"remote\",\"url\":\"https://example.test\",\"headers\":[{\"name\":\"MCP-Session-Id\",\"value\":\"override\"}]}]}"),
    );
}

fn checkPreparationOwnershipAllocFailures(alloc: Allocator) !void {
    const runtime = try alloc.create(mcp_runtime.McpRuntime);
    runtime.* = mcp_runtime.McpRuntime.init(alloc);
    var preparation = Preparation{ .ready = runtime };
    defer preparation.deinit(alloc);

    var config = mcp_contract.McpServerConfig{
        .name = try alloc.dupe(u8, "fixture"),
        .enabled = false,
    };
    var config_owned = true;
    defer if (config_owned) config.deinit(alloc);
    try runtime.addServer(config);
    config_owned = false;

    const taken = preparation.takeRuntime().?;
    taken.deinit();
    alloc.destroy(taken);
}

test "ACP MCP preparation releases heap runtime ownership on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkPreparationOwnershipAllocFailures,
        .{},
    );
}

fn fuzzParse(_: void, smith: *std.testing.Smith) !void {
    var buffer: [4096]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    if (parse(std.testing.allocator, buffer[0..len])) |configs| {
        var owned = configs;
        owned.deinit(std.testing.allocator);
    } else |_| {}
    if (parseResume(std.testing.allocator, buffer[0..len])) |configs| {
        var owned = configs;
        owned.deinit(std.testing.allocator);
    } else |_| {}
}

test "ACP MCP parser handles fuzzed request bytes" {
    try std.testing.fuzz({}, fuzzParse, .{
        .corpus = &.{
            "",
            "{}",
            "{\"mcpServers\":[]}",
            "{\"mcpServers\":[{\"name\":\"fixture\",\"command\":\"/bin/echo\",\"args\":[],\"env\":[]}]}",
            "{\"mcpServers\":[{\"type\":\"http\",\"name\":\"fixture\",\"url\":\"http://localhost:4321/mcp\",\"headers\":[]}]}",
        },
    });
}
