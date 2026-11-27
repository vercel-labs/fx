//! The effects of one remote setup, for one call (spec U1 to U12, R5). The pure
//! step in `setup.zig` decides; this file runs what it asks for: the login
//! check, REST steps, prompts, the locked write and the single flight.
//! `ensureReady` returns ready, canceled, or a refusal with its exact E text.
//!
//! The slot's mutex is never held across a REST call, a prompt or the write.
//! Those run between `Slot.begin` and `Slot.end`, which only the flight's owner
//! calls. Each slot call takes the mutex only to read or change its state.

const std = @import("std");
const vercel = @import("vercel/vercel.zig");
const setup = @import("setup.zig");
const remote_slot = @import("remote_slot.zig");
const config = @import("config.zig");
const config_write = @import("config_write.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const elicitation = @import("../mcp/elicitation.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");

const testing = std.testing;
const test_server = @import("vercel/test_server.zig");

const TokenHash = remote_slot.TokenHash;

/// A host prompt is not an MCP request, so it names no server and no tool.
const host_wire: elicitation.Wire = .modern_mcp;
const host_operation: elicitation.Operation = .{ .tools_call = "" };

const user_step = "user";
const team_key = "team";
const project_key = "project";
const prompt_team_message = "Which Vercel team should remote commands use?";
const create_choice = "__create__";
const other_choice = "__other__";
const create_title = "Create a new project named fx-sandbox";
const other_title = "Another project (type its name below)";

const e4_prefix = "fx did not run this command: ";
const e4_suffix = " Fix ~/.fx/sandbox/config.json, or turn off experimental.sandbox_execution.";
pub const e5_text = "fx did not run this command: no Vercel login. Run `vercel login`, then try again.";
pub const e6_text = "fx did not run this command: the Vercel login has expired or was rejected. Run `vercel whoami` to refresh it, or `vercel login`, then try again.";
const e7_text = "fx did not run this command: remote is not set up, and fx cannot ask the user here. Ask again in an interactive fx session.";
const e8_text = "fx did not run this command: the user did not set up remote.";
const e9_prefix = "fx did not run this command: remote setup failed: ";
const e10_text = "fx did not run this command: remote is not set up. Set it up from the main conversation first.";
const e14_text = "fx did not run this command: ~/.fx/sandbox/config.json changed since fx started. Restart fx to use it.";
const e15_text = "fx did not run this command: the remote setup question was not answered in 15 minutes.";

/// The clock, injected so tests control it. `awake_ms` is the clock the
/// responder compares prompt deadlines with (U7); `unix_s` sets `confirmed_at`.
pub const Clock = struct {
    context: ?*anyopaque = null,
    awake_ms: *const fn (context: ?*anyopaque) i64 = realAwakeMs,
    unix_s: *const fn (context: ?*anyopaque) i64 = realUnixS,

    fn awakeMs(self: Clock) i64 {
        return self.awake_ms(self.context);
    }

    pub fn unixS(self: Clock) i64 {
        return self.unix_s(self.context);
    }
};

fn realAwakeMs(context: ?*anyopaque) i64 {
    _ = context;
    return io_mod.awakeMilliTimestamp();
}

fn realUnixS(context: ?*anyopaque) i64 {
    _ = context;
    return @divFloor(io_mod.milliTimestamp(), 1000);
}

/// Trace lines go to the debug trace. A line names the step and the outcome only (U12).
pub const debug_trace_sink: vercel.Trace = .{ .context = null, .line = debugLine };

fn debugLine(context: ?*anyopaque, text: []const u8) void {
    _ = context;
    debug_trace.logf("remote setup", "{s}", .{text});
}

/// The user check (R5) keeps the login it passed in the remote slot (R145), never the token.
/// This view is the `user_check.store` call that the shell tests seed, so they keep their shape.
pub const UserCheck = struct {
    slot: *remote_slot.Slot,

    /// Keeps `user_id` as the checked user of `hash`. `alloc` is unused: the slot owns its copies.
    pub fn store(self: *UserCheck, alloc: std.mem.Allocator, hash: TokenHash, user_id: []const u8) std.mem.Allocator.Error!void {
        _ = alloc;
        return self.slot.storeChecked(hash, user_id);
    }
};

/// What is per process: the slot, the login sources, the API base, the trace
/// sink, the clock and the config fingerprint that load computed (U9).
pub const Host = struct {
    alloc: std.mem.Allocator,
    slot: *remote_slot.Slot,
    fx_home: []const u8,
    home: []const u8,
    loaded: config.Fingerprint,
    base: vercel.BaseUrl,
    env: vercel.Env,
    os: std.Target.Os.Tag,
    files: vercel.Files,
    trace: vercel.Trace,
    clock: Clock = .{},
    user_check: UserCheck,
};

/// One call that may need setup. The shell tool builds it from the tool context.
pub const Call = struct {
    /// Owns this call's text and its destination. The caller frees it after the result.
    arena: std.mem.Allocator,
    /// The session the decline mark belongs to. Null: the call never reads or writes a mark (U4).
    session_key: ?[]const u8,
    /// The worker's active turn id (U4). Zero means no active turn.
    turn_id: u64,
    /// False for a sub-agent call (U2), which is refused with E10.
    setup_allowed: bool,
    /// The host prompt responder. Setup needs one with form capability (U1).
    responder: ?tool_mcp_runtime.InputResponder,
    cancel: *std.atomic.Value(bool),
};

/// The call for one tool call. A call from a sub-agent (`remote_setup_allowed`
/// false, U2) has no session key, so it reads and writes no decline mark (U4).
pub fn callFor(
    arena: std.mem.Allocator,
    remote_setup_allowed: bool,
    session_key: ?[]const u8,
    turn_id: u64,
    responder: ?tool_mcp_runtime.InputResponder,
    cancel: *std.atomic.Value(bool),
) Call {
    return .{
        .arena = arena,
        .session_key = if (remote_setup_allowed) session_key else null,
        .turn_id = turn_id,
        .setup_allowed = remote_setup_allowed,
        .responder = responder,
        .cancel = cancel,
    };
}

/// The outcome of `ensureReady`. A refusal carries its exact E text in the call's arena.
pub const Result = union(enum) {
    ready: remote_slot.Destination,
    canceled,
    refused: []const u8,
};

/// The login as this process reads it without the network (R2, R3): its state
/// for the step, and the token that REST calls use.
const HostLogin = struct {
    state: setup.Login,
    token: vercel.Token,
};

/// The login's user, read through the cache or one `GET /v2/user` (R5). `done`
/// is a failed or canceled read.
const Resolved = union(enum) {
    login: setup.Login,
    done: Result,
};

/// One arrival. When the step needs the login's user, that is read and the
/// arrival is sent again.
const Arrived = union(enum) {
    transition: setup.Transition,
    done: Result,
};

const Reply = union(enum) {
    answered: []const u8,
    timed_out,
    failed,
};

const Parsed = union(enum) {
    accept: std.json.ObjectMap,
    dismissed,
    invalid,
};

/// Runs one call's part of remote setup. It returns when the destination is
/// ready, the call is canceled, or it is refused. A call that must wait for
/// another setup waits, then checks again (U3).
pub fn ensureReady(host: *Host, call: Call) std.mem.Allocator.Error!Result {
    while (true) {
        var login = try localLogin(host, call);
        const first = switch (try arriveResolved(host, call, &login)) {
            .transition => |found| found,
            .done => |result| return result,
        };
        if (!needsFlight(first.decision)) return finish(host, call, first);
        switch (host.slot.begin()) {
            .wait => switch (host.slot.wait(call.cancel)) {
                .canceled => return .canceled,
                .finished => continue,
            },
            .owner => {
                defer host.slot.end();
                // Config may have changed between the first arrival and the flight.
                const again = switch (try arriveResolved(host, call, &login)) {
                    .transition => |found| found,
                    .done => |result| return result,
                };
                if (!needsFlight(again.decision)) return finish(host, call, again);
                return runOwner(host, call, login.token, again);
            },
        }
    }
}

fn needsFlight(decision: setup.Decision) bool {
    return switch (decision) {
        .rest, .ask_team, .ask_project, .write => true,
        .none, .wait, .ready, .need_user, .refuse, .canceled => false,
    };
}

/// The login as this process reads it, with no network call (R2, R3).
fn localLogin(host: *Host, call: Call) std.mem.Allocator.Error!HostLogin {
    const auth = try vercel.load(call.arena, host.env, host.os, host.files, host.trace, host.clock.unixS());
    return switch (auth) {
        .missing => .{ .state = .none, .token = unused_token },
        .expired => .{ .state = .expired, .token = unused_token },
        .token => |token| .{ .state = .present, .token = token },
    };
}

/// The login's user (R5): the cached id for this token, else one `GET /v2/user`.
/// The read runs at most once per process per token. A rejected login is `rejected`.
fn resolveUser(host: *Host, call: Call, token: vercel.Token) std.mem.Allocator.Error!Resolved {
    const hash = tokenHash(token);
    if (try host.slot.checkedUser(hash, call.arena)) |user_id| {
        return .{ .login = .{ .user = user_id } };
    }
    const outcome = try vercel.getUser(call.arena, linkFor(host, call, token));
    switch (outcome) {
        .ok => |user| {
            try host.slot.storeChecked(hash, user.id);
            return .{ .login = .{ .user = user.id } };
        },
        .rejected => return .{ .login = .rejected },
        .not_found => return .{ .done = try apiFailure(call.arena, .{ .step = user_step, .reason = .bad_reply }) },
        .canceled => return .{ .done = .canceled },
        .failed => |failure| return .{ .done = try apiFailure(call.arena, failure) },
    }
}

/// One arrival. When the step needs the login's user, that is read, the login
/// is updated, and the arrival is sent again.
fn arriveResolved(host: *Host, call: Call, login: *HostLogin) std.mem.Allocator.Error!Arrived {
    const first = try arrive(host, call, login.state);
    if (std.meta.activeTag(first.decision) != .need_user) return .{ .transition = first };
    switch (try resolveUser(host, call, login.token)) {
        .login => |state| login.state = state,
        .done => |result| return .{ .done = result },
    }
    return .{ .transition = try arrive(host, call, login.state) };
}

const unused_token: vercel.Token = .{ .value = "" };

fn tokenHash(token: vercel.Token) TokenHash {
    var digest: TokenHash = undefined;
    std.crypto.hash.sha2.Sha256.hash(token.bytes(), &digest, .{});
    return digest;
}

fn linkFor(host: *const Host, call: Call, token: vercel.Token) vercel.Link {
    return .{ .base = host.base, .token = token, .cancel_flag = call.cancel, .trace = host.trace };
}

/// One arrival: the step's first event for this call, read against the slot now.
fn arrive(host: *Host, call: Call, login: setup.Login) std.mem.Allocator.Error!setup.Transition {
    const config_state = try configOf(host, call.arena);
    const mark = host.slot.markFor(call.session_key, call.turn_id);
    return setup.step(.{ .idle = mark }, .{ .arrival = .{
        .caller = if (call.setup_allowed) .main else .sub_agent,
        .channel = channelOf(call),
        .login = login,
        .config = config_state,
    } });
}

fn configOf(host: *Host, arena: std.mem.Allocator) std.mem.Allocator.Error!setup.Config {
    const destination = (try host.slot.currentDestination(arena)) orelse return .absent;
    return .{ .remote = destination.user_id };
}

fn channelOf(call: Call) setup.Channel {
    const responder = call.responder orelse return .none;
    return if (responder.capabilities.form) .form else .none;
}

/// The flight's owner runs the effects, one event at a time, until the step ends the call.
fn runOwner(host: *Host, call: Call, token: vercel.Token, first: setup.Transition) std.mem.Allocator.Error!Result {
    var transition = first;
    while (true) {
        trace(host, "setup decision={s}", .{@tagName(transition.decision)});
        switch (transition.decision) {
            .none, .wait, .ready, .need_user, .refuse, .canceled => return finish(host, call, transition),
            .write => |destination| transition = try writeTransition(host, call, transition.state, destination),
            .rest => |rest| {
                const event = if (cancelled(call)) setup.Event.owner_canceled else try restEvent(host, call, token, rest);
                transition = setup.step(transition.state, event);
            },
            .ask_team => |choices| {
                const event = if (cancelled(call)) setup.Event.owner_canceled else try askTeam(call, transition.state, choices);
                transition = setup.step(transition.state, event);
            },
            .ask_project => |ask| {
                const event = if (cancelled(call)) setup.Event.owner_canceled else try askProject(call, transition.state, ask);
                transition = setup.step(transition.state, event);
            },
        }
    }
}

fn cancelled(call: Call) bool {
    return call.cancel.load(.acquire);
}

/// Ends a call that does not need the flight, or that the flight has finished.
/// The mark the step left is kept first, so every waiter sees it.
fn finish(host: *Host, call: Call, transition: setup.Transition) std.mem.Allocator.Error!Result {
    try recordMark(host, call, transition.state);
    return switch (transition.decision) {
        // A ready decision means config has a remote, and the slot holds it.
        .ready => .{ .ready = (try host.slot.currentDestination(call.arena)) orelse unreachable },
        .refuse => |refusal| .{ .refused = try refusalText(call.arena, refusal) },
        .canceled => .canceled,
        // Only the flight's loop reaches these decisions, and it never finishes with them.
        .none, .wait, .need_user, .rest, .ask_team, .ask_project, .write => unreachable,
    };
}

/// Keeps the mark that the step left in the idle state, for this session and turn (U4).
fn recordMark(host: *Host, call: Call, state: setup.State) std.mem.Allocator.Error!void {
    const mark = switch (state) {
        .idle => |kept| kept,
        else => return,
    };
    if (mark == .none) return;
    host.slot.recordMark(call.session_key, call.turn_id, mark) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // A turn with no id cannot hold a mark. The refusal still stands.
        error.NoActiveTurn => trace(host, "setup mark not kept: no active turn", .{}),
    };
}

/// The locked write (U9). The write is not interrupted by a cancel. A cancel
/// that arrives meanwhile ends the call canceled after it (U7).
fn writeTransition(host: *Host, call: Call, state: setup.State, destination: setup.Destination) std.mem.Allocator.Error!setup.Transition {
    const result = try lockedWrite(host, call, destination);
    var current = state;
    if (cancelled(call)) current = setup.step(current, .owner_canceled).state;
    return setup.step(current, .{ .write_done = result });
}

fn lockedWrite(host: *Host, call: Call, destination: setup.Destination) std.mem.Allocator.Error!setup.WriteResult {
    const loaded_remote = try host.slot.currentDestination(call.arena);
    const result = config_write.writeRemote(
        call.arena,
        .{ .fx_home = host.fx_home, .home = host.home },
        host.loaded,
        loaded_remote,
        destination,
        call.cancel,
        host.clock.unixS(),
    );
    switch (result) {
        .written, .kept => try host.slot.setDestination(.{
            .team_id = destination.team.id,
            .team_slug = destination.team.slug,
            .project_id = destination.project.id,
            .project_name = destination.project.name,
            .user_id = destination.user_id,
        }),
        .config_changed, .invalid, .failed, .canceled => {},
    }
    return result;
}

/// U6: the first page holds only the newest projects, so an `fx-sandbox` past it is found by
/// name. A 200 lists it as existing, a 404 leaves the list as it is, and any other failure is
/// the list step's failure (E9).
fn withSandboxProject(
    arena: std.mem.Allocator,
    link: vercel.Link,
    team_id: []const u8,
    listed: []const vercel.Project,
) std.mem.Allocator.Error!vercel.Outcome([]const vercel.Project) {
    if (setup.hasProjectNamed(listed, vercel.sandbox_project_name)) return .{ .ok = listed };
    return switch (try vercel.getProjectByName(arena, link, team_id, vercel.sandbox_project_name)) {
        .ok => |project| {
            const all = try arena.alloc(vercel.Project, listed.len + 1);
            @memcpy(all[0..listed.len], listed);
            all[listed.len] = project;
            return .{ .ok = all };
        },
        .rejected => .rejected,
        .not_found => .{ .ok = listed },
        .canceled => .canceled,
        .failed => |failure| .{ .failed = failure },
    };
}

fn restEvent(host: *Host, call: Call, token: vercel.Token, rest: setup.Rest) std.mem.Allocator.Error!setup.Event {
    const link = linkFor(host, call, token);
    const now_ms = host.clock.awakeMs();
    switch (rest) {
        .list_teams => return switch (try vercel.listTeams(call.arena, link)) {
            .ok => |teams| .{ .teams_listed = .{ .teams = teams, .now_ms = now_ms } },
            .rejected => .rest_rejected,
            .not_found => .{ .rest_not_found = setup.step_teams },
            .canceled => .owner_canceled,
            .failed => |failure| .{ .rest_failed = failure },
        },
        .team_by_slug => |slug| return switch (try vercel.getTeamBySlug(call.arena, link, slug)) {
            .ok => |team| .{ .team_resolved = team },
            .rejected => .rest_rejected,
            .not_found => .{ .rest_not_found = setup.step_team },
            .canceled => .owner_canceled,
            .failed => |failure| .{ .rest_failed = failure },
        },
        .list_projects => |team| return switch (try vercel.listProjects(call.arena, link, team.id)) {
            .ok => |projects| switch (try withSandboxProject(call.arena, link, team.id, projects)) {
                .ok => |listed| .{ .projects_listed = .{ .projects = listed, .now_ms = now_ms } },
                .rejected => .rest_rejected,
                .not_found => .{ .rest_not_found = setup.step_project },
                .canceled => .owner_canceled,
                .failed => |failure| .{ .rest_failed = failure },
            },
            .rejected => .rest_rejected,
            .not_found => .{ .rest_not_found = setup.step_project },
            .canceled => .owner_canceled,
            .failed => |failure| .{ .rest_failed = failure },
        },
        .create_project => |team| return switch (try vercel.createProject(call.arena, link, team.id)) {
            .ok => |project| .{ .project_resolved = project },
            .rejected => .rest_rejected,
            .not_found => .{ .rest_not_found = setup.step_project },
            .canceled => .owner_canceled,
            .failed => |failure| .{ .rest_failed = failure },
        },
        .project_by_name => |lookup| return switch (try vercel.getProjectByName(call.arena, link, lookup.team.id, lookup.name)) {
            .ok => |project| .{ .project_resolved = project },
            .rejected => .rest_rejected,
            .not_found => .{ .rest_not_found = setup.step_project },
            .canceled => .owner_canceled,
            .failed => |failure| .{ .rest_failed = failure },
        },
    }
}

/// P1 (U5): a team chosen from the list, or a team slug typed in.
fn askTeam(call: Call, state: setup.State, choices: setup.TeamChoices) std.mem.Allocator.Error!setup.Event {
    const asked_at_ms = switch (state) {
        .team_prompt => |open| open.asked_at_ms,
        else => return .prompt_failed,
    };
    const schema = try teamSchema(call.arena, choices);
    const reply = try prompt(call, team_key, prompt_team_message, schema, asked_at_ms);
    return promptEvent(call, reply, asked_at_ms, teamAnswer);
}

/// P2 (U6): a project, a new fx-sandbox project, or another name typed in.
fn askProject(call: Call, state: setup.State, ask: setup.ProjectAsk) std.mem.Allocator.Error!setup.Event {
    const asked_at_ms = switch (state) {
        .project_prompt => |open| open.asked_at_ms,
        else => return .prompt_failed,
    };
    const message = try call.arena.print("Pick a project in {f}. fx will copy this repository's files to a sandbox in the project you pick, for remote commands.", .{text_utils.terminalSafe(ask.team.slug)});
    const schema = try projectSchema(call.arena, ask.projects, ask.offer_create);
    const reply = try prompt(call, project_key, message, schema, asked_at_ms);
    return promptEvent(call, reply, asked_at_ms, projectAnswer);
}

fn promptEvent(
    call: Call,
    reply: Reply,
    asked_at_ms: i64,
    comptime answerOf: fn (Parsed) setup.Answer,
) std.mem.Allocator.Error!setup.Event {
    if (cancelled(call)) return .owner_canceled;
    return switch (reply) {
        .answered => |bytes| .{ .answered = answerOf(try parseReply(call.arena, bytes)) },
        .timed_out => .{ .tick = asked_at_ms + setup.question_limit_ms },
        .failed => .prompt_failed,
    };
}

/// Opens one host prompt through the responder (U11). The origin is host-kind,
/// and its deadline is the step's limit on the awake clock.
fn prompt(call: Call, key: []const u8, message: []const u8, schema: std.json.Value, asked_at_ms: i64) std.mem.Allocator.Error!Reply {
    const responder = call.responder orelse return .failed;
    const params = try objectOf(call.arena, &.{
        .{ .key = "message", .value = str(message) },
        .{ .key = "requestedSchema", .value = schema },
    });
    const request = try objectOf(call.arena, &.{
        .{ .key = "method", .value = str("elicitation/create") },
        .{ .key = "params", .value = params },
    });
    const requests = try objectOf(call.arena, &.{.{ .key = key, .value = request }});
    const input = std.json.Stringify.valueAlloc(call.arena, requests, .{}) catch return error.OutOfMemory;
    const origin: tool_mcp_runtime.InputOrigin = .{
        .wire = host_wire,
        .kind = .host,
        .server_name = "",
        .operation = host_operation,
        .connection_generation = 0,
        .client_generation = 0,
        .catalog_generation = 0,
        .request_generation = 0,
        .auth_generation = 0,
        .deadline_ms = asked_at_ms + setup.question_limit_ms,
        .lifecycle_cancel_flag = call.cancel,
    };
    const answer = responder.callback(responder.context, call.arena, origin, .{ .input_requests_json = input }) catch |err| return switch (err) {
        error.McpInputTimedOut => .timed_out,
        else => .failed,
    };
    return .{ .answered = try entryFor(call.arena, key, answer) };
}

/// The responder answers with one object keyed by the request key, the shape
/// the TUI, `fx ask` and ACP all write. This returns the entry for `key`, or
/// `{}` when there is none, which `parseReply` refuses.
fn entryFor(arena: std.mem.Allocator, key: []const u8, answer: []const u8) std.mem.Allocator.Error![]const u8 {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, answer, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return "{}",
    };
    const object = switch (root) {
        .object => |object| object,
        else => return "{}",
    };
    const entry = object.get(key) orelse return "{}";
    return std.json.Stringify.valueAlloc(arena, entry, .{}) catch return error.OutOfMemory;
}

/// A reply is `accept` with its content, `decline`, or `cancel` (MCP elicitation).
/// Anything else is an invalid answer, which the step refuses.
fn parseReply(arena: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!Parsed {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .invalid,
    };
    const fields = switch (root) {
        .object => |object| object,
        else => return .invalid,
    };
    const action = switch (fields.get("action") orelse return .invalid) {
        .string => |text| text,
        else => return .invalid,
    };
    if (std.mem.eql(u8, action, "decline") or std.mem.eql(u8, action, "cancel")) return .dismissed;
    if (!std.mem.eql(u8, action, "accept")) return .invalid;
    const content = switch (fields.get("content") orelse return .invalid) {
        .object => |object| object,
        else => return .invalid,
    };
    return .{ .accept = content };
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn teamAnswer(parsed: Parsed) setup.Answer {
    const object = switch (parsed) {
        .dismissed => return .dismissed,
        .invalid => return .{ .team_choice = "" },
        .accept => |found| found,
    };
    if (stringField(object, "team")) |id| return .{ .team_choice = id };
    if (stringField(object, "team_slug")) |slug| return .{ .team_slug = slug };
    return .{ .team_choice = "" };
}

fn projectAnswer(parsed: Parsed) setup.Answer {
    const object = switch (parsed) {
        .dismissed => return .dismissed,
        .invalid => return .{ .project_choice = "" },
        .accept => |found| found,
    };
    const id = stringField(object, "project") orelse return .{ .project_choice = "" };
    if (std.mem.eql(u8, id, create_choice)) {
        traceDroppedOtherName(object, "the create choice was picked");
        return .project_create;
    }
    if (std.mem.eql(u8, id, other_choice)) return .{ .project_other = stringField(object, "other_project") orelse "" };
    traceDroppedOtherName(object, "a listed project was picked");
    return .{ .project_choice = id };
}

/// A typed name that comes with a listed project or the create choice is dropped: the
/// form asks the name only for another project, and an ACP editor may still send it.
/// The trace names the size and the reason, never the text.
fn traceDroppedOtherName(object: std.json.ObjectMap, reason: []const u8) void {
    const typed = stringField(object, "other_project") orelse return;
    if (typed.len == 0) return;
    debug_trace.logf("remote setup", "dropped a typed other project name of {d} bytes: {s}", .{ typed.len, reason });
}

const Field = struct {
    key: []const u8,
    value: std.json.Value,
};

fn str(value: []const u8) std.json.Value {
    return .{ .string = value };
}

fn objectOf(arena: std.mem.Allocator, fields: []const Field) std.mem.Allocator.Error!std.json.Value {
    var object: std.json.ObjectMap = .empty;
    for (fields) |field| try object.put(arena, field.key, field.value);
    return .{ .object = object };
}

fn arrayOf(arena: std.mem.Allocator, items: []const std.json.Value) std.mem.Allocator.Error!std.json.Value {
    var array = std.json.Array.init(arena);
    try array.appendSlice(items);
    return .{ .array = array };
}

fn choice(arena: std.mem.Allocator, value: []const u8, title: []const u8) std.mem.Allocator.Error!std.json.Value {
    return objectOf(arena, &.{
        .{ .key = "const", .value = str(value) },
        .{ .key = "title", .value = str(title) },
    });
}

fn teamSchema(arena: std.mem.Allocator, choices: setup.TeamChoices) std.mem.Allocator.Error!std.json.Value {
    switch (choices) {
        .slug => return objectOf(arena, &.{
            .{ .key = "type", .value = str("object") },
            .{ .key = "required", .value = try arrayOf(arena, &.{str("team_slug")}) },
            .{ .key = "properties", .value = try objectOf(arena, &.{.{
                .key = "team_slug",
                .value = try objectOf(arena, &.{
                    .{ .key = "type", .value = str("string") },
                    .{ .key = "title", .value = str("Team slug") },
                }),
            }}) },
        }),
        .choose => |teams| {
            var options = std.json.Array.init(arena);
            for (teams) |team| {
                const title = try arena.print("{f} ({f})", .{ text_utils.terminalSafe(team.name), text_utils.terminalSafe(team.slug) });
                try options.append(try choice(arena, team.id, title));
            }
            return objectOf(arena, &.{
                .{ .key = "type", .value = str("object") },
                .{ .key = "required", .value = try arrayOf(arena, &.{str("team")}) },
                .{ .key = "properties", .value = try objectOf(arena, &.{.{
                    .key = "team",
                    .value = try objectOf(arena, &.{
                        .{ .key = "type", .value = str("string") },
                        .{ .key = "oneOf", .value = .{ .array = options } },
                    }),
                }}) },
            });
        },
    }
}

fn projectSchema(arena: std.mem.Allocator, projects: []const vercel.Project, offer_create: bool) std.mem.Allocator.Error!std.json.Value {
    var options = std.json.Array.init(arena);
    for (projects) |project| {
        const title = try arena.print("{f}", .{text_utils.terminalSafe(project.name)});
        try options.append(try choice(arena, project.id, title));
    }
    if (offer_create) try options.append(try choice(arena, create_choice, create_title));
    try options.append(try choice(arena, other_choice, other_title));
    return objectOf(arena, &.{
        .{ .key = "type", .value = str("object") },
        .{ .key = "required", .value = try arrayOf(arena, &.{str("project")}) },
        .{ .key = "properties", .value = try objectOf(arena, &.{
            .{ .key = "project", .value = try objectOf(arena, &.{
                .{ .key = "type", .value = str("string") },
                .{ .key = "oneOf", .value = .{ .array = options } },
            }) },
            .{ .key = "other_project", .value = try objectOf(arena, &.{
                .{ .key = "type", .value = str("string") },
                .{ .key = "title", .value = str("Project name, for Another project") },
                .{ .key = elicitation.shown_when_key, .value = try objectOf(arena, &.{
                    .{ .key = "project", .value = str(other_choice) },
                }) },
            }) },
        }) },
    });
}

/// The E text for a refusal, in `arena`. E4 wraps the text the config write gave.
fn refusalText(arena: std.mem.Allocator, refusal: setup.Refusal) std.mem.Allocator.Error![]const u8 {
    return switch (refusal) {
        .no_login => e5_text,
        .login_expired => e6_text,
        .sub_agent => e10_text,
        .no_channel => e7_text,
        .declined => e8_text,
        .no_answer => e15_text,
        .config_changed => e14_text,
        .config_invalid => |text| arena.print("{s}{s}{s}", .{ e4_prefix, text, e4_suffix }),
        .setup_failed => |failure| failureText(arena, failure),
    };
}

/// E9: `remote setup failed: {step}: {reason}`. An API failure uses `api.describe`.
fn failureText(arena: std.mem.Allocator, failure: setup.StepFailure) std.mem.Allocator.Error![]const u8 {
    var buffer: [256]u8 = undefined;
    const detail: []const u8 = switch (failure.reason) {
        .api => |reason| vercel.describe(&buffer, .{ .step = failure.step, .reason = reason }),
        .not_found => try arena.print("{s}: not found", .{failure.step}),
        .no_team => try arena.print("{s}: the login has no team", .{failure.step}),
        .bad_answer => try arena.print("{s}: the answer did not fit the question", .{failure.step}),
        .write_failed => try arena.print("{s}: the config could not be written", .{failure.step}),
        .write_lock_busy => try arena.print("{s}: config lock busy", .{failure.step}),
        .prompt_failed => try arena.print("{s}: the question could not be shown or answered", .{failure.step}),
    };
    return arena.print("{s}{s}", .{ e9_prefix, detail });
}

fn failedResult(arena: std.mem.Allocator, failure: setup.StepFailure) std.mem.Allocator.Error!Result {
    return .{ .refused = try refusalText(arena, .{ .setup_failed = failure }) };
}

fn apiFailure(arena: std.mem.Allocator, failure: vercel.Failure) std.mem.Allocator.Error!Result {
    return failedResult(arena, .{ .step = failure.step, .reason = .{ .api = failure.reason } });
}

fn trace(host: *const Host, comptime format: []const u8, args: anytype) void {
    var buffer: [256]u8 = undefined;
    const line = std.mem.print(&buffer, format, args) catch return;
    host.trace.write(line);
}

// Tests. Each runs `ensureReady` against fake replies, a scripted responder,
// and a temp home for the config file.

const test_token = "fx-test-token";
const test_home = "/home/fx-test";
const test_unix_s: i64 = 1_800_000_000;
const test_awake_ms: i64 = 1_000_000;

fn fakeAwake(context: ?*anyopaque) i64 {
    _ = context;
    return test_awake_ms;
}

fn fakeUnix(context: ?*anyopaque) i64 {
    _ = context;
    return test_unix_s;
}

const fake_clock: Clock = .{ .awake_ms = fakeAwake, .unix_s = fakeUnix };

const rule_config = "{\"rules\": [{\"command\": \"zig build*\", \"runner\": \"remote\"}]}";

const user_reply: test_server.Reply = .{ .body = "{\"user\":{\"id\":\"usr_1\"}}" };
const teams_one_reply: test_server.Reply = .{
    .body = "{\"teams\":[{\"id\":\"team_1\",\"slug\":\"acme\",\"name\":\"Acme\"}],\"pagination\":{\"next\":null}}",
};
const teams_two_reply: test_server.Reply = .{
    .body = "{\"teams\":[{\"id\":\"team_1\",\"slug\":\"acme\",\"name\":\"Acme\"},{\"id\":\"team_2\",\"slug\":\"other\",\"name\":\"Other\"}],\"pagination\":{\"next\":null}}",
};
const teams_evil_reply: test_server.Reply = .{
    .body = "{\"teams\":[{\"id\":\"team_1\",\"slug\":\"acme\",\"name\":\"evil\\u001b[2Jteam\"},{\"id\":\"team_2\",\"slug\":\"other\",\"name\":\"Other\"}],\"pagination\":{\"next\":null}}",
};
const projects_one_reply: test_server.Reply = .{ .body = "{\"projects\":[{\"id\":\"prj_1\",\"name\":\"repo\"}]}" };
const projects_evil_reply: test_server.Reply = .{ .body = "{\"projects\":[{\"id\":\"prj_1\",\"name\":\"re\\u001b[2Jpo\"}]}" };
const status_500: test_server.Reply = .{ .status = "500 Internal Server Error", .body = "" };
const status_401: test_server.Reply = .{ .status = "401 Unauthorized", .body = "{}" };

const accept_project = "{\"action\":\"accept\",\"content\":{\"project\":\"prj_1\"}}";
const accept_team_one = "{\"action\":\"accept\",\"content\":{\"team\":\"team_1\"}}";
const decline_reply = "{\"action\":\"decline\"}";
const cancel_reply = "{\"action\":\"cancel\"}";

const Step = struct {
    answer: Answer,
    /// Sets the call's cancel flag before the answer goes back.
    cancel_first: bool = false,
    /// Waits for this event before the answer goes back.
    gate: ?*std.Io.Event = null,

    const Answer = union(enum) {
        /// This prompt's answer. The responder keys it as the real ones do.
        json: []const u8,
        /// The exact bytes a responder writes, keyed by the request.
        keyed: []const u8,
        timed_out,
        broken,
    };
};

const Capture = struct {
    bytes: [16 * 1024]u8 = undefined,
    len: usize = 0,

    fn line(context: ?*anyopaque, text: []const u8) void {
        const self: *Capture = @ptrCast(@alignCast(context.?));
        const take = @min(self.bytes.len - self.len, text.len);
        @memcpy(self.bytes[self.len..][0..take], text[0..take]);
        self.len += take;
    }

    fn trace(self: *Capture) vercel.Trace {
        return .{ .context = self, .line = line };
    }

    fn captured(self: *const Capture) []const u8 {
        return self.bytes[0..self.len];
    }
};

const Scripted = struct {
    steps: []const Step,
    cancel: *std.atomic.Value(bool),
    tmp_dir: std.Io.Dir,
    token: []const u8 = test_token,
    /// Runs once the prompt is open, before its answer goes back.
    before: ?*const fn (*Scripted) anyerror!void = null,
    /// Set when the first prompt opens.
    asked: ?*std.Io.Event = null,
    next: usize = 0,
    prompts: usize = 0,
    saw_token: bool = false,
    saw_header: bool = false,
    saw_escape: bool = false,
    saw_evil: bool = false,
    wrong_origin: bool = false,

    fn respond(context: *anyopaque, alloc: std.mem.Allocator, origin: tool_mcp_runtime.InputOrigin, required: tool_mcp_runtime.InputRequired) anyerror![]const u8 {
        const self: *Scripted = @ptrCast(@alignCast(context));
        self.prompts += 1;
        const json = required.input_requests_json;
        if (origin.kind != .host) self.wrong_origin = true;
        if (std.mem.find(u8, json, self.token) != null) self.saw_token = true;
        if (std.mem.find(u8, json, "fx asks") != null) self.saw_header = true;
        // A JSON string writes an ESC byte as \u001b, so this finds a raw escape.
        if (std.mem.find(u8, json, "\\u001b") != null) self.saw_escape = true;
        if (std.mem.find(u8, json, "evil") != null) self.saw_evil = true;
        if (self.asked) |event| event.set(io_mod.getIo());
        const step = self.steps[@min(self.next, self.steps.len - 1)];
        self.next += 1;
        if (step.cancel_first) self.cancel.store(true, .release);
        if (step.gate) |gate| try gate.waitTimeout(io_mod.getIo(), .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
        if (self.before) |hook| try hook(self);
        return switch (step.answer) {
            .json => |bytes| try keyedFor(alloc, json, bytes),
            .keyed => |bytes| try alloc.dupe(u8, bytes),
            .timed_out => error.McpInputTimedOut,
            .broken => error.QuestionFailed,
        };
    }
};

/// Writes `bare` as the answer to the request in `input_json`, keyed by that
/// request, as the TUI, `fx ask` and ACP responders do.
fn keyedFor(alloc: std.mem.Allocator, input_json: []const u8, bare: []const u8) ![]const u8 {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, input_json, .{});
    const key = root.object.keys()[0];
    return alloc.print("{{\"{s}\":{s}}}", .{ key, bare });
}

fn addRule(self: *Scripted) anyerror!void {
    try self.tmp_dir.writeFile(testing.io, .{ .sub_path = "fxhome/sandbox/config.json", .data = rule_config });
}

const TestEnv = struct {
    alloc: std.mem.Allocator,
    tmp: testing.TmpDir,
    home_path: []u8,
    fx_home: []u8,
    origin: []u8,
    slot: *remote_slot.Slot,
    server: test_server.Server,
    capture: Capture,
    cancel: std.atomic.Value(bool),
    scripted: Scripted,
    responder: tool_mcp_runtime.InputResponder,
    host: Host,

    fn create(alloc: std.mem.Allocator, replies: []const test_server.Reply, steps: []const Step) !*TestEnv {
        const self = try alloc.create(TestEnv);
        errdefer alloc.destroy(self);
        self.alloc = alloc;
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        try self.tmp.dir.createDirPath(testing.io, "fxhome/sandbox");
        self.fx_home = try io_mod.dirRealpathAlloc(alloc, self.tmp.dir, "fxhome");
        errdefer alloc.free(self.fx_home);
        self.home_path = try io_mod.dirRealpathAlloc(alloc, self.tmp.dir, ".");
        errdefer alloc.free(self.home_path);
        self.slot = try remote_slot.Slot.create(alloc);
        errdefer self.slot.destroy();
        self.server = .{ .replies = replies };
        try self.server.listen();
        try self.server.start();
        self.origin = try alloc.print("http://127.0.0.1:{d}", .{self.server.port()});
        errdefer alloc.free(self.origin);
        self.capture = .{};
        self.cancel = .init(false);
        self.scripted = .{ .steps = steps, .cancel = &self.cancel, .tmp_dir = self.tmp.dir };
        self.responder = .{
            .context = &self.scripted,
            .capabilities = .{ .form = true },
            .callback = Scripted.respond,
        };
        self.host = .{
            .alloc = alloc,
            .slot = self.slot,
            .fx_home = self.fx_home,
            .home = test_home,
            .loaded = config.absent_fingerprint,
            .base = vercel.resolveBaseUrl(self.origin),
            .env = .{ .vercel_token = test_token, .home = self.home_path },
            .os = .linux,
            .files = vercel.disk,
            .trace = self.capture.trace(),
            .clock = fake_clock,
            .user_check = .{ .slot = self.slot },
        };
        return self;
    }

    fn destroy(self: *TestEnv) void {
        self.server.close();
        self.slot.destroy();
        self.tmp.cleanup();
        self.alloc.free(self.origin);
        self.alloc.free(self.home_path);
        self.alloc.free(self.fx_home);
        self.alloc.destroy(self);
    }

    fn call(self: *TestEnv, arena: std.mem.Allocator, key: ?[]const u8, turn: u64, allowed: bool, form: bool) Call {
        return callFor(arena, allowed, key, turn, if (form) self.responder else null, &self.cancel);
    }

    fn run(self: *TestEnv, arena: std.mem.Allocator, key: ?[]const u8, turn: u64) !Result {
        return ensureReady(&self.host, self.call(arena, key, turn, true, true));
    }

    fn primeUser(self: *TestEnv) !void {
        try self.host.user_check.store(self.alloc, tokenHash(.{ .value = test_token }), "usr_1");
    }
};

fn readConfig(arena: std.mem.Allocator, dir: std.Io.Dir) ![]u8 {
    return dir.readFileAlloc(testing.io, "fxhome/sandbox/config.json", arena, .limited(64 * 1024));
}

const Runner = struct {
    host: *Host,
    call: Call,
    result: ?Result = null,
    failed: bool = false,

    fn run(self: *Runner) void {
        self.result = ensureReady(self.host, self.call) catch {
            self.failed = true;
            return;
        };
    }
};

fn expectRefused(result: Result, expected: []const u8) !void {
    switch (result) {
        .refused => |text| try testing.expectEqualStrings(expected, text),
        else => return error.TestUnexpectedResult,
    }
}

fn expectReady(result: Result, team_id: []const u8, project_id: []const u8) !void {
    switch (result) {
        .ready => |destination| {
            try testing.expectEqualStrings(team_id, destination.team_id);
            try testing.expectEqualStrings(project_id, destination.project_id);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "AC-19: one team, two calls at once: the project is asked once, and both calls get the same destination" {
    const alloc = testing.allocator;
    var asked: std.Io.Event = .unset;
    var gate: std.Io.Event = .unset;
    const steps = [_]Step{.{ .answer = .{ .json = accept_project }, .gate = &gate }};
    const env = try TestEnv.create(alloc, &.{ teams_one_reply, projects_one_reply, sandbox_missing_reply }, &steps);
    defer env.destroy();
    env.scripted.asked = &asked;
    try env.primeUser();

    var arena_a = std.heap.ArenaAllocator.init(alloc);
    defer arena_a.deinit();
    var arena_b = std.heap.ArenaAllocator.init(alloc);
    defer arena_b.deinit();

    var first: Runner = .{ .host = &env.host, .call = env.call(arena_a.allocator(), "session-a", 5, true, true) };
    const thread_a = try std.Thread.spawn(.{}, Runner.run, .{&first});
    try asked.waitTimeout(io_mod.getIo(), .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });

    var second: Runner = .{ .host = &env.host, .call = env.call(arena_b.allocator(), "session-b", 5, true, true) };
    const thread_b = try std.Thread.spawn(.{}, Runner.run, .{&second});
    gate.set(io_mod.getIo());
    thread_a.join();
    thread_b.join();

    try testing.expect(!first.failed and !second.failed);
    try expectReady(first.result orelse return error.TestUnexpectedResult, "team_1", "prj_1");
    try expectReady(second.result orelse return error.TestUnexpectedResult, "team_1", "prj_1");
    try testing.expectEqual(@as(usize, 1), env.scripted.prompts);
    try testing.expect(!env.scripted.wrong_origin);
}

test "AC-29: a rule added before the project accept gives E14, and the file keeps the rule with no remote" {
    const alloc = testing.allocator;
    const steps = [_]Step{.{ .answer = .{ .json = accept_project } }};
    const env = try TestEnv.create(alloc, &.{ user_reply, teams_one_reply, projects_one_reply, sandbox_missing_reply }, &steps);
    defer env.destroy();
    env.scripted.before = addRule;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const result = try env.run(arena.allocator(), "session-a", 5);
    try expectRefused(result, e14_text);

    const text = try readConfig(arena.allocator(), env.tmp.dir);
    try testing.expect(std.mem.find(u8, text, "\"rules\"") != null);
    try testing.expect(std.mem.find(u8, text, "\"remote\":") == null);
    try testing.expect((try env.slot.currentDestination(arena.allocator())) == null);
}

test "the host prompt text has no fx asks header, so the ACP formatter adds exactly one" {
    const alloc = testing.allocator;
    const steps = [_]Step{.{ .answer = .{ .json = accept_project } }};
    const env = try TestEnv.create(alloc, &.{ user_reply, teams_one_reply, projects_one_reply, sandbox_missing_reply }, &steps);
    defer env.destroy();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const result = try env.run(arena.allocator(), "session-a", 5);
    try expectReady(result, "team_1", "prj_1");
    try testing.expectEqual(@as(usize, 1), env.scripted.prompts);
    try testing.expect(!env.scripted.saw_header);
}

const sandbox_found_reply: test_server.Reply = .{ .body = "{\"id\":\"prj_9\",\"name\":\"fx-sandbox\"}" };
const sandbox_missing_reply: test_server.Reply = .{ .status = "404 Not Found", .body = "{}" };

test "U6: an fx-sandbox the first page does not hold is listed as existing when its lookup answers 200" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const env = try TestEnv.create(testing.allocator, &.{ projects_one_reply, sandbox_found_reply }, &.{});
    defer env.destroy();
    const team: vercel.Team = .{ .id = "team_1", .slug = "acme", .name = "Acme" };
    const event = try restEvent(&env.host, env.call(arena_state.allocator(), null, 1, true, false), .{ .value = test_token }, .{ .list_projects = team });
    switch (event) {
        .projects_listed => |listed| {
            try testing.expectEqual(@as(usize, 2), listed.projects.len);
            try testing.expectEqualStrings("fx-sandbox", listed.projects[1].name);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "U6: a 404 on the fx-sandbox lookup leaves the listed projects as they are" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const env = try TestEnv.create(testing.allocator, &.{ projects_one_reply, sandbox_missing_reply }, &.{});
    defer env.destroy();
    const team: vercel.Team = .{ .id = "team_1", .slug = "acme", .name = "Acme" };
    const event = try restEvent(&env.host, env.call(arena_state.allocator(), null, 1, true, false), .{ .value = test_token }, .{ .list_projects = team });
    switch (event) {
        .projects_listed => |listed| try testing.expectEqual(@as(usize, 1), listed.projects.len),
        else => return error.TestUnexpectedResult,
    }
}

test "U6: a failed fx-sandbox lookup is the list step's failure, with its status (E9)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const env = try TestEnv.create(testing.allocator, &.{ projects_one_reply, status_500 }, &.{});
    defer env.destroy();
    const team: vercel.Team = .{ .id = "team_1", .slug = "acme", .name = "Acme" };
    const event = try restEvent(&env.host, env.call(arena_state.allocator(), null, 1, true, false), .{ .value = test_token }, .{ .list_projects = team });
    switch (event) {
        .rest_failed => |failure| {
            try testing.expectEqualStrings("project", failure.step);
            switch (failure.reason) {
                .status => |code| try testing.expectEqual(@as(u16, 500), code),
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "E5: no login is refused, and no prompt or REST runs" {
    const alloc = testing.allocator;
    const env = try TestEnv.create(alloc, &.{user_reply}, &.{});
    defer env.destroy();
    env.host.env = .{ .home = env.home_path };

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    try expectRefused(try env.run(arena.allocator(), "session-a", 5), e5_text);
    try testing.expectEqual(@as(usize, 0), env.scripted.prompts);
    try testing.expectEqual(@as(setup.Mark, .none), env.slot.markFor("session-a", 5));
}

test "E6: an expired login is refused with no REST" {
    const alloc = testing.allocator;
    const env = try TestEnv.create(alloc, &.{user_reply}, &.{});
    defer env.destroy();
    env.host.env = .{ .home = env.home_path };
    try env.tmp.dir.createDirPath(testing.io, ".local/share/com.vercel.cli");
    try env.tmp.dir.writeFile(testing.io, .{
        .sub_path = ".local/share/com.vercel.cli/auth.json",
        .data = "{\"token\":\"fx-expired-token\",\"expiresAt\":1700000000}",
    });

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    try expectRefused(try env.run(arena.allocator(), "session-a", 5), e6_text);
    try testing.expectEqual(@as(usize, 0), env.scripted.prompts);
}

test "E6: a 401 from the user check is refused as a rejected login" {
    const alloc = testing.allocator;
    const env = try TestEnv.create(alloc, &.{status_401}, &.{});
    defer env.destroy();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    try expectRefused(try env.run(arena.allocator(), "session-a", 5), e6_text);
    try testing.expectEqual(@as(usize, 0), env.scripted.prompts);
}

test "E7: no prompt channel is refused with no prompt" {
    const alloc = testing.allocator;
    const env = try TestEnv.create(alloc, &.{user_reply}, &.{});
    defer env.destroy();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const result = try ensureReady(&env.host, env.call(arena.allocator(), "session-a", 5, true, false));
    try expectRefused(result, e7_text);
    try testing.expectEqual(@as(usize, 0), env.scripted.prompts);
}

test "E8: a decline on P1 sets the mark, which refuses the same turn without a prompt" {
    const alloc = testing.allocator;
    const steps = [_]Step{.{ .answer = .{ .json = decline_reply } }};
    const env = try TestEnv.create(alloc, &.{ user_reply, teams_two_reply, teams_two_reply }, &steps);
    defer env.destroy();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    try expectRefused(try env.run(arena.allocator(), "session-a", 5), e8_text);
    try testing.expectEqual(setup.Mark.declined, env.slot.markFor("session-a", 5));
    try expectRefused(try env.run(arena.allocator(), "session-a", 5), e8_text);
    try testing.expectEqual(@as(usize, 1), env.scripted.prompts);

    try expectRefused(try env.run(arena.allocator(), "session-a", 6), e8_text);
    try testing.expectEqual(@as(usize, 2), env.scripted.prompts);
}

test "E8: a decline on P2 sets the mark, which refuses the same turn without a prompt" {
    const alloc = testing.allocator;
    const steps = [_]Step{.{ .answer = .{ .json = decline_reply } }};
    const env = try TestEnv.create(alloc, &.{ user_reply, teams_one_reply, projects_one_reply, sandbox_missing_reply }, &steps);
    defer env.destroy();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    try expectRefused(try env.run(arena.allocator(), "session-a", 5), e8_text);
    try expectRefused(try env.run(arena.allocator(), "session-a", 5), e8_text);
    try testing.expectEqual(@as(usize, 1), env.scripted.prompts);
}

test "E9: a failed REST step is refused with its step and status, and sets no mark" {
    const alloc = testing.allocator;
    const env = try TestEnv.create(alloc, &.{ user_reply, status_500 }, &.{});
    defer env.destroy();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const result = try env.run(arena.allocator(), "session-a", 5);
    switch (result) {
        .refused => |text| {
            try testing.expect(std.mem.startsWith(u8, text, e9_prefix));
            try testing.expect(std.mem.find(u8, text, "HTTP 500") != null);
        },
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(setup.Mark.none, env.slot.markFor("session-a", 5));
}

test "E9: a failed user check names the user step" {
    const alloc = testing.allocator;
    const env = try TestEnv.create(alloc, &.{status_500}, &.{});
    defer env.destroy();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const result = try env.run(arena.allocator(), "session-a", 5);
    switch (result) {
        .refused => |text| try testing.expectEqualStrings(e9_prefix ++ "user: HTTP 500", text),
        else => return error.TestUnexpectedResult,
    }
}

test "E9: a prompt that cannot be answered is refused, sets no mark, and writes nothing" {
    const alloc = testing.allocator;
    const steps = [_]Step{.{ .answer = .broken }};
    const env = try TestEnv.create(alloc, &.{ user_reply, teams_one_reply, projects_one_reply, sandbox_missing_reply }, &steps);
    defer env.destroy();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const result = try env.run(arena.allocator(), "session-a", 5);
    try expectRefused(result, e9_prefix ++ "project: the question could not be shown or answered");
    try testing.expectEqual(setup.Mark.none, env.slot.markFor("session-a", 5));
    try testing.expectError(error.FileNotFound, readConfig(arena.allocator(), env.tmp.dir));
}

test "E10: a sub-agent call is refused, and it never reads or writes the mark" {
    const alloc = testing.allocator;
    const env = try TestEnv.create(alloc, &.{user_reply}, &.{});
    defer env.destroy();
    try env.slot.recordMark("session-a", 5, .declined);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const result = try ensureReady(&env.host, env.call(arena.allocator(), null, 5, false, true));
    try expectRefused(result, e10_text);
    try testing.expectEqual(@as(usize, 0), env.scripted.prompts);
    try testing.expectEqual(setup.Mark.declined, env.slot.markFor("session-a", 5));
}

test "E15: an unanswered prompt is refused after the limit, and the same turn stays refused" {
    const alloc = testing.allocator;
    const steps = [_]Step{.{ .answer = .timed_out }};
    const env = try TestEnv.create(alloc, &.{ user_reply, teams_one_reply, projects_one_reply, sandbox_missing_reply }, &steps);
    defer env.destroy();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    try expectRefused(try env.run(arena.allocator(), "session-a", 5), e15_text);
    try testing.expectEqual(setup.Mark.no_answer, env.slot.markFor("session-a", 5));
    try expectRefused(try env.run(arena.allocator(), "session-a", 5), e15_text);
    try testing.expectEqual(@as(usize, 1), env.scripted.prompts);
}

test "cancel before the call ends canceled with no prompt and no mark" {
    const alloc = testing.allocator;
    const env = try TestEnv.create(alloc, &.{user_reply}, &.{});
    defer env.destroy();
    env.cancel.store(true, .release);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const result = try env.run(arena.allocator(), "session-a", 5);
    try testing.expect(result == .canceled);
    try testing.expectEqual(@as(usize, 0), env.scripted.prompts);
    try testing.expectEqual(setup.Mark.none, env.slot.markFor("session-a", 5));
}

test "cancel during a prompt ends canceled with no mark" {
    const alloc = testing.allocator;
    const steps = [_]Step{.{ .answer = .{ .json = decline_reply }, .cancel_first = true }};
    const env = try TestEnv.create(alloc, &.{ user_reply, teams_one_reply, projects_one_reply, sandbox_missing_reply }, &steps);
    defer env.destroy();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const result = try env.run(arena.allocator(), "session-a", 5);
    try testing.expect(result == .canceled);
    try testing.expectEqual(setup.Mark.none, env.slot.markFor("session-a", 5));
}

test "cancel after an accept ends canceled, and nothing is written" {
    const alloc = testing.allocator;
    const steps = [_]Step{.{ .answer = .{ .json = accept_project }, .cancel_first = true }};
    const env = try TestEnv.create(alloc, &.{ user_reply, teams_one_reply, projects_one_reply, sandbox_missing_reply }, &steps);
    defer env.destroy();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const result = try env.run(arena.allocator(), "session-a", 5);
    try testing.expect(result == .canceled);
    try testing.expectError(error.FileNotFound, readConfig(arena.allocator(), env.tmp.dir));
}

test "R5: the user check runs once per process per token, and later calls read the cache" {
    const alloc = testing.allocator;
    const steps = [_]Step{.{ .answer = .{ .json = accept_project } }};
    const env = try TestEnv.create(alloc, &.{ user_reply, teams_one_reply, projects_one_reply, sandbox_missing_reply }, &steps);
    defer env.destroy();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    try expectReady(try env.run(arena.allocator(), "session-a", 5), "team_1", "prj_1");
    try expectReady(try env.run(arena.allocator(), "session-a", 6), "team_1", "prj_1");
    env.server.close();
    // The user, the teams, the projects, and the fx-sandbox lookup (U6); the second run asks nothing.
    try testing.expectEqual(@as(usize, 4), env.server.servedCount());
    try testing.expect(std.mem.startsWith(u8, env.server.head(0), "GET /v2/user"));
}

test "a token that is held by the host never reaches a prompt, a trace line or a refusal" {
    const alloc = testing.allocator;
    const leak_token = "fx-leak-token-7f3a91";
    const steps = [_]Step{.{ .answer = .{ .json = accept_project } }};
    const env = try TestEnv.create(alloc, &.{ user_reply, teams_one_reply, projects_one_reply, sandbox_missing_reply }, &steps);
    defer env.destroy();
    env.host.env = .{ .vercel_token = leak_token, .home = env.home_path };
    env.scripted.token = leak_token;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    try expectReady(try env.run(arena.allocator(), "session-a", 5), "team_1", "prj_1");
    try testing.expect(!env.scripted.saw_token);
    try testing.expect(std.mem.find(u8, env.capture.captured(), leak_token) == null);
}

const keyed_accept_team_one = "{\"team\":{\"action\":\"accept\",\"content\":{\"team\":\"team_1\"}}}";
const keyed_accept_project = "{\"project\":{\"action\":\"accept\",\"content\":{\"project\":\"prj_1\"}}}";

test "an answer keyed exactly as ACP writes it is read as this prompt's answer" {
    const alloc = testing.allocator;
    const steps = [_]Step{ .{ .answer = .{ .keyed = keyed_accept_team_one } }, .{ .answer = .{ .keyed = keyed_accept_project } } };
    const env = try TestEnv.create(alloc, &.{ user_reply, teams_two_reply, projects_one_reply, sandbox_missing_reply }, &steps);
    defer env.destroy();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    try expectReady(try env.run(arena.allocator(), "session-a", 5), "team_1", "prj_1");
    try testing.expectEqual(@as(usize, 2), env.scripted.prompts);
}

test "an answer keyed by another request is refused, and the setup fails without asking again" {
    const alloc = testing.allocator;
    const steps = [_]Step{.{ .answer = .{ .keyed = keyed_accept_project } }};
    const env = try TestEnv.create(alloc, &.{ user_reply, teams_two_reply, projects_one_reply, sandbox_missing_reply }, &steps);
    defer env.destroy();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const result = try env.run(arena.allocator(), "session-a", 5);
    try testing.expect(std.meta.activeTag(result) == .refused);
    try testing.expect(std.mem.find(u8, result.refused, "did not fit the question") != null);
    try testing.expectEqual(@as(usize, 1), env.scripted.prompts);
}

test "a team name with an escape sequence shows cleaned in the title, and the step gets the team's id unchanged" {
    const alloc = testing.allocator;
    const steps = [_]Step{ .{ .answer = .{ .json = accept_team_one } }, .{ .answer = .{ .json = accept_project } } };
    const env = try TestEnv.create(alloc, &.{ user_reply, teams_evil_reply, projects_one_reply, sandbox_missing_reply }, &steps);
    defer env.destroy();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    try expectReady(try env.run(arena.allocator(), "session-a", 5), "team_1", "prj_1");
    try testing.expectEqual(@as(usize, 2), env.scripted.prompts);
    try testing.expect(env.scripted.saw_evil);
    try testing.expect(!env.scripted.saw_escape);
}

test "a project name with an escape sequence shows cleaned in the choice" {
    const alloc = testing.allocator;
    const steps = [_]Step{.{ .answer = .{ .json = accept_project } }};
    const env = try TestEnv.create(alloc, &.{ user_reply, teams_one_reply, projects_evil_reply, sandbox_missing_reply }, &steps);
    defer env.destroy();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    try expectReady(try env.run(arena.allocator(), "session-a", 5), "team_1", "prj_1");
    try testing.expect(!env.scripted.saw_escape);
}

test "E10: a sub-agent call with no remote is refused with no request, and reads no mark" {
    const alloc = testing.allocator;
    const env = try TestEnv.create(alloc, &.{user_reply}, &.{});
    defer env.destroy();
    try env.slot.recordMark("session-a", 5, .declined);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const result = try ensureReady(&env.host, env.call(arena.allocator(), "session-a", 5, false, true));
    try expectRefused(result, e10_text);
    try testing.expectEqual(@as(usize, 0), env.scripted.prompts);
    env.server.close();
    try testing.expectEqual(@as(usize, 0), env.server.servedCount());
    try testing.expectEqual(setup.Mark.declined, env.slot.markFor("session-a", 5));
}

test "callFor gives a sub-agent call no session key, so it cannot read a mark" {
    var cancel: std.atomic.Value(bool) = .init(false);
    const main_call = callFor(testing.allocator, true, "session-a", 5, null, &cancel);
    try testing.expectEqualStrings("session-a", main_call.session_key.?);
    const sub_call = callFor(testing.allocator, false, "session-a", 5, null, &cancel);
    try testing.expect(sub_call.session_key == null);
}
