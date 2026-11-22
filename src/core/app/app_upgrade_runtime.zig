const std = @import("std");
const agents = @import("../agents/agents.zig");
const app_agents_runtime = @import("app_agents_runtime.zig");
const auto_upgrade = @import("../upgrade/auto_upgrade.zig");
const types = @import("../shared/types.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const upgrade_helpers = @import("../upgrade/upgrade_helpers.zig");
const editor_state = @import("../input/editor_state.zig");
const paste_framing = @import("../input/paste_framing.zig");

pub const ApplyOutcome = enum {
    not_ready,
    unavailable,
    relaunch_requested,
    /// The relaunch waits for the running turns to stop between steps.
    waiting,
};

const CurrentExecutablePathFn = *const fn (
    ?*anyopaque,
    []u8,
) upgrade_helpers.ExecutablePathError![]const u8;

pub const Deps = struct {
    ctx: ?*anyopaque = null,
    current_executable_path: CurrentExecutablePathFn = currentExecutablePathDefault,
};

/// What Ctrl+G says while the relaunch waits for the running turns.
const restart_waits_notice = "fx restarts for the upgrade when the running turns stop between steps";
const restart_waits_for_subagents_notice = "fx restarts for the upgrade when the running turns stop between steps and the subagents finish";

/// Whether `App` can stop running turns between steps for the restart.
/// Without it, Ctrl+G still refuses while a response streams.
fn supportsYield(comptime App: type) bool {
    return @hasDecl(App, "anyTurnRunning") and @hasDecl(App, "requestTurnYields") and
        @hasField(App, "upgrader") and @hasField(@FieldType(App, "upgrader"), "restart_waits");
}

pub fn Runtime(comptime App: type) type {
    return struct {
        const AppAgent = if (@hasField(App, "main_agent")) @FieldType(App, "main_agent") else struct {};
        pub fn applyReadyUpgrade(app: *App, agent: *AppAgent) !void {
            _ = try applyReadyUpgradeWithDeps(app, agent, .{});
        }

        pub fn collectUpgradeFacts(app: *App) void {
            finishWaitingRestart(app);
            if (!autoUpgradeEnabled(app)) return;

            if (comptime @hasField(App, "upgrader")) {
                if (comptime @hasDecl(@TypeOf(app.upgrader), "takeRenderDirty")) {
                    if (app.upgrader.takeRenderDirty()) requestFooterRender(app);
                }
            }
        }

        /// The notice for a restart that waits: it names the subagents while
        /// one works, since the restart waits for them to finish.
        fn restartWaitsNotice(app: *App) []const u8 {
            if (comptime @hasDecl(App, "anySubagentWorking")) {
                if (app.anySubagentWorking()) return restart_waits_for_subagents_notice;
            }
            return restart_waits_notice;
        }

        /// Exits for the relaunch Ctrl+G asked for once every turn has
        /// stopped and nothing typed would be lost with the process.
        fn finishWaitingRestart(app: *App) void {
            if (comptime !supportsYield(App)) return;
            if (!app.upgrader.restart_waits) return;
            if (app.anyTurnRunning() or draftPending(app)) return;
            app.upgrader.restart_waits = false;
            if (comptime @hasDecl(App, "logHeldWorkForRestart")) app.logHeldWorkForRestart();
            debug_trace.logf("upgrade", "event=restart_after_yield", .{});
            if (comptime @hasField(App, "should_exit")) app.should_exit = true;
            requestFooterRender(app);
        }

        /// Text, a paste, or images in the composer, or a prompt sent but not
        /// yet started, which exiting would lose.
        fn draftPending(app: *App) bool {
            if (comptime @hasField(App, "input_runtime")) {
                if (app.input_runtime.paste.active()) return true;
                if (app.input_runtime.edit_state.input.items.len > 0) return true;
            }
            if (comptime @hasDecl(App, "screenAgent") and agents.hasAgentField(App, "pending_images")) {
                if (app.screenAgent().pending_images.items.len > 0) return true;
            }
            // Ctrl+G refuses while one is pending (`upgradeUnavailableNotice`)
            // and the wait holds new text in the composer, so this only guards
            // the exit.
            if (submissionPending(app)) return true;
            return false;
        }

        /// A prompt sent but not yet started by its agent's worker, on main
        /// or another instance (`submission.pending`, every phase): it waits
        /// for a frame, for sign-in, or for the worker to take it, and lives
        /// only in memory until then.
        fn submissionPending(app: *App) bool {
            if (comptime !agents.hasAgentField(App, "submission")) return false;
            if (app.main_agent.submission.pending != null) return true;
            if (comptime @hasField(App, "child_agents")) {
                for (app.child_agents.items) |child| {
                    if (child.agent.role == .instance and child.agent.submission.pending != null) return true;
                }
            }
            return false;
        }

        pub fn applyReadyUpgradeWithDeps(
            app: *App,
            agent: *AppAgent,
            deps: Deps,
        ) !ApplyOutcome {
            // A second Ctrl+G while the relaunch waits changes nothing.
            if (comptime supportsYield(App)) {
                if (app.upgrader.restart_waits) {
                    try writeUpgradeNotice(app, .neutral, restartWaitsNotice(app));
                    return .waiting;
                }
            }
            if (upgradeUnavailableNotice(app, agent)) |notice| {
                try writeUpgradeNotice(app, .neutral, notice);
                return .unavailable;
            }
            // The upgrade restarts fx. Ctrl+G asks the main agent and other
            // instances to stop between steps, and the restart waits until
            // working subagents finish. An agent that waits for the user gets
            // its answer first.
            if (comptime @hasDecl(App, "needsUserElsewhere")) {
                var name_buf: [32]u8 = undefined;
                if (app.needsUserElsewhere(&name_buf)) |busy| {
                    const notice = try app.alloc.print("upgrade is unavailable while {s} {s}", .{ busy.name, busyPhrase(busy.doing) });
                    defer app.alloc.free(notice);
                    try writeUpgradeNotice(app, .neutral, notice);
                    return .unavailable;
                }
            }

            // Main and other instances hold their queued work while they
            // yield, and the restart drops it with the process, so a queue
            // elsewhere refuses as the one on screen does.
            if (comptime @hasDecl(App, "queuedWorkElsewhere")) {
                var queue_name_buf: [32]u8 = undefined;
                if (app.queuedWorkElsewhere(&queue_name_buf)) |name| {
                    const notice = try app.alloc.print("upgrade is unavailable while {s} has queued prompts", .{name});
                    defer app.alloc.free(notice);
                    try writeUpgradeNotice(app, .neutral, notice);
                    return .unavailable;
                }
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

            app.prepareResumeHandoffForUpgrade(agent) catch |err| {
                const notice = try app.alloc.print(
                    "upgrade paused because this conversation is not safely resumable: {s}; run `fx doctor` for recovery guidance",
                    .{@errorName(err)},
                );
                defer app.alloc.free(notice);
                try writeUpgradeNotice(app, .@"error", notice);
                return .unavailable;
            };

            var executable_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const executable_path = deps.current_executable_path(
                deps.ctx,
                &executable_buf,
            ) catch |err| {
                const notice = try app.alloc.print(
                    "upgrade installed, but the executable path could not be resolved: {s}; restart fx manually",
                    .{@errorName(err)},
                );
                defer app.alloc.free(notice);
                try writeUpgradeNotice(app, .@"error", notice);
                return .unavailable;
            };

            app.requestUpgradeRelaunch(executable_path) catch |err| {
                const notice = try app.alloc.print(
                    "upgrade installed, but relaunch could not be prepared: {s}; restart fx manually",
                    .{@errorName(err)},
                );
                defer app.alloc.free(notice);
                try writeUpgradeNotice(app, .@"error", notice);
                return .unavailable;
            };
            app.requestResumeHandoffForUpgrade(agent);
            // Everything that can fail is done. A running turn stops at its
            // next step boundary, saved so the relaunched fx continues it
            // (`tests/tla/recovery/Resume.tla` Upgrade, Relaunch), and fx
            // exits once none runs (`collectUpgradeFacts`).
            if (comptime supportsYield(App)) {
                if (app.anyTurnRunning()) {
                    app.requestTurnYields();
                    app.upgrader.restart_waits = true;
                    debug_trace.logf("upgrade", "event=restart_waits_for_turns", .{});
                    try writeUpgradeNotice(app, .neutral, restartWaitsNotice(app));
                    return .waiting;
                }
            }
            if (comptime @hasField(App, "should_exit")) app.should_exit = true;
            return .relaunch_requested;
        }

        fn busyPhrase(doing: app_agents_runtime.Busiest) []const u8 {
            return switch (doing) {
                .needs_approval => "needs approval",
                .has_question => "has a question",
                .needs_you => "needs you",
                // `needsUserElsewhere` never names a working or idle agent.
                .working, .idle => unreachable,
            };
        }

        fn upgradeUnavailableNotice(app: *App, agent: *AppAgent) ?[]const u8 {
            // A host that stops turns between steps waits for them instead.
            if (comptime agents.hasAgentField(App, "stream") and !supportsYield(App)) {
                if (agent.stream.active) return "upgrade is unavailable until the response finishes";
            }
            if (comptime agents.hasAgentField(App, "worker")) {
                if (comptime @hasDecl(@TypeOf(agent.worker), "queuedPromptCount")) {
                    if (agent.worker.queuedPromptCount() > 0) {
                        return "upgrade is unavailable while prompts are queued";
                    }
                }
            }
            if (comptime agents.hasAgentField(App, "question_prompt")) {
                if (agent.question_prompt.isActive()) return "upgrade is unavailable while a question is open";
            }
            if (comptime agents.hasAgentField(App, "approval_prompt")) {
                if (agent.approval_prompt.isActive()) return "upgrade is unavailable while an approval is open";
            }
            if (comptime @hasField(App, "auth") and
                @hasDecl(@TypeOf(app.auth), "apiKeyEntryActive"))
            {
                if (app.auth.apiKeyEntryActive()) return "upgrade is unavailable during API key entry";
            }
            if (comptime @hasField(App, "subagents")) {
                if (app.subagents.isViewActive()) return "close the subagent view before upgrading";
            }
            if (comptime agents.hasAgentField(App, "session_persistence")) {
                if (agent.session_persistence.session_picker.active) return "close the session picker before upgrading";
            }
            if (comptime @hasField(App, "terminal")) {
                if (app.terminal.fullTranscriptScreenActive()) return "close the transcript view before upgrading";
            }
            if (comptime @hasField(App, "input_runtime")) {
                if (app.input_runtime.paste.active()) return "finish the paste before upgrading";
                if (app.input_runtime.edit_state.input.items.len > 0) return "submit or clear the current prompt before upgrading";
            }
            if (comptime agents.hasAgentField(App, "pending_images")) {
                if (agent.pending_images.items.len > 0) return "submit or clear pending images before upgrading";
            }
            // The worker holds its queue while it yields, so a sent prompt
            // that has not started would wait there until fx exits.
            if (submissionPending(app)) return "upgrade is unavailable while a sent prompt waits to go out";
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
    restart_waits: bool = false,

    fn getState(self: *TestUpgrader) auto_upgrade.State {
        return self.state;
    }

    fn stop(self: *TestUpgrader) void {
        self.stop_count += 1;
    }

    pub fn takeRenderDirty(self: *TestUpgrader) bool {
        const dirty = self.render_dirty;
        self.render_dirty = false;
        return dirty;
    }
};

const TestWorker = struct {
    queued_count: usize = 0,
    shutdown_count: usize = 0,

    pub fn queuedPromptCount(self: *const TestWorker) usize {
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
    main_agent: struct {
        worker: TestWorker = .{},
        stream: struct { active: bool = false } = .{},
        submission: struct { pending: ?u8 = null } = .{},
    } = .{},
    input_runtime: TestInputRuntime = .{},
    terminal_input_runtime: TestTerminalInputRuntime = .{},
    shell: TestShell = .{},
    should_exit: bool = false,
    session_id: ?[]const u8 = "session-123",
    notices: std.ArrayList(u8) = .empty,
    prepare_count: usize = 0,
    request_handoff_count: usize = 0,
    relaunch_path: [std.Io.Dir.max_path_bytes]u8 = undefined,
    relaunch_path_len: usize = 0,
    prepare_error: ?anyerror = null,
    relaunch_error: ?error{NameTooLong} = null,
    needs_user_elsewhere: ?app_agents_runtime.BusyAgent = null,
    queued_elsewhere: ?[]const u8 = null,
    turn_running: bool = false,
    subagent_working: bool = false,
    yield_request_count: usize = 0,
    held_work_logs: usize = 0,

    fn deinit(self: *TestApp) void {
        self.input_runtime.edit_state.deinit(self.alloc);
        self.notices.deinit(self.alloc);
    }

    fn prepareResumeHandoffForUpgrade(self: *TestApp, _: anytype) !void {
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

    fn requestResumeHandoffForUpgrade(self: *TestApp, _: anytype) void {
        self.request_handoff_count += 1;
    }

    pub fn needsUserElsewhere(self: *TestApp, _: []u8) ?app_agents_runtime.BusyAgent {
        return self.needs_user_elsewhere;
    }

    pub fn queuedWorkElsewhere(self: *TestApp, _: []u8) ?[]const u8 {
        return self.queued_elsewhere;
    }

    pub fn anyTurnRunning(self: *TestApp) bool {
        return self.turn_running;
    }

    pub fn anySubagentWorking(self: *TestApp) bool {
        return self.subagent_working;
    }

    pub fn requestTurnYields(self: *TestApp) void {
        self.yield_request_count += 1;
    }

    pub fn logHeldWorkForRestart(self: *TestApp) void {
        self.held_work_logs += 1;
    }

    fn writeDomainNotice(self: *TestApp, notice: types.SemanticNotice, _: bool) !void {
        try self.notices.appendSlice(self.alloc, notice.body);
    }

    pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }
};

/// An app that cannot stop its turns between steps: it has no restart wait,
/// so Ctrl+G still refuses while a response streams.
const StreamOnlyApp = struct {
    alloc: std.mem.Allocator,
    main_agent: struct {
        stream: struct { active: bool = false } = .{},
    } = .{},
    notices: std.ArrayList(u8) = .empty,

    fn prepareResumeHandoffForUpgrade(_: *StreamOnlyApp, _: anytype) !void {}
    fn requestUpgradeRelaunch(_: *StreamOnlyApp, _: []const u8) !void {}
    fn requestResumeHandoffForUpgrade(_: *StreamOnlyApp, _: anytype) void {}

    fn writeDomainNotice(self: *StreamOnlyApp, notice: types.SemanticNotice, _: bool) !void {
        try self.notices.appendSlice(self.alloc, notice.body);
    }

    pub fn agent(self: *StreamOnlyApp) @TypeOf(&self.main_agent) {
        return &self.main_agent;
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

test "app_upgrade_runtime refuses while another agent needs the user, and names it" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    app.needs_user_elsewhere = .{ .name = "reviewer", .doing = .needs_approval };
    var deps_state = TestDepsState{};
    const outcome = try Runtime(TestApp).applyReadyUpgradeWithDeps(&app, (&app).agent(), deps_state.deps());

    try std.testing.expectEqual(ApplyOutcome.unavailable, outcome);
    try std.testing.expectEqualStrings("upgrade is unavailable while reviewer needs approval", app.notices.items);
    try std.testing.expectEqual(@as(usize, 0), app.prepare_count);
    try std.testing.expectEqual(@as(usize, 0), deps_state.path_count);
    try std.testing.expect(!app.should_exit);
}

test "app_upgrade_runtime refuses while another instance has queued prompts, and names it" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    // A turn runs, so without the refusal fx would ask it to yield.
    app.turn_running = true;
    app.queued_elsewhere = "fx 2";
    var deps_state = TestDepsState{};
    const outcome = try Runtime(TestApp).applyReadyUpgradeWithDeps(&app, (&app).agent(), deps_state.deps());

    try std.testing.expectEqual(ApplyOutcome.unavailable, outcome);
    try std.testing.expectEqualStrings("upgrade is unavailable while fx 2 has queued prompts", app.notices.items);
    try std.testing.expectEqual(@as(usize, 0), app.yield_request_count);
    try std.testing.expect(!app.upgrader.restart_waits);
    try std.testing.expectEqual(@as(usize, 0), app.prepare_count);
    try std.testing.expectEqual(@as(usize, 0), deps_state.path_count);
    try std.testing.expect(!app.should_exit);
}

test "app_upgrade_runtime validates then requests normal relaunch handoff" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    var deps_state = TestDepsState{};
    const outcome = try Runtime(TestApp).applyReadyUpgradeWithDeps(&app, (&app).agent(), deps_state.deps());

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
        (&app).agent(),
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

    const outcome = try Runtime(TestApp).applyReadyUpgradeWithDeps(&app, (&app).agent(), deps_state.deps());

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
        (&app).agent(),
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

    const outcome = try Runtime(TestApp).applyReadyUpgradeWithDeps(&app, (&app).agent(), deps_state.deps());

    try std.testing.expectEqual(ApplyOutcome.not_ready, outcome);
    try std.testing.expectEqual(@as(usize, 0), deps_state.path_count);
    try std.testing.expect(std.mem.find(u8, app.notices.items, "no installed upgrade is ready") != null);
}

test "app_upgrade_runtime requires an active session before reload" {
    var app = TestApp{ .alloc = std.testing.allocator, .session_id = null };
    defer app.deinit();
    app.upgrader.state = .ready;
    var deps_state = TestDepsState{};

    const outcome = try Runtime(TestApp).applyReadyUpgradeWithDeps(&app, (&app).agent(), deps_state.deps());

    try std.testing.expectEqual(ApplyOutcome.unavailable, outcome);
    try std.testing.expectEqual(@as(usize, 0), deps_state.path_count);
    try std.testing.expect(std.mem.find(
        u8,
        app.notices.items,
        "SessionPersistenceUnavailable",
    ) != null);
}

test "app_upgrade_runtime rejects busy app state before reload" {
    var composer_app = TestApp{ .alloc = std.testing.allocator };
    defer composer_app.deinit();
    composer_app.upgrader.state = .ready;
    try composer_app.input_runtime.edit_state.input.appendSlice(std.testing.allocator, "draft prompt");
    var composer_deps = TestDepsState{};

    const composer_outcome = try Runtime(TestApp).applyReadyUpgradeWithDeps(&composer_app, (&composer_app).agent(), composer_deps.deps());
    try std.testing.expectEqual(ApplyOutcome.unavailable, composer_outcome);
    try std.testing.expectEqual(@as(usize, 0), composer_deps.path_count);
    try std.testing.expect(std.mem.find(u8, composer_app.notices.items, "current prompt") != null);
}

test "app_upgrade_runtime still refuses while a response streams in an app that cannot stop turns between steps" {
    var stream_app = StreamOnlyApp{ .alloc = std.testing.allocator };
    defer stream_app.notices.deinit(std.testing.allocator);
    stream_app.agent().stream.active = true;
    var stream_deps = TestDepsState{};

    const stream_outcome = try Runtime(StreamOnlyApp).applyReadyUpgradeWithDeps(&stream_app, (&stream_app).agent(), stream_deps.deps());
    try std.testing.expectEqual(ApplyOutcome.unavailable, stream_outcome);
    try std.testing.expectEqual(@as(usize, 0), stream_deps.path_count);
    try std.testing.expect(std.mem.find(u8, stream_app.notices.items, "response finishes") != null);
}

test "app_upgrade_runtime asks running turns to yield and exits once they stop" {
    const alloc = std.testing.allocator;
    var app = TestApp{ .alloc = alloc };
    defer app.deinit();
    app.upgrader.state = .ready;
    app.turn_running = true;
    // A response on screen no longer refuses the upgrade.
    app.agent().stream.active = true;
    var deps_state = TestDepsState{};

    const outcome = try Runtime(TestApp).applyReadyUpgradeWithDeps(&app, (&app).agent(), deps_state.deps());
    try std.testing.expectEqual(ApplyOutcome.waiting, outcome);
    try std.testing.expectEqual(@as(usize, 1), app.yield_request_count);
    try std.testing.expect(app.upgrader.restart_waits);
    try std.testing.expect(!app.should_exit);
    // Everything that can fail ran before any turn stopped.
    try std.testing.expectEqual(@as(usize, 1), app.prepare_count);
    try std.testing.expectEqual(@as(usize, 1), deps_state.path_count);
    try std.testing.expectEqualStrings("/tmp/fx-upgraded", app.relaunch_path[0..app.relaunch_path_len]);
    try std.testing.expectEqual(@as(usize, 1), app.request_handoff_count);

    // While a turn runs, the tick waits.
    Runtime(TestApp).collectUpgradeFacts(&app);
    try std.testing.expect(!app.should_exit);

    // A second Ctrl+G changes nothing.
    const again = try Runtime(TestApp).applyReadyUpgradeWithDeps(&app, (&app).agent(), deps_state.deps());
    try std.testing.expectEqual(ApplyOutcome.waiting, again);
    try std.testing.expectEqual(@as(usize, 1), app.yield_request_count);
    try std.testing.expectEqual(@as(usize, 1), deps_state.path_count);

    // The turns stopped, but a draft typed meanwhile holds the exit.
    app.turn_running = false;
    try app.input_runtime.edit_state.input.appendSlice(alloc, "draft");
    Runtime(TestApp).collectUpgradeFacts(&app);
    try std.testing.expect(!app.should_exit);
    app.input_runtime.edit_state.input.clearRetainingCapacity();

    Runtime(TestApp).collectUpgradeFacts(&app);
    try std.testing.expect(app.should_exit);
    try std.testing.expect(!app.upgrader.restart_waits);
    try std.testing.expectEqual(@as(usize, 1), app.held_work_logs);
}

test "app_upgrade_runtime holds the restart while a sent prompt waits for sign-in" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    app.turn_running = true;
    app.main_agent.stream.active = true;
    var deps_state = TestDepsState{};

    const outcome = try Runtime(TestApp).applyReadyUpgradeWithDeps(&app, (&app).agent(), deps_state.deps());
    try std.testing.expectEqual(ApplyOutcome.waiting, outcome);

    // The turn stopped, but a prompt sent while sign-in is pending holds the exit.
    app.turn_running = false;
    app.main_agent.submission.pending = 1;
    Runtime(TestApp).collectUpgradeFacts(&app);
    try std.testing.expect(!app.should_exit);

    app.main_agent.submission.pending = null;
    Runtime(TestApp).collectUpgradeFacts(&app);
    try std.testing.expect(app.should_exit);
}

test "app_upgrade_runtime refuses while a sent prompt waits to go out" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    app.main_agent.submission.pending = 1;
    var deps_state = TestDepsState{};

    const outcome = try Runtime(TestApp).applyReadyUpgradeWithDeps(&app, (&app).agent(), deps_state.deps());
    try std.testing.expectEqual(ApplyOutcome.unavailable, outcome);
    try std.testing.expect(std.mem.find(u8, app.notices.items, "while a sent prompt waits to go out") != null);
    try std.testing.expectEqual(@as(usize, 0), deps_state.path_count);
    try std.testing.expectEqual(@as(usize, 0), app.yield_request_count);
    try std.testing.expect(!app.should_exit);

    // Once the prompt has gone out, Ctrl+G relaunches at once, as with no turn.
    app.main_agent.submission.pending = null;
    const again = try Runtime(TestApp).applyReadyUpgradeWithDeps(&app, (&app).agent(), deps_state.deps());
    try std.testing.expectEqual(ApplyOutcome.relaunch_requested, again);
    try std.testing.expectEqual(@as(usize, 0), app.yield_request_count);
    try std.testing.expect(app.should_exit);
}

test "app_upgrade_runtime says the restart also waits for working subagents" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    app.turn_running = true;
    app.subagent_working = true;
    var deps_state = TestDepsState{};
    const outcome = try Runtime(TestApp).applyReadyUpgradeWithDeps(&app, (&app).agent(), deps_state.deps());
    try std.testing.expectEqual(ApplyOutcome.waiting, outcome);
    try std.testing.expectEqualStrings(restart_waits_for_subagents_notice, app.notices.items);
}

test "app_upgrade_runtime relaunches at once when no turn runs" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    var deps_state = TestDepsState{};
    const outcome = try Runtime(TestApp).applyReadyUpgradeWithDeps(&app, (&app).agent(), deps_state.deps());
    try std.testing.expectEqual(ApplyOutcome.relaunch_requested, outcome);
    try std.testing.expectEqual(@as(usize, 0), app.yield_request_count);
    try std.testing.expect(app.should_exit);
}

test "app_upgrade_runtime rejects mid key sequence before reload" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    app.terminal_input_runtime.terminal_action_pending = true;
    var deps = TestDepsState{};

    const outcome = try Runtime(TestApp).applyReadyUpgradeWithDeps(&app, (&app).agent(), deps.deps());
    try std.testing.expectEqual(ApplyOutcome.unavailable, outcome);
    try std.testing.expectEqual(@as(usize, 0), deps.path_count);
    try std.testing.expect(std.mem.find(u8, app.notices.items, "finish the key sequence") != null);
}
