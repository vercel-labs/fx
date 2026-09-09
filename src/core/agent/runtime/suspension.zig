const std = @import("std");

pub const ToolEvidence = enum { none, proven_unexecuted, confirmed, uncertain };
pub const Boundary = enum { model_active, tool_group_active, before_model, final_response, resume_request };
pub const PendingCalls = enum { none, safe, blocked };
pub const CheckpointAck = enum { needed, durable, unavailable, uncertain };
pub const Decision = enum { continue_work, wait_for_settlement, persist_checkpoint, paused, finish, blocked, resume_request };

pub const Evidence = struct {
    requested: bool = false,
    boundary: Boundary,
    tool: ToolEvidence = .none,
    pending: PendingCalls = .none,
    checkpoint: CheckpointAck = .needed,
};

/// Shared checkpoint-based handoff policy, not an onEntry effect journal.
/// Pending calls (including permission-blocked calls) must settle through normal
/// admission. No decision authorizes a tool, cancels active work, or replays it.
/// `durable` means the exact current boundary was acknowledged, not an older save.
pub fn decide(evidence: Evidence) Decision {
    if (evidence.boundary == .resume_request) {
        if (evidence.tool == .uncertain or evidence.pending != .none or
            evidence.checkpoint != .durable) return .blocked;
        return if (evidence.requested) .paused else .resume_request;
    }
    if (evidence.boundary == .model_active or evidence.boundary == .tool_group_active or
        evidence.pending != .none)
        return if (evidence.requested) .wait_for_settlement else .continue_work;
    if (evidence.boundary == .final_response)
        return if (evidence.tool == .uncertain) .blocked else .finish;
    if (!evidence.requested)
        return if (evidence.tool == .uncertain) .blocked else .continue_work;
    return switch (evidence.checkpoint) {
        .needed => .persist_checkpoint,
        .durable => .paused,
        .unavailable, .uncertain => .blocked,
    };
}

test "suspension simulation waits for active work and pending safe or blocked calls" {
    for ([_]Boundary{ .model_active, .tool_group_active }) |boundary| {
        try std.testing.expectEqual(Decision.wait_for_settlement, decide(.{ .requested = true, .boundary = boundary }));
    }
    for ([_]PendingCalls{ .safe, .blocked }) |pending| {
        try std.testing.expectEqual(Decision.wait_for_settlement, decide(.{ .requested = true, .boundary = .before_model, .pending = pending }));
        try std.testing.expectEqual(Decision.blocked, decide(.{ .boundary = .resume_request, .pending = pending, .checkpoint = .durable }));
    }
    try std.testing.expectEqual(Decision.finish, decide(.{ .requested = true, .boundary = .final_response }));
}

test "suspension simulation requires durable ack and never resumes uncertain effects" {
    var evidence = Evidence{ .requested = true, .boundary = .before_model, .tool = .confirmed };
    try std.testing.expectEqual(Decision.persist_checkpoint, decide(evidence));
    // A store may have committed but lost its acknowledgement. It grants no handoff.
    evidence.checkpoint = .uncertain;
    try std.testing.expectEqual(Decision.blocked, decide(evidence));
    evidence.boundary = .resume_request;
    try std.testing.expectEqual(Decision.blocked, decide(evidence));
    evidence.checkpoint = .durable;
    evidence.requested = false;
    try std.testing.expectEqual(Decision.resume_request, decide(evidence));
    evidence.tool = .uncertain;
    try std.testing.expectEqual(Decision.blocked, decide(evidence));
    evidence.boundary = .final_response;
    try std.testing.expectEqual(Decision.blocked, decide(evidence));
    evidence.boundary = .before_model;
    evidence.requested = true;
    evidence.checkpoint = .needed;
    try std.testing.expectEqual(Decision.persist_checkpoint, decide(evidence));
    evidence.checkpoint = .durable;
    try std.testing.expectEqual(Decision.paused, decide(evidence));
    evidence.checkpoint = .unavailable;
    try std.testing.expectEqual(Decision.blocked, decide(evidence));
}

test "suspension simulation handoff carries committed results without reexecution" {
    var committed_effects: usize = 0;
    var evidence = Evidence{ .requested = true, .boundary = .tool_group_active, .pending = .safe };
    try std.testing.expectEqual(Decision.wait_for_settlement, decide(evidence));
    committed_effects += 1;
    evidence.boundary = .before_model;
    evidence.pending = .none;
    evidence.tool = .confirmed;
    try std.testing.expectEqual(Decision.persist_checkpoint, decide(evidence));
    evidence.checkpoint = .durable;
    try std.testing.expectEqual(Decision.paused, decide(evidence));
    evidence.boundary = .resume_request;
    evidence.requested = false;
    for (0..3) |_| {
        try std.testing.expectEqual(Decision.resume_request, decide(evidence));
        try std.testing.expectEqual(@as(usize, 1), committed_effects);
    }
}
