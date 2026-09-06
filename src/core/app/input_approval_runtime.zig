const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const edit_contract = @import("../input/editor_state.zig");
const input_action = @import("../input/input_action.zig");
const input_limit_rejection = @import("../input/input_limit_rejection.zig");
const io_mod = @import("../shared/io.zig");
const approval_decision = @import("../permissions/approval_decision.zig");
const approval_screen = @import("../../ui/approval_screen.zig");
const approval_ui = @import("../../ui/footer/approval_ui.zig");
const types = @import("../shared/types.zig");
const input_interrupt_runtime = @import("input_interrupt_runtime.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const app_render_runtime = @import("app_render_runtime.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const permission_request = @import("../permissions/permission_request.zig");
const session = @import("../session/session.zig");
const interaction_state = @import("../../ui/footer/interaction_state.zig");
const approval_prompt = @import("../permissions/approval_prompt.zig");
const render_request = @import("../../ui/render_request.zig");

const ToolPermissionDecision = types.ToolPermissionDecision;

pub fn ApprovalRuntime(comptime App: type) type {
    return struct {
        const interrupt = input_interrupt_runtime.InterruptRuntime(App);

        fn requestActiveSurfaceFrame(app: *App) void {
            app_render_runtime.Runtime(App).requestActiveSurfaceFrame(app, .modal);
        }

        pub fn handlePermissionAction(
            app: *App,
            action: approval_decision.Action,
        ) !bool {
            return switch (try handlePermissionActionWithLimit(app, action, null)) {
                .consumed => true,
                .ignored => false,
                .limit_exceeded => unreachable,
            };
        }

        pub fn handlePermissionActionBounded(
            app: *App,
            action: approval_decision.Action,
            max_len: usize,
        ) !edit_contract.ByteResult {
            return handlePermissionActionWithLimit(app, action, max_len);
        }

        fn handlePermissionActionWithLimit(
            app: *App,
            action: approval_decision.Action,
            max_len: ?usize,
        ) !edit_contract.ByteResult {
            const event = try applyDecisionAction(app, action, max_len);
            switch (event) {
                .none => return .ignored,
                .redraw => {
                    requestActiveSurfaceFrame(app);
                    return .consumed;
                },
                .decision => |decision| {
                    try submitPermissionChoice(app, decision);
                    return .consumed;
                },
                .limit_exceeded => return .limit_exceeded,
            }
        }

        pub fn routeApprovalEscapeAction(
            app: *App,
            action: input_action.Action,
            focused_edit: ?approval_decision.DraftAction,
        ) !void {
            app.input_runtime.vertical_navigation.reset();
            app.input_runtime.input_limit_rejection = input_limit_rejection.clear();
            const amending = app.approval_prompt.isAmending();
            if (amending) {
                if (focused_edit) |edit| {
                    _ = try applyDecisionAction(
                        app,
                        .{ .edit_draft = edit },
                        null,
                    );
                    requestActiveSurfaceFrame(app);
                    return;
                }
            }
            switch (action) {
                .cursor_left, .word_left => {
                    if (!amending) {
                        _ = try applyDecisionAction(
                            app,
                            .{ .move_choice = .previous },
                            null,
                        );
                        requestActiveSurfaceFrame(app);
                    }
                },
                .cursor_right, .word_right => {
                    if (!amending) {
                        _ = try applyDecisionAction(
                            app,
                            .{ .move_choice = .next },
                            null,
                        );
                        requestActiveSurfaceFrame(app);
                    }
                },
                .history_up, .cursor_up => {
                    _ = try applyDecisionAction(
                        app,
                        .{ .move_choice = .previous },
                        null,
                    );
                    requestActiveSurfaceFrame(app);
                },
                .history_down, .cursor_down => {
                    _ = try applyDecisionAction(
                        app,
                        .{ .move_choice = .next },
                        null,
                    );
                    requestActiveSurfaceFrame(app);
                },
                .mouse_wheel => |direction| try handleApprovalWheel(app, direction),
                else => {},
            }
        }

        fn applyDecisionAction(
            app: *App,
            action: approval_decision.Action,
            max_len: ?usize,
        ) !approval_decision.Event {
            const amendment_allowed: ?bool = if (app.approval_prompt.request) |request|
                request.amendment_allowed
            else
                null;
            return app.approval_prompt.decision.apply(
                app.alloc,
                action,
                amendment_allowed,
                max_len,
            );
        }

        fn clearApprovalPrompt(app: *App, reason: []const u8) void {
            app.approval_prompt.clearWithReason(app.alloc, reason);
            app.approval_screen.clear();
        }

        fn clearApprovalPromptAfterSubmission(app: *App) void {
            app.approval_prompt.clearAfterAcceptedSubmission(app.alloc);
            app.approval_screen.clear();
        }

        fn handleApprovalWheel(app: *App, direction: input_action.MouseWheel) !void {
            const request = app.approval_prompt.request orelse return;
            const commit = app.approval_screen.screen_commit orelse return;
            if (!(try approval_screen.needsScreen(
                app.alloc,
                request.view(),
                app.shell.layout,
                app.worker.queuedPromptCount(),
            )) or
                commit.request_id != request.id or
                !commit.document_scrollable)
            {
                return;
            }
            app.approval_screen.scrollDocument(
                approval_screen.documentWheelDelta(direction),
            );
            requestActiveSurfaceFrame(app);
        }

        fn submitPermissionChoice(app: *App, decision: ToolPermissionDecision) !void {
            debug_trace.logf(
                "permission",
                "approval response submitted request_id={d} decision={s}",
                .{ app.approval_prompt.request.?.id, @tagName(decision) },
            );
            if (app.approval_prompt.rule_management != null) {
                try submitRuleManagementChoice(app, decision);
                return;
            }
            if (try submitSubagentPermissionChoice(app, decision)) return;
            var affirmative_claimed = false;
            if (decision != .deny and
                app.approval_prompt.request.?.file != null)
            {
                admitPendingApprovalResize(app);
                const approval = app.approval_prompt.projection().?;
                const ready = if (comptime @hasField(App, "terminal"))
                    approval_screen.fileApprovalAffirmativeReady(
                        &app.shell,
                        approval,
                        &app.approval_screen,
                    )
                else
                    approval_ui.fileApprovalAffirmativeReady(
                        &app.shell,
                        approval,
                    );
                if (!ready) {
                    requestActiveSurfaceFrame(app);
                    debug_trace.logf(
                        "permission",
                        "file_approval_confirmation_blocked request_id={d} decision={s}",
                        .{
                            app.approval_prompt.request.?.id,
                            @tagName(decision),
                        },
                    );
                    return;
                }
                if (comptime @hasDecl(App, "beforeApprovalAffirmativeClaim")) {
                    app.beforeApprovalAffirmativeClaim();
                }
                if (!claimApprovalAffirmative(app)) {
                    debug_trace.logf(
                        "permission",
                        "file_approval_confirmation_blocked request_id={d} decision={s} reason=resize_interlock",
                        .{
                            app.approval_prompt.request.?.id,
                            @tagName(decision),
                        },
                    );
                    return;
                }
                affirmative_claimed = true;
            }
            defer if (affirmative_claimed) {
                releaseApprovalAffirmative(app);
            };
            const request_id = app.approval_prompt.request.?.id;
            var response = try app.approval_prompt.decision.materializeResponse(
                app.alloc,
                decision,
            );
            var response_submitted = false;
            errdefer if (!response_submitted) response.deinit();
            const result = app.worker.submitPermissionResponse(request_id, response);
            response_submitted = true;
            switch (result) {
                .accepted => {
                    clearApprovalPromptAfterSubmission(app);
                    app.input_runtime.input_limit_rejection = input_limit_rejection.clear();
                    requestActiveSurfaceFrame(app);
                },
                .stale, .no_pending => {},
            }
        }

        fn submitRuleManagementChoice(
            app: *App,
            decision: ToolPermissionDecision,
        ) !void {
            if (comptime !@hasField(App, "session") or
                !@hasField(App, "session_persistence") or
                !@hasDecl(App, "writeDomainNotice"))
            {
                return error.RuleManagementUnavailable;
            } else {
                if (decision == .deny) {
                    clearApprovalPromptAfterSubmission(app);
                    try app.writeDomainNotice(.{
                        .topic = "permissions",
                        .tone = .neutral,
                        .body = "saved-session permission change cancelled",
                    }, true);
                    requestActiveSurfaceFrame(app);
                    return;
                }
                const managed = app.approval_prompt.rule_management orelse return;
                var current = try app.session.snapshotPermissionState(app.alloc);
                defer current.deinit(app.alloc);
                const result = try session_permission_state.apply(
                    app.alloc,
                    current,
                    managed.event,
                );
                switch (result) {
                    .applied => |next_value| {
                        var next = next_value;
                        defer next.deinit(app.alloc);
                        try app_session_runtime.Runtime(App).commitPermissionState(
                            app,
                            next,
                        );
                        app.session.replacePermissionStateOwned(app.alloc, &next);
                        clearApprovalPromptAfterSubmission(app);
                        try app.writeDomainNotice(.{
                            .topic = "permissions",
                            .tone = .neutral,
                            .body = "saved-session permission rule updated",
                        }, true);
                    },
                    .stale => {
                        clearApprovalPrompt(app, "rule_management_stale");
                        try app.writeDomainNotice(.{
                            .topic = "permissions",
                            .tone = .warning,
                            .body = "saved-session permission rule changed before confirmation",
                        }, true);
                    },
                    .full => {
                        clearApprovalPrompt(app, "rule_management_full");
                        try app.writeDomainNotice(.{
                            .topic = "permissions",
                            .tone = .warning,
                            .body = "saved-session permission rule capacity reached",
                        }, true);
                    },
                    .invalid => {
                        clearApprovalPrompt(app, "rule_management_invalid");
                        try app.writeDomainNotice(.{
                            .topic = "permissions",
                            .tone = .@"error",
                            .body = "saved-session permission rule is invalid",
                        }, true);
                    },
                }
                requestActiveSurfaceFrame(app);
            }
        }

        fn submitSubagentPermissionChoice(
            app: *App,
            decision: ToolPermissionDecision,
        ) !bool {
            if (comptime !@hasField(App, "session_persistence")) return false;
            const host = app_session_runtime.Runtime(App).subagentHost(app) orelse {
                debug_trace.logf("subagent", "approval response ignored reason=host_unavailable", .{});
                return false;
            };
            const loaded_pending = host.pendingApprovalRequest(app.alloc) catch |err| {
                debug_trace.logf(
                    "subagent",
                    "approval response failed reason=request_load err={s}",
                    .{@errorName(err)},
                );
                return true;
            };
            var pending = loaded_pending orelse {
                debug_trace.logf("subagent", "approval response ignored reason=request_unavailable", .{});
                return false;
            };
            defer pending.deinit(app.alloc);
            const request_id = app.approval_prompt.request.?.id;
            if (pending.request.view().id != request_id) {
                debug_trace.logf(
                    "subagent",
                    "approval response ignored reason=request_mismatch presented={d} pending={d}",
                    .{ request_id, pending.request.view().id },
                );
                return false;
            }
            var response = try app.approval_prompt.decision.materializeResponse(
                app.alloc,
                decision,
            );
            defer response.deinit();
            const resolved = host.resolveApproval(.{
                .request_id = pending.request_id,
                .child_id = pending.child_id,
                .decision = response.decision,
                .feedback = response.feedback,
                .timestamp_ms = io_mod.milliTimestamp(),
            }) catch |err| {
                const stale = err == error.RequestNotFound or
                    err == error.StaleRequest or err == error.WrongChild;
                debug_trace.logf(
                    "subagent",
                    "main approval response failed request_id={s} child_id={s} outcome={s}",
                    .{ pending.request_id, pending.child_id, @errorName(err) },
                );
                if (stale) {
                    clearApprovalPrompt(app, "subagent_approval_stale");
                    requestActiveSurfaceFrame(app);
                }
                return true;
            };
            if (resolved == .accepted) {
                debug_trace.logf(
                    "subagent",
                    "approval response accepted request_id={s} child_id={s} decision={s}",
                    .{ pending.request_id, pending.child_id, @tagName(decision) },
                );
                clearApprovalPromptAfterSubmission(app);
                requestActiveSurfaceFrame(app);
            } else {
                clearApprovalPrompt(app, "subagent_approval_first_response_won");
                requestActiveSurfaceFrame(app);
            }
            return true;
        }

        pub fn cancelApprovalOperation(app: *App) !void {
            if (app_session_runtime.Runtime(App).subagentHost(app)) |host| {
                if (try host.pendingApprovalRequest(app.alloc)) |loaded| {
                    var pending = loaded;
                    defer pending.deinit(app.alloc);
                    if (app.approval_prompt.request) |request| {
                        if (pending.request.view().id == request.id) {
                            _ = host.resolveApproval(.{
                                .request_id = pending.request_id,
                                .child_id = pending.child_id,
                                .decision = .deny,
                                .timestamp_ms = io_mod.milliTimestamp(),
                            }) catch {};
                            clearApprovalPrompt(app, "subagent_approval_dismissed");
                            requestActiveSurfaceFrame(app);
                            return;
                        }
                    }
                }
            }
            const already_cancelled = app.worker.isCancelRequested();
            if (!already_cancelled) {
                debug_trace.logf("input", "cancel approval operation queued={d}", .{app.worker.queuedPromptCount()});
                interrupt.traceInterruptRequested(app, "input_approval");
            }
            app.worker.cancelApprovalTurn();

            clearApprovalPrompt(app, "cancelled");
            app.input_runtime.input_limit_rejection = input_limit_rejection.clear();

            if (!already_cancelled and app.stream.active) {
                app.pacer.clear(app.alloc);
                app.stopStream();
            }
            requestActiveSurfaceFrame(app);
        }

        fn claimApprovalAffirmative(app: *App) bool {
            if (comptime @hasDecl(App, "claimApprovalAffirmative")) {
                return app.claimApprovalAffirmative();
            }
            return false;
        }

        fn releaseApprovalAffirmative(app: *App) void {
            if (comptime @hasDecl(App, "releaseApprovalAffirmative")) {
                app.releaseApprovalAffirmative();
            }
        }

        fn admitPendingApprovalResize(app: *App) void {
            if (comptime @hasDecl(App, "admitPendingApprovalResize")) {
                _ = app.admitPendingApprovalResize();
            }
        }
    };
}

test "approval wheel keeps scrolling a committed command review after review sync" {
    const WheelWorker = struct {
        pub fn queuedPromptCount(_: *const @This()) usize {
            return 0;
        }
    };
    const WheelApp = struct {
        alloc: std.mem.Allocator,
        approval_prompt: approval_prompt.ApprovalPrompt = .{},
        approval_screen: interaction_state.ApprovalScreenState = .{},
        shell: struct {
            layout: types.Layout = .{
                .rows = 24,
                .cols = 80,
                .content_bottom = 20,
                .divider_top_row = 21,
                .input_row = 22,
                .divider_bottom_row = 23,
                .hint_row = 24,
            },
            render_requests: render_request.RenderRequestState = .{},
        } = .{},
        worker: WheelWorker = .{},

        fn deinit(self: *@This()) void {
            self.approval_prompt.deinit(self.alloc);
        }
    };

    const alloc = std.testing.allocator;
    var app = WheelApp{ .alloc = alloc };
    defer app.deinit();
    const request: permission_request.PermissionRequest = .{
        .id = 42,
        .label = "shell.run " ++ ("x" ** 2_400),
    };
    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, request));
    try std.testing.expect(try approval_screen.needsScreen(
        alloc,
        request,
        app.shell.layout,
        app.worker.queuedPromptCount(),
    ));
    app.approval_screen.recordScreenCommit(request.id, .{
        .request_id = request.id,
        .rows = app.shell.layout.rows,
        .cols = app.shell.layout.cols,
        .file_identity_visible = false,
        .all_decision_controls_visible = true,
        .changed_or_notice_visible = false,
        .document_scrollable = true,
    });

    try std.testing.expect(!app.approval_prompt.syncReview(null));
    try ApprovalRuntime(WheelApp).handleApprovalWheel(&app, .up);
    try std.testing.expectEqual(@as(usize, 3), app.approval_screen.document_scroll_rows);
    try std.testing.expect(app.shell.render_requests.hasReason(.modal));
}
