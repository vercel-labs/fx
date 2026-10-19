//! How a launch treats the turn an earlier fx process left: the recovery
//! record alone decides (decision 46). The TUI and ACP decide the same way;
//! each words its own question.

const std = @import("std");
const recovery = @import("../recovery/recovery.zig");
const session_codec = @import("session_codec.zig");
const session_log = @import("session_log.zig");

pub const Decision = enum {
    auto_continue,
    skip_compaction_owned,
    /// No record bound to the checkpoint: nothing was in flight that fx may
    /// resend on its own (decision 51).
    ask_without_record,
    /// The record is more than a day old, or dated in the future.
    ask_old,
    /// The recovery module asks first: the request crashed fx twice.
    ask_crash_loop,
    /// The request was waiting for the user when fx closed.
    ask_waiting,
};

/// A record older than this asks before fx resends its request.
const resume_max_age_ms: i64 = 24 * std.time.ms_per_hour;
/// Clock adjustment allowed before a record counts as dated in the future.
const resume_clock_slack_ms: i64 = std.time.ms_per_min;

/// How a launch treats the checkpoint it found. The recovery record alone
/// decides (decision 46): a record bound to the checkpoint resumes its
/// request without a question, unless the record is more than a day old or
/// the recovery module would ask first. Without one, nothing was in flight
/// that fx may resend on its own, so the user decides
/// (`tests/tla/recovery/Resume.tla` NoQuestionAfterCleanClose,
/// NoQuestionAfterOneDeath, CrashLoopAsks, OldAsks).
pub fn decide(
    checkpoint: session_codec.RecoveryCheckpoint,
    record: ?session_log.RecoveryRecord,
    binding: u32,
    now_ms: i64,
) Decision {
    if (checkpoint.cause == .compaction_prepared) return .skip_compaction_owned;
    const saved = record orelse return .ask_without_record;
    // An unreadable record resumes, and the module counts it as one abrupt
    // death (decision 49).
    if (recovery.boundTo(saved.bytes)) |bound| {
        if (bound != binding) return .ask_without_record;
    }
    if (now_ms - saved.saved_at_ms > resume_max_age_ms or
        saved.saved_at_ms - now_ms > resume_clock_slack_ms) return .ask_old;
    // `step` is pure, so a copy answers what the resumed request will do.
    var probe: recovery.State = .{};
    const plan = recovery.step(&probe, .{ .start = .{ .resume_from = saved.bytes } }, 0);
    if (plan.send != null) return .auto_continue;
    const status = plan.status orelse return .ask_waiting;
    const need = status.need orelse return .ask_waiting;
    return if (need == .crash_loop) .ask_crash_loop else .ask_waiting;
}

test "a launch resumes from a record bound to its checkpoint and asks otherwise" {
    const interrupted = testCheckpoint(.network_interrupted);
    const now_ms: i64 = 1_800_000_000_000;
    const binding: u32 = 4;

    // A send was in flight when fx closed or died once.
    var state: recovery.State = .{};
    const in_flight = recovery.step(&state, .{ .start = .{ .binding = binding } }, 10).save.?;
    const saved: session_log.RecoveryRecord = .{ .bytes = in_flight, .saved_at_ms = now_ms - 5_000 };
    try std.testing.expectEqual(.auto_continue, decide(interrupted, saved, binding, now_ms));

    // No record, or one of a turn the log already committed: nothing fx
    // may resend on its own.
    try std.testing.expectEqual(.ask_without_record, decide(interrupted, null, binding, now_ms));
    try std.testing.expectEqual(.ask_without_record, decide(interrupted, saved, binding + 1, now_ms));

    // More than a day old, or dated in the future.
    var old = saved;
    old.saved_at_ms = now_ms - 25 * std.time.ms_per_hour;
    try std.testing.expectEqual(.ask_old, decide(interrupted, old, binding, now_ms));
    old.saved_at_ms = now_ms + 2 * std.time.ms_per_min;
    try std.testing.expectEqual(.ask_old, decide(interrupted, old, binding, now_ms));

    // An unreadable record resumes, counted as one death.
    var torn = saved;
    torn.bytes[31] ^= 0xff;
    try std.testing.expectEqual(.auto_continue, decide(interrupted, torn, binding, now_ms));

    // A second death with the send in flight: the module asks first.
    var again: recovery.State = .{};
    const second = recovery.step(&again, .{ .start = .{ .resume_from = in_flight, .binding = binding } }, 10).save.?;
    const crashed: session_log.RecoveryRecord = .{ .bytes = second, .saved_at_ms = now_ms - 5_000 };
    try std.testing.expectEqual(.ask_crash_loop, decide(interrupted, crashed, binding, now_ms));

    const compaction = testCheckpoint(.compaction_prepared);
    try std.testing.expectEqual(.skip_compaction_owned, decide(compaction, saved, binding, now_ms));
}

fn testCheckpoint(cause: anytype) session_codec.RecoveryCheckpoint {
    return .{
        .turn_id = 7,
        .user = .{ .text = @constCast("continue the request") },
        .assistant_source = @constCast("partial"),
        .cause = cause,
        .action = .retrying_request,
        .authority = .{ .provider = .gateway, .model = @constCast("test/model") },
        .requested_fast_mode = false,
        .fast_mode = false,
        .max_provider_attempts = 3,
        .consumed_provider_attempts = 1,
    };
}
