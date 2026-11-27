const std = @import("std");
const agents = @import("../agents/agents.zig");
const runtime_profile = @import("../hosts/runtime_profile.zig");
const app_agents_runtime = @import("app_agents_runtime.zig");
const auto_upgrade = @import("../upgrade/auto_upgrade.zig");
const types = @import("../shared/types.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const upgrade_helpers = @import("../upgrade/upgrade_helpers.zig");
const editor_state = @import("../input/editor_state.zig");
const paste_framing = @import("../input/paste_framing.zig");

pub const ApplyOutcome = enum {
    not_ready,
    unavailable,
    relaunch_requested,
    /// The relaunch waits for the running turns to stop between steps or end.
    waiting,
    /// A second Ctrl+G cancelled the waiting restart: the turns go on.
    restart_cancelled,
};

const CurrentExecutablePathFn = *const fn (
    ?*anyopaque,
    []u8,
) upgrade_helpers.ExecutablePathError![]const u8;

pub const Deps = struct {
    ctx: ?*anyopaque = null,
    current_executable_path: CurrentExecutablePathFn = currentExecutablePathDefault,
};

/// What Ctrl+G says while the relaunch waits: a turn on the AI Gateway stops
/// at its next step and goes on after the restart, a turn on another
/// provider runs to its end (`orchestrator.zig` `canStopForRestart`), and
/// the ways out of the wait.
const restart_ways_out = "Ctrl+G cancels the restart, Esc twice interrupts the turn, /quit exits without the restart";
const restart_waits_notice = "fx restarts for the upgrade when the running turns stop or end; " ++ restart_ways_out;
const restart_waits_for_subagents_notice = "fx restarts for the upgrade when the running turns stop or end and the subagents finish; " ++ restart_ways_out;
const restart_cancelled_notice = "restart cancelled; Ctrl+G restarts for the upgrade later";
const restart_releasing_notice = "fx is restarting for the upgrade now";

/// Quiet time after the last key press before an idle automatic update restart
/// starts (`collectUpgradeFacts`).
pub const idle_restart_quiet_ms: i64 = 2000;
const idle_quiet_env_name = "FX_TEST_UPGRADE_IDLE_QUIET_MS";

fn idleRestartQuietMs() i64 {
    return parseIdleRestartQuietMs(io_mod.getenv(idle_quiet_env_name));
}

fn parseIdleRestartQuietMs(text: ?[]const u8) i64 {
    const value = text orelse return idle_restart_quiet_ms;
    const ms = std.fmt.parseInt(u32, value, 10) catch return idle_restart_quiet_ms;
    return if (ms > 0) @intCast(ms) else idle_restart_quiet_ms;
}

/// Whether `App` can stop running turns between steps for the restart.
/// Without it, Ctrl+G still refuses while a response streams.
/// A host that never upgrades itself, such as the browser terminal, has no restart to wait for.
fn supportsYield(comptime App: type) bool {
    return runtime_profile.allows(App, .auto_upgrade) and @hasDecl(App, "anyTurnRunning") and @hasDecl(App, "requestTurnYields") and
        @hasDecl(App, "anyTurnUnheld") and @hasDecl(App, "releaseTurnYields") and @hasDecl(App, "cancelTurnYields") and
        @hasDecl(App, "cancelResumeHandoffForUpgrade") and
        @hasField(App, "upgrader") and @hasField(@FieldType(App, "upgrader"), "restart");
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
            const now_ms = currentTimestampMs(app);
            syncReadySince(app, now_ms);
            _ = tryIdleAutoUpgrade(
                app,
                agents.screenAgentOf(app),
                now_ms,
                idleRestartQuietMs(),
                .{},
            );
        }

        fn syncReadySince(app: *App, now_ms: i64) void {
            if (comptime !(@hasField(App, "upgrader") and
                @hasField(@FieldType(App, "upgrader"), "ready_since_ms")))
            {
                return;
            }
            if (app.upgrader.getState() == auto_upgrade.State.ready) {
                if (app.upgrader.ready_since_ms == null) app.upgrader.ready_since_ms = now_ms;
            } else {
                app.upgrader.ready_since_ms = null;
            }
        }

        pub fn noteUserInput(app: *App, now_ms: i64) void {
            if (comptime @hasField(App, "upgrader") and
                @hasField(@FieldType(App, "upgrader"), "last_user_input_ms"))
            {
                app.upgrader.last_user_input_ms = now_ms;
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

        /// Restarts for the upgrade Ctrl+G asked for, in two ticks: once every
        /// turn holds at its step boundary or has ended, and nothing typed would
        /// be lost, the held turns are let go; once none runs, fx exits
        /// (`tests/tla/recovery/RestartWait.tla` Release, Exit).
        fn finishWaitingRestart(app: *App) void {
            if (comptime !supportsYield(App)) return;
            switch (app.upgrader.restart) {
                .none => return,
                .waiting => {
                    if (app.anyTurnUnheld() or draftPending(app)) return;
                    app.releaseTurnYields();
                    app.upgrader.restart = .releasing;
                    debug_trace.logf("upgrade", "event=restart_releases_held_turns", .{});
                },
                .releasing => {},
            }
            if (app.anyTurnRunning() or draftPending(app)) return;
            app.upgrader.restart = .none;
            if (comptime @hasDecl(App, "logHeldWorkForRestart")) app.logHeldWorkForRestart();
            debug_trace.logf("upgrade", "event=restart_after_yield", .{});
            if (comptime @hasField(App, "should_exit")) app.should_exit = true;
            requestFooterRender(app);
        }

        /// What the composer holds that exiting would lose, as the notice
        /// that names it, or null: a paste, typed text, images, or a prompt
        /// sent but not yet started. Ctrl+G refuses with it
        /// (`upgradeUnavailableNotice`), and a waiting restart holds its exit
        /// while one is there (`draftPending`).
        fn draftNotice(app: *App, agent: *AppAgent) ?[]const u8 {
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
            return null;
        }

        /// Whether the composer holds something exiting would lose
        /// (`draftNotice`). Ctrl+G refuses while it does, and the wait holds
        /// new text in the composer, so this only guards the exit.
        fn draftPending(app: *App) bool {
            return draftNotice(app, agents.screenAgentOf(app)) != null;
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
            // A host that never upgrades itself, such as the browser
            // terminal, says so at once: nothing after this runs there.
            if (comptime !runtime_profile.allows(App, .auto_upgrade)) {
                try writeUpgradeNotice(app, .neutral, "auto-upgrade is disabled");
                return .not_ready;
            }
            // A second Ctrl+G while the restart waits cancels it. Once the
            // held turns are let go, the restart is under way.
            if (comptime supportsYield(App)) {
                switch (app.upgrader.restart) {
                    .none => {},
                    .waiting => {
                        try cancelWaitingRestart(app);
                        return .restart_cancelled;
                    },
                    .releasing => {
                        try writeUpgradeNotice(app, .neutral, restart_releasing_notice);
                        return .waiting;
                    },
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
            // next step boundary and holds there, saved so the relaunched fx
            // continues it (`tests/tla/recovery/Resume.tla` Upgrade, Hold,
            // Relaunch), and fx exits once every turn holds or ends
            // (`collectUpgradeFacts`).
            if (comptime supportsYield(App)) {
                if (app.anyTurnRunning()) {
                    app.requestTurnYields();
                    app.upgrader.restart = .waiting;
                    debug_trace.logf("upgrade", "event=restart_waits_for_turns", .{});
                    try writeUpgradeNotice(app, .neutral, restartWaitsNotice(app));
                    return .waiting;
                }
            }
            if (comptime @hasField(App, "should_exit")) app.should_exit = true;
            return .relaunch_requested;
        }

        /// A second Ctrl+G while the restart waits: the held turns go on, queued
        /// work flows again, the relaunch Ctrl+G prepared is dropped, and a later
        /// exit is a plain one (`tests/tla/recovery/Resume.tla` CancelRestart).
        fn cancelWaitingRestart(app: *App) !void {
            app.upgrader.cancelRestart();
            app.cancelTurnYields();
            cancelUpgradeHandoffs(app);
            debug_trace.logf("upgrade", "event=restart_cancelled", .{});
            try writeUpgradeNotice(app, .neutral, restart_cancelled_notice);
        }

        /// Ctrl+G asked the agent on screen, which can be a subagent, for a
        /// resume handoff, and that agent may no longer be on screen, so every
        /// agent drops the handoff the restart asked for. A subagent's left in
        /// place would move to its instance at a later exit (`liftResumeIntent`).
        fn cancelUpgradeHandoffs(app: *App) void {
            app.cancelResumeHandoffForUpgrade(&app.main_agent);
            if (comptime @hasField(App, "child_agents")) {
                for (app.child_agents.items) |child| app.cancelResumeHandoffForUpgrade(&child.agent);
            }
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
            if (draftNotice(app, agent)) |notice| return notice;
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

        fn currentTimestampMs(app: *const App) i64 {
            if (comptime @hasField(App, "test_now_ms")) {
                if (app.test_now_ms) |now_ms| return now_ms;
            }
            return io_mod.milliTimestamp();
        }

        fn hasRunningShellOrTtySession(app: *App) bool {
            if (comptime agents.hasAgentField(App, "managed_executions")) {
                if (app.main_agent.managed_executions.hasRunningExecution()) return true;
                if (comptime @hasField(App, "child_agents")) {
                    for (app.child_agents.items) |child| {
                        if (child.agent.managed_executions.hasRunningExecution()) return true;
                    }
                }
            }
            if (comptime @hasField(App, "terminal_client") and
                @hasDecl(@FieldType(App, "terminal_client"), "hasRunningSession"))
            {
                if (app.terminal_client.hasRunningSession()) return true;
            }
            return false;
        }

        fn idleRestartQuietElapsed(app: *const App, now_ms: i64, quiet_ms: i64) bool {
            if (comptime @hasField(App, "upgrader") and
                @hasField(@FieldType(App, "upgrader"), "ready_since_ms"))
            {
                const ready_ms = app.upgrader.ready_since_ms orelse return false;
                if (now_ms - ready_ms < quiet_ms) return false;
            }
            if (comptime @hasField(App, "upgrader") and
                @hasField(@FieldType(App, "upgrader"), "last_user_input_ms"))
            {
                if (app.upgrader.last_user_input_ms) |last_ms| {
                    if (now_ms - last_ms < quiet_ms) return false;
                }
            }
            return true;
        }

        fn isIdleForAutoRestart(
            app: *App,
            agent: *AppAgent,
            now_ms: i64,
            quiet_ms: i64,
        ) bool {
            if (comptime !runtime_profile.allows(App, .auto_upgrade)) return false;
            if (!autoUpgradeEnabled(app)) return false;
            if (comptime @hasField(App, "should_exit")) {
                if (app.should_exit) return false;
            }
            if (comptime @hasField(App, "upgrader")) {
                if (app.upgrader.getState() != auto_upgrade.State.ready) return false;
                if (comptime @hasField(@FieldType(App, "upgrader"), "restart")) {
                    if (app.upgrader.restart != .none) return false;
                }
                if (comptime @hasField(@FieldType(App, "upgrader"), "auto_restart_failed")) {
                    if (app.upgrader.auto_restart_failed) return false;
                }
            }
            if (comptime @hasDecl(App, "anyTurnRunning")) {
                if (app.anyTurnRunning()) return false;
            }
            if (comptime @hasDecl(App, "anySubagentWorking")) {
                if (app.anySubagentWorking()) return false;
            }
            if (comptime agents.hasAgentField(App, "stream")) {
                if (agent.stream.active) return false;
            }
            if (upgradeUnavailableNotice(app, agent) != null) return false;
            if (comptime @hasDecl(App, "needsUserElsewhere")) {
                var name_buf: [32]u8 = undefined;
                if (app.needsUserElsewhere(&name_buf) != null) return false;
            }
            if (comptime @hasDecl(App, "queuedWorkElsewhere")) {
                var queue_name_buf: [32]u8 = undefined;
                if (app.queuedWorkElsewhere(&queue_name_buf) != null) return false;
            }
            if (hasRunningShellOrTtySession(app)) return false;
            return idleRestartQuietElapsed(app, now_ms, quiet_ms);
        }

        fn tryIdleAutoUpgrade(
            app: *App,
            agent: *AppAgent,
            now_ms: i64,
            quiet_ms: i64,
            deps: Deps,
        ) bool {
            if (!isIdleForAutoRestart(app, agent, now_ms, quiet_ms)) return false;
            const outcome = applyReadyUpgradeWithDeps(app, agent, deps) catch |err| {
                debug_trace.logf("upgrade", "event=idle_auto_restart_failed err={s}", .{@errorName(err)});
                if (comptime @hasField(App, "upgrader") and
                    @hasField(@FieldType(App, "upgrader"), "auto_restart_failed"))
                {
                    app.upgrader.auto_restart_failed = true;
                }
                return false;
            };
            if (outcome != .relaunch_requested) {
                if (comptime @hasField(App, "upgrader") and
                    @hasField(@FieldType(App, "upgrader"), "auto_restart_failed"))
                {
                    app.upgrader.auto_restart_failed = true;
                }
                return false;
            }
            debug_trace.logf("upgrade", "event=idle_auto_restart_started", .{});
            return true;
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
    restart: auto_upgrade.RestartWait = .none,
    cancel_count: usize = 0,
    last_user_input_ms: ?i64 = null,
    ready_since_ms: ?i64 = null,
    auto_restart_failed: bool = false,

    fn getState(self: *TestUpgrader) auto_upgrade.State {
        return self.state;
    }

    fn stop(self: *TestUpgrader) void {
        self.stop_count += 1;
    }

    fn cancelRestart(self: *TestUpgrader) void {
        self.cancel_count += 1;
        self.restart = .none;
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

const TestToggle = struct {
    active: bool = false,

    pub fn isActive(self: *const TestToggle) bool {
        return self.active;
    }
};

const TestSessionPersistence = struct {
    session_picker: struct { active: bool = false } = .{},
};

const TestManagedExecutions = struct {
    running: bool = false,

    pub fn hasRunningExecution(self: *const TestManagedExecutions) bool {
        return self.running;
    }
};

const TestAuth = struct {
    api_key_entry: bool = false,

    pub fn apiKeyEntryActive(self: *const TestAuth) bool {
        return self.api_key_entry;
    }
};

const TestSubagents = struct {
    view_active: bool = false,

    pub fn isViewActive(self: *const TestSubagents) bool {
        return self.view_active;
    }
};

const TestTerminal = struct {
    full_transcript_active: bool = false,

    pub fn fullTranscriptScreenActive(self: *const TestTerminal) bool {
        return self.full_transcript_active;
    }
};

const TestTerminalClient = struct {
    running: bool = false,

    pub fn hasRunningSession(self: *const TestTerminalClient) bool {
        return self.running;
    }
};

const TestAgent = struct {
    worker: TestWorker = .{},
    stream: struct { active: bool = false } = .{},
    submission: struct { pending: ?u8 = null } = .{},
    pending_images: std.ArrayList(u8) = .empty,
    question_prompt: TestToggle = .{},
    approval_prompt: TestToggle = .{},
    session_persistence: TestSessionPersistence = .{},
    managed_executions: TestManagedExecutions = .{},
    role: enum { instance, subagent } = .instance,
    /// Whether this agent holds the resume handoff an upgrade asked for.
    upgrade_handoff: bool = false,
};

const TestChild = struct {
    agent: TestAgent = .{},
};

const TestApp = struct {
    alloc: std.mem.Allocator,
    auto_upgrade_enabled: bool = true,
    upgrader: TestUpgrader = .{},
    main_agent: TestAgent = .{},
    child_agents: std.ArrayList(*TestChild) = .empty,
    input_runtime: TestInputRuntime = .{},
    terminal_input_runtime: TestTerminalInputRuntime = .{},
    auth: TestAuth = .{},
    subagents: TestSubagents = .{},
    terminal: TestTerminal = .{},
    terminal_client: TestTerminalClient = .{},
    shell: TestShell = .{},
    should_exit: bool = false,
    session_id: ?[]const u8 = "session-123",
    test_now_ms: ?i64 = null,
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
    turn_held: bool = false,
    release_count: usize = 0,
    cancel_yield_count: usize = 0,
    cancel_handoff_count: usize = 0,

    fn deinit(self: *TestApp) void {
        self.input_runtime.edit_state.deinit(self.alloc);
        self.input_runtime.paste.deinit(self.alloc);
        self.main_agent.pending_images.deinit(self.alloc);
        for (self.child_agents.items) |child| child.agent.pending_images.deinit(self.alloc);
        self.notices.deinit(self.alloc);
        self.child_agents.deinit(self.alloc);
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

    fn requestResumeHandoffForUpgrade(self: *TestApp, asked: *TestAgent) void {
        self.request_handoff_count += 1;
        asked.upgrade_handoff = true;
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

    pub fn anyTurnUnheld(self: *TestApp) bool {
        return self.turn_running and !self.turn_held;
    }

    pub fn releaseTurnYields(self: *TestApp) void {
        self.release_count += 1;
    }

    pub fn cancelTurnYields(self: *TestApp) void {
        self.cancel_yield_count += 1;
    }

    pub fn cancelResumeHandoffForUpgrade(self: *TestApp, asked: *TestAgent) void {
        self.cancel_handoff_count += 1;
        asked.upgrade_handoff = false;
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
    try std.testing.expectEqual(auto_upgrade.RestartWait.none, app.upgrader.restart);
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

const NoUpgradeUpgrader = struct {
    state: auto_upgrade.State = .ready,
    restart: auto_upgrade.RestartWait = .none,

    fn getState(self: *NoUpgradeUpgrader) auto_upgrade.State {
        return self.state;
    }
};

/// A host that never upgrades itself, such as the browser terminal. A turn
/// can run on it, but nothing restarts the host, so it asks no turn to stop.
const NoUpgradeHostApp = struct {
    pub const host_profile = runtime_profile.wasm;

    alloc: std.mem.Allocator,
    main_agent: struct {} = .{},
    upgrader: NoUpgradeUpgrader = .{},
    notices: std.ArrayList(u8) = .empty,
    turn_running: bool = false,
    yield_request_count: usize = 0,

    pub fn anyTurnRunning(self: *NoUpgradeHostApp) bool {
        return self.turn_running;
    }

    pub fn requestTurnYields(self: *NoUpgradeHostApp) void {
        self.yield_request_count += 1;
    }

    fn prepareResumeHandoffForUpgrade(_: *NoUpgradeHostApp, _: anytype) !void {}
    fn requestUpgradeRelaunch(_: *NoUpgradeHostApp, _: []const u8) !void {}
    fn requestResumeHandoffForUpgrade(_: *NoUpgradeHostApp, _: anytype) void {}

    fn writeDomainNotice(self: *NoUpgradeHostApp, notice: types.SemanticNotice, _: bool) !void {
        try self.notices.appendSlice(self.alloc, notice.body);
    }

    pub fn agent(self: *NoUpgradeHostApp) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }
};

test "app_upgrade_runtime on a host that never upgrades itself says so and asks no turn to stop" {
    var app = NoUpgradeHostApp{ .alloc = std.testing.allocator };
    defer app.notices.deinit(std.testing.allocator);
    app.turn_running = true;
    var deps_state = TestDepsState{};

    const outcome = try Runtime(NoUpgradeHostApp).applyReadyUpgradeWithDeps(&app, (&app).agent(), deps_state.deps());
    try std.testing.expectEqual(ApplyOutcome.not_ready, outcome);
    try std.testing.expectEqualStrings("auto-upgrade is disabled", app.notices.items);
    try std.testing.expectEqual(@as(usize, 0), app.yield_request_count);
    try std.testing.expectEqual(auto_upgrade.RestartWait.none, app.upgrader.restart);
    try std.testing.expectEqual(@as(usize, 0), deps_state.path_count);
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
    try std.testing.expectEqual(auto_upgrade.RestartWait.waiting, app.upgrader.restart);
    try std.testing.expect(!app.should_exit);
    // Everything that can fail ran before any turn stopped.
    try std.testing.expectEqual(@as(usize, 1), app.prepare_count);
    try std.testing.expectEqual(@as(usize, 1), deps_state.path_count);
    try std.testing.expectEqualStrings("/tmp/fx-upgraded", app.relaunch_path[0..app.relaunch_path_len]);
    try std.testing.expectEqual(@as(usize, 1), app.request_handoff_count);

    // While a turn runs, the tick waits.
    Runtime(TestApp).collectUpgradeFacts(&app);
    try std.testing.expect(!app.should_exit);

    // The turn stops and holds for the restart. A draft typed meanwhile holds the release.
    app.turn_held = true;
    try app.input_runtime.edit_state.input.appendSlice(alloc, "draft");
    Runtime(TestApp).collectUpgradeFacts(&app);
    try std.testing.expectEqual(@as(usize, 0), app.release_count);
    try std.testing.expect(!app.should_exit);
    app.input_runtime.edit_state.input.clearRetainingCapacity();

    // The draft is gone: the held turn is let go, and fx waits for it to return.
    Runtime(TestApp).collectUpgradeFacts(&app);
    try std.testing.expectEqual(@as(usize, 1), app.release_count);
    try std.testing.expectEqual(auto_upgrade.RestartWait.releasing, app.upgrader.restart);
    try std.testing.expect(!app.should_exit);

    // The held turn returned.
    app.turn_running = false;
    app.turn_held = false;
    Runtime(TestApp).collectUpgradeFacts(&app);
    try std.testing.expect(app.should_exit);
    try std.testing.expectEqual(auto_upgrade.RestartWait.none, app.upgrader.restart);
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

test "app_upgrade_runtime cancels the waiting restart on a second Ctrl+G" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    app.turn_running = true;
    var deps_state = TestDepsState{};

    const first = try Runtime(TestApp).applyReadyUpgradeWithDeps(&app, (&app).agent(), deps_state.deps());
    try std.testing.expectEqual(ApplyOutcome.waiting, first);

    const second = try Runtime(TestApp).applyReadyUpgradeWithDeps(&app, (&app).agent(), deps_state.deps());
    try std.testing.expectEqual(ApplyOutcome.restart_cancelled, second);
    try std.testing.expectEqual(auto_upgrade.RestartWait.none, app.upgrader.restart);
    try std.testing.expectEqual(@as(usize, 1), app.upgrader.cancel_count);
    try std.testing.expectEqual(@as(usize, 1), app.cancel_yield_count);
    try std.testing.expectEqual(@as(usize, 1), app.cancel_handoff_count);
    try std.testing.expect(std.mem.endsWith(u8, app.notices.items, restart_cancelled_notice));

    // With the restart cancelled, a turn that holds releases nothing and fx stays.
    app.turn_held = true;
    Runtime(TestApp).collectUpgradeFacts(&app);
    try std.testing.expectEqual(@as(usize, 0), app.release_count);
    try std.testing.expect(!app.should_exit);

    const third = try Runtime(TestApp).applyReadyUpgradeWithDeps(&app, (&app).agent(), deps_state.deps());
    try std.testing.expectEqual(ApplyOutcome.waiting, third);
    try std.testing.expectEqual(@as(usize, 2), app.yield_request_count);
}

test "app_upgrade_runtime cancel takes back the resume handoff Ctrl+G asked of a subagent on screen" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    var instance = TestChild{};
    var subagent = TestChild{ .agent = .{ .role = .subagent } };
    try app.child_agents.appendSlice(app.alloc, &.{ &instance, &subagent });
    app.upgrader.state = .ready;
    app.turn_running = true;
    var deps_state = TestDepsState{};

    // Ctrl+G on the subagent's screen asks that subagent for the handoff.
    const first = try Runtime(TestApp).applyReadyUpgradeWithDeps(&app, &subagent.agent, deps_state.deps());
    try std.testing.expectEqual(ApplyOutcome.waiting, first);
    try std.testing.expect(subagent.agent.upgrade_handoff);

    // The second Ctrl+G comes from main's screen.
    const second = try Runtime(TestApp).applyReadyUpgradeWithDeps(&app, &app.main_agent, deps_state.deps());
    try std.testing.expectEqual(ApplyOutcome.restart_cancelled, second);
    try std.testing.expect(!subagent.agent.upgrade_handoff);
    try std.testing.expect(!instance.agent.upgrade_handoff);
    try std.testing.expect(!app.main_agent.upgrade_handoff);
}

test "app_upgrade_runtime says the restart is under way once the held turns are let go" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    app.turn_running = true;
    var deps_state = TestDepsState{};

    const waiting = try Runtime(TestApp).applyReadyUpgradeWithDeps(&app, (&app).agent(), deps_state.deps());
    try std.testing.expectEqual(ApplyOutcome.waiting, waiting);

    app.turn_held = true;
    Runtime(TestApp).collectUpgradeFacts(&app);
    try std.testing.expectEqual(auto_upgrade.RestartWait.releasing, app.upgrader.restart);

    const again = try Runtime(TestApp).applyReadyUpgradeWithDeps(&app, (&app).agent(), deps_state.deps());
    try std.testing.expectEqual(ApplyOutcome.waiting, again);
    try std.testing.expect(std.mem.endsWith(u8, app.notices.items, restart_releasing_notice));
    try std.testing.expectEqual(@as(usize, 0), app.upgrader.cancel_count);
    try std.testing.expectEqual(auto_upgrade.RestartWait.releasing, app.upgrader.restart);
}

test "app_upgrade_runtime names the ways out of the restart wait" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    app.turn_running = true;
    var deps_state = TestDepsState{};

    const outcome = try Runtime(TestApp).applyReadyUpgradeWithDeps(&app, (&app).agent(), deps_state.deps());
    try std.testing.expectEqual(ApplyOutcome.waiting, outcome);
    try std.testing.expectEqualStrings(
        "fx restarts for the upgrade when the running turns stop or end; Ctrl+G cancels the restart, Esc twice interrupts the turn, /quit exits without the restart",
        app.notices.items,
    );
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

fn expectAutoRestartHeldUntilCleared(app: *TestApp, clear: *const fn (*TestApp) void) !void {
    if (app.upgrader.state == .ready and app.upgrader.ready_since_ms == null) {
        app.upgrader.ready_since_ms = 10_000;
    }
    if (app.test_now_ms == null) {
        app.test_now_ms = 12_000;
    }
    Runtime(TestApp).collectUpgradeFacts(app);
    try std.testing.expect(!app.should_exit);
    try std.testing.expectEqual(@as(usize, 0), app.prepare_count);
    try std.testing.expectEqual(@as(usize, 0), app.relaunch_path_len);

    clear(app);
    Runtime(TestApp).collectUpgradeFacts(app);
    try std.testing.expect(app.should_exit);
    try std.testing.expectEqual(@as(usize, 1), app.prepare_count);
    try std.testing.expect(app.relaunch_path_len > 0);
}

test "app_upgrade_runtime auto-restarts when idle and auto_upgrade is on" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    app.upgrader.ready_since_ms = 10_000;
    app.test_now_ms = 12_000;

    Runtime(TestApp).collectUpgradeFacts(&app);

    try std.testing.expect(app.should_exit);
    try std.testing.expectEqual(@as(usize, 1), app.prepare_count);
    try std.testing.expectEqual(@as(usize, 1), app.request_handoff_count);
    try std.testing.expect(app.relaunch_path_len > 0);
}

test "app_upgrade_runtime auto-restart stays off when auto_upgrade is disabled" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.auto_upgrade_enabled = false;
    app.upgrader.state = .ready;
    app.upgrader.ready_since_ms = 10_000;
    app.test_now_ms = 12_000;

    Runtime(TestApp).collectUpgradeFacts(&app);

    try std.testing.expect(!app.should_exit);
    try std.testing.expectEqual(@as(usize, 0), app.prepare_count);
    try std.testing.expectEqual(@as(usize, 0), app.relaunch_path_len);
}

test "app_upgrade_runtime auto-restart waits until update state is ready" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .downloading;
    app.test_now_ms = 10_000;

    Runtime(TestApp).collectUpgradeFacts(&app);
    try std.testing.expect(!app.should_exit);
    try std.testing.expect(app.upgrader.ready_since_ms == null);

    app.upgrader.state = .ready;
    Runtime(TestApp).collectUpgradeFacts(&app);
    try std.testing.expect(!app.should_exit);
    try std.testing.expectEqual(@as(?i64, 10_000), app.upgrader.ready_since_ms);

    app.test_now_ms = 12_000;
    Runtime(TestApp).collectUpgradeFacts(&app);
    try std.testing.expect(app.should_exit);
    try std.testing.expectEqual(@as(usize, 1), app.prepare_count);
}

test "app_upgrade_runtime waits quiet time after .ready even when idle for a long time" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .downloading;
    app.upgrader.last_user_input_ms = 1_000;
    app.test_now_ms = 100_000;

    Runtime(TestApp).collectUpgradeFacts(&app);
    try std.testing.expect(!app.should_exit);

    // .ready lands after a long idle period: must draw notice first and wait
    // the full quiet window after .ready before restarting.
    app.upgrader.state = .ready;
    app.upgrader.render_dirty = true;
    Runtime(TestApp).collectUpgradeFacts(&app);
    try std.testing.expect(!app.should_exit);
    try std.testing.expectEqual(@as(usize, 1), app.shell.render_requests.footer_count);
    try std.testing.expectEqual(@as(?i64, 100_000), app.upgrader.ready_since_ms);

    app.test_now_ms = 101_999;
    Runtime(TestApp).collectUpgradeFacts(&app);
    try std.testing.expect(!app.should_exit);

    app.test_now_ms = 102_000;
    Runtime(TestApp).collectUpgradeFacts(&app);
    try std.testing.expect(app.should_exit);
    try std.testing.expectEqual(@as(usize, 1), app.prepare_count);
}

test "app_upgrade_runtime auto-restart holds while a turn is running" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    app.turn_running = true;

    try expectAutoRestartHeldUntilCleared(&app, struct {
        fn clear(target: *TestApp) void {
            target.turn_running = false;
        }
    }.clear);
}

test "app_upgrade_runtime auto-restart holds while a subagent is working" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    app.subagent_working = true;

    try expectAutoRestartHeldUntilCleared(&app, struct {
        fn clear(target: *TestApp) void {
            target.subagent_working = false;
        }
    }.clear);
}

test "app_upgrade_runtime auto-restart holds while a restart already waits" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    app.turn_running = true;
    app.upgrader.restart = .waiting;

    Runtime(TestApp).collectUpgradeFacts(&app);
    try std.testing.expect(!app.should_exit);
    try std.testing.expectEqual(@as(usize, 0), app.prepare_count);
    try std.testing.expectEqual(auto_upgrade.RestartWait.waiting, app.upgrader.restart);
}

test "app_upgrade_runtime auto-restart holds while prompts are queued" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    app.main_agent.worker.queued_count = 1;

    try expectAutoRestartHeldUntilCleared(&app, struct {
        fn clear(target: *TestApp) void {
            target.main_agent.worker.queued_count = 0;
        }
    }.clear);
}

test "app_upgrade_runtime auto-restart holds while composer has draft text" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    try app.input_runtime.edit_state.input.appendSlice(app.alloc, "draft");

    try expectAutoRestartHeldUntilCleared(&app, struct {
        fn clear(target: *TestApp) void {
            target.input_runtime.edit_state.input.clearRetainingCapacity();
        }
    }.clear);
}

test "app_upgrade_runtime auto-restart holds while a paste is active" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    app.input_runtime.paste.begin(.composer, 1024);

    try expectAutoRestartHeldUntilCleared(&app, struct {
        fn clear(target: *TestApp) void {
            target.input_runtime.paste.finishHandled();
        }
    }.clear);
}

test "app_upgrade_runtime auto-restart holds while pending images exist" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    try app.main_agent.pending_images.append(app.alloc, 1);

    try expectAutoRestartHeldUntilCleared(&app, struct {
        fn clear(target: *TestApp) void {
            target.main_agent.pending_images.clearRetainingCapacity();
        }
    }.clear);
}

test "app_upgrade_runtime auto-restart holds while a sent prompt waits to go out" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    app.main_agent.submission.pending = 1;

    try expectAutoRestartHeldUntilCleared(&app, struct {
        fn clear(target: *TestApp) void {
            target.main_agent.submission.pending = null;
        }
    }.clear);
}

test "app_upgrade_runtime auto-restart holds while a question is open" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    app.main_agent.question_prompt.active = true;

    try expectAutoRestartHeldUntilCleared(&app, struct {
        fn clear(target: *TestApp) void {
            target.main_agent.question_prompt.active = false;
        }
    }.clear);
}

test "app_upgrade_runtime auto-restart holds while an approval is open" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    app.main_agent.approval_prompt.active = true;

    try expectAutoRestartHeldUntilCleared(&app, struct {
        fn clear(target: *TestApp) void {
            target.main_agent.approval_prompt.active = false;
        }
    }.clear);
}

test "app_upgrade_runtime auto-restart holds during API key entry" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    app.auth.api_key_entry = true;

    try expectAutoRestartHeldUntilCleared(&app, struct {
        fn clear(target: *TestApp) void {
            target.auth.api_key_entry = false;
        }
    }.clear);
}

test "app_upgrade_runtime auto-restart holds while subagent view is open" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    app.subagents.view_active = true;

    try expectAutoRestartHeldUntilCleared(&app, struct {
        fn clear(target: *TestApp) void {
            target.subagents.view_active = false;
        }
    }.clear);
}

test "app_upgrade_runtime auto-restart holds while session picker is open" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    app.main_agent.session_persistence.session_picker.active = true;

    try expectAutoRestartHeldUntilCleared(&app, struct {
        fn clear(target: *TestApp) void {
            target.main_agent.session_persistence.session_picker.active = false;
        }
    }.clear);
}

test "app_upgrade_runtime auto-restart holds while full transcript screen is open" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    app.terminal.full_transcript_active = true;

    try expectAutoRestartHeldUntilCleared(&app, struct {
        fn clear(target: *TestApp) void {
            target.terminal.full_transcript_active = false;
        }
    }.clear);
}

test "app_upgrade_runtime auto-restart holds while a terminal key sequence is pending" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    app.terminal_input_runtime.terminal_action_pending = true;

    try expectAutoRestartHeldUntilCleared(&app, struct {
        fn clear(target: *TestApp) void {
            target.terminal_input_runtime.terminal_action_pending = false;
        }
    }.clear);
}

test "app_upgrade_runtime auto-restart holds while another agent needs the user" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    app.needs_user_elsewhere = .{ .name = "reviewer", .doing = .needs_approval };

    try expectAutoRestartHeldUntilCleared(&app, struct {
        fn clear(target: *TestApp) void {
            target.needs_user_elsewhere = null;
        }
    }.clear);
}

test "app_upgrade_runtime auto-restart holds while another instance has queued prompts" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    app.queued_elsewhere = "fx 2";

    try expectAutoRestartHeldUntilCleared(&app, struct {
        fn clear(target: *TestApp) void {
            target.queued_elsewhere = null;
        }
    }.clear);
}

test "app_upgrade_runtime auto-restart holds while a background shell session runs" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    app.main_agent.managed_executions.running = true;

    try expectAutoRestartHeldUntilCleared(&app, struct {
        fn clear(target: *TestApp) void {
            target.main_agent.managed_executions.running = false;
        }
    }.clear);
}

test "app_upgrade_runtime auto-restart holds while a child background shell session runs" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    var child = TestChild{};
    child.agent.managed_executions.running = true;
    try app.child_agents.append(app.alloc, &child);
    app.upgrader.state = .ready;

    try expectAutoRestartHeldUntilCleared(&app, struct {
        fn clear(target: *TestApp) void {
            target.child_agents.items[0].agent.managed_executions.running = false;
        }
    }.clear);
}

test "app_upgrade_runtime auto-restart holds while a tty session runs" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    app.terminal_client.running = true;

    try expectAutoRestartHeldUntilCleared(&app, struct {
        fn clear(target: *TestApp) void {
            target.terminal_client.running = false;
        }
    }.clear);
}

test "app_upgrade_runtime auto-restart holds during the quiet time after a key press" {
    var app = TestApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.upgrader.state = .ready;
    app.upgrader.ready_since_ms = 1_000;
    app.upgrader.last_user_input_ms = 10_000;
    app.test_now_ms = 11_999;

    try expectAutoRestartHeldUntilCleared(&app, struct {
        fn clear(target: *TestApp) void {
            target.test_now_ms = 12_000;
        }
    }.clear);
}

test "app_upgrade_runtime parses idle quiet time override" {
    try std.testing.expectEqual(@as(i64, 2000), idle_restart_quiet_ms);
    try std.testing.expectEqual(idle_restart_quiet_ms, parseIdleRestartQuietMs(null));
    try std.testing.expectEqual(idle_restart_quiet_ms, parseIdleRestartQuietMs("0"));
    try std.testing.expectEqual(idle_restart_quiet_ms, parseIdleRestartQuietMs("-5"));
    try std.testing.expectEqual(idle_restart_quiet_ms, parseIdleRestartQuietMs("fast"));
    try std.testing.expectEqual(@as(i64, 150), parseIdleRestartQuietMs("150"));
    try std.testing.expectEqual(@as(i64, 3_600_000), parseIdleRestartQuietMs("3600000"));
}

test "app_upgrade_runtime idle auto-restart does not repeat failed relaunch notices" {
    var app = TestApp{
        .alloc = std.testing.allocator,
        .session_id = null,
    };
    defer app.deinit();
    app.upgrader.state = .ready;
    app.upgrader.ready_since_ms = 10_000;
    app.test_now_ms = 12_000;

    Runtime(TestApp).collectUpgradeFacts(&app);
    try std.testing.expect(!app.should_exit);
    try std.testing.expectEqual(@as(usize, 1), app.prepare_count);
    try std.testing.expect(app.upgrader.auto_restart_failed);

    Runtime(TestApp).collectUpgradeFacts(&app);
    try std.testing.expectEqual(@as(usize, 1), app.prepare_count);
}
