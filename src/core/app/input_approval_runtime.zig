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
const input_queue_runtime = @import("input_queue_runtime.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const app_render_runtime = @import("app_render_runtime.zig");
const approval_registry = @import("../subagent/approval_registry.zig");
const communication = @import("../subagent/communication.zig");
const communication_store = @import("../subagent/communication_store.zig");
const control_store = @import("../subagent/control_store.zig");
const domain = @import("../subagent/domain.zig");
const execution = @import("../subagent/execution.zig");
const permissions = @import("../permissions/permissions.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const permission_request = @import("../permissions/permission_request.zig");
const session = @import("../session/session.zig");
const session_codec = @import("../session/session_codec.zig");
const session_store = @import("../session/session_store.zig");
const subagent_authority = @import("../subagent/authority.zig");
const subagent_projection = @import("../subagent/ui_projection.zig");
const subagent_tool_host = @import("../subagent/tool_host.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const vertical_navigation = @import("../input/vertical_navigation.zig");
const interaction_state = @import("../../ui/footer/interaction_state.zig");
const approval_prompt = @import("../permissions/approval_prompt.zig");
const render_request = @import("../../ui/render_request.zig");
const subagent_controller = @import("../../ui/subagent/controller.zig");

const ToolPermissionDecision = types.ToolPermissionDecision;

pub fn ApprovalRuntime(comptime App: type) type {
    return struct {
        const interrupt = input_interrupt_runtime.InterruptRuntime(App);
        const queue_rt = input_queue_runtime.Runtime(App);

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
            if (comptime !@hasField(App, "subagents") or
                !@hasField(App, "session_persistence")) return false;
            if (comptime !@hasDecl(@TypeOf(app.subagents), "mainApprovalBinding")) return false;
            const request_id = app.approval_prompt.request.?.id;
            const binding = app.subagents.mainApprovalBinding(request_id) orelse return false;
            const host = app_session_runtime.Runtime(App).subagentHost(app) orelse return true;
            var response = try app.approval_prompt.decision.materializeResponse(
                app.alloc,
                decision,
            );
            defer response.deinit();
            const resolved = host.resolveApproval(.{
                .request_id = binding.approval_id,
                .child_id = binding.child_id,
                .decision = response.decision,
                .feedback = response.feedback,
                .timestamp_ms = io_mod.milliTimestamp(),
            }) catch |err| {
                const stale = err == error.RequestNotFound or
                    err == error.StaleRequest or err == error.WrongChild;
                debug_trace.logf(
                    "subagent",
                    "main approval response failed request_id={s} child_id={s} outcome={s}",
                    .{ binding.approval_id, binding.child_id, @errorName(err) },
                );
                if (stale) {
                    clearApprovalPrompt(app, "subagent_approval_stale");
                    app.subagents.markMainApprovalPresented(false);
                    if (comptime @hasDecl(App, "refreshSubagentManagerProjection")) {
                        try app.refreshSubagentManagerProjection();
                    }
                    requestActiveSurfaceFrame(app);
                }
                return true;
            };
            if (resolved == .accepted) {
                clearApprovalPromptAfterSubmission(app);
                app.subagents.markMainApprovalPresented(false);
                if (comptime @hasDecl(App, "refreshSubagentManagerProjection")) {
                    try app.refreshSubagentManagerProjection();
                }
                requestActiveSurfaceFrame(app);
            } else {
                clearApprovalPrompt(app, "subagent_approval_first_response_won");
                app.subagents.markMainApprovalPresented(false);
                requestActiveSurfaceFrame(app);
            }
            return true;
        }

        pub fn cancelApprovalOperation(app: *App) !void {
            if (comptime @hasField(App, "subagents")) {
                if (comptime @hasDecl(@TypeOf(app.subagents), "mainApprovalBinding")) {
                    if (app.approval_prompt.request) |request| {
                        if (app.subagents.mainApprovalBinding(request.id) != null) {
                            clearApprovalPrompt(app, "subagent_approval_dismissed");
                            app.subagents.dismissMainApproval();
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
            if (comptime @hasField(App, "queued_prompt_review")) {
                _ = queue_rt.pauseAndOpenAfterModalCancel(app);
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
        .label = "terminal.exec " ++ ("x" ** 2_400),
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

const ApprovalBridgeEnvironment = struct {
    tmp: std.testing.TmpDir,
    home: []u8,
    workspace: []u8,
    store: session_store.Store,

    fn init(alloc: std.mem.Allocator) !ApprovalBridgeEnvironment {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
        try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
        const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
        errdefer alloc.free(home);
        const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
        errdefer alloc.free(workspace);
        return .{
            .tmp = tmp,
            .home = home,
            .workspace = workspace,
            .store = try session_store.Store.initFromHome(alloc, home, workspace),
        };
    }

    fn deinit(self: *ApprovalBridgeEnvironment, alloc: std.mem.Allocator) void {
        self.store.deinit(alloc);
        alloc.free(self.home);
        alloc.free(self.workspace);
        self.tmp.cleanup();
        self.* = undefined;
    }

    fn createSession(
        self: *ApprovalBridgeEnvironment,
        alloc: std.mem.Allocator,
        id: []const u8,
    ) !void {
        const owned_id = try alloc.dupe(u8, id);
        errdefer alloc.free(owned_id);
        const origin = try alloc.dupe(u8, self.workspace);
        errdefer alloc.free(origin);
        const current = try alloc.dupe(u8, self.workspace);
        errdefer alloc.free(current);
        const model = try alloc.dupe(u8, "test/model");
        var state: session_codec.DurableSessionState = .{
            .id = owned_id,
            .origin_workspace_root = origin,
            .workspace_root = current,
            .created_at_ms = 1,
            .updated_at_ms = 1,
            .conversation_language = session.ConversationLanguage.literal("en"),
            .preferences = .{ .model = model, .effort = types.ReasoningEffort.literal("high"), .fast_mode = false },
            .history = &.{},
            .total_input_tokens = 0,
            .total_output_tokens = 0,
        };
        defer state.deinit(alloc);
        var loaded = try self.store.startWritableSession(alloc, state);
        loaded.deinit(alloc);
    }

    fn loadLedger(
        self: *ApprovalBridgeEnvironment,
        alloc: std.mem.Allocator,
        id: []const u8,
    ) !communication.Ledger {
        var capability = try self.store.openSubagentControlCapabilityReadOnly(
            alloc,
            id,
            .{},
        );
        defer capability.deinit();
        const store = communication_store.Store{
            .capability = &capability,
            .expected_session_id = id,
        };
        return store.load(alloc);
    }

    fn grantVisible(
        self: *ApprovalBridgeEnvironment,
        alloc: std.mem.Allocator,
        id: []const u8,
        grant: types.PermissionGrant,
    ) !bool {
        var capability = try self.store.openSubagentControlCapabilityReadOnly(
            alloc,
            id,
            .{},
        );
        defer capability.deinit();
        const store = communication_store.Store{
            .capability = &capability,
            .expected_session_id = id,
        };
        const maybe_ledger = try store.loadOptional(alloc);
        var ledger = maybe_ledger orelse return false;
        defer ledger.deinit(alloc);
        return permissions.sessionGrantAllowed(
            ledger.authority_grants,
            grant.tool_name,
            grant.target_path,
        );
    }
};

const ApprovalBridgeAuthority = struct {
    fn resolve(
        _: ?*anyopaque,
        alloc: std.mem.Allocator,
        _: []const u8,
    ) subagent_authority.HostResolveError!subagent_authority.HostAuthority {
        return subagent_authority.HostAuthority.capture(
            alloc,
            &.{"run_command"},
            &.{},
            .{ .rules = &.{} },
            &.{},
        );
    }

    fn resolver() subagent_authority.HostResolver {
        return .{ .resolve_fn = resolve };
    }
};

const ApprovalBridgeWaiter = struct {
    alloc: std.mem.Allocator,
    env: *ApprovalBridgeEnvironment,
    host: *subagent_tool_host.Runtime,
    worker: worker_runtime.WorkerRuntime = .{},
    expected_status: communication.ApprovalStatus,
    require_grant: bool,
    child_id_value: []const u8 = child_id,
    work_id_value: []const u8 = work_id,
    approval_id_value: []const u8 = approval_id,
    worker_request_id: u64 = 77,
    grant_value: types.PermissionGrant = grant,
    wake_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    effect_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    commit_before_wake: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    const root_id = "01J00000000000000000000000";
    const child_id = "01J00000000000000000000001";
    const work_id = "approval-bridge-create";
    const approval_id = "approval-bridge-request";
    const grant = types.PermissionGrant{
        .tool_name = @constCast("run_command"),
        .target_path = @constCast("/tmp/approval-bridge-effect"),
    };

    fn observe(
        raw: *anyopaque,
        worker: *worker_runtime.WorkerRuntime,
        request: permission_request.PermissionRequest,
    ) error{ OutOfMemory, PermissionRegistrationFailed }!void {
        const self: *ApprovalBridgeWaiter = @ptrCast(@alignCast(raw));
        self.host.approvals.registerTool(
            self.approval_id_value,
            self.child_id_value,
            root_id,
            self.work_id_value,
            request,
            &.{self.grant_value},
            worker,
            10,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.PermissionRegistrationFailed,
        };
    }

    fn run(self: *ApprovalBridgeWaiter) void {
        self.runFallible() catch self.failed.store(true, .seq_cst);
    }

    fn runFallible(self: *ApprovalBridgeWaiter) !void {
        self.worker.worker_processing = true;
        var response = try self.worker.requestPermissionBlockingObserved(
            self.alloc,
            .{
                .id = self.worker_request_id,
                .label = "Run the child effect",
                .explanation = "Production bridge approval",
                .command = "touch /tmp/approval-bridge-effect",
            },
            null,
            .{ .context = self, .observe_fn = observe },
        );
        defer response.deinit();

        var child_ledger = try self.env.loadLedger(self.alloc, self.child_id_value);
        defer child_ledger.deinit(self.alloc);
        const approval = communication.findApproval(
            child_ledger.approvals,
            self.approval_id_value,
        ) orelse return error.TestApprovalMissing;
        if (approval.status != self.expected_status) return error.TestApprovalStatus;

        const grant_visible = try self.env.grantVisible(
            self.alloc,
            root_id,
            self.grant_value,
        );
        if (grant_visible != self.require_grant) return error.TestGrantOrder;
        self.commit_before_wake.store(true, .seq_cst);
        _ = self.wake_count.fetchAdd(1, .seq_cst);
        if (response.decision != .deny) {
            _ = self.effect_count.fetchAdd(1, .seq_cst);
        }
        self.worker.finishProcessing();
    }
};

const ApprovalBridgeApp = struct {
    alloc: std.mem.Allocator,
    session_persistence: app_session_runtime.Persistence = .{},
    subagents: subagent_controller.Controller = .{},
    approval_prompt: approval_prompt.ApprovalPrompt = .{},
    approval_screen: interaction_state.ApprovalScreenState = .{},
    input_runtime: struct {
        vertical_navigation: vertical_navigation.State = .{},
        input_limit_rejection: input_limit_rejection.State = .{},

        fn deinit(_: *@This(), _: std.mem.Allocator) void {}
    } = .{},
    worker: *worker_runtime.WorkerRuntime,
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

    fn deinit(self: *ApprovalBridgeApp) void {
        self.session_persistence.subagent_host = null;
        self.subagents.deinit(self.alloc);
        self.approval_prompt.deinit(self.alloc);
        self.input_runtime.deinit(self.alloc);
    }

    fn refreshSubagentManagerProjection(self: *ApprovalBridgeApp) !void {
        const host = self.session_persistence.subagent_host.?;
        var loaded = try subagent_projection.load(self.alloc, .{
            .root_id = host.root_id,
            .manager = &host.manager,
            .sessions = host.sessions,
            .owner = &host.owner,
            .approval_registry = &host.approvals,
            .pending_approval_offset = self.subagents.pendingApprovalOffset(),
        });
        switch (loaded) {
            .snapshot => |snapshot| {
                loaded = undefined;
                _ = try self.subagents.replaceSnapshot(self.alloc, snapshot);
            },
            .degraded => {
                loaded.deinit(self.alloc);
                return error.TestProjectionDegraded;
            },
        }
    }
};

test "child approval navigation requests only the selected child surface" {
    const alloc = std.testing.allocator;
    var worker: worker_runtime.WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var app = ApprovalBridgeApp{
        .alloc = alloc,
        .worker = &worker,
    };
    defer app.deinit();
    app.subagents.open(alloc);
    app.subagents.runtime.child.presentation = .{};
    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, .{
        .id = 42,
        .label = "Run the selected child action",
    }));
    app.shell.render_requests.clearReason(.modal);
    app.subagents.runtime.child.presentation.?.render_requests.clearReason(.modal);

    try ApprovalRuntime(ApprovalBridgeApp).routeApprovalEscapeAction(
        &app,
        .cursor_right,
        null,
    );

    try std.testing.expect(!app.shell.render_requests.hasReason(.modal));
    try std.testing.expect(
        app.subagents.runtime.child.presentation.?.render_requests.hasReason(.modal),
    );
}

fn prepareApprovalBridge(
    alloc: std.mem.Allocator,
    env: *ApprovalBridgeEnvironment,
    host: *subagent_tool_host.Runtime,
) !void {
    try env.createSession(alloc, ApprovalBridgeWaiter.root_id);
    try prepareApprovalBridgeChild(
        alloc,
        env,
        host,
        ApprovalBridgeWaiter.child_id,
        ApprovalBridgeWaiter.work_id,
        "approval bridge child",
    );
}

fn prepareApprovalBridgeChild(
    alloc: std.mem.Allocator,
    env: *ApprovalBridgeEnvironment,
    host: *subagent_tool_host.Runtime,
    child_id: []const u8,
    work_id: []const u8,
    name: []const u8,
) !void {
    try env.createSession(alloc, child_id);
    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = name,
        .mode = .persistent,
        .prompt = "perform the approved effect",
    } });
    defer create.deinit(alloc);
    var created = try host.manager.execute(alloc, create, .{
        .actor_id = ApprovalBridgeWaiter.root_id,
        .operation_id = work_id,
        .created_child_id = child_id,
        .timestamp_ms = 2,
    });
    defer created.deinit(alloc);
    if (created != .receipt) return error.TestCreateFailed;

    var capability = try env.store.openSubagentControlCapabilityWritable(
        alloc,
        child_id,
        .{},
    );
    defer capability.deinit();
    const control = control_store.Store{
        .capability = &capability,
        .expected_child_id = child_id,
    };
    var lock = try control.acquireLock();
    defer lock.release();
    var record = try control.load(alloc);
    defer record.deinit(alloc);
    try execution.admitWork(alloc, &record, 0, 3);
    try control.save(alloc, record);
}

fn waitForApprovalBridgeRegistration(
    host: *subagent_tool_host.Runtime,
    waiter: *ApprovalBridgeWaiter,
    expected_revision: u64,
) !void {
    const deadline = io_mod.milliTimestamp() + 5_000;
    while (host.approvals.pendingRevision() < expected_revision) {
        if (waiter.failed.load(.seq_cst) or io_mod.milliTimestamp() >= deadline) {
            return error.TestApprovalRegistrationTimeout;
        }
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
}

fn runApprovalBridgeScenario(
    decision: ToolPermissionDecision,
    main_surface_wins: bool,
) !void {
    const alloc = std.testing.allocator;
    var env = try ApprovalBridgeEnvironment.init(alloc);
    defer env.deinit(alloc);
    const host = try subagent_tool_host.Runtime.create(
        alloc,
        &env.store,
        ApprovalBridgeWaiter.root_id,
        ApprovalBridgeAuthority.resolver(),
        .{},
    );
    defer host.deinit();
    _ = try host.reconcileAfterRestart(0);
    try prepareApprovalBridge(alloc, &env, host);

    const expected_status: communication.ApprovalStatus = switch (decision) {
        .once => .allowed_once,
        .always => .allowed_always,
        .deny => .denied,
        else => unreachable,
    };
    var waiter = ApprovalBridgeWaiter{
        .alloc = alloc,
        .env = &env,
        .host = host,
        .expected_status = expected_status,
        .require_grant = decision == .always,
    };
    defer waiter.worker.deinit(alloc);
    const thread = try std.Thread.spawn(.{}, ApprovalBridgeWaiter.run, .{&waiter});
    var joined = false;
    defer if (!joined) {
        waiter.worker.requestShutdown();
        thread.join();
    };
    try waitForApprovalBridgeRegistration(host, &waiter, 1);

    var app = ApprovalBridgeApp{
        .alloc = alloc,
        .worker = &waiter.worker,
    };
    defer app.deinit();
    app.session_persistence.subagent_host = host;
    try app.refreshSubagentManagerProjection();
    const main_request = app.subagents.mainApprovalRequest() orelse
        return error.TestMainApprovalMissing;
    try std.testing.expectEqualStrings(
        "Run the child effect",
        main_request.label,
    );
    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, main_request));
    app.subagents.markMainApprovalPresented(true);
    const binding = app.subagents.mainApprovalBinding(main_request.id).?;
    try std.testing.expectEqualStrings(ApprovalBridgeWaiter.child_id, binding.child_id);
    try std.testing.expectEqualStrings(ApprovalBridgeWaiter.approval_id, binding.approval_id);

    app.subagents.open(alloc);
    try std.testing.expectEqual(
        subagent_controller.KeyAction.redraw,
        try app.subagents.handleKeyWithMainApproval(alloc, 'n', main_request.id),
    );
    const key: u8 = switch (decision) {
        .once => '1',
        .always => '2',
        .deny => '3',
        else => unreachable,
    };
    if (main_surface_wins) {
        try std.testing.expectEqual(
            subagent_controller.KeyAction.resolve_child_approval,
            try app.subagents.handleKey(alloc, key),
        );
        try std.testing.expect(try ApprovalRuntime(ApprovalBridgeApp).handlePermissionAction(
            &app,
            .{ .number = key - '1' },
        ));
        try app_render_runtime.Runtime(ApprovalBridgeApp).resolveSubagentApproval(&app);
        const panel = try app.subagents.panelText(
            alloc,
            .{ .rows = 20, .cols = 100, .content_bottom = 16, .divider_top_row = 17, .input_row = 18, .divider_bottom_row = 19, .hint_row = 20 },
            null,
        );
        defer alloc.free(panel);
        try std.testing.expect(std.mem.find(u8, panel, "already resolved") != null);
    } else {
        try std.testing.expectEqual(
            subagent_controller.KeyAction.resolve_child_approval,
            try app.subagents.handleKey(alloc, key),
        );
        const submission = app.subagents.prepareApprovalResolution().?;
        try std.testing.expectEqualStrings(ApprovalBridgeWaiter.child_id, submission.child_id);
        try std.testing.expectEqualStrings(ApprovalBridgeWaiter.approval_id, submission.request_id);
        try std.testing.expectEqual(decision, submission.decision);
        try app_render_runtime.Runtime(ApprovalBridgeApp).resolveSubagentApproval(&app);
        try std.testing.expect(app.subagents.mainApprovalRequest() == null);
        try std.testing.expect(app.subagents.mainApprovalBinding(main_request.id) == null);
        try std.testing.expectError(
            error.RequestNotFound,
            host.resolveApproval(.{
                .request_id = ApprovalBridgeWaiter.approval_id,
                .child_id = ApprovalBridgeWaiter.child_id,
                .decision = decision,
                .timestamp_ms = 20,
            }),
        );
    }

    thread.join();
    joined = true;
    try std.testing.expect(!waiter.failed.load(.seq_cst));
    try std.testing.expect(waiter.commit_before_wake.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), waiter.wake_count.load(.seq_cst));
    try std.testing.expectEqual(
        @as(usize, if (decision == .deny) 0 else 1),
        waiter.effect_count.load(.seq_cst),
    );
    try std.testing.expectEqual(@as(u64, 2), host.approvals.pendingRevision());
    try std.testing.expectEqual(@as(usize, 0), app.subagents.runtime.snapshot.?.pending_approvals.len);
}

fn runTwoApprovalBridgeScenario() !void {
    const alloc = std.testing.allocator;
    const second_child_id = "01J00000000000000000000002";
    const second_work_id = "approval-bridge-create-second";
    const second_approval_id = "approval-bridge-request-second";
    const second_grant = types.PermissionGrant{
        .tool_name = @constCast("run_command"),
        .target_path = @constCast("/tmp/approval-bridge-effect-second"),
    };

    var env = try ApprovalBridgeEnvironment.init(alloc);
    defer env.deinit(alloc);
    const host = try subagent_tool_host.Runtime.create(
        alloc,
        &env.store,
        ApprovalBridgeWaiter.root_id,
        ApprovalBridgeAuthority.resolver(),
        .{},
    );
    defer host.deinit();
    _ = try host.reconcileAfterRestart(0);
    try prepareApprovalBridge(alloc, &env, host);
    try prepareApprovalBridgeChild(
        alloc,
        &env,
        host,
        second_child_id,
        second_work_id,
        "approval bridge child second",
    );

    var first_waiter = ApprovalBridgeWaiter{
        .alloc = alloc,
        .env = &env,
        .host = host,
        .expected_status = .allowed_once,
        .require_grant = false,
    };
    defer first_waiter.worker.deinit(alloc);
    const first_thread = try std.Thread.spawn(.{}, ApprovalBridgeWaiter.run, .{&first_waiter});
    var first_joined = false;
    defer if (!first_joined) {
        first_waiter.worker.requestShutdown();
        first_thread.join();
    };
    try waitForApprovalBridgeRegistration(host, &first_waiter, 1);

    var second_waiter = ApprovalBridgeWaiter{
        .alloc = alloc,
        .env = &env,
        .host = host,
        .expected_status = .allowed_once,
        .require_grant = false,
        .child_id_value = second_child_id,
        .work_id_value = second_work_id,
        .approval_id_value = second_approval_id,
        .worker_request_id = 88,
        .grant_value = second_grant,
    };
    defer second_waiter.worker.deinit(alloc);
    const second_thread = try std.Thread.spawn(.{}, ApprovalBridgeWaiter.run, .{&second_waiter});
    var second_joined = false;
    defer if (!second_joined) {
        second_waiter.worker.requestShutdown();
        second_thread.join();
    };
    try waitForApprovalBridgeRegistration(host, &second_waiter, 2);

    var app = ApprovalBridgeApp{
        .alloc = alloc,
        .worker = &first_waiter.worker,
    };
    defer app.deinit();
    app.session_persistence.subagent_host = host;
    try app.refreshSubagentManagerProjection();
    try std.testing.expectEqual(@as(usize, 2), app.subagents.runtime.snapshot.?.pending_approval_total);

    const first_request = app.subagents.mainApprovalRequest() orelse
        return error.TestMainApprovalMissing;
    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, first_request));
    app.subagents.markMainApprovalPresented(true);
    const first_binding = app.subagents.mainApprovalBinding(first_request.id).?;
    try std.testing.expectEqualStrings(ApprovalBridgeWaiter.child_id, first_binding.child_id);
    try std.testing.expectEqualStrings(ApprovalBridgeWaiter.approval_id, first_binding.approval_id);

    app.subagents.open(alloc);
    try std.testing.expectEqual(
        subagent_controller.KeyAction.redraw,
        try app.subagents.handleKeyWithMainApproval(alloc, 'n', first_request.id),
    );
    try std.testing.expectEqual(
        subagent_controller.KeyAction.resolve_child_approval,
        try app.subagents.handleKey(alloc, '1'),
    );
    try std.testing.expect(try ApprovalRuntime(ApprovalBridgeApp).handlePermissionAction(
        &app,
        .{ .number = 0 },
    ));
    try app_render_runtime.Runtime(ApprovalBridgeApp).resolveSubagentApproval(&app);

    const stale_panel = try app.subagents.panelText(
        alloc,
        .{ .rows = 20, .cols = 100, .content_bottom = 16, .divider_top_row = 17, .input_row = 18, .divider_bottom_row = 19, .hint_row = 20 },
        null,
    );
    defer alloc.free(stale_panel);
    try std.testing.expect(std.mem.find(u8, stale_panel, "already resolved") != null);

    const second_request = app.subagents.runtime.mainApprovalRequest() orelse
        return error.TestMainApprovalMissing;
    app.subagents.markMainApprovalPresented(true);
    const second_binding = app.subagents.mainApprovalBinding(second_request.id).?;
    try std.testing.expectEqualStrings(second_child_id, second_binding.child_id);
    try std.testing.expectEqualStrings(second_approval_id, second_binding.approval_id);
    switch (app.subagents.runtime.currentRoute().?.*) {
        .approval => |route| {
            try std.testing.expectEqualStrings(second_binding.child_id, route.child_id);
            try std.testing.expectEqualStrings(second_binding.approval_id, route.approval_id);
        },
        else => return error.TestExpectedApprovalRoute,
    }

    first_thread.join();
    first_joined = true;
    try std.testing.expect(!first_waiter.failed.load(.seq_cst));
    try std.testing.expect(first_waiter.commit_before_wake.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), first_waiter.wake_count.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), first_waiter.effect_count.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), second_waiter.wake_count.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), second_waiter.effect_count.load(.seq_cst));

    try std.testing.expect(try app.approval_prompt.syncRequest(alloc, second_request));
    app.worker = &second_waiter.worker;
    try std.testing.expectEqual(
        subagent_controller.KeyAction.resolve_child_approval,
        try app.subagents.handleKey(alloc, '1'),
    );
    const second_submission = app.subagents.prepareApprovalResolution().?;
    try std.testing.expectEqualStrings(second_binding.child_id, second_submission.child_id);
    try std.testing.expectEqualStrings(second_binding.approval_id, second_submission.request_id);
    try app_render_runtime.Runtime(ApprovalBridgeApp).resolveSubagentApproval(&app);
    try std.testing.expect(try ApprovalRuntime(ApprovalBridgeApp).handlePermissionAction(
        &app,
        .{ .number = 0 },
    ));

    second_thread.join();
    second_joined = true;
    try std.testing.expect(!second_waiter.failed.load(.seq_cst));
    try std.testing.expect(second_waiter.commit_before_wake.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), second_waiter.wake_count.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), second_waiter.effect_count.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), first_waiter.wake_count.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), first_waiter.effect_count.load(.seq_cst));
    try std.testing.expectEqual(@as(u64, 4), host.approvals.pendingRevision());
    try std.testing.expectEqual(@as(usize, 0), app.subagents.runtime.snapshot.?.pending_approval_total);
    try std.testing.expect(app.subagents.runtime.mainApprovalRequest() == null);
}

test "production approval bridge keeps exact identity and first winner across both surfaces" {
    try runApprovalBridgeScenario(.once, true);
    try runApprovalBridgeScenario(.always, false);
    try runApprovalBridgeScenario(.deny, true);
}

test "two real pending approvals keep exact identity while each surface wins once" {
    try runTwoApprovalBridgeScenario();
}
