const std = @import("std");
const mcp_contract = @import("mcp_contract.zig");
const project_config = @import("project_config.zig");
const streamable_http = @import("streamable_http.zig");
const cli_flags = @import("../cli/cli_flags.zig");
const builtin_commands = @import("../../builtins/commands.zig");

const Allocator = std.mem.Allocator;

pub const AddIntent = union(enum) {
    slack,
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

/// Reads the arguments of `fx mcp add` and `/mcp add`: `slack`,
/// `NAME COMMAND [ARGS...]`, or `--transport http NAME URL`. Flags go before
/// the name, through the shared parser; the words after a command belong to
/// it, flags included.
pub fn parseAddIntent(args: []const [:0]const u8) AddIntentError!AddIntent {
    var parser: cli_flags.Parser = .initPrefix(&builtin_commands.mcp_transport_options, args);
    var http = false;
    while (parser.next() catch return error.McpAddUsage) |item| {
        // http is the one transport --transport names.
        if (!std.mem.eql(u8, item.option.value.?, "http")) return error.McpAddUsage;
        http = true;
    }
    const words = args[parser.index..];
    if (http) {
        if (words.len != 2) return error.McpAddUsage;
        return httpIntent(words[0], words[1]);
    }
    if (words.len == 1 and std.mem.eql(u8, words[0], "slack")) return .slack;
    if (words.len < 2) return error.McpAddUsage;
    return localIntent(words[0], words[1], @ptrCast(words[2..]));
}

/// A remote server named `name` at `url`.
pub fn httpIntent(name: []const u8, url: []const u8) AddIntentError!AddIntent {
    if (!isValidServerName(name)) return error.McpInvalidServerName;
    streamable_http.validateEndpoint(url) catch return error.McpConfigInvalidUrl;
    return .{ .http = .{ .name = name, .url = url } };
}

/// A server named `name` that fx starts as `command args...`.
pub fn localIntent(name: []const u8, command: []const u8, args: []const []const u8) AddIntentError!AddIntent {
    if (!isValidServerName(name)) return error.McpInvalidServerName;
    return .{ .local = .{ .name = name, .command = command, .args = args } };
}

pub fn isValidServerName(name: []const u8) bool {
    // A leading dash would make a flag, such as a mistyped scope, a name.
    if (name.len == 0 or name[0] == '-') return false;
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
    connect_slack: bool = false,
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
        .http, .slack => return error.TestUnexpectedResult,
    }

    const remote = try parseAddIntent(&.{ "--transport", "http", "docs", "https://example.test/mcp" });
    switch (remote) {
        .local, .slack => return error.TestUnexpectedResult,
        .http => |intent| {
            try std.testing.expectEqualStrings("docs", intent.name);
            try std.testing.expectEqualStrings("https://example.test/mcp", intent.url);
        },
    }
}

test "MCP add intent rejects invalid syntax names and URLs" {
    try std.testing.expect(try parseAddIntent(&.{"slack"}) == .slack);
    try std.testing.expect(try parseAddIntent(&.{ "slack", "node" }) == .local);
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
