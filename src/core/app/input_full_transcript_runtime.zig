const std = @import("std");
const host = @import("../hosts/host.zig");
const runtime_profile = @import("../hosts/runtime_profile.zig");
const app_lifecycle = @import("app_lifecycle.zig");
const app_render_runtime = @import("app_render_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const input_action = @import("../input/input_action.zig");
const transcript_presentation = @import("../output/transcript_presentation.zig");
const types = @import("../shared/types.zig");
const interaction_state = @import("../../ui/footer/interaction_state.zig");
const approval_prompt = @import("../permissions/approval_prompt.zig");
const subagent_runtime = @import("../../ui/subagent/runtime.zig");
const shell_runtime = @import("../../ui/shell_runtime.zig");
const full_transcript_screen = @import("../../ui/full_transcript_screen.zig");
const render_request = @import("../../ui/render_request.zig");
const transcript_runtime = @import("../../ui/transcript/runtime.zig");

pub fn Runtime(comptime App: type) type {
    return struct {
        const FullTranscriptKey = union(enum) {
            toggle,
            navigate: transcript_presentation.Event,
            close,
            interrupt,
            subagent_manager,
            redraw,
            wheel_scroll: input_action.MouseWheel,
            page_scroll: input_action.MouseWheel,
            pointer: input_action.MousePointer,
        };

        fn requestActiveSurfaceFrame(app: *App) void {
            app_render_runtime.Runtime(App).requestActiveSurfaceFrame(app, .modal);
        }

        fn screenOwnsInput(app: *App) bool {
            if (comptime !@hasField(App, "terminal")) return false;
            if (approvalOwnsCurrentSurface(app)) return false;
            if (app.terminal.fullTranscriptScreenActive()) return true;
            return childFullTranscriptRequested(app);
        }

        fn approvalOwnsCurrentSurface(app: *const App) bool {
            if (!app.approval_prompt.isActive()) return false;
            if (comptime !@hasField(App, "subagents")) return true;
            if (comptime !@hasDecl(
                @TypeOf(app.subagents),
                "childRouteId",
            )) return true;
            if (!app.subagents.isViewActive() or
                app.subagents.childRouteId() == null)
            {
                return true;
            }
            return selectedChildApprovalOwnsSurface(app);
        }

        pub fn routeByte(app: *App, byte: u8) !bool {
            const key = keyForByte(byte) orelse return false;
            if (!screenOwnsInput(app)) return false;
            try routeKey(app, key);
            return true;
        }

        pub fn routeAction(app: *App, resolved: input_action.Action) !bool {
            const key = keyForAction(resolved) orelse return false;
            switch (key) {
                .toggle => if (childRouteActive(app)) {
                    if (selectedChildApprovalOwnsSurface(app)) return false;
                    try routeKey(app, key);
                    return true;
                },
                else => {},
            }
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
                else => false,
            };
        }

        fn transitionScreen(
            app: *App,
            event: transcript_presentation.Event,
        ) !void {
            if (childRouteActive(app)) {
                const from = childPresentationDepth(app);
                const to = from.transition(event);
                if (from == to) return;
                if (comptime @hasDecl(
                    @TypeOf(app.subagents),
                    "setChildTranscriptPresentationDepth",
                )) {
                    _ = try app.subagents.setChildTranscriptPresentationDepth(
                        app.alloc,
                        to,
                    );
                } else if (childPresentationShell(app)) |child| {
                    _ = try child.setTranscriptPresentationDepth(app.alloc, to);
                }
                logDepthTransition(from, to, .child, triggerForEvent(event));
                requestActiveSurfaceFrame(app);
                return;
            }
            if (comptime !@hasField(App, "terminal")) {
                _ = try app.transitionFullTranscriptProjection(event);
                return;
            }

            const from = app.shell.transcriptPresentationDepth();
            const to = from.transition(event);
            if (from == to) return;
            if (from == .inline_mode) {
                std.debug.assert(to == .review);
                if (app.terminal.alternate_screen_owner != .none) return;
                if (app.approval_prompt.isActive()) return;
                try app_lifecycle.openFullTranscript(
                    app.alloc,
                    &app.terminal,
                    &app.shell,
                    &app.metrics,
                );
                requestActiveSurfaceFrame(app);
            } else if (to == .inline_mode) {
                try app_lifecycle.closeFullTranscript(
                    app.alloc,
                    &app.terminal,
                    &app.shell,
                    &app.metrics,
                );
            } else {
                const changed = try app.shell.setTranscriptPresentationDepth(app.alloc, to);
                debug_trace.logf(
                    "full_transcript",
                    "depth_set to={s} changed={} depth_after_set={s}",
                    .{ depthName(to), changed, depthName(app.shell.transcriptPresentationDepth()) },
                );
                requestActiveSurfaceFrame(app);
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
            if (childRouteActive(app)) {
                const from = childPresentationDepth(app);
                if (comptime @hasDecl(
                    @TypeOf(app.subagents),
                    "closeChildTranscriptPresentation",
                )) {
                    _ = try app.subagents.closeChildTranscriptPresentation(app.alloc);
                } else if (childPresentationShell(app)) |child| {
                    _ = try child.setTranscriptPresentationDepth(app.alloc, .inline_mode);
                }
                logDepthTransition(from, .inline_mode, .child, trigger);
                requestActiveSurfaceFrame(app);
                return;
            }
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
                24 => .subagent_manager,
                else => null,
            };
        }

        fn keyForAction(resolved: input_action.Action) ?FullTranscriptKey {
            return switch (resolved) {
                .toggle_full_transcript => .toggle,
                .cursor_left => .{ .navigate = .left },
                .cursor_right => .{ .navigate = .right },
                .escape => .close,
                .mouse_wheel => |direction| .{ .wheel_scroll = direction },
                .mouse_pointer => |pointer| .{ .pointer = pointer },
                .page_up => .{ .page_scroll = .up },
                .page_down => .{ .page_scroll = .down },
                .composer_shortcut => |shortcut| switch (shortcut) {
                    .redraw => .redraw,
                    else => null,
                },
                .remapped_byte => |byte| switch (byte) {
                    3 => .interrupt,
                    12 => .redraw,
                    24 => .subagent_manager,
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
                .subagent_manager => {
                    if (comptime runtime_profile.allows(App, .subagents) and
                        @hasDecl(App, "writeSubagentSnapshot"))
                    {
                        try app.writeSubagentSnapshot();
                    }
                },
                .redraw => {},
                .wheel_scroll => |direction| {
                    if (childRouteActive(app)) {
                        if (childPresentationShell(app)) |child| {
                            child.scrollFullTranscript(direction, .wheel);
                        }
                    } else {
                        app.shell.scrollFullTranscript(direction, .wheel);
                    }
                    requestActiveSurfaceFrame(app);
                },
                .page_scroll => |direction| {
                    if (childRouteActive(app)) {
                        if (childPresentationShell(app)) |child| {
                            child.scrollFullTranscript(direction, .page);
                        }
                    } else {
                        app.shell.scrollFullTranscript(direction, .page);
                    }
                    requestActiveSurfaceFrame(app);
                },
                .pointer => |pointer| try routeCodeCopyPointer(app, pointer),
            }
        }

        fn routeCodeCopyPointer(
            app: *App,
            pointer: input_action.MousePointer,
        ) !void {
            if (pointer.kind != .press or pointer.shift or pointer.alt or pointer.ctrl) return;
            if (childRouteActive(app)) {
                const child = childPresentationShell(app) orelse return;
                return activateCodeCopyPointer(app, child, pointer);
            }
            if (comptime @hasDecl(@TypeOf(app.shell), "codeCopyHit") and
                @hasDecl(@TypeOf(app.shell), "assistantCodeBlockSource"))
            {
                return activateCodeCopyPointer(app, &app.shell, pointer);
            }
        }

        fn activateCodeCopyPointer(
            app: *App,
            active_shell: anytype,
            pointer: input_action.MousePointer,
        ) !void {
            const entry_id = active_shell.codeCopyHit(
                pointer.row,
                pointer.column,
            ) orelse return;
            const code = active_shell.assistantCodeBlockSource(entry_id) orelse {
                debug_trace.logf(
                    "full_transcript",
                    "code_copy_target_stale entry_id={d}",
                    .{entry_id},
                );
                return;
            };
            const copied = if (comptime @hasDecl(App, "clipboard"))
                app.clipboard().copy(code) catch |err| failed: {
                    debug_trace.logf(
                        "full_transcript",
                        "code_copy_failed entry_id={d} err={s}",
                        .{ entry_id, @errorName(err) },
                    );
                    break :failed false;
                }
            else
                false;

            try closeScreen(app, .code_copy);
            if (copied) return;
            _ = try active_shell.appendSemanticNotice(app.alloc, .{
                .topic = "clipboard",
                .tone = .@"error",
                .body = "Failed to copy code block to clipboard.",
            });
            requestActiveSurfaceFrame(app);
        }

        fn childPresentationShell(
            app: *App,
        ) ?*transcript_runtime.TranscriptRuntime {
            if (comptime !@hasField(App, "subagents")) return null;
            if (comptime !@hasDecl(
                @TypeOf(app.subagents),
                "childRouteId",
            )) return null;
            if (comptime !@hasDecl(
                @TypeOf(app.subagents),
                "childConversationRuntime",
            )) return null;
            if (!app.subagents.isViewActive()) return null;
            if (app.subagents.childRouteId() == null) return null;
            return app.subagents.childConversationRuntime();
        }

        fn childRouteActive(app: *App) bool {
            if (comptime !@hasField(App, "subagents")) return false;
            if (comptime !@hasDecl(
                @TypeOf(app.subagents),
                "childRouteId",
            )) return false;
            return app.subagents.isViewActive() and
                app.subagents.childRouteId() != null;
        }

        fn selectedChildApprovalOwnsSurface(app: *const App) bool {
            if (!app.approval_prompt.isActive()) return false;
            if (comptime !@hasDecl(
                @TypeOf(app.subagents),
                "mainApprovalBinding",
            )) return false;
            const child_id = app.subagents.childRouteId() orelse return false;
            const request = app.approval_prompt.request orelse return false;
            const binding = app.subagents.mainApprovalBinding(request.id) orelse return false;
            return std.mem.eql(u8, binding.child_id, child_id);
        }

        fn childFullTranscriptRequested(app: *App) bool {
            if (!childRouteActive(app)) return false;
            if (comptime !@hasDecl(
                @TypeOf(app.subagents),
                "childFullTranscriptRequested",
            )) {
                const child = childPresentationShell(app) orelse return false;
                return child.fullTranscriptActive();
            }
            return app.subagents.childFullTranscriptRequested();
        }

        fn childPresentationDepth(
            app: *App,
        ) transcript_presentation.Depth {
            if (comptime @hasDecl(
                @TypeOf(app.subagents),
                "childTranscriptPresentationDepth",
            )) {
                return app.subagents.childTranscriptPresentationDepth();
            }
            const child = childPresentationShell(app) orelse return .inline_mode;
            return child.transcriptPresentationDepth();
        }

        const TransitionRoute = enum { root, child };
        const TransitionTrigger = enum { ctrl_o, left, right, escape, ctrl_c, code_copy };

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
                .review => "review",
                .full => "full",
            };
        }
    };
}

const ApprovalRoutingSubagents = struct {
    depth: transcript_presentation.Depth = .review,
    selected_child_id: []const u8 = "child-one",
    approval_child_id: []const u8 = "child-one",

    pub fn isViewActive(_: *const ApprovalRoutingSubagents) bool {
        return true;
    }

    pub fn childRouteId(self: *const ApprovalRoutingSubagents) ?[]const u8 {
        return self.selected_child_id;
    }

    pub fn childTranscriptPresentationDepth(
        self: *const ApprovalRoutingSubagents,
    ) transcript_presentation.Depth {
        return self.depth;
    }

    pub fn setChildTranscriptPresentationDepth(
        self: *ApprovalRoutingSubagents,
        _: std.mem.Allocator,
        requested: transcript_presentation.Depth,
    ) !transcript_presentation.Depth {
        self.depth = requested;
        return self.depth;
    }

    pub fn mainApprovalBinding(
        self: *const ApprovalRoutingSubagents,
        prompt_id: u64,
    ) ?subagent_runtime.MainApprovalBinding {
        if (prompt_id != 77) return null;
        return .{ .child_id = self.approval_child_id, .approval_id = "approval-one" };
    }

    pub fn childFullTranscriptRequested(
        self: *const ApprovalRoutingSubagents,
    ) bool {
        return self.depth.active();
    }
};

const ApprovalRoutingApp = struct {
    alloc: std.mem.Allocator,
    approval_prompt: approval_prompt.ApprovalPrompt = .{},
    approval_screen: interaction_state.ApprovalScreenState = .{},
    metrics: types.Metrics = .{},
    subagents: ApprovalRoutingSubagents = .{},
    shell: transcript_runtime.TranscriptRuntime = .{},
    terminal: shell_runtime.TerminalState = .{
        .alternate_screen_owner = .full_transcript,
    },

    fn deinit(self: *ApprovalRoutingApp) void {
        self.approval_prompt.deinit(self.alloc);
        self.shell.deinit(self.alloc);
    }

    pub fn transitionFullTranscriptProjection(
        _: *ApprovalRoutingApp,
        event: transcript_presentation.Event,
    ) !transcript_presentation.Depth {
        return transcript_presentation.Depth.inline_mode.transition(
            event,
        );
    }
};

test "full transcript owns raw semantic and remapped ctrl-l" {
    const alloc = std.testing.allocator;
    const runtime = Runtime(ApprovalRoutingApp);
    var app = ApprovalRoutingApp{ .alloc = alloc };
    defer app.deinit();

    try std.testing.expect(try runtime.routeByte(&app, 12));
    try std.testing.expect(try runtime.routeAction(&app, .{
        .composer_shortcut = .redraw,
    }));
    try std.testing.expect(try runtime.routeAction(&app, .{
        .remapped_byte = 12,
    }));
    try std.testing.expectEqual(
        transcript_presentation.Depth.review,
        app.subagents.depth,
    );
}

test "selected child approval owns ctrl-o ahead of transcript depth" {
    const alloc = std.testing.allocator;
    var app = ApprovalRoutingApp{ .alloc = alloc };
    defer app.deinit();
    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{
        .id = 77,
        .label = "terminal.exec npm test",
    }));

    _ = try Runtime(ApprovalRoutingApp).routeAction(
        &app,
        .toggle_full_transcript,
    );

    try std.testing.expectEqual(
        transcript_presentation.Depth.review,
        app.subagents.depth,
    );
    try std.testing.expect(app.approval_prompt.isActive());
}

test "approval for another child does not steal selected child transcript input" {
    const alloc = std.testing.allocator;
    var app = ApprovalRoutingApp{ .alloc = alloc };
    defer app.deinit();
    app.subagents.approval_child_id = "child-two";
    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{
        .id = 77,
        .label = "terminal.exec npm test",
    }));

    try std.testing.expect(!Runtime(ApprovalRoutingApp).approvalOwnsCurrentSurface(&app));

    app.subagents.approval_child_id = "child-one";
    try std.testing.expect(Runtime(ApprovalRoutingApp).approvalOwnsCurrentSurface(&app));
}

const CodeCopyTestClipboard = struct {
    succeed: bool = true,
    copied: std.ArrayList(u8) = .empty,

    fn deinit(self: *CodeCopyTestClipboard, alloc: std.mem.Allocator) void {
        self.copied.deinit(alloc);
    }

    fn clipboard(self: *CodeCopyTestClipboard) host.Clipboard {
        return .{ .context = self, .copy_fn = copy };
    }

    fn copy(raw_context: ?*anyopaque, bytes: []const u8) host.ClipboardError!bool {
        const self: *CodeCopyTestClipboard = @ptrCast(@alignCast(raw_context.?));
        self.copied.clearRetainingCapacity();
        self.copied.appendSlice(std.testing.allocator, bytes) catch return error.CopyFailed;
        return self.succeed;
    }
};

const CodeCopyRoutingSubagents = struct {
    active: bool = false,
    child: transcript_runtime.TranscriptRuntime = .{},

    fn deinit(self: *CodeCopyRoutingSubagents, alloc: std.mem.Allocator) void {
        self.child.deinit(alloc);
    }

    pub fn isViewActive(self: *const CodeCopyRoutingSubagents) bool {
        return self.active;
    }

    pub fn childRouteId(self: *const CodeCopyRoutingSubagents) ?[]const u8 {
        return if (self.active) "child-one" else null;
    }

    pub fn childConversationRuntime(
        self: *CodeCopyRoutingSubagents,
    ) ?*transcript_runtime.TranscriptRuntime {
        return if (self.active) &self.child else null;
    }

    pub fn childFullTranscriptRequested(self: *const CodeCopyRoutingSubagents) bool {
        return self.active and self.child.fullTranscriptActive();
    }

    pub fn childTranscriptPresentationDepth(
        self: *const CodeCopyRoutingSubagents,
    ) transcript_presentation.Depth {
        return if (self.active)
            self.child.transcriptPresentationDepth()
        else
            .inline_mode;
    }

    pub fn closeChildTranscriptPresentation(
        self: *CodeCopyRoutingSubagents,
        alloc: std.mem.Allocator,
    ) !bool {
        if (!self.active) return false;
        return self.child.setTranscriptPresentationDepth(alloc, .inline_mode);
    }

    pub fn activeRenderRequests(
        self: *CodeCopyRoutingSubagents,
    ) *render_request.RenderRequestState {
        return &self.child.render_requests;
    }
};

const CodeCopyRoutingApp = struct {
    alloc: std.mem.Allocator,
    metrics: types.Metrics = .{},
    approval_prompt: approval_prompt.ApprovalPrompt = .{},
    terminal: shell_runtime.TerminalState = .{},
    shell: transcript_runtime.TranscriptRuntime = .{},
    subagents: CodeCopyRoutingSubagents = .{},
    clipboard_state: CodeCopyTestClipboard = .{},

    fn deinit(self: *CodeCopyRoutingApp) void {
        self.clipboard_state.deinit(self.alloc);
        self.subagents.deinit(self.alloc);
        self.shell.deinit(self.alloc);
        self.approval_prompt.deinit(self.alloc);
    }

    pub fn clipboard(self: *CodeCopyRoutingApp) host.Clipboard {
        return self.clipboard_state.clipboard();
    }
};

fn prepareCodeCopyRoute(
    alloc: std.mem.Allocator,
    runtime: *transcript_runtime.TranscriptRuntime,
) !void {
    runtime.layout = .{
        .rows = 12,
        .cols = 80,
        .content_bottom = 8,
        .divider_top_row = 9,
        .input_row = 10,
        .divider_bottom_row = 11,
        .hint_row = 12,
    };
    runtime.owned_top_row = 1;
    runtime.viewport_top_row = 1;
    const language = try alloc.dupe(u8, "zig");
    var owns_language = true;
    errdefer if (owns_language) alloc.free(language);
    const code = try alloc.dupe(u8, "const copied = true;\n");
    var owns_code = true;
    errdefer if (owns_code) alloc.free(code);
    const entry_id = try runtime.appendAssistantCodeBlockOwned(alloc, .{
        .language = language,
        .code = code,
    });
    owns_language = false;
    owns_code = false;
    runtime.full_transcript = .{ .depth = .review };

    var frame: full_transcript_screen.CodeCopyInteractionFrame = .{};
    defer frame.deinit(alloc);
    try frame.targets.append(alloc, .{
        .entry_id = entry_id,
        .row = 4,
        .first_col = 70,
        .last_col = 73,
    });
    runtime.commitCodeCopyFrame(alloc, &frame);
}

fn semanticNoticeCount(runtime: *const transcript_runtime.TranscriptRuntime) usize {
    var count: usize = 0;
    for (runtime.entries.items) |entry| {
        if (entry == .semantic_notice) count += 1;
    }
    return count;
}

test "code copy closes and reports on the active transcript route" {
    const alloc = std.testing.allocator;
    const Route = enum { root, child };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    for ([_]Route{ .root, .child }) |route| {
        for ([_]bool{ true, false }) |copy_succeeds| {
            const out_file = try tmp.dir.createFile(
                @import("../shared/io.zig").getIo(),
                "code-copy-route.out",
                .{ .truncate = true },
            );
            var app = CodeCopyRoutingApp{ .alloc = alloc };
            defer app.deinit();
            app.shell.stdout_file = out_file;
            defer app.shell.stdout_file.close(@import("../shared/io.zig").getIo());
            app.clipboard_state.succeed = copy_succeeds;

            const active = switch (route) {
                .root => &app.shell,
                .child => blk: {
                    app.subagents.active = true;
                    break :blk &app.subagents.child;
                },
            };
            try prepareCodeCopyRoute(alloc, active);
            if (route == .root) {
                app.terminal.alternate_screen_owner = .full_transcript;
            }

            try std.testing.expect(try Runtime(CodeCopyRoutingApp).routeAction(
                &app,
                .{ .mouse_pointer = .{
                    .kind = .press,
                    .column = 71,
                    .row = 4,
                } },
            ));

            try std.testing.expectEqualStrings(
                "const copied = true;\n",
                app.clipboard_state.copied.items,
            );
            try std.testing.expectEqual(
                transcript_presentation.Depth.inline_mode,
                active.transcriptPresentationDepth(),
            );
            try std.testing.expectEqual(
                @as(usize, @intFromBool(!copy_succeeds)),
                semanticNoticeCount(active),
            );
            if (!copy_succeeds) {
                const notice = active.entries.items[active.entries.items.len - 1].semantic_notice;
                try std.testing.expectEqualStrings(
                    "Failed to copy code block to clipboard.",
                    notice.body,
                );
            }

            const inactive = switch (route) {
                .root => &app.subagents.child,
                .child => &app.shell,
            };
            try std.testing.expectEqual(
                transcript_presentation.Depth.inline_mode,
                inactive.transcriptPresentationDepth(),
            );
            try std.testing.expectEqual(@as(usize, 0), semanticNoticeCount(inactive));
        }
    }
}

test "code copy ignores non-target and modified pointer actions" {
    const alloc = std.testing.allocator;
    var app = CodeCopyRoutingApp{ .alloc = alloc };
    defer app.deinit();
    app.subagents.active = true;
    try prepareCodeCopyRoute(alloc, &app.subagents.child);

    const pointers = [_]input_action.MousePointer{
        .{ .kind = .press, .column = 69, .row = 4 },
        .{ .kind = .press, .column = 74, .row = 4 },
        .{ .kind = .press, .column = 71, .row = 5 },
        .{ .kind = .drag, .column = 71, .row = 4 },
        .{ .kind = .release, .column = 71, .row = 4 },
        .{ .kind = .press, .column = 71, .row = 4, .shift = true },
        .{ .kind = .press, .column = 71, .row = 4, .alt = true },
        .{ .kind = .press, .column = 71, .row = 4, .ctrl = true },
    };
    for (pointers) |pointer| {
        try std.testing.expect(try Runtime(CodeCopyRoutingApp).routeAction(
            &app,
            .{ .mouse_pointer = pointer },
        ));
        try std.testing.expectEqual(
            transcript_presentation.Depth.review,
            app.subagents.child.transcriptPresentationDepth(),
        );
        try std.testing.expectEqual(@as(usize, 0), app.clipboard_state.copied.items.len);
    }

    var stale_frame: full_transcript_screen.CodeCopyInteractionFrame = .{};
    defer stale_frame.deinit(alloc);
    try stale_frame.targets.append(alloc, .{
        .entry_id = 999,
        .row = 4,
        .first_col = 70,
        .last_col = 73,
    });
    app.subagents.child.commitCodeCopyFrame(alloc, &stale_frame);
    try std.testing.expect(try Runtime(CodeCopyRoutingApp).routeAction(
        &app,
        .{ .mouse_pointer = .{
            .kind = .press,
            .column = 71,
            .row = 4,
        } },
    ));
    try std.testing.expectEqual(
        transcript_presentation.Depth.review,
        app.subagents.child.transcriptPresentationDepth(),
    );
    try std.testing.expectEqual(@as(usize, 0), app.clipboard_state.copied.items.len);
}
