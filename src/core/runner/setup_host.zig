//! The effects of one remote setup, for one call (spec U1 to U12, R5). The pure
//! step in `setup.zig` decides; this file runs what it asks for: the login
//! check, destination discovery, the copy question, the locked write, and the
//! consent record. `ensureReady` returns ready, canceled, or a refusal text.
//!
//! The slot's mutex is never held across a REST call, a prompt, or a write.

const std = @import("std");
const vercel = @import("vercel/vercel.zig");
const setup = @import("setup.zig");
const consent = @import("consent.zig");
const remote_slot = @import("remote_slot.zig");
const config = @import("config.zig");
const config_write = @import("config_write.zig");
const settings_keys = @import("../config/settings_keys.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");

const testing = std.testing;
const test_server = @import("vercel/test_server.zig");

const TokenHash = remote_slot.TokenHash;

const host_wire: @import("../mcp/elicitation.zig").Wire = .modern_mcp;
const host_operation: @import("../mcp/elicitation.zig").Operation = .{ .tools_call = "" };

pub const team_setting_key = settings_keys.sandbox_team_key;
pub const project_setting_key = settings_keys.sandbox_project_key;

const copy_key = "copy";
const choice_yes = "Yes";
const choice_no = "No";

const e4_prefix = "fx did not run this command: ";
const e4_suffix = " Fix ~/.fx/sandbox/config.json, or turn off experimental.sandbox_execution.";
pub const e5_text = "fx did not run this command: no Vercel login. Ask the person to run `vercel login` or set VERCEL_TOKEN.";
pub const e6_text = "fx did not run this command: the Vercel login has expired or was rejected. Ask the person to run `vercel whoami` to refresh it, or run `vercel login`.";
pub const e7_text = "fx did not run this command: this repository needs remote consent, and fx cannot ask here. Run the first remote command in the fx TUI or `fx ask` in a terminal.";
pub const e8_text = "fx did not run this command: the person declined copying this repository to Vercel. Do not retry in this turn.";
const e9_prefix = "fx did not run this command: remote setup failed: ";
pub const e10_text = "fx did not run this command: this repository is not set up for remote commands. Set it up from the main conversation first.";
const e14_text = "fx did not run this command: ~/.fx/sandbox/config.json changed since fx started. Restart fx to use it.";
pub const e15_text = "fx did not run this command: the remote copy question was not answered in 15 minutes. Do not retry in this turn.";

pub const SetupIntent = setup.Intent;

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

pub const debug_trace_sink: vercel.Trace = .{ .context = null, .line = debugLine };

fn debugLine(context: ?*anyopaque, text: []const u8) void {
    _ = context;
    debug_trace.logf("remote setup", "{s}", .{text});
}

pub const UserCheck = struct {
    slot: *remote_slot.Slot,

    pub fn store(self: *UserCheck, alloc: std.mem.Allocator, hash: TokenHash, user_id: []const u8) std.mem.Allocator.Error!void {
        _ = alloc;
        return self.slot.storeChecked(hash, user_id);
    }

    pub fn storeWithTeam(
        self: *UserCheck,
        alloc: std.mem.Allocator,
        hash: TokenHash,
        user_id: []const u8,
        default_team_id: ?[]const u8,
    ) std.mem.Allocator.Error!void {
        _ = alloc;
        return self.slot.storeCheckedUser(hash, user_id, default_team_id);
    }
};

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

pub const Call = struct {
    arena: std.mem.Allocator,
    workspace_root: []const u8,
    intent: SetupIntent = .{},
    session_key: ?[]const u8,
    turn_id: u64,
    setup_allowed: bool,
    responder: ?tool_mcp_runtime.InputResponder,
    cancel: *std.atomic.Value(bool),
};

pub fn callFor(
    arena: std.mem.Allocator,
    workspace_root: []const u8,
    intent: SetupIntent,
    remote_setup_allowed: bool,
    session_key: ?[]const u8,
    turn_id: u64,
    responder: ?tool_mcp_runtime.InputResponder,
    cancel: *std.atomic.Value(bool),
) Call {
    return .{
        .arena = arena,
        .workspace_root = workspace_root,
        .intent = intent,
        .session_key = if (remote_setup_allowed) session_key else null,
        .turn_id = turn_id,
        .setup_allowed = remote_setup_allowed,
        .responder = responder,
        .cancel = cancel,
    };
}

pub const Result = union(enum) {
    ready: remote_slot.Destination,
    canceled,
    refused: []const u8,
};

const user_step = "user";

const HostLogin = struct {
    state: setup.Login,
    token: vercel.Token,
};

const Resolved = union(enum) {
    login: setup.Login,
    done: Result,
};

const Arrived = union(enum) {
    transition: setup.Transition,
    done: Result,
};

const ConfigRead = union(enum) {
    config: setup.Config,
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
        .discover, .ask_copy, .create_project, .write => true,
        .none, .wait, .ready, .need_user, .refuse, .canceled => false,
    };
}

fn localLogin(host: *Host, call: Call) std.mem.Allocator.Error!HostLogin {
    const auth = try vercel.load(call.arena, host.env, host.os, host.files, host.trace, host.clock.unixS());
    return switch (auth) {
        .missing => .{ .state = .none, .token = unused_token },
        .expired => .{ .state = .expired, .token = unused_token },
        .token => |token| .{ .state = .present, .token = token },
    };
}

fn resolveUser(host: *Host, call: Call, token: vercel.Token) std.mem.Allocator.Error!Resolved {
    const hash = tokenHash(token);
    if (try host.slot.checkedUser(hash, call.arena)) |user_id| {
        return .{ .login = .{ .user = user_id } };
    }
    const outcome = try vercel.getUser(call.arena, linkFor(host, call, token));
    switch (outcome) {
        .ok => |user| {
            try host.slot.storeCheckedUser(hash, user.id, user.default_team_id);
            return .{ .login = .{ .user = user.id } };
        },
        .rejected => return .{ .login = .rejected },
        .not_found => return .{ .done = try apiFailure(call.arena, .{ .step = user_step, .reason = .bad_reply }) },
        .canceled => return .{ .done = .canceled },
        .failed => |failure| return .{ .done = try apiFailure(call.arena, failure) },
    }
}

fn arriveResolved(host: *Host, call: Call, login: *HostLogin) std.mem.Allocator.Error!Arrived {
    const first = switch (try arrive(host, call, login.*)) {
        .transition => |found| found,
        .done => |result| return .{ .done = result },
    };
    if (std.meta.activeTag(first.decision) != .need_user) return .{ .transition = first };
    switch (try resolveUser(host, call, login.token)) {
        .login => |state| login.state = state,
        .done => |result| return .{ .done = result },
    }
    return arrive(host, call, login.*);
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

fn arrive(host: *Host, call: Call, login: HostLogin) std.mem.Allocator.Error!Arrived {
    const cfg = switch (try configOf(host, call, login)) {
        .config => |value| value,
        .done => |result| return .{ .done = result },
    };
    const mark = host.slot.markFor(call.session_key, call.turn_id);
    return .{ .transition = setup.step(.{ .idle = mark }, .{ .arrival = .{
        .caller = if (call.setup_allowed) .main else .sub_agent,
        .channel = channelOf(call),
        .login = login.state,
        .config = cfg,
    } }) };
}

const EffectiveDestination = struct {
    team_ref: ?[]const u8,
    team_from_setting: bool,
    project_name: []const u8,
};

/// Resolves the effective destination inputs in one place (R1.8) with no REST calls:
/// team = `sandbox_team`, else Vercel CLI `currentTeam`, else cached `defaultTeamId`;
/// project = `sandbox_project`, else `fx-sandbox`.
fn effectiveDestination(
    host: *const Host,
    arena: std.mem.Allocator,
    intent: SetupIntent,
    token_hash: ?TokenHash,
) std.mem.Allocator.Error!EffectiveDestination {
    const team_ref: ?[]const u8 = if (intent.team) |slug|
        slug
    else if (try vercel.loadCliTeamId(arena, host.env, host.os, host.files, host.trace)) |cli_id|
        cli_id
    else if (token_hash) |hash|
        try host.slot.checkedDefaultTeam(hash, arena)
    else
        null;

    return .{
        .team_ref = team_ref,
        .team_from_setting = intent.team != null,
        .project_name = intent.project orelse vercel.sandbox_project_name,
    };
}

fn destinationMatchesEffective(destination: remote_slot.Destination, effective: EffectiveDestination) bool {
    const team_ref = effective.team_ref orelse return false;
    if (!std.mem.eql(u8, destination.team_id, team_ref) and !std.mem.eql(u8, destination.team_slug, team_ref)) {
        return false;
    }
    return std.mem.eql(u8, destination.project_name, effective.project_name);
}

fn configOf(host: *Host, call: Call, login: HostLogin) std.mem.Allocator.Error!ConfigRead {
    const destination = (try host.slot.currentDestination(call.arena)) orelse return .{ .config = .absent };
    const hash: ?TokenHash = switch (login.state) {
        .user => tokenHash(login.token),
        else => null,
    };
    const effective = try effectiveDestination(host, call.arena, call.intent, hash);
    const matches_effective = destinationMatchesEffective(destination, effective);
    const consent_state: setup.Consent = switch (login.state) {
        .user => |user_id| blk: {
            if (!std.mem.eql(u8, destination.user_id, user_id) or !matches_effective) break :blk .missing;
            const root = io_mod.realpathAlloc(call.arena, call.workspace_root) catch |err| {
                return .{ .done = .{ .refused = try workspaceRefusalText(call.arena, call.workspace_root, err) } };
            };
            const key = try consent.repoKey(call.arena, user_id, root);
            const ok = try consent.hasForDestination(call.arena, host.fx_home, key, destination.team_id, destination.project_id);
            break :blk if (ok) .matches else .missing;
        },
        else => .missing,
    };
    return .{ .config = .{ .remote = .{
        .user_id = destination.user_id,
        .matches_intent = matches_effective,
        .consent = consent_state,
    } } };
}

fn channelOf(call: Call) setup.Channel {
    const responder = call.responder orelse return .none;
    return if (responder.capabilities.form) .form else .none;
}

fn runOwner(host: *Host, call: Call, token: vercel.Token, first: setup.Transition) std.mem.Allocator.Error!Result {
    var transition = first;
    while (true) {
        trace(host, "setup decision={s}", .{@tagName(transition.decision)});
        switch (transition.decision) {
            .none, .wait, .ready, .need_user, .refuse, .canceled => return finish(host, call, transition),
            .discover => |owner| {
                const event = if (cancelled(call)) setup.Event.owner_canceled else try discoverEvent(host, call, token, owner);
                transition = setup.step(transition.state, event);
            },
            .ask_copy => |ask| {
                const event = if (cancelled(call)) setup.Event.owner_canceled else try askCopy(call, transition.state, ask);
                transition = setup.step(transition.state, event);
            },
            .create_project => |team| {
                const event = if (cancelled(call)) setup.Event.owner_canceled else try createProjectEvent(host, call, token, team);
                transition = setup.step(transition.state, event);
            },
            .write => |destination| transition = try writeTransition(host, call, transition.state, destination),
        }
    }
}

fn cancelled(call: Call) bool {
    return call.cancel.load(.acquire);
}

fn finish(host: *Host, call: Call, transition: setup.Transition) std.mem.Allocator.Error!Result {
    try recordMark(host, call, transition.state);
    return switch (transition.decision) {
        .ready => .{ .ready = (try host.slot.currentDestination(call.arena)) orelse unreachable },
        .refuse => |refusal| .{ .refused = try refusalText(call.arena, refusal) },
        .canceled => .canceled,
        .none, .wait, .need_user, .discover, .ask_copy, .create_project, .write => unreachable,
    };
}

fn recordMark(host: *Host, call: Call, state: setup.State) std.mem.Allocator.Error!void {
    const mark = switch (state) {
        .idle => |kept| kept,
        else => return,
    };
    if (mark == .none) return;
    host.slot.recordMark(call.session_key, call.turn_id, mark) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoActiveTurn => trace(host, "setup mark not kept: no active turn", .{}),
    };
}

fn discoverEvent(host: *Host, call: Call, token: vercel.Token, owner: setup.Owner) std.mem.Allocator.Error!setup.Event {
    const link = linkFor(host, call, token);
    _ = io_mod.realpathAlloc(call.arena, call.workspace_root) catch |err| {
        const message = try workspaceRefusalText(call.arena, call.workspace_root, err);
        return .{ .discover_refused = .{ .workspace_unresolved = message } };
    };

    const effective = try effectiveDestination(host, call.arena, call.intent, tokenHash(token));
    const existing = try host.slot.currentDestination(call.arena);
    if (existing) |dest| {
        if (std.mem.eql(u8, dest.user_id, owner.user_id) and destinationMatchesEffective(dest, effective)) {
            return discoverExistingDestination(host, call, link, dest, effective);
        }
    }
    return discoverFreshDestination(host, call, link, effective);
}

fn discoverExistingDestination(
    host: *Host,
    call: Call,
    link: vercel.Link,
    dest: remote_slot.Destination,
    effective: EffectiveDestination,
) std.mem.Allocator.Error!setup.Event {
    const setting_slug = if (effective.team_from_setting) effective.team_ref else null;
    const team = switch (try vercel.getTeam(call.arena, link, dest.team_id)) {
        .ok => |found| found,
        .not_found => return refuseTeamMissing(call.arena, link, setting_slug),
        .rejected => return .rest_rejected,
        .canceled => return .owner_canceled,
        .failed => |failure| return .{ .rest_failed = failure },
    };
    const project = switch (try vercel.getProjectByName(call.arena, link, team.id, dest.project_name)) {
        .ok => |found| found,
        .not_found => if (call.intent.project == null and std.mem.eql(u8, dest.project_name, vercel.sandbox_project_name))
            null
        else
            return .{ .discover_refused = .{ .project_not_found = .{ .team = team, .name = dest.project_name } } },
        .rejected => return .rest_rejected,
        .canceled => return .owner_canceled,
        .failed => |failure| return .{ .rest_failed = failure },
    };
    return .{ .discovered = .{ .team = team, .project = project, .now_ms = host.clock.awakeMs() } };
}

fn discoverFreshDestination(
    host: *Host,
    call: Call,
    link: vercel.Link,
    effective: EffectiveDestination,
) std.mem.Allocator.Error!setup.Event {
    const setting_slug = if (effective.team_from_setting) effective.team_ref else null;
    const lookup = effective.team_ref orelse return refuseTeamMissing(call.arena, link, null);
    const team = switch (try vercel.getTeam(call.arena, link, lookup)) {
        .ok => |found| found,
        .not_found => return refuseTeamMissing(call.arena, link, setting_slug),
        .rejected => return .rest_rejected,
        .canceled => return .owner_canceled,
        .failed => |failure| return .{ .rest_failed = failure },
    };

    const project: ?vercel.Project = switch (try vercel.getProjectByName(call.arena, link, team.id, effective.project_name)) {
        .ok => |found| found,
        .not_found => if (call.intent.project != null)
            return .{ .discover_refused = .{ .project_not_found = .{ .team = team, .name = effective.project_name } } }
        else
            null,
        .rejected => return .rest_rejected,
        .canceled => return .owner_canceled,
        .failed => |failure| return .{ .rest_failed = failure },
    };
    return .{ .discovered = .{ .team = team, .project = project, .now_ms = host.clock.awakeMs() } };
}

fn refuseTeamMissing(
    arena: std.mem.Allocator,
    link: vercel.Link,
    setting_slug: ?[]const u8,
) std.mem.Allocator.Error!setup.Event {
    const available: []const vercel.Team = switch (try vercel.listTeamsFirstPage(arena, link)) {
        .ok => |teams| teams,
        .not_found => &.{},
        .rejected => return .rest_rejected,
        .canceled => return .owner_canceled,
        .failed => |failure| return .{ .rest_failed = failure },
    };
    return .{ .discover_refused = .{ .no_team = .{ .setting_slug = setting_slug, .available = available } } };
}

fn createProjectEvent(
    host: *Host,
    call: Call,
    token: vercel.Token,
    team: vercel.Team,
) std.mem.Allocator.Error!setup.Event {
    const link = linkFor(host, call, token);
    return switch (try vercel.createProject(call.arena, link, team.id)) {
        .ok => |project| .{ .project_created = project },
        .rejected => .rest_rejected,
        .not_found => .{ .rest_failed = .{ .step = vercel.sandbox_project_name, .reason = .{ .status = 404 } } },
        .canceled => .owner_canceled,
        .failed => |failure| .{ .rest_failed = failure },
    };
}

fn writeTransition(host: *Host, call: Call, state: setup.State, destination: setup.Destination) std.mem.Allocator.Error!setup.Transition {
    const result = try lockedWrite(host, call, destination);
    var current = state;
    if (cancelled(call)) current = setup.step(current, .owner_canceled).state;
    return setup.step(current, .{ .write_done = result });
}

fn lockedWrite(host: *Host, call: Call, destination: setup.Destination) std.mem.Allocator.Error!setup.WriteResult {
    const now_s = host.clock.unixS();
    const loaded_remote = try host.slot.currentDestination(call.arena);
    const result = config_write.writeRemote(
        call.arena,
        .{ .fx_home = host.fx_home, .home = host.home },
        host.loaded,
        loaded_remote,
        destination,
        call.cancel,
        now_s,
    );
    switch (result) {
        .written, .kept => {
            try host.slot.setDestination(.{
                .team_id = destination.team.id,
                .team_slug = destination.team.slug,
                .project_id = destination.project.id,
                .project_name = destination.project.name,
                .user_id = destination.user_id,
            });
            const root = io_mod.realpathAlloc(call.arena, call.workspace_root) catch return .{ .failed = .write_failed };
            const key = try consent.repoKey(call.arena, destination.user_id, root);
            consent.write(call.arena, host.fx_home, key, destination.team.id, destination.project.id, now_s) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.WriteFailed => return .{ .failed = .write_failed },
            };
        },
        .config_changed, .invalid, .failed, .canceled => {},
    }
    return result;
}

fn askCopy(call: Call, state: setup.State, ask: setup.CopyAsk) std.mem.Allocator.Error!setup.Event {
    const asked_at_ms = switch (state) {
        .copy_prompt => |open| open.asked_at_ms,
        else => return .prompt_failed,
    };
    const message = try call.arena.print(
        "Copy this repository to Vercel team {f}, project {f}? fx copies its tracked and unignored files to a sandbox there for remote commands.",
        .{ text_utils.terminalSafe(ask.team.name), text_utils.terminalSafe(ask.project_name) },
    );
    const schema = try copySchema(call.arena);
    const reply = try prompt(call, copy_key, message, schema, asked_at_ms);
    if (cancelled(call)) return .owner_canceled;
    return switch (reply) {
        .answered => |bytes| .{ .answered = copyAnswer(try parseReply(call.arena, bytes)) },
        .timed_out => .{ .tick = asked_at_ms + setup.question_limit_ms },
        .failed => .prompt_failed,
    };
}

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

fn entryFor(arena: std.mem.Allocator, key: []const u8, answer: []const u8) std.mem.Allocator.Error![]const u8 {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, answer, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return "{}",
    };
    const object = switch (root) {
        .object => |obj| obj,
        else => return "{}",
    };
    const entry = object.get(key) orelse return "{}";
    return std.json.Stringify.valueAlloc(arena, entry, .{}) catch return error.OutOfMemory;
}

fn parseReply(arena: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!Parsed {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .invalid,
    };
    const fields = switch (root) {
        .object => |obj| obj,
        else => return .invalid,
    };
    const action = switch (fields.get("action") orelse return .invalid) {
        .string => |text| text,
        else => return .invalid,
    };
    if (std.mem.eql(u8, action, "decline") or std.mem.eql(u8, action, "cancel")) return .dismissed;
    if (!std.mem.eql(u8, action, "accept")) return .invalid;
    const content = switch (fields.get("content") orelse return .invalid) {
        .object => |obj| obj,
        else => return .invalid,
    };
    return .{ .accept = content };
}

fn copyAnswer(parsed: Parsed) setup.Answer {
    const object = switch (parsed) {
        .dismissed => return .dismissed,
        .invalid => return .invalid,
        .accept => |found| found,
    };
    const value = object.get(copy_key) orelse return .invalid;
    const text = switch (value) {
        .string => |s| s,
        else => return .invalid,
    };
    if (std.mem.eql(u8, text, choice_yes)) return .yes;
    if (std.mem.eql(u8, text, choice_no)) return .no;
    return .invalid;
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

fn copySchema(arena: std.mem.Allocator) std.mem.Allocator.Error!std.json.Value {
    return objectOf(arena, &.{
        .{ .key = "type", .value = str("object") },
        .{ .key = "required", .value = try arrayOf(arena, &.{str(copy_key)}) },
        .{ .key = "properties", .value = try objectOf(arena, &.{.{
            .key = copy_key,
            .value = try objectOf(arena, &.{
                .{ .key = "type", .value = str("string") },
                .{ .key = "enum", .value = try arrayOf(arena, &.{ str(choice_yes), str(choice_no) }) },
            }),
        }}) },
    });
}

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
        .workspace_unresolved => |text| text,
        .no_team => |missing| noTeamText(arena, missing),
        .project_not_found => |missing| arena.print(
            "fx did not run this command: Vercel project `{f}` (from `{s}`) was not found on team `{f}`. Ask the person for a project name and run `fx config set {s} <name>`.",
            .{ text_utils.terminalSafe(missing.name), project_setting_key, text_utils.terminalSafe(missing.team.slug), project_setting_key },
        ),
        .project_create_failed => |failure| projectCreateFailedText(arena, failure),
        .setup_failed => |failure| failureText(arena, failure),
    };
}

fn noTeamText(arena: std.mem.Allocator, missing: setup.TeamMissing) std.mem.Allocator.Error![]const u8 {
    var slugs: std.Io.Writer.Allocating = .init(arena);
    const limit = @min(missing.available.len, vercel.max_team_hints);
    for (missing.available[0..limit], 0..) |team, index| {
        if (index > 0) slugs.writer.writeAll(", ") catch return error.OutOfMemory;
        slugs.writer.print("{f}", .{text_utils.terminalSafe(team.slug)}) catch return error.OutOfMemory;
    }
    if (missing.setting_slug) |slug| {
        if (limit > 0) {
            return arena.print(
                "fx did not run this command: Vercel team `{f}` (from `{s}`) was not found. Available teams: {s}. Ask the person which one to use and run `fx config set {s} <slug>`.",
                .{ text_utils.terminalSafe(slug), team_setting_key, slugs.written(), team_setting_key },
            );
        }
        return arena.print(
            "fx did not run this command: Vercel team `{f}` (from `{s}`) was not found, and no teams were listed for this login. Ask the person which team slug to use and run `fx config set {s} <slug>`.",
            .{ text_utils.terminalSafe(slug), team_setting_key, team_setting_key },
        );
    }
    if (limit > 0) {
        return arena.print(
            "fx did not run this command: no Vercel team is selected. Available teams: {s}. Ask the person which one to use and run `fx config set {s} <slug>`.",
            .{ slugs.written(), team_setting_key },
        );
    }
    return arena.print(
        "fx did not run this command: no Vercel team was found for this login. Ask the person which team slug to use and run `fx config set {s} <slug>`.",
        .{team_setting_key},
    );
}

fn projectCreateFailedText(arena: std.mem.Allocator, failure: vercel.Failure) std.mem.Allocator.Error![]const u8 {
    var buffer: [256]u8 = undefined;
    const detail: []const u8 = switch (failure.reason) {
        .status => |code| std.mem.print(&buffer, "HTTP {d}", .{code}) catch "HTTP error",
        else => vercel.describe(&buffer, failure),
    };
    return arena.print(
        "fx did not run this command: could not create project `{s}` ({s}). Ask the person for a project name and run `fx config set {s} <name>`.",
        .{ vercel.sandbox_project_name, detail, project_setting_key },
    );
}

pub fn settingsErrorText(arena: std.mem.Allocator, settings_path: []const u8, err: anyerror) std.mem.Allocator.Error![]const u8 {
    return arena.print(
        "fx did not run this command: could not read settings {f} ({s}). Fix it and try again.",
        .{ text_utils.terminalSafe(settings_path), @errorName(err) },
    );
}

fn workspaceRefusalText(arena: std.mem.Allocator, workspace_root: []const u8, err: anyerror) std.mem.Allocator.Error![]const u8 {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return arena.print(
        "fx did not run this command: the workspace folder {f} could not be resolved: {s}",
        .{ text_utils.terminalSafe(workspace_root), @errorName(err) },
    );
}

fn failureText(arena: std.mem.Allocator, failure: setup.StepFailure) std.mem.Allocator.Error![]const u8 {
    var buffer: [256]u8 = undefined;
    const detail: []const u8 = switch (failure.reason) {
        .api => |reason| vercel.describe(&buffer, .{ .step = failure.step, .reason = reason }),
        .bad_answer => try arena.print("{s}: the answer did not fit the question", .{failure.step}),
        .write_failed => try arena.print("{s}: the config could not be written", .{failure.step}),
        .write_lock_busy => try arena.print("{s}: config lock busy", .{failure.step}),
        .prompt_failed => try arena.print("{s}: the question could not be shown or answered", .{failure.step}),
    };
    return arena.print("{s}{s}", .{ e9_prefix, detail });
}

fn apiFailure(arena: std.mem.Allocator, failure: vercel.Failure) std.mem.Allocator.Error!Result {
    return .{ .refused = try refusalText(arena, .{ .setup_failed = .{ .step = failure.step, .reason = .{ .api = failure.reason } } }) };
}

fn trace(host: *const Host, comptime format: []const u8, args: anytype) void {
    var buffer: [256]u8 = undefined;
    const line = std.mem.print(&buffer, format, args) catch return;
    host.trace.write(line);
}

// --- Tests -----------------------------------------------------------------

const test_token = "fx-test-token";
const test_home = "/home/fx-test";
const test_unix_s: i64 = 1_800_000_000;
const test_awake_ms: i64 = 1_000_000;

fn fakeAwake(_: ?*anyopaque) i64 {
    return test_awake_ms;
}

fn fakeUnix(_: ?*anyopaque) i64 {
    return test_unix_s;
}

const fake_clock: Clock = .{ .awake_ms = fakeAwake, .unix_s = fakeUnix };

const rule_config = "{\"rules\": [{\"command\": \"zig build*\", \"runner\": \"remote\"}]}";

const user_plain_reply: test_server.Reply = .{ .body = "{\"user\":{\"id\":\"usr_1\"}}" };
const user_default_team_reply: test_server.Reply = .{ .body = "{\"user\":{\"id\":\"usr_1\",\"defaultTeamId\":\"team_def\"}}" };
const team_acme_reply: test_server.Reply = .{ .body = "{\"id\":\"team_1\",\"slug\":\"acme\",\"name\":\"Acme\"}" };
const team_def_reply: test_server.Reply = .{ .body = "{\"id\":\"team_def\",\"slug\":\"def-slug\",\"name\":\"Default Team\"}" };
const team_explicit_reply: test_server.Reply = .{ .body = "{\"id\":\"team_exp\",\"slug\":\"explicit-slug\",\"name\":\"Explicit Team\"}" };
const team_evil_reply: test_server.Reply = .{ .body = "{\"id\":\"team_1\",\"slug\":\"acme\",\"name\":\"evil\\u001b[2Jteam\"}" };
const teams_list_reply: test_server.Reply = .{
    .body = "{\"teams\":[{\"id\":\"team_1\",\"slug\":\"acme\",\"name\":\"Acme\"},{\"id\":\"team_2\",\"slug\":\"beta\",\"name\":\"Beta\"}],\"pagination\":{\"next\":null}}",
};
const project_sandbox_reply: test_server.Reply = .{ .body = "{\"id\":\"prj_sandbox\",\"name\":\"fx-sandbox\"}" };
const project_custom_reply: test_server.Reply = .{ .body = "{\"id\":\"prj_custom\",\"name\":\"my-proj\"}" };
const project_evil_reply: test_server.Reply = .{ .body = "{\"id\":\"prj_1\",\"name\":\"re\\u001b[2Jpo\"}" };
const not_found_reply: test_server.Reply = .{ .status = "404 Not Found", .body = "{}" };
const status_500: test_server.Reply = .{ .status = "500 Internal Server Error", .body = "" };
const status_401: test_server.Reply = .{ .status = "401 Unauthorized", .body = "{}" };

const accept_yes = "{\"action\":\"accept\",\"content\":{\"copy\":\"Yes\"}}";
const accept_no = "{\"action\":\"accept\",\"content\":{\"copy\":\"No\"}}";
const decline_reply = "{\"action\":\"decline\"}";

const Step = struct {
    answer: Answer,
    cancel_first: bool = false,
    gate: ?*std.Io.Event = null,

    const Answer = union(enum) {
        json: []const u8,
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
    before: ?*const fn (*Scripted) anyerror!void = null,
    asked: ?*std.Io.Event = null,
    next: usize = 0,
    prompts: usize = 0,
    saw_token: bool = false,
    saw_escape: bool = false,
    saw_evil: bool = false,
    wrong_origin: bool = false,
    last_message: [512]u8 = undefined,
    last_message_len: usize = 0,

    fn respond(context: *anyopaque, alloc: std.mem.Allocator, origin: tool_mcp_runtime.InputOrigin, required: tool_mcp_runtime.InputRequired) anyerror![]const u8 {
        const self: *Scripted = @ptrCast(@alignCast(context));
        self.prompts += 1;
        const json = required.input_requests_json;
        if (origin.kind != .host) self.wrong_origin = true;
        if (std.mem.find(u8, json, self.token) != null) self.saw_token = true;
        if (std.mem.find(u8, json, "\\u001b") != null) self.saw_escape = true;
        if (std.mem.find(u8, json, "evil") != null) self.saw_evil = true;
        if (std.json.parseFromSliceLeaky(std.json.Value, alloc, json, .{})) |root| {
            if (root.object.get(copy_key)) |req| {
                if (req.object.get("params")) |params| {
                    if (params.object.get("message")) |msg| {
                        const copy_len = @min(self.last_message.len, msg.string.len);
                        @memcpy(self.last_message[0..copy_len], msg.string[0..copy_len]);
                        self.last_message_len = copy_len;
                    }
                }
            }
        } else |_| {}
        if (self.asked) |event| event.set(io_mod.getIo());
        const step = self.steps[@min(self.next, self.steps.len - 1)];
        self.next += 1;
        if (step.cancel_first) self.cancel.store(true, .release);
        if (step.gate) |gate| try gate.waitTimeout(io_mod.getIo(), .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
        if (self.before) |hook| try hook(self);
        return switch (step.answer) {
            .json => |bytes| try keyedFor(alloc, json, bytes),
            .timed_out => error.McpInputTimedOut,
            .broken => error.QuestionFailed,
        };
    }

    fn lastMessage(self: *const Scripted) []const u8 {
        return self.last_message[0..self.last_message_len];
    }
};

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
    repo_a: []u8,
    repo_b: []u8,
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
        try self.tmp.dir.createDirPath(testing.io, "repo-a");
        try self.tmp.dir.createDirPath(testing.io, "repo-b");
        self.fx_home = try io_mod.dirRealpathAlloc(alloc, self.tmp.dir, "fxhome");
        errdefer alloc.free(self.fx_home);
        self.home_path = try io_mod.dirRealpathAlloc(alloc, self.tmp.dir, ".");
        errdefer alloc.free(self.home_path);
        self.repo_a = try io_mod.dirRealpathAlloc(alloc, self.tmp.dir, "repo-a");
        errdefer alloc.free(self.repo_a);
        self.repo_b = try io_mod.dirRealpathAlloc(alloc, self.tmp.dir, "repo-b");
        errdefer alloc.free(self.repo_b);
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
        self.alloc.free(self.repo_b);
        self.alloc.free(self.repo_a);
        self.alloc.free(self.home_path);
        self.alloc.free(self.fx_home);
        self.alloc.destroy(self);
    }

    fn writeCliLogin(self: *TestEnv, current_team: ?[]const u8) !void {
        try self.tmp.dir.createDirPath(testing.io, ".local/share/com.vercel.cli");
        try self.tmp.dir.writeFile(testing.io, .{
            .sub_path = ".local/share/com.vercel.cli/auth.json",
            .data = "{\"token\":\"" ++ test_token ++ "\"}",
        });
        if (current_team) |team| {
            var arena = std.heap.ArenaAllocator.init(self.alloc);
            defer arena.deinit();
            const body = try arena.allocator().print("{{\"currentTeam\":\"{s}\"}}", .{team});
            try self.tmp.dir.writeFile(testing.io, .{
                .sub_path = ".local/share/com.vercel.cli/config.json",
                .data = body,
            });
        }
        self.host.env = .{ .home = self.home_path };
    }

    fn call(self: *TestEnv, arena: std.mem.Allocator, repo: []const u8, intent: SetupIntent, key: ?[]const u8, turn: u64, allowed: bool, form: bool) Call {
        return callFor(arena, repo, intent, allowed, key, turn, if (form) self.responder else null, &self.cancel);
    }

    fn run(self: *TestEnv, arena: std.mem.Allocator, repo: []const u8, key: ?[]const u8, turn: u64) !Result {
        return ensureReady(&self.host, self.call(arena, repo, .{}, key, turn, true, true));
    }

    fn runWithIntent(self: *TestEnv, arena: std.mem.Allocator, repo: []const u8, intent: SetupIntent, key: ?[]const u8, turn: u64) !Result {
        return ensureReady(&self.host, self.call(arena, repo, intent, key, turn, true, true));
    }
};

fn readConfig(arena: std.mem.Allocator, dir: std.Io.Dir) ![]u8 {
    return dir.readFileAlloc(testing.io, "fxhome/sandbox/config.json", arena, .limited(64 * 1024));
}

fn consentExists(arena: std.mem.Allocator, env: *TestEnv, user_id: []const u8, repo: []const u8, team_id: []const u8, project_id: []const u8) !bool {
    const key = try consent.repoKey(arena, user_id, repo);
    return consent.hasForDestination(arena, env.fx_home, key, team_id, project_id);
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

test "team from CLI config resolves team and fx-sandbox, asks copy question once, writes config and consent" {
    const alloc = testing.allocator;
    const steps = [_]Step{.{ .answer = .{ .json = accept_yes } }};
    const env = try TestEnv.create(alloc, &.{ user_plain_reply, team_acme_reply, project_sandbox_reply }, &steps);
    defer env.destroy();
    try env.writeCliLogin("team_1");

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    try expectReady(try env.run(a, env.repo_a, "session-a", 5), "team_1", "prj_sandbox");
    try testing.expectEqual(@as(usize, 1), env.scripted.prompts);
    try testing.expect(std.mem.find(u8, env.scripted.lastMessage(), "Vercel team Acme, project fx-sandbox?") != null);
    try testing.expect(try consentExists(a, env, "usr_1", env.repo_a, "team_1", "prj_sandbox"));
    const cfg = try readConfig(a, env.tmp.dir);
    try testing.expect(std.mem.find(u8, cfg, "\"team_id\": \"team_1\"") != null);
    try testing.expectEqualStrings("GET /v2/teams/team_1 HTTP/1.1", env.server.line(1));
}

test "team from user defaultTeamId resolves when CLI config is absent" {
    const alloc = testing.allocator;
    const steps = [_]Step{.{ .answer = .{ .json = accept_yes } }};
    const env = try TestEnv.create(alloc, &.{ user_default_team_reply, team_def_reply, project_sandbox_reply }, &steps);
    defer env.destroy();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    try expectReady(try env.run(arena.allocator(), env.repo_a, "session-a", 5), "team_def", "prj_sandbox");
    try testing.expectEqualStrings("GET /v2/teams/team_def HTTP/1.1", env.server.line(1));
}

test "team from explicit slug overrides CLI config and defaultTeamId" {
    const alloc = testing.allocator;
    const steps = [_]Step{.{ .answer = .{ .json = accept_yes } }};
    const env = try TestEnv.create(alloc, &.{ user_default_team_reply, team_explicit_reply, project_sandbox_reply }, &steps);
    defer env.destroy();
    try env.writeCliLogin("team_1");

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const res = try env.runWithIntent(arena.allocator(), env.repo_a, .{ .team = "explicit-slug" }, "session-a", 5);
    try expectReady(res, "team_exp", "prj_sandbox");
    try testing.expectEqualStrings("GET /v2/teams/explicit-slug HTTP/1.1", env.server.line(1));
}

test "no team found refuses with up to 10 team slugs and fx config set fix" {
    const alloc = testing.allocator;
    const env = try TestEnv.create(alloc, &.{ user_plain_reply, teams_list_reply }, &.{});
    defer env.destroy();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const res = try env.run(arena.allocator(), env.repo_a, "session-a", 5);
    switch (res) {
        .refused => |text| {
            try testing.expect(std.mem.find(u8, text, "acme") != null);
            try testing.expect(std.mem.find(u8, text, "beta") != null);
            try testing.expect(std.mem.find(u8, text, "fx config set " ++ team_setting_key ++ " <slug>") != null);
        },
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(usize, 0), env.scripted.prompts);
}

test "explicit project exists uses it; missing explicit project refuses with project fix" {
    const alloc = testing.allocator;
    const steps = [_]Step{.{ .answer = .{ .json = accept_yes } }};
    const env = try TestEnv.create(alloc, &.{ user_default_team_reply, team_def_reply, project_custom_reply }, &steps);
    defer env.destroy();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const ok = try env.runWithIntent(arena.allocator(), env.repo_a, .{ .project = "my-proj" }, "session-a", 5);
    try expectReady(ok, "team_def", "prj_custom");

    const env_missing = try TestEnv.create(alloc, &.{ user_default_team_reply, team_def_reply, not_found_reply }, &.{});
    defer env_missing.destroy();
    const missing = try env_missing.runWithIntent(arena.allocator(), env_missing.repo_a, .{ .project = "missing-proj" }, "session-a", 5);
    switch (missing) {
        .refused => |text| {
            try testing.expect(std.mem.find(u8, text, "missing-proj") != null);
            try testing.expect(std.mem.find(u8, text, "fx config set " ++ project_setting_key ++ " <name>") != null);
        },
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(usize, 0), env_missing.scripted.prompts);
}

test "fx-sandbox missing asks copy question first, then creates after yes" {
    const alloc = testing.allocator;
    const steps = [_]Step{.{ .answer = .{ .json = accept_yes } }};
    const env = try TestEnv.create(alloc, &.{ user_default_team_reply, team_def_reply, not_found_reply, project_sandbox_reply }, &steps);
    defer env.destroy();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const res = try env.run(arena.allocator(), env.repo_a, "session-a", 5);
    try expectReady(res, "team_def", "prj_sandbox");
    try testing.expectEqual(@as(usize, 1), env.scripted.prompts);
    try testing.expectEqualStrings("POST /v11/projects?teamId=team_def HTTP/1.1", env.server.line(3));
}

test "fx-sandbox create failure refuses with HTTP status and project fix, writes nothing" {
    const alloc = testing.allocator;
    const steps = [_]Step{.{ .answer = .{ .json = accept_yes } }};
    const env = try TestEnv.create(alloc, &.{ user_default_team_reply, team_def_reply, not_found_reply, status_500 }, &steps);
    defer env.destroy();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const res = try env.run(arena.allocator(), env.repo_a, "session-a", 5);
    switch (res) {
        .refused => |text| {
            try testing.expect(std.mem.find(u8, text, "HTTP 500") != null);
            try testing.expect(std.mem.find(u8, text, "fx config set " ++ project_setting_key ++ " <name>") != null);
        },
        else => return error.TestUnexpectedResult,
    }
    try testing.expect(!try consentExists(arena.allocator(), env, "usr_1", env.repo_a, "team_def", "prj_sandbox"));
    try testing.expectError(error.FileNotFound, readConfig(arena.allocator(), env.tmp.dir));
}

test "decline creates nothing, writes no config or consent, and sets per-turn mark" {
    const alloc = testing.allocator;
    const steps = [_]Step{.{ .answer = .{ .json = accept_no } }};
    const env = try TestEnv.create(alloc, &.{ user_default_team_reply, team_def_reply, not_found_reply }, &steps);
    defer env.destroy();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    try expectRefused(try env.run(a, env.repo_a, "session-a", 5), e8_text);
    try testing.expectEqual(@as(usize, 1), env.scripted.prompts);
    try testing.expectEqual(setup.Mark.declined, env.slot.markFor("session-a", 5));
    try testing.expectError(error.FileNotFound, readConfig(a, env.tmp.dir));
    try testing.expect(!try consentExists(a, env, "usr_1", env.repo_a, "team_def", "prj_sandbox"));

    try expectRefused(try env.run(a, env.repo_a, "session-a", 5), e8_text);
    try testing.expectEqual(@as(usize, 1), env.scripted.prompts);
    try testing.expectEqual(@as(usize, 3), env.server.servedCount());
}

test "consent in repo A asks again in repo B, asks once for same repo and destination, and asks again on destination change" {
    const alloc = testing.allocator;
    const steps = [_]Step{
        .{ .answer = .{ .json = accept_yes } },
        .{ .answer = .{ .json = accept_yes } },
        .{ .answer = .{ .json = accept_yes } },
    };
    const env = try TestEnv.create(alloc, &.{
        user_default_team_reply,
        team_def_reply,
        project_sandbox_reply,
        // Repo B discovery:
        team_def_reply,
        project_sandbox_reply,
        // Destination change in Repo A:
        team_explicit_reply,
        project_sandbox_reply,
    }, &steps);
    defer env.destroy();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // First run in Repo A: asks once.
    try expectReady(try env.run(a, env.repo_a, "session-a", 5), "team_def", "prj_sandbox");
    try testing.expectEqual(@as(usize, 1), env.scripted.prompts);

    // Repeat in Repo A: no prompt.
    try expectReady(try env.run(a, env.repo_a, "session-a", 6), "team_def", "prj_sandbox");
    try testing.expectEqual(@as(usize, 1), env.scripted.prompts);

    // First run in Repo B: asks again.
    try expectReady(try env.run(a, env.repo_b, "session-a", 7), "team_def", "prj_sandbox");
    try testing.expectEqual(@as(usize, 2), env.scripted.prompts);

    // Destination change in Repo A: asks again.
    try expectReady(try env.runWithIntent(a, env.repo_a, .{ .team = "explicit-slug" }, "session-a", 8), "team_exp", "prj_sandbox");
    try testing.expectEqual(@as(usize, 3), env.scripted.prompts);
}

test "concurrent calls in the same repo ask once" {
    const alloc = testing.allocator;
    var asked: std.Io.Event = .unset;
    var gate: std.Io.Event = .unset;
    const steps = [_]Step{.{ .answer = .{ .json = accept_yes }, .gate = &gate }};
    const env = try TestEnv.create(alloc, &.{ user_default_team_reply, team_def_reply, project_sandbox_reply }, &steps);
    defer env.destroy();
    env.scripted.asked = &asked;

    var arena_a = std.heap.ArenaAllocator.init(alloc);
    defer arena_a.deinit();
    var arena_b = std.heap.ArenaAllocator.init(alloc);
    defer arena_b.deinit();

    var first: Runner = .{ .host = &env.host, .call = env.call(arena_a.allocator(), env.repo_a, .{}, "session-a", 5, true, true) };
    const thread_a = try std.Thread.spawn(.{}, Runner.run, .{&first});
    try asked.waitTimeout(io_mod.getIo(), .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });

    var second: Runner = .{ .host = &env.host, .call = env.call(arena_b.allocator(), env.repo_a, .{}, "session-b", 5, true, true) };
    const thread_b = try std.Thread.spawn(.{}, Runner.run, .{&second});
    gate.set(io_mod.getIo());
    thread_a.join();
    thread_b.join();

    try testing.expect(!first.failed and !second.failed);
    try expectReady(first.result orelse return error.TestUnexpectedResult, "team_def", "prj_sandbox");
    try expectReady(second.result orelse return error.TestUnexpectedResult, "team_def", "prj_sandbox");
    try testing.expectEqual(@as(usize, 1), env.scripted.prompts);
}

test "no channel refuses without prompt when no consent, and succeeds once consented" {
    const alloc = testing.allocator;
    const steps = [_]Step{.{ .answer = .{ .json = accept_yes } }};
    const env = try TestEnv.create(alloc, &.{ user_default_team_reply, team_def_reply, project_sandbox_reply }, &steps);
    defer env.destroy();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const headless_before = try ensureReady(&env.host, env.call(a, env.repo_a, .{}, "session-a", 5, true, false));
    try expectRefused(headless_before, e7_text);
    try testing.expectEqual(@as(usize, 0), env.scripted.prompts);

    try expectReady(try env.run(a, env.repo_a, "session-a", 5), "team_def", "prj_sandbox");
    const headless_after = try ensureReady(&env.host, env.call(a, env.repo_a, .{}, "session-a", 6, true, false));
    try expectReady(headless_after, "team_def", "prj_sandbox");
}

test "sub-agent refuses E10 without prompt when no consent, and succeeds once consented" {
    const alloc = testing.allocator;
    const steps = [_]Step{.{ .answer = .{ .json = accept_yes } }};
    const env = try TestEnv.create(alloc, &.{ user_default_team_reply, team_def_reply, project_sandbox_reply }, &steps);
    defer env.destroy();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const sub_before = try ensureReady(&env.host, env.call(a, env.repo_a, .{}, "session-a", 5, false, true));
    try expectRefused(sub_before, e10_text);
    try testing.expectEqual(@as(usize, 0), env.scripted.prompts);

    try expectReady(try env.run(a, env.repo_a, "session-a", 5), "team_def", "prj_sandbox");
    const sub_after = try ensureReady(&env.host, env.call(a, env.repo_a, .{}, "session-a", 6, false, true));
    try expectReady(sub_after, "team_def", "prj_sandbox");
}

test "cancel during the copy question writes nothing and sets no mark" {
    const alloc = testing.allocator;
    const steps = [_]Step{.{ .answer = .{ .json = decline_reply }, .cancel_first = true }};
    const env = try TestEnv.create(alloc, &.{ user_default_team_reply, team_def_reply, project_sandbox_reply }, &steps);
    defer env.destroy();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const result = try env.run(a, env.repo_a, "session-a", 5);
    try testing.expect(result == .canceled);
    try testing.expectEqual(setup.Mark.none, env.slot.markFor("session-a", 5));
    try testing.expectError(error.FileNotFound, readConfig(a, env.tmp.dir));
    try testing.expect(!try consentExists(a, env, "usr_1", env.repo_a, "team_def", "prj_sandbox"));
}

test "E5, E6, E14, E15, and terminal-safe outside text hold" {
    const alloc = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // E5
    const env_no_login = try TestEnv.create(alloc, &.{}, &.{});
    defer env_no_login.destroy();
    env_no_login.host.env = .{ .home = env_no_login.home_path };
    try expectRefused(try env_no_login.run(a, env_no_login.repo_a, "session-a", 5), e5_text);

    // E6
    const env_rejected = try TestEnv.create(alloc, &.{status_401}, &.{});
    defer env_rejected.destroy();
    try expectRefused(try env_rejected.run(a, env_rejected.repo_a, "session-a", 5), e6_text);

    // E15
    const timeout_steps = [_]Step{.{ .answer = .timed_out }};
    const env_timeout = try TestEnv.create(alloc, &.{ user_default_team_reply, team_def_reply, project_sandbox_reply }, &timeout_steps);
    defer env_timeout.destroy();
    try expectRefused(try env_timeout.run(a, env_timeout.repo_a, "session-a", 5), e15_text);
    try testing.expectEqual(setup.Mark.no_answer, env_timeout.slot.markFor("session-a", 5));

    // E14
    const rule_steps = [_]Step{.{ .answer = .{ .json = accept_yes } }};
    const env_rule = try TestEnv.create(alloc, &.{ user_default_team_reply, team_def_reply, project_sandbox_reply }, &rule_steps);
    defer env_rule.destroy();
    env_rule.scripted.before = addRule;
    try expectRefused(try env_rule.run(a, env_rule.repo_a, "session-a", 5), e14_text);
    try testing.expect(!try consentExists(a, env_rule, "usr_1", env_rule.repo_a, "team_def", "prj_sandbox"));

    // Terminal-safe + token leak check
    const leak_token = "fx-leak-token-7f3a91";
    const evil_steps = [_]Step{.{ .answer = .{ .json = accept_yes } }};
    const env_evil = try TestEnv.create(alloc, &.{ user_default_team_reply, team_evil_reply, project_evil_reply }, &evil_steps);
    defer env_evil.destroy();
    env_evil.host.env = .{ .vercel_token = leak_token, .home = env_evil.home_path };
    env_evil.scripted.token = leak_token;
    try expectReady(try env_evil.run(a, env_evil.repo_a, "session-a", 5), "team_1", "prj_1");
    try testing.expect(!env_evil.scripted.saw_escape);
    try testing.expect(env_evil.scripted.saw_evil);
    try testing.expect(!env_evil.scripted.saw_token);
    try testing.expect(std.mem.find(u8, env_evil.capture.captured(), leak_token) == null);
}

test "unset project goes back to fx-sandbox and asks again, and same effective values make no REST call" {
    const alloc = testing.allocator;
    const steps = [_]Step{
        .{ .answer = .{ .json = accept_yes } },
        .{ .answer = .{ .json = accept_yes } },
    };
    const env = try TestEnv.create(alloc, &.{
        user_default_team_reply,
        team_def_reply,
        project_custom_reply,
        // After unsetting sandbox_project, fresh discovery checks team_def and fx-sandbox:
        team_def_reply,
        project_sandbox_reply,
    }, &steps);
    defer env.destroy();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // 1. Setup with explicit project "my-proj".
    try expectReady(try env.runWithIntent(a, env.repo_a, .{ .project = "my-proj" }, "session-a", 5), "team_def", "prj_custom");
    try testing.expectEqual(@as(usize, 1), env.scripted.prompts);

    // 2. Same effective values ask nothing and make no extra REST call.
    const before_repeat = env.server.servedCount();
    try expectReady(try env.runWithIntent(a, env.repo_a, .{ .project = "my-proj" }, "session-a", 6), "team_def", "prj_custom");
    try testing.expectEqual(@as(usize, 1), env.scripted.prompts);
    try testing.expectEqual(before_repeat, env.server.servedCount());

    // 3. Unsetting project falls back to fx-sandbox and asks again.
    try expectReady(try env.run(a, env.repo_a, "session-a", 7), "team_def", "prj_sandbox");
    try testing.expectEqual(@as(usize, 2), env.scripted.prompts);
    try testing.expect(std.mem.find(u8, env.scripted.lastMessage(), "project fx-sandbox?") != null);
}

test "a Vercel CLI currentTeam change asks again for the new team" {
    const alloc = testing.allocator;
    const steps = [_]Step{
        .{ .answer = .{ .json = accept_yes } },
        .{ .answer = .{ .json = accept_yes } },
    };
    const env = try TestEnv.create(alloc, &.{
        user_plain_reply,
        team_acme_reply,
        project_sandbox_reply,
        // After switching CLI currentTeam to team_exp:
        team_explicit_reply,
        project_sandbox_reply,
    }, &steps);
    defer env.destroy();
    try env.writeCliLogin("team_1");

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    try expectReady(try env.run(a, env.repo_a, "session-a", 5), "team_1", "prj_sandbox");
    try testing.expectEqual(@as(usize, 1), env.scripted.prompts);

    // Switch CLI currentTeam to team_exp; next run must ask for team_exp.
    try env.writeCliLogin("team_exp");
    try expectReady(try env.run(a, env.repo_a, "session-a", 6), "team_exp", "prj_sandbox");
    try testing.expectEqual(@as(usize, 2), env.scripted.prompts);
    try testing.expect(std.mem.find(u8, env.scripted.lastMessage(), "Vercel team Explicit Team, project fx-sandbox?") != null);
}
