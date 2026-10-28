const std = @import("std");
const child_state = @import("child_state.zig");
const domain = @import("domain.zig");
const mcp_access = @import("../mcp/access_policy.zig");
const permissions = @import("../permissions/permissions.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const session_store = @import("../session/session_store.zig");
const types = @import("../shared/types.zig");
const profiles = @import("../profiles/profiles.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const testing_allocator = @import("../shared/testing_allocator.zig");

const Allocator = std.mem.Allocator;

pub const PermissionAdmissionError = error{PermissionEscalation};

fn permissionRank(mode: types.PermissionMode) u2 {
    return switch (mode) {
        .ask => 0,
        .auto => 1,
        .yolo => 2,
    };
}

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

pub const Error = error{
    OutOfMemory,
    ChildNotAttached,
    InvalidControlRecord,
    StoreUnavailable,
    HostAuthorityUnavailable,
};

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

pub const HostResolver = struct {
    context: ?*anyopaque = null,
    resolve_fn: *const fn (
        ?*anyopaque,
        Allocator,
        []const u8,
    ) HostResolveError!HostAuthority,
    /// The permission mode the user chose on a child's own screen, if any.
    /// It wins over the child's profile and the work's mode, as main's
    /// choice wins over its launch profile.
    child_permission_mode_fn: ?*const fn (?*anyopaque, []const u8) ?types.PermissionMode = null,
    /// The permission mode agent `parent_id` works in now: an instance's
    /// own, or a subagent's as the host that started it resolves it. A
    /// child with no mode of its own or from its profile follows it on each
    /// tool call. Without it, or when it returns null, a child keeps the mode
    /// its work was sent under.
    parent_permission_mode_fn: ?*const fn (?*anyopaque, Allocator, []const u8) ?types.PermissionMode = null,
    /// fx's own tools, MCP integrations, and MCP view for root `root_id`,
    /// before any profile: what a profile that sets tools or MCP servers
    /// chooses from, even past its parent's. Without it, such a profile
    /// narrows its parent's instead.
    base_fn: ?*const fn (?*anyopaque, Allocator, []const u8) HostResolveError!HostAuthority = null,

    fn resolveBase(self: HostResolver, alloc: Allocator, root_id: []const u8) Error!?HostAuthority {
        const base_fn = self.base_fn orelse return null;
        return try base_fn(self.context, alloc, root_id);
    }

    fn childPermissionMode(self: HostResolver, child_id: []const u8) ?types.PermissionMode {
        const mode_fn = self.child_permission_mode_fn orelse return null;
        return mode_fn(self.context, child_id);
    }

    fn parentPermissionMode(self: HostResolver, alloc: Allocator, parent_id: []const u8) ?types.PermissionMode {
        const mode_fn = self.parent_permission_mode_fn orelse return null;
        return mode_fn(self.context, alloc, parent_id);
    }

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

pub const LiveAuthority = struct {
    generation: u64,
    root_id: []const u8,
    tools: []const []const u8,
    integrations: []const []const u8,
    rules: types.PermissionRuleSet,
    grants: []const types.PermissionGrant,
    permission_mode: types.PermissionMode,
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
    permission_mode: types.PermissionMode,
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

    pub fn view(self: *const Snapshot) LiveAuthority {
        return .{
            .generation = self.generation,
            .root_id = self.root_id,
            .tools = self.tools,
            .integrations = self.integrations,
            .rules = self.rules,
            .grants = self.grants,
            .permission_mode = self.permission_mode,
        };
    }
};

/// The profile each child started in, loaded the first time the child's
/// authority is resolved and kept for the life of the process, so a running
/// child keeps it whatever is saved later. Profiles resolve from the fx home
/// and the current directory, as `fx --profile` does.
pub const ProfileCache = struct {
    alloc: Allocator,
    /// Where to look instead of the fx home and the current directory.
    roots: ?struct { home: ?[]const u8, workspace_root: ?[]const u8 } = null,
    mutex: std.Io.Mutex = .init,
    /// Keyed by child id, owned. Entries live until `deinit`.
    entries: std.array_hash_map.String(*profiles.Held) = .empty,

    /// The profile `child_id` runs in, loading `name` the first time. A
    /// profile that cannot be loaded fails closed: the child gets no
    /// authority at all rather than more than its profile gives.
    pub fn get(self: *ProfileCache, child_id: []const u8, name: []const u8) Error!*const profiles.Profile {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.entries.get(child_id)) |held| return &held.profile;
        const held = try self.alloc.create(profiles.Held);
        errdefer self.alloc.destroy(held);
        held.* = .{};
        const process_root = if (self.roots == null) io_mod.realpathAlloc(self.alloc, ".") catch null else null;
        defer if (process_root) |root| self.alloc.free(root);
        const home = if (self.roots) |roots| roots.home else io_mod.homeDir();
        const workspace_root = if (self.roots) |roots| roots.workspace_root else process_root;
        var failure: ?[]u8 = null;
        defer if (failure) |message| self.alloc.free(message);
        held.replace(self.alloc, home, workspace_root, name, "", &failure) catch |err| {
            debug_trace.eventf("profile", "profile_failed", .{}, "child={s} name={s} reason={s}", .{
                child_id,
                name,
                failure orelse @errorName(err),
            });
            return if (err == error.OutOfMemory) error.OutOfMemory else error.HostAuthorityUnavailable;
        };
        errdefer held.deinit();
        const key = try self.alloc.dupe(u8, child_id);
        errdefer self.alloc.free(key);
        try self.entries.put(self.alloc, key, held);
        return &held.profile;
    }

    /// The profile `child_id` was given, if its authority was resolved.
    pub fn find(self: *ProfileCache, child_id: []const u8) ?*const profiles.Profile {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const held = self.entries.get(child_id) orelse return null;
        return &held.profile;
    }

    pub fn deinit(self: *ProfileCache) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
            self.alloc.destroy(entry.value_ptr.*);
        }
        self.entries.deinit(self.alloc);
        self.* = undefined;
    }
};

pub const Resolver = struct {
    children: *child_state.V2Children,
    root_id: []const u8 = "",
    host: HostResolver,

    /// Where a child's stored profile is loaded. A child with a profile and
    /// no cache gets no authority.
    profiles: ?*ProfileCache = null,

    /// The authority of the work main started on child `child_id`, which
    /// must still be active.
    pub fn resolve(
        self: *Resolver,
        alloc: Allocator,
        child_id: []const u8,
    ) Error!Snapshot {
        return self.resolveWith(alloc, child_id, .work);
    }

    /// The authority of a turn on child `child_id` that no work of main's
    /// started, such as one the user typed on its screen: the same as
    /// a run's, with `permission_mode` in place of the work's where the host
    /// can't say the parent's current mode. The child's profile still
    /// narrows its tools, and its own mode still wins.
    pub fn resolveForUser(
        self: *Resolver,
        alloc: Allocator,
        child_id: []const u8,
        permission_mode: types.PermissionMode,
    ) Error!Snapshot {
        return self.resolveWith(alloc, child_id, .{ .user = permission_mode });
    }

    const Basis = union(enum) { work, user: types.PermissionMode };

    /// The permission mode child `child_id` works in now, whatever its work
    /// was sent under: the mode chosen on its own screen, else its
    /// profile's, else the one its parent works in now. Its tool calls are
    /// decided in this mode, and the host that started it asks here for
    /// the mode its own subagents follow. Reads the registry without the
    /// store lock, so the main loop can call it while a save runs.
    pub fn currentMode(self: *Resolver, alloc: Allocator, child_id: []const u8) Error!types.PermissionMode {
        domain.validateId(child_id) catch return error.ChildNotAttached;
        domain.validateId(self.root_id) catch return error.ChildNotAttached;
        const parent_mode = self.host.parentPermissionMode(alloc, self.root_id);
        const store = child_state.Store{ .children = self.children, .parent_id = self.root_id };
        var registry = store.load(alloc) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.StoreUnavailable,
        };
        defer registry.deinit(alloc);
        const child = registry.findById(child_id) orelse return error.ChildNotAttached;
        // Without its parent's mode it keeps the one its work was sent
        // under, or ask with no work.
        const sent: types.PermissionMode = if (child.active) |work| work.permission_mode else .ask;
        return self.modeFor(child_id, try self.profileOf(child_id, child.profile), parent_mode orelse sent);
    }

    /// The profile child `child_id` runs in, loaded the first time. A
    /// child with a profile and no cache gets no authority.
    fn profileOf(self: *Resolver, child_id: []const u8, name: ?[]const u8) Error!?*const profiles.Profile {
        const value = name orelse return null;
        const cache = self.profiles orelse return error.HostAuthorityUnavailable;
        return try cache.get(child_id, value);
    }

    /// Child `child_id`'s mode, given the one it would otherwise follow:
    /// the mode chosen on its own screen, else its profile's, which wins
    /// even when looser than `inherited`, else `inherited`.
    fn modeFor(
        self: *Resolver,
        child_id: []const u8,
        profile: ?*const profiles.Profile,
        inherited: types.PermissionMode,
    ) types.PermissionMode {
        if (self.host.childPermissionMode(child_id)) |own| return own;
        return if (profile) |value| profiles.permissionMode(value, inherited) else inherited;
    }

    fn resolveWith(
        self: *Resolver,
        alloc: Allocator,
        child_id: []const u8,
        basis: Basis,
    ) Error!Snapshot {
        domain.validateId(child_id) catch return error.ChildNotAttached;
        domain.validateId(self.root_id) catch return error.ChildNotAttached;
        const store = child_state.Store{ .children = self.children, .parent_id = self.root_id };
        const work_generation = blk: {
            var lock = store.acquireLock();
            defer lock.release();
            var registry = store.load(alloc) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.StoreUnavailable,
            };
            defer registry.deinit(alloc);
            const child = registry.findById(child_id) orelse return error.ChildNotAttached;
            if (basis == .work and child.active == null) return error.ChildNotAttached;
            break :blk child.work_generation;
        };

        // Host resolution may connect MCP servers; parent state observation must remain available.
        var host = try self.host.resolve(alloc, self.root_id);
        defer host.deinit(alloc);
        // The parent's current mode, resolved outside the store lock: the
        // host's hook takes the authority lock, and a subagent parent's
        // reads its own parent's registry.
        const parent_mode = self.host.parentPermissionMode(alloc, self.root_id);

        const current = blk: {
            var lock = store.acquireLock();
            defer lock.release();
            var registry = store.load(alloc) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.StoreUnavailable,
            };
            defer registry.deinit(alloc);
            const child = registry.findById(child_id) orelse return error.ChildNotAttached;
            const sent = switch (basis) {
                .work => (child.active orelse return error.ChildNotAttached).permission_mode,
                .user => |value| value,
            };
            // Work replaced since the first read is no longer this run's. A
            // user's turn belongs to no work.
            if (basis == .work and child.work_generation != work_generation) return error.ChildNotAttached;
            const profile = try self.profileOf(child_id, child.profile);
            break :blk .{
                .generation = registry.generation,
                // It follows its parent's current mode, and keeps the one its
                // work was sent under only where the host can't say it.
                .permission_mode = self.modeFor(child_id, profile, parent_mode orelse sent),
                .profile = profile,
            };
        };

        // A profile that sets tools or MCP servers decides them from fx's
        // own, even past what the parent has; what it leaves unset is the
        // parent's.
        const sets_tools = if (current.profile) |profile| profiles.setsTools(profile) else false;
        const sets_mcp = if (current.profile) |profile| profiles.setsMcpServers(profile) else false;
        var base: ?HostAuthority = if (sets_tools or sets_mcp) try self.host.resolveBase(alloc, self.root_id) else null;
        defer if (base) |*value| value.deinit(alloc);
        const tool_source = if (sets_tools) if (base) |*value| value.tools else host.tools else host.tools;
        const integration_source = if (sets_mcp) if (base) |*value| value.integrations else host.integrations else host.integrations;
        const view_source: ?*const mcp_access.View = view: {
            if (sets_mcp) if (base) |*value| break :view if (value.mcp_view) |*view| view else null;
            break :view if (host.mcp_view) |*view| view else null;
        };
        const host_generation = if (base) |value| host.generation ^ std.math.rotl(u64, value.generation, 1) else host.generation;

        const owned_child_id = try alloc.dupe(u8, child_id);
        errdefer alloc.free(owned_child_id);
        const owned_root_id = try alloc.dupe(u8, self.root_id);
        errdefer alloc.free(owned_root_id);
        const tools = try cloneKeptTools(alloc, tool_source, current.profile);
        errdefer freeStrings(alloc, tools);
        const integrations = try cloneIntegrations(alloc, integration_source, current.profile, view_source);
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
        var mcp_view = if (view_source) |view| try view.clone(alloc) else null;
        errdefer if (mcp_view) |*view| view.deinit(alloc);
        if (mcp_view) |*view| {
            try rebindMcpViewOwnership(alloc, view, child_id, self.root_id);
            if (current.profile) |profile| try narrowMcpView(alloc, view, profile);
        }
        return .{
            .child_id = owned_child_id,
            .root_id = owned_root_id,
            .generation = authorityGeneration(
                child_id,
                self.root_id,
                current.generation,
                host_generation,
            ),
            .tools = tools,
            .integrations = integrations,
            .rules = rules,
            .grants = try types.dupePermissionGrantSlice(alloc, host.grants),
            .permission_state = permission_state,
            .permission_mode = current.permission_mode,
            .mcp_view = mcp_view,
        };
    }
};

pub const ToolAuthorityDecision = enum { allow, ask, deny, unavailable };

pub fn decideToolAuthority(
    alloc: Allocator,
    live: LiveAuthority,
    workspace_root: []const u8,
    tool_name: []const u8,
    target: []const u8,
    target_kind: permissions.PermissionTargetKind,
) !ToolAuthorityDecision {
    if (!contains(live.tools, tool_name) and
        !contains(live.integrations, tool_name))
    {
        return .unavailable;
    }
    if (live.permission_mode == .yolo) return .allow;
    const permission_name = if (target_kind == .command_cwd and
        std.mem.eql(u8, tool_name, "shell"))
        "terminal"
    else
        tool_name;
    return switch (try permissions.ruleDecisionFor(
        alloc,
        live.rules,
        workspace_root,
        permission_name,
        target,
        target_kind,
    )) {
        .allow => .allow,
        .deny => .deny,
        .ask, .none => if (permissions.sessionGrantAllowed(
            live.grants,
            permission_name,
            target,
        )) .allow else .ask,
    };
}

fn rebindMcpViewOwnership(
    alloc: Allocator,
    view: *mcp_access.View,
    child_id: []const u8,
    parent_id: []const u8,
) !void {
    const owner = try alloc.dupe(u8, child_id);
    errdefer alloc.free(owner);
    const parent = try alloc.dupe(u8, parent_id);
    alloc.free(view.owner_id);
    alloc.free(view.parent_id);
    view.owner_id = owner;
    view.parent_id = parent;
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
    hash.update("fx.subagent.host-authority.v3\x00");
    for (tools) |tool| hashString(&hash, tool);
    for (integrations) |integration| hashString(&hash, integration);
    for (rules.rules) |rule| {
        hashString(&hash, rule.permission);
        hashString(&hash, rule.pattern);
        hashString(&hash, @tagName(rule.action));
    }
    for (grants) |grant| {
        hashString(&hash, grant.tool_name);
        hashString(&hash, grant.target_path);
    }
    hashU64(&hash, permission_state.version);
    hashU64(&hash, permission_state.next_generation);
    if (mcp_view) |view| {
        hashU64(&hash, view.runtime_generation);
        hashString(&hash, view.owner_id);
        hashString(&hash, view.parent_id);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.mem.readInt(u64, digest[0..8], .little);
}

fn authorityGeneration(
    child_id: []const u8,
    root_id: []const u8,
    child_generation: u64,
    host_generation: u64,
) u64 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.subagent.live-authority.v2\x00");
    hashString(&hash, child_id);
    hashString(&hash, root_id);
    hashU64(&hash, child_generation);
    hashU64(&hash, host_generation);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const value = std.mem.readInt(u64, digest[0..8], .little);
    return if (value == 0) 1 else value;
}

fn contains(values: []const []const u8, value: []const u8) bool {
    for (values) |candidate| {
        if (std.mem.eql(u8, candidate, value)) return true;
    }
    return false;
}

fn cloneStrings(alloc: Allocator, values: []const []const u8) ![][]u8 {
    const out = try alloc.alloc([]u8, values.len);
    var copied: usize = 0;
    errdefer {
        for (out[0..copied]) |value| alloc.free(value);
        alloc.free(out);
    }
    for (values) |value| {
        out[copied] = try alloc.dupe(u8, value);
        copied += 1;
    }
    return out;
}

/// The host's tools a child may use: all of them, `subagent` included, or with
/// a profile only those it allows.
fn cloneKeptTools(
    alloc: Allocator,
    values: []const []const u8,
    profile: ?*const profiles.Profile,
) ![][]u8 {
    return cloneKept(alloc, values, profile, keepTool);
}

/// The host's MCP integrations a child may use: with a profile, only the
/// servers it allows.
/// Keeps only the MCP servers `profile` allows, and their tools, so a
/// profiled child cannot even find the others, as its integrations cannot
/// name them.
/// Narrows `host`'s MCP integrations and view to the servers `profile` sets,
/// as an instance's own profile narrows what its tree starts from. A profile
/// that sets none leaves them.
pub fn narrowHostToMcpServers(alloc: Allocator, host: *HostAuthority, profile: *const profiles.Profile) !void {
    if (!profiles.setsMcpServers(profile)) return;
    const integrations = try cloneIntegrations(alloc, host.integrations, profile, if (host.mcp_view) |*view| view else null);
    freeStrings(alloc, host.integrations);
    host.integrations = integrations;
    if (host.mcp_view) |*view| try narrowMcpView(alloc, view, profile);
}

fn narrowMcpView(alloc: Allocator, view: *mcp_access.View, profile: *const profiles.Profile) !void {
    // Both kept lists are allocated before anything in `view` moves or is
    // freed, so a failed allocation leaves `view` whole for its owner to free.
    var server_count: usize = 0;
    for (view.servers) |server| {
        if (profiles.allowsMcpServer(profile, server.name)) server_count += 1;
    }
    var tool_count: usize = 0;
    for (view.tools) |tool| {
        if (profiles.allowsMcpServer(profile, tool.server_name)) tool_count += 1;
    }
    const servers = try alloc.alloc(mcp_access.ServerIdentity, server_count);
    errdefer alloc.free(servers);
    const tools = try alloc.alloc(mcp_access.ToolIdentity, tool_count);

    var kept: usize = 0;
    for (view.servers) |*server| {
        if (profiles.allowsMcpServer(profile, server.name)) {
            servers[kept] = server.*;
            kept += 1;
        } else server.deinit(alloc);
    }
    kept = 0;
    for (view.tools) |*tool| {
        if (profiles.allowsMcpServer(profile, tool.server_name)) {
            tools[kept] = tool.*;
            kept += 1;
        } else tool.deinit(alloc);
    }
    alloc.free(view.servers);
    alloc.free(view.tools);
    view.servers = servers;
    view.tools = tools;
}

/// The MCP integrations in `values` that `profile` keeps. Each is an MCP
/// tool's name, kept when its server, as `view` names it, is one the profile
/// allows; a name `view` doesn't know is taken as a server's own name.
fn cloneIntegrations(
    alloc: Allocator,
    values: []const []const u8,
    profile: ?*const profiles.Profile,
    view: ?*const mcp_access.View,
) ![][]u8 {
    const value = profile orelse return cloneStrings(alloc, values);
    if (!profiles.setsMcpServers(value)) return cloneStrings(alloc, values);
    var kept: std.ArrayList([]const u8) = .empty;
    defer kept.deinit(alloc);
    for (values) |name| {
        const server = if (view) |known| if (known.tool(name)) |tool| tool.server_name else name else name;
        if (profiles.allowsMcpServer(value, server)) try kept.append(alloc, name);
    }
    return cloneStrings(alloc, kept.items);
}

/// A tool the child keeps from the set it starts from, unless its profile
/// leaves it out. `subagent` is kept like any other, so a child starts its
/// own.
fn keepTool(profile: ?*const profiles.Profile, name: []const u8) bool {
    const value = profile orelse return true;
    return profiles.allowsTool(value, name);
}

fn cloneKept(
    alloc: Allocator,
    values: []const []const u8,
    profile: ?*const profiles.Profile,
    comptime keep: fn (?*const profiles.Profile, []const u8) bool,
) ![][]u8 {
    var count: usize = 0;
    for (values) |value| {
        if (keep(profile, value)) count += 1;
    }
    const out = try alloc.alloc([]u8, count);
    var copied: usize = 0;
    errdefer {
        for (out[0..copied]) |value| alloc.free(value);
        alloc.free(out);
    }
    for (values) |value| {
        if (!keep(profile, value)) continue;
        out[copied] = try alloc.dupe(u8, value);
        copied += 1;
    }
    return out;
}

fn freeStrings(alloc: Allocator, values: [][]u8) void {
    for (values) |value| alloc.free(value);
    alloc.free(values);
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

test "child permission admission inherits without elevation" {
    try std.testing.expectEqual(
        types.PermissionMode.auto,
        try admitChildPermission(.auto, null),
    );
    try std.testing.expectError(
        error.PermissionEscalation,
        admitChildPermission(.ask, .auto),
    );
}

test "tool authority refuses a tool the host lacks" {
    const alloc = std.testing.allocator;
    const decision = try decideToolAuthority(alloc, .{
        .generation = 1,
        .root_id = "root",
        .tools = &.{"read_file"},
        .integrations = &.{},
        .rules = .{},
        .grants = &.{},
        .permission_mode = .yolo,
    }, "/tmp", "subagent", "subagent", .none);
    try std.testing.expectEqual(ToolAuthorityDecision.unavailable, decision);
}

test "narrowing an MCP view to a profile's servers leaves it whole when an allocation fails" {
    const Narrow = struct {
        fn run(alloc: Allocator, profile: *const profiles.Profile) !void {
            var servers = [_]mcp_access.ServerIdentity{
                .{ .name = @constCast("github"), .source = .profile, .scope = .profile, .connection_generation = 1, .catalog_generation = 1, .auth_generation = 1 },
                .{ .name = @constCast("slack"), .source = .profile, .scope = .profile, .connection_generation = 1, .catalog_generation = 1, .auth_generation = 1 },
            };
            var tools = [_]mcp_access.ToolIdentity{
                .{ .name = @constCast("github_issue"), .server_name = @constCast("github") },
                .{ .name = @constCast("slack_post"), .server_name = @constCast("slack") },
            };
            const source = mcp_access.View{
                .runtime_generation = 1,
                .owner_id = @constCast("root"),
                .parent_id = @constCast("root"),
                .servers = &servers,
                .tools = &tools,
            };
            var view = try source.clone(alloc);
            defer view.deinit(alloc);
            try narrowMcpView(alloc, &view, profile);
            try std.testing.expectEqual(@as(usize, 1), view.servers.len);
            try std.testing.expectEqualStrings("github", view.servers[0].name);
            try std.testing.expectEqual(@as(usize, 1), view.tools.len);
            try std.testing.expectEqualStrings("github_issue", view.tools[0].name);
        }
    };
    const profile = profiles.Profile{ .name = "reviewer", .description = "Reviewer", .source = .home, .mcp_servers = &.{"github"} };
    // Without in-place resizing, a list can't shrink where it is, so every
    // allocation the narrowing needs can fail.
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, Narrow.run, .{&profile});
}

test "authority capture permits registry access and rejects changed work" {
    const Fixture = struct {
        const Change = enum { none, finish, replace, permission, sibling, host_failure };
        store: child_state.Store,
        change: Change,
        calls: usize = 0,

        fn resolve(raw: ?*anyopaque, alloc: Allocator, _: []const u8) HostResolveError!HostAuthority {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            var lock = self.store.acquireLock();
            defer lock.release();
            var registry = self.store.load(alloc) catch return error.HostAuthorityUnavailable;
            defer registry.deinit(alloc);
            switch (self.change) {
                .none => {},
                .host_failure => return error.HostAuthorityUnavailable,
                .finish, .replace => {
                    registry.finish(alloc, "authority-child", "work-one", .completed, null) catch
                        return error.HostAuthorityUnavailable;
                    if (self.change != .finish) {
                        var work = child_state.ActiveWork{
                            .id = try alloc.dupe(u8, "work-two"),
                            .message = try alloc.dupe(u8, "replacement"),
                            .created_at_ms = 2,
                        };
                        defer work.deinit(alloc);
                        _ = registry.startPersistentWork(alloc, "worker", null, work) catch
                            return error.HostAuthorityUnavailable;
                    }
                },
                .permission => {
                    registry.children[0].active.?.permission_mode = .auto;
                    registry.generation += 1;
                },
                .sibling => {
                    var work = child_state.ActiveWork{
                        .id = try alloc.dupe(u8, "sibling-work"),
                        .message = try alloc.dupe(u8, "independent work"),
                        .created_at_ms = 2,
                    };
                    defer work.deinit(alloc);
                    registry.appendOneOff(alloc, "authority-sibling", work) catch
                        return error.HostAuthorityUnavailable;
                },
            }
            self.store.save(alloc, registry) catch return error.HostAuthorityUnavailable;
            return HostAuthority.capture(alloc, &.{ "read_file", "subagent" }, &.{}, .{}, &.{}) catch
                return error.OutOfMemory;
        }
    };

    const alloc = std.testing.allocator;
    for (std.enums.values(Fixture.Change)) |change| {
        // A parent for each change: v2 children are never removed (D22).
        var parent: child_state.TestParent = undefined;
        try parent.init(alloc);
        defer parent.deinit();
        const store = parent.stateStore();
        var registry = try child_state.Registry.init(alloc, parent.parent.id());
        defer registry.deinit(alloc);
        var work = child_state.ActiveWork{
            .id = try alloc.dupe(u8, "work-one"),
            .message = try alloc.dupe(u8, "original"),
            .permission_mode = .ask,
            .created_at_ms = 1,
        };
        defer work.deinit(alloc);
        try registry.appendPersistent(alloc, "authority-child", "worker", "", work);
        try store.save(alloc, registry);
        var fixture = Fixture{ .store = store, .change = change };
        var resolver = Resolver{
            .children = &parent.children,
            .root_id = parent.parent.id(),
            .host = .{ .context = &fixture, .resolve_fn = Fixture.resolve },
        };
        try std.testing.expectError(error.ChildNotAttached, resolver.resolve(alloc, "missing-child"));
        try std.testing.expectEqual(@as(usize, 0), fixture.calls);
        switch (change) {
            .finish, .replace => try std.testing.expectError(
                error.ChildNotAttached,
                resolver.resolve(alloc, "authority-child"),
            ),
            .host_failure => try std.testing.expectError(
                error.HostAuthorityUnavailable,
                resolver.resolve(alloc, "authority-child"),
            ),
            .none, .permission, .sibling => {
                var snapshot = try resolver.resolve(alloc, "authority-child");
                defer snapshot.deinit(alloc);
                try std.testing.expectEqual(
                    if (change == .permission) types.PermissionMode.auto else types.PermissionMode.ask,
                    snapshot.permission_mode,
                );
                // A child keeps `subagent` like any tool its parent holds.
                try std.testing.expectEqual(@as(usize, 2), snapshot.tools.len);
                try std.testing.expectEqualStrings("read_file", snapshot.tools[0]);
                try std.testing.expectEqualStrings("subagent", snapshot.tools[1]);
                var current = try store.load(alloc);
                defer current.deinit(alloc);
                var host = try HostAuthority.capture(alloc, &.{ "read_file", "subagent" }, &.{}, .{}, &.{});
                defer host.deinit(alloc);
                try std.testing.expectEqual(
                    authorityGeneration("authority-child", parent.parent.id(), current.generation, host.generation),
                    snapshot.generation,
                );
            },
        }
        try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    }
}

test "a subagent's profile narrows its tools, integrations, MCP view, and mode, and keeps them while it runs" {
    const Host = struct {
        fn resolve(_: ?*anyopaque, alloc: Allocator, root_id: []const u8) HostResolveError!HostAuthority {
            var servers = [_]mcp_access.ServerIdentity{
                .{ .name = @constCast("github"), .source = .profile, .scope = .profile, .connection_generation = 1, .catalog_generation = 1, .auth_generation = 1 },
                .{ .name = @constCast("slack"), .source = .profile, .scope = .profile, .connection_generation = 1, .catalog_generation = 1, .auth_generation = 1 },
            };
            var tools = [_]mcp_access.ToolIdentity{
                .{ .name = @constCast("github_issue"), .server_name = @constCast("github") },
                .{ .name = @constCast("slack_post"), .server_name = @constCast("slack") },
            };
            const view = mcp_access.View{
                .runtime_generation = 1,
                .owner_id = @constCast(root_id),
                .parent_id = @constCast(root_id),
                .servers = &servers,
                .tools = &tools,
            };
            return HostAuthority.captureWithPermissionStateAndMcpView(alloc, &.{ "read_file", "write_file", "subagent" }, &.{ "github_issue", "slack_post" }, .{}, &.{}, .{}, &view) catch
                return error.OutOfMemory;
        }
    };
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "fxhome/.fx/agents/reviewer");
    const writeProfile = struct {
        fn run(dir: std.Io.Dir, json: []const u8) !void {
            var file = try dir.createFile(io_mod.getIo(), "fxhome/.fx/agents/reviewer/profile.json", .{});
            defer file.close(io_mod.getIo());
            try file.writeStreamingAll(io_mod.getIo(), json);
        }
    }.run;
    try writeProfile(tmp.dir, "{\"description\": \"Reviewer\", \"tools\": [\"read_file\"], \"mcp_servers\": [\"github\"], \"permission_mode\": \"auto\"}");
    const fx_home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "fxhome");
    defer alloc.free(fx_home);
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    const store = parent.stateStore();
    var registry = try child_state.Registry.init(alloc, parent.parent.id());
    defer registry.deinit(alloc);
    var work = child_state.ActiveWork{ .id = try alloc.dupe(u8, "work-1"), .message = try alloc.dupe(u8, "review"), .permission_mode = .ask, .created_at_ms = 1 };
    defer work.deinit(alloc);
    try registry.appendOneOff(alloc, "profiled-child", work);
    try registry.setProfile(alloc, "profiled-child", "reviewer");
    try registry.appendOneOff(alloc, "plain-child", work);
    try store.save(alloc, registry);

    var cache: ProfileCache = .{ .alloc = alloc, .roots = .{ .home = fx_home, .workspace_root = null } };
    defer cache.deinit();
    var resolver = Resolver{ .children = &parent.children, .root_id = parent.parent.id(), .host = .{ .resolve_fn = Host.resolve }, .profiles = &cache };

    var profiled = try resolver.resolve(alloc, "profiled-child");
    defer profiled.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), profiled.tools.len);
    try std.testing.expectEqualStrings("read_file", profiled.tools[0]);
    // An integration is an MCP tool, kept by the server the MCP view names.
    try std.testing.expectEqual(@as(usize, 1), profiled.integrations.len);
    try std.testing.expectEqualStrings("github_issue", profiled.integrations[0]);
    // Its MCP view has only the servers its profile allows, and their tools.
    try std.testing.expectEqual(@as(usize, 1), profiled.mcp_view.?.servers.len);
    try std.testing.expectEqualStrings("github", profiled.mcp_view.?.servers[0].name);
    try std.testing.expectEqual(@as(usize, 1), profiled.mcp_view.?.tools.len);
    try std.testing.expectEqualStrings("github_issue", profiled.mcp_view.?.tools[0].name);
    // The profile's own mode wins, even looser than the parent's.
    try std.testing.expectEqual(types.PermissionMode.auto, profiled.permission_mode);

    // Saving the profile again does not change a child that started in it.
    try writeProfile(tmp.dir, "{\"description\": \"Reviewer\", \"tools\": [\"write_file\"]}");
    var again = try resolver.resolve(alloc, "profiled-child");
    defer again.deinit(alloc);
    try std.testing.expectEqualStrings("read_file", again.tools[0]);

    var plain = try resolver.resolve(alloc, "plain-child");
    defer plain.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), plain.tools.len);
    try std.testing.expectEqual(types.PermissionMode.ask, plain.permission_mode);
    try std.testing.expectEqual(@as(usize, 2), plain.mcp_view.?.servers.len);
    try std.testing.expectEqual(@as(usize, 2), plain.mcp_view.?.tools.len);

    // Without a place to load it, a profiled child gets no authority at all.
    resolver.profiles = null;
    try std.testing.expectError(error.HostAuthorityUnavailable, resolver.resolve(alloc, "profiled-child"));
}

test "a profile that sets tools or MCP servers decides them from fx's own, and one that sets neither copies its parent" {
    const Views = struct {
        fn capture(alloc: Allocator, root_id: []const u8, tools: []const []const u8, server_names: []const []const u8) HostResolveError!HostAuthority {
            var servers: [2]mcp_access.ServerIdentity = undefined;
            var server_tools: [2]mcp_access.ToolIdentity = undefined;
            for (server_names, 0..) |name, index| {
                servers[index] = .{ .name = @constCast(name), .source = .profile, .scope = .profile, .connection_generation = 1, .catalog_generation = 1, .auth_generation = 1 };
                server_tools[index] = .{ .name = @constCast(if (std.mem.eql(u8, name, "github")) "github_issue" else "slack_post"), .server_name = @constCast(name) };
            }
            const view = mcp_access.View{
                .runtime_generation = 1,
                .owner_id = @constCast(root_id),
                .parent_id = @constCast(root_id),
                .servers = servers[0..server_names.len],
                .tools = server_tools[0..server_names.len],
            };
            return HostAuthority.captureWithPermissionStateAndMcpView(alloc, tools, server_names, .{}, &.{}, .{}, &view) catch
                return error.OutOfMemory;
        }
        // The parent has only read_file and GitHub.
        fn parent(_: ?*anyopaque, alloc: Allocator, root_id: []const u8) HostResolveError!HostAuthority {
            return capture(alloc, root_id, &.{"read_file"}, &.{"github"});
        }
        // fx has more tools and both servers.
        fn base(_: ?*anyopaque, alloc: Allocator, root_id: []const u8) HostResolveError!HostAuthority {
            return capture(alloc, root_id, &.{ "read_file", "write_file", "shell", "subagent" }, &.{ "github", "slack" });
        }
    };
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const profiles_json = [_]struct { name: []const u8, json: []const u8 }{
        .{ .name = "builder", .json = "{\"description\": \"Builder\", \"tools\": [\"*\", \"!subagent\"], \"mcp_servers\": [\"slack\"]}" },
        .{ .name = "quiet", .json = "{\"description\": \"Sets nothing\"}" },
    };
    for (profiles_json) |entry| {
        var path_buf: [96]u8 = undefined;
        const dir_path = try std.mem.print(&path_buf, "fxhome/.fx/agents/{s}", .{entry.name});
        try tmp.dir.createDirPath(io_mod.getIo(), dir_path);
        var file_buf: [128]u8 = undefined;
        const file_path = try std.mem.print(&file_buf, "{s}/profile.json", .{dir_path});
        var file = try tmp.dir.createFile(io_mod.getIo(), file_path, .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), entry.json);
    }
    const fx_home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "fxhome");
    defer alloc.free(fx_home);
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    const store = parent.stateStore();
    var registry = try child_state.Registry.init(alloc, parent.parent.id());
    defer registry.deinit(alloc);
    var work = child_state.ActiveWork{ .id = try alloc.dupe(u8, "work-1"), .message = try alloc.dupe(u8, "build"), .permission_mode = .ask, .created_at_ms = 1 };
    defer work.deinit(alloc);
    try registry.appendOneOff(alloc, "builder-child", work);
    try registry.setProfile(alloc, "builder-child", "builder");
    try registry.appendOneOff(alloc, "quiet-child", work);
    try registry.setProfile(alloc, "quiet-child", "quiet");
    try store.save(alloc, registry);

    var cache: ProfileCache = .{ .alloc = alloc, .roots = .{ .home = fx_home, .workspace_root = null } };
    defer cache.deinit();
    var resolver = Resolver{
        .children = &parent.children,
        .root_id = parent.parent.id(),
        .host = .{ .resolve_fn = Views.parent, .base_fn = Views.base },
        .profiles = &cache,
    };

    // The builder's tools and servers are its profile's, past the parent's.
    var builder = try resolver.resolve(alloc, "builder-child");
    defer builder.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), builder.tools.len);
    for ([_][]const u8{ "read_file", "write_file", "shell" }) |name| try std.testing.expect(contains(builder.tools, name));
    try std.testing.expect(!contains(builder.tools, "subagent"));
    try std.testing.expectEqual(@as(usize, 1), builder.integrations.len);
    try std.testing.expectEqualStrings("slack", builder.integrations[0]);
    try std.testing.expectEqual(@as(usize, 1), builder.mcp_view.?.servers.len);
    try std.testing.expectEqualStrings("slack", builder.mcp_view.?.servers[0].name);

    // A profile that sets neither is a copy of its parent.
    var quiet = try resolver.resolve(alloc, "quiet-child");
    defer quiet.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), quiet.tools.len);
    try std.testing.expectEqualStrings("read_file", quiet.tools[0]);
    try std.testing.expectEqualStrings("github", quiet.integrations[0]);
    try std.testing.expectEqualStrings("github", quiet.mcp_view.?.servers[0].name);

    // Without fx's own set to choose from, a profile narrows its parent's.
    resolver.host.base_fn = null;
    var narrowed = try resolver.resolve(alloc, "builder-child");
    defer narrowed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), narrowed.tools.len);
    try std.testing.expectEqualStrings("read_file", narrowed.tools[0]);
    try std.testing.expectEqual(@as(usize, 0), narrowed.integrations.len);
}

test "a turn no work started is limited by the child's profile and the user's mode, and only for a known child" {
    const Host = struct {
        fn resolve(_: ?*anyopaque, alloc: Allocator, _: []const u8) HostResolveError!HostAuthority {
            return HostAuthority.capture(alloc, &.{ "read_file", "write_file", "subagent" }, &.{ "github", "slack" }, .{}, &.{}) catch
                return error.OutOfMemory;
        }
    };
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "fxhome/.fx/agents/reviewer");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "fxhome/.fx/agents/reviewer/profile.json", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "{\"description\": \"Reviewer\", \"tools\": [\"read_file\"], \"permission_mode\": \"auto\"}");
    }
    const fx_home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "fxhome");
    defer alloc.free(fx_home);
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    const store = parent.stateStore();
    var registry = try child_state.Registry.init(alloc, parent.parent.id());
    defer registry.deinit(alloc);
    var work = child_state.ActiveWork{ .id = try alloc.dupe(u8, "work-1"), .message = try alloc.dupe(u8, "review"), .permission_mode = .ask, .created_at_ms = 1 };
    defer work.deinit(alloc);
    try registry.appendOneOff(alloc, "profiled-child", work);
    try registry.setProfile(alloc, "profiled-child", "reviewer");
    try registry.appendOneOff(alloc, "plain-child", work);
    // Main's work on both has ended.
    try registry.finish(alloc, "profiled-child", "work-1", .completed, null);
    try registry.finish(alloc, "plain-child", "work-1", .completed, null);
    try store.save(alloc, registry);

    var cache: ProfileCache = .{ .alloc = alloc, .roots = .{ .home = fx_home, .workspace_root = null } };
    defer cache.deinit();
    var resolver = Resolver{ .children = &parent.children, .root_id = parent.parent.id(), .host = .{ .resolve_fn = Host.resolve }, .profiles = &cache };

    // A run's authority needs main's work in flight.
    try std.testing.expectError(error.ChildNotAttached, resolver.resolve(alloc, "profiled-child"));

    // A turn the user typed is still narrowed by the profile, whose own
    // mode wins.
    var profiled = try resolver.resolveForUser(alloc, "profiled-child", .ask);
    defer profiled.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), profiled.tools.len);
    try std.testing.expectEqualStrings("read_file", profiled.tools[0]);
    try std.testing.expectEqual(types.PermissionMode.auto, profiled.permission_mode);

    // Without a profile the user's mode decides, and nesting stays out.
    var plain = try resolver.resolveForUser(alloc, "plain-child", .ask);
    defer plain.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), plain.tools.len);
    try std.testing.expectEqual(types.PermissionMode.ask, plain.permission_mode);

    try std.testing.expectError(error.ChildNotAttached, resolver.resolveForUser(alloc, "missing-child", .ask));

    // A mode the user chose on a child's own screen wins over its profile's,
    // and leaves other children alone.
    const Own = struct {
        fn mode(_: ?*anyopaque, child_id: []const u8) ?types.PermissionMode {
            return if (std.mem.eql(u8, child_id, "profiled-child")) .yolo else null;
        }
    };
    resolver.host.child_permission_mode_fn = Own.mode;
    var chosen = try resolver.resolveForUser(alloc, "profiled-child", .ask);
    defer chosen.deinit(alloc);
    try std.testing.expectEqual(types.PermissionMode.yolo, chosen.permission_mode);
    try std.testing.expectEqual(@as(usize, 1), chosen.tools.len);
    var unchanged = try resolver.resolveForUser(alloc, "plain-child", .ask);
    defer unchanged.deinit(alloc);
    try std.testing.expectEqual(types.PermissionMode.ask, unchanged.permission_mode);
}

test "a child with no mode of its own follows its parent's current mode, under its profile's and its own screen's" {
    const Host = struct {
        fn resolve(_: ?*anyopaque, alloc: Allocator, _: []const u8) HostResolveError!HostAuthority {
            return HostAuthority.capture(alloc, &.{ "read_file", "write_file" }, &.{}, .{}, &.{}) catch
                return error.OutOfMemory;
        }
        fn parentMode(context: ?*anyopaque, _: Allocator, _: []const u8) ?types.PermissionMode {
            const mode: *const ?types.PermissionMode = @ptrCast(@alignCast(context.?));
            return mode.*;
        }
        fn ownMode(_: ?*anyopaque, child_id: []const u8) ?types.PermissionMode {
            return if (std.mem.eql(u8, child_id, "plain-child")) .auto else null;
        }
    };
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "fxhome/.fx/agents/reviewer");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "fxhome/.fx/agents/reviewer/profile.json", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "{\"description\": \"Reviewer\", \"permission_mode\": \"auto\"}");
    }
    const fx_home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "fxhome");
    defer alloc.free(fx_home);
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    const store = parent.stateStore();
    var registry = try child_state.Registry.init(alloc, parent.parent.id());
    defer registry.deinit(alloc);
    // Both children's work was sent while the parent was in ask.
    var work = child_state.ActiveWork{ .id = try alloc.dupe(u8, "work-1"), .message = try alloc.dupe(u8, "build"), .permission_mode = .ask, .created_at_ms = 1 };
    defer work.deinit(alloc);
    try registry.appendOneOff(alloc, "plain-child", work);
    try registry.appendOneOff(alloc, "profiled-child", work);
    try registry.setProfile(alloc, "profiled-child", "reviewer");
    try store.save(alloc, registry);

    var cache: ProfileCache = .{ .alloc = alloc, .roots = .{ .home = fx_home, .workspace_root = null } };
    defer cache.deinit();
    var parent_mode: ?types.PermissionMode = .yolo;
    var resolver = Resolver{
        .children = &parent.children,
        .root_id = parent.parent.id(),
        .host = .{ .context = &parent_mode, .resolve_fn = Host.resolve, .parent_permission_mode_fn = Host.parentMode },
        .profiles = &cache,
    };

    // The parent loosened after the work was sent, and the child's next call
    // follows it, as does the mode the host reads for it.
    var loosened = try resolver.resolve(alloc, "plain-child");
    defer loosened.deinit(alloc);
    try std.testing.expectEqual(types.PermissionMode.yolo, loosened.permission_mode);
    try std.testing.expectEqual(types.PermissionMode.yolo, try resolver.currentMode(alloc, "plain-child"));

    // Tightening tightens it, and a turn the user typed follows the parent
    // too, not the mode its admission copied.
    parent_mode = .ask;
    var tightened = try resolver.resolve(alloc, "plain-child");
    defer tightened.deinit(alloc);
    try std.testing.expectEqual(types.PermissionMode.ask, tightened.permission_mode);
    var typed = try resolver.resolveForUser(alloc, "plain-child", .yolo);
    defer typed.deinit(alloc);
    try std.testing.expectEqual(types.PermissionMode.ask, typed.permission_mode);

    // A profile's mode wins over the parent's either way.
    var profiled = try resolver.resolve(alloc, "profiled-child");
    defer profiled.deinit(alloc);
    try std.testing.expectEqual(types.PermissionMode.auto, profiled.permission_mode);
    parent_mode = .yolo;
    try std.testing.expectEqual(types.PermissionMode.auto, try resolver.currentMode(alloc, "profiled-child"));

    // A mode chosen on the child's own screen wins over its parent's.
    resolver.host.child_permission_mode_fn = Host.ownMode;
    try std.testing.expectEqual(types.PermissionMode.auto, try resolver.currentMode(alloc, "plain-child"));
    resolver.host.child_permission_mode_fn = null;

    // Where the host can't say the parent's mode, the child keeps the one
    // its work was sent under, or the user's for a typed turn.
    parent_mode = null;
    var kept = try resolver.resolve(alloc, "plain-child");
    defer kept.deinit(alloc);
    try std.testing.expectEqual(types.PermissionMode.ask, kept.permission_mode);
    var kept_typed = try resolver.resolveForUser(alloc, "plain-child", .auto);
    defer kept_typed.deinit(alloc);
    try std.testing.expectEqual(types.PermissionMode.auto, kept_typed.permission_mode);

    // With no work and no parent mode, the host reads ask; an unknown child
    // has none.
    try registry.finish(alloc, "plain-child", "work-1", .completed, null);
    try store.save(alloc, registry);
    try std.testing.expectEqual(types.PermissionMode.ask, try resolver.currentMode(alloc, "plain-child"));
    parent_mode = .auto;
    try std.testing.expectEqual(types.PermissionMode.auto, try resolver.currentMode(alloc, "plain-child"));
    try std.testing.expectError(error.ChildNotAttached, resolver.currentMode(alloc, "missing-child"));
}
