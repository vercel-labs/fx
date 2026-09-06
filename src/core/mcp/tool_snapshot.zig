const std = @import("std");
const io_mod = @import("../shared/io.zig");
const mcp_contract = @import("mcp_contract.zig");
const catalog_freshness = @import("catalog_freshness.zig");
const server_auth = @import("server_auth.zig");
const tool_catalog = @import("tool_catalog.zig");
const tool_subscription = @import("tool_subscription.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const controlled_lock = @import("controlled_lock.zig");
const Allocator = std.mem.Allocator;
const McpServer = @import("server_connection.zig").Server;
const catalog_state = @import("catalog_state.zig");
const McpTool = catalog_state.McpTool;
const authorizeLiveAccess = @import("operation_authority.zig").authorizeLiveAccess;
const lockMutexUntil = controlled_lock.mutexUntil;
const lockRwSharedUntil = controlled_lock.rwSharedUntil;
const checkOperationControl = controlled_lock.checkOperation;

pub const Snapshot = struct {
    server_name: []u8,
    original_name: []u8,
    prefixed_name: []u8,
    input_schema_json: []u8,
    output_schema_json: ?[]u8,
    auth_partition: catalog_freshness.AuthPartition,
    connection_generation: u64,
    catalog_generation: u64,
    stdio_generation: ?u64,
    authority_id: u64 = 0,

    pub fn init(
        alloc: Allocator,
        server: *const McpServer,
        tool: *const McpTool,
    ) !Snapshot {
        const metadata = server.tool_catalog.metadata orelse
            return error.McpToolCatalogUnavailable;
        const server_name = try alloc.dupe(u8, server.config.name);
        errdefer alloc.free(server_name);
        const original_name = try alloc.dupe(u8, tool.original_name);
        errdefer alloc.free(original_name);
        const prefixed_name = try alloc.dupe(u8, tool.prefixed_name);
        errdefer alloc.free(prefixed_name);
        const input_schema_json = try alloc.dupe(u8, tool.input_schema_json);
        errdefer alloc.free(input_schema_json);
        const output_schema_json = if (tool.output_schema_json) |schema|
            try alloc.dupe(u8, schema)
        else
            null;
        errdefer if (output_schema_json) |schema| alloc.free(schema);
        return .{
            .server_name = server_name,
            .original_name = original_name,
            .prefixed_name = prefixed_name,
            .input_schema_json = input_schema_json,
            .output_schema_json = output_schema_json,
            .auth_partition = metadata.key,
            .authority_id = server.authority_id.load(.acquire),
            .connection_generation = server.connection_generation,
            .catalog_generation = server.catalog_generation,
            .stdio_generation = if (server.dispatcher) |dispatcher|
                dispatcher.connectionGeneration()
            else
                null,
        };
    }

    pub fn deinit(self: *Snapshot, alloc: Allocator) void {
        alloc.free(self.server_name);
        alloc.free(self.original_name);
        alloc.free(self.prefixed_name);
        alloc.free(self.input_schema_json);
        if (self.output_schema_json) |schema| alloc.free(schema);
        self.* = undefined;
    }
};

pub const CommitGuard = struct {
    alloc: Allocator,
    runtime_generation: u64,
    catalog_mutex: *std.Io.RwLock,
    server: *McpServer,
    snapshot: *const Snapshot,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
    access: tool_mcp_runtime.Access = .unrestricted,
    live_view: ?tool_mcp_runtime.ResolvedLiveView = null,
    subscription: ?*tool_subscription.State = null,
    subscription_locked: bool = false,
    catalog_commit_locked: bool = false,
    auth_locked: bool = false,

    pub fn transport(self: *CommitGuard) mcp_contract.TransportPrecommit {
        return .{
            .context = self,
            .acquire_callback = acquireCallback,
            .release_callback = releaseCallback,
        };
    }

    fn acquireCallback(raw: *anyopaque) !void {
        const self: *CommitGuard = @ptrCast(@alignCast(raw));
        errdefer self.release();
        try checkOperationControl(io_mod.getIo(), self.deadline, self.cancel_flag);
        if (self.server.lifetime.retiring.load(.acquire)) return error.Cancelled;
        self.live_view = try authorizeLiveAccess(
            self.alloc,
            self.access,
            self.runtime_generation,
            .{ .tool = self.snapshot.prefixed_name },
        );

        try lockMutexUntil(
            &self.server.catalog_commit_lock,
            self.deadline,
            self.cancel_flag,
        );
        self.catalog_commit_locked = true;

        if (self.server.tool_subscription) |subscription| {
            if (!subscription.lockCommitIfCurrent()) {
                return error.McpToolCatalogChanged;
            }
            self.subscription = subscription;
            self.subscription_locked = true;
        }

        const private_remote = self.snapshot.auth_partition.private_auth_identity != null and
            self.server.config.transport != .stdio;
        if (self.server.config.transport != .stdio) {
            try lockMutexUntil(
                &self.server.auth_lock,
                self.deadline,
                self.cancel_flag,
            );
            self.auth_locked = true;
        }

        if (self.snapshot.authority_id != self.server.authority_id.load(.acquire)) return error.McpAdvertisedToolChanged;

        try lockRwSharedUntil(
            self.catalog_mutex,
            self.deadline,
            self.cancel_flag,
        );
        defer self.catalog_mutex.unlockShared(io_mod.getIo());
        if (!current(self.server, self.snapshot)) {
            return error.McpToolCatalogChanged;
        }
        if (private_remote) {
            const active_key = catalog_freshness.authPartition(.private, try server_auth.currentAuthIdentity(self.alloc, self.server));
            if (!self.snapshot.auth_partition.eql(active_key)) {
                return error.McpToolCatalogChanged;
            }
        }
    }

    fn releaseCallback(raw: *anyopaque) void {
        const self: *CommitGuard = @ptrCast(@alignCast(raw));
        self.release();
    }

    fn release(self: *CommitGuard) void {
        if (self.live_view) |*view| {
            view.deinit(self.alloc);
            self.live_view = null;
        }
        if (self.auth_locked) {
            self.server.auth_lock.unlock(io_mod.getIo());
            self.auth_locked = false;
        }
        if (self.subscription_locked) {
            self.subscription.?.unlockCommit();
            self.subscription_locked = false;
            self.subscription = null;
        }
        if (self.catalog_commit_locked) {
            self.server.catalog_commit_lock.unlock(io_mod.getIo());
            self.catalog_commit_locked = false;
        }
    }
};

pub fn current(server: *const McpServer, snapshot: *const Snapshot) bool {
    const metadata = server.tool_catalog.metadata orelse return false;
    if (!tool_catalog.serverCatalogAvailable(server) or !metadata.key.eql(snapshot.auth_partition)) return false;
    if (server.connection_generation != snapshot.connection_generation or server.catalog_generation != snapshot.catalog_generation) return false;
    if (server.tool_subscription) |subscription| if (subscription.hasInvalidation()) return false;
    return serverHasSnapshotTool(server, snapshot);
}

fn serverHasSnapshotTool(
    server: *const McpServer,
    snapshot: *const Snapshot,
) bool {
    if (!std.mem.eql(u8, server.config.name, snapshot.server_name)) return false;
    for (server.tool_catalog.tools.items) |tool| {
        if (std.mem.eql(u8, tool.original_name, snapshot.original_name) and
            std.mem.eql(u8, tool.prefixed_name, snapshot.prefixed_name) and
            std.mem.eql(u8, tool.input_schema_json, snapshot.input_schema_json) and
            optionalBytesEqual(tool.output_schema_json, snapshot.output_schema_json))
        {
            return true;
        }
    }
    return false;
}

pub fn refreshGenerations(
    server: *const McpServer,
    snapshot: *Snapshot,
    stdio_generation: ?u64,
) bool {
    const metadata = server.tool_catalog.metadata orelse return false;
    if (snapshot.authority_id != server.authority_id.load(.acquire) or
        !tool_catalog.serverCatalogAvailable(server) or
        !metadata.key.eql(snapshot.auth_partition) or
        !serverHasSnapshotTool(server, snapshot))
    {
        return false;
    }
    snapshot.connection_generation = server.connection_generation;
    snapshot.catalog_generation = server.catalog_generation;
    snapshot.stdio_generation = stdio_generation;
    return true;
}

fn optionalBytesEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if ((left == null) != (right == null)) return false;
    if (left) |value| return std.mem.eql(u8, value, right.?);
    return true;
}

pub fn binding(runtime_generation: u64, server: *const McpServer, tool: McpTool) tool_mcp_runtime.Binding {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&catalog_state.digestTools(&.{tool}));
    catalog_state.hashOptionalField(&hasher, server.instructions);
    var definition_digest: [32]u8 = undefined;
    hasher.final(&definition_digest);
    return .{
        .runtime_generation = runtime_generation,
        .connection_generation = server.connection_generation,
        .catalog_generation = server.catalog_generation,
        .auth_generation = server.auth_generation.load(.acquire),
        .authority_id = server.authority_id.load(.acquire),
        .definition_digest = definition_digest,
    };
}
