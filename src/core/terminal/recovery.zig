const std = @import("std");
const contracts = @import("contracts.zig");

pub const RecordEvidence = enum {
    valid,
    missing,
    partial,
    corrupt,
    unsupported,
};

pub const HostEvidence = enum {
    present_same,
    present_foreign,
    absent,
};

pub const ProcessEvidence = enum {
    matched,
    missing,
    mismatched,
    unavailable,
};

pub const CheckpointEvidence = enum {
    valid_contiguous,
    missing,
    corrupt,
    unsupported,
    disconnected,
    retention_evicted,
    resize_uncheckpointed,
};

pub const Input = struct {
    record: RecordEvidence,
    lifecycle: contracts.Lifecycle,
    termination_present: bool,
    host: HostEvidence,
    process: ProcessEvidence,
    checkpoint: CheckpointEvidence,
};

pub const Disposition = enum {
    retain_live,
    retain_final,
    finalize_exited,
    mark_lost,
    isolate_corrupt,
    unavailable,
};

pub const Decision = struct {
    disposition: Disposition,
    lifecycle: contracts.Lifecycle,
    screen_unavailable: ?contracts.ScreenUnavailableReason,
};

/// Decides what happens to a terminal record a process finds. The terminal
/// lifecycle is modeled in `tests/tla/terminal/TerminalLifecycle.tla`.
pub fn reconcile(input: Input) Decision {
    if (input.record != .valid) {
        return .{
            .disposition = .isolate_corrupt,
            .lifecycle = .lost,
            .screen_unavailable = record_screen_reason(input.record),
        };
    }

    const screen_unavailable = checkpoint_reason(input.checkpoint);
    if (input.lifecycle == .exited or input.lifecycle == .lost or
        input.lifecycle == .closed)
    {
        return .{
            .disposition = .retain_final,
            .lifecycle = input.lifecycle,
            .screen_unavailable = screen_unavailable,
        };
    }
    if (input.termination_present) {
        return .{
            .disposition = .finalize_exited,
            .lifecycle = .exited,
            .screen_unavailable = screen_unavailable,
        };
    }
    if (input.host == .present_same and input.process == .matched) {
        return .{
            .disposition = .retain_live,
            .lifecycle = input.lifecycle,
            .screen_unavailable = screen_unavailable,
        };
    }
    if (input.host == .present_same and input.process == .unavailable) {
        return .{
            .disposition = .unavailable,
            .lifecycle = input.lifecycle,
            .screen_unavailable = screen_unavailable,
        };
    }
    return .{
        .disposition = .mark_lost,
        .lifecycle = .lost,
        .screen_unavailable = screen_unavailable,
    };
}

fn record_screen_reason(
    evidence: RecordEvidence,
) contracts.ScreenUnavailableReason {
    return switch (evidence) {
        .valid, .missing => .missing,
        .partial, .corrupt => .corrupt,
        .unsupported => .unsupported_schema,
    };
}

fn checkpoint_reason(
    evidence: CheckpointEvidence,
) ?contracts.ScreenUnavailableReason {
    return switch (evidence) {
        .valid_contiguous => null,
        .missing => .missing,
        .corrupt => .corrupt,
        .unsupported => .unsupported_schema,
        .disconnected => .raw_gap,
        .retention_evicted => .retention_evicted,
        .resize_uncheckpointed => .resize_uncheckpointed,
    };
}

test "recovery never restarts and isolates invalid durable records" {
    const evidences = [_]RecordEvidence{ .missing, .partial, .corrupt, .unsupported };
    for (evidences) |record| {
        const decision = reconcile(.{
            .record = record,
            .lifecycle = .running,
            .termination_present = false,
            .host = .present_same,
            .process = .matched,
            .checkpoint = .valid_contiguous,
        });
        try std.testing.expectEqual(Disposition.isolate_corrupt, decision.disposition);
    }
}

test "recovery retains only a matching process behind the same host" {
    const retained = reconcile(.{
        .record = .valid,
        .lifecycle = .running,
        .termination_present = false,
        .host = .present_same,
        .process = .matched,
        .checkpoint = .valid_contiguous,
    });
    try std.testing.expectEqual(Disposition.retain_live, retained.disposition);

    const host_absent = reconcile(.{
        .record = .valid,
        .lifecycle = .running,
        .termination_present = false,
        .host = .absent,
        .process = .matched,
        .checkpoint = .missing,
    });
    try std.testing.expectEqual(Disposition.mark_lost, host_absent.disposition);
    try std.testing.expectEqual(contracts.Lifecycle.lost, host_absent.lifecycle);

    const mismatched = reconcile(.{
        .record = .valid,
        .lifecycle = .starting,
        .termination_present = false,
        .host = .present_same,
        .process = .mismatched,
        .checkpoint = .disconnected,
    });
    try std.testing.expectEqual(Disposition.mark_lost, mismatched.disposition);
    try std.testing.expectEqual(
        contracts.ScreenUnavailableReason.raw_gap,
        mismatched.screen_unavailable.?,
    );
}

test "recovery finalizes durable termination and preserves completed records" {
    const exited = reconcile(.{
        .record = .valid,
        .lifecycle = .running,
        .termination_present = true,
        .host = .absent,
        .process = .missing,
        .checkpoint = .retention_evicted,
    });
    try std.testing.expectEqual(Disposition.finalize_exited, exited.disposition);
    try std.testing.expectEqual(contracts.Lifecycle.exited, exited.lifecycle);
    try std.testing.expectEqual(
        contracts.ScreenUnavailableReason.retention_evicted,
        exited.screen_unavailable.?,
    );

    const closed = reconcile(.{
        .record = .valid,
        .lifecycle = .closed,
        .termination_present = false,
        .host = .absent,
        .process = .missing,
        .checkpoint = .corrupt,
    });
    try std.testing.expectEqual(Disposition.retain_final, closed.disposition);
}
