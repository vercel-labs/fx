const std = @import("std");
const agent_runtime = @import("../../core/agent/agent_runtime.zig");
const hooks = @import("../../core/hooks/hooks.zig");
const notification_contract = @import("../../core/notifications/notification_contract.zig");
const notification_sound = @import("../../core/notifications/sound.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const app_session_runtime = @import("../../core/app/app_session_runtime.zig");

const Preferences = notification_contract.Preferences;
const Kind = notification_contract.Kind;
const Cue = notification_contract.Cue;
const Notification = notification_contract.Notification;

const ReadyNotifications = struct {
    turn_end_success: usize = 0,
    turn_end_error: usize = 0,
    attention_required: usize = 0,
};

pub const State = struct {
    player: ?notification_sound.Player = null,
    turn_end_enabled: std.atomic.Value(bool) = .init(false),
    attention_required_enabled: std.atomic.Value(bool) = .init(false),
    max_enabled: std.atomic.Value(bool) = .init(false),
    pending_turn_end_success: usize = 0,
    pending_turn_end_error: usize = 0,
    pending_attention_required: usize = 0,

    fn configure(self: *State, bell: notification_sound.BellSink) void {
        std.debug.assert(self.player == null);
        self.player = notification_sound.Player.init(bell);
    }

    fn setPreferences(self: *State, next: Preferences) void {
        self.turn_end_enabled.store(next.turn_end, .release);
        self.attention_required_enabled.store(next.attention_required, .release);
        self.max_enabled.store(next.max, .release);
    }

    fn preferences(self: *const State) Preferences {
        return .{
            .turn_end = self.turn_end_enabled.load(.acquire),
            .attention_required = self.attention_required_enabled.load(.acquire),
            .max = self.max_enabled.load(.acquire),
        };
    }

    // Gate for max-only sound points. Requires sound on and max selected.
    fn maxEnabled(self: *const State) bool {
        return self.soundEnabled() and self.max_enabled.load(.acquire);
    }

    fn enabled(self: *const State, kind: Kind) bool {
        return switch (kind) {
            .turn_end => self.turn_end_enabled.load(.acquire),
            .attention_required => self.attention_required_enabled.load(.acquire),
        };
    }

    // The /sound master switch moves both flags together, so turn_end stands
    // in for "sound on" when playing cues without a turn/attention hook.
    fn soundEnabled(self: *const State) bool {
        return self.turn_end_enabled.load(.acquire);
    }

    fn enabledForScope(
        self: *const State,
        kind: Kind,
        scope: hooks.ScopeKind,
    ) bool {
        return scope == .interactive and self.enabled(kind);
    }

    fn queue(
        self: *State,
        notification: Notification,
        presentation_pending: bool,
    ) bool {
        return switch (notification.kind) {
            .turn_end => blk: {
                // Turn notifications only ever carry success or error; bloom and
                // press play directly via playCue, never through this queue.
                if (notification.cue == .@"error") {
                    self.pending_turn_end_error +|= 1;
                } else {
                    self.pending_turn_end_success +|= 1;
                }
                break :blk !presentation_pending;
            },
            .attention_required => blk: {
                self.pending_attention_required +|= 1;
                break :blk true;
            },
        };
    }

    fn presentationFinished(self: *const State) bool {
        return self.pending_turn_end_success != 0 or self.pending_turn_end_error != 0;
    }

    fn takeReady(
        self: *State,
        presentation_pending: bool,
    ) ReadyNotifications {
        const ready = ReadyNotifications{
            .turn_end_success = if (presentation_pending) 0 else self.pending_turn_end_success,
            .turn_end_error = if (presentation_pending) 0 else self.pending_turn_end_error,
            .attention_required = self.pending_attention_required,
        };
        if (!presentation_pending) {
            self.pending_turn_end_success = 0;
            self.pending_turn_end_error = 0;
        }
        self.pending_attention_required = 0;
        return ready;
    }
};

fn Runtime(comptime App: type) type {
    return struct {
        pub fn configure(app: *App) !void {
            app.notifications.configure(.{
                .ctx = app,
                .emit = emitInteractiveBell,
            });
            try app.lifecycle_runtime.registerPostTurnEnd(.{
                .name = "fx.sound.turn_end",
                .ctx = app,
                .run = postTurnEndHandler,
            });
            try app.lifecycle_runtime.registerAttentionRequired(.{
                .name = "fx.sound.attention_required",
                .ctx = app,
                .run = attentionRequiredHandler,
            });
            app.lifecycle_view = app.lifecycle_runtime.freeze();
        }

        pub fn setPreferences(
            app: *App,
            next: Preferences,
        ) void {
            app.notifications.setPreferences(next);
        }

        pub fn preferences(app: *const App) Preferences {
            return app.notifications.preferences();
        }

        // Whether max-only sound points should fire. Consulted by future
        // trigger sites gated on the max level.
        pub fn maxEnabled(app: *const App) bool {
            return app.notifications.maxEnabled();
        }

        pub fn queue(app: *App, notification: Notification) void {
            if (app.notifications.queue(notification, app.pacer.hasPending())) {
                app.shell.render_requests.request(.notification);
            }
        }

        // Plays a cue immediately, bypassing the turn/attention queue. Used for
        // one-off events (startup, cancellation) gated by the /sound switch.
        pub fn playCue(app: *App, cue: Cue) void {
            if (!app.notifications.soundEnabled()) return;
            const player = if (app.notifications.player) |*configured| configured else return;
            debug_trace.logf("notifications", "sound play cue={s} trigger=direct", .{@tagName(cue)});
            player.play(cue);
        }

        // Plays a cue for a max-only point: silent unless the level is max.
        pub fn playMaxCue(app: *App, cue: Cue) void {
            if (!app.notifications.maxEnabled()) return;
            const player = if (app.notifications.player) |*configured| configured else return;
            debug_trace.logf("notifications", "sound play cue={s} trigger=max", .{@tagName(cue)});
            player.play(cue);
        }

        pub fn presentationFinished(app: *App) void {
            if (app.notifications.presentationFinished()) {
                app.shell.render_requests.request(.notification);
            }
        }

        pub fn flush(app: *App) void {
            const ready = app.notifications.takeReady(app.pacer.hasPending());
            const count = ready.attention_required +| ready.turn_end_success +| ready.turn_end_error;
            if (count == 0) return;

            const player = if (app.notifications.player) |*configured|
                configured
            else {
                debug_trace.logf(
                    "notifications",
                    "notification delivery dropped count={d} reason=player_not_configured",
                    .{count},
                );
                return;
            };
            deliver(player, .attention_required, .success, ready.attention_required);
            deliver(player, .turn_end, .success, ready.turn_end_success);
            deliver(player, .turn_end, .@"error", ready.turn_end_error);
        }

        pub fn dispatchAttentionRequired(
            app: *App,
            turn_id: u64,
            kind: hooks.AttentionKind,
        ) void {
            agent_runtime.dispatchAttentionRequiredCheckpoint(.{
                .view = app.lifecycle_view,
                .scope = .{
                    .kind = .interactive,
                    .workspace_root = app.workspace_root,
                    .session_id = app_session_runtime.Runtime(App).activeSessionId(app),
                },
                .outcome_allocator = app.alloc,
            }, .{
                .turn_id = turn_id,
                .kind = kind,
            });
        }

        fn postTurnEndHandler(
            raw: *anyopaque,
            input: hooks.PostTurnEndInput,
        ) hooks.HandlerError!void {
            const app: *App = @ptrCast(@alignCast(raw));
            if (!app.notifications.enabledForScope(
                .turn_end,
                input.invocation.scope.kind,
            )) return;
            const cue: Cue = switch (input.outcome) {
                .completed => .success,
                .failed => .@"error",
                // Cancellation already plays the press cue; stay silent here.
                .interrupted, .paused => return,
            };
            enqueue(app, .{ .kind = .turn_end, .cue = cue });
        }

        fn attentionRequiredHandler(
            raw: *anyopaque,
            input: hooks.AttentionRequiredInput,
        ) hooks.HandlerError!void {
            const app: *App = @ptrCast(@alignCast(raw));
            if (!app.notifications.enabledForScope(
                .attention_required,
                input.invocation.scope.kind,
            )) return;
            enqueue(app, .{ .kind = .attention_required });
        }

        fn enqueue(app: *App, notification: Notification) void {
            app.worker.pushEvent(std.heap.c_allocator, .{ .notification = notification }) catch |err| {
                debug_trace.logf(
                    "notifications",
                    "interactive notification enqueue failed kind={s} err={s}",
                    .{ @tagName(notification.kind), @errorName(err) },
                );
            };
        }

        fn deliver(
            player: *notification_sound.Player,
            kind: Kind,
            cue: Cue,
            count: usize,
        ) void {
            for (0..count) |_| {
                debug_trace.logf(
                    "notifications",
                    "sound play kind={s} cue={s}",
                    .{ @tagName(kind), @tagName(cue) },
                );
                switch (kind) {
                    .attention_required => player.playAttention(cue),
                    .turn_end => player.play(cue),
                }
            }
        }

        fn emitInteractiveBell(raw: *anyopaque) void {
            const app: *App = @ptrCast(@alignCast(raw));
            app.shell.writeNotificationBell(&app.metrics);
        }
    };
}

pub fn provider(comptime App: type) notification_contract.Provider {
    const Adapter = ProviderAdapter(App);
    return .{
        .configure = Adapter.configure,
        .set_preferences = Adapter.setPreferences,
        .preferences = Adapter.preferences,
        .max_enabled = Adapter.maxEnabled,
        .queue = Adapter.queue,
        .presentation_finished = Adapter.presentationFinished,
        .flush = Adapter.flush,
        .play_cue = Adapter.playCue,
        .play_max_cue = Adapter.playMaxCue,
        .dispatch_attention_required = Adapter.dispatchAttentionRequired,
    };
}

fn ProviderAdapter(comptime App: type) type {
    return struct {
        const Concrete = Runtime(App);

        fn configure(raw: *anyopaque) notification_contract.ConfigureError!void {
            const app: *App = @ptrCast(@alignCast(raw));
            try Concrete.configure(app);
        }

        fn setPreferences(raw: *anyopaque, next: Preferences) void {
            const app: *App = @ptrCast(@alignCast(raw));
            Concrete.setPreferences(app, next);
        }

        fn preferences(raw: *const anyopaque) Preferences {
            const app: *const App = @ptrCast(@alignCast(raw));
            return Concrete.preferences(app);
        }

        fn maxEnabled(raw: *const anyopaque) bool {
            const app: *const App = @ptrCast(@alignCast(raw));
            return Concrete.maxEnabled(app);
        }

        fn queue(raw: *anyopaque, notification: Notification) void {
            const app: *App = @ptrCast(@alignCast(raw));
            Concrete.queue(app, notification);
        }

        fn presentationFinished(raw: *anyopaque) void {
            const app: *App = @ptrCast(@alignCast(raw));
            Concrete.presentationFinished(app);
        }

        fn flush(raw: *anyopaque) void {
            const app: *App = @ptrCast(@alignCast(raw));
            Concrete.flush(app);
        }

        fn playCue(raw: *anyopaque, cue: Cue) void {
            const app: *App = @ptrCast(@alignCast(raw));
            Concrete.playCue(app, cue);
        }

        fn playMaxCue(raw: *anyopaque, cue: Cue) void {
            const app: *App = @ptrCast(@alignCast(raw));
            Concrete.playMaxCue(app, cue);
        }

        fn dispatchAttentionRequired(
            raw: *anyopaque,
            turn_id: u64,
            kind: hooks.AttentionKind,
        ) void {
            const app: *App = @ptrCast(@alignCast(raw));
            Concrete.dispatchAttentionRequired(app, turn_id, kind);
        }
    };
}

test "turn-end delivery waits for paced presentation while attention remains immediate" {
    var state = State{};
    state.setPreferences(.{
        .turn_end = true,
        .attention_required = true,
    });

    try std.testing.expect(state.enabled(.turn_end));
    try std.testing.expect(state.enabled(.attention_required));
    for ([_]hooks.ScopeKind{ .ask, .acp, .subagent }) |scope| {
        try std.testing.expect(!state.enabledForScope(.turn_end, scope));
        try std.testing.expect(!state.enabledForScope(.attention_required, scope));
    }
    try std.testing.expect(!state.queue(.{ .kind = .turn_end, .cue = .@"error" }, true));
    try std.testing.expect(state.queue(.{ .kind = .attention_required }, true));

    var ready = state.takeReady(true);
    try std.testing.expectEqual(@as(usize, 0), ready.turn_end_error);
    try std.testing.expectEqual(@as(usize, 1), ready.attention_required);
    try std.testing.expect(state.presentationFinished());

    ready = state.takeReady(false);
    try std.testing.expectEqual(@as(usize, 1), ready.turn_end_error);
    try std.testing.expectEqual(@as(usize, 0), ready.turn_end_success);
    try std.testing.expectEqual(@as(usize, 0), ready.attention_required);
    try std.testing.expect(!state.presentationFinished());
}

test "max gate requires both sound on and max selected" {
    var state = State{};
    try std.testing.expect(!state.maxEnabled());

    state.setPreferences(.{ .turn_end = true, .attention_required = true, .max = false });
    try std.testing.expect(!state.maxEnabled());
    try std.testing.expect(!state.preferences().max);

    state.setPreferences(.{ .turn_end = true, .attention_required = true, .max = true });
    try std.testing.expect(state.maxEnabled());
    try std.testing.expect(state.preferences().max);

    // Sound off suppresses max even if the flag lingers.
    state.setPreferences(.{ .turn_end = false, .attention_required = false, .max = true });
    try std.testing.expect(!state.maxEnabled());
}
