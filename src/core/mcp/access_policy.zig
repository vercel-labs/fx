const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");
const mcp_contract = @import("mcp_contract.zig");

const Allocator = std.mem.Allocator;

pub const ToolIdentity = struct {
    name: []u8,
    server_name: []u8,

    pub fn deinit(self: *ToolIdentity, alloc: Allocator) void {
        alloc.free(self.name);
        alloc.free(self.server_name);
        self.* = undefined;
    }

    fn clone(self: ToolIdentity, alloc: Allocator) !ToolIdentity {
        const name = try alloc.dupe(u8, self.name);
        errdefer alloc.free(name);
        return .{
            .name = name,
            .server_name = try alloc.dupe(u8, self.server_name),
        };
    }
};

pub const ServerIdentity = struct {
    name: []u8,
    source: mcp_contract.ConfigSource,
    scope: mcp_contract.ConfigScope,
    connection_generation: u64,
    catalog_generation: u64,
    auth_generation: u64,

    pub fn deinit(self: *ServerIdentity, alloc: Allocator) void {
        alloc.free(self.name);
        self.* = undefined;
    }

    fn clone(self: ServerIdentity, alloc: Allocator) !ServerIdentity {
        return .{
            .name = try alloc.dupe(u8, self.name),
            .source = self.source,
            .scope = self.scope,
            .connection_generation = self.connection_generation,
            .catalog_generation = self.catalog_generation,
            .auth_generation = self.auth_generation,
        };
    }
};

/// Immutable product authority for one MCP consumer. It contains identities,
/// never clients, transports, credentials, or mutable catalogs.
pub const View = struct {
    runtime_generation: u64,
    owner_id: []u8,
    parent_id: []u8,
    features_visible: bool,
    servers: []ServerIdentity,
    tools: []ToolIdentity,

    pub fn deinit(self: *View, alloc: Allocator) void {
        alloc.free(self.owner_id);
        alloc.free(self.parent_id);
        for (self.servers) |*item| item.deinit(alloc);
        alloc.free(self.servers);
        for (self.tools) |*item| item.deinit(alloc);
        alloc.free(self.tools);
        self.* = undefined;
    }

    pub fn clone(self: View, alloc: Allocator) !View {
        const owner_id = try alloc.dupe(u8, self.owner_id);
        errdefer alloc.free(owner_id);
        const parent_id = try alloc.dupe(u8, self.parent_id);
        errdefer alloc.free(parent_id);
        const servers = try alloc.alloc(ServerIdentity, self.servers.len);
        var server_count: usize = 0;
        errdefer {
            for (servers[0..server_count]) |*item| item.deinit(alloc);
            alloc.free(servers);
        }
        for (self.servers, 0..) |item, index| {
            servers[index] = try item.clone(alloc);
            server_count += 1;
        }
        const tools = try alloc.alloc(ToolIdentity, self.tools.len);
        var tool_count: usize = 0;
        errdefer {
            for (tools[0..tool_count]) |*item| item.deinit(alloc);
            alloc.free(tools);
        }
        for (self.tools, 0..) |item, index| {
            tools[index] = try item.clone(alloc);
            tool_count += 1;
        }
        return .{
            .runtime_generation = self.runtime_generation,
            .owner_id = owner_id,
            .parent_id = parent_id,
            .features_visible = self.features_visible,
            .servers = servers,
            .tools = tools,
        };
    }

    pub fn server(self: View, name: []const u8) ?ServerIdentity {
        for (self.servers) |candidate| {
            if (std.mem.eql(u8, candidate.name, name)) return candidate;
        }
        return null;
    }

    pub fn tool(self: View, name: []const u8) ?ToolIdentity {
        for (self.tools) |candidate| {
            if (std.mem.eql(u8, candidate.name, name)) return candidate;
        }
        return null;
    }
};

pub const Target = union(enum) {
    tool: []const u8,
    tool_server: []const u8,
    feature_server: []const u8,
};

pub const Decision = enum {
    allow,
    reject_owner,
    reject_runtime_generation,
    reject_server,
    reject_server_generation,
    reject_tool,
    reject_features,
};

/// Stable witness for only the authority that can affect MCP access. Child
/// lifecycle revisions are deliberately excluded; ownership, permission-
/// filtered visibility, and every runtime/catalog/auth identity are included.
pub fn authorityGeneration(view: View) u64 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.mcp.access-authority.v1\x00");
    hashU64(&hash, view.runtime_generation);
    hashString(&hash, view.owner_id);
    hashString(&hash, view.parent_id);
    hashU64(&hash, @intFromBool(view.features_visible));
    for (view.servers) |server_identity| {
        hashString(&hash, server_identity.name);
        hashU64(&hash, @backingInt(server_identity.source));
        hashU64(&hash, @backingInt(server_identity.scope));
        hashU64(&hash, server_identity.connection_generation);
        hashU64(&hash, server_identity.catalog_generation);
        hashU64(&hash, server_identity.auth_generation);
    }
    for (view.tools) |tool_identity| {
        hashString(&hash, tool_identity.name);
        hashString(&hash, tool_identity.server_name);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const value = std.mem.readInt(u64, digest[0..8], .little);
    return if (value == 0) 1 else value;
}

fn hashString(hash: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    hashU64(hash, value.len);
    hash.update(value);
}

fn hashU64(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

pub fn authorize(captured: View, live: View, target: Target) Decision {
    if (!std.mem.eql(u8, captured.owner_id, live.owner_id) or
        !std.mem.eql(u8, captured.parent_id, live.parent_id))
    {
        return .reject_owner;
    }
    if (captured.runtime_generation == 0 or
        captured.runtime_generation != live.runtime_generation)
    {
        return .reject_runtime_generation;
    }
    const server_name = switch (target) {
        .tool => |name| (captured.tool(name) orelse return .reject_tool).server_name,
        .tool_server => |name| name,
        .feature_server => |name| blk: {
            if (!captured.features_visible or !live.features_visible) {
                return .reject_features;
            }
            break :blk name;
        },
    };
    const captured_server = captured.server(server_name) orelse return .reject_server;
    const live_server = live.server(server_name) orelse return .reject_server;
    if (captured_server.source != live_server.source or
        captured_server.scope != live_server.scope)
    {
        return .reject_server;
    }
    if (captured_server.connection_generation != live_server.connection_generation or
        captured_server.catalog_generation != live_server.catalog_generation or
        captured_server.auth_generation != live_server.auth_generation)
    {
        return .reject_server_generation;
    }
    switch (target) {
        .tool => |name| {
            const live_tool = live.tool(name) orelse return .reject_tool;
            if (!std.mem.eql(u8, live_tool.server_name, server_name)) return .reject_tool;
        },
        .tool_server => {
            for (captured.tools) |tool_identity| {
                if (!std.mem.eql(u8, tool_identity.server_name, server_name)) continue;
                const live_tool = live.tool(tool_identity.name) orelse continue;
                if (std.mem.eql(u8, live_tool.server_name, server_name)) return .allow;
            }
            return .reject_tool;
        },
        .feature_server => {},
    }
    return .allow;
}

test "MCP view authorization intersects immutable and live authority" {
    const alloc = std.testing.allocator;
    var captured = View{
        .runtime_generation = 7,
        .owner_id = try alloc.dupe(u8, "session"),
        .parent_id = try alloc.dupe(u8, "parent"),
        .features_visible = true,
        .servers = try alloc.alloc(ServerIdentity, 1),
        .tools = try alloc.alloc(ToolIdentity, 1),
    };
    captured.servers[0] = .{
        .name = try alloc.dupe(u8, "docs"),
        .source = .profile,
        .scope = .profile,
        .connection_generation = 2,
        .catalog_generation = 3,
        .auth_generation = 4,
    };
    captured.tools[0] = .{
        .name = try alloc.dupe(u8, "docs_search"),
        .server_name = try alloc.dupe(u8, "docs"),
    };
    defer captured.deinit(alloc);
    var live = try captured.clone(alloc);
    defer live.deinit(alloc);

    try std.testing.expectEqual(authorityGeneration(captured), authorityGeneration(live));
    try std.testing.expectEqual(Decision.allow, authorize(captured, live, .{ .tool = "docs_search" }));
    try std.testing.expectEqual(Decision.allow, authorize(captured, live, .{ .tool_server = "docs" }));
    try std.testing.expectEqual(Decision.reject_tool, authorize(captured, live, .{ .tool = "other" }));

    live.owner_id[0] = 'x';
    try std.testing.expectEqual(Decision.reject_owner, authorize(captured, live, .{ .tool = "docs_search" }));
    live.owner_id[0] = 's';
    live.parent_id[0] = 'x';
    try std.testing.expectEqual(Decision.reject_owner, authorize(captured, live, .{ .tool = "docs_search" }));
    live.parent_id[0] = 'p';
    live.runtime_generation += 1;
    try std.testing.expectEqual(Decision.reject_runtime_generation, authorize(captured, live, .{ .tool = "docs_search" }));
    live.runtime_generation -= 1;
    live.features_visible = false;
    try std.testing.expectEqual(Decision.reject_features, authorize(captured, live, .{ .feature_server = "docs" }));
    live.features_visible = true;
    live.servers[0].source = .acp;
    try std.testing.expectEqual(Decision.reject_server, authorize(captured, live, .{ .feature_server = "docs" }));
    live.servers[0].source = .profile;
    live.servers[0].scope = .acp_session;
    try std.testing.expectEqual(Decision.reject_server, authorize(captured, live, .{ .feature_server = "docs" }));
    live.servers[0].scope = .profile;
    live.servers[0].connection_generation += 1;
    try std.testing.expectEqual(Decision.reject_server_generation, authorize(captured, live, .{ .tool = "docs_search" }));
    live.servers[0].connection_generation -= 1;
    live.servers[0].catalog_generation += 1;
    try std.testing.expectEqual(Decision.reject_server_generation, authorize(captured, live, .{ .tool = "docs_search" }));
    live.servers[0].catalog_generation -= 1;
    live.servers[0].auth_generation += 1;
    try std.testing.expect(authorityGeneration(captured) != authorityGeneration(live));
    try std.testing.expectEqual(Decision.reject_server_generation, authorize(captured, live, .{ .feature_server = "docs" }));
    live.servers[0].auth_generation -= 1;
    live.tools[0].name[0] = 'x';
    try std.testing.expectEqual(Decision.reject_tool, authorize(captured, live, .{ .tool = "docs_search" }));
}

test "MCP view clone cleans up every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        testing_allocator.no_resize,
        checkViewCloneAllocationFailures,
        .{},
    );
}

fn checkViewCloneAllocationFailures(alloc: Allocator) !void {
    var source = View{
        .runtime_generation = 7,
        .owner_id = try std.testing.allocator.dupe(u8, "child"),
        .parent_id = try std.testing.allocator.dupe(u8, "parent"),
        .features_visible = true,
        .servers = try std.testing.allocator.alloc(ServerIdentity, 1),
        .tools = try std.testing.allocator.alloc(ToolIdentity, 1),
    };
    source.servers[0] = .{
        .name = try std.testing.allocator.dupe(u8, "server"),
        .source = .profile,
        .scope = .profile,
        .connection_generation = 1,
        .catalog_generation = 2,
        .auth_generation = 3,
    };
    source.tools[0] = .{
        .name = try std.testing.allocator.dupe(u8, "mcp_server_tool"),
        .server_name = try std.testing.allocator.dupe(u8, "server"),
    };
    defer source.deinit(std.testing.allocator);
    var cloned = try source.clone(alloc);
    defer cloned.deinit(alloc);
}
