const std = @import("std");
const auto_upgrade = @import("../upgrade/auto_upgrade.zig");
const types = @import("../shared/types.zig");
const upgrade_helpers = @import("../upgrade/upgrade_helpers.zig");
const editor_state = @import("../input/editor_state.zig");
const paste_framing = @import("../input/paste_framing.zig");

pub const ApplyOutcome = enum {
    not_ready,
    unavailable,
    relaunch_requested,
};

const CurrentExecutablePathFn = *const fn (
    ?*anyopaque,
    []u8,
) upgrade_helpers.ExecutablePathError![]const u8;

pub const Deps = struct {
    ctx: ?*anyopaque = null,
    current_executable_path: CurrentExecutablePathFn = currentExecutablePathDefault,
};

pub fn Runtime(comptime App: type) type {
    return struct {
        pub fn applyReadyUpgrade(app: *App) !void {
            _ = try applyReadyUpgradeWithDeps(app, .{});
        }

        pub fn collectUpgradeFacts(app: *App) void {
            if (!autoUpgradeEnabled(app)) return;

            if (comptime @hasField(App, "upgrader")) {
                if (comptime @hasDecl(@TypeOf(app.upgrader), "takeRenderDirty")) {
                    if (app.upgrader.takeRenderDirty()) requestFooterRender(app);
                }
            }
        }

        pub fn applyReadyUpgradeWithDeps(
            app: *App,
            deps: Deps,
        ) !ApplyOutcome {
            if (upgradeUnavailableNotice(app)) |notice| {
                try writeUpgradeNotice(app, .neutral, notice);
                return .unavailable;
            }

            if (!autoUpgradeEnabled(app)) {
                try writeUpgradeNotice(app, .neutral, "auto-upgrade is disabled");
                return .not_ready;
            }

            if (comptime @hasField(App, "upgrader")) {
                if (app.upgrader.getState() != auto_upgrade.State.ready) {
                    try writeUpgradeNotice(app, .neutral, "no installed upgrade is ready");
                    return .not_ready;
                }
            }

            app.prepareResumeHandoffForUpgrade() catch |err| {
                const notice = try std.fmt.allocPrint(
                    app.alloc,
                    "upgrade paused because this conversation is not safely resumable: {s}; run `fx doctor` for recovery guidance",
                    .{@errorName(err)},
                );
                defer app.alloc.free(notice);
                try writeUpgradeNotice(app, .@"error", notice);
                return .unavailable;
            };

            var executable_buf: [std.fs.max_path_bytes]u8 = undefined;
            const executable_path = deps.current_executable_path(
                deps.ctx,
                &executable_buf,
            ) catch |err| {
                const notice = try std.fmt.allocPrint(
                    app.alloc,
                    "upgrade installed, but the executable path could not be resolved: {s}; restart fx manually",
                    .{@errorName(err)},
                );
                defer app.alloc.free(notice);
                try writeUpgradeNotice(app, .@"error", notice);
                return .unavailable;
            };

            app.requestUpgradeRelaunch(executable_path) catch |err| {
                const notice = try std.fmt.allocPrint(
                    app.alloc,
                    "upgrade installed, but relaunch could not be prepared: {s}; restart fx manually",
                    .{@errorName(err)},
                );
                defer app.alloc.free(notice);
                try writeUpgradeNotice(app, .@"error", notice);
                return .unavailable;
            };
            app.requestResumeHandoffForUpgrade();
            if (comptime @hasField(App, "should_exit")) app.should_exit = true;
            return .relaunch_requested;
        }

        fn upgradeUnavailableNotice(app: *App) ?[]const u8 {
            if (comptime @hasField(App, "stream")) {
                if (app.stream.active) return "upgrade is unavailable until the response finishes";
            }
            if (comptime @hasField(App, "worker")) {
                if (comptime @hasDecl(@TypeOf(app.worker), "queuedPromptCount")) {
                    if (app.worker.queuedPromptCount() > 0) {
                        return "upgrade is unavailable while prompts are queued";
                    }
                }
            }
            if (comptime @hasField(App, "question_prompt")) {
                if (app.question_prompt.isActive()) return "upgrade is unavailable while a question is open";
            }
            if (comptime @hasField(App, "approval_prompt")) {
                if (app.approval_prompt.isActive()) return "upgrade is unavailable while an approval is open";
            }
            if (comptime @hasField(App, "auth") and
                @hasDecl(@TypeOf(app.auth), "enteredSecretEntryActive"))
            {
                if (app.auth.enteredSecretEntryActive()) return "upgrade is unavailable during API key entry";
            }
            if (comptime @hasField(App, "subagents")) {
                if (app.subagents.isViewActive()) return "close the subagent view before upgrading";
            }
            if (comptime @hasField(App, "session_persistence")) {
                if (app.session_persistence.session_picker.active) return "close the session picker before upgrading";
            }
            if (comptime @hasField(App, "terminal")) {
                if (app.terminal.fullTranscriptScreenActive()) return "close the transcript view before upgrading";
            }
            if (comptime @hasField(App, "input_runtime")) {
                if (app.input_runtime.paste.active()) return "finish the paste before upgrading";
                if (app.input_runtime.edit_state.input.items.len > 0) return "submit or clear the current prompt before upgrading";
            }
            if (comptime @hasField(App, "pending_images")) {
                if (app.pending_images.items.len > 0) return "submit or clear pending images before upgrading";
            }
            if (comptime @hasField(App, "terminal_input_runtime")) {
                if (app.terminal_input_runtime.hasPendingTerminalAction()) return "finish the key sequence before upgrading";
            }
            return null;
        }

        fn autoUpgradeEnabled(app: *const App) bool {
            if (comptime @hasField(App, "auto_upgrade_enabled")) {
                return app.auto_upgrade_enabled;
            }
            return true;
        }

        fn writeUpgradeNotice(app: *App, tone: types.NoticeTone, body: []const u8) !void {
            try app.writeDomainNotice(.{
                .topic = "upgrade",
                .tone = tone,
                .body = body,
            }, true);
            requestFooterRender(app);
        }

        fn requestFooterRender(app: *App) void {
            if (comptime @hasField(App, "shell")) app.shell.render_requests.request(.footer);
        }
    };
}

fn currentExecutablePathDefault(
    _: ?*anyopaque,
    executable_buf: []u8,
) upgrade_helpers.ExecutablePathError![]const u8 {
    return upgrade_helpers.currentExecutablePath(executable_buf);
}

const TestUpgrader = struct {
    state: auto_upgrade.State = .idle,
    stop_count: usize = 0,
    render_dirty: bool = false,

    fn getState(self: *TestUpgrader) auto_upgrade.State {
        return self.state;
    }

    fn stop(self: *TestUpgrader) void {
        self.stop_count += 1;
    }

    fn takeRenderDirty(self: *TestUpgrader) bool {
        const dirty = self.render_dirty;
        self.render_dirty = false;
        return dirty;
    }
};

const TestWorker = struct {
    queued_count: usize = 0,
    shutdown_count: usize = 0,

    fn queuedPromptCount(self: *const TestWorker) usize {
        return self.queued_count;
    }

    fn requestShutdown(self: *TestWorker) void {
        self.shutdown_count += 1;
    }
};

const TestInputRuntime = struct {
    edit_state: editor_state.State = .{},
    paste: paste_framing.State = .{},
};

const TestTerminalInputRuntime = struct {
    terminal_action_pending: bool = false,

    fn hasPendingTerminalAction(self: *const TestTerminalInputRuntime) bool {
        return self.terminal_action_pending;
    }
};

const TestRenderRequests = struct {
    footer_count: usize = 0,

    fn request(self: *TestRenderRequests, reason: anytype) void {
        if (reason == .footer) self.footer_count += 1;
    }
};

const TestShell = struct {
    render_requests: TestRenderRequests = .{},
};

const TestApp = struct {
    alloc: std.mem.Allocator,
    auto_upgrade_enabled: bool = true,
    upgrader: TestUpgrader = .{},
    worker: TestWorker = .{},
    input_runtime: TestInputRuntime = .{},
    terminal_input_runtime: TestTerminalInputRuntime = .{},
    shell: TestShell = .{},
    stream: struct { active: bool = false } = .{},
    should_exit: bool = false,
    session_id: ?[]const u8 = "session-123",
    notices: std.ArrayList(u8) = .empty,
    prepare_count: usize = 0,
    request_handoff_count: usize = 0,
    relaunch_path: [std.fs.max_path_bytes]u8 = undefined,
    relaunch_path_len: usize = 0,
    prepare_error: ?anyerror = null,
    relaunch_error: ?error{NameTooLong} = null,

    fn deinit(self: *TestApp) void {
        self.input_runtime.edit_state.deinit(self.alloc);
        self.notices.deinit(self.alloc);
    }

    fn prepareResumeHandoffForUpgrade(self: *TestApp) !void {
        self.prepare_count += 1;
        if (self.session_id == null) return error.SessionPersistenceUnavailable;
        if (self.prepare_error) |err| return err;
    }

    fn requestUpgradeRelaunch(self: *TestApp, executable_path: []const u8) !void {
        if (self.relaunch_error) |err| return err;
        if (executable_path.len > self.relaunch_path.len) return error.NameTooLong;
        @memcpy(self.relaunch_path[0..executable_path.len], executable_path);
        self.relaunch_path_len = executable_path.len;
    }

    fn requestResumeHandoffForUpgrade(self: *TestApp) void {
        self.request_handoff_count += 1;
    }

    fn writeDomainNotice(self: *TestApp, notice: types.SemanticNotice, _: bool) !void {
        try self.notices.appendSlice(self.alloc, notice.body);
    }
};

const TestDepsState = struct {
    path_count: usize = 0,
    path_error: ?upgrade_helpers.ExecutablePathError = null,

    fn deps(self: *TestDepsState) Deps {
        return .{
            .ctx = self,
            .current_executable_path = currentExecutablePathForTest,
        };
    }
};

fn currentExecutablePathForTest(
    ctx: ?*anyopaque,
    executable_buf: []u8,
) upgrade_helpers.ExecutablePathError![]const u8 {
    const state: *TestDepsState = @ptrCast(@alignCast(ctx.?));
    state.path_count += 1;
    if (state.path_error) |err| return err;
    const executable_path = "/tmp/fx-upgraded";
    if (executable_path.len > executable_buf.len) return error.PathTooLong;
    @memcpy(executable_buf[0..executable_path.len], executable_path);
    return executable_buf[0..executable_path.len];
}

test "app_upgrade_runtime validates then requests normal relaunch handoff" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    var deps_state = TestDepsState{};
    const outcome = try Runtime(TestApp).applyReadyUpgradeWithDeps(&app, deps_state.deps());

    try std.testing.expectEqual(ApplyOutcome.relaunch_requested, outcome);
    try std.testing.expectEqual(@as(usize, 1), app.prepare_count);
    try std.testing.expectEqual(@as(usize, 1), deps_state.path_count);
    try std.testing.expectEqualStrings(
        "/tmp/fx-upgraded",
        app.relaunch_path[0..app.relaunch_path_len],
    );
    try std.testing.expectEqual(@as(usize, 1), app.request_handoff_count);
    try std.testing.expect(app.should_exit);
}

test "app_upgrade_runtime keeps running when the executable path is unavailable" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    var deps_state = TestDepsState{ .path_error = error.SelfExeNotFound };

    const outcome = try Runtime(TestApp).applyReadyUpgradeWithDeps(
        &app,
        deps_state.deps(),
    );

    try std.testing.expectEqual(ApplyOutcome.unavailable, outcome);
    try std.testing.expectEqual(@as(usize, 1), app.prepare_count);
    try std.testing.expectEqual(@as(usize, 1), deps_state.path_count);
    try std.testing.expectEqual(@as(usize, 0), app.relaunch_path_len);
    try std.testing.expectEqual(@as(usize, 0), app.request_handoff_count);
    try std.testing.expect(!app.should_exit);
    try std.testing.expect(std.mem.find(
        u8,
        app.notices.items,
        "executable path could not be resolved: SelfExeNotFound",
    ) != null);
}

test "app_upgrade_runtime keeps running when relaunch preparation fails" {
    var app = TestApp{
        .alloc = std.testing.allocator,
        .relaunch_error = error.NameTooLong,
    };
    defer app.deinit();
    app.upgrader.state = .ready;
    var deps_state = TestDepsState{};

    const outcome = try Runtime(TestApp).applyReadyUpgradeWithDeps(&app, deps_state.deps());

    try std.testing.expectEqual(ApplyOutcome.unavailable, outcome);
    try std.testing.expectEqual(@as(usize, 1), deps_state.path_count);
    try std.testing.expectEqual(@as(usize, 0), app.request_handoff_count);
    try std.testing.expect(!app.should_exit);
    try std.testing.expect(std.mem.find(
        u8,
        app.notices.items,
        "relaunch could not be prepared: NameTooLong",
    ) != null);
}

test "app_upgrade_runtime keeps the app alive when the resume boundary is invalid" {
    var app = TestApp{
        .alloc = std.testing.allocator,
        .prepare_error = error.InvalidSessionFormat,
    };
    defer app.deinit();
    app.upgrader.state = .ready;
    var deps_state = TestDepsState{};

    const outcome = try Runtime(TestApp).applyReadyUpgradeWithDeps(
        &app,
        deps_state.deps(),
    );

    try std.testing.expectEqual(ApplyOutcome.unavailable, outcome);
    try std.testing.expectEqual(@as(usize, 1), app.prepare_count);
    try std.testing.expectEqual(@as(usize, 0), deps_state.path_count);
    try std.testing.expectEqual(@as(usize, 0), app.request_handoff_count);
    try std.testing.expect(!app.should_exit);
    try std.testing.expect(std.mem.find(
        u8,
        app.notices.items,
        "not safely resumable: InvalidSessionFormat",
    ) != null);
}

test "app_upgrade_runtime consumes upgrade render facts" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    app.upgrader.render_dirty = true;

    Runtime(TestApp).collectUpgradeFacts(&app);

    try std.testing.expectEqual(@as(usize, 1), app.shell.render_requests.footer_count);

    Runtime(TestApp).collectUpgradeFacts(&app);
    try std.testing.expectEqual(@as(usize, 1), app.shell.render_requests.footer_count);
}

test "app_upgrade_runtime skips upgrade render facts when disabled" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.auto_upgrade_enabled = false;
    app.upgrader.render_dirty = true;

    Runtime(TestApp).collectUpgradeFacts(&app);

    try std.testing.expectEqual(@as(usize, 0), app.shell.render_requests.footer_count);
}

test "app_upgrade_runtime rejects ctrl+g while upgrade is not ready" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    var deps_state = TestDepsState{};

    const outcome = try Runtime(TestApp).applyReadyUpgradeWithDeps(&app, deps_state.deps());

    try std.testing.expectEqual(ApplyOutcome.not_ready, outcome);
    try std.testing.expectEqual(@as(usize, 0), deps_state.path_count);
    try std.testing.expect(std.mem.find(u8, app.notices.items, "no installed upgrade is ready") != null);
}

test "app_upgrade_runtime requires an active session before reload" {
    var app = TestApp{ .alloc = std.testing.allocator, .session_id = null };
    defer app.deinit();
    app.upgrader.state = .ready;
    var deps_state = TestDepsState{};

    const outcome = try Runtime(TestApp).applyReadyUpgradeWithDeps(&app, deps_state.deps());

    try std.testing.expectEqual(ApplyOutcome.unavailable, outcome);
    try std.testing.expectEqual(@as(usize, 0), deps_state.path_count);
    try std.testing.expect(std.mem.find(
        u8,
        app.notices.items,
        "SessionPersistenceUnavailable",
    ) != null);
}

test "app_upgrade_runtime rejects busy app state before reload" {
    var stream_app = TestApp{ .alloc = std.testing.allocator };
    defer stream_app.deinit();
    stream_app.upgrader.state = .ready;
    stream_app.stream.active = true;
    var stream_deps = TestDepsState{};

    const stream_outcome = try Runtime(TestApp).applyReadyUpgradeWithDeps(&stream_app, stream_deps.deps());
    try std.testing.expectEqual(ApplyOutcome.unavailable, stream_outcome);
    try std.testing.expectEqual(@as(usize, 0), stream_deps.path_count);
    try std.testing.expect(std.mem.find(u8, stream_app.notices.items, "response finishes") != null);

    var composer_app = TestApp{ .alloc = std.testing.allocator };
    defer composer_app.deinit();
    composer_app.upgrader.state = .ready;
    try composer_app.input_runtime.edit_state.input.appendSlice(std.testing.allocator, "draft prompt");
    var composer_deps = TestDepsState{};

    const composer_outcome = try Runtime(TestApp).applyReadyUpgradeWithDeps(&composer_app, composer_deps.deps());
    try std.testing.expectEqual(ApplyOutcome.unavailable, composer_outcome);
    try std.testing.expectEqual(@as(usize, 0), composer_deps.path_count);
    try std.testing.expect(std.mem.find(u8, composer_app.notices.items, "current prompt") != null);
}

test "app_upgrade_runtime rejects mid key sequence before reload" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    app.terminal_input_runtime.terminal_action_pending = true;
    var deps = TestDepsState{};

    const outcome = try Runtime(TestApp).applyReadyUpgradeWithDeps(&app, deps.deps());
    try std.testing.expectEqual(ApplyOutcome.unavailable, outcome);
    try std.testing.expectEqual(@as(usize, 0), deps.path_count);
    try std.testing.expect(std.mem.find(u8, app.notices.items, "finish the key sequence") != null);
}
