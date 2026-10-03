//! The live view in the TUI. Ctrl+T on main opens a picker of the children;
//! choosing one shows its screen at full size, and every key goes straight to
//! it until Ctrl+T returns to main. The view returns to main by itself only
//! when its child exits. A prompt of main's own waits for the user, named on
//! the status line, so no key meant for the child lands on it.
//!
//! Rules: `child_agents/view_core.zig`. Painting: `ui/child_view_screen.zig`.
const std = @import("std");
const child_agents = @import("../child_agents/runtime.zig");
const labels = @import("../child_agents/labels.zig");
const view_core = @import("../child_agents/view_core.zig");
const engine = @import("../terminal/engine.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const host_target = @import("../hosts/target.zig");
const app_lifecycle = @import("app_lifecycle.zig");
const shell_runtime = @import("../../ui/shell_runtime.zig");
const child_view_screen = @import("../../ui/child_view_screen.zig");

/// The row under a child's screen that names it.
const status_rows = 1;
/// How often the picker repaints, so children's states stay current.
const picker_repaint_ms = 250;
const main_notice = "main needs you";

/// What the status line of a child's view tells the user is waiting.
const Notice = struct {
    /// Main shows a prompt of its own.
    main: bool = false,
    /// Other children wait on a prompt.
    others: usize = 0,
};

/// The view's state; one per TUI.
pub const State = struct {
    view: view_core.View(child_agents.Handle) = .{},
    /// The viewed child's screen as last painted, to paint only changes.
    painted: ?engine.Grid = null,
    painted_version: ?u64 = null,
    name_buf: [64]u8 = undefined,
    name_len: usize = 0,
    /// What the painted status line says needs the user.
    noticed: Notice = .{},
    picker_rows: usize = 0,
    picker_painted_ms: i64 = 0,
    /// The last picker frame, so an unchanged one is not written again.
    picker_hash: ?u64 = null,
    /// Main's terminal size when the picker opened, to tell on leaving
    /// whether main's screen needs repairing.
    open_cols: u16 = 0,
    open_rows: u16 = 0,

    pub fn deinit(self: *State) void {
        self.forgetPainted();
    }

    fn forgetPainted(self: *State) void {
        if (self.painted) |*grid| grid.deinit();
        self.painted = null;
        self.painted_version = null;
    }
};

/// The picker or a child's view is on screen.
pub fn active(app: anytype) bool {
    const App = @typeInfo(@TypeOf(app)).pointer.child;
    if (comptime !@hasField(App, "child_view")) return false;
    return app.child_view.view.mode != .main;
}

pub fn Runtime(comptime App: type) type {
    return struct {
        /// Ctrl+T on main. Does nothing without children support, while main
        /// asks the user something, or while another screen, such as the
        /// full transcript, holds the alternate screen.
        pub fn open(app: *App) !void {
            // The wasm builds have no terminals for children.
            if (comptime host_target.is_wasm or !@hasField(App, "child_view")) return;
            if (child_agents.ofApp(app) == null) return;
            if (app.terminal.alternate_screen_owner != .none) return;
            if (!app.child_view.view.open(mainAsks(app))) return;
            app.child_view.picker_hash = null;
            app.child_view.open_cols = app.shell.layout.cols;
            app.child_view.open_rows = app.shell.layout.rows;
            try app_lifecycle.enterChildViewScreen(&app.terminal, &app.shell, &app.metrics);
            try paintPicker(app, true);
        }

        /// Takes every byte meant for fx while the picker or a view is open.
        /// Returns false on main.
        pub fn handleByte(app: *App, byte: u8) !bool {
            if (comptime host_target.is_wasm) return false;
            if (!active(app)) return false;
            const view = &app.child_view.view;
            var buf: view_core.Matcher.Buffer = undefined;
            try apply(app, view.matcher.feed(view.keys(), byte, io_mod.milliTimestamp(), &buf));
            return true;
        }

        /// Runs every loop, after main's worker: keeps the children at the
        /// terminal's size, ends a waiting key, leaves when the rules say
        /// so, and paints what changed.
        pub fn tick(app: *App) !void {
            if (comptime host_target.is_wasm) return;
            const children = child_agents.ofApp(app) orelse return;
            const layout = app.shell.layout;
            if (layout.rows > status_rows) children.resize(layout.cols, layout.rows - status_rows);
            if (!active(app)) return;

            const state = &app.child_view;
            var buf: view_core.Matcher.Buffer = undefined;
            const now_ms = io_mod.milliTimestamp();
            try apply(app, state.view.matcher.expire(state.view.keys(), now_ms, &buf));
            switch (state.view.mode) {
                .main => {},
                .picker => if (now_ms - state.picker_painted_ms >= picker_repaint_ms) try paintPicker(app, false),
                .view => try paintChild(app, children),
            }
        }

        fn apply(app: *App, result: view_core.Matcher.Result) !void {
            const state = &app.child_view;
            if (result.pass.len > 0 and state.view.mode == .view) {
                // Keys the child cannot take are dropped. A child that is gone
                // is left on the next tick.
                child_agents.ofApp(app).?.keys(state.view.viewed.?, result.pass) catch |err| {
                    debug_trace.logf("child_view", "keys dropped bytes={d} err={s}", .{ result.pass.len, @errorName(err) });
                };
            }
            const key = result.key orelse return;
            switch (state.view.mode) {
                .main => {},
                .view => if (key == .ctrl_t) try leave(app),
                .picker => switch (key) {
                    .up, .down => {
                        state.view.move(key, state.picker_rows);
                        try paintPicker(app, true);
                    },
                    .enter => try chooseSelected(app),
                    .escape, .ctrl_t => try leave(app),
                },
            }
        }

        fn chooseSelected(app: *App) !void {
            const children = child_agents.ofApp(app).?;
            const state = &app.child_view;
            const statuses = try children.list(app.alloc);
            defer child_agents.freeStatuses(app.alloc, statuses);
            if (state.view.selected >= statuses.len) return;
            const status = statuses[state.view.selected];
            // An exited child stays listed until stopped, but has no screen.
            if (status.exit != null) return;
            state.view.choose(status.handle orelse return);
            state.noticed = .{};
            state.name_len = @min(status.name.len, state.name_buf.len);
            @memcpy(state.name_buf[0..state.name_len], status.name[0..state.name_len]);
            state.forgetPainted();
            try paintChild(app, children);
        }

        /// Back to main: release the screen and repaint main whole.
        fn leave(app: *App) !void {
            const state = &app.child_view;
            state.view.leave();
            state.forgetPainted();
            try app_lifecycle.leaveChildViewScreen(&app.terminal, &app.shell, &app.metrics);
            // After a resize a viewport replay can drop rows the terminal
            // reflowed, so main is repaired the way the full transcript's
            // close repairs it.
            const shell = &app.shell;
            const resized = shell.layout.cols != state.open_cols or shell.layout.rows != state.open_rows or
                shell.terminal_reset_pending or shell.resize_history_row_delta != null;
            if (resized) {
                shell.repaintRestoredPrimaryTranscriptAfterResize();
            } else {
                try shell_runtime.requestRedraw(shell, &app.metrics, .replay_viewport);
            }
        }

        fn paintChild(app: *App, children: *child_agents.Runtime) !void {
            const state = &app.child_view;
            // A change in what needs the user repaints the status line: a
            // fresh copy matches what is painted, so only that line is written.
            const notice: Notice = .{ .main = mainAsks(app), .others = children.blockedOthers(state.view.viewed.?) };
            const after = if (std.meta.eql(notice, state.noticed)) state.painted_version else null;
            var gone = false;
            const screen = children.screen(app.alloc, state.view.viewed.?, after) catch |err| switch (err) {
                error.Gone => blk: {
                    gone = true;
                    break :blk null;
                },
                error.OutOfMemory => return err,
            };
            if (state.view.mustLeave(gone)) return leave(app);
            var next = screen orelse return;
            errdefer next.grid.deinit();
            state.noticed = notice;

            var status: std.Io.Writer.Allocating = .init(app.alloc);
            defer status.deinit();
            try status.writer.print(" {s} \u{00b7} ", .{state.name_buf[0..state.name_len]});
            if (notice.main) try status.writer.writeAll(main_notice ++ " \u{00b7} ");
            switch (notice.others) {
                0 => {},
                1 => try status.writer.writeAll("1 other child needs you \u{00b7} "),
                else => try status.writer.print("{d} other children need you \u{00b7} ", .{notice.others}),
            }
            try status.writer.writeAll("Ctrl+T returns to main");
            var out: std.Io.Writer.Allocating = .init(app.alloc);
            defer out.deinit();
            try child_view_screen.paintChild(app.alloc, &out.writer, if (state.painted) |*grid| grid else null, &next.grid, status.written());
            try app_lifecycle.writeLifecycleTerminalBytes(&app.shell, &app.metrics, out.written());
            state.forgetPainted();
            state.painted = next.grid;
            state.painted_version = next.version;
        }

        /// Paints the picker when it changed, or always when `force`.
        fn paintPicker(app: *App, force: bool) !void {
            const children = child_agents.ofApp(app).?;
            const state = &app.child_view;
            const statuses = try children.list(app.alloc);
            defer child_agents.freeStatuses(app.alloc, statuses);
            var rows: [child_agents.max_children]child_view_screen.PickerRow = undefined;
            for (statuses, 0..) |status, index| rows[index] = .{ .name = status.name, .state = stateLabel(status) };
            state.picker_rows = statuses.len;
            if (state.view.selected >= statuses.len) state.view.selected = statuses.len -| 1;

            var out: std.Io.Writer.Allocating = .init(app.alloc);
            defer out.deinit();
            try child_view_screen.paintPicker(&out.writer, app.shell.layout.cols, app.shell.layout.rows, rows[0..statuses.len], state.view.selected, if (mainAsks(app)) main_notice else null);
            state.picker_painted_ms = io_mod.milliTimestamp();
            const hash = std.hash.Wyhash.hash(0, out.written());
            if (!force and state.picker_hash == hash) return;
            try app_lifecycle.writeLifecycleTerminalBytes(&app.shell, &app.metrics, out.written());
            state.picker_hash = hash;
        }

        /// Main has a prompt of its own waiting. While the view is open main
        /// takes no child's prompt, so any open prompt is main's.
        fn mainAsks(app: *App) bool {
            return app.approval_prompt.isActive() or app.question_prompt.isActive();
        }
    };
}

fn stateLabel(status: child_agents.Status) []const u8 {
    if (status.exit != null) return "exited";
    return switch (status.state) {
        .starting => "starting",
        .idle => "idle",
        .working => "working",
        .blocked => switch (status.blocked_reason orelse .permission) {
            .permission => "needs permission",
            .question => "has a question",
            .recovery => "needs a decision",
        },
    };
}
