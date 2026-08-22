const std = @import("std");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const display_width = @import("../../core/shared/display_width.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const types = @import("../../core/shared/types.zig");
const domain = @import("../../core/subagent/domain.zig");
const execution = @import("../../core/subagent/execution.zig");
const diff_mod = @import("../../core/output/diff.zig");
const transcript_presentation = @import("../../core/output/transcript_presentation.zig");
const worker_runtime = @import("../../core/agent/worker_runtime.zig");
const io_mod = @import("../../core/shared/io.zig");
const manager_mod = @import("../../core/subagent/manager.zig");
const permission_request = @import("../../core/permissions/permission_request.zig");
const projection = @import("../../core/subagent/ui_projection.zig");
const resume_admission = @import("../../core/subagent/resume_admission.zig");
const terminal_projection = @import("../../core/terminal/ui_projection.zig");
const skill_contract = @import("../../core/skills/skill_contract.zig");
const input_action = @import("../../core/input/input_action.zig");
const core_input_runtime = @import("../../core/input/runtime.zig");
const subagent_input = @import("../../core/subagent/input_action.zig");
const horizontal_navigation = @import("../../core/input/horizontal_navigation.zig");
const paste_framing = @import("../../core/input/paste_framing.zig");
const ui_input = @import("../input/runtime.zig");
const input_visual_layout = @import("../input/visual_layout.zig");
const ui_render = @import("../render.zig");
const render_request = @import("../render_request.zig");
const approval_ui = @import("../footer/approval_ui.zig");
const row_text = @import("../footer/row_text.zig");
const full_transcript_screen = @import("../full_transcript_screen.zig");
const transcript_runtime = @import("../transcript/runtime.zig");

const Allocator = std.mem.Allocator;

pub const Status = domain.State;

const PhysicalSurface = enum {
    manager,
    child_conversation,
    child_catalog,
};

pub const EntryView = struct {
    id: []const u8,
    label: []const u8,
    status: Status,
    unread_count: usize,
    external_busy: bool,
};

pub const SelectedInfo = struct {
    id: []const u8,
    label: []const u8,
    status: Status,
    unread_count: usize,
    external_busy: bool,
};

pub fn statusLabelPublic(status: Status) []const u8 {
    return switch (status) {
        .awaiting_approval => "approval",
        else => @tagName(status),
    };
}

pub const Focus = enum {
    child_list,
    archived_list,
    child_detail,
    child_composer,
    create_form,
    attach_list,
    configure_form,
    actions,
    confirmation,
    activity,
    notification,
    approval,
};

pub const Route = union(enum) {
    archived,
    create,
    attach,
    child: []u8,
    configure: []u8,
    actions: []u8,
    confirm_close: []u8,
    activity: []u8,
    notification: struct {
        child_id: []u8,
        sequence: u64,
    },
    approval: struct {
        child_id: []u8,
        approval_id: []u8,
    },
    main_approval: u64,

    fn deinit(self: *Route, alloc: Allocator) void {
        switch (self.*) {
            .archived, .create, .attach => {},
            .child, .configure, .actions, .confirm_close, .activity => |id| alloc.free(id),
            .notification => |value| alloc.free(value.child_id),
            .approval => |value| {
                alloc.free(value.child_id);
                alloc.free(value.approval_id);
            },
            .main_approval => {},
        }
        self.* = undefined;
    }
};

pub const Command = subagent_input.Command;

const RootSelection = enum { child, terminal };

pub const Action = subagent_input.Action;

pub const SubmissionFailure = struct {
    code: manager_mod.FailureCode,
    retryable: bool,
};

pub const ChildInputFailure = enum {
    message_too_large,
    invalid_utf8,
    paste_allocation_failed,
    unsafe_paste_boundary,
};

const FormField = enum {
    name,
    model,
    initial_message,
    milestones,
    interval,
    duration,
    effort,
    permission_mode,
    notifications,
    completed,
    failed,
    cancelled,
};

const FormKind = enum {
    none,
    create,
    configure,
};

const FormValidationFailure = enum {
    missing_name,
    invalid_name,
    invalid_model,
    invalid_effort,
    invalid_initial_message,
    invalid_notification_policy,
    duplicate_milestone,
    invalid_number,
    invalid_utf8,
    field_too_large,
    unsafe_paste_boundary,
    no_attach_candidate,
    attach_candidate_ineligible,
    allocation_failure,
};

const MutationFailure = union(enum) {
    validation: FormValidationFailure,
    manager: manager_mod.Failure,
    approval_stale,
    approval_commit_failed,
};

const MutationKind = enum {
    create,
    relationship,
    configure,
    cancel,
    @"resume",
    close,
    reopen,
};

const MutationAttempt = struct {
    operation_id: ?[]u8 = null,
    identity_epoch: u64 = 0,
    failure: ?MutationFailure = null,
    counter: u64 = 0,

    fn deinit(self: *MutationAttempt, alloc: Allocator) void {
        if (self.operation_id) |value| alloc.free(value);
        self.* = .{};
    }

    fn edited(self: *MutationAttempt, alloc: Allocator) void {
        if (self.operation_id) |value| alloc.free(value);
        self.operation_id = null;
        self.identity_epoch = 0;
        self.failure = null;
    }

    fn ensureOperationId(
        self: *MutationAttempt,
        alloc: Allocator,
        kind: MutationKind,
        target_id: []const u8,
        timestamp_ms: i64,
    ) ![]const u8 {
        if (self.operation_id == null) {
            self.counter +%= 1;
            self.operation_id = try std.fmt.allocPrint(
                alloc,
                "manager-ui:{s}:{s}:{d}:{d}",
                .{ @tagName(kind), target_id, timestamp_ms, self.counter },
            );
        }
        return self.operation_id.?;
    }
};

const form_editor_count: usize = 7;
const create_fields = [_]FormField{
    .name,
    .model,
    .initial_message,
    .milestones,
    .interval,
    .duration,
    .effort,
    .permission_mode,
    .notifications,
    .completed,
    .failed,
    .cancelled,
};
const configure_fields = [_]FormField{
    .name,
    .model,
    .milestones,
    .interval,
    .duration,
    .effort,
    .permission_mode,
    .completed,
    .failed,
    .cancelled,
};

const FormState = struct {
    kind: FormKind = .none,
    target_id: ?[]u8 = null,
    expected_generation: ?u64 = null,
    editors: [form_editor_count]core_input_runtime.Runtime = [_]core_input_runtime.Runtime{.{}} ** form_editor_count,
    field_index: usize = 0,
    permission_mode: types.PermissionMode = .yolo,
    notifications_enabled: bool = false,
    terminal: domain.TerminalEvents = .{},
    paste_field: ?FormField = null,
    paste_rejection: ?FormValidationFailure = null,
    attempt: MutationAttempt = .{},

    noinline fn init() FormState {
        var result: FormState = .{ .editors = undefined };
        for (&result.editors) |*editor| editor.* = .{};
        return result;
    }

    fn deinit(self: *FormState, alloc: Allocator) void {
        self.clear(alloc);
        for (&self.editors) |*editor| editor.deinit(alloc);
        self.* = undefined;
    }

    fn clear(self: *FormState, alloc: Allocator) void {
        if (self.target_id) |value| alloc.free(value);
        self.target_id = null;
        for (&self.editors) |*editor| {
            editor.inputResetState().clearCurrent(alloc);
            editor.paste.resetWithTrace(.session_reset);
        }
        self.attempt.deinit(alloc);
        self.kind = .none;
        self.expected_generation = null;
        self.field_index = 0;
        self.permission_mode = .yolo;
        self.notifications_enabled = false;
        self.terminal = .{};
        self.paste_field = null;
        self.paste_rejection = null;
    }

    fn fields(self: *const FormState) []const FormField {
        return switch (self.kind) {
            .create => &create_fields,
            .configure => &configure_fields,
            .none => &.{},
        };
    }

    fn currentField(self: *const FormState) ?FormField {
        const available = self.fields();
        if (available.len == 0) return null;
        return available[@min(self.field_index, available.len - 1)];
    }

    fn editorForField(self: *FormState, field: FormField) ?*core_input_runtime.Runtime {
        const index: ?usize = switch (field) {
            .name => 0,
            .model => 1,
            .initial_message => 2,
            .milestones => 3,
            .interval => 4,
            .duration => 5,
            .effort => 6,
            .permission_mode, .notifications, .completed, .failed, .cancelled => null,
        };
        return if (index) |value| &self.editors[value] else null;
    }

    fn replaceEditor(self: *FormState, alloc: Allocator, field: FormField, value: []const u8) !void {
        const editor = self.editorForField(field) orelse return;
        editor.inputResetState().clearCurrent(alloc);
        try editor.insertionState().insertSlice(alloc, value, .preserve);
    }

    fn edit(self: *FormState, alloc: Allocator) void {
        self.attempt.edited(alloc);
        self.paste_rejection = null;
        if (self.kind == .create) {
            const current_field = self.currentField() orelse return;
            switch (current_field) {
                .milestones, .interval, .duration, .completed, .failed, .cancelled => self.notifications_enabled = true,
                else => {},
            }
        }
    }
};

const AttachState = struct {
    candidates: std.ArrayList(projection.AttachCandidate) = .empty,
    selected: usize = 0,
    has_more: bool = false,
    continuation: ?resume_admission.ActionableContinuation = null,
    loading: bool = false,
    selection_stale: bool = false,
    attempt: MutationAttempt = .{},

    fn deinit(self: *AttachState, alloc: Allocator) void {
        self.clear(alloc);
        self.candidates.deinit(alloc);
        self.* = .{};
    }

    fn clear(self: *AttachState, alloc: Allocator) void {
        for (self.candidates.items) |*candidate| candidate.deinit(alloc);
        self.candidates.clearRetainingCapacity();
        if (self.continuation) |*continuation| continuation.deinit(alloc);
        self.continuation = null;
        self.attempt.deinit(alloc);
        self.selected = 0;
        self.has_more = false;
        self.loading = false;
        self.selection_stale = false;
    }

    fn selectedCandidate(self: *const AttachState) ?*const projection.AttachCandidate {
        if (self.selected >= self.candidates.items.len) return null;
        return &self.candidates.items[self.selected];
    }
};

const MainApprovalCard = struct {
    prompt_id: u64,
    child_id: []u8,
    child_name: []u8,
    approval_id: []u8,
    label: []u8,
    explanation: ?[]u8,
    tool_arguments_preview: ?[]u8 = null,
    command: ?[]u8 = null,
    file: ?permission_request.FileApprovalRequest = null,

    fn deinit(self: *MainApprovalCard, alloc: Allocator) void {
        alloc.free(self.child_id);
        alloc.free(self.child_name);
        alloc.free(self.approval_id);
        alloc.free(self.label);
        if (self.explanation) |value| alloc.free(value);
        if (self.tool_arguments_preview) |value| alloc.free(value);
        if (self.command) |value| alloc.free(value);
        if (self.file) |value| {
            permission_request.deinitFileApprovalRequest(alloc, value);
        }
        self.* = undefined;
    }
};

pub const MainApprovalBinding = struct {
    child_id: []const u8,
    approval_id: []const u8,
};

const ViewportMutation = enum {
    none,
    bottom,
    prepend,
};

fn validChildMessage(text: []const u8) bool {
    return std.unicode.utf8ValidateSlice(text) and
        std.mem.findScalar(u8, text, 0) == null;
}

fn childDraftFailure(text: []const u8) ?ChildInputFailure {
    if (text.len > domain.max_message_bytes) return .message_too_large;
    if (!validChildMessage(text)) return .invalid_utf8;
    return null;
}

fn childInputFailureTraceLabel(failure: ChildInputFailure) []const u8 {
    return switch (failure) {
        .message_too_large => "message_too_large",
        .invalid_utf8 => "invalid_utf8",
        .paste_allocation_failed => "allocation_failure",
        .unsafe_paste_boundary => "unsafe_paste_boundary",
    };
}

pub fn childInputFailureDisplay(failure: ChildInputFailure) []const u8 {
    return switch (failure) {
        .message_too_large => "Message too large",
        .invalid_utf8 => "Invalid UTF-8",
        .paste_allocation_failed => "Paste allocation failed",
        .unsafe_paste_boundary => "Paste contained input after its end marker",
    };
}

const FormParseError = error{
    InvalidNotificationPolicy,
    DuplicateMilestone,
};

fn parseMilestones(
    raw: []const u8,
    out: *[domain.max_milestones][]const u8,
) FormParseError![]const []const u8 {
    var count: usize = 0;
    var tokens = std.mem.splitScalar(u8, raw, ',');
    while (tokens.next()) |token| {
        const value = std.mem.trim(u8, token, " \t\r\n");
        if (value.len == 0) continue;
        if (count == out.len) return error.InvalidNotificationPolicy;
        for (out[0..count]) |prior| {
            if (std.mem.eql(u8, prior, value)) return error.DuplicateMilestone;
        }
        out[count] = value;
        count += 1;
    }
    return out[0..count];
}

fn parseOptionalU64(raw: []const u8) !?u64 {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) return null;
    return try std.fmt.parseInt(u64, value, 10);
}

fn mapFormValidationError(err: anyerror) FormValidationFailure {
    return switch (err) {
        error.MissingName => .missing_name,
        error.InvalidName => .invalid_name,
        error.InvalidModel => .invalid_model,
        error.InvalidPrompt, error.InvalidMessage => .invalid_initial_message,
        error.InvalidNotificationPolicy => .invalid_notification_policy,
        error.DuplicateMilestone => .duplicate_milestone,
        error.OutOfMemory => .allocation_failure,
        else => .invalid_notification_policy,
    };
}

fn formFieldMaxBytes(field: FormField) usize {
    return switch (field) {
        .name => domain.max_name_bytes,
        .model => domain.max_model_bytes,
        .initial_message => domain.max_prompt_bytes,
        .milestones => domain.max_milestones * domain.max_name_bytes,
        .interval, .duration => 20,
        .effort => types.ReasoningEffort.max_name_bytes,
        .permission_mode, .notifications, .completed, .failed, .cancelled => 0,
    };
}

fn formValidationDisplay(failure: FormValidationFailure) []const u8 {
    return switch (failure) {
        .missing_name => "Name is required",
        .invalid_name => "Name is invalid",
        .invalid_model => "Model is invalid",
        .invalid_effort => "Effort is invalid",
        .invalid_initial_message => "Initial message is invalid",
        .invalid_notification_policy => "Notification policy is invalid",
        .duplicate_milestone => "Milestones must be unique",
        .invalid_number => "Interval and duration must be positive integers",
        .invalid_utf8 => "Field contains invalid UTF-8",
        .field_too_large => "Field exceeds its byte limit",
        .unsafe_paste_boundary => "Paste contained input after its end marker",
        .no_attach_candidate => "No attach candidate is selected",
        .attach_candidate_ineligible => "Selected chat is busy or no longer eligible",
        .allocation_failure => "Unable to allocate form state",
    };
}

fn nextPermissionMode(mode: types.PermissionMode) types.PermissionMode {
    return switch (mode) {
        .ask => .auto,
        .auto => .yolo,
        .yolo => .ask,
    };
}

fn previousPermissionMode(mode: types.PermissionMode) types.PermissionMode {
    return switch (mode) {
        .ask => .yolo,
        .auto => .ask,
        .yolo => .auto,
    };
}

fn hasStopCondition(
    conditions: []const domain.StopCondition,
    expected: domain.StopCondition,
) bool {
    for (conditions) |condition| if (condition == expected) return true;
    return false;
}

fn childHasActiveWork(state: domain.State) bool {
    return state == .queued or state == .running or state == .awaiting_approval;
}

fn sameLivePresentationVersion(
    current: ?execution.LivePresentation,
    next: ?execution.LivePresentation,
) bool {
    if ((current == null) != (next == null)) return false;
    if (current == null) return true;
    return current.?.revision == next.?.revision and
        std.mem.eql(u8, current.?.work_id, next.?.work_id);
}

fn sameRichPresentationFrontier(
    current: ?execution.LivePresentation,
    next: ?execution.LivePresentation,
) bool {
    if (current == null or next == null) return false;
    return current.?.events.len > 0 and
        current.?.events.len == next.?.events.len and
        current.?.events_truncated == next.?.events_truncated and
        std.mem.eql(u8, current.?.work_id, next.?.work_id);
}

fn livePresentationExtends(
    presented_work_id: ?[]const u8,
    presented_event_count: usize,
    next: ?execution.LivePresentation,
) bool {
    const work_id = presented_work_id orelse return false;
    const live = next orelse return false;
    return std.mem.eql(u8, work_id, live.work_id) and
        live.events.len > presented_event_count;
}

fn buildMainApprovalCard(
    alloc: Allocator,
    snapshot: projection.Snapshot,
    selected_index: usize,
) !?MainApprovalCard {
    if (selectedPendingApproval(snapshot, selected_index)) |pending| {
        const card = try buildMainApprovalCardFor(
            alloc,
            pending.child_id,
            pending.child_name,
            pending.request,
            pending.tool_arguments_preview,
        );
        return card;
    }
    for (snapshot.nodes) |node| {
        for (node.approvals) |approval| {
            if (approval.status != .pending) continue;
            const card = try buildMainApprovalCardFor(
                alloc,
                node.child_id,
                node.name,
                approval,
                null,
            );
            return card;
        }
    }
    return null;
}

fn selectedPendingApproval(
    snapshot: projection.Snapshot,
    selected_index: usize,
) ?*const projection.PendingApproval {
    if (selected_index >= snapshot.pending_approvals.len) return null;
    const pending = &snapshot.pending_approvals[selected_index];
    if (pending.request.status != .pending) return null;
    return pending;
}

fn pendingApprovalIndex(
    snapshot: projection.Snapshot,
    child_id: []const u8,
    approval_id: []const u8,
) ?usize {
    for (snapshot.pending_approvals, 0..) |pending, index| {
        if (std.mem.eql(u8, pending.child_id, child_id) and
            std.mem.eql(u8, pending.request.id, approval_id)) return index;
    }
    return null;
}

fn approvalCardStillPending(
    snapshot: projection.Snapshot,
    card: MainApprovalCard,
) bool {
    if (pendingApprovalIndex(snapshot, card.child_id, card.approval_id) != null) {
        return true;
    }
    const node = findNodeIn(snapshot.nodes, card.child_id) orelse return false;
    for (node.approvals) |approval| {
        if (approval.status == .pending and
            std.mem.eql(u8, approval.id, card.approval_id)) return true;
    }
    return false;
}

fn buildMainApprovalCardFor(
    alloc: Allocator,
    child_id_value: []const u8,
    child_name: []const u8,
    approval: projection.Approval,
    tool_arguments_preview: ?[]const u8,
) !MainApprovalCard {
    const child_id = try alloc.dupe(u8, child_id_value);
    errdefer alloc.free(child_id);
    const child_name_copy = try alloc.dupe(u8, child_name);
    errdefer alloc.free(child_name_copy);
    const approval_id = try alloc.dupe(u8, approval.id);
    errdefer alloc.free(approval_id);
    const label = try alloc.dupe(u8, approval.label);
    errdefer alloc.free(label);
    const explanation = if (approval.explanation) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (explanation) |value| alloc.free(value);
    const tool_arguments_preview_copy = if (tool_arguments_preview) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (tool_arguments_preview_copy) |value| alloc.free(value);
    const command = if (approval.command) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (command) |value| alloc.free(value);
    const file = if (approval.file) |value|
        try permission_request.dupeFileApprovalRequest(alloc, value)
    else
        null;
    errdefer if (file) |value| {
        permission_request.deinitFileApprovalRequest(alloc, value);
    };
    return .{
        .prompt_id = mainApprovalPromptId(child_id_value, approval.id),
        .child_id = child_id,
        .child_name = child_name_copy,
        .approval_id = approval_id,
        .label = label,
        .explanation = explanation,
        .tool_arguments_preview = tool_arguments_preview_copy,
        .command = command,
        .file = file,
    };
}

fn approvalRouteForCard(
    alloc: Allocator,
    card: ?MainApprovalCard,
) !?Route {
    const current = card orelse return null;
    const child_id = try alloc.dupe(u8, current.child_id);
    errdefer alloc.free(child_id);
    return .{ .approval = .{
        .child_id = child_id,
        .approval_id = try alloc.dupe(u8, current.approval_id),
    } };
}

fn mainApprovalPromptId(child_id: []const u8, approval_id: []const u8) u64 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.subagent.main-approval.v1\x00");
    hash.update(child_id);
    hash.update("\x00");
    hash.update(approval_id);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.mem.readInt(u64, digest[0..8], .little) | (@as(u64, 1) << 63);
}

fn sameMainApprovalCard(a: ?MainApprovalCard, b: ?MainApprovalCard) bool {
    if ((a == null) != (b == null)) return false;
    if (a == null) return true;
    return std.mem.eql(u8, a.?.child_id, b.?.child_id) and
        std.mem.eql(u8, a.?.approval_id, b.?.approval_id);
}

pub const ChildRouteState = struct {
    chat: ?projection.ChildChat = null,
    unavailable: ?projection.ChildUnavailable = null,
    pages: projection.ChildChatPageCache = .{},
    editor: core_input_runtime.Runtime = .{},
    scroll_from_bottom: usize = 0,
    max_scroll: usize = 0,
    invocation_id: ?[]u8 = null,
    identity_epoch: u64 = 0,
    submission_failure: ?SubmissionFailure = null,
    input_failure: ?ChildInputFailure = null,
    paste_rejection: ?ChildInputFailure = null,
    operation_counter: u64 = 0,
    rendered_chat_rows: ?usize = null,
    viewport_mutation: ViewportMutation = .none,
    presentation: ?transcript_runtime.TranscriptRuntime = null,
    presentation_transcript_depth: transcript_presentation.Depth = .inline_mode,
    presentation_live_work_id: ?[]u8 = null,
    presentation_live_event_count: usize = 0,
    presentation_next_diff_id: u32 = 1,
    presentation_diffs: std.ArrayList(diff_mod.DiffEntry) = .empty,
    presented_through_sequence: u64 = 0,

    noinline fn init() ChildRouteState {
        var result: ChildRouteState = .{
            .editor = undefined,
            .presentation = undefined,
        };
        result.editor = .{};
        result.presentation = null;
        return result;
    }

    fn deinit(self: *ChildRouteState, alloc: Allocator) void {
        self.clear(alloc);
        self.pages.deinit(alloc);
        self.editor.deinit(alloc);
        self.* = undefined;
    }

    fn clear(self: *ChildRouteState, alloc: Allocator) void {
        self.clearViewPreservingDraft(alloc);
        self.editor.inputResetState().clearCurrent(alloc);
        if (self.invocation_id) |invocation_id| alloc.free(invocation_id);
        self.invocation_id = null;
        self.identity_epoch = 0;
        self.submission_failure = null;
        self.input_failure = null;
        self.paste_rejection = null;
    }

    fn clearViewPreservingDraft(self: *ChildRouteState, alloc: Allocator) void {
        if (self.chat) |*chat| chat.deinit(alloc);
        self.chat = null;
        self.unavailable = null;
        self.pages.clear(alloc);
        self.editor.paste.resetWithTrace(.session_reset);
        self.scroll_from_bottom = 0;
        self.max_scroll = 0;
        self.rendered_chat_rows = null;
        self.viewport_mutation = .none;
        self.clearPresentation(alloc);
        self.presentation_transcript_depth = .inline_mode;
        self.presented_through_sequence = 0;
    }

    fn clearPresentation(self: *ChildRouteState, alloc: Allocator) void {
        if (self.presentation) |*runtime| runtime.deinit(alloc);
        self.presentation = null;
        for (self.presentation_diffs.items) |*entry| {
            entry.deinit(std.heap.c_allocator);
        }
        self.presentation_diffs.deinit(std.heap.c_allocator);
        self.presentation_diffs = .empty;
        if (self.presentation_live_work_id) |work_id| alloc.free(work_id);
        self.presentation_live_work_id = null;
        self.presentation_live_event_count = 0;
        self.presentation_next_diff_id = 1;
    }

    fn edited(self: *ChildRouteState, alloc: Allocator) void {
        if (self.invocation_id) |invocation_id| alloc.free(invocation_id);
        self.invocation_id = null;
        self.identity_epoch = 0;
        self.submission_failure = null;
        self.input_failure = null;
    }
};

pub const ChildPresentationView = struct {
    chat: *const projection.ChildChat,
    pages: *const projection.ChildChatPageCache,
    editor: *const core_input_runtime.Runtime,
    submission_failure: ?SubmissionFailure,
    input_failure: ?ChildInputFailure,
    rows_from_bottom: u32,
    prior_total_rows: ?u32,
    preserve_after_append: bool,
};

const ChildViewportBookmark = struct {
    rows_from_bottom: usize,
    prior_total_rows: ?usize,
    full_transcript: ?transcript_presentation.Snapshot,
};

const ChildDraft = struct {
    child_id: []u8,
    editor: core_input_runtime.Runtime = .{},

    fn deinit(self: *ChildDraft, alloc: Allocator) void {
        alloc.free(self.child_id);
        self.editor.deinit(alloc);
        self.* = undefined;
    }
};

pub const ChildAcknowledgement = struct {
    child_id: []const u8,
    through_sequence: u64,
};

const PendingChildAcknowledgement = struct {
    child_id: []u8,
    through_sequence: u64,

    fn deinit(self: *PendingChildAcknowledgement, alloc: Allocator) void {
        alloc.free(self.child_id);
        self.* = undefined;
    }
};

pub const Runtime = struct {
    render_requests: render_request.RenderRequestState = .{},
    loading: bool = true,
    degraded: ?manager_mod.FailureCode = null,
    snapshot: ?projection.Snapshot = null,
    terminal_snapshot: ?terminal_projection.Snapshot = null,
    selected_id: ?[]u8 = null,
    selected_terminal_id: ?[]u8 = null,
    root_selection: RootSelection = .child,
    archived_selected_id: ?[]u8 = null,
    routes: std.ArrayList(Route) = .empty,
    page_cursor: ?[]u8 = null,
    page_history: std.ArrayList(?[]u8) = .empty,
    preserve_page_anchor: bool = true,
    pending_approval_offset: usize = 0,
    pending_approval_selection: usize = 0,
    focus: Focus = .child_list,
    list_scroll: usize = 0,
    terminal_scroll: usize = 0,
    archived_scroll: usize = 0,
    detail_scroll: usize = 0,
    child: ChildRouteState = .{},
    child_drafts: std.ArrayList(ChildDraft) = .empty,
    selected_child_viewport: ?ChildViewportBookmark = null,
    pending_child_acknowledgement: ?PendingChildAcknowledgement = null,
    default_model: ?[]u8 = null,
    default_effort: types.ReasoningEffort = .auto,
    form: FormState = .{},
    attach: AttachState = .{},
    lifecycle_attempt: MutationAttempt = .{},
    lifecycle_action: ?domain.LifecycleAction = null,
    approval_failure: ?MutationFailure = null,
    approval_decision: ?types.ToolPermissionDecision = null,
    main_approval_card: ?MainApprovalCard = null,
    main_approval_presented: bool = false,
    main_approval_dismissed: bool = false,
    physical_surface: PhysicalSurface = .manager,
    count_projection: usize = 0,

    pub noinline fn init() Runtime {
        var result: Runtime = .{
            .child = undefined,
            .form = undefined,
        };
        result.child = ChildRouteState.init();
        result.form = FormState.init();
        return result;
    }

    pub fn deinit(self: *Runtime, alloc: Allocator) void {
        self.clearProjection(alloc);
        self.clearTerminalProjection(alloc);
        self.clearRoutes(alloc);
        self.routes.deinit(alloc);
        self.page_history.deinit(alloc);
        self.child.deinit(alloc);
        self.clearChildDrafts(alloc);
        self.child_drafts.deinit(alloc);
        if (self.default_model) |value| alloc.free(value);
        self.form.deinit(alloc);
        self.attach.deinit(alloc);
        self.lifecycle_attempt.deinit(alloc);
        if (self.main_approval_card) |*card| card.deinit(alloc);
        self.* = undefined;
    }

    pub fn resetForOpen(self: *Runtime, alloc: Allocator) void {
        self.rememberSelectedChildViewport();
        self.child.clearViewPreservingDraft(alloc);
        self.clearRouteLocalState(alloc);
        self.clearRoutes(alloc);
        self.render_requests = .{};
        self.physical_surface = .manager;
        self.focus = .child_list;
        self.detail_scroll = 0;
        if (self.snapshot == null and self.degraded == null) self.loading = true;
    }

    pub fn setDefaults(
        self: *Runtime,
        alloc: Allocator,
        model: []const u8,
        effort: types.ReasoningEffort,
    ) !void {
        const replacement = try alloc.dupe(u8, model);
        if (self.default_model) |value| alloc.free(value);
        self.default_model = replacement;
        self.default_effort = effort;
    }

    pub fn mainApprovalRequest(self: *const Runtime) ?permission_request.PermissionRequest {
        if (self.main_approval_dismissed) return null;
        const card = self.main_approval_card orelse return null;
        return .{
            .id = card.prompt_id,
            .label = card.label,
            .origin = .{ .subagent = card.child_name },
            .explanation = card.explanation,
            .tool_arguments_preview = card.tool_arguments_preview,
            .command = card.command,
            .file = card.file,
            .amendment_allowed = false,
        };
    }

    pub fn markMainApprovalPresented(self: *Runtime, presented: bool) void {
        self.main_approval_presented = presented;
    }

    pub fn mainApprovalPresented(self: Runtime) bool {
        return self.main_approval_presented;
    }

    pub fn mainApprovalBinding(self: *const Runtime, prompt_id: u64) ?MainApprovalBinding {
        if (!self.main_approval_presented) return null;
        const card = self.main_approval_card orelse return null;
        if (card.prompt_id != prompt_id) return null;
        return .{ .child_id = card.child_id, .approval_id = card.approval_id };
    }

    pub fn dismissMainApproval(self: *Runtime) void {
        self.main_approval_presented = false;
        self.main_approval_dismissed = true;
    }

    fn clearRouteLocalState(self: *Runtime, alloc: Allocator) void {
        self.form.clear(alloc);
        self.attach.clear(alloc);
        self.lifecycle_attempt.deinit(alloc);
        self.lifecycle_action = null;
        self.approval_failure = null;
        self.approval_decision = null;
    }

    fn clearMainApprovalCard(self: *Runtime, alloc: Allocator) void {
        if (self.main_approval_card) |*card| card.deinit(alloc);
        self.main_approval_card = null;
        self.main_approval_presented = false;
        self.main_approval_dismissed = false;
    }

    pub fn clearProjection(self: *Runtime, alloc: Allocator) void {
        self.clearChildSelectionState(alloc, "projection_cleared");
        if (self.snapshot) |*snapshot| snapshot.deinit(alloc);
        self.snapshot = null;
        if (self.selected_id) |id| alloc.free(id);
        self.selected_id = null;
        if (self.archived_selected_id) |id| alloc.free(id);
        self.archived_selected_id = null;
        if (self.page_cursor) |cursor| alloc.free(cursor);
        self.page_cursor = null;
        self.clearPageHistory(alloc);
        self.preserve_page_anchor = true;
        self.pending_approval_offset = 0;
        self.pending_approval_selection = 0;
        self.degraded = null;
        self.loading = true;
        self.list_scroll = 0;
        self.archived_scroll = 0;
        self.selected_child_viewport = null;
        self.count_projection = 0;
        self.clearMainApprovalCard(alloc);
    }

    pub fn setCountProjection(self: *Runtime, projected_count: usize) void {
        if (self.snapshot == null) self.count_projection = projected_count;
    }

    pub fn clearTerminalProjection(self: *Runtime, alloc: Allocator) void {
        if (self.terminal_snapshot) |*snapshot| snapshot.deinit();
        self.terminal_snapshot = null;
        if (self.selected_terminal_id) |id| alloc.free(id);
        self.selected_terminal_id = null;
        self.root_selection = .child;
        self.terminal_scroll = 0;
    }

    pub fn replaceTerminalSnapshot(
        self: *Runtime,
        alloc: Allocator,
        next_snapshot: terminal_projection.Snapshot,
    ) !bool {
        var next = next_snapshot;
        errdefer next.deinit();
        if (terminalSnapshotsEqual(self.terminal_snapshot, next)) {
            next.deinit();
            return false;
        }
        var selected: ?[]u8 = null;
        errdefer if (selected) |id| alloc.free(id);
        if (self.selected_terminal_id) |current| {
            if (findVisibleTerminal(next.rows, current) != null) {
                selected = try alloc.dupe(u8, current);
            }
        }
        if (selected == null) {
            if (firstVisibleTerminal(next.rows)) |row| {
                selected = try alloc.dupe(u8, row.session_id);
            }
        }
        if (self.terminal_snapshot) |*snapshot| snapshot.deinit();
        if (self.selected_terminal_id) |id| alloc.free(id);
        self.terminal_snapshot = next;
        self.selected_terminal_id = selected;
        if (self.selectedNode() == null and selected != null and
            self.routes.items.len == 0)
        {
            self.root_selection = .terminal;
        } else if (selected == null) {
            self.root_selection = .child;
            self.terminal_scroll = 0;
        }
        return true;
    }

    pub fn selectedTerminalId(self: *const Runtime) ?[]const u8 {
        if (self.routes.items.len != 0 or self.root_selection != .terminal) {
            return null;
        }
        return self.selected_terminal_id;
    }

    pub fn setDegraded(self: *Runtime, alloc: Allocator, failure: manager_mod.FailureCode) void {
        if (self.snapshot) |*snapshot| snapshot.deinit(alloc);
        self.snapshot = null;
        self.count_projection = 0;
        self.degraded = failure;
        self.loading = false;
        self.clearMainApprovalCard(alloc);
    }

    /// Installs a new owned projection without changing the active route,
    /// focus, or immutable-ID selection.
    pub fn replaceSnapshot(self: *Runtime, alloc: Allocator, next_snapshot: projection.Snapshot) !bool {
        var next = next_snapshot;
        errdefer next.deinit(alloc);
        const refreshed_form_generation: ?u64 = if (self.form.kind == .configure and
            self.form.expected_generation == null)
        blk: {
            if (self.form.target_id) |target_id| {
                if (findNodeIn(next.nodes, target_id)) |node| {
                    break :blk node.generation;
                }
            }
            break :blk null;
        } else null;
        if (self.snapshot) |current| {
            if (std.mem.eql(u8, current.root_id, next.root_id) and
                current.content_hash == next.content_hash)
            {
                if (refreshed_form_generation) |generation| {
                    self.form.expected_generation = generation;
                }
                var unchanged = next;
                unchanged.deinit(alloc);
                return false;
            }
        }

        const next_approval_selection = self.nextPendingApprovalSelection(next);
        var next_main_approval = try buildMainApprovalCard(
            alloc,
            next,
            next_approval_selection,
        );
        errdefer if (next_main_approval) |*card| card.deinit(alloc);
        const retarget_approval_route = self.approvalRouteNeedsRetarget(next);
        var next_approval_route = if (retarget_approval_route)
            try approvalRouteForCard(alloc, next_main_approval)
        else
            null;
        errdefer if (next_approval_route) |*route| route.deinit(alloc);
        const preserve_main_dismissal = sameMainApprovalCard(
            self.main_approval_card,
            next_main_approval,
        ) and self.main_approval_dismissed;

        const preserve_anchor = self.preserve_page_anchor;
        const active_offset = if (preserve_anchor)
            selectionViewportOffset(self.snapshot, self.selected_id, self.list_scroll, false)
        else
            null;
        const archived_offset = if (preserve_anchor)
            selectionViewportOffset(self.snapshot, self.archived_selected_id, self.archived_scroll, true)
        else
            null;

        var selected_copy: ?[]u8 = null;
        errdefer if (selected_copy) |id| alloc.free(id);
        if (self.selected_id) |selected| {
            if (findNodeIn(next.nodes, selected)) |node| {
                if (node.state != .archived) selected_copy = try alloc.dupe(u8, selected);
            }
        }
        if (selected_copy == null) {
            if (firstNode(next.nodes, false)) |node| {
                selected_copy = try alloc.dupe(u8, node.child_id);
            }
        }
        const selection_unchanged = if (self.selected_id) |current|
            if (selected_copy) |selected|
                std.mem.eql(u8, current, selected)
            else
                false
        else
            selected_copy == null;

        var archived_copy: ?[]u8 = null;
        errdefer if (archived_copy) |id| alloc.free(id);
        if (self.archived_selected_id) |selected| {
            if (findNodeIn(next.nodes, selected)) |node| {
                if (node.state == .archived) archived_copy = try alloc.dupe(u8, selected);
            }
        }
        if (archived_copy == null) {
            if (firstNode(next.nodes, true)) |node| {
                archived_copy = try alloc.dupe(u8, node.child_id);
            }
        }

        const next_page_cursor = if (next.page_cursor) |cursor|
            try alloc.dupe(u8, cursor)
        else
            null;
        errdefer if (next_page_cursor) |cursor| alloc.free(cursor);

        if (next.restart_required) self.clearPageHistory(alloc);
        if (self.page_cursor) |cursor| alloc.free(cursor);
        self.page_cursor = next_page_cursor;
        self.preserve_page_anchor = true;
        self.pending_approval_offset = next.pending_approval_offset;
        self.pending_approval_selection = next_approval_selection;

        if (self.snapshot) |*snapshot| snapshot.deinit(alloc);
        if (self.selected_id) |id| alloc.free(id);
        if (self.archived_selected_id) |id| alloc.free(id);
        self.snapshot = next;
        if (self.main_approval_card) |*card| card.deinit(alloc);
        self.main_approval_card = next_main_approval;
        next_main_approval = null;
        self.main_approval_presented = false;
        self.main_approval_dismissed = preserve_main_dismissal;
        if (retarget_approval_route) {
            self.replaceCurrentApprovalRoute(alloc, next_approval_route);
            next_approval_route = null;
        }
        self.selected_id = selected_copy;
        if (!selection_unchanged) self.clearChildSelectionState(alloc, "snapshot_selection_changed");
        if (self.pending_child_acknowledgement) |pending| {
            if (findNodeIn(next.nodes, pending.child_id)) |node| {
                if (node.unread_count == 0) self.clearPendingChildAcknowledgement(alloc);
            }
        }
        self.archived_selected_id = archived_copy;
        self.degraded = null;
        self.loading = false;
        self.list_scroll = restoredScroll(next.nodes, self.selected_id, active_offset, false);
        self.archived_scroll = restoredScroll(next.nodes, self.archived_selected_id, archived_offset, true);
        if (refreshed_form_generation) |generation| {
            self.form.expected_generation = generation;
        }
        return true;
    }

    fn approvalRouteNeedsRetarget(
        self: Runtime,
        snapshot: projection.Snapshot,
    ) bool {
        if (self.approval_decision != null or self.approval_failure != null) return false;
        const route = self.currentRoute() orelse return false;
        return switch (route.*) {
            .approval => |value| pendingApprovalIndex(
                snapshot,
                value.child_id,
                value.approval_id,
            ) == null,
            else => false,
        };
    }

    fn replaceCurrentApprovalRoute(
        self: *Runtime,
        alloc: Allocator,
        replacement: ?Route,
    ) void {
        var owned_replacement = replacement;
        const route = self.currentRoute() orelse {
            if (owned_replacement) |*owned| owned.deinit(alloc);
            return;
        };
        switch (route.*) {
            .approval => {},
            else => {
                if (owned_replacement) |*owned| owned.deinit(alloc);
                return;
            },
        }
        var removed = self.routes.pop().?;
        removed.deinit(alloc);
        if (owned_replacement) |value| self.routes.appendAssumeCapacity(value);
        self.syncFocus();
    }

    pub fn pageCursor(self: Runtime) ?[]const u8 {
        return self.page_cursor;
    }

    pub fn pendingApprovalOffset(self: Runtime) usize {
        return self.pending_approval_offset;
    }

    pub fn approvalRevision(self: Runtime) u64 {
        return if (self.snapshot) |snapshot| snapshot.approval_revision else 0;
    }

    fn nextPendingApprovalSelection(
        self: Runtime,
        snapshot: projection.Snapshot,
    ) usize {
        if (snapshot.pending_approvals.len == 0) return 0;
        if (self.main_approval_card) |card| {
            if (pendingApprovalIndex(snapshot, card.child_id, card.approval_id)) |index| {
                return index;
            }
        }
        return @min(
            self.pending_approval_selection,
            snapshot.pending_approvals.len - 1,
        );
    }

    fn movePendingApprovalSelection(
        self: *Runtime,
        alloc: Allocator,
        direction: i8,
    ) !Command {
        const snapshot = self.snapshot orelse return .none;
        if (snapshot.pending_approvals.len == 0) return .none;
        const next_index = if (direction < 0)
            self.pending_approval_selection -| 1
        else
            @min(
                self.pending_approval_selection +| 1,
                snapshot.pending_approvals.len - 1,
            );
        if (next_index == self.pending_approval_selection) return .none;

        var next_card = (try buildMainApprovalCard(alloc, snapshot, next_index)).?;
        errdefer next_card.deinit(alloc);
        var next_route = (try approvalRouteForCard(alloc, next_card)).?;
        errdefer next_route.deinit(alloc);

        if (self.main_approval_card) |*card| card.deinit(alloc);
        self.main_approval_card = next_card;
        self.main_approval_presented = false;
        self.main_approval_dismissed = false;
        self.pending_approval_selection = next_index;
        self.replaceCurrentApprovalRoute(alloc, next_route);
        self.detail_scroll = 0;
        return .redraw;
    }

    fn nextPendingApprovalPage(self: *Runtime) Command {
        const snapshot = self.snapshot orelse return .none;
        const next_offset = snapshot.pending_approval_next_offset orelse return .none;
        self.pending_approval_offset = next_offset;
        self.pending_approval_selection = 0;
        return .page_changed;
    }

    fn previousPendingApprovalPage(self: *Runtime) Command {
        const snapshot = self.snapshot orelse return .none;
        const previous_offset = snapshot.pending_approval_previous_offset orelse return .none;
        self.pending_approval_offset = previous_offset;
        self.pending_approval_selection = 0;
        return .page_changed;
    }

    pub fn pageAnchorId(self: Runtime) ?[]const u8 {
        if (!self.preserve_page_anchor) return null;
        if (self.currentRoute()) |route| {
            return switch (route.*) {
                .archived => self.archived_selected_id,
                .create, .attach => self.selected_id,
                .child, .configure, .actions, .confirm_close, .activity => |id| id,
                .notification => |value| value.child_id,
                .approval => |value| value.child_id,
                .main_approval => self.selected_id,
            };
        }
        return self.selected_id;
    }

    pub fn childRouteId(self: *const Runtime) ?[]const u8 {
        const route = self.currentRoute() orelse return null;
        return switch (route.*) {
            .child => |child_id| child_id,
            else => null,
        };
    }

    pub fn pendingChildAcknowledgement(self: Runtime) ?ChildAcknowledgement {
        const pending = self.pending_child_acknowledgement orelse return null;
        return .{
            .child_id = pending.child_id,
            .through_sequence = pending.through_sequence,
        };
    }

    pub fn childAcknowledgementAttempted(
        self: *Runtime,
        alloc: Allocator,
        child_id: []const u8,
        through_sequence: u64,
    ) void {
        const pending = self.pending_child_acknowledgement orelse return;
        if (pending.through_sequence != through_sequence or
            !std.mem.eql(u8, pending.child_id, child_id))
        {
            return;
        }
        self.clearPendingChildAcknowledgement(alloc);
    }

    pub fn visibleChildAcknowledgementSequence(self: Runtime) ?u64 {
        if (self.childRouteId() == null) return null;
        const node = self.routedNode() orelse return null;
        if (node.unread_count == 0 or self.child.presented_through_sequence == 0) return null;
        return self.child.presented_through_sequence;
    }

    pub fn childPresentationView(self: *const Runtime) ?ChildPresentationView {
        _ = self.childRouteId() orelse return null;
        const chat = if (self.child.chat) |*value| value else return null;
        return .{
            .chat = chat,
            .pages = &self.child.pages,
            .editor = &self.child.editor,
            .submission_failure = self.child.submission_failure,
            .input_failure = self.child.input_failure,
            .rows_from_bottom = @intCast(@min(
                self.child.scroll_from_bottom,
                std.math.maxInt(u32),
            )),
            .prior_total_rows = if (self.child.rendered_chat_rows) |rows|
                @intCast(@min(rows, std.math.maxInt(u32)))
            else
                null,
            .preserve_after_append = self.child.viewport_mutation == .bottom,
        };
    }

    pub fn clearChildComposer(self: *Runtime, alloc: Allocator) void {
        debug_trace.logf(
            "subagent",
            "child composer cleared reason=local_command bytes={d}",
            .{self.child.editor.edit_state.input.items.len},
        );
        self.child.editor.inputResetState().clearCurrent(alloc);
        self.child.editor.paste.resetWithTrace(.session_reset);
        self.child.edited(alloc);
    }

    pub fn childComposerFocused(self: *const Runtime) bool {
        return self.childComposerEditable();
    }

    pub fn childComposerEditor(self: *Runtime) ?*core_input_runtime.Runtime {
        if (!self.childComposerEditable()) return null;
        return &self.child.editor;
    }

    pub fn moveChildInputCursor(
        self: *Runtime,
        intent: input_action.MoveIntent,
        terminal_cols: u16,
        page_rows: usize,
    ) bool {
        if (!self.childComposerEditable()) return false;
        const direction: input_visual_layout.Direction = switch (intent.kind) {
            .visual_up, .page_up => .up,
            .visual_down, .page_down => .down,
            else => return self.child.editor.moveInputCursor(intent),
        };
        const scan = if (intent.kind == .page_up or intent.kind == .page_down)
            ui_input.scanInputCursorRows(&self.child.editor, direction, page_rows, terminal_cols, &.{})
        else
            ui_input.scanInputCursorVertical(&self.child.editor, direction, terminal_cols, &.{});
        return self.child.editor.vertical_navigation.applyTargetWithSelection(
            &self.child.editor.edit_state,
            &self.child.editor.entities,
            if (scan.target) |target| target.raw_offset else null,
            scan.preferred_column,
            intent.extend_selection,
        );
    }

    pub fn commitChildEditorEdit(self: *Runtime, alloc: Allocator) void {
        if (!self.childComposerEditable()) return;
        self.child.edited(alloc);
    }

    pub fn bindSelectedChildSkill(
        self: *Runtime,
        alloc: Allocator,
        name: []const u8,
        path: []const u8,
        display_source: ?skill_contract.SkillSource,
    ) !bool {
        _ = self.childRouteId() orelse return false;
        const replace_end = self.child.editor.edit_state.input.items.len;
        const inserted_len = self.child.editor.entities.skillTokenInsertedLen(
            self.child.editor.edit_state.input.items,
            replace_end,
            name,
        );
        if (inserted_len > domain.max_message_bytes) {
            self.child.input_failure = .message_too_large;
            return false;
        }
        try self.child.editor.skillBindingState().bindSkillToken(
            alloc,
            0,
            replace_end,
            name,
            path,
            display_source,
        );
        self.child.edited(alloc);
        return true;
    }

    fn childComposerEditable(self: *const Runtime) bool {
        if (self.focus != .child_composer) return false;
        const chat = if (self.child.chat) |*value| value else return false;
        return self.childRouteId() != null and chat.messageable();
    }

    pub fn invalidateChildConversationProjection(
        self: *Runtime,
        alloc: Allocator,
    ) void {
        if (self.child.presentation == null) return;
        self.rememberSelectedChildViewport();
        self.child.clearPresentation(alloc);
    }

    pub fn openSelectedChildModelConfiguration(
        self: *Runtime,
        alloc: Allocator,
        model: []const u8,
    ) !Command {
        const result = try self.openConfigure(alloc);
        if (result != .redraw) return result;
        try self.form.replaceEditor(alloc, .model, model);
        self.form.field_index = 1;
        self.form.edit(alloc);
        return .redraw;
    }

    pub fn commitChildPresentationViewport(
        self: *Runtime,
        total_rows: u32,
        max_rows_from_bottom: u32,
        rows_from_bottom: u32,
    ) void {
        if (self.childRouteId() == null or self.child.chat == null) return;
        self.child.rendered_chat_rows = total_rows;
        self.child.max_scroll = max_rows_from_bottom;
        self.child.scroll_from_bottom = rows_from_bottom;
        self.child.viewport_mutation = .none;
        if (rows_from_bottom == 0) {
            if (self.routedNode()) |node| {
                self.child.presented_through_sequence = node.through_sequence;
            }
        }
    }

    pub fn managerPasteActive(self: *const Runtime) bool {
        if (self.form.paste_field) |field| {
            const editor = switch (field) {
                .name => &self.form.editors[0],
                .model => &self.form.editors[1],
                .initial_message => &self.form.editors[2],
                .milestones => &self.form.editors[3],
                .interval => &self.form.editors[4],
                .duration => &self.form.editors[5],
                else => null,
            };
            if (editor) |value| return value.paste.active();
        }
        return self.child.editor.paste.active();
    }

    pub fn beginManagerPaste(self: *Runtime) void {
        if (self.form.kind != .none) {
            if (self.form.currentField()) |field| {
                if (self.form.editorForField(field)) |editor| {
                    const available = formFieldMaxBytes(field) -| editor.edit_state.input.items.len;
                    editor.paste.begin(.composer, available);
                    self.form.paste_field = field;
                    self.form.paste_rejection = null;
                    return;
                }
            }
        }
        self.child.paste_rejection = null;
        const child_chat = if (self.childRouteId() != null) self.child.chat else null;
        const owner: paste_framing.Owner = if (child_chat != null and child_chat.?.messageable())
            .composer
        else
            .decision_prompt;
        const buffer_limit = if (owner == .composer)
            self.child.editor.replacementState(null).availableBytesForSelectionOrInsertion(domain.max_message_bytes)
        else
            std.math.maxInt(usize);
        self.child.editor.paste.begin(owner, buffer_limit);
    }

    pub fn consumeManagerPasteByte(
        self: *Runtime,
        alloc: Allocator,
        byte: u8,
    ) !bool {
        if (!self.managerPasteActive()) return false;
        if (self.form.paste_field != null) {
            return self.consumeFormPasteByte(alloc, byte);
        }
        self.child.editor.paste.consumeByte(alloc, byte) catch |err| {
            debug_trace.logf(
                "subagent",
                "child paste dropped bytes={d} reason=allocation_failure error={s}",
                .{ self.child.editor.paste.buffer.items.len, @errorName(err) },
            );
            self.clearManagerPasteCapture();
            self.child.paste_rejection = null;
            self.child.input_failure = .paste_allocation_failed;
            return true;
        };

        if (self.child.editor.paste.owner != .decision_prompt and
            self.child.editor.paste.confirmedOverflowBytes() > 0)
        {
            self.child.paste_rejection = .message_too_large;
            self.child.editor.paste.continueDiscarding();
        }
        return true;
    }

    pub fn settleManagerPasteDeliveryEpoch(
        self: *Runtime,
        alloc: Allocator,
    ) bool {
        if (!self.managerPasteActive()) return false;
        if (self.form.paste_field != null) {
            return self.settleFormPasteDeliveryEpoch(alloc);
        }

        switch (self.child.editor.paste.settleDeliveryEpoch()) {
            .none => return false,
            .reject => {
                self.rejectChildPaste(.unsafe_paste_boundary, "unsafe_paste_boundary");
                return true;
            },
            .finish => {},
        }

        if (self.child.editor.paste.owner == .decision_prompt) {
            self.finishDiscardedManagerPaste();
            return true;
        }

        const available = self.child.editor.replacementState(null).availableBytesForSelectionOrInsertion(domain.max_message_bytes);
        const normalized = text_utils.normalizeLineEndingsInPlace(self.child.editor.paste.buffer.items);
        self.child.editor.paste.buffer.items.len = normalized.len;
        const pasted = self.child.editor.paste.buffer.items;
        if (pasted.len > available) {
            self.rejectChildPaste(.message_too_large, "message_too_large");
            return true;
        }
        if (!validChildMessage(pasted)) {
            self.rejectChildPaste(.invalid_utf8, "invalid_utf8");
            return true;
        }
        if (pasted.len == 0) {
            self.clearManagerPasteCapture();
            return true;
        }
        switch (self.child.editor.replacementState(null).replaceSelectionOrInsertSliceBounded(
            alloc,
            pasted,
            domain.max_message_bytes,
            .preserve,
        ) catch |err| {
            debug_trace.logf(
                "subagent",
                "child paste dropped bytes={d} reason=allocation_failure error={s}",
                .{ pasted.len, @errorName(err) },
            );
            self.clearManagerPasteCapture();
            self.child.paste_rejection = null;
            self.child.input_failure = .paste_allocation_failed;
            return true;
        }) {
            .inserted => {},
            .inactive => unreachable,
            .limit_exceeded => {
                self.rejectChildPaste(.message_too_large, "message_too_large");
                return true;
            },
        }
        self.clearManagerPasteCapture();
        self.child.paste_rejection = null;
        self.child.edited(alloc);
        return true;
    }

    fn consumeFormPasteByte(
        self: *Runtime,
        alloc: Allocator,
        byte: u8,
    ) !bool {
        const field = self.form.paste_field orelse return false;
        const editor = self.form.editorForField(field) orelse {
            self.form.paste_field = null;
            return false;
        };
        editor.paste.consumeByte(alloc, byte) catch |err| {
            debug_trace.logf(
                "subagent",
                "manager form paste dropped bytes={d} reason=allocation_failure error={s}",
                .{ editor.paste.buffer.items.len, @errorName(err) },
            );
            self.clearFormPasteCapture();
            self.form.attempt.failure = .{ .validation = .allocation_failure };
            return true;
        };
        if (editor.paste.owner != .decision_prompt and
            editor.paste.confirmedOverflowBytes() > 0)
        {
            self.form.paste_rejection = .field_too_large;
            editor.paste.continueDiscarding();
        }
        return true;
    }

    fn settleFormPasteDeliveryEpoch(
        self: *Runtime,
        alloc: Allocator,
    ) bool {
        const field = self.form.paste_field orelse return false;
        const editor = self.form.editorForField(field) orelse {
            self.form.paste_field = null;
            return false;
        };
        switch (editor.paste.settleDeliveryEpoch()) {
            .none => return false,
            .reject => {
                debug_trace.logf(
                    "subagent",
                    "manager form paste dropped bytes={d} reason=unsafe_paste_boundary",
                    .{editor.paste.observedBytes()},
                );
                self.clearFormPasteCapture();
                self.form.attempt.failure = .{ .validation = .unsafe_paste_boundary };
                return true;
            },
            .finish => {},
        }

        const available = formFieldMaxBytes(field) -| editor.edit_state.input.items.len;
        if (editor.paste.owner == .decision_prompt) {
            debug_trace.logf(
                "subagent",
                "manager form paste dropped bytes={d} reason=field_too_large",
                .{editor.paste.attemptedBytes() +| editor.paste.decision_bytes},
            );
            self.clearFormPasteCapture();
            self.form.attempt.failure = .{ .validation = .field_too_large };
            return true;
        }
        const pasted = editor.paste.buffer.items;
        if (pasted.len > available) {
            debug_trace.logf(
                "subagent",
                "manager form paste dropped bytes={d} reason=field_too_large",
                .{pasted.len},
            );
            self.clearFormPasteCapture();
            self.form.attempt.failure = .{ .validation = .field_too_large };
            return true;
        }
        if (!std.unicode.utf8ValidateSlice(pasted) or std.mem.findScalar(u8, pasted, 0) != null) {
            debug_trace.logf(
                "subagent",
                "manager form paste dropped bytes={d} reason=invalid_utf8",
                .{pasted.len},
            );
            self.clearFormPasteCapture();
            self.form.attempt.failure = .{ .validation = .invalid_utf8 };
            return true;
        }
        if (pasted.len > 0) {
            editor.insertionState().insertSlice(alloc, pasted, .preserve) catch |err| {
                debug_trace.logf(
                    "subagent",
                    "manager form paste dropped bytes={d} reason=allocation_failure error={s}",
                    .{ pasted.len, @errorName(err) },
                );
                self.clearFormPasteCapture();
                self.form.attempt.failure = .{ .validation = .allocation_failure };
                return true;
            };
        }
        self.clearFormPasteCapture();
        self.form.edit(alloc);
        return true;
    }

    fn clearFormPasteCapture(self: *Runtime) void {
        const field = self.form.paste_field orelse return;
        if (self.form.editorForField(field)) |editor| {
            editor.paste.finishHandled();
        }
        self.form.paste_field = null;
        self.form.paste_rejection = null;
    }

    pub fn childPasteActive(self: Runtime) bool {
        return self.childRouteId() != null and self.managerPasteActive();
    }

    pub fn beginChildPaste(self: *Runtime) void {
        if (self.childRouteId() == null) return;
        self.beginManagerPaste();
    }

    pub fn consumeChildPasteByte(
        self: *Runtime,
        alloc: Allocator,
        byte: u8,
    ) !bool {
        if (!self.childPasteActive()) return false;
        return self.consumeManagerPasteByte(alloc, byte);
    }

    fn finishDiscardedManagerPaste(self: *Runtime) void {
        if (self.child.paste_rejection) |failure| {
            debug_trace.logf(
                "subagent",
                "child paste dropped bytes={d} reason={s}",
                .{
                    self.child.editor.paste.attemptedBytes() +| self.child.editor.paste.decision_bytes,
                    childInputFailureTraceLabel(failure),
                },
            );
            self.child.input_failure = failure;
        } else {
            debug_trace.logf(
                "subagent",
                "manager paste dropped bytes={d} reason=route_without_composer",
                .{self.child.editor.paste.decision_bytes},
            );
        }
        self.clearManagerPasteCapture();
        self.child.paste_rejection = null;
    }

    fn rejectChildPaste(
        self: *Runtime,
        failure: ChildInputFailure,
        reason: []const u8,
    ) void {
        debug_trace.logf(
            "subagent",
            "child paste dropped bytes={d} reason={s}",
            .{ self.child.editor.paste.observedBytes(), reason },
        );
        self.clearManagerPasteCapture();
        self.child.paste_rejection = null;
        self.child.input_failure = failure;
    }

    fn clearManagerPasteCapture(self: *Runtime) void {
        self.child.editor.paste.finishHandled();
    }

    pub fn installChildChat(
        self: *Runtime,
        alloc: Allocator,
        chat_value: projection.ChildChat,
        older_page: bool,
        reset_pages: bool,
    ) !void {
        var chat = chat_value;
        errdefer chat.deinit(alloc);
        self.child.clearPresentation(alloc);
        const page = chat.takePage();
        if (reset_pages or self.child.chat == null) {
            try self.child.pages.resetNewest(alloc, page);
        } else if (older_page) {
            try self.child.pages.addOlder(alloc, page);
        } else {
            try self.child.pages.replaceNewest(alloc, page);
        }
        if (self.child.chat) |*current| current.deinit(alloc);
        self.child.chat = chat;
        if (!self.child.chat.?.messageable()) self.focus = .child_detail;
        self.child.unavailable = null;
        if (self.child.rendered_chat_rows != null) {
            self.child.viewport_mutation = if (older_page) .prepend else .bottom;
        }
    }

    pub fn replaceChildLive(
        self: *Runtime,
        alloc: Allocator,
        live: ?execution.LivePresentation,
    ) bool {
        var next = live;
        if (self.child.chat) |*chat| {
            if (sameLivePresentationVersion(chat.live, next) or
                sameRichPresentationFrontier(chat.live, next))
            {
                if (next) |*unchanged| unchanged.deinit(alloc);
                return false;
            }
            const presentation_still_appendable =
                livePresentationExtends(
                    self.child.presentation_live_work_id,
                    self.child.presentation_live_event_count,
                    next,
                );
            if (!presentation_still_appendable) {
                self.child.clearPresentation(alloc);
            }
            if (chat.live) |*current| current.deinit(alloc);
            chat.live = next;
            next = null;
            if (self.child.rendered_chat_rows != null) {
                self.child.viewport_mutation = .bottom;
            }
            return true;
        }
        if (next) |*unused| unused.deinit(alloc);
        return false;
    }

    pub fn setChildUnavailable(
        self: *Runtime,
        alloc: Allocator,
        unavailable: projection.ChildUnavailable,
    ) void {
        if (self.child.chat) |*chat| chat.deinit(alloc);
        self.child.chat = null;
        self.child.pages.clear(alloc);
        self.child.unavailable = unavailable;
        self.child.rendered_chat_rows = null;
        self.child.viewport_mutation = .none;
        self.child.clearPresentation(alloc);
    }

    pub fn childConversationRuntime(
        self: *Runtime,
    ) ?*transcript_runtime.TranscriptRuntime {
        if (self.child.presentation) |*runtime| return runtime;
        return null;
    }

    pub fn childFullTranscriptRequested(self: Runtime) bool {
        return self.childRouteId() != null and
            self.child.presentation_transcript_depth.active();
    }

    pub fn childTranscriptPresentationDepth(
        self: Runtime,
    ) transcript_presentation.Depth {
        if (self.childRouteId() == null) return .inline_mode;
        return self.child.presentation_transcript_depth;
    }

    pub fn setChildTranscriptPresentationDepth(
        self: *Runtime,
        alloc: Allocator,
        requested: transcript_presentation.Depth,
    ) !transcript_presentation.Depth {
        _ = self.childRouteId() orelse return .inline_mode;
        if (self.child.presentation) |*runtime| {
            _ = try runtime.setTranscriptPresentationDepth(alloc, requested);
        }
        self.child.presentation_transcript_depth = requested;
        return requested;
    }

    pub fn closeChildTranscriptPresentation(
        self: *Runtime,
        alloc: Allocator,
    ) !bool {
        _ = self.childRouteId() orelse return false;
        if (!self.child.presentation_transcript_depth.active()) return false;
        if (self.child.presentation) |*runtime| {
            _ = try runtime.setTranscriptPresentationDepth(alloc, .inline_mode);
        }
        self.child.presentation_transcript_depth = .inline_mode;
        return true;
    }

    pub fn activeRenderRequests(self: *Runtime) *render_request.RenderRequestState {
        if (self.child.presentation) |*runtime| return &runtime.render_requests;
        return &self.render_requests;
    }

    pub fn activateManagerSurface(self: *Runtime) void {
        self.physical_surface = .manager;
    }

    pub fn activateChildConversationSurface(self: *Runtime) bool {
        if (self.physical_surface == .child_conversation) return false;
        self.physical_surface = .child_conversation;
        return true;
    }

    pub fn activateChildCatalogSurface(self: *Runtime) bool {
        if (self.physical_surface == .child_catalog) return false;
        self.physical_surface = .child_catalog;
        return true;
    }

    pub fn installChildConversationRuntime(
        self: *Runtime,
        alloc: Allocator,
        runtime_value: transcript_runtime.TranscriptRuntime,
        diff_entries_value: std.ArrayList(diff_mod.DiffEntry),
        live: ?execution.LivePresentation,
        next_diff_id: u32,
    ) !void {
        var runtime = runtime_value;
        errdefer runtime.deinit(alloc);
        runtime.bindDetachedCommitAllocator(alloc);
        var diff_entries = diff_entries_value;
        errdefer {
            for (diff_entries.items) |*entry| {
                entry.deinit(std.heap.c_allocator);
            }
            diff_entries.deinit(std.heap.c_allocator);
        }
        const live_work_id = if (live) |value|
            try alloc.dupe(u8, value.work_id)
        else
            null;
        errdefer if (live_work_id) |work_id| alloc.free(work_id);
        const full_transcript_bookmark = self.selectedChildFullTranscriptBookmark();
        if (full_transcript_bookmark) |bookmark| {
            runtime.restoreFullTranscriptViewport(bookmark);
            self.child.presentation_transcript_depth = bookmark.depth;
            self.selected_child_viewport.?.full_transcript = null;
        } else if (runtime.transcriptPresentationDepth() !=
            self.child.presentation_transcript_depth)
        {
            _ = try runtime.setTranscriptPresentationDepth(
                alloc,
                self.child.presentation_transcript_depth,
            );
        }

        self.child.clearPresentation(alloc);
        self.child.presentation = runtime;
        self.child.presentation_diffs = diff_entries;
        self.child.presentation_live_work_id = live_work_id;
        self.child.presentation_live_event_count = if (live) |value|
            value.events.len
        else
            0;
        self.child.presentation_next_diff_id = next_diff_id;
    }

    pub fn markChildConversationEventsAppliedThrough(
        self: *Runtime,
        live: execution.LivePresentation,
        event_count: usize,
        next_diff_id: u32,
    ) void {
        std.debug.assert(self.child.presentation != null);
        std.debug.assert(self.child.presentation_live_work_id != null);
        std.debug.assert(event_count <= live.events.len);
        std.debug.assert(event_count >= self.child.presentation_live_event_count);
        std.debug.assert(std.mem.eql(
            u8,
            self.child.presentation_live_work_id.?,
            live.work_id,
        ));
        self.child.presentation_live_event_count = event_count;
        self.child.presentation_next_diff_id = next_diff_id;
    }

    pub fn childConversationEventCount(self: Runtime) usize {
        return self.child.presentation_live_event_count;
    }

    pub fn childConversationNextDiffId(self: Runtime) u32 {
        return self.child.presentation_next_diff_id;
    }

    pub fn childConversationDiffEntries(
        self: *Runtime,
    ) *std.ArrayList(diff_mod.DiffEntry) {
        return &self.child.presentation_diffs;
    }

    pub fn childFullTranscriptDiffResolver(
        self: *Runtime,
    ) ?full_transcript_screen.FullDiffResolver {
        if (self.child.presentation == null) return null;
        return .{
            .context = self,
            .full_for_marker = childFullDiffForMarker,
            .has_full_for_lifecycle = childHasFullDiffForLifecycle,
        };
    }

    fn childFullDiffForMarker(
        raw: *anyopaque,
        id: u32,
    ) ?[]const u8 {
        const self: *Runtime = @ptrCast(@alignCast(raw));
        for (self.child.presentation_diffs.items) |entry| {
            if (entry.id != id) continue;
            const full = entry.full orelse return null;
            return full.content;
        }
        return null;
    }

    fn childHasFullDiffForLifecycle(
        raw: *anyopaque,
        lifecycle_id: types.ToolLifecycleId,
    ) bool {
        const self: *Runtime = @ptrCast(@alignCast(raw));
        for (self.child.presentation_diffs.items) |entry| {
            const full = entry.full orelse continue;
            if (full.lifecycle_id.turn_id != lifecycle_id.turn_id) continue;
            if (std.mem.eql(
                u8,
                full.lifecycle_id.call_id,
                lifecycle_id.call_id,
            )) return true;
        }
        return false;
    }

    pub fn olderHistoryCursor(self: Runtime) ?[]const u8 {
        return self.child.pages.olderCursor();
    }

    pub fn needsNewestHistory(self: Runtime) bool {
        return !self.child.pages.has_newest;
    }

    pub const Submission = struct {
        child_id: []const u8,
        content: []const u8,
        invocation_id: []const u8,
        identity_epoch: u64,
    };

    pub fn prepareSubmission(
        self: *Runtime,
        alloc: Allocator,
        timestamp_ms: i64,
    ) !?Submission {
        const child_id = self.childRouteId() orelse return null;
        const chat = self.child.chat orelse return null;
        if (!chat.messageable() or self.child.editor.edit_state.input.items.len == 0) return null;
        if (childDraftFailure(self.child.editor.edit_state.input.items)) |failure| {
            self.child.input_failure = failure;
            debug_trace.logf(
                "subagent",
                "child submission rejected bytes={d} reason={s}",
                .{ self.child.editor.edit_state.input.items.len, childInputFailureTraceLabel(failure) },
            );
            return null;
        }
        if (self.child.invocation_id == null) {
            self.child.operation_counter +%= 1;
            self.child.invocation_id = try std.fmt.allocPrint(
                alloc,
                "child-chat:{s}:{d}:{d}",
                .{ child_id, timestamp_ms, self.child.operation_counter },
            );
        }
        return .{
            .child_id = child_id,
            .content = self.child.editor.edit_state.input.items,
            .invocation_id = self.child.invocation_id.?,
            .identity_epoch = self.child.identity_epoch,
        };
    }

    pub fn assignSubmissionIdentity(
        self: *Runtime,
        invocation_id: []const u8,
        identity_epoch: u64,
    ) bool {
        const current = self.child.invocation_id orelse return false;
        if (!std.mem.eql(u8, current, invocation_id)) return false;
        if (self.child.identity_epoch != 0) {
            return self.child.identity_epoch == identity_epoch;
        }
        self.child.identity_epoch = identity_epoch;
        return true;
    }

    pub fn submissionAccepted(self: *Runtime, alloc: Allocator) void {
        self.child.editor.inputResetState().clearCurrent(alloc);
        if (self.child.invocation_id) |invocation_id| alloc.free(invocation_id);
        self.child.invocation_id = null;
        self.child.identity_epoch = 0;
        self.child.submission_failure = null;
        self.child.input_failure = null;
        self.child.scroll_from_bottom = 0;
    }

    pub fn submissionRejected(
        self: *Runtime,
        alloc: Allocator,
        failure: manager_mod.Failure,
    ) void {
        self.child.input_failure = null;
        self.child.submission_failure = .{
            .code = failure.code,
            .retryable = failure.retryable,
        };
        if (!failure.retryable) {
            if (self.child.invocation_id) |invocation_id| {
                alloc.free(invocation_id);
            }
            self.child.invocation_id = null;
            self.child.identity_epoch = 0;
        }
    }

    pub const PreparedMutation = struct {
        command: domain.Command,
        invocation_id: []const u8,
        expected_generation: ?u64,
        identity_epoch: u64,

        pub fn deinit(self: *PreparedMutation, alloc: Allocator) void {
            self.command.deinit(alloc);
            self.* = undefined;
        }
    };

    pub const ApprovalSubmission = struct {
        child_id: []const u8,
        request_id: []const u8,
        decision: types.ToolPermissionDecision,
    };

    pub fn installAttachPage(
        self: *Runtime,
        alloc: Allocator,
        page_value: projection.AttachPage,
        append: bool,
    ) !void {
        var page = page_value;
        errdefer page.deinit(alloc);
        const has_more = page.has_more;
        const continuation = page.continuation;
        page.continuation = null;
        errdefer if (continuation) |value| {
            var owned = value;
            owned.deinit(alloc);
        };
        if (!append) {
            const prior_selected = self.attach.selectedCandidate();
            var next_candidates: std.ArrayList(projection.AttachCandidate) = .empty;
            errdefer next_candidates.deinit(alloc);
            try next_candidates.ensureUnusedCapacity(alloc, page.candidates.len);
            for (page.candidates) |candidate| next_candidates.appendAssumeCapacity(candidate);
            var next_selected: usize = 0;
            var preserved_selection = prior_selected == null;
            if (prior_selected) |prior| {
                for (next_candidates.items, 0..) |candidate, index| {
                    if (std.mem.eql(u8, prior.session_id, candidate.session_id)) {
                        next_selected = index;
                        preserved_selection = true;
                        break;
                    }
                }
            }
            for (self.attach.candidates.items) |*candidate| candidate.deinit(alloc);
            self.attach.candidates.deinit(alloc);
            self.attach.candidates = next_candidates;
            next_candidates = .empty;
            self.attach.selected = next_selected;
            self.attach.selection_stale = !preserved_selection;
            if (!preserved_selection) {
                self.attach.attempt.failure = .{ .manager = .{ .code = .child_unavailable } };
            }
        } else {
            try self.attach.candidates.ensureUnusedCapacity(alloc, page.candidates.len);
            for (page.candidates) |candidate| {
                self.attach.candidates.appendAssumeCapacity(candidate);
            }
        }
        alloc.free(page.candidates);
        page = undefined;
        if (self.attach.continuation) |*prior| prior.deinit(alloc);
        self.attach.continuation = continuation;
        self.attach.has_more = has_more;
        self.attach.loading = false;
        if (self.attach.candidates.items.len == 0) self.attach.selected = 0 else {
            self.attach.selected = @min(self.attach.selected, self.attach.candidates.items.len - 1);
        }
    }

    pub fn setAttachLoadFailure(self: *Runtime) void {
        self.attach.loading = false;
        self.attach.attempt.failure = .{ .manager = .{
            .code = .store_failure,
            .retryable = true,
        } };
    }

    pub fn attachContinuation(self: Runtime) ?@import("../../core/session/session_store.zig").ResumableSessionContinuation {
        if (!self.attach.has_more) return null;
        const continuation = self.attach.continuation orelse return null;
        return continuation.view();
    }

    pub fn prepareManagerMutation(
        self: *Runtime,
        alloc: Allocator,
        timestamp_ms: i64,
    ) !?PreparedMutation {
        if (self.form.kind != .none) {
            return self.prepareFormMutation(alloc, timestamp_ms);
        }
        if (self.attachRouteActive()) {
            return self.prepareRelationshipMutation(alloc, timestamp_ms);
        }
        const action = self.lifecycle_action orelse return null;
        return self.prepareLifecycleMutation(alloc, action, timestamp_ms);
    }

    fn prepareFormMutation(
        self: *Runtime,
        alloc: Allocator,
        timestamp_ms: i64,
    ) !?PreparedMutation {
        if (self.form.kind == .configure and self.form.expected_generation == null) {
            return null;
        }
        const name = std.mem.trim(u8, self.form.editors[0].edit_state.input.items, " \t\r\n");
        const model = std.mem.trim(u8, self.form.editors[1].edit_state.input.items, " \t\r\n");
        const initial_message = self.form.editors[2].edit_state.input.items;
        var milestones_buf: [domain.max_milestones][]const u8 = undefined;
        const milestones = parseMilestones(
            self.form.editors[3].edit_state.input.items,
            &milestones_buf,
        ) catch |err| {
            self.form.attempt.failure = .{ .validation = mapFormValidationError(err) };
            return null;
        };
        const interval = parseOptionalU64(self.form.editors[4].edit_state.input.items) catch {
            self.form.attempt.failure = .{ .validation = .invalid_number };
            return null;
        };
        const duration = parseOptionalU64(self.form.editors[5].edit_state.input.items) catch {
            self.form.attempt.failure = .{ .validation = .invalid_number };
            return null;
        };
        const effort_raw = std.mem.trim(u8, self.form.editors[6].edit_state.input.items, " \t\r\n");
        const effort = types.ReasoningEffort.parseDisplayLabel(effort_raw) orelse {
            self.form.attempt.failure = .{ .validation = .invalid_effort };
            return null;
        };
        const notifications: domain.NotificationPolicyInput = .{
            .terminal = self.form.terminal,
            .milestones = milestones,
            .report_interval_ms = interval,
            .report_duration_ms = duration,
            .stop_conditions = &.{.terminal},
        };

        const input: domain.CommandInput = switch (self.form.kind) {
            .create => .{ .create = .{
                .name = if (name.len == 0) null else name,
                .mode = .persistent,
                .prompt = if (initial_message.len == 0) null else initial_message,
                .model = if (model.len == 0) null else model,
                .effort = effort,
                .permission_mode = self.form.permission_mode,
                .notifications = if (self.form.notifications_enabled) notifications else null,
            } },
            .configure => .{ .configure = .{
                .id = self.form.target_id.?,
                .name = if (name.len == 0) null else name,
                .model = if (model.len == 0) null else model,
                .effort = effort,
                .permission_mode = self.form.permission_mode,
                .notifications = notifications,
            } },
            .none => return null,
        };
        var command = domain.validateCommand(alloc, input) catch |err| {
            self.form.attempt.failure = .{ .validation = mapFormValidationError(err) };
            return null;
        };
        errdefer command.deinit(alloc);
        const kind: MutationKind = if (self.form.kind == .create) .create else .configure;
        const target_id = self.form.target_id orelse "new-child";
        const operation_id = self.form.attempt.ensureOperationId(
            alloc,
            kind,
            target_id,
            timestamp_ms,
        ) catch {
            command.deinit(alloc);
            self.form.attempt.failure = .{ .validation = .allocation_failure };
            return null;
        };
        return .{
            .command = command,
            .invocation_id = operation_id,
            .expected_generation = self.form.expected_generation,
            .identity_epoch = self.form.attempt.identity_epoch,
        };
    }

    fn prepareRelationshipMutation(
        self: *Runtime,
        alloc: Allocator,
        timestamp_ms: i64,
    ) !?PreparedMutation {
        const candidate = self.attach.selectedCandidate() orelse {
            self.attach.attempt.failure = .{ .validation = .no_attach_candidate };
            return null;
        };
        if (self.attach.selection_stale) {
            self.attach.attempt.failure = .{ .validation = .attach_candidate_ineligible };
            return null;
        }
        if (!candidate.eligible) {
            self.attach.attempt.failure = .{ .validation = .attach_candidate_ineligible };
            return null;
        }
        const root_id = if (self.snapshot) |snapshot| snapshot.root_id else return null;
        const action = candidate.relationshipAction(root_id);
        var command = domain.validateCommand(alloc, .{ .relationship = .{
            .action = action,
            .id = candidate.session_id,
            .parent_id = if (action == .reparent) root_id else null,
        } }) catch |err| {
            self.attach.attempt.failure = .{ .validation = mapFormValidationError(err) };
            return null;
        };
        errdefer command.deinit(alloc);
        const operation_id = self.attach.attempt.ensureOperationId(
            alloc,
            .relationship,
            candidate.session_id,
            timestamp_ms,
        ) catch {
            command.deinit(alloc);
            self.attach.attempt.failure = .{ .validation = .allocation_failure };
            return null;
        };
        return .{
            .command = command,
            .invocation_id = operation_id,
            .expected_generation = candidate.generation,
            .identity_epoch = self.attach.attempt.identity_epoch,
        };
    }

    fn prepareLifecycleMutation(
        self: *Runtime,
        alloc: Allocator,
        action: domain.LifecycleAction,
        timestamp_ms: i64,
    ) !?PreparedMutation {
        const node = if (action == .reopen) self.archivedSelectedNode() else self.routedNode();
        const selected = node orelse return null;
        var command = try domain.validateCommand(alloc, .{ .lifecycle = .{
            .id = selected.child_id,
            .action = action,
        } });
        errdefer command.deinit(alloc);
        const kind: MutationKind = switch (action) {
            .cancel => .cancel,
            .close => .close,
            .reopen => .reopen,
            .@"resume" => .@"resume",
        };
        const operation_id = self.lifecycle_attempt.ensureOperationId(
            alloc,
            kind,
            selected.child_id,
            timestamp_ms,
        ) catch {
            command.deinit(alloc);
            self.lifecycle_attempt.failure = .{ .validation = .allocation_failure };
            return null;
        };
        return .{
            .command = command,
            .invocation_id = operation_id,
            .expected_generation = selected.generation,
            .identity_epoch = self.lifecycle_attempt.identity_epoch,
        };
    }

    pub fn assignMutationIdentity(
        self: *Runtime,
        invocation_id: []const u8,
        identity_epoch: u64,
    ) bool {
        const attempt = self.currentMutationAttempt() orelse return false;
        const current = attempt.operation_id orelse return false;
        if (!std.mem.eql(u8, current, invocation_id)) return false;
        if (attempt.identity_epoch != 0) {
            return attempt.identity_epoch == identity_epoch;
        }
        attempt.identity_epoch = identity_epoch;
        return true;
    }

    pub fn mutationRejected(self: *Runtime, alloc: Allocator, failure: manager_mod.Failure) void {
        const attempt = self.currentMutationAttempt() orelse return;
        attempt.failure = .{ .manager = failure };
        if (self.form.kind == .configure and
            failure.code == .stale_generation and
            failure.retryable)
        {
            self.form.expected_generation = null;
        }
        if (!failure.retryable) {
            if (attempt.operation_id) |value| alloc.free(value);
            attempt.operation_id = null;
            attempt.identity_epoch = 0;
        }
    }

    pub fn mutationAccepted(
        self: *Runtime,
        alloc: Allocator,
        receipt: domain.OperationReceipt,
    ) !Command {
        if (self.form.kind == .create) {
            return self.openAcceptedChild(alloc, receipt.target_id);
        }
        if (self.form.kind == .configure) {
            self.form.clear(alloc);
            self.popCurrentRoute(alloc);
            return .child_changed;
        }
        if (self.attachRouteActive()) {
            self.attach.clear(alloc);
            self.popCurrentRoute(alloc);
            try self.setSelectedBorrowed(alloc, receipt.target_id, false);
            return .redraw;
        }
        const action = self.lifecycle_action orelse return .redraw;
        self.lifecycle_attempt.deinit(alloc);
        self.lifecycle_action = null;
        return switch (action) {
            .cancel => blk: {
                if (self.currentRoute()) |route| switch (route.*) {
                    .actions => self.popCurrentRoute(alloc),
                    else => {},
                };
                break :blk .child_changed;
            },
            .close => blk: {
                self.rememberSelectedChildViewport();
                self.clearChildSelectionState(alloc, "child_closed");
                self.clearRoutes(alloc);
                self.focus = .child_list;
                break :blk .redraw;
            },
            .reopen => self.openAcceptedChild(alloc, receipt.target_id),
            .@"resume" => blk: {
                self.popCurrentRoute(alloc);
                break :blk .child_changed;
            },
        };
    }

    pub fn prepareApprovalResolution(self: *Runtime) ?ApprovalSubmission {
        const decision = self.approval_decision orelse return null;
        const route = self.currentRoute() orelse return null;
        return switch (route.*) {
            .approval => |value| .{
                .child_id = value.child_id,
                .request_id = value.approval_id,
                .decision = decision,
            },
            else => null,
        };
    }

    pub fn approvalAccepted(self: *Runtime, alloc: Allocator) void {
        self.approval_decision = null;
        self.approval_failure = null;
        self.popCurrentRoute(alloc);
    }

    pub fn approvalRejected(
        self: *Runtime,
        alloc: Allocator,
        stale: bool,
    ) !void {
        self.approval_decision = null;
        self.approval_failure = if (stale) .approval_stale else .approval_commit_failed;
        if (!stale) return;
        const route = try approvalRouteForCard(alloc, self.main_approval_card);
        if (route != null) self.replaceCurrentApprovalRoute(alloc, route);
    }

    fn currentMutationAttempt(self: *Runtime) ?*MutationAttempt {
        if (self.form.kind != .none) return &self.form.attempt;
        if (self.attachRouteActive()) return &self.attach.attempt;
        if (self.lifecycle_action != null) return &self.lifecycle_attempt;
        return null;
    }

    fn openAcceptedChild(self: *Runtime, alloc: Allocator, child_id: []const u8) !Command {
        const selected = try alloc.dupe(u8, child_id);
        errdefer alloc.free(selected);
        const route_id = try alloc.dupe(u8, child_id);
        errdefer alloc.free(route_id);
        try self.routes.ensureUnusedCapacity(alloc, 1);
        self.form.clear(alloc);
        self.attach.clear(alloc);
        try self.switchChildDraft(alloc, child_id);
        self.clearRoutes(alloc);
        if (self.selected_id) |value| alloc.free(value);
        self.selected_id = selected;
        self.routes.appendAssumeCapacity(.{ .child = route_id });
        self.focus = .child_composer;
        return .child_changed;
    }

    fn popCurrentRoute(self: *Runtime, alloc: Allocator) void {
        var route = self.routes.pop() orelse return;
        route.deinit(alloc);
        self.syncFocus();
    }

    fn attachRouteActive(self: Runtime) bool {
        const route = self.currentRoute() orelse return false;
        return route.* == .attach;
    }

    pub fn isAttachRouteActive(self: Runtime) bool {
        return self.attachRouteActive();
    }

    fn clearPageHistory(self: *Runtime, alloc: Allocator) void {
        for (self.page_history.items) |maybe_cursor| {
            if (maybe_cursor) |cursor| alloc.free(cursor);
        }
        self.page_history.clearRetainingCapacity();
    }

    pub fn count(self: Runtime) usize {
        const snapshot = self.snapshot orelse return self.count_projection;
        return countNodes(snapshot.nodes, false);
    }

    pub fn snapshotEntries(self: Runtime, alloc: Allocator) ![]EntryView {
        const snapshot = self.snapshot orelse return alloc.alloc(EntryView, 0);
        const entries = try alloc.alloc(EntryView, snapshot.nodes.len);
        for (snapshot.nodes, 0..) |node, index| {
            entries[index] = .{
                .id = node.child_id,
                .label = node.name,
                .status = node.state,
                .unread_count = node.unread_count,
                .external_busy = node.external_busy,
            };
        }
        return entries;
    }

    pub fn selectedInfo(self: Runtime) ?SelectedInfo {
        const node = self.selectedNode() orelse return null;
        return .{
            .id = node.child_id,
            .label = node.name,
            .status = node.state,
            .unread_count = node.unread_count,
            .external_busy = node.external_busy,
        };
    }

    pub fn selectedNode(self: Runtime) ?*const projection.Node {
        const snapshot = self.snapshot orelse return null;
        const selected = self.selected_id orelse return null;
        return findNodeIn(snapshot.nodes, selected);
    }

    fn archivedSelectedNode(self: Runtime) ?*const projection.Node {
        const snapshot = self.snapshot orelse return null;
        const selected = self.archived_selected_id orelse return null;
        return findNodeIn(snapshot.nodes, selected);
    }

    pub fn routedNode(self: Runtime) ?*const projection.Node {
        const route = self.currentRoute() orelse return self.selectedNode();
        const id = switch (route.*) {
            .archived => return self.archivedSelectedNode(),
            .create, .attach => return null,
            .child, .configure, .actions, .confirm_close, .activity => |value| value,
            .notification => |value| value.child_id,
            .approval => |value| value.child_id,
            .main_approval => return null,
        };
        const snapshot = self.snapshot orelse return null;
        return findNodeIn(snapshot.nodes, id);
    }

    pub fn currentRoute(self: *const Runtime) ?*const Route {
        if (self.routes.items.len == 0) return null;
        return &self.routes.items[self.routes.items.len - 1];
    }

    pub fn handle(self: *Runtime, alloc: Allocator, action: Action) !Command {
        return self.handleWithMainApproval(alloc, action, null);
    }

    pub fn handleWithMainApproval(
        self: *Runtime,
        alloc: Allocator,
        action: Action,
        main_approval_id: ?u64,
    ) !Command {
        if (self.form.kind != .none) switch (action) {
            .ctrl_c, .toggle, .escape => {},
            else => return self.handleFormAction(alloc, action),
        };
        if (self.attachRouteActive()) switch (action) {
            .ctrl_c, .toggle, .escape => {},
            else => return self.handleAttachAction(alloc, action),
        };
        if (self.childRouteId() != null) switch (action) {
            .ctrl_c, .toggle, .escape => {},
            else => return self.handleChildAction(alloc, action),
        };
        if (self.currentRoute()) |route| switch (route.*) {
            .approval => |value| {
                const command = if (approvalForRoute(
                    self,
                    value.child_id,
                    value.approval_id,
                )) |approval|
                    approval.command
                else
                    null;
                if (command != null) switch (action) {
                    .up => {
                        self.detail_scroll -|= 1;
                        return .redraw;
                    },
                    .down => {
                        self.detail_scroll +|= 1;
                        return .redraw;
                    },
                    .page_up => {
                        self.detail_scroll -|= 8;
                        return .redraw;
                    },
                    .page_down => {
                        self.detail_scroll +|= 8;
                        return .redraw;
                    },
                    .left => return self.movePendingApprovalSelection(alloc, -1),
                    .right => return self.movePendingApprovalSelection(alloc, 1),
                    .previous_page => return self.previousPendingApprovalPage(),
                    .next_page => return self.nextPendingApprovalPage(),
                    else => {},
                } else switch (action) {
                    .up, .left => return self.movePendingApprovalSelection(alloc, -1),
                    .down, .right => return self.movePendingApprovalSelection(alloc, 1),
                    .page_up, .previous_page => return self.previousPendingApprovalPage(),
                    .page_down, .next_page => return self.nextPendingApprovalPage(),
                    else => {},
                }
            },
            else => {},
        };
        return switch (action) {
            .ctrl_c => self.handleCtrlC(),
            .toggle => .close_manager,
            .escape => if (self.routes.items.len == 0) .none else blk: {
                self.rememberSelectedChildViewport();
                var route = self.routes.pop().?;
                defer route.deinit(alloc);
                var result: Command = .redraw;
                switch (route) {
                    .child => |child_id| {
                        const node = if (self.snapshot) |snapshot|
                            findNodeIn(snapshot.nodes, child_id)
                        else
                            null;
                        const acknowledge_visible = if (node) |value|
                            value.unread_count > 0 and self.child.presented_through_sequence > 0
                        else
                            false;
                        if (acknowledge_visible) {
                            try self.setPendingChildAcknowledgement(
                                alloc,
                                child_id,
                                self.child.presented_through_sequence,
                            );
                        }
                        self.child.clearViewPreservingDraft(alloc);
                        result = if (acknowledge_visible) .acknowledge else .child_changed;
                    },
                    .create => self.form.clear(alloc),
                    .configure => {
                        self.form.clear(alloc);
                        result = .child_changed;
                    },
                    .attach => self.attach.clear(alloc),
                    .actions, .confirm_close => {
                        self.lifecycle_attempt.deinit(alloc);
                        self.lifecycle_action = null;
                    },
                    else => {},
                }
                self.detail_scroll = 0;
                self.syncFocus();
                break :blk result;
            },
            .up, .left => try self.moveSelection(alloc, -1),
            .down, .right => try self.moveSelection(alloc, 1),
            .page_up => try self.movePage(alloc, false),
            .page_down => try self.movePage(alloc, true),
            .enter => try self.openSelected(alloc),
            .activity => try self.openActivity(alloc),
            .notifications => try self.openNotification(alloc, main_approval_id),
            .archived => try self.openArchived(alloc),
            .next_page => try self.nextPage(alloc),
            .previous_page => self.previousPage(alloc),
            .home,
            .end,
            .word_left,
            .word_right,
            .focus_next,
            .delete_backward,
            .delete_next,
            .delete_word_left,
            .delete_word_right,
            .delete_to_line_start,
            .delete_to_line_end,
            .clear_line,
            .insert_newline,
            => .none,
        };
    }

    fn handleChildAction(self: *Runtime, alloc: Allocator, action: Action) !Command {
        if (action == .focus_next) {
            const messageable = if (self.child.chat) |chat|
                chat.messageable()
            else
                false;
            self.focus = if (self.focus == .child_composer)
                .child_detail
            else if (messageable)
                .child_composer
            else
                .child_detail;
            return .redraw;
        }
        const messageable = if (self.child.chat) |chat|
            chat.messageable()
        else
            false;
        switch (action) {
            .up => {
                self.child.scroll_from_bottom +|= 1;
                return .redraw;
            },
            .down => {
                self.child.scroll_from_bottom -|= 1;
                return .redraw;
            },
            .page_up => {
                if (self.child.scroll_from_bottom >= self.child.max_scroll and
                    self.olderHistoryCursor() != null)
                {
                    return .load_older_history;
                }
                self.child.scroll_from_bottom +|= 8;
                return .redraw;
            },
            .page_down => {
                if (self.child.scroll_from_bottom == 0 and
                    self.needsNewestHistory())
                {
                    return .refresh_newest_history;
                }
                self.child.scroll_from_bottom -|= 8;
                return .redraw;
            },
            .activity => return self.openActivity(alloc),
            .notifications => return self.openNotification(alloc, null),
            else => {},
        }
        if (!messageable) return .none;
        if (self.focus == .child_detail) {
            return switch (action) {
                .enter => blk: {
                    self.focus = .child_composer;
                    break :blk .redraw;
                },
                else => .none,
            };
        }
        var edited = false;
        switch (action) {
            .left => _ = horizontal_navigation.move(
                .character_left,
                &self.child.editor.edit_state,
                &self.child.editor.entities,
                &self.child.editor.vertical_navigation,
            ),
            .right => _ = horizontal_navigation.move(
                .character_right,
                &self.child.editor.edit_state,
                &self.child.editor.entities,
                &self.child.editor.vertical_navigation,
            ),
            .home => _ = horizontal_navigation.move(
                .line_start,
                &self.child.editor.edit_state,
                &self.child.editor.entities,
                &self.child.editor.vertical_navigation,
            ),
            .end => _ = horizontal_navigation.move(
                .line_end,
                &self.child.editor.edit_state,
                &self.child.editor.entities,
                &self.child.editor.vertical_navigation,
            ),
            .word_left => _ = horizontal_navigation.move(
                .word_left,
                &self.child.editor.edit_state,
                &self.child.editor.entities,
                &self.child.editor.vertical_navigation,
            ),
            .word_right => _ = horizontal_navigation.move(
                .word_right,
                &self.child.editor.edit_state,
                &self.child.editor.entities,
                &self.child.editor.vertical_navigation,
            ),
            .delete_backward => edited = self.child.editor.deletionState(null).delete(
                alloc,
                .character_left,
                .clear,
            ),
            .delete_next => edited = self.child.editor.deletionState(null).delete(
                alloc,
                .character_right,
                .clear,
            ),
            .delete_word_left => edited = self.child.editor.deletionState(null).delete(
                alloc,
                .word_left,
                .clear,
            ),
            .delete_word_right => edited = self.child.editor.deletionState(null).delete(
                alloc,
                .word_right,
                .clear,
            ),
            .delete_to_line_start => edited = try self.child.editor.killRingState(null).delete(alloc, .line_start),
            .delete_to_line_end => edited = try self.child.editor.killRingState(null).delete(alloc, .line_end),
            .clear_line => {
                edited = self.child.editor.edit_state.input.items.len > 0;
                self.child.editor.inputResetState().clearCurrent(alloc);
            },
            .insert_newline => if (self.child.editor.edit_state.input.items.len < domain.max_message_bytes) {
                try self.child.editor.insertionState().insertByte(alloc, '\n', .clear);
                edited = true;
            },
            .enter => return if (self.child.editor.edit_state.input.items.len == 0)
                .none
            else
                .submit_child_message,
            .activity,
            .notifications,
            .archived,
            .next_page,
            .previous_page,
            .ctrl_c,
            .toggle,
            .escape,
            => return .none,
            .focus_next => unreachable,
            .up,
            .down,
            .page_up,
            .page_down,
            => unreachable,
        }
        if (edited) self.child.edited(alloc);
        return .redraw;
    }

    fn handleFormAction(self: *Runtime, alloc: Allocator, action: Action) !Command {
        var edited = false;
        const field = self.form.currentField() orelse return .none;
        const editor = self.form.editorForField(field);
        switch (action) {
            .up => self.moveFormField(-1),
            .down => self.moveFormField(1),
            .left => if (editor) |value| {
                _ = horizontal_navigation.move(
                    .character_left,
                    &value.edit_state,
                    &value.entities,
                    &value.vertical_navigation,
                );
            } else self.cycleFormToggle(alloc, -1),
            .right => if (editor) |value| {
                _ = horizontal_navigation.move(
                    .character_right,
                    &value.edit_state,
                    &value.entities,
                    &value.vertical_navigation,
                );
            } else self.cycleFormToggle(alloc, 1),
            .home => if (editor) |value| {
                _ = horizontal_navigation.move(
                    .line_start,
                    &value.edit_state,
                    &value.entities,
                    &value.vertical_navigation,
                );
            },
            .end => if (editor) |value| {
                _ = horizontal_navigation.move(
                    .line_end,
                    &value.edit_state,
                    &value.entities,
                    &value.vertical_navigation,
                );
            },
            .word_left => if (editor) |value| {
                _ = horizontal_navigation.move(
                    .word_left,
                    &value.edit_state,
                    &value.entities,
                    &value.vertical_navigation,
                );
            },
            .word_right => if (editor) |value| {
                _ = horizontal_navigation.move(
                    .word_right,
                    &value.edit_state,
                    &value.entities,
                    &value.vertical_navigation,
                );
            },
            .delete_backward => if (editor) |value| {
                edited = value.deletionState(null).delete(
                    alloc,
                    .character_left,
                    .clear,
                );
            },
            .delete_next => if (editor) |value| {
                edited = value.deletionState(null).delete(
                    alloc,
                    .character_right,
                    .clear,
                );
            },
            .delete_word_left => if (editor) |value| {
                edited = value.deletionState(null).delete(
                    alloc,
                    .word_left,
                    .clear,
                );
            },
            .delete_word_right => if (editor) |value| {
                edited = value.deletionState(null).delete(
                    alloc,
                    .word_right,
                    .clear,
                );
            },
            .delete_to_line_start => if (editor) |value| {
                edited = try value.killRingState(null).delete(alloc, .line_start);
            },
            .delete_to_line_end => if (editor) |value| {
                edited = try value.killRingState(null).delete(alloc, .line_end);
            },
            .clear_line => if (editor) |value| {
                edited = value.edit_state.input.items.len > 0;
                value.inputResetState().clearCurrent(alloc);
            },
            .insert_newline => if (field == .initial_message) {
                const value = editor.?;
                if (value.edit_state.input.items.len < domain.max_prompt_bytes) {
                    try value.insertionState().insertByte(alloc, '\n', .clear);
                    edited = true;
                }
            },
            .focus_next => self.moveFormField(1),
            .enter => return .submit_manager_mutation,
            else => return .none,
        }
        if (edited) self.form.edit(alloc);
        return .redraw;
    }

    fn handleAttachAction(self: *Runtime, alloc: Allocator, action: Action) !Command {
        switch (action) {
            .up, .left => {
                if (self.attach.candidates.items.len > 0) {
                    self.attach.selected = if (self.attach.selected == 0)
                        self.attach.candidates.items.len - 1
                    else
                        self.attach.selected - 1;
                    self.attach.attempt.edited(alloc);
                    self.attach.selection_stale = false;
                }
                return .redraw;
            },
            .down, .right => {
                if (self.attach.candidates.items.len > 0) {
                    self.attach.selected = (self.attach.selected + 1) % self.attach.candidates.items.len;
                    self.attach.attempt.edited(alloc);
                    self.attach.selection_stale = false;
                }
                return .redraw;
            },
            .enter => return .submit_manager_mutation,
            .page_down, .next_page => if (self.attach.has_more and !self.attach.loading) {
                self.attach.loading = true;
                return .load_more_attach_candidates;
            },
            else => {},
        }
        return .none;
    }

    pub fn handleByte(
        self: *Runtime,
        alloc: Allocator,
        byte: u8,
        main_approval_id: ?u64,
    ) !Command {
        switch (byte) {
            3 => return self.handleCtrlC(),
            24 => return .close_manager,
            0x1b => return self.handleWithMainApproval(alloc, .escape, main_approval_id),
            else => {},
        }

        if (self.form.kind != .none) return self.handleFormByte(alloc, byte);
        if (self.attachRouteActive()) {
            return self.handleAttachAction(alloc, switch (byte) {
                '\r' => .enter,
                ']' => .next_page,
                else => switch (std.ascii.toLower(byte)) {
                    'j' => .down,
                    'k' => .up,
                    else => return .none,
                },
            });
        }
        if (self.currentRoute()) |route| switch (route.*) {
            .actions => return switch (std.ascii.toLower(byte)) {
                'c' => self.requestCancel(),
                'r' => self.requestResume(),
                'x' => try self.requestClose(alloc),
                else => .none,
            },
            .confirm_close => return switch (std.ascii.toLower(byte)) {
                'y' => .submit_manager_mutation,
                'n' => self.handleWithMainApproval(alloc, .escape, main_approval_id),
                else => if (byte == '\r') .submit_manager_mutation else .none,
            },
            .approval => if (byte >= '1' and byte <= '3') {
                self.approval_decision = switch (byte) {
                    '1' => .once,
                    '2' => .always,
                    '3' => .deny,
                    else => unreachable,
                };
                self.approval_failure = null;
                return .resolve_child_approval;
            },
            .archived => if (std.ascii.toLower(byte) == 'o') return self.requestReopen(),
            else => {},
        };

        if (self.childRouteId() == null) {
            return self.handleWithMainApproval(alloc, switch (byte) {
                '\r' => .enter,
                else => switch (std.ascii.toLower(byte)) {
                    'j' => .down,
                    'k' => .up,
                    'h' => .left,
                    'l' => .right,
                    'a' => .activity,
                    'n' => .notifications,
                    'r' => .archived,
                    'c' => return self.openCreate(alloc),
                    't' => return self.openAttach(alloc),
                    ']' => .next_page,
                    '[' => .previous_page,
                    else => return .none,
                },
            }, main_approval_id);
        }
        if (byte == '\t') {
            const messageable = if (self.child.chat) |chat|
                chat.messageable()
            else
                false;
            self.focus = if (self.focus == .child_composer)
                .child_detail
            else if (messageable)
                .child_composer
            else
                .child_detail;
            return .redraw;
        }
        if (self.focus == .child_detail) {
            return switch (std.ascii.toLower(byte)) {
                's' => self.openConfigure(alloc),
                'x' => self.openActions(alloc),
                'a' => self.openActivity(alloc),
                'n' => self.openNotification(alloc, main_approval_id),
                else => if (byte == '\r') self.handleChildAction(alloc, .enter) else .none,
            };
        }
        if (self.child.chat == null or !self.child.chat.?.messageable()) {
            return .none;
        }
        switch (byte) {
            '\r' => return self.handleChildAction(alloc, .enter),
            1 => return self.handleChildAction(alloc, .home),
            5 => return self.handleChildAction(alloc, .end),
            0x7f, 8 => {
                if (self.child.editor.deletionState(null).delete(
                    alloc,
                    .character_left,
                    .clear,
                )) self.child.edited(alloc);
            },
            11 => return self.handleChildAction(alloc, .delete_to_line_end),
            21 => return self.handleChildAction(alloc, .clear_line),
            23 => return self.handleChildAction(alloc, .delete_word_left),
            else => {
                if (byte < 0x20) return .none;
                const inserted = if (self.child.editor.edit_state.selectionRange() != null)
                    try self.child.editor.replacementState(null).replaceSelectionBounded(
                        alloc,
                        &.{byte},
                        domain.max_message_bytes,
                    ) == .inserted
                else if (self.child.editor.edit_state.input.items.len < domain.max_message_bytes) blk: {
                    try self.child.editor.insertionState().insertByte(alloc, byte, .clear);
                    break :blk true;
                } else false;
                if (!inserted) return .none;
                self.child.edited(alloc);
            },
        }
        return .redraw;
    }

    fn handleFormByte(self: *Runtime, alloc: Allocator, byte: u8) !Command {
        if (byte == '\r') return .submit_manager_mutation;
        if (byte == '\t') {
            self.moveFormField(1);
            return .redraw;
        }
        const field = self.form.currentField() orelse return .none;
        const editor = self.form.editorForField(field);
        if (editor == null) {
            if (byte == ' ') {
                self.cycleFormToggle(alloc, 1);
                return .redraw;
            }
            return .none;
        }
        const value = editor.?;
        switch (byte) {
            1 => return self.handleFormAction(alloc, .home),
            5 => return self.handleFormAction(alloc, .end),
            0x7f, 8 => if (value.deletionState(null).delete(
                alloc,
                .character_left,
                .clear,
            )) self.form.edit(alloc),
            11 => return self.handleFormAction(alloc, .delete_to_line_end),
            21 => return self.handleFormAction(alloc, .clear_line),
            23 => return self.handleFormAction(alloc, .delete_word_left),
            else => {
                const max_bytes = formFieldMaxBytes(field);
                if (byte >= 0x20 and value.edit_state.input.items.len < max_bytes) {
                    value.insertionState().insertByte(alloc, byte, .clear) catch {
                        self.form.attempt.failure = .{ .validation = .allocation_failure };
                        return .redraw;
                    };
                    self.form.edit(alloc);
                } else return .none;
            },
        }
        return .redraw;
    }

    fn moveFormField(self: *Runtime, delta: i2) void {
        const fields = self.form.fields();
        if (fields.len == 0) return;
        if (delta < 0) {
            self.form.field_index = if (self.form.field_index == 0)
                fields.len - 1
            else
                self.form.field_index - 1;
        } else {
            self.form.field_index = (self.form.field_index + 1) % fields.len;
        }
    }

    fn cycleFormToggle(self: *Runtime, alloc: Allocator, delta: i2) void {
        const field = self.form.currentField() orelse return;
        switch (field) {
            .effort => {},
            .permission_mode => self.form.permission_mode = if (delta < 0)
                previousPermissionMode(self.form.permission_mode)
            else
                nextPermissionMode(self.form.permission_mode),
            .notifications => self.form.notifications_enabled = !self.form.notifications_enabled,
            .completed => self.form.terminal.completed = !self.form.terminal.completed,
            .failed => self.form.terminal.failed = !self.form.terminal.failed,
            .cancelled => self.form.terminal.cancelled = !self.form.terminal.cancelled,
            else => return,
        }
        self.form.edit(alloc);
    }

    fn moveSelection(self: *Runtime, alloc: Allocator, delta: i2) !Command {
        const archived = self.archivedListActive();
        if (self.routes.items.len != 0 and !archived) {
            if (delta < 0) self.detail_scroll -|= 1 else self.detail_scroll +|= 1;
            return .redraw;
        }
        if (!archived and self.routes.items.len == 0) {
            return self.moveRootSelection(alloc, delta);
        }
        const snapshot = self.snapshot orelse return .none;
        const selected = if (archived) self.archived_selected_id else self.selected_id;
        const current = if (selected) |id|
            indexOfNode(snapshot.nodes, id) orelse firstNodeIndex(snapshot.nodes, archived) orelse return .none
        else
            firstNodeIndex(snapshot.nodes, archived) orelse return .none;
        const next = nextNodeIndex(snapshot.nodes, current, delta, archived) orelse return .none;
        try self.setSelectedBorrowed(alloc, snapshot.nodes[next].child_id, archived);
        return .redraw;
    }

    fn moveRootSelection(
        self: *Runtime,
        alloc: Allocator,
        delta: i2,
    ) !Command {
        const child_snapshot = self.snapshot;
        const terminal_snapshot = self.terminal_snapshot;
        if (self.root_selection == .child) {
            if (child_snapshot) |snapshot| {
                const current = if (self.selected_id) |id|
                    indexOfNode(snapshot.nodes, id)
                else
                    firstNodeIndex(snapshot.nodes, false);
                if (current) |index| {
                    if (adjacentNodeIndex(snapshot.nodes, index, delta, false)) |next| {
                        try self.setSelectedBorrowed(alloc, snapshot.nodes[next].child_id, false);
                        return .redraw;
                    }
                }
            }
            if (terminal_snapshot) |snapshot| {
                const terminal = if (delta > 0)
                    firstVisibleTerminal(snapshot.rows)
                else
                    lastVisibleTerminal(snapshot.rows);
                if (terminal) |row| {
                    try self.setSelectedTerminalBorrowed(alloc, row.session_id);
                    self.root_selection = .terminal;
                    return .redraw;
                }
            }
            const snapshot = child_snapshot orelse return .none;
            const node = if (delta > 0)
                firstNode(snapshot.nodes, false)
            else
                lastNode(snapshot.nodes, false);
            const wrapped = node orelse return .none;
            try self.setSelectedBorrowed(alloc, wrapped.child_id, false);
            return .redraw;
        }

        if (terminal_snapshot) |snapshot| {
            if (self.selected_terminal_id) |id| {
                if (adjacentVisibleTerminal(snapshot.rows, id, delta)) |row| {
                    try self.setSelectedTerminalBorrowed(alloc, row.session_id);
                    return .redraw;
                }
            }
        }
        if (child_snapshot) |snapshot| {
            const node = if (delta > 0)
                firstNode(snapshot.nodes, false)
            else
                lastNode(snapshot.nodes, false);
            if (node) |child| {
                try self.setSelectedBorrowed(alloc, child.child_id, false);
                self.root_selection = .child;
                return .redraw;
            }
        }
        const snapshot = terminal_snapshot orelse return .none;
        const terminal = if (delta > 0)
            firstVisibleTerminal(snapshot.rows)
        else
            lastVisibleTerminal(snapshot.rows);
        const wrapped = terminal orelse return .none;
        try self.setSelectedTerminalBorrowed(alloc, wrapped.session_id);
        return .redraw;
    }

    fn setSelectedTerminalBorrowed(
        self: *Runtime,
        alloc: Allocator,
        id: []const u8,
    ) !void {
        const owned = try alloc.dupe(u8, id);
        if (self.selected_terminal_id) |old| alloc.free(old);
        self.selected_terminal_id = owned;
    }

    fn movePage(self: *Runtime, alloc: Allocator, down: bool) !Command {
        const archived = self.archivedListActive();
        if (self.routes.items.len != 0 and !archived) {
            if (down) self.detail_scroll +|= 8 else self.detail_scroll -|= 8;
            return .redraw;
        }
        const snapshot = self.snapshot orelse return .none;
        const selected = if (archived) self.archived_selected_id else self.selected_id;
        var next = if (selected) |id|
            indexOfNode(snapshot.nodes, id) orelse firstNodeIndex(snapshot.nodes, archived) orelse return .none
        else
            firstNodeIndex(snapshot.nodes, archived) orelse return .none;
        for (0..8) |_| {
            next = nextNodeIndex(snapshot.nodes, next, if (down) 1 else -1, archived) orelse break;
        }
        try self.setSelectedBorrowed(alloc, snapshot.nodes[next].child_id, archived);
        return .redraw;
    }

    fn setSelectedBorrowed(
        self: *Runtime,
        alloc: Allocator,
        id: []const u8,
        archived: bool,
    ) !void {
        const owned = try alloc.dupe(u8, id);
        errdefer alloc.free(owned);
        if (archived) {
            if (self.archived_selected_id) |old| alloc.free(old);
            self.archived_selected_id = owned;
        } else {
            const selection_unchanged = if (self.selected_id) |old|
                std.mem.eql(u8, old, id)
            else
                false;
            if (!selection_unchanged) try self.switchChildDraft(alloc, id);
            if (self.selected_id) |old| alloc.free(old);
            self.selected_id = owned;
        }
    }

    fn switchChildDraft(
        self: *Runtime,
        alloc: Allocator,
        next_child_id: []const u8,
    ) !void {
        if (self.selected_id) |current_child_id| {
            var current_index = self.childDraftIndex(current_child_id);
            if (current_index == null) {
                const owned_id = try alloc.dupe(u8, current_child_id);
                errdefer alloc.free(owned_id);
                try self.child_drafts.append(alloc, .{ .child_id = owned_id });
                current_index = self.child_drafts.items.len - 1;
            }
            std.mem.swap(
                core_input_runtime.Runtime,
                &self.child.editor,
                &self.child_drafts.items[current_index.?].editor,
            );
        }

        self.child.clear(alloc);
        if (self.childDraftIndex(next_child_id)) |next_index| {
            std.mem.swap(
                core_input_runtime.Runtime,
                &self.child.editor,
                &self.child_drafts.items[next_index].editor,
            );
        }
        self.selected_child_viewport = null;
        self.clearPendingChildAcknowledgement(alloc);
    }

    fn childDraftIndex(self: *const Runtime, child_id: []const u8) ?usize {
        for (self.child_drafts.items, 0..) |draft, index| {
            if (std.mem.eql(u8, draft.child_id, child_id)) return index;
        }
        return null;
    }

    fn clearChildDrafts(self: *Runtime, alloc: Allocator) void {
        for (self.child_drafts.items) |*draft| draft.deinit(alloc);
        self.child_drafts.clearRetainingCapacity();
    }

    fn clearChildSelectionState(
        self: *Runtime,
        alloc: Allocator,
        reason: []const u8,
    ) void {
        var dropped_bytes = self.child.editor.edit_state.input.items.len;
        for (self.child_drafts.items) |draft| {
            dropped_bytes += draft.editor.edit_state.input.items.len;
        }
        if (dropped_bytes > 0) {
            debug_trace.logf(
                "subagent",
                "child draft dropped bytes={d} reason={s}",
                .{ dropped_bytes, reason },
            );
        }
        self.child.clear(alloc);
        self.clearChildDrafts(alloc);
        self.selected_child_viewport = null;
        self.clearPendingChildAcknowledgement(alloc);
    }

    fn setPendingChildAcknowledgement(
        self: *Runtime,
        alloc: Allocator,
        child_id: []const u8,
        through_sequence: u64,
    ) !void {
        const owned_child_id = try alloc.dupe(u8, child_id);
        self.clearPendingChildAcknowledgement(alloc);
        self.pending_child_acknowledgement = .{
            .child_id = owned_child_id,
            .through_sequence = through_sequence,
        };
    }

    fn clearPendingChildAcknowledgement(self: *Runtime, alloc: Allocator) void {
        if (self.pending_child_acknowledgement) |*pending| pending.deinit(alloc);
        self.pending_child_acknowledgement = null;
    }

    fn openSelected(self: *Runtime, alloc: Allocator) !Command {
        const archived = self.archivedListActive();
        if (self.routes.items.len != 0 and !archived) return self.openActivity(alloc);
        if (!archived and self.root_selection == .terminal and
            self.selected_terminal_id != null)
        {
            return .open_terminal;
        }
        const node = (if (archived) self.archivedSelectedNode() else self.selectedNode()) orelse return .none;
        self.child.clearViewPreservingDraft(alloc);
        self.restoreSelectedChildViewport(node.child_id);
        const child_id = try alloc.dupe(u8, node.child_id);
        errdefer alloc.free(child_id);
        try self.routes.append(alloc, .{ .child = child_id });
        self.focus = .child_composer;
        self.detail_scroll = 0;
        return .child_changed;
    }

    fn openArchived(self: *Runtime, alloc: Allocator) !Command {
        if (self.routes.items.len != 0) return .none;
        try self.routes.append(alloc, .archived);
        self.focus = .archived_list;
        self.detail_scroll = 0;
        return .redraw;
    }

    fn openCreate(self: *Runtime, alloc: Allocator) !Command {
        if (self.routes.items.len != 0) return .none;
        self.form.clear(alloc);
        self.form.kind = .create;
        self.form.permission_mode = .yolo;
        if (self.default_model) |model| {
            self.form.replaceEditor(alloc, .model, model) catch |err| {
                self.form.clear(alloc);
                return err;
            };
        }
        self.form.replaceEditor(alloc, .effort, self.default_effort.displayLabel()) catch |err| {
            self.form.clear(alloc);
            return err;
        };
        self.routes.append(alloc, .create) catch |err| {
            self.form.clear(alloc);
            return err;
        };
        self.focus = .create_form;
        return .redraw;
    }

    fn openAttach(self: *Runtime, alloc: Allocator) !Command {
        if (self.routes.items.len != 0) return .none;
        self.attach.clear(alloc);
        self.attach.loading = true;
        self.routes.append(alloc, .attach) catch |err| {
            self.attach.clear(alloc);
            return err;
        };
        self.focus = .attach_list;
        return .load_attach_candidates;
    }

    fn openConfigure(self: *Runtime, alloc: Allocator) !Command {
        const node = self.routedNode() orelse return .none;
        const configuration = node.configuration orelse return .none;
        self.form.clear(alloc);
        self.form.kind = .configure;
        self.form.target_id = try alloc.dupe(u8, node.child_id);
        errdefer self.form.clear(alloc);
        self.form.expected_generation = node.generation;
        const effort = configuration.effort orelse self.default_effort;
        self.form.permission_mode = configuration.permission_mode;
        self.form.terminal = configuration.notifications.terminal;
        try self.form.replaceEditor(alloc, .name, configuration.name);
        try self.form.replaceEditor(alloc, .model, configuration.model orelse self.default_model orelse "");
        try self.form.replaceEditor(alloc, .effort, effort.displayLabel());
        const milestones = try std.mem.join(
            alloc,
            ", ",
            configuration.notifications.milestones,
        );
        defer alloc.free(milestones);
        try self.form.replaceEditor(alloc, .milestones, milestones);
        var number_buf: [32]u8 = undefined;
        if (configuration.notifications.report_interval_ms) |value| {
            try self.form.replaceEditor(
                alloc,
                .interval,
                try std.fmt.bufPrint(&number_buf, "{d}", .{value}),
            );
        }
        if (configuration.notifications.report_duration_ms) |value| {
            try self.form.replaceEditor(
                alloc,
                .duration,
                try std.fmt.bufPrint(&number_buf, "{d}", .{value}),
            );
        }
        const child_id = try alloc.dupe(u8, node.child_id);
        errdefer alloc.free(child_id);
        try self.routes.append(alloc, .{ .configure = child_id });
        self.focus = .configure_form;
        return .redraw;
    }

    fn openActions(self: *Runtime, alloc: Allocator) !Command {
        const node = self.routedNode() orelse return .none;
        const child_id = try alloc.dupe(u8, node.child_id);
        errdefer alloc.free(child_id);
        self.lifecycle_attempt.deinit(alloc);
        self.lifecycle_action = null;
        try self.routes.append(alloc, .{ .actions = child_id });
        self.focus = .actions;
        return .redraw;
    }

    fn requestCancel(self: *Runtime) Command {
        const node = self.routedNode() orelse return .none;
        if (projection.cancellationCapability(
            node.state,
            node.external_busy,
        ) != .available) return .none;
        self.lifecycle_attempt.failure = null;
        self.lifecycle_action = .cancel;
        return .submit_manager_mutation;
    }

    fn handleCtrlC(self: *Runtime) Command {
        const route = self.currentRoute() orelse return .exit_app;
        const child_id = switch (route.*) {
            .child => |id| id,
            else => return .exit_app,
        };
        const snapshot = self.snapshot orelse return .exit_app;
        const node = findNodeIn(snapshot.nodes, child_id) orelse return .exit_app;
        if (!childHasActiveWork(node.state)) return .exit_app;
        return self.requestCancel();
    }

    fn requestResume(self: *Runtime) Command {
        const node = self.routedNode() orelse return .none;
        if (node.state != .interrupted and !node.external_busy) return .none;
        self.lifecycle_attempt.failure = null;
        self.lifecycle_action = .@"resume";
        return .submit_manager_mutation;
    }

    fn requestClose(self: *Runtime, alloc: Allocator) !Command {
        const node = self.routedNode() orelse return .none;
        self.lifecycle_attempt.failure = null;
        self.lifecycle_action = .close;
        if (!childHasActiveWork(node.state)) return .submit_manager_mutation;
        const child_id = try alloc.dupe(u8, node.child_id);
        errdefer alloc.free(child_id);
        try self.routes.append(alloc, .{ .confirm_close = child_id });
        self.focus = .confirmation;
        return .redraw;
    }

    fn requestReopen(self: *Runtime) Command {
        const node = self.archivedSelectedNode() orelse return .none;
        if (node.state != .archived) return .none;
        self.lifecycle_attempt.failure = null;
        self.lifecycle_action = .reopen;
        return .submit_manager_mutation;
    }

    fn nextPage(self: *Runtime, alloc: Allocator) !Command {
        if (self.currentRoute()) |route| switch (route.*) {
            .archived => {},
            else => return .none,
        };
        const snapshot = self.snapshot orelse return .none;
        const cursor_source = snapshot.next_cursor orelse return .none;
        const next_cursor = try alloc.dupe(u8, cursor_source);
        errdefer alloc.free(next_cursor);
        try self.page_history.append(alloc, self.page_cursor);
        self.page_cursor = next_cursor;
        self.preserve_page_anchor = false;
        self.list_scroll = 0;
        self.archived_scroll = 0;
        return .page_changed;
    }

    fn previousPage(self: *Runtime, alloc: Allocator) Command {
        if (self.currentRoute()) |route| switch (route.*) {
            .archived => {},
            else => return .none,
        };
        const previous = self.page_history.pop() orelse blk: {
            if (self.page_cursor == null) return .none;
            break :blk null;
        };
        if (self.page_cursor) |cursor| alloc.free(cursor);
        self.page_cursor = previous;
        self.preserve_page_anchor = false;
        self.list_scroll = 0;
        self.archived_scroll = 0;
        return .page_changed;
    }

    fn archivedListActive(self: Runtime) bool {
        const route = self.currentRoute() orelse return false;
        return route.* == .archived;
    }

    fn openActivity(self: *Runtime, alloc: Allocator) !Command {
        const node = self.routedNode() orelse return .none;
        const child_id = try alloc.dupe(u8, node.child_id);
        errdefer alloc.free(child_id);
        try self.routes.append(alloc, .{ .activity = child_id });
        self.focus = .activity;
        self.detail_scroll = 0;
        return if (node.through_sequence > 0) .acknowledge else .redraw;
    }

    fn openNotification(self: *Runtime, alloc: Allocator, main_approval_id: ?u64) !Command {
        if (self.routes.items.len == 0) {
            const current_card = if (self.main_approval_card) |card|
                if (self.snapshot) |snapshot|
                    if (approvalCardStillPending(snapshot, card)) card else null
                else
                    null
            else
                null;
            if (try approvalRouteForCard(alloc, current_card)) |route_value| {
                var route = route_value;
                errdefer route.deinit(alloc);
                const acknowledge_node = if (self.snapshot) |snapshot|
                    pendingApprovalIndex(
                        snapshot,
                        route.approval.child_id,
                        route.approval.approval_id,
                    ) == null and
                        (if (findNodeIn(snapshot.nodes, route.approval.child_id)) |node|
                            node.through_sequence > 0
                        else
                            false)
                else
                    false;
                try self.routes.append(alloc, route);
                self.focus = .approval;
                self.detail_scroll = 0;
                return if (acknowledge_node) .acknowledge else .redraw;
            }
            if (main_approval_id) |request_id| {
                try self.routes.append(alloc, .{ .main_approval = request_id });
                self.focus = .approval;
                self.detail_scroll = 0;
                return .redraw;
            }
        }
        const node = self.routedNode() orelse return .none;
        if (node.approvals.len > 0) {
            const approval = node.approvals[node.approvals.len - 1];
            const child_id = try alloc.dupe(u8, node.child_id);
            errdefer alloc.free(child_id);
            const approval_id = try alloc.dupe(u8, approval.id);
            errdefer alloc.free(approval_id);
            try self.routes.append(alloc, .{ .approval = .{
                .child_id = child_id,
                .approval_id = approval_id,
            } });
            self.focus = .approval;
        } else if (node.activity.len > 0) {
            const latest = node.activity[node.activity.len - 1];
            const child_id = try alloc.dupe(u8, node.child_id);
            errdefer alloc.free(child_id);
            try self.routes.append(alloc, .{ .notification = .{
                .child_id = child_id,
                .sequence = latest.sequence,
            } });
            self.focus = .notification;
        } else return .none;
        self.detail_scroll = 0;
        return if (node.through_sequence > 0) .acknowledge else .redraw;
    }

    fn syncFocus(self: *Runtime) void {
        const route = self.currentRoute() orelse {
            self.focus = .child_list;
            return;
        };
        self.focus = switch (route.*) {
            .archived => .archived_list,
            .create => .create_form,
            .attach => .attach_list,
            .child => .child_composer,
            .configure => .configure_form,
            .actions => .actions,
            .confirm_close => .confirmation,
            .activity => .activity,
            .notification => .notification,
            .approval => .approval,
            .main_approval => .approval,
        };
    }

    fn rememberSelectedChildViewport(self: *Runtime) void {
        const child_id = self.childRouteId() orelse return;
        const selected_id = self.selected_id orelse return;
        if (!std.mem.eql(u8, selected_id, child_id)) return;
        self.selected_child_viewport = .{
            .rows_from_bottom = self.child.scroll_from_bottom,
            .prior_total_rows = self.child.rendered_chat_rows,
            .full_transcript = if (self.child.presentation) |*runtime|
                runtime.snapshotFullTranscriptViewport()
            else
                null,
        };
    }

    fn selectedChildFullTranscriptBookmark(
        self: *const Runtime,
    ) ?transcript_presentation.Snapshot {
        const child_id = self.childRouteId() orelse return null;
        const selected_id = self.selected_id orelse return null;
        if (!std.mem.eql(u8, selected_id, child_id)) return null;
        const bookmark = self.selected_child_viewport orelse return null;
        return bookmark.full_transcript;
    }

    fn restoreSelectedChildViewport(
        self: *Runtime,
        child_id: []const u8,
    ) void {
        const selected_id = self.selected_id orelse return;
        if (!std.mem.eql(u8, selected_id, child_id)) return;
        const bookmark = self.selected_child_viewport orelse return;
        self.child.scroll_from_bottom = bookmark.rows_from_bottom;
        self.child.rendered_chat_rows = bookmark.prior_total_rows;
        self.child.viewport_mutation = .bottom;
    }

    fn clearRoutes(self: *Runtime, alloc: Allocator) void {
        for (self.routes.items) |*route| route.deinit(alloc);
        self.routes.clearRetainingCapacity();
    }

    fn clampListScroll(self: *Runtime, visible_rows: usize, archived: bool) void {
        const snapshot = self.snapshot orelse {
            if (archived) self.archived_scroll = 0 else self.list_scroll = 0;
            return;
        };
        const selected_id = if (archived) self.archived_selected_id else self.selected_id;
        const selected_raw = if (selected_id) |id| indexOfNode(snapshot.nodes, id) else null;
        const selected = visibleIndex(snapshot.nodes, selected_raw, archived);
        const visible_count = countNodes(snapshot.nodes, archived);
        const scroll = if (archived) &self.archived_scroll else &self.list_scroll;
        if (selected < scroll.*) scroll.* = selected;
        if (selected >= scroll.* + visible_rows) {
            scroll.* = selected + 1 - visible_rows;
        }
        const max_scroll = visible_count -| visible_rows;
        scroll.* = @min(scroll.*, max_scroll);
    }

    fn clampTerminalScroll(self: *Runtime, visible_rows: usize) void {
        const snapshot = self.terminal_snapshot orelse {
            self.terminal_scroll = 0;
            return;
        };
        const selected_id = self.selected_terminal_id orelse {
            self.terminal_scroll = 0;
            return;
        };
        const selected = visibleTerminalIndex(snapshot.rows, selected_id) orelse {
            self.terminal_scroll = 0;
            return;
        };
        if (selected < self.terminal_scroll) self.terminal_scroll = selected;
        if (selected >= self.terminal_scroll + visible_rows) {
            self.terminal_scroll = selected + 1 - visible_rows;
        }
        const max_scroll = countVisibleTerminals(snapshot.rows) -| visible_rows;
        self.terminal_scroll = @min(self.terminal_scroll, max_scroll);
    }
};

test "repeated editor defaults are initialized through one runtime path" {
    const runtime = Runtime.init();
    try std.testing.expect(runtime.loading);
    try std.testing.expect(runtime.preserve_page_anchor);
    try std.testing.expectEqual(FormKind.none, runtime.form.kind);
    for (runtime.form.editors) |editor| {
        try std.testing.expect(editor.slash_menu_categories);
    }
}

test "child route initializer preserves every runtime default" {
    var child = ChildRouteState.init();
    defer child.deinit(std.testing.allocator);

    try std.testing.expect(child.chat == null);
    try std.testing.expect(child.unavailable == null);
    try std.testing.expectEqual(@as(usize, 0), child.pages.pages.items.len);
    try std.testing.expect(child.editor.slash_menu_categories);
    try std.testing.expectEqual(@as(usize, 0), child.scroll_from_bottom);
    try std.testing.expectEqual(@as(usize, 0), child.max_scroll);
    try std.testing.expect(child.invocation_id == null);
    try std.testing.expectEqual(@as(u64, 0), child.identity_epoch);
    try std.testing.expect(child.submission_failure == null);
    try std.testing.expect(child.input_failure == null);
    try std.testing.expect(child.paste_rejection == null);
    try std.testing.expectEqual(@as(u64, 0), child.operation_counter);
    try std.testing.expect(child.rendered_chat_rows == null);
    try std.testing.expectEqual(ViewportMutation.none, child.viewport_mutation);
    try std.testing.expect(child.presentation == null);
    try std.testing.expectEqual(
        transcript_presentation.Depth.inline_mode,
        child.presentation_transcript_depth,
    );
    try std.testing.expect(child.presentation_live_work_id == null);
    try std.testing.expectEqual(@as(usize, 0), child.presentation_live_event_count);
    try std.testing.expectEqual(@as(u32, 1), child.presentation_next_diff_id);
    try std.testing.expectEqual(@as(usize, 0), child.presentation_diffs.items.len);
    try std.testing.expectEqual(@as(u64, 0), child.presented_through_sequence);
}

pub fn paint(
    alloc: Allocator,
    runtime: *Runtime,
    layout: types.Layout,
    main_approval: ?permission_request.PermissionRequest,
) ![]u8 {
    if (layout.rows == 0 or layout.cols == 0) return alloc.dupe(u8, "");
    var screen: std.Io.Writer.Allocating = .init(alloc);
    defer screen.deinit();
    try screen.writer.writeAll("\x1b[?25l\x1b[H\x1b[2J");

    var row: usize = 0;
    if (pendingApprovalOwner(runtime, main_approval)) |owner| {
        try writeApprovalOwnerLine(
            alloc,
            &screen.writer,
            layout.cols,
            &row,
            layout.rows,
            owner,
            "Agents & processes · main chat approval pending",
            "Agents & processes · ",
            " approval pending",
        );
    } else {
        try writeManagerTitle(alloc, &screen.writer, runtime, layout.cols, &row, layout.rows);
    }
    if (layout.rows == 1) return screen.toOwnedSlice();

    const footer_rows: usize = if (layout.rows >= 3) 1 else 0;
    const body_limit = @as(usize, layout.rows) - footer_rows;
    const main_approval_route_active = if (runtime.currentRoute()) |route| switch (route.*) {
        .main_approval => true,
        else => false,
    } else false;
    if (main_approval_route_active) {
        try paintRoute(alloc, &screen.writer, runtime, runtime.currentRoute().?.*, main_approval, layout.cols, &row, body_limit);
    } else if (runtime.loading) {
        try writeLine(alloc, &screen.writer, layout.cols, &row, body_limit, "Loading agents…");
    } else if (runtime.degraded) |failure| {
        try writeFormattedLine(alloc, &screen.writer, layout.cols, &row, body_limit, "Manager degraded: {s}", .{@tagName(failure)});
        try writeLine(alloc, &screen.writer, layout.cols, &row, body_limit, "The main conversation is unchanged. ctrl-x closes.");
    } else if (runtime.currentRoute()) |route| {
        try paintRoute(alloc, &screen.writer, runtime, route.*, main_approval, layout.cols, &row, body_limit);
    } else {
        try paintRoot(alloc, &screen.writer, runtime, main_approval, layout.cols, &row, body_limit);
    }
    while (row < body_limit) try writeLine(alloc, &screen.writer, layout.cols, &row, body_limit, "");
    if (footer_rows > 0) {
        try screen.writer.writeAll("\r\n");
        const footer = if (runtime.routes.items.len == 0)
            if (runtime.snapshot) |snapshot|
                rootFooter(layout.cols, hasTreePagination(snapshot))
            else
                rootFooter(layout.cols, false)
        else switch (runtime.currentRoute().?.*) {
            .archived => "ctrl-x close  •  Enter details  •  O reopen  •  [/] pages  •  Esc back",
            .create, .configure => "ctrl-x close  •  Tab/Arrows fields  •  Enter submit  •  Esc discard/back",
            .attach => "ctrl-x close  •  J/K select  •  Enter authorize action  •  Esc back",
            .actions => actionsFooter(runtime),
            .confirm_close => "ctrl-x close  •  Y/Enter cancel and archive  •  N/Esc back",
            .approval => managerApprovalFooter(runtime),
            else => "ctrl-x close  •  Esc back  •  A activity  •  N notifications",
        };
        try writeLine(alloc, &screen.writer, layout.cols, &row, layout.rows, footer);
    }
    return screen.toOwnedSlice();
}

fn writeManagerTitle(
    alloc: Allocator,
    writer: *std.Io.Writer,
    runtime: *const Runtime,
    cols: u16,
    row: *usize,
    limit: usize,
) !void {
    var line: std.Io.Writer.Allocating = .init(alloc);
    defer line.deinit();
    try line.writer.writeAll(ui_render.bold_style);
    try line.writer.writeAll("Agents & processes");
    try line.writer.writeAll(ui_render.reset_style);
    const complete_active_count = if (runtime.snapshot) |snapshot|
        runtime.terminal_snapshot != null and !hasTreePagination(snapshot)
    else
        false;
    if (complete_active_count) {
        try line.writer.writeAll(ui_render.dim_style);
        try line.writer.print(" · {d} active", .{managerActiveCount(runtime)});
        try line.writer.writeAll(ui_render.reset_style);
    }
    try writeLine(alloc, writer, cols, row, limit, line.written());
}

fn managerActiveCount(runtime: *const Runtime) usize {
    var count: usize = 0;
    if (runtime.snapshot) |snapshot| {
        for (snapshot.nodes) |node| {
            if (node.external_busy or switch (node.state) {
                .queued, .running, .awaiting_approval => true,
                else => false,
            }) count += 1;
        }
    }
    if (runtime.terminal_snapshot) |snapshot| {
        count += countVisibleTerminals(snapshot.rows);
    }
    return count;
}

const root_footer_variants = [_][]const u8{
    "↑↓ select   enter inspect   c new agent   t attach   r archives   ctrl-x close",
    "↑↓ select   enter inspect   c new   t attach   r archives   ctrl-x close",
    "↑↓ select   enter inspect   ctrl-x close",
    "ctrl-x close",
};

const paginated_root_footer_variants = [_][]const u8{
    "↑↓ select   [ ] pages   enter inspect   c new agent   t attach   r archives   ctrl-x close",
    "↑↓ select   [ ] pages   enter inspect   ctrl-x close",
    "ctrl-x close   [ ] pages",
    "ctrl-x close",
};

fn rootFooter(cols: u16, paginated: bool) []const u8 {
    const variants: []const []const u8 = if (paginated)
        &paginated_root_footer_variants
    else
        &root_footer_variants;
    return display_width.widestFitting(variants, cols);
}

const PendingApprovalOwner = union(enum) {
    main_chat,
    subagent: []const u8,
};

fn pendingApprovalOwner(
    runtime: *const Runtime,
    main_approval: ?permission_request.PermissionRequest,
) ?PendingApprovalOwner {
    if (runtime.main_approval_card) |card| {
        if (runtime.snapshot) |snapshot| {
            if (approvalCardStillPending(snapshot, card)) {
                return .{ .subagent = card.child_name };
            }
        }
    }
    if (runtime.snapshot) |snapshot| {
        if (selectedPendingApproval(
            snapshot,
            runtime.pending_approval_selection,
        )) |pending| {
            return .{ .subagent = pending.child_name };
        }
    }
    const request = main_approval orelse return null;
    return switch (request.origin) {
        .active_session => .main_chat,
        .subagent => |child_name| .{ .subagent = child_name },
    };
}

fn writeApprovalOwnerLine(
    alloc: Allocator,
    writer: *std.Io.Writer,
    cols: u16,
    row: *usize,
    limit: usize,
    owner: PendingApprovalOwner,
    main_chat_text: []const u8,
    subagent_prefix: []const u8,
    subagent_suffix: []const u8,
) !void {
    switch (owner) {
        .main_chat => try writeLine(
            alloc,
            writer,
            cols,
            row,
            limit,
            main_chat_text,
        ),
        .subagent => |child_name| {
            var line: std.Io.Writer.Allocating = .init(alloc);
            defer line.deinit();
            try line.writer.writeAll(subagent_prefix);
            try writeSafe(
                &line.writer,
                alloc,
                child_name,
                projection.max_summary_bytes,
            );
            try line.writer.writeAll(subagent_suffix);
            try writeLine(
                alloc,
                writer,
                cols,
                row,
                limit,
                line.written(),
            );
        },
    }
}

fn paintRoot(
    alloc: Allocator,
    writer: *std.Io.Writer,
    runtime: *Runtime,
    main_approval: ?permission_request.PermissionRequest,
    cols: u16,
    row: *usize,
    limit: usize,
) !void {
    const snapshot = runtime.snapshot orelse {
        try writeLine(alloc, writer, cols, row, limit, "No manager snapshot available.");
        return;
    };
    const visible_terminal_count = if (runtime.terminal_snapshot) |terminal_snapshot|
        countVisibleTerminals(terminal_snapshot.rows)
    else
        0;
    const terminal_reserve = if (runtime.root_selection == .terminal and
        visible_terminal_count > 0)
        @min(limit -| row.*, visible_terminal_count + 2)
    else
        0;
    const child_limit = limit -| terminal_reserve;

    if (row.* + 2 < child_limit) try writeLine(alloc, writer, cols, row, child_limit, "");
    const agent_count = countNodes(snapshot.nodes, false);
    try writeSectionHeading(alloc, writer, cols, row, child_limit, "Agents", agent_count);
    if (pendingApprovalOwner(runtime, main_approval)) |owner| {
        try writeApprovalOwnerLine(
            alloc,
            writer,
            cols,
            row,
            child_limit,
            owner,
            "Notification: main chat approval pending — N details",
            "Notification: ",
            " approval pending — N details",
        );
        if (snapshot.pending_approval_total > 0) {
            try writeFormattedLine(
                alloc,
                writer,
                cols,
                row,
                child_limit,
                "Current approval: {d} of {d}",
                .{
                    snapshot.pending_approval_offset + runtime.pending_approval_selection + 1,
                    snapshot.pending_approval_total,
                },
            );
        }
    }
    if (snapshot.diagnostics.len > 0) {
        const suffix: []const u8 = if (snapshot.diagnostics_truncated) "+" else "";
        try writeFormattedLine(
            alloc,
            writer,
            cols,
            row,
            child_limit,
            "Degraded tree data: {d}{s} diagnostic(s)",
            .{ snapshot.diagnostics.len, suffix },
        );
    }
    if (agent_count == 0) {
        try writeDimLine(alloc, writer, cols, row, child_limit, "  No active agents");
    } else {
        try paintNodeRows(
            alloc,
            writer,
            runtime,
            false,
            cols,
            row,
            child_limit -| pageStatusRowCount(snapshot),
        );
    }
    try paintPageStatus(alloc, writer, snapshot, cols, row, child_limit);
    const terminal_body_rows = @max(visible_terminal_count, 1);
    if (limit -| row.* > terminal_body_rows + 1) {
        try writeLine(alloc, writer, cols, row, limit, "");
    }
    if (limit -| row.* > 1) {
        try writeSectionHeading(
            alloc,
            writer,
            cols,
            row,
            limit,
            "Background processes",
            visible_terminal_count,
        );
    }
    if (runtime.terminal_snapshot) |terminal_snapshot| {
        if (countVisibleTerminals(terminal_snapshot.rows) == 0) {
            try writeDimLine(alloc, writer, cols, row, limit, "  No background processes");
        } else {
            try paintTerminalRows(
                alloc,
                writer,
                runtime,
                terminal_snapshot.rows,
                cols,
                row,
                limit,
            );
        }
    } else {
        try writeDimLine(alloc, writer, cols, row, limit, "  No background processes");
    }
}

fn writeSectionHeading(
    alloc: Allocator,
    writer: *std.Io.Writer,
    cols: u16,
    row: *usize,
    limit: usize,
    label: []const u8,
    count: usize,
) !void {
    var line: std.Io.Writer.Allocating = .init(alloc);
    defer line.deinit();
    try line.writer.writeAll(ui_render.bold_style);
    try line.writer.print("{s} {d}", .{ label, count });
    try line.writer.writeAll(ui_render.reset_style);
    try writeLine(alloc, writer, cols, row, limit, line.written());
}

fn writeDimLine(
    alloc: Allocator,
    writer: *std.Io.Writer,
    cols: u16,
    row: *usize,
    limit: usize,
    text: []const u8,
) !void {
    var line: std.Io.Writer.Allocating = .init(alloc);
    defer line.deinit();
    try line.writer.writeAll(ui_render.dim_style);
    try line.writer.writeAll(text);
    try line.writer.writeAll(ui_render.reset_style);
    try writeLine(alloc, writer, cols, row, limit, line.written());
}

fn paintTerminalRows(
    alloc: Allocator,
    writer: *std.Io.Writer,
    runtime: *Runtime,
    rows: []const terminal_projection.Row,
    cols: u16,
    output_row: *usize,
    limit: usize,
) !void {
    const visible_rows = limit -| output_row.*;
    if (visible_rows == 0) return;
    runtime.clampTerminalScroll(visible_rows);
    var visible_index: usize = 0;
    for (rows) |terminal| {
        if (!terminalVisible(terminal)) continue;
        if (visible_index < runtime.terminal_scroll) {
            visible_index += 1;
            continue;
        }
        if (output_row.* >= limit) break;
        visible_index += 1;
        const selected = runtime.root_selection == .terminal and
            runtime.selected_terminal_id != null and
            std.mem.eql(u8, runtime.selected_terminal_id.?, terminal.session_id);
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(alloc);
        try composeTerminalRow(alloc, &line, terminal, selected, cols);
        try writeLine(alloc, writer, cols, output_row, limit, line.items);
    }
}

fn composeTerminalRow(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    terminal: terminal_projection.Row,
    selected: bool,
    cols: u16,
) !void {
    var safe_label = try text_utils.encodeTerminalSafe(alloc, terminal.label, 256);
    defer safe_label.deinit(alloc);
    var safe_id = try text_utils.encodeTerminalSafe(alloc, terminal.session_id, 128);
    defer safe_id.deinit(alloc);

    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.reset_style);
    try row.appendSlice(alloc, if (selected) "› " else "  ");

    const width: usize = cols;
    const prefix_width: usize = 2;
    const status = @tagName(terminal.lifecycle);
    const status_width = display_width.visibleWidth(status);
    const show_status = width >= prefix_width + status_width + 4;
    const left_limit = if (show_status) width - status_width - 3 else width;
    const available = left_limit -| prefix_width;
    const distinct_id = !std.mem.eql(u8, terminal.label, terminal.session_id);
    const id_budget: usize = if (distinct_id and available >= 18)
        @min(@as(usize, 12), available / 3)
    else
        0;
    const label_budget = available -| if (id_budget > 0) id_budget + 2 else 0;
    try row_text.appendSingleLineMiddleEllipsized(alloc, row, safe_label.bytes, label_budget);
    try row.appendSlice(alloc, ui_render.reset_style);
    if (id_budget > 0) {
        try row.appendSlice(alloc, "  ");
        try row.appendSlice(alloc, ui_render.dim_style);
        try row_text.appendSingleLineMiddleEllipsized(alloc, row, safe_id.bytes, id_budget);
        try row.appendSlice(alloc, ui_render.reset_style);
    }
    if (show_status) {
        const status_col = width - status_width - 1;
        try row_text.appendSpacesToColumn(alloc, row, status_col);
        try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.dim_style);
        try row.appendSlice(alloc, status);
        try row.appendSlice(alloc, ui_render.reset_style);
    }
}

fn paintArchived(
    alloc: Allocator,
    writer: *std.Io.Writer,
    runtime: *Runtime,
    cols: u16,
    row: *usize,
    limit: usize,
) !void {
    const snapshot = runtime.snapshot orelse {
        try writeLine(alloc, writer, cols, row, limit, "No manager snapshot available.");
        return;
    };
    try writeLine(alloc, writer, cols, row, limit, "Archived subagents");
    try writeLine(alloc, writer, cols, row, limit, "O Reopen selected child");
    if (countNodes(snapshot.nodes, true) == 0) {
        try writeLine(alloc, writer, cols, row, limit, "No archived subagents on this page.");
        try paintPageStatus(alloc, writer, snapshot, cols, row, limit);
        return;
    }
    try paintNodeRows(
        alloc,
        writer,
        runtime,
        true,
        cols,
        row,
        limit -| pageStatusRowCount(snapshot),
    );
    try paintPageStatus(alloc, writer, snapshot, cols, row, limit);
}

fn hasTreePagination(snapshot: projection.Snapshot) bool {
    return snapshot.next_cursor != null or snapshot.page_cursor != null;
}

fn pageStatusRowCount(snapshot: projection.Snapshot) usize {
    var rows: usize = 0;
    if (snapshot.next_cursor != null) rows += 1;
    if (snapshot.page_cursor != null) rows += 1;
    if (snapshot.restart_required) rows += 1;
    return rows;
}

fn paintNodeRows(
    alloc: Allocator,
    writer: *std.Io.Writer,
    runtime: *Runtime,
    archived: bool,
    cols: u16,
    row: *usize,
    limit: usize,
) !void {
    const snapshot = runtime.snapshot.?;
    const visible_rows = limit -| row.*;
    runtime.clampListScroll(@max(visible_rows, 1), archived);
    const scroll = if (archived) runtime.archived_scroll else runtime.list_scroll;
    const selected_id = if (archived) runtime.archived_selected_id else runtime.selected_id;
    var visible_index: usize = 0;
    for (snapshot.nodes) |node| {
        if ((node.state == .archived) != archived) continue;
        if (visible_index < scroll) {
            visible_index += 1;
            continue;
        }
        if (row.* >= limit) break;
        visible_index += 1;
        const selected = (archived or runtime.root_selection == .child) and
            selected_id != null and
            std.mem.eql(u8, selected_id.?, node.child_id);
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(alloc);
        try composeNodeRow(alloc, &line, &node, selected, cols);
        try writeLine(alloc, writer, cols, row, limit, line.items);
    }
}

fn composeNodeRow(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    node: *const projection.Node,
    selected: bool,
    cols: u16,
) !void {
    var safe_name = try text_utils.encodeTerminalSafe(alloc, node.name, 256);
    defer safe_name.deinit(alloc);
    var metadata: std.Io.Writer.Allocating = .init(alloc);
    defer metadata.deinit();
    var has_metadata = false;
    if (node.unread_count > 0) {
        try metadata.writer.print("unread {d}{s}", .{ node.unread_count, if (node.unread_truncated) "+" else "" });
        has_metadata = true;
    }
    if (node.stale) {
        if (has_metadata) try metadata.writer.writeAll(" · ");
        try metadata.writer.writeAll("history gap");
        has_metadata = true;
    }
    if (node.approvals.len > 0) {
        if (has_metadata) try metadata.writer.writeAll(" · ");
        try metadata.writer.print("approval {d}", .{node.approvals.len});
        has_metadata = true;
    }
    if (node.degraded) |reason| {
        if (has_metadata) try metadata.writer.writeAll(" · ");
        try metadata.writer.print("degraded {s}", .{@tagName(reason)});
        has_metadata = true;
    }

    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.reset_style);
    try row.appendSlice(alloc, if (selected) "› " else "  ");
    const depth = @min(node.depth, 8);
    try row.appendNTimes(alloc, ' ', depth * 2);

    const width: usize = cols;
    const prefix_width = @min(width, 2 + depth * 2);
    const status = nodeStateLabel(node);
    const status_width = display_width.visibleWidth(status);
    const show_status = width >= prefix_width + status_width + 4;
    const left_limit = if (show_status) width - status_width - 3 else width;
    const available = left_limit -| prefix_width;
    const metadata_width = display_width.visibleWidth(metadata.written());
    const show_metadata = has_metadata and available >= metadata_width + 10;
    const name_budget = available -| if (show_metadata) metadata_width + 2 else 0;
    try row_text.appendSingleLineMiddleEllipsized(alloc, row, safe_name.bytes, name_budget);
    try row.appendSlice(alloc, ui_render.reset_style);
    if (show_metadata) {
        try row.appendSlice(alloc, "  ");
        try row.appendSlice(alloc, ui_render.dim_style);
        try row.appendSlice(alloc, metadata.written());
        try row.appendSlice(alloc, ui_render.reset_style);
    }
    if (show_status) {
        const status_col = width - status_width - 1;
        try row_text.appendSpacesToColumn(alloc, row, status_col);
        try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.dim_style);
        try row.appendSlice(alloc, status);
        try row.appendSlice(alloc, ui_render.reset_style);
    }
}

fn paintPageStatus(
    alloc: Allocator,
    writer: *std.Io.Writer,
    snapshot: projection.Snapshot,
    cols: u16,
    row: *usize,
    limit: usize,
) !void {
    if (snapshot.next_cursor != null and row.* < limit) {
        try writeLine(alloc, writer, cols, row, limit, "More children available: ] next page.");
    }
    if (snapshot.page_cursor != null and row.* < limit) {
        try writeLine(alloc, writer, cols, row, limit, "Previous children available: [ previous page.");
    }
    if (snapshot.restart_required and row.* < limit) {
        try writeLine(alloc, writer, cols, row, limit, "Snapshot changed; selection was relocated from the tree root.");
    }
}

fn paintRoute(
    alloc: Allocator,
    writer: *std.Io.Writer,
    runtime: *Runtime,
    route: Route,
    main_approval: ?permission_request.PermissionRequest,
    cols: u16,
    row: *usize,
    limit: usize,
) !void {
    switch (route) {
        .main_approval => |request_id| {
            try paintMainApproval(alloc, writer, request_id, main_approval, cols, row, limit);
            return;
        },
        .archived => {
            try paintArchived(alloc, writer, runtime, cols, row, limit);
            return;
        },
        .create => {
            try paintForm(alloc, writer, runtime, null, cols, row, limit);
            return;
        },
        .attach => {
            try paintAttach(alloc, writer, runtime, cols, row, limit);
            return;
        },
        .approval => |value| if (findPendingApproval(
            runtime.snapshot,
            value.child_id,
            value.approval_id,
        )) |pending| {
            try paintPendingApproval(
                alloc,
                writer,
                runtime,
                pending,
                cols,
                row,
                limit,
            );
            return;
        } else if (runtimeApprovalFailureLine(runtime, null, value.approval_id)) |failure| {
            try writeSafeLabeledLine(alloc, writer, cols, row, limit, "Approval ID: ", value.approval_id);
            try writeLine(alloc, writer, cols, row, limit, failure);
            return;
        },
        else => {},
    }
    const node = runtime.routedNode() orelse {
        try writeLine(alloc, writer, cols, row, limit, "This child is no longer present in the latest snapshot.");
        try writeLine(alloc, writer, cols, row, limit, "Esc returns to the previous route.");
        return;
    };
    switch (route) {
        .archived => unreachable,
        .create, .attach => unreachable,
        .child => try paintChild(alloc, writer, node, cols, row, limit),
        .configure => try paintForm(alloc, writer, runtime, node, cols, row, limit),
        .actions => try paintActions(alloc, writer, runtime, node, cols, row, limit),
        .confirm_close => try paintCloseConfirmation(alloc, writer, runtime, node, cols, row, limit),
        .activity => try paintActivity(alloc, writer, runtime, node, cols, row, limit),
        .notification => |value| try paintNotification(alloc, writer, node, value.sequence, cols, row, limit),
        .approval => |value| try paintApproval(alloc, writer, runtime, node, value.approval_id, cols, row, limit),
        .main_approval => unreachable,
    }
}

fn paintMainApproval(
    alloc: Allocator,
    writer: *std.Io.Writer,
    request_id: u64,
    main_approval: ?permission_request.PermissionRequest,
    cols: u16,
    row: *usize,
    limit: usize,
) !void {
    const request = main_approval orelse {
        try writeLine(alloc, writer, cols, row, limit, "This main chat approval is no longer pending.");
        try writeLine(alloc, writer, cols, row, limit, "Esc returns to the manager list; ctrl-x closes.");
        return;
    };
    if (request.id != request_id) {
        try writeLine(alloc, writer, cols, row, limit, "This main chat approval was replaced by a newer request.");
        try writeLine(alloc, writer, cols, row, limit, "Esc returns to the manager list; ctrl-x closes.");
        return;
    }
    try writeLine(alloc, writer, cols, row, limit, "Main chat approval");
    try writeFormattedLine(alloc, writer, cols, row, limit, "Request ID: {d}", .{request.id});
    try writeSafeLabeledLine(alloc, writer, cols, row, limit, "Request: ", request.label);
    if (request.explanation) |value| try writeSafeLabeledLine(alloc, writer, cols, row, limit, "Why: ", value);
    try writeFormattedLine(alloc, writer, cols, row, limit, "Kind: {s}", .{if (request.file != null) "file" else if (request.command != null) "command" else "tool"});
    try writeLine(alloc, writer, cols, row, limit, "Read-only here; resolve approval from its owning flow.");
}

fn paintChild(
    alloc: Allocator,
    writer: *std.Io.Writer,
    node: *const projection.Node,
    cols: u16,
    row: *usize,
    limit: usize,
) !void {
    try writeSafeLabeledLine(alloc, writer, cols, row, limit, "Child: ", node.name);
    try writeSafeLabeledLine(alloc, writer, cols, row, limit, "Immutable ID: ", node.child_id);
    try writeSafeLabeledLine(alloc, writer, cols, row, limit, "Parent ID: ", node.parent_id);
    try writeFormattedLine(alloc, writer, cols, row, limit, "State: {s}  •  mode: {s}  •  generation: {d}", .{ nodeStateLabel(node), @tagName(node.mode), node.generation });
    if (node.configuration) |configuration| {
        try writeSafeLabeledLine(alloc, writer, cols, row, limit, "Model: ", configuration.model orelse "default");
        try writeFormattedLine(alloc, writer, cols, row, limit, "Effort: {s}", .{if (configuration.effort) |*effort| effort.displayLabel() else "default"});
        try writeFormattedLine(alloc, writer, cols, row, limit, "Permission mode: {s}", .{@tagName(configuration.permission_mode)});
        try paintNotifications(alloc, writer, configuration.notifications, cols, row, limit);
    } else {
        try writeLine(alloc, writer, cols, row, limit, "Configuration unavailable.");
    }
    if (node.relationship_issue) |issue| try writeFormattedLine(alloc, writer, cols, row, limit, "Relationship degraded: {s}", .{@tagName(issue)});
    if (node.stale) try writeLine(alloc, writer, cols, row, limit, "Activity cursor is stale; retained history is incomplete.");
    if (node.degraded) |reason| try writeFormattedLine(alloc, writer, cols, row, limit, "Activity degraded: {s}", .{@tagName(reason)});
    if (node.failure_reason) |reason| {
        try writeSafeLabeledLine(alloc, writer, cols, row, limit, "Latest failure: ", reason);
    }
    try writeFormattedLine(alloc, writer, cols, row, limit, "Recent activity: {d}  •  unread: {d}{s}  •  approvals: {d}", .{ node.activity.len, node.unread_count, if (node.unread_truncated) "+" else "", node.approvals.len });
    try writeLine(alloc, writer, cols, row, limit, "S Configure  •  X Actions");
    try writeLine(alloc, writer, cols, row, limit, "Press A for bounded activity or N for the latest notification/approval.");
}

fn paintForm(
    alloc: Allocator,
    writer: *std.Io.Writer,
    runtime: *Runtime,
    node: ?*const projection.Node,
    cols: u16,
    row: *usize,
    limit: usize,
) !void {
    const fields = runtime.form.fields();
    const available_rows = limit -| row.*;
    const compact = available_rows < fields.len + 6;
    if (compact) {
        try writeLine(
            alloc,
            writer,
            cols,
            row,
            limit,
            if (runtime.form.kind == .create)
                "Create persistent agent"
            else
                "Configure child",
        );
        if (runtime.form.attempt.failure) |failure| {
            try paintMutationFailure(alloc, writer, failure, cols, row, limit);
        }
        try writeLine(
            alloc,
            writer,
            cols,
            row,
            limit,
            "Duration sets the stop boundary; clear duration to disable.",
        );
        const remaining = limit -| row.*;
        const reserve_help: usize = @intFromBool(remaining > 1);
        const window = formFieldWindow(
            fields.len,
            runtime.form.field_index,
            remaining -| reserve_help,
        );
        for (fields[window.first..][0..window.count], window.first..) |field, index| {
            try paintFormField(
                alloc,
                writer,
                runtime,
                field,
                index == runtime.form.field_index,
                cols,
                row,
                limit,
            );
        }
        if (reserve_help > 0) {
            try writeLine(alloc, writer, cols, row, limit, "Tab fields  •  Space toggle  •  Enter submit");
        }
        return;
    }

    switch (runtime.form.kind) {
        .create => {
            try writeLine(alloc, writer, cols, row, limit, "Create persistent agent");
            try writeLine(alloc, writer, cols, row, limit, "Mode: persistent (manager-owned)");
            try writeSafeLabeledLine(
                alloc,
                writer,
                cols,
                row,
                limit,
                "Main-session default model: ",
                runtime.default_model orelse "unavailable",
            );
            try writeFormattedLine(
                alloc,
                writer,
                cols,
                row,
                limit,
                "Main-session default effort: {s}",
                .{runtime.default_effort.displayLabel()},
            );
        },
        .configure => {
            try writeLine(alloc, writer, cols, row, limit, "Configure child");
            if (node) |current| {
                try writeSafeLabeledLine(alloc, writer, cols, row, limit, "Effective/current name: ", current.name);
                if (current.configuration) |configuration| {
                    try writeSafeLabeledLine(
                        alloc,
                        writer,
                        cols,
                        row,
                        limit,
                        "Effective/current model: ",
                        configuration.model orelse runtime.default_model orelse "default",
                    );
                    const effective_effort = configuration.effort orelse runtime.default_effort;
                    try writeFormattedLine(
                        alloc,
                        writer,
                        cols,
                        row,
                        limit,
                        "Effective/current effort: {s}",
                        .{effective_effort.displayLabel()},
                    );
                    try writeFormattedLine(
                        alloc,
                        writer,
                        cols,
                        row,
                        limit,
                        "Effective/current permission mode: {s}",
                        .{@tagName(configuration.permission_mode)},
                    );
                }
                if (current.state == .idle) {
                    try writeLine(alloc, writer, cols, row, limit, "Pending next turn: proposed settings apply after submit.");
                } else {
                    try writeLine(alloc, writer, cols, row, limit, "Pending next turn: none; core admits configure only while idle.");
                }
            }
        },
        .none => return,
    }

    if (runtime.form.attempt.failure) |failure| {
        try paintMutationFailure(alloc, writer, failure, cols, row, limit);
    }
    try writeLine(
        alloc,
        writer,
        cols,
        row,
        limit,
        "Duration sets the stop boundary; clear duration to disable.",
    );
    for (fields, 0..) |field, index| {
        try paintFormField(
            alloc,
            writer,
            runtime,
            field,
            index == runtime.form.field_index,
            cols,
            row,
            limit,
        );
    }
    try writeLine(alloc, writer, cols, row, limit, "Tab/Arrows fields  •  Space toggles  •  Enter submit");
}

const FormFieldWindow = struct {
    first: usize,
    count: usize,
};

fn formFieldWindow(
    total: usize,
    focused: usize,
    capacity: usize,
) FormFieldWindow {
    const count = @min(total, capacity);
    if (count == 0) return .{ .first = 0, .count = 0 };
    const clamped_focus = @min(focused, total - 1);
    const first = @min(clamped_focus -| (count - 1), total - count);
    return .{ .first = first, .count = count };
}

const AttachCandidateWindow = struct {
    first: usize,
    count: usize,
};

fn attachCandidateWindow(
    total: usize,
    selected: usize,
    capacity: usize,
) AttachCandidateWindow {
    const count = @min(total, capacity);
    if (count == 0) return .{ .first = 0, .count = 0 };
    const clamped_selection = @min(selected, total - 1);
    const first = @min(clamped_selection -| (count - 1), total - count);
    return .{ .first = first, .count = count };
}

fn paintFormField(
    alloc: Allocator,
    writer: *std.Io.Writer,
    runtime: *Runtime,
    field: FormField,
    selected: bool,
    cols: u16,
    row: *usize,
    limit: usize,
) !void {
    var line: std.Io.Writer.Allocating = .init(alloc);
    defer line.deinit();
    try line.writer.writeAll(if (selected) "> " else "  ");
    try line.writer.writeAll(switch (field) {
        .name => "Name: ",
        .model => "Model: ",
        .initial_message => "Initial message: ",
        .milestones => "Milestones (comma-separated): ",
        .interval => "Report interval ms: ",
        .duration => "Report duration ms: ",
        .effort => "Effort: ",
        .permission_mode => "Permission mode: ",
        .notifications => "Custom notifications: ",
        .completed => "Notify completed: ",
        .failed => "Notify failed: ",
        .cancelled => "Notify cancelled: ",
    });
    if (runtime.form.editorForField(field)) |editor| {
        const cursor = @min(editor.edit_state.cursor, editor.edit_state.input.items.len);
        try writeSafe(&line.writer, alloc, editor.edit_state.input.items[0..cursor], formFieldMaxBytes(field));
        if (selected) try line.writer.writeAll("│");
        try writeSafe(&line.writer, alloc, editor.edit_state.input.items[cursor..], formFieldMaxBytes(field));
    } else {
        switch (field) {
            .permission_mode => try line.writer.writeAll(@tagName(runtime.form.permission_mode)),
            .notifications => try line.writer.writeAll(if (runtime.form.notifications_enabled) "custom" else "default"),
            .completed => try line.writer.writeAll(if (runtime.form.terminal.completed) "yes" else "no"),
            .failed => try line.writer.writeAll(if (runtime.form.terminal.failed) "yes" else "no"),
            .cancelled => try line.writer.writeAll(if (runtime.form.terminal.cancelled) "yes" else "no"),
            else => {},
        }
    }
    try writeLine(alloc, writer, cols, row, limit, line.written());
}

fn paintAttach(
    alloc: Allocator,
    writer: *std.Io.Writer,
    runtime: *Runtime,
    cols: u16,
    row: *usize,
    limit: usize,
) !void {
    try writeLine(alloc, writer, cols, row, limit, "Attach visible chat");
    try writeLine(alloc, writer, cols, row, limit, "Canonical profile-visible session discovery; Enter explicitly authorizes the labeled action.");
    if (runtime.attach.attempt.failure) |failure| {
        try paintMutationFailure(alloc, writer, failure, cols, row, limit);
    }
    if (runtime.attach.loading and runtime.attach.candidates.items.len == 0) {
        try writeLine(alloc, writer, cols, row, limit, "Loading visible chats…");
        return;
    }
    if (runtime.attach.candidates.items.len == 0) {
        try writeLine(alloc, writer, cols, row, limit, "No eligible visible chats on this page.");
        return;
    }
    const root_id = runtime.snapshot.?.root_id;
    const reserve_load_more: usize = @intFromBool(runtime.attach.has_more);
    const window = attachCandidateWindow(
        runtime.attach.candidates.items.len,
        runtime.attach.selected,
        (limit -| row.*) -| reserve_load_more,
    );
    for (
        runtime.attach.candidates.items[window.first..][0..window.count],
        window.first..,
    ) |candidate, index| {
        var line: std.Io.Writer.Allocating = .init(alloc);
        defer line.deinit();
        try line.writer.writeAll(if (index == runtime.attach.selected) "> " else "  ");
        var safe_title = try text_utils.encodeTerminalSafe(
            alloc,
            candidate.title orelse candidate.session_id,
            projection.max_summary_bytes,
        );
        defer safe_title.deinit(alloc);
        try line.writer.writeAll(safe_title.bytes);
        try line.writer.writeAll("  [");
        const action = @tagName(candidate.relationshipAction(root_id));
        try line.writer.writeAll(action);
        try line.writer.writeAll("]  relationship:");
        if (candidate.parent_id) |parent_id| {
            try writeSafe(&line.writer, alloc, parent_id, domain.max_operation_id_bytes);
        } else {
            try line.writer.writeAll("detached");
        }
        if (candidate.busy()) try line.writer.writeAll("  busy");
        if (!candidate.eligible) try line.writer.writeAll("  ineligible");
        if (candidate.failure) |failure| try line.writer.print("  failure:{s}", .{@tagName(failure)});
        if (display_width.visibleWidth(line.written()) <= cols) {
            try writeLine(alloc, writer, cols, row, limit, line.written());
            continue;
        }

        var compact: std.ArrayList(u8) = .empty;
        defer compact.deinit(alloc);
        try compact.appendSlice(alloc, if (index == runtime.attach.selected) "> " else "  ");
        const action_suffix_width = action.len + "  []".len;
        const title_width = @as(usize, cols) -| (2 + action_suffix_width);
        try row_text.appendSingleLineMiddleEllipsized(
            alloc,
            &compact,
            safe_title.bytes,
            title_width,
        );
        try compact.appendSlice(alloc, "  [");
        try compact.appendSlice(alloc, action);
        try compact.append(alloc, ']');
        try writeLine(alloc, writer, cols, row, limit, compact.items);
    }
    if (runtime.attach.has_more) {
        try writeLine(alloc, writer, cols, row, limit, if (runtime.attach.loading)
            "Loading more visible chats…"
        else
            "] Load 10 more visible chats");
    }
}

fn paintActions(
    alloc: Allocator,
    writer: *std.Io.Writer,
    runtime: *Runtime,
    node: *const projection.Node,
    cols: u16,
    row: *usize,
    limit: usize,
) !void {
    try writeSafeLabeledLine(alloc, writer, cols, row, limit, "Actions — ", node.name);
    try writeFormattedLine(alloc, writer, cols, row, limit, "Current state: {s}", .{nodeStateLabel(node)});
    if (runtime.lifecycle_attempt.failure) |failure| {
        try paintMutationFailure(alloc, writer, failure, cols, row, limit);
    }
    try writeLine(alloc, writer, cols, row, limit, "R Retry queued external work or resume interrupted work");
    switch (projection.cancellationCapability(node.state, node.external_busy)) {
        .available => try writeLine(alloc, writer, cols, row, limit, "C Cancel active/queued work; preserve persistent chat and return idle"),
        .external_owner => try writeLine(alloc, writer, cols, row, limit, "Cancel unavailable: another Fx process owns this child."),
        .inactive => try writeLine(alloc, writer, cols, row, limit, "Cancel unavailable: this child has no active or queued work."),
    }
    try writeLine(alloc, writer, cols, row, limit, "X Close and archive chat (separate from navigation)");
    try writeLine(alloc, writer, cols, row, limit, "Esc only navigates back; it never mutates lifecycle.");
}

fn actionsFooter(runtime: *const Runtime) []const u8 {
    const node = runtime.routedNode() orelse
        return "ctrl-x close  •  R retry/resume  •  X close/archive  •  Esc back";
    return if (projection.cancellationCapability(
        node.state,
        node.external_busy,
    ) == .available)
        "ctrl-x close  •  R retry/resume  •  C cancel  •  X close/archive  •  Esc back"
    else
        "ctrl-x close  •  R retry/resume  •  X close/archive  •  Esc back";
}

fn paintCloseConfirmation(
    alloc: Allocator,
    writer: *std.Io.Writer,
    runtime: *Runtime,
    node: *const projection.Node,
    cols: u16,
    row: *usize,
    limit: usize,
) !void {
    try writeSafeLabeledLine(alloc, writer, cols, row, limit, "Close running child — ", node.name);
    try writeLine(alloc, writer, cols, row, limit, "Closing archives this persistent chat and cancels all running or queued work.");
    if (runtime.lifecycle_attempt.failure) |failure| {
        try paintMutationFailure(alloc, writer, failure, cols, row, limit);
    }
    try writeLine(alloc, writer, cols, row, limit, "Y / Enter confirm cancellation and archive  •  N / Esc back");
}

fn paintMutationFailure(
    alloc: Allocator,
    writer: *std.Io.Writer,
    failure: MutationFailure,
    cols: u16,
    row: *usize,
    limit: usize,
) !void {
    switch (failure) {
        .validation => |validation| try writeFormattedLine(
            alloc,
            writer,
            cols,
            row,
            limit,
            "Validation: {s}",
            .{formValidationDisplay(validation)},
        ),
        .manager => |manager_failure| try writeFormattedLine(
            alloc,
            writer,
            cols,
            row,
            limit,
            "Command failed: {s}{s}",
            .{ @tagName(manager_failure.code), if (manager_failure.retryable) " (retryable)" else "" },
        ),
        .approval_stale => try writeLine(alloc, writer, cols, row, limit, "Approval was already resolved; refreshed authoritative state."),
        .approval_commit_failed => try writeLine(alloc, writer, cols, row, limit, "Approval response could not be committed; retry is safe."),
    }
}

fn runtimeApprovalFailureLine(
    runtime: *const Runtime,
    node: ?*const projection.Node,
    approval_id: []const u8,
) ?[]const u8 {
    _ = node;
    _ = approval_id;
    const failure = runtime.approval_failure orelse return null;
    return switch (failure) {
        .approval_stale => "Approval was already resolved; authoritative state is refreshing.",
        .approval_commit_failed => "Approval response failed to commit; retry is safe.",
        .validation, .manager => null,
    };
}

fn paintNotifications(
    alloc: Allocator,
    writer: *std.Io.Writer,
    notifications: domain.NotificationPolicy,
    cols: u16,
    row: *usize,
    limit: usize,
) !void {
    var terminal: std.Io.Writer.Allocating = .init(alloc);
    defer terminal.deinit();
    try terminal.writer.writeAll("Terminal: ");
    var wrote_terminal = false;
    try appendConfiguredEvent(&terminal.writer, &wrote_terminal, notifications.terminal.completed, "completed");
    try appendConfiguredEvent(&terminal.writer, &wrote_terminal, notifications.terminal.failed, "failed");
    try appendConfiguredEvent(&terminal.writer, &wrote_terminal, notifications.terminal.cancelled, "cancelled");
    if (!wrote_terminal) try terminal.writer.writeAll("none");
    try writeLine(alloc, writer, cols, row, limit, terminal.written());

    var milestones: std.Io.Writer.Allocating = .init(alloc);
    defer milestones.deinit();
    try milestones.writer.writeAll("Milestones: ");
    if (notifications.milestones.len == 0) {
        try milestones.writer.writeAll("none");
    } else {
        for (notifications.milestones, 0..) |milestone, index| {
            if (index > 0) try milestones.writer.writeAll(", ");
            try writeSafe(&milestones.writer, alloc, milestone, domain.max_name_bytes);
        }
    }
    try writeLine(alloc, writer, cols, row, limit, milestones.written());
    if (notifications.report_interval_ms) |value| {
        try writeFormattedLine(alloc, writer, cols, row, limit, "Interval: {d} ms", .{value});
    } else {
        try writeLine(alloc, writer, cols, row, limit, "Interval: off");
    }
    if (notifications.report_duration_ms) |value| {
        try writeFormattedLine(alloc, writer, cols, row, limit, "Duration: {d} ms", .{value});
    } else {
        try writeLine(alloc, writer, cols, row, limit, "Duration: unbounded");
    }

    var stops: std.Io.Writer.Allocating = .init(alloc);
    defer stops.deinit();
    try stops.writer.writeAll("Stop: ");
    if (notifications.stop_conditions.len == 0) {
        try stops.writer.writeAll("none");
    } else {
        for (notifications.stop_conditions, 0..) |condition, index| {
            if (index > 0) try stops.writer.writeAll(", ");
            try stops.writer.writeAll(@tagName(condition));
        }
    }
    try writeLine(alloc, writer, cols, row, limit, stops.written());
}

fn appendConfiguredEvent(
    writer: *std.Io.Writer,
    wrote_any: *bool,
    configured: bool,
    label: []const u8,
) !void {
    if (!configured) return;
    if (wrote_any.*) try writer.writeAll(", ");
    try writer.writeAll(label);
    wrote_any.* = true;
}

fn paintActivity(
    alloc: Allocator,
    writer: *std.Io.Writer,
    runtime: *Runtime,
    node: *const projection.Node,
    cols: u16,
    row: *usize,
    limit: usize,
) !void {
    try writeSafeLabeledLine(alloc, writer, cols, row, limit, "Activity — ", node.name);
    try writeSafeLabeledLine(alloc, writer, cols, row, limit, "Immutable ID: ", node.child_id);
    if (node.activity.len == 0) {
        try writeLine(alloc, writer, cols, row, limit, "No retained activity.");
        return;
    }
    const available = limit -| row.*;
    const start = @min(runtime.detail_scroll, node.activity.len -| @max(available, 1));
    for (node.activity[start..]) |activity| {
        if (row.* >= limit) break;
        var line: std.Io.Writer.Allocating = .init(alloc);
        defer line.deinit();
        try line.writer.print("#{d} {s}  ", .{ activity.sequence, @tagName(activity.kind) });
        try writeSafe(&line.writer, alloc, activity.summary, projection.max_summary_bytes);
        try writeLine(alloc, writer, cols, row, limit, line.written());
    }
}

fn paintNotification(
    alloc: Allocator,
    writer: *std.Io.Writer,
    node: *const projection.Node,
    sequence: u64,
    cols: u16,
    row: *usize,
    limit: usize,
) !void {
    try writeSafeLabeledLine(alloc, writer, cols, row, limit, "Notification — ", node.name);
    try writeSafeLabeledLine(alloc, writer, cols, row, limit, "Immutable ID: ", node.child_id);
    for (node.activity) |activity| {
        if (activity.sequence != sequence) continue;
        try writeFormattedLine(alloc, writer, cols, row, limit, "Sequence: {d}  •  kind: {s}", .{ activity.sequence, @tagName(activity.kind) });
        try writeSafeLabeledLine(alloc, writer, cols, row, limit, "Detail: ", activity.summary);
        return;
    }
    try writeLine(alloc, writer, cols, row, limit, "This notification is no longer retained.");
}

fn paintApproval(
    alloc: Allocator,
    writer: *std.Io.Writer,
    runtime: *const Runtime,
    node: *const projection.Node,
    approval_id: []const u8,
    cols: u16,
    row: *usize,
    limit: usize,
) !void {
    try writeSafeLabeledLine(alloc, writer, cols, row, limit, "Approval — ", node.name);
    try writeSafeLabeledLine(alloc, writer, cols, row, limit, "Immutable ID: ", node.child_id);
    for (node.approvals) |approval| {
        if (!std.mem.eql(u8, approval.id, approval_id)) continue;
        try writeSafeLabeledLine(alloc, writer, cols, row, limit, "Approval ID: ", approval.id);
        try writeFormattedLine(alloc, writer, cols, row, limit, "Kind: {s}  •  status: {s}", .{ @tagName(approval.kind), @tagName(approval.status) });
        try writeSafeLabeledLine(alloc, writer, cols, row, limit, "Request: ", approval.label);
        if (approval.explanation) |value| try writeSafeLabeledLine(alloc, writer, cols, row, limit, "Why: ", value);
        if (runtimeApprovalFailureLine(runtime, node, approval_id)) |failure| {
            try writeLine(alloc, writer, cols, row, limit, failure);
        }
        if (approval.command) |command| {
            try paintManagerCommandReview(alloc, writer, runtime, command, cols, row, limit);
        }
        try writeLine(alloc, writer, cols, row, limit, "1 Allow once  •  2 Always allow  •  3 Deny");
        return;
    }
    if (runtimeApprovalFailureLine(runtime, node, approval_id)) |failure| {
        try writeLine(alloc, writer, cols, row, limit, failure);
        return;
    }
    try writeLine(alloc, writer, cols, row, limit, "This approval is no longer pending.");
}

fn paintPendingApproval(
    alloc: Allocator,
    writer: *std.Io.Writer,
    runtime: *const Runtime,
    pending: *const projection.PendingApproval,
    cols: u16,
    row: *usize,
    limit: usize,
) !void {
    const approval = pending.request;
    const snapshot = runtime.snapshot.?;
    try writeFormattedLine(
        alloc,
        writer,
        cols,
        row,
        limit,
        "Pending approval {d} of {d}",
        .{
            snapshot.pending_approval_offset + runtime.pending_approval_selection + 1,
            snapshot.pending_approval_total,
        },
    );
    try writeSafeLabeledLine(alloc, writer, cols, row, limit, "Approval — ", pending.child_name);
    try writeSafeLabeledLine(alloc, writer, cols, row, limit, "Immutable ID: ", pending.child_id);
    try writeSafeLabeledLine(alloc, writer, cols, row, limit, "Approval ID: ", approval.id);
    try writeFormattedLine(alloc, writer, cols, row, limit, "Kind: {s}  •  status: {s}", .{ @tagName(approval.kind), @tagName(approval.status) });
    try writeSafeLabeledLine(alloc, writer, cols, row, limit, "Request: ", approval.label);
    if (approval.explanation) |value| try writeSafeLabeledLine(alloc, writer, cols, row, limit, "Why: ", value);
    if (runtimeApprovalFailureLine(runtime, null, approval.id)) |failure| {
        try writeLine(alloc, writer, cols, row, limit, failure);
    }
    if (approval.command) |command| {
        try paintManagerCommandReview(alloc, writer, runtime, command, cols, row, limit);
    }
    try writeLine(alloc, writer, cols, row, limit, "1 Allow once  •  2 Always allow  •  3 Deny");
}

fn paintManagerCommandReview(
    alloc: Allocator,
    writer: *std.Io.Writer,
    runtime: *const Runtime,
    command: []const u8,
    cols: u16,
    row: *usize,
    limit: usize,
) !void {
    if (limit -| row.* < 3) return;
    var projected = try approval_ui.projectCommandText(alloc, command);
    defer projected.deinit(alloc);

    const content_width = @as(usize, cols) -|
        display_width.visibleWidth("  $ ");
    if (content_width == 0) return;

    var counter = approval_ui.CommandSegmentIterator.initContentWidth(
        projected.bytes,
        content_width,
    );
    var total_rows: usize = 0;
    while (try counter.next()) |_| total_rows += 1;

    const command_rows = @max(@min(limit -| row.* -| 2, total_rows), 1);
    const scroll = @min(runtime.detail_scroll, total_rows -| command_rows);
    try writeFormattedLine(
        alloc,
        writer,
        cols,
        row,
        limit,
        "Command review — rows {d}–{d} of {d}",
        .{ scroll + 1, @min(scroll + command_rows, total_rows), total_rows },
    );

    var segments = approval_ui.CommandSegmentIterator.initContentWidth(
        projected.bytes,
        content_width,
    );
    var visual_row: usize = 0;
    var painted_rows: usize = 0;
    while (try segments.next()) |segment| {
        if (visual_row >= scroll and painted_rows < command_rows) {
            var line: std.Io.Writer.Allocating = .init(alloc);
            defer line.deinit();
            try line.writer.writeAll(if (visual_row == 0) "  $ " else "    ");
            try line.writer.writeAll(segment);
            try writeLine(alloc, writer, cols, row, limit, line.written());
            painted_rows += 1;
        }
        visual_row += 1;
    }
}

fn nodeStateLabel(node: *const projection.Node) []const u8 {
    if (node.external_busy) return "external busy";
    return statusLabelPublic(node.state);
}

fn writeSafeLabeledLine(
    alloc: Allocator,
    writer: *std.Io.Writer,
    cols: u16,
    row: *usize,
    limit: usize,
    label: []const u8,
    raw: []const u8,
) !void {
    var line: std.Io.Writer.Allocating = .init(alloc);
    defer line.deinit();
    try line.writer.writeAll(label);
    try writeSafe(&line.writer, alloc, raw, projection.max_summary_bytes);
    try writeLine(alloc, writer, cols, row, limit, line.written());
}

fn writeFormattedLine(
    alloc: Allocator,
    writer: *std.Io.Writer,
    cols: u16,
    row: *usize,
    limit: usize,
    comptime format: []const u8,
    args: anytype,
) !void {
    const line = try std.fmt.allocPrint(alloc, format, args);
    defer alloc.free(line);
    try writeLine(alloc, writer, cols, row, limit, line);
}

fn writeSafe(writer: *std.Io.Writer, alloc: Allocator, raw: []const u8, max_bytes: usize) !void {
    var safe = try text_utils.encodeTerminalSafe(alloc, raw, max_bytes);
    defer safe.deinit(alloc);
    try writer.writeAll(safe.bytes);
}

fn writeLine(
    alloc: Allocator,
    writer: *std.Io.Writer,
    cols: u16,
    row: *usize,
    limit: usize,
    raw: []const u8,
) !void {
    _ = alloc;
    if (row.* >= limit) return;
    const clipped = display_width.prefixByWidthIgnoringAnsi(raw, cols);
    try writer.writeAll("\x1b[2K");
    try writer.writeAll(clipped);
    try writer.writeAll(ui_render.reset_style);
    row.* += 1;
    if (row.* < limit) try writer.writeAll("\r\n");
}

fn findNodeIn(nodes: []const projection.Node, id: []const u8) ?*const projection.Node {
    for (nodes) |*node| if (std.mem.eql(u8, node.child_id, id)) return node;
    return null;
}

fn findPendingApproval(
    maybe_snapshot: ?projection.Snapshot,
    child_id: []const u8,
    approval_id: []const u8,
) ?*const projection.PendingApproval {
    const snapshot = maybe_snapshot orelse return null;
    for (snapshot.pending_approvals) |*pending| {
        if (std.mem.eql(u8, pending.child_id, child_id) and
            std.mem.eql(u8, pending.request.id, approval_id)) return pending;
    }
    return null;
}

fn approvalForRoute(
    runtime: *const Runtime,
    child_id: []const u8,
    approval_id: []const u8,
) ?*const projection.Approval {
    if (findPendingApproval(runtime.snapshot, child_id, approval_id)) |pending| {
        return &pending.request;
    }
    const snapshot = runtime.snapshot orelse return null;
    const node = findNodeIn(snapshot.nodes, child_id) orelse return null;
    for (node.approvals) |*approval| {
        if (std.mem.eql(u8, approval.id, approval_id)) return approval;
    }
    return null;
}

fn managerApprovalFooter(runtime: *const Runtime) []const u8 {
    const route = runtime.currentRoute() orelse return "ctrl-x close  •  Esc back";
    const approval = switch (route.*) {
        .approval => |value| approvalForRoute(runtime, value.child_id, value.approval_id),
        else => null,
    };
    if (approval != null and approval.?.command != null) {
        return "ctrl-x close  •  ↑↓/Pg scroll  •  ←→ request  •  [/] page  •  1 once  •  2 always  •  3 deny";
    }
    return "ctrl-x close  •  J/K request  •  [/] page  •  1 once  •  2 always  •  3 deny  •  Esc back";
}

fn indexOfNode(nodes: []const projection.Node, id: []const u8) ?usize {
    for (nodes, 0..) |node, index| if (std.mem.eql(u8, node.child_id, id)) return index;
    return null;
}

fn firstNode(nodes: []const projection.Node, archived: bool) ?*const projection.Node {
    const index = firstNodeIndex(nodes, archived) orelse return null;
    return &nodes[index];
}

fn firstNodeIndex(nodes: []const projection.Node, archived: bool) ?usize {
    for (nodes, 0..) |node, index| {
        if ((node.state == .archived) == archived) return index;
    }
    return null;
}

fn nextNodeIndex(
    nodes: []const projection.Node,
    current: usize,
    delta: i2,
    archived: bool,
) ?usize {
    if (nodes.len == 0) return null;
    var index = current;
    for (0..nodes.len) |_| {
        index = if (delta < 0)
            if (index == 0) nodes.len - 1 else index - 1
        else
            (index + 1) % nodes.len;
        if ((nodes[index].state == .archived) == archived) return index;
    }
    return null;
}

fn adjacentNodeIndex(
    nodes: []const projection.Node,
    current: usize,
    delta: i2,
    archived: bool,
) ?usize {
    if (delta < 0) {
        var index = current;
        while (index > 0) {
            index -= 1;
            if ((nodes[index].state == .archived) == archived) return index;
        }
        return null;
    }
    var index = current + 1;
    while (index < nodes.len) : (index += 1) {
        if ((nodes[index].state == .archived) == archived) return index;
    }
    return null;
}

fn lastNode(nodes: []const projection.Node, archived: bool) ?*const projection.Node {
    var index = nodes.len;
    while (index > 0) {
        index -= 1;
        if ((nodes[index].state == .archived) == archived) return &nodes[index];
    }
    return null;
}

fn terminalVisible(row: terminal_projection.Row) bool {
    return row.attention.attention == .background and
        (row.lifecycle == .starting or row.lifecycle == .running);
}

fn countVisibleTerminals(rows: []const terminal_projection.Row) usize {
    var count: usize = 0;
    for (rows) |row| if (terminalVisible(row)) {
        count += 1;
    };
    return count;
}

fn visibleTerminalIndex(
    rows: []const terminal_projection.Row,
    session_id: []const u8,
) ?usize {
    var visible_index: usize = 0;
    for (rows) |row| {
        if (!terminalVisible(row)) continue;
        if (std.mem.eql(u8, row.session_id, session_id)) return visible_index;
        visible_index += 1;
    }
    return null;
}

fn firstVisibleTerminal(
    rows: []const terminal_projection.Row,
) ?*const terminal_projection.Row {
    for (rows) |*row| if (terminalVisible(row.*)) return row;
    return null;
}

fn lastVisibleTerminal(
    rows: []const terminal_projection.Row,
) ?*const terminal_projection.Row {
    var index = rows.len;
    while (index > 0) {
        index -= 1;
        if (terminalVisible(rows[index])) return &rows[index];
    }
    return null;
}

fn findVisibleTerminal(
    rows: []const terminal_projection.Row,
    session_id: []const u8,
) ?*const terminal_projection.Row {
    for (rows) |*row| {
        if (terminalVisible(row.*) and
            std.mem.eql(u8, row.session_id, session_id)) return row;
    }
    return null;
}

fn adjacentVisibleTerminal(
    rows: []const terminal_projection.Row,
    session_id: []const u8,
    delta: i2,
) ?*const terminal_projection.Row {
    var current: ?usize = null;
    for (rows, 0..) |row, index| {
        if (std.mem.eql(u8, row.session_id, session_id)) {
            current = index;
            break;
        }
    }
    const start = current orelse return firstVisibleTerminal(rows);
    if (delta < 0) {
        var index = start;
        while (index > 0) {
            index -= 1;
            if (terminalVisible(rows[index])) return &rows[index];
        }
        return null;
    }
    var index = start + 1;
    while (index < rows.len) : (index += 1) {
        if (terminalVisible(rows[index])) return &rows[index];
    }
    return null;
}

test "terminal manager exposes only projected background rows" {
    var session_id = "terminal-row".*;
    var label = "shell".*;
    var row = terminal_projection.Row{
        .session_id = &session_id,
        .label = &label,
        .lifecycle = .running,
        .attention = .{
            .attention = .user_takeover,
            .write_lease = .human,
        },
        .backend = .native,
    };

    try std.testing.expect(!terminalVisible(row));
    row.attention = .{ .attention = .background };
    try std.testing.expect(terminalVisible(row));
    row.lifecycle = .exited;
    try std.testing.expect(!terminalVisible(row));
}

fn terminalSnapshotsEqual(
    current: ?terminal_projection.Snapshot,
    next: terminal_projection.Snapshot,
) bool {
    const existing = current orelse return false;
    if (existing.rows.len != next.rows.len) return false;
    for (existing.rows, next.rows) |left, right| {
        if (!std.mem.eql(u8, left.session_id, right.session_id) or
            !std.mem.eql(u8, left.label, right.label) or
            left.lifecycle != right.lifecycle or
            !std.meta.eql(left.attention, right.attention) or
            left.backend != right.backend)
        {
            return false;
        }
    }
    return true;
}

fn countNodes(nodes: []const projection.Node, archived: bool) usize {
    var count: usize = 0;
    for (nodes) |node| {
        if ((node.state == .archived) == archived) count += 1;
    }
    return count;
}

fn visibleIndex(
    nodes: []const projection.Node,
    raw_index: ?usize,
    archived: bool,
) usize {
    const selected = raw_index orelse return 0;
    var visible: usize = 0;
    for (nodes[0..@min(selected, nodes.len)]) |node| {
        if ((node.state == .archived) == archived) visible += 1;
    }
    return visible;
}

fn selectionViewportOffset(
    maybe_snapshot: ?projection.Snapshot,
    selected_id: ?[]const u8,
    scroll: usize,
    archived: bool,
) ?usize {
    const snapshot = maybe_snapshot orelse return null;
    const id = selected_id orelse return null;
    const raw_index = indexOfNode(snapshot.nodes, id) orelse return null;
    const selected = visibleIndex(snapshot.nodes, raw_index, archived);
    return selected -| scroll;
}

fn restoredScroll(
    nodes: []const projection.Node,
    selected_id: ?[]const u8,
    offset: ?usize,
    archived: bool,
) usize {
    const id = selected_id orelse return 0;
    const raw_index = indexOfNode(nodes, id) orelse return 0;
    const selected = visibleIndex(nodes, raw_index, archived);
    return selected -| (offset orelse return 0);
}

test "stable immutable ID selection and route survive sorting and live updates" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    try std.testing.expect(try runtime.replaceSnapshot(alloc, try testSnapshot(alloc, 1, &.{ "b", "a", "c", "d" })));
    try std.testing.expectEqual(Command.redraw, runtime.handle(alloc, .down));
    try std.testing.expectEqualStrings("a", runtime.selected_id.?);
    try std.testing.expectEqual(Command.child_changed, runtime.handle(alloc, .enter));
    const focus_before = runtime.focus;
    var live_update = try testSnapshot(alloc, 1, &.{ "b", "c", "d", "a" });
    live_update.content_hash = 2;
    live_update.nodes[0].unread_count = 1;
    try std.testing.expect(try runtime.replaceSnapshot(alloc, live_update));
    try std.testing.expectEqualStrings("a", runtime.selected_id.?);
    try std.testing.expectEqual(focus_before, runtime.focus);
    try std.testing.expectEqual(@as(usize, 1), runtime.routes.items.len);
    try std.testing.expectEqual(@as(usize, 1), runtime.snapshot.?.nodes[0].unread_count);
    try std.testing.expectEqual(@as(usize, 2), runtime.list_scroll);
}

test "escape pops one route while root escape is a no-op and ctrl x closes" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    try std.testing.expect(try runtime.replaceSnapshot(alloc, try testSnapshot(alloc, 1, &.{"child"})));
    try std.testing.expectEqual(Command.none, runtime.handle(alloc, .escape));
    try std.testing.expectEqual(Command.child_changed, runtime.handle(alloc, .enter));
    try std.testing.expectEqual(Command.child_changed, runtime.handle(alloc, .escape));
    try std.testing.expectEqual(@as(usize, 0), runtime.routes.items.len);
    try std.testing.expectEqual(Command.none, runtime.handle(alloc, .escape));
    try std.testing.expectEqual(Command.redraw, runtime.handle(alloc, .activity));
    try std.testing.expectEqual(@as(usize, 1), runtime.routes.items.len);
    try std.testing.expectEqual(Command.redraw, runtime.handle(alloc, .escape));
    try std.testing.expectEqual(Command.close_manager, runtime.handle(alloc, .toggle));
}

test "manager inventory navigates mixed immutable rows and emits terminal open intent" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    try std.testing.expect(try runtime.replaceSnapshot(
        alloc,
        try testSnapshot(alloc, 1, &.{"child"}),
    ));
    const rows = try alloc.alloc(terminal_projection.Row, 2);
    rows[0] = .{
        .session_id = try alloc.dupe(u8, "terminal-a"),
        .label = try alloc.dupe(u8, "serve"),
        .lifecycle = .running,
        .attention = .{},
        .backend = .native,
    };
    rows[1] = .{
        .session_id = try alloc.dupe(u8, "terminal-b"),
        .label = try alloc.dupe(u8, "watch"),
        .lifecycle = .starting,
        .attention = .{},
        .backend = .tmux,
    };
    try std.testing.expect(try runtime.replaceTerminalSnapshot(alloc, .{
        .alloc = alloc,
        .rows = rows,
    }));

    try std.testing.expectEqual(Command.redraw, try runtime.handle(alloc, .down));
    try std.testing.expectEqualStrings("terminal-a", runtime.selectedTerminalId().?);
    try std.testing.expectEqual(Command.redraw, try runtime.handle(alloc, .down));
    try std.testing.expectEqualStrings("terminal-b", runtime.selectedTerminalId().?);
    try std.testing.expectEqual(Command.open_terminal, try runtime.handle(alloc, .enter));
    try std.testing.expectEqual(Command.none, try runtime.handle(alloc, .escape));
    try std.testing.expectEqual(Command.close_manager, try runtime.handle(alloc, .toggle));

    const rendered = try paint(
        alloc,
        &runtime,
        .{ .rows = 12, .cols = 100, .content_bottom = 8, .divider_top_row = 9, .input_row = 10, .divider_bottom_row = 11, .hint_row = 12 },
        null,
    );
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "Background processes 2") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "› watch") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "terminal-b") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "starting") != null);
    try std.testing.expect(std.mem.find(
        u8,
        rendered,
        "↑↓ select   enter inspect   c new agent   t attach   r archives   ctrl-x close",
    ) != null);
}

test "manager inventory leads with process labels and shortens secondary IDs" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    try std.testing.expect(try runtime.replaceSnapshot(
        alloc,
        try testSnapshot(alloc, 1, &.{}),
    ));
    const rows = try alloc.alloc(terminal_projection.Row, 1);
    rows[0] = .{
        .session_id = try alloc.dupe(u8, "1786460757753-1786460757753277000-ef75d8fd94fdab1"),
        .label = try alloc.dupe(u8, "/bin/zsh"),
        .lifecycle = .running,
        .attention = .{},
        .backend = .native,
    };
    try std.testing.expect(try runtime.replaceTerminalSnapshot(alloc, .{
        .alloc = alloc,
        .rows = rows,
    }));

    const rendered = try paint(
        alloc,
        &runtime,
        .{ .rows = 12, .cols = 80, .content_bottom = 8, .divider_top_row = 9, .input_row = 10, .divider_bottom_row = 11, .hint_row = 12 },
        null,
    );
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "Agents & processes") != null);
    try std.testing.expect(std.mem.find(u8, rendered, " · 1 active") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "Agents 0") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "Background processes 1") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "› /bin/zsh") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "178646…fdab1") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "running") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "No background processes") == null);
    try std.testing.expect(std.mem.find(u8, rendered, "ctrl-x close") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "Ctrl-X") == null);
}

test "manager root footers preserve the close shortcut at responsive boundaries" {
    const non_paginated_widths = [_]u16{ 12, 63, 64, 71, 72, 77, 78 };
    for (non_paginated_widths) |width| {
        const footer = rootFooter(width, false);
        try std.testing.expect(display_width.visibleWidth(footer) <= width);
        try std.testing.expect(std.mem.find(u8, footer, "ctrl-x close") != null);
    }
    try std.testing.expectEqualStrings(
        "↑↓ select   enter inspect   ctrl-x close",
        rootFooter(64, false),
    );
    try std.testing.expectEqualStrings(
        "↑↓ select   enter inspect   ctrl-x close",
        rootFooter(71, false),
    );
    try std.testing.expectEqualStrings(
        "↑↓ select   enter inspect   c new   t attach   r archives   ctrl-x close",
        rootFooter(72, false),
    );

    const paginated_widths = [_]u16{ 12, 23, 24 };
    for (paginated_widths) |width| {
        const footer = rootFooter(width, true);
        try std.testing.expect(display_width.visibleWidth(footer) <= width);
        try std.testing.expect(std.mem.find(u8, footer, "ctrl-x close") != null);
    }
    try std.testing.expectEqualStrings("ctrl-x close", rootFooter(23, true));
    try std.testing.expectEqualStrings("ctrl-x close   [ ] pages", rootFooter(24, true));
}

test "manager title omits an incomplete active total while agents are paginated" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    var snapshot = try testSnapshot(alloc, 1, &.{});
    snapshot.next_cursor = try alloc.dupe(u8, "next-page");
    try std.testing.expect(try runtime.replaceSnapshot(alloc, snapshot));
    try std.testing.expect(try runtime.replaceTerminalSnapshot(alloc, .{
        .alloc = alloc,
        .rows = try alloc.alloc(terminal_projection.Row, 0),
    }));

    const rendered = try paint(
        alloc,
        &runtime,
        .{ .rows = 8, .cols = 80, .content_bottom = 4, .divider_top_row = 5, .input_row = 6, .divider_bottom_row = 7, .hint_row = 8 },
        null,
    );
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "Agents & processes") != null);
    try std.testing.expect(std.mem.find(u8, rendered, " · 0 active") == null);
}

test "manager title requires complete agent and process projections for active total" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    try std.testing.expect(try runtime.replaceSnapshot(
        alloc,
        try testSnapshot(alloc, 1, &.{"worker"}),
    ));

    const missing_processes = try paint(
        alloc,
        &runtime,
        .{ .rows = 8, .cols = 80, .content_bottom = 4, .divider_top_row = 5, .input_row = 6, .divider_bottom_row = 7, .hint_row = 8 },
        null,
    );
    defer alloc.free(missing_processes);
    try std.testing.expect(std.mem.find(u8, missing_processes, " active") == null);

    const rows = try alloc.alloc(terminal_projection.Row, 1);
    rows[0] = .{
        .session_id = try alloc.dupe(u8, "terminal-a"),
        .label = try alloc.dupe(u8, "serve"),
        .lifecycle = .running,
        .attention = .{},
        .backend = .native,
    };
    try std.testing.expect(try runtime.replaceTerminalSnapshot(alloc, .{
        .alloc = alloc,
        .rows = rows,
    }));
    const complete = try paint(
        alloc,
        &runtime,
        .{ .rows = 8, .cols = 80, .content_bottom = 4, .divider_top_row = 5, .input_row = 6, .divider_bottom_row = 7, .hint_row = 8 },
        null,
    );
    defer alloc.free(complete);
    try std.testing.expect(std.mem.find(u8, complete, " · 2 active") != null);

    runtime.setDegraded(alloc, .store_failure);
    const degraded = try paint(
        alloc,
        &runtime,
        .{ .rows = 8, .cols = 80, .content_bottom = 4, .divider_top_row = 5, .input_row = 6, .divider_bottom_row = 7, .hint_row = 8 },
        null,
    );
    defer alloc.free(degraded);
    try std.testing.expect(std.mem.find(u8, degraded, " active") == null);
}

test "manager rows align status after odd-budget wide glyph ellipsis" {
    const alloc = std.testing.allocator;

    var terminal_row: std.ArrayList(u8) = .empty;
    defer terminal_row.deinit(alloc);
    const terminal_label = try alloc.dupe(u8, "界界");
    defer alloc.free(terminal_label);
    const terminal_id = try alloc.dupe(u8, "界界");
    defer alloc.free(terminal_id);
    try composeTerminalRow(alloc, &terminal_row, .{
        .session_id = terminal_id,
        .label = terminal_label,
        .lifecycle = .running,
        .attention = .{},
        .backend = .native,
    }, false, 15);
    try std.testing.expectEqual(
        @as(usize, 14),
        display_width.visibleWidthIgnoringAnsi(terminal_row.items),
    );
    try std.testing.expect(std.mem.find(u8, terminal_row.items, "…") != null);

    var snapshot = try testSnapshot(alloc, 1, &.{"界界"});
    defer snapshot.deinit(alloc);
    var node_row: std.ArrayList(u8) = .empty;
    defer node_row.deinit(alloc);
    try composeNodeRow(alloc, &node_row, &snapshot.nodes[0], false, 17);
    try std.testing.expectEqual(
        @as(usize, 16),
        display_width.visibleWidthIgnoringAnsi(node_row.items),
    );
    try std.testing.expect(std.mem.find(u8, node_row.items, "…") != null);
}

test "manager inventory keeps the selected terminal visible in a paginated viewport" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);

    var snapshot = try testSnapshot(
        alloc,
        1,
        &.{ "child-0", "child-1", "child-2", "child-3", "child-4", "child-5" },
    );
    snapshot.next_cursor = try alloc.dupe(u8, "page-006");
    try std.testing.expect(try runtime.replaceSnapshot(alloc, snapshot));

    const rows = try alloc.alloc(terminal_projection.Row, 3);
    rows[0] = .{
        .session_id = try alloc.dupe(u8, "terminal-a"),
        .label = try alloc.dupe(u8, "serve"),
        .lifecycle = .running,
        .attention = .{},
        .backend = .native,
    };
    rows[1] = .{
        .session_id = try alloc.dupe(u8, "terminal-b"),
        .label = try alloc.dupe(u8, "watch"),
        .lifecycle = .running,
        .attention = .{},
        .backend = .tmux,
    };
    rows[2] = .{
        .session_id = try alloc.dupe(u8, "terminal-c"),
        .label = try alloc.dupe(u8, "tests"),
        .lifecycle = .starting,
        .attention = .{},
        .backend = .native,
    };
    try std.testing.expect(try runtime.replaceTerminalSnapshot(alloc, .{
        .alloc = alloc,
        .rows = rows,
    }));

    for (0..8) |_| try std.testing.expectEqual(
        Command.redraw,
        try runtime.handle(alloc, .down),
    );
    try std.testing.expectEqualStrings("terminal-c", runtime.selectedTerminalId().?);
    try std.testing.expectEqual(Command.open_terminal, try runtime.handle(alloc, .enter));

    const rendered = try paint(
        alloc,
        &runtime,
        .{ .rows = 9, .cols = 100, .content_bottom = 7, .divider_top_row = 8, .input_row = 8, .divider_bottom_row = 8, .hint_row = 9 },
        null,
    );
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "› tests") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "terminal-c") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "starting") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "More children available: ] next page.") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "ctrl-x close") != null);
    try std.testing.expect(std.mem.find(u8, rendered, " active") == null);
}

test "renderer covers loading empty populated interrupted archived degraded unicode and narrow dimensions" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    const layout = types.Layout{ .rows = 8, .cols = 48, .content_bottom = 4, .divider_top_row = 5, .input_row = 6, .divider_bottom_row = 7, .hint_row = 8 };
    const loading = try paint(alloc, &runtime, layout, null);
    defer alloc.free(loading);
    try std.testing.expect(std.mem.find(u8, loading, "Agents & processes") != null);
    try std.testing.expect(std.mem.find(u8, loading, "Loading agents") != null);
    try std.testing.expect(std.mem.find(u8, loading, "last lines:") == null);

    try std.testing.expect(try runtime.replaceSnapshot(alloc, try testSnapshot(alloc, 1, &.{})));
    const empty = try paint(alloc, &runtime, layout, null);
    defer alloc.free(empty);
    try std.testing.expect(std.mem.find(u8, empty, "No active agents") != null);

    var populated = try testSnapshot(alloc, 2, &.{ "worker-🦎", "sleeping-child" });
    populated.nodes[0].state = .interrupted;
    populated.nodes[1].state = .archived;
    alloc.free(populated.diagnostics);
    populated.diagnostics = try alloc.alloc(manager_mod.TreeDiagnostic, 1);
    populated.diagnostics[0] = .{
        .session_id = try alloc.dupe(u8, "missing-child"),
        .code = .session_unavailable,
    };
    try std.testing.expect(try runtime.replaceSnapshot(alloc, populated));
    const tree = try paint(alloc, &runtime, layout, .{ .id = 9, .label = "main approval" });
    defer alloc.free(tree);
    try std.testing.expect(std.mem.find(u8, tree, "interrupted") != null);
    try std.testing.expect(std.mem.find(u8, tree, "sleeping-child") == null);
    try std.testing.expect(std.mem.find(u8, tree, "Degraded tree data") != null);
    try std.testing.expect(std.mem.find(u8, tree, "main chat approval pending") != null);

    try std.testing.expectEqual(Command.redraw, try runtime.handle(alloc, .archived));
    const archived = try paint(alloc, &runtime, layout, null);
    defer alloc.free(archived);
    try std.testing.expect(std.mem.find(u8, archived, "Archived subagents") != null);
    try std.testing.expect(std.mem.find(u8, archived, "sleeping-child") != null);

    runtime.setDegraded(alloc, .store_failure);
    const degraded = try paint(alloc, &runtime, layout, null);
    defer alloc.free(degraded);
    try std.testing.expect(std.mem.find(u8, degraded, "Manager degraded") != null);
    const narrow = try paint(alloc, &runtime, .{ .rows = 1, .cols = 4, .content_bottom = 0, .divider_top_row = 0, .input_row = 1, .divider_bottom_row = 1, .hint_row = 1 }, null);
    defer alloc.free(narrow);
    try std.testing.expect(narrow.len > 0);
    const zero = try paint(alloc, &runtime, .{ .rows = 0, .cols = 0, .content_bottom = 0, .divider_top_row = 0, .input_row = 0, .divider_bottom_row = 0, .hint_row = 0 }, null);
    defer alloc.free(zero);
    try std.testing.expectEqual(@as(usize, 0), zero.len);
}

test "narrow configure form always renders its focused control" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);

    var snapshot = try testSnapshot(alloc, 1, &.{"child"});
    snapshot.nodes[0].state = .idle;
    snapshot.nodes[0].configuration = try testConfiguration(
        alloc,
        snapshot.nodes[0].name,
    );
    try std.testing.expect(try runtime.replaceSnapshot(alloc, snapshot));
    try std.testing.expectEqual(
        Command.child_changed,
        try runtime.handle(alloc, .enter),
    );
    try runtime.installChildChat(
        alloc,
        try testChildChat(alloc, runtime.routedNode().?),
        false,
        true,
    );
    try std.testing.expectEqual(
        Command.redraw,
        try runtime.handleByte(alloc, '\t', null),
    );
    try std.testing.expectEqual(
        Command.redraw,
        try runtime.handleByte(alloc, 's', null),
    );
    const labels = [_][]const u8{
        "> Name:",
        "> Model:",
        "> Milestones",
        "> Report interval",
        "> Report duration",
        "> Effort:",
        "> Permission mode:",
        "> Notify completed:",
        "> Notify failed:",
        "> Notify cancelled:",
    };
    for (labels, 0..) |label, index| {
        runtime.form.field_index = index;
        const rendered = try paint(
            alloc,
            &runtime,
            .{
                .rows = 12,
                .cols = 60,
                .content_bottom = 8,
                .divider_top_row = 9,
                .input_row = 10,
                .divider_bottom_row = 11,
                .hint_row = 12,
            },
            null,
        );
        defer alloc.free(rendered);
        try std.testing.expect(std.mem.find(u8, rendered, label) != null);
    }
}

test "manager root advertises create and attach routes in the compact footer" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    try std.testing.expect(try runtime.replaceSnapshot(alloc, try testSnapshot(alloc, 1, &.{})));

    const rendered = try paint(
        alloc,
        &runtime,
        .{ .rows = 16, .cols = 80, .content_bottom = 12, .divider_top_row = 13, .input_row = 14, .divider_bottom_row = 15, .hint_row = 16 },
        null,
    );
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "c new agent") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "t attach") != null);
}

test "selected child advertises configure and explicit lifecycle routes" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    try std.testing.expect(try runtime.replaceSnapshot(alloc, try testSnapshot(alloc, 1, &.{"child"})));
    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .enter));
    try runtime.installChildChat(alloc, try testChildChat(alloc, runtime.routedNode().?), false, true);

    const rendered = try paint(
        alloc,
        &runtime,
        .{ .rows = 18, .cols = 80, .content_bottom = 14, .divider_top_row = 15, .input_row = 16, .divider_bottom_row = 17, .hint_row = 18 },
        null,
    );
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "S Configure") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "X Actions") != null);
}

test "child approval route offers authoritative once always and deny responses" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    var snapshot = try testSnapshot(alloc, 1, &.{"child"});
    alloc.free(snapshot.nodes[0].approvals);
    snapshot.nodes[0].approvals = try alloc.alloc(projection.Approval, 1);
    snapshot.nodes[0].approvals[0] = .{
        .id = try alloc.dupe(u8, "approval-exact-id"),
        .kind = .tool,
        .status = .pending,
        .label = try alloc.dupe(u8, "read outside workspace"),
        .explanation = try alloc.dupe(u8, "needs approval"),
    };
    try std.testing.expect(try runtime.replaceSnapshot(alloc, snapshot));
    try std.testing.expectEqual(Command.redraw, try runtime.handle(alloc, .notifications));

    const rendered = try paint(
        alloc,
        &runtime,
        .{ .rows = 16, .cols = 80, .content_bottom = 12, .divider_top_row = 13, .input_row = 14, .divider_bottom_row = 15, .hint_row = 16 },
        null,
    );
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "Approval ID: approval-exact-id") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "1 Allow once") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "2 Always allow") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "3 Deny") != null);
}

test "child command approval route exposes complete scroll review and resolves" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    var snapshot = try testSnapshot(alloc, 1, &.{"child"});
    alloc.free(snapshot.nodes[0].approvals);
    snapshot.nodes[0].approvals = try alloc.alloc(projection.Approval, 1);
    const command = try std.fmt.allocPrint(
        alloc,
        "# terminal.exec profile=user shell=/bin/zsh\n{s}COMMAND_TAIL_VISIBLE",
        .{"printf review-line\\n\n" ** 20},
    );
    snapshot.nodes[0].approvals[0] = .{
        .id = try alloc.dupe(u8, "command-approval-id"),
        .kind = .tool,
        .status = .pending,
        .label = try alloc.dupe(u8, "terminal.exec printf ok"),
        .explanation = null,
        .command = command,
    };
    try std.testing.expect(try runtime.replaceSnapshot(alloc, snapshot));
    try std.testing.expectEqual(Command.redraw, try runtime.handle(alloc, .notifications));

    const rendered = try paint(
        alloc,
        &runtime,
        .{ .rows = 18, .cols = 100, .content_bottom = 14, .divider_top_row = 15, .input_row = 16, .divider_bottom_row = 17, .hint_row = 18 },
        null,
    );
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "profile=user shell=/bin/zsh") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "Command review — rows 1–") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "1 Allow once") != null);
    try std.testing.expectEqual(Command.redraw, try runtime.handle(alloc, .page_down));
    try std.testing.expectEqual(Command.redraw, try runtime.handle(alloc, .page_down));
    try std.testing.expectEqual(Command.redraw, try runtime.handle(alloc, .page_down));
    const scrolled = try paint(
        alloc,
        &runtime,
        .{ .rows = 18, .cols = 100, .content_bottom = 14, .divider_top_row = 15, .input_row = 16, .divider_bottom_row = 17, .hint_row = 18 },
        null,
    );
    defer alloc.free(scrolled);
    try std.testing.expect(std.mem.find(u8, scrolled, "COMMAND_TAIL_VISIBLE") != null);
    try std.testing.expectEqual(Command.resolve_child_approval, try runtime.handleByte(alloc, '2', null));
    try std.testing.expectEqual(
        types.ToolPermissionDecision.always,
        runtime.prepareApprovalResolution().?.decision,
    );
}

test "pending command approval route shows profile and keeps authoritative decisions" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    var snapshot = try pendingApprovalTestSnapshot(alloc, "pending-command-id");
    snapshot.pending_approvals[0].request.command = try alloc.dupe(
        u8,
        "# terminal.exec profile=clean shell=/bin/bash\nprintf ok",
    );
    try std.testing.expect(try runtime.replaceSnapshot(alloc, snapshot));
    try std.testing.expectEqual(Command.redraw, try runtime.handle(alloc, .notifications));

    const rendered = try paint(
        alloc,
        &runtime,
        .{ .rows = 18, .cols = 100, .content_bottom = 14, .divider_top_row = 15, .input_row = 16, .divider_bottom_row = 17, .hint_row = 18 },
        null,
    );
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "profile=clean shell=/bin/bash") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "printf ok") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "1 Allow once") != null);
    try std.testing.expectEqual(Command.resolve_child_approval, try runtime.handleByte(alloc, '1', null));
    try std.testing.expectEqual(
        types.ToolPermissionDecision.once,
        runtime.prepareApprovalResolution().?.decision,
    );
}

test "archived child advertises typed reopen instead of navigation side effects" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    var snapshot = try testSnapshot(alloc, 1, &.{"archived-child"});
    snapshot.nodes[0].state = .archived;
    try std.testing.expect(try runtime.replaceSnapshot(alloc, snapshot));
    try std.testing.expectEqual(Command.redraw, try runtime.handle(alloc, .archived));

    const rendered = try paint(
        alloc,
        &runtime,
        .{ .rows = 14, .cols = 80, .content_bottom = 10, .divider_top_row = 11, .input_row = 12, .divider_bottom_row = 13, .hint_row = 14 },
        null,
    );
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "O Reopen selected child") != null);
}

test "create form requires a name defaults from main and retains a retry-stable operation" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    try runtime.setDefaults(alloc, "openai/gpt-5", types.ReasoningEffort.literal("high"));
    try std.testing.expect(try runtime.replaceSnapshot(alloc, try testSnapshot(alloc, 1, &.{})));
    try std.testing.expectEqual(Command.redraw, try runtime.handleByte(alloc, 'c', null));
    try std.testing.expectEqual(Focus.create_form, runtime.focus);
    try std.testing.expect((try runtime.prepareManagerMutation(alloc, 10)) == null);
    try std.testing.expectEqual(
        FormValidationFailure.missing_name,
        runtime.form.attempt.failure.?.validation,
    );

    try runtime.form.replaceEditor(alloc, .name, "persistent worker");
    runtime.form.edit(alloc);
    var first = (try runtime.prepareManagerMutation(alloc, 20)).?;
    defer first.deinit(alloc);
    try std.testing.expect(first.command == .create);
    try std.testing.expectEqual(domain.Mode.persistent, first.command.create.mode);
    try std.testing.expectEqualStrings("persistent worker", first.command.create.configuration.name);
    try std.testing.expectEqualStrings("openai/gpt-5", first.command.create.configuration.model.?);
    try std.testing.expectEqual(types.ReasoningEffort.literal("high"), first.command.create.configuration.effort.?);
    try std.testing.expectEqual(types.PermissionMode.yolo, first.command.create.configuration.permission_mode);
    try std.testing.expect(first.command.create.prompt == null);
    const operation_id = try alloc.dupe(u8, first.invocation_id);
    defer alloc.free(operation_id);

    runtime.mutationRejected(alloc, .{ .code = .control_lock_busy, .retryable = true });
    var retry = (try runtime.prepareManagerMutation(alloc, 30)).?;
    defer retry.deinit(alloc);
    try std.testing.expectEqualStrings(operation_id, retry.invocation_id);
    try std.testing.expectEqualStrings("persistent worker", runtime.form.editors[0].edit_state.input.items);
    try std.testing.expectEqualStrings("openai/gpt-5", runtime.form.editors[1].edit_state.input.items);
}

test "create form owns optional initial message and complete notification policy" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    try runtime.setDefaults(alloc, "default/model", types.ReasoningEffort.literal("medium"));
    try std.testing.expect(try runtime.replaceSnapshot(alloc, try testSnapshot(alloc, 1, &.{})));
    _ = try runtime.handleByte(alloc, 'c', null);
    try runtime.form.replaceEditor(alloc, .name, "notifier");
    try runtime.form.replaceEditor(alloc, .model, "custom/model");
    try runtime.form.replaceEditor(alloc, .initial_message, "start with unicode λ");
    try runtime.form.replaceEditor(alloc, .milestones, "halfway, verified");
    try runtime.form.replaceEditor(alloc, .interval, "5000");
    try runtime.form.replaceEditor(alloc, .duration, "60000");
    try runtime.form.replaceEditor(alloc, .effort, "xhigh");
    runtime.form.permission_mode = .ask;
    runtime.form.notifications_enabled = true;
    runtime.form.terminal = .{ .completed = true, .failed = false, .cancelled = true };
    runtime.form.edit(alloc);

    var prepared = (try runtime.prepareManagerMutation(alloc, 40)).?;
    defer prepared.deinit(alloc);
    const create = prepared.command.create;
    try std.testing.expectEqualStrings("start with unicode λ", create.prompt.?);
    try std.testing.expectEqualStrings("custom/model", create.configuration.model.?);
    try std.testing.expectEqual(types.ReasoningEffort.literal("xhigh"), create.configuration.effort.?);
    try std.testing.expectEqual(types.PermissionMode.ask, create.configuration.permission_mode);
    try std.testing.expectEqual(@as(usize, 2), create.configuration.notifications.milestones.len);
    try std.testing.expectEqual(@as(?u64, 5000), create.configuration.notifications.report_interval_ms);
    try std.testing.expectEqual(@as(?u64, 60000), create.configuration.notifications.report_duration_ms);
    try std.testing.expect(!create.configuration.notifications.terminal.failed);
    try std.testing.expect(hasStopCondition(create.configuration.notifications.stop_conditions, .duration_elapsed));
}

test "manager form exposes duration as the only stop boundary" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    try runtime.setDefaults(alloc, "default/model", types.ReasoningEffort.literal("medium"));
    try std.testing.expect(try runtime.replaceSnapshot(alloc, try testSnapshot(alloc, 1, &.{})));
    try std.testing.expectEqual(Command.redraw, try runtime.handleByte(alloc, 'c', null));
    try runtime.form.replaceEditor(alloc, .name, "duration-worker");
    try runtime.form.replaceEditor(alloc, .interval, "100");
    try runtime.form.replaceEditor(alloc, .duration, "900");
    runtime.form.notifications_enabled = true;
    runtime.form.edit(alloc);

    const full = try paint(
        alloc,
        &runtime,
        .{ .rows = 28, .cols = 80, .content_bottom = 24, .divider_top_row = 25, .input_row = 26, .divider_bottom_row = 27, .hint_row = 28 },
        null,
    );
    defer alloc.free(full);
    try std.testing.expect(std.mem.find(u8, full, "Duration sets the stop boundary; clear duration to disable.") != null);
    try std.testing.expect(std.mem.find(u8, full, "Stop after duration:") == null);

    const compact = try paint(
        alloc,
        &runtime,
        .{ .rows = 12, .cols = 60, .content_bottom = 8, .divider_top_row = 9, .input_row = 10, .divider_bottom_row = 11, .hint_row = 12 },
        null,
    );
    defer alloc.free(compact);
    try std.testing.expect(std.mem.find(u8, compact, "Duration sets the stop boundary; clear duration to disable.") != null);
    try std.testing.expect(std.mem.find(u8, compact, "Stop after duration:") == null);

    var with_duration = (try runtime.prepareManagerMutation(alloc, 40)).?;
    defer with_duration.deinit(alloc);
    try std.testing.expect(hasStopCondition(
        with_duration.command.create.configuration.notifications.stop_conditions,
        .duration_elapsed,
    ));

    try runtime.form.replaceEditor(alloc, .duration, "");
    runtime.form.edit(alloc);
    var without_duration = (try runtime.prepareManagerMutation(alloc, 50)).?;
    defer without_duration.deinit(alloc);
    try std.testing.expect(!hasStopCondition(
        without_duration.command.create.configuration.notifications.stop_conditions,
        .duration_elapsed,
    ));
}

test "manager form retains owned drafts across validation io conflict and allocation failures" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    try runtime.setDefaults(alloc, "default/model", types.ReasoningEffort.literal("medium"));
    try std.testing.expect(try runtime.replaceSnapshot(alloc, try testSnapshot(alloc, 1, &.{})));
    _ = try runtime.handleByte(alloc, 'c', null);
    try runtime.form.replaceEditor(alloc, .name, "retry draft λ");
    try runtime.form.replaceEditor(alloc, .interval, "not-a-number");
    runtime.form.edit(alloc);
    try std.testing.expect((try runtime.prepareManagerMutation(alloc, 10)) == null);
    try std.testing.expectEqualStrings("retry draft λ", runtime.form.editors[0].edit_state.input.items);
    try std.testing.expectEqual(FormValidationFailure.invalid_number, runtime.form.attempt.failure.?.validation);

    try runtime.form.replaceEditor(alloc, .interval, "1000");
    runtime.form.edit(alloc);
    var first = (try runtime.prepareManagerMutation(alloc, 20)).?;
    defer first.deinit(alloc);
    const first_id = try alloc.dupe(u8, first.invocation_id);
    defer alloc.free(first_id);
    try std.testing.expect(runtime.assignMutationIdentity(first.invocation_id, 41));
    runtime.mutationRejected(alloc, .{ .code = .store_failure, .retryable = true });
    var io_retry = (try runtime.prepareManagerMutation(alloc, 30)).?;
    defer io_retry.deinit(alloc);
    try std.testing.expectEqualStrings(first_id, io_retry.invocation_id);
    try std.testing.expectEqual(@as(u64, 41), io_retry.identity_epoch);
    try std.testing.expectEqualStrings("retry draft λ", runtime.form.editors[0].edit_state.input.items);

    runtime.mutationRejected(alloc, .{ .code = .operation_conflict });
    var conflict_retry = (try runtime.prepareManagerMutation(alloc, 40)).?;
    defer conflict_retry.deinit(alloc);
    try std.testing.expect(!std.mem.eql(u8, first_id, conflict_retry.invocation_id));
    try std.testing.expectEqual(@as(u64, 0), conflict_retry.identity_epoch);
    try std.testing.expectEqualStrings("retry draft λ", runtime.form.editors[0].edit_state.input.items);

    const conflict_id = try alloc.dupe(u8, conflict_retry.invocation_id);
    defer alloc.free(conflict_id);
    try std.testing.expect(runtime.assignMutationIdentity(
        conflict_retry.invocation_id,
        42,
    ));
    runtime.mutationRejected(alloc, .{ .code = .child_unavailable });
    var terminal_retry = (try runtime.prepareManagerMutation(alloc, 45)).?;
    defer terminal_retry.deinit(alloc);
    try std.testing.expect(!std.mem.eql(
        u8,
        conflict_id,
        terminal_retry.invocation_id,
    ));
    try std.testing.expectEqual(@as(u64, 0), terminal_retry.identity_epoch);
    try std.testing.expectEqualStrings(
        "retry draft λ",
        runtime.form.editors[0].edit_state.input.items,
    );

    runtime.form.edit(alloc);
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expect((try runtime.prepareManagerMutation(failing.allocator(), 50)) == null);
    try std.testing.expectEqualStrings("retry draft λ", runtime.form.editors[0].edit_state.input.items);
    try std.testing.expectEqual(FormValidationFailure.allocation_failure, runtime.form.attempt.failure.?.validation);
}

test "attach route derives attach detach and reparent from canonical relationships" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    try std.testing.expect(try runtime.replaceSnapshot(alloc, try testSnapshot(alloc, 1, &.{})));
    try std.testing.expectEqual(Command.load_attach_candidates, try runtime.handleByte(alloc, 't', null));
    try runtime.installAttachPage(alloc, try testAttachPage(alloc, &.{
        .{ .id = "detached", .parent_id = null, .generation = 0 },
        .{ .id = "ours", .parent_id = "root", .generation = 4 },
        .{ .id = "theirs", .parent_id = "other-parent", .generation = 7 },
    }), false);

    var attach = (try runtime.prepareManagerMutation(alloc, 10)).?;
    defer attach.deinit(alloc);
    try std.testing.expectEqual(domain.RelationshipAction.attach, attach.command.relationship.action);
    try std.testing.expectEqual(@as(?u64, 0), attach.expected_generation);

    try std.testing.expectEqual(Command.redraw, try runtime.handle(alloc, .down));
    var detach = (try runtime.prepareManagerMutation(alloc, 20)).?;
    defer detach.deinit(alloc);
    try std.testing.expectEqual(domain.RelationshipAction.detach, detach.command.relationship.action);
    try std.testing.expectEqual(@as(?u64, 4), detach.expected_generation);

    try std.testing.expectEqual(Command.redraw, try runtime.handle(alloc, .down));
    var reparent = (try runtime.prepareManagerMutation(alloc, 30)).?;
    defer reparent.deinit(alloc);
    try std.testing.expectEqual(domain.RelationshipAction.reparent, reparent.command.relationship.action);
    try std.testing.expectEqualStrings("root", reparent.command.relationship.parent_id.?);
    try std.testing.expectEqual(@as(?u64, 7), reparent.expected_generation);
}

test "attach picker keeps the selected candidate and load more control visible in short layouts" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    try std.testing.expect(try runtime.replaceSnapshot(alloc, try testSnapshot(alloc, 1, &.{})));
    try std.testing.expectEqual(Command.load_attach_candidates, try runtime.handleByte(alloc, 't', null));
    var page = try testAttachPage(alloc, &.{
        .{ .id = "candidate-00", .parent_id = null, .generation = 0 },
        .{ .id = "candidate-01", .parent_id = null, .generation = 0 },
        .{ .id = "candidate-02", .parent_id = null, .generation = 0 },
        .{ .id = "candidate-03", .parent_id = null, .generation = 0 },
        .{ .id = "candidate-04", .parent_id = null, .generation = 0 },
        .{ .id = "candidate-05", .parent_id = null, .generation = 0 },
        .{ .id = "candidate-06", .parent_id = null, .generation = 0 },
        .{ .id = "candidate-07", .parent_id = null, .generation = 0 },
        .{ .id = "candidate-08", .parent_id = null, .generation = 0 },
        .{ .id = "candidate-09", .parent_id = null, .generation = 0 },
    });
    page.has_more = true;
    try runtime.installAttachPage(alloc, page, false);

    for (0..8) |_| try std.testing.expectEqual(Command.redraw, try runtime.handle(alloc, .down));
    const selected_tail = try paint(
        alloc,
        &runtime,
        .{ .rows = 12, .cols = 74, .content_bottom = 8, .divider_top_row = 9, .input_row = 10, .divider_bottom_row = 11, .hint_row = 12 },
        null,
    );
    defer alloc.free(selected_tail);
    try std.testing.expect(std.mem.find(u8, selected_tail, "> candidate-08  [attach]") != null);
    try std.testing.expect(std.mem.find(u8, selected_tail, "] Load 10 more visible chats") != null);
    try std.testing.expect(std.mem.find(u8, selected_tail, "candidate-00") == null);

    for (0..2) |_| try std.testing.expectEqual(Command.redraw, try runtime.handle(alloc, .down));
    const wrapped = try paint(
        alloc,
        &runtime,
        .{ .rows = 12, .cols = 74, .content_bottom = 8, .divider_top_row = 9, .input_row = 10, .divider_bottom_row = 11, .hint_row = 12 },
        null,
    );
    defer alloc.free(wrapped);
    try std.testing.expect(std.mem.find(u8, wrapped, "> candidate-00  [attach]") != null);
    try std.testing.expect(std.mem.find(u8, wrapped, "] Load 10 more visible chats") != null);
}

test "attach picker keeps shared-prefix targets and relationship actions visible when narrow" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    try std.testing.expect(try runtime.replaceSnapshot(alloc, try testSnapshot(alloc, 1, &.{})));
    try std.testing.expectEqual(Command.load_attach_candidates, try runtime.handleByte(alloc, 't', null));
    try runtime.installAttachPage(alloc, try testAttachPage(alloc, &.{
        .{
            .id = "alpha-id",
            .title = "Shared relationship authorization candidate alpha",
            .parent_id = null,
            .generation = 0,
        },
        .{
            .id = "beta-id",
            .title = "Shared relationship authorization candidate beta",
            .parent_id = "root",
            .generation = 3,
        },
        .{
            .id = "gamma-id",
            .title = "Shared relationship \x1b authorization candidate gamma 🦎",
            .parent_id = "other-parent",
            .generation = 7,
        },
    }), false);

    const narrow = try paint(
        alloc,
        &runtime,
        .{ .rows = 10, .cols = 40, .content_bottom = 6, .divider_top_row = 7, .input_row = 8, .divider_bottom_row = 9, .hint_row = 10 },
        null,
    );
    defer alloc.free(narrow);
    try std.testing.expect(std.mem.find(u8, narrow, "alpha  [attach]") != null);
    try std.testing.expect(std.mem.find(u8, narrow, "beta  [detach]") != null);
    try std.testing.expect(std.mem.find(u8, narrow, "gamma 🦎  [reparent]") != null);
    try std.testing.expect(std.mem.find(u8, narrow, "\x1b authorization") == null);

    const wide = try paint(
        alloc,
        &runtime,
        .{ .rows = 10, .cols = 100, .content_bottom = 6, .divider_top_row = 7, .input_row = 8, .divider_bottom_row = 9, .hint_row = 10 },
        null,
    );
    defer alloc.free(wide);
    try std.testing.expect(std.mem.find(u8, wide, "alpha  [attach]  relationship:detached") != null);
    try std.testing.expect(std.mem.find(u8, wide, "beta  [detach]  relationship:root") != null);
    try std.testing.expect(std.mem.find(u8, wide, "gamma 🦎  [reparent]  relationship:other-parent") != null);
}

test "attach failure refresh retains immutable selection draft and operation identity" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    try std.testing.expect(try runtime.replaceSnapshot(alloc, try testSnapshot(alloc, 1, &.{})));
    _ = try runtime.handleByte(alloc, 't', null);
    try runtime.installAttachPage(alloc, try testAttachPage(alloc, &.{
        .{ .id = "first", .parent_id = null, .generation = 0 },
        .{ .id = "stable-target", .parent_id = "other", .generation = 3 },
    }), false);
    _ = try runtime.handle(alloc, .down);
    var first = (try runtime.prepareManagerMutation(alloc, 100)).?;
    defer first.deinit(alloc);
    const operation_id = try alloc.dupe(u8, first.invocation_id);
    defer alloc.free(operation_id);
    runtime.mutationRejected(alloc, .{
        .code = .stale_generation,
        .retryable = true,
    });

    try runtime.installAttachPage(alloc, try testAttachPage(alloc, &.{
        .{ .id = "stable-target", .parent_id = "other", .generation = 4 },
        .{ .id = "first", .parent_id = null, .generation = 0 },
    }), false);
    try std.testing.expectEqualStrings("stable-target", runtime.attach.selectedCandidate().?.session_id);
    var retry = (try runtime.prepareManagerMutation(alloc, 200)).?;
    defer retry.deinit(alloc);
    try std.testing.expectEqualStrings(operation_id, retry.invocation_id);
    try std.testing.expectEqual(@as(?u64, 4), retry.expected_generation);

    runtime.attach.candidates.items[runtime.attach.selected].eligible = false;
    try std.testing.expect((try runtime.prepareManagerMutation(alloc, 300)) == null);
    try std.testing.expectEqual(
        FormValidationFailure.attach_candidate_ineligible,
        runtime.attach.attempt.failure.?.validation,
    );
}

test "configure form pins reviewed generation until stale refresh and keeps draft" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    try runtime.setDefaults(alloc, "default/model", types.ReasoningEffort.literal("medium"));
    const snapshot = try configuredTestSnapshot(alloc, 1, 5, .idle);
    try std.testing.expect(try runtime.replaceSnapshot(alloc, snapshot));
    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .enter));
    runtime.focus = .child_detail;
    try std.testing.expectEqual(Command.redraw, try runtime.handleByte(alloc, 's', null));
    try runtime.form.replaceEditor(alloc, .name, "renamed");
    runtime.form.edit(alloc);

    const ordinary_refresh = try configuredTestSnapshot(alloc, 2, 6, .idle);
    try std.testing.expect(try runtime.replaceSnapshot(alloc, ordinary_refresh));

    const rendered = try paint(
        alloc,
        &runtime,
        .{ .rows = 22, .cols = 96, .content_bottom = 18, .divider_top_row = 19, .input_row = 20, .divider_bottom_row = 21, .hint_row = 22 },
        null,
    );
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "Effective/current model: configured/model") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "Effective/current permission mode: yolo") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "Pending next turn: proposed settings apply after submit.") != null);

    var first = (try runtime.prepareManagerMutation(alloc, 100)).?;
    defer first.deinit(alloc);
    const operation_id = try alloc.dupe(u8, first.invocation_id);
    defer alloc.free(operation_id);
    try std.testing.expectEqualStrings("renamed", first.command.configure.name.?);
    try std.testing.expectEqual(@as(?u64, 5), first.expected_generation);
    runtime.mutationRejected(alloc, .{
        .code = .stale_generation,
        .retryable = true,
    });

    var blocked = try runtime.prepareManagerMutation(alloc, 150);
    defer if (blocked) |*prepared| prepared.deinit(alloc);
    try std.testing.expect(blocked == null);

    const failed_refresh = try configuredTestSnapshot(alloc, 3, 6, .idle);
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        runtime.replaceSnapshot(failing.allocator(), failed_refresh),
    );
    try std.testing.expect(runtime.form.expected_generation == null);

    const current_refresh = try configuredTestSnapshot(alloc, 2, 6, .idle);
    try std.testing.expect(!try runtime.replaceSnapshot(alloc, current_refresh));
    var retry = (try runtime.prepareManagerMutation(alloc, 200)).?;
    defer retry.deinit(alloc);
    try std.testing.expectEqualStrings(operation_id, retry.invocation_id);
    try std.testing.expectEqual(@as(?u64, 6), retry.expected_generation);
    try std.testing.expectEqualStrings("renamed", runtime.form.editors[0].edit_state.input.items);

    const later_refresh = try configuredTestSnapshot(alloc, 3, 7, .idle);
    try std.testing.expect(try runtime.replaceSnapshot(alloc, later_refresh));
    var pinned_retry = (try runtime.prepareManagerMutation(alloc, 300)).?;
    defer pinned_retry.deinit(alloc);
    try std.testing.expectEqualStrings(operation_id, pinned_retry.invocation_id);
    try std.testing.expectEqual(@as(?u64, 6), pinned_retry.expected_generation);
    try std.testing.expectEqualStrings("renamed", runtime.form.editors[0].edit_state.input.items);
    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .escape));
    try std.testing.expectEqual(Focus.child_composer, runtime.focus);
    try std.testing.expectEqual(FormKind.none, runtime.form.kind);
}

test "off-page main card and manager approval route retain the same authoritative request identity" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    var snapshot = try pendingApprovalTestSnapshot(alloc, "request-authority-id");
    snapshot.nodes[0].deinit(alloc);
    alloc.free(snapshot.nodes);
    snapshot.nodes = try alloc.alloc(projection.Node, 0);
    try std.testing.expect(try runtime.replaceSnapshot(alloc, snapshot));
    const card = runtime.mainApprovalRequest().?;
    try std.testing.expectEqualStrings("bounded approval", card.label);
    runtime.markMainApprovalPresented(true);
    const binding = runtime.mainApprovalBinding(card.id).?;
    try std.testing.expectEqualStrings("approval-child", binding.child_id);
    try std.testing.expectEqualStrings("request-authority-id", binding.approval_id);

    try std.testing.expectEqual(Command.redraw, try runtime.handle(alloc, .notifications));
    switch (runtime.currentRoute().?.*) {
        .approval => |route| {
            try std.testing.expectEqualStrings("approval-child", route.child_id);
            try std.testing.expectEqualStrings("request-authority-id", route.approval_id);
        },
        else => return error.TestExpectedApprovalRoute,
    }
    try std.testing.expectEqual(Command.resolve_child_approval, try runtime.handleByte(alloc, '2', null));
    const submission = runtime.prepareApprovalResolution().?;
    try std.testing.expectEqualStrings(binding.child_id, submission.child_id);
    try std.testing.expectEqualStrings(binding.approval_id, submission.request_id);
    try std.testing.expectEqual(types.ToolPermissionDecision.always, submission.decision);
}

test "child approval card preserves the semantic label and live preview" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    var snapshot = try pendingApprovalTestSnapshot(alloc, "semantic-label-id");
    alloc.free(snapshot.pending_approvals[0].request.label);
    snapshot.pending_approvals[0].request.label =
        try alloc.dupe(u8, "terminal.exec touch child-marker");
    snapshot.pending_approvals[0].request.command =
        try alloc.dupe(u8, "# terminal.exec profile=user shell=/bin/zsh\ntouch child-marker");
    snapshot.pending_approvals[0].tool_arguments_preview =
        try alloc.dupe(u8, "{\"text\":\"child sentinel\"}");
    try std.testing.expect(try runtime.replaceSnapshot(alloc, snapshot));

    const card = runtime.mainApprovalRequest().?;
    try std.testing.expectEqualStrings(
        "terminal.exec touch child-marker",
        card.label,
    );
    switch (card.origin) {
        .active_session => return error.TestExpectedSubagentApprovalOrigin,
        .subagent => |child_name| try std.testing.expectEqualStrings(
            "approval-child",
            child_name,
        ),
    }
    try std.testing.expectEqualStrings(
        "{\"text\":\"child sentinel\"}",
        card.tool_arguments_preview.?,
    );
    try std.testing.expectEqualStrings(
        "# terminal.exec profile=user shell=/bin/zsh\ntouch child-marker",
        card.command.?,
    );
}

test "child file approval card preserves the bounded review projection" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    var snapshot = try pendingApprovalTestSnapshot(alloc, "file-review-id");
    snapshot.pending_approvals[0].request.file =
        try permission_request.dupeFileApprovalRequest(alloc, .{
            .kind = .edit,
            .intent = .mutation,
            .preview = .{
                .path = "src/note.txt",
                .lines = &.{
                    .{ .op = .deletion, .old_line = 1, .text = "before" },
                    .{ .op = .addition, .new_line = 1, .text = "after" },
                },
                .additions = 1,
                .deletions = 1,
                .truncated = false,
            },
            .scope = .workspace_files,
        });
    try std.testing.expect(try runtime.replaceSnapshot(alloc, snapshot));

    const card = runtime.mainApprovalRequest().?;
    try std.testing.expectEqualStrings("src/note.txt", card.file.?.preview.path);
    try std.testing.expectEqual(@as(usize, 2), card.file.?.preview.lines.len);
    try std.testing.expect(card.file.?.scope == .workspace_files);
    switch (card.origin) {
        .active_session => return error.TestExpectedSubagentApprovalOrigin,
        .subagent => |child_name| try std.testing.expectEqualStrings(
            "approval-child",
            child_name,
        ),
    }
}

test "manager title and notification identify a pending child approval owner" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    try std.testing.expect(try runtime.replaceSnapshot(
        alloc,
        try pendingApprovalTestSnapshot(alloc, "owner-copy-id"),
    ));

    const screen = try paint(
        alloc,
        &runtime,
        .{
            .rows = 12,
            .cols = 120,
            .content_bottom = 8,
            .divider_top_row = 9,
            .input_row = 10,
            .divider_bottom_row = 11,
            .hint_row = 12,
        },
        null,
    );
    defer alloc.free(screen);
    try std.testing.expect(std.mem.find(
        u8,
        screen,
        "Agents & processes · approval-child approval pending",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        screen,
        "Notification: approval-child approval pending — N details",
    ) != null);
    try std.testing.expect(
        std.mem.find(u8, screen, "main chat approval pending") == null,
    );
}

test "main card and manager route keep one selected identity across refresh" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    var snapshot = try pendingApprovalPageTestSnapshot(
        alloc,
        &.{ "request-first", "request-second" },
        0,
        2,
        null,
        null,
    );
    snapshot.content_hash = 1;
    try std.testing.expect(try runtime.replaceSnapshot(alloc, snapshot));

    const card = runtime.mainApprovalRequest().?;
    runtime.markMainApprovalPresented(true);
    const binding = runtime.mainApprovalBinding(card.id).?;
    try std.testing.expectEqualStrings("request-first", binding.approval_id);

    try std.testing.expectEqual(Command.redraw, try runtime.handle(alloc, .notifications));
    switch (runtime.currentRoute().?.*) {
        .approval => |route| {
            try std.testing.expectEqualStrings(binding.child_id, route.child_id);
            try std.testing.expectEqualStrings(binding.approval_id, route.approval_id);
        },
        else => return error.TestExpectedApprovalRoute,
    }

    try std.testing.expectEqual(Command.redraw, try runtime.handle(alloc, .down));
    const second_card = runtime.mainApprovalRequest().?;
    runtime.markMainApprovalPresented(true);
    const second_binding = runtime.mainApprovalBinding(second_card.id).?;
    try std.testing.expectEqualStrings("request-second", second_binding.approval_id);
    switch (runtime.currentRoute().?.*) {
        .approval => |route| {
            try std.testing.expectEqualStrings(second_binding.child_id, route.child_id);
            try std.testing.expectEqualStrings(second_binding.approval_id, route.approval_id);
        },
        else => return error.TestExpectedApprovalRoute,
    }

    try std.testing.expectEqual(Command.redraw, try runtime.handle(alloc, .up));
    var refreshed = try pendingApprovalPageTestSnapshot(
        alloc,
        &.{"request-second"},
        0,
        1,
        null,
        null,
    );
    refreshed.content_hash = 2;
    try std.testing.expect(try runtime.replaceSnapshot(alloc, refreshed));
    const next_card = runtime.mainApprovalRequest().?;
    runtime.markMainApprovalPresented(true);
    const next_binding = runtime.mainApprovalBinding(next_card.id).?;
    try std.testing.expectEqualStrings("request-second", next_binding.approval_id);
    switch (runtime.currentRoute().?.*) {
        .approval => |route| {
            try std.testing.expectEqualStrings(next_binding.child_id, route.child_id);
            try std.testing.expectEqualStrings(next_binding.approval_id, route.approval_id);
        },
        else => return error.TestExpectedApprovalRoute,
    }
}

test "approval page navigation leaves the tree page unchanged beyond eight" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    var first = try pendingApprovalPageTestSnapshot(
        alloc,
        &.{
            "request-00",
            "request-01",
            "request-02",
            "request-03",
            "request-04",
            "request-05",
            "request-06",
            "request-07",
        },
        0,
        10,
        null,
        8,
    );
    first.content_hash = 1;
    first.page_cursor = try alloc.dupe(u8, "tree-page-cursor");
    try std.testing.expect(try runtime.replaceSnapshot(alloc, first));
    try std.testing.expectEqual(Command.redraw, try runtime.handle(alloc, .notifications));
    try std.testing.expectEqual(Command.page_changed, try runtime.handle(alloc, .next_page));
    try std.testing.expectEqual(@as(usize, 8), runtime.pendingApprovalOffset());
    try std.testing.expectEqualStrings("tree-page-cursor", runtime.pageCursor().?);

    var second = try pendingApprovalPageTestSnapshot(
        alloc,
        &.{ "request-08", "request-09" },
        8,
        10,
        0,
        null,
    );
    second.content_hash = 2;
    second.page_cursor = try alloc.dupe(u8, "tree-page-cursor");
    try std.testing.expect(try runtime.replaceSnapshot(alloc, second));
    const card = runtime.mainApprovalRequest().?;
    runtime.markMainApprovalPresented(true);
    const binding = runtime.mainApprovalBinding(card.id).?;
    try std.testing.expectEqualStrings("request-08", binding.approval_id);
    switch (runtime.currentRoute().?.*) {
        .approval => |route| {
            try std.testing.expectEqualStrings(binding.child_id, route.child_id);
            try std.testing.expectEqualStrings(binding.approval_id, route.approval_id);
        },
        else => return error.TestExpectedApprovalRoute,
    }
    try std.testing.expectEqualStrings("tree-page-cursor", runtime.pageCursor().?);
    try std.testing.expectEqual(Command.page_changed, try runtime.handle(alloc, .previous_page));
    try std.testing.expectEqual(@as(usize, 0), runtime.pendingApprovalOffset());
    try std.testing.expectEqualStrings("tree-page-cursor", runtime.pageCursor().?);
}

test "cancel close confirmation reopen and manager navigation remain distinct" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    var snapshot = try testSnapshot(alloc, 1, &.{ "running-child", "archived-child" });
    snapshot.nodes[0].state = .running;
    snapshot.nodes[1].state = .archived;
    try std.testing.expect(try runtime.replaceSnapshot(alloc, snapshot));
    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .enter));
    runtime.focus = .child_detail;
    try std.testing.expectEqual(Command.redraw, try runtime.handleByte(alloc, 'x', null));
    try std.testing.expectEqual(Command.redraw, try runtime.handleByte(alloc, 'x', null));
    try std.testing.expect(runtime.lifecycle_action == .close);
    try std.testing.expectEqual(Focus.confirmation, runtime.focus);
    try std.testing.expectEqual(Command.redraw, try runtime.handle(alloc, .escape));
    try std.testing.expect(runtime.lifecycle_action == null);
    try std.testing.expectEqual(Command.close_manager, try runtime.handle(alloc, .toggle));

    try std.testing.expectEqual(Command.submit_manager_mutation, try runtime.handleByte(alloc, 'c', null));
    try std.testing.expect(runtime.lifecycle_action == .cancel);
    var cancel = (try runtime.prepareManagerMutation(alloc, 10)).?;
    defer cancel.deinit(alloc);
    try std.testing.expectEqual(domain.LifecycleAction.cancel, cancel.command.lifecycle.action);

    runtime.lifecycle_attempt.deinit(alloc);
    runtime.lifecycle_action = null;
    runtime.child.clear(alloc);
    runtime.clearRoutes(alloc);
    try std.testing.expectEqual(Command.redraw, try runtime.handle(alloc, .archived));
    try std.testing.expectEqual(Command.submit_manager_mutation, try runtime.handleByte(alloc, 'o', null));
    var reopen = (try runtime.prepareManagerMutation(alloc, 20)).?;
    defer reopen.deinit(alloc);
    try std.testing.expectEqual(domain.LifecycleAction.reopen, reopen.command.lifecycle.action);
}

test "external owner makes manager cancellation unavailable" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    var snapshot = try testSnapshot(alloc, 1, &.{"external-child"});
    snapshot.nodes[0].state = .queued;
    snapshot.nodes[0].external_busy = true;
    try std.testing.expect(try runtime.replaceSnapshot(alloc, snapshot));
    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .enter));
    runtime.focus = .child_detail;
    try std.testing.expectEqual(Command.redraw, try runtime.handleByte(alloc, 'x', null));

    const rendered = try paint(
        alloc,
        &runtime,
        .{ .rows = 12, .cols = 80, .content_bottom = 8, .divider_top_row = 9, .input_row = 10, .divider_bottom_row = 11, .hint_row = 12 },
        null,
    );
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "Current state: external busy") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "another Fx process owns this child") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "C cancel") == null);
    try std.testing.expectEqual(Command.none, try runtime.handleByte(alloc, 'c', null));
    try std.testing.expect(runtime.lifecycle_action == null);
    try std.testing.expect((try runtime.prepareManagerMutation(alloc, 10)) == null);
}

test "first Ctrl-C cancels active child without exiting manager" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    var snapshot = try testSnapshot(alloc, 1, &.{"running-child"});
    snapshot.nodes[0].state = .running;
    try std.testing.expect(try runtime.replaceSnapshot(alloc, snapshot));
    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .enter));

    try std.testing.expectEqual(
        Command.submit_manager_mutation,
        try runtime.handleByte(alloc, 3, null),
    );
    var cancel = (try runtime.prepareManagerMutation(alloc, 10)).?;
    defer cancel.deinit(alloc);
    try std.testing.expectEqual(domain.LifecycleAction.cancel, cancel.command.lifecycle.action);

    runtime.mutationRejected(alloc, .{ .code = .invalid_state });
    runtime.snapshot.?.nodes[0].state = .interrupted;
    try std.testing.expectEqual(Command.exit_app, try runtime.handle(alloc, .ctrl_c));
}

test "Ctrl-C never cancels a highlighted child from manager or modal routes" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    var snapshot = try testSnapshot(alloc, 1, &.{"running-child"});
    snapshot.nodes[0].state = .running;
    try std.testing.expect(try runtime.replaceSnapshot(alloc, snapshot));

    try std.testing.expectEqual(Command.exit_app, try runtime.handle(alloc, .ctrl_c));
    try std.testing.expect(runtime.lifecycle_action == null);

    const modal_routes = [_]Route{
        .{ .configure = try alloc.dupe(u8, "running-child") },
        .{ .actions = try alloc.dupe(u8, "running-child") },
        .{ .confirm_close = try alloc.dupe(u8, "running-child") },
        .{ .activity = try alloc.dupe(u8, "running-child") },
        .{ .notification = .{
            .child_id = try alloc.dupe(u8, "running-child"),
            .sequence = 1,
        } },
        .{ .approval = .{
            .child_id = try alloc.dupe(u8, "running-child"),
            .approval_id = try alloc.dupe(u8, "approval-id"),
        } },
    };
    for (modal_routes) |route| {
        try runtime.routes.append(alloc, route);
        try std.testing.expectEqual(Command.exit_app, try runtime.handle(alloc, .ctrl_c));
        try std.testing.expect(runtime.lifecycle_action == null);
        var removed = runtime.routes.pop().?;
        removed.deinit(alloc);
    }
}

test "interrupted child actions submit one canonical resume command" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    var snapshot = try testSnapshot(alloc, 1, &.{"interrupted-child"});
    snapshot.nodes[0].state = .interrupted;
    try std.testing.expect(try runtime.replaceSnapshot(alloc, snapshot));
    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .enter));
    runtime.focus = .child_detail;
    try std.testing.expectEqual(Command.redraw, try runtime.handleByte(alloc, 'x', null));
    try std.testing.expectEqual(
        Command.submit_manager_mutation,
        try runtime.handleByte(alloc, 'r', null),
    );
    var prepared_resume = (try runtime.prepareManagerMutation(alloc, 30)).?;
    defer prepared_resume.deinit(alloc);
    try std.testing.expectEqual(domain.LifecycleAction.@"resume", prepared_resume.command.lifecycle.action);
    try std.testing.expectEqualStrings(
        "interrupted-child",
        prepared_resume.command.lifecycle.id,
    );
}

test "opaque tree revisions do not suppress a committed live update" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    try std.testing.expect(try runtime.replaceSnapshot(alloc, try testSnapshot(alloc, 4, &.{"child"})));
    var committed = try testSnapshot(alloc, 3, &.{"child"});
    committed.nodes[0].state = .idle;
    try std.testing.expect(try runtime.replaceSnapshot(alloc, committed));
    try std.testing.expectEqual(Status.idle, runtime.snapshot.?.nodes[0].state);
}

test "bounded page navigation reaches and opens a later immutable child" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);

    var first = try testSnapshot(alloc, 1, &.{"child-099"});
    first.next_cursor = try alloc.dupe(u8, "page-100");
    try std.testing.expect(try runtime.replaceSnapshot(alloc, first));
    try std.testing.expectEqual(Command.page_changed, try runtime.handle(alloc, .next_page));
    try std.testing.expectEqualStrings("page-100", runtime.pageCursor().?);

    var second = try testSnapshot(alloc, 1, &.{"child-100"});
    second.page_cursor = try alloc.dupe(u8, "page-100");
    second.content_hash = 2;
    try std.testing.expect(try runtime.replaceSnapshot(alloc, second));
    try std.testing.expectEqualStrings("child-100", runtime.selected_id.?);
    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .enter));
    try runtime.installChildChat(
        alloc,
        try testChildChat(alloc, runtime.routedNode().?),
        false,
        true,
    );
    try std.testing.expectEqualStrings("child-100", runtime.routedNode().?.child_id);
}

test "manager keeps the next page control visible when child rows fill the body" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);

    var snapshot = try testSnapshot(
        alloc,
        1,
        &.{ "child-000", "child-001", "child-002", "child-003", "child-004", "child-005" },
    );
    snapshot.next_cursor = try alloc.dupe(u8, "page-006");
    try std.testing.expect(try runtime.replaceSnapshot(alloc, snapshot));

    const rendered = try paint(
        alloc,
        &runtime,
        .{ .rows = 7, .cols = 80, .content_bottom = 5, .divider_top_row = 6, .input_row = 6, .divider_bottom_row = 6, .hint_row = 7 },
        null,
    );
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "More children available: ] next page.") != null);
}

test "archived route excludes archived children from the active tree and opens read-only detail" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    var snapshot = try testSnapshot(alloc, 1, &.{ "active-child", "archived-child" });
    snapshot.nodes[1].state = .archived;
    for (snapshot.nodes) |*node| {
        alloc.free(node.name);
        node.name = try alloc.dupe(u8, "duplicate display name");
    }
    try std.testing.expect(try runtime.replaceSnapshot(alloc, snapshot));

    const layout = types.Layout{ .rows = 10, .cols = 72, .content_bottom = 6, .divider_top_row = 7, .input_row = 8, .divider_bottom_row = 9, .hint_row = 10 };
    const active = try paint(alloc, &runtime, layout, null);
    defer alloc.free(active);
    try std.testing.expect(std.mem.find(u8, active, "duplicate display name") != null);
    try std.testing.expect(std.mem.find(u8, active, "archived-child") == null);
    try std.testing.expectEqualStrings("active-child", runtime.selected_id.?);

    try std.testing.expectEqual(Command.redraw, try runtime.handle(alloc, .archived));
    const archived = try paint(alloc, &runtime, layout, null);
    defer alloc.free(archived);
    try std.testing.expect(std.mem.find(u8, archived, "Archived subagents") != null);
    try std.testing.expect(std.mem.find(u8, archived, "duplicate display name") != null);
    try std.testing.expect(std.mem.find(u8, archived, "active-child") == null);
    try std.testing.expectEqualStrings("archived-child", runtime.archived_selected_id.?);
    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .enter));
    try runtime.installChildChat(
        alloc,
        try testChildChat(alloc, runtime.routedNode().?),
        false,
        true,
    );
    try std.testing.expectEqualStrings("archived-child", runtime.routedNode().?.child_id);
    try std.testing.expectEqual(Status.archived, runtime.routedNode().?.state);
    const detail = try paint(alloc, &runtime, layout, null);
    defer alloc.free(detail);
    try std.testing.expect(std.mem.find(u8, detail, "archived-child") != null);
    try std.testing.expect(std.mem.find(u8, detail, "Agents & processes") != null);
}

test "live archival preserves the routed immutable child without stealing focus" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    try std.testing.expect(try runtime.replaceSnapshot(alloc, try testSnapshot(alloc, 1, &.{"child-id"})));
    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .enter));
    const focus_before = runtime.focus;

    var archived = try testSnapshot(alloc, 2, &.{"child-id"});
    archived.nodes[0].state = .archived;
    try std.testing.expect(try runtime.replaceSnapshot(alloc, archived));
    try std.testing.expectEqual(focus_before, runtime.focus);
    try std.testing.expectEqual(@as(usize, 1), runtime.routes.items.len);
    try std.testing.expectEqualStrings("child-id", runtime.routedNode().?.child_id);
    try std.testing.expectEqual(Status.archived, runtime.routedNode().?.state);
    try std.testing.expect(runtime.selected_id == null);
    try std.testing.expectEqualStrings("child-id", runtime.archived_selected_id.?);
}

test "child detail renders owned configuration on a narrow terminal" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    var snapshot = try testSnapshot(alloc, 1, &.{"configured-child"});
    var command = try domain.validateCommand(alloc, .{ .create = .{
        .name = "configured-child",
        .mode = .persistent,
        .model = "openai/gpt-5",
        .effort = types.ReasoningEffort.literal("high"),
        .permission_mode = .auto,
        .notifications = .{
            .terminal = .{ .completed = true, .failed = false, .cancelled = true },
            .milestones = &.{ "halfway", "verified" },
            .report_interval_ms = 5000,
            .report_duration_ms = 60000,
            .stop_conditions = &.{ .terminal, .duration_elapsed },
        },
    } });
    defer command.deinit(alloc);
    snapshot.nodes[0].configuration = try command.create.configuration.clone(alloc);
    try std.testing.expect(try runtime.replaceSnapshot(alloc, snapshot));
    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .enter));
    try runtime.installChildChat(
        alloc,
        try testChildChat(alloc, runtime.routedNode().?),
        false,
        true,
    );

    const rendered = try paint(
        alloc,
        &runtime,
        .{ .rows = 14, .cols = 28, .content_bottom = 10, .divider_top_row = 11, .input_row = 12, .divider_bottom_row = 13, .hint_row = 14 },
        null,
    );
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "Model: openai/gpt-5") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "Permission mode: auto") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "Agents & processes") != null);
}

test "all manager routes expose authoritative detail and ctrl x exits without navigation side effects" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    var snapshot = try testSnapshot(alloc, 1, &.{"child-id"});
    var node = &snapshot.nodes[0];
    node.state = .awaiting_approval;
    node.external_busy = true;
    node.unread_count = 1;
    node.stale = true;
    node.through_sequence = 7;
    node.failure_reason = try alloc.dupe(u8, "provider_http_error: HTTP 502");
    alloc.free(node.activity);
    node.activity = try alloc.alloc(projection.Activity, 1);
    node.activity[0] = .{
        .sequence = 7,
        .revision = 1,
        .timestamp_ms = 1,
        .kind = .tool_activity,
        .summary = try alloc.dupe(u8, "read_file: started"),
    };
    alloc.free(node.approvals);
    node.approvals = try alloc.alloc(projection.Approval, 1);
    node.approvals[0] = .{
        .id = try alloc.dupe(u8, "approval-id"),
        .kind = .tool,
        .status = .pending,
        .label = try alloc.dupe(u8, "read outside workspace"),
        .explanation = try alloc.dupe(u8, "needs approval"),
    };
    try std.testing.expect(try runtime.replaceSnapshot(alloc, snapshot));

    const layout = types.Layout{ .rows = 12, .cols = 72, .content_bottom = 8, .divider_top_row = 9, .input_row = 10, .divider_bottom_row = 11, .hint_row = 12 };
    const root = try paint(alloc, &runtime, layout, null);
    defer alloc.free(root);
    try std.testing.expect(std.mem.find(u8, root, "external busy") != null);
    try std.testing.expect(std.mem.find(u8, root, "unread 1") != null);
    try std.testing.expect(std.mem.find(u8, root, "history gap") != null);
    try std.testing.expect(std.mem.find(u8, root, "approval 1") != null);
    try std.testing.expectEqual(Command.close_manager, try runtime.handle(alloc, .toggle));

    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .enter));
    try runtime.installChildChat(
        alloc,
        try testChildChat(alloc, runtime.routedNode().?),
        false,
        true,
    );
    const child = try paint(alloc, &runtime, layout, null);
    defer alloc.free(child);
    try std.testing.expect(std.mem.find(u8, child, "Agents & processes") != null);
    try std.testing.expect(std.mem.find(u8, child, "child-id") != null);
    try std.testing.expectEqualStrings(
        "provider_http_error: HTTP 502",
        runtime.child.chat.?.failure_reason.?,
    );
    try std.testing.expect(std.mem.find(u8, child, "Latest failure: provider_http_error: HTTP 502") != null);
    try std.testing.expectEqual(Command.close_manager, try runtime.handle(alloc, .toggle));

    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .escape));
    try std.testing.expectEqual(Command.acknowledge, try runtime.handle(alloc, .activity));
    const activity = try paint(alloc, &runtime, layout, null);
    defer alloc.free(activity);
    try std.testing.expect(std.mem.find(u8, activity, "read_file: started") != null);
    try std.testing.expectEqual(Command.close_manager, try runtime.handle(alloc, .toggle));
    try std.testing.expectEqual(Command.redraw, try runtime.handle(alloc, .escape));

    try std.testing.expectEqual(Command.acknowledge, try runtime.handle(alloc, .notifications));
    const approval = try paint(alloc, &runtime, layout, null);
    defer alloc.free(approval);
    try std.testing.expect(std.mem.find(u8, approval, "Approval ID: approval-id") != null);
    try std.testing.expect(std.mem.find(u8, approval, "1 Allow once") != null);
    try std.testing.expectEqual(Command.close_manager, try runtime.handle(alloc, .toggle));
    try std.testing.expectEqual(Command.redraw, try runtime.handle(alloc, .escape));

    for (runtime.snapshot.?.nodes[0].approvals) |*item| item.deinit(alloc);
    alloc.free(runtime.snapshot.?.nodes[0].approvals);
    runtime.snapshot.?.nodes[0].approvals = try alloc.alloc(projection.Approval, 0);
    try std.testing.expectEqual(Command.acknowledge, try runtime.handle(alloc, .notifications));
    const notification = try paint(alloc, &runtime, layout, null);
    defer alloc.free(notification);
    try std.testing.expect(std.mem.find(u8, notification, "Notification") != null);
    try std.testing.expectEqual(Command.close_manager, try runtime.handle(alloc, .toggle));
}

test "main approval notification opens from an empty manager without owning resolution" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    try std.testing.expect(try runtime.replaceSnapshot(alloc, try testSnapshot(alloc, 1, &.{})));

    try std.testing.expectEqual(
        Command.redraw,
        try runtime.handleWithMainApproval(alloc, .notifications, 42),
    );
    try std.testing.expectEqual(Focus.approval, runtime.focus);
    const layout = types.Layout{ .rows = 9, .cols = 72, .content_bottom = 5, .divider_top_row = 6, .input_row = 7, .divider_bottom_row = 8, .hint_row = 9 };
    const rendered = try paint(alloc, &runtime, layout, .{
        .id = 42,
        .label = "terminal.exec zig build test",
        .explanation = "requires confirmation",
        .command = "zig build test",
    });
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "Main chat approval") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "Request ID: 42") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "terminal.exec zig build test") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "Read-only here") != null);

    runtime.setDegraded(alloc, .store_failure);
    const degraded = try paint(alloc, &runtime, layout, .{ .id = 42, .label = "still pending" });
    defer alloc.free(degraded);
    try std.testing.expect(std.mem.find(u8, degraded, "Main chat approval") != null);

    const cleared = try paint(alloc, &runtime, layout, null);
    defer alloc.free(cleared);
    try std.testing.expect(std.mem.find(u8, cleared, "no longer pending") != null);
    try std.testing.expectEqual(Command.redraw, try runtime.handle(alloc, .escape));
    try std.testing.expectEqual(Command.close_manager, try runtime.handle(alloc, .toggle));
}

test "child composer input submission and refresh stay independent from main state" {
    const alloc = std.testing.allocator;
    var main_editor = core_input_runtime.Runtime{};
    defer main_editor.deinit(alloc);
    try main_editor.insertionState().insertSlice(alloc, "untouched main 🧭", .preserve);
    const main_cursor = main_editor.edit_state.cursor;

    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    try std.testing.expect(try runtime.replaceSnapshot(
        alloc,
        try testSnapshot(alloc, 1, &.{ "child-a", "child-b" }),
    ));
    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .enter));
    try runtime.installChildChat(
        alloc,
        try testChildChat(alloc, runtime.routedNode().?),
        false,
        true,
    );
    for ("héllo 🦎") |byte| {
        try std.testing.expectEqual(Command.redraw, try runtime.handleByte(alloc, byte, null));
    }
    try std.testing.expectEqual(Command.redraw, try runtime.handle(alloc, .left));
    try std.testing.expectEqual(Command.redraw, try runtime.handleByte(alloc, '!', null));
    runtime.beginChildPaste();
    for (" pasted\x1b[201~") |byte| {
        try std.testing.expect(try runtime.consumeChildPasteByte(alloc, byte));
    }
    try std.testing.expect(runtime.settleManagerPasteDeliveryEpoch(alloc));
    try std.testing.expect(std.unicode.utf8ValidateSlice(runtime.child.editor.edit_state.input.items));
    try std.testing.expect(std.mem.find(u8, runtime.child.editor.edit_state.input.items, "pasted") != null);
    try std.testing.expectEqualStrings("untouched main 🧭", main_editor.edit_state.input.items);
    try std.testing.expectEqual(main_cursor, main_editor.edit_state.cursor);

    runtime.child.scroll_from_bottom = 5;
    const child_cursor = runtime.child.editor.edit_state.cursor;
    const draft = try alloc.dupe(u8, runtime.child.editor.edit_state.input.items);
    defer alloc.free(draft);
    const focus = runtime.focus;
    var update = try testSnapshot(alloc, 2, &.{ "child-b", "child-a" });
    update.nodes[1].state = .awaiting_approval;
    try std.testing.expect(try runtime.replaceSnapshot(alloc, update));
    try runtime.installChildChat(
        alloc,
        try testChildChat(alloc, runtime.routedNode().?),
        false,
        false,
    );
    _ = runtime.replaceChildLive(
        alloc,
        try testLivePresentation(alloc, "work-live", "new live answer"),
    );
    try std.testing.expectEqual(focus, runtime.focus);
    try std.testing.expectEqual(child_cursor, runtime.child.editor.edit_state.cursor);
    try std.testing.expectEqual(@as(usize, 5), runtime.child.scroll_from_bottom);
    try std.testing.expectEqualStrings(draft, runtime.child.editor.edit_state.input.items);

    const first_submission = (try runtime.prepareSubmission(alloc, 100)).?;
    try std.testing.expectEqualStrings("child-a", first_submission.child_id);
    try std.testing.expectEqualStrings(draft, first_submission.content);
    const stable_id = try alloc.dupe(u8, first_submission.invocation_id);
    defer alloc.free(stable_id);
    runtime.submissionRejected(alloc, .{ .code = .store_failure, .retryable = true });
    const retry = (try runtime.prepareSubmission(alloc, 200)).?;
    try std.testing.expectEqualStrings(stable_id, retry.invocation_id);
    try std.testing.expectEqualStrings(draft, retry.content);

    try std.testing.expect(runtime.assignSubmissionIdentity(
        retry.invocation_id,
        51,
    ));
    runtime.submissionRejected(alloc, .{ .code = .child_unavailable });
    const terminal_retry = (try runtime.prepareSubmission(alloc, 250)).?;
    try std.testing.expect(!std.mem.eql(
        u8,
        stable_id,
        terminal_retry.invocation_id,
    ));
    try std.testing.expectEqual(@as(u64, 0), terminal_retry.identity_epoch);
    try std.testing.expectEqualStrings(draft, terminal_retry.content);

    runtime.submissionAccepted(alloc);
    try std.testing.expectEqual(@as(usize, 0), runtime.child.editor.edit_state.input.items.len);
    try std.testing.expect(runtime.child.invocation_id == null);
    try std.testing.expect(runtime.child.submission_failure == null);

    for ("switch draft") |byte| _ = try runtime.handleByte(alloc, byte, null);
    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .escape));
    try std.testing.expectEqualStrings("switch draft", runtime.child.editor.edit_state.input.items);
    try std.testing.expectEqual(Command.redraw, try runtime.handle(alloc, .down));
    try std.testing.expectEqual(@as(usize, 0), runtime.child.editor.edit_state.input.items.len);
    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .enter));
    try std.testing.expectEqualStrings("child-b", runtime.childRouteId().?);
    try runtime.installChildChat(
        alloc,
        try testChildChat(alloc, runtime.routedNode().?),
        false,
        true,
    );
    for ("beta draft") |byte| _ = try runtime.handleByte(alloc, byte, null);
    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .escape));
    try std.testing.expectEqual(Command.redraw, try runtime.handle(alloc, .up));
    try std.testing.expectEqualStrings("switch draft", runtime.child.editor.edit_state.input.items);
    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .enter));
    try std.testing.expectEqualStrings("child-a", runtime.childRouteId().?);
    try std.testing.expectEqualStrings("switch draft", runtime.child.editor.edit_state.input.items);
    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .escape));
    try std.testing.expectEqual(Command.redraw, try runtime.handle(alloc, .down));
    try std.testing.expectEqualStrings("beta draft", runtime.child.editor.edit_state.input.items);
    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .enter));
    try std.testing.expectEqualStrings("child-b", runtime.childRouteId().?);
    try std.testing.expectEqualStrings("beta draft", runtime.child.editor.edit_state.input.items);
    try std.testing.expectEqualStrings("untouched main 🧭", main_editor.edit_state.input.items);
}

test "child composer pointer selection replaces and cuts only the selected range" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    try std.testing.expect(try runtime.replaceSnapshot(
        alloc,
        try testSnapshot(alloc, 1, &.{"child"}),
    ));
    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .enter));
    try runtime.installChildChat(
        alloc,
        try testChildChat(alloc, runtime.routedNode().?),
        false,
        true,
    );
    try runtime.child.editor.insertionState().insertSlice(alloc, "abcdef", .preserve);

    try std.testing.expect(runtime.child.editor.selectionState().begin(1));
    try std.testing.expect(runtime.child.editor.selectionState().extend(4));
    runtime.child.editor.selectionState().finish();
    try std.testing.expectEqualStrings("bcd", runtime.child.editor.edit_state.selectedText().?);
    try std.testing.expectEqual(Command.redraw, try runtime.handleByte(alloc, 'X', null));
    try std.testing.expectEqualStrings("aXef", runtime.child.editor.edit_state.input.items);

    try std.testing.expect(runtime.child.editor.selectionState().begin(1));
    try std.testing.expect(runtime.child.editor.selectionState().extend(2));
    runtime.child.editor.selectionState().finish();
    try std.testing.expect(runtime.child.editor.selectionState().delete(alloc, null));
    runtime.commitChildEditorEdit(alloc);
    try std.testing.expectEqualStrings("aef", runtime.child.editor.edit_state.input.items);
    try std.testing.expect(runtime.child.editor.edit_state.selectedText() == null);
}

test "child composer keyboard movement selection and undo use the shared editor" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    try std.testing.expect(try runtime.replaceSnapshot(
        alloc,
        try testSnapshot(alloc, 1, &.{"child"}),
    ));
    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .enter));
    try runtime.installChildChat(
        alloc,
        try testChildChat(alloc, runtime.routedNode().?),
        false,
        true,
    );
    try runtime.child.editor.insertionState().insertSlice(alloc, "alpha beta", .preserve);

    try std.testing.expect(runtime.moveChildInputCursor(
        .{ .kind = .word_left, .extend_selection = true },
        80,
        10,
    ));
    try std.testing.expectEqualStrings("beta", runtime.child.editor.edit_state.selectedText().?);
    try std.testing.expectEqual(Command.redraw, try runtime.handleByte(alloc, 'X', null));
    try std.testing.expectEqualStrings("alpha X", runtime.child.editor.edit_state.input.items);
    try std.testing.expect(try runtime.child.editor.undoState().undo(alloc));
    try std.testing.expectEqualStrings("alpha beta", runtime.child.editor.edit_state.input.items);
    try std.testing.expect(runtime.child.editor.selectionState().selectAll());
    try std.testing.expectEqualStrings("alpha beta", runtime.child.editor.edit_state.selectedText().?);
}

test "child and form editors keep Home End and control aliases on the current line" {
    const alloc = std.testing.allocator;
    const multiline = "first\nsecond";
    const second_line_start = "first\n".len;

    var child_runtime = Runtime{};
    defer child_runtime.deinit(alloc);
    try std.testing.expect(try child_runtime.replaceSnapshot(
        alloc,
        try testSnapshot(alloc, 1, &.{"child"}),
    ));
    try std.testing.expectEqual(Command.child_changed, try child_runtime.handle(alloc, .enter));
    try child_runtime.installChildChat(
        alloc,
        try testChildChat(alloc, child_runtime.routedNode().?),
        false,
        true,
    );
    try child_runtime.child.editor.insertionState().insertSlice(alloc, multiline, .preserve);

    try std.testing.expectEqual(Command.redraw, try child_runtime.handle(alloc, .home));
    try std.testing.expectEqual(second_line_start, child_runtime.child.editor.edit_state.cursor);
    try std.testing.expectEqual(Command.redraw, try child_runtime.handle(alloc, .end));
    try std.testing.expectEqual(multiline.len, child_runtime.child.editor.edit_state.cursor);
    try std.testing.expectEqual(Command.redraw, try child_runtime.handleByte(alloc, 1, null));
    try std.testing.expectEqual(second_line_start, child_runtime.child.editor.edit_state.cursor);
    try std.testing.expectEqual(Command.redraw, try child_runtime.handleByte(alloc, 5, null));
    try std.testing.expectEqual(multiline.len, child_runtime.child.editor.edit_state.cursor);

    var form_runtime = Runtime{};
    defer form_runtime.deinit(alloc);
    try form_runtime.setDefaults(alloc, "test/model", types.ReasoningEffort.literal("high"));
    try std.testing.expect(try form_runtime.replaceSnapshot(
        alloc,
        try testSnapshot(alloc, 1, &.{}),
    ));
    try std.testing.expectEqual(Command.redraw, try form_runtime.handleByte(alloc, 'c', null));
    form_runtime.form.field_index = 2;
    try form_runtime.form.replaceEditor(alloc, .initial_message, multiline);

    try std.testing.expectEqual(Command.redraw, try form_runtime.handle(alloc, .home));
    try std.testing.expectEqual(second_line_start, form_runtime.form.editors[2].edit_state.cursor);
    try std.testing.expectEqual(Command.redraw, try form_runtime.handle(alloc, .end));
    try std.testing.expectEqual(multiline.len, form_runtime.form.editors[2].edit_state.cursor);
    try std.testing.expectEqual(Command.redraw, try form_runtime.handleByte(alloc, 1, null));
    try std.testing.expectEqual(second_line_start, form_runtime.form.editors[2].edit_state.cursor);
    try std.testing.expectEqual(Command.redraw, try form_runtime.handleByte(alloc, 5, null));
    try std.testing.expectEqual(multiline.len, form_runtime.form.editors[2].edit_state.cursor);
}

test "typed terminal controls preserve child and form edit behavior" {
    const alloc = std.testing.allocator;

    var child_runtime = Runtime{};
    defer child_runtime.deinit(alloc);
    try std.testing.expect(try child_runtime.replaceSnapshot(
        alloc,
        try testSnapshot(alloc, 1, &.{"child"}),
    ));
    try std.testing.expectEqual(Command.child_changed, try child_runtime.handle(alloc, .enter));
    try child_runtime.installChildChat(
        alloc,
        try testChildChat(alloc, child_runtime.routedNode().?),
        false,
        true,
    );
    try child_runtime.child.editor.insertionState().insertSlice(alloc, "ab", .preserve);

    try std.testing.expect(child_runtime.childComposerFocused());
    try std.testing.expectEqual(Command.redraw, try child_runtime.handle(alloc, .focus_next));
    try std.testing.expect(!child_runtime.childComposerFocused());
    try std.testing.expectEqual(Command.redraw, try child_runtime.handle(alloc, .focus_next));
    try std.testing.expect(child_runtime.childComposerFocused());
    try std.testing.expectEqual(Command.redraw, try child_runtime.handle(alloc, .delete_backward));
    try std.testing.expectEqualStrings("a", child_runtime.child.editor.edit_state.input.items);

    var form_runtime = Runtime{};
    defer form_runtime.deinit(alloc);
    try form_runtime.setDefaults(alloc, "test/model", types.ReasoningEffort.literal("high"));
    try std.testing.expect(try form_runtime.replaceSnapshot(
        alloc,
        try testSnapshot(alloc, 1, &.{}),
    ));
    try std.testing.expectEqual(Command.redraw, try form_runtime.handleByte(alloc, 'c', null));
    form_runtime.form.field_index = 2;
    try form_runtime.form.replaceEditor(alloc, .initial_message, "ab");

    try std.testing.expectEqual(Command.redraw, try form_runtime.handle(alloc, .delete_backward));
    try std.testing.expectEqualStrings("a", form_runtime.form.editors[2].edit_state.input.items);
    try std.testing.expectEqual(Command.redraw, try form_runtime.handle(alloc, .focus_next));
    try std.testing.expectEqual(@as(usize, 3), form_runtime.form.field_index);
}

test "unchanged live child snapshots do not mutate the viewport or request repaint" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    try std.testing.expect(try runtime.replaceSnapshot(
        alloc,
        try testSnapshot(alloc, 1, &.{"child-live"}),
    ));
    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .enter));
    try runtime.installChildChat(
        alloc,
        try testChildChat(alloc, runtime.routedNode().?),
        false,
        true,
    );
    runtime.child.rendered_chat_rows = 20;

    try std.testing.expect(runtime.replaceChildLive(
        alloc,
        try testLivePresentation(alloc, "work-live", "streaming"),
    ));
    try std.testing.expectEqual(ViewportMutation.bottom, runtime.child.viewport_mutation);
    runtime.child.viewport_mutation = .none;

    try std.testing.expect(!runtime.replaceChildLive(
        alloc,
        try testLivePresentation(alloc, "work-live", "streaming"),
    ));
    try std.testing.expectEqual(ViewportMutation.none, runtime.child.viewport_mutation);

    var changed = try testLivePresentation(alloc, "work-live", "streaming more");
    changed.revision = 2;
    try std.testing.expect(runtime.replaceChildLive(alloc, changed));
    try std.testing.expectEqual(ViewportMutation.bottom, runtime.child.viewport_mutation);

    var rich = try testLivePresentationWithRichTextEvent(
        alloc,
        "work-rich",
        "canonical stream",
    );
    rich.revision = 3;
    try std.testing.expect(runtime.replaceChildLive(alloc, rich));
    runtime.child.viewport_mutation = .none;
    var legacy_only_update = try testLivePresentationWithRichTextEvent(
        alloc,
        "work-rich",
        "canonical stream",
    );
    legacy_only_update.revision = 4;
    try std.testing.expect(!runtime.replaceChildLive(
        alloc,
        legacy_only_update,
    ));
    try std.testing.expectEqual(ViewportMutation.none, runtime.child.viewport_mutation);
}

test "subagent manager and child conversations own independent render requests" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);

    runtime.activeRenderRequests().request(.subagent_panel);
    try std.testing.expect(runtime.render_requests.hasReason(.subagent_panel));

    runtime.child.presentation = .{};
    runtime.activeRenderRequests().request(.transcript);
    try std.testing.expect(runtime.child.presentation.?.render_requests.hasReason(.transcript));
    try std.testing.expect(!runtime.render_requests.hasReason(.transcript));

    try std.testing.expect(runtime.activateChildConversationSurface());
    try std.testing.expect(!runtime.activateChildConversationSurface());
    try std.testing.expect(runtime.activateChildCatalogSurface());
    try std.testing.expect(!runtime.activateChildCatalogSurface());
    try std.testing.expect(runtime.activateChildConversationSurface());
    runtime.activateManagerSurface();
    try std.testing.expect(runtime.activateChildConversationSurface());
}

test "read only child route hides editing and rejects composer bytes" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    var snapshot = try testSnapshot(alloc, 1, &.{"child-read-only"});
    snapshot.nodes[0].mode = .one_off;
    snapshot.nodes[0].state = .completed;
    try std.testing.expect(try runtime.replaceSnapshot(alloc, snapshot));
    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .enter));
    try runtime.installChildChat(
        alloc,
        try testChildChat(alloc, runtime.routedNode().?),
        false,
        true,
    );

    try std.testing.expectEqual(Focus.child_detail, runtime.focus);
    try std.testing.expectEqual(
        Command.none,
        try runtime.handleByte(alloc, 'z', null),
    );
    try std.testing.expectEqual(@as(usize, 0), runtime.child.editor.edit_state.input.items.len);
    try std.testing.expectEqual(Command.none, try runtime.handle(alloc, .enter));
    try std.testing.expectEqual(Focus.child_detail, runtime.focus);
    try std.testing.expectEqual(
        Command.redraw,
        try runtime.handleByte(alloc, '\t', null),
    );
    try std.testing.expectEqual(Focus.child_detail, runtime.focus);
}

test "read only child route pages its transcript" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    var snapshot = try testSnapshot(alloc, 1, &.{"child-read-only"});
    snapshot.nodes[0].mode = .one_off;
    snapshot.nodes[0].state = .completed;
    try std.testing.expect(try runtime.replaceSnapshot(alloc, snapshot));
    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .enter));
    try runtime.installChildChat(
        alloc,
        try testChildChat(alloc, runtime.routedNode().?),
        false,
        true,
    );
    runtime.child.max_scroll = 64;

    try std.testing.expectEqual(Command.redraw, try runtime.handle(alloc, .page_up));
    try std.testing.expectEqual(@as(usize, 8), runtime.child.scroll_from_bottom);
    try std.testing.expectEqual(Command.redraw, try runtime.handle(alloc, .page_down));
    try std.testing.expectEqual(@as(usize, 0), runtime.child.scroll_from_bottom);
}

test "messageable child detail focus pages its transcript" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    try std.testing.expect(try runtime.replaceSnapshot(
        alloc,
        try testSnapshot(alloc, 1, &.{"child"}),
    ));
    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .enter));
    try runtime.installChildChat(
        alloc,
        try testChildChat(alloc, runtime.routedNode().?),
        false,
        true,
    );
    runtime.focus = .child_detail;
    runtime.child.max_scroll = 64;

    try std.testing.expectEqual(Command.redraw, try runtime.handle(alloc, .page_up));
    try std.testing.expectEqual(@as(usize, 8), runtime.child.scroll_from_bottom);
}

test "selected child restores its viewport after escape and manager close" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    try std.testing.expect(try runtime.replaceSnapshot(
        alloc,
        try testSnapshot(alloc, 1, &.{"child"}),
    ));
    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .enter));
    try runtime.installChildChat(
        alloc,
        try testChildChat(alloc, runtime.routedNode().?),
        false,
        true,
    );
    try runtime.child.editor.insertionState().insertSlice(alloc, "unsent\nchild draft", .preserve);
    _ = horizontal_navigation.move(
        .character_left,
        &runtime.child.editor.edit_state,
        &runtime.child.editor.entities,
        &runtime.child.editor.vertical_navigation,
    );
    const draft_cursor = runtime.child.editor.edit_state.cursor;
    runtime.commitChildPresentationViewport(90, 70, 40);

    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .escape));
    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .enter));
    try runtime.installChildChat(
        alloc,
        try testChildChat(alloc, runtime.routedNode().?),
        false,
        true,
    );
    const escaped_view = runtime.childPresentationView().?;
    try std.testing.expectEqual(@as(u32, 40), escaped_view.rows_from_bottom);
    try std.testing.expectEqual(@as(?u32, 90), escaped_view.prior_total_rows);
    try std.testing.expect(escaped_view.preserve_after_append);
    try std.testing.expectEqualStrings("unsent\nchild draft", escaped_view.editor.edit_state.input.items);
    try std.testing.expectEqual(draft_cursor, escaped_view.editor.edit_state.cursor);

    runtime.commitChildPresentationViewport(90, 70, 32);
    runtime.resetForOpen(alloc);
    runtime.resetForOpen(alloc);
    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .enter));
    try runtime.installChildChat(
        alloc,
        try testChildChat(alloc, runtime.routedNode().?),
        false,
        true,
    );
    const reopened_view = runtime.childPresentationView().?;
    try std.testing.expectEqual(@as(u32, 32), reopened_view.rows_from_bottom);
    try std.testing.expectEqual(@as(?u32, 90), reopened_view.prior_total_rows);
    try std.testing.expect(reopened_view.preserve_after_append);
    try std.testing.expectEqualStrings("unsent\nchild draft", reopened_view.editor.edit_state.input.items);
    try std.testing.expectEqual(draft_cursor, reopened_view.editor.edit_state.cursor);
}

test "leaving a selected child acknowledges activity that arrived while visible" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    try std.testing.expect(try runtime.replaceSnapshot(
        alloc,
        try testSnapshot(alloc, 1, &.{"child"}),
    ));
    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .enter));
    try runtime.installChildChat(
        alloc,
        try testChildChat(alloc, runtime.routedNode().?),
        false,
        true,
    );

    var update = try testSnapshot(alloc, 2, &.{"child"});
    update.nodes[0].through_sequence = 7;
    update.nodes[0].unread_count = 1;
    try std.testing.expect(try runtime.replaceSnapshot(alloc, update));
    try std.testing.expect(runtime.visibleChildAcknowledgementSequence() == null);
    runtime.commitChildPresentationViewport(20, 10, 4);
    try std.testing.expect(runtime.visibleChildAcknowledgementSequence() == null);
    runtime.commitChildPresentationViewport(20, 0, 0);
    try std.testing.expectEqual(
        @as(?u64, 7),
        runtime.visibleChildAcknowledgementSequence(),
    );

    var unseen_update = try testSnapshot(alloc, 3, &.{"child"});
    unseen_update.nodes[0].through_sequence = 8;
    unseen_update.nodes[0].unread_count = 2;
    try std.testing.expect(try runtime.replaceSnapshot(alloc, unseen_update));

    try std.testing.expectEqual(Command.acknowledge, try runtime.handle(alloc, .escape));
    try std.testing.expectEqualStrings("child", runtime.selectedNode().?.child_id);
    try std.testing.expectEqual(@as(u64, 8), runtime.selectedNode().?.through_sequence);
    try std.testing.expectEqual(
        @as(u64, 7),
        runtime.pendingChildAcknowledgement().?.through_sequence,
    );
    runtime.childAcknowledgementAttempted(alloc, "child", 6);
    try std.testing.expectEqual(
        @as(u64, 7),
        runtime.pendingChildAcknowledgement().?.through_sequence,
    );
    runtime.childAcknowledgementAttempted(alloc, "child", 7);
    try std.testing.expect(runtime.pendingChildAcknowledgement() == null);
    try std.testing.expectEqual(@as(u64, 8), runtime.routedNode().?.through_sequence);
}

test "archived child acknowledgement retains the watched child identity" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);

    var snapshot = try testSnapshot(alloc, 1, &.{ "active-child", "archived-child" });
    snapshot.nodes[1].state = .archived;
    snapshot.nodes[1].through_sequence = 11;
    snapshot.nodes[1].unread_count = 1;
    try std.testing.expect(try runtime.replaceSnapshot(alloc, snapshot));
    try std.testing.expectEqual(Command.redraw, try runtime.handle(alloc, .archived));
    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .enter));
    try runtime.installChildChat(
        alloc,
        try testChildChat(alloc, runtime.routedNode().?),
        false,
        true,
    );
    runtime.commitChildPresentationViewport(20, 0, 0);

    try std.testing.expectEqual(Command.acknowledge, try runtime.handle(alloc, .escape));
    const pending = runtime.pendingChildAcknowledgement().?;
    try std.testing.expectEqualStrings("archived-child", pending.child_id);
    try std.testing.expectEqual(@as(u64, 11), pending.through_sequence);
}

test "child conversation owns and resolves its full diff sidecars" {
    const alloc = std.testing.allocator;
    const c_alloc = std.heap.c_allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);

    var conversation: transcript_runtime.TranscriptRuntime = .{};
    conversation.layout.cols = 80;
    var diffs: std.ArrayList(diff_mod.DiffEntry) = .empty;
    var entry = try struct {
        fn make(a: Allocator) !diff_mod.DiffEntry {
            const content = try a.dupe(u8, "full child diff\n");
            errdefer a.free(content);
            const call_id = try a.dupe(u8, "child-diff-call");
            return .{
                .id = 9,
                .full = .{
                    .content = content,
                    .lifecycle_id = .{
                        .turn_id = 5,
                        .call_id = call_id,
                    },
                },
            };
        }
    }.make(c_alloc);
    var owns_entry = true;
    errdefer if (owns_entry) entry.deinit(c_alloc);
    try diffs.append(c_alloc, entry);
    owns_entry = false;
    try runtime.installChildConversationRuntime(
        alloc,
        conversation,
        diffs,
        null,
        10,
    );

    const resolver = runtime.childFullTranscriptDiffResolver().?;
    try std.testing.expectEqualStrings(
        "full child diff\n",
        resolver.full_for_marker(resolver.context, 9).?,
    );
    try std.testing.expect(resolver.has_full_for_lifecycle(
        resolver.context,
        .{ .turn_id = 5, .call_id = "child-diff-call" },
    ));
    try std.testing.expect(!resolver.has_full_for_lifecycle(
        resolver.context,
        .{ .turn_id = 5, .call_id = "main-diff-call" },
    ));
}

test "child transcript depth survives transient presentation rebuilds" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);

    try std.testing.expect(try runtime.replaceSnapshot(
        alloc,
        try testSnapshot(alloc, 1, &.{"child"}),
    ));
    try std.testing.expectEqual(
        Command.child_changed,
        try runtime.handle(alloc, .enter),
    );
    try std.testing.expectEqual(
        transcript_presentation.Depth.review,
        try runtime.setChildTranscriptPresentationDepth(alloc, .review),
    );
    try std.testing.expect(runtime.childFullTranscriptRequested());
    try std.testing.expect(runtime.childConversationRuntime() == null);

    var first: transcript_runtime.TranscriptRuntime = .{};
    first.layout.cols = 80;
    try runtime.installChildConversationRuntime(
        alloc,
        first,
        .empty,
        null,
        1,
    );
    try std.testing.expect(
        runtime.childConversationRuntime().?.fullTranscriptActive(),
    );

    runtime.child.clearPresentation(alloc);
    try std.testing.expect(runtime.childFullTranscriptRequested());
    try std.testing.expect(runtime.childConversationRuntime() == null);

    var second: transcript_runtime.TranscriptRuntime = .{};
    second.layout.cols = 80;
    try runtime.installChildConversationRuntime(
        alloc,
        second,
        .empty,
        null,
        1,
    );
    try std.testing.expect(
        runtime.childConversationRuntime().?.fullTranscriptActive(),
    );

    runtime.child.clearPresentation(alloc);
    try std.testing.expectEqual(
        transcript_presentation.Depth.full,
        try runtime.setChildTranscriptPresentationDepth(alloc, .full),
    );
    try std.testing.expect(runtime.childFullTranscriptRequested());

    var third: transcript_runtime.TranscriptRuntime = .{};
    third.layout.cols = 80;
    try runtime.installChildConversationRuntime(
        alloc,
        third,
        .empty,
        null,
        1,
    );
    try std.testing.expect(
        runtime.childConversationRuntime().?.fullTranscriptActive(),
    );
    try std.testing.expectEqual(
        transcript_presentation.Depth.full,
        runtime.childConversationRuntime().?.transcriptPresentationDepth(),
    );

    try std.testing.expectEqual(
        transcript_presentation.Depth.inline_mode,
        try runtime.setChildTranscriptPresentationDepth(alloc, .inline_mode),
    );
    try std.testing.expect(
        !runtime.childConversationRuntime().?.fullTranscriptActive(),
    );
    runtime.child.clear(alloc);
    try std.testing.expect(!runtime.childFullTranscriptRequested());
}

test "child paste is bounded UTF-8 safe atomic and retry stable" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    try std.testing.expect(try runtime.replaceSnapshot(
        alloc,
        try testSnapshot(alloc, 1, &.{"child"}),
    ));
    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .enter));
    try runtime.installChildChat(
        alloc,
        try testChildChat(alloc, runtime.routedNode().?),
        false,
        true,
    );

    const exact_prefix = try alloc.alloc(u8, domain.max_message_bytes - 2);
    defer alloc.free(exact_prefix);
    @memset(exact_prefix, 'x');
    try runtime.child.editor.insertionState().insertSlice(alloc, exact_prefix, .preserve);
    runtime.beginChildPaste();
    for ("é\x1b[201~") |byte| {
        try std.testing.expect(try runtime.consumeChildPasteByte(alloc, byte));
    }
    try std.testing.expect(runtime.settleManagerPasteDeliveryEpoch(alloc));
    try std.testing.expectEqual(domain.max_message_bytes, runtime.child.editor.edit_state.input.items.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(runtime.child.editor.edit_state.input.items));

    runtime.child.editor.inputResetState().clearCurrent(alloc);
    try runtime.child.editor.insertionState().insertSlice(alloc, exact_prefix, .preserve);
    try runtime.child.editor.insertionState().insertByte(alloc, 'x', .clear);
    const boundary_cursor = runtime.child.editor.edit_state.cursor;
    const initial_submission = (try runtime.prepareSubmission(alloc, 100)).?;
    const operation_id = try alloc.dupe(u8, initial_submission.invocation_id);
    defer alloc.free(operation_id);
    runtime.submissionRejected(alloc, .{ .code = .store_failure, .retryable = true });
    runtime.beginChildPaste();
    for ("é\x1b[201~") |byte| {
        try std.testing.expect(try runtime.consumeChildPasteByte(alloc, byte));
    }
    try std.testing.expect(runtime.settleManagerPasteDeliveryEpoch(alloc));
    try std.testing.expectEqual(domain.max_message_bytes - 1, runtime.child.editor.edit_state.input.items.len);
    try std.testing.expectEqual(boundary_cursor, runtime.child.editor.edit_state.cursor);
    try std.testing.expect(std.unicode.utf8ValidateSlice(runtime.child.editor.edit_state.input.items));
    const retry = (try runtime.prepareSubmission(alloc, 200)).?;
    try std.testing.expectEqualStrings(operation_id, retry.invocation_id);
    const boundary_view = runtime.childPresentationView().?;
    try std.testing.expectEqual(
        ChildInputFailure.message_too_large,
        boundary_view.input_failure.?,
    );
    try std.testing.expectEqualStrings(
        "Message too large",
        childInputFailureDisplay(boundary_view.input_failure.?),
    );

    runtime.child.editor.inputResetState().clearCurrent(alloc);
    runtime.beginChildPaste();
    for (0..domain.max_message_bytes + 32) |_| {
        try std.testing.expect(try runtime.consumeChildPasteByte(alloc, 'z'));
        try std.testing.expect(runtime.child.editor.paste.buffer.items.len <= domain.max_message_bytes);
    }
    for ("\x1b[201~") |byte| {
        try std.testing.expect(try runtime.consumeChildPasteByte(alloc, byte));
    }
    try std.testing.expect(runtime.settleManagerPasteDeliveryEpoch(alloc));
    try std.testing.expectEqual(@as(usize, 0), runtime.child.editor.edit_state.input.items.len);
    try std.testing.expectEqual(paste_framing.Owner.none, runtime.child.editor.paste.owner);
}

test "child paste replaces selection and remains undoable" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    try std.testing.expect(try runtime.replaceSnapshot(
        alloc,
        try testSnapshot(alloc, 1, &.{"child"}),
    ));
    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .enter));
    try runtime.installChildChat(
        alloc,
        try testChildChat(alloc, runtime.routedNode().?),
        false,
        true,
    );
    try runtime.child.editor.textReplacementState().replace(alloc, "abcde");
    _ = runtime.child.editor.selectionState().begin(1);
    _ = runtime.child.editor.selectionState().extend(4);

    runtime.beginChildPaste();
    for ("XYZ\x1b[201~") |byte| {
        try std.testing.expect(try runtime.consumeChildPasteByte(alloc, byte));
    }
    try std.testing.expect(runtime.settleManagerPasteDeliveryEpoch(alloc));

    try std.testing.expectEqualStrings("aXYZe", runtime.child.editor.edit_state.input.items);
    try std.testing.expect(runtime.child.editor.edit_state.selectionRange() == null);
    try std.testing.expect(try runtime.child.editor.undoState().undo(alloc));
    try std.testing.expectEqualStrings("abcde", runtime.child.editor.edit_state.input.items);
}

test "child and form paste settlement reject unsafe suffixes without mutating drafts" {
    const alloc = std.testing.allocator;

    {
        var runtime = Runtime{};
        defer runtime.deinit(alloc);
        try std.testing.expect(try runtime.replaceSnapshot(
            alloc,
            try testSnapshot(alloc, 1, &.{"child"}),
        ));
        try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .enter));
        try runtime.installChildChat(
            alloc,
            try testChildChat(alloc, runtime.routedNode().?),
            false,
            true,
        );
        try runtime.child.editor.insertionState().insertSlice(alloc, "keep", .preserve);
        runtime.beginChildPaste();
        for ("new\x1b[201~\r") |byte| {
            try std.testing.expect(try runtime.consumeChildPasteByte(alloc, byte));
        }

        try std.testing.expect(runtime.settleManagerPasteDeliveryEpoch(alloc));
        try std.testing.expectEqualStrings("keep", runtime.child.editor.edit_state.input.items);
        try std.testing.expectEqual(
            ChildInputFailure.unsafe_paste_boundary,
            runtime.childPresentationView().?.input_failure.?,
        );
    }

    {
        var runtime = Runtime{};
        defer runtime.deinit(alloc);
        try runtime.setDefaults(alloc, "test/model", types.ReasoningEffort.literal("high"));
        try std.testing.expect(try runtime.replaceSnapshot(
            alloc,
            try testSnapshot(alloc, 1, &.{}),
        ));
        _ = try runtime.handleByte(alloc, 'c', null);
        try runtime.form.replaceEditor(alloc, .name, "keep");
        runtime.beginManagerPaste();
        for ("new\x1b[201~\r") |byte| {
            try std.testing.expect(try runtime.consumeManagerPasteByte(alloc, byte));
        }

        try std.testing.expect(runtime.settleManagerPasteDeliveryEpoch(alloc));
        try std.testing.expectEqualStrings("keep", runtime.form.editors[0].edit_state.input.items);
        try std.testing.expectEqual(
            FormValidationFailure.unsafe_paste_boundary,
            runtime.form.attempt.failure.?.validation,
        );
    }
}

test "manager route without a composer discards paste with an observable reason" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "manager-paste.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "subagent");

    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    runtime.beginManagerPaste();
    for ("ROOT_PASTE_LEAK\x1b[201~") |byte| {
        try std.testing.expect(try runtime.consumeManagerPasteByte(alloc, byte));
    }
    try std.testing.expect(runtime.settleManagerPasteDeliveryEpoch(alloc));
    try std.testing.expect(!runtime.managerPasteActive());
    try std.testing.expectEqual(@as(usize, 0), runtime.child.editor.edit_state.input.items.len);

    debug_trace.shutdown();
    var trace_file = try std.Io.Dir.cwd().openFile(io_mod.getIo(), trace_path, .{});
    defer trace_file.close(io_mod.getIo());
    const trace = try io_mod.readFileToEnd(alloc, &trace_file, 4096);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(
        u8,
        trace,
        "manager paste dropped bytes=15 reason=route_without_composer",
    ) != null);
}

test "child paste rejects malformed UTF-8 and preserves normalized newline and tab input" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    try std.testing.expect(try runtime.replaceSnapshot(
        alloc,
        try testSnapshot(alloc, 1, &.{"child"}),
    ));
    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .enter));
    try runtime.installChildChat(
        alloc,
        try testChildChat(alloc, runtime.routedNode().?),
        false,
        true,
    );
    try runtime.child.editor.insertionState().insertSlice(alloc, "existing", .preserve);
    const cursor = runtime.child.editor.edit_state.cursor;

    runtime.beginChildPaste();
    try std.testing.expect(try runtime.consumeChildPasteByte(alloc, 0xc3));
    for ("\x1b[201~") |byte| {
        try std.testing.expect(try runtime.consumeChildPasteByte(alloc, byte));
    }
    try std.testing.expect(runtime.settleManagerPasteDeliveryEpoch(alloc));
    try std.testing.expectEqualStrings("existing", runtime.child.editor.edit_state.input.items);
    try std.testing.expectEqual(cursor, runtime.child.editor.edit_state.cursor);
    const invalid_view = runtime.childPresentationView().?;
    try std.testing.expectEqual(
        ChildInputFailure.invalid_utf8,
        invalid_view.input_failure.?,
    );
    try std.testing.expectEqualStrings(
        "Invalid UTF-8",
        childInputFailureDisplay(invalid_view.input_failure.?),
    );

    runtime.beginChildPaste();
    for ("\none\ttwo\rthree\x1b[201~") |byte| {
        try std.testing.expect(try runtime.consumeChildPasteByte(alloc, byte));
    }
    try std.testing.expect(runtime.settleManagerPasteDeliveryEpoch(alloc));
    try std.testing.expectEqualStrings("existing\none\ttwo\nthree", runtime.child.editor.edit_state.input.items);
    try std.testing.expect(std.unicode.utf8ValidateSlice(runtime.child.editor.edit_state.input.items));

    runtime.beginChildPaste();
    for ("cancelled") |byte| {
        try std.testing.expect(try runtime.consumeChildPasteByte(alloc, byte));
    }
    runtime.child.editor.paste.resetWithTrace(.session_reset);
    try std.testing.expectEqual(paste_framing.Owner.none, runtime.child.editor.paste.owner);
    try std.testing.expectEqualStrings("existing\none\ttwo\nthree", runtime.child.editor.edit_state.input.items);
}

test "child paste allocation failure stays route local and retains the draft" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    try std.testing.expect(try runtime.replaceSnapshot(
        alloc,
        try testSnapshot(alloc, 1, &.{"child"}),
    ));
    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .enter));
    try runtime.installChildChat(
        alloc,
        try testChildChat(alloc, runtime.routedNode().?),
        false,
        true,
    );
    try runtime.child.editor.insertionState().insertSlice(alloc, "existing draft", .preserve);
    const cursor = runtime.child.editor.edit_state.cursor;
    runtime.beginChildPaste();
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expect(try runtime.consumeChildPasteByte(failing.allocator(), 'x'));
    try std.testing.expectEqual(paste_framing.Owner.none, runtime.child.editor.paste.owner);
    try std.testing.expectEqualStrings("existing draft", runtime.child.editor.edit_state.input.items);
    try std.testing.expectEqual(cursor, runtime.child.editor.edit_state.cursor);
    const failed_view = runtime.childPresentationView().?;
    try std.testing.expectEqual(
        ChildInputFailure.paste_allocation_failed,
        failed_view.input_failure.?,
    );
    try std.testing.expectEqualStrings(
        "Paste allocation failed",
        childInputFailureDisplay(failed_view.input_failure.?),
    );
}

test "manager form paste allocation failure stays route local and retains the draft" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    try runtime.setDefaults(alloc, "test/model", types.ReasoningEffort.literal("high"));
    try std.testing.expect(try runtime.replaceSnapshot(
        alloc,
        try testSnapshot(alloc, 1, &.{}),
    ));
    _ = try runtime.handleByte(alloc, 'c', null);
    try runtime.form.replaceEditor(alloc, .name, "existing name");
    const cursor = runtime.form.editors[0].edit_state.cursor;
    runtime.beginManagerPaste();
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expect(try runtime.consumeManagerPasteByte(failing.allocator(), 'x'));
    try std.testing.expect(!runtime.managerPasteActive());
    try std.testing.expectEqualStrings("existing name", runtime.form.editors[0].edit_state.input.items);
    try std.testing.expectEqual(cursor, runtime.form.editors[0].edit_state.cursor);
    const rendered = try paint(
        alloc,
        &runtime,
        .{ .rows = 18, .cols = 80, .content_bottom = 14, .divider_top_row = 15, .input_row = 16, .divider_bottom_row = 17, .hint_row = 18 },
        null,
    );
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "Unable to allocate form state") != null);
}

test "child submission validates malformed and oversized drafts before host dispatch" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    try std.testing.expect(try runtime.replaceSnapshot(
        alloc,
        try testSnapshot(alloc, 1, &.{"child"}),
    ));
    try std.testing.expectEqual(Command.child_changed, try runtime.handle(alloc, .enter));
    try runtime.installChildChat(
        alloc,
        try testChildChat(alloc, runtime.routedNode().?),
        false,
        true,
    );

    try runtime.child.editor.edit_state.input.append(alloc, 0xc3);
    runtime.child.editor.edit_state.cursor = 1;
    try std.testing.expect((try runtime.prepareSubmission(alloc, 100)) == null);
    try std.testing.expectEqual(@as(usize, 1), runtime.child.editor.edit_state.input.items.len);

    runtime.child.editor.inputResetState().clearCurrent(alloc);
    const oversized = try alloc.alloc(u8, domain.max_message_bytes + 1);
    defer alloc.free(oversized);
    @memset(oversized, 'x');
    try runtime.child.editor.edit_state.input.appendSlice(alloc, oversized);
    runtime.child.editor.edit_state.cursor = oversized.len;
    try std.testing.expect((try runtime.prepareSubmission(alloc, 200)) == null);
    try std.testing.expectEqual(oversized.len, runtime.child.editor.edit_state.input.items.len);
}

fn checkChildRouteAllocationFailures(alloc: Allocator) !void {
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    _ = try runtime.replaceSnapshot(
        alloc,
        try testSnapshot(alloc, 1, &.{ "child-a", "child-b" }),
    );
    _ = try runtime.handle(alloc, .enter);
    try runtime.installChildChat(
        alloc,
        try testChildChat(alloc, runtime.routedNode().?),
        false,
        true,
    );
    for ("owned draft 🦎") |byte| _ = try runtime.handleByte(alloc, byte, null);
    _ = try runtime.prepareSubmission(alloc, 100);
    _ = try runtime.handle(alloc, .escape);
    _ = try runtime.handle(alloc, .down);
    _ = try runtime.handle(alloc, .enter);
    try runtime.installChildChat(
        alloc,
        try testChildChat(alloc, runtime.routedNode().?),
        false,
        true,
    );
}

fn checkCheckpointTwoRouteAllocationFailures(alloc: Allocator) !void {
    {
        var runtime = Runtime{};
        defer runtime.deinit(alloc);
        try runtime.setDefaults(alloc, "default/model", types.ReasoningEffort.literal("high"));
        _ = try runtime.replaceSnapshot(alloc, try testSnapshot(alloc, 1, &.{}));
        _ = try runtime.handleByte(alloc, 'c', null);
        try runtime.form.replaceEditor(alloc, .name, "allocated create");
        try runtime.form.replaceEditor(alloc, .initial_message, "start λ");
        try runtime.form.replaceEditor(alloc, .milestones, "ready, verified");
        if (try runtime.prepareManagerMutation(alloc, 10)) |prepared_value| {
            var prepared = prepared_value;
            prepared.deinit(alloc);
        }
    }
    {
        var runtime = Runtime{};
        defer runtime.deinit(alloc);
        try runtime.setDefaults(alloc, "default/model", types.ReasoningEffort.literal("medium"));
        _ = try runtime.replaceSnapshot(
            alloc,
            try configuredTestSnapshot(alloc, 1, 5, .idle),
        );
        _ = try runtime.handle(alloc, .enter);
        runtime.focus = .child_detail;
        _ = try runtime.handleByte(alloc, 's', null);
        try runtime.form.replaceEditor(alloc, .name, "allocated configure");
        if (try runtime.prepareManagerMutation(alloc, 20)) |prepared_value| {
            var prepared = prepared_value;
            prepared.deinit(alloc);
        }
    }
    {
        var runtime = Runtime{};
        defer runtime.deinit(alloc);
        _ = try runtime.replaceSnapshot(alloc, try testSnapshot(alloc, 1, &.{}));
        _ = try runtime.handleByte(alloc, 't', null);
        try runtime.installAttachPage(alloc, try testAttachPage(alloc, &.{
            .{ .id = "visible-session", .parent_id = null, .generation = 0 },
        }), false);
        if (try runtime.prepareManagerMutation(alloc, 30)) |prepared_value| {
            var prepared = prepared_value;
            prepared.deinit(alloc);
        }
    }
    {
        var runtime = Runtime{};
        defer runtime.deinit(alloc);
        _ = try runtime.replaceSnapshot(
            alloc,
            try pendingApprovalPageTestSnapshot(
                alloc,
                &.{ "approval-allocation-a", "approval-allocation-b" },
                0,
                2,
                null,
                null,
            ),
        );
        _ = try runtime.handle(alloc, .notifications);
        _ = try runtime.handle(alloc, .down);
        _ = try runtime.handleByte(alloc, '1', null);
        try std.testing.expect(runtime.prepareApprovalResolution() != null);
    }
    {
        var runtime = Runtime{};
        defer runtime.deinit(alloc);
        var snapshot = try testSnapshot(alloc, 1, &.{"running-child"});
        snapshot.nodes[0].state = .running;
        _ = try runtime.replaceSnapshot(alloc, snapshot);
        _ = try runtime.handle(alloc, .enter);
        runtime.focus = .child_detail;
        _ = try runtime.handleByte(alloc, 'x', null);
        _ = try runtime.handleByte(alloc, 'c', null);
        if (try runtime.prepareManagerMutation(alloc, 40)) |prepared_value| {
            var prepared = prepared_value;
            prepared.deinit(alloc);
        }
    }
}

test "child route switching frees partial pages drafts and operation identity" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkChildRouteAllocationFailures,
        .{},
    );
}

test "checkpoint two owned forms routes and results clean up across allocation failures" {
    var probe = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    try checkCheckpointTwoRouteAllocationFailures(probe.allocator());
    const allocation_count = probe.alloc_index;
    try std.testing.expectEqual(probe.allocated_bytes, probe.freed_bytes);

    for (0..allocation_count) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        checkCheckpointTwoRouteAllocationFailures(failing.allocator()) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        };
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "scrolling follows selected immutable ID and terminal-unsafe child text is encoded" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);
    const ids = [_][]const u8{
        "child-00", "child-01", "child-02", "child-03", "child-04",         "child-05",
        "child-06", "child-07", "child-08", "child-09", "child-10\x1b[31m",
    };
    try std.testing.expect(try runtime.replaceSnapshot(alloc, try testSnapshot(alloc, 1, &ids)));
    for (0..10) |_| _ = try runtime.handle(alloc, .down);
    try std.testing.expectEqualStrings("child-10\x1b[31m", runtime.selected_id.?);
    const rendered = try paint(
        alloc,
        &runtime,
        .{ .rows = 5, .cols = 32, .content_bottom = 1, .divider_top_row = 2, .input_row = 3, .divider_bottom_row = 4, .hint_row = 5 },
        null,
    );
    defer alloc.free(rendered);
    try std.testing.expect(runtime.list_scroll > 0);
    try std.testing.expect(std.mem.find(u8, rendered, "child-10") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "\x1b[31m") == null);
}

const TestAttachCandidate = struct {
    id: []const u8,
    title: ?[]const u8 = null,
    parent_id: ?[]const u8,
    generation: u64,
};

fn testAttachPage(
    alloc: Allocator,
    specs: []const TestAttachCandidate,
) !projection.AttachPage {
    const candidates = try alloc.alloc(projection.AttachCandidate, specs.len);
    var built: usize = 0;
    errdefer {
        for (candidates[0..built]) |*candidate| candidate.deinit(alloc);
        alloc.free(candidates);
    }
    for (specs) |spec| {
        const session_id = try alloc.dupe(u8, spec.id);
        errdefer alloc.free(session_id);
        const title = try alloc.dupe(u8, spec.title orelse spec.id);
        errdefer alloc.free(title);
        candidates[built] = .{
            .session_id = session_id,
            .title = title,
            .workspace_root = null,
            .preview = null,
            .updated_at_ms = @intCast(100 - built),
            .history_len = 1,
            .control_present = spec.parent_id != null,
            .parent_id = if (spec.parent_id) |parent_id| try alloc.dupe(u8, parent_id) else null,
            .state = .idle,
            .generation = spec.generation,
        };
        built += 1;
    }
    return .{ .candidates = candidates, .has_more = false };
}

fn configuredTestSnapshot(
    alloc: Allocator,
    revision: u64,
    generation: u64,
    state: domain.State,
) !projection.Snapshot {
    var snapshot = try testSnapshot(alloc, revision, &.{"configured-child"});
    errdefer snapshot.deinit(alloc);
    var command = try domain.validateCommand(alloc, .{ .create = .{
        .name = "configured-child",
        .mode = .persistent,
        .model = "configured/model",
        .effort = types.ReasoningEffort.literal("high"),
        .notifications = .{
            .terminal = .{ .completed = true, .failed = false, .cancelled = true },
            .milestones = &.{"verified"},
            .report_interval_ms = 1000,
            .report_duration_ms = 5000,
            .stop_conditions = &.{ .terminal, .duration_elapsed },
        },
    } });
    defer command.deinit(alloc);
    snapshot.nodes[0].configuration = try command.create.configuration.clone(alloc);
    snapshot.nodes[0].generation = generation;
    snapshot.nodes[0].state = state;
    return snapshot;
}

fn pendingApprovalTestSnapshot(
    alloc: Allocator,
    approval_id: []const u8,
) !projection.Snapshot {
    var snapshot = try testSnapshot(alloc, 1, &.{"approval-child"});
    errdefer snapshot.deinit(alloc);
    var node_approval = try testApproval(alloc, approval_id);
    errdefer node_approval.deinit(alloc);
    var pending_approval = try testApproval(alloc, approval_id);
    errdefer pending_approval.deinit(alloc);
    const child_id = try alloc.dupe(u8, "approval-child");
    errdefer alloc.free(child_id);
    const child_name = try alloc.dupe(u8, "approval-child");
    errdefer alloc.free(child_name);
    const approvals = try alloc.alloc(projection.Approval, 1);
    errdefer alloc.free(approvals);
    const pending = try alloc.alloc(projection.PendingApproval, 1);
    errdefer alloc.free(pending);
    approvals[0] = node_approval;
    pending[0] = .{
        .child_id = child_id,
        .child_name = child_name,
        .request = pending_approval,
    };
    alloc.free(snapshot.nodes[0].approvals);
    snapshot.nodes[0].approvals = approvals;
    alloc.free(snapshot.pending_approvals);
    snapshot.pending_approvals = pending;
    snapshot.approval_revision = 1;
    snapshot.pending_approval_total = 1;
    return snapshot;
}

fn pendingApprovalPageTestSnapshot(
    alloc: Allocator,
    approval_ids: []const []const u8,
    offset: usize,
    total: usize,
    previous_offset: ?usize,
    next_offset: ?usize,
) !projection.Snapshot {
    var snapshot = try testSnapshot(alloc, 1, &.{});
    errdefer snapshot.deinit(alloc);
    const pending = try alloc.alloc(projection.PendingApproval, approval_ids.len);
    var built: usize = 0;
    errdefer {
        for (pending[0..built]) |*approval| approval.deinit(alloc);
        alloc.free(pending);
    }
    for (approval_ids) |approval_id| {
        const child_id = try std.fmt.allocPrint(alloc, "child-{s}", .{approval_id});
        errdefer alloc.free(child_id);
        const child_name = try alloc.dupe(u8, child_id);
        errdefer alloc.free(child_name);
        pending[built] = .{
            .child_id = child_id,
            .child_name = child_name,
            .request = try testApproval(alloc, approval_id),
        };
        built += 1;
    }
    alloc.free(snapshot.pending_approvals);
    snapshot.pending_approvals = pending;
    snapshot.approval_revision = 1;
    snapshot.pending_approval_total = total;
    snapshot.pending_approval_offset = offset;
    snapshot.pending_approval_previous_offset = previous_offset;
    snapshot.pending_approval_next_offset = next_offset;
    return snapshot;
}

fn testApproval(alloc: Allocator, approval_id: []const u8) !projection.Approval {
    const id = try alloc.dupe(u8, approval_id);
    errdefer alloc.free(id);
    const label = try alloc.dupe(u8, "bounded approval");
    errdefer alloc.free(label);
    const explanation = try alloc.dupe(u8, "authoritative request");
    errdefer alloc.free(explanation);
    return .{
        .id = id,
        .kind = .tool,
        .status = .pending,
        .label = label,
        .explanation = explanation,
    };
}

fn testSnapshot(alloc: Allocator, revision: u64, ids: []const []const u8) !projection.Snapshot {
    const nodes = try alloc.alloc(projection.Node, ids.len);
    var built: usize = 0;
    errdefer {
        for (nodes[0..built]) |*node| node.deinit(alloc);
        alloc.free(nodes);
    }
    for (ids) |id| {
        nodes[built] = node: {
            const child_id = try alloc.dupe(u8, id);
            errdefer alloc.free(child_id);
            const parent_id = try alloc.dupe(u8, "root");
            errdefer alloc.free(parent_id);
            const name = try alloc.dupe(u8, id);
            errdefer alloc.free(name);
            const activity = try alloc.alloc(projection.Activity, 0);
            errdefer alloc.free(activity);
            const approvals = try alloc.alloc(projection.Approval, 0);
            errdefer alloc.free(approvals);
            break :node .{
                .child_id = child_id,
                .parent_id = parent_id,
                .name = name,
                .mode = .persistent,
                .state = .running,
                .generation = revision,
                .depth = 1,
                .relationship_issue = null,
                .activity = activity,
                .approvals = approvals,
            };
        };
        built += 1;
    }
    const root_id = try alloc.dupe(u8, "root");
    errdefer alloc.free(root_id);
    const diagnostics = try alloc.alloc(manager_mod.TreeDiagnostic, 0);
    errdefer alloc.free(diagnostics);
    const pending_approvals = try alloc.alloc(projection.PendingApproval, 0);
    errdefer alloc.free(pending_approvals);
    return .{
        .root_id = root_id,
        .revision = revision,
        .approval_revision = 0,
        .content_hash = revision,
        .restart_required = false,
        .nodes = nodes,
        .pending_approvals = pending_approvals,
        .next_cursor = null,
        .diagnostics = diagnostics,
        .diagnostics_truncated = false,
    };
}

fn testChildChat(alloc: Allocator, node: *const projection.Node) !projection.ChildChat {
    const child_id = try alloc.dupe(u8, node.child_id);
    errdefer alloc.free(child_id);
    const parent_id = try alloc.dupe(u8, node.parent_id);
    errdefer alloc.free(parent_id);

    var configuration = if (node.configuration) |configuration|
        try configuration.clone(alloc)
    else
        try testConfiguration(alloc, node.name);
    errdefer configuration.deinit(alloc);
    const failure_reason = if (node.failure_reason) |reason|
        try alloc.dupe(u8, reason)
    else
        null;
    errdefer if (failure_reason) |reason| alloc.free(reason);

    const messages = try alloc.alloc(projection.ChildMessage, 0);
    errdefer alloc.free(messages);
    const activity = try alloc.alloc(projection.Activity, node.activity.len);
    var activity_built: usize = 0;
    errdefer {
        for (activity[0..activity_built]) |*item| item.deinit(alloc);
        alloc.free(activity);
    }
    for (node.activity) |item| {
        activity[activity_built] = .{
            .sequence = item.sequence,
            .revision = item.revision,
            .timestamp_ms = item.timestamp_ms,
            .kind = item.kind,
            .summary = try alloc.dupe(u8, item.summary),
        };
        activity_built += 1;
    }

    const history_session_id = try alloc.dupe(u8, node.child_id);
    errdefer alloc.free(history_session_id);
    const turns = try alloc.alloc(@import("../../core/session/session.zig").HistoryTurn, 0);
    errdefer alloc.free(turns);
    const sources = try alloc.alloc(projection.OwnedTurnSource, 0);
    errdefer alloc.free(sources);

    return .{
        .child_id = child_id,
        .parent_id = parent_id,
        .mode = node.mode,
        .state = node.state,
        .generation = node.generation,
        .configuration = configuration,
        .external_busy = node.external_busy,
        .failure_reason = failure_reason,
        .messages = messages,
        .activity = activity,
        .live = null,
        .page = .{
            .history = .{
                .session_id = history_session_id,
                .revision_ms = 1,
                .history_len = 0,
                .turns = turns,
            },
            .sources = sources,
        },
    };
}

fn testConfiguration(alloc: Allocator, name_value: []const u8) !domain.Configuration {
    const name = try alloc.dupe(u8, name_value);
    errdefer alloc.free(name);
    const milestones = try alloc.alloc([]u8, 0);
    errdefer alloc.free(milestones);
    const stop_conditions = try alloc.dupe(domain.StopCondition, &.{.terminal});
    errdefer alloc.free(stop_conditions);
    return .{
        .name = name,
        .notifications = .{
            .milestones = milestones,
            .stop_conditions = stop_conditions,
        },
    };
}

fn testLivePresentation(
    alloc: Allocator,
    work_id_value: []const u8,
    text_value: []const u8,
) !execution.LivePresentation {
    return testLivePresentationWithToolCount(alloc, work_id_value, text_value, 1);
}

fn testLivePresentationWithToolCount(
    alloc: Allocator,
    work_id_value: []const u8,
    text_value: []const u8,
    tool_count: usize,
) !execution.LivePresentation {
    const work_id = try alloc.dupe(u8, work_id_value);
    errdefer alloc.free(work_id);
    const text_value_owned = try alloc.dupe(u8, text_value);
    errdefer alloc.free(text_value_owned);
    const tools = try alloc.alloc(execution.LiveToolActivity, tool_count);
    var tools_built: usize = 0;
    errdefer {
        for (tools[0..tools_built]) |*tool| tool.deinit(alloc);
        alloc.free(tools);
    }
    for (tools) |*tool| {
        tool.* = .{
            .tool_name = try alloc.dupe(u8, "read_file"),
            .phase = .started,
        };
        tools_built += 1;
    }
    return .{
        .work_id = work_id,
        .revision = 1,
        .text = text_value_owned,
        .text_truncated = false,
        .tools = tools,
        .tools_truncated = false,
        .events = try alloc.alloc(worker_runtime.WorkerEvent, 0),
        .events_truncated = false,
    };
}

fn testLivePresentationWithRichTextEvent(
    alloc: Allocator,
    work_id_value: []const u8,
    text_value: []const u8,
) !execution.LivePresentation {
    var live = try testLivePresentation(
        alloc,
        work_id_value,
        text_value,
    );
    errdefer live.deinit(alloc);
    const events = try alloc.alloc(worker_runtime.WorkerEvent, 1);
    errdefer alloc.free(events);
    events[0] = try worker_runtime.dupeWorkerEvent(
        alloc,
        .{ .assistant_presentation = .{ .text = @constCast(text_value) } },
    );
    alloc.free(live.events);
    live.events = events;
    return live;
}
