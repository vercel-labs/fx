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

/// Stable witness for only the authority that can affect MCP access. Child
/// lifecycle revisions are deliberately excluded; ownership, permission-
/// filtered visibility, and every runtime/catalog/auth identity are included.
pub fn authorityGeneration(view: View) u64 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.mcp.access-authority.v1\x00");
    hashU64(&hash, view.runtime_generation);
    hashString(&hash, view.owner_id);
    hashString(&hash, view.parent_id);
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

test "MCP authority generation changes with every captured identity" {
    const alloc = std.testing.allocator;
    var captured = View{
        .runtime_generation = 7,
        .owner_id = try alloc.dupe(u8, "session"),
        .parent_id = try alloc.dupe(u8, "parent"),
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
    const base = authorityGeneration(captured);
    try std.testing.expectEqual(base, authorityGeneration(live));

    live.owner_id[0] = 'x';
    try std.testing.expect(authorityGeneration(live) != base);
    live.owner_id[0] = 's';
    live.parent_id[0] = 'x';
    try std.testing.expect(authorityGeneration(live) != base);
    live.parent_id[0] = 'p';
    live.runtime_generation += 1;
    try std.testing.expect(authorityGeneration(live) != base);
    live.runtime_generation -= 1;
    live.servers[0].source = .acp;
    try std.testing.expect(authorityGeneration(live) != base);
    live.servers[0].source = .profile;
    live.servers[0].scope = .acp_session;
    try std.testing.expect(authorityGeneration(live) != base);
    live.servers[0].scope = .profile;
    live.servers[0].connection_generation += 1;
    try std.testing.expect(authorityGeneration(live) != base);
    live.servers[0].connection_generation -= 1;
    live.servers[0].catalog_generation += 1;
    try std.testing.expect(authorityGeneration(live) != base);
    live.servers[0].catalog_generation -= 1;
    live.servers[0].auth_generation += 1;
    try std.testing.expect(authorityGeneration(live) != base);
    live.servers[0].auth_generation -= 1;
    live.tools[0].name[0] = 'x';
    try std.testing.expect(authorityGeneration(live) != base);
    live.tools[0].name[0] = 'd';
    try std.testing.expectEqual(base, authorityGeneration(live));
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
