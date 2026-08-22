const std = @import("std");
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
pub const yolo_warning_compact_text = "YOLO: unrestricted";
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
        /// Session-scoped mode change: applies the mode and syncs queued
        /// prompts without touching the persisted preference.
        pub fn setMode(app: *App, mode: types.PermissionMode) void {
            app.permission_engine.mode = mode;
            updateYoloWarningForMode(app);
            syncQueuedPermissionSnapshot(app);
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

        /// The live (unsnapshotted) permission state owned by this runtime.
        pub fn livePermissionSnapshot(app: *App) worker_runtime.PermissionSnapshot {
            return .{
                .mode = app.permission_engine.mode,
            };
        }

        pub fn selectMode(app: *App, mode: types.PermissionMode) !void {
            setMode(app, mode);
            if (comptime @hasDecl(App, "persistAcceptedPermissionMode")) {
                try app.persistAcceptedPermissionMode(mode);
            }
            try finalizeModePreference(app);
        }

        pub fn toggleMode(app: *App) !void {
            if (comptime !@hasField(App, "permission_engine")) return;
            try selectMode(app, switch (app.permission_engine.mode) {
                .ask => .auto,
                .auto => .yolo,
                .yolo => .ask,
            });
        }

        pub fn reset(app: *App) !void {
            if (comptime @hasField(@TypeOf(app.permission_state), "authority_mutex")) {
                app.permission_state.authority_mutex.lockUncancelable(io_mod.getIo());
            }
            app.permission_engine.mode = .ask;
            updateYoloWarningForMode(app);
            app.permission_engine.clear(app.alloc);
            if (comptime @hasField(@TypeOf(app.permission_state), "authority_mutex")) {
                app.permission_state.authority_mutex.unlock(io_mod.getIo());
            }
            try app_worker_runtime.Runtime(App).syncQueuedPromptPermissionState(
                app,
                livePermissionSnapshot(app),
            );
            try finalizeModePreference(app);
        }

        fn syncQueuedPermissionSnapshot(app: *App) void {
            app_worker_runtime.Runtime(App).syncQueuedPromptPermissionSnapshot(
                app,
                livePermissionSnapshot(app),
            );
        }

        fn updateYoloWarningForMode(app: *App) void {
            if (app.permission_engine.mode == .yolo and
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
                        "yolo-acknowledgment",
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
                .{permissions.permissionModeLabel(app.permission_engine.mode)},
            );
            app.shell.render_requests.request(.footer);
        }

        fn persistModePreference(app: *App) !void {
            const mode = app.permission_engine.mode;
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
    worker: TestWorker = .{},
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
            .synced_mode = self.worker.synced_mode,
            .mode_sync_count = self.worker.mode_sync_count,
            .synced_state_mode = self.worker.synced_state_mode,
            .synced_state_grant_count = self.worker.synced_state_grant_count,
            .state_sync_count = self.worker.state_sync_count,
        };
    }

    pub fn persistYoloAcknowledgment(self: *TestApp) bool {
        self.yolo_acknowledgment_commit_count += 1;
        return self.yolo_acknowledgment_commit_succeeds;
    }
};

fn expectPersistentModeSelection(mode: types.PermissionMode) !void {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();

    try Runtime(TestApp).selectMode(&app, mode);

    try std.testing.expectEqual(mode, app.permission_engine.mode);
    try std.testing.expectEqual(@as(?types.PermissionMode, mode), app.worker.synced_mode);
    try std.testing.expectEqual(@as(usize, 1), app.worker.mode_sync_count);
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

    try Runtime(TestApp).selectMode(&app, .yolo);
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

    Runtime(TestApp).setMode(&app, .yolo);
    Runtime(TestApp).noteFrameCommitted(&app, 100, true);
    Runtime(TestApp).noteFrameCommitted(&app, 200, true);

    try std.testing.expectEqual(@as(usize, 1), app.yolo_acknowledgment_commit_count);
    try std.testing.expect(!app.permission_state.yolo_acknowledged);
    try std.testing.expect(app.permission_state.yolo_warning.active);
}

test "app_permission_runtime toggleMode cycles ask auto yolo and persists" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();

    try Runtime(TestApp).toggleMode(&app);

    try std.testing.expectEqual(types.PermissionMode.auto, app.permission_engine.mode);
    try std.testing.expectEqual(@as(?types.PermissionMode, .auto), app.worker.synced_mode);
    try std.testing.expectEqual(@as(usize, 1), app.worker.mode_sync_count);
    try std.testing.expectEqual(@as(usize, 1), app.permission_mode_preference_commit_count);
    try std.testing.expectEqual(@as(?types.PermissionMode, .auto), app.last_preference_permission_mode);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
    try std.testing.expectEqual(@as(usize, 1), app.permission_commit_snapshot.?.mode_sync_count);
    try std.testing.expectEqual(@as(?types.PermissionMode, .auto), app.permission_commit_snapshot.?.synced_mode);

    app.shell.render_requests.clearReason(.footer);
    try Runtime(TestApp).toggleMode(&app);

    try std.testing.expectEqual(types.PermissionMode.yolo, app.permission_engine.mode);
    try std.testing.expectEqual(@as(?types.PermissionMode, .yolo), app.worker.synced_mode);
    try std.testing.expectEqual(@as(usize, 2), app.permission_mode_preference_commit_count);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
    try std.testing.expectEqual(@as(usize, 2), app.permission_commit_snapshot.?.mode_sync_count);
    try std.testing.expectEqual(@as(?types.PermissionMode, .yolo), app.permission_commit_snapshot.?.synced_mode);

    app.shell.render_requests.clearReason(.footer);
    try Runtime(TestApp).toggleMode(&app);

    try std.testing.expectEqual(types.PermissionMode.ask, app.permission_engine.mode);
    try std.testing.expectEqual(@as(?types.PermissionMode, .ask), app.worker.synced_mode);
    try std.testing.expectEqual(@as(usize, 3), app.permission_mode_preference_commit_count);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
}

test "app_permission_runtime setMode syncs queued prompts without persisting" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();

    Runtime(TestApp).setMode(&app, .auto);

    try std.testing.expectEqual(types.PermissionMode.auto, app.permission_engine.mode);
    try std.testing.expectEqual(@as(?types.PermissionMode, .auto), app.worker.synced_mode);
    try std.testing.expectEqual(@as(usize, 1), app.worker.mode_sync_count);
    try std.testing.expectEqual(@as(usize, 0), app.permission_mode_preference_commit_count);
    try std.testing.expect(!app.shell.render_requests.hasReason(.footer));
}

test "app_permission_runtime reset clears grants before syncing permission state" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.permission_engine.mode = .auto;
    try app.permission_engine.allow(std.testing.allocator, "run_command", "/tmp/workspace::git status");

    try Runtime(TestApp).reset(&app);

    try std.testing.expectEqual(types.PermissionMode.ask, app.permission_engine.mode);
    try std.testing.expectEqual(@as(usize, 0), app.permission_engine.grants.items.len);
    try std.testing.expectEqual(@as(?types.PermissionMode, .ask), app.worker.synced_state_mode);
    try std.testing.expectEqual(@as(usize, 0), app.worker.synced_state_grant_count);
    try std.testing.expectEqual(@as(usize, 1), app.worker.state_sync_count);
    try std.testing.expectEqual(@as(usize, 1), app.permission_mode_preference_commit_count);
    try std.testing.expectEqual(@as(?types.PermissionMode, .ask), app.last_preference_permission_mode);
    try std.testing.expectEqual(@as(usize, 0), app.worker.mode_sync_count);
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
