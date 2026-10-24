const std = @import("std");
const agents = @import("../agents/agents.zig");
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
const text_utils = @import("../shared/text_utils.zig");

const ToolPermissionDecision = types.ToolPermissionDecision;

pub fn ApprovalRuntime(comptime App: type) type {
    return struct {
        const AppAgent = if (@hasField(App, "main_agent")) @FieldType(App, "main_agent") else struct {};
        const interrupt = input_interrupt_runtime.InterruptRuntime(App);

        fn requestActiveSurfaceFrame(app: *App) void {
            app_render_runtime.Runtime(App).requestActiveSurfaceFrame(app, .modal);
        }

        pub fn handlePermissionAction(
            app: *App,
            agent: *AppAgent,
            action: approval_decision.Action,
        ) !bool {
            return switch (try handlePermissionActionWithLimit(app, agent, action, null)) {
                .consumed => true,
                .ignored => false,
                .limit_exceeded => unreachable,
            };
        }

        pub fn handlePermissionActionBounded(
            app: *App,
            agent: *AppAgent,
            action: approval_decision.Action,
            max_len: usize,
        ) !edit_contract.ByteResult {
            return handlePermissionActionWithLimit(app, agent, action, max_len);
        }

        fn handlePermissionActionWithLimit(
            app: *App,
            agent: *AppAgent,
            action: approval_decision.Action,
            max_len: ?usize,
        ) !edit_contract.ByteResult {
            const event = try applyDecisionAction(app, agent, action, max_len);
            switch (event) {
                .none => return .ignored,
                .redraw => {
                    requestActiveSurfaceFrame(app);
                    return .consumed;
                },
                .decision => |decision| {
                    try submitPermissionChoice(app, agent, decision);
                    return .consumed;
                },
                .limit_exceeded => return .limit_exceeded,
            }
        }

        pub fn routeApprovalEscapeAction(
            app: *App,
            agent: *AppAgent,
            action: input_action.Action,
            focused_edit: ?approval_decision.DraftAction,
        ) !void {
            app.input_runtime.vertical_navigation.reset();
            app.input_runtime.input_limit_rejection = input_limit_rejection.clear();
            const amending = agent.approval_prompt.isAmending();
            if (amending) {
                if (focused_edit) |edit| {
                    _ = try applyDecisionAction(
                        app,
                        agent,
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
                            agent,
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
                            agent,
                            .{ .move_choice = .next },
                            null,
                        );
                        requestActiveSurfaceFrame(app);
                    }
                },
                .history_up, .cursor_up => {
                    _ = try applyDecisionAction(
                        app,
                        agent,
                        .{ .move_choice = .previous },
                        null,
                    );
                    requestActiveSurfaceFrame(app);
                },
                .history_down, .cursor_down => {
                    _ = try applyDecisionAction(
                        app,
                        agent,
                        .{ .move_choice = .next },
                        null,
                    );
                    requestActiveSurfaceFrame(app);
                },
                .mouse_wheel => |direction| try handleApprovalWheel(app, agent, direction),
                else => {},
            }
        }

        fn applyDecisionAction(
            app: *App,
            agent: *AppAgent,
            action: approval_decision.Action,
            max_len: ?usize,
        ) !approval_decision.Event {
            const amendment_allowed: ?bool = if (agent.approval_prompt.request) |request|
                request.amendment_allowed
            else
                null;
            return agent.approval_prompt.decision.apply(
                app.alloc,
                action,
                amendment_allowed,
                max_len,
            );
        }

        fn clearApprovalPrompt(app: *App, agent: *AppAgent, reason: []const u8) void {
            agent.approval_prompt.clearWithReason(app.alloc, reason);
            app.approval_screen.clear();
        }

        fn clearApprovalPromptAfterSubmission(app: *App, agent: *AppAgent) void {
            agent.approval_prompt.clearAfterAcceptedSubmission(app.alloc);
            app.approval_screen.clear();
        }

        fn handleApprovalWheel(app: *App, agent: *AppAgent, direction: input_action.MouseWheel) !void {
            const request = agent.approval_prompt.request orelse return;
            const commit = app.approval_screen.screen_commit orelse return;
            if (!(try approval_screen.needsScreen(
                app.alloc,
                request.view(),
                app.shell.layout,
                agent.worker.queuedPromptCount(),
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

        fn submitPermissionChoice(app: *App, agent: *AppAgent, decision: ToolPermissionDecision) !void {
            debug_trace.logf(
                "permission",
                "approval response submitted request_id={d} decision={s}",
                .{ agent.approval_prompt.request.?.id, @tagName(decision) },
            );
            if (agent.approval_prompt.rule_management != null) {
                try submitRuleManagementChoice(app, agent, decision);
                return;
            }
            var affirmative_claimed = false;
            if (decision != .deny and
                agent.approval_prompt.request.?.file != null)
            {
                admitPendingApprovalResize(app);
                const approval = agent.approval_prompt.projection().?;
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
                            agent.approval_prompt.request.?.id,
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
                            agent.approval_prompt.request.?.id,
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
            const request_id = agent.approval_prompt.request.?.id;
            var response = try agent.approval_prompt.decision.materializeResponse(
                app.alloc,
                decision,
            );
            var response_submitted = false;
            errdefer if (!response_submitted) response.deinit();
            // A subagent's approval main's screen shows is answered here, on
            // main's screen, and its answer goes to that subagent's worker.
            const lent = if (comptime @hasDecl(App, "lentApproval")) app.lentApproval() else null;
            const worker = if (lent) |subagent| subagent.worker else &agent.worker;
            const result = worker.submitPermissionResponse(request_id, response);
            response_submitted = true;
            switch (result) {
                .accepted => {
                    if (comptime @hasDecl(App, "screenAgentId")) {
                        const asker = if (lent) |subagent| subagent.id else subagentIdOf(app, agent);
                        if (asker) |id| debug_trace.eventf("host", "approval_answered", .{}, "agent={s} screen={s}", .{ id, app.screenAgentId() });
                    }
                    clearApprovalPromptAfterSubmission(app, agent);
                    app.input_runtime.input_limit_rejection = input_limit_rejection.clear();
                    requestActiveSurfaceFrame(app);
                },
                .stale, .no_pending => {},
            }
        }

        fn submitRuleManagementChoice(
            app: *App,
            agent: *AppAgent,
            decision: ToolPermissionDecision,
        ) !void {
            if (comptime !agents.hasAgentField(App, "session") or
                !agents.hasAgentField(App, "session_persistence") or
                !@hasDecl(App, "writeDomainNotice"))
            {
                return error.RuleManagementUnavailable;
            } else {
                if (decision == .deny) {
                    clearApprovalPromptAfterSubmission(app, agent);
                    try app.writeDomainNotice(.{
                        .topic = "permissions",
                        .tone = .neutral,
                        .body = "saved-session permission change cancelled",
                    }, true);
                    requestActiveSurfaceFrame(app);
                    return;
                }
                const managed = agent.approval_prompt.rule_management orelse return;
                var current = try agent.session.snapshotPermissionState(app.alloc);
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
                            agent,
                            next,
                        );
                        agent.session.replacePermissionStateOwned(app.alloc, &next);
                        clearApprovalPromptAfterSubmission(app, agent);
                        try app.writeDomainNotice(.{
                            .topic = "permissions",
                            .tone = .neutral,
                            .body = "saved-session permission rule updated",
                        }, true);
                    },
                    .stale => {
                        clearApprovalPrompt(app, agent, "rule_management_stale");
                        try app.writeDomainNotice(.{
                            .topic = "permissions",
                            .tone = .warning,
                            .body = "saved-session permission rule changed before confirmation",
                        }, true);
                    },
                    .full => {
                        clearApprovalPrompt(app, agent, "rule_management_full");
                        try app.writeDomainNotice(.{
                            .topic = "permissions",
                            .tone = .warning,
                            .body = "saved-session permission rule capacity reached",
                        }, true);
                    },
                    .invalid => {
                        clearApprovalPrompt(app, agent, "rule_management_invalid");
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

        fn subagentIdOf(app: *App, agent: *AppAgent) ?[]const u8 {
            if (comptime !@hasDecl(App, "subagentIdOf")) return null;
            return app.subagentIdOf(agent);
        }

        pub fn cancelApprovalOperation(app: *App, agent: *AppAgent) !void {
            // A subagent's approval main's screen shows is cancelled in that
            // subagent's context, as its own screen would cancel it.
            if (comptime @hasDecl(App, "answerLentApproval")) {
                if (try app.answerLentApproval(agent, cancelApprovalOperation)) return;
            }
            const already_cancelled = agent.worker.isCancelRequested();
            if (!already_cancelled) {
                debug_trace.logf("input", "cancel approval operation queued={d}", .{agent.worker.queuedPromptCount()});
                interrupt.traceInterruptRequested(app, agent, "input_approval");
            }
            agent.worker.cancelApprovalTurn();

            clearApprovalPrompt(app, agent, "cancelled");
            app.input_runtime.input_limit_rejection = input_limit_rejection.clear();

            if (!already_cancelled and agent.stream.active) {
                app.pacer.clear(app.alloc);
                app.stopStream(agent);
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
        main_agent: struct {
            approval_prompt: approval_prompt.ApprovalPrompt = .{},
            worker: WheelWorker = .{},
        } = .{},
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

        fn deinit(self: *@This()) void {
            self.agent().approval_prompt.deinit(self.alloc);
        }

        pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
            return &self.main_agent;
        }
    };

    const alloc = std.testing.allocator;
    var app = WheelApp{ .alloc = alloc };
    defer app.deinit();
    const request: permission_request.PermissionRequest = .{
        .id = 42,
        .label = "shell.run " ++ text_utils.repeat("x", 2_400),
    };
    try std.testing.expect(try app.agent().approval_prompt.syncRequest(alloc, request));
    try std.testing.expect(try approval_screen.needsScreen(
        alloc,
        request,
        app.shell.layout,
        app.agent().worker.queuedPromptCount(),
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

    try std.testing.expect(!app.agent().approval_prompt.syncReview(null));
    try ApprovalRuntime(WheelApp).handleApprovalWheel(&app, (&app).agent(), .up);
    try std.testing.expectEqual(@as(usize, 3), app.approval_screen.document_scroll_rows);
    try std.testing.expect(app.shell.render_requests.hasReason(.modal));
}
