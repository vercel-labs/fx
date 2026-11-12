const std = @import("std");
const profile_paths = @import("../shared/profile_paths.zig");
const agents = @import("../agents/agents.zig");
const runtime_profile = @import("../hosts/runtime_profile.zig");
const app_permission_runtime = @import("app_permission_runtime.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const app_loop_runtime = @import("app_loop_runtime.zig");
const session_display_metadata = @import("../session/session_display_metadata.zig");
const app_bootstrap_runtime = @import("app_bootstrap_runtime.zig");
const io_mod = @import("../shared/io.zig");
const shell_snapshot = @import("../terminal/shell_snapshot.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const credentials = @import("../auth/credentials.zig");
const credits_lookup = @import("credits_lookup.zig");
const gateway_provider = @import("../gateway/gateway_provider.zig");
const token_pass = @import("../gateway/token_pass.zig");
const host = @import("../hosts/host.zig");
const change_tracker_mod = @import("../workspace/change_tracker.zig");
const command_router = @import("../slash_commands/command_router.zig");
const command_specs = @import("../slash_commands/command_specs.zig");
const config_runtime = @import("../config/config_runtime.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const editor_state = @import("../input/editor_state.zig");
const settings_catalog = @import("../config/settings_catalog.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const feedback_runtime = @import("../feedback/runtime.zig");
const output_contracts = @import("../output/output_contracts.zig");
const workspace_commands = @import("../workspace/workspace_commands.zig");
const image_commands = @import("../images/image_commands.zig");
const app_mcp_runtime = @import("app_mcp_runtime.zig");
const model_cache_runtime = @import("model_cache_runtime.zig");
const provider_runtime = @import("provider_runtime.zig");
const permissions = @import("../permissions/permissions.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const skill_commands = @import("../skills/skill_commands.zig");
const skill_runtime = @import("../skills/skill_runtime.zig");
const text_utils = @import("../shared/text_utils.zig");
const trace_report = @import("trace_report.zig");
const session_commands = @import("../session/session_commands.zig");
const info_panel = @import("../input/info_panel.zig");
const usage = @import("../../usage/usage.zig");
const usage_host = @import("usage_host.zig");
const types = @import("../shared/types.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const transcript_runtime = @import("../../ui/transcript/runtime.zig");
const test_builtin_skills = if (@import("builtin").is_test)
    @import("../../builtins/skills.zig")
else
    struct {};

fn finish_trace_notice(app: anytype, entry_id: u32, tone: types.NoticeTone, body: []const u8) !void {
    const notice: types.SemanticNotice = .{
        .topic = "",
        .tone = tone,
        .body = body,
    };
    if (!try app.replaceDomainNotice(entry_id, notice)) {
        _ = try app.appendDomainNotice(notice);
    }
    app.shell.render_requests.request(.transcript);
}

const TraceReportDisposition = union(enum) {
    copied_file: []const u8,
    copy_failed: []const u8,
    saved: []const u8,
    unavailable,
};

/// Returns an owned trace notice whose bytes belong to the caller.
fn format_trace_notice(
    alloc: std.mem.Allocator,
    disposition: TraceReportDisposition,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    switch (disposition) {
        .copied_file => try out.writer.writeAll("Trace copied to clipboard. Review and redact it before sharing."),
        .copy_failed => |path| try out.writer.print("Clipboard copy failed. Trace saved at {s}. Review and redact it before sharing.", .{path}),
        .saved => |path| try out.writer.print("Trace saved at {s}. Review and redact it before sharing.", .{path}),
        .unavailable => try out.writer.writeAll("Could not create trace."),
    }
    return out.toOwnedSlice();
}

fn persistUserPreferences(
    app: anytype,
    label: []const u8,
    patch: config_runtime.UserSettingsPatch,
    runtime_changed: bool,
) !void {
    var attempt = config_runtime.attemptUserPreferences(app.alloc, patch);
    defer attempt.deinit(app.alloc);
    switch (attempt) {
        .failure => |failure| try session_commands.reportUserSettingsFailure(
            app,
            label,
            failure.err,
            failure.cleanup,
            runtime_changed,
        ),
        .outcome => |outcome| _ = try session_commands.reportUserSettingsCommit(
            app,
            label,
            patch,
            outcome,
            null,
            true,
        ),
    }
}

fn clearSessionForClearCommand(app: anytype) !void {
    try app.clearSession(agents.screenAgentOf(app));
}

noinline fn parseWorkspaceCommand(rest: []const u8) !?workspace_commands.Action {
    const trimmed = std.mem.trim(u8, rest, " \t");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "list")) return null;
    if (std.mem.eql(u8, trimmed, "clear")) return .clear;
    if (std.mem.startsWith(u8, trimmed, "add") and trimmed.len > "add".len and
        std.ascii.isWhitespace(trimmed["add".len]))
    {
        const path = std.mem.trim(u8, trimmed["add".len..], " \t");
        if (path.len == 0) return error.InvalidWorkspaceCommand;
        return .{ .add = path };
    }
    if (std.mem.startsWith(u8, trimmed, "remove") and trimmed.len > "remove".len and
        std.ascii.isWhitespace(trimmed["remove".len]))
    {
        const path = std.mem.trim(u8, trimmed["remove".len..], " \t");
        if (path.len == 0) return error.InvalidWorkspaceCommand;
        return .{ .remove = path };
    }
    return error.InvalidWorkspaceCommand;
}

noinline fn tryBeginWorkspaceMutation(app: anytype) bool {
    if (agents.screenAgentOf(app).stream.active) return false;
    return agents.screenAgentOf(app).worker.tryHoldTurnStart();
}

fn refreshWorkspaceAvailabilityForList(app: anytype) !void {
    if (!tryBeginWorkspaceMutation(app)) return;
    defer agents.screenAgentOf(app).worker.releaseTurnStartHold();
    if (comptime @hasDecl(@TypeOf(app.*), "refreshWorkspaceAccess")) {
        _ = try app.refreshWorkspaceAccess();
    }
}

fn handleShellCommand(app: anytype, rest: []const u8) !void {
    if (!std.mem.eql(u8, std.mem.trim(u8, rest, " \t"), "reload")) {
        try app.writeDomainNotice(.{ .topic = "", .tone = .@"error", .body = "usage: /shell reload" }, true);
        return;
    }
    shell_snapshot.processOwner().markDirty(.user_reload);
    try app.writeDomainNotice(.{
        .topic = "shell",
        .tone = .neutral,
        .body = "The next command reloads your shell startup files. Remembered command approvals were reset.",
    }, true);
}

fn handleWorkspaceCommand(app: anytype, rest: []const u8) !void {
    const maybe_action = parseWorkspaceCommand(rest) catch {
        try app.writeDomainNotice(.{
            .topic = "",
            .tone = .@"error",
            .body = "usage: /workspace [add PATH|remove PATH|clear]",
        }, true);
        return;
    };
    const action = maybe_action orelse {
        refreshWorkspaceAvailabilityForList(app) catch |err| {
            const reason = output_contracts.workspaceErrorMessage(err) orelse "workspace refresh failed";
            const message = try app.alloc.print("Workspace refresh rejected: {s}", .{reason});
            defer app.alloc.free(message);
            try app.writeDomainNotice(.{
                .topic = "workspace",
                .tone = .@"error",
                .body = message,
            }, true);
            return;
        };
        return writeWorkspaceSnapshot(app, null);
    };

    if (!tryBeginWorkspaceMutation(app)) {
        try app.writeDomainNotice(.{
            .topic = "workspace",
            .tone = .neutral,
            .body = "Workspace changes are unavailable until the active and queued work finishes.",
        }, true);
        return;
    }
    defer agents.screenAgentOf(app).worker.releaseTurnStartHold();

    var failure_phase: workspace_commands.FailurePhase = .stage;
    var result = workspace_commands.execute(
        app.alloc,
        app.workspace_root,
        app.workspaceAccess(),
        action,
        &failure_phase,
    ) catch |err| {
        const reason = output_contracts.workspaceErrorMessage(err) orelse "workspace update failed";
        const prefix: []const u8 = switch (failure_phase) {
            .stage => "Workspace update rejected",
            .commit => "Workspace settings were not changed",
            .reconcile => "Workspace settings are uncertain and could not be reloaded",
        };
        const message = try app.alloc.print("{s}: {s}", .{ prefix, reason });
        defer app.alloc.free(message);
        try app.writeDomainNotice(.{
            .topic = "workspace",
            .tone = .@"error",
            .body = message,
        }, true);
        return;
    };
    defer result.deinit(app.alloc);

    switch (result) {
        .updated => |*updated| {
            _ = app.installWorkspaceAccess(&updated.access);
            try writeWorkspaceSnapshot(app, updated.mutation);
        },
        .indeterminate => |*reconciliation| {
            const message: []const u8 = switch (reconciliation.*) {
                .intended => |*reconciled| blk: {
                    _ = app.installWorkspaceAccess(reconciled);
                    break :blk "Workspace settings durability is uncertain; reloaded settings match the requested update.";
                },
                .previous => |*reconciled| blk: {
                    _ = app.installWorkspaceAccess(reconciled);
                    break :blk "Workspace settings durability is uncertain; reloaded settings match the previous state, so the update is not active.";
                },
                .unconfirmed => "Workspace settings durability is uncertain; reloaded settings match neither the requested nor previous state, so runtime access is unchanged.",
            };
            try app.writeDomainNotice(.{
                .topic = "workspace",
                .tone = .warning,
                .body = message,
            }, true);
        },
    }
}

fn writeWorkspaceSnapshot(
    app: anytype,
    mutation: ?workspace_commands.Mutation,
) !void {
    var snapshot = output_contracts.WorkspaceSnapshot.fromAccess(app.workspace_root, app.workspaceAccess());
    snapshot.mutation = mutation;
    const body = try snapshot.renderInteractiveBody(app.alloc);
    defer app.alloc.free(body);
    try app.writeDomainNotice(.{
        .topic = "workspace",
        .tone = .neutral,
        .body = body,
    }, true);
}

fn requestResumeExit(app: anytype) void {
    const App = @TypeOf(app.*);
    app_session_runtime.Runtime(App).requestResumeHandoff(agents.screenAgentOf(app));
    app.should_exit = true;
}

pub fn Handlers(comptime App: type) type {
    return struct {
        const AppAgent = if (@hasField(App, "main_agent")) @FieldType(App, "main_agent") else struct {};
        pub fn route(app: *App, cmd: []const u8) !void {
            const handlers = commandHandlers(app);
            try command_router.route(app.slashRegistry(), &handlers, cmd);
        }

        pub fn commandHandlers(app: *App) command_router.CommandHandlers {
            return .{
                .ctx = @ptrCast(app),
                .quit = commandQuit,
                .clear_screen = commandClearScreen,
                .new_session = commandNewSession,
                .launch_instance = commandLaunchInstance,
                .close_instance = commandCloseInstance,
                .show_agents = commandShowAgents,
                .reset_session = commandResetSession,
                .resume_session = commandResumeSession,
                .fork_session = commandForkSession,

                .show_help = commandShowHelp,
                .login = commandLogin,
                .logout = commandLogout,
                .provider = commandProvider,
                .setup_alias = commandSetupAlias,
                .show_status = commandShowStatus,
                .attach_image = commandAttachImage,
                .manage_images = commandManageImages,
                .handle_model = commandHandleModel,
                .handle_effort = commandHandleEffort,
                .handle_permissions = commandHandlePermissions,
                .handle_allowlist = commandHandleAllowlist,
                .show_stats = commandShowStats,
                .show_usage = commandShowUsage,
                .undo_last = commandUndoLast,
                .handle_mcp = commandHandleMcp,
                .handle_skills = commandHandleSkills,
                .copy_last = commandCopyLast,
                .submit_feedback = commandSubmitFeedback,
                .create_trace = commandCreateTrace,
                .compact_history = commandCompactHistory,
                .handle_settings = commandHandleSettings,
                .show_credits = commandShowCredits,
                .paste_clipboard = commandPasteClipboard,
                .handle_fast = commandHandleFast,
                .handle_ultrafast = commandHandleUltrafast,
                .handle_statusline = commandHandleStatusline,
                .rename_session = commandRenameSession,
                .handle_notifications = commandHandleNotifications,
                .handle_workspace = commandHandleWorkspace,
                .handle_loop = commandHandleLoop,
                .handle_shell = commandHandleShell,
                .show_version = commandShowVersion,
                .unknown = commandUnknown,
            };
        }

        /// What the MCP host and `/mcp` have to say, and the reload a `/mcp` change asked for.
        fn closeOtherMenusForMcp(app: *App, agent: *AppAgent) void {
            closeModelMenuIfPresent(app);
            closeHelpMenuIfPresent(app);
            closeInlineCommandMenusIfPresent(app);
            if (comptime @hasField(App, "skills")) app.skills.closeMenu();
            if (comptime @hasField(App, "input_runtime")) {
                if (comptime @hasField(@TypeOf(app.input_runtime), "settings_menu")) {
                    app.input_runtime.settings_menu.close();
                }
            }
            if (comptime agents.hasAgentField(App, "session_persistence")) {
                agent.session_persistence.session_picker.active = false;
            }
        }

        pub fn collectMcpHostFacts(app: *App, agent: *AppAgent) !void {
            if (comptime !@hasDecl(App, "takeMcpHostNotices")) return;
            // A reload that fails leaves its warning among the notices.
            app.applyMcpHostReload(agent);
            const notices = app.takeMcpHostNotices();
            defer {
                for (notices) |n| std.heap.c_allocator.free(n.text);
                std.heap.c_allocator.free(notices);
            }
            for (notices) |n| try app.writeDomainNotice(.{ .topic = "mcp", .tone = if (n.warning) .warning else .neutral, .body = n.text }, true);
            app.refreshMcpCompletion();
            app.refreshMcpHostMenu();
            app.refreshMcpHostStatus();
        }

        pub fn collectShellSnapshotFacts(app: *App) !void {
            var buffer: [shell_snapshot.max_notice_bytes]u8 = undefined;
            const notice = shell_snapshot.processOwner().takeUiNotice(&buffer) orelse return;
            try app.writeDomainNotice(.{ .topic = "shell", .tone = .warning, .body = notice }, true);
        }

        fn handleFeedback(app: *App) !void {
            try app.flushBeforeBlockingExternalWork();
            const opened = if (comptime @hasDecl(App, "urlOpener"))
                app.urlOpener().open(app.alloc, feedback_runtime.url) catch false
            else
                false;
            if (opened) {
                try app.writeDomainNotice(.{
                    .topic = "",
                    .tone = .neutral,
                    .body = "Opened https://fx.sh/feedback.",
                }, true);
                return;
            }
            try app.writeDomainNotice(.{
                .topic = "",
                .tone = .@"error",
                .body = "Could not open https://fx.sh/feedback. Open it manually.",
            }, true);
        }

        fn handleTraceReport(app: *App) !void {
            const progress_entry_id = try app.appendReplaceableDomainNotice(.{
                .topic = "",
                .tone = .neutral,
                .body = "Preparing trace...",
            });
            app.shell.render_requests.request(.transcript);
            try app.flushBeforeBlockingExternalWork();

            const report = trace_report.build(app) catch {
                try finish_trace_notice(app, progress_entry_id, .@"error", "Failed to build trace.");
                return;
            };
            defer app.alloc.free(report);

            const builtin = @import("builtin");
            const report_path: ?[]u8 = trace_report.writeFile(app.alloc, report) catch null;
            defer if (report_path) |path| app.alloc.free(path);
            const disposition: TraceReportDisposition = if (report_path) |path| blk: {
                const copied = if (comptime @hasDecl(App, "clipboard"))
                    app.clipboard().copy_file(app.alloc, path) catch false
                else
                    false;
                if (copied) break :blk .{ .copied_file = path };
                if (builtin.target.os.tag == .macos) break :blk .{ .copy_failed = path };
                break :blk .{ .saved = path };
            } else blk: {
                break :blk .unavailable;
            };
            const body = try format_trace_notice(app.alloc, disposition);
            defer app.alloc.free(body);
            const tone: types.NoticeTone = switch (disposition) {
                .copied_file, .saved => .neutral,
                .copy_failed, .unavailable => .@"error",
            };
            try finish_trace_notice(app, progress_entry_id, tone, body);
        }

        fn commandQuit(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            requestResumeExit(app);
        }

        fn commandClearScreen(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try clearSessionForClearCommand(app);
        }

        fn commandResetSession(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.resetSession(agents.screenAgentOf(app));
        }

        fn commandNewSession(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.newSession(agents.screenAgentOf(app));
        }

        /// `/launch [profile]` starts another instance on the host with a
        /// fresh session, in `profile` or the launch profile, and shows it.
        fn commandLaunchInstance(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime !@hasDecl(App, "launchInstance")) return;
            const name = std.mem.trim(u8, rest, " \t\r\n");
            try app.launchInstance(if (name.len == 0) null else name);
        }

        /// `/close` closes the instance on screen; closing the last one ends
        /// fx.
        fn commandCloseInstance(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime !@hasDecl(App, "closeInstanceOnScreen")) return;
            try app.closeInstanceOnScreen();
        }

        /// `/agents` lists the open instances to switch to one; with one
        /// open it says how to start another.
        fn commandShowAgents(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime !@hasDecl(App, "openAgentsMenu")) return;
            try app.openAgentsMenu();
        }

        fn commandResumeSession(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime !runtime_profile.allows(App, .durable_sessions)) {
                try app.writeDomainNotice(.{
                    .topic = "session",
                    .tone = .warning,
                    .body = "Session resume is owned by the embedding SDK for this host.",
                }, true);
                return;
            }
            try app_session_runtime.Runtime(App).openSessionPicker(app, agents.screenAgentOf(app));
        }

        fn commandForkSession(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime !runtime_profile.allows(App, .durable_sessions)) {
                try app.writeDomainNotice(.{
                    .topic = "session",
                    .tone = .warning,
                    .body = "Session forking is owned by the embedding SDK for this host.",
                }, true);
                return;
            }
            try app_session_runtime.Runtime(App).openForkMenu(app, agents.screenAgentOf(app));
        }

        fn commandRenameSession(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try handleRenameCommand(app, rest);
        }

        fn commandShowHelp(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasField(App, "skills")) app.skills.closeMenu();
            if (comptime @hasField(App, "model_cache")) app.model_cache.closeMenu();
            app.input_runtime.help_menu.open();
            app.shell.render_requests.request(.footer);
        }

        /// `/setup` is the deprecated alias of `/provider`.
        fn commandSetupAlias(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.writeDomainNotice(.{
                .topic = "",
                .tone = .warning,
                .body = "/setup " ++ command_specs.deprecated_until ++ "; use /login to sign in or add an API key, or /provider to choose a provider",
            }, true);
            try commandProvider(ctx);
        }

        fn commandLogin(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasDecl(App, "runLoginCommand")) {
                try app.runLoginCommand(agents.screenAgentOf(app));
            } else {
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .@"error",
                    .body = "login is not available in this runtime",
                }, true);
            }
        }

        fn commandLogout(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasDecl(App, "runLogoutCommand")) {
                try app.runLogoutCommand(agents.screenAgentOf(app), rest);
            } else {
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .@"error",
                    .body = "logout is not available in this runtime",
                }, true);
            }
        }

        fn commandProvider(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasDecl(App, "runProviderCommand")) {
                try app.runProviderCommand(agents.screenAgentOf(app));
            } else {
                try app.writeDomainNotice(.{
                    .topic = "provider",
                    .tone = .@"error",
                    .body = "provider selection is not available in this runtime",
                }, true);
            }
        }

        /// `/status` opens its panel in the footer, like `/usage`, and
        /// writes nothing to the transcript.
        fn commandShowStatus(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            openInfoPanel(app, try session_commands.Commands(App).openStatusSnapshot(app, agents.screenAgentOf(app)));
        }

        /// Shows `snapshot` in place of any other footer menu. Takes ownership.
        fn openInfoPanel(app: *App, snapshot: info_panel.Snapshot) void {
            closeFooterMenus(app);
            app.input_runtime.info_panel.open(snapshot);
            app.shell.render_requests.request(.footer);
        }

        /// Rebuilds the open `/status` or `/permissions` panel when a running
        /// turn changed what it shows. Returns whether it did, so the footer
        /// repaints.
        pub fn collectInfoPanelFacts(app: *App) !bool {
            const panel = &app.input_runtime.info_panel;
            if (!panel.active) return false;
            const shown = if (panel.snapshot) |*snapshot| snapshot else return false;
            // The panel shows the agent on screen, so it refreshes from it.
            const agent = agents.screenAgentOf(app);
            const next = (switch (shown.kind()) {
                .status => try session_commands.Commands(App).refreshedStatusSnapshot(app, agent, shown),
                .permissions => try session_commands.Commands(App).refreshedPermissionsSnapshot(app, agent, shown),
            }) orelse return false;
            panel.replace(next);
            return true;
        }

        fn commandAttachImage(ctx: *anyopaque, path: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try image_commands.Commands(App).attachPath(app, path);
        }

        fn commandManageImages(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try image_commands.Commands(App).managePending(app, agents.screenAgentOf(app), rest);
        }

        fn commandHandleModel(ctx: *anyopaque, query: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try session_commands.Commands(App).handleModel(app, agents.screenAgentOf(app), query);
        }

        /// Bare `/effort` opens the menu of the current model's reasoning
        /// effort levels; `/effort <level>` applies one.
        fn commandHandleEffort(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            // `/effort` sets the agent on screen's effort, as `/model` sets its model.
            const agent = agents.screenAgentOf(app);
            switch (try session_commands.Commands(App).handleEffort(app, agent, rest)) {
                .done => {},
                .open_menu => |capabilities| {
                    if (comptime @hasField(App, "skills")) app.skills.closeMenu();
                    if (comptime @hasField(App, "model_cache")) app.model_cache.closeMenu();
                    closeHelpMenuIfPresent(app);
                    app.input_runtime.settings_menu.close();
                    closeInlineCommandMenusIfPresent(app);
                    try app.input_runtime.effort_menu.open(app.alloc, provider_runtime.modelOf(app, agent), capabilities, agent.effort);
                    app.shell.render_requests.request(.footer);
                },
            }
        }

        /// Bare `/permissions` opens its panel and writes nothing to the
        /// transcript; a subcommand changes the mode or a saved-session rule.
        fn commandHandlePermissions(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            const agent = agents.screenAgentOf(app);
            if (std.mem.trim(u8, rest, " \t").len == 0) {
                openInfoPanel(app, try session_commands.Commands(App).openPermissionsSnapshot(app, agent));
                return;
            }
            if (try handlePermissionRuleManagement(app, agent, rest)) return;
            try session_commands.Commands(App).handlePermissions(app, agent, rest);
        }

        fn handlePermissionRuleManagement(app: *App, agent: *AppAgent, rest: []const u8) !bool {
            if (comptime !agents.hasAgentField(App, "approval_prompt") or
                !agents.hasAgentField(App, "session_persistence") or
                !@hasDecl(App, "preparePermissionStateAction"))
            {
                return false;
            } else {
                const trimmed = std.mem.trim(u8, rest, " \t");
                const action = splitPermissionWord(trimmed) orelse return false;
                const remember = std.ascii.eqlIgnoreCase(action.word, "remember");
                const revoke = std.ascii.eqlIgnoreCase(action.word, "revoke");
                if (!remember and !revoke) return false;
                debug_trace.logf("permission", "event=rule_management_begin action={s}", .{action.word});
                if (app_session_runtime.Runtime(App).activeSessionId(agent) == null) {
                    try writePermissionManagementNotice(
                        app,
                        .@"error",
                        "saved-session permission rules require an active saved session",
                    );
                    return true;
                }
                debug_trace.logf("permission", "event=rule_management_session_ready", .{});
                if (agent.approval_prompt.isActive()) {
                    try writePermissionManagementNotice(
                        app,
                        .warning,
                        "finish the active permission prompt before managing saved-session rules",
                    );
                    return true;
                }

                debug_trace.logf("permission", "event=rule_management_snapshot_start", .{});
                var snapshot = try agent.session.snapshotPermissionState(app.alloc);
                defer snapshot.deinit(app.alloc);
                debug_trace.logf("permission", "event=rule_management_snapshot_done rules={d}", .{snapshot.rules.items.len});
                if (remember) {
                    const decision_word = splitPermissionWord(action.rest) orelse {
                        try writePermissionManagementUsage(app);
                        return true;
                    };
                    const decision: session_permission_state.Decision =
                        if (std.ascii.eqlIgnoreCase(decision_word.word, "allow"))
                            .allow
                        else if (std.ascii.eqlIgnoreCase(decision_word.word, "deny"))
                            .deny
                        else {
                            try writePermissionManagementUsage(app);
                            return true;
                        };
                    const tool_word = splitPermissionWord(decision_word.rest) orelse {
                        try writePermissionManagementUsage(app);
                        return true;
                    };
                    if (tool_word.rest.len == 0) {
                        try writePermissionManagementUsage(app);
                        return true;
                    }
                    var arena_state = std.heap.ArenaAllocator.init(app.alloc);
                    defer arena_state.deinit();
                    debug_trace.logf("permission", "event=rule_management_prepare_start tool={s}", .{tool_word.word});
                    const prepared = app.preparePermissionStateAction(
                        agent,
                        arena_state.allocator(),
                        .{
                            .id = "permission-rule-management",
                            .name = tool_word.word,
                            .arguments_json = tool_word.rest,
                        },
                    ) catch {
                        try writePermissionManagementNotice(
                            app,
                            .@"error",
                            "could not prepare that exact permission action without executing it",
                        );
                        return true;
                    };
                    debug_trace.logf("permission", "event=rule_management_prepare_done kind={s}", .{@tagName(prepared.key.kind)});
                    const existing = session_permission_state.ruleForKey(
                        snapshot,
                        prepared.key,
                    );
                    try agent.approval_prompt.syncRuleManagement(
                        app.alloc,
                        .{
                            .id = debug_trace.nextStepId(),
                            .label = if (decision == .allow)
                                "Remember allow for this saved session"
                            else
                                "Remember deny for this saved session",
                            .explanation = if (existing == null)
                                "Confirm this exact saved-session permission rule. The action will not run."
                            else
                                "Confirm replacement of the existing exact saved-session rule. The action will not run.",
                            .command = prepared.display_identity,
                            .amendment_allowed = false,
                            .confirmation_only = true,
                        },
                        .{ .set = .{
                            .key = prepared.key,
                            .display_identity = prepared.display_identity,
                            .decision = decision,
                            .expected_generation = if (existing) |rule|
                                rule.generation
                            else
                                null,
                        } },
                    );
                    debug_trace.logf("permission", "event=rule_management_prompt_published", .{});
                    app.shell.render_requests.request(.footer);
                    return true;
                }

                const id_word = splitPermissionWord(action.rest) orelse {
                    try writePermissionManagementUsage(app);
                    return true;
                };
                if (id_word.rest.len != 0) {
                    try writePermissionManagementUsage(app);
                    return true;
                }
                const raw_id = std.fmt.parseUnsigned(u64, id_word.word, 10) catch {
                    try writePermissionManagementUsage(app);
                    return true;
                };
                const rule = session_permission_state.ruleForId(
                    snapshot,
                    .{ .value = raw_id },
                ) orelse {
                    try writePermissionManagementNotice(
                        app,
                        .warning,
                        "saved-session permission rule not found",
                    );
                    return true;
                };
                try agent.approval_prompt.syncRuleManagement(
                    app.alloc,
                    .{
                        .id = debug_trace.nextStepId(),
                        .label = "Revoke saved-session permission rule",
                        .explanation = "Confirm revocation of this stored rule. No current action will be prepared or run.",
                        .command = rule.display_identity,
                        .amendment_allowed = false,
                        .confirmation_only = true,
                    },
                    .{ .revoke = .{
                        .id = rule.id,
                        .expected_generation = rule.generation,
                    } },
                );
                app.shell.render_requests.request(.footer);
                return true;
            }
        }

        const PermissionWord = struct {
            word: []const u8,
            rest: []const u8,
        };

        fn splitPermissionWord(value: []const u8) ?PermissionWord {
            const trimmed = std.mem.trim(u8, value, " \t");
            if (trimmed.len == 0) return null;
            const end = std.mem.findAny(u8, trimmed, " \t") orelse trimmed.len;
            return .{
                .word = trimmed[0..end],
                .rest = std.mem.trim(u8, trimmed[end..], " \t"),
            };
        }

        fn writePermissionManagementUsage(app: *App) !void {
            // Usage lines name the command; a topic tag would repeat it.
            try app.writeDomainNotice(.{
                .topic = "",
                .tone = .@"error",
                .body = "usage: /permissions remember <allow|deny> <tool-name> <arguments-json>\n       /permissions revoke <rule-id>",
            }, true);
        }

        fn writePermissionManagementNotice(
            app: *App,
            tone: types.NoticeTone,
            body: []const u8,
        ) !void {
            try app.writeDomainNotice(.{
                .topic = "permissions",
                .tone = tone,
                .body = body,
            }, true);
        }

        fn commandHandleAllowlist(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try session_commands.Commands(App).handleAllowlist(app, agents.screenAgentOf(app), rest);
        }

        fn commandShowStats(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            var buf: [256]u8 = undefined;
            const body = try std.mem.print(
                &buf,
                "ansi_bytes={d}, redraws={d}, debounced_resizes={d}, footer_updates={d}, stream_chunks={d}",
                .{ app.metrics.ansi_bytes, app.metrics.full_redraws, app.metrics.debounced_resizes, app.metrics.footer_line_updates, app.metrics.stream_chunks },
            );
            try app.writeDomainNotice(.{
                .topic = "stats",
                .tone = .neutral,
                .body = body,
            }, true);
        }

        fn commandShowUsage(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime !@hasField(App, "usage_dashboard")) {
                try app.writeDomainNotice(.{
                    .topic = "usage",
                    .tone = .neutral,
                    .body = "Usage is not available in this host.",
                }, true);
                return;
            }
            if (comptime @hasField(App, "skills")) app.skills.closeMenu();
            if (comptime @hasField(App, "model_cache")) app.model_cache.closeMenu();
            closeHelpMenuIfPresent(app);
            app.input_runtime.settings_menu.close();
            closeInlineCommandMenusIfPresent(app);
            var label_buf: usage_host.LabelBuffer = undefined;
            if (usage_host.credential(&app.auth, &label_buf)) |credential| {
                app.usage_dashboard.open(credential);
            } else {
                app.usage_dashboard.openUnavailable(usage_host.missingReason(&app.auth));
            }
            try installUsageSnapshot(app);
        }

        /// Tab and ←→: lists `period` in the model table; never fetches.
        pub fn refreshUsageMenu(app: *App, period: usage.Period) !void {
            if (comptime !@hasField(App, "usage_dashboard")) return;
            if (app.input_runtime.usage_menu.setPeriod(period)) app.shell.render_requests.request(.footer);
        }

        /// `r`: fetches unless a fetch is already running, then redraws.
        pub fn reloadUsageMenu(app: *App, period: usage.Period) !void {
            if (comptime !@hasField(App, "usage_dashboard")) return;
            _ = period;
            _ = app.usage_dashboard.refresh();
            try installUsageSnapshot(app);
        }

        /// Runs on every event-loop pass while `/usage` is open: starts the
        /// periodic refresh when due, and redraws when the dashboard changed
        /// or the minute turned ("updated 2m ago", and today at midnight).
        pub fn collectUsageDashboardFacts(app: *App) !bool {
            if (comptime !@hasField(App, "usage_dashboard")) return false;
            const menu = &app.input_runtime.usage_menu;
            if (!menu.active) return false;
            app.usage_dashboard.tick();
            const changed = app.usage_dashboard.generationCount() != menu.generation;
            const shown_minute = if (menu.snapshot) |*s| @divFloor(s.now_ms, std.time.ms_per_min) else 0;
            const minute_turned = @divFloor(app.usage_dashboard.nowMs(), std.time.ms_per_min) != shown_minute;
            if (!changed and !minute_turned) return false;
            try installUsageSnapshot(app);
            return true;
        }

        pub fn closeUsageMenu(app: *App) void {
            app.input_runtime.usage_menu.close();
            if (comptime @hasField(App, "usage_dashboard")) app.usage_dashboard.close();
        }

        fn installUsageSnapshot(app: *App) !void {
            // Read the generation first, so a fetch finishing in between
            // still triggers a redraw.
            const generation = app.usage_dashboard.generationCount();
            const snapshot = try app.usage_dashboard.snapshot(app.alloc);
            const menu = &app.input_runtime.usage_menu;
            if (menu.active) menu.replace(snapshot, generation) else menu.open(snapshot, generation);
            app.shell.render_requests.request(.footer);
        }

        fn commandUndoLast(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            const result = agents.screenAgentOf(app).change_tracker.undoLast(std.heap.c_allocator);
            const msg = switch (result) {
                .restored => |path| blk: {
                    var display_path = try text_utils.encodeTerminalSafe(
                        app.alloc,
                        path,
                        std.Io.Dir.max_path_bytes,
                    );
                    defer display_path.deinit(app.alloc);
                    break :blk try app.alloc.print("Restored {s}", .{display_path.bytes});
                },
                .deleted => |path| blk: {
                    var display_path = try text_utils.encodeTerminalSafe(
                        app.alloc,
                        path,
                        std.Io.Dir.max_path_bytes,
                    );
                    defer display_path.deinit(app.alloc);
                    break :blk try app.alloc.print("Deleted {s} (was newly created)", .{display_path.bytes});
                },
                .unavailable => |path| blk: {
                    var display_path = try text_utils.encodeTerminalSafe(
                        app.alloc,
                        path,
                        std.Io.Dir.max_path_bytes,
                    );
                    defer display_path.deinit(app.alloc);
                    break :blk try app.alloc.print(
                        "Could not undo {s}",
                        .{display_path.bytes},
                    );
                },
                .empty => try app.alloc.dupe(u8, "Nothing to undo."),
            };
            defer app.alloc.free(msg);
            switch (result) {
                .restored => |path| std.heap.c_allocator.free(path),
                .deleted => |path| std.heap.c_allocator.free(path),
                .unavailable => |path| std.heap.c_allocator.free(path),
                .empty => {},
            }
            try app.writeDomainNotice(.{
                .topic = "undo",
                .tone = .neutral,
                .body = msg,
            }, true);
        }

        fn commandHandleMcp(ctx: *anyopaque, rest: []const u8) !void {
            if (comptime !@hasDecl(App, "runMcpVerbs")) return;
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime !runtime_profile.allows(App, .mcp)) {
                try app.writeDomainNotice(.{
                    .topic = "mcp",
                    .tone = .warning,
                    .body = "MCP servers are unavailable in this host; the embedding app provides MCP tools.",
                }, true);
                return;
            }
            const command = std.mem.trim(u8, rest, " \t");
            // `/mcp` alone opens the menu, and `/mcp VERB` runs the verbs
            // `fx mcp` has.
            if (command.len > 0) return app.runMcpVerbs(command);
            closeOtherMenusForMcp(app, agents.screenAgentOf(app));
            app.openMcpHostMenu();
            app.shell.render_requests.request(.footer);
        }

        noinline fn commandHandleSkills(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime !runtime_profile.allows(App, .skills)) {
                try app.writeDomainNotice(.{
                    .topic = "skills",
                    .tone = .warning,
                    .body = "Skills are unavailable in this host because filesystem access is not provided.",
                }, true);
                return;
            }
            const provider = app.skillsCommandProvider();
            const command = provider.parseCommand(rest);

            if (comptime @hasDecl(App, "requestSkillsRefresh")) switch (command) {
                .list => {
                    const generation = try app.requestSkillsRefresh();
                    try app.skills.queueRefreshAction(app.alloc, generation, .list);
                    try collectSkillsRefreshFacts(app, agents.screenAgentOf(app));
                    return;
                },
                .show => |name| {
                    const generation = try app.requestSkillsRefresh();
                    try app.skills.queueRefreshAction(
                        app.alloc,
                        generation,
                        .{ .show = name },
                    );
                    try collectSkillsRefreshFacts(app, agents.screenAgentOf(app));
                    return;
                },
                .install, .create, .remove, .path, .usage => {},
            };
            try executeSkillsCommand(app, agents.screenAgentOf(app), provider, command);
            try collectSkillsRefreshFacts(app, agents.screenAgentOf(app));
        }

        pub fn collectSkillsRefreshFacts(app: *App, agent: *AppAgent) !void {
            var ready = app.skills.takeReadyRefreshAction() orelse return;
            defer ready.deinit(app.alloc);
            if (!ready.succeeded) {
                try app.writeDomainNotice(.{
                    .topic = "skills",
                    .tone = .@"error",
                    .body = if (ready.action == .startup_notice)
                        "Skills could not be loaded. Run /skills to try again."
                    else
                        "Skills could not be refreshed. The previous catalog was not shown as current.",
                }, true);
                return;
            }
            switch (ready.action) {
                .startup_notice => try app_bootstrap_runtime.Runtime(App).writeSkillDiagnosticsNotice(app, agent),
                .list => try executeSkillsCommand(
                    app,
                    agent,
                    app.skillsCommandProvider(),
                    .list,
                ),
                .show => |name| try executeSkillsCommand(
                    app,
                    agent,
                    app.skillsCommandProvider(),
                    .{ .show = name },
                ),
                .notice => |body| try app.writeDomainNotice(.{
                    .topic = noticeTopicForBody("skills", body),
                    .tone = .neutral,
                    .body = body,
                }, true),
            }
        }

        fn executeSkillsCommand(
            app: *App,
            agent: *AppAgent,
            provider: skill_commands.Provider,
            command: skill_commands.Command,
        ) !void {
            try writeSkillDiagnosticNotice(app, agent);

            switch (command) {
                .install => |install| {
                    const install_notice = try app.alloc.print("Installing from {s}...", .{install.source});
                    defer app.alloc.free(install_notice);
                    try app.writeDomainNotice(.{
                        .topic = "skills",
                        .tone = .neutral,
                        .body = install_notice,
                    }, true);
                },
                .show => |name| switch (skill_runtime.resolveSkill(app.skills.items, name, null)) {
                    .ambiguous_name => {
                        closeModelMenuIfPresent(app);
                        closeHelpMenuIfPresent(app);
                        try app.input_runtime.textReplacementState().replace(app.alloc, name);
                        app.skills.openMenuWithQuery(.command, null, name);
                        app.shell.render_requests.request(.footer);
                        return;
                    },
                    .found, .not_found, .name_location_mismatch => {},
                },
                else => {},
            }

            var result = try provider.executeCommand(app.alloc, command, .{
                .skills_dir = app.skills.dir,
                .find_ctx = @ptrCast(app),
                .find_skill = findSkillForProvider,
            });
            defer result.deinit(app.alloc);

            try applySkillsCommandResult(app, &result);
        }

        /// Usage lines name the command; a topic tag would repeat it.
        fn noticeTopicForBody(comptime default: []const u8, body: []const u8) []const u8 {
            return if (std.mem.startsWith(u8, body, "usage:")) "" else default;
        }

        fn findSkillForProvider(ctx: *anyopaque, name: []const u8) ?skill_commands.SkillInfo {
            const app: *App = @ptrCast(@alignCast(ctx));
            var fallback: ?skill_runtime.Skill = null;
            for (app.skills.items) |skill| {
                if (!std.mem.eql(u8, skill.name, name)) continue;
                if (skill_runtime.isManagedInstallSkill(skill)) return skillInfoForProvider(skill);
                if (fallback == null) fallback = skill;
            }
            const skill = fallback orelse return null;
            return skillInfoForProvider(skill);
        }

        fn skillInfoForProvider(skill: skill_runtime.Skill) skill_commands.SkillInfo {
            return .{
                .path = skill.path,
                .source_label = skill_runtime.skillSourceLabel(skill.source),
                .managed_install = skill_runtime.isManagedInstallSkill(skill),
            };
        }

        fn writeSkillDiagnosticNotice(app: *App, agent: *AppAgent) !void {
            if (app.skills.diagnostics.len == 0) return;

            var out: std.Io.Writer.Allocating = .init(app.alloc);
            defer out.deinit();
            try skill_runtime.writeDiagnosticSummary(app.alloc, &out.writer, app.skills.diagnostics);
            const body = try out.toOwnedSlice();
            defer app.alloc.free(body);
            if (comptime agents.hasAgentField(App, "session") and @hasDecl(@TypeOf(agent.session), "claimContextNotice")) {
                _ = try agent.session.claimContextNotice(app.alloc, body);
            }
            try app.writeDomainNotice(.{
                .topic = "skills",
                .tone = .warning,
                .body = body,
                .visibility = .full_only,
            }, true);
        }

        fn applySkillsCommandResult(app: *App, result: *const skill_commands.CommandResult) !void {
            switch (result.*) {
                .open_menu => {
                    closeModelMenuIfPresent(app);
                    closeHelpMenuIfPresent(app);
                    app.skills.openMenu();
                    app.shell.render_requests.request(.footer);
                },
                .focus_menu => |name| {
                    closeModelMenuIfPresent(app);
                    closeHelpMenuIfPresent(app);
                    if (app.skills.openMenuFocusedByName(name)) {
                        app.shell.render_requests.request(.footer);
                    }
                },
                .notice => |notice| {
                    if (notice.reload and comptime @hasDecl(App, "requestSkillsRefresh")) {
                        try queueSkillsNoticeAfterRefresh(app, notice.text);
                    } else {
                        try app.writeDomainNotice(.{
                            .topic = noticeTopicForBody("skills", notice.text),
                            .tone = .neutral,
                            .body = notice.text,
                        }, true);
                    }
                },
                .installed => |install_result| {
                    var installed_notice: std.Io.Writer.Allocating = .init(app.alloc);
                    defer installed_notice.deinit();

                    for (install_result.installed.items) |name| {
                        try installed_notice.writer.print("Installed: {s}\n", .{name});
                    }

                    const msg = try installed_notice.toOwnedSlice();
                    defer app.alloc.free(msg);
                    if (comptime @hasDecl(App, "requestSkillsRefresh")) {
                        try queueSkillsNoticeAfterRefresh(
                            app,
                            std.mem.trimEnd(u8, msg, "\n"),
                        );
                    } else {
                        try app.writeDomainNotice(.{
                            .topic = "skills",
                            .tone = .neutral,
                            .body = std.mem.trimEnd(u8, msg, "\n"),
                        }, true);
                    }
                },
            }
        }

        fn queueSkillsNoticeAfterRefresh(app: *App, body: []const u8) !void {
            const generation = try app.requestSkillsRefresh();
            try app.skills.queueRefreshAction(
                app.alloc,
                generation,
                .{ .notice = body },
            );
        }

        fn closeModelMenuIfPresent(app: *App) void {
            if (comptime @hasField(App, "model_cache")) app.model_cache.closeMenu();
        }

        noinline fn closeHelpMenuIfPresent(app: *App) void {
            if (comptime @hasField(App, "input_runtime")) {
                if (comptime @hasField(@TypeOf(app.input_runtime), "help_menu")) {
                    app.input_runtime.help_menu.close();
                }
            }
        }

        /// Closes every footer menu and panel, so another can open in its place.
        pub fn closeFooterMenus(app: *App) void {
            if (comptime @hasField(App, "skills")) app.skills.closeMenu();
            if (comptime @hasField(App, "model_cache")) app.model_cache.closeMenu();
            closeHelpMenuIfPresent(app);
            app.input_runtime.settings_menu.close();
            closeInlineCommandMenusIfPresent(app);
        }

        fn closeInlineCommandMenusIfPresent(app: *App) void {
            if (comptime @hasDecl(App, "closeAgentsMenu")) app.closeAgentsMenu();
            if (comptime !@hasField(App, "input_runtime")) return;
            const InputRuntime = @TypeOf(app.input_runtime);
            if (comptime @hasField(InputRuntime, "statusline_menu")) app.input_runtime.statusline_menu.close();
            if (comptime @hasField(InputRuntime, "info_panel")) app.input_runtime.info_panel.close();
            if (comptime @hasField(InputRuntime, "usage_menu")) closeUsageMenu(app);
            if (comptime @hasField(InputRuntime, "workspace_menu")) app.input_runtime.workspace_menu.close();
            if (comptime @hasField(InputRuntime, "effort_menu")) app.input_runtime.effort_menu.close(app.alloc);
        }

        fn commandCopyLast(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            const last_reply = agents.screenAgentOf(app).session.lastAssistantReply() orelse {
                try app.writeDomainNotice(.{
                    .topic = "clipboard",
                    .tone = .neutral,
                    .body = "No assistant reply to copy.",
                }, true);
                return;
            };
            const copied = app.clipboard().copy(last_reply) catch false;
            if (!copied) {
                try app.writeDomainNotice(.{
                    .topic = "clipboard",
                    .tone = .@"error",
                    .body = "Failed to copy to clipboard.",
                }, true);
                return;
            }
            try app.writeDomainNotice(.{
                .topic = "clipboard",
                .tone = .neutral,
                .body = "Copied to clipboard.",
            }, true);
        }

        fn commandSubmitFeedback(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try handleFeedback(app);
        }

        fn commandCreateTrace(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try handleTraceReport(app);
        }

        fn commandCompactHistory(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasDecl(App, "request_context_compaction")) {
                return app.request_context_compaction(agents.screenAgentOf(app));
            }
            try app.writeDomainNotice(.{
                .topic = "context",
                .tone = .neutral,
                .body = "No context to compact.",
            }, true);
        }

        fn commandHandleSettings(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (std.mem.trim(u8, rest, " \t").len == 0) {
                var settings = config_runtime.loadMergedSettings(app.alloc, app.workspace_root) catch {
                    try session_commands.Commands(App).handleSettings(app, rest);
                    return;
                };
                defer settings.deinit(app.alloc);
                if (comptime @hasField(App, "skills")) app.skills.closeMenu();
                if (comptime @hasField(App, "model_cache")) app.model_cache.closeMenu();
                closeHelpMenuIfPresent(app);
                closeInlineCommandMenusIfPresent(app);
                app.input_runtime.settings_menu.openWithStartupScrollback(
                    settings.startup_scrollback orelse true,
                );
                app.shell.render_requests.request(.footer);
                return;
            }
            try session_commands.Commands(App).handleSettings(app, rest);
        }

        fn commandShowCredits(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            // The lookup runs in a `std.Io` task so a slow Gateway or issuer
            // never holds the input loop; `collectCreditsFacts` writes its result.
            if (comptime @hasField(App, "credits_lookup") and !@import("builtin").single_threaded) {
                return startCreditsLookup(app);
            }
            const input: gateway_provider.CreditsLookupInput = .{
                .credential = app.auth.apiKey(),
                .credential_source = if (comptime @hasDecl(@TypeOf(app.auth), "credentialSource"))
                    app.auth.credentialSource()
                else
                    null,
                .tenant = app.auth.gatewayTeam(),
            };
            var snapshot = app.creditsProvider().fetch(app.alloc, input);
            defer snapshot.deinit(app.alloc);
            try writeCreditsNotice(app, snapshot);
        }

        fn startCreditsLookup(app: *App) !void {
            // A due token still names the session; the task renews it before
            // asking for credits.
            const queued = app.auth.queuedPromptCredential();
            const source = app.auth.credentialSource();
            const renewal: ?credits_lookup.Renewal = if (source) |active|
                if (credentials.sourceRefreshable(active) and app.auth.credentialNeedsRefresh())
                    .{ .transport = app.auth.oauthTransport(), .source = active, .account_id = app.auth.accountId() }
                else
                    null
            else
                null;
            const input: gateway_provider.CreditsLookupInput = .{
                .credential = if (queued) |credential| credential.api_key else null,
                .credential_source = source,
                .tenant = if (queued) |credential| credential.gateway_team else null,
            };
            const started = app.credits_lookup.start(app.creditsProvider(), input, renewal) catch |err| {
                if (err == error.OutOfMemory) return err;
                debug_trace.logf("credits", "lookup start failed err={s}", .{@errorName(err)});
                return app.writeDomainNotice(.{
                    .topic = "credits",
                    .tone = .@"error",
                    .body = "fx could not start a background task to check credits. Try again.",
                }, true);
            };
            try app.writeDomainNotice(.{
                .topic = "credits",
                .tone = .neutral,
                .body = switch (started) {
                    .started => "Checking credits…",
                    .busy => "Credits are still loading.",
                },
            }, true);
        }

        /// Writes the `/credits` result once its background lookup finishes,
        /// after adopting a credential the lookup renewed.
        pub fn collectCreditsFacts(app: *App) !void {
            if (comptime !@hasField(App, "credits_lookup")) return;
            var result = app.credits_lookup.take() orelse return;
            defer result.deinit();
            if (result.renewed) |*renewed| try app.adoptRenewedCredential(renewed);
            try writeCreditsNotice(app, result.snapshot);
        }

        fn writeCreditsNotice(app: *App, snapshot: output_contracts.CreditsSnapshot) !void {
            const text = snapshot.renderInteractiveBody(app.alloc) catch {
                try app.writeDomainNotice(.{
                    .topic = "credits",
                    .tone = .@"error",
                    .body = "Failed to render credits.",
                }, true);
                return;
            };
            defer app.alloc.free(text);
            try app.writeDomainNotice(.{
                .topic = "credits",
                .tone = if (snapshot.err_message == null) .neutral else .@"error",
                .body = text,
            }, true);
            if (comptime @hasField(App, "model_cache")) {
                if (snapshot.err_message == null) {
                    if (snapshot.token_pass != null) {
                        app.model_cache.observeTokenPassCredit();
                    } else if (snapshot.no_token_pass) {
                        app.model_cache.observeNoTokenPass("credits");
                    } else if (app.model_cache.tokenPassStatus() == .active) {
                        // The team uses Token Pass, but this reply does not
                        // mention Token Pass: point at the tab that has it.
                        try app.writeDomainNotice(.{
                            .topic = "credits",
                            .tone = .neutral,
                            .body = "Token Pass credit is a separate balance. See it in the Token Pass tab: " ++ token_pass.dashboard_url,
                        }, true);
                    }
                }
            }
        }

        fn commandPasteClipboard(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try image_commands.Commands(App).attachClipboard(app);
        }

        fn commandHandleFast(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try session_commands.Commands(App).handleFast(app, agents.screenAgentOf(app), rest);
        }

        fn commandHandleUltrafast(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try session_commands.Commands(App).handleUltrafast(app, agents.screenAgentOf(app), rest);
        }

        fn commandHandleStatusline(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (std.mem.trim(u8, rest, " \t").len == 0) {
                if (comptime @hasField(App, "skills")) app.skills.closeMenu();
                if (comptime @hasField(App, "model_cache")) app.model_cache.closeMenu();
                closeHelpMenuIfPresent(app);
                app.input_runtime.settings_menu.close();
                closeInlineCommandMenusIfPresent(app);
                app.input_runtime.statusline_menu.open();
                app.shell.render_requests.request(.footer);
                return;
            }
            try handleStatuslineCommand(app, rest);
        }

        fn commandHandleNotifications(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try handleNotificationsCommand(app, rest);
        }

        fn commandHandleShell(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try handleShellCommand(app, rest);
        }

        fn commandHandleWorkspace(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime !@hasDecl(App, "workspaceAccess")) {
                try app.writeDomainNotice(.{
                    .topic = "workspace",
                    .tone = .@"error",
                    .body = "Workspace access is unavailable in this runtime.",
                }, true);
                return;
            }
            if (std.mem.trim(u8, rest, " \t").len == 0) {
                refreshWorkspaceAvailabilityForList(app) catch |err| {
                    const reason = output_contracts.workspaceErrorMessage(err) orelse "workspace refresh failed";
                    const message = try app.alloc.print("Workspace refresh rejected: {s}", .{reason});
                    defer app.alloc.free(message);
                    try app.writeDomainNotice(.{
                        .topic = "workspace",
                        .tone = .@"error",
                        .body = message,
                    }, true);
                    return;
                };
                if (comptime @hasField(App, "skills")) app.skills.closeMenu();
                if (comptime @hasField(App, "model_cache")) app.model_cache.closeMenu();
                closeHelpMenuIfPresent(app);
                app.input_runtime.settings_menu.close();
                closeInlineCommandMenusIfPresent(app);
                app.input_runtime.workspace_menu.open();
                app.shell.render_requests.request(.footer);
                return;
            }
            try handleWorkspaceCommand(app, rest);
        }

        fn commandHandleLoop(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime !agents.hasAgentField(App, "loops")) {
                try app.writeDomainNotice(.{ .topic = "loop", .tone = .@"error", .body = "/loop is unavailable in this runtime." }, true);
                return;
            }
            try app_loop_runtime.Runtime(App).handleCommand(app, agents.screenAgentOf(app), rest);
        }

        fn commandShowVersion(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.writeDomainNotice(.{
                .topic = "version",
                .tone = .neutral,
                .body = App.app_version,
            }, true);
        }

        fn commandUnknown(ctx: *anyopaque, _: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.writeDomainNotice(.{
                .topic = "command",
                .tone = .@"error",
                .body = "Unknown command. Try /help.",
            }, true);
        }
    };
}

test "workspace slash parser preserves paths with spaces and rejects incomplete actions" {
    try std.testing.expect((try parseWorkspaceCommand("")) == null);
    try std.testing.expect((try parseWorkspaceCommand(" list ")) == null);
    switch ((try parseWorkspaceCommand("clear")).?) {
        .clear => {},
        else => return error.TestExpectedEqual,
    }
    switch ((try parseWorkspaceCommand(" add /tmp/shared project ")).?) {
        .add => |path| try std.testing.expectEqualStrings("/tmp/shared project", path),
        else => return error.TestExpectedEqual,
    }
    switch ((try parseWorkspaceCommand("remove\t/tmp/shared project")).?) {
        .remove => |path| try std.testing.expectEqualStrings("/tmp/shared project", path),
        else => return error.TestExpectedEqual,
    }
    try std.testing.expectError(error.InvalidWorkspaceCommand, parseWorkspaceCommand("add"));
    try std.testing.expectError(error.InvalidWorkspaceCommand, parseWorkspaceCommand("remove"));
    try std.testing.expectError(error.InvalidWorkspaceCommand, parseWorkspaceCommand("unknown"));
}

test "workspace mutation admission rejects queue-zero processing gap" {
    const alloc = std.testing.allocator;
    var app = struct {
        main_agent: struct {
            stream: struct { active: bool = false } = .{},
            worker: worker_runtime.WorkerRuntime = .{},
        } = .{},

        pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
            return &self.main_agent;
        }
    }{};
    defer app.agent().worker.deinit(alloc);

    try app.agent().worker.enqueuePrompt(alloc, .{
        .prompt = try alloc.dupe(u8, "active turn"),
        .images = &.{},
        .model = try alloc.dupe(u8, "test-model"),
        .api_key = try alloc.dupe(u8, "test-key"),
        .permission_mode = .auto,
        .history = try alloc.alloc(types.HistoryTurn, 0),
        .grants = try alloc.alloc(types.PermissionGrant, 0),
    });
    const active = (try app.agent().worker.waitAndTakeNextPrompt(alloc)).?;
    defer worker_runtime.freeQueuedPrompt(alloc, active);

    try std.testing.expectEqual(@as(usize, 0), app.agent().worker.queuedPromptCount());
    try std.testing.expect(!tryBeginWorkspaceMutation(&app));

    app.agent().worker.finishProcessing();
    try std.testing.expect(tryBeginWorkspaceMutation(&app));
    app.agent().worker.releaseTurnStartHold();
}

test "workspace list refresh waits for an idle turn" {
    const alloc = std.testing.allocator;
    const TestApp = struct {
        main_agent: struct {
            stream: struct { active: bool = false } = .{},
            worker: worker_runtime.WorkerRuntime = .{},
        } = .{},
        available: bool = true,
        active: bool = true,
        index_refresh_count: usize = 0,

        pub fn refreshWorkspaceAccess(self: *@This()) !bool {
            self.available = false;
            self.active = false;
            self.index_refresh_count += 1;
            return true;
        }

        pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
            return &self.main_agent;
        }
    };
    var app = TestApp{};
    defer app.agent().worker.deinit(alloc);

    app.agent().stream.active = true;
    try refreshWorkspaceAvailabilityForList(&app);
    try std.testing.expect(app.available);
    try std.testing.expect(app.active);
    try std.testing.expectEqual(@as(usize, 0), app.index_refresh_count);

    app.agent().stream.active = false;
    try app.agent().worker.enqueuePrompt(alloc, .{
        .prompt = try alloc.dupe(u8, "active turn"),
        .images = &.{},
        .model = try alloc.dupe(u8, "test-model"),
        .api_key = try alloc.dupe(u8, "test-key"),
        .permission_mode = .auto,
        .history = try alloc.alloc(types.HistoryTurn, 0),
        .grants = try alloc.alloc(types.PermissionGrant, 0),
    });
    const queued = (try app.agent().worker.waitAndTakeNextPrompt(alloc)).?;
    defer worker_runtime.freeQueuedPrompt(alloc, queued);

    try refreshWorkspaceAvailabilityForList(&app);
    try std.testing.expect(app.available);
    try std.testing.expect(app.active);
    try std.testing.expectEqual(@as(usize, 0), app.index_refresh_count);

    app.agent().worker.finishProcessing();
    try refreshWorkspaceAvailabilityForList(&app);
    try std.testing.expect(!app.available);
    try std.testing.expect(!app.active);
    try std.testing.expectEqual(@as(usize, 1), app.index_refresh_count);
}

test "workspace list reports refresh rejection without replacing access" {
    const alloc = std.testing.allocator;
    const Access = @import("../workspace/workspace_access.zig").WorkspaceAccess;
    const TestApp = struct {
        alloc: std.mem.Allocator,
        workspace_root: []const u8 = "/tmp/workspace",
        main_agent: struct {
            stream: struct { active: bool = false } = .{},
            worker: worker_runtime.WorkerRuntime = .{},
        } = .{},
        access: Access = .{},
        transcript: std.ArrayList(u8) = .empty,
        last_tone: ?types.NoticeTone = null,

        fn deinit(self: *@This()) void {
            self.agent().worker.deinit(self.alloc);
            self.transcript.deinit(self.alloc);
        }

        pub fn refreshWorkspaceAccess(_: *@This()) !bool {
            return error.TooManyDirectories;
        }

        pub fn workspaceAccess(self: *@This()) *const Access {
            return &self.access;
        }

        fn installWorkspaceAccess(_: *@This(), _: *Access) bool {
            return false;
        }

        noinline fn writeDomainNotice(self: *@This(), notice: types.SemanticNotice, _: bool) !void {
            self.last_tone = notice.tone;
            try self.transcript.appendSlice(self.alloc, notice.body);
        }

        pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
            return &self.main_agent;
        }
    };

    var app = TestApp{ .alloc = alloc };
    defer app.deinit();
    try handleWorkspaceCommand(&app, "");
    try std.testing.expectEqual(types.NoticeTone.@"error", app.last_tone.?);
    try std.testing.expect(std.mem.find(u8, app.transcript.items, "Workspace refresh rejected: additional directory limit reached") != null);
    try std.testing.expectEqual(@as(usize, 0), app.access.entries.len);
}

fn handleRenameCommand(app: anytype, rest: []const u8) !void {
    const App = @TypeOf(app.*);
    const SessionRuntime = app_session_runtime.Runtime(App);
    const agent = agents.screenAgentOf(app);
    // A rename to the current title is still saved, so it pins the title;
    // only the notice changes.
    const previous_title: ?[]u8 = if (SessionRuntime.cachedSessionTitle(agent)) |title|
        try app.alloc.dupe(u8, title)
    else
        null;
    defer if (previous_title) |title| app.alloc.free(title);
    SessionRuntime.renameActiveSession(app, agent, rest) catch |err| {
        if (err == error.EmptyTitle) {
            // Usage lines name the command; a topic tag would repeat it.
            try app.writeDomainNotice(
                .{ .topic = "", .tone = .@"error", .body = "usage: /rename <title>" },
                true,
            );
            return;
        }
        const body: []const u8 = switch (err) {
            error.EmptyTitle => unreachable,
            error.TitleTooLong => std.fmt.comptimePrint(
                "title is too long (at most {d} bytes)",
                .{session_display_metadata.max_title_bytes},
            ),
            error.MultilineTitle => "title must be one line",
            error.InvalidTitle => "title must be printable text",
            error.NoActiveSession => "no active session to rename",
            else => {
                const notice = try app.alloc.print(
                    "renamed for this process but not saved ({s})",
                    .{@errorName(err)},
                );
                defer app.alloc.free(notice);
                try app.writeDomainNotice(
                    .{ .topic = "session", .tone = .warning, .body = notice },
                    true,
                );
                app.shell.render_requests.request(.footer);
                return;
            },
        };
        try app.writeDomainNotice(
            .{ .topic = "session", .tone = .@"error", .body = body },
            true,
        );
        return;
    };

    app.shell.render_requests.request(.footer);
    const title = SessionRuntime.cachedSessionTitle(agent) orelse "";
    const unchanged = if (previous_title) |previous| std.mem.eql(u8, previous, title) else false;
    const msg = if (unchanged)
        try app.alloc.print("already named \"{s}\"", .{title})
    else
        try app.alloc.print("renamed to \"{s}\"", .{title});
    defer app.alloc.free(msg);
    try app.writeDomainNotice(.{ .topic = "session", .tone = .neutral, .body = msg }, true);
}

const StatuslineFeedback = enum { announce, silent };

fn parseStatuslineItem(raw: []const u8) ?config_runtime.StatuslineItem {
    const trimmed = std.mem.trim(u8, raw, " \t");
    const statusline_item_info = @typeInfo(config_runtime.StatuslineItem).@"enum";
    inline for (statusline_item_info.field_names, statusline_item_info.field_values) |field_name, field_value| {
        if (std.mem.eql(u8, trimmed, field_name)) return @fromBackingInt(@intCast(field_value));
    }
    return null;
}

fn statuslineItemForSetting(setting: settings_catalog.SettingId) ?config_runtime.StatuslineItem {
    return switch (setting) {
        .statusline_context => .context,
        .statusline_session => .session,
        .statusline_workspace => .workspace,
        else => null,
    };
}

fn statuslineItemEnabled(app: anytype, item: config_runtime.StatuslineItem) bool {
    const App = @TypeOf(app.*);
    return switch (item) {
        .context => app.statusline_context,
        .session => app.statusline_session,
        .workspace => if (comptime @hasField(App, "workspace_identity"))
            app.workspace_identity.enabled
        else
            false,
    };
}

fn assignStatuslineItem(app: anytype, item: config_runtime.StatuslineItem, enabled: bool) bool {
    const App = @TypeOf(app.*);
    const current = statuslineItemEnabled(app, item);
    switch (item) {
        .context => app.statusline_context = enabled,
        .session => app.statusline_session = enabled,
        .workspace => if (comptime @hasField(App, "workspace_identity")) {
            app.workspace_identity.enabled = enabled;
        },
    }
    return current != enabled;
}

fn applyStatuslineItem(
    app: anytype,
    item: config_runtime.StatuslineItem,
    enabled: bool,
    feedback: StatuslineFeedback,
) !void {
    const runtime_changed = assignStatuslineItem(app, item, enabled);
    const patch: config_runtime.UserSettingsPatch = .{
        .statusline_item = .{ .item = item, .enabled = enabled },
    };
    switch (feedback) {
        .announce => {
            try persistUserPreferences(app, "statusline", patch, runtime_changed);
            const message = try app.alloc.print(
                "{s}: {s}",
                .{ @tagName(item), if (enabled) "on" else "off" },
            );
            defer app.alloc.free(message);
            try app.writeDomainNotice(.{ .topic = "statusline", .tone = .neutral, .body = message }, true);
        },
        .silent => try persistUserPreferencesSilently(app, "statusline", patch, runtime_changed),
    }
    app.shell.render_requests.request(.footer);
}

fn handleStatuslineCommand(app: anytype, rest: []const u8) !void {
    const item = parseStatuslineItem(rest) orelse {
        try app.writeDomainNotice(.{
            .topic = "",
            .tone = .@"error",
            .body = "usage: /statusline [context|session|workspace]",
        }, true);
        return;
    };
    try applyStatuslineItem(app, item, !statuslineItemEnabled(app, item), .announce);
}

const SoundLevel = enum {
    off,
    on,
    max,

    fn label(self: SoundLevel) []const u8 {
        return @tagName(self);
    }
};

const ParsedSoundCommand = union(enum) {
    toggle,
    set: SoundLevel,
    invalid,
};

noinline fn parseSoundCommand(rest: []const u8) ParsedSoundCommand {
    var tokens = std.mem.tokenizeAny(u8, rest, " \t");
    const first = tokens.next() orelse return .toggle;
    const level = parseSoundLevel(first) orelse return .invalid;
    if (tokens.next() != null) return .invalid;
    return .{ .set = level };
}

fn parseSoundLevel(value: []const u8) ?SoundLevel {
    if (std.mem.eql(u8, value, "off")) return .off;
    if (std.mem.eql(u8, value, "on")) return .on;
    if (std.mem.eql(u8, value, "max")) return .max;
    return null;
}

fn handleNotificationsCommand(app: anytype, rest: []const u8) !void {
    const current = app.notificationPreferences();
    const level: SoundLevel = switch (parseSoundCommand(rest)) {
        // Bare /sound toggles sound on/off; max is only ever explicit.
        .toggle => if (current.turn_end) .off else .on,
        .set => |value| value,
        .invalid => {
            try app.writeDomainNotice(.{
                .topic = "",
                .tone = .@"error",
                .body = "usage: /sound [on|off|max]",
            }, true);
            return;
        },
    };

    const sound_on = level != .off;
    const max = level == .max;
    const runtime_changed = sound_on != current.turn_end or
        sound_on != current.attention_required or
        max != current.max;
    app.setNotificationPreferences(sound_on, sound_on, max);

    const patch: config_runtime.UserSettingsPatch = .{
        .notification_turn_end = sound_on,
        .notification_attention_required = sound_on,
        .notification_max = max,
    };
    var attempt = config_runtime.attemptUserPreferences(app.alloc, patch);
    defer attempt.deinit(app.alloc);
    switch (attempt) {
        .failure => |failure| try session_commands.reportUserSettingsFailure(
            app,
            "sound",
            failure.err,
            failure.cleanup,
            runtime_changed,
        ),
        // announce_commit=false drops the routine "saved" line (the state
        // notice below covers it, matching /fast) but keeps warnings.
        .outcome => |outcome| _ = try session_commands.reportUserSettingsCommit(
            app,
            "sound",
            patch,
            outcome,
            null,
            false,
        ),
    }

    try app.writeDomainNotice(.{
        .topic = "sound",
        .tone = .neutral,
        .body = level.label(),
    }, true);
}

pub fn settingsCatalogSnapshot(app: anytype) settings_catalog.Snapshot {
    const App = @TypeOf(app.*);
    var snapshot: settings_catalog.Snapshot = .{};
    if (comptime provider_runtime.supported(App)) snapshot.model = provider_runtime.model(app);
    if (comptime agents.hasAgentField(App, "effort")) snapshot.effort = agents.screenAgentOf(app).effort.displayLabel();
    if (comptime @hasField(App, "fast_mode")) snapshot.fast_mode = app.fast_mode;
    if (comptime agents.hasAgentField(App, "worker") and
        @hasField(@TypeOf(agents.screenAgentOf(app).worker), "agent_turn_settings"))
    {
        snapshot.ultrafast_mode = agents.screenAgentOf(app).worker.agent_turn_settings.ultrafast_mode;
    }
    if (comptime @hasDecl(App, "resolvedModelCapabilities") and provider_runtime.supported(App)) {
        const capabilities = app.resolvedModelCapabilities(provider_runtime.model(app));
        snapshot.reasoning_efforts = capabilities.reasoning_efforts;
        snapshot.supports_fast_mode = capabilities.supports_fast_mode;
        snapshot.supports_ultrafast_mode = capabilities.supports_ultrafast_mode;
    }
    if (comptime @hasField(App, "permission_engine")) snapshot.permission_mode = @tagName(app_permission_runtime.Runtime(App).viewOf(app, agents.screenAgentOf(app)).mode);
    if (comptime @hasField(App, "input_runtime")) {
        snapshot.startup_scrollback = app.input_runtime.settings_menu.startup_scrollback;
        if (comptime @hasField(@TypeOf(app.input_runtime), "slash_menu_categories")) {
            snapshot.slash_menu_categories = app.input_runtime.slash_menu_categories;
        }
    }
    if (comptime @hasField(App, "shell") and @hasField(@TypeOf(app.shell), "collapse_tool_calls")) {
        snapshot.collapse_tool_calls = app.shell.collapse_tool_calls;
    }
    if (comptime @hasField(App, "statusline_context")) snapshot.statusline_context = app.statusline_context;
    if (comptime @hasField(App, "statusline_session")) snapshot.statusline_session = app.statusline_session;
    if (comptime @hasField(App, "session_title_generation")) snapshot.session_titles = app.session_title_generation;
    if (comptime @hasField(App, "workspace_identity")) snapshot.statusline_workspace = app.workspace_identity.enabled;
    if (comptime @hasField(App, "prompt_history")) snapshot.prompt_history = app.prompt_history.enabled;
    if (comptime @hasDecl(App, "notificationPreferences")) {
        const notifications = app.notificationPreferences();
        snapshot.sound_level = settings_catalog.notificationLevel(
            notifications.turn_end,
            notifications.attention_required,
            notifications.max,
        );
    }
    return snapshot;
}

pub fn applySettingsCatalogMenuChange(app: anytype, change: settings_catalog.Change) !void {
    switch (change.setting) {
        .statusline_context, .statusline_session, .statusline_workspace => {
            const enabled = parseOnOff(change.value) orelse return error.InvalidSettingsCatalogValue;
            try applyStatuslineItem(
                app,
                statuslineItemForSetting(change.setting).?,
                enabled,
                .silent,
            );
        },
        else => try applySettingsCatalogChange(app, change),
    }
    app.shell.render_requests.request(.footer);
}

fn persistUserPreferencesSilently(
    app: anytype,
    label: []const u8,
    patch: config_runtime.UserSettingsPatch,
    runtime_changed: bool,
) !void {
    var attempt = config_runtime.attemptUserPreferences(app.alloc, patch);
    defer attempt.deinit(app.alloc);
    switch (attempt) {
        .failure => |failure| try session_commands.reportUserSettingsFailure(
            app,
            label,
            failure.err,
            failure.cleanup,
            runtime_changed,
        ),
        .outcome => {},
    }
}

pub fn applySettingsCatalogChange(app: anytype, change: settings_catalog.Change) !void {
    switch (change.setting) {
        .model => unreachable,
        .statusline_context, .statusline_session, .statusline_workspace => {
            const enabled = parseOnOff(change.value) orelse return error.InvalidSettingsCatalogValue;
            const item = statuslineItemForSetting(change.setting).?;
            if (enabled != statuslineItemEnabled(app, item)) {
                try applyStatuslineItem(app, item, enabled, .announce);
            }
        },
        .collapse_tool_calls => {
            const enabled = parseOnOff(change.value) orelse return error.InvalidSettingsCatalogValue;
            const runtime_changed = enabled != app.shell.collapse_tool_calls;
            if (runtime_changed) {
                app.shell.collapse_tool_calls = enabled;
                app.shell.markTranscriptStructureDirty();
                app.shell.render_requests.request(.transcript);
            }
            try persistUserPreferences(
                app,
                "collapse tool calls",
                .{ .collapse_tool_calls = enabled },
                runtime_changed,
            );
        },
        .slash_menu_categories => {
            const enabled = parseOnOff(change.value) orelse return error.InvalidSettingsCatalogValue;
            const runtime_changed = enabled != app.input_runtime.slash_menu_categories;
            if (runtime_changed) {
                app.input_runtime.slash_menu_categories = enabled;
                app.shell.render_requests.request(.footer);
            }
            try persistUserPreferences(
                app,
                "slash menu categories",
                .{ .slash_menu_categories = enabled },
                runtime_changed,
            );
        },
        .session_titles => {
            const enabled = parseOnOff(change.value) orelse return error.InvalidSettingsCatalogValue;
            const ChangeApp = @TypeOf(app.*);
            const current = if (comptime @hasField(ChangeApp, "session_title_generation"))
                app.session_title_generation
            else
                true;
            const runtime_changed = enabled != current;
            if (comptime @hasField(ChangeApp, "session_title_generation")) {
                if (runtime_changed) app.session_title_generation = enabled;
            }
            try persistUserPreferences(
                app,
                "session titles",
                .{ .session_titles = enabled },
                runtime_changed,
            );
        },
        .effort => {
            const effort = types.ReasoningEffort.parseDisplayLabel(change.value) orelse
                return error.InvalidSettingsCatalogValue;
            const capabilities = app.resolvedModelCapabilities(provider_runtime.model(app));
            if (!model_capabilities.reasoningEffortSupported(capabilities, effort)) {
                const message = try app.alloc.print(
                    "{s} is not available for {s}",
                    .{ effort.displayLabel(), provider_runtime.model(app) },
                );
                defer app.alloc.free(message);
                try app.writeDomainNotice(.{ .topic = "effort", .tone = .neutral, .body = message }, true);
                return;
            }
            try session_commands.Commands(@TypeOf(app.*)).selectEffortFromSettings(app, agents.screenAgentOf(app), effort);
        },
        .fast_mode => {
            const enabled = parseOnOff(change.value) orelse return error.InvalidSettingsCatalogValue;
            if (enabled != app.fast_mode) try session_commands.Commands(@TypeOf(app.*)).toggleFast(app, agents.screenAgentOf(app));
        },
        .ultrafast_mode => {
            const enabled = parseOnOff(change.value) orelse return error.InvalidSettingsCatalogValue;
            if (enabled != agents.screenAgentOf(app).worker.agent_turn_settings.ultrafast_mode) {
                try session_commands.Commands(@TypeOf(app.*)).handleUltrafast(
                    app,
                    agents.screenAgentOf(app),
                    if (enabled) "on" else "off",
                );
            }
        },
        .permission_mode => try session_commands.Commands(@TypeOf(app.*)).handlePermissions(app, agents.screenAgentOf(app), change.value),
        .sound_level => try handleNotificationsCommand(app, change.value),
        .startup_scrollback => {
            const enabled = parseOnOff(change.value) orelse return error.InvalidSettingsCatalogValue;
            try session_commands.Commands(@TypeOf(app.*)).handleSettings(
                app,
                if (enabled) "startup-scrollback on" else "startup-scrollback off",
            );
            var settings = config_runtime.loadMergedSettings(app.alloc, app.workspace_root) catch return;
            defer settings.deinit(app.alloc);
            app.input_runtime.settings_menu.startup_scrollback = settings.startup_scrollback orelse true;
        },
        .prompt_history => try session_commands.Commands(@TypeOf(app.*)).handleHistory(app, change.value),
    }
}

fn parseOnOff(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "on")) return true;
    if (std.mem.eql(u8, value, "off")) return false;
    return null;
}

const SurfaceOnlyApp = struct {};

const CreditsCommandFakeApp = struct {
    const FakeAuth = struct {
        fn apiKey(_: *const FakeAuth) ?[]const u8 {
            return "credential";
        }

        fn gatewayTeam(_: *const FakeAuth) ?[]const u8 {
            return "tenant";
        }
    };

    alloc: std.mem.Allocator,
    auth: FakeAuth = .{},
    calls: usize = 0,
    saw_expected_input: bool = false,
    notice_body: std.ArrayList(u8) = .empty,
    notice_topic: ?[]const u8 = null,
    notice_tone: ?types.NoticeTone = null,

    fn deinit(self: *CreditsCommandFakeApp) void {
        self.notice_body.deinit(self.alloc);
    }

    fn creditsProvider(self: *CreditsCommandFakeApp) gateway_provider.CreditsProvider {
        return .{
            .context = self,
            .fetch_fn = fetchCredits,
        };
    }

    fn fetchCredits(
        raw: ?*anyopaque,
        alloc: std.mem.Allocator,
        input: gateway_provider.CreditsLookupInput,
    ) output_contracts.CreditsSnapshot {
        const self: *CreditsCommandFakeApp = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        self.saw_expected_input =
            std.mem.eql(u8, input.credential orelse "", "credential") and
            std.mem.eql(u8, input.tenant orelse "", "tenant");
        return .{ .balance = alloc.dupe(u8, "10") catch null };
    }

    noinline fn writeDomainNotice(
        self: *CreditsCommandFakeApp,
        notice: types.SemanticNotice,
        _: bool,
    ) !void {
        self.notice_topic = notice.topic;
        self.notice_tone = notice.tone;
        try self.notice_body.appendSlice(self.alloc, notice.body);
    }
};

test "sound command parses toggle and off/on/max levels" {
    try std.testing.expectEqual(ParsedSoundCommand.toggle, parseSoundCommand("  \t"));
    try std.testing.expectEqual(ParsedSoundCommand{ .set = .on }, parseSoundCommand("on"));
    try std.testing.expectEqual(ParsedSoundCommand{ .set = .off }, parseSoundCommand("off"));
    try std.testing.expectEqual(ParsedSoundCommand{ .set = .max }, parseSoundCommand("max"));
    try std.testing.expectEqual(ParsedSoundCommand.invalid, parseSoundCommand("turn-end"));
    try std.testing.expectEqual(ParsedSoundCommand.invalid, parseSoundCommand("max extra"));
}

const ClearCommandFakeApp = struct {
    main_agent: struct {} = .{},
    clear_count: usize = 0,
    new_count: usize = 0,
    reset_count: usize = 0,

    fn clearSession(self: *ClearCommandFakeApp, _: anytype) !void {
        self.clear_count += 1;
    }

    fn newSession(self: *ClearCommandFakeApp) !void {
        self.new_count += 1;
    }

    fn resetSession(self: *ClearCommandFakeApp) !void {
        self.reset_count += 1;
    }
    pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }
};

const QuitCommandFakeApp = struct {
    should_exit: bool = false,
    main_agent: struct {
        session_persistence: app_session_runtime.Persistence = .{},
    } = .{},

    pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }
};

test "quit command requests resume handoff before exit" {
    var app = QuitCommandFakeApp{};
    defer app.agent().session_persistence.deinit(std.testing.allocator);

    requestResumeExit(&app);

    try std.testing.expect(app.should_exit);
    try std.testing.expectEqual(
        app_session_runtime.ResumeHandoffIntent.requested,
        app.agent().session_persistence.resume_handoff_intent,
    );
}

const ClipboardCommandFakeApp = struct {
    const CopyOutcome = enum {
        copied,
        unavailable,
        failed,
    };

    const Session = struct {
        reply: ?[]const u8 = null,

        fn lastAssistantReply(self: *const Session) ?[]const u8 {
            return self.reply;
        }
    };

    main_agent: struct {
        session: Session = .{},
    } = .{},
    copy_outcome: CopyOutcome = .copied,
    copy_calls: usize = 0,
    copied_text: ?[]const u8 = null,
    last_topic: ?[]const u8 = null,
    last_tone: ?types.NoticeTone = null,
    last_body: ?[]const u8 = null,

    pub fn clipboard(self: *ClipboardCommandFakeApp) host.Clipboard {
        return .{
            .context = self,
            .copy_fn = copy,
        };
    }

    fn copy(raw_context: ?*anyopaque, text: []const u8) host.ClipboardError!bool {
        const self: *ClipboardCommandFakeApp = @ptrCast(@alignCast(raw_context.?));
        self.copy_calls += 1;
        self.copied_text = text;
        return switch (self.copy_outcome) {
            .copied => true,
            .unavailable => false,
            .failed => error.CopyFailed,
        };
    }

    noinline fn writeDomainNotice(
        self: *ClipboardCommandFakeApp,
        notice: types.SemanticNotice,
        _: bool,
    ) !void {
        self.last_topic = notice.topic;
        self.last_tone = notice.tone;
        self.last_body = notice.body;
    }

    pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }
};

const SkillsInstallReplayApp = struct {
    const FakeInputRuntime = struct {
        const TextReplacementState = struct {
            edit: *editor_state.State,

            fn replace(self: TextReplacementState, alloc: std.mem.Allocator, text: []const u8) !void {
                try self.edit.setText(alloc, text);
            }
        };

        edit_state: editor_state.State = .{},
        help_menu: command_specs.HelpMenu = .{},

        fn deinit(self: *FakeInputRuntime, alloc: std.mem.Allocator) void {
            self.edit_state.deinit(alloc);
        }

        fn textReplacementState(self: *FakeInputRuntime) TextReplacementState {
            return .{ .edit = &self.edit_state };
        }
    };

    main_agent: struct {} = .{},
    alloc: std.mem.Allocator,
    input_runtime: FakeInputRuntime = .{},
    skills: skill_runtime.Runtime = .{},
    shell: transcript_runtime.TranscriptRuntime = .{},
    write_count: usize = 0,
    reload_count: usize = 0,
    last_tone: ?types.NoticeTone = null,

    fn skillsCommandProvider(_: *const SkillsInstallReplayApp) skill_commands.Provider {
        return test_builtin_skills.command_provider;
    }

    fn deinit(self: *SkillsInstallReplayApp) void {
        self.input_runtime.deinit(self.alloc);
        self.shell.deinit(self.alloc);
    }

    pub fn requestSkillsRefresh(self: *SkillsInstallReplayApp) !u64 {
        self.reload_count += 1;
        self.skills.fresh_through_generation = self.reload_count;
        return self.reload_count;
    }

    pub noinline fn writeDomainNotice(self: *SkillsInstallReplayApp, notice: types.SemanticNotice, _: bool) !void {
        self.write_count += 1;
        self.last_tone = notice.tone;
        _ = try self.shell.appendSemanticNotice(self.alloc, notice);
    }
    pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }
};

const ChangeCommandFakeApp = struct {
    alloc: std.mem.Allocator,
    main_agent: struct {
        change_tracker: change_tracker_mod.ChangeTracker = .{},
    } = .{},
    transcript: std.ArrayList(u8) = .empty,

    fn deinit(self: *ChangeCommandFakeApp) void {
        self.change_tracker.deinit(std.heap.c_allocator);
        self.transcript.deinit(self.alloc);
    }

    noinline fn writeDomainNotice(
        self: *ChangeCommandFakeApp,
        notice: types.SemanticNotice,
        _: bool,
    ) !void {
        try self.transcript.appendSlice(self.alloc, notice.body);
    }

    pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }
};

fn writeTempSkillFile(tmp: *std.testing.TmpDir, sub_path: []const u8, content: []const u8) !void {
    if (std.Io.Dir.path.dirname(sub_path)) |parent| {
        try tmp.dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try tmp.dir.createFile(io_mod.getIo(), sub_path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

test {
    _ = trace_report;
}

test "trace notice distinguishes file outcomes without a feedback CTA" {
    const report_path = "/tmp/trace.jsonl";
    const cases = [_]struct {
        disposition: TraceReportDisposition,
        expected: []const u8,
    }{
        .{
            .disposition = .{ .copied_file = report_path },
            .expected = "Trace copied to clipboard. Review and redact it before sharing.",
        },
        .{
            .disposition = .{ .copy_failed = report_path },
            .expected = "Clipboard copy failed. Trace saved at /tmp/trace.jsonl. Review and redact it before sharing.",
        },
        .{
            .disposition = .{ .saved = report_path },
            .expected = "Trace saved at /tmp/trace.jsonl. Review and redact it before sharing.",
        },
        .{
            .disposition = .unavailable,
            .expected = "Could not create trace.",
        },
    };

    for (cases) |case| {
        const body = try format_trace_notice(std.testing.allocator, case.disposition);
        defer std.testing.allocator.free(body);
        try std.testing.expectEqualStrings(case.expected, body);
        try std.testing.expect(std.mem.find(u8, body, "feedback") == null);
        try std.testing.expect(std.mem.find(u8, body, "Report issue") == null);
    }
}

test "app_commands exposes active handler API surface" {
    const HandlerSurface = Handlers(SurfaceOnlyApp);

    const route_info = @typeInfo(@TypeOf(HandlerSurface.route)).@"fn";
    try std.testing.expectEqual(@as(usize, 2), route_info.param_types.len);
    try std.testing.expect(route_info.param_types[0].? == *SurfaceOnlyApp);
    try std.testing.expect(route_info.param_types[1].? == []const u8);

    const handlers_info = @typeInfo(@TypeOf(HandlerSurface.commandHandlers)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), handlers_info.param_types.len);
    try std.testing.expect(handlers_info.param_types[0].? == *SurfaceOnlyApp);
    try std.testing.expect(handlers_info.return_type.? == command_router.CommandHandlers);
}

test "credits command renders through the composed provider" {
    var app = CreditsCommandFakeApp{ .alloc = std.testing.allocator };
    defer app.deinit();

    try Handlers(CreditsCommandFakeApp).commandShowCredits(@ptrCast(&app));

    try std.testing.expectEqual(@as(usize, 1), app.calls);
    try std.testing.expect(app.saw_expected_input);
    try std.testing.expectEqualStrings("credits", app.notice_topic.?);
    try std.testing.expectEqual(types.NoticeTone.neutral, app.notice_tone.?);
    try std.testing.expectEqualStrings("balance=10", app.notice_body.items);
}

test "app_commands routes clear through carry-forward session reset" {
    var app = ClearCommandFakeApp{};

    try clearSessionForClearCommand(&app);

    try std.testing.expectEqual(@as(usize, 1), app.clear_count);
    try std.testing.expectEqual(@as(usize, 0), app.reset_count);
}

test "copy command routes exact reply bytes through the host clipboard" {
    var app = ClipboardCommandFakeApp{
        .main_agent = .{ .session = .{ .reply = "reply\nwith exact bytes" } },
    };

    try Handlers(ClipboardCommandFakeApp).commandCopyLast(@ptrCast(&app));

    try std.testing.expectEqual(@as(usize, 1), app.copy_calls);
    try std.testing.expectEqualStrings("reply\nwith exact bytes", app.copied_text.?);
    try std.testing.expectEqualStrings("clipboard", app.last_topic.?);
    try std.testing.expectEqual(types.NoticeTone.neutral, app.last_tone.?);
    try std.testing.expectEqualStrings("Copied to clipboard.", app.last_body.?);
}

test "copy command reports missing replies and host failures" {
    var app = ClipboardCommandFakeApp{};

    try Handlers(ClipboardCommandFakeApp).commandCopyLast(@ptrCast(&app));
    try std.testing.expectEqual(@as(usize, 0), app.copy_calls);
    try std.testing.expectEqual(types.NoticeTone.neutral, app.last_tone.?);
    try std.testing.expectEqualStrings("No assistant reply to copy.", app.last_body.?);

    app.agent().session.reply = "reply";
    for ([_]ClipboardCommandFakeApp.CopyOutcome{ .unavailable, .failed }) |outcome| {
        app.copy_outcome = outcome;
        app.last_tone = null;
        app.last_body = null;

        try Handlers(ClipboardCommandFakeApp).commandCopyLast(@ptrCast(&app));

        try std.testing.expectEqual(types.NoticeTone.@"error", app.last_tone.?);
        try std.testing.expectEqualStrings("Failed to copy to clipboard.", app.last_body.?);
    }
    try std.testing.expectEqual(@as(usize, 2), app.copy_calls);
}

test "skills install groups command notice fragments for entry replay" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempSkillFile(&tmp, "pack/SKILL.md", "---\nname: root-skill\ndescription: root\n---\n\nbody\n");
    try writeTempSkillFile(&tmp, "pack/nested/SKILL.md", "---\nname: nested-skill\ndescription: nested\n---\n\nbody\n");
    try tmp.dir.createDirPath(io_mod.getIo(), "dest");

    const pack_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "pack");
    defer alloc.free(pack_dir);
    const dest_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "dest");
    defer alloc.free(dest_dir);

    var app = SkillsInstallReplayApp{ .alloc = alloc, .skills = .{ .dir = dest_dir } };
    defer app.deinit();

    const args = try alloc.print("install {s}", .{pack_dir});
    defer alloc.free(args);
    try Handlers(SkillsInstallReplayApp).commandHandleSkills(@ptrCast(&app), args);

    try std.testing.expectEqual(@as(usize, 2), app.shell.notebook.entries.items.len);
    try std.testing.expectEqual(@as(usize, 2), app.write_count);
    try std.testing.expectEqual(@as(usize, 1), app.reload_count);
    try std.testing.expectEqual(types.NoticeTone.neutral, app.last_tone.?);
    try std.testing.expect(app.shell.notebook.entries.items[0] == .semantic_notice);
    try std.testing.expect(app.shell.notebook.entries.items[1] == .semantic_notice);
    try std.testing.expectEqualStrings("skills", app.shell.notebook.entries.items[0].semantic_notice.topic);
    const installing_body = try alloc.print("Installing from {s}...", .{pack_dir});
    defer alloc.free(installing_body);
    try std.testing.expectEqualStrings(installing_body, app.shell.notebook.entries.items[0].semantic_notice.body);
    try std.testing.expectEqualStrings(
        "Installed: root-skill\nInstalled: nested-skill",
        app.shell.notebook.entries.items[1].semantic_notice.body,
    );

    const rendered = try transcript_runtime.renderEntriesToBytes(alloc, app.shell.notebook.entries.items, 80, .{});
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.startsWith(u8, rendered, "* skills: Installing from "));
    try std.testing.expect(std.mem.find(u8, rendered, "\n\n* skills: Installed: root-skill") != null);
    try std.testing.expect(std.mem.endsWith(u8, rendered, "  Installed: nested-skill"));
}

test "help command opens the catalog without writing transcript output" {
    const alloc = std.testing.allocator;
    var app = SkillsInstallReplayApp{ .alloc = alloc };
    defer app.deinit();
    app.skills.openMenu();

    try Handlers(SkillsInstallReplayApp).commandShowHelp(@ptrCast(&app));

    try std.testing.expect(!app.skills.menu.active);
    try std.testing.expect(app.input_runtime.help_menu.active);
    try std.testing.expectEqual(@as(usize, 0), app.write_count);
    try std.testing.expectEqual(@as(usize, 0), app.shell.notebook.entries.items.len);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
}

test "skills list opens menu without transcript inventory" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{
        .{
            .name = "managed",
            .description = "managed skill",
            .path = "/tmp/managed/SKILL.md",
            .source = .global_fx,
        },
        .{
            .name = "workspace",
            .description = "workspace skill",
            .path = "/tmp/workspace/skills/workspace/SKILL.md",
            .source = .workspace_shared,
        },
    };
    var app = SkillsInstallReplayApp{ .alloc = alloc, .skills = .{ .items = @constCast(&skills) } };
    defer app.deinit();

    try Handlers(SkillsInstallReplayApp).commandHandleSkills(@ptrCast(&app), "list");

    try std.testing.expectEqual(@as(usize, 1), app.reload_count);
    try std.testing.expectEqual(@as(usize, 0), app.write_count);
    try std.testing.expect(app.skills.menu.active);
    try std.testing.expectEqual(@as(usize, 0), app.skills.menu.selected_index);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));

    const rendered = try transcript_runtime.renderEntriesToBytes(alloc, app.shell.notebook.entries.items, 80, .{});
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "Visible skills (") == null);
}

test "skills list keeps a bounded discovery warning in the full transcript only" {
    const alloc = std.testing.allocator;
    const skill_diagnostics = [_]skill_runtime.SkillDiagnostic{.{
        .path = "/tmp/hostile\npath/body-sentinel",
        .source = .workspace_shared,
        .scope = .candidate,
        .cause = .{ .invalid_metadata = .missing_name },
    }};
    var app = SkillsInstallReplayApp{
        .alloc = alloc,
        .skills = .{ .diagnostics = @constCast(&skill_diagnostics) },
    };
    defer app.deinit();

    try Handlers(SkillsInstallReplayApp).commandHandleSkills(@ptrCast(&app), "list");

    try std.testing.expectEqual(@as(usize, 1), app.write_count);
    try std.testing.expectEqual(@as(usize, 1), app.shell.notebook.entries.items.len);
    try std.testing.expect(app.shell.notebook.entries.items[0] == .semantic_notice);
    const notice = app.shell.notebook.entries.items[0].semantic_notice;
    try std.testing.expectEqualStrings("skills", notice.topic);
    try std.testing.expectEqual(types.NoticeTone.warning, notice.tone);
    try std.testing.expectEqual(types.NoticeVisibility.full_only, notice.visibility);
    try std.testing.expect(std.mem.find(u8, notice.body, "skill discovery warning:") != null);
    try std.testing.expect(std.mem.find(u8, notice.body, "hostile&#x0a;path/body-sentinel") != null);
    try std.testing.expect(std.mem.find(u8, notice.body, "metadata is invalid (missing_name)") != null);
    const rendered = try transcript_runtime.renderEntriesToBytes(alloc, app.shell.notebook.entries.items, 80, .{});
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "skill discovery warning:") == null);
}

test "skills show focuses matching menu row without transcript body" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{
        .{
            .name = "managed",
            .description = "managed skill",
            .path = "/tmp/managed/SKILL.md",
            .source = .global_fx,
        },
        .{
            .name = "workspace",
            .description = "workspace skill",
            .path = "/tmp/workspace/skills/workspace/SKILL.md",
            .source = .workspace_shared,
        },
    };
    var app = SkillsInstallReplayApp{ .alloc = alloc, .skills = .{ .items = @constCast(&skills) } };
    defer app.deinit();

    try Handlers(SkillsInstallReplayApp).commandHandleSkills(@ptrCast(&app), "show workspace");

    try std.testing.expectEqual(@as(usize, 1), app.reload_count);
    try std.testing.expectEqual(@as(usize, 0), app.write_count);
    try std.testing.expect(app.skills.menu.active);
    try std.testing.expectEqual(skill_runtime.SkillMenuSourceFilter.workspace, app.skills.menu.source_filter);
    try std.testing.expectEqual(@as(usize, 0), app.skills.menu.selected_index);
    try std.testing.expectEqualStrings("workspace", app.skills.selectedMenuSkill().?.name);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
}

test "skills show exposes duplicate rows without focusing a precedence winner" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{
        .{
            .name = "review",
            .description = "managed review",
            .path = "/tmp/managed/review",
            .source = .global_fx,
        },
        .{
            .name = "review",
            .description = "workspace review",
            .path = "/tmp/workspace/skills/review",
            .source = .workspace_shared,
        },
    };
    var app = SkillsInstallReplayApp{ .alloc = alloc, .skills = .{ .items = @constCast(&skills) } };
    defer app.deinit();

    try Handlers(SkillsInstallReplayApp).commandHandleSkills(@ptrCast(&app), "show review");

    try std.testing.expectEqual(@as(usize, 1), app.reload_count);
    try std.testing.expectEqual(@as(usize, 0), app.write_count);
    try std.testing.expect(app.skills.menu.active);
    try std.testing.expectEqualStrings("review", app.skills.menu.query());
    try std.testing.expectEqualStrings("review", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(
        @as(usize, 2),
        app.skills.menu.filteredItemCount(app.skills.items),
    );
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
}

test "skills remove prefers a managed match after a workspace duplicate" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempSkillFile(&tmp, "home/.fx/skills/review/SKILL.md", "---\nname: review\n---\nmanaged body\n");
    try writeTempSkillFile(&tmp, "home/workspace/.agents/skills/review/SKILL.md", "---\nname: review\n---\nworkspace body\n");

    const managed_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/.fx/skills");
    defer alloc.free(managed_root);
    const managed_skill = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/.fx/skills/review");
    defer alloc.free(managed_skill);
    const workspace_skill = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace/.agents/skills/review");
    defer alloc.free(workspace_skill);
    const skills = [_]skill_runtime.Skill{
        .{
            .name = "review",
            .description = "workspace review",
            .path = workspace_skill,
            .source = .workspace_agents,
        },
        .{
            .name = "review",
            .description = "managed review",
            .path = managed_skill,
            .source = .global_fx,
        },
    };
    var app = SkillsInstallReplayApp{
        .alloc = alloc,
        .skills = .{ .dir = managed_root, .items = @constCast(&skills) },
    };
    defer app.deinit();

    try Handlers(SkillsInstallReplayApp).commandHandleSkills(@ptrCast(&app), "remove review");

    const rendered = try transcript_runtime.renderEntriesToBytes(alloc, app.shell.notebook.entries.items, 80, .{});
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "Removed skill 'review'.") != null);
    try std.testing.expectEqual(@as(usize, 1), app.reload_count);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access(io_mod.getIo(), "home/.fx/skills/review", .{}),
    );
    try tmp.dir.access(io_mod.getIo(), "home/workspace/.agents/skills/review/SKILL.md", .{});
}

test "skills show missing name keeps not found notice" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{.{
        .name = "managed",
        .description = "managed skill",
        .path = "/tmp/managed/SKILL.md",
        .source = .global_fx,
    }};
    var app = SkillsInstallReplayApp{ .alloc = alloc, .skills = .{ .items = @constCast(&skills) } };
    defer app.deinit();

    try Handlers(SkillsInstallReplayApp).commandHandleSkills(@ptrCast(&app), "show missing");

    try std.testing.expectEqual(@as(usize, 1), app.reload_count);
    try std.testing.expectEqual(@as(usize, 1), app.write_count);
    try std.testing.expect(!app.skills.menu.active);
    const rendered = try transcript_runtime.renderEntriesToBytes(alloc, app.shell.notebook.entries.items, 80, .{});
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "Skill 'missing' not found.") != null);
}
