//! How a turn that fx stopped goes on.
//!
//! fx reports how the process left a turn (`Stop`) and, for each tool call
//! the stop left running, whether its result was recorded. The module answers
//! each call and says whether the model reads fx's resume notice. The CLI's
//! session replay and resume and the libfx journal carry out its answers, so
//! the same stop gives the model the same turn on every host.
//!
//! The module performs no I/O, reads no clock, starts no thread, keeps no
//! global state, and never allocates. Outside code imports only this file,
//! and this file imports only `std`.

const std = @import("std");

/// How the process that ran the turn left it.
pub const Stop = enum {
    /// The process ended before the turn finished: SIGKILL, a crash, a
    /// host's hard cut-off, or a closed window (SIGHUP, SIGTERM).
    interrupted,
    /// The host stopped the turn between steps to continue it later
    /// (`src/core/quiesce/`, libfx `yieldAt`, Ctrl+G).
    yielded,
};

/// What the model reads for a call the stop left running.
pub const Answer = enum {
    /// The result recorded as the call finished.
    recorded,
    /// `unfinished_call_output`: the call may have partly run.
    may_have_partly_run,
};

/// Whether a call's result was recorded as it finished.
pub const Recorded = enum { recorded, unrecorded };

/// A call keeps the result recorded as it finished. Any other may have
/// partly run, so the model decides whether to run it again (RULES.md R3.3).
pub fn answer(recorded: Recorded) Answer {
    return switch (recorded) {
        .recorded => .recorded,
        .unrecorded => .may_have_partly_run,
    };
}

pub const Notice = enum {
    /// The model reads nothing new.
    none,
    /// The model reads `resume_notice` after the turn's finished steps.
    resumed,
};

/// Whether a turn already holds fx's resume notice.
pub const Told = enum { told, untold };

/// The notice a turn that `stop` ended reads when it goes on. A yield is the
/// host's own pause, so the turn goes on as if it never stopped. A turn reads
/// the notice once: one that already holds it keeps that one where the model
/// first saw it, so each later request still extends the one before it
/// (`tests/tla/durable/Resumption.tla` AtMostOneNotice).
pub fn notice(stop: Stop, told: Told) Notice {
    if (told == .told) return .none;
    return switch (stop) {
        .interrupted => .resumed,
        .yielded => .none,
    };
}

/// What the model reads after the finished steps of a turn that goes on after
/// an interruption.
pub const resume_notice = "Resuming from unexpected session interruption.";

/// What the model reads for a call that was running when its turn stopped.
pub const unfinished_call_output = "fx stopped while this tool was running, so it may have partly run. Check its effects before running it again.";

test "continuation: a recorded call keeps its result and any other may have partly run" {
    try std.testing.expectEqual(Answer.recorded, answer(.recorded));
    try std.testing.expectEqual(Answer.may_have_partly_run, answer(.unrecorded));
}

test "continuation: an interrupted turn reads the resume notice once" {
    try std.testing.expectEqual(Notice.resumed, notice(.interrupted, .untold));
    try std.testing.expectEqual(Notice.none, notice(.interrupted, .told));
}

test "continuation: a yielded turn reads no notice" {
    try std.testing.expectEqual(Notice.none, notice(.yielded, .untold));
    try std.testing.expectEqual(Notice.none, notice(.yielded, .told));
}

test "continuation: the texts the model reads are pinned byte for byte" {
    try std.testing.expectEqualStrings("Resuming from unexpected session interruption.", resume_notice);
    try std.testing.expectEqualStrings(
        "fx stopped while this tool was running, so it may have partly run. Check its effects before running it again.",
        unfinished_call_output,
    );
}
