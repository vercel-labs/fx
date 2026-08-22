const std = @import("std");
const runtime_profile = @import("../hosts/runtime_profile.zig");
const acp_turn_mod = @import("../acp_client/turn_runner.zig");
const app_permission_runtime = @import("app_permission_runtime.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const io_mod = @import("../shared/io.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const credentials = @import("../auth/credentials.zig");
const background_commands = @import("../background/background_commands.zig");
const gateway_provider = @import("../gateway/gateway_provider.zig");
const host = @import("../hosts/host.zig");
const change_tracker_mod = @import("../workspace/change_tracker.zig");
const command_router = @import("../slash_commands/command_router.zig");
const command_specs = @import("../slash_commands/command_specs.zig");
const config_runtime = @import("../config/config_runtime.zig");
const input_appearance = @import("../config/input_appearance.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const editor_state = @import("../input/editor_state.zig");
const settings_catalog = @import("../config/settings_catalog.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const feedback_runtime = @import("../feedback/runtime.zig");
const output_contracts = @import("../output/output_contracts.zig");
const diagnostics = @import("../workspace/diagnostics.zig");
const workspace_commands = @import("../workspace/workspace_commands.zig");
const image_commands = @import("../images/image_commands.zig");
const mcp_auth = @import("../mcp/mcp_auth.zig");
const mcp_command_provider = @import("../mcp/command_provider.zig");
const mcp_runtime = @import("../mcp/mcp_runtime.zig");
const app_mcp_runtime = @import("app_mcp_runtime.zig");
const model_cache_runtime = @import("model_cache_runtime.zig");
const provider_runtime = @import("provider_runtime.zig");
const permissions = @import("../permissions/permissions.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const skill_commands = @import("../skills/skill_commands.zig");
const skill_runtime = @import("../skills/skill_runtime.zig");
const text_utils = @import("../shared/text_utils.zig");
const session_commands = @import("../session/session_commands.zig");
const usage_recovery = @import("../session/usage_recovery.zig");
const usage_report = @import("../session/usage_report.zig");
const types = @import("../shared/types.zig");
const assistant_presentation = @import("../agent/assistant_presentation.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const presentation_mode = @import("../config/presentation_mode.zig");
const transcript_blocks = @import("../../ui/render_engine/transcript_blocks.zig");
const ui_subagents = @import("../../ui/subagent/runtime.zig");
const transcript_runtime = @import("../../ui/transcript/runtime.zig");
const test_builtin_skills = if (@import("builtin").is_test)
    @import("../../builtins/skills.zig")
else
    struct {};
const TranscriptEntry = transcript_runtime.TranscriptEntry;

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

fn formatMcpPublishedReload(
    alloc: std.mem.Allocator,
    published: app_mcp_runtime.PublishedReload,
) ![]u8 {
    if (published.health == .ready) {
        return alloc.dupe(
            u8,
            if (published.configured_server_count == 0)
                "MCP configuration reloaded. No servers are configured."
            else
                "MCP configuration reloaded successfully.",
        );
    }

    if (published.unavailable_server_names.len == 0) {
        return alloc.dupe(
            u8,
            "MCP configuration reloaded, but some servers are unavailable. Run /mcp list for details.",
        );
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    if (published.unavailable_server_names.len == 1) {
        try out.writer.print(
            "MCP configuration reloaded, but server '{s}' is unavailable. Run /mcp list for details.",
            .{published.unavailable_server_names[0]},
        );
        return out.toOwnedSlice();
    }

    try out.writer.print(
        "MCP configuration reloaded, but {d} servers are unavailable: ",
        .{published.unavailable_server_names.len},
    );
    for (published.unavailable_server_names, 0..) |name, index| {
        if (index > 0) try out.writer.writeAll(", ");
        try out.writer.print("'{s}'", .{name});
    }
    try out.writer.writeAll(". Run /mcp list for details.");
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
    try app.clearSession();
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
    const queued_review_active = if (comptime @hasField(@TypeOf(app.*), "queued_prompt_review"))
        app.queued_prompt_review.active()
    else
        false;
    if (app.stream.active or queued_review_active) return false;
    return app.worker.tryHoldTurnStart();
}

fn refreshWorkspaceAvailabilityForList(app: anytype) !void {
    if (!tryBeginWorkspaceMutation(app)) return;
    defer app.worker.releaseTurnStartHold();
    if (comptime @hasDecl(@TypeOf(app.*), "refreshWorkspaceAccess")) {
        _ = try app.refreshWorkspaceAccess();
    }
}

fn handleWorkspaceCommand(app: anytype, rest: []const u8) !void {
    const maybe_action = parseWorkspaceCommand(rest) catch {
        try app.writeDomainNotice(.{
            .topic = "workspace",
            .tone = .@"error",
            .body = "Use: /workspace [add PATH|remove PATH|clear]",
        }, true);
        return;
    };
    const action = maybe_action orelse {
        refreshWorkspaceAvailabilityForList(app) catch |err| {
            const reason = output_contracts.workspaceErrorMessage(err) orelse "workspace refresh failed";
            const message = try std.fmt.allocPrint(app.alloc, "Workspace refresh rejected: {s}", .{reason});
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
    defer app.worker.releaseTurnStartHold();

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
        const message = try std.fmt.allocPrint(app.alloc, "{s}: {s}", .{ prefix, reason });
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
    app_session_runtime.Runtime(App).requestResumeHandoff(app);
    app.should_exit = true;
}

pub fn Handlers(comptime App: type) type {
    return struct {
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
                .reset_session = commandResetSession,
                .resume_session = commandResumeSession,
                .continue_recovery = commandContinueRecovery,
                .show_help = commandShowHelp,
                .login = commandLogin,
                .logout = commandLogout,
                .setup = commandSetup,
                .show_status = commandShowStatus,
                .show_background = commandShowBackground,
                .stop_background = commandStopBackground,
                .open_background = commandOpenBackground,
                .show_background_logs = commandShowBackgroundLogs,
                .attach_image = commandAttachImage,
                .manage_images = commandManageImages,
                .handle_model = commandHandleModel,
                .show_models = commandShowModels,
                .handle_permissions = commandHandlePermissions,
                .handle_allowlist = commandHandleAllowlist,
                .show_stats = commandShowStats,
                .show_usage = commandShowUsage,
                .undo_last = commandUndoLast,
                .handle_mcp = commandHandleMcp,
                .handle_acp = commandHandleAcp,
                .handle_skills = commandHandleSkills,
                .copy_last = commandCopyLast,
                .submit_feedback = commandSubmitFeedback,
                .create_trace = commandCreateTrace,
                .compact_history = commandCompactHistory,
                .handle_settings = commandHandleSettings,
                .handle_alias = commandHandleAlias,
                .show_credits = commandShowCredits,
                .paste_clipboard = commandPasteClipboard,
                .toggle_fast = commandToggleFast,
                .handle_appearance = commandHandleAppearance,
                .handle_statusline = commandHandleStatusline,
                .rename_session = commandRenameSession,
                .handle_notifications = commandHandleNotifications,
                .handle_workspace = commandHandleWorkspace,
                .show_version = commandShowVersion,
                .unknown = commandUnknown,
            };
        }

        pub fn collectMcpReloadFacts(app: *App) !void {
            if (comptime !@hasDecl(App, "takeMcpReloadCompletion")) return;
            var completion = (try app.takeMcpReloadCompletion()) orelse return;
            defer completion.deinit(app.alloc);
            var warning = false;
            const body = switch (completion) {
                .outcome => |outcome| switch (outcome) {
                    .published => |published| published: {
                        warning = published.health != .ready;
                        if (published.generation) |generation| {
                            debug_trace.logf(
                                "mcp",
                                "profile reload published health={s} runtime_generation={d} configured_servers={d} unavailable_servers={d}",
                                .{
                                    @tagName(published.health),
                                    generation,
                                    published.configured_server_count,
                                    published.unavailable_server_names.len,
                                },
                            );
                        } else {
                            debug_trace.logf(
                                "mcp",
                                "profile reload published health={s} runtime_generation=none configured_servers={d} unavailable_servers={d}",
                                .{
                                    @tagName(published.health),
                                    published.configured_server_count,
                                    published.unavailable_server_names.len,
                                },
                            );
                        }
                        break :published try formatMcpPublishedReload(app.alloc, published);
                    },
                    .retained_required_failure => |failure| retained: {
                        warning = true;
                        debug_trace.logf(
                            "mcp",
                            "profile reload retained current runtime required_server_failure={s}",
                            .{failure},
                        );
                        break :retained try std.fmt.allocPrint(
                            app.alloc,
                            "MCP configuration could not be reloaded. Your existing MCP servers are still active. {s} Check the configuration or run /mcp list for details.",
                            .{failure},
                        );
                    },
                },
                .failed => |err| failed: {
                    warning = true;
                    debug_trace.logf(
                        "mcp",
                        "profile reload retained current runtime err={s}",
                        .{@errorName(err)},
                    );
                    break :failed try app.alloc.dupe(
                        u8,
                        "MCP configuration could not be reloaded. Your existing MCP servers are still active. Check the configuration and run /mcp list for details before trying again.",
                    );
                },
            };
            defer app.alloc.free(body);
            try app.writeDomainNotice(.{
                .topic = "mcp",
                .tone = if (warning) .warning else .neutral,
                .body = body,
            }, true);
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

            const report = buildTraceReport(app) catch {
                try finish_trace_notice(app, progress_entry_id, .@"error", "Failed to build trace.");
                return;
            };
            defer app.alloc.free(report);

            const builtin = @import("builtin");
            const report_path: ?[]u8 = writeTraceReportFile(app.alloc, report) catch null;
            defer if (report_path) |path| app.alloc.free(path);
            const disposition: TraceReportDisposition = if (report_path) |path| blk: {
                const copied = if (comptime @hasDecl(App, "clipboard"))
                    app.clipboard().copy_file(app.alloc, path) catch false
                else
                    false;
                if (copied) break :blk .{ .copied_file = path };
                if (builtin.os.tag == .macos) break :blk .{ .copy_failed = path };
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
            try app.resetSession();
        }

        fn commandNewSession(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.newSession();
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
            try app_session_runtime.Runtime(App).openSessionPicker(app);
        }

        fn commandContinueRecovery(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            const queued = app.continuePausedRecovery() catch |err| switch (err) {
                error.RecoveryBusy => {
                    try app.writeDomainNotice(.{
                        .topic = "recovery",
                        .tone = .neutral,
                        .body = "wait for the current response to finish before continuing recovery",
                    }, true);
                    return;
                },
                else => return err,
            };
            if (queued) return;
            try app.writeDomainNotice(.{
                .topic = "recovery",
                .tone = .neutral,
                .body = "there is no paused model response to continue",
            }, true);
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

        fn commandLogin(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasDecl(App, "runLoginCommand")) {
                try app.runLoginCommand();
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
                try app.runLogoutCommand(rest);
            } else {
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .@"error",
                    .body = "logout is not available in this runtime",
                }, true);
            }
        }

        fn commandSetup(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasDecl(App, "openSetupHub")) {
                try app.openSetupHub();
            } else {
                try app.writeDomainNotice(.{
                    .topic = "setup",
                    .tone = .@"error",
                    .body = "setup is not available in this runtime",
                }, true);
            }
        }

        fn commandShowStatus(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try session_commands.Commands(App).showStatus(app);
        }

        fn commandShowBackground(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try background_commands.Commands(App).show(app);
        }

        fn commandStopBackground(ctx: *anyopaque, target: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try background_commands.Commands(App).stop(app, target);
        }

        fn commandOpenBackground(ctx: *anyopaque, target: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try background_commands.Commands(App).open(app, target);
        }

        fn commandShowBackgroundLogs(ctx: *anyopaque, target: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try background_commands.Commands(App).logs(app, target);
        }

        fn commandAttachImage(ctx: *anyopaque, path: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try image_commands.Commands(App).attachPath(app, path);
        }

        fn commandManageImages(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try image_commands.Commands(App).managePending(app, rest);
        }

        fn commandHandleModel(ctx: *anyopaque, query: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try session_commands.Commands(App).handleModel(app, query);
        }

        fn commandShowModels(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            app.ensureModelCache();
            refreshAcpModelEntries(app);
            if (comptime @hasField(App, "skills")) app.skills.closeMenu();
            closeHelpMenuIfPresent(app);
            try app.model_cache.openMenu();
            app.shell.render_requests.request(.footer);
        }

        /// Capabilities for an "acp/<agent>[/model]" id: reasoning efforts
        /// come from the agent's cached effort options in acp.json so the
        /// /model picker offers an effort stage like any other provider.
        pub fn acpModelCapabilities(app: *App, model: []const u8) model_capabilities.Capabilities {
            var capabilities = model_capabilities.Capabilities{};
            if (!std.mem.startsWith(u8, model, "acp/")) return capabilities;
            const rest = model["acp/".len..];
            const slash = std.mem.indexOfScalar(u8, rest, '/');
            const agent = if (slash) |i| rest[0..i] else rest;
            const builtin_acp = @import("../../builtins/acp.zig");
            const labels = builtin_acp.agentEffortLabels(app.alloc, io_mod.getenv("HOME"), agent) catch
                return capabilities;
            defer builtin_acp.freeAgentNames(app.alloc, labels);
            var efforts: [types.ReasoningEffort.max_options]types.ReasoningEffort = undefined;
            var len: usize = 0;
            for (labels) |label| {
                if (len >= efforts.len) break;
                const parsed = types.ReasoningEffort.parse(label) orelse continue;
                // The picker prepends its own "default" row.
                if (parsed.isDefault()) continue;
                efforts[len] = parsed;
                len += 1;
            }
            capabilities.supports_reasoning = len > 0;
            capabilities.reasoning_efforts = model_capabilities.ReasoningEffortOptions.fromSlice(efforts[0..len]);
            return capabilities;
        }

        /// Surfaces configured ACP agents in the model menu as acp/<name>
        /// entries. Failures leave the menu without ACP rows.
        pub fn refreshAcpModelEntries(app: *App) void {
            const builtin_acp = @import("../../builtins/acp.zig");
            const names = builtin_acp.enabledAgentNames(app.alloc, io_mod.getenv("HOME")) catch |err| {
                debug_trace.logf("acp", "picker names failed err={s}", .{@errorName(err)});
                return;
            };
            defer builtin_acp.freeAgentNames(app.alloc, names);
            debug_trace.logf("acp", "picker names count={d}", .{names.len});
            app.model_cache.setAcpAgentNames(names) catch |err| {
                debug_trace.logf("acp", "picker set failed err={s}", .{@errorName(err)});
            };
        }

        fn commandHandlePermissions(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (try handlePermissionRuleManagement(app, rest)) return;
            try session_commands.Commands(App).handlePermissions(app, rest);
            if (std.mem.trim(u8, rest, " \t").len == 0) {
                try writeSessionPermissionRules(app);
            }
        }

        fn writeSessionPermissionRules(app: *App) !void {
            if (comptime !@hasField(App, "session") or
                !@hasDecl(@TypeOf(app.session), "snapshotPermissionState"))
            {
                return;
            } else {
                var snapshot = try app.session.snapshotPermissionState(app.alloc);
                defer snapshot.deinit(app.alloc);
                var out: std.Io.Writer.Allocating = .init(app.alloc);
                defer out.deinit();
                if (snapshot.rules.items.len == 0) {
                    try out.writer.writeAll("saved-session permission rules: none");
                } else {
                    try out.writer.print(
                        "saved-session permission rules ({d}):",
                        .{snapshot.rules.items.len},
                    );
                    for (snapshot.rules.items) |rule| {
                        var identity = try text_utils.encodeTerminalSafe(
                            app.alloc,
                            rule.display_identity,
                            session_permission_state.max_display_identity_bytes,
                        );
                        defer identity.deinit(app.alloc);
                        try out.writer.print(
                            "\n{d} {s} {s}",
                            .{ rule.id.value, @tagName(rule.decision), identity.bytes },
                        );
                    }
                }
                try app.writeDomainNotice(.{
                    .topic = "permissions",
                    .tone = .neutral,
                    .body = out.writer.buffered(),
                }, true);
            }
        }

        fn handlePermissionRuleManagement(app: *App, rest: []const u8) !bool {
            if (comptime !@hasField(App, "approval_prompt") or
                !@hasField(App, "session_persistence") or
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
                if (app_session_runtime.Runtime(App).activeSessionId(app) == null) {
                    try writePermissionManagementNotice(
                        app,
                        .@"error",
                        "saved-session permission rules require an active saved session",
                    );
                    return true;
                }
                debug_trace.logf("permission", "event=rule_management_session_ready", .{});
                if (app.approval_prompt.isActive()) {
                    try writePermissionManagementNotice(
                        app,
                        .warning,
                        "finish the active permission prompt before managing saved-session rules",
                    );
                    return true;
                }

                debug_trace.logf("permission", "event=rule_management_snapshot_start", .{});
                var snapshot = try app.session.snapshotPermissionState(app.alloc);
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
                    try app.approval_prompt.syncRuleManagement(
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
                try app.approval_prompt.syncRuleManagement(
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
            try writePermissionManagementNotice(
                app,
                .@"error",
                "usage: /permissions remember <allow|deny> <tool-name> <arguments-json>\n       /permissions revoke <rule-id>",
            );
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
            try session_commands.Commands(App).handleAllowlist(app, rest);
        }

        fn commandShowStats(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            var buf: [256]u8 = undefined;
            const body = try std.fmt.bufPrint(
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
            if (comptime !runtime_profile.allows(App, .profile_usage)) {
                var usage = try app.session.usage.reportSnapshot(app.alloc);
                defer usage.deinit(app.alloc);
                try app.writeDomainNotice(.{
                    .topic = "usage",
                    .tone = .neutral,
                    .body = "Durable profile usage is unavailable in this host; active session usage remains in memory.",
                }, true);
                return;
            }
            if (comptime @hasField(App, "skills")) app.skills.closeMenu();
            if (comptime @hasField(App, "model_cache")) app.model_cache.closeMenu();
            closeHelpMenuIfPresent(app);
            app.input_runtime.settings_menu.close();
            closeInlineCommandMenusIfPresent(app);
            var usage = loadUsageSnapshot(app, .days_30) catch |err| {
                debug_trace.logf(
                    "usage",
                    "usage dashboard open failed scope={s} reason={s}",
                    .{ @tagName(usage_report.Scope.days_30), @errorName(err) },
                );
                try app.input_runtime.usage_menu.openError(
                    app.alloc,
                    .days_30,
                    "Local usage data is unavailable",
                );
                app.shell.render_requests.request(.footer);
                return;
            };
            errdefer usage.deinit(app.alloc);
            app.input_runtime.usage_menu.openOwned(app.alloc, usage);
            app.shell.render_requests.request(.footer);
        }

        pub fn refreshUsageMenu(
            app: *App,
            scope: usage_report.Scope,
        ) !void {
            var usage = loadUsageSnapshot(app, scope) catch |err| {
                debug_trace.logf(
                    "usage",
                    "usage dashboard refresh failed scope={s} reason={s}",
                    .{ @tagName(scope), @errorName(err) },
                );
                try app.input_runtime.usage_menu.recordRefreshFailure(
                    app.alloc,
                    scope,
                    "Local usage data is unavailable",
                );
                app.shell.render_requests.request(.footer);
                return;
            };
            errdefer usage.deinit(app.alloc);
            if (app.input_runtime.usage_menu.active) {
                app.input_runtime.usage_menu.replaceOwned(app.alloc, usage);
            } else {
                app.input_runtime.usage_menu.openOwned(app.alloc, usage);
            }
            app.shell.render_requests.request(.footer);
        }

        fn loadUsageSnapshot(
            app: *App,
            scope: usage_report.Scope,
        ) !usage_report.Snapshot {
            if (scope == .session) {
                return app.session.usage.reportSnapshot(app.alloc);
            }
            const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
            const availability = try app.session.ensureProfileUsageReadable(
                app.alloc,
                home,
            );
            if (availability == .unavailable) {
                return app.session.profile_usage.lastError() orelse
                    error.ProfileUsageUnavailable;
            }
            const snapshot_time_ms = @max(io_mod.milliTimestamp(), 0);
            var recovery = try usage_recovery.collectFromHomeConservative(
                app.alloc,
                home,
            );
            defer recovery.deinit(app.alloc);
            return app.session.profile_usage.snapshot(
                app.alloc,
                scope,
                snapshot_time_ms,
                .{
                    .facts = recovery.facts,
                    .incidents = recovery.incidents,
                    .pending = recovery.pending,
                    .unknown_pending = recovery.unknown_pending,
                },
            );
        }

        fn commandUndoLast(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            const result = app.change_tracker.undoLast(std.heap.c_allocator);
            const msg = switch (result) {
                .restored => |path| blk: {
                    var display_path = try text_utils.encodeTerminalSafe(
                        app.alloc,
                        path,
                        std.Io.Dir.max_path_bytes,
                    );
                    defer display_path.deinit(app.alloc);
                    break :blk try std.fmt.allocPrint(app.alloc, "Restored {s}", .{display_path.bytes});
                },
                .deleted => |path| blk: {
                    var display_path = try text_utils.encodeTerminalSafe(
                        app.alloc,
                        path,
                        std.Io.Dir.max_path_bytes,
                    );
                    defer display_path.deinit(app.alloc);
                    break :blk try std.fmt.allocPrint(app.alloc, "Deleted {s} (was newly created)", .{display_path.bytes});
                },
                .empty => try app.alloc.dupe(u8, "Nothing to undo."),
            };
            defer app.alloc.free(msg);
            switch (result) {
                .restored => |path| std.heap.c_allocator.free(path),
                .deleted => |path| std.heap.c_allocator.free(path),
                .empty => {},
            }
            try app.writeDomainNotice(.{
                .topic = "undo",
                .tone = .neutral,
                .body = msg,
            }, true);
        }

        fn commandHandleMcp(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            const result = try app.mcpCommandProvider().handle(app.alloc, rest, .{
                .home = io_mod.getenv("HOME"),
                .list_ctx = @ptrCast(app),
                .summarize_servers = summarizeMcpServers,
                .list_servers_and_tools = listMcpServersAndTools,
                .auth_ctx = @ptrCast(app),
                .validate_authentication_server = validateMcpAuthenticationServer,
                .authenticate_server = authenticateMcpServer,
                .logout_server = logoutMcpServer,
                .feature_ctx = @ptrCast(app),
                .list_resources = listMcpResources,
                .read_resource = readMcpResource,
                .list_prompts = listMcpPrompts,
                .get_prompt = getMcpPrompt,
                .complete_prompt = completeMcpPrompt,
                .complete_resource = completeMcpResource,
            });
            defer result.deinit(app.alloc);
            const command_body = switch (result.display) {
                .block => |text| text,
                .line => |text| text,
            };

            var reload_notice: ?[]u8 = null;
            defer if (reload_notice) |notice| app.alloc.free(notice);
            var reload_warning = false;
            if (result.reload) {
                app.beginMcpReload() catch |err| {
                    reload_warning = true;
                    reload_notice = if (result.report_reload)
                        try app.alloc.dupe(
                            u8,
                            "MCP configuration could not be reloaded. Your existing MCP servers are still active. Check the configuration and run /mcp list for details before trying again.",
                        )
                    else
                        try std.fmt.allocPrint(
                            app.alloc,
                            "{s}\nMCP configuration could not be reloaded. Your existing MCP servers are still active. Check the configuration and run /mcp list for details before trying again.",
                            .{command_body},
                        );
                    debug_trace.logf("mcp", "profile reload retained current runtime err={s}", .{@errorName(err)});
                    const notice = reload_notice.?;
                    try app.writeDomainNotice(.{ .topic = "mcp", .tone = .warning, .body = notice }, true);
                    return;
                };
                const started = "MCP reconnection started. Your existing MCP servers will stay active while the new configuration is checked.";
                reload_notice = if (result.report_reload)
                    try app.alloc.dupe(u8, started)
                else
                    try std.fmt.allocPrint(
                        app.alloc,
                        "{s}\n{s}",
                        .{ command_body, started },
                    );
            }
            const body = reload_notice orelse command_body;
            try app.writeDomainNotice(.{
                .topic = "mcp",
                .tone = if (reload_warning) .warning else .neutral,
                .body = body,
            }, true);
        }

        fn listMcpServersAndTools(ctx: *anyopaque, alloc: std.mem.Allocator) ![]u8 {
            const app: *App = @ptrCast(@alignCast(ctx));
            return app.listMcpServersAndTools(alloc);
        }

        fn summarizeMcpServers(ctx: *anyopaque, alloc: std.mem.Allocator) ![]u8 {
            const app: *App = @ptrCast(@alignCast(ctx));
            return app.summarizeMcpServers(alloc);
        }

        fn commandHandleAcp(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime !runtime_profile.allows(App, .mcp)) {
                try app.writeDomainNotice(.{
                    .topic = "acp",
                    .tone = .warning,
                    .body = "ACP agents are unavailable in this host because process spawning is not provided.",
                }, true);
                return;
            }

            const builtin_acp = @import("../../builtins/acp.zig");
            var result = try builtin_acp.command_provider.handle(app.alloc, rest, .{
                .home = io_mod.getenv("HOME"),
                .acp_run_ctx = @ptrCast(app),
                .report_agent_update = acpReportAgentUpdate,
                .request_permission = acpRequestPermission,
                .worker = &app.worker,
                .cwd = app.workspace_root,
                .on_turn_started = acpTurnStarted,
                .turn_started_ctx = @ptrCast(app),
                .acp_session_store = if (comptime @hasField(App, "acp_session_store"))
                    @ptrCast(&app.acp_session_store)
                else
                    null,
                .effort_label = if (comptime @hasField(App, "effort"))
                    app.effort.gatewayValue()
                else
                    null,
            });
            defer result.deinit(app.alloc);

            const body = switch (result.display) {
                .block => |text| text,
                .line => |text| text,
            };
            try app.writeDomainNotice(.{
                .topic = "acp",
                .tone = if (result.warning) .warning else .neutral,
                .body = body,
            }, true);
        }

        /// Streams agent message chunks into the transcript as they arrive.
        /// Streams agent message chunks into the transcript as they arrive.
        /// Called from the turn's reader thread; the worker event queue makes
        /// the write visible on the UI thread.
        fn acpReportAgentUpdate(ctx: *anyopaque, agent_name: []const u8, update_text: []const u8) void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (update_text.len == 0) return;
            const worker_runtime_mod = @import("app_worker_runtime.zig");
            const line = std.fmt.allocPrint(app.alloc, "[{s}] {s}", .{ agent_name, update_text }) catch return;
            defer app.alloc.free(line);
            worker_runtime_mod.Runtime(App).pushSemanticNotice(app, .{
                .topic = "acp",
                .tone = .neutral,
                .body = line,
            }) catch {};
        }

        /// Bridges the child agent's session/request_permission into fx's
        /// interactive approval UI. Returns "allow" or "reject" (resolved
        /// against the agent's optionIds by the turn runner), or an empty
        /// slice when the approval failed or was dismissed.
        fn acpRequestPermission(ctx: *anyopaque, agent_name: []const u8, request_json: []const u8) []const u8 {
            const app: *App = @ptrCast(@alignCast(ctx));

            const permission_request_mod = @import("../permissions/permission_request.zig");
            const tool_admission = @import("../tooling/tool_admission.zig");
            const turn_runner = @import("../acp_client/turn_runner.zig");

            var arena_state = std.heap.ArenaAllocator.init(app.alloc);
            defer arena_state.deinit();
            const arena = arena_state.allocator();

            // Surface what the agent wants approved.
            const parsed = turn_runner.parsePermissionRequest(arena, request_json) catch null;
            const title = if (parsed) |value| value.title else null;
            const label = if (title) |t|
                std.fmt.allocPrint(arena, "ACP agent {s}: {s}", .{ agent_name, t }) catch
                    "ACP agent permission request"
            else
                std.fmt.allocPrint(arena, "ACP agent {s} requests approval", .{agent_name}) catch
                    "ACP agent permission request";

            const request: permission_request_mod.PermissionRequest = .{
                .label = label,
                .origin = .active_session,
                .explanation = "The ACP agent asks fx to approve this action.",
                .confirmation_only = true,
                .amendment_allowed = false,
            };
            const call: types.ToolCall = .{
                .id = "acp-permission",
                .name = "acp_request_permission",
                .arguments_json = "{}",
            };

            const prompter = tool_admission.workerPrompter(&app.worker);
            const response = prompter.request(app.alloc, request, call, null, null) catch {
                return "";
            };
            var owned = response;
            defer owned.deinit();

            return switch (owned.decision) {
                .once, .always => "allow",
                else => "reject",
            };
        }

        /// Receives the turn handle so the app can drain and cancel it.
        fn acpTurnStarted(ctx: *anyopaque, turn: *anyopaque) void {
            const app: *App = @ptrCast(@alignCast(ctx));
            app.acp_turn = @ptrCast(@alignCast(turn));
            app.stream.active = true;
            app.stream.turn_started_ms = io_mod.milliTimestamp();
            app.shell.render_requests.request(.footer);
        }

        /// Cancels the active ACP agent turn, if any. Wired to Escape.
        pub fn requestAcpCancel(app: *App) void {
            if (app.acp_turn) |turn| turn.requestCancel();
        }

        /// Drains one tick of the active ACP turn: flushes streamed updates,
        /// publishes the result when the turn finishes, and frees the turn.
        pub fn drainAcpTurn(app: *App) !void {
            const turn = app.acp_turn orelse return;
            if (try turn.takeUpdate(app.alloc)) |text| {
                defer app.alloc.free(text);
                try app.pacer.enqueue(app.alloc, text);
                app.shell.render_requests.request(.transcript);
            }
            if (turn.finished) {
                try app.pacer.flushPresentationAtBoundary(
                    app.alloc,
                    io_mod.nanoTimestamp(),
                    app.pacerCallbacks(),
                );
                // Successful turns end like a normal provider reply; only
                // failures surface as a notice.
                if (turn.result_is_warning) {
                    if (turn.result_text) |text| {
                        try app.writeDomainNotice(.{
                            .topic = "acp",
                            .tone = .warning,
                            .body = text,
                        }, true);
                    }
                }
                if (turn.model_values.len > 0) {
                    cacheAcpModels(app, turn);
                }
                turn.deinit();
                app.acp_turn = null;
                app.stream = .{};
                app.shell.render_requests.request(.footer);
            }
        }

        fn cacheAcpModels(app: *App, turn: *acp_turn_mod.ActiveTurn) void {
            const acp_config = @import("../acp_client/config.zig");
            const profile_paths = @import("../shared/profile_paths.zig");
            const home = io_mod.getenv("HOME") orelse return;
            const config_path = profile_paths.acpConfigPath(app.alloc, home) catch return;
            defer app.alloc.free(config_path);
            acp_config.updateAgentModels(app.alloc, config_path, turn.agent_name, turn.model_values, turn.effort_values) catch |err| {
                debug_trace.logf("acp", "caching models failed agent={s} err={s}", .{ turn.agent_name, @errorName(err) });
            };
        }

        fn listMcpResources(
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
            server_name: []const u8,
            templates: bool,
        ) ![]u8 {
            if (comptime !@hasDecl(App, "acquireMcpRuntime")) {
                return error.McpRuntimeUnavailable;
            }
            const app: *App = @ptrCast(@alignCast(ctx));
            var lease = app.acquireMcpRuntime() orelse return error.McpRuntimeUnavailable;
            defer lease.deinit();
            var result = try lease.runtime.listResources(alloc, server_name, templates, null, .unrestricted);
            defer result.deinit(alloc);
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            try out.writer.print("MCP {s} from {s} ({d}):\n", .{
                if (templates) "resource templates" else "resources",
                server_name,
                result.items.len,
            });
            for (result.items) |item| {
                try out.writer.print("  {s} :: {s}", .{ item.server_name, item.uri });
                try out.writer.print(" — {s}", .{item.title orelse item.name});
                try out.writer.writeByte('\n');
            }
            return try out.toOwnedSlice();
        }

        fn readMcpResource(
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
            server_name: []const u8,
            uri: []const u8,
        ) ![]u8 {
            if (comptime !@hasDecl(App, "acquireMcpRuntime")) {
                return error.McpRuntimeUnavailable;
            }
            const app: *App = @ptrCast(@alignCast(ctx));
            var lease = app.acquireMcpRuntime() orelse return error.McpRuntimeUnavailable;
            defer lease.deinit();
            var protocol_diagnostic: ?[]u8 = null;
            defer if (protocol_diagnostic) |diagnostic| alloc.free(diagnostic);
            var result = lease.runtime.readResource(alloc, server_name, uri, .{
                .protocol_diagnostic = &protocol_diagnostic,
            }) catch |err| {
                if (err == error.McpProtocolError) {
                    if (protocol_diagnostic) |diagnostic| {
                        protocol_diagnostic = null;
                        return diagnostic;
                    }
                }
                return err;
            };
            defer result.deinit(alloc);
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            try out.writer.print("[untrusted MCP resource content] {s} :: {s}\n", .{ result.server_name, result.uri });
            for (result.contents) |content| {
                try out.writer.print("\n{s}", .{content.uri});
                if (content.mime_type) |mime_type| try out.writer.print(" ({s})", .{mime_type});
                try out.writer.writeByte('\n');
                switch (content.data) {
                    .text => |text| try out.writer.writeAll(text),
                    .blob => |blob| try out.writer.print("<base64 blob: {d} bytes encoded>", .{blob.len}),
                }
                try out.writer.writeByte('\n');
            }
            return try out.toOwnedSlice();
        }

        fn listMcpPrompts(ctx: *anyopaque, alloc: std.mem.Allocator, server_name: []const u8) ![]u8 {
            if (comptime !@hasDecl(App, "acquireMcpRuntime")) {
                return error.McpRuntimeUnavailable;
            }
            const app: *App = @ptrCast(@alignCast(ctx));
            var lease = app.acquireMcpRuntime() orelse return error.McpRuntimeUnavailable;
            defer lease.deinit();
            var result = try lease.runtime.listPrompts(alloc, server_name, null, .unrestricted);
            defer result.deinit(alloc);
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            try out.writer.print("MCP prompts from {s} ({d}):\n", .{ server_name, result.items.len });
            for (result.items) |item| {
                try out.writer.print("  {s} :: {s}", .{ item.server_name, item.name });
                if (item.title) |label| {
                    try out.writer.print(" — {s}", .{label});
                } else if (item.description) |label| {
                    try out.writer.print(" — {s}", .{label});
                }
                if (item.arguments.len > 0) {
                    try out.writer.writeAll(" [");
                    for (item.arguments, 0..) |argument, index| {
                        if (index > 0) try out.writer.writeAll(", ");
                        try out.writer.print("{s}{s}", .{ argument.name, if (argument.required) "*" else "" });
                    }
                    try out.writer.writeByte(']');
                }
                try out.writer.writeByte('\n');
            }
            return try out.toOwnedSlice();
        }

        fn getMcpPrompt(
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
            server_name: []const u8,
            prompt_name: []const u8,
            arguments_json: []const u8,
        ) ![]u8 {
            if (comptime !@hasDecl(App, "acquireMcpRuntime")) {
                return error.McpRuntimeUnavailable;
            }
            const app: *App = @ptrCast(@alignCast(ctx));
            var lease = app.acquireMcpRuntime() orelse return error.McpRuntimeUnavailable;
            defer lease.deinit();
            var protocol_diagnostic: ?[]u8 = null;
            defer if (protocol_diagnostic) |diagnostic| alloc.free(diagnostic);
            var result = lease.runtime.getPrompt(alloc, server_name, prompt_name, arguments_json, .{
                .protocol_diagnostic = &protocol_diagnostic,
            }) catch |err| {
                if (err == error.McpProtocolError) {
                    if (protocol_diagnostic) |diagnostic| {
                        protocol_diagnostic = null;
                        return diagnostic;
                    }
                }
                return err;
            };
            defer result.deinit(alloc);
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            try out.writer.print("[untrusted MCP prompt content] {s} :: {s}\n", .{ result.server_name, result.name });
            if (result.description) |description| try out.writer.print("{s}\n", .{description});
            for (result.messages) |message| {
                try out.writer.print("\n{s} ({s}):\n{s}\n", .{
                    @tagName(message.role),
                    @tagName(message.content_kind),
                    message.content_json,
                });
            }
            return try out.toOwnedSlice();
        }

        fn completeMcpPrompt(
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
            server_name: []const u8,
            prompt_name: []const u8,
            argument_name: []const u8,
            value: []const u8,
        ) ![]u8 {
            if (comptime !@hasDecl(App, "acquireMcpRuntime")) {
                return error.McpRuntimeUnavailable;
            }
            const app: *App = @ptrCast(@alignCast(ctx));
            var lease = app.acquireMcpRuntime() orelse return error.McpRuntimeUnavailable;
            defer lease.deinit();
            var result = try lease.runtime.completePromptArgument(
                alloc,
                server_name,
                prompt_name,
                .{ .name = argument_name, .value = value },
                &.{},
                null,
                .unrestricted,
            );
            defer result.deinit(alloc);
            return renderMcpCompletions(alloc, &result);
        }

        fn completeMcpResource(
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
            server_name: []const u8,
            uri_template: []const u8,
            variable_name: []const u8,
            value: []const u8,
        ) ![]u8 {
            if (comptime !@hasDecl(App, "acquireMcpRuntime")) {
                return error.McpRuntimeUnavailable;
            }
            const app: *App = @ptrCast(@alignCast(ctx));
            var lease = app.acquireMcpRuntime() orelse return error.McpRuntimeUnavailable;
            defer lease.deinit();
            var result = try lease.runtime.completeResourceTemplateArgument(
                alloc,
                server_name,
                uri_template,
                .{ .name = variable_name, .value = value },
                &.{},
                null,
                .unrestricted,
            );
            defer result.deinit(alloc);
            return renderMcpCompletions(alloc, &result);
        }

        fn renderMcpCompletions(alloc: std.mem.Allocator, result: *const mcp_runtime.CompletionResult) ![]u8 {
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            try out.writer.print("MCP completions from {s} ({d}", .{ result.server_name, result.values.len });
            if (result.total) |total| try out.writer.print(" of {d}", .{total});
            try out.writer.writeAll("):\n");
            for (result.values) |value| try out.writer.print("  {s}\n", .{value});
            if (result.has_more == true) try out.writer.writeAll("  … more available\n");
            return try out.toOwnedSlice();
        }

        fn authenticateMcpServer(
            ctx: *anyopaque,
            name: []const u8,
        ) !mcp_auth.AuthenticationResult {
            if (comptime !@hasDecl(App, "acquireMcpRuntime") or
                !@hasDecl(App, "urlOpener"))
            {
                return error.McpAuthenticationUnavailable;
            }
            const app: *App = @ptrCast(@alignCast(ctx));
            var lease = app.acquireMcpRuntime() orelse return error.McpServerNotFound;
            defer lease.deinit();
            return lease.runtime.authenticateServer(name, app, openMcpAuthUrl);
        }

        fn validateMcpAuthenticationServer(ctx: *anyopaque, name: []const u8) !void {
            if (comptime !@hasDecl(App, "acquireMcpRuntime")) {
                return error.McpAuthenticationUnavailable;
            }
            const app: *App = @ptrCast(@alignCast(ctx));
            var lease = app.acquireMcpRuntime() orelse return error.McpServerNotFound;
            defer lease.deinit();
            try lease.runtime.validateAuthenticationServer(name);
        }

        fn openMcpAuthUrl(
            ctx: ?*anyopaque,
            alloc: std.mem.Allocator,
            url: []const u8,
        ) anyerror!bool {
            if (comptime !@hasDecl(App, "urlOpener")) return false;
            const app: *App = @ptrCast(@alignCast(ctx.?));
            return app.urlOpener().open(alloc, url);
        }

        fn logoutMcpServer(
            ctx: *anyopaque,
            name: []const u8,
        ) !mcp_command_provider.LogoutResult {
            if (comptime !@hasDecl(App, "acquireMcpRuntime")) {
                return error.McpAuthenticationUnavailable;
            }
            const app: *App = @ptrCast(@alignCast(ctx));
            var lease = app.acquireMcpRuntime() orelse return error.McpServerNotFound;
            defer lease.deinit();
            const result = try lease.runtime.logoutServer(name);
            return .{
                .removed = result.removed,
                .revocation_failed = result.revocation_failed,
            };
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

            try app.reloadSkills();
            try writeSkillDiagnosticNotice(app);

            switch (command) {
                .install => |install| {
                    const install_notice = try std.fmt.allocPrint(app.alloc, "Installing from {s}...", .{install.source});
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

        fn writeSkillDiagnosticNotice(app: *App) !void {
            if (app.skills.diagnostics.len == 0) return;

            var out: std.Io.Writer.Allocating = .init(app.alloc);
            defer out.deinit();
            try skill_runtime.writeDiagnosticSummary(app.alloc, &out.writer, app.skills.diagnostics);
            const body = try out.toOwnedSlice();
            defer app.alloc.free(body);
            if (comptime @hasField(App, "session") and @hasDecl(@TypeOf(app.session), "claimContextNotice")) {
                _ = try app.session.claimContextNotice(app.alloc, body);
            }
            try app.writeDomainNotice(.{
                .topic = "skills",
                .tone = .warning,
                .body = body,
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
                    try app.writeDomainNotice(.{
                        .topic = "skills",
                        .tone = .neutral,
                        .body = notice.text,
                    }, true);
                    if (notice.reload) try app.reloadSkills();
                },
                .installed => |install_result| {
                    var installed_notice: std.Io.Writer.Allocating = .init(app.alloc);
                    defer installed_notice.deinit();

                    for (install_result.installed.items) |name| {
                        try installed_notice.writer.print("Installed: {s}\n", .{name});
                    }

                    const msg = try installed_notice.toOwnedSlice();
                    defer app.alloc.free(msg);
                    try app.writeDomainNotice(.{
                        .topic = "skills",
                        .tone = .neutral,
                        .body = std.mem.trimEnd(u8, msg, "\n"),
                    }, true);
                    try app.reloadSkills();
                },
            }
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

        fn closeInlineCommandMenusIfPresent(app: *App) void {
            if (comptime !@hasField(App, "input_runtime")) return;
            const InputRuntime = @TypeOf(app.input_runtime);
            if (comptime @hasField(InputRuntime, "appearance_menu")) app.input_runtime.appearance_menu.close();
            if (comptime @hasField(InputRuntime, "statusline_menu")) app.input_runtime.statusline_menu.close();
            if (comptime @hasField(InputRuntime, "usage_menu")) app.input_runtime.usage_menu.close(app.alloc);
            if (comptime @hasField(InputRuntime, "workspace_menu")) app.input_runtime.workspace_menu.close();
        }

        fn commandCopyLast(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            const last_reply = app.session.lastAssistantReply() orelse {
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
            try app_session_runtime.Runtime(App).compactHistory(app);
            try app.writeDomainNotice(.{
                .topic = "context",
                .tone = .neutral,
                .body = "Context compacted.",
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

        fn commandHandleAlias(ctx: *anyopaque, _: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.writeDomainNotice(.{
                .topic = "aliases",
                .tone = .neutral,
                .body = "Aliases are not yet configurable.",
            }, true);
        }

        fn commandShowCredits(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            var snapshot = app.creditsProvider().fetch(app.alloc, .{
                .credential = app.auth.apiKey(),
                .credential_source = if (comptime @hasDecl(@TypeOf(app.auth), "credentialSource"))
                    app.auth.credentialSource()
                else
                    null,
                .tenant = app.auth.gatewayTeam(),
            });
            defer snapshot.deinit(app.alloc);
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
        }

        fn commandPasteClipboard(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try image_commands.Commands(App).attachClipboard(app);
        }

        fn commandToggleFast(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try session_commands.Commands(App).toggleFast(app);
        }

        fn commandHandleAppearance(ctx: *anyopaque, rest: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            const trimmed = std.mem.trim(u8, rest, " \t");
            if (trimmed.len == 0) {
                if (comptime @hasField(App, "skills")) app.skills.closeMenu();
                if (comptime @hasField(App, "model_cache")) app.model_cache.closeMenu();
                closeHelpMenuIfPresent(app);
                app.input_runtime.settings_menu.close();
                closeInlineCommandMenusIfPresent(app);
                app.input_runtime.appearance_menu.open();
                app.shell.render_requests.request(.footer);
                return;
            }

            const change = parseAppearanceChange(trimmed) orelse {
                try app.writeDomainNotice(.{
                    .topic = "appearance",
                    .tone = .@"error",
                    .body = "Use: /appearance input lines|tint or /appearance presentation normal|minimal",
                }, true);
                return;
            };
            try applySettingsCatalogChange(app, change);
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
                    const message = try std.fmt.allocPrint(app.alloc, "Workspace refresh rejected: {s}", .{reason});
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

const trace_transcript_max_line_bytes: usize = 300;

fn traceFilePermissions() std.Io.File.Permissions {
    const builtin = @import("builtin");
    return switch (builtin.os.tag) {
        .windows => .default_file,
        else => std.Io.File.Permissions.fromMode(0o600),
    };
}

fn writeTraceReportFile(alloc: std.mem.Allocator, contents: []const u8) ![]u8 {
    const tmp_dir = io_mod.getenv("TMPDIR") orelse "/tmp";
    const trimmed = std.mem.trimEnd(u8, tmp_dir, "/");
    const now_ms = io_mod.milliTimestamp();
    const now_secs: i64 = @max(@divFloor(now_ms, 1000), 0);
    const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(now_secs) };
    const day_seconds = epoch_secs.getDaySeconds();
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    var attempts: u8 = 0;
    while (attempts < 8) : (attempts += 1) {
        var random_bytes: [6]u8 = undefined;
        io_mod.getIo().random(&random_bytes);
        const random_hex = std.fmt.bytesToHex(random_bytes, .lower);
        const path = try std.fmt.allocPrint(alloc, "{s}/fx-trace-{d}-{d:0>2}-{d:0>2}-{d:0>2}{d:0>2}{d:0>2}-{s}.md", .{
            trimmed,
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
            random_hex,
        });
        errdefer alloc.free(path);

        var file = std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{
            .truncate = false,
            .exclusive = true,
            .permissions = traceFilePermissions(),
        }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                alloc.free(path);
                continue;
            },
            else => return err,
        };
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), contents);
        try file.sync(io_mod.getIo());

        return path;
    }
    return error.PathAlreadyExists;
}

fn buildTraceReport(app: anytype) ![]u8 {
    const App = @TypeOf(app.*);
    const builtin = @import("builtin");

    var out: std.Io.Writer.Allocating = .init(app.alloc);
    defer out.deinit();

    try out.writer.writeAll("# fx trace\n\n");
    try out.writer.writeAll("Private diagnostic report. It may include prompts, file paths, command output, and file snippets.\n\n");

    try out.writer.writeAll("## Summary\n");
    const now_secs: i64 = @divFloor(io_mod.milliTimestamp(), 1000);
    if (now_secs >= 0) {
        const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(now_secs) };
        const day_seconds = epoch_secs.getDaySeconds();
        const year_day = epoch_secs.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        try out.writer.print("generated: {d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z\n", .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        });
    }
    const build_options = @import("build_options");
    try out.writer.print("version: {s} ({s})\n", .{ App.app_version, build_options.git_commit });
    try out.writer.print("platform: {s}/{s}\n", .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) });
    try out.writer.print("build: {s}\n", .{@tagName(builtin.mode)});
    try out.writer.print("model: {s}\n", .{provider_runtime.model(app)});
    if (app.fast_mode) try out.writer.writeAll("fast_mode: on\n");
    const perm_label = permissions.permissionModeLabel(app.permission_engine.mode);
    try out.writer.print("permission_mode: {s}\n", .{perm_label});
    try out.writer.print("workspace: {s}\n", .{app.workspace_root});

    try writeCurrentStateSummary(&out.writer, app, app.alloc);
    try writeProblemsSummary(&out.writer, app, app.alloc);
    try writeLastInterruptedDetail(&out.writer, app.session.history.items, app.alloc);
    try writeNetworkCallsSummary(&out.writer);
    try writeToolCallsSummary(&out.writer, app.alloc);
    try writeSubagentsSummary(&out.writer, app.alloc, &app.subagents);
    try writePermissionsSummary(&out.writer, app.permission_engine.grants.items);
    try writeRuntimeContextSummary(&out.writer, app, app.alloc);
    try writeRendererState(&out.writer, app, app.alloc);

    if (app.shell.entries.items.len > 0) {
        try out.writer.writeAll("\n## Transcript Timeline\n");
        try out.writer.writeAll("ansi stripped; only obvious secrets masked\n");
        try writeTranscriptTimeline(&out.writer, app.alloc, app.shell.entries.items);
    } else {
        try out.writer.writeAll("\n## Transcript Timeline\n(empty)\n");
    }

    const trace_path: ?[]const u8 = debug_trace.activeLogPath() orelse io_mod.getenv("FX_TRACE_LOG");
    if (trace_path) |path| {
        try writeTraceLogTail(&out.writer, app.alloc, path);
    }

    return try out.toOwnedSlice();
}

fn mcpServerStateLabel(state: mcp_runtime.ServerState) []const u8 {
    return switch (state) {
        .disconnected => "disconnected",
        .disabled => "disabled",
        .ready => "ready",
        .failed => "failed",
    };
}

noinline fn writeMaskedInline(writer: *std.Io.Writer, alloc: std.mem.Allocator, text: []const u8) !void {
    const masked = try text_utils.maskSecrets(alloc, text);
    defer if (masked.ptr != text.ptr) alloc.free(masked);
    try writer.writeAll(masked);
}

fn writeCurrentStateSummary(writer: *std.Io.Writer, app: anytype, alloc: std.mem.Allocator) !void {
    const App = @TypeOf(app.*);
    try writer.writeAll("\n## Current State\n");
    if (comptime @hasField(App, "session_persistence")) {
        if (app_session_runtime.Runtime(App).activeSessionId(app)) |id| {
            try writer.print("session_id: {s}\n", .{id});
        }
        const session_dir =
            try app_session_runtime.Runtime(App).activeSessionDisplayPath(
                app,
                alloc,
            );
        if (session_dir) |dir| {
            defer alloc.free(dir);
            try writer.print("session_dir: {s}\n", .{dir});
        }
    }
    if (comptime @hasField(App, "agent_step_limit")) try writer.print("agent_step_limit: {d}\n", .{app.agent_step_limit});
    if (comptime @hasField(App, "effort")) try writer.print("effort: {s}\n", .{app.effort.label()});
    if (comptime @hasField(App, "total_input_tokens") and @hasField(App, "total_output_tokens")) {
        try writer.print("tokens_total: {d}->{d}\n", .{ app.total_input_tokens, app.total_output_tokens });
    }
    if (comptime @hasField(App, "total_web_search_requests")) {
        try writer.print("web_search_requests_total: {d}\n", .{app.total_web_search_requests});
    }
    try writeAuthStateSummary(writer, app);
    try writeProcessSummary(writer, alloc);
    if (comptime @hasField(App, "worker")) {
        const snapshot = app.worker.snapshotState(alloc) catch null;
        if (snapshot) |state| {
            defer state.deinit(alloc);
            try writer.print("worker: processing={s} queued={d} cancel={s}\n", .{ boolLabel(state.processing), state.queued_count, boolLabel(state.cancel_requested) });
            if (state.pending_permission_request) |request| {
                try writer.writeAll("pending_permission: ");
                try writeMaskedInline(writer, alloc, request.label);
                try writer.writeByte('\n');
            }
        }
        const pending_questions = app.worker.snapshotPendingQuestionBatch(alloc) catch null;
        if (pending_questions) |questions| {
            defer questions.deinit(alloc);
            try writer.print("pending_questions: {d}\n", .{questions.entries.len});
            for (questions.entries, 0..) |entry, idx| {
                if (idx >= 3) {
                    try writer.print("  ... {d} more pending questions\n", .{questions.entries.len - idx});
                    break;
                }
                try writer.writeAll("  - ");
                try writeMaskedInline(writer, alloc, entry.question);
                try writer.print(" options={d}\n", .{entry.options.len});
            }
        }
    }
    if (comptime @hasField(App, "pending_images")) {
        if (app.pending_images.items.len > 0) {
            try writer.print("pending_images: {d}\n", .{app.pending_images.items.len});
            for (app.pending_images.items, 0..) |image, idx| {
                if (idx >= 3) {
                    try writer.print("  ... {d} more pending images\n", .{app.pending_images.items.len - idx});
                    break;
                }
                try writer.print("  - media={s} path=", .{image.media_type});
                try writeMaskedInline(writer, alloc, image.path);
                try writer.writeByte('\n');
            }
        }
    }
    if (comptime @hasField(App, "context_enabled") and @hasField(App, "context_snapshot")) {
        try writer.print("project_context: enabled={s}", .{boolLabel(app.context_enabled)});
        const context_bytes = app.context_snapshot.modelVisibleBytes();
        if (context_bytes.len > 0) try writer.print(" bytes={d}", .{context_bytes.len}) else try writer.writeAll(" not_loaded");
        try writer.writeByte('\n');
    }
    try writeDebugEnvSummary(writer, alloc);
    if (comptime @hasField(App, "stream")) {
        try writer.print("stream: active={s} chunks={d} reads={d} lists={d} writes={d} edits={d} commands={d} subagents={d}", .{
            boolLabel(app.stream.active),
            app.stream.chunks,
            app.stream.read_count,
            app.stream.list_count,
            app.stream.write_count,
            app.stream.edit_count,
            app.stream.command_count,
            app.stream.subagent_count,
        });
        if (app.stream.last_activity_kind) |kind| try writer.print(" last_activity={s}", .{@tagName(kind)});
        try writer.writeByte('\n');
    }
    try writer.print("terminal: {d} cols x {d} rows\n", .{ app.shell.layout.cols, app.shell.layout.rows });
    try writer.print("metrics: ansi_bytes={d} full_redraws={d} debounced_resizes={d} footer_updates={d} stream_chunks={d}\n", .{
        app.metrics.ansi_bytes,
        app.metrics.full_redraws,
        app.metrics.debounced_resizes,
        app.metrics.footer_line_updates,
        app.metrics.stream_chunks,
    });
}

fn writeProcessSummary(writer: *std.Io.Writer, alloc: std.mem.Allocator) !void {
    const pid = std.c.getpid();
    try writer.print("process: pid={d}", .{pid});
    if (countOpenFileDescriptors()) |fd_count| try writer.print(" open_fds={d}", .{fd_count});
    try writer.writeByte('\n');

    const ps = processMemorySnapshot(alloc, pid) catch null;
    if (ps) |text| {
        defer alloc.free(text);
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len > 0) {
            try writer.writeAll("process_memory:\n");
            var it = std.mem.splitScalar(u8, trimmed, '\n');
            while (it.next()) |line| {
                try writer.writeAll("  ");
                try writer.writeAll(std.mem.trimEnd(u8, line, " \t\r"));
                try writer.writeByte('\n');
            }
        }
    }
}

fn countOpenFileDescriptors() ?usize {
    const builtin = @import("builtin");
    const fd_dir = switch (builtin.os.tag) {
        .linux => "/proc/self/fd",
        .macos => "/dev/fd",
        else => return null,
    };
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), fd_dir, .{ .iterate = true }) catch return null;
    defer dir.close(io_mod.getIo());

    var count: usize = 0;
    var it = dir.iterate();
    while (it.next(io_mod.getIo()) catch return null) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        count += 1;
    }
    return count;
}

fn processMemorySnapshot(alloc: std.mem.Allocator, pid: std.c.pid_t) ![]u8 {
    const pid_text = try std.fmt.allocPrint(alloc, "{d}", .{pid});
    defer alloc.free(pid_text);
    const result = try std.process.run(alloc, io_mod.getIo(), .{
        .argv = &.{ "ps", "-o", "pid,ppid,rss,vsz,etime,stat", "-p", pid_text },
    });
    defer alloc.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        alloc.free(result.stdout);
        return error.ProcessSnapshotFailed;
    }
    return result.stdout;
}

fn writeDebugEnvSummary(writer: *std.Io.Writer, alloc: std.mem.Allocator) !void {
    try writer.print("FX_TRACE: {s}\n", .{if (envTruthy("FX_TRACE")) "on" else "off"});
    if (debug_trace.activeLogPath() orelse io_mod.getenv("FX_TRACE_LOG")) |path| {
        try writer.writeAll("trace_log: ");
        try writeMaskedInline(writer, alloc, path);
        try writer.writeByte('\n');
    }
}

fn envTruthy(name: []const u8) bool {
    const raw = io_mod.getenv(name) orelse return false;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return std.ascii.eqlIgnoreCase(trimmed, "1") or
        std.ascii.eqlIgnoreCase(trimmed, "true") or
        std.ascii.eqlIgnoreCase(trimmed, "yes") or
        std.ascii.eqlIgnoreCase(trimmed, "on");
}

fn writeAuthStateSummary(writer: *std.Io.Writer, app: anytype) !void {
    const App = @TypeOf(app.*);
    if (comptime !@hasField(App, "auth")) return;

    const auth_view = app.auth.view();
    try writer.print(
        "auth: source={s} refreshable={s} gateway_team={s}\n",
        .{
            auth_view.activeSourceLabel(),
            boolLabel(auth_view.refreshable),
            auth_view.gatewayTeamStatus().label(),
        },
    );
}

fn writeProblemsSummary(writer: *std.Io.Writer, app: anytype, alloc: std.mem.Allocator) !void {
    try writer.writeAll("\n## Problems\n");
    var count: usize = 0;

    const state = app.worker.snapshotState(alloc) catch null;
    if (state) |snapshot| {
        defer snapshot.deinit(alloc);
        if (snapshot.processing or app.stream.active) {
            count += 1;
            try writer.print("- report captured an active turn; state may be partial processing={s} stream_active={s} queued={d}\n", .{ boolLabel(snapshot.processing), boolLabel(app.stream.active), snapshot.queued_count });
        }
    }

    if (lastInterruptedTurn(app.session.history.items)) |entry| {
        count += 1;
        try writer.writeAll("- interrupted turn");
        if (entry.tool_call) |call| try writer.print(" in_flight_tool={s}", .{call.name});
        if (entry.completed_tool_names.len > 0) try writer.print(" completed_tools={d}", .{entry.completed_tool_names.len});
        try writer.writeByte('\n');
    }

    var network_buf: [diagnostics.network_ring_capacity]diagnostics.NetworkCall = undefined;
    const network_n = diagnostics.snapshotNetworkCalls(&network_buf);
    var network_reported: usize = 0;
    var ni = network_n;
    while (ni > 0 and network_reported < 3) {
        ni -= 1;
        const call = network_buf[ni];
        if (!networkCallIsError(call)) continue;
        count += 1;
        network_reported += 1;
        try writer.writeAll("- network ");
        try writeNetworkCallCompact(writer, call);
    }

    var tool_buf: [diagnostics.tool_call_ring_capacity]diagnostics.ToolCallMetric = undefined;
    const tool_n = diagnostics.snapshotToolCalls(&tool_buf);
    var tool_reported: usize = 0;
    var ti = tool_n;
    while (ti > 0 and tool_reported < 5) {
        ti -= 1;
        const call = tool_buf[ti];
        if (call.ok) continue;
        count += 1;
        tool_reported += 1;
        try writer.writeAll("- tool ");
        try writeToolCallCompact(writer, call);
    }

    const entries = app.subagents.snapshotEntries(alloc) catch &.{};
    defer if (entries.len > 0) alloc.free(entries);
    for (entries) |entry| {
        if (entry.status != .failed) continue;
        count += 1;
        try writer.print("- subagent failed id={s} label=", .{entry.id});
        try writeMaskedInline(writer, alloc, entry.label);
        try writer.writeByte('\n');
    }

    var mcp_lease = if (comptime @hasDecl(@TypeOf(app.*), "acquireMcpRuntime"))
        app.acquireMcpRuntime()
    else
        null;
    defer if (mcp_lease) |*lease| lease.deinit();
    if (mcp_lease) |lease| {
        const mcp = lease.runtime;
        if (mcp.isDiscovering()) {
            count += 1;
            try writer.writeAll("- mcp discovery in progress\n");
        } else {
            var diagnostics_snapshot = try mcp.snapshotServerDiagnostics(alloc);
            defer diagnostics_snapshot.deinit(alloc);
            for (diagnostics_snapshot.items) |server| {
                if (server.state != .failed) continue;
                count += 1;
                try writer.print("- mcp server failed name={s}", .{server.name});
                if (server.last_error) |err| {
                    try writer.writeAll(" error=");
                    try writeMaskedInline(writer, alloc, err);
                }
                try writer.writeByte('\n');
            }
        }
    }

    if (count == 0) try writer.writeAll("- no obvious errors captured in recent network, tool, subagent, or MCP state\n");
}

fn writeRuntimeContextSummary(writer: *std.Io.Writer, app: anytype, alloc: std.mem.Allocator) !void {
    try writer.writeAll("\n## Runtime Context\n");
    try writer.print("TERM: {s}\n", .{io_mod.getenv("TERM") orelse "(unset)"});
    try writer.print("TERM_PROGRAM: {s}\n", .{io_mod.getenv("TERM_PROGRAM") orelse "(unset)"});
    try writer.print("LANG: {s}\n", .{io_mod.getenv("LANG") orelse "(unset)"});

    const tasks = app.background.snapshotTasks(alloc) catch null;
    if (tasks) |snapshot| {
        defer snapshot.deinit(alloc);
        if (snapshot.items.len == 0) {
            try writer.writeAll("background_tasks: none\n");
        } else {
            try writer.print("background_tasks ({d}):\n", .{snapshot.items.len});
            for (snapshot.items) |task| {
                try writer.print("  - id={d} state={s} pid={s} cwd=", .{ task.id, @tagName(task.state), task.pid });
                try writeMaskedInline(writer, alloc, task.cwd);
                try writer.writeAll(" command=");
                try writeMaskedInline(writer, alloc, task.command);
                try writer.writeAll(" log=");
                try writeMaskedInline(writer, alloc, task.log_path);
                if (task.server_url) |url| {
                    try writer.writeAll(" url=");
                    try writeMaskedInline(writer, alloc, url);
                }
                try writer.writeByte('\n');
            }
        }
    }

    var mcp_lease = if (comptime @hasDecl(@TypeOf(app.*), "acquireMcpRuntime"))
        app.acquireMcpRuntime()
    else
        null;
    defer if (mcp_lease) |*lease| lease.deinit();
    if (mcp_lease) |lease| {
        const mcp = lease.runtime;
        if (mcp.isDiscovering()) {
            try writer.writeAll("mcp_servers: discovery in progress\n");
        } else {
            var diagnostics_snapshot = try mcp.snapshotServerDiagnostics(alloc);
            defer diagnostics_snapshot.deinit(alloc);
            if (diagnostics_snapshot.items.len == 0) {
                try writer.writeAll("mcp_servers: none\n");
            } else {
                try writer.print("mcp_servers ({d}):\n", .{diagnostics_snapshot.items.len});
                for (diagnostics_snapshot.items) |server| {
                    try writer.print("  - {s} state={s} tools={d} command=", .{ server.name, mcpServerStateLabel(server.state), server.tool_count });
                    try writeMaskedInline(writer, alloc, server.command);
                    try writer.writeByte('\n');
                    if (server.last_error) |err| {
                        try writer.writeAll("    error: ");
                        try writeMaskedInline(writer, alloc, err);
                        try writer.writeByte('\n');
                    }
                }
            }
        }
    } else {
        try writer.writeAll("mcp_servers: runtime not loaded\n");
    }
}

fn writeRendererState(writer: *std.Io.Writer, app: anytype, alloc: std.mem.Allocator) !void {
    const transcript_commit = app.shell.transcriptCommitDiagnostic();
    try writer.writeAll("\n## Renderer State\n");
    try writer.print(
        "layout: cols={d} rows={d} content_bottom={d} divider_top={d} input_row={d}\n",
        .{ app.shell.layout.cols, app.shell.layout.rows, app.shell.layout.content_bottom, app.shell.layout.divider_top_row, app.shell.layout.input_row },
    );
    try writer.print(
        "cursor: row={d} col={d} viewport_top={d} owned_top={d} last_visible_top={d} last_start_line={d} partial_skip={d}\n",
        .{
            app.shell.cursor_row,
            app.shell.cursor_col,
            app.shell.viewport_top_row,
            app.shell.owned_top_row,
            app.shell.last_visible_transcript_top_row,
            app.shell.last_visible_transcript_start_line,
            app.shell.last_visible_transcript_partial_skip_rows,
        },
    );
    try writer.print(
        "transcript: bytes={d} entries={d} last_rendered_cols={d} dirty={s} has_painted={s} commit_state={s} committed_start_line={d} pending_compact={s}\n",
        .{
            app.shell.transcript.items.len,
            app.shell.entries.items.len,
            app.shell.last_rendered_cols,
            boolLabel(app.shell.transcript_band_dirty),
            boolLabel(app.shell.has_painted_transcript),
            @tagName(transcript_commit.state),
            transcript_commit.stable_start_line orelse 0,
            boolLabel(app.shell.pending_scroll_compact),
        },
    );
    try writer.print(
        "replaceable: active={s} row={d} start={d}\n",
        .{ boolLabel(app.shell.replaceable_last_line), app.shell.replaceable_row, app.shell.replaceable_start },
    );

    const grid = app.shell.shadow_vt orelse {
        try writer.writeAll("shadow_grid: unavailable\n");
        return;
    };
    try writer.print(
        "shadow_grid: cols={d} rows={d} cursor={d},{d} visible={s} sync_active={s}\n",
        .{ grid.cols, grid.rows, grid.cursor_row, grid.cursor_col, boolLabel(grid.cursor_visible), boolLabel(grid.sync_active) },
    );
    try writer.writeAll("shadow_grid_visible_rows:\n");
    var emitted_any = false;
    var row: u16 = 1;
    while (row <= grid.rows) : (row += 1) {
        var row_text: std.ArrayList(u8) = .empty;
        defer row_text.deinit(alloc);
        try grid.rowTextTrimmed(row, &row_text);
        const trimmed = std.mem.trimEnd(u8, row_text.items, " \t\r");
        if (trimmed.len == 0) continue;
        emitted_any = true;
        const masked = try text_utils.maskSecrets(alloc, trimmed);
        defer if (masked.ptr != trimmed.ptr) alloc.free(masked);
        try writer.print("  {d:0>3}: {s}\n", .{ row, masked });
    }
    if (!emitted_any) try writer.writeAll("  (empty)\n");
}

fn boolLabel(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn lastInterruptedTurn(items: []const types.HistoryTurn) ?types.InterruptedHistoryTurn {
    if (items.len == 0) return null;
    return switch (items[items.len - 1]) {
        .interrupted => |entry| entry,
        else => null,
    };
}

const trace_tool_args_max_bytes: usize = 1200;

fn networkCallIsError(call: diagnostics.NetworkCall) bool {
    return call.errorName().len > 0 or (call.status != 0 and call.status >= 400);
}

fn writeNetworkCallCompact(writer: *std.Io.Writer, call: diagnostics.NetworkCall) !void {
    try writeTraceTimestampUtc(writer, call.started_at_ms);
    try writer.print(" model={s}", .{call.model()});
    if (call.kind != .gateway) try writer.print(" kind={s}", .{@tagName(call.kind)});
    if (call.subagent_id != 0) try writer.print(" source=subagent#{d}", .{call.subagent_id}) else try writer.writeAll(" source=parent");
    if (call.errorName().len > 0) {
        try writer.print(" err={s}", .{call.errorName()});
    } else if (call.status != 0) {
        try writer.print(" status={d}", .{call.status});
    }
    try writer.print(" duration={d}ms bytes={d}", .{ call.duration_ms, call.response_bytes });
    if (call.input_tokens > 0 or call.output_tokens > 0) try writer.print(" tokens={d}->{d}", .{ call.input_tokens, call.output_tokens });
    if (call.is_web_search) try writer.print(" web_search_requests={d}", .{call.web_search_requests});
    if (call.terminalStopReason().len > 0) try writer.print(" stop_reason={s}", .{call.terminalStopReason()});
    if (call.turn_id != 0) try writer.print(" turn={d}", .{call.turn_id});
    if (call.step_id != 0) try writer.print(" step={d}", .{call.step_id});
    if (call.gatewaySchemaDiagnostic().len > 0) try writer.print(" gateway_schema=\"{s}\"", .{call.gatewaySchemaDiagnostic()});
    if (call.gatewayRequestShape().len > 0) try writer.print(" request_shape=\"{s}\"", .{call.gatewayRequestShape()});
    try writer.writeByte('\n');
}

fn writeNetworkCallsSummary(writer: *std.Io.Writer) !void {
    var buf: [diagnostics.network_ring_capacity]diagnostics.NetworkCall = undefined;
    const n = diagnostics.snapshotNetworkCalls(&buf);
    if (n == 0) {
        try writer.writeAll("\n## Network Calls\n(none recorded)\n");
        return;
    }

    var ok_count: u32 = 0;
    var error_count: u32 = 0;
    var total_ms: u64 = 0;
    var max_ms: u32 = 0;
    var min_ms: u32 = std.math.maxInt(u32);
    for (buf[0..n]) |call| {
        if (networkCallIsError(call)) error_count += 1 else ok_count += 1;
        total_ms += call.duration_ms;
        if (call.duration_ms > max_ms) max_ms = call.duration_ms;
        if (call.duration_ms < min_ms) min_ms = call.duration_ms;
    }
    const avg_ms: u64 = if (n > 0) total_ms / n else 0;

    try writer.print("\n## Network Calls\nlast={d} ok={d} errors={d} avg={d}ms min={d}ms max={d}ms\n", .{ n, ok_count, error_count, avg_ms, min_ms, max_ms });
    for (buf[0..n]) |call| {
        try writeNetworkCallCompact(writer, call);
    }
}

fn writePermissionsSummary(writer: *std.Io.Writer, grants: []const types.PermissionGrant) !void {
    if (grants.len == 0) {
        try writer.writeAll("\n## Permissions\npermission grants: none\n");
        return;
    }
    try writer.print("\n## Permissions\npermission grants ({d}):\n", .{grants.len});
    for (grants) |grant| {
        try writer.print("  - {s} :: {s}\n", .{ grant.tool_name, grant.target_path });
    }
}

fn writeSubagentsSummary(writer: *std.Io.Writer, alloc: std.mem.Allocator, controller: anytype) !void {
    const entries = controller.snapshotEntries(alloc) catch {
        try writer.writeAll("\n## Subagents\n(snapshot failed)\n");
        return;
    };
    defer alloc.free(entries);
    if (entries.len == 0) {
        try writer.writeAll("\n## Subagents\n(none)\n");
        return;
    }
    try writer.print("\n## Subagents\ncount={d}\n", .{entries.len});
    for (entries) |entry| {
        try writer.print("[{s}] ", .{entry.id});
        try writeMaskedInline(writer, alloc, entry.label);
        try writer.print(" status={s} unread={d}", .{ ui_subagents.statusLabelPublic(entry.status), entry.unread_count });
        if (entry.external_busy) try writer.writeAll(" external_busy=true");
        try writer.writeByte('\n');
    }
}

fn writeToolCallCompact(writer: *std.Io.Writer, call: diagnostics.ToolCallMetric) !void {
    try writeTraceTimestampUtc(writer, call.started_at_ms);
    try writer.print(" name={s} status={s} duration={d}ms", .{ call.name(), if (call.ok) "ok" else "err", call.duration_ms });
    if (call.subagent_id != 0) try writer.print(" source=subagent#{d}", .{call.subagent_id}) else try writer.writeAll(" source=parent");
    try writer.writeByte('\n');
}

noinline fn writeToolCallsSummary(writer: *std.Io.Writer, alloc: std.mem.Allocator) !void {
    var buf: [diagnostics.tool_call_ring_capacity]diagnostics.ToolCallMetric = undefined;
    const n = diagnostics.snapshotToolCalls(&buf);
    if (n == 0) {
        try writer.writeAll("\n## Tool Calls\n(none recorded)\n");
        return;
    }

    var ok_count: u32 = 0;
    var error_count: u32 = 0;
    var total_ms: u64 = 0;
    for (buf[0..n]) |call| {
        if (call.ok) ok_count += 1 else error_count += 1;
        total_ms += call.duration_ms;
    }

    try writer.print("\n## Tool Calls\nlast={d} ok={d} errors={d} total={d}ms\n", .{ n, ok_count, error_count, total_ms });
    if (error_count > 0) {
        try writer.writeAll("errors first:\n");
        for (buf[0..n]) |call| {
            if (call.ok) continue;
            try writeToolCallCompact(writer, call);
            try writeToolFieldBlock(writer, alloc, "args", call.args(), call.args_len, call.args_total_bytes);
            try writeToolFieldBlock(writer, alloc, "result", call.result(), call.result_len, call.result_total_bytes);
        }
        try writer.writeAll("recent successes (compact):\n");
    } else {
        try writer.writeAll("recent successes (compact):\n");
    }
    for (buf[0..n]) |call| {
        if (!call.ok) continue;
        try writeToolCallCompact(writer, call);
        try writeToolFieldBlock(writer, alloc, "args", call.args(), call.args_len, call.args_total_bytes);
        try writeToolResultPreview(writer, alloc, call.result(), call.result_total_bytes);
    }
}

fn writeToolResultPreview(writer: *std.Io.Writer, alloc: std.mem.Allocator, body: []const u8, total_bytes: u32) !void {
    if (total_bytes == 0) return;
    const raw_trimmed = std.mem.trim(u8, body, " \t\r\n");
    const masked = try text_utils.maskSecrets(alloc, raw_trimmed);
    defer if (masked.ptr != raw_trimmed.ptr) alloc.free(masked);
    const trimmed = std.mem.trim(u8, masked, " \t\r\n");
    if (trimmed.len == 0) return;

    const preview = firstUsefulPreviewLine(trimmed);
    try writer.writeAll("  result_preview: ");
    if (preview.len > 180) {
        try writer.writeAll(preview[0..180]);
        try writer.writeAll(" ...");
    } else {
        try writer.writeAll(preview);
    }
    if (total_bytes > preview.len) try writer.print(" ({d} bytes total)", .{total_bytes});
    try writer.writeByte('\n');
}

fn firstUsefulPreviewLine(text: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, ":")) continue;
        return trimmed;
    }
    return text[0..@min(text.len, 180)];
}

fn writeToolFieldBlock(writer: *std.Io.Writer, alloc: std.mem.Allocator, label: []const u8, body: []const u8, body_len: u16, total_bytes: u32) !void {
    if (total_bytes == 0) return;
    const raw_trimmed = std.mem.trim(u8, body, " \t\r\n");
    const masked = try text_utils.maskSecrets(alloc, raw_trimmed);
    defer if (masked.ptr != raw_trimmed.ptr) alloc.free(masked);
    const trimmed = std.mem.trim(u8, masked, " \t\r\n");
    if (trimmed.len == 0) return;

    if (std.mem.findScalar(u8, trimmed, '\n') == null) {
        try writer.print("  {s}: {s}", .{ label, trimmed });
        if (total_bytes > body_len) {
            try writer.print(" ... ({d} more bytes)", .{total_bytes - body_len});
        }
        try writer.writeByte('\n');
        return;
    }

    try writer.print("  {s}:\n", .{label});
    var it = std.mem.splitScalar(u8, trimmed, '\n');
    while (it.next()) |line| {
        try writer.print("    {s}\n", .{std.mem.trimEnd(u8, line, " \t\r")});
    }
    if (total_bytes > body_len) {
        try writer.print("    ... ({d} more bytes)\n", .{total_bytes - body_len});
    }
}

fn writeLastInterruptedDetail(writer: *std.Io.Writer, items: []const types.HistoryTurn, alloc: std.mem.Allocator) !void {
    if (items.len == 0) return;
    const last = items[items.len - 1];
    switch (last) {
        .interrupted => |t| {
            try writer.writeAll("\n## Interrupted Turn\nlast turn was interrupted by user\n");
            if (t.tool_call) |call| {
                try writer.print("  in_flight_tool: {s}\n", .{call.name});
                if (call.arguments_json.len > 0) {
                    try writer.writeAll("  in_flight_args:\n");
                    if (call.arguments_json.len > trace_tool_args_max_bytes) {
                        try writer.writeAll("    ");
                        try writeMaskedInline(writer, alloc, call.arguments_json[0..trace_tool_args_max_bytes]);
                        try writer.print("\n    ... (truncated, {d} more bytes)\n", .{call.arguments_json.len - trace_tool_args_max_bytes});
                    } else {
                        try writer.writeAll("    ");
                        try writeMaskedInline(writer, alloc, call.arguments_json);
                        try writer.writeByte('\n');
                    }
                }
            }
            if (t.completed_tool_names.len > 0) {
                try writer.print("  completed_tools ({d}):", .{t.completed_tool_names.len});
                for (t.completed_tool_names) |name| try writer.print(" {s}", .{name});
                try writer.writeByte('\n');
            }
        },
        else => {},
    }
}

const trace_tail_bytes: usize = 6 * 1024;
const trace_max_lines: usize = 80;

fn writeTraceLogTail(writer: *std.Io.Writer, alloc: std.mem.Allocator, path: []const u8) !void {
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch return;
    defer file.close(io_mod.getIo());

    var stat_buf: std.Io.File.Stat = undefined;
    stat_buf = file.stat(io_mod.getIo()) catch return;
    const total_size: usize = @intCast(stat_buf.size);
    if (total_size == 0) return;

    const read_size = @min(total_size, trace_tail_bytes);
    const offset: u64 = total_size - read_size;

    const buf = alloc.alloc(u8, read_size) catch return;
    defer alloc.free(buf);
    const n = file.readPositionalAll(io_mod.getIo(), buf, offset) catch return;
    if (n == 0) return;

    try writer.print("\n## Trace Tail\npath={s} last_bytes={d}\n", .{ path, n });
    try writer.writeAll("only obvious secrets masked\n");
    if (offset > 0) try writer.writeAll("... (older lines truncated)\n");

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(alloc);
    var it = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        try lines.append(alloc, trimmed);
    }

    const start = if (lines.items.len > trace_max_lines)
        lines.items.len - trace_max_lines
    else
        0;

    for (lines.items[start..]) |line| {
        const masked = try text_utils.maskSecrets(alloc, line);
        defer if (masked.ptr != line.ptr) alloc.free(masked);
        if (masked.len > trace_transcript_max_line_bytes) {
            try writer.writeAll(masked[0..trace_transcript_max_line_bytes]);
            try writer.writeAll(" ...\n");
        } else {
            try writer.writeAll(masked);
            try writer.writeByte('\n');
        }
    }
}

fn writeTraceTimestampUtc(writer: *std.Io.Writer, ms: i64) !void {
    if (ms <= 0) {
        try writer.writeAll("[----------T--:--:--Z]");
        return;
    }
    const secs: u64 = @intCast(@divFloor(ms, 1000));
    const ms_part: u64 = @intCast(@mod(ms, 1000));
    const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(secs) };
    const day_seconds = epoch_secs.getDaySeconds();
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    try writer.print("[{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z]", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
        ms_part,
    });
}

noinline fn writeTranscriptTimeline(writer: *std.Io.Writer, alloc: std.mem.Allocator, entries: anytype) !void {
    var emitted_any = false;
    for (entries) |entry| {
        const ts = entry.createdAtMs();
        var rendered_payload: ?[]u8 = null;
        defer if (rendered_payload) |text| alloc.free(text);
        const kind: []const u8 = switch (entry) {
            .raw_bytes => "raw",
            .user_turn => "user",
            .assistant_turn => "assistant",
            .assistant_table => "assistant table",
            .assistant_code_block => "assistant code block",
            .assistant_thematic_rule => "assistant thematic rule",
            .semantic_notice => "semantic notice",
        };
        const text: []const u8 = switch (entry) {
            .raw_bytes => |e| e.bytes,
            .user_turn => |e| e.turn.text,
            .assistant_turn => |e| e.segments.text.items,
            .assistant_table => |e| blk: {
                var table_text: std.ArrayList(u8) = .empty;
                errdefer table_text.deinit(alloc);
                try assistant_presentation.renderTablePayload(alloc, e.table, &table_text);
                rendered_payload = try table_text.toOwnedSlice(alloc);
                break :blk rendered_payload.?;
            },
            .assistant_code_block => |e| blk: {
                var code_text: std.ArrayList(u8) = .empty;
                errdefer code_text.deinit(alloc);
                try assistant_presentation.renderCodeBlockPayload(alloc, e.block, &code_text);
                rendered_payload = try code_text.toOwnedSlice(alloc);
                break :blk rendered_payload.?;
            },
            .assistant_thematic_rule => blk: {
                var rule_text: std.ArrayList(u8) = .empty;
                errdefer rule_text.deinit(alloc);
                try assistant_presentation.writeHorizontalRule(alloc, &rule_text);
                rendered_payload = try rule_text.toOwnedSlice(alloc);
                break :blk rendered_payload.?;
            },
            .semantic_notice => |e| blk: {
                const rendered = try transcript_blocks.renderSemanticNotice(
                    alloc,
                    .{
                        .topic = e.topic,
                        .tone = e.tone,
                        .body = e.body,
                        .visibility = e.visibility,
                    },
                    .{},
                    std.math.maxInt(u16),
                );
                rendered_payload = rendered;
                break :blk rendered;
            },
        };
        if (text.len == 0) continue;

        const body = switch (entry) {
            .assistant_thematic_rule => try renderThematicRuleTimelineBody(alloc, text),
            else => try renderTimelineEntryBody(alloc, text),
        };
        defer alloc.free(body);
        if (body.len == 0) continue;

        if (emitted_any) try writer.writeByte('\n');
        try writeTraceTimestampUtc(writer, ts);
        try writer.print(" {s}\n", .{kind});
        try writer.writeAll(body);
        emitted_any = true;
    }
    if (!emitted_any) try writer.writeAll("(empty after filtering)\n");
}

fn renderTimelineEntryBody(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    const stripped = try stripAnsiEscapes(alloc, text);
    defer alloc.free(stripped);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var it = std.mem.splitScalar(u8, stripped, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (isBannerNoiseLine(trimmed)) continue;
        const masked = try text_utils.maskSecrets(alloc, trimmed);
        defer if (masked.ptr != trimmed.ptr) alloc.free(masked);
        try out.appendSlice(alloc, "  ");
        try out.appendSlice(alloc, masked);
        try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}

fn renderThematicRuleTimelineBody(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    const stripped = try stripAnsiEscapes(alloc, text);
    defer alloc.free(stripped);
    const trimmed = std.mem.trimEnd(u8, stripped, " \t\r\n");
    return std.fmt.allocPrint(alloc, "  {s}\n", .{trimmed});
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
        stream: struct { active: bool = false } = .{},
        worker: worker_runtime.WorkerRuntime = .{},
    }{};
    defer app.worker.deinit(alloc);

    try app.worker.enqueuePrompt(alloc, .{
        .prompt = try alloc.dupe(u8, "active turn"),
        .images = &.{},
        .model = try alloc.dupe(u8, "test-model"),
        .api_key = try alloc.dupe(u8, "test-key"),
        .permission_mode = .auto,
        .history = try alloc.alloc(types.HistoryTurn, 0),
        .grants = try alloc.alloc(types.PermissionGrant, 0),
    });
    const active = (try app.worker.waitAndTakeNextPrompt(alloc)).?;
    defer worker_runtime.freeQueuedPrompt(alloc, active);

    try std.testing.expectEqual(@as(usize, 0), app.worker.queuedPromptCount());
    try std.testing.expect(!tryBeginWorkspaceMutation(&app));

    app.worker.finishProcessing();
    try std.testing.expect(tryBeginWorkspaceMutation(&app));
    app.worker.releaseTurnStartHold();
}

test "workspace list refresh waits for an idle turn" {
    const alloc = std.testing.allocator;
    const TestApp = struct {
        stream: struct { active: bool = false } = .{},
        worker: worker_runtime.WorkerRuntime = .{},
        available: bool = true,
        active: bool = true,
        index_refresh_count: usize = 0,

        fn refreshWorkspaceAccess(self: *@This()) !bool {
            self.available = false;
            self.active = false;
            self.index_refresh_count += 1;
            return true;
        }
    };
    var app = TestApp{};
    defer app.worker.deinit(alloc);

    app.stream.active = true;
    try refreshWorkspaceAvailabilityForList(&app);
    try std.testing.expect(app.available);
    try std.testing.expect(app.active);
    try std.testing.expectEqual(@as(usize, 0), app.index_refresh_count);

    app.stream.active = false;
    try app.worker.enqueuePrompt(alloc, .{
        .prompt = try alloc.dupe(u8, "active turn"),
        .images = &.{},
        .model = try alloc.dupe(u8, "test-model"),
        .api_key = try alloc.dupe(u8, "test-key"),
        .permission_mode = .auto,
        .history = try alloc.alloc(types.HistoryTurn, 0),
        .grants = try alloc.alloc(types.PermissionGrant, 0),
    });
    const queued = (try app.worker.waitAndTakeNextPrompt(alloc)).?;
    defer worker_runtime.freeQueuedPrompt(alloc, queued);

    try refreshWorkspaceAvailabilityForList(&app);
    try std.testing.expect(app.available);
    try std.testing.expect(app.active);
    try std.testing.expectEqual(@as(usize, 0), app.index_refresh_count);

    app.worker.finishProcessing();
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
        stream: struct { active: bool = false } = .{},
        worker: worker_runtime.WorkerRuntime = .{},
        access: Access = .{},
        transcript: std.ArrayList(u8) = .empty,
        last_tone: ?types.NoticeTone = null,

        fn deinit(self: *@This()) void {
            self.worker.deinit(self.alloc);
            self.transcript.deinit(self.alloc);
        }

        fn refreshWorkspaceAccess(_: *@This()) !bool {
            return error.TooManyDirectories;
        }

        fn workspaceAccess(self: *@This()) *const Access {
            return &self.access;
        }

        fn installWorkspaceAccess(_: *@This(), _: *Access) bool {
            return false;
        }

        noinline fn writeDomainNotice(self: *@This(), notice: types.SemanticNotice, _: bool) !void {
            self.last_tone = notice.tone;
            try self.transcript.appendSlice(self.alloc, notice.body);
        }
    };

    var app = TestApp{ .alloc = alloc };
    defer app.deinit();
    try handleWorkspaceCommand(&app, "");
    try std.testing.expectEqual(types.NoticeTone.@"error", app.last_tone.?);
    try std.testing.expect(std.mem.find(u8, app.transcript.items, "Workspace refresh rejected: additional directory limit reached") != null);
    try std.testing.expectEqual(@as(usize, 0), app.access.entries.len);
}

test "trace timeline retains semantic table contents" {
    const alloc = std.testing.allocator;
    var entries: std.ArrayList(TranscriptEntry) = .empty;
    defer {
        for (entries.items) |*entry| entry.deinit(alloc);
        entries.deinit(alloc);
    }

    const table = try assistant_presentation.parseTablePayload(
        alloc,
        "| Name | Count |\n" ++
            "|------|------:|\n" ++
            "| api | 7 |\n",
    );
    try entries.append(alloc, .{ .assistant_table = .{ .id = 1, .table = table } });

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeTranscriptTimeline(&out.writer, alloc, entries.items);

    try std.testing.expect(std.mem.find(u8, out.written(), "api") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "[structured table]") == null);
}

test "trace timeline retains semantic code block contents" {
    const alloc = std.testing.allocator;
    var entries: std.ArrayList(TranscriptEntry) = .empty;
    defer {
        for (entries.items) |*entry| entry.deinit(alloc);
        entries.deinit(alloc);
    }

    const block = assistant_presentation.CodeBlockPayload{
        .language = try alloc.dupe(u8, "zig"),
        .code = try alloc.dupe(u8, "const value = 1;\n"),
    };
    try entries.append(alloc, .{ .assistant_code_block = .{ .id = 1, .block = block } });

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeTranscriptTimeline(&out.writer, alloc, entries.items);

    try std.testing.expect(std.mem.find(u8, out.written(), "assistant code block") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "const value = 1;") != null);
}

test "trace timeline retains the semantic thematic rule adapter" {
    const alloc = std.testing.allocator;
    var entries: std.ArrayList(TranscriptEntry) = .empty;
    defer {
        for (entries.items) |*entry| entry.deinit(alloc);
        entries.deinit(alloc);
    }
    try entries.append(alloc, .{ .assistant_thematic_rule = .{ .id = 1 } });

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeTranscriptTimeline(&out.writer, alloc, entries.items);

    try std.testing.expect(std.mem.find(u8, out.written(), "assistant thematic rule") != null);
    try std.testing.expectEqual(@as(usize, 60), std.mem.count(u8, out.written(), "\xe2\x94\x80"));
}

fn isBannerNoiseLine(line: []const u8) bool {
    if (line.len == 0) return true;
    if (std.mem.find(u8, line, "\xe2\x96\x91") != null) return true;
    var has_alnum: bool = false;
    for (line) |c| if (std.ascii.isAlphanumeric(c)) {
        has_alnum = true;
        break;
    };
    return !has_alnum;
}

fn stripAnsiEscapes(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, input.len);

    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (c == 0x1b and i + 1 < input.len) {
            const next = input[i + 1];
            if (next == '[') {
                // CSI: ESC '[' params... final-byte (0x40-0x7E)
                i += 2;
                while (i < input.len) {
                    const b = input[i];
                    i += 1;
                    if (b >= 0x40 and b <= 0x7E) break;
                }
                continue;
            }
            if (next == ']') {
                // OSC: ESC ']' ... BEL (0x07) or ESC '\'
                i += 2;
                while (i < input.len) {
                    const b = input[i];
                    if (b == 0x07) {
                        i += 1;
                        break;
                    }
                    if (b == 0x1b and i + 1 < input.len and input[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                    i += 1;
                }
                continue;
            }
            // Other ESC sequences: skip ESC + one byte
            i += 2;
            continue;
        }
        if (c == '\r') {
            i += 1;
            continue;
        }
        try out.append(alloc, c);
        i += 1;
    }

    return out.toOwnedSlice(alloc);
}

noinline fn parseAppearanceChange(rest: []const u8) ?settings_catalog.Change {
    var tokens = std.mem.tokenizeAny(u8, rest, " \t");
    const first = tokens.next() orelse return null;
    const second = tokens.next();
    if (tokens.next() != null) return null;

    if (second) |value| {
        if (std.mem.eql(u8, first, "input")) {
            const appearance = input_appearance.InputAppearance.parse(value) orelse return null;
            return .{ .setting = .input_appearance, .value = appearance.label() };
        }
        if (std.mem.eql(u8, first, "presentation")) {
            const mode = presentation_mode.MaxxingMode.parse(value) orelse return null;
            return .{ .setting = .maxxing_mode, .value = mode.label() };
        }
        return null;
    }

    if (input_appearance.InputAppearance.parse(first)) |appearance| {
        return .{ .setting = .input_appearance, .value = appearance.label() };
    }
    if (presentation_mode.MaxxingMode.parse(first)) |mode| {
        return .{ .setting = .maxxing_mode, .value = mode.label() };
    }
    return null;
}

fn handleInputAppearanceCommand(app: anytype, rest: []const u8) !void {
    const trimmed = std.mem.trim(u8, rest, " \t");

    if (trimmed.len == 0) {
        debug_trace.logf("core", "input command show current={s}", .{app.input_runtime.input_appearance.label()});
        const msg = try std.fmt.allocPrint(
            app.alloc,
            "current: {s}\n" ++
                "available: lines, tint\n" ++
                "  lines current two-line composer chrome\n" ++
                "  tint  tinted composer background\n" ++
                "examples: /input lines, /input tint",
            .{app.input_runtime.input_appearance.label()},
        );
        defer app.alloc.free(msg);
        try app.writeDomainNotice(.{ .topic = "input", .tone = .neutral, .body = msg }, true);
        return;
    }

    const next = input_appearance.InputAppearance.parse(trimmed) orelse {
        debug_trace.logf("core", "input command rejected arg_bytes={d}", .{trimmed.len});
        try app.writeDomainNotice(.{ .topic = "input", .tone = .@"error", .body = "Use: lines, tint" }, true);
        return;
    };

    const runtime_changed = next != app.input_runtime.input_appearance;
    if (runtime_changed) {
        app.input_runtime.input_appearance = next;
        app.shell.render_requests.request(.footer);
    }
    try persistInputAppearanceSetting(app, next, runtime_changed);

    if (!runtime_changed) {
        debug_trace.logf("core", "input command unchanged mode={s}", .{next.label()});
        const msg = try std.fmt.allocPrint(app.alloc, "already in {s}", .{next.label()});
        defer app.alloc.free(msg);
        try app.writeDomainNotice(.{ .topic = "input", .tone = .neutral, .body = msg }, true);
        return;
    }

    debug_trace.logf("core", "input command switched mode={s}", .{next.label()});
    const msg = try std.fmt.allocPrint(app.alloc, "switched to {s}", .{next.label()});
    defer app.alloc.free(msg);
    try app.writeDomainNotice(.{ .topic = "input", .tone = .neutral, .body = msg }, true);
}

fn persistInputAppearanceSetting(app: anytype, next: input_appearance.InputAppearance, runtime_changed: bool) !void {
    if (comptime @hasDecl(@TypeOf(app.*), "persistInputAppearance")) {
        try app.persistInputAppearance(next.label(), runtime_changed);
        return;
    }

    const patch = config_runtime.UserSettingsPatch{ .input_appearance = next.label() };
    try persistUserPreferences(app, "input", patch, runtime_changed);
}

fn handleMaxxingCommand(app: anytype, rest: []const u8) !void {
    const trimmed = std.mem.trim(u8, rest, " \t");

    if (trimmed.len == 0) {
        const msg = try std.fmt.allocPrint(
            app.alloc,
            "current: {s}\n" ++
                "available: minimal, legacy\n" ++
                "  minimal bare composer and grouped tool activity\n" ++
                "  legacy  original Fx presentation\n" ++
                "examples: /maxxing minimal, /maxxing legacy",
            .{app.shell.maxxing_mode.label()},
        );
        defer app.alloc.free(msg);
        try app.writeDomainNotice(.{ .topic = "maxxing", .tone = .neutral, .body = msg }, true);
        return;
    }

    const next = presentation_mode.MaxxingMode.parse(trimmed) orelse {
        try app.writeDomainNotice(.{ .topic = "maxxing", .tone = .@"error", .body = "Use: minimal, legacy" }, true);
        return;
    };

    const runtime_changed = next != app.shell.maxxing_mode;
    if (runtime_changed) {
        app.shell.maxxing_mode = next;
        app.shell.render_requests.request(.transcript);
        app.shell.render_requests.request(.footer);
    }
    try persistMaxxingModeSetting(app, next, runtime_changed);

    const msg = try std.fmt.allocPrint(app.alloc, "{s} {s}", .{
        if (runtime_changed) "switched to" else "already in",
        next.label(),
    });
    defer app.alloc.free(msg);
    try app.writeDomainNotice(.{
        .topic = "maxxing",
        .tone = .neutral,
        .body = msg,
    }, true);
}

fn persistMaxxingModeSetting(app: anytype, next: presentation_mode.MaxxingMode, runtime_changed: bool) !void {
    if (comptime @hasDecl(@TypeOf(app.*), "persistMaxxingMode")) {
        try app.persistMaxxingMode(next.label(), runtime_changed);
        return;
    }

    const patch = config_runtime.UserSettingsPatch{ .maxxing_mode = next.label() };
    try persistUserPreferences(app, "maxxing", patch, runtime_changed);
}

fn handleRenameCommand(app: anytype, rest: []const u8) !void {
    const App = @TypeOf(app.*);
    const SessionRuntime = app_session_runtime.Runtime(App);
    SessionRuntime.renameActiveSession(app, rest) catch |err| {
        const body: []const u8 = switch (err) {
            error.EmptyTitle => "Use: /rename <title>",
            error.TitleTooLong => "title is too long",
            error.InvalidTitle => "title must be printable text",
            error.NoActiveSession => "no active session to rename",
            else => {
                const notice = try std.fmt.allocPrint(
                    app.alloc,
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
    const title = SessionRuntime.cachedSessionTitle(app) orelse "";
    const msg = try std.fmt.allocPrint(app.alloc, "renamed: {s}", .{title});
    defer app.alloc.free(msg);
    try app.writeDomainNotice(.{ .topic = "session", .tone = .neutral, .body = msg }, true);
}

const StatuslineFeedback = enum { announce, silent };

fn parseStatuslineItem(raw: []const u8) ?config_runtime.StatuslineItem {
    const trimmed = std.mem.trim(u8, raw, " \t");
    inline for (std.meta.fields(config_runtime.StatuslineItem)) |field| {
        if (std.mem.eql(u8, trimmed, field.name)) return @enumFromInt(field.value);
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
            const message = try std.fmt.allocPrint(
                app.alloc,
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
            .topic = "statusline",
            .tone = .@"error",
            .body = "Use: context, session, workspace",
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
                .topic = "sound",
                .tone = .@"error",
                .body = "Use: /sound [on|off|max].",
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
    if (comptime @hasField(App, "effort")) snapshot.effort = app.effort.displayLabel();
    if (comptime @hasField(App, "fast_mode")) snapshot.fast_mode = app.fast_mode;
    if (comptime @hasDecl(App, "resolvedModelCapabilities") and provider_runtime.supported(App)) {
        const capabilities = app.resolvedModelCapabilities(provider_runtime.model(app));
        snapshot.reasoning_efforts = capabilities.reasoning_efforts;
        snapshot.supports_fast_mode = capabilities.supports_fast_mode;
    }
    if (comptime @hasField(App, "permission_engine")) snapshot.permission_mode = @tagName(app.permission_engine.mode);
    if (comptime @hasField(App, "input_runtime")) {
        snapshot.input_appearance = app.input_runtime.input_appearance.label();
        snapshot.startup_scrollback = app.input_runtime.settings_menu.startup_scrollback;
        if (comptime @hasField(@TypeOf(app.input_runtime), "slash_menu_categories")) {
            snapshot.slash_menu_categories = app.input_runtime.slash_menu_categories;
        }
    }
    if (comptime @hasField(App, "shell")) {
        if (comptime @hasField(@TypeOf(app.shell), "maxxing_mode")) {
            snapshot.maxxing_mode = app.shell.maxxing_mode.label();
        }
    }
    if (comptime @hasField(App, "statusline_context")) snapshot.statusline_context = app.statusline_context;
    if (comptime @hasField(App, "statusline_session")) snapshot.statusline_session = app.statusline_session;
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
        .input_appearance => {
            const next = input_appearance.InputAppearance.parse(change.value) orelse
                return error.InvalidSettingsCatalogValue;
            const runtime_changed = next != app.input_runtime.input_appearance;
            if (runtime_changed) app.input_runtime.input_appearance = next;
            try persistUserPreferencesSilently(
                app,
                "input",
                .{ .input_appearance = next.label() },
                runtime_changed,
            );
        },
        .maxxing_mode => {
            const next = presentation_mode.MaxxingMode.parse(change.value) orelse
                return error.InvalidSettingsCatalogValue;
            const runtime_changed = next != app.shell.maxxing_mode;
            if (runtime_changed) {
                app.shell.maxxing_mode = next;
                app.shell.render_requests.request(.transcript);
            }
            try persistUserPreferencesSilently(
                app,
                "maxxing",
                .{ .maxxing_mode = next.label() },
                runtime_changed,
            );
        },
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
        .input_appearance => try handleInputAppearanceCommand(app, change.value),
        .maxxing_mode => try handleMaxxingCommand(app, change.value),
        .statusline_context, .statusline_session, .statusline_workspace => {
            const enabled = parseOnOff(change.value) orelse return error.InvalidSettingsCatalogValue;
            const item = statuslineItemForSetting(change.setting).?;
            if (enabled != statuslineItemEnabled(app, item)) {
                try applyStatuslineItem(app, item, enabled, .announce);
            }
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
        .effort => {
            const effort = types.ReasoningEffort.parseDisplayLabel(change.value) orelse
                return error.InvalidSettingsCatalogValue;
            const capabilities = app.resolvedModelCapabilities(provider_runtime.model(app));
            if (!model_capabilities.reasoningEffortSupported(capabilities, effort)) {
                const message = try std.fmt.allocPrint(
                    app.alloc,
                    "{s} is not available for {s}",
                    .{ effort.displayLabel(), provider_runtime.model(app) },
                );
                defer app.alloc.free(message);
                try app.writeDomainNotice(.{ .topic = "effort", .tone = .neutral, .body = message }, true);
                return;
            }
            try session_commands.Commands(@TypeOf(app.*)).selectEffortFromSettings(app, effort);
        },
        .fast_mode => {
            const enabled = parseOnOff(change.value) orelse return error.InvalidSettingsCatalogValue;
            if (enabled != app.fast_mode) try session_commands.Commands(@TypeOf(app.*)).toggleFast(app);
        },
        .permission_mode => try session_commands.Commands(@TypeOf(app.*)).handlePermissions(app, change.value),
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

const McpCommandFakeApp = struct {
    const ReloadBehavior = enum {
        published_empty,
        published_healthy,
        published_degraded,
        retained,
        completion_failed,
        begin_failed,
    };

    alloc: std.mem.Allocator,
    notice_body: std.ArrayList(u8) = .empty,
    list_count: usize = 0,
    reload_count: usize = 0,
    notice_count: usize = 0,
    last_topic: ?[]const u8 = null,
    last_tone: ?types.NoticeTone = null,
    reload_behavior: ReloadBehavior = .published_empty,
    reload_pending: bool = false,

    fn deinit(self: *McpCommandFakeApp) void {
        self.notice_body.deinit(self.alloc);
    }

    fn mcpCommandProvider(_: *const McpCommandFakeApp) mcp_command_provider.Provider {
        return .{ .handle_fn = handleMcpCommand };
    }

    fn handleMcpCommand(
        alloc: std.mem.Allocator,
        rest: []const u8,
        request: mcp_command_provider.Request,
    ) !mcp_command_provider.Result {
        _ = request;
        if (std.mem.eql(u8, rest, "reload")) {
            return .{
                .display = .{
                    .line = try alloc.dupe(u8, "Evaluating trusted profile MCP configuration."),
                },
                .reload = true,
                .report_reload = true,
            };
        }
        try std.testing.expectEqualStrings("auth fixture --open", rest);
        return .{
            .display = .{
                .line = try alloc.dupe(u8, "Authenticated MCP server 'fixture'."),
            },
            .reload = true,
        };
    }

    fn listMcpServersAndTools(self: *McpCommandFakeApp, alloc: std.mem.Allocator) ![]u8 {
        self.list_count += 1;
        return alloc.dupe(u8, "configured server and tool\n");
    }

    fn summarizeMcpServers(self: *McpCommandFakeApp, alloc: std.mem.Allocator) ![]u8 {
        return self.listMcpServersAndTools(alloc);
    }

    fn beginMcpReload(self: *McpCommandFakeApp) !void {
        self.reload_count += 1;
        if (self.reload_behavior == .begin_failed) return error.TestReloadFailed;
        self.reload_pending = true;
    }

    fn takeMcpReloadCompletion(self: *McpCommandFakeApp) !?app_mcp_runtime.ReloadCompletion {
        if (!self.reload_pending) return null;
        self.reload_pending = false;
        return switch (self.reload_behavior) {
            .published_empty => .{ .outcome = .{ .published = .{
                .generation = null,
                .health = .ready,
                .configured_server_count = 0,
                .unavailable_server_names = try self.alloc.alloc([]u8, 0),
            } } },
            .published_healthy => .{ .outcome = .{ .published = .{
                .generation = 42,
                .health = .ready,
                .configured_server_count = 1,
                .unavailable_server_names = try self.alloc.alloc([]u8, 0),
            } } },
            .published_degraded => degraded: {
                const names = try self.alloc.alloc([]u8, 2);
                errdefer self.alloc.free(names);
                names[0] = try self.alloc.dupe(u8, "alpha");
                errdefer self.alloc.free(names[0]);
                names[1] = try self.alloc.dupe(u8, "beta");
                break :degraded .{ .outcome = .{ .published = .{
                    .generation = 43,
                    .health = .degraded,
                    .configured_server_count = 3,
                    .unavailable_server_names = names,
                } } };
            },
            .retained => .{ .outcome = .{
                .retained_required_failure = try self.alloc.dupe(
                    u8,
                    "Required MCP server 'fixture' failed to start.",
                ),
            } },
            .completion_failed => .{ .failed = error.TestReloadFailed },
            .begin_failed => unreachable,
        };
    }

    noinline fn writeDomainNotice(self: *McpCommandFakeApp, notice: types.SemanticNotice, _: bool) !void {
        self.notice_count += 1;
        self.last_topic = notice.topic;
        self.last_tone = notice.tone;
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
    clear_count: usize = 0,
    new_count: usize = 0,
    reset_count: usize = 0,

    fn clearSession(self: *ClearCommandFakeApp) !void {
        self.clear_count += 1;
    }

    fn newSession(self: *ClearCommandFakeApp) !void {
        self.new_count += 1;
    }

    fn resetSession(self: *ClearCommandFakeApp) !void {
        self.reset_count += 1;
    }
};

const QuitCommandFakeApp = struct {
    should_exit: bool = false,
    session_persistence: app_session_runtime.Persistence = .{},
};

test "quit command requests resume handoff before exit" {
    var app = QuitCommandFakeApp{};
    defer app.session_persistence.deinit(std.testing.allocator);

    requestResumeExit(&app);

    try std.testing.expect(app.should_exit);
    try std.testing.expectEqual(
        app_session_runtime.ResumeHandoffIntent.requested,
        app.session_persistence.resume_handoff_intent,
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

    session: Session = .{},
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
};

const InputAppearanceCommandFakeApp = struct {
    const InputAppearance = input_appearance.InputAppearance;

    const FakeRenderRequests = struct {
        footer_requests: usize = 0,

        fn request(self: *FakeRenderRequests, reason: anytype) void {
            _ = reason;
            self.footer_requests += 1;
        }
    };

    const FakeShell = struct {
        render_requests: FakeRenderRequests = .{},
    };

    const FakeInputRuntime = struct {
        input_appearance: InputAppearance = .tint,
    };

    alloc: std.mem.Allocator,
    input_runtime: FakeInputRuntime = .{},
    shell: FakeShell = .{},
    transcript: std.ArrayList(u8) = .empty,
    last_tone: ?types.NoticeTone = null,
    persist_calls: usize = 0,
    persisted_appearance: []const u8 = "",
    persisted_runtime_changed: bool = false,

    fn deinit(self: *InputAppearanceCommandFakeApp) void {
        self.transcript.deinit(self.alloc);
    }

    noinline fn writeDomainNotice(self: *InputAppearanceCommandFakeApp, notice: types.SemanticNotice, _: bool) !void {
        self.last_tone = notice.tone;
        try self.transcript.appendSlice(self.alloc, notice.body);
    }

    fn persistInputAppearance(self: *InputAppearanceCommandFakeApp, appearance: []const u8, runtime_changed: bool) !void {
        self.persist_calls += 1;
        self.persisted_runtime_changed = runtime_changed;
        self.persisted_appearance = appearance;
    }
};

const MaxxingCommandFakeApp = struct {
    const FakeRenderRequests = struct {
        full_requests: usize = 0,

        fn request(self: *FakeRenderRequests, reason: anytype) void {
            _ = reason;
            self.full_requests += 1;
        }
    };

    const FakeShell = struct {
        maxxing_mode: presentation_mode.MaxxingMode = presentation_mode.MaxxingMode.default,
        render_requests: FakeRenderRequests = .{},
    };

    const FakeInputRuntime = struct {
        input_appearance: input_appearance.InputAppearance = .default,
    };

    alloc: std.mem.Allocator,
    input_runtime: FakeInputRuntime = .{},
    shell: FakeShell = .{},
    transcript: std.ArrayList(u8) = .empty,
    last_tone: ?types.NoticeTone = null,
    persisted_mode: []const u8 = "",
    persisted_runtime_changed: bool = false,

    fn deinit(self: *MaxxingCommandFakeApp) void {
        self.transcript.deinit(self.alloc);
    }

    noinline fn writeDomainNotice(self: *MaxxingCommandFakeApp, notice: types.SemanticNotice, _: bool) !void {
        self.last_tone = notice.tone;
        try self.transcript.appendSlice(self.alloc, notice.body);
    }

    fn persistMaxxingMode(self: *MaxxingCommandFakeApp, mode: []const u8, runtime_changed: bool) !void {
        self.persisted_mode = mode;
        self.persisted_runtime_changed = runtime_changed;
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

    fn reloadSkills(self: *SkillsInstallReplayApp) !void {
        self.reload_count += 1;
    }

    noinline fn writeDomainNotice(self: *SkillsInstallReplayApp, notice: types.SemanticNotice, _: bool) !void {
        self.write_count += 1;
        self.last_tone = notice.tone;
        _ = try self.shell.appendSemanticNotice(self.alloc, notice);
    }
};

const ModelCatalogCommandFakeApp = struct {
    alloc: std.mem.Allocator,
    model_cache: model_cache_runtime.Runtime,
    skills: skill_runtime.Runtime = .{},
    shell: transcript_runtime.TranscriptRuntime = .{},
    ensure_count: usize = 0,

    fn init(alloc: std.mem.Allocator) !ModelCatalogCommandFakeApp {
        return ModelCatalogCommandFakeApp{
            .alloc = alloc,
            .model_cache = model_cache_runtime.Runtime.init(alloc, "/v1/models"),
        };
    }

    fn deinit(self: *ModelCatalogCommandFakeApp) void {
        self.model_cache.deinit();
        self.shell.deinit(self.alloc);
    }

    fn ensureModelCache(self: *ModelCatalogCommandFakeApp) void {
        self.ensure_count += 1;
    }
};

const ChangeCommandFakeApp = struct {
    alloc: std.mem.Allocator,
    change_tracker: change_tracker_mod.ChangeTracker = .{},
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
};

fn runInputAppearanceCommandForTest(app: *InputAppearanceCommandFakeApp, rest: []const u8) !void {
    try handleInputAppearanceCommand(app, rest);
}

fn runMaxxingCommandForTest(app: *MaxxingCommandFakeApp, rest: []const u8) !void {
    try handleMaxxingCommand(app, rest);
}

test "appearance command parses grouped values and compatibility shorthand" {
    try std.testing.expectEqual(
        settings_catalog.Change{ .setting = .input_appearance, .value = "lines" },
        parseAppearanceChange("input lines").?,
    );
    try std.testing.expectEqual(
        settings_catalog.Change{ .setting = .maxxing_mode, .value = "legacy" },
        parseAppearanceChange("presentation normal").?,
    );
    try std.testing.expectEqual(
        settings_catalog.Change{ .setting = .input_appearance, .value = "tint" },
        parseAppearanceChange(" tint ").?,
    );
    try std.testing.expectEqual(
        settings_catalog.Change{ .setting = .maxxing_mode, .value = "minimal" },
        parseAppearanceChange("minimal").?,
    );
    try std.testing.expect(parseAppearanceChange("input minimal") == null);
    try std.testing.expect(parseAppearanceChange("presentation tint") == null);
    try std.testing.expect(parseAppearanceChange("input lines extra") == null);
}

fn writeTempSkillFile(tmp: *std.testing.TmpDir, sub_path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(sub_path)) |parent| {
        try tmp.dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try tmp.dir.createFile(io_mod.getIo(), sub_path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

test "trace notice distinguishes Markdown file outcomes without a feedback CTA" {
    const report_path = "/tmp/trace.md";
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
            .expected = "Clipboard copy failed. Trace saved at /tmp/trace.md. Review and redact it before sharing.",
        },
        .{
            .disposition = .{ .saved = report_path },
            .expected = "Trace saved at /tmp/trace.md. Review and redact it before sharing.",
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

test "trace report file uses private randomized markdown path" {
    const alloc = std.testing.allocator;
    const path = try writeTraceReportFile(alloc, "hello\n");
    defer alloc.free(path);
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, path) catch {};

    try std.testing.expect(std.mem.find(u8, path, "fx-trace-") != null);
    try std.testing.expect(std.mem.endsWith(u8, path, ".md"));

    var file = try std.Io.Dir.openFileAbsolute(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    const stat = try file.stat(std.testing.io);
    try std.testing.expectEqual(@as(u64, 6), stat.size);
    if (@import("builtin").os.tag != .windows) {
        try std.testing.expectEqual(@as(std.posix.mode_t, 0), stat.permissions.toMode() & 0o077);
    }
}

test "trace auth summary preserves missing and loaded status text" {
    const alloc = std.testing.allocator;
    var app = struct { auth: auth_runtime.Runtime = .{} }{};
    defer app.auth.deinit(alloc);

    var missing: std.Io.Writer.Allocating = .init(alloc);
    defer missing.deinit();
    try writeAuthStateSummary(&missing.writer, &app);
    try std.testing.expectEqualStrings(
        "auth: source=missing refreshable=false gateway_team=unknown\n",
        missing.written(),
    );

    var credential = credentials.Credential{
        .token = try alloc.dupe(u8, "token"),
        .source = .fx_login,
    };
    defer credential.deinit(alloc);
    _ = app.auth.adoptCredential(alloc, &credential);
    var loaded: std.Io.Writer.Allocating = .init(alloc);
    defer loaded.deinit();
    try writeAuthStateSummary(&loaded.writer, &app);
    try std.testing.expectEqualStrings(
        "auth: source=fx login refreshable=true gateway_team=unset\n",
        loaded.written(),
    );
}

test "trace tool calls print errors first and mask obvious secrets" {
    const alloc = std.testing.allocator;
    diagnostics.resetForTest();
    defer diagnostics.resetForTest();

    var ok: diagnostics.ToolCallMetric = .{ .started_at_ms = 1000, .duration_ms = 7, .ok = true };
    ok.setName("read_file");
    ok.setArgs("{\"path\":\"README.md\"}");
    ok.setResult("read ok");
    diagnostics.recordToolCall(ok);

    var failed: diagnostics.ToolCallMetric = .{ .started_at_ms = 2000, .duration_ms = 9, .ok = false, .subagent_id = 3 };
    failed.setName("run_command");
    failed.setArgs("{\"command\":\"AI_GATEWAY_API_KEY=abcdefghijklmnop zig build\"}");
    failed.setResult("failed with PASSWORD=abcdefghijklmnop");
    diagnostics.recordToolCall(failed);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeToolCallsSummary(&out.writer, alloc);
    const text = out.written();

    const error_pos = std.mem.find(u8, text, "name=run_command") orelse return error.TestExpectedEqual;
    const success_pos = std.mem.find(u8, text, "name=read_file") orelse return error.TestExpectedEqual;
    try std.testing.expect(error_pos < success_pos);
    try std.testing.expect(std.mem.find(u8, text, "source=subagent#3") != null);
    try std.testing.expect(std.mem.find(u8, text, "abcdefghijklmnop") == null);
    try std.testing.expect(std.mem.find(u8, text, "AI_GATEWAY_API_KEY=[redacted]") != null);
    try std.testing.expect(std.mem.find(u8, text, "PASSWORD=[redacted]") != null);
}

test "trace successful tool calls use compact result previews" {
    const alloc = std.testing.allocator;
    diagnostics.resetForTest();
    defer diagnostics.resetForTest();

    var call: diagnostics.ToolCallMetric = .{ .started_at_ms = 3000, .duration_ms = 1, .ok = true };
    call.setName("read_file");
    call.setArgs("{\"path\":\"README.md\"}");
    call.setResult("<path>README.md</path>\n<content>\n# fx\n\nlong body line\n</content>");
    diagnostics.recordToolCall(call);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeToolCallsSummary(&out.writer, alloc);
    const text = out.written();

    try std.testing.expect(std.mem.find(u8, text, "recent successes (compact):") != null);
    try std.testing.expect(std.mem.find(u8, text, "result_preview: # fx") != null);
    try std.testing.expect(std.mem.find(u8, text, "<path>README.md</path>") == null);
    try std.testing.expect(std.mem.find(u8, text, "long body line") == null);
}

test "trace omits web_fetch URL and result bodies from tool-call diagnostics" {
    const alloc = std.testing.allocator;
    diagnostics.resetForTest();
    defer diagnostics.resetForTest();

    var call: diagnostics.ToolCallMetric = .{ .started_at_ms = 4000, .duration_ms = 3, .ok = true };
    call.setName("web_fetch");
    call.setArgs("{\"url\":\"https://example.com/docs\"}");
    call.setResult("<content>\nFETCHED_PAGE_SECRET_RAW\nEXTRACTED_RESULT_SECRET\n</content>");
    diagnostics.recordToolCall(call);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeToolCallsSummary(&out.writer, alloc);
    const text = out.written();

    try std.testing.expect(std.mem.find(u8, text, "name=web_fetch") != null);
    try std.testing.expect(std.mem.find(u8, text, "source=parent") != null);
    try std.testing.expect(std.mem.find(u8, text, "PROMPT_BODY_SECRET") == null);
    try std.testing.expect(std.mem.find(u8, text, "FETCHED_PAGE_SECRET_RAW") == null);
    try std.testing.expect(std.mem.find(u8, text, "EXTRACTED_RESULT_SECRET") == null);
    try std.testing.expect(std.mem.find(u8, text, "args:") == null);
    try std.testing.expect(std.mem.find(u8, text, "result_preview:") == null);
}

test "trace renders web search request count without content" {
    const alloc = std.testing.allocator;
    diagnostics.resetForTest();
    defer diagnostics.resetForTest();

    var call: diagnostics.NetworkCall = .{
        .kind = .web_search,
        .started_at_ms = 3000,
        .duration_ms = 11,
        .status = 200,
        .input_tokens = 12,
        .output_tokens = 34,
        .is_web_search = true,
        .web_search_requests = 2,
    };
    call.setModel("gateway/native-search-worker");
    call.setTerminalStopReason("max_tokens");
    diagnostics.recordNetworkCall(call);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeNetworkCallsSummary(&out.writer);
    const text = out.written();

    try std.testing.expect(std.mem.find(u8, text, "web_search_requests=2") != null);
    try std.testing.expect(std.mem.find(u8, text, "stop_reason=max_tokens") != null);
    try std.testing.expect(std.mem.find(u8, text, "raw result content") == null);
}

test "trace renders gateway schema diagnostics without raw payload content" {
    const alloc = std.testing.allocator;
    diagnostics.resetForTest();
    defer diagnostics.resetForTest();

    var call: diagnostics.NetworkCall = .{
        .started_at_ms = 5000,
        .duration_ms = 17,
        .status = 400,
        .response_bytes = 91,
        .turn_id = 12,
        .step_id = 34,
    };
    call.setModel("zai/glm-5.2-fast");
    call.setGatewaySchemaDiagnostic("path=prompt.0.content expected=string received=array");
    call.setGatewayRequestShape("bytes=123 prompt_count=1 prompt.0 role=system content=array tools=array tools_count=0 toolChoice=auto");
    diagnostics.recordNetworkCall(call);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeNetworkCallsSummary(&out.writer);
    const text = out.written();

    try std.testing.expect(std.mem.find(u8, text, "status=400") != null);
    try std.testing.expect(std.mem.find(u8, text, "turn=12") != null);
    try std.testing.expect(std.mem.find(u8, text, "step=34") != null);
    try std.testing.expect(std.mem.find(u8, text, "gateway_schema=\"path=prompt.0.content expected=string received=array\"") != null);
    try std.testing.expect(std.mem.find(u8, text, "request_shape=\"bytes=123 prompt_count=1 prompt.0 role=system content=array") != null);
    try std.testing.expect(std.mem.find(u8, text, "SECRET_RAW_PROMPT") == null);
}

test "app_commands exposes active handler API surface" {
    const HandlerSurface = Handlers(SurfaceOnlyApp);

    const route_info = @typeInfo(@TypeOf(HandlerSurface.route)).@"fn";
    try std.testing.expectEqual(@as(usize, 2), route_info.params.len);
    try std.testing.expect(route_info.params[0].type.? == *SurfaceOnlyApp);
    try std.testing.expect(route_info.params[1].type.? == []const u8);

    const handlers_info = @typeInfo(@TypeOf(HandlerSurface.commandHandlers)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), handlers_info.params.len);
    try std.testing.expect(handlers_info.params[0].type.? == *SurfaceOnlyApp);
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
        .session = .{ .reply = "reply\nwith exact bytes" },
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

    app.session.reply = "reply";
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

test "app_commands renders transactional status for explicit MCP reload" {
    var app = McpCommandFakeApp{ .alloc = std.testing.allocator };
    defer app.deinit();

    try Handlers(McpCommandFakeApp).commandHandleMcp(@ptrCast(&app), "reload");

    try std.testing.expectEqual(@as(usize, 0), app.list_count);
    try std.testing.expectEqual(@as(usize, 1), app.reload_count);
    try std.testing.expectEqual(@as(usize, 1), app.notice_count);
    try std.testing.expectEqualStrings("mcp", app.last_topic.?);
    try std.testing.expectEqual(types.NoticeTone.neutral, app.last_tone.?);
    try std.testing.expectEqualStrings(
        "MCP reconnection started. Your existing MCP servers will stay active while the new configuration is checked.",
        app.notice_body.items,
    );
    try Handlers(McpCommandFakeApp).collectMcpReloadFacts(&app);
    try std.testing.expectEqual(@as(usize, 2), app.notice_count);
    try std.testing.expect(std.mem.endsWith(
        u8,
        app.notice_body.items,
        "MCP configuration reloaded. No servers are configured.",
    ));
}

test "app_commands explains healthy and degraded MCP reloads without internal state" {
    const cases = [_]struct {
        behavior: McpCommandFakeApp.ReloadBehavior,
        tone: types.NoticeTone,
        expected: []const u8,
    }{
        .{
            .behavior = .published_healthy,
            .tone = .neutral,
            .expected = "MCP configuration reloaded successfully.",
        },
        .{
            .behavior = .published_degraded,
            .tone = .warning,
            .expected = "MCP configuration reloaded, but 2 servers are unavailable: 'alpha', 'beta'. Run /mcp list for details.",
        },
    };

    for (cases) |case| {
        var app = McpCommandFakeApp{
            .alloc = std.testing.allocator,
            .reload_behavior = case.behavior,
        };
        defer app.deinit();

        try Handlers(McpCommandFakeApp).commandHandleMcp(@ptrCast(&app), "reload");
        try Handlers(McpCommandFakeApp).collectMcpReloadFacts(&app);

        try std.testing.expectEqual(case.tone, app.last_tone.?);
        try std.testing.expect(std.mem.endsWith(u8, app.notice_body.items, case.expected));
        try std.testing.expect(std.mem.find(u8, app.notice_body.items, "runtime 42") == null);
        try std.testing.expect(std.mem.find(u8, app.notice_body.items, "degraded") == null);
    }
}

test "app_commands preserves command display after implicit MCP reload" {
    var app = McpCommandFakeApp{ .alloc = std.testing.allocator };
    defer app.deinit();

    try Handlers(McpCommandFakeApp).commandHandleMcp(@ptrCast(&app), "auth fixture --open");

    try std.testing.expectEqual(@as(usize, 1), app.reload_count);
    try std.testing.expectEqual(@as(usize, 1), app.notice_count);
    try std.testing.expectEqualStrings("mcp", app.last_topic.?);
    try std.testing.expectEqual(types.NoticeTone.neutral, app.last_tone.?);
    try std.testing.expectEqualStrings(
        "Authenticated MCP server 'fixture'.\nMCP reconnection started. Your existing MCP servers will stay active while the new configuration is checked.",
        app.notice_body.items,
    );
    try Handlers(McpCommandFakeApp).collectMcpReloadFacts(&app);
    try std.testing.expectEqual(@as(usize, 2), app.notice_count);
}

test "app_commands warns when implicit MCP reload cannot replace the active servers" {
    for ([_]McpCommandFakeApp.ReloadBehavior{ .retained, .completion_failed, .begin_failed }) |behavior| {
        var app = McpCommandFakeApp{
            .alloc = std.testing.allocator,
            .reload_behavior = behavior,
        };
        defer app.deinit();

        try Handlers(McpCommandFakeApp).commandHandleMcp(@ptrCast(&app), "auth fixture --open");

        try std.testing.expectEqual(@as(usize, 1), app.reload_count);
        try std.testing.expectEqual(@as(usize, 1), app.notice_count);
        try std.testing.expectEqualStrings("mcp", app.last_topic.?);
        if (behavior != .begin_failed) {
            try std.testing.expectEqual(types.NoticeTone.neutral, app.last_tone.?);
            try Handlers(McpCommandFakeApp).collectMcpReloadFacts(&app);
            try std.testing.expectEqual(@as(usize, 2), app.notice_count);
            try std.testing.expectEqual(types.NoticeTone.warning, app.last_tone.?);
            try std.testing.expect(std.mem.find(
                u8,
                app.notice_body.items,
                "MCP configuration could not be reloaded. Your existing MCP servers are still active.",
            ) != null);
        } else {
            try std.testing.expectEqual(types.NoticeTone.warning, app.last_tone.?);
            try std.testing.expect(std.mem.find(
                u8,
                app.notice_body.items,
                "MCP configuration could not be reloaded. Your existing MCP servers are still active.",
            ) != null);
        }
        try std.testing.expect(std.mem.find(u8, app.notice_body.items, "TestReloadFailed") == null);
        try std.testing.expect(std.mem.find(u8, app.notice_body.items, "/mcp list") != null);
    }
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

    const args = try std.fmt.allocPrint(alloc, "install {s}", .{pack_dir});
    defer alloc.free(args);
    try Handlers(SkillsInstallReplayApp).commandHandleSkills(@ptrCast(&app), args);

    try std.testing.expectEqual(@as(usize, 2), app.shell.entries.items.len);
    try std.testing.expectEqual(@as(usize, 2), app.write_count);
    try std.testing.expectEqual(@as(usize, 2), app.reload_count);
    try std.testing.expectEqual(types.NoticeTone.neutral, app.last_tone.?);
    try std.testing.expect(app.shell.entries.items[0] == .semantic_notice);
    try std.testing.expect(app.shell.entries.items[1] == .semantic_notice);
    try std.testing.expectEqualStrings("skills", app.shell.entries.items[0].semantic_notice.topic);
    const installing_body = try std.fmt.allocPrint(alloc, "Installing from {s}...", .{pack_dir});
    defer alloc.free(installing_body);
    try std.testing.expectEqualStrings(installing_body, app.shell.entries.items[0].semantic_notice.body);
    try std.testing.expectEqualStrings(
        "Installed: root-skill\nInstalled: nested-skill",
        app.shell.entries.items[1].semantic_notice.body,
    );

    const rendered = try transcript_runtime.renderEntriesToBytes(alloc, app.shell.entries.items, 80, .{});
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.startsWith(u8, rendered, "● Skills: Installing from "));
    try std.testing.expect(std.mem.find(u8, rendered, "\n\n● Skills: Installed: root-skill") != null);
    try std.testing.expect(std.mem.endsWith(u8, rendered, "  Installed: nested-skill"));
}

test "models command opens the catalog without writing transcript output" {
    const alloc = std.testing.allocator;
    var app = try ModelCatalogCommandFakeApp.init(alloc);
    defer app.deinit();
    app.skills.openMenu();

    try Handlers(ModelCatalogCommandFakeApp).commandShowModels(@ptrCast(&app));

    try std.testing.expectEqual(@as(usize, 1), app.ensure_count);
    try std.testing.expect(!app.skills.menu.active);
    try std.testing.expect(app.model_cache.menu.active);
    try std.testing.expectEqual(model_cache_runtime.ModelMenuLoadState.loading, app.model_cache.menu.load_state);
    try std.testing.expectEqual(@as(usize, 0), app.shell.entries.items.len);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
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
    try std.testing.expectEqual(@as(usize, 0), app.shell.entries.items.len);
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

    const rendered = try transcript_runtime.renderEntriesToBytes(alloc, app.shell.entries.items, 80, .{});
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "Visible skills (") == null);
}

test "skills list reports a bounded discovery warning with an escaped candidate path" {
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
    try std.testing.expectEqual(@as(usize, 1), app.shell.entries.items.len);
    try std.testing.expect(app.shell.entries.items[0] == .semantic_notice);
    const notice = app.shell.entries.items[0].semantic_notice;
    try std.testing.expectEqualStrings("skills", notice.topic);
    try std.testing.expectEqual(types.NoticeTone.warning, notice.tone);
    try std.testing.expect(std.mem.find(u8, notice.body, "skill discovery warning:") != null);
    try std.testing.expect(std.mem.find(u8, notice.body, "hostile&#x0a;path/body-sentinel") != null);
    try std.testing.expect(std.mem.find(u8, notice.body, "metadata is invalid (missing_name)") != null);
    const rendered = try transcript_runtime.renderEntriesToBytes(alloc, app.shell.entries.items, 80, .{});
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "● Skills: skill discovery warning:") != null);
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

    const rendered = try transcript_runtime.renderEntriesToBytes(alloc, app.shell.entries.items, 80, .{});
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "Removed skill 'review'.") != null);
    try std.testing.expectEqual(@as(usize, 2), app.reload_count);
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
    const rendered = try transcript_runtime.renderEntriesToBytes(alloc, app.shell.entries.items, 80, .{});
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "Skill 'missing' not found.") != null);
}

test "input appearance command without arguments reports session-local options" {
    var app = InputAppearanceCommandFakeApp{ .alloc = std.testing.allocator };
    defer app.deinit();

    try runInputAppearanceCommandForTest(&app, "");

    try std.testing.expect(std.mem.find(u8, app.transcript.items, "current: tint") != null);
    try std.testing.expect(std.mem.find(u8, app.transcript.items, "available: lines, tint") != null);
    try std.testing.expect(std.mem.find(u8, app.transcript.items, "/input lines") != null);
    try std.testing.expect(std.mem.find(u8, app.transcript.items, "/input tint") != null);
    try std.testing.expectEqual(types.NoticeTone.neutral, app.last_tone.?);
    try std.testing.expectEqual(@as(usize, 0), app.shell.render_requests.footer_requests);
}

test "input appearance command switches mode and requests footer redraw" {
    var app = InputAppearanceCommandFakeApp{ .alloc = std.testing.allocator };
    defer app.deinit();

    try runInputAppearanceCommandForTest(&app, "lines");

    try std.testing.expectEqual(InputAppearanceCommandFakeApp.InputAppearance.lines, app.input_runtime.input_appearance);
    try std.testing.expectEqualStrings("lines", app.persisted_appearance);
    try std.testing.expect(app.persisted_runtime_changed);
    try std.testing.expect(std.mem.find(u8, app.transcript.items, "switched to lines") != null);
    try std.testing.expectEqual(types.NoticeTone.neutral, app.last_tone.?);
    try std.testing.expectEqual(@as(usize, 1), app.shell.render_requests.footer_requests);

    app.transcript.clearRetainingCapacity();
    try runInputAppearanceCommandForTest(&app, "lines");

    try std.testing.expectEqual(InputAppearanceCommandFakeApp.InputAppearance.lines, app.input_runtime.input_appearance);
    try std.testing.expectEqual(@as(usize, 2), app.persist_calls);
    try std.testing.expectEqualStrings("lines", app.persisted_appearance);
    try std.testing.expect(!app.persisted_runtime_changed);
    try std.testing.expect(std.mem.find(u8, app.transcript.items, "already in lines") != null);
    try std.testing.expectEqual(@as(usize, 1), app.shell.render_requests.footer_requests);
}

test "input appearance command rejects unknown mode without changing state" {
    var app = InputAppearanceCommandFakeApp{ .alloc = std.testing.allocator, .input_runtime = .{ .input_appearance = .tint } };
    defer app.deinit();

    try runInputAppearanceCommandForTest(&app, "card");

    try std.testing.expectEqual(InputAppearanceCommandFakeApp.InputAppearance.tint, app.input_runtime.input_appearance);
    try std.testing.expect(std.mem.find(u8, app.transcript.items, "Use: lines, tint") != null);
    try std.testing.expectEqual(types.NoticeTone.@"error", app.last_tone.?);
    try std.testing.expectEqual(@as(usize, 0), app.shell.render_requests.footer_requests);
}

test "maxxing command switches presentation without changing input appearance" {
    var app = MaxxingCommandFakeApp{ .alloc = std.testing.allocator, .shell = .{ .maxxing_mode = .legacy } };
    defer app.deinit();
    app.input_runtime.input_appearance = .lines;

    try runMaxxingCommandForTest(&app, "minimal");

    try std.testing.expectEqual(presentation_mode.MaxxingMode.minimal, app.shell.maxxing_mode);
    try std.testing.expectEqual(input_appearance.InputAppearance.lines, app.input_runtime.input_appearance);
    try std.testing.expectEqualStrings("minimal", app.persisted_mode);
    try std.testing.expect(app.shell.render_requests.full_requests > 0);
}

test "maxxing command reports options and rejects unknown modes" {
    var app = MaxxingCommandFakeApp{ .alloc = std.testing.allocator };
    defer app.deinit();

    try runMaxxingCommandForTest(&app, "");
    try std.testing.expect(std.mem.find(u8, app.transcript.items, "current: minimal") != null);
    try std.testing.expect(std.mem.find(u8, app.transcript.items, "/maxxing minimal") != null);
    try std.testing.expect(std.mem.find(u8, app.transcript.items, "/maxxing legacy") != null);

    app.transcript.clearRetainingCapacity();
    try runMaxxingCommandForTest(&app, "bare");
    try std.testing.expectEqual(presentation_mode.MaxxingMode.minimal, app.shell.maxxing_mode);
    try std.testing.expectEqual(types.NoticeTone.@"error", app.last_tone.?);
    try std.testing.expect(std.mem.find(u8, app.transcript.items, "Use: minimal, legacy") != null);
}

test "maxxing command switches to legacy with stored input appearance intact" {
    var app = MaxxingCommandFakeApp{ .alloc = std.testing.allocator };
    defer app.deinit();
    app.input_runtime.input_appearance = .lines;

    try runMaxxingCommandForTest(&app, "legacy");

    try std.testing.expectEqual(presentation_mode.MaxxingMode.legacy, app.shell.maxxing_mode);
    try std.testing.expectEqual(input_appearance.InputAppearance.lines, app.input_runtime.input_appearance);
    try std.testing.expectEqualStrings("legacy", app.persisted_mode);
}

test "maxxing command accepts normal as a hidden legacy alias" {
    var app = MaxxingCommandFakeApp{ .alloc = std.testing.allocator };
    defer app.deinit();

    try runMaxxingCommandForTest(&app, "normal");

    try std.testing.expectEqual(presentation_mode.MaxxingMode.legacy, app.shell.maxxing_mode);
    try std.testing.expectEqualStrings("legacy", app.persisted_mode);
}
