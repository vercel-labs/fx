//! What an agent's prompt submission is waiting on: the prompt the composer
//! handed over and how far it got. The agents folder holds one per agent, so
//! this file imports nothing from the screen; `input_submit_runtime.zig` runs
//! it.

const std = @import("std");
const types = @import("../shared/types.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const compaction_activity = @import("../output/compaction_activity.zig");

pub const PendingPhase = enum {
    awaiting_frame,
    awaiting_adoption,
    adopted,
    awaiting_auth,
    queued,
};

pub const PendingPhaseError = error{InvalidPendingPhase};

pub const PendingPromptDraft = struct {
    turn_id: u64,
    prompt: []u8,
    images: []types.ImageAttachment,
    skill_display_spans: []worker_runtime.SkillDisplaySpan,

    pub fn deinit(self: PendingPromptDraft, alloc: std.mem.Allocator) void {
        alloc.free(self.prompt);
        types.freeImageAttachmentSlice(alloc, self.images);
        worker_runtime.freeSkillDisplaySpans(alloc, self.skill_display_spans);
    }
};

pub const PendingSubmission = struct {
    draft: PendingPromptDraft,
    phase: PendingPhase = .awaiting_frame,
    credential_admitted: bool = false,
    skill_refresh_generation: ?u64 = null,

    pub fn init(draft: PendingPromptDraft) PendingSubmission {
        std.debug.assert(draft.turn_id != 0);
        return .{ .draft = draft };
    }

    pub fn deinit(self: *PendingSubmission, alloc: std.mem.Allocator) void {
        self.draft.deinit(alloc);
        self.* = undefined;
    }

    pub fn ownsTurnStartHold(self: PendingSubmission) bool {
        return self.phase != .queued;
    }

    pub fn markFrameCommitted(self: *PendingSubmission) bool {
        if (self.phase != .awaiting_frame) return false;
        self.phase = .awaiting_adoption;
        return true;
    }

    pub fn markAdopted(self: *PendingSubmission) PendingPhaseError!void {
        if (self.phase != .awaiting_adoption) return error.InvalidPendingPhase;
        self.phase = .adopted;
    }

    pub fn markQueued(self: *PendingSubmission) bool {
        if (self.phase != .adopted) return false;
        self.phase = .queued;
        return true;
    }
};

pub const PendingSkillRefresh = enum {
    pending,
    current,
};

pub const State = struct {
    pending: ?PendingSubmission = null,
    retry_after_auth: bool = false,
    compaction_pending: bool = false,
    /// Identity only; auth retains its existing pending execution flag.
    compaction_operation: ?compaction_activity.OperationId = null,
};
