const std = @import("std");
const permission_request = @import("../../core/permissions/permission_request.zig");
const types = @import("../../core/shared/types.zig");
const manager_mod = @import("../../core/subagent/manager.zig");
const projection = @import("../../core/subagent/ui_projection.zig");
const terminal_projection = @import("../../core/terminal/ui_projection.zig");
const execution = @import("../../core/subagent/execution.zig");
const domain = @import("../../core/subagent/domain.zig");
const input_action = @import("../../core/input/input_action.zig");
const core_input_runtime = @import("../../core/input/runtime.zig");
const transcript_presentation = @import("../../core/output/transcript_presentation.zig");
const skill_contract = @import("../../core/skills/skill_contract.zig");
const subagent_runtime = @import("runtime.zig");
const render_request = @import("../render_request.zig");
const transcript_runtime = @import("../transcript/runtime.zig");

const Allocator = std.mem.Allocator;

pub const KeyAction = subagent_runtime.Command;
pub const InputAction = subagent_runtime.Action;
pub const ToggleResult = enum { changed };
pub const ChildPresentationView = subagent_runtime.ChildPresentationView;

pub const Controller = struct {
    runtime: subagent_runtime.Runtime = .{},
    view_active: bool = false,
    last_refresh_ms: i64 = 0,

    pub noinline fn init() Controller {
        return .{ .runtime = subagent_runtime.Runtime.init() };
    }

    pub fn deinit(self: *Controller, alloc: Allocator) void {
        self.runtime.deinit(alloc);
        self.view_active = false;
    }

    pub fn isViewActive(self: Controller) bool {
        return self.view_active;
    }

    pub fn open(self: *Controller, alloc: Allocator) void {
        self.runtime.resetForOpen(alloc);
        self.view_active = true;
    }

    pub fn close(self: *Controller, alloc: Allocator) void {
        self.runtime.resetForOpen(alloc);
        self.view_active = false;
    }

    pub fn clearProjection(self: *Controller, alloc: Allocator) void {
        self.runtime.clearProjection(alloc);
        self.last_refresh_ms = 0;
    }

    pub fn count(self: Controller) usize {
        return self.runtime.count();
    }

    pub fn setCountProjection(self: *Controller, projected_count: usize) void {
        self.runtime.setCountProjection(projected_count);
    }

    pub fn hasEntries(self: Controller) bool {
        return self.count() > 0 or self.runtime.selectedTerminalId() != null;
    }

    pub fn snapshotEntries(self: Controller, alloc: Allocator) ![]subagent_runtime.EntryView {
        return self.runtime.snapshotEntries(alloc);
    }

    pub fn selectedInfo(self: Controller) ?subagent_runtime.SelectedInfo {
        return self.runtime.selectedInfo();
    }

    pub fn replaceSnapshot(self: *Controller, alloc: Allocator, snapshot: projection.Snapshot) !bool {
        return self.runtime.replaceSnapshot(alloc, snapshot);
    }

    pub fn replaceTerminalSnapshot(
        self: *Controller,
        alloc: Allocator,
        snapshot: terminal_projection.Snapshot,
    ) !bool {
        return self.runtime.replaceTerminalSnapshot(alloc, snapshot);
    }

    pub fn selectedTerminalId(self: *const Controller) ?[]const u8 {
        return self.runtime.selectedTerminalId();
    }

    pub fn pageCursor(self: Controller) ?[]const u8 {
        return self.runtime.pageCursor();
    }

    pub fn pendingApprovalOffset(self: Controller) usize {
        return self.runtime.pendingApprovalOffset();
    }

    pub fn pageAnchorId(self: Controller) ?[]const u8 {
        return self.runtime.pageAnchorId();
    }

    pub fn refreshDue(self: *Controller, now_ms: i64, force: bool) bool {
        const interval_ms: i64 = if (self.view_active) 100 else 250;
        if (!force and now_ms - self.last_refresh_ms < interval_ms) return false;
        self.last_refresh_ms = now_ms;
        return true;
    }

    pub fn projectionRefreshDue(
        self: *Controller,
        now_ms: i64,
        force: bool,
        pending_approval_revision: u64,
    ) bool {
        if (self.view_active) return self.refreshDue(now_ms, force);
        if (!force and
            self.runtime.approvalRevision() == pending_approval_revision) return false;
        self.last_refresh_ms = now_ms;
        return true;
    }

    pub fn mainApprovalRequest(self: *const Controller) ?permission_request.PermissionRequest {
        return self.runtime.mainApprovalRequest();
    }

    pub fn markMainApprovalPresented(self: *Controller, presented: bool) void {
        self.runtime.markMainApprovalPresented(presented);
    }

    pub fn mainApprovalPresented(self: Controller) bool {
        return self.runtime.mainApprovalPresented();
    }

    pub fn mainApprovalBinding(
        self: *const Controller,
        prompt_id: u64,
    ) ?subagent_runtime.MainApprovalBinding {
        return self.runtime.mainApprovalBinding(prompt_id);
    }

    pub fn dismissMainApproval(self: *Controller) void {
        self.runtime.dismissMainApproval();
    }

    pub fn setDegraded(self: *Controller, alloc: Allocator, failure: manager_mod.FailureCode) void {
        self.runtime.setDegraded(alloc, failure);
    }

    pub fn setDefaults(
        self: *Controller,
        alloc: Allocator,
        model: []const u8,
        effort: types.ReasoningEffort,
    ) !void {
        try self.runtime.setDefaults(alloc, model, effort);
    }

    pub fn handleAction(self: *Controller, alloc: Allocator, action: InputAction) !KeyAction {
        return self.handleActionWithMainApproval(alloc, action, null);
    }

    pub fn handleActionWithMainApproval(
        self: *Controller,
        alloc: Allocator,
        action: InputAction,
        main_approval_id: ?u64,
    ) !KeyAction {
        return self.runtime.handleWithMainApproval(alloc, action, main_approval_id);
    }

    pub const Acknowledgement = struct {
        child_id: []const u8,
        through_sequence: u64,
    };

    pub fn acknowledgement(self: *const Controller) ?Acknowledgement {
        if (self.runtime.pendingChildAcknowledgement()) |pending| {
            return .{
                .child_id = pending.child_id,
                .through_sequence = pending.through_sequence,
            };
        }
        const node = self.runtime.routedNode() orelse return null;
        if (node.through_sequence == 0) return null;
        return .{ .child_id = node.child_id, .through_sequence = node.through_sequence };
    }

    pub fn acknowledgementAttempted(
        self: *Controller,
        alloc: Allocator,
        attempted: Acknowledgement,
    ) void {
        self.runtime.childAcknowledgementAttempted(
            alloc,
            attempted.child_id,
            attempted.through_sequence,
        );
    }

    pub fn visibleChildAcknowledgement(self: *const Controller) ?Acknowledgement {
        const through_sequence = self.runtime.visibleChildAcknowledgementSequence() orelse return null;
        const child_id = self.runtime.childRouteId() orelse return null;
        return .{ .child_id = child_id, .through_sequence = through_sequence };
    }

    pub fn handleKey(self: *Controller, alloc: Allocator, byte: u8) !KeyAction {
        return self.handleKeyWithMainApproval(alloc, byte, null);
    }

    pub fn handleKeyWithMainApproval(
        self: *Controller,
        alloc: Allocator,
        byte: u8,
        main_approval_id: ?u64,
    ) !KeyAction {
        return self.runtime.handleByte(alloc, byte, main_approval_id);
    }

    pub fn childRouteId(self: *const Controller) ?[]const u8 {
        return self.runtime.childRouteId();
    }

    pub fn childPresentationView(
        self: *const Controller,
    ) ?ChildPresentationView {
        return self.runtime.childPresentationView();
    }

    pub fn childComposerFocused(self: *const Controller) bool {
        return self.runtime.childComposerFocused();
    }

    pub fn childComposerEditor(self: *Controller) ?*core_input_runtime.Runtime {
        return self.runtime.childComposerEditor();
    }

    pub fn moveChildInputCursor(
        self: *Controller,
        intent: input_action.MoveIntent,
        terminal_cols: u16,
        page_rows: usize,
    ) bool {
        return self.runtime.moveChildInputCursor(intent, terminal_cols, page_rows);
    }

    pub fn commitChildEditorEdit(self: *Controller, alloc: Allocator) void {
        self.runtime.commitChildEditorEdit(alloc);
    }

    pub fn clearChildComposer(self: *Controller, alloc: Allocator) void {
        self.runtime.clearChildComposer(alloc);
    }

    pub fn bindSelectedChildSkill(
        self: *Controller,
        alloc: Allocator,
        name: []const u8,
        path: []const u8,
        display_source: ?skill_contract.SkillSource,
    ) !bool {
        return self.runtime.bindSelectedChildSkill(
            alloc,
            name,
            path,
            display_source,
        );
    }

    pub fn invalidateChildConversationProjection(
        self: *Controller,
        alloc: Allocator,
    ) void {
        self.runtime.invalidateChildConversationProjection(alloc);
    }

    pub fn openSelectedChildModelConfiguration(
        self: *Controller,
        alloc: Allocator,
        model: []const u8,
    ) !KeyAction {
        return self.runtime.openSelectedChildModelConfiguration(alloc, model);
    }

    pub fn commitChildPresentationViewport(
        self: *Controller,
        total_rows: u32,
        max_rows_from_bottom: u32,
        rows_from_bottom: u32,
    ) void {
        self.runtime.commitChildPresentationViewport(
            total_rows,
            max_rows_from_bottom,
            rows_from_bottom,
        );
    }

    pub fn managerPasteActive(self: *const Controller) bool {
        return self.view_active and self.runtime.managerPasteActive();
    }

    pub fn beginManagerPaste(self: *Controller) void {
        if (!self.view_active) return;
        self.runtime.beginManagerPaste();
    }

    pub fn consumeManagerPasteByte(
        self: *Controller,
        alloc: Allocator,
        byte: u8,
    ) !bool {
        if (!self.view_active) return false;
        return self.runtime.consumeManagerPasteByte(alloc, byte);
    }

    pub fn settleManagerPasteDeliveryEpoch(
        self: *Controller,
        alloc: Allocator,
    ) bool {
        if (!self.view_active) return false;
        return self.runtime.settleManagerPasteDeliveryEpoch(alloc);
    }

    pub fn childPasteActive(self: Controller) bool {
        return self.runtime.childPasteActive();
    }

    pub fn beginChildPaste(self: *Controller) void {
        self.runtime.beginChildPaste();
    }

    pub fn consumeChildPasteByte(
        self: *Controller,
        alloc: Allocator,
        byte: u8,
    ) !bool {
        return self.runtime.consumeChildPasteByte(alloc, byte);
    }

    pub fn installChildChat(
        self: *Controller,
        alloc: Allocator,
        chat: projection.ChildChat,
        older_page: bool,
        reset_pages: bool,
    ) !void {
        try self.runtime.installChildChat(
            alloc,
            chat,
            older_page,
            reset_pages,
        );
    }

    pub fn replaceChildLive(
        self: *Controller,
        alloc: Allocator,
        live: ?execution.LivePresentation,
    ) bool {
        return self.runtime.replaceChildLive(alloc, live);
    }

    pub fn childConversationRuntime(
        self: *Controller,
    ) ?*transcript_runtime.TranscriptRuntime {
        return self.runtime.childConversationRuntime();
    }

    pub fn childFullTranscriptRequested(self: Controller) bool {
        return self.view_active and
            self.runtime.childFullTranscriptRequested();
    }

    pub fn childTranscriptPresentationDepth(
        self: Controller,
    ) transcript_presentation.Depth {
        if (!self.view_active) return .inline_mode;
        return self.runtime.childTranscriptPresentationDepth();
    }

    pub fn setChildTranscriptPresentationDepth(
        self: *Controller,
        alloc: Allocator,
        requested: transcript_presentation.Depth,
    ) !transcript_presentation.Depth {
        if (!self.view_active) return .inline_mode;
        return self.runtime.setChildTranscriptPresentationDepth(
            alloc,
            requested,
        );
    }

    pub fn closeChildTranscriptPresentation(
        self: *Controller,
        alloc: Allocator,
    ) !bool {
        if (!self.view_active) return false;
        return self.runtime.closeChildTranscriptPresentation(alloc);
    }

    pub fn activeRenderRequests(
        self: *Controller,
    ) *render_request.RenderRequestState {
        return self.runtime.activeRenderRequests();
    }

    pub fn activateManagerSurface(self: *Controller) void {
        self.runtime.activateManagerSurface();
    }

    pub fn activateChildConversationSurface(self: *Controller) bool {
        return self.runtime.activateChildConversationSurface();
    }

    pub fn activateChildCatalogSurface(self: *Controller) bool {
        return self.runtime.activateChildCatalogSurface();
    }

    pub fn installChildConversationRuntime(
        self: *Controller,
        alloc: Allocator,
        runtime_value: transcript_runtime.TranscriptRuntime,
        diff_entries: std.ArrayList(
            @import("../../core/output/diff.zig").DiffEntry,
        ),
        live: ?execution.LivePresentation,
        next_diff_id: u32,
    ) !void {
        try self.runtime.installChildConversationRuntime(
            alloc,
            runtime_value,
            diff_entries,
            live,
            next_diff_id,
        );
    }

    pub fn markChildConversationEventsAppliedThrough(
        self: *Controller,
        live: execution.LivePresentation,
        event_count: usize,
        next_diff_id: u32,
    ) void {
        self.runtime.markChildConversationEventsAppliedThrough(
            live,
            event_count,
            next_diff_id,
        );
    }

    pub fn childConversationEventCount(self: Controller) usize {
        return self.runtime.childConversationEventCount();
    }

    pub fn childConversationNextDiffId(self: Controller) u32 {
        return self.runtime.childConversationNextDiffId();
    }

    pub fn childConversationDiffEntries(
        self: *Controller,
    ) *std.ArrayList(@import("../../core/output/diff.zig").DiffEntry) {
        return self.runtime.childConversationDiffEntries();
    }

    pub fn childFullTranscriptDiffResolver(
        self: *Controller,
    ) ?@import("../full_transcript_screen.zig").FullDiffResolver {
        return self.runtime.childFullTranscriptDiffResolver();
    }

    pub fn setChildUnavailable(
        self: *Controller,
        alloc: Allocator,
        unavailable: projection.ChildUnavailable,
    ) void {
        self.runtime.setChildUnavailable(alloc, unavailable);
    }

    pub fn olderHistoryCursor(self: Controller) ?[]const u8 {
        return self.runtime.olderHistoryCursor();
    }

    pub fn prepareSubmission(
        self: *Controller,
        alloc: Allocator,
        timestamp_ms: i64,
    ) !?subagent_runtime.Runtime.Submission {
        return self.runtime.prepareSubmission(alloc, timestamp_ms);
    }

    pub fn assignSubmissionIdentity(
        self: *Controller,
        invocation_id: []const u8,
        identity_epoch: u64,
    ) bool {
        return self.runtime.assignSubmissionIdentity(invocation_id, identity_epoch);
    }

    pub fn submissionAccepted(self: *Controller, alloc: Allocator) void {
        self.runtime.submissionAccepted(alloc);
    }

    pub fn submissionRejected(
        self: *Controller,
        alloc: Allocator,
        failure: manager_mod.Failure,
    ) void {
        self.runtime.submissionRejected(alloc, failure);
    }

    pub fn installAttachPage(
        self: *Controller,
        alloc: Allocator,
        page: projection.AttachPage,
        append: bool,
    ) !void {
        try self.runtime.installAttachPage(alloc, page, append);
    }

    pub fn setAttachLoadFailure(self: *Controller) void {
        self.runtime.setAttachLoadFailure();
    }

    pub fn attachContinuation(self: Controller) ?@import("../../core/session/session_store.zig").ResumableSessionContinuation {
        return self.runtime.attachContinuation();
    }

    pub fn isAttachRouteActive(self: Controller) bool {
        return self.runtime.isAttachRouteActive();
    }

    pub fn prepareManagerMutation(
        self: *Controller,
        alloc: Allocator,
        timestamp_ms: i64,
    ) !?subagent_runtime.Runtime.PreparedMutation {
        return self.runtime.prepareManagerMutation(alloc, timestamp_ms);
    }

    pub fn assignMutationIdentity(
        self: *Controller,
        invocation_id: []const u8,
        identity_epoch: u64,
    ) bool {
        return self.runtime.assignMutationIdentity(invocation_id, identity_epoch);
    }

    pub fn mutationRejected(
        self: *Controller,
        alloc: Allocator,
        failure: manager_mod.Failure,
    ) void {
        self.runtime.mutationRejected(alloc, failure);
    }

    pub fn mutationAccepted(
        self: *Controller,
        alloc: Allocator,
        receipt: domain.OperationReceipt,
    ) !KeyAction {
        return self.runtime.mutationAccepted(alloc, receipt);
    }

    pub fn prepareApprovalResolution(self: *Controller) ?subagent_runtime.Runtime.ApprovalSubmission {
        return self.runtime.prepareApprovalResolution();
    }

    pub fn approvalAccepted(self: *Controller, alloc: Allocator) void {
        self.runtime.approvalAccepted(alloc);
    }

    pub fn approvalRejected(
        self: *Controller,
        alloc: Allocator,
        stale: bool,
    ) !void {
        try self.runtime.approvalRejected(alloc, stale);
    }

    pub fn toggleView(self: *Controller) ToggleResult {
        self.view_active = !self.view_active;
        return .changed;
    }

    pub fn panelText(
        self: *Controller,
        alloc: Allocator,
        layout: types.Layout,
        main_approval: ?permission_request.PermissionRequest,
    ) ![]u8 {
        return subagent_runtime.paint(alloc, &self.runtime, layout, main_approval);
    }
};

pub const statusLabelPublic = subagent_runtime.statusLabelPublic;
pub const childInputFailureDisplay = subagent_runtime.childInputFailureDisplay;

test "controller opens an empty manager and ctrl x closes from a nested route" {
    const alloc = std.testing.allocator;
    var controller = Controller{};
    defer controller.deinit(alloc);
    controller.open(alloc);
    try std.testing.expect(controller.isViewActive());
    try std.testing.expectEqual(KeyAction.none, try controller.handleKey(alloc, 0x1b));
    try std.testing.expectEqual(KeyAction.redraw, try controller.handleKeyWithMainApproval(alloc, 'n', 42));
    try std.testing.expect(controller.acknowledgement() == null);
    try std.testing.expectEqual(KeyAction.close_manager, try controller.handleKey(alloc, 24));
}

test "controller settles a manager paste delivery epoch" {
    const alloc = std.testing.allocator;
    var controller = Controller{};
    defer controller.deinit(alloc);
    controller.open(alloc);

    controller.beginManagerPaste();
    for ("ROOT_PASTE_LEAK\x1b[201~") |byte| {
        try std.testing.expect(try controller.consumeManagerPasteByte(alloc, byte));
    }

    try std.testing.expect(controller.managerPasteActive());
    try std.testing.expect(controller.settleManagerPasteDeliveryEpoch(alloc));
    try std.testing.expect(!controller.managerPasteActive());
}

test "controller projection clear invalidates cached refresh state" {
    const alloc = std.testing.allocator;
    var controller = Controller{};
    defer controller.deinit(alloc);
    controller.last_refresh_ms = 42;
    controller.runtime.loading = false;

    controller.clearProjection(alloc);

    try std.testing.expectEqual(@as(i64, 0), controller.last_refresh_ms);
    try std.testing.expect(controller.runtime.loading);
    try std.testing.expectEqual(@as(usize, 0), controller.count());

    controller.setCountProjection(3);
    try std.testing.expectEqual(@as(usize, 3), controller.count());
}

test "controller exposes the child composer shortcut routing contract" {
    try std.testing.expect(@hasDecl(Controller, "childComposerFocused"));
    try std.testing.expect(@hasDecl(Controller, "childComposerEditor"));
    try std.testing.expect(@hasDecl(Controller, "moveChildInputCursor"));
    try std.testing.expect(@hasDecl(Controller, "commitChildEditorEdit"));
}
