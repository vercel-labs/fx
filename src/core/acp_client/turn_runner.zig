const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");

const active_turn_mod = @import("active_turn.zig");
const acp_runtime = @import("runtime.zig");

const Allocator = std.mem.Allocator;
pub const ActiveTurn = active_turn_mod.ActiveTurn;

/// Host surface the runner needs. Both callbacks are invoked from turn-owned
/// threads (the reader thread for updates, a permission worker for approvals)
/// and must be internally synchronized by the host.
pub const Host = struct {
    ctx: *anyopaque,
    /// Streams one agent update (message chunk or tool line) to the UI.
    report_update: *const fn (ctx: *anyopaque, agent_name: []const u8, update_text: []const u8) void,
    /// Interactive approval for the agent's session/request_permission call.
    /// Returns the agent optionId to select, or an empty slice to reject.
    request_permission: *const fn (ctx: *anyopaque, agent_name: []const u8, request_json: []const u8) []const u8,
    /// Working directory passed to the agent session.
    cwd: []const u8,
};

// Generous handshake window: an npx-launched agent may download its package
// on first start.
const initialize_timeout_ms: u32 = 60_000;
const prompt_timeout_ms: u32 = 10 * 60 * 1000;

/// Host-owned store keeping one ACP agent session (process + ACP session)
/// alive across turns so consecutive prompts share context instead of cold
/// starting. Thread-safe; turns and warmups claim it via `tryClaim`.
pub const SessionStore = struct {
    mutex: std.Io.Mutex = .init,
    session: ?*PersistentSession = null,
    busy: bool = false,

    /// Shuts down any live agent session. UI-thread, app shutdown only.
    /// When a worker still holds the claim the session is intentionally
    /// leaked: process exit reaps the agent, and destroying it here would
    /// free memory that worker is using.
    pub fn deinit(self: *SessionStore) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        const claimed = self.busy;
        const session = if (claimed) null else self.session;
        if (!claimed) self.session = null;
        self.mutex.unlock(zio);
        if (session) |live| live.destroy();
    }

    fn tryClaim(self: *SessionStore) bool {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        if (self.busy) return false;
        self.busy = true;
        return true;
    }

    fn release(self: *SessionStore) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        self.busy = false;
    }

    fn take(self: *SessionStore) ?*PersistentSession {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        const session = self.session;
        self.session = null;
        return session;
    }

    fn put(self: *SessionStore, session: *PersistentSession) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        std.debug.assert(self.session == null);
        self.session = session;
    }
};

/// One live agent connection owned by the SessionStore. The bridge is heap
/// allocated because the client's reader thread calls into it for the whole
/// session lifetime, across many turns.
const PersistentSession = struct {
    alloc: Allocator,
    client: *acp_runtime.Client,
    bridge: *SharedBridge,
    agent_name: []u8,
    cwd: []u8,
    current_model: ?[]u8 = null,
    current_effort: ?[]u8 = null,

    fn destroy(self: *PersistentSession) void {
        // Client teardown joins the reader thread; only then is the bridge
        // safe to free.
        self.client.deinit();
        self.alloc.destroy(self.bridge);
        self.alloc.free(self.agent_name);
        self.alloc.free(self.cwd);
        if (self.current_model) |value| self.alloc.free(value);
        if (self.current_effort) |value| self.alloc.free(value);
        self.alloc.destroy(self);
    }
};

/// Session-lifetime callback target. Updates route to the currently attached
/// turn; between turns they are dropped.
const SharedBridge = struct {
    alloc: Allocator,
    host: Host,
    mutex: std.Io.Mutex = .init,
    turn: ?*ActiveTurn = null,

    fn attach(self: *SharedBridge, turn: *ActiveTurn) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        self.turn = turn;
    }

    fn detach(self: *SharedBridge) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        self.turn = null;
    }

    fn currentTurn(self: *SharedBridge) ?*ActiveTurn {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        return self.turn;
    }

    /// Reader-thread callback: stream updates to the UI. Only agent message
    /// text streams; tool calls, thoughts, and plan updates stay silent so
    /// the transcript reads like a normal provider reply.
    fn onUpdate(ctx: *anyopaque, cb_arena: Allocator, update: acp_runtime.Update) void {
        _ = cb_arena;
        const bridge: *SharedBridge = @ptrCast(@alignCast(ctx));
        const turn = bridge.currentTurn() orelse return;
        switch (update) {
            .agent_message => |message| turn.appendUpdate(message),
            .agent_thought, .user_message, .tool_call, .tool_call_update, .plan, .mode_change, .raw => {},
        }
    }

    /// Permission-worker callback: ask the host, then map the decision to
    /// the agent's own optionIds.
    fn onPermission(ctx: *anyopaque, cb_arena: Allocator, request_json: []const u8) acp_runtime.PermissionOutcome {
        const bridge: *SharedBridge = @ptrCast(@alignCast(ctx));
        const turn = bridge.currentTurn() orelse return .{ .cancelled = {} };
        const decision = bridge.host.request_permission(
            bridge.host.ctx,
            turn.agent_name,
            request_json,
        );
        if (decision.len == 0) return .{ .cancelled = {} };
        // The host returns a semantic decision ("allow" or "reject");
        // resolve it against the agent's offered optionIds.
        const parsed = parsePermissionRequest(cb_arena, request_json) catch
            return .{ .cancelled = {} };
        const wanted: acp_runtime.PermissionOptionKind = if (std.mem.eql(u8, decision, "allow"))
            .allow
        else
            .reject;
        const option_id = parsed.optionIdForKind(wanted) orelse
            return .{ .cancelled = {} };
        return .{ .selected = cb_arena.dupe(u8, option_id) catch return .{ .cancelled = {} } };
    }
};

/// Returns the live session for `config.name`, reusing it when healthy and
/// (re)connecting otherwise. Caller must hold the store claim.
fn acquireSession(
    store: *SessionStore,
    alloc: Allocator,
    config: acp_runtime.AgentConfig,
    host: Host,
) acp_runtime.AcpError!*PersistentSession {
    if (store.take()) |existing| {
        if (std.ascii.eqlIgnoreCase(existing.agent_name, config.name) and existing.client.isAlive()) {
            store.put(existing);
            return existing;
        }
        existing.destroy();
    }

    const session = alloc.create(PersistentSession) catch return error.AcpSpawnFailed;
    errdefer alloc.destroy(session);
    const bridge = alloc.create(SharedBridge) catch return error.AcpSpawnFailed;
    errdefer alloc.destroy(bridge);
    const agent_name = alloc.dupe(u8, config.name) catch return error.AcpSpawnFailed;
    errdefer alloc.free(agent_name);
    const cwd = alloc.dupe(u8, host.cwd) catch return error.AcpSpawnFailed;
    errdefer alloc.free(cwd);
    bridge.* = .{ .alloc = alloc, .host = host };
    bridge.host.cwd = cwd;

    const client = try acp_runtime.Client.create(alloc, alloc, config, .{
        .ctx = @ptrCast(bridge),
        .on_update = SharedBridge.onUpdate,
        .on_permission = SharedBridge.onPermission,
    });
    errdefer client.deinit();
    try client.start(cwd, initialize_timeout_ms);

    session.* = .{
        .alloc = alloc,
        .client = client,
        .bridge = bridge,
        .agent_name = agent_name,
        .cwd = cwd,
    };
    store.put(session);
    return session;
}

/// Drops `session` from the store and tears it down. Claim must be held.
fn dropSession(store: *SessionStore, session: *PersistentSession) void {
    if (store.take()) |stored| {
        std.debug.assert(stored == session);
    }
    session.destroy();
}

/// Connects an agent in the background so its models are cached in
/// ~/.fx/acp.json and the session is warm before the first prompt. Fire and
/// forget: failures only trace.
pub fn startWarmup(
    alloc: Allocator,
    store: *SessionStore,
    agent_config: acp_runtime.AgentConfig,
    host: Host,
    config_path: []const u8,
) !void {
    const acp_config = @import("config.zig");
    const Job = struct {
        alloc: Allocator,
        store: *SessionStore,
        agent_config: acp_runtime.AgentConfig,
        host: Host,
        config_path: []u8,

        fn run(self: *@This()) void {
            defer {
                freeAgentConfig(self.alloc, self.agent_config);
                self.alloc.free(self.host.cwd);
                self.alloc.free(self.config_path);
                self.alloc.destroy(self);
            }
            if (!self.store.tryClaim()) return;
            defer self.store.release();
            const session = acquireSession(self.store, self.alloc, self.agent_config, self.host) catch |err| {
                debug_trace.logf("acp", "warmup failed agent={s} err={s}", .{ self.agent_config.name, @errorName(err) });
                return;
            };
            acp_config.updateAgentModels(
                self.alloc,
                self.config_path,
                session.agent_name,
                session.client.modelValues(),
                session.client.effortValues(),
            ) catch |err| {
                debug_trace.logf("acp", "warmup model cache failed err={s}", .{@errorName(err)});
            };
            debug_trace.logf("acp", "warmup complete agent={s} models={d}", .{
                session.agent_name,
                session.client.modelValues().len,
            });
        }
    };

    const job = try alloc.create(Job);
    errdefer alloc.destroy(job);
    job.* = .{
        .alloc = alloc,
        .store = store,
        .agent_config = try dupeAgentConfig(alloc, agent_config),
        .host = host,
        .config_path = try alloc.dupe(u8, config_path),
    };
    errdefer {
        freeAgentConfig(alloc, job.agent_config);
        alloc.free(job.config_path);
    }
    job.host.cwd = try alloc.dupe(u8, host.cwd);
    const thread = std.Thread.spawn(.{}, Job.run, .{job}) catch |err| {
        freeAgentConfig(alloc, job.agent_config);
        alloc.free(job.config_path);
        alloc.free(job.host.cwd);
        alloc.destroy(job);
        return err;
    };
    thread.detach();
}

/// Runs one agent turn on a new thread and returns immediately. The host
/// drains `ActiveTurn` from its UI tick until `finished` is set, then frees
/// the turn with `deinit` (which joins the thread).
pub fn startAgentTurn(
    alloc: Allocator,
    store: *SessionStore,
    agent_config: acp_runtime.AgentConfig,
    prompt_text: []const u8,
    model: ?[]const u8,
    effort: ?[]const u8,
    host: Host,
) !*ActiveTurn {
    const turn = try ActiveTurn.init(alloc, agent_config.name);
    errdefer turn.deinit();

    const RunJob = struct {
        turn: *ActiveTurn,
        alloc: Allocator,
        store: *SessionStore,
        agent_config: acp_runtime.AgentConfig,
        prompt_text: []u8,
        model: ?[]u8,
        effort: ?[]u8,
        host: Host,

        fn run(self: *@This()) void {
            defer {
                self.alloc.free(self.prompt_text);
                if (self.model) |value| self.alloc.free(value);
                if (self.effort) |value| self.alloc.free(value);
                freeAgentConfig(self.alloc, self.agent_config);
                self.alloc.free(self.host.cwd);
                self.alloc.destroy(self);
            }
            runTurn(self.turn, self.alloc, self.store, self.agent_config, self.prompt_text, self.model, self.effort, self.host);
        }
    };

    // Strings must outlive the caller's frame; the job owns copies.
    const job = try alloc.create(RunJob);
    errdefer alloc.destroy(job);
    job.* = .{
        .turn = turn,
        .alloc = alloc,
        .store = store,
        .agent_config = try dupeAgentConfig(alloc, agent_config),
        .prompt_text = try alloc.dupe(u8, prompt_text),
        .model = if (model) |value| try alloc.dupe(u8, value) else null,
        .effort = null,
        .host = host,
    };
    errdefer {
        freeAgentConfig(alloc, job.agent_config);
        alloc.free(job.prompt_text);
        if (job.model) |value| alloc.free(value);
        if (job.effort) |value| alloc.free(value);
    }
    if (effort) |value| job.effort = try alloc.dupe(u8, value);
    job.host.cwd = try alloc.dupe(u8, host.cwd);
    turn.turn_thread = std.Thread.spawn(.{}, RunJob.run, .{job}) catch |err| {
        freeAgentConfig(alloc, job.agent_config);
        alloc.free(job.prompt_text);
        if (job.model) |value| alloc.free(value);
        if (job.effort) |value| alloc.free(value);
        alloc.free(job.host.cwd);
        alloc.destroy(job);
        return err;
    };
    return turn;
}

fn dupeAgentConfig(alloc: Allocator, config: acp_runtime.AgentConfig) !acp_runtime.AgentConfig {
    const name = try alloc.dupe(u8, config.name);
    errdefer alloc.free(name);
    const command = try alloc.dupe(u8, config.command);
    errdefer alloc.free(command);
    const args = try dupeStringSlice(alloc, config.args);
    errdefer freeStringSlice(alloc, args);
    const env = try dupeStringSlice(alloc, config.env);
    return .{ .name = name, .command = command, .args = args, .env = env };
}

fn freeAgentConfig(alloc: Allocator, config: acp_runtime.AgentConfig) void {
    alloc.free(config.name);
    alloc.free(config.command);
    freeStringSlice(alloc, config.args);
    freeStringSlice(alloc, config.env);
}

fn dupeStringSlice(alloc: Allocator, values: []const []const u8) ![]const []const u8 {
    const copies = try alloc.alloc([]const u8, values.len);
    var filled: usize = 0;
    errdefer {
        for (copies[0..filled]) |copy| alloc.free(copy);
        alloc.free(copies);
    }
    for (values) |value| {
        copies[filled] = try alloc.dupe(u8, value);
        filled += 1;
    }
    return copies;
}

fn freeStringSlice(alloc: Allocator, values: []const []const u8) void {
    for (values) |value| alloc.free(value);
    alloc.free(values);
}

fn runTurn(
    turn: *ActiveTurn,
    alloc: Allocator,
    store: *SessionStore,
    config: acp_runtime.AgentConfig,
    prompt_text: []const u8,
    model: ?[]const u8,
    effort: ?[]const u8,
    host: Host,
) void {
    if (!store.tryClaim()) {
        turn.finishWithFailure(alloc.dupe(u8, "An ACP agent turn is already running; wait for it to finish.") catch return);
        return;
    }
    defer store.release();

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const session = acquireSession(store, alloc, config, host) catch |err| {
        debug_trace.logf("acp", "session acquire failed agent={s} err={s}", .{ config.name, @errorName(err) });
        turn.finishWithFailure(failureText(alloc, "agent connection failed", err) catch return);
        return;
    };

    debug_trace.logf("acp", "prompt sending len={d}", .{prompt_text.len});
    const result = promptOnSession(turn, alloc, arena, session, prompt_text, model, effort);
    const outcome = result catch |err| {
        debug_trace.logf("acp", "prompt failed err={s}", .{@errorName(err)});
        // A dead connection is not reusable: drop it so the next turn
        // reconnects instead of failing forever.
        if (!session.client.isAlive()) dropSession(store, session);
        if (turn.cancelRequestedTurnThread()) {
            turn.finishWithFailure(alloc.dupe(u8, "ACP agent turn interrupted.") catch return);
            return;
        }
        turn.finishWithFailure(failureText(alloc, "agent turn failed", err) catch return);
        return;
    };
    debug_trace.logf("acp", "prompt outcome stop_reason={s}", .{outcome.stop_reason});

    const summary = std.fmt.allocPrint(
        alloc,
        "ACP agent {s} finished ({s}).",
        .{ config.name, outcome.stop_reason },
    ) catch null;
    const models = dupeModels(alloc, session.client.modelValues()) catch &.{};
    const efforts = dupeModels(alloc, session.client.effortValues()) catch &.{};
    turn.finishWithOutcome(summary orelse "", models, efforts);
}

/// One prompt on a live session: attaches the turn to the session bridge,
/// applies a model change if requested, and blocks until the stop reason.
/// Bridge and cancel hooks are detached before returning so the session
/// never references this turn's stack.
fn promptOnSession(
    turn: *ActiveTurn,
    alloc: Allocator,
    arena: Allocator,
    session: *PersistentSession,
    prompt_text: []const u8,
    model: ?[]const u8,
    effort: ?[]const u8,
) acp_runtime.AcpError!acp_runtime.PromptOutcome {
    session.bridge.attach(turn);
    defer session.bridge.detach();

    // Escape during a turn sends session/cancel and fails the pending request.
    var cancel_watch = CancelWatch{ .turn = turn, .client = session.client };
    session.client.cancel_check = CancelWatch.hook;
    session.client.cancel_check_ctx = @ptrCast(&cancel_watch);
    defer {
        session.client.cancel_check = null;
        session.client.cancel_check_ctx = null;
    }

    if (model) |value| {
        const unchanged = if (session.current_model) |current|
            std.mem.eql(u8, current, value)
        else
            false;
        if (!unchanged) {
            if (session.client.setModel(value, initialize_timeout_ms)) {
                const copy = alloc.dupe(u8, value) catch null;
                if (copy) |owned| {
                    if (session.current_model) |old| alloc.free(old);
                    session.current_model = owned;
                }
            } else |err| {
                debug_trace.logf("acp", "set model failed value={s} err={s}", .{ value, @errorName(err) });
            }
        }
    }

    if (effort) |value| {
        const unchanged = if (session.current_effort) |current|
            std.mem.eql(u8, current, value)
        else
            false;
        if (!unchanged) {
            if (session.client.setEffort(value, initialize_timeout_ms)) {
                const copy = alloc.dupe(u8, value) catch null;
                if (copy) |owned| {
                    if (session.current_effort) |old| alloc.free(old);
                    session.current_effort = owned;
                }
            } else |err| {
                debug_trace.logf("acp", "set effort failed value={s} err={s}", .{ value, @errorName(err) });
            }
        }
    }

    return session.client.prompt(arena, prompt_text, prompt_timeout_ms);
}

/// Client cancel hook: forwards the UI's cancel request as session/cancel so
/// a responsive agent stops promptly instead of at the prompt timeout.
const CancelWatch = struct {
    turn: *ActiveTurn,
    client: *acp_runtime.Client,

    fn hook(ctx: ?*anyopaque) void {
        const watch: *CancelWatch = @ptrCast(@alignCast(ctx orelse return));
        if (watch.turn.cancelRequestedTurnThread()) watch.client.cancel();
    }
};

fn dupeModels(alloc: Allocator, models: []const []const u8) ![]const []const u8 {
    const dupes = try alloc.alloc([]const u8, models.len);
    errdefer alloc.free(dupes);
    for (models, 0..) |model, i| dupes[i] = try alloc.dupe(u8, model);
    return @as([]const []const u8, dupes);
}

fn failureText(alloc: Allocator, context: []const u8, err: anyerror) ![]u8 {
    return std.fmt.allocPrint(alloc, "ACP agent {s}: {s}.", .{ context, @errorName(err) });
}

/// Parsed session/request_permission params. Option kinds map from the ACP
/// schema's `kind` strings.
pub const ParsedPermissionRequest = struct {
    title: ?[]const u8 = null,
    options: []Option = &.{},

    pub const Option = struct {
        option_id: []const u8,
        kind: acp_runtime.PermissionOptionKind,
    };

    pub fn optionIdForKind(self: ParsedPermissionRequest, kind: acp_runtime.PermissionOptionKind) ?[]const u8 {
        for (self.options) |option| {
            if (option.kind == kind) return option.option_id;
        }
        return null;
    }
};

pub fn parsePermissionRequest(arena: Allocator, request_json: []const u8) !ParsedPermissionRequest {
    var parsed = std.json.parseFromSlice(std.json.Value, arena, request_json, .{}) catch
        return error.AcpProtocolError;
    defer parsed.deinit();
    if (parsed.value != .object) return error.AcpProtocolError;

    var result = ParsedPermissionRequest{};

    if (parsed.value.object.get("title")) |title_value| {
        if (title_value == .string and title_value.string.len > 0) result.title = title_value.string;
    }

    const options_value = parsed.value.object.get("options") orelse return result;
    if (options_value != .array) return result;

    var options: std.ArrayList(ParsedPermissionRequest.Option) = .empty;
    for (options_value.array.items) |option_value| {
        if (option_value != .object) continue;
        const option_id_value = option_value.object.get("optionId") orelse continue;
        if (option_id_value != .string) continue;
        const kind_value = option_value.object.get("kind") orelse continue;
        if (kind_value != .string) continue;
        const kind: acp_runtime.PermissionOptionKind = if (std.mem.eql(u8, kind_value.string, "allow_once"))
            .allow
        else if (std.mem.eql(u8, kind_value.string, "allow_always"))
            .allow
        else if (std.mem.eql(u8, kind_value.string, "reject_once"))
            .reject
        else if (std.mem.eql(u8, kind_value.string, "reject_always"))
            .reject
        else
            continue;
        try options.append(arena, .{
            .option_id = try arena.dupe(u8, option_id_value.string),
            .kind = kind,
        });
    }
    result.options = try options.toOwnedSlice(arena);
    return result;
}

test "parsePermissionRequest extracts title and option kinds" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const request_json =
        \\{"sessionId":"s","title":"Run rm -rf /tmp/x","options":[
        \\  {"optionId":"opt-allow","name":"Allow","kind":"allow_once"},
        \\  {"optionId":"opt-reject","name":"Reject","kind":"reject_once"}]}
    ;
    const parsed = try parsePermissionRequest(arena, request_json);
    try std.testing.expectEqualStrings("Run rm -rf /tmp/x", parsed.title.?);
    try std.testing.expectEqual(@as(usize, 2), parsed.options.len);
    try std.testing.expectEqualStrings("opt-allow", parsed.optionIdForKind(.allow).?);
    try std.testing.expectEqualStrings("opt-reject", parsed.optionIdForKind(.reject).?);
    try std.testing.expect(parsed.optionIdForKind(.allow) != null);
}

test "parsePermissionRequest tolerates missing options" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try parsePermissionRequest(arena, "{\"sessionId\":\"s\"}");
    try std.testing.expect(parsed.title == null);
    try std.testing.expectEqual(@as(usize, 0), parsed.options.len);
    try std.testing.expect(parsed.optionIdForKind(.allow) == null);
}
