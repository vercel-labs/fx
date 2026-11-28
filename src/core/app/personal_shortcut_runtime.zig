const std = @import("std");
const shortcut_rules = @import("../shortcuts/shortcuts.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const profile_shortcuts = @import("../config/profile_shortcuts.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const provider_runtime = @import("provider_runtime.zig");
const session_commands = @import("../session/session_commands.zig");

/// The personal shortcut map held by the app, and the profile stamp it was
/// read at. Input and render only read `map`; `reloadAfterTurn` replaces it.
pub const State = struct {
    map: shortcut_rules.Map = .{},
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

/// The one-line transcript notice for a profile edit that did not apply. It
/// names the failing chord when the parser found one. `active` is how many
/// shortcuts the app keeps; the notice says they stay active only when there
/// are some.
pub fn formatInvalidNotice(writer: *std.Io.Writer, invalid: profile_shortcuts.Invalid, active: usize) !void {
    const outcome: []const u8 = if (active == 0) "no shortcuts are active" else "your previous shortcuts stay active";
    if (invalid.chord().len == 0) {
        return writer.print("profile shortcuts could not be read; {s}", .{outcome});
    }
    try writer.print("profile shortcut \"{s}\" is invalid; {s}", .{ invalid.chord(), outcome });
}

test "invalid profile notice names the chord and keeps the previous shortcuts" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var named: profile_shortcuts.Invalid = .{};
    @memcpy(named.chord_bytes[0..14], "ctrl+not-a-key");
    named.chord_len = 14;
    try formatInvalidNotice(&writer, named, 1);
    try std.testing.expectEqualStrings(
        "profile shortcut \"ctrl+not-a-key\" is invalid; your previous shortcuts stay active",
        writer.buffered(),
    );

    var unnamed: std.Io.Writer = .fixed(&buffer);
    try formatInvalidNotice(&unnamed, .{}, 2);
    try std.testing.expectEqualStrings(
        "profile shortcuts could not be read; your previous shortcuts stay active",
        unnamed.buffered(),
    );
}

test "invalid profile notice never claims previous shortcuts when none are active" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var named: profile_shortcuts.Invalid = .{};
    @memcpy(named.chord_bytes[0..14], "ctrl+not-a-key");
    named.chord_len = 14;
    try formatInvalidNotice(&writer, named, 0);
    try std.testing.expectEqualStrings(
        "profile shortcut \"ctrl+not-a-key\" is invalid; no shortcuts are active",
        writer.buffered(),
    );

    var unnamed: std.Io.Writer = .fixed(&buffer);
    try formatInvalidNotice(&unnamed, .{}, 0);
    try std.testing.expectEqualStrings(
        "profile shortcuts could not be read; no shortcuts are active",
        unnamed.buffered(),
    );
}

test "reconcile clears only on a real absence and keeps the last good map" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"alt+m\":\"/model\"}", .{});
    defer parsed.deinit();
    const map = try shortcut_rules.parseJsonObject(parsed.value);

    var first = std.mem.zeroes(profile_shortcuts.Stamp);
    first.size = 1;
    var second = first;
    second.size = 2;

    var state: State = .{};
    reconcile(&state, first, .{ .loaded = map });
    try std.testing.expect(state.map.find(shortcut_rules.Chord.parse("alt+m").?) != null);
    try std.testing.expectEqual(first.size, state.stamp.?.size);

    reconcile(&state, second, .{ .invalid = .{} });
    try std.testing.expect(state.map.find(shortcut_rules.Chord.parse("alt+m").?) != null);
    try std.testing.expectEqual(second.size, state.stamp.?.size);

    reconcile(&state, null, .absent);
    try std.testing.expect(state.map.find(shortcut_rules.Chord.parse("alt+m").?) == null);
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
        pub fn applyPreset(app: *App, agent: *AppAgent, preset: *const shortcut_rules.Preset) !void {
            const model = preset.model();
            const facts: shortcut_rules.PresetFacts = .{
                .same_provider = provider_runtime.providerOf(app, agent).eql(preset.provider),
                .model_in_catalog = modelInCatalog(app, model),
                .effort = preset.effort,
                .fast_mode = preset.fast_mode,
            };
            const capabilities = model_capabilities.resolveForApp(App, app, model);
            if (shortcut_rules.checkPreset(facts, capabilities)) |refusal| {
                debug_trace.logf("shortcuts", "preset refused reason={s}", .{@tagName(refusal)});
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
            // A changed profile is read once, so an invalid edit is announced once.
            switch (load) {
                .invalid => |invalid| {
                    debug_trace.logf("shortcuts", "reload kept last map reason=invalid_profile", .{});
                    writeInvalidNotice(app, invalid) catch |err| {
                        debug_trace.logf("shortcuts", "invalid notice dropped err={s}", .{@errorName(err)});
                    };
                },
                .absent, .loaded => {},
            }
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

        fn writeInvalidNotice(app: *App, invalid: profile_shortcuts.Invalid) !void {
            var body: std.Io.Writer.Allocating = .init(app.alloc);
            defer body.deinit();
            try formatInvalidNotice(&body.writer, invalid, app.personal_shortcuts.map.items().len);
            const text = try body.toOwnedSlice();
            defer app.alloc.free(text);
            try app.writeDomainNotice(.{ .topic = "shortcut", .tone = .warning, .body = text }, true);
        }

        fn writeRefusal(app: *App, refusal: shortcut_rules.PresetRefusal, model: []const u8) !void {
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
