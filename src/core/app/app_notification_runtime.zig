const std = @import("std");
const hooks = @import("../hooks/hooks.zig");
const notification_contract = @import("../notifications/notification_contract.zig");

pub const Preferences = notification_contract.Preferences;
pub const Notification = notification_contract.Notification;
const Kind = notification_contract.Kind;
const Cue = notification_contract.Cue;
const Provider = notification_contract.Provider;

pub fn Runtime(
    comptime App: type,
    comptime provider: Provider,
) type {
    return struct {
        pub fn configure(app: *App) notification_contract.ConfigureError!void {
            try provider.configure(app);
        }

        pub fn setPreferences(app: *App, next: Preferences) void {
            provider.set_preferences(app, next);
        }

        pub fn preferences(app: *const App) Preferences {
            return provider.preferences(app);
        }

        pub fn maxEnabled(app: *const App) bool {
            return provider.max_enabled(app);
        }

        pub fn queue(app: *App, notification: Notification) void {
            provider.queue(app, notification);
        }

        pub fn presentationFinished(app: *App) void {
            provider.presentation_finished(app);
        }

        pub fn flush(app: *App) void {
            provider.flush(app);
        }

        pub fn playCue(app: *App, cue: Cue) void {
            provider.play_cue(app, cue);
        }

        pub fn playMaxCue(app: *App, cue: Cue) void {
            provider.play_max_cue(app, cue);
        }

        pub fn dispatchAttentionRequired(
            app: *App,
            session_id: ?[]const u8,
            turn_id: u64,
            kind: hooks.AttentionKind,
        ) void {
            provider.dispatch_attention_required(app, session_id, turn_id, kind);
        }
    };
}

test "notification runtime routes the full contract through its provider" {
    const FakeApp = struct {
        configure_fails: bool = false,
        configure_count: usize = 0,
        preferences_value: Preferences = .{},
        max_enabled_value: bool = false,
        queued: ?Notification = null,
        presentation_finished_count: usize = 0,
        flush_count: usize = 0,
        played_cue: ?Cue = null,
        played_max_cue: ?Cue = null,
        attention_session_id: ?[]const u8 = null,
        attention_turn_id: ?u64 = null,
        attention_kind: ?hooks.AttentionKind = null,

        const provider = Provider{
            .configure = configureProvider,
            .set_preferences = setPreferencesProvider,
            .preferences = preferencesProvider,
            .max_enabled = maxEnabledProvider,
            .queue = queueProvider,
            .presentation_finished = presentationFinishedProvider,
            .flush = flushProvider,
            .play_cue = playCueProvider,
            .play_max_cue = playMaxCueProvider,
            .dispatch_attention_required = dispatchAttentionRequiredProvider,
        };

        fn configureProvider(raw: *anyopaque) notification_contract.ConfigureError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.configure_fails) return error.RuntimeFrozen;
            self.configure_count += 1;
        }

        fn setPreferencesProvider(raw: *anyopaque, preferences_value: Preferences) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.preferences_value = preferences_value;
        }

        fn preferencesProvider(raw: *const anyopaque) Preferences {
            const self: *const @This() = @ptrCast(@alignCast(raw));
            return self.preferences_value;
        }

        fn maxEnabledProvider(raw: *const anyopaque) bool {
            const self: *const @This() = @ptrCast(@alignCast(raw));
            return self.max_enabled_value;
        }

        fn queueProvider(raw: *anyopaque, notification: Notification) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.queued = notification;
        }

        fn presentationFinishedProvider(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.presentation_finished_count += 1;
        }

        fn flushProvider(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.flush_count += 1;
        }

        fn playCueProvider(raw: *anyopaque, cue: Cue) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.played_cue = cue;
        }

        fn playMaxCueProvider(raw: *anyopaque, cue: Cue) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.played_max_cue = cue;
        }

        fn dispatchAttentionRequiredProvider(
            raw: *anyopaque,
            session_id: ?[]const u8,
            turn_id: u64,
            kind: hooks.AttentionKind,
        ) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.attention_session_id = session_id;
            self.attention_turn_id = turn_id;
            self.attention_kind = kind;
        }
    };

    const TestRuntime = Runtime(FakeApp, FakeApp.provider);
    var app = FakeApp{};

    app.configure_fails = true;
    try std.testing.expectError(error.RuntimeFrozen, TestRuntime.configure(&app));
    app.configure_fails = false;
    try TestRuntime.configure(&app);
    try std.testing.expectEqual(@as(usize, 1), app.configure_count);

    const preferences_value = Preferences{
        .turn_end = true,
        .attention_required = true,
        .max = true,
    };
    TestRuntime.setPreferences(&app, preferences_value);
    const captured_preferences = TestRuntime.preferences(&app);
    try std.testing.expect(captured_preferences.turn_end);
    try std.testing.expect(captured_preferences.attention_required);
    try std.testing.expect(captured_preferences.max);

    app.max_enabled_value = true;
    try std.testing.expect(TestRuntime.maxEnabled(&app));

    TestRuntime.queue(&app, .{ .kind = .turn_end, .cue = .@"error" });
    try std.testing.expectEqual(Kind.turn_end, app.queued.?.kind);
    try std.testing.expectEqual(Cue.@"error", app.queued.?.cue);

    TestRuntime.presentationFinished(&app);
    TestRuntime.flush(&app);
    try std.testing.expectEqual(@as(usize, 1), app.presentation_finished_count);
    try std.testing.expectEqual(@as(usize, 1), app.flush_count);

    TestRuntime.playCue(&app, .bloom);
    TestRuntime.playMaxCue(&app, .toggle);
    try std.testing.expectEqual(Cue.bloom, app.played_cue.?);
    try std.testing.expectEqual(Cue.toggle, app.played_max_cue.?);

    TestRuntime.dispatchAttentionRequired(&app, "background-session", 42, .permission);
    try std.testing.expectEqualStrings("background-session", app.attention_session_id.?);
    try std.testing.expectEqual(@as(u64, 42), app.attention_turn_id.?);
    try std.testing.expectEqual(hooks.AttentionKind.permission, app.attention_kind.?);
}
