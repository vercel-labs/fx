const std = @import("std");

const Allocator = std.mem.Allocator;

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
