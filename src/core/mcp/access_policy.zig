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
