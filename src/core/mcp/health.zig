//! A configured MCP server's config, as `fx status` and `fx doctor` inspect it.

const std = @import("std");
const mcp_contract = @import("mcp_contract.zig");

const Allocator = std.mem.Allocator;

pub const ConfigurationIssue = struct {
    message: []u8,

    pub fn deinit(self: *ConfigurationIssue, alloc: Allocator) void {
        alloc.free(self.message);
        self.* = undefined;
    }
};

pub const ConfiguredServerSnapshot = struct {
    configured_name: []u8,
    source: mcp_contract.ConfigSource,
    scope: mcp_contract.ConfigScope,
    workspace_admission: ?mcp_contract.WorkspaceAdmission = null,
    required: bool,
    transport: mcp_contract.McpTransport,

    pub fn deinit(self: *ConfiguredServerSnapshot, alloc: Allocator) void {
        alloc.free(self.configured_name);
        self.* = undefined;
    }
};

pub const LocalConfigSnapshot = struct {
    servers: []ConfiguredServerSnapshot,
    configuration_issues: []ConfigurationIssue,

    pub fn deinit(self: *LocalConfigSnapshot, alloc: Allocator) void {
        for (self.servers) |*server| server.deinit(alloc);
        alloc.free(self.servers);
        for (self.configuration_issues) |*issue| issue.deinit(alloc);
        alloc.free(self.configuration_issues);
        self.* = undefined;
    }
};

pub const LocalConfigInspection = struct {
    profile_diagnostic: mcp_contract.ProfileConfigDiagnostic = .clear,
    snapshot: LocalConfigSnapshot,
    inspection_error: ?[]const u8 = null,

    pub fn deinit(self: *LocalConfigInspection, alloc: Allocator) void {
        self.snapshot.deinit(alloc);
        self.* = undefined;
    }
};

pub const InspectLocalConfigFn = *const fn (
    Allocator,
    []const u8,
) error{OutOfMemory}!LocalConfigInspection;

pub fn inspectLocalConfigUnavailable(
    alloc: Allocator,
    _: []const u8,
) error{OutOfMemory}!LocalConfigInspection {
    const servers = try alloc.alloc(ConfiguredServerSnapshot, 0);
    errdefer alloc.free(servers);
    return .{ .snapshot = .{
        .servers = servers,
        .configuration_issues = try alloc.alloc(ConfigurationIssue, 0),
    } };
}
