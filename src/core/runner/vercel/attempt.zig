//! The retry plan for one sandbox call (V3, V5, V6, V7). Pure: no I/O, no clock, no allocation.
//! Callers carry out the plan and keep the budget they pass in. Each row below is one test.
const std = @import("std");

/// The call being answered. `exec` is the command request itself.
pub const Step = enum { user, setup, generation, marker, push, patch, extend, exec };

/// A remote run recovers a session. An isolated run never does (I3).
pub const Mode = enum { remote, isolated };

/// What the call's answer says.
pub const Outcome = union(enum) {
    ok,
    /// The push's answer that the folder is missing (V5, `Cannot open`).
    cannot_open,
    /// 404 or 410: the session or the sandbox is gone (V3).
    gone: u16,
    /// Any other failure. The caller keeps its own detail.
    failed: u16,
};

/// What the run already used: one repair (a push, V5) and one resume (every session call before exec, V3).
/// The budget is per run, so it is never reset inside one run.
pub const Used = struct {
    repaired: bool = false,
    recovered: bool = false,
};

pub const Refusal = enum {
    /// The folder is still missing after one repair (V5).
    folder_missing,
    /// The session ended, and recovery is not allowed or is already used (V3).
    session_ended,
    /// The command request got 404 or 410 before its command line, and this run cannot resume: the command
    /// did not run (V3, V6, V7).
    not_sent,
    /// Any other failure. The caller keeps its own detail.
    failed,
};

pub const Plan = union(enum) {
    done,
    /// Repair the folder once, then send the call again (V5).
    repair,
    /// One resume GET, then send the call again (V3).
    resume_session,
    refuse: Refusal,
};

/// The one definition of which statuses mean a gone session (V3).
pub fn statusOutcome(status: u16) Outcome {
    return if (status == 404 or status == 410) .{ .gone = status } else .{ .failed = status };
}

/// V13: a 401 or 403 from a call before the exec means Vercel rejected the login, so the run stops (N11).
pub fn loginRejected(status: u16) bool {
    return status == 401 or status == 403;
}

pub fn plan(step: Step, mode: Mode, outcome: Outcome, used: Used) Plan {
    return switch (outcome) {
        .ok => .done,
        .cannot_open => if (step == .push and !used.repaired)
            .repair
        else
            .{ .refuse = if (step == .push) .folder_missing else .failed },
        .gone => if (step == .exec)
            (if (mode == .remote and !used.recovered) Plan.resume_session else Plan{ .refuse = .not_sent })
        else if (mode == .isolated or used.recovered)
            .{ .refuse = .session_ended }
        else
            .resume_session,
        .failed => .{ .refuse = .failed },
    };
}

test "a successful answer ends the call, whatever the step, mode, or budget" {
    const used: Used = .{ .repaired = true, .recovered = true };
    try std.testing.expectEqual(Plan.done, plan(.push, .remote, .ok, used));
    try std.testing.expectEqual(Plan.done, plan(.exec, .isolated, .ok, .{}));
}

test "a missing folder is repaired once for a push, then refused (V5)" {
    try std.testing.expectEqual(Plan.repair, plan(.push, .remote, .cannot_open, .{}));
    try std.testing.expectEqual(Plan.repair, plan(.push, .isolated, .cannot_open, .{}));
    try std.testing.expectEqual(
        Plan{ .refuse = .folder_missing },
        plan(.push, .remote, .cannot_open, .{ .repaired = true }),
    );
    try std.testing.expectEqual(Plan{ .refuse = .failed }, plan(.marker, .remote, .cannot_open, .{}));
}

test "a gone session resumes once for a remote step before exec (V3)" {
    try std.testing.expectEqual(Plan.resume_session, plan(.push, .remote, .{ .gone = 410 }, .{}));
    try std.testing.expectEqual(Plan.resume_session, plan(.marker, .remote, .{ .gone = 404 }, .{}));
    try std.testing.expectEqual(Plan.resume_session, plan(.patch, .remote, .{ .gone = 410 }, .{}));
    try std.testing.expectEqual(Plan.resume_session, plan(.extend, .remote, .{ .gone = 410 }, .{}));
    try std.testing.expectEqual(
        Plan{ .refuse = .session_ended },
        plan(.push, .remote, .{ .gone = 410 }, .{ .recovered = true }),
    );
    try std.testing.expectEqual(
        Plan{ .refuse = .session_ended },
        plan(.extend, .remote, .{ .gone = 410 }, .{ .recovered = true }),
    );
}

test "an isolated step never resumes a gone session (I3)" {
    try std.testing.expectEqual(
        Plan{ .refuse = .session_ended },
        plan(.push, .isolated, .{ .gone = 410 }, .{}),
    );
    try std.testing.expectEqual(
        Plan{ .refuse = .session_ended },
        plan(.setup, .isolated, .{ .gone = 404 }, .{}),
    );
}

test "an exec answered 404 or 410 before its command line resumes once when the run's recovery is unused (V3, V6)" {
    try std.testing.expectEqual(Plan.resume_session, plan(.exec, .remote, .{ .gone = 410 }, .{}));
    try std.testing.expectEqual(Plan.resume_session, plan(.exec, .remote, .{ .gone = 404 }, .{}));
}

test "an exec answered 404 or 410 is refused when the run's recovery is spent, or the run is isolated (V3, V6)" {
    try std.testing.expectEqual(
        Plan{ .refuse = .not_sent },
        plan(.exec, .remote, .{ .gone = 410 }, .{ .recovered = true }),
    );
    try std.testing.expectEqual(Plan{ .refuse = .not_sent }, plan(.exec, .isolated, .{ .gone = 404 }, .{}));
}

test "any other failure is refused with the caller's detail" {
    try std.testing.expectEqual(Plan{ .refuse = .failed }, plan(.push, .remote, .{ .failed = 500 }, .{}));
    try std.testing.expectEqual(Plan{ .refuse = .failed }, plan(.exec, .remote, .{ .failed = 409 }, .{}));
}

test "only 404 and 410 are gone statuses (V3)" {
    try std.testing.expectEqual(Outcome{ .gone = 404 }, statusOutcome(404));
    try std.testing.expectEqual(Outcome{ .gone = 410 }, statusOutcome(410));
    try std.testing.expectEqual(Outcome{ .failed = 409 }, statusOutcome(409));
    try std.testing.expectEqual(Outcome{ .failed = 500 }, statusOutcome(500));
}
