const std = @import("std");
const shortcut_map = @import("../config/shortcut_map.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const profile_shortcuts = @import("../config/profile_shortcuts.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const personal_shortcut_check = @import("personal_shortcut_check.zig");
const provider_runtime = @import("provider_runtime.zig");
const session_commands = @import("../session/session_commands.zig");

/// The personal shortcut map held by the app, and the profile stamp it was
/// read at. Input and render only read `map`; `reloadAfterTurn` replaces it.
pub const State = struct {
    map: shortcut_map.Map = .{},
    stamp: ?profile_shortcuts.Stamp = null,
};

/// Applies one turn-end read. Only a real absence clears the map; an invalid
/// profile keeps the last good map and records the stamp, so the same broken
/// bytes are not parsed again until the profile changes.
pub fn reconcile(state: *State, stamp: ?profile_shortcuts.Stamp, load: profile_shortcuts.Load) void {
    switch (load) {
        .absent => state.map = .{},
        .loaded => |map| state.map = map,
        .invalid => {},
    }
    state.stamp = stamp;
}

test "reconcile clears only on a real absence and keeps the last good map" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"alt+m\":{\"action\":\"open_model_picker\"}}", .{});
    defer parsed.deinit();
    const map = try shortcut_map.parseJsonObject(parsed.value);

    var first = std.mem.zeroes(profile_shortcuts.Stamp);
    first.size = 1;
    var second = first;
    second.size = 2;

    var state: State = .{};
    reconcile(&state, first, .{ .loaded = map });
    try std.testing.expect(state.map.find(shortcut_map.Chord.parse("alt+m").?) != null);
    try std.testing.expectEqual(first.size, state.stamp.?.size);

    reconcile(&state, second, .invalid);
    try std.testing.expect(state.map.find(shortcut_map.Chord.parse("alt+m").?) != null);
    try std.testing.expectEqual(second.size, state.stamp.?.size);

    reconcile(&state, null, .absent);
    try std.testing.expect(state.map.find(shortcut_map.Chord.parse("alt+m").?) == null);
    try std.testing.expectEqual(@as(?profile_shortcuts.Stamp, null), state.stamp);
}

/// Applies a saved `select_model` preset to the agent on screen, and reloads
/// the profile's shortcut map after a turn.
pub fn Runtime(comptime App: type) type {
    const AppAgent = if (@hasField(App, "main_agent")) @FieldType(App, "main_agent") else struct {};
    const Commands = session_commands.Commands(App);

    return struct {
        /// Validates the preset, then applies it through the picker's path.
        /// A refused preset leaves the model, effort, speed, and draft as they were.
        pub fn applyPreset(app: *App, agent: *AppAgent, preset: *const shortcut_map.Preset) !void {
            const model = preset.model();
            const facts: personal_shortcut_check.Facts = .{
                .same_provider = provider_runtime.providerOf(app, agent).eql(preset.provider),
                .model_in_catalog = modelInCatalog(app, model),
                .effort = preset.effort,
                .fast_mode = preset.fast_mode,
            };
            const capabilities = model_capabilities.resolveForApp(App, app, model);
            if (personal_shortcut_check.check(facts, capabilities)) |refusal| {
                try writeRefusal(app, refusal, model);
                return;
            }
            try Commands.selectModelFromPicker(app, agent, model, preset.effort, preset.fast_mode, false);
            app.shell.render_requests.request(.footer);
        }

        /// Runs at a turn's end, never on a key or a frame. One stat decides
        /// whether the profile changed; only a changed profile is read, and only
        /// its `shortcuts` key. An unreadable or malformed profile keeps the last
        /// good map and is retried at the next turn end. Only a real absence clears it.
        pub fn reloadAfterTurn(app: *App) void {
            if (comptime !@hasField(App, "personal_shortcuts")) return;
            const home_dir = io_mod.homeDir() orelse return;
            const stamp = profile_shortcuts.stampOf(app.alloc, home_dir) catch |err| {
                debug_trace.logf("shortcuts", "reload kept last map stage=stat err={s}", .{@errorName(err)});
                return;
            };
            if (std.meta.eql(stamp, app.personal_shortcuts.stamp)) return;
            const load = profile_shortcuts.read(app.alloc, home_dir) catch |err| {
                debug_trace.logf("shortcuts", "reload kept last map stage=read err={s}", .{@errorName(err)});
                return;
            };
            if (load == .invalid) debug_trace.logf("shortcuts", "reload kept last map reason=invalid_profile", .{});
            reconcile(&app.personal_shortcuts, stamp, load);
        }

        /// The loaded catalog must hold the id exactly. A ranked search or a
        /// UI-filtered list can truncate or hide it, so it is not a membership
        /// check. Without a loaded catalog, no model is known to exist.
        fn modelInCatalog(app: *App, model: []const u8) bool {
            if (comptime !@hasField(App, "model_cache")) return false;
            if (comptime !@hasDecl(@TypeOf(app.model_cache), "catalogModelCompletion")) return false;
            return app.model_cache.catalogModelCompletion(model) != null;
        }

        fn writeRefusal(app: *App, refusal: personal_shortcut_check.Refusal, model: []const u8) !void {
            const reason: []const u8 = switch (refusal) {
                .provider_mismatch => "this shortcut is for another provider",
                .model_not_in_catalog => "the model is not in the catalog",
                .effort_unsupported => "that effort is not available for the model",
                .fast_unsupported => "fast mode is not available for the model",
            };
            var body: std.Io.Writer.Allocating = .init(app.alloc);
            defer body.deinit();
            try body.writer.print("{s} ({s}); nothing changed", .{ reason, model });
            const text = try body.toOwnedSlice();
            defer app.alloc.free(text);
            try app.writeDomainNotice(.{ .topic = "shortcut", .tone = .warning, .body = text }, true);
        }
    };
}
