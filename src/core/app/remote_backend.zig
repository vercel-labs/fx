//! The detached session backend: the frontend half of a session the
//! supervisor runs. It turns what the person does into supervisor requests.
//! `remote_view.zig` applies what comes back, and `app_remote_runtime.zig`
//! carries both over the supervisor connection. See `session_backend.zig`
//! for the contract this implements.
//!
//! Every operation that acts on a session names its target `Node`; nothing
//! here defaults to the root. The composer's focus (the root, or the
//! subagent it shows) picks the target for prompts and `.node` commands,
//! and a command's `scope` sends `.tree` and `.root` commands to the root.
//! A prompt, a cancel, a host command, or `/kernel` on a node travels with
//! the node's id, and the host decides what it can do there (D91).
//! `wireSession` refuses the session settings the supervisor changes only
//! on the root.
//!
//! Slash commands go through the shared router with this backend's handler
//! table: commands the session owns become requests, and frontend commands
//! (help, settings, images, sound) keep their in-process handlers.
const std = @import("std");
const types = @import("../shared/types.zig");
const client_protocol = @import("../supervisor/protocol.zig");
const host_commands = @import("../../acp/commands.zig");
const command_router = @import("../slash_commands/command_router.zig");
const command_specs = @import("../slash_commands/command_specs.zig");
const browser_mod = @import("../input/session_browser.zig");
const app_commands = @import("app_commands.zig");
const app_auth_runtime = @import("app_auth_runtime.zig");
const provider_registry = @import("../config/provider_registry.zig");
const remote_runtime = @import("app_remote_runtime.zig");
const remote_view = @import("remote_view.zig");
const transcript_runtime = @import("../../ui/transcript/runtime.zig");

/// A session the supervisor runs: the attached root, or a node below it.
pub const Node = struct {
    id: []const u8,
    /// The root session the node belongs to; `id` itself for the root.
    root_id: []const u8,

    pub fn isRoot(self: Node) bool {
        return std.mem.eql(u8, self.id, self.root_id);
    }
};

pub fn Runtime(comptime App: type) type {
    return struct {
        const View = remote_view.Runtime(App);
        const Transport = remote_runtime.Runtime(App);
        const notice = View.notice;

        /// The session the composer shows.
        pub fn focus(app: *const App) Node {
            return .{ .id = app.remote.viewedNodeId(), .root_id = app.remote.current_id };
        }

        /// The root of the focused tree.
        pub fn root(app: *const App) Node {
            return .{ .id = app.remote.current_id, .root_id = app.remote.current_id };
        }

        /// The root session to address on the wire for `target`, or null
        /// after telling the person why not.
        fn wireRoot(app: *App, target: Node, purpose: []const u8) !?[]const u8 {
            if (target.root_id.len > 0) return target.root_id;
            const body = try app.alloc.print("Open a session before {s}.", .{purpose});
            defer app.alloc.free(body);
            try notice(app, "session", body);
            return null;
        }

        /// The node id to send beside the root's, null for the root itself.
        fn wireNode(target: Node) ?[]const u8 {
            return if (target.isRoot()) null else target.id;
        }

        /// The session to address on the wire for `target`, or null after
        /// telling the person why not. The supervisor changes a session's
        /// settings on its root only, so a subagent target is refused here.
        fn wireSession(app: *App, target: Node, purpose: []const u8) !?[]const u8 {
            _ = try wireRoot(app, target, purpose) orelse return null;
            if (!target.isRoot()) {
                const body = try app.alloc.print("This is not yet supported in a subagent session: {s}. Press Left to return to the parent.", .{purpose});
                defer app.alloc.free(body);
                try notice(app, "subagent", body);
                return null;
            }
            return target.id;
        }

        /// The target a command of `kind` acts on: its spec's scope, applied
        /// to the composer's focus.
        fn commandTarget(app: *App, kind: command_specs.SlashKind) Node {
            return switch (scopeOf(app, kind)) {
                .node => focus(app),
                .tree, .root => root(app),
            };
        }

        fn scopeOf(app: *App, kind: command_specs.SlashKind) command_specs.CommandScope {
            for (app.slashRegistry().commands) |spec| if (spec.kind == kind) return spec.scope;
            return .node;
        }

        // Session lifecycle and turns.

        /// The session `target` takes a prompt in, or null after telling the
        /// person why it cannot. The frontend asks before it shows the
        /// prompt's card, so a refused prompt shows only the refusal.
        pub fn admit(app: *App, target: Node, images: []const types.ImageAttachment) !?[]const u8 {
            if (images.len > 0) {
                try notice(app, "images", "Image forwarding is not supported by the detached frontend yet. Remove the image attachments before sending; no prompt was submitted.");
                return null;
            }
            if (app.remote.link == .stopped) {
                try app.writeDomainNotice(.{ .topic = "session", .tone = .warning, .body = "Supervisor stopped. Relaunch proto-fx to reconnect." }, true);
                return null;
            }
            if (app.remote.history_load.active and app.remote.history_load.initial) {
                try app.writeDomainNotice(.{ .topic = "session", .tone = .neutral, .body = "The saved transcript is still loading. Please send again when it is ready." }, true);
                return null;
            }
            if (target.root_id.len == 0) {
                try app.writeDomainNotice(.{ .topic = "session", .tone = .warning, .body = "The session is still connecting. Please send again when it is ready." }, true);
                return null;
            }
            // A subagent takes a message only between its own turns; the
            // host checks the rest and names any refusal.
            if (!target.isRoot() and app.remote.viewedChildRunning()) {
                try notice(app, "subagent", host_commands.NodeRefusal.node_running.text());
                return null;
            }
            return target.root_id;
        }

        pub fn submit(app: *App, target: Node, prompt: []const u8, images: []const types.ImageAttachment) !bool {
            const session_id = try admit(app, target, images) orelse return false;
            // `remote_view` skips the host's echo of a prompt shown here.
            const text = try app.alloc.dupe(u8, prompt);
            errdefer app.alloc.free(text);
            if (app.remote.submitted_text.items.len >= 32) app.alloc.free(app.remote.submitted_text.orderedRemove(0));
            try app.remote.submitted_text.append(app.alloc, text);
            errdefer _ = app.remote.submitted_text.pop();
            try app.remote.enqueue(.submit, .{ .prompt = .{ .session_id = session_id, .node_id = wireNode(target), .text = prompt } });
            app.stream.active = true;
            app.shell.render_requests.request(.footer);
            return true;
        }

        pub fn cancel(app: *App, target: Node) !void {
            if (target.root_id.len == 0) return;
            const session_id = try wireRoot(app, target, "cancelling its turn") orelse return;
            try app.remote.enqueue(.cancel, .{ .cancel = .{ .session_id = session_id, .node_id = wireNode(target) } });
        }

        /// Answers the pending permission prompt, in the session that asked.
        /// False when none is pending.
        pub fn resolvePermission(app: *App, decision: types.ToolPermissionDecision) !bool {
            const id = app.remote.pending_permission_id orelse return false;
            const session_id = app.remote.pending_permission_session;
            if (session_id.len == 0) return false;
            const option: client_protocol.PermissionOption = switch (decision) {
                .once => .allow_once,
                .always => .allow_always,
                .deny, .policy_denied, .permission_required => .reject_once,
            };
            try app.remote.enqueue(.rpc, .{ .permission = .{ .session_id = session_id, .request_id = id, .option = option } });
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
            if (comptime @hasField(@TypeOf(app.shell), "max_retained_transcript_bytes")) {
                app.shell.max_retained_transcript_bytes = transcript_runtime.default_max_retained_transcript_bytes;
            }
            View.resetTranscript(app);
            try app.remote.enqueue(.startup, .{ .create = .{ .cwd = app.workspace_root } });
        }

        pub fn switchSession(app: *App, id: []const u8) !void {
            try focusSession(app, id);
            try app.remote.enqueue(.attach, .{ .attach = .{ .session_id = app.remote.current_id, .after_sequence = 0 } });
        }

        /// Fetches the saved-history page before the loaded window. The full
        /// transcript asks for it when PgUp reaches the top.
        pub fn loadOlderHistory(app: *App) !void {
            const remote = &app.remote;
            if (remote.child_id.len > 0) {
                // A node's transcript arrives whole and shows its newest work.
                return notice(app, "session", "Older entries page at the root session only.");
            }
            if (remote.link != .ready or !remote.history_loaded or
                remote.history_load.active or remote.older_page != null or remote.current_id.len == 0) return;
            const window = &remote.history_window;
            window.dropPruned(app.alloc, oldestEntryFrom(app, window.first_entry_ids.items));
            if (!window.has_older) return;
            if (window.bytes >= remote_runtime.history_window_max_bytes) {
                return notice(app, "session", "The transcript holds as much saved history as it can; older entries stay in the saved session.");
            }
            try remote.requestHistoryPage(false);
            try Transport.showLoadingRow(app);
        }

        /// The oldest transcript entry at or after the window's first, which
        /// retention has not pruned. Entries before the window, such as the
        /// welcome, are not history.
        fn oldestEntryFrom(app: *App, first_entry_ids: []const u32) ?u32 {
            const floor = if (first_entry_ids.len > 0) first_entry_ids[0] else return null;
            var oldest: ?u32 = null;
            for (app.shell.entries.items) |entry| {
                const id = entry.id();
                if (id >= floor and id < (oldest orelse std.math.maxInt(u32))) oldest = id;
            }
            return oldest;
        }

        /// Opens saved session `id`, which the supervisor may not hold yet,
        /// such as a fork (D98), and focuses it.
        pub fn openSavedSession(app: *App, id: []const u8) !void {
            try focusSession(app, id);
            try app.remote.enqueue(.startup, .{ .create = .{ .cwd = app.workspace_root, .@"resume" = app.remote.current_id } });
        }

        fn focusSession(app: *App, id: []const u8) !void {
            const owned = try app.alloc.dupe(u8, id);
            app.clearPendingSubmissionForSessionTransition();
            if (app.remote.current_id.len > 0) app.alloc.free(app.remote.current_id);
            app.remote.current_id = owned;
            leaveChild(app);
            app.remote.generation +%= 1;
            app.remote.sequence = 0;
            if (comptime @hasField(@TypeOf(app.shell), "max_retained_transcript_bytes")) {
                app.shell.max_retained_transcript_bytes = transcript_runtime.default_max_retained_transcript_bytes;
            }
            View.resetTranscript(app);
        }

        fn leaveChild(app: *App) void {
            const remote = &app.remote;
            if (remote.child_id.len > 0) app.alloc.free(remote.child_id);
            remote.child_id = &.{};
            if (remote.child_name.len > 0) app.alloc.free(remote.child_name);
            remote.child_name = &.{};
            for (remote.child_ancestors.items) |hop| hop.deinit(app.alloc);
            remote.child_ancestors.clearRetainingCapacity();
            remote.clearChildTracking(app.alloc);
            remote.rebuildBreadcrumb(app.alloc) catch {};
        }

        /// Focuses node `id`, labelled `name`, under the attached root.
        /// `parent_id` is its parent: the node shown now when the person
        /// descends, or an ancestor when Left walks back up.
        pub fn viewChild(app: *App, id: []const u8, parent_id: []const u8, name: []const u8) !void {
            const remote = &app.remote;
            const owned = try app.alloc.dupe(u8, id);
            errdefer app.alloc.free(owned);
            // An unnamed node reads "worker" in the breadcrumb, never its id.
            const owned_name = try app.alloc.dupe(u8, if (name.len > 0) name else "worker");
            errdefer app.alloc.free(owned_name);
            if (remote.child_id.len > 0 and std.mem.eql(u8, parent_id, remote.child_id)) {
                // Descending: the node shown now becomes an ancestor.
                try remote.child_ancestors.append(app.alloc, .{ .id = remote.child_id, .name = remote.child_name });
            } else if (remote.child_id.len > 0) {
                app.alloc.free(remote.child_id);
                app.alloc.free(remote.child_name);
            }
            remote.child_id = owned;
            remote.child_name = owned_name;
            try remote.rebuildBreadcrumb(app.alloc);
            remote.generation +%= 1;
            remote.clearChildTracking(app.alloc);
            View.resetTranscriptContents(app);
            try Transport.refreshChild(app);
        }

        /// Replaces the host's live permission rules with what this process
        /// just wrote to the profile or project settings.
        /// Permission rules are the tree's shared config, so they reload on
        /// the root host.
        pub fn reloadPermissions(app: *App) !void {
            if (app.remote.current_id.len == 0) return;
            try runHostCommand(app, root(app), "reloading its permissions", .permissions_reload);
        }

        pub fn setModel(app: *App, target: Node, model: []const u8) !void {
            // A subagent keeps its model on its own node, for its next turns.
            if (!target.isRoot()) return runHostCommand(app, target, "changing its model", .{ .model = model });
            const id = try wireSession(app, target, "changing the model") orelse return;
            try app.remote.enqueue(.config, .{ .model = .{ .session_id = id, .model = model } });
        }

        pub fn setPermissionMode(app: *App, target: Node, mode: types.PermissionMode) !void {
            const id = try wireSession(app, target, "changing the permission mode") orelse return;
            try app.remote.enqueue(.config, .{ .mode = .{ .session_id = id, .mode = mode.configId() } });
        }

        /// The host runs the command on `target`, or answers with the reason
        /// it cannot run it on a subagent.
        fn runHostCommand(app: *App, target: Node, purpose: []const u8, command: host_commands.Command) !void {
            const id = try wireRoot(app, target, purpose) orelse return;
            const fields = host_commands.requestFields(command);
            try app.remote.enqueue(.command, .{ .command = .{
                .session_id = id,
                .node_id = wireNode(target),
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

        /// Confirms the browser's pending delete. The supervisor closes the
        /// session and removes its saved history; its list watch pushes the
        /// new rows.
        pub fn deleteBrowserSelection(app: *App) !void {
            const browser = &app.input_runtime.session_browser;
            const id = browser.pendingDeleteId() orelse return;
            const owned = try app.alloc.dupe(u8, id);
            defer app.alloc.free(owned);
            browser.cancelDelete();
            try app.remote.enqueue(.delete, .{ .delete = .{ .session_id = owned } });
            app.shell.render_requests.request(.footer);
        }

        pub fn activateBrowserSelection(app: *App) !void {
            const browser = &app.input_runtime.session_browser;
            const row = browser.selectedRow() orelse return;
            const id = try app.alloc.dupe(u8, row.id);
            defer app.alloc.free(id);
            const parent_id = try app.alloc.dupe(u8, row.parent_id);
            defer app.alloc.free(parent_id);
            const name = try app.alloc.dupe(u8, row.title);
            defer app.alloc.free(name);
            const scope = browser.scope;
            browser.close();
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            switch (scope) {
                .subagents => try viewChild(app, id, parent_id, name),
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
                    defer parent.deinit(app.alloc);
                    const grandparent = if (remote.child_ancestors.last()) |hop| hop.id else remote.current_id;
                    try viewChild(app, parent.id, grandparent, parent.name);
                } else {
                    try switchSession(app, remote.current_id);
                }
            }
            app.shell.render_requests.request(.footer);
        }

        // Slash commands.

        pub fn route(app: *App, cmd: []const u8) !void {
            const registry = app.slashRegistry();
            if (app.remote.child_id.len > 0) if (command_router.match(registry, cmd)) |matched| switch (matched.spec.scope) {
                .node => {},
                .tree => try notice(app, "subagent", "This applies to the whole session tree."),
                .root => try notice(app, "subagent", "This runs on the root session."),
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
            handlers.login = commandLogin;
            handlers.logout = commandLogout;
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
            const id = try wireSession(app, commandTarget(app, .rename_session), "renaming it") orelse return;
            try app.remote.enqueue(.rename, .{ .rename = .{ .session_id = id, .name = rest } });
        }

        fn commandFork(ctx: *anyopaque) !void {
            const app = appFrom(ctx);
            // A subagent forks into a new root session, which the result
            // then focuses (D98).
            if (!focus(app).isRoot()) return runHostCommand(app, focus(app), "forking it", .fork);
            try notice(app, "session", "Detached session fork is not available yet. Use /new to create a session, or /resume to switch.");
        }

        fn commandGatewayAccount(ctx: *anyopaque) !void {
            try notice(appFrom(ctx), "setup", "proto-fx uses your OpenAI-compatible endpoint configuration. Gateway account login, billing, teams, and self-upgrade are disabled. Run proto-fx --help for setup.");
        }

        fn commandGatewayAccountWithArgs(ctx: *anyopaque, _: []const u8) !void {
            try commandGatewayAccount(ctx);
        }

        /// `/login` opens the provider picker for the built-in API providers;
        /// the key it saves is the profile's, which the host reads (D147).
        fn commandLogin(ctx: *anyopaque) !void {
            try app_auth_runtime.Runtime(App).runLoginCommand(appFrom(ctx));
        }

        fn commandLogout(ctx: *anyopaque, rest: []const u8) !void {
            const name = std.mem.trim(u8, rest, " \t\r\n");
            if (provider_registry.presetFor(name) == null) return commandGatewayAccount(ctx);
            try app_auth_runtime.Runtime(App).runLogoutCommand(appFrom(ctx), name);
        }

        /// Switches the attached root session to `provider` after a login.
        /// With no session open, as when the profile's provider had no
        /// credential at startup, it opens one and switches it once it is
        /// open (D215).
        pub fn selectProvider(app: *App, provider: []const u8) !void {
            if (root(app).root_id.len > 0) return setOption(app, root(app), "provider", provider);
            const owned = try app.alloc.dupe(u8, provider);
            if (app.remote.pending_provider) |previous| app.alloc.free(previous);
            app.remote.pending_provider = owned;
            if (!app.remote.inFlight(.startup)) {
                try app.remote.enqueue(.startup, .{ .create = .{ .cwd = app.workspace_root } });
            }
            const body = try app.alloc.print("Opening a session with {s}.", .{provider});
            defer app.alloc.free(body);
            try notice(app, "session", body);
        }

        /// Applies the provider `/login` chose before a session was open, now
        /// that one is.
        pub fn applyPendingProvider(app: *App) !void {
            const provider = app.remote.pending_provider orelse return;
            if (root(app).root_id.len == 0) return;
            app.remote.pending_provider = null;
            defer app.alloc.free(provider);
            try setOption(app, root(app), "provider", provider);
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
            const target = commandTarget(app, .model);
            if (!target.isRoot() and query.len == 0) return runHostCommand(app, target, "reading its model", .{ .model = null });
            if (query.len == 0) {
                // Only the root's model is in the attached snapshot.
                _ = try wireSession(app, target, "reading its model") orelse return;
                return notice(app, "model", app.remote.model);
            }
            try setModel(app, target, query);
        }

        fn commandPermissions(ctx: *anyopaque, rest: []const u8) !void {
            const app = appFrom(ctx);
            const target = commandTarget(app, .permissions);
            if (rest.len == 0) {
                _ = try wireSession(app, target, "reading its permission mode") orelse return;
                return notice(app, "permissions", app.remote.permission_mode.configId());
            }
            const mode = types.PermissionMode.parse(rest) orelse return notice(app, "", "usage: /permissions ask|auto|full-access");
            try setPermissionMode(app, target, mode);
        }

        /// The host owns each option's accepted values and its rejection
        /// text, so effort passes through and speed only normalizes on/off.
        fn commandEffort(ctx: *anyopaque, rest: []const u8) !void {
            const app = appFrom(ctx);
            const target = commandTarget(app, .effort);
            if (!target.isRoot()) return runHostCommand(app, target, "changing its effort", .{ .effort = if (rest.len > 0) rest else null });
            if (rest.len == 0) return notice(app, "", "usage: /effort auto|minimal|low|medium|high");
            try setOption(app, target, "effort", rest);
        }

        fn commandFast(ctx: *anyopaque, rest: []const u8) !void {
            const app = appFrom(ctx);
            try setToggleOption(app, commandTarget(app, .fast), "fast", rest, "usage: /fast on|off");
        }

        fn commandUltrafast(ctx: *anyopaque, rest: []const u8) !void {
            const app = appFrom(ctx);
            try setToggleOption(app, commandTarget(app, .ultrafast), "ultrafast", rest, "usage: /ultrafast on|off");
        }

        fn setToggleOption(app: *App, target: Node, option: []const u8, rest: []const u8, usage: []const u8) !void {
            const enabled = app_commands.parseToggle(rest) orelse return notice(app, "", usage);
            try setOption(app, target, option, if (enabled) "true" else "false");
        }

        fn setOption(app: *App, target: Node, option: []const u8, value: []const u8) !void {
            const id = try wireSession(app, target, "changing its configuration") orelse return;
            try app.remote.enqueue(.config, .{ .option = .{ .session_id = id, .config_id = option, .value = value } });
        }

        fn commandCopy(ctx: *anyopaque) !void {
            const app = appFrom(ctx);
            try runHostCommand(app, commandTarget(app, .copy), "copying a reply", .last_reply);
        }

        fn commandUndo(ctx: *anyopaque) !void {
            const app = appFrom(ctx);
            try runHostCommand(app, commandTarget(app, .undo), "undoing a file operation", .undo);
        }

        fn commandCompact(ctx: *anyopaque) !void {
            const app = appFrom(ctx);
            const target = commandTarget(app, .compact);
            _ = try wireRoot(app, target, "compacting it") orelse return;
            try runHostCommand(app, target, "compacting it", .compact);
            if (target.isRoot()) try notice(app, "session", "Compacting context...");
        }

        fn commandContext(ctx: *anyopaque) !void {
            const app = appFrom(ctx);
            try runHostCommand(app, commandTarget(app, .context), "checking its context", .context);
        }

        fn commandWorkspace(ctx: *anyopaque, rest: []const u8) !void {
            const app = appFrom(ctx);
            const target = commandTarget(app, .workspace);
            const usage = "usage: /workspace [list|add PATH|remove PATH|clear]";
            const purpose = "changing its workspace";
            if (rest.len == 0 or std.mem.eql(u8, rest, "list")) return runHostCommand(app, target, purpose, .{ .workspace = .list });
            if (std.mem.eql(u8, rest, "clear")) return runHostCommand(app, target, purpose, .{ .workspace = .clear });
            const verb_end = std.mem.findAny(u8, rest, " \t") orelse return notice(app, "", usage);
            const path = std.mem.trim(u8, rest[verb_end..], " \t");
            if (path.len == 0) return notice(app, "", usage);
            const verb = rest[0..verb_end];
            if (std.mem.eql(u8, verb, "add")) return runHostCommand(app, target, purpose, .{ .workspace = .{ .add = path } });
            if (std.mem.eql(u8, verb, "remove")) return runHostCommand(app, target, purpose, .{ .workspace = .{ .remove = path } });
            try notice(app, "", usage);
        }

        fn commandShell(ctx: *anyopaque, rest: []const u8) !void {
            const app = appFrom(ctx);
            if (!std.mem.eql(u8, rest, "reload")) return notice(app, "", "usage: /shell reload");
            try runHostCommand(app, commandTarget(app, .shell), "reloading its shell", .shell_reload);
        }

        fn commandMcp(ctx: *anyopaque, rest: []const u8) !void {
            const app = appFrom(ctx);
            try runHostCommand(app, commandTarget(app, .mcp), "managing MCP servers", if (rest.len == 0) .mcp_status else .{ .mcp_verb = rest });
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
            const id = try wireSession(app, commandTarget(app, .heartbeat), "managing its heartbeat") orelse return;
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
            const target = commandTarget(app, .kernel);
            const id = try wireRoot(app, target, "managing its kernel") orelse return;
            try app.remote.enqueue(.kernel, .{ .kernel = .{ .session_id = id, .node_id = wireNode(target), .action = action } });
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

test "command scopes send tree and root commands past the focused subagent" {
    const registry = @import("../../builtins/commands.zig").slash_registry;
    const Case = struct { cmd: []const u8, scope: command_specs.CommandScope };
    const cases = [_]Case{
        .{ .cmd = "/model", .scope = .node },
        .{ .cmd = "/undo", .scope = .node },
        .{ .cmd = "/kernel status", .scope = .node },
        .{ .cmd = "/compact", .scope = .node },
        .{ .cmd = "/workspace add /tmp", .scope = .tree },
        .{ .cmd = "/mcp", .scope = .tree },
        .{ .cmd = "/shell reload", .scope = .tree },
        .{ .cmd = "/allowlist", .scope = .tree },
        .{ .cmd = "/heartbeat stop", .scope = .root },
        .{ .cmd = "/new", .scope = .root },
        .{ .cmd = "/resume last", .scope = .root },
        .{ .cmd = "/clear", .scope = .root },
    };
    for (cases) |case| {
        const matched = command_router.match(registry, case.cmd) orelse return error.TestExpectedCommand;
        try std.testing.expectEqual(case.scope, matched.spec.scope);
    }
}

test "a node names its root explicitly" {
    const root_node: Node = .{ .id = "root", .root_id = "root" };
    const child: Node = .{ .id = "child", .root_id = "root" };
    try std.testing.expect(root_node.isRoot());
    try std.testing.expect(!child.isRoot());
}
