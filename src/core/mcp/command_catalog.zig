const std = @import("std");
const command_specs = @import("../slash_commands/command_specs.zig");

const Allocator = std.mem.Allocator;

pub const Kind = enum {
    list,
    resource,
    prompt,
    add,
    remove,
    path,
    reload,
    auth,
    logout,
};

pub const Spec = struct {
    kind: Kind,
    token: []const u8,
    slash: command_specs.SlashSpec,
};

pub const specs = [_]Spec{
    .{
        .kind = .list,
        .token = "list",
        .slash = .{
            .kind = .mcp,
            .command = "/mcp list",
            .help_entry = "/mcp list",
            .completion_description = "list configured servers, tools, and connection status",
            .presentation_category = .extensions,
            .dispatchable = false,
            .completion_parent = "/mcp",
        },
    },
    .{
        .kind = .resource,
        .token = "resource",
        .slash = .{
            .kind = .mcp,
            .command = "/mcp resource",
            .help_entry = "/mcp resource [list|templates|read|complete] ...",
            .completion_description = "list, read, and complete MCP resources",
            .presentation_category = .extensions,
            .has_args = true,
            .dispatchable = false,
            .completion_parent = "/mcp",
        },
    },
    .{
        .kind = .prompt,
        .token = "prompt",
        .slash = .{
            .kind = .mcp,
            .command = "/mcp prompt",
            .help_entry = "/mcp prompt [list|get|complete] ...",
            .completion_description = "list, invoke, and complete MCP prompts",
            .presentation_category = .extensions,
            .has_args = true,
            .dispatchable = false,
            .completion_parent = "/mcp",
        },
    },
    .{
        .kind = .add,
        .token = "add",
        .slash = .{
            .kind = .mcp,
            .command = "/mcp add",
            .help_entry = "/mcp add <name> <command> [args...]",
            .completion_description = "add or replace a local MCP server",
            .presentation_category = .extensions,
            .has_args = true,
            .dispatchable = false,
            .completion_parent = "/mcp",
        },
    },
    .{
        .kind = .remove,
        .token = "remove",
        .slash = .{
            .kind = .mcp,
            .command = "/mcp remove",
            .help_entry = "/mcp remove <name>",
            .completion_description = "remove a local MCP server",
            .presentation_category = .extensions,
            .has_args = true,
            .dispatchable = false,
            .completion_parent = "/mcp",
        },
    },
    .{
        .kind = .path,
        .token = "path",
        .slash = .{
            .kind = .mcp,
            .command = "/mcp path",
            .help_entry = "/mcp path",
            .completion_description = "show the MCP configuration path",
            .presentation_category = .extensions,
            .dispatchable = false,
            .completion_parent = "/mcp",
        },
    },
    .{
        .kind = .reload,
        .token = "reload",
        .slash = .{
            .kind = .mcp,
            .command = "/mcp reload",
            .help_entry = "/mcp reload",
            .completion_description = "reload trusted MCP configuration",
            .presentation_category = .extensions,
            .dispatchable = false,
            .completion_parent = "/mcp",
        },
    },
    .{
        .kind = .auth,
        .token = "auth",
        .slash = .{
            .kind = .mcp,
            .command = "/mcp auth",
            .help_entry = "/mcp auth <name> [--open]",
            .completion_description = "authenticate an MCP server in the browser",
            .presentation_category = .extensions,
            .has_args = true,
            .dispatchable = false,
            .completion_parent = "/mcp",
        },
    },
    .{
        .kind = .logout,
        .token = "logout",
        .slash = .{
            .kind = .mcp,
            .command = "/mcp logout",
            .help_entry = "/mcp logout <name>",
            .completion_description = "remove stored credentials for an MCP server",
            .presentation_category = .extensions,
            .has_args = true,
            .dispatchable = false,
            .completion_parent = "/mcp",
        },
    },
};

pub const slash_specs = blk: {
    var entries: [specs.len]command_specs.SlashSpec = undefined;
    for (specs, 0..) |spec, idx| entries[idx] = spec.slash;
    break :blk entries;
};

pub const Parsed = struct {
    kind: Kind,
    args: []const u8,
};

pub fn parse(input: []const u8) ?Parsed {
    const trimmed = std.mem.trim(u8, input, " \t");
    if (trimmed.len == 0) return null;

    const token_end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
    const token = trimmed[0..token_end];
    const args = std.mem.trim(u8, trimmed[token_end..], " \t");
    for (specs) |spec| {
        if (std.mem.eql(u8, token, spec.token)) {
            return .{ .kind = spec.kind, .args = args };
        }
    }
    return null;
}

pub fn renderUsage(alloc: Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("Usage: /mcp [");
    for (specs, 0..) |spec, idx| {
        if (idx > 0) try out.writer.writeByte('|');
        try out.writer.writeAll(spec.token);
    }
    try out.writer.writeByte(']');
    return try out.toOwnedSlice();
}

test "MCP command catalog keeps parser and slash discovery aligned" {
    for (specs, 0..) |spec, idx| {
        const parsed = parse(spec.slash.command["/mcp ".len..]) orelse return error.TestExpectedEqual;
        try std.testing.expectEqual(spec.kind, parsed.kind);
        try std.testing.expectEqualStrings("", parsed.args);
        try std.testing.expectEqualStrings(spec.slash.command, slash_specs[idx].command);
        try std.testing.expect(!spec.slash.dispatchable);
        try std.testing.expect(spec.slash.help_entry != null);
        try std.testing.expect(spec.slash.completion_description != null);
    }

    const auth = parse("  auth server-a --open  ") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(Kind.auth, auth.kind);
    try std.testing.expectEqualStrings("server-a --open", auth.args);
    try std.testing.expect(parse("unknown") == null);
}

test "MCP command usage derives from the supported catalog" {
    const usage = try renderUsage(std.testing.allocator);
    defer std.testing.allocator.free(usage);
    try std.testing.expectEqualStrings(
        "Usage: /mcp [list|resource|prompt|add|remove|path|reload|auth|logout]",
        usage,
    );
}
