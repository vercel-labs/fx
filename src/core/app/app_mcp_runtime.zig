const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("../hosts/host.zig");
const mcp_access = @import("../mcp/access_policy.zig");
const mcp_auth = @import("../mcp/mcp_auth.zig");
const mcp_command_provider = @import("../mcp/command_provider.zig");
const mcp_contract = @import("../mcp/mcp_contract.zig");
const elicitation = @import("../mcp/elicitation.zig");
const mcp_health = @import("../mcp/health.zig");
const mcp_model_catalog = @import("../mcp/model_catalog.zig");
const mcp_runtime = @import("../mcp/mcp_runtime.zig");
const context_limits = @import("../config/context_limits.zig");
const tool_projection = @import("../tooling/tool_projection.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const tool_set = @import("../tooling/tool_set.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const Lease = struct {
    runtime: *mcp_runtime.McpRuntime,

    pub fn deinit(self: *Lease) void {
        self.runtime.releaseUse();
        self.* = undefined;
    }
};

pub const PublishedReload = struct {
    generation: ?u64,
    health: mcp_health.StartupDecision,
    configured_server_count: usize,
    unavailable_server_names: [][]u8,

    fn init(
        alloc: Allocator,
        generation: ?u64,
        servers: []const mcp_health.ServerSnapshot,
    ) !PublishedReload {
        var unavailable_count: usize = 0;
        for (servers) |server| {
            if (isUnavailableForReload(server)) unavailable_count += 1;
        }

        const names = try alloc.alloc([]u8, unavailable_count);
        errdefer alloc.free(names);
        var initialized: usize = 0;
        errdefer for (names[0..initialized]) |name| alloc.free(name);
        for (servers) |server| {
            if (!isUnavailableForReload(server)) continue;
            names[initialized] = try alloc.dupe(u8, server.configured_name);
            initialized += 1;
        }

        return .{
            .generation = generation,
            .health = mcp_health.startupDecision(servers),
            .configured_server_count = servers.len,
            .unavailable_server_names = names,
        };
    }

    pub fn deinit(self: *PublishedReload, alloc: Allocator) void {
        for (self.unavailable_server_names) |name| alloc.free(name);
        alloc.free(self.unavailable_server_names);
        self.* = undefined;
    }
};

pub const ReloadOutcome = union(enum) {
    published: PublishedReload,
    retained_required_failure: []u8,

    pub fn deinit(self: *ReloadOutcome, alloc: Allocator) void {
        switch (self.*) {
            .published => |*published| published.deinit(alloc),
            .retained_required_failure => |message| alloc.free(message),
        }
        self.* = undefined;
    }
};

fn isUnavailableForReload(server: mcp_health.ServerSnapshot) bool {
    return server.connection != .ready and
        (server.connection != .disabled or server.required);
}

pub const ReloadCompletion = union(enum) {
    outcome: ReloadOutcome,
    failed: anyerror,

    pub fn deinit(self: *ReloadCompletion, alloc: Allocator) void {
        switch (self.*) {
            .outcome => |*outcome| outcome.deinit(alloc),
            .failed => {},
        }
        self.* = undefined;
    }
};

const PendingResult = union(enum) {
    outcome: ReloadOutcome,
    failed: anyerror,
    cancelled,
};

const PendingReload = struct {
    owner: *State,
    alloc: Allocator,
    elicitation_capabilities: elicitation.Capabilities,
    loader: mcp_runtime.LoadRuntimeFn,
    registry: tool_dispatch.Registry,
    captured_at_ms: u64,
    cancel_requested: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    result: ?PendingResult = null,

    fn run(self: *PendingReload) void {
        const outcome = self.owner.reloadControlled(
            self.alloc,
            self.elicitation_capabilities,
            self.loader,
            self.registry,
            self.captured_at_ms,
            &self.cancel_requested,
            self,
        ) catch |err| {
            self.result = if (err == error.Cancelled)
                .cancelled
            else
                .{ .failed = err };
            self.done.store(true, .release);
            return;
        };
        self.result = .{ .outcome = outcome };
        self.done.store(true, .release);
    }

    fn join(self: *PendingReload) void {
        if (comptime builtin.single_threaded) {
            std.debug.assert(self.thread == null);
            return;
        }
        if (self.thread) |thread| {
            self.thread = null;
            thread.join();
        }
    }

    fn deinit(self: *PendingReload) void {
        self.join();
        if (self.result) |*result| switch (result.*) {
            .outcome => |*outcome| outcome.deinit(self.alloc),
            .failed, .cancelled => {},
        };
        self.alloc.destroy(self);
    }
};

pub const AuthenticationCompletion = struct {
    server_name: []u8,
    result: anyerror!mcp_auth.AuthenticationResult,

    pub fn deinit(self: *AuthenticationCompletion, alloc: Allocator) void {
        alloc.free(self.server_name);
        deinitAuthenticationResult(self.result);
        self.* = undefined;
    }
};

const PendingAuthentication = struct {
    alloc: Allocator,
    server_name: []u8,
    lease: Lease,
    opener: host.UrlOpener,
    cancel_requested: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    result: ?(anyerror!mcp_auth.AuthenticationResult) = null,

    fn run(self: *PendingAuthentication) void {
        self.result = self.lease.runtime.authenticateServerControlled(
            self.server_name,
            self,
            openUrl,
            &self.cancel_requested,
        );
        self.done.store(true, .release);
    }

    fn openUrl(
        raw: ?*anyopaque,
        alloc: Allocator,
        url: []const u8,
    ) anyerror!bool {
        const self: *PendingAuthentication = @ptrCast(@alignCast(raw.?));
        return self.opener.open(alloc, url);
    }

    fn join(self: *PendingAuthentication) void {
        if (comptime builtin.single_threaded) {
            std.debug.assert(self.thread == null);
            return;
        }
        if (self.thread) |thread| {
            self.thread = null;
            thread.join();
        }
    }

    fn deinit(self: *PendingAuthentication) void {
        self.join();
        if (self.result) |result| deinitAuthenticationResult(result);
        self.lease.deinit();
        self.alloc.free(self.server_name);
        self.alloc.destroy(self);
    }
};

fn deinitAuthenticationResult(result: anyerror!mcp_auth.AuthenticationResult) void {
    var owned = result catch return;
    owned.deinit();
}

/// Owns the native profile MCP runtime. All transport work and retirement happen
/// after releasing this state lock; the lock protects only pointer publication.
pub const State = struct {
    lock: std.Io.RwLock = .init,
    runtime: ?*mcp_runtime.McpRuntime = null,
    pending_reload: ?*PendingReload = null,
    pending_authentication: ?*PendingAuthentication = null,

    pub fn installInitial(self: *State, runtime: ?*mcp_runtime.McpRuntime) void {
        std.debug.assert(self.runtime == null);
        self.runtime = runtime;
    }

    pub fn startDiscovery(self: *State, registry: tool_dispatch.Registry) void {
        var lease = self.acquire() orelse return;
        defer lease.deinit();
        lease.runtime.startDiscovery(registry);
    }

    pub fn acquire(self: *State) ?Lease {
        self.lock.lockSharedUncancelable(io_mod.getIo());
        const runtime = self.runtime orelse {
            self.lock.unlockShared(io_mod.getIo());
            return null;
        };
        if (!runtime.acquireUse()) {
            self.lock.unlockShared(io_mod.getIo());
            return null;
        }
        self.lock.unlockShared(io_mod.getIo());
        return .{ .runtime = runtime };
    }

    pub fn hasTool(self: *State, name: []const u8, access: tool_mcp_runtime.Access) bool {
        var lease = self.acquire() orelse return false;
        defer lease.deinit();
        return lease.runtime.hasToolWithAccess(name, access);
    }

    pub fn validateTool(
        self: *State,
        arena: Allocator,
        name: []const u8,
        arguments_json: []const u8,
        access: tool_mcp_runtime.Access,
    ) !tool_mcp_runtime.ValidationResult {
        var lease = self.acquire() orelse return .not_available;
        defer lease.deinit();
        return lease.runtime.validateToolArgumentsByNameWithAccess(
            arena,
            name,
            arguments_json,
            access,
        );
    }

    pub fn callTool(
        self: *State,
        arena: Allocator,
        name: []const u8,
        arguments_json: []const u8,
        max_tool_result_bytes: usize,
        options: tool_mcp_runtime.CallOptions,
    ) !?tool_mcp_runtime.CallResult {
        var lease = self.acquire() orelse return null;
        defer lease.deinit();
        return lease.runtime.callToolByNameWithOptions(
            arena,
            name,
            arguments_json,
            max_tool_result_bytes,
            options,
        );
    }

    pub fn searchTools(
        self: *State,
        arena: Allocator,
        query: []const u8,
        limit: usize,
        permission_rules: types.PermissionRuleSet,
        limits: context_limits.Values,
        access: tool_mcp_runtime.Access,
    ) !tool_mcp_runtime.SearchResult {
        var lease = self.acquire() orelse
            return .{ .model_output = try arena.dupe(u8, "{\"tools\":[],\"count\":0}") };
        defer lease.deinit();
        return lease.runtime.searchTools(arena, query, limit, permission_rules, limits, access);
    }

    pub fn toolSchema(
        self: *State,
        arena: Allocator,
        name: []const u8,
        permission_rules: types.PermissionRuleSet,
        limits: context_limits.Values,
        access: tool_mcp_runtime.Access,
    ) !?tool_mcp_runtime.ToolSchemaResult {
        var lease = self.acquire() orelse return null;
        defer lease.deinit();
        return lease.runtime.toolSchemaJsonByNameWithAccess(
            arena,
            name,
            permission_rules,
            limits,
            access,
        );
    }

    pub fn renderHealth(self: *State, alloc: Allocator) ![]u8 {
        var lease = self.acquire() orelse return alloc.dupe(u8, "No MCP servers configured.\n");
        defer lease.deinit();
        return lease.runtime.listServersAndTools(alloc);
    }

    pub fn renderHealthSummary(self: *State, alloc: Allocator) ![]u8 {
        var lease = self.acquire() orelse return mcp_health.renderSummary(
            alloc,
            .{ .captured_at_ms = 0, .servers = &.{} },
        );
        defer lease.deinit();
        var snapshot = try lease.runtime.snapshotHealth(
            alloc,
            @intCast(@max(io_mod.milliTimestamp(), 0)),
        );
        defer snapshot.deinit(alloc);
        return mcp_health.renderSummary(alloc, snapshot);
    }

    pub fn snapshotToolNames(
        self: *State,
        alloc: Allocator,
        permission_rules: types.PermissionRuleSet,
    ) ![][]u8 {
        var lease = self.acquire() orelse return alloc.alloc([]u8, 0);
        defer lease.deinit();
        return lease.runtime.snapshotToolNames(alloc, permission_rules);
    }

    pub fn snapshotAccessView(
        self: *State,
        alloc: Allocator,
        owner_id: []const u8,
        parent_id: []const u8,
        permission_rules: types.PermissionRuleSet,
        features_visible: bool,
    ) !?mcp_access.View {
        var lease = self.acquire() orelse return null;
        defer lease.deinit();
        const view = try lease.runtime.snapshotAccessView(
            alloc,
            owner_id,
            parent_id,
            permission_rules,
            features_visible,
        );
        return view;
    }

    pub fn snapshotModelCatalog(
        self: *State,
        alloc: Allocator,
        permission_rules: types.PermissionRuleSet,
        include_ask_deferred: bool,
    ) !mcp_model_catalog.Snapshot {
        var lease = self.acquire() orelse return mcp_model_catalog.Snapshot.empty(alloc);
        defer lease.deinit();
        return lease.runtime.snapshotModelCatalog(
            alloc,
            permission_rules,
            include_ask_deferred,
        );
    }

    pub fn waitForRequired(
        self: *State,
        alloc: Allocator,
        cancel_flag: ?*std.atomic.Value(bool),
        captured_at_ms: u64,
    ) !?[]u8 {
        var lease = self.acquire() orelse return null;
        defer lease.deinit();
        try lease.runtime.waitForDiscovery(cancel_flag);
        return lease.runtime.requiredStartupFailure(alloc, captured_at_ms);
    }

    pub fn startAuthentication(
        self: *State,
        alloc: Allocator,
        server_name: []const u8,
        opener: host.UrlOpener,
    ) !mcp_command_provider.AuthenticationStart {
        const pending = try alloc.create(PendingAuthentication);
        var pending_owned = true;
        errdefer if (pending_owned) alloc.destroy(pending);
        const owned_name = try alloc.dupe(u8, server_name);
        var name_owned = true;
        errdefer if (name_owned) alloc.free(owned_name);

        self.lock.lockUncancelable(io_mod.getIo());
        if (self.pending_authentication != null or self.pending_reload != null) {
            self.lock.unlock(io_mod.getIo());
            alloc.free(owned_name);
            alloc.destroy(pending);
            return .busy;
        }
        const runtime = self.runtime orelse {
            self.lock.unlock(io_mod.getIo());
            return error.McpServerNotFound;
        };
        if (!runtime.acquireUse()) {
            self.lock.unlock(io_mod.getIo());
            return error.McpServerNotFound;
        }
        runtime.validateAuthenticationServer(server_name) catch |err| {
            runtime.releaseUse();
            self.lock.unlock(io_mod.getIo());
            return err;
        };
        pending.* = .{
            .alloc = alloc,
            .server_name = owned_name,
            .lease = .{ .runtime = runtime },
            .opener = opener,
        };
        pending_owned = false;
        name_owned = false;
        self.pending_authentication = pending;
        self.lock.unlock(io_mod.getIo());

        if (comptime builtin.single_threaded) {
            pending.run();
        } else {
            pending.thread = std.Thread.spawn(.{}, PendingAuthentication.run, .{pending}) catch |err| {
                self.lock.lockUncancelable(io_mod.getIo());
                if (self.pending_authentication == pending) self.pending_authentication = null;
                self.lock.unlock(io_mod.getIo());
                pending.deinit();
                return err;
            };
        }
        return .started;
    }

    pub fn takeAuthenticationCompletion(self: *State) ?AuthenticationCompletion {
        self.lock.lockUncancelable(io_mod.getIo());
        const pending = self.pending_authentication orelse {
            self.lock.unlock(io_mod.getIo());
            return null;
        };
        if (!pending.done.load(.acquire)) {
            self.lock.unlock(io_mod.getIo());
            return null;
        }
        self.pending_authentication = null;
        self.lock.unlock(io_mod.getIo());

        pending.join();
        const result = pending.result.?;
        pending.result = null;
        const server_name = pending.server_name;
        pending.lease.deinit();
        pending.alloc.destroy(pending);
        return .{
            .server_name = server_name,
            .result = result,
        };
    }

    pub fn authenticationPending(self: *State, server_name: []const u8) bool {
        self.lock.lockSharedUncancelable(io_mod.getIo());
        defer self.lock.unlockShared(io_mod.getIo());
        const pending = self.pending_authentication orelse return false;
        return std.mem.eql(u8, pending.server_name, server_name);
    }

    pub fn reload(
        self: *State,
        alloc: Allocator,
        elicitation_capabilities: elicitation.Capabilities,
        loader: mcp_runtime.LoadRuntimeFn,
        registry: tool_dispatch.Registry,
        captured_at_ms: u64,
    ) !ReloadOutcome {
        var cancel_requested = std.atomic.Value(bool).init(false);
        return self.reloadControlled(
            alloc,
            elicitation_capabilities,
            loader,
            registry,
            captured_at_ms,
            &cancel_requested,
            null,
        );
    }

    pub fn beginReload(
        self: *State,
        alloc: Allocator,
        elicitation_capabilities: elicitation.Capabilities,
        loader: mcp_runtime.LoadRuntimeFn,
        registry: tool_dispatch.Registry,
        captured_at_ms: u64,
    ) !void {
        self.cancelPendingReload();

        const pending = try alloc.create(PendingReload);
        pending.* = .{
            .owner = self,
            .alloc = alloc,
            .elicitation_capabilities = elicitation_capabilities,
            .loader = loader,
            .registry = registry,
            .captured_at_ms = captured_at_ms,
        };
        self.lock.lockUncancelable(io_mod.getIo());
        std.debug.assert(self.pending_reload == null);
        const authentication = self.pending_authentication;
        self.pending_authentication = null;
        self.pending_reload = pending;
        self.lock.unlock(io_mod.getIo());
        if (authentication) |task| cancelAndDeinitAuthentication(task, "reload");

        if (comptime builtin.single_threaded) {
            pending.run();
        } else {
            pending.thread = std.Thread.spawn(.{}, PendingReload.run, .{pending}) catch |err| {
                self.lock.lockUncancelable(io_mod.getIo());
                if (self.pending_reload == pending) self.pending_reload = null;
                self.lock.unlock(io_mod.getIo());
                alloc.destroy(pending);
                return err;
            };
        }
    }

    pub fn takeReloadCompletion(self: *State) ?ReloadCompletion {
        self.lock.lockUncancelable(io_mod.getIo());
        const pending = self.pending_reload orelse {
            self.lock.unlock(io_mod.getIo());
            return null;
        };
        if (!pending.done.load(.acquire)) {
            self.lock.unlock(io_mod.getIo());
            return null;
        }
        self.pending_reload = null;
        self.lock.unlock(io_mod.getIo());

        pending.join();
        const result = pending.result.?;
        pending.result = null;
        pending.alloc.destroy(pending);
        return switch (result) {
            .outcome => |outcome| .{ .outcome = outcome },
            .failed => |err| .{ .failed = err },
            .cancelled => null,
        };
    }

    fn cancelPendingReload(self: *State) void {
        self.lock.lockUncancelable(io_mod.getIo());
        const pending = self.pending_reload;
        if (pending) |task| task.cancel_requested.store(true, .release);
        self.pending_reload = null;
        self.lock.unlock(io_mod.getIo());
        if (pending) |task| task.deinit();
    }

    fn cancelPendingAuthentication(self: *State, reason: []const u8) void {
        self.lock.lockUncancelable(io_mod.getIo());
        const pending = self.pending_authentication;
        self.pending_authentication = null;
        self.lock.unlock(io_mod.getIo());
        if (pending) |task| cancelAndDeinitAuthentication(task, reason);
    }

    fn reloadControlled(
        self: *State,
        alloc: Allocator,
        elicitation_capabilities: elicitation.Capabilities,
        loader: mcp_runtime.LoadRuntimeFn,
        registry: tool_dispatch.Registry,
        captured_at_ms: u64,
        cancel_requested: *std.atomic.Value(bool),
        pending: ?*PendingReload,
    ) !ReloadOutcome {
        if (cancel_requested.load(.acquire)) return error.Cancelled;
        const candidate = try loader(alloc, elicitation_capabilities);
        var candidate_owned = candidate != null;
        errdefer if (candidate_owned) destroyRuntime(alloc, candidate.?);
        if (cancel_requested.load(.acquire)) return error.Cancelled;

        var published = if (candidate) |runtime| published: {
            runtime.connectAllCancellable(registry, cancel_requested);
            if (cancel_requested.load(.acquire)) return error.Cancelled;
            var snapshot = try runtime.snapshotHealth(alloc, captured_at_ms);
            defer snapshot.deinit(alloc);
            const value = mcp_health.startupDecision(snapshot.servers);
            if (!mcp_health.publishCandidateForDecision(value)) {
                const failure = (try runtime.requiredStartupFailure(alloc, captured_at_ms)) orelse
                    try alloc.dupe(u8, "A required MCP server is unavailable.");
                destroyRuntime(alloc, runtime);
                candidate_owned = false;
                return .{ .retained_required_failure = failure };
            }
            break :published try PublishedReload.init(
                alloc,
                runtime.generation,
                snapshot.servers,
            );
        } else try PublishedReload.init(alloc, null, &.{});
        errdefer published.deinit(alloc);

        self.lock.lockUncancelable(io_mod.getIo());
        if (cancel_requested.load(.acquire) or
            (pending != null and self.pending_reload != pending.?))
        {
            self.lock.unlock(io_mod.getIo());
            return error.Cancelled;
        }
        const previous = self.runtime;
        self.runtime = candidate;
        self.lock.unlock(io_mod.getIo());
        candidate_owned = false;

        if (previous) |runtime| destroyRuntime(alloc, runtime);
        return .{ .published = published };
    }

    pub fn deinit(self: *State, alloc: Allocator) void {
        self.cancelPendingAuthentication("shutdown");
        self.cancelPendingReload();
        self.lock.lockUncancelable(io_mod.getIo());
        const previous = self.runtime;
        self.runtime = null;
        self.lock.unlock(io_mod.getIo());
        if (previous) |runtime| destroyRuntime(alloc, runtime);
        self.* = .{};
    }
};

fn cancelAndDeinitAuthentication(
    pending: *PendingAuthentication,
    reason: []const u8,
) void {
    debug_trace.logf(
        "mcp",
        "discarding pending authentication server={s} reason={s}",
        .{ pending.server_name, reason },
    );
    pending.cancel_requested.store(true, .release);
    pending.deinit();
}

pub fn buildModelToolProjection(
    state: *State,
    alloc: Allocator,
    advertisement_set: tool_set.ToolSet,
    options: tool_projection.Options,
) !tool_projection.EffectiveToolProjection {
    var lease = state.acquire();
    defer if (lease) |*active| active.deinit();
    var effective = options;
    effective.mcp_runtime = if (lease) |active| active.runtime else null;
    return tool_projection.buildModelToolProjectionForSet(
        alloc,
        advertisement_set,
        effective,
    );
}

fn destroyRuntime(alloc: Allocator, runtime: *mcp_runtime.McpRuntime) void {
    runtime.retireAndWait();
    runtime.deinit();
    alloc.destroy(runtime);
}

const TestReloadMode = enum {
    parse_failure,
    required_disabled,
    optional_failed,
    empty,
    delayed_empty,
    stalled_candidate,
};

var test_reload_mode: TestReloadMode = .empty;

fn loadTestReloadRuntime(
    alloc: Allocator,
    _: elicitation.Capabilities,
) !?*mcp_runtime.McpRuntime {
    switch (test_reload_mode) {
        .parse_failure => return error.McpConfigInvalidJson,
        .empty => return null,
        .delayed_empty => {
            io_mod.sleep(100 * std.time.ns_per_ms);
            return null;
        },
        .required_disabled, .optional_failed, .stalled_candidate => {},
    }
    const runtime = try alloc.create(mcp_runtime.McpRuntime);
    errdefer alloc.destroy(runtime);
    runtime.* = mcp_runtime.McpRuntime.init(alloc);
    errdefer runtime.deinit();
    const name = try alloc.dupe(u8, "candidate");
    errdefer alloc.free(name);
    const command = try alloc.dupe(
        u8,
        switch (test_reload_mode) {
            .optional_failed => "__fx_missing_mcp_executable__",
            .stalled_candidate => "awk",
            else => "disabled",
        },
    );
    errdefer alloc.free(command);
    const args = if (test_reload_mode == .stalled_candidate) args: {
        const values = try alloc.alloc([]const u8, 1);
        errdefer alloc.free(values);
        values[0] = try alloc.dupe(u8, "{}");
        break :args values;
    } else &.{};
    errdefer if (args.len > 0) {
        for (args) |arg| alloc.free(arg);
        alloc.free(args);
    };
    const config = mcp_contract.McpServerConfig{
        .name = name,
        .command = command,
        .args = args,
        .enabled = test_reload_mode == .optional_failed or
            test_reload_mode == .stalled_candidate,
        .required = test_reload_mode == .required_disabled,
        .startup_timeout_ms = if (test_reload_mode == .stalled_candidate)
            60_000
        else
            10_000,
    };
    try runtime.addServer(config);
    return runtime;
}

test "transactional reload retains old runtime and publishes only accepted candidates" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    const original = try alloc.create(mcp_runtime.McpRuntime);
    original.* = mcp_runtime.McpRuntime.init(alloc);
    const original_generation = original.generation;
    state.installInitial(original);

    test_reload_mode = .parse_failure;
    try std.testing.expectError(
        error.McpConfigInvalidJson,
        state.reload(alloc, .{}, loadTestReloadRuntime, .{}, 10),
    );
    {
        var lease = state.acquire() orelse return error.TestUnexpectedResult;
        defer lease.deinit();
        try std.testing.expectEqual(original_generation, lease.runtime.generation);
    }

    test_reload_mode = .required_disabled;
    var rejected = try state.reload(alloc, .{}, loadTestReloadRuntime, .{}, 20);
    defer rejected.deinit(alloc);
    switch (rejected) {
        .retained_required_failure => |failure| {
            try std.testing.expect(std.mem.find(u8, failure, "candidate") != null);
            try std.testing.expect(std.mem.find(u8, failure, "required") != null);
        },
        .published => return error.TestUnexpectedResult,
    }
    {
        var lease = state.acquire() orelse return error.TestUnexpectedResult;
        defer lease.deinit();
        try std.testing.expectEqual(original_generation, lease.runtime.generation);
    }

    test_reload_mode = .optional_failed;
    var degraded = try state.reload(alloc, .{}, loadTestReloadRuntime, .{}, 30);
    defer degraded.deinit(alloc);
    switch (degraded) {
        .published => |published| {
            try std.testing.expectEqual(mcp_health.StartupDecision.degraded, published.health);
            try std.testing.expect(published.generation.? != original_generation);
            try std.testing.expectEqual(@as(usize, 1), published.configured_server_count);
            try std.testing.expectEqual(@as(usize, 1), published.unavailable_server_names.len);
            try std.testing.expectEqualStrings("candidate", published.unavailable_server_names[0]);
        },
        .retained_required_failure => return error.TestUnexpectedResult,
    }

    test_reload_mode = .empty;
    var empty = try state.reload(alloc, .{}, loadTestReloadRuntime, .{}, 40);
    defer empty.deinit(alloc);
    switch (empty) {
        .published => |published| {
            try std.testing.expectEqual(mcp_health.StartupDecision.ready, published.health);
            try std.testing.expect(published.generation == null);
            try std.testing.expectEqual(@as(usize, 0), published.configured_server_count);
            try std.testing.expectEqual(@as(usize, 0), published.unavailable_server_names.len);
        },
        .retained_required_failure => return error.TestUnexpectedResult,
    }
    try std.testing.expect(state.acquire() == null);
}

test "pending reload returns immediately and publishes one completion" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    const original = try alloc.create(mcp_runtime.McpRuntime);
    original.* = mcp_runtime.McpRuntime.init(alloc);
    const original_generation = original.generation;
    state.installInitial(original);

    test_reload_mode = .delayed_empty;
    const started_ms = io_mod.milliTimestamp();
    try state.beginReload(alloc, .{}, loadTestReloadRuntime, .{}, 50);
    try std.testing.expect(io_mod.milliTimestamp() - started_ms < 50);
    {
        var lease = state.acquire() orelse return error.TestUnexpectedResult;
        defer lease.deinit();
        try std.testing.expectEqual(original_generation, lease.runtime.generation);
    }
    try std.testing.expect(state.takeReloadCompletion() == null);

    var completion: ?ReloadCompletion = null;
    const deadline = io_mod.milliTimestamp() + 2_000;
    while (completion == null and io_mod.milliTimestamp() < deadline) {
        io_mod.sleep(std.time.ns_per_ms);
        completion = state.takeReloadCompletion();
    }
    var loaded = completion orelse return error.TestUnexpectedResult;
    defer loaded.deinit(alloc);
    switch (loaded) {
        .outcome => |outcome| switch (outcome) {
            .published => |published| {
                try std.testing.expectEqual(mcp_health.StartupDecision.ready, published.health);
                try std.testing.expect(published.generation == null);
                try std.testing.expectEqual(@as(usize, 0), published.configured_server_count);
                try std.testing.expectEqual(@as(usize, 0), published.unavailable_server_names.len);
            },
            .retained_required_failure => return error.TestUnexpectedResult,
        },
        .failed => return error.TestUnexpectedResult,
    }
    try std.testing.expect(state.takeReloadCompletion() == null);
    try std.testing.expect(state.acquire() == null);
}

test "authentication admission is busy while reload is pending" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);

    test_reload_mode = .delayed_empty;
    try state.beginReload(alloc, .{}, loadTestReloadRuntime, .{}, 55);
    try std.testing.expectEqual(
        mcp_command_provider.AuthenticationStart.busy,
        try state.startAuthentication(
            alloc,
            "fixture",
            host.unavailable_url_opener,
        ),
    );

    var completion: ?ReloadCompletion = null;
    const deadline = io_mod.milliTimestamp() + 2_000;
    while (completion == null and io_mod.milliTimestamp() < deadline) {
        io_mod.sleep(std.time.ns_per_ms);
        completion = state.takeReloadCompletion();
    }
    var loaded = completion orelse return error.TestUnexpectedResult;
    loaded.deinit(alloc);
}

test "authentication completion releases its lease and is taken once" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    const runtime = try alloc.create(mcp_runtime.McpRuntime);
    runtime.* = mcp_runtime.McpRuntime.init(alloc);
    state.installInitial(runtime);

    const pending = try alloc.create(PendingAuthentication);
    pending.* = .{
        .alloc = alloc,
        .server_name = try alloc.dupe(u8, "fixture"),
        .lease = state.acquire() orelse return error.TestUnexpectedResult,
        .opener = host.unavailable_url_opener,
        .done = .init(true),
        .result = error.Cancelled,
    };
    state.pending_authentication = pending;
    try std.testing.expect(state.authenticationPending("fixture"));
    try std.testing.expect(!state.authenticationPending("other"));

    var completion = state.takeAuthenticationCompletion() orelse
        return error.TestUnexpectedResult;
    defer completion.deinit(alloc);
    try std.testing.expectEqualStrings("fixture", completion.server_name);
    try std.testing.expectError(error.Cancelled, completion.result);
    try std.testing.expect(!state.authenticationPending("fixture"));
    try std.testing.expect(state.takeAuthenticationCompletion() == null);
}

test "superseding and deinitializing a stalled pending reload cancel before join" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    const original = try alloc.create(mcp_runtime.McpRuntime);
    original.* = mcp_runtime.McpRuntime.init(alloc);
    state.installInitial(original);

    test_reload_mode = .stalled_candidate;
    try state.beginReload(alloc, .{}, loadTestReloadRuntime, .{}, 60);
    io_mod.sleep(25 * std.time.ns_per_ms);
    test_reload_mode = .empty;
    const supersede_started_ms = io_mod.milliTimestamp();
    try state.beginReload(alloc, .{}, loadTestReloadRuntime, .{}, 70);
    try std.testing.expect(io_mod.milliTimestamp() - supersede_started_ms < 1_000);

    var completion: ?ReloadCompletion = null;
    const completion_deadline = io_mod.milliTimestamp() + 2_000;
    while (completion == null and io_mod.milliTimestamp() < completion_deadline) {
        io_mod.sleep(std.time.ns_per_ms);
        completion = state.takeReloadCompletion();
    }
    var loaded = completion orelse return error.TestUnexpectedResult;
    loaded.deinit(alloc);

    test_reload_mode = .stalled_candidate;
    try state.beginReload(alloc, .{}, loadTestReloadRuntime, .{}, 80);
    io_mod.sleep(25 * std.time.ns_per_ms);
    const deinit_started_ms = io_mod.milliTimestamp();
    state.deinit(alloc);
    try std.testing.expect(io_mod.milliTimestamp() - deinit_started_ms < 1_000);
}
