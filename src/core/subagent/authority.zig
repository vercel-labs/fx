const std = @import("std");
const session_child_store = @import("../session/session_child_store.zig");
const session_store = @import("../session/session_store.zig");
const types = @import("../shared/types.zig");
const communication = @import("communication.zig");
const communication_store = @import("communication_store.zig");
const control_store = @import("control_store.zig");
const domain = @import("domain.zig");
const mcp_access = @import("../mcp/access_policy.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");

const Allocator = std.mem.Allocator;
const max_ancestry_depth: usize = 1024;

pub const PermissionAdmissionError = error{PermissionEscalation};

fn permissionRank(mode: types.PermissionMode) u2 {
    return switch (mode) {
        .ask => 0,
        .auto => 1,
        .yolo => 2,
    };
}

/// Resolves omitted child authority to the caller's current authority and
/// rejects explicit elevation. This policy applies only to model tool calls;
/// human manager commands retain their existing behavior.
pub fn admitChildPermission(
    parent: types.PermissionMode,
    requested: ?types.PermissionMode,
) PermissionAdmissionError!types.PermissionMode {
    const child = requested orelse parent;
    if (permissionRank(child) > permissionRank(parent)) {
        return error.PermissionEscalation;
    }
    return child;
}

test "child permission admission inherits and never elevates" {
    const Case = struct {
        parent: types.PermissionMode,
        requested: ?types.PermissionMode,
        expected: ?types.PermissionMode,
    };
    const cases = [_]Case{
        .{ .parent = .ask, .requested = null, .expected = .ask },
        .{ .parent = .auto, .requested = null, .expected = .auto },
        .{ .parent = .yolo, .requested = null, .expected = .yolo },
        .{ .parent = .ask, .requested = .ask, .expected = .ask },
        .{ .parent = .ask, .requested = .auto, .expected = null },
        .{ .parent = .ask, .requested = .yolo, .expected = null },
        .{ .parent = .auto, .requested = .ask, .expected = .ask },
        .{ .parent = .auto, .requested = .auto, .expected = .auto },
        .{ .parent = .auto, .requested = .yolo, .expected = null },
        .{ .parent = .yolo, .requested = .ask, .expected = .ask },
        .{ .parent = .yolo, .requested = .auto, .expected = .auto },
        .{ .parent = .yolo, .requested = .yolo, .expected = .yolo },
    };

    for (cases) |case| {
        if (case.expected) |expected| {
            try std.testing.expectEqual(
                expected,
                try admitChildPermission(case.parent, case.requested),
            );
        } else {
            try std.testing.expectError(
                error.PermissionEscalation,
                admitChildPermission(case.parent, case.requested),
            );
        }
    }
}

pub const Error = error{
    OutOfMemory,
    ChildNotAttached,
    RelationshipCycle,
    GraphTooDeep,
    InvalidControlRecord,
    StoreUnavailable,
    HostAuthorityUnavailable,
};

/// Owned current authority supplied by the controlling root. It is host state,
/// not child configuration, and must be freed with `deinit`.
pub const HostAuthority = struct {
    generation: u64,
    tools: [][]u8,
    integrations: [][]u8,
    rules: types.PermissionRuleSet,
    grants: []types.PermissionGrant,
    permission_state: session_permission_state.State = .{},
    mcp_view: ?mcp_access.View = null,

    pub fn capture(
        alloc: Allocator,
        tools: []const []const u8,
        integrations: []const []const u8,
        rules: types.PermissionRuleSet,
        grants: []const types.PermissionGrant,
    ) !HostAuthority {
        return captureWithPermissionStateAndMcpView(
            alloc,
            tools,
            integrations,
            rules,
            grants,
            .{},
            null,
        );
    }

    pub fn captureWithPermissionStateAndMcpView(
        alloc: Allocator,
        tools: []const []const u8,
        integrations: []const []const u8,
        rules: types.PermissionRuleSet,
        grants: []const types.PermissionGrant,
        permission_state: session_permission_state.State,
        mcp_view: ?*const mcp_access.View,
    ) !HostAuthority {
        const owned_tools = try cloneStrings(alloc, tools);
        errdefer freeStrings(alloc, owned_tools);
        const owned_integrations = try cloneStrings(alloc, integrations);
        errdefer freeStrings(alloc, owned_integrations);
        var owned_rules = try types.dupePermissionRuleSet(alloc, rules);
        errdefer owned_rules.deinit(alloc);
        const owned_permission_state = try session_permission_state.projectForChild(
            alloc,
            permission_state,
            &.{},
        );
        errdefer {
            var value = owned_permission_state;
            value.deinit(alloc);
        }
        var owned_mcp_view = if (mcp_view) |view| try view.clone(alloc) else null;
        errdefer if (owned_mcp_view) |*view| view.deinit(alloc);
        return .{
            .generation = hostGeneration(
                tools,
                integrations,
                rules,
                grants,
                owned_permission_state,
                mcp_view,
            ),
            .tools = owned_tools,
            .integrations = owned_integrations,
            .rules = owned_rules,
            .grants = try types.dupePermissionGrantSlice(alloc, grants),
            .permission_state = owned_permission_state,
            .mcp_view = owned_mcp_view,
        };
    }

    pub fn deinit(self: *HostAuthority, alloc: Allocator) void {
        freeStrings(alloc, self.tools);
        freeStrings(alloc, self.integrations);
        self.rules.deinit(alloc);
        types.freePermissionGrantSlice(alloc, self.grants);
        self.permission_state.deinit(alloc);
        if (self.mcp_view) |*mcp_view| mcp_view.deinit(alloc);
        self.* = undefined;
    }
};

test "host authority preserves session denies and filters undelegated allows" {
    const alloc = std.testing.allocator;
    var empty: session_permission_state.State = .{};
    defer empty.deinit(alloc);

    const allow_key = try session_permission_state.RuleKey.init(
        .command,
        "command\x00git status",
    );
    var allow_result = try session_permission_state.apply(alloc, empty, .{ .set = .{
        .key = allow_key,
        .display_identity = "git status",
        .decision = .allow,
        .expected_generation = null,
    } });
    var allow_state = allow_result.takeApplied() orelse
        return error.TestExpectedAppliedState;
    defer allow_state.deinit(alloc);

    const deny_key = try session_permission_state.RuleKey.init(
        .command,
        "command\x00rm -rf build",
    );
    var deny_result = try session_permission_state.apply(alloc, allow_state, .{ .set = .{
        .key = deny_key,
        .display_identity = "rm -rf build",
        .decision = .deny,
        .expected_generation = null,
    } });
    var parent_state = deny_result.takeApplied() orelse
        return error.TestExpectedAppliedState;
    defer parent_state.deinit(alloc);

    var host = try HostAuthority.captureWithPermissionStateAndMcpView(
        alloc,
        &.{"run_command"},
        &.{},
        .{},
        &.{},
        parent_state,
        null,
    );
    defer host.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), host.permission_state.rules.items.len);
    try std.testing.expectEqual(
        session_permission_state.Decision.deny,
        host.permission_state.rules.items[0].decision,
    );
    try std.testing.expect(session_permission_state.RuleKey.eql(
        deny_key,
        host.permission_state.rules.items[0].key,
    ));
    try std.testing.expectEqual(
        session_permission_state.StateDecision.unresolved,
        session_permission_state.decide(host.permission_state, allow_key),
    );
    try std.testing.expectEqual(
        session_permission_state.StateDecision.deny,
        session_permission_state.decide(host.permission_state, deny_key),
    );
}

fn hostGeneration(
    tools: []const []const u8,
    integrations: []const []const u8,
    rules: types.PermissionRuleSet,
    grants: []const types.PermissionGrant,
    permission_state: session_permission_state.State,
    mcp_view: ?*const mcp_access.View,
) u64 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.subagent.host-authority.v2\x00");
    hashU64(&hash, tools.len);
    for (tools) |tool| hashString(&hash, tool);
    hashU64(&hash, integrations.len);
    for (integrations) |integration| hashString(&hash, integration);
    hashU64(&hash, rules.rules.len);
    for (rules.rules) |rule| {
        hashString(&hash, rule.permission);
        hashString(&hash, rule.pattern);
        hashString(&hash, @tagName(rule.action));
    }
    hashU64(&hash, grants.len);
    for (grants) |grant| {
        hashString(&hash, grant.tool_name);
        hashString(&hash, grant.target_path);
    }
    hashU64(&hash, permission_state.version);
    hashU64(&hash, permission_state.next_generation);
    hashU64(&hash, permission_state.rules.items.len);
    for (permission_state.rules.items) |rule| {
        hashU64(&hash, rule.id.value);
        hashString(&hash, @tagName(rule.key.kind));
        hashString(&hash, rule.key.canonical);
        hashString(&hash, @tagName(rule.decision));
        hashU64(&hash, rule.generation);
    }
    if (mcp_view) |view| {
        hashU64(&hash, view.runtime_generation);
        hashString(&hash, view.owner_id);
        hashString(&hash, view.parent_id);
        hashU64(&hash, @intFromBool(view.features_visible));
        for (view.servers) |server_identity| {
            hashString(&hash, server_identity.name);
            hashString(&hash, @tagName(server_identity.source));
            hashString(&hash, @tagName(server_identity.scope));
            hashU64(&hash, server_identity.connection_generation);
            hashU64(&hash, server_identity.catalog_generation);
            hashU64(&hash, server_identity.auth_generation);
        }
        for (view.tools) |tool_identity| {
            hashString(&hash, tool_identity.name);
            hashString(&hash, tool_identity.server_name);
        }
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.mem.readInt(u64, digest[0..8], .little);
}

pub const HostResolver = struct {
    context: ?*anyopaque = null,
    resolve_fn: *const fn (
        ?*anyopaque,
        Allocator,
        []const u8,
    ) HostResolveError!HostAuthority,

    fn resolve(
        self: HostResolver,
        alloc: Allocator,
        root_id: []const u8,
    ) Error!HostAuthority {
        return self.resolve_fn(self.context, alloc, root_id);
    }
};

pub const HostResolveError = error{
    OutOfMemory,
    HostAuthorityUnavailable,
};

pub const Snapshot = struct {
    child_id: []u8,
    root_id: []u8,
    generation: u64,
    tools: [][]u8,
    integrations: [][]u8,
    rules: types.PermissionRuleSet,
    grants: []types.PermissionGrant,
    permission_state: session_permission_state.State = .{},
    permission_mode: types.PermissionMode = .yolo,
    mcp_view: ?mcp_access.View = null,

    pub fn deinit(self: *Snapshot, alloc: Allocator) void {
        alloc.free(self.child_id);
        alloc.free(self.root_id);
        freeStrings(alloc, self.tools);
        freeStrings(alloc, self.integrations);
        self.rules.deinit(alloc);
        types.freePermissionGrantSlice(alloc, self.grants);
        self.permission_state.deinit(alloc);
        if (self.mcp_view) |*mcp_view| mcp_view.deinit(alloc);
        self.* = undefined;
    }

    pub fn view(self: *const Snapshot) communication.LiveAuthority {
        return .{
            .generation = self.generation,
            .root_id = self.root_id,
            .tools = self.tools,
            .integrations = self.integrations,
            .rules = self.rules,
            .grants = self.grants,
            .permission_state = &self.permission_state,
            .permission_mode = self.permission_mode,
        };
    }
};

pub const Resolver = struct {
    sessions: *session_store.Store,
    host: HostResolver,
    child_store_options: session_child_store.Options = .{},

    /// Resolves the canonical parent chain and current root authority on every
    /// call. Callers may cache only together with `generation` and must resolve
    /// again before the next child tool action.
    pub fn resolve(
        self: *Resolver,
        alloc: Allocator,
        child_id: []const u8,
    ) Error!Snapshot {
        for (0..3) |_| {
            return self.resolveOnce(alloc, child_id) catch |err| {
                if (err == error.AuthorityChanged) continue;
                return @errorCast(err);
            };
        }
        return error.StoreUnavailable;
    }

    fn resolveOnce(
        self: *Resolver,
        alloc: Allocator,
        child_id: []const u8,
    ) (Error || error{AuthorityChanged})!Snapshot {
        domain.validateId(child_id) catch return error.ChildNotAttached;
        var seen: std.ArrayList([]u8) = .empty;
        defer freeStringsList(alloc, &seen);
        var generations: std.ArrayList(u64) = .empty;
        defer generations.deinit(alloc);
        var current = try alloc.dupe(u8, child_id);
        defer alloc.free(current);
        var found_root = false;
        var permission_mode: types.PermissionMode = .yolo;

        var depth: usize = 0;
        while (depth < max_ancestry_depth) : (depth += 1) {
            for (seen.items) |id| {
                if (std.mem.eql(u8, id, current)) return error.RelationshipCycle;
            }
            try seen.append(alloc, try alloc.dupe(u8, current));
            var capability = self.sessions.openSubagentControlCapabilityReadOnly(
                alloc,
                current,
                self.child_store_options,
            ) catch |err| return mapOpen(err);
            defer capability.deinit();
            const store = control_store.Store{
                .capability = &capability,
                .expected_child_id = current,
            };
            const maybe_record = store.loadOptional(alloc) catch |err| return mapControl(err);
            if (maybe_record) |loaded| {
                var record = loaded;
                defer record.deinit(alloc);
                if (depth == 0) {
                    permission_mode = record.configuration.permission_mode;
                }
                try generations.append(alloc, record.generation);
                if (record.parent_id) |parent_id| {
                    const next = try alloc.dupe(u8, parent_id);
                    alloc.free(current);
                    current = next;
                    continue;
                }
            } else if (depth == 0) {
                return error.ChildNotAttached;
            }
            found_root = true;
            break;
        }
        if (!found_root) return error.GraphTooDeep;
        const root: []const u8 = current;
        var host = try self.host.resolve(alloc, root);
        defer host.deinit(alloc);
        var durable_grants: []types.PermissionGrant = try alloc.alloc(types.PermissionGrant, 0);
        defer types.freePermissionGrantSlice(alloc, durable_grants);
        var durable_generation: u64 = 0;
        var root_capability = self.sessions.openSubagentControlCapabilityReadOnly(
            alloc,
            root,
            self.child_store_options,
        ) catch |err| return mapOpen(err);
        defer root_capability.deinit();
        const durable_store = communication_store.Store{
            .capability = &root_capability,
            .expected_session_id = root,
        };
        const maybe_ledger = durable_store.loadOptional(alloc) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCommunicationRecord,
            error.UnsupportedCommunicationSchema,
            => return error.InvalidControlRecord,
            error.CommunicationRecordTooLarge,
            error.CommunicationPathUnsafe,
            error.PrivateStatePermissionsUnsupported,
            error.CommunicationStoreFailed,
            error.CommunicationNotFound,
            => return error.StoreUnavailable,
        };
        if (maybe_ledger) |loaded| {
            var ledger = loaded;
            defer ledger.deinit(alloc);
            types.freePermissionGrantSlice(alloc, durable_grants);
            durable_grants = try types.dupePermissionGrantSlice(alloc, ledger.authority_grants);
            durable_generation = ledger.authority_generation;
        }
        try self.validateAncestrySnapshot(alloc, seen.items, generations.items);
        const grants = try mergeGrants(alloc, host.grants, durable_grants);
        errdefer types.freePermissionGrantSlice(alloc, grants);
        const owned_child_id = try alloc.dupe(u8, child_id);
        errdefer alloc.free(owned_child_id);
        const owned_root_id = try alloc.dupe(u8, root);
        errdefer alloc.free(owned_root_id);
        const tools = try cloneStrings(alloc, host.tools);
        errdefer freeStrings(alloc, tools);
        const integrations = try cloneStrings(alloc, host.integrations);
        errdefer freeStrings(alloc, integrations);
        var rules = try types.dupePermissionRuleSet(alloc, host.rules);
        errdefer rules.deinit(alloc);
        const permission_state = session_permission_state.dupe(
            alloc,
            host.permission_state,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidControlRecord,
        };
        errdefer {
            var value = permission_state;
            value.deinit(alloc);
        }
        var mcp_view = if (host.mcp_view) |view| try view.clone(alloc) else null;
        errdefer if (mcp_view) |*view| view.deinit(alloc);
        if (mcp_view) |*view| {
            const parent_id = if (seen.items.len > 1) seen.items[1] else root;
            try rebindMcpViewOwnership(alloc, view, child_id, parent_id);
        }
        return .{
            .child_id = owned_child_id,
            .root_id = owned_root_id,
            .generation = authorityGeneration(
                child_id,
                root,
                generations.items,
                host.generation,
                durable_generation,
            ),
            .tools = tools,
            .integrations = integrations,
            .rules = rules,
            .grants = grants,
            .permission_state = permission_state,
            .permission_mode = permission_mode,
            .mcp_view = mcp_view,
        };
    }

    fn validateAncestrySnapshot(
        self: *Resolver,
        alloc: Allocator,
        ids: []const []u8,
        generations: []const u64,
    ) (Error || error{AuthorityChanged})!void {
        if (ids.len == 0 or generations.len > ids.len or
            ids.len - generations.len > 1)
        {
            return error.AuthorityChanged;
        }
        for (ids, 0..) |id, index| {
            var capability = self.sessions.openSubagentControlCapabilityReadOnly(
                alloc,
                id,
                self.child_store_options,
            ) catch |err| return mapOpen(err);
            defer capability.deinit();
            const store = control_store.Store{
                .capability = &capability,
                .expected_child_id = id,
            };
            const maybe_record = store.loadOptional(alloc) catch |err|
                return mapControl(err);
            if (index >= generations.len) {
                if (maybe_record != null or index + 1 != ids.len) {
                    if (maybe_record) |loaded| {
                        var record = loaded;
                        record.deinit(alloc);
                    }
                    return error.AuthorityChanged;
                }
                continue;
            }
            var record = maybe_record orelse return error.AuthorityChanged;
            defer record.deinit(alloc);
            if (record.generation != generations[index]) {
                return error.AuthorityChanged;
            }
            const expected_parent: ?[]const u8 = if (index + 1 < ids.len)
                ids[index + 1]
            else
                null;
            if (!optionalEqual(record.parent_id, expected_parent)) {
                return error.AuthorityChanged;
            }
        }
    }
};

fn rebindMcpViewOwnership(
    alloc: Allocator,
    view: *mcp_access.View,
    owner_id: []const u8,
    parent_id: []const u8,
) !void {
    const owned_owner = try alloc.dupe(u8, owner_id);
    errdefer alloc.free(owned_owner);
    const owned_parent = try alloc.dupe(u8, parent_id);
    alloc.free(view.owner_id);
    alloc.free(view.parent_id);
    view.owner_id = owned_owner;
    view.parent_id = owned_parent;
}

fn authorityGeneration(
    child_id: []const u8,
    root_id: []const u8,
    relationship_generations: []const u64,
    host_generation: u64,
    durable_generation: u64,
) u64 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.subagent.live-authority.v1\x00");
    hashString(&hash, child_id);
    hashString(&hash, root_id);
    hashU64(&hash, host_generation);
    hashU64(&hash, durable_generation);
    for (relationship_generations) |generation| hashU64(&hash, generation);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const value = std.mem.readInt(u64, digest[0..8], .little);
    return if (value == 0) 1 else value;
}

fn mergeGrants(
    alloc: Allocator,
    host: []const types.PermissionGrant,
    durable: []const types.PermissionGrant,
) ![]types.PermissionGrant {
    var merged: std.ArrayList(types.PermissionGrant) = .empty;
    errdefer {
        for (merged.items) |grant| {
            alloc.free(grant.tool_name);
            alloc.free(grant.target_path);
        }
        merged.deinit(alloc);
    }
    for (host) |grant| try appendGrant(alloc, &merged, grant);
    for (durable) |grant| {
        var found = false;
        for (merged.items) |existing| {
            if (std.mem.eql(u8, existing.tool_name, grant.tool_name) and
                std.mem.eql(u8, existing.target_path, grant.target_path))
            {
                found = true;
                break;
            }
        }
        if (!found) try appendGrant(alloc, &merged, grant);
    }
    return merged.toOwnedSlice(alloc);
}

fn appendGrant(
    alloc: Allocator,
    list: *std.ArrayList(types.PermissionGrant),
    grant: types.PermissionGrant,
) !void {
    const tool_name = try alloc.dupe(u8, grant.tool_name);
    errdefer alloc.free(tool_name);
    const target_path = try alloc.dupe(u8, grant.target_path);
    errdefer alloc.free(target_path);
    try list.append(alloc, .{
        .tool_name = tool_name,
        .target_path = target_path,
    });
}

fn mapOpen(err: session_store.OpenSubagentControlError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidSessionId, error.SessionNotFound => error.ChildNotAttached,
        error.SessionPathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        error.SessionChildStoreFailed,
        error.SessionStoreUnavailable,
        => error.StoreUnavailable,
    };
}

fn mapControl(err: control_store.LoadError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ControlNotFound => error.ChildNotAttached,
        error.InvalidControlRecord,
        error.UnsupportedControlSchema,
        => error.InvalidControlRecord,
        error.ControlRecordTooLarge,
        error.ControlPathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        error.ControlStoreFailed,
        => error.StoreUnavailable,
    };
}

fn cloneStrings(alloc: Allocator, values: []const []const u8) ![][]u8 {
    const out = try alloc.alloc([]u8, values.len);
    errdefer alloc.free(out);
    var copied: usize = 0;
    errdefer for (out[0..copied]) |value| alloc.free(value);
    for (values, 0..) |value, index| {
        out[index] = try alloc.dupe(u8, value);
        copied += 1;
    }
    return out;
}

fn freeStrings(alloc: Allocator, values: [][]u8) void {
    for (values) |value| alloc.free(value);
    alloc.free(values);
}

fn freeStringsList(alloc: Allocator, values: *std.ArrayList([]u8)) void {
    for (values.items) |value| alloc.free(value);
    values.deinit(alloc);
}

fn hashString(hash: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    hashU64(hash, value.len);
    hash.update(value);
}

fn optionalEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn hashU64(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

fn checkGrantMergeResolutionAllocationFailures(alloc: Allocator) !void {
    const host = [_]types.PermissionGrant{
        .{ .tool_name = @constCast("read"), .target_path = @constCast("src/**") },
        .{ .tool_name = @constCast("bash"), .target_path = @constCast("zig build*") },
    };
    const durable = [_]types.PermissionGrant{
        .{ .tool_name = @constCast("read"), .target_path = @constCast("src/**") },
        .{ .tool_name = @constCast("custom"), .target_path = @constCast("zig build*") },
    };
    const merged = try mergeGrants(alloc, &host, &durable);
    defer types.freePermissionGrantSlice(alloc, merged);
    try std.testing.expectEqual(@as(usize, 3), merged.len);
    try std.testing.expectEqualStrings("read", merged[0].tool_name);
    try std.testing.expectEqualStrings("bash", merged[1].tool_name);
    try std.testing.expectEqualStrings("custom", merged[2].tool_name);
}

test "grant merge resolution cleans every failing allocation path" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkGrantMergeResolutionAllocationFailures,
        .{},
    );
}
