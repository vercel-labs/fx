const std = @import("std");
const app_permission_runtime = @import("app_permission_runtime.zig");
const js_host_config_store = @import("../config/js_host_config_store.zig");
const mode_registry = @import("../modes/mode_registry.zig");
const runtime_profile = @import("../hosts/runtime_profile.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const session_codec = @import("../session/session_codec.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const PermissionMode = types.PermissionMode;

pub fn Runtime(comptime App: type) type {
    return struct {
        pub fn restore(app: *App, modes: mode_registry.Registry) !void {
            if (comptime !runtime_profile.allows(App, .js_host_config)) return;

            if (try loadValue(app, "model")) |model| {
                defer app.alloc.free(model);
                if (session_codec.validateModelPreference(model)) |_| {
                    app.selected_model.clearRetainingCapacity();
                    try app.selected_model.appendSlice(app.alloc, model);
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
                    app_permission_runtime.Runtime(App).setMode(app, mode.permission_mode);
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

fn configIdForPermissionMode(mode: PermissionMode) []const u8 {
    return switch (mode) {
        .auto => "code",
        .ask => "ask",
        // The host persists product mode IDs. Yolo has no product mode, so its
        // non-interactive behavior restores through the closest mode, code.
        .yolo => "code",
    };
}

test "host config maps permission modes to restorable product modes" {
    try std.testing.expectEqualStrings("code", configIdForPermissionMode(.auto));
    try std.testing.expectEqualStrings("ask", configIdForPermissionMode(.ask));
    try std.testing.expectEqualStrings("code", configIdForPermissionMode(.yolo));
}
