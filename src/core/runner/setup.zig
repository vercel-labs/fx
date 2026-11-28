//! The in-chat setup of a remote runner, as a pure step (RULES R1.5): no I/O,
//! no clock, no allocation. The host reports what happened as an `Event`, and
//! carries out the `Decision` that `step` returns. A state keeps only what the
//! next step needs. Slices in states and decisions point into memory the host
//! owns. The states and rules follow tests/tla/runner/RunnerSetup.tla. Each test
//! names the model property it checks.

const std = @import("std");
const vercel = @import("vercel/vercel.zig");

/// How long a setup prompt waits for an answer before it counts as no answer (U7, E15).
pub const question_limit_ms: i64 = 15 * 60 * 1000;

/// Up to this many teams are listed in the team prompt. With more, the prompt
/// asks for a team slug as text (U5).
pub const max_team_choices: usize = 60;

pub const step_teams = "teams";
pub const step_team = "team";
pub const step_project = "project";
const step_write = "write";

pub const Caller = enum { main, sub_agent };

/// Whether the call can show a prompt.
pub const Channel = enum { form, none };

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

pub const Config = union(enum) {
    absent,
    /// config.remote.user_id: the user who confirmed the destination.
    remote: []const u8,
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

pub const TeamChoices = union(enum) {
    /// P1 lists these teams.
    choose: []const vercel.Team,
    /// P1 asks for a team slug as text: more than max_team_choices teams.
    slug,
};

pub const TeamPrompt = struct {
    owner: Owner,
    choices: TeamChoices,
    asked_at_ms: i64,
};

pub const ProjectPrompt = struct {
    owner: Owner,
    team: vercel.Team,
    projects: []const vercel.Project,
    offer_create: bool,
    asked_at_ms: i64,
};

/// A team is chosen, and the project is not yet.
pub const Pick = struct {
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
    /// Discovery before P1: the teams are listed.
    teams_listing: Owner,
    /// Discovery after a slug answer at P1: the team is looked up.
    team_slug_lookup: Owner,
    /// Discovery before P2: the projects of the chosen team are listed.
    projects_listing: Pick,
    /// P1 is open.
    team_prompt: TeamPrompt,
    /// P2 is open.
    project_prompt: ProjectPrompt,
    /// After a P2 accept: the project is created or looked up.
    project_resolving: Pick,
    /// The locked write runs (U9). A cancel does not interrupt it.
    writing: Chosen,
    /// The write runs, and a cancel arrived meanwhile. The call ends canceled after it.
    writing_canceled: Chosen,
};

pub const Answer = union(enum) {
    /// P1: a team id from the list.
    team_choice: []const u8,
    /// P1: a team slug typed in.
    team_slug: []const u8,
    /// P2: a project id from the list.
    project_choice: []const u8,
    /// P2: create the project named fx-sandbox.
    project_create,
    /// P2: another project, by the name typed in.
    project_other: []const u8,
    /// A decline or a dismissed form, at P1 or P2 (E8).
    dismissed,
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

pub const Event = union(enum) {
    /// A call reaches setup, or a waiting call checks again.
    arrival: Arrival,
    teams_listed: TeamsListed,
    team_resolved: vercel.Team,
    projects_listed: ProjectsListed,
    project_resolved: vercel.Project,
    /// A REST step failed, with the step's name (E9).
    rest_failed: vercel.Failure,
    /// The API rejected the login (E6).
    rest_rejected,
    /// A REST step found no team, or no project, with the step's name (E9).
    rest_not_found: []const u8,
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

    pub const TeamsListed = struct {
        teams: []const vercel.Team,
        now_ms: i64,
    };

    pub const ProjectsListed = struct {
        projects: []const vercel.Project,
        now_ms: i64,
    };
};

pub const Rest = union(enum) {
    list_teams,
    team_by_slug: []const u8,
    list_projects: vercel.Team,
    create_project: vercel.Team,
    project_by_name: ProjectByName,
};

pub const ProjectByName = struct {
    team: vercel.Team,
    name: []const u8,
};

pub const ProjectAsk = struct {
    team: vercel.Team,
    projects: []const vercel.Project,
    offer_create: bool,
};

pub const Destination = struct {
    team: vercel.Team,
    project: vercel.Project,
    user_id: []const u8,
};

pub const Reason = union(enum) {
    api: vercel.Failure.Reason,
    /// A team, project or slug the API does not have.
    not_found,
    /// The login has no team.
    no_team,
    /// The answer does not fit the open prompt.
    bad_answer,
    write_failed,
    /// The config lock stayed busy for the whole wait (E9 `write: config lock busy`).
    write_lock_busy,
    /// P1 or P2 could not be shown or answered (E9).
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
    setup_failed: StepFailure,
};

pub const Decision = union(enum) {
    /// Nothing for the host to do.
    none,
    /// Another setup runs. Wait, then send the call again (U3).
    wait,
    /// The destination is ready. The host reads the login again and runs the call.
    ready,
    /// The step needs the login's user id (R5) before it can go on. The host
    /// reads it and sends the arrival again. No state changes.
    need_user,
    /// A REST step. Its result comes back as an event.
    rest: Rest,
    /// Open P1.
    ask_team: TeamChoices,
    /// Open P2.
    ask_project: ProjectAsk,
    /// Write config.remote under the lock (U9).
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
        .teams_listing => |owner| teamsListing(owner, event),
        .team_slug_lookup => |owner| teamSlugLookup(owner, event),
        .projects_listing => |pick| projectsListing(pick, event),
        .team_prompt => |prompt| teamPrompt(prompt, event),
        .project_prompt => |prompt| projectPrompt(prompt, event),
        .project_resolving => |pick| projectResolving(pick, event),
        .writing => |chosen| writing(chosen, event),
        .writing_canceled => |chosen| writingCanceled(chosen, event),
    };
}

/// The model's Check: login, then readiness, then the caller and the channel,
/// then the mark, then one setup at a time. The user is read only when a remote
/// exists (R5) or a setup is about to start, so a sub-agent (E10) and a call
/// with no channel (E7) are refused with no network call (R4 before R5).
fn arrive(state: State, arrival: Arrival) Transition {
    const known: ?[]const u8 = switch (arrival.login) {
        .none => return refuse(state, .no_login),
        .expired, .rejected => return refuse(state, .login_expired),
        .present => null,
        .user => |id| id,
    };
    switch (arrival.config) {
        .absent => {},
        .remote => |confirmed| {
            const user = known orelse return needUser(state);
            if (std.mem.eql(u8, confirmed, user)) return stay(state, .ready);
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

/// A setup needs the owner's user id before it lists the teams. It is read only
/// after a declined or unanswered mark has been checked, so those refusals make
/// no network call.
fn startSetup(mark: Mark, owner: ?[]const u8) Transition {
    return switch (mark) {
        .none => if (owner) |user| .{
            .state = .{ .teams_listing = .{ .user_id = user } },
            .decision = .{ .rest = .list_teams },
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

fn teamsListing(owner: Owner, event: Event) Transition {
    return switch (event) {
        .teams_listed => |listed| onTeamsListed(owner, listed),
        .rest_failed => |failure| apiFail(failure),
        .rest_rejected => end(.login_expired),
        .rest_not_found => |name| fail(name, .not_found),
        .owner_canceled => cancelSetup(),
        else => stay(.{ .teams_listing = owner }, .none),
    };
}

fn onTeamsListed(owner: Owner, listed: Event.TeamsListed) Transition {
    if (listed.teams.len == 0) return fail(step_teams, .no_team);
    if (listed.teams.len == 1) return listProjects(owner, listed.teams[0]);
    const choices = teamChoices(listed.teams);
    return .{
        .state = .{ .team_prompt = .{
            .owner = owner,
            .choices = choices,
            .asked_at_ms = listed.now_ms,
        } },
        .decision = .{ .ask_team = choices },
    };
}

fn teamChoices(teams: []const vercel.Team) TeamChoices {
    return if (teams.len <= max_team_choices) .{ .choose = teams } else .slug;
}

fn listProjects(owner: Owner, team: vercel.Team) Transition {
    return .{
        .state = .{ .projects_listing = .{ .owner = owner, .team = team } },
        .decision = .{ .rest = .{ .list_projects = team } },
    };
}

fn teamSlugLookup(owner: Owner, event: Event) Transition {
    return switch (event) {
        .team_resolved => |team| listProjects(owner, team),
        .rest_failed => |failure| apiFail(failure),
        .rest_rejected => end(.login_expired),
        .rest_not_found => |name| fail(name, .not_found),
        .owner_canceled => cancelSetup(),
        else => stay(.{ .team_slug_lookup = owner }, .none),
    };
}

fn projectsListing(pick: Pick, event: Event) Transition {
    return switch (event) {
        .projects_listed => |listed| askProject(pick, listed),
        .rest_failed => |failure| apiFail(failure),
        .rest_rejected => end(.login_expired),
        .rest_not_found => |name| fail(name, .not_found),
        .owner_canceled => cancelSetup(),
        else => stay(.{ .projects_listing = pick }, .none),
    };
}

fn askProject(pick: Pick, listed: Event.ProjectsListed) Transition {
    const offer_create = !hasProjectNamed(listed.projects, vercel.sandbox_project_name);
    return .{
        .state = .{ .project_prompt = .{
            .owner = pick.owner,
            .team = pick.team,
            .projects = listed.projects,
            .offer_create = offer_create,
            .asked_at_ms = listed.now_ms,
        } },
        .decision = .{ .ask_project = .{
            .team = pick.team,
            .projects = listed.projects,
            .offer_create = offer_create,
        } },
    };
}

pub fn hasProjectNamed(projects: []const vercel.Project, name: []const u8) bool {
    for (projects) |project| {
        if (std.mem.eql(u8, project.name, name)) return true;
    }
    return false;
}

fn teamPrompt(prompt: TeamPrompt, event: Event) Transition {
    return switch (event) {
        .answered => |answer| answerTeam(prompt, answer),
        .tick => |now_ms| if (promptTimedOut(prompt.asked_at_ms, now_ms))
            noAnswer()
        else
            stay(.{ .team_prompt = prompt }, .none),
        .owner_canceled => cancelSetup(),
        .prompt_failed => fail(step_team, .prompt_failed),
        else => stay(.{ .team_prompt = prompt }, .none),
    };
}

fn answerTeam(prompt: TeamPrompt, answer: Answer) Transition {
    return switch (answer) {
        .team_choice => |id| chooseTeam(prompt, id),
        .team_slug => |slug| typeSlug(prompt, slug),
        .dismissed => declined(),
        .project_choice, .project_create, .project_other => fail(step_team, .bad_answer),
    };
}

fn chooseTeam(prompt: TeamPrompt, id: []const u8) Transition {
    const teams = switch (prompt.choices) {
        .choose => |listed| listed,
        .slug => return fail(step_team, .bad_answer),
    };
    for (teams) |team| {
        if (std.mem.eql(u8, team.id, id)) return listProjects(prompt.owner, team);
    }
    return fail(step_team, .bad_answer);
}

fn typeSlug(prompt: TeamPrompt, slug: []const u8) Transition {
    switch (prompt.choices) {
        .slug => {},
        .choose => return fail(step_team, .bad_answer),
    }
    if (slug.len == 0) return fail(step_team, .bad_answer);
    return .{
        .state = .{ .team_slug_lookup = prompt.owner },
        .decision = .{ .rest = .{ .team_by_slug = slug } },
    };
}

fn projectPrompt(prompt: ProjectPrompt, event: Event) Transition {
    return switch (event) {
        .answered => |answer| answerProject(prompt, answer),
        .tick => |now_ms| if (promptTimedOut(prompt.asked_at_ms, now_ms))
            noAnswer()
        else
            stay(.{ .project_prompt = prompt }, .none),
        .owner_canceled => cancelSetup(),
        .prompt_failed => fail(step_project, .prompt_failed),
        else => stay(.{ .project_prompt = prompt }, .none),
    };
}

fn answerProject(prompt: ProjectPrompt, answer: Answer) Transition {
    return switch (answer) {
        .project_choice => |id| chooseProject(prompt, id),
        .project_create => if (prompt.offer_create)
            createProject(prompt)
        else
            fail(step_project, .bad_answer),
        .project_other => |name| lookupProject(prompt, name),
        .dismissed => declined(),
        .team_choice, .team_slug => fail(step_project, .bad_answer),
    };
}

/// The P2 accept is the consent. A project that is listed needs no create or
/// lookup step, so the write starts at once.
fn chooseProject(prompt: ProjectPrompt, id: []const u8) Transition {
    for (prompt.projects) |project| {
        if (std.mem.eql(u8, project.id, id)) return startWrite(prompt.owner, prompt.team, project);
    }
    return fail(step_project, .bad_answer);
}

fn createProject(prompt: ProjectPrompt) Transition {
    return .{
        .state = .{ .project_resolving = .{ .owner = prompt.owner, .team = prompt.team } },
        .decision = .{ .rest = .{ .create_project = prompt.team } },
    };
}

fn lookupProject(prompt: ProjectPrompt, name: []const u8) Transition {
    if (name.len == 0) return fail(step_project, .bad_answer);
    return .{
        .state = .{ .project_resolving = .{ .owner = prompt.owner, .team = prompt.team } },
        .decision = .{ .rest = .{ .project_by_name = .{ .team = prompt.team, .name = name } } },
    };
}

fn projectResolving(pick: Pick, event: Event) Transition {
    return switch (event) {
        .project_resolved => |project| startWrite(pick.owner, pick.team, project),
        .rest_failed => |failure| apiFail(failure),
        .rest_rejected => end(.login_expired),
        .rest_not_found => |name| fail(name, .not_found),
        .owner_canceled => cancelSetup(),
        else => stay(.{ .project_resolving = pick }, .none),
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

/// The call is refused, and the state does not change.
fn refuse(state: State, reason: Refusal) Transition {
    return stay(state, .{ .refuse = reason });
}

/// The setup ends, with its mark and its decision.
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

test "RunnerSetup.tla Check: an expired login is refused E6 and no prompt opens" {
    const t = step(initial, arrivalOf(.expired, .absent));
    try expectRefusal(t, .login_expired);
    try expectIdle(t.state, .none);
}

test "RunnerSetup.tla Check: a login the API rejects is refused E6" {
    const t = step(initial, arrivalOf(.rejected, .absent));
    try expectRefusal(t, .login_expired);
}

test "R4 before R5: with no remote, a sub-agent is refused E10 before the user is read" {
    const t = step(initial, .{ .arrival = .{ .caller = .sub_agent, .channel = .form, .login = .present, .config = .absent } });
    try expectRefusal(t, .sub_agent);
}

test "R4 before R5: with no remote, a call with no channel is refused E7 before the user is read" {
    const t = step(initial, .{ .arrival = .{ .caller = .main, .channel = .none, .login = .present, .config = .absent } });
    try expectRefusal(t, .no_channel);
}

test "R5: a remote needs the login's user, so an arrival without one asks for it" {
    const t = step(initial, .{ .arrival = .{ .caller = .main, .channel = .form, .login = .present, .config = .{ .remote = user_alice } } });
    try expectTag(Decision, .need_user, t.decision);
}

test "R5: a setup about to start asks for the login's user, then lists the teams" {
    const asked = step(initial, .{ .arrival = .{ .caller = .main, .channel = .form, .login = .present, .config = .absent } });
    try expectTag(Decision, .need_user, asked.decision);
    const started = step(asked.state, .{ .arrival = .{ .caller = .main, .channel = .form, .login = .{ .user = user_alice }, .config = .absent } });
    try expectTag(Decision, .rest, started.decision);
}

test "R5: a declined mark is refused without asking for the user" {
    const t = step(.{ .idle = .declined }, .{ .arrival = .{ .caller = .main, .channel = .form, .login = .present, .config = .absent } });
    try expectRefusal(t, .declined);
}

test "RunnerSetup.tla RemoteNeedsReady: a remote run needs the login that confirmed config.remote" {
    const ready = step(initial, arrivalOf(.{ .user = user_alice }, .{ .remote = user_alice }));
    try expectTag(Decision, .ready, ready.decision);

    const other = step(initial, arrivalOf(.{ .user = user_bob }, .{ .remote = user_alice }));
    try expectTag(Decision, .rest, other.decision);
    try expectTag(Rest, .list_teams, other.decision.rest);
}

test "RunnerSetup.tla NoWaitWithoutChannel: a sub-agent is refused E10 and never waits" {
    const sub = step(initial, .{ .arrival = .{
        .caller = .sub_agent,
        .channel = .form,
        .login = .{ .user = user_alice },
        .config = .absent,
    } });
    try expectRefusal(sub, .sub_agent);
    try expectIdle(sub.state, .none);
}

test "RunnerSetup.tla NoWaitWithoutChannel: a call with no prompt channel is refused E7, even while a setup runs" {
    const busy = step(initial, arrivalOf(.{ .user = user_alice }, .absent));
    const headless = step(busy.state, .{ .arrival = .{
        .caller = .main,
        .channel = .none,
        .login = .{ .user = user_bob },
        .config = .absent,
    } });
    try expectRefusal(headless, .no_channel);
    try expectTag(State, .teams_listing, headless.state);
}

test "RunnerSetup.tla SinglePrompt: a second call waits while P1 is open, and P1 and P2 never overlap" {
    const started = step(initial, arrivalOf(.{ .user = user_alice }, .absent));
    const at_p1 = step(started.state, .{ .teams_listed = .{ .teams = &two_teams, .now_ms = 0 } });
    try expectTag(Decision, .ask_team, at_p1.decision);

    const second = step(at_p1.state, arrivalOf(.{ .user = user_bob }, .absent));
    try expectTag(Decision, .wait, second.decision);

    const after_p1 = step(at_p1.state, .{ .answered = .{ .team_choice = team_two.id } });
    try expectTag(State, .projects_listing, after_p1.state);
    try expectTag(Decision, .rest, after_p1.decision);
}

test "RunnerSetup.tla NoPromptAfterDecline: after a decline at P2, the repeat in the same turn is refused without a prompt" {
    const declined_at_p2 = declinedAtProject();
    try expectIdle(declined_at_p2.state, .declined);

    const repeat = step(declined_at_p2.state, arrivalOf(.{ .user = user_alice }, .absent));
    try expectRefusal(repeat, .declined);
    try expectIdle(repeat.state, .declined);

    const next_turn = step(repeat.state, .new_turn);
    try expectIdle(next_turn.state, .none);
    const again = step(next_turn.state, arrivalOf(.{ .user = user_alice }, .absent));
    try expectTag(State, .teams_listing, again.state);
}

test "RunnerSetup.tla NoPromptAfterDecline: a decline at P1 sets the mark, so the repeat gets no prompt" {
    const started = step(initial, arrivalOf(.{ .user = user_alice }, .absent));
    const at_p1 = step(started.state, .{ .teams_listed = .{ .teams = &two_teams, .now_ms = 0 } });
    const declined_p1 = step(at_p1.state, .{ .answered = .dismissed });
    try expectRefusal(declined_p1, .declined);
    try expectIdle(declined_p1.state, .declined);

    const repeat = step(declined_p1.state, arrivalOf(.{ .user = user_alice }, .absent));
    try expectRefusal(repeat, .declined);
}

test "RunnerSetup.tla ConfigOnlyByUser: without a project accept, nothing is written" {
    const started = step(initial, arrivalOf(.{ .user = user_alice }, .absent));
    var t = step(started.state, .{ .teams_listed = .{ .teams = &two_teams, .now_ms = 0 } });
    t = step(t.state, .{ .answered = .{ .team_choice = team_one.id } });
    t = step(t.state, .{ .projects_listed = .{ .projects = &[_]vercel.Project{web}, .now_ms = 1 } });
    try expectTag(Decision, .ask_project, t.decision);
    t = step(t.state, .{ .answered = .dismissed });
    try expectRefusal(t, .declined);
    try expectTag(State, .idle, t.state);
}

test "RunnerSetup.tla WriteOnlyAfterProjectAccept: a team accept at P1 does not write; only a P2 accept does" {
    const started = step(initial, arrivalOf(.{ .user = user_alice }, .absent));
    const at_p1 = step(started.state, .{ .teams_listed = .{ .teams = &two_teams, .now_ms = 0 } });
    const after_team = step(at_p1.state, .{ .answered = .{ .team_choice = team_one.id } });
    try expectTag(Decision, .rest, after_team.decision);

    const listed = step(after_team.state, .{ .projects_listed = .{ .projects = &[_]vercel.Project{web}, .now_ms = 2 } });
    try expectTag(Decision, .ask_project, listed.decision);

    const written = step(listed.state, .{ .answered = .{ .project_choice = web.id } });
    try expectTag(Decision, .write, written.decision);
}

test "RunnerSetup.tla NoWriteAfterEarlyCancel: a setup canceled while its create step runs never writes" {
    const projects = [_]vercel.Project{web};
    const started = step(initial, arrivalOf(.{ .user = user_alice }, .absent));
    var t = step(started.state, .{ .teams_listed = .{ .teams = &[_]vercel.Team{team_one}, .now_ms = 0 } });
    t = step(t.state, .{ .projects_listed = .{ .projects = &projects, .now_ms = 1 } });
    t = step(t.state, .{ .answered = .project_create });
    try expectTag(State, .project_resolving, t.state);

    t = step(t.state, .owner_canceled);
    try expectTag(Decision, .canceled, t.decision);
    try expectIdle(t.state, .none);

    const late = step(t.state, .{ .project_resolved = sandbox });
    try expectTag(Decision, .none, late.decision);
}

test "RunnerSetup.tla NoWriteAfterEarlyCancel: a cancel during the write completes it, then the call ends canceled and does not run" {
    const chosen = step(projectPromptWithWeb().state, .{ .answered = .{ .project_choice = web.id } });
    try expectTag(Decision, .write, chosen.decision);

    const canceled_during = step(chosen.state, .owner_canceled);
    try expectTag(State, .writing_canceled, canceled_during.state);
    try expectTag(Decision, .none, canceled_during.decision);

    const done = step(canceled_during.state, .{ .write_done = .written });
    try expectTag(Decision, .canceled, done.decision);
    try expectIdle(done.state, .none);
}

test "RunnerSetup.tla NoPromptAfterCancel: a canceled call opens no prompt when its discovery answers late" {
    const started = step(initial, arrivalOf(.{ .user = user_alice }, .absent));
    const canceled = step(started.state, .owner_canceled);
    try expectTag(Decision, .canceled, canceled.decision);
    try expectIdle(canceled.state, .none);

    const late = step(canceled.state, .{ .teams_listed = .{ .teams = &two_teams, .now_ms = 0 } });
    try expectTag(Decision, .none, late.decision);
    try expectIdle(late.state, .none);
}

test "RunnerSetup.tla EventuallyEnds: a prompt with no answer ends at the limit with E15 and the mark" {
    const at_p1 = teamPromptAt(0);
    const before = step(at_p1.state, .{ .tick = question_limit_ms - 1 });
    try expectTag(Decision, .none, before.decision);
    try expectTag(State, .team_prompt, before.state);

    const at_limit = step(at_p1.state, .{ .tick = question_limit_ms });
    try expectRefusal(at_limit, .no_answer);
    try expectIdle(at_limit.state, .no_answer);

    const repeat = step(at_limit.state, arrivalOf(.{ .user = user_alice }, .absent));
    try expectRefusal(repeat, .no_answer);
}

test "U7: a cancel at P1 ends the call canceled with no mark, like a cancel in setup" {
    const canceled = step(teamPromptAt(0).state, .owner_canceled);
    try expectTag(Decision, .canceled, canceled.decision);
    try expectIdle(canceled.state, .none);
}

test "U5: a login with no team is refused E9 with teams: no team" {
    const started = step(initial, arrivalOf(.{ .user = user_alice }, .absent));
    const t = step(started.state, .{ .teams_listed = .{ .teams = &[_]vercel.Team{}, .now_ms = 0 } });
    try expectSetupFailed(t, step_teams, .no_team);
    try expectIdle(t.state, .none);
}

test "U5: one team has no P1, and the projects are listed next" {
    const started = step(initial, arrivalOf(.{ .user = user_alice }, .absent));
    const t = step(started.state, .{ .teams_listed = .{ .teams = &[_]vercel.Team{team_one}, .now_ms = 0 } });
    try expectTag(State, .projects_listing, t.state);
    switch (t.decision) {
        .rest => |rest| switch (rest) {
            .list_projects => |team| try std.testing.expectEqualStrings(team_one.id, team.id),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "U5: up to max_team_choices teams are listed; more than that asks for a slug" {
    const started = step(initial, arrivalOf(.{ .user = user_alice }, .absent));
    const listed = step(started.state, .{ .teams_listed = .{ .teams = &two_teams, .now_ms = 0 } });
    switch (listed.decision) {
        .ask_team => |choices| try expectTag(TeamChoices, .choose, choices),
        else => return error.TestUnexpectedResult,
    }

    var many: [max_team_choices + 1]vercel.Team = undefined;
    for (&many) |*team| team.* = team_one;
    const slug = step(started.state, .{ .teams_listed = .{ .teams = &many, .now_ms = 0 } });
    switch (slug.decision) {
        .ask_team => |choices| try expectTag(TeamChoices, .slug, choices),
        else => return error.TestUnexpectedResult,
    }
}

test "U5: a team slug is looked up, and a slug that is not found is E9 not_found" {
    const started = step(initial, arrivalOf(.{ .user = user_alice }, .absent));
    var many: [max_team_choices + 1]vercel.Team = undefined;
    for (&many) |*team| team.* = team_one;
    var t = step(started.state, .{ .teams_listed = .{ .teams = &many, .now_ms = 0 } });
    t = step(t.state, .{ .answered = .{ .team_slug = team_two.slug } });
    try expectTag(State, .team_slug_lookup, t.state);
    switch (t.decision) {
        .rest => |rest| switch (rest) {
            .team_by_slug => |slug| try std.testing.expectEqualStrings(team_two.slug, slug),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }

    const missing = step(t.state, .{ .rest_not_found = step_team });
    try expectSetupFailed(missing, step_team, .not_found);
    try expectIdle(missing.state, .none);
}

test "U5: an empty slug is refused E9 bad_answer, and a team not in the list is too" {
    const started = step(initial, arrivalOf(.{ .user = user_alice }, .absent));
    const at_p1 = step(started.state, .{ .teams_listed = .{ .teams = &two_teams, .now_ms = 0 } });
    const unknown = step(at_p1.state, .{ .answered = .{ .team_choice = "team_missing" } });
    try expectSetupFailed(unknown, step_team, .bad_answer);
    try expectIdle(unknown.state, .none);
}

test "U6: the create choice is offered only when fx-sandbox does not exist" {
    const with_sandbox = projectPromptFor(&[_]vercel.Project{ web, sandbox });
    try expectTag(Decision, .ask_project, with_sandbox.decision);
    try std.testing.expect(!with_sandbox.decision.ask_project.offer_create);

    const without = projectPromptFor(&[_]vercel.Project{web});
    try std.testing.expect(without.decision.ask_project.offer_create);
}

test "U6: a create answer with fx-sandbox already listed is refused E9 bad_answer" {
    const with_sandbox = projectPromptFor(&[_]vercel.Project{ web, sandbox });
    const t = step(with_sandbox.state, .{ .answered = .project_create });
    try expectSetupFailed(t, step_project, .bad_answer);
}

test "U6: another project is looked up by name; an empty name is refused, and a name not found is E9 not_found" {
    const at_p2 = projectPromptWithWeb();
    const empty = step(at_p2.state, .{ .answered = .{ .project_other = "" } });
    try expectSetupFailed(empty, step_project, .bad_answer);

    const looked_up = step(at_p2.state, .{ .answered = .{ .project_other = "my-app" } });
    try expectTag(Decision, .rest, looked_up.decision);
    const missing = step(looked_up.state, .{ .rest_not_found = step_project });
    try expectSetupFailed(missing, step_project, .not_found);
}

test "U7: a dismissed P2 form ends the setup with E8 and the mark" {
    const t = step(projectPromptWithWeb().state, .{ .answered = .dismissed });
    try expectRefusal(t, .declined);
    try expectIdle(t.state, .declined);
}

test "U9: a write that says written or kept is ready to run" {
    const chosen = step(projectPromptWithWeb().state, .{ .answered = .{ .project_choice = web.id } });
    const written = step(chosen.state, .{ .write_done = .written });
    try expectTag(Decision, .ready, written.decision);
    try expectIdle(written.state, .none);

    const kept = step(chosen.state, .{ .write_done = .kept });
    try expectTag(Decision, .ready, kept.decision);
}

test "U9: a config changed under the lock is E14, an invalid config is E4, and a failed write is E9" {
    const chosen = step(projectPromptWithWeb().state, .{ .answered = .{ .project_choice = web.id } });

    try expectRefusal(step(chosen.state, .{ .write_done = .config_changed }), .config_changed);
    try expectRefusal(step(chosen.state, .{ .write_done = .{ .invalid = "reason" } }), .config_invalid);
    try expectSetupFailed(step(chosen.state, .{ .write_done = .{ .failed = .write_failed } }), step_write, .write_failed);
}

test "U1/U7: a prompt that cannot be answered is E9 with no mark, and nothing is written" {
    const started = step(initial, arrivalOf(.{ .user = user_alice }, .absent));
    const at_p1 = step(started.state, .{ .teams_listed = .{ .teams = &two_teams, .now_ms = 0 } });
    try expectTag(Decision, .ask_team, at_p1.decision);

    const failed = step(at_p1.state, .prompt_failed);
    try expectSetupFailed(failed, step_team, .prompt_failed);
    try expectIdle(failed.state, .none);
}

test "U9: a lock that stays busy is E9 write: config lock busy, and a cancel while the lock is awaited ends canceled" {
    const chosen = step(projectPromptWithWeb().state, .{ .answered = .{ .project_choice = web.id } });
    try expectSetupFailed(step(chosen.state, .{ .write_done = .{ .failed = .write_lock_busy } }), step_write, .write_lock_busy);
    const canceled = step(chosen.state, .{ .write_done = .canceled });
    try expectTag(Decision, .canceled, canceled.decision);
}

test "U7: a REST failure before a prompt is E9 with no mark, and the next arrival starts again" {
    const started = step(initial, arrivalOf(.{ .user = user_alice }, .absent));
    const failed = step(started.state, .{ .rest_failed = .{ .step = step_teams, .reason = .timeout } });
    try expectSetupFailed(failed, step_teams, .api);
    try expectIdle(failed.state, .none);

    const again = step(failed.state, arrivalOf(.{ .user = user_alice }, .absent));
    try expectTag(State, .teams_listing, again.state);
}

test "U7: a REST failure after a P2 accept is E9 with no mark, and nothing is written" {
    const creating = step(projectPromptWithWeb().state, .{ .answered = .project_create });
    const failed = step(creating.state, .{ .rest_failed = .{ .step = step_project, .reason = .{ .status = 500 } } });
    try expectSetupFailed(failed, step_project, .api);
    try expectIdle(failed.state, .none);
}

test "U7: a rejected login during a REST step is E6" {
    const started = step(initial, arrivalOf(.{ .user = user_alice }, .absent));
    try expectRefusal(step(started.state, .rest_rejected), .login_expired);
}

test "U3: a waiting call is ready once the setup it waited for has written the destination" {
    const first = step(initial, arrivalOf(.{ .user = user_alice }, .absent));
    const second = step(first.state, arrivalOf(.{ .user = user_alice }, .absent));
    try expectTag(Decision, .wait, second.decision);

    const listed = step(first.state, .{ .teams_listed = .{ .teams = &[_]vercel.Team{team_one}, .now_ms = 0 } });
    const with_project = step(listed.state, .{ .projects_listed = .{ .projects = &[_]vercel.Project{web}, .now_ms = 1 } });
    const chosen = step(with_project.state, .{ .answered = .{ .project_choice = web.id } });
    const done = step(chosen.state, .{ .write_done = .written });

    const retried = step(done.state, arrivalOf(.{ .user = user_alice }, .{ .remote = user_alice }));
    try expectTag(Decision, .ready, retried.decision);
}

test "U3: a waiting call that is canceled is canceled, and the setup it waited for is unchanged" {
    const first = step(initial, arrivalOf(.{ .user = user_alice }, .absent));
    const second = step(first.state, arrivalOf(.{ .user = user_bob }, .absent));
    const canceled = step(second.state, .waiter_canceled);
    try expectTag(Decision, .canceled, canceled.decision);
    try expectTag(State, .teams_listing, canceled.state);
}

const user_alice = "user_alice";
const user_bob = "user_bob";
const team_one = vercel.Team{ .id = "team_1", .slug = "one", .name = "One" };
const team_two = vercel.Team{ .id = "team_2", .slug = "two", .name = "Two" };
const two_teams = [_]vercel.Team{ team_one, team_two };
const web = vercel.Project{ .id = "prj_web", .name = "web" };
const sandbox = vercel.Project{ .id = "prj_sandbox", .name = "fx-sandbox" };

fn arrivalOf(login: Login, config: Config) Event {
    return .{ .arrival = .{ .caller = .main, .channel = .form, .login = login, .config = config } };
}

/// P1 is open at `now_ms`, with two teams to choose from.
fn teamPromptAt(now_ms: i64) Transition {
    const started = step(initial, arrivalOf(.{ .user = user_alice }, .absent));
    return step(started.state, .{ .teams_listed = .{ .teams = &two_teams, .now_ms = now_ms } });
}

/// One team, and P2 is open with the listed `projects`.
fn projectPromptFor(projects: []const vercel.Project) Transition {
    const started = step(initial, arrivalOf(.{ .user = user_alice }, .absent));
    const listed = step(started.state, .{ .teams_listed = .{ .teams = &[_]vercel.Team{team_one}, .now_ms = 0 } });
    return step(listed.state, .{ .projects_listed = .{ .projects = projects, .now_ms = 1 } });
}

fn projectPromptWithWeb() Transition {
    return projectPromptFor(&[_]vercel.Project{web});
}

/// The P2 prompt is answered "dismissed", which sets the mark.
fn declinedAtProject() Transition {
    return step(projectPromptWithWeb().state, .{ .answered = .dismissed });
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
