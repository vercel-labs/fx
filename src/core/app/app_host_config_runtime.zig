const std = @import("std");
const app_permission_runtime = @import("app_permission_runtime.zig");
const provider_runtime = @import("provider_runtime.zig");
const config_runtime = @import("../config/config_runtime.zig");
const js_host_config_store = @import("../config/js_host_config_store.zig");
const mode_registry = @import("../modes/mode_registry.zig");
const runtime_profile = @import("../hosts/runtime_profile.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const session_codec = @import("../session/session_codec.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const PermissionMode = types.PermissionMode;

/// What a user preferences write did for an app's runtime profile.
pub const UserPreferenceAttempt = union(enum) {
    /// The profile keeps preferences in its JS host's config store and has
    /// no settings file, so nothing was written and nothing failed.
    host_owned,
    outcome: config_runtime.CommitOutcome,
    failure: config_runtime.CommitFailure,

    pub fn deinit(self: *UserPreferenceAttempt, alloc: Allocator) void {
        switch (self.*) {
            .host_owned => {},
            .outcome => |*outcome| outcome.deinit(alloc),
            .failure => |*failure| failure.deinit(alloc),
        }
        self.* = undefined;
    }
};

/// Saves user preferences for an app of type `App`. A JS host profile keeps
/// them in the host's config store and has no settings file, so it returns
/// `.host_owned` without looking for a home, even when the host passes HOME
/// (`tests/tla/host_config/HostPreferences.tla` HostProfileQuiet,
/// HostNeverTouchesHome). Other profiles write ~/.fx/settings.json.
pub fn attemptUserPreferences(
    comptime App: type,
    alloc: Allocator,
    patch: config_runtime.UserSettingsPatch,
) UserPreferenceAttempt {
    if (comptime runtime_profile.allows(App, .js_host_config)) {
        // The host store keeps only the model and the permission mode; any
        // other preference lasts for this process alone.
        debug_trace.logf("host_config", "user_settings_write_skipped reason=host_owned", .{});
        return .host_owned;
    }
    return switch (config_runtime.attemptUserPreferences(alloc, patch)) {
        .outcome => |outcome| .{ .outcome = outcome },
        .failure => |failure| .{ .failure = failure },
    };
}

pub fn Runtime(comptime App: type) type {
    return struct {
        const AppAgent = if (@hasField(App, "main_agent")) @FieldType(App, "main_agent") else struct {};
        pub fn restore(app: *App, agent: *AppAgent, modes: mode_registry.Registry) !void {
            if (comptime !runtime_profile.allows(App, .js_host_config)) return;

            if (try loadValue(app, "model")) |model| {
                defer app.alloc.free(model);
                if (session_codec.validateModelPreference(model)) |_| {
                    try provider_runtime.replaceModel(app, model);
                    try agent.worker.syncQueuedPromptModel(std.heap.c_allocator, model);
                } else |err| {
                    debug_trace.logf(
                        "host_config",
                        "restore_ignored id=model reason=invalid_value err={s}",
                        .{@errorName(err)},
                    );
                }
            }

            if (try loadValue(app, "mode")) |mode_id| {
                defer app.alloc.free(mode_id);
                if (modes.lookup(mode_id)) |mode| {
                    app_permission_runtime.Runtime(App).setMode(app, agent, mode.permission_mode);
                } else {
                    debug_trace.logf(
                        "host_config",
                        "restore_ignored id=mode reason=unknown_value",
                        .{},
                    );
                }
            }
        }

        fn loadValue(app: *App, id: []const u8) Allocator.Error!?[]u8 {
            return js_host_config_store.load(app.alloc, id) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.ValueTooLarge, error.HostFailure => {
                    debug_trace.logf(
                        "host_config",
                        "restore_ignored id={s} reason=load_failed err={s}",
                        .{ id, @errorName(err) },
                    );
                    return null;
                },
            };
        }

        pub fn persistModel(_: *App, model: []const u8) void {
            if (comptime !runtime_profile.allows(App, .js_host_config)) return;
            persist("model", model);
        }

        pub fn persistPermissionMode(_: *App, mode: PermissionMode) void {
            if (comptime !runtime_profile.allows(App, .js_host_config)) return;
            persist("mode", configIdForPermissionMode(mode));
        }
    };
}

fn persist(id: []const u8, value: []const u8) void {
    js_host_config_store.setAccepted(id, value) catch |err| {
        debug_trace.logf(
            "host_config",
            "persist_ignored id={s} reason=host_failure err={s}",
            .{ id, @errorName(err) },
        );
    };
}

/// The host persists product mode IDs, which are the CLI's permission modes.
fn configIdForPermissionMode(mode: PermissionMode) []const u8 {
    return switch (mode) {
        .auto => "auto",
        .ask => "ask",
        .yolo => "full-access",
    };
}

test "a js-host profile owns user preferences and leaves the settings file alone" {
    const io = io_mod.getIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "home/.fx");
    const home = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "home");
    defer std.testing.allocator.free(home);
    // A host that passes HOME must not make fx write there either.
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("HOME", home);
    io_mod.setEnvironMap(&environ);
    defer io_mod.resetEnvironForTest();

    const HostApp = struct {
        pub const host_profile = runtime_profile.wasm;
    };
    const NativeApp = struct {
        pub const host_profile = runtime_profile.native;
    };

    var hosted = attemptUserPreferences(HostApp, std.testing.allocator, .{ .startup_scrollback = false });
    defer hosted.deinit(std.testing.allocator);
    try std.testing.expect(hosted == .host_owned);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "home/.fx/settings.json", .{}));

    var native = attemptUserPreferences(NativeApp, std.testing.allocator, .{ .startup_scrollback = false });
    defer native.deinit(std.testing.allocator);
    try std.testing.expect(native == .outcome);
    try tmp.dir.access(io, "home/.fx/settings.json", .{});
}

test "host config maps permission modes to restorable product modes" {
    try std.testing.expectEqualStrings("auto", configIdForPermissionMode(.auto));
    try std.testing.expectEqualStrings("ask", configIdForPermissionMode(.ask));
    try std.testing.expectEqualStrings("full-access", configIdForPermissionMode(.yolo));
}
