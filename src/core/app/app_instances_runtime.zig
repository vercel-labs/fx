//! The host's instances. Every top-level fx instance the host
//! runs is launched the same way, with its own session, worker, transcript,
//! and profile, from the settings the host started with. The first instance
//! is only the first one launched. Subagents are not instances: an instance
//! or another subagent starts them.

const std = @import("std");
const agents = @import("../agents/agents.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const app_agents_runtime = @import("app_agents_runtime.zig");
const app_process_runtime = @import("app_process_runtime.zig");
const host_record = @import("host_record.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const config_runtime = @import("../config/config_runtime.zig");
const model_provider = @import("../config/model_provider.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

/// What every instance starts from: the per-agent settings the first one
/// started with, including the launch profile and the process's flags, as a
/// second fx started the same way would read them. Owned.
pub const Seed = struct {
    captured: bool = false,
    provider: model_provider.ProviderId = .gateway,
    configured_model: []u8 = &.{},
    model_source: config_runtime.ModelSource = .compiled_default,
    selected_model: []u8 = &.{},
    effort: types.ReasoningEffort = .auto,
    fast_mode: bool = false,
    fast_mode_model_bound: bool = false,
    configured_ultrafast_mode: bool = false,
    ultrafast_process_override: ?bool = null,
    effort_process_override: ?types.ReasoningEffort = null,
    fast_process_override: ?bool = null,
    provider_process_override: ?model_provider.ProviderId = null,
    permission_mode: types.PermissionMode = .ask,
    turn_settings: worker_runtime.AgentTurnSettings = .{},
    provider_order: [][]u8 = &.{},
    provider_strict: bool = false,
    agent_effort: types.ReasoningEffort = .auto,
    profile_name: ?[]u8 = null,

    pub fn deinit(self: *Seed, alloc: Allocator) void {
        alloc.free(self.configured_model);
        alloc.free(self.selected_model);
        for (self.provider_order) |name| alloc.free(name);
        alloc.free(self.provider_order);
        if (self.profile_name) |name| alloc.free(name);
        self.* = .{};
    }

    /// The preferences the first instance was configured with, as the
    /// bootstrap passed them. Copies every slice.
    pub fn capturePreferences(
        self: *Seed,
        alloc: Allocator,
        provider: model_provider.ProviderId,
        configured_model: []const u8,
        model_source: config_runtime.ModelSource,
        selected_model: []const u8,
        effort: types.ReasoningEffort,
        fast_mode: bool,
        fast_mode_model_bound: bool,
        configured_ultrafast_mode: bool,
        ultrafast_process_override: ?bool,
        effort_process_override: ?types.ReasoningEffort,
        fast_process_override: ?bool,
        provider_process_override: ?model_provider.ProviderId,
    ) !void {
        const configured = try alloc.dupe(u8, configured_model);
        errdefer alloc.free(configured);
        const selected = try alloc.dupe(u8, selected_model);
        alloc.free(self.configured_model);
        alloc.free(self.selected_model);
        self.configured_model = configured;
        self.selected_model = selected;
        self.provider = provider;
        self.model_source = model_source;
        self.effort = effort;
        self.fast_mode = fast_mode;
        self.fast_mode_model_bound = fast_mode_model_bound;
        self.configured_ultrafast_mode = configured_ultrafast_mode;
        self.ultrafast_process_override = ultrafast_process_override;
        self.effort_process_override = effort_process_override;
        self.fast_process_override = fast_process_override;
        self.provider_process_override = provider_process_override;
    }

    /// The first instance's turn settings, permission mode, and effort once
    /// the bootstrap set them. Copies the provider order.
    pub fn captureAgent(self: *Seed, alloc: Allocator, agent: *const agents.Agent, mode: types.PermissionMode) !void {
        const order = try alloc.alloc([]u8, agent.worker.agent_turn_settings.provider_order.len);
        var filled: usize = 0;
        errdefer {
            for (order[0..filled]) |name| alloc.free(name);
            alloc.free(order);
        }
        for (agent.worker.agent_turn_settings.provider_order, 0..) |name, index| {
            order[index] = try alloc.dupe(u8, name);
            filled += 1;
        }
        for (self.provider_order) |name| alloc.free(name);
        alloc.free(self.provider_order);
        self.provider_order = order;
        self.provider_strict = agent.worker.agent_turn_settings.provider_strict;
        self.turn_settings = agent.worker.agent_turn_settings;
        self.turn_settings.provider_order = &.{};
        self.agent_effort = agent.effort;
        self.permission_mode = mode;
        self.captured = true;
    }

    pub fn captureProfile(self: *Seed, alloc: Allocator, name: ?[]const u8) !void {
        const owned = if (name) |value| try alloc.dupe(u8, value) else null;
        if (self.profile_name) |old| alloc.free(old);
        self.profile_name = owned;
    }
};

pub const State = struct {
    seed: Seed = .{},
    /// Instances launched since the host started, the first one included.
    launched: usize = 0,
    /// How many instances startup opens: `--instances`, the test hook, or 1.
    startup_count: usize = 1,
    /// Backs the footer's instance label.
    label_buf: [32]u8 = undefined,
    /// Whether the first instance, kept in `App.main_agent`, still runs. It
    /// closes like any other and stays closed.
    first_open: bool = true,
    /// The resume command a launched instance's teardown made at exit, for
    /// when the user quit from its screen. Owned.
    exit_handoff: ?app_session_runtime.ResumeHandoff = null,
    /// This host's group id, named by its record file once two instances
    /// are open, or the restored group's.
    group_id: [host_record.group_id_len]u8 = undefined,
    has_group: bool = false,
    /// The session ids the record file lists now, in launch order, or none
    /// while there is no file. Owned.
    written: std.ArrayList([]u8) = .empty,
    /// Startup resumed the first instance's session, so its group comes
    /// back with the startup instances.
    restore_pending: bool = false,
    /// Startup opened the session picker, so the group of the session
    /// picked comes back then; a later in-app `/resume` brings back only
    /// that session.
    restore_on_pick: bool = false,

    pub fn deinit(self: *State, alloc: Allocator) void {
        self.seed.deinit(alloc);
        if (self.exit_handoff) |*handoff| handoff.deinit(alloc);
        self.exit_handoff = null;
        self.clearWritten(alloc);
        self.written.deinit(alloc);
    }

    fn clearWritten(self: *State, alloc: Allocator) void {
        for (self.written.items) |id| alloc.free(id);
        self.written.clearRetainingCapacity();
    }

    /// Takes the stashed exit resume command, if any. The caller owns it.
    pub fn takeExitHandoff(self: *State) ?app_session_runtime.ResumeHandoff {
        const handoff = self.exit_handoff;
        self.exit_handoff = null;
        return handoff;
    }
};

/// How many instances the E2E test hook asks startup to open, or 1. The
/// hook is `FX_TEST_INSTANCES`, like the other `FX_TEST_*` test overrides.
pub fn testHookCount() usize {
    const raw = io_mod.getenv("FX_TEST_INSTANCES") orelse return 1;
    const count = std.fmt.parseUnsigned(usize, std.mem.trim(u8, raw, " \t\r\n"), 10) catch return 1;
    return @max(count, 1);
}

pub fn Runtime(comptime App: type) type {
    return struct {
        const AgentsRuntime = app_agents_runtime.Runtime(App);
        const SessionRuntime = app_session_runtime.Runtime(App);
        const ChildAgent = app_agents_runtime.ChildAgent;

        /// Launches a new instance with a fresh session of its own, from the
        /// host's seed and `profile_name`, or the launch profile when null.
        /// Its worker starts now, as the first instance's does;
        /// it shows its welcome when it is first on screen. Returns it,
        /// listed last among the instances.
        pub fn launch(app: *App, profile_name: ?[]const u8) !*ChildAgent {
            return launchWith(app, profile_name, null);
        }

        /// Launches an instance that resumes saved session `session_id`, for
        /// a resumed host's group. Its conversation is drawn into its
        /// own transcript now, in its own screen context.
        pub fn launchResumed(app: *App, session_id: []const u8) !*ChildAgent {
            return launchWith(app, null, session_id);
        }

        fn resumeInContext(session_id: []const u8, app: *App, agent: *agents.Agent) anyerror!void {
            try SessionRuntime.resumeSessionById(app, agent, session_id);
        }

        fn launchWith(app: *App, profile_name: ?[]const u8, resume_id: ?[]const u8) !*ChildAgent {
            const seed = &app.instances.seed;
            if (!seed.captured) return error.HostNotStarted;
            const child = try AgentsRuntime.addInstance(app);
            errdefer AgentsRuntime.dropHosted(app, child);
            const agent = &child.agent;
            app_session_runtime.Persistence.initInto(&agent.session_persistence);
            const name = profile_name orelse seed.profile_name;
            if (name) |value| try app.applyInstanceProfile(agent, value);
            const profile_model = if (name != null) agent.profile.profile.model else null;
            try SessionRuntime.configureStartupPreferences(
                app,
                agent,
                seed.provider,
                seed.configured_model,
                seed.model_source,
                profile_model orelse seed.selected_model,
                seed.effort,
                seed.fast_mode,
                seed.fast_mode_model_bound,
                seed.configured_ultrafast_mode,
                seed.ultrafast_process_override,
                seed.effort_process_override,
                seed.fast_process_override,
                seed.provider_process_override,
            );
            agent.worker.agent_turn_settings = seed.turn_settings;
            agent.worker.agent_turn_settings.provider_order = &.{};
            try agent.worker.setProviderRouting(std.heap.c_allocator, constNames(seed.provider_order), seed.provider_strict);
            agent.effort = if (name != null) (agent.profile.profile.effort orelse seed.agent_effort) else seed.agent_effort;
            agent.worker.agent_turn_settings.effort = agent.effort;
            agent.permission_mode = app.instanceProfileMode(agent, seed.permission_mode);
            try SessionRuntime.initializePersistence(app, agent, resume_id != null);
            if (resume_id) |id| {
                try AgentsRuntime.visit(app, child, id, resumeInContext);
                child.view_built = true;
            } else {
                try SessionRuntime.beginFreshPersistedSession(app, agent);
                SessionRuntime.enableSessionStores(app, agent);
                try SessionRuntime.applyProcessModelOverride(app, agent);
            }
            try AgentsRuntime.nameInstance(app, child, SessionRuntime.activeSessionId(agent));
            child.session_attached = true;
            try app_process_runtime.Runtime(App).startAgentWorkerThread(app, agent);
            // A resumed instance sends again the request its session left
            // unfinished, as `fx --resume` does for the first one.
            if (resume_id != null) SessionRuntime.startPendingResume(app, agent);
            app.instances.launched += 1;
            debug_trace.eventf("host", "instance_launched", .{}, "agent={s} profile={s} instances={d} resumed={s}", .{
                child.id,
                name orelse "default",
                app.instances.launched,
                if (resume_id != null) "true" else "false",
            });
            return child;
        }

        /// Keeps the host record in step with the open instances: a
        /// file listing their sessions while two or more are open, none
        /// otherwise. Runs on the main loop and touches the disk only when
        /// the list changes, so a launch, a close, `/new`, and an in-app
        /// `/resume` all count alike. Waits while an instance has no session
        /// yet, such as during the startup picker.
        pub fn syncRecord(app: *App) void {
            const state = &app.instances;
            var count: usize = 0;
            var same = true;
            if (AgentsRuntime.firstOpen(app)) {
                const id = SessionRuntime.activeSessionId(&app.main_agent) orelse return;
                same = same and matchesWritten(state, count, id);
                count += 1;
            }
            for (app.child_agents.items) |child| {
                if (child.agent.role != .instance) continue;
                const id = SessionRuntime.activeSessionId(&child.agent) orelse return;
                same = same and matchesWritten(state, count, id);
                count += 1;
            }
            if (same and count == state.written.items.len) return;
            if (count < 2) {
                if (state.written.items.len == 0) return;
                state.clearWritten(app.alloc);
                if (state.has_group) withHostsDir(app, removeRecord);
                return;
            }
            state.clearWritten(app.alloc);
            if (AgentsRuntime.firstOpen(app)) appendWritten(app, SessionRuntime.activeSessionId(&app.main_agent).?) catch return;
            for (app.child_agents.items) |child| {
                if (child.agent.role != .instance) continue;
                appendWritten(app, SessionRuntime.activeSessionId(&child.agent).?) catch return;
            }
            if (!state.has_group) {
                state.group_id = host_record.newGroupId();
                state.has_group = true;
            }
            withHostsDir(app, writeRecord);
        }

        fn matchesWritten(state: *const State, index: usize, id: []const u8) bool {
            return index < state.written.items.len and std.mem.eql(u8, state.written.items[index], id);
        }

        fn appendWritten(app: *App, id: []const u8) !void {
            const copy = try app.alloc.dupe(u8, id);
            errdefer app.alloc.free(copy);
            try app.instances.written.append(app.alloc, copy);
        }

        fn withHostsDir(app: *App, comptime body: fn (*App, []const u8) anyerror!void) void {
            const home = io_mod.homeDir() orelse return;
            const dir = profile_paths.hostsDir(app.alloc, home) catch return;
            defer app.alloc.free(dir);
            body(app, dir) catch |err| {
                debug_trace.logf("host", "host_record_failed err={s}", .{@errorName(err)});
            };
        }

        fn writeRecord(app: *App, dir: []const u8) anyerror!void {
            const state = &app.instances;
            try host_record.write(app.alloc, dir, .{
                .group_id = &state.group_id,
                .updated_ms = io_mod.milliTimestamp(),
                .sessions = constNames(state.written.items),
            });
            debug_trace.eventf("host", "host_record_written", .{}, "group={s} sessions={d}", .{ &state.group_id, state.written.items.len });
        }

        fn removeRecord(app: *App, dir: []const u8) anyerror!void {
            try host_record.remove(app.alloc, dir, &app.instances.group_id);
            debug_trace.eventf("host", "host_record_removed", .{}, "group={s}", .{&app.instances.group_id});
        }

        /// Brings back the group of the session the first instance resumed
        /// at startup. Every other session its record lists
        /// comes back as an instance with its saved conversation, after the
        /// first and in their saved order, and the host keeps the group's
        /// id. A session that can't load is skipped with a notice. The first
        /// instance stays on screen.
        pub fn restoreGroup(app: *App) void {
            const resumed = SessionRuntime.activeSessionId(&app.main_agent) orelse return;
            const home = io_mod.homeDir() orelse return;
            const dir = profile_paths.hostsDir(app.alloc, home) catch return;
            defer app.alloc.free(dir);
            var loaded = host_record.loadAll(app.alloc, dir) catch |err| {
                debug_trace.logf("host", "host_restore_failed err={s}", .{@errorName(err)});
                return;
            };
            defer loaded.deinit();
            var restore = (host_record.chooseRestore(app.alloc, loaded.records, resumed) catch return) orelse return;
            defer restore.deinit(app.alloc);
            if (restore.group_id.len == host_record.group_id_len) {
                @memcpy(&app.instances.group_id, restore.group_id);
                app.instances.has_group = true;
            }
            debug_trace.eventf("host", "host_restore", .{}, "group={s} sessions={d}", .{ restore.group_id, restore.others.len });
            for (restore.others) |id| {
                _ = launchResumed(app, id) catch |err| {
                    debug_trace.logf("host", "host_restore_skipped session={s} err={s}", .{ id, @errorName(err) });
                    const body = app.alloc.print("Couldn't bring back session {s} with this one: {s}.", .{ id, @errorName(err) }) catch continue;
                    defer app.alloc.free(body);
                    app.writeDomainNotice(.{ .topic = "instances", .tone = .neutral, .body = body }, true) catch {};
                    continue;
                };
            }
        }

        fn constNames(names: []const []u8) []const []const u8 {
            return @ptrCast(names);
        }
    };
}
