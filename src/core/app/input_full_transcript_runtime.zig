const std = @import("std");
const runtime_profile = @import("../hosts/runtime_profile.zig");
const app_lifecycle = @import("app_lifecycle.zig");
const app_render_runtime = @import("app_render_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const input_action = @import("../input/input_action.zig");
const transcript_presentation = @import("../output/transcript_presentation.zig");
const types = @import("../shared/types.zig");
const interaction_state = @import("../../ui/footer/interaction_state.zig");
const approval_prompt = @import("../permissions/approval_prompt.zig");
const shell_runtime = @import("../../ui/shell_runtime.zig");
const transcript_runtime = @import("../../ui/transcript/runtime.zig");

pub fn Runtime(comptime App: type) type {
    return struct {
        const FullTranscriptKey = union(enum) {
            toggle,
            navigate: transcript_presentation.Event,
            close,
            interrupt,
            redraw,
            wheel_scroll: input_action.MouseWheel,
            page_scroll: input_action.MouseWheel,
        };

        fn requestActiveSurfaceFrame(app: *App) void {
            app_render_runtime.Runtime(App).requestActiveSurfaceFrame(app, .modal);
        }

        fn screenOwnsInput(app: *App) bool {
            if (comptime !@hasField(App, "terminal")) return false;
            if (approvalOwnsCurrentSurface(app)) return false;
            return app.terminal.fullTranscriptScreenActive();
        }

        fn approvalOwnsCurrentSurface(app: *const App) bool {
            return app.approval_prompt.isActive();
        }

        pub fn routeByte(app: *App, byte: u8) !bool {
            const key = keyForByte(byte) orelse return false;
            if (!screenOwnsInput(app)) return false;
            try routeKey(app, key);
            return true;
        }

        pub fn routeAction(app: *App, resolved: input_action.Action) !bool {
            const key = keyForAction(resolved) orelse return false;
            if (!screenOwnsInput(app)) return false;
            try routeKey(app, key);
            return true;
        }

        pub fn routeComposerAction(app: *App, resolved: input_action.Action) !bool {
            return switch (keyForAction(resolved) orelse return false) {
                .toggle => {
                    try transitionScreen(app, .toggle);
                    return true;
                },
                .close => {
                    if (comptime @hasDecl(
                        @TypeOf(app.shell),
                        "cancelPendingFullTranscriptOpen",
                    )) {
                        if (app.shell.cancelPendingFullTranscriptOpen()) return true;
                    }
                    return false;
                },
                else => false,
            };
        }

        pub fn cancelPendingOpenForInput(app: *App) bool {
            if (comptime @hasDecl(
                @TypeOf(app.shell),
                "cancelPendingFullTranscriptOpen",
            )) {
                return app.shell.cancelPendingFullTranscriptOpen();
            }
            return false;
        }

        fn transitionScreen(
            app: *App,
            event: transcript_presentation.Event,
        ) !void {
            if (comptime !@hasField(App, "terminal")) {
                _ = try app.transitionFullTranscriptProjection(event);
                return;
            }

            const from = app.shell.transcriptPresentationDepth();
            const to = from.transition(event);
            if (from == to) return;
            if (from == .inline_mode) {
                std.debug.assert(to == .full);
                if (app.terminal.alternate_screen_owner != .none) return;
                if (app.approval_prompt.isActive()) return;
                if (comptime @hasDecl(
                    @TypeOf(app.shell),
                    "requestFullTranscriptOpen",
                )) {
                    if (!app.shell.requestFullTranscriptOpen()) return;
                }
                try app_lifecycle.openFullTranscript(
                    app.alloc,
                    &app.terminal,
                    &app.shell,
                    &app.metrics,
                );
                requestActiveSurfaceFrame(app);
            } else {
                std.debug.assert(to == .inline_mode);
                try app_lifecycle.closeFullTranscript(
                    app.alloc,
                    &app.terminal,
                    &app.shell,
                    &app.metrics,
                );
            }
            logDepthTransition(
                from,
                app.shell.transcriptPresentationDepth(),
                .root,
                triggerForEvent(event),
            );
        }

        fn closeScreen(app: *App, trigger: TransitionTrigger) !void {
            debug_trace.logf(
                "full_transcript",
                "close_screen trigger={s}",
                .{@tagName(trigger)},
            );
            if (comptime !@hasField(App, "terminal")) return;
            const from = app.shell.transcriptPresentationDepth();
            if (!from.active()) return;
            try app_lifecycle.closeFullTranscript(
                app.alloc,
                &app.terminal,
                &app.shell,
                &app.metrics,
            );
            logDepthTransition(from, .inline_mode, .root, trigger);
        }

        fn keyForByte(byte: u8) ?FullTranscriptKey {
            return switch (byte) {
                3 => .interrupt,
                12 => .redraw,
                24 => null,
                else => null,
            };
        }

        fn keyForAction(resolved: input_action.Action) ?FullTranscriptKey {
            return switch (resolved) {
                .toggle_full_transcript => .toggle,
                .cursor_left => .{ .navigate = .left },
                .cursor_right => .{ .navigate = .right },
                .cursor_up => .{ .wheel_scroll = .up },
                .cursor_down => .{ .wheel_scroll = .down },
                .escape => .close,
                .mouse_wheel => |direction| .{ .wheel_scroll = direction },
                .page_up => .{ .page_scroll = .up },
                .page_down => .{ .page_scroll = .down },
                .composer_shortcut => |shortcut| switch (shortcut) {
                    .redraw => .redraw,
                    else => null,
                },
                .remapped_byte => |byte| switch (byte) {
                    3 => .interrupt,
                    12 => .redraw,
                    24 => null,
                    else => null,
                },
                else => null,
            };
        }

        fn routeKey(app: *App, key: FullTranscriptKey) !void {
            switch (key) {
                .toggle => try transitionScreen(app, .toggle),
                .navigate => |event| try transitionScreen(app, event),
                .close => try closeScreen(app, .escape),
                .interrupt => try closeScreen(app, .ctrl_c),
                .redraw => {},
                .wheel_scroll => |direction| {
                    app.shell.scrollFullTranscript(direction, .wheel);
                    requestActiveSurfaceFrame(app);
                },
                .page_scroll => |direction| {
                    app.shell.scrollFullTranscript(direction, .page);
                    requestActiveSurfaceFrame(app);
                },
            }
        }

        const TransitionRoute = enum { root };
        const TransitionTrigger = enum { ctrl_o, left, right, escape, ctrl_c };

        fn triggerForEvent(
            event: transcript_presentation.Event,
        ) TransitionTrigger {
            return switch (event) {
                .toggle => .ctrl_o,
                .left => .left,
                .right => .right,
            };
        }

        fn logDepthTransition(
            from: transcript_presentation.Depth,
            to: transcript_presentation.Depth,
            route: TransitionRoute,
            trigger: TransitionTrigger,
        ) void {
            debug_trace.logf(
                "full_transcript",
                "depth_transition from={s} to={s} route={s} trigger={s}",
                .{ depthName(from), depthName(to), @tagName(route), @tagName(trigger) },
            );
        }

        fn depthName(depth: transcript_presentation.Depth) []const u8 {
            return switch (depth) {
                .inline_mode => "inline",
                .full => "full",
            };
        }
    };
}
