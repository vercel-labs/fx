const std = @import("std");

pub const Context = struct {
    allocator: std.mem.Allocator,
    app: *anyopaque,
};

pub const Handler = *const fn (Context, []const u8) anyerror!void;

pub const Command = struct {
    name: []const u8,
    description: []const u8,
    handler: Handler,
    accepts_payload: bool = true,
};

pub const Registry = struct {
    commands: []const Command = &.{},

    pub const Match = struct {
        command: *const Command,
        payload: []const u8,
    };

    pub fn match(self: Registry, input: []const u8) ?Match {
        const trimmed = std.mem.trim(u8, input, " \t\r\n");
        if (trimmed.len < 2 or trimmed[0] != '/') return null;

        const token_end = std.mem.indexOfAny(u8, trimmed, " \t\r\n") orelse trimmed.len;
        const token = trimmed[1..token_end];
        const payload = std.mem.trim(u8, trimmed[token_end..], " \t\r\n");

        for (self.commands) |*command| {
            if (!std.mem.eql(u8, command.name, token)) continue;
            if (!command.accepts_payload and payload.len != 0) return null;
            return .{ .command = command, .payload = payload };
        }
        return null;
    }

    pub fn dispatch(self: Registry, context: Context, input: []const u8) !bool {
        const matched = self.match(input) orelse return false;
        try matched.command.handler(context, matched.payload);
        return true;
    }
};

fn fixtureHandler(_: Context, payload: []const u8) !void {
    try std.testing.expectEqualStrings("production", payload);
}

test "native command registry matches and dispatches open slash commands" {
    const commands = [_]Command{.{
        .name = "deploy",
        .description = "Deploy a workspace",
        .handler = fixtureHandler,
    }};
    const registry = Registry{ .commands = &commands };
    const matched = registry.match("/deploy production") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("deploy", matched.command.name);
    try std.testing.expectEqualStrings("production", matched.payload);
    var marker: u8 = 0;
    try std.testing.expect(try registry.dispatch(.{
        .allocator = std.testing.allocator,
        .app = @ptrCast(&marker),
    }, "/deploy production"));
    try std.testing.expect(!try registry.dispatch(.{
        .allocator = std.testing.allocator,
        .app = @ptrCast(&marker),
    }, "/missing"));
}
