const std = @import("std");
const mcp_contract = @import("mcp_contract.zig");
const project_config = @import("project_config.zig");
const streamable_http = @import("streamable_http.zig");

const Allocator = std.mem.Allocator;

pub const AddIntent = union(enum) {
    local: struct {
        name: []const u8,
        command: []const u8,
        args: []const []const u8,
    },
    http: struct {
        name: []const u8,
        url: []const u8,
    },
};

pub const AddIntentError = error{
    McpAddUsage,
    McpInvalidServerName,
    McpConfigInvalidUrl,
};

pub const ProfileAddResult = struct {
    profile_path: []u8,
    warning: ?mcp_contract.ProfileConfigWarning = null,

    pub fn deinit(self: *ProfileAddResult, alloc: Allocator) void {
        alloc.free(self.profile_path);
        self.* = undefined;
    }
};

pub const AddProfileServerFn = *const fn (
    alloc: Allocator,
    intent: AddIntent,
) anyerror!ProfileAddResult;

pub fn addProfileServerUnavailable(
    _: Allocator,
    _: AddIntent,
) anyerror!ProfileAddResult {
    return error.McpProfileMutationUnavailable;
}

pub const ProfileRemoveResult = struct {
    profile_path: []u8,
    removed: bool,
    warning: ?mcp_contract.ProfileConfigWarning = null,

    pub fn deinit(self: *ProfileRemoveResult, alloc: Allocator) void {
        alloc.free(self.profile_path);
        self.* = undefined;
    }
};

pub const RemoveProfileServerFn = *const fn (
    alloc: Allocator,
    name: []const u8,
) anyerror!ProfileRemoveResult;

pub fn removeProfileServerUnavailable(
    _: Allocator,
    _: []const u8,
) anyerror!ProfileRemoveResult {
    return error.McpProfileMutationUnavailable;
}

pub fn parseAddIntent(tokens: []const []const u8) AddIntentError!AddIntent {
    if (tokens.len == 0) return error.McpAddUsage;
    if (std.mem.eql(u8, tokens[0], "--transport")) {
        if (tokens.len != 4 or !std.mem.eql(u8, tokens[1], "http")) {
            return error.McpAddUsage;
        }
        if (!isValidServerName(tokens[2])) return error.McpInvalidServerName;
        streamable_http.validateEndpoint(tokens[3]) catch return error.McpConfigInvalidUrl;
        return .{ .http = .{ .name = tokens[2], .url = tokens[3] } };
    }
    if (tokens.len < 2) return error.McpAddUsage;
    if (!isValidServerName(tokens[0])) return error.McpInvalidServerName;
    return .{ .local = .{
        .name = tokens[0],
        .command = tokens[1],
        .args = tokens[2..],
    } };
}

pub fn isValidServerName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-') continue;
        return false;
    }
    return true;
}

pub const AuthenticationStart = enum {
    started,
    busy,
};

pub const ListServersFn = *const fn (ctx: *anyopaque, alloc: Allocator) anyerror![]u8;
pub const SummarizeServersFn = *const fn (ctx: *anyopaque, alloc: Allocator) anyerror![]u8;
pub const AuthenticateServerFn = *const fn (
    ctx: *anyopaque,
    name: []const u8,
) anyerror!AuthenticationStart;
pub const ValidateAuthenticationServerFn = *const fn (
    ctx: *anyopaque,
    name: []const u8,
) anyerror!void;

pub const LogoutResult = struct {
    busy: bool = false,
    removed: bool = false,
    revocation_failed: bool = false,
    repaired_entries: usize = 0,
    local_only: bool = false,
};

pub const LogoutServerFn = *const fn (
    ctx: *anyopaque,
    name: []const u8,
) anyerror!LogoutResult;

pub const ListResourcesFn = *const fn (
    ctx: *anyopaque,
    alloc: Allocator,
    server_name: []const u8,
    include_templates: bool,
) anyerror![]u8;
pub const ReadResourceFn = *const fn (
    ctx: *anyopaque,
    alloc: Allocator,
    server_name: []const u8,
    uri: []const u8,
) anyerror![]u8;
pub const ListPromptsFn = *const fn (
    ctx: *anyopaque,
    alloc: Allocator,
    server_name: []const u8,
) anyerror![]u8;
pub const GetPromptFn = *const fn (
    ctx: *anyopaque,
    alloc: Allocator,
    server_name: []const u8,
    prompt_name: []const u8,
    arguments_json: []const u8,
) anyerror![]u8;
pub const CompletePromptFn = *const fn (
    ctx: *anyopaque,
    alloc: Allocator,
    server_name: []const u8,
    prompt_name: []const u8,
    argument_name: []const u8,
    value: []const u8,
) anyerror![]u8;
pub const CompleteResourceFn = *const fn (
    ctx: *anyopaque,
    alloc: Allocator,
    server_name: []const u8,
    uri_template: []const u8,
    variable_name: []const u8,
    value: []const u8,
) anyerror![]u8;

pub const Request = struct {
    home: ?[]const u8,
    list_ctx: *anyopaque,
    summarize_servers: ?SummarizeServersFn = null,
    list_servers_and_tools: ListServersFn,
    auth_ctx: ?*anyopaque = null,
    validate_authentication_server: ?ValidateAuthenticationServerFn = null,
    authenticate_server: ?AuthenticateServerFn = null,
    logout_server: ?LogoutServerFn = null,
    feature_ctx: ?*anyopaque = null,
    list_resources: ?ListResourcesFn = null,
    read_resource: ?ReadResourceFn = null,
    list_prompts: ?ListPromptsFn = null,
    get_prompt: ?GetPromptFn = null,
    complete_prompt: ?CompletePromptFn = null,
    complete_resource: ?CompleteResourceFn = null,
};

pub const Display = union(enum) {
    block: []u8,
    line: []u8,
};

/// Owns the selected display text. `deinit` releases it with the allocator
/// supplied to the provider.
pub const Result = struct {
    display: Display,
    reload: bool = false,
    report_reload: bool = false,
    project_action: ?project_config.ProjectMcpAction = null,

    pub fn deinit(self: Result, alloc: Allocator) void {
        switch (self.display) {
            .block => |text| alloc.free(text),
            .line => |text| alloc.free(text),
        }
    }
};

pub const HandleFn = *const fn (alloc: Allocator, rest: []const u8, request: Request) anyerror!Result;

pub const Provider = struct {
    handle_fn: HandleFn,

    pub fn handle(self: Provider, alloc: Allocator, rest: []const u8, request: Request) !Result {
        return self.handle_fn(alloc, rest, request);
    }
};

test "MCP command provider delegates requests and returns owned display text" {
    const Fixture = struct {
        fn list(_: *anyopaque, alloc: Allocator) ![]u8 {
            return alloc.dupe(u8, "servers\n");
        }

        fn handle(alloc: Allocator, rest: []const u8, request: Request) !Result {
            try std.testing.expectEqualStrings("list", rest);
            return .{
                .display = .{
                    .block = try request.list_servers_and_tools(request.list_ctx, alloc),
                },
            };
        }
    };

    var list_context: u8 = 0;
    const provider = Provider{ .handle_fn = Fixture.handle };
    const result = try provider.handle(std.testing.allocator, "list", .{
        .home = null,
        .list_ctx = @ptrCast(&list_context),
        .list_servers_and_tools = Fixture.list,
    });
    defer result.deinit(std.testing.allocator);

    switch (result.display) {
        .block => |text| try std.testing.expectEqualStrings("servers\n", text),
        .line => return error.TestExpectedEqual,
    }
    try std.testing.expect(!result.reload);
}

test "MCP add intent parses local and HTTP argv without allocation" {
    const local = try parseAddIntent(&.{ "fixture", "node", "server.js", "--stdio" });
    switch (local) {
        .local => |intent| {
            try std.testing.expectEqualStrings("fixture", intent.name);
            try std.testing.expectEqualStrings("node", intent.command);
            try std.testing.expectEqualSlices([]const u8, &.{ "server.js", "--stdio" }, intent.args);
        },
        .http => return error.TestUnexpectedResult,
    }

    const remote = try parseAddIntent(&.{ "--transport", "http", "docs", "https://example.test/mcp" });
    switch (remote) {
        .local => return error.TestUnexpectedResult,
        .http => |intent| {
            try std.testing.expectEqualStrings("docs", intent.name);
            try std.testing.expectEqualStrings("https://example.test/mcp", intent.url);
        },
    }
}

test "MCP add intent rejects invalid syntax names and URLs" {
    try std.testing.expectError(error.McpAddUsage, parseAddIntent(&.{}));
    try std.testing.expectError(error.McpAddUsage, parseAddIntent(&.{"only-name"}));
    try std.testing.expectError(
        error.McpAddUsage,
        parseAddIntent(&.{ "--transport", "sse", "docs", "https://example.test/mcp" }),
    );
    try std.testing.expectError(
        error.McpInvalidServerName,
        parseAddIntent(&.{ "bad/name", "node" }),
    );
    try std.testing.expectError(
        error.McpConfigInvalidUrl,
        parseAddIntent(&.{ "--transport", "http", "docs", "file:///tmp/socket" }),
    );
}
