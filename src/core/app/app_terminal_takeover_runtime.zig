const std = @import("std");
const app_lifecycle = @import("app_lifecycle.zig");
const app_render_runtime = @import("app_render_runtime.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const contracts = @import("../terminal/contracts.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const engine = @import("../terminal/engine.zig");
const identity = @import("../terminal/identity.zig");
const io_mod = @import("../shared/io.zig");
const operation = @import("../terminal/operation.zig");
const record_tape = @import("../workspace/record_tape.zig");
const store = @import("../terminal/store.zig");
const types = @import("../shared/types.zig");
const render_request = @import("../../ui/render_request.zig");
const shell_runtime = @import("../../ui/shell_runtime.zig");
const transcript_runtime = @import("../../ui/transcript/runtime.zig");

const control_prefix: u8 = 0x1d; // Ctrl-]
const max_forwarded_input_bytes = contracts.max_write_bytes;
const screen_poll_interval_ms: i64 = 33;
const release_retry_interval_ms: i64 = 250;

const Phase = enum {
    inactive,
    acquiring,
    active,
    releasing,
};

const ReturnReason = enum {
    detach,
    exited,
    lost,
    failure,
};

const SurfaceReturnAction = enum {
    handoff_to_manager,
    enter_manager,
    render_manager,
    leave_to_inline,
    recover_inline,
    none,
};

fn surfaceReturnAction(
    manager_active: bool,
    owner: shell_runtime.AlternateScreenOwner,
    inline_recovery_pending: bool,
) SurfaceReturnAction {
    if (manager_active) return switch (owner) {
        .terminal_session => .handoff_to_manager,
        .none => .enter_manager,
        .subagent_manager => .render_manager,
        else => .none,
    };
    return switch (owner) {
        .terminal_session => .leave_to_inline,
        .none => if (inline_recovery_pending) .recover_inline else .none,
        else => .none,
    };
}

const PrefixAction = enum {
    none,
    detach,
    help,
};

const PrefixResult = struct {
    action: PrefixAction = .none,
    forwarded: [1]u8 = undefined,
    forwarded_len: u1 = 0,

    fn bytes(self: *const PrefixResult) []const u8 {
        return self.forwarded[0..self.forwarded_len];
    }
};

const PrefixParser = struct {
    pending: bool = false,
    in_paste: bool = false,
    begin_match: u3 = 0,
    end_match: u3 = 0,

    fn feed(self: *PrefixParser, byte: u8) PrefixResult {
        if (self.in_paste) {
            self.end_match = advanceDelimiter(
                self.end_match,
                byte,
                "\x1b[201~",
            );
            if (self.end_match == "\x1b[201~".len) {
                self.in_paste = false;
                self.end_match = 0;
            }
            return forward(byte);
        }

        self.begin_match = advanceDelimiter(
            self.begin_match,
            byte,
            "\x1b[200~",
        );
        if (self.begin_match == "\x1b[200~".len) {
            self.in_paste = true;
            self.begin_match = 0;
        }

        if (self.pending) {
            self.pending = false;
            return switch (byte) {
                'd', 'D' => .{ .action = .detach },
                '?' => .{ .action = .help },
                control_prefix => forward(control_prefix),
                else => forward(byte),
            };
        }
        if (byte == control_prefix) {
            self.pending = true;
            return .{};
        }
        return forward(byte);
    }
};

fn advanceDelimiter(current: u3, byte: u8, delimiter: []const u8) u3 {
    const index: usize = current;
    if (byte == delimiter[index]) return @intCast(index + 1);
    return if (byte == delimiter[0]) 1 else 0;
}

fn forward(byte: u8) PrefixResult {
    return .{ .forwarded = .{byte}, .forwarded_len = 1 };
}

pub const Controller = struct {
    phase: Phase = .inactive,
    session_id: ?[]u8 = null,
    authority: ?operation.OwnedAuthorityClaim = null,
    lease_acquired: bool = false,
    return_reason: ReturnReason = .detach,
    discard_input: bool = false,
    input: std.ArrayList(u8) = .empty,
    prefix: PrefixParser = .{},
    help_visible: bool = false,
    acquire_correlation: ?contracts.CorrelationId = null,
    write_correlation: ?contracts.CorrelationId = null,
    inflight_write_bytes: usize = 0,
    screen_correlation: ?contracts.CorrelationId = null,
    resize_correlation: ?contracts.CorrelationId = null,
    release_correlation: ?contracts.CorrelationId = null,
    release_attempts: u8 = 0,
    surface_return_attempts: u8 = 0,
    inline_recovery_pending: bool = false,
    next_release_ms: i64 = 0,
    last_dimensions: ?contracts.Dimensions = null,
    next_screen_ms: i64 = 0,

    pub fn deinit(self: *Controller, alloc: std.mem.Allocator) void {
        if (self.session_id) |session_id| alloc.free(session_id);
        if (self.authority) |*authority| authority.deinit();
        self.input.deinit(alloc);
        self.* = .{};
    }

    pub fn shutdown(self: *Controller, comptime App: type, app: *App) void {
        if (self.phase == .inactive) return;
        if (self.input.items.len != 0) {
            debug_trace.logf(
                "terminal_takeover",
                "input dropped bytes={d} reason=app_shutdown",
                .{self.input.items.len},
            );
            self.input.clearRetainingCapacity();
        }
        if (self.acquire_correlation) |correlation_id| {
            _ = app.terminal_client.cancel(correlation_id);
            if (waitForCompletion(app, correlation_id)) |completion_value| {
                var completion = completion_value;
                defer completion.deinit();
                if (successFor(completion, .write)) |result| {
                    self.lease_acquired =
                        result.write.session.attention.write_lease == .human;
                }
            }
            self.acquire_correlation = null;
        }
        if (self.write_correlation) |correlation_id| {
            _ = app.terminal_client.cancel(correlation_id);
            var delivered = false;
            if (waitForCompletion(app, correlation_id)) |completion_value| {
                var completion = completion_value;
                delivered = successFor(completion, .write) != null;
                completion.deinit();
            }
            self.write_correlation = null;
            if (!delivered and self.inflight_write_bytes != 0) {
                debug_trace.logf(
                    "terminal_takeover",
                    "input dropped bytes={d} reason=app_shutdown_inflight",
                    .{self.inflight_write_bytes},
                );
            }
            self.inflight_write_bytes = 0;
        }
        if (self.release_correlation) |correlation_id| {
            if (waitForCompletion(app, correlation_id)) |completion_value| {
                var completion = completion_value;
                defer completion.deinit();
                if (successFor(completion, .write) != null) {
                    self.lease_acquired = false;
                }
            }
            self.release_correlation = null;
        }
        if (self.lease_acquired) {
            const correlation_id = app.terminal_client.nextCorrelationId();
            app.terminal_client.admit(app.alloc, correlation_id, .{ .write = .{
                .session_id = self.session_id.?,
                .lease = .release,
                .authority = self.authority.?.view(),
            } }) catch |err| {
                self.traceFailure("shutdown_release_admission", @errorName(err));
                return;
            };
            if (waitForCompletion(app, correlation_id)) |completion_value| {
                var completion = completion_value;
                defer completion.deinit();
                if (successFor(completion, .write) != null) {
                    self.lease_acquired = false;
                }
            }
            if (self.lease_acquired) {
                debug_trace.logf(
                    "terminal_takeover",
                    "shutdown lease release unconfirmed id={s}",
                    .{self.session_id.?},
                );
            }
        }
    }

    pub fn blocksFxSurface(
        self: *const Controller,
        terminal: *const shell_runtime.TerminalState,
    ) bool {
        _ = self;
        return terminal.alternate_screen_owner == .terminal_session;
    }

    pub fn handleByte(
        self: *Controller,
        comptime App: type,
        app: *App,
        byte: u8,
    ) !bool {
        if (self.phase == .inactive) return false;
        if (self.phase == .releasing) {
            return self.blocksFxSurface(&app.terminal);
        }
        if (self.phase != .acquiring and !self.blocksFxSurface(&app.terminal)) {
            return false;
        }
        if (self.help_visible) {
            self.help_visible = false;
            self.next_screen_ms = 0;
        }
        const parsed = self.prefix.feed(byte);
        switch (parsed.action) {
            .none => {},
            .detach => self.beginReturn(App, app, .detach, false) catch |err| {
                self.containFailure(App, app, "detach", err);
            },
            .help => {
                self.help_visible = true;
                self.next_screen_ms = 0;
            },
        }
        if (parsed.forwarded_len != 0 and
            (self.phase == .acquiring or self.phase == .active))
        {
            self.retainInput(app.alloc, parsed.bytes()) catch |err| {
                self.containFailure(App, app, "input", err);
            };
        }
        return true;
    }

    pub fn collect(self: *Controller, comptime App: type, app: *App) !void {
        if (self.phase == .inactive) {
            const session_id = app.terminal_direct.takeOpenIntent() orelse return;
            self.beginOpen(App, app, session_id) catch |err| {
                self.containFailure(App, app, "acquire_admission", err);
            };
        }

        self.collectAcquire(App, app) catch |err| {
            self.containFailure(App, app, "acquire", err);
        };
        self.collectWrite(App, app) catch |err| {
            self.containFailure(App, app, "write", err);
        };
        self.collectResize(App, app) catch |err| {
            self.containFailure(App, app, "resize", err);
        };
        self.collectScreen(App, app) catch |err| {
            self.containFailure(App, app, "screen", err);
        };
        self.collectRelease(App, app) catch |err| {
            self.containFailure(App, app, "release", err);
        };

        if (self.phase == .active) {
            self.scheduleResize(app) catch |err| {
                self.containFailure(App, app, "resize_admission", err);
            };
            if (self.phase == .active) self.scheduleScreen(app) catch |err| {
                self.containFailure(App, app, "screen_admission", err);
            };
        } else if (self.phase == .releasing) {
            self.advanceRelease(App, app) catch |err| {
                self.containFailure(App, app, "release", err);
            };
        }
    }

    pub fn commit(self: *Controller, comptime App: type, app: *App) !bool {
        if (self.phase == .inactive) return false;
        if (self.phase == .acquiring) return true;
        if (!self.blocksFxSurface(&app.terminal)) return false;
        if ((self.phase == .active or
            (self.phase == .releasing and !self.discard_input)) and
            self.write_correlation == null and self.input.items.len != 0)
        {
            self.submitWrite(app) catch |err| {
                self.containFailure(App, app, "write_admission", err);
            };
        }
        if (self.phase == .releasing) self.advanceRelease(App, app) catch |err| {
            self.containFailure(App, app, "release", err);
        };
        return true;
    }

    fn retainInput(
        self: *Controller,
        alloc: std.mem.Allocator,
        bytes: []const u8,
    ) !void {
        if (takeoverFailureRequested("allocation")) {
            return error.InjectedTakeoverFailure;
        }
        if (self.input.items.len > max_forwarded_input_bytes or
            bytes.len > max_forwarded_input_bytes - self.input.items.len)
        {
            return error.TerminalTakeoverInputFull;
        }
        try self.input.appendSlice(alloc, bytes);
    }

    fn containFailure(
        self: *Controller,
        comptime App: type,
        app: *App,
        action: []const u8,
        err: anyerror,
    ) void {
        self.traceFailure(action, @errorName(err));
        if (self.phase == .inactive) {
            app.subagents.activeRenderRequests().request(.subagent_panel);
            return;
        }
        self.beginReturn(App, app, .failure, true) catch |cleanup_err| {
            self.traceFailure("failure_cleanup", @errorName(cleanup_err));
        };
    }

    fn traceFailure(
        self: *const Controller,
        action: []const u8,
        err: []const u8,
    ) void {
        debug_trace.logf(
            "terminal_takeover",
            "failure id={s} phase={s} action={s} error={s}",
            .{
                self.session_id orelse "none",
                @tagName(self.phase),
                action,
                err,
            },
        );
    }

    fn traceCompletionFailure(
        self: *const Controller,
        action: []const u8,
        completion: @import("../terminal/client.zig").Completion,
    ) void {
        var error_name: []const u8 = @tagName(completion.kind);
        if (completion.frame) |frame| {
            switch (frame.message().payload) {
                .response => |response| switch (response) {
                    .failure => |failure| error_name = @tagName(failure.code),
                    .success => {},
                },
                else => {},
            }
        }
        self.traceFailure(action, error_name);
    }

    fn beginOpen(
        self: *Controller,
        comptime App: type,
        app: *App,
        session_id: []u8,
    ) !void {
        var session_owned = true;
        defer if (session_owned) app.alloc.free(session_id);
        var profile_user_buffer: [64]u8 = undefined;
        const profile_user = identity.profileUser(&profile_user_buffer) orelse
            return self.restoreManagerAfterOpenFailure(App, app, "unsupported host");
        const durable_session_id = app_session_runtime.Runtime(App).activeSessionId(app) orelse
            return self.restoreManagerAfterOpenFailure(App, app, "no durable Fx session");
        const owner = app_session_runtime.Runtime(App).childCapability(app) orelse
            return self.restoreManagerAfterOpenFailure(App, app, "durable session unavailable");
        var authority = store.reloadHumanTakeoverAuthorityClaim(app.alloc, owner, .{
            .terminal_session_id = session_id,
            .profile_user = profile_user,
            .durable_session_id = durable_session_id,
            .workspace_root = app.workspace_root,
            .transport_role = .interactive,
            .actor = .human,
        }) catch |err| {
            debug_trace.logf(
                "terminal_takeover",
                "authority reload failed id={s} err={s}",
                .{ session_id, @errorName(err) },
            );
            return self.restoreManagerAfterOpenFailure(App, app, "authority denied");
        };
        var authority_owned = true;
        defer if (authority_owned) authority.deinit();

        self.phase = .acquiring;
        self.session_id = session_id;
        session_owned = false;
        self.authority = authority;
        authority_owned = false;

        try app_lifecycle.leaveSubagentManagerScreen(
            &app.terminal,
            &app.shell,
            &app.metrics,
        );
        const correlation_id = app.terminal_client.nextCorrelationId();
        if (takeoverFailureRequested("acquire_admission")) {
            return error.InjectedTakeoverFailure;
        }
        try app.terminal_client.admit(app.alloc, correlation_id, .{ .write = .{
            .session_id = self.session_id.?,
            .lease = .acquire,
            .authority = self.authority.?.view(),
        } });

        self.acquire_correlation = correlation_id;
        debug_trace.logf(
            "terminal_takeover",
            "lease acquire submitted id={s} correlation={d}",
            .{ session_id, correlation_id.value },
        );
    }

    fn restoreManagerAfterOpenFailure(
        self: *Controller,
        comptime App: type,
        app: *App,
        reason: []const u8,
    ) void {
        _ = self;
        debug_trace.logf(
            "terminal_takeover",
            "open rejected reason={s}",
            .{reason},
        );
        app.subagents.activeRenderRequests().request(.subagent_panel);
    }

    fn collectAcquire(self: *Controller, comptime App: type, app: *App) !void {
        const correlation_id = self.acquire_correlation orelse return;
        var completion = app.terminal_client.takeCompletionFor(correlation_id) orelse return;
        defer completion.deinit();
        self.acquire_correlation = null;
        const success = successFor(completion, .write);
        if (success) |result| {
            const write = result.write;
            if (write.session.attention.write_lease == .human) {
                self.lease_acquired = true;
                if (self.phase == .releasing) {
                    try self.advanceRelease(App, app);
                    return;
                }
                app_lifecycle.enterTerminalSessionScreen(
                    &app.terminal,
                    &app.shell,
                    &app.metrics,
                ) catch |err| {
                    self.traceFailure("screen_enter", @errorName(err));
                    return self.beginReturn(App, app, .failure, true);
                };
                self.phase = .active;
                self.help_visible = true;
                self.next_screen_ms = 0;
                return;
            }
        }
        if (self.phase == .releasing) {
            try self.advanceRelease(App, app);
            return;
        }
        self.traceCompletionFailure("acquire", completion);
        try self.beginReturn(App, app, completionReason(completion), true);
    }

    fn collectWrite(self: *Controller, comptime App: type, app: *App) !void {
        const correlation_id = self.write_correlation orelse return;
        var completion = app.terminal_client.takeCompletionFor(correlation_id) orelse return;
        defer completion.deinit();
        self.write_correlation = null;
        if (self.phase == .releasing) {
            if (successFor(completion, .write) == null) {
                self.traceCompletionFailure("write", completion);
                self.traceInflightInputDrop("drain_write_failed");
                if (self.input.items.len != 0) {
                    debug_trace.logf(
                        "terminal_takeover",
                        "input dropped bytes={d} reason=drain_write_failed",
                        .{self.input.items.len},
                    );
                    self.input.clearRetainingCapacity();
                }
                self.discard_input = true;
                self.return_reason = completionReason(completion);
            }
            self.inflight_write_bytes = 0;
            return;
        }
        const result = successFor(completion, .write) orelse {
            self.traceCompletionFailure("write", completion);
            self.traceInflightInputDrop("write_failed");
            self.inflight_write_bytes = 0;
            return self.beginReturn(App, app, completionReason(completion), true);
        };
        self.inflight_write_bytes = 0;
        if (terminalEnded(result.write.session.lifecycle)) {
            try self.beginReturn(App, app, lifecycleReason(result.write.session.lifecycle), true);
        }
    }

    fn collectResize(self: *Controller, comptime App: type, app: *App) !void {
        const correlation_id = self.resize_correlation orelse return;
        var completion = app.terminal_client.takeCompletionFor(correlation_id) orelse return;
        defer completion.deinit();
        self.resize_correlation = null;
        if (self.phase == .releasing) return;
        const result = successFor(completion, .resize) orelse {
            self.traceCompletionFailure("resize", completion);
            return self.beginReturn(App, app, completionReason(completion), true);
        };
        if (terminalEnded(result.resize.session.lifecycle)) {
            try self.beginReturn(App, app, lifecycleReason(result.resize.session.lifecycle), true);
        }
    }

    fn collectScreen(self: *Controller, comptime App: type, app: *App) !void {
        const correlation_id = self.screen_correlation orelse return;
        var completion = app.terminal_client.takeCompletionFor(correlation_id) orelse return;
        defer completion.deinit();
        self.screen_correlation = null;
        if (self.phase == .releasing) return;
        const result = successFor(completion, .screen) orelse {
            self.traceCompletionFailure("screen", completion);
            return self.beginReturn(App, app, completionReason(completion), true);
        };
        if (terminalEnded(result.screen.session.lifecycle)) {
            return self.beginReturn(
                App,
                app,
                lifecycleReason(result.screen.session.lifecycle),
                true,
            );
        }
        try self.paintSnapshot(app, result.screen.snapshot);
    }

    fn collectRelease(self: *Controller, comptime App: type, app: *App) !void {
        const correlation_id = self.release_correlation orelse return;
        var completion = app.terminal_client.takeCompletionFor(correlation_id) orelse return;
        defer completion.deinit();
        self.release_correlation = null;
        if (successFor(completion, .write) != null) {
            self.lease_acquired = false;
            self.traceReleaseCompletion(correlation_id, "released");
        } else if (releaseOwnershipGone(completion)) {
            self.lease_acquired = false;
            self.traceReleaseCompletion(correlation_id, "ownership_gone");
        } else {
            self.traceCompletionFailure("release", completion);
            self.traceReleaseCompletion(correlation_id, "failed");
            self.next_release_ms = io_mod.milliTimestamp() + release_retry_interval_ms;
        }
        try self.advanceRelease(App, app);
    }

    fn traceReleaseCompletion(
        self: *const Controller,
        correlation_id: contracts.CorrelationId,
        outcome: []const u8,
    ) void {
        debug_trace.logf(
            "terminal_takeover",
            "lease release completed id={s} phase={s} correlation={d} outcome={s}",
            .{
                self.session_id orelse "none",
                @tagName(self.phase),
                correlation_id.value,
                outcome,
            },
        );
    }

    fn scheduleResize(self: *Controller, app: anytype) !void {
        if (self.resize_correlation != null) return;
        if (takeoverFailureRequested("resize")) {
            return error.InjectedTakeoverFailure;
        }
        const dimensions = contracts.Dimensions{
            .rows = app.shell.layout.rows,
            .columns = app.shell.layout.cols,
        };
        try dimensions.validate();
        if (self.last_dimensions) |last| {
            if (std.meta.eql(last, dimensions)) return;
        }
        const correlation_id = app.terminal_client.nextCorrelationId();
        try app.terminal_client.admit(app.alloc, correlation_id, .{ .resize = .{
            .session_id = self.session_id.?,
            .dimensions = dimensions,
            .authority = self.authority.?.view(),
        } });
        if (self.last_dimensions != null) {
            record_tape.recordResize(dimensions.columns, dimensions.rows);
        }
        self.resize_correlation = correlation_id;
        self.last_dimensions = dimensions;
    }

    fn scheduleScreen(self: *Controller, app: anytype) !void {
        if (self.screen_correlation != null) return;
        const now_ms = io_mod.milliTimestamp();
        if (now_ms < self.next_screen_ms) return;
        if (takeoverFailureRequested("screen")) {
            return error.InjectedTakeoverFailure;
        }
        const correlation_id = app.terminal_client.nextCorrelationId();
        try app.terminal_client.admit(app.alloc, correlation_id, .{ .screen = .{
            .session_id = self.session_id.?,
            .authority = self.authority.?.view(),
        } });
        self.screen_correlation = correlation_id;
        self.next_screen_ms = now_ms + screen_poll_interval_ms;
    }

    fn submitWrite(self: *Controller, app: anytype) !void {
        if (takeoverFailureRequested("write")) {
            return error.InjectedTakeoverFailure;
        }
        const byte_count = @min(self.input.items.len, contracts.max_write_bytes);
        const correlation_id = app.terminal_client.nextCorrelationId();
        try app.terminal_client.admit(app.alloc, correlation_id, .{ .write = .{
            .session_id = self.session_id.?,
            .payload = .{ .text = self.input.items[0..byte_count] },
            .lease = .use,
            .authority = self.authority.?.view(),
        } });
        self.write_correlation = correlation_id;
        self.inflight_write_bytes = byte_count;
        debug_trace.logf(
            "terminal_takeover",
            "write submitted id={s} correlation={d} bytes={d}",
            .{ self.session_id.?, correlation_id.value, byte_count },
        );
        const remaining = self.input.items.len - byte_count;
        std.mem.copyForwards(
            u8,
            self.input.items[0..remaining],
            self.input.items[byte_count..],
        );
        self.input.items.len = remaining;
    }

    fn traceInflightInputDrop(self: *const Controller, reason: []const u8) void {
        if (self.inflight_write_bytes == 0) return;
        debug_trace.logf(
            "terminal_takeover",
            "input dropped bytes={d} reason={s}",
            .{ self.inflight_write_bytes, reason },
        );
    }

    fn paintSnapshot(
        self: *Controller,
        app: anytype,
        snapshot: contracts.RenderSnapshot,
    ) !void {
        if (!app.terminal.terminalSessionScreenActive()) return;
        if (takeoverFailureRequested("paint")) {
            return error.InjectedTakeoverFailure;
        }
        var output: std.Io.Writer.Allocating = .init(app.alloc);
        defer output.deinit();
        try engine.writeFullSnapshot(snapshot, &output.writer);
        if (self.help_visible) {
            try output.writer.print(
                "\x1b[{d};1H\x1b[0;7m\x1b[2K Ctrl-] d detach  Ctrl-] ? help \x1b[0m\x1b[?25l",
                .{snapshot.dimensions.rows},
            );
        }
        try app_lifecycle.writeLifecycleTerminalBytes(
            &app.shell,
            &app.metrics,
            output.written(),
        );
    }

    fn beginReturn(
        self: *Controller,
        comptime App: type,
        app: *App,
        reason: ReturnReason,
        discard_input: bool,
    ) !void {
        if (self.phase == .inactive or self.phase == .releasing) return;
        self.phase = .releasing;
        self.return_reason = reason;
        self.discard_input = discard_input;
        if (discard_input and self.input.items.len != 0) {
            debug_trace.logf(
                "terminal_takeover",
                "input dropped bytes={d} reason={s}",
                .{ self.input.items.len, @tagName(reason) },
            );
            self.input.clearRetainingCapacity();
        }
        try self.advanceRelease(App, app);
    }

    fn advanceRelease(self: *Controller, comptime App: type, app: *App) !void {
        if (self.phase != .releasing) return;
        if (!self.discard_input and self.input.items.len != 0) {
            if (self.write_correlation == null) try self.submitWrite(app);
            return;
        }
        if (self.write_correlation != null) return;

        var surface_error: ?anyerror = null;
        self.returnToOrigin(App, app) catch |err| {
            surface_error = err;
        };

        if (self.acquire_correlation == null and
            self.lease_acquired and
            self.release_correlation == null)
        {
            const now_ms = io_mod.milliTimestamp();
            if (now_ms >= self.next_release_ms) {
                if (takeoverFailureRequested("release_admission") and
                    self.release_attempts == 0)
                {
                    self.release_attempts = 1;
                    self.next_release_ms = now_ms + release_retry_interval_ms;
                    self.traceFailure(
                        "release_admission",
                        @errorName(error.InjectedTakeoverFailure),
                    );
                } else {
                    const correlation_id = app.terminal_client.nextCorrelationId();
                    app.terminal_client.admit(app.alloc, correlation_id, .{ .write = .{
                        .session_id = self.session_id.?,
                        .lease = .release,
                        .authority = self.authority.?.view(),
                    } }) catch |err| {
                        self.traceFailure("release_admission", @errorName(err));
                        self.release_attempts +|= 1;
                        self.next_release_ms = now_ms + release_retry_interval_ms;
                        if (surface_error) |return_err| return return_err;
                        return;
                    };
                    self.release_correlation = correlation_id;
                    self.release_attempts +|= 1;
                    debug_trace.logf(
                        "terminal_takeover",
                        "lease release submitted id={s} phase={s} correlation={d} attempt={d}",
                        .{
                            self.session_id.?,
                            @tagName(self.phase),
                            correlation_id.value,
                            self.release_attempts,
                        },
                    );
                }
            }
        }

        const cleanup_pending = self.acquire_correlation != null or
            self.lease_acquired or
            self.release_correlation != null or
            self.screen_correlation != null or
            self.resize_correlation != null or
            self.inline_recovery_pending;
        if (!cleanup_pending and
            !self.blocksFxSurface(&app.terminal))
        {
            try self.finishReturn(App, app);
        } else if (surface_error) |return_err| {
            return return_err;
        }
    }

    fn finishReturn(self: *Controller, comptime App: type, app: *App) !void {
        std.debug.assert(!self.lease_acquired);
        std.debug.assert(self.acquire_correlation == null);
        std.debug.assert(self.write_correlation == null);
        std.debug.assert(self.screen_correlation == null);
        std.debug.assert(self.resize_correlation == null);
        std.debug.assert(self.release_correlation == null);
        std.debug.assert(!self.blocksFxSurface(&app.terminal));
        const reason = self.return_reason;

        self.reset(app.alloc);
        if (reason != .detach) {
            const body = switch (reason) {
                .exited => "Terminal session exited",
                .lost => "Terminal session was lost",
                .failure => "Terminal takeover ended after an error",
                .detach => unreachable,
            };
            app.writeDomainNotice(.{
                .topic = "terminal",
                .tone = if (reason == .failure or reason == .lost)
                    types.NoticeTone.@"error"
                else
                    .information,
                .body = body,
            }, true) catch |err| debug_trace.logf(
                "terminal_takeover",
                "state notice failed err={s}",
                .{@errorName(err)},
            );
        }
    }

    fn returnToOrigin(self: *Controller, comptime App: type, app: *App) !void {
        const action = surfaceReturnAction(
            app.subagents.isViewActive(),
            app.terminal.alternate_screen_owner,
            self.inline_recovery_pending,
        );
        const physical_transition = action == .handoff_to_manager or
            action == .enter_manager or
            action == .leave_to_inline;
        if (physical_transition and
            takeoverFailureRequested("surface_return") and
            self.surface_return_attempts == 0)
        {
            self.surface_return_attempts = 1;
            return error.InjectedTakeoverFailure;
        }

        switch (action) {
            .handoff_to_manager => {
                app_lifecycle.handoffTerminalSessionToSubagentManager(
                    &app.terminal,
                    &app.shell,
                    &app.metrics,
                ) catch |err| {
                    debug_trace.logf(
                        "terminal_takeover",
                        "manager handoff failed err={s}",
                        .{@errorName(err)},
                    );
                    try app_lifecycle.leaveTerminalSessionScreen(
                        &app.terminal,
                        &app.shell,
                        &app.metrics,
                    );
                    try app_lifecycle.enterSubagentManagerScreen(
                        &app.terminal,
                        &app.shell,
                        &app.metrics,
                    );
                };
                self.inline_recovery_pending = false;
                app.subagents.activeRenderRequests().request(.subagent_panel);
                app.subagents.activeRenderRequests().request(.footer);
            },
            .enter_manager => {
                try app_lifecycle.enterSubagentManagerScreen(
                    &app.terminal,
                    &app.shell,
                    &app.metrics,
                );
                self.inline_recovery_pending = false;
                app.subagents.activeRenderRequests().request(.subagent_panel);
                app.subagents.activeRenderRequests().request(.footer);
            },
            .render_manager => {
                self.inline_recovery_pending = false;
                app.subagents.activeRenderRequests().request(.subagent_panel);
                app.subagents.activeRenderRequests().request(.footer);
            },
            .leave_to_inline => {
                try app_lifecycle.leaveTerminalSessionScreen(
                    &app.terminal,
                    &app.shell,
                    &app.metrics,
                );
                self.inline_recovery_pending = true;
                try self.recoverInline(App, app);
            },
            .recover_inline => try self.recoverInline(App, app),
            .none => {},
        }
    }

    fn recoverInline(self: *Controller, comptime App: type, app: *App) !void {
        try app_render_runtime.Runtime(App).requestNormalViewportRecovery(app);
        self.inline_recovery_pending = false;
    }

    fn reset(self: *Controller, alloc: std.mem.Allocator) void {
        if (self.session_id) |session_id| alloc.free(session_id);
        if (self.authority) |*authority| authority.deinit();
        self.input.clearRetainingCapacity();
        const retained_input = self.input;
        self.* = .{ .input = retained_input };
    }
};

fn takeoverFailureRequested(action: []const u8) bool {
    const requested = io_mod.getenv("FX_TERMINAL_TEST_TAKEOVER_FAILURE") orelse
        return false;
    return std.mem.eql(u8, requested, action);
}

fn waitForCompletion(app: anytype, correlation_id: contracts.CorrelationId) ?@import("../terminal/client.zig").Completion {
    const deadline_ms = io_mod.milliTimestamp() + 2_000;
    while (io_mod.milliTimestamp() < deadline_ms) {
        if (app.terminal_client.takeCompletionFor(correlation_id)) |completion| {
            return completion;
        }
        io_mod.sleep(5 * std.time.ns_per_ms);
    }
    return null;
}

fn successFor(
    completion: @import("../terminal/client.zig").Completion,
    action: contracts.Action,
) ?contracts.ActionResult {
    const frame = completion.frame orelse return null;
    return switch (frame.message().payload) {
        .response => |response| switch (response) {
            .success => |success| if (success.action() == action) success else null,
            .failure => null,
        },
        else => null,
    };
}

fn completionReason(
    completion: @import("../terminal/client.zig").Completion,
) ReturnReason {
    if (completion.frame) |frame| {
        switch (frame.message().payload) {
            .response => |response| switch (response) {
                .failure => |failure| return switch (failure.code) {
                    .session_not_found, .session_lost => .lost,
                    else => .failure,
                },
                .success => {},
            },
            else => {},
        }
    }
    return switch (completion.kind) {
        .disconnected, .unavailable => .lost,
        else => .failure,
    };
}

fn releaseOwnershipGone(
    completion: @import("../terminal/client.zig").Completion,
) bool {
    const frame = completion.frame orelse return false;
    return switch (frame.message().payload) {
        .response => |response| switch (response) {
            .failure => |failure| switch (failure.code) {
                .session_not_found,
                .session_lost,
                .authority_denied,
                .lease_conflict,
                => true,
                else => false,
            },
            .success => false,
        },
        else => false,
    };
}

fn terminalEnded(lifecycle: contracts.Lifecycle) bool {
    return lifecycle == .exited or lifecycle == .lost or lifecycle == .closed;
}

fn lifecycleReason(lifecycle: contracts.Lifecycle) ReturnReason {
    return if (lifecycle == .exited or lifecycle == .closed) .exited else .lost;
}

test "takeover prefix fragments locally without leaking consumed bytes" {
    var parser: PrefixParser = .{};
    try std.testing.expectEqual(@as(u1, 0), parser.feed(control_prefix).forwarded_len);
    try std.testing.expectEqual(PrefixAction.detach, parser.feed('d').action);

    _ = parser.feed(control_prefix);
    try std.testing.expectEqual(PrefixAction.help, parser.feed('?').action);

    _ = parser.feed(control_prefix);
    const literal = parser.feed(control_prefix);
    try std.testing.expectEqualSlices(u8, &.{control_prefix}, literal.bytes());

    _ = parser.feed(control_prefix);
    const unknown = parser.feed('x');
    try std.testing.expectEqualSlices(u8, "x", unknown.bytes());
}

test "takeover prefix is raw data inside fragmented bracketed paste" {
    var parser: PrefixParser = .{};
    for ("\x1b[200~") |byte| _ = parser.feed(byte);
    try std.testing.expect(parser.in_paste);
    try std.testing.expectEqualSlices(
        u8,
        &.{control_prefix},
        parser.feed(control_prefix).bytes(),
    );
    for ("\x1b[201~") |byte| _ = parser.feed(byte);
    try std.testing.expect(!parser.in_paste);
}

test "takeover retains bounded input while lease acquisition is pending" {
    var controller = Controller{ .phase = .acquiring };
    defer controller.deinit(std.testing.allocator);

    try controller.retainInput(std.testing.allocator, "before-acquire");
    try std.testing.expectEqualStrings("before-acquire", controller.input.items);

    try controller.input.ensureTotalCapacity(
        std.testing.allocator,
        max_forwarded_input_bytes,
    );
    controller.input.items.len = max_forwarded_input_bytes;
    try std.testing.expectError(
        error.TerminalTakeoverInputFull,
        controller.retainInput(std.testing.allocator, "x"),
    );
}

test "takeover input allocation failure leaves the controller-owned buffer intact" {
    var controller = Controller{ .phase = .acquiring };
    defer controller.deinit(std.testing.allocator);
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );

    try std.testing.expectError(
        error.OutOfMemory,
        controller.retainInput(failing.allocator(), "pending"),
    );
    try std.testing.expectEqual(@as(usize, 0), controller.input.items.len);
}

test "alternate screen ownership is the takeover visibility oracle" {
    var controller = Controller{
        .phase = .releasing,
        .lease_acquired = true,
    };
    var terminal = shell_runtime.TerminalState{
        .alternate_screen_owner = .terminal_session,
    };
    try std.testing.expect(controller.blocksFxSurface(&terminal));
    terminal.alternate_screen_owner = .subagent_manager;
    try std.testing.expect(!controller.blocksFxSurface(&terminal));
    try std.testing.expectEqual(Phase.releasing, controller.phase);
    try std.testing.expect(controller.lease_acquired);
}

test "surface return decisions are independent of lease cleanup order" {
    try std.testing.expectEqual(
        SurfaceReturnAction.handoff_to_manager,
        surfaceReturnAction(true, .terminal_session, false),
    );
    try std.testing.expectEqual(
        SurfaceReturnAction.render_manager,
        surfaceReturnAction(true, .subagent_manager, false),
    );
    try std.testing.expectEqual(
        SurfaceReturnAction.leave_to_inline,
        surfaceReturnAction(false, .terminal_session, false),
    );
    try std.testing.expectEqual(
        SurfaceReturnAction.recover_inline,
        surfaceReturnAction(false, .none, true),
    );
    try std.testing.expectEqual(
        SurfaceReturnAction.none,
        surfaceReturnAction(false, .none, false),
    );
}

const DirectReturnTestSubagents = struct {
    fn isViewActive(_: *const DirectReturnTestSubagents) bool {
        return false;
    }

    fn activeRenderRequests(_: *DirectReturnTestSubagents) *render_request.RenderRequestState {
        unreachable;
    }
};

const DirectReturnTestApp = struct {
    terminal: shell_runtime.TerminalState = .{},
    shell: transcript_runtime.TranscriptRuntime,
    metrics: types.Metrics = .{},
    subagents: DirectReturnTestSubagents = .{},
};

test "takeover direct return restores modes and requests normal viewport recovery" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(
        io_mod.getIo(),
        "terminal-takeover-direct-return.out",
        .{ .read = true },
    );
    defer file.close(io_mod.getIo());
    var app = DirectReturnTestApp{ .shell = .{
        .stdout_file = file,
        .layout = .{
            .rows = 12,
            .cols = 60,
            .content_bottom = 8,
            .divider_top_row = 9,
            .input_row = 10,
            .divider_bottom_row = 11,
            .hint_row = 12,
        },
        .owned_top_row = 1,
        .viewport_top_row = 1,
        .cursor_row = 12,
    } };
    defer app.shell.deinit(alloc);
    try app.shell.initBacking(alloc);
    try app_lifecycle.enterTerminalSessionScreen(
        &app.terminal,
        &app.shell,
        &app.metrics,
    );

    var controller = Controller{
        .phase = .releasing,
        .lease_acquired = true,
    };
    try controller.returnToOrigin(DirectReturnTestApp, &app);
    try controller.returnToOrigin(DirectReturnTestApp, &app);

    try std.testing.expect(controller.lease_acquired);
    try std.testing.expect(!controller.inline_recovery_pending);
    try std.testing.expect(!controller.blocksFxSurface(&app.terminal));
    try std.testing.expectEqual(Phase.releasing, controller.phase);
    try std.testing.expectEqual(
        shell_runtime.AlternateScreenOwner.none,
        app.terminal.alternate_screen_owner,
    );
    try std.testing.expect(app.shell.viewport_clear_pending);
    try std.testing.expectEqual(@as(u32, 8), app.shell.cursor_row);
    try std.testing.expect(app.shell.render_requests.pending_reasons.contains(.resize));
    try std.testing.expect(app.shell.render_requests.pending_reasons.contains(.footer));
    try std.testing.expect(!app.shell.render_requests.pending_reasons.contains(.first_frame));

    var read_file = try tmp.dir.openFile(
        io_mod.getIo(),
        "terminal-takeover-direct-return.out",
        .{},
    );
    defer read_file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &read_file, 4096);
    defer alloc.free(bytes);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, bytes, "\x1b[?1049h"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, bytes, "\x1b[?1049l"),
    );
}
