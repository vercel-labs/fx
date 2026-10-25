//! The session backend: what runs the agent behind the terminal frontend.
//!
//! `App.init` chooses one backend and the App keeps it for its lifetime:
//!
//! - `in_process` runs the agent worker, its persistence, and its
//!   credentials in this process. The libfx terminal (wasm) build uses it,
//!   and so do the in-process App tests.
//! - `detached` drives a session the background supervisor owns
//!   (`remote_backend.zig`); the native binary always uses it.
//!
//! The contract is the set of frontend actions a backend owns. Each is
//! dispatched on the kind exactly once, either at the composition root in
//! `main.zig` or by `Ops` below for the generic runtimes:
//!
//!   operation                         in_process                  detached
//!   submit a prompt                   worker queue                supervisor `prompt`
//!   admit a prompt before its card    always                      focused node takes it
//!   message an idle subagent          (not offered)               supervisor `prompt` with its node
//!   admit a prompt / credentials      local credential checks     daemon owns credentials
//!   cancel the turn                   worker interrupt            supervisor `cancel`
//!   answer a permission request       local approval flow         supervisor `permission`
//!   run a slash command               local command handlers      `remote_backend` handlers
//!   new or reset session              session runtime             supervisor `create`
//!   reload permission rules           (rules are live)            host `permissions_reload`
//!   select a model, cycle mode        session commands            supervisor `model`, `mode`
//!   deliver events                    worker event tick           supervisor poll
//!   browse sessions and subagents     (not offered)               session browser
//!
//! The detached backend addresses every operation to an explicit session
//! node (`remote_backend.Node`): the composer's focus for prompts, cancels,
//! and `.node` commands, and the root for `.tree` and `.root` commands (see
//! `command_specs.CommandScope`). It has no implicit "main" session.
//!
//! What the frontend shows of its session (model, mode, workspace) comes
//! from `Ops.view`, so renderers and pickers never read either backend's
//! state directly.
const std = @import("std");
const types = @import("../shared/types.zig");
const session_commands = @import("../session/session_commands.zig");
const app_permission_runtime = @import("app_permission_runtime.zig");
const remote_backend = @import("remote_backend.zig");

pub const Kind = enum { in_process, detached };

/// A model chosen in a picker, with the options the picker offered.
pub const ModelSelection = struct {
    model: []const u8,
    effort: types.ReasoningEffort,
    fast_mode: bool = false,
    ultrafast_mode: bool = false,
};

/// What the frontend shows of the session it drives.
pub const View = struct {
    /// The session's model when the backend reports it; null means the
    /// frontend's own model selection is the session's.
    model: ?[]const u8 = null,
    /// The directory the session works in.
    workspace_root: []const u8 = "",
    /// A terminal-safe label for an attached workspace, when it has one.
    workspace_label: ?[]const u8 = null,
    /// The composer shows a subagent below the root; Left returns to its
    /// parent.
    child_transcript: bool = false,
    /// The path to the focused node, `root › a › b`; empty at the root.
    breadcrumb: []const u8 = "",
    /// Left and Right open the session and subagent browser.
    session_browser: bool = false,
    /// Model pickers can offer effort and speed stages, because this
    /// process knows the selected model's capabilities.
    model_options: bool = true,
    /// Settings can change this process's model, effort, and speed.
    session_controls: bool = true,
};

/// The backend operations generic runtimes call. An App without a `backend`
/// field (most test fakes) is in-process.
pub fn Ops(comptime App: type) type {
    return struct {
        const has_backend = @hasField(App, "backend");

        pub fn kind(app: *const App) Kind {
            if (comptime !has_backend) return .in_process;
            return app.backend;
        }

        /// The agent, its worker, persistence, and credentials live here.
        pub fn agentInProcess(app: *const App) bool {
            return kind(app) == .in_process;
        }

        pub fn view(app: *const App) View {
            if (comptime has_backend) if (app.backend == .detached) {
                const remote = &app.remote;
                return .{
                    .model = if (remote.model.len > 0) remote.model else null,
                    .workspace_root = remote.cwd,
                    .workspace_label = remote.workspace_label,
                    .child_transcript = remote.child_id.len > 0,
                    .breadcrumb = remote.breadcrumb,
                    .session_browser = true,
                    .model_options = false,
                    .session_controls = false,
                };
            };
            return .{ .workspace_root = if (comptime @hasField(App, "workspace_root")) app.workspace_root else "" };
        }

        /// Whether the backend takes the composer's prompt and pending images
        /// now, asked before the prompt's card is shown. A backend that
        /// refuses has told the person why.
        pub fn admitPrompt(app: *App) !bool {
            if (comptime !has_backend or !@hasField(App, "remote")) return true;
            if (app.backend == .in_process) return true;
            const Detached = remote_backend.Runtime(App);
            return try Detached.admit(app, Detached.focus(app), app.pending_images.items) != null;
        }

        pub fn selectModel(app: *App, selection: ModelSelection) !void {
            if (comptime has_backend) if (app.backend == .detached) {
                const Detached = remote_backend.Runtime(App);
                return Detached.setModel(app, Detached.focus(app), selection.model);
            };
            try session_commands.Commands(App).selectModelFromPicker(
                app,
                selection.model,
                selection.effort,
                selection.fast_mode,
                selection.ultrafast_mode,
            );
        }

        /// Moves to the next permission mode: ask, auto, full access.
        pub fn cyclePermissionMode(app: *App) !void {
            if (comptime has_backend) if (app.backend == .detached) {
                const Detached = remote_backend.Runtime(App);
                return Detached.setPermissionMode(app, Detached.focus(app), app.remote.permission_mode.next());
            };
            try app_permission_runtime.Runtime(App).toggleMode(app);
        }
    };
}

test "an App without a backend field is in-process with its own workspace" {
    const Fake = struct { workspace_root: []const u8 = "/work" };
    const fake: Fake = .{};
    try std.testing.expect(Ops(Fake).agentInProcess(&fake));
    const shown = Ops(Fake).view(&fake);
    try std.testing.expectEqualStrings("/work", shown.workspace_root);
    try std.testing.expect(shown.model == null and !shown.session_browser and shown.model_options);
}
