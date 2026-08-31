const std = @import("std");
const builtin_mcp = @import("../../builtins/mcp.zig");
const config_runtime = @import("../config/config_runtime.zig");
const mcp_command_provider = @import("../mcp/command_provider.zig");
const mcp_menu_state = @import("../mcp/menu_state.zig");
const project_config = @import("../mcp/project_config.zig");

pub fn Runtime(comptime App: type) type {
    return struct {
        pub fn saveAdd(
            app: *App,
            generation: u64,
            transport: mcp_menu_state.AddTransport,
        ) !void {
            const form = app.mcp.menuView().add_form;
            var tokens: std.ArrayList([]const u8) = .empty;
            defer tokens.deinit(app.alloc);
            switch (transport) {
                .local => {
                    try tokens.appendSlice(app.alloc, &.{ form.name.items, form.target.items });
                    var arguments = std.mem.tokenizeAny(u8, form.arguments.items, " \t");
                    while (arguments.next()) |argument| try tokens.append(app.alloc, argument);
                },
                .http => try tokens.appendSlice(
                    app.alloc,
                    &.{ "--transport", "http", form.name.items, form.target.items },
                ),
            }
            const intent = try mcp_command_provider.parseAddIntent(tokens.items);
            var result = try builtin_mcp.addProfileServer(app.alloc, intent);
            defer result.deinit(app.alloc);
            try app.mcp.setMenuFeedback(app.alloc, "Saved MCP server; reconnecting…");
            app.mcp.returnMenuToServers();
            app.beginMcpMenuReload(generation) catch |err| {
                try app.mcp.recordMenuEffectFailure(app.alloc, generation, err);
            };
        }

        pub fn removeServer(app: *App, generation: u64) !void {
            const server_name = app.mcp.selectedMenuServerName() orelse
                return error.McpServerNotFound;
            var result = try builtin_mcp.removeProfileServer(app.alloc, server_name);
            defer result.deinit(app.alloc);
            if (!result.removed) return error.McpProfileServerNotFound;
            try app.mcp.setMenuFeedback(app.alloc, "Removed MCP server; reconnecting…");
            app.mcp.returnMenuToServers();
            app.beginMcpMenuReload(generation) catch |err| {
                try app.mcp.recordMenuEffectFailure(app.alloc, generation, err);
            };
        }

        pub fn applyTrustAction(
            app: *App,
            generation: u64,
            action: mcp_menu_state.Action,
        ) !void {
            const project_action: project_config.ProjectMcpAction = switch (action) {
                .trust_approve => .{
                    .approve = app.mcp.selectedMenuServerName() orelse return error.McpServerNotFound,
                },
                .trust_reject => .{
                    .reject = app.mcp.selectedMenuServerName() orelse return error.McpServerNotFound,
                },
                .trust_approve_all => .approve_all,
                .trust_reset => .reset,
                else => return error.McpMenuInvalidOperation,
            };
            var attempt = config_runtime.attemptProjectMcpMutation(
                app.alloc,
                app.workspace_root,
                project_action,
            );
            defer attempt.deinit(app.alloc);
            const outcome = switch (attempt) {
                .outcome => |value| value,
                .failure => |failure| {
                    if (try handleIndeterminateTrustFailure(
                        app,
                        generation,
                        action,
                        failure.err,
                    )) return;
                    return failure.err;
                },
            };
            try app.mcp.setMenuFeedback(app.alloc, "Updated project MCP trust; reconnecting…");
            app.mcp.returnMenuToServers();
            switch (outcome) {
                .unchanged => {
                    _ = mcp_menu_state.apply(
                        &app.mcp.menu,
                        .{ .action_succeeded = generation },
                    );
                },
                .committed => |committed| if (committed.authority_reduced)
                    app.beginMcpMenuAuthorityReduction(true, generation) catch |err| {
                        try app.mcp.recordMenuEffectFailure(app.alloc, generation, err);
                    }
                else
                    app.beginMcpMenuReload(generation) catch |err| {
                        try app.mcp.recordMenuEffectFailure(app.alloc, generation, err);
                    },
            }
        }
    };
}

fn actionReducesAuthority(action: mcp_menu_state.Action) bool {
    return action == .trust_reject or action == .trust_reset;
}

fn handleIndeterminateTrustFailure(
    app: anytype,
    generation: u64,
    action: mcp_menu_state.Action,
    err: anyerror,
) !bool {
    if (err != error.SettingsCommitIndeterminate or !actionReducesAuthority(action)) return false;
    try app.mcp.setMenuFeedback(
        app.alloc,
        "Project MCP choices may have been saved; live MCP authority was retired.",
    );
    app.mcp.returnMenuToServers();
    app.beginMcpMenuAuthorityReduction(false, generation) catch |reduction_err| {
        try app.mcp.recordMenuEffectFailure(app.alloc, generation, reduction_err);
    };
    return true;
}

test "only rejecting or resetting project MCP trust reduces authority" {
    try std.testing.expect(actionReducesAuthority(.trust_reject));
    try std.testing.expect(actionReducesAuthority(.trust_reset));
    try std.testing.expect(!actionReducesAuthority(.trust_approve));
    try std.testing.expect(!actionReducesAuthority(.trust_approve_all));
}

test "indeterminate trust rejection retires authority without rebuilding" {
    const FakeMcp = struct {
        feedback_set: bool = false,
        returned_to_servers: bool = false,

        fn setMenuFeedback(self: *@This(), _: std.mem.Allocator, text: []const u8) !void {
            try std.testing.expectEqualStrings(
                "Project MCP choices may have been saved; live MCP authority was retired.",
                text,
            );
            self.feedback_set = true;
        }

        fn returnMenuToServers(self: *@This()) void {
            self.returned_to_servers = true;
        }

        fn recordMenuEffectFailure(_: *@This(), _: std.mem.Allocator, _: u64, _: anyerror) !void {
            return error.TestUnexpectedFailure;
        }
    };
    const FakeApp = struct {
        alloc: std.mem.Allocator,
        mcp: FakeMcp = .{},
        reduction_started: bool = false,

        fn beginMcpMenuAuthorityReduction(self: *@This(), rebuild: bool, generation: u64) !void {
            try std.testing.expect(!rebuild);
            try std.testing.expectEqual(@as(u64, 41), generation);
            self.reduction_started = true;
        }
    };
    var app = FakeApp{ .alloc = std.testing.allocator };
    try std.testing.expect(try handleIndeterminateTrustFailure(
        &app,
        41,
        .trust_reject,
        error.SettingsCommitIndeterminate,
    ));
    try std.testing.expect(app.mcp.feedback_set);
    try std.testing.expect(app.mcp.returned_to_servers);
    try std.testing.expect(app.reduction_started);
}
