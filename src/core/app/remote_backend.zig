//! The detached session backend: the frontend half of a session the
//! supervisor runs. It turns what the person does into supervisor requests.
//! `remote_view.zig` applies what comes back, and `app_remote_runtime.zig`
//! carries both over the supervisor connection. See `session_backend.zig`
//! for the contract this implements.
//!
//! Slash commands go through the shared router with this backend's handler
//! table: commands the session owns become requests, and frontend commands
//! (help, settings, images, sound) keep their in-process handlers. Whether a
//! command may run in a read-only child transcript comes from its spec's
//! `child_transcript` field.
const std = @import("std");
const types = @import("../shared/types.zig");
const client_protocol = @import("../supervisor/protocol.zig");
const host_commands = @import("../../acp/commands.zig");
const command_router = @import("../slash_commands/command_router.zig");
const browser_mod = @import("../input/session_browser.zig");
const app_commands = @import("app_commands.zig");
const remote_runtime = @import("app_remote_runtime.zig");
const remote_view = @import("remote_view.zig");

pub fn Runtime(comptime App: type) type {
    return struct {
        const View = remote_view.Runtime(App);
        const Transport = remote_runtime.Runtime(App);
        const notice = View.notice;

        // Session lifecycle and turns.

        pub fn submit(app: *App, prompt: []const u8, images: []const types.ImageAttachment) !bool {
            if (images.len > 0) {
                try notice(app, "images", "Image forwarding is not supported by the detached frontend yet. Remove the image attachments before sending; no prompt was submitted.");
                return false;
            }
            if (app.remote.link == .stopped) {
                try app.writeDomainNotice(.{ .topic = "session", .tone = .warning, .body = "Supervisor stopped. Relaunch proto-fx to reconnect." }, true);
                return false;
            }
            if (app.remote.current_id.len == 0) {
                try app.writeDomainNotice(.{ .topic = "session", .tone = .warning, .body = "The session is still connecting. Please send again when it is ready." }, true);
                return false;
            }
            if (app.remote.child_id.len > 0) {
                try notice(app, "subagent", "This is a child transcript. Return to its parent to send a message.");
                return false;
            }
            // `remote_view` skips the host's echo of a prompt shown here.
            const text = try app.alloc.dupe(u8, prompt);
            errdefer app.alloc.free(text);
            if (app.remote.submitted_text.items.len >= 32) app.alloc.free(app.remote.submitted_text.orderedRemove(0));
            try app.remote.submitted_text.append(app.alloc, text);
            errdefer _ = app.remote.submitted_text.pop();
            try app.remote.enqueue(.submit, .{ .prompt = .{ .session_id = app.remote.current_id, .text = prompt } });
            app.stream.active = true;
            app.shell.render_requests.request(.footer);
            return true;
        }

        pub fn cancel(app: *App) !void {
            if (app.remote.current_id.len == 0) return;
            try app.remote.enqueue(.cancel, .{ .cancel = .{ .session_id = app.remote.current_id } });
        }

        /// Answers the pending permission prompt. False when none is pending.
        pub fn resolvePermission(app: *App, decision: types.ToolPermissionDecision) !bool {
            const id = app.remote.pending_permission_id orelse return false;
            const option: client_protocol.PermissionOption = switch (decision) {
                .once => .allow_once,
                .always => .allow_always,
                .deny, .policy_denied, .permission_required => .reject_once,
            };
            try app.remote.enqueue(.rpc, .{ .permission = .{ .session_id = app.remote.current_id, .request_id = id, .option = option } });
            app.remote.permission_response_queued = true;
            app.approval_prompt.clear(app.alloc);
            app.shell.render_requests.request(.modal);
            return true;
        }

        /// Starts a fresh session; the supervisor keeps the old one running.
        pub fn newSession(app: *App) !void {
            app.clearPendingSubmissionForSessionTransition();
            if (app.remote.current_id.len > 0) app.alloc.free(app.remote.current_id);
            app.remote.current_id = &.{};
            leaveChild(app);
            app.remote.generation +%= 1;
            app.remote.sequence = 0;
            app.input_runtime.session_browser.close();
            View.resetTranscript(app);
            try app.remote.enqueue(.startup, .{ .create = .{ .cwd = app.workspace_root } });
        }

        pub fn switchSession(app: *App, id: []const u8) !void {
            const owned = try app.alloc.dupe(u8, id);
            app.clearPendingSubmissionForSessionTransition();
            if (app.remote.current_id.len > 0) app.alloc.free(app.remote.current_id);
            app.remote.current_id = owned;
            leaveChild(app);
            app.remote.generation +%= 1;
            app.remote.sequence = 0;
            View.resetTranscript(app);
            try app.remote.enqueue(.attach, .{ .attach = .{ .session_id = app.remote.current_id, .after_sequence = 0 } });
        }

        fn leaveChild(app: *App) void {
            if (app.remote.child_id.len > 0) app.alloc.free(app.remote.child_id);
            app.remote.child_id = &.{};
            for (app.remote.child_ancestors.items) |ancestor| app.alloc.free(ancestor);
            app.remote.child_ancestors.clearRetainingCapacity();
            app.remote.clearChildTracking(app.alloc);
        }

        /// Shows the read-only transcript of node `id` under the attached
        /// root. `parent_id` is its parent: the node shown now when the
        /// person descends, or an ancestor when Left walks back up.
        pub fn viewChild(app: *App, id: []const u8, parent_id: []const u8) !void {
            const remote = &app.remote;
            const owned = try app.alloc.dupe(u8, id);
            errdefer app.alloc.free(owned);
            if (remote.child_id.len > 0 and std.mem.eql(u8, parent_id, remote.child_id)) {
                // Descending: the node shown now becomes an ancestor.
                try remote.child_ancestors.append(app.alloc, remote.child_id);
            } else if (remote.child_id.len > 0) {
                app.alloc.free(remote.child_id);
            }
            remote.child_id = owned;
            remote.generation +%= 1;
            remote.clearChildTracking(app.alloc);
            View.resetTranscriptContents(app);
            try Transport.refreshChild(app);
        }

        /// Replaces the host's live permission rules with what this process
        /// just wrote to the profile or project settings.
        pub fn reloadPermissions(app: *App) !void {
            if (app.remote.current_id.len == 0) return;
            try runHostCommand(app, "reloading its permissions", .permissions_reload);
        }

        pub fn setModel(app: *App, model: []const u8) !void {
            const id = try sessionFor(app, "changing its configuration") orelse return;
            try app.remote.enqueue(.config, .{ .model = .{ .session_id = id, .model = model } });
        }

        pub fn setPermissionMode(app: *App, mode: types.PermissionMode) !void {
            const id = try sessionFor(app, "changing its configuration") orelse return;
            try app.remote.enqueue(.config, .{ .mode = .{ .session_id = id, .mode = mode.configId() } });
        }

        /// The attached session's id, or null after telling the person to
        /// open one before `purpose`.
        fn sessionFor(app: *App, purpose: []const u8) !?[]const u8 {
            if (app.remote.current_id.len > 0) return app.remote.current_id;
            const body = try app.alloc.print("Open a session before {s}.", .{purpose});
            defer app.alloc.free(body);
            try notice(app, "session", body);
            return null;
        }

        fn runHostCommand(app: *App, purpose: []const u8, command: host_commands.Command) !void {
            const id = try sessionFor(app, purpose) orelse return;
            const fields = host_commands.requestFields(command);
            try app.remote.enqueue(.command, .{ .command = .{
                .session_id = id,
                .name = fields.command,
                .action = fields.action,
                .path = fields.path,
                .line = fields.line,
            } });
        }

        // The session and subagent browser.

        pub fn openSessionBrowser(app: *App, scope: browser_mod.Scope) !void {
            app.input_runtime.session_browser.open(scope);
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            try Transport.refreshBrowser(app);
            app.shell.render_requests.request(.footer);
        }

        pub fn activateBrowserSelection(app: *App) !void {
            const browser = &app.input_runtime.session_browser;
            const row = browser.selectedRow() orelse return;
            const id = try app.alloc.dupe(u8, row.id);
            defer app.alloc.free(id);
            const parent_id = try app.alloc.dupe(u8, row.parent_id);
            defer app.alloc.free(parent_id);
            const scope = browser.scope;
            browser.close();
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            switch (scope) {
                .subagents => try viewChild(app, id, parent_id),
                .sessions => try switchSession(app, id),
            }
            app.shell.render_requests.request(.footer);
        }

        /// Closes the browser; from a child transcript, shows its parent,
        /// which is the root once no ancestor is left.
        pub fn browserBack(app: *App) !void {
            app.input_runtime.session_browser.close();
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            const remote = &app.remote;
            if (remote.child_id.len > 0) {
                if (remote.child_ancestors.pop()) |parent| {
                    defer app.alloc.free(parent);
                    const grandparent = remote.child_ancestors.last() orelse remote.current_id;
                    try viewChild(app, parent, grandparent);
                } else {
                    try switchSession(app, remote.current_id);
                }
            }
            app.shell.render_requests.request(.footer);
        }

        // Slash commands.

        pub fn route(app: *App, cmd: []const u8) !void {
            const registry = app.slashRegistry();
            if (app.remote.child_id.len > 0) if (command_router.match(registry, cmd)) |matched| {
                const access = matched.spec.child_transcript;
                if (!access.admits(matched.payload)) {
                    const body = try app.alloc.print("This child transcript is read-only. Press Left to return to the parent before running {s}.", .{matched.spec.command});
                    defer app.alloc.free(body);
                    try notice(app, "subagent", body);
                    return;
                }
                if (access != .allowed) try notice(app, "subagent", "Showing parent session status; this child transcript is read-only.");
            };
            var handlers = app_commands.Handlers(App).commandHandlers(app);
            // `/clear` keeps the old conversation's processes, which the
            // supervisor does by keeping the whole session: a new one starts.
            handlers.clear_screen = commandNewSession;
            handlers.resume_session = commandResume;
            handlers.rename_session = commandRename;
            handlers.fork_session = commandFork;
            handlers.show_status = commandStatus;
            handlers.handle_model = commandModel;
            handlers.handle_permissions = commandPermissions;
            handlers.handle_effort = commandEffort;
            handlers.toggle_fast = commandFast;
            handlers.handle_ultrafast = commandUltrafast;
            handlers.copy_last = commandCopy;
            handlers.undo_last = commandUndo;
            handlers.compact_history = commandCompact;
            handlers.show_context = commandContext;
            handlers.handle_workspace = commandWorkspace;
            handlers.handle_shell = commandShell;
            handlers.handle_mcp = commandMcp;
            handlers.browse_subagents = commandSubagents;
            handlers.handle_heartbeat = commandHeartbeat;
            handlers.handle_kernel = commandKernel;
            handlers.login = commandGatewayAccount;
            handlers.logout = commandGatewayAccountWithArgs;
            handlers.provider = commandGatewayAccount;
            handlers.show_credits = commandGatewayAccount;
            handlers.show_usage = commandGatewayAccount;
            handlers.submit_feedback = commandGatewayAccount;
            try command_router.route(registry, &handlers, cmd);
        }

        fn appFrom(ctx: *anyopaque) *App {
            return @ptrCast(@alignCast(ctx));
        }

        fn commandNewSession(ctx: *anyopaque) !void {
            try newSession(appFrom(ctx));
        }

        fn commandResume(ctx: *anyopaque, rest: []const u8) !void {
            const app = appFrom(ctx);
            if (rest.len == 0) return openSessionBrowser(app, .sessions);
            if (std.mem.eql(u8, rest, "last")) return app.remote.enqueue(.startup_last, .{ .list = .{} });
            try switchSession(app, rest);
        }

        fn commandRename(ctx: *anyopaque, rest: []const u8) !void {
            const app = appFrom(ctx);
            if (rest.len == 0) return notice(app, "", "usage: /rename <title>");
            const id = try sessionFor(app, "renaming it") orelse return;
            try app.remote.enqueue(.rename, .{ .rename = .{ .session_id = id, .name = rest } });
        }

        fn commandFork(ctx: *anyopaque) !void {
            try notice(appFrom(ctx), "session", "Detached session fork is not available yet. Use /new to create a session, or /resume to switch.");
        }

        fn commandGatewayAccount(ctx: *anyopaque) !void {
            try notice(appFrom(ctx), "setup", "proto-fx uses your OpenAI-compatible endpoint configuration. Gateway account login, billing, teams, and self-upgrade are disabled. Run proto-fx --help for setup.");
        }

        fn commandGatewayAccountWithArgs(ctx: *anyopaque, _: []const u8) !void {
            try commandGatewayAccount(ctx);
        }

        fn commandStatus(ctx: *anyopaque) !void {
            const app = appFrom(ctx);
            const remote = &app.remote;
            const body = try app.alloc.print("session: {s}\nworkspace: {s}\nmodel: {s}\nmode: {s}\nview: {s}", .{
                remote.current_id,
                remote.cwd,
                remote.model,
                remote.permission_mode.configId(),
                if (remote.child_id.len > 0) remote.child_id else "root",
            });
            defer app.alloc.free(body);
            try notice(app, "session", body);
        }

        fn commandModel(ctx: *anyopaque, query: []const u8) !void {
            const app = appFrom(ctx);
            if (query.len == 0) return notice(app, "model", app.remote.model);
            try setModel(app, query);
        }

        fn commandPermissions(ctx: *anyopaque, rest: []const u8) !void {
            const app = appFrom(ctx);
            if (rest.len == 0) return notice(app, "permissions", app.remote.permission_mode.configId());
            const mode = types.PermissionMode.parse(rest) orelse return notice(app, "", "usage: /permissions ask|auto|full-access");
            try setPermissionMode(app, mode);
        }

        /// The host owns each option's accepted values and its rejection
        /// text, so effort passes through and speed only normalizes on/off.
        fn commandEffort(ctx: *anyopaque, rest: []const u8) !void {
            const app = appFrom(ctx);
            if (rest.len == 0) return notice(app, "", "usage: /effort auto|minimal|low|medium|high");
            try setOption(app, "effort", rest);
        }

        fn commandFast(ctx: *anyopaque, rest: []const u8) !void {
            try setToggleOption(appFrom(ctx), "fast", rest, "usage: /fast on|off");
        }

        fn commandUltrafast(ctx: *anyopaque, rest: []const u8) !void {
            try setToggleOption(appFrom(ctx), "ultrafast", rest, "usage: /ultrafast on|off");
        }

        fn setToggleOption(app: *App, option: []const u8, rest: []const u8, usage: []const u8) !void {
            const enabled = app_commands.parseToggle(rest) orelse return notice(app, "", usage);
            try setOption(app, option, if (enabled) "true" else "false");
        }

        fn setOption(app: *App, option: []const u8, value: []const u8) !void {
            const id = try sessionFor(app, "changing its configuration") orelse return;
            try app.remote.enqueue(.config, .{ .option = .{ .session_id = id, .config_id = option, .value = value } });
        }

        fn commandCopy(ctx: *anyopaque) !void {
            try runHostCommand(appFrom(ctx), "copying a reply", .last_reply);
        }

        fn commandUndo(ctx: *anyopaque) !void {
            try runHostCommand(appFrom(ctx), "undoing a file operation", .undo);
        }

        fn commandCompact(ctx: *anyopaque) !void {
            const app = appFrom(ctx);
            const attached = app.remote.current_id.len > 0;
            try runHostCommand(app, "compacting it", .compact);
            if (attached) try notice(app, "session", "Compacting context...");
        }

        fn commandContext(ctx: *anyopaque) !void {
            try runHostCommand(appFrom(ctx), "checking its context", .context);
        }

        fn commandWorkspace(ctx: *anyopaque, rest: []const u8) !void {
            const app = appFrom(ctx);
            const usage = "usage: /workspace [list|add PATH|remove PATH|clear]";
            const purpose = "changing its workspace";
            if (rest.len == 0 or std.mem.eql(u8, rest, "list")) return runHostCommand(app, purpose, .{ .workspace = .list });
            if (std.mem.eql(u8, rest, "clear")) return runHostCommand(app, purpose, .{ .workspace = .clear });
            const verb_end = std.mem.findAny(u8, rest, " \t") orelse return notice(app, "", usage);
            const path = std.mem.trim(u8, rest[verb_end..], " \t");
            if (path.len == 0) return notice(app, "", usage);
            const verb = rest[0..verb_end];
            if (std.mem.eql(u8, verb, "add")) return runHostCommand(app, purpose, .{ .workspace = .{ .add = path } });
            if (std.mem.eql(u8, verb, "remove")) return runHostCommand(app, purpose, .{ .workspace = .{ .remove = path } });
            try notice(app, "", usage);
        }

        fn commandShell(ctx: *anyopaque, rest: []const u8) !void {
            const app = appFrom(ctx);
            if (!std.mem.eql(u8, rest, "reload")) return notice(app, "", "usage: /shell reload");
            try runHostCommand(app, "reloading its shell", .shell_reload);
        }

        fn commandMcp(ctx: *anyopaque, rest: []const u8) !void {
            const app = appFrom(ctx);
            try runHostCommand(app, "managing MCP servers", if (rest.len == 0) .mcp_status else .{ .mcp_verb = rest });
        }

        fn commandSubagents(ctx: *anyopaque) !void {
            try openSessionBrowser(appFrom(ctx), .subagents);
        }

        /// Heartbeats and the kernel are supervisor requests, not host
        /// commands: the supervisor schedules heartbeats across clients, and
        /// it answers kernel status even while the host runs a turn.
        fn commandHeartbeat(ctx: *anyopaque, rest: []const u8) !void {
            const app = appFrom(ctx);
            const request = parseHeartbeat(rest) orelse
                return notice(app, "", "usage: /heartbeat status|start <seconds> <prompt>|pause|resume|stop");
            const id = try sessionFor(app, "managing its background runtime") orelse return;
            try app.remote.enqueue(.heartbeat, .{ .heartbeat = .{
                .session_id = id,
                .action = request.action,
                .interval_ms = request.interval_ms,
                .prompt = request.prompt,
            } });
        }

        fn commandKernel(ctx: *anyopaque, rest: []const u8) !void {
            const app = appFrom(ctx);
            const action = parseKernelAction(rest) orelse
                return notice(app, "", "usage: /kernel status|restart|stop|prewarm|interrupt");
            const id = try sessionFor(app, "managing its background runtime") orelse return;
            try app.remote.enqueue(.kernel, .{ .kernel = .{ .session_id = id, .action = action } });
        }
    };
}

const HeartbeatCommand = struct {
    action: client_protocol.HeartbeatAction,
    interval_ms: ?u64 = null,
    prompt: ?[]const u8 = null,
};

const max_heartbeat_seconds: u64 = 365 * 24 * 60 * 60;

/// Reads `/heartbeat` arguments. Bare means status; `stop` clears it.
fn parseHeartbeat(rest: []const u8) ?HeartbeatCommand {
    const action_end = std.mem.findAny(u8, rest, " \t") orelse rest.len;
    const action = rest[0..action_end];
    const args = std.mem.trim(u8, rest[action_end..], " \t");
    if (action.len == 0) return .{ .action = .status };
    if (std.mem.eql(u8, action, "start")) {
        const seconds_end = std.mem.findAny(u8, args, " \t") orelse args.len;
        const seconds = std.fmt.parseInt(u64, args[0..seconds_end], 10) catch return null;
        const prompt = std.mem.trim(u8, args[seconds_end..], " \t");
        if (seconds == 0 or seconds > max_heartbeat_seconds or prompt.len == 0) return null;
        return .{ .action = .set, .interval_ms = seconds * 1000, .prompt = prompt };
    }
    if (args.len > 0) return null;
    if (std.mem.eql(u8, action, "stop")) return .{ .action = .clear };
    const Plain = enum { status, pause, @"resume" };
    return switch (std.meta.stringToEnum(Plain, action) orelse return null) {
        .status => .{ .action = .status },
        .pause => .{ .action = .pause },
        .@"resume" => .{ .action = .@"resume" },
    };
}

/// The `/kernel` action, or null for anything the supervisor would reject.
fn parseKernelAction(rest: []const u8) ?[]const u8 {
    if (rest.len == 0) return "status";
    const Action = enum { status, restart, stop, prewarm, interrupt };
    _ = std.meta.stringToEnum(Action, rest) orelse return null;
    return rest;
}

test "heartbeat arguments map to supervisor actions" {
    try std.testing.expectEqual(client_protocol.HeartbeatAction.status, parseHeartbeat("").?.action);
    try std.testing.expectEqual(client_protocol.HeartbeatAction.status, parseHeartbeat("status").?.action);
    try std.testing.expectEqual(client_protocol.HeartbeatAction.clear, parseHeartbeat("stop").?.action);
    try std.testing.expectEqual(client_protocol.HeartbeatAction.pause, parseHeartbeat("pause").?.action);
    try std.testing.expectEqual(client_protocol.HeartbeatAction.@"resume", parseHeartbeat("resume").?.action);
    const start = parseHeartbeat("start 90  check the build").?;
    try std.testing.expectEqual(client_protocol.HeartbeatAction.set, start.action);
    try std.testing.expectEqual(@as(?u64, 90_000), start.interval_ms);
    try std.testing.expectEqualStrings("check the build", start.prompt.?);
    try std.testing.expect(parseHeartbeat("start 0 hi") == null);
    try std.testing.expect(parseHeartbeat("start 60") == null);
    try std.testing.expect(parseHeartbeat("start soon hi") == null);
    try std.testing.expect(parseHeartbeat("pause now") == null);
    try std.testing.expect(parseHeartbeat("set") == null);
}

test "kernel arguments accept only the supervisor's actions" {
    try std.testing.expectEqualStrings("status", parseKernelAction("").?);
    try std.testing.expectEqualStrings("restart", parseKernelAction("restart").?);
    try std.testing.expect(parseKernelAction("restart now") == null);
    try std.testing.expect(parseKernelAction("reboot") == null);
}

test "child transcript access comes from the slash specs" {
    const registry = @import("../../builtins/commands.zig").slash_registry;
    const Case = struct { cmd: []const u8, admitted: bool };
    const cases = [_]Case{
        .{ .cmd = "/kernel", .admitted = true },
        .{ .cmd = "/kernel status", .admitted = true },
        .{ .cmd = "/kernel restart", .admitted = false },
        .{ .cmd = "/heartbeat stop", .admitted = false },
        .{ .cmd = "/model", .admitted = true },
        .{ .cmd = "/model status", .admitted = false },
        .{ .cmd = "/permissions auto", .admitted = false },
        .{ .cmd = "/compact", .admitted = false },
        .{ .cmd = "/workspace", .admitted = false },
        .{ .cmd = "/status", .admitted = true },
        .{ .cmd = "/new", .admitted = true },
    };
    for (cases) |case| {
        const matched = command_router.match(registry, case.cmd) orelse return error.TestExpectedCommand;
        try std.testing.expectEqual(case.admitted, matched.spec.child_transcript.admits(matched.payload));
    }
}
