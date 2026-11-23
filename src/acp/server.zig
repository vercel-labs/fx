const std = @import("std");
const builtin = @import("builtin");
const testing_allocator = @import("../core/shared/testing_allocator.zig");
const managed_execution = @import("../core/execution/managed_execution.zig");
const acp_runner = @import("../core/cli/acp_runner.zig");
const config_runtime = @import("../core/config/config_runtime.zig");
const io_mod = @import("../core/shared/io.zig");
const host_target = @import("../core/hosts/target.zig");
const jsonrpc = @import("jsonrpc.zig");
const acp_types = @import("types.zig");
const sessions = @import("sessions.zig");
const leader_mod = @import("leader.zig");
const prompt_handler = @import("prompt.zig");
const prompt_test_controls = @import("prompt_test_controls.zig");
const app_lifecycle = @import("../core/app/app_lifecycle.zig");
const app_runtime_setup = @import("../core/app/app_runtime_setup.zig");
const compactor = @import("../core/compactor/compactor.zig");
const builtin_skills = @import("../builtins/skills.zig");
const builtin_tools = @import("../builtins/tools.zig");
const credentials = @import("../core/auth/credentials.zig");
const secret = @import("../core/auth/secret.zig");
const auth_runtime = @import("../core/auth/auth_runtime.zig");
const model_provider = @import("../core/config/model_provider.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const token_pass = @import("../core/gateway/token_pass.zig");
const token_pass_check = @import("../core/app/token_pass_check.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const model_capabilities = @import("../core/config/model_capabilities.zig");
const hooks = @import("../core/hooks/hooks.zig");
const mcp_host = @import("../core/mcp_host/host.zig");
const mode_registry = @import("../core/modes/mode_registry.zig");
const skill_runtime = @import("../core/skills/skill_runtime.zig");
const session_codec = @import("../core/session/session_codec.zig");
const session_log = @import("../core/session/session_log.zig");
const session_store = @import("../core/session/session_store.zig");
const session_adapter = @import("../core/session/session_adapter.zig");
const turn_capture = @import("../core/workspace/turn_capture.zig");
const session_runtime = @import("../core/session/session.zig");
const session_title_generation = @import("../core/session/session_title_generation.zig");
const worker_runtime = @import("../core/agent/worker_runtime.zig");
const terminal_client_runtime = @import("../core/terminal/client.zig");
const subagent_tool_host = @import("../core/subagent/tool_host.zig");
const subagent_reports = @import("../core/subagent/reports.zig");
const subagent_child_state = @import("../core/subagent/child_state.zig");
const subagent_authority = @import("../core/subagent/authority.zig");
const types = @import("../core/shared/types.zig");
const context_contract = @import("../core/workspace/context_contract.zig");
const workspace_access = @import("../core/workspace/workspace_access.zig");
const web_fetch_runtime = @import("../core/tooling/web_fetch_runtime.zig");
const web_search_runtime = @import("../core/tooling/web_search_runtime.zig");
const elicitation = @import("../core/mcp/elicitation.zig");
const tool_mcp_runtime = @import("../core/tooling/tool_mcp_runtime.zig");
const permissions = @import("../core/permissions/permissions.zig");
const host_tool_runtime = @import("../core/tooling/host_tool_runtime.zig");
const tool_dispatch = @import("../core/tooling/tool_dispatch.zig");
const agent_checkpoint = @import("../core/agent/runtime/checkpoint.zig");
const host_attachments = @import("../core/hosts/host_attachments.zig");
const image_attachments = @import("../core/images/image_attachments.zig");
const libfx_steering = @import("libfx_steering.zig");
const prompt_line = @import("prompt_line.zig");
const connection = @import("connection.zig");
const journal_events = @import("../core/agent/runtime/journal.zig");
const libfx_journal = @import("libfx_journal.zig");
const sh_fx = @import("sh_fx.zig");
const tool_call_identities = @import("tool_call_identities.zig");
const workspace_binding = @import("workspace_binding.zig");
const process_host = @import("process_host/process_host.zig");

const Allocator = std.mem.Allocator;
const ErrorCode = jsonrpc.ErrorCode;
const writeJsonStr = jsonrpc.writeJsonStr;
const legacy_url_completion_timeout_ms: i64 = 10 * 60 * 1000;
const libfx_provider_tools = [_]tool_dispatch.Tool{
    host_tool_runtime.providerProjection(builtin_tools.web_search),
};
const libfx_provider_tool_registry = tool_dispatch.Registry{ .tools = &libfx_provider_tools };

const AcpMethod = enum {
    request_cancel,
    initialize,
    session_cancel,
    session_new,
    session_load,
    session_resume,
    session_close,
    session_list,
    session_delete,
    session_prompt,
    session_set_config_option,
    session_set_mode,
    libfx_checkpoint,
    libfx_restore,
    libfx_new,
    libfx_steer,
    libfx_withdraw,
    libfx_handoff,
    libfx_follow_up,
    libfx_snapshot,
    libfx_journal_open,
    libfx_journal_images,
    mcp_message,
    unknown,

    fn parse(method: []const u8) AcpMethod {
        if (std.mem.eql(u8, method, "$/cancel_request")) return .request_cancel;
        if (std.mem.eql(u8, method, "initialize")) return .initialize;
        if (std.mem.eql(u8, method, "session/cancel")) return .session_cancel;
        if (std.mem.eql(u8, method, "session/new")) return .session_new;
        if (std.mem.eql(u8, method, "session/load")) return .session_load;
        if (std.mem.eql(u8, method, "session/resume")) return .session_resume;
        if (std.mem.eql(u8, method, "session/close")) return .session_close;
        if (std.mem.eql(u8, method, "session/list")) return .session_list;
        if (std.mem.eql(u8, method, "session/delete")) return .session_delete;
        if (std.mem.eql(u8, method, "session/prompt")) return .session_prompt;
        if (std.mem.eql(u8, method, "session/set_config_option")) return .session_set_config_option;
        if (std.mem.eql(u8, method, "session/set_mode")) return .session_set_mode;
        if (std.mem.eql(u8, method, sh_fx.method.session_checkpoint)) return .libfx_checkpoint;
        if (std.mem.eql(u8, method, sh_fx.method.session_restore)) return .libfx_restore;
        if (std.mem.eql(u8, method, sh_fx.method.session_new)) return .libfx_new;
        if (std.mem.eql(u8, method, sh_fx.method.session_steer)) return .libfx_steer;
        if (std.mem.eql(u8, method, sh_fx.method.session_withdraw_steer)) return .libfx_withdraw;
        if (std.mem.eql(u8, method, sh_fx.method.session_end_turn_for_steer)) return .libfx_handoff;
        if (std.mem.eql(u8, method, sh_fx.method.session_follow_up)) return .libfx_follow_up;
        if (std.mem.eql(u8, method, sh_fx.method.journal_snapshot)) return .libfx_snapshot;
        if (std.mem.eql(u8, method, sh_fx.method.journal_open)) return .libfx_journal_open;
        if (std.mem.eql(u8, method, sh_fx.method.journal_stage_images)) return .libfx_journal_images;
        if (std.mem.eql(u8, method, "mcp/message")) return .mcp_message;
        return .unknown;
    }

    fn waitsForActivePrompt(self: AcpMethod) bool {
        return switch (self) {
            .initialize,
            .request_cancel,
            .session_cancel,
            .session_set_mode,
            .session_new,
            .session_load,
            .session_resume,
            .session_close,
            .libfx_new,
            .libfx_steer,
            .libfx_withdraw,
            .libfx_handoff,
            .libfx_follow_up,
            // Answered during a turn; the running turn keeps its own copy of
            // the settings (TurnSettings), and the change applies from
            // the next turn, as in the TUI.
            .session_set_config_option,
            => false,
            .session_list,
            .session_delete,
            .session_prompt,
            .libfx_checkpoint,
            .libfx_restore,
            .libfx_snapshot,
            .libfx_journal_open,
            .libfx_journal_images,
            .mcp_message,
            .unknown,
            => true,
        };
    }

    fn isLibfx(self: AcpMethod) bool {
        return switch (self) {
            .libfx_checkpoint, .libfx_restore, .libfx_new, .libfx_steer, .libfx_withdraw, .libfx_handoff, .libfx_follow_up, .libfx_snapshot, .libfx_journal_open, .libfx_journal_images => true,
            else => false,
        };
    }
};

const SessionTargetDecision = enum {
    exact,
    missing,
    inactive,
    mismatch,
};

fn decideSessionTarget(open_count: usize, found: bool, supplied: ?std.json.Value) SessionTargetDecision {
    if (open_count == 0) return .inactive;
    const value = supplied orelse return .missing;
    if (value != .string or value.string.len == 0) return .missing;
    return if (found) .exact else .mismatch;
}

pub const Config = acp_runner.Config;

pub const OutboundKind = enum {
    permission,
    elicitation,
    host_tool,
    /// MCP over ACP request to a client-served MCP server.
    mcp_message,
    /// libfx journal flush: the host answers once it holds every event.
    journal,
};

pub const OutboundResponse = struct {
    result_json: ?[]u8 = null,
    error_json: ?[]u8 = null,
    cancelled: bool = false,
    /// The client can't answer: its input has ended. It is not a cancel, so
    /// `cancelled` stays false and a caller sees a request with no result: a
    /// permission request is denied, and a host tool or an elicitation gets an
    /// error result, while the turn goes on.
    no_client: bool = false,
    /// The client that was asked has left, and the request moved to the
    /// session's main client. The waiter asks again there. Nothing sets this yet:
    /// the hand-off that moves a session's main is its first producer.
    moved: bool = false,

    pub fn deinit(self: *OutboundResponse, alloc: Allocator) void {
        if (self.result_json) |value| alloc.free(value);
        if (self.error_json) |value| alloc.free(value);
        self.* = undefined;
    }
};

/// A request that a session's turn waits for. It names the connection it was
/// sent to and that connection's request id, so an answer can only come from
/// the connection that was asked.
pub const OutboundRequest = struct {
    connection: ConnectionId,
    id: u64,
};

const PendingOutbound = struct {
    kind: OutboundKind,
    response: ?OutboundResponse = null,
};

/// The client requests one session's turns have open, with their answers. The
/// table is the session's own, so a request is answered in the session it
/// belongs to. Guarded by `mutex`. A request takes a connection's
/// `outbound_mutex` first, then this `mutex`, and `endClientInput` takes them in
/// that order too.
pub const SessionOutbound = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    pending: std.AutoHashMapUnmanaged(OutboundRequest, PendingOutbound) = .empty,
};

/// The most requests to the client that one session's turns can wait for.
const max_pending_outbound = 32;

const PendingLegacyUrl = struct {
    server_name: []u8,
    source_id: []u8,
    acp_id: []u8,
    session_id: []u8,
    tool_call_id: []u8,
    binding: elicitation.Binding,
    accepted: bool = false,
    completed: bool = false,

    fn deinit(self: *PendingLegacyUrl, alloc: Allocator) void {
        alloc.free(self.server_name);
        alloc.free(self.source_id);
        alloc.free(self.acp_id);
        alloc.free(self.session_id);
        alloc.free(self.tool_call_id);
        self.* = undefined;
    }
};

/// A session's workspace: the root its `cwd` names, what may be read and
/// written there, its project skills, and its project context. ACP v1 says a
/// session's cwd MUST be used for that session, so each session of `fx acp`
/// keeps its own (`tests/tla/acp/AcpSessions.tla` OwnWorkspace). The libfx
/// kernel and the web core hold one session, which uses the launch workspace.
pub const Workspace = struct {
    /// Owned by the server allocator.
    root: []u8 = &.{},
    access: workspace_access.WorkspaceAccess = .{},
    skills: skill_runtime.Runtime = .{},
    /// Gathered again at each turn's start.
    context_snapshot: context_contract.GatheredContextSnapshot = .{},

    pub fn deinit(self: *Workspace, alloc: Allocator) void {
        self.access.deinit(alloc);
        if (self.root.len > 0) alloc.free(self.root);
        self.skills.deinit(alloc);
        self.context_snapshot.deinit(alloc);
        self.* = .{};
    }
};

/// One client of a session. A turn reads and writes its client through this record and never
/// through the client's connection, so no turn touches a connection frame. The session owns
/// each record until the session is freed, so a turn that holds a record never reads freed
/// memory, even after the client left. The values are copies taken when the client joined.
/// `writer` is the connection's writer. It is used only under `audience_mutex` and only while
/// `gone` is false: the connection's leave sets `gone` under that lock before its frame ends.
pub const Member = struct {
    connection_id: ConnectionId,
    /// The process host, which outlives every connection.
    host: *Host,
    gone: bool = false,
    writer: *jsonrpc.Writer,
    initialized: bool,
    terminal_ui: bool,
    client_notices: bool,
    client_compaction: bool,
    client_elicitation: elicitation.Capabilities,
    extensions: sh_fx.Set,
    host_tools: host_tool_runtime.Runtime,
    terminal_client: terminal_client_runtime.Runtime,
    /// The connection default credential, copied when the client joined. A turn that changes it
    /// changes this copy, never the connection's.
    gateway_source_preference: ?types.CredentialSource = null,
    credential_source: ?types.CredentialSource = null,
    /// The process allocator. It owns this record and everything the record holds.
    alloc: Allocator,
    /// Guards `next_outbound_request_id` and `input_ended`. Taken alone or before a
    /// session's `outbound.mutex`.
    outbound_mutex: std.Io.Mutex = .init,
    next_outbound_request_id: u64 = 1,
    /// Set when the client's input ends. Guarded by `outbound_mutex`.
    input_ended: bool = false,
    legacy_url_mutex: std.Io.Mutex = .init,
    pending_legacy_urls: std.ArrayList(PendingLegacyUrl) = .empty,
    /// Holders of this record: the session's member list (one), each connection membership
    /// (one), and each read that takes a hold (`holdMain`). The last `drop` frees it.
    refs: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),

    /// Adds a holder. The caller holds the session's `audience_mutex`, so the record is still listed or held.
    pub fn hold(self: *Member) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    /// Drops a holder, and frees the record with the last one.
    pub fn drop(self: *Member) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) self.destroy();
    }

    /// Whether steering updates carry `sh.fx/steerInput`: `fx acp`'s clients
    /// list `sh.fx/promptDelivery`, and a libfx host lists `sh.fx/hostSteering`.
    pub fn sendsSteerInput(self: *const Member) bool {
        return self.extensions.contains(.prompt_delivery) or self.extensions.contains(.host_steering);
    }

    /// Frees the record and what it holds. `drop` calls it with the last holder, and a record that
    /// was never listed is freed here directly.
    pub fn destroy(self: *Member) void {
        self.host_tools.deinit();
        self.terminal_client.deinit();
        for (self.pending_legacy_urls.items) |*pending| pending.deinit(self.alloc);
        self.pending_legacy_urls.deinit(self.alloc);
        self.alloc.destroy(self);
    }
};

pub const ActiveSessionState = struct {
    /// The live members, in join order. The first one is the main client. Each listed
    /// record holds one reference. Changed only under `audience_mutex`.
    members: std.ArrayList(*Member) = .empty,
    /// The record of the last member that left. It keeps the list's reference while the session
    /// has no member, so a kept turn can still read the main client. Null while `members` is not empty.
    last_main: ?*Member = null,
    /// How many connection memberships list this session. Under `audience_mutex`.
    holders: usize = 0,
    /// Set when the session closes. A closed session is freed by its last holder. Under `audience_mutex`.
    closed: bool = false,
    /// The turns running in this session, or null when none runs.
    prompt: ?*ActivePrompt = null,
    /// `&own_workspace`, or the launch workspace for the one session of the
    /// libfx kernel and the web core.
    workspace: *Workspace = undefined,
    own_workspace: Workspace = .{},
    /// The session's subagent mail: reports and messages its turns run next.
    worker: worker_runtime.WorkerRuntime = .{},
    /// What each report queued in `worker` answers, oldest first, so the
    /// prompt can show it on the subagent call that sent the work (decision
    /// 26). Guarded by `report_mutex`, which also covers posting the report,
    /// so both stay in the same order.
    report_calls: std.ArrayList(ReportCall) = .empty,
    report_mutex: std.Io.Mutex = .init,
    /// A v2 session's children (D22), borrowed by `subagent_host`.
    subagent_v2_children: ?*subagent_child_state.V2Children = null,
    subagent_host: ?*subagent_tool_host.Runtime = null,
    /// Configured with this session's credential and model before each turn.
    web_search_runtime: web_search_runtime.Runtime = web_search_runtime.Runtime.init(.{}),
    /// The Gateway team of the session's credential. Owned, like `api_key`
    /// and `account_id`: each session keeps its own credential, so one
    /// session's refresh or provider change never touches another's.
    gateway_team: ?[]u8 = null,
    observer_hooks: ?@import("libfx_hooks.zig").Config = null,
    session_id: []u8,
    /// The saved session; null on the wasm host, which keeps `wasm_state`.
    v2: ?*session_adapter.Session = null,
    /// The home of the session store while workspace captures are on, set
    /// as each prompt starts; null when they are off (D98).
    capture_home: ?[]const u8 = null,
    /// The current turn's workspace captures.
    turn_capture: turn_capture.TurnCapture = .{},
    wasm_state: ?session_codec.DurableSessionState = null,
    wasm_revision: ?[]u8 = null,
    session_write_mutex: std.Io.Mutex = .init,
    /// The writer a turn sends its updates and requests through. Its callback hands
    /// each frame to the session's main connection, so a turn holds no connection.
    /// `openSession` sets it, because the callback needs the session's address.
    client_writer: jsonrpc.Writer = undefined,
    /// The client requests this session's turns have open, with their answers.
    outbound: SessionOutbound = .{},
    /// Guards `members`, and keeps one turn's updates in order across every
    /// member of the audience. Taken after `session_write_mutex`; nothing else
    /// is taken while it is held, except a member's writer lock.
    audience_mutex: std.Io.Mutex = .init,
    /// What a client that joins the running turn needs to see of it. Guarded by
    /// `audience_mutex`, so it has the order the audience saw.
    running_copy: RunningCopy = .{},
    /// Guards the session's settings: `model`, `provider`, the credential
    /// fields, `fast_mode`, `ultrafast_mode` and `effort`. The request thread
    /// holds it while `session/set_config_option` changes them; a turn holds it
    /// while it picks its credential and copies them, and while it publishes a
    /// renewed credential. Lock order: `settings_mutex`, then `catalog_mutex`,
    /// then `session_write_mutex`.
    settings_mutex: std.Io.Mutex = .init,
    /// Input plus output tokens of the latest main-model completion, the
    /// context `usage_update` reports; 0 until a completion reports both.
    /// `usize` keeps it atomic on wasm32.
    context_used: std.atomic.Value(usize) = .init(0),
    /// The summary of the session's latest finished turn, its times and the
    /// tokens fx counted, for that turn's response. The turn's worker writes
    /// it and then answers the prompt (`promptWorkerMain`), so both happen on
    /// one thread.
    turn_summary: ?types.TurnSummary = null,
    model: []u8,
    provider: model_provider.ProviderId = .gateway,
    mode: []const u8,
    /// `workspace.root`.
    workspace_root: []const u8,
    /// Owned by the server allocator.
    api_key: []const u8,
    credential_source: ?types.CredentialSource = null,
    credential_refresh_after_ms: ?i64 = null,
    account_id: ?[]const u8 = null,
    agent_step_limit: usize,
    max_tool_result_bytes: usize,
    fast_mode: bool,
    ultrafast_mode: bool = false,
    effort: types.ReasoningEffort,
    first_call_tool_choice: types.ToolChoice,
    permission_mode: types.PermissionMode,
    permission_rules: types.PermissionRuleSet,
    /// The connection defaults this session copied when it opened (`openSession`). It keeps
    /// them when its main client changes, so it never reads the connection for them.
    context_limits: config_runtime.context_limits.Values = .{},
    toolbox_behind: config_runtime.tool_placement.Behind = config_runtime.tool_placement.behindToolbox(.{}, &.{}),
    auto_compact_percent: u8 = compactor.default_percent,
    context_enabled: bool = true,
    session_titles: bool = true,
    cache_warming: bool = true,
    workspace_capture: bool = false,
    /// Runtime-only "allow for this session" grants. Never persisted to
    /// profile or project configuration.
    session_grants: []types.PermissionGrant = &.{},
    session_rt: session_runtime.SessionRuntime,
    title_task: ?*session_title_generation.Task = null,
    /// The session's MCP servers; null when it has none.
    mcp_host: ?*mcp_host.Host = null,
    /// Session-scoped client system prompt, appended after fx's instructions.
    /// Owned by the server allocator; empty when the client supplied none.
    client_system_prompt: []u8 = &.{},
    /// MCP identities shown for earlier tool calls, for session/load replay.
    /// Guarded by `tool_identities_mutex`: a load can replay them while the
    /// session's turn records more.
    tool_identities: tool_call_identities.Record = .{},
    tool_identities_mutex: std.Io.Mutex = .init,
    cancel_flag: std.atomic.Value(bool),
    /// Set with `cancel_flag` only by a cancel that stops the turn: the
    /// client's `session/cancel`, its closed steering, or a host tool it
    /// cancelled. A steer that cuts the reply short sets `cancel_flag` alone,
    /// so the turn's workspace captures, which watch this, keep running (D98).
    /// Cleared as each prompt starts.
    turn_cancel: std.atomic.Value(bool) = .init(false),
    pending_prompt_id: ?jsonrpc.RequestId,
    steering: libfx_steering.Runtime = .{},
    /// The steers for the next turn and the queued prompts, which wait for
    /// the running turn to end.
    waiting_prompts: prompt_line.Line = .{},
    /// Uses of this session that `SharedSessions.retain` took. A close waits for
    /// them to end. Guarded by the shared table's `mutex`.
    uses: usize = 0,
    uses_done: std.Io.Condition = .init,
    /// Set when the host passed a journal; every state change is sent to it.
    journal: ?libfx_journal.Journal = null,
    /// Images the host staged from its store for the journal it opens next.
    /// Owned by the server allocator; cleared once the journal opens.
    staged_images: session_codec.StagedImages = .{},
    /// What the last open that found images missing needs staged, all told:
    /// an open turn's tool images can take a session past one window and one
    /// prompt, and what a running session held must reopen.
    staging_needed: StagedTotals = .{},

    pub fn retainGrant(self: *ActiveSessionState, alloc: Allocator, tool_name: []const u8, target_path: []const u8) !void {
        for (self.session_grants) |grant| {
            if (std.mem.eql(u8, grant.tool_name, tool_name) and
                std.mem.eql(u8, grant.target_path, target_path)) return;
        }

        const name_copy = try alloc.dupe(u8, tool_name);
        errdefer alloc.free(name_copy);
        const target_copy = try alloc.dupe(u8, target_path);
        errdefer alloc.free(target_copy);
        const next = try alloc.alloc(types.PermissionGrant, self.session_grants.len + 1);
        errdefer alloc.free(next);
        if (self.session_grants.len > 0) {
            @memmove(next[0..self.session_grants.len], self.session_grants);
            alloc.free(self.session_grants);
        }
        next[next.len - 1] = .{ .tool_name = name_copy, .target_path = target_copy };
        self.session_grants = next;
    }
};

const ActivePrompt = struct {
    /// The process host, which outlives every connection, so a turn never holds
    /// the frame of the connection that started it.
    host: *Host,
    /// The session whose turns this worker runs. It stays open until the
    /// worker is reaped.
    session: *ActiveSessionState,
    /// Whether the client that sent the prompt listed `sh.fx/usage` and
    /// `sh.fx/promptDelivery` when the turn started. The answer keeps that shape
    /// when the sender has left.
    usage_shown: bool = false,
    delivery_shown: bool = false,
    /// Whether the sender listed `sh.fx/keepTurnOnDisconnect` when the turn
    /// started. Such a turn finishes and is saved when the last client leaves,
    /// even if that client did not list it.
    keep_turn: bool = false,
    alloc: Allocator,
    msg: jsonrpc.Message,
    /// The connection that sent the prompt this turn runs; its answer goes there. A turn
    /// of steers has no prompt of its own: each steer's answer goes to that steer's sender.
    from: ConnectionId = no_connection,
    /// Mode and permission policy captured when the prompt was dispatched.
    /// Mid-turn mode changes apply to the next prompt, never the running one.
    mode: []const u8,
    permission_mode: types.PermissionMode,
    /// The steers that started the running turn together, each with its sender,
    /// answered with `next_turn`. Empty for a turn a prompt started.
    /// Owned by `alloc`. The worker replaces `msg` and these between turns
    /// while it holds the session's `waiting_prompts` mutex.
    group_ids: []libfx_steering.Sender = &.{},
    /// The usage of every turn the prompt ran, its own and each report turn
    /// after it. The response reports it. Written by the prompt's own thread.
    usage: types.Usage = .{},
    thread: if (host_target.is_wasm) void else std.Thread = if (host_target.is_wasm) {} else undefined,
    reapable: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// The sessions this process has open, with the uses each one holds. The table
/// lives in `process_host/session_table.zig`; the server names it here.
pub const SharedSessions = process_host.SessionTable(ActiveSessionState);

/// The process's shared parts: its store, leader, session table, catalog, and
/// runtimes. See `process_host/process_host.zig`.
pub const Host = process_host.ProcessHost(ActiveSessionState);

/// A process host for a test's connections. Its config is undefined, as the test
/// connections' always were, so no test may read it.
pub fn testHost(alloc: Allocator) Host {
    return .{
        .alloc = alloc,
        .cfg = undefined,
        .store = null,
        .web_fetch_runtime = web_fetch_runtime.Runtime.init(.{}),
        .managed_executions = managed_execution.Runtime.init(alloc),
        .lifecycle_runtime = hooks.Runtime.init(alloc),
        .lifecycle_view = hooks.RuntimeView.empty(),
    };
}

const LeaderInfo = process_host.LeaderInfo;

/// One session a connection has open, as its main client or as a follower. The membership
/// holds one reference to the connection's record, so the record outlives the membership.
pub const Membership = struct {
    session: *ActiveSessionState,
    member: *Member,
};

pub const ServerState = struct {
    configured_providers: @import("../core/config/configured_provider.zig").Registry = .{},
    alloc: Allocator,
    /// The process's shared parts: its store, leader, session table, catalog,
    /// and runtimes. Every connection of the process points at the same host.
    host: *Host,
    writer: jsonrpc.Writer,
    /// This connection's id, which its waiting input carries (see `ConnectionId`).
    connection_id: ConnectionId = no_connection,
    initialized: bool = false,
    /// Selects fx's terminal or embedded base prompt for this connection.
    terminal_ui: bool = true,
    client_fs_read: bool = false,
    client_fs_write: bool = false,
    client_terminal: bool = false,
    /// The client shows ACP v1 Session Notices (`session.notices`).
    client_notices: bool = false,
    /// The client takes ACP v1's compaction updates (`session.compaction`).
    client_compaction: bool = false,
    client_elicitation: elicitation.Capabilities = .{},
    /// The directory `fx acp` was launched in, or `--workspace`'s: the
    /// workspace of the libfx kernel's and the web core's one session, and
    /// where a native session's workspace starts before its `cwd`.
    launch: Workspace = .{},
    /// The default credential, which each session copies when it opens.
    /// Only the reader thread changes it.
    api_key: []u8 = &.{},
    credential_source: ?types.CredentialSource = null,
    gateway_source_preference: ?types.CredentialSource = null,
    credential_refresh_after_ms: ?i64 = null,
    account_id: ?[]u8 = null,
    gateway_team: ?[]u8 = null,
    selected_model: []u8 = &.{},
    provider: model_provider.ProviderId = .gateway,
    configured_model: []u8 = &.{},
    process_model_override: bool = false,
    /// Whether the credential's team has Token Pass: the check that asks.
    token_pass_run: ?token_pass_check.Check = null,
    /// The profile's speeds, kept while nothing chose the model, so new
    /// sessions follow the team's start model (`token_pass.startModel`).
    token_pass_start: ?struct { fast_mode: bool, ultrafast_mode: bool } = null,
    process_provider_override: bool = false,
    permission_mode: types.PermissionMode = .ask,
    permission_rules: types.PermissionRuleSet = .{},
    agent_step_limit: usize = 0,
    max_tool_result_bytes: usize = 64 * 1024,
    auto_compact_percent: u8 = compactor.default_percent,
    context_limits: config_runtime.context_limits.Values = .{},
    /// The built-in tools offered through toolbox, fixed for the server.
    toolbox_behind: config_runtime.tool_placement.Behind = config_runtime.tool_placement.behindToolbox(.{}, &.{}),
    fast_mode: bool = false,
    ultrafast_mode: bool = false,
    configured_ultrafast_mode: bool = false,
    process_ultrafast_override: ?bool = null,
    effort: types.ReasoningEffort = .auto,
    first_call_tool_choice: types.ToolChoice = .auto,
    context_enabled: bool = true,
    session_titles: bool = true,
    cache_warming: bool = true,
    /// `experimental.workspace_capture`, from startup.
    workspace_capture: bool = false,
    /// This connection's memberships, oldest first: each session it has open, as its main
    /// client or as a follower. Only this connection's reader thread changes the list, so it has no lock.
    memberships: std.ArrayList(Membership) = .empty,
    terminal_client: terminal_client_runtime.Runtime = .{},
    /// The record this connection has before a session it opens or loads adopts it. Only the
    /// reader thread uses it.
    pending_member: ?*Member = null,
    terminate_connection: bool = false,
    host_tools: host_tool_runtime.Runtime = .{},
    /// The extensions that both fx and the client list at `initialize`. fx
    /// sends an extension's notifications and `_meta` keys only for these.
    extensions: sh_fx.Set = .empty,
    /// What a socket connection answers `initialize` with beyond the stdio answer:
    /// this process's pid and the sessions it leads. Null on stdio, whose answer is unchanged.
    leader_info: ?LeaderInfo = null,

    pub fn deinit(self: *ServerState) void {
        if (self.pending_member) |member| {
            markMemberGone(member);
            member.drop();
        }
        if (self.token_pass_run) |*check| check.finish(self.alloc, "shutdown");
        // Terminals end with this process. Ending them first also releases
        // an active prompt waiting on one.
        self.terminal_client.closeOwnedTerminals();
        // Every session this connection's end closes (`endsSession`): a session it left keeps its
        // kept turn, which these loops wait for. A session another member still leads is not this
        // connection's to wait for.
        for (self.memberships.items) |membership| {
            if (!endsSession(membership)) continue;
            reapSessionPrompt(membership.session, true);
        }
        // A subagent inside a command uses the host's managed executions until it stops, so the
        // subagents stop first, as in `fx ask`. The host ends its runtimes only after every session
        // has closed, when `closeAllSessions` no longer waits for a subagent.
        for (self.memberships.items) |membership| {
            if (!endsSession(membership)) continue;
            disableSubagentHost(membership.session);
        }
        self.terminal_client.deinit();
        closeAllSessions(self);
        self.memberships.deinit(self.alloc);
        self.launch.deinit(self.alloc);
        if (self.api_key.len > 0) secret.zeroAndFree(self.alloc, self.api_key);
        if (self.gateway_team) |team| self.alloc.free(team);
        if (self.account_id) |account_id| self.alloc.free(account_id);
        if (self.selected_model.len > 0) self.alloc.free(self.selected_model);
        if (self.configured_model.len > 0) self.alloc.free(self.configured_model);
        self.permission_rules.deinit(self.alloc);
        self.host_tools.deinit();
        self.configured_providers.deinit(self.alloc);
    }
};

fn credentialMatchesProvider(
    source: ?types.CredentialSource,
    provider: model_provider.ProviderId,
) bool {
    return model_provider.authorizesCredential(provider, source);
}

fn credentialReadyAt(
    source: ?types.CredentialSource,
    token: []const u8,
    refresh_after_ms: ?i64,
    now_ms: i64,
) bool {
    if (source == null or (token.len == 0 and source != .configured)) return false;
    if (credentials.sourceRefreshable(source.?) and
        refresh_after_ms != null and refresh_after_ms.? <= now_ms)
    {
        return false;
    }
    return true;
}

/// Transfers credential storage after the caller has stopped its prior borrowers.
/// Makes `credential` the default that sessions copy when they open. Only
/// the reader thread calls it.
pub fn adoptServerCredential(state: *ServerState, credential: *credentials.Credential) void {
    if (state.api_key.len > 0) secret.zeroAndFree(state.alloc, state.api_key);
    if (state.gateway_team) |team| state.alloc.free(team);
    if (state.account_id) |account_id| state.alloc.free(account_id);

    state.api_key = credential.token;
    credential.token = &.{};
    state.credential_source = credential.source;
    state.credential_refresh_after_ms = credential.refresh_after_ms;
    state.account_id = credential.account_id;
    credential.account_id = null;
    state.gateway_team = if (credential.team_id) |team| team else credential.team_slug;
    if (credential.team_id != null) {
        credential.team_id = null;
        if (credential.team_slug) |slug| state.alloc.free(slug);
        credential.team_slug = null;
    } else {
        credential.team_slug = null;
    }
}

/// Takes `credential` over as `session`'s own. Every other session keeps its
/// credential, so one session's provider or refresh never changes another's.
/// It frees the credential it replaces, which a subagent's turn reads from its
/// own copy (`ModelRoute`); call it with `subagent_authority_mutex` held.
pub fn adoptSessionCredential(alloc: Allocator, session: *ActiveSessionState, credential: *credentials.Credential) void {
    var previous = takeSessionCredential(session);
    session.api_key = credential.token;
    credential.token = &.{};
    session.credential_source = credential.source;
    session.credential_refresh_after_ms = credential.refresh_after_ms;
    session.account_id = credential.account_id;
    credential.account_id = null;
    session.gateway_team = if (credential.team_id) |team| team else credential.team_slug;
    if (credential.team_id != null) {
        credential.team_id = null;
        if (credential.team_slug) |slug| alloc.free(slug);
    }
    credential.team_slug = null;
    // The web search runtime borrows the key and the team, so it points at the new ones first.
    pointWebSearchAtSession(session);
    previous.deinit(alloc);
}

/// Marks `session`'s route as authorized by the host, with no credential.
/// Call it with `subagent_authority_mutex` held.
pub fn useHostManagedCredential(alloc: Allocator, session: *ActiveSessionState) void {
    var previous = takeSessionCredential(session);
    session.credential_source = .host_managed;
    session.credential_refresh_after_ms = null;
    pointWebSearchAtSession(session);
    previous.deinit(alloc);
}

/// A session's credential, taken out of it so it can be freed once nothing
/// borrows it.
const TakenCredential = struct {
    api_key: []const u8,
    account_id: ?[]const u8,
    gateway_team: ?[]u8,

    fn deinit(self: *TakenCredential, alloc: Allocator) void {
        if (self.api_key.len > 0) secret.zeroAndFree(alloc, @constCast(self.api_key));
        if (self.account_id) |id| alloc.free(id);
        if (self.gateway_team) |team| alloc.free(team);
        self.* = .{ .api_key = &.{}, .account_id = null, .gateway_team = null };
    }
};

fn takeSessionCredential(session: *ActiveSessionState) TakenCredential {
    const taken: TakenCredential = .{ .api_key = session.api_key, .account_id = session.account_id, .gateway_team = session.gateway_team };
    session.api_key = &.{};
    session.account_id = null;
    session.gateway_team = null;
    return taken;
}

/// Points `session`'s web search runtime at the session's own credential and
/// worker model, under `subagent_authority_mutex`, when a prompt's turn ends
/// and frees the copy it pointed the runtime at.
pub fn pointWebSearchBackAtSession(session: *ActiveSessionState) void {
    const main_record = holdMain(session);
    defer main_record.drop();
    main_record.host.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
    const second_main_record = holdMain(session);
    defer second_main_record.drop();
    defer second_main_record.host.subagent_authority_mutex.unlock(io_mod.getIo());
    pointWebSearchAtSession(session);
}

/// Points `session`'s web search runtime at its credential and worker model
/// again. The runtime borrows them, and a switch of the model or of the
/// credential frees what it borrowed. Call with `subagent_authority_mutex`
/// held.
fn pointWebSearchAtSession(session: *ActiveSessionState) void {
    const main_record = holdMain(session);
    defer main_record.drop();
    const state = main_record;
    session.web_search_runtime.configure(.{
        .api_key = session.api_key,
        .credential_source = session.credential_source,
        .gateway_team = session.gateway_team,
        .worker_model = session.model,
        .gateway_retry_count = state.host.cfg.gateway_retry_count,
        .gateway_chat_url = state.host.cfg.gateway_chat_url,
    });
}

/// Ensures `session` holds a credential authorized for its provider's
/// route, changing only that session. Returns false when that route has no
/// credential.
pub fn selectCredentialForSession(state: *Member, session: *ActiveSessionState) !bool {
    if (state.host.cfg.auth_mode == .host_managed) {
        state.host.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
        defer state.host.subagent_authority_mutex.unlock(io_mod.getIo());
        useHostManagedCredential(state.alloc, session);
        return true;
    }
    var prepared = prepareCredentialForProvider(state, session, session.provider) catch |err| {
        if (err == error.ProviderCredentialUnavailable) return false;
        return err;
    };
    defer if (prepared) |*credential| credential.deinit(state.alloc);
    if (prepared) |*credential| {
        state.host.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
        defer state.host.subagent_authority_mutex.unlock(io_mod.getIo());
        adoptSessionCredential(state.alloc, session, credential);
    }
    return true;
}

/// True when requests on the provider's route carry no credential from this
/// server because the host authorizes them at its fetch edge.
fn hostManagesRoute(cfg: Config, provider: model_provider.ProviderId) bool {
    return provider != .gateway and cfg.provider_auth_mode == .host_managed;
}

/// A tokenless credential that marks a route as authorized by the host.
fn hostManagedCredential() credentials.Credential {
    return .{ .token = &.{}, .source = .host_managed };
}

/// Stages authorization without changing any in-flight credential storage.
/// The caller owns a non-null credential; null keeps `session`'s credential,
/// or with no session the default. A session's own turn passes its session,
/// and never reads the default, which only the reader thread changes.
pub fn prepareCredentialForProvider(
    state: *Member,
    session: ?*const ActiveSessionState,
    provider: model_provider.ProviderId,
) !?credentials.Credential {
    if (state.host.cfg.auth_mode == .host_managed) return null;
    if (hostManagesRoute(state.host.cfg, provider)) return hostManagedCredential();
    const now_ms = io_mod.milliTimestamp();
    {
        // The credential in use is read under the lock a subagent's refresh publishes under.
        state.host.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
        defer state.host.subagent_authority_mutex.unlock(io_mod.getIo());
        if (session) |active| {
            if (provider != .configured and credentialMatchesProvider(active.credential_source, provider) and
                credentialReadyAt(
                    active.credential_source,
                    active.api_key,
                    active.credential_refresh_after_ms,
                    now_ms,
                )) return null;
        }
    }

    return if (provider == .gateway and state.host.cfg.credential_override != null)
        credentials.Credential{
            .token = try state.alloc.dupe(u8, state.host.cfg.credential_override.?),
            .source = .ai_gateway_api_key,
        }
    else blk: {
        break :blk (try auth_runtime.prepareCredential(
            state.alloc,
            state.host.cfg.gateway_provider.oauth_transport,
            state.host.cfg.secret_store,
            provider,
            if (provider == .gateway) state.gateway_source_preference else state.credential_source,
        )) orelse return error.ProviderCredentialUnavailable;
    };
}

/// Stages the credential for a load or resume that no session holds yet. The
/// connection's own credential stays in use while it matches the provider and
/// is ready, so a stored login removed later does not refuse the load.
pub fn prepareStagingCredential(
    state: *ServerState,
    provider: model_provider.ProviderId,
) !?credentials.Credential {
    if (state.host.cfg.auth_mode != .host_managed and !hostManagesRoute(state.host.cfg, provider)) {
        const now_ms = io_mod.milliTimestamp();
        state.host.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
        defer state.host.subagent_authority_mutex.unlock(io_mod.getIo());
        if (provider != .configured and credentialMatchesProvider(state.credential_source, provider) and
            credentialReadyAt(state.credential_source, state.api_key, state.credential_refresh_after_ms, now_ms)) return null;
    }
    return prepareCredentialForProvider(try pendingMember(state), null, provider);
}

test "ACP credential preparation preserves the existing borrowed credential" {
    const alloc = std.testing.allocator;
    var test_host = testHost(alloc);
    defer test_host.deinit();
    const Discard = struct {
        fn write(_: ?*anyopaque, _: []const u8) !void {}
    };
    var state = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(null, Discard.write),
    };
    defer state.deinit();
    test_host.subagent_authority_mutex = .init;
    state.host.cfg.auth_mode = .local;
    state.host.cfg.credential_override = "next-token";
    state.credential_source = .configured;
    state.api_key = try alloc.dupe(u8, "active-token");
    const borrowed = state.api_key;
    var prepared = (try prepareCredentialForProvider(try pendingMember(&state), null, .gateway)).?;
    defer prepared.deinit(alloc);
    try std.testing.expectEqualStrings("next-token", prepared.token);
    try std.testing.expectEqualStrings("active-token", borrowed);
    try std.testing.expect(state.api_key.ptr == borrowed.ptr);
    try std.testing.expectEqual(types.CredentialSource.configured, state.credential_source.?);
}

test "ACP provider routes are host-managed only when configured and never leak into Gateway" {
    const alloc = std.testing.allocator;
    var test_host = testHost(alloc);
    defer test_host.deinit();
    const Discard = struct {
        fn write(_: ?*anyopaque, _: []const u8) !void {}
    };
    var state = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(null, Discard.write),
    };
    defer state.deinit();
    test_host.subagent_authority_mutex = .init;
    state.host.cfg.auth_mode = .local;
    state.host.cfg.provider_auth_mode = .host_managed;
    state.host.cfg.credential_override = "gateway-key";
    state.api_key = &.{};
    state.credential_refresh_after_ms = null;
    state.account_id = null;
    state.gateway_team = null;

    // A Codex turn leaves the process host-managed with no token.
    var codex = (try prepareCredentialForProvider(try pendingMember(&state), null, .codex)).?;
    try std.testing.expectEqual(types.CredentialSource.host_managed, codex.source);
    try std.testing.expectEqual(@as(usize, 0), codex.token.len);
    adoptServerCredential(&state, &codex);
    codex.deinit(alloc);
    try std.testing.expectEqual(types.CredentialSource.host_managed, state.credential_source.?);

    // The next Gateway turn gets its own key, not the host-managed source.
    var gateway = (try prepareCredentialForProvider(try pendingMember(&state), null, .gateway)).?;
    defer gateway.deinit(alloc);
    try std.testing.expectEqual(types.CredentialSource.ai_gateway_api_key, gateway.source);
    try std.testing.expectEqualStrings("gateway-key", gateway.token);

    // A Grok turn is host-managed the same way.
    var grok = (try prepareCredentialForProvider(try pendingMember(&state), null, .grok)).?;
    defer grok.deinit(alloc);
    try std.testing.expectEqual(types.CredentialSource.host_managed, grok.source);
    try std.testing.expectEqual(@as(usize, 0), grok.token.len);

    // So is a configured provider: the host adds its API key, if any.
    const configured = model_provider.parse("local").?;
    var custom = (try prepareCredentialForProvider(try pendingMember(&state), null, configured)).?;
    defer custom.deinit(alloc);
    try std.testing.expectEqual(types.CredentialSource.host_managed, custom.source);
    try std.testing.expectEqual(@as(usize, 0), custom.token.len);

    // Without the policy each provider needs its own credential.
    state.host.cfg.provider_auth_mode = .local;
    try std.testing.expect(!hostManagesRoute(state.host.cfg, .codex));
    try std.testing.expect(!hostManagesRoute(state.host.cfg, .grok));
    try std.testing.expect(!hostManagesRoute(state.host.cfg, configured));
    try std.testing.expect(!hostManagesRoute(state.host.cfg, .gateway));
}

pub fn streamProviderFor(
    host: *const Host,
    provider: model_provider.ProviderId,
) @import("../core/agent/stream_provider.zig").Provider {
    return host.cfg.provider_set.select(provider).agent_stream_or_unavailable();
}

pub fn catalogProviderFor(
    host: *const Host,
    provider: model_provider.ProviderId,
) ?@import("../core/gateway/model_catalog.zig").Provider {
    return host.cfg.provider_set.select(provider).model_catalog;
}

pub fn refreshModelCredential(
    raw: *anyopaque,
    expected_provider: model_provider.ProviderId,
    alloc: Allocator,
    source: types.CredentialSource,
    mode: auth_runtime.CredentialRefreshMode,
    expected_account_id: ?[]const u8,
    rejected_token: ?[]const u8,
) !?[]u8 {
    const session: *ActiveSessionState = @ptrCast(@alignCast(raw));
    const main_record = holdMain(session);
    defer main_record.drop();
    const state = main_record;
    if (mode == .if_needed and auth_runtime.requestPathCredentialVerifiedRecently(source)) {
        debug_trace.logf("auth", "credential refresh skipped source={t} reason=verified_recently", .{source});
        return null;
    }
    var refreshed = (try auth_runtime.refreshCredentialForAccount(
        state.host.cfg.gateway_provider.oauth_transport,
        state.alloc,
        source,
        mode,
        expected_account_id,
        rejected_token,
    )) orelse return null;
    defer refreshed.deinit(state.alloc);

    const worker_token = try alloc.dupe(u8, refreshed.token);
    errdefer secret.zeroAndFree(alloc, worker_token);
    try publishRefreshedCredential(
        state.alloc,
        session,
        expected_provider,
        &refreshed,
        expected_account_id,
        source == .fx_login,
    );
    return worker_token;
}

/// Gives a refreshed credential to the session whose turn refreshed it, when
/// it still names the same provider, source, account, and team. Holds the
/// session's settings lock, so a `session/set_config_option` cannot change
/// them between the checks and the adoption.
fn publishRefreshedCredential(
    alloc: Allocator,
    session: *ActiveSessionState,
    expected_provider: model_provider.ProviderId,
    refreshed: *credentials.Credential,
    expected_account_id: ?[]const u8,
    check_team: bool,
) !void {
    session.settings_mutex.lockUncancelable(io_mod.getIo());
    defer session.settings_mutex.unlock(io_mod.getIo());
    // A subagent's turn refreshes from its own thread, and a switch of the provider replaces the
    // session's credential, team and account, so the checks, the reads of the team included, and
    // the adoption are one step under both locks, in their order.
    const main_record = holdMain(session);
    defer main_record.drop();
    const state = main_record;
    state.host.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
    defer state.host.subagent_authority_mutex.unlock(io_mod.getIo());
    if (!session.provider.eql(expected_provider)) {
        debug_trace.logf("auth", "ACP credential publication rejected stage=session_provider: the session changed provider during the turn, so the renewed credential stays the turn's own", .{});
        return error.CredentialAuthorityChanged;
    }
    if (session.credential_source != refreshed.source) {
        debug_trace.logf("auth", "ACP credential publication rejected stage=session_source", .{});
        return error.CredentialAuthorityChanged;
    }
    if (expected_account_id) |expected| {
        const refreshed_account = refreshed.accountId() orelse {
            debug_trace.logf("auth", "ACP credential publication rejected stage=refreshed_account_missing", .{});
            return error.ChatGptAccountChanged;
        };
        const session_account = session.account_id orelse {
            debug_trace.logf("auth", "ACP credential publication rejected stage=session_account_missing", .{});
            return error.ChatGptAccountChanged;
        };
        if (!std.mem.eql(u8, expected, refreshed_account)) {
            debug_trace.logf("auth", "ACP credential publication rejected stage=refreshed_account_changed", .{});
            return error.ChatGptAccountChanged;
        }
        if (!std.mem.eql(u8, expected, session_account)) {
            debug_trace.logf("auth", "ACP credential publication rejected stage=session_account_changed", .{});
            return error.ChatGptAccountChanged;
        }
    }
    if (check_team) {
        const refreshed_team = refreshed.gatewayTeam() orelse return error.CredentialAuthorityChanged;
        const session_team = session.gateway_team orelse return error.CredentialAuthorityChanged;
        if (!std.mem.eql(u8, session_team, refreshed_team)) return error.CredentialAuthorityChanged;
    }
    adoptSessionCredential(alloc, session, refreshed);
}

/// The native session store: the one this connection shares, or the one it
/// opened. Null when it could not open (no `HOME`). The wasm host keeps sessions
/// in the JS host's snapshot store instead.
pub fn sessionsStore(host: *Host) ?*session_adapter.Store {
    return if (host.store) |*store| store else null;
}

/// The record of the session's main client: the oldest live member, or, once every member has
/// left, the record of the last one. The caller holds `audience_mutex` and takes no hold.
pub fn mainLocked(session: *ActiveSessionState) ?*Member {
    if (session.members.items.len > 0) return session.members.items[0];
    return session.last_main;
}

/// The record of the main client, with a hold that the caller drops with `Member.drop` after its
/// last read. Takes `audience_mutex`, so the caller must not hold it already.
pub fn holdMain(session: *ActiveSessionState) *Member {
    var audience = lockAudience(session);
    defer audience.unlock();
    const main = mainLocked(session).?;
    main.hold();
    return main;
}

/// The `client_writer` callback: hands one finished frame to the session's main client,
/// under `audience_mutex`, so the frame never reaches a client that has left.
pub fn forwardToMain(context: ?*anyopaque, frame: []const u8) anyerror!void {
    const session: *ActiveSessionState = @ptrCast(@alignCast(context.?));
    var audience = lockAudience(session);
    defer audience.unlock();
    const main = mainLocked(session).?;
    if (main.gone) return error.ClientGone;
    try main.writer.writeBytes(frame);
}

/// The clients one session's updates reach: its members, in join order, the main first.
/// `lockAudience` holds `audience_mutex` until `unlock`, so the members cannot change while
/// a turn sends to them.
pub const Audience = struct {
    session: *ActiveSessionState,
    next_member: usize = 0,

    /// The next member to send to. Null once every member has had its turn.
    pub fn next(self: *Audience) ?*Member {
        if (self.next_member >= self.session.members.items.len) return null;
        defer self.next_member += 1;
        return self.session.members.items[self.next_member];
    }

    /// Whether a member lists `extension`. It does not move `next`.
    pub fn anyLists(self: *const Audience, extension: sh_fx.Extension) bool {
        for (self.session.members.items) |member| {
            if (member.extensions.contains(extension)) return true;
        }
        return false;
    }

    /// Why a follower left the audience. The main client is never dropped this way.
    pub const DropReason = union(enum) {
        /// The member's write returned an error.
        write_failed: anyerror,
        /// The member's writer has stopped writing: its client closed.
        client_gone,
    };

    /// Writes one notification to `member`. A follower whose write fails, or whose writer has
    /// stopped (its client closed), is dropped from the audience: it loses this update, and the
    /// turn goes on. When the main client's write fails, the main client leaves, the oldest
    /// remaining member becomes the main, and the update is sent to it. With no member left,
    /// the error reaches the turn.
    pub fn writeNotification(
        self: *Audience,
        member: *Member,
        alloc: Allocator,
        method: []const u8,
        params_json: []const u8,
    ) !void {
        member.writer.writeNotification(alloc, method, params_json) catch |err| {
            if (member == mainLocked(self.session).?) {
                if (removeMemberLocked(self.session, member.connection_id)) return self.writeNotification(mainLocked(self.session).?, alloc, method, params_json);
                return err;
            }
            self.dropMember(member, method, .{ .write_failed = err });
            return;
        };
        // A writer that has stopped after a broken pipe returns no error for a notification,
        // so it is checked after every follower's write.
        if (member != mainLocked(self.session).? and memberStopped(member)) {
            self.dropMember(member, method, .client_gone);
        }
    }

    /// Sends one notification the turn makes: `with` to each member that `need` covers,
    /// `without` to the others (none when it is null), main first. The copy keeps the entry in
    /// the same hold, so it has the order the members saw.
    pub fn deliver(
        self: *Audience,
        alloc: Allocator,
        method: []const u8,
        need: RunningCopy.Need,
        with: []const u8,
        without: ?[]const u8,
    ) !void {
        try self.writeEach(alloc, method, need, with, without);
        self.session.running_copy.add(mainLocked(self.session).?.alloc, method, need, with, without);
    }

    /// The writes of `deliver`, without the copy.
    pub fn writeEach(
        self: *Audience,
        alloc: Allocator,
        method: []const u8,
        need: RunningCopy.Need,
        with: []const u8,
        without: ?[]const u8,
    ) !void {
        // Without `follow_supported` no follower exists, so the main client is the only member:
        // its version goes straight to its writer, and its error reaches the turn as before.
        if (comptime !follow_supported) {
            const main = mainLocked(self.session).?;
            const params = if (memberTakes(main, need)) with else (without orelse return);
            try main.writer.writeNotification(alloc, method, params);
            return;
        }
        while (self.next()) |member| {
            const params = if (memberTakes(member, need)) with else (without orelse continue);
            try self.writeNotification(member, alloc, method, params);
        }
    }

    /// Keeps the turn's latest progress for a joiner. Nothing is sent.
    pub fn keepProgress(self: *Audience, params: []const u8) void {
        self.session.running_copy.setProgress(mainLocked(self.session).?.alloc, params);
    }

    /// Whether `member`'s writer has stopped writing. `writeFrame` sets
    /// `dropping` under the writer's own lock, so it is read under that lock too.
    fn memberStopped(member: *Member) bool {
        const io = io_mod.getIo();
        member.writer.mutex.lockUncancelable(io);
        defer member.writer.mutex.unlock(io);
        return member.writer.dropping;
    }

    /// Removes `member` from the followers, and logs the update it lost and why.
    /// `next` has already passed `member`, so the cursor moves back one place
    /// when the removed entry sat before it.
    fn dropMember(self: *Audience, member: *Member, method: []const u8, reason: DropReason) void {
        for (self.session.members.items, 0..) |listed, index| {
            if (listed != member) continue;
            if (index < self.next_member) self.next_member -= 1;
            break;
        }
        _ = removeMemberLocked(self.session, member.connection_id);
        // The member can no longer hear the session, so its waiting input leaves with it.
        withdrawFollowerInput(member, self.session, .left);
        switch (reason) {
            .write_failed => |err| debug_trace.logf(
                "acp",
                "event=follower_dropped session={s} method={s} reason=write_failed err={s}",
                .{ self.session.session_id, method, @errorName(err) },
            ),
            .client_gone => debug_trace.logf(
                "acp",
                "event=follower_dropped session={s} method={s} reason=client_gone",
                .{ self.session.session_id, method },
            ),
        }
    }

    pub fn unlock(self: *Audience) void {
        self.session.audience_mutex.unlock(io_mod.getIo());
    }
};

/// Takes a session's audience. The caller sends through `next`, then `unlock`.
pub fn lockAudience(session: *ActiveSessionState) Audience {
    session.audience_mutex.lockUncancelable(io_mod.getIo());
    return .{ .session = session };
}

/// What a client that joins a running turn needs to see of it: each update the
/// turn has sent, in order, with the params each kind of client takes. It is
/// freed when the save that commits the turn to the log runs, and again when the
/// turn ends. A joining client reads the log and this copy under
/// `session_write_mutex`, so it never sees the turn in both.
pub const RunningCopy = struct {
    /// Past this many bytes the copy stops: a joiner is told that the earlier
    /// output is not shown, and no later update of the turn is kept.
    pub const limit_bytes: usize = 16 << 20;

    /// Which members take an entry's `with` params. The others take `without`.
    pub const Need = union(enum) {
        /// Every member takes `with`.
        none,
        /// A member takes `with` when it lists this extension.
        extension: sh_fx.Extension,
        /// A member takes `with` when its client shows ACP notices.
        notices,
        /// A member takes `with` when `ServerState.sendsSteerInput` holds.
        steer_input,
        /// A member takes `with` unless it is `sender`, the connection that sent the
        /// prompt, which sees its own prompt in its own client.
        except_sender: ConnectionId,
    };

    pub const Entry = struct {
        /// A static method name: `session/update` or an `sh.fx` method.
        method: []const u8,
        need: Need,
        /// The params a member takes when `need` covers it.
        with: []u8,
        /// The params the other members take; null when they take nothing.
        without: ?[]u8,
    };

    /// Why the copy is freed. The save that commits the turn frees it, since the
    /// log then holds every update the turn sent; the turn's end frees the rest.
    pub const Reason = enum {
        /// The save committed the turn to the log.
        turn_saved,
        /// The turn ended.
        turn_ended,
        /// The session is being destroyed.
        session_released,
    };

    entries: std.ArrayList(Entry) = .empty,
    /// The bytes the entries hold.
    bytes: usize = 0,
    /// Entries that were not kept. Once one is dropped, every later entry is
    /// dropped too, so the copy is always an exact prefix of what the turn sent.
    dropped: usize = 0,
    /// The turn's latest progress params. A joiner that lists `sh.fx/turnProgress`
    /// gets them after the entries.
    progress: ?[]u8 = null,

    /// Keeps one entry with its own copies of the bytes. Past the limit, or when
    /// an allocation fails, the entry is dropped and logged.
    fn add(
        self: *RunningCopy,
        alloc: Allocator,
        method: []const u8,
        need: Need,
        with: []const u8,
        without: ?[]const u8,
    ) void {
        // Only a joined connection reads the copy, and one exists only where
        // `follow_supported` holds, so nothing is kept without it.
        if (comptime !follow_supported) return;
        const size = with.len + (if (without) |bytes| bytes.len else 0);
        if (self.dropped > 0 or self.bytes + size > limit_bytes) return self.drop(method, "limit");
        const kept_with = alloc.dupe(u8, with) catch return self.drop(method, "out_of_memory");
        var kept_without: ?[]u8 = null;
        if (without) |bytes| {
            kept_without = alloc.dupe(u8, bytes) catch {
                alloc.free(kept_with);
                return self.drop(method, "out_of_memory");
            };
        }
        self.entries.append(alloc, .{ .method = method, .need = need, .with = kept_with, .without = kept_without }) catch {
            alloc.free(kept_with);
            if (kept_without) |bytes| alloc.free(bytes);
            return self.drop(method, "out_of_memory");
        };
        self.bytes += size;
    }

    /// Records that an entry was not kept. Only the first drop is logged; the
    /// later ones are counted in `dropped`, which `release` logs.
    fn drop(self: *RunningCopy, method: []const u8, reason: []const u8) void {
        if (self.dropped == 0) debug_trace.logf(
            "acp",
            "event=running_copy_dropped method={s} reason={s} kept_bytes={d} later_updates=dropped",
            .{ method, reason, self.bytes },
        );
        self.dropped += 1;
    }

    /// Keeps `params` as the turn's latest progress, in place of an earlier one.
    fn setProgress(self: *RunningCopy, alloc: Allocator, params: []const u8) void {
        // Only a joined connection replays the progress; see `follow_supported`.
        if (comptime !follow_supported) return;
        if (self.progress) |current| if (std.mem.eql(u8, current, params)) return;
        const kept = alloc.dupe(u8, params) catch {
            debug_trace.logf(
                "acp",
                "event=running_copy_dropped method={s} reason=out_of_memory kept_bytes={d}",
                .{ sh_fx.method.session_turn_progress, self.bytes },
            );
            return;
        };
        if (self.progress) |old| alloc.free(old);
        self.progress = kept;
    }

    /// Frees every entry and the progress. A copy that is freed unsaved logs what
    /// it held: those updates reached the owner, and no joiner can see them now.
    fn release(self: *RunningCopy, alloc: Allocator, reason: Reason) void {
        // Nothing is kept without `follow_supported`, so there is nothing to free.
        if (comptime !follow_supported) return;
        if (self.entries.items.len > 0 or self.dropped > 0) {
            debug_trace.logf(
                "acp",
                "event=running_copy_released reason={s} entries={d} bytes={d} dropped={d}",
                .{ @tagName(reason), self.entries.items.len, self.bytes, self.dropped },
            );
        }
        for (self.entries.items) |entry| {
            alloc.free(entry.with);
            if (entry.without) |bytes| alloc.free(bytes);
        }
        self.entries.deinit(alloc);
        self.entries = .empty;
        if (self.progress) |bytes| alloc.free(bytes);
        self.progress = null;
        self.bytes = 0;
        self.dropped = 0;
    }
};

/// Whether `member` takes the `with` params of an entry that needs `need`.
fn memberTakes(member: *const Member, need: RunningCopy.Need) bool {
    return switch (need) {
        .none => true,
        .extension => |extension| member.extensions.contains(extension),
        .notices => member.client_notices,
        .steer_input => member.sendsSteerInput(),
        .except_sender => |sender| !connection.sameConnection(member.connection_id, sender),
    };
}

/// Frees `session`'s running copy under its audience lock. The save that commits
/// the turn calls this while it holds `session_write_mutex` (lock order: session
/// write, then audience), so the copy and the log change together. The turn's end
/// calls it without that lock, since the turn has no commit to match.
pub fn releaseRunningCopy(session: *ActiveSessionState, reason: RunningCopy.Reason) void {
    // Without `follow_supported` no copy is kept, so the save takes no lock for it.
    if (comptime !follow_supported) return;
    session.audience_mutex.lockUncancelable(io_mod.getIo());
    defer session.audience_mutex.unlock(io_mod.getIo());
    session.running_copy.release(mainLocked(session).?.alloc, reason);
}

/// The params of a steering chunk, with `sh.fx/steerInput` when `steer_input`
/// holds. The caller frees them.
pub fn steerChunkParams(
    alloc: Allocator,
    session_id: []const u8,
    message_id: []const u8,
    text: []const u8,
    request_id: ?jsonrpc.RequestId,
    input_id: ?[]const u8,
    steer_input: bool,
) ![]u8 {
    var update: std.Io.Writer.Allocating = .init(alloc);
    defer update.deinit();
    try update.writer.writeAll("{\"sessionId\":");
    try jsonrpc.writeJsonStr(session_id, &update.writer);
    try update.writer.writeAll(",\"update\":");
    try acp_types.writeSteeringUserMessageChunk(&update.writer, message_id, text, request_id, input_id, steer_input);
    try update.writer.writeByte('}');
    return try update.toOwnedSlice();
}

/// The member record this connection holds in `session`. A session the connection has open always
/// has its membership, and only the connection's reader thread changes the membership list, so no lock is needed.
fn ownMember(state: *ServerState, session: *ActiveSessionState) *Member {
    for (state.memberships.items) |membership| {
        if (membership.session == session) return membership.member;
    }
    unreachable;
}

/// The open session `session_id` names, when this connection leads it, or null.
pub fn findSession(state: *ServerState, session_id: []const u8) ?*ActiveSessionState {
    const index = membershipIndex(state, session_id) orelse return null;
    const membership = state.memberships.items[index];
    if (!leadsMembership(membership)) return null;
    return membership.session;
}

/// The session at `index` among the sessions this connection leads, oldest first, or null past
/// its end. A loop that may stop leading the session it is at reads the next index after that.
pub fn sessionAt(state: *ServerState, index: usize) ?*ActiveSessionState {
    var led_index: usize = 0;
    for (state.memberships.items) |membership| {
        if (!leadsMembership(membership)) continue;
        if (led_index == index) return membership.session;
        led_index += 1;
    }
    return null;
}

/// The newest session this connection leads, or null when none is led.
pub fn lastSession(state: *ServerState) ?*ActiveSessionState {
    var index = state.memberships.items.len;
    while (index > 0) {
        index -= 1;
        const membership = state.memberships.items[index];
        if (leadsMembership(membership)) return membership.session;
    }
    return null;
}

/// How many sessions this connection leads.
pub fn sessionCount(state: *ServerState) usize {
    var count: usize = 0;
    for (state.memberships.items) |membership| {
        if (leadsMembership(membership)) count += 1;
    }
    return count;
}

/// The oldest open session: the one session of the libfx kernel and the web
/// core. Null when none is open.
pub fn firstSession(state: *ServerState) ?*ActiveSessionState {
    return sessionAt(state, 0);
}

/// Whether the connection holds one session at a time, as the libfx kernel
/// and the web core do: opening a session there closes the open one.
pub fn holdsOneSession(state: *ServerState) bool {
    return host_target.is_wasm or state.host.cfg.minimal_kernel;
}

/// Takes `value` over as a newly open session, with the staged workspace
/// `binding` (null for the launch workspace), and returns it. The session
/// copies the default credential; each session then keeps its own. Opening
/// leaves every other session open (`tests/tla/acp/AcpSessions.tla`
/// OthersUntouched), except where the connection holds one session.
/// The record of this connection as a client of a session that is not open yet. The session that
/// opens next adopts it, so a legacy URL sink built before the open keeps its record.
pub fn pendingMember(state: *ServerState) !*Member {
    if (state.pending_member) |member| return member;
    state.pending_member = try newMember(state.host.alloc, state);
    return state.pending_member.?;
}

fn takePendingMember(state: *ServerState) !*Member {
    if (state.pending_member) |member| {
        state.pending_member = null;
        return member;
    }
    return newMember(state.host.alloc, state);
}

pub fn openSession(state: *ServerState, value: ActiveSessionState, binding: ?*workspace_binding.Binding) !*ActiveSessionState {
    try state.memberships.ensureUnusedCapacity(state.alloc, 1);
    const session = try state.alloc.create(ActiveSessionState);
    errdefer state.alloc.destroy(session);
    session.* = value;
    try reserveMemberLocked(session, state.host.alloc);
    const opener = try takePendingMember(state);
    errdefer opener.drop();
    session.client_writer = jsonrpc.Writer.initCallback(session, forwardToMain);
    // The connection defaults for new sessions are copied now, so this session keeps them when its main client changes.
    session.context_limits = state.context_limits;
    session.toolbox_behind = state.toolbox_behind;
    session.auto_compact_percent = state.auto_compact_percent;
    session.context_enabled = state.context_enabled;
    session.session_titles = state.session_titles;
    session.cache_warming = state.cache_warming;
    session.workspace_capture = state.workspace_capture;
    session.web_search_runtime = web_search_runtime.Runtime.init(.{ .provider = state.host.cfg.provider_set.gateway.fx_search });
    if (binding) |staged| {
        session.own_workspace = .{};
        try workspace_binding.install(state.alloc, &session.own_workspace, staged);
        session.workspace = &session.own_workspace;
    } else {
        session.workspace = &state.launch;
    }
    session.workspace_root = session.workspace.root;
    errdefer session.own_workspace.deinit(state.alloc);
    session.api_key = &.{};
    session.account_id = null;
    session.gateway_team = null;
    try copyDefaultCredential(state, session);
    _ = listMemberLocked(session, opener);
    addMembershipLocked(state, session, opener);
    // Without `follow_supported` no other connection can follow the session.
    if (comptime follow_supported) {
        {
            // A session that is not listed still works on this connection; another
            // connection of the process then cannot follow it, and opens the store.
            const shared = &state.host.shared;
            shared.register(state.alloc, session) catch |err| {
                debug_trace.logf("acp", "event=shared_session_not_registered session={s} err={s}", .{ session.session_id, @errorName(err) });
            };
        }
    }
    return session;
}

/// Gives `session` its own copy of the default credential.
fn copyDefaultCredential(state: *ServerState, session: *ActiveSessionState) !void {
    const api_key: []u8 = if (state.api_key.len > 0) try state.alloc.dupe(u8, state.api_key) else &.{};
    errdefer if (api_key.len > 0) secret.zeroAndFree(state.alloc, api_key);
    const account_id = if (state.account_id) |id| try state.alloc.dupe(u8, id) else null;
    errdefer if (account_id) |id| state.alloc.free(id);
    const gateway_team = if (state.gateway_team) |team| try state.alloc.dupe(u8, team) else null;
    freeSessionCredential(state.alloc, session);
    session.api_key = api_key;
    session.account_id = account_id;
    session.gateway_team = gateway_team;
    session.credential_source = state.credential_source;
    session.credential_refresh_after_ms = state.credential_refresh_after_ms;
}

fn freeSessionCredential(alloc: Allocator, session: *ActiveSessionState) void {
    if (session.api_key.len > 0) secret.zeroAndFree(alloc, @constCast(session.api_key));
    session.api_key = &.{};
    if (session.account_id) |id| alloc.free(id);
    session.account_id = null;
    if (session.gateway_team) |team| alloc.free(team);
    session.gateway_team = null;
}

/// Closes `session`: stops its turns and answers what waits for them, joins its subagents, and
/// ends every member. Its last holder frees it. Every other session runs on
/// (`tests/tla/acp/AcpSessions.tla` OthersUntouched).
pub fn closeSession(state: *ServerState, session: *ActiveSessionState) void {
    startClose(state, session);
    cancelAndReapPrompt(state, session);
    clearPendingLegacyUrls(session);
    disableSubagentHost(session);
    closeMembers(session);
    removeMembershipForSession(state, session);
}

/// Ends every membership this connection holds as `fx acp` exits. A session it left while another
/// member still leads stays open: only this membership goes.
fn closeAllSessions(state: *ServerState) void {
    while (state.memberships.items.len > 0) {
        const index = state.memberships.items.len - 1;
        const membership = state.memberships.items[index];
        switch (standing(membership)) {
            .follows => detachFollowerAt(state, index, .left),
            .led => closeSession(state, membership.session),
            .left => if (sessionHasMembers(membership.session)) {
                removeMembershipAt(state, index);
            } else {
                closeSession(state, membership.session);
            },
        }
    }
}

/// Whether this connection's end closes the session `membership` names: it leads the session, or it
/// has left and no member remains. A follow is not closed here, and neither is a session another member leads.
fn endsSession(membership: Membership) bool {
    return switch (standing(membership)) {
        .led => true,
        .follows => false,
        .left => !sessionHasMembers(membership.session),
    };
}

/// Whether a live member remains in `session`. Takes `audience_mutex`.
fn sessionHasMembers(session: *ActiveSessionState) bool {
    var audience = lockAudience(session);
    defer audience.unlock();
    return session.members.items.len > 0;
}

/// Closes every open session where the connection holds one, before it
/// opens another.
pub fn closeSessionsBeforeOpen(state: *ServerState) void {
    if (holdsOneSession(state)) {
        while (firstSession(state)) |session| {
            startClose(state, session);
            cancelAndReapPrompt(state, session);
            stopSubagentsForSwitch(session);
            closeSession(state, session);
        }
    }
}

/// What a connection that joins a running turn is told when the copy dropped
/// part of the turn's output (`RunningCopy.dropped`). The copy keeps the turn's
/// start, so the part after the limit, up to the join, is what is not shown.
const partial_copy_notice = "fx kept only the start of this turn's output, so part of it isn't shown.";

/// Replays the running turn's copy to `member`, a connection that joins the
/// session: each kept update in the version `member` takes, then the latest
/// progress when `member` lists `sh.fx/turnProgress`, then one notice when the
/// copy dropped updates. The caller holds the session's `session_write_mutex`
/// and `audience_mutex`, so the copy is not changed while it is replayed.
pub fn replayRunningCopy(member: *Member, alloc: Allocator, session: *ActiveSessionState) !void {
    // A joined connection replays the copy, and one exists only where `follow_supported` holds.
    if (comptime !follow_supported) return;
    const copy = &session.running_copy;
    for (copy.entries.items) |entry| {
        const params = (if (memberTakes(member, entry.need)) entry.with else entry.without) orelse continue;
        try member.writer.writeNotification(alloc, entry.method, params);
    }
    if (member.extensions.contains(.turn_progress)) {
        if (copy.progress) |params| try member.writer.writeNotification(alloc, sh_fx.method.session_turn_progress, params);
    }
    if (copy.dropped > 0) try writePartialCopyNotice(member, alloc, session.session_id);
}

/// Sends a prompt that starts a turn to every client that has the session open,
/// except `sender`, the client that sent it. The update is the text, then each
/// image, under one message id, built as a load replays a saved prompt
/// (`sendUserHistoryTurn` in sessions.zig), so the bytes match. The updates also
/// go into the running copy, so a client that joins later gets them once, in its
/// replay. Nothing is sent where `follow_supported` does not hold: there the owner
/// is the only client, and it sent the prompt. The caller holds no lock.
pub fn announcePromptTurn(
    session: *ActiveSessionState,
    sender: ConnectionId,
    alloc: Allocator,
    message_id: []const u8,
    text: []const u8,
    images: []const types.ImageAttachment,
) !void {
    if (comptime !follow_supported) return;
    if (text.len == 0 and images.len == 0) return;
    var audience = lockAudience(session);
    defer audience.unlock();
    if (text.len > 0) {
        var update: std.Io.Writer.Allocating = .init(alloc);
        defer update.deinit();
        try acp_types.writeUserMessageChunk(&update.writer, message_id, text);
        try deliverPromptUpdate(&audience, alloc, sender, session.session_id, update.writer.buffered());
    }
    for (images) |attachment| {
        var snapshot = image_attachments.loadVerifiedSnapshot(alloc, attachment, .{}) catch |err| {
            if (err == error.OutOfMemory) return err;
            debug_trace.logf("acp", "prompt image unavailable id={d} err={s}", .{ attachment.id, @errorName(err) });
            var unavailable: [96]u8 = undefined;
            const notice = try std.mem.print(&unavailable, "Image #{d} unavailable", .{attachment.id});
            var update: std.Io.Writer.Allocating = .init(alloc);
            defer update.deinit();
            try acp_types.writeUserMessageChunk(&update.writer, message_id, notice);
            try deliverPromptUpdate(&audience, alloc, sender, session.session_id, update.writer.buffered());
            continue;
        };
        defer snapshot.deinit(alloc);
        var update: std.Io.Writer.Allocating = .init(alloc);
        defer update.deinit();
        try acp_types.writeUserImageChunk(&update.writer, message_id, snapshot.media_type, snapshot.bytes);
        try deliverPromptUpdate(&audience, alloc, sender, session.session_id, update.writer.buffered());
    }
}

/// Sends one `session/update` built from `update` to every member but `sender`, and
/// records it in the running copy. The caller holds the audience.
fn deliverPromptUpdate(
    audience: *Audience,
    alloc: Allocator,
    sender: ConnectionId,
    session_id: []const u8,
    update: []const u8,
) !void {
    var params: std.Io.Writer.Allocating = .init(alloc);
    defer params.deinit();
    try acp_types.writeSessionUpdate(&params.writer, session_id, update);
    try audience.deliver(alloc, "session/update", .{ .except_sender = sender }, params.writer.buffered(), null);
}

/// Writes the partial-copy notice to `member`: an ACP notice when its client
/// shows them, otherwise an agent message.
fn writePartialCopyNotice(member: *Member, alloc: Allocator, session_id: []const u8) !void {
    var update: std.Io.Writer.Allocating = .init(alloc);
    defer update.deinit();
    if (member.client_notices) {
        try acp_types.writeNotice(&update.writer, "info", partial_copy_notice);
    } else {
        var message_id_storage: acp_types.MessageIdBuffer = undefined;
        const message_id = acp_types.generateMessageId(&message_id_storage);
        try acp_types.writeAgentMessageChunk(&update.writer, message_id, partial_copy_notice);
    }
    var params: std.Io.Writer.Allocating = .init(alloc);
    defer params.deinit();
    try acp_types.writeSessionUpdate(&params.writer, session_id, update.writer.buffered());
    try member.writer.writeNotification(alloc, "session/update", params.writer.buffered());
}

/// Removes `follower` from `session`'s followers, and reports whether it was
/// listed. The caller holds `session.audience_mutex`.
/// Makes the record for `state` as a client of a session, with `alloc`. The values a turn
/// reads are copied now. The runtimes `state` owned move into the record, because `state`'s
/// frame may end before the session does.
pub fn newMember(alloc: Allocator, state: *ServerState) !*Member {
    const member = try alloc.create(Member);
    errdefer alloc.destroy(member);
    member.* = .{
        .connection_id = state.connection_id,
        .host = state.host,
        .writer = &state.writer,
        .initialized = state.initialized,
        .terminal_ui = state.terminal_ui,
        .client_notices = state.client_notices,
        .client_compaction = state.client_compaction,
        .client_elicitation = state.client_elicitation,
        .extensions = state.extensions,
        .host_tools = state.host_tools,
        .terminal_client = state.terminal_client,
        .credential_source = state.credential_source,
        .gateway_source_preference = state.gateway_source_preference,
        .alloc = alloc,
    };
    state.host_tools = .{};
    state.terminal_client = .{};
    return member;
}

/// Makes room for one more member of `session`. Call it before the answer that lists the member
/// goes out, so listing after it cannot fail.
pub fn reserveMemberLocked(session: *ActiveSessionState, alloc: Allocator) Allocator.Error!void {
    try session.members.ensureUnusedCapacity(alloc, 1);
}

/// Lists `member` as the newest member of `session`, and takes over the list's reference to it.
/// The main client stays the oldest live member. Returns false, listing nothing, when a member for
/// the same connection is listed. Needs the room `reserveMemberLocked` made, and `audience_mutex`.
pub fn listMemberLocked(session: *ActiveSessionState, member: *Member) bool {
    for (session.members.items) |listed| {
        if (listed.connection_id == member.connection_id) return false;
    }
    if (session.last_main) |last| {
        session.last_main = null;
        last.drop();
    }
    session.members.appendAssumeCapacity(member);
    return true;
}

/// Lists `state` as a follower of a session a test builds by hand, with its membership.
pub fn joinMemberForTest(session: *ActiveSessionState, state: *ServerState) !void {
    try reserveMemberLocked(session, state.host.alloc);
    try state.memberships.ensureUnusedCapacity(state.alloc, 1);
    const member = try newMember(state.host.alloc, state);
    if (!listMemberLocked(session, member)) {
        member.destroy();
        return;
    }
    addMembershipLocked(state, session, member);
}

/// The number of sessions this connection follows, for a test.
pub fn followingCountForTest(state: *ServerState) usize {
    var count: usize = 0;
    for (state.memberships.items) |membership| {
        if (standing(membership) == .follows) count += 1;
    }
    return count;
}

/// The number of followers a test session lists: its members other than the opener.
pub fn followerCountForTest(session: *const ActiveSessionState) usize {
    return session.members.items.len -| 1;
}

/// Adds `state` as the opener of a session that a test builds by hand, with its membership. The
/// test frees the session with `freeMembers`.
pub fn attachOpenerForTest(session: *ActiveSessionState, state: *ServerState) !void {
    session.audience_mutex = .init;
    session.members = .empty;
    session.last_main = null;
    session.holders = 0;
    session.closed = false;
    try reserveMemberLocked(session, state.host.alloc);
    try state.memberships.ensureUnusedCapacity(state.alloc, 1);
    const opener = try newMember(state.host.alloc, state);
    _ = listMemberLocked(session, opener);
    addMembershipLocked(state, session, opener);
}

/// Drops the membership a test made for `session`, and its reference, so the test state stays usable.
pub fn dropMembershipForTest(state: *ServerState, session: *ActiveSessionState) void {
    for (state.memberships.items, 0..) |membership, index| {
        if (membership.session != session) continue;
        removeMembershipAt(state, index);
        return;
    }
}

/// Frees a test session's member list and each membership a test made for it, and the list
/// itself once no membership is left. A test defers it right after it attaches the session.
pub fn releaseTestSession(state: *ServerState, session: *ActiveSessionState) void {
    freeMembers(session, state.host.alloc);
    var index = state.memberships.items.len;
    while (index > 0) {
        index -= 1;
        if (state.memberships.items[index].session != session) continue;
        removeMembershipAt(state, index);
    }
    if (state.memberships.items.len == 0) {
        state.memberships.deinit(state.alloc);
        state.memberships = .empty;
    }
}

/// Drops a test state's memberships and their references, without closing the sessions a test
/// built by hand. The test frees the session's member list with `freeMembers` first.
pub fn releaseMembershipsForTest(state: *ServerState) void {
    for (state.memberships.items) |membership| membership.member.drop();
    state.memberships.deinit(state.alloc);
}

/// A turn's write to the main client failed. The main client leaves, and the result says whether a
/// member remains to take the turn. The caller holds no lock.
pub fn mainWriteFailed(session: *ActiveSessionState, failed: *Member) bool {
    var audience = lockAudience(session);
    defer audience.unlock();
    return removeMemberLocked(session, failed.connection_id);
}

/// Takes the live member for `connection_id` out of the audience and makes its record gone.
/// The oldest remaining member becomes the main. Returns whether a member remains; with none,
/// the main stays the record of the member that left last. The caller holds `audience_mutex`.
pub fn removeMemberLocked(session: *ActiveSessionState, connection_id: ConnectionId) bool {
    var was_main = false;
    for (session.members.items, 0..) |listed, index| {
        if (listed.connection_id != connection_id) continue;
        was_main = index == 0;
        _ = session.members.orderedRemove(index);
        markMemberGone(listed);
        releaseLeftLocked(session, listed);
        break;
    }
    prompt_test_controls.noteMemberRemoved();
    // A main that leaves answers the requests it still owes: `moved` when another member takes
    // the session, so its turns ask that member again, and `no_client` when none remains.
    if (session.members.items.len == 0) {
        if (was_main) markOwedRequests(session, connection_id, false);
        return false;
    }
    // Only where follow_supported holds can another member take the session.
    if (comptime !follow_supported) return false;
    if (was_main) markOwedRequests(session, connection_id, true);
    clearWriterDrop(session);
    return true;
}

/// Drops the list's reference to a record that left. The last member to leave hands its reference
/// to `last_main`, so a kept turn can still read the main client. The caller holds `audience_mutex`.
fn releaseLeftLocked(session: *ActiveSessionState, left: *Member) void {
    if (session.members.items.len == 0) {
        session.last_main = left;
        return;
    }
    left.drop();
}

/// Marks `member` gone before its connection's frame ends, so nothing writes through its writer
/// after that. Takes `legacy_url_mutex`, so a completion that is being written finishes first.
fn markMemberGone(member: *Member) void {
    member.legacy_url_mutex.lockUncancelable(io_mod.getIo());
    defer member.legacy_url_mutex.unlock(io_mod.getIo());
    member.gone = true;
}

/// Whether the record of `connection_id` is the session's only live member, so that its leave
/// leaves the session with no member. Takes `audience_mutex`.
fn isOnlyMember(session: *ActiveSessionState, connection_id: ConnectionId) bool {
    var audience = lockAudience(session);
    defer audience.unlock();
    return session.members.items.len == 1 and session.members.items[0].connection_id == connection_id;
}

/// A client leaves `session`: its input ended (`leave` is `.left`), or it closed the session (`.closed`).
/// Its record leaves the audience under `audience_mutex`. Returns whether a member remains. The caller
/// removes the session from its own lists, on its own thread.
pub fn leaveMember(state: *ServerState, session: *ActiveSessionState, leave: FollowerLeave) bool {
    var audience = lockAudience(session);
    defer audience.unlock();
    // The leaver's waiting input is withdrawn only when another member remains to take the turn. A close
    // answers it, because the client is still there to read the answer; an ended input has no reader.
    if (session.members.items.len > 1) {
        if (findMemberLocked(session, state.connection_id)) |member| withdrawFollowerInput(member, session, leave);
    }
    return removeMemberLocked(session, state.connection_id);
}

/// Answers each request that `leaver` still owes `session` and nobody has answered yet.
/// When another member remains (`new_main`), a permission becomes `moved`, so its turn asks
/// again of the new main. Otherwise, or for any other request, it becomes `no_client`.
fn markOwedRequests(session: *ActiveSessionState, leaver: ConnectionId, new_main: bool) void {
    const io = io_mod.getIo();
    session.outbound.mutex.lockUncancelable(io);
    defer session.outbound.mutex.unlock(io);
    var pending = session.outbound.pending.iterator();
    while (pending.next()) |entry| {
        if (entry.key_ptr.connection != leaver or entry.value_ptr.response != null) continue;
        entry.value_ptr.response = if (new_main and entry.value_ptr.kind == .permission) .{ .moved = true } else .{ .no_client = true };
    }
    session.outbound.cond.broadcast(io);
}

/// A new main has not failed, so the forwarding writer's drop flag, which a failed write
/// to the old main set, is cleared.
fn clearWriterDrop(session: *ActiveSessionState) void {
    const io = io_mod.getIo();
    session.client_writer.mutex.lockUncancelable(io);
    defer session.client_writer.mutex.unlock(io);
    session.client_writer.dropping = false;
}

/// How this connection stands in a session, read once under `audience_mutex`: `led` when its
/// record is the live main client, `follows` when another record is, and `left` when its record left.
const Standing = enum { led, follows, left };

fn standing(membership: Membership) Standing {
    var audience = lockAudience(membership.session);
    defer audience.unlock();
    if (membership.member.gone or membership.session.closed) return .left;
    if (mainLocked(membership.session) == membership.member) return .led;
    return .follows;
}

fn leadsMembership(membership: Membership) bool {
    return standing(membership) == .led;
}

/// The index of this connection's membership of the session `session_id` names, or null.
fn membershipIndex(state: *const ServerState, session_id: []const u8) ?usize {
    for (state.memberships.items, 0..) |membership, index| {
        if (std.mem.eql(u8, membership.session.session_id, session_id)) return index;
    }
    return null;
}

/// Whether this connection follows `session_id`: it has the session open, and another record leads it.
pub fn followsSession(state: *ServerState, session_id: []const u8) bool {
    const index = membershipIndex(state, session_id) orelse return false;
    return standing(state.memberships.items[index]) == .follows;
}

/// Adds `member` as this connection's membership of `session`, with a hold on the record. The
/// caller reserved room in `memberships`, and holds `audience_mutex` or owns a session not yet shared.
pub fn addMembershipLocked(state: *ServerState, session: *ActiveSessionState, member: *Member) void {
    member.hold();
    session.holders += 1;
    state.memberships.appendAssumeCapacity(.{ .session = session, .member = member });
}

/// Removes the membership at `index`: this connection stops having the session open. It drops the
/// membership's hold on the record, and frees the session when it is closed and this was its last
/// holder. Only this connection's reader thread calls it.
fn removeMembershipAt(state: *ServerState, index: usize) void {
    const membership = state.memberships.orderedRemove(index);
    var audience = lockAudience(membership.session);
    membership.session.holders -= 1;
    const freed = membership.session.closed and membership.session.holders == 0;
    audience.unlock();
    membership.member.drop();
    if (freed) destroySession(state, membership.session);
}

/// Removes this connection's membership of `session`, if it has one.
pub fn removeMembershipForSession(state: *ServerState, session: *ActiveSessionState) void {
    for (state.memberships.items, 0..) |membership, index| {
        if (membership.session == session) return removeMembershipAt(state, index);
    }
}

/// Forgets this connection's membership of `session_id`, if it has one.
pub fn forgetFollowing(state: *ServerState, session_id: []const u8) void {
    const index = membershipIndex(state, session_id) orelse return;
    removeMembershipAt(state, index);
}

/// Why a connection stops following a session. `closed`: it closed the session and
/// still hears its answers. `left`: its connection ended or its writes failed, so
/// it hears nothing more.
pub const FollowerLeave = enum { closed, left };

/// Ends `state`'s follow of `session_id`: its record leaves the session, and the input it still
/// has waiting is withdrawn (`withdrawFollowerInput`). Its membership ends too.
pub fn detachFollower(state: *ServerState, session_id: []const u8, leave: FollowerLeave) void {
    // A follower can exist only where `follow_supported` holds.
    if (comptime !follow_supported) return;
    const index = membershipIndex(state, session_id) orelse return;
    detachFollowerAt(state, index, leave);
}

fn detachFollowerAt(state: *ServerState, index: usize, leave: FollowerLeave) void {
    const membership = state.memberships.items[index];
    debug_trace.logf("acp", "event=follower_detached session={s} reason={s}", .{
        membership.session.session_id,
        switch (leave) {
            .closed => "close",
            .left => "connection_end",
        },
    });
    {
        var audience = lockAudience(membership.session);
        defer audience.unlock();
        if (findMemberLocked(membership.session, state.connection_id)) |member| withdrawFollowerInput(member, membership.session, leave);
        _ = removeMemberLocked(membership.session, state.connection_id);
    }
    removeMembershipAt(state, index);
}

/// The live member record for `connection_id`, or null. The caller holds `audience_mutex`.
pub fn findMemberLocked(session: *ActiveSessionState, connection_id: ConnectionId) ?*Member {
    for (session.members.items) |listed| {
        if (listed.connection_id == connection_id) return listed;
    }
    return null;
}

/// Frees the member lists of `session` a test built by hand, and the references they keep.
pub fn freeMembers(session: *ActiveSessionState, alloc: Allocator) void {
    for (session.members.items) |member| member.drop();
    session.members.deinit(alloc);
    if (session.last_main) |last| last.drop();
    session.last_main = null;
}

/// Withdraws the input that a following connection still has waiting: its late
/// steers, its queued prompts, and its steers that the running turn has not taken.
/// A steer a turn took stays with the turn. Each withdrawn entry is traced. For a
/// `closed` follower, which is still connected, each withdrawn prompt and steer gets
/// the cancelled answer that the owner's close gives its drained input, and the
/// answers are written before the close's own answer. A follower that `left` gets no
/// write.
///
/// The caller holds the session's audience lock. This takes the line lock inside it,
/// and the steering runtime's lock inside that. Nothing takes the line lock and then
/// the audience or shared lock: the line lock's sections call neither, and the
/// subagent authority lock's sections reach neither, so this order cannot cycle.
fn withdrawFollowerInput(state: *Member, session: *ActiveSessionState, leave: FollowerLeave) void {
    // A follower can exist only where `follow_supported` holds.
    if (comptime !follow_supported) return;
    var taken: prompt_line.Drained = .{};
    defer taken.deinit(state.alloc);
    {
        session.waiting_prompts.lock();
        defer session.waiting_prompts.unlock();
        // Both moves allocate before they remove anything, so a failure leaves that
        // part of the input where it was, and it is traced.
        taken = session.waiting_prompts.takeFromLocked(state.alloc, state.connection_id) catch |err| {
            debug_trace.logf("acp", "event=waiting_input_kept session={s} reason=out_of_memory err={s}", .{ session.session_id, @errorName(err) });
            return;
        };
        session.steering.takeRequestsFrom(state.alloc, state.connection_id, &taken.late) catch |err| {
            debug_trace.logf("acp", "event=waiting_input_kept session={s} reason=out_of_memory err={s}", .{ session.session_id, @errorName(err) });
        };
    }
    for (taken.late.items) |steer| {
        traceWaitingInputDropped(session, steer.request_id, leave);
        if (leave == .closed) writeCancelledAnswer(state, steer.request_id);
    }
    for (taken.queue.items) |queued| {
        traceWaitingInputDropped(session, queued.msg.id, leave);
        if (leave == .closed) if (queued.msg.id) |id| writeCancelledAnswer(state, id);
    }
}

/// Writes the cancelled answer to `state`'s own connection, the answer the owner's
/// close gives input it drains (`answerCancelled`): `-32800`, "Request cancelled".
fn writeCancelledAnswer(state: *Member, id: jsonrpc.RequestId) void {
    const answer: Answer = .{ .rpc_error = .{
        .code = ErrorCode.request_cancelled,
        .message = "Request cancelled",
    } };
    writeAnswer(state.writer, state.alloc, id, answer) catch |err| debug_trace.logf("acp", "failed to answer withdrawn input err={s}", .{@errorName(err)});
}

/// Traces one waiting input that a follower's leave withdraws. The reason says
/// whether the follower closed the session or left.
fn traceWaitingInputDropped(session: *const ActiveSessionState, id: ?jsonrpc.RequestId, leave: FollowerLeave) void {
    var buf: [32]u8 = undefined;
    debug_trace.logf("acp", "event=waiting_input_dropped session={s} request={s} reason={s}", .{
        session.session_id,
        requestText(id, &buf),
        switch (leave) {
            .closed => "follower_closed",
            .left => "follower_left",
        },
    });
}

/// Ends the session's membership as it closes: every record leaves the audience, and the
/// session is marked closed. Its last holder frees it (`removeMembershipAt`).
fn closeMembers(session: *ActiveSessionState) void {
    var audience = lockAudience(session);
    defer audience.unlock();
    session.closed = true;
    for (session.members.items) |member| {
        markMemberGone(member);
        debug_trace.logf("acp", "event=follower_dropped session={s} reason=session_closed", .{session.session_id});
        member.drop();
    }
    session.members.clearRetainingCapacity();
    if (session.last_main) |last| {
        session.last_main = null;
        last.drop();
    }
}

/// The client closes `session`, or opens another where the connection holds
/// one: its subagents stop as cancelled and owe no report, and nothing they
/// posted for it stays (D41, D97; the app does the same in `stopSet`). The
/// tree closes first, so no work the stop ends owes a report, and the host is
/// joined before the queue is dropped, so nothing posts after it. A quit
/// leaves reports owed and loses no queue it could keep, so it does not call
/// this, and neither does opening another session where the connection holds
/// many: every other session keeps its subagents. Call this before
/// `closeSession`.
pub fn stopSubagentsForSwitch(session: *ActiveSessionState) void {
    if (session.subagent_host) |host| host.closeTree();
    disableSubagentHost(session);
    dropQueuedMail(session, "session_switch");
}

/// Drops the mail `postAcpReport` queued for `session` that no prompt took,
/// and names each item in the trace with `reason`. A report that was owed
/// stays owed in the session's log, which posts it again when the session
/// opens. A message a child sent is in no log of the parent, so a drop of it
/// leaves only the child's own log and the trace line.
fn dropQueuedMail(session: *ActiveSessionState, reason: []const u8) void {
    const alloc = std.heap.c_allocator;
    session.report_mutex.lockUncancelable(io_mod.getIo());
    defer session.report_mutex.unlock(io_mod.getIo());
    const Drop = struct {
        session: *ActiveSessionState,
        reason: []const u8,

        fn decide(self: *@This(), place: usize, queued: *const worker_runtime.QueuedPrompt) bool {
            const call: ?*const ReportCall = if (place < self.session.report_calls.items.len) &self.session.report_calls.items[place] else null;
            debug_trace.logf("acp", "event=subagent_mail_dropped session={s} kind={s} child={s} work={s} reason={s}", .{
                self.session.session_id,
                @tagName(queued.mail),
                if (call) |value| value.child_id else "",
                if (call) |value| value.work_id else "",
                self.reason,
            });
            return true;
        }
    };
    var drop: Drop = .{ .session = session, .reason = reason };
    _ = session.worker.discardQueuedWhere(alloc, &drop, Drop.decide);
    for (session.report_calls.items) |*call| call.deinit(alloc);
    session.report_calls.shrinkRetainingCapacity(0);
}

fn destroySession(state: *ServerState, active: *ActiveSessionState) void {
    // The session's requests end with it. Each answer that nobody took is freed here.
    var pending = active.outbound.pending.valueIterator();
    while (pending.next()) |entry| {
        if (entry.response) |*response| response.deinit(state.alloc);
    }
    active.outbound.pending.deinit(state.alloc);
    if (active.title_task) |task| {
        debug_trace.logf("session", "event=title_generation_dropped reason=session_release", .{});
        task.destroy();
    }
    state.alloc.free(active.session_id);
    state.alloc.free(active.model);
    if (active.client_system_prompt.len > 0) state.alloc.free(active.client_system_prompt);
    active.tool_identities.deinit(state.alloc);
    active.steering.deinit(state.alloc);
    {
        // Closing answers what waits first, so anything left here is lost.
        active.waiting_prompts.lock();
        const late = active.waiting_prompts.late.items.len;
        const queued = active.waiting_prompts.queue.items.len;
        active.waiting_prompts.unlock();
        if (late + queued > 0) {
            debug_trace.logf("acp", "dropped waiting prompts steers={d} queued={d} reason=session_release", .{ late, queued });
        }
    }
    active.waiting_prompts.deinit(state.alloc);
    if (active.journal) |*journal| journal.deinit(state.alloc);
    active.staged_images.deinit(state.alloc);
    types.freePermissionGrantSlice(state.alloc, active.session_grants);
    if (comptime !host_target.is_wasm) {
        // Its servers stop on a thread of their own, so closing one session
        // never holds up another's requests; `deinit` waits for them.
        if (active.mcp_host) |h| h.stop();
    }
    active.session_rt.deinit(state.alloc);
    if (active.v2) |v2| v2.close();
    active.turn_capture.deinit();
    if (active.wasm_state) |*wasm_state| wasm_state.deinit(state.alloc);
    if (active.wasm_revision) |revision| state.alloc.free(revision);
    active.worker.deinit(std.heap.c_allocator);
    for (active.report_calls.items) |*call| call.deinit(std.heap.c_allocator);
    active.report_calls.deinit(std.heap.c_allocator);
    active.web_search_runtime.deinit();
    freeSessionCredential(state.alloc, active);
    // The copy goes before the store is freed; a turn's copy is never kept past its session.
    active.running_copy.release(state.alloc, .session_released);
    // Each follower is owned by its own connection; only the list is freed here.
    active.members.deinit(state.host.alloc);
    active.own_workspace.deinit(state.alloc);
    state.alloc.destroy(active);
}

pub fn enableSubagentHost(session: *ActiveSessionState) void {
    disableSubagentHost(session);
    const v2 = session.v2 orelse return;
    enableSubagentHostV2(session, v2);
}

/// Subagents on v2 keep their state in the session's log (D22). A host that
/// cannot start leaves them off and says why, as on v1.
fn enableSubagentHostV2(active: *ActiveSessionState, v2: *session_adapter.Session) void {
    const main_record = holdMain(active);
    defer main_record.drop();
    const alloc = main_record.alloc;
    const children = alloc.create(subagent_child_state.V2Children) catch |err| {
        debug_trace.logf("acp", "subagent host unavailable session={s} err={s}", .{ active.session_id, @errorName(err) });
        return;
    };
    children.* = subagent_child_state.V2Children.init(alloc, v2, active.workspace_root);
    active.subagent_host = subagent_tool_host.Runtime.create(
        alloc,
        children,
        .{ .context = active, .resolve_fn = resolveSubagentAuthority },
        .{ .context = active, .run_fn = prompt_handler.runSubagentChild },
    ) catch |err| {
        debug_trace.logf("acp", "subagent host unavailable session={s} err={s}", .{ active.session_id, @errorName(err) });
        children.deinit();
        alloc.destroy(children);
        return;
    };
    // A child whose profile lists a tool kept behind toolbox keeps toolbox.
    active.subagent_host.?.authority_resolver.toolbox_behind = &active.toolbox_behind;
    active.subagent_host.?.report_sink = .{ .context = active, .post_fn = postAcpReport };
    active.subagent_v2_children = children;
    // What a restart left owed reaches the session as its next turns.
    active.subagent_host.?.resumeReports(v2);
}

/// The host's report sink: queues the report or message for the prompt,
/// which runs it as the session's next turn once its own turn ends.
fn postAcpReport(
    raw: ?*anyopaque,
    _: *subagent_tool_host.Runtime,
    delivery: subagent_tool_host.Delivery,
) subagent_tool_host.PostReportError!void {
    const session: *ActiveSessionState = @ptrCast(@alignCast(raw.?));
    const alloc = std.heap.c_allocator;
    const text = switch (delivery) {
        .report => |report| try subagent_reports.message(alloc, report, session.max_tool_result_bytes),
        .message => |message| try subagent_reports.messageText(alloc, message.agent, message.child_id, message.text, session.max_tool_result_bytes, null, message.user_typed),
    };
    var owns_text = true;
    defer if (owns_text) alloc.free(text);
    var call = try ReportCall.init(alloc, delivery);
    var owns_call = true;
    defer if (owns_call) call.deinit(alloc);
    session.report_mutex.lockUncancelable(io_mod.getIo());
    defer session.report_mutex.unlock(io_mod.getIo());
    try session.report_calls.append(alloc, call);
    owns_call = false;
    session.worker.postMail(alloc, .{
        .prompt = text,
        .images = &.{},
        .model = &.{},
        .api_key = &.{},
        .permission_mode = .ask,
        .history = &.{},
        .grants = &.{},
        .author = .child,
        .mail = if (delivery == .report) .report else .message,
    }) catch |err| {
        var dropped = session.report_calls.pop().?;
        dropped.deinit(alloc);
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.QueueFull => error.QueueFull,
            else => error.AgentGone,
        };
    };
    owns_text = false;
}

/// What a queued report answers. All strings are owned (`std.heap.c_allocator`).
pub const ReportCall = struct {
    /// The subagent call that sent the work; empty for a message a child sent.
    call_id: []u8,
    child_id: []u8,
    work_id: []u8,
    /// How the work ended; null for a message.
    outcome: ?subagent_child_state.Outcome,

    fn init(alloc: Allocator, delivery: subagent_tool_host.Delivery) !ReportCall {
        const call_id = try alloc.dupe(u8, switch (delivery) {
            .report => |report| report.call_id,
            .message => "",
        });
        errdefer alloc.free(call_id);
        const child_id = try alloc.dupe(u8, switch (delivery) {
            .report => |report| report.child_id,
            .message => |message| message.child_id,
        });
        errdefer alloc.free(child_id);
        const work_id = try alloc.dupe(u8, switch (delivery) {
            .report => |report| report.work_id,
            .message => "",
        });
        return .{ .call_id = call_id, .child_id = child_id, .work_id = work_id, .outcome = switch (delivery) {
            .report => |report| report.outcome,
            .message => null,
        } };
    }

    pub fn deinit(self: *ReportCall, alloc: Allocator) void {
        alloc.free(self.call_id);
        alloc.free(self.child_id);
        alloc.free(self.work_id);
    }
};

/// What the oldest queued report answers, owned by the caller. Null when
/// the queue holds none.
pub fn takeReportCall(session: *ActiveSessionState) ?ReportCall {
    session.report_mutex.lockUncancelable(io_mod.getIo());
    defer session.report_mutex.unlock(io_mod.getIo());
    if (session.report_calls.items.len == 0) return null;
    return session.report_calls.orderedRemove(0);
}

fn resolveSubagentAuthority(
    raw: ?*anyopaque,
    alloc: Allocator,
    root_id: []const u8,
) subagent_authority.HostResolveError!subagent_authority.HostAuthority {
    const active: *ActiveSessionState = @ptrCast(@alignCast(raw.?));
    const main_record = holdMain(active);
    defer main_record.drop();
    const state = main_record;
    if (!std.mem.eql(u8, active.session_id, root_id)) {
        return error.HostAuthorityUnavailable;
    }
    state.host.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
    defer state.host.subagent_authority_mutex.unlock(io_mod.getIo());
    const integrations = if (active.mcp_host) |h|
        h.catalog.snapshotToolNames(alloc)
    else
        alloc.alloc([]u8, 0);
    const owned_integrations = integrations catch return error.OutOfMemory;
    defer {
        for (owned_integrations) |name| alloc.free(name);
        alloc.free(owned_integrations);
    }
    var mcp_view = if (active.mcp_host) |h|
        try h.catalog.snapshotAccessView(alloc, root_id, root_id)
    else
        null;
    defer if (mcp_view) |*view| view.deinit(alloc);
    var permission_state = active.session_rt.snapshotPermissionState(alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.HostAuthorityUnavailable,
    };
    defer permission_state.deinit(alloc);
    return subagent_tool_host.captureHostAuthorityWithMcpView(
        alloc,
        .{
            .tool_set = builtin_tools.advertisement_set,
            .mode = .{
                .active = .{
                    .registry = state.host.cfg.mode_registry,
                    .id = active.mode,
                },
            },
        },
        owned_integrations,
        active.permission_rules,
        active.session_grants,
        permission_state,
        if (mcp_view) |*view| view else null,
    );
}

/// Joins the child threads before the session they append to can close
/// (`tests/tla/session_manager/Wiring.tla` ParentOutlivesChildren).
pub fn disableSubagentHost(session: *ActiveSessionState) void {
    if (session.subagent_host) |host| {
        host.deinit();
        session.subagent_host = null;
    }
    if (session.subagent_v2_children) |children| {
        children.deinit();
        const main_record = holdMain(session);
        defer main_record.drop();
        main_record.alloc.destroy(children);
        session.subagent_v2_children = null;
    }
}

/// What one run does beyond its transport. `run`, the stdio entry, sets `lead`.
/// A socket connection sets `leader_info`. `runWithTransport`, the SDK's
/// in-process transport, sets none.
const RunOptions = struct {
    /// Serve the leader socket and record it in each session lock, so another
    /// process can find this one. Native hosts only (see `leader_supported`).
    lead: bool = false,
    /// The process's shared parts. Every connection of one process uses one host.
    host: *Host,
    /// Set on a socket connection, which answers `initialize` with its pid and sessions.
    leader_info: ?LeaderInfo = null,
};

const leader_supported = process_host.leader_supported;

/// Whether a second connection can open a session of this process, so whether the
/// follow code is compiled. Defined in `connection.zig`; each follow-only entry
/// returns at comptime when it is false, and the compiler drops its code.
pub const follow_supported = connection.follow_supported;

comptime {
    // A second connection exists only through the leader socket, so the two gates agree.
    std.debug.assert(follow_supported == leader_supported);
}

pub const ConnectionId = connection.ConnectionId;
const no_connection = connection.no_connection;
const newConnectionId = connection.newConnectionId;
const sameConnection = connection.sameConnection;

/// The trace file belongs to the process, so the stdio entries configure it
/// before their host opens its store, which traces through it.
fn configureProcessTrace(cfg: Config) !void {
    if (cfg.log_file) |path| {
        try debug_trace.configure(.{ .file_path = path });
    }
}

pub fn run(alloc: Allocator, cfg: Config) !void {
    try configureProcessTrace(cfg);
    // One host for every connection this process serves. `runServer` closes its
    // sessions before it returns. The host's `deinit` then stops the leader, which
    // awaits its accept task and cancels its connections, and frees the store and
    // the table, so nothing a connection uses is freed while it still runs.
    var host = Host.open(alloc, cfg);
    defer host.deinit();
    const served = runServer(alloc, cfg, jsonrpc.Reader.init(), jsonrpc.Writer.init(), .{ .lead = true, .host = &host });
    waitForSessionsToEnd(&host);
    return served;
}

/// The exit rule: once the stdio connection has ended, fx exits when no session has a
/// member and no turn runs. A session a follower took over stays open until that follower
/// leaves, and the leader keeps serving it until then.
fn waitForSessionsToEnd(host: *Host) void {
    if (comptime follow_supported) host.shared.waitUntilEmpty();
}

pub fn runWithTransport(
    alloc: Allocator,
    cfg: Config,
    reader_value: jsonrpc.Reader,
    writer_value: jsonrpc.Writer,
) !void {
    try configureProcessTrace(cfg);
    var host = Host.open(alloc, cfg);
    defer host.deinit();
    return runServer(alloc, cfg, reader_value, writer_value, .{ .host = &host });
}

fn runServer(
    alloc: Allocator,
    cfg: Config,
    reader_value: jsonrpc.Reader,
    writer_value: jsonrpc.Writer,
    options: RunOptions,
) !void {
    var state = ServerState{
        .alloc = alloc,
        .host = options.host,
        .writer = writer_value,
        .connection_id = newConnectionId(),
        .leader_info = options.leader_info,
        .terminal_client = terminal_client_runtime.Runtime.init(
            cfg.process_provider,
        ),
    };
    defer state.deinit();

    if (comptime leader_supported) {
        if (options.lead) startLeader(&state);
    }

    var reader = reader_value;
    while (!state.terminate_connection) {
        reapPrompts(&state);
        const line_result = reader.readLine(alloc) catch break;
        if (line_result == null) break;
        const line = switch (line_result.?) {
            // `tests/tla/acp/AcpSessionTarget.tla` OversizeIs32600 and NeverAuthCode.
            .overflow => {
                state.writer.writeError(alloc, null, .{
                    .code = ErrorCode.invalid_request,
                    .message = "Request frame too large",
                }) catch break;
                continue;
            },
            .line => |value| value,
        };
        defer alloc.free(line);

        var msg = jsonrpc.parseMessage(alloc, line) catch |err| {
            const code = switch (err) {
                error.ParseError => ErrorCode.parse_error,
                else => ErrorCode.invalid_request,
            };
            state.writer.writeError(alloc, null, .{ .code = code, .message = "Parse error" }) catch break;
            continue;
        };
        defer jsonrpc.freeMessage(alloc, &msg);

        if (msg.isResponse()) {
            handleClientResponse(&state, alloc, &msg);
            continue;
        }

        if (!shouldRespondToMessage(&msg)) {
            dispatchNotification(&state, alloc, &msg) catch {};
            if (state.terminate_connection) break;
            continue;
        }

        dispatch(&state, alloc, &msg) catch |err| {
            const auth_notice = auth_runtime.preparationFailureNotice(err);
            state.writer.writeError(alloc, msg.id, .{
                .code = if (auth_notice != null) ErrorCode.invalid_request else ErrorCode.internal_error,
                .message = auth_notice orelse @errorName(err),
            }) catch break;
        };
        if (state.terminate_connection) break;
    }
    // A client that listed sh.fx/keepTurnOnDisconnect keeps its running
    // turns: they finish and are saved, and state.deinit() joins them and the
    // queued prompts. Any other client's turns stop first, as before, so their
    // waiting requests end as cancels. Then the client can't answer any more,
    // so end what fx still waits on and refuse new requests.
    // A session that a follower still has open goes on with that follower as its main, so
    // its turn is not cancelled here (the leave rule). Other sessions stop as before.
    // Once this connection's record leaves a session, it no longer leads it, so the next led
    // session is always at index 0. A turn that stops because its last client leaves is
    // cancelled and ends before that client's record leaves, so the client still hears the turn's end.
    while (sessionAt(&state, 0)) |session| {
        const own_member = ownMember(&state, session);
        if (!own_member.extensions.contains(.keep_turn_on_disconnect) and !runningTurnKeeps(session) and
            isOnlyMember(session, own_member.connection_id))
        {
            handleCancel(session, false);
            // The client can't answer any more, so what the turn waits on ends before the turn is awaited.
            endClientInput(&state);
            reapSessionPrompt(session, true);
        }
        if (leaveMember(&state, session, .left)) removeMembershipForSession(&state, session);
    }
    endClientInput(&state);
}

/// Whether the session's running turn was started by a client that listed
/// `sh.fx/keepTurnOnDisconnect`. The last client to leave does not stop such a
/// turn, because the turn belongs to its sender, not to the client leaving.
fn runningTurnKeeps(session: *const ActiveSessionState) bool {
    const active = session.prompt orelse return false;
    return active.keep_turn;
}

/// Starts this process's leader socket and records it in every session lock
/// this process holds. If the leader cannot start, or cannot record itself,
/// fx acp runs without one, and the reason is traced.
fn startLeader(state: *ServerState) void {
    const store = sessionsStore(state.host) orelse return;
    const io = io_mod.getIo();
    const host = state.host;
    // Set before the leader starts, since a client may connect at once.
    host.leader_info = .{
        .pid = @intCast(std.c.getpid()),
        .sessions = .{ .context = store, .copy_ids = copyLeadingIds },
    };
    const leader = leader_mod.Leader.start(host.alloc, io, io_mod.getenv("TMPDIR"), .{
        .context = host,
        .run = runSocketConnection,
    }) catch |err| {
        debug_trace.logf("acp", "event=leader_not_started err={s}", .{@errorName(err)});
        return;
    };
    store.manager.setLeaderRecord(leader.record) catch |err| {
        debug_trace.logf("acp", "event=leader_not_started err={s}", .{@errorName(err)});
        leader.stop(io);
        return;
    };
    host.leader = leader;
}

/// The leader's session list: the ids the store's manager leads, copied under
/// the manager's own short lock. The caller frees each id and the slice.
fn copyLeadingIds(context: ?*anyopaque, alloc: Allocator) error{OutOfMemory}![][]u8 {
    const store: *session_adapter.Store = @ptrCast(@alignCast(context.?));
    return store.manager.leadingIds(alloc);
}

/// Runs one socket connection as a full ACP connection of this process: the same
/// `runServer` the stdio connection runs, with the process's host, and the socket's
/// reader and writer. It never leads, so it starts no leader. It returns after its
/// own `deinit`, which the leader waits for.
fn runSocketConnection(context: ?*anyopaque, reader: jsonrpc.Reader, writer: jsonrpc.Writer) void {
    const host: *Host = @ptrCast(@alignCast(context.?));
    runServer(host.alloc, host.cfg, reader, writer, .{
        .host = host,
        .leader_info = host.leader_info,
    }) catch |err| {
        debug_trace.logf("acp", "event=leader_connection_failed err={s}", .{@errorName(err)});
    };
}

fn shouldRespondToMessage(msg: *const jsonrpc.Message) bool {
    return !msg.isResponse() and msg.id != null;
}

/// Stores a client's answer in the request it answers. Only the sessions this
/// connection leads can hold its requests, so only those are searched. A second
/// answer, or an answer to no request, frees its copies.
fn handleClientResponse(state: *ServerState, alloc: Allocator, msg: *const jsonrpc.Message) void {
    const id = msg.id orelse return;
    const numeric_id: u64 = switch (id) {
        .integer => |value| if (value > 0) @intCast(value) else return,
        else => return,
    };
    const result_copy = if (msg.result_raw) |raw| alloc.dupe(u8, raw) catch return else null;
    const error_copy = if (msg.error_raw) |raw| alloc.dupe(u8, raw) catch {
        if (result_copy) |value| alloc.free(value);
        return;
    } else null;

    const io = io_mod.getIo();
    var index: usize = 0;
    while (sessionAt(state, index)) |session| : (index += 1) {
        const request: OutboundRequest = .{ .connection = ownMember(state, session).connection_id, .id = numeric_id };
        session.outbound.mutex.lockUncancelable(io);
        const pending = session.outbound.pending.getPtr(request) orelse {
            session.outbound.mutex.unlock(io);
            continue;
        };
        if (pending.response != null) {
            session.outbound.mutex.unlock(io);
            break;
        }
        pending.response = .{
            .result_json = result_copy,
            .error_json = error_copy,
        };
        session.outbound.cond.broadcast(io);
        session.outbound.mutex.unlock(io);
        return;
    }
    if (result_copy) |value| alloc.free(value);
    if (error_copy) |value| alloc.free(value);
}

fn parsePermissionDecision(root: std.json.Value) ?types.ToolPermissionDecision {
    if (root != .object) return null;
    const outcome = root.object.get("outcome") orelse return null;
    if (outcome != .object) return null;
    const kind = outcome.object.get("outcome") orelse return null;
    if (kind != .string) return null;
    if (std.mem.eql(u8, kind.string, "cancelled")) return .deny;
    if (!std.mem.eql(u8, kind.string, "selected")) return null;
    const option = outcome.object.get("optionId") orelse return null;
    if (option != .string) return null;
    if (std.mem.eql(u8, option.string, "allow_once")) return .once;
    if (std.mem.eql(u8, option.string, "allow_always")) return .always;
    if (std.mem.eql(u8, option.string, "reject_once")) return .deny;
    return null;
}

/// Starts a request to the client that `session`'s turn waits for. Null when that
/// client's input has ended, or when the session already waits for
/// `max_pending_outbound` of them. The connection's lock is taken before the
/// session's, the same order `endClientInput` uses.
pub fn beginOutboundRequest(session: *ActiveSessionState, kind: OutboundKind) !?OutboundRequest {
    const main_record = holdMain(session);
    defer main_record.drop();
    const request = (try putOutboundRequest(session, main_record, kind)) orelse return null;
    answerIfMemberGone(session, main_record, request);
    return request;
}

/// Adds a pending request to `session` for the main record `state`, or returns null when that
/// client's input has ended or the session's pending requests are full.
fn putOutboundRequest(session: *ActiveSessionState, state: *Member, kind: OutboundKind) !?OutboundRequest {
    const io = io_mod.getIo();
    state.outbound_mutex.lockUncancelable(io);
    defer state.outbound_mutex.unlock(io);
    // The client's input has ended, so no answer can arrive.
    if (state.input_ended) return null;
    if (state.next_outbound_request_id > @as(u64, @intCast(std.math.maxInt(i64)))) return null;
    session.outbound.mutex.lockUncancelable(io);
    defer session.outbound.mutex.unlock(io);
    if (session.outbound.pending.count() >= max_pending_outbound) return null;
    const request: OutboundRequest = .{
        .connection = state.connection_id,
        .id = state.next_outbound_request_id,
    };
    state.next_outbound_request_id += 1;
    try session.outbound.pending.put(state.alloc, request, .{ .kind = kind });
    return request;
}

/// Answers `request` `no_client` when its target record has already left. A leave answers only the
/// requests pending at that moment, so a request put after the leave would wait forever. The check
/// runs after the put, so a leave that comes later finds the request pending and answers it.
fn answerIfMemberGone(session: *ActiveSessionState, member: *Member, request: OutboundRequest) void {
    const io = io_mod.getIo();
    {
        var audience = lockAudience(session);
        defer audience.unlock();
        if (!member.gone) return;
    }
    session.outbound.mutex.lockUncancelable(io);
    defer session.outbound.mutex.unlock(io);
    if (session.outbound.pending.getPtr(request)) |entry| {
        if (entry.response == null) entry.response = .{ .no_client = true };
    }
    session.outbound.cond.broadcast(io);
}

/// Whether the main client's input has ended (`endClientInput`), so a request to
/// it can't get an answer.
pub fn clientInputEnded(session: *ActiveSessionState) bool {
    const main_record = holdMain(session);
    defer main_record.drop();
    const state = main_record;
    state.outbound_mutex.lockUncancelable(io_mod.getIo());
    defer state.outbound_mutex.unlock(io_mod.getIo());
    return state.input_ended;
}

/// Waits for the answer to `request`, or for a cancel, or for the client's input to end.
/// The wait has no deadline of its own (R2.3): a cancel, the input ending, or the
/// session's close each end it, and each one answers the request.
pub fn awaitOutboundResponse(session: *ActiveSessionState, request: OutboundRequest, kind: OutboundKind) ?OutboundResponse {
    const io = io_mod.getIo();
    session.outbound.mutex.lockUncancelable(io);
    defer session.outbound.mutex.unlock(io);
    while (true) {
        const pending = session.outbound.pending.getPtr(request) orelse return null;
        if (pending.kind != kind) return null;
        if (pending.response) |response| {
            _ = session.outbound.pending.remove(request);
            return response;
        }
        prompt_test_controls.noteOutboundWaiting();
        session.outbound.cond.wait(io, &session.outbound.mutex) catch {
            _ = cancelOutboundRequestLocked(session, request);
        };
    }
}

/// Takes the event of an `awaitOutboundResponse` task in `select` after
/// `cancelOutboundRequest` made it return, and frees any response. Call when
/// that event is the only one outstanding; `select` then has nothing left to
/// cancel. `select` must hold a `response: ?OutboundResponse` event.
pub fn takeCancelledResponse(session: *ActiveSessionState, select: anytype) void {
    const main_record = holdMain(session);
    defer main_record.drop();
    const alloc = main_record.alloc;
    const item = select.queue.getOneUncancelable(select.io) catch |err| switch (err) {
        // Only Select.cancel and cancelDiscard close the queue, and they leave
        // nothing outstanding.
        error.Closed => return,
    };
    switch (item) {
        .response => |maybe_response| if (maybe_response) |owned| {
            var response = owned;
            response.deinit(alloc);
        },
        else => {},
    }
    std.debug.assert(select.cancel() == null);
}

/// Forgets a request that was never written to the client.
pub fn discardOutboundRequest(session: *ActiveSessionState, request: OutboundRequest) void {
    const io = io_mod.getIo();
    session.outbound.mutex.lockUncancelable(io);
    defer session.outbound.mutex.unlock(io);
    if (session.outbound.pending.fetchRemove(request)) |entry| {
        if (entry.value.response) |response| {
            var owned = response;
            const main_record = holdMain(session);
            defer main_record.drop();
            owned.deinit(main_record.alloc);
        }
    }
}

pub fn cancelOutboundRequest(session: *ActiveSessionState, request: OutboundRequest) void {
    session.outbound.mutex.lockUncancelable(io_mod.getIo());
    const changed = cancelOutboundRequestLocked(session, request);
    session.outbound.mutex.unlock(io_mod.getIo());
    if (changed) publishRequestCancellation(session, request);
}

fn cancelOutboundRequestLocked(session: *ActiveSessionState, request: OutboundRequest) bool {
    const pending = session.outbound.pending.getPtr(request) orelse return false;
    if (pending.response != null) return false;
    pending.response = .{ .cancelled = true };
    session.outbound.cond.broadcast(io_mod.getIo());
    return true;
}

/// Cancels every request that `session`'s turns wait for from the client, and
/// tells the client about each one when `notify_client` is set.
fn cancelSessionPending(session: *ActiveSessionState, notify_client: bool) void {
    const io = io_mod.getIo();
    var cancelled_requests: [max_pending_outbound]OutboundRequest = undefined;
    var cancelled_count: usize = 0;
    session.outbound.mutex.lockUncancelable(io);
    var pending = session.outbound.pending.iterator();
    while (pending.next()) |entry| {
        if (entry.value_ptr.response != null) continue;
        entry.value_ptr.response = .{ .cancelled = true };
        if (cancelled_count < cancelled_requests.len) {
            cancelled_requests[cancelled_count] = entry.key_ptr.*;
            cancelled_count += 1;
        } else if (notify_client) {
            debug_trace.logf("acp", "cancelled a client request without telling the client id={d} reason=too_many", .{entry.key_ptr.id});
        }
    }
    session.outbound.cond.broadcast(io);
    session.outbound.mutex.unlock(io);

    if (!notify_client) return;
    for (cancelled_requests[0..cancelled_count]) |request| publishRequestCancellation(session, request);
}

/// Ends the client's input: every request fx waits on gets the `no_client`
/// result, and later requests are refused, so no turn waits for an answer
/// that can't arrive. The sessions this connection leads hold its requests.
pub fn endClientInput(state: *ServerState) void {
    const io = io_mod.getIo();
    markMembersInputEnded(state);
    var index: usize = 0;
    while (sessionAt(state, index)) |session| : (index += 1) {
        session.outbound.mutex.lockUncancelable(io);
        const own_connection = ownMember(state, session).connection_id;
        var pending = session.outbound.pending.iterator();
        while (pending.next()) |entry| {
            if (entry.key_ptr.connection != own_connection) continue;
            if (entry.value_ptr.response != null) continue;
            entry.value_ptr.response = .{ .no_client = true };
        }
        session.outbound.cond.broadcast(io);
        session.outbound.mutex.unlock(io);
    }
}

/// Records that this connection's input ended on each member record it holds, so a turn never
/// asks it a question once it is the main client. Covers the sessions it leads and follows.
fn markMembersInputEnded(state: *ServerState) void {
    for (state.memberships.items) |membership| markMemberInputEnded(membership.session, membership.member.connection_id);
}

fn markMemberInputEnded(session: *ActiveSessionState, connection_id: ConnectionId) void {
    var audience = lockAudience(session);
    defer audience.unlock();
    const member = findMemberLocked(session, connection_id) orelse return;
    const io = io_mod.getIo();
    member.outbound_mutex.lockUncancelable(io);
    defer member.outbound_mutex.unlock(io);
    member.input_ended = true;
}

/// Tells the client to stop `request`, on the writer of the connection that is main now.
fn publishRequestCancellation(session: *ActiveSessionState, request: OutboundRequest) void {
    var audience = lockAudience(session);
    defer audience.unlock();
    const state = mainLocked(session).?;
    if (state.gone) return;
    var params: std.Io.Writer.Allocating = .init(state.alloc);
    defer params.deinit();
    params.writer.print("{{\"requestId\":{d}}}", .{request.id}) catch |err| {
        debug_trace.logf("acp", "request cancellation serialization failed id={d} err={s}", .{ request.id, @errorName(err) });
        return;
    };
    state.writer.writeNotification(
        state.alloc,
        "$/cancel_request",
        params.writer.buffered(),
    ) catch |err| {
        debug_trace.logf("acp", "request cancellation publication failed id={d} err={s}", .{ request.id, @errorName(err) });
    };
}

pub fn reserveLegacyUrl(
    state: *Member,
    origin: tool_mcp_runtime.InputOrigin,
    source_id: []const u8,
    acp_id: []const u8,
    session_id: []const u8,
    tool_call_id: []const u8,
) !bool {
    state.legacy_url_mutex.lockUncancelable(io_mod.getIo());
    defer state.legacy_url_mutex.unlock(io_mod.getIo());
    const now_ms = serverAwakeMillis();
    var pending_index: usize = 0;
    while (pending_index < state.pending_legacy_urls.items.len) {
        const pending = &state.pending_legacy_urls.items[pending_index];
        const stale_generation = std.mem.eql(u8, pending.server_name, origin.server_name) and
            (pending.binding.runtime_generation != origin.runtime_generation or
                pending.binding.connection_generation != origin.connection_generation or
                pending.binding.client_generation != origin.client_generation or
                pending.binding.auth_generation != origin.auth_generation);
        if (pending.binding.deadline_ms >= now_ms and !stale_generation) {
            pending_index += 1;
            continue;
        }
        var expired = state.pending_legacy_urls.swapRemove(pending_index);
        expired.deinit(state.alloc);
    }
    if (state.pending_legacy_urls.items.len >= max_pending_outbound) return false;
    for (state.pending_legacy_urls.items) |pending| {
        if (std.mem.eql(u8, pending.server_name, origin.server_name) and
            std.mem.eql(u8, pending.source_id, source_id)) return false;
    }

    const server_name = try state.alloc.dupe(u8, origin.server_name);
    errdefer state.alloc.free(server_name);
    const owned_source_id = try state.alloc.dupe(u8, source_id);
    errdefer state.alloc.free(owned_source_id);
    const owned_acp_id = try state.alloc.dupe(u8, acp_id);
    errdefer state.alloc.free(owned_acp_id);
    const owned_session_id = try state.alloc.dupe(u8, session_id);
    errdefer state.alloc.free(owned_session_id);
    const owned_tool_call_id = try state.alloc.dupe(u8, tool_call_id);
    errdefer state.alloc.free(owned_tool_call_id);
    try state.pending_legacy_urls.append(state.alloc, .{
        .server_name = server_name,
        .source_id = owned_source_id,
        .acp_id = owned_acp_id,
        .session_id = owned_session_id,
        .tool_call_id = owned_tool_call_id,
        .binding = .{
            .server_name = server_name,
            .scope = .{ .acp_session = .{
                .session_id = owned_session_id,
                .tool_call_id = owned_tool_call_id,
            } },
            .runtime_generation = origin.runtime_generation,
            .connection_generation = origin.connection_generation,
            .client_generation = origin.client_generation,
            .catalog_generation = origin.catalog_generation,
            .request_generation = origin.request_generation,
            .auth_generation = origin.auth_generation,
            .deadline_ms = std.math.add(i64, now_ms, legacy_url_completion_timeout_ms) catch
                std.math.maxInt(i64),
        },
    });
    return true;
}

pub fn removeLegacyUrl(
    state: *Member,
    acp_id: []const u8,
) void {
    state.legacy_url_mutex.lockUncancelable(io_mod.getIo());
    defer state.legacy_url_mutex.unlock(io_mod.getIo());
    for (state.pending_legacy_urls.items, 0..) |pending, index| {
        if (!std.mem.eql(u8, pending.acp_id, acp_id)) continue;
        var removed = state.pending_legacy_urls.swapRemove(index);
        removed.deinit(state.alloc);
        return;
    }
}

pub fn acceptLegacyUrl(
    state: *Member,
    origin: tool_mcp_runtime.InputOrigin,
    acp_id: []const u8,
) tool_mcp_runtime.LegacyUrlAcceptTransition {
    var owned_acp_id: ?[]u8 = null;
    state.legacy_url_mutex.lockUncancelable(io_mod.getIo());
    const result = result: for (state.pending_legacy_urls.items, 0..) |*pending, index| {
        if (!std.mem.eql(u8, pending.acp_id, acp_id)) continue;
        if (pending.binding.runtime_generation != origin.runtime_generation or
            pending.binding.connection_generation != origin.connection_generation or
            pending.binding.client_generation != origin.client_generation or
            pending.binding.catalog_generation != origin.catalog_generation or
            pending.binding.request_generation != origin.request_generation or
            pending.binding.auth_generation != origin.auth_generation)
        {
            break :result tool_mcp_runtime.LegacyUrlAcceptTransition.missing;
        }
        pending.accepted = true;
        if (!pending.completed) {
            break :result tool_mcp_runtime.LegacyUrlAcceptTransition.awaiting_completion;
        }
        var removed = state.pending_legacy_urls.swapRemove(index);
        owned_acp_id = removed.acp_id;
        removed.acp_id = &.{};
        removed.deinit(state.alloc);
        break :result tool_mcp_runtime.LegacyUrlAcceptTransition{ .completed = owned_acp_id.? };
    } else tool_mcp_runtime.LegacyUrlAcceptTransition.missing;
    state.legacy_url_mutex.unlock(io_mod.getIo());
    return result;
}

/// Forgets the URL completions that the members of `session` still owe for it. The completions
/// live in each member's record, so the session's closing clears them there.
fn clearPendingLegacyUrls(session: *ActiveSessionState) void {
    var audience = lockAudience(session);
    defer audience.unlock();
    for (session.members.items) |member| clearMemberPendingLegacyUrls(member, session.session_id);
}

fn clearMemberPendingLegacyUrls(member: *Member, session_id: []const u8) void {
    member.legacy_url_mutex.lockUncancelable(io_mod.getIo());
    defer member.legacy_url_mutex.unlock(io_mod.getIo());
    var index: usize = 0;
    while (index < member.pending_legacy_urls.items.len) {
        const pending = &member.pending_legacy_urls.items[index];
        if (!std.mem.eql(u8, pending.session_id, session_id)) {
            index += 1;
            continue;
        }
        pending.deinit(member.alloc);
        _ = member.pending_legacy_urls.orderedRemove(index);
    }
}

pub fn legacyUrlCompletionSink(state: *Member) tool_mcp_runtime.LegacyUrlCompletionSink {
    return .{
        .context = @ptrCast(state),
        .accept = acceptLegacyUrlFromSink,
        .consume = consumeLegacyUrlCompletion,
        .publish = publishLegacyUrlCompletionFromSink,
    };
}

fn acceptLegacyUrlFromSink(
    raw_context: *anyopaque,
    origin: tool_mcp_runtime.InputOrigin,
    acp_id: []const u8,
) tool_mcp_runtime.LegacyUrlAcceptTransition {
    const state: *Member = @ptrCast(@alignCast(raw_context));
    return acceptLegacyUrl(state, origin, acp_id);
}

fn consumeLegacyUrlCompletion(
    raw_context: *anyopaque,
    completion: tool_mcp_runtime.LegacyUrlCompletion,
) tool_mcp_runtime.LegacyUrlConsumeTransition {
    const state: *Member = @ptrCast(@alignCast(raw_context));
    var acp_id: ?[]u8 = null;
    var matched = false;
    state.legacy_url_mutex.lockUncancelable(io_mod.getIo());
    for (state.pending_legacy_urls.items, 0..) |*pending, index| {
        if (!std.mem.eql(u8, pending.server_name, completion.server_name) or
            !std.mem.eql(u8, pending.source_id, completion.elicitation_id)) continue;
        if (pending.binding.runtime_generation != completion.runtime_generation or
            pending.binding.connection_generation != completion.connection_generation or
            pending.binding.client_generation != completion.client_generation or
            pending.binding.auth_generation != completion.auth_generation) break;
        const transition = elicitation.decideTransition(
            .pending,
            pending.binding,
            .{
                .server_name = completion.server_name,
                .scope = pending.binding.scope,
                .runtime_generation = completion.runtime_generation,
                .connection_generation = completion.connection_generation,
                .client_generation = completion.client_generation,
                .catalog_generation = pending.binding.catalog_generation,
                .request_generation = pending.binding.request_generation,
                .auth_generation = completion.auth_generation,
            },
            serverAwakeMillis(),
            true,
        );
        matched = true;
        switch (transition) {
            .consume => {
                if (pending.accepted) {
                    var removed = state.pending_legacy_urls.swapRemove(index);
                    acp_id = removed.acp_id;
                    removed.acp_id = &.{};
                    removed.deinit(state.alloc);
                } else {
                    pending.completed = true;
                }
            },
            .reject => {
                var removed = state.pending_legacy_urls.swapRemove(index);
                removed.deinit(state.alloc);
            },
        }
        break;
    }
    state.legacy_url_mutex.unlock(io_mod.getIo());

    return if (matched)
        .{ .consumed = acp_id }
    else
        .missing;
}

fn publishLegacyUrlCompletionFromSink(raw_context: *anyopaque, id: []u8) void {
    const member: *Member = @ptrCast(@alignCast(raw_context));
    publishLegacyUrlCompletion(member, id);
}

/// Writes the completion to the record's client. The write holds `legacy_url_mutex` and checks
/// `gone` there, so the connection's frame cannot end under it (`markMemberGone`).
fn publishLegacyUrlCompletion(member: *Member, id: []u8) void {
    defer member.alloc.free(id);
    var params: std.Io.Writer.Allocating = .init(member.alloc);
    defer params.deinit();
    params.writer.writeAll("{\"elicitationId\":") catch return;
    std.json.Stringify.value(id, .{}, &params.writer) catch return;
    params.writer.writeByte('}') catch return;
    member.legacy_url_mutex.lockUncancelable(io_mod.getIo());
    defer member.legacy_url_mutex.unlock(io_mod.getIo());
    if (member.gone) return;
    member.writer.writeNotification(
        member.alloc,
        "elicitation/complete",
        params.writer.buffered(),
    ) catch {};
}

fn serverAwakeMillis() i64 {
    const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    const milliseconds = @divFloor(now.raw.nanoseconds, std.time.ns_per_ms);
    return std.math.cast(i64, milliseconds) orelse if (milliseconds < 0)
        std.math.minInt(i64)
    else
        std.math.maxInt(i64);
}

/// Permission compatibility wrapper over the shared outbound registry.
pub fn beginPermissionRequest(session: *ActiveSessionState) ?OutboundRequest {
    return beginOutboundRequest(session, .permission) catch null;
}

/// What a permission wait ended with: the client's decision, or `moved` when the main
/// client left before it answered, so the turn asks the new main again.
pub const PermissionAnswer = union(enum) {
    decided: types.ToolPermissionDecision,
    moved,
};

pub fn awaitPermissionAnswer(session: *ActiveSessionState, request: OutboundRequest) PermissionAnswer {
    const main_record = holdMain(session);
    defer main_record.drop();
    const alloc = main_record.alloc;
    var response = awaitOutboundResponse(session, request, .permission) orelse return .{ .decided = .deny };
    defer response.deinit(alloc);
    if (response.moved) return .moved;
    if (response.no_client) debug_trace.logf("acp", "event=permission_denied reason=client_input_ended", .{});
    if (response.cancelled or response.error_json != null) return .{ .decided = .deny };
    const raw = response.result_json orelse return .{ .decided = .deny };
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch return .{ .decided = .deny };
    defer parsed.deinit();
    return .{ .decided = parsePermissionDecision(parsed.value) orelse .deny };
}

/// The decision of a permission wait that cannot move: a move is denied, as a cancel is.
pub fn awaitPermissionDecision(session: *ActiveSessionState, request: OutboundRequest) types.ToolPermissionDecision {
    return switch (awaitPermissionAnswer(session, request)) {
        .decided => |decision| decision,
        .moved => .deny,
    };
}

/// Sends `method` with `params_json` to the session's main client, which must still be the
/// connection `request` was made to. The check and the write hold the session's audience
/// lock, so a hand-off cannot land between them. Fails with `error.MainChanged` when it did,
/// and the caller asks the new main.
pub fn writeRequestToMain(
    session: *ActiveSessionState,
    request: OutboundRequest,
    alloc: Allocator,
    method: []const u8,
    params_json: []const u8,
) !void {
    prompt_test_controls.notePermissionWrite();
    var audience = lockAudience(session);
    defer audience.unlock();
    const main = mainLocked(session).?;
    if (main.gone or main.connection_id != request.connection) return error.MainChanged;
    try main.writer.writeRequest(alloc, .{ .integer = @intCast(request.id) }, method, params_json);
}

pub fn cancelPermissionRequest(session: *ActiveSessionState, request: OutboundRequest) void {
    cancelOutboundRequest(session, request);
}

fn dispatchNotification(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    reapPrompts(state);
    if (!state.initialized) return;
    switch (AcpMethod.parse(msg.method)) {
        .request_cancel => handleRequestCancellation(state, alloc, msg.params_raw),
        .session_cancel => {
            if (notificationTargetSession(state, alloc, msg.params_raw)) |session| {
                handleCancel(session, true);
            } else {
                _ = try cancelFollowedSession(state, alloc, false, null, msg.params_raw);
            }
        },
        .mcp_message => {
            // Request-scoped MCP notifications, such as progress, are not
            // delivered to the running operation yet.
            debug_trace.logf("acp", "dropped mcp/message notification bytes={d}", .{if (msg.params_raw) |raw| raw.len else 0});
        },
        else => {},
    }
}

/// Routes one request. Public so the tests can send a follower its requests the way the reader does.
pub fn dispatch(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    reapPrompts(state);
    pollTokenPass(state);
    const method = AcpMethod.parse(msg.method);

    if (method == .initialize) {
        return handleInitialize(state, alloc, msg);
    }

    if (!state.initialized) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = "Not initialized. Call initialize first.",
        });
    }

    if (method == .session_cancel) {
        if (try cancelFollowedSession(state, alloc, true, msg.id, msg.params_raw)) return;
        const session = (try requireSessionTarget(state, alloc, msg)) orelse return;
        handleCancel(session, true);
        return state.writer.writeResponse(alloc, msg.id, "null");
    }

    if (method.isLibfx() and !state.host.cfg.minimal_kernel) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.method_not_found,
            .message = "Method not found",
        });
    }

    if (method == .session_prompt) {
        if (try promptFromFollower(state, alloc, msg)) return;
        const session = (try requireSessionTarget(state, alloc, msg)) orelse return;
        // AcpSessionReaders BeginRequest: the decision is made under the line lock.
        return handleSessionPrompt(state, alloc, msg, session);
    }

    if (method.waitsForActivePrompt() and promptBusy(state, alloc, msg)) {
        return writePromptInProgress(state, alloc, msg.id);
    }

    if (comptime host_target.is_wasm) {
        return switch (method) {
            .session_new => sessions.handleNewWasmSession(state, alloc, msg),
            .session_load => sessions.handleLoadWasmSession(state, alloc, msg),
            .session_list => sessions.handleListWasmSessions(state, alloc, msg),
            .session_delete => sessions.handleDeleteWasmSession(state, alloc, msg),
            .session_set_config_option => handleSetConfigOption(state, alloc, msg),
            .session_set_mode => handleSetMode(state, alloc, msg),
            .libfx_checkpoint => handleKernelCheckpoint(state, alloc, msg),
            .libfx_restore => handleKernelRestore(state, alloc, msg),
            .libfx_new => sessions.handleNewLibfxSession(state, alloc, msg),
            .libfx_steer => handleKernelSteer(state, alloc, msg),
            .libfx_withdraw => handleKernelWithdraw(state, alloc, msg),
            .libfx_handoff => handleKernelHandoff(state, alloc, msg),
            .libfx_follow_up => handleKernelFollowUp(state, alloc, msg),
            .libfx_snapshot => handleKernelSnapshot(state, alloc, msg),
            .libfx_journal_open => handleKernelJournalOpen(state, alloc, msg),
            .libfx_journal_images => handleKernelJournalImages(state, alloc, msg),
            else => state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.method_not_found,
                .message = "Method not available in the web core yet",
            }),
        };
    }

    return switch (method) {
        .session_new => sessions.handleNewSession(state, alloc, msg),
        .session_load => sessions.handleLoadSession(state, alloc, msg),
        .session_resume => sessions.handleResumeSession(state, alloc, msg),
        .session_close => handleCloseSession(state, alloc, msg),
        .session_list => sessions.handleListSessions(state, alloc, msg),
        .session_set_config_option => handleSetConfigOption(state, alloc, msg),
        .session_set_mode => handleSetMode(state, alloc, msg),
        .libfx_checkpoint => handleKernelCheckpoint(state, alloc, msg),
        .libfx_restore => handleKernelRestore(state, alloc, msg),
        .libfx_new => sessions.handleNewLibfxSession(state, alloc, msg),
        .libfx_steer => handleKernelSteer(state, alloc, msg),
        .libfx_withdraw => handleKernelWithdraw(state, alloc, msg),
        .libfx_handoff => handleKernelHandoff(state, alloc, msg),
        .libfx_follow_up => handleKernelFollowUp(state, alloc, msg),
        .libfx_snapshot => handleKernelSnapshot(state, alloc, msg),
        .libfx_journal_open => handleKernelJournalOpen(state, alloc, msg),
        .libfx_journal_images => handleKernelJournalImages(state, alloc, msg),
        .initialize,
        .request_cancel,
        .session_cancel,
        .session_prompt,
        .session_delete,
        .mcp_message,
        .unknown,
        => state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.method_not_found,
            .message = "Method not found",
        }),
    };
}

const requestIdsEqual = jsonrpc.requestIdsEqual;

fn requestIdFromValue(value: std.json.Value) ?jsonrpc.RequestId {
    return switch (value) {
        .integer => |id| .{ .integer = id },
        .string => |id| .{ .string = id },
        .null => .null,
        else => null,
    };
}

fn handleRequestCancellation(
    state: *ServerState,
    alloc: Allocator,
    params: ?[]const u8,
) void {
    const raw = params orelse return;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const value = parsed.value.object.get("requestId") orelse return;
    const requested = requestIdFromValue(value) orelse return;
    // The request may belong to any open session's turns.
    var open_index: usize = 0;
    while (sessionAt(state, open_index)) |session| : (open_index += 1) {
        if (withdrawSessionRequest(state, alloc, session, requested)) return;
    }
    // A follower's own waiting input and its own running prompt are in the sessions it
    // follows. Each one is held while it is checked, and only this connection's
    // entries match, so a follower stops only a turn that its own prompt started.
    if (comptime follow_supported) {
        for (state.memberships.items) |membership| {
            if (standing(membership) != .follows) continue;
            if (withdrawSessionRequest(state, alloc, membership.session, requested)) return;
        }
    }
}

/// Handles `$/cancel_request` for `session`: its running turn's own prompt
/// stops the turn, and a steer or queued prompt that hasn't run is withdrawn;
/// one a turn took stays. Returns whether the request was this session's.
fn withdrawSessionRequest(
    state: *ServerState,
    alloc: Allocator,
    session: *ActiveSessionState,
    requested: jsonrpc.RequestId,
) bool {
    const own_member = ownMember(state, session);
    const outcome: enum { stop_turn, withdrawn, none } = outcome: {
        // AcpSessionReaders WithdrawLocked: the slot and the turn it holds are read
        // under the line lock, so a reap cannot free the turn while this reads it.
        session.waiting_prompts.lock();
        defer session.waiting_prompts.unlock();
        const active = session.prompt orelse break :outcome .none;
        if (active.group_ids.len == 0) {
            if (active.msg.id) |active_id| {
                const same_connection = sameConnection(active.from, own_member.connection_id);
                if (same_connection and requestIdsEqual(active_id, requested)) break :outcome .stop_turn;
            }
        }
        if (session.steering.withdrawRequest(state.alloc, own_member.connection_id, requested) or
            session.waiting_prompts.withdrawLocked(state.alloc, own_member.connection_id, requested)) break :outcome .withdrawn;
        break :outcome .none;
    };
    switch (outcome) {
        .stop_turn => {
            handleCancel(session, true);
        },
        .withdrawn => {
            debug_trace.logf("acp", "withdrew a prompt that hadn't run", .{});
            const answer: Answer = .{ .rpc_error = .{
                .code = ErrorCode.request_cancelled,
                .message = "Request cancelled",
            } };
            answerSender(session, alloc, own_member.connection_id, requested, .none, answer, answer) catch |err| debug_trace.logf("acp", "failed to answer a withdrawn prompt err={s}", .{@errorName(err)});
        },
        .none => return false,
    }
    return true;
}

fn libfxSessionId(alloc: Allocator, msg: *const jsonrpc.Message) !std.json.Parsed(std.json.Value) {
    const raw = msg.params_raw orelse return error.InvalidLibfxParams;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch
        return error.InvalidLibfxParams;
    if (parsed.value != .object) {
        parsed.deinit();
        return error.InvalidLibfxParams;
    }
    return parsed;
}

fn activeLibfxSession(
    state: *ServerState,
    params: std.json.Value,
) ?*ActiveSessionState {
    const session_id = params.object.get("sessionId") orelse return null;
    if (session_id != .string) return null;
    return findSession(state, session_id.string);
}

/// Queues libfx steering. A journaled input is recorded as accepted under
/// the session write mutex, which every progress that places an input also
/// takes, so its acceptance always reaches the host first.
fn queueLibfxSteering(
    state: *ServerState,
    alloc: Allocator,
    active: *ActiveSessionState,
    text: []const u8,
    input_id: ?[]const u8,
) !void {
    const id = input_id orelse return active.steering.enqueue(state.alloc, text);
    active.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer active.session_write_mutex.unlock(io_mod.getIo());
    try active.steering.enqueueInput(state.alloc, text, id);
    const journal = if (active.journal) |*value| value else return;
    journal.append(alloc, active.session_id, .{ .input_accepted = .{ .id = id, .text = text } }) catch |err| {
        _ = active.steering.withdraw(state.alloc, id);
        return err;
    };
}

/// Takes back a libfx steer the running turn has not handed to the model:
/// `withdrawn`, recorded in the journal, or `already_placed`.
fn handleKernelWithdraw(
    state: *ServerState,
    alloc: Allocator,
    msg: *const jsonrpc.Message,
) !void {
    var parsed = libfxSessionId(alloc, msg) catch return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Invalid withdraw params",
    });
    defer parsed.deinit();
    const active = activeLibfxSession(state, parsed.value) orelse
        return state.writer.writeError(alloc, msg.id, unknownLibfxSession(parsed.value));
    const id = parsed.value.object.get("id") orelse
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Missing input id",
        });
    if (id != .string or !libfx_steering.validInputId(id.string)) return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Invalid input id",
    });
    const withdrawn = withdrawn: {
        active.session_write_mutex.lockUncancelable(io_mod.getIo());
        defer active.session_write_mutex.unlock(io_mod.getIo());
        if (!active.steering.withdraw(state.alloc, id.string)) break :withdrawn false;
        if (active.journal) |*journal| try journal.append(alloc, active.session_id, .{ .input_withdrawn = id.string });
        break :withdrawn true;
    };
    try state.writer.writeResponse(alloc, msg.id, if (withdrawn) "{\"result\":\"withdrawn\"}" else "{\"result\":\"already_placed\"}");
}

/// A libfx steer that cannot join the running turn, such as one with images,
/// ends that turn at its next safe point so the host can run it next.
fn handleKernelHandoff(
    state: *ServerState,
    alloc: Allocator,
    msg: *const jsonrpc.Message,
) !void {
    var parsed = libfxSessionId(alloc, msg) catch return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Invalid handoff params",
    });
    defer parsed.deinit();
    const active = activeLibfxSession(state, parsed.value) orelse
        return state.writer.writeError(alloc, msg.id, unknownLibfxSession(parsed.value));
    if (active.steering.requestHandoff(&active.cancel_flag)) {
        debug_trace.logf("acp", "libfx handoff interrupts the streaming reply", .{});
    }
    try state.writer.writeResponse(alloc, msg.id, "null");
}

pub fn takeSteering(
    session: *ActiveSessionState,
    result_alloc: Allocator,
    close_if_empty: bool,
) Allocator.Error!libfx_steering.Drained {
    const main_record = holdMain(session);
    defer main_record.drop();
    return session.steering.takeAll(main_record.alloc, result_alloc, close_if_empty);
}

fn writePromptInProgress(state: *ServerState, alloc: Allocator, id: ?jsonrpc.RequestId) !void {
    return state.writer.writeError(alloc, id, .{
        .code = ErrorCode.invalid_request,
        .message = "Prompt already in progress",
    });
}

/// What a `session/prompt` that arrives while a turn runs asks for, from its
/// `sh.fx/delivery`.
const Delivery = enum { none, steer, queue };

/// What a running turn did with a `session/prompt` delivered into it.
const DeliveryOutcome = union(enum) {
    in_progress,
    /// A steer that joined the running turn: its text length, and whether it
    /// cut a streaming reply short.
    steered: struct { bytes: usize, interrupts_reply: bool },
    /// A steer that waits for the next turn, with its text length.
    late: usize,
    queued,
    failed: jsonrpc.RpcError,
};

/// What `decideSessionPrompt` decided for one `session/prompt`.
const PromptDecision = union(enum) {
    /// The session is closing, so the prompt starts no turn.
    refused,
    /// The prompt claimed the session's turn. The caller starts its thread.
    claimed: *ActivePrompt,
    /// A running turn took the prompt. The caller answers it.
    delivered: DeliveryOutcome,
};

/// Handles a `session/prompt`. A prompt that arrives while a turn runs
/// (src/protocol/spec/sh-fx.md, "Steering and queued prompts") joins it: a steer
/// joins the running turn, or the next one once that turn stops taking input; a
/// queued prompt waits for a turn of its own; and a prompt with no delivery
/// fails with `-32600`. A prompt that arrives once the worker has found
/// nothing waiting starts its own turn. Answers come when their turns end.
/// `decideSessionPrompt` makes the decision under the line lock. The answer and
/// the thread start come after the unlock.
fn handleSessionPrompt(state: *ServerState, alloc: Allocator, msg: *const jsonrpc.Message, session: *ActiveSessionState) !void {
    switch (try decideSessionPrompt(state, alloc, msg, session)) {
        .refused => return answerSessionRefused(state, alloc, msg.id, session.session_id),
        .claimed => |active| return startClaimedTurn(session, active),
        .delivered => |outcome| return answerDelivery(state, alloc, msg, outcome),
    }
}

/// A `session/prompt` on a session this connection follows. The session is
/// kept for the request (`SharedSessions.retain`, released after it), so a close waits for
/// the request. The prompt then takes the owner's path with this connection as its sender.
/// Returns false when the session is not followed here, so the owner's path applies.
fn promptFromFollower(state: *ServerState, alloc: Allocator, msg: *const jsonrpc.Message) !bool {
    if (comptime !follow_supported) return false;
    const raw = msg.params_raw orelse return false;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch return false;
    defer parsed.deinit();
    const session_id = requestedSessionId(parsed.value) orelse return false;
    if (!followsSession(state, session_id)) return false;
    const shared = &state.host.shared;
    const session = shared.retain(session_id) orelse {
        // The owner has closed the session, or is closing it: this follow is over.
        forgetFollowing(state, session_id);
        try answerSessionRefused(state, alloc, msg.id, session_id);
        return true;
    };
    defer shared.release(session);
    try handleSessionPrompt(state, alloc, msg, session);
    return true;
}

/// A `session/cancel` on a session this connection follows. Any client that has the
/// session open may stop its running turn, whichever client sent the prompt (sh-fx.md,
/// "Stopping a turn"). The cancel runs in the owner's state, because the requests the
/// turn waits for live on the owner's connection, so the owner's client gets
/// `$/cancel_request` for them, as its own cancel gives. The session is kept for the
/// cancel (`SharedSessions.retain`, released after it). A request (`reply`) gets the
/// answer the owner's cancel gets, or `-32002` when the owner has closed the session.
/// Returns false when the session is not followed here, so the owner's path applies.
fn cancelFollowedSession(
    state: *ServerState,
    alloc: Allocator,
    reply: bool,
    request_id: ?jsonrpc.RequestId,
    params: ?[]const u8,
) !bool {
    if (comptime !follow_supported) return false;
    const raw = params orelse return false;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch return false;
    defer parsed.deinit();
    const session_id = requestedSessionId(parsed.value) orelse return false;
    if (!followsSession(state, session_id)) return false;
    const shared = &state.host.shared;
    if (shared.retain(session_id)) |session| {
        defer shared.release(session);
        handleCancel(session, true);
        if (reply) try state.writer.writeResponse(alloc, request_id, "null");
        return true;
    }
    // The owner has closed the session, or is closing it: this follow is over.
    forgetFollowing(state, session_id);
    if (reply) try answerSessionRefused(state, alloc, request_id, session_id);
    return true;
}

/// Answers a `session/prompt` that reached a closing or closed session. No turn starts, and
/// the request gets the same not-found answer as a session that is not open
/// (`writeSessionTargetError`).
fn answerSessionRefused(state: *ServerState, alloc: Allocator, id: ?jsonrpc.RequestId, session_id: []const u8) !void {
    return state.writer.writeError(alloc, id, jsonrpc.sessionNotFound("No active session", session_id));
}

/// Decides one `session/prompt` for the session's line. Each decision is made in
/// one hold of the line lock. A finished turn in the slot is reaped first, and
/// then the decision is made again.
fn decideSessionPrompt(state: *ServerState, alloc: Allocator, msg: *const jsonrpc.Message, session: *ActiveSessionState) !PromptDecision {
    while (true) {
        const line = &session.waiting_prompts;
        prompt_test_controls.noteDecisionCheck();
        line.lock();
        const decided = decideLocked(state, alloc, msg, session) catch |err| {
            line.unlock();
            return err;
        };
        line.unlock();
        if (decided) |decision| return decision;
        debug_trace.logf("acp", "prompt arrived after the worker found nothing waiting; starting a turn", .{});
        reapSessionPrompt(session, true);
    }
}

/// The decision of `decideSessionPrompt`, made with the line lock held. Null when
/// the slot holds a finished turn: the caller reaps it and decides again.
fn decideLocked(state: *ServerState, alloc: Allocator, msg: *const jsonrpc.Message, session: *ActiveSessionState) !?PromptDecision {
    const line = &session.waiting_prompts;
    // A claim, a delivery and a reap wait while a taken turn is being joined. A
    // closing session stops waiting, and refuses.
    const was_joining = line.joining;
    line.waitWhileJoiningLocked(true);
    if (was_joining) prompt_test_controls.noteJoinPassed();
    // AcpSessionReaders ClaimRefuse: a closing session starts nothing.
    if (line.closing) return .refused;
    // AcpSessionReaders ClaimNew: the slot is empty, so this prompt starts the turn.
    if (session.prompt == null) return .{ .claimed = try claimTurnLocked(state, alloc, msg, session) };
    // The prompt finds a turn in the slot, so it is read as a delivery. The reads
    // below answer a bad delivery even when the turn has already ended, as before.
    // libfx kernel hosts steer through `_sh.fx/session/steer`.
    if (state.host.cfg.minimal_kernel) return deliveredDecision(.in_progress);
    const params = msg.params_raw orelse return deliveredDecision(.in_progress);
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, params, .{}) catch return deliveredDecision(.in_progress);
    defer parsed.deinit();
    if (parsed.value != .object) return deliveredDecision(.in_progress);
    const delivery: Delivery = if (acp_types.metaField(parsed.value.object, "sh.fx/delivery")) |value| delivery: {
        if (value == .string and std.mem.eql(u8, value.string, "steer")) break :delivery .steer;
        if (value == .string and std.mem.eql(u8, value.string, "queue")) break :delivery .queue;
        return deliveredDecision(.{ .failed = .{
            .code = ErrorCode.invalid_params,
            .message = "sh.fx/delivery must be \"steer\" or \"queue\"",
        } });
    } else .none;
    const text: []u8 = if (delivery == .steer) steeringPromptText(alloc, parsed.value.object) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedSteeringContent => return deliveredDecision(.{ .failed = .{
            .code = ErrorCode.invalid_params,
            .message = "Steering prompts accept text content blocks only",
        } }),
    } else &.{};
    defer if (delivery == .steer) alloc.free(text);
    var queued: ?jsonrpc.Message = if (delivery == .queue) try cloneMessage(state.alloc, msg) else null;
    defer if (queued) |*copy| jsonrpc.freeMessage(state.alloc, copy);
    // AcpSessionReaders ClaimReap: a finished turn is reaped first, then the prompt is decided again.
    if (!line.worker_running) return null;
    // AcpSessionReaders ClaimDeliver: a running turn takes the prompt.
    const outcome: DeliveryOutcome = switch (delivery) {
        .none => .in_progress,
        .steer => try deliverSteerLocked(state, session, msg.id, text),
        .queue => try deliverQueueLocked(state, session, &queued),
    };
    return deliveredDecision(outcome);
}

fn deliveredDecision(outcome: DeliveryOutcome) ?PromptDecision {
    return .{ .delivered = outcome };
}

/// Makes the session's turn for a claimed prompt (AcpSessionReaders ClaimNew).
/// The turn runs on the owner (`sessionMain(session)`), and its answers go to the sender's
/// connection. The caller holds the line lock. The turn goes into the slot, and
/// `worker_running` is set in the same hold, so no other prompt can see an empty
/// slot with no turn. The thread starts later, outside the lock
/// (`startClaimedTurn`).
fn claimTurnLocked(state: *ServerState, alloc: Allocator, msg: *const jsonrpc.Message, session: *ActiveSessionState) !*ActivePrompt {
    const own_member = ownMember(state, session);
    const active = try alloc.create(ActivePrompt);
    errdefer alloc.destroy(active);
    active.* = .{
        .host = state.host,
        .session = session,
        .alloc = alloc,
        .msg = try cloneMessage(alloc, msg),
        .from = own_member.connection_id,
        .mode = session.mode,
        .permission_mode = session.permission_mode,
        .usage_shown = own_member.extensions.contains(.usage),
        .delivery_shown = own_member.extensions.contains(.prompt_delivery),
        .keep_turn = own_member.extensions.contains(.keep_turn_on_disconnect),
    };
    errdefer jsonrpc.freeMessage(alloc, &active.msg);
    session.turn_cancel.store(false, .seq_cst);
    session.cancel_flag.store(false, .seq_cst);
    session.steering.open(state.alloc);
    session.waiting_prompts.worker_running = true;
    // WebAssembly has no thread: `startClaimedTurn` runs the turn inline, and the
    // slot stays empty there.
    if (comptime !host_target.is_wasm) session.prompt = active;
    return active;
}

/// Starts the thread of a claimed turn, outside the line lock. A failed spawn
/// gives the claim back under the lock, so the session holds no turn and no
/// worker.
fn startClaimedTurn(session: *ActiveSessionState, active: *ActivePrompt) !void {
    if (comptime host_target.is_wasm) {
        promptWorkerMain(active);
        freeActivePrompt(active);
        return;
    }
    // AcpSessionReaders Spawn: the worker runs outside the lock.
    const spawned = if (prompt_test_controls.takeSpawnFailure()) error.SystemResources else std.Thread.spawn(.{}, promptWorkerMain, .{active});
    active.thread = spawned catch |err| {
        // AcpSessionReaders SpawnFail: the claim is given back under the lock. The steers the
        // runtime took between the claim and this spawn belong to the turn that never starts,
        // so they leave with it, and each is answered once the line is unlocked.
        const alloc = active.alloc;
        const collected: ?libfx_steering.Finished = collected: {
            session.waiting_prompts.lock();
            defer session.waiting_prompts.unlock();
            session.prompt = null;
            session.waiting_prompts.worker_running = false;
            break :collected session.steering.finishTurn(alloc, alloc, "spawn_failed") catch |finish_err| {
                // The steers stay in the runtime when collection fails, so this failure is traced.
                debug_trace.logf("acp", "failed to collect the steers of a turn that did not start err={s}", .{@errorName(finish_err)});
                break :collected null;
            };
        };
        freeActivePrompt(active);
        if (collected) |finished| {
            defer finished.deinit(alloc);
            answerSpawnFailedSteers(session, alloc, finished.untaken, err);
        }
        return err;
    };
}

/// Answers the steers that a claimed turn left in the runtime when its worker did not start.
/// Each goes to the connection that sent it, with `-32603` and the spawn error's name: the
/// answer `answerDroppedWaiting` gives input of a turn that could not start. Each one is
/// traced. Answering takes the audience lock, so the caller holds no line lock.
fn answerSpawnFailedSteers(session: *ActiveSessionState, alloc: Allocator, steers: []const libfx_steering.Steer, err: anyerror) void {
    for (steers) |steer| {
        var buf: [32]u8 = undefined;
        debug_trace.logf("acp", "event=waiting_input_dropped session={s} request={s} reason=spawn_failed", .{ session.session_id, requestText(steer.request_id, &buf) });
        const answer: Answer = .{ .rpc_error = .{
            .code = ErrorCode.internal_error,
            .message = @errorName(err),
        } };
        answerSender(session, alloc, steer.from, steer.request_id, .none, answer, answer) catch |write_err| debug_trace.logf("acp", "failed to answer waiting input err={s}", .{@errorName(write_err)});
    }
}

/// Answers a `session/prompt` that a running turn took, and logs what happened.
fn answerDelivery(state: *ServerState, alloc: Allocator, msg: *const jsonrpc.Message, outcome: DeliveryOutcome) !void {
    switch (outcome) {
        .in_progress => return writePromptInProgress(state, alloc, msg.id),
        .steered => |steered| debug_trace.logf(
            "acp",
            "queued steering prompt bytes={d} interrupts_reply={}",
            .{ steered.bytes, steered.interrupts_reply },
        ),
        .late => |bytes| debug_trace.logf("acp", "steering prompt waits for the next turn bytes={d}", .{bytes}),
        .queued => debug_trace.logf("acp", "queued prompt for a turn of its own", .{}),
        .failed => |rpc_error| return state.writer.writeError(alloc, msg.id, rpc_error),
    }
}

/// Joins a steer to the running turn, or to the next one once that turn stops
/// taking input. The caller holds the line lock.
fn deliverSteerLocked(state: *ServerState, session: *ActiveSessionState, id: ?jsonrpc.RequestId, text: []const u8) !DeliveryOutcome {
    const line = &session.waiting_prompts;
    const own_member = ownMember(state, session);
    // AcpSessionReaders Deliver: the steer touches the session, not a turn it holds.
    session.steering.enqueueRequest(state.alloc, text, id, own_member.connection_id) catch |err| switch (err) {
        error.SteeringNotActive => {
            // The running turn stopped taking input: the steer runs next.
            line.addLateLocked(state.alloc, text, id.?, own_member.connection_id) catch |late_err| switch (late_err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.SteeringQueueFull => return .{ .failed = .{
                    .code = ErrorCode.invalid_request,
                    .message = "Steering queue is full",
                } },
            };
            return .{ .late = text.len };
        },
        error.OutOfMemory => return error.OutOfMemory,
        error.EmptySteeringMessage => return .{ .failed = .{
            .code = ErrorCode.invalid_params,
            .message = "Steering prompt text cannot be empty",
        } },
        error.SteeringMessageTooLarge => return .{ .failed = .{
            .code = ErrorCode.invalid_params,
            .message = "Steering prompt text exceeds the 64 KiB limit",
        } },
        error.SteeringQueueFull => return .{ .failed = .{
            .code = ErrorCode.invalid_request,
            .message = "Steering queue is full",
        } },
    };
    // A steer cuts a streaming reply short, as in the fx CLI.
    return .{ .steered = .{
        .bytes = text.len,
        .interrupts_reply = session.steering.claimInterrupt(&session.cancel_flag),
    } };
}

/// Queues a prompt for a turn of its own. The caller holds the line lock. The
/// line takes the copy, and `queued` is cleared once it does.
fn deliverQueueLocked(state: *ServerState, session: *ActiveSessionState, queued: *?jsonrpc.Message) !DeliveryOutcome {
    // AcpSessionReaders Deliver: the queued prompt touches the session, not a turn it holds.
    const own_member = ownMember(state, session);
    session.waiting_prompts.addQueuedLocked(state.alloc, queued.*.?, own_member.connection_id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.PromptQueueFull => return .{ .failed = .{
            .code = ErrorCode.invalid_request,
            .message = "Prompt queue is full",
        } },
    };
    queued.* = null;
    return .queued;
}

/// Joins the text blocks of a steering prompt. Caller owns the result.
fn steeringPromptText(
    alloc: Allocator,
    params: std.json.ObjectMap,
) (Allocator.Error || error{UnsupportedSteeringContent})![]u8 {
    const prompt = params.get("prompt") orelse return error.UnsupportedSteeringContent;
    if (prompt != .array) return error.UnsupportedSteeringContent;
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(alloc);
    for (prompt.array.items) |block| {
        if (block != .object) return error.UnsupportedSteeringContent;
        const kind = block.object.get("type") orelse return error.UnsupportedSteeringContent;
        const value = block.object.get("text") orelse return error.UnsupportedSteeringContent;
        if (kind != .string or !std.mem.eql(u8, kind.string, "text") or value != .string) {
            return error.UnsupportedSteeringContent;
        }
        if (text.items.len > 0) try text.append(alloc, '\n');
        try text.appendSlice(alloc, value.string);
    }
    return text.toOwnedSlice(alloc);
}

/// The host's `checkpointMeta` in libfx `params`, borrowed from them: what a
/// checkpoint records about the agent that saves it. Params without one
/// record none; null when it is malformed.
fn checkpointMetaParam(params: std.json.Value) ?agent_checkpoint.Meta {
    const value = params.object.get("checkpointMeta") orelse return .{};
    return agent_checkpoint.metaFromJson(value) catch null;
}

const invalid_checkpoint_meta: jsonrpc.RpcError = .{
    .code = ErrorCode.invalid_params,
    .message = "Invalid checkpoint meta",
};

/// `_sh.fx/session/checkpoint`: saves the state of a session that has no
/// running turn as the bytes of one binary attachment, which the host stores.
fn handleKernelCheckpoint(
    state: *ServerState,
    alloc: Allocator,
    msg: *const jsonrpc.Message,
) !void {
    var parsed = libfxSessionId(alloc, msg) catch return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Invalid checkpoint params",
    });
    defer parsed.deinit();
    const active = activeLibfxSession(state, parsed.value) orelse
        return state.writer.writeError(alloc, msg.id, unknownLibfxSession(parsed.value));
    const unavailable: jsonrpc.RpcError = .{
        .code = ErrorCode.invalid_request,
        .message = "Checkpoint is unavailable",
    };
    const meta = checkpointMetaParam(parsed.value) orelse return state.writer.writeError(alloc, msg.id, invalid_checkpoint_meta);
    const store = state.host.cfg.host_attachments orelse return state.writer.writeError(alloc, msg.id, unavailable);
    const bytes = active.session_rt.agent.checkpoint(alloc, meta) catch
        return state.writer.writeError(alloc, msg.id, unavailable);
    defer alloc.free(bytes);
    // The checkpoint leaves as raw bytes beside the response frame.
    const attachment = store.put(bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.AttachmentStoreFull => return state.writer.writeError(alloc, msg.id, unavailable),
    };
    var response: [64]u8 = undefined;
    const written = try std.mem.print(&response, "{{\"checkpointAttachment\":{d}}}", .{attachment});
    try state.writer.writeResponse(alloc, msg.id, written);
}

/// `_sh.fx/session/restore`: loads a session's state from a checkpoint
/// attachment into the session that `_sh.fx/session/new` created.
fn handleKernelRestore(
    state: *ServerState,
    alloc: Allocator,
    msg: *const jsonrpc.Message,
) !void {
    var parsed = libfxSessionId(alloc, msg) catch return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Invalid restore params",
    });
    defer parsed.deinit();
    const active = activeLibfxSession(state, parsed.value) orelse
        return state.writer.writeError(alloc, msg.id, unknownLibfxSession(parsed.value));
    const reference = parsed.value.object.get("checkpointAttachment") orelse
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Missing checkpoint",
        });
    const invalid: jsonrpc.RpcError = .{
        .code = ErrorCode.invalid_params,
        .message = "Invalid checkpoint",
    };
    const attachment = host_attachments.idFromJson(reference) orelse
        return state.writer.writeError(alloc, msg.id, invalid);
    const store = state.host.cfg.host_attachments orelse return state.writer.writeError(alloc, msg.id, invalid);
    const bytes = store.take(alloc, attachment, agent_checkpoint.max_checkpoint_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.AttachmentUnavailable => return state.writer.writeError(alloc, msg.id, invalid),
        error.AttachmentTooLarge => return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Checkpoint is too large",
        }),
    };
    defer alloc.free(bytes);
    // A journaled session's history changes only through its journal.
    if (active.journal != null) return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_request,
        .message = "A journaled session cannot restore a checkpoint",
    });
    const saved = active.session_rt.agent.restoreCheckpoint(alloc, bytes) catch |err|
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            // The host reports a newer checkpoint as it reports a newer journal.
            .message = if (err == error.UnsupportedCheckpointVersion)
                "Checkpoint was written by a newer fx"
            else
                "Invalid or non-fresh checkpoint",
        });
    defer saved.free(alloc);
    if (saved.isEmpty()) return state.writer.writeResponse(alloc, msg.id, "null");
    // What the checkpoint recorded about the agent that saved it, for the
    // host to compare with its own.
    var response: std.Io.Writer.Allocating = .init(alloc);
    defer response.deinit();
    try response.writer.writeAll("{\"checkpointMeta\":");
    try saved.writeJson(&response.writer);
    try response.writer.writeByte('}');
    try state.writer.writeResponse(alloc, msg.id, response.written());
}

/// Opens a new libfx session's journal from the events its host stored,
/// passed as one JSON array attachment. No attachment is an empty journal.
fn handleKernelJournalOpen(
    state: *ServerState,
    alloc: Allocator,
    msg: *const jsonrpc.Message,
) !void {
    // An open journal sends `_sh.fx/journal/append` and `flush`, which go
    // only to a client that lists `sh.fx/journal`.
    if (!state.extensions.contains(.journal)) return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "The journal needs the sh.fx/journal capability in clientCapabilities._meta",
    });
    var parsed = libfxSessionId(alloc, msg) catch return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Invalid journal params",
    });
    defer parsed.deinit();
    const active = activeLibfxSession(state, parsed.value) orelse
        return state.writer.writeError(alloc, msg.id, unknownLibfxSession(parsed.value));
    const invalid: jsonrpc.RpcError = .{
        .code = ErrorCode.invalid_params,
        .message = "Invalid journal",
    };
    const too_large: jsonrpc.RpcError = .{
        .code = ErrorCode.invalid_params,
        .message = "Journal is too large",
    };
    var events: ?[]u8 = null;
    defer if (events) |bytes| alloc.free(bytes);
    if (parsed.value.object.get("journalAttachment")) |reference| {
        const attachment = host_attachments.idFromJson(reference) orelse
            return state.writer.writeError(alloc, msg.id, invalid);
        const store = state.host.cfg.host_attachments orelse return state.writer.writeError(alloc, msg.id, invalid);
        events = store.take(alloc, attachment, libfx_journal.max_load_bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.AttachmentUnavailable => return state.writer.writeError(alloc, msg.id, invalid),
            error.AttachmentTooLarge => return state.writer.writeError(alloc, msg.id, too_large),
        };
    }

    var snapshot: ?[]u8 = null;
    defer if (snapshot) |bytes| alloc.free(bytes);
    if (parsed.value.object.get("snapshotAttachment")) |reference| {
        const attachment = host_attachments.idFromJson(reference) orelse
            return state.writer.writeError(alloc, msg.id, invalid);
        const store = state.host.cfg.host_attachments orelse return state.writer.writeError(alloc, msg.id, invalid);
        snapshot = store.take(alloc, attachment, journal_events.max_snapshot_bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.AttachmentUnavailable => return state.writer.writeError(alloc, msg.id, invalid),
            error.AttachmentTooLarge => return state.writer.writeError(alloc, msg.id, too_large),
        };
    }

    active.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer active.session_write_mutex.unlock(io_mod.getIo());
    if (active.journal != null) return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_request,
        .message = "Journal is already open",
    });
    // A host that stores every input before handing it in, as libfx's
    // session executor does, needs no wait before a request carries one.
    const inputs_durable = if (parsed.value.object.get("inputsDurable")) |value| switch (value) {
        .bool => |durable| durable,
        else => return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Invalid journal params",
        }),
    } else false;
    // A host with an image store stores each prompt image before it sends
    // it, so the journal names stored images instead of holding their bytes.
    const image_store = if (parsed.value.object.get("imageStore")) |value| switch (value) {
        .bool => |enabled| enabled,
        else => return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Invalid journal params",
        }),
    } else false;
    const window = imageWindowParam(parsed.value.object.get("imageWindow")) orelse return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Invalid journal params",
    });
    var images: session_codec.ImageResolver = .{ .alloc = alloc, .staged = &active.staged_images };
    defer images.deinit();
    const journal, const opened = libfx_journal.open(
        alloc,
        state.alloc,
        &state.writer,
        &active.session_rt,
        events orelse "[]",
        snapshot,
        inputs_durable,
        &images,
        image_store,
        window,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // The host stages them from its store, then opens again.
        error.ImagesMissing => {
            var needed: StagedTotals = .{ .images = active.staged_images.images.count(), .bytes = active.staged_images.bytes };
            for (images.missing.values()) |size| {
                needed.images +|= 1;
                needed.bytes +|= size;
            }
            active.staging_needed = needed;
            return writeImagesNeeded(state, alloc, msg.id, images.missing.keys());
        },
        error.AgentNotFresh => return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = "A journal opens only on a new session",
        }),
        error.UnsupportedJournalVersion => return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Journal was written by a newer fx",
        }),
        error.OutOfOrderJournalEvent => return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Journal events are out of order",
        }),
        error.JournalTooLarge => return state.writer.writeError(alloc, msg.id, too_large),
        error.JournalTooManyTurns => return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = std.fmt.comptimePrint("Journal holds more than {d} turns", .{journal_events.max_history_turns}),
        }),
        error.InvalidJournal => return state.writer.writeError(alloc, msg.id, invalid),
    };
    defer opened.checkpoint_meta.free(alloc);
    active.journal = journal;
    // The history holds its own copies of every staged image it named.
    active.staged_images.clear(state.alloc);
    active.staging_needed = .{};
    // The host runs the follow-ups the journal held, after any resume.
    const follow_ups = active.journal.?.takeFollowUps();
    defer journal_events.freePendingInputs(state.alloc, follow_ups);
    var response: std.Io.Writer.Allocating = .init(alloc);
    defer response.deinit();
    try response.writer.print("{{\"turns\":{d},\"resumable\":{s}", .{
        opened.turns,
        if (opened.resumable) "true" else "false",
    });
    // The open turn stopped at the host's time, not in a crash.
    if (opened.yielded) try response.writer.writeAll(",\"yielded\":true");
    if (!opened.checkpoint_meta.isEmpty()) {
        try response.writer.writeAll(",\"checkpointMeta\":");
        try opened.checkpoint_meta.writeJson(&response.writer);
    }
    // The host's ids for the open turn and the last one, so a retried prompt
    // can continue or skip its turn instead of running it twice.
    if (opened.open_turn_id.slice()) |id| {
        try response.writer.writeAll(",\"openTurnId\":");
        try writeJsonStr(id, &response.writer);
    }
    if (opened.last_turn_id.slice()) |id| {
        try response.writer.writeAll(",\"lastTurnId\":");
        try writeJsonStr(id, &response.writer);
    }
    // The calls the open turn left running, which the host may have the
    // resume run again instead of leaving them to the model.
    const running = active.journal.?.ambiguousCalls();
    if (running.len > 0) {
        try response.writer.writeAll(",\"runningCalls\":[");
        for (running, 0..) |call, index| {
            if (index > 0) try response.writer.writeByte(',');
            try response.writer.writeAll("{\"id\":");
            try writeJsonStr(call.id, &response.writer);
            try response.writer.writeAll(",\"name\":");
            try writeJsonStr(call.name, &response.writer);
            try response.writer.writeAll(",\"arguments\":");
            try writeJsonStr(call.arguments_json, &response.writer);
            try response.writer.writeByte('}');
        }
        try response.writer.writeByte(']');
    }
    try response.writer.writeAll(",\"followUps\":[");
    for (follow_ups, 0..) |follow_up, index| {
        if (index > 0) try response.writer.writeByte(',');
        try response.writer.writeAll("{\"id\":");
        try writeJsonStr(follow_up.id, &response.writer);
        try response.writer.writeAll(",\"text\":");
        try writeJsonStr(follow_up.text, &response.writer);
        try response.writer.writeByte('}');
    }
    try response.writer.writeAll("]}");
    try state.writer.writeResponse(alloc, msg.id, response.written());
}

/// Answers an open whose saved history names images the host has not
/// staged: every such name, so one round of staging serves the next open.
fn writeImagesNeeded(state: *ServerState, alloc: Allocator, id: ?jsonrpc.RequestId, names: []const session_codec.ImageName) !void {
    var response: std.Io.Writer.Allocating = .init(alloc);
    defer response.deinit();
    try response.writer.writeAll("{\"imagesNeeded\":[");
    for (names, 0..) |name, index| {
        if (index > 0) try response.writer.writeByte(',');
        try response.writer.print("\"{s}\"", .{&name});
    }
    try response.writer.writeAll("]}");
    try state.writer.writeResponse(alloc, id, response.written());
}

/// The most images, and image bytes, a host may stage for one open: those of
/// the largest image window, the newest images a session keeps, and those of
/// the open turn, which the window leaves out and which holds one prompt's
/// images at most.
/// An open that needs more, because its open turn's tools returned images
/// beyond one prompt's, may stage what it reported missing
/// (`ActiveSessionState.staging_needed`).
const max_staged_images = (session_codec.ImageWindow{}).max_images + image_attachments.max_libfx_prompt_images;
const max_staged_image_bytes = (session_codec.ImageWindow{}).max_bytes + image_attachments.max_libfx_prompt_images_bytes;

const StagedTotals = struct { images: usize = 0, bytes: usize = 0 };

/// The image window an open asks for, `{images, bytes}`, each at most the
/// default: a host may keep fewer images, never more than an open stages.
/// Null when the value is not one.
fn imageWindowParam(value: ?std.json.Value) ?session_codec.ImageWindow {
    const defaults: session_codec.ImageWindow = .{};
    const object = switch (value orelse return defaults) {
        .object => |object| object,
        else => return null,
    };
    var window = defaults;
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const limit = switch (entry.value_ptr.*) {
            .integer => |integer| std.math.cast(usize, integer) orelse return null,
            else => return null,
        };
        if (limit == 0) return null;
        if (std.mem.eql(u8, entry.key_ptr.*, "images")) {
            window.max_images = @min(limit, defaults.max_images);
        } else if (std.mem.eql(u8, entry.key_ptr.*, "bytes")) {
            window.max_bytes = @min(limit, defaults.max_bytes);
        } else return null;
    }
    return window;
}

/// Stages images from the host's store for the journal the session opens
/// next. `images` is `[{name, attachment}]`; each attachment holds the bytes
/// whose SHA-256 is the name.
fn handleKernelJournalImages(
    state: *ServerState,
    alloc: Allocator,
    msg: *const jsonrpc.Message,
) !void {
    const invalid: jsonrpc.RpcError = .{
        .code = ErrorCode.invalid_params,
        .message = "Invalid journal images",
    };
    const too_large: jsonrpc.RpcError = .{
        .code = ErrorCode.invalid_params,
        .message = "Journal images are too large",
    };
    var parsed = libfxSessionId(alloc, msg) catch return state.writer.writeError(alloc, msg.id, invalid);
    defer parsed.deinit();
    const active = activeLibfxSession(state, parsed.value) orelse
        return state.writer.writeError(alloc, msg.id, unknownLibfxSession(parsed.value));
    const store = state.host.cfg.host_attachments orelse return state.writer.writeError(alloc, msg.id, invalid);
    const list = parsed.value.object.get("images") orelse return state.writer.writeError(alloc, msg.id, invalid);
    if (list != .array or list.array.items.len == 0) return state.writer.writeError(alloc, msg.id, invalid);

    active.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer active.session_write_mutex.unlock(io_mod.getIo());
    if (active.journal != null) return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_request,
        .message = "Journal is already open",
    });
    for (list.array.items) |item| {
        if (item != .object) return state.writer.writeError(alloc, msg.id, invalid);
        const name_value = item.object.get("name") orelse return state.writer.writeError(alloc, msg.id, invalid);
        if (name_value != .string) return state.writer.writeError(alloc, msg.id, invalid);
        const name = session_codec.imageName(name_value.string) orelse return state.writer.writeError(alloc, msg.id, invalid);
        const reference = item.object.get("attachment") orelse return state.writer.writeError(alloc, msg.id, invalid);
        const attachment = host_attachments.idFromJson(reference) orelse return state.writer.writeError(alloc, msg.id, invalid);
        if (active.staged_images.images.count() >= @max(max_staged_images, active.staging_needed.images)) return state.writer.writeError(alloc, msg.id, too_large);
        const bytes = store.take(state.alloc, attachment, image_attachments.max_image_bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.AttachmentUnavailable => return state.writer.writeError(alloc, msg.id, invalid),
            error.AttachmentTooLarge => return state.writer.writeError(alloc, msg.id, too_large),
        };
        if (bytes.len > @max(max_staged_image_bytes, active.staging_needed.bytes) -| active.staged_images.bytes) {
            state.alloc.free(bytes);
            return state.writer.writeError(alloc, msg.id, too_large);
        }
        active.staged_images.add(state.alloc, name, bytes) catch |err| {
            state.alloc.free(bytes);
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.ImageNameMismatch => state.writer.writeError(alloc, msg.id, .{
                    .code = ErrorCode.invalid_params,
                    .message = "Image does not match its name",
                }),
            };
        };
    }
    const written = try alloc.print("{{\"staged\":{d}}}", .{active.staged_images.images.count()});
    defer alloc.free(written);
    try state.writer.writeResponse(alloc, msg.id, written);
}

/// A snapshot of the session for its journal to store, when it is quiet (no
/// turn open and no follow-up waiting) or at a turn that yielded with nothing
/// waiting for it, which the snapshot then carries. `null` otherwise; the
/// host asks again after a later turn. The snapshot covers every event
/// through `atSeq`.
fn handleKernelSnapshot(
    state: *ServerState,
    alloc: Allocator,
    msg: *const jsonrpc.Message,
) !void {
    var parsed = libfxSessionId(alloc, msg) catch return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Invalid snapshot params",
    });
    defer parsed.deinit();
    const active = activeLibfxSession(state, parsed.value) orelse
        return state.writer.writeError(alloc, msg.id, unknownLibfxSession(parsed.value));
    const store = state.host.cfg.host_attachments orelse return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_request,
        .message = "Snapshot is unavailable",
    });
    const meta = checkpointMetaParam(parsed.value) orelse return state.writer.writeError(alloc, msg.id, invalid_checkpoint_meta);
    const none = "{\"snapshotAttachment\":null}";
    active.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer active.session_write_mutex.unlock(io_mod.getIo());
    const journal = if (active.journal) |*value| value else return state.writer.writeResponse(alloc, msg.id, none);
    const yielded = journal.yieldedQuiet();
    if (!journal.quiet() and !yielded) return state.writer.writeResponse(alloc, msg.id, none);
    // A session past a snapshot's bounds gets none until compaction brings it
    // back within them; the host learns why. Images the host stored are
    // named, not held.
    const stored = journal.storedImages();
    const encoded = if (stored) |names|
        active.session_rt.agent.checkpointNamingImages(alloc, meta, names)
    else
        active.session_rt.agent.checkpoint(alloc, meta);
    const checkpoint = encoded catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CheckpointTooLarge => return writeSnapshotSkipped(state, alloc, msg.id, if (active.session_rt.agent.history.items.len > journal_events.max_history_turns) .too_many_turns else .too_large),
        else => return writeSnapshotSkipped(state, alloc, msg.id, .invalid),
    };
    defer alloc.free(checkpoint);
    const at_seq = journal.cursor.next_seq - 1;
    var open_turn: std.Io.Writer.Allocating = .init(alloc);
    defer open_turn.deinit();
    var open_turn_names_images = false;
    if (yielded) {
        if (stored) |names| {
            open_turn_names_images = try journal_events.writeOpenTurnNamingImages(&open_turn.writer, journal.open_turn_id.slice(), journal.pending_resume.?, names);
        } else {
            try journal_events.writeOpenTurn(&open_turn.writer, journal.open_turn_id.slice(), journal.pending_resume.?);
            // An image the session dropped is written by name even here.
            open_turn_names_images = session_codec.checkpointNamesImages(journal.pending_resume.?, null, null);
        }
    }
    const snapshot_bytes = if (yielded and session_codec.executionUsesNotesSchema(journal.pending_resume.?.execution))
        journal_events.encodeSnapshotWithNotes(alloc, at_seq, journal.cursor.turn, journal.last_turn_id.slice(), open_turn.written(), checkpoint)
    else if (open_turn_names_images)
        journal_events.encodeSnapshotNamingImages(alloc, at_seq, journal.cursor.turn, journal.last_turn_id.slice(), open_turn.written(), checkpoint)
    else
        journal_events.encodeSnapshot(alloc, at_seq, journal.cursor.turn, journal.last_turn_id.slice(), if (yielded) open_turn.written() else null, checkpoint);
    const bytes = snapshot_bytes catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SnapshotTooLarge => return writeSnapshotSkipped(state, alloc, msg.id, .too_large),
    };
    defer alloc.free(bytes);
    // A snapshot travels back as one host attachment.
    if (bytes.len > journal_events.max_snapshot_bytes) return writeSnapshotSkipped(state, alloc, msg.id, .too_large);
    const attachment = store.put(bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.AttachmentStoreFull => return state.writer.writeResponse(alloc, msg.id, none),
    };
    if (yielded) journal.noteOpenTurnSnapshot();
    const written = try alloc.print("{{\"snapshotAttachment\":{d},\"atSeq\":{d}}}", .{ attachment, at_seq });
    defer alloc.free(written);
    try state.writer.writeResponse(alloc, msg.id, written);
}

/// Why a session past a snapshot's bounds gets none.
const SnapshotSkip = enum { too_large, too_many_turns, invalid };

fn writeSnapshotSkipped(state: *ServerState, alloc: Allocator, id: ?jsonrpc.RequestId, reason: SnapshotSkip) !void {
    debug_trace.logf("session", "event=libfx_snapshot_skipped reason={s}", .{@tagName(reason)});
    const body = try alloc.print("{{\"snapshotAttachment\":null,\"skipped\":\"{s}\"}}", .{@tagName(reason)});
    defer alloc.free(body);
    try state.writer.writeResponse(alloc, id, body);
}

/// Records a follow-up the host queued behind the running turn, so a journal
/// keeps it across a crash. The host runs it; its turn places it.
fn handleKernelFollowUp(
    state: *ServerState,
    alloc: Allocator,
    msg: *const jsonrpc.Message,
) !void {
    var parsed = libfxSessionId(alloc, msg) catch return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Invalid follow-up params",
    });
    defer parsed.deinit();
    const active = activeLibfxSession(state, parsed.value) orelse
        return state.writer.writeError(alloc, msg.id, unknownLibfxSession(parsed.value));
    const id = parsed.value.object.get("id");
    const text = parsed.value.object.get("text");
    const valid_id = if (id) |value| value == .string and libfx_steering.validInputId(value.string) else false;
    const valid_text = if (text) |value| value == .string and value.string.len > 0 and value.string.len <= libfx_steering.max_message_bytes else false;
    if (!valid_id or !valid_text) return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "A follow-up needs a valid id and 1 byte to 64 KiB of text",
    });
    {
        active.session_write_mutex.lockUncancelable(io_mod.getIo());
        defer active.session_write_mutex.unlock(io_mod.getIo());
        if (active.journal) |*journal| try journal.append(alloc, active.session_id, .{ .input_accepted = .{
            .id = id.?.string,
            .text = text.?.string,
            .kind = .follow_up,
        } });
    }
    try state.writer.writeResponse(alloc, msg.id, "null");
}

/// `_sh.fx/session/steer`: adds a host's text to the running turn, under
/// the limits of a steer. The optional input id is the host's, and the
/// steer's `user_message_chunk` carries it in `sh.fx/steerInput`.
fn handleKernelSteer(
    state: *ServerState,
    alloc: Allocator,
    msg: *const jsonrpc.Message,
) !void {
    var parsed = libfxSessionId(alloc, msg) catch return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Invalid steer params",
    });
    defer parsed.deinit();
    const active = activeLibfxSession(state, parsed.value) orelse
        return state.writer.writeError(alloc, msg.id, unknownLibfxSession(parsed.value));
    const text = parsed.value.object.get("text") orelse
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Missing steering text",
        });
    if (text != .string) return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Invalid steering text",
    });
    const input_id: ?[]const u8 = if (parsed.value.object.get("id")) |value| switch (value) {
        .string => |id| id,
        .null => null,
        else => return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Invalid input id",
        }),
    } else null;
    queueLibfxSteering(state, alloc, active, text.string, input_id) catch |err| {
        return state.writer.writeError(alloc, msg.id, .{
            .code = switch (err) {
                error.SteeringQueueFull, error.SteeringNotActive => ErrorCode.invalid_request,
                error.EmptySteeringMessage, error.SteeringMessageTooLarge, error.InvalidInputId => ErrorCode.invalid_params,
                else => ErrorCode.internal_error,
            },
            .message = switch (err) {
                error.EmptySteeringMessage => "Steering text cannot be empty",
                error.SteeringMessageTooLarge => "Steering text exceeds the 64 KiB limit",
                error.SteeringQueueFull => "Steering queue is full",
                error.SteeringNotActive => "No prompt is running",
                error.InvalidInputId => "Invalid or repeated input id",
                error.OutOfMemory => "Failed to queue steering text",
                else => "Failed to record steering in the journal",
            },
        });
    };
    // While the model streams a reply, the steer cuts it short, as in the fx
    // CLI. The turn shows the steer when a boundary places it.
    if (active.steering.claimInterrupt(&active.cancel_flag)) {
        debug_trace.logf("acp", "libfx steer interrupts the streaming reply bytes={d}", .{text.string.len});
    }
    try state.writer.writeResponse(alloc, msg.id, "null");
}

fn parsedSessionTargetDecision(state: *ServerState, root: std.json.Value) SessionTargetDecision {
    const supplied = if (root == .object) root.object.get("sessionId") else null;
    return decideSessionTarget(sessionCount(state), parsedSessionTarget(state, root) != null, supplied);
}

/// The open session a request's params name, or null.
fn parsedSessionTarget(state: *ServerState, root: std.json.Value) ?*ActiveSessionState {
    const requested = requestedSessionId(root) orelse return null;
    return findSession(state, requested);
}

/// Whether the session's prompt slot holds a turn: one that runs, or one that has
/// ended and is not yet reaped. Another reader can reap the turn that the slot
/// names, so the slot is read under the line lock. A caller that acts on the answer
/// more than once checks again under the lock.
pub fn sessionPromptRunning(session: *ActiveSessionState) bool {
    session.waiting_prompts.lock();
    defer session.waiting_prompts.unlock();
    return session.prompt != null;
}

/// Copies the session's client system prompt for a turn. The caller holds
/// `settings_mutex`. A turn takes this copy when it starts, so a prompt that a load
/// changes while the turn runs does not reach that turn (`TurnSettings.capture`).
pub fn dupClientSystemPromptLocked(alloc: Allocator, session: *const ActiveSessionState) ![]u8 {
    return alloc.dupe(u8, session.client_system_prompt);
}

/// Test only: claims the session's slot for a prompt, as a prompt that starts a turn
/// does, without starting its worker. `releaseTurnForTest` gives the claim back.
pub fn claimTurnForTest(state: *ServerState, alloc: Allocator, session: *ActiveSessionState) !void {
    if (comptime !builtin.is_test) return error.TestOnly;
    const msg = jsonrpc.Message{ .id = .{ .integer = 1 }, .method = "session/prompt" };
    switch (try decideSessionPrompt(state, alloc, &msg, session)) {
        .claimed => {},
        else => return error.TestUnexpectedResult,
    }
}

/// Test only: gives back the claim that `claimTurnForTest` made.
pub fn releaseTurnForTest(session: *ActiveSessionState) void {
    if (comptime !builtin.is_test) return;
    session.waiting_prompts.lock();
    const turn = session.prompt orelse {
        session.waiting_prompts.unlock();
        return;
    };
    session.prompt = null;
    session.waiting_prompts.worker_running = false;
    session.waiting_prompts.unlock();
    freeActivePrompt(turn);
}

/// Whether a request that waits for a prompt arrives while one runs: the
/// prompt of the session it names, or, where the connection holds one
/// session, any prompt. A request for another session, or one that names
/// none on `fx acp`, goes on (`tests/tla/acp/AcpSessions.tla` OthersUntouched).
fn promptBusy(state: *ServerState, alloc: Allocator, msg: *const jsonrpc.Message) bool {
    if (holdsOneSession(state)) {
        // A stale answer only refuses the request as busy.
        var running_index: usize = 0;
        while (sessionAt(state, running_index)) |session| : (running_index += 1) if (sessionPromptRunning(session)) return true;
        return false;
    }
    const raw = msg.params_raw orelse return false;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch return false;
    defer parsed.deinit();
    const session = parsedSessionTarget(state, parsed.value) orelse return false;
    return sessionPromptRunning(session);
}

/// Answers a request whose `sessionId` is not the open session. A missing or malformed id is
/// invalid params; an id that names no open session gets ACP's `-32002` with `data.sessionId`.
fn writeSessionTargetError(
    state: *ServerState,
    alloc: Allocator,
    id: ?jsonrpc.RequestId,
    decision: SessionTargetDecision,
    root: std.json.Value,
) !void {
    const message: []const u8 = switch (decision) {
        .exact => return,
        .missing => return state.writer.writeError(alloc, id, .{
            .code = ErrorCode.invalid_params,
            .message = "Missing sessionId",
        }),
        .inactive => "No active session",
        .mismatch => "Session is not active",
    };
    // With no open session, `decideSessionTarget` answers `.inactive` before it looks at the id.
    const requested = requestedSessionId(root) orelse return state.writer.writeError(alloc, id, .{
        .code = ErrorCode.invalid_params,
        .message = message,
    });
    try state.writer.writeError(alloc, id, jsonrpc.sessionNotFound(message, requested));
}

/// Returns the non-empty string `sessionId` of request params, or null.
fn requestedSessionId(root: std.json.Value) ?[]const u8 {
    if (root != .object) return null;
    const value = root.object.get("sessionId") orelse return null;
    return if (value == .string and value.string.len > 0) value.string else null;
}

/// The answer to a libfx request whose session is not the open one: ACP's `-32002` with
/// `data.sessionId` when the request names an id, and invalid params when it names none.
fn unknownLibfxSession(params: std.json.Value) jsonrpc.RpcError {
    const requested = requestedSessionId(params) orelse return .{
        .code = ErrorCode.invalid_params,
        .message = "Unknown session",
    };
    return jsonrpc.sessionNotFound("Unknown session", requested);
}

test "a libfx request for a session that isn't open names it, and one without an id is invalid" {
    const alloc = std.testing.allocator;
    const named = try std.json.parseFromSlice(std.json.Value, alloc, "{\"sessionId\":\"s1\"}", .{});
    defer named.deinit();
    const not_found = unknownLibfxSession(named.value);
    try std.testing.expectEqual(ErrorCode.resource_not_found, not_found.code);
    try std.testing.expectEqualStrings("s1", not_found.data.?.session.session_id);

    for ([_][]const u8{ "{}", "{\"sessionId\":\"\"}", "{\"sessionId\":3}", "[]" }) |params| {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, params, .{});
        defer parsed.deinit();
        const invalid = unknownLibfxSession(parsed.value);
        try std.testing.expectEqual(ErrorCode.invalid_params, invalid.code);
        try std.testing.expectEqualStrings("Unknown session", invalid.message);
        try std.testing.expect(invalid.data == null);
    }
}

/// The open session a request names, or null once it has answered the
/// request's error.
fn requireParsedSessionTarget(
    state: *ServerState,
    alloc: Allocator,
    id: ?jsonrpc.RequestId,
    root: std.json.Value,
) !?*ActiveSessionState {
    var decision = parsedSessionTargetDecision(state, root);
    if (decision == .exact) return parsedSessionTarget(state, root).?;
    // A follower changes nothing: the connection that owns the session does. A follower's prompt
    // and cancel never reach this lookup (promptFromFollower and cancelFollowedSession handle
    // them). The lookup refuses the other session-scoped requests a follower can send: set_mode
    // and set_config_option.
    if (comptime follow_supported) {
        if (requestedSessionId(root)) |requested| {
            // The main client can change between the two reads (a leave on another connection's
            // thread). A connection that became the main then leads the session, so the decision is read again.
            prompt_test_controls.noteTargetDecided();
            if (followedElsewhere(state, requested)) {
                try state.writer.writeError(alloc, id, .{ .code = ErrorCode.invalid_request, .message = follower_refusal });
                return null;
            }
            decision = parsedSessionTargetDecision(state, root);
            if (decision == .exact) {
                if (parsedSessionTarget(state, root)) |session| return session;
            }
        }
    }
    try writeSessionTargetError(state, alloc, id, decision, root);
    return null;
}

/// The answer to a change request from a connection that only follows the session. Still
/// refused: `session/set_mode` and `session/set_config_option`, because a follower's mode and
/// config changes are not allowed yet. A follower's `session/prompt` and `session/cancel` are
/// accepted.
const follower_refusal = "This session is open on another connection; only that connection can change it.";

/// Whether `session_id` is a session this connection follows and another
/// connection still has open. A follow whose owner has closed the session is
/// forgotten here, so the request gets the same not-found answer as any id that
/// is not open.
fn followedElsewhere(state: *ServerState, session_id: []const u8) bool {
    // A follow exists only where `follow_supported` holds.
    if (comptime !follow_supported) return false;
    if (!followsSession(state, session_id)) return false;
    const shared = &state.host.shared;
    shared.mutex.lockUncancelable(io_mod.getIo());
    defer shared.mutex.unlock(io_mod.getIo());
    if (shared.findLocked(session_id) != null) return true;
    forgetFollowing(state, session_id);
    return false;
}

fn requireSessionTarget(
    state: *ServerState,
    alloc: Allocator,
    msg: *const jsonrpc.Message,
) !?*ActiveSessionState {
    const params = msg.params_raw orelse {
        try state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Missing params",
        });
        return null;
    };
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, params, .{}) catch {
        try state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Invalid params",
        });
        return null;
    };
    defer parsed.deinit();
    return requireParsedSessionTarget(state, alloc, msg.id, parsed.value);
}

/// The open session a notification names, or null when it names none.
fn notificationTargetSession(
    state: *ServerState,
    alloc: Allocator,
    params: ?[]const u8,
) ?*ActiveSessionState {
    const raw = params orelse return null;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch return null;
    defer parsed.deinit();
    const decision = parsedSessionTargetDecision(state, parsed.value);
    if (decision != .exact) {
        debug_trace.logf("acp", "ignored session notification target reason={s}", .{@tagName(decision)});
        return null;
    }
    return parsedSessionTarget(state, parsed.value);
}

/// Runs the session's turns: the prompt it started with, then, each time a
/// turn ends, what waits for it (`prompt_line.zig`): every late steer together
/// as one turn, else the first queued prompt. Once nothing waits, it marks
/// itself reapable before it sends the last answers, so a prompt the client
/// sends after them starts its own turn.
fn promptWorkerMain(active: *ActivePrompt) void {
    const host = active.host;
    const session = active.session;
    var mode = active.mode;
    var permission_mode = active.permission_mode;
    while (true) {
        const outcome: prompt_handler.TerminalOutcome = prompt_handler.handlePrompt(
            host,
            session,
            active.alloc,
            &active.msg,
            if (active.group_ids.len == 0) active.from else null,
            mode,
            permission_mode,
            &active.usage,
        ) catch |err| .{
            .rpc_error = .{
                .code = ErrorCode.internal_error,
                // A storage fault is named (D29); the wasm host keeps the error name.
                .message = if (sessionsStore(host) != null)
                    sessions.v2StorageFaultMessage("Session could not be saved", err) orelse @errorName(err)
                else
                    @errorName(err),
            },
        };
        // The turn is over and its updates are either saved or lost with it, so its copy goes.
        releaseRunningCopy(session, .turn_ended);
        var finished: ?libfx_steering.Finished = session.steering.finishTurn(host.alloc, host.alloc, "turn_finished") catch |err| blk: {
            debug_trace.logf("acp", "failed to collect steering prompts at turn end err={s}", .{@errorName(err)});
            break :blk null;
        };
        defer if (finished) |value| value.deinit(host.alloc);

        // The turn that just ended, answered below once the next one is chosen.
        var ended_msg = active.msg;
        const ended_from = active.from;
        const ended_group = active.group_ids;
        defer {
            jsonrpc.freeMessage(active.alloc, &ended_msg);
            freeSenderGroup(active.alloc, ended_group);
        }
        var cancelled_steers: []const libfx_steering.Steer = &.{};
        var dropped_waiting: ?DroppedWaiting = null;
        const next = next: {
            const line = &session.waiting_prompts;
            line.lock();
            defer line.unlock();
            if (finished) |*value| handBack: {
                if (line.closing) {
                    cancelled_steers = value.untaken;
                    break :handBack;
                }
                line.handBackLocked(host.alloc, value.untaken) catch {
                    debug_trace.logf("acp", "dropped steers the turn never took count={d} reason=out_of_memory", .{value.untaken.len});
                    cancelled_steers = value.untaken;
                    break :handBack;
                };
                // The line owns the steers now.
                host.alloc.free(value.untaken);
                value.untaken = &.{};
            }
            if (!line.closing) if (line.takeNextLocked()) |taken| {
                var waiting = taken;
                if (startNextTurn(active, session, &waiting)) {
                    session.turn_cancel.store(false, .seq_cst);
                    session.cancel_flag.store(false, .seq_cst);
                    session.steering.open(host.alloc);
                    mode = session.mode;
                    permission_mode = session.permission_mode;
                    break :next waiting;
                } else |err| {
                    debug_trace.logf("acp", "failed to start the next waiting turn err={s}", .{@errorName(err)});
                    // Answered after the line unlocks: answering takes the audience lock.
                    dropped_waiting = .{ .input = waiting, .err = err };
                }
            };
            // The turn that ended owned `active.msg`; a withdrawal reads it
            // under this mutex.
            active.msg = .{};
            active.group_ids = &.{};
            line.worker_running = false;
            // AcpSessionReaders WorkerEnd: the worker is reapable here. Its last answers
            // follow in publishTurnOutcome, so a second turn waits for the join.
            active.reapable.store(true, .seq_cst);
            break :next null;
        };

        publishTurnOutcome(active, ended_from, ended_msg.id, ended_group, outcome, finished);
        for (cancelled_steers) |steer| answerCancelled(host, session, steer.from, steer.request_id);
        if (dropped_waiting) |*dropped| {
            answerDroppedWaiting(session, host.alloc, dropped);
            dropped.input.deinit(host.alloc);
        }
        if (next) |taken| {
            var waiting = taken;
            defer waiting.deinit(host.alloc);
            if (waiting == .steers) publishStartingSteers(session, active.alloc, waiting.steers.items);
            // The ended turn's answer carried its usage; the next one sums its own.
            active.usage = .{};
            continue;
        }
        break;
    }
    prompt_test_controls.pauseAfterTerminalWrite();
}

/// Makes what waits the running prompt's next turn: a queued prompt as the
/// client sent it, or the late steers as one prompt of their text blocks,
/// answered by request id. On success `waiting` keeps only the steers, which
/// the caller shows as they start the turn.
fn startNextTurn(active: *ActivePrompt, session: *ActiveSessionState, waiting: *prompt_line.Next) !void {
    switch (waiting.*) {
        .prompt => |queued| {
            active.msg = try cloneMessage(active.alloc, &queued.msg);
            active.from = queued.from;
            active.group_ids = &.{};
        },
        .steers => |steers| {
            var params: std.Io.Writer.Allocating = .init(active.alloc);
            defer params.deinit();
            try params.writer.writeAll("{\"sessionId\":");
            try jsonrpc.writeJsonStr(session.session_id, &params.writer);
            try params.writer.writeAll(",\"prompt\":[");
            for (steers.items, 0..) |steer, index| {
                if (index > 0) try params.writer.writeByte(',');
                try params.writer.writeAll("{\"type\":\"text\",\"text\":");
                try jsonrpc.writeJsonStr(steer.text, &params.writer);
                try params.writer.writeByte('}');
            }
            try params.writer.writeAll("]}");
            const senders = try active.alloc.alloc(libfx_steering.Sender, steers.items.len);
            var copied: usize = 0;
            errdefer {
                for (senders[0..copied]) |sender| jsonrpc.freeRequestId(active.alloc, sender.id);
                active.alloc.free(senders);
            }
            for (steers.items, senders) |steer, *sender| {
                sender.* = .{ .id = try jsonrpc.dupeRequestId(active.alloc, steer.request_id), .from = steer.from };
                copied += 1;
            }
            var msg: jsonrpc.Message = .{ .method = try active.alloc.dupe(u8, "session/prompt") };
            errdefer jsonrpc.freeMessage(active.alloc, &msg);
            msg.id = try jsonrpc.dupeRequestId(active.alloc, steers.items[0].request_id);
            msg.params_raw = try params.toOwnedSlice();
            active.msg = msg;
            active.from = steers.items[0].from;
            active.group_ids = senders;
        },
    }
}

fn freeSenderGroup(alloc: Allocator, senders: []libfx_steering.Sender) void {
    libfx_steering.freeSenders(alloc, senders);
    if (senders.len > 0) alloc.free(senders);
}

fn freeActivePrompt(active: *ActivePrompt) void {
    jsonrpc.freeMessage(active.alloc, &active.msg);
    freeSenderGroup(active.alloc, active.group_ids);
    active.alloc.destroy(active);
}

/// Shows each steer that starts a turn together with the others, as a
/// `user_message_chunk` with `sh.fx/steerInput`, as a steer a running turn
/// takes is shown.
fn publishStartingSteers(session: *ActiveSessionState, alloc: Allocator, steers: []const libfx_steering.Steer) void {
    for (steers) |steer| {
        var message_id_storage: acp_types.MessageIdBuffer = undefined;
        const message_id = acp_types.generateMessageId(&message_id_storage);
        // Without `follow_supported` no follower takes the other version, so only the owner's is built.
        if (comptime !follow_supported) {
            const main_record = holdMain(session);
            defer main_record.drop();
            const params = steerChunkParams(alloc, session.session_id, message_id, steer.text, steer.request_id, null, main_record.sendsSteerInput()) catch {
                debug_trace.logf("acp", "dropped the update for a steer that starts a turn reason=out_of_memory", .{});
                continue;
            };
            defer alloc.free(params);
            var audience = lockAudience(session);
            defer audience.unlock();
            audience.deliver(alloc, "session/update", .none, params, null) catch |err|
                debug_trace.logf("acp", "failed to send the update for a steer that starts a turn err={s}", .{@errorName(err)});
            continue;
        }
        // Both versions are built, so a joiner takes the one its prompt delivery asks for.
        const with = steerChunkParams(alloc, session.session_id, message_id, steer.text, steer.request_id, null, true) catch {
            debug_trace.logf("acp", "dropped the update for a steer that starts a turn reason=out_of_memory", .{});
            continue;
        };
        defer alloc.free(with);
        const without = steerChunkParams(alloc, session.session_id, message_id, steer.text, steer.request_id, null, false) catch {
            debug_trace.logf("acp", "dropped the update for a steer that starts a turn reason=out_of_memory", .{});
            continue;
        };
        defer alloc.free(without);
        var audience = lockAudience(session);
        defer audience.unlock();
        audience.deliver(alloc, "session/update", .steer_input, with, without) catch |err|
            debug_trace.logf("acp", "failed to send the update for a steer that starts a turn err={s}", .{@errorName(err)});
    }
}

/// At a cancel boundary of a libfx turn: whether steering, not the user,
/// cancelled it, and why. A steer's cancel is spent so the turn goes on.
pub fn takeSteeringInterrupt(active: *ActiveSessionState) ?libfx_steering.Runtime.Interrupt {
    return active.steering.takeInterrupt(&active.cancel_flag);
}

/// Spends a steer's interrupt the running libfx turn no longer needs, so its
/// cancel flag reports only a user cancel.
pub fn releaseSteeringInterrupt(active: *ActiveSessionState) void {
    active.steering.releaseInterrupt(&active.cancel_flag);
}

/// Records that the running libfx turn's step works on an announced tool call.
pub fn noteSteeringToolsPhase(active: *ActiveSessionState) void {
    active.steering.noteToolsPhase();
}

/// Whether the running libfx turn ends at this boundary for a handoff.
pub fn steeringHandoffPending(active: *ActiveSessionState) bool {
    return active.steering.handoffPending();
}

/// Records what the running libfx turn's current step does, which decides
/// whether a queued steer interrupts it.
pub fn noteSteeringPhase(active: *ActiveSessionState, step: u64, phase: libfx_steering.Phase) void {
    if (active.steering.notePhase(step, phase, &active.cancel_flag)) {
        debug_trace.logf("acp", "queued libfx steer interrupts the streaming reply step={d}", .{step});
    }
}

/// Whether the `queued` steers a web host holds should interrupt the running
/// libfx turn's streaming reply now; if so the turn's cancel flag is set.
pub fn claimHostSteeringInterrupt(active: *ActiveSessionState, queued: usize) bool {
    return active.steering.claimHostInterrupt(queued, &active.cancel_flag);
}

/// A handoff a web host holds for the running libfx turn: the turn ends at its
/// next safe point, as with `_sh.fx/session/end_turn_for_steer`.
pub fn noteHostSteeringHandoff(active: *ActiveSessionState) void {
    _ = active.steering.requestHandoff(&active.cancel_flag);
}

/// A boundary of a libfx turn whose web host keeps the steering queue.
pub fn noteSteeringBoundary(active: *ActiveSessionState) void {
    active.steering.noteBoundary();
}

/// Records a libfx turn's tool call `call_id` starting or ending.
pub fn noteSteeringTool(active: *ActiveSessionState, call_id: []const u8, started: bool) void {
    if (started) {
        const main_record = holdMain(active);
        defer main_record.drop();
        active.steering.noteToolStarted(main_record.alloc, call_id);
    } else {
        const second_main_record = holdMain(active);
        defer second_main_record.drop();
        active.steering.noteToolEnded(second_main_record.alloc, call_id);
    }
}

/// Answers a turn that ended: the prompt that started it, or each steer that
/// started it together (`next_turn`), and each steer it took (`absorbed`). Each
/// answer goes to the connection that sent its request, in the shape that
/// connection lists.
fn publishTurnOutcome(
    active: *ActivePrompt,
    from: ConnectionId,
    owner: ?jsonrpc.RequestId,
    group: []const libfx_steering.Sender,
    outcome: prompt_handler.TerminalOutcome,
    finished: ?libfx_steering.Finished,
) void {
    if (group.len == 0) {
        publishPromptOutcome(active, from, owner, outcome) catch |err|
            debug_trace.logf("acp", "failed to answer a prompt err={s}", .{@errorName(err)});
    }
    for (group) |sender| writeSteeringOutcome(active, sender, outcome, .next_turn) catch |err|
        debug_trace.logf("acp", "failed to answer a steer err={s}", .{@errorName(err)});
    const value = finished orelse return;
    for (value.absorbed) |sender| writeSteeringOutcome(active, sender, outcome, .absorbed) catch |err|
        debug_trace.logf("acp", "failed to answer a steer err={s}", .{@errorName(err)});
}

fn publishPromptOutcome(active: *ActivePrompt, from: ConnectionId, id: ?jsonrpc.RequestId, outcome: prompt_handler.TerminalOutcome) !void {
    switch (outcome) {
        .stop_reason => |stop_reason| {
            // Without `follow_supported` the owner is the only member, so only its own shape is built.
            if (comptime !follow_supported) {
                const body = try stopResponse(active, stop_reason, active.usage_shown);
                defer active.alloc.free(body);
                return answerSender(active.session, active.alloc, from, id, .none, .{ .response = body }, .{ .response = body });
            }
            const with = try stopResponse(active, stop_reason, true);
            defer active.alloc.free(with);
            const without = try stopResponse(active, stop_reason, false);
            defer active.alloc.free(without);
            try answerSender(active.session, active.alloc, from, id, .{ .extension = .usage }, .{ .response = with }, .{ .response = without });
        },
        .rpc_error => |rpc_error| try answerSender(active.session, active.alloc, from, id, .none, .{ .rpc_error = rpc_error }, .{ .rpc_error = rpc_error }),
    }
}

/// The response to a turn's stop. `usage` says whether the member lists `.usage`,
/// which adds the turn's timing as `_meta`. The usage reported is the prompt's sum
/// over its turns (`active.usage`). The caller frees the result.
fn stopResponse(active: *ActivePrompt, stop_reason: acp_types.StopReason, usage: bool) ![]u8 {
    var response: std.Io.Writer.Allocating = .init(active.alloc);
    defer response.deinit();
    try acp_types.writePromptResponseWithUsage(
        &response.writer,
        stop_reason,
        active.usage,
        active.session.turn_summary,
        usage,
    );
    return response.toOwnedSlice();
}

fn writeSteeringOutcome(
    active: *ActivePrompt,
    sender: libfx_steering.Sender,
    outcome: prompt_handler.TerminalOutcome,
    delivery: acp_types.SteeringDelivery,
) !void {
    switch (outcome) {
        .stop_reason => |stop_reason| {
            // Without `follow_supported` the owner is the only member: the delivery is in its response only when it lists `.prompt_delivery`.
            if (comptime !follow_supported) {
                const delivery_shown: ?acp_types.SteeringDelivery = if (active.delivery_shown) delivery else null;
                const body = try steerResponse(active, stop_reason, delivery_shown);
                defer active.alloc.free(body);
                return answerSender(active.session, active.alloc, sender.from, sender.id, .none, .{ .response = body }, .{ .response = body });
            }
            // A member that lists `.prompt_delivery` takes the delivery; the others take the response without it.
            const with = try steerResponse(active, stop_reason, delivery);
            defer active.alloc.free(with);
            const without = try steerResponse(active, stop_reason, null);
            defer active.alloc.free(without);
            try answerSender(active.session, active.alloc, sender.from, sender.id, .{ .extension = .prompt_delivery }, .{ .response = with }, .{ .response = without });
        },
        .rpc_error => |rpc_error| try answerSender(active.session, active.alloc, sender.from, sender.id, .none, .{ .rpc_error = rpc_error }, .{ .rpc_error = rpc_error }),
    }
}

/// The response to a steer's turn stop, with its delivery when given. The caller frees the result.
fn steerResponse(active: *ActivePrompt, stop_reason: acp_types.StopReason, delivery: ?acp_types.SteeringDelivery) ![]u8 {
    var response: std.Io.Writer.Allocating = .init(active.alloc);
    defer response.deinit();
    try acp_types.writeSteeringPromptResponse(&response.writer, stop_reason, delivery);
    return response.toOwnedSlice();
}

/// Reaps the session's turn. Under the line lock it takes the turn out of the
/// slot and marks it joining (AcpSessionReaders ReapTake). Outside the lock it
/// joins the thread and frees the turn (JoinOwn, FreeOwn), then clears joining and
/// wakes the waiters. A reap that finds a join under way waits for it, so no turn
/// is joined twice. `wait` reaps a turn that is still running (a close); otherwise
/// only a finished turn is taken.
fn reapSessionPrompt(session: *ActiveSessionState, wait: bool) void {
    if (comptime host_target.is_wasm) return;
    const line = &session.waiting_prompts;
    const active = taken: {
        line.lock();
        defer line.unlock();
        const was_joining = line.joining;
        line.waitWhileJoiningLocked(false);
        if (was_joining) prompt_test_controls.noteJoinPassed();
        // AcpSessionReaders ReapRetry: the slot is empty, so there is nothing to reap.
        const active = session.prompt orelse return;
        if (!wait and !active.reapable.load(.seq_cst)) return;
        // AcpSessionReaders ReapTake: the turn leaves the slot, and joining marks it taken.
        session.prompt = null;
        line.joining = true;
        break :taken active;
    };
    prompt_test_controls.noteReapBeforeJoin();
    // AcpSessionReaders JoinOwn: the join runs outside the lock.
    active.thread.join();
    // AcpSessionReaders FreeOwn: the free runs outside the lock; then joining is
    // cleared under the lock, and the waiters wake.
    freeActivePrompt(active);
    line.lock();
    line.joining = false;
    line.wakeWaitersLocked();
    line.unlock();
}

/// Joins the worker of every session whose turns ended.
fn reapPrompts(state: *ServerState) void {
    var reap_index: usize = 0;
    while (sessionAt(state, reap_index)) |session| : (reap_index += 1) reapSessionPrompt(session, false);
}

fn cloneMessage(alloc: Allocator, msg: *const jsonrpc.Message) !jsonrpc.Message {
    var copy = jsonrpc.Message{
        .method = try alloc.dupe(u8, msg.method),
    };
    errdefer jsonrpc.freeMessage(alloc, &copy);
    if (msg.params_raw) |params| copy.params_raw = try alloc.dupe(u8, params);
    if (msg.id) |id| {
        copy.id = switch (id) {
            .integer => |value| .{ .integer = value },
            .string => |value| .{ .string = try alloc.dupe(u8, value) },
            .null => .null,
        };
    }
    return copy;
}

const InitializeRequest = struct {
    /// False when the client presents fx inside an application rather than a
    /// terminal, set through `sh.fx/terminalUi` in the params' `_meta`.
    terminal_ui: bool = true,
    client_fs_read: bool = false,
    client_fs_write: bool = false,
    client_terminal: bool = false,
    /// The client shows ACP v1 Session Notices (`session.notices`).
    client_notices: bool = false,
    /// The client takes ACP v1's compaction updates (`session.compaction`).
    client_compaction: bool = false,
    client_elicitation: elicitation.Capabilities = .{},
    host_tools: host_tool_runtime.Runtime = .{},
    /// The extensions the client lists in `clientCapabilities._meta`.
    client_extensions: sh_fx.Set = .empty,

    fn deinit(self: *InitializeRequest) void {
        self.host_tools.deinit();
        self.* = .{};
    }
};

fn parseInitializeRequest(
    alloc: Allocator,
    params: ?[]const u8,
    allow_host_tools: bool,
) !InitializeRequest {
    const raw = params orelse return error.InvalidInitializeParams;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch
        return error.InvalidInitializeParams;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidInitializeParams;

    const version = parsed.value.object.get("protocolVersion") orelse
        return error.InvalidInitializeParams;
    if (version != .integer) return error.InvalidInitializeParams;
    if (version.integer < 0 or version.integer > std.math.maxInt(u16))
        return error.InvalidInitializeParams;

    var request = InitializeRequest{
        .terminal_ui = acp_types.metaBool(parsed.value.object, "sh.fx/terminalUi") orelse true,
    };
    const capabilities = parsed.value.object.get("clientCapabilities") orelse
        return request;
    if (capabilities != .object) return request;
    if (capabilities.object.get("fs")) |fs| {
        if (fs == .object) {
            if (fs.object.get("readTextFile")) |value| {
                request.client_fs_read = value == .bool and value.bool;
            }
            if (fs.object.get("writeTextFile")) |value| {
                request.client_fs_write = value == .bool and value.bool;
            }
        }
    }
    if (capabilities.object.get("session")) |session| {
        // ACP v1 advertises notices with an object, `{}`. Omitted, null,
        // and any value v1 doesn't define, such as `false`, all mean no.
        if (session == .object) if (session.object.get("notices")) |notices| {
            request.client_notices = notices == .object;
        };
        if (session == .object) if (session.object.get("compaction")) |compaction| {
            request.client_compaction = compaction == .object;
        };
    }
    if (capabilities.object.get("terminal")) |value| {
        request.client_terminal = value == .bool and value.bool;
    }
    request.client_elicitation = elicitation.parseAcpCapabilities(capabilities);
    request.client_extensions = sh_fx.clientList(capabilities.object);
    // A client lists the tools it runs for fx in its `sh.fx/hostTools` value.
    if (allow_host_tools) if (sh_fx.clientValue(capabilities.object, .host_tools)) |host_tools| {
        request.host_tools = try host_tool_runtime.Runtime.initWithProviderRegistry(
            alloc,
            host_tools.get("tools"),
            libfx_provider_tool_registry,
        );
    };
    return request;
}

test "ACP initialize owns the tools a host lists in sh.fx/hostTools" {
    const alloc = std.testing.allocator;
    var request = try parseInitializeRequest(
        alloc,
        \\{"protocolVersion":1,"clientCapabilities":{"_meta":{"sh.fx/hostTools":{"tools":[{"name":"lookup","description":"Lookup","inputSchema":{"type":"object"}}]},"sh.fx/journal":{}}}}
    ,
        true,
    );
    defer request.deinit();
    try std.testing.expectEqual(@as(usize, 1), request.host_tools.tools.len);
    try std.testing.expectEqualStrings("lookup", request.host_tools.tools[0].name);
    try std.testing.expect(request.client_extensions.contains(.host_tools));
    try std.testing.expect(request.client_extensions.contains(.journal));
}

test "ACP initialize accepts registered provider-executed libfx tools" {
    const alloc = std.testing.allocator;
    var request = try parseInitializeRequest(
        alloc,
        \\{"protocolVersion":1,"clientCapabilities":{"_meta":{"sh.fx/hostTools":{"tools":[{"name":"web_search","providerExecuted":true}]}}}}
    ,
        true,
    );
    defer request.deinit();
    try std.testing.expectEqual(@as(usize, 1), request.host_tools.tools.len);
    try std.testing.expectEqual(@as(usize, 0), request.host_tools.dynamic_tools.len);
    try std.testing.expect(request.host_tools.tools[0].provider_executed);
    try std.testing.expect(request.host_tools.tools[0].write_provider_advertisement_fn != null);
}

test "ordinary ACP takes no host tools and ignores the old libfx capability" {
    const alloc = std.testing.allocator;
    var request = try parseInitializeRequest(
        alloc,
        \\{"protocolVersion":1,"clientCapabilities":{"libfx":{"tools":[{"name":"lookup"}]},"_meta":{"sh.fx/hostTools":{"tools":[{"name":"lookup"}]}}}}
    ,
        false,
    );
    defer request.deinit();
    try std.testing.expectEqual(@as(usize, 0), request.host_tools.tools.len);
    try std.testing.expect(request.client_extensions.contains(.host_tools));
}

/// Asks whether the credential's team has Token Pass. A team with Token Pass
/// starts new sessions on the Token Pass default when nothing chose the
/// model. The check waits here only when fx has no saved answer, and
/// `pollTokenPass` takes a later answer.
fn startTokenPassCheck(state: *ServerState, alloc: Allocator, model_source: config_runtime.ModelSource) void {
    if (state.provider != .gateway) return;
    const source = state.credential_source orelse return;
    const api_key: ?[]const u8 = if (state.api_key.len > 0) state.api_key else null;
    // A client that sends `initialize` again replaces the earlier check.
    if (state.token_pass_run) |*earlier| earlier.finish(alloc, "initialize_retried");
    state.token_pass_run = null;
    state.token_pass_start = null;
    const named = token_pass_check.name(alloc, source, api_key, state.account_id, state.gateway_team) orelse return;
    state.token_pass_run = .{ .named = named, .home = state.host.cfg.home_override orelse io_mod.homeDir() };
    state.token_pass_run.?.begin(
        alloc,
        state.host.cfg.provider_set.select(.gateway).credits orelse gateway_provider.unavailable_credits_provider,
        .{ .credential = api_key, .credential_source = source, .tenant = state.gateway_team },
        token_pass_check.first_prompt_wait_ms,
    );
    if (model_source != .compiled_default or state.process_model_override) return;
    state.token_pass_start = .{ .fast_mode = state.fast_mode, .ultrafast_mode = state.ultrafast_mode };
    applyTokenPassStartModel(state);
}

fn pollTokenPass(state: *ServerState) void {
    const check = if (state.token_pass_run) |*value| value else return;
    const before = check.has_pass;
    if (check.lookup.task != null) check.poll(state.alloc);
    _ = check.observeCatalog(state.alloc);
    if (check.has_pass != before) applyTokenPassStartModel(state);
}

/// Puts new sessions on the team's start model, unless a client chose
/// another model since. Token Pass credit pays only for standard speed.
fn applyTokenPassStartModel(state: *ServerState) void {
    const profile = state.token_pass_start orelse return;
    const has_pass = if (state.token_pass_run) |check| check.has_pass else false;
    const target = token_pass.startModelFor(state.selected_model, state.configured_model, has_pass) orelse return;
    if (!std.mem.eql(u8, state.selected_model, target)) {
        const owned = state.alloc.dupe(u8, target) catch |err| {
            debug_trace.logf("token_pass", "start model not applied err={s}", .{@errorName(err)});
            return;
        };
        if (state.selected_model.len > 0) state.alloc.free(state.selected_model);
        state.selected_model = owned;
        debug_trace.logf("token_pass", "start model={s}", .{target});
    }
    state.fast_mode = if (has_pass) false else profile.fast_mode;
    state.ultrafast_mode = if (has_pass) false else profile.ultrafast_mode;
}

fn loadConfiguredStartupState(state: *ServerState, alloc: Allocator) !app_lifecycle.StartupState {
    if (state.host.cfg.minimal_kernel) {
        var startup = try app_lifecycle.loadLibfxStartupState(
            alloc,
            state.host.cfg.workspace_root_override orelse "/",
            state.host.cfg.model_override orelse state.host.cfg.default_model,
            state.host.cfg.default_agent_step_limit,
        );
        errdefer startup.deinit(alloc);
        if (state.host.cfg.configured_providers_json) |json| {
            startup.configured_providers = try @import("../core/config/configured_provider.zig").Registry.parse_json(alloc, json);
        }
        return startup;
    }
    if (state.host.cfg.home_override) |home_dir| {
        if (state.host.cfg.workspace_root_override) |workspace_root| {
            var startup = try app_lifecycle.loadEmbeddedStartupState(
                alloc,
                home_dir,
                workspace_root,
                state.host.cfg.default_model,
                state.host.cfg.default_agent_step_limit,
                state.host.cfg.model_override,
            );
            startup.auth_mode = state.host.cfg.auth_mode;
            return startup;
        }
    }
    return app_lifecycle.loadStartupStateForRun(
        alloc,
        state.host.cfg.gateway_provider.oauth_transport,
        state.host.cfg.secret_store,
        state.host.cfg.default_model,
        state.host.cfg.default_agent_step_limit,
        state.host.cfg.auth_mode,
        null,
        state.host.cfg.model_override,
    );
}

fn configureUltrafastStartup(state: *ServerState, startup: *const app_lifecycle.StartupState) void {
    state.configured_ultrafast_mode = startup.configured_ultrafast_mode;
    state.process_ultrafast_override = state.host.cfg.ultrafast_override orelse startup.ultrafast_process_override;
    state.ultrafast_mode = state.process_ultrafast_override orelse state.configured_ultrafast_mode;
}

fn handleInitialize(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    if (state.initialized) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = "Already initialized",
        });
    }

    var request = parseInitializeRequest(
        alloc,
        msg.params_raw,
        state.host.cfg.minimal_kernel,
    ) catch {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Invalid initialize params",
        });
    };
    defer request.deinit();

    var startup = loadConfiguredStartupState(state, alloc) catch |err| {
        const model_message = config_runtime.modelNotSelectedMessage(err);
        const settings_message = if (model_message == null) try config_runtime.configuredProviderMessage(alloc, err) else null;
        defer if (settings_message) |message| alloc.free(message);
        return state.writer.writeError(alloc, msg.id, .{
            .code = if (model_message != null or settings_message != null) ErrorCode.invalid_request else ErrorCode.internal_error,
            .message = model_message orelse settings_message orelse "Failed to load startup state",
        });
    };
    defer startup.deinit(alloc);
    if (state.host.cfg.auth_mode == .local and startup.credential == null and
        !(startup.provider == .gateway and state.host.cfg.credential_override != null))
    {
        if (startup.credential_load_failure) |failure| {
            if (auth_runtime.preparationError(auth_runtime.classifyCredentialFailure(failure.source, failure.err))) |err| return err;
        }
    }
    if (!state.host.cfg.minimal_kernel) {
        try app_lifecycle.applyWorkspaceLaunch(
            &startup,
            alloc,
            state.host.cfg.additional_directories,
            state.host.cfg.saved_directories_suppressed,
        );
    }
    for (startup.config_diagnostics) |diagnostic| {
        if (diagnostic.recovery_path != null) {
            debug_trace.logf("config", "acp startup diagnostic layer={s} cause={s} recovery_available=true", .{
                @tagName(diagnostic.layer),
                @tagName(diagnostic.cause),
            });
        } else {
            debug_trace.logf("config", "acp startup diagnostic layer={s} cause={s}", .{
                @tagName(diagnostic.layer),
                @tagName(diagnostic.cause),
            });
        }
    }

    state.launch.root = startup.takeWorkspaceRoot();
    state.launch.access = startup.takeWorkspaceAccess();

    if (state.host.cfg.model_override) |override| {
        state.selected_model = try alloc.dupe(u8, override);
        alloc.free(startup.takeSelectedModel());
        state.process_model_override = true;
    } else {
        state.selected_model = startup.takeSelectedModel();
        state.process_model_override = startup.model_source == .process_override;
    }
    if (state.host.cfg.provider_override) |override| {
        state.provider = override;
        state.process_provider_override = true;
    } else {
        state.provider = startup.provider;
        state.process_provider_override = config_runtime.providerEnvOverride() != null;
    }
    state.configured_providers.deinit(alloc);
    state.configured_providers = startup.configured_providers;
    startup.configured_providers = .{};
    state.host.cfg.provider_set.definitions = state.configured_providers.definitions;
    state.gateway_source_preference = startup.credential_source_preference;
    state.configured_model = try alloc.dupe(u8, startup.configured_model);

    if (state.host.cfg.auth_mode == .host_managed or hostManagesRoute(state.host.cfg, state.provider)) {
        state.api_key = &.{};
        state.credential_source = .host_managed;
        state.credential_refresh_after_ms = null;
        state.account_id = null;
        state.gateway_team = null;
    } else {
        var startup_credential = startup.takeCredential();
        defer if (startup_credential) |*credential| credential.deinit(alloc);
        var routed_credential: ?credentials.Credential = null;
        defer if (routed_credential) |*credential| credential.deinit(alloc);
        const startup_matches_model = if (startup_credential) |credential|
            credentialMatchesProvider(credential.source, state.provider)
        else
            false;
        const startup_credential_is_final = startup_matches_model and
            !credentials.sourceRefreshable(startup_credential.?.source);
        const credential: *credentials.Credential = if (state.provider == .gateway and state.host.cfg.credential_override != null) override: {
            routed_credential = .{
                .token = try alloc.dupe(u8, state.host.cfg.credential_override.?),
                .source = .ai_gateway_api_key,
            };
            break :override &routed_credential.?;
        } else if (startup_credential_is_final)
            &startup_credential.?
        else routed: {
            routed_credential = try auth_runtime.prepareCredential(
                alloc,
                state.host.cfg.gateway_provider.oauth_transport,
                state.host.cfg.secret_store,
                state.provider,
                if (state.provider == .gateway) startup.credential_source_preference else null,
            );
            if (routed_credential == null) {
                return state.writer.writeError(alloc, msg.id, .{
                    .code = ErrorCode.invalid_request,
                    .message = if (state.provider == .codex)
                        credentials.missing_chatgpt_credential_message
                    else if (state.provider == .grok)
                        credentials.missing_grok_credential_message
                    else
                        credentials.missing_credential_message,
                });
            }
            break :routed &routed_credential.?;
        };
        if (credential.token.len == 0 and credential.source != .configured) {
            return state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_request,
                .message = if (state.provider == .codex)
                    credentials.missing_chatgpt_credential_message
                else if (state.provider == .grok)
                    credentials.missing_grok_credential_message
                else
                    credentials.missing_credential_message,
            });
        }
        adoptServerCredential(state, credential);
    }

    state.permission_mode = startup.permission_mode;
    state.permission_rules = startup.takePermissionRules();
    state.agent_step_limit = startup.agent_step_limit;
    state.max_tool_result_bytes = startup.max_tool_result_bytes;
    state.auto_compact_percent = startup.auto_compact_percent;
    state.context_limits = startup.context_limits;
    state.context_limits.applyCommandLine(state.host.cfg.context_limit_overrides);
    state.toolbox_behind = config_runtime.tool_placement.behindToolbox(startup.tool_placement, state.host.cfg.tool_placement_overrides);
    state.fast_mode = startup.fast_mode and
        (state.host.cfg.model_override == null or startup.fast_mode_source != .compiled_default);
    configureUltrafastStartup(state, &startup);
    if (comptime !host_target.is_wasm) {
        if (!state.host.cfg.minimal_kernel) startTokenPassCheck(state, alloc, startup.model_source);
    }
    state.effort = startup.effort;
    state.first_call_tool_choice = startup.first_call_tool_choice;
    state.context_enabled = startup.context_enabled;
    state.session_titles = startup.session_title_generation;
    state.cache_warming = startup.cache_warming;
    state.workspace_capture = startup.workspace_capture;

    if (comptime !host_target.is_wasm) {
        if (!state.host.cfg.minimal_kernel) {
            var loaded_skills = try app_runtime_setup.loadSkills(alloc, state.launch.root, builtin_skills.root_policy);
            errdefer loaded_skills.deinit(alloc);
            skill_runtime.traceDiagnostics("acp_startup", loaded_skills.diagnostics);
            try state.launch.skills.replaceLoaded(alloc, loaded_skills.dir, loaded_skills.skills, loaded_skills.diagnostics);
            loaded_skills = .{};
        }
    }

    if (!state.host.cfg.minimal_kernel) {
        const startup_catalog = catalogProviderFor(state.host, state.provider) orelse
            return state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_request,
                .message = "Selected provider is unavailable in this host",
            });
        _ = try resolveSelectedModelCapabilities(state, startup_catalog);
        // The catalog just loaded; its Token Pass marks can answer for the
        // team when the credits check could not.
        if (comptime !host_target.is_wasm) pollTokenPass(state);
    }

    if (state.host.cfg.effort_override) |raw| {
        const effort = types.ReasoningEffort.parse(raw) orelse
            return state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_params,
                .message = "Invalid reasoning effort",
            });
        if (!try applyEffortOverride(state, alloc, msg, effort)) return;
    }

    if (state.host.cfg.fast_override) |fast| {
        if (!try applyFastOverride(state, alloc, msg, fast)) return;
    }
    if (!try applyUltrafastOverride(state, alloc, msg, state.ultrafast_mode)) return;

    state.terminal_ui = request.terminal_ui;
    state.client_fs_read = request.client_fs_read;
    state.client_fs_write = request.client_fs_write;
    state.client_terminal = request.client_terminal;
    state.client_notices = request.client_notices;
    state.client_compaction = request.client_compaction;
    state.client_elicitation = request.client_elicitation;
    state.host_tools.deinit();
    state.host_tools = request.host_tools;
    request.host_tools = .{};
    const agent_extensions = agentExtensions(state.host.cfg.minimal_kernel);
    state.extensions = agent_extensions.intersectWith(request.client_extensions);
    debug_trace.logf("acp", "initialize host_tools={d} extensions={d}", .{
        state.host_tools.tools.len,
        state.extensions.count(),
    });
    state.initialized = true;
    return writeInitializeAnswer(state, alloc, msg.id);
}

/// Writes the `initialize` answer. A socket connection adds `leader`: this
/// process's pid and the sessions it leads, copied now so the list is current. If
/// they cannot be copied, the answer is an error, not a list that may be wrong.
fn writeInitializeAnswer(state: *ServerState, alloc: Allocator, id: ?jsonrpc.RequestId) !void {
    var capabilities = agentCapabilities(state);
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    // Only a socket connection has leader info, and a socket exists only where `follow_supported` holds.
    if (comptime follow_supported) {
        if (state.leader_info) |info| {
            const ids = info.sessions.copy_ids(info.sessions.context, arena.allocator()) catch {
                debug_trace.logf("acp", "event=leader_sessions_unlisted", .{});
                return state.writer.writeError(alloc, id, .{
                    .code = ErrorCode.internal_error,
                    .message = "Could not list the sessions this process leads",
                });
            };
            const view = try arena.allocator().alloc([]const u8, ids.len);
            for (ids, view) |listed, *slot| slot.* = listed;
            capabilities.leader = .{ .pid = info.pid, .sessions = view };
        }
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try acp_types.writeInitializeResponse(&out.writer, capabilities);
    try state.writer.writeResponse(alloc, id, out.writer.buffered());
}

/// The capabilities fx answers `initialize` with. A socket connection's answer
/// adds `leader` (see `writeInitializeAnswer`), and the rest is this same value,
/// so the two always agree. It reads only `cfg`, never the client's request.
fn agentCapabilities(state: *ServerState) acp_types.AgentCapabilities {
    return .{
        .image_prompts = !host_target.is_wasm,
        .mcp_servers = state.host.cfg.allow_acp_mcp,
        .extensions = agentExtensions(state.host.cfg.minimal_kernel),
        .session_delete = host_target.is_wasm,
        .system_prompt = !host_target.is_wasm and !state.host.cfg.minimal_kernel,
        // fx takes only what ACP v1 defines and fx's MCP engine speaks: stdio and
        // HTTP.
        .mcp_over_acp = false,
        .mcp_sse = false,
    };
}

/// The extensions fx lists at `initialize`. `fx acp` steers through
/// `session/prompt`; libfx's kernel serves its host's steering, journal, and
/// tools. Every build sends hooks, tool call identities, permission modes,
/// model recovery, and turn events to a client that lists them.
fn agentExtensions(minimal_kernel: bool) sh_fx.Set {
    var set: sh_fx.Set = .initMany(&.{ .hooks, .tool_call, .permission_mode, .model_response_recovery, .turn_progress, .model_calls, .usage, .command_result, .keep_turn_on_disconnect });
    if (minimal_kernel) {
        set.setUnion(.initMany(&.{ .host_steering, .journal, .host_tools }));
    } else if (!host_target.is_wasm) {
        set.insert(.prompt_delivery);
    }
    return set;
}

/// The selected model's capabilities from `provider`'s catalog, loading it
/// first if needed. A first load whose request cannot connect gives up after
/// `gateway_provider.catalog_connect_wait_ms`, as `fx ask`'s does, so a
/// dead network doesn't hold up the reply for the 20 to 30 seconds its DNS
/// lookup or connect takes to fail (`CapabilityResolver.resolveWithin`).
fn resolveSelectedModelCapabilities(
    state: *ServerState,
    provider: model_catalog.Provider,
) model_capabilities.ResolveError!model_capabilities.Capabilities {
    var cancel_flag = std.atomic.Value(bool).init(false);
    return state.host.capability_resolver.resolveWithin(
        state.alloc,
        provider,
        .{
            .access = if (state.host.cfg.auth_mode == .host_managed)
                .host_managed
            else
                credentials.catalogAccessForCredentialAndAccount(
                    state.credential_source,
                    state.api_key,
                    state.gateway_team,
                    state.account_id,
                ),
            .endpoint = state.host.cfg.gateway_models_path,
            .cancel_flag = &cancel_flag,
        },
        state.selected_model,
        state.host.cfg.provider_set.select(state.provider).fallbackModelCapabilities(state.selected_model),
        gateway_provider.catalog_connect_wait_ms,
    );
}

/// Applies a host-supplied reasoning effort override to sessions created after
/// initialize. A non-default effort must be one of the selected model's
/// advertised efforts whenever the catalog resolves; a catalog outage leaves
/// the override in place, matching turn-time capability fallback. Returns
/// false after writing the rejection response.
fn applyEffortOverride(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message, effort: types.ReasoningEffort) !bool {
    state.effort = effort;
    if (effort.isDefault()) return true;

    const bundle = state.host.cfg.provider_set.select(state.provider);
    const fallback = bundle.fallbackModelCapabilities(state.selected_model);
    var capabilities: model_capabilities.Capabilities = undefined;
    if (state.host.cfg.minimal_kernel and state.host.capability_resolver.state == .idle) {
        // libfx cores skip the startup catalog resolve; explicit effort and
        // fast overrides are the creation-time consumers that need it.
        const catalog_provider = catalogProviderFor(state.host, state.provider) orelse return true;
        capabilities = try resolveSelectedModelCapabilities(state, catalog_provider);
    } else {
        capabilities = state.host.capability_resolver.available(state.selected_model, fallback);
    }
    // A failed catalog lookup cannot name the supported set; the turn-time
    // capability check remains the backstop.
    if (state.host.capability_resolver.state == .failed) return true;

    const rejection = effortOverrideRejection(alloc, capabilities, effort, state.selected_model) catch {
        try state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Failed to validate reasoning effort",
        });
        return false;
    };
    if (rejection) |message| {
        defer alloc.free(message);
        try state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = message,
            .data = .{ .model_capability = .{
                .code = "MODEL_UNSUPPORTED_EFFORT",
                .model = state.selected_model,
                .capability = "effort",
            } },
        });
        return false;
    }
    return true;
}

/// Pure decision for a host-supplied effort override: returns an owned
/// rejection message naming the model's advertised efforts, or null when the
/// effort is usable. Caller frees the returned slice.
fn effortOverrideRejection(
    alloc: Allocator,
    capabilities: model_capabilities.Capabilities,
    effort: types.ReasoningEffort,
    model: []const u8,
) Allocator.Error!?[]u8 {
    if (model_capabilities.reasoningEffortSupported(capabilities, effort)) return null;
    if (capabilities.reasoning_efforts.len == 0) {
        return try alloc.dupe(u8, "Reasoning effort is unavailable for the active model");
    }
    var set: std.ArrayList(u8) = .empty;
    defer set.deinit(alloc);
    for (capabilities.reasoning_efforts.slice(), 0..) |option, index| {
        if (index > 0) try set.appendSlice(alloc, ", ");
        try set.appendSlice(alloc, option.label());
    }
    return try alloc.print(
        "Reasoning effort \"{s}\" is not available for model \"{s}\" (available: {s})",
        .{ effort.label(), model, set.items },
    );
}

test "effortOverrideRejection accepts default and advertised efforts" {
    const alloc = std.testing.allocator;
    const capabilities = model_capabilities.Capabilities{
        .reasoning_efforts = .fromSlice(&.{
            types.ReasoningEffort.literal("low"),
            types.ReasoningEffort.literal("high"),
        }),
    };
    try std.testing.expectEqual(@as(?[]u8, null), try effortOverrideRejection(alloc, capabilities, .auto, "provider/model"));
    try std.testing.expectEqual(@as(?[]u8, null), try effortOverrideRejection(alloc, capabilities, .literal("high"), "provider/model"));
}

test "effortOverrideRejection names the advertised set" {
    const alloc = std.testing.allocator;
    const capabilities = model_capabilities.Capabilities{
        .reasoning_efforts = .fromSlice(&.{
            types.ReasoningEffort.literal("low"),
            types.ReasoningEffort.literal("high"),
        }),
    };
    const rejection = (try effortOverrideRejection(alloc, capabilities, .literal("max"), "provider/model")).?;
    defer alloc.free(rejection);
    try std.testing.expect(std.mem.find(u8, rejection, "\"max\"") != null);
    try std.testing.expect(std.mem.find(u8, rejection, "provider/model") != null);
    try std.testing.expect(std.mem.find(u8, rejection, "low, high") != null);
}

test "effortOverrideRejection reports models without advertised efforts" {
    const alloc = std.testing.allocator;
    const rejection = (try effortOverrideRejection(alloc, .{}, .literal("high"), "provider/plain")).?;
    defer alloc.free(rejection);
    try std.testing.expectEqualStrings("Reasoning effort is unavailable for the active model", rejection);
}

/// Applies a host-supplied fast-lane override to sessions created after
/// initialize. Enabling fast mode requires the selected model to offer a fast
/// path whenever the catalog resolves; a catalog outage leaves the override in
/// place, matching turn-time capability fallback. Disabling is always
/// accepted. Returns false after writing the rejection response.
fn applyFastOverride(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message, fast: bool) !bool {
    state.fast_mode = fast;
    if (!fast) return true;

    const bundle = state.host.cfg.provider_set.select(state.provider);
    const fallback = bundle.fallbackModelCapabilities(state.selected_model);
    var capabilities: model_capabilities.Capabilities = undefined;
    if (state.host.cfg.minimal_kernel and state.host.capability_resolver.state == .idle) {
        // Shares the effort override's one-shot catalog resolve: creation is
        // the only point that can reject before any turn runs.
        const catalog_provider = catalogProviderFor(state.host, state.provider) orelse return true;
        capabilities = try resolveSelectedModelCapabilities(state, catalog_provider);
    } else {
        capabilities = state.host.capability_resolver.available(state.selected_model, fallback);
    }
    // A failed catalog lookup cannot confirm a fast path; the turn-time
    // capability gate remains the backstop.
    if (state.host.capability_resolver.state == .failed) return true;

    const rejection = fastOverrideRejection(alloc, capabilities, state.selected_model) catch {
        try state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Failed to validate fast mode",
        });
        return false;
    };
    if (rejection) |message| {
        defer alloc.free(message);
        try state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = message,
            .data = .{ .model_capability = .{
                .code = "MODEL_UNSUPPORTED_FAST",
                .model = state.selected_model,
                .capability = "fast",
            } },
        });
        return false;
    }
    return true;
}

/// Pure decision for a host-supplied fast override: returns an owned rejection
/// message naming the model, or null when the model offers a fast path. An
/// intrinsically fast model already satisfies the request. Caller frees the
/// returned slice.
fn fastOverrideRejection(
    alloc: Allocator,
    capabilities: model_capabilities.Capabilities,
    model: []const u8,
) Allocator.Error!?[]u8 {
    if (capabilities.supports_fast_mode or capabilities.intrinsic_fast) return null;
    return try alloc.print("Fast mode is not available for model \"{s}\"", .{model});
}

test "fastOverrideRejection accepts models with a fast path" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(@as(?[]u8, null), try fastOverrideRejection(alloc, .{ .supports_fast_mode = true }, "provider/model"));
    try std.testing.expectEqual(@as(?[]u8, null), try fastOverrideRejection(alloc, .{ .intrinsic_fast = true }, "provider/model-fast"));
}

test "fastOverrideRejection names models without a fast path" {
    const alloc = std.testing.allocator;
    const rejection = (try fastOverrideRejection(alloc, .{}, "provider/plain")).?;
    defer alloc.free(rejection);
    try std.testing.expectEqualStrings("Fast mode is not available for model \"provider/plain\"", rejection);
}

/// Applies a host-supplied ultrafast override before session creation. Unlike
/// fast mode, enabling it requires a verified Gateway catalog capability; a
/// catalog failure cannot silently send an unverified ultrafast request.
fn applyUltrafastOverride(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message, ultrafast: bool) !bool {
    if (!ultrafast) {
        state.ultrafast_mode = false;
        return true;
    }
    if (state.provider != .gateway) {
        return writeUltrafastOverrideFailure(state, alloc, msg, "Ultrafast mode is unavailable for the selected provider");
    }
    const catalog_provider = catalogProviderFor(state.host, state.provider) orelse
        return writeUltrafastOverrideFailure(state, alloc, msg, "Ultrafast mode is unavailable for the selected provider");
    const capabilities = try resolveSelectedModelCapabilities(state, catalog_provider);
    if (state.host.capability_resolver.state == .failed) {
        return writeUltrafastOverrideFailure(state, alloc, msg, "Ultrafast mode requires a verified Gateway model catalog");
    }
    const rejection = try ultrafastOverrideRejection(alloc, state.provider, capabilities, state.selected_model);
    if (rejection) |message| {
        defer alloc.free(message);
        return writeUltrafastOverrideFailure(state, alloc, msg, message);
    }
    state.ultrafast_mode = true;
    return true;
}

fn writeUltrafastOverrideFailure(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message, message: []const u8) !bool {
    try state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = message,
        .data = .{ .model_capability = .{
            .code = "MODEL_UNSUPPORTED_ULTRAFAST",
            .model = state.selected_model,
            .capability = "ultrafast",
        } },
    });
    return false;
}

/// Pure capability policy: ultrafast is an opt-in Gateway OpenAI catalog lane.
/// Caller frees a non-null rejection message.
fn ultrafastOverrideRejection(
    alloc: Allocator,
    provider: model_provider.ProviderId,
    capabilities: model_capabilities.Capabilities,
    model: []const u8,
) Allocator.Error!?[]u8 {
    if (provider == .gateway and capabilities.supports_ultrafast_mode) return null;
    return try alloc.print("Ultrafast mode is not available for model \"{s}\"", .{model});
}

test "ultrafastOverrideRejection accepts only Gateway models with the catalog capability" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(@as(?[]u8, null), try ultrafastOverrideRejection(alloc, .gateway, .{ .supports_ultrafast_mode = true }, "openai/model"));
    const rejection = (try ultrafastOverrideRejection(alloc, .codex, .{ .supports_ultrafast_mode = true }, "openai/model")).?;
    defer alloc.free(rejection);
    try std.testing.expect(std.mem.find(u8, rejection, "openai/model") != null);
    const unavailable = (try ultrafastOverrideRejection(alloc, .gateway, .{}, "openai/model")).?;
    defer alloc.free(unavailable);
}

test "ACP answers an ultrafast override without waiting out a model catalog that cannot connect" {
    var test_host = testHost(std.testing.allocator);
    defer test_host.deinit();
    // A Gateway catalog on a dead network: its request never connects, and
    // it fails only when cancelled or once a stalled DNS lookup would give up.
    const UnconnectableCatalog = struct {
        give_up_ms: i64 = 6_000,

        fn fetch(raw: ?*anyopaque, _: Allocator, input: model_catalog.FetchInput) Allocator.Error!model_catalog.ProviderResult {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const started_ms = model_catalog.clockMs();
            while (model_catalog.clockMs() - started_ms < self.give_up_ms) {
                if (input.cancel_flag) |flag| if (flag.load(.seq_cst)) {
                    return .{ .failure = .{ .category = .cancellation } };
                };
                io_mod.sleep(std.time.ns_per_ms);
            }
            return .{ .failure = .{ .category = .transport } };
        }
    };
    const Capture = struct {
        saw_catalog_failure: bool = false,

        fn write(raw: ?*anyopaque, frame: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (std.mem.find(u8, frame, "requires a verified Gateway model catalog") != null) {
                self.saw_catalog_failure = true;
            }
        }
    };
    var catalog = UnconnectableCatalog{};
    var capture = Capture{};
    var model = "openai/gpt-5.5".*;
    var state = ServerState{
        .alloc = std.testing.allocator,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&capture, Capture.write),
        .selected_model = &model,
    };
    state.host.cfg.auth_mode = .host_managed;
    state.host.cfg.gateway_models_path = "/v1/models";
    state.host.cfg.provider_set = @import("../core/gateway/provider_set.zig").gateway_only(.{
        .model_catalog = .{ .context = &catalog, .fetch_fn = UnconnectableCatalog.fetch, .reports_connection = true },
    });
    var msg = jsonrpc.Message{ .id = .{ .integer = 1 }, .method = "initialize" };

    const started_ms = model_catalog.clockMs();
    try std.testing.expect(!try applyUltrafastOverride(&state, std.testing.allocator, &msg, true));
    const elapsed_ms = model_catalog.clockMs() - started_ms;

    // The override fails as on any catalog outage, after the first load's wait
    // rather than after the lookup gives up.
    try std.testing.expect(elapsed_ms < 5_000);
    try std.testing.expect(capture.saw_catalog_failure);
    try std.testing.expect(!state.ultrafast_mode);
}

test "ACP keeps its model catalog when a due refresh cannot connect" {
    var test_host = testHost(std.testing.allocator);
    defer test_host.deinit();
    // A Gateway catalog that answers, then goes behind a dead network: its
    // request never connects, and it fails only when cancelled or once a
    // stalled DNS lookup would give up.
    const RefreshingCatalog = struct {
        answers: std.atomic.Value(bool) = .init(true),
        give_up_ms: i64 = 6_000,

        fn fetch(raw: ?*anyopaque, alloc: Allocator, input: model_catalog.FetchInput) Allocator.Error!model_catalog.ProviderResult {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (self.answers.load(.seq_cst)) {
                if (input.connected) |connected| connected.store(true, .release);
                var entries: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
                errdefer model_catalog.freeModelCatalog(alloc, &entries);
                const id = try alloc.dupe(u8, "openai/gpt-5.5");
                errdefer alloc.free(id);
                const model_type = try alloc.dupe(u8, "language");
                errdefer alloc.free(model_type);
                try entries.append(alloc, .{ .id = id, .model_type = model_type });
                return .{ .catalog = entries };
            }
            const started_ms = model_catalog.clockMs();
            while (model_catalog.clockMs() - started_ms < self.give_up_ms) {
                if (input.cancel_flag) |flag| if (flag.load(.seq_cst)) {
                    return .{ .failure = .{ .category = .cancellation } };
                };
                io_mod.sleep(std.time.ns_per_ms);
            }
            return .{ .failure = .{ .category = .transport } };
        }
    };
    var catalog = RefreshingCatalog{};
    var model = "openai/gpt-5.5".*;
    var state = ServerState{
        .alloc = std.testing.allocator,
        .host = &test_host,
        .writer = jsonrpc.Writer.init(),
        .selected_model = &model,
    };
    state.host.cfg.minimal_kernel = false;
    state.host.cfg.auth_mode = .host_managed;
    state.host.cfg.gateway_models_path = "/v1/models";
    state.host.cfg.provider_set = @import("../core/gateway/provider_set.zig").gateway_only(.{
        .model_catalog = .{
            .context = &catalog,
            .fetch_fn = RefreshingCatalog.fetch,
            .reports_connection = true,
            .refresh_interval_ms = 60_000,
        },
    });
    var active: ActiveSessionState = undefined;
    active.client_writer = jsonrpc.Writer.initCallback(&active, forwardToMain);
    active.provider = .gateway;
    active.subagent_host = null;

    try refreshModelCatalogForOptions(&state, &active);
    try std.testing.expectEqual(@as(usize, 1), state.host.capability_resolver.catalogEntries().?.len);

    // The refresh interval passes while the network is down.
    state.host.capability_resolver.last_attempt_ms -= 60_000;
    catalog.answers.store(false, .seq_cst);
    const started_ms = model_catalog.clockMs();
    try refreshModelCatalogForOptions(&state, &active);
    const elapsed_ms = model_catalog.clockMs() - started_ms;

    // The refresh fails as on any catalog outage, after the wait for its
    // connection rather than after the lookup gives up, and the models the
    // catalog already listed stay in use.
    try std.testing.expect(elapsed_ms < 5_000);
    try std.testing.expectEqualStrings("openai/gpt-5.5", state.host.capability_resolver.catalogEntries().?[0].id);
}

/// Stops `session`'s running turn only, and what it waits for from the
/// client. It keeps its queued steering until it ends, which hands the steers
/// it never took to the next turn, or a libfx turn's inputs back to its host.
/// Queued prompts still run after it. Held under the waiting prompts' mutex,
/// so a stop never lands on the turn the worker starts next. Every other
/// session's turn runs on (`tests/tla/acp/AcpSessions.tla` OthersUntouched).
fn handleCancel(session: *ActiveSessionState, notify_client: bool) void {
    debug_trace.eventf("interrupt", "cancel_requested", .{}, "source=acp active_tool_known=false", .{});
    session.waiting_prompts.lock();
    // The flag is set under the line lock, together with the cancel. A claim
    // takes the same lock, so this cancel either lands before the claim, which
    // then clears the flag, or after it, which stops that turn. If the flag were
    // set before the lock, a claim could run in between and the cancel would
    // stop the next turn.
    session.turn_cancel.store(true, .seq_cst);
    session.steering.cancelForUser(&session.cancel_flag);
    session.waiting_prompts.unlock();
    // A prompt waiting for its subagents' reports stops waiting.
    session.worker.nudgeWaiter();
    cancelSessionPending(session, notify_client);
    clearPendingLegacyUrls(session);
}

/// The first steps of a close (AcpSessionReaders BeginClose, CloseDetach and
/// CloseWait). The session starts closing, leaves the shared table so that no
/// connection can take a use of it, and waits until the uses that other connections
/// hold end. Callers run it before they stop the turn, so no request starts work on
/// the session in between. A second call finds nothing left to do.
fn startClose(state: *ServerState, session: *ActiveSessionState) void {
    beginClose(session);
    if (comptime follow_supported) {
        {
            const shared = &state.host.shared;
            shared.unregister(session);
            prompt_test_controls.noteCloseBeforeUseWait();
            shared.waitNoUses(session);
            prompt_test_controls.noteCloseAfterUseWait();
        }
    }
}

/// Begins a close (AcpSessionReaders BeginClose), under the line lock. From here
/// no prompt starts a turn, and a claim that waits for a join wakes and is
/// refused. `startClose` calls it first.
fn beginClose(session: *ActiveSessionState) void {
    session.waiting_prompts.lock();
    defer session.waiting_prompts.unlock();
    session.waiting_prompts.closing = true;
    session.waiting_prompts.wakeWaitersLocked();
}

/// Stops the running turn and waits for it, answering every steer and queued
/// prompt that hasn't run with `-32800`, as `session/close` does. The caller has
/// begun the close (`startClose`), so the line takes nothing new while this runs.
pub fn cancelAndReapPrompt(state: *ServerState, session: *ActiveSessionState) void {
    {
        var drained = drained: {
            session.waiting_prompts.lock();
            defer session.waiting_prompts.unlock();
            break :drained session.waiting_prompts.drainLocked();
        };
        defer drained.deinit(state.alloc);
        for (drained.late.items) |steer| answerCancelled(state.host, session, steer.from, steer.request_id);
        for (drained.queue.items) |queued| if (queued.msg.id) |id| answerCancelled(state.host, session, queued.from, id);
    }
    // AcpSessionReaders CloseCancel: the cancel stops the turn under the line lock.
    handleCancel(session, true);
    // AcpSessionReaders CloseTakeSlot, CloseJoin and CloseFreeT: the reap takes the
    // turn, joins it, and frees it.
    reapSessionPrompt(session, true);
}

/// Answers a prompt that never ran with `-32800`, to the connection that sent it.
fn answerCancelled(host: *Host, session: *ActiveSessionState, from: ConnectionId, id: jsonrpc.RequestId) void {
    const answer: Answer = .{ .rpc_error = .{
        .code = ErrorCode.request_cancelled,
        .message = "Request cancelled",
    } };
    answerSender(session, host.alloc, from, id, .none, answer, answer) catch |err| debug_trace.logf("acp", "failed to answer a prompt that never ran err={s}", .{@errorName(err)});
}

/// The answer to a client's prompt or steer: a response, or an error.
const Answer = union(enum) {
    response: []const u8,
    rpc_error: jsonrpc.RpcError,
};

/// Input a turn never ran: the queued prompt or the steers that waited when the next
/// turn failed to start, and the error that stopped it.
const DroppedWaiting = struct {
    input: prompt_line.Next,
    err: anyerror,
};

/// Writes `answer` to the connection that sent request `id`: the owner, `sessionMain(session)`,
/// or the follower in `session.followers` with that connection id. A member that takes
/// `need` gets `with`, the others get `without`. Without `follow_supported` there is one
/// connection, the owner, and the caller built the owner's body, which both `with` and
/// `without` hold: it goes straight to the owner's writer, and its error is returned.
/// Otherwise the audience lock keeps the members still during the write. An error writing
/// to a follower drops that follower, as `Audience.dropFollower` does, and is traced; the
/// answer is lost and the turn goes on. An error writing to the owner is returned. A
/// follower whose writer has stopped is dropped after its write, as `Audience.writeNotification`
/// drops it, because its answer is lost too. When no member has the sender's id, the sender
/// has left: nothing is written, and the drop is traced.
fn answerSender(
    session: *ActiveSessionState,
    alloc: Allocator,
    from: ConnectionId,
    id: ?jsonrpc.RequestId,
    need: RunningCopy.Need,
    with: Answer,
    without: Answer,
) !void {
    // Without `follow_supported` the owner is the only member, and the caller built its
    // body into both `with` and `without`, so either one is the owner's.
    if (comptime !follow_supported) {
        const main = holdMain(session);
        defer main.drop();
        return writeAnswer(main.writer, alloc, id, if (memberTakes(main, need)) with else without);
    }
    var audience = lockAudience(session);
    defer audience.unlock();
    if (sameConnection(mainLocked(session).?.connection_id, from)) {
        return writeAnswer(mainLocked(session).?.writer, alloc, id, if (memberTakes(mainLocked(session).?, need)) with else without);
    }
    for (session.members.items) |member| {
        if (!sameConnection(member.connection_id, from)) continue;
        writeAnswer(member.writer, alloc, id, if (memberTakes(member, need)) with else without) catch |err| {
            traceDroppedAnswer(session, id, "write_failed", err);
            audience.dropMember(member, "session/prompt", .{ .write_failed = err });
            return;
        };
        if (Audience.memberStopped(member)) {
            traceDroppedAnswer(session, id, "client_gone", null);
            audience.dropMember(member, "session/prompt", .client_gone);
        }
        return;
    }
    traceDroppedAnswer(session, id, "sender_left", null);
}

fn writeAnswer(writer: *jsonrpc.Writer, alloc: Allocator, id: ?jsonrpc.RequestId, answer: Answer) !void {
    switch (answer) {
        .response => |body| try writer.writeResponse(alloc, id, body),
        .rpc_error => |rpc_error| try writer.writeError(alloc, id, rpc_error),
    }
}

/// Answers the input a turn never ran, when the next turn failed to start: each queued
/// prompt and steer goes to the connection that sent it, with `-32603` and the error
/// name, the code a failed turn answers with. The caller frees `dropped`.
fn answerDroppedWaiting(session: *ActiveSessionState, alloc: Allocator, dropped: *const DroppedWaiting) void {
    switch (dropped.input) {
        .steers => |steers| {
            for (steers.items) |steer| answerWaitingInput(session, alloc, steer.from, steer.request_id, dropped.err);
        },
        .prompt => |queued| answerWaitingInput(session, alloc, queued.from, queued.msg.id, dropped.err),
    }
}

fn answerWaitingInput(session: *ActiveSessionState, alloc: Allocator, from: ConnectionId, id: ?jsonrpc.RequestId, err: anyerror) void {
    var buf: [32]u8 = undefined;
    debug_trace.logf("acp", "event=waiting_input_dropped session={s} request={s} reason={s}", .{ session.session_id, requestText(id, &buf), @errorName(err) });
    const answer: Answer = .{ .rpc_error = .{ .code = ErrorCode.internal_error, .message = @errorName(err) } };
    answerSender(session, alloc, from, id, .none, answer, answer) catch |write_err|
        debug_trace.logf("acp", "failed to answer waiting input err={s}", .{@errorName(write_err)});
}

/// A request id as a trace shows it: its number or text, `none` without one. `buf` holds a number.
fn requestText(id: ?jsonrpc.RequestId, buf: []u8) []const u8 {
    const request = id orelse return "none";
    return switch (request) {
        .integer => |value| std.mem.print(buf, "{d}", .{value}) catch "?",
        .string => |text| text,
        .null => "none",
    };
}

/// Traces an answer that was not written. `reason` says why; `err` is the write error, if any.
fn traceDroppedAnswer(session: *const ActiveSessionState, id: ?jsonrpc.RequestId, reason: []const u8, err: ?anyerror) void {
    var buf: [32]u8 = undefined;
    if (err) |value| {
        debug_trace.logf("acp", "event=answer_dropped session={s} request={s} reason={s} err={s}", .{ session.session_id, requestText(id, &buf), reason, @errorName(value) });
        return;
    }
    debug_trace.logf("acp", "event=answer_dropped session={s} request={s} reason={s}", .{ session.session_id, requestText(id, &buf), reason });
}

/// Handles `session/close`. Closing an open session stops its turn and closes it, and closing a
/// session that isn't open succeeds with `{}` and changes nothing (`tests/tla/acp/AcpSessionTarget.tla`
/// CloseClosesOpen and CloseIdempotent, `tests/tla/acp/AcpSessions.tla` OthersUntouched).
pub fn handleCloseSession(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    const params = msg.params_raw orelse return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Missing params",
    });
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, params, .{}) catch
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Invalid params",
        });
    defer parsed.deinit();
    const requested_id = if (parsed.value == .object)
        if (parsed.value.object.get("sessionId")) |value|
            if (value == .string and value.string.len > 0) value.string else null
        else
            null
    else
        null;
    const session_id = requested_id orelse
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Missing sessionId",
        });
    // A session this connection follows is detached, not closed: its owner keeps it open.
    if (comptime follow_supported) {
        if (followsSession(state, session_id)) {
            detachFollower(state, session_id, .closed);
            return state.writer.writeResponse(alloc, msg.id, "{}");
        }
    }
    // Closing is idempotent in ACP v1: a session that isn't open, or doesn't exist, closes with the
    // same empty result, and every open session stays open.
    const session = findSession(state, session_id) orelse return state.writer.writeResponse(alloc, msg.id, "{}");
    // The main client closes a session a follower still has open. The follower becomes its
    // main, and the session, its turn and the follower's input stay open (the leave rule).
    if (leaveMember(state, session, .closed)) {
        removeMembershipForSession(state, session);
        return state.writer.writeResponse(alloc, msg.id, "{}");
    }
    startClose(state, session);
    cancelAndReapPrompt(state, session);
    stopSubagentsForSwitch(session);
    closeSession(state, session);
    try state.writer.writeResponse(alloc, msg.id, "{}");
}

/// Handles `session/set_config_option`. The `mode` option is modeled in
/// `tests/tla/acp/AcpPermissionModes.tla`, and `fast` and `ultrafast` in
/// `tests/tla/acp/AcpSpeed.tla`.
fn handleSetConfigOption(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    const params = msg.params_raw orelse return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Missing params",
    });

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, params, .{}) catch
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Invalid params" });
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Params must be object" });
    const target_session = (try requireParsedSessionTarget(state, alloc, msg.id, root)) orelse return;
    const own_member = ownMember(state, target_session);
    // Held for every branch and the response, so a turn that publishes a
    // renewed credential sees the settings either before or after this change.
    target_session.settings_mutex.lockUncancelable(io_mod.getIo());
    defer target_session.settings_mutex.unlock(io_mod.getIo());

    const config_id = blk: {
        if (root.object.get("configId")) |v| {
            if (v == .string) break :blk v.string;
        }
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Missing configId" });
    };

    const value = blk: {
        if (root.object.get("value")) |v| {
            if (v == .string) break :blk v.string;
        }
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Missing value" });
    };

    if (std.mem.eql(u8, config_id, "model")) {
        const session = target_session;
        session_codec.validateModelPreference(value) catch
            return state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_params,
                .message = "Invalid session model",
            });
        if (comptime !host_target.is_wasm) {
            const main = holdMain(session);
            defer main.drop();
            if (session.provider != .gateway) {
                if (session.provider != .configured) {
                    const model_available = available: {
                        lockCatalog(state.host);
                        defer unlockCatalog(state.host);
                        try refreshModelCatalogForOptionsLocked(state, session);
                        const entries = state.host.capability_resolver.catalogEntries() orelse break :available false;
                        for (entries) |entry| {
                            if (std.mem.eql(u8, entry.id, value)) break :available true;
                        }
                        break :available false;
                    };
                    if (!model_available) {
                        return state.writer.writeError(alloc, msg.id, .{
                            .code = ErrorCode.invalid_params,
                            .message = "Model is not available for the active provider",
                        });
                    }
                }
                if (!try selectCredentialForSession(main, session)) {
                    return state.writer.writeError(alloc, msg.id, .{
                        .code = ErrorCode.invalid_request,
                        .message = if (session.provider == .codex)
                            credentials.missing_chatgpt_credential_message
                        else if (session.provider == .grok)
                            credentials.missing_grok_credential_message
                        else
                            "Configured provider authentication is unavailable",
                    });
                }
            }
        }
        // A subagent's turn reads the session's model route under this lock, from its own copy.
        state.host.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
        defer state.host.subagent_authority_mutex.unlock(io_mod.getIo());
        if (host_target.is_wasm) {
            const next_model = alloc.dupe(u8, value) catch
                return state.writer.writeError(alloc, msg.id, .{
                    .code = ErrorCode.internal_error,
                    .message = "Failed to update session model",
                });
            const previous_model = session.model;
            session.model = next_model;
            sessions.commitWasmSession(alloc, session) catch {
                session.model = previous_model;
                alloc.free(next_model);
                return state.writer.writeError(alloc, msg.id, .{
                    .code = ErrorCode.internal_error,
                    .message = "Failed to persist session model",
                });
            };
            alloc.free(previous_model);
        } else commitActiveSessionModel(
            alloc,
            session,
            value,
        ) catch |err| {
            return state.writer.writeError(alloc, msg.id, .{
                .code = if (err == error.InvalidDurableField)
                    ErrorCode.invalid_params
                else
                    ErrorCode.internal_error,
                .message = if (err == error.InvalidDurableField)
                    "Invalid session model"
                else
                    "Failed to persist session model",
            });
        };
        pointWebSearchAtSession(session);
        if (!try dropUnsupportedSpeeds(state, alloc, msg, session)) return;
    } else if (std.mem.eql(u8, config_id, "provider")) {
        const parsed_provider = model_provider.parse(value) orelse
            return state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_params,
                .message = "Invalid provider",
            });
        const target = parsed_provider.bind(state.configured_providers) catch
            return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Unknown or changed configured provider" });
        const session = target_session;
        if (!target.eql(session.provider)) {
            if (host_target.is_wasm and !hostManagesRoute(state.host.cfg, target)) {
                return state.writer.writeError(alloc, msg.id, .{
                    .code = ErrorCode.invalid_request,
                    .message = "Subscription provider switching is unavailable in this WASM runtime",
                });
            }
            var staged_credential: ?credentials.Credential = if (state.host.cfg.auth_mode == .host_managed)
                null
            else if (hostManagesRoute(state.host.cfg, target))
                hostManagedCredential()
            else if (target == .gateway and state.host.cfg.credential_override != null)
                credentials.Credential{
                    .token = try alloc.dupe(u8, state.host.cfg.credential_override.?),
                    .source = .ai_gateway_api_key,
                }
            else credential: {
                break :credential (try auth_runtime.prepareCredential(
                    alloc,
                    state.host.cfg.gateway_provider.oauth_transport,
                    state.host.cfg.secret_store,
                    target,
                    if (target == .gateway) own_member.gateway_source_preference else null,
                )) orelse
                    return state.writer.writeError(alloc, msg.id, .{
                        .code = ErrorCode.invalid_request,
                        .message = if (target == .codex)
                            credentials.missing_chatgpt_credential_message
                        else if (target == .grok)
                            credentials.missing_grok_credential_message
                        else
                            credentials.missing_credential_message,
                    });
            };
            defer if (staged_credential) |*credential| credential.deinit(alloc);
            if (staged_credential) |credential| if (!model_provider.authorizesCredential(target, credential.source)) {
                return state.writer.writeError(alloc, msg.id, .{
                    .code = ErrorCode.invalid_request,
                    .message = "Credential cannot authorize the selected provider",
                });
            };
            const catalog_provider = catalogProviderFor(state.host, target) orelse
                return state.writer.writeError(alloc, msg.id, .{
                    .code = ErrorCode.invalid_request,
                    .message = "Selected provider is unavailable in this host",
                });
            const access: credentials.CatalogAccess = if (state.host.cfg.auth_mode == .host_managed)
                .host_managed
            else
                credentials.catalogAccessForCredentialAndAccount(
                    staged_credential.?.source,
                    staged_credential.?.token,
                    staged_credential.?.gatewayTeam(),
                    staged_credential.?.accountId(),
                );
            // Provider selection is independent of earlier prompt cancellation.
            var catalog_cancel_flag = std.atomic.Value(bool).init(false);
            const fetched = try catalog_provider.fetch(alloc, .{
                .access = access,
                .endpoint = state.host.cfg.gateway_models_path,
                .cancel_flag = &catalog_cancel_flag,
                .view = .picker,
            });
            var catalog = switch (fetched) {
                .catalog => |catalog| catalog,
                .failure => return state.writer.writeError(alloc, msg.id, .{
                    .code = ErrorCode.invalid_request,
                    .message = "Failed to load provider model catalog",
                }),
            };
            defer model_catalog.freeModelCatalog(alloc, &catalog);
            if (target != .configured and catalog.items.len == 0) {
                return state.writer.writeError(alloc, msg.id, .{
                    .code = ErrorCode.invalid_request,
                    .message = "Provider returned no supported models",
                });
            }
            var settings = if (state.host.cfg.home_override) |home|
                try config_runtime.loadMergedSettingsFromHome(alloc, home, session.workspace_root)
            else
                try config_runtime.loadMergedSettings(alloc, session.workspace_root);
            defer settings.deinit(alloc);
            const saved_model = settings.models.get(target);
            var selected_model = if (target == .configured)
                saved_model orelse return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_request, .message = "Configure a model for the selected provider" })
            else
                catalog.items[0].id;
            if (target != .configured) if (saved_model) |saved| {
                for (catalog.items) |entry| {
                    if (std.mem.eql(u8, entry.id, saved)) {
                        selected_model = entry.id;
                        break;
                    }
                }
            };
            // A subagent's turn copies the session's model route under this lock when it starts,
            // so what the switch frees here is nobody's but the server's.
            state.host.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
            defer state.host.subagent_authority_mutex.unlock(io_mod.getIo());
            commitActiveSessionProvider(
                alloc,
                session,
                target,
                selected_model,
            ) catch {
                return state.writer.writeError(alloc, msg.id, .{
                    .code = ErrorCode.internal_error,
                    .message = "Failed to persist session provider",
                });
            };
            {
                lockCatalog(state.host);
                defer unlockCatalog(state.host);
                state.host.capability_resolver.adoptOwnedCatalog(alloc, catalog_provider, access, &catalog);
            }
            if (staged_credential) |*credential| {
                adoptSessionCredential(state.alloc, session, credential);
            } else {
                useHostManagedCredential(state.alloc, session);
            }
            pointWebSearchAtSession(session);
            if (!try dropUnsupportedSpeeds(state, alloc, msg, session)) return;
        }
    } else if (std.mem.eql(u8, config_id, "mode")) {
        const session = target_session;
        if (!try selectSessionMode(state, alloc, msg, session, value)) return;
    } else if (std.mem.eql(u8, config_id, "ultrafast")) {
        const session = target_session;
        const ultrafast = parseConfigBool(value) orelse
            return state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_params,
                .message = "Ultrafast mode must be true or false",
            });
        state.host.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
        defer state.host.subagent_authority_mutex.unlock(io_mod.getIo());
        if (!try applyActiveSessionUltrafast(state, alloc, msg, session, ultrafast)) return;
    } else if (std.mem.eql(u8, config_id, "fast")) {
        const session = target_session;
        const fast = parseConfigBool(value) orelse
            return state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_params,
                .message = "Fast mode must be true or false",
            });
        state.host.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
        defer state.host.subagent_authority_mutex.unlock(io_mod.getIo());
        if (!try applyActiveSessionFast(state, alloc, msg, session, fast)) return;
    } else if (std.mem.eql(u8, config_id, "effort")) {
        const session = target_session;
        const effort = types.ReasoningEffort.parse(value) orelse
            return state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_params,
                .message = "Invalid reasoning effort",
            });
        // The catalog's effort list is borrowed, so it is read under its lock.
        const supported: ?bool = supported: {
            lockCatalog(state.host);
            defer unlockCatalog(state.host);
            const config = sessions.effortConfigState(state, session) orelse break :supported null;
            break :supported sessions.effortSupportedBy(config.efforts, effort);
        };
        if (supported == null) return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Reasoning effort is unavailable for the active model",
        });
        if (!supported.?) {
            return state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_params,
                .message = "Reasoning effort is not available for the active model",
            });
        }
        state.host.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
        defer state.host.subagent_authority_mutex.unlock(io_mod.getIo());
        commitActiveSessionEffort(alloc, session, effort) catch {
            return state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.internal_error,
                .message = "Failed to persist session effort",
            });
        };
    } else {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Unknown config option",
        });
    }

    lockCatalog(state.host);
    defer unlockCatalog(state.host);
    try refreshModelCatalogForOptionsLocked(state, target_session);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"configOptions\":[");
    if (comptime !host_target.is_wasm) {
        try sessions.writeProviderConfigOption(
            &out.writer,
            target_session.provider,
            state.configured_providers.definitions,
        );
        try out.writer.writeAll(",");
    }
    try sessions.writeModelConfigOption(
        &out.writer,
        target_session.model,
        state.host.capability_resolver.catalogEntries(),
    );
    try out.writer.writeAll(",");
    try sessions.writeModeConfigOption(&out.writer, state.host.cfg.mode_registry, target_session.mode, own_member.extensions.contains(.permission_mode));
    if (sessions.effortConfigState(state, target_session)) |config| {
        try out.writer.writeAll(",");
        try sessions.writeEffortConfigOption(&out.writer, config.efforts, config.current);
    }
    if (sessions.fastConfigState(state, target_session)) |current| {
        try out.writer.writeAll(",");
        try sessions.writeFastConfigOption(&out.writer, current);
    }
    if (sessions.ultrafastConfigState(state, target_session)) |current| {
        try out.writer.writeAll(",");
        try sessions.writeUltrafastConfigOption(&out.writer, current);
    }
    try out.writer.writeAll("]}");
    try state.writer.writeResponse(alloc, msg.id, out.writer.buffered());
}

/// Loads the catalog when it is due, before a reply that lists its models. A
/// due load whose request cannot connect gives up after
/// `gateway_provider.catalog_connect_wait_ms` and keeps the catalog fx
/// already has (`CapabilityResolver.refreshWithin`), so a dead network does
/// not hold up the reply, or the prompt sent after it, for the 20 to 30
/// seconds its DNS lookup or connect takes to fail.
pub fn refreshModelCatalogForOptions(state: *ServerState, active: *const ActiveSessionState) !void {
    lockCatalog(state.host);
    defer unlockCatalog(state.host);
    return refreshModelCatalogForOptionsLocked(state, active);
}

/// `refreshModelCatalogForOptions` with `catalog_mutex` held.
pub fn refreshModelCatalogForOptionsLocked(state: *ServerState, active: *const ActiveSessionState) !void {
    if (comptime host_target.is_wasm) return;
    if (state.host.cfg.minimal_kernel) return;
    const provider = catalogProviderFor(state.host, active.provider) orelse return;
    // A refresh replaces the catalog's entries. A working subagent reads its
    // own copy of the catalog (`ModelRoute` in prompt.zig), so a refresh frees
    // nothing it reads. The refresh is skipped while the session's subagents
    // work, so that a reload and a model option leave the catalog as it is for
    // their run. It is not run again when they end: a refresh that was due
    // stays due, and the next call that finds no subagent of its session
    // working makes it. A switch of the provider, which must replace the
    // catalog, does it under `subagent_authority_mutex` in
    // `handleSetConfigOption`.
    if (active.subagent_host) |subagents| if (!subagents.quiet()) {
        debug_trace.logf("acp", "event=model_catalog_refresh_skipped session={s} reason=subagents_working", .{active.session_id});
        return;
    };
    // Restoring the same session can leave its previous cancellation flag set.
    var cancel_flag = std.atomic.Value(bool).init(false);
    try state.host.capability_resolver.refreshWithin(state.alloc, provider, .{
        .access = if (state.host.cfg.auth_mode == .host_managed)
            .host_managed
        else
            credentials.catalogAccessForCredentialAndAccount(
                active.credential_source,
                active.api_key,
                active.gateway_team,
                active.account_id,
            ),
        .endpoint = state.host.cfg.gateway_models_path,
        .cancel_flag = &cancel_flag,
    }, gateway_provider.catalog_connect_wait_ms);
}

/// Takes `catalog_mutex`, which every use of the shared capability resolver
/// holds: the reader thread and the turns of every session use it.
pub fn lockCatalog(host: *Host) void {
    host.catalog_mutex.lockUncancelable(io_mod.getIo());
}

pub fn unlockCatalog(host: *Host) void {
    host.catalog_mutex.unlock(io_mod.getIo());
}

fn commitActiveSessionProvider(
    alloc: Allocator,
    session: *ActiveSessionState,
    provider: model_provider.ProviderId,
    model: []const u8,
) !void {
    session.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer session.session_write_mutex.unlock(io_mod.getIo());
    const staged_model = try alloc.dupe(u8, model);
    errdefer alloc.free(staged_model);
    const v2 = session.v2 orelse return error.SessionPersistenceUnavailable;
    try setV2Preferences(v2, session, provider, model, session.effort);
    alloc.free(session.model);
    session.model = staged_model;
    session.provider = provider;
}

/// A v2 session stores its preferences as one value, so every change
/// writes the whole set.
fn setV2Preferences(
    v2: *session_adapter.Session,
    session: *const ActiveSessionState,
    provider: model_provider.ProviderId,
    model: []const u8,
    effort: types.ReasoningEffort,
) !void {
    var durable = try v2.currentPreferences(v2.alloc);
    defer durable.deinit(v2.alloc);
    try v2.setPreferences(.{
        .provider = provider,
        .model = @constCast(model),
        .effort = effort,
        .fast_mode = session.fast_mode,
        .ultrafast_mode = durable.ultrafast_mode,
    });
}

fn commitActiveSessionModel(
    alloc: Allocator,
    session: *ActiveSessionState,
    value: []const u8,
) !void {
    session.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer session.session_write_mutex.unlock(io_mod.getIo());
    if (session.v2) |v2| {
        const staged_model = try alloc.dupe(u8, value);
        errdefer alloc.free(staged_model);
        try setV2Preferences(v2, session, session.provider, value, session.effort);
        alloc.free(session.model);
        session.model = staged_model;
        return;
    }
    return error.SessionPersistenceUnavailable;
}

fn commitActiveSessionEffort(
    alloc: Allocator,
    session: *ActiveSessionState,
    effort: types.ReasoningEffort,
) !void {
    if (host_target.is_wasm) {
        const previous = session.effort;
        session.effort = effort;
        sessions.commitWasmSession(alloc, session) catch |err| {
            session.effort = previous;
            return err;
        };
        return;
    }
    session.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer session.session_write_mutex.unlock(io_mod.getIo());
    const v2 = session.v2 orelse return error.SessionPersistenceUnavailable;
    try setV2Preferences(v2, session, session.provider, session.model, effort);
    session.effort = effort;
}

fn parseConfigBool(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return null;
}

/// Applies a strict ultrafast-mode transition to the session it names. Every
/// enabled request is admitted against its current provider/model capability.
fn applyActiveSessionUltrafast(
    state: *ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
    session: *ActiveSessionState,
    ultrafast: bool,
) !bool {
    if (ultrafast) {
        const capabilities = activeSessionCapabilities(state, session);
        const rejection = try ultrafastOverrideRejection(alloc, session.provider, capabilities, session.model);
        if (rejection) |message| {
            defer alloc.free(message);
            try state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_params,
                .message = message,
                .data = .{ .model_capability = .{
                    .code = "MODEL_UNSUPPORTED_ULTRAFAST",
                    .model = session.model,
                    .capability = "ultrafast",
                } },
            });
            return false;
        }
        // Fast and Ultrafast are exclusive, as in the CLI.
        if (session.fast_mode and !try storeSessionFast(state, alloc, msg, session, false)) return false;
    }
    return storeSessionUltrafast(state, alloc, msg, session, ultrafast);
}

/// Saves the session's ultrafast preference without admission checks.
/// Returns false after writing the error response.
fn storeSessionUltrafast(
    state: *ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
    session: *ActiveSessionState,
    ultrafast: bool,
) !bool {
    if (state.host.cfg.minimal_kernel and session.v2 == null and session.wasm_state == null) {
        session.ultrafast_mode = ultrafast;
        return true;
    }
    commitActiveSessionUltrafast(alloc, session, ultrafast) catch {
        try state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Failed to persist session ultrafast preference",
        });
        return false;
    };
    return true;
}

/// Applies a Fast-mode transition to the session it names, mirroring the CLI's
/// `/fast`: enabling requires the model's Fast lane and turns Ultrafast off;
/// disabling always succeeds. Returns false after writing the error response.
fn applyActiveSessionFast(
    state: *ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
    session: *ActiveSessionState,
    fast: bool,
) !bool {
    if (fast) {
        if (!activeSessionCapabilities(state, session).supports_fast_mode) {
            const message = try alloc.print("Fast mode is not available for model \"{s}\"", .{session.model});
            defer alloc.free(message);
            try state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_params,
                .message = message,
                .data = .{ .model_capability = .{
                    .code = "MODEL_UNSUPPORTED_FAST",
                    .model = session.model,
                    .capability = "fast",
                } },
            });
            return false;
        }
        if (session.ultrafast_mode and !try storeSessionUltrafast(state, alloc, msg, session, false)) return false;
    }
    return storeSessionFast(state, alloc, msg, session, fast);
}

/// Saves the session's fast preference without admission checks.
/// Returns false after writing the error response.
fn storeSessionFast(
    state: *ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
    session: *ActiveSessionState,
    fast: bool,
) !bool {
    if (state.host.cfg.minimal_kernel and session.v2 == null and session.wasm_state == null) {
        session.fast_mode = fast;
        return true;
    }
    commitActiveSessionFast(alloc, session, fast) catch {
        try state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Failed to persist session fast preference",
        });
        return false;
    };
    return true;
}

fn commitActiveSessionFast(alloc: Allocator, session: *ActiveSessionState, fast: bool) !void {
    if (host_target.is_wasm) {
        const previous = session.fast_mode;
        session.fast_mode = fast;
        sessions.commitWasmSession(alloc, session) catch |err| {
            session.fast_mode = previous;
            return err;
        };
        return;
    }
    session.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer session.session_write_mutex.unlock(io_mod.getIo());
    const v2 = session.v2 orelse return error.SessionPersistenceUnavailable;
    var preferences = try v2.currentPreferences(alloc);
    defer preferences.deinit(alloc);
    preferences.fast_mode = fast;
    try v2.setPreferences(preferences);
    session.fast_mode = fast;
}

fn activeSessionCapabilities(state: *ServerState, session: *const ActiveSessionState) model_capabilities.Capabilities {
    const bundle = state.host.cfg.provider_set.select(session.provider);
    lockCatalog(state.host);
    defer unlockCatalog(state.host);
    return state.host.capability_resolver.available(session.model, bundle.fallbackModelCapabilities(session.model));
}

const SessionSpeed = struct {
    fast: bool,
    ultrafast: bool,
};

/// Pure policy: the lanes a session keeps after switching to a model with
/// `capabilities` under `provider`. Ultrafast is a Gateway-only lane.
fn speedSupportedBy(
    speed: SessionSpeed,
    provider: model_provider.ProviderId,
    capabilities: model_capabilities.Capabilities,
) SessionSpeed {
    return .{
        .fast = speed.fast and capabilities.supports_fast_mode,
        .ultrafast = speed.ultrafast and provider == .gateway and capabilities.supports_ultrafast_mode,
    };
}

test "speedSupportedBy keeps only the lanes the new model offers" {
    const both = model_capabilities.Capabilities{ .supports_fast_mode = true, .supports_ultrafast_mode = true };
    const fast_only = model_capabilities.Capabilities{ .supports_fast_mode = true };
    const plain = model_capabilities.Capabilities{};
    const on: SessionSpeed = .{ .fast = true, .ultrafast = true };

    try std.testing.expectEqual(on, speedSupportedBy(on, .gateway, both));
    try std.testing.expectEqual(SessionSpeed{ .fast = true, .ultrafast = false }, speedSupportedBy(on, .gateway, fast_only));
    try std.testing.expectEqual(SessionSpeed{ .fast = false, .ultrafast = false }, speedSupportedBy(on, .gateway, plain));
    try std.testing.expectEqual(SessionSpeed{ .fast = true, .ultrafast = false }, speedSupportedBy(on, .codex, both));
    const standard: SessionSpeed = .{ .fast = false, .ultrafast = false };
    try std.testing.expectEqual(standard, speedSupportedBy(standard, .gateway, both));
}

/// After a model or provider switch, turns off any lane the new model lacks,
/// like the CLI model picker. A hidden lane would otherwise stay on: Ultrafast
/// would fail the next prompt and Fast would return on a later switch back.
/// Returns false after writing the error response.
fn dropUnsupportedSpeeds(
    state: *ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
    session: *ActiveSessionState,
) !bool {
    const kept = speedSupportedBy(
        .{ .fast = session.fast_mode, .ultrafast = session.ultrafast_mode },
        session.provider,
        activeSessionCapabilities(state, session),
    );
    if (session.ultrafast_mode and !kept.ultrafast) {
        debug_trace.logf("acp", "ultrafast mode turned off: model={s} does not offer it", .{session.model});
        if (!try storeSessionUltrafast(state, alloc, msg, session, false)) return false;
    }
    if (session.fast_mode and !kept.fast) {
        debug_trace.logf("acp", "fast mode turned off: model={s} does not offer it", .{session.model});
        if (!try storeSessionFast(state, alloc, msg, session, false)) return false;
    }
    return true;
}

test "ACP ultrafast disable applies to volatile SDK sessions without a durable store" {
    var test_host = testHost(std.testing.allocator);
    defer test_host.deinit();
    var state = ServerState{
        .alloc = std.testing.allocator,
        .host = &test_host,
        .writer = jsonrpc.Writer.init(),
        .configured_ultrafast_mode = true,
        .process_ultrafast_override = true,
    };
    state.host.cfg.minimal_kernel = true;
    var active: ActiveSessionState = undefined;
    active.client_writer = jsonrpc.Writer.initCallback(&active, forwardToMain);
    active.v2 = null;
    active.wasm_state = null;
    active.ultrafast_mode = true;
    var msg = jsonrpc.Message{ .id = .{ .integer = 1 }, .method = "session/set_config_option" };
    try std.testing.expect(try applyActiveSessionUltrafast(&state, std.testing.allocator, &msg, &active, false));
    try std.testing.expect(!active.ultrafast_mode);
    try std.testing.expect(state.configured_ultrafast_mode);
    try std.testing.expectEqual(@as(?bool, true), state.process_ultrafast_override);
}

fn commitActiveSessionUltrafast(
    alloc: Allocator,
    session: *ActiveSessionState,
    ultrafast: bool,
) !void {
    if (comptime host_target.is_wasm) {
        return sessions.commitWasmUltrafastPreference(alloc, session, ultrafast);
    }
    session.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer session.session_write_mutex.unlock(io_mod.getIo());
    const v2 = session.v2 orelse return error.SessionPersistenceUnavailable;
    var preferences = try v2.currentPreferences(alloc);
    defer preferences.deinit(alloc);
    preferences.ultrafast_mode = ultrafast;
    try v2.setPreferences(preferences);
    session.ultrafast_mode = ultrafast;
}

/// Handles the older `session/set_mode`, modeled with the `mode` option in
/// `tests/tla/acp/AcpPermissionModes.tla`.
fn handleSetMode(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    const params = msg.params_raw orelse return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Missing params",
    });

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, params, .{}) catch
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Invalid params" });
    defer parsed.deinit();

    const target = (try requireParsedSessionTarget(state, alloc, msg.id, parsed.value)) orelse return;

    const mode_id = modeId: {
        if (parsed.value != .object) break :modeId null;
        const value = parsed.value.object.get("modeId") orelse break :modeId null;
        break :modeId if (value == .string) value.string else null;
    } orelse return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Missing modeId",
    });
    if (!try selectSessionMode(state, alloc, msg, target, mode_id)) return;

    try state.writer.writeResponse(alloc, msg.id, "null");
}

/// Switches the session to a registered mode. Returns null and leaves the
/// session unchanged when `id` is not registered.
pub fn applySessionMode(registry: mode_registry.Registry, session: *ActiveSessionState, id: []const u8) ?*const mode_registry.ModeSpec {
    const mode = registry.lookup(id) orelse return null;
    session.mode = mode.id;
    session.permission_mode = mode.permission_mode;
    return mode;
}

/// Applies a client's mode choice to the session it names and saves it as the
/// profile's permission mode, like the CLI's /permissions. Writes an error
/// and returns false for a mode the registry does not list.
fn selectSessionMode(
    state: *ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
    session: *ActiveSessionState,
    id: []const u8,
) !bool {
    const applied = blk: {
        state.host.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
        defer state.host.subagent_authority_mutex.unlock(io_mod.getIo());
        break :blk applySessionMode(state.host.cfg.mode_registry, session, id);
    };
    const mode = applied orelse {
        try state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Unknown mode" });
        return false;
    };
    saveSessionPermissionMode(state, alloc, mode.permission_mode);
    return true;
}

/// Saves a chosen permission mode to the profile so new sessions, here and
/// in other fx processes, start in it. Hosts without a profile keep it for
/// this process only.
fn saveSessionPermissionMode(state: *ServerState, alloc: Allocator, mode: types.PermissionMode) void {
    state.permission_mode = mode;
    if (comptime !host_target.is_wasm) {
        if (state.host.cfg.minimal_kernel) return;
        const label = permissions.permissionModeLabel(mode);
        const home = state.host.cfg.home_override orelse io_mod.homeDir() orelse {
            debug_trace.logf("acp", "permission_mode_save_failed mode={s} err=HomeNotSet", .{label});
            return;
        };
        var attempt = config_runtime.attemptUserPreferencesInHome(alloc, home, .{ .permission_mode = mode });
        defer attempt.deinit(alloc);
        switch (attempt) {
            .outcome => |outcome| debug_trace.logf("acp", "permission_mode_saved mode={s} outcome={s}", .{ label, @tagName(outcome) }),
            .failure => |failure| debug_trace.logf("acp", "permission_mode_save_failed mode={s} err={s}", .{ label, @errorName(failure.err) }),
        }
    }
}

/// The mode a session starts in and the permission mode it enforces.
pub const StartingMode = struct {
    id: []const u8,
    permission_mode: types.PermissionMode,
};

/// Reads the permission mode saved for `workspace_root` as it is now, so a
/// running process follows a mode another fx process saved, and returns the
/// registered mode that applies it, or the default mode when none does.
pub fn loadStartingMode(state: *ServerState, alloc: Allocator, workspace_root: []const u8) StartingMode {
    if (comptime !host_target.is_wasm) {
        if (!state.host.cfg.minimal_kernel and workspace_root.len > 0) {
            if (app_lifecycle.loadSavedPermissionMode(alloc, state.host.cfg.home_override, workspace_root)) |saved| {
                state.permission_mode = saved;
            } else |err| {
                debug_trace.logf("acp", "permission_mode_reload_failed kept={s} err={s}", .{
                    permissions.permissionModeLabel(state.permission_mode),
                    @errorName(err),
                });
            }
        }
    }
    // `fx acp --permission-mode` beats the saved mode, as FX_PERMISSION_MODE does.
    if (state.host.cfg.permission_override) |mode| state.permission_mode = mode;
    return .{
        .id = state.host.cfg.mode_registry.startingModeId(state.permission_mode),
        .permission_mode = state.permission_mode,
    };
}

test "applySessionMode uses registered mode policy and ignores unknown modes" {
    const mode_specs = [_]mode_registry.ModeSpec{
        .{ .id = "inspect", .name = "Inspect", .permission_mode = .ask },
        .{ .id = "apply", .name = "Apply", .permission_mode = .auto },
    };
    const registry = mode_registry.Registry{
        .default_mode_id = "inspect",
        .modes = mode_specs[0..],
    };
    var session = ActiveSessionState{
        .session_id = @constCast("session"),
        .model = @constCast("model"),
        .mode = registry.default_mode_id,
        .workspace_root = "/tmp/workspace",
        .api_key = "",
        .agent_step_limit = 0,
        .max_tool_result_bytes = 0,
        .fast_mode = false,
        .effort = .auto,
        .first_call_tool_choice = .auto,
        .permission_mode = .ask,
        .permission_rules = .{},
        .session_rt = .{ .max_history_turns = 0 },
        .cancel_flag = std.atomic.Value(bool).init(false),
        .pending_prompt_id = null,
    };
    session.client_writer = jsonrpc.Writer.initCallback(&session, forwardToMain);

    try std.testing.expectEqualStrings("apply", applySessionMode(registry, &session, "apply").?.id);
    try std.testing.expectEqualStrings("apply", session.mode);
    try std.testing.expectEqual(types.PermissionMode.auto, session.permission_mode);

    _ = applySessionMode(registry, &session, "inspect");
    try std.testing.expectEqualStrings("inspect", session.mode);
    try std.testing.expectEqual(types.PermissionMode.ask, session.permission_mode);

    try std.testing.expect(applySessionMode(registry, &session, "unknown") == null);
    try std.testing.expectEqualStrings("inspect", session.mode);
    try std.testing.expectEqual(types.PermissionMode.ask, session.permission_mode);

    _ = applySessionMode(registry, &session, "apply");
    try std.testing.expectEqual(types.PermissionMode.auto, session.permission_mode);
    _ = applySessionMode(registry, &session, "inspect");
    try std.testing.expectEqual(types.PermissionMode.ask, session.permission_mode);
}

test "ACP notifications with absent id are not response targets" {
    const alloc = std.testing.allocator;
    var notification = try jsonrpc.parseMessage(
        alloc,
        "{\"jsonrpc\":\"2.0\",\"method\":\"unknown/notification\",\"params\":{}}",
    );
    defer jsonrpc.freeMessage(alloc, &notification);
    try std.testing.expect(!shouldRespondToMessage(&notification));

    var null_id_request = try jsonrpc.parseMessage(
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"unknown/request\",\"params\":{}}",
    );
    defer jsonrpc.freeMessage(alloc, &null_id_request);
    try std.testing.expect(shouldRespondToMessage(&null_id_request));
}

test "ACP method parser classifies request dispatch methods" {
    try std.testing.expectEqual(AcpMethod.initialize, AcpMethod.parse("initialize"));
    try std.testing.expectEqual(AcpMethod.session_cancel, AcpMethod.parse("session/cancel"));
    try std.testing.expectEqual(AcpMethod.session_new, AcpMethod.parse("session/new"));
    try std.testing.expectEqual(AcpMethod.session_load, AcpMethod.parse("session/load"));
    try std.testing.expectEqual(AcpMethod.session_resume, AcpMethod.parse("session/resume"));
    try std.testing.expectEqual(AcpMethod.session_close, AcpMethod.parse("session/close"));
    try std.testing.expectEqual(AcpMethod.session_list, AcpMethod.parse("session/list"));
    try std.testing.expectEqual(AcpMethod.session_prompt, AcpMethod.parse("session/prompt"));
    try std.testing.expectEqual(AcpMethod.session_set_config_option, AcpMethod.parse("session/set_config_option"));
    try std.testing.expectEqual(AcpMethod.session_set_mode, AcpMethod.parse("session/set_mode"));
    try std.testing.expectEqual(AcpMethod.libfx_checkpoint, AcpMethod.parse("_sh.fx/session/checkpoint"));
    try std.testing.expectEqual(AcpMethod.libfx_restore, AcpMethod.parse("_sh.fx/session/restore"));
    try std.testing.expectEqual(AcpMethod.libfx_new, AcpMethod.parse("_sh.fx/session/new"));
    try std.testing.expectEqual(AcpMethod.libfx_steer, AcpMethod.parse("_sh.fx/session/steer"));
    try std.testing.expectEqual(AcpMethod.libfx_withdraw, AcpMethod.parse("_sh.fx/session/withdraw_steer"));
    try std.testing.expectEqual(AcpMethod.libfx_handoff, AcpMethod.parse("_sh.fx/session/end_turn_for_steer"));
    try std.testing.expectEqual(AcpMethod.libfx_follow_up, AcpMethod.parse("_sh.fx/session/follow_up"));
    try std.testing.expectEqual(AcpMethod.libfx_snapshot, AcpMethod.parse("_sh.fx/journal/snapshot"));
    try std.testing.expectEqual(AcpMethod.libfx_journal_open, AcpMethod.parse("_sh.fx/journal/open"));
    try std.testing.expectEqual(AcpMethod.libfx_journal_images, AcpMethod.parse("_sh.fx/journal/stage_images"));
    try std.testing.expectEqual(AcpMethod.session_delete, AcpMethod.parse("session/delete"));
    // The old names are gone, not aliases.
    try std.testing.expectEqual(AcpMethod.unknown, AcpMethod.parse("libfx/steer"));
    try std.testing.expectEqual(AcpMethod.unknown, AcpMethod.parse("session/remove"));
    try std.testing.expectEqual(AcpMethod.unknown, AcpMethod.parse("workspace/unknown"));
    try std.testing.expect(AcpMethod.libfx_checkpoint.isLibfx());
    try std.testing.expect(AcpMethod.libfx_restore.isLibfx());
    try std.testing.expect(AcpMethod.libfx_new.isLibfx());
    try std.testing.expect(AcpMethod.libfx_steer.isLibfx());
    try std.testing.expect(AcpMethod.libfx_handoff.isLibfx());
    try std.testing.expect(!AcpMethod.libfx_handoff.waitsForActivePrompt());
    try std.testing.expect(!AcpMethod.session_new.isLibfx());
}

test "ACP prompt gate policy keeps lifecycle interruption responsive" {
    try std.testing.expect(!AcpMethod.initialize.waitsForActivePrompt());
    try std.testing.expect(!AcpMethod.session_cancel.waitsForActivePrompt());
    try std.testing.expect(!AcpMethod.session_new.waitsForActivePrompt());
    try std.testing.expect(!AcpMethod.session_load.waitsForActivePrompt());
    try std.testing.expect(!AcpMethod.session_resume.waitsForActivePrompt());
    try std.testing.expect(!AcpMethod.session_close.waitsForActivePrompt());
    try std.testing.expect(AcpMethod.session_list.waitsForActivePrompt());
    try std.testing.expect(AcpMethod.session_prompt.waitsForActivePrompt());
    try std.testing.expect(!AcpMethod.session_set_config_option.waitsForActivePrompt());
    try std.testing.expect(!AcpMethod.session_set_mode.waitsForActivePrompt());
    try std.testing.expect(!AcpMethod.libfx_steer.waitsForActivePrompt());
    try std.testing.expect(AcpMethod.unknown.waitsForActivePrompt());
}

test "ACP initialize request validation requires a uint16 protocol version" {
    const alloc = std.testing.allocator;
    const valid = try parseInitializeRequest(
        alloc,
        "{\"protocolVersion\":1,\"clientCapabilities\":{\"fs\":{\"readTextFile\":true},\"terminal\":true}}",
        false,
    );
    try std.testing.expect(valid.client_fs_read);
    try std.testing.expect(!valid.client_fs_write);
    try std.testing.expect(valid.client_terminal);

    _ = try parseInitializeRequest(alloc, "{\"protocolVersion\":0}", false);
    _ = try parseInitializeRequest(alloc, "{\"protocolVersion\":2}", false);
    _ = try parseInitializeRequest(alloc, "{\"protocolVersion\":65535}", false);

    const cases = [_]struct {
        params: ?[]const u8,
        expected: anyerror,
    }{
        .{ .params = null, .expected = error.InvalidInitializeParams },
        .{ .params = "{}", .expected = error.InvalidInitializeParams },
        .{ .params = "[]", .expected = error.InvalidInitializeParams },
        .{ .params = "{\"protocolVersion\":\"one\"}", .expected = error.InvalidInitializeParams },
        .{ .params = "{\"protocolVersion\":-1}", .expected = error.InvalidInitializeParams },
        .{ .params = "{\"protocolVersion\":70000}", .expected = error.InvalidInitializeParams },
    };
    for (cases) |case| {
        try std.testing.expectError(
            case.expected,
            parseInitializeRequest(alloc, case.params, false),
        );
    }
}

test "ACP initialize reads session.notices as advertised only for an object" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { capabilities: []const u8, advertised: bool }{
        .{ .capabilities = "{\"session\":{\"notices\":{}}}", .advertised = true },
        .{ .capabilities = "{\"session\":{\"notices\":{\"_meta\":{}}}}", .advertised = true },
        .{ .capabilities = "{}", .advertised = false },
        .{ .capabilities = "{\"session\":null}", .advertised = false },
        .{ .capabilities = "{\"session\":{}}", .advertised = false },
        .{ .capabilities = "{\"session\":{\"notices\":null}}", .advertised = false },
        .{ .capabilities = "{\"session\":{\"notices\":false}}", .advertised = false },
        .{ .capabilities = "{\"session\":{\"notices\":true}}", .advertised = false },
        .{ .capabilities = "{\"session\":{\"notices\":\"yes\"}}", .advertised = false },
        .{ .capabilities = "{\"session\":{\"notices\":[]}}", .advertised = false },
    };
    for (cases) |case| {
        const params = try alloc.print("{{\"protocolVersion\":1,\"clientCapabilities\":{s}}}", .{case.capabilities});
        defer alloc.free(params);
        const request = try parseInitializeRequest(alloc, params, false);
        std.testing.expectEqual(case.advertised, request.client_notices) catch |err| {
            std.debug.print("capabilities: {s}\n", .{case.capabilities});
            return err;
        };
    }
}

test "ACP permission responses map canonical option ids" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { json: []const u8, expected: types.ToolPermissionDecision }{
        .{ .json = "{\"outcome\":{\"outcome\":\"selected\",\"optionId\":\"allow_once\"}}", .expected = .once },
        .{ .json = "{\"outcome\":{\"outcome\":\"selected\",\"optionId\":\"allow_always\"}}", .expected = .always },
        .{ .json = "{\"outcome\":{\"outcome\":\"selected\",\"optionId\":\"reject_once\"}}", .expected = .deny },
        .{ .json = "{\"outcome\":{\"outcome\":\"cancelled\"}}", .expected = .deny },
    };
    for (cases) |case| {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, case.json, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(case.expected, parsePermissionDecision(parsed.value).?);
    }
    const malformed_cases = [_][]const u8{
        "{\"outcome\":{\"outcome\":\"selected\"}}",
        "{\"outcome\":{\"outcome\":\"selected\",\"optionId\":\"allow_forever\"}}",
        "{\"outcome\":{\"outcome\":\"granted\"}}",
        "{\"outcome\":\"selected\"}",
        "{}",
        "[]",
    };
    for (malformed_cases) |json| {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
        defer parsed.deinit();
        try std.testing.expect(parsePermissionDecision(parsed.value) == null);
    }
}

test "an ACP steer that cuts the reply short is no turn cancel, and the client's cancel is" {
    const alloc = std.testing.allocator;
    var test_host = testHost(alloc);
    defer test_host.deinit();
    const Discard = struct {
        fn write(_: ?*anyopaque, _: []const u8) !void {}
    };
    var state = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(null, Discard.write),
    };
    state.host.cfg.minimal_kernel = true;
    var session: ActiveSessionState = .{
        .session_id = @constCast("session"),
        .model = @constCast("model"),
        .mode = "default",
        .workspace_root = "/tmp/workspace",
        .api_key = "",
        .agent_step_limit = 0,
        .max_tool_result_bytes = 0,
        .fast_mode = false,
        .effort = .auto,
        .first_call_tool_choice = .auto,
        .permission_mode = .ask,
        .permission_rules = .{},
        .session_rt = .{ .max_history_turns = 0 },
        .cancel_flag = std.atomic.Value(bool).init(false),
        .pending_prompt_id = null,
    };
    session.client_writer = jsonrpc.Writer.initCallback(&session, forwardToMain);
    defer session.outbound.pending.deinit(alloc);
    try attachOpenerForTest(&session, &state);
    defer releaseTestSession(&state, &session);
    session.steering.open(alloc);
    defer session.steering.deinit(alloc);
    _ = session.steering.notePhase(1, .reply, &session.cancel_flag);
    try session.steering.enqueue(alloc, "use tabs");
    try std.testing.expect(session.steering.claimInterrupt(&session.cancel_flag));
    try std.testing.expect(session.cancel_flag.load(.seq_cst));
    // The turn's workspace captures keep running (D98).
    try std.testing.expect(!session.turn_cancel.load(.seq_cst));
    handleCancel(&session, false);
    try std.testing.expect(session.turn_cancel.load(.seq_cst));
}

test "ACP outbound waiters resolve to deny on cancellation" {
    var test_host = testHost(std.testing.allocator);
    defer test_host.deinit();
    const Capture = struct {
        saw_request_cancellation: bool = false,

        fn write(raw: ?*anyopaque, frame: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (std.mem.find(u8, frame, "\"method\":\"$/cancel_request\"") != null and
                std.mem.find(u8, frame, "\"requestId\":3") != null)
            {
                self.saw_request_cancellation = true;
            }
        }
    };
    var capture = Capture{};
    var state = ServerState{
        .alloc = std.testing.allocator,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&capture, Capture.write),
    };
    var session: ActiveSessionState = undefined;
    session.client_writer = jsonrpc.Writer.initCallback(&session, forwardToMain);
    try attachOpenerForTest(&session, &state);
    defer releaseTestSession(&state, &session);
    session.outbound = .{};
    defer session.outbound.pending.deinit(state.alloc);

    const id = beginPermissionRequest(&session) orelse return error.TestExpectedEqual;
    const concurrent = beginPermissionRequest(&session) orelse return error.TestExpectedEqual;

    cancelSessionPending(&session, false);
    try std.testing.expectEqual(types.ToolPermissionDecision.deny, awaitPermissionDecision(&session, id));
    try std.testing.expectEqual(types.ToolPermissionDecision.deny, awaitPermissionDecision(&session, concurrent));
    try std.testing.expectEqual(@as(usize, 0), session.outbound.pending.count());

    const second = beginPermissionRequest(&session) orelse return error.TestExpectedEqual;
    try std.testing.expect(second.id != id.id);
    cancelPermissionRequest(&session, second);
    try std.testing.expectEqual(types.ToolPermissionDecision.deny, awaitPermissionDecision(&session, second));
    try std.testing.expect(capture.saw_request_cancellation);
}

test "ACP client input end gives a pending request no client and refuses new ones" {
    const alloc = std.testing.allocator;
    var test_host = testHost(alloc);
    defer test_host.deinit();
    var state = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.init(),
    };
    var session: ActiveSessionState = undefined;
    session.client_writer = jsonrpc.Writer.initCallback(&session, forwardToMain);
    try attachOpenerForTest(&session, &state);
    defer releaseTestSession(&state, &session);
    session.outbound = .{};
    defer session.outbound.pending.deinit(alloc);

    const request = (try beginOutboundRequest(&session, .elicitation)).?;
    endClientInput(&state);

    var response = awaitOutboundResponse(&session, request, .elicitation) orelse return error.TestExpectedEqual;
    defer response.deinit(alloc);
    try std.testing.expect(!response.cancelled);
    try std.testing.expect(response.no_client);
    try std.testing.expect((try beginOutboundRequest(&session, .elicitation)) == null);
}

test "ACP outbound responses correlate out of order and ignore unknown ids" {
    const alloc = std.testing.allocator;
    var test_host = testHost(alloc);
    defer test_host.deinit();
    var state = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.init(),
    };
    var session: ActiveSessionState = undefined;
    session.client_writer = jsonrpc.Writer.initCallback(&session, forwardToMain);
    try attachOpenerForTest(&session, &state);
    defer releaseTestSession(&state, &session);
    session.outbound = .{};
    defer session.outbound.pending.deinit(alloc);

    const first = (try beginOutboundRequest(&session, .elicitation)).?;
    const second = (try beginOutboundRequest(&session, .elicitation)).?;
    handleClientResponse(&state, alloc, &.{
        .id = .{ .integer = @intCast(second.id) },
        .result_raw = "{\"action\":\"decline\"}",
    });
    handleClientResponse(&state, alloc, &.{
        .id = .{ .integer = 9999 },
        .result_raw = "{\"action\":\"accept\"}",
    });
    handleClientResponse(&state, alloc, &.{
        .id = .{ .integer = @intCast(first.id) },
        .result_raw = "{\"action\":\"cancel\"}",
    });

    var second_response = awaitOutboundResponse(&session, second, .elicitation).?;
    defer second_response.deinit(alloc);
    try std.testing.expectEqualStrings("{\"action\":\"decline\"}", second_response.result_json.?);
    var first_response = awaitOutboundResponse(&session, first, .elicitation).?;
    defer first_response.deinit(alloc);
    try std.testing.expectEqualStrings("{\"action\":\"cancel\"}", first_response.result_json.?);
    try std.testing.expectEqual(@as(usize, 0), session.outbound.pending.count());
}

test "ACP client requests of every kind get their own answer, a cancel, or the client-gone result" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        cancelled_requests: usize = 0,

        fn write(raw: ?*anyopaque, frame: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (std.mem.find(u8, frame, "\"method\":\"$/cancel_request\"") != null) self.cancelled_requests += 1;
        }
    };
    const kinds = [_]OutboundKind{ .permission, .elicitation, .host_tool, .journal };
    for (kinds) |kind| {
        var test_host = testHost(alloc);
        defer test_host.deinit();
        var capture = Capture{};
        var state = ServerState{
            .alloc = alloc,
            .host = &test_host,
            .writer = jsonrpc.Writer.initCallback(&capture, Capture.write),
        };
        var session: ActiveSessionState = undefined;
        session.client_writer = jsonrpc.Writer.initCallback(&session, forwardToMain);
        try attachOpenerForTest(&session, &state);
        defer releaseTestSession(&state, &session);
        session.outbound = .{};
        defer session.outbound.pending.deinit(alloc);

        const answered = (try beginOutboundRequest(&session, kind)).?;
        handleClientResponse(&state, alloc, &.{
            .id = .{ .integer = @intCast(answered.id) },
            .result_raw = "{\"ok\":true}",
        });
        var response = awaitOutboundResponse(&session, answered, kind) orelse return error.TestExpectedEqual;
        defer response.deinit(alloc);
        try std.testing.expectEqualStrings("{\"ok\":true}", response.result_json.?);

        const cancelled = (try beginOutboundRequest(&session, kind)).?;
        cancelOutboundRequest(&session, cancelled);
        var cancelled_response = awaitOutboundResponse(&session, cancelled, kind) orelse return error.TestExpectedEqual;
        defer cancelled_response.deinit(alloc);
        try std.testing.expect(cancelled_response.cancelled);
        try std.testing.expectEqual(@as(usize, 1), capture.cancelled_requests);

        const gone = (try beginOutboundRequest(&session, kind)).?;
        endClientInput(&state);
        var gone_response = awaitOutboundResponse(&session, gone, kind) orelse return error.TestExpectedEqual;
        defer gone_response.deinit(alloc);
        try std.testing.expect(gone_response.no_client);
        try std.testing.expect((try beginOutboundRequest(&session, kind)) == null);
    }
}

test "ACP a waiter blocked on the client wakes for each kind of answer, cancel, and client-gone" {
    const alloc = std.testing.allocator;
    const Outcome = enum { answer, cancel, gone };
    const Capture = struct {
        cancelled_requests: usize = 0,

        fn write(raw: ?*anyopaque, frame: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (std.mem.find(u8, frame, "\"method\":\"$/cancel_request\"") != null) self.cancelled_requests += 1;
        }
    };
    const Answerer = struct {
        waiting: *prompt_test_controls.Gate,
        state: *ServerState,
        session: *ActiveSessionState,
        request: OutboundRequest,
        outcome: Outcome,

        fn run(self: @This()) void {
            self.waiting.awaitReached();
            switch (self.outcome) {
                .answer => handleClientResponse(self.state, self.state.alloc, &.{
                    .id = .{ .integer = @intCast(self.request.id) },
                    .result_raw = "{\"ok\":true}",
                }),
                .cancel => cancelOutboundRequest(self.session, self.request),
                .gone => endClientInput(self.state),
            }
        }
    };
    const kinds = [_]OutboundKind{ .permission, .elicitation, .host_tool, .journal };
    const outcomes = [_]Outcome{ .answer, .cancel, .gone };
    for (kinds) |kind| for (outcomes) |outcome| {
        var test_host = testHost(alloc);
        defer test_host.deinit();
        var capture = Capture{};
        var state = ServerState{
            .alloc = alloc,
            .host = &test_host,
            .writer = jsonrpc.Writer.initCallback(&capture, Capture.write),
        };
        var session: ActiveSessionState = undefined;
        session.client_writer = jsonrpc.Writer.initCallback(&session, forwardToMain);
        try attachOpenerForTest(&session, &state);
        defer releaseTestSession(&state, &session);
        session.outbound = .{};
        defer session.outbound.pending.deinit(alloc);

        var waiting = prompt_test_controls.Gate{};
        prompt_test_controls.outbound_waiting = &waiting;
        defer prompt_test_controls.outbound_waiting = null;

        const request = (try beginOutboundRequest(&session, kind)).?;
        const answerer = try std.Thread.spawn(.{}, Answerer.run, .{Answerer{
            .waiting = &waiting,
            .state = &state,
            .session = &session,
            .request = request,
            .outcome = outcome,
        }});
        const answered = awaitOutboundResponse(&session, request, kind);
        waiting.mark();
        answerer.join();
        var response = answered orelse return error.TestExpectedEqual;
        defer response.deinit(alloc);
        switch (outcome) {
            .answer => try std.testing.expectEqualStrings("{\"ok\":true}", response.result_json.?),
            .cancel => {
                try std.testing.expect(response.cancelled);
                try std.testing.expectEqual(@as(usize, 1), capture.cancelled_requests);
            },
            .gone => try std.testing.expect(response.no_client),
        }
    };
}

/// Counts the frames a test writer receives that contain `needle`.
const CountingWriter = struct {
    needle: []const u8,
    count: usize = 0,

    fn write(raw: ?*anyopaque, frame: []const u8) !void {
        const self: *CountingWriter = @ptrCast(@alignCast(raw.?));
        if (std.mem.find(u8, frame, self.needle) != null) self.count += 1;
    }
};

/// Opens a session on `state` for the hand-off tests.
fn openHandOffTestSession(state: *ServerState, session_id: []const u8) !*ActiveSessionState {
    const alloc = state.alloc;
    state.host.cfg.provider_set = @import("../core/gateway/provider_set.zig").gateway_only(test_builtin_gateway.provider_bundle);
    const id = try alloc.dupe(u8, session_id);
    const model = try alloc.dupe(u8, "test-model");
    return openSession(state, .{
        .session_id = id,
        .model = model,
        .mode = "normal",
        .workspace_root = &.{},
        .api_key = &.{},
        .agent_step_limit = 4,
        .max_tool_result_bytes = 1024 * 1024,
        .fast_mode = false,
        .effort = .auto,
        .first_call_tool_choice = .auto,
        .permission_mode = .ask,
        .permission_rules = .{},
        .session_rt = .{ .max_history_turns = 8 },
        .cancel_flag = std.atomic.Value(bool).init(false),
        .pending_prompt_id = null,
    }, null);
}

const HandOffRun = struct {
    fn run(state: *ServerState, session: *ActiveSessionState, moved: *bool) void {
        moved.* = leaveMember(state, session, .left);
    }
};

const JoinRun = struct {
    fn run(session: *ActiveSessionState, joiner: *ServerState, joined: *bool) void {
        var audience = lockAudience(session);
        defer audience.unlock();
        _ = listMemberLocked(session, try newMember(joiner.host.alloc, joiner));
        joined.* = true;
    }
};

const PermissionWriteRun = struct {
    fn run(session: *ActiveSessionState, request: OutboundRequest, alloc: Allocator, write_error: *?anyerror) void {
        writeRequestToMain(session, request, alloc, "session/request_permission", "{}") catch |err| {
            write_error.* = err;
        };
    }
};

test "a permission write parked while the opener leaves reaches no client, and the turn asks the new main" {
    const alloc = std.testing.allocator;
    var test_host = testHost(alloc);
    defer test_host.deinit();
    var leaver_frames = CountingWriter{ .needle = "session/request_permission" };
    var state = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&leaver_frames, CountingWriter.write),
        .connection_id = 1,
        .launch = .{ .root = try alloc.dupe(u8, "/tmp/workspace") },
    };
    defer state.deinit();
    var follower_frames = CountingWriter{ .needle = "session/request_permission" };
    var follower = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&follower_frames, CountingWriter.write),
        .connection_id = 2,
        .launch = .{ .root = try alloc.dupe(u8, "/tmp/workspace") },
    };
    defer follower.deinit();
    const session = try openHandOffTestSession(&state, "session_permission_held");
    try joinMemberForTest(session, &follower);

    const request = beginPermissionRequest(session) orelse return error.TestExpectedEqual;
    var gate = prompt_test_controls.Gate{};
    prompt_test_controls.permission_write_gate = &gate;
    defer prompt_test_controls.permission_write_gate = null;
    var write_error: ?anyerror = null;
    const writing = try std.Thread.spawn(.{}, PermissionWriteRun.run, .{ session, request, alloc, &write_error });
    gate.awaitReached();

    const moved = leaveMember(&state, session, .left);
    gate.release();
    writing.join();

    try std.testing.expect(moved);
    try std.testing.expect(write_error != null and write_error.? == error.MainChanged);
    try std.testing.expectEqual(@as(usize, 0), leaver_frames.count);
    try std.testing.expectEqual(@as(usize, 0), follower_frames.count);

    const again = beginPermissionRequest(session) orelse return error.TestExpectedEqual;
    try writeRequestToMain(session, again, alloc, "session/request_permission", "{}");
    try std.testing.expectEqual(@as(usize, 0), leaver_frames.count);
    try std.testing.expectEqual(@as(usize, 1), follower_frames.count);

    cancelPermissionRequest(session, again);
    var answered_again = awaitOutboundResponse(session, again, .permission) orelse return error.TestExpectedEqual;
    defer answered_again.deinit(alloc);
    var answered_first = awaitOutboundResponse(session, request, .permission) orelse return error.TestExpectedEqual;
    defer answered_first.deinit(alloc);
    try std.testing.expect(answered_first.moved);
}

const LeaveRun = struct {
    fn run(state: *ServerState, session: *ActiveSessionState, moved: *bool) void {
        moved.* = leaveMember(state, session, .left);
    }
};

const MemberJoinRun = struct {
    fn run(session: *ActiveSessionState, joiner: *ServerState, member: *Member, joined: *bool) void {
        var audience = lockAudience(session);
        defer audience.unlock();
        joined.* = listMemberLocked(session, member);
        if (joined.*) addMembershipLocked(joiner, session, member);
    }
};

const HoldReadRun = struct {
    fn run(session: *ActiveSessionState, gate: *prompt_test_controls.Gate, read: *ConnectionId) void {
        const held = holdMain(session);
        defer held.drop();
        gate.park();
        read.* = held.connection_id;
    }
};

/// Whether the connection `owner_id` has an outbound request that somebody already answered.
fn anyOutboundAnsweredFor(session: *ActiveSessionState, owner_id: ConnectionId) bool {
    const io = io_mod.getIo();
    session.outbound.mutex.lockUncancelable(io);
    defer session.outbound.mutex.unlock(io);
    var pending = session.outbound.pending.iterator();
    while (pending.next()) |entry| {
        if (entry.key_ptr.connection == owner_id and entry.value_ptr.response != null) return true;
    }
    return false;
}

test "a main's leave parked after its record leaves answers the owed permission only when it finishes" {
    const alloc = std.testing.allocator;
    var test_host = testHost(alloc);
    defer test_host.deinit();
    var leaver_frames = CountingWriter{ .needle = "session/request_permission" };
    var state = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&leaver_frames, CountingWriter.write),
        .connection_id = 1,
        .launch = .{ .root = try alloc.dupe(u8, "/tmp/workspace") },
    };
    defer state.deinit();
    var follower = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(null, DiscardFrames.write),
        .connection_id = 2,
        .launch = .{ .root = try alloc.dupe(u8, "/tmp/workspace") },
    };
    defer follower.deinit();
    const session = try openHandOffTestSession(&state, "session_leave_parked");
    try joinMemberForTest(session, &follower);
    const request = beginPermissionRequest(session) orelse return error.TestExpectedEqual;

    var gate = prompt_test_controls.Gate{};
    prompt_test_controls.leave_gate = &gate;
    defer prompt_test_controls.leave_gate = null;
    var moved = false;
    const leaving = try std.Thread.spawn(.{}, LeaveRun.run, .{ &state, session, &moved });
    gate.awaitReached();

    const audience_free = session.audience_mutex.tryLock();
    if (audience_free) session.audience_mutex.unlock(io_mod.getIo());
    const follower_is_main = mainLocked(session).?.connection_id == follower.connection_id;
    const answered_while_parked = anyOutboundAnsweredFor(session, state.connection_id);

    gate.release();
    leaving.join();

    try std.testing.expect(!audience_free);
    try std.testing.expect(follower_is_main);
    try std.testing.expect(!answered_while_parked);
    try std.testing.expect(moved);
    var answer = awaitOutboundResponse(session, request, .permission) orelse return error.TestExpectedEqual;
    defer answer.deinit(alloc);
    try std.testing.expect(answer.moved);
}

test "a join during a parked leave waits for it, and is listed after the new main" {
    const alloc = std.testing.allocator;
    var test_host = testHost(alloc);
    defer test_host.deinit();
    var state = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(null, DiscardFrames.write),
        .connection_id = 1,
        .launch = .{ .root = try alloc.dupe(u8, "/tmp/workspace") },
    };
    defer state.deinit();
    var follower = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(null, DiscardFrames.write),
        .connection_id = 2,
        .launch = .{ .root = try alloc.dupe(u8, "/tmp/workspace") },
    };
    defer follower.deinit();
    var joiner = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(null, DiscardFrames.write),
        .connection_id = 3,
        .launch = .{ .root = try alloc.dupe(u8, "/tmp/workspace") },
    };
    defer joiner.deinit();
    const session = try openHandOffTestSession(&state, "session_join_parked");
    try joinMemberForTest(session, &follower);
    try reserveMemberLocked(session, alloc);
    try joiner.memberships.ensureUnusedCapacity(alloc, 1);
    const joiner_member = try newMember(alloc, &joiner);

    var gate = prompt_test_controls.Gate{};
    prompt_test_controls.leave_gate = &gate;
    defer prompt_test_controls.leave_gate = null;
    var moved = false;
    const leaving = try std.Thread.spawn(.{}, LeaveRun.run, .{ &state, session, &moved });
    gate.awaitReached();

    const audience_free = session.audience_mutex.tryLock();
    if (audience_free) session.audience_mutex.unlock(io_mod.getIo());
    var joined = false;
    const joining = try std.Thread.spawn(.{}, MemberJoinRun.run, .{ session, &joiner, joiner_member, &joined });
    gate.release();
    leaving.join();
    joining.join();

    try std.testing.expect(!audience_free);
    try std.testing.expect(moved);
    try std.testing.expect(joined);
    try std.testing.expect(mainLocked(session).?.connection_id == follower.connection_id);
    try std.testing.expectEqual(@as(usize, 2), session.members.items.len);
    try std.testing.expect(session.members.items[1] == joiner_member);
}

test "a session request that reads its target before a leave and its follow after it still finds the session" {
    const alloc = std.testing.allocator;
    var test_host = testHost(alloc);
    defer test_host.deinit();
    var state = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(null, DiscardFrames.write),
        .connection_id = 1,
        .launch = .{ .root = try alloc.dupe(u8, "/tmp/workspace") },
    };
    defer state.deinit();
    var follower = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(null, DiscardFrames.write),
        .connection_id = 2,
        .launch = .{ .root = try alloc.dupe(u8, "/tmp/workspace") },
    };
    defer follower.deinit();
    const session = try openHandOffTestSession(&state, "session_target_leave");
    try joinMemberForTest(session, &follower);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, "{\"sessionId\":\"session_target_leave\"}", .{});
    defer parsed.deinit();
    var gate = prompt_test_controls.Gate{};
    prompt_test_controls.target_decided_gate = &gate;
    defer prompt_test_controls.target_decided_gate = null;
    var found: ?*ActiveSessionState = null;
    const targeting = try std.Thread.spawn(.{}, TargetRun.run, .{ &follower, alloc, parsed.value, &found });
    gate.awaitReached();

    const moved = leaveMember(&state, session, .left);
    gate.release();
    targeting.join();

    try std.testing.expect(moved);
    try std.testing.expect(found == session);
}

test "a turn that holds the main record reads its client field after the member left and the frame ended" {
    const alloc = std.testing.allocator;
    var test_host = testHost(alloc);
    defer test_host.deinit();
    var state = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(null, DiscardFrames.write),
        .connection_id = 1,
        .launch = .{ .root = try alloc.dupe(u8, "/tmp/workspace") },
    };
    const session = try openHandOffTestSession(&state, "session_record_read");
    const expected_connection = state.connection_id;

    var gate = prompt_test_controls.Gate{};
    var read: ConnectionId = 0;
    const reading = try std.Thread.spawn(.{}, HoldReadRun.run, .{ session, &gate, &read });
    gate.awaitReached();

    _ = leaveMember(&state, session, .left);
    state.deinit();
    @memset(std.mem.asBytes(&state), 0xaa);
    gate.release();
    reading.join();

    try std.testing.expectEqual(expected_connection, read);
}

const TargetRun = struct {
    fn run(state: *ServerState, alloc: Allocator, root: std.json.Value, found: *?*ActiveSessionState) void {
        found.* = requireParsedSessionTarget(state, alloc, .{ .integer = 7 }, root) catch null;
    }
};

test "ACP a moved request reaches its waiter as moved, not as an answer" {
    const alloc = std.testing.allocator;
    var test_host = testHost(alloc);
    defer test_host.deinit();
    var state = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.init(),
    };
    var session: ActiveSessionState = undefined;
    session.client_writer = jsonrpc.Writer.initCallback(&session, forwardToMain);
    try attachOpenerForTest(&session, &state);
    defer {
        freeMembers(&session, alloc);
        releaseMembershipsForTest(&state);
    }
    session.outbound = .{};
    defer session.outbound.pending.deinit(alloc);

    const request = (try beginOutboundRequest(&session, .host_tool)).?;
    session.outbound.mutex.lockUncancelable(io_mod.getIo());
    session.outbound.pending.getPtr(request).?.response = .{ .moved = true };
    session.outbound.mutex.unlock(io_mod.getIo());

    var response = awaitOutboundResponse(&session, request, .host_tool) orelse return error.TestExpectedEqual;
    defer response.deinit(alloc);
    try std.testing.expect(response.moved);
    try std.testing.expect(!response.no_client);
    try std.testing.expect(!response.cancelled);
}

test "ACP legacy URL publication owns partial allocations" {
    const Case = struct {
        fn run(alloc: Allocator) !void {
            var test_host = testHost(alloc);
            defer test_host.deinit();
            var state = ServerState{
                .alloc = alloc,
                .host = &test_host,
                .writer = jsonrpc.Writer.init(),
            };
            defer state.deinit();
            const reserved = try reserveLegacyUrl(
                try pendingMember(&state),
                .{
                    .wire = .legacy_mcp_2025_11,
                    .server_name = "fixture",
                    .operation = .{ .tools_call = "echo" },
                    .connection_generation = 1,
                    .client_generation = 1,
                    .catalog_generation = 1,
                    .request_generation = 1,
                    .auth_generation = 1,
                    .deadline_ms = 1,
                },
                "legacy-id",
                "acp-id",
                "session-id",
                "tool-call-id",
            );
            try std.testing.expect(reserved);
        }
    };
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, Case.run, .{});
}

test "ACP legacy URL state requires consent and completion" {
    const alloc = std.testing.allocator;
    var test_host = testHost(alloc);
    defer test_host.deinit();
    var state = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.init(),
    };
    defer state.deinit();
    const origin = tool_mcp_runtime.InputOrigin{
        .wire = .legacy_mcp_2025_11,
        .server_name = "fixture",
        .operation = .{ .tools_call = "echo" },
        .runtime_generation = 1,
        .connection_generation = 1,
        .client_generation = 2,
        .catalog_generation = 3,
        .request_generation = 4,
        .auth_generation = 5,
        .deadline_ms = std.math.maxInt(i64),
    };
    try std.testing.expect(try reserveLegacyUrl(
        try pendingMember(&state),
        origin,
        "early",
        "acp-early",
        "session",
        "call",
    ));
    const sink = legacyUrlCompletionSink(try pendingMember(&state));
    _ = sink.consume(sink.context, .{
        .server_name = "fixture",
        .elicitation_id = "early",
        .runtime_generation = 1,
        .connection_generation = 0,
        .client_generation = 1,
        .auth_generation = 4,
    });
    try std.testing.expectEqual(@as(usize, 1), (try pendingMember(&state)).pending_legacy_urls.items.len);
    try std.testing.expect(!(try pendingMember(&state)).pending_legacy_urls.items[0].completed);
    _ = sink.consume(sink.context, .{
        .server_name = "fixture",
        .elicitation_id = "early",
        .runtime_generation = 2,
        .connection_generation = 1,
        .client_generation = 2,
        .auth_generation = 5,
    });
    try std.testing.expectEqual(@as(usize, 1), (try pendingMember(&state)).pending_legacy_urls.items.len);
    try std.testing.expect(!(try pendingMember(&state)).pending_legacy_urls.items[0].completed);
    _ = sink.consume(sink.context, .{
        .server_name = "fixture",
        .elicitation_id = "early",
        .runtime_generation = 1,
        .connection_generation = 1,
        .client_generation = 2,
        .auth_generation = 5,
    });
    try std.testing.expectEqual(@as(usize, 1), (try pendingMember(&state)).pending_legacy_urls.items.len);
    try std.testing.expect((try pendingMember(&state)).pending_legacy_urls.items[0].completed);
    try std.testing.expect(!(try pendingMember(&state)).pending_legacy_urls.items[0].accepted);
    removeLegacyUrl(try pendingMember(&state), "acp-early");
    try std.testing.expectEqual(@as(usize, 0), (try pendingMember(&state)).pending_legacy_urls.items.len);

    try std.testing.expect(try reserveLegacyUrl(
        try pendingMember(&state),
        origin,
        "late",
        "acp-late",
        "session",
        "call",
    ));
    try std.testing.expectEqual(
        tool_mcp_runtime.LegacyUrlAcceptTransition.awaiting_completion,
        acceptLegacyUrl(try pendingMember(&state), origin, "acp-late"),
    );
    try std.testing.expect((try pendingMember(&state)).pending_legacy_urls.items[0].accepted);
    try std.testing.expect(!(try pendingMember(&state)).pending_legacy_urls.items[0].completed);
    removeLegacyUrl(try pendingMember(&state), "acp-late");

    try std.testing.expect(try reserveLegacyUrl(
        try pendingMember(&state),
        origin,
        "publish",
        "acp-publish",
        "session",
        "call",
    ));
    try std.testing.expectEqual(
        tool_mcp_runtime.LegacyUrlAcceptTransition.awaiting_completion,
        acceptLegacyUrl(try pendingMember(&state), origin, "acp-publish"),
    );
    const publication = sink.consume(sink.context, .{
        .server_name = "fixture",
        .elicitation_id = "publish",
        .runtime_generation = 1,
        .connection_generation = 1,
        .client_generation = 2,
        .auth_generation = 5,
    }).consumed.?;
    defer alloc.free(publication);
    try std.testing.expectEqualStrings("acp-publish", publication);
    try std.testing.expectEqual(@as(usize, 0), (try pendingMember(&state)).pending_legacy_urls.items.len);

    try std.testing.expect(try reserveLegacyUrl(
        try pendingMember(&state),
        origin,
        "old-a",
        "acp-old-a",
        "session",
        "call",
    ));
    try std.testing.expect(try reserveLegacyUrl(
        try pendingMember(&state),
        origin,
        "old-b",
        "acp-old-b",
        "session",
        "call",
    ));
    var refreshed_catalog = origin;
    refreshed_catalog.catalog_generation = 4;
    try std.testing.expect(!try reserveLegacyUrl(
        try pendingMember(&state),
        refreshed_catalog,
        "old-a",
        "acp-old-a-refresh",
        "session",
        "call",
    ));
    try std.testing.expectEqual(@as(usize, 2), (try pendingMember(&state)).pending_legacy_urls.items.len);
    var recovered = origin;
    recovered.runtime_generation = 2;
    recovered.catalog_generation = 4;
    try std.testing.expect(try reserveLegacyUrl(
        try pendingMember(&state),
        recovered,
        "old-a",
        "acp-new",
        "session",
        "call",
    ));
    try std.testing.expectEqual(@as(usize, 1), (try pendingMember(&state)).pending_legacy_urls.items.len);
    try std.testing.expectEqual(@as(u64, 2), (try pendingMember(&state)).pending_legacy_urls.items[0].binding.runtime_generation);
    try std.testing.expectEqual(@as(u64, 1), (try pendingMember(&state)).pending_legacy_urls.items[0].binding.connection_generation);
    removeLegacyUrl(try pendingMember(&state), "acp-old-a");
    try std.testing.expectEqual(@as(usize, 1), (try pendingMember(&state)).pending_legacy_urls.items.len);
    try std.testing.expectEqualStrings("acp-new", (try pendingMember(&state)).pending_legacy_urls.items[0].acp_id);
    removeLegacyUrl(try pendingMember(&state), "acp-new");
}

test "ACP ultrafast writes preserve v2 baselines across other preference changes" {
    const alloc = testing_allocator.no_resize;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var store = try session_adapter.Store.open(alloc, home);
    defer store.deinit(alloc);
    const v2 = try session_adapter.Session.create(alloc, &store, home, .acp, .{
        .preferences = .{ .model = @constCast("old-model"), .effort = .auto, .fast_mode = false },
        .language = types.ConversationLanguage.default(),
        .permission_state = .{},
    });
    defer v2.close();
    var active: ActiveSessionState = undefined;
    active.client_writer = jsonrpc.Writer.initCallback(&active, forwardToMain);
    active.session_write_mutex = .init;
    active.wasm_state = null;
    active.v2 = v2;
    active.model = try alloc.dupe(u8, "old-model");
    defer alloc.free(active.model);
    active.provider = .gateway;
    active.effort = .auto;
    active.fast_mode = false;
    active.ultrafast_mode = false;
    try commitActiveSessionUltrafast(alloc, &active, true);
    try std.testing.expect(active.ultrafast_mode);
    active.ultrafast_mode = false;
    try commitActiveSessionModel(alloc, &active, "new-model");
    try commitActiveSessionProvider(alloc, &active, .codex, "child-model");
    try commitActiveSessionEffort(alloc, &active, .literal("high"));
    {
        var preferences = try v2.currentPreferences(alloc);
        defer preferences.deinit(alloc);
        try std.testing.expect(preferences.ultrafast_mode);
        try std.testing.expectEqualStrings("child-model", preferences.model);
        try std.testing.expectEqual(model_provider.ProviderId.codex, preferences.provider);
        try std.testing.expectEqualStrings("high", preferences.effort.label());
    }
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, commitActiveSessionUltrafast(failing.allocator(), &active, false));
    try std.testing.expect(!active.ultrafast_mode);
    {
        var preferences = try v2.currentPreferences(alloc);
        defer preferences.deinit(alloc);
        try std.testing.expect(preferences.ultrafast_mode);
    }
    try commitActiveSessionUltrafast(alloc, &active, false);
    var preferences = try v2.currentPreferences(alloc);
    defer preferences.deinit(alloc);
    try std.testing.expect(!preferences.ultrafast_mode);
    try std.testing.expect(!active.ultrafast_mode);
}

test "ACP model commits honor the active session write boundary" {
    const alloc = std.testing.allocator;
    var active: ActiveSessionState = undefined;
    active.client_writer = jsonrpc.Writer.initCallback(&active, forwardToMain);
    active.v2 = null;
    active.session_write_mutex = .init;
    active.model = try alloc.dupe(u8, "old-model");
    defer alloc.free(active.model);

    const Worker = struct {
        alloc: Allocator,
        active: *ActiveSessionState,
        started: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            self.started.store(true, .seq_cst);
            commitActiveSessionModel(
                self.alloc,
                self.active,
                "new-model",
            ) catch |err| {
                self.failure = err;
            };
            self.done.store(true, .seq_cst);
        }
    };
    var worker = Worker{
        .alloc = alloc,
        .active = &active,
    };
    active.session_write_mutex.lockUncancelable(io_mod.getIo());
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    while (!worker.started.load(.seq_cst)) std.Thread.yield() catch {};
    for (0..100) |_| std.Thread.yield() catch {};
    const blocked_at_boundary = !worker.done.load(.seq_cst);
    active.session_write_mutex.unlock(io_mod.getIo());
    thread.join();

    try std.testing.expect(blocked_at_boundary);
    try std.testing.expect(worker.done.load(.seq_cst));
    try std.testing.expectEqual(
        error.SessionPersistenceUnavailable,
        worker.failure.?,
    );
}

/// A session with its own Codex credential for the credential tests; free
/// it with `freeSessionCredential`.
/// A server with only what a credential change reads: its allocator, the
/// authority lock, and the web search settings.
fn testCredentialServer(host: *Host, alloc: Allocator) ServerState {
    const Discard = struct {
        fn write(_: ?*anyopaque, _: []const u8) !void {}
    };
    host.subagent_authority_mutex = .init;
    host.cfg.gateway_retry_count = 0;
    host.cfg.gateway_chat_url = "";
    return .{
        .alloc = alloc,
        .host = host,
        .writer = jsonrpc.Writer.initCallback(null, Discard.write),
    };
}

fn testCodexSession(state: *ServerState, session: *ActiveSessionState, alloc: Allocator, token: []const u8) !void {
    session.* = undefined;
    session.client_writer = jsonrpc.Writer.initCallback(session, forwardToMain);
    // Publishing locks the settings mutex and checks the provider, so both
    // must be set; `undefined` would leave them as garbage.
    session.settings_mutex = .init;
    session.provider = .codex;
    try attachOpenerForTest(session, state);
    session.model = &.{};
    session.web_search_runtime = web_search_runtime.Runtime.init(.{});
    session.api_key = try alloc.dupe(u8, token);
    errdefer secret.zeroAndFree(alloc, @constCast(session.api_key));
    session.account_id = try alloc.dupe(u8, "acct-1");
    session.gateway_team = null;
    session.credential_source = .chatgpt_subscription;
    session.credential_refresh_after_ms = 1;
}

test "ACP gives a refreshed Codex token to the session whose turn refreshed it, and no other" {
    const alloc = std.testing.allocator;
    var test_host = testHost(alloc);
    defer test_host.deinit();
    var state = testCredentialServer(&test_host, alloc);
    var refreshing: ActiveSessionState = undefined;
    try testCodexSession(&state, &refreshing, alloc, "stale-token");
    defer releaseTestSession(&state, &refreshing);
    defer freeSessionCredential(alloc, &refreshing);
    var other: ActiveSessionState = undefined;
    try testCodexSession(&state, &other, alloc, "other-token");
    defer releaseTestSession(&state, &other);
    defer freeSessionCredential(alloc, &other);

    var refreshed = credentials.Credential{
        .token = try alloc.dupe(u8, "fresh-token"),
        .source = .chatgpt_subscription,
        .account_id = try alloc.dupe(u8, "acct-1"),
        .refresh_after_ms = 100,
    };
    defer refreshed.deinit(alloc);
    try publishRefreshedCredential(alloc, &refreshing, refreshing.provider, &refreshed, "acct-1", false);

    try std.testing.expectEqualStrings("fresh-token", refreshing.api_key);
    try std.testing.expectEqualStrings("acct-1", refreshing.account_id.?);
    try std.testing.expectEqual(@as(?i64, 100), refreshing.credential_refresh_after_ms);
    try std.testing.expectEqualStrings("other-token", other.api_key);
    try std.testing.expectEqual(@as(?i64, 1), other.credential_refresh_after_ms);
}

test "ACP credential readiness rejects refresh-due access tokens" {
    try std.testing.expect(credentialReadyAt(.chatgpt_subscription, "token", 11, 10));
    try std.testing.expect(!credentialReadyAt(.chatgpt_subscription, "token", 10, 10));
    try std.testing.expect(!credentialReadyAt(.grok_subscription, "token", 1, 10));
    try std.testing.expect(credentialReadyAt(.ai_gateway_api_key, "token", null, 10));
    try std.testing.expect(!credentialReadyAt(.ai_gateway_api_key, "", null, 10));
}

test "ACP rejects a refreshed Gateway login for another team and takes one for the same team" {
    const alloc = std.testing.allocator;
    var test_host = testHost(alloc);
    defer test_host.deinit();
    var state = testCredentialServer(&test_host, alloc);
    var session: ActiveSessionState = undefined;
    try testCodexSession(&state, &session, alloc, "stale-token");
    defer releaseTestSession(&state, &session);
    defer freeSessionCredential(alloc, &session);
    alloc.free(session.account_id.?);
    session.account_id = null;
    session.credential_source = .fx_login;
    session.gateway_team = try alloc.dupe(u8, "team-a");

    var other_team = credentials.Credential{
        .token = try alloc.dupe(u8, "other-token"),
        .source = .fx_login,
        .team_id = try alloc.dupe(u8, "team-b"),
        .refresh_after_ms = 100,
    };
    defer other_team.deinit(alloc);
    try std.testing.expectError(error.CredentialAuthorityChanged, publishRefreshedCredential(alloc, &session, session.provider, &other_team, null, true));
    try std.testing.expectEqualStrings("stale-token", session.api_key);
    try std.testing.expectEqualStrings("team-a", session.gateway_team.?);

    var same_team = credentials.Credential{
        .token = try alloc.dupe(u8, "fresh-token"),
        .source = .fx_login,
        .team_id = try alloc.dupe(u8, "team-a"),
        .refresh_after_ms = 100,
    };
    defer same_team.deinit(alloc);
    try publishRefreshedCredential(alloc, &session, session.provider, &same_team, null, true);
    try std.testing.expectEqualStrings("fresh-token", session.api_key);
    try std.testing.expectEqualStrings("team-a", session.gateway_team.?);
}

test "ACP rejects refreshed Codex tokens for another account" {
    const alloc = std.testing.allocator;
    var test_host = testHost(alloc);
    defer test_host.deinit();
    var state = testCredentialServer(&test_host, alloc);
    var session: ActiveSessionState = undefined;
    try testCodexSession(&state, &session, alloc, "stale-token");
    defer releaseTestSession(&state, &session);
    defer freeSessionCredential(alloc, &session);

    var refreshed = credentials.Credential{
        .token = try alloc.dupe(u8, "wrong-token"),
        .source = .chatgpt_subscription,
        .account_id = try alloc.dupe(u8, "acct-2"),
        .refresh_after_ms = 100,
    };
    defer refreshed.deinit(alloc);
    try std.testing.expectError(error.ChatGptAccountChanged, publishRefreshedCredential(
        alloc,
        &session,
        session.provider,
        &refreshed,
        "acct-2",
        false,
    ));
    try std.testing.expectEqualStrings("stale-token", session.api_key);
}

test "ACP keeps a renewed credential out of a session that changed provider during the turn" {
    const alloc = std.testing.allocator;
    var test_host = testHost(alloc);
    defer test_host.deinit();
    var state = testCredentialServer(&test_host, alloc);
    var session: ActiveSessionState = undefined;
    try testCodexSession(&state, &session, alloc, "stale-token");
    defer releaseTestSession(&state, &session);
    defer freeSessionCredential(alloc, &session);
    const before = session.api_key;

    var refreshed = credentials.Credential{
        .token = try alloc.dupe(u8, "fresh-token"),
        .source = .chatgpt_subscription,
        .account_id = try alloc.dupe(u8, "acct-1"),
        .refresh_after_ms = 100,
    };
    defer refreshed.deinit(alloc);
    // The turn started on the gateway, and the session has since become Codex.
    try std.testing.expectError(error.CredentialAuthorityChanged, publishRefreshedCredential(
        alloc,
        &session,
        .gateway,
        &refreshed,
        "acct-1",
        false,
    ));
    try std.testing.expectEqualStrings(before, session.api_key);
}

/// The gateway the tests below build a provider set from, as `prompt.zig` does.
const test_builtin_gateway = if (builtin.is_test) @import("../builtins/gateway.zig") else struct {};

/// Keeps a test's owner frames out of stdout, which the test runner reads as its protocol.
const DiscardFrames = struct {
    fn write(raw: ?*anyopaque, frame: []const u8) anyerror!void {
        _ = raw;
        _ = frame;
    }
};

fn readTraceFile(alloc: Allocator, trace_path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(std.testing.io, trace_path, .{});
    defer file.close(io_mod.getIo());
    var read_buf: [1024]u8 = undefined;
    var reader = file.reader(std.testing.io, &read_buf);
    return reader.interface.allocRemaining(alloc, std.Io.Limit.limited(64 * 1024));
}

test "a session is in the shared table until it closes, and a follower is dropped with it" {
    const alloc = std.testing.allocator;
    var test_host = testHost(alloc);
    defer test_host.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const folder = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(folder);
    const trace_path = try std.Io.Dir.path.join(alloc, &.{ folder, "trace.log" });
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    const launch_root = try alloc.dupe(u8, "/tmp/workspace");
    var state = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(null, DiscardFrames.write),
        .launch = .{ .root = launch_root },
    };
    defer state.deinit();
    state.host.cfg.provider_set = @import("../core/gateway/provider_set.zig").gateway_only(test_builtin_gateway.provider_bundle);

    const session_id = try alloc.dupe(u8, "session_shared");
    const model = try alloc.dupe(u8, "test-model");
    const session = try openSession(&state, .{
        .session_id = session_id,
        .model = model,
        .mode = "normal",
        .workspace_root = &.{},
        .api_key = &.{},
        .agent_step_limit = 4,
        .max_tool_result_bytes = 1024 * 1024,
        .fast_mode = false,
        .effort = .auto,
        .first_call_tool_choice = .auto,
        .permission_mode = .ask,
        .permission_rules = .{},
        .session_rt = .{ .max_history_turns = 8 },
        .cancel_flag = std.atomic.Value(bool).init(false),
        .pending_prompt_id = null,
    }, null);

    // Open, the session is in the table, where another connection can find it.
    {
        test_host.shared.mutex.lockUncancelable(io_mod.getIo());
        defer test_host.shared.mutex.unlock(io_mod.getIo());
        try std.testing.expect(test_host.shared.findLocked("session_shared") == session);
    }

    // A follower of the session, added by hand, belongs to another connection.
    var follower = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(null, DiscardFrames.write),
    };
    defer follower.deinit();
    try joinMemberForTest(session, &follower);

    // Closing frees the session. The table lets go of it first, and the follower is dropped with it.
    closeSession(&state, session);
    {
        test_host.shared.mutex.lockUncancelable(io_mod.getIo());
        defer test_host.shared.mutex.unlock(io_mod.getIo());
        try std.testing.expect(test_host.shared.findLocked("session_shared") == null);
    }
    try std.testing.expectEqual(@as(usize, 0), test_host.shared.sessions.items.len);

    const trace = try readTraceFile(alloc, trace_path);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "event=follower_dropped session=session_shared reason=session_closed") != null);
}

/// Captures the bytes one connection writes, for the answer tests.
const AnswerWire = struct {
    alloc: Allocator,
    bytes: std.ArrayList(u8) = .empty,

    fn write(raw: ?*anyopaque, frame: []const u8) anyerror!void {
        const self: *AnswerWire = @ptrCast(@alignCast(raw.?));
        try self.bytes.appendSlice(self.alloc, frame);
    }

    fn deinit(self: *AnswerWire) void {
        self.bytes.deinit(self.alloc);
    }
};

/// Opens a session on `owner` and lists `follower` as its member, so an answer
/// can reach either connection.
fn openAnswerSession(alloc: Allocator, owner: *ServerState, follower: *ServerState) !*ActiveSessionState {
    owner.host.cfg.provider_set = @import("../core/gateway/provider_set.zig").gateway_only(test_builtin_gateway.provider_bundle);
    const session = try openSession(owner, .{
        .session_id = try alloc.dupe(u8, "session_answers"),
        .model = try alloc.dupe(u8, "test-model"),
        .mode = "normal",
        .workspace_root = &.{},
        .api_key = &.{},
        .agent_step_limit = 4,
        .max_tool_result_bytes = 1024 * 1024,
        .fast_mode = false,
        .effort = .auto,
        .first_call_tool_choice = .auto,
        .permission_mode = .ask,
        .permission_rules = .{},
        .session_rt = .{ .max_history_turns = 8 },
        .cancel_flag = std.atomic.Value(bool).init(false),
        .pending_prompt_id = null,
    }, null);
    try joinMemberForTest(session, follower);
    return session;
}

/// A turn that a prompt sent by connection `from` started, as the worker holds it.
fn answerTestPrompt(owner: *ServerState, session: *ActiveSessionState, from: ConnectionId) ActivePrompt {
    return .{
        .host = owner.host,
        .session = session,
        .alloc = owner.alloc,
        .msg = .{ .method = "session/prompt", .id = .{ .integer = 7 } },
        .from = from,
        .mode = "normal",
        .permission_mode = .ask,
    };
}

test "a queued prompt's answer is written on the connection that sent it, not on the owner's" {
    const alloc = std.testing.allocator;
    var test_host = testHost(alloc);
    defer test_host.deinit();
    var owner_wire = AnswerWire{ .alloc = alloc };
    defer owner_wire.deinit();
    var follower_wire = AnswerWire{ .alloc = alloc };
    defer follower_wire.deinit();
    const launch_root = try alloc.dupe(u8, "/tmp/workspace");
    var state = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&owner_wire, AnswerWire.write),
        .launch = .{ .root = launch_root },
        .connection_id = 1,
    };
    defer state.deinit();
    var follower = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&follower_wire, AnswerWire.write),
        .connection_id = 2,
    };
    defer follower.deinit();
    const session = try openAnswerSession(alloc, &state, &follower);
    const owner_before = owner_wire.bytes.items.len;

    var active = answerTestPrompt(&state, session, 2);
    publishTurnOutcome(&active, 2, .{ .integer = 7 }, &.{}, .{ .stop_reason = .end_turn }, null);

    try std.testing.expectEqual(owner_before, owner_wire.bytes.items.len);
    try std.testing.expect(std.mem.find(u8, follower_wire.bytes.items, "\"id\":7") != null);
}

test "a steer's outcome is written on the connection that sent the steer" {
    const alloc = std.testing.allocator;
    var test_host = testHost(alloc);
    defer test_host.deinit();
    var owner_wire = AnswerWire{ .alloc = alloc };
    defer owner_wire.deinit();
    var follower_wire = AnswerWire{ .alloc = alloc };
    defer follower_wire.deinit();
    const launch_root = try alloc.dupe(u8, "/tmp/workspace");
    var state = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&owner_wire, AnswerWire.write),
        .launch = .{ .root = launch_root },
        .connection_id = 1,
    };
    defer state.deinit();
    var follower = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&follower_wire, AnswerWire.write),
        .connection_id = 2,
    };
    defer follower.deinit();
    const session = try openAnswerSession(alloc, &state, &follower);
    const owner_before = owner_wire.bytes.items.len;

    var active = answerTestPrompt(&state, session, 1);
    const steers = [_]libfx_steering.Sender{.{ .id = .{ .integer = 9 }, .from = 2 }};
    publishTurnOutcome(&active, 1, null, &steers, .{ .stop_reason = .end_turn }, null);

    try std.testing.expectEqual(owner_before, owner_wire.bytes.items.len);
    try std.testing.expect(std.mem.find(u8, follower_wire.bytes.items, "\"id\":9") != null);
}

test "an answer to a connection that has left the session is dropped, and no connection gets it" {
    const alloc = std.testing.allocator;
    var test_host = testHost(alloc);
    defer test_host.deinit();
    var owner_wire = AnswerWire{ .alloc = alloc };
    defer owner_wire.deinit();
    var follower_wire = AnswerWire{ .alloc = alloc };
    defer follower_wire.deinit();
    const launch_root = try alloc.dupe(u8, "/tmp/workspace");
    var state = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&owner_wire, AnswerWire.write),
        .launch = .{ .root = launch_root },
        .connection_id = 1,
    };
    defer state.deinit();
    var follower = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&follower_wire, AnswerWire.write),
        .connection_id = 2,
    };
    defer follower.deinit();
    const session = try openAnswerSession(alloc, &state, &follower);
    const owner_before = owner_wire.bytes.items.len;
    const follower_before = follower_wire.bytes.items.len;

    // Connection 3 is not a member: it sent the prompt and then left.
    var active = answerTestPrompt(&state, session, 3);
    publishTurnOutcome(&active, 3, .{ .integer = 7 }, &.{}, .{ .stop_reason = .end_turn }, null);
    answerCancelled(state.host, session, 3, .{ .integer = 8 });

    try std.testing.expectEqual(owner_before, owner_wire.bytes.items.len);
    try std.testing.expectEqual(follower_before, follower_wire.bytes.items.len);
}

/// Refuses every write, as a follower whose client has gone does.
fn refuseAnswer(_: ?*anyopaque, _: []const u8) anyerror!void {
    return error.WriteFailed;
}

test "a follower that does not list usage gets its answer without the usage meta, while the owner's has it" {
    const alloc = std.testing.allocator;
    var test_host = testHost(alloc);
    defer test_host.deinit();
    var owner_wire = AnswerWire{ .alloc = alloc };
    defer owner_wire.deinit();
    var follower_wire = AnswerWire{ .alloc = alloc };
    defer follower_wire.deinit();
    const launch_root = try alloc.dupe(u8, "/tmp/workspace");
    var state = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&owner_wire, AnswerWire.write),
        .launch = .{ .root = launch_root },
        .connection_id = 1,
    };
    defer state.deinit();
    var follower = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&follower_wire, AnswerWire.write),
        .connection_id = 2,
    };
    defer follower.deinit();
    state.extensions = sh_fx.Set.initMany(&.{.usage});
    const session = try openAnswerSession(alloc, &state, &follower);
    session.turn_summary = .{};

    var owner_turn = answerTestPrompt(&state, session, 1);
    publishTurnOutcome(&owner_turn, 1, .{ .integer = 7 }, &.{}, .{ .stop_reason = .end_turn }, null);
    var follower_turn = answerTestPrompt(&state, session, 2);
    publishTurnOutcome(&follower_turn, 2, .{ .integer = 8 }, &.{}, .{ .stop_reason = .end_turn }, null);

    try std.testing.expect(std.mem.find(u8, owner_wire.bytes.items, "\"sh.fx/usage\"") != null);
    try std.testing.expect(std.mem.find(u8, follower_wire.bytes.items, "\"id\":8") != null);
    try std.testing.expect(std.mem.find(u8, follower_wire.bytes.items, "sh.fx/usage") == null);
}

test "a write that fails to a follower drops it and is traced, and the owner's turn still answers" {
    const alloc = std.testing.allocator;
    var test_host = testHost(alloc);
    defer test_host.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const folder = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(folder);
    const trace_path = try std.Io.Dir.path.join(alloc, &.{ folder, "trace.log" });
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    var owner_wire = AnswerWire{ .alloc = alloc };
    defer owner_wire.deinit();
    const launch_root = try alloc.dupe(u8, "/tmp/workspace");
    var state = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&owner_wire, AnswerWire.write),
        .launch = .{ .root = launch_root },
        .connection_id = 1,
    };
    defer state.deinit();
    var follower = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(null, refuseAnswer),
        .connection_id = 2,
    };
    defer follower.deinit();
    const session = try openAnswerSession(alloc, &state, &follower);

    var follower_turn = answerTestPrompt(&state, session, 2);
    publishTurnOutcome(&follower_turn, 2, .{ .integer = 7 }, &.{}, .{ .stop_reason = .end_turn }, null);
    try std.testing.expectEqual(@as(usize, 0), followerCountForTest(session));

    var owner_turn = answerTestPrompt(&state, session, 1);
    publishTurnOutcome(&owner_turn, 1, .{ .integer = 8 }, &.{}, .{ .stop_reason = .end_turn }, null);
    try std.testing.expect(std.mem.find(u8, owner_wire.bytes.items, "\"id\":8") != null);

    const trace = try readTraceFile(alloc, trace_path);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "event=answer_dropped session=session_answers request=7 reason=write_failed err=") != null);
    try std.testing.expect(std.mem.find(u8, trace, "event=follower_dropped session=session_answers") != null);
}

test "a next turn that fails to start answers each waiting prompt and steer with its error, on its sender's writer" {
    const alloc = std.testing.allocator;
    var test_host = testHost(alloc);
    defer test_host.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const folder = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(folder);
    const trace_path = try std.Io.Dir.path.join(alloc, &.{ folder, "trace.log" });
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    var owner_wire = AnswerWire{ .alloc = alloc };
    defer owner_wire.deinit();
    var follower_wire = AnswerWire{ .alloc = alloc };
    defer follower_wire.deinit();
    const launch_root = try alloc.dupe(u8, "/tmp/workspace");
    var state = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&owner_wire, AnswerWire.write),
        .launch = .{ .root = launch_root },
        .connection_id = 1,
    };
    defer state.deinit();
    var follower = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&follower_wire, AnswerWire.write),
        .connection_id = 2,
    };
    defer follower.deinit();
    const session = try openAnswerSession(alloc, &state, &follower);

    // A follower's steer, waiting when the next turn failed to start.
    var steers: std.ArrayList(libfx_steering.Steer) = .empty;
    try steers.append(alloc, .{ .text = try alloc.dupe(u8, "steer"), .request_id = .{ .integer = 9 }, .from = 2 });
    var dropped_steers: DroppedWaiting = .{ .input = .{ .steers = steers }, .err = error.OutOfMemory };
    defer dropped_steers.input.deinit(alloc);

    // The owner's queued prompt, waiting the same way.
    const queued_source = jsonrpc.Message{ .id = .{ .integer = 10 }, .method = "session/prompt" };
    const queued_msg = try cloneMessage(alloc, &queued_source);
    var dropped_prompt: DroppedWaiting = .{ .input = .{ .prompt = .{ .msg = queued_msg, .from = 1 } }, .err = error.OutOfMemory };
    defer dropped_prompt.input.deinit(alloc);

    answerDroppedWaiting(session, alloc, &dropped_steers);
    answerDroppedWaiting(session, alloc, &dropped_prompt);

    try std.testing.expect(std.mem.find(u8, follower_wire.bytes.items, "\"id\":9") != null);
    try std.testing.expect(std.mem.find(u8, follower_wire.bytes.items, "\"code\":-32603") != null);
    try std.testing.expect(std.mem.find(u8, follower_wire.bytes.items, "OutOfMemory") != null);
    try std.testing.expect(std.mem.find(u8, owner_wire.bytes.items, "\"id\":10") != null);
    try std.testing.expect(std.mem.find(u8, owner_wire.bytes.items, "\"id\":9") == null);

    const trace = try readTraceFile(alloc, trace_path);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "event=waiting_input_dropped session=session_answers request=9 reason=OutOfMemory") != null);
    try std.testing.expect(std.mem.find(u8, trace, "event=waiting_input_dropped session=session_answers request=10 reason=OutOfMemory") != null);
}

/// A `session/prompt` as a client sends it, for the session tests below.
const session_prompt_params = "{\"sessionId\":\"session_answers\",\"prompt\":[{\"type\":\"text\",\"text\":\"hi\"}]}";

fn sessionPromptTestMessage(id: i64) jsonrpc.Message {
    return .{ .id = .{ .integer = id }, .method = "session/prompt", .params_raw = session_prompt_params };
}

/// A turn's worker as the line sees it. It ends the turn and marks it reapable, then
/// waits in its tail (`pauseAfterTerminalWrite`) when the test gates it.
const ParkedTurn = struct {
    line: *prompt_line.Line,
    active: *ActivePrompt,
    reapable_gate: ?*prompt_test_controls.Gate = null,
    finished: std.atomic.Value(bool) = .init(false),

    fn run(self: *ParkedTurn) void {
        self.line.lock();
        self.line.worker_running = false;
        self.active.reapable.store(true, .seq_cst);
        self.line.unlock();
        if (self.reapable_gate) |gate| gate.mark();
        prompt_test_controls.pauseAfterTerminalWrite();
        self.finished.store(true, .seq_cst);
    }
};

/// One `session/prompt` decided on its own thread, as `decideSessionPrompt` sees it.
const DecisionCall = struct {
    state: *ServerState,
    alloc: Allocator,
    msg: *const jsonrpc.Message,
    session: *ActiveSessionState,
    decision: ?PromptDecision = null,
    failure: ?anyerror = null,
    done: std.atomic.Value(bool) = .init(false),
    /// Marked when the decision returns, if set. A claim that waited has passed its wait, and a
    /// claim that did not wait has settled at once, so a test that waits on either gate ends.
    settled: ?*prompt_test_controls.Gate = null,
    passed: ?*prompt_test_controls.Gate = null,

    fn run(self: *DecisionCall) void {
        defer {
            if (self.settled) |gate| gate.mark();
            if (self.passed) |gate| gate.mark();
        }
        if (decideSessionPrompt(self.state, self.alloc, self.msg, self.session)) |decision| {
            self.decision = decision;
        } else |err| {
            self.failure = err;
        }
        self.done.store(true, .seq_cst);
    }
};

/// One reap of the session's turn, on its own thread.
const ReapCall = struct {
    session: *ActiveSessionState,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *ReapCall) void {
        reapSessionPrompt(self.session, false);
        self.done.store(true, .seq_cst);
    }
};

/// One close of a session, on its own thread.
const CloseCall = struct {
    state: *ServerState,
    session: *ActiveSessionState,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *CloseCall) void {
        closeSession(self.state, self.session);
        self.done.store(true, .seq_cst);
    }
};

/// Joins a test thread that was started, and forgets it, so it is joined once.
fn joinIfStarted(thread: *?std.Thread) void {
    if (thread.*) |running| running.join();
    thread.* = null;
}

/// Gives back a turn that a test's claim took. The test starts no thread for it.
fn giveBackClaim(session: *ActiveSessionState, turn: *ActivePrompt) void {
    session.waiting_prompts.lock();
    if (session.prompt == turn) session.prompt = null;
    session.waiting_prompts.worker_running = false;
    session.waiting_prompts.unlock();
    freeActivePrompt(turn);
}

test "a prompt that arrives after the close has begun is refused, and starts no turn" {
    const alloc = std.testing.allocator;
    var test_host = testHost(alloc);
    defer test_host.deinit();
    var owner_wire = AnswerWire{ .alloc = alloc };
    defer owner_wire.deinit();
    var follower_wire = AnswerWire{ .alloc = alloc };
    defer follower_wire.deinit();
    const launch_root = try alloc.dupe(u8, "/tmp/workspace");
    var state = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&owner_wire, AnswerWire.write),
        .launch = .{ .root = launch_root },
        .connection_id = 1,
    };
    defer state.deinit();
    var follower = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&follower_wire, AnswerWire.write),
        .connection_id = 2,
    };
    defer follower.deinit();
    const session = try openAnswerSession(alloc, &state, &follower);

    beginClose(session);
    const msg = sessionPromptTestMessage(7);
    // The decision alone: a claim here would start a worker that a test cannot run,
    // so a claimed turn is given back instead.
    switch (try decideSessionPrompt(&state, alloc, &msg, session)) {
        .refused => try answerSessionRefused(&state, alloc, msg.id, session.session_id),
        .claimed => |turn| {
            giveBackClaim(session, turn);
            return error.TestUnexpectedResult;
        },
        .delivered => return error.TestUnexpectedResult,
    }

    try std.testing.expect(session.prompt == null);
    try std.testing.expect(!session.waiting_prompts.worker_running);
    try std.testing.expect(std.mem.find(u8, owner_wire.bytes.items, "\"code\":-32002") != null);
}

test "a claim waits while a finished turn is being joined, and claims the slot only after the join" {
    const alloc = std.testing.allocator;
    var test_host = testHost(alloc);
    defer test_host.deinit();
    var owner_wire = AnswerWire{ .alloc = alloc };
    defer owner_wire.deinit();
    var follower_wire = AnswerWire{ .alloc = alloc };
    defer follower_wire.deinit();
    const launch_root = try alloc.dupe(u8, "/tmp/workspace");
    var state = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&owner_wire, AnswerWire.write),
        .launch = .{ .root = launch_root },
        .connection_id = 1,
    };
    defer state.deinit();
    var follower = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&follower_wire, AnswerWire.write),
        .connection_id = 2,
    };
    defer follower.deinit();
    const session = try openAnswerSession(alloc, &state, &follower);
    const line = &session.waiting_prompts;

    var tail_gate = prompt_test_controls.Gate{};
    var reap_gate = prompt_test_controls.Gate{};
    var join_settled = prompt_test_controls.Gate{};
    var join_passed = prompt_test_controls.Gate{};
    prompt_test_controls.tail_gate = &tail_gate;
    prompt_test_controls.reap_gate = &reap_gate;
    prompt_test_controls.join_settled = &join_settled;
    prompt_test_controls.join_passed = &join_passed;
    defer {
        prompt_test_controls.tail_gate = null;
        prompt_test_controls.reap_gate = null;
        prompt_test_controls.join_settled = null;
        prompt_test_controls.join_passed = null;
    }

    // The first turn has ended: its worker is reapable, and it parks in its tail.
    const first_msg = sessionPromptTestMessage(1);
    const first = try alloc.create(ActivePrompt);
    first.* = .{
        .host = state.host,
        .session = session,
        .alloc = alloc,
        .msg = try cloneMessage(alloc, &first_msg),
        .from = state.connection_id,
        .mode = session.mode,
        .permission_mode = session.permission_mode,
    };
    line.lock();
    session.prompt = first;
    line.worker_running = true;
    line.unlock();
    var parked = ParkedTurn{ .line = line, .active = first };
    first.thread = try std.Thread.spawn(.{}, ParkedTurn.run, .{&parked});
    tail_gate.awaitReached();

    const reaper_msg = sessionPromptTestMessage(2);
    const waiter_msg = sessionPromptTestMessage(3);
    var reaper = DecisionCall{ .state = &state, .alloc = alloc, .msg = &reaper_msg, .session = session };
    // A claim that does not wait marks both gates when it returns, so a bypass of the join wait
    // fails the assertion below and does not leave the test waiting on `join_settled`.
    var waiter = DecisionCall{ .state = &state, .alloc = alloc, .msg = &waiter_msg, .session = session, .settled = &join_settled, .passed = &join_passed };
    var reaper_thread: ?std.Thread = null;
    var waiter_thread: ?std.Thread = null;
    // Runs last: both requests end, and a claim the test took is given back.
    defer {
        joinIfStarted(&waiter_thread);
        joinIfStarted(&reaper_thread);
        for ([_]*const DecisionCall{ &reaper, &waiter }) |call| {
            if (call.decision) |decision| switch (decision) {
                .claimed => |turn| giveBackClaim(session, turn),
                else => {},
            };
        }
    }
    // Runs first on a failure, so the parked threads can end.
    defer {
        reap_gate.release();
        tail_gate.release();
    }

    // The first request reaps the turn: it takes the turn out of the slot, marks it
    // joining, and parks before the join.
    reaper_thread = try std.Thread.spawn(.{}, DecisionCall.run, .{&reaper});
    reap_gate.awaitReached();
    line.lock();
    const taken = session.prompt == null and line.joining;
    line.unlock();
    try std.testing.expect(taken);

    // A second request arrives during the join. The join cannot end while the parked
    // tail is held, so the second request cannot have decided yet.
    waiter_thread = try std.Thread.spawn(.{}, DecisionCall.run, .{&waiter});
    reap_gate.release();
    // The claim has settled: it waits for the join, or it has passed its wait.
    join_settled.awaitReached();
    try std.testing.expect(!join_passed.hasReached());
    tail_gate.release();
    joinIfStarted(&reaper_thread);
    joinIfStarted(&waiter_thread);

    try std.testing.expect(parked.finished.load(.seq_cst));
    var claims: usize = 0;
    var delivered: usize = 0;
    for ([_]*const DecisionCall{ &reaper, &waiter }) |call| {
        if (call.failure) |err| return err;
        switch (call.decision orelse return error.TestUnexpectedResult) {
            .claimed => claims += 1,
            .delivered => |outcome| switch (outcome) {
                .in_progress => delivered += 1,
                else => return error.TestUnexpectedResult,
            },
            .refused => return error.TestUnexpectedResult,
        }
    }
    // Exactly one request claims the turn, and the other is delivered into it.
    try std.testing.expectEqual(@as(usize, 1), claims);
    try std.testing.expectEqual(@as(usize, 1), delivered);
}

test "a reap that finds a join under way waits for it, and joins nothing once the turn is taken" {
    const alloc = std.testing.allocator;
    var test_host = testHost(alloc);
    defer test_host.deinit();
    var owner_wire = AnswerWire{ .alloc = alloc };
    defer owner_wire.deinit();
    var follower_wire = AnswerWire{ .alloc = alloc };
    defer follower_wire.deinit();
    const launch_root = try alloc.dupe(u8, "/tmp/workspace");
    var state = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&owner_wire, AnswerWire.write),
        .launch = .{ .root = launch_root },
        .connection_id = 1,
    };
    defer state.deinit();
    var follower = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&follower_wire, AnswerWire.write),
        .connection_id = 2,
    };
    defer follower.deinit();
    const session = try openAnswerSession(alloc, &state, &follower);
    const line = &session.waiting_prompts;

    var reap_gate = prompt_test_controls.Gate{};
    var ready = prompt_test_controls.Gate{};
    var join_settled = prompt_test_controls.Gate{};
    var join_passed = prompt_test_controls.Gate{};
    prompt_test_controls.reap_gate = &reap_gate;
    prompt_test_controls.join_settled = &join_settled;
    prompt_test_controls.join_passed = &join_passed;
    defer {
        prompt_test_controls.reap_gate = null;
        prompt_test_controls.join_settled = null;
        prompt_test_controls.join_passed = null;
    }

    // A turn whose worker has ended, so the turn is reapable.
    const first_msg = sessionPromptTestMessage(1);
    const first = try alloc.create(ActivePrompt);
    first.* = .{
        .host = state.host,
        .session = session,
        .alloc = alloc,
        .msg = try cloneMessage(alloc, &first_msg),
        .from = state.connection_id,
        .mode = session.mode,
        .permission_mode = session.permission_mode,
    };
    line.lock();
    session.prompt = first;
    line.worker_running = true;
    line.unlock();
    var ended = ParkedTurn{ .line = line, .active = first, .reapable_gate = &ready };
    first.thread = try std.Thread.spawn(.{}, ParkedTurn.run, .{&ended});
    ready.awaitReached();

    var first_reap = ReapCall{ .session = session };
    var second_reap = ReapCall{ .session = session };
    var first_thread: ?std.Thread = null;
    var second_thread: ?std.Thread = null;
    // Runs last: both reaps end before the test does.
    defer {
        joinIfStarted(&second_thread);
        joinIfStarted(&first_thread);
    }
    // Runs first on a failure, so a parked reap can end.
    defer reap_gate.release();

    // The first reap takes the turn and parks before its join.
    first_thread = try std.Thread.spawn(.{}, ReapCall.run, .{&first_reap});
    reap_gate.awaitReached();
    second_thread = try std.Thread.spawn(.{}, ReapCall.run, .{&second_reap});
    // The second reap has settled: it waits for the join, or it has passed its wait.
    join_settled.awaitReached();
    try std.testing.expect(!join_passed.hasReached());
    reap_gate.release();
    joinIfStarted(&first_thread);
    joinIfStarted(&second_thread);

    try std.testing.expect(second_reap.done.load(.seq_cst));
    try std.testing.expect(session.prompt == null);
    try std.testing.expect(!line.joining);
    try std.testing.expect(ended.finished.load(.seq_cst));
}

test "a close waits while a follower holds a use, and frees the session only after the release" {
    const alloc = std.testing.allocator;
    var test_host = testHost(alloc);
    defer test_host.deinit();
    var owner_wire = AnswerWire{ .alloc = alloc };
    defer owner_wire.deinit();
    var follower_wire = AnswerWire{ .alloc = alloc };
    defer follower_wire.deinit();
    const launch_root = try alloc.dupe(u8, "/tmp/workspace");
    var state = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&owner_wire, AnswerWire.write),
        .launch = .{ .root = launch_root },
        .connection_id = 1,
    };
    defer state.deinit();
    var follower = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&follower_wire, AnswerWire.write),
        .connection_id = 2,
    };
    defer follower.deinit();
    const session = try openAnswerSession(alloc, &state, &follower);

    // A follower takes a use while the session is still listed.
    const held = test_host.shared.retain(session.session_id) orelse return error.TestUnexpectedResult;
    var held_live = true;
    var detached = prompt_test_controls.Gate{};
    var uses_ended = prompt_test_controls.Gate{};
    var uses_settled = prompt_test_controls.Gate{};
    var uses_passed = prompt_test_controls.Gate{};
    prompt_test_controls.close_detached_gate = &detached;
    prompt_test_controls.close_uses_gate = &uses_ended;
    prompt_test_controls.uses_settled = &uses_settled;
    prompt_test_controls.uses_passed = &uses_passed;
    defer {
        prompt_test_controls.close_detached_gate = null;
        prompt_test_controls.close_uses_gate = null;
        prompt_test_controls.uses_settled = null;
        prompt_test_controls.uses_passed = null;
    }
    var closer = CloseCall{ .state = &state, .session = session };
    var closer_thread: ?std.Thread = null;
    // Runs last: the close ends before the test does.
    defer joinIfStarted(&closer_thread);
    // Runs second: a use the test still holds is given back, so the close can end.
    defer if (held_live) test_host.shared.release(held);
    // Runs first on a failure: a close parked at a gate goes on.
    defer {
        detached.release();
        uses_ended.release();
    }

    closer_thread = try std.Thread.spawn(.{}, CloseCall.run, .{&closer});
    // The session has left the table, and the close is about to wait for the held use.
    detached.awaitReached();
    detached.release();
    // The close settles in its wait for the held use. It must not pass that wait.
    uses_settled.awaitReached();
    try std.testing.expect(!uses_passed.hasReached());
    try std.testing.expect(!closer.done.load(.seq_cst));

    test_host.shared.release(held);
    held_live = false;
    // With the use released, the close passes the wait and parks before it frees the
    // session.
    uses_ended.awaitReached();
    try std.testing.expect(!closer.done.load(.seq_cst));
    uses_ended.release();
    joinIfStarted(&closer_thread);
    try std.testing.expect(closer.done.load(.seq_cst));
}

test "after a close has taken the session out of the table, retain finds nothing" {
    const alloc = std.testing.allocator;
    var test_host = testHost(alloc);
    defer test_host.deinit();
    var owner_wire = AnswerWire{ .alloc = alloc };
    defer owner_wire.deinit();
    var follower_wire = AnswerWire{ .alloc = alloc };
    defer follower_wire.deinit();
    const launch_root = try alloc.dupe(u8, "/tmp/workspace");
    var state = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&owner_wire, AnswerWire.write),
        .launch = .{ .root = launch_root },
        .connection_id = 1,
    };
    defer state.deinit();
    var follower = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&follower_wire, AnswerWire.write),
        .connection_id = 2,
    };
    defer follower.deinit();
    const session = try openAnswerSession(alloc, &state, &follower);

    var detached = prompt_test_controls.Gate{};
    prompt_test_controls.close_detached_gate = &detached;
    defer prompt_test_controls.close_detached_gate = null;
    var closer = CloseCall{ .state = &state, .session = session };
    var closer_thread: ?std.Thread = null;
    // Runs last: the close ends before the test does.
    defer joinIfStarted(&closer_thread);
    // Runs first on a failure: a close parked at the gate goes on.
    defer detached.release();

    closer_thread = try std.Thread.spawn(.{}, CloseCall.run, .{&closer});
    detached.awaitReached();
    // The close has taken the session out of the table, so no follower can take a use.
    if (test_host.shared.retain(session.session_id)) |found| {
        // Give the use back, so the close can end, and then fail.
        test_host.shared.release(found);
        return error.TestUnexpectedResult;
    }
    detached.release();
    joinIfStarted(&closer_thread);
    try std.testing.expect(closer.done.load(.seq_cst));
}

/// A `session/prompt` that queues behind a running turn (`sh.fx/delivery` = queue).
const queue_session_prompt_params = "{\"sessionId\":\"session_answers\",\"prompt\":[{\"type\":\"text\",\"text\":\"later\"}],\"_meta\":{\"sh.fx/delivery\":\"queue\"}}";
/// A `session/prompt` that steers a running turn (`sh.fx/delivery` = steer).
const steer_session_prompt_params = "{\"sessionId\":\"session_answers\",\"prompt\":[{\"type\":\"text\",\"text\":\"now\"}],\"_meta\":{\"sh.fx/delivery\":\"steer\"}}";

fn queuedTestMessage(id: i64) jsonrpc.Message {
    return .{ .id = .{ .integer = id }, .method = "session/prompt", .params_raw = queue_session_prompt_params };
}

fn steerTestMessage(id: i64) jsonrpc.Message {
    return .{ .id = .{ .integer = id }, .method = "session/prompt", .params_raw = steer_session_prompt_params };
}

/// Whether a prompt's decision claimed the session's turn.
fn isClaim(decision: PromptDecision) bool {
    return switch (decision) {
        .claimed => true,
        else => false,
    };
}

/// Gives back the turns that decisions claimed in a test, so no test leaves a turn in a session.
fn giveBackClaims(session: *ActiveSessionState, calls: []const *const DecisionCall) void {
    for (calls) |call| {
        if (call.decision) |decision| switch (decision) {
            .claimed => |turn| giveBackClaim(session, turn),
            else => {},
        };
    }
}

test "a follower's prompt on an idle session starts a turn on that session, and its answer goes to the follower only" {
    const alloc = std.testing.allocator;
    var test_host = testHost(alloc);
    defer test_host.deinit();
    var owner_wire = AnswerWire{ .alloc = alloc };
    defer owner_wire.deinit();
    var follower_wire = AnswerWire{ .alloc = alloc };
    defer follower_wire.deinit();
    const launch_root = try alloc.dupe(u8, "/tmp/workspace");
    var state = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&owner_wire, AnswerWire.write),
        .launch = .{ .root = launch_root },
        .connection_id = 1,
    };
    defer state.deinit();
    state.host.cfg.minimal_kernel = false;
    var follower = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&follower_wire, AnswerWire.write),
        .connection_id = 2,
    };
    defer follower.deinit();
    follower.host.cfg.minimal_kernel = false;
    const session = try openAnswerSession(alloc, &state, &follower);
    const owner_before = owner_wire.bytes.items.len;

    // The follower's prompt finds the session idle, so it claims the turn. No thread starts here.
    const msg = sessionPromptTestMessage(4);
    var turn: ?*ActivePrompt = null;
    defer if (turn) |claimed| giveBackClaim(session, claimed);
    switch (try decideSessionPrompt(&follower, alloc, &msg, session)) {
        .claimed => |claimed| turn = claimed,
        else => return error.TestUnexpectedResult,
    }
    const won = turn orelse return error.TestUnexpectedResult;

    // The turn runs on the owner's state, and its answer goes to the follower's connection.
    try std.testing.expect(won.session == session);
    try std.testing.expectEqual(@as(ConnectionId, 2), won.from);
    publishTurnOutcome(won, 2, .{ .integer = 4 }, &.{}, .{ .stop_reason = .end_turn }, null);
    try std.testing.expectEqual(owner_before, owner_wire.bytes.items.len);
    try std.testing.expect(std.mem.find(u8, follower_wire.bytes.items, "\"id\":4") != null);
}

test "a follower's queued prompt and steer, sent while the owner's turn runs, are delivered, and the steer's answer goes to the follower" {
    const alloc = std.testing.allocator;
    var test_host = testHost(alloc);
    defer test_host.deinit();
    var owner_wire = AnswerWire{ .alloc = alloc };
    defer owner_wire.deinit();
    var follower_wire = AnswerWire{ .alloc = alloc };
    defer follower_wire.deinit();
    const launch_root = try alloc.dupe(u8, "/tmp/workspace");
    var state = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&owner_wire, AnswerWire.write),
        .launch = .{ .root = launch_root },
        .connection_id = 1,
    };
    defer state.deinit();
    state.host.cfg.minimal_kernel = false;
    var follower = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&follower_wire, AnswerWire.write),
        .connection_id = 2,
    };
    defer follower.deinit();
    follower.host.cfg.minimal_kernel = false;
    const session = try openAnswerSession(alloc, &state, &follower);

    // The owner's prompt claims the turn, which runs until the test ends it.
    const owner_msg = sessionPromptTestMessage(1);
    var turn: ?*ActivePrompt = null;
    defer if (turn) |running| giveBackClaim(session, running);
    switch (try decideSessionPrompt(&state, alloc, &owner_msg, session)) {
        .claimed => |running| turn = running,
        else => return error.TestUnexpectedResult,
    }
    const running = turn orelse return error.TestUnexpectedResult;
    const owner_before = owner_wire.bytes.items.len;

    // The follower queues a prompt and steers the running turn.
    const queue_msg = queuedTestMessage(6);
    switch (try decideSessionPrompt(&follower, alloc, &queue_msg, session)) {
        .delivered => |outcome| switch (outcome) {
            .queued => {},
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
    const steer_msg = steerTestMessage(7);
    switch (try decideSessionPrompt(&follower, alloc, &steer_msg, session)) {
        .delivered => |outcome| switch (outcome) {
            .steered => {},
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }

    // Neither prompt reaches the owner, and the queued prompt waits under the follower's connection.
    try std.testing.expectEqual(owner_before, owner_wire.bytes.items.len);
    {
        const line = &session.waiting_prompts;
        line.lock();
        defer line.unlock();
        try std.testing.expectEqual(@as(usize, 1), line.queue.items.len);
        try std.testing.expectEqual(@as(ConnectionId, 2), line.queue.items[0].from);
    }

    // The turn ends and answers the steer on the follower's writer, and not on the owner's.
    const steers = [_]libfx_steering.Sender{.{ .id = .{ .integer = 7 }, .from = 2 }};
    publishTurnOutcome(running, 1, .{ .integer = 1 }, &steers, .{ .stop_reason = .end_turn }, null);
    try std.testing.expect(std.mem.find(u8, follower_wire.bytes.items, "\"id\":7") != null);
    try std.testing.expectEqual(owner_before, owner_wire.bytes.items.len);

    // With the turn given back, closing the session answers the queued prompt on the follower's writer.
    giveBackClaim(session, running);
    turn = null;
    cancelAndReapPrompt(&state, session);
    try std.testing.expect(std.mem.find(u8, follower_wire.bytes.items, "\"id\":6") != null);
}

test "a follower's $/cancel_request withdraws its own queued prompt, and not the owner's prompt with the same request id" {
    const alloc = std.testing.allocator;
    var test_host = testHost(alloc);
    defer test_host.deinit();
    var owner_wire = AnswerWire{ .alloc = alloc };
    defer owner_wire.deinit();
    var follower_wire = AnswerWire{ .alloc = alloc };
    defer follower_wire.deinit();
    const launch_root = try alloc.dupe(u8, "/tmp/workspace");
    var state = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&owner_wire, AnswerWire.write),
        .launch = .{ .root = launch_root },
        .connection_id = 1,
    };
    defer state.deinit();
    state.host.cfg.minimal_kernel = false;
    var follower = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&follower_wire, AnswerWire.write),
        .connection_id = 2,
    };
    defer follower.deinit();
    follower.host.cfg.minimal_kernel = false;
    const session = try openAnswerSession(alloc, &state, &follower);
    // The follower's list buffer is freed last (defers run in reverse), after the entry is forgotten.

    // The owner's turn runs. The owner and the follower each queue a prompt with request id 5.
    const owner_turn_msg = sessionPromptTestMessage(1);
    var turn: ?*ActivePrompt = null;
    defer if (turn) |running| giveBackClaim(session, running);
    switch (try decideSessionPrompt(&state, alloc, &owner_turn_msg, session)) {
        .claimed => |running| turn = running,
        else => return error.TestUnexpectedResult,
    }
    const running = turn orelse return error.TestUnexpectedResult;
    const owner_queued = queuedTestMessage(5);
    switch (try decideSessionPrompt(&state, alloc, &owner_queued, session)) {
        .delivered => |outcome| switch (outcome) {
            .queued => {},
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
    const follower_queued = queuedTestMessage(5);
    switch (try decideSessionPrompt(&follower, alloc, &follower_queued, session)) {
        .delivered => |outcome| switch (outcome) {
            .queued => {},
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
    const owner_before = owner_wire.bytes.items.len;

    // The follower cancels request 5.
    handleRequestCancellation(&follower, alloc, "{\"requestId\":5}");

    // Only the owner's queued prompt remains, and the follower alone got the cancel answer.
    {
        const line = &session.waiting_prompts;
        line.lock();
        defer line.unlock();
        try std.testing.expectEqual(@as(usize, 1), line.queue.items.len);
        try std.testing.expectEqual(@as(ConnectionId, 1), line.queue.items[0].from);
    }
    try std.testing.expect(std.mem.find(u8, follower_wire.bytes.items, "\"id\":5") != null);
    try std.testing.expect(std.mem.find(u8, follower_wire.bytes.items, "-32800") != null);
    try std.testing.expectEqual(owner_before, owner_wire.bytes.items.len);

    giveBackClaim(session, running);
    turn = null;
}

test "two prompts that arrive together on an idle session start one turn, and the other is delivered into it" {
    const alloc = std.testing.allocator;
    var test_host = testHost(alloc);
    defer test_host.deinit();
    var owner_wire = AnswerWire{ .alloc = alloc };
    defer owner_wire.deinit();
    var follower_wire = AnswerWire{ .alloc = alloc };
    defer follower_wire.deinit();
    const launch_root = try alloc.dupe(u8, "/tmp/workspace");
    var state = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&owner_wire, AnswerWire.write),
        .launch = .{ .root = launch_root },
        .connection_id = 1,
    };
    defer state.deinit();
    state.host.cfg.minimal_kernel = false;
    var follower = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&follower_wire, AnswerWire.write),
        .connection_id = 2,
    };
    defer follower.deinit();
    follower.host.cfg.minimal_kernel = false;
    const session = try openAnswerSession(alloc, &state, &follower);

    // Each prompt decides on its own thread. The owner's parks before the line lock, so the
    // follower's decides while it waits, and both see an idle slot.
    const owner_msg = sessionPromptTestMessage(1);
    const follower_msg = sessionPromptTestMessage(2);
    var owner_call = DecisionCall{ .state = &state, .alloc = alloc, .msg = &owner_msg, .session = session };
    var follower_call = DecisionCall{ .state = &follower, .alloc = alloc, .msg = &follower_msg, .session = session };
    const calls = [_]*const DecisionCall{ &owner_call, &follower_call };
    var owner_thread: ?std.Thread = null;
    var follower_thread: ?std.Thread = null;
    var gate = prompt_test_controls.Gate{};
    prompt_test_controls.decision_gate = &gate;
    defer prompt_test_controls.decision_gate = null;
    // Runs last, after the threads end: every turn a decision claimed is given back.
    defer giveBackClaims(session, &calls);
    defer joinIfStarted(&follower_thread);
    defer joinIfStarted(&owner_thread);
    // Runs first on a failure, so a parked prompt can go on and the threads can end.
    defer gate.release();

    owner_thread = try std.Thread.spawn(.{}, DecisionCall.run, .{&owner_call});
    gate.awaitReached();
    follower_thread = try std.Thread.spawn(.{}, DecisionCall.run, .{&follower_call});
    joinIfStarted(&follower_thread);
    gate.release();
    joinIfStarted(&owner_thread);

    if (owner_call.failure) |err| return err;
    if (follower_call.failure) |err| return err;
    const owner_decision = owner_call.decision orelse return error.TestUnexpectedResult;
    const follower_decision = follower_call.decision orelse return error.TestUnexpectedResult;

    // Exactly one of the two claims the turn, and the claimed turn runs on the owner's state.
    const owner_claims = isClaim(owner_decision);
    try std.testing.expect(owner_claims != isClaim(follower_decision));
    const winner = if (owner_claims) owner_decision else follower_decision;
    const won = switch (winner) {
        .claimed => |turn| turn,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(won.session == session);

    // The other prompt is delivered into that turn, and gets the delivery path's answer on its own writer.
    const loser_state: *ServerState = if (owner_claims) &follower else &state;
    const loser_msg: *const jsonrpc.Message = if (owner_claims) &follower_msg else &owner_msg;
    const loser_decision = if (owner_claims) follower_decision else owner_decision;
    switch (loser_decision) {
        .delivered => |outcome| try answerDelivery(loser_state, alloc, loser_msg, outcome),
        else => return error.TestUnexpectedResult,
    }
    const loser_wire = if (owner_claims) &follower_wire else &owner_wire;
    try std.testing.expect(std.mem.find(u8, loser_wire.bytes.items, "\"code\":-32600") != null);
}

test "a follower's $/cancel_request with its own running prompt's id stops that turn, and the follower gets the cancelled answer" {
    const alloc = std.testing.allocator;
    var test_host = testHost(alloc);
    defer test_host.deinit();
    var owner_wire = AnswerWire{ .alloc = alloc };
    defer owner_wire.deinit();
    var follower_wire = AnswerWire{ .alloc = alloc };
    defer follower_wire.deinit();
    const launch_root = try alloc.dupe(u8, "/tmp/workspace");
    var state = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&owner_wire, AnswerWire.write),
        .launch = .{ .root = launch_root },
        .connection_id = 1,
    };
    defer state.deinit();
    state.host.cfg.minimal_kernel = false;
    var follower = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&follower_wire, AnswerWire.write),
        .connection_id = 2,
    };
    defer follower.deinit();
    follower.host.cfg.minimal_kernel = false;
    const session = try openAnswerSession(alloc, &state, &follower);
    // The list buffer is freed last (defers run in reverse), after the entry is forgotten.

    // The follower's own prompt starts the turn, with request id 4.
    const msg = sessionPromptTestMessage(4);
    var turn: ?*ActivePrompt = null;
    defer if (turn) |claimed| giveBackClaim(session, claimed);
    switch (try decideSessionPrompt(&follower, alloc, &msg, session)) {
        .claimed => |claimed| turn = claimed,
        else => return error.TestUnexpectedResult,
    }
    const running = turn orelse return error.TestUnexpectedResult;
    const owner_before = owner_wire.bytes.items.len;

    // The follower cancels request 4, the prompt its own connection started.
    handleRequestCancellation(&follower, alloc, "{\"requestId\":4}");
    try std.testing.expect(session.turn_cancel.load(.seq_cst));

    // The turn ends with the cancelled answer, which goes to the follower and not to the owner.
    publishTurnOutcome(running, 2, .{ .integer = 4 }, &.{}, .{ .stop_reason = .cancelled }, null);
    try std.testing.expect(std.mem.find(u8, follower_wire.bytes.items, "\"id\":4") != null);
    try std.testing.expect(std.mem.find(u8, follower_wire.bytes.items, "\"stopReason\":\"cancelled\"") != null);
    try std.testing.expectEqual(owner_before, owner_wire.bytes.items.len);

    giveBackClaim(session, running);
    turn = null;
}

test "a follower's $/cancel_request with the same request id number as the owner's running prompt does not stop the owner's turn" {
    const alloc = std.testing.allocator;
    var test_host = testHost(alloc);
    defer test_host.deinit();
    var owner_wire = AnswerWire{ .alloc = alloc };
    defer owner_wire.deinit();
    var follower_wire = AnswerWire{ .alloc = alloc };
    defer follower_wire.deinit();
    const launch_root = try alloc.dupe(u8, "/tmp/workspace");
    var state = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&owner_wire, AnswerWire.write),
        .launch = .{ .root = launch_root },
        .connection_id = 1,
    };
    defer state.deinit();
    state.host.cfg.minimal_kernel = false;
    var follower = ServerState{
        .alloc = alloc,
        .host = &test_host,
        .writer = jsonrpc.Writer.initCallback(&follower_wire, AnswerWire.write),
        .connection_id = 2,
    };
    defer follower.deinit();
    follower.host.cfg.minimal_kernel = false;
    const session = try openAnswerSession(alloc, &state, &follower);
    // The list buffer is freed last (defers run in reverse), after the entry is forgotten.

    // The owner's prompt starts the turn, with request id 1.
    const owner_msg = sessionPromptTestMessage(1);
    var turn: ?*ActivePrompt = null;
    defer if (turn) |claimed| giveBackClaim(session, claimed);
    switch (try decideSessionPrompt(&state, alloc, &owner_msg, session)) {
        .claimed => |claimed| turn = claimed,
        else => return error.TestUnexpectedResult,
    }
    const running = turn orelse return error.TestUnexpectedResult;
    const owner_before = owner_wire.bytes.items.len;
    const follower_before = follower_wire.bytes.items.len;

    // The follower cancels request 1, a number its own connection never sent. The owner's
    // turn is not the follower's, so nothing stops, and nothing is answered.
    handleRequestCancellation(&follower, alloc, "{\"requestId\":1}");
    try std.testing.expect(!session.turn_cancel.load(.seq_cst));
    try std.testing.expect(session.prompt == running);
    try std.testing.expectEqual(owner_before, owner_wire.bytes.items.len);
    try std.testing.expectEqual(follower_before, follower_wire.bytes.items.len);

    giveBackClaim(session, running);
    turn = null;
}

/// Two connections of one process: the owner, which opened the session `session_answers`,
/// and a follower that joined it. The follower's cancel tests share this setup.
const CancelPair = struct {
    owner_wire: AnswerWire,
    follower_wire: AnswerWire,
    host: Host = undefined,
    state: ServerState,
    follower: ServerState,
    session: *ActiveSessionState,

    fn open(self: *CancelPair, alloc: Allocator) !void {
        self.host = testHost(alloc);
        self.owner_wire = .{ .alloc = alloc };
        self.follower_wire = .{ .alloc = alloc };
        self.state = .{
            .alloc = alloc,
            .host = &self.host,
            .writer = jsonrpc.Writer.initCallback(&self.owner_wire, AnswerWire.write),
            .launch = .{ .root = try alloc.dupe(u8, "/tmp/workspace") },
            .connection_id = 1,
        };
        self.host.cfg.minimal_kernel = false;
        self.follower = .{
            .alloc = alloc,
            .host = &self.host,
            .writer = jsonrpc.Writer.initCallback(&self.follower_wire, AnswerWire.write),
            .connection_id = 2,
            .initialized = true,
        };
        self.follower.host.cfg.minimal_kernel = false;
        self.session = try openAnswerSession(alloc, &self.state, &self.follower);
    }

    fn close(self: *CancelPair) void {
        self.follower.deinit();
        self.state.deinit();
        self.host.deinit();
        self.follower_wire.deinit();
        self.owner_wire.deinit();
    }
};

test "a follower's session/cancel request stops the owner's running turn, and the prompt's answer goes to its sender" {
    const alloc = std.testing.allocator;
    var pair: CancelPair = undefined;
    try pair.open(alloc);
    defer pair.close();

    // The owner's prompt starts the turn, with request id 1.
    const owner_msg = sessionPromptTestMessage(1);
    var turn: ?*ActivePrompt = null;
    defer if (turn) |claimed| giveBackClaim(pair.session, claimed);
    switch (try decideSessionPrompt(&pair.state, alloc, &owner_msg, pair.session)) {
        .claimed => |claimed| turn = claimed,
        else => return error.TestUnexpectedResult,
    }
    const running = turn orelse return error.TestUnexpectedResult;
    const owner_before = pair.owner_wire.bytes.items.len;

    // The follower cancels with a request of its own, and gets the answer the owner's cancel gets.
    var cancel_msg = jsonrpc.Message{
        .id = .{ .integer = 9 },
        .method = "session/cancel",
        .params_raw = "{\"sessionId\":\"session_answers\"}",
    };
    try dispatch(&pair.follower, alloc, &cancel_msg);
    try std.testing.expect(pair.session.turn_cancel.load(.seq_cst));
    try std.testing.expect(std.mem.find(u8, pair.follower_wire.bytes.items, "\"id\":9") != null);
    try std.testing.expect(std.mem.find(u8, pair.follower_wire.bytes.items, "\"result\":null") != null);
    try std.testing.expectEqual(owner_before, pair.owner_wire.bytes.items.len);

    // The turn ends cancelled. The prompt's sender, the owner, gets the cancelled answer.
    const follower_before = pair.follower_wire.bytes.items.len;
    publishTurnOutcome(running, 1, .{ .integer = 1 }, &.{}, .{ .stop_reason = .cancelled }, null);
    try std.testing.expect(std.mem.find(u8, pair.owner_wire.bytes.items, "\"stopReason\":\"cancelled\"") != null);
    try std.testing.expectEqual(follower_before, pair.follower_wire.bytes.items.len);

    giveBackClaim(pair.session, running);
    turn = null;
}

test "a follower's session/cancel sends $/cancel_request to the owner's client for the permission request the turn waits for" {
    const alloc = std.testing.allocator;
    var pair: CancelPair = undefined;
    try pair.open(alloc);
    defer pair.close();

    // The owner's turn runs, and it waits for the client's answer to a permission request.
    const owner_msg = sessionPromptTestMessage(1);
    var turn: ?*ActivePrompt = null;
    defer if (turn) |claimed| giveBackClaim(pair.session, claimed);
    switch (try decideSessionPrompt(&pair.state, alloc, &owner_msg, pair.session)) {
        .claimed => |claimed| turn = claimed,
        else => return error.TestUnexpectedResult,
    }
    const running = turn orelse return error.TestUnexpectedResult;
    const permission = beginPermissionRequest(pair.session) orelse return error.TestUnexpectedResult;

    // The follower cancels. The owner's client is told to cancel the permission request.
    var cancel_msg = jsonrpc.Message{
        .id = .{ .integer = 9 },
        .method = "session/cancel",
        .params_raw = "{\"sessionId\":\"session_answers\"}",
    };
    try dispatch(&pair.follower, alloc, &cancel_msg);
    var needle_buf: [40]u8 = undefined;
    const needle = try std.fmt.bufPrint(&needle_buf, "\"requestId\":{d}", .{permission.id});
    try std.testing.expect(std.mem.find(u8, pair.owner_wire.bytes.items, "\"method\":\"$/cancel_request\"") != null);
    try std.testing.expect(std.mem.find(u8, pair.owner_wire.bytes.items, needle) != null);

    // The request ends as cancelled, so the wait ends with a denial.
    try std.testing.expectEqual(types.ToolPermissionDecision.deny, awaitPermissionDecision(pair.session, permission));

    giveBackClaim(pair.session, running);
    turn = null;
}

test "a follower's session/cancel notification stops the owner's running turn, and gets no answer" {
    const alloc = std.testing.allocator;
    var pair: CancelPair = undefined;
    try pair.open(alloc);
    defer pair.close();

    const owner_msg = sessionPromptTestMessage(1);
    var turn: ?*ActivePrompt = null;
    defer if (turn) |claimed| giveBackClaim(pair.session, claimed);
    switch (try decideSessionPrompt(&pair.state, alloc, &owner_msg, pair.session)) {
        .claimed => |claimed| turn = claimed,
        else => return error.TestUnexpectedResult,
    }
    const running = turn orelse return error.TestUnexpectedResult;
    const owner_before = pair.owner_wire.bytes.items.len;
    const follower_before = pair.follower_wire.bytes.items.len;

    // A notification has no id, so the follower gets nothing back, and the turn stops.
    var cancel_note = jsonrpc.Message{
        .id = null,
        .method = "session/cancel",
        .params_raw = "{\"sessionId\":\"session_answers\"}",
    };
    try dispatchNotification(&pair.follower, alloc, &cancel_note);
    try std.testing.expect(pair.session.turn_cancel.load(.seq_cst));
    try std.testing.expectEqual(follower_before, pair.follower_wire.bytes.items.len);
    try std.testing.expectEqual(owner_before, pair.owner_wire.bytes.items.len);

    giveBackClaim(pair.session, running);
    turn = null;
}

test "a session/cancel for a session this connection neither owns nor follows gets -32002 and stops nothing" {
    const alloc = std.testing.allocator;
    var pair: CancelPair = undefined;
    try pair.open(alloc);
    defer pair.close();

    // A third connection of the process, which neither opened nor follows the session.
    var stranger_wire = AnswerWire{ .alloc = alloc };
    defer stranger_wire.deinit();
    var stranger = ServerState{
        .alloc = alloc,
        .host = &pair.host,
        .writer = jsonrpc.Writer.initCallback(&stranger_wire, AnswerWire.write),
        .connection_id = 3,
        .initialized = true,
    };
    stranger.host.cfg.minimal_kernel = false;

    var cancel_msg = jsonrpc.Message{
        .id = .{ .integer = 4 },
        .method = "session/cancel",
        .params_raw = "{\"sessionId\":\"session_answers\"}",
    };
    try dispatch(&stranger, alloc, &cancel_msg);
    try std.testing.expect(std.mem.find(u8, stranger_wire.bytes.items, "\"code\":-32002") != null);
    try std.testing.expect(std.mem.find(u8, stranger_wire.bytes.items, "No active session") != null);
    try std.testing.expect(!pair.session.turn_cancel.load(.seq_cst));
}

test "a follower's cancel on an idle session does not stop the next turn" {
    const alloc = std.testing.allocator;
    var pair: CancelPair = undefined;
    try pair.open(alloc);
    defer pair.close();

    // The cancel arrives while no turn runs. It sets the flag, and the follower gets its answer.
    var cancel_msg = jsonrpc.Message{
        .id = .{ .integer = 9 },
        .method = "session/cancel",
        .params_raw = "{\"sessionId\":\"session_answers\"}",
    };
    try dispatch(&pair.follower, alloc, &cancel_msg);
    try std.testing.expect(pair.session.turn_cancel.load(.seq_cst));
    try std.testing.expect(std.mem.find(u8, pair.follower_wire.bytes.items, "\"id\":9,\"result\":null") != null);

    // The owner's next prompt claims the turn. The claim clears both flags, so the cancel does not reach it.
    const owner_msg = sessionPromptTestMessage(1);
    var turn: ?*ActivePrompt = null;
    defer if (turn) |claimed| giveBackClaim(pair.session, claimed);
    switch (try decideSessionPrompt(&pair.state, alloc, &owner_msg, pair.session)) {
        .claimed => |claimed| turn = claimed,
        else => return error.TestUnexpectedResult,
    }
    const running = turn orelse return error.TestUnexpectedResult;
    try std.testing.expect(!pair.session.turn_cancel.load(.seq_cst));
    try std.testing.expect(!pair.session.cancel_flag.load(.seq_cst));

    // The turn ends normally, and its sender, the owner, gets end_turn.
    publishTurnOutcome(running, 1, .{ .integer = 1 }, &.{}, .{ .stop_reason = .end_turn }, null);
    try std.testing.expect(std.mem.find(u8, pair.owner_wire.bytes.items, "\"stopReason\":\"end_turn\"") != null);

    giveBackClaim(pair.session, running);
    turn = null;
}

/// Runs `handleCancel` on its own thread, so a test can hold the line lock while
/// the cancel waits for it.
const CancelCall = struct {
    state: *ServerState,
    session: *ActiveSessionState,

    fn run(self: *CancelCall) void {
        handleCancel(self.session, true);
    }
};

test "a cancel that waits for a claim stops that turn, and both flags agree" {
    const alloc = std.testing.allocator;
    var pair: CancelPair = undefined;
    try pair.open(alloc);
    defer pair.close();

    // A claim works under the line lock, so this test takes the lock too, and the
    // cancel starts on another thread and waits for it.
    const owner_msg = sessionPromptTestMessage(1);
    pair.session.waiting_prompts.lock();
    var call = CancelCall{ .state = &pair.state, .session = pair.session };
    const thread = try std.Thread.spawn(.{}, CancelCall.run, .{&call});

    // Before the fix, the cancel sets its flag before it waits for the lock, so the
    // flag appears at once. After the fix it stays unset until the lock is free.
    // The cancel thread waits for the lock, so after the fix the flag stays unset for the whole
    // wait. Before the fix it is set at once, so 250 ms is enough to see it.
    const deadline = io_mod.milliTimestamp() + 250;
    while (!pair.session.turn_cancel.load(.seq_cst) and io_mod.milliTimestamp() < deadline) {
        io_mod.sleep(std.time.ns_per_ms);
    }

    const claimed = claimTurnLocked(&pair.state, alloc, &owner_msg, pair.session) catch |err| {
        pair.session.waiting_prompts.unlock();
        thread.join();
        return err;
    };
    pair.session.waiting_prompts.unlock();
    thread.join();
    defer giveBackClaim(pair.session, claimed);

    // The claim ran first, so the cancel stops that turn and sets both flags. Before
    // the fix, the claim cleared the early flag and the cancel set only the other one.
    try std.testing.expect(pair.session.turn_cancel.load(.seq_cst));
    try std.testing.expect(pair.session.cancel_flag.load(.seq_cst));
}

test "the owner's prompt reaches the follower's client as its turn starts, and the owner's client gets no copy" {
    const alloc = std.testing.allocator;
    var pair: CancelPair = undefined;
    try pair.open(alloc);
    defer pair.close();

    const msg = sessionPromptTestMessage(1);
    var turn: ?*ActivePrompt = null;
    defer if (turn) |claimed| giveBackClaim(pair.session, claimed);
    switch (try decideSessionPrompt(&pair.state, alloc, &msg, pair.session)) {
        .claimed => |claimed| turn = claimed,
        else => return error.TestUnexpectedResult,
    }
    const running = turn orelse return error.TestUnexpectedResult;

    try announcePromptTurn(pair.session, pair.state.connection_id, alloc, "prompt-owner", "OWNER_PROMPT", &.{});
    try std.testing.expect(std.mem.find(u8, pair.follower_wire.bytes.items, "\"user_message_chunk\"") != null);
    try std.testing.expect(std.mem.find(u8, pair.follower_wire.bytes.items, "OWNER_PROMPT") != null);
    try std.testing.expect(std.mem.find(u8, pair.owner_wire.bytes.items, "user_message_chunk") == null);

    giveBackClaim(pair.session, running);
    turn = null;
}

test "a follower's prompt reaches the owner's client as its turn starts, and the follower's client gets no copy" {
    const alloc = std.testing.allocator;
    var pair: CancelPair = undefined;
    try pair.open(alloc);
    defer pair.close();

    const msg = sessionPromptTestMessage(4);
    var turn: ?*ActivePrompt = null;
    defer if (turn) |claimed| giveBackClaim(pair.session, claimed);
    switch (try decideSessionPrompt(&pair.follower, alloc, &msg, pair.session)) {
        .claimed => |claimed| turn = claimed,
        else => return error.TestUnexpectedResult,
    }
    const running = turn orelse return error.TestUnexpectedResult;

    try announcePromptTurn(pair.session, pair.follower.connection_id, alloc, "prompt-follower", "FOLLOWER_PROMPT", &.{});
    try std.testing.expect(std.mem.find(u8, pair.owner_wire.bytes.items, "\"user_message_chunk\"") != null);
    try std.testing.expect(std.mem.find(u8, pair.owner_wire.bytes.items, "FOLLOWER_PROMPT") != null);
    try std.testing.expect(std.mem.find(u8, pair.follower_wire.bytes.items, "user_message_chunk") == null);

    giveBackClaim(pair.session, running);
    turn = null;
}

test "a follower's prompt queued behind the owner's turn reaches the owner's client when its turn starts, not when it is queued" {
    const alloc = std.testing.allocator;
    var pair: CancelPair = undefined;
    try pair.open(alloc);
    defer pair.close();

    const owner_msg = sessionPromptTestMessage(1);
    var turn: ?*ActivePrompt = null;
    defer if (turn) |claimed| giveBackClaim(pair.session, claimed);
    switch (try decideSessionPrompt(&pair.state, alloc, &owner_msg, pair.session)) {
        .claimed => |claimed| turn = claimed,
        else => return error.TestUnexpectedResult,
    }
    const running = turn orelse return error.TestUnexpectedResult;

    // The follower's prompt waits behind the owner's turn. Queueing sends nothing.
    const follower_msg = jsonrpc.Message{ .id = .{ .integer = 4 }, .method = "session/prompt", .params_raw = queue_session_prompt_params };
    switch (try decideSessionPrompt(&pair.follower, alloc, &follower_msg, pair.session)) {
        .delivered => |outcome| switch (outcome) {
            .queued => {},
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(std.mem.find(u8, pair.owner_wire.bytes.items, "user_message_chunk") == null);
    try std.testing.expect(std.mem.find(u8, pair.follower_wire.bytes.items, "user_message_chunk") == null);

    // The owner's turn ends, and the queued prompt is taken to run next, as the worker does.
    var taken = blk: {
        pair.session.waiting_prompts.lock();
        defer pair.session.waiting_prompts.unlock();
        break :blk pair.session.waiting_prompts.takeNextLocked() orelse return error.TestUnexpectedResult;
    };
    defer taken.deinit(alloc);
    var ended = running.msg;
    running.msg = .{};
    defer jsonrpc.freeMessage(alloc, &ended);
    try startNextTurn(running, pair.session, &taken);
    try std.testing.expect(std.mem.find(u8, pair.owner_wire.bytes.items, "user_message_chunk") == null);

    // The queued prompt's turn starts: the owner's client gets its text, and the follower's
    // client gets none.
    try announcePromptTurn(pair.session, running.from, alloc, "prompt-queued", "QUEUED_PROMPT", &.{});
    try std.testing.expect(std.mem.find(u8, pair.owner_wire.bytes.items, "QUEUED_PROMPT") != null);
    try std.testing.expect(std.mem.find(u8, pair.follower_wire.bytes.items, "user_message_chunk") == null);

    giveBackClaim(pair.session, running);
    turn = null;
}

test "an image in a prompt reaches the other client as a replay sends it" {
    const alloc = std.testing.allocator;
    var pair: CancelPair = undefined;
    try pair.open(alloc);
    defer pair.close();

    const png = "\x89PNG\r\n\x1a\nimage-bytes";
    const image = try image_attachments.captureInlineImageBytesInMemory(alloc, 1, "image/png", png);
    defer types.freeImageAttachment(alloc, image);
    const images = [_]types.ImageAttachment{image};
    try announcePromptTurn(pair.session, pair.follower.connection_id, alloc, "prompt-image", "", &images);

    var expected: std.Io.Writer.Allocating = .init(alloc);
    defer expected.deinit();
    try acp_types.writeUserImageChunk(&expected.writer, "prompt-image", "image/png", png);
    try std.testing.expect(std.mem.find(u8, pair.owner_wire.bytes.items, expected.writer.buffered()) != null);
    try std.testing.expect(std.mem.find(u8, pair.follower_wire.bytes.items, "user_message_chunk") == null);
}

/// How many times `needle` occurs in `haystack`.
fn countText(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var rest = haystack;
    while (std.mem.find(u8, rest, needle)) |at| {
        count += 1;
        rest = rest[at + needle.len ..];
    }
    return count;
}

test "a follower's session/close withdraws its waiting input, answers it cancelled before its close answer, and leaves the owner's queued prompt" {
    const alloc = std.testing.allocator;
    var pair: CancelPair = undefined;
    try pair.open(alloc);
    defer pair.close();

    // The owner's turn runs, and its claim opens the steering runtime to take input.
    const owner_msg = sessionPromptTestMessage(1);
    var turn: ?*ActivePrompt = null;
    defer if (turn) |claimed| giveBackClaim(pair.session, claimed);
    switch (try decideSessionPrompt(&pair.state, alloc, &owner_msg, pair.session)) {
        .claimed => |claimed| turn = claimed,
        else => return error.TestUnexpectedResult,
    }

    // While the turn takes input, the follower's steer waits in the steering runtime.
    const steer_msg = jsonrpc.Message{ .id = .{ .integer = 6 }, .method = "session/prompt", .params_raw = steer_session_prompt_params };
    switch (try decideSessionPrompt(&pair.follower, alloc, &steer_msg, pair.session)) {
        .delivered => |outcome| switch (outcome) {
            .steered => {},
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }

    // The turn stops taking input, as `finishTurn` leaves the runtime. The follower's next
    // steer waits on the line as a late steer.
    pair.session.steering.accepting = false;
    const late_msg = jsonrpc.Message{ .id = .{ .integer = 7 }, .method = "session/prompt", .params_raw = steer_session_prompt_params };
    switch (try decideSessionPrompt(&pair.follower, alloc, &late_msg, pair.session)) {
        .delivered => |outcome| switch (outcome) {
            .late => {},
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }

    // Both connections queue a prompt with request id 4. The owner's must survive the
    // follower's close.
    const owner_queued = jsonrpc.Message{ .id = .{ .integer = 4 }, .method = "session/prompt", .params_raw = queue_session_prompt_params };
    switch (try decideSessionPrompt(&pair.state, alloc, &owner_queued, pair.session)) {
        .delivered => |outcome| switch (outcome) {
            .queued => {},
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
    const follower_queued = jsonrpc.Message{ .id = .{ .integer = 4 }, .method = "session/prompt", .params_raw = queue_session_prompt_params };
    switch (try decideSessionPrompt(&pair.follower, alloc, &follower_queued, pair.session)) {
        .delivered => |outcome| switch (outcome) {
            .queued => {},
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }

    // The follower closes the session. Its withdrawn input is answered before its close answer.
    var close_msg = jsonrpc.Message{ .id = .{ .integer = 9 }, .method = "session/close", .params_raw = "{\"sessionId\":\"session_answers\"}" };
    try handleCloseSession(&pair.follower, alloc, &close_msg);

    // The owner's queued prompt stays, with its sender and request id. The owner hears nothing.
    pair.session.waiting_prompts.lock();
    defer pair.session.waiting_prompts.unlock();
    try std.testing.expectEqual(@as(usize, 1), pair.session.waiting_prompts.queue.items.len);
    try std.testing.expectEqual(pair.state.connection_id, pair.session.waiting_prompts.queue.items[0].from);
    try std.testing.expectEqual(@as(i64, 4), pair.session.waiting_prompts.queue.items[0].msg.id.?.integer);
    try std.testing.expectEqual(@as(usize, 0), pair.session.waiting_prompts.late.items.len);
    try std.testing.expectEqual(@as(usize, 0), pair.session.steering.messages.items.len);
    try std.testing.expect(std.mem.find(u8, pair.owner_wire.bytes.items, "Request cancelled") == null);
    try std.testing.expect(!followsSession(&pair.follower, "session_answers"));

    // Each withdrawn steer and prompt gets exactly one cancelled answer on the follower's
    // writer, and all of them come before the close's answer. Their order among themselves
    // is not part of the contract.
    const wire = pair.follower_wire.bytes.items;
    const at_close = std.mem.find(u8, wire, "\"id\":9") orelse return error.TestUnexpectedResult;
    const needles = [_][]const u8{
        "\"id\":6,\"error\":{\"code\":-32800,\"message\":\"Request cancelled\"}",
        "\"id\":7,\"error\":{\"code\":-32800,\"message\":\"Request cancelled\"}",
        "\"id\":4,\"error\":{\"code\":-32800,\"message\":\"Request cancelled\"}",
    };
    for (needles) |needle| {
        try std.testing.expectEqual(@as(usize, 1), countText(wire, needle));
        const at = std.mem.find(u8, wire, needle) orelse return error.TestUnexpectedResult;
        try std.testing.expect(at < at_close);
    }
    try std.testing.expect(std.mem.find(u8, wire[at_close..], "\"result\":{}") != null);
    try std.testing.expectEqual(@as(usize, 3), countText(wire, "\"code\":-32800"));
}

test "a follower's disconnect withdraws its queued prompt with no write, and the trace names it" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const folder = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(folder);
    const trace_path = try std.Io.Dir.path.join(alloc, &.{ folder, "trace.log" });
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    var pair: CancelPair = undefined;
    try pair.open(alloc);
    defer pair.close();

    const owner_msg = sessionPromptTestMessage(1);
    var turn: ?*ActivePrompt = null;
    defer if (turn) |claimed| giveBackClaim(pair.session, claimed);
    switch (try decideSessionPrompt(&pair.state, alloc, &owner_msg, pair.session)) {
        .claimed => |claimed| turn = claimed,
        else => return error.TestUnexpectedResult,
    }

    const queued_msg = jsonrpc.Message{ .id = .{ .integer = 4 }, .method = "session/prompt", .params_raw = queue_session_prompt_params };
    switch (try decideSessionPrompt(&pair.follower, alloc, &queued_msg, pair.session)) {
        .delivered => |outcome| switch (outcome) {
            .queued => {},
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }

    // The follower's connection ends. Its deinit leaves each session it follows the same way.
    detachFollower(&pair.follower, "session_answers", .left);

    // Nothing reaches the follower, and its queued prompt is gone.
    try std.testing.expectEqual(@as(usize, 0), pair.follower_wire.bytes.items.len);
    pair.session.waiting_prompts.lock();
    const queued_after = pair.session.waiting_prompts.queue.items.len;
    pair.session.waiting_prompts.unlock();
    try std.testing.expectEqual(@as(usize, 0), queued_after);

    const trace = try readTraceFile(alloc, trace_path);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "event=waiting_input_dropped session=session_answers request=4 reason=follower_left") != null);
}

test "a follower that leaves while its own prompt's turn runs: the turn goes on, and its answer is dropped and traced" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const folder = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(folder);
    const trace_path = try std.Io.Dir.path.join(alloc, &.{ folder, "trace.log" });
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    var pair: CancelPair = undefined;
    try pair.open(alloc);
    defer pair.close();

    // The follower's own prompt starts the turn.
    const follower_msg = sessionPromptTestMessage(3);
    var turn: ?*ActivePrompt = null;
    defer if (turn) |claimed| giveBackClaim(pair.session, claimed);
    switch (try decideSessionPrompt(&pair.follower, alloc, &follower_msg, pair.session)) {
        .claimed => |claimed| turn = claimed,
        else => return error.TestUnexpectedResult,
    }
    const running = turn orelse return error.TestUnexpectedResult;

    // The follower closes the session while its turn runs.
    var close_msg = jsonrpc.Message{ .id = .{ .integer = 9 }, .method = "session/close", .params_raw = "{\"sessionId\":\"session_answers\"}" };
    try handleCloseSession(&pair.follower, alloc, &close_msg);

    // The turn goes on: it still holds the slot, and its worker still runs.
    pair.session.waiting_prompts.lock();
    const still_running = pair.session.prompt == running and pair.session.waiting_prompts.worker_running;
    pair.session.waiting_prompts.unlock();
    try std.testing.expect(still_running);

    // The turn ends. Its answer has no member to reach, so it is dropped and traced.
    publishTurnOutcome(running, pair.follower.connection_id, .{ .integer = 3 }, &.{}, .{ .stop_reason = .end_turn }, null);
    try std.testing.expect(std.mem.find(u8, pair.follower_wire.bytes.items, "stopReason") == null);

    const trace = try readTraceFile(alloc, trace_path);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "event=answer_dropped session=session_answers request=3 reason=sender_left") != null);
}

test "a steer that waits for a turn whose worker cannot start is answered to its sender, and traced" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const folder = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(folder);
    const trace_path = try std.Io.Dir.path.join(alloc, &.{ folder, "trace.log" });
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    var pair: CancelPair = undefined;
    try pair.open(alloc);
    defer pair.close();

    // The owner's prompt is claimed, and the claim opens the steering runtime. No worker runs yet.
    const owner_msg = sessionPromptTestMessage(1);
    var claimed: ?*ActivePrompt = null;
    defer if (claimed) |claim| giveBackClaim(pair.session, claim);
    switch (try decideSessionPrompt(&pair.state, alloc, &owner_msg, pair.session)) {
        .claimed => |claim| claimed = claim,
        else => return error.TestUnexpectedResult,
    }

    // In the gap before the worker starts, the follower's steer joins the runtime.
    const steer_msg = jsonrpc.Message{ .id = .{ .integer = 6 }, .method = "session/prompt", .params_raw = steer_session_prompt_params };
    switch (try decideSessionPrompt(&pair.follower, alloc, &steer_msg, pair.session)) {
        .delivered => |outcome| switch (outcome) {
            .steered => {},
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }

    // The spawn fails. startClaimedTurn takes the claim whether or not the spawn works, so
    // the test stops holding it before the call.
    const claim = claimed orelse return error.TestUnexpectedResult;
    claimed = null;
    prompt_test_controls.fail_next_spawn = true;
    try std.testing.expectError(error.SystemResources, startClaimedTurn(pair.session, claim));

    // The claim is given back, and the runtime holds no steer.
    pair.session.waiting_prompts.lock();
    const given_back = pair.session.prompt == null and !pair.session.waiting_prompts.worker_running;
    pair.session.waiting_prompts.unlock();
    try std.testing.expect(given_back);
    try std.testing.expectEqual(@as(usize, 0), pair.session.steering.messages.items.len);

    // The follower gets the spawn error for its steer, once. The owner's writer gets nothing
    // from this path, and the trace names the steer.
    try std.testing.expectEqual(@as(usize, 1), countText(pair.follower_wire.bytes.items, "\"id\":6,\"error\":{\"code\":-32603,\"message\":\"SystemResources\"}"));
    try std.testing.expectEqual(@as(usize, 0), pair.owner_wire.bytes.items.len);
    const trace = try readTraceFile(alloc, trace_path);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "event=waiting_input_dropped session=session_answers request=6 reason=spawn_failed") != null);
}
