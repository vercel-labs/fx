const std = @import("std");
const secret = @import("../auth/secret.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const diff_mod = @import("../output/diff.zig");
const file_mutation_contract = @import("../tooling/file_mutation_contract.zig");
const image_attachments = @import("../images/image_attachments.zig");
const context_contract = @import("../workspace/context_contract.zig");
const auto_classifier_context = @import("../permissions/auto_classifier_context.zig");
const permission_request = @import("../permissions/permission_request.zig");
const notification_contract = @import("../notifications/notification_contract.zig");
const session_runtime = @import("../session/session.zig");
const session_codec = @import("../session/session_codec.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const tool_result_limits = @import("../tooling/tool_result_limits.zig");
const command_output_content = @import("../tooling/command_output_content.zig");
const paste_blocks = @import("../input/pasted_blocks.zig");
const entity_spans = @import("../shared/entity_spans.zig");
const types = @import("../shared/types.zig");
const model_provider = @import("../config/model_provider.zig");
const assistant_presentation = @import("assistant_presentation.zig");

pub const AgentTurnSettings = struct {
    max_tool_result_bytes: usize = tool_result_limits.default_max_tool_result_bytes,
    first_call_tool_choice: types.ToolChoice = .auto,
    fast_mode: bool = false,
    effort: types.ReasoningEffort = .auto,
};

pub const SkillBinding = struct {
    name: []u8,
    path: []u8,
};

pub const SkillDisplaySpan = struct {
    raw_start: usize,
    raw_end: usize,
    name: []u8,
    path: []u8,
    display_source: ?skill_contract.SkillSource = null,
    owns_trailing_separator: bool = false,
};

pub const BeginPromptWithSkillBindings = struct {
    prompt: types.UserTurn,
    skill_bindings: []SkillBinding = &.{},
    skill_display_spans: []SkillDisplaySpan = &.{},
};

pub const QueueReviewDraft = struct {
    input: []u8,
    pasted_blocks: []paste_blocks.PastedBlock = &.{},
    image_tokens: []entity_spans.ImageTokenSpan = &.{},
    skill_display_spans: []SkillDisplaySpan = &.{},
};

pub const QueuedPrompt = struct {
    turn_id: u64 = 0,
    prompt: []u8,
    images: []types.ImageAttachment,
    authorized_image_catalog: []types.ImageAttachment = &.{},
    model: []u8,
    provider: model_provider.ProviderId = .gateway,
    api_key: []u8,
    gateway_team: ?[]u8 = null,
    credential_source: ?types.CredentialSource = null,
    account_id: ?[]u8 = null,
    permission_mode: types.PermissionMode,
    history: []types.HistoryTurn,
    root_user_intent_context: []u8 = &.{},
    grants: []types.PermissionGrant,
    skill_bindings: []SkillBinding = &.{},
    skill_display_spans: []SkillDisplaySpan = &.{},
    review_draft: ?QueueReviewDraft = null,
    context_snapshot: context_contract.GatheredContextSnapshot = .{},
    agent_settings: AgentTurnSettings = .{},
    snapshot_file_ownerships: []types.SnapshotFileOwnership = &.{},
    /// Present only when an explicit host action resumes a durable paused
    /// model turn. The same ownership rules as the other queued fields apply.
    recovery_checkpoint: ?session_codec.RecoveryCheckpoint = null,
    /// True when this output surface already contains the checkpoint's
    /// assistant source. Recovery still restores the source for overlap and
    /// persistence, but publishes only novel continuation text.
    recovery_source_already_presented: bool = false,
};

pub const ActivePromptSnapshotOwnership = struct {
    images: []const types.ImageAttachment,
    state: enum {
        active,
        handed_off,
        discarded,
    } = .active,
    shared_ownership: ?types.SnapshotFileOwnership = null,

    pub fn init(images: []const types.ImageAttachment) ActivePromptSnapshotOwnership {
        return .{ .images = images };
    }

    fn ensureSharedOwnership(
        self: *ActivePromptSnapshotOwnership,
        alloc: std.mem.Allocator,
    ) !?types.SnapshotFileOwnership {
        if (self.images.len == 0) return null;
        if (self.shared_ownership) |ownership| return ownership;
        const ownership = (try SnapshotFileOwnershipState.create(alloc, self.images)).handle();
        self.shared_ownership = ownership;
        return ownership;
    }

    fn handoff(
        self: *ActivePromptSnapshotOwnership,
        alloc: std.mem.Allocator,
    ) !?types.SnapshotFileOwnership {
        if (self.state != .active or self.images.len == 0) return null;
        const ownership = (try self.ensureSharedOwnership(alloc)).?;
        self.state = .handed_off;
        return ownership;
    }

    fn deinit(self: *ActivePromptSnapshotOwnership) void {
        if (self.state == .active) {
            if (self.shared_ownership) |ownership| {
                ownership.release();
            } else {
                image_attachments.deleteUnreferencedImageSnapshots(self.images, &.{});
            }
            self.state = .discarded;
        }
    }
};

const SnapshotFileOwnershipState = struct {
    alloc: std.mem.Allocator,
    images: []types.ImageAttachment,
    references: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),
    transferred: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn create(
        alloc: std.mem.Allocator,
        images: []const types.ImageAttachment,
    ) !*SnapshotFileOwnershipState {
        const owned_images = try types.dupeImageAttachmentSlice(alloc, images);
        errdefer types.freeImageAttachmentSlice(alloc, owned_images);
        const state = try alloc.create(SnapshotFileOwnershipState);
        state.* = .{
            .alloc = alloc,
            .images = owned_images,
        };
        return state;
    }

    fn handle(self: *SnapshotFileOwnershipState) types.SnapshotFileOwnership {
        return .{
            .ctx = self,
            .retain_fn = retain,
            .release_fn = release,
            .transfer_fn = transfer,
        };
    }

    fn retain(raw: *anyopaque) void {
        const self: *SnapshotFileOwnershipState = @ptrCast(@alignCast(raw));
        _ = self.references.fetchAdd(1, .seq_cst);
    }

    fn release(raw: *anyopaque) void {
        const self: *SnapshotFileOwnershipState = @ptrCast(@alignCast(raw));
        if (self.references.fetchSub(1, .seq_cst) != 1) return;
        if (!self.transferred.load(.seq_cst)) {
            image_attachments.deleteUnreferencedImageSnapshots(self.images, &.{});
        }
        const alloc = self.alloc;
        types.freeImageAttachmentSlice(alloc, self.images);
        alloc.destroy(self);
    }

    fn transfer(raw: *anyopaque) void {
        const self: *SnapshotFileOwnershipState = @ptrCast(@alignCast(raw));
        self.transferred.store(true, .seq_cst);
    }
};

pub const PermissionSnapshot = struct {
    mode: types.PermissionMode,
};

pub const CommandOutputChunk = struct {
    lifecycle_id: ?types.ToolLifecycleId = null,
    stream: command_output_content.Stream,
    text: []u8,
};

pub const QueuePreview = struct {
    count: usize = 0,
    paused: bool = false,
};

pub const QueueReviewReason = enum {
    manual,
    post_cancel,
};

pub const QueuedPromptDraft = struct {
    turn_id: u64,
    prompt: []u8,
    images: []types.ImageAttachment,
    skill_display_spans: []SkillDisplaySpan,
    review_draft: ?QueueReviewDraft = null,

    pub fn reviewInput(self: QueuedPromptDraft) []const u8 {
        return if (self.review_draft) |review| review.input else self.prompt;
    }

    pub fn reviewSkillDisplaySpans(
        self: QueuedPromptDraft,
    ) []const SkillDisplaySpan {
        return if (self.review_draft) |review|
            review.skill_display_spans
        else
            self.skill_display_spans;
    }
};

const PreparedQueuedPromptDraft = struct {
    turn_id: u64,
    prompt: []u8,
    images: []types.ImageAttachment,
    authorized_image_catalog: []types.ImageAttachment,
    skill_bindings: []SkillBinding,
    skill_display_spans: []SkillDisplaySpan,
    review_draft: ?QueueReviewDraft,
};

const PreparedHistoryPropagation = struct {
    history: []types.HistoryTurn,
    root_user_intent_context: []u8,
    authorized_image_catalog: []types.ImageAttachment,
    snapshot_file_ownerships: ?[]types.SnapshotFileOwnership,
    added_snapshot_ownership: ?types.SnapshotFileOwnership,

    fn deinit(self: PreparedHistoryPropagation, alloc: std.mem.Allocator) void {
        types.freeHistoryTurnSlice(alloc, self.history);
        alloc.free(self.root_user_intent_context);
        types.freeImageAttachmentSlice(alloc, self.authorized_image_catalog);
        if (self.added_snapshot_ownership) |ownership| ownership.release();
        if (self.snapshot_file_ownerships) |ownerships| alloc.free(ownerships);
    }
};

pub fn freeQueuedPromptDraft(alloc: std.mem.Allocator, draft: QueuedPromptDraft) void {
    alloc.free(draft.prompt);
    types.freeImageAttachmentSlice(alloc, draft.images);
    freeSkillDisplaySpans(alloc, draft.skill_display_spans);
    freeQueueReviewDraftOpt(alloc, draft.review_draft);
}

pub fn freeQueuedPromptDrafts(alloc: std.mem.Allocator, drafts: []QueuedPromptDraft) void {
    for (drafts) |draft| freeQueuedPromptDraft(alloc, draft);
    if (drafts.len > 0) alloc.free(drafts);
}

pub fn dupeQueueReviewDraft(
    alloc: std.mem.Allocator,
    draft: QueueReviewDraft,
) !QueueReviewDraft {
    const input = try alloc.dupe(u8, draft.input);
    errdefer alloc.free(input);

    const pasted_blocks: []paste_blocks.PastedBlock = if (draft.pasted_blocks.len > 0)
        try alloc.alloc(paste_blocks.PastedBlock, draft.pasted_blocks.len)
    else
        @constCast(&.{});
    var pasted_count: usize = 0;
    errdefer {
        for (pasted_blocks[0..pasted_count]) |block| alloc.free(block.text);
        if (pasted_blocks.len > 0) alloc.free(pasted_blocks);
    }
    while (pasted_count < draft.pasted_blocks.len) : (pasted_count += 1) {
        pasted_blocks[pasted_count] = .{
            .id = draft.pasted_blocks[pasted_count].id,
            .text = try alloc.dupe(u8, draft.pasted_blocks[pasted_count].text),
            .line_count = draft.pasted_blocks[pasted_count].line_count,
            .span = draft.pasted_blocks[pasted_count].span,
        };
    }

    const image_tokens: []entity_spans.ImageTokenSpan = if (draft.image_tokens.len > 0)
        try alloc.dupe(entity_spans.ImageTokenSpan, draft.image_tokens)
    else
        @constCast(&.{});
    errdefer if (image_tokens.len > 0) alloc.free(image_tokens);

    const skill_display_spans = try dupeSkillDisplaySpans(
        alloc,
        draft.skill_display_spans,
    );
    return .{
        .input = input,
        .pasted_blocks = pasted_blocks,
        .image_tokens = image_tokens,
        .skill_display_spans = skill_display_spans,
    };
}

pub fn freeQueueReviewDraft(
    alloc: std.mem.Allocator,
    draft: QueueReviewDraft,
) void {
    alloc.free(draft.input);
    for (draft.pasted_blocks) |block| alloc.free(block.text);
    if (draft.pasted_blocks.len > 0) alloc.free(draft.pasted_blocks);
    if (draft.image_tokens.len > 0) alloc.free(draft.image_tokens);
    freeSkillDisplaySpans(alloc, draft.skill_display_spans);
}

fn freeQueueReviewDraftOpt(
    alloc: std.mem.Allocator,
    draft: ?QueueReviewDraft,
) void {
    if (draft) |owned| freeQueueReviewDraft(alloc, owned);
}

fn freePreparedQueuedPromptDraft(alloc: std.mem.Allocator, draft: PreparedQueuedPromptDraft) void {
    alloc.free(draft.prompt);
    types.freeImageAttachmentSlice(alloc, draft.images);
    types.freeImageAttachmentSlice(alloc, draft.authorized_image_catalog);
    freeSkillBindings(alloc, draft.skill_bindings);
    freeSkillDisplaySpans(alloc, draft.skill_display_spans);
    freeQueueReviewDraftOpt(alloc, draft.review_draft);
}

fn skillBindingsFromDisplaySpans(
    alloc: std.mem.Allocator,
    spans: []const SkillDisplaySpan,
) ![]SkillBinding {
    var bindings: std.ArrayList(SkillBinding) = .empty;
    errdefer {
        for (bindings.items) |binding| {
            alloc.free(binding.name);
            alloc.free(binding.path);
        }
        bindings.deinit(alloc);
    }
    for (spans) |span| {
        var already_present = false;
        for (bindings.items) |binding| {
            if (std.mem.eql(u8, binding.path, span.path)) {
                already_present = true;
                break;
            }
        }
        if (already_present) continue;

        const name = try alloc.dupe(u8, span.name);
        errdefer alloc.free(name);
        const path = try alloc.dupe(u8, span.path);
        errdefer alloc.free(path);
        try bindings.append(alloc, .{ .name = name, .path = path });
    }
    if (bindings.items.len == 0) {
        bindings.deinit(alloc);
        return &.{};
    }
    return bindings.toOwnedSlice(alloc);
}

pub const StateSnapshot = struct {
    processing: bool = false,
    active_turn_id: u64 = 0,
    queued_count: usize = 0,
    pending_event_count: usize = 0,
    queue_review_reason: ?QueueReviewReason = null,
    cancel_requested: bool = false,
    pending_permission_request: ?permission_request.OwnedPermissionRequest = null,
    pending_permission_review: ?PendingPermissionReview = null,

    pub fn deinit(self: StateSnapshot, alloc: std.mem.Allocator) void {
        if (self.pending_permission_request) |request| {
            var owned = request;
            owned.deinit(alloc);
        }
    }
};

pub const PendingPermissionReview = struct {
    request_id: u64,
    review: *const diff_mod.FileReview,
};

pub const FinalizationFailure = struct {
    turn_id: u64,
    outcome: types.TurnPresentationOutcome,
};

pub const InteractiveAdmissionSnapshot = union(enum) {
    open,
    stopped,
    finalization_failed: FinalizationFailure,
};

pub const PermissionSubmissionResult = enum {
    accepted,
    stale,
    no_pending,
};

const OwnedQuestionOption = struct {
    label: []u8,
    description: ?[]u8 = null,
};

const OwnedQuestionEntry = struct {
    question: []u8,
    options: []OwnedQuestionOption,
};

pub const QuestionPromptSource = enum {
    agent_question,
    route_recovery,
    mcp_elicitation,
};

const OwnedQuestionBatch = struct {
    entries: []OwnedQuestionEntry,
    source: QuestionPromptSource = .agent_question,
};

const QuestionResponse = union(enum) {
    pending,
    cancelled,
    answered: [][]u8,
};

pub const PendingQuestionBatchSnapshot = struct {
    entries: []types.QuestionBatchEntry,
    source: QuestionPromptSource = .agent_question,

    pub fn deinit(self: PendingQuestionBatchSnapshot, alloc: std.mem.Allocator) void {
        for (self.entries) |entry| {
            alloc.free(@constCast(entry.question));
            for (entry.options) |opt| {
                alloc.free(@constCast(opt.label));
                if (opt.description) |desc| alloc.free(@constCast(desc));
            }
            alloc.free(@constCast(entry.options));
        }
        alloc.free(self.entries);
    }
};

pub const WorkerEvent = union(enum) {
    begin_prompt: types.UserTurn,
    begin_prompt_with_skill_bindings: BeginPromptWithSkillBindings,
    append_user_feedback: []u8,
    assistant_presentation: assistant_presentation.Event,
    notification: notification_contract.Notification,
    question_requested,
    open_model_picker,
    semantic_notice: types.SemanticNotice,
    route_recovery_status: types.RouteRecoveryStatus,
    clear_route_recovery_status,
    api_status_text: []u8,
    command_output: CommandOutputChunk,
    command_output_complete: ?types.ToolLifecycleId,
    tool_lifecycle: types.ToolLifecycleEvent,
    turn_token_update: types.TurnTokenProgress,
    /// A tool call that publishes no status row of its own began streaming its
    /// arguments. The turn is working, with nothing to print until it lands.
    tool_payload_started,
    diff_block: diff_mod.DiffEntryPayload,
    finish_prompt: types.FinishedPrompt,
    session_grant: types.PermissionGrant,
    error_text: types.SemanticNotice,
};

pub const WorkerEventBatch = struct {
    events: std.ArrayList(WorkerEvent),
    cancel_requested: bool,
};

pub const WorkerRuntime = struct {
    worker_mutex: std.Io.Mutex = .init,
    worker_cond: std.Io.Condition = .init,
    queued_prompts: std.ArrayList(QueuedPrompt) = .empty,
    worker_events: std.ArrayList(WorkerEvent) = .empty,
    worker_processing: bool = false,
    active_turn_id: u64 = 0,
    worker_stop_requested: bool = false,
    finalization_failure: ?FinalizationFailure = null,
    worker_cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    worker_recovery_pause_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    worker_connectivity_wait_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Set under `worker_mutex` once the active turn publishes its terminal
    /// recovery pause. The turn may still be finalizing, but cannot perform
    /// more model work, so one continuation may queue before processing clears.
    recovery_continuation_ready: bool = false,
    queued_prompt_count: usize = 0,
    /// `null` means admission is open; otherwise queue take is paused for review.
    queue_admission: ?QueueReviewReason = null,
    /// When true, `waitAndTakeNextPrompt` will not start a turn.
    turn_start_held: bool = false,
    next_permission_request_id: u64 = 1,
    pending_permission_response: ?permission_request.OwnedPermissionResponse = null,
    pending_permission_request_shared: ?permission_request.OwnedPermissionRequest = null,
    pending_permission_review: ?*const diff_mod.FileReview = null,
    pending_permission_waiting: bool = false,
    pending_question_shared: ?OwnedQuestionBatch = null,
    pending_question_response: QuestionResponse = .pending,
    agent_turn_settings: AgentTurnSettings = .{},
    active_agent_turn_settings: ?AgentTurnSettings = null,
    active_permission_snapshot: ?PermissionSnapshot = null,
    active_context_snapshot: ?*const context_contract.GatheredContextSnapshot = null,
    active_prompt_snapshot_ownership: ?*ActivePromptSnapshotOwnership = null,

    pub fn deinit(self: *WorkerRuntime, alloc: std.mem.Allocator) void {
        if (self.pending_permission_response) |response| {
            self.discardPermissionResponse(response, "deinit");
        }
        self.pending_permission_response = null;
        if (self.pending_permission_request_shared) |*request| request.deinit(alloc);
        self.pending_permission_request_shared = null;
        self.pending_permission_review = null;
        freeOwnedQuestionBatchOpt(alloc, self.pending_question_shared);
        self.pending_question_shared = null;
        freeQuestionResponse(alloc, self.pending_question_response);
        self.pending_question_response = .pending;

        for (self.queued_prompts.items) |prompt| discardQueuedPrompt(alloc, prompt, &.{});
        self.queued_prompts.deinit(alloc);

        for (self.worker_events.items) |event| freeWorkerEvent(alloc, event);
        self.worker_events.deinit(alloc);
    }

    pub fn requestStop(self: *WorkerRuntime) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        self.worker_stop_requested = true;
        self.worker_cond.broadcast(io_mod.getIo());
        self.worker_mutex.unlock(io_mod.getIo());
    }

    pub fn requestShutdown(self: *WorkerRuntime) void {
        self.worker_cancel_requested.store(true, .seq_cst);
        self.requestStop();
    }

    pub fn requestCancel(self: *WorkerRuntime) void {
        debug_trace.logf("worker", "cancel requested processing={s} queued={d}", .{ if (self.worker_processing) "true" else "false", self.queuedPromptCount() });
        debug_trace.eventf("interrupt", "cancel_requested", .{}, "processing={s} queued={d} active_tool_known=false", .{ if (self.worker_processing) "true" else "false", self.queuedPromptCount() });
        self.worker_cancel_requested.store(true, .seq_cst);
    }

    /// Interrupt the current gateway wait while preserving its recovery
    /// checkpoint. The ordinary cancel flag wakes the existing socket watcher;
    /// agent policy distinguishes the typed pause flag at the boundary.
    pub fn requestRecoveryPause(self: *WorkerRuntime) void {
        debug_trace.eventf("recovery", "pause_requested", .{}, "source=interactive_try_later", .{});
        self.worker_recovery_pause_requested.store(true, .seq_cst);
        self.worker_cancel_requested.store(true, .seq_cst);
    }

    pub fn requestCancelWithQueueReview(self: *WorkerRuntime) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        const paused = self.beginQueueReviewLocked(.post_cancel);
        debug_trace.logf("worker", "cancel requested processing={s} queued={d} queue_paused={s}", .{
            if (self.worker_processing) "true" else "false",
            self.queued_prompt_count,
            if (paused) "true" else "false",
        });
        debug_trace.eventf("interrupt", "cancel_requested", .{}, "processing={s} queued={d} queue_paused={s} active_tool_known=false", .{
            if (self.worker_processing) "true" else "false",
            self.queued_prompt_count,
            if (paused) "true" else "false",
        });
        self.worker_cancel_requested.store(true, .seq_cst);
        return paused;
    }

    pub fn cancelApprovalTurn(self: *WorkerRuntime) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        _ = self.beginQueueReviewLocked(.post_cancel);
        self.worker_cancel_requested.store(true, .seq_cst);
        _ = self.resolvePendingPermissionLocked(
            permission_request.OwnedPermissionResponse.init(
                std.heap.c_allocator,
                .deny,
                null,
            ),
        );
    }

    pub fn isCancelRequested(self: *const WorkerRuntime) bool {
        return self.worker_cancel_requested.load(.seq_cst);
    }

    pub fn isConnectivityWaitActive(self: *const WorkerRuntime) bool {
        return self.worker_connectivity_wait_active.load(.seq_cst);
    }

    pub fn pushEvent(self: *WorkerRuntime, alloc: std.mem.Allocator, event: WorkerEvent) !void {
        const owned = try dupeWorkerEvent(alloc, event);
        errdefer freeWorkerEvent(alloc, owned);
        try self.pushOwnedEvent(alloc, owned);
    }

    /// Transfers an already-owned event into the queue on success.
    /// Every heap payload in `event` must have been allocated by `alloc`.
    pub fn pushOwnedEvent(self: *WorkerRuntime, alloc: std.mem.Allocator, event: WorkerEvent) !void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        try self.worker_events.append(alloc, event);
        self.applyRecoveryStateEvent(event);
        self.worker_cond.broadcast(io_mod.getIo());
    }

    /// Transfers already-owned events to the front of the queue on success.
    /// Every heap payload must have been allocated by `alloc`.
    pub fn prependOwnedEvents(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        events: []const WorkerEvent,
    ) !void {
        if (events.len == 0) return;
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        try self.worker_events.insertSlice(alloc, 0, events);
        self.worker_cond.broadcast(io_mod.getIo());
    }

    pub fn pushTurnFinished(self: *WorkerRuntime, alloc: std.mem.Allocator, event: types.TurnFinished) !void {
        std.debug.assert(event.turn_id != 0);

        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.worker_events.append(alloc, .{ .tool_lifecycle = .{
            .turn_finished = event,
        } }) catch {
            self.latchFinalizationFailureLocked(.{
                .turn_id = event.turn_id,
                .outcome = event.outcome,
            });
            return error.TurnFinalizationDeliveryFailed;
        };
        self.applyRecoveryStateEvent(.{ .tool_lifecycle = .{
            .turn_finished = event,
        } });
        self.worker_cond.broadcast(io_mod.getIo());
    }

    fn applyRecoveryStateEvent(self: *WorkerRuntime, event: WorkerEvent) void {
        switch (event) {
            .route_recovery_status => |status| {
                self.worker_connectivity_wait_active.store(
                    status.action == .waiting_for_connectivity,
                    .seq_cst,
                );
                self.recovery_continuation_ready = status.action == .paused;
            },
            .clear_route_recovery_status,
            .finish_prompt,
            .error_text,
            => {
                self.worker_connectivity_wait_active.store(false, .seq_cst);
                self.recovery_continuation_ready = false;
            },
            .tool_lifecycle => |lifecycle| switch (lifecycle) {
                .turn_finished => self.worker_connectivity_wait_active.store(false, .seq_cst),
                .provisional, .authoritative_started, .progress, .terminal => return,
            },
            else => return,
        }
    }

    pub fn latchFinalizationFailure(self: *WorkerRuntime, failure: FinalizationFailure) void {
        std.debug.assert(failure.turn_id != 0);

        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.latchFinalizationFailureLocked(failure);
    }

    fn latchFinalizationFailureLocked(self: *WorkerRuntime, failure: FinalizationFailure) void {
        if (self.finalization_failure == null) {
            self.finalization_failure = failure;
        } else {
            debug_trace.logf(
                "worker",
                "duplicate finalization failure ignored turn_id={d} first_turn_id={d}",
                .{ failure.turn_id, self.finalization_failure.?.turn_id },
            );
        }
        self.worker_stop_requested = true;
        self.worker_cancel_requested.store(true, .seq_cst);
        self.worker_cond.broadcast(io_mod.getIo());
    }

    pub fn interactiveAdmissionSnapshot(self: *WorkerRuntime) InteractiveAdmissionSnapshot {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        if (self.finalization_failure) |failure| {
            return .{ .finalization_failed = failure };
        }
        if (self.worker_stop_requested) return .stopped;
        return .open;
    }

    pub fn takeEventBatch(self: *WorkerRuntime) WorkerEventBatch {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        const events = self.worker_events;
        self.worker_events = .empty;
        return .{
            .events = events,
            .cancel_requested = self.worker_cancel_requested.load(.seq_cst),
        };
    }

    pub fn takeEvents(self: *WorkerRuntime) std.ArrayList(WorkerEvent) {
        return self.takeEventBatch().events;
    }

    pub fn enqueuePrompt(self: *WorkerRuntime, alloc: std.mem.Allocator, prompt: QueuedPrompt) !void {
        var queued = prompt;
        if (queued.turn_id == 0) queued.turn_id = debug_trace.nextTurnId();

        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.finalization_failure != null) return error.TurnFinalizationDeliveryFailed;
        if (self.worker_stop_requested) return error.WorkerStopped;
        if (queued.recovery_checkpoint != null and
            !recoveryContinuationAdmission(
                self.worker_processing,
                self.queued_prompt_count,
                self.recovery_continuation_ready,
            ))
        {
            return error.RecoveryBusy;
        }
        queued.agent_settings = self.agent_turn_settings;
        try self.queued_prompts.append(alloc, queued);
        self.queued_prompt_count += 1;
        debug_trace.logf(
            "worker",
            "queued prompt bytes={d} queue_depth={d} fast_mode={s} effort={s}",
            .{ queued.prompt.len, self.queued_prompt_count, if (queued.agent_settings.fast_mode) "true" else "false", queued.agent_settings.effort.label() },
        );
        debug_trace.eventf(
            "worker",
            "prompt_enqueue",
            .{ .turn_id = queued.turn_id },
            "prompt_bytes={d} queue_depth={d} fast_mode={s} effort={s}",
            .{ queued.prompt.len, self.queued_prompt_count, if (queued.agent_settings.fast_mode) "true" else "false", queued.agent_settings.effort.label() },
        );
        self.worker_cond.broadcast(io_mod.getIo());
    }

    pub fn beginQueueReview(self: *WorkerRuntime, reason: QueueReviewReason) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return self.beginQueueReviewLocked(reason);
    }

    fn beginQueueReviewLocked(self: *WorkerRuntime, reason: QueueReviewReason) bool {
        if (self.queued_prompts.items.len == 0) return false;
        if (self.queue_admission) |current| {
            if (reason == .post_cancel and current != .post_cancel) {
                self.queue_admission = .post_cancel;
            }
        } else {
            self.queue_admission = reason;
            debug_trace.logf("worker", "queue review started reason={s} queued={d}", .{ @tagName(reason), self.queued_prompt_count });
            debug_trace.eventf("worker", "queue_review_started", .{}, "reason={s} queued={d}", .{ @tagName(reason), self.queued_prompt_count });
        }
        self.worker_cond.broadcast(io_mod.getIo());
        return true;
    }

    pub fn queueReviewReason(self: *WorkerRuntime) ?QueueReviewReason {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return self.queue_admission;
    }

    pub fn resumeQueueReview(self: *WorkerRuntime) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        const reason = self.queue_admission orelse return false;
        self.queue_admission = null;
        debug_trace.logf("worker", "queue review resumed reason={s} queued={d}", .{ @tagName(reason), self.queued_prompt_count });
        debug_trace.eventf("worker", "queue_review_resumed", .{}, "reason={s} queued={d}", .{ @tagName(reason), self.queued_prompt_count });
        self.worker_cond.broadcast(io_mod.getIo());
        return true;
    }

    /// Hold turn admission only when no turn is active or queued.
    pub fn tryHoldTurnStart(self: *WorkerRuntime) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.worker_processing or self.queued_prompt_count > 0 or self.turn_start_held) {
            return false;
        }
        self.turn_start_held = true;
        debug_trace.logf("worker", "turn start hold acquired", .{});
        return true;
    }

    pub fn releaseTurnStartHold(self: *WorkerRuntime) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (!self.turn_start_held) return;
        self.turn_start_held = false;
        debug_trace.logf("worker", "turn start hold released", .{});
        self.worker_cond.broadcast(io_mod.getIo());
    }

    pub fn snapshotQueuedPromptDrafts(self: *WorkerRuntime, alloc: std.mem.Allocator) ![]QueuedPromptDraft {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        if (self.queued_prompts.items.len == 0) return &.{};
        const drafts = try alloc.alloc(QueuedPromptDraft, self.queued_prompts.items.len);
        var filled: usize = 0;
        errdefer {
            for (drafts[0..filled]) |draft| freeQueuedPromptDraft(alloc, draft);
            alloc.free(drafts);
        }
        while (filled < self.queued_prompts.items.len) : (filled += 1) {
            const queued = self.queued_prompts.items[filled];
            const prompt = try alloc.dupe(u8, queued.prompt);
            errdefer alloc.free(prompt);
            const images = try types.dupeImageAttachmentSlice(alloc, queued.images);
            errdefer types.freeImageAttachmentSlice(alloc, images);
            const skill_display_spans = try dupeSkillDisplaySpans(alloc, queued.skill_display_spans);
            errdefer freeSkillDisplaySpans(alloc, skill_display_spans);
            const review_draft = if (queued.review_draft) |review|
                try dupeQueueReviewDraft(alloc, review)
            else
                null;
            drafts[filled] = .{
                .turn_id = queued.turn_id,
                .prompt = prompt,
                .images = images,
                .skill_display_spans = skill_display_spans,
                .review_draft = review_draft,
            };
        }
        return drafts;
    }

    pub fn replaceQueuedPromptDrafts(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        drafts: []const QueuedPromptDraft,
    ) !bool {
        if (drafts.len == 0) return true;

        const prepared = try alloc.alloc(PreparedQueuedPromptDraft, drafts.len);
        var prepared_count: usize = 0;
        var partial_cleanup = true;
        errdefer if (partial_cleanup) {
            for (prepared[0..prepared_count]) |replacement| freePreparedQueuedPromptDraft(alloc, replacement);
            alloc.free(prepared);
        };
        while (prepared_count < drafts.len) : (prepared_count += 1) {
            const draft = drafts[prepared_count];
            const prompt = try alloc.dupe(u8, draft.prompt);
            errdefer alloc.free(prompt);
            const images = try types.dupeImageAttachmentSlice(alloc, draft.images);
            errdefer types.freeImageAttachmentSlice(alloc, images);
            const skill_bindings = try skillBindingsFromDisplaySpans(alloc, draft.skill_display_spans);
            errdefer freeSkillBindings(alloc, skill_bindings);
            const skill_display_spans = try dupeSkillDisplaySpans(alloc, draft.skill_display_spans);
            errdefer freeSkillDisplaySpans(alloc, skill_display_spans);
            const review_draft = if (draft.review_draft) |review|
                try dupeQueueReviewDraft(alloc, review)
            else
                null;
            prepared[prepared_count] = .{
                .turn_id = draft.turn_id,
                .prompt = prompt,
                .images = images,
                .authorized_image_catalog = &.{},
                .skill_bindings = skill_bindings,
                .skill_display_spans = skill_display_spans,
                .review_draft = review_draft,
            };
        }
        partial_cleanup = false;
        defer {
            for (prepared) |replacement| freePreparedQueuedPromptDraft(alloc, replacement);
            alloc.free(prepared);
        }

        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.queue_admission == null) return false;

        for (prepared, 0..) |replacement, replacement_index| {
            for (prepared[0..replacement_index]) |prior| {
                if (prior.turn_id == replacement.turn_id) return false;
            }
            var found = false;
            for (self.queued_prompts.items) |queued| {
                if (queued.turn_id == replacement.turn_id) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }

        for (prepared) |*replacement| {
            for (self.queued_prompts.items) |queued| {
                if (queued.turn_id != replacement.turn_id) continue;
                replacement.authorized_image_catalog = try session_runtime.replace_image_catalog_current_images(
                    alloc,
                    queued.authorized_image_catalog,
                    queued.images,
                    replacement.images,
                );
                break;
            }
        }

        for (prepared) |*replacement| {
            for (self.queued_prompts.items) |*queued| {
                if (queued.turn_id != replacement.turn_id) continue;
                std.mem.swap([]u8, &queued.prompt, &replacement.prompt);
                std.mem.swap([]types.ImageAttachment, &queued.images, &replacement.images);
                std.mem.swap([]types.ImageAttachment, &queued.authorized_image_catalog, &replacement.authorized_image_catalog);
                std.mem.swap([]SkillBinding, &queued.skill_bindings, &replacement.skill_bindings);
                std.mem.swap([]SkillDisplaySpan, &queued.skill_display_spans, &replacement.skill_display_spans);
                std.mem.swap(?QueueReviewDraft, &queued.review_draft, &replacement.review_draft);
                image_attachments.deleteUnreferencedImageSnapshots(
                    replacement.images,
                    queued.authorized_image_catalog,
                );
                debug_trace.logf("worker", "queued prompt draft replaced turn_id={d} bytes={d}", .{ queued.turn_id, queued.prompt.len });
                debug_trace.eventf("worker", "queue_review_committed", .{ .turn_id = queued.turn_id }, "prompt_bytes={d}", .{queued.prompt.len});
                break;
            }
        }
        debug_trace.eventf("worker", "queue_review_batch_committed", .{}, "updated={d}", .{prepared.len});
        return true;
    }

    pub fn deleteQueuedPromptDraft(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        turn_id: u64,
        retained_images: []const types.ImageAttachment,
    ) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        var removed: ?QueuedPrompt = null;
        for (self.queued_prompts.items, 0..) |queued, index| {
            if (queued.turn_id != turn_id) continue;
            removed = self.queued_prompts.orderedRemove(index);
            if (self.queued_prompt_count > 0) self.queued_prompt_count -= 1;
            break;
        }
        const remaining = self.queued_prompt_count;
        self.worker_mutex.unlock(io_mod.getIo());

        const prompt = removed orelse return false;
        discardQueuedPrompt(alloc, prompt, retained_images);
        debug_trace.logf("worker", "queued prompt draft deleted turn_id={d} remaining={d}", .{ turn_id, remaining });
        debug_trace.eventf("worker", "queue_review_deleted", .{ .turn_id = turn_id }, "remaining={d}", .{remaining});
        return true;
    }

    pub fn waitAndTakeNextPrompt(self: *WorkerRuntime, alloc: std.mem.Allocator) !?QueuedPrompt {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        while ((self.queued_prompts.items.len == 0 or
            self.queue_admission != null or
            self.turn_start_held) and !self.worker_stop_requested)
        {
            self.worker_processing = false;
            self.worker_cond.wait(io_mod.getIo(), &self.worker_mutex) catch break;
        }
        return self.takeNextPromptLocked(alloc);
    }

    /// Nonblocking queue take for single-threaded hosts. Returns null while the
    /// queue is empty, paused for review, held, or stopped.
    pub fn tryTakeNextPrompt(self: *WorkerRuntime, alloc: std.mem.Allocator) !?QueuedPrompt {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.queued_prompts.items.len == 0 or
            self.queue_admission != null or
            self.turn_start_held or
            self.worker_stop_requested)
        {
            return null;
        }
        return self.takeNextPromptLocked(alloc);
    }

    fn takeNextPromptLocked(self: *WorkerRuntime, alloc: std.mem.Allocator) !?QueuedPrompt {
        if (self.worker_stop_requested or self.queued_prompts.items.len == 0) return null;

        const queued = self.queued_prompts.items[0];
        if (queued.recovery_checkpoint == null) {
            const begin_prompt = try types.dupeUserTurn(alloc, .{ .text = queued.prompt, .images = queued.images });
            errdefer types.freeUserTurn(alloc, begin_prompt);
            if (queued.skill_bindings.len > 0 or queued.skill_display_spans.len > 0) {
                const skill_bindings = try dupeSkillBindings(alloc, queued.skill_bindings);
                errdefer freeSkillBindings(alloc, skill_bindings);
                const skill_display_spans = try dupeSkillDisplaySpans(alloc, queued.skill_display_spans);
                errdefer freeSkillDisplaySpans(alloc, skill_display_spans);
                try self.worker_events.append(alloc, .{
                    .begin_prompt_with_skill_bindings = .{
                        .prompt = begin_prompt,
                        .skill_bindings = skill_bindings,
                        .skill_display_spans = skill_display_spans,
                    },
                });
            } else {
                try self.worker_events.append(alloc, .{ .begin_prompt = begin_prompt });
            }
        }

        var job = self.queued_prompts.orderedRemove(0);
        freeQueueReviewDraftOpt(alloc, job.review_draft);
        job.review_draft = null;
        if (self.queued_prompt_count > 0) self.queued_prompt_count -= 1;
        self.worker_cancel_requested.store(false, .seq_cst);
        self.worker_recovery_pause_requested.store(false, .seq_cst);
        self.worker_connectivity_wait_active.store(false, .seq_cst);
        self.recovery_continuation_ready = false;
        self.worker_processing = true;
        self.active_turn_id = job.turn_id;
        debug_trace.logf(
            "worker",
            "begin prompt bytes={d} remaining_queue={d} fast_mode={s} effort={s}",
            .{ job.prompt.len, self.queued_prompt_count, if (job.agent_settings.fast_mode) "true" else "false", job.agent_settings.effort.label() },
        );
        debug_trace.eventf(
            "worker",
            "worker_begin",
            .{ .turn_id = job.turn_id },
            "prompt_bytes={d} remaining_queue={d} cancel_reset=true fast_mode={s} effort={s}",
            .{ job.prompt.len, self.queued_prompt_count, if (job.agent_settings.fast_mode) "true" else "false", job.agent_settings.effort.label() },
        );
        return job;
    }

    pub fn finishProcessing(self: *WorkerRuntime) void {
        debug_trace.logf("worker", "finish processing queued={d}", .{self.queuedPromptCount()});
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        self.worker_processing = false;
        self.active_turn_id = 0;
        self.worker_connectivity_wait_active.store(false, .seq_cst);
        self.worker_cond.broadcast(io_mod.getIo());
        self.worker_mutex.unlock(io_mod.getIo());
    }

    pub fn waitUntilIdle(self: *WorkerRuntime) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        while (self.worker_processing) {
            self.worker_cond.wait(io_mod.getIo(), &self.worker_mutex) catch break;
        }
    }

    pub fn isProcessing(self: *WorkerRuntime) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return self.worker_processing;
    }

    pub fn snapshotState(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
    ) permission_request.RequestCloneError!StateSnapshot {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return .{
            .processing = self.worker_processing,
            .active_turn_id = self.active_turn_id,
            .queued_count = self.queued_prompt_count,
            .pending_event_count = self.worker_events.items.len,
            .queue_review_reason = self.queue_admission,
            .cancel_requested = self.worker_cancel_requested.load(.seq_cst),
            .pending_permission_request = if (self.permissionRequestAwaitingDecisionLocked()) blk: {
                const request = &self.pending_permission_request_shared.?;
                break :blk try permission_request.OwnedPermissionRequest.dupe(alloc, request.view());
            } else null,
            .pending_permission_review = if (self.permissionRequestAwaitingDecisionLocked())
                if (self.pending_permission_review) |review|
                    .{
                        .request_id = self.pending_permission_request_shared.?.id,
                        .review = review,
                    }
                else
                    null
            else
                null,
        };
    }

    pub fn activeTurnId(self: *WorkerRuntime) u64 {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return self.active_turn_id;
    }

    pub fn queuePreview(self: *WorkerRuntime) QueuePreview {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        const count = self.queued_prompts.items.len;
        if (count == 0) return .{};
        return .{
            .count = count,
            .paused = self.queue_admission != null,
        };
    }

    pub fn queuedPromptCount(self: *WorkerRuntime) usize {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return self.queued_prompt_count;
    }

    pub fn clearQueuedPrompts(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        retained_images: []const types.ImageAttachment,
    ) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        const dropped = self.queued_prompt_count;
        if (dropped > 0) {
            debug_trace.logf("worker", "clear queued prompts dropped={d}", .{dropped});
            debug_trace.eventf("worker", "queued_prompts_cleared", .{}, "dropped={d}", .{dropped});
        }
        for (self.queued_prompts.items) |prompt| {
            discardQueuedPrompt(alloc, prompt, retained_images);
        }
        self.queued_prompts.clearRetainingCapacity();
        self.queued_prompt_count = 0;
        self.queue_admission = null;
        self.worker_cond.broadcast(io_mod.getIo());
    }

    pub fn discardEvents(self: *WorkerRuntime, alloc: std.mem.Allocator) void {
        var events = self.takeEvents();
        defer events.deinit(alloc);
        for (events.items) |event| freeWorkerEvent(alloc, event);
    }

    pub fn syncQueuedPromptModel(self: *WorkerRuntime, alloc: std.mem.Allocator, model: []const u8) !void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        for (self.queued_prompts.items) |*prompt| {
            const next_model = try alloc.dupe(u8, model);
            alloc.free(prompt.model);
            prompt.model = next_model;
        }
    }

    pub fn syncQueuedPromptPermissionSnapshot(self: *WorkerRuntime, snapshot: PermissionSnapshot) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        for (self.queued_prompts.items) |*prompt| {
            prompt.permission_mode = snapshot.mode;
        }
    }

    pub fn syncQueuedPromptFastMode(self: *WorkerRuntime, enabled: bool) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.agent_turn_settings.fast_mode = enabled;
        for (self.queued_prompts.items) |*prompt| prompt.agent_settings.fast_mode = enabled;
    }

    pub fn syncQueuedPromptEffort(self: *WorkerRuntime, effort: types.ReasoningEffort) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.agent_turn_settings.effort = effort;
        for (self.queued_prompts.items) |*prompt| prompt.agent_settings.effort = effort;
    }

    pub fn setActiveAgentTurnSettings(self: *WorkerRuntime, settings: AgentTurnSettings) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.active_agent_turn_settings = settings;
    }

    pub fn clearActiveAgentTurnSettings(self: *WorkerRuntime) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.active_agent_turn_settings = null;
    }

    pub fn effectiveAgentTurnSettings(self: *WorkerRuntime) AgentTurnSettings {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return self.active_agent_turn_settings orelse self.agent_turn_settings;
    }

    pub fn setActivePermissionSnapshot(self: *WorkerRuntime, snapshot: PermissionSnapshot) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.active_permission_snapshot = snapshot;
    }

    pub fn clearActivePermissionSnapshot(self: *WorkerRuntime) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.active_permission_snapshot = null;
    }

    pub fn effectivePermissionSnapshot(self: *WorkerRuntime, fallback: PermissionSnapshot) PermissionSnapshot {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return self.active_permission_snapshot orelse fallback;
    }

    pub fn syncQueuedPromptPermissionState(self: *WorkerRuntime, alloc: std.mem.Allocator, grants: []const types.PermissionGrant, snapshot: PermissionSnapshot) !void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        for (self.queued_prompts.items) |*prompt| {
            const next_grants = try types.dupePermissionGrantSlice(alloc, grants);
            types.freePermissionGrantSlice(alloc, prompt.grants);
            prompt.grants = next_grants;
            prompt.permission_mode = snapshot.mode;
        }
    }

    pub fn propagateHistoryTurn(self: *WorkerRuntime, alloc: std.mem.Allocator, turn: types.HistoryTurn, max_history_turns: usize) !void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        if (self.queued_prompts.items.len == 0) return;
        const active_ownership = if (self.active_prompt_snapshot_ownership) |ownership|
            try ownership.ensureSharedOwnership(alloc)
        else
            null;
        const prepared = try alloc.alloc(
            PreparedHistoryPropagation,
            self.queued_prompts.items.len,
        );
        var prepared_count: usize = 0;
        var committed = false;
        defer {
            if (!committed) {
                for (prepared[0..prepared_count]) |entry| entry.deinit(alloc);
            }
            alloc.free(prepared);
        }

        while (prepared_count < self.queued_prompts.items.len) : (prepared_count += 1) {
            const prompt = self.queued_prompts.items[prepared_count];
            const next_image_catalog = try session_runtime.merge_image_catalog_history_turn(
                alloc,
                prompt.authorized_image_catalog,
                turn,
            );
            errdefer types.freeImageAttachmentSlice(alloc, next_image_catalog);
            const next_root_user_intent_context = try auto_classifier_context.refreshQueuedRootUserContext(
                alloc,
                prompt.prompt,
                prompt.root_user_intent_context,
                turn,
            );
            errdefer alloc.free(next_root_user_intent_context);
            const next_history = try appendHistoryTurnProjection(
                alloc,
                prompt.history,
                turn,
                max_history_turns,
            );
            errdefer types.freeHistoryTurnSlice(alloc, next_history);

            const next_snapshot_file_ownerships = if (active_ownership) |ownership| blk: {
                const ownership_count = std.math.add(
                    usize,
                    prompt.snapshot_file_ownerships.len,
                    1,
                ) catch return error.OutOfMemory;
                const ownerships = try alloc.alloc(
                    types.SnapshotFileOwnership,
                    ownership_count,
                );
                std.mem.copyForwards(
                    types.SnapshotFileOwnership,
                    ownerships[0..prompt.snapshot_file_ownerships.len],
                    prompt.snapshot_file_ownerships,
                );
                ownership.retain();
                ownerships[prompt.snapshot_file_ownerships.len] = ownership;
                break :blk ownerships;
            } else null;
            errdefer {
                if (next_snapshot_file_ownerships) |ownerships| {
                    ownerships[ownerships.len - 1].release();
                    alloc.free(ownerships);
                }
            }

            prepared[prepared_count] = .{
                .history = next_history,
                .root_user_intent_context = next_root_user_intent_context,
                .authorized_image_catalog = next_image_catalog,
                .snapshot_file_ownerships = next_snapshot_file_ownerships,
                .added_snapshot_ownership = if (next_snapshot_file_ownerships) |ownerships|
                    ownerships[ownerships.len - 1]
                else
                    null,
            };
        }

        for (self.queued_prompts.items, prepared) |*prompt, next| {
            types.freeHistoryTurnSlice(alloc, prompt.history);
            prompt.history = next.history;
            if (prompt.root_user_intent_context.len > 0) alloc.free(prompt.root_user_intent_context);
            prompt.root_user_intent_context = next.root_user_intent_context;
            types.freeImageAttachmentSlice(alloc, prompt.authorized_image_catalog);
            prompt.authorized_image_catalog = next.authorized_image_catalog;
            if (next.snapshot_file_ownerships) |ownerships| {
                if (prompt.snapshot_file_ownerships.len > 0) {
                    alloc.free(prompt.snapshot_file_ownerships);
                }
                prompt.snapshot_file_ownerships = ownerships;
            }
        }
        committed = true;
    }

    pub fn beginActivePromptSnapshots(
        self: *WorkerRuntime,
        ownership: *ActivePromptSnapshotOwnership,
    ) void {
        std.debug.assert(self.active_prompt_snapshot_ownership == null);
        self.active_prompt_snapshot_ownership = ownership;
    }

    pub fn handoffActivePromptSnapshots(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
    ) !?types.SnapshotFileOwnership {
        const ownership = self.active_prompt_snapshot_ownership orelse return null;
        return ownership.handoff(alloc);
    }

    pub fn endActivePromptSnapshots(
        self: *WorkerRuntime,
        ownership: *ActivePromptSnapshotOwnership,
    ) void {
        std.debug.assert(self.active_prompt_snapshot_ownership == ownership);
        self.active_prompt_snapshot_ownership = null;
        ownership.deinit();
    }

    pub fn propagateGrant(self: *WorkerRuntime, alloc: std.mem.Allocator, tool_name: []const u8, target_path: []const u8) !void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        for (self.queued_prompts.items) |*prompt| try appendGrantToQueuedPrompt(alloc, prompt, tool_name, target_path);
    }

    pub fn requestPermissionBlocking(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        request: permission_request.PermissionRequest,
    ) permission_request.RequestCloneError!permission_request.OwnedPermissionResponse {
        return self.requestPermissionBlockingWithReview(alloc, request, null);
    }

    pub fn requestPermissionBlockingWithReview(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        request: permission_request.PermissionRequest,
        review: ?*const diff_mod.FileReview,
    ) permission_request.RequestCloneError!permission_request.OwnedPermissionResponse {
        return self.requestPermissionBlockingObserved(alloc, request, review, null) catch |err| switch (err) {
            error.PermissionRegistrationFailed,
            error.PermissionCapacityExceeded,
            => unreachable,
            else => |request_err| return request_err,
        };
    }

    pub const PermissionRequestObserver = struct {
        context: *anyopaque,
        observe_fn: *const fn (
            *anyopaque,
            *WorkerRuntime,
            permission_request.PermissionRequest,
        ) error{
            OutOfMemory,
            PermissionRegistrationFailed,
            PermissionCapacityExceeded,
        }!void,
    };

    pub fn requestPermissionBlockingObserved(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        request: permission_request.PermissionRequest,
        review: ?*const diff_mod.FileReview,
        observer: ?PermissionRequestObserver,
    ) (permission_request.RequestCloneError || error{
        PermissionRegistrationFailed,
        PermissionCapacityExceeded,
    })!permission_request.OwnedPermissionResponse {
        var shared_request: ?permission_request.OwnedPermissionRequest =
            try permission_request.OwnedPermissionRequest.dupe(
                alloc,
                request,
            );
        errdefer if (shared_request) |*owned| owned.deinit(alloc);

        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        shared_request.?.id = try self.allocatePermissionRequestIdLocked();
        if (self.pending_permission_request_shared) |*old| old.deinit(alloc);
        self.pending_permission_request_shared = shared_request.?;
        shared_request = null;
        self.pending_permission_review = review;
        if (self.pending_permission_response) |response| {
            self.discardPermissionResponse(response, "request_replaced");
        }
        self.pending_permission_response = null;
        self.pending_permission_waiting = true;

        if (observer) |value| {
            value.observe_fn(
                value.context,
                self,
                self.pending_permission_request_shared.?.view(),
            ) catch |err| {
                self.pending_permission_waiting = false;
                self.pending_permission_request_shared.?.deinit(alloc);
                self.pending_permission_request_shared = null;
                self.pending_permission_review = null;
                return err;
            };
        }

        while (self.pending_permission_response == null and !self.worker_stop_requested) {
            self.worker_cond.wait(io_mod.getIo(), &self.worker_mutex) catch break;
        }

        const response = self.pending_permission_response orelse
            permission_request.OwnedPermissionResponse.init(alloc, .deny, null);
        self.pending_permission_waiting = false;
        self.pending_permission_response = null;
        if (self.pending_permission_request_shared) |*old| {
            old.deinit(alloc);
            self.pending_permission_request_shared = null;
        }
        self.pending_permission_review = null;
        return response;
    }

    pub fn submitPermissionResponse(
        self: *WorkerRuntime,
        expected_request_id: u64,
        response: permission_request.OwnedPermissionResponse,
    ) PermissionSubmissionResult {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        if (self.permissionSubmissionBlockedLocked(expected_request_id)) |blocked| {
            self.discardPermissionResponse(response, @tagName(blocked));
            return blocked;
        }
        std.debug.assert(self.resolvePendingPermissionLocked(response));
        return .accepted;
    }

    pub const PermissionCommitError = error{
        OutOfMemory,
        PermissionCommitFailed,
        PermissionCapacityExceeded,
    };

    pub const PermissionCommit = struct {
        context: *anyopaque,
        commit_fn: *const fn (*anyopaque) PermissionCommitError!void,
    };

    /// Keeps canonical pending-request identity stable across a durable host
    /// commit. The response becomes visible and the waiter wakes only after the
    /// callback succeeds. On callback failure the owned response is discarded.
    pub fn submitPermissionResponseAfterCommit(
        self: *WorkerRuntime,
        expected_request_id: u64,
        response: permission_request.OwnedPermissionResponse,
        commit: ?PermissionCommit,
    ) PermissionCommitError!PermissionSubmissionResult {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        if (self.permissionSubmissionBlockedLocked(expected_request_id)) |blocked| {
            self.discardPermissionResponse(response, @tagName(blocked));
            return blocked;
        }
        if (commit) |effect| effect.commit_fn(effect.context) catch |err| {
            self.discardPermissionResponse(response, "commit_failed");
            return err;
        };
        std.debug.assert(self.resolvePendingPermissionLocked(response));
        return .accepted;
    }

    fn permissionSubmissionBlockedLocked(
        self: *const WorkerRuntime,
        expected_request_id: u64,
    ) ?PermissionSubmissionResult {
        if (!self.permissionRequestAwaitedLocked() or
            self.pending_permission_response != null)
        {
            return .no_pending;
        }
        if (self.pending_permission_request_shared.?.id != expected_request_id) {
            return .stale;
        }
        return null;
    }

    fn allocatePermissionRequestIdLocked(
        self: *WorkerRuntime,
    ) error{RequestIdExhausted}!u64 {
        const request_id = self.next_permission_request_id;
        if (request_id == 0) return error.RequestIdExhausted;
        self.next_permission_request_id = std.math.add(
            u64,
            request_id,
            1,
        ) catch 0;
        return request_id;
    }

    fn permissionRequestAwaitedLocked(self: *const WorkerRuntime) bool {
        return self.worker_processing and
            !self.worker_stop_requested and
            self.pending_permission_waiting and
            self.pending_permission_request_shared != null;
    }

    fn permissionRequestAwaitingDecisionLocked(
        self: *const WorkerRuntime,
    ) bool {
        return self.permissionRequestAwaitedLocked() and
            self.pending_permission_response == null;
    }

    fn resolvePendingPermissionLocked(
        self: *WorkerRuntime,
        response: permission_request.OwnedPermissionResponse,
    ) bool {
        if (!self.permissionRequestAwaitingDecisionLocked()) {
            self.discardPermissionResponse(response, "unawaited");
            return false;
        }
        self.pending_permission_response = response;
        self.worker_cond.broadcast(io_mod.getIo());
        return true;
    }

    fn discardPermissionResponse(
        _: *WorkerRuntime,
        response: permission_request.OwnedPermissionResponse,
        reason: []const u8,
    ) void {
        var owned = response;
        if (owned.feedback) |feedback| {
            debug_trace.logf(
                "permission",
                "approval feedback discarded reason={s} bytes={d}",
                .{ reason, feedback.len },
            );
        }
        owned.deinit();
    }

    pub fn requestQuestionBatchAnswerBlocking(self: *WorkerRuntime, alloc: std.mem.Allocator, entries: []const types.QuestionBatchEntry) !?[][]u8 {
        return self.requestQuestionBatchAnswerBlockingWithSource(alloc, entries, .agent_question);
    }

    pub fn requestRouteRecoveryAnswerBlocking(self: *WorkerRuntime, alloc: std.mem.Allocator, entries: []const types.QuestionBatchEntry) !?[][]u8 {
        return self.requestQuestionBatchAnswerBlockingWithSource(alloc, entries, .route_recovery);
    }

    pub fn requestMcpElicitationAnswerBlocking(self: *WorkerRuntime, alloc: std.mem.Allocator, entries: []const types.QuestionBatchEntry) !?[][]u8 {
        return self.requestQuestionBatchAnswerBlockingWithSource(alloc, entries, .mcp_elicitation);
    }

    fn requestQuestionBatchAnswerBlockingWithSource(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        entries: []const types.QuestionBatchEntry,
        source: QuestionPromptSource,
    ) !?[][]u8 {
        const owned = try dupeOwnedQuestionBatch(alloc, entries, source);
        var owns_pending_question = true;
        errdefer if (owns_pending_question) freeOwnedQuestionBatch(alloc, owned);

        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        std.debug.assert(self.pending_question_shared == null);
        self.pending_question_shared = owned;
        freeQuestionResponse(alloc, self.pending_question_response);
        self.pending_question_response = .pending;
        self.worker_events.append(alloc, .question_requested) catch |err| {
            self.pending_question_shared = null;
            self.pending_question_response = .pending;
            return err;
        };
        owns_pending_question = false;
        self.worker_cond.broadcast(io_mod.getIo());

        while (self.pending_question_response == .pending and !self.worker_stop_requested) {
            self.worker_cond.wait(io_mod.getIo(), &self.worker_mutex) catch break;
        }

        if (self.pending_question_shared) |pending| {
            freeOwnedQuestionBatch(alloc, pending);
            self.pending_question_shared = null;
        }

        const response = self.pending_question_response;
        self.pending_question_response = .pending;
        return switch (response) {
            .answered => |labels| labels,
            .cancelled, .pending => null,
        };
    }

    pub fn submitQuestionBatchAnswer(self: *WorkerRuntime, alloc: std.mem.Allocator, answers: ?[]const []const u8) !void {
        var new_response: QuestionResponse = .cancelled;
        if (answers) |labels| {
            const dup = try alloc.alloc([]u8, labels.len);
            errdefer alloc.free(dup);
            var filled: usize = 0;
            errdefer {
                var i: usize = 0;
                while (i < filled) : (i += 1) alloc.free(dup[i]);
            }
            while (filled < labels.len) : (filled += 1) dup[filled] = try alloc.dupe(u8, labels[filled]);
            new_response = .{ .answered = dup };
        }

        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.pending_question_shared == null or self.pending_question_response != .pending) {
            freeQuestionResponse(alloc, new_response);
            debug_trace.logf("worker", "ignored late question response pending=false", .{});
            return;
        }
        freeQuestionResponse(alloc, self.pending_question_response);
        self.pending_question_response = new_response;
        self.worker_cond.broadcast(io_mod.getIo());
    }

    pub fn cancelPendingQuestionBatch(self: *WorkerRuntime) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.pending_question_shared == null or self.pending_question_response != .pending) return false;
        self.pending_question_response = .cancelled;
        self.worker_cond.broadcast(io_mod.getIo());
        return true;
    }

    pub fn snapshotPendingQuestionBatch(self: *WorkerRuntime, alloc: std.mem.Allocator) !?PendingQuestionBatchSnapshot {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        const pending = self.pending_question_shared orelse return null;
        return try dupePendingBatchSnapshot(alloc, pending);
    }

    pub fn pendingQuestionBatchSource(self: *WorkerRuntime) QuestionPromptSource {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        const pending = self.pending_question_shared orelse return .agent_question;
        return pending.source;
    }
};

fn recoveryContinuationAdmission(
    processing: bool,
    queued_count: usize,
    terminal_pause_ready: bool,
) bool {
    return queued_count == 0 and (!processing or terminal_pause_ready);
}

test "recovery continuation admission requires an empty idle or terminally paused worker" {
    try std.testing.expect(recoveryContinuationAdmission(false, 0, false));
    try std.testing.expect(!recoveryContinuationAdmission(true, 0, false));
    try std.testing.expect(recoveryContinuationAdmission(true, 0, true));
    try std.testing.expect(!recoveryContinuationAdmission(false, 1, true));
}

test "terminal recovery pause admits continuation before worker cleanup" {
    const alloc = std.testing.allocator;
    var runtime: WorkerRuntime = .{};
    defer runtime.deinit(alloc);

    const Fixture = struct {
        fn make(allocator: std.mem.Allocator) !QueuedPrompt {
            var prompt = try makePrompt(allocator, "continue preserved turn", "model");
            errdefer freeQueuedPrompt(allocator, prompt);
            prompt.recovery_checkpoint = try (session_codec.RecoveryCheckpoint{
                .turn_id = 41,
                .user = .{ .text = @constCast("unfinished prompt") },
                .assistant_source = @constCast("partial response"),
                .cause = .network_interrupted,
                .action = .paused,
                .route_model = @constCast("model"),
                .requested_fast_mode = false,
                .fast_mode = false,
                .max_provider_attempts = 10,
                .consumed_provider_attempts = 10,
            }).dupe(allocator);
            return prompt;
        }
    };

    runtime.worker_processing = true;
    try runtime.pushEvent(alloc, .{ .route_recovery_status = .{
        .kind = .terminal_provider_error,
        .failed_attempt = 10,
        .attempt_limit = 10,
        .cause = .network_interrupted,
        .action = .paused,
        .required_action = .continue_later,
    } });
    try runtime.pushTurnFinished(alloc, .{
        .turn_id = 41,
        .outcome = .paused,
    });

    const continuation = try Fixture.make(alloc);
    runtime.enqueuePrompt(alloc, continuation) catch |err| {
        freeQueuedPrompt(alloc, continuation);
        return err;
    };
    try std.testing.expectEqual(@as(usize, 1), runtime.queuedPromptCount());
}

test "connectivity wait state follows worker events before UI presentation" {
    var runtime: WorkerRuntime = .{};
    defer runtime.deinit(std.testing.allocator);

    try runtime.pushEvent(std.testing.allocator, .{ .route_recovery_status = .{
        .kind = .auto_retry,
        .cause = .system_resumed,
        .action = .waiting_for_connectivity,
    } });
    try std.testing.expect(runtime.isConnectivityWaitActive());

    try runtime.pushEvent(std.testing.allocator, .{ .route_recovery_status = .{
        .kind = .auto_retry,
        .cause = .network_interrupted,
        .action = .retrying_request,
    } });
    try std.testing.expect(!runtime.isConnectivityWaitActive());

    try runtime.pushEvent(std.testing.allocator, .{ .route_recovery_status = .{
        .kind = .auto_retry,
        .cause = .system_resumed,
        .action = .waiting_for_connectivity,
    } });
    try runtime.pushEvent(std.testing.allocator, .clear_route_recovery_status);
    try std.testing.expect(!runtime.isConnectivityWaitActive());
}

fn dupeOwnedQuestionEntry(alloc: std.mem.Allocator, entry: types.QuestionBatchEntry) !OwnedQuestionEntry {
    const question_dup = try alloc.dupe(u8, entry.question);
    errdefer alloc.free(question_dup);
    const options_dup = try alloc.alloc(OwnedQuestionOption, entry.options.len);
    errdefer alloc.free(options_dup);

    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) {
            alloc.free(options_dup[i].label);
            if (options_dup[i].description) |d| alloc.free(d);
        }
    }
    while (filled < entry.options.len) : (filled += 1) {
        const src = entry.options[filled];
        const label_dup = try alloc.dupe(u8, src.label);
        errdefer alloc.free(label_dup);
        const desc_dup: ?[]u8 = if (src.description) |d| try alloc.dupe(u8, d) else null;
        options_dup[filled] = .{ .label = label_dup, .description = desc_dup };
    }
    return .{ .question = question_dup, .options = options_dup };
}

fn freeOwnedQuestionEntry(alloc: std.mem.Allocator, entry: OwnedQuestionEntry) void {
    alloc.free(entry.question);
    for (entry.options) |opt| {
        alloc.free(opt.label);
        if (opt.description) |d| alloc.free(d);
    }
    alloc.free(entry.options);
}

fn dupeOwnedQuestionBatch(
    alloc: std.mem.Allocator,
    entries: []const types.QuestionBatchEntry,
    source: QuestionPromptSource,
) !OwnedQuestionBatch {
    const owned_entries = try alloc.alloc(OwnedQuestionEntry, entries.len);
    errdefer alloc.free(owned_entries);
    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) freeOwnedQuestionEntry(alloc, owned_entries[i]);
    }
    while (filled < entries.len) : (filled += 1) owned_entries[filled] = try dupeOwnedQuestionEntry(alloc, entries[filled]);
    return .{ .entries = owned_entries, .source = source };
}

fn freeOwnedQuestionBatch(alloc: std.mem.Allocator, owned: OwnedQuestionBatch) void {
    for (owned.entries) |entry| freeOwnedQuestionEntry(alloc, entry);
    alloc.free(owned.entries);
}

fn freeOwnedQuestionBatchOpt(alloc: std.mem.Allocator, owned: ?OwnedQuestionBatch) void {
    if (owned) |o| freeOwnedQuestionBatch(alloc, o);
}

fn freeQuestionResponse(alloc: std.mem.Allocator, response: QuestionResponse) void {
    switch (response) {
        .answered => |labels| {
            for (labels) |label| alloc.free(label);
            alloc.free(labels);
        },
        .cancelled, .pending => {},
    }
}

fn dupePendingEntrySnapshot(alloc: std.mem.Allocator, pending: OwnedQuestionEntry) !types.QuestionBatchEntry {
    const question_dup = try alloc.dupe(u8, pending.question);
    errdefer alloc.free(question_dup);
    const options_dup = try alloc.alloc(types.QuestionOption, pending.options.len);
    errdefer alloc.free(options_dup);

    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) {
            alloc.free(@constCast(options_dup[i].label));
            if (options_dup[i].description) |d| alloc.free(@constCast(d));
        }
    }
    while (filled < pending.options.len) : (filled += 1) {
        const src = pending.options[filled];
        const label_dup = try alloc.dupe(u8, src.label);
        errdefer alloc.free(label_dup);
        const desc_dup: ?[]const u8 = if (src.description) |d| try alloc.dupe(u8, d) else null;
        options_dup[filled] = .{ .label = label_dup, .description = desc_dup };
    }
    return .{ .question = question_dup, .options = options_dup };
}

fn dupePendingBatchSnapshot(alloc: std.mem.Allocator, pending: OwnedQuestionBatch) !PendingQuestionBatchSnapshot {
    const entries_dup = try alloc.alloc(types.QuestionBatchEntry, pending.entries.len);
    errdefer alloc.free(entries_dup);
    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) {
            alloc.free(@constCast(entries_dup[i].question));
            for (entries_dup[i].options) |opt| {
                alloc.free(@constCast(opt.label));
                if (opt.description) |d| alloc.free(@constCast(d));
            }
            alloc.free(@constCast(entries_dup[i].options));
        }
    }
    while (filled < pending.entries.len) : (filled += 1) entries_dup[filled] = try dupePendingEntrySnapshot(alloc, pending.entries[filled]);
    return .{ .entries = entries_dup, .source = pending.source };
}

fn appendGrantToQueuedPrompt(alloc: std.mem.Allocator, prompt: *QueuedPrompt, tool_name: []const u8, target_path: []const u8) !void {
    for (prompt.grants) |grant| {
        if (std.mem.eql(u8, grant.tool_name, tool_name) and std.mem.eql(u8, grant.target_path, target_path)) return;
    }
    const tool_name_dup = try alloc.dupe(u8, tool_name);
    errdefer alloc.free(tool_name_dup);
    const target_path_dup = try alloc.dupe(u8, target_path);
    errdefer alloc.free(target_path_dup);
    const current = prompt.grants;
    const next = try alloc.alloc(types.PermissionGrant, current.len + 1);
    errdefer alloc.free(next);
    if (current.len > 0) std.mem.copyForwards(types.PermissionGrant, next[0..current.len], current);
    next[current.len] = .{ .tool_name = tool_name_dup, .target_path = target_path_dup };
    alloc.free(current);
    prompt.grants = next;
}

fn dupeStringSlice(alloc: std.mem.Allocator, values: []const []const u8) ![][]u8 {
    if (values.len == 0) return &.{};
    const copy = try alloc.alloc([]u8, values.len);
    errdefer alloc.free(copy);

    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) alloc.free(copy[i]);
    }
    while (filled < values.len) : (filled += 1) {
        copy[filled] = try alloc.dupe(u8, values[filled]);
    }
    return copy;
}

fn freeStringSlice(alloc: std.mem.Allocator, values: [][]u8) void {
    for (values) |value| alloc.free(value);
    if (values.len > 0) alloc.free(values);
}

fn appendHistoryTurnProjection(
    alloc: std.mem.Allocator,
    current: []const types.HistoryTurn,
    turn: types.HistoryTurn,
    max_history_turns: usize,
) ![]types.HistoryTurn {
    const combined_len = std.math.add(usize, current.len, 1) catch
        return error.OutOfMemory;
    const combined = try alloc.alloc(types.HistoryTurn, combined_len);
    defer alloc.free(combined);
    std.mem.copyForwards(types.HistoryTurn, combined[0..current.len], current);
    combined[current.len] = turn;
    return session_runtime.snapshotOwnedContextHistory(
        alloc,
        combined,
        0,
        max_history_turns,
    );
}

pub fn freeQueuedPrompt(alloc: std.mem.Allocator, prompt: QueuedPrompt) void {
    alloc.free(prompt.prompt);
    types.freeImageAttachmentSlice(alloc, prompt.images);
    types.freeImageAttachmentSlice(alloc, prompt.authorized_image_catalog);
    alloc.free(prompt.model);
    secret.zeroAndFree(alloc, prompt.api_key);
    if (prompt.gateway_team) |team| alloc.free(team);
    if (prompt.account_id) |account_id| alloc.free(account_id);
    types.freeHistoryTurnSlice(alloc, prompt.history);
    if (prompt.root_user_intent_context.len > 0) alloc.free(prompt.root_user_intent_context);
    types.freePermissionGrantSlice(alloc, prompt.grants);
    freeSkillBindings(alloc, prompt.skill_bindings);
    freeSkillDisplaySpans(alloc, prompt.skill_display_spans);
    freeQueueReviewDraftOpt(alloc, prompt.review_draft);
    var context_snapshot = prompt.context_snapshot;
    context_snapshot.deinit(alloc);
    for (prompt.snapshot_file_ownerships) |ownership| ownership.release();
    if (prompt.snapshot_file_ownerships.len > 0) {
        alloc.free(prompt.snapshot_file_ownerships);
    }
    if (prompt.recovery_checkpoint) |checkpoint| {
        var owned = checkpoint;
        owned.deinit(alloc);
    }
}

fn discardQueuedPrompt(
    alloc: std.mem.Allocator,
    prompt: QueuedPrompt,
    retained_images: []const types.ImageAttachment,
) void {
    image_attachments.deleteUnreferencedImageSnapshots(prompt.images, retained_images);
    freeQueuedPrompt(alloc, prompt);
}

test "active prompt snapshot ownership discards every pre-transfer boundary" {
    const boundaries = [_][]const u8{
        "preflight_notice",
        "skill_prompt",
        "tool_projection",
        "permission_preparation",
        "process_queued_prompt",
        "postflight_finish",
    };
    for (boundaries, 0..) |_, index| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "snapshot-{d}.bin", .{index});
        {
            var file = try tmp.dir.createFile(std.testing.io, name, .{});
            defer file.close(std.testing.io);
            try file.writeStreamingAll(std.testing.io, "snapshot");
        }
        const path = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, name);
        defer std.testing.allocator.free(path);
        const images = [_]types.ImageAttachment{.{
            .id = index + 1,
            .path = @constCast("/tmp/source.png"),
            .media_type = @constCast("image/png"),
            .snapshot_path = path,
            .snapshot_sha256 = @constCast("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        }};
        var ownership = ActivePromptSnapshotOwnership.init(&images);
        ownership.deinit();
        ownership.deinit();
        try std.testing.expectError(
            error.FileNotFound,
            std.Io.Dir.accessAbsolute(std.testing.io, path, .{}),
        );
    }
}

test "accepted active prompt ownership does not delete history files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var first = try tmp.dir.createFile(std.testing.io, "first.bin", .{});
        defer first.close(std.testing.io);
        try first.writeStreamingAll(std.testing.io, "first");
    }
    {
        var second = try tmp.dir.createFile(std.testing.io, "second.bin", .{});
        defer second.close(std.testing.io);
        try second.writeStreamingAll(std.testing.io, "second");
    }
    const first_path = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "first.bin");
    defer std.testing.allocator.free(first_path);
    const second_path = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "second.bin");
    defer std.testing.allocator.free(second_path);
    const images = [_]types.ImageAttachment{
        .{
            .id = 1,
            .path = @constCast("/tmp/first.png"),
            .media_type = @constCast("image/png"),
            .snapshot_path = first_path,
            .snapshot_sha256 = @constCast("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        },
        .{
            .id = 2,
            .path = @constCast("/tmp/second.png"),
            .media_type = @constCast("image/png"),
            .snapshot_path = second_path,
            .snapshot_sha256 = @constCast("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
        },
    };
    var ownership = ActivePromptSnapshotOwnership.init(&images);
    const accepted = (try ownership.handoff(std.testing.allocator)) orelse
        return error.TestExpectedEqual;
    accepted.transfer();
    accepted.release();
    ownership.deinit();

    try std.Io.Dir.accessAbsolute(std.testing.io, first_path, .{});
    try std.Io.Dir.accessAbsolute(std.testing.io, second_path, .{});
}

test "propagated queued snapshots survive finish failure until the last borrower releases" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(std.testing.io, "snapshot.bin", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "snapshot");
    }
    const path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "snapshot.bin");
    defer alloc.free(path);
    var images = [_]types.ImageAttachment{.{
        .id = 1,
        .path = @constCast("/tmp/source.png"),
        .media_type = @constCast("image/png"),
        .snapshot_path = path,
        .snapshot_sha256 = @constCast("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
    }};
    const turn: types.HistoryTurn = .{ .assistant = .{
        .user = .{ .text = @constCast("active"), .images = &images },
        .assistant = @constCast("done"),
    } };

    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);
    try runtime.enqueuePrompt(alloc, try makePrompt(alloc, "first queued", "model"));
    try runtime.enqueuePrompt(alloc, try makePrompt(alloc, "second queued", "model"));

    var active = ActivePromptSnapshotOwnership.init(&images);
    runtime.beginActivePromptSnapshots(&active);
    try runtime.propagateHistoryTurn(alloc, turn, 8);
    const failed_finish_ownership =
        (try runtime.handoffActivePromptSnapshots(alloc)) orelse
        return error.TestExpectedEqual;
    failed_finish_ownership.release();
    runtime.endActivePromptSnapshots(&active);

    for (runtime.queued_prompts.items) |prompt| {
        try std.testing.expectEqual(@as(usize, 1), prompt.authorized_image_catalog.len);
        try std.testing.expectEqual(@as(usize, 1), prompt.snapshot_file_ownerships.len);
        try std.Io.Dir.accessAbsolute(
            std.testing.io,
            prompt.authorized_image_catalog[0].snapshot_path.?,
            .{},
        );
    }

    const first_turn_id = runtime.queued_prompts.items[0].turn_id;
    try std.testing.expect(runtime.deleteQueuedPromptDraft(alloc, first_turn_id, &.{}));
    try std.Io.Dir.accessAbsolute(std.testing.io, path, .{});

    runtime.clearQueuedPrompts(alloc, &.{});
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(std.testing.io, path, .{}),
    );
}

test "accepted history prevents propagated queue cleanup from deleting snapshots" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(std.testing.io, "snapshot.bin", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "snapshot");
    }
    const path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "snapshot.bin");
    defer alloc.free(path);
    var images = [_]types.ImageAttachment{.{
        .id = 1,
        .path = @constCast("/tmp/source.png"),
        .media_type = @constCast("image/png"),
        .snapshot_path = path,
        .snapshot_sha256 = @constCast("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
    }};
    const turn: types.HistoryTurn = .{ .assistant = .{
        .user = .{ .text = @constCast("active"), .images = &images },
        .assistant = @constCast("done"),
    } };

    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);
    try runtime.enqueuePrompt(alloc, try makePrompt(alloc, "queued", "model"));

    var active = ActivePromptSnapshotOwnership.init(&images);
    runtime.beginActivePromptSnapshots(&active);
    try runtime.propagateHistoryTurn(alloc, turn, 8);
    const accepted =
        (try runtime.handoffActivePromptSnapshots(alloc)) orelse
        return error.TestExpectedEqual;
    accepted.transfer();
    accepted.release();
    runtime.endActivePromptSnapshots(&active);
    runtime.clearQueuedPrompts(alloc, &.{});

    try std.Io.Dir.accessAbsolute(std.testing.io, path, .{});
}

test "failed queued prompt dequeue retains borrowed snapshot ownership" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(std.testing.io, "snapshot.bin", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "snapshot");
    }
    const path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "snapshot.bin");
    defer alloc.free(path);
    var images = [_]types.ImageAttachment{.{
        .id = 1,
        .path = @constCast("/tmp/source.png"),
        .media_type = @constCast("image/png"),
        .snapshot_path = path,
        .snapshot_sha256 = @constCast("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
    }};
    const turn: types.HistoryTurn = .{ .assistant = .{
        .user = .{ .text = @constCast("active"), .images = &images },
        .assistant = @constCast("done"),
    } };

    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);
    try runtime.enqueuePrompt(alloc, try makePrompt(alloc, "queued", "model"));

    var active = ActivePromptSnapshotOwnership.init(&images);
    runtime.beginActivePromptSnapshots(&active);
    try runtime.propagateHistoryTurn(alloc, turn, 8);
    const failed_finish_ownership =
        (try runtime.handoffActivePromptSnapshots(alloc)) orelse
        return error.TestExpectedEqual;
    failed_finish_ownership.release();
    runtime.endActivePromptSnapshots(&active);

    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        runtime.waitAndTakeNextPrompt(failing.allocator()),
    );
    try std.testing.expectEqual(@as(usize, 1), runtime.queuedPromptCount());
    try std.testing.expectEqual(
        @as(usize, 1),
        runtime.queued_prompts.items[0].snapshot_file_ownerships.len,
    );
    try std.Io.Dir.accessAbsolute(std.testing.io, path, .{});

    runtime.clearQueuedPrompts(alloc, &.{});
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(std.testing.io, path, .{}),
    );
}

fn checkHistoryPropagationAllocation(
    alloc: std.mem.Allocator,
    snapshot_path: []const u8,
    fail_index: usize,
) !bool {
    {
        var file = try std.Io.Dir.createFileAbsolute(
            std.testing.io,
            snapshot_path,
            .{ .truncate = true },
        );
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "snapshot");
    }
    var images = [_]types.ImageAttachment{.{
        .id = 1,
        .path = @constCast("/tmp/source.png"),
        .media_type = @constCast("image/png"),
        .snapshot_path = @constCast(snapshot_path),
        .snapshot_sha256 = @constCast("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
    }};
    const turn: types.HistoryTurn = .{ .assistant = .{
        .user = .{ .text = @constCast("active"), .images = &images },
        .assistant = @constCast("done"),
    } };

    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);
    const first = try makePrompt(alloc, "first queued", "model");
    var owns_first = true;
    errdefer if (owns_first) freeQueuedPrompt(alloc, first);
    try runtime.enqueuePrompt(alloc, first);
    owns_first = false;
    const second = try makePrompt(alloc, "second queued", "model");
    var owns_second = true;
    errdefer if (owns_second) freeQueuedPrompt(alloc, second);
    try runtime.enqueuePrompt(alloc, second);
    owns_second = false;

    var active = ActivePromptSnapshotOwnership.init(&images);
    runtime.beginActivePromptSnapshots(&active);
    defer runtime.endActivePromptSnapshots(&active);

    var failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = fail_index },
    );
    runtime.propagateHistoryTurn(failing.allocator(), turn, 8) catch |err| {
        if (!failing.has_induced_failure) return err;
        for (runtime.queued_prompts.items) |prompt| {
            try std.testing.expectEqual(@as(usize, 0), prompt.history.len);
            try std.testing.expectEqual(@as(usize, 0), prompt.authorized_image_catalog.len);
            try std.testing.expectEqual(@as(usize, 0), prompt.snapshot_file_ownerships.len);
        }
        return false;
    };

    for (runtime.queued_prompts.items) |prompt| {
        try std.testing.expectEqual(@as(usize, 1), prompt.history.len);
        try std.testing.expectEqual(@as(usize, 1), prompt.authorized_image_catalog.len);
        try std.testing.expectEqual(@as(usize, 1), prompt.snapshot_file_ownerships.len);
    }
    return true;
}

test "multi-queue history propagation is allocation-failure atomic" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const snapshot_path = try std.fs.path.join(alloc, &.{ root, "snapshot.bin" });
    defer alloc.free(snapshot_path);

    var fail_index: usize = 0;
    while (fail_index < 256) : (fail_index += 1) {
        if (try checkHistoryPropagationAllocation(alloc, snapshot_path, fail_index)) {
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "finish ownership handoff deletes snapshots after its last unaccepted release" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(std.testing.io, "snapshot.bin", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "snapshot");
    }
    const path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "snapshot.bin");
    defer alloc.free(path);
    const images = [_]types.ImageAttachment{.{
        .id = 1,
        .path = @constCast("/tmp/source.png"),
        .media_type = @constCast("image/png"),
        .snapshot_path = path,
        .snapshot_sha256 = @constCast("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
    }};
    var active = ActivePromptSnapshotOwnership.init(&images);
    const ownership = (try active.handoff(alloc)) orelse return error.TestExpectedEqual;
    active.deinit();

    const queued = try types.dupeFinishedPrompt(alloc, .{
        .turn = .{ .compacted_summary = .{
            .summary = @constCast("queued"),
            .removed_turn_count = 1,
            .compaction_count = 1,
        } },
        .snapshot_file_ownership = ownership,
    });
    ownership.release();
    const paced = try types.dupeFinishedPrompt(alloc, queued);
    types.freeFinishedPrompt(alloc, queued);
    try std.Io.Dir.accessAbsolute(std.testing.io, path, .{});

    types.freeFinishedPrompt(alloc, paced);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(std.testing.io, path, .{}),
    );
}

test "accepted finish ownership survives queue and pacing release" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(std.testing.io, "snapshot.bin", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "snapshot");
    }
    const path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "snapshot.bin");
    defer alloc.free(path);
    const images = [_]types.ImageAttachment{.{
        .id = 1,
        .path = @constCast("/tmp/source.png"),
        .media_type = @constCast("image/png"),
        .snapshot_path = path,
        .snapshot_sha256 = @constCast("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
    }};
    var active = ActivePromptSnapshotOwnership.init(&images);
    const ownership = (try active.handoff(alloc)) orelse return error.TestExpectedEqual;
    active.deinit();

    const finished = try types.dupeFinishedPrompt(alloc, .{
        .turn = .{ .compacted_summary = .{
            .summary = @constCast("accepted"),
            .removed_turn_count = 1,
            .compaction_count = 1,
        } },
        .snapshot_file_ownership = ownership,
    });
    ownership.release();
    finished.snapshot_file_ownership.?.transfer();
    types.freeFinishedPrompt(alloc, finished);

    try std.Io.Dir.accessAbsolute(std.testing.io, path, .{});
}

fn checkFinishOwnershipHandoffAllocation(
    alloc: std.mem.Allocator,
    snapshot_path: []const u8,
) !void {
    {
        var file = try std.Io.Dir.createFileAbsolute(
            std.testing.io,
            snapshot_path,
            .{ .truncate = true },
        );
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "snapshot");
    }
    const images = [_]types.ImageAttachment{.{
        .id = 1,
        .path = @constCast("/tmp/source.png"),
        .media_type = @constCast("image/png"),
        .snapshot_path = @constCast(snapshot_path),
        .snapshot_sha256 = @constCast("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
    }};
    var active = ActivePromptSnapshotOwnership.init(&images);
    const ownership = active.handoff(alloc) catch |err| {
        active.deinit();
        try std.testing.expectError(
            error.FileNotFound,
            std.Io.Dir.accessAbsolute(std.testing.io, snapshot_path, .{}),
        );
        return err;
    };
    active.deinit();
    ownership.?.release();
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(std.testing.io, snapshot_path, .{}),
    );
}

test "finish ownership handoff preserves allocator and filesystem ownership" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const snapshot_path = try std.fs.path.join(alloc, &.{ root, "snapshot.bin" });
    defer alloc.free(snapshot_path);

    try std.testing.checkAllAllocationFailures(
        alloc,
        checkFinishOwnershipHandoffAllocation,
        .{snapshot_path},
    );
}

pub fn dupeSkillBindings(alloc: std.mem.Allocator, bindings: []const SkillBinding) ![]SkillBinding {
    if (bindings.len == 0) return &.{};
    const copy = try alloc.alloc(SkillBinding, bindings.len);
    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) {
            alloc.free(copy[i].name);
            alloc.free(copy[i].path);
        }
        alloc.free(copy);
    }
    while (filled < bindings.len) : (filled += 1) {
        copy[filled] = .{
            .name = try alloc.dupe(u8, bindings[filled].name),
            .path = try alloc.dupe(u8, bindings[filled].path),
        };
    }
    return copy;
}

pub fn freeSkillBindings(alloc: std.mem.Allocator, bindings: []SkillBinding) void {
    for (bindings) |binding| {
        alloc.free(binding.name);
        alloc.free(binding.path);
    }
    if (bindings.len > 0) alloc.free(bindings);
}

pub fn dupeSkillDisplaySpans(alloc: std.mem.Allocator, spans: []const SkillDisplaySpan) ![]SkillDisplaySpan {
    if (spans.len == 0) return &.{};
    const copy = try alloc.alloc(SkillDisplaySpan, spans.len);
    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) {
            alloc.free(copy[i].name);
            alloc.free(copy[i].path);
        }
        alloc.free(copy);
    }
    while (filled < spans.len) : (filled += 1) {
        copy[filled] = .{
            .raw_start = spans[filled].raw_start,
            .raw_end = spans[filled].raw_end,
            .name = try alloc.dupe(u8, spans[filled].name),
            .path = try alloc.dupe(u8, spans[filled].path),
            .display_source = spans[filled].display_source,
            .owns_trailing_separator = spans[filled].owns_trailing_separator,
        };
    }
    return copy;
}

pub fn freeSkillDisplaySpans(alloc: std.mem.Allocator, spans: []SkillDisplaySpan) void {
    for (spans) |span| {
        alloc.free(span.name);
        alloc.free(span.path);
    }
    if (spans.len > 0) alloc.free(spans);
}

pub fn dupeWorkerEvent(alloc: std.mem.Allocator, event: WorkerEvent) !WorkerEvent {
    return switch (event) {
        .begin_prompt => |prompt| .{ .begin_prompt = try types.dupeUserTurn(alloc, prompt) },
        .begin_prompt_with_skill_bindings => |begin| blk: {
            const prompt = try types.dupeUserTurn(alloc, begin.prompt);
            errdefer types.freeUserTurn(alloc, prompt);
            const skill_bindings = try dupeSkillBindings(alloc, begin.skill_bindings);
            errdefer freeSkillBindings(alloc, skill_bindings);
            const skill_display_spans = try dupeSkillDisplaySpans(alloc, begin.skill_display_spans);
            break :blk .{ .begin_prompt_with_skill_bindings = .{
                .prompt = prompt,
                .skill_bindings = skill_bindings,
                .skill_display_spans = skill_display_spans,
            } };
        },
        .append_user_feedback => |text| .{ .append_user_feedback = try alloc.dupe(u8, text) },
        .assistant_presentation => |presentation| .{
            .assistant_presentation = try presentation.clone(alloc),
        },
        .notification => |notification| .{ .notification = notification },
        .question_requested => .question_requested,
        .open_model_picker => .open_model_picker,
        .semantic_notice => |notice| .{ .semantic_notice = try types.dupeSemanticNotice(alloc, notice) },
        .route_recovery_status => |status| .{ .route_recovery_status = status },
        .clear_route_recovery_status => .clear_route_recovery_status,
        .api_status_text => |text| .{ .api_status_text = try alloc.dupe(u8, text) },
        .command_output => |chunk| .{ .command_output = .{
            .lifecycle_id = if (chunk.lifecycle_id) |id| .{
                .turn_id = id.turn_id,
                .call_id = try alloc.dupe(u8, id.call_id),
            } else null,
            .stream = chunk.stream,
            .text = try alloc.dupe(u8, chunk.text),
        } },
        .command_output_complete => |lifecycle_id| .{ .command_output_complete = if (lifecycle_id) |id| .{
            .turn_id = id.turn_id,
            .call_id = try alloc.dupe(u8, id.call_id),
        } else null },
        .tool_lifecycle => |lifecycle| .{
            .tool_lifecycle = try dupeToolLifecycleEvent(alloc, lifecycle),
        },
        .turn_token_update => |update| .{ .turn_token_update = update },
        .tool_payload_started => .tool_payload_started,
        .diff_block => |payload| blk: {
            const preview = try alloc.dupe(u8, payload.preview);
            errdefer alloc.free(preview);
            const full = if (payload.full) |source| full_value: {
                const content = try alloc.dupe(u8, source.content);
                errdefer alloc.free(content);
                const call_id = try alloc.dupe(u8, source.lifecycle_id.call_id);
                break :full_value diff_mod.FullDiff{
                    .content = content,
                    .lifecycle_id = .{
                        .turn_id = source.lifecycle_id.turn_id,
                        .call_id = call_id,
                    },
                };
            } else null;
            errdefer if (full) |owned| owned.deinit(alloc);
            break :blk .{ .diff_block = .{
                .preview = preview,
                .additions = payload.additions,
                .deletions = payload.deletions,
                .full = full,
            } };
        },
        .finish_prompt => |finished| .{ .finish_prompt = try types.dupeFinishedPrompt(alloc, finished) },
        .session_grant => |grant| blk: {
            const tool_name = try alloc.dupe(u8, grant.tool_name);
            errdefer alloc.free(tool_name);
            const target_path = try alloc.dupe(u8, grant.target_path);
            break :blk .{ .session_grant = .{
                .tool_name = tool_name,
                .target_path = target_path,
            } };
        },
        .error_text => |notice| .{ .error_text = try types.dupeSemanticNotice(alloc, notice) },
    };
}

pub fn freeWorkerEvent(alloc: std.mem.Allocator, event: WorkerEvent) void {
    switch (event) {
        .begin_prompt => |prompt| types.freeUserTurn(alloc, prompt),
        .begin_prompt_with_skill_bindings => |begin| {
            types.freeUserTurn(alloc, begin.prompt);
            freeSkillBindings(alloc, begin.skill_bindings);
            freeSkillDisplaySpans(alloc, begin.skill_display_spans);
        },
        .append_user_feedback => |text| alloc.free(text),
        .assistant_presentation => |presentation| {
            var owned = presentation;
            owned.deinit(alloc);
        },
        .notification => {},
        .open_model_picker => {},
        .semantic_notice => |notice| types.freeSemanticNotice(alloc, notice),
        .route_recovery_status => {},
        .clear_route_recovery_status => {},
        .api_status_text => |text| alloc.free(text),
        .command_output => |chunk| {
            if (chunk.lifecycle_id) |id| alloc.free(@constCast(id.call_id));
            alloc.free(chunk.text);
        },
        .command_output_complete => |lifecycle_id| {
            if (lifecycle_id) |id| alloc.free(@constCast(id.call_id));
        },
        .tool_lifecycle => |lifecycle| freeToolLifecycleEvent(alloc, lifecycle),
        .diff_block => |payload| diff_mod.freeDiffEntryPayload(alloc, payload),
        .finish_prompt => |finished| types.freeFinishedPrompt(alloc, finished),
        .session_grant => |grant| {
            alloc.free(grant.tool_name);
            alloc.free(grant.target_path);
        },
        .error_text => |notice| types.freeSemanticNotice(alloc, notice),
        else => {},
    }
}

pub fn dupeToolLifecycleEvent(
    alloc: std.mem.Allocator,
    event: types.ToolLifecycleEvent,
) !types.ToolLifecycleEvent {
    return switch (event) {
        .provisional => |started| blk: {
            const call_id = try alloc.dupe(u8, started.id.call_id);
            errdefer alloc.free(call_id);
            const tool_name = if (started.tool_name) |name| try alloc.dupe(u8, name) else null;
            break :blk .{ .provisional = .{
                .id = .{ .turn_id = started.id.turn_id, .call_id = call_id },
                .presentation_group_id = started.presentation_group_id,
                .tool_name = tool_name,
                .activity_kind = started.activity_kind,
            } };
        },
        .authoritative_started => |started| blk: {
            const call_id = try alloc.dupe(u8, started.id.call_id);
            errdefer alloc.free(call_id);
            const alias = if (started.reconciles_provisional_call_id) |value|
                try alloc.dupe(u8, value)
            else
                null;
            errdefer if (alias) |value| alloc.free(value);
            const tool_name = try alloc.dupe(u8, started.tool_name);
            errdefer alloc.free(tool_name);
            const arguments_json = if (started.arguments_json) |value|
                try alloc.dupe(u8, value)
            else
                null;
            errdefer if (arguments_json) |value| alloc.free(value);
            break :blk .{ .authoritative_started = .{
                .id = .{ .turn_id = started.id.turn_id, .call_id = call_id },
                .presentation_group_id = started.presentation_group_id,
                .reconciles_provisional_call_id = alias,
                .tool_name = tool_name,
                .activity_kind = started.activity_kind,
                .arguments_json = arguments_json,
                .place_after_current_transcript = started.place_after_current_transcript,
            } };
        },
        .progress => |progress| blk: {
            const call_id = try alloc.dupe(u8, progress.id.call_id);
            errdefer alloc.free(call_id);
            const text = try alloc.dupe(u8, progress.text);
            break :blk .{ .progress = .{
                .id = .{ .turn_id = progress.id.turn_id, .call_id = call_id },
                .text = text,
            } };
        },
        .terminal => |terminal| blk: {
            const call_id = try alloc.dupe(u8, terminal.id.call_id);
            errdefer alloc.free(call_id);
            const summary = try alloc.dupe(u8, terminal.outcome.summary);
            errdefer alloc.free(summary);
            const result = if (terminal.result) |value|
                try alloc.dupe(u8, value)
            else
                null;
            errdefer if (result) |value| alloc.free(value);
            const result_memory = try dupeToolResultMemory(alloc, terminal.result_memory);
            errdefer freeToolResultMemory(alloc, result_memory);
            const command_artifact_handle = if (terminal.command_artifact_handle) |handle|
                try alloc.dupe(u8, handle)
            else
                null;
            errdefer if (command_artifact_handle) |handle| alloc.free(handle);
            break :blk .{ .terminal = .{
                .id = .{ .turn_id = terminal.id.turn_id, .call_id = call_id },
                .outcome = .{
                    .kind = terminal.outcome.kind,
                    .summary = summary,
                },
                .result = result,
                .result_memory = result_memory,
                .command_artifact_handle = command_artifact_handle,
            } };
        },
        .turn_finished => |finished| .{ .turn_finished = finished },
    };
}

pub fn freeToolLifecycleEvent(
    alloc: std.mem.Allocator,
    event: types.ToolLifecycleEvent,
) void {
    switch (event) {
        .provisional => |started| {
            alloc.free(@constCast(started.id.call_id));
            if (started.tool_name) |name| alloc.free(@constCast(name));
        },
        .authoritative_started => |started| {
            alloc.free(@constCast(started.id.call_id));
            if (started.reconciles_provisional_call_id) |alias| {
                alloc.free(@constCast(alias));
            }
            alloc.free(@constCast(started.tool_name));
            if (started.arguments_json) |arguments_json| {
                alloc.free(@constCast(arguments_json));
            }
        },
        .progress => |progress| {
            alloc.free(@constCast(progress.id.call_id));
            alloc.free(@constCast(progress.text));
        },
        .terminal => |terminal| {
            alloc.free(@constCast(terminal.id.call_id));
            alloc.free(@constCast(terminal.outcome.summary));
            if (terminal.result) |result| alloc.free(@constCast(result));
            freeToolResultMemory(alloc, terminal.result_memory);
            if (terminal.command_artifact_handle) |handle| alloc.free(@constCast(handle));
        },
        .turn_finished => {},
    }
}

fn dupeToolResultMemory(
    alloc: std.mem.Allocator,
    source: ?types.ToolResultMemory,
) !?types.ToolResultMemory {
    const memory = source orelse return null;
    const output_handle = if (memory.output_handle) |handle|
        try alloc.dupe(u8, handle)
    else
        null;
    errdefer if (output_handle) |handle| alloc.free(handle);
    const preview = if (memory.preview) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (preview) |value| alloc.free(value);
    const command_output_replay = if (memory.command_output_replay) |replay|
        try types.dupeCommandOutputReplay(alloc, replay)
    else
        null;
    errdefer if (command_output_replay) |replay| types.freeCommandOutputReplay(alloc, replay);
    return .{
        .output_handle = output_handle,
        .preview = preview,
        .output_bytes = memory.output_bytes,
        .stored_output_bytes = memory.stored_output_bytes,
        .truncated = memory.truncated,
        .model_view_covers_full_file = memory.model_view_covers_full_file,
        .command_output_replay = command_output_replay,
        .command_process_presentation = memory.command_process_presentation,
    };
}

fn freeToolResultMemory(
    alloc: std.mem.Allocator,
    memory: ?types.ToolResultMemory,
) void {
    const value = memory orelse return;
    if (value.output_handle) |handle| alloc.free(@constCast(handle));
    if (value.preview) |preview| alloc.free(@constCast(preview));
    if (value.command_output_replay) |replay| {
        types.freeCommandOutputReplay(alloc, replay);
    }
}

fn makePrompt(alloc: std.mem.Allocator, text: []const u8, model: []const u8) !QueuedPrompt {
    return .{
        .prompt = try alloc.dupe(u8, text),
        .images = &.{},
        .model = try alloc.dupe(u8, model),
        .api_key = try alloc.dupe(u8, "key"),
        .permission_mode = .auto,
        .history = try alloc.alloc(types.HistoryTurn, 0),
        .grants = try alloc.alloc(types.PermissionGrant, 0),
    };
}

fn makeGrant(alloc: std.mem.Allocator, tool_name: []const u8, target_path: []const u8) !types.PermissionGrant {
    return .{ .tool_name = try alloc.dupe(u8, tool_name), .target_path = try alloc.dupe(u8, target_path) };
}

fn makePromptWithGrant(alloc: std.mem.Allocator, text: []const u8, model: []const u8, tool_name: []const u8, target_path: []const u8) !QueuedPrompt {
    var prompt = try makePrompt(alloc, text, model);
    errdefer freeQueuedPrompt(alloc, prompt);
    const grants = try alloc.alloc(types.PermissionGrant, 1);
    grants[0] = try makeGrant(alloc, tool_name, target_path);
    alloc.free(prompt.grants);
    prompt.grants = grants;
    return prompt;
}

fn freeEventList(alloc: std.mem.Allocator, events: *std.ArrayList(WorkerEvent)) void {
    for (events.items) |event| freeWorkerEvent(alloc, event);
    events.deinit(alloc);
}

test "request shutdown sets stop and cancel flags" {
    var runtime = WorkerRuntime{};
    defer runtime.deinit(std.testing.allocator);
    runtime.requestShutdown();
    try std.testing.expect(runtime.worker_stop_requested);
    try std.testing.expect(runtime.worker_cancel_requested.load(.seq_cst));
}

test "takeEventBatch snapshots cancellation with detached events" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    runtime.worker_cancel_requested.store(true, .seq_cst);
    runtime.worker_recovery_pause_requested.store(true, .seq_cst);
    try runtime.pushEvent(alloc, .{ .assistant_presentation = .{
        .text = @constCast("late"),
    } });

    var batch = runtime.takeEventBatch();
    defer freeEventList(alloc, &batch.events);
    try std.testing.expect(batch.cancel_requested);
    try std.testing.expectEqual(@as(usize, 1), batch.events.items.len);
    try std.testing.expect(batch.events.items[0] == .assistant_presentation);
    try std.testing.expect(batch.events.items[0].assistant_presentation == .text);
    try std.testing.expectEqual(@as(usize, 0), runtime.worker_events.items.len);
}

test "state snapshot reports completion queued after event batch detach" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    try runtime.pushEvent(alloc, .{ .command_output = .{
        .stream = .stdout,
        .text = @constCast("record\n"),
    } });
    var batch = runtime.takeEventBatch();
    defer freeEventList(alloc, &batch.events);
    try runtime.pushEvent(alloc, .{ .command_output_complete = null });

    var snapshot = try runtime.snapshotState(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), snapshot.pending_event_count);
    try std.testing.expectEqual(@as(usize, 1), batch.events.items.len);
    try std.testing.expect(batch.events.items[0] == .command_output);
    try std.testing.expect(runtime.worker_events.items[0] == .command_output_complete);
}

fn checkStateSnapshotFailurePreservesPendingEvents(alloc: std.mem.Allocator) !void {
    const owner_alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(owner_alloc);

    try runtime.pushEvent(owner_alloc, .{ .command_output_complete = null });
    runtime.worker_processing = true;
    runtime.pending_permission_waiting = true;
    runtime.pending_permission_request_shared =
        try permission_request.OwnedPermissionRequest.dupe(
            owner_alloc,
            .{ .id = 17, .label = "pending command completion" },
        );

    var snapshot = runtime.snapshotState(alloc) catch |err| {
        try std.testing.expectEqual(@as(usize, 1), runtime.worker_events.items.len);
        try std.testing.expect(runtime.worker_events.items[0] == .command_output_complete);
        try std.testing.expectEqualStrings(
            "pending command completion",
            runtime.pending_permission_request_shared.?.label,
        );
        return err;
    };
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), snapshot.pending_event_count);
    try std.testing.expectEqual(@as(usize, 1), runtime.worker_events.items.len);
    try std.testing.expect(runtime.worker_events.items[0] == .command_output_complete);
}

test "state snapshot allocation failures preserve pending event ownership" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkStateSnapshotFailurePreservesPendingEvents,
        .{},
    );
}

test "finalization failure latches fixed metadata and closes interactive admission" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    try std.testing.expect(runtime.interactiveAdmissionSnapshot() == .open);
    runtime.latchFinalizationFailure(.{
        .turn_id = 41,
        .outcome = .failed,
    });
    runtime.latchFinalizationFailure(.{
        .turn_id = 42,
        .outcome = .interrupted,
    });

    switch (runtime.interactiveAdmissionSnapshot()) {
        .finalization_failed => |failure| {
            try std.testing.expectEqual(@as(u64, 41), failure.turn_id);
            try std.testing.expectEqual(types.TurnPresentationOutcome.failed, failure.outcome);
        },
        else => return error.TestExpectedEqual,
    }
    try std.testing.expect(runtime.worker_stop_requested);
    try std.testing.expect(runtime.worker_cancel_requested.load(.seq_cst));

    const prompt = try makePrompt(alloc, "rejected", "model");
    try std.testing.expectError(error.TurnFinalizationDeliveryFailed, runtime.enqueuePrompt(alloc, prompt));
    freeQueuedPrompt(alloc, prompt);
    try std.testing.expectEqual(@as(usize, 0), runtime.queued_prompts.items.len);
}

test "dedicated turn finalizer queues before optional finish payload" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    try runtime.pushTurnFinished(alloc, .{
        .turn_id = 99,
        .outcome = .completed,
    });
    try runtime.pushEvent(alloc, .{ .finish_prompt = .{
        .turn = .{ .assistant = .{
            .user = .{ .text = @constCast("prompt") },
            .assistant = @constCast("answer"),
        } },
    } });

    var events = runtime.takeEvents();
    defer freeEventList(alloc, &events);
    try std.testing.expectEqual(@as(usize, 2), events.items.len);
    try std.testing.expect(events.items[0] == .tool_lifecycle);
    try std.testing.expectEqual(
        @as(u64, 99),
        events.items[0].tool_lifecycle.turn_finished.turn_id,
    );
    try std.testing.expect(events.items[1] == .finish_prompt);
}

test "queue, event, snapshot, sync, history, and grant behavior" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    const first_prompt = try makePrompt(alloc, "first", "old");
    try runtime.enqueuePrompt(alloc, first_prompt);
    const second_prompt = try makePrompt(alloc, "second", "old");
    try runtime.enqueuePrompt(alloc, second_prompt);
    try std.testing.expectEqual(@as(usize, 2), runtime.queuePreview().count);

    runtime.worker_cancel_requested.store(true, .seq_cst);
    const job = (try runtime.waitAndTakeNextPrompt(alloc)).?;
    defer freeQueuedPrompt(alloc, job);
    try std.testing.expect(job.turn_id != 0);
    try std.testing.expectEqualStrings("first", job.prompt);
    try std.testing.expect(!runtime.isCancelRequested());
    try std.testing.expect(runtime.worker_processing);
    try std.testing.expectEqual(@as(usize, 1), runtime.queuedPromptCount());

    var events = runtime.takeEvents();
    defer freeEventList(alloc, &events);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expect(events.items[0] == .begin_prompt);
    try std.testing.expectEqualStrings("first", events.items[0].begin_prompt.text);
    try std.testing.expect(events.items[0].begin_prompt.text.ptr != job.prompt.ptr);

    try runtime.syncQueuedPromptModel(alloc, "next");
    try std.testing.expectEqualStrings("next", runtime.queued_prompts.items[0].model);
    runtime.syncQueuedPromptPermissionSnapshot(.{
        .mode = .ask,
    });
    try std.testing.expectEqual(types.PermissionMode.ask, runtime.queued_prompts.items[0].permission_mode);
    try std.testing.expectEqual(types.PermissionMode.auto, job.permission_mode);

    const grant_source = try alloc.alloc(types.PermissionGrant, 1);
    defer types.freePermissionGrantSlice(alloc, grant_source);
    grant_source[0] = try makeGrant(alloc, "read_file", "/tmp/a");
    try runtime.syncQueuedPromptPermissionState(alloc, grant_source, .{
        .mode = .auto,
    });
    grant_source[0].tool_name[0] = 'R';
    grant_source[0].target_path[1] = 'T';
    try std.testing.expectEqualStrings("read_file", runtime.queued_prompts.items[0].grants[0].tool_name);
    try std.testing.expectEqualStrings("/tmp/a", runtime.queued_prompts.items[0].grants[0].target_path);

    const old_turn: types.HistoryTurn = .{ .compacted_summary = .{
        .summary = try alloc.dupe(u8, "old"),
        .removed_turn_count = 0,
        .compaction_count = 0,
    } };
    defer types.freeHistoryTurn(alloc, old_turn);
    runtime.queued_prompts.items[0].history = try session_runtime.appendHistoryTurnToOwnedContext(alloc, runtime.queued_prompts.items[0].history, old_turn, 2);
    const turn: types.HistoryTurn = .{ .compacted_summary = .{
        .summary = try alloc.dupe(u8, "summary"),
        .removed_turn_count = 0,
        .compaction_count = 0,
    } };
    defer types.freeHistoryTurn(alloc, turn);
    try runtime.propagateHistoryTurn(alloc, turn, 1);
    try std.testing.expectEqual(@as(usize, 1), runtime.queued_prompts.items[0].history.len);
    try std.testing.expect(runtime.queued_prompts.items[0].history[0] == .compacted_summary);
    try std.testing.expectEqualStrings("summary", runtime.queued_prompts.items[0].history[0].compacted_summary.summary);

    try runtime.propagateGrant(alloc, "read_file", "/tmp/a");
    try std.testing.expectEqual(@as(usize, 1), runtime.queued_prompts.items[0].grants.len);
    try runtime.propagateGrant(alloc, "read_file", "/tmp/b");
    try std.testing.expectEqual(@as(usize, 2), runtime.queued_prompts.items[0].grants.len);

    runtime.worker_processing = true;
    runtime.pending_permission_waiting = true;
    runtime.pending_permission_request_shared =
        try permission_request.OwnedPermissionRequest.dupe(
            alloc,
            .{ .id = 1, .label = "pending" },
        );
    var snapshot = try runtime.snapshotState(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqualStrings("pending", snapshot.pending_permission_request.?.label);
    try std.testing.expect(
        snapshot.pending_permission_request.?.label.ptr !=
            runtime.pending_permission_request_shared.?.label.ptr,
    );
}

test "permission response durable barrier commits before waiter wake" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);
    runtime.worker_processing = true;
    runtime.pending_permission_waiting = true;
    runtime.pending_permission_request_shared =
        try permission_request.OwnedPermissionRequest.dupe(
            alloc,
            .{ .id = 9, .label = "prepared action" },
        );

    const Capture = struct {
        runtime: *WorkerRuntime,
        committed: bool = false,

        fn commit(raw: *anyopaque) WorkerRuntime.PermissionCommitError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.runtime.pending_permission_response != null) {
                return error.PermissionCommitFailed;
            }
            self.committed = true;
        }
    };
    var capture = Capture{ .runtime = &runtime };
    const result = try runtime.submitPermissionResponseAfterCommit(
        9,
        permission_request.OwnedPermissionResponse.init(alloc, .always, null),
        .{ .context = &capture, .commit_fn = Capture.commit },
    );
    try std.testing.expectEqual(PermissionSubmissionResult.accepted, result);
    try std.testing.expect(capture.committed);
    try std.testing.expect(runtime.pending_permission_response != null);
}

test "permission response durable barrier failure does not wake waiter" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);
    runtime.worker_processing = true;
    runtime.pending_permission_waiting = true;
    runtime.pending_permission_request_shared =
        try permission_request.OwnedPermissionRequest.dupe(
            alloc,
            .{ .id = 10, .label = "prepared action" },
        );

    const Fail = struct {
        fn commit(_: *anyopaque) WorkerRuntime.PermissionCommitError!void {
            return error.PermissionCommitFailed;
        }
    };
    try std.testing.expectError(
        error.PermissionCommitFailed,
        runtime.submitPermissionResponseAfterCommit(
            10,
            permission_request.OwnedPermissionResponse.init(alloc, .once, null),
            .{ .context = &runtime, .commit_fn = Fail.commit },
        ),
    );
    try std.testing.expect(runtime.pending_permission_response == null);
    try std.testing.expect(runtime.pending_permission_waiting);
}

test "permission capacity rejection removes the unpublished waiter" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    const Reject = struct {
        fn observe(
            _: *anyopaque,
            _: *WorkerRuntime,
            _: permission_request.PermissionRequest,
        ) error{
            OutOfMemory,
            PermissionRegistrationFailed,
            PermissionCapacityExceeded,
        }!void {
            return error.PermissionCapacityExceeded;
        }
    };
    try std.testing.expectError(
        error.PermissionCapacityExceeded,
        runtime.requestPermissionBlockingObserved(
            alloc,
            .{ .id = 11, .label = "capacity-bound action" },
            null,
            .{ .context = &runtime, .observe_fn = Reject.observe },
        ),
    );
    try std.testing.expect(!runtime.pending_permission_waiting);
    try std.testing.expect(runtime.pending_permission_request_shared == null);
    try std.testing.expect(runtime.pending_permission_review == null);
    try std.testing.expect(runtime.pending_permission_response == null);
}

test "waitAndTakeNextPrompt emits bound skill prompt event when queued prompt has bindings" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    var prompt = try makePrompt(alloc, "raw $review then $review and $review", "model");
    errdefer freeQueuedPrompt(alloc, prompt);
    prompt.skill_bindings = try dupeSkillBindings(alloc, &[_]SkillBinding{.{
        .name = @constCast("review"),
        .path = @constCast("/tmp/.codex/skills/review"),
    }});
    prompt.skill_display_spans = try dupeSkillDisplaySpans(alloc, &[_]SkillDisplaySpan{
        .{
            .raw_start = "raw $review then ".len,
            .raw_end = "raw $review then $review".len,
            .name = @constCast("review"),
            .path = @constCast("/tmp/.codex/skills/review"),
            .display_source = .workspace_codex,
            .owns_trailing_separator = true,
        },
        .{
            .raw_start = "raw $review then $review and ".len,
            .raw_end = "raw $review then $review and $review".len,
            .name = @constCast("review"),
            .path = @constCast("/tmp/.codex/skills/review"),
        },
    });
    try runtime.enqueuePrompt(alloc, prompt);

    const job = (try runtime.waitAndTakeNextPrompt(alloc)).?;
    defer freeQueuedPrompt(alloc, job);

    var events = runtime.takeEvents();
    defer freeEventList(alloc, &events);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expect(events.items[0] == .begin_prompt_with_skill_bindings);
    try std.testing.expectEqualStrings("raw $review then $review and $review", events.items[0].begin_prompt_with_skill_bindings.prompt.text);
    try std.testing.expectEqual(@as(usize, 1), events.items[0].begin_prompt_with_skill_bindings.skill_bindings.len);
    try std.testing.expectEqualStrings("review", events.items[0].begin_prompt_with_skill_bindings.skill_bindings[0].name);
    try std.testing.expectEqualStrings("/tmp/.codex/skills/review", events.items[0].begin_prompt_with_skill_bindings.skill_bindings[0].path);
    try std.testing.expectEqual(@as(usize, 2), events.items[0].begin_prompt_with_skill_bindings.skill_display_spans.len);
    try std.testing.expectEqual(@as(usize, "raw $review then ".len), events.items[0].begin_prompt_with_skill_bindings.skill_display_spans[0].raw_start);
    try std.testing.expectEqual(@as(usize, "raw $review then $review".len), events.items[0].begin_prompt_with_skill_bindings.skill_display_spans[0].raw_end);
    try std.testing.expectEqualStrings("review", events.items[0].begin_prompt_with_skill_bindings.skill_display_spans[0].name);
    try std.testing.expectEqual(
        skill_contract.SkillSource.workspace_codex,
        events.items[0].begin_prompt_with_skill_bindings.skill_display_spans[0].display_source.?,
    );
    try std.testing.expect(events.items[0].begin_prompt_with_skill_bindings.skill_display_spans[0].owns_trailing_separator);
}

test "permission snapshot keeps the full file review borrowed and request-bound" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);
    var review = try diff_mod.FileReview.init(
        alloc,
        "",
        "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\n",
    );
    defer review.deinit(alloc);

    runtime.worker_processing = true;
    runtime.pending_permission_waiting = true;
    runtime.pending_permission_request_shared =
        try permission_request.OwnedPermissionRequest.dupe(
            alloc,
            .{
                .id = 44,
                .label = "file_mutation",
                .file = .{
                    .kind = .write,
                    .intent = .mutation,
                    .preview = .{
                        .path = "note.txt",
                        .lines = &.{
                            .{ .op = .addition, .new_line = 1, .text = "line 1" },
                            .{ .op = .addition, .new_line = 7, .text = "line 7" },
                        },
                        .additions = 7,
                        .deletions = 0,
                        .truncated = true,
                    },
                    .scope = .workspace_files,
                },
            },
        );
    runtime.pending_permission_review = &review;

    var snapshot = try runtime.snapshotState(alloc);
    defer snapshot.deinit(alloc);

    try std.testing.expectEqual(
        @as(usize, 2),
        snapshot.pending_permission_request.?.file.?.preview.lines.len,
    );
    try std.testing.expectEqual(@as(u64, 44), snapshot.pending_permission_review.?.request_id);
    try std.testing.expect(snapshot.pending_permission_review.?.review == &review);
    try std.testing.expectEqual(@as(usize, 7), snapshot.pending_permission_review.?.review.rowCount());
}

test "held turn propagation refreshes queued prompt trusted reviewer context" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    var queued = try makePrompt(alloc, "queued current prompt", "model");
    var canonical_history = [_]types.HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("original first request") },
        .assistant = @constCast("original answer"),
    } }};
    queued.root_user_intent_context = try auto_classifier_context.buildCanonicalRootUserContext(
        alloc,
        queued.prompt,
        &canonical_history,
    );
    try runtime.enqueuePrompt(alloc, queued);
    const original_prompt_ptr = runtime.queued_prompts.items[0].prompt.ptr;
    const original_prompt_len = runtime.queued_prompts.items[0].prompt.len;

    const turn: types.HistoryTurn = .{ .assistant = .{
        .user = .{ .text = try alloc.dupe(u8, "Revoke permission: do not modify any more files.") },
        .assistant = try alloc.dupe(u8, "completed prior answer"),
    } };
    defer types.freeHistoryTurn(alloc, turn);

    try runtime.propagateHistoryTurn(alloc, turn, 8);

    try std.testing.expectEqual(@as(usize, 1), runtime.queued_prompts.items[0].history.len);
    try std.testing.expect(runtime.queued_prompts.items[0].history[0] == .assistant);
    try std.testing.expectEqualStrings("Revoke permission: do not modify any more files.", runtime.queued_prompts.items[0].history[0].assistant.user.text);
    try std.testing.expectEqualStrings("completed prior answer", runtime.queued_prompts.items[0].history[0].assistant.assistant);
    try std.testing.expectEqualStrings("queued current prompt", runtime.queued_prompts.items[0].prompt);
    try std.testing.expectEqual(original_prompt_len, runtime.queued_prompts.items[0].prompt.len);
    try std.testing.expect(original_prompt_ptr == runtime.queued_prompts.items[0].prompt.ptr);

    const review_context = runtime.queued_prompts.items[0].root_user_intent_context;
    try std.testing.expect(std.mem.find(
        u8,
        review_context,
        "first_root_user_request: original first request",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        review_context,
        "recent_root_user_request: Revoke permission: do not modify any more files.",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        review_context,
        "current_request: queued current prompt",
    ) != null);

    const newer_turn: types.HistoryTurn = .{ .assistant = .{
        .user = .{ .text = try alloc.dupe(u8, "newer completed request") },
        .assistant = try alloc.dupe(u8, "newer completed answer"),
    } };
    defer types.freeHistoryTurn(alloc, newer_turn);
    try runtime.propagateHistoryTurn(alloc, newer_turn, 8);
    const refreshed = runtime.queued_prompts.items[0].root_user_intent_context;
    try std.testing.expect(std.mem.find(
        u8,
        refreshed,
        "recent_root_user_request: Revoke permission: do not modify any more files.",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        refreshed,
        "recent_root_user_request: newer completed request",
    ) != null);
}

test "queue review preserves FIFO identity while replacing an editable draft" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    try runtime.enqueuePrompt(alloc, try makePrompt(alloc, "first queued", "model"));
    try runtime.enqueuePrompt(alloc, try makePrompt(alloc, "second queued", "model"));
    const first_turn_id = runtime.queued_prompts.items[0].turn_id;
    const second_turn_id = runtime.queued_prompts.items[1].turn_id;

    try std.testing.expect(runtime.beginQueueReview(.manual));
    try std.testing.expectEqual(QueueReviewReason.manual, runtime.queueReviewReason().?);
    const preview = runtime.queuePreview();
    try std.testing.expect(preview.paused);
    try std.testing.expectEqual(@as(usize, 2), preview.count);

    const drafts = try runtime.snapshotQueuedPromptDrafts(alloc);
    defer freeQueuedPromptDrafts(alloc, drafts);
    try std.testing.expectEqual(@as(usize, 2), drafts.len);
    try std.testing.expectEqualStrings("first queued", drafts[0].prompt);
    try std.testing.expectEqualStrings("second queued", drafts[1].prompt);

    alloc.free(drafts[0].prompt);
    drafts[0].prompt = try alloc.dupe(u8, "first queued edited");
    try std.testing.expect(try runtime.replaceQueuedPromptDrafts(alloc, drafts[0..1]));

    const turn: types.HistoryTurn = .{ .interrupted = .{
        .user = .{ .text = try alloc.dupe(u8, "active") },
        .assistant = try alloc.dupe(u8, "partial"),
    } };
    defer types.freeHistoryTurn(alloc, turn);
    try runtime.propagateHistoryTurn(alloc, turn, 8);

    try std.testing.expectEqual(first_turn_id, runtime.queued_prompts.items[0].turn_id);
    try std.testing.expectEqual(second_turn_id, runtime.queued_prompts.items[1].turn_id);
    try std.testing.expectEqualStrings("first queued edited", runtime.queued_prompts.items[0].prompt);
    try std.testing.expectEqualStrings("second queued", runtime.queued_prompts.items[1].prompt);
    try std.testing.expectEqual(@as(usize, 1), runtime.queued_prompts.items[0].history.len);
    try std.testing.expectEqual(@as(usize, 1), runtime.queued_prompts.items[1].history.len);

    try std.testing.expect(runtime.resumeQueueReview());
    const first = (try runtime.waitAndTakeNextPrompt(alloc)).?;
    defer freeQueuedPrompt(alloc, first);
    try std.testing.expectEqualStrings("first queued edited", first.prompt);
    runtime.finishProcessing();
    const second = (try runtime.waitAndTakeNextPrompt(alloc)).?;
    defer freeQueuedPrompt(alloc, second);
    try std.testing.expectEqualStrings("second queued", second.prompt);
}

test "queue review snapshot owns semantic draft through replacement but not execution" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    const compact = "before [Pasted text #7, 1 line] $review";
    const backing = "pasted backing";
    var prompt = try makePrompt(
        alloc,
        "before pasted backing $review",
        "model",
    );
    errdefer freeQueuedPrompt(alloc, prompt);
    var pasted_blocks = [_]paste_blocks.PastedBlock{.{
        .id = 7,
        .text = @constCast(backing),
        .line_count = 1,
        .span = .{
            .raw_start = "before ".len,
            .raw_end = "before [Pasted text #7, 1 line]".len,
        },
    }};
    var image_tokens = [_]entity_spans.ImageTokenSpan{.{
        .id = 3,
        .span = .{
            .raw_start = 0,
            .raw_end = 6,
        },
    }};
    var review_skills = [_]SkillDisplaySpan{.{
        .raw_start = compact.len - "$review".len,
        .raw_end = compact.len,
        .name = @constCast("review"),
        .path = @constCast("/tmp/review"),
    }};
    prompt.review_draft = try dupeQueueReviewDraft(alloc, .{
        .input = @constCast(compact),
        .pasted_blocks = &pasted_blocks,
        .image_tokens = &image_tokens,
        .skill_display_spans = &review_skills,
    });
    try runtime.enqueuePrompt(alloc, prompt);

    try std.testing.expect(runtime.beginQueueReview(.manual));
    const drafts = try runtime.snapshotQueuedPromptDrafts(alloc);
    defer freeQueuedPromptDrafts(alloc, drafts);
    const snapshot = drafts[0].review_draft.?;
    try std.testing.expectEqualStrings(compact, snapshot.input);
    try std.testing.expectEqualStrings(backing, snapshot.pasted_blocks[0].text);
    try std.testing.expectEqual(@as(usize, 3), snapshot.image_tokens[0].id);
    try std.testing.expectEqualStrings(
        "/tmp/review",
        snapshot.skill_display_spans[0].path,
    );
    try std.testing.expect(
        snapshot.input.ptr != runtime.queued_prompts.items[0].review_draft.?.input.ptr,
    );
    try std.testing.expect(
        snapshot.pasted_blocks[0].text.ptr !=
            runtime.queued_prompts.items[0].review_draft.?.pasted_blocks[0].text.ptr,
    );

    alloc.free(drafts[0].prompt);
    drafts[0].prompt = try alloc.dupe(u8, "edited replacement backing");
    freeQueueReviewDraft(alloc, drafts[0].review_draft.?);
    var replacement_blocks = [_]paste_blocks.PastedBlock{.{
        .id = 8,
        .text = @constCast("replacement backing"),
        .line_count = 1,
        .span = .{
            .raw_start = "edited ".len,
            .raw_end = "edited [Pasted text #8, 1 line]".len,
        },
    }};
    drafts[0].review_draft = try dupeQueueReviewDraft(alloc, .{
        .input = @constCast("edited [Pasted text #8, 1 line]"),
        .pasted_blocks = &replacement_blocks,
    });
    try std.testing.expect(try runtime.replaceQueuedPromptDrafts(
        alloc,
        drafts,
    ));
    try std.testing.expectEqualStrings(
        "edited replacement backing",
        runtime.queued_prompts.items[0].prompt,
    );
    try std.testing.expectEqualStrings(
        "edited [Pasted text #8, 1 line]",
        runtime.queued_prompts.items[0].review_draft.?.input,
    );
    try std.testing.expectEqualStrings(
        "replacement backing",
        runtime.queued_prompts.items[0].review_draft.?.pasted_blocks[0].text,
    );

    try std.testing.expect(runtime.resumeQueueReview());
    const job = (try runtime.waitAndTakeNextPrompt(alloc)).?;
    defer freeQueuedPrompt(alloc, job);
    try std.testing.expectEqualStrings("edited replacement backing", job.prompt);
    try std.testing.expect(job.review_draft == null);
}

test "queue review atomically rebuilds owned image authority" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    const current = [_]types.ImageAttachment{.{
        .id = 8,
        .path = @constCast("/tmp/current.png"),
        .media_type = @constCast("image/png"),
    }};
    const authority = [_]types.ImageAttachment{
        .{ .id = 2, .path = @constCast("/tmp/history.png"), .media_type = @constCast("image/png") },
        current[0],
    };
    var prompt = try makePrompt(alloc, "queued", "model");
    prompt.images = try types.dupeImageAttachmentSlice(alloc, &current);
    prompt.authorized_image_catalog = try types.dupeImageAttachmentSlice(alloc, &authority);
    try runtime.enqueuePrompt(alloc, prompt);

    try std.testing.expect(runtime.beginQueueReview(.manual));
    const drafts = try runtime.snapshotQueuedPromptDrafts(alloc);
    defer freeQueuedPromptDrafts(alloc, drafts);
    types.freeImageAttachmentSlice(alloc, drafts[0].images);
    drafts[0].images = try types.dupeImageAttachmentSlice(alloc, &.{.{
        .id = 9,
        .path = @constCast("/tmp/replacement.jpg"),
        .media_type = @constCast("image/jpeg"),
    }});

    try std.testing.expect(try runtime.replaceQueuedPromptDrafts(alloc, drafts));
    const queued = runtime.queued_prompts.items[0];
    try std.testing.expectEqual(@as(usize, 1), queued.images.len);
    try std.testing.expectEqual(@as(usize, 9), queued.images[0].id);
    try std.testing.expectEqual(@as(usize, 2), queued.authorized_image_catalog.len);
    try std.testing.expectEqual(@as(usize, 2), queued.authorized_image_catalog[0].id);
    try std.testing.expectEqual(@as(usize, 9), queued.authorized_image_catalog[1].id);
}

test "queue review rejects a stale image catalog without replacing the draft" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    const current = [_]types.ImageAttachment{.{
        .id = 8,
        .path = @constCast("/tmp/current.png"),
        .media_type = @constCast("image/png"),
    }};
    var prompt = try makePrompt(alloc, "queued", "model");
    prompt.images = try types.dupeImageAttachmentSlice(alloc, &current);
    prompt.authorized_image_catalog = try types.dupeImageAttachmentSlice(alloc, &.{.{
        .id = 2,
        .path = @constCast("/tmp/history.png"),
        .media_type = @constCast("image/png"),
    }});
    try runtime.enqueuePrompt(alloc, prompt);

    try std.testing.expect(runtime.beginQueueReview(.manual));
    const drafts = try runtime.snapshotQueuedPromptDrafts(alloc);
    defer freeQueuedPromptDrafts(alloc, drafts);
    alloc.free(drafts[0].prompt);
    drafts[0].prompt = try alloc.dupe(u8, "edited");

    try std.testing.expectError(
        error.StaleImageCatalog,
        runtime.replaceQueuedPromptDrafts(alloc, drafts),
    );
    try std.testing.expectEqualStrings("queued", runtime.queued_prompts.items[0].prompt);
    try std.testing.expectEqual(@as(usize, 8), runtime.queued_prompts.items[0].images[0].id);
}

test "queue review catalog growth failure preserves queued ownership" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    const current = [_]types.ImageAttachment{.{
        .id = 8,
        .path = @constCast("/tmp/current.png"),
        .media_type = @constCast("image/png"),
    }};
    var prompt = try makePrompt(alloc, "queued", "model");
    prompt.images = try types.dupeImageAttachmentSlice(alloc, &current);
    prompt.authorized_image_catalog = try types.dupeImageAttachmentSlice(alloc, &current);
    try runtime.enqueuePrompt(alloc, prompt);
    try std.testing.expect(runtime.beginQueueReview(.manual));

    const drafts = try runtime.snapshotQueuedPromptDrafts(alloc);
    defer freeQueuedPromptDrafts(alloc, drafts);
    alloc.free(drafts[0].prompt);
    drafts[0].prompt = try alloc.dupe(u8, "edited");
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 5 });
    try std.testing.expectError(
        error.OutOfMemory,
        runtime.replaceQueuedPromptDrafts(failing.allocator(), drafts),
    );

    const queued = runtime.queued_prompts.items[0];
    try std.testing.expectEqualStrings("queued", queued.prompt);
    try std.testing.expectEqual(@as(usize, 8), queued.images[0].id);
    try std.testing.expectEqual(@as(usize, 8), queued.authorized_image_catalog[0].id);
}

test "completed image turns propagate authority to queued follow-ups" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    var prompt = try makePrompt(alloc, "queued follow-up", "model");
    prompt.authorized_image_catalog = try types.dupeImageAttachmentSlice(alloc, &.{.{
        .id = 2,
        .path = @constCast("/tmp/older.png"),
        .media_type = @constCast("image/png"),
    }});
    try runtime.enqueuePrompt(alloc, prompt);

    var completed_images = [_]types.ImageAttachment{.{
        .id = 8,
        .path = @constCast("/tmp/completed.png"),
        .media_type = @constCast("image/png"),
    }};
    const turn: types.HistoryTurn = .{ .assistant = .{
        .user = .{ .text = @constCast("active image turn"), .images = &completed_images },
        .assistant = @constCast("done"),
    } };
    try runtime.propagateHistoryTurn(alloc, turn, 1);

    const queued = runtime.queued_prompts.items[0];
    try std.testing.expectEqual(@as(usize, 2), queued.authorized_image_catalog.len);
    try std.testing.expectEqual(@as(usize, 2), queued.authorized_image_catalog[0].id);
    try std.testing.expectEqual(@as(usize, 8), queued.authorized_image_catalog[1].id);
    try std.testing.expectEqualStrings("/tmp/completed.png", queued.authorized_image_catalog[1].path);
}

test "queue review batch replaces every edited draft atomically in FIFO order" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    try runtime.enqueuePrompt(alloc, try makePrompt(alloc, "first queued", "model"));
    try runtime.enqueuePrompt(alloc, try makePrompt(alloc, "second queued", "model"));
    const first_turn_id = runtime.queued_prompts.items[0].turn_id;
    const second_turn_id = runtime.queued_prompts.items[1].turn_id;
    try std.testing.expect(runtime.beginQueueReview(.manual));

    const drafts = try runtime.snapshotQueuedPromptDrafts(alloc);
    defer freeQueuedPromptDrafts(alloc, drafts);
    alloc.free(drafts[0].prompt);
    drafts[0].prompt = try alloc.dupe(u8, "first queued edited");
    alloc.free(drafts[1].prompt);
    drafts[1].prompt = try alloc.dupe(u8, "second queued edited");

    drafts[1].turn_id = std.math.maxInt(u64);
    try std.testing.expect(!try runtime.replaceQueuedPromptDrafts(alloc, drafts));
    try std.testing.expectEqualStrings("first queued", runtime.queued_prompts.items[0].prompt);
    try std.testing.expectEqualStrings("second queued", runtime.queued_prompts.items[1].prompt);

    drafts[1].turn_id = second_turn_id;
    try std.testing.expect(try runtime.replaceQueuedPromptDrafts(alloc, drafts));
    try std.testing.expectEqual(first_turn_id, runtime.queued_prompts.items[0].turn_id);
    try std.testing.expectEqual(second_turn_id, runtime.queued_prompts.items[1].turn_id);
    try std.testing.expectEqualStrings("first queued edited", runtime.queued_prompts.items[0].prompt);
    try std.testing.expectEqualStrings("second queued edited", runtime.queued_prompts.items[1].prompt);

    try std.testing.expect(runtime.resumeQueueReview());
    const first = (try runtime.waitAndTakeNextPrompt(alloc)).?;
    defer freeQueuedPrompt(alloc, first);
    try std.testing.expectEqualStrings("first queued edited", first.prompt);
    runtime.finishProcessing();
    const second = (try runtime.waitAndTakeNextPrompt(alloc)).?;
    defer freeQueuedPrompt(alloc, second);
    try std.testing.expectEqualStrings("second queued edited", second.prompt);
}

test "queue review deletes one draft by identity without opening admission" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    try runtime.enqueuePrompt(alloc, try makePrompt(alloc, "first queued", "model"));
    try runtime.enqueuePrompt(alloc, try makePrompt(alloc, "second queued", "model"));
    try runtime.enqueuePrompt(alloc, try makePrompt(alloc, "third queued", "model"));
    const second_turn_id = runtime.queued_prompts.items[1].turn_id;

    try std.testing.expect(runtime.beginQueueReview(.manual));
    try std.testing.expect(runtime.deleteQueuedPromptDraft(alloc, second_turn_id, &.{}));
    try std.testing.expect(!runtime.deleteQueuedPromptDraft(alloc, second_turn_id, &.{}));
    try std.testing.expectEqual(@as(usize, 2), runtime.queuedPromptCount());
    try std.testing.expectEqual(QueueReviewReason.manual, runtime.queueReviewReason().?);
    try std.testing.expectEqualStrings("first queued", runtime.queued_prompts.items[0].prompt);
    try std.testing.expectEqualStrings("third queued", runtime.queued_prompts.items[1].prompt);
}

test "queue removal deletes its uncommitted image snapshot" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var snapshot = try tmp.dir.createFile(std.testing.io, "queued-image.bin", .{});
        defer snapshot.close(std.testing.io);
        try snapshot.writeStreamingAll(std.testing.io, "queued image");
    }
    const snapshot_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "queued-image.bin");
    defer alloc.free(snapshot_path);

    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);
    var prompt = try makePrompt(alloc, "queued image", "model");
    errdefer freeQueuedPrompt(alloc, prompt);
    prompt.images = try types.dupeImageAttachmentSlice(alloc, &.{.{
        .id = 1,
        .path = @constCast("/tmp/original.png"),
        .media_type = @constCast("image/png"),
        .snapshot_path = @constCast(snapshot_path),
        .snapshot_sha256 = @constCast("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"),
    }});
    prompt.authorized_image_catalog = try types.dupeImageAttachmentSlice(alloc, prompt.images);
    try runtime.enqueuePrompt(alloc, prompt);
    const turn_id = runtime.queued_prompts.items[0].turn_id;

    try std.testing.expect(runtime.deleteQueuedPromptDraft(alloc, turn_id, &.{}));
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.openFileAbsolute(std.testing.io, snapshot_path, .{}),
    );
}

test "queue removal preserves retained snapshots and deletes unreferenced snapshots" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{
        "retained.bin",
        "delete-one.bin",
        "clear-all.bin",
    }) |name| {
        var snapshot = try tmp.dir.createFile(std.testing.io, name, .{});
        defer snapshot.close(std.testing.io);
        try snapshot.writeStreamingAll(std.testing.io, name);
    }

    const retained_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "retained.bin");
    defer alloc.free(retained_path);
    const delete_one_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "delete-one.bin");
    defer alloc.free(delete_one_path);
    const clear_all_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "clear-all.bin");
    defer alloc.free(clear_all_path);

    const retained_images = [_]types.ImageAttachment{.{
        .id = 1,
        .path = @constCast("/tmp/retained.png"),
        .media_type = @constCast("image/png"),
        .snapshot_path = retained_path,
        .snapshot_sha256 = @constCast("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"),
    }};

    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);
    {
        var prompt = try makePrompt(alloc, "delete one", "model");
        errdefer freeQueuedPrompt(alloc, prompt);
        const images = [_]types.ImageAttachment{
            retained_images[0],
            .{
                .id = 2,
                .path = @constCast("/tmp/delete-one.png"),
                .media_type = @constCast("image/png"),
                .snapshot_path = delete_one_path,
                .snapshot_sha256 = @constCast("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"),
            },
        };
        prompt.images = try types.dupeImageAttachmentSlice(alloc, &images);
        prompt.authorized_image_catalog = try types.dupeImageAttachmentSlice(alloc, prompt.images);
        try runtime.enqueuePrompt(alloc, prompt);
    }

    const turn_id = runtime.queued_prompts.items[0].turn_id;
    try std.testing.expect(runtime.deleteQueuedPromptDraft(
        alloc,
        turn_id,
        &retained_images,
    ));
    try std.Io.Dir.accessAbsolute(std.testing.io, retained_path, .{});
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(std.testing.io, delete_one_path, .{}),
    );

    {
        var prompt = try makePrompt(alloc, "clear all", "model");
        errdefer freeQueuedPrompt(alloc, prompt);
        const images = [_]types.ImageAttachment{
            retained_images[0],
            .{
                .id = 3,
                .path = @constCast("/tmp/clear-all.png"),
                .media_type = @constCast("image/png"),
                .snapshot_path = clear_all_path,
                .snapshot_sha256 = @constCast("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"),
            },
        };
        prompt.images = try types.dupeImageAttachmentSlice(alloc, &images);
        prompt.authorized_image_catalog = try types.dupeImageAttachmentSlice(alloc, prompt.images);
        try runtime.enqueuePrompt(alloc, prompt);
    }

    runtime.clearQueuedPrompts(alloc, &retained_images);
    try std.Io.Dir.accessAbsolute(std.testing.io, retained_path, .{});
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(std.testing.io, clear_all_path, .{}),
    );
}

const QueueTakeThreadState = struct {
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    err: ?anyerror = null,
    job: ?QueuedPrompt = null,
};

fn runQueueTake(state: *QueueTakeThreadState, runtime: *WorkerRuntime) void {
    state.started.store(true, .seq_cst);
    state.job = runtime.waitAndTakeNextPrompt(std.testing.allocator) catch |err| {
        state.err = err;
        state.finished.store(true, .seq_cst);
        return;
    };
    state.finished.store(true, .seq_cst);
}

test "paused queue admission blocks the next prompt until review resumes" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    try runtime.enqueuePrompt(alloc, try makePrompt(alloc, "blocked queued prompt", "model"));
    try std.testing.expect(runtime.beginQueueReview(.manual));

    var state = QueueTakeThreadState{};
    const thread = try std.Thread.spawn(.{}, runQueueTake, .{ &state, &runtime });
    var joined = false;
    defer if (!joined) {
        _ = runtime.resumeQueueReview();
        runtime.requestStop();
        thread.join();
    };

    var attempts: usize = 0;
    while (!state.started.load(.seq_cst) and attempts < 100) : (attempts += 1) {
        io_mod.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(state.started.load(.seq_cst));
    io_mod.sleep(10 * std.time.ns_per_ms);
    try std.testing.expect(!state.finished.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), runtime.queuedPromptCount());

    try std.testing.expect(runtime.resumeQueueReview());
    thread.join();
    joined = true;
    try std.testing.expect(state.err == null);
    const job = state.job.?;
    defer freeQueuedPrompt(alloc, job);
    try std.testing.expectEqualStrings("blocked queued prompt", job.prompt);
}

test "explicit cancellation pauses queued admission for post-cancel review" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    runtime.worker_processing = true;
    try runtime.enqueuePrompt(alloc, try makePrompt(alloc, "queued", "model"));

    try std.testing.expect(runtime.requestCancelWithQueueReview());
    try std.testing.expect(runtime.isCancelRequested());
    try std.testing.expectEqual(QueueReviewReason.post_cancel, runtime.queueReviewReason().?);
    var snapshot = try runtime.snapshotState(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), snapshot.queued_count);
    try std.testing.expectEqual(QueueReviewReason.post_cancel, snapshot.queue_review_reason.?);
}

test "turn start hold rejects busy worker and blocks take while held" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    runtime.worker_processing = true;
    try std.testing.expect(!runtime.tryHoldTurnStart());
    runtime.worker_processing = false;

    try runtime.enqueuePrompt(alloc, try makePrompt(alloc, "queued blocks park", "model"));
    try std.testing.expect(!runtime.tryHoldTurnStart());
    runtime.clearQueuedPrompts(alloc, &.{});

    try std.testing.expect(runtime.tryHoldTurnStart());
    try std.testing.expect(!runtime.tryHoldTurnStart());

    try runtime.enqueuePrompt(alloc, try makePrompt(alloc, "held blocked prompt", "model"));
    var state = QueueTakeThreadState{};
    const thread = try std.Thread.spawn(.{}, runQueueTake, .{ &state, &runtime });
    var joined = false;
    defer if (!joined) {
        runtime.releaseTurnStartHold();
        runtime.requestStop();
        thread.join();
    };

    var attempts: usize = 0;
    while (!state.started.load(.seq_cst) and attempts < 100) : (attempts += 1) {
        io_mod.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(state.started.load(.seq_cst));
    io_mod.sleep(10 * std.time.ns_per_ms);
    try std.testing.expect(!state.finished.load(.seq_cst));

    runtime.releaseTurnStartHold();
    thread.join();
    joined = true;
    try std.testing.expect(state.err == null);
    const job = state.job.?;
    defer freeQueuedPrompt(alloc, job);
    try std.testing.expectEqualStrings("held blocked prompt", job.prompt);
}

test "waitAndTakeNextPrompt assigns turn id and resets cancellation for next prompt" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    runtime.worker_cancel_requested.store(true, .seq_cst);
    try runtime.enqueuePrompt(alloc, try makePrompt(alloc, "next", "model"));
    try std.testing.expect(runtime.isCancelRequested());
    try std.testing.expectEqual(@as(usize, 1), runtime.queuedPromptCount());

    const job = (try runtime.waitAndTakeNextPrompt(alloc)).?;
    defer freeQueuedPrompt(alloc, job);

    try std.testing.expect(job.turn_id != 0);
    try std.testing.expect(!runtime.isCancelRequested());
    try std.testing.expect(!runtime.worker_recovery_pause_requested.load(.seq_cst));

    var events = runtime.takeEvents();
    defer freeEventList(alloc, &events);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expect(events.items[0] == .begin_prompt);
}

test "requestRecoveryPause wakes the active operation without losing pause intent" {
    var worker = WorkerRuntime{};
    worker.requestRecoveryPause();
    try std.testing.expect(worker.worker_recovery_pause_requested.load(.seq_cst));
    try std.testing.expect(worker.worker_cancel_requested.load(.seq_cst));
}

test "enqueuePrompt stamps agent settings from worker runtime" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    runtime.agent_turn_settings = .{
        .max_tool_result_bytes = 4096,
        .first_call_tool_choice = .none,
    };
    try runtime.enqueuePrompt(alloc, try makePrompt(alloc, "next", "model"));
    const job = (try runtime.waitAndTakeNextPrompt(alloc)).?;
    defer freeQueuedPrompt(alloc, job);

    try std.testing.expectEqual(@as(usize, 4096), job.agent_settings.max_tool_result_bytes);
    try std.testing.expectEqual(types.ToolChoice.none, job.agent_settings.first_call_tool_choice);
}

test "enqueuePrompt stamps fast mode and effort from worker runtime" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    runtime.agent_turn_settings = .{
        .fast_mode = true,
        .effort = types.ReasoningEffort.literal("high"),
    };

    try runtime.enqueuePrompt(alloc, try makePrompt(alloc, "next", "model"));
    const job = (try runtime.waitAndTakeNextPrompt(alloc)).?;
    defer freeQueuedPrompt(alloc, job);

    try std.testing.expect(job.agent_settings.fast_mode);
    try std.testing.expectEqual(types.ReasoningEffort.literal("high"), job.agent_settings.effort);
}

test "sync queued prompt fast mode and effort updates queued prompts and future defaults" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    runtime.agent_turn_settings = .{
        .fast_mode = false,
        .effort = types.ReasoningEffort.literal("low"),
    };
    try runtime.enqueuePrompt(alloc, try makePrompt(alloc, "queued", "model"));

    runtime.syncQueuedPromptFastMode(true);
    runtime.syncQueuedPromptEffort(types.ReasoningEffort.literal("high"));

    try std.testing.expect(runtime.queued_prompts.items[0].agent_settings.fast_mode);
    try std.testing.expectEqual(types.ReasoningEffort.literal("high"), runtime.queued_prompts.items[0].agent_settings.effort);
    try std.testing.expect(runtime.agent_turn_settings.fast_mode);
    try std.testing.expectEqual(types.ReasoningEffort.literal("high"), runtime.agent_turn_settings.effort);

    try runtime.enqueuePrompt(alloc, try makePrompt(alloc, "future", "model"));

    try std.testing.expect(runtime.queued_prompts.items[1].agent_settings.fast_mode);
    try std.testing.expectEqual(types.ReasoningEffort.literal("high"), runtime.queued_prompts.items[1].agent_settings.effort);
}

const EnqueueThreadState = struct {
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    err: ?anyerror = null,
};

fn runEnqueuePrompt(state: *EnqueueThreadState, runtime: *WorkerRuntime, text: []const u8, model: []const u8) void {
    const prompt = makePrompt(std.testing.allocator, text, model) catch |err| {
        state.err = err;
        return;
    };
    state.started.store(true, .seq_cst);
    runtime.enqueuePrompt(std.testing.allocator, prompt) catch |err| {
        freeQueuedPrompt(std.testing.allocator, prompt);
        state.err = err;
        return;
    };
}

fn waitForEnqueueThreadStart(state: *EnqueueThreadState) !void {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (state.started.load(.seq_cst)) return;
        io_mod.sleep(1 * std.time.ns_per_ms);
    }
    return error.TestExpectedEqual;
}

test "enqueuePrompt snapshots settings under the same mutex as sync" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    runtime.agent_turn_settings = .{
        .fast_mode = false,
        .effort = types.ReasoningEffort.literal("low"),
    };

    runtime.worker_mutex.lockUncancelable(io_mod.getIo());
    var state = EnqueueThreadState{};
    const thread = try std.Thread.spawn(.{}, runEnqueuePrompt, .{ &state, &runtime, "blocked", "model" });
    try waitForEnqueueThreadStart(&state);
    io_mod.sleep(10 * std.time.ns_per_ms);
    runtime.agent_turn_settings.fast_mode = true;
    runtime.agent_turn_settings.effort = types.ReasoningEffort.literal("high");
    runtime.worker_mutex.unlock(io_mod.getIo());
    thread.join();

    try std.testing.expect(state.err == null);
    try std.testing.expectEqual(@as(usize, 1), runtime.queued_prompts.items.len);
    try std.testing.expect(runtime.queued_prompts.items[0].agent_settings.fast_mode);
    try std.testing.expectEqual(types.ReasoningEffort.literal("high"), runtime.queued_prompts.items[0].agent_settings.effort);
}

test "taken prompt keeps original fast mode and effort after later sync" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    runtime.agent_turn_settings = .{
        .fast_mode = true,
        .effort = types.ReasoningEffort.literal("high"),
    };
    try runtime.enqueuePrompt(alloc, try makePrompt(alloc, "active", "model"));

    const job = (try runtime.waitAndTakeNextPrompt(alloc)).?;
    defer freeQueuedPrompt(alloc, job);

    runtime.syncQueuedPromptFastMode(false);
    runtime.syncQueuedPromptEffort(types.ReasoningEffort.literal("low"));

    try std.testing.expect(job.agent_settings.fast_mode);
    try std.testing.expectEqual(types.ReasoningEffort.literal("high"), job.agent_settings.effort);
    try std.testing.expect(!runtime.agent_turn_settings.fast_mode);
    try std.testing.expectEqual(types.ReasoningEffort.literal("low"), runtime.agent_turn_settings.effort);
}

test "effectiveAgentTurnSettings prefers active turn settings until cleared" {
    var runtime = WorkerRuntime{};
    defer runtime.deinit(std.testing.allocator);

    runtime.agent_turn_settings = .{
        .max_tool_result_bytes = 2048,
        .first_call_tool_choice = .auto,
        .fast_mode = false,
        .effort = types.ReasoningEffort.literal("low"),
    };
    try std.testing.expectEqual(@as(usize, 2048), runtime.effectiveAgentTurnSettings().max_tool_result_bytes);
    try std.testing.expect(!runtime.effectiveAgentTurnSettings().fast_mode);
    try std.testing.expectEqual(types.ReasoningEffort.literal("low"), runtime.effectiveAgentTurnSettings().effort);

    runtime.setActiveAgentTurnSettings(.{
        .max_tool_result_bytes = 4096,
        .first_call_tool_choice = .none,
        .fast_mode = true,
        .effort = types.ReasoningEffort.literal("high"),
    });

    const active = runtime.effectiveAgentTurnSettings();
    try std.testing.expectEqual(@as(usize, 4096), active.max_tool_result_bytes);
    try std.testing.expectEqual(types.ToolChoice.none, active.first_call_tool_choice);
    try std.testing.expect(active.fast_mode);
    try std.testing.expectEqual(types.ReasoningEffort.literal("high"), active.effort);

    runtime.clearActiveAgentTurnSettings();
    const fallback = runtime.effectiveAgentTurnSettings();
    try std.testing.expectEqual(@as(usize, 2048), fallback.max_tool_result_bytes);
    try std.testing.expect(!fallback.fast_mode);
    try std.testing.expectEqual(types.ReasoningEffort.literal("low"), fallback.effort);
}

test "effective permission snapshot keeps a held turn mode until cleared" {
    var runtime = WorkerRuntime{};
    defer runtime.deinit(std.testing.allocator);

    runtime.setActivePermissionSnapshot(.{
        .mode = .auto,
    });
    const active = runtime.effectivePermissionSnapshot(.{
        .mode = .ask,
    });
    try std.testing.expectEqual(types.PermissionMode.auto, active.mode);

    runtime.clearActivePermissionSnapshot();
    const next = runtime.effectivePermissionSnapshot(.{
        .mode = .ask,
    });
    try std.testing.expectEqual(types.PermissionMode.ask, next.mode);
}

test "queued permission mode updates from ask to auto without rewriting held turn" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    var held_prompt = try makePrompt(alloc, "held", "model");
    held_prompt.permission_mode = .ask;
    try runtime.enqueuePrompt(alloc, held_prompt);
    var queued_prompt = try makePrompt(alloc, "queued", "model");
    queued_prompt.permission_mode = .ask;
    try runtime.enqueuePrompt(alloc, queued_prompt);

    const active = (try runtime.waitAndTakeNextPrompt(alloc)).?;
    defer freeQueuedPrompt(alloc, active);
    runtime.syncQueuedPromptPermissionSnapshot(.{
        .mode = .auto,
    });

    try std.testing.expectEqual(types.PermissionMode.ask, active.permission_mode);
    try std.testing.expectEqual(types.PermissionMode.auto, runtime.queued_prompts.items[0].permission_mode);
}

test "submitted text only queues while a prompt is active" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    try runtime.enqueuePrompt(alloc, try makePrompt(alloc, "use all your tools", "model"));
    const active = (try runtime.waitAndTakeNextPrompt(alloc)).?;
    defer freeQueuedPrompt(alloc, active);
    try std.testing.expect(runtime.worker_processing);
    try std.testing.expect(!runtime.isCancelRequested());

    runtime.pending_permission_waiting = true;
    runtime.pending_permission_request_shared =
        try permission_request.OwnedPermissionRequest.dupe(
            alloc,
            .{ .id = 1, .label = "terminal.exec launch chrome" },
        );
    const question_options = [_]types.QuestionOption{.{ .label = "Wait", .description = null }};
    const question_entries = [_]types.QuestionBatchEntry{.{
        .question = "Keep waiting?",
        .options = &question_options,
    }};
    runtime.pending_question_shared = try dupeOwnedQuestionBatch(
        alloc,
        &question_entries,
        .agent_question,
    );

    const submitted = [_][]const u8{
        "Stop",
        "continue",
        "What are you doing right now?",
        "What files are in this repository?",
        "checkpoint?",
    };
    for (submitted) |text| {
        try runtime.enqueuePrompt(alloc, try makePrompt(alloc, text, "model"));
        try std.testing.expect(!runtime.isCancelRequested());
        try std.testing.expect(runtime.pending_permission_response == null);
        try std.testing.expect(runtime.pending_permission_request_shared != null);
        try std.testing.expect(runtime.pending_question_shared != null);
        try std.testing.expect(runtime.pending_question_response == .pending);
    }

    try std.testing.expectEqual(submitted.len, runtime.queuedPromptCount());
    for (submitted, runtime.queued_prompts.items) |expected, queued| {
        try std.testing.expectEqualStrings(expected, queued.prompt);
    }
}

test "editing queued text cannot cancel active work" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    try runtime.enqueuePrompt(alloc, try makePrompt(alloc, "active", "model"));
    const active = (try runtime.waitAndTakeNextPrompt(alloc)).?;
    defer freeQueuedPrompt(alloc, active);
    try runtime.enqueuePrompt(alloc, try makePrompt(alloc, "queued", "model"));

    runtime.pending_permission_waiting = true;
    runtime.pending_permission_request_shared =
        try permission_request.OwnedPermissionRequest.dupe(
            alloc,
            .{ .id = 2, .label = "write_file fixture" },
        );
    const question_options = [_]types.QuestionOption{.{ .label = "Wait", .description = null }};
    const question_entries = [_]types.QuestionBatchEntry{.{
        .question = "Keep waiting?",
        .options = &question_options,
    }};
    runtime.pending_question_shared = try dupeOwnedQuestionBatch(
        alloc,
        &question_entries,
        .agent_question,
    );

    try std.testing.expect(runtime.beginQueueReview(.manual));
    const drafts = try runtime.snapshotQueuedPromptDrafts(alloc);
    defer freeQueuedPromptDrafts(alloc, drafts);
    alloc.free(drafts[0].prompt);
    drafts[0].prompt = try alloc.dupe(u8, "Stop");
    try std.testing.expect(try runtime.replaceQueuedPromptDrafts(alloc, drafts));

    try std.testing.expectEqualStrings("Stop", runtime.queued_prompts.items[0].prompt);
    try std.testing.expect(!runtime.isCancelRequested());
    try std.testing.expect(runtime.pending_permission_response == null);
    try std.testing.expect(runtime.pending_permission_request_shared != null);
    try std.testing.expect(runtime.pending_question_shared != null);
    try std.testing.expect(runtime.pending_question_response == .pending);
}

test "prompt take and grant append allocation failures preserve state" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    try runtime.enqueuePrompt(alloc, try makePromptWithGrant(alloc, "keep", "model", "read_file", "/tmp/a"));
    runtime.worker_cancel_requested.store(true, .seq_cst);
    var failing_take = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, runtime.waitAndTakeNextPrompt(failing_take.allocator()));
    try std.testing.expectEqual(@as(usize, 1), runtime.queuedPromptCount());
    try std.testing.expectEqualStrings("keep", runtime.queued_prompts.items[0].prompt);
    try std.testing.expect(runtime.isCancelRequested());
    try std.testing.expectEqual(@as(usize, 0), runtime.worker_events.items.len);

    const original = runtime.queued_prompts.items[0].grants.ptr;
    var failing_grant = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 1 });
    try std.testing.expectError(error.OutOfMemory, runtime.propagateGrant(failing_grant.allocator(), "write_file", "/tmp/b"));
    try std.testing.expectEqual(original, runtime.queued_prompts.items[0].grants.ptr);
    try std.testing.expectEqual(@as(usize, 1), runtime.queued_prompts.items[0].grants.len);

    var failing_slice = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 2 });
    try std.testing.expectError(error.OutOfMemory, runtime.propagateGrant(failing_slice.allocator(), "write_file", "/tmp/c"));
    try std.testing.expectEqual(original, runtime.queued_prompts.items[0].grants.ptr);
    try std.testing.expectEqual(@as(usize, 1), runtime.queued_prompts.items[0].grants.len);
}

test "clear queued prompts preserves events and discard frees event payloads" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    try runtime.enqueuePrompt(alloc, try makePrompt(alloc, "drop", "model"));
    try runtime.pushEvent(alloc, .{ .assistant_presentation = .{
        .text = @constCast("kept"),
    } });
    runtime.clearQueuedPrompts(alloc, &.{});
    try std.testing.expectEqual(@as(usize, 0), runtime.queuedPromptCount());
    try std.testing.expectEqual(@as(usize, 0), runtime.queued_prompts.items.len);
    try std.testing.expectEqual(@as(usize, 1), runtime.worker_events.items.len);

    runtime.discardEvents(alloc);
    try std.testing.expectEqual(@as(usize, 0), runtime.worker_events.items.len);

    freeQueuedPrompt(alloc, try makePrompt(alloc, "free", "model"));
    freeWorkerEvent(alloc, .{ .begin_prompt = try types.dupeUserTurn(alloc, .{ .text = @constCast("user"), .images = &.{} }) });
    freeWorkerEvent(alloc, .{ .assistant_presentation = .{
        .text = try alloc.dupe(u8, "append"),
    } });
    const table = try assistant_presentation.parseTablePayload(alloc, "| H |\n|---|\n| v |\n");
    freeWorkerEvent(alloc, .{ .assistant_presentation = .{ .table = table } });
    freeWorkerEvent(alloc, try dupeWorkerEvent(alloc, .{ .semantic_notice = .{
        .topic = "system",
        .tone = .information,
        .body = "notice",
    } }));
    freeWorkerEvent(alloc, .{ .route_recovery_status = .{ .kind = .auto_retry, .failed_attempt = 1, .attempt_limit = 3 } });
    freeWorkerEvent(alloc, .clear_route_recovery_status);
    freeWorkerEvent(alloc, .{ .command_output = .{ .stream = .stdout, .text = try alloc.dupe(u8, "out") } });
    freeWorkerEvent(alloc, .{ .command_output_complete = null });
    freeWorkerEvent(alloc, .{ .command_output_complete = .{ .turn_id = 1, .call_id = try alloc.dupe(u8, "1") } });
    freeWorkerEvent(alloc, .{ .tool_lifecycle = .{
        .provisional = .{
            .id = .{ .turn_id = 1, .call_id = try alloc.dupe(u8, "1") },
            .tool_name = try alloc.dupe(u8, "read_file"),
            .activity_kind = .read,
        },
    } });
    freeWorkerEvent(alloc, .{ .tool_lifecycle = .{
        .progress = .{
            .id = .{ .turn_id = 1, .call_id = try alloc.dupe(u8, "1") },
            .text = try alloc.dupe(u8, "reading"),
        },
    } });
    freeWorkerEvent(alloc, .{ .tool_lifecycle = .{
        .terminal = .{
            .id = .{ .turn_id = 1, .call_id = try alloc.dupe(u8, "1") },
            .outcome = .{
                .kind = .completed,
                .summary = try alloc.dupe(u8, "read"),
            },
        },
    } });
    freeWorkerEvent(alloc, .{ .turn_token_update = .{ .input_tokens = 10, .output_tokens = 5 } });
    freeWorkerEvent(alloc, .{ .diff_block = .{ .preview = try alloc.dupe(u8, "preview") } });
    freeWorkerEvent(alloc, .{ .tool_lifecycle = .{
        .turn_finished = .{ .turn_id = 1, .outcome = .completed },
    } });
    freeWorkerEvent(alloc, .{ .finish_prompt = .{ .turn = .{ .compacted_summary = .{
        .summary = try alloc.dupe(u8, "summary"),
        .removed_turn_count = 1,
        .compaction_count = 1,
    } } } });
    freeWorkerEvent(alloc, .{ .session_grant = try makeGrant(alloc, "read_file", "/tmp/a") });
    freeWorkerEvent(alloc, try dupeWorkerEvent(alloc, .{ .error_text = .{
        .topic = "system",
        .tone = .@"error",
        .body = "err",
    } }));
}

test "typed lifecycle worker events duplicate and free every payload variant" {
    const alloc = std.testing.allocator;
    const events = [_]types.ToolLifecycleEvent{
        .{ .provisional = .{
            .id = .{ .turn_id = 1, .call_id = "provisional" },
            .presentation_group_id = .{ .turn_id = 1, .anchor_step_id = 3 },
            .tool_name = "read_file",
            .activity_kind = .read,
        } },
        .{ .provisional = .{
            .id = .{ .turn_id = 1, .call_id = "provisional" },
            .tool_name = "list_files",
            .activity_kind = .list,
        } },
        .{ .authoritative_started = .{
            .id = .{ .turn_id = 1, .call_id = "final" },
            .presentation_group_id = .{ .turn_id = 1, .anchor_step_id = 3 },
            .reconciles_provisional_call_id = "provisional",
            .tool_name = "list_files",
            .activity_kind = .list,
        } },
        .{ .progress = .{
            .id = .{ .turn_id = 1, .call_id = "final" },
            .text = "Listing files",
        } },
        .{ .terminal = .{
            .id = .{ .turn_id = 1, .call_id = "final" },
            .outcome = .{ .kind = .completed, .summary = "Listed files" },
            .command_artifact_handle = "fx-command-final.log",
        } },
        .{ .turn_finished = .{ .turn_id = 1, .outcome = .completed } },
    };

    for (events) |event| {
        const owned = try dupeToolLifecycleEvent(alloc, event);
        freeToolLifecycleEvent(alloc, owned);
    }
}

fn checkToolLifecycleDupAllocationFailure(alloc: std.mem.Allocator) !void {
    const owned = try dupeToolLifecycleEvent(alloc, .{ .authoritative_started = .{
        .id = .{ .turn_id = 7, .call_id = "final" },
        .reconciles_provisional_call_id = "provisional",
        .tool_name = "read_file",
        .activity_kind = .read,
    } });
    defer freeToolLifecycleEvent(alloc, owned);

    try std.testing.expectEqualStrings(
        "final",
        owned.authoritative_started.id.call_id,
    );
    try std.testing.expectEqualStrings(
        "provisional",
        owned.authoritative_started.reconciles_provisional_call_id.?,
    );
    try std.testing.expectEqualStrings(
        "read_file",
        owned.authoritative_started.tool_name,
    );
}

test "typed lifecycle duplication frees every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkToolLifecycleDupAllocationFailure,
        .{},
    );
}

test "pushEvent copies session grants into queue allocator" {
    const source_alloc = std.testing.allocator;
    const queue_alloc = std.heap.c_allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(queue_alloc);

    const grant = try makeGrant(source_alloc, "read_file", "/tmp/source.zig");
    const tool_ptr = grant.tool_name.ptr;
    const target_ptr = grant.target_path.ptr;

    try runtime.pushEvent(queue_alloc, .{ .session_grant = grant });
    source_alloc.free(grant.tool_name);
    source_alloc.free(grant.target_path);

    var events = runtime.takeEvents();
    defer freeEventList(queue_alloc, &events);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expect(events.items[0] == .session_grant);
    try std.testing.expectEqualStrings("read_file", events.items[0].session_grant.tool_name);
    try std.testing.expectEqualStrings("/tmp/source.zig", events.items[0].session_grant.target_path);
    try std.testing.expect(events.items[0].session_grant.tool_name.ptr != tool_ptr);
    try std.testing.expect(events.items[0].session_grant.target_path.ptr != target_ptr);
}

test "pushEvent copies string events into queue allocator" {
    const source_alloc = std.testing.allocator;
    const queue_alloc = std.heap.c_allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(queue_alloc);

    const text = try source_alloc.dupe(u8, "borrowed assistant text");
    const text_ptr = text.ptr;

    try runtime.pushEvent(queue_alloc, .{ .assistant_presentation = .{ .text = text } });
    source_alloc.free(text);

    var events = runtime.takeEvents();
    defer freeEventList(queue_alloc, &events);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expect(events.items[0] == .assistant_presentation);
    try std.testing.expect(events.items[0].assistant_presentation == .text);
    try std.testing.expectEqualStrings("borrowed assistant text", events.items[0].assistant_presentation.text);
    try std.testing.expect(events.items[0].assistant_presentation.text.ptr != text_ptr);
}

test "pushEvent copies semantic table payloads into the queue allocator" {
    const source_alloc = std.testing.allocator;
    const queue_alloc = std.heap.c_allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(queue_alloc);

    var table = try assistant_presentation.parseTablePayload(
        source_alloc,
        "| Name | Count |\n" ++
            "|------|------:|\n" ++
            "| api | 7 |\n",
    );
    const source_cell_ptr = table.rows[1].cells[0].ptr;
    try runtime.pushEvent(queue_alloc, .{ .assistant_presentation = .{ .table = table } });
    table.deinit(source_alloc);

    var events = runtime.takeEvents();
    defer freeEventList(queue_alloc, &events);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expect(events.items[0] == .assistant_presentation);
    try std.testing.expect(events.items[0].assistant_presentation == .table);
    try std.testing.expectEqualStrings("api", events.items[0].assistant_presentation.table.rows[1].cells[0]);
    try std.testing.expect(events.items[0].assistant_presentation.table.rows[1].cells[0].ptr != source_cell_ptr);
}

test "pushEvent copies code block payload into queue allocator" {
    const source_alloc = std.testing.allocator;
    const queue_alloc = std.heap.c_allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(queue_alloc);

    var block = assistant_presentation.CodeBlockPayload{
        .language = try source_alloc.dupe(u8, "zig"),
        .code = try source_alloc.dupe(u8, "  const value = 1;\n"),
    };
    const source_code_ptr = block.code.ptr;
    try runtime.pushEvent(queue_alloc, .{ .assistant_presentation = .{ .code_block = block } });
    block.deinit(source_alloc);

    var events = runtime.takeEvents();
    defer freeEventList(queue_alloc, &events);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expect(events.items[0] == .assistant_presentation);
    try std.testing.expect(events.items[0].assistant_presentation == .code_block);
    try std.testing.expectEqualStrings("zig", events.items[0].assistant_presentation.code_block.language);
    try std.testing.expectEqualStrings("  const value = 1;\n", events.items[0].assistant_presentation.code_block.code);
    try std.testing.expect(events.items[0].assistant_presentation.code_block.code.ptr != source_code_ptr);
}

test "pushEvent copies absolute turn token progress into queue allocator" {
    const queue_alloc = std.heap.c_allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(queue_alloc);

    const progress: types.TurnTokenProgress = .{
        .input_tokens = 10,
        .output_tokens = 5,
        .input_exact = false,
        .output_exact = false,
    };
    try runtime.pushEvent(queue_alloc, .{ .turn_token_update = progress });

    var events = runtime.takeEvents();
    defer freeEventList(queue_alloc, &events);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expect(events.items[0] == .turn_token_update);
    try std.testing.expectEqual(progress, events.items[0].turn_token_update);
}

test "pushEvent copies finish prompt assistant turns into queue allocator" {
    const source_alloc = std.testing.allocator;
    const queue_alloc = std.heap.c_allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(queue_alloc);

    const turn: types.HistoryTurn = .{ .assistant = .{
        .user = .{ .text = try source_alloc.dupe(u8, "source prompt"), .images = &.{} },
        .assistant = try source_alloc.dupe(u8, "source answer"),
    } };
    const prompt_ptr = turn.assistant.user.text.ptr;
    const answer_ptr = turn.assistant.assistant.ptr;

    try runtime.pushEvent(queue_alloc, .{ .finish_prompt = .{
        .turn = turn,
        .summary = .{
            .thinking_duration_ms = 1,
            .turn_duration_ms = 2,
            .token_progress = .{ .input_tokens = 7 },
        },
    } });
    types.freeHistoryTurn(source_alloc, turn);

    var events = runtime.takeEvents();
    defer freeEventList(queue_alloc, &events);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expect(events.items[0] == .finish_prompt);
    try std.testing.expect(events.items[0].finish_prompt.turn == .assistant);
    try std.testing.expectEqualStrings("source prompt", events.items[0].finish_prompt.turn.assistant.user.text);
    try std.testing.expectEqualStrings("source answer", events.items[0].finish_prompt.turn.assistant.assistant);
    try std.testing.expect(events.items[0].finish_prompt.turn.assistant.user.text.ptr != prompt_ptr);
    try std.testing.expect(events.items[0].finish_prompt.turn.assistant.assistant.ptr != answer_ptr);
    try std.testing.expectEqual(@as(u64, 7), events.items[0].finish_prompt.summary.?.token_progress.input_tokens);
}

test "pushOwnedEvent transfers diff block payloads without copying" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    const preview = try alloc.dupe(u8, "preview");
    try runtime.pushOwnedEvent(alloc, .{ .diff_block = .{
        .preview = preview,
    } });

    var events = runtime.takeEvents();
    defer freeEventList(alloc, &events);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expect(events.items[0] == .diff_block);
    try std.testing.expectEqual(preview.ptr, events.items[0].diff_block.preview.ptr);
}

test "dupeWorkerEvent clones canonical diff payload and full detail" {
    const alloc = std.testing.allocator;
    const source: WorkerEvent = .{ .diff_block = .{
        .preview = @constCast("preview"),
        .additions = 2,
        .deletions = 1,
        .full = .{
            .content = @constCast("full detail"),
            .lifecycle_id = .{ .turn_id = 9, .call_id = "call-9" },
        },
    } };
    const owned = try dupeWorkerEvent(alloc, source);
    defer freeWorkerEvent(alloc, owned);

    try std.testing.expectEqualStrings("preview", owned.diff_block.preview);
    try std.testing.expect(source.diff_block.preview.ptr != owned.diff_block.preview.ptr);
    try std.testing.expectEqual(@as(u32, 2), owned.diff_block.additions);
    try std.testing.expectEqual(@as(u32, 1), owned.diff_block.deletions);
    const full = owned.diff_block.full orelse return error.TestExpectedFullDiff;
    try std.testing.expectEqualStrings("full detail", full.content);
    try std.testing.expectEqual(@as(u64, 9), full.lifecycle_id.turn_id);
    try std.testing.expectEqualStrings("call-9", full.lifecycle_id.call_id);
    try std.testing.expect(source.diff_block.full.?.content.ptr != full.content.ptr);
    try std.testing.expect(source.diff_block.full.?.lifecycle_id.call_id.ptr != full.lifecycle_id.call_id.ptr);
}

test "pushEvent clones every semantic notice field into the queue allocator" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    var topic = [_]u8{ 'c', 'o', 'n', 't', 'e', 'x', 't' };
    var body = [_]u8{ 'w', 'a', 'r', 'n', 'i', 'n', 'g' };
    const topic_ptr = topic[0..].ptr;
    const body_ptr = body[0..].ptr;
    try runtime.pushEvent(alloc, .{ .semantic_notice = .{
        .topic = &topic,
        .tone = .warning,
        .body = &body,
        .visibility = .full_only,
    } });
    topic[0] = 'X';
    body[0] = 'X';

    var events = runtime.takeEvents();
    defer freeEventList(alloc, &events);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expect(events.items[0] == .semantic_notice);
    const notice = events.items[0].semantic_notice;
    try std.testing.expectEqualStrings("context", notice.topic);
    try std.testing.expectEqual(types.NoticeTone.warning, notice.tone);
    try std.testing.expectEqualStrings("warning", notice.body);
    try std.testing.expectEqual(types.NoticeVisibility.full_only, notice.visibility);
    try std.testing.expect(notice.topic.ptr != topic_ptr);
    try std.testing.expect(notice.body.ptr != body_ptr);
}

fn checkSemanticWorkerEventDuplicationAllocationFailure(alloc: std.mem.Allocator) !void {
    const ordinary = try dupeWorkerEvent(alloc, .{ .semantic_notice = .{
        .topic = "context",
        .tone = .warning,
        .body = "source limit reached",
        .visibility = .full_only,
    } });
    defer freeWorkerEvent(alloc, ordinary);

    const error_event = try dupeWorkerEvent(alloc, .{ .error_text = .{
        .topic = "github",
        .tone = .@"error",
        .body = "publish failed",
    } });
    defer freeWorkerEvent(alloc, error_event);

    try std.testing.expectEqualStrings("context", ordinary.semantic_notice.topic);
    try std.testing.expectEqualStrings("source limit reached", ordinary.semantic_notice.body);
    try std.testing.expectEqualStrings("github", error_event.error_text.topic);
    try std.testing.expectEqualStrings("publish failed", error_event.error_text.body);
}

test "ordinary and error semantic worker events free partial duplication allocations" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkSemanticWorkerEventDuplicationAllocationFailure,
        .{},
    );
}

test "prependOwnedEvents preserves retained order ahead of newer events" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    try runtime.pushEvent(alloc, .{ .semantic_notice = .{
        .topic = "system",
        .tone = .information,
        .body = "newer",
    } });
    const retained = [_]WorkerEvent{
        .{ .assistant_presentation = .{
            .text = try alloc.dupe(u8, "first"),
        } },
        try dupeWorkerEvent(alloc, .{ .semantic_notice = .{
            .topic = "system",
            .tone = .information,
            .body = "second",
        } }),
    };
    errdefer {
        for (retained) |event| freeWorkerEvent(alloc, event);
    }
    try runtime.prependOwnedEvents(alloc, &retained);

    var events = runtime.takeEvents();
    defer freeEventList(alloc, &events);
    try std.testing.expectEqual(@as(usize, 3), events.items.len);
    try std.testing.expectEqualStrings("first", events.items[0].assistant_presentation.text);
    try std.testing.expectEqualStrings("second", events.items[1].semantic_notice.body);
    try std.testing.expectEqualStrings("newer", events.items[2].semantic_notice.body);
}

fn checkSemanticNoticeEnqueueAllocationFailure(alloc: std.mem.Allocator) !void {
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    try runtime.pushEvent(alloc, .{ .semantic_notice = .{
        .topic = "permissions",
        .tone = .success,
        .body = "approval",
        .visibility = .full_only,
    } });
    var events = runtime.takeEvents();
    defer freeEventList(alloc, &events);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expect(events.items[0] == .semantic_notice);
    try std.testing.expectEqualStrings("permissions", events.items[0].semantic_notice.topic);
    try std.testing.expectEqualStrings("approval", events.items[0].semantic_notice.body);
}

test "semantic notice enqueue frees partial topic body and queue allocations" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkSemanticNoticeEnqueueAllocationFailure,
        .{},
    );
}

const PermissionThreadState = struct {
    decision: ?types.ToolPermissionDecision = null,
    err: ?anyerror = null,
};

fn runPermissionRequest(state: *PermissionThreadState, runtime: *WorkerRuntime, label: []const u8) void {
    var response = runtime.requestPermissionBlocking(
        std.testing.allocator,
        .{ .label = label },
    ) catch |err| {
        state.err = err;
        return;
    };
    defer response.deinit();
    state.decision = response.decision;
}

fn submitPermissionDecisionForTest(
    runtime: *WorkerRuntime,
    request_id: u64,
    decision: types.ToolPermissionDecision,
) PermissionSubmissionResult {
    return runtime.submitPermissionResponse(
        request_id,
        permission_request.OwnedPermissionResponse.init(
            std.testing.allocator,
            decision,
            null,
        ),
    );
}

fn waitForPermissionLabel(worker: *WorkerRuntime, expected: []const u8) !u64 {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        var snapshot = try worker.snapshotState(std.testing.allocator);
        defer snapshot.deinit(std.testing.allocator);
        if (snapshot.pending_permission_request) |request| {
            try std.testing.expectEqualStrings(expected, request.label);
            try std.testing.expect(request.id != 0);
            return request.id;
        }
        io_mod.sleep(1 * std.time.ns_per_ms);
    }
    return error.TestExpectedEqual;
}

test "permission blocking handles submit and stop" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);
    runtime.worker_processing = true;

    var state = PermissionThreadState{};
    const thread = try std.Thread.spawn(.{}, runPermissionRequest, .{ &state, &runtime, "Allow?" });
    const request_id = try waitForPermissionLabel(&runtime, "Allow?");
    try std.testing.expectEqual(
        PermissionSubmissionResult.accepted,
        submitPermissionDecisionForTest(&runtime, request_id, .once),
    );
    thread.join();
    try std.testing.expect(state.err == null);
    try std.testing.expectEqual(types.ToolPermissionDecision.once, state.decision.?);
    var snapshot = try runtime.snapshotState(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expect(snapshot.pending_permission_request == null);

    var deny_state = PermissionThreadState{};
    const deny_thread = try std.Thread.spawn(.{}, runPermissionRequest, .{ &deny_state, &runtime, "Deny?" });
    const deny_request_id = try waitForPermissionLabel(&runtime, "Deny?");
    try std.testing.expectEqual(
        PermissionSubmissionResult.accepted,
        submitPermissionDecisionForTest(&runtime, deny_request_id, .deny),
    );
    deny_thread.join();
    try std.testing.expect(deny_state.err == null);
    try std.testing.expectEqual(types.ToolPermissionDecision.deny, deny_state.decision.?);
    var deny_snapshot = try runtime.snapshotState(alloc);
    defer deny_snapshot.deinit(alloc);
    try std.testing.expect(deny_snapshot.pending_permission_request == null);

    var stop_runtime = WorkerRuntime{};
    defer stop_runtime.deinit(alloc);
    stop_runtime.worker_processing = true;
    var stop_state = PermissionThreadState{};
    const stop_thread = try std.Thread.spawn(.{}, runPermissionRequest, .{ &stop_state, &stop_runtime, "Stop?" });
    _ = try waitForPermissionLabel(&stop_runtime, "Stop?");
    stop_runtime.requestStop();
    stop_thread.join();
    try std.testing.expect(stop_state.err == null);
    try std.testing.expectEqual(types.ToolPermissionDecision.deny, stop_state.decision.?);
    var stop_snapshot = try stop_runtime.snapshotState(alloc);
    defer stop_snapshot.deinit(alloc);
    try std.testing.expect(stop_snapshot.pending_permission_request == null);

    var shutdown_runtime = WorkerRuntime{};
    defer shutdown_runtime.deinit(alloc);
    shutdown_runtime.worker_processing = true;
    var shutdown_state = PermissionThreadState{};
    const shutdown_thread = try std.Thread.spawn(.{}, runPermissionRequest, .{ &shutdown_state, &shutdown_runtime, "Shutdown?" });
    _ = try waitForPermissionLabel(&shutdown_runtime, "Shutdown?");
    shutdown_runtime.requestShutdown();
    shutdown_thread.join();
    try std.testing.expect(shutdown_state.err == null);
    try std.testing.expectEqual(types.ToolPermissionDecision.deny, shutdown_state.decision.?);
    var shutdown_snapshot = try shutdown_runtime.snapshotState(alloc);
    defer shutdown_snapshot.deinit(alloc);
    try std.testing.expect(shutdown_snapshot.pending_permission_request == null);
}

test "permission response accepts feedback ownership" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);
    runtime.worker_processing = true;
    runtime.pending_permission_waiting = true;
    runtime.pending_permission_request_shared = try permission_request.OwnedPermissionRequest.dupe(
        alloc,
        .{ .id = 44, .label = "feedback" },
    );

    const feedback = try alloc.dupe(u8, "summarize the result");
    try std.testing.expectEqual(
        PermissionSubmissionResult.accepted,
        runtime.submitPermissionResponse(
            44,
            permission_request.OwnedPermissionResponse.init(alloc, .once, feedback),
        ),
    );
    try std.testing.expectEqualStrings(
        "summarize the result",
        runtime.pending_permission_response.?.feedback.?,
    );
}

test "permission submission rejects stale ids and preserves first resolution" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);
    runtime.worker_processing = true;
    runtime.pending_permission_waiting = true;
    runtime.pending_permission_request_shared =
        try permission_request.OwnedPermissionRequest.dupe(
            alloc,
            .{ .id = 22, .label = "B" },
        );

    try std.testing.expectEqual(
        PermissionSubmissionResult.stale,
        submitPermissionDecisionForTest(&runtime, 21, .always),
    );
    try std.testing.expect(runtime.pending_permission_response == null);
    try std.testing.expectEqual(
        PermissionSubmissionResult.accepted,
        submitPermissionDecisionForTest(&runtime, 22, .deny),
    );
    try std.testing.expectEqual(
        types.ToolPermissionDecision.deny,
        runtime.pending_permission_response.?.decision,
    );
    try std.testing.expectEqual(
        PermissionSubmissionResult.no_pending,
        submitPermissionDecisionForTest(&runtime, 22, .once),
    );
    try std.testing.expectEqual(
        PermissionSubmissionResult.no_pending,
        submitPermissionDecisionForTest(&runtime, 22, .always),
    );
    try std.testing.expectEqual(
        PermissionSubmissionResult.no_pending,
        submitPermissionDecisionForTest(&runtime, 22, .deny),
    );
    try std.testing.expectEqual(
        types.ToolPermissionDecision.deny,
        runtime.pending_permission_response.?.decision,
    );

    var snapshot = try runtime.snapshotState(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expect(snapshot.pending_permission_request == null);
}

test "stale A decisions cannot resolve a newer B request" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);
    runtime.worker_processing = true;

    var a_state = PermissionThreadState{};
    const a_thread = try std.Thread.spawn(
        .{},
        runPermissionRequest,
        .{ &a_state, &runtime, "A" },
    );
    const a_id = try waitForPermissionLabel(&runtime, "A");
    try std.testing.expectEqual(
        PermissionSubmissionResult.accepted,
        submitPermissionDecisionForTest(&runtime, a_id, .once),
    );
    a_thread.join();
    try std.testing.expectEqual(types.ToolPermissionDecision.once, a_state.decision.?);

    var b_state = PermissionThreadState{};
    const b_thread = try std.Thread.spawn(
        .{},
        runPermissionRequest,
        .{ &b_state, &runtime, "B" },
    );
    const b_id = try waitForPermissionLabel(&runtime, "B");
    try std.testing.expect(b_id != a_id);

    const stale_decisions = [_]types.ToolPermissionDecision{
        .once,
        .always,
        .deny,
        .deny,
    };
    for (stale_decisions) |decision| {
        try std.testing.expectEqual(
            PermissionSubmissionResult.stale,
            submitPermissionDecisionForTest(&runtime, a_id, decision),
        );
    }
    try std.testing.expect(runtime.pending_permission_response == null);
    try std.testing.expectEqual(
        PermissionSubmissionResult.accepted,
        submitPermissionDecisionForTest(&runtime, b_id, .always),
    );
    b_thread.join();
    try std.testing.expectEqual(
        types.ToolPermissionDecision.always,
        b_state.decision.?,
    );
}

test "permission request ids never wrap or reuse zero" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);
    runtime.worker_processing = true;
    runtime.next_permission_request_id = std.math.maxInt(u64);

    var last_state = PermissionThreadState{};
    const last_thread = try std.Thread.spawn(
        .{},
        runPermissionRequest,
        .{ &last_state, &runtime, "last id" },
    );
    const last_id = try waitForPermissionLabel(&runtime, "last id");
    try std.testing.expectEqual(std.math.maxInt(u64), last_id);
    try std.testing.expectEqual(
        PermissionSubmissionResult.accepted,
        submitPermissionDecisionForTest(&runtime, last_id, .deny),
    );
    last_thread.join();
    try std.testing.expect(last_state.err == null);

    var exhausted_state = PermissionThreadState{};
    const exhausted_thread = try std.Thread.spawn(
        .{},
        runPermissionRequest,
        .{ &exhausted_state, &runtime, "exhausted" },
    );
    exhausted_thread.join();
    try std.testing.expectEqual(
        error.RequestIdExhausted,
        exhausted_state.err.?,
    );
}

test "approval turn cancellation resolves the current worker request once" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);
    runtime.worker_processing = true;
    runtime.pending_permission_waiting = true;
    runtime.pending_permission_request_shared =
        try permission_request.OwnedPermissionRequest.dupe(
            alloc,
            .{ .id = 33, .label = "current" },
        );

    runtime.cancelApprovalTurn();
    try std.testing.expect(runtime.isCancelRequested());
    try std.testing.expectEqual(
        types.ToolPermissionDecision.deny,
        runtime.pending_permission_response.?.decision,
    );
    try std.testing.expectEqual(
        PermissionSubmissionResult.no_pending,
        submitPermissionDecisionForTest(&runtime, 33, .always),
    );
}

test "text enqueue allocation failure preserves active interactive state" {
    const alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);
    runtime.worker_processing = true;

    runtime.pending_permission_waiting = true;
    runtime.pending_permission_request_shared =
        try permission_request.OwnedPermissionRequest.dupe(
            alloc,
            .{ .id = 3, .label = "active permission" },
        );
    const question_options = [_]types.QuestionOption{.{ .label = "Wait", .description = null }};
    const question_entries = [_]types.QuestionBatchEntry{.{
        .question = "Keep waiting?",
        .options = &question_options,
    }};
    runtime.pending_question_shared = try dupeOwnedQuestionBatch(
        alloc,
        &question_entries,
        .agent_question,
    );

    const prompt = try makePrompt(
        alloc,
        "Stop",
        "model",
    );
    var failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        runtime.enqueuePrompt(failing.allocator(), prompt),
    );
    freeQueuedPrompt(alloc, prompt);

    try std.testing.expectEqual(@as(usize, 0), runtime.queuedPromptCount());
    try std.testing.expect(!runtime.isCancelRequested());
    try std.testing.expect(runtime.pending_permission_response == null);
    try std.testing.expect(runtime.pending_permission_request_shared != null);
    try std.testing.expectEqualStrings(
        "active permission",
        runtime.pending_permission_request_shared.?.label,
    );
    try std.testing.expect(runtime.pending_question_shared != null);
    try std.testing.expect(runtime.pending_question_response == .pending);
}

const QuestionThreadState = struct {
    answers: ?[][]u8 = null,
    err: ?anyerror = null,
};

fn runQuestionRequest(state: *QuestionThreadState, runtime: *WorkerRuntime, entries: []const types.QuestionBatchEntry) void {
    state.answers = runtime.requestQuestionBatchAnswerBlocking(std.testing.allocator, entries) catch |err| {
        state.err = err;
        return;
    };
}

fn runRouteRecoveryRequest(state: *QuestionThreadState, runtime: *WorkerRuntime, entries: []const types.QuestionBatchEntry) void {
    state.answers = runtime.requestRouteRecoveryAnswerBlocking(std.testing.allocator, entries) catch |err| {
        state.err = err;
        return;
    };
}

fn waitForQuestionSnapshot(worker: *WorkerRuntime) !PendingQuestionBatchSnapshot {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (try worker.snapshotPendingQuestionBatch(std.testing.allocator)) |snapshot| return snapshot;
        io_mod.sleep(1 * std.time.ns_per_ms);
    }
    return error.TestExpectedEqual;
}

fn freeAnswers(alloc: std.mem.Allocator, answers: ?[][]u8) void {
    if (answers) |labels| {
        for (labels) |label| alloc.free(label);
        alloc.free(labels);
    }
}

test "question batch snapshot answer and cancellation" {
    const alloc = std.testing.allocator;
    const options = [_]types.QuestionOption{
        .{ .label = "Yes", .description = "Do it" },
        .{ .label = "No", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{.{ .question = "Continue?", .options = &options }};

    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);
    var state = QuestionThreadState{};
    const thread = try std.Thread.spawn(.{}, runQuestionRequest, .{ &state, &runtime, &entries });
    var snapshot = try waitForQuestionSnapshot(&runtime);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqualStrings("Continue?", snapshot.entries[0].question);
    try std.testing.expectEqualStrings("Yes", snapshot.entries[0].options[0].label);
    try std.testing.expect(snapshot.entries[0].question.ptr != entries[0].question.ptr);
    try runtime.submitQuestionBatchAnswer(alloc, &.{"Yes"});
    thread.join();
    defer freeAnswers(alloc, state.answers);
    try std.testing.expect(state.err == null);
    try std.testing.expectEqualStrings("Yes", state.answers.?[0]);
    try std.testing.expect(try runtime.snapshotPendingQuestionBatch(alloc) == null);

    var cancel_runtime = WorkerRuntime{};
    defer cancel_runtime.deinit(alloc);
    var cancel_state = QuestionThreadState{};
    const cancel_thread = try std.Thread.spawn(.{}, runQuestionRequest, .{ &cancel_state, &cancel_runtime, &entries });
    var cancel_snapshot = try waitForQuestionSnapshot(&cancel_runtime);
    cancel_snapshot.deinit(alloc);
    try cancel_runtime.submitQuestionBatchAnswer(alloc, null);
    cancel_thread.join();
    try std.testing.expect(cancel_state.err == null);
    try std.testing.expect(cancel_state.answers == null);
    try std.testing.expect(try cancel_runtime.snapshotPendingQuestionBatch(alloc) == null);
}

test "question batch source distinguishes route recovery from agent questions" {
    const alloc = std.testing.allocator;
    const options = [_]types.QuestionOption{.{ .label = "Try again later", .description = null }};
    const entries = [_]types.QuestionBatchEntry{.{ .question = "Route failed. What should fx do?", .options = &options }};

    var route_runtime = WorkerRuntime{};
    defer route_runtime.deinit(alloc);
    var route_state = QuestionThreadState{};
    const route_thread = try std.Thread.spawn(.{}, runRouteRecoveryRequest, .{ &route_state, &route_runtime, &entries });
    var route_snapshot = try waitForQuestionSnapshot(&route_runtime);
    defer route_snapshot.deinit(alloc);
    try std.testing.expectEqual(QuestionPromptSource.route_recovery, route_snapshot.source);
    try std.testing.expectEqual(QuestionPromptSource.route_recovery, route_runtime.pendingQuestionBatchSource());
    try route_runtime.submitQuestionBatchAnswer(alloc, &.{"Try again later"});
    route_thread.join();
    defer freeAnswers(alloc, route_state.answers);
    try std.testing.expect(route_state.err == null);
    try std.testing.expectEqualStrings("Try again later", route_state.answers.?[0]);

    var agent_runtime = WorkerRuntime{};
    defer agent_runtime.deinit(alloc);
    var agent_state = QuestionThreadState{};
    const agent_thread = try std.Thread.spawn(.{}, runQuestionRequest, .{ &agent_state, &agent_runtime, &entries });
    var agent_snapshot = try waitForQuestionSnapshot(&agent_runtime);
    defer agent_snapshot.deinit(alloc);
    try std.testing.expectEqual(QuestionPromptSource.agent_question, agent_snapshot.source);
    try std.testing.expectEqual(QuestionPromptSource.agent_question, agent_runtime.pendingQuestionBatchSource());
    try agent_runtime.submitQuestionBatchAnswer(alloc, &.{"Try again later"});
    agent_thread.join();
    defer freeAnswers(alloc, agent_state.answers);
    try std.testing.expect(agent_state.err == null);
}

test "question request queues an ordered boundary after prior assistant text" {
    const alloc = std.testing.allocator;
    const options = [_]types.QuestionOption{.{ .label = "Yes", .description = null }};
    const entries = [_]types.QuestionBatchEntry{.{ .question = "Continue?", .options = &options }};

    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);
    try runtime.pushEvent(alloc, .{ .assistant_presentation = .{
        .text = @constCast("before question"),
    } });

    var state = QuestionThreadState{};
    const thread = try std.Thread.spawn(.{}, runQuestionRequest, .{ &state, &runtime, &entries });
    var snapshot = try waitForQuestionSnapshot(&runtime);
    defer snapshot.deinit(alloc);

    var events = runtime.takeEvents();
    defer freeEventList(alloc, &events);
    try std.testing.expectEqual(@as(usize, 2), events.items.len);
    try std.testing.expect(events.items[0] == .assistant_presentation);
    try std.testing.expect(events.items[0].assistant_presentation == .text);
    try std.testing.expectEqualStrings("before question", events.items[0].assistant_presentation.text);
    try std.testing.expect(events.items[1] == .question_requested);

    try runtime.submitQuestionBatchAnswer(alloc, &.{"Yes"});
    thread.join();
    defer freeAnswers(alloc, state.answers);
    try std.testing.expect(state.err == null);
    try std.testing.expectEqualStrings("Yes", state.answers.?[0]);
}

test "question request rolls back pending state when its boundary event cannot be queued" {
    const options = [_]types.QuestionOption{.{ .label = "Yes", .description = null }};
    const entries = [_]types.QuestionBatchEntry{.{ .question = "Continue?", .options = &options }};

    var probe = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var probe_runtime = WorkerRuntime{};
    probe_runtime.worker_stop_requested = true;
    const probe_result = try probe_runtime.requestQuestionBatchAnswerBlocking(probe.allocator(), &entries);
    try std.testing.expect(probe_result == null);
    const marker_append_alloc_index = probe.alloc_index - 1;
    probe_runtime.deinit(probe.allocator());
    try std.testing.expectEqual(probe.allocated_bytes, probe.freed_bytes);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = marker_append_alloc_index,
    });
    var runtime = WorkerRuntime{};
    defer runtime.deinit(failing.allocator());
    runtime.worker_stop_requested = true;

    try std.testing.expectError(
        error.OutOfMemory,
        runtime.requestQuestionBatchAnswerBlocking(failing.allocator(), &entries),
    );
    try std.testing.expect(runtime.pending_question_shared == null);
    try std.testing.expect(runtime.pending_question_response == .pending);
    try std.testing.expectEqual(@as(usize, 0), runtime.worker_events.items.len);
}
