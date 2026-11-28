//! The in-chat setup of a remote runner, as a pure step (RULES R1.5): no I/O,
//! no clock, no allocation. The host reports what happened as an `Event`, and
//! carries out the `Decision` that `step` returns. A state keeps only what the
//! next step needs. Slices in states and decisions point into memory the host
//! owns. The states and rules follow `tests/tla/runner/RunnerSetup.tla`.

const std = @import("std");
const vercel = @import("vercel/vercel.zig");

/// How long a setup prompt waits for an answer before it counts as no answer (U7, E15).
pub const question_limit_ms: i64 = 15 * 60 * 1000;

pub const step_copy = "copy";
pub const step_create_project = "create project";
const step_write = "write";

pub const Caller = enum { main, sub_agent };

/// Whether the call can show a prompt.
pub const Channel = enum { form, none };

/// Explicit destination overrides passed from policy configuration.
pub const Intent = struct {
    /// Configured team slug override, or null to resolve from CLI config or account default.
    team: ?[]const u8 = null,
    /// Configured project name override, or null to use `fx-sandbox`.
    project: ?[]const u8 = null,
};

pub const Login = union(enum) {
    none,
    expired,
    /// A usable token whose user is not read yet. The step asks for the user
    /// only when it needs it (`Decision.need_user`).
    present,
    /// The API answered 401 or 403 for the login (R5).
    rejected,
    /// The API answered for this user id (GET /v2/user).
    user: []const u8,
};

pub const Consent = enum { missing, matches };

pub const RemoteState = struct {
    user_id: []const u8,
    matches_intent: bool,
    consent: Consent,
};

pub const Config = union(enum) {
    absent,
    /// config.remote state relative to the current user, intent, and repository consent.
    remote: RemoteState,
};

pub const Arrival = struct {
    caller: Caller,
    channel: Channel,
    login: Login,
    config: Config,
};

pub const Mark = enum { none, declined, no_answer };

/// The login user who starts a setup. That user confirms config.remote.
pub const Owner = struct {
    user_id: []const u8,
};

pub const CopyPrompt = struct {
    owner: Owner,
    team: vercel.Team,
    project: ?vercel.Project,
    asked_at_ms: i64,
};

pub const Creating = struct {
    owner: Owner,
    team: vercel.Team,
};

pub const Chosen = struct {
    owner: Owner,
    team: vercel.Team,
    project: vercel.Project,
};

pub const State = union(enum) {
    /// No setup runs. The mark is this user turn's decline mark (U4).
    idle: Mark,
    /// Discovery before the copy question: resolving team and project (read-only REST).
    discovering: Owner,
    /// The copy question is open.
    copy_prompt: CopyPrompt,
    /// After a yes when fx-sandbox is missing: creating the project on Vercel.
    creating: Creating,
    /// The locked write runs (U9). A cancel does not interrupt it.
    writing: Chosen,
    /// The write runs, and a cancel arrived meanwhile. The call ends canceled after it.
    writing_canceled: Chosen,
};

pub const Answer = union(enum) {
    yes,
    no,
    /// A dismissed or canceled form (E8).
    dismissed,
    invalid,
};

pub const WriteResult = union(enum) {
    written,
    /// The same destination was set meanwhile by another process: keep it (U9).
    kept,
    /// The keys other than remote changed, or another destination was set (E14).
    config_changed,
    /// The config file cannot be used (E4). The text says why. The allocator the
    /// write was given owns it; the caller frees it after the refusal.
    invalid: []const u8,
    /// The write did not happen (E9). The reason is `write_lock_busy` or `write_failed`.
    failed: Reason,
    /// The wait for the config lock ended by a cancel. Nothing was written.
    canceled,
};

pub const Discovered = struct {
    team: vercel.Team,
    project: ?vercel.Project,
    now_ms: i64,
};

pub const TeamMissing = struct {
    setting_slug: ?[]const u8 = null,
    available: []const vercel.Team = &.{},
};

pub const ProjectMissing = struct {
    team: vercel.Team,
    name: []const u8,
};

pub const Destination = struct {
    team: vercel.Team,
    project: vercel.Project,
    user_id: []const u8,
};

pub const Reason = union(enum) {
    api: vercel.Failure.Reason,
    /// The answer does not fit the open prompt.
    bad_answer,
    write_failed,
    /// The config lock stayed busy for the whole wait (E9 `write: config lock busy`).
    write_lock_busy,
    /// The copy question could not be shown or answered (E9).
    prompt_failed,
};

pub const StepFailure = struct {
    step: []const u8,
    reason: Reason,
};

pub const Refusal = union(enum) {
    no_login,
    login_expired,
    sub_agent,
    no_channel,
    declined,
    no_answer,
    config_changed,
    /// The config file cannot be used (E4). The text says why.
    config_invalid: []const u8,
    workspace_unresolved: []const u8,
    no_team: TeamMissing,
    project_not_found: ProjectMissing,
    project_create_failed: vercel.Failure,
    setup_failed: StepFailure,
};

pub const CopyAsk = struct {
    team: vercel.Team,
    project_name: []const u8,
};

pub const Event = union(enum) {
    /// A call reaches setup, or a waiting call checks again.
    arrival: Arrival,
    discovered: Discovered,
    discover_refused: Refusal,
    project_created: vercel.Project,
    /// A REST step failed, with the step's name (E9).
    rest_failed: vercel.Failure,
    /// The API rejected the login (E6).
    rest_rejected,
    answered: Answer,
    /// The host's clock. The prompt limit is measured from the time it asked.
    tick: i64,
    write_done: WriteResult,
    /// The user canceled the call that owns the setup.
    owner_canceled,
    /// The user canceled a call that waits for the setup.
    waiter_canceled,
    /// The open prompt could not be shown or answered (E9). Nothing is written,
    /// and no mark is set, as with a failed REST step.
    prompt_failed,
    new_turn,
};

pub const Decision = union(enum) {
    /// Nothing for the host to do.
    none,
    /// Another setup runs. Wait, then send the call again (U3).
    wait,
    /// The destination and repository consent are ready. Run the call.
    ready,
    /// The step needs the login's user id (R5) before it can go on. The host
    /// reads it and sends the arrival again. No state changes.
    need_user,
    /// Resolve the team and project via read-only REST.
    discover: Owner,
    /// Open the copy confirmation prompt.
    ask_copy: CopyAsk,
    /// Create `fx-sandbox` on Vercel after a yes.
    create_project: vercel.Team,
    /// Write config.remote and consent record (U9).
    write: Destination,
    /// The call is refused. Nothing is written.
    refuse: Refusal,
    /// The call ends canceled (U7). Nothing is written, and no mark is set.
    canceled,
};

pub const Transition = struct {
    state: State,
    decision: Decision,
};

pub const initial: State = .{ .idle = .none };

/// The next state and decision for one event.
pub fn step(state: State, event: Event) Transition {
    switch (event) {
        .arrival => |arrival| return arrive(state, arrival),
        .waiter_canceled => return stay(state, .canceled),
        .new_turn => return newTurn(state),
        else => {},
    }
    return switch (state) {
        .idle => |mark| stay(.{ .idle = mark }, .none),
        .discovering => |owner| discovering(owner, event),
        .copy_prompt => |prompt| copyPrompt(prompt, event),
        .creating => |state_creating| creating(state_creating, event),
        .writing => |chosen| writing(chosen, event),
        .writing_canceled => |chosen| writingCanceled(chosen, event),
    };
}

/// The model's Check: login, readiness with consent, caller and channel, decline
/// mark, then one setup at a time. The user is read only when a remote exists
/// (R5) or a setup is about to start, so a sub-agent (E10) and a call with no
/// channel (E7) are refused with no network call (R4 before R5).
fn arrive(state: State, arrival: Arrival) Transition {
    const known: ?[]const u8 = switch (arrival.login) {
        .none => return refuse(state, .no_login),
        .expired, .rejected => return refuse(state, .login_expired),
        .present => null,
        .user => |id| id,
    };
    switch (arrival.config) {
        .absent => {},
        .remote => |remote| {
            const user = known orelse return needUser(state);
            if (std.mem.eql(u8, remote.user_id, user) and remote.matches_intent and remote.consent == .matches) {
                return stay(state, .ready);
            }
        },
    }
    if (arrival.caller == .sub_agent) return refuse(state, .sub_agent);
    if (arrival.channel == .none) return refuse(state, .no_channel);
    return switch (state) {
        .idle => |mark| startSetup(mark, known),
        else => stay(state, .wait),
    };
}

fn needUser(state: State) Transition {
    return stay(state, .need_user);
}

fn startSetup(mark: Mark, owner: ?[]const u8) Transition {
    return switch (mark) {
        .none => if (owner) |user| .{
            .state = .{ .discovering = .{ .user_id = user } },
            .decision = .{ .discover = .{ .user_id = user } },
        } else needUser(.{ .idle = .none }),
        .declined => refuse(.{ .idle = .declined }, .declined),
        .no_answer => refuse(.{ .idle = .no_answer }, .no_answer),
    };
}

fn newTurn(state: State) Transition {
    return switch (state) {
        .idle => stay(.{ .idle = .none }, .none),
        else => stay(state, .none),
    };
}

fn discovering(owner: Owner, event: Event) Transition {
    return switch (event) {
        .discovered => |found| .{
            .state = .{ .copy_prompt = .{
                .owner = owner,
                .team = found.team,
                .project = found.project,
                .asked_at_ms = found.now_ms,
            } },
            .decision = .{ .ask_copy = .{
                .team = found.team,
                .project_name = if (found.project) |proj| proj.name else vercel.sandbox_project_name,
            } },
        },
        .discover_refused => |refusal| end(refusal),
        .rest_failed => |failure| apiFail(failure),
        .rest_rejected => end(.login_expired),
        .owner_canceled => cancelSetup(),
        else => stay(.{ .discovering = owner }, .none),
    };
}

fn copyPrompt(prompt: CopyPrompt, event: Event) Transition {
    return switch (event) {
        .answered => |answer| switch (answer) {
            .yes => if (prompt.project) |proj|
                startWrite(prompt.owner, prompt.team, proj)
            else
                .{
                    .state = .{ .creating = .{ .owner = prompt.owner, .team = prompt.team } },
                    .decision = .{ .create_project = prompt.team },
                },
            .no, .dismissed => declined(),
            .invalid => fail(step_copy, .bad_answer),
        },
        .tick => |now_ms| if (promptTimedOut(prompt.asked_at_ms, now_ms))
            noAnswer()
        else
            stay(.{ .copy_prompt = prompt }, .none),
        .owner_canceled => cancelSetup(),
        .prompt_failed => fail(step_copy, .prompt_failed),
        else => stay(.{ .copy_prompt = prompt }, .none),
    };
}

fn creating(state_creating: Creating, event: Event) Transition {
    return switch (event) {
        .project_created => |proj| startWrite(state_creating.owner, state_creating.team, proj),
        .rest_failed => |failure| end(.{ .project_create_failed = failure }),
        .rest_rejected => end(.login_expired),
        .owner_canceled => cancelSetup(),
        else => stay(.{ .creating = state_creating }, .none),
    };
}

fn startWrite(owner: Owner, team: vercel.Team, project: vercel.Project) Transition {
    return .{
        .state = .{ .writing = .{ .owner = owner, .team = team, .project = project } },
        .decision = .{ .write = .{ .team = team, .project = project, .user_id = owner.user_id } },
    };
}

fn writing(chosen: Chosen, event: Event) Transition {
    return switch (event) {
        .write_done => |result| writeResult(result),
        .owner_canceled => stay(.{ .writing_canceled = chosen }, .none),
        else => stay(.{ .writing = chosen }, .none),
    };
}

fn writeResult(result: WriteResult) Transition {
    return switch (result) {
        .written, .kept => endWith(.none, .ready),
        .config_changed => end(.config_changed),
        .invalid => |message| end(.{ .config_invalid = message }),
        .failed => |reason| fail(step_write, reason),
        .canceled => cancelSetup(),
    };
}

fn writingCanceled(chosen: Chosen, event: Event) Transition {
    return switch (event) {
        .write_done => cancelSetup(),
        else => stay(.{ .writing_canceled = chosen }, .none),
    };
}

/// The 15-minute limit (U7, E15). Time comes in with the event.
fn promptTimedOut(asked_at_ms: i64, now_ms: i64) bool {
    return now_ms - asked_at_ms >= question_limit_ms;
}

fn stay(state: State, decision: Decision) Transition {
    return .{ .state = state, .decision = decision };
}

fn refuse(state: State, reason: Refusal) Transition {
    return stay(state, .{ .refuse = reason });
}

fn endWith(mark: Mark, decision: Decision) Transition {
    return .{ .state = .{ .idle = mark }, .decision = decision };
}

fn end(reason: Refusal) Transition {
    return endWith(.none, .{ .refuse = reason });
}

fn fail(step_name: []const u8, reason: Reason) Transition {
    return end(.{ .setup_failed = .{ .step = step_name, .reason = reason } });
}

fn apiFail(failure: vercel.Failure) Transition {
    return fail(failure.step, .{ .api = failure.reason });
}

fn declined() Transition {
    return endWith(.declined, .{ .refuse = .declined });
}

fn noAnswer() Transition {
    return endWith(.no_answer, .{ .refuse = .no_answer });
}

fn cancelSetup() Transition {
    return endWith(.none, .canceled);
}

test "RunnerSetup.tla Check: a call without a login is refused E5 and no prompt opens" {
    const t = step(initial, arrivalOf(.none, .absent));
    try expectRefusal(t, .no_login);
    try expectIdle(t.state, .none);
}

test "RunnerSetup.tla Check: an expired or rejected login is refused E6 and no prompt opens" {
    const expired = step(initial, arrivalOf(.expired, .absent));
    try expectRefusal(expired, .login_expired);
    try expectIdle(expired.state, .none);

    const rejected = step(initial, arrivalOf(.rejected, .absent));
    try expectRefusal(rejected, .login_expired);
}

test "R4 before R5: with no remote, a sub-agent or no-channel call is refused before reading the user" {
    const sub = step(initial, .{ .arrival = .{ .caller = .sub_agent, .channel = .form, .login = .present, .config = .absent } });
    try expectRefusal(sub, .sub_agent);

    const headless = step(initial, .{ .arrival = .{ .caller = .main, .channel = .none, .login = .present, .config = .absent } });
    try expectRefusal(headless, .no_channel);
}

test "R5: a remote needs the login user, so present asks for it" {
    const t = step(initial, .{ .arrival = .{
        .caller = .main,
        .channel = .form,
        .login = .present,
        .config = .{ .remote = .{ .user_id = user_alice, .matches_intent = true, .consent = .matches } },
    } });
    try expectTag(Decision, .need_user, t.decision);

    const asked = step(initial, .{ .arrival = .{ .caller = .main, .channel = .form, .login = .present, .config = .absent } });
    try expectTag(Decision, .need_user, asked.decision);

    const started = step(asked.state, .{ .arrival = .{ .caller = .main, .channel = .form, .login = .{ .user = user_alice }, .config = .absent } });
    try expectTag(State, .discovering, started.state);
    try expectTag(Decision, .discover, started.decision);
}

test "R5: a declined mark is refused without asking for the user" {
    const t = step(.{ .idle = .declined }, .{ .arrival = .{ .caller = .main, .channel = .form, .login = .present, .config = .absent } });
    try expectRefusal(t, .declined);
}

test "RunnerSetup.tla RemoteNeedsReady and NoCopyWithoutConsent: ready requires matching user, intent, and consent" {
    const ready = step(initial, arrivalOf(.{ .user = user_alice }, remoteMatching(user_alice, .matches)));
    try expectTag(Decision, .ready, ready.decision);

    const missing_consent = step(initial, arrivalOf(.{ .user = user_alice }, remoteMatching(user_alice, .missing)));
    try expectTag(Decision, .discover, missing_consent.decision);

    const intent_mismatch = step(initial, arrivalOf(.{ .user = user_alice }, .{ .remote = .{
        .user_id = user_alice,
        .matches_intent = false,
        .consent = .matches,
    } }));
    try expectTag(Decision, .discover, intent_mismatch.decision);

    const other_user = step(initial, arrivalOf(.{ .user = user_bob }, remoteMatching(user_alice, .matches)));
    try expectTag(Decision, .discover, other_user.decision);
}

test "RunnerSetup.tla NoPromptWithoutChannel: sub-agent and headless run with consent, refuse without it, and never wait" {
    const sub_ready = step(initial, .{ .arrival = .{
        .caller = .sub_agent,
        .channel = .none,
        .login = .{ .user = user_alice },
        .config = remoteMatching(user_alice, .matches),
    } });
    try expectTag(Decision, .ready, sub_ready.decision);

    const busy = step(initial, arrivalOf(.{ .user = user_alice }, .absent));
    const sub_refused = step(busy.state, .{ .arrival = .{
        .caller = .sub_agent,
        .channel = .form,
        .login = .{ .user = user_alice },
        .config = remoteMatching(user_alice, .missing),
    } });
    try expectRefusal(sub_refused, .sub_agent);
    try expectTag(State, .discovering, sub_refused.state);

    const headless_refused = step(busy.state, .{ .arrival = .{
        .caller = .main,
        .channel = .none,
        .login = .{ .user = user_bob },
        .config = .absent,
    } });
    try expectRefusal(headless_refused, .no_channel);
    try expectTag(State, .discovering, headless_refused.state);
}

test "RunnerSetup.tla DiscoverDone and DiscoverFail: discovery opens copy prompt or refuses without mark" {
    const started = step(initial, arrivalOf(.{ .user = user_alice }, .absent));
    const prompt_existing = step(started.state, .{ .discovered = .{ .team = team_one, .project = web, .now_ms = 10 } });
    try expectTag(State, .copy_prompt, prompt_existing.state);
    try expectTag(Decision, .ask_copy, prompt_existing.decision);
    try std.testing.expectEqualStrings("web", prompt_existing.decision.ask_copy.project_name);

    const prompt_missing_sandbox = step(started.state, .{ .discovered = .{ .team = team_one, .project = null, .now_ms = 10 } });
    try expectTag(State, .copy_prompt, prompt_missing_sandbox.state);
    try expectTag(Decision, .ask_copy, prompt_missing_sandbox.decision);
    try std.testing.expectEqualStrings(vercel.sandbox_project_name, prompt_missing_sandbox.decision.ask_copy.project_name);

    const no_team = step(started.state, .{ .discover_refused = .{ .no_team = .{} } });
    try expectRefusal(no_team, .no_team);
    try expectIdle(no_team.state, .none);

    const api_fail = step(started.state, .{ .rest_failed = .{ .step = "team", .reason = .timeout } });
    try expectSetupFailed(api_fail, "team", .api);
    try expectIdle(api_fail.state, .none);

    const rejected = step(started.state, .rest_rejected);
    try expectRefusal(rejected, .login_expired);
    try expectIdle(rejected.state, .none);
}

test "RunnerSetup.tla SinglePrompt: a second call waits during discovery, copy prompt, create, and write" {
    const disc_t = step(initial, arrivalOf(.{ .user = user_alice }, .absent));
    try expectTag(Decision, .wait, step(disc_t.state, arrivalOf(.{ .user = user_bob }, .absent)).decision);

    const asking = step(disc_t.state, .{ .discovered = .{ .team = team_one, .project = null, .now_ms = 0 } });
    try expectTag(Decision, .wait, step(asking.state, arrivalOf(.{ .user = user_bob }, .absent)).decision);

    const create_t = step(asking.state, .{ .answered = .yes });
    try expectTag(State, .creating, create_t.state);
    try expectTag(Decision, .wait, step(create_t.state, arrivalOf(.{ .user = user_bob }, .absent)).decision);

    const write_t = step(create_t.state, .{ .project_created = sandbox });
    try expectTag(State, .writing, write_t.state);
    try expectTag(Decision, .wait, step(write_t.state, arrivalOf(.{ .user = user_bob }, .absent)).decision);
}

test "RunnerSetup.tla NoVercelWriteBeforeYes: yes creates missing fx-sandbox or writes existing project" {
    const with_existing = copyPromptWith(web, 0);
    const write_existing = step(with_existing.state, .{ .answered = .yes });
    try expectTag(State, .writing, write_existing.state);
    try expectTag(Decision, .write, write_existing.decision);
    try std.testing.expectEqualStrings(web.id, write_existing.decision.write.project.id);

    const with_missing = copyPromptWith(null, 0);
    const create_missing = step(with_missing.state, .{ .answered = .yes });
    try expectTag(State, .creating, create_missing.state);
    try expectTag(Decision, .create_project, create_missing.decision);

    const created = step(create_missing.state, .{ .project_created = sandbox });
    try expectTag(State, .writing, created.state);
    try expectTag(Decision, .write, created.decision);
    try std.testing.expectEqualStrings(sandbox.id, created.decision.write.project.id);

    const create_failed = step(create_missing.state, .{ .rest_failed = .{ .step = step_create_project, .reason = .{ .status = 500 } } });
    try expectRefusal(create_failed, .project_create_failed);
    try expectIdle(create_failed.state, .none);

    const create_rejected = step(create_missing.state, .rest_rejected);
    try expectRefusal(create_rejected, .login_expired);
    try expectIdle(create_rejected.state, .none);
}

test "RunnerSetup.tla NoPromptAfterDecline and ConsentOnlyByPerson: no and dismissed set mark without write" {
    for ([_]Answer{ .no, .dismissed }) |answer| {
        const declined_t = step(copyPromptWith(web, 0).state, .{ .answered = answer });
        try expectRefusal(declined_t, .declined);
        try expectIdle(declined_t.state, .declined);

        const repeat = step(declined_t.state, arrivalOf(.{ .user = user_alice }, .absent));
        try expectRefusal(repeat, .declined);
        try expectIdle(repeat.state, .declined);

        const next_turn = step(repeat.state, .new_turn);
        try expectIdle(next_turn.state, .none);
        const again = step(next_turn.state, arrivalOf(.{ .user = user_alice }, .absent));
        try expectTag(State, .discovering, again.state);
    }
}

test "RunnerSetup.tla EventuallyEnds: copy prompt timeout sets no_answer mark and refuses same turn" {
    const prompt = copyPromptWith(web, 100);
    const before = step(prompt.state, .{ .tick = 100 + question_limit_ms - 1 });
    try expectTag(Decision, .none, before.decision);
    try expectTag(State, .copy_prompt, before.state);

    const at_limit = step(prompt.state, .{ .tick = 100 + question_limit_ms });
    try expectRefusal(at_limit, .no_answer);
    try expectIdle(at_limit.state, .no_answer);

    const repeat = step(at_limit.state, arrivalOf(.{ .user = user_alice }, .absent));
    try expectRefusal(repeat, .no_answer);

    const next_turn = step(repeat.state, .new_turn);
    try expectIdle(next_turn.state, .none);
}

test "RunnerSetup.tla NoWriteAfterEarlyCancel and NoPromptAfterCancel: cancel ends canceled without writing" {
    const disc_t = step(initial, arrivalOf(.{ .user = user_alice }, .absent));
    const canceled_discover = step(disc_t.state, .owner_canceled);
    try expectTag(Decision, .canceled, canceled_discover.decision);
    try expectIdle(canceled_discover.state, .none);
    try expectTag(Decision, .none, step(canceled_discover.state, .{ .discovered = .{ .team = team_one, .project = web, .now_ms = 0 } }).decision);

    const asking = copyPromptWith(null, 0);
    const canceled_ask = step(asking.state, .owner_canceled);
    try expectTag(Decision, .canceled, canceled_ask.decision);
    try expectIdle(canceled_ask.state, .none);

    const create_t = step(asking.state, .{ .answered = .yes });
    const canceled_create = step(create_t.state, .owner_canceled);
    try expectTag(Decision, .canceled, canceled_create.decision);
    try expectIdle(canceled_create.state, .none);
    try expectTag(Decision, .none, step(canceled_create.state, .{ .project_created = sandbox }).decision);

    const write_t = step(create_t.state, .{ .project_created = sandbox });
    const canceled_during_write = step(write_t.state, .owner_canceled);
    try expectTag(State, .writing_canceled, canceled_during_write.state);
    try expectTag(Decision, .none, canceled_during_write.decision);
    const finished = step(canceled_during_write.state, .{ .write_done = .written });
    try expectTag(Decision, .canceled, finished.decision);
    try expectIdle(finished.state, .none);

    const waiter = step(disc_t.state, arrivalOf(.{ .user = user_bob }, .absent));
    try expectTag(Decision, .wait, waiter.decision);
    const waiter_canceled = step(waiter.state, .waiter_canceled);
    try expectTag(Decision, .canceled, waiter_canceled.decision);
    try expectTag(State, .discovering, waiter_canceled.state);
}

test "U1/U9: prompt failure and write outcomes map cleanly" {
    const asking = copyPromptWith(web, 0);
    const bad = step(asking.state, .{ .answered = .invalid });
    try expectSetupFailed(bad, step_copy, .bad_answer);
    try expectIdle(bad.state, .none);

    const failed = step(asking.state, .prompt_failed);
    try expectSetupFailed(failed, step_copy, .prompt_failed);
    try expectIdle(failed.state, .none);

    const write_t = step(asking.state, .{ .answered = .yes });
    try expectTag(Decision, .ready, step(write_t.state, .{ .write_done = .written }).decision);
    try expectTag(Decision, .ready, step(write_t.state, .{ .write_done = .kept }).decision);
    try expectRefusal(step(write_t.state, .{ .write_done = .config_changed }), .config_changed);
    try expectRefusal(step(write_t.state, .{ .write_done = .{ .invalid = "reason" } }), .config_invalid);
    try expectSetupFailed(step(write_t.state, .{ .write_done = .{ .failed = .write_failed } }), step_write, .write_failed);
    try expectSetupFailed(step(write_t.state, .{ .write_done = .{ .failed = .write_lock_busy } }), step_write, .write_lock_busy);
    try expectTag(Decision, .canceled, step(write_t.state, .{ .write_done = .canceled }).decision);
}

const user_alice = "user_alice";
const user_bob = "user_bob";
const team_one = vercel.Team{ .id = "team_1", .slug = "one", .name = "One" };
const web = vercel.Project{ .id = "prj_web", .name = "web" };
const sandbox = vercel.Project{ .id = "prj_sandbox", .name = "fx-sandbox" };

fn remoteMatching(user_id: []const u8, consent: Consent) Config {
    return .{ .remote = .{ .user_id = user_id, .matches_intent = true, .consent = consent } };
}

fn arrivalOf(login: Login, config: Config) Event {
    return .{ .arrival = .{ .caller = .main, .channel = .form, .login = login, .config = config } };
}

fn copyPromptWith(project: ?vercel.Project, now_ms: i64) Transition {
    const started = step(initial, arrivalOf(.{ .user = user_alice }, .absent));
    return step(started.state, .{ .discovered = .{ .team = team_one, .project = project, .now_ms = now_ms } });
}

fn expectTag(comptime T: type, expected: std.meta.Tag(T), value: T) !void {
    try std.testing.expectEqual(expected, std.meta.activeTag(value));
}

fn expectRefusal(t: Transition, expected: std.meta.Tag(Refusal)) !void {
    try expectTag(Decision, .refuse, t.decision);
    try expectTag(Refusal, expected, t.decision.refuse);
}

fn expectSetupFailed(t: Transition, step_name: []const u8, expected: std.meta.Tag(Reason)) !void {
    try expectRefusal(t, .setup_failed);
    try std.testing.expectEqualStrings(step_name, t.decision.refuse.setup_failed.step);
    try expectTag(Reason, expected, t.decision.refuse.setup_failed.reason);
}

fn expectIdle(state: State, mark: Mark) !void {
    try expectTag(State, .idle, state);
    try std.testing.expectEqual(mark, state.idle);
}
