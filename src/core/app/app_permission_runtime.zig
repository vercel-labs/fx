const std = @import("std");
const agents = @import("../agents/agents.zig");
const app_worker_runtime = @import("app_worker_runtime.zig");
const config_runtime = @import("../config/config_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const permissions = @import("../permissions/permissions.zig");
const render_request = @import("../../ui/render_request.zig");
const session_commands = @import("../session/session_commands.zig");
const types = @import("../shared/types.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");

pub const State = struct {
    authority_mutex: std.Io.Mutex = .init,
    yolo_acknowledged: bool = false,
    yolo_acknowledgment_attempted: bool = false,
    yolo_warning: YoloWarning = .{},
};

pub const yolo_warning_text = permissions.yolo_warning_text;
pub const yolo_warning_compact_text = "Full access";
const yolo_warning_visible_ms: i64 = 4000;

pub fn monotonicMillis() i64 {
    const timestamp = std.Io.Clock.awake.now(io_mod.getIo());
    return @intCast(@divFloor(timestamp.nanoseconds, 1_000_000));
}

const YoloWarning = struct {
    active: bool = false,
    remaining_visible_ms: i64 = yolo_warning_visible_ms,
    visible_since_ms: ?i64 = null,

    pub fn arm(self: *YoloWarning) void {
        self.* = .{ .active = true };
    }

    pub fn clear(self: *YoloWarning) void {
        self.* = .{};
    }

    pub fn frameCommitted(self: *YoloWarning, now_ms: i64, included: bool) void {
        if (!self.active) return;
        if (included) {
            if (self.visible_since_ms == null) self.visible_since_ms = now_ms;
            return;
        }
        self.pause(now_ms);
    }

    pub fn tick(self: *YoloWarning, now_ms: i64) bool {
        if (!self.active) return false;
        const started = self.visible_since_ms orelse return false;
        const elapsed = @max(@as(i64, 0), now_ms - started);
        if (elapsed < self.remaining_visible_ms) return false;
        self.active = false;
        self.remaining_visible_ms = 0;
        self.visible_since_ms = null;
        return true;
    }

    fn pause(self: *YoloWarning, now_ms: i64) void {
        const started = self.visible_since_ms orelse return;
        const elapsed = @max(@as(i64, 0), now_ms - started);
        self.remaining_visible_ms = @max(@as(i64, 0), self.remaining_visible_ms - elapsed);
        self.visible_since_ms = null;
        if (self.remaining_visible_ms == 0) self.active = false;
    }
};

pub fn Runtime(comptime App: type) type {
    return struct {
        const AppAgent = if (@hasField(App, "main_agent")) @FieldType(App, "main_agent") else struct {};
        /// Whether this app runs subagents with modes of their own.
        const own_mode_supported = blk: {
            if (!@hasField(App, "main_agent") or !@hasField(App, "screen_owner")) break :blk false;
            const Agent = @FieldType(App, "main_agent");
            break :blk @hasField(Agent, "permission_mode") and @hasField(Agent, "child_run");
        };

        /// Whether this app keeps each instance's permission mode and session
        /// approvals on the instance. Test apps without instances keep
        /// them on the engine.
        const per_instance = own_mode_supported and
            @hasField(AppAgent, "session_grants") and @hasField(AppAgent, "role");

        /// Whether `agent` is a subagent, whose permission mode is its own.
        fn isSubagent(app: anytype, agent: anytype) bool {
            if (comptime !own_mode_supported) return false;
            if (comptime @hasField(AppAgent, "role")) return agent.role == .subagent;
            return agent != &app.main_agent;
        }

        /// The instance whose permission mode and session approvals `agent`
        /// uses: itself, or for a subagent the instance at the top of its
        /// tree. Tool checks on worker threads ask here, so it reads the
        /// root the subagent recorded before its first turn rather than
        /// walking the instances. A subagent not yet bound to a host uses
        /// the first slot, which stays valid after the first instance closes.
        fn permissionOwner(app: anytype, agent: anytype) @TypeOf(agent) {
            if (isSubagent(app, agent)) {
                if (comptime @hasField(@TypeOf(agent.*), "root_instance")) if (agent.root_instance) |root| return root;
                return &app.main_agent;
            }
            return agent;
        }

        /// Instance `owner`'s own mode, or the engine's in an app
        /// without instances.
        fn instanceMode(app: anytype, owner: anytype) types.PermissionMode {
            if (comptime per_instance) return owner.permission_mode orelse .ask;
            return app.permission_engine.mode;
        }

        fn lockAuthority(app: anytype) void {
            if (comptime @hasField(@TypeOf(app.permission_state), "authority_mutex")) {
                app.permission_state.authority_mutex.lockUncancelable(io_mod.getIo());
            }
        }

        fn unlockAuthority(app: anytype) void {
            if (comptime @hasField(@TypeOf(app.permission_state), "authority_mutex")) {
                app.permission_state.authority_mutex.unlock(io_mod.getIo());
            }
        }

        /// The permission mode of the agent on screen, for main-loop screen
        /// code.
        pub fn currentMode(app: anytype) types.PermissionMode {
            return modeOf(app, agents.screenAgentOf(app));
        }

        /// `agent`'s permission mode: an instance's own, or a
        /// subagent's own: the one chosen on its screen, else the one
        /// its run was admitted with, else its root instance's.
        pub fn modeOf(app: anytype, agent: anytype) types.PermissionMode {
            if (comptime !@hasField(App, "permission_engine")) return .ask;
            if (comptime own_mode_supported) if (isSubagent(app, agent)) {
                if (agent.permission_mode) |own| return own;
                if (agent.child_run) |*run| return run.admission.permission_mode;
            };
            return instanceMode(app, permissionOwner(app, agent));
        }

        /// Sets instance `agent`'s mode at startup or launch, before its
        /// worker runs, so without the lock or a queue sync.
        pub fn initMode(app: *App, agent: *AppAgent, mode: types.PermissionMode) void {
            if (comptime per_instance) {
                agent.permission_mode = mode;
            } else {
                app.permission_engine.mode = mode;
            }
        }

        /// The session approvals `agent`'s tool calls use.
        pub fn grantsOf(app: anytype, agent: anytype) []const types.PermissionGrant {
            if (comptime per_instance) return permissionOwner(app, agent).session_grants.items;
            return app.permission_engine.grants.items;
        }

        /// Records an "always" approval from `agent`'s turn on its
        /// permission owner.
        pub fn allowForSession(app: *App, agent: *AppAgent, tool_name: []const u8, target_path: []const u8) !void {
            lockAuthority(app);
            defer unlockAuthority(app);
            if (comptime per_instance) {
                try permissions.allowToolForSession(app.alloc, &permissionOwner(app, agent).session_grants, tool_name, target_path);
            } else {
                try app.permission_engine.allow(app.alloc, tool_name, target_path);
            }
        }

        /// Drops `agent`'s session approvals when its session ends: they
        /// last one session, and only its own end.
        pub fn clearSessionGrants(app: *App, agent: *AppAgent) void {
            lockAuthority(app);
            defer unlockAuthority(app);
            if (comptime per_instance) {
                permissions.clearAllowedTools(app.alloc, &permissionOwner(app, agent).session_grants);
            } else {
                app.permission_engine.clear(app.alloc);
            }
        }

        /// Frees `agent`'s session approvals when the agent goes. Its
        /// worker has stopped, so nothing else reads them.
        pub fn deinitSessionGrants(app: *App, agent: *AppAgent) void {
            if (comptime !per_instance) return;
            permissions.clearAllowedTools(app.alloc, &agent.session_grants);
            agent.session_grants.deinit(app.alloc);
        }

        /// The permission state `agent`'s screen reports: its permission
        /// owner's mode and approvals over the host's rules. Borrowed;
        /// never deinit it.
        pub fn viewOf(app: anytype, agent: anytype) permissions.PermissionEngine {
            if (comptime !per_instance) return app.permission_engine;
            const owner = permissionOwner(app, agent);
            return .{
                .mode = instanceMode(app, owner),
                .grants = owner.session_grants,
                .rules = app.permission_engine.rules,
            };
        }

        /// Session-scoped mode change: applies the mode and syncs queued
        /// prompts without touching the persisted preference. On a subagent
        /// it sets that subagent's own mode, which its live checks resolve on
        /// each tool call.
        pub fn setMode(app: *App, agent: *AppAgent, mode: types.PermissionMode) void {
            if (comptime own_mode_supported) if (isSubagent(app, agent)) {
                app.permission_state.authority_mutex.lockUncancelable(io_mod.getIo());
                agent.permission_mode = mode;
                app.permission_state.authority_mutex.unlock(io_mod.getIo());
                debug_trace.eventf("host", "agent_permission_mode_set", .{}, "mode={s}", .{@tagName(mode)});
                return;
            };
            lockAuthority(app);
            if (comptime per_instance) {
                agent.permission_mode = mode;
            } else {
                app.permission_engine.mode = mode;
            }
            unlockAuthority(app);
            updateYoloWarningForMode(app);
            syncQueuedPermissionSnapshot(app, agent);
        }

        pub fn initializeYoloWarning(app: *App) void {
            updateYoloWarningForMode(app);
        }

        pub fn yoloWarningActive(app: *const App) bool {
            return app.permission_state.yolo_warning.active;
        }

        pub fn tick(app: *App, now_ms: i64) void {
            if (app.permission_state.yolo_warning.tick(now_ms)) {
                app.shell.render_requests.request(.footer);
            }
        }

        pub fn noteFrameCommitted(app: *App, now_ms: i64, warning_included: bool) void {
            if (comptime !@hasField(App, "permission_state")) return;
            const was_active = app.permission_state.yolo_warning.active;
            app.permission_state.yolo_warning.frameCommitted(now_ms, warning_included);
            if (!was_active or !warning_included) return;
            if (app.permission_state.yolo_acknowledged or
                app.permission_state.yolo_acknowledgment_attempted)
            {
                return;
            }
            app.permission_state.yolo_acknowledgment_attempted = true;
            persistYoloAcknowledgment(app);
        }

        /// Snapshots `agent`'s live permission state: its permission owner's
        /// mode.
        pub fn livePermissionSnapshot(app: *App, agent: anytype) worker_runtime.PermissionSnapshot {
            lockAuthority(app);
            defer unlockAuthority(app);
            return .{
                .mode = instanceMode(app, permissionOwner(app, agent)),
            };
        }

        pub fn selectMode(app: *App, agent: *AppAgent, mode: types.PermissionMode) !void {
            setMode(app, agent, mode);
            if (comptime @hasDecl(App, "persistAcceptedPermissionMode")) {
                try app.persistAcceptedPermissionMode(mode);
            }
            try finalizeModePreference(app);
        }

        pub fn toggleMode(app: *App, agent: *AppAgent) !void {
            if (comptime !@hasField(App, "permission_engine")) return;
            try selectMode(app, agent, switch (modeOf(app, agent)) {
                .ask => .auto,
                .auto => .yolo,
                .yolo => .ask,
            });
        }

        /// `/permissions reset` on `agent`'s screen: its permission owner goes
        /// back to ask with no session approvals.
        pub fn reset(app: *App, agent: *AppAgent) !void {
            lockAuthority(app);
            if (comptime per_instance) {
                const owner = permissionOwner(app, agent);
                owner.permission_mode = .ask;
                permissions.clearAllowedTools(app.alloc, &owner.session_grants);
            } else {
                app.permission_engine.mode = .ask;
                app.permission_engine.clear(app.alloc);
            }
            updateYoloWarningForMode(app);
            unlockAuthority(app);
            try app_worker_runtime.Runtime(App).syncQueuedPromptPermissionState(
                app,
                agent,
                livePermissionSnapshot(app, agent),
            );
            try finalizeModePreference(app);
        }

        fn syncQueuedPermissionSnapshot(app: *App, agent: *AppAgent) void {
            app_worker_runtime.Runtime(App).syncQueuedPromptPermissionSnapshot(
                agent,
                livePermissionSnapshot(app, agent),
            );
        }

        /// Arms the full-access warning when the instance on screen is in
        /// full access.
        fn updateYoloWarningForMode(app: *App) void {
            const mode = if (comptime per_instance)
                instanceMode(app, permissionOwner(app, agents.screenAgentOf(app)))
            else
                app.permission_engine.mode;
            if (mode == .yolo and
                !app.permission_state.yolo_acknowledged)
            {
                app.permission_state.yolo_warning.arm();
            } else {
                app.permission_state.yolo_warning.clear();
            }
        }

        fn persistYoloAcknowledgment(app: *App) void {
            if (comptime @hasDecl(App, "persistYoloAcknowledgment")) {
                if (app.persistYoloAcknowledgment()) {
                    app.permission_state.yolo_acknowledged = true;
                }
                return;
            }

            var attempt = config_runtime.attemptUserPreferences(
                app.alloc,
                .{ .yolo_acknowledged = true },
            );
            defer attempt.deinit(app.alloc);
            switch (attempt) {
                .outcome => |outcome| {
                    app.permission_state.yolo_acknowledged = true;
                    debug_trace.logf(
                        "permission",
                        "interactive_yolo_acknowledgment_persisted outcome={s}",
                        .{@tagName(outcome)},
                    );
                },
                .failure => |failure| {
                    debug_trace.logf(
                        "permission",
                        "interactive_yolo_acknowledgment_persist_failed err={s}",
                        .{@errorName(failure.err)},
                    );
                    session_commands.reportUserSettingsFailure(
                        app,
                        "full-access-acknowledgment",
                        failure.err,
                        failure.cleanup,
                        true,
                    ) catch |err| {
                        debug_trace.logf(
                            "permission",
                            "interactive_yolo_acknowledgment_failure_notice_failed err={s}",
                            .{@errorName(err)},
                        );
                    };
                },
            }
        }

        fn finalizeModePreference(app: *App) !void {
            try persistModePreference(app);
            debug_trace.logf(
                "permission",
                "interactive_permission_mode_selected mode={s}",
                .{permissions.permissionModeLabel(currentMode(app))},
            );
            app.shell.render_requests.request(.footer);
        }

        fn persistModePreference(app: *App) !void {
            const mode = currentMode(app);
            if (comptime @hasDecl(App, "persistPermissionModePreference")) {
                try app.persistPermissionModePreference(mode);
                return;
            }

            var attempt = config_runtime.attemptUserPreferences(
                app.alloc,
                .{ .permission_mode = mode },
            );
            defer attempt.deinit(app.alloc);
            switch (attempt) {
                .outcome => |outcome| {
                    debug_trace.logf(
                        "permission",
                        "interactive_permission_mode_persisted mode={s} outcome={s}",
                        .{ permissions.permissionModeLabel(mode), @tagName(outcome) },
                    );
                },
                .failure => |failure| {
                    debug_trace.logf(
                        "permission",
                        "interactive_permission_mode_persist_failed mode={s} err={s}",
                        .{ permissions.permissionModeLabel(mode), @errorName(failure.err) },
                    );
                    try session_commands.reportUserSettingsFailure(
                        app,
                        "permission-mode",
                        failure.err,
                        failure.cleanup,
                        true,
                    );
                },
            }
        }
    };
}

const TestWorker = struct {
    synced_mode: ?types.PermissionMode = null,
    mode_sync_count: usize = 0,
    synced_state_mode: ?types.PermissionMode = null,
    synced_state_grant_count: usize = 0,
    state_sync_count: usize = 0,

    pub fn syncQueuedPromptPermissionSnapshot(self: *TestWorker, snapshot: worker_runtime.PermissionSnapshot) void {
        self.synced_mode = snapshot.mode;
        self.mode_sync_count += 1;
    }

    pub fn syncQueuedPromptPermissionState(
        self: *TestWorker,
        _: std.mem.Allocator,
        grants: []const types.PermissionGrant,
        snapshot: worker_runtime.PermissionSnapshot,
    ) !void {
        self.synced_state_mode = snapshot.mode;
        self.synced_state_grant_count = grants.len;
        self.state_sync_count += 1;
    }
};

const PermissionCommitSnapshot = struct {
    engine_mode: types.PermissionMode,
    engine_grant_count: usize,
    synced_mode: ?types.PermissionMode,
    mode_sync_count: usize,
    synced_state_mode: ?types.PermissionMode,
    synced_state_grant_count: usize,
    state_sync_count: usize,
};

const TestApp = struct {
    alloc: std.mem.Allocator,
    permission_engine: permissions.PermissionEngine = .{},
    permission_state: State = .{},
    main_agent: struct {
        worker: TestWorker = .{},
    } = .{},
    shell: struct {
        render_requests: render_request.RenderRequestState = .{},
    } = .{},
    permission_mode_preference_commit_count: usize = 0,
    last_preference_permission_mode: ?types.PermissionMode = null,
    permission_commit_snapshot: ?PermissionCommitSnapshot = null,
    yolo_acknowledgment_commit_count: usize = 0,
    yolo_acknowledgment_commit_succeeds: bool = true,

    fn deinit(self: *TestApp) void {
        self.permission_engine.deinit(self.alloc);
    }

    pub fn persistPermissionModePreference(self: *TestApp, mode: types.PermissionMode) !void {
        self.permission_mode_preference_commit_count += 1;
        self.last_preference_permission_mode = mode;
        self.permission_commit_snapshot = .{
            .engine_mode = self.permission_engine.mode,
            .engine_grant_count = self.permission_engine.grants.items.len,
            .synced_mode = self.agent().worker.synced_mode,
            .mode_sync_count = self.agent().worker.mode_sync_count,
            .synced_state_mode = self.agent().worker.synced_state_mode,
            .synced_state_grant_count = self.agent().worker.synced_state_grant_count,
            .state_sync_count = self.agent().worker.state_sync_count,
        };
    }

    pub fn persistYoloAcknowledgment(self: *TestApp) bool {
        self.yolo_acknowledgment_commit_count += 1;
        return self.yolo_acknowledgment_commit_succeeds;
    }

    pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }
};

fn expectPersistentModeSelection(mode: types.PermissionMode) !void {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();

    try Runtime(TestApp).selectMode(&app, (&app).agent(), mode);

    try std.testing.expectEqual(mode, app.permission_engine.mode);
    try std.testing.expectEqual(@as(?types.PermissionMode, mode), app.agent().worker.synced_mode);
    try std.testing.expectEqual(@as(usize, 1), app.agent().worker.mode_sync_count);
    try std.testing.expectEqual(@as(usize, 1), app.permission_mode_preference_commit_count);
    try std.testing.expectEqual(@as(?types.PermissionMode, mode), app.last_preference_permission_mode);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));

    const snapshot = app.permission_commit_snapshot.?;
    try std.testing.expectEqual(mode, snapshot.engine_mode);
    try std.testing.expectEqual(@as(usize, 0), snapshot.engine_grant_count);
    try std.testing.expectEqual(@as(?types.PermissionMode, mode), snapshot.synced_mode);
    try std.testing.expectEqual(@as(usize, 1), snapshot.mode_sync_count);
    try std.testing.expectEqual(@as(?types.PermissionMode, null), snapshot.synced_state_mode);
    try std.testing.expectEqual(@as(usize, 0), snapshot.state_sync_count);
}

test "app_permission_runtime selectMode persists ask after syncing queued prompts" {
    try expectPersistentModeSelection(.ask);
}

test "app_permission_runtime selectMode persists auto after syncing queued prompts" {
    try expectPersistentModeSelection(.auto);
}

test "app_permission_runtime selectMode persists yolo after syncing queued prompts" {
    try expectPersistentModeSelection(.yolo);
}

test "yolo acknowledgment follows the first committed warning frame" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();

    try Runtime(TestApp).selectMode(&app, (&app).agent(), .yolo);
    try std.testing.expect(app.permission_state.yolo_warning.active);
    try std.testing.expect(!app.permission_state.yolo_acknowledged);

    Runtime(TestApp).noteFrameCommitted(&app, 100, false);
    try std.testing.expectEqual(@as(usize, 0), app.yolo_acknowledgment_commit_count);
    try std.testing.expect(!app.permission_state.yolo_acknowledgment_attempted);

    Runtime(TestApp).noteFrameCommitted(&app, 200, true);
    try std.testing.expectEqual(@as(usize, 1), app.yolo_acknowledgment_commit_count);
    try std.testing.expect(app.permission_state.yolo_acknowledgment_attempted);
    try std.testing.expect(app.permission_state.yolo_acknowledged);
    try std.testing.expectEqual(@as(?i64, 200), app.permission_state.yolo_warning.visible_since_ms);

    Runtime(TestApp).noteFrameCommitted(&app, 300, true);
    try std.testing.expectEqual(@as(usize, 1), app.yolo_acknowledgment_commit_count);
    Runtime(TestApp).tick(&app, 4199);
    try std.testing.expect(app.permission_state.yolo_warning.active);
    Runtime(TestApp).tick(&app, 4200);
    try std.testing.expect(!app.permission_state.yolo_warning.active);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
}

test "yolo warning counts only committed visible intervals" {
    var warning = YoloWarning{};
    warning.arm();

    warning.frameCommitted(100, true);
    warning.frameCommitted(1100, false);
    try std.testing.expectEqual(@as(i64, 3000), warning.remaining_visible_ms);
    try std.testing.expect(!warning.tick(10_000));

    warning.frameCommitted(12_000, true);
    try std.testing.expect(!warning.tick(14_999));
    try std.testing.expect(warning.tick(15_000));
}

test "failed yolo acknowledgment is attempted at most once per process" {
    var app = TestApp{
        .alloc = std.testing.allocator,
        .yolo_acknowledgment_commit_succeeds = false,
    };
    defer app.deinit();

    Runtime(TestApp).setMode(&app, (&app).agent(), .yolo);
    Runtime(TestApp).noteFrameCommitted(&app, 100, true);
    Runtime(TestApp).noteFrameCommitted(&app, 200, true);

    try std.testing.expectEqual(@as(usize, 1), app.yolo_acknowledgment_commit_count);
    try std.testing.expect(!app.permission_state.yolo_acknowledged);
    try std.testing.expect(app.permission_state.yolo_warning.active);
}

test "app_permission_runtime toggleMode cycles ask auto yolo and persists" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();

    try Runtime(TestApp).toggleMode(&app, (&app).agent());

    try std.testing.expectEqual(types.PermissionMode.auto, app.permission_engine.mode);
    try std.testing.expectEqual(@as(?types.PermissionMode, .auto), app.agent().worker.synced_mode);
    try std.testing.expectEqual(@as(usize, 1), app.agent().worker.mode_sync_count);
    try std.testing.expectEqual(@as(usize, 1), app.permission_mode_preference_commit_count);
    try std.testing.expectEqual(@as(?types.PermissionMode, .auto), app.last_preference_permission_mode);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
    try std.testing.expectEqual(@as(usize, 1), app.permission_commit_snapshot.?.mode_sync_count);
    try std.testing.expectEqual(@as(?types.PermissionMode, .auto), app.permission_commit_snapshot.?.synced_mode);

    app.shell.render_requests.clearReason(.footer);
    try Runtime(TestApp).toggleMode(&app, (&app).agent());

    try std.testing.expectEqual(types.PermissionMode.yolo, app.permission_engine.mode);
    try std.testing.expectEqual(@as(?types.PermissionMode, .yolo), app.agent().worker.synced_mode);
    try std.testing.expectEqual(@as(usize, 2), app.permission_mode_preference_commit_count);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
    try std.testing.expectEqual(@as(usize, 2), app.permission_commit_snapshot.?.mode_sync_count);
    try std.testing.expectEqual(@as(?types.PermissionMode, .yolo), app.permission_commit_snapshot.?.synced_mode);

    app.shell.render_requests.clearReason(.footer);
    try Runtime(TestApp).toggleMode(&app, (&app).agent());

    try std.testing.expectEqual(types.PermissionMode.ask, app.permission_engine.mode);
    try std.testing.expectEqual(@as(?types.PermissionMode, .ask), app.agent().worker.synced_mode);
    try std.testing.expectEqual(@as(usize, 3), app.permission_mode_preference_commit_count);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
}

test "app_permission_runtime setMode syncs queued prompts without persisting" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();

    Runtime(TestApp).setMode(&app, (&app).agent(), .auto);

    try std.testing.expectEqual(types.PermissionMode.auto, app.permission_engine.mode);
    try std.testing.expectEqual(@as(?types.PermissionMode, .auto), app.agent().worker.synced_mode);
    try std.testing.expectEqual(@as(usize, 1), app.agent().worker.mode_sync_count);
    try std.testing.expectEqual(@as(usize, 0), app.permission_mode_preference_commit_count);
    try std.testing.expect(!app.shell.render_requests.hasReason(.footer));
}

test "app_permission_runtime reset clears grants before syncing permission state" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.permission_engine.mode = .auto;
    try app.permission_engine.allow(std.testing.allocator, "run_command", "/tmp/workspace::git status");

    try Runtime(TestApp).reset(&app, (&app).agent());

    try std.testing.expectEqual(types.PermissionMode.ask, app.permission_engine.mode);
    try std.testing.expectEqual(@as(usize, 0), app.permission_engine.grants.items.len);
    try std.testing.expectEqual(@as(?types.PermissionMode, .ask), app.agent().worker.synced_state_mode);
    try std.testing.expectEqual(@as(usize, 0), app.agent().worker.synced_state_grant_count);
    try std.testing.expectEqual(@as(usize, 1), app.agent().worker.state_sync_count);
    try std.testing.expectEqual(@as(usize, 1), app.permission_mode_preference_commit_count);
    try std.testing.expectEqual(@as(?types.PermissionMode, .ask), app.last_preference_permission_mode);
    try std.testing.expectEqual(@as(usize, 0), app.agent().worker.mode_sync_count);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));

    const snapshot = app.permission_commit_snapshot.?;
    try std.testing.expectEqual(types.PermissionMode.ask, snapshot.engine_mode);
    try std.testing.expectEqual(@as(usize, 0), snapshot.engine_grant_count);
    try std.testing.expectEqual(@as(?types.PermissionMode, null), snapshot.synced_mode);
    try std.testing.expectEqual(@as(usize, 0), snapshot.mode_sync_count);
    try std.testing.expectEqual(@as(?types.PermissionMode, .ask), snapshot.synced_state_mode);
    try std.testing.expectEqual(@as(usize, 0), snapshot.synced_state_grant_count);
    try std.testing.expectEqual(@as(usize, 1), snapshot.state_sync_count);
}
